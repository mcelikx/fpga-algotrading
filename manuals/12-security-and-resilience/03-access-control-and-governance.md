# 12.03 — Access Control and Governance

> **Why this matters here:** the fastest way to lose a very large amount of money
> with this system is not an exploit — it is one authorised person making one
> authorised change on a Tuesday afternoon. The fabric enforces limits; it cannot
> enforce judgement. Governance is the layer that decides *whose* judgement gets
> to reach a register, and it is the only defence against the adversary who
> already has the credentials.

---

## 1. The question this document answers

> **Who is allowed to change what, by what mechanism, with whose approval, and
> where is the record?**

Four parts. A control that answers three of them is not a control. "The senior
engineer approves limit changes" fails on *mechanism* and *record*: there is
nothing that stops a non-approved change, and nothing that proves an approved one
happened.

The organising principle for the rest of the document:

```
Separation of duties  →  who may act
Change control        →  what the act must go through
Enforcement point     →  what physically refuses a non-conforming act
Audit trail           →  what proves what happened, afterwards
```

⚠️ **The enforcement point must be closer to the hardware than the person.** A
policy document is not an enforcement point. A host tool that "always uses the
approved workflow" is not an enforcement point if the BAR is writable by anything
else running as root. The enforcement points in this project are named in §5.

---

## 2. Roles and separation of duties

| Role | May do | Must **not** do | Rationale |
| --- | --- | --- | --- |
| **Strategy author** | Write `rtl/strategy/`, propose parameters, run backtests, request limit changes | ⚠️ Set or approve their own risk limits; sign a release; hold production credentials | The whole point of a limit is that it constrains someone else |
| **Risk owner** | Set and approve `sym_risk_t` limits, aggregate limits, message-rate caps; veto any release | Author strategy logic; hold the kill switch alone | Independence is the control |
| **Operator / trading ops** | Start of day, arm/disarm, **kill at any time without permission**, execute rollback | Change limits or parameters outside the approved workflow | Fast, unconditional stop authority; no change authority |
| **Build/release engineer** | Run CI, produce and sign artifacts, program cards | Approve their own release; change limits | Separates "what runs" from "what it is allowed to do" |
| **Compliance / supervision** | Read everything; require records; halt activity | Change anything | Independent oversight, read-only by design |
| **Reviewer (second engineer)** | Approve RTL, XDC, host, and config diffs | Approve their own work | Four-eyes on the source |

**The one non-negotiable split:**

> ⚠️ **The person who writes the strategy does not set the limits that constrain
> it.** In a small team this feels absurd — there may be three people. Do it
> anyway, even if the "risk owner" is the CTO reviewing a one-line diff. The
> alternative is a system where the only bound on capital deployment is set by
> the person whose incentive is to deploy capital.

