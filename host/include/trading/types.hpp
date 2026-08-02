// =============================================================================
// types.hpp — C++ mirrors of rtl/pkg/trading_pkg.sv
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Mirrors : rtl/pkg/trading_pkg.sv        (THE interface contract)
//           rtl/telemetry/telemetry_pkg.sv (word-stride constants only)
// Owner   : device layer (agent 1). Included by every other host component.
//
// -----------------------------------------------------------------------------
// THE RULE THIS FILE EXISTS TO ENFORCE
//   A silent disagreement between fabric and host on a packed layout does not
//   produce a crash. It produces a risk limit that is off by a factor of 2^16
//   and an order that should never have left the building. Every mirrored type
//   below carries (a) the name of the RTL construct it mirrors, (b) an explicit
//   bit-field table, and (c) a static_assert that the table tiles the declared
//   width exactly. If trading_pkg.sv changes, this file fails to compile.
//
// -----------------------------------------------------------------------------
// FIXED POINT — CLAUDE.md §5.3, trading_pkg.sv §2
//   Prices are ITCH-native scaled integers with 4 implied decimals.
//   $12.3400 -> 123400. PRICE_SCALE = 10000.
//   There is not one floating-point type in this header and there must never
//   be. Analysis tooling in host/tools/ and host/pymodel/ may use doubles; it
//   must say so in a comment at the point of use.
//
// -----------------------------------------------------------------------------
// PACKED-STRUCT BIT ORDER — read this before touching pack()/unpack()
//   SystemVerilog packed structs place the FIRST declared member in the HIGH
//   bits and the LAST declared member in bit 0. This header follows the RTL
//   exactly: for sym_risk_t, `enabled` (first member) is bit 323 and
//   `tick_penny` (last member) is bit 0.
//
//   The 324-bit value is then serialised LSB-first into little-endian uint32
//   words: word 0 holds bits [31:0], word 1 holds bits [63:32], and so on.
//   That is the order in which the words are written through
//   PARAM_RISK_DATA at ascending PARAM_RISK_ADDR.word_idx, and it is the order
//   the fabric reassembles them in.
//
//   SHARED_CONTRACT.md §"Packed parameter record encodings" describes the field
//   list top-down and contains a self-contradictory sentence about which end is
//   the LSB. The RTL is unambiguous, so the RTL wins. The bit tables below are
//   the normative statement of the layout for all host code.
// =============================================================================
#ifndef TRADING_TYPES_HPP
#define TRADING_TYPES_HPP

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>
#include <type_traits>

