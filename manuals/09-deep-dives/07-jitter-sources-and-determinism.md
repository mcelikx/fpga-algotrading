# 09.07 — Jitter Sources and Determinism

> **Why this matters here:** `rtl/fpga_top.sv` marks every stage `fixed` or `var`, and
> exactly **one** row is `var`. That column is the whole design philosophy compressed into
> one character per line. This document is why the column exists, what each `fixed` costs
> to keep fixed, what the single `var` is allowed to cost, and — the part that is usually
> skipped — how you *attribute* a bad p99.9 to a stage instead of staring at it.
> [04.01](../04-system-architecture/01-tick-to-trade-pipeline.md) §5 lists the jitter
> sources; [05.01](../05-optimization/01-latency-budgeting.md) §5–§6 budgets them. This is
> the deep dive that gives each one a mechanism, a magnitude, a detector, and a mitigation.

---

## 1. Two things are called "jitter". Only one of them is this document.

| Term used here | Definition | Units | Where it lives |
| --- | --- | --- | --- |
| **Clock jitter** | Phase noise on a clock edge — the deviation of an actual edge from its ideal time. Random (RJ) + deterministic (DJ). | **picoseconds** | `clk_rst_gen`, the GT reference clock, the MMCM. Eats setup margin. [00.05](../00-foundations/05-timing-closure.md) |
| **Latency dispersion** | The distribution, across events, of wire-to-wire tick-to-trade for *this* system. | **nanoseconds / core cycles** | Everything in §3. Eats money. |

They meet in exactly one place — §3.12, where die temperature and supply droop move
propagation delay and clock jitter together — and nowhere else. **In this document
"jitter" without a qualifier always means latency dispersion**, and the two words are
never used interchangeably. If you are reading a timing report, you want
[06-timing-report-forensics.md](06-timing-report-forensics.md); if you are reading a
latency histogram, you are in the right file.

### 1.1 The thesis

You are not running a throughput system where the mean is the product. You are entering a
**discrete race**, once per triggering event, and the only latency that decides whether you
win event *i* is your latency **on event *i***.

```
     p50 = 300 ns, p99.9 = 900 ns          p50 = 340 ns, p99.9 = 355 ns
     ────────────────────────────          ─────────────────────────────
     wins the 999                          wins the 999 (slightly less often)
     loses the 1                           wins the 1

     The second design has a WORSE mean and is strictly better here.
```

And the 1-in-1000 is not a uniformly-drawn event.

> **The thesis of this file: latency dispersion is not noise scattered around a mean. It
> is concentrated in exactly the states where money is made and lost.** Every mechanism in
> §3 that produces a tail — packet packing, arbitration collision, book rescan, FIFO
> occupancy, credit starvation, thermal drift at 14:00 — is *load-triggered*. Load means a
> burst. A burst means the market is moving. A market that is moving is when the trade is
> worth 10–50× a quiet-tape trade
> ([08-market-open-and-close-dynamics.md](08-market-open-and-close-dynamics.md)).
> The tail and the payoff are drawn from the same underlying variable, and they are
> **positively correlated by construction**.

A histogram weights every event equally. The market does not. That single sentence is why
CLAUDE.md §5 rule 8 exists.

---

## 2. ⚠️ Why a p99.9 regression outweighs a p50 improvement

Assert this and nobody believes it. Do the arithmetic and it stops being arguable.

### 2.1 The model

```
Session EV  =  Σ_races  P(win | our latency on that race) × V(race)

Two inputs, both of which must be measured, never assumed:
  ε  — competitive elasticity: percentage points of win probability per ns
  V  — value of winning, which is NOT constant across races
```

> **ILLUSTRATIVE, derived here, not measured.** `ε = 0.034 pp/ns` is carried over from
> [01-queue-position-and-fill-probability.md](01-queue-position-and-fill-probability.md) §6
> (3.4 pp per 100 ns at a competitor density of 1 per 100 ns). Every figure below inherits
> that document's warning: the arithmetic is the deliverable, the numbers are placeholders.

**Races are not homogeneous.** Decompose one session by regime:

| Regime | Races | Share of count | `V` / race | Share of value | Latency regime |
| --- | ---: | ---: | ---: | ---: | --- |
| Quiet tape | 180,000 | 90.0 % | $0.20 | 60.6 % | p50 |
| Active | 19,000 | 9.5 % | $0.60 | 19.2 % | p50 → p99 |
| **Burst** | **1,000** | **0.5 %** | **$12.00** | **20.2 %** | **p99 → max lives here** |
| | 200,000 | | | $59,400 | |

**Burst races are 0.5 % of the count and 20 % of the value.** That asymmetry is the entire
argument, and it is invisible to any instrument that reports percentiles over an
unweighted event stream.

### 2.2 The trade that looks good and is not

A change that buys 20 ns at p50 (three whole core cycles — a large win) by introducing a
structure that degrades under load, costing 400 ns during bursts:

```
GAIN — body, from ε = 0.034 pp/ns over 20 ns  ⇒  +0.68 pp win rate
    quiet   180,000 × 0.0068 × $0.20  =  +$244.80
    active   19,000 × 0.0068 × $0.60  =  +$ 77.52
                                          ─────────
                                          +$322.32 / session

LOSS — burst. +400 ns is >3× the entire 128 ns fabric budget: we are simply not
       in the race any more. Assume we previously won 55 % of burst races.
    burst    1,000 × 0.55 × $12.00    =  −$6,600.00 / session

NET  −$6,277.68 / session   ⇒  ≈ −$1.58 M / year at 252 sessions
```

> **Verify:** sessions per year from the **Nasdaq trading calendar**.

**The break-even, which is the number to remember:** the p50 gain is worth $16.1/ns. To pay
for that tail regression you would need **410 ns** of p50 improvement. The entire fabric
budget in `rtl/fpga_top.sv` is **128 ns**. *There is no p50 improvement available anywhere
in this design that pays for that tail regression* — you could delete the fabric and still
be short. That is not rhetoric; it is the arithmetic falling out of a 20 % value share.

### 2.3 The second-order point: tail events are clustered

The above already understates it. A tail regression is **not** 550 independent small
losses:

| Naive view | Reality |
| --- | --- |
| 0.1 % of events are slow, drawn at random | Slow events arrive in **runs** — one burst produces tens or hundreds consecutively |
| Losses are diversified across the session | You lose the **whole burst**, and bursts are where the volume is |
| Variance of daily P&L is unaffected | Daily P&L variance rises: outcomes now depend on how many bursts occurred |
| p99.9 is a tail statistic | Inside a burst, p99.9 latency is the **modal** latency. The regime is not rare; its *sampling weight* is |

⚠️ **A tail source that only fires under load will look like a rounding error in every
measurement taken on a quiet wire.** This is why
[05.04](../05-optimization/04-measurement-and-profiling.md) §8 makes market-open replay
the published load profile and idle the *floor*, never the headline.

### 2.4 The operational rule

> **RULE: CI gates on p99.9 and max, not the mean.** A change with lower p50 and worse
> p99.9 is a **regression** and is reverted by default. Accepting one requires a written
> argument, a named signer, and a ledger entry — the gate mechanics are in
> [05.01](../05-optimization/01-latency-budgeting.md) §10 and the accept/reject decision
> table in [05.04](../05-optimization/04-measurement-and-profiling.md) §10. Do not restate
> them; wire the gate to them.

---

## 3. The systematic inventory

