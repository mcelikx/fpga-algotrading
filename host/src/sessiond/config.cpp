// =============================================================================
// config.cpp — sessiond configuration validation and redaction
// -----------------------------------------------------------------------------
// ⚠️ The password never leaves this file except as the literal "<redacted>".
//    Not its length, not a prefix, not a hash. See host/README.md §3.5.
// =============================================================================
#include "trading/sessiond/config.hpp"

#include <cctype>
#include <cstdio>
#include <limits>

namespace trading::sessiond {
namespace {

[[nodiscard]] bool hexNibble(char c, std::uint8_t& out) noexcept {
    if (c >= '0' && c <= '9') { out = static_cast<std::uint8_t>(c - '0');        return true; }
    if (c >= 'a' && c <= 'f') { out = static_cast<std::uint8_t>(c - 'a' + 10);   return true; }
    if (c >= 'A' && c <= 'F') { out = static_cast<std::uint8_t>(c - 'A' + 10);   return true; }
    return false;
}

}  // namespace

bool parseMac(std::string_view text, MacAddress& out) noexcept {
    // Exactly "xx:xx:xx:xx:xx:xx" or "xx-xx-xx-xx-xx-xx". Nothing else: a MAC
    // that parses loosely is a MAC that ends up wrong in the TX template, and a
    // wrong destination MAC means every order goes to the wrong place.
    if (text.size() != 17) {
        return false;
    }
    MacAddress tmp{};
    for (std::size_t i = 0; i < 6; ++i) {
        const std::size_t p = i * 3;
        std::uint8_t hi = 0;
        std::uint8_t lo = 0;
        if (!hexNibble(text[p], hi) || !hexNibble(text[p + 1], lo)) {
            return false;
        }
        if (i < 5) {
            const char sep = text[p + 2];
            if (sep != ':' && sep != '-') {
                return false;
            }
        }
        tmp[i] = static_cast<std::uint8_t>((hi << 4) | lo);
    }
    out = tmp;
    return true;
}

bool parseIpv4(std::string_view text, std::uint32_t& out_host_order) noexcept {
    std::uint32_t acc    = 0;
    std::uint32_t octet  = 0;
    int           digits = 0;
    int           parts  = 0;

    for (std::size_t i = 0; i <= text.size(); ++i) {
        const bool end = (i == text.size());
        const char c   = end ? '.' : text[i];
        if (c == '.') {
            if (digits == 0 || digits > 3 || octet > 255 || parts == 4) {
                return false;
            }
            acc    = (acc << 8) | octet;
            octet  = 0;
            digits = 0;
            ++parts;
        } else if (c >= '0' && c <= '9') {
            octet = octet * 10 + static_cast<std::uint32_t>(c - '0');
            if (++digits > 3) {
                return false;
            }
        } else {
            return false;
        }
    }
    if (parts != 4) {
        return false;
    }
    out_host_order = acc;
    return true;
}

bool parseStartPolicy(std::string_view text, StartSequencePolicy& out) noexcept {
    if (text == "current_end") { out = StartSequencePolicy::CurrentEnd; return true; }
    if (text == "replay_all")  { out = StartSequencePolicy::ReplayAll;  return true; }
    if (text == "explicit")    { out = StartSequencePolicy::Explicit;   return true; }
    return false;
}

std::string formatIpv4(std::uint32_t host_order) {
    char buf[16];
    const int n = std::snprintf(buf, sizeof(buf), "%u.%u.%u.%u",
                                (host_order >> 24) & 0xFFU,
                                (host_order >> 16) & 0xFFU,
                                (host_order >> 8) & 0xFFU,
                                host_order & 0xFFU);
    return (n > 0) ? std::string(buf, static_cast<std::size_t>(n)) : std::string{};
}

SessionError SessionConfig::validate() const noexcept {
    // ── presence: no venue, no account, no session without explicit config ──
    if (venue_host.empty() || venue_port == 0 || local_bind_ip.empty() ||
        username.empty() || password.empty()) {
        return SessionError::NotConfigured;
    }
    // tcp_window has no safe default: the fabric advertises it on every segment.
    if (tcp_window == 0) {
        return SessionError::NotConfigured;
    }

    std::uint32_t ip = 0;
    if (!parseIpv4(venue_host, ip) || !parseIpv4(local_bind_ip, ip)) {
        return SessionError::InvalidConfig;
    }

    // Wire-field widths. Overlong values cannot be truncated (soupbin.cpp
    // refuses), so catch them at load time rather than at 09:29:58.
    if (username.size() > sizeof(soup::LoginRequestPayload::username) ||
        password.size() > sizeof(soup::LoginRequestPayload::password) ||
        requested_session.size() > sizeof(soup::LoginRequestPayload::requested_session)) {
        return SessionError::InvalidConfig;
    }

    if (start_policy == StartSequencePolicy::Explicit && explicit_start == 0) {
        // 0 means "current end", which is not what "explicit" asked for.
        return SessionError::InvalidConfig;
    }

    if (heartbeat_interval.count() <= 0 || rx_timeout.count() <= 0 ||
        connect_timeout.count() <= 0 || login_timeout.count() <= 0) {
        return SessionError::InvalidConfig;
    }
    // ⚠️ A receive timeout at or below the heartbeat interval declares the
    //    session dead between two healthy heartbeats.
    if (rx_timeout <= heartbeat_interval) {
        return SessionError::InvalidConfig;
    }
    if (backoff_max < backoff_initial) {
        return SessionError::InvalidConfig;
    }

    // A MAC of all zeroes is not a resolved static ARP entry, it is an unset
    // field. The template must never carry it.
    const MacAddress zero{};
    if (src_mac == zero || dst_mac == zero) {
        return SessionError::NotConfigured;
    }

    // CLAUDE.md §6: pointing a build at production is an explicit, deliberate,
    // separately-approved act.
    if (is_production && !allow_production_arm) {
        return SessionError::InvalidConfig;
    }
    return SessionError::None;
}

std::string SessionConfig::redactedSummary() const {
    char macbuf[18];
    std::snprintf(macbuf, sizeof(macbuf), "%02x:%02x:%02x:%02x:%02x:%02x",
                  dst_mac[0], dst_mac[1], dst_mac[2], dst_mac[3], dst_mac[4], dst_mac[5]);

    std::string s;
    s.reserve(256);
    s += "sessiond{venue=";
    s += venue_host;
    s += ':';
    s += std::to_string(venue_port);
    s += " local=";
    s += local_bind_ip;
    s += ':';
    s += std::to_string(local_bind_port);
    s += " gw_mac=";
    s += macbuf;
    s += " user=";
    s += username;                 // the username is an identifier, not a secret
    s += " password=<redacted>";   // ⚠️ always this literal, unconditionally
    s += " session=";
    s += requested_session.empty() ? std::string("<current>") : requested_session;
    s += " start_policy=";
    switch (start_policy) {
        case StartSequencePolicy::CurrentEnd: s += "current_end"; break;
        case StartSequencePolicy::ReplayAll:  s += "replay_all";  break;
        case StartSequencePolicy::Explicit:
            s += "explicit:";
            s += std::to_string(explicit_start);
            break;
    }
    s += " hb=";
    s += std::to_string(heartbeat_interval.count());
    s += "ms rx_timeout=";
    s += std::to_string(rx_timeout.count());
    s += "ms cod=";
    s += cancel_on_disconnect ? "on" : "off";
    s += is_production ? " env=PRODUCTION" : " env=uat";
    s += '}';
    return s;
}

}  // namespace trading::sessiond
