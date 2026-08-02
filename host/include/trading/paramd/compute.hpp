// =============================================================================
// paramd/compute.hpp — deriving risk limits and strategy parameters, in integers
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : paramd (the parameter engine)
// Primary reference: manuals/08-nasdaq/09-risk-controls-and-limits.md §1, §2, §10
//
// -----------------------------------------------------------------------------
// ⚠ NO FLOATING POINT. NOT ONE.
//   CLAUDE.md §2 ("Prices as scaled integers"), §5.3, trading_pkg.sv §2, and
//   types.hpp's header all say the same thing, and this file is where the
//   temptation is strongest: a fair value is a weighted average and an edge is a
//   fraction of a spread, and both are one `double` away from being easy.
//
//   Every quantity below is an integer with a documented scale:
//     price / fair value / edge / collar : ITCH-native, PRICE_SCALE = 10000,
//                                          i.e. $12.3400 -> 123400
//     quantity                            : shares, unscaled
//     notional                            : price * qty, so ALSO x10000
//     bps                                 : integer basis points, /10000
//     ratios                              : an explicit {num, den} pair
//
//   Where a computation genuinely needs a ratio it is done as a widened integer
//   mul-then-div with the rounding direction stated and chosen to be the
//   CONSERVATIVE one — a limit rounds tighter, an edge rounds wider, a size
//   rounds down. If a model needs real arithmetic, it belongs in the Python
//   analysis tooling and hands the answer across as an integer.
// =============================================================================
#ifndef TRADING_PARAMD_COMPUTE_HPP
#define TRADING_PARAMD_COMPUTE_HPP

#include <cstdint>
#include <optional>

#include "trading/paramd/param_table.hpp"
#include "trading/paramd/validation.hpp"
#include "trading/types.hpp"