Every entry: mechanism, magnitude at **6.4 ns/cycle**, whether it is a design choice or
data-dependent, how you *detect* it, and what you do about it.

### 3.1 Arbitration

Any point where two requesters can want one resource in the same cycle.

| Arbiter | Best case | Worst case | Effect on the distribution |
| --- | --- | --- | --- |
| **Strict priority** | Priority-0 waits **0** (or one non-preemptible transfer) | Lowest priority is **unbounded** under sustained load | Splits into two distributions. Priority-0 gets a spike; everyone else gets a fat tail |
| **Round-robin (fair)** | Every requester waits ≥ 0, typically more than priority-0 would | Bounded at **(N−1) grants** for everyone | One distribution, wider body, **shorter tail** |

> **A fair arbiter has a *better* worst case and a *worse* best case than a priority
> arbiter.** That is the whole trade, and it means "fair" is the right answer for shared
> infrastructure and the wrong answer for a fast path. On a fast path you do not want
> fairness; you want to be priority 0 and for nobody else to exist.

| Arbitration point here | Design | Cost on the delivered path |
| --- | --- | --- |
| **A/B feed** (`u_net_rx`) | There is no arbiter. First arrival wins, dedupe *is* the sequence check ([02.03](../02-networking/03-multicast-feeds-and-arbitration.md) §5) | **0 cycles.** The loser's copy is a duplicate discarded by logic that had to exist anyway |
| **A/B port mux** (two MACs → one stream) | Fixed priority A over B, **locked at packet granularity** from SOP to `tlast` | 0 when the loser is a duplicate. Non-zero only when A and B carry *different* sequences, i.e. after a gap on one feed. Bounded by one max-frame drain: ⌈1518×8 / AXIS_W⌉ cycles — **~24 cyc ≈ 153.6 ns at 512 b/beat, ILLUSTRATIVE** |
| **TX: order vs cancel** | **Strict priority to cancel**, always ([01-queue-position-and-fill-probability.md](01-queue-position-and-fill-probability.md) §5.1, [03-cancel-latency-and-pickoff.md](03-cancel-latency-and-pickoff.md)) | Cancel: 0. New order: at most one in-flight cancel frame. Deliberate — bounded upside vs. unbounded pickoff downside is not a close call |
| **Fast-path memory ports** | None. Simple dual-port, fast path owns port A exclusively ([04.01](../04-system-architecture/01-tick-to-trade-pipeline.md) §4) | **0 by construction** |

> **Verify:** the 1518-byte maximum untagged frame from **IEEE 802.3**; `AXIS_W` from
> `rtl/pkg/trading_pkg.sv`, which is the contract, not this table.

> **RULE: the fast path has nothing to arbitrate for.** Every arbiter in the design is
> either off the fast path or resolves in favour of the fast path in zero cycles. A design
> change that adds a fast-path arbiter must add a budget row and a jitter row, and justify
> both. Count `arb_collisions` and `ingress_fifo_high_water` per port regardless.

### 3.2 FIFO occupancy

**A FIFO that is sometimes empty and sometimes deep is a variable delay by construction.**
This is not a subtle property; it is the definition of a FIFO. Occupancy `d` costs `d`
cycles, and occupancy is set by arrival statistics you do not control.

| Structure | Latency | Dispersion |
| --- | --- | --- |
| **Cut-through** MAC (`CUT_THROUGH(1)` in `fpga_top.sv`) | Small and fixed — 2 cyc / 12.8 ns per the budget | **~0** |
| **Store-and-forward** MAC | Full frame time before the first byte emerges | Fully data-dependent: 1518 B at 0.8 ns/B ≈ **1214 ns**. Larger than the entire budget |
| **Elastic / clock-compensation buffer** in the GT+PCS | Absorbs the ppm difference between recovered and local clocks | **±1–2 cyc (±6.4–12.8 ns)**, continuous. `LOW_LATENCY(1)` bypasses where the GT permits. Irreducible where it does not — [04.01](../04-system-architecture/01-tick-to-trade-pipeline.md) §5 J1 |
| **Skid buffer, always full** | 1 cycle | 0 — a *constant* occupancy is a fixed delay, which is the point |
| **Skid buffer that fills and drains** | 0–1 cycle | 1 cycle, data-dependent |
| **Fast-path R0→T6** | No FIFOs at all. Single-cycle valid pulse, no ready, II = 1, drop-and-count instead of stall ([04.01](../04-system-architecture/01-tick-to-trade-pipeline.md) §7.1) | **0** |

> **Verify:** 0.8 ns/byte at 10GbE against **IEEE 802.3 Clause 49**; elastic-buffer and
> bypass latency from the **AMD UG578** GTY user guide and the Ethernet subsystem product
> guide for your exact configuration.

> **RULE: on the fast path, prefer a structure with *constant* occupancy, or none at all.**
> A depth-1 register that is always occupied beats a depth-4 FIFO that is usually empty,
> even though the FIFO has the lower mean. Where a FIFO is unavoidable (the MAC boundary),
> its high-water mark is a monitored counter, not an assumption.

### 3.3 Message straddling and packet packing — the data-dependent one

This is the source most often forgotten, and it is the only one on this list that **cannot
be designed away**.

Three independent effects compound:

```
(1) MESSAGE LENGTH varies by ITCH type. Order Delete is the shortest message in the
    catalogue; Add Order with MPID attribution is among the longest.

(2) STRADDLING. With a 64-byte (512-bit) beat, a message wholly inside one beat costs
    one beat to assemble; a message crossing a beat boundary costs two.
    Whether it straddles depends on its BYTE OFFSET in the packet, which depends on
    the lengths of every message ahead of it.  ⇒  +0 or +1 cycle (0 or 6.4 ns)

(3) PACKING. MoldUDP64 carries N messages per datagram. The Nth is delivered after
    the first. At II = 1, each preceding BOOK-AFFECTING message costs one cycle;
    preceding filtered messages cost zero.
    ⇒  +0 to +(k−1) cycles for the kth book message in the packet
```

**Total spread, ILLUSTRATIVE:** for a datagram carrying up to 10 book-affecting messages,
`0 … 9` cycles of packing plus `0 … 1` cycle of straddle = **0–10 cycles = 0–64 ns**, on a
128 ns fabric budget. That is a **50 % excursion** driven entirely by which slot in the
venue's datagram your trigger happened to land in.

> **Verify:** the message catalogue and every message length from the **Nasdaq
> TotalView-ITCH 5.0 specification** ([08.04](../08-nasdaq/04-totalview-itch-5.0.md)); the
> MoldUDP64 message-count field from the **MoldUDP64 specification**
> ([02.03](../02-networking/03-multicast-feeds-and-arbitration.md) §2).

⚠️ **This is not a defect and there is no mitigation that removes it.** The venue chose the
packing; you receive what arrives. Wider beats reduce straddling but not packing;
parallel per-type dispatch reduces packing cost but not to zero. **It is budgetable, not
fixable**, and the correct engineering response is:

> **RULE: histogram tick-to-trade *conditioned on message index within the datagram*.**
> This is the single highest-value conditioning variable in the system. An unconditioned
> p99.9 that moved tells you nothing; a p99.9 that moved *for k = 1* is a real regression,
> while one that moved only for `k ≥ 5` is the venue packing more densely today. Carry `k`
> in the tail-capture context field (§5.3) and never publish a latency number without the
> `k`-distribution of the load that produced it.

