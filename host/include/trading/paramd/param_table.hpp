// =============================================================================
// paramd/param_table.hpp — whole-bank parameter tables, the fail-closed default,
//                          and the change diff
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : paramd (the parameter engine)
// Mirrors : rtl/pkg/trading_pkg.sv  sym_risk_t (324b) / sym_strat_t (149b)
//           via host/include/trading/types.hpp
//
// -----------------------------------------------------------------------------
// WHY A TABLE IS ALWAYS A *WHOLE* BANK
//   The commit flips which bank the fast path reads. Whatever is in the bank we
//   write becomes the entire parameter state — including the 200-odd symbols we
//   did not think about. manual 08/09 §6 has the fabric copy active->shadow
//   after a commit so the next edit starts from current values, but that copy is
//   RTL that does not exist yet, and a host that depends on it silently
//   resurrects whatever the shadow bank happened to contain.
//
//   So paramd only ever accepts a complete N_ACTIVE-entry table and only ever
//   writes all N_ACTIVE records. There is no partial-update API. A symbol the
//   caller never mentions is written as kFailClosedRisk / kFailClosedStrat.
//
// -----------------------------------------------------------------------------
// ⚠ THE DEFAULT IS ZERO, NEVER A PLACEHOLDER  (manual 08/09 §2)
//   "A limit that resets to a large value is worse than no limit at all, because
//    it creates the appearance of a control."
//   kFailClosedRisk is all-zero: disabled, not shortable, zero max order size,
//   zero notional, zero positions, zero open orders, a collar of [0,0] and a
//   LULD band of [0,0] — a record under which no order can pass any check. It is
//   asserted to pack to all-zero words, which is also sym_risk_t's RTL reset
//   value, so an unwritten fabric bank and an unset host record are the same
//   thing.
// =============================================================================
#ifndef TRADING_PARAMD_PARAM_TABLE_HPP
#define TRADING_PARAMD_PARAM_TABLE_HPP

#include <array>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "trading/paramd/param_window.hpp"
#include "trading/types.hpp"