namespace trading::paramd {

// =============================================================================
// 1. Integer arithmetic primitives
// -----------------------------------------------------------------------------
// All saturating. manual 08/09 §3: "Every position, notional, and exposure
// counter saturates. None wrap." A limit computed through a wrapped multiply is
// the failure mode that section calls "the single worst failure mode in the
// whole design".
// =============================================================================
inline constexpr std::uint64_t U64_MAX = ~std::uint64_t{0};

[[nodiscard]] constexpr std::uint64_t satMul64(std::uint64_t a, std::uint64_t b) noexcept {
    if (a == 0 || b == 0) return 0;
    if (a > U64_MAX / b) return U64_MAX;
    return a * b;
}

[[nodiscard]] constexpr std::uint64_t satAdd(std::uint64_t a, std::uint64_t b) noexcept {
    return satAdd64(a, b);  // types.hpp, mirrors trading_pkg::sat_add64
}

// floor((a*b)/d) and ceil((a*b)/d), saturating. The product is formed in 64 bits
// with a saturating multiply, so a caller that hands in absurd inputs gets
// U64_MAX rather than a wrapped value that looks reasonable.
[[nodiscard]] constexpr std::uint64_t mulDivFloor(std::uint64_t a, std::uint64_t b,
                                                  std::uint64_t d) noexcept {
    if (d == 0) return U64_MAX;
    return satMul64(a, b) / d;
}
[[nodiscard]] constexpr std::uint64_t mulDivCeil(std::uint64_t a, std::uint64_t b,
                                                 std::uint64_t d) noexcept {
    if (d == 0) return U64_MAX;
    const std::uint64_t p = satMul64(a, b);
    if (p == U64_MAX) return U64_MAX;
    return (p + d - 1) / d;
}
[[nodiscard]] constexpr std::uint64_t mulDivNearest(std::uint64_t a, std::uint64_t b,
                                                    std::uint64_t d) noexcept {
    if (d == 0) return U64_MAX;
    const std::uint64_t p = satMul64(a, b);
    if (p == U64_MAX) return U64_MAX;
    return (p + d / 2) / d;
}

[[nodiscard]] constexpr std::uint64_t clampU64(std::uint64_t v, std::uint64_t lo,
                                               std::uint64_t hi) noexcept {
    return v < lo ? lo : (v > hi ? hi : v);
}

[[nodiscard]] constexpr price_t clampPrice(std::uint64_t v) noexcept {
    return static_cast<price_t>(v > PRICE_MAX ? PRICE_MAX : v);
}
[[nodiscard]] constexpr qty_t clampQty(std::uint64_t v) noexcept {
    return static_cast<qty_t>(v > QTY_MAX ? QTY_MAX : v);
}
[[nodiscard]] constexpr position_t clampPosition(std::uint64_t v) noexcept {
    return static_cast<position_t>(v > static_cast<std::uint64_t>(POSITION_MAX)
                                       ? POSITION_MAX
                                       : static_cast<position_t>(v));
}

// Basis points. bps is an integer; the divisor is spelled out so nobody has to
// remember whether "bps" meant 1e-4 or 1e-2 here.
inline constexpr std::uint64_t BPS_DEN = 10'000;

[[nodiscard]] constexpr std::uint64_t applyBpsDown(std::uint64_t v, std::uint32_t bps) noexcept {
    return mulDivFloor(v, bps, BPS_DEN);
}
[[nodiscard]] constexpr std::uint64_t applyBpsUp(std::uint64_t v, std::uint32_t bps) noexcept {
    return mulDivCeil(v, bps, BPS_DEN);
}

// Dollars -> the fabric's notional units. notional = price * qty, price carries
// 4 implied decimals, so a notional is also x10000.
//   $25,000 -> 250,000,000
[[nodiscard]] constexpr notional_t dollarsToNotional(std::uint64_t dollars) noexcept {
    return satMul64(dollars, PRICE_SCALE);
}
static_assert(dollarsToNotional(25'000) == 250'000'000ull,
              "notional scale drifted: notional = price(x10000) * qty");
static_assert(orderNotional(123'400u, 100u) == 12'340'000ull,
              "100 shares at $12.34 is $1,234.00 = 12,340,000 in fabric units");

// =============================================================================
// 2. Tick-grid arithmetic — mirrors trading_pkg.sv, no divider
// -----------------------------------------------------------------------------
// Rounding uses types.hpp::div100(), which is trading_pkg::div100's reciprocal
// multiply. Rounding a price with `/ 100` here and testing it with the
// reciprocal multiply in fabric is exactly the kind of near-agreement that
// produces a Rule 612 reject nobody can reproduce.
// =============================================================================
[[nodiscard]] constexpr price_t roundDownToPenny(price_t px) noexcept {
    return div100(px) * TICK_PENNY_SCALED;
}
[[nodiscard]] constexpr price_t roundUpToPenny(price_t px) noexcept {
    const price_t lo = roundDownToPenny(px);
    if (lo == px) return px;
    // Saturate rather than wrap past $429,496.7295.
    return (lo > PRICE_MAX - TICK_PENNY_SCALED) ? lo : static_cast<price_t>(lo + TICK_PENNY_SCALED);
}
[[nodiscard]] constexpr price_t roundNearestPenny(price_t px) noexcept {
    const price_t lo = roundDownToPenny(px);
    return (px - lo >= TICK_PENNY_SCALED / 2) ? roundUpToPenny(px) : lo;
}
static_assert(roundDownToPenny(123'456u) == 123'400u);
static_assert(roundUpToPenny(123'456u) == 123'500u);
static_assert(roundNearestPenny(123'456u) == 123'500u);
static_assert(roundNearestPenny(123'449u) == 123'400u);
static_assert(roundUpToPenny(123'400u) == 123'400u, "an exact penny must not be nudged");
static_assert(isWholePenny(roundNearestPenny(999'999u)), "the result is always on the grid");

// tickPenny selects the grid; below $1.00 Rule 612's minimum increment is
// $0.0001, which every ITCH price already satisfies.
[[nodiscard]] constexpr price_t roundDownToTick(price_t px, bool tickPenny) noexcept {
    return tickPenny ? roundDownToPenny(px) : px;
}
[[nodiscard]] constexpr price_t roundUpToTick(price_t px, bool tickPenny) noexcept {
    return tickPenny ? roundUpToPenny(px) : px;
}
[[nodiscard]] constexpr price_t roundNearestToTick(price_t px, bool tickPenny) noexcept {
    return tickPenny ? roundNearestPenny(px) : px;
}

// Round a share count down to whole round lots. Rounding DOWN is the
// conservative direction for anything that is a size.
inline constexpr qty_t ROUND_LOT = 100;
[[nodiscard]] constexpr qty_t roundDownToLot(qty_t q) noexcept { return (q / ROUND_LOT) * ROUND_LOT; }

// =============================================================================
// 3. Risk limits
// -----------------------------------------------------------------------------
// The mandate is what the RISK OWNER approved (manual 08/09 §9: "A named risk
// owner sets limits. Not the strategy developer, not the person on the desk").
// paramd's job is to turn it into a sym_risk_t deterministically, so that the
// record on the card can be re-derived from the mandate and diffed against it —
// §9's "read-back diff is the control that catches everything else".
//
// EVERY FIELD IS ANNOTATED WITH ITS §1 ROW AND ITS REGULATORY BASIS.
// =============================================================================
struct RiskMandate {
    // ---- approval state. Without these the record is fail-closed. ----------
    bool symbolApproved = false;  // §1 #3 per-symbol enabled, 15c3-5(c)(2)
    bool restricted = false;      // §1 #24 restricted list, firm policy / Reg SHO
    bool hardToBorrow = false;    // §1 #24
    bool shortingApproved = false;  // §1 #11 short-sale permission, Reg SHO 203(b)

    // ---- sizes, as the risk owner states them ------------------------------
    qty_t maxOrderShares = 0;         // §1 #13 max order shares, 15c3-5(c)(1)(ii)
    std::uint64_t maxOrderDollars = 0;  // §1 #14 max order notional, 15c3-5(c)(1)(i)
    std::uint64_t maxLongShares = 0;  // §1 #15 max position long,  15c3-5(c)(1)(i)
    std::uint64_t maxShortShares = 0; // §1 #16 max position short, 15c3-5(c)(1)(i)
    std::uint16_t maxOpenOrders = 0;  // §1 #19 max open orders per symbol, 15c3-5

    // ---- price collar ------------------------------------------------------
    // §1 #8 price collar vs reference, 15c3-5(c)(1)(ii). Expressed in bps around
    // the reference price so one mandate covers a $3 name and a $600 name.
    std::uint32_t collarBps = 0;

    // Round order sizes down to whole lots. Off for sub-dollar names where an
    // odd lot is normal.
    bool roundSizesToLot = true;
};

// Per-symbol inputs that are NOT the mandate: reference data and live market
// state the host mirrors into the record. manual 08/09 §6 keeps these logically
// in the same record but physically in a different memory; on the host side they
// are simply a different struct so it is obvious which values a human approved
// and which the feed supplied.
struct SymbolRiskInputs {
    bool present = false;      // false -> the symbol is not in the active set at all
    price_t referencePx = 0;   // prior close / opening print, ITCH-scaled

    // §1 #9 LULD band, LULD Plan. ⚠ If the band is not known, leave both at zero
    // and the symbol comes out DISABLED. manual 08/09 §0: "Any ambiguity, any
    // uninitialised state ... reject." An unknown band is not a wide band.
    price_t luldLo = 0;
    price_t luldHi = 0;
    bool luldValid = false;

    // §1 #10 Reg SHO Rule 201 short-sale price test. From ITCH 'Y'.
    bool ssrActive = false;

    // §1 #11 Reg SHO 203(b): shares located for shorting, from the slow path.
    std::uint64_t locateShares = 0;
};

// Derive the record. Total function: any missing or contradictory input yields
// the fail-closed record rather than a partially-populated one.
[[nodiscard]] SymRisk computeRiskLimits(const RiskMandate& mandate,
                                        const SymbolRiskInputs& inputs) noexcept;

// Convenience for building a whole table. Both spans must be N_ACTIVE long.
[[nodiscard]] RiskTable computeRiskTable(std::span<const RiskMandate> mandates,
                                         std::span<const SymbolRiskInputs> inputs) noexcept;

// =============================================================================
// 4. Strategy parameters
// -----------------------------------------------------------------------------
// sym_strat_t carries fair_value, edge_ticks, quote_qty, min_book_qty and
// imbalance_thr. host/README.md §1: "Strategy parameter computation | Millisecond
// cadence, needs real math" — real, but still integer.
// =============================================================================

// Top of book as the host sees it (from goldenbook or from the telemetry shadow).
struct BookSnapshot {
    bool valid = false;
    price_t bidPx = 0;
    qty_t bidQty = 0;
    price_t askPx = 0;
    qty_t askQty = 0;
    bool crossed = false;  // bid >= ask: never derive a fair value from this
    bool stale = false;    // §1 #6 stale book, 15c3-5(c)(1)(ii)
};

struct StratPolicy {
    bool enabled = false;
    std::uint8_t stratSelect = 0;  // which hardened primitive (4 bits)

    // Fair value. `useMicroprice` weights the mid by the opposite side's size;
    // otherwise the plain mid is used. Both are exact integer computations.
    bool useMicroprice = true;

    // Edge. The threshold the primitive must beat before it acts, as a fraction
    // of the fair value in basis points, with an absolute floor in ITCH-scaled
    // price units. The result is rounded UP: a wider edge is the less aggressive
    // direction, which is the safe way to be wrong.
    std::uint32_t edgeBps = 0;
    price_t minEdgeScaled = 0;
    // Never let the computed edge exceed this. Prevents a nonsense fair value
    // from producing an edge that quotes into next week.
    price_t maxEdgeScaled = 0;

    // Size. targetNotionalDollars / fairValue, floored, clamped, then rounded
    // down to round lots.
    std::uint64_t targetNotionalDollars = 0;
    qty_t minQuoteQty = 0;
    qty_t maxQuoteQty = 0;
    bool roundQuoteToLot = true;

    // Don't act on a thin book: min_book_qty as a multiple of our own quote.
    std::uint32_t minBookQtyMultiple = 0;

    std::uint16_t imbalanceThr = 0;
};

// True when the symbol quotes on the penny grid. Rule 612 / manual 08/09 §1
// note on check #7. Derived from the reference price, NOT from the risk record —
// reading the risk record here would couple the two commit paths.
[[nodiscard]] constexpr bool tickPennyFor(price_t referencePx) noexcept {
    return rule612RequiresPenny(referencePx);
}

// Fair value from top of book. Returns nullopt when the book cannot support one
// (invalid, crossed, stale, or one side empty) — the caller then leaves the
// symbol's strategy record fail-closed rather than inventing a price.
//
// Microprice = (bid*askQty + ask*bidQty) / (bidQty + askQty), computed as
//     bid + (ask - bid) * bidQty / (bidQty + askQty)
// so the widest intermediate is (ask-bid) * bidQty, a 32x32 -> 64 product that
// cannot overflow. Rounding is to nearest.
[[nodiscard]] std::optional<price_t> computeFairValue(const BookSnapshot& book,
                                                      bool useMicroprice) noexcept;

// The full record. `referencePx` selects the tick grid; when it is on the penny
// grid, fair_value is snapped to the nearest penny and edge_ticks up to a whole
// penny, so that fair +/- edge stays on the grid and cannot trip §1 check #7.
[[nodiscard]] SymStrat computeStratParams(const StratPolicy& policy, const BookSnapshot& book,
                                          price_t referencePx) noexcept;

[[nodiscard]] StratTable computeStratTable(std::span<const StratPolicy> policies,
                                           std::span<const BookSnapshot> books,
                                           std::span<const price_t> referencePx) noexcept;

}  // namespace trading::paramd

#endif  // TRADING_PARAMD_COMPUTE_HPP
