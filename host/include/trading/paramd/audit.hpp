// =============================================================================
// paramd/audit.hpp — SEPARATE audit records for a risk-limit commit and a
//                    strategy-parameter commit
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : paramd (the parameter engine)
// Primary reference: manuals/08-nasdaq/09-risk-controls-and-limits.md §9
//                    host/README.md §3.3, CLAUDE.md §6
//
// -----------------------------------------------------------------------------
// WHY THERE ARE TWO OF EVERYTHING
//   host/README.md §3.3: "Risk limit changes are never bundled with other work.
//   Separate change, separate review, separate audit entry."
//   manual 08/09 §9: "⚠ Never bundled | A limit change is never combined with a
//   strategy change ... One change, one deploy, one rollback story."
//
//   That is made structurally true here rather than by convention:
//     * two record types, RiskLimitCommitRecord and StrategyParamCommitRecord,
//       with no common base a caller could hold generically;
//     * two sink methods, emitRiskLimitCommit() and emitStrategyParamCommit(),
//       with no combined method;
//     * two files on disk, by default, so the risk audit trail is a distinct
//       artefact that can be retained, shipped and reviewed on its own.
//   There is deliberately no emitParamCommit(domain, ...) overload. Adding one
//   would let a future caller write both from one call site, which is the exact
//   thing the rule forbids.
//
// -----------------------------------------------------------------------------
// RECORD ENCODING
//   Records go out as SHARED_CONTRACT.md's DMA log-record shape:
//     32-byte LogRecordHeader with type = PARAM_COMMIT (8), then a JSON payload,
//     then a CRC32 over the payload.
//   The header carries schema_ver; the payload carries its OWN schema version
//   too, because the payload schema for a risk commit and for a strategy commit
//   evolve independently.
//
//   ⚠ The 32-byte header mirrors a log_ring.sv that does not exist yet. It is
//   duplicated here inside namespace trading::paramd rather than taken from a
//   logd header, so that paramd does not depend on a component it does not own.
// TODO(rtl-contract): if logd publishes a canonical LogRecordHeader, delete this
//   copy and include that one; the static_assert below is what will notice.
// =============================================================================
#ifndef TRADING_PARAMD_AUDIT_HPP
#define TRADING_PARAMD_AUDIT_HPP

#include <cstdint>
#include <cstdio>
#include <string>
#include <string_view>
#include <vector>

#include "trading/expected.hpp"
#include "trading/paramd/bank_writer.hpp"
#include "trading/paramd/param_table.hpp"
#include "trading/paramd/param_window.hpp"
#include "trading/paramd/validation.hpp"

