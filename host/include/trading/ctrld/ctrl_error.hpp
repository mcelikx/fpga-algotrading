// =============================================================================
// ctrld/ctrl_error.hpp — the control daemon's failure vocabulary
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : ctrld (the control daemon)
//
// ⚠ ctrld NEVER EMITS AN ORDER AND HAS NO CODE PATH THAT COULD.
//   The pre-trade risk gate lives in fabric (rtl/risk/) and is structurally
//   non-bypassable: it is the only driver of the order-encode path in
//   rtl/fpga_top.sv. Nothing in host/src/ctrld/ writes an order, a token, a
//   quantity or a price onto any datapath. ctrld writes exactly the CONTROL
//   block of BAR0 and rings the PARAM commit doorbells; that is its entire
//   write surface. See CLAUDE.md §5.5 and host/README.md §3.2.
//
// -----------------------------------------------------------------------------
// WHY A SEPARATE ERROR ENUM FROM trading::DeviceError
//   DeviceError says "the bus transaction failed". ctrld needs to say "the
//   generation counter did not move after the commit doorbell, so the fabric
//   did not accept the bank, so we are aborting the startup sequence and
//   leaving the device in the fail-closed state". Those are different facts and
//   an operator at 09:28 needs the second one. Every DeviceError that crosses
//   into ctrld is wrapped, never flattened: the originating bus code survives in
//   CtrlFailure::busCode.
//
// POD ONLY. No allocation, no owned strings, no virtual anything. A failure in
// the middle of the startup sequence must be constructible when the heap is the
// thing that is broken.
// =============================================================================
#ifndef TRADING_CTRLD_CTRL_ERROR_HPP
#define TRADING_CTRLD_CTRL_ERROR_HPP

#include <cstdint>
#include <string_view>

#include "trading/expected.hpp"

namespace trading::ctrld {

// =============================================================================
// 1. Lifecycle phases
// -----------------------------------------------------------------------------
// A failure is meaningless without knowing which half of the day it happened
// in. `state` below is a StartupState or a ShutdownState depending on this.
// =============================================================================
enum class Lifecycle : std::uint8_t {
    None = 0,      // not inside either sequence (config parsing, construction)
    Startup = 1,
    Runtime = 2,   // supervising a running system
    Shutdown = 3,
};

[[nodiscard]] constexpr std::string_view toString(Lifecycle l) noexcept {
    switch (l) {
        case Lifecycle::None:     return "NONE";
        case Lifecycle::Startup:  return "STARTUP";
        case Lifecycle::Runtime:  return "RUNTIME";
        case Lifecycle::Shutdown: return "SHUTDOWN";
    }
    return "LIFECYCLE_UNKNOWN";
}

// =============================================================================
// 2. Errors
// =============================================================================
enum class CtrlError : std::uint16_t {
    Ok = 0,

    // --- configuration ----------------------------------------------------
    // ⚠ ConfigMissingBuildId is its own code and not "ConfigInvalid" because it
    //   is the one configuration mistake that must never be recoverable by a
    //   default. host/README.md §3.1 step 1.
    ConfigMissingBuildId = 1,
    ConfigMissingDevicePath = 2,
    ConfigInvalid = 3,
    ConfigFileUnreadable = 4,
    ConfigParseError = 5,
    ConfigForbiddenInProduction = 6,  // a relaxation that only UAT may have

    // --- transport --------------------------------------------------------
    DeviceNotOpen = 10,
    BusRead = 11,
    BusWrite = 12,
    BusVerify = 13,  // a register did not read back what we wrote
    // ⚠ Every register read that comes back 0xFFFFFFFF is treated as a probable
    //   link-down / surprise-removal until corroborated against IDENT_MAGIC. On
    //   PCIe an unsuccessful completion is synthesised by the root complex as
    //   all-ones; a host that believes it read a limit of 4294967295 has read
    //   the absence of a card.
    LinkDown = 14,
    Timeout = 15,
    RetriesExhausted = 16,

    // --- identity (startup step 1) ----------------------------------------
    IdentityMagicWrong = 20,
    BuildIdMismatch = 21,        // ⚠ HARD STOP. Never a warning.
    GitShaMismatch = 22,
    RegmapVersionMismatch = 23,  // MAJOR only; MINOR is additive and warns
    CapsMismatch = 24,           // fabric geometry != types.hpp geometry
    KillRespCyclesMismatch = 25,

