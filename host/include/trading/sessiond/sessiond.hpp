// =============================================================================
// sessiond.hpp — the venue session daemon
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : host/src/sessiond
// Governs : host/README.md §2 (`sessiond`), §3 (non-negotiables)
//           manuals/08-nasdaq/05-ouch-5.0-order-entry.md §2, §10, §11
//           manuals/02-networking/02-ip-udp-tcp-in-hardware.md §6
//
// =============================================================================
// ⚠️⚠️  sessiond DOES NOT SEND ORDERS.  ⚠️⚠️
//
// host/README.md §3.2: "The host never bypasses the risk gate. There is no
// software path that emits an order." sessiond owns the TCP connection and the
// SoupBinTCP login. It then hands the fabric a validated header template and the
// sequence state, and the FABRIC emits orders — through the hardware risk gate,
// which it cannot go around. There is no sendOrder() in this class, in this
// directory, or anywhere in host/. If one appears, that is a design discussion,
// not a patch.
//
// What sessiond does send: Login Request, Client Heartbeat (only while it owns
// the send side), Logout Request. Three packet types, none of which can move a
// position.
// =============================================================================
//
// =============================================================================
// SEND OWNERSHIP — the interlock that makes the split TCP safe
// -----------------------------------------------------------------------------
// manuals/02-networking/02-ip-udp-tcp-in-hardware.md §6 hazard 1: two
// independent writers to one TCP stream consume overlapping sequence space and
// corrupt the connection beyond recovery. So there is exactly one writer at any
// instant, and the transition is explicit:
//
//   SendOwner::Host                        SendOwner::Fabric
//   ─────────────────────────────          ─────────────────────────────
//   connect, Login Request,                orders, cancels, and the
//   Client Heartbeat, Logout               SoupBinTCP Client Heartbeat
//   ▲                                      ▲
//   │ lock socket, TxArm=1 ────────────────┘
//   └──────────── TxArm=0, verify, unlock socket
//
// The host's socket is LOCKED (TcpEndpoint::lockSend) whenever the fabric owns
// the send side; any attempted write returns SendOwnerViolation and increments a
// counter that must always read zero.
//
// Handing the heartbeat to the fabric is deliberate (rtl/order/ouch_pkg.sv §2):
// a quiet market must not be able to kill the session because the host was busy.
//
// ⚠️ HONEST CAVEAT — the host TCP stack must not repudiate the fabric's bytes.
//    While the fabric transmits on this connection, the venue's ACKs cover bytes
//    the host's own stack never sent. A stock kernel socket will treat those as
//    acknowledging data it does not have and can RST the connection. Three
//    deployments are viable, and one MUST be chosen explicitly:
//      1. A kernel-bypass stack whose TCB the fabric and the host share
//         (Onload/TCPDirect, VMA, or a userspace stack over DPDK) — production.
//      2. The socket held in Linux TCP_REPAIR while the fabric is armed, so the
//         kernel neither transmits nor reacts, with the host reading the wire
//         through a capture ring instead.
//      3. The FPGA as a bump-in-the-wire that owns the IP entirely and forwards
//         a copy of the inbound stream to the host.
//    Option (1) is the project default. TcpEndpoint::seqSnapshot() is where that
//    choice becomes concrete; there is no configuration that makes a plain
//    kernel socket correct here.
// =============================================================================
#pragma once

#include <array>
#include <chrono>
#include <cstdint>
#include "trading/expected.hpp"
#include <span>

#include "trading/device.hpp"
#include "trading/sessiond/config.hpp"
#include "trading/sessiond/control_plane.hpp"
#include "trading/sessiond/frame_template.hpp"
#include "trading/sessiond/session_regs.hpp"
#include "trading/sessiond/session_state.hpp"
#include "trading/sessiond/soupbin.hpp"
#include "trading/sessiond/tcp_endpoint.hpp"

