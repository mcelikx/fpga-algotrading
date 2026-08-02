// =============================================================================
// views.hpp — the three sources of truth, as three incompatible types
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : host/src/reconciler
// Mirrors : rtl/risk/position_monitor.sv   (position_t, working shares, open
//                                           orders, gross/net notional, the
//                                           saturation flags)
//           rtl/pkg/trading_pkg.sv §2      (position_t is SIGNED 40-bit)
//
// -----------------------------------------------------------------------------
// WHY THE SOURCE IS IN THE TYPE
//   A reconciler that accidentally compares the fabric's position to the
//   fabric's position reports "no divergence" forever and is worse than no
//   reconciler at all, because it creates the appearance of a control
//   (manuals/08-nasdaq/09-risk-controls-and-limits.md §2). So the source is a
//   template parameter, the three instantiations are unrelated types, and
//   compare() static_asserts that its two arguments come from different
//   sources. `compare(fabric, fabric)` does not compile.
//
// -----------------------------------------------------------------------------
// WHAT EACH SOURCE ACTUALLY PROVES — read this before trusting a comparison
//
//   Source::Fabric      The card's own accounting, read back through the risk
//                       gate's read-back mux (rtl/risk/risk_gate.sv §11,
//                       rb_sel=5) and the telemetry shadow bank. This is the
//                       number that GATES ORDERS. It is the one that has to be
//                       right, and the only one a correction can change.
//
//   Source::HostShadow  The host's independent replay of the fabric's DMA event
//                       stream: every ORDER_SENT, FILL, VENUE_ACK, VENUE_REJECT
//                       and VENUE_BREAK record. NOTE HONESTLY: this shares an
//                       origin with Fabric, so Fabric-vs-HostShadow catches
//                       fabric accounting bugs, dropped ring records and
//                       torn/stale records — it does NOT catch anything that
//                       never reached the fabric at all.
//
//   Source::Venue       Drop copy and end-of-day clearing. The only genuinely
//                       independent observer, and therefore the only one that
//                       can catch an out-of-band trade, a fill on another
//                       system, a bust, or a corporate action. It is also the
//                       laggiest, which is what the settling window is for.
//
//   Three sources, three pairwise comparisons, and each pair answers a
//   different question. Doing only one of the three is not reconciliation.
//
// -----------------------------------------------------------------------------
// FIXED POINT, SATURATING, NO FLOATS
//   Positions are signed integer shares (trading_pkg::position_t, 40 bits).
//   Notionals are ITCH-scaled integers (4 implied decimals) in 64 bits.
//   Every accumulator here SATURATES and reports that it saturated, because a
//   wrapped counter does not breach a limit loudly — it silently deletes it
//   (manual 08/09 §3, "The catastrophe"). A saturated accumulator on ANY of the
//   three views means the host no longer knows the position, and that is a kill
//   trigger, not a log line.
// =============================================================================
#ifndef TRADING_RECONCILER_VIEWS_HPP
#define TRADING_RECONCILER_VIEWS_HPP

#include <array>
#include <cstdint>
#include <string_view>

#include "trading/reconciler/error.hpp"
#include "trading/types.hpp"

