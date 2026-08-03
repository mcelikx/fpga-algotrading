// =============================================================================
// heartbeat.hpp — the host watchdog kick. THE THREAD THAT KEEPS TRADING LEGAL.
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : host/src/heartbeat
// Governs : host/README.md §2 (`heartbeat`), §3.4, §4 (runtime placement)
//           manuals/06-operations/03-monitoring-and-telemetry.md §4 (watchdog)
//           manuals/08-nasdaq/09-risk-controls-and-limits.md §5 (kill switch)
// Mirrors : rtl/ctrl/csr_regfile.sv  — HEARTBEAT / HEARTBEAT_AGE / WATCHDOG_CFG
//                                      / STATUS / KILL_SRC and their semantics
//           rtl/risk/kill_switch.sv  — the latch this thread's silence trips
//
// =============================================================================
// ⚠⚠⚠  THE LOAD-BEARING PROPERTY. READ THIS BEFORE CHANGING ANYTHING BELOW. ⚠⚠⚠
// =============================================================================
//
//   IF THIS THREAD STALLS, THE HARDWARE KILL SWITCH FIRES AND TRADING STOPS.
//   THAT IS THE ENTIRE POINT OF THIS FILE. IT IS BY DESIGN. IT IS NOT A BUG.
//
// This component exists to be the thing that fails. Every other component in
// host/ exists to do something; this one exists so that when the host stops
// being able to do anything, the machine on the other side of the PCIe bus
// finds out and stops trading without asking permission.
//
// THE REASONING, because a maintainer who does not understand it will "fix" it:
//
//   The FPGA does not know the host is dead. It has no way to know. If this
//   process segfaults, or the box hangs, or the kernel decides to spend 400 ms
//   in a reclaim path, the fabric happily keeps executing the last-loaded
//   strategy against live market data, forever, at line rate. Nobody is doing
//   position accounting. Nobody is reconciling against the drop copy. Nobody
//   can see the P&L. And no human can act, because the process that would have
//   told them something was wrong is the process that died.
//
//   manuals/08-nasdaq/09-risk-controls-and-limits.md §5 states it plainly:
//
//       "The host watchdog is the most important trigger, and it is the one
//        most often implemented wrong. ... A fabric-side countdown that the
//        host must keep refreshing is the only thing standing between a
//        segfault and an unsupervised algorithm."
//
//   So the contract is inverted from ordinary software. This thread's job is
//   not to be reliable. Its job is to be HONEST: to keep beating exactly as
//   long as the host is genuinely healthy, and to go silent the instant it is
//   not. A heartbeat that keeps beating through a stall is worse than no
//   heartbeat at all, because it actively asserts a safety property that is
//   false.
//
// -----------------------------------------------------------------------------
// THINGS THAT MUST NEVER BE ADDED TO THIS COMPONENT
// -----------------------------------------------------------------------------
//   ✗ A watchdog-on-the-watchdog that restarts this thread if it stops.
//   ✗ A supervisor that re-writes HEARTBEAT from another thread if this one is
//     late. (This is the worst one. It converts "the host is sick" into "the
//     host is fine", which is exactly the lie the fabric watchdog exists to
//     detect.)
//   ✗ A grace period, a "catch-up" burst of writes after an overrun, or any
//     backdating of the deadline so a missed tick looks like it happened.
//   ✗ Retry-until-success on a failed MMIO write. One attempt per tick. If the
//     write fails, the tick is LOST and the age climbs — which is correct,
//     because a card that will not accept a BAR write is a card that should
//     stop trading.
//   ✗ Any write to CTRL_KILL / arm_step1 / arm_step2, or any attempt to clear
//     the kill latch. See the next section.
//   ✗ Raising WATCHDOG_CFG to make a stall stop tripping the watchdog. Those
//     thresholds are READ-ONLY synthesis parameters in the RTL, deliberately,
//     and this file only ever reads them.
//
//   The correct response to "the heartbeat stalled" is to find out why the host
//   stalled. It is never to make the heartbeat more forgiving.
//
// -----------------------------------------------------------------------------
// THIS COMPONENT NEVER CLEARS THE KILL LATCH
// -----------------------------------------------------------------------------
//   rtl/risk/kill_switch.sv: "Once triggered, it latches. Clearing requires an
//   explicit, authenticated host write to a distinct clear register — never a
//   timeout, never an auto-recover." The clear is a two-step keyed sequence
//   (CONTROL[2] then CONTROL[3], as SEPARATE bus writes, inside a bounded
//   window, with all triggers clear and a reconciled position loaded).
//
//   That sequence belongs to ctrld and to a human following a runbook. This
//   file has no code path that can perform it: writeAllowed() is a compile-time
//   allow-list of exactly one writable offset (HEARTBEAT), and there are
//   static_asserts below proving CONTROL is not on it.
//
//   Note also that continuing to beat after a watchdog kill does NOT and CANNOT
//   un-kill anything — the latch is in fabric and ignores us. So the loop keeps
//   beating after it observes a kill, deliberately: it keeps HEARTBEAT_AGE
//   meaningful for the operator working the runbook, and it makes "is the host
//   alive?" answerable during the incident.
//
// -----------------------------------------------------------------------------
// THE FABRIC SIDE, AS ACTUALLY BUILT  (rtl/ctrl/csr_regfile.sv)
// -----------------------------------------------------------------------------
//   HEARTBEAT (WO)      The host writes ANY value. THE WRITE IS THE EVENT. It
//                       resets HEARTBEAT_AGE to 0 and emits one pulse to the
//                       core domain. ⚠ The fabric does NOT check that the value
//                       increases. We write an incrementing value anyway — it
//                       makes hb_seq_q a usable host-side debugging landmark —
//                       but no safety property depends on it, and the
//                       FreezeValue drill in fault_inject.hpp exists to keep us
//                       honest about that.
//   HEARTBEAT_AGE (RO)  Milliseconds since the last write. ⚠ RESETS TO 0xFFFF.
//   WATCHDOG_CFG (RO)   {warn_ms[15:0], timeout_ms[15:0]}. Synthesis
//                       parameters. Read them, never write them.
//   STATUS (RO)         bit 13 watchdog_expired, bit 24 watchdog_warn,
//                       bit 3 kill_active, bits 11:9 arm_state.
//   KILL_SRC (RO)       sticky provenance; a watchdog kill latches KILL_WATCHDOG.
//
//       age >= WATCHDOG_WARN_MS  (50 ms)  -> STATUS bit 24, alert
//       age >= WATCHDOG_MS      (100 ms)  -> ⚠ FORCED DISARM: arm_state ->
//                                            DISARMED, kill asserted,
//                                            LOG_WATCHDOG (0x15) record emitted
//
//   ⚠ HEARTBEAT_AGE RESETS TO 0xFFFF, WHICH IS ALREADY PAST THE TIMEOUT.
//     csr_regfile.sv states the consequence, and it is the strongest form of
//     this component's justification:
//
//         "a freshly configured or freshly reset card is watchdog-expired and
//          CANNOT be armed until the host has established a live heartbeat.
//          There is no window in which a rebooting host leaves an armed card
//          behind."
//
//     THEREFORE: this thread must be RUNNING AND VERIFIED before the two-step
//     arm, not merely started somewhere near it. That is not a convention this
//     file is asking for politely; the arm will be REJECTED otherwise. It is
//     why "start heartbeat" is step 6 and "two-step arm" is step 7 in the
//     startup sequence, and why shutdown disables trading BEFORE stopping the
//     heartbeat rather than after.
//
//   ⚠ DEFENCE IN DEPTH — there are TWO watchdogs, not one.
//     csr_regfile runs a millisecond-resolution watchdog in the pcie_clk domain
//     and forces the disarm. Independently, rtl/risk/kill_switch.sv runs its own
//     countdown in the CORE clock domain off the forwarded heartbeat pulse, and
//     BLOCKS in risk_gate. If csr_regfile or the PCIe domain wedges, host_ctrl
//     stops forwarding pulses, and the core-domain watchdog fires on its own
//     without any cooperation from the block that wedged. Neither watchdog is a
//     single point of failure for the other. Do not "simplify" the host to
//     target only one of them.
//
// -----------------------------------------------------------------------------
// RUNTIME PLACEMENT  (host/README.md §4)
// -----------------------------------------------------------------------------
//   Dedicated isolated core (isolcpus / nohz_full), SCHED_FIFO, memory locked,
//   NUMA-local to the PCIe root port. C-states and frequency scaling disabled.
//   The thread does exactly one thing per tick — one posted 32-bit BAR write —
//   and everything else it does is off the deadline path.
//
// LATENCY BUDGET (the slow-path analogue of an RTL block's header budget):
//   wake jitter    target p99  <  200 us,  hard fail  >   5 ms  (0.25 of a tick)
//   MMIO write     target p99  <    5 us,  hard fail  >   1 ms
//   observed age   target      <   2*P,    alert      >=  WARN
//   Both jitter distributions are measured, not assumed — see jitter_hist.hpp.
// =============================================================================
#ifndef TRADING_HEARTBEAT_HEARTBEAT_HPP
#define TRADING_HEARTBEAT_HEARTBEAT_HPP

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <type_traits>

