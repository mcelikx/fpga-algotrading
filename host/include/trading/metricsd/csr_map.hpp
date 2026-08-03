// =============================================================================
// csr_map.hpp — BAR0 byte offsets and status-word decode, AS THE RTL DEFINES THEM
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : metricsd
//
// -----------------------------------------------------------------------------
// ⚠⚠ WHY THIS FILE EXISTS AND WHY IT IS NOT A REGMAP.HPP FORK
//
//   host/include/trading/regmap.hpp is, and remains, the single place host code
//   gets an offset. This file does not replace it and does not redefine a
//   single register regmap.hpp gets right.
//
//   It exists because regmap.hpp was written before rtl/ctrl/csr_regfile.sv
//   landed, and it currently disagrees with the hardware about the BAR geometry:
//
//     | thing                  | regmap.hpp        | csr_regfile.sv (REAL)    |
//     | ---------------------- | ----------------- | ------------------------ |
//     | BAR size               | 0x10_0000 (1 MiB) | BAR_ADDR_W=16 -> 64 KiB  |
//     | CONTROL block base     | 0x0_1000          | 0x000 core page          |
//     | STATUS / health word   | 0x0_101C          | 0x014                    |
//     | telemetry window base  | 0x8_0000          | 0x800                    |
//     | telemetry window size  | 0x4_0000 (256 KiB)| 0x400 (256 WORDS)        |
//
//   Reading regmap::TELEM_FEED.offset (0x80030) on real hardware does not read
//   the feed counters. It reads an unmapped offset and returns 0xDEAD_C0DE — or,
//   on a smaller BAR, faults. Publishing that number as `ft_feed_msgs_in_total`
//   is precisely the failure mode manuals/06-operations/03-monitoring-and-
//   telemetry.md exists to prevent: telemetry that is WRONG rather than absent.
//
//   So metricsd takes:
//     * WORD INDICES from regmap::telem_word::  — those come from
//       telemetry_pkg.sv and are RTL-correct, and the brief requires building on
//       them rather than re-deriving offsets;
//     * the WINDOW BASE and the CSR page from rtl/ctrl/csr_regfile.sv, below.
//
//   `kRegmapAgreesWithRtl` is exported as a metric and logged at startup so the
//   disagreement is visible in production rather than living in a comment. When
//   agent 1 reconciles regmap.hpp, delete this file's offsets and switch the
//   aliases at the bottom to regmap:: — nothing else changes.
//
// TODO(rtl-contract): derived from rtl/ctrl/csr_regfile.sv's header register
// map (the file says "The register map below is the HOST-SOFTWARE CONTRACT").
// Delete in favour of regmap.hpp once regmap.hpp is reconciled against it.
//
// -----------------------------------------------------------------------------
// ⚠ metricsd NEVER WRITES ANY REGISTER ON THIS PAGE.
//   Not CONTROL[4] reset_counters (that would destroy every counter under the
//   feet of every other consumer, and manual 06/03 §9 forbids clear-on-read for
//   the same reason). Not CONTROL[6] clr_sticky (sticky bits are cleared at
//   start of day BY CTRLD, after logging the values). Not LOG_RING_TAIL. Not
//   SCRATCH. The offsets below are declared for reading only, and the scraper
//   has no write path at all — see scraper.hpp.
// =============================================================================
#ifndef TRADING_METRICSD_CSR_MAP_HPP
#define TRADING_METRICSD_CSR_MAP_HPP

#include <cstdint>
#include <string_view>

#include "trading/regmap.hpp"
#include "trading/types.hpp"