namespace trading::reconciler {

// =============================================================================
// 1. Source tags
// =============================================================================
enum class Source : std::uint8_t {
    Fabric = 0,      // the card's own counters (the ones that gate orders)
    HostShadow = 1,  // the host's replay of the fabric DMA event stream
    Venue = 2,       // drop copy + clearing (the independent observer)
};
inline constexpr std::size_t kNumSources = 3;

[[nodiscard]] constexpr std::string_view toString(Source s) noexcept {
    switch (s) {
        case Source::Fabric:     return "FABRIC";
        case Source::HostShadow: return "HOST_SHADOW";
        case Source::Venue:      return "VENUE";
    }
    return "SOURCE_UNKNOWN";
}

// =============================================================================
// 2. Saturating arithmetic for the signed 40-bit position and the signed
//    64-bit net notional
// -----------------------------------------------------------------------------
// types.hpp already provides satAdd64 / satSub64 for UNSIGNED 64-bit values and
// orderNotional() for the 32x32->64 product. It does not provide a SIGNED
// saturating add clamped to the fabric's 40-bit position range, because nothing
// else in host/ accumulates a position. These two functions are the missing
// signed cases, not a competing implementation — they mirror `sat_add_s` in
// manuals/08-nasdaq/09-risk-controls-and-limits.md §3 and the clamping in
// rtl/risk/position_monitor.sv (POS_MAX / POS_MIN).
//
// ⚠ Clamping to POSITION_MIN/MAX rather than to int64 is deliberate. The host
//   must saturate at exactly the value the FABRIC saturates at, or the host will
//   fail to notice the fabric has saturated.
// =============================================================================
struct SatPosition {
    position_t value = 0;
    bool saturated = false;
};

[[nodiscard]] constexpr SatPosition satAddPosition(position_t a, position_t b) noexcept {
    // int64 cannot overflow here: both operands are within +/-2^39.
    const std::int64_t s = a + b;
    if (s > POSITION_MAX) return {POSITION_MAX, true};
    if (s < POSITION_MIN) return {POSITION_MIN, true};
    return {static_cast<position_t>(s), false};
}

struct SatSigned64 {
    std::int64_t value = 0;
    bool saturated = false;
};

inline constexpr std::int64_t NET_NOTIONAL_MAX = INT64_MAX;
inline constexpr std::int64_t NET_NOTIONAL_MIN = INT64_MIN;

// mirrors rtl/risk/position_monitor.sv net_q saturation (NET_MAX / NET_MIN).
[[nodiscard]] constexpr SatSigned64 satAddNetNotional(std::int64_t a, std::int64_t b) noexcept {
    if (b > 0 && a > NET_NOTIONAL_MAX - b) return {NET_NOTIONAL_MAX, true};
    if (b < 0 && a < NET_NOTIONAL_MIN - b) return {NET_NOTIONAL_MIN, true};
    return {a + b, false};
}

// Absolute magnitude of a position difference, as an unsigned value that cannot
// itself overflow. |POSITION_MIN| does not fit in position_t; it does fit here.
[[nodiscard]] constexpr std::uint64_t absDelta(position_t a, position_t b) noexcept {
    return a >= b ? static_cast<std::uint64_t>(a - b) : static_cast<std::uint64_t>(b - a);
}

[[nodiscard]] constexpr std::uint64_t absDelta64(std::int64_t a, std::int64_t b) noexcept {
    // Computed in unsigned space so INT64_MIN - INT64_MAX does not trap.
    const std::uint64_t ua = static_cast<std::uint64_t>(a);
    const std::uint64_t ub = static_cast<std::uint64_t>(b);
    return a >= b ? (ua - ub) : (ub - ua);
}

[[nodiscard]] constexpr std::uint64_t absDeltaU64(std::uint64_t a, std::uint64_t b) noexcept {
    return a >= b ? a - b : b - a;
}

// =============================================================================
// 3. Per-symbol state, tagged by source
// -----------------------------------------------------------------------------
// mirrors the per-symbol record in rtl/risk/position_monitor.sv:
//   pos (position_t, signed 40b), work_buy / work_sell (qty_t), open (16b)
// =============================================================================
template <Source S>
struct SymbolState {
    static constexpr Source kSource = S;

    sym_idx_t sym = 0;

    // ⚠ FAIL-CLOSED. A default-constructed view is NOT "flat"; it is "unknown".
    //   Treating an unpopulated venue view as a zero position would either
    //   manufacture a divergence equal to the whole book, or — far worse —
    //   agree with a fabric that had also been zeroed by a restart. Every
    //   comparison checks `valid` on BOTH sides first.
    bool valid = false;

