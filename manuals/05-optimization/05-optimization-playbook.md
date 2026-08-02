# 05.05 — Optimization Playbook

> **Why this matters here:** this is the working document for the optimization
> phase. It is an ordered checklist, cheapest-and-highest-yield first, and it is
> meant to be worked through top-to-bottom rather than cherry-picked. The ordering
> is not aesthetic — it reflects that a change request to shorten a cross-connect
> beats three weeks of pipeline surgery by an order of magnitude, and that **you are
> not allowed to skip Tier 0**.

**All gain figures below are ESTIMATES** for this system's defaults (10GbE,
156.25 MHz core clock, 6.4 ns/cycle, UltraScale+, ITCH 5.0 in / OUCH 5.0 out).
They exist to *order the work*, not to be quoted. Every one must be replaced with a
measured number using
[04-measurement-and-profiling.md](04-measurement-and-profiling.md) before it goes
in a report.

---

## Tier 0 — Measure and attribute. Do nothing else first.

> **Gate:** you may not open Tier 1 until you have a per-stage latency breakdown
> from hardware. This is not a formality. Teams routinely discover that the stage
> they were about to optimize accounts for 3 % of the budget.

| # | Action | Output | Why it's first |
| --- | --- | --- | --- |
| 0.1 | Build the tap rig: passive/L1 tap both directions, one capture device, one clock, matched fibres | A wire-to-wire p50/p99/p99.9/max | Everything downstream is compared against this |
| 0.2 | Calibrate the rig (loopback, known-length, asymmetry, repeatability) | Rig offset + **noise floor** | Any "improvement" below the noise floor is imaginary |
| 0.3 | Instrument the fabric: free-running counter, ingress/egress timestamps, per-stage `lat_hist` | Per-stage attribution at line rate | The tap gives the total; only this gives the *breakdown* |
| 0.4 | Echo the trigger ID into the outbound order token | Exact trigger↔order pairing | Nearest-preceding pairing corrupts the tail |
| 0.5 | Capture a real market-open pcap and build a deterministic line-rate replay | A repeatable load | Idle-feed measurements are fiction |
| 0.6 | Fill in the budget table in [01-latency-budgeting.md](01-latency-budgeting.md) §3 with **measured** values | The live budget | You now know which lines are worth attacking |
| 0.7 | Classify every line: controllable / physical / uncontrollable / mandatory | The work list | Stops you attacking the speed of light |

> ⚠️ **The most common failure of an optimization phase is doing Tier 2 work on a
> stage that Tier 0 would have shown to be irrelevant.** Cost of Tier 0: one to
> three weeks. Cost of skipping it: the whole phase.

---

## Tier 1 — Free wins (configuration, not architecture)

Changes that cost little engineering, touch little RTL, and often return more than
all of Tier 3 combined.

| # | Technique | Expected gain (est.) | Cost / risk | How to verify |
| --- | --- | --- | --- | --- |
| 1.1 | **Shorten the cross-connect** — reposition the cage, re-run the fibre | **~9.8 ns per metre saved** (4.9 ns/m × both directions) | A change request; possibly a contract negotiation | Known-length method, §4 of [04-measurement...](04-measurement-and-profiling.md) |
| 1.2 | **Remove a switch hop** from the feed or order path | **~600–1000 ns** for a ToR-class cut-through hop in each direction; ~180–260 ns for a low-latency L2; ~8–10 ns for an L1 | Redundancy/topology redesign; ops buy-in | Tap on both sides of the hop |
| 1.3 | **Cut-through MAC** instead of store-and-forward | **~50–150 ns** each way, = frame serialization you stop waiting for (a 100 B frame is 80 ns) | You act before FCS validation — **you must still check FCS and count failures** | MAC IP config + tap A/B |
| 1.4 | **Low-latency GT configuration**: bypass TX and RX buffers, minimal gearbox, use `RXOUTCLK` directly | **~20–60 ns** round trip | Requires phase alignment and a common reference clock; link-stability risk | UG578 latency tables, then tap A/B and a soak for link errors |
| 1.5 | **Remove store-and-forward FIFOs in your own RX path** (anything that waits for EOF before forwarding) | **~50–1200 ns** depending on frame size | Must handle truncated/errored frames downstream | RTL review + per-stage histogram |
| 1.6 | **Disable RS-FEC** (25GbE only — 10GBASE-R has none to disable) | **~100+ ns each way** | Link margin; only at short reach; requires switch/venue agreement | IEEE 802.3 Clause 91 + measure + BER soak |
| 1.7 | **Faster speed grade** (-2 → -3) | 0 ns directly; **~10–15 % Fmax**, which typically buys back **1–2 closure-driven pipeline stages = 6.4–12.8 ns** | Part cost; check it is a drop-in for your board | Rebuild, count deleted stages, directive sweep |
| 1.8 | **Turn off unused MAC/IP features** in the datapath: VLAN insert, padding, in-band timestamp insertion, jumbo support | **~6–20 ns** | Confirm you don't need them | IP config diff + histogram |
| 1.9 | **Strip debug cores from the production bitstream** | Indirect: placement/routing relief, often **0–13 ns** and a tail improvement | Two build configs to maintain | Rebuild + re-measure (§6 of [03-resource...](03-resource-power-optimization.md)) |
| 1.10 | **Passive optical tap instead of an active inline tap** in the production path | **~4–5 ns** each way | Optical power budget | Link margin check + measure |