namespace trading::paramd {

// =============================================================================
// 1. Tables
// =============================================================================
using RiskTable = std::array<SymRisk, N_ACTIVE>;
using StratTable = std::array<SymStrat, N_ACTIVE>;

// The fail-closed record. Default-constructed SymRisk/SymStrat are already
// all-zero (types.hpp initialises every member); these named constants exist so
// call sites read as an intent rather than as an omission.
inline constexpr SymRisk kFailClosedRisk{};
inline constexpr SymStrat kFailClosedStrat{};

// manual 08/09 §2: every limit resets to zero, every enable resets to disabled.
static_assert(!kFailClosedRisk.enabled, "the unset risk record must be DISABLED");
static_assert(!kFailClosedRisk.shortable, "the unset risk record must not permit shorting");
static_assert(kFailClosedRisk.maxOrderQty == 0, "RST_MAX_ORDER_QTY = 0");
static_assert(kFailClosedRisk.maxOrderNotional == 0, "RST_MAX_NOTIONAL = 0");
static_assert(kFailClosedRisk.maxLongPos == 0 && kFailClosedRisk.maxShortPos == 0);
static_assert(kFailClosedRisk.maxOpenOrders == 0);
static_assert(kFailClosedRisk.collarHi == 0 && kFailClosedRisk.luldHi == 0,
              "a zero price ceiling admits no order — that is the point");
static_assert(!kFailClosedStrat.stratEnabled, "the unset strategy record must be DISABLED");
static_assert(kFailClosedStrat.quoteQty == 0);

// The packed form of the fail-closed record must be all-zero, i.e. identical to
// sym_risk_t's RTL reset value. If a future field's "safe" value is a 1, this
// assertion fires and forces a deliberate decision instead of an accident.
namespace detail {
[[nodiscard]] consteval bool packsToAllZero(const SymRiskWords& w) {
    for (std::uint32_t x : w) {
        if (x != 0) return false;
    }
    return true;
}
[[nodiscard]] consteval bool packsToAllZero(const SymStratWords& w) {
    for (std::uint32_t x : w) {
        if (x != 0) return false;
    }
    return true;
}
}  // namespace detail
static_assert(detail::packsToAllZero(pack(kFailClosedRisk)),
              "the fail-closed risk record must pack to all-zero words — it has to be "
              "bit-identical to sym_risk_t's reset value (manual 08/09 §2)");
static_assert(detail::packsToAllZero(pack(kFailClosedStrat)),
              "the fail-closed strategy record must pack to all-zero words");

// A table with every symbol fail-closed. This, not an uninitialised buffer, is
// what paramd starts from.
[[nodiscard]] inline RiskTable failClosedRiskTable() noexcept {
    RiskTable t{};
    t.fill(kFailClosedRisk);
    return t;
}
[[nodiscard]] inline StratTable failClosedStratTable() noexcept {
    StratTable t{};
    t.fill(kFailClosedStrat);
    return t;
}

[[nodiscard]] inline bool isFailClosed(const SymRisk& r) noexcept { return r == kFailClosedRisk; }
[[nodiscard]] inline bool isFailClosed(const SymStrat& s) noexcept { return s == kFailClosedStrat; }

[[nodiscard]] std::size_t countEnabled(const RiskTable& t) noexcept;
[[nodiscard]] std::size_t countEnabled(const StratTable& t) noexcept;

// =============================================================================
// 2. Serialisation to bank words
// -----------------------------------------------------------------------------
// Record-major, ascending symbol then ascending word — the order the words are
// pushed through PARAM_*_DATA and the order crc32BankWords() consumes.
// =============================================================================
// `out` must be exactly kRiskWindow.bankWords() / kStratWindow.bankWords() long.
[[nodiscard]] bool serialiseBank(const RiskTable& t, std::span<std::uint32_t> out) noexcept;
[[nodiscard]] bool serialiseBank(const StratTable& t, std::span<std::uint32_t> out) noexcept;

[[nodiscard]] bool deserialiseBank(std::span<const std::uint32_t> words, RiskTable& out) noexcept;
[[nodiscard]] bool deserialiseBank(std::span<const std::uint32_t> words, StratTable& out) noexcept;

// =============================================================================
// 3. Symbol labels
// -----------------------------------------------------------------------------
// The active-set index is what the fabric uses; a human reading an audit record
// needs the ticker. Labels are presentation only — they are never written to the
// device and never affect a limit.
// =============================================================================
class SymbolLabels {
public:
    SymbolLabels() = default;