namespace trading::metricsd {

// =============================================================================
// 1. Core page (0x000-0x0FF) — read-only use only
// =============================================================================
namespace csr {

inline constexpr std::uint32_t BUILD_ID        = 0x000;  // ⚠ the arm gate
inline constexpr std::uint32_t GIT_SHA         = 0x004;
inline constexpr std::uint32_t BUILD_TIMESTAMP = 0x008;
inline constexpr std::uint32_t MAP_VERSION     = 0x00C;  // {MAGIC, MAJOR, MINOR}
inline constexpr std::uint32_t CONTROL         = 0x010;  // ⚠ never written here
inline constexpr std::uint32_t STATUS          = 0x014;  // THE health register
inline constexpr std::uint32_t WATCHDOG_CFG    = 0x01C;  // {warn_ms, timeout_ms}
inline constexpr std::uint32_t KILL_SRC        = 0x020;  // sticky provenance
inline constexpr std::uint32_t KILL_COUNT      = 0x024;
inline constexpr std::uint32_t HEARTBEAT_AGE   = 0x028;  // ms; resets to 0xFFFF
inline constexpr std::uint32_t PARAM_GEN       = 0x030;  // {strat_gen, risk_gen}
inline constexpr std::uint32_t PARAM_STATUS    = 0x034;
inline constexpr std::uint32_t CFG_ERR         = 0x038;
inline constexpr std::uint32_t ARM_STATE       = 0x03C;
inline constexpr std::uint32_t LOG_RING_HEAD   = 0x04C;  // in RECORDS
inline constexpr std::uint32_t LOG_RING_TAIL   = 0x050;  // in RECORDS
inline constexpr std::uint32_t LOG_DROP_CNT    = 0x054;  // ⚠ alertable
inline constexpr std::uint32_t LOG_REC_CNT     = 0x058;
inline constexpr std::uint32_t LOG_FULL_CNT    = 0x060;
inline constexpr std::uint32_t TELEM_ERR_CNT   = 0x064;  // ⚠ telemetry read timeouts

// The two sentinels. Both are deliberately non-zero so a host reading the wrong
// place finds out instead of believing a plausible bank of zeros.
inline constexpr std::uint32_t UNMAPPED_SENTINEL = 0xDEAD'C0DEu;  // bad offset
inline constexpr std::uint32_t TELEM_TIMEOUT_SENTINEL = 0xDEAD'DEADu;  // core wedged

[[nodiscard]] constexpr bool isSentinel(std::uint32_t v) noexcept {
    return v == UNMAPPED_SENTINEL || v == TELEM_TIMEOUT_SENTINEL;
}

// -----------------------------------------------------------------------------
// The telemetry read window. 256 WORDS at 0x800..0xBFC, read-only, proxied to
// telem_raddr/telem_rdata in the core clock domain.
//     word index = (byte offset - 0x800) >> 2      -- csr_regfile.sv line ~87
// The word map itself is rtl/telemetry/telemetry_pkg.sv, mirrored in
// regmap::telem_word:: — use those constants, never a literal.
// -----------------------------------------------------------------------------
inline constexpr std::uint32_t TELEM_WINDOW_BASE = 0x800;
inline constexpr std::uint32_t TELEM_WINDOW_WORDS = 256;
inline constexpr std::uint32_t TELEM_WINDOW_BYTES = TELEM_WINDOW_WORDS * 4;

[[nodiscard]] constexpr std::uint32_t telemByte(std::uint32_t wordIndex) noexcept {
    return TELEM_WINDOW_BASE + (wordIndex << 2);
}
[[nodiscard]] constexpr bool telemWordValid(std::uint32_t wordIndex) noexcept {
    return wordIndex < TELEM_WINDOW_WORDS;
}

// telemetry_pkg.sv reserves 0x00FF as the top of the map and the CSR decodes
// reg_addr[9:2] — exactly 8 bits — so the whole map fits and nothing above
// TELEM_A_LAST is reachable.
static_assert(regmap::telem_word::LAST < TELEM_WINDOW_WORDS,
              "telemetry_pkg.sv map does not fit csr_regfile.sv's 256-word window");
static_assert(telemByte(regmap::telem_word::LAST) == 0xBFC,
              "telemetry window arithmetic disagrees with csr_regfile.sv 0x800-0xBFC");

// -----------------------------------------------------------------------------
// The disagreement, made observable. Exported as ft_host_regmap_agrees so an
// operator sees it on the dashboard rather than discovering it in an incident.
// -----------------------------------------------------------------------------
inline constexpr bool kRegmapTelemBaseAgrees = (regmap::TELEM_BASE == TELEM_WINDOW_BASE);
inline constexpr bool kRegmapStatusAgrees = (regmap::CTRL_HEALTH.offset == STATUS);
inline constexpr bool kRegmapAgreesWithRtl = kRegmapTelemBaseAgrees && kRegmapStatusAgrees;

}  // namespace csr

// =============================================================================
// 2. STATUS (0x014) — the health register
// -----------------------------------------------------------------------------
// mirrors rtl/ctrl/csr_regfile.sv "STATUS (0x014) bit table".
//
// ⚠ This SUPERSEDES manuals/06-operations/03-monitoring-and-telemetry.md §4 and
//   trading::health::, which describe a different 16-bit assignment. The manual
//   §4 table has ALL_OK at bit 0; the RTL has link_up there. Decoding a real
//   STATUS word with the manual's table reports "all ok" whenever market data
//   feed A is up, which is worse than useless. Where they differ, the RTL wins
//   (CLAUDE.md §6). The manual's table should be corrected.
//
//   Bits the manual has and the RTL does not: seq_gap, unknown_msg,
//   book_integrity, fifo_overflow, cdc_error, overtemp_warn, overtemp_crit,
//   param_crc_mismatch, pcie_error, session_down, rate_limited. Several of those
//   are recoverable from the telemetry counters (see telemetry_map.hpp) and
//   metricsd synthesises them there; die temperature is NOT instrumented
//   anywhere in this design and is reported as a coverage gap.
// =============================================================================
namespace status {

inline constexpr unsigned LINK_LSB = 0;      // [2:0] {oe, md_b, md_a}
inline constexpr unsigned LINK_W = 3;
inline constexpr unsigned KILL_ACTIVE = 3;
inline constexpr unsigned KILL_SRC_LSB = 4;  // [6:4] kill_src_e, LIVE
inline constexpr unsigned PCIE_LINK_UP = 7;
inline constexpr unsigned CORE_ALIVE = 8;    // ⚠ core_clk domain is running
inline constexpr unsigned ARM_STATE_LSB = 9;  // [11:9]
inline constexpr unsigned TRADING_EN_EFF = 12;
inline constexpr unsigned WATCHDOG_EXPIRED = 13;  // ⚠ Tier 1
inline constexpr unsigned PARAMS_VALID = 14;
inline constexpr unsigned CFG_WR_BUSY = 15;
inline constexpr unsigned RISK_VALID = 16;
inline constexpr unsigned STRAT_VALID = 17;
inline constexpr unsigned FILTER_VALID = 18;
inline constexpr unsigned TMPL_VALID = 19;
inline constexpr unsigned SESSION_VALID = 20;
inline constexpr unsigned LOG_DROP_STICKY = 21;      // ⚠ audit records LOST
inline constexpr unsigned TELEM_TIMEOUT_STICKY = 22;  // ⚠ core did not answer
inline constexpr unsigned CFG_ERR_STICKY = 23;       // ⚠ a write was rejected
inline constexpr unsigned WATCHDOG_WARN = 24;

inline constexpr unsigned N_BITS = 25;

[[nodiscard]] constexpr bool bit(std::uint32_t s, unsigned b) noexcept {
    return ((s >> b) & 1u) != 0;
}
[[nodiscard]] constexpr std::uint32_t linkMask(std::uint32_t s) noexcept {
    return (s >> LINK_LSB) & 0x7u;
}
[[nodiscard]] constexpr KillSrc liveKillSrc(std::uint32_t s) noexcept {
    return static_cast<KillSrc>((s >> KILL_SRC_LSB) & 0x7u);
}
[[nodiscard]] constexpr std::uint32_t armState(std::uint32_t s) noexcept {
    return (s >> ARM_STATE_LSB) & 0x7u;
}

// Link bit positions inside linkMask(), matching fpga_top.sv's concatenation
// {oe_link_up, md_link_up[1], md_link_up[0]}.
inline constexpr unsigned LINK_MD_A = 0;
inline constexpr unsigned LINK_MD_B = 1;
inline constexpr unsigned LINK_OE = 2;

// A named STATUS bit, for decode-to-metric and for the health dashboard zone.
// `healthy` is the value the bit takes when nothing is wrong: some of these are
// "bad when set" (watchdog_expired) and some are "bad when clear" (core_alive).
struct StatusBit {
    unsigned bit;
    std::string_view name;   // metric label value; lower_snake
    bool healthyValue;       // the value that means "fine"
    bool tier1;              // pages a human when unhealthy (manual §7 Tier 1)
    std::string_view help;
};

// clang-format off
inline constexpr std::array<StatusBit, N_BITS - 3 + 1> kStatusBits{{
    // link_up is decoded per port below rather than as a 3-bit field.
    {KILL_ACTIVE,           "kill_active",           false, true,
     "risk gate is suppressing all outbound orders"},
    {PCIE_LINK_UP,          "pcie_link_up",          true,  true,
     "PCIe link is up as seen by the fabric"},
    {CORE_ALIVE,            "core_alive",            true,  true,
     "core_clk domain is running; if clear the datapath is wedged"},
    {TRADING_EN_EFF,        "trading_en_effective",  true,  false,
     "CONTROL[0] AND armed - the only state in which orders can leave"},
    {WATCHDOG_EXPIRED,      "watchdog_expired",      false, true,
     "host heartbeat stale past WATCHDOG_MS; the fabric has forced a disarm"},
    {PARAMS_VALID,          "params_valid",          true,  true,
     "every config window is committed and marked valid"},
    {CFG_WR_BUSY,           "cfg_wr_busy",           false, false,
     "config write path has not drained"},
    {RISK_VALID,            "risk_valid",            true,  true,
     "risk parameter window committed and valid"},
    {STRAT_VALID,           "strat_valid",           true,  false,
     "strategy parameter window committed and valid"},
    {FILTER_VALID,          "filter_valid",          true,  false,
     "symbol filter window committed and valid"},
    {TMPL_VALID,            "tmpl_valid",            true,  false,
     "session header template committed and valid"},
    {SESSION_VALID,         "session_valid",         true,  false,
     "session window committed and valid"},
    {LOG_DROP_STICKY,       "log_drop_sticky",       false, true,
     "audit log records were LOST - a hole in the CAT trail"},
    {TELEM_TIMEOUT_STICKY,  "telem_timeout_sticky",  false, true,
     "a telemetry read was not answered by the core domain"},
    {CFG_ERR_STICKY,        "cfg_err_sticky",        false, false,
     "at least one config write was rejected"},
    {WATCHDOG_WARN,         "watchdog_warn",         false, false,
     "host heartbeat older than WATCHDOG_WARN_MS"},
    // Padding entry so the array size is a named expression rather than a
    // magic number; see the static_assert below.
    {ARM_STATE_LSB,         "arm_state_lsb",         true,  false,
     "low bit of the 3-bit arm state; decoded separately as ft_host_arm_state"},
}};
// clang-format on
static_assert(kStatusBits.size() == 17, "kStatusBits length changed - update consumers");

[[nodiscard]] constexpr std::string_view armStateName(std::uint32_t s) noexcept {
    switch (s) {
        case 0: return "DISARMED";
        case 1: return "STEP1";
        case 2: return "ARMED";
        case 3: return "FAULT";
        default: return "UNKNOWN";
    }
}

}  // namespace status

// =============================================================================
// 3. KILL_SRC (0x020) — sticky kill provenance
// -----------------------------------------------------------------------------
// mirrors rtl/ctrl/csr_regfile.sv "KILL_SRC (0x020) bit table".
//
//   [2:0]   last_kill_src   provenance of the MOST RECENT kill
//   [3]     kill_active     live
//   [10:8]  first_kill_src  provenance of the FIRST kill since reset
//   [23:16] ever_mask       bit n = kill_src_e value n has fired at least once
//
// ⚠ WHY FIRST AND LAST ARE BOTH EXPORTED, SEPARATELY.
//   Kills cascade. A position breach trips the kill; the kill drops the venue
//   session; the dropped session trips LINK_DOWN; LINK_DOWN re-asserts the kill.
//   `last_kill_src` then says LINK_DOWN, which is the consequence, and the
//   operator spends the incident chasing an optic. `first_kill_src` says
//   POS_BREACH, which is the cause. Exporting only one of them is exporting the
//   wrong one half the time.
//
// ⚠ WHY ever_mask IS A COUNTER-COVERAGE INSTRUMENT, NOT A CURIOSITY.
//   The RTL header states it directly: "A source that has never fired is a
//   control you have never actually tested." That is manual 06/03 §1.3 ("a
//   counter that never moves is a bug you haven't found yet") applied to the
//   single most safety-critical control in the system. metricsd exports one
//   gauge per kill source and folds the never-fired ones into the zero-counter
//   report, so the untested-control list is generated rather than remembered.
// =============================================================================
namespace killsrc {

inline constexpr unsigned LAST_LSB = 0;
inline constexpr unsigned ACTIVE = 3;
inline constexpr unsigned FIRST_LSB = 8;
inline constexpr unsigned EVER_MASK_LSB = 16;
inline constexpr std::uint32_t SRC_MASK = 0x7u;
inline constexpr std::uint32_t EVER_MASK = 0xFFu;

[[nodiscard]] constexpr KillSrc last(std::uint32_t w) noexcept {
    return static_cast<KillSrc>((w >> LAST_LSB) & SRC_MASK);
}
[[nodiscard]] constexpr KillSrc first(std::uint32_t w) noexcept {
    return static_cast<KillSrc>((w >> FIRST_LSB) & SRC_MASK);
}
[[nodiscard]] constexpr bool active(std::uint32_t w) noexcept {
    return ((w >> ACTIVE) & 1u) != 0;
}
[[nodiscard]] constexpr std::uint32_t everMask(std::uint32_t w) noexcept {
    return (w >> EVER_MASK_LSB) & EVER_MASK;
}
[[nodiscard]] constexpr bool everFired(std::uint32_t w, KillSrc s) noexcept {
    return (everMask(w) >> static_cast<unsigned>(s)) & 1u;
}

// The ever_mask is 8 bits wide and kill_src_e has exactly 8 values. If that ever
// stops being true the mask silently truncates and a source becomes invisible.
static_assert(N_KILL_SRC == 8, "KILL_SRC ever_mask is 8 bits; kill_src_e must be 8 values");

}  // namespace killsrc

// =============================================================================
// 4. CFG_ERR (0x038) bit positions — mirrors csr_regfile.sv E_* localparams
// =============================================================================
namespace cfgerr {
inline constexpr unsigned PROTECTED = 0;  // write attempted while trading enabled
inline constexpr unsigned QUEUE = 1;      // config write queue overflow
inline constexpr unsigned ARM_SEQ = 2;    // arm_step2 without step1, or both at once
inline constexpr unsigned ARM_PRE = 3;    // arm attempted, preconditions unmet
inline constexpr unsigned UNMAPPED = 4;   // write to an unmapped offset
inline constexpr unsigned RING_CFG = 5;   // illegal ring size / base
inline constexpr unsigned TELEM_TO = 6;   // telemetry read timed out
inline constexpr unsigned N_BITS = 7;

inline constexpr std::array<std::string_view, N_BITS> kNames{
    {"protected", "queue", "arm_seq", "arm_pre", "unmapped", "ring_cfg", "telem_timeout"}};
}  // namespace cfgerr

// =============================================================================
// 5. Watchdog thresholds, for alert rule generation
// -----------------------------------------------------------------------------
// Defaults from csr_regfile.sv parameters. The live values are readable at
// WATCHDOG_CFG = {warn_ms[31:16], timeout_ms[15:0]} and metricsd exports both,
// so an alert rule can be written against the value the card is actually
// running rather than against a constant that drifted.
// =============================================================================
namespace watchdog {
inline constexpr std::uint32_t DEFAULT_WARN_MS = 50;
inline constexpr std::uint32_t DEFAULT_TIMEOUT_MS = 100;
inline constexpr std::uint32_t HEARTBEAT_AGE_RESET = 0xFFFF;  // already expired

[[nodiscard]] constexpr std::uint32_t warnMs(std::uint32_t cfg) noexcept { return cfg >> 16; }
[[nodiscard]] constexpr std::uint32_t timeoutMs(std::uint32_t cfg) noexcept {
    return cfg & 0xFFFFu;
}
}  // namespace watchdog

}  // namespace trading::metricsd

#endif  // TRADING_METRICSD_CSR_MAP_HPP