Where the team is genuinely too small for clean separation, record the
compensating control explicitly (e.g. "limit changes require the risk owner's
written approval in the ticket **and** a second engineer's review of the diff;
the strategy author may propose but not commit"). A documented compromise is
auditable. An undocumented one is a finding.

---

## 3. Change classes

Not all changes are alike, and treating them alike guarantees the important ones
get the same casual handling as the trivial ones.

| Class | Examples | Blast radius | Control required | Change window |
| --- | --- | --- | --- | --- |
| **A — Risk limits** | `sym_risk_t`: `max_order_qty`, notional, position, price collar, rate caps | **Unbounded** — this is the bound itself | Risk owner approval + second reviewer + trading disabled + readback verified | Outside market hours, or with trading halted |
| **B — Bitstream** | Any RTL, XDC, IP, or tool change | Unbounded — could change any behaviour | Full release sign-off ([../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md) §8) + canary | Scheduled; never intraday without an incident reason |
| **C — Strategy parameters (structural)** | Enable a symbol, change size, change trigger thresholds | Bounded by class A limits | Author + reviewer, logged, canary at min size | Pre-open preferred |
| **D — Strategy parameters (continuous)** | `fair_value` updates at ms cadence | Bounded by A, but ⚠️ steers behaviour | Automated by `paramd`; **bounded and monitored**, not individually approved | Continuous, by design |
| **E — Session/venue config** | Endpoints, credentials, templates | Session-level | Ops + reviewer; write-protected while enabled | Pre-open |
| **F — Symbol/reference data** | Symbol table, reference prices | Bounded by A | Automated with validation + checksum readback | Pre-open |
| **G — Operational actions** | Arm, disarm, **kill**, rollback | Kill: risk-reducing. Arm: risk-increasing | ⚠️ **Asymmetric** — see §4 | Any time |

⚠️ **Class D is the one that gets missed.** `fair_value` is written continuously
into an unprotected CSR window while trading is live, which means it is the only
class of change with no human in the loop *and* direct influence on order
generation. It must therefore be constrained by mechanism instead: bounds-checked
in `paramd` before the write, bounds-checked again against the collar in fabric,
rate-limited, and monitored for jumps. A `fair_value` that moves more than a
configured amount in one update is an alertable event, not a normal one.

---

## 4. The asymmetry rule

Every governance decision in this system follows one rule:

> **Actions that reduce risk require no approval and must always be available.
> Actions that increase risk require approval and may be blocked.**

| Action | Direction | Approval | Availability requirement |
| --- | --- | --- | --- |
| Hit the kill switch | ↓ | **None. Ever.** | Must work at 3am, from anyone on the rota |
| Cancel orders | ↓ | None | ⚠️ Must work *while killed* — `KILLED ≠ SILENT` |
| Disable trading | ↓ | None | Always |
| Tighten a limit | ↓ | Light — logged, single approver | Should be easy |
| Arm / re-arm | ↑ | Two-step, all triggers clear, position loaded | Deliberately hard |
| Widen a limit | ↑ | Risk owner + reviewer + trading disabled | Deliberately hard |
| Enable a new symbol | ↑ | Reviewer + canary | Deliberately staged |

⚠️ **Never build an approval workflow that can delay a stop.** If the kill path
requires a login to a system that requires MFA that requires a phone that is
charging in another room, the kill path is 20 minutes long and you do not have a
kill switch. This is why the external `ext_kill_n` GPIO exists: it is the path
that requires no software, no credentials, and no network. See
[05-incident-preparedness.md](05-incident-preparedness.md) §3.

---

## 5. Enforcement points that actually exist in this design

Governance claims are only worth what the hardware backs. Here is what is real:

| Enforcement point | Where | Enforces |
| --- | --- | --- |
| Risk window write protection | `csr_regfile.sv` — writes to `0x200` **rejected while trading enabled**, no override bit, no force flag | A limit change is a deliberate, visible, multi-step operation |
| Two-step arm | `CONTROL[2]` then `CONTROL[3]` as **separate bus writes**; both in one write is rejected as operator error | Arming cannot be a stray single write |
| Kill latch | `kill_switch.sv` — sticky, never self-clears, re-arm requires all triggers clear **and** `position_loaded` | You cannot re-arm through a live fault or with an unreconciled position |
| CRC-gated parameter commit | `risk_params.sv` — host writes record words + expected CRC-32; fabric recomputes and **refuses** on mismatch; `crc_err` sticky, `crc_fail_cnt` increments | A torn or corrupted limit record never becomes active |
| Atomic activation | Single 324-bit write to `active_mem[sym]` on one clock edge | No window in which a half-updated limit is evaluated |
| Reset = fail-closed | Reset state: killed, trading disabled, limits zero, `HEARTBEAT_AGE = 0xFFFF` (already expired) | A fresh or rebooted card cannot trade by default |
| Build-ID arm gate | `BUILD_ID` at `0x000`, host refuses to arm on mismatch | Only the expected logic may trade |
| Audit ring | `dma_log_ring.sv` → `logd`, with `LOG_GAP_MARKER` when records are dropped | Gaps in the record are *recorded as gaps* |

**The workflow the hardware forces for a class-A change:**

```
disable trading  →  write risk window  →  write expected CRC  →  commit
                 →  read back FILTER/RISK checksum and compare
                 →  verify PARAM_GEN advanced
                 →  re-enable trading
```

Bracketed in the audit ring by a `LOG_TRADING_DIS` / `LOG_PARAM_COMMIT` /
`LOG_TRADING_EN` triple with the write-side checksum in the commit record. A
reviewer can reconstruct exactly what changed and when, months later, without
trusting anyone's memory.

⚠️ **The fabric does not implement four-eyes and cannot.** It has no notion of a
second human. What it provides is an *enforcement point that makes the host-side
control meaningful*: because the sequence cannot be bypassed by writing directly
to the BAR — the fabric refuses — the host tool is a real chokepoint rather than
a convention. The four-eyes requirement itself lives in `ctrld`/`paramd`: a second
authenticated operator must approve before the tool performs the
disable/commit/re-enable sequence.

⚠️ And the honest caveat, which must be stated in any compliance conversation:
**anyone with root on the trading host can write the BAR directly and skip the
host tool entirely.** The fabric will still refuse a write to `0x200` while
trading is enabled, and will still require the two-step arm — but four-eyes is
gone. Host access control is therefore part of the risk-limit control, not a
separate concern.

---

## 6. Host access control

Because §5 ends where it does, the trading host is a Tier-0 asset.

| Control | Requirement |
| --- | --- |
| Interactive login | Named accounts only; no shared `trader` account; MFA at the jump host |
| Root / sudo | Explicitly granted, logged centrally, alerting on use |
| Who can write BAR0 | Only `ctrld`. The device node is not world-writable; other processes have no business there |
| IOMMU | Enabled, with the card's DMA scoped. ⚠️ A device that can DMA anywhere can be used to reach anything |
| Running software | Minimal. Every extra daemon is an extra path to §5's caveat |
| Remote management (BMC/IPMI) | Separate network, separate credentials, ⚠️ it can power-cycle and re-flash |
| Change to host software | Same review discipline as RTL; version in the compatibility matrix with `BUILD_ID` |
| Break-glass access | Exists, is documented, is alarmed, and is reviewed after every use |

⚠️ **Monitoring agents count.** A metrics agent with a remote-code-execution
vulnerability is an order-injection vulnerability, because it runs next to
`ctrld`. Apply the same scrutiny to what you install for observability as to what
you install for trading.

---

## 7. Venue credentials

| Credential | Where it may live | Where it may **never** live |
| --- | --- | --- |
| SoupBinTCP username / password | Host secret store or a mode-`0600` file owned by the session user, injected at start | ⚠️ The repository — `CLAUDE.md` §6 |
| MPID, comp IDs, session IDs | Host config, environment-specific | The repository, a manual, a commit message, a ticket |
| Production venue IPs and ports | Host config | The repository |
| Test/UAT credentials | Test config file only, clearly marked | Any file that a production build reads |

The codebase already encodes the discipline —
[`host/include/trading/sessiond/config.hpp`](../../host/include/trading/sessiond/config.hpp)
carries `password` with the annotation *"never logged, never in an error string"*
and provides a `redactedSummary()` for anything that reaches a log. Extend that
posture everywhere:

| Rule | Why |
| --- | --- |
| Secrets are never interpolated into exception messages | Exceptions get logged, shipped to aggregators, and pasted into tickets |
| Secrets are never in a core dump you keep | Disable core dumps for `sessiond`, or scrub them |
| Secrets are never in a pcap you archive | ⚠️ A capture of a SoupBinTCP login contains the password in the clear |
| Rotation has a documented procedure and a rehearsal | An un-rehearsed rotation happens during an incident, badly |
| Leak response is written down before it is needed | Rotate at venue, restart sessions, review order activity in the exposure window, notify compliance |

⚠️ **The pcap point is the one people get wrong.** The order-entry capture that
you take routinely for latency analysis and conformance evidence contains the
session login. Either exclude the login frames from archived captures, or treat
the whole capture corpus as a secret with the same handling rules as the password
file. Pick one and write it down.

> **Verify:** whether your venue supports transport encryption, IP allow-listing,
> or port-level restrictions on order-entry sessions, and what its credential
> rotation procedure is — check the current Nasdaq SoupBinTCP/OUCH documentation
> and ask your connectivity contact.

---

## 8. Audit trail requirements

Two distinct trails. Both are mandatory and they answer different questions.

### (a) The decision trail — what the machine did

Produced in fabric, DMA'd to the host, drained by `logd`.

| Requirement | Detail |
| --- | --- |
| Every order candidate produces a record | ⚠️ **Including rejected ones.** A rejection is a decision |
| Rejection reason is attributable | `risk_reason_e` — 24 distinct reasons, per-reason counters |
| Causal link preserved | `{rx_cycle, feed sequence}` carried from the triggering message into the order record — turns "we sent a strange order" into "message #4 812 991 caused it" |
| Identity of the logic | `GIT_SHA` / `BUILD_ID` recorded alongside |
| Gaps are visible | `LOG_GAP_MARKER` pushed when space returns; `LOG_DROP_CNT` alertable |
| Timestamps from a disciplined clock | PTP/GPS, offset and drift monitored — a timestamp you cannot defend is not an audit trail |

### (b) The change trail — what the humans did

| Recorded for every change | Class A/B | Class C–F |
| --- | --- | --- |
| Who requested | ✔ | ✔ |
| Who approved (≠ requester) | ✔ | ✔ for C, E |
| What changed — before and after values | ✔ | ✔ |
| Why | ✔ | ✔ |
| When applied, by whom | ✔ | ✔ |
| Evidence it took effect (checksum/generation readback) | ✔ | ✔ |
| Link to the artifact (`BUILD_ID`, manifest) | ✔ | — |
| Backout plan | ✔ | Where applicable |

⚠️ **The change trail must be outside the system it describes.** A change record
stored only on the trading host is unavailable exactly when you need it — during
an outage, after a rebuild, or when the host is the thing under investigation.

**Retention:** long, and longer than you think.
> **Verify:** applicable record-keeping periods and formats with compliance —
> SEC Rules 17a-3/17a-4 (books and records, including electronic storage
> requirements) and CAT reporting obligations under SEC Rule 613 are the usual
> anchors for a US equities operation, and the details depend on your registration
> status. Do not pick a retention period from a manual; get it from counsel.

---

## 9. Regulatory backdrop

The controls above are not invented here; they are the practical shape of what
regulators already expect. Stated as mechanism, with the citations flagged for
verification.

| Framework | What it drives in this design |
| --- | --- |
| **SEC Rule 15c3-5** (Market Access Rule) | Pre-trade risk controls that are *reasonably designed*, and — the part that shapes governance — under the **direct and exclusive control of the broker-dealer** providing market access. That phrase is why the risk gate is non-bypassable in fabric and why limit-change authority is separated from strategy authority. > **Verify:** 17 CFR 240.15c3-5 and the SEC's adopting release; obligations differ between a broker-dealer and a sponsored-access customer. Confirm with compliance. |
| **Regulation SCI** | Change management, testing, BC/DR, and incident notification discipline for critical trading systems. > **Verify:** 17 CFR §§ 242.1000–1007. A proprietary trading firm is generally **not** an SCI entity, though the scope has been the subject of rule proposals. Confirm with counsel. |
| **SEC Rule 613 / CAT** | Order-lifecycle reporting; drives the decision trail's field set and clock discipline. > **Verify:** the CAT NMS Plan and current FINRA CAT industry-member specifications, plus the applicable clock-synchronisation rule. |
| **MiFID II / RTS 6** | The EU analogue: kill functionality, pre-trade controls, testing, annual self-assessment, clear responsibility for algorithms. > **Verify:** Reg. (EU) 2017/589 and UK onshored equivalents before any EU/UK activity. |
| **FINRA supervision rules** | Supervisory procedures and the requirement that someone is accountable. > **Verify:** applicable FINRA rules with compliance. |

**Adopt the Reg SCI posture even if you are not an SCI entity.** It is the
regulator's own articulated standard for running a critical trading system, and
the venue you connect to is bound by it. Concretely, that means: documented and
reviewable change management for every bitstream and every limit; pre-deployment
testing against a defined regression suite with a canary stage; capacity evidence
(for us, "sustains line rate", proven, not asserted); incident detection,
escalation, and post-mortem discipline; and business continuity for the loss of
the card, the host, or the site.

⚠️ **Do not let "we are not an SCI entity" become "we do not need change
management".** The rule's applicability is a legal question; the engineering
practice is justified on its own merits by [01-threat-model.md](01-threat-model.md) §4.

---

## 10. RULES FOR THIS PROJECT

1. **The strategy author does not set or approve the risk limits.** If the team is
   too small to separate cleanly, write down the compensating control.
2. **A risk-limit change is a standalone change.** Never bundled with a strategy
   change, an RTL change, or a deployment. Separate review, separate audit entry.
   (`host/README.md` §3.3 already says this — it is a governance rule, not a
   style rule.)
3. **Risk-reducing actions never require approval; risk-increasing actions always
   do.** No workflow may sit between an operator and the kill switch.
4. **Four-eyes on class A and B changes**, enforced in `ctrld`/`paramd`, backed by
   the fabric's refusal to accept a live risk-window write.
5. **Every change is verified by readback**, not by the absence of an error. The
   generation counter advanced and the checksum matches, or the change did not
   happen.
6. **No production credentials, comp IDs, session IDs, or venue IPs in the
   repository** — ever, including in tests, fixtures, comments, and commit
   messages.
7. **Archived pcaps of order-entry sessions are secrets** unless login frames are
   stripped. Decide which, and enforce it in the capture tooling.
8. **The change trail lives outside the trading host** and is retained per
   compliance's answer, not per engineering's guess.
9. **Host root access is equivalent to full control of the card.** Treat every
   package installed on the trading host as a trading-system component.
10. **Access is reviewed on a schedule and on every role change.** Someone who
    changed teams six months ago should not still be able to widen a limit.

---

## Further reading

- [01-threat-model.md](01-threat-model.md) — the insider and buggy-deployment adversaries this document constrains
- [02-supply-chain-and-bitstream-integrity.md](02-supply-chain-and-bitstream-integrity.md) — governance of the build pipeline
- [04-resilience-and-failure-isolation.md](04-resilience-and-failure-isolation.md) — what the system does when nobody is available to govern it
- [05-incident-preparedness.md](05-incident-preparedness.md) — kill authority and the 3am path
- [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md) — 15c3-5, Reg SCI, CAT, RTS 6 in more depth
- [../08-nasdaq/09-risk-controls-and-limits.md](../08-nasdaq/09-risk-controls-and-limits.md) §9 — operational governance of limits
- [../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md) §8 — release sign-off and named signers
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) §10 — audit logging of order decisions