namespace trading::paramd {

// =============================================================================
// 1. Wire header  (SHARED_CONTRACT.md §"DMA log record header")
// =============================================================================
inline constexpr std::uint32_t LOG_RECORD_MAGIC = 0x4C47'5231u;  // 'LGR1'
inline constexpr std::uint16_t LOG_RECORD_TYPE_PARAM_COMMIT = 8;  // LogRecordType::PARAM_COMMIT

struct LogRecordHeader {
    std::uint32_t magic;
    std::uint16_t schema_ver;
    std::uint16_t type;
    std::uint32_t length;  // total record bytes INCLUDING this header
    std::uint32_t seq;
    std::uint64_t fabric_cycle;
    std::uint32_t build_id;
    std::uint32_t crc32;  // over the payload
};
static_assert(sizeof(LogRecordHeader) == 32,
              "LogRecordHeader must be 32 bytes — SHARED_CONTRACT.md pins this and logd, "
              "the reconciler and metricsd all parse it");
static_assert(alignof(LogRecordHeader) <= 8);

// Payload schema versions. These move INDEPENDENTLY: a new risk field is not a
// reason to renumber the strategy schema.
inline constexpr std::uint16_t RISK_AUDIT_SCHEMA_VERSION = 1;
inline constexpr std::uint16_t STRAT_AUDIT_SCHEMA_VERSION = 1;
// The header's own schema_ver, shared by both because the header shape is shared.
inline constexpr std::uint16_t LOG_HEADER_SCHEMA_VERSION = 1;

// =============================================================================
// 2. Common metadata
// =============================================================================
enum class CommitMode : std::uint8_t {
    DryRun = 0,  // validate, pack, diff. Zero writes. The DEFAULT for risk limits.
    Commit = 1,
};

[[nodiscard]] constexpr std::string_view toString(CommitMode m) noexcept {
    return m == CommitMode::DryRun ? "DRY_RUN" : "COMMIT";
}

enum class CommitOutcome : std::uint8_t {
    DryRun = 0,             // nothing was written; the diff is the deliverable
    Success = 1,            // written, read back, verified, committed, gen+1, bank flipped
    NoChange = 2,           // the desired table already matches the live bank
    ValidationRejected = 3, // refused before any device access
    GovernanceRejected = 4, // four-eyes / loosening approval missing
    PreflightFailed = 5,    // could not even read ACTIVE_BANK / GEN
    WriteFailed = 6,
    VerifyFailed = 7,       // read-back mismatch or host CRC mismatch
    CommitNotTaken = 8,     // ⚠ doorbell rung, but GEN/bank did not move as required
    AuditFailed = 9,        // could not durably record: the commit is NOT attempted
};

[[nodiscard]] std::string_view toString(CommitOutcome o) noexcept;

// Who asked, who approved, and why. manual 08/09 §9: "Every change logged: who,
// when, old value, new value, reason, approver, and the resulting parameter-bank
// CRC. Immutable, retained."
struct AuditActor {
    std::string requestedBy;  // a person or a named automation
    std::string approvedBy;   // MUST differ from requestedBy for a risk commit
    std::string ticket;       // change record / incident reference
    std::string reason;       // free text; required for a risk commit
    std::string host;         // where paramd was running
    std::uint32_t pid = 0;
};

// Wall-clock, recorded as integer nanoseconds since the Unix epoch. No time
// formatting library, no locale, no float.
struct AuditClock {
    std::uint64_t unixNanos = 0;
    static AuditClock now() noexcept;
};

[[nodiscard]] std::string formatUnixNanosIso8601(std::uint64_t unixNanos);

// The device-side evidence, common to both domains.
struct CommitEvidence {
    ParamBank liveBankBefore = ParamBank::A;
    ParamBank targetBank = ParamBank::B;
    ParamBank liveBankAfter = ParamBank::A;
    std::uint32_t generationBefore = 0;
    std::uint32_t generationAfter = 0;
    std::uint32_t hostCrcIntent = 0;
    std::uint32_t hostCrcReadBack = 0;
    std::uint32_t fabricCrcBefore = 0;
    std::uint32_t fabricCrcAfter = 0;
    bool fabricCrcChecked = false;
    bool fabricCrcMatched = false;
    std::uint32_t wordsWritten = 0;
    std::uint32_t wordsReadBack = 0;
    std::uint64_t liveBankGuardChecks = 0;  // must equal wordsWritten
    std::uint64_t busReads = 0;
    std::uint64_t busWrites = 0;
};

// =============================================================================
// 3. Risk-limit commit record
// -----------------------------------------------------------------------------
// Carries the FULL before and after sym_risk_t for every symbol that changed
// (and, on request, for every symbol), plus the direction classification that
// manual 08/09 §9 makes operationally significant.
// =============================================================================
struct RiskSymBeforeAfter {
    std::uint32_t symIdx = 0;
    std::string label;
    SymRisk before{};
    SymRisk after{};
    bool loosened = false;
};

struct RiskLimitCommitRecord {
    std::uint16_t schemaVersion = RISK_AUDIT_SCHEMA_VERSION;
    ParamDomain domain = ParamDomain::RiskLimits;  // fixed. Never StrategyParams.

    AuditActor actor;
    AuditClock startedAt;
    AuditClock finishedAt;
    CommitMode mode = CommitMode::DryRun;
    CommitOutcome outcome = CommitOutcome::DryRun;
    ParamFailure failure{};  // valid when outcome is a failure

    // Governance (manual 08/09 §9)
    bool loosensAnyLimit = false;
    bool looseningApproved = false;

    // What changed
    std::vector<RiskSymBeforeAfter> changed;
    std::size_t symbolsEnabledBefore = 0;
    std::size_t symbolsEnabledAfter = 0;
    std::size_t tightenCount = 0;
    std::size_t loosenCount = 0;
    std::size_t neutralCount = 0;
    std::string diffText;  // the rendered, human-readable diff

    // Validation
    std::size_t validationErrors = 0;
    std::size_t validationWarnings = 0;
    std::string validationText;

    CommitEvidence evidence;
};

// =============================================================================
// 4. Strategy-parameter commit record — a DIFFERENT type, deliberately
// -----------------------------------------------------------------------------
// Note what it does NOT have: a loosening classification and an approver. A
// strategy parameter is not a control; a risk limit is. Giving them the same
// record shape would invite giving them the same workflow.
// =============================================================================
struct StratSymBeforeAfter {
    std::uint32_t symIdx = 0;
    std::string label;
    SymStrat before{};
    SymStrat after{};
};

struct StrategyParamCommitRecord {
    std::uint16_t schemaVersion = STRAT_AUDIT_SCHEMA_VERSION;
    ParamDomain domain = ParamDomain::StrategyParams;  // fixed. Never RiskLimits.

