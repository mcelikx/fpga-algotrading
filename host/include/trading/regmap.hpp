// =============================================================================
// regmap.hpp — BAR0 register map. THE SINGLE SOURCE OF TRUTH IN HOST CODE.
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : device layer (agent 1). Included by every other host component.
//
// SOURCE OF THESE OFFSETS
//   rtl/ctrl/csr_regfile.sv DOES NOT EXIST YET. Everything in the IDENT,
//   CONTROL, PARAM, SESSION and LOGRING blocks below is DERIVED from the
//   `cfg_*` / `telem_*` ports of the u_host_ctrl instantiation in
//   rtl/fpga_top.sv (lines 483-538) and from
//   manuals/06-operations/03-monitoring-and-telemetry.md, as transcribed into
//   the master agent's SHARED_CONTRACT.md.
//
//   ⚠ EVERY OFFSET IN THOSE FIVE BLOCKS IS PROVISIONAL.
// TODO(rtl-contract): derived from fpga_top.sv cfg_* ports; reconcile with
// rtl/ctrl/csr_regfile.sv when that file lands.
//
//   The TELEMETRY block is DIFFERENT: rtl/telemetry/telemetry_pkg.sv EXISTS and
//   declares the telemetry word map normatively. Those offsets are therefore
//   RTL-derived, not provisional — and they DISAGREE with SHARED_CONTRACT.md.
//   See §6 below; the disagreement is documented, not hidden.
//
// NO OTHER HOST FILE MAY HARDCODE AN OFFSET. If you find yourself writing a
// hex literal into an MMIO call, the constant belongs here instead.
//
// -----------------------------------------------------------------------------
// ACCESS TYPES ARE COMPILE-TIME ENFORCED
//   Every register carries an Access tag. Device's typed accessors take a Reg
//   as a non-type template parameter and static_assert the direction, so
//
//       dev.write<regmap::CTRL_KILL_ACTIVE>(1);   // does not compile: RO
//       dev.read<regmap::CTRL_HEARTBEAT>();       // does not compile: WO
//
//   are build errors rather than a silent no-op against a read-only register on
//   a live card.
// =============================================================================
#ifndef TRADING_REGMAP_HPP
#define TRADING_REGMAP_HPP

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>

#include "trading/types.hpp"

namespace trading::regmap {

// =============================================================================
// 1. Access classification
// =============================================================================
enum class Access : std::uint8_t {
    RO,     // read-only. Writing is a bug the compiler catches.
    RW,     // read/write, and a read-back returns what was written -> verifiable
    WO,     // write-only. Reads are meaningless; usually a command/pulse.
    W1S,    // write-1-to-set, sticky. Not clearable by writing 0.
    RO_SE,  // read-only AND THE READ HAS A SIDE EFFECT. Never poll one of these.
};

[[nodiscard]] constexpr bool isWritable(Access a) noexcept {
    return a == Access::RW || a == Access::WO || a == Access::W1S;
}
[[nodiscard]] constexpr bool isReadable(Access a) noexcept {
    return a == Access::RO || a == Access::RW || a == Access::RO_SE;
}
// Only a plain RW register round-trips. writeVerify() is restricted to these:
// verifying a WO or W1S register would read garbage and "prove" a mismatch.
[[nodiscard]] constexpr bool isVerifiable(Access a) noexcept { return a == Access::RW; }
[[nodiscard]] constexpr bool hasReadSideEffect(Access a) noexcept { return a == Access::RO_SE; }

[[nodiscard]] constexpr std::string_view toString(Access a) noexcept {
    switch (a) {
        case Access::RO:    return "RO";
        case Access::RW:    return "RW";
        case Access::WO:    return "WO";
        case Access::W1S:   return "W1S";
        case Access::RO_SE: return "RO_SE";
    }
    return "??";
}

// A register. Structural type, so it can be a non-type template parameter and
// drive the compile-time access checks in device.hpp.
struct Reg {
    std::uint32_t offset;
    Access access;

