// =============================================================================
// paramd/param_table.cpp — bank serialisation, diffing, and integer rendering
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : paramd (the parameter engine)
// Mirrors : rtl/pkg/trading_pkg.sv sym_risk_t / sym_strat_t via types.hpp
// =============================================================================
#include "trading/paramd/param_table.hpp"

#include <algorithm>
#include <cstring>

namespace trading::paramd {

// =============================================================================
// Counting
// =============================================================================
std::size_t countEnabled(const RiskTable& t) noexcept {
    std::size_t n = 0;
    for (const auto& r : t) {
        if (r.enabled) ++n;
    }
    return n;
}

std::size_t countEnabled(const StratTable& t) noexcept {
    std::size_t n = 0;
    for (const auto& s : t) {
        if (s.stratEnabled) ++n;
    }
    return n;
}

// =============================================================================
// Bank serialisation — record-major, ascending symbol then ascending word.
// This is the order the words go through PARAM_*_DATA and the order
// crc32BankWords() consumes them; the three must never disagree.
// =============================================================================
bool serialiseBank(const RiskTable& t, std::span<std::uint32_t> out) noexcept {
    if (out.size() != kRiskWindow.bankWords()) return false;
    std::size_t k = 0;
    for (std::size_t sym = 0; sym < N_ACTIVE; ++sym) {
        const SymRiskWords w = pack(t[sym]);
        for (std::size_t i = 0; i < SYM_RISK_WORDS; ++i) out[k++] = w[i];
    }
    return k == out.size();
}

bool serialiseBank(const StratTable& t, std::span<std::uint32_t> out) noexcept {
    if (out.size() != kStratWindow.bankWords()) return false;
    std::size_t k = 0;
    for (std::size_t sym = 0; sym < N_ACTIVE; ++sym) {
        const SymStratWords w = pack(t[sym]);
        for (std::size_t i = 0; i < SYM_STRAT_WORDS; ++i) out[k++] = w[i];
    }
    return k == out.size();
}

bool deserialiseBank(std::span<const std::uint32_t> words, RiskTable& out) noexcept {
    if (words.size() != kRiskWindow.bankWords()) return false;
    for (std::size_t sym = 0; sym < N_ACTIVE; ++sym) {
        SymRiskWords w{};
        for (std::size_t i = 0; i < SYM_RISK_WORDS; ++i) w[i] = words[sym * SYM_RISK_WORDS + i];
        out[sym] = unpackSymRisk(w);
    }
    return true;
}

bool deserialiseBank(std::span<const std::uint32_t> words, StratTable& out) noexcept {
    if (words.size() != kStratWindow.bankWords()) return false;
    for (std::size_t sym = 0; sym < N_ACTIVE; ++sym) {
        SymStratWords w{};
        for (std::size_t i = 0; i < SYM_STRAT_WORDS; ++i) w[i] = words[sym * SYM_STRAT_WORDS + i];
        out[sym] = unpackSymStrat(w);
    }
    return true;
}

// =============================================================================
// Symbol labels
// =============================================================================
void SymbolLabels::set(std::uint32_t symIdx, std::string_view ticker) {
    if (symIdx >= N_ACTIVE) return;
    auto& slot = names_[symIdx];
    slot.fill('\0');
    const std::size_t n = std::min<std::size_t>(ticker.size(), slot.size() - 1);
    for (std::size_t i = 0; i < n; ++i) slot[i] = ticker[i];
}

std::string_view SymbolLabels::get(std::uint32_t symIdx) const noexcept {
    if (symIdx >= N_ACTIVE) return {};
    const auto& slot = names_[symIdx];
    return std::string_view(slot.data(), std::strlen(slot.data()));
}

std::string SymbolLabels::describe(std::uint32_t symIdx) const {
    std::string out;
    const std::string_view t = get(symIdx);
    if (!t.empty()) {
        out.append(t);
        out.push_back('[');
        out.append(std::to_string(symIdx));
        out.push_back(']');
    } else {
        out.push_back('#');
        out.append(std::to_string(symIdx));
    }
    return out;
}

// =============================================================================
// Field metadata
// -----------------------------------------------------------------------------
// `basis` is the row in manuals/08-nasdaq/09-risk-controls-and-limits.md §1 that
// this field feeds, and the regulation named in that row's "Regulatory basis"
// column. It goes into the audit record, so a compliance reviewer reading a
// limit change sees why the limit exists without leaving the record.
// =============================================================================
std::string_view fieldName(RiskField f) noexcept {
    switch (f) {
        case RiskField::Enabled:          return "enabled";
        case RiskField::Shortable:        return "shortable";
        case RiskField::MaxOrderQty:      return "max_order_qty";
        case RiskField::MaxOrderNotional: return "max_order_notional";
        case RiskField::MaxLongPos:       return "max_long_pos";
        case RiskField::MaxShortPos:      return "max_short_pos";
        case RiskField::CollarLo:         return "collar_lo";
        case RiskField::CollarHi:         return "collar_hi";
        case RiskField::LuldLo:           return "luld_lo";
        case RiskField::LuldHi:           return "luld_hi";
        case RiskField::SsrActive:        return "ssr_active";
        case RiskField::MaxOpenOrders:    return "max_open_orders";
        case RiskField::TickPenny:        return "tick_penny";
        case RiskField::Count_:           break;
    }
    return "?";
}

std::string_view fieldBasis(RiskField f) noexcept {
    switch (f) {
        case RiskField::Enabled:
            return "manual 08/09 §1 check #3 per-symbol enabled; SEC Rule 15c3-5(c)(2)";
        case RiskField::Shortable:
            return "manual 08/09 §1 check #11 short-sale permission; Reg SHO Rule 203(b)";
        case RiskField::MaxOrderQty:
            return "manual 08/09 §1 check #13 max order shares; SEC Rule 15c3-5(c)(1)(ii)";
        case RiskField::MaxOrderNotional:
            return "manual 08/09 §1 check #14 max order notional; SEC Rule 15c3-5(c)(1)(i)";
        case RiskField::MaxLongPos:
            return "manual 08/09 §1 check #15 max position long; SEC Rule 15c3-5(c)(1)(i)";
        case RiskField::MaxShortPos:
            return "manual 08/09 §1 check #16 max position short; SEC Rule 15c3-5(c)(1)(i)";
        case RiskField::CollarLo:
        case RiskField::CollarHi:
            return "manual 08/09 §1 check #8 price collar vs reference; "
                   "SEC Rule 15c3-5(c)(1)(ii)";
        case RiskField::LuldLo:
        case RiskField::LuldHi:
            return "manual 08/09 §1 check #9 LULD band; LULD Plan (market data, not a "
                   "firm limit)";
        case RiskField::SsrActive:
            return "manual 08/09 §1 check #10 short-sale price test; Reg SHO Rule 201 "
                   "(market state, not a firm limit)";
        case RiskField::MaxOpenOrders:
            return "manual 08/09 §1 check #19 max open orders per symbol; SEC Rule 15c3-5";
        case RiskField::TickPenny:
            return "manual 08/09 §1 check #7 tick validity; SEC Rule 612";
        case RiskField::Count_:
            break;
    }
    return "";
}

ValueKind fieldKind(RiskField f) noexcept {
    switch (f) {
        case RiskField::Enabled:
        case RiskField::Shortable:
        case RiskField::SsrActive:
        case RiskField::TickPenny:        return ValueKind::Flag;
        case RiskField::MaxOrderQty:      return ValueKind::Shares;
        case RiskField::MaxOrderNotional: return ValueKind::Notional;
        case RiskField::MaxLongPos:
        case RiskField::MaxShortPos:      return ValueKind::Position;
        case RiskField::CollarLo:
        case RiskField::CollarHi:
        case RiskField::LuldLo:
        case RiskField::LuldHi:           return ValueKind::Price;
        case RiskField::MaxOpenOrders:    return ValueKind::Count;
        case RiskField::Count_:           break;
    }
    return ValueKind::Count;
}

std::string_view fieldName(StratField f) noexcept {
    switch (f) {
        case StratField::StratEnabled: return "strat_enabled";
        case StratField::StratSelect:  return "strat_select";
        case StratField::QuoteQty:     return "quote_qty";
        case StratField::EdgeTicks:    return "edge_ticks";
        case StratField::MinBookQty:   return "min_book_qty";
        case StratField::FairValue:    return "fair_value";
        case StratField::ImbalanceThr: return "imbalance_thr";
        case StratField::Count_:       break;
    }
    return "?";
}

ValueKind fieldKind(StratField f) noexcept {
    switch (f) {
        case StratField::StratEnabled: return ValueKind::Flag;
        case StratField::StratSelect:  return ValueKind::Select;
        case StratField::QuoteQty:
        case StratField::MinBookQty:   return ValueKind::Shares;
        case StratField::EdgeTicks:    return ValueKind::Ticks;
        case StratField::FairValue:    return ValueKind::Price;
        case StratField::ImbalanceThr: return ValueKind::Count;
        case StratField::Count_:       break;
    }
    return ValueKind::Count;
}

// =============================================================================
// Direction classification
// -----------------------------------------------------------------------------
// manual 08/09 §9: "Direction matters. Tightening a limit is low-risk and may be
// expedited. Loosening always requires the full process."
//
// LULD bands and the SSR flag are classified NEUTRAL: they are market state the
// host mirrors into the record from the feed, not limits a risk owner sets.
// Calling a widening LULD band a "loosening" would make every ordinary band
// update require four-eyes approval, and a control that fires on everything is a
// control people learn to click through.
// =============================================================================
namespace {

ChangeDirection dirForCeiling(std::uint64_t before, std::uint64_t after) noexcept {
    if (after == before) return ChangeDirection::Unchanged;
    return after < before ? ChangeDirection::Tighten : ChangeDirection::Loosen;
}

ChangeDirection dirForFloor(std::uint64_t before, std::uint64_t after) noexcept {
    if (after == before) return ChangeDirection::Unchanged;
    return after > before ? ChangeDirection::Tighten : ChangeDirection::Loosen;
}

ChangeDirection dirForPermissionFlag(bool before, bool after) noexcept {
    if (before == after) return ChangeDirection::Unchanged;
    // Turning a permission ON permits more.
    return after ? ChangeDirection::Loosen : ChangeDirection::Tighten;
}

ChangeDirection dirForRestrictionFlag(bool before, bool after) noexcept {
    if (before == after) return ChangeDirection::Unchanged;
    // Turning a restriction ON permits less.
    return after ? ChangeDirection::Tighten : ChangeDirection::Loosen;
}

void pushChange(std::vector<FieldChange>& v, RiskField f, ChangeDirection d, std::uint64_t before,
                std::uint64_t after) {
    if (d == ChangeDirection::Unchanged) return;
    FieldChange c{};
    c.field = static_cast<std::uint8_t>(f);
    c.dir = d;
    c.kind = fieldKind(f);
    c.before = before;
    c.after = after;
    v.push_back(c);
}

void pushChange(std::vector<FieldChange>& v, StratField f, std::uint64_t before,
                std::uint64_t after) {
    if (before == after) return;
    FieldChange c{};
    c.field = static_cast<std::uint8_t>(f);
    c.dir = ChangeDirection::Neutral;  // strategy parameters are not controls
    c.kind = fieldKind(f);
    c.before = before;
    c.after = after;
    v.push_back(c);
}

std::uint64_t raw(position_t p) noexcept { return static_cast<std::uint64_t>(p); }

}  // namespace

TableDiff diffTables(const RiskTable& before, const RiskTable& after) {
    TableDiff d{};
    d.domain = ParamDomain::RiskLimits;
    for (std::uint32_t s = 0; s < N_ACTIVE; ++s) {
        const SymRisk& b = before[s];
        const SymRisk& a = after[s];
        if (b == a) continue;

        SymDiff sd{};
        sd.symIdx = s;

        pushChange(sd.changes, RiskField::Enabled, dirForPermissionFlag(b.enabled, a.enabled),
                   b.enabled, a.enabled);
        pushChange(sd.changes, RiskField::Shortable, dirForPermissionFlag(b.shortable, a.shortable),
                   b.shortable, a.shortable);
        pushChange(sd.changes, RiskField::MaxOrderQty,
                   dirForCeiling(b.maxOrderQty, a.maxOrderQty), b.maxOrderQty, a.maxOrderQty);
        pushChange(sd.changes, RiskField::MaxOrderNotional,
                   dirForCeiling(b.maxOrderNotional, a.maxOrderNotional), b.maxOrderNotional,
                   a.maxOrderNotional);
        pushChange(sd.changes, RiskField::MaxLongPos,
                   dirForCeiling(raw(b.maxLongPos), raw(a.maxLongPos)), raw(b.maxLongPos),
                   raw(a.maxLongPos));
        pushChange(sd.changes, RiskField::MaxShortPos,
                   dirForCeiling(raw(b.maxShortPos), raw(a.maxShortPos)), raw(b.maxShortPos),
                   raw(a.maxShortPos));
        // A collar floor tightens by RISING; a collar ceiling tightens by FALLING.
        pushChange(sd.changes, RiskField::CollarLo, dirForFloor(b.collarLo, a.collarLo), b.collarLo,
                   a.collarLo);
        pushChange(sd.changes, RiskField::CollarHi, dirForCeiling(b.collarHi, a.collarHi),
                   b.collarHi, a.collarHi);
        // LULD is feed-sourced market state, not a firm limit.
        if (b.luldLo != a.luldLo) {
            pushChange(sd.changes, RiskField::LuldLo, ChangeDirection::Neutral, b.luldLo, a.luldLo);
        }
        if (b.luldHi != a.luldHi) {
            pushChange(sd.changes, RiskField::LuldHi, ChangeDirection::Neutral, b.luldHi, a.luldHi);
        }
        if (b.ssrActive != a.ssrActive) {
            pushChange(sd.changes, RiskField::SsrActive, ChangeDirection::Neutral, b.ssrActive,
                       a.ssrActive);
        }
        pushChange(sd.changes, RiskField::MaxOpenOrders,
                   dirForCeiling(b.maxOpenOrders, a.maxOpenOrders), b.maxOpenOrders,
                   a.maxOpenOrders);
        // tick_penny ON is the RESTRICTIVE setting (Rule 612 whole-cent grid).
        pushChange(sd.changes, RiskField::TickPenny,
                   dirForRestrictionFlag(b.tickPenny, a.tickPenny), b.tickPenny, a.tickPenny);

        for (const auto& c : sd.changes) {
            switch (c.dir) {
                case ChangeDirection::Tighten: ++d.tighten; break;
                case ChangeDirection::Loosen:  ++d.loosen;  break;
                case ChangeDirection::Neutral: ++d.neutral; break;
                case ChangeDirection::Unchanged: break;
            }
        }
        if (!b.enabled && a.enabled) ++d.symbolsAdded;
        if (b.enabled && !a.enabled) ++d.symbolsRemoved;

        if (!sd.changes.empty()) d.symbols.push_back(std::move(sd));
    }
    return d;
}

TableDiff diffTables(const StratTable& before, const StratTable& after) {
    TableDiff d{};
    d.domain = ParamDomain::StrategyParams;
    for (std::uint32_t s = 0; s < N_ACTIVE; ++s) {
        const SymStrat& b = before[s];
        const SymStrat& a = after[s];
        if (b == a) continue;

        SymDiff sd{};
        sd.symIdx = s;
        pushChange(sd.changes, StratField::StratEnabled, b.stratEnabled, a.stratEnabled);
        pushChange(sd.changes, StratField::StratSelect, b.stratSelect, a.stratSelect);
        pushChange(sd.changes, StratField::QuoteQty, b.quoteQty, a.quoteQty);
        pushChange(sd.changes, StratField::EdgeTicks, b.edgeTicks, a.edgeTicks);
        pushChange(sd.changes, StratField::MinBookQty, b.minBookQty, a.minBookQty);
        pushChange(sd.changes, StratField::FairValue, b.fairValue, a.fairValue);
        pushChange(sd.changes, StratField::ImbalanceThr, b.imbalanceThr, a.imbalanceThr);

        d.neutral += sd.changes.size();
        if (!b.stratEnabled && a.stratEnabled) ++d.symbolsAdded;
        if (b.stratEnabled && !a.stratEnabled) ++d.symbolsRemoved;

        if (!sd.changes.empty()) d.symbols.push_back(std::move(sd));
    }
    return d;
}

// =============================================================================
// Rendering — integer only
// -----------------------------------------------------------------------------
// A price is printed by splitting the scaled integer into whole units and a
// zero-padded 4-digit remainder. There is no division into a double anywhere on
// this path, in keeping with types.hpp's header rule.
// =============================================================================
std::string formatScaledPrice(std::uint64_t scaled) {
    const std::uint64_t whole = scaled / PRICE_SCALE;
    const std::uint64_t frac = scaled % PRICE_SCALE;
    std::string out = "$";
    out += std::to_string(whole);
    out.push_back('.');
    // 4 implied decimals, zero-padded.
    std::string f = std::to_string(frac);
    out.append(4 - f.size(), '0');
    out += f;
    return out;
}

std::string formatValue(ValueKind k, std::uint64_t rawValue) {
    switch (k) {
        case ValueKind::Flag:
            return rawValue ? "true" : "false";
        case ValueKind::Price:
        case ValueKind::Ticks:
        case ValueKind::Notional:
            return formatScaledPrice(rawValue);
        case ValueKind::Position: {
            const std::int64_t v = static_cast<std::int64_t>(rawValue);
            return std::to_string(v);
        }
        case ValueKind::Shares:
        case ValueKind::Count:
        case ValueKind::Select:
            return std::to_string(rawValue);
    }
    return std::to_string(rawValue);
}

namespace {

std::string_view directionMark(ChangeDirection d) noexcept {
    switch (d) {
        case ChangeDirection::Tighten:   return "  [TIGHTEN]";
        case ChangeDirection::Loosen:    return "  [LOOSEN] <== requires approval";
        case ChangeDirection::Neutral:   return "  [market state]";
        case ChangeDirection::Unchanged: return "";
    }
    return "";
}

}  // namespace

std::string renderDiff(const TableDiff& d, const SymbolLabels& labels,
                       const DiffRenderOptions& opt) {
    const bool isRisk = d.domain == ParamDomain::RiskLimits;

    std::string out;
    out += "=== parameter diff: ";
    out += toString(d.domain);
    out += " ===\n";

    if (d.empty()) {
        out += "  (no change: the desired table is identical to the baseline)\n";
        return out;
    }

    out += "  symbols changed : " + std::to_string(d.symbols.size()) + "\n";
    out += "  symbols enabled : +" + std::to_string(d.symbolsAdded) + " / -" +
           std::to_string(d.symbolsRemoved) + "\n";
    if (isRisk) {
        out += "  tighten / loosen / market-state : " + std::to_string(d.tighten) + " / " +
               std::to_string(d.loosen) + " / " + std::to_string(d.neutral) + "\n";
        if (d.loosensAnything()) {
            out +=
                "  !! THIS CHANGE LOOSENS AT LEAST ONE LIMIT. manual 08/09 §9: loosening\n"
                "     always requires the full approval process; tightening may be expedited.\n";
        }
    } else {
        out += "  fields changed : " + std::to_string(d.neutral) + "\n";
    }
    out += "\n";

    std::size_t shown = 0;
    for (const auto& sd : d.symbols) {
        if (opt.maxSymbols != 0 && shown >= opt.maxSymbols) {
            out += "  ... " + std::to_string(d.symbols.size() - shown) + " more symbol(s)\n";
            break;
        }
        ++shown;
        out += "  " + labels.describe(sd.symIdx) + "\n";
        for (const auto& c : sd.changes) {
            const std::string_view name =
                isRisk ? fieldName(static_cast<RiskField>(c.field))
                       : fieldName(static_cast<StratField>(c.field));
            out += "      ";
            out.append(name);
            out.append(name.size() < 24 ? 24 - name.size() : std::size_t{1}, ' ');
            out += formatValue(c.kind, c.before);
            out += "  ->  ";
            out += formatValue(c.kind, c.after);
            out.append(directionMark(c.dir));
            out.push_back('\n');
            if (opt.showBasis && isRisk) {
                const std::string_view basis = fieldBasis(static_cast<RiskField>(c.field));
                if (!basis.empty()) {
                    out += "          basis: ";
                    out.append(basis);
                    out.push_back('\n');
                }
            }
        }
    }
    return out;
}

}  // namespace trading::paramd
