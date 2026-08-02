// =============================================================================
// paramd/compute.cpp — deriving sym_risk_t and sym_strat_t, in integers only
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : paramd (the parameter engine)
// Primary reference: manuals/08-nasdaq/09-risk-controls-and-limits.md §1, §2, §10
//
// ⚠ There is no `double`, no `float`, and no `std::pow` in this file, and there
//   must never be. Every ratio is an integer mul-then-div with the rounding
//   direction chosen so that being wrong is being conservative.
// =============================================================================
#include "trading/paramd/compute.hpp"

#include <algorithm>

namespace trading::paramd {

// =============================================================================
// Risk limits
// -----------------------------------------------------------------------------
// The record is built field by field, each annotated with its manual 08/09 §1
// row and the regulation that row cites. A field with no basis does not belong
// in a pre-trade risk record.
// =============================================================================
SymRisk computeRiskLimits(const RiskMandate& mandate, const SymbolRiskInputs& inputs) noexcept {
    // manual 08/09 §2: start from the fail-closed record and only ever relax it
    // deliberately. Never start from a template with plausible numbers in it.
    SymRisk r = kFailClosedRisk;

    // -------------------------------------------------------------------------
    // Gate: everything that must be true before ANY limit is populated.
    //
    // §1 #3  per-symbol enabled            15c3-5(c)(2)
    // §1 #24 restricted / hard-to-borrow   firm policy, Reg SHO
    // §1 #9  LULD band                     LULD Plan  — an unknown band is not a
    //                                      wide band (§0 principle 1)
    // §1 #29 parameter validity            fail-closed
    //
    // Any failure here returns the all-zero record, which is bit-identical to
    // sym_risk_t's RTL reset value.
    // -------------------------------------------------------------------------
    if (!inputs.present) return r;
    if (!mandate.symbolApproved) return r;
    if (mandate.restricted || mandate.hardToBorrow) return r;
    if (inputs.referencePx == 0) return r;
    if (!inputs.luldValid || inputs.luldHi == 0 || inputs.luldLo > inputs.luldHi) return r;
    if (mandate.maxOrderShares == 0 || mandate.maxOrderDollars == 0) return r;
    if (mandate.maxOpenOrders == 0) return r;
    if (mandate.maxLongShares == 0 && mandate.maxShortShares == 0) return r;
    if (mandate.collarBps == 0) return r;

    // -------------------------------------------------------------------------
    // §1 #7 tick validity — SEC Rule 612.
    // An NMS stock priced at or above $1.00 quotes in whole cents; below $1.00
    // the minimum increment is $0.0001, which every ITCH price already satisfies.
    // ⚠ The reciprocal-multiply div100 in trading_pkg.sv is only proven exact for
    // px < 2^31, so a price above that cannot be held to the penny grid with the
    // same arithmetic the fabric uses — fail closed rather than disagree.
    // -------------------------------------------------------------------------
    const bool tickPenny = rule612RequiresPenny(inputs.referencePx);
    if (tickPenny && !priceInRecipExactRange(inputs.referencePx)) return r;

    // -------------------------------------------------------------------------
    // §1 #8 price collar — 15c3-5(c)(1)(ii).
    // referencePx * (1 +/- collarBps/10000), with each end rounded INWARD:
    // the floor rounds up, the ceiling rounds down, then both snap onto the tick
    // grid in the same inward direction. Every rounding decision here narrows
    // the band; none widens it.
    // -------------------------------------------------------------------------
    const std::uint64_t delta = applyBpsUp(inputs.referencePx, mandate.collarBps);
    std::uint64_t lo64 = inputs.referencePx > delta ? inputs.referencePx - delta : 0;
    std::uint64_t hi64 = satAdd(inputs.referencePx, delta);

    price_t collarLo = clampPrice(lo64);
    price_t collarHi = clampPrice(hi64);
    collarLo = roundUpToTick(collarLo, tickPenny);    // inward: raise the floor
    collarHi = roundDownToTick(collarHi, tickPenny);  // inward: lower the ceiling

    // A collar so tight it inverted (a sub-penny band on the penny grid) is not
    // a usable control.
    if (collarHi == 0 || collarLo > collarHi) return r;

    // -------------------------------------------------------------------------
    // §1 #9 LULD band — LULD Plan. Market state, mirrored in verbatim. The host
    // does not "adjust" a regulatory band; it copies it.
    // -------------------------------------------------------------------------
    r.luldLo = inputs.luldLo;
    r.luldHi = inputs.luldHi;

    // -------------------------------------------------------------------------
    // §1 #13 max order shares — 15c3-5(c)(1)(ii).
    // The share cap is the tighter of what the risk owner stated and what the
    // dollar cap permits at the collar ceiling (the most expensive price an
    // order could legally carry). Both divisions floor; sizes round DOWN.
    // -------------------------------------------------------------------------
    const notional_t notionalCap = dollarsToNotional(mandate.maxOrderDollars);
    // sharesAtCeiling = notionalCap / collarHi, floored. collarHi > 0 here.
    const std::uint64_t sharesAtCeiling = notionalCap / static_cast<std::uint64_t>(collarHi);
    std::uint64_t shares = std::min<std::uint64_t>(mandate.maxOrderShares, sharesAtCeiling);
    if (mandate.roundSizesToLot) {
        shares = roundDownToLot(clampQty(shares));
    }
    if (shares == 0) {
        // The dollar cap cannot buy a single lot at the ceiling. That is a
        // coherent instruction to not trade this symbol; express it the only way
        // the record can — fail closed.
        return kFailClosedRisk;
    }

    // -------------------------------------------------------------------------
    // §1 #14 max order notional — 15c3-5(c)(1)(i).
    // Units: notional = price(x10000) * qty, so a dollar figure scales by
    // PRICE_SCALE. dollarsToNotional() saturates.
    // -------------------------------------------------------------------------
    r.maxOrderNotional = notionalCap;
    r.maxOrderQty = clampQty(shares);

    // -------------------------------------------------------------------------
    // §1 #15 / #16 max position long and short — 15c3-5(c)(1)(i).
    // max_short_pos is a POSITIVE magnitude (trading_pkg.sv comment). Both are
    // clamped into position_t's signed 40-bit range; a value that would truncate
    // is not written.
    // -------------------------------------------------------------------------
    r.maxLongPos = clampPosition(mandate.maxLongShares);
    r.maxShortPos = clampPosition(mandate.maxShortShares);

    // -------------------------------------------------------------------------
    // §1 #19 max open orders per symbol — 15c3-5.
    // -------------------------------------------------------------------------
    r.maxOpenOrders = mandate.maxOpenOrders;

    // -------------------------------------------------------------------------
    // §1 #11 short-sale permission — Reg SHO Rule 203(b).
    // Shortable only if the risk owner approved shorting AND a locate exists
    // that covers at least one maximum-size order. A locate of zero is not a
    // locate.
    // -------------------------------------------------------------------------
    r.shortable = mandate.shortingApproved && inputs.locateShares >= shares &&
                  mandate.maxShortShares > 0;

    // -------------------------------------------------------------------------
    // §1 #10 SSR — Reg SHO Rule 201. Market state from ITCH 'Y', mirrored in.
    // -------------------------------------------------------------------------
    r.ssrActive = inputs.ssrActive;

    r.collarLo = collarLo;
    r.collarHi = collarHi;
    r.tickPenny = tickPenny;

    // §1 #3 — the enable is the LAST thing set, after every limit above it has a
    // value. That ordering is not cosmetic: an early return anywhere above
    // yields a record with enabled = 0.
    r.enabled = true;
    return r;
}

RiskTable computeRiskTable(std::span<const RiskMandate> mandates,
                           std::span<const SymbolRiskInputs> inputs) noexcept {
    RiskTable t{};
    t.fill(kFailClosedRisk);
    const std::size_t n = std::min({mandates.size(), inputs.size(), std::size_t{N_ACTIVE}});
    for (std::size_t s = 0; s < n; ++s) {
        t[s] = computeRiskLimits(mandates[s], inputs[s]);
    }
    return t;
}

// =============================================================================
// Strategy parameters
// =============================================================================
std::optional<price_t> computeFairValue(const BookSnapshot& book, bool useMicroprice) noexcept {
    // manual 08/09 §1 check #6 (stale book) and trading_pkg.sv book_top_t
    // (`crossed`: "never act on a crossed book"). A fair value derived from a
    // book we do not trust is worse than no fair value, because it looks fine.
    if (!book.valid || book.stale || book.crossed) return std::nullopt;
    if (book.bidPx == 0 || book.askPx == 0) return std::nullopt;
    if (book.askPx <= book.bidPx) return std::nullopt;

    if (!useMicroprice || (book.bidQty == 0 && book.askQty == 0)) {
        // Plain mid, rounded to nearest. bid + ask cannot overflow 64 bits.
        const std::uint64_t sum =
            static_cast<std::uint64_t>(book.bidPx) + static_cast<std::uint64_t>(book.askPx);
        return clampPrice((sum + 1) / 2);
    }

    // Microprice = (bid*askQty + ask*bidQty) / (bidQty + askQty)
    //            = bid + (ask - bid) * bidQty / (bidQty + askQty)
    //
    // The rewritten form keeps the widest intermediate at (ask-bid) * bidQty,
    // a 32x32 -> 64 product that cannot overflow, and needs no 128-bit type.
    // Rounding is to nearest. The weight is dimensionless, so the result stays
    // in ITCH-scaled units.
    const std::uint64_t spread =
        static_cast<std::uint64_t>(book.askPx) - static_cast<std::uint64_t>(book.bidPx);
    const std::uint64_t den =
        static_cast<std::uint64_t>(book.bidQty) + static_cast<std::uint64_t>(book.askQty);
    if (den == 0) return clampPrice((static_cast<std::uint64_t>(book.bidPx) +
                                     static_cast<std::uint64_t>(book.askPx) + 1) /
                                    2);
    const std::uint64_t adj = mulDivNearest(spread, book.bidQty, den);
    return clampPrice(static_cast<std::uint64_t>(book.bidPx) + adj);
}

SymStrat computeStratParams(const StratPolicy& policy, const BookSnapshot& book,
                            price_t referencePx) noexcept {
    // Same discipline as the risk path: start fail-closed.
    SymStrat s = kFailClosedStrat;

    if (!policy.enabled) return s;
    if (policy.stratSelect > STRAT_SELECT_MAX) return s;

    const std::optional<price_t> fair = computeFairValue(book, policy.useMicroprice);
    if (!fair.has_value() || *fair == 0) return s;

    // The tick grid the risk gate will hold this symbol to (Rule 612, §1 #7).
    // Derived from the reference price, NOT read out of the risk record: reading
    // the risk record here would couple the strategy commit path to the risk
    // commit path, and host/README.md §3.3 requires them to be independent.
    const bool tickPenny = tickPennyFor(referencePx);
    if (tickPenny && !priceInRecipExactRange(*fair)) return s;

    // fair_value snaps to the NEAREST tick; it is an estimate, not a limit, so
    // nearest is the honest rounding.
    const price_t fairValue = roundNearestToTick(*fair, tickPenny);
    if (fairValue == 0) return s;

    // -------------------------------------------------------------------------
    // edge_ticks: max(minEdge, fairValue * edgeBps / 10000), rounded UP, then
    // snapped UP onto the tick grid, then clamped to maxEdge.
    //
    // Rounding UP is deliberate: a larger edge means the primitive fires less
    // readily. When the arithmetic has to break a tie, it breaks it towards
    // doing nothing.
    // -------------------------------------------------------------------------
    std::uint64_t edge = applyBpsUp(fairValue, policy.edgeBps);
    edge = std::max<std::uint64_t>(edge, policy.minEdgeScaled);
    price_t edgeTicks = roundUpToTick(clampPrice(edge), tickPenny);
    if (policy.maxEdgeScaled > 0 && edgeTicks > policy.maxEdgeScaled) {
        edgeTicks = roundDownToTick(policy.maxEdgeScaled, tickPenny);
    }
    if (edgeTicks == 0) return s;  // no edge is not a strategy, it is a bug

    // The quote must stay on the grid AND stay positive: fair - edge is the bid
    // the primitive would post.
    if (edgeTicks >= fairValue) return s;

    // -------------------------------------------------------------------------
    // quote_qty: targetNotional / fairValue, floored, clamped to the policy
    // range, rounded DOWN to whole lots. Sizes always round down.
    //   units: dollars * PRICE_SCALE / (price * PRICE_SCALE) = shares.
    // -------------------------------------------------------------------------
    const notional_t targetNotional = dollarsToNotional(policy.targetNotionalDollars);
    std::uint64_t qty = targetNotional / static_cast<std::uint64_t>(fairValue);
    if (policy.maxQuoteQty > 0) qty = std::min<std::uint64_t>(qty, policy.maxQuoteQty);
    if (policy.roundQuoteToLot) qty = roundDownToLot(clampQty(qty));
    if (qty < policy.minQuoteQty) {
        // Cannot make the minimum size the policy demands at this price. Leave
        // the symbol fail-closed rather than quoting a size nobody asked for.
        return kFailClosedStrat;
    }
    if (qty == 0) return kFailClosedStrat;

    s.quoteQty = clampQty(qty);
    s.fairValue = fairValue;
    s.edgeTicks = edgeTicks;
    s.minBookQty = clampQty(satMul64(s.quoteQty, policy.minBookQtyMultiple));
    s.imbalanceThr = policy.imbalanceThr;
    s.stratSelect = policy.stratSelect;
    // Enabled last, after every field above it has a value.
    s.stratEnabled = true;
    return s;
}

StratTable computeStratTable(std::span<const StratPolicy> policies,
                             std::span<const BookSnapshot> books,
                             std::span<const price_t> referencePx) noexcept {
    StratTable t{};
    t.fill(kFailClosedStrat);
    const std::size_t n =
        std::min({policies.size(), books.size(), referencePx.size(), std::size_t{N_ACTIVE}});
    for (std::size_t s = 0; s < n; ++s) {
        t[s] = computeStratParams(policies[s], books[s], referencePx[s]);
    }
    return t;
}

}  // namespace trading::paramd
