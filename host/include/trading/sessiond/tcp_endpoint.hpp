// =============================================================================
// tcp_endpoint.hpp — the host owns the TCP connection
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : host/src/sessiond
// Governs : manuals/02-networking/02-ip-udp-tcp-in-hardware.md §5, §6
//           manuals/08-nasdaq/05-ouch-5.0-order-entry.md §2 "Division of labour"
//
// =============================================================================
// THE SPLIT, IN ONE PLACE, IN WRITING
// -----------------------------------------------------------------------------
//   HOST (this file, and sessiond)                FPGA (rtl/order/*)
//   ------------------------------                ------------------------
//   · TCP three-way handshake                     · emits ONE pre-validated
//   · TCP options, MSS, window scale                segment shape on an
//   · SoupBinTCP Login / Login Accepted              ALREADY-ESTABLISHED
//   · retransmission, RTO, congestion control        connection, fast
//   · the authoritative receive path               · patches {seq, ack, len,
//   · Logout, FIN, teardown, TIME_WAIT               csum} into a host-written
//   · the frame template + sequence hand-off         template
//                                                  · client heartbeat WHILE ARMED
//
// The FPGA never opens, closes, retransmits, or reasons about a connection. It
// splices bytes into a frame the host proved correct. Everything TCP knows how
// to do that is hard, the host does — and does slowly, which is correct, because
// by the time any of it runs the fast path has already failed.
//
// ⚠️ HAZARD 1 (manual §6): two writers to one TCP stream consume overlapping
//    sequence space and corrupt the connection beyond recovery. `snd_nxt` is
//    handed to the fabric exactly once per session epoch, while the fabric is
//    DISARMED, and the host must not write a single byte to this socket while
//    the fabric is armed. sessiond enforces that with SendOwner; this class
//    additionally refuses a send when `send_locked_` is set.
// =============================================================================
#pragma once

#include <chrono>
#include <cstdint>
#include "trading/expected.hpp"
#include <span>
#include <string_view>

#include "trading/sessiond/config.hpp"
#include "trading/sessiond/session_state.hpp"

namespace trading::sessiond {

// The established connection's 4-tuple, in HOST byte order. These values go
// straight into the frame template, where they are written big-endian.
struct ConnectionTuple {
    std::uint32_t local_ip    = 0;
    std::uint32_t remote_ip   = 0;
    std::uint16_t local_port  = 0;
    std::uint16_t remote_port = 0;
};

// -----------------------------------------------------------------------------
// The TCP sequence state that must be handed to the fabric.
//
// ⚠️ THIS IS THE HARDEST PART OF THE SPLIT TO GET FROM A KERNEL SOCKET.
//    The kernel does not export snd_nxt/rcv_nxt through any portable API.
//    The three real options, in order of preference:
//
//      1. A kernel-bypass TCP stack (Solarflare Onload / TCPDirect, VMA, or a
//         userspace stack over DPDK). The stack owns the TCB in user memory and
//         exposes it directly. This is what production runs.
//      2. Linux TCP_REPAIR + TCP_QUEUE_SEQ (getsockopt on a socket put into
//         repair mode). ⚠️ Requires CAP_NET_ADMIN and briefly perturbs the
//         socket — acceptable at hand-off time, which is a quiescent moment,
//         and never afterwards.
//      3. Snooping our own outbound SYN/ACK with a capture ring and computing
//         the sequence state from the wire. Correct, ugly, and useful as a
//         cross-check even when 1 or 2 is available.
//
//    There is no fourth option that involves guessing. `seqSnapshot()` returns
//    SeqStateUnavailable rather than inventing a number, and sessiond refuses to
//    write a template without one. A wrong snd_nxt does not produce an error: it
//    produces a segment the venue silently discards, and an order that never
//    happened.
// -----------------------------------------------------------------------------
struct TcpSeqSnapshot {
    std::uint32_t snd_nxt = 0;   // next sequence number WE will send (wire value)
    std::uint32_t rcv_nxt = 0;   // next sequence number we expect FROM the venue
    std::uint16_t snd_wnd = 0;   // the venue's advertised receive window, unscaled
    bool          valid   = false;
};

// -----------------------------------------------------------------------------
// Interface. Virtual so tests can drive the whole session state machine against
// a scripted peer with no sockets involved — which is the only way the recovery
// paths (§6 of the brief) ever get exercised.
// -----------------------------------------------------------------------------
class TcpEndpoint {
 public:
    virtual ~TcpEndpoint() = default;

