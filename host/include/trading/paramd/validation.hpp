// =============================================================================
// paramd/validation.hpp — reject an inconsistent parameter set BEFORE the device
//                         is touched
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : paramd (the parameter engine)
// Primary reference: manuals/08-nasdaq/09-risk-controls-and-limits.md
//                    §1 (the complete pre-trade check table + regulatory basis)
//                    §2 (fail-closed reset state)
//                    §9 (operational governance of limits)
//
// -----------------------------------------------------------------------------
// THE CONTRACT
//   Validation runs to completion over the WHOLE table and returns every issue
//   it found, before a single register is written. "Fail before touching the
//   device, never halfway through" is not a nicety: a half-written bank that is
//   then abandoned leaves a shadow bank full of plausible-looking garbage, and
//   the next commit — possibly by a different operator, possibly under time
//   pressure — flips it live.
//
//   This is the one part of paramd that allocates (std::string detail, a vector
//   of issues). It runs strictly before the commit cycle, which allocates
//   nothing. That split is deliberate and load-bearing.
//
// -----------------------------------------------------------------------------
// WHAT "INVALID" MEANS HERE
//   Error   — the record is internally contradictory, or unrepresentable in the
//             fabric's field widths, or would make an enabled symbol untradeable
//             in a way that hides a configuration mistake. The commit is refused.
//   Warning — the record is coherent but the operator should look. A limit that
//             can never bind is the case manual 08/09 §9 calls out: "A limit
//             never approached in six months is probably too loose to be a
//             control." Warnings never block; they always appear in the audit
//             record and in the dry-run diff.
// =============================================================================
#ifndef TRADING_PARAMD_VALIDATION_HPP
#define TRADING_PARAMD_VALIDATION_HPP

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "trading/paramd/param_table.hpp"
#include "trading/types.hpp"

namespace trading::paramd {

enum class Severity : std::uint8_t { Warning = 0, Error = 1 };

[[nodiscard]] constexpr std::string_view toString(Severity s) noexcept {
    return s == Severity::Error ? "ERROR" : "WARNING";
}

// -----------------------------------------------------------------------------
// Stable rule identifiers. These land in audit records and in alerts, so they
// are numbers that must not be reused, not positions in a list.
//
// The `check #N` in each comment is the row in manual 08/09 §1 that the field
// feeds, and the regulation named there is the reason the check exists.
// -----------------------------------------------------------------------------
enum class RiskRule : std::uint16_t {
    // --- representability ---------------------------------------------------
    NotPackable = 100,          // a value does not fit its sym_risk_t field width
    PositionOutOfRange = 101,   // outside position_t's signed 40-bit range
    NegativePosition = 102,     // max_long_pos / max_short_pos are magnitudes: >= 0
                                //   check #15/#16, 15c3-5(c)(1)(i)

    // --- internally contradictory bands -------------------------------------
    CollarInverted = 110,       // collar_lo > collar_hi.  check #8, 15c3-5(c)(1)(ii)
    LuldInverted = 111,         // luld_lo > luld_hi.      check #9, LULD Plan
    CollarZeroCeiling = 112,    // enabled with collar_hi == 0: no order can price
    LuldZeroCeiling = 113,      // enabled with luld_hi == 0: band unknown -> fail closed

    // --- an enabled symbol with a zero limit ---------------------------------
    ZeroMaxOrderQty = 120,      // check #13, 15c3-5(c)(1)(ii)
    ZeroMaxOrderNotional = 121, // check #14, 15c3-5(c)(1)(i)
    ZeroMaxOpenOrders = 122,    // check #19, 15c3-5
    ZeroBothPositionLimits = 123,  // check #15/#16: cannot hold any position at all

    // --- SEC Rule 612 (tick size) -------------------------------------------
    PriceNotWholePenny = 130,   // check #7, SEC Rule 612
    PriceOutsideRecipRange = 131,  // px >= 2^31: trading_pkg::div100's reciprocal
                                   // multiply is only exact below that, so the
                                   // fabric's is_whole_penny would disagree

    // --- Reg SHO -------------------------------------------------------------
    SsrWithoutShortable = 140,  // check #10/#11: SSR set on a name we cannot short.
                                // Coherent, but usually means the wrong record.

    // --- limits that can never bind ------------------------------------------
    NotionalUnreachable = 150,  // max_order_notional > max_order_qty * collar_hi
    NotionalTooTight = 151,     // one share at collar_lo already exceeds the notional cap
    OrderExceedsBothPositions = 152,
    CollarWiderThanLuld = 153,  // the firm control is looser than the regulatory band

    // --- fail-closed posture --------------------------------------------------
    EnabledWithoutBand = 160,   // enabled but the whole band is [0,0]
};

enum class StratRule : std::uint16_t {
    NotPackable = 200,          // strat_select > 15
    UnknownPrimitive = 201,     // strat_select names a primitive this build has no RTL for
    ZeroQuoteQty = 210,         // enabled with nothing to quote
    ZeroFairValue = 211,        // enabled with no fair value: it was never computed
    ZeroEdgeTicks = 212,        // enabled with no edge: quote at fair == adverse selection
    ZeroMinBookQty = 220,       // warning: "don't act on a thin book" is defeated
    // --- cross-checks against the LIVE risk table (advisory, read-only) -------
    // These read the risk bank. They NEVER write it. host/README.md §3.3.
    NoRiskRecord = 230,         // strategy enabled where the risk record is disabled
    FairValueOutsideCollar = 231,
    FairValueOutsideLuld = 232,
    QuoteExceedsMaxOrderQty = 233,
    QuoteNotOnTickGrid = 234,   // fair +/- edge would be sub-penny under check #7
};

[[nodiscard]] std::string_view toString(RiskRule r) noexcept;
[[nodiscard]] std::string_view toString(StratRule r) noexcept;
// The manual 08/09 §1 row and the regulation behind it, per rule.
[[nodiscard]] std::string_view basisOf(RiskRule r) noexcept;

struct ValidationIssue {
    Severity severity = Severity::Error;
    std::uint16_t rule = 0;              // RiskRule or StratRule, per the report's domain
    std::string_view ruleName;
    std::string_view basis;              // "manual 08/09 §1 check #13, 15c3-5(c)(1)(ii)"
    std::uint32_t symIdx = 0xFFFF'FFFFu; // ~0 for a table-level issue
    std::string detail;                  // the actual numbers, integer-formatted
};

class ValidationReport {
public:
    explicit ValidationReport(ParamDomain d) noexcept : domain_(d) {}