    // --- the fail-closed baseline (manual 08/09 §2) -----------------------
    TradingEnabledAtEntry = 30,  // someone else is driving this card
    ArmedAtEntry = 31,
    KillLatched = 32,            // ⚠ latched kill; a human must clear it
    KillClearNotSupported = 33,  // ⚠ no clear register exists in the reg map
    ForeignWriterDetected = 34,  // a control register moved under us

    // --- parameter staging / commit ---------------------------------------
    ParamStageFailed = 40,          // paramd could not write the inactive bank
    ParamImageSizeWrong = 41,
    ParamTargetIsLiveBank = 42,     // ⚠ we were about to write the LIVE bank
    ParamActiveBankUndecodable = 43,
    ParamReadBackMismatch = 44,     // PARAM_*_RB != the word we intended
    ParamHostCrcMismatch = 45,      // CRC of the read-back != CRC of the intent
    ParamFabricCrcMismatch = 46,    // PARAM_*_CRC != host CRC of the live bank
    ParamGenerationDidNotMove = 47, // commit not accepted
    ParamGenerationJumped = 48,     // moved by != 1: a second writer exists
    ParamBankDidNotFlip = 49,
    ParamBankFlippedToWrongBank = 50,
    FilterReadBackMismatch = 51,
    FilterEntryInvalid = 52,        // locate or active index out of range

    // --- session (startup step 5) -----------------------------------------
    SessionConfigureFailed = 60,
    SessionNotUp = 61,
    SessionLinkDown = 62,
    SessionDriverMissing = 63,

    // --- heartbeat (startup step 6) ---------------------------------------
    HeartbeatDriverMissing = 70,  // ⚠ refuse to arm: nothing is feeding the watchdog
    HeartbeatStartFailed = 71,
    HeartbeatNotObserved = 72,    // CTRL_HB_AGE_MS never came down: fabric is not seeing us
    HeartbeatStale = 73,          // age crossed the warn threshold while running
    HeartbeatStopFailed = 74,

    // --- the two-step arm (startup step 7) --------------------------------
    ArmNonceUnavailable = 80,
    ArmWindowExpired = 81,       // could not land ARM_EXEC inside CTRL_ARM_WINDOW_MS
    ArmNotConfirmed = 82,        // CTRL_ARMED did not read back set
    ArmRefusedKillActive = 83,
    ArmRefusedNotConfigured = 84,  // an earlier state has not completed
    ArmAttemptsExhausted = 85,
    ArmUnexpectedlyLost = 86,    // ⚠ CTRL_ARMED cleared under us

    // --- enable trading (startup step 8) ----------------------------------
    TradingEnableRejected = 90,  // CTRL_TRADING_EN did not read back set
    HealthFatal = 91,            // types.hpp health::FATAL_MASK is non-zero

    // --- sequencing / API misuse ------------------------------------------
    WrongLifecycleState = 100,
    StateOutOfOrder = 101,
    AlreadyRunning = 102,
    NotRunning = 103,
    AbortedByOperator = 104,   // SIGTERM / SIGINT arrived mid-sequence
    AbortedByPriorFailure = 105,

