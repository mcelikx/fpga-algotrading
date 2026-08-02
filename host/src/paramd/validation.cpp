// =============================================================================
// paramd/validation.cpp — the rules that stop a bad parameter set at the door
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : paramd (the parameter engine)
// Primary reference: manuals/08-nasdaq/09-risk-controls-and-limits.md §1, §2, §9
//
// Every rule below names the §1 row it protects and the regulation behind it.
// A rule with no basis is a rule someone will delete under deadline pressure.
// =============================================================================
#include "trading/paramd/validation.hpp"

#include <string>

#include "trading/paramd/compute.hpp"

namespace trading::paramd {

// =============================================================================
// Rule names and citations
// =============================================================================
std::string_view toString(RiskRule r) noexcept {
    switch (r) {
        case RiskRule::NotPackable:              return "NOT_PACKABLE";
        case RiskRule::PositionOutOfRange:       return "POSITION_OUT_OF_RANGE";
        case RiskRule::NegativePosition:         return "NEGATIVE_POSITION";
        case RiskRule::CollarInverted:           return "COLLAR_INVERTED";
        case RiskRule::LuldInverted:             return "LULD_INVERTED";
        case RiskRule::CollarZeroCeiling:        return "COLLAR_ZERO_CEILING";
        case RiskRule::LuldZeroCeiling:          return "LULD_ZERO_CEILING";
        case RiskRule::ZeroMaxOrderQty:          return "ZERO_MAX_ORDER_QTY";
        case RiskRule::ZeroMaxOrderNotional:     return "ZERO_MAX_ORDER_NOTIONAL";
        case RiskRule::ZeroMaxOpenOrders:        return "ZERO_MAX_OPEN_ORDERS";
        case RiskRule::ZeroBothPositionLimits:   return "ZERO_BOTH_POSITION_LIMITS";
        case RiskRule::PriceNotWholePenny:       return "PRICE_NOT_WHOLE_PENNY";
        case RiskRule::PriceOutsideRecipRange:   return "PRICE_OUTSIDE_RECIP_RANGE";
        case RiskRule::SsrWithoutShortable:      return "SSR_WITHOUT_SHORTABLE";
        case RiskRule::NotionalUnreachable:      return "NOTIONAL_UNREACHABLE";
        case RiskRule::NotionalTooTight:         return "NOTIONAL_TOO_TIGHT";
        case RiskRule::OrderExceedsBothPositions:return "ORDER_EXCEEDS_BOTH_POSITIONS";
        case RiskRule::CollarWiderThanLuld:      return "COLLAR_WIDER_THAN_LULD";
        case RiskRule::EnabledWithoutBand:       return "ENABLED_WITHOUT_BAND";
    }
    return "RISK_RULE_UNKNOWN";
}

std::string_view basisOf(RiskRule r) noexcept {
    switch (r) {
        case RiskRule::NotPackable:
        case RiskRule::PositionOutOfRange:
            return "rtl/pkg/trading_pkg.sv sym_risk_t field width; a truncated limit is no limit";
        case RiskRule::NegativePosition:
            return "manual 08/09 §1 checks #15/#16; SEC Rule 15c3-5(c)(1)(i). max_short_pos is "
                   "stored as a POSITIVE magnitude (trading_pkg.sv)";
        case RiskRule::CollarInverted:
        case RiskRule::CollarZeroCeiling:
        case RiskRule::CollarWiderThanLuld:
            return "manual 08/09 §1 check #8 price collar; SEC Rule 15c3-5(c)(1)(ii)";
        case RiskRule::LuldInverted:
        case RiskRule::LuldZeroCeiling:
            return "manual 08/09 §1 check #9 LULD band; LULD Plan";
        case RiskRule::ZeroMaxOrderQty:
            return "manual 08/09 §1 check #13 max order shares; SEC Rule 15c3-5(c)(1)(ii)";
        case RiskRule::ZeroMaxOrderNotional:
        case RiskRule::NotionalUnreachable:
        case RiskRule::NotionalTooTight:
            return "manual 08/09 §1 check #14 max order notional; SEC Rule 15c3-5(c)(1)(i)";
        case RiskRule::ZeroMaxOpenOrders:
            return "manual 08/09 §1 check #19 max open orders per symbol; SEC Rule 15c3-5";
        case RiskRule::ZeroBothPositionLimits:
        case RiskRule::OrderExceedsBothPositions:
            return "manual 08/09 §1 checks #15/#16 max position; SEC Rule 15c3-5(c)(1)(i)";
        case RiskRule::PriceNotWholePenny:
        case RiskRule::PriceOutsideRecipRange:
            return "manual 08/09 §1 check #7 tick validity; SEC Rule 612";
        case RiskRule::SsrWithoutShortable:
            return "manual 08/09 §1 checks #10/#11; Reg SHO Rules 201 and 203(b)";
        case RiskRule::EnabledWithoutBand:
            return "manual 08/09 §0 principle 1 (fail closed) and §2 (a limit that resets to a "
                   "large value is worse than no limit at all)";
    }
    return "";
}

std::string_view toString(StratRule r) noexcept {
    switch (r) {
        case StratRule::NotPackable:            return "NOT_PACKABLE";
        case StratRule::UnknownPrimitive:       return "UNKNOWN_PRIMITIVE";
        case StratRule::ZeroQuoteQty:           return "ZERO_QUOTE_QTY";
        case StratRule::ZeroFairValue:          return "ZERO_FAIR_VALUE";
        case StratRule::ZeroEdgeTicks:          return "ZERO_EDGE_TICKS";
        case StratRule::ZeroMinBookQty:         return "ZERO_MIN_BOOK_QTY";
        case StratRule::NoRiskRecord:           return "NO_RISK_RECORD";
        case StratRule::FairValueOutsideCollar: return "FAIR_VALUE_OUTSIDE_COLLAR";
        case StratRule::FairValueOutsideLuld:   return "FAIR_VALUE_OUTSIDE_LULD";
        case StratRule::QuoteExceedsMaxOrderQty:return "QUOTE_EXCEEDS_MAX_ORDER_QTY";
        case StratRule::QuoteNotOnTickGrid:     return "QUOTE_NOT_ON_TICK_GRID";
    }
    return "STRAT_RULE_UNKNOWN";
}

// =============================================================================
// ValidationReport
// =============================================================================
void ValidationReport::add(ValidationIssue issue) {
    if (issue.severity == Severity::Error) {
        ++errors_;
    } else {
        ++warnings_;
    }
    issues_.push_back(std::move(issue));
}

std::string ValidationReport::render(const SymbolLabels& labels) const {
    std::string out = "=== validation: ";
    out += toString(domain_);
    out += " ===\n";
    out += "  errors: " + std::to_string(errors_) + "   warnings: " + std::to_string(warnings_) +
           "\n";
    for (const auto& i : issues_) {
        out += "  ";
        out.append(toString(i.severity));
        out += "  ";
        if (i.symIdx != 0xFFFF'FFFFu) {
            out += labels.describe(i.symIdx);
            out += "  ";
        }
        out.append(i.ruleName);
        out += ": ";
        out += i.detail;
        out.push_back('\n');
        if (!i.basis.empty()) {
            out += "        basis: ";
            out.append(i.basis);
            out.push_back('\n');
        }
    }
    return out;
}

// =============================================================================
// Helpers
// =============================================================================
namespace {

ValidationIssue mk(Severity sev, RiskRule rule, std::uint32_t sym, std::string detail) {
    ValidationIssue i{};
    i.severity = sev;
    i.rule = static_cast<std::uint16_t>(rule);
    i.ruleName = toString(rule);
    i.basis = basisOf(rule);
    i.symIdx = sym;
    i.detail = std::move(detail);
    return i;
}

ValidationIssue mk(Severity sev, StratRule rule, std::uint32_t sym, std::string detail,
                   std::string_view basis = {}) {
    ValidationIssue i{};
    i.severity = sev;
    i.rule = static_cast<std::uint16_t>(rule);
    i.ruleName = toString(rule);
    i.basis = basis;
    i.symIdx = sym;
    i.detail = std::move(detail);
    return i;
}

std::string px(price_t p) { return formatScaledPrice(p); }

// A price field of the risk record, for the Rule 612 sweep.
struct NamedPrice {
    std::string_view name;
    price_t value;
};

}  // namespace

// =============================================================================
// Risk record validation
// =============================================================================
void validateRiskRecord(const SymRisk& r, std::uint32_t symIdx, const RiskValidationConfig& cfg,
                        ValidationReport& out) {
    // -------------------------------------------------------------------------
    // 1. Representability. types.hpp's bit packer TRUNCATES silently; a
    //    truncated risk limit is a risk limit that does not exist.
    // -------------------------------------------------------------------------
    if (r.maxLongPos < 0 || r.maxShortPos < 0) {
        out.add(mk(Severity::Error, RiskRule::NegativePosition, symIdx,
                   "max_long_pos=" + std::to_string(r.maxLongPos) +
                       " max_short_pos=" + std::to_string(r.maxShortPos) +
                       "; both are magnitudes and must be >= 0"));
    }
    if (!positionInRange(r.maxLongPos) || !positionInRange(r.maxShortPos)) {
        out.add(mk(Severity::Error, RiskRule::PositionOutOfRange, symIdx,
                   "position limit outside the signed 40-bit position_t range [" +
                       std::to_string(POSITION_MIN) + ", " + std::to_string(POSITION_MAX) + "]"));
    }
    if (!isPackable(r)) {
        out.add(mk(Severity::Error, RiskRule::NotPackable, symIdx,
                   "record does not fit sym_risk_t's field widths"));
    }

    // -------------------------------------------------------------------------
    // 2. Bands must not be inverted. §1 check #8 (collar) and #9 (LULD).
    //    An inverted band admits nothing, which reads as "the symbol is broken"
    //    rather than "the symbol is disabled" — and the two are investigated
    //    very differently at 09:31.
    // -------------------------------------------------------------------------
    if (r.collarLo > r.collarHi) {
        out.add(mk(Severity::Error, RiskRule::CollarInverted, symIdx,
                   "collar_lo=" + px(r.collarLo) + " > collar_hi=" + px(r.collarHi)));
    }
    if (r.luldLo > r.luldHi) {
        out.add(mk(Severity::Error, RiskRule::LuldInverted, symIdx,
                   "luld_lo=" + px(r.luldLo) + " > luld_hi=" + px(r.luldHi)));
    }

    // -------------------------------------------------------------------------
    // 3. Rule 612 (§1 check #7). Every price in the record must sit on the grid
    //    the record itself declares. The test is types.hpp::isWholePenny(),
    //    which is trading_pkg::is_whole_penny's reciprocal multiply — NOT
    //    `% 100`. See the header comment in validation.hpp.
    // -------------------------------------------------------------------------
    if (r.tickPenny) {
        const NamedPrice prices[] = {
            {"collar_lo", r.collarLo},
            {"collar_hi", r.collarHi},
            {"luld_lo", r.luldLo},
            {"luld_hi", r.luldHi},
        };
        for (const auto& p : prices) {
            if (p.value == 0) continue;  // zero is the fail-closed sentinel, not a price
            if (!priceInRecipExactRange(p.value)) {
                out.add(mk(Severity::Error, RiskRule::PriceOutsideRecipRange, symIdx,
                           std::string(p.name) + "=" + px(p.value) +
                               " is >= 2^31; trading_pkg::div100's reciprocal multiply is only "
                               "exact below that, so the fabric's is_whole_penny would disagree "
                               "with the host"));
                continue;
            }
            if (!isWholePenny(p.value)) {
                out.add(mk(Severity::Error, RiskRule::PriceNotWholePenny, symIdx,
                           std::string(p.name) + "=" + px(p.value) +
                               " is not a whole cent but tick_penny is set"));
            }
        }
    }

    // -------------------------------------------------------------------------
    // 4. Reg SHO coherence (§1 checks #10/#11). SSR in force on a name we are
    //    not permitted to short is not dangerous — it is a sign the record was
    //    assembled from the wrong symbol's inputs.
    // -------------------------------------------------------------------------
    if (r.ssrActive && !r.shortable) {
        out.add(mk(Severity::Warning, RiskRule::SsrWithoutShortable, symIdx,
                   "ssr_active is set on a symbol that is not shortable; the SSR price test can "
                   "never be reached"));
    }

    // -------------------------------------------------------------------------
    // 5. Everything below only applies to an ENABLED symbol.
    //
    //    ⚠ manual 08/09 §2: the DISABLED, all-zero record is the correct and
    //    expected state for the overwhelming majority of the 256 slots. Zero
    //    limits on a disabled symbol are not a finding.
    // -------------------------------------------------------------------------
    if (!r.enabled) {
        return;
    }

    if (r.maxOrderQty == 0) {
        out.add(mk(Severity::Error, RiskRule::ZeroMaxOrderQty, symIdx,
                   "symbol is enabled with max_order_qty = 0; no order can pass check #13. If the "
                   "intent is 'do not trade this symbol', clear `enabled` instead — the "
                   "fail-closed record is the whole record, not one field of it"));
    }
    if (r.maxOrderNotional == 0) {
        out.add(mk(Severity::Error, RiskRule::ZeroMaxOrderNotional, symIdx,
                   "symbol is enabled with max_order_notional = 0; no order can pass check #14"));
    }
    if (r.maxOpenOrders == 0) {
        out.add(mk(Severity::Error, RiskRule::ZeroMaxOpenOrders, symIdx,
                   "symbol is enabled with max_open_orders = 0; no order can rest"));
    }
    if (r.maxLongPos == 0 && r.maxShortPos == 0) {
        out.add(mk(Severity::Error, RiskRule::ZeroBothPositionLimits, symIdx,
                   "symbol is enabled but both position limits are 0; no fill could ever be "
                   "held. A long-only mandate sets max_short_pos = 0 and a POSITIVE "
                   "max_long_pos"));
    }
    if (r.collarHi == 0) {
        out.add(mk(Severity::Error, RiskRule::CollarZeroCeiling, symIdx,
                   "symbol is enabled with collar_hi = 0; every price fails check #8"));
    }
    if (cfg.requireLuldBandWhenEnabled && r.luldHi == 0) {
        out.add(mk(Severity::Error, RiskRule::LuldZeroCeiling, symIdx,
                   "symbol is enabled with luld_hi = 0; the LULD band is unknown. manual 08/09 "
                   "§0: an unknown band is not a wide band — reject"));
    }
    if (r.collarHi == 0 && r.luldHi == 0) {
        out.add(mk(Severity::Error, RiskRule::EnabledWithoutBand, symIdx,
                   "symbol is enabled with no price band at all"));
    }

    // -------------------------------------------------------------------------
    // 6. Limits that can never bind. manual 08/09 §9: "A limit never approached
    //    in six months is probably too loose to be a control." A limit that is
    //    ARITHMETICALLY unreachable is worse — it is decoration.
    // -------------------------------------------------------------------------
    if (r.maxOrderQty > 0 && r.collarHi > 0) {
        const notional_t maxReachable = orderNotional(r.collarHi, r.maxOrderQty);
        if (r.maxOrderNotional > maxReachable) {
            out.add(mk(Severity::Warning, RiskRule::NotionalUnreachable, symIdx,
                       "max_order_notional=" + formatScaledPrice(r.maxOrderNotional) +
                           " exceeds the largest order the share limit permits (" +
                           std::to_string(r.maxOrderQty) + " shares at collar_hi " +
                           px(r.collarHi) + " = " + formatScaledPrice(maxReachable) +
                           "); the notional check can never fire"));
        }
    }
    if (r.collarLo > 0 && r.maxOrderNotional > 0) {
        const notional_t oneShare = orderNotional(r.collarLo, 1);
        if (oneShare > r.maxOrderNotional) {
            out.add(mk(Severity::Error, RiskRule::NotionalTooTight, symIdx,
                       "a single share at collar_lo " + px(r.collarLo) + " (" +
                           formatScaledPrice(oneShare) + ") already exceeds max_order_notional " +
                           formatScaledPrice(r.maxOrderNotional) + "; no order can ever pass"));
        }
    }
    if (r.maxOrderQty > 0 &&
        static_cast<std::int64_t>(r.maxOrderQty) > r.maxLongPos &&
        static_cast<std::int64_t>(r.maxOrderQty) > r.maxShortPos) {
        out.add(mk(Severity::Warning, RiskRule::OrderExceedsBothPositions, symIdx,
                   "max_order_qty=" + std::to_string(r.maxOrderQty) +
                       " exceeds both position limits (long " + std::to_string(r.maxLongPos) +
                       ", short " + std::to_string(r.maxShortPos) +
                       "); a full-size order can never be filled without breaching a position "
                       "limit"));
    }

    // -------------------------------------------------------------------------
    // 7. The firm control should be at least as tight as the regulatory band.
    //    A collar outside the LULD band is a control that the LULD check would
    //    always reach first. Warning, not error: LULD bands move intraday and a
    //    collar computed at 09:25 legitimately lags them.
    // -------------------------------------------------------------------------
    if (cfg.requireBandInsideLuld && r.luldHi > 0 && r.collarHi > 0) {
        if (r.collarLo < r.luldLo || r.collarHi > r.luldHi) {
            out.add(mk(Severity::Warning, RiskRule::CollarWiderThanLuld, symIdx,
                       "collar [" + px(r.collarLo) + ", " + px(r.collarHi) +
                           "] is not contained in the LULD band [" + px(r.luldLo) + ", " +
                           px(r.luldHi) + "]; check #9 would reject before check #8 does"));
        }
    }
}

ValidationReport validateRiskTable(const RiskTable& t, const RiskValidationConfig& cfg) {
    ValidationReport rep(ParamDomain::RiskLimits);
    for (std::uint32_t s = 0; s < N_ACTIVE; ++s) {
        validateRiskRecord(t[s], s, cfg, rep);
    }
    return rep;
}

// =============================================================================
// Strategy record validation
// -----------------------------------------------------------------------------
// ⚠ The cross-checks against the live risk table are ADVISORY and READ-ONLY.
//   A strategy commit never writes a risk limit (host/README.md §3.3); what it
//   can do is tell the operator that the strategy it is about to load will be
//   rejected by the risk gate on every order.
// =============================================================================
void validateStratRecord(const SymStrat& s, std::uint32_t symIdx, const StratValidationConfig& cfg,
                         const LiveRiskView& live, ValidationReport& out) {
    if (!isPackable(s)) {
        out.add(mk(Severity::Error, StratRule::NotPackable, symIdx,
                   "strat_select=" + std::to_string(s.stratSelect) +
                       " does not fit sym_strat_t's 4-bit field",
                   "rtl/pkg/trading_pkg.sv sym_strat_t"));
    }

    if (!s.stratEnabled) {
        return;  // the disabled, all-zero record is the correct default state
    }

    if (s.stratSelect >= cfg.primitivesInBitstream) {
        out.add(mk(Severity::Error, StratRule::UnknownPrimitive, symIdx,
                   "strat_select=" + std::to_string(s.stratSelect) + " but this bitstream has " +
                       std::to_string(cfg.primitivesInBitstream) + " hardened primitives",
                   "rtl/strategy/ — a selector with no primitive behind it is undefined "
                   "behaviour in fabric"));
    }
    if (s.quoteQty == 0) {
        out.add(mk(Severity::Error, StratRule::ZeroQuoteQty, symIdx,
                   "strategy is enabled with quote_qty = 0"));
    }
    if (s.fairValue == 0) {
        out.add(mk(Severity::Error, StratRule::ZeroFairValue, symIdx,
                   "strategy is enabled with fair_value = 0; the fair value was never computed, "
                   "and a zero fair value is not a cheap stock"));
    }
    if (s.edgeTicks == 0) {
        out.add(mk(Severity::Error, StratRule::ZeroEdgeTicks, symIdx,
                   "strategy is enabled with edge_ticks = 0; quoting at fair value with no "
                   "threshold means every tick triggers"));
    }
    if (s.minBookQty == 0) {
        out.add(mk(Severity::Warning, StratRule::ZeroMinBookQty, symIdx,
                   "min_book_qty = 0 defeats the thin-book guard (trading_pkg.sv sym_strat_t: "
                   "\"don't act on a thin book\")"));
    }

    // ---- cross-checks against the LIVE risk bank (read-only) -----------------
    if (!cfg.crossCheckAgainstRisk || live.table == nullptr || symIdx >= N_ACTIVE) {
        return;
    }
    const SymRisk& r = (*live.table)[symIdx];

    if (!r.enabled) {
        out.add(mk(Severity::Warning, StratRule::NoRiskRecord, symIdx,
                   "strategy enabled but the LIVE risk record (bank " +
                       std::string(toString(live.bank)) + ", gen " +
                       std::to_string(live.generation) +
                       ") has enabled = 0; every order will be rejected with "
                       "RISK_SYM_DISABLED",
                   "manual 08/09 §1 check #3; SEC Rule 15c3-5(c)(2)"));
    }
    if (r.collarHi > 0 && (s.fairValue < r.collarLo || s.fairValue > r.collarHi)) {
        out.add(mk(Severity::Warning, StratRule::FairValueOutsideCollar, symIdx,
                   "fair_value " + px(s.fairValue) + " is outside the live collar [" +
                       px(r.collarLo) + ", " + px(r.collarHi) + "]",
                   "manual 08/09 §1 check #8; SEC Rule 15c3-5(c)(1)(ii)"));
    }
    if (r.luldHi > 0 && (s.fairValue < r.luldLo || s.fairValue > r.luldHi)) {
        out.add(mk(Severity::Warning, StratRule::FairValueOutsideLuld, symIdx,
                   "fair_value " + px(s.fairValue) + " is outside the live LULD band [" +
                       px(r.luldLo) + ", " + px(r.luldHi) + "]",
                   "manual 08/09 §1 check #9; LULD Plan"));
    }
    if (r.maxOrderQty > 0 && s.quoteQty > r.maxOrderQty) {
        out.add(mk(Severity::Warning, StratRule::QuoteExceedsMaxOrderQty, symIdx,
                   "quote_qty " + std::to_string(s.quoteQty) + " exceeds the live max_order_qty " +
                       std::to_string(r.maxOrderQty) + "; every order will be rejected with "
                       "RISK_MAX_SHARES",
                   "manual 08/09 §1 check #13; SEC Rule 15c3-5(c)(1)(ii)"));
    }
    // The strategy quotes at fair +/- edge. If the live record demands the penny
    // grid, both terms must be on it or the derived quote is sub-penny and
    // check #7 rejects.
    if (r.tickPenny) {
        const bool fairOnGrid =
            priceInRecipExactRange(s.fairValue) && isWholePenny(s.fairValue);
        const bool edgeOnGrid =
            priceInRecipExactRange(s.edgeTicks) && isWholePenny(s.edgeTicks);
        if (!fairOnGrid || !edgeOnGrid) {
            out.add(mk(Severity::Warning, StratRule::QuoteNotOnTickGrid, symIdx,
                       "the live risk record sets tick_penny, but fair_value " + px(s.fairValue) +
                           (fairOnGrid ? " (on grid)" : " (OFF GRID)") + " and edge_ticks " +
                           px(s.edgeTicks) + (edgeOnGrid ? " (on grid)" : " (OFF GRID)") +
                           " mean fair +/- edge can land sub-penny",
                       "manual 08/09 §1 check #7; SEC Rule 612"));
        }
    }
}

ValidationReport validateStratTable(const StratTable& t, const StratValidationConfig& cfg,
                                    const LiveRiskView& live) {
    ValidationReport rep(ParamDomain::StrategyParams);
    for (std::uint32_t s = 0; s < N_ACTIVE; ++s) {
        validateStratRecord(t[s], s, cfg, live, rep);
    }
    return rep;
}

}  // namespace trading::paramd
