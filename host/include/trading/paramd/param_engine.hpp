// =============================================================================
// paramd/param_engine.hpp — the two commit workflows
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : paramd (the parameter engine)
// References: host/README.md §2 (paramd: "Never writes a live bank"), §3.1, §3.3
//             manuals/08-nasdaq/09-risk-controls-and-limits.md §6, §9
//
// -----------------------------------------------------------------------------
// TWO METHODS, TWO WORKFLOWS, AND NO THIRD ONE
//
//   commitRiskLimits()      — governed. Dry-run by DEFAULT. Requires a requester
//                             AND a distinct approver AND a reason. Any loosening
//                             requires an explicit extra approval. Writes a
//                             RiskLimitCommitRecord to the risk audit trail.
//
//   commitStrategyParams()  — routine. Runs at millisecond-to-minute cadence.
//                             Requires a requester. Writes a
//                             StrategyParamCommitRecord to the strategy audit
//                             trail.
//
//   There is no commitAll(), no commitBoth(), and no commit(domain, table).
//   host/README.md §3.3 and manual 08/09 §9 forbid bundling a limit change with
//   anything else; the way to make that stick is to give the caller no way to
//   express it.
//
// -----------------------------------------------------------------------------
// THE ORDER OF OPERATIONS (both workflows, identical, and it matters)
//   1.  validate the desired table          — allocates; no device access yet
//   2.  governance gate                     — no device access yet
//   3.  read the LIVE bank (read-only)      — for the "before" values
//   4.  diff, classify direction            — the dry-run deliverable
//   5.  if DryRun: stop here. Nothing has been written.
//   6.  audit record written and FSYNCED with outcome=InFlight-equivalent...
//       ...actually: the record is emitted AFTER the cycle completes, but the
//       sink is proven writable BEFORE anything is written to the device, so a
//       commit is never made that cannot be recorded. See preflightAudit().
//   7.  BankTarget::acquire()               — ⚠ the one place a bank is chosen
//   8.  writeBank()                         — guard re-checked before EVERY word
//   9.  verifyBank()                        — FULL read-back + host CRC
//   10. commitBank()                        — doorbell, then GEN+1 and bank flip
//                                             are REQUIRED, not hoped for
//   11. emit the audit record
//
//   A failure at any step leaves the previously-live bank live.
// =============================================================================
#ifndef TRADING_PARAMD_PARAM_ENGINE_HPP
#define TRADING_PARAMD_PARAM_ENGINE_HPP

#include <cstdint>
#include <string>
#include <vector>

#include "trading/expected.hpp"
#include "trading/paramd/audit.hpp"
#include "trading/paramd/bank_writer.hpp"
#include "trading/paramd/param_bus.hpp"
#include "trading/paramd/param_table.hpp"
#include "trading/paramd/validation.hpp"

namespace trading::paramd {

struct EngineConfig {
    CommitConfig commit{};
    RiskValidationConfig riskValidation{};
    StratValidationConfig stratValidation{};

    // Dump every symbol into the audit record, not only the changed ones.
    bool auditIncludesUnchanged = false;

    // manual 08/09 §9 four-eyes. Off only for a bring-up rig with no venue.
    bool requireFourEyesForRisk = true;

    // Identity stamped into every emitted log record.
    std::uint32_t buildId = 0;

    DiffRenderOptions diffRender{};
};

// -----------------------------------------------------------------------------
// Requests
// -----------------------------------------------------------------------------
struct RiskCommitRequest {
    RiskTable desired = failClosedRiskTable();
    AuditActor actor;

    // ⚠ DEFAULT IS DRY RUN. manual 08/09 §9: a limit change is proposed by one
    // person and approved by a second "before it is applied". The default
    // posture for a risk limit is therefore: produce the diff, let a human look.
    CommitMode mode = CommitMode::DryRun;

    // Required when the diff loosens ANY limit (manual 08/09 §9 "Direction
    // matters"). Tightening does not need it.
    bool approveLoosening = false;