namespace trading {

// =============================================================================
// 1. System configuration  (mirrors trading_pkg.sv §1)
// =============================================================================

// Core datapath clock. 10GbE / 64-bit = 156.25 MHz, one domain for the fast
// path. Expressed as an exact rational so no float appears in host code that
// converts cycles to nanoseconds.
inline constexpr std::uint64_t CORE_CLK_HZ = 156'250'000ULL;
inline constexpr std::uint64_t CORE_CLK_PS = 6400ULL;  // picoseconds per cycle

// mirrors trading_pkg::AXIS_W / AXIS_KEEP_W
inline constexpr std::uint32_t AXIS_W = 64;
inline constexpr std::uint32_t AXIS_KEEP_W = AXIS_W / 8;

// mirrors trading_pkg::ITCH_MSG_MAX_BYTES / ITCH_MSG_W / ITCH_LEN_W
inline constexpr std::uint32_t ITCH_MSG_MAX_BYTES = 64;
inline constexpr std::uint32_t ITCH_MSG_W = ITCH_MSG_MAX_BYTES * 8;  // 512
inline constexpr std::uint32_t ITCH_LEN_W = 8;

// Tradeable universe. Nasdaq stock-locate codes are dense integers, so the
// symbol lookup is a direct index. mirrors trading_pkg::N_SYMBOLS etc.
inline constexpr std::uint32_t N_SYMBOLS = 8192;  // raw ITCH locate space
inline constexpr std::uint32_t SYM_IDX_W = 13;    // $clog2(N_SYMBOLS)
inline constexpr std::uint32_t N_ACTIVE = 256;    // filtered / active set
inline constexpr std::uint32_t ACT_IDX_W = 8;     // $clog2(N_ACTIVE)

// mirrors trading_pkg::BOOK_LEVELS / LEVEL_IDX_W
inline constexpr std::uint32_t BOOK_LEVELS = 16;
inline constexpr std::uint32_t LEVEL_IDX_W = 4;

// mirrors trading_pkg::ORDER_MAP_ENTRIES / ORDER_MAP_WAYS
inline constexpr std::uint32_t ORDER_MAP_ENTRIES = 1u << 16;
inline constexpr std::uint32_t ORDER_MAP_WAYS = 4;

// Outstanding orders the FPGA may emit before the host has accounted for them.
// mirrors trading_pkg::MAX_IN_FLIGHT / CREDIT_W
inline constexpr std::uint32_t MAX_IN_FLIGHT = 64;
inline constexpr std::uint32_t CREDIT_W = 7;  // $clog2(MAX_IN_FLIGHT + 1)

static_assert(1u << SYM_IDX_W == N_SYMBOLS, "SYM_IDX_W out of step with N_SYMBOLS");
static_assert(1u << ACT_IDX_W == N_ACTIVE, "ACT_IDX_W out of step with N_ACTIVE");
static_assert(1u << LEVEL_IDX_W == BOOK_LEVELS, "LEVEL_IDX_W out of step with BOOK_LEVELS");

// =============================================================================
// 2. Scalar types  (mirrors trading_pkg.sv §2)
// -----------------------------------------------------------------------------
// The RTL widths are not all a natural C++ width. Where they are not, the host
// uses the next-larger standard type and the *_MIN / *_MAX constants below are
// the authoritative range. Anything that writes one of these to the fabric MUST
// range-check first — the fabric silently truncates, the host must not.
// =============================================================================

// mirrors trading_pkg::price_t — logic [31:0], ITCH scaled integer, 4 decimals
inline constexpr std::uint32_t PRICE_W = 32;
inline constexpr std::uint32_t PRICE_SCALE = 10000;  // implied decimals
using price_t = std::uint32_t;
inline constexpr price_t PRICE_MAX = 0xFFFF'FFFFu;  // $429,496.7295

// mirrors trading_pkg::qty_t — logic [31:0], shares
inline constexpr std::uint32_t QTY_W = 32;
using qty_t = std::uint32_t;
inline constexpr qty_t QTY_MAX = 0xFFFF'FFFFu;

// mirrors trading_pkg::notional_t — logic [63:0], price * qty, ALWAYS saturating
inline constexpr std::uint32_t NOTIONAL_W = 64;
using notional_t = std::uint64_t;
inline constexpr notional_t NOTIONAL_MAX = 0xFFFF'FFFF'FFFF'FFFFull;

// mirrors trading_pkg::position_t — logic signed [39:0]. Long positive, short
// negative. There is no 40-bit C++ integer, so the host uses int64_t and the
// range below is enforced by positionInRange() / packSymRisk().
inline constexpr std::uint32_t POS_W = 40;
using position_t = std::int64_t;
inline constexpr position_t POSITION_MIN = -(static_cast<position_t>(1) << (POS_W - 1));       // -549,755,813,888
inline constexpr position_t POSITION_MAX = (static_cast<position_t>(1) << (POS_W - 1)) - 1;    // +549,755,813,887

[[nodiscard]] constexpr bool positionInRange(position_t v) noexcept {
    return v >= POSITION_MIN && v <= POSITION_MAX;
}

// mirrors trading_pkg::order_ref_t — logic [63:0], ITCH order reference number
using order_ref_t = std::uint64_t;

// mirrors trading_pkg::locate_t — logic [15:0], ITCH stock locate code
using locate_t = std::uint16_t;
inline constexpr locate_t LOCATE_MAX = static_cast<locate_t>(N_SYMBOLS - 1);

// mirrors trading_pkg::ts_ns_t — logic [47:0], ns since midnight ET
inline constexpr std::uint32_t TS_NS_W = 48;
using ts_ns_t = std::uint64_t;
inline constexpr ts_ns_t TS_NS_MAX = (1ull << TS_NS_W) - 1;

// mirrors trading_pkg::cycle_t — logic [47:0], free-running core-clock counter
inline constexpr std::uint32_t CYCLE_CNT_W = 48;
using cycle_t = std::uint64_t;
inline constexpr cycle_t CYCLE_MAX = (1ull << CYCLE_CNT_W) - 1;

// mirrors trading_pkg::sym_idx_t — logic [ACT_IDX_W-1:0], active-set index
using sym_idx_t = std::uint8_t;
static_assert(ACT_IDX_W == 8, "sym_idx_t must widen if N_ACTIVE grows past 256");

// mirrors trading_pkg::token_t / TOKEN_W — OUCH order token, 14 bytes
inline constexpr std::uint32_t TOKEN_W = 112;
inline constexpr std::size_t TOKEN_BYTES = TOKEN_W / 8;  // 14
static_assert(TOKEN_BYTES == 14, "OUCH order token is 14 bytes");

// Convert a fabric cycle count to nanoseconds. Integer only: cycles * 6400 ps,
// rounded to nearest ns. Do not "simplify" this with a double.
[[nodiscard]] constexpr std::uint64_t cyclesToNs(std::uint64_t cycles) noexcept {
    return (cycles * CORE_CLK_PS + 500ull) / 1000ull;
}

// =============================================================================
// 3. Enumerations  (mirrors trading_pkg.sv §3)
// -----------------------------------------------------------------------------
// Underlying types match the RTL bit widths so a value read from a register or
// a log record round-trips without a range check being silently skipped.
// =============================================================================

// mirrors trading_pkg::side_e — enum logic [0:0]
enum class Side : std::uint8_t {
    Buy = 0,
    Sell = 1,
};

// mirrors trading_pkg::trade_state_e — enum logic [2:0]
// The strategy may only quote in Open. Reset value is Disabled (fail-closed).
enum class TradeState : std::uint8_t {
    Closed = 0,    // outside session
    Preopen = 1,   // pre-market / cross orders only
    Open = 2,      // regular hours, quoting permitted
    Halted = 3,    // regulatory or operational halt
    Paused = 4,    // LULD pause
    Auction = 5,   // in a cross
    Stale = 6,     // sequence gap: book not trustworthy
    Disabled = 7,  // host- or risk-disabled. RESET VALUE.
};

// mirrors trading_pkg::book_op_e — enum logic [2:0]
enum class BookOp : std::uint8_t {
    Add = 0,      // ITCH 'A' / 'F'
    Execute = 1,  // ITCH 'E' / 'C'
    Cancel = 2,   // ITCH 'X'  (partial reduce)
    Delete = 3,   // ITCH 'D'  (full remove)
    Replace = 4,  // ITCH 'U'  (delete old ref, add new ref)
    Clear = 5,    // resync / start of day
    Nop = 6,
};

// mirrors trading_pkg::action_e — enum logic [1:0]
enum class Action : std::uint8_t {
    None = 0,
    Send = 1,    // new order
    Cancel = 2,  // cancel an existing order by token
};

// mirrors trading_pkg::risk_reason_e — enum logic [4:0]
// EVERY reason gets its own counter (TELEM_A_REJECT[24]). A check that never
// fires is a check you cannot trust. CLAUDE.md §5.7: silent failure is the
// worst failure mode in this domain.
enum class RiskReason : std::uint8_t {
    Ok = 0,
    MasterDisabled = 1,
    KillSwitch = 2,
    SymDisabled = 3,
    SessionClosed = 4,
    SymHalted = 5,
    BookStale = 6,
    SubPenny = 7,      // SEC Rule 612
    PriceCollar = 8,
    LuldBand = 9,      // outside the LULD band
    Ssr = 10,          // Reg SHO Rule 201 short-sale price test
    MaxShares = 11,
    MaxNotional = 12,
    PosLimit = 13,
    GrossLimit = 14,
    OpenOrders = 15,
    MsgRate = 16,
    Duplicate = 17,
    SelfMatch = 18,
    Restricted = 19,
    NoCredit = 20,     // in-flight limit reached
    ZeroQty = 21,
    ZeroPrice = 22,
    ParamInvalid = 23,
};

// mirrors trading_pkg::N_RISK_REASONS
inline constexpr std::size_t N_RISK_REASONS = 24;
static_assert(static_cast<std::size_t>(RiskReason::ParamInvalid) + 1 == N_RISK_REASONS,
              "risk_reason_e enumerators out of step with N_RISK_REASONS — "
              "the reject-counter array in telemetry is sized by this constant");

// mirrors trading_pkg::kill_src_e — enum logic [2:0], latched sticky
enum class KillSrc : std::uint8_t {
    None = 0,
    Host = 1,       // host wrote the kill register
    Watchdog = 2,   // host heartbeat stopped
    MsgRate = 3,    // outbound rate limit breached
    PosBreach = 4,  // aggregate position limit breached
    Gpio = 5,       // external hardware input
    LinkDown = 6,   // order-entry link lost
    SeqFault = 7,   // unrecoverable session sequence fault
};
inline constexpr std::size_t N_KILL_SRC = 8;

// -----------------------------------------------------------------------------
// Name tables. logd and metricsd both need human-readable reason strings and
// neither should own its own copy — a divergent table produces an audit log
// that says the wrong thing about why an order was rejected.
// -----------------------------------------------------------------------------
[[nodiscard]] constexpr std::string_view toString(RiskReason r) noexcept {
    switch (r) {
        case RiskReason::Ok:             return "OK";
        case RiskReason::MasterDisabled: return "MASTER_DISABLED";
        case RiskReason::KillSwitch:     return "KILL_SWITCH";
        case RiskReason::SymDisabled:    return "SYM_DISABLED";
        case RiskReason::SessionClosed:  return "SESSION_CLOSED";
        case RiskReason::SymHalted:      return "SYM_HALTED";
        case RiskReason::BookStale:      return "BOOK_STALE";
        case RiskReason::SubPenny:       return "SUB_PENNY";
        case RiskReason::PriceCollar:    return "PRICE_COLLAR";
        case RiskReason::LuldBand:       return "LULD_BAND";
        case RiskReason::Ssr:            return "SSR";
        case RiskReason::MaxShares:      return "MAX_SHARES";
        case RiskReason::MaxNotional:    return "MAX_NOTIONAL";
        case RiskReason::PosLimit:       return "POS_LIMIT";
        case RiskReason::GrossLimit:     return "GROSS_LIMIT";
        case RiskReason::OpenOrders:     return "OPEN_ORDERS";
        case RiskReason::MsgRate:        return "MSG_RATE";
        case RiskReason::Duplicate:      return "DUPLICATE";
        case RiskReason::SelfMatch:      return "SELF_MATCH";
        case RiskReason::Restricted:     return "RESTRICTED";
        case RiskReason::NoCredit:       return "NO_CREDIT";
        case RiskReason::ZeroQty:        return "ZERO_QTY";
        case RiskReason::ZeroPrice:      return "ZERO_PRICE";
        case RiskReason::ParamInvalid:   return "PARAM_INVALID";
    }
    return "RISK_REASON_UNKNOWN";
}

[[nodiscard]] constexpr std::string_view toString(KillSrc k) noexcept {
    switch (k) {
        case KillSrc::None:      return "NONE";
        case KillSrc::Host:      return "HOST";
        case KillSrc::Watchdog:  return "WATCHDOG";
        case KillSrc::MsgRate:   return "MSG_RATE";
        case KillSrc::PosBreach: return "POS_BREACH";
        case KillSrc::Gpio:      return "GPIO";
        case KillSrc::LinkDown:  return "LINK_DOWN";
        case KillSrc::SeqFault:  return "SEQ_FAULT";
    }
    return "KILL_SRC_UNKNOWN";
}

[[nodiscard]] constexpr std::string_view toString(TradeState s) noexcept {
    switch (s) {
        case TradeState::Closed:   return "CLOSED";
        case TradeState::Preopen:  return "PREOPEN";
        case TradeState::Open:     return "OPEN";
        case TradeState::Halted:   return "HALTED";
        case TradeState::Paused:   return "PAUSED";
        case TradeState::Auction:  return "AUCTION";
        case TradeState::Stale:    return "STALE";
        case TradeState::Disabled: return "DISABLED";
    }
    return "TRADE_STATE_UNKNOWN";
}

[[nodiscard]] constexpr std::string_view toString(Side s) noexcept {
    return s == Side::Buy ? "BUY" : "SELL";
}

[[nodiscard]] constexpr std::string_view toString(Action a) noexcept {
    switch (a) {
        case Action::None:   return "NONE";
        case Action::Send:   return "SEND";
        case Action::Cancel: return "CANCEL";
    }
    return "ACTION_UNKNOWN";
}

// Narrowing helpers: a value read off the wire or out of a register is not
// trusted to be a valid enumerator. These say so explicitly.
[[nodiscard]] constexpr bool isValidRiskReason(std::uint32_t v) noexcept { return v < N_RISK_REASONS; }
[[nodiscard]] constexpr bool isValidKillSrc(std::uint32_t v) noexcept { return v < N_KILL_SRC; }
[[nodiscard]] constexpr bool isValidTradeState(std::uint32_t v) noexcept { return v < 8; }

// =============================================================================
// 4. Bit-field plumbing
// -----------------------------------------------------------------------------
// Every packed record in this project is expressed as a table of {lsb, width}
// and a consteval check that the table tiles the declared width EXACTLY — no
// gaps, no overlaps, correct total. That check is the reason a shifted field
// cannot survive a build.
//
// Serialisation is LSB-first into little-endian uint32 words: bit b of the
// packed value lives in word (b/32), bit (b%32).
// =============================================================================
namespace bits {

struct BitField {
    std::uint16_t lsb;
    std::uint16_t width;

