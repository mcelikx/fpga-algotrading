# 07.04 — Checklists

> **Why this matters here:** everything in these manuals is knowledge; this file is
> the part you actually execute. Checklists exist because under time pressure —
> a release window closing, a market open approaching, a position moving against
> you — human memory reliably drops exactly the step that would have saved you.
> Copy the relevant list into the PR, the ticket, or the incident doc, and tick the
> boxes for real.

**How to use these:** they are `- [ ]` task lists. Paste, tick, and attach the
completed list to the artifact it describes. An untickable item is a blocker, not
a judgement call. If an item genuinely does not apply, write *why* next to it
rather than deleting it.

Index: [1](#1-new-rtl-module-review) · [2](#2-testbench-completeness) ·
[3](#3-timing-closure) · [4](#4-cdc-review) ·
[5](#5-pre-synthesis--pre-implementation) · [6](#6-latency-budget-review) ·
[7](#7-pre-deployment--go-live-for-a-new-bitstream) ·
[8](#8-start-of-trading-day) · [9](#9-end-of-day) ·
[10](#10-incident-response) · [11](#11-post-incident-review) ·
[12](#12-new-venue--new-symbol-onboarding)

---

## 1. New RTL module review

**When:** on every pull request that adds or substantially changes a module in
`rtl/`. The reviewer works this list; the author pre-ticks it.

### Header and contract
- [ ] Module header states the **latency budget** in both nanoseconds and cycles.
- [ ] Module header states the **resource budget** (LUT/FF/BRAM/URAM/DSP).
- [ ] Every port has a comment: direction, width meaning, and units (shares? scaled price? cycles?).
- [ ] Every parameter has a legal range documented; illegal values trip an elaboration-time assertion.
- [ ] Fixed-point signals document their `Q<m>.<n>` format and scale factor.

### Structure
- [ ] All widths parameterized. No literal `64`, `8`, or `48` outside a parameter default.
- [ ] Outputs registered. Any combinational output port is justified in a comment.
- [ ] Reset is **synchronous, active-high**, applied only where needed (control/state, not bulk datapath).
- [ ] No inferred latches: every `always_comb` assigns every output on every path; every `case` has a `default`.
- [ ] `unique`/`priority` used deliberately, not decoratively.
- [ ] `always_ff` uses non-blocking `<=`; `always_comb` uses blocking `=`. No mixing.
- [ ] No `initial` blocks in synthesizable code.
- [ ] No `#delay` in synthesizable code.
- [ ] FSM states are an enum, not raw encodings; illegal-state recovery is explicit.

### Fast-path hard rules (`CLAUDE.md` §5)
- [ ] No dynamic memory; all storage statically sized at elaboration.
- [ ] No unbounded loops; every loop bound is a compile-time constant.
- [ ] No floating point.
- [ ] Module never asserts backpressure toward MAC RX — it drops and counts instead.
- [ ] Latency is **fixed**, not input-dependent. If it varies, the variation is documented and histogrammed.

### Safety and observability
- [ ] Every error condition has both a **sticky bit** and a **counter**.
- [ ] Every counter's width is sized for a full trading day at peak rate (or documented as wrapping, with host-side unsigned-delta handling).
- [ ] Every FIFO has a high-water-mark register.
- [ ] Every deliberate drop increments a per-stage drop counter.
- [ ] Arithmetic that can overflow either saturates explicitly or is sized for the true worst case — and saturation events are counted.
- [ ] Any signal crossing a clock domain uses a sanctioned primitive from `rtl/common/cdc/`. Nothing hand-rolled.
- [ ] If this module can influence an outbound order, it cannot bypass the risk gate. Confirm by inspection of the connectivity, not by intent.

### Review mechanics
- [ ] Verilator `-Wall` lint clean; any waiver is in `waivers/verilator.vlt` with an owner and reason.
- [ ] SVA assertions written for the module's key invariants and enabled in simulation.
- [ ] A second engineer has read the code, not just the diff summary.
- [ ] PR description states whether latency changed, and by how many cycles.

---

## 2. Testbench completeness

**When:** alongside checklist 1 — a module is not reviewable without its testbench.

- [ ] Reset behaviour: during reset, on the release edge, and asserted mid-transaction.
- [ ] Backpressure applied on every output interface, including a permanently-stalled downstream.
- [ ] Randomized backpressure patterns; output byte/word sequence identical regardless.
- [ ] Boundary inputs: zero-length, minimum, maximum, maximum+1 where representable.
- [ ] Every arithmetic value class: 0, 1, max, max−1, and the exact overflow point.
- [ ] **Cycle-exact latency assertion**: input at cycle N produces output at cycle N+K, asserted every transaction.
- [ ] Determinism: the same stimulus replayed produces identical outputs *and* identical timing.
- [ ] Every counter the module exposes is driven to increment at least once.
- [ ] Every sticky error bit is provoked at least once, and its clear path is tested.
- [ ] Every FSM state entered; every arc taken. Unreachable states removed or documented.
- [ ] Malformed/illegal input: module does not hang, does not corrupt neighbours, does count the event.
- [ ] Back-to-back transactions with no gap (throughput at II=1 where claimed).
- [ ] Maximum-burst stimulus at line rate for longer than the deepest FIFO.
- [ ] Golden-model comparison where a golden model exists; scoreboard mismatch prints the message index.
- [ ] Randomized/property test present for at least one non-trivial invariant.
- [ ] Coverage: statement/branch/toggle ≥ 95 %, with written justification for each gap.
- [ ] Test failures print the `RANDOM_SEED` so any failure is reproducible.
- [ ] Runs under Verilator with `--assert --x-assign unique --x-initial unique`.
- [ ] Module participates in the full-path integration test and the pcap replay regression.

---

## 3. Timing closure

**When:** post-route WNS is negative, or WNS regressed against the 7-day median.

### Before touching RTL
- [ ] Confirm this is a **post-route** number. Synthesis estimates do not count.
- [ ] Re-read the constraints. Is `create_clock` the frequency you actually need?
- [ ] Check for over-constraining. Are you chasing margin you do not need?
- [ ] `report_exceptions -ignored` — is a false path or multicycle silently dead?
- [ ] `report_clock_interaction` — is an intended-asynchronous crossing being timed synchronously?
- [ ] `report_timing_summary` check_timing section — any unconstrained paths or missing IO delays?
- [ ] Is the failing path inside the fast path or in the control plane? A control-plane path may want a `set_multicycle_path` instead of RTL work.

### Classify
- [ ] Record WNS, TNS, WHS, THS, and failing endpoint count verbatim.
- [ ] One path or many? (TNS ≈ WNS means one; TNS ≫ WNS means systemic.)
- [ ] Route-dominated (> 60 % route) or logic-dominated (high logic levels)?
- [ ] Logic levels on the worst path — recorded.
- [ ] Does the path cross an SLR? (`report_design_analysis`, or the SLR snippet in [03-toolchain-reference.md](03-toolchain-reference.md) §10.)
- [ ] Congestion level from `report_design_analysis` — is any region ≥ 5?
- [ ] Do the failing endpoints cluster in one module or one net?

### Fix, cheapest first
- [ ] Fixed the constraints, if they were the problem. (Free.)
- [ ] Added a pipeline stage at the failing point. (One cycle of latency — check the budget first.)
- [ ] Replicated the high-fanout driver / applied `MAX_FANOUT`.
- [ ] Registered BRAM outputs.
- [ ] Broke the wide combinational tree into pipelined stages.
- [ ] Rebalanced logic across an existing register.
- [ ] Precomputed anything not dependent on this cycle's input.
- [ ] Changed the data structure (incremental top-of-book rather than a full recompute).
- [ ] Banked contended memory instead of arbitrating.
- [ ] Floorplanned the fast path into one SLR near the transceivers.
- [ ] Tried alternative place/route directives across the sweep.

### Confirm
- [ ] **One change at a time.** Attribution is impossible otherwise.
- [ ] Both WNS **and** TNS improved. WNS alone can move by promoting a different path.
- [ ] Improvement holds across the seed sweep, not on one lucky run.
- [ ] Latency assertions still pass — a pipeline stage changed the cycle count somewhere.
- [ ] Utilization did not blow out to buy the timing.
- [ ] Result reported honestly: distribution across seeds, tool version, target frequency.

---

## 4. CDC review

**When:** any PR that adds a clock, a clock domain, or a signal crossing between
domains — and as a standing item before every release.

- [ ] `report_cdc` reviewed line by line. **Every entry explained in writing.** No entry dismissed as "probably fine".
- [ ] Zero "Critical" severity CDC findings, or each has a named waiver with a technical justification.
- [ ] Every single-bit control crossing uses the sanctioned 2-FF synchronizer from `rtl/common/cdc/`.
- [ ] Every multi-bit **bus** crossing uses a gray-coded async FIFO or a handshake — never per-bit synchronizers. ⚠️ Independently synchronizing the bits of a bus produces transient values that never existed.
- [ ] Every pulse crossing from fast to slow domain uses a toggle/handshake pulse synchronizer, not a raw 2-FF chain (a short pulse can be missed entirely).
- [ ] Async FIFO depths sized for the worst-case rate mismatch plus the synchronizer latency.
- [ ] `ASYNC_REG` (or the vendor equivalent) applied to every synchronizer flop so the tools place them adjacently.
- [ ] `set_clock_groups -asynchronous` (or explicit `set_max_delay -datapath_only`) declared for each genuinely asynchronous clock pair — and **not** a blanket `set_false_path` that hides real paths.
- [ ] Reset crossing handled: reset assertion may be asynchronous, de-assertion is synchronized into each domain.
- [ ] No combinational logic between a source register and the first synchronizer flop.
- [ ] Data stability: for handshake-based crossings, the data bus is proven stable for the full handshake duration by an assertion.
- [ ] Every CDC FIFO has an overflow counter and a sticky bit, even where overflow should be structurally impossible.
- [ ] Simulated with randomized clock phase relationships, not a fixed integer ratio.
- [ ] Long soak run completed; CDC-related counters and sticky bits all clean.
- [ ] Confirmed that the datapath itself is still **single clock domain** — CDC only at the MAC and PCIe boundaries (`CLAUDE.md` §4).

---

## 5. Pre-synthesis / pre-implementation

**When:** before kicking off a long implementation run, especially a nightly or a
release build. Ten minutes here saves a wasted four-hour run.

- [ ] Working tree clean; `git status` empty. A dirty build is not reproducible.
- [ ] `scripts/env.sh` sourced; tool version check passed.
- [ ] Correct part and speed grade in the command line, not inherited from a default.
- [ ] All RTL lints clean.
- [ ] All unit tests and the pcap replay short set pass.
- [ ] Every `.xci` IP file is the checked-in version; no `upgrade_ip` in the flow.
- [ ] Constraint files all listed in `build.tcl` — a forgotten `read_xdc` produces a design that "closes" because nothing was checked.
- [ ] Every constraint matches at least one object (run the dead-constraint check).
- [ ] Clock definitions match the actual design intent and the datapath width.
- [ ] Input and output delays specified for every top-level port. Unconstrained IO is unanalysed IO.
- [ ] Floorplan pblocks reference module names that still exist after the last refactor.
- [ ] Seed and directives explicitly specified, not left to defaults.
- [ ] Output directory is fresh; reports from a previous run cannot be mistaken for this one.
- [ ] Thread count pinned (`set_param general.maxThreads`).
- [ ] Disk space sufficient for checkpoints (they are large, and a full disk fails at `write_bitstream` after hours of work).
- [ ] For a release build: the build manifest generator is wired in and will capture git SHA, tool, seed, and constraint hash.

---

## 6. Latency budget review

**When:** at design time for every new block, and again whenever measured or
simulated latency moves.

- [ ] The end-to-end budget exists as a written table, stage by stage, in `docs/`.
- [ ] Every stage's number is labelled: **[EXACT]** (cycle arithmetic), **[SPEC]** (vendor/standard document, cited), **[OOM]** (estimate), **simulated**, or **measured (N=…)**.
- [ ] The Ethernet stack cost (PMA + PCS + FEC + MAC, both directions) is taken from the IP product guide for the **exact configuration** in use, not from a generic table.
- [ ] FEC is off where it is optional and the link quality permits — or its cost is explicitly accepted and recorded.
- [ ] MAC is cut-through, not store-and-forward.
- [ ] Measured intra-cage fibre lengths are in the budget, converted at 5 ns/m, counted for both directions.
- [ ] Every switch hop on the market data path and the order path is listed with its datasheet latency. Every avoidable hop has been challenged.
- [ ] The budget sums to less than the target with **reserve** — plan to spend ~75 % and keep the rest for closure (a late pipeline stage costs 6.4 ns).
- [ ] Each block's cycle count is asserted in its testbench, so a regression is a test failure and not a discovery.
- [ ] Jitter sources enumerated: arbitration, FIFO occupancy, message straddling a packet boundary, CDC, any stall-capable handshake. Each is histogrammed.
- [ ] p50 / p99 / p99.9 / max reported — never a mean alone.
- [ ] Nothing on the fast path touches the host over PCIe. Confirmed by inspection.
- [ ] Any variable-latency block has been evaluated against a fixed-latency alternative; determinism preferred unless the mean gain is large and documented.
- [ ] The measured wire-to-wire number is compared against the sum of the budget, and the discrepancy is explained. An unexplained gap means the budget is wrong.

---

## 7. Pre-deployment / go-live for a new bitstream

**When:** before a bitstream is loaded on a production trading host. **Every item
requires evidence, not recollection.** Two people sign this list.

### Build provenance
- [ ] Built from a clean, tagged commit; `git_dirty: false` in the manifest.
- [ ] Built by CI, not on a laptop.
- [ ] Tool version, part, seed, directives, IP versions, and constraint hash all recorded in `manifest.json`.
- [ ] Post-route WNS / TNS / WHS / failing-endpoint count quoted verbatim from the report.
- [ ] Seed sweep meets the project closure criterion (see [../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md) §6).
- [ ] `report_cdc`, `report_drc`, `report_methodology` clean or every waiver justified and owned.
- [ ] Utilization headroom recorded; no resource above the agreed threshold.

### Verification
- [ ] Full cocotb regression green.
- [ ] pcap replay regression bit-exact against the golden model over the full corpus.
- [ ] Fault-injection suite green; every required behaviour observed.
- [ ] Gate-level simulation run on this netlist.
- [ ] Hardware-in-the-loop run completed on the lab card with this exact bitstream.
- [ ] **Measured** (not simulated) wire-to-wire latency distribution recorded, with N and methodology stated.
- [ ] Soak run completed; zero unexplained counter movement, zero sticky bits set, latency stable from first hour to last.

### Risk and safety — the non-negotiable part
- [ ] Risk limits loaded and **read back and compared word for word**.
- [ ] For **each** limit independently — max order quantity, max notional per order, max long position, max short position, price collar, message rate limit, symbol whitelist, duplicate client order ID — a deliberately violating test order was injected in the loopback/UAT path and was **rejected**, with:
  - [ ] the correct reason code, and
  - [ ] the matching per-reason rejection counter incremented, and
  - [ ] `orders_emitted` unchanged.
- [ ] `risk_reject_total` equals the sum of the per-reason counters.
- [ ] Confirmed by inspecting connectivity that **no path emits an order without passing the risk gate**.
- [ ] Kill switch asserted under live loopback order flow: outbound flow stopped within the documented cycle bound, `kill_switch_activations` incremented, `kill_switch_latency_max_cyc` within spec.
- [ ] Kill switch verified reachable from **both** the host control process and the out-of-band path.
- [ ] Host watchdog verified: killing the host process blocks new orders within the documented threshold.
- [ ] Parameter double-buffering verified: a mid-write parameter update never produces a decision on a half-written table.

### Environment and rollback
- [ ] Build ID readback matches the host's expected value; host **refuses to arm** on mismatch (tested by deliberately configuring the wrong ID).
- [ ] Symbol table loaded and checksum-verified fabric-side against host-side.
- [ ] Venue conformance/certification still valid for every protocol-affecting change in this release; re-certification obtained if required.
- [ ] Configuration files point at the intended environment. ⚠️ Confirm explicitly that a UAT deployment cannot reach a production endpoint and vice versa.
- [ ] Rollback bitstream staged on the trading host's local disk; SHA256 verified.
- [ ] Rollback procedure rehearsed within the last quarter.
- [ ] Monitoring dashboards and alert rules updated for any new counters in this release.
- [ ] Canary plan written: symbol, size, limits, duration, supervisor, maximum acceptable loss.
- [ ] Release note describes the change in terms of **market behaviour**, not only RTL.
- [ ] Two named signers recorded.

---

## 8. Start-of-trading-day

**When:** before the market opens, every trading day. Finish well before the
pre-market session begins.

> **Verify:** US equities regular session hours (09:30–16:00 ET), pre-market and
> after-hours windows, and half-day/holiday schedules are set by the exchange.
> Confirm against the current **Nasdaq trading calendar**; do not hardcode a
> schedule from this manual.

### Hardware and platform
- [ ] Both power feeds present; PDU telemetry normal.
- [ ] Cage inlet temperature within SLA; FPGA die temperature nominal at idle.
- [ ] PCIe link present at the expected width and speed (`lspci` `LnkSta`).
- [ ] Card enumerated at the expected BDF and NUMA node.
- [ ] Host process pinned correctly; C-states and frequency settings as configured.

### Firmware and configuration
- [ ] Build ID read back and matches the expected release. **Mismatch = stop.**
- [ ] Uptime counter consistent with expectation (an unexpected reset means something reconfigured the device).
- [ ] Symbol table loaded for today's universe, including new listings and symbol changes; checksum verified.
- [ ] Strategy parameters loaded; parameter CRC verified fabric-side against host-side.
- [ ] Risk limits loaded and read back; spot-check at least one limit with a rejected test order in the loopback path.
- [ ] Kill switch tested and confirmed functional **today**, before arming.
- [ ] Reference prices / prior close data loaded where the strategy needs them.

### Connectivity and data
- [ ] Both market data feed sides (A and B) receiving; frame counters advancing.
- [ ] Sequence numbers advancing on both sides; zero gaps during the settling period.
- [ ] A/B arbitration win ratio roughly balanced.
- [ ] Order-entry session logged in; sequence state matches expectation.
- [ ] Backup order-entry session available.
- [ ] Drop-copy session up.
- [ ] PTP grandmaster locked to GNSS; offset-from-master and path delay nominal; holdover not engaged.

### State and counters
- [ ] All sticky error bits read, **logged**, then cleared for the new session.
- [ ] Counter baselines snapshotted so the day's deltas are meaningful.
- [ ] Latency histograms cleared at the session boundary.
- [ ] Position confirmed flat (or matching the expected overnight position) across fabric, host, drop copy, and clearing.
- [ ] Health register reads `ALL_OK`.

### Awareness
- [ ] Exchange notices / trader alerts reviewed for today: halts, symbol changes, protocol changes, IPOs, corporate actions.
- [ ] Known macro events and their times noted (expect message-rate spikes).
- [ ] Half-day / early close checked.
- [ ] Named human on point for the session; escalation path confirmed reachable.

### Arm
- [ ] Book compared against an independent software book for a set of reference symbols — they agree.
- [ ] Arm. Log who armed and when.

---

## 9. End-of-day

**When:** after the close, every trading day.

- [ ] Disarm. Confirm the armed bit is clear.
- [ ] Confirm zero resting orders at the venue: fabric view, host view, and drop copy all agree.
- [ ] Positions reconciled three ways: fabric ↔ host ↔ drop copy/clearing. **Any discrepancy is investigated today, not tomorrow.**
- [ ] PnL computed and compared against expectation; outliers explained.
- [ ] Fill count and filled shares reconciled against drop copy.
- [ ] All counters snapshotted and archived for the day.
- [ ] All sticky error bits read and logged. Any bit set that was clear at open gets a ticket.
- [ ] Latency histograms exported and archived; distribution compared against the trailing baseline.
- [ ] List every counter that stayed at zero all day and confirm each is expected.
- [ ] Audit log for the day closed, checksummed, and archived per the retention policy.
- [ ] Any venue rejects reviewed by reason code; anything unexpected ticketed.
- [ ] Any risk rejects reviewed; confirm each was intended behaviour and not a misconfigured limit.
- [ ] Sequence gap events for the day reviewed and explained.
- [ ] Die temperature maximum for the day recorded and compared to the trend.
- [ ] Link errors (CRC, FEC corrected, flaps) reviewed; any upward trend ticketed as a degrading optic.
- [ ] Log out of order-entry sessions cleanly.
- [ ] Tomorrow's symbol universe and any known corporate actions prepared.
- [ ] Handover note written if anyone else opens tomorrow.

---

## 10. Incident response

**When:** anything in production is behaving in a way you cannot immediately
explain. The bar is *unexplained*, not *obviously broken*.

> **The ordering below is the entire point of this checklist: stop first,
> understand second.** Every minute spent diagnosing while armed is a minute the
> system is trading on state you do not trust.

### Stop
- [ ] **1. HIT THE KILL SWITCH.** No discussion, no "let me just check one thing".
- [ ] 2. Confirm outbound order flow has actually stopped: `orders_emitted` frozen, `kill_switch_active` set.
- [ ] 3. If the kill switch did not take effect, use the out-of-band path. If that fails, log out the order-entry sessions. If that fails, call the venue's emergency desk.
- [ ] 4. Announce in the ops channel: what you saw, that the kill switch is on, who is on point.

### Contain
- [ ] 5. Determine the current position from **all three** sources: fabric, host, drop copy. Do not proceed on one source.
- [ ] 6. Enumerate resting orders at the venue and cancel them explicitly. Verify each cancel is acked — do not rely on cancel-on-disconnect.
- [ ] 7. Decide, with the trading owner, whether to flatten. Default to flattening if you cannot explain the state. **Losing money safely beats trading on state you do not trust.**
- [ ] 8. Do not restart, reprogram, or power-cycle anything yet — that destroys evidence.

### Preserve
- [ ] 9. Snapshot every counter, every sticky bit, and the health register **before** clearing anything.
- [ ] 10. Snapshot the latency histograms.
- [ ] 11. Copy the audit log and the packet captures for the incident window to a safe location.
- [ ] 12. Record: wall-clock time, build ID, parameter CRC, symbol table checksum, host software version.
- [ ] 13. Capture the venue's own view (drop copy, any exchange messages or notices).
- [ ] 14. Screenshot the dashboard.

### Diagnose
- [ ] 15. Read the sticky bits first — they tell you what happened, not what is happening.
- [ ] 16. Was there a sequence gap? Was it recovered?
- [ ] 17. Any unknown message types or length mismatches?
- [ ] 18. Any link errors, flaps, or FEC activity?
- [ ] 19. Did the book diverge from the independent software model, and from when?
- [ ] 20. Did latency change before the symptom appeared?
- [ ] 21. Did anything change today — bitstream, parameters, symbol table, host software, network, venue notice?
- [ ] 22. Is the venue itself having a problem? Check exchange status and other participants' symptoms.

### Recover
- [ ] 23. Root cause identified, or an explicit decision taken to stay down until it is.
- [ ] 24. Fix applied, or rollback executed per the rollback procedure.
- [ ] 25. Full start-of-day checklist (§8) re-run before re-arming. Not a subset of it.
- [ ] 26. Re-enter via the single-symbol canary, minimum size — **never** straight back to full universe.
- [ ] 27. Supervised for a full session before returning to normal operation.

### Report
- [ ] 28. Notify compliance and any regulatory/venue contacts as required by your firm's procedures.
- [ ] 29. Timeline written while it is fresh, before anyone goes home.

---

## 11. Post-incident review

**When:** within a few business days of any incident, including near-misses that
cost nothing.

- [ ] Blameless. The output is a list of system changes, not a list of people.
- [ ] Timeline reconstructed to the second from the audit log and counter snapshots — not from memory.
- [ ] Root cause identified to the level of a specific line of RTL, a specific config value, or a specific procedural gap. "Human error" is not a root cause; it is a request for a better system.
- [ ] Contributing factors listed separately from the root cause.
- [ ] **Detection**: how long between the fault starting and anyone noticing? What would have caught it sooner? Is that a new counter, a new alert, or a new dashboard element?
- [ ] **Was there a counter for this?** If not, add one. This is the most common and most valuable output of a review in this project.
- [ ] **Was there an alert for this?** If it existed but did not fire, why? If it fired but was ignored, why?
- [ ] **Was there a test for this?** Add the failing case to the regression suite and, where applicable, to the pcap corpus — permanently, with a comment naming this incident.
- [ ] Could the fault have been caught by lint, by simulation, by the golden-model comparison, by fault injection, or by the seed sweep? Whichever layer missed it gets strengthened.
- [ ] Blast radius reviewed: were the risk limits sized so the worst case was survivable? Should they change?
- [ ] Kill switch performance reviewed: did it work, how fast, was it reachable?
- [ ] Rollback reviewed: was it available, current, and rehearsed?
- [ ] Financial impact quantified and recorded.
- [ ] Compliance notified of the outcome; any required reporting completed.
- [ ] Action items have named owners and dates. Items without both do not exist.
- [ ] Manuals updated: if a document in `manuals/` was wrong, misleading, or silent on this, fix it in the same week.
- [ ] Review the review: did checklist §10 work? Amend it here.

---

## 12. New venue / new symbol onboarding

**When:** adding a trading venue, a new protocol version, or extending the symbol
universe. Symbols are cheap; venues are not — do the whole list for a venue.

### New venue or new protocol version
- [ ] Authoritative specifications obtained directly from the venue, current revision, with revision date recorded.
- [ ] Commercial and regulatory prerequisites complete: membership or sponsored access, MPID, market data agreements, reporting arrangements.
  > **Verify:** requirements differ for a member firm versus a sponsored-access customer, and sponsored access carries specific obligations under **SEC Rule 15c3-5**. Confirm the applicable set with compliance.
- [ ] Connectivity ordered: colocation space, cross-connects, ports for market data, order entry, backup order entry, drop copy, retransmission/snapshot.
- [ ] Measured (not ordered) fibre lengths recorded and added to the latency budget.
- [ ] Test-environment credentials obtained; endpoints stored in the **test** config file only.
- [ ] Decoder implemented from the spec, with a golden vector per message type traceable to a spec section.
- [ ] Encoder implemented from the spec, verified byte-exact against golden vectors.
- [ ] Session layer implemented: login, sequencing, heartbeats, logout, reconnect and replay.
- [ ] Every venue reject reason code enumerated and handled; a counter exists per reason.
- [ ] Venue-specific market structure rules understood and enforced: tick sizes, price bands / LULD, halt states, short-sale restrictions, self-match prevention, order type semantics, cancel-on-disconnect behaviour.
- [ ] Golden software model extended to the new venue; pcap corpus captured from the venue's test or production feed.
- [ ] Conformance rehearsal harness run locally against the venue's published test script.
- [ ] **Venue conformance/certification completed and the confirmation filed in `docs/`**, referencing the bitstream version tested.
- [ ] Risk limits defined for the new venue, including venue-specific message-rate limits.
- [ ] Monitoring extended: per-venue counters, dashboards, and alert rules.
- [ ] Emergency contacts recorded and **printed in the cage**: venue trading desk, emergency cancel line, connectivity support.
- [ ] Runbooks updated: start of day, end of day, incident response.
- [ ] Canary plan for the new venue: one symbol, minimum size, supervised.
- [ ] ⚠️ Explicitly confirmed that no build or configuration points at the live venue until every item above is ticked (`CLAUDE.md` §6).

### New symbol
- [ ] Symbol present in the venue's directory data with the expected attributes (round lot size, market category, financial status, ETP flags).
- [ ] Tick size / price increment rules confirmed for this symbol.
- [ ] Symbol added to the fabric symbol table; hash collisions checked and within the acceptable rate.
- [ ] Reference price / prior close loaded.
- [ ] Book depth allocation sufficient for this symbol's typical depth.
- [ ] Message rate for this symbol estimated from a capture; FIFO and throughput headroom confirmed.
- [ ] Per-symbol risk limits set: max position, max notional, price collar.
- [ ] Locate arranged if short selling is intended.
  > **Verify:** locate and close-out requirements are governed by **Regulation SHO**; the short-sale price test (Rule 201) may restrict short sales after a significant intraday decline. Confirm with compliance.
- [ ] Corporate actions checked: splits, dividends, symbol changes, mergers — each of which changes reference data mid-life.
- [ ] Strategy parameters tuned and reviewed for this symbol; not copied blindly from another.
- [ ] Backtested / replayed against corpus data including this symbol.
- [ ] Enabled as a canary at minimum size before full size.
- [ ] Dashboards and per-symbol alerts include it.

---

## Further reading

- [01-glossary.md](01-glossary.md) — terminology used throughout these lists
- [02-latency-reference-numbers.md](02-latency-reference-numbers.md) — numbers for checklist 6
- [03-toolchain-reference.md](03-toolchain-reference.md) — commands for checklists 3 and 5
- [../00-foundations/04-clocking-reset-and-cdc.md](../00-foundations/04-clocking-reset-and-cdc.md) — the reasoning behind checklist 4
- [../00-foundations/05-timing-closure.md](../00-foundations/05-timing-closure.md) — the reasoning behind checklist 3
- [../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md) — release sign-off behind checklist 7
- [../06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md) — deployment runbook and DR
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) — the counters and alerts these lists depend on
- [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md) — the reasoning behind checklists 1, 2 and 7
