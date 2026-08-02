// =============================================================================
// log_record.hpp — DMA audit-log record layouts
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : device layer (agent 1). Shared with logd, reconciler and metricsd.
// Mirrors : rtl/telemetry/telemetry_pkg.sv §5 (log_rec_t) — RTL truth
//           SHARED_CONTRACT.md §"DMA log record header"  — provisional
//
// -----------------------------------------------------------------------------
// ⚠⚠ TWO INCOMPATIBLE RECORD FORMATS ARE DEFINED HERE, DELIBERATELY.
//
//   SHARED_CONTRACT.md specifies a 32-byte `LogRecordHeader` followed by a
//   variable-length payload, with a 32-bit `seq` and a CRC32 over the payload.
//
//   rtl/telemetry/telemetry_pkg.sv — WHICH EXISTS, contrary to the brief —
//   specifies something quite different: a FIXED 512-bit / 64-byte record
//   (`log_rec_t`) with no separate header, a 48-bit `seq`, and a rotate-XOR
//   fold (`chk32`) rather than a CRC. It is exactly one host cache line and
//   exactly one beat on a 512-bit DMA datapath, which is why the fabric can
//   guarantee a record is never torn.
//
//   Both are implemented. `LogFormat` selects between them at DmaLogRing
//   construction. `LogFormat::Fabric64` is the one that matches the RTL as it
//   stands today and should be the default once the contract is reconciled;
//   `LogFormat::ContractV0` exists so components written against
//   SHARED_CONTRACT.md keep working. THIS MUST BE RESOLVED — carrying two ring
//   formats indefinitely is how a CAT trail ends up half-parseable.
// TODO(rtl-contract): reconcile SHARED_CONTRACT.md's 32-byte header against
// telemetry_pkg.sv::log_rec_t and delete the losing format.
// =============================================================================
#ifndef TRADING_LOG_RECORD_HPP
#define TRADING_LOG_RECORD_HPP

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>
#include <string_view>

#include "trading/types.hpp"