    [[nodiscard]] constexpr std::uint16_t msb() const noexcept {
        return static_cast<std::uint16_t>(lsb + width - 1);
    }
};

// Does this table cover [0, total) with each bit claimed by exactly one field?
template <std::size_t N>
[[nodiscard]] consteval bool tilesExactly(const std::array<BitField, N>& f, unsigned total) {
    unsigned sum = 0;
    for (const auto& x : f) {
        if (x.width == 0 || x.width > 64) return false;
        if (static_cast<unsigned>(x.lsb) + x.width > total) return false;
        sum += x.width;
    }
    if (sum != total) return false;
    for (unsigned b = 0; b < total; ++b) {
        unsigned covered = 0;
        for (const auto& x : f) {
            if (b >= x.lsb && b < static_cast<unsigned>(x.lsb) + x.width) ++covered;
        }
        if (covered != 1) return false;
    }
    return true;
}

[[nodiscard]] constexpr std::uint64_t widthMask(unsigned w) noexcept {
    return w >= 64 ? ~std::uint64_t{0} : ((std::uint64_t{1} << w) - 1);
}

// Sign-extend a `w`-bit two's-complement value held in the low bits of `v`.
[[nodiscard]] constexpr std::int64_t signExtend(std::uint64_t v, unsigned w) noexcept {
    const std::uint64_t m = std::uint64_t{1} << (w - 1);
    return static_cast<std::int64_t>((v & widthMask(w)) ^ m) - static_cast<std::int64_t>(m);
}

// Write `v` (low `f.width` bits) into the word array at bit offset f.lsb.
// The caller guarantees the array is long enough; the record pack() functions
// below take fixed-size std::array references so that is structural.
constexpr void put(std::uint32_t* words, BitField f, std::uint64_t v) noexcept {
    v &= widthMask(f.width);
    unsigned bit = f.lsb;
    unsigned consumed = 0;
    while (consumed < f.width) {
        const unsigned wi = bit >> 5;
        const unsigned off = bit & 31u;
        unsigned n = 32u - off;
        if (n > f.width - consumed) n = f.width - consumed;
        const std::uint32_t chunkMask = static_cast<std::uint32_t>(widthMask(n));
        const std::uint32_t chunk = static_cast<std::uint32_t>((v >> consumed) & chunkMask);
        const std::uint32_t placed = chunkMask << off;
        words[wi] = static_cast<std::uint32_t>((words[wi] & ~placed) | ((chunk << off) & placed));
        bit += n;
        consumed += n;
    }
}

// Read the `f.width` bits at f.lsb out of the word array, zero-extended.
[[nodiscard]] constexpr std::uint64_t get(const std::uint32_t* words, BitField f) noexcept {
    std::uint64_t out = 0;
    unsigned bit = f.lsb;
    unsigned consumed = 0;
    while (consumed < f.width) {
        const unsigned wi = bit >> 5;
        const unsigned off = bit & 31u;
        unsigned n = 32u - off;
        if (n > f.width - consumed) n = f.width - consumed;
        const std::uint32_t chunkMask = static_cast<std::uint32_t>(widthMask(n));
        const std::uint64_t chunk = (words[wi] >> off) & chunkMask;
        out |= chunk << consumed;
        bit += n;
        consumed += n;
    }
    return out;
}

}  // namespace bits

// =============================================================================
// 5. sym_risk_t  (mirrors trading_pkg.sv §4 `sym_risk_t`, 324 bits)
// -----------------------------------------------------------------------------
// Per-symbol pre-trade risk limits. Written by the host into the INACTIVE bank,
// read back, verified, then committed (host/README.md §3.1). The fast path
// never reads a half-written record.
//
// RESET VALUE IS ALL-ZERO = trading disabled, all limits zero (fail-closed).
// The default-constructed HostSymRisk below is exactly that, deliberately.
//
// BIT LAYOUT — first RTL member in the HIGH bits (see the header comment):
//
//   [323]     enabled              1
//   [322]     shortable            1
//   [321:290] max_order_qty       32
//   [289:226] max_order_notional  64
//   [225:186] max_long_pos        40   signed
//   [185:146] max_short_pos       40   signed, stored as a POSITIVE magnitude
//   [145:114] collar_lo           32
//   [113:82]  collar_hi           32
//   [81:50]   luld_lo             32
//   [49:18]   luld_hi             32
//   [17]      ssr_active           1
//   [16:1]    max_open_orders     16
//   [0]       tick_penny           1
//                                ---
//                                324
// =============================================================================
inline constexpr unsigned SYM_RISK_BITS = 324;
inline constexpr std::size_t SYM_RISK_WORDS = 11;  // ceil(324/32); top 28 bits zero
static_assert(SYM_RISK_WORDS * 32 >= SYM_RISK_BITS, "SYM_RISK_WORDS too small");
static_assert((SYM_RISK_WORDS - 1) * 32 < SYM_RISK_BITS, "SYM_RISK_WORDS not minimal");

namespace fields {

// clang-format off
inline constexpr bits::BitField RISK_TICK_PENNY         {  0,  1};
inline constexpr bits::BitField RISK_MAX_OPEN_ORDERS    {  1, 16};
inline constexpr bits::BitField RISK_SSR_ACTIVE         { 17,  1};
inline constexpr bits::BitField RISK_LULD_HI            { 18, 32};
inline constexpr bits::BitField RISK_LULD_LO            { 50, 32};
inline constexpr bits::BitField RISK_COLLAR_HI          { 82, 32};
inline constexpr bits::BitField RISK_COLLAR_LO          {114, 32};
inline constexpr bits::BitField RISK_MAX_SHORT_POS      {146, 40};
inline constexpr bits::BitField RISK_MAX_LONG_POS       {186, 40};
inline constexpr bits::BitField RISK_MAX_ORDER_NOTIONAL {226, 64};
inline constexpr bits::BitField RISK_MAX_ORDER_QTY      {290, 32};
inline constexpr bits::BitField RISK_SHORTABLE          {322,  1};
inline constexpr bits::BitField RISK_ENABLED            {323,  1};
// clang-format on

inline constexpr std::array<bits::BitField, 13> kSymRiskFields{
    RISK_TICK_PENNY,   RISK_MAX_OPEN_ORDERS,    RISK_SSR_ACTIVE,    RISK_LULD_HI,
    RISK_LULD_LO,      RISK_COLLAR_HI,          RISK_COLLAR_LO,     RISK_MAX_SHORT_POS,
    RISK_MAX_LONG_POS, RISK_MAX_ORDER_NOTIONAL, RISK_MAX_ORDER_QTY, RISK_SHORTABLE,
    RISK_ENABLED,
};

}  // namespace fields

static_assert(bits::tilesExactly(fields::kSymRiskFields, SYM_RISK_BITS),
              "sym_risk_t bit table does not tile 324 bits exactly — host and "
              "rtl/pkg/trading_pkg.sv::sym_risk_t have diverged");

// Host-side value type. Wider than the RTL fields; pack() range-checks.
// mirrors rtl/pkg/trading_pkg.sv :: sym_risk_t
struct SymRisk {
    bool enabled = false;             // [323]
    bool shortable = false;           // [322] not on the restricted / HTB list
    qty_t maxOrderQty = 0;            // [321:290]
    notional_t maxOrderNotional = 0;  // [289:226] saturating
    position_t maxLongPos = 0;        // [225:186] signed 40-bit
    position_t maxShortPos = 0;       // [185:146] signed 40-bit, POSITIVE magnitude
    price_t collarLo = 0;             // [145:114] hard price floor
    price_t collarHi = 0;             // [113:82]  hard price ceiling
    price_t luldLo = 0;               // [81:50]   current LULD lower band
    price_t luldHi = 0;               // [49:18]   current LULD upper band
    bool ssrActive = false;           // [17] Reg SHO Rule 201 in force
    std::uint16_t maxOpenOrders = 0;  // [16:1]
    bool tickPenny = false;           // [0] Rule 612: price must be a whole cent