### 3.4 Clock domain crossing

| Primitive | Latency | Dispersion | Why |
| --- | --- | --- | --- |
| **2-FF level synchronizer** | 2 destination cycles nominal | **1 cycle (6.4 ns)** | The source transition lands at an arbitrary phase relative to the destination edge; it is captured on this edge or the next. Structural, not tunable. Add a stage and you add fixed latency, not certainty |
| **Toggle/pulse synchronizer** | ~3 cycles | 1 cycle | Same mechanism, plus a rate limit ([00.04](../00-foundations/04-clocking-reset-and-cdc.md) §3.2) |
| **Gray-coded async FIFO** | ~2–3 destination cycles ([00.04](../00-foundations/04-clocking-reset-and-cdc.md) §3.3) | **1–2 cycles**, and *drifting* — occupancy oscillates with the ppm offset between the two clocks | Pointer synchronization plus occupancy. The dispersion is not white; it has structure on the beat period of the two clocks |
| **req/ack handshake** | 4–6 cycles round trip | 1–2 cycles | Control plane only. Far too slow for a datapath |

**In this design, CDC is confined to the MAC and PCIe boundaries** (`fpga_top.sv` HARD
RULE 5). The contributions:

| Boundary | On the T2T path? | Contribution |
| --- | --- | --- |
| MAC RX `rx_clk` → `core_clk` (async FIFO inside `eth_10g_wrapper`) | **Yes**, once per event | ~2–3 cyc of latency, **~1 cyc (6.4 ns) of dispersion**, plus the elastic-buffer ±1–2 cyc of §3.2. Both are inside the "MAC RX (cut-through) 2 cyc" budget row and neither is removable |
| MAC TX `core_clk` → TX clock | **Yes**, once per event | Same order of magnitude, inside the MAC TX row |
| PCIe `pcie_clk` ↔ `core_clk` (inside `u_host_ctrl`) | **No** | 0 ns on T2T. It bounds credit-return latency (§3.7) and parameter-commit latency (§3.11), both off the fast path |
| `ext_kill_n` → `core_clk` (`cdc_sync_bit STAGES(3)`) | **No** | Adds 3 cycles to kill-switch response, which is why `KILL_RESP_CYCLES` is a declared parameter and not a hope |

> **RULE: no CDC anywhere between the MAC RX egress register and the MAC TX ingress
> register.** One 2-FF synchronizer inserted on a fast-path control bit "just to be safe"
> costs a full cycle of dispersion on **every** event — a body-wide regression disguised as
> a defensive measure. If a fast-path signal appears to need synchronizing, the bug is that
> it left the domain, not that it needs a synchronizer.

### 3.5 The declared variable stage: delete-the-best

`rtl/fpga_top.sv` marks one row `var*`: **"Book level update + incremental top-of-book"**,
footnoted *"the single variable-latency stage is a best-level delete that forces a new-best
search."* This is the design's canonical jitter source and the worked example of the whole
policy.

**Mechanism.** ITCH is order-based. A `D` Delete (or the final `E`/`X` that empties a level)
removes the last order at the current best price. The new best is the next-occupied level,
and *finding it is a search* — the only search left anywhere on the fast path.

**Why it is bounded.** It is bounded because the structure makes it bounded, not because
the data is kind ([04.03](../04-system-architecture/03-order-book-in-hardware.md) §6.3):

| Mitigation | Mechanism | Cost |
| --- | --- | --- |
| **(a) Cached second-best** | `bid2_lvl`/`bid2_qty` maintained by the same incremental rules; on a best-emptying delete, promote | **0 extra cycles.** Covers the large majority of cases |
| **(b) Occupancy bitmap + bounded priority encode** | Read the 256-bit bitmap word containing the old best, mask at-or-above, priority-encode down; if empty, one adjacent word | **+2 cycles = 12.8 ns.** Hard-bounded at **two** words |
| **(c) Bounded depth** | If both words are empty, publish `bid_valid = 0` and let the strategy gate on it | **0.** No third word is ever read |

**Magnitude in context.** Worst case is +2 cycles on a 20-cycle fabric total: 22 cycles =
140.8 ns, wire-to-wire ~333.6 ns against a ~320.8 ns target. **The design's one declared
variable stage moves the wire-to-wire number by 4.0 %** — and that is the whole reason it
is permitted. Frequency ≈ **1 % of book messages**
([04.03](../04-system-architecture/03-order-book-in-hardware.md) §6.4, estimates pending
pcap measurement).

⚠️ Alternatives considered and rejected: a full 2048-wide priority encode over the level
array is `⌈log₂ 2048⌉ = 11` cycles = 70.4 ns — **more than double the entire book budget**.
A sorted structure (heap, skip list, linked list) replaces a bounded excursion with a
variable one that also has a worse mean. Both are worse on both axes.

> **RULE for every variable stage in this project — this is the template, and the book
> stage is the only instance:**
> 1. The bound is **documented** in the module header, in cycles and ns, and matched by a
>    parameter (`VAR_CYCLES`).
> 2. Each occurrence is **counted** in `book_stat` (`rescan_cnt`), readable over the CSR
>    interface.
> 3. The corresponding **histogram bucket is inspected** every session: `u_telemetry` with
>    `N_BUCKETS = 32` must show a secondary mode exactly `VAR_CYCLES` above the primary,
>    with a mass matching `rescan_cnt / n`. **If the counter and the histogram disagree,
>    one of them is lying and you do not know which** — that discrepancy is a P1.
> 4. The variable path is **covered** in regression (§4.2). An untaken cover means the
>    testbench does not exercise the case that produces your tail.

### 3.6 Memory: banking, collisions, and cascade depth

| Effect | Mechanism | Magnitude | Status here |
| --- | --- | --- | --- |
| **True-dual-port collision** | Two agents read/write the same BRAM in one cycle; one is delayed or the read data is undefined | +1 cycle, or silent corruption | **Structurally impossible.** Simple dual-port; fast path owns port A, telemetry reads port B ([04.01](../04-system-architecture/01-tick-to-trade-pipeline.md) §4) |
| **URAM cascade hop** | A wide array spans several URAM288s in a cascade; each hop adds a register stage | **+1 cycle per hop** ([05.01](../05-optimization/01-latency-budgeting.md) §9) | ⚠️ Cascade depth is a **placement outcome**. The same RTL can build at different latencies across runs |
| **Bank conflict** | Two accesses to the same physical bank in one cycle | +1 cycle, load-dependent | Avoided by giving the level array a single fast-path reader |

⚠️ **The cascade-depth trap is the one that gets people.** A memory whose read latency is
implied by placement rather than declared will change latency between builds, and the
change appears only in hardware measurement — never in RTL simulation.

> **RULE: every fast-path memory is instantiated through a wrapper with an explicit
> `RD_LATENCY` parameter, and an assertion fires if the instantiated primitive does not
> match it.** A latency that is a build outcome is not a budget.
> **Verify:** URAM288 geometry, cascade rules and per-hop latency from the **AMD UltraScale
> Architecture Memory Resources user guide** and the synthesis report — never from a table.

### 3.7 Write-forwarding bypass depth

Back-to-back updates to the same `(slot, level)` are **common, not rare** — an execution
and the follow-on delete of the same order, a cancel/replace pair, several orders leaving
the touch in the same microsecond
([04.03](../04-system-architecture/03-order-book-in-hardware.md) §8). Two ways to handle it:

