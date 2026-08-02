// =============================================================================
// paramd/param_window.hpp — the two indirect parameter windows, and the failure
//                           vocabulary shared by everything that drives them
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : paramd (the parameter engine)
// Mirrors : rtl/pkg/trading_pkg.sv  (sym_risk_t = 324b, sym_strat_t = 149b)
//           rtl/fpga_top.sv         (cfg_risk_* / cfg_strat_* ports)
//
// WHY A "WINDOW" TYPE AT ALL
//   The risk window and the strategy window have identical shapes and different
//   consequences. Writing a risk record and then ringing the STRATEGY commit
//   doorbell is a single-character mistake that leaves risk limits in a shadow
//   bank forever while the strategy bank flips under a live book. Bundling the
//   seven registers of one domain into one immutable descriptor makes that
//   mistake unrepresentable: every low-level operation takes exactly one
//   ParamWindow and can only touch the registers inside it.
//
//   It is ALSO the reason paramd never offers "commit both". host/README.md §3.3
//   and manual 08/09 §9 ("⚠ Never bundled") require a risk-limit change to be a
//   separate change with a separate audit entry. Two windows, two code paths,
//   two audit record types, two files on disk.
// =============================================================================
#ifndef TRADING_PARAMD_PARAM_WINDOW_HPP
#define TRADING_PARAMD_PARAM_WINDOW_HPP

#include <cstddef>
#include <cstdint>
#include <string_view>

#include "trading/regmap.hpp"
#include "trading/types.hpp"

namespace trading::paramd {

// =============================================================================
// 1. Domain
// =============================================================================
enum class ParamDomain : std::uint8_t {
    RiskLimits = 0,      // sym_risk_t. Governed. Four-eyes. Dry-run by default.
    StrategyParams = 1,  // sym_strat_t. Recomputed at ms cadence.
};

[[nodiscard]] constexpr std::string_view toString(ParamDomain d) noexcept {
    return d == ParamDomain::RiskLimits ? "RISK_LIMITS" : "STRATEGY_PARAMS";
}

// =============================================================================
// 2. The window descriptor
// -----------------------------------------------------------------------------
// SHARED_CONTRACT.md §PARAM / regmap.hpp §5. The protocol per word is:
//     writeVerify(ADDR, paramAddr(bank, sym, word));   // RW, round-trips
//     write32   (DATA, value);                          // the write pulses cfg_*_wr
//     ... later ...
//     writeVerify(ADDR, same);  read32(RB);  compare.   // MANDATORY read-back
// and per bank:
//     write32(COMMIT, PARAM_COMMIT_MAGIC); then GEN must +1 and ACTIVE_BANK must flip.
// =============================================================================
struct ParamWindow {
    ParamDomain domain;
    std::string_view name;

    regmap::Reg addr;        // RW  -> cfg_*_addr
    regmap::Reg data;        // RW  -> cfg_*_data; the write pulses cfg_*_wr
    regmap::Reg rb;          // RO  read-back of the word currently addressed
    regmap::Reg commit;      // WO  write PARAM_COMMIT_MAGIC
    regmap::Reg gen;         // RO  +1 per ACCEPTED commit
    regmap::Reg activeBank;  // RO  bit0 — which bank the FAST PATH is reading
    regmap::Reg crc;         // RO  fabric CRC32 of the LIVE bank

    std::uint32_t wordsPerRecord;  // 11 for risk, 5 for strat
    unsigned recordBits;           // 324 / 149 — mirrored from trading_pkg.sv