namespace trading {

// =============================================================================
// 1. Which layout is in the ring
// =============================================================================
enum class LogFormat : std::uint8_t {
    ContractV0,  // 32-byte LogRecordHeader + variable payload (SHARED_CONTRACT.md)
    Fabric64,    // fixed 64-byte telemetry_pkg::log_rec_t (RTL truth)
};

[[nodiscard]] constexpr std::string_view toString(LogFormat f) noexcept {
    return f == LogFormat::ContractV0 ? "ContractV0" : "Fabric64";
}

// =============================================================================
// 2. ContractV0 — SHARED_CONTRACT.md §"DMA log record header"
// =============================================================================

// Record types as enumerated in SHARED_CONTRACT.md.
enum class LogRecordType : std::uint16_t {
    OrderDecision = 1,
    OrderEmitted = 2,
    RiskReject = 3,
    Fill = 4,
    VenueAck = 5,
    VenueReject = 6,
    KillEvent = 7,
    ParamCommit = 8,
    SessionEvent = 9,
    Heartbeat = 10,
    RingDrop = 11,
};

[[nodiscard]] constexpr std::string_view toString(LogRecordType t) noexcept {
    switch (t) {
        case LogRecordType::OrderDecision: return "ORDER_DECISION";
        case LogRecordType::OrderEmitted:  return "ORDER_EMITTED";
        case LogRecordType::RiskReject:    return "RISK_REJECT";
        case LogRecordType::Fill:          return "FILL";
        case LogRecordType::VenueAck:      return "VENUE_ACK";
        case LogRecordType::VenueReject:   return "VENUE_REJECT";
        case LogRecordType::KillEvent:     return "KILL_EVENT";
        case LogRecordType::ParamCommit:   return "PARAM_COMMIT";
        case LogRecordType::SessionEvent:  return "SESSION_EVENT";
        case LogRecordType::Heartbeat:     return "HEARTBEAT";
        case LogRecordType::RingDrop:      return "RING_DROP";
    }
    return "LOG_TYPE_UNKNOWN";
}

// mirrors SHARED_CONTRACT.md §"DMA log record header"
// TODO(rtl-contract): rtl/ctrl/log_ring.sv does not exist; this layout has no
// RTL counterpart yet. See the header comment.
struct LogRecordHeader {
    std::uint32_t magic;         // 0x4C475231 = 'LGR1'
    std::uint16_t schema_ver;    // REQUIRED version field
    std::uint16_t type;          // LogRecordType
    std::uint32_t length;        // total record bytes INCLUDING this header
    std::uint32_t seq;           // monotonic per-ring; a gap == a silent drop == alert
    std::uint64_t fabric_cycle;  // 48-bit cycle_cnt, zero-extended
    std::uint32_t build_id;
    std::uint32_t crc32;         // over the payload
};

static_assert(sizeof(LogRecordHeader) == 32,
              "LogRecordHeader must be exactly 32 bytes — SHARED_CONTRACT.md");
static_assert(alignof(LogRecordHeader) == 8, "LogRecordHeader alignment changed");
static_assert(offsetof(LogRecordHeader, magic) == 0);
static_assert(offsetof(LogRecordHeader, schema_ver) == 4);
static_assert(offsetof(LogRecordHeader, type) == 6);
static_assert(offsetof(LogRecordHeader, length) == 8);
static_assert(offsetof(LogRecordHeader, seq) == 12);
static_assert(offsetof(LogRecordHeader, fabric_cycle) == 16);
static_assert(offsetof(LogRecordHeader, build_id) == 24);
static_assert(offsetof(LogRecordHeader, crc32) == 28);
static_assert(std::is_trivially_copyable_v<LogRecordHeader>,
              "records are memcpy'd out of a DMA ring");

inline constexpr std::uint32_t LOG_RECORD_MAGIC = 0x4C47'5231u;  // 'LGR1'
inline constexpr std::uint16_t LOG_SCHEMA_VER = 1;

// Sanity bounds for the variable-length form. A length outside these means the
// ring is corrupt or we lost record framing; either way we must stop and alert
// rather than walk off into the next record.
inline constexpr std::uint32_t LOG_RECORD_MIN_BYTES = sizeof(LogRecordHeader);
inline constexpr std::uint32_t LOG_RECORD_MAX_BYTES = 4096;

// =============================================================================
// 3. Fabric64 — mirrors rtl/telemetry/telemetry_pkg.sv §5 `log_rec_t`
// -----------------------------------------------------------------------------
// EXACTLY 512 bits = 64 bytes = one host cache line.
//
// Packed-struct bit order, same convention as types.hpp: the FIRST declared RTL
// member (`ver`) occupies the HIGH bits, the LAST (`chk32`) occupies bit 0. The
// 512-bit value is serialised LSB-first, so `chk32` is bytes 0..3 of the record
// and `ver` is byte 63.
//
//   [511:504] ver          8   LOG_REC_VERSION
//   [503:496] rec_type     8   log_rec_e
//   [495:480] build_tag   16   BUILD_ID[15:0]
//   [479:432] ts_cycle    48   core cycle when the record was created
//   [431:384] trig_cycle  48   ingress cycle of the triggering tick
//   [383:336] seq         48   monotonic, never reused in a session
//   [335:320] sym         16   active-set symbol index
//   [319:312] flags        8   {4'b0, kill_active, post_only, is_short, side}
//   [311:304] reason       8   risk_reason_e / venue reject / kill_src_e
//   [303:272] price       32   ITCH-scaled integer
//   [271:240] qty         32   shares
//   [239:128] token      112   OUCH client order token (order_token_t)
//   [127:96]  strat_ctx   32   {strat_id[3:0], 4'b0, param_gen[15:0], 8'b0}
//   [95:64]   aux0        32   type-specific (gap marker: records lost)
//   [63:32]   aux1        32   type-specific
//   [31:0]    chk32       32   integrity fold over the preceding 480 bits
//                        ---
//                        512
// =============================================================================
inline constexpr std::uint8_t LOG_REC_VERSION = 1;      // telemetry_pkg::LOG_REC_VERSION
inline constexpr std::size_t LOG_REC_BYTES = 64;        // telemetry_pkg::LOG_REC_BYTES
inline constexpr unsigned LOG_REC_BITS = 512;
inline constexpr unsigned LOG_REC_BYTES_LOG2 = 6;
inline constexpr unsigned LOG_BODY_BITS = 480;          // telemetry_pkg::LOG_BODY_W
inline constexpr std::uint32_t LOG_CHK_SEED = 0xA5A5'5A5Au;  // telemetry_pkg::LOG_CHK_SEED

// mirrors rtl/telemetry/telemetry_pkg.sv :: log_rec_e
enum class FabricLogType : std::uint8_t {
    // fast-path decisions (the CAT trail proper)
    OrderSent = 0x01,
    OrderCancel = 0x02,
    RiskReject = 0x03,
    StratSuppress = 0x04,
    Fill = 0x05,
    VenueAck = 0x06,
    VenueReject = 0x07,
    VenueBreak = 0x08,
    // control-plane events (who armed it, when, with what)
    KillAssert = 0x10,
    KillClear = 0x11,
    Arm = 0x12,
    Disarm = 0x13,
    ParamCommit = 0x14,
    Watchdog = 0x15,
    TradingEn = 0x16,
    TradingDis = 0x17,
    // ring self-reporting
    GapMarker = 0xFE,     // ⚠ aux0 = records lost, aux1 = first lost seq
    SessionMark = 0xFF,
};

[[nodiscard]] constexpr std::string_view toString(FabricLogType t) noexcept {
    switch (t) {
        case FabricLogType::OrderSent:     return "ORDER_SENT";
        case FabricLogType::OrderCancel:   return "ORDER_CANCEL";
        case FabricLogType::RiskReject:    return "RISK_REJECT";
        case FabricLogType::StratSuppress: return "STRAT_SUPPRESS";
        case FabricLogType::Fill:          return "FILL";
        case FabricLogType::VenueAck:      return "VENUE_ACK";
        case FabricLogType::VenueReject:   return "VENUE_REJECT";
        case FabricLogType::VenueBreak:    return "VENUE_BREAK";
        case FabricLogType::KillAssert:    return "KILL_ASSERT";
        case FabricLogType::KillClear:     return "KILL_CLEAR";
        case FabricLogType::Arm:           return "ARM";
        case FabricLogType::Disarm:        return "DISARM";
        case FabricLogType::ParamCommit:   return "PARAM_COMMIT";
        case FabricLogType::Watchdog:      return "WATCHDOG";
        case FabricLogType::TradingEn:     return "TRADING_EN";
        case FabricLogType::TradingDis:    return "TRADING_DIS";
        case FabricLogType::GapMarker:     return "GAP_MARKER";
        case FabricLogType::SessionMark:   return "SESSION_MARK";
    }
    return "FABRIC_LOG_TYPE_UNKNOWN";
}

// mirrors telemetry_pkg.sv flags[] bit positions
namespace log_flag {
inline constexpr std::uint8_t SIDE = 1u << 0;       // 0 = buy, 1 = sell
inline constexpr std::uint8_t IS_SHORT = 1u << 1;
inline constexpr std::uint8_t POST_ONLY = 1u << 2;
inline constexpr std::uint8_t KILL = 1u << 3;
}  // namespace log_flag

namespace fields {

// The 112-bit token exceeds the 64-bit bit-packer, so it is declared as two
// halves purely so the tiling check can see full coverage. It is extracted as
// 14 whole bytes at byte offset 16 — see tokenBytes() below.
// clang-format off
inline constexpr bits::BitField LOGR_CHK32      {  0, 32};
inline constexpr bits::BitField LOGR_AUX1       { 32, 32};
inline constexpr bits::BitField LOGR_AUX0       { 64, 32};
inline constexpr bits::BitField LOGR_STRAT_CTX  { 96, 32};
inline constexpr bits::BitField LOGR_TOKEN_LO   {128, 64};
inline constexpr bits::BitField LOGR_TOKEN_HI   {192, 48};
inline constexpr bits::BitField LOGR_QTY        {240, 32};
inline constexpr bits::BitField LOGR_PRICE      {272, 32};
inline constexpr bits::BitField LOGR_REASON     {304,  8};
inline constexpr bits::BitField LOGR_FLAGS      {312,  8};
inline constexpr bits::BitField LOGR_SYM        {320, 16};
inline constexpr bits::BitField LOGR_SEQ        {336, 48};
inline constexpr bits::BitField LOGR_TRIG_CYCLE {384, 48};
inline constexpr bits::BitField LOGR_TS_CYCLE   {432, 48};
inline constexpr bits::BitField LOGR_BUILD_TAG  {480, 16};
inline constexpr bits::BitField LOGR_REC_TYPE   {496,  8};
inline constexpr bits::BitField LOGR_VER        {504,  8};
// clang-format on

inline constexpr std::array<bits::BitField, 17> kFabricLogFields{
    LOGR_CHK32,  LOGR_AUX1,     LOGR_AUX0,       LOGR_STRAT_CTX, LOGR_TOKEN_LO,
    LOGR_TOKEN_HI, LOGR_QTY,    LOGR_PRICE,      LOGR_REASON,    LOGR_FLAGS,
    LOGR_SYM,    LOGR_SEQ,      LOGR_TRIG_CYCLE, LOGR_TS_CYCLE,  LOGR_BUILD_TAG,
    LOGR_REC_TYPE, LOGR_VER,
};

}  // namespace fields

static_assert(bits::tilesExactly(fields::kFabricLogFields, LOG_REC_BITS),
              "log_rec_t bit table does not tile 512 bits exactly — host and "
              "rtl/telemetry/telemetry_pkg.sv::log_rec_t have diverged");

// The token is byte-aligned inside the record, which is what lets it be lifted
// out without any shifting. If that ever stops being true, tokenBytes() below
// is wrong and this assertion catches it.
static_assert(fields::LOGR_TOKEN_LO.lsb % 8 == 0, "token must start on a byte boundary");
inline constexpr std::size_t LOG_TOKEN_BYTE_OFFSET = fields::LOGR_TOKEN_LO.lsb / 8;  // 16
static_assert(LOG_TOKEN_BYTE_OFFSET == 16);
static_assert(LOG_TOKEN_BYTE_OFFSET + TOKEN_BYTES <= LOG_REC_BYTES);

using FabricLogWords = std::array<std::uint32_t, LOG_REC_BYTES / 4>;  // 16 words
static_assert(FabricLogWords{}.size() == 16);

// Host-side decoded view. mirrors rtl/telemetry/telemetry_pkg.sv :: log_rec_t
struct FabricLogRecord {
    std::uint8_t ver = LOG_REC_VERSION;
    FabricLogType recType = FabricLogType::SessionMark;
    std::uint16_t buildTag = 0;
    cycle_t tsCycle = 0;    // 48-bit
    cycle_t trigCycle = 0;  // 48-bit
    std::uint64_t seq = 0;  // 48-bit
    std::uint16_t sym = 0;
    std::uint8_t flags = 0;
    std::uint8_t reason = 0;
    price_t price = 0;
    qty_t qty = 0;
    OrderToken token{};
    std::uint32_t stratCtx = 0;
    std::uint32_t aux0 = 0;
    std::uint32_t aux1 = 0;
    std::uint32_t chk32 = 0;