    friend constexpr bool operator==(const SymRisk&, const SymRisk&) = default;
};

using SymRiskWords = std::array<std::uint32_t, SYM_RISK_WORDS>;

// Is this record representable in the fabric's field widths? paramd MUST call
// this before packing: the bit packer truncates silently, and a truncated risk
// limit is a risk limit that does not exist.
[[nodiscard]] constexpr bool isPackable(const SymRisk& r) noexcept {
    return positionInRange(r.maxLongPos) && positionInRange(r.maxShortPos) &&
           r.maxLongPos >= 0 && r.maxShortPos >= 0;
}

[[nodiscard]] constexpr SymRiskWords pack(const SymRisk& r) noexcept {
    SymRiskWords w{};
    std::uint32_t* p = w.data();
    bits::put(p, fields::RISK_TICK_PENNY, r.tickPenny ? 1u : 0u);
    bits::put(p, fields::RISK_MAX_OPEN_ORDERS, r.maxOpenOrders);
    bits::put(p, fields::RISK_SSR_ACTIVE, r.ssrActive ? 1u : 0u);
    bits::put(p, fields::RISK_LULD_HI, r.luldHi);
    bits::put(p, fields::RISK_LULD_LO, r.luldLo);
    bits::put(p, fields::RISK_COLLAR_HI, r.collarHi);
    bits::put(p, fields::RISK_COLLAR_LO, r.collarLo);
    bits::put(p, fields::RISK_MAX_SHORT_POS, static_cast<std::uint64_t>(r.maxShortPos));
    bits::put(p, fields::RISK_MAX_LONG_POS, static_cast<std::uint64_t>(r.maxLongPos));
    bits::put(p, fields::RISK_MAX_ORDER_NOTIONAL, r.maxOrderNotional);
    bits::put(p, fields::RISK_MAX_ORDER_QTY, r.maxOrderQty);
    bits::put(p, fields::RISK_SHORTABLE, r.shortable ? 1u : 0u);
    bits::put(p, fields::RISK_ENABLED, r.enabled ? 1u : 0u);
    return w;
}

[[nodiscard]] constexpr SymRisk unpackSymRisk(const SymRiskWords& w) noexcept {
    const std::uint32_t* p = w.data();
    SymRisk r{};
    r.tickPenny = bits::get(p, fields::RISK_TICK_PENNY) != 0;
    r.maxOpenOrders = static_cast<std::uint16_t>(bits::get(p, fields::RISK_MAX_OPEN_ORDERS));
    r.ssrActive = bits::get(p, fields::RISK_SSR_ACTIVE) != 0;
    r.luldHi = static_cast<price_t>(bits::get(p, fields::RISK_LULD_HI));
    r.luldLo = static_cast<price_t>(bits::get(p, fields::RISK_LULD_LO));
    r.collarHi = static_cast<price_t>(bits::get(p, fields::RISK_COLLAR_HI));
    r.collarLo = static_cast<price_t>(bits::get(p, fields::RISK_COLLAR_LO));
    r.maxShortPos = bits::signExtend(bits::get(p, fields::RISK_MAX_SHORT_POS), POS_W);
    r.maxLongPos = bits::signExtend(bits::get(p, fields::RISK_MAX_LONG_POS), POS_W);
    r.maxOrderNotional = bits::get(p, fields::RISK_MAX_ORDER_NOTIONAL);
    r.maxOrderQty = static_cast<qty_t>(bits::get(p, fields::RISK_MAX_ORDER_QTY));
    r.shortable = bits::get(p, fields::RISK_SHORTABLE) != 0;
    r.enabled = bits::get(p, fields::RISK_ENABLED) != 0;
    return r;
}

// =============================================================================
// 6. sym_strat_t  (mirrors trading_pkg.sv §4 `sym_strat_t`, 149 bits)
// -----------------------------------------------------------------------------
//   [148]     strat_enabled   1
//   [147:144] strat_select    4   which hardened primitive to run
//   [143:112] quote_qty      32
//   [111:80]  edge_ticks     32   threshold, in ticks
//   [79:48]   min_book_qty   32   don't act on a thin book
//   [47:16]   fair_value     32   written by the host at ms cadence
//   [15:0]    imbalance_thr  16
//                           ---
//                           149
// =============================================================================
inline constexpr unsigned SYM_STRAT_BITS = 149;
inline constexpr std::size_t SYM_STRAT_WORDS = 5;  // ceil(149/32); top 11 bits zero
static_assert(SYM_STRAT_WORDS * 32 >= SYM_STRAT_BITS, "SYM_STRAT_WORDS too small");
static_assert((SYM_STRAT_WORDS - 1) * 32 < SYM_STRAT_BITS, "SYM_STRAT_WORDS not minimal");

namespace fields {

// clang-format off
inline constexpr bits::BitField STRAT_IMBALANCE_THR {  0, 16};
inline constexpr bits::BitField STRAT_FAIR_VALUE    { 16, 32};
inline constexpr bits::BitField STRAT_MIN_BOOK_QTY  { 48, 32};
inline constexpr bits::BitField STRAT_EDGE_TICKS    { 80, 32};
inline constexpr bits::BitField STRAT_QUOTE_QTY     {112, 32};
inline constexpr bits::BitField STRAT_SELECT        {144,  4};
inline constexpr bits::BitField STRAT_ENABLED       {148,  1};
// clang-format on

inline constexpr std::array<bits::BitField, 7> kSymStratFields{
    STRAT_IMBALANCE_THR, STRAT_FAIR_VALUE, STRAT_MIN_BOOK_QTY, STRAT_EDGE_TICKS,
    STRAT_QUOTE_QTY,     STRAT_SELECT,     STRAT_ENABLED,
};

}  // namespace fields

static_assert(bits::tilesExactly(fields::kSymStratFields, SYM_STRAT_BITS),
              "sym_strat_t bit table does not tile 149 bits exactly — host and "
              "rtl/pkg/trading_pkg.sv::sym_strat_t have diverged");

// mirrors rtl/pkg/trading_pkg.sv :: sym_strat_t
struct SymStrat {
    bool stratEnabled = false;         // [148]
    std::uint8_t stratSelect = 0;      // [147:144] 4 bits
    qty_t quoteQty = 0;                // [143:112]
    price_t edgeTicks = 0;             // [111:80]
    qty_t minBookQty = 0;              // [79:48]
    price_t fairValue = 0;             // [47:16]
    std::uint16_t imbalanceThr = 0;    // [15:0]