    position_t position = 0;      // signed shares. Long positive, short negative.
    qty_t workingBuy = 0;         // sent-and-unfilled buy shares
    qty_t workingSell = 0;        // sent-and-unfilled sell shares
    std::uint16_t openOrders = 0; // resting order count
    qty_t cumBoughtQty = 0;       // cumulative executed shares, buy side
    qty_t cumSoldQty = 0;         // cumulative executed shares, sell side
    notional_t grossNotional = 0; // ITCH-scaled, always saturating
    std::int64_t netNotional = 0; // ITCH-scaled, signed, always saturating

    // Set the moment any accumulator above hit its rail. Sticky for the life of
    // the view. This is a kill trigger (manual 08/09 §3), not a warning.
    bool saturated = false;

    // Monotonic host time of the newest input that contributed to this view.
    // Used for staleness, never for ordering against another source's clock.
    MonoNs asOfNs = 0;

    friend constexpr bool operator==(const SymbolState&, const SymbolState&) = default;
};

using FabricSymbolState = SymbolState<Source::Fabric>;
using ShadowSymbolState = SymbolState<Source::HostShadow>;
using VenueSymbolState = SymbolState<Source::Venue>;

// The three are genuinely distinct types. If this ever stops being true, the
// whole safety property of this header is gone.
static_assert(!std::is_same_v<FabricSymbolState, VenueSymbolState>);
static_assert(!std::is_same_v<FabricSymbolState, ShadowSymbolState>);
static_assert(!std::is_same_v<ShadowSymbolState, VenueSymbolState>);

// =============================================================================
// 4. Aggregate (whole-account) state, tagged by source
// -----------------------------------------------------------------------------
// The fabric maintains these directly (agg_pos, gross_notional, net_notional,
// agg_open in rtl/risk/position_monitor.sv) and enforces the account-level
// limits against them. The host must compare them in aggregate as well as per
// symbol: a set of per-symbol errors that happen to cancel is still an error,
// and an aggregate that matches while the symbols do not is a symbol-mapping
// bug — the one that puts a position in the wrong name.
// =============================================================================
template <Source S>
struct AggregateState {
    static constexpr Source kSource = S;

    bool valid = false;
    position_t netShares = 0;        // signed sum over symbols, saturating
    std::uint64_t grossShares = 0;   // sum of |position| — never cancels out
    notional_t grossNotional = 0;
    std::int64_t netNotional = 0;
    std::uint32_t openOrders = 0;
    std::uint32_t symbolsCovered = 0;
    bool saturated = false;
    MonoNs asOfNs = 0;

    friend constexpr bool operator==(const AggregateState&, const AggregateState&) = default;
};

using FabricAggregate = AggregateState<Source::Fabric>;
using ShadowAggregate = AggregateState<Source::HostShadow>;
using VenueAggregate = AggregateState<Source::Venue>;

// =============================================================================
// 5. Deltas — the only sanctioned way to compare two views
// -----------------------------------------------------------------------------
// compare(reference, observed) is directional and the direction is in the type.
// Deltas are (observed - reference), so a positive positionDelta means the
// observed source thinks we are LONGER than the reference source does.
// =============================================================================
template <Source Ref, Source Obs>
struct SymbolDelta {
    static_assert(Ref != Obs,
                  "comparing a source against itself is not a reconciliation — it is a "
                  "control that can never fire (manual 08/09 §2)");

    static constexpr Source kReference = Ref;
    static constexpr Source kObserved = Obs;

    sym_idx_t sym = 0;

    // False when either side is invalid. A delta computed against an unknown is
    // not a divergence; it is a gap in coverage, and it is classified as one.
    bool comparable = false;
    bool referenceValid = false;
    bool observedValid = false;

    std::int64_t positionDelta = 0;   // observed - reference, in shares
    std::uint64_t positionAbs = 0;    // |positionDelta|, overflow-proof
    std::int64_t workingBuyDelta = 0;
    std::int64_t workingSellDelta = 0;
    std::int64_t openOrdersDelta = 0;
    std::int64_t cumBoughtDelta = 0;
    std::int64_t cumSoldDelta = 0;
    std::uint64_t grossNotionalAbs = 0;
    std::uint64_t netNotionalAbs = 0;

