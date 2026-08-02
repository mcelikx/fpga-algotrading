// =============================================================================
// fault_inject.hpp — DELIBERATE heartbeat failure modes, for testing the kill
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : host/src/heartbeat  (heartbeat + watchdog)
//
// =============================================================================
// WHY THIS FILE EXISTS
// =============================================================================
// host/README.md §3.4: "Losing the host must be safe. If any of these processes
// dies, the watchdog fires and trading stops. TEST THIS DELIBERATELY AND
// REGULARLY."  manuals/08-nasdaq/09-risk-controls-and-limits.md §5 goes further
// and makes it a gating CI test: "The kill switch is re-tested on every
// bitstream... It is the one test that may never be skipped for a build going
// anywhere near production."  rtl/risk/kill_switch.sv says the same thing from
// the other side of the PCIe bus:
//
//     "A kill switch that has never been observed to fire is one you cannot
//      trust, and the first time you find out it is broken must not be the day
//      you need it."
//
// That module exposes `kill_test`, which walks the real OR tree and the real
// latch. This file is the host-side counterpart for the ONE trigger source
// `kill_test` cannot exercise: the watchdog. `kill_test` proves the latch
// works. Only stopping the actual heartbeat proves that the fabric NOTICES a
// dead host — that the age counter really counts, that the threshold really
// compares, and that host_ctrl really stops forwarding pulses.
//
// =============================================================================
// ⚠⚠ THIS ARMS A REAL HARDWARE KILL ON A REAL CARD. ⚠⚠
// =============================================================================
// There is no simulation mode here and no dry run. Every mode below drives the
// production write path. StopWriting and SlowPastBlock WILL latch the kill
// switch, which WILL force a disarm, and clearing it requires the full
// authenticated two-step re-arm sequence with a reconciled position loaded
// (kill_switch.sv, KS_ARMED -> KS_ARM_STEP1 -> KS_LIVE). Budget for that in the
// runbook before you arm anything here.
//
// THREE INDEPENDENT GATES, ALL REQUIRED:
//   1. COMPILE TIME  — TRADING_HEARTBEAT_FAULT_INJECTION must be defined to 1.
//                      Production builds do not define it, so the arming code
//                      is not merely unreachable, it is not present.
//   2. CONFIG        — FaultInjectionConfig::enabled must be true AND
//                      confirm_phrase must match kFaultConfirmPhrase EXACTLY.
//                      A boolean alone is one YAML typo away from being armed;
//                      a sentence nobody types by accident is not.
//   3. FABRIC STATE  — CTRL_TRADING_EN must read 0 unless the operator has also
//                      set allow_while_trading_enabled. Run the drill pre-open
//                      with trading disabled, exactly as kill_switch.sv's
//                      header recommends for `kill_test`.
//
// ⚠ THERE IS NO AUTO-REVERT AND THERE MUST NEVER BE ONE.
//   Once armed, a mode runs until the process is stopped. A "revert after N
//   seconds" feature would be indistinguishable from the auto-recovery logic
//   that host/README.md §3.4 and this component's header comment forbid, and
//   the day someone reuses it outside a drill it silently papers over a real
//   stall. Ending the drill is an operator action, not a timer.
// =============================================================================
#ifndef TRADING_HEARTBEAT_FAULT_INJECT_HPP
#define TRADING_HEARTBEAT_FAULT_INJECT_HPP

#include <cstdint>
#include <string>
#include <string_view>

#ifndef TRADING_HEARTBEAT_FAULT_INJECTION
// Default OFF. A production build must not merely leave the flag false, it must
// not compile the arming path at all.
#define TRADING_HEARTBEAT_FAULT_INJECTION 0
#endif

namespace trading::heartbeat {

// -----------------------------------------------------------------------------
// The modes. Each one attacks a DIFFERENT assumption in the watchdog chain.
// -----------------------------------------------------------------------------
enum class FaultMode : std::uint8_t {
    None = 0,

    // Stop issuing MMIO writes entirely, as if the process had been SIGSTOPped.
    // Attacks: does the fabric age counter actually count, and does the
    // comparison actually fire?
    StopWriting = 1,

