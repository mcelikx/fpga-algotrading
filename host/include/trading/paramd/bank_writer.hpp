// =============================================================================
// paramd/bank_writer.hpp — the write-inactive-bank / read-back / verify / commit
//                          cycle, and the guard that makes writing a live bank
//                          impossible
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : paramd (the parameter engine)
// Primary reference: manuals/08-nasdaq/09-risk-controls-and-limits.md §6
//                    ("Atomic double-buffered parameter update")
//                    host/README.md §3.1 (read back and verify — mandatory)
//
// -----------------------------------------------------------------------------
// ⚠⚠ THE ONE THING THIS FILE EXISTS TO PREVENT
//   Writing risk limits into the bank the fast path is reading from, mid-trade.
//   manual 08/09 §6: "A half-written record is not a smaller limit — it is an
//   undefined limit." The design defence is three-layered and every layer is
//   always on. There is no NDEBUG-disabled assert anywhere in this file.
//
//   Layer 1 — THE BANK INDEX IS COMPUTED IN EXACTLY ONE PLACE.
//     BankTarget::acquire() reads PARAM_*_ACTIVE_BANK, decodes it strictly, and
//     stores `target = otherBank(live)`. BankTarget's constructor is private, so
//     acquire() is the only way a target can come into existence. Nothing else
//     in paramd computes a bank index.
//
//   Layer 2 — A WRITE ADDRESS CANNOT BE FORGED.
//     writeWord() does not take a std::uint16_t; it takes a WriteAddr, whose
//     constructor is private and whose only friend is BankTarget. types.hpp's
//     paramAddr() is public and could encode any bank, but its result cannot be
//     handed to a write.
//
//   Layer 3 — RE-VALIDATED IMMEDIATELY BEFORE EVERY SINGLE WRITE.
//     BankTarget::addrForWrite() re-reads PARAM_*_ACTIVE_BANK from the device
//     and refuses if it now equals our target, then re-extracts the bank field
//     out of the address it just encoded and refuses if it is not the target.
//     Yes, that is one extra MMIO read per word: 2816 reads for a risk bank,
//     a few milliseconds on a path that runs at human cadence. That is the
//     cheapest insurance in this repository.
//     A refusal POISONS the BankTarget permanently — no further write can be
//     attempted through it, so a race cannot be retried into success.
//
// -----------------------------------------------------------------------------
// FAILURE SEMANTICS
//   Any failure at any step leaves the previously-live bank live, because the
//   only thing that changes which bank is live is the COMMIT doorbell, and that
//   is the last write of the cycle. manual 08/09 §6: "Rollback | The previous
//   bank is still intact — a 'revert' is another flip." So the safe outcome is
//   the DEFAULT outcome, not something the error path has to remember to do.
//
//   Nothing in this file allocates.
// =============================================================================
#ifndef TRADING_PARAMD_BANK_WRITER_HPP
#define TRADING_PARAMD_BANK_WRITER_HPP

#include <cstdint>
#include <span>

#include "trading/expected.hpp"
#include "trading/paramd/crc32.hpp"
#include "trading/paramd/param_bus.hpp"
#include "trading/paramd/param_window.hpp"
#include "trading/types.hpp"

namespace trading::paramd {

// -----------------------------------------------------------------------------
// Loud reporting of a live-bank violation. Returning an error is what the code
// does; this hook is so a human hears about it. Default writes to stderr.
// manual 08/09 §6: "Fail the commit loudly, set a sticky error, and alarm."
// -----------------------------------------------------------------------------
using LiveBankViolationHandler = void (*)(const ParamFailure&) noexcept;
void setLiveBankViolationHandler(LiveBankViolationHandler h) noexcept;
[[nodiscard]] bool liveBankViolationLatched() noexcept;  // sticky, process-lifetime
void clearLiveBankViolationLatch() noexcept;             // test hook only

class BankTarget;

// -----------------------------------------------------------------------------
// WriteAddr — a PARAM_*_ADDR value that has been proven to point at the target
// (non-live) bank. Only BankTarget can make one.
// -----------------------------------------------------------------------------
class WriteAddr {
public:
    [[nodiscard]] std::uint16_t value() const noexcept { return v_; }
    [[nodiscard]] std::uint32_t symIdx() const noexcept { return sym_; }
    [[nodiscard]] std::uint32_t wordIdx() const noexcept { return word_; }

private:
    friend class BankTarget;
    constexpr WriteAddr(std::uint16_t v, std::uint32_t sym, std::uint32_t word) noexcept
        : v_(v), sym_(sym), word_(word) {}