    virtual trading::expected<void, SessionError> connect(const SessionConfig& cfg) = 0;

    // Non-blocking. Returns bytes written; a short write is normal and the
    // caller must retry the remainder.
    virtual trading::expected<std::size_t, SessionError> send(std::span<const std::uint8_t> data) = 0;

    // Non-blocking. Returns bytes read; 0 means "nothing available right now",
    // PeerClosed means the venue closed the connection.
    virtual trading::expected<std::size_t, SessionError> recv(std::span<std::uint8_t> buf) = 0;

    virtual trading::expected<void, SessionError>            shutdownWrite() = 0;
    virtual void                                         close() noexcept = 0;
    [[nodiscard]] virtual bool                           connected() const noexcept = 0;
    [[nodiscard]] virtual trading::expected<ConnectionTuple, SessionError> tuple() const = 0;
    [[nodiscard]] virtual trading::expected<TcpSeqSnapshot, SessionError> seqSnapshot() const = 0;

    // ⚠️ Hazard-1 interlock. While locked, every send() returns
    //    SendOwnerViolation. sessiond locks the socket the instant the fabric is
    //    armed and unlocks it only after a verified disarm.
    virtual void lockSend(bool locked) noexcept = 0;
    [[nodiscard]] virtual bool sendLocked() const noexcept = 0;
};

// -----------------------------------------------------------------------------
// A plain BSD-socket implementation. Nagle and delayed ACK are disabled at
// connect time (manual §8 rule 10: a 40 ms delayed-ACK timer on an order
// session is a catastrophe hiding in a default).
//
// seqSnapshot() returns SeqStateUnavailable unless a provider has been
// installed with setSeqProvider() — see the note above. This class does not
// pretend to know the kernel's TCB.
// -----------------------------------------------------------------------------
class PosixTcpEndpoint final : public TcpEndpoint {
 public:
    using SeqProvider = trading::expected<TcpSeqSnapshot, SessionError> (*)(int fd, void* ctx);

    PosixTcpEndpoint() = default;
    ~PosixTcpEndpoint() override;

    PosixTcpEndpoint(const PosixTcpEndpoint&)            = delete;
    PosixTcpEndpoint& operator=(const PosixTcpEndpoint&) = delete;

    trading::expected<void, SessionError>        connect(const SessionConfig& cfg) override;
    trading::expected<std::size_t, SessionError> send(std::span<const std::uint8_t> data) override;
    trading::expected<std::size_t, SessionError> recv(std::span<std::uint8_t> buf) override;
    trading::expected<void, SessionError>        shutdownWrite() override;
    void                                     close() noexcept override;
    [[nodiscard]] bool                       connected() const noexcept override;
    [[nodiscard]] trading::expected<ConnectionTuple, SessionError> tuple() const override;
    [[nodiscard]] trading::expected<TcpSeqSnapshot, SessionError>  seqSnapshot() const override;

    void lockSend(bool locked) noexcept override { send_locked_ = locked; }
    [[nodiscard]] bool sendLocked() const noexcept override { return send_locked_; }

    // Install the platform-specific way of reading the TCB. Called by main()
    // with whichever of the three options above this deployment has.
    void setSeqProvider(SeqProvider fn, void* ctx) noexcept {
        seq_provider_ = fn;
        seq_ctx_      = ctx;
    }

    [[nodiscard]] int fd() const noexcept { return fd_; }

 private:
    int         fd_          = -1;
    bool        send_locked_ = false;
    SeqProvider seq_provider_ = nullptr;
    void*       seq_ctx_      = nullptr;
};

}  // namespace trading::sessiond