    friend constexpr bool operator==(const SymStrat&, const SymStrat&) = default;
};

using SymStratWords = std::array<std::uint32_t, SYM_STRAT_WORDS>;

inline constexpr std::uint8_t STRAT_SELECT_MAX = 0x0F;

[[nodiscard]] constexpr bool isPackable(const SymStrat& s) noexcept {
    return s.stratSelect <= STRAT_SELECT_MAX;
}

[[nodiscard]] constexpr SymStratWords pack(const SymStrat& s) noexcept {
    SymStratWords w{};
    std::uint32_t* p = w.data();
    bits::put(p, fields::STRAT_IMBALANCE_THR, s.imbalanceThr);
    bits::put(p, fields::STRAT_FAIR_VALUE, s.fairValue);
    bits::put(p, fields::STRAT_MIN_BOOK_QTY, s.minBookQty);
    bits::put(p, fields::STRAT_EDGE_TICKS, s.edgeTicks);
    bits::put(p, fields::STRAT_QUOTE_QTY, s.quoteQty);
    bits::put(p, fields::STRAT_SELECT, s.stratSelect);
    bits::put(p, fields::STRAT_ENABLED, s.stratEnabled ? 1u : 0u);
    return w;
}

[[nodiscard]] constexpr SymStrat unpackSymStrat(const SymStratWords& w) noexcept {
    const std::uint32_t* p = w.data();
    SymStrat s{};
    s.imbalanceThr = static_cast<std::uint16_t>(bits::get(p, fields::STRAT_IMBALANCE_THR));
    s.fairValue = static_cast<price_t>(bits::get(p, fields::STRAT_FAIR_VALUE));
    s.minBookQty = static_cast<qty_t>(bits::get(p, fields::STRAT_MIN_BOOK_QTY));
    s.edgeTicks = static_cast<price_t>(bits::get(p, fields::STRAT_EDGE_TICKS));
    s.quoteQty = static_cast<qty_t>(bits::get(p, fields::STRAT_QUOTE_QTY));
    s.stratSelect = static_cast<std::uint8_t>(bits::get(p, fields::STRAT_SELECT));
    s.stratEnabled = bits::get(p, fields::STRAT_ENABLED) != 0;
    return s;
}

// =============================================================================
// 7. order_token_t  (mirrors trading_pkg.sv §5 `order_token_t`, 112 bits)
// -----------------------------------------------------------------------------
// The token is the ONLY link between an FPGA-emitted order and the host's
// accounting. It must be unique for the life of the session and decodable by
// the host WITHOUT a lookup — that is what makes the reconciler able to work
// from a drop copy alone.
//
//   [111:96] magic     16   build/session tag; host REJECTS a mismatch
//   [95:92]  strat_id   4
//   [91:80]  sym       12   active-set index, zero-extended
//   [79:32]  counter   48   monotonic, never reused within a session
//   [31:0]   rsvd      32
//                     ---
//                     112
//
// TWO BYTE ORDERS EXIST AND THEY ARE NOT INTERCHANGEABLE:
//   pack()/unpack()             — LSB-first little-endian. This is the fabric's
//                                 in-memory order and therefore the order the
//                                 token appears in inside a DMA log record.
//   packWire()/unpackWire()     — big-endian, MSB first. This is the order the
//                                 14 token bytes appear in on an OUCH message
//                                 (trading_pkg.sv §6 notes ITCH/OUCH are
//                                 big-endian on the wire). sessiond and the
//                                 reconciler use this one.
// =============================================================================
inline constexpr unsigned ORDER_TOKEN_BITS = TOKEN_W;  // 112

namespace fields {

// clang-format off
inline constexpr bits::BitField TOKEN_RSVD     {  0, 32};
inline constexpr bits::BitField TOKEN_COUNTER  { 32, 48};
inline constexpr bits::BitField TOKEN_SYM      { 80, 12};
inline constexpr bits::BitField TOKEN_STRAT_ID { 92,  4};
inline constexpr bits::BitField TOKEN_MAGIC    { 96, 16};
// clang-format on

inline constexpr std::array<bits::BitField, 5> kOrderTokenFields{
    TOKEN_RSVD, TOKEN_COUNTER, TOKEN_SYM, TOKEN_STRAT_ID, TOKEN_MAGIC,
};

}  // namespace fields

static_assert(bits::tilesExactly(fields::kOrderTokenFields, ORDER_TOKEN_BITS),
              "order_token_t bit table does not tile 112 bits exactly — host and "
              "rtl/pkg/trading_pkg.sv::order_token_t have diverged");

// mirrors rtl/pkg/trading_pkg.sv :: order_token_t
struct OrderToken {
    std::uint16_t magic = 0;     // [111:96]
    std::uint8_t stratId = 0;    // [95:92]  4 bits
    std::uint16_t sym = 0;       // [91:80]  12 bits, active-set index
    std::uint64_t counter = 0;   // [79:32]  48 bits
    std::uint32_t rsvd = 0;      // [31:0]