    void set(std::uint32_t symIdx, std::string_view ticker);
    [[nodiscard]] std::string_view get(std::uint32_t symIdx) const noexcept;
    // "AAPL[7]" or "#7" when unlabelled.
    [[nodiscard]] std::string describe(std::uint32_t symIdx) const;

private:
    std::array<std::array<char, 9>, N_ACTIVE> names_{};  // 8 chars + NUL, ITCH stock field
};

// =============================================================================
// 4. Diff
// -----------------------------------------------------------------------------
// manual 08/09 §9: "Direction matters. *Tightening* a limit is low-risk and may
// be expedited. *Loosening* always requires the full process. Encode the
// asymmetry in the tooling." ChangeDirection is that encoding.
// =============================================================================
enum class ChangeDirection : std::uint8_t {
    Unchanged = 0,
    Tighten = 1,  // the new value permits strictly less
    Loosen = 2,   // ⚠ the new value permits strictly more
    Neutral = 3,  // not a limit: market state the host mirrors into the record
};

[[nodiscard]] constexpr std::string_view toString(ChangeDirection d) noexcept {
    switch (d) {
        case ChangeDirection::Unchanged: return "UNCHANGED";
        case ChangeDirection::Tighten:   return "TIGHTEN";
        case ChangeDirection::Loosen:    return "LOOSEN";
        case ChangeDirection::Neutral:   return "NEUTRAL";
    }
    return "?";
}

enum class ValueKind : std::uint8_t {
    Flag,      // 0/1
    Shares,    // integer share count
    Price,     // ITCH-scaled, 4 implied decimals
    Notional,  // price * qty, so also 4 implied decimals
    Position,  // SIGNED share count
    Count,     // plain integer
    Ticks,     // ITCH-scaled price offset
    Select,    // strategy primitive selector
};

enum class RiskField : std::uint8_t {
    Enabled = 0,
    Shortable,
    MaxOrderQty,
    MaxOrderNotional,
    MaxLongPos,
    MaxShortPos,
    CollarLo,
    CollarHi,
    LuldLo,
    LuldHi,
    SsrActive,
    MaxOpenOrders,
    TickPenny,
    Count_
};
inline constexpr std::size_t kRiskFieldCount = static_cast<std::size_t>(RiskField::Count_);
static_assert(kRiskFieldCount == 13,
              "sym_risk_t has 13 members; the diff must cover every one of them");

enum class StratField : std::uint8_t {
    StratEnabled = 0,
    StratSelect,
    QuoteQty,
    EdgeTicks,
    MinBookQty,
    FairValue,
    ImbalanceThr,
    Count_
};
inline constexpr std::size_t kStratFieldCount = static_cast<std::size_t>(StratField::Count_);
static_assert(kStratFieldCount == 7,
              "sym_strat_t has 7 members; the diff must cover every one of them");

[[nodiscard]] std::string_view fieldName(RiskField f) noexcept;
[[nodiscard]] std::string_view fieldName(StratField f) noexcept;
[[nodiscard]] ValueKind fieldKind(RiskField f) noexcept;
[[nodiscard]] ValueKind fieldKind(StratField f) noexcept;
// The regulatory / manual citation for the check this field feeds.
// manuals/08-nasdaq/09-risk-controls-and-limits.md §1.
[[nodiscard]] std::string_view fieldBasis(RiskField f) noexcept;

struct FieldChange {
    std::uint8_t field = 0;  // RiskField or StratField, per the owning diff
    ChangeDirection dir = ChangeDirection::Unchanged;
    ValueKind kind = ValueKind::Count;
    std::uint64_t before = 0;  // raw; reinterpret as int64 when kind == Position
    std::uint64_t after = 0;
};

struct SymDiff {
    std::uint32_t symIdx = 0;
    std::vector<FieldChange> changes;
};

struct TableDiff {
    ParamDomain domain = ParamDomain::RiskLimits;
    std::vector<SymDiff> symbols;   // only symbols with >= 1 change
    std::size_t tighten = 0;
    std::size_t loosen = 0;
    std::size_t neutral = 0;
    std::size_t symbolsAdded = 0;    // fail-closed -> enabled
    std::size_t symbolsRemoved = 0;  // enabled -> fail-closed

    [[nodiscard]] bool empty() const noexcept { return symbols.empty(); }
    // manual 08/09 §9: any loosening escalates to the full approval process.
    [[nodiscard]] bool loosensAnything() const noexcept { return loosen > 0; }
};

[[nodiscard]] TableDiff diffTables(const RiskTable& before, const RiskTable& after);
[[nodiscard]] TableDiff diffTables(const StratTable& before, const StratTable& after);

// -----------------------------------------------------------------------------
// Rendering. Integer formatting only — a price is printed by splitting the
// scaled integer, never by dividing into a double. types.hpp's header comment
// says it plainly: there is not one floating-point value on this path.
// -----------------------------------------------------------------------------
// "$12.3400" from 123400.
[[nodiscard]] std::string formatScaledPrice(std::uint64_t scaled);
[[nodiscard]] std::string formatValue(ValueKind k, std::uint64_t raw);

struct DiffRenderOptions {
    bool showBasis = true;       // print the 15c3-5 / Rule 612 / LULD citation
    bool colourDirection = false;  // plain text by default; logs are not terminals
    std::size_t maxSymbols = 0;  // 0 = no limit
};

[[nodiscard]] std::string renderDiff(const TableDiff& d, const SymbolLabels& labels,
                                     const DiffRenderOptions& opt = {});

}  // namespace trading::paramd

#endif  // TRADING_PARAMD_PARAM_TABLE_HPP