> ⚠️ **Do not** "optimize" by shortening the preamble, the inter-frame gap, or the
> minimum frame size. These are IEEE 802.3 requirements; violating them produces a
> link that works on the bench and fails conformance, or worse, works until the
> venue's switch is upgraded.

> **Verify:** every figure in this tier is an estimate of a *product class*. Take
> GT and PCS latency from **UG578**/**UG576**, MAC latency from your Ethernet IP
> product guide (e.g. **PG210**), switch latency from the vendor's port-to-port
> spec for your exact model and frame size — then **measure on your hardware**.

---

## Tier 2 — Architectural (restructure what is computed)

The highest-yield RTL work. All of these change *what* the design does, not just
how fast it runs, so they cost design time but usually **zero latency to close**.

| # | Technique | Expected gain (est.) | Cost / risk | How to verify |
| --- | --- | --- | --- | --- |
| 2.1 | **Dedicated TX port/MAC for orders** — nothing else ever transmits on it | Removes up to **1200 ns** of worst-case TX-occupancy jitter (a 1500 B frame in flight) | An extra port and cross-connect | p99.9/max on the burst load profile |
| 2.2 | **Direct-index symbol lookup** — use the ITCH 5.0 16-bit stock locate as a memory address; no hash, no probe | **13–26 ns** (2–4 cycles) **and eliminates variable-latency probing** | Memory sized for the locate space; see §9 of [03-resource...](03-resource-power-optimization.md) | Per-stage histogram: the lookup stage becomes fixed-width |
| 2.3 | **Pre-built per-symbol order templates** — read + splice ~10 mutable bytes instead of serializing a message | **19–51 ns** (3–8 cycles) | ~114 BRAM36 at 8192 symbols; template coherency protocol | Per-stage histogram on the encode stage |
| 2.4 | **Precomputed per-symbol limits** — host computes `limit_qty = notional / price_ref`; fabric does one compare instead of a multiply | **19–26 ns** (a registered DSP multiply is 3–4 cycles) | ⚠️ Table updates must be atomic or you trade on a torn limit | Histogram + a torn-update assertion in the testbench |
| 2.5 | **Incremental top-of-book** — maintain the inside on every update instead of recomputing a max over the book | **13–26 ns** (2–4 cycles) and removes a wide reduction from the critical path | Book update logic gets more state to get right | Histogram + book-equivalence regression vs a reference model |
| 2.6 | **Widen the datapath so the trigger message lands in one beat** | **13–32 ns** (2–5 cycles of reassembly) and deletes the straddle state machine | Area, barrel shifter, congestion. ⚠️ **Never width-convert twice** | Histogram on deframe/decode; check congestion didn't regress |
| 2.7 | **Parallel multi-message decode within a MoldUDP64 datagram** | Tail only, but large: **50–200 ns at p99.9** (removes the "message N of M" penalty) | Significant decoder complexity | p99.9 on the compressed-open replay |
| 2.8 | **Speculative order encode** — build both buy and sell candidates during the book update, discard one when the strategy resolves | **6.4–19 ns** (1–3 cycles) | ~2× encode area; both candidates must be risk-checked or the survivor must be | Histogram; assertion that the discarded path can never reach TX |
| 2.9 | **Early symbol filtering** — drop untraded symbols at the decoder | ~0 ns at p50; **10–50 ns at p99.9** via reduced contention and congestion | A wrongly-filtered symbol is invisible until you miss a trade | p99.9 comparison + a filter-coverage test |
| 2.10 | **Trigger on an earlier field in the message** | Up to **~30 ns** of serialization you stop waiting for | ⚠️ **This is a trading decision, not an RTL one.** It changes what the strategy knows. | Requires strategy sign-off; then measure S2 in the budget |
| 2.11 | **LUTRAM hot tier** for the top ~256 symbols' top-of-book and templates | **6.4 ns** (1 cycle) on the names you actually trade | ~0.5 k LUTs; a two-tier coherency problem | Histogram split by symbol tier |

---

## Tier 3 — Pipeline surgery

Individually small, collectively meaningful. Each item is one cycle: **6.4 ns**.
Do these *after* Tier 2, because Tier 2 often deletes the stage you were about to
tune.

| # | Technique | Expected gain (est.) | Cost / risk | How to verify |
| --- | --- | --- | --- | --- |
| 3.1 | **Rebalance stages** (move logic across a register, or let retiming do it) | 0 ns latency, but frees timing that lets you delete a stage elsewhere | ⚠️ Retiming relocates registers — breaks ILA probes and register-named constraints | `report_design_analysis -logic_level_distribution` before/after |
| 3.2 | **Merge two shallow adjacent stages** | **6.4 ns** each | Deepens the combined cone; may not close | Post-route WNS across the directive sweep + histogram |
| 3.3 | **Remove skid buffers where backpressure is impossible** | **6.4 ns** each | ⚠️ **Prove** it is impossible with an assertion, don't assume. An overrun here is silent data loss. | Formal or exhaustive assertion + line-rate soak with drop counters at zero |
| 3.4 | **Fold the BRAM output register into the consumer's logic** (use LUTRAM instead where the table is small) | **6.4 ns** | Only for small hot tables; ⚠️ never for the deep book | Histogram + WNS |
| 3.5 | **Common-case bypass path** (e.g. an `Add Order` that doesn't change the inside skips the recompute) | **6.4–12.8 ns** on the common case | ⚠️ **Creates variable latency.** Only acceptable if the slow case is off the trigger path and is counted. | p50 vs p99.9 both — reject if the tail worsens |
| 3.6 | **Delete the width converter** if the MAC width and core width can be made equal | **6.4–51.2 ns** (a 64→512 gearbox must accumulate 8 beats) | Architectural ripple | Histogram on the MAC RX stage |
| 3.7 | **Make the risk gate faster without making it weaker** — replace runtime arithmetic with precomputed comparisons, keep the same checks | 0–6.4 ns | ⚠️ The *checks* may not be reduced, reordered out of the path, or made bypassable. See §8. | Risk-equivalence test vector suite must pass unchanged |

---

## Tier 4 — Physical implementation

These rarely reduce latency directly. They **buy back the cycles that closure
would otherwise cost you**, and they fix the tail.

| # | Technique | Expected gain (est.) | Cost / risk | How to verify |
| --- | --- | --- | --- | --- |
| 4.1 | **Floorplan the fast path into one SLR near the GT quads** | 0–13 ns (avoided closure stages) + large tail/consistency gain | Must be done early; retrofitting at 80 % complete is weeks | Post-route WNS across the sweep; zero SLR crossings |
| 4.2 | **Evict the slow path (PCIe, telemetry, logging, session state) to another SLR** | Often the difference between closing and not | Requires clean fast/slow partitioning in RTL | Congestion level in the fast pblock; WNS |
| 4.3 | **Reduce fast-path pblock occupancy to ≤ 60 % LUT** | Congestion relief → shorter routes | Area work (Tier 5 of [03-resource...](03-resource-power-optimization.md) §5) | `report_utilization -pblocks` + congestion report |
| 4.4 | **High-fanout replication** (`MAX_FANOUT`, manual + `DONT_TOUCH`, partitioned loads) | Closure enabler; typically 0.1–0.5 ns WNS | ⚠️ Replication without partitioning the loads does nothing | `report_high_fanout_nets` before/after; WNS |
| 4.5 | **Directive/strategy sweep** (≥ 8 combinations) | 0.1–0.3 ns WNS; occasionally converts to a deleted stage | Build farm time | Distribution of WNS across runs — **not the best run** |
| 4.6 | **Enable `phys_opt_design` and post-route `phys_opt`** with several directives | 0.1–0.4 ns WNS | Runtime | Same |

> ⚠️ **One lucky build is not closure.** A design that closes on 1 of 20 runs will
> fail the next time someone edits a comment. Require WNS ≥ +0.150 ns on the *worst*
> run of the sweep. See §9.2 of
> [02-fmax-and-timing-optimization.md](02-fmax-and-timing-optimization.md).

---

## Tier 5 — Aggressive / advanced

Real techniques used in production systems. Each carries a correctness, compliance,
or operational risk that must be signed off explicitly.

| # | Technique | Expected gain (est.) | Cost / risk | How to verify |
| --- | --- | --- | --- | --- |
| 5.1 | **Speculative transmission with frame abort** — begin streaming the outbound frame's invariant leading bytes (Ethernet + IP + UDP + OUCH header ≈ 42+ B) before the decision resolves; deliberately corrupt the FCS to abort | **~34–60 ns** | ⚠️ **Requires written venue approval.** Invalid frames may trip error-rate thresholds or a disconnection policy. Also requires that the aborted frame can never be interpreted as an order. | Venue sign-off in writing; conformance test; count aborts as a first-class metric |
| 5.2 | **Bypass the book entirely for a pure top-of-book trigger** — the strategy reads the inside directly from the decode stage | **13–26 ns** (2–4 cycles) | The strategy loses depth information; book still maintained in parallel for the slow path | Strategy equivalence backtest + histogram |
| 5.3 | **Dedicated per-symbol datapaths** for the highest-value names — a replicated fixed-function pipeline per symbol, no lookup, no arbitration | **13–26 ns** + eliminates arbitration jitter for those names | Area × N; a deployment/config problem (which symbols, changed how often?) | Histogram split by symbol; congestion check |
| 5.4 | **Fixed-function datapath for the one message type you trade on**, general decoder in parallel for everything else | **6.4–19 ns** | Two decoders to keep consistent; ⚠️ divergence between them is a silent correctness bug | Differential test: both decoders on the same replay must agree |
| 5.5 | **Act on pre-MAC bytes** — trigger off the PCS/descrambled stream before MAC framing completes | **6.4–13 ns** | ⚠️ You are acting on unframed, unvalidated data. Requires downstream reconciliation and a hard error path. | Fault-injection test with corrupted frames; count every mis-trigger |

> ⚠️ **Tier 5 items are the ones that lose money when they are wrong.** None of them
> may be enabled by default. Each gets a runtime enable bit, a counter, and an
> explicit go-live decision.

---

## Tier 6 — Non-FPGA (usually the largest numbers in the building)

| # | Technique | Expected gain (est.) | Cost / risk | How to verify |
| --- | --- | --- | --- | --- |
| 6.1 | **Colocate** at the venue's data centre instead of a nearby facility | **10²–10⁴ µs** — dwarfs the entire FPGA budget | Cost, contracts | Tap measurement from both sites |
| 6.2 | **Direct venue feed instead of a consolidated/SIP feed** | **10²–10⁵ µs** | Cost, feed handling work, entitlements | Compare timestamps of the same event on both feeds |
| 6.3 | **Cross-connect routing and rack position** — shortest physical path to the meet-me room | **~9.8 ns per metre saved** (both directions) | Change request; sometimes a cage move | Known-length calibration + tap |
| 6.4 | **Cable choice** — passive DAC/twinax at short reach instead of optics | **~10–30 ns** total (skips the optical PMD at each end; ~4.3 vs ~4.9 ns/m propagation) | Reach limit (a few metres); link margin | Tap A/B with matched lengths |
| 6.5 | **L1 replication for feed distribution** instead of a switch | **~300–500 ns** per hop replaced | Device cost; no L2 features | Tap either side |
| 6.6 | **A/B feed line diversity and physical path symmetry** | Tail: reduces A/B skew, which is a p99.9 driver | Ops complexity | A/B skew histogram |

> **Verify:** all Tier 6 numbers are order-of-magnitude estimates that depend
> entirely on your facility, venue, and equipment. Every one is measurable with the
> tap method; **measure, don't assume**, before spending money.

---

## 7. Where the effort actually pays — the ordering, in one picture

```
  gain
  (ns)
  10000 ┤ ●  6.1 colocation / 6.2 direct feed
        │
   1000 ┤   ●  1.2 remove a switch hop
        │    ● 2.1 dedicated TX port (tail)
        │
    100 ┤      ● 1.1/6.3 shorten the cross-connect (per 10 m)
        │       ● 1.3 cut-through MAC   ● 1.4 GT low-latency
        │        ● 2.3 order templates  ● 5.1 speculative TX
        │
     10 ┤          ● 2.2 direct index  ● 2.5 incremental TOB  ● 2.6 widen
        │            ● 3.x pipeline surgery (6.4 ns each)
        │
      1 ┤                ● 4.x floorplan / directive sweep (indirect)
        │
      0 ┴──────────────────────────────────────────────────────────────►
          days              weeks             months        engineering effort
```

Read it as: **the curve is not smooth and it is not monotonic in effort.** The
biggest wins are cheap and non-technical; the expensive wins are small.

---

## 8. What NOT to optimize

These are off-limits. Not "optimize carefully" — off-limits. Making any of them
faster by making it weaker is a defect, not an improvement, and will be rejected in
review regardless of the latency gain.

| Never remove, weaken, bypass, or make optional | Why | You *may* |
| --- | --- | --- |
| **The hardware pre-trade risk gate** | [CLAUDE.md](../../CLAUDE.md) §5, and the market access rule. There is no software path that emits orders without it. | Make it faster with precomputed comparisons (3.7), keeping every check |
| **The kill switch** | A single register write must stop all outbound flow in a bounded, documented number of cycles | Reduce the bound, and document it |
| **Drop, error, and reject counters** | Silent failure is the worst failure mode in this domain | Move the counters off the critical path (they should already be) |
| **Sequence gap detection on the feed** | Trading on a gapped book is trading on fiction | Detect in parallel with the fast path rather than in series |
| **FCS / CRC checking** | Cut-through means you *act* before validation — it does not mean you *skip* validation | Act cut-through, validate after, count every failure, and reconcile |
| **A/B feed arbitration correctness** | Picking the wrong line silently corrupts the book | Optimize the arbiter's latency, not its logic |
| **Self-match prevention and venue-mandated checks** | Conformance and regulatory | Precompute the inputs |
| **Compliance timestamping and audit trail** | RTS 25 / Reg SCI class obligations | Move it off the fast path entirely |
| **Reset and initialization sequencing** | A fast path that comes up in an undefined state at 09:30:00 is worse than a slow one | — |
| **The measurement instrumentation itself** | You will need it more than any 6.4 ns it costs — and it costs ~0 on the datapath | — |

> ⚠️ **The seductive version of this mistake** is not "delete the risk gate". It is
> "move the risk check to run in parallel with the encode and merge the result at
> TX". That sounds fine and is fine — *only* if the frame provably cannot leave the
> MAC before the risk result arrives. Prove it with an assertion and a fault
> injection test, or don't do it.

---

## 9. Diminishing returns — knowing when to stop

Stop conditions, any one of which means the phase is over:

| Stop condition | Test |
| --- | --- |
| **The controllable fraction is small.** | If fabric is 15 % of wire-to-wire, halving it gains 7.5 %. Compute the fraction before starting the next item. |
| **The next item's estimated gain is below the rig noise floor.** | You cannot prove it worked; therefore it did not. |
| **The next item's gain is below one cycle (6.4 ns).** | You cannot spend less than a cycle. Sub-cycle "gains" are closure margin, not latency. |
| **The tail stopped improving two items ago.** | Determinism is the goal. If p99.9 is flat, you are polishing p50 for nothing. |
| **The physical lines are still unoptimized.** | If there is a 30 m cross-connect or a switch hop left in the path, **stop RTL work and go fix that.** |
| **The change increases the number of things that can be silently wrong.** | Complexity has a cost that does not appear in the histogram. |

**The canonical failure mode**, stated plainly:

> You spend a month merging two pipeline stages to save 6.4 ns, ship it, and remain
> 300 ns behind a competitor whose cage is 60 m closer to the meet-me room. Your
> RTL is better than theirs. You still lose every trade.

Before every optimization sprint, recompute the split from §3 of
[01-latency-budgeting.md](01-latency-budgeting.md):

```
  fibre + optics    : ___ ns  (___ %)   ← who owns fixing this?
  serialization     : ___ ns  (___ %)   ← uncontrollable, subtract and move on
  SerDes + PCS + MAC: ___ ns  (___ %)   ← configuration, Tier 1
  our fabric        : ___ ns  (___ %)   ← the only part RTL work can touch
```

If the last line is under ~20 % and the first line is over ~40 %, **the next sprint
is a facilities sprint, not an engineering sprint.**

---

## 10. One-page optimization session checklist

Print this. Work down it. One change per session.

```
── BEFORE ────────────────────────────────────────────────────────────────
[ ] Latency budget open, measured values current (not older than this build)
[ ] Per-stage histogram dump from the current production bitstream, saved
[ ] Rig calibrated this week: offset ___ ns, noise floor ___ ns
[ ] Replay file pinned (name + hash): ______________________
[ ] Baseline recorded: p50 ___  p99 ___  p99.9 ___  max ___  N ___
[ ] Baseline built across >=8 directives; worst-run WNS ___ ns
[ ] Target line identified from the budget, and it is CONTROLLABLE
[ ] Chosen technique's tier is <= any un-attempted lower tier

── HYPOTHESIS ────────────────────────────────────────────────────────────
[ ] Stage: ____________  Current: ___ ns / ___ cycles
[ ] Technique (tier + number): ____________
[ ] Predicted gain: ___ ns   Predicted p99.9 effect: ___ ns
[ ] Predicted cost: ___ LUT / ___ BRAM / ___ congestion level
[ ] Written down BEFORE building. A prediction made after the fact is a story.

── CHANGE ────────────────────────────────────────────────────────────────
[ ] Exactly ONE change
[ ] Module header budget updated (latency, jitter, reserve)
[ ] Debt ledger entry if this spends a cycle anywhere
[ ] Unit testbench passes; regression passes; assertions unchanged or added
[ ] Risk gate untouched, or risk-equivalence suite passes unchanged
[ ] Production build config (no debug cores)

── BUILD ─────────────────────────────────────────────────────────────────
[ ] >=8 directive combinations
[ ] Worst-run WNS >= +0.150 ns   (actual: ___)
[ ] Fast-path SLR crossings = 0  (actual: ___)
[ ] Fast-path pblock LUT occupancy <= 60 %  (actual: ___)
[ ] Worst congestion level in the fast pblock <= 4  (actual: ___)
[ ] Debug cores in bitstream = 0

── MEASURE ───────────────────────────────────────────────────────────────
[ ] Same replay file, same rig, same day if possible
[ ] N >= 1e6 trigger events
[ ] Load profiles: idle / open-original / open-compressed / burst
[ ] p50 ___  p99 ___  p99.9 ___  max ___  histogram overflow ___
[ ] Per-stage histograms: did the TARGET stage move? Did anything else?
[ ] Junction temperature ___ °C

── DECIDE ────────────────────────────────────────────────────────────────
[ ] Effect size >= 6.4 ns at p50 AND > noise floor?           yes / no
[ ] p99.9 no worse?                                           yes / no
[ ] Holds across the whole directive sweep?                   yes / no
[ ] Prediction matched? If not, do you understand why?        yes / no
        → If any "no": REVERT. Complexity without measured benefit is a defect.
        → If all "yes": commit, update the budget, update the debt ledger,
          record the new baseline, and close the session.

── RECORD ────────────────────────────────────────────────────────────────
[ ] Result appended to docs/latency-history.md with build hash + tool version
[ ] Budget table updated (measured, not predicted)
[ ] Next session's target chosen from the updated budget, not from memory
```

---

## Further reading

- [01-latency-budgeting.md](01-latency-budgeting.md) — the budget these techniques are aimed at
- [02-fmax-and-timing-optimization.md](02-fmax-and-timing-optimization.md) — Tier 3 and Tier 4 in detail
- [03-resource-power-optimization.md](03-resource-power-optimization.md) — congestion, SLR discipline, thermals
- [04-measurement-and-profiling.md](04-measurement-and-profiling.md) — Tier 0, and the verification column of every table above
- [../01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) — precompute, speculation, width vs depth
- [../04-system-architecture/01-tick-to-trade-pipeline.md](../04-system-architecture/01-tick-to-trade-pipeline.md) — the stages being optimized
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — why §8 is non-negotiable
- [../06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md) — the Tier 6 items in practice
- [../07-reference/02-latency-reference-numbers.md](../07-reference/02-latency-reference-numbers.md) — order-of-magnitude sanity checks