    // --- catch-alls --------------------------------------------------------
    NotImplemented = 110,
    Internal = 111,
};

[[nodiscard]] constexpr std::string_view toString(CtrlError e) noexcept {
    switch (e) {
        case CtrlError::Ok:                          return "OK";
        case CtrlError::ConfigMissingBuildId:        return "CONFIG_MISSING_BUILD_ID";
        case CtrlError::ConfigMissingDevicePath:     return "CONFIG_MISSING_DEVICE_PATH";
        case CtrlError::ConfigInvalid:               return "CONFIG_INVALID";
        case CtrlError::ConfigFileUnreadable:        return "CONFIG_FILE_UNREADABLE";
        case CtrlError::ConfigParseError:            return "CONFIG_PARSE_ERROR";
        case CtrlError::ConfigForbiddenInProduction: return "CONFIG_FORBIDDEN_IN_PRODUCTION";
        case CtrlError::DeviceNotOpen:               return "DEVICE_NOT_OPEN";
        case CtrlError::BusRead:                     return "BUS_READ";
        case CtrlError::BusWrite:                    return "BUS_WRITE";
        case CtrlError::BusVerify:                   return "BUS_VERIFY";
        case CtrlError::LinkDown:                    return "LINK_DOWN";
        case CtrlError::Timeout:                     return "TIMEOUT";
        case CtrlError::RetriesExhausted:            return "RETRIES_EXHAUSTED";
        case CtrlError::IdentityMagicWrong:          return "IDENTITY_MAGIC_WRONG";
        case CtrlError::BuildIdMismatch:             return "BUILD_ID_MISMATCH";
        case CtrlError::GitShaMismatch:              return "GIT_SHA_MISMATCH";
        case CtrlError::RegmapVersionMismatch:       return "REGMAP_VERSION_MISMATCH";
        case CtrlError::CapsMismatch:                return "CAPS_MISMATCH";
        case CtrlError::KillRespCyclesMismatch:      return "KILL_RESP_CYCLES_MISMATCH";
        case CtrlError::TradingEnabledAtEntry:       return "TRADING_ENABLED_AT_ENTRY";
        case CtrlError::ArmedAtEntry:                return "ARMED_AT_ENTRY";
        case CtrlError::KillLatched:                 return "KILL_LATCHED";
        case CtrlError::KillClearNotSupported:       return "KILL_CLEAR_NOT_SUPPORTED";
        case CtrlError::ForeignWriterDetected:       return "FOREIGN_WRITER_DETECTED";
        case CtrlError::ParamStageFailed:            return "PARAM_STAGE_FAILED";
        case CtrlError::ParamImageSizeWrong:         return "PARAM_IMAGE_SIZE_WRONG";
        case CtrlError::ParamTargetIsLiveBank:       return "PARAM_TARGET_IS_LIVE_BANK";
        case CtrlError::ParamActiveBankUndecodable:  return "PARAM_ACTIVE_BANK_UNDECODABLE";
        case CtrlError::ParamReadBackMismatch:       return "PARAM_READ_BACK_MISMATCH";
        case CtrlError::ParamHostCrcMismatch:        return "PARAM_HOST_CRC_MISMATCH";
        case CtrlError::ParamFabricCrcMismatch:      return "PARAM_FABRIC_CRC_MISMATCH";
        case CtrlError::ParamGenerationDidNotMove:   return "PARAM_GENERATION_DID_NOT_MOVE";
        case CtrlError::ParamGenerationJumped:       return "PARAM_GENERATION_JUMPED";
        case CtrlError::ParamBankDidNotFlip:         return "PARAM_BANK_DID_NOT_FLIP";
        case CtrlError::ParamBankFlippedToWrongBank: return "PARAM_BANK_FLIPPED_TO_WRONG_BANK";
        case CtrlError::FilterReadBackMismatch:      return "FILTER_READ_BACK_MISMATCH";
        case CtrlError::FilterEntryInvalid:          return "FILTER_ENTRY_INVALID";
        case CtrlError::SessionConfigureFailed:      return "SESSION_CONFIGURE_FAILED";
        case CtrlError::SessionNotUp:                return "SESSION_NOT_UP";
        case CtrlError::SessionLinkDown:             return "SESSION_LINK_DOWN";
        case CtrlError::SessionDriverMissing:        return "SESSION_DRIVER_MISSING";
        case CtrlError::HeartbeatDriverMissing:      return "HEARTBEAT_DRIVER_MISSING";
        case CtrlError::HeartbeatStartFailed:        return "HEARTBEAT_START_FAILED";
        case CtrlError::HeartbeatNotObserved:        return "HEARTBEAT_NOT_OBSERVED";
        case CtrlError::HeartbeatStale:              return "HEARTBEAT_STALE";
        case CtrlError::HeartbeatStopFailed:         return "HEARTBEAT_STOP_FAILED";
        case CtrlError::ArmNonceUnavailable:         return "ARM_NONCE_UNAVAILABLE";
        case CtrlError::ArmWindowExpired:            return "ARM_WINDOW_EXPIRED";
        case CtrlError::ArmNotConfirmed:             return "ARM_NOT_CONFIRMED";
        case CtrlError::ArmRefusedKillActive:        return "ARM_REFUSED_KILL_ACTIVE";
        case CtrlError::ArmRefusedNotConfigured:     return "ARM_REFUSED_NOT_CONFIGURED";
        case CtrlError::ArmAttemptsExhausted:        return "ARM_ATTEMPTS_EXHAUSTED";
        case CtrlError::ArmUnexpectedlyLost:         return "ARM_UNEXPECTEDLY_LOST";
        case CtrlError::TradingEnableRejected:       return "TRADING_ENABLE_REJECTED";
        case CtrlError::HealthFatal:                 return "HEALTH_FATAL";
        case CtrlError::WrongLifecycleState:         return "WRONG_LIFECYCLE_STATE";
        case CtrlError::StateOutOfOrder:             return "STATE_OUT_OF_ORDER";
        case CtrlError::AlreadyRunning:              return "ALREADY_RUNNING";
        case CtrlError::NotRunning:                  return "NOT_RUNNING";
        case CtrlError::AbortedByOperator:           return "ABORTED_BY_OPERATOR";
        case CtrlError::AbortedByPriorFailure:       return "ABORTED_BY_PRIOR_FAILURE";
        case CtrlError::NotImplemented:              return "NOT_IMPLEMENTED";
        case CtrlError::Internal:                    return "INTERNAL";
    }
    return "CTRL_ERROR_UNKNOWN";
}

// =============================================================================
// 3. Severity — decides how far back toward the reset state we go
// -----------------------------------------------------------------------------
// manual 08/09 §2: the reset state is fail-closed and a fresh device is already
// safe. Every failure here disables trading. The question severity answers is
// the SECOND one: do we also latch the hardware kill?
//
//   Benign      the device was never moved out of the fail-closed state, or the
//               failure is a configuration mistake caught before any write.
//               Disable trading (which it already is) and stop.
//   Operational something outside the card did not come up — the venue session,
//               the heartbeat driver. Disable trading. Do not latch: the fix is
//               to start the missing piece and re-run startup, and a latched
//               kill would need a human with a runbook for a problem that does
//               not warrant one.
//   Integrity   ⚠ the card disagrees with us about its own state: a read-back
//               mismatch, a CRC mismatch, a generation counter that moved twice,
//               a control register that changed under us. We no longer know what
//               is in the fabric. Disable trading AND latch the kill, because
//               "we are not sure" is exactly the case manual 08/09 §0.1 says
//               must reject.
// =============================================================================
enum class FailSeverity : std::uint8_t {
    Benign = 0,
    Operational = 1,
    Integrity = 2,
};

[[nodiscard]] constexpr std::string_view toString(FailSeverity s) noexcept {
    switch (s) {
        case FailSeverity::Benign:      return "BENIGN";
        case FailSeverity::Operational: return "OPERATIONAL";
        case FailSeverity::Integrity:   return "INTEGRITY";
    }
    return "SEVERITY_UNKNOWN";
}

[[nodiscard]] constexpr FailSeverity severityOf(CtrlError e) noexcept {
    switch (e) {
        // Caught before we touched anything, or the device is simply not there.
        case CtrlError::Ok:
        case CtrlError::ConfigMissingBuildId:
        case CtrlError::ConfigMissingDevicePath:
        case CtrlError::ConfigInvalid:
        case CtrlError::ConfigFileUnreadable:
        case CtrlError::ConfigParseError:
        case CtrlError::ConfigForbiddenInProduction:
        case CtrlError::DeviceNotOpen:
        case CtrlError::IdentityMagicWrong:
        case CtrlError::BuildIdMismatch:
        case CtrlError::GitShaMismatch:
        case CtrlError::RegmapVersionMismatch:
        case CtrlError::CapsMismatch:
        case CtrlError::KillRespCyclesMismatch:
        case CtrlError::KillLatched:
        case CtrlError::KillClearNotSupported:
        case CtrlError::WrongLifecycleState:
        case CtrlError::AlreadyRunning:
        case CtrlError::NotRunning:
        case CtrlError::NotImplemented:
            return FailSeverity::Benign;

        // Something outside the card is missing or not ready.
        case CtrlError::SessionConfigureFailed:
        case CtrlError::SessionNotUp:
        case CtrlError::SessionLinkDown:
        case CtrlError::SessionDriverMissing:
        case CtrlError::HeartbeatDriverMissing:
        case CtrlError::HeartbeatStartFailed:
        case CtrlError::HeartbeatNotObserved:
        case CtrlError::ArmWindowExpired:
        case CtrlError::ArmRefusedKillActive:
        case CtrlError::ArmRefusedNotConfigured:
        case CtrlError::ArmAttemptsExhausted:
        case CtrlError::ParamStageFailed:
        case CtrlError::ParamImageSizeWrong:
        case CtrlError::FilterEntryInvalid:
        case CtrlError::AbortedByOperator:
        case CtrlError::AbortedByPriorFailure:
            return FailSeverity::Operational;

        // ⚠ Everything else means the card and the host disagree about state.
        default:
            return FailSeverity::Integrity;
    }
}

// =============================================================================
// 4. CtrlFailure — the whole story, in 40-odd bytes and no allocations
// =============================================================================
inline constexpr std::uint32_t kNoIndex = 0xFFFF'FFFFu;

struct CtrlFailure {
    CtrlError code = CtrlError::Ok;
    Lifecycle lifecycle = Lifecycle::None;
    std::uint8_t state = 0;   // StartupState or ShutdownState, per `lifecycle`
    std::uint32_t offset = 0; // BAR0 byte offset involved, 0 if none
    std::uint64_t expected = 0;
    std::uint64_t actual = 0;
    std::uint32_t symIdx = kNoIndex;
    std::uint32_t wordIdx = kNoIndex;
    std::int32_t busCode = 0;  // the underlying trading::DeviceError, preserved
    std::uint32_t attempts = 0;

