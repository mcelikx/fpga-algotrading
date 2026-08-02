// =============================================================================
// config.hpp — sessiond runtime configuration
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : host/src/sessiond
//
// ⚠️⚠️  NOTHING IN THIS STRUCT HAS A DEFAULT THAT COULD REACH A VENUE.  ⚠️⚠️
//
// host/README.md §3.5 and CLAUDE.md §6: no production credentials, comp IDs,
// session IDs or venue IPs in the repository. Every field below that identifies
// a venue, an account or a session is REQUIRED, has NO default, and comes from
// a gitignored config file. `validate()` refuses to run without them — there is
// deliberately no "sensible default" path that silently points at something.
//
// The committed template is host/config/sessiond.yaml.example (owned by the
// build/config agent — the required keys are listed against each field below).
//
// ⚠️ `password` is never logged. Use redactedSummary() for anything that reaches
//    a log, a metric label, an alert or a core dump annotation.
// =============================================================================
#pragma once

#include <array>
#include <chrono>
#include <cstdint>
#include <string>
#include <string_view>

#include "trading/sessiond/session_state.hpp"
#include "trading/sessiond/soupbin.hpp"

namespace trading::sessiond {

// -----------------------------------------------------------------------------
// Where the venue replay should start on the FIRST login of a session.
// (Every RE-login always requests the next sequence number we actually need —
// that is not a policy choice, it is the only correct value.)
// -----------------------------------------------------------------------------
enum class StartSequencePolicy : std::uint8_t {
    // Request 0 = "send me only what happens from now on".
    // ⚠️ Discards everything the venue already generated in this session. Only
    //    correct for the first login of the trading day, on a session with no
    //    prior orders.
    CurrentEnd = 0,
    // Request 1 = replay the entire session from the beginning. Correct after a
    // host restart when the order database must be rebuilt from the venue's
    // authoritative stream.
    ReplayAll = 1,
    // Request an operator-supplied number. Used only in recovery drills.
    Explicit = 2,
};

// -----------------------------------------------------------------------------
// A resolved MAC address. Sourced from config (static ARP entry), never from an
// ARP exchange — manuals/02-networking/02-ip-udp-tcp-in-hardware.md §7: the
// FPGA never originates ARP, and the destination MAC is baked into the template.
// -----------------------------------------------------------------------------
using MacAddress = std::array<std::uint8_t, 6>;

struct SessionConfig {
    // ── Venue endpoint ───────────────────────────────────────────────────────
    // YAML: sessiond.venue.host   (string, IPv4 dotted quad — REQUIRED)
    // YAML: sessiond.venue.port   (uint16 — REQUIRED)
    // ⚠️ CLAUDE.md §6: UAT / conformance endpoints only unless the user has
    //    explicitly and specifically instructed otherwise for a given task.
    std::string   venue_host;
    std::uint16_t venue_port = 0;

    // YAML: sessiond.venue.is_production (bool, default false)
    // Purely a guard: when false, sessiond logs loudly if the endpoint looks
    // like production and refuses to arm the fabric without
    // `allow_production_arm`.
    bool is_production = false;
    // YAML: sessiond.venue.allow_production_arm (bool, default false)
    bool allow_production_arm = false;

    // ── Local endpoint ───────────────────────────────────────────────────────
    // YAML: sessiond.local.bind_ip   (string IPv4 — REQUIRED; the source address
    //                                 that must also appear in the TX template)
    // YAML: sessiond.local.bind_port (uint16, default 0 = ephemeral)
    std::string   local_bind_ip;
    std::uint16_t local_bind_port = 0;

    // ── Layer 2, for the frame template ──────────────────────────────────────
    // YAML: sessiond.l2.src_mac (string "aa:bb:cc:dd:ee:ff" — REQUIRED)
    // YAML: sessiond.l2.dst_mac (string — REQUIRED, the venue gateway's MAC from
    //                            the static ARP entry)
    MacAddress src_mac{};
    MacAddress dst_mac{};

    // ── Credentials ⚠️ gitignored config only ────────────────────────────────
    // YAML: sessiond.login.username          (string, <= 6 chars — REQUIRED)
    // YAML: sessiond.login.password          (string, <= 10 chars — REQUIRED)
    // YAML: sessiond.login.requested_session (string, <= 10 chars, default ""
    //                                         = the currently active session)
    std::string username;
    std::string password;            // ⚠️ never logged, never in an error string
    std::string requested_session;