    friend constexpr bool operator==(const OrderToken&, const OrderToken&) = default;
};

using OrderTokenBytes = std::array<std::byte, TOKEN_BYTES>;  // 14

inline constexpr std::uint64_t TOKEN_COUNTER_MAX = (1ull << 48) - 1;
inline constexpr std::uint16_t TOKEN_SYM_MAX = 0x0FFF;
inline constexpr std::uint8_t TOKEN_STRAT_ID_MAX = 0x0F;

[[nodiscard]] constexpr bool isPackable(const OrderToken& t) noexcept {
    return t.counter <= TOKEN_COUNTER_MAX && t.sym <= TOKEN_SYM_MAX &&
           t.stratId <= TOKEN_STRAT_ID_MAX;
}

// Pack into a 128-bit staging pair, then emit the low 14 bytes LSB-first.
[[nodiscard]] constexpr OrderTokenBytes pack(const OrderToken& t) noexcept {
    std::array<std::uint32_t, 4> w{};  // 128 bits of scratch; top 16 discarded
    std::uint32_t* p = w.data();
    bits::put(p, fields::TOKEN_RSVD, t.rsvd);
    bits::put(p, fields::TOKEN_COUNTER, t.counter);
    bits::put(p, fields::TOKEN_SYM, t.sym);
    bits::put(p, fields::TOKEN_STRAT_ID, t.stratId);
    bits::put(p, fields::TOKEN_MAGIC, t.magic);

    OrderTokenBytes out{};
    for (std::size_t i = 0; i < TOKEN_BYTES; ++i) {
        out[i] = static_cast<std::byte>((w[i >> 2] >> ((i & 3u) * 8u)) & 0xFFu);
    }
    return out;
}

[[nodiscard]] constexpr OrderToken unpackOrderToken(const OrderTokenBytes& b) noexcept {
    std::array<std::uint32_t, 4> w{};
    for (std::size_t i = 0; i < TOKEN_BYTES; ++i) {
        w[i >> 2] |= static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(b[i]))
                     << ((i & 3u) * 8u);
    }
    const std::uint32_t* p = w.data();
    OrderToken t{};
    t.rsvd = static_cast<std::uint32_t>(bits::get(p, fields::TOKEN_RSVD));
    t.counter = bits::get(p, fields::TOKEN_COUNTER);
    t.sym = static_cast<std::uint16_t>(bits::get(p, fields::TOKEN_SYM));
    t.stratId = static_cast<std::uint8_t>(bits::get(p, fields::TOKEN_STRAT_ID));
    t.magic = static_cast<std::uint16_t>(bits::get(p, fields::TOKEN_MAGIC));
    return t;
}

// Big-endian (OUCH wire) order: byte 0 is bits [111:104].
[[nodiscard]] constexpr OrderTokenBytes packWire(const OrderToken& t) noexcept {
    const OrderTokenBytes le = pack(t);
    OrderTokenBytes be{};
    for (std::size_t i = 0; i < TOKEN_BYTES; ++i) be[i] = le[TOKEN_BYTES - 1 - i];
    return be;
}

[[nodiscard]] constexpr OrderToken unpackOrderTokenWire(const OrderTokenBytes& be) noexcept {
    OrderTokenBytes le{};
    for (std::size_t i = 0; i < TOKEN_BYTES; ++i) le[i] = be[TOKEN_BYTES - 1 - i];
    return unpackOrderToken(le);
}

// =============================================================================
// 8. Helper functions mirrored from trading_pkg.sv §6
// -----------------------------------------------------------------------------
// These exist so the host computes the SAME answer as the fabric, bit for bit.
// Reimplementing "is this a whole cent" with a modulo would agree with the
// fabric today and disagree the day someone changes RECIP_100 — so the host
// mirrors the reciprocal multiply, exactly.
// =============================================================================

// mirrors trading_pkg::RECIP_100 / RECIP_100_SHIFT
inline constexpr std::uint32_t RECIP_100 = 1'374'389'535u;
inline constexpr unsigned RECIP_100_SHIFT = 37;

// mirrors trading_pkg::div100 — divide an ITCH price by 100, no divider.
[[nodiscard]] constexpr price_t div100(price_t px) noexcept {
    const std::uint64_t prod = static_cast<std::uint64_t>(px) * static_cast<std::uint64_t>(RECIP_100);
    return static_cast<price_t>(prod >> RECIP_100_SHIFT);
}