    std::uint16_t v_;
    std::uint32_t sym_;
    std::uint32_t word_;
};

// -----------------------------------------------------------------------------
// BankTarget — the single place a bank index is decided.
// -----------------------------------------------------------------------------
class BankTarget {
public:
    // Reads PARAM_*_ACTIVE_BANK and selects the OTHER bank. This is the only
    // constructor path in the program.
    [[nodiscard]] static expected<BankTarget, ParamFailure> acquire(ParamBus& bus,
                                                                    const ParamWindow& win);

    [[nodiscard]] ParamBank target() const noexcept { return target_; }
    [[nodiscard]] ParamBank liveAtAcquire() const noexcept { return liveAtAcquire_; }
    [[nodiscard]] const ParamWindow& window() const noexcept { return *win_; }
    [[nodiscard]] bool poisoned() const noexcept { return poisoned_; }
    [[nodiscard]] std::uint64_t guardChecks() const noexcept { return guardChecks_; }

    // ⚠ THE GUARD. Called immediately before every write; re-reads ACTIVE_BANK
    // from the device, re-derives the address, and re-extracts its bank field.
    [[nodiscard]] expected<WriteAddr, ParamFailure> addrForWrite(ParamBus& bus, std::uint32_t symIdx,
                                                                 std::uint32_t wordIdx);

    // Read-side addressing. Reading any bank is harmless, so this does not need
    // the guard — but it does need to be a different function, so that "I am
    // reading" and "I am writing" are never the same call.
    [[nodiscard]] static std::uint16_t addrForRead(ParamBank bank, std::uint32_t symIdx,
                                                   std::uint32_t wordIdx) noexcept;

    // Read ACTIVE_BANK and decode it strictly. Exposed because the commit step
    // has to re-check the flip afterwards.
    [[nodiscard]] static expected<ParamBank, ParamFailure> readActiveBank(ParamBus& bus,
                                                                          const ParamWindow& win);

private:
    BankTarget(const ParamWindow& win, ParamBank live) noexcept
        : win_(&win), liveAtAcquire_(live), target_(otherBank(live)) {}

    void poison(const ParamFailure& f) noexcept;