    // ── Sequencing ───────────────────────────────────────────────────────────
    // YAML: sessiond.sequence.start_policy      ("current_end"|"replay_all"|"explicit")
    // YAML: sessiond.sequence.explicit_start    (uint64, required iff explicit)
    StartSequencePolicy start_policy    = StartSequencePolicy::ReplayAll;
    std::uint64_t       explicit_start  = 0;

    // ── Timers ───────────────────────────────────────────────────────────────
    // YAML: sessiond.timers.heartbeat_interval_ms (uint32, default 1000)
    // YAML: sessiond.timers.rx_timeout_ms         (uint32, default 15000)
    // YAML: sessiond.timers.connect_timeout_ms    (uint32, default 5000)
    // YAML: sessiond.timers.login_timeout_ms      (uint32, default 5000)
    // TODO(verify): SoupBinTCP 3.00 §"Heartbeats" — the 1 s / 15 s discipline.
    std::chrono::milliseconds heartbeat_interval{soup::kDefaultHeartbeatIntervalMs};
    std::chrono::milliseconds rx_timeout{soup::kDefaultReceiveTimeoutMs};
    std::chrono::milliseconds connect_timeout{5000};
    std::chrono::milliseconds login_timeout{5000};

    // ── Reconnection ─────────────────────────────────────────────────────────
    // YAML: sessiond.reconnect.backoff_initial_ms (uint32, default 250)
    // YAML: sessiond.reconnect.backoff_max_ms     (uint32, default 5000)
    // YAML: sessiond.reconnect.max_attempts       (uint32, default 5; 0 = no auto retry)
    std::chrono::milliseconds backoff_initial{250};
    std::chrono::milliseconds backoff_max{5000};
    std::uint32_t             max_reconnect_attempts = 5;

    // ── TX frame template parameters ─────────────────────────────────────────
    // YAML: sessiond.template.ip_ttl        (uint8,  default 64)
    // YAML: sessiond.template.ip_dscp       (uint8,  default 0)
    // YAML: sessiond.template.tcp_window    (uint16 — REQUIRED)
    //   ⚠️ This is the receive window the FABRIC advertises on every segment it
    //      sends. It is FIXED for the life of the template while the host's real
    //      window moves. Configure it CONSERVATIVELY — at or below the smallest
    //      window the host stack will ever advertise — or we promise the venue
    //      buffer space we do not have.
    // YAML: sessiond.template.ip_id_base    (uint16, default 0)
    std::uint8_t  ip_ttl       = 64;
    std::uint8_t  ip_dscp      = 0;
    std::uint16_t tcp_window   = 0;
    std::uint16_t ip_id_base   = 0;

    // ── Operational expectations (asserted, not assumed) ─────────────────────
    // YAML: sessiond.venue.cancel_on_disconnect (bool — REQUIRED, and it must be
    //   the value the venue has in writing for OUR ports).
    // ⚠️ manuals/08-nasdaq/05-ouch-5.0-order-entry.md §10: both settings are
    //    dangerous in different ways. sessiond does not change behaviour based
    //    on this; it logs it at every session start so the value in the incident
    //    timeline is the value that was actually configured.
    bool cancel_on_disconnect = false;

    // ── Validation ───────────────────────────────────────────────────────────
    // Checks presence and shape of everything above. Never logs the password.
    [[nodiscard]] SessionError validate() const noexcept;

    // A one-line summary safe for logs. The password is replaced with a fixed
    // literal — never a length, never a hash, never a prefix.
    [[nodiscard]] std::string redactedSummary() const;
};

// Parsers used by whoever loads the YAML. Return false on any malformed input;
// they never throw and never partially write their output.
[[nodiscard]] bool parseMac(std::string_view text, MacAddress& out) noexcept;
[[nodiscard]] bool parseIpv4(std::string_view text, std::uint32_t& out_host_order) noexcept;
[[nodiscard]] bool parseStartPolicy(std::string_view text, StartSequencePolicy& out) noexcept;

// Formats an IPv4 address held in host byte order. For logs and diagnostics.
[[nodiscard]] std::string formatIpv4(std::uint32_t host_order);

}  // namespace trading::sessiond