    // Either side saturated. Propagated, never swallowed.
    bool eitherSaturated = false;

    [[nodiscard]] constexpr bool positionMatches() const noexcept {
        return comparable && positionDelta == 0;
    }
    [[nodiscard]] constexpr bool quantityMatches() const noexcept {
        return comparable && cumBoughtDelta == 0 && cumSoldDelta == 0;
    }
    [[nodiscard]] constexpr bool clean() const noexcept {
        return comparable && positionDelta == 0 && workingBuyDelta == 0 &&
               workingSellDelta == 0 && openOrdersDelta == 0 && cumBoughtDelta == 0 &&
               cumSoldDelta == 0 && !eitherSaturated;
    }
};

template <Source Ref, Source Obs>
[[nodiscard]] constexpr SymbolDelta<Ref, Obs> compare(const SymbolState<Ref>& reference,
                                                      const SymbolState<Obs>& observed) noexcept {
    SymbolDelta<Ref, Obs> d{};
    d.sym = reference.valid ? reference.sym : observed.sym;
    d.referenceValid = reference.valid;
    d.observedValid = observed.valid;
    d.comparable = reference.valid && observed.valid;
    d.eitherSaturated = reference.saturated || observed.saturated;
    if (!d.comparable) return d;

    d.positionDelta = static_cast<std::int64_t>(observed.position) -
                      static_cast<std::int64_t>(reference.position);
    d.positionAbs = absDelta(reference.position, observed.position);
    d.workingBuyDelta = static_cast<std::int64_t>(observed.workingBuy) -
                        static_cast<std::int64_t>(reference.workingBuy);
    d.workingSellDelta = static_cast<std::int64_t>(observed.workingSell) -
                         static_cast<std::int64_t>(reference.workingSell);
    d.openOrdersDelta = static_cast<std::int64_t>(observed.openOrders) -
                        static_cast<std::int64_t>(reference.openOrders);
    d.cumBoughtDelta = static_cast<std::int64_t>(observed.cumBoughtQty) -
                       static_cast<std::int64_t>(reference.cumBoughtQty);
    d.cumSoldDelta = static_cast<std::int64_t>(observed.cumSoldQty) -
                     static_cast<std::int64_t>(reference.cumSoldQty);
    d.grossNotionalAbs = absDeltaU64(reference.grossNotional, observed.grossNotional);
    d.netNotionalAbs = absDelta64(reference.netNotional, observed.netNotional);
    return d;
}

template <Source Ref, Source Obs>
struct AggregateDelta {
    static_assert(Ref != Obs, "an aggregate cannot be reconciled against itself");

    static constexpr Source kReference = Ref;
    static constexpr Source kObserved = Obs;

    bool comparable = false;
    std::int64_t netSharesDelta = 0;
    std::uint64_t netSharesAbs = 0;
    std::uint64_t grossSharesAbs = 0;
    std::uint64_t grossNotionalAbs = 0;
    std::uint64_t netNotionalAbs = 0;
    std::int64_t openOrdersDelta = 0;
    bool eitherSaturated = false;

    [[nodiscard]] constexpr bool clean() const noexcept {
        return comparable && netSharesDelta == 0 && openOrdersDelta == 0 && !eitherSaturated;
    }
};

template <Source Ref, Source Obs>
[[nodiscard]] constexpr AggregateDelta<Ref, Obs> compare(
    const AggregateState<Ref>& reference, const AggregateState<Obs>& observed) noexcept {
    AggregateDelta<Ref, Obs> d{};
    d.comparable = reference.valid && observed.valid;
    d.eitherSaturated = reference.saturated || observed.saturated;
    if (!d.comparable) return d;

    d.netSharesDelta = static_cast<std::int64_t>(observed.netShares) -
                       static_cast<std::int64_t>(reference.netShares);
    d.netSharesAbs = absDelta(reference.netShares, observed.netShares);
    d.grossSharesAbs = absDeltaU64(reference.grossShares, observed.grossShares);
    d.grossNotionalAbs = absDeltaU64(reference.grossNotional, observed.grossNotional);
    d.netNotionalAbs = absDelta64(reference.netNotional, observed.netNotional);
    d.openOrdersDelta = static_cast<std::int64_t>(observed.openOrders) -
                        static_cast<std::int64_t>(reference.openOrders);
    return d;
}

// =============================================================================
// 6. A whole book of per-symbol state for one source
// -----------------------------------------------------------------------------
// Statically sized at N_ACTIVE (trading_pkg::N_ACTIVE = 256, the filtered set).
// No dynamic memory: this array is a member of the reconciler, allocated once.
// =============================================================================
template <Source S>
class SymbolBook {
public:
    static constexpr Source kSource = S;
    static constexpr std::size_t kCapacity = N_ACTIVE;