    [[nodiscard]] constexpr FailSeverity severity() const noexcept { return severityOf(code); }
    [[nodiscard]] constexpr bool perSymbol() const noexcept { return symIdx != kNoIndex; }
};

// Trivially copyable so it can live in an expected<> without any heap traffic
// and be memcpy'd into an audit record.
static_assert(sizeof(CtrlFailure) <= 64, "CtrlFailure must stay small and POD");

[[nodiscard]] constexpr CtrlFailure makeFailure(CtrlError c, Lifecycle lc = Lifecycle::None,
                                                std::uint8_t st = 0) noexcept {
    CtrlFailure f{};
    f.code = c;
    f.lifecycle = lc;
    f.state = st;
    return f;
}

[[nodiscard]] constexpr CtrlFailure makeRegFailure(CtrlError c, std::uint32_t offset,
                                                   std::uint64_t expected,
                                                   std::uint64_t actual) noexcept {
    CtrlFailure f{};
    f.code = c;
    f.offset = offset;
    f.expected = expected;
    f.actual = actual;
    return f;
}

// =============================================================================
// 5. Result aliases
// =============================================================================
template <class T>
using CtrlResult = expected<T, CtrlFailure>;
using CtrlStatus = expected<void, CtrlFailure>;

// =============================================================================
// 6. The all-ones read
// -----------------------------------------------------------------------------
// ⚠ 0xFFFFFFFF from a control register is a link-down/surprise-removal signature
//   until proven otherwise. On PCIe, an Unsupported Request or a Completion
//   Timeout is synthesised by the root complex as all-ones data; a hot-removed
//   card, a card in reset, and a card behind a downed link all read this way.
//
//   The pattern is only SUSPICIOUS, not conclusive: a CRC register or a
//   free-running counter may legitimately hold 0xFFFFFFFF. So the rule ctrld
//   applies is: on seeing all-ones from a register where all-ones is not a
//   plausible value, corroborate by re-reading IDENT_MAGIC. If that is ALSO
//   all-ones, the link is gone. See Controller::confirmLinkAlive().
// =============================================================================
inline constexpr std::uint32_t kAllOnes = 0xFFFF'FFFFu;

[[nodiscard]] constexpr bool isAllOnes(std::uint32_t v) noexcept { return v == kAllOnes; }

}  // namespace trading::ctrld

#endif  // TRADING_CTRLD_CTRL_ERROR_HPP