namespace trading::sessiond {

// -----------------------------------------------------------------------------
// Injectable clock. Recovery paths are the least-exercised code in any trading
// system; making time injectable is what lets a test drive a 15-second receive
// timeout in a microsecond.
// -----------------------------------------------------------------------------
class Clock {
 public:
    using TimePoint = std::chrono::steady_clock::time_point;
    virtual ~Clock() = default;
    [[nodiscard]] virtual TimePoint now() const noexcept = 0;
};

class SteadyClock final : public Clock {
 public:
    [[nodiscard]] TimePoint now() const noexcept override {
        return std::chrono::steady_clock::now();
    }
};

// -----------------------------------------------------------------------------
// Inbound sequenced data is handed on verbatim. sessiond does not parse OUCH —
// that belongs to the order-gateway / reconciler components. A raw function
// pointer, not std::function: no allocation, no exceptions, no surprises.
// -----------------------------------------------------------------------------
using SequencedDataHandler = void (*)(std::uint64_t sequence,
                                      std::span<const std::uint8_t> ouch_message,
                                      void* ctx);

// -----------------------------------------------------------------------------
// Inbound SoupBinTCP sequence tracking. 64-bit integers throughout — the wire
// field is 20 ASCII digits and a sequence number is never, under any
// circumstances, a floating-point value.
// -----------------------------------------------------------------------------
struct SequenceState {
    // The sequence number of the next Sequenced Data packet we expect. On a
    // reconnect, THIS is what we ask the venue to replay from.
    std::uint64_t next_expected = 0;
    // The highest sequence number actually delivered to the handler. Replayed
    // duplicates below this are counted and dropped, never re-delivered.
    std::uint64_t highest_delivered = 0;
    // What we asked for on the most recent Login Request.
    std::uint64_t last_requested = 0;
    // What the venue said it would start from in Login Accepted.
    std::uint64_t last_accepted = 0;
    bool baseline_established = false;
};

// =============================================================================
// SessionDaemon
// =============================================================================
class SessionDaemon {
 public:
    SessionDaemon(SessionConfig cfg,
                  Device& dev,
                  ControlPlane& control,
                  TcpEndpoint& tcp,
                  Clock& clock) noexcept;

    void setSequencedDataHandler(SequencedDataHandler h, void* ctx) noexcept {
        on_seq_data_     = h;
        on_seq_data_ctx_ = ctx;
    }

    // ── Bring-up ─────────────────────────────────────────────────────────────
    // Step 5 of the fixed startup sequence (host/README.md §3.1): "configure
    // session and templates". Ordered, and every step must succeed before the
    // next runs:
    //   1. validate the config (no credentials, no start)
    //   2. confirm the order-entry link is up (SESS_LINK_UP bit0)
    //   3. confirm the fabric cannot emit — we configure a quiescent gateway
    //   4. TCP connect
    //   5. SoupBinTCP Login Request -> Login Accepted
    //   6. reconcile the inbound sequence number with what the venue reports
    //   7. build, write, READ BACK, verify and CRC-check the frame template
    //   8. publish the sequence state and the session epoch
    //   9. hand the TCP send side to the fabric (lock socket, TxArm=1)
    // It does NOT arm trading. That is ctrld's two-step arm, steps 7-8 of the
    // startup sequence, and it is a separate, human-gated act.
    [[nodiscard]] trading::expected<void, SessionError> start();

    // ── Steady state ─────────────────────────────────────────────────────────
    // Non-blocking. Drains the socket, dispatches packets, enforces the receive
    // timeout, emits a Client Heartbeat when the host owns the send side, and
    // periodically cross-checks the fabric's view against ours. Returns the
    // error that took the session down, having already set state to Fault; the
    // caller decides whether to resynchronize().
    [[nodiscard]] trading::expected<void, SessionError> poll();

    // ── Recovery ─────────────────────────────────────────────────────────────
    // THE ORDERED RECOVERY. On any session drop, link down or sequence fault:
    //   (a) make the fabric unable to emit — request it AND verify it. On an
    //       unrecoverable sequence fault, latch the hardware kill switch with
    //       kill_src = KILL_SEQ_FAULT (trading_pkg::kill_src_e = 7) first.
    //   (b) tear down the old connection and reconnect
    //   (c) re-login, requesting the sequence number we actually need, and
    //       reconcile what the venue reports against it
    //   (d) rewrite the template for the NEW connection (new source port, new
    //       sequence space, new epoch) and re-verify it, CRC included
    //   (e) only then permit trading again — and only if it was permitted
    //       before the fault.
    // Every step is checked; a failure anywhere leaves the session in Fault with
    // the fabric unable to emit, which is the only safe resting place.
    [[nodiscard]] trading::expected<void, SessionError> resynchronize(ResyncReason reason);

    // Orderly shutdown: disarm first, take back the send side, Logout Request,
    // then close. ⚠️ The reverse of bring-up, and it disables emission BEFORE it
    // stops anything else (host/README.md, shutdown ordering).
    [[nodiscard]] trading::expected<void, SessionError> shutdown();