    friend constexpr bool operator==(const Reg&, const Reg&) = default;
};

// =============================================================================
// 2. BAR0 geometry  (SHARED_CONTRACT.md §"BAR0 layout")
// -----------------------------------------------------------------------------
// 1 MiB, 32-bit registers, little-endian.
// =============================================================================
inline constexpr std::uint32_t BAR0_SIZE = 0x10'0000;  // 1 MiB

inline constexpr std::uint32_t IDENT_BASE   = 0x0'0000;
inline constexpr std::uint32_t CONTROL_BASE = 0x0'1000;
inline constexpr std::uint32_t PARAM_BASE   = 0x0'2000;
inline constexpr std::uint32_t SESSION_BASE = 0x0'3000;
inline constexpr std::uint32_t LOGRING_BASE = 0x0'4000;
inline constexpr std::uint32_t TELEM_BASE   = 0x8'0000;

inline constexpr std::uint32_t IDENT_SIZE   = 0x1000;
inline constexpr std::uint32_t CONTROL_SIZE = 0x1000;
inline constexpr std::uint32_t PARAM_SIZE   = 0x1000;
inline constexpr std::uint32_t SESSION_SIZE = 0x1000;
inline constexpr std::uint32_t LOGRING_SIZE = 0x1000;
inline constexpr std::uint32_t TELEM_SIZE   = 0x4'0000;  // 256 KiB RO shadow bank

inline constexpr std::uint32_t REG_STRIDE = 4;  // all registers are 32-bit

// Blocks are page-aligned, ordered, non-overlapping, and inside the BAR.
static_assert(IDENT_BASE % 0x1000 == 0 && CONTROL_BASE % 0x1000 == 0 &&
                  PARAM_BASE % 0x1000 == 0 && SESSION_BASE % 0x1000 == 0 &&
                  LOGRING_BASE % 0x1000 == 0 && TELEM_BASE % 0x1000 == 0,
              "every BAR0 block must be 4 KiB aligned");
static_assert(IDENT_BASE + IDENT_SIZE <= CONTROL_BASE, "IDENT overlaps CONTROL");
static_assert(CONTROL_BASE + CONTROL_SIZE <= PARAM_BASE, "CONTROL overlaps PARAM");
static_assert(PARAM_BASE + PARAM_SIZE <= SESSION_BASE, "PARAM overlaps SESSION");
static_assert(SESSION_BASE + SESSION_SIZE <= LOGRING_BASE, "SESSION overlaps LOGRING");
static_assert(LOGRING_BASE + LOGRING_SIZE <= TELEM_BASE, "LOGRING overlaps TELEMETRY");
static_assert(TELEM_BASE + TELEM_SIZE <= BAR0_SIZE, "TELEMETRY runs off the end of BAR0");

// =============================================================================
// 3. IDENT — read-only identity  (base 0x0_0000)
// -----------------------------------------------------------------------------
// The startup sequence begins here: step 1 is "verify BUILD_ID, refuse to
// proceed on mismatch" (host/README.md §3.1). A host talking to a bitstream it
// was not built against is the single easiest way to load a risk record into
// the wrong field offsets.
// =============================================================================
inline constexpr Reg IDENT_MAGIC        {IDENT_BASE + 0x000, Access::RO};
inline constexpr Reg IDENT_BUILD_ID     {IDENT_BASE + 0x004, Access::RO};  // fpga_top #BUILD_ID
inline constexpr Reg IDENT_GIT_SHA      {IDENT_BASE + 0x008, Access::RO};  // fpga_top #GIT_SHA
inline constexpr Reg IDENT_REGMAP_VER   {IDENT_BASE + 0x00C, Access::RO};  // (major<<16)|minor
inline constexpr Reg IDENT_CAPS         {IDENT_BASE + 0x010, Access::RO};
inline constexpr Reg IDENT_UPTIME_LO    {IDENT_BASE + 0x014, Access::RO};  // uptime_cycles[31:0]
inline constexpr Reg IDENT_UPTIME_HI    {IDENT_BASE + 0x018, Access::RO};  // uptime_cycles[47:32]
inline constexpr Reg IDENT_KILL_RESP_CYC{IDENT_BASE + 0x01C, Access::RO};  // #KILL_RESP_CYCLES

// 'FPGA' in ASCII, big-endian-read. Reading anything else means the BAR is not
// mapped, the device is in reset, or you are talking to the wrong function.
inline constexpr std::uint32_t IDENT_MAGIC_VALUE = 0x4650'4741u;

// IDENT_REGMAP_VER starts at 1.0. The host refuses to proceed on a MAJOR
// mismatch; a MINOR mismatch is additive and only warns.
inline constexpr std::uint16_t REGMAP_VER_MAJOR = 1;
inline constexpr std::uint16_t REGMAP_VER_MINOR = 0;
inline constexpr std::uint32_t REGMAP_VER_VALUE =
    (static_cast<std::uint32_t>(REGMAP_VER_MAJOR) << 16) | REGMAP_VER_MINOR;

[[nodiscard]] constexpr std::uint16_t regmapVerMajor(std::uint32_t v) noexcept {
    return static_cast<std::uint16_t>(v >> 16);
}
[[nodiscard]] constexpr std::uint16_t regmapVerMinor(std::uint32_t v) noexcept {
    return static_cast<std::uint16_t>(v & 0xFFFFu);
}

// IDENT_CAPS field layout:
//   [7:0]   log2(N_SYMBOLS)
//   [15:8]  log2(N_ACTIVE)
//   [23:16] log2(BOOK_LEVELS)   <- log2, not the raw value: 2048 does
//                                  not fit 8 bits. Consistent with the
//                                  two fields above, which are log2 too.
//   [31:24] N_RISK_REASONS
namespace caps {
inline constexpr unsigned LOG2_N_SYMBOLS_SHIFT = 0;
inline constexpr unsigned LOG2_N_ACTIVE_SHIFT = 8;
inline constexpr unsigned BOOK_LEVELS_SHIFT = 16;
inline constexpr unsigned N_RISK_REASONS_SHIFT = 24;
inline constexpr std::uint32_t FIELD_MASK = 0xFFu;

[[nodiscard]] constexpr std::uint32_t field(std::uint32_t caps, unsigned shift) noexcept {
    return (caps >> shift) & FIELD_MASK;
}
[[nodiscard]] constexpr std::uint32_t log2NSymbols(std::uint32_t c) noexcept {
    return field(c, LOG2_N_SYMBOLS_SHIFT);
}
[[nodiscard]] constexpr std::uint32_t log2NActive(std::uint32_t c) noexcept {
    return field(c, LOG2_N_ACTIVE_SHIFT);
}
[[nodiscard]] constexpr std::uint32_t bookLevels(std::uint32_t c) noexcept {
    return field(c, BOOK_LEVELS_SHIFT);
}
[[nodiscard]] constexpr std::uint32_t nRiskReasons(std::uint32_t c) noexcept {
    return field(c, N_RISK_REASONS_SHIFT);
}
}  // namespace caps

// The value this host build expects to read back from IDENT_CAPS. ctrld
// compares against this: if the fabric was built with a different N_ACTIVE, the
// PARAM address encoding in types.hpp is wrong and nothing else matters.
inline constexpr std::uint32_t IDENT_CAPS_EXPECTED =
    (static_cast<std::uint32_t>(SYM_IDX_W) << caps::LOG2_N_SYMBOLS_SHIFT) |
    (static_cast<std::uint32_t>(ACT_IDX_W) << caps::LOG2_N_ACTIVE_SHIFT) |
    (static_cast<std::uint32_t>(BOOK_LEVELS) << caps::BOOK_LEVELS_SHIFT) |
    (static_cast<std::uint32_t>(N_RISK_REASONS) << caps::N_RISK_REASONS_SHIFT);

static_assert(caps::log2NSymbols(IDENT_CAPS_EXPECTED) == SYM_IDX_W);
static_assert(caps::log2NActive(IDENT_CAPS_EXPECTED) == ACT_IDX_W);
static_assert(caps::bookLevels(IDENT_CAPS_EXPECTED) == BOOK_LEVELS);
static_assert(caps::nRiskReasons(IDENT_CAPS_EXPECTED) == N_RISK_REASONS);
static_assert(BOOK_LEVELS <= 0xFF && N_RISK_REASONS <= 0xFF,
              "IDENT_CAPS packs these into 8 bits each");

// mirrors fpga_top.sv parameter KILL_RESP_CYCLES = 4
inline constexpr std::uint32_t KILL_RESP_CYCLES_EXPECTED = 4;

// =============================================================================
// 4. CONTROL — arm / kill / heartbeat / watchdog  (base 0x0_1000)
// -----------------------------------------------------------------------------
// ctrld is the ONLY writer of this block (host/README.md §2).
// =============================================================================
inline constexpr Reg CTRL_TRADING_EN    {CONTROL_BASE + 0x000, Access::RW};   // bit0 -> cfg_trading_en
inline constexpr Reg CTRL_KILL          {CONTROL_BASE + 0x004, Access::W1S};  // bit0 -> cfg_kill
inline constexpr Reg CTRL_HEARTBEAT     {CONTROL_BASE + 0x008, Access::WO};   // monotonic u32 -> cfg_heartbeat
inline constexpr Reg CTRL_ARM_EXEC      {CONTROL_BASE + 0x00C, Access::WO};   // step 2 of the two-step arm
inline constexpr Reg CTRL_ARM_KEY       {CONTROL_BASE + 0x010, Access::WO};   // step 1: nonce
inline constexpr Reg CTRL_KILL_SRC      {CONTROL_BASE + 0x014, Access::RO};   // kill_src_e, latched sticky
inline constexpr Reg CTRL_KILL_ACTIVE   {CONTROL_BASE + 0x018, Access::RO};   // bit0
inline constexpr Reg CTRL_HEALTH        {CONTROL_BASE + 0x01C, Access::RO};   // see types.hpp namespace health
inline constexpr Reg CTRL_CREDIT_RETURN {CONTROL_BASE + 0x020, Access::WO};   // -> cfg_credit_return
inline constexpr Reg CTRL_WDOG_WARN_MS  {CONTROL_BASE + 0x024, Access::RW};
inline constexpr Reg CTRL_WDOG_BLOCK_MS {CONTROL_BASE + 0x028, Access::RW};
inline constexpr Reg CTRL_HB_AGE_MS     {CONTROL_BASE + 0x02C, Access::RO};   // fabric's view of host liveness
inline constexpr Reg CTRL_ARM_WINDOW_MS {CONTROL_BASE + 0x030, Access::RW};
inline constexpr Reg CTRL_ARMED         {CONTROL_BASE + 0x034, Access::RO};   // bit0

inline constexpr std::uint32_t CTRL_BIT0 = 1u;

// ⚠ CTRL_WDOG_BLOCK_MS: once the host heartbeat is this stale, the risk gate
// blocks ALL orders. That is host/README.md §3.4 ("losing the host must be
// safe") implemented in fabric. Do not raise it to work around a stalled
// heartbeat thread — fix the thread.
inline constexpr std::uint32_t CTRL_ARM_WINDOW_MS_DEFAULT = 5000;

// CTRL_KILL is write-1-to-set. Clearing it requires the CTRL_ARM_KEY nonce plus
// an explicit clear command — never implicitly, and never as a side effect of
// any other write. There is deliberately no CTRL_KILL_CLEAR constant here: kill
// clearing is a human-in-the-loop workflow (host/README.md §2), not an API.
inline constexpr std::uint32_t CTRL_KILL_SET = 1u;

// =============================================================================
// 5. PARAM — indirect parameter windows  (base 0x0_2000)
// -----------------------------------------------------------------------------
// The write protocol for every window is the same:
//   1. write *_ADDR
//   2. write *_DATA          (the write itself pulses cfg_*_wr in fabric)
//   3. read  *_RB and compare        <-- MANDATORY, host/README.md §3.1
//   4. when the whole record is in, write *_COMMIT with PARAM_COMMIT_MAGIC
//   5. read *_GEN and confirm it incremented, read *_CRC and compare
//
// paramd writes the INACTIVE bank only. *_ACTIVE_BANK tells you which one that
// is. See types.hpp::paramAddr() for the address encoding.
// =============================================================================
inline constexpr Reg PARAM_FILTER_ADDR      {PARAM_BASE + 0x000, Access::RW};  // raw ITCH locate 0..8191
inline constexpr Reg PARAM_FILTER_DATA      {PARAM_BASE + 0x004, Access::RW};  // pulses cfg_filter_wr
inline constexpr Reg PARAM_FILTER_RB        {PARAM_BASE + 0x008, Access::RO};

inline constexpr Reg PARAM_RISK_ADDR        {PARAM_BASE + 0x010, Access::RW};  // -> cfg_risk_addr
inline constexpr Reg PARAM_RISK_DATA        {PARAM_BASE + 0x014, Access::RW};  // pulses cfg_risk_wr
inline constexpr Reg PARAM_RISK_RB          {PARAM_BASE + 0x018, Access::RO};
inline constexpr Reg PARAM_RISK_COMMIT      {PARAM_BASE + 0x01C, Access::WO};  // -> cfg_risk_commit
inline constexpr Reg PARAM_RISK_GEN         {PARAM_BASE + 0x020, Access::RO};  // +1 per accepted commit
inline constexpr Reg PARAM_RISK_ACTIVE_BANK {PARAM_BASE + 0x024, Access::RO};  // bit0
inline constexpr Reg PARAM_RISK_CRC         {PARAM_BASE + 0x028, Access::RO};  // fabric CRC32 of the LIVE bank

inline constexpr Reg PARAM_STRAT_ADDR       {PARAM_BASE + 0x030, Access::RW};  // -> cfg_strat_addr
inline constexpr Reg PARAM_STRAT_DATA       {PARAM_BASE + 0x034, Access::RW};  // pulses cfg_strat_wr
inline constexpr Reg PARAM_STRAT_RB         {PARAM_BASE + 0x038, Access::RO};
inline constexpr Reg PARAM_STRAT_COMMIT     {PARAM_BASE + 0x03C, Access::WO};  // -> cfg_strat_commit
inline constexpr Reg PARAM_STRAT_GEN        {PARAM_BASE + 0x040, Access::RO};
inline constexpr Reg PARAM_STRAT_ACTIVE_BANK{PARAM_BASE + 0x044, Access::RO};
inline constexpr Reg PARAM_STRAT_CRC        {PARAM_BASE + 0x048, Access::RO};

// The commit doorbell. A specific non-trivial value so a stray zero or a
// wild write cannot swap a parameter bank under a live strategy.
inline constexpr std::uint32_t PARAM_COMMIT_MAGIC = 0x00C0'FFEEu;

// =============================================================================
// 6. SESSION — OUCH/Soup/TCP template + sequence  (base 0x0_3000)
// -----------------------------------------------------------------------------
// sessiond owns this block. NOTHING in here may be committed to the repo:
// comp IDs, session IDs and venue IPs go in a gitignored config file with a
// committed .example template (host/README.md §3.5).
// =============================================================================
inline constexpr Reg SESS_TMPL_ADDR  {SESSION_BASE + 0x000, Access::RW};  // -> cfg_tmpl_addr
inline constexpr Reg SESS_TMPL_DATA  {SESSION_BASE + 0x004, Access::RW};  // pulses cfg_tmpl_wr
inline constexpr Reg SESS_TMPL_RB    {SESSION_BASE + 0x008, Access::RO};
inline constexpr Reg SESS_TMPL_CRC   {SESSION_BASE + 0x00C, Access::RO};
inline constexpr Reg SESS_CTRL       {SESSION_BASE + 0x010, Access::RW};  // cfg_session_wr selector
inline constexpr Reg SESS_DATA       {SESSION_BASE + 0x014, Access::RW};  // -> cfg_session_data
inline constexpr Reg SESS_SEQ_TX_LO  {SESSION_BASE + 0x018, Access::RW};  // SoupBinTCP outbound seq, low 32
inline constexpr Reg SESS_SEQ_TX_HI  {SESSION_BASE + 0x01C, Access::RW};
inline constexpr Reg SESS_SEQ_RX_LO  {SESSION_BASE + 0x020, Access::RO};
inline constexpr Reg SESS_SEQ_RX_HI  {SESSION_BASE + 0x024, Access::RO};
inline constexpr Reg SESS_STATE      {SESSION_BASE + 0x028, Access::RO};  // trading::SessionState
inline constexpr Reg SESS_LINK_UP    {SESSION_BASE + 0x02C, Access::RO};

// SESS_LINK_UP bit assignment. Matches the fpga_top.sv telemetry concatenation
// {oe_link_up, md_link_up[1], md_link_up[0]}.
namespace link {
inline constexpr std::uint32_t OE = 1u << 0;    // order entry
inline constexpr std::uint32_t MD_A = 1u << 1;  // market data feed A
inline constexpr std::uint32_t MD_B = 1u << 2;  // market data feed B
inline constexpr std::uint32_t ALL = OE | MD_A | MD_B;
}  // namespace link

// Maximum words the template and session windows accept.
// mirrors rtl/telemetry/telemetry_pkg.sv::TMPL_WORDS_MAX / SESSION_WORDS_MAX
inline constexpr std::uint32_t SESS_TMPL_WORDS_MAX = RTL_TMPL_WORDS_MAX;      // 2048
inline constexpr std::uint32_t SESS_SESSION_WORDS_MAX = RTL_SESSION_WORDS_MAX;  // 32

// =============================================================================
// 7. LOGRING — DMA audit log, fabric -> host  (base 0x0_4000)
// -----------------------------------------------------------------------------
// logd owns CONS. Everything else here is fabric-owned.
//
// ⚠ LOG_RING_DROPS IS NEVER SILENT. Any increment is an alertable condition —
//   a dropped record is a hole in the CAT trail (CLAUDE.md §5.7). DmaLogRing
//   surfaces it as a latched alert the caller has to acknowledge; it cannot be
//   ignored by forgetting to check a return value.
// =============================================================================
inline constexpr Reg LOG_RING_BASE_LO    {LOGRING_BASE + 0x000, Access::RW};  // IOVA low 32
inline constexpr Reg LOG_RING_BASE_HI    {LOGRING_BASE + 0x004, Access::RW};  // IOVA high 32
inline constexpr Reg LOG_RING_SIZE       {LOGRING_BASE + 0x008, Access::RW};  // power of two, BYTES
inline constexpr Reg LOG_RING_PROD       {LOGRING_BASE + 0x00C, Access::RO};  // producer byte index
inline constexpr Reg LOG_RING_CONS       {LOGRING_BASE + 0x010, Access::RW};  // consumer byte index
inline constexpr Reg LOG_RING_DROPS      {LOGRING_BASE + 0x014, Access::RO};  // ⚠ alertable
inline constexpr Reg LOG_RING_ENABLE     {LOGRING_BASE + 0x018, Access::RW};  // bit0
inline constexpr Reg LOG_RING_IRQ_THRESH {LOGRING_BASE + 0x01C, Access::RW};

// Ring size bounds. mirrors rtl/telemetry/telemetry_pkg.sv §6 LOG_RING_LOG2_*,
// converted from records to bytes at LOG_REC_BYTES = 64.
//   LOG_RING_LOG2_MIN = 8  -> 256 records   = 16 KiB
//   LOG_RING_LOG2_DEF = 16 -> 64 K records  = 4 MiB
//   LOG_RING_LOG2_MAX = 22 -> 4 M records   = 256 MiB
inline constexpr std::uint32_t LOG_RING_BYTES_MIN = 16u * 1024u;
inline constexpr std::uint32_t LOG_RING_BYTES_DEF = 4u * 1024u * 1024u;
inline constexpr std::uint32_t LOG_RING_BYTES_MAX = 256u * 1024u * 1024u;

[[nodiscard]] constexpr bool logRingSizeValid(std::uint32_t bytes) noexcept {
    return bytes >= LOG_RING_BYTES_MIN && bytes <= LOG_RING_BYTES_MAX &&
           (bytes & (bytes - 1)) == 0;  // power of two: the wrap is a mask, never a modulo
}
static_assert(logRingSizeValid(LOG_RING_BYTES_MIN));
static_assert(logRingSizeValid(LOG_RING_BYTES_DEF));
static_assert(logRingSizeValid(LOG_RING_BYTES_MAX));
static_assert(!logRingSizeValid(LOG_RING_BYTES_DEF + 1), "non-power-of-two must be rejected");

// =============================================================================
// 8. TELEMETRY — RO shadow bank  (base 0x8_0000)
// -----------------------------------------------------------------------------
// ⚠⚠ THE ONLY BLOCK IN THIS FILE WITH A REAL RTL SOURCE, AND IT CONTRADICTS
//    SHARED_CONTRACT.md. rtl/telemetry/telemetry_pkg.sv EXISTS (the master
//    agent's brief said it did not) and §2 of that file declares the telemetry
//    word map normatively. THE RTL WINS. The offsets below are computed from
//    telemetry_pkg.sv's word indices, not from SHARED_CONTRACT.md's byte
//    offsets. See the report accompanying this change.
//
//    Concretely, SHARED_CONTRACT.md places the MAC counters at byte 0x80100
//    (word 0x40); telemetry_pkg.sv places them at word 0x10 (byte 0x80040).
//    Using the contract's numbers against real hardware would read the wrong
//    counters and report them confidently — the exact failure mode
//    manuals/06-operations/03-monitoring-and-telemetry.md exists to prevent.
//
//    The SHARED_CONTRACT.md *names* are preserved so metricsd compiles either
//    way; they now resolve to the RTL-correct addresses.
//
// ADDRESS TRANSFORM (both sources agree on this part):
//     byte_offset = TELEM_BASE + (word_index << 2)
//     word_index  = telem_raddr, the 16-bit port on u_telemetry in fpga_top.sv
// =============================================================================
[[nodiscard]] constexpr std::uint32_t telemByte(std::uint32_t wordIndex) noexcept {
    return TELEM_BASE + (wordIndex << 2);
}

// --- word indices, mirroring rtl/telemetry/telemetry_pkg.sv §2 --------------
namespace telem_word {
inline constexpr std::uint32_t STATUS     = 0x0000;  // LIVE, not snapshotted
inline constexpr std::uint32_t UPTIME_LO  = 0x0001;
inline constexpr std::uint32_t UPTIME_HI  = 0x0002;
inline constexpr std::uint32_t VERSION    = 0x0003;  // {MAGIC, MAJOR, MINOR}
inline constexpr std::uint32_t SNAP       = 0x0004;  // ⚠ READ HAS A SIDE EFFECT
inline constexpr std::uint32_t HIST_CLEAR = 0x0005;  // ⚠ READ HAS A SIDE EFFECT
inline constexpr std::uint32_t SNAP_SEQ   = 0x0006;
inline constexpr std::uint32_t LAT_CFG    = 0x0007;

inline constexpr std::uint32_t MD_MAC = 0x0010;  //  8 words: feed*4 + idx
inline constexpr std::uint32_t OE_MAC = 0x0018;  //  4 words
inline constexpr std::uint32_t NET    = 0x0020;  //  8 words
inline constexpr std::uint32_t FEED   = 0x0030;  // 16 words
inline constexpr std::uint32_t BOOK   = 0x0040;  // 16 words
inline constexpr std::uint32_t STRAT  = 0x0050;  // 16 words
inline constexpr std::uint32_t RISK   = 0x0060;  //  8 words
inline constexpr std::uint32_t REJECT = 0x0070;  // 24 words, index == risk_reason_e
inline constexpr std::uint32_t ORDER  = 0x0090;  // 16 words
inline constexpr std::uint32_t HIST   = 0x00C0;  // 32 words, latency buckets

inline constexpr std::uint32_t LAT_MIN    = 0x00E0;
inline constexpr std::uint32_t LAT_MAX    = 0x00E1;
inline constexpr std::uint32_t LAT_SUM_LO = 0x00E2;
inline constexpr std::uint32_t LAT_SUM_HI = 0x00E3;
inline constexpr std::uint32_t LAT_N      = 0x00E4;
inline constexpr std::uint32_t LAT_OVER   = 0x00E5;  // ⚠ samples above the top bucket
inline constexpr std::uint32_t LAT_LAST   = 0x00E6;

inline constexpr std::uint32_t LAST = 0x00FF;  // top of the map
inline constexpr std::uint32_t IDLE = 0xFFFF;  // CSR parking address
}  // namespace telem_word

// --- element counts, mirroring telemetry_pkg.sv TELEM_N_* -------------------
inline constexpr std::size_t TELEM_N_MD_MAC = 8;
inline constexpr std::size_t TELEM_N_OE_MAC = 4;
inline constexpr std::size_t TELEM_N_NET    = 8;
inline constexpr std::size_t TELEM_N_FEED   = 16;
inline constexpr std::size_t TELEM_N_BOOK   = 16;
inline constexpr std::size_t TELEM_N_STRAT  = 16;
inline constexpr std::size_t TELEM_N_RISK   = 8;
inline constexpr std::size_t TELEM_N_REJECT = N_RISK_REASONS;  // 24
inline constexpr std::size_t TELEM_N_ORDER  = 16;
inline constexpr std::size_t TELEM_N_HIST   = 32;  // telemetry_pkg::TELEM_HIST_MAX

// THE assertion the brief asks for by name: the reject-counter array is exactly
// N_RISK_REASONS long, matching rtl/pkg/trading_pkg.sv.
static_assert(TELEM_N_REJECT == 24, "reject counter array must be N_RISK_REASONS = 24");
static_assert(TELEM_N_REJECT == N_RISK_REASONS,
              "telemetry reject array length must equal trading_pkg::N_RISK_REASONS");

// Regions must not overlap, in word space.
static_assert(telem_word::MD_MAC + TELEM_N_MD_MAC <= telem_word::OE_MAC, "MD_MAC overruns OE_MAC");
static_assert(telem_word::OE_MAC + TELEM_N_OE_MAC <= telem_word::NET, "OE_MAC overruns NET");
static_assert(telem_word::NET + TELEM_N_NET <= telem_word::FEED, "NET overruns FEED");
static_assert(telem_word::FEED + TELEM_N_FEED <= telem_word::BOOK, "FEED overruns BOOK");
static_assert(telem_word::BOOK + TELEM_N_BOOK <= telem_word::STRAT, "BOOK overruns STRAT");
static_assert(telem_word::STRAT + TELEM_N_STRAT <= telem_word::RISK, "STRAT overruns RISK");
static_assert(telem_word::RISK + TELEM_N_RISK <= telem_word::REJECT, "RISK overruns REJECT");
static_assert(telem_word::REJECT + TELEM_N_REJECT <= telem_word::ORDER, "REJECT overruns ORDER");
static_assert(telem_word::ORDER + TELEM_N_ORDER <= telem_word::HIST, "ORDER overruns HIST");
static_assert(telem_word::HIST + TELEM_N_HIST <= telem_word::LAT_MIN, "HIST overruns LAT_MIN");
static_assert(telemByte(telem_word::LAST) < TELEM_BASE + TELEM_SIZE,
              "telemetry map runs off the end of the telemetry window");

// --- byte-offset registers. The SHARED_CONTRACT.md names, RTL-correct values --
inline constexpr Reg TELEM_STATUS      {telemByte(telem_word::STATUS), Access::RO};
inline constexpr Reg TELEM_UPTIME_LO   {telemByte(telem_word::UPTIME_LO), Access::RO};
inline constexpr Reg TELEM_UPTIME_HI   {telemByte(telem_word::UPTIME_HI), Access::RO};
inline constexpr Reg TELEM_VERSION     {telemByte(telem_word::VERSION), Access::RO};
// ⚠ RO_SE: reading TELEM_SNAPSHOT LATCHES the whole shadow bank and returns the
//   new sequence number. SHARED_CONTRACT.md modelled this as a write-1-to-latch
//   register; telemetry_pkg.sv §2 says it is a read side effect. NEVER poll it.
inline constexpr Reg TELEM_SNAPSHOT    {telemByte(telem_word::SNAP), Access::RO_SE};
// ⚠ RO_SE: reading this ZEROES the latency histogram. Start-of-day only.
inline constexpr Reg TELEM_HIST_CLEAR  {telemByte(telem_word::HIST_CLEAR), Access::RO_SE};
inline constexpr Reg TELEM_SNAPSHOT_SEQ{telemByte(telem_word::SNAP_SEQ), Access::RO};
inline constexpr Reg TELEM_LAT_CFG     {telemByte(telem_word::LAT_CFG), Access::RO};

inline constexpr Reg TELEM_MAC    {telemByte(telem_word::MD_MAC), Access::RO};  // 8 md + 4 oe
inline constexpr Reg TELEM_OE_MAC {telemByte(telem_word::OE_MAC), Access::RO};
inline constexpr Reg TELEM_NET    {telemByte(telem_word::NET), Access::RO};
inline constexpr Reg TELEM_FEED   {telemByte(telem_word::FEED), Access::RO};
inline constexpr Reg TELEM_BOOK   {telemByte(telem_word::BOOK), Access::RO};
inline constexpr Reg TELEM_STRAT  {telemByte(telem_word::STRAT), Access::RO};
inline constexpr Reg TELEM_RISK   {telemByte(telem_word::RISK), Access::RO};
inline constexpr Reg TELEM_REJECT {telemByte(telem_word::REJECT), Access::RO};
inline constexpr Reg TELEM_ORDER  {telemByte(telem_word::ORDER), Access::RO};
inline constexpr Reg TELEM_HIST   {telemByte(telem_word::HIST), Access::RO};
// SHARED_CONTRACT.md's "TELEM_LIVE — health/link/kill/die_temp live values" is
// telemetry_pkg.sv's STATUS word: the one word that is LIVE, not snapshotted,
// and therefore atomic on its own.
inline constexpr Reg TELEM_LIVE {telemByte(telem_word::STATUS), Access::RO};

inline constexpr Reg TELEM_LAT_MIN    {telemByte(telem_word::LAT_MIN), Access::RO};
inline constexpr Reg TELEM_LAT_MAX    {telemByte(telem_word::LAT_MAX), Access::RO};
inline constexpr Reg TELEM_LAT_SUM_LO {telemByte(telem_word::LAT_SUM_LO), Access::RO};
inline constexpr Reg TELEM_LAT_SUM_HI {telemByte(telem_word::LAT_SUM_HI), Access::RO};
inline constexpr Reg TELEM_LAT_N      {telemByte(telem_word::LAT_N), Access::RO};
inline constexpr Reg TELEM_LAT_OVER   {telemByte(telem_word::LAT_OVER), Access::RO};
inline constexpr Reg TELEM_LAT_LAST   {telemByte(telem_word::LAT_LAST), Access::RO};

// Indexed accessors. Bounds are checked at compile time where the index is a
// constant, and at runtime by Device::readBlock otherwise.
[[nodiscard]] constexpr std::uint32_t telemRejectOffset(std::size_t reason) noexcept {
    return telemByte(telem_word::REJECT + static_cast<std::uint32_t>(reason));
}
[[nodiscard]] constexpr std::uint32_t telemRejectOffset(RiskReason r) noexcept {
    return telemRejectOffset(static_cast<std::size_t>(r));
}
[[nodiscard]] constexpr std::uint32_t telemHistBucketOffset(std::size_t bucket) noexcept {
    return telemByte(telem_word::HIST + static_cast<std::uint32_t>(bucket));
}
static_assert(telemRejectOffset(RiskReason::ParamInvalid) ==
                  telemByte(telem_word::REJECT + N_RISK_REASONS - 1),
              "reject index arithmetic is wrong");

// --- telemetry map identity, mirroring telemetry_pkg.sv §1 ------------------
inline constexpr std::uint16_t TELEM_MAP_MAGIC = 0x4654;  // "FT" — fabric trading
inline constexpr std::uint8_t TELEM_MAP_MAJOR = 1;
inline constexpr std::uint8_t TELEM_MAP_MINOR = 0;
// TELEM_VERSION reads back {MAGIC[15:0], MAJOR[7:0], MINOR[7:0]}.
inline constexpr std::uint32_t TELEM_VERSION_VALUE =
    (static_cast<std::uint32_t>(TELEM_MAP_MAGIC) << 16) |
    (static_cast<std::uint32_t>(TELEM_MAP_MAJOR) << 8) | TELEM_MAP_MINOR;

// Returned for an address outside the map. Chosen so a host reading the wrong
// window sees it immediately instead of seeing a plausible zero.
// mirrors telemetry_pkg::TELEM_UNMAPPED
inline constexpr std::uint32_t TELEM_UNMAPPED = 0xDEAD'C0DEu;

// --- STATUS word bit layout, mirroring telemetry_pkg.sv §2 ------------------
namespace telem_status {
inline constexpr unsigned LINK_LSB = 0;      // [2:0] {oe, md_b, md_a}
inline constexpr unsigned KILL_ACTIVE = 3;
inline constexpr unsigned KILL_SRC_LSB = 4;  // [6:4] kill_src_e
inline constexpr unsigned LAT_SAT = 7;       // ⚠ histogram counters saturated
inline constexpr unsigned LAT_OVER_NZ = 8;   // ⚠ a sample landed above the top bucket

[[nodiscard]] constexpr std::uint32_t linkMask(std::uint32_t s) noexcept {
    return (s >> LINK_LSB) & 0x7u;
}
[[nodiscard]] constexpr bool killActive(std::uint32_t s) noexcept {
    return ((s >> KILL_ACTIVE) & 1u) != 0;
}
[[nodiscard]] constexpr KillSrc killSrc(std::uint32_t s) noexcept {
    return static_cast<KillSrc>((s >> KILL_SRC_LSB) & 0x7u);
}
[[nodiscard]] constexpr bool latSaturated(std::uint32_t s) noexcept {
    return ((s >> LAT_SAT) & 1u) != 0;
}
[[nodiscard]] constexpr bool latOverflowed(std::uint32_t s) noexcept {
    return ((s >> LAT_OVER_NZ) & 1u) != 0;
}
}  // namespace telem_status

// --- latency histogram geometry ---------------------------------------------
// SHARED_CONTRACT.md §TELEMETRY and manuals/06-operations/03-*.md §3:
// linear below (N_BUCKETS/2) << LIN_STEP_W = 16 << 3 = 128 cycles, 8 cycles per
// bucket; log2 above that; the top bucket saturates.
inline constexpr std::uint32_t HIST_N_BUCKETS = 32;
inline constexpr std::uint32_t HIST_LIN_STEP_W = 3;                       // 8 cycles/bucket
inline constexpr std::uint32_t HIST_LIN_BUCKETS = HIST_N_BUCKETS / 2;     // 16
inline constexpr std::uint32_t HIST_LIN_MAX_CYCLES = HIST_LIN_BUCKETS << HIST_LIN_STEP_W;  // 128
static_assert(HIST_N_BUCKETS == TELEM_N_HIST, "histogram bucket count mismatch");
static_assert(HIST_LIN_MAX_CYCLES == 128, "linear/log crossover must be 128 cycles");

// Upper edge of bucket k, in CYCLES. Linear below the crossover, log2 above.
// Integer arithmetic only; convert to ns with trading::cyclesToNs().
[[nodiscard]] constexpr std::uint64_t histBucketUpperCycles(std::uint32_t k) noexcept {
    if (k < HIST_LIN_BUCKETS) {
        return static_cast<std::uint64_t>(k + 1) << HIST_LIN_STEP_W;
    }
    // Above the crossover each bucket doubles. Bucket HIST_LIN_BUCKETS covers
    // (128, 256], the next (256, 512], and so on. The top bucket saturates.
    const std::uint32_t over = k - HIST_LIN_BUCKETS;
    if (over >= 40) return ~std::uint64_t{0};  // guard against a silly index
    return static_cast<std::uint64_t>(HIST_LIN_MAX_CYCLES) << (over + 1);
}
static_assert(histBucketUpperCycles(0) == 8);
static_assert(histBucketUpperCycles(15) == 128);
static_assert(histBucketUpperCycles(16) == 256);

// -----------------------------------------------------------------------------
// SHARED_CONTRACT.md's 7-histogram layout (hist_wire_to_wire, hist_decode,
// hist_book, hist_trigger, hist_risk_encode, hist_ack_rtt, hist_interarrival at
// byte 0x81000, stride 0x100) IS NOT IMPLEMENTED IN RTL. rtl/telemetry has ONE
// latency histogram (u_telemetry in fpga_top.sv takes a single lat_valid /
// lat_start pair, sampled when an order leaves). metricsd must expose one
// histogram — wire-to-wire — and must NOT synthesise the other six.
//
// The constants are recorded here, unused and clearly marked, so nobody
// re-derives them from the contract document and believes they work.
// TODO(rtl-contract): if per-stage histograms are wanted, that is an RTL change
// to rtl/telemetry/telemetry.sv, not a host change.
// -----------------------------------------------------------------------------
namespace unimplemented_contract_v0 {
inline constexpr std::uint32_t MULTI_HIST_BASE = 0x8'1000;
inline constexpr std::uint32_t MULTI_HIST_STRIDE = 0x100;
inline constexpr std::size_t MULTI_HIST_COUNT = 7;
inline constexpr bool IMPLEMENTED_IN_RTL = false;
}  // namespace unimplemented_contract_v0

// =============================================================================
// 9. Whole-map validation
// -----------------------------------------------------------------------------
// One descriptor table, checked once at compile time for the three mistakes a
// hand-maintained register map actually makes: an unaligned offset, an offset
// that fell outside its block, and two registers accidentally sharing an
// address. All three are silent at runtime.
// =============================================================================
struct RegDesc {
    Reg reg;
    std::uint32_t blockBase;
    std::uint32_t blockSize;
    std::string_view name;
};

// clang-format off
// The explicit size is itself a check: adding a register without updating it is
// a compile error, which is the prompt to also add it to the block below.
inline constexpr std::array<RegDesc, 59> kAllRegisters{{
    {IDENT_MAGIC,             IDENT_BASE,   IDENT_SIZE,   "IDENT_MAGIC"},
    {IDENT_BUILD_ID,          IDENT_BASE,   IDENT_SIZE,   "IDENT_BUILD_ID"},
    {IDENT_GIT_SHA,           IDENT_BASE,   IDENT_SIZE,   "IDENT_GIT_SHA"},
    {IDENT_REGMAP_VER,        IDENT_BASE,   IDENT_SIZE,   "IDENT_REGMAP_VER"},
    {IDENT_CAPS,              IDENT_BASE,   IDENT_SIZE,   "IDENT_CAPS"},
    {IDENT_UPTIME_LO,         IDENT_BASE,   IDENT_SIZE,   "IDENT_UPTIME_LO"},
    {IDENT_UPTIME_HI,         IDENT_BASE,   IDENT_SIZE,   "IDENT_UPTIME_HI"},
    {IDENT_KILL_RESP_CYC,     IDENT_BASE,   IDENT_SIZE,   "IDENT_KILL_RESP_CYC"},

    {CTRL_TRADING_EN,         CONTROL_BASE, CONTROL_SIZE, "CTRL_TRADING_EN"},
    {CTRL_KILL,               CONTROL_BASE, CONTROL_SIZE, "CTRL_KILL"},
    {CTRL_HEARTBEAT,          CONTROL_BASE, CONTROL_SIZE, "CTRL_HEARTBEAT"},
    {CTRL_ARM_EXEC,           CONTROL_BASE, CONTROL_SIZE, "CTRL_ARM_EXEC"},
    {CTRL_ARM_KEY,            CONTROL_BASE, CONTROL_SIZE, "CTRL_ARM_KEY"},
    {CTRL_KILL_SRC,           CONTROL_BASE, CONTROL_SIZE, "CTRL_KILL_SRC"},
    {CTRL_KILL_ACTIVE,        CONTROL_BASE, CONTROL_SIZE, "CTRL_KILL_ACTIVE"},
    {CTRL_HEALTH,             CONTROL_BASE, CONTROL_SIZE, "CTRL_HEALTH"},
    {CTRL_CREDIT_RETURN,      CONTROL_BASE, CONTROL_SIZE, "CTRL_CREDIT_RETURN"},
    {CTRL_WDOG_WARN_MS,       CONTROL_BASE, CONTROL_SIZE, "CTRL_WDOG_WARN_MS"},
    {CTRL_WDOG_BLOCK_MS,      CONTROL_BASE, CONTROL_SIZE, "CTRL_WDOG_BLOCK_MS"},
    {CTRL_HB_AGE_MS,          CONTROL_BASE, CONTROL_SIZE, "CTRL_HB_AGE_MS"},
    {CTRL_ARM_WINDOW_MS,      CONTROL_BASE, CONTROL_SIZE, "CTRL_ARM_WINDOW_MS"},
    {CTRL_ARMED,              CONTROL_BASE, CONTROL_SIZE, "CTRL_ARMED"},

    {PARAM_FILTER_ADDR,       PARAM_BASE,   PARAM_SIZE,   "PARAM_FILTER_ADDR"},
    {PARAM_FILTER_DATA,       PARAM_BASE,   PARAM_SIZE,   "PARAM_FILTER_DATA"},
    {PARAM_FILTER_RB,         PARAM_BASE,   PARAM_SIZE,   "PARAM_FILTER_RB"},
    {PARAM_RISK_ADDR,         PARAM_BASE,   PARAM_SIZE,   "PARAM_RISK_ADDR"},
    {PARAM_RISK_DATA,         PARAM_BASE,   PARAM_SIZE,   "PARAM_RISK_DATA"},
    {PARAM_RISK_RB,           PARAM_BASE,   PARAM_SIZE,   "PARAM_RISK_RB"},
    {PARAM_RISK_COMMIT,       PARAM_BASE,   PARAM_SIZE,   "PARAM_RISK_COMMIT"},
    {PARAM_RISK_GEN,          PARAM_BASE,   PARAM_SIZE,   "PARAM_RISK_GEN"},
    {PARAM_RISK_ACTIVE_BANK,  PARAM_BASE,   PARAM_SIZE,   "PARAM_RISK_ACTIVE_BANK"},
    {PARAM_RISK_CRC,          PARAM_BASE,   PARAM_SIZE,   "PARAM_RISK_CRC"},
    {PARAM_STRAT_ADDR,        PARAM_BASE,   PARAM_SIZE,   "PARAM_STRAT_ADDR"},
    {PARAM_STRAT_DATA,        PARAM_BASE,   PARAM_SIZE,   "PARAM_STRAT_DATA"},
    {PARAM_STRAT_RB,          PARAM_BASE,   PARAM_SIZE,   "PARAM_STRAT_RB"},
    {PARAM_STRAT_COMMIT,      PARAM_BASE,   PARAM_SIZE,   "PARAM_STRAT_COMMIT"},
    {PARAM_STRAT_GEN,         PARAM_BASE,   PARAM_SIZE,   "PARAM_STRAT_GEN"},
    {PARAM_STRAT_ACTIVE_BANK, PARAM_BASE,   PARAM_SIZE,   "PARAM_STRAT_ACTIVE_BANK"},
    {PARAM_STRAT_CRC,         PARAM_BASE,   PARAM_SIZE,   "PARAM_STRAT_CRC"},

    {SESS_TMPL_ADDR,          SESSION_BASE, SESSION_SIZE, "SESS_TMPL_ADDR"},
    {SESS_TMPL_DATA,          SESSION_BASE, SESSION_SIZE, "SESS_TMPL_DATA"},
    {SESS_TMPL_RB,            SESSION_BASE, SESSION_SIZE, "SESS_TMPL_RB"},
    {SESS_TMPL_CRC,           SESSION_BASE, SESSION_SIZE, "SESS_TMPL_CRC"},
    {SESS_CTRL,               SESSION_BASE, SESSION_SIZE, "SESS_CTRL"},
    {SESS_DATA,               SESSION_BASE, SESSION_SIZE, "SESS_DATA"},
    {SESS_SEQ_TX_LO,          SESSION_BASE, SESSION_SIZE, "SESS_SEQ_TX_LO"},
    {SESS_SEQ_TX_HI,          SESSION_BASE, SESSION_SIZE, "SESS_SEQ_TX_HI"},
    {SESS_SEQ_RX_LO,          SESSION_BASE, SESSION_SIZE, "SESS_SEQ_RX_LO"},
    {SESS_SEQ_RX_HI,          SESSION_BASE, SESSION_SIZE, "SESS_SEQ_RX_HI"},
    {SESS_STATE,              SESSION_BASE, SESSION_SIZE, "SESS_STATE"},
    {SESS_LINK_UP,            SESSION_BASE, SESSION_SIZE, "SESS_LINK_UP"},

    {LOG_RING_BASE_LO,        LOGRING_BASE, LOGRING_SIZE, "LOG_RING_BASE_LO"},
    {LOG_RING_BASE_HI,        LOGRING_BASE, LOGRING_SIZE, "LOG_RING_BASE_HI"},
    {LOG_RING_SIZE,           LOGRING_BASE, LOGRING_SIZE, "LOG_RING_SIZE"},
    {LOG_RING_PROD,           LOGRING_BASE, LOGRING_SIZE, "LOG_RING_PROD"},
    {LOG_RING_CONS,           LOGRING_BASE, LOGRING_SIZE, "LOG_RING_CONS"},
    {LOG_RING_DROPS,          LOGRING_BASE, LOGRING_SIZE, "LOG_RING_DROPS"},
    {LOG_RING_ENABLE,         LOGRING_BASE, LOGRING_SIZE, "LOG_RING_ENABLE"},
    {LOG_RING_IRQ_THRESH,     LOGRING_BASE, LOGRING_SIZE, "LOG_RING_IRQ_THRESH"},
}};
// clang-format on

namespace detail {

[[nodiscard]] consteval bool allAligned() {
    for (const auto& d : kAllRegisters) {
        if (d.reg.offset % REG_STRIDE != 0) return false;
    }
    return true;
}

[[nodiscard]] consteval bool allInBlock() {
    for (const auto& d : kAllRegisters) {
        if (d.reg.offset < d.blockBase) return false;
        if (d.reg.offset + REG_STRIDE > d.blockBase + d.blockSize) return false;
    }
    return true;
}

[[nodiscard]] consteval bool allInBar() {
    for (const auto& d : kAllRegisters) {
        if (d.reg.offset + REG_STRIDE > BAR0_SIZE) return false;
    }
    return true;
}

[[nodiscard]] consteval bool allOffsetsUnique() {
    for (std::size_t i = 0; i < kAllRegisters.size(); ++i) {
        for (std::size_t j = i + 1; j < kAllRegisters.size(); ++j) {
            if (kAllRegisters[i].reg.offset == kAllRegisters[j].reg.offset) return false;
        }
    }
    return true;
}

// A register may not be simultaneously unreadable and unwritable: that is a
// transcription slip, not a design.
[[nodiscard]] consteval bool allAccessible() {
    for (const auto& d : kAllRegisters) {
        if (!isReadable(d.reg.access) && !isWritable(d.reg.access)) return false;
    }
    return true;
}

}  // namespace detail

static_assert(detail::allAligned(), "a register offset is not 4-byte aligned");
static_assert(detail::allInBlock(), "a register offset falls outside its declared block");
static_assert(detail::allInBar(), "a register offset falls outside BAR0");
static_assert(detail::allOffsetsUnique(), "two registers share an offset");
static_assert(detail::allAccessible(), "a register is neither readable nor writable");

// Spot checks that pin the literal values from SHARED_CONTRACT.md. If someone
// renumbers a block, these fail before anything reaches hardware.
static_assert(IDENT_MAGIC.offset == 0x0000);
static_assert(CTRL_TRADING_EN.offset == 0x1000);
static_assert(CTRL_ARMED.offset == 0x1034);
static_assert(PARAM_FILTER_ADDR.offset == 0x2000);
static_assert(PARAM_STRAT_CRC.offset == 0x2048);
static_assert(SESS_TMPL_ADDR.offset == 0x3000);
static_assert(SESS_LINK_UP.offset == 0x302C);
static_assert(LOG_RING_BASE_LO.offset == 0x4000);
static_assert(LOG_RING_IRQ_THRESH.offset == 0x401C);
static_assert(TELEM_BASE == 0x8'0000);

// Runtime lookup, for tooling and error messages. Linear scan over 55 entries
// on a diagnostic path — do not use it in a loop over the telemetry bank.
[[nodiscard]] constexpr std::string_view nameOf(std::uint32_t offset) noexcept {
    for (const auto& d : kAllRegisters) {
        if (d.reg.offset == offset) return d.name;
    }
    return "<unnamed>";
}

[[nodiscard]] constexpr bool offsetInBar(std::uint32_t offset) noexcept {
    return offset % REG_STRIDE == 0 && offset + REG_STRIDE <= BAR0_SIZE;
}

[[nodiscard]] constexpr bool isTelemetryOffset(std::uint32_t offset) noexcept {
    return offset >= TELEM_BASE && offset < TELEM_BASE + TELEM_SIZE;
}

// Runtime access lookup, so Device::write32() can refuse a write to a read-only
// register even when the caller passed a raw offset rather than using the
// typed accessors. The typed path catches it at compile time; this is the net
// under the code that could not use it (a loop over a computed offset, a
// tool driven by a config file).
//
// `known` is false for the telemetry window and for any offset not in the
// table; isTelemetryOffset() covers the former, which is RO in its entirety.
struct AccessLookup {
    bool known;
    Access access;
};

[[nodiscard]] constexpr AccessLookup accessOf(std::uint32_t offset) noexcept {
    for (const auto& d : kAllRegisters) {
        if (d.reg.offset == offset) return {true, d.reg.access};
    }
    if (isTelemetryOffset(offset)) return {true, Access::RO};
    return {false, Access::RW};
}

static_assert(accessOf(CTRL_KILL_ACTIVE.offset).known &&
                  accessOf(CTRL_KILL_ACTIVE.offset).access == Access::RO,
              "accessOf lookup is broken");
static_assert(accessOf(TELEM_FEED.offset).known &&
                  accessOf(TELEM_FEED.offset).access == Access::RO,
              "the whole telemetry window is read-only");

}  // namespace trading::regmap

#endif  // TRADING_REGMAP_HPP