    const ParamWindow* win_;
    ParamBank liveAtAcquire_;
    ParamBank target_;
    bool poisoned_ = false;
    std::uint64_t guardChecks_ = 0;
};

// =============================================================================
// The cycle
// =============================================================================

struct BankIoStats {
    std::uint32_t wordsWritten = 0;
    std::uint32_t wordsReadBack = 0;
    std::uint64_t activeBankReads = 0;  // one per word write, by design
};

// (c) Write every word of every symbol record through PARAM_*_ADDR/DATA.
//     `words` must be exactly win.bankWords() long.
[[nodiscard]] expected<void, ParamFailure> writeBank(ParamBus& bus, BankTarget& target,
                                                     std::span<const std::uint32_t> words,
                                                     BankIoStats& stats);

// Read a whole bank out through PARAM_*_ADDR/RB. Used for (d) the read-back and
// for capturing the "before" values that go in the audit record.
[[nodiscard]] expected<void, ParamFailure> readBank(ParamBus& bus, const ParamWindow& win,
                                                    ParamBank bank, std::span<std::uint32_t> out,
                                                    BankIoStats& stats);

// (d) FULL read-back and compare — every word, not a spot check — plus (e) the
// host CRC over what actually came back. `scratch` must be win.bankWords() long.
struct VerifyResult {
    std::uint32_t hostCrcIntent = 0;    // CRC of what we meant to write
    std::uint32_t hostCrcReadBack = 0;  // CRC of what the fabric says is there
    std::uint32_t wordsCompared = 0;
};

[[nodiscard]] expected<VerifyResult, ParamFailure> verifyBank(
    ParamBus& bus, const BankTarget& target, std::span<const std::uint32_t> intent,
    std::span<std::uint32_t> scratch, BankIoStats& stats);

// -----------------------------------------------------------------------------
// PARAM_*_CRC semantics.
//
// regmap.hpp and SHARED_CONTRACT.md both describe PARAM_*_CRC as "fabric CRC32
// of the LIVE bank". If that is right, then BEFORE the commit the register
// describes the bank we are replacing, and the only moment a fabric-vs-host CRC
// comparison is meaningful is AFTER the flip. The brief's step ordering has the
// comparison before the commit, which is only correct if the register actually
// tracks the shadow bank (which is what manual 08/09 §6's fabric-side
// "verify shadow CRC on commit" would imply).
//
// Rather than guess, paramd is explicit: it captures the register on both sides
// of the commit, and compares against the host CRC on whichever side the
// configured semantics say is meaningful.
// TODO(rtl-contract): pin this when rtl/ctrl/csr_regfile.sv lands.
// -----------------------------------------------------------------------------
enum class FabricCrcSemantics : std::uint8_t {
    LiveBank = 0,    // regmap.hpp's reading: compare AFTER the flip
    ShadowBank = 1,  // manual §6's reading: compare BEFORE the commit
};

enum class FabricCrcPolicy : std::uint8_t {
    Required = 0,  // a mismatch fails the commit
    Advisory = 1,  // ⚠ a mismatch is recorded in the audit record but does not fail.
                   //   ONLY legitimate while the fabric CRC generator is unspecified.
    Ignore = 2,    // the register is not implemented at all in this bitstream
};

struct CommitConfig {
    FabricCrcSemantics crcSemantics = FabricCrcSemantics::LiveBank;
    FabricCrcPolicy crcPolicy = FabricCrcPolicy::Required;
    bool strictActiveBankDecode = true;  // reserved bits set -> undecodable -> fail closed
};

// (f) snapshot GEN, ring the doorbell; (g) verify GEN incremented by EXACTLY 1
// and ACTIVE_BANK flipped to the bank we wrote.
struct CommitResult {
    ParamBank bankBefore = ParamBank::A;
    ParamBank bankAfter = ParamBank::A;
    std::uint32_t genBefore = 0;
    std::uint32_t genAfter = 0;
    std::uint32_t fabricCrcBefore = 0;
    std::uint32_t fabricCrcAfter = 0;
    std::uint32_t hostCrc = 0;
    bool fabricCrcMatched = false;
    bool fabricCrcChecked = false;
    // True when the bank we wrote is byte-identical to the bank that was live:
    // a commit that changes nothing. Not an error, but the operator should know
    // they burned a generation for nothing.
    bool noOpAgainstLiveBank = false;
};

[[nodiscard]] expected<CommitResult, ParamFailure> commitBank(ParamBus& bus, BankTarget& target,
                                                              std::uint32_t hostCrc,
                                                              const CommitConfig& cfg);

// Read GEN. Exposed for the audit record and for reconciliation sweeps.
[[nodiscard]] expected<std::uint32_t, ParamFailure> readGeneration(ParamBus& bus,
                                                                    const ParamWindow& win);
[[nodiscard]] expected<std::uint32_t, ParamFailure> readFabricCrc(ParamBus& bus,
                                                                    const ParamWindow& win);

}  // namespace trading::paramd

#endif  // TRADING_PARAMD_BANK_WRITER_HPP