#include "trading/device.hpp"
#include "trading/expected.hpp"
#include "trading/heartbeat/fault_inject.hpp"
#include "trading/heartbeat/jitter_hist.hpp"
#include "trading/heartbeat/seqlock.hpp"
#include "trading/regmap.hpp"
#include "trading/types.hpp"

namespace trading::heartbeat {

// =============================================================================
// 1. Fabric-side constants, mirrored from rtl/ctrl/csr_regfile.sv
// -----------------------------------------------------------------------------
// These are the DEFAULT synthesis parameter values. They are NOT trusted at
// runtime: readWatchdogThresholds() reads what this particular bitstream was
// actually built with, and the cadence is validated against that. They exist
// here so that a config file can be written and reviewed without a card
// present, and so that a mismatch between the two is visible.
// =============================================================================

// mirrors rtl/ctrl/csr_regfile.sv parameter WATCHDOG_WARN_MS = 50
inline constexpr std::uint32_t kFabricWarnMsDefault = 50;
// mirrors rtl/ctrl/csr_regfile.sv parameter WATCHDOG_MS = 100
inline constexpr std::uint32_t kFabricBlockMsDefault = 100;

// csr_regfile.sv: "required cadence : >= 10 Hz. RECOMMENDED 50 Hz (20 ms)."
inline constexpr std::uint32_t kRecommendedPeriodMs = 20;   // 50 Hz
inline constexpr std::uint32_t kFabricMinCadenceHz = 10;

// =============================================================================
// 2. ⚠ THE CADENCE ARITHMETIC. This is the number the whole component turns on.
// =============================================================================
//
//   P (period) = 20 ms = 50 Hz.
//
//   This is not derived from first principles and then compared with the RTL;
//   it IS the RTL's own recommendation, adopted deliberately so that host and
//   fabric are reviewable against ONE number instead of two that happen to be
//   compatible. rtl/ctrl/csr_regfile.sv, §"THE HEARTBEAT AND THE WATCHDOG":
//   "required cadence : >= 10 Hz. RECOMMENDED 50 Hz (20 ms period)."
//
//   MARGIN AGAINST THE TWO THRESHOLDS THE SAME FILE DECLARES:
//
//       WATCHDOG_WARN_MS =  50 ms  ->  50 / 20 = 2.5x
//       WATCHDOG_MS      = 100 ms  -> 100 / 20 = 5.0x
//
//   Ratios are the wrong unit for an operator, though. The useful form is the
//   MISS BUDGET — how many consecutive ticks may be lost before something
//   observable happens:
//
//       2 consecutive ticks lost -> age ~ 40 ms  -> nothing. Invisible.
//       3 consecutive ticks lost -> age ~ 60 ms  -> STATUS bit 24, a human is
//                                                   paged. No kill.
//       5 consecutive ticks lost -> age ~100 ms  -> ⚠ FORCED DISARM, kill
//                                                   asserted and LATCHED,
//                                                   LOG_WATCHDOG emitted.
//
//   WORST-CASE AGE ACCOUNTING, from the last successful write to the fabric's
//   own view of it:
//
//       A_max(M) = M*P + J + L_pcie + Q
//         M      = consecutive ticks lost
//         P      = 20 ms, the period
//         J      = 2 ms, the scheduling jitter budget for an isolated
//                  SCHED_FIFO core. NOT a guess: it is the alert threshold, and
//                  the wake-jitter histogram measures whether it holds.
//         L_pcie = ~0.01 ms. A posted 32-bit BAR write; hundreds of ns.
//         Q      = 1 ms. csr_regfile's hb_age_q increments on a 1 ms tick and
//                  the comparison is `>=`, so up to a full millisecond of
//                  quantisation works against us. Counted, not hand-waved.
//
//       M = 2 :  40 + 2 + 0.01 + 1 =  43.01 ms  <  50 ms (WARN)   ✔
//       M = 4 :  80 + 2 + 0.01 + 1 =  83.01 ms  < 100 ms (BLOCK)  ✔
//
//   So the design tolerates two lost ticks silently and four lost ticks without
//   stopping trading, while still paging a human at three. That is the shape
//   you want: the alert fires strictly before the action, with enough gap that
//   the alert is not simply a slower copy of the action.
//
//   COST: 50 posted 32-bit MMIO writes per second, to one register. Manual
//   06/03 §5 warns that a 1 kHz register scrape competes with the order-path
//   DMA; this is 1/20 of that rate on a single word. It is also the one PCIe
//   transaction in the system that may never be skipped to save bandwidth.
//
//   WHY NOT FASTER (10 ms / 100 Hz): it would double every margin above, and
//   double the PCIe traffic, in exchange for tolerating a few more lost ticks
//   in a regime where losing that many ticks already means the host is sick.
//   Sitting at the vendor's recommended value is worth more than the margin.
//
//   WHY NOT SLOWER: 10 Hz is csr_regfile's stated floor, but it is a floor for
//   the register write path, NOT a usable operating point — at a 100 ms period
//   the NOMINAL age reaches the 100 ms forced-disarm threshold on every single
//   tick, with zero miss budget. validateCadence() below enforces the real
//   constraint (kMissBudget lost ticks must still fit under WARN), which at the
//   default thresholds puts the true minimum near 40 Hz.
//
// =============================================================================
inline constexpr std::uint32_t kDefaultPeriodMs = kRecommendedPeriodMs;  // 20

// Consecutive lost ticks that must still fit under WARN. See the M = 2 line.
inline constexpr std::uint32_t kMissBudget = 2;
// Scheduling jitter budget, J above. Also the alert threshold on the histogram.
inline constexpr std::uint32_t kJitterBudgetMs = 2;
// Fabric ms-tick quantisation, Q above.
inline constexpr std::uint32_t kFabricAgeQuantMs = 1;

// A block threshold above this contradicts 08-nasdaq/09 §5 ("tens of
// milliseconds, not seconds") and is treated as a misread register rather than
// a deliberate configuration. Refusing here is how a wrong register map gets
// caught before it becomes a silent safety regression.
inline constexpr std::uint32_t kMaxPlausibleBlockMs = 1000;

// =============================================================================
// 3. Register-mirroring types
// =============================================================================

// mirrors rtl/ctrl/csr_regfile.sv WATCHDOG_CFG (BAR offset 0x01C, RO)
//   {warn_ms[31:16], timeout_ms[15:0]}
// ⚠ Two separate fields in ONE 32-bit register. host/include/trading/regmap.hpp
//   currently still exposes them as two registers (CTRL_WDOG_WARN_MS /
//   CTRL_WDOG_BLOCK_MS) inherited from the v1 contract. readWatchdogThresholds()
//   handles both shapes and says which one it found, so this component keeps
//   working across that reconciliation instead of silently reading garbage.
// TODO(rtl-contract): collapse to a single WATCHDOG_CFG read once regmap.hpp is
// reconciled against rtl/ctrl/csr_regfile.sv.
struct WatchdogCfgWord {
    std::uint16_t timeoutMs = 0;  // [15:0]  WATCHDOG_MS      -> forced disarm
    std::uint16_t warnMs = 0;     // [31:16] WATCHDOG_WARN_MS -> alert only