// mirrors trading_pkg::is_whole_penny — SEC Rule 612 sub-penny test.
[[nodiscard]] constexpr bool isWholePenny(price_t px) noexcept {
    return px == div100(px) * 100u;
}

// mirrors trading_pkg::sat_add64 — ALL risk/position arithmetic saturates.
// A wrapped counter turns a risk check into a no-op (CLAUDE.md §5).
[[nodiscard]] constexpr std::uint64_t satAdd64(std::uint64_t a, std::uint64_t b) noexcept {
    const std::uint64_t s = a + b;
    return s < a ? ~std::uint64_t{0} : s;
}

// mirrors trading_pkg::sat_sub64 — floor at zero.
[[nodiscard]] constexpr std::uint64_t satSub64(std::uint64_t a, std::uint64_t b) noexcept {
    return a > b ? a - b : 0ull;
}

// Notional of an order, saturating. price is ITCH-scaled (4 decimals), so the
// result is also scaled by PRICE_SCALE. Do NOT divide it back out on this path.
[[nodiscard]] constexpr notional_t orderNotional(price_t px, qty_t qty) noexcept {
    return static_cast<notional_t>(px) * static_cast<notional_t>(qty);  // 32x32 -> 64, cannot overflow
}

// mirrors trading_pkg::bswap16/32/64 — ITCH and OUCH are big-endian on the wire.
[[nodiscard]] constexpr std::uint16_t bswap16(std::uint16_t d) noexcept {
    return static_cast<std::uint16_t>((d >> 8) | (d << 8));
}
[[nodiscard]] constexpr std::uint32_t bswap32(std::uint32_t d) noexcept {
    return ((d & 0x0000'00FFu) << 24) | ((d & 0x0000'FF00u) << 8) |
           ((d & 0x00FF'0000u) >> 8) | ((d & 0xFF00'0000u) >> 24);
}
[[nodiscard]] constexpr std::uint64_t bswap64(std::uint64_t d) noexcept {
    return (static_cast<std::uint64_t>(bswap32(static_cast<std::uint32_t>(d))) << 32) |
           bswap32(static_cast<std::uint32_t>(d >> 32));
}

// =============================================================================
// 9. Parameter-window addressing
// -----------------------------------------------------------------------------
// Mirrors rtl/telemetry/telemetry_pkg.sv §4 and the window table in
// rtl/ctrl/README.md §2.6. The 16-bit value written to a window's ADDR register
// (which becomes cfg_wr_addr into the pcie->core handshake) is a flat word
// index:
//
//     risk  addr = sym_idx * RISK_WORDS_PER_SYM (12) + word_idx
//     strat addr = sym_idx * STRAT_WORDS_PER_SYM (8) + word_idx
//     filter addr = raw ITCH stock locate, 0 .. N_SYMBOLS-1
//     tmpl   addr = template word index
//     session addr = running word index
//
// ⚠ THERE IS NO A/B BANKING. An earlier revision of the host contract described
//   an inactive-bank / active-bank / bank-flip model. The hardware does not do
//   that and never did. The real mechanism is WRITE PROTECTION plus a
//   write-side checksum:
//
//     * Writes to the FILTER, RISK, TMPL and SESSION windows are REJECTED while
//       trading is enabled (csr_regfile.sv `w_protected`). There is no override
//       bit and no force flag. A rejected write sets CFG_ERR[E_PROTECTED],
//       increments a counter, and changes nothing.
//     * The operator is therefore forced through:
//         disable trading -> change limits -> commit -> read back and verify
//         the checksum -> re-enable trading
//     * ⚠ The STRAT window is deliberately NOT protected, because
//       sym_strat_t.fair_value is updated at millisecond cadence while trading.
//       NEVER move a risk limit into the strategy window.
//     * ⚠ The fabric does NOT implement four-eyes approval. It provides the
//       enforcement point that makes a host-side four-eyes control meaningful.
//       Requiring a second authenticated operator is paramd's job.
// =============================================================================

// mirrors rtl/telemetry/telemetry_pkg.sv §4
inline constexpr std::uint32_t RISK_WORDS_PER_SYM = 12;   // 11 used, 1 pad
inline constexpr std::uint32_t STRAT_WORDS_PER_SYM = 8;   // 5 used, 3 pad
inline constexpr std::uint32_t FILTER_WORDS = N_SYMBOLS;  // one word per locate
inline constexpr std::uint32_t TMPL_WORDS_MAX = 2048;
inline constexpr std::uint32_t SESSION_WORDS_MAX = 32;

static_assert(RISK_WORDS_PER_SYM >= SYM_RISK_WORDS, "risk record does not fit its address stride");
static_assert(STRAT_WORDS_PER_SYM >= SYM_STRAT_WORDS, "strat record does not fit its address stride");
// The whole active set must be addressable in the 16-bit window ADDR register.
static_assert((N_ACTIVE - 1) * RISK_WORDS_PER_SYM + RISK_WORDS_PER_SYM - 1 <= 0xFFFF,
              "risk table overflows the 16-bit window address");
static_assert((N_ACTIVE - 1) * STRAT_WORDS_PER_SYM + STRAT_WORDS_PER_SYM - 1 <= 0xFFFF,
              "strat table overflows the 16-bit window address");
static_assert(FILTER_WORDS - 1 <= 0xFFFF, "filter table overflows the 16-bit window address");

[[nodiscard]] constexpr std::uint16_t riskParamAddr(std::uint32_t symIdx,
                                                    std::uint32_t wordIdx) noexcept {
    return static_cast<std::uint16_t>(symIdx * RISK_WORDS_PER_SYM + wordIdx);
}
[[nodiscard]] constexpr std::uint16_t stratParamAddr(std::uint32_t symIdx,
                                                     std::uint32_t wordIdx) noexcept {
    return static_cast<std::uint16_t>(symIdx * STRAT_WORDS_PER_SYM + wordIdx);
}
[[nodiscard]] constexpr bool riskAddrValid(std::uint32_t symIdx, std::uint32_t wordIdx) noexcept {
    return symIdx < N_ACTIVE && wordIdx < RISK_WORDS_PER_SYM;
}
[[nodiscard]] constexpr bool stratAddrValid(std::uint32_t symIdx, std::uint32_t wordIdx) noexcept {
    return symIdx < N_ACTIVE && wordIdx < STRAT_WORDS_PER_SYM;
}
static_assert(riskParamAddr(0, 0) == 0 && riskParamAddr(1, 0) == 12 && riskParamAddr(2, 3) == 27);
static_assert(stratParamAddr(0, 0) == 0 && stratParamAddr(1, 0) == 8 && stratParamAddr(3, 2) == 26);