    void add(ValidationIssue issue);

    [[nodiscard]] ParamDomain domain() const noexcept { return domain_; }
    [[nodiscard]] const std::vector<ValidationIssue>& issues() const noexcept { return issues_; }
    [[nodiscard]] std::size_t errors() const noexcept { return errors_; }
    [[nodiscard]] std::size_t warnings() const noexcept { return warnings_; }
    [[nodiscard]] bool ok() const noexcept { return errors_ == 0; }

    [[nodiscard]] std::string render(const SymbolLabels& labels) const;

private:
    ParamDomain domain_;
    std::vector<ValidationIssue> issues_;
    std::size_t errors_ = 0;
    std::size_t warnings_ = 0;
};

// -----------------------------------------------------------------------------
// Context
// -----------------------------------------------------------------------------
struct RiskValidationConfig {
    // How many hardened strategy primitives this bitstream actually contains.
    // Only used by strategy validation, but kept here so both share one place.
    bool requireBandInsideLuld = true;  // emit CollarWiderThanLuld as a warning
    // Enabled symbols must carry a usable LULD band. manual 08/09 §1 check #9 and
    // §0 principle 1 (fail closed): an unknown band is not a permissive band.
    bool requireLuldBandWhenEnabled = true;
};

struct StratValidationConfig {
    std::uint8_t primitivesInBitstream = 16;  // strat_select is 4 bits
    bool crossCheckAgainstRisk = true;
};

// Cross-check input for strategy validation. This is a READ-ONLY view of the
// live risk bank. Supplying it lets paramd warn that a strategy is enabled on a
// symbol whose risk record would reject every order. It does not, and must not,
// let a strategy commit modify a risk limit.
struct LiveRiskView {
    const RiskTable* table = nullptr;
    std::uint32_t generation = 0;
    ParamBank bank = ParamBank::A;
};

[[nodiscard]] ValidationReport validateRiskTable(const RiskTable& t,
                                                 const RiskValidationConfig& cfg = {});

[[nodiscard]] ValidationReport validateStratTable(const StratTable& t,
                                                  const StratValidationConfig& cfg = {},
                                                  const LiveRiskView& live = {});

// -----------------------------------------------------------------------------
// Single-record helpers, exposed because the computation layer wants to check
// what it just produced before it is ever put in a table.
// -----------------------------------------------------------------------------
void validateRiskRecord(const SymRisk& r, std::uint32_t symIdx, const RiskValidationConfig& cfg,
                        ValidationReport& out);
void validateStratRecord(const SymStrat& s, std::uint32_t symIdx, const StratValidationConfig& cfg,
                         const LiveRiskView& live, ValidationReport& out);

// -----------------------------------------------------------------------------
// Rule 612 helpers — these MIRROR trading_pkg.sv exactly.
//
// The RTL has no divider (CLAUDE.md §5, trading_pkg.sv §6), so "divisible by
// 100" is a reciprocal multiply: q = (px * 1_374_389_535) >> 37, exact for
// px < 2^31. types.hpp::isWholePenny() is that same multiply. The host must not
// "simplify" it to px % 100 == 0 — the two agree today and would diverge the day
// RECIP_100 changes, and the direction of that divergence is an order the fabric
// rejects for a reason the host cannot explain.
//
// manual 08/09 §1 note on check #7 describes tick_class as a 2-3 bit enum
// {$0.0001, $0.005, $0.01}. sym_risk_t currently carries a single `tick_penny`
// bit, i.e. only the {$0.0001, $0.01} pair. TICK_HALF_PENNY has no field in the
// packed record; see the report accompanying this component.
// -----------------------------------------------------------------------------
inline constexpr price_t TICK_PENNY_SCALED = 100;      // $0.01 with 4 implied decimals
inline constexpr price_t TICK_SUBDOLLAR_SCALED = 1;    // $0.0001
inline constexpr price_t DOLLAR_SCALED = PRICE_SCALE;  // $1.0000 = 10000

// Above this, trading_pkg::div100's reciprocal multiply is no longer proven
// exact (trading_pkg.sv §6: "Exact for px < 2^31").
inline constexpr price_t PRICE_RECIP_EXACT_MAX = 0x7FFF'FFFFu;

[[nodiscard]] constexpr bool priceInRecipExactRange(price_t px) noexcept {
    return px <= PRICE_RECIP_EXACT_MAX;
}

// SEC Rule 612: an NMS stock priced at or above $1.00 quotes in whole pennies.
// This is the rule paramd uses to DERIVE tick_penny; validation then checks the
// record's own prices against whatever tick_penny actually says.
[[nodiscard]] constexpr bool rule612RequiresPenny(price_t referencePx) noexcept {
    return referencePx >= DOLLAR_SCALED;
}

}  // namespace trading::paramd

#endif  // TRADING_PARAMD_VALIDATION_HPP
