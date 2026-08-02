// =============================================================================
// credit_ledger.cpp — in-flight credit accounting
// -----------------------------------------------------------------------------
// See control_plane.hpp for why this exists: it is what structurally bounds
// position drift between an FPGA that emits in 40 ns and a host that learns
// about it microseconds later.
// =============================================================================
#include "trading/sessiond/control_plane.hpp"

#include <algorithm>

namespace trading::sessiond {

void CreditLedger::noteOrderEmitted(std::uint32_t n) noexcept {
    // Saturate rather than wrap. A wrapped counter turns a bound into a no-op —
    // the same rule trading_pkg::sat_add64 enforces in the fabric.
    if (outstanding_ > max_in_flight_ - std::min(n, max_in_flight_)) {
        outstanding_ = max_in_flight_;
    } else {
        outstanding_ += n;
    }
    min_available_ = std::min(min_available_, available());
}

void CreditLedger::noteTerminalAccounted(std::uint32_t n) noexcept {
    const std::uint32_t d = std::min(n, outstanding_);
    outstanding_ -= d;
    if (!fabric_auto_returns_) {
        // The host owns the return in this regime.
        pending_returns_ += d;
    }
    // If the fabric auto-returns, the host stays silent here on purpose: a
    // second return would manufacture credit the fabric never spent. The
    // correction channel is resync(), which is idempotent.
}

void CreditLedger::resync(std::uint32_t outstanding) noexcept {
    outstanding_ = std::min(outstanding, max_in_flight_);
    // Any queued returns computed against the old view are void — the whole
    // point of a resync is that the authoritative stream, not our running
    // arithmetic, decides. Drop them rather than apply them on top.
    pending_returns_ = 0;
    min_available_   = std::min(min_available_, available());
}

trading::expected<std::uint32_t, SessionError> CreditLedger::flush(ControlPlane& cp,
                                                               std::uint32_t max_this_call) {
    const std::uint32_t n = std::min(pending_returns_, max_this_call);
    for (std::uint32_t i = 0; i < n; ++i) {
        // One write == one credit (cfg_credit_return is a 1-bit pulse).
        auto r = cp.returnCredit();
        if (!r.has_value()) {
            // Credit already given back stays given back; the remainder is
            // retried on the next flush. Never lose track of the difference.
            pending_returns_ -= i;
            total_returned_  += i;
            return trading::fail(r.error());
        }
    }
    pending_returns_ -= n;
    total_returned_  += n;
    return n;
}

}  // namespace trading::sessiond
