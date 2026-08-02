// =============================================================================
// session_state.hpp — sessiond lifecycle states, errors, and counters
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : host/src/sessiond
//
// The state enum MIRRORS THE HARDWARE. SESS_STATE (BAR0 + 0x3028) encodes
// 0=down 1=connecting 2=login_sent 3=up 4=fault. The host's own state machine
// uses the same encoding so the two can be compared directly, and a divergence
// is a counted, alertable event rather than something nobody notices.
//
// TODO(rtl-contract): derived from fpga_top.sv cfg_* ports; reconcile with
//   rtl/ctrl/csr_regfile.sv when that file lands.
// =============================================================================
#pragma once

#include <cstdint>
#include <string_view>

#include "trading/types.hpp"

namespace trading::sessiond {

// =============================================================================
// Session lifecycle
// -----------------------------------------------------------------------------
//                    ┌──────────────────────────────────────────┐
//                    │                                          │
//   DOWN ──connect──► CONNECTING ──tcp up──► LOGIN_SENT ──accept──► UP
//    ▲                    │                      │                  │
//    │                    │ timeout/refused      │ reject/timeout   │ eos/close
//    │                    ▼                      ▼                  │
//    └──── resync ──── FAULT ◄───── seq fault / template fault ◄────┘
//
// FAULT is sticky: it is only left through resynchronize(), which begins by
// making the fabric unable to emit. There is no edge from FAULT to UP that does
// not pass through that call.
// =============================================================================
// The enum itself lives in trading/types.hpp (§11, "Venue session state") so
// that logd, metricsd and ctrld all read SESS_STATE through the same type.
// sessiond does not define a second one — two enums for one register is exactly
// how a 3 comes to mean "up" in one process and "fault" in another.
using SessionState = trading::SessionState;
// trading::toString(SessionState) is found by ADL; there is no override here.

// =============================================================================
// Errors
// -----------------------------------------------------------------------------
// No exceptions on control paths. Every fallible operation returns
// trading::expected<T, SessionError>.
// =============================================================================
enum class SessionError : std::uint32_t {
    None = 0,

    // configuration
    NotConfigured,          // a required config key was absent (no defaults for credentials)
    InvalidConfig,          // present but unusable (bad IP, empty username, …)

    // transport
    SocketError,
    ConnectTimeout,
    PeerClosed,             // venue closed the TCP connection
    SendOwnerViolation,     // ⚠️ host tried to write the socket while the fabric owns TX
    SeqStateUnavailable,    // TCP snd_nxt/rcv_nxt could not be read from the stack

    // session layer
    LoginTimeout,
    LoginRejectedAuth,      // 'A' — credentials/entitlement. Operator action, DO NOT retry.
    LoginRejectedSession,   // 'S' — requested session id unavailable. Different problem.
    LoginRejectedUnknown,
    ReceiveTimeout,         // no bytes at all for rx_timeout — the session is dead
    EndOfSession,           // orderly 'Z'; not an error, but not a state we can trade in
    MalformedPacket,
    UnexpectedPacket,       // legal packet, illegal in this state
    WrongState,             // API misuse: called in a state that cannot service it

    // sequence
    SequenceGap,            // venue replayed from a point ahead of what we need
    SequenceFault,          // ⚠️ unrecoverable -> kill_src_e KILL_SEQ_FAULT (7)

    // fabric
    DeviceIo,               // any trading::Device read/write failure
    TemplateVerifyMismatch, // read-back of a template word != what we wrote
    TemplateCrcMismatch,    // SESS_TMPL_CRC != host-computed CRC32
    FabricStateMismatch,    // SESS_STATE disagrees with the host state machine
    LinkDown,               // SESS_LINK_UP bit0 (order-entry link) is low
    ControlPlaneRefused,    // ctrld would not disarm / arm / kill on request
    BufferOverflow,         // rx buffer full with no complete packet — corrupt stream
};

[[nodiscard]] std::string_view toString(SessionError e) noexcept;

// True for errors that must not be retried automatically. Retrying a bad
// password locks the account; retrying an unrecoverable sequence fault trades on
// a book we know is wrong.
[[nodiscard]] bool requiresOperator(SessionError e) noexcept;

// =============================================================================
// Why a resynchronisation was started. Recorded in the audit log and in stats;
// the distribution of these is the single best health signal for the session.
// =============================================================================
enum class ResyncReason : std::uint32_t {
    Startup = 0,
    TcpClosed,
    ReceiveTimeout,
    LoginRejected,
    SequenceGap,
    SequenceFault,
    EndOfSession,
    LinkDown,
    TemplateFault,
    OperatorRequest,
};

[[nodiscard]] std::string_view toString(ResyncReason r) noexcept;

// =============================================================================
// Counters. ⚠️ CLAUDE.md §5.7: every drop, error and rejection is counted.
// Silent failure is the worst failure mode in this domain.
// =============================================================================
struct SessionStats {
    std::uint64_t connects_attempted    = 0;
    std::uint64_t connects_succeeded    = 0;
    std::uint64_t logins_sent           = 0;
    std::uint64_t logins_accepted       = 0;
    std::uint64_t logins_rejected_auth  = 0;
    std::uint64_t logins_rejected_sess  = 0;
    std::uint64_t logouts_sent          = 0;

    std::uint64_t seq_data_rx           = 0;   // SequencedData packets consumed
    std::uint64_t unseq_data_rx         = 0;   // ⚠️ should be 0; we are the client
    std::uint64_t server_heartbeats_rx  = 0;
    std::uint64_t client_heartbeats_tx  = 0;   // host-originated only (see send ownership)
    std::uint64_t debug_rx              = 0;
    std::uint64_t end_of_session_rx     = 0;

    std::uint64_t rx_timeouts           = 0;
    std::uint64_t malformed_packets     = 0;
    std::uint64_t unexpected_packets    = 0;
    std::uint64_t peer_closes           = 0;

    std::uint64_t sequence_gaps         = 0;
    std::uint64_t sequence_faults       = 0;
    std::uint64_t replay_duplicates     = 0;   // venue re-sent messages we already had

    std::uint64_t template_writes       = 0;
    std::uint64_t template_verify_fails = 0;
    std::uint64_t template_crc_fails    = 0;

    std::uint64_t resyncs_started       = 0;
    std::uint64_t resyncs_completed     = 0;
    std::uint64_t resyncs_failed        = 0;

    std::uint64_t fabric_state_mismatch = 0;
    std::uint64_t credits_returned      = 0;
    std::uint64_t credit_return_errors  = 0;
    std::uint64_t send_owner_violations = 0;   // ⚠️ any nonzero value is a design bug
};

// =============================================================================
// Who currently owns the TCP send side of the order-entry connection.
// -----------------------------------------------------------------------------
// ⚠️ manuals/02-networking/02-ip-udp-tcp-in-hardware.md §6 hazard 1: two
//    independent writers to one TCP stream consume overlapping sequence space
//    and corrupt the connection beyond recovery. There is exactly one owner at
//    any instant, it is recorded here, and every host-side socket write is
//    gated on it.
// =============================================================================
enum class SendOwner : std::uint8_t {
    Host   = 0,   // login, logout, host heartbeats, teardown
    Fabric = 1,   // steady state: orders, cancels AND the client heartbeat
};

[[nodiscard]] std::string_view toString(SendOwner o) noexcept;

}  // namespace trading::sessiond