| Approach | Latency effect | Correctness |
| --- | --- | --- |
| **Stall on the hazard** | +1 cycle on a **high fraction** of events. Not a tail — a **bimodal body**, and it fires hardest exactly when the tape is busiest | correct |
| **Write-forwarding bypass** (chosen) | **0 cycles.** A 2-input mux and a comparator, well inside 6.4 ns | correct |
| Neither | 0 cycles | ⚠️ silent book drift in the direction of the traffic |

> **RULE: `BYPASS_DEPTH = RAM_RD_LAT`, as a parameter, always.** They are the same number.
> A bypass one stage too shallow produces the same silent drift, just less often — which
> makes it harder to find, not easier. This couples §3.6 to §3.7: a retiming that adds an
> output register to the level array for Fmax silently invalidates the bypass.

### 3.8 Credit starvation — the stall that *improves* your histogram

`credit_avail` bounds how many orders the FPGA may emit before the host has accounted for
them. It is a **risk bound, not flow control**
([04.05](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) §9). When it is
exhausted, the risk gate rejects with `RISK_NO_CREDIT` and the order is **not sent** —
fail-closed, not fail-slow, because a queued order is a stale order.

From the strategy's point of view this is a latency event of **unbounded duration**: the
trade does not happen until credit returns, which is a host round trip
(**~10–50 µs, ILLUSTRATIVE** — [04.05](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) §9).

⚠️ **The instrumentation trap, and it is a bad one.** `u_telemetry` samples latency on
`order_out_valid` — when an order *leaves*. A suppressed order produces **no sample at
all**. So credit starvation makes the latency histogram look **better**: it removes exactly
the events that occurred under the heaviest load. A system that is failing to trade during
bursts reports a beautiful p99.9.

> **RULE: `credit_starved` is counted, alerted, and reported *alongside* every latency
> distribution.** A latency report without the suppressed-event count is not a report —
> it is a survivorship-biased sample. The pairing is mandatory:
> `n_samples + credit_starved + risk_rejects` must reconcile against `book_top_valid`
> triggers, or you are reading a filtered distribution.

⚠️ **The failure mode that looks like a fabric problem.** If host credit return is slow or
periodic (a poll loop, an interrupt-coalescing timer, a scheduler quantum), `credit_avail`
develops a **sawtooth**: full, drained during a burst, refilled on the host's period. The
symptom is a *periodic* pattern of suppressed orders and apparent latency excursions whose
period matches nothing in the fabric. Engineers spend days in timing reports.
**Diagnostic:** plot `credit_starved` increments against wall clock and look for a spectral
line at the host poll period. If one exists, the problem is
[04.06](../04-system-architecture/06-cpu-fpga-partitioning.md), not the RTL.
Sizing `MAX_IN_FLIGHT` up "to fix the stalls" trades supervised risk for order rate and is
an approved risk decision, never a performance tweak.

### 3.9 TCP retransmit on the order path

| Property | Value |
| --- | --- |
| **Mechanism** | A lost or corrupted segment on the OUCH/SoupBinTCP session; the sender must wait a retransmission timeout before resending |
| **Magnitude** | The RTO minimum — **hundreds of milliseconds**, i.e. **10⁶×** the fabric budget. Roughly 10⁵ races |
| **Why rare** | A short, dedicated, uncongested colo cross-connect to the venue drops essentially nothing ([08.08](../08-nasdaq/08-connectivity-and-colocation.md)) |
| **Why catastrophic anyway** | It is not a tail *of* the distribution; it is a different distribution entirely. No histogram bucketing that resolves 6.4 ns also resolves 200 ms |

> **Verify:** the RTO computation and its minimum from **RFC 6298**, and the effective
> minimum from your host TCP stack's configuration — they differ, and the stack's value
> is the operative one.

**The design consequence — and this is why the ownership split in
[04.05](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) §8 has the shape
it does:** TCP state is **host-owned with a fabric fast-send**. Retransmission is a CPU
responsibility. On duplicate ACKs, an out-of-order ACK, a closed window, or a SoupBin
sequence mismatch, the FPGA **stops emitting and hands ownership to the CPU**. A retransmit
therefore never lengthens the fabric path — it is converted into a *counted functional
event* (`tx_blocked`) rather than an unbounded latency event. **That conversion is the
mitigation.** Putting retransmission in fabric would move a 200 ms tail *onto* the
measured path, which is precisely backwards.

### 3.10 Telemetry and debug sharing fabric with the fast path

Two distinct mechanisms, and the second is invisible in simulation:

| Mechanism | Effect | Mitigation |
| --- | --- | --- |
| **Resource sharing** — telemetry contends for a memory port or an arbiter with the fast path | Telemetry becomes a critical-path stage with **no budget row**. The most common way the §4 rule of [04.01](../04-system-architecture/01-tick-to-trade-pipeline.md) gets violated | Observer-only: consume a `valid + delta` pulse, never backpressure. Port B only |
| **Routing congestion** — telemetry logic placed inside the fast-path pblock competes for routing resources | Degrades WNS on fast-path nets. A *latency* effect that appears in **no functional simulation** and only in the timing report | Floorplan telemetry **outside** the fast-path pblock; `set_max_delay -datapath_only` on the readback crossing |

```tcl
# constraints/floorplan.xdc — telemetry may observe the fast path but may not
# share its silicon. The pblock is the enforcement, not the code review.
create_pblock pb_fastpath
add_cells_to_pblock pb_fastpath [get_cells {u_net_rx u_feed u_book \
                                            u_strategy u_risk_gate u_order_gw}]
resize_pblock pb_fastpath -add {SLR1}

# Readback is slow, wide, and must never be timed as a fast-path net.
set_max_delay -datapath_only 20.000 \
    -from [get_cells u_telemetry/*] -to [get_cells u_host_ctrl/*]
```

⚠️ **Never quote a latency number from a bitstream containing an ILA.** Probe nets change
placement and routing, which changes the thing you are measuring
([05.04](../05-optimization/04-measurement-and-profiling.md) §6). The corollary is stronger
than it looks: **the instrumentation in §5 must be in the production bitstream**, because
an instrumented debug build measures a different design.

### 3.11 Reset and parameter-commit windows

| Event | Mechanism | Magnitude | Policy |
| --- | --- | --- | --- |
| **Parameter commit** (`cfg_risk_commit`, `cfg_strat_commit`) | Double-buffered shadow bank, single-cycle atomic flip | **0 cycles** | The atomicity *is* the mitigation. ⚠️ A multi-cycle copy forces a choice between stalling the fast path (jitter) and reading a half-written record (**wrong trade**). Both unacceptable |
| **Reset release** | Pipeline flush; `cycle_cnt` restarts from 0 | Bounded by pipeline depth: **20 cycles = 128 ns**, once, at arm time | Do not trade for a documented number of cycles after release. `core_rst` is synchronous and fail-closed by design (`fpga_top.sv` HARD RULE 4) |
| **`cycle_cnt` after reset** | The measurement time base restarts | All deltas spanning the reset are garbage | ⚠️ `cycle_cnt` is **never reset after initial release** — that comment in `fpga_top.sv` is a measurement contract, not a style note. Discard any sample whose `t0` predates the last release |

### 3.12 Thermal and voltage drift — the p99.9 driver nobody instruments

This is the one place where **clock jitter** (§1) and **latency dispersion** touch.