    // Diff against this instead of reading the device. Used when the risk system
    // holds its own record of what should be on the card — §9's reconciliation
    // control — or when running a dry run with no device at all.
    const RiskTable* baseline = nullptr;
};

struct StratCommitRequest {
    StratTable desired = failClosedStratTable();
    AuditActor actor;
    CommitMode mode = CommitMode::Commit;
    const StratTable* baseline = nullptr;

    // Read the LIVE risk bank and cross-check the strategy parameters against it
    // (advisory warnings only). ⚠ Read-only: this can never modify a risk limit.
    bool crossCheckAgainstLiveRisk = true;
};

// -----------------------------------------------------------------------------
// Reports — what the caller gets back, on success and on failure alike.
// -----------------------------------------------------------------------------
struct RiskCommitReport {
    CommitOutcome outcome = CommitOutcome::DryRun;
    ValidationReport validation{ParamDomain::RiskLimits};
    TableDiff diff;
    std::string diffText;
    RiskLimitCommitRecord record;
    bool auditEmitted = false;
};

struct StratCommitReport {
    CommitOutcome outcome = CommitOutcome::DryRun;
    ValidationReport validation{ParamDomain::StrategyParams};
    TableDiff diff;
    std::string diffText;
    StrategyParamCommitRecord record;
    bool auditEmitted = false;
};

// -----------------------------------------------------------------------------
// The engine
// -----------------------------------------------------------------------------
class ParamEngine {
public:
    // `bus` may be null: an engine with no device does dry runs only, diffing
    // against the caller-supplied baseline. That is the "prints the diff without
    // touching the device" mode in its strictest form — there is no device to
    // touch.
    ParamEngine(ParamBus* bus, AuditSink& audit, EngineConfig cfg = {});

    void setLabels(SymbolLabels labels) { labels_ = std::move(labels); }
    [[nodiscard]] const SymbolLabels& labels() const noexcept { return labels_; }
    [[nodiscard]] const EngineConfig& config() const noexcept { return cfg_; }

    // ---- the two workflows -------------------------------------------------
    [[nodiscard]] expected<RiskCommitReport, ParamFailure> commitRiskLimits(
        const RiskCommitRequest& req);

    [[nodiscard]] expected<StratCommitReport, ParamFailure> commitStrategyParams(
        const StratCommitRequest& req);

    // ---- read-only device access ------------------------------------------
    // §9: "Limits in the FPGA are periodically read back and diffed against the
    // risk system's record of what they should be. A mismatch is an incident."
    [[nodiscard]] expected<RiskTable, ParamFailure> readLiveRiskTable();
    [[nodiscard]] expected<StratTable, ParamFailure> readLiveStratTable();
    [[nodiscard]] expected<RiskTable, ParamFailure> readRiskTable(ParamBank bank);
    [[nodiscard]] expected<StratTable, ParamFailure> readStratTable(ParamBank bank);

    // The reconciliation control, as one call. Returns the diff between what is
    // live and what the risk system says should be live. Reads only.
    [[nodiscard]] expected<TableDiff, ParamFailure> reconcileRiskLimits(const RiskTable& expected);

private:
    // Deliberately absent: any method that commits both domains.
    ParamEngine(const ParamEngine&) = delete;
    ParamEngine& operator=(const ParamEngine&) = delete;

    ParamBus* bus_;
    AuditSink& audit_;
    EngineConfig cfg_;
    SymbolLabels labels_;

    // Preallocated so the commit cycle itself never allocates.
    std::vector<std::uint32_t> riskIntent_;
    std::vector<std::uint32_t> riskScratch_;
    std::vector<std::uint32_t> stratIntent_;
    std::vector<std::uint32_t> stratScratch_;

    std::uint32_t seq_ = 0;
};

}  // namespace trading::paramd

#endif  // TRADING_PARAMD_PARAM_ENGINE_HPP