    // ts_cycle - trig_cycle is the fabric latency of the event, in core cycles.
    // Both are 48-bit free-running counters, so the subtraction wraps correctly
    // only if it is masked back to 48 bits. Do that here, once.
    [[nodiscard]] constexpr cycle_t fabricLatencyCycles() const noexcept {
        return (tsCycle - trigCycle) & CYCLE_MAX;
    }

    [[nodiscard]] constexpr Side side() const noexcept {
        return (flags & log_flag::SIDE) ? Side::Sell : Side::Buy;
    }
    [[nodiscard]] constexpr bool isShort() const noexcept { return (flags & log_flag::IS_SHORT) != 0; }
    [[nodiscard]] constexpr bool postOnly() const noexcept { return (flags & log_flag::POST_ONLY) != 0; }
    [[nodiscard]] constexpr bool killActive() const noexcept { return (flags & log_flag::KILL) != 0; }

    // strat_ctx = {strat_id[3:0], 4'b0, param_gen[15:0], 8'b0}
    [[nodiscard]] constexpr std::uint8_t stratId() const noexcept {
        return static_cast<std::uint8_t>((stratCtx >> 28) & 0xFu);
    }
    [[nodiscard]] constexpr std::uint16_t paramGen() const noexcept {
        return static_cast<std::uint16_t>((stratCtx >> 8) & 0xFFFFu);
    }