    // Keep writing at the correct cadence, but write the SAME u32 forever.
    //
    // ⚠⚠ WHAT THIS PROVES AND WHAT IT DOES NOT — read before interpreting a
    //    result, because the obvious reading is wrong.
    //
    //    An earlier version of the host/fabric contract claimed the fabric
    //    detects liveness by the VALUE CHANGING, and that a stuck-at value is
    //    therefore as dead as no write at all. THE HARDWARE DOES NOT WORK THAT
    //    WAY. rtl/ctrl/csr_regfile.sv is explicit:
    //
    //        "The host writes ANY value to HEARTBEAT on a fixed cadence. Each
    //         write resets HEARTBEAT_AGE to 0 and emits one pulse to the core
    //         domain, where risk_gate runs the authoritative watchdog."
    //
    //    The WRITE is the event. The payload is latched into hb_seq_q for
    //    host-side debugging and is not an input to any watchdog comparison.
    //    kill_switch.sv's `host_heartbeat` is edge-detected, but that edge is
    //    csr_regfile's one-cycle hb_pulse — one edge per WRITE, not one per
    //    value change. So:
    //
    //        EXPECTED OUTCOME OF THIS MODE: no warn, no block, no kill.
    //        The card stays alive on a frozen value exactly as it does on an
    //        incrementing one.
    //
    //    Then what is it for? It is a regression test on THIS COMPONENT, not on
    //    the fabric. It proves the value we write is not accidentally
    //    load-bearing, which is precisely what makes the u32 sequence counter
    //    safe to wrap. And it is the canary for a future RTL change: if someone
    //    later makes the fabric value-sensitive, this drill is where that is
    //    discovered, on a pre-open rehearsal rather than at 09:31.
    //
    //    ⚠ A KILL DURING THIS DRILL IS A FINDING, NOT A PASS. It means the
    //      fabric became value-sensitive without the host being told, and every
    //      wrap-around assumption in heartbeat.cpp needs re-reviewing.
    FreezeValue = 2,

    // Stretch the period so the fabric's view of our age crosses WARN but stays
    // below BLOCK. Attacks: is the WARN threshold wired to anything, and does
    // the alert actually reach a human?  Must NOT kill.
    SlowPastWarn = 3,

    // Stretch the period past BLOCK. Attacks: the full chain, end to end, with
    // the heartbeat still nominally "working" — the nastiest real-world shape,
    // because a degraded host looks alive right up until it is blocked.
    SlowPastBlock = 4,
};

[[nodiscard]] constexpr std::string_view toString(FaultMode m) noexcept {
    switch (m) {
        case FaultMode::None:          return "NONE";
        case FaultMode::StopWriting:   return "STOP_WRITING";
        case FaultMode::FreezeValue:   return "FREEZE_VALUE";
        case FaultMode::SlowPastWarn:  return "SLOW_PAST_WARN";
        case FaultMode::SlowPastBlock: return "SLOW_PAST_BLOCK";
    }
    return "FAULT_MODE_UNKNOWN";
}

// ⚠ FreezeValue is deliberately NOT in this set. See the note on the
//   enumerator: the fabric's watchdog is write-triggered, not value-triggered,
//   so a frozen value keeps the card alive. If this function ever needs to
//   return true for FreezeValue, the RTL changed and this whole file needs a
//   re-read.
[[nodiscard]] constexpr bool faultModeIsExpectedToKill(FaultMode m) noexcept {
    return m == FaultMode::StopWriting || m == FaultMode::SlowPastBlock;
}

// The phrase that must appear verbatim in the config file. Chosen so that it
// cannot be produced by a copy-paste of a boolean, a default, or an
// autocompleted key, and so that it appears in the audit trail as an
// unambiguous statement of intent.
inline constexpr std::string_view kFaultConfirmPhrase = "I ACCEPT THE HARDWARE KILL";

// -----------------------------------------------------------------------------
// Expected observable outcome per mode. Logged verbatim at arm time so the
// operator's terminal contains the pass criteria BEFORE the drill runs, and so
// the post-mortem does not depend on anyone remembering what was supposed to
// happen. Referenced register/bit names are the ones in
// host/include/trading/regmap.hpp and rtl/ctrl/csr_regfile.sv.
// -----------------------------------------------------------------------------
[[nodiscard]] std::string expectedOutcome(FaultMode mode, std::uint32_t warnMs,
                                          std::uint32_t blockMs);

// -----------------------------------------------------------------------------
// Configuration. Every field defaults to the inert value; a default-constructed
// FaultInjectionConfig can never arm anything.
// -----------------------------------------------------------------------------
struct FaultInjectionConfig {
    // YAML: heartbeat.fault_injection.enabled (bool, default false)
    bool enabled = false;