```
Static timing closes at a worst-case corner (Tj max, Vccint min, slow process).
Actual propagation delay and actual clock jitter both vary with Tj and Vccint
DURING the session. A build that closed with WNS ~ 0 has no margin left for
that variation.
```

⚠️ **The failure mode is not "it gets slower".** The pipeline is synchronous: it takes the
same number of cycles at any temperature. What happens instead is that a marginal path
starts **intermittently violating setup** — a corrupted field, a dropped event, a
mis-decoded message. Its signature is a defect rate that tracks the **temperature curve**,
not the message rate: it appears in the afternoon, in a hot aisle, and vanishes overnight
in the lab.

| Detection | Mitigation |
| --- | --- |
| Log `Tj` from the device monitor at 1 Hz alongside every counter, and **alert on correlation between any error counter and `Tj`** — not on `Tj` alone | Hold a WNS margin rather than closing at zero ([06-timing-report-forensics.md](06-timing-report-forensics.md), [05.02](../05-optimization/02-fmax-and-timing-optimization.md)) |
| Compare morning and afternoon histograms from the **same build, same day** | Record `Tj` in the conditions line of every latency report (§6) |

> **Verify:** operating temperature range, `Vccint` tolerance, and the on-die monitor's
> accuracy from the **AMD UltraScale+ device datasheet** for your exact speed grade.

### 3.13 The host: PCIe DMA, interrupts, and shared resources

PCIe is **slow path only** in this design, and everything the host does reaches the fast
path through exactly three bounded channels:

| Host activity | Reaches the fast path how | Magnitude on T2T | Residual |
| --- | --- | --- | --- |
| DMA log-ring drain, telemetry readback | Fabric BRAM/URAM only; no DDR, no HBM, no NoC on the fast path | **0 ns** | 0 — **by an architectural property that is easy to lose** |
| Credit return | `cfg_credit_return` → `credit_avail` | 0 ns directly; gates order emission (§3.8) | Counted, alerted |
| Parameter commit | Double-buffered atomic flip (§3.11) | 0 ns | 0 |
| Interrupt coalescing / scheduler quantum on the host | Delays log-ring drain ⇒ delays credit return | 0 ns directly | Feeds §3.8's sawtooth |

⚠️ **The zero in row 1 is conditional on a design choice, not a law.** The moment any
fast-path structure moves to HBM, DDR, or a NoC-attached memory, host DMA and the fast path
share a controller and a queue, and PCIe becomes a first-class jitter source with a
load-dependent, unbounded tail. **State it as a constraint:** every fast-path memory in
this design is fabric BRAM or URAM. That is why the book fits in one SLR
([04.03](../04-system-architecture/03-order-book-in-hardware.md) §5) and it is not
negotiable for a resource saving.

### 3.14 Master inventory

Magnitudes at **6.4 ns/cycle**. `ILL` = ILLUSTRATIVE, derived here from the `fpga_top.sv`
budget; measure before relying on it.

| # | Source | Mechanism | Magnitude (cyc / ns) | Kind | Detect by | Mitigation | Residual |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | A/B feed arbitration | First-arrival wins; dedupe is the seq check | 0 | design | `feed_a_wins`/`feed_b_wins`, skew histogram | No arbiter exists | **0** |
| 2 | A/B port mux collision | Two ports present a beat in one cycle | 0 → ~24 / ~154 (ILL) | data | `arb_collisions`, `ingress_fifo_high_water` | Fixed priority, packet-granular lock | ~0 (loser is a dup) |
| 3 | TX order-vs-cancel | Shared TX stream | cancel 0; order ≤ 1 frame | design | `tx_defer_cnt` | **Strict priority to cancel** | Deliberate, bounded |
| 4 | MAC elastic buffer | Clock compensation, gearbox slip | ±1–2 / ±6.4–12.8 | phys | Wire-to-wire histogram width at idle | `LOW_LATENCY(1)`, bypass where permitted | **Irreducible** |
| 5 | Store-and-forward MAC | Whole frame before first byte out | ≤ ~1214 ns | design | Idle-load p50 vs frame size | `CUT_THROUGH(1)` | **0** |
| 6 | Fast-path FIFOs | Occupancy = delay | 0 | design | Structural review | None exist; valid-pulse, no ready, II=1 | **0** |
| 7 | **Message straddling** | Message crosses a 64 B beat | +0 or +1 / 0–6.4 | **data** | Histogram vs message type | None. Budget it | **0–6.4 ns, permanent** |
| 8 | **MoldUDP64 packing** | kth book message in a datagram | +0 → +(k−1) / 0–57.6 (ILL) | **data** | Histogram conditioned on `k` (§3.3) | None. Budget worst realistic N | **0–58 ns, permanent** |
| 9 | MAC-boundary CDC | Async FIFO phase + occupancy | ~1 / 6.4 | phys | Idle histogram width | Confined to the MAC boundary | **~6.4 ns** |
| 10 | Fast-path CDC | Any synchronizer R0→T6 | +1 per crossing | design | CDC lint report | **Forbidden** | **0** |
| 11 | **Best-level delete rescan** | Delete empties best ⇒ new-best search | **+2 / 12.8, bounded** | data | `rescan_cnt` + 2nd histogram mode | 2nd-best cache; bitmap + bounded prio-enc | **+12.8 ns @ ~1 %** |
| 12 | Order-map set overflow | Hash set full ⇒ overflow probe | +2 / 12.8 | data | `omap_overflow_cnt` | 4-way + overflow region | +12.8 ns, rare |
| 13 | `U` Replace expansion | delete + insert = two `book_cmd`s | +1 / 6.4 | data | Message-type histogram | II = 1, so +1 not +5 | +6.4 ns |
| 14 | URAM cascade depth | Placement-dependent extra hop | +1 per hop | **build** | Post-route latency check vs `RD_LATENCY` | Explicit wrapper parameter + assertion | **0 if asserted** |
| 15 | Level RMW hazard | Same-address back-to-back | +1 if stalled | data | Would show as a bimodal body | **Bypass, never stall**; `BYPASS_DEPTH = RAM_RD_LAT` | **0** |
| 16 | Parameter commit | Bank switch during a read | +1 if non-atomic | design | `param_commit_cnt` vs latency | Double-buffer, single-cycle atomic flip | **0** |
| 17 | Reset / arm flush | Pipeline drain after release | ≤ 20 / 128, once | design | `arm_flush_cycles` | Do not trade for N cycles post-release | **0 steady state** |
| 18 | **Credit starvation** | `credit_avail` = 0 ⇒ order suppressed | **unbounded**, ~10–50 µs to recover | load | `credit_starved`; ⚠️ **absent** from the histogram | Size `MAX_IN_FLIGHT`; fix host return rate | Counted + alerted |
| 19 | **TCP retransmit** | Lost segment ⇒ RTO | **10⁵–10⁶ cyc**, ~10² ms | rare | `tx_blocked`, session counters | Host-owned TCP + fabric fast-send; stop and hand over | Converted to a **functional** event |
| 20 | Telemetry resource share | Port/arbiter contention | +1, unbudgeted | design | Structural review | Observer-only, port B, no backpressure | **0** |
| 21 | Telemetry congestion | Routing pressure in the pblock | WNS loss ⇒ Fmax loss | **build** | Timing report, not simulation | Floorplan outside the fast-path pblock | **0** |
| 22 | **Thermal / voltage drift** | Delay + clock jitter vary with Tj, Vccint | not cycles — **margin** | phys | Error-counter ↔ `Tj` correlation at 1 Hz | Hold WNS margin; record `Tj` per report | Monitored |
| 23 | Host PCIe / DMA | Shared memory controller | **0 here**, unbounded if violated | design | N/A while the constraint holds | Fast-path memory is fabric BRAM/URAM only | **0, conditionally** |

