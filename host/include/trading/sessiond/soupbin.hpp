// =============================================================================
// soupbin.hpp — SoupBinTCP 3.00 session-layer wire formats
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : host/src/sessiond  (sessiond — the venue session)
// Mirrors : manuals/08-nasdaq/05-ouch-5.0-order-entry.md §2 (SoupBinTCP)
//           rtl/order/ouch_pkg.sv §1 (SOUP_* parameters) — the RTL and this
//           header MUST agree byte for byte; they are the same wire format seen
//           from two sides. Any change here is a change there.
//
// -----------------------------------------------------------------------------
// EVERY STRUCT IN THIS FILE IS A WIRE FORMAT.
//   * packed, no padding, `static_assert` on sizeof
//   * BIG-ENDIAN on the wire. Multi-byte binary fields use be16_t / be32_t and
//     are converted exactly once, at the boundary (see host/README.md brief).
//   * numeric text fields (SoupBinTCP sequence numbers) are ASCII DECIMAL, not
//     binary. They are parsed into std::uint64_t and never touched as text
//     again.
//   * NO FLOATS. Sequence numbers are 64-bit unsigned integers.
//
// ⚠️ A wrong offset in this file does not fail loudly. It produces a Login
//    Request the venue rejects, or — far worse — a sequence number the venue
//    interprets as a different replay point. Every field below is marked with
//    the spec section that must confirm it.
// =============================================================================
#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>

namespace trading::sessiond::soup {

// =============================================================================
// 1. Big-endian scalar wrappers
// -----------------------------------------------------------------------------
// The type name says "be" so that a big-endian value can never be mistaken for
// a host-order one at a call site. `.host()` is the only way to read it.
// =============================================================================
struct be16_t {
    std::uint8_t b[2];

    [[nodiscard]] constexpr std::uint16_t host() const noexcept {
        return static_cast<std::uint16_t>((static_cast<std::uint16_t>(b[0]) << 8) |
                                           static_cast<std::uint16_t>(b[1]));
    }
    constexpr void set(std::uint16_t v) noexcept {
        b[0] = static_cast<std::uint8_t>(v >> 8);
        b[1] = static_cast<std::uint8_t>(v);
    }
};
static_assert(sizeof(be16_t) == 2, "wire format");

struct be32_t {
    std::uint8_t b[4];