    // YAML: heartbeat.fault_injection.confirm_phrase (string, no default)
    // Must equal kFaultConfirmPhrase exactly, including case.
    std::string confirm_phrase;

    // YAML: heartbeat.fault_injection.mode
    //   "stop_writing" | "freeze_value" | "slow_past_warn" | "slow_past_block"
    FaultMode mode = FaultMode::None;

    // YAML: heartbeat.fault_injection.arm_after_ticks (uint32, default 100)
    // Beat normally for this many ticks first. Two reasons: the fabric must be
    // observed HEALTHY before the fault so the drill has a baseline, and an
    // operator who armed this by mistake gets a window in which the loud banner
    // is on screen and nothing irreversible has happened yet.
    std::uint32_t arm_after_ticks = 100;

    // YAML: heartbeat.fault_injection.allow_while_trading_enabled (bool, false)
    // ⚠ Leaving this false means the drill refuses to start if CTRL_TRADING_EN
    //   reads non-zero. Setting it true is a decision to stop live order flow.
    bool allow_while_trading_enabled = false;

    // YAML: heartbeat.fault_injection.slow_factor_pct (uint32, default 150)
    // For the Slow* modes: the stretched period is expressed as a percentage of
    // the relevant threshold (WARN or BLOCK) rather than of the nominal period,
    // so the drill scales correctly if the fabric is synthesised with different
    // thresholds. 150 means "beat at 1.5x the threshold interval", which puts
    // the observed age comfortably past it without being so slow that the test
    // takes minutes.
    std::uint32_t slow_factor_pct = 150;

    [[nodiscard]] bool confirmed() const noexcept {
        return enabled && mode != FaultMode::None && confirm_phrase == kFaultConfirmPhrase;
    }
};

// -----------------------------------------------------------------------------
// What the loop should do on this tick. Returned by FaultInjector::plan().
// -----------------------------------------------------------------------------
struct TickPlan {
    bool write = true;            // false -> emit no MMIO write at all
    bool freezeValue = false;     // true  -> re-write the previous value verbatim
    std::int64_t periodNs = 0;    // effective period for the NEXT absolute deadline
};

// -----------------------------------------------------------------------------
// The injector. Owned by HeartbeatThread; consulted once per tick.
//
// arm() is the ONLY way to leave the inert state, it can only be called before
// the thread starts, and it returns false (with a reason) unless all three
// gates above are satisfied. There is no disarm() — see the no-auto-revert note
// in the file header.
// -----------------------------------------------------------------------------
class FaultInjector {
public:
    // `tradingEnabled` is the value just read from CTRL_TRADING_EN. `warnMs`
    // and `blockMs` are the thresholds read from the card, used to compute the
    // stretched periods for the Slow* modes.
    // Returns true if armed. On false, `reason` explains which gate rejected it.
    bool arm(const FaultInjectionConfig& cfg, bool tradingEnabled, std::uint32_t warnMs,
             std::uint32_t blockMs, std::string& reason);

    [[nodiscard]] bool armed() const noexcept { return armed_; }
    [[nodiscard]] FaultMode mode() const noexcept { return armed_ ? cfg_.mode : FaultMode::None; }

    // True once the fault is actually in effect (armed AND past arm_after_ticks).
    [[nodiscard]] bool active(std::uint64_t tick) const noexcept {
        return armed_ && tick >= cfg_.arm_after_ticks;
    }

    // Called once per tick from the heartbeat loop. `nominalPeriodNs` is the
    // configured healthy cadence.
    [[nodiscard]] TickPlan plan(std::uint64_t tick, std::int64_t nominalPeriodNs) const noexcept;

    [[nodiscard]] const FaultInjectionConfig& config() const noexcept { return cfg_; }

private:
    FaultInjectionConfig cfg_{};
    bool armed_ = false;
    std::int64_t slowPeriodNs_ = 0;  // precomputed at arm() time; no division per tick
};

}  // namespace trading::heartbeat

#endif  // TRADING_HEARTBEAT_FAULT_INJECT_HPP