    SymbolBook() noexcept { reset(); }

    void reset() noexcept {
        for (std::size_t i = 0; i < kCapacity; ++i) {
            sym_[i] = SymbolState<S>{};
            sym_[i].sym = static_cast<sym_idx_t>(i);
        }
        agg_ = AggregateState<S>{};
    }

    [[nodiscard]] static constexpr bool inRange(std::uint32_t sym) noexcept {
        return sym < kCapacity;
    }

    [[nodiscard]] SymbolState<S>& at(sym_idx_t sym) noexcept { return sym_[sym]; }
    [[nodiscard]] const SymbolState<S>& at(sym_idx_t sym) const noexcept { return sym_[sym]; }

    [[nodiscard]] AggregateState<S>& aggregate() noexcept { return agg_; }
    [[nodiscard]] const AggregateState<S>& aggregate() const noexcept { return agg_; }

    // Recompute the aggregate from the per-symbol rows, saturating exactly the
    // way the fabric does. Returns false if any accumulation saturated — which
    // the caller must escalate, not log.
    bool recomputeAggregate(MonoNs nowNs) noexcept {
        AggregateState<S> a{};
        a.asOfNs = nowNs;
        bool anyValid = false;
        for (const auto& s : sym_) {
            if (!s.valid) continue;
            anyValid = true;
            ++a.symbolsCovered;

            const SatPosition p = satAddPosition(a.netShares, s.position);
            a.netShares = p.value;
            a.saturated |= p.saturated;

            const std::uint64_t mag =
                s.position >= 0 ? static_cast<std::uint64_t>(s.position)
                                : static_cast<std::uint64_t>(-(s.position + 1)) + 1ull;
            const std::uint64_t gs = satAdd64(a.grossShares, mag);
            a.saturated |= (gs == NOTIONAL_MAX && a.grossShares != NOTIONAL_MAX);
            a.grossShares = gs;

            const notional_t gn = satAdd64(a.grossNotional, s.grossNotional);
            a.saturated |= (gn == NOTIONAL_MAX && a.grossNotional != NOTIONAL_MAX);
            a.grossNotional = gn;

            const SatSigned64 nn = satAddNetNotional(a.netNotional, s.netNotional);
            a.netNotional = nn.value;
            a.saturated |= nn.saturated;

            const std::uint64_t oo =
                static_cast<std::uint64_t>(a.openOrders) + static_cast<std::uint64_t>(s.openOrders);
            if (oo > UINT32_MAX) {
                a.openOrders = UINT32_MAX;
                a.saturated = true;
            } else {
                a.openOrders = static_cast<std::uint32_t>(oo);
            }

            a.saturated |= s.saturated;
        }
        a.valid = anyValid;
        agg_ = a;
        return !a.saturated;
    }

private:
    std::array<SymbolState<S>, kCapacity> sym_{};
    AggregateState<S> agg_{};
};

using FabricBook = SymbolBook<Source::Fabric>;
using ShadowBook = SymbolBook<Source::HostShadow>;
using VenueBook = SymbolBook<Source::Venue>;

}  // namespace trading::reconciler

#endif  // TRADING_RECONCILER_VIEWS_HPP
