// =============================================================================
// soupbin.cpp — SoupBinTCP 3.00 session-layer encode / decode
// -----------------------------------------------------------------------------
// See host/include/trading/sessiond/soupbin.hpp for the wire-format contract and
// the TODO(verify) list. No exceptions, no allocation, no floating point.
// =============================================================================
#include "trading/sessiond/soupbin.hpp"

#include <algorithm>
#include <cstring>
#include <limits>

namespace trading::sessiond::soup {
namespace {

constexpr char kPad = ' ';

}  // namespace

LoginRejectReason decodeRejectReason(char c) noexcept {
    switch (c) {
        case 'A': return LoginRejectReason::NotAuthorized;
        case 'S': return LoginRejectReason::SessionNotAvailable;
        default:  return LoginRejectReason::Unknown;
    }
}

std::string_view toString(LoginRejectReason r) noexcept {
    switch (r) {
        case LoginRejectReason::NotAuthorized:       return "not-authorized";
        case LoginRejectReason::SessionNotAvailable: return "session-not-available";
        case LoginRejectReason::Unknown:             break;
    }
    return "unknown";
}

std::string_view toString(PacketType t) noexcept {
    switch (t) {
        case PacketType::LoginRequest:    return "LoginRequest";
        case PacketType::UnsequencedData: return "UnsequencedData";
        case PacketType::ClientHeartbeat: return "ClientHeartbeat";
        case PacketType::LogoutRequest:   return "LogoutRequest";
        case PacketType::LoginAccepted:   return "LoginAccepted";
        case PacketType::LoginRejected:   return "LoginRejected";
        case PacketType::SequencedData:   return "SequencedData";
        case PacketType::ServerHeartbeat: return "ServerHeartbeat";
        case PacketType::EndOfSession:    return "EndOfSession";
        case PacketType::Debug:           return "Debug";
    }
    return "Unrecognised";
}

// -----------------------------------------------------------------------------
// ASCII field helpers
// -----------------------------------------------------------------------------
bool setAsciiLeft(std::span<char> field, std::string_view value) noexcept {
    if (value.size() > field.size()) {
        return false;   // ⚠️ never truncate a credential or a session id
    }
    std::memcpy(field.data(), value.data(), value.size());
    std::fill(field.begin() + static_cast<std::ptrdiff_t>(value.size()), field.end(), kPad);
    return true;
}

bool setAsciiRightNumeric(std::span<char> field, std::uint64_t value) noexcept {
    if (field.empty()) {
        return false;
    }
    // Render digits into a scratch buffer, then right-justify. 20 digits is the
    // widest a uint64 can be; the field is 20 wide, so this always fits unless
    // the caller passed a narrower field.
    char scratch[20];
    std::size_t n = 0;
    do {
        scratch[n++] = static_cast<char>('0' + static_cast<char>(value % 10U));
        value /= 10U;
    } while (value != 0U && n < sizeof(scratch));

    if (value != 0U || n > field.size()) {
        return false;
    }
    const std::size_t pad = field.size() - n;
    std::fill(field.begin(), field.begin() + static_cast<std::ptrdiff_t>(pad), kPad);
    for (std::size_t i = 0; i < n; ++i) {
        field[pad + i] = scratch[n - 1 - i];
    }
    return true;
}

bool parseAsciiUint(std::span<const char> field, std::uint64_t& out) noexcept {
    std::size_t i = 0;
    while (i < field.size() && (field[i] == kPad || field[i] == '\0')) {
        ++i;
    }
    std::uint64_t v      = 0;
    std::size_t   digits = 0;
    for (; i < field.size(); ++i) {
        const char c = field[i];
        if (c == kPad || c == '\0') {
            break;   // trailing padding
        }
        if (c < '0' || c > '9') {
            return false;
        }
        const auto d = static_cast<std::uint64_t>(c - '0');
        if (v > (std::numeric_limits<std::uint64_t>::max() - d) / 10U) {
            return false;   // overflow: a 64-bit sequence number cannot be this big
        }
        v = v * 10U + d;
        ++digits;
    }
    // Anything after the trailing padding must also be padding.
    for (; i < field.size(); ++i) {
        if (field[i] != kPad && field[i] != '\0') {
            return false;
        }
    }
    if (digits == 0) {
        return false;
    }
    out = v;
    return true;
}

std::string_view trimAscii(std::span<const char> field) noexcept {
    std::size_t end = field.size();
    while (end > 0 && (field[end - 1] == kPad || field[end - 1] == '\0')) {
        --end;
    }
    return std::string_view(field.data(), end);
}

// -----------------------------------------------------------------------------
// Encoders
// -----------------------------------------------------------------------------
std::size_t encodeLoginRequest(std::span<std::uint8_t> out,
                               const LoginCredentials& cred,
                               std::uint64_t requested_sequence) noexcept {
    if (out.size() < sizeof(LoginRequestPacket)) {
        return 0;
    }
    LoginRequestPacket pkt{};
    pkt.hdr.length.set(static_cast<std::uint16_t>(sizeof(LoginRequestPayload) + kLengthBias));
    pkt.hdr.type = static_cast<std::uint8_t>(PacketType::LoginRequest);

    if (!setAsciiLeft(std::span<char>(pkt.body.username, sizeof(pkt.body.username)),
                      cred.username)) {
        return 0;
    }
    if (!setAsciiLeft(std::span<char>(pkt.body.password, sizeof(pkt.body.password)),
                      cred.password)) {
        return 0;
    }
    // Empty requested session == all spaces == "the currently active session".
    if (!setAsciiLeft(std::span<char>(pkt.body.requested_session,
                                      sizeof(pkt.body.requested_session)),
                      cred.requested_session)) {
        return 0;
    }
    if (!setAsciiRightNumeric(std::span<char>(pkt.body.requested_sequence,
                                              sizeof(pkt.body.requested_sequence)),
                              requested_sequence)) {
        return 0;
    }
    std::memcpy(out.data(), &pkt, sizeof(pkt));
    return sizeof(pkt);
}

std::size_t encodeEmptyPacket(std::span<std::uint8_t> out, PacketType type) noexcept {
    if (out.size() < kHeaderBytes) {
        return 0;
    }
    PacketHeader hdr{};
    hdr.length.set(kLengthBias);   // payload of zero bytes
    hdr.type = static_cast<std::uint8_t>(type);
    std::memcpy(out.data(), &hdr, sizeof(hdr));
    return sizeof(hdr);
}

std::size_t encodeUnsequencedData(std::span<std::uint8_t> out,
                                  std::span<const std::uint8_t> ouch_msg) noexcept {
    const std::size_t total = kHeaderBytes + ouch_msg.size();
    if (out.size() < total || ouch_msg.empty() ||
        (ouch_msg.size() + kLengthBias) > std::numeric_limits<std::uint16_t>::max()) {
        return 0;
    }
    PacketHeader hdr{};
    hdr.length.set(static_cast<std::uint16_t>(ouch_msg.size() + kLengthBias));
    hdr.type = static_cast<std::uint8_t>(PacketType::UnsequencedData);
    std::memcpy(out.data(), &hdr, sizeof(hdr));
    std::memcpy(out.data() + sizeof(hdr), ouch_msg.data(), ouch_msg.size());
    return total;
}

// -----------------------------------------------------------------------------
// Inbound framing
// -----------------------------------------------------------------------------
FrameStatus nextPacket(std::span<const std::uint8_t> in, Packet& out) noexcept {
    if (in.size() < kHeaderBytes) {
        return FrameStatus::Incomplete;
    }
    PacketHeader hdr{};
    std::memcpy(&hdr, in.data(), sizeof(hdr));
    const std::uint16_t len = hdr.length.host();

    // length counts the type byte, so it is >= 1 for every legal packet.
    if (len < kLengthBias) {
        return FrameStatus::Malformed;
    }
    const std::size_t payload_len = static_cast<std::size_t>(len) - kLengthBias;
    const std::size_t frame_bytes = kHeaderBytes + payload_len;
    if (frame_bytes > kMaxPacketBytes) {
        // ⚠️ Do not wait for bytes a corrupt length promised. The stream is not
        //    recoverable by resynchronisation — SoupBinTCP has no framing
        //    marker to resynchronise on. Drop the connection and re-login.
        return FrameStatus::Malformed;
    }
    if (in.size() < frame_bytes) {
        return FrameStatus::Incomplete;
    }
    out.type        = static_cast<PacketType>(hdr.type);
    out.payload     = in.subspan(kHeaderBytes, payload_len);
    out.frame_bytes = frame_bytes;
    return FrameStatus::Ok;
}

bool decodeLoginAccepted(std::span<const std::uint8_t> payload,
                         LoginAccepted& out) noexcept {
    if (payload.size() != sizeof(LoginAcceptedPayload)) {
        return false;
    }
    LoginAcceptedPayload body{};
    std::memcpy(&body, payload.data(), sizeof(body));
    std::memcpy(out.session, body.session, sizeof(out.session));
    return parseAsciiUint(std::span<const char>(body.sequence, sizeof(body.sequence)),
                          out.next_sequence);
}

}  // namespace trading::sessiond::soup