---

## 4. The case for fixed-latency design, made rather than asserted

**Fixed latency** = the block consumes the same number of cycles for every input, for every
data value, under every load. Not "usually". Every.

### 4.1 The honest ledger

| Costs | Benefits |
| --- | --- |
| You pay the **worst case on every event**, including the 99 % that did not need it | The distribution **collapses to a spike**. p50 = p99.9 = max |
| Some resources idle on most events (the padded cycle does nothing) | The tail **does not exist**, so it cannot be correlated with bursts (§1.1) |
| More logic, sometimes, to make the slow path fast rather than the fast path slow | **Verifiable**: you can assert cycle-exact latency in a testbench. This is an enormously strong property — a *proof* rather than a measurement |
| Can be **worse in expectation** than a variable design | **Reproducible**: a simulation replay predicts hardware cycle-for-cycle, so a regression is caught in CI rather than in production |

The third benefit is the one that is systematically undervalued. A cycle-exact latency
contract turns "we measured it and it seemed fine" into "the build fails if it is not
exactly this". Nothing else in the toolbox converts a performance property into a
compile-time property.

### 4.2 The contract, in SystemVerilog

```systemverilog
// ─────────────────────────────────────────────────────────────────────────────
//  Latency contract. Every fast-path block instantiates this.
//    FIXED_CYCLES : the declared latency, matching the fpga_top.sv budget row
//    VAR_CYCLES   : the ONLY permitted excursion. 0 for a fixed-latency block.
//    var_expected : asserted combinationally at s_valid when the declared
//                   variable case applies (e.g. best-emptying delete). It is a
//                   PREDICTION the block must honour, not a post-hoc excuse.
// ─────────────────────────────────────────────────────────────────────────────
`ifndef SYNTHESIS
    // 1. The envelope. Nothing may EVER land outside it.
    assert property (@(posedge clk) disable iff (rst)
        s_valid |-> ##[FIXED_CYCLES:FIXED_CYCLES+VAR_CYCLES] m_valid)
        else $error("%m: latency outside declared envelope [%0d,%0d]",
                    FIXED_CYCLES, FIXED_CYCLES+VAR_CYCLES);

    // 2. The fixed case is EXACT. Not "within". Exact.
    assert property (@(posedge clk) disable iff (rst)
        (s_valid && !var_expected) |-> ##FIXED_CYCLES m_valid)
        else $error("%m: fixed case took other than %0d cycles", FIXED_CYCLES);

    // 3. The variable case is exact too, at its own number. A block that
    //    "sometimes" takes the excursion has an undeclared third mode.
    assert property (@(posedge clk) disable iff (rst)
        (s_valid && var_expected) |-> ##(FIXED_CYCLES+VAR_CYCLES) m_valid)
        else $error("%m: declared variable case took other than %0d cycles",
                    FIXED_CYCLES+VAR_CYCLES);

    // 4. ⚠️ The cover is as load-bearing as the asserts. An untaken cover means
    //    regression never exercised the case that produces the production tail.
    cover property (@(posedge clk) disable iff (rst) s_valid && var_expected);

    // 5. The counter the histogram is reconciled against (§3.5 rule 3).
    always_ff @(posedge clk)
        if (rst) var_cnt <= '0;
        else if (s_valid && var_expected) var_cnt <= var_cnt + 1'b1;
`endif
```

`VAR_CYCLES = 0` collapses assertions 1–3 into a single exact-cycle contract and makes
assertion 3 vacuous — which is the correct shape for every block in the design except one.

### 4.3 The counter-argument, taken seriously

**Fixed latency at the worst case can be worse in expectation.** Take the book stage: pad
it to always take 4 cycles instead of 2-with-a-bounded-+2.

```
Variable (current) : p50 = 2 cyc, p99.9 ≈ 4 cyc, max = 4 cyc.  Mean ≈ 2.02 cyc
Padded to fixed    : p50 = p99.9 = max = 4 cyc.                Mean  = 4.00 cyc

Padding costs +12.8 ns on EVERY event and removes an excursion that was already
bounded, already counted, already inside budget, and already 4 % of wire-to-wire.
Using §2's elasticity: 12.8 ns × 0.034 pp/ns × $47,400 of body value ≈ −$206/session,
for a p99.9 improvement of exactly ZERO — because p99.9 was already 4 cycles.
```

Padding here is **strictly worse**. Which is why the project rule is conditional, not
absolute:

> **THE PROJECT RULE — fixed latency on every stage where the worst case is within budget;
> variable latency only where it is declared, bounded, counted, and histogrammed.**

Padding is the right answer when, and only when, one of these holds:

| Condition | Why padding wins |
| --- | --- |
| The excursion would cross a **competitive threshold** | Losing a race is a step function; being uniformly slower is not |
| The excursion is **unbounded or uncountable** | You cannot budget what you cannot bound. Pad it or move it off the fast path |
| The excursion is **load-correlated** (fires in bursts) | §1.1: the excursion lands on the valuable events. This is the common case |
| Determinism has **verification value** exceeding the mean cost | A cycle-exact contract catches regressions that measurement will not |

⚠️ Note that the book rescan does **not** satisfy condition 3: it is triggered by book
structure, not by load. If it were burst-correlated, the answer would flip.

**`rtl/fpga_top.sv` is the worked example of the rule.** Fourteen `fixed` rows and one
`var*`, footnoted, bounded, counted in `book_stat`, and visible as a second mode in
`u_telemetry`. That is what compliance looks like.

---

## 5. Measuring and **attributing** jitter

Knowing that p99.9 is 90 ns worse than yesterday tells you **nothing** about which of the
23 rows in §3.14 did it. A single end-to-end number cannot be debugged. This section is
about producing a number that can be.

### 5.1 Per-stage timestamps carried with the event

The design already carries `cycle_t rx_cycle` through `book_evt_t → book_top_t →
order_req_t → order_out_t`, and `u_telemetry` subtracts it at `order_out_valid`. That gives
you the **total**. The extension gives you the **decomposition**:

```systemverilog
// rtl/pkg/trading_pkg.sv — proposed addition. Carried alongside, never consumed.
typedef enum logic [3:0] {
    ST_RX=0, ST_DEFRAME=1, ST_DECODE=2, ST_FILTER=3, ST_OMAP=4,
    ST_BOOK=5, ST_STRAT=6, ST_RISK=7, ST_ENCODE=8, ST_TX=9
} stage_e;
localparam int unsigned N_STAGE = 10;

typedef struct packed {
    cycle_t                t0;      // absolute ingress cycle — the ONE full stamp
    logic [7:0]            t_prev;  // low 8 bits of the previous stage boundary
    logic [7:0][N_STAGE-1:0] d;     // per-stage deltas, in cycles
} lat_trace_t;
```

Per-stage latch, parameterised by `STAGE_ID`, dropped in at each boundary:

```systemverilog
// Deltas, not absolute stamps: 8 bits (255 cyc = 1.63 us headroom) per stage
// instead of 48. Unsigned 8-bit subtraction wraps correctly for any delta < 256,
// exactly as the free-running counter does for the total.
wire [7:0] now8 = cycle_cnt[7:0];
always_ff @(posedge clk) if (s_valid) begin
    m_trace             <= s_trace;                    // carry everything forward
    m_trace.d[STAGE_ID] <= now8 - s_trace.t_prev;      // this stage's cost
    m_trace.t_prev      <= now8;
end
```

| Cost | Figure (ILLUSTRATIVE) |
| --- | --- |
| Carried width | 48 + 8 + 10×8 = **136 bits** per in-flight event |
| Flip-flops | ~136 FF × ~20 occupied stages ≈ **2.7 k FF**, ~3 % of the 90 k FF fast-path budget in `fpga_top.sv` |
| Logic | 10 × 8-bit subtract — one LUT level, nowhere near a 6.4 ns period |
| Added latency | **0 cycles** |

> **RULE: the stamps are never on the critical path.** No fast-path expression may read
> `.d[]` or `.t_prev`; they ride alongside the payload and are consumed only at the
> terminal stage by observer logic. Enforce it two ways: a lint rule, and a simulation
> equivalence check proving that a `TRACE=0` build produces **byte-identical outputs**.

> **RULE: the trace is in the production bitstream.** Not a debug build. A debug build has
> different placement and routing and therefore different latency
> ([05.04](../05-optimization/04-measurement-and-profiling.md) §7) — the number you would
> obtain from it is a number about a design you do not ship.

### 5.2 The terminal decomposition, and why a histogram is not enough

At `order_out_valid`, `total = cycle_cnt − trace.t0` feeds `u_telemetry`, and `trace.d[]`
holds the breakdown. Histogramming each stage separately (one `latency_hist` per stage per
[06.03](../06-operations/03-monitoring-and-telemetry.md) §3) gives per-stage marginals —
useful, and not sufficient:

⚠️ **Marginal histograms cannot answer the question you actually have.** "Stage 8 has a
tail" and "stage 3 has a tail" does not tell you whether they were the *same* events. The
tail investigation needs the **joint** distribution, and it needs it for the handful of
events that were actually slow. A histogram discards precisely that.

### 5.3 The tail-capture buffer — the highest-value instrument for tail work

A small circular buffer recording the **full stage decomposition plus context** for any
event whose total exceeded a host-set threshold.

```systemverilog
// rtl/telemetry/tail_capture.sv
//  Budget row : none — observer only, 0 cycles on the datapath.
//  Resources  : DEPTH x 256 b. At DEPTH=256 that is 64 Kbit = 2 BRAM36.
//  Rationale  : tail events are rare and a histogram throws away exactly the
//               information a tail investigation needs. This keeps it.
module tail_capture import trading_pkg::*; #(
    parameter int unsigned DEPTH = 256
)(
    input  var logic        clk, rst,
    input  var logic        s_valid,        // one pulse per completed T2T event
    input  var lat_trace_t  s_trace,
    input  var cycle_t      s_now,
    // ── context: the attribution question is "what was happening", not
    //    "which gate was slow". These fields answer it. ──────────────────
    input  var logic [7:0]  ctx_msg_type,   // ITCH message type
    input  var sym_idx_t    ctx_sym,
    input  var logic [7:0]  ctx_msg_idx,    // kth message in the Mold datagram (§3.3)
    input  var logic [15:0] ctx_rate,       // book events in the last 1024 cycles
    input  var logic [15:0] ctx_flags,      // rescan | omap_ovf | gap | credit | feed
    // ── host control and readout ────────────────────────────────────────
    input  var logic [23:0] cfg_threshold_cyc,  // set from LAST session's p99.9
    input  var logic [$clog2(DEPTH)-1:0] rd_addr,
    output var logic [255:0] rd_rec,
    output var logic [31:0]  captured_cnt,
    output var logic [31:0]  overrun_cnt
);
    logic [23:0] total;
    logic        arm;
    assign total = 24'(s_now - s_trace.t0);
    assign arm   = s_valid && (total > cfg_threshold_cyc);

    logic [255:0] mem [DEPTH];
    logic [$clog2(DEPTH)-1:0] wptr;

    always_ff @(posedge clk) begin
        if (rst) begin wptr <= '0; captured_cnt <= '0; overrun_cnt <= '0; end
        else if (arm) begin
            mem[wptr] <= {s_trace.t0, total, s_trace.d,
                          ctx_msg_type, ctx_sym, ctx_msg_idx, ctx_rate, ctx_flags};
            wptr         <= wptr + 1'b1;
            captured_cnt <= captured_cnt + 1'b1;
            // Wrapped before the host drained: we overwrote a tail event.
            if (wptr == '1) overrun_cnt <= overrun_cnt + 1'b1;
        end
    end
    assign rd_rec = mem[rd_addr];
endmodule
```

**Sizing and operation.**

| Parameter | Value | Reasoning |
| --- | --- | --- |
| `DEPTH` | 256 records | 64 Kbit = 2 BRAM36. Trivial against the 300-BRAM budget |
| `cfg_threshold_cyc` | **last session's p99.9**, not a constant | A constant threshold silently stops capturing when the design improves, and floods when it regresses |
| Arm rate | ~10⁻³ × event rate | At 10⁵ events/s that is ~100 records/s ⇒ 256 records ≈ 2.5 s, ample for a 1 Hz host drain |
| Drain | Host reads and advances at 1 Hz over the CSR interface | Off the fast path entirely |

⚠️ **`overrun_cnt > 0` means "raise the threshold", not "the buffer is too small".** A
threshold set too low fills the buffer with the *least* interesting tail events and
overwrites the worst ones — the buffer captures the p99, discards the p99.99, and you
conclude the tail is mild. This is the single most likely way to mis-operate this
instrument.

### 5.4 Host-side attribution

```python
# host/analysis/tail_attrib.py — slow path, offline.
# Joins fabric tail-capture records against the feed log to produce a
# per-CAUSE attribution table. The fabric says WHERE; the feed log says WHY.
import pandas as pd

STAGES = ["rx","deframe","decode","filter","omap","book","strat","risk","enc","tx"]
NS     = 6.4                                     # ns per core cycle @ 156.25 MHz

tails = pd.read_parquet("tail_capture.parquet")  # one row per armed event
feed  = pd.read_parquet("feed_log.parquet")      # decoded ITCH + Mold framing

# 1. Which stage overran? Compare each stage against its OWN median, not the total.
base   = tails[STAGES].median()
excess = tails[STAGES].sub(base, axis=1).clip(lower=0)
tails["worst_stage"]  = excess.idxmax(axis=1)
tails["excess_ns"]    = excess.max(axis=1) * NS
tails["explained_ns"] = excess.sum(axis=1) * NS   # ⚠️ if this is much less than
                                                  # total_ns - base.sum(), the cause
                                                  # is BETWEEN stages: CDC, elastic
                                                  # buffer, or a missing boundary.

# 2. Attach external context. "What was happening" beats "which gate was slow".
tails = tails.merge(feed[["t0","msg_type","mold_seq","msgs_in_pkt","session_phase"]],
                    on="t0", how="left")

# 3. The deliverable: one row per cause, ranked by TOTAL ns, not by count.
attrib = (tails
    .assign(cause=lambda d: d.worst_stage + " | " +
            d.flags.map(lambda f: "rescan" if f & 1 else
                                  "omap_ovf" if f & 2 else
                                  "gap" if f & 4 else "-"))
    .groupby(["cause","session_phase"])
    .agg(n=("excess_ns","size"),
         p50_excess=("excess_ns","median"),
         max_excess=("excess_ns","max"),
         total_ns=("excess_ns","sum"),
         median_k=("msg_idx","median"),        # kth-in-datagram: §3.3 in one column
         median_rate=("ctx_rate","median"))    # burst intensity at the time
    .sort_values("total_ns", ascending=False))
```

**Rank by total nanoseconds, not by occurrence count.** A cause that fires 5 times for
400 ns each outranks one that fires 5,000 times for 6.4 ns, and the count-ordered table
puts them the other way round.

⚠️ **`explained_ns` far below the observed excess is the most informative single output
here.** It means the time was spent *between* instrumented boundaries — the elastic buffer,
a CDC, or a stage boundary you forgot to instrument. Chasing stages when the sum does not
reconcile is how tail investigations lose a week.

---

## 6. The reporting standard

Every latency claim in this project carries all of the following. Methodology —
tap setup, rig offset, noise floor, A/B statistics — is
[05.04](../05-optimization/04-measurement-and-profiling.md) §9 and §10; do not restate it,
satisfy it.

| Field | Requirement | Why it is mandatory |
| --- | --- | --- |
| `metric` | Convention, explicitly ([05.01](../05-optimization/01-latency-budgeting.md) §2) | Two conventions differ by 200 ns |
| `N` | Trigger events, ≥ 10⁶ for a p99.9 claim | A p99.9 over N = 1,000 is noise |
| `capture window` | Wall-clock start and end | Pairs the number with the tape |
| `session phase` | pre-open / open / mid-day / close / auction | The open is a different system ([08-market-open-and-close-dynamics.md](08-market-open-and-close-dynamics.md)) |
| `p50 / p90 / p99 / p99.9 / max` | All five. `max` is exact (a register); percentiles carry ±1 bucket | CLAUDE.md §5 rule 8 |
| `histogram overflow` | `rd_over` count | A saturating top bucket reports a max that is not the max |
| **per-stage decomposition** | Median and p99.9 for each of the 10 stages | Without it the number cannot be debugged (§5) |
| **variable-stage occurrences** | `rescan_cnt`, `omap_overflow_cnt`, and their **rate** | §3.5 rule 3 — reconcile against the histogram's second mode |
| **suppressed events** | `credit_starved`, `risk_rejects`, `tx_blocked` | ⚠️ §3.8 — without these the distribution is survivorship-biased |
| `msgs-per-datagram` | Distribution of `k` over the load | §3.3 — makes two runs comparable |
| `build ID` + `GIT_SHA` + seed/directive | From `fpga_top.sv` parameters and the run log | Latency is a property of a bitstream, not a repo |
| `source` | **`MEASURED`** or **`SIMULATED`**, capitalised | They are not comparable and never summed |
| `conditions` | `Tj`, ambient, production bitstream, no debug cores | §3.12 — a report without `Tj` cannot be compared to one taken in the afternoon |

---

## 7. Rules for this project

1. **"Jitter" means latency dispersion here; clock phase noise is called clock jitter.** Never use the bare word for both in one document.
2. **Dispersion is concentrated where the money is.** Tail excursions are load-triggered, load means bursts, bursts are when the trade is worth 10–50×. Never model the tail as random.
3. **CI gates on p99.9 and max.** A change with lower p50 and worse p99.9 is a regression and is reverted by default. Overriding requires a written argument and a named signer.
4. **The fast path has nothing to arbitrate for.** Every arbiter is off it, or resolves in its favour in zero cycles. Cancel beats order, always.
5. **No FIFOs on the fast path.** Constant occupancy or none. R0→T6 is valid-pulse, no ready, II = 1, drop-and-count.
6. **No CDC between MAC RX and MAC TX.** Not one synchronizer, not defensively.
7. **Exactly one variable stage exists, and it is declared in `fpga_top.sv`.** Adding a second requires a budget row, a jitter row, a bound, a counter, a histogram mode, and a cover property.
8. **Every variable stage is declared + bounded + counted + histogrammed.** If the counter and the histogram disagree, that is a P1, not a curiosity.
9. **Fixed latency wherever the worst case fits the budget.** Padding is justified only against a competitive threshold, an unbounded excursion, or a load-correlated one — never reflexively.
10. **Every fast-path block carries a cycle-exact latency contract** (§4.2), including the cover property. An untaken cover means the tail case is untested.
11. **Every fast-path memory declares `RD_LATENCY` explicitly and asserts it.** A latency that is a placement outcome is not a budget.
12. **`BYPASS_DEPTH = RAM_RD_LAT`.** Bypass, never stall. They are the same number, parameterised together.
13. **Per-stage trace stamps ride in the production bitstream, alongside the payload, never consumed by fast-path logic.** Proven by a `TRACE=0` equivalence check.
14. **The tail-capture buffer is armed at last session's p99.9.** `overrun_cnt > 0` means raise the threshold.
15. **Never publish a latency distribution without the suppressed-event counts.** A histogram that improved because orders stopped being sent is the worst report in this domain.
16. **Message straddling and packet packing are budgeted, not fixed.** Condition every histogram on `k`, the message index within the datagram.
17. **Record `Tj` with every measurement, and alert on error-counter/`Tj` correlation** — not on temperature alone.
18. **Fast-path memory is fabric BRAM/URAM only.** The moment it is not, host DMA becomes an unbounded jitter source.

---

## Further reading

- [../00-foundations/01-digital-logic-and-timing.md](../00-foundations/01-digital-logic-and-timing.md) — §5, determinism as the product; where cycles come from
- [../00-foundations/04-clocking-reset-and-cdc.md](../00-foundations/04-clocking-reset-and-cdc.md) — the four sanctioned CDC primitives and their costs
- [../00-foundations/05-timing-closure.md](../00-foundations/05-timing-closure.md) — clock jitter, the *other* jitter, and where margin lives
- [../01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) — II = 1 and why it removes queueing
- [../02-networking/03-multicast-feeds-and-arbitration.md](../02-networking/03-multicast-feeds-and-arbitration.md) — A/B arbitration, packet packing, skew histograms
- [../04-system-architecture/01-tick-to-trade-pipeline.md](../04-system-architecture/01-tick-to-trade-pipeline.md) — §5, the jitter inventory this file expands
- [../04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md) — §6.3, the one operation that is not O(1)
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — credit, TCP ownership, fail-closed
- [../04-system-architecture/06-cpu-fpga-partitioning.md](../04-system-architecture/06-cpu-fpga-partitioning.md) — the host behaviours that reach the fabric
- [../05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md) — §5, §6, §10: fixed/variable rows, four numbers per row, the CI gate
- [../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md) — the histogram, percentiles from buckets, the reporting standard, A/B method
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) — §3, running the histograms in production
- [01-queue-position-and-fill-probability.md](01-queue-position-and-fill-probability.md) — §6, the elasticity `ε` the §2 arithmetic borrows
- [03-cancel-latency-and-pickoff.md](03-cancel-latency-and-pickoff.md) — the fat-tailed downside that makes cancel strict-priority
- [06-timing-report-forensics.md](06-timing-report-forensics.md) — clock jitter, WNS margin, and congestion-driven latency
- [08-market-open-and-close-dynamics.md](08-market-open-and-close-dynamics.md) — why the tail regime and the payoff regime are the same regime
- [09-failure-modes-and-postmortems.md](09-failure-modes-and-postmortems.md) — what these jitter sources look like after they have cost money