    [[nodiscard]] constexpr std::uint32_t host() const noexcept {
        return (static_cast<std::uint32_t>(b[0]) << 24) |
               (static_cast<std::uint32_t>(b[1]) << 16) |
               (static_cast<std::uint32_t>(b[2]) << 8) |
                static_cast<std::uint32_t>(b[3]);
    }
    constexpr void set(std::uint32_t v) noexcept {
        b[0] = static_cast<std::uint8_t>(v >> 24);
        b[1] = static_cast<std::uint8_t>(v >> 16);
        b[2] = static_cast<std::uint8_t>(v >> 8);
        b[3] = static_cast<std::uint8_t>(v);
    }
};
static_assert(sizeof(be32_t) == 4, "wire format");

// =============================================================================
// 2. Packet framing
// -----------------------------------------------------------------------------
//   byte  0      1      2      3 ....
//        ┌──────┬──────┬──────┬──────────────────────────────┐
//        │ length (BE) │ type │ payload (length-1 bytes)     │
//        └──────┴──────┴──────┴──────────────────────────────┘
//
// TODO(verify): SoupBinTCP 3.00 §"Packet Header" — the Packet Length field is
//   assumed to COUNT the Packet Type byte, so a packet carrying an N-byte
//   payload has length = N + 1 and occupies N + 3 bytes on the wire. A Client
//   Heartbeat therefore has length = 1. This matches rtl/order/ouch_pkg.sv
//   SOUP_LEN_BIAS = 1 (itself unverified, marked V1 there).
// =============================================================================
inline constexpr std::size_t   kHeaderBytes = 3;
inline constexpr std::uint16_t kLengthBias  = 1;   // length = payload_len + BIAS

// Largest SoupBinTCP packet sessiond will accept from the venue. Outbound OUCH
// messages are < 128 B today; the cap exists so a corrupt length field cannot
// make us wait forever for bytes that will never come.
// TODO(verify): OUCH 5.0 §"Optional Appendage" — an appendage on an outbound
//   message could exceed this. Confirm the venue's maximum outbound message
//   length and raise the cap if needed. Too small is a stall; too large is only
//   memory.
inline constexpr std::size_t kMaxPacketBytes = 1024;

// ---- Packet type codes ------------------------------------------------------
// TODO(verify): SoupBinTCP 3.00 §"Packet Types" — every letter below.
//   Cross-checked against manuals/08-nasdaq/05-ouch-5.0-order-entry.md §2 and
//   rtl/order/ouch_pkg.sv SOUP_* (both flagged "verify" at source).
enum class PacketType : std::uint8_t {
    // client -> server
    LoginRequest    = 'L',
    UnsequencedData = 'U',   // carries an inbound OUCH message (Enter/Cancel/…)
    ClientHeartbeat = 'R',
    LogoutRequest   = 'O',
    // server -> client
    LoginAccepted   = 'A',
    LoginRejected   = 'J',
    SequencedData   = 'S',   // carries an outbound OUCH message (Accepted/…)
    ServerHeartbeat = 'H',
    EndOfSession    = 'Z',
    // either direction
    Debug           = '+',
};

[[nodiscard]] constexpr bool isServerToClient(PacketType t) noexcept {
    switch (t) {
        case PacketType::LoginAccepted:
        case PacketType::LoginRejected:
        case PacketType::SequencedData:
        case PacketType::ServerHeartbeat:
        case PacketType::EndOfSession:
        case PacketType::Debug:
            return true;
        default:
            return false;
    }
}

// ⚠️ ONLY SequencedData advances the inbound sequence number. Heartbeats and
//    Debug packets do not. Getting this wrong silently shifts every subsequent
//    replay point. See manuals/08-nasdaq/05-ouch-5.0-order-entry.md §2 and
//    rtl/order/ouch_pkg.sv §2 CONSEQUENCE 3.
[[nodiscard]] constexpr bool advancesSequence(PacketType t) noexcept {
    return t == PacketType::SequencedData;
}

// =============================================================================
// 3. Packed wire structs
// =============================================================================
#pragma pack(push, 1)

// SoupBinTCP packet header. Mirrors rtl/order/ouch_pkg.sv SOUP_LEN_OFF /
// SOUP_TYPE_OFF / SOUP_HDR_LEN.
struct PacketHeader {
    be16_t       length;   // payload bytes + kLengthBias
    std::uint8_t type;     // PacketType
};
static_assert(sizeof(PacketHeader) == 3, "SoupBinTCP header is 2+1 bytes");
static_assert(sizeof(PacketHeader) == kHeaderBytes, "framing constant drift");

// ---- Login Request (client -> server), payload 46 bytes ---------------------
// TODO(verify): SoupBinTCP 3.00 §"Login Request Packet" — field widths and
//   order. Mirrors rtl/order/ouch_pkg.sv SOUP_LOGIN_REQ_* (flagged V2 there).
// TODO(verify): text field justification. Username / Password / Requested
//   Session are assumed LEFT-justified and space-padded; Requested Sequence
//   Number is assumed RIGHT-justified and space-padded ASCII decimal. The
//   parser here is tolerant of both, the encoder is not — it must emit exactly
//   what the venue expects.
// ⚠️ Username, password and requested session are CREDENTIALS. They come from
//    the gitignored config file only (host/README.md §3.5). Never a default,
//    never a literal, and `password` is never written to a log — see
//    SessionConfig::redactedSummary().
struct LoginRequestPayload {
    char username[6];
    char password[10];
    char requested_session[10];
    char requested_sequence[20];   // ASCII decimal
};
static_assert(sizeof(LoginRequestPayload) == 46, "SoupBinTCP Login Request payload");

struct LoginRequestPacket {
    PacketHeader        hdr;
    LoginRequestPayload body;
};
static_assert(sizeof(LoginRequestPacket) == 49, "SoupBinTCP Login Request packet");

// ---- Login Accepted (server -> client), payload 30 bytes --------------------
// TODO(verify): SoupBinTCP 3.00 §"Login Accepted Packet".
// The sequence number here is the sequence of the NEXT Sequenced Data packet
// the venue will send — not the last one it sent.
// TODO(verify): that "next, not last" reading. It decides whether our first
//   received message is counted at N or N+1, and an off-by-one in the replay
//   point is an order-state divergence, not a cosmetic bug.
struct LoginAcceptedPayload {
    char session[10];
    char sequence[20];   // ASCII decimal
};
static_assert(sizeof(LoginAcceptedPayload) == 30, "SoupBinTCP Login Accepted payload");

// ---- Login Rejected (server -> client), payload 1 byte ----------------------
struct LoginRejectedPayload {
    char reason;
};
static_assert(sizeof(LoginRejectedPayload) == 1, "SoupBinTCP Login Rejected payload");

#pragma pack(pop)

// ---- Login reject reason codes ----------------------------------------------
// ⚠️ These two are NOT the same problem and must never share a code path:
//   'A' — the credentials are wrong or the account is not entitled. Retrying
//         burns login attempts and can lock the account. Operator action.
//   'S' — the requested session id does not exist / is not available. The
//         credentials are fine; the session identifier is stale (typically a
//         previous day's session). Retrying with the SAME id will never work.
// TODO(verify): SoupBinTCP 3.00 §"Login Rejected Packet" — the reason letters
//   and whether more than these two exist. Mirrors ouch_pkg.sv SOUP_REJ_*.
enum class LoginRejectReason : std::uint8_t {
    NotAuthorized     = 'A',
    SessionNotAvailable = 'S',
    Unknown           = 0,
};

[[nodiscard]] LoginRejectReason decodeRejectReason(char c) noexcept;
[[nodiscard]] std::string_view  toString(LoginRejectReason r) noexcept;
[[nodiscard]] std::string_view  toString(PacketType t) noexcept;

// =============================================================================
// 4. Heartbeat discipline
// -----------------------------------------------------------------------------
// TODO(verify): SoupBinTCP 3.00 §"Heartbeats" — both numbers below.
//   The commonly cited discipline is: send a Client Heartbeat if nothing has
//   been sent for 1 second; declare the session dead if nothing at all has been
//   received for 15 seconds. Missing heartbeats terminates the session, so
//   these are not tuning knobs to guess at — confirm them, and make them
//   configurable (they are: SessionConfig::heartbeat_interval / rx_timeout).
// ⚠️ "Nothing has been sent" includes bytes the FPGA sent. While the fabric
//    owns the send side, the fabric owns the client heartbeat too — see
//    sessiond.hpp §"Send ownership".
// =============================================================================
inline constexpr std::uint32_t kDefaultHeartbeatIntervalMs = 1000;
inline constexpr std::uint32_t kDefaultReceiveTimeoutMs    = 15000;

// =============================================================================
// 5. Login field semantics
// =============================================================================
// TODO(verify): SoupBinTCP 3.00 §"Login Request Packet".
//   Requested Session = all spaces  -> "the currently active session".
//   Requested Sequence Number = 0   -> "start at the end of the session", i.e.
//                                      send me only messages generated from now
//                                      on. Any other value is a replay point.
// ⚠️ Requesting 0 after a mid-day disconnect SILENTLY DISCARDS every fill that
//    happened while we were away. sessiond only ever requests 0 on the first
//    login of a session, and only when the operator configured that policy.
inline constexpr std::uint64_t kSequenceCurrentEnd = 0;

// =============================================================================
// 6. Encoding / decoding
// =============================================================================

// Fixed-width ASCII helpers. Return false rather than truncate — a truncated
// username is a login reject at 09:29:58.
[[nodiscard]] bool setAsciiLeft(std::span<char> field, std::string_view value) noexcept;
[[nodiscard]] bool setAsciiRightNumeric(std::span<char> field, std::uint64_t value) noexcept;

// Tolerant parse: skips leading/trailing spaces, requires >= 1 digit, rejects
// overflow. Never throws.
[[nodiscard]] bool parseAsciiUint(std::span<const char> field, std::uint64_t& out) noexcept;

// Trim trailing spaces from a fixed-width ASCII field.
[[nodiscard]] std::string_view trimAscii(std::span<const char> field) noexcept;

struct LoginCredentials {
    std::string_view username;
    std::string_view password;           // ⚠️ never logged
    std::string_view requested_session;  // empty -> "current session" (spaces)
};

// Build a complete Login Request packet into `out`. Returns bytes written, or 0
// if `out` is too small or a field does not fit.
[[nodiscard]] std::size_t encodeLoginRequest(std::span<std::uint8_t> out,
                                             const LoginCredentials& cred,
                                             std::uint64_t requested_sequence) noexcept;

// Build a payload-less packet (Client Heartbeat, Logout Request). 3 bytes.
[[nodiscard]] std::size_t encodeEmptyPacket(std::span<std::uint8_t> out,
                                            PacketType type) noexcept;

// Build an Unsequenced Data packet wrapping an already-encoded OUCH message.
// ⚠️ sessiond DOES NOT USE THIS TO SEND ORDERS. There is no software path that
//    emits an order (host/README.md §3.2) — orders are spliced and emitted by
//    the fabric, downstream of the hardware risk gate. This exists so the
//    template builder and the unit tests can produce the exact framing the
//    fabric must produce, and so a conformance harness can be byte-compared
//    against it.
[[nodiscard]] std::size_t encodeUnsequencedData(std::span<std::uint8_t> out,
                                                std::span<const std::uint8_t> ouch_msg) noexcept;

// ---- Inbound framing --------------------------------------------------------
enum class FrameStatus : std::uint8_t {
    Ok,          // `out` is a complete packet
    Incomplete,  // need more bytes; call again after another read
    Malformed,   // length field is illegal or absurd — the stream is corrupt
};

struct Packet {
    PacketType                     type{};
    std::span<const std::uint8_t>  payload{};
    std::size_t                    frame_bytes{0};  // header + payload, to consume
};

// Frame one packet out of the front of `in`. Does not copy.
[[nodiscard]] FrameStatus nextPacket(std::span<const std::uint8_t> in, Packet& out) noexcept;

struct LoginAccepted {
    char          session[10]{};
    std::uint64_t next_sequence{0};
};

[[nodiscard]] bool decodeLoginAccepted(std::span<const std::uint8_t> payload,
                                       LoginAccepted& out) noexcept;

}  // namespace trading::sessiond::soup