// -----------------------------------------------------------------------------
// The write-side checksum — rtl/ctrl/README.md §6, csr_regfile.sv line ~842.
//
// Both fabric and host fold every word pushed through a window since the last
// reset_chk:
//
//     chk = 0xA5A5_5A5A                        // CHK_SEED
//     for each (addr, data) written, in order:
//         chk = rotl32(chk, 1) ^ data ^ (addr & 0xFFFF)
//
// `addr` is the window ADDR value AT THE TIME OF THE DATA WRITE — i.e. before
// auto-increment advances it. WR_CHK is the running value; CMT_CHK is what was
// latched when the commit pulse fired.
//
// ⚠ WHAT THIS PROVES AND WHAT IT DOES NOT. Comparing a host-computed checksum
//   against CMT_CHK verifies the TRANSPORT: it catches a corrupted, dropped,
//   duplicated or reordered BAR write, which are the failure modes the PCIe
//   path actually has. It does NOT verify STORAGE — that risk_gate holds what
//   the CSR forwarded. rtl/ctrl/README.md §6 flags that as an open item: until
//   risk_gate and strategy_engine expose a live-table checksum in
//   risk_stat[]/strat_stat[], startup step 8 verifies the transport only.
//   Do not describe it as end-to-end parameter verification.
// -----------------------------------------------------------------------------
inline constexpr std::uint32_t CHK_SEED = 0xA5A5'5A5Au;  // telemetry_pkg::LOG_CHK_SEED

[[nodiscard]] constexpr std::uint32_t rotl32(std::uint32_t v, unsigned n) noexcept {
    return n == 0 ? v : static_cast<std::uint32_t>((v << n) | (v >> (32u - n)));
}

// One fold step. `addr` is the pre-increment window address of this word.
[[nodiscard]] constexpr std::uint32_t chkStep(std::uint32_t chk, std::uint16_t addr,
                                              std::uint32_t data) noexcept {
    return rotl32(chk, 1) ^ data ^ static_cast<std::uint32_t>(addr);
}

// Fold a contiguous run of words starting at `startAddr` with auto-increment on.
[[nodiscard]] constexpr std::uint32_t chkWords(std::uint32_t chk, std::uint16_t startAddr,
                                               std::span<const std::uint32_t> words) noexcept {
    std::uint16_t a = startAddr;
    for (std::uint32_t d : words) {
        chk = chkStep(chk, a, d);
        a = static_cast<std::uint16_t>(a + 1);
    }
    return chk;
}

// -----------------------------------------------------------------------------
// Symbol filter entry — the FILTER window DATA word, addressed by the RAW ITCH
// stock locate (0 .. N_SYMBOLS-1). This is the map from the 8192-entry locate
// space onto the 256-entry active set.
//
// ⚠ TODO(rtl-contract): rtl/ctrl/csr_regfile.sv is a pure TRANSPORT — it
//   forwards {target, addr, data} unchanged and does not define the bit layout
//   of a filter word. rtl/feed/symbol_filter.sv is the block that consumes it.
//   The {valid[0], active_idx[15:8]} encoding below is carried over from the
//   host contract document and is the one field layout here that the RTL does
//   NOT yet pin down. Reconcile against the feed block before trusting it.
// -----------------------------------------------------------------------------
struct FilterEntry {
    bool valid = false;
    sym_idx_t activeIdx = 0;

    friend constexpr bool operator==(const FilterEntry&, const FilterEntry&) = default;
};

inline constexpr unsigned FILTER_VALID_BIT = 0;
inline constexpr unsigned FILTER_ACTIVE_IDX_SHIFT = 8;
inline constexpr std::uint32_t FILTER_ACTIVE_IDX_MASK = 0xFFu;

[[nodiscard]] constexpr std::uint32_t pack(const FilterEntry& f) noexcept {
    return (f.valid ? (1u << FILTER_VALID_BIT) : 0u) |
           ((static_cast<std::uint32_t>(f.activeIdx) & FILTER_ACTIVE_IDX_MASK)
            << FILTER_ACTIVE_IDX_SHIFT);
}

[[nodiscard]] constexpr FilterEntry unpackFilterEntry(std::uint32_t w) noexcept {
    FilterEntry f{};
    f.valid = ((w >> FILTER_VALID_BIT) & 1u) != 0;
    f.activeIdx = static_cast<sym_idx_t>((w >> FILTER_ACTIVE_IDX_SHIFT) & FILTER_ACTIVE_IDX_MASK);
    return f;
}

// =============================================================================
// 10. Fabric health word  (manuals/06-operations/03-monitoring-and-telemetry.md §4)
// -----------------------------------------------------------------------------
// One register a human or a script reads in a single access to know whether to
// panic. Exposed at CTRL_HEALTH.
// =============================================================================
namespace health {
inline constexpr std::uint32_t ALL_OK            = 1u << 0;   // AND of everything below being clear
inline constexpr std::uint32_t LINK_DOWN         = 1u << 1;
inline constexpr std::uint32_t SEQ_GAP           = 1u << 2;
inline constexpr std::uint32_t UNKNOWN_MSG       = 1u << 3;
inline constexpr std::uint32_t BOOK_INTEGRITY    = 1u << 4;
inline constexpr std::uint32_t FIFO_OVERFLOW     = 1u << 5;
inline constexpr std::uint32_t CDC_ERROR         = 1u << 6;
inline constexpr std::uint32_t KILL_ACTIVE       = 1u << 7;
inline constexpr std::uint32_t NOT_ARMED         = 1u << 8;
inline constexpr std::uint32_t HEARTBEAT_STALE   = 1u << 9;
inline constexpr std::uint32_t OVERTEMP_WARN     = 1u << 10;
inline constexpr std::uint32_t OVERTEMP_CRIT     = 1u << 11;
inline constexpr std::uint32_t PARAM_CRC_MISMATCH= 1u << 12;
inline constexpr std::uint32_t PCIE_ERROR        = 1u << 13;
inline constexpr std::uint32_t SESSION_DOWN      = 1u << 14;
inline constexpr std::uint32_t RATE_LIMITED      = 1u << 15;

// Everything that is a hard stop for trading. metricsd alerts on any of these.
inline constexpr std::uint32_t FATAL_MASK = SEQ_GAP | BOOK_INTEGRITY | FIFO_OVERFLOW | CDC_ERROR |
                                            KILL_ACTIVE | OVERTEMP_CRIT | PARAM_CRC_MISMATCH |
                                            PCIE_ERROR | SESSION_DOWN;
}  // namespace health

// =============================================================================
// 11. Venue session state  (SHARED_CONTRACT.md §SESSION, SESS_STATE)
// =============================================================================
enum class SessionState : std::uint32_t {
    Down = 0,
    Connecting = 1,
    LoginSent = 2,
    Up = 3,
    Fault = 4,
};

[[nodiscard]] constexpr std::string_view toString(SessionState s) noexcept {
    switch (s) {
        case SessionState::Down:       return "DOWN";
        case SessionState::Connecting: return "CONNECTING";
        case SessionState::LoginSent:  return "LOGIN_SENT";
        case SessionState::Up:         return "UP";
        case SessionState::Fault:      return "FAULT";
    }
    return "SESSION_STATE_UNKNOWN";
}

}  // namespace trading

#endif  // TRADING_TYPES_HPP