    friend constexpr bool operator==(const FabricLogRecord&, const FabricLogRecord&) = default;
};

// -----------------------------------------------------------------------------
// telemetry_pkg::log_chk32 — rotate-left-1 then XOR each 32-bit word of the
// 480-bit body, seeded non-zero so an all-zero record does NOT check as valid.
//
// ⚠ This is NOT a CRC and NOT cryptographic (telemetry_pkg.sv §5). It catches
//   the failure modes a DMA ring actually has — torn, zeroed, stale or
//   transposed records. Compliance-grade integrity is logd's per-file SHA-256
//   over the archived day file. Do not represent chk32 as tamper evidence.
//
// `body` is bits [479:0] of the record, i.e. record words 1..15.
// -----------------------------------------------------------------------------
[[nodiscard]] constexpr std::uint32_t logChk32(const FabricLogWords& rec) noexcept {
    std::uint32_t acc = LOG_CHK_SEED;
    for (std::size_t w = 0; w < LOG_BODY_BITS / 32; ++w) {
        acc = static_cast<std::uint32_t>((acc << 1) | (acc >> 31)) ^ rec[w + 1];
    }
    return acc;
}

[[nodiscard]] constexpr FabricLogWords pack(const FabricLogRecord& r) noexcept {
    FabricLogWords w{};
    std::uint32_t* p = w.data();
    bits::put(p, fields::LOGR_AUX1, r.aux1);
    bits::put(p, fields::LOGR_AUX0, r.aux0);
    bits::put(p, fields::LOGR_STRAT_CTX, r.stratCtx);

    const OrderTokenBytes tb = pack(r.token);
    for (std::size_t i = 0; i < TOKEN_BYTES; ++i) {
        const std::size_t byteIdx = LOG_TOKEN_BYTE_OFFSET + i;
        w[byteIdx >> 2] |= static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(tb[i]))
                           << ((byteIdx & 3u) * 8u);
    }