    [[nodiscard]] constexpr std::uint32_t pack() const noexcept {
        return (static_cast<std::uint32_t>(warnMs) << 16) | timeoutMs;
    }
    [[nodiscard]] static constexpr WatchdogCfgWord unpack(std::uint32_t w) noexcept {
        return WatchdogCfgWord{static_cast<std::uint16_t>(w & 0xFFFFu),
                               static_cast<std::uint16_t>(w >> 16)};
    }
    // Does this 32-bit word look like a packed cfg rather than a bare count?
    // Both halves non-zero, warn strictly below timeout, timeout plausible.
    [[nodiscard]] constexpr bool plausible() const noexcept {
        return warnMs != 0 && timeoutMs != 0 && warnMs < timeoutMs &&
               timeoutMs <= kMaxPlausibleBlockMs;
    }
};
static_assert(sizeof(WatchdogCfgWord) == 4,
              "WatchdogCfgWord mirrors one 32-bit register (csr_regfile.sv 0x01C)");
static_assert(WatchdogCfgWord{100, 50}.pack() == 0x0032'0064u,
              "WATCHDOG_CFG field placement disagrees with csr_regfile.sv");
static_assert(WatchdogCfgWord::unpack(0x0032'0064u).timeoutMs == 100);
static_assert(WatchdogCfgWord::unpack(0x0032'0064u).warnMs == 50);

// STATUS (0x014) bit assignments — mirrors rtl/ctrl/csr_regfile.sv §STATUS.
// ⚠ These are NOT the same bits as trading::health in types.hpp. That namespace
//   mirrors manuals/06-operations/03-monitoring-and-telemetry.md §4, which puts
//   "host heartbeat stale" at bit 9; the RTL as built puts watchdog_expired at
//   bit 13 and watchdog_warn at bit 24. The RTL wins for a register read. Both
//   are checked by this component (see HeartbeatConfig::check_manual_health_bit)
//   so the divergence is observed rather than assumed away.
// TODO(rtl-contract): manual 06/03 §4 and csr_regfile.sv STATUS disagree on the
// heartbeat-stale bit position. One of them must be corrected.
namespace csr_status {
inline constexpr std::uint32_t KILL_ACTIVE = 1u << 3;
inline constexpr unsigned ARM_STATE_LSB = 9;  // [11:9]
inline constexpr std::uint32_t ARM_STATE_MASK = 0x7u;
inline constexpr std::uint32_t WATCHDOG_EXPIRED = 1u << 13;
inline constexpr std::uint32_t WATCHDOG_WARN = 1u << 24;

[[nodiscard]] constexpr bool killActive(std::uint32_t s) noexcept {
    return (s & KILL_ACTIVE) != 0;
}
[[nodiscard]] constexpr bool watchdogExpired(std::uint32_t s) noexcept {
    return (s & WATCHDOG_EXPIRED) != 0;
}
[[nodiscard]] constexpr bool watchdogWarn(std::uint32_t s) noexcept {
    return (s & WATCHDOG_WARN) != 0;
}
[[nodiscard]] constexpr std::uint32_t armState(std::uint32_t s) noexcept {
    return (s >> ARM_STATE_LSB) & ARM_STATE_MASK;
}
inline constexpr std::uint32_t ARM_DISARMED = 0;
inline constexpr std::uint32_t ARM_STEP1 = 1;
inline constexpr std::uint32_t ARM_ARMED = 2;
inline constexpr std::uint32_t ARM_FAULT = 3;
}  // namespace csr_status

// KILL_SRC (0x020) bit assignments — mirrors rtl/ctrl/csr_regfile.sv §KILL_SRC.
// Sticky, cleared only by reset. In a cascade the FIRST source is the root
// cause and the last one is usually just the consequence, so both are exposed.
namespace csr_kill_src {
inline constexpr unsigned LAST_LSB = 0;    // [2:0]   kill_src_e
inline constexpr std::uint32_t LAST_MASK = 0x7u;
inline constexpr std::uint32_t ACTIVE = 1u << 3;
inline constexpr unsigned FIRST_LSB = 8;   // [10:8]  kill_src_e
inline constexpr std::uint32_t FIRST_MASK = 0x7u;
inline constexpr unsigned EVER_LSB = 16;   // [23:16] one bit per kill_src_e
inline constexpr std::uint32_t EVER_MASK = 0xFFu;

[[nodiscard]] constexpr KillSrc last(std::uint32_t w) noexcept {
    return static_cast<KillSrc>((w >> LAST_LSB) & LAST_MASK);
}
[[nodiscard]] constexpr KillSrc first(std::uint32_t w) noexcept {
    return static_cast<KillSrc>((w >> FIRST_LSB) & FIRST_MASK);
}
[[nodiscard]] constexpr bool active(std::uint32_t w) noexcept { return (w & ACTIVE) != 0; }
[[nodiscard]] constexpr std::uint32_t everMask(std::uint32_t w) noexcept {
    return (w >> EVER_LSB) & EVER_MASK;
}
// Has the WATCHDOG ever fired on this card since reset? This is the bit the
// fault-injection drill is trying to set, and the bit an incident review reads.
[[nodiscard]] constexpr bool watchdogEverFired(std::uint32_t w) noexcept {
    return (everMask(w) & (1u << static_cast<unsigned>(KillSrc::Watchdog))) != 0;
}
}  // namespace csr_kill_src

// HEARTBEAT_AGE resets to this. ⚠ Already past every plausible timeout, by
// design — see the header. Also the saturating maximum, so an age of 0xFFFF
// means "at least 65535 ms", never exactly 65535.
inline constexpr std::uint32_t kHeartbeatAgeReset = 0xFFFFu;

// Returned by csr_regfile for any unmapped BAR offset. Deliberately never 0, so
// a host pointed at the wrong offset finds out instead of reading a plausible
// zero. mirrors csr_regfile.sv localparam CSR_UNMAPPED.
inline constexpr std::uint32_t kCsrUnmapped = 0xDEAD'C0DEu;
// Returned when a telemetry-window read times out in the core domain.
inline constexpr std::uint32_t kCsrTelemTimeout = 0xDEAD'DEADu;

[[nodiscard]] constexpr bool isSentinel(std::uint32_t v) noexcept {
    return v == kCsrUnmapped || v == kCsrTelemTimeout;
}

// =============================================================================
// 4. ⚠ THE WRITE ALLOW-LIST — structural proof this component cannot arm, kill,
//    or clear a kill.
// -----------------------------------------------------------------------------
// This component writes exactly ONE register, ever. Everything else it touches
// is read-only. That is asserted at compile time here and checked again at
// runtime in the write path, so the property survives a careless edit.
// =============================================================================
[[nodiscard]] constexpr bool writeAllowed(std::uint32_t offset) noexcept {
    return offset == regmap::CTRL_HEARTBEAT.offset;
}

// The dangerous registers, named explicitly so the assertions below read as
// statements of intent rather than arithmetic.
static_assert(!writeAllowed(regmap::CTRL_KILL.offset),
              "the heartbeat component must never be able to write CTRL_KILL");
static_assert(!writeAllowed(regmap::CTRL_ARM_KEY.offset),
              "the heartbeat component must never be able to write the arm nonce");
static_assert(!writeAllowed(regmap::CTRL_ARM_EXEC.offset),
              "the heartbeat component must never be able to execute an arm");
static_assert(!writeAllowed(regmap::CTRL_TRADING_EN.offset),
              "the heartbeat component must never be able to enable trading");
static_assert(!writeAllowed(regmap::CTRL_WDOG_WARN_MS.offset) &&
                  !writeAllowed(regmap::CTRL_WDOG_BLOCK_MS.offset),
              "watchdog thresholds are read-only synthesis parameters; raising "
              "one to silence a stalled heartbeat is the exact failure this "
              "component exists to prevent");
static_assert(writeAllowed(regmap::CTRL_HEARTBEAT.offset),
              "the heartbeat component must be able to write the heartbeat");
static_assert(regmap::CTRL_HEARTBEAT.access == regmap::Access::WO,
              "CTRL_HEARTBEAT is write-only; never read it back");

// =============================================================================
// 5. Logging
// -----------------------------------------------------------------------------
// This component does not own a logger. It takes a sink so it can be wired to
// whatever logd/metricsd provide.
//
// ⚠ CONTRACT ON THE SINK: it is called from the SCHED_FIFO heartbeat thread,
//   ALWAYS AFTER the tick's MMIO write has already been issued, never before.
//   A slow sink can therefore delay the NEXT beat but can never delay THIS one,
//   and any delay it does cause shows up honestly in the wake-jitter histogram
//   instead of being hidden. It must not block indefinitely and must not
//   allocate unboundedly. The default sink writes to stderr and is for
//   development only.
// =============================================================================
enum class LogLevel : std::uint8_t { Info = 0, Warn = 1, Error = 2, Fatal = 3 };

[[nodiscard]] constexpr std::string_view toString(LogLevel l) noexcept {
    switch (l) {
        case LogLevel::Info:  return "INFO";
        case LogLevel::Warn:  return "WARN";
        case LogLevel::Error: return "ERROR";
        case LogLevel::Fatal: return "FATAL";
    }
    return "?";
}

using LogSink = std::function<void(LogLevel, std::string_view)>;

// Development default: timestamped line to stderr. Not for production.
void defaultLogSink(LogLevel level, std::string_view msg);

// =============================================================================
// 6. Errors
// =============================================================================
enum class HeartbeatError : std::uint8_t {
    AlreadyRunning = 1,
    NotRunning,
    InvalidPeriod,
    // The configured cadence does not leave kMissBudget lost ticks under the
    // fabric's WARN threshold. Refusing to start is correct: a heartbeat that
    // pages a human on one missed tick trains the desk to ignore the page.
    CadenceUnsafe,
    ThresholdReadFailed,
    ThresholdImplausible,
    // The preflight could not prove that a HEARTBEAT write actually resets
    // HEARTBEAT_AGE. Almost always a wrong register map.
    WatchdogProofFailed,
    AffinityDenied,
    SchedulingDenied,
    MemoryLockDenied,
    ClockUnavailable,
    PlatformUnsupported,
    ThreadStartFailed,
    DeviceReadFailed,
    DeviceWriteFailed,
    FaultInjectionNotCompiledIn,
    FaultInjectionRefused,
};

[[nodiscard]] std::string_view toString(HeartbeatError e) noexcept;

// =============================================================================
// 7. Configuration
// =============================================================================
struct HeartbeatConfig {
    // ── Cadence ─────────────────────────────────────────────────────────────
    // YAML: heartbeat.period_ms (uint32, default 20) — see §2, THE CADENCE
    //       ARITHMETIC. Validated against the thresholds actually read from the
    //       card, not against the defaults in this header.
    std::chrono::milliseconds period{kDefaultPeriodMs};

    // ── Runtime placement (host/README.md §4) ───────────────────────────────
    // YAML: heartbeat.cpu (int, default -1)
    // ⚠ -1 means "not pinned", which is only legal when require_pinning is
    //   false. There is deliberately no default core number: picking one for
    //   you would be picking one that is not in isolcpus on somebody's box.
    int cpu = -1;

    // YAML: heartbeat.rt_priority (int, default 80)
    // Below the usual 85-99 band reserved for kernel threads (ksoftirqd,
    // migration) so this thread cannot starve the machine it depends on, and
    // well above any application thread.
    int rt_priority = 80;

    // ⚠ These three default to REFUSING TO START rather than degrading.
    //   Rationale: starting a heartbeat you already know is unreliable, and
    //   then arming trading on top of it, is the bad outcome. Refusing to start
    //   means trading does not happen, which is merely the disruptive outcome.
    //   Setting any of them false is an explicit decision to run degraded; the
    //   thread then logs a banner and latches a `degraded_*` flag that never
    //   clears, so metricsd can alert on it and it cannot be forgotten.
    bool require_pinning = true;
    bool require_realtime = true;
    bool require_memlock = true;

    // YAML: heartbeat.lock_memory (bool, default true)
    // mlockall(MCL_CURRENT|MCL_FUTURE). A major fault in this loop is a
    // multi-millisecond stall, which is a direct step towards a kill.
    bool lock_memory = true;

    // ── Self-monitoring (§6 of the brief) ───────────────────────────────────
    // YAML: heartbeat.age_poll_divisor (uint32, default 5)
    // Read HEARTBEAT_AGE / STATUS / KILL_SRC every Nth tick. At P=20 ms and
    // N=5 that is a 10 Hz scrape of four registers — manual 06/03 §5's stated
    // rate for "latency-critical health", and 1/25 of the rate it warns about.
    std::uint32_t age_poll_divisor = 5;

    // Warn if the fabric's view of our age exceeds this multiple of the period.
    // At P=20 ms, x3 = 60 ms... which is already past WARN, so the effective
    // trigger is min(period*multiple, warnMs) — computed in the loop.
    std::uint32_t age_warn_period_multiple = 3;

    // Consecutive polls of strictly rising age that constitute "drifting up".
    // ⚠ This is the early warning that this thread is being starved: the age is
    //   climbing between polls, which means writes are landing later and later.
    //   It fires well before the fabric's own WARN does.
    std::uint32_t age_rise_streak_alert = 3;

    // YAML: heartbeat.check_manual_health_bit (bool, default true)
    // Also read CTRL_HEALTH and check trading::health::HEARTBEAT_STALE (bit 9,
    // per manual 06/03 §4). The RTL as built reports staleness in STATUS bit 13
    // instead. Checking both surfaces the documented disagreement instead of
    // picking a winner silently.
    bool check_manual_health_bit = true;

    // ── Startup proof ───────────────────────────────────────────────────────
    // YAML: heartbeat.verify_watchdog_on_start (bool, default true)
    // ⚠ Turning this off removes the only check that proves a HEARTBEAT write
    //   actually reaches the watchdog. Leave it on. host/README.md §3.1 makes
    //   read-back-and-verify mandatory after every parameter commit; this is
    //   the same discipline applied to the one register whose write IS the
    //   safety property.
    bool verify_watchdog_on_start = true;

    // ── Fault injection. Inert by default. See fault_inject.hpp. ────────────
    FaultInjectionConfig fault{};

    // Validate everything that can be validated without a card.
    [[nodiscard]] expected<void, HeartbeatError> validateStatic() const;
};

// Thresholds as actually read from this bitstream.
struct WatchdogThresholds {
    std::uint32_t warnMs = 0;
    std::uint32_t blockMs = 0;
    bool fromPackedCfgWord = false;  // true if WATCHDOG_CFG's packed form was seen

    [[nodiscard]] constexpr bool plausible() const noexcept {
        return warnMs != 0 && blockMs != 0 && warnMs < blockMs &&
               blockMs <= kMaxPlausibleBlockMs;
    }
};

// Read the thresholds from the card. Handles both the packed WATCHDOG_CFG shape
// (rtl/ctrl/csr_regfile.sv 0x01C) and the two-register shape that regmap.hpp
// currently exposes, and reports which it found.
[[nodiscard]] expected<WatchdogThresholds, HeartbeatError> readWatchdogThresholds(Device& dev);

// Is `period` safe against these thresholds? The rule is the M = kMissBudget
// line of §2: kMissBudget lost ticks, plus the jitter budget, plus the fabric's
// millisecond quantisation, must still fit under WARN.
[[nodiscard]] constexpr bool cadenceIsSafe(std::uint32_t periodMs,
                                           const WatchdogThresholds& t) noexcept {
    if (periodMs == 0 || !t.plausible()) return false;
    const std::uint64_t worst = static_cast<std::uint64_t>(kMissBudget) * periodMs +
                                kJitterBudgetMs + kFabricAgeQuantMs;
    return worst <= t.warnMs;
}
// The documented default must satisfy its own rule against the documented
// defaults. If someone changes one number and not the others, this fails here
// rather than on a live card.
static_assert(cadenceIsSafe(kDefaultPeriodMs,
                            WatchdogThresholds{kFabricWarnMsDefault, kFabricBlockMsDefault, false}),
              "the default cadence does not satisfy the miss-budget rule against "
              "the default fabric thresholds — re-derive §2 THE CADENCE ARITHMETIC");
static_assert(!cadenceIsSafe(100, WatchdogThresholds{kFabricWarnMsDefault,
                                                     kFabricBlockMsDefault, false}),
              "a 10 Hz cadence must be rejected: its nominal age reaches the "
              "forced-disarm threshold on every tick");

// Largest period that satisfies the rule, for error messages that tell the
// operator what to do rather than only what went wrong.
[[nodiscard]] constexpr std::uint32_t maxSafePeriodMs(const WatchdogThresholds& t) noexcept {
    if (!t.plausible()) return 0;
    const std::uint32_t slack = kJitterBudgetMs + kFabricAgeQuantMs;
    if (t.warnMs <= slack) return 0;
    return (t.warnMs - slack) / kMissBudget;
}

// =============================================================================
// 8. Published statistics — what metricsd reads
// -----------------------------------------------------------------------------
// POD, trivially copyable, published through a seqlock once per tick.
// =============================================================================
struct HeartbeatCounters {
    // ── the beat ────────────────────────────────────────────────────────────
    std::uint64_t ticks = 0;             // loop iterations
    std::uint64_t writesOk = 0;          // MMIO writes that succeeded
    std::uint64_t writesFailed = 0;      // ⚠ each one is a lost tick, never retried
    std::uint64_t writesSuppressed = 0;  // fault injection only
    std::uint32_t consecutiveWriteFailures = 0;
    std::uint32_t lastValueWritten = 0;
    std::uint64_t wraps = 0;             // u32 sequence wraps. See §9.

    // ── deadline discipline ─────────────────────────────────────────────────
    std::uint64_t missedDeadlines = 0;   // ⚠ ticks that never happened
    std::uint64_t rebases = 0;           // times the deadline was re-based, not caught up
    std::uint64_t maxOverrunNs = 0;      // worst single overrun

    // ── the fabric's view of us ─────────────────────────────────────────────
    std::uint32_t lastAgeMs = 0;
    std::uint32_t maxAgeMs = 0;          // high-water. Never resets. See §9.
    std::uint32_t ageRiseStreak = 0;     // consecutive polls with rising age
    std::uint32_t maxAgeRiseStreak = 0;
    std::uint64_t agePolls = 0;
    std::uint64_t ageReadFailures = 0;
    std::uint64_t sentinelReads = 0;     // ⚠ 0xDEADC0DE: wrong offset or dead BAR

    // ── latched observations. These NEVER clear while the process lives. ────
    bool warnObserved = false;           // fabric STATUS watchdog_warn seen set
    bool blockObserved = false;          // fabric STATUS watchdog_expired seen set
    bool killObserved = false;           // fabric kill_active seen set
    bool watchdogKillObserved = false;   // ⚠ and its provenance was WATCHDOG
    bool manualHealthBitObserved = false;    // CTRL_HEALTH bit 9 (manual 06/03 §4)
    bool healthBitDisagreementObserved = false;  // bit 9 and STATUS bit 13 disagreed
    bool disarmObserved = false;         // arm_state left ARMED while we were beating

    std::uint32_t lastStatusWord = 0;
    std::uint32_t lastKillSrcWord = 0;
    std::uint8_t lastArmState = 0;

    // ── degradation. Latched at start, never cleared. ───────────────────────
    bool degradedAffinity = false;   // not pinned
    bool degradedScheduling = false; // not SCHED_FIFO — ⚠ jitter is now unbounded
    bool degradedMemlock = false;    // not mlocked — a major fault can stall us

    // ── fault injection ─────────────────────────────────────────────────────
    bool faultArmed = false;
    FaultMode faultMode = FaultMode::None;
    bool faultActive = false;

    bool running = false;
    bool stopRequested = false;
};
static_assert(std::is_trivially_copyable_v<HeartbeatCounters>,
              "HeartbeatCounters is published through a seqlock by memcpy");

// The whole published view. Returned by value; ~700 bytes.
struct HeartbeatSnapshot {
    HeartbeatCounters counters{};
    JitterSnapshot wakeJitter{};    // (actual wake - intended deadline)
    JitterSnapshot writeLatency{};  // MMIO write issue -> return
    WatchdogThresholds thresholds{};
    std::uint32_t periodMs = 0;
    bool torn = false;  // ⚠ true means the fields are not mutually consistent

    // The two questions an alert rule actually asks.
    [[nodiscard]] bool healthy() const noexcept {
        return counters.running && !counters.blockObserved && !counters.killObserved &&
               counters.consecutiveWriteFailures == 0 && !counters.degradedScheduling &&
               !counters.faultArmed;
    }
    [[nodiscard]] bool degraded() const noexcept {
        return counters.degradedAffinity || counters.degradedScheduling ||
               counters.degradedMemlock;
    }
};

// =============================================================================
// 9. The thread
// -----------------------------------------------------------------------------
// LIFECYCLE
//   start()  — runs the preflight SYNCHRONOUSLY on the caller's thread (so
//              failures are returned, not logged and swallowed), then spawns
//              the beating thread and does not return until that thread has
//              reported whether it got its affinity, scheduling and memory
//              lock. If start() returns success, the heartbeat is live and
//              PROVEN live — the card is ready to be armed.
//   stop()   — a DELIBERATE SHUTDOWN ACTION, and the only sanctioned way for
//              the beat to end. It must be called with trading already
//              disabled: SHARED_CONTRACT.md's shutdown sequence is the startup
//              sequence reversed, and it disables trading BEFORE stopping the
//              heartbeat. Stopping first works, in the sense that the fabric
//              will kill within WATCHDOG_MS — but it books an unexplained
//              watchdog kill into the audit trail every time you shut down,
//              which trains everyone to ignore watchdog kills.
//   ~HeartbeatThread() — stops and joins. Destroying this object stops the
//              heartbeat, and the fabric will act on that. It is not a leak to
//              let it live for the whole process; it is the design.
//
// THE SEQUENCE VALUE AND ITS WRAP (§2 of the brief)
//   The value written is a u32 that increments every tick and SKIPS ZERO on
//   wrap: ... 0xFFFFFFFE, 0xFFFFFFFF, 1, 2, ... Zero is reserved to mean "never
//   written" for anything reading hb_seq_q, and skipping it keeps consecutive
//   values distinct across the wrap (a naive wrap to 0 followed by a bump to 1
//   would write 1 twice in a row).
//   ⚠ No safety property depends on any of this: the fabric's watchdog is
//     triggered by the WRITE, not by the value. At 50 Hz the wrap is 2^32 / 50
//     seconds ≈ 2.7 years of continuous operation, so it is unreachable inside
//     a trading day and is handled anyway, because "unreachable" arithmetic is
//     how you get a bug in year three.
//
// WHY maxAgeMs AND THE LATCHED FLAGS NEVER RESET
//   manual 06/03 §9, the sticky-error pattern: the sticky bit answers "did this
//   ever happen" and the counter answers "how often". A max age that an
//   operator can clear is a max age that hides last night's 80 ms excursion.
//   These clear when the process restarts, and the restart is itself logged.
// =============================================================================
class HeartbeatThread {
public:
    HeartbeatThread(Device& dev, HeartbeatConfig cfg, LogSink log = LogSink{});
    ~HeartbeatThread();

    HeartbeatThread(const HeartbeatThread&) = delete;
    HeartbeatThread& operator=(const HeartbeatThread&) = delete;
    HeartbeatThread(HeartbeatThread&&) = delete;
    HeartbeatThread& operator=(HeartbeatThread&&) = delete;

    [[nodiscard]] expected<void, HeartbeatError> start();

    // Deliberate shutdown. Idempotent. Blocks until the thread has joined;
    // worst case one period.
    void stop() noexcept;

    [[nodiscard]] bool running() const noexcept {
        return running_.load(std::memory_order_relaxed);
    }

    // Lock-free, safe from any thread, never blocks the heartbeat.
    [[nodiscard]] HeartbeatSnapshot snapshot() const noexcept;

    [[nodiscard]] const WatchdogThresholds& thresholds() const noexcept { return thresholds_; }
    [[nodiscard]] const HeartbeatConfig& config() const noexcept { return cfg_; }

private:
    // ── preflight, on the caller's thread ───────────────────────────────────
    [[nodiscard]] expected<void, HeartbeatError> preflight();
    // Proves a HEARTBEAT write actually resets HEARTBEAT_AGE, and that the age
    // register actually counts. See the .cpp for the three phases.
    [[nodiscard]] expected<void, HeartbeatError> proveWatchdogWiring();

    // ── on the heartbeat thread ─────────────────────────────────────────────
    void threadMain();
    [[nodiscard]] bool applyThreadPlacement(std::string& detail);  // affinity/sched/memlock
    void loop();
    void pollFabricView();  // self-monitoring: age, status, kill provenance
    void publish() noexcept { pub_.publish(counters_); }
    void log(LogLevel level, std::string_view msg) const;

    [[nodiscard]] std::uint32_t nextValue() noexcept;

    Device& dev_;
    HeartbeatConfig cfg_;
    LogSink log_;

    WatchdogThresholds thresholds_{};
    FaultInjector fault_{};

    std::thread thread_;
    std::atomic<bool> stop_{false};
    std::atomic<bool> running_{false};

    // start() -> threadMain() placement handshake.
    std::mutex startMx_;
    std::condition_variable startCv_;
    bool startReported_ = false;
    bool startOk_ = false;
    HeartbeatError startError_{};

    // ── heartbeat-thread-private state. No other thread touches these. ──────
    HeartbeatCounters counters_{};
    std::uint32_t value_ = 0;
    std::uint32_t lastPolledAgeMs_ = 0;
    bool haveLastPolledAge_ = false;

    // ── cross-thread publication ────────────────────────────────────────────
    SeqLocked<HeartbeatCounters> pub_{};
    JitterHistogram wakeJitter_{};
    JitterHistogram writeLatency_{};
};

}  // namespace trading::heartbeat

#endif  // TRADING_HEARTBEAT_HEARTBEAT_HPP