    // ── Accessors ────────────────────────────────────────────────────────────
    [[nodiscard]] SessionState state() const noexcept { return state_; }
    [[nodiscard]] SendOwner sendOwner() const noexcept { return send_owner_; }
    [[nodiscard]] const SessionStats& stats() const noexcept { return stats_; }
    [[nodiscard]] const SequenceState& sequence() const noexcept { return seq_; }
    [[nodiscard]] CreditLedger& credits() noexcept { return credits_; }
    [[nodiscard]] std::uint16_t epoch() const noexcept { return epoch_; }
    [[nodiscard]] SessionError lastError() const noexcept { return last_error_; }
    // True once the session is UP with a verified template — the precondition
    // ctrld checks before its two-step arm.
    [[nodiscard]] bool readyForArm() const noexcept {
        return state_ == SessionState::Up && template_verified_;
    }
    // Records that trading was permitted, so a resynchronise knows whether to
    // re-permit it at step (e). Called by ctrld when it arms and disarms.
    void noteTradingPermitted(bool permitted) noexcept { was_armed_ = permitted; }

 private:
    // ── Ordered bring-up steps, each individually testable ───────────────────
    [[nodiscard]] trading::expected<void, SessionError> ensureFabricCannotEmit();
    [[nodiscard]] trading::expected<void, SessionError> checkLink();
    [[nodiscard]] trading::expected<void, SessionError> connectTcp();
    [[nodiscard]] trading::expected<void, SessionError> performLogin();
    [[nodiscard]] trading::expected<void, SessionError> reconcileSequence(
            const soup::LoginAccepted& accepted);
    [[nodiscard]] trading::expected<void, SessionError> writeTemplateAndVerify();
    [[nodiscard]] trading::expected<void, SessionError> publishSequenceState();
    [[nodiscard]] trading::expected<void, SessionError> handSendSideToFabric();
    [[nodiscard]] trading::expected<void, SessionError> takeSendSideFromFabric();

    // ── Packet handling ──────────────────────────────────────────────────────
    [[nodiscard]] trading::expected<void, SessionError> drainSocket();
    [[nodiscard]] trading::expected<void, SessionError> dispatch(const soup::Packet& pkt);
    [[nodiscard]] trading::expected<void, SessionError> sendAll(std::span<const std::uint8_t> data);
    [[nodiscard]] trading::expected<void, SessionError> sendClientHeartbeat();
    [[nodiscard]] std::uint64_t computeRequestedSequence() const noexcept;

    [[nodiscard]] trading::expected<void, SessionError> crossCheckFabric();
    void transition(SessionState next) noexcept;
    void fault(SessionError e) noexcept;

    // ── Wiring ───────────────────────────────────────────────────────────────
    SessionConfig    cfg_;
    SessionRegisters regs_;
    ControlPlane&    control_;
    TcpEndpoint&     tcp_;
    Clock&           clock_;

    SequencedDataHandler on_seq_data_     = nullptr;
    void*                on_seq_data_ctx_ = nullptr;

    // ── State ────────────────────────────────────────────────────────────────
    SessionState  state_       = SessionState::Down;
    SendOwner     send_owner_  = SendOwner::Host;
    SessionError  last_error_  = SessionError::None;
    SequenceState seq_{};
    SessionStats  stats_{};
    CreditLedger  credits_{/*fabric_auto_returns=*/true};

    // Session epoch. ⚠️ Bumped on EVERY (re-)login. The fabric refuses to fire
    // if the template's epoch does not match the armed value, so a stale
    // template physically cannot emit into a new session
    // (networking manual §6 hazard 5).
    std::uint16_t epoch_             = 0;
    bool          template_verified_ = false;
    bool          was_armed_         = false;

    FrameTemplate frame_template_{};   // rebuilt on every login

    // ── Timers ───────────────────────────────────────────────────────────────
    Clock::TimePoint last_rx_{};
    Clock::TimePoint last_tx_{};
    Clock::TimePoint last_cross_check_{};

    // ── Receive buffering ────────────────────────────────────────────────────
    // Fixed size, no allocation. Sized so a burst of sequenced data cannot force
    // a partial-packet stall; a full buffer with no complete packet in it means
    // the stream is corrupt and the session must be torn down, not grown.
    static constexpr std::size_t kRxBufBytes = 256 * 1024;
    std::array<std::uint8_t, kRxBufBytes> rx_buf_{};
    std::size_t                           rx_len_ = 0;
};

}  // namespace trading::sessiond
