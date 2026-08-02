// =============================================================================
// error.hpp — the reconciler's error vocabulary
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : host/src/reconciler
//
// NO EXCEPTIONS ON CONTROL PATHS (CLAUDE.md, host/README.md §3). Every fallible
// operation in the reconciler returns ReconResult<T> / ReconStatus. An exception
// unwinding out of a reconciliation pass would leave the fabric's accounting
// state half-corrected with no record of how far it got — which is precisely the
// state this component exists to make impossible.
//
// The reconciler does not reuse trading::DeviceError because most of its
// failures are not device failures: a drop copy that stopped arriving, an
// unmatched token, a correction whose effect could not be proven. Device errors
// are wrapped (see deviceError() / lastDeviceError()) rather than flattened, so
// the cause survives into the audit record.
// =============================================================================
#ifndef TRADING_RECONCILER_ERROR_HPP
#define TRADING_RECONCILER_ERROR_HPP

#include <cstdint>
#include <string_view>

#include "trading/expected.hpp"

namespace trading::reconciler {

enum class ReconError : std::uint16_t {
    None = 0,

    // --- configuration -------------------------------------------------------
    ConfigInvalid,           // validate() rejected the config; see validate()'s message
    ConfigMissingRequired,   // a field with no safe default was left unset
    SettlingWindowTooLong,   // ⚠ an unbounded settle is how a real break gets ignored
    RetentionTooShort,       // order retention < venue lag + settling: manufactures phantoms
    NotStarted,
    AlreadyStarted,

    // --- device / control plane ---------------------------------------------
    DeviceFault,             // an underlying trading::DeviceError; see lastDeviceError()
    ParamWindowBusy,         // ⚠ the PARAM_RISK addr/data pair is shared with paramd
    ReadbackTimeout,         // the risk read-back mux did not produce a value
    CorrectionNotApplied,    // ⚠⚠ recon_cnt did not increment: we CANNOT prove the
                             //    fabric took the correction. Escalates to a kill.
    KillAssertFailed,        // ⚠⚠ CTRL_KILL written, CTRL_KILL_ACTIVE did not set

    // --- inputs --------------------------------------------------------------
    LogSourceFault,
    LogSourceGap,            // a hole in the fabric event stream: shadow is incomplete
    DropCopyDown,
    DropCopyStale,           // ⚠ no venue truth within venueTruthMaxAgeNs
    DropCopyMalformed,
    ClearingUnavailable,
    ClearingMalformed,

    // --- matching ------------------------------------------------------------
    TokenMagicMismatch,      // ⚠⚠ stale session or corruption. Immediate escalation.
    TokenMalformed,          // sym / strat / counter outside the issued space
    UnknownSymbol,

    // --- capacity ------------------------------------------------------------
    OrderTableFull,          // fixed-capacity shadow table exhausted
    DivergenceTableFull,
    BufferTooSmall,

    // --- audit ---------------------------------------------------------------
    AuditSinkFault,          // ⚠ a correction that could not be recorded did not happen
                             //   as far as compliance is concerned
    Io,
};

[[nodiscard]] constexpr std::string_view toString(ReconError e) noexcept {
    switch (e) {
        case ReconError::None:                  return "NONE";
        case ReconError::ConfigInvalid:         return "CONFIG_INVALID";
        case ReconError::ConfigMissingRequired: return "CONFIG_MISSING_REQUIRED";
        case ReconError::SettlingWindowTooLong: return "SETTLING_WINDOW_TOO_LONG";
        case ReconError::RetentionTooShort:     return "RETENTION_TOO_SHORT";
        case ReconError::NotStarted:            return "NOT_STARTED";
        case ReconError::AlreadyStarted:        return "ALREADY_STARTED";
        case ReconError::DeviceFault:           return "DEVICE_FAULT";
        case ReconError::ParamWindowBusy:       return "PARAM_WINDOW_BUSY";
        case ReconError::ReadbackTimeout:       return "READBACK_TIMEOUT";
        case ReconError::CorrectionNotApplied:  return "CORRECTION_NOT_APPLIED";
        case ReconError::KillAssertFailed:      return "KILL_ASSERT_FAILED";
        case ReconError::LogSourceFault:        return "LOG_SOURCE_FAULT";
        case ReconError::LogSourceGap:          return "LOG_SOURCE_GAP";
        case ReconError::DropCopyDown:          return "DROP_COPY_DOWN";
        case ReconError::DropCopyStale:         return "DROP_COPY_STALE";
        case ReconError::DropCopyMalformed:     return "DROP_COPY_MALFORMED";
        case ReconError::ClearingUnavailable:   return "CLEARING_UNAVAILABLE";
        case ReconError::ClearingMalformed:     return "CLEARING_MALFORMED";
        case ReconError::TokenMagicMismatch:    return "TOKEN_MAGIC_MISMATCH";
        case ReconError::TokenMalformed:        return "TOKEN_MALFORMED";
        case ReconError::UnknownSymbol:         return "UNKNOWN_SYMBOL";
        case ReconError::OrderTableFull:        return "ORDER_TABLE_FULL";
        case ReconError::DivergenceTableFull:   return "DIVERGENCE_TABLE_FULL";
        case ReconError::BufferTooSmall:        return "BUFFER_TOO_SMALL";
        case ReconError::AuditSinkFault:        return "AUDIT_SINK_FAULT";
        case ReconError::Io:                    return "IO";
    }
    return "RECON_ERROR_UNKNOWN";
}

template <class T>
using ReconResult = expected<T, ReconError>;
using ReconStatus = expected<void, ReconError>;

// -----------------------------------------------------------------------------
// Monotonic host time. Integer nanoseconds everywhere — no floats, no
// std::chrono::duration<double>. Ages, windows and rate buckets are all computed
// on this clock, never on a wall clock: a leap second or an NTP step must not be
// able to reset a settling window or fake a correction rate.
// -----------------------------------------------------------------------------
using MonoNs = std::uint64_t;

[[nodiscard]] constexpr MonoNs msToNs(std::uint64_t ms) noexcept { return ms * 1'000'000ull; }
[[nodiscard]] constexpr MonoNs secToNs(std::uint64_t s) noexcept { return s * 1'000'000'000ull; }
[[nodiscard]] constexpr std::uint64_t nsToMs(MonoNs ns) noexcept { return ns / 1'000'000ull; }

class ITimeSource {
public:
    virtual ~ITimeSource() = default;
    [[nodiscard]] virtual MonoNs nowNs() const noexcept = 0;
};

// steady_clock, in nanoseconds since an arbitrary epoch. Never goes backwards.
class SteadyTimeSource final : public ITimeSource {
public:
    [[nodiscard]] MonoNs nowNs() const noexcept override;
};

// Test double: time only moves when a test says so, which is the only way to
// prove a settling window is bounded without waiting for it in real time.
class ManualTimeSource final : public ITimeSource {
public:
    [[nodiscard]] MonoNs nowNs() const noexcept override { return now_; }
    void set(MonoNs t) noexcept { now_ = t; }
    void advance(MonoNs d) noexcept { now_ += d; }

private:
    MonoNs now_ = 0;
};

}  // namespace trading::reconciler

#endif  // TRADING_RECONCILER_ERROR_HPP