    AuditActor actor;
    AuditClock startedAt;
    AuditClock finishedAt;
    CommitMode mode = CommitMode::Commit;
    CommitOutcome outcome = CommitOutcome::DryRun;
    ParamFailure failure{};

    std::vector<StratSymBeforeAfter> changed;
    std::size_t symbolsEnabledBefore = 0;
    std::size_t symbolsEnabledAfter = 0;
    std::string diffText;

    std::size_t validationErrors = 0;
    std::size_t validationWarnings = 0;
    std::string validationText;

    // Advisory cross-check state: which risk generation the strategy parameters
    // were validated against. Recorded so a later investigation can tell whether
    // the strategy was checked against the risk limits that were actually live.
    // ⚠ Read-only. A strategy commit NEVER writes a risk limit.
    bool riskCrossChecked = false;
    std::uint32_t riskGenerationObserved = 0;

    CommitEvidence evidence;
};

// =============================================================================
// 5. Serialisation
// =============================================================================
[[nodiscard]] std::string toJson(const RiskLimitCommitRecord& r);
[[nodiscard]] std::string toJson(const StrategyParamCommitRecord& r);

// Encode header + JSON payload into a DMA-log-shaped record.
[[nodiscard]] std::vector<std::uint8_t> encodeRecord(const RiskLimitCommitRecord& r,
                                                     std::uint32_t seq, std::uint32_t buildId,
                                                     std::uint64_t fabricCycle);
[[nodiscard]] std::vector<std::uint8_t> encodeRecord(const StrategyParamCommitRecord& r,
                                                     std::uint32_t seq, std::uint32_t buildId,
                                                     std::uint64_t fabricCycle);

// =============================================================================
// 6. Sinks
// =============================================================================
enum class AuditError : std::uint8_t {
    OpenFailed = 1,
    WriteFailed = 2,
    SyncFailed = 3,
    NotConfigured = 4,
};

[[nodiscard]] std::string_view toString(AuditError e) noexcept;

class AuditSink {
public:
    virtual ~AuditSink() = default;
    AuditSink() = default;
    AuditSink(const AuditSink&) = delete;
    AuditSink& operator=(const AuditSink&) = delete;

    [[nodiscard]] virtual expected<void, AuditError> emitRiskLimitCommit(
        const RiskLimitCommitRecord& r) = 0;

    [[nodiscard]] virtual expected<void, AuditError> emitStrategyParamCommit(
        const StrategyParamCommitRecord& r) = 0;

    // ⚠ There is intentionally NO emitParamCommit(ParamDomain, ...). See the
    //   header comment.
};

// Append-only JSONL, one file per domain, fsync'd before the call returns.
// "Immutable, retained" (manual 08/09 §9) is a property of the storage this
// writes into; what paramd guarantees is that the record is on stable storage
// BEFORE the commit doorbell is rung.
class JsonlAuditSink final : public AuditSink {
public:
    // Two paths. Not one file with a domain column — a separate artefact.
    JsonlAuditSink(std::string riskLogPath, std::string strategyLogPath);
    ~JsonlAuditSink() override;

    [[nodiscard]] expected<void, AuditError> emitRiskLimitCommit(
        const RiskLimitCommitRecord& r) override;
    [[nodiscard]] expected<void, AuditError> emitStrategyParamCommit(
        const StrategyParamCommitRecord& r) override;

    [[nodiscard]] const std::string& riskLogPath() const noexcept { return riskPath_; }
    [[nodiscard]] const std::string& strategyLogPath() const noexcept { return stratPath_; }

private:
    [[nodiscard]] expected<void, AuditError> appendLine(std::FILE*& fh, const std::string& path,
                                                        const std::string& line);

    std::string riskPath_;
    std::string stratPath_;
    std::FILE* riskFh_ = nullptr;
    std::FILE* stratFh_ = nullptr;
};

// Keeps records in memory. For tests and for the dry-run path, where there is
// nothing durable to record because nothing happened.
class MemoryAuditSink final : public AuditSink {
public:
    [[nodiscard]] expected<void, AuditError> emitRiskLimitCommit(
        const RiskLimitCommitRecord& r) override {
        risk_.push_back(r);
        return {};
    }
    [[nodiscard]] expected<void, AuditError> emitStrategyParamCommit(
        const StrategyParamCommitRecord& r) override {
        strat_.push_back(r);
        return {};
    }

    [[nodiscard]] const std::vector<RiskLimitCommitRecord>& riskRecords() const noexcept {
        return risk_;
    }
    [[nodiscard]] const std::vector<StrategyParamCommitRecord>& strategyRecords() const noexcept {
        return strat_;
    }

private:
    std::vector<RiskLimitCommitRecord> risk_;
    std::vector<StrategyParamCommitRecord> strat_;
};

}  // namespace trading::paramd

#endif  // TRADING_PARAMD_AUDIT_HPP