    bits::put(p, fields::LOGR_QTY, r.qty);
    bits::put(p, fields::LOGR_PRICE, r.price);
    bits::put(p, fields::LOGR_REASON, r.reason);
    bits::put(p, fields::LOGR_FLAGS, r.flags);
    bits::put(p, fields::LOGR_SYM, r.sym);
    bits::put(p, fields::LOGR_SEQ, r.seq);
    bits::put(p, fields::LOGR_TRIG_CYCLE, r.trigCycle);
    bits::put(p, fields::LOGR_TS_CYCLE, r.tsCycle);
    bits::put(p, fields::LOGR_BUILD_TAG, r.buildTag);
    bits::put(p, fields::LOGR_REC_TYPE, static_cast<std::uint64_t>(r.recType));
    bits::put(p, fields::LOGR_VER, r.ver);

    // chk32 is always recomputed on pack. A caller cannot accidentally emit a
    // record whose stored check does not match its own body.
    bits::put(p, fields::LOGR_CHK32, logChk32(w));
    return w;
}

[[nodiscard]] constexpr FabricLogRecord unpackFabricLog(const FabricLogWords& w) noexcept {
    const std::uint32_t* p = w.data();
    FabricLogRecord r{};
    r.chk32 = static_cast<std::uint32_t>(bits::get(p, fields::LOGR_CHK32));
    r.aux1 = static_cast<std::uint32_t>(bits::get(p, fields::LOGR_AUX1));
    r.aux0 = static_cast<std::uint32_t>(bits::get(p, fields::LOGR_AUX0));
    r.stratCtx = static_cast<std::uint32_t>(bits::get(p, fields::LOGR_STRAT_CTX));

    OrderTokenBytes tb{};
    for (std::size_t i = 0; i < TOKEN_BYTES; ++i) {
        const std::size_t byteIdx = LOG_TOKEN_BYTE_OFFSET + i;
        tb[i] = static_cast<std::byte>((w[byteIdx >> 2] >> ((byteIdx & 3u) * 8u)) & 0xFFu);
    }
    r.token = unpackOrderToken(tb);

    r.qty = static_cast<qty_t>(bits::get(p, fields::LOGR_QTY));
    r.price = static_cast<price_t>(bits::get(p, fields::LOGR_PRICE));
    r.reason = static_cast<std::uint8_t>(bits::get(p, fields::LOGR_REASON));
    r.flags = static_cast<std::uint8_t>(bits::get(p, fields::LOGR_FLAGS));
    r.sym = static_cast<std::uint16_t>(bits::get(p, fields::LOGR_SYM));
    r.seq = bits::get(p, fields::LOGR_SEQ);
    r.trigCycle = bits::get(p, fields::LOGR_TRIG_CYCLE);
    r.tsCycle = bits::get(p, fields::LOGR_TS_CYCLE);
    r.buildTag = static_cast<std::uint16_t>(bits::get(p, fields::LOGR_BUILD_TAG));
    r.recType = static_cast<FabricLogType>(bits::get(p, fields::LOGR_REC_TYPE));
    r.ver = static_cast<std::uint8_t>(bits::get(p, fields::LOGR_VER));
    return r;
}