    [[nodiscard]] constexpr std::uint32_t bankWords() const noexcept {
        return N_ACTIVE * wordsPerRecord;
    }
};

// -----------------------------------------------------------------------------
// mirrors rtl/pkg/trading_pkg.sv :: sym_risk_t (324 bits) via
// host/include/trading/types.hpp §5. A change to the struct in the RTL changes
// SYM_RISK_BITS/SYM_RISK_WORDS in types.hpp, which breaks the static_asserts
// below rather than silently shortening every risk record by a word.
// -----------------------------------------------------------------------------
inline constexpr ParamWindow kRiskWindow{
    /*domain*/ ParamDomain::RiskLimits,
    /*name*/ "RISK",
    regmap::PARAM_RISK_ADDR,
    regmap::PARAM_RISK_DATA,
    regmap::PARAM_RISK_RB,
    regmap::PARAM_RISK_COMMIT,
    regmap::PARAM_RISK_GEN,
    regmap::PARAM_RISK_ACTIVE_BANK,
    regmap::PARAM_RISK_CRC,
    /*wordsPerRecord*/ static_cast<std::uint32_t>(SYM_RISK_WORDS),
    /*recordBits*/ SYM_RISK_BITS,
};

// mirrors rtl/pkg/trading_pkg.sv :: sym_strat_t (149 bits)
inline constexpr ParamWindow kStratWindow{
    /*domain*/ ParamDomain::StrategyParams,
    /*name*/ "STRAT",
    regmap::PARAM_STRAT_ADDR,
    regmap::PARAM_STRAT_DATA,
    regmap::PARAM_STRAT_RB,
    regmap::PARAM_STRAT_COMMIT,
    regmap::PARAM_STRAT_GEN,
    regmap::PARAM_STRAT_ACTIVE_BANK,
    regmap::PARAM_STRAT_CRC,
    /*wordsPerRecord*/ static_cast<std::uint32_t>(SYM_STRAT_WORDS),
    /*recordBits*/ SYM_STRAT_BITS,
};

// THE assertions the brief asks for by name. A change to trading_pkg.sv's packed
// widths must break this build, not corrupt a risk limit.
static_assert(kRiskWindow.recordBits == 324,
              "sym_risk_t is not 324 bits — rtl/pkg/trading_pkg.sv changed and every "
              "risk limit paramd writes is now at the wrong bit offset");
static_assert(kStratWindow.recordBits == 149,
              "sym_strat_t is not 149 bits — rtl/pkg/trading_pkg.sv changed and every "
              "strategy parameter paramd writes is now at the wrong bit offset");
static_assert(kRiskWindow.wordsPerRecord == 11, "sym_risk_t must serialise to 11 u32 words");
static_assert(kStratWindow.wordsPerRecord == 5, "sym_strat_t must serialise to 5 u32 words");
static_assert(kRiskWindow.wordsPerRecord * 32 >= kRiskWindow.recordBits);
static_assert(kStratWindow.wordsPerRecord * 32 >= kStratWindow.recordBits);
static_assert(kRiskWindow.wordsPerRecord <= PARAM_WORDS_PER_SYM,
              "a risk record does not fit the PARAM address stride (word_idx is 4 bits)");
static_assert(kStratWindow.wordsPerRecord <= PARAM_WORDS_PER_SYM,
              "a strat record does not fit the PARAM address stride (word_idx is 4 bits)");
static_assert(kRiskWindow.bankWords() == 256u * 11u, "risk bank is 2816 words");
static_assert(kStratWindow.bankWords() == 256u * 5u, "strat bank is 1280 words");

// The two windows must not share a single register. If they ever do, a commit in
// one domain would ring the other's doorbell.
namespace detail {
[[nodiscard]] consteval bool windowsDisjoint() {
    const std::uint32_t a[7] = {kRiskWindow.addr.offset,  kRiskWindow.data.offset,
                                kRiskWindow.rb.offset,    kRiskWindow.commit.offset,
                                kRiskWindow.gen.offset,   kRiskWindow.activeBank.offset,
                                kRiskWindow.crc.offset};
    const std::uint32_t b[7] = {kStratWindow.addr.offset,  kStratWindow.data.offset,
                                kStratWindow.rb.offset,    kStratWindow.commit.offset,
                                kStratWindow.gen.offset,   kStratWindow.activeBank.offset,
                                kStratWindow.crc.offset};
    for (std::uint32_t x : a) {
        for (std::uint32_t y : b) {
            if (x == y) return false;
        }
    }
    return true;
}
}  // namespace detail
static_assert(detail::windowsDisjoint(),
              "the risk and strategy parameter windows share a register offset — a commit "
              "in one domain would flip the other domain's bank");

// The access classes the protocol depends on. writeVerify() is only legal on RW.
static_assert(regmap::isVerifiable(kRiskWindow.addr.access), "PARAM_RISK_ADDR must be RW");
static_assert(regmap::isVerifiable(kStratWindow.addr.access), "PARAM_STRAT_ADDR must be RW");
static_assert(regmap::isWritable(kRiskWindow.data.access), "PARAM_RISK_DATA must be writable");
static_assert(regmap::isWritable(kRiskWindow.commit.access), "PARAM_RISK_COMMIT must be writable");
static_assert(regmap::isReadable(kRiskWindow.rb.access), "PARAM_RISK_RB must be readable");
static_assert(regmap::isReadable(kRiskWindow.gen.access), "PARAM_RISK_GEN must be readable");
static_assert(regmap::isReadable(kRiskWindow.activeBank.access),
              "PARAM_RISK_ACTIVE_BANK must be readable — the live-bank guard depends on it");
static_assert(!regmap::hasReadSideEffect(kRiskWindow.activeBank.access),
              "ACTIVE_BANK is re-read before every write; it must not have a read side effect");
static_assert(!regmap::hasReadSideEffect(kStratWindow.activeBank.access),
              "ACTIVE_BANK is re-read before every write; it must not have a read side effect");

[[nodiscard]] constexpr const ParamWindow& windowFor(ParamDomain d) noexcept {
    return d == ParamDomain::RiskLimits ? kRiskWindow : kStratWindow;
}

// =============================================================================
// 3. Banks
// =============================================================================
[[nodiscard]] constexpr ParamBank otherBank(ParamBank b) noexcept {
    return b == ParamBank::A ? ParamBank::B : ParamBank::A;
}
[[nodiscard]] constexpr std::string_view toString(ParamBank b) noexcept {
    return b == ParamBank::A ? "A" : "B";
}
static_assert(otherBank(ParamBank::A) == ParamBank::B);
static_assert(otherBank(ParamBank::B) == ParamBank::A);
static_assert(otherBank(otherBank(ParamBank::A)) == ParamBank::A);

// =============================================================================
// 4. Failure vocabulary
// -----------------------------------------------------------------------------
// POD. No allocation, no strings owned. The commit path must be able to fail
// without touching the heap: an OOM in the middle of a bank write is exactly the
// half-configured state host/include/trading/expected.hpp exists to prevent.
// =============================================================================
enum class ParamError : std::uint16_t {
    Ok = 0,

