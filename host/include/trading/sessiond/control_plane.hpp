// =============================================================================
// control_plane.hpp — sessiond's dependency on ctrld, and the credit ledger
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : host/src/sessiond  (the INTERFACE; ctrld implements it)
//
// ⚠️ WHY THIS INTERFACE EXISTS
//    host/README.md §2: `ctrld` "owns the PCIe register interface. The only
//    writer of control registers." sessiond owns the SESSION block at 0x3000
//    and NOTHING in the CONTROL block at 0x1000. When a session fault must stop
//    the fabric emitting, sessiond does not reach across and write CTRL_KILL —
//    it asks ctrld, and then it VERIFIES. "Coordinate with the kill/disarm path,
//    do not just hope."
//
//    The verification half matters more than the request half. disarmOrderPath()
//    that returns success without emissionBlocked() confirming it is exactly the
//    kind of assumption that turns a recoverable session drop into orders
//    arriving at a venue that has already forgotten who we are.
// =============================================================================
#pragma once

#include <cstdint>
#include "trading/expected.hpp"

#include "trading/sessiond/session_state.hpp"

namespace trading::sessiond {

// Kill provenance codes come from trading/types.hpp (KillSrc), which mirrors
// trading_pkg::kill_src_e. ⚠️ The one sessiond ever raises is
// KillSrc::SeqFault (7) — an unrecoverable session sequence fault.
using KillSrc = trading::KillSrc;

// Bounds how many orders the fabric may have outstanding-and-unaccounted.
// trading::MAX_IN_FLIGHT mirrors trading_pkg::MAX_IN_FLIGHT (= 64).
inline constexpr std::uint32_t kMaxInFlight = trading::MAX_IN_FLIGHT;

// =============================================================================
// The slice of ctrld that sessiond depends on.
// =============================================================================
class ControlPlane {
 public:
    virtual ~ControlPlane() = default;

    // Stop the fabric being able to emit. Implemented by ctrld as a disarm
    // (CTRL_TRADING_EN low / CTRL_ARMED cleared) — a graceful stop, not a kill.
    virtual trading::expected<void, SessionError> disarmOrderPath() = 0;

    // Re-permit emission. ⚠️ sessiond calls this ONLY as the last step of a
    // completed resynchronise, after the template has been rewritten and
    // verified and the sequence reconciled.
    virtual trading::expected<void, SessionError> armOrderPath() = 0;

    // Proof, read back from the fabric, that no order can leave. sessiond
    // refuses to proceed with a reconnect until this returns true.
    [[nodiscard]] virtual trading::expected<bool, SessionError> emissionBlocked() const = 0;

    // Latch the hardware kill switch with a provenance code. Used for
    // KillSrc::SeqFault; the fabric latches it sticky for post-incident analysis.
    virtual trading::expected<void, SessionError> requestKill(KillSrc kill_src) = 0;

    // Return exactly ONE in-flight credit to the fabric.
    // ⚠️ CTRL_CREDIT_RETURN (0x1020) drives `cfg_credit_return`, which is a
    //    single-bit pulse in rtl/fpga_top.sv — one write returns one credit, the
    //    value written is not a count. CreditLedger::flush() therefore issues N
    //    writes, and bounds N per call so a large correction cannot monopolise
    //    the register interface.
    virtual trading::expected<void, SessionError> returnCredit() = 0;
};

// =============================================================================
// CreditLedger — what actually bounds position drift
// -----------------------------------------------------------------------------
// The FPGA encodes an order in ~40 ns. The host learns about it over PCIe and a
// DMA ring, microseconds later. Nothing about that asymmetry can be fixed by
// making the host faster, so it is not fixed by speed: the fabric may have at
// most MAX_IN_FLIGHT (64) orders outstanding-and-unaccounted, and when that
// budget is exhausted IT STOPS SENDING. A strategy bug, a decode error or a feed
// glitch can therefore put at most 64 orders into the market before the host has
// a say — which is the difference between an incident and a firm-ending event.
// See manuals/08-nasdaq/05-ouch-5.0-order-entry.md §11.
//
// The host returns credit as it accounts for terminal outbound messages
// (Accepted-then-Canceled, fully Executed, Rejected, Broken Trade) on the
// SoupBinTCP sequenced stream — the authoritative record. Every returned credit
// is one more order the fabric may send.
//
// ⚠️ CREDIT LEAKS ARE SILENT. A missed terminal message is a credit never
//    returned; the path throttles toward zero and looks exactly like a market
//    with no opportunities. Hence `outstanding()`, `min_available_observed()`
//    and the periodic resync() from the authoritative stream. Alert on the
//    watermark, not on a symptom.
//
// ⚠️ DOUBLE-RETURN IS ALSO A BUG, in the opposite direction: rtl/order/ouch_rx
//    can be built to return credit itself on terminal messages
//    (CREDIT_RETURN_ON_EXEC). If it does, the host must NOT also return per
//    message — it corrects with resync() instead. `fabric_auto_returns` selects
//    which regime this ledger is in, and it must match the RTL build.
// =============================================================================
class CreditLedger {
 public:
    explicit CreditLedger(bool fabric_auto_returns,
                          std::uint32_t max_in_flight = kMaxInFlight) noexcept
        : max_in_flight_(max_in_flight), fabric_auto_returns_(fabric_auto_returns) {}

    // The host observed an order leaving (from the DMA log ring / TX record).
    void noteOrderEmitted(std::uint32_t n = 1) noexcept;

    // The host accounted for a terminal outbound OUCH message on the sequenced
    // stream. In the host-returns regime this queues a credit return.
    void noteTerminalAccounted(std::uint32_t n = 1) noexcept;

    // Recompute from the authoritative stream. `outstanding` is the number of
    // orders the host believes are live-and-unaccounted right now. Used at
    // startup, after any resynchronise, and periodically — this is the only
    // thing that repairs a leak.
    void resync(std::uint32_t outstanding) noexcept;

    // Push queued returns to the fabric. Returns the number actually issued.
    // `max_this_call` bounds the burst; the rest waits for the next call.
    [[nodiscard]] trading::expected<std::uint32_t, SessionError> flush(
            ControlPlane& cp, std::uint32_t max_this_call = 16);

    [[nodiscard]] std::uint32_t outstanding() const noexcept { return outstanding_; }
    [[nodiscard]] std::uint32_t pendingReturns() const noexcept { return pending_returns_; }
    [[nodiscard]] std::uint32_t available() const noexcept {
        return (outstanding_ >= max_in_flight_) ? 0U : (max_in_flight_ - outstanding_);
    }
    // ⚠️ Alert on this, not on order count. A falling watermark is a leak.
    [[nodiscard]] std::uint32_t minAvailableObserved() const noexcept { return min_available_; }
    [[nodiscard]] std::uint64_t totalReturned() const noexcept { return total_returned_; }

 private:
    std::uint32_t max_in_flight_;
    bool          fabric_auto_returns_;
    std::uint32_t outstanding_      = 0;
    std::uint32_t pending_returns_  = 0;
    std::uint32_t min_available_    = kMaxInFlight;
    std::uint64_t total_returned_   = 0;
};

}  // namespace trading::sessiond