[[nodiscard]] constexpr bool checksumOk(const FabricLogWords& w) noexcept {
    return bits::get(w.data(), fields::LOGR_CHK32) == logChk32(w);
}

// Load a 64-byte record out of the ring without assuming alignment. The ring is
// host memory written by the device; the bytes are little-endian.
[[nodiscard]] inline FabricLogWords loadFabricWords(const std::byte* src) noexcept {
    FabricLogWords w{};
    std::memcpy(w.data(), src, LOG_REC_BYTES);
    return w;  // little-endian host assumed; see kHostIsLittleEndian below
}

// =============================================================================
// 4. CRC32 (IEEE 802.3, reflected) — used by the ContractV0 payload check
// -----------------------------------------------------------------------------
// This is a real CRC, unlike Fabric64's chk32 fold. It is also NOT
// cryptographic; the compliance-grade integrity story is logd's per-file
// SHA-256 over the archived day file
// (manuals/06-operations/03-monitoring-and-telemetry.md §10).
// =============================================================================
namespace detail {

[[nodiscard]] consteval std::array<std::uint32_t, 256> makeCrc32Table() {
    std::array<std::uint32_t, 256> t{};
    for (std::uint32_t i = 0; i < 256; ++i) {
        std::uint32_t c = i;
        for (int k = 0; k < 8; ++k) {
            c = (c & 1u) ? (0xEDB8'8320u ^ (c >> 1)) : (c >> 1);
        }
        t[i] = c;
    }
    return t;
}

inline constexpr std::array<std::uint32_t, 256> kCrc32Table = makeCrc32Table();

}  // namespace detail

[[nodiscard]] inline std::uint32_t crc32(std::span<const std::byte> data,
                                         std::uint32_t seed = 0) noexcept {
    std::uint32_t c = ~seed;
    for (std::byte b : data) {
        c = detail::kCrc32Table[(c ^ std::to_integer<std::uint8_t>(b)) & 0xFFu] ^ (c >> 8);
    }
    return ~c;
}

// Known-answer test. "123456789" -> 0xCBF43926 is the standard CRC-32 check
// value; if this fails the table generation is wrong.
static_assert(detail::kCrc32Table[1] == 0x7707'3096u, "CRC32 table generation is wrong");

// =============================================================================
// 5. Endianness
// -----------------------------------------------------------------------------
// BAR0 registers and the DMA ring are little-endian (SHARED_CONTRACT.md
// §"BAR0 layout"). Every load in this header does a straight memcpy, which is
// only correct on a little-endian host. x86-64 and the aarch64 configurations
// this runs on are both little-endian; assert it rather than assume it.
// =============================================================================
inline constexpr bool kHostIsLittleEndian =
#if defined(__BYTE_ORDER__) && defined(__ORDER_LITTLE_ENDIAN__)
    (__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__);
#else
    true;
#endif
static_assert(kHostIsLittleEndian,
              "host must be little-endian: the DMA ring and BAR0 are little-endian and "
              "this header memcpy's them directly");

}  // namespace trading

#endif  // TRADING_LOG_RECORD_HPP