    // --- transport --------------------------------------------------------
    BusRead = 1,    // a register read failed
    BusWrite = 2,   // a register write failed
    BusVerify = 3,  // writeVerify read back something other than what it wrote
    NoBus = 4,      // an operation that needs the device was called without one

    // --- the live-bank guard ⚠ --------------------------------------------
    ActiveBankUndecodable = 10,  // PARAM_*_ACTIVE_BANK had bits set we do not understand
    WriteTargetIsLiveBank = 11,  // ⚠⚠ the guard fired: we were about to write the LIVE bank
    LiveBankMovedUnderUs = 12,   // ACTIVE_BANK changed mid-write; someone else committed
    BankTargetPoisoned = 13,     // a guard already fired on this target; it is dead
    AddressBankFieldWrong = 14,  // the encoded PARAM address does not carry the target bank

    // --- integrity --------------------------------------------------------
    ReadBackMismatch = 20,     // PARAM_*_RB != what we wrote
    CrcMismatchReadBack = 21,  // host CRC of the read-back bank != host CRC of the intent
    CrcMismatchFabric = 22,    // fabric PARAM_*_CRC != host CRC after the flip

    // --- the commit -------------------------------------------------------
    GenerationDidNotMove = 30,   // GEN unchanged: the commit was not accepted
    GenerationJumped = 31,       // GEN moved by != 1: someone else committed too
    BankDidNotFlip = 32,         // ACTIVE_BANK still points at the old bank
    BankFlippedToWrongBank = 33, // ACTIVE_BANK flipped somewhere we did not write

    // --- governance / preflight ------------------------------------------
    ValidationFailed = 40,      // the parameter set is internally inconsistent
    NotPackable = 41,           // a value does not fit its fabric field width
    UnapprovedLoosening = 42,   // manual 08/09 §9 "Direction matters"
    MissingAuthorization = 43,  // manual 08/09 §9 four-eyes
    DryRunRefusedToCommit = 44, // mode was DryRun; nothing was written. Not an error condition.
    AuditSinkFailed = 45,       // could not durably record the change -> do not commit
    SizeMismatch = 46,          // a caller-supplied buffer is the wrong length
};

[[nodiscard]] constexpr std::string_view toString(ParamError e) noexcept {
    switch (e) {
        case ParamError::Ok:                    return "OK";
        case ParamError::BusRead:               return "BUS_READ";
        case ParamError::BusWrite:              return "BUS_WRITE";
        case ParamError::BusVerify:             return "BUS_VERIFY";
        case ParamError::NoBus:                 return "NO_BUS";
        case ParamError::ActiveBankUndecodable: return "ACTIVE_BANK_UNDECODABLE";
        case ParamError::WriteTargetIsLiveBank: return "WRITE_TARGET_IS_LIVE_BANK";
        case ParamError::LiveBankMovedUnderUs:  return "LIVE_BANK_MOVED_UNDER_US";
        case ParamError::BankTargetPoisoned:    return "BANK_TARGET_POISONED";
        case ParamError::AddressBankFieldWrong: return "ADDRESS_BANK_FIELD_WRONG";
        case ParamError::ReadBackMismatch:      return "READ_BACK_MISMATCH";
        case ParamError::CrcMismatchReadBack:   return "CRC_MISMATCH_READ_BACK";
        case ParamError::CrcMismatchFabric:     return "CRC_MISMATCH_FABRIC";
        case ParamError::GenerationDidNotMove:  return "GENERATION_DID_NOT_MOVE";
        case ParamError::GenerationJumped:      return "GENERATION_JUMPED";
        case ParamError::BankDidNotFlip:        return "BANK_DID_NOT_FLIP";
        case ParamError::BankFlippedToWrongBank:return "BANK_FLIPPED_TO_WRONG_BANK";
        case ParamError::ValidationFailed:      return "VALIDATION_FAILED";
        case ParamError::NotPackable:           return "NOT_PACKABLE";
        case ParamError::UnapprovedLoosening:   return "UNAPPROVED_LOOSENING";
        case ParamError::MissingAuthorization:  return "MISSING_AUTHORIZATION";
        case ParamError::DryRunRefusedToCommit: return "DRY_RUN_REFUSED_TO_COMMIT";
        case ParamError::AuditSinkFailed:       return "AUDIT_SINK_FAILED";
        case ParamError::SizeMismatch:          return "SIZE_MISMATCH";
    }
    return "PARAM_ERROR_UNKNOWN";
}

// A failure anywhere in the cycle leaves the PREVIOUSLY-LIVE BANK LIVE, which is
// the safe outcome (manual 08/09 §6: "Rollback | The previous bank is still
// intact"). This struct exists so the operator learns *which* word of *which*
// symbol disagreed, not just that something did.
struct ParamFailure {
    ParamError code = ParamError::Ok;
    ParamDomain domain = ParamDomain::RiskLimits;
    std::uint32_t offset = 0;     // BAR0 byte offset involved, 0 if none
    std::uint32_t symIdx = 0xFFFF'FFFFu;  // active-set index, or ~0 if not per-symbol
    std::uint32_t wordIdx = 0xFFFF'FFFFu; // word within the record, or ~0
    std::uint64_t expected = 0;
    std::uint64_t actual = 0;
    std::int32_t busCode = 0;     // opaque device-layer error code, if any

    [[nodiscard]] constexpr bool perSymbol() const noexcept { return symIdx != 0xFFFF'FFFFu; }
};

[[nodiscard]] constexpr ParamFailure makeFailure(ParamError c, ParamDomain d) noexcept {
    ParamFailure f{};
    f.code = c;
    f.domain = d;
    return f;
}

}  // namespace trading::paramd

#endif  // TRADING_PARAMD_PARAM_WINDOW_HPP
