# 09.07 — Jitter Sources and Determinism

> **Why this matters here:** `rtl/fpga_top.sv` marks every stage `fixed` or `var`, and
> exactly **one** row is `var`. That column is the design philosophy compressed to one
> character per line. This file is why the column exists, what each `fixed` costs to keep
> fixed, what the single `var` is allowed to cost, and — the part usually skipped — how you
> *attribute* a bad p99.9 to a stage instead of staring at it.
> [04.01](../04-system-architecture/01-tick-to-trade-pipeline.md) §5 lists the sources;
> [05.01](../05-optimization/01-latency-budgeting.md) §5–§6 budgets them. This is the deep
> dive that gives each a mechanism, a magnitude, a detector and a mitigation.

---

## 1. Two things are called "jitter". Only one is this document.

| Term used here | Definition | Units | Where it lives |
| --- | --- | --- | --- |
| **Clock jitter** | Phase noise on a clock edge — deviation of an actual edge from its ideal time. Random + deterministic. | **picoseconds** | GT refclk, MMCM. Eats setup margin. [00.05](../00-foundations/05-timing-closure.md) |
| **Latency dispersion** | The distribution, across events, of wire-to-wire tick-to-trade. | **ns / core cycles** | Everything in §3. Eats money. |

They meet in exactly one place — §3.9, where die temperature moves propagation delay and
clock jitter together — and nowhere else. **"Jitter" unqualified means latency dispersion
throughout this file**, and the two are never used interchangeably. Timing report →
[06-timing-report-forensics.md](06-timing-report-forensics.md). Latency histogram → here.

### 1.1 The thesis

This is not a throughput system where the mean is the product. You enter a **discrete
race** once per triggering event, and the only latency that decides event *i* is your
latency **on event *i***.

```
   p50 = 300 ns, p99.9 = 900 ns          p50 = 340 ns, p99.9 = 355 ns
   ───────────────────────────           ───────────────────────────
   wins the 999                          wins the 999 (slightly less often)
   loses the 1                           wins the 1
   → worse mean, strictly better system ─────────────────────────────┘
```

And the 1-in-1000 is not uniformly drawn.

> **Thesis: latency dispersion is not noise around a mean. It is concentrated in exactly
> the states where money is made and lost.** Every tail mechanism in §3 — packet packing,
> arbitration collision, FIFO occupancy, credit starvation, thermal drift at 14:00 — is
> *load-triggered*. Load means a burst; a burst means the market is moving; a moving market
> is when the trade is worth 10–50× a quiet-tape trade
> ([08-market-open-and-close-dynamics.md](08-market-open-and-close-dynamics.md)). The tail
> and the payoff are drawn from the same variable and are **positively correlated by
> construction**.

A histogram weights every event equally. The market does not. That is why CLAUDE.md §5
rule 8 exists.

---

## 2. ⚠️ Why a p99.9 regression outweighs a p50 improvement

Assert this and nobody believes it. Do the arithmetic and it stops being arguable.

```
Session EV = Σ_races  P(win | our latency on that race) × V(race)
  ε — competitive elasticity, percentage points of win probability per ns
  V — value of winning, which is NOT constant across races
```

> **ILLUSTRATIVE, derived here.** `ε = 0.034 pp/ns` is carried from
> [01-queue-position-and-fill-probability.md](01-queue-position-and-fill-probability.md) §6
> (3.4 pp per 100 ns). Every figure below inherits that file's warning: the arithmetic is
> the deliverable, the numbers are placeholders until measured.

**Races are not homogeneous.** Decompose one session:

| Regime | Races | Share of count | `V`/race | Share of value | Latency regime |
| --- | ---: | ---: | ---: | ---: | --- |
| Quiet tape | 180,000 | 90.0 % | $0.20 | 60.6 % | p50 |
| Active | 19,000 | 9.5 % | $0.60 | 19.2 % | p50 → p99 |
| **Burst** | **1,000** | **0.5 %** | **$12.00** | **20.2 %** | **p99 → max lives here** |
| | 200,000 | | | $59,400 | |

**Burst races are 0.5 % of the count and 20 % of the value.** That asymmetry is the whole
argument, and it is invisible to any instrument reporting percentiles over an unweighted
event stream.

A change buying 20 ns at p50 (three core cycles — a large win) via a structure that
degrades under load, costing 400 ns during bursts:

```
GAIN — body, ε = 0.034 pp/ns over 20 ns ⇒ +0.68 pp win rate
    quiet  180,000 × 0.0068 × $0.20  =   +$244.80
    active  19,000 × 0.0068 × $0.60  =   +$ 77.52        →  +$322.32 / session

LOSS — burst. +400 ns is >3× the whole 128 ns fabric budget: we are not in the
       race at all. Assume we previously won 55 % of burst races.
    burst   1,000 × 0.55 × $12.00    = −$6,600.00 / session

NET   −$6,277.68 / session   ⇒   ≈ −$1.58 M / year at 252 sessions
```

> **Verify:** sessions per year from the **Nasdaq trading calendar**.

**The break-even is the number to remember.** The p50 gain is worth $16.1/ns, so paying for
that tail regression needs **410 ns** of p50 improvement. The entire fabric budget in
`rtl/fpga_top.sv` is **128 ns**. *No p50 improvement available anywhere in this design pays
for that tail regression* — delete the fabric entirely and you are still short.

**Second order: tail events are clustered.** The loss above is not 550 independent small
losses.

| Naive view | Reality |
| --- | --- |
| 0.1 % of events are slow, drawn at random | Slow events arrive in **runs**; one burst produces tens consecutively |
| Losses diversify across the session | You lose the **whole burst**, and bursts are where the volume is |
| p99.9 is a tail statistic | Inside a burst, p99.9 latency is the **modal** latency. The regime is not rare — its *sampling weight* is |

⚠️ **A tail source that only fires under load looks like a rounding error in every
measurement taken on a quiet wire.** Hence market-open replay is the published load profile
and idle is the *floor*, never the headline
([05.04](../05-optimization/04-measurement-and-profiling.md) §8).

> **RULE: CI gates on p99.9 and max, not the mean.** Lower p50 with worse p99.9 is a
> **regression**, reverted by default; overriding needs a written argument and a named
> signer. Gate mechanics: [05.01](../05-optimization/01-latency-budgeting.md) §10.
> Accept/reject table: [05.04](../05-optimization/04-measurement-and-profiling.md) §10.
> Wire the gate to them; do not restate them.

---

## 3. The systematic inventory

Magnitudes at **6.4 ns/cycle** (156.25 MHz). The master table is §3.10.

### 3.1 Arbitration

| Arbiter | Best case | Worst case | Effect on the distribution |
| --- | --- | --- | --- |
| **Strict priority** | Priority-0 waits **0** (or one non-preemptible transfer) | Lowest priority **unbounded** under sustained load | Splits into two distributions: a spike for priority 0, a fat tail for everyone else |
| **Round-robin (fair)** | Everyone waits ≥ 0, typically more than priority-0 would | Bounded at **(N−1) grants**, for everyone | One distribution: wider body, **shorter tail** |

> **A fair arbiter has a *better* worst case and a *worse* best case than a priority
> arbiter.** That is the entire trade, and it makes "fair" right for shared infrastructure
> and wrong for a fast path. On a fast path you do not want fairness; you want to be
> priority 0 and for nobody else to exist.

| Point here | Design | Cost on the delivered path |
| --- | --- | --- |
| **A/B feed** (`u_net_rx`) | No arbiter. First arrival wins; the sequence check *is* the dedupe ([02.03](../02-networking/03-multicast-feeds-and-arbitration.md) §5) | **0 cycles.** The loser is a duplicate discarded by logic that had to exist |
| **A/B port mux** | Fixed priority A over B, locked at **packet** granularity SOP→`tlast` | 0 when the loser is a duplicate. Non-zero only when A and B carry different sequences (post-gap), bounded by one max-frame drain: ⌈1518×8/`AXIS_W`⌉ ≈ **24 cyc ≈ 154 ns at 512 b/beat, ILLUSTRATIVE** |
| **TX: order vs cancel** | **Strict priority to cancel**, always ([01](01-queue-position-and-fill-probability.md) §5.1, [03](03-cancel-latency-and-pickoff.md)) | Cancel 0; new order ≤ one in-flight cancel frame. Bounded upside vs unbounded pickoff is not a close call |
| **Fast-path memory ports** | None. Simple dual-port, fast path owns port A ([04.01](../04-system-architecture/01-tick-to-trade-pipeline.md) §4) | **0 by construction** |

> **Verify:** the 1518-byte maximum untagged frame from **IEEE 802.3**; `AXIS_W` from
> `rtl/pkg/trading_pkg.sv`, which is the contract, not this table.

> **RULE: the fast path has nothing to arbitrate for.** Every arbiter is off it or resolves
> in its favour in zero cycles. Adding a fast-path arbiter requires a budget row *and* a
> jitter row. Count `arb_collisions` and `ingress_fifo_high_water` per port regardless.

### 3.2 FIFO occupancy

**A FIFO that is sometimes empty and sometimes deep is a variable delay by construction.**
Occupancy `d` costs `d` cycles, and occupancy is set by arrival statistics you do not
control.

| Structure | Latency | Dispersion |
| --- | --- | --- |
| **Cut-through** MAC (`CUT_THROUGH(1)` in `fpga_top.sv`) | 2 cyc / 12.8 ns per the budget | **~0** |
| **Store-and-forward** MAC | Whole frame before the first byte emerges | Data-dependent: 1518 B × 0.8 ns/B ≈ **1214 ns**, larger than the whole budget |
| **Elastic / clock-comp buffer** in GT+PCS | Absorbs the ppm offset between recovered and local clocks | **±1–2 cyc (±6.4–12.8 ns)**, continuous. `LOW_LATENCY(1)` bypasses where the GT permits; **irreducible** where it does not |
| **Skid buffer, always full** | 1 cyc | 0 — *constant* occupancy is a fixed delay. That is the point |
| **Skid buffer that fills and drains** | 0–1 cyc | 1 cyc, data-dependent |
| **Fast path R0→T6** | No FIFOs. Single-cycle valid pulse, no ready, II = 1, drop-and-count ([04.01](../04-system-architecture/01-tick-to-trade-pipeline.md) §7.1) | **0** |

> **Verify:** 0.8 ns/byte at 10GbE from **IEEE 802.3 Clause 49**; elastic-buffer and bypass
> latency from **AMD UG578** and your Ethernet subsystem product guide, for your exact
> configuration.

> **RULE: on the fast path, prefer constant occupancy or none at all.** An always-occupied
> depth-1 register beats a usually-empty depth-4 FIFO even though the FIFO has a lower mean.

### 3.3 Message straddling and packet packing — the data-dependent one

Most often forgotten, and the only source here that **cannot be designed away**.

```
(1) LENGTH varies by ITCH type. Order Delete is the shortest message in the
    catalogue; Add Order with MPID attribution is among the longest.
(2) STRADDLING. With a 64-byte beat, a message wholly inside one beat costs one
    beat to assemble; one crossing a boundary costs two. Whether it straddles
    depends on its BYTE OFFSET, which depends on every message ahead of it.
        ⇒ +0 or +1 cycle  (0 or 6.4 ns)
(3) PACKING. MoldUDP64 carries N messages per datagram; the Nth arrives after the
    first. At II = 1 each preceding BOOK-AFFECTING message costs one cycle;
    preceding filtered messages cost zero.
        ⇒ +0 to +(k−1) cycles for the kth book message in the packet
```

**ILLUSTRATIVE spread:** a datagram with up to 10 book-affecting messages gives `0…9`
cycles of packing plus `0…1` of straddle = **0–10 cycles = 0–64 ns** on a 128 ns fabric
budget — a **50 % excursion** decided entirely by which slot in the venue's datagram your
trigger landed in.

> **Verify:** the message catalogue and every length from the **Nasdaq TotalView-ITCH 5.0
> specification** ([08.04](../08-nasdaq/04-totalview-itch-5.0.md)); the MoldUDP64
> message-count field from the **MoldUDP64 specification**.

⚠️ **Not a defect, and no mitigation removes it.** The venue chose the packing. Wider beats
reduce straddling but not packing; parallel per-type dispatch reduces packing cost but not
to zero. **It is budgetable, not fixable.**

> **RULE: histogram tick-to-trade *conditioned on message index `k` within the datagram*.**
> The highest-value conditioning variable in the system. An unconditioned p99.9 that moved
> tells you nothing; one that moved *for k = 1* is a real regression, while one that moved
> only for `k ≥ 5` is the venue packing more densely today. Carry `k` in tail-capture
> context (§5.3) and never publish a latency number without the `k`-distribution of its
> load.

### 3.4 Clock domain crossing

| Primitive | Latency | Dispersion | Mechanism |
| --- | --- | --- | --- |
| **2-FF level sync** | 2 dst cycles | **1 cyc (6.4 ns)** | The source transition lands at an arbitrary phase; it is captured on this edge or the next. Structural. Adding a stage adds fixed latency, not certainty |
| **Toggle/pulse sync** | ~3 cyc | 1 cyc | Same, plus a rate limit ([00.04](../00-foundations/04-clocking-reset-and-cdc.md) §3.2) |
| **Gray async FIFO** | ~2–3 dst cyc | **1–2 cyc, drifting** | Pointer sync plus occupancy; occupancy oscillates on the beat period of the two clocks. Not white noise |
| **req/ack handshake** | 4–6 cyc round trip | 1–2 cyc | Control plane only |

CDC is confined to the MAC and PCIe boundaries (`fpga_top.sv` HARD RULE 5):

| Boundary | On T2T? | Contribution |
| --- | --- | --- |
| MAC RX `rx_clk`→`core_clk` async FIFO | **yes** | ~2–3 cyc latency, **~1 cyc (6.4 ns) dispersion**, plus §3.2's elastic buffer. Both sit inside the "MAC RX 2 cyc" budget row; neither is removable |
| MAC TX `core_clk`→TX clock | **yes** | Same order, inside the MAC TX row |
| PCIe ↔ core (`u_host_ctrl`) | no | 0 ns on T2T. Bounds credit return (§3.7) and parameter commit |
| `ext_kill_n` (`cdc_sync_bit STAGES(3)`) | no | +3 cyc on kill response — which is why `KILL_RESP_CYCLES` is a declared parameter, not a hope |

> **RULE: no CDC between the MAC RX egress register and the MAC TX ingress register.** One
> 2-FF synchronizer added to a fast-path control bit "just to be safe" costs a full cycle of
> dispersion on **every** event — a body-wide regression disguised as a defensive measure.
> If a fast-path signal appears to need synchronizing, the bug is that it left the domain.

### 3.5 The declared variable stage: delete-the-best

`fpga_top.sv` marks one row `var*` — **"Book level update + incremental top-of-book"**,
footnoted *"a best-level delete that forces a new-best search"*. The canonical jitter source
and the worked example of the whole policy.

**Mechanism.** ITCH is order-based. A `D` Delete (or the final `E`/`X` emptying a level)
removes the last order at the current best price; the new best is the next-occupied level,
and *finding it is a search* — the only search left on the fast path.

**Why it is bounded** — by structure, not by the data being kind
([04.03](../04-system-architecture/03-order-book-in-hardware.md) §6.3):

| Mitigation | Mechanism | Cost |
| --- | --- | --- |
| **(a) Cached second-best** | `bid2_lvl`/`bid2_qty` maintained by the same incremental rules; promote on a best-emptying delete | **0 extra cycles.** Covers the large majority |
| **(b) Occupancy bitmap + bounded priority encode** | Read the 256-bit bitmap word holding the old best, mask at-or-above, encode down; if empty, one adjacent word | **+2 cyc = 12.8 ns.** Hard-bounded at **two** words |
| **(c) Bounded depth** | Both words empty ⇒ publish `bid_valid = 0` and let the strategy gate | **0.** A third word is never read |

**Magnitude in context:** +2 cycles on a 20-cycle fabric total gives 22 cyc = 140.8 ns,
wire-to-wire ~333.6 ns against the ~320.8 ns target. **The one declared variable stage moves
wire-to-wire by 4.0 %** — which is exactly why it is permitted. Frequency ≈ **1 % of book
messages** ([04.03](../04-system-architecture/03-order-book-in-hardware.md) §6.4, estimates
pending pcap measurement).

⚠️ Rejected alternatives: a full 2048-wide priority encode is `⌈log₂2048⌉ = 11` cyc =
70.4 ns, **more than double the entire book budget**; a sorted structure (heap, skip list,
list) replaces a bounded excursion with a variable one *and* a worse mean — worse on both
axes.

> **RULE — the template for every variable stage; the book is the only instance.**
> 1. The bound is **documented** in the module header in cycles and ns, matched by a
>    `VAR_CYCLES` parameter.
> 2. Each occurrence is **counted** in `book_stat` (`rescan_cnt`), CSR-readable.
> 3. The **histogram bucket is inspected** every session: `u_telemetry` (`N_BUCKETS = 32`)
>    must show a secondary mode exactly `VAR_CYCLES` above the primary with mass matching
>    `rescan_cnt / n`. **If the counter and the histogram disagree, one is lying and you do
>    not know which** — that is a P1.
> 4. The variable path is **covered** in regression (§4.2). An untaken cover means the
>    testbench never exercises the case that produces your tail.

### 3.6 Memory: banking, cascade depth, and bypass depth

| Effect | Mechanism | Magnitude | Status here |
| --- | --- | --- | --- |
| True-dual-port collision | Two agents hit one BRAM in a cycle | +1 cyc, or undefined read data | **Structurally impossible**: simple dual-port, fast path owns port A, telemetry reads port B |
| **URAM cascade hop** | A wide array spans several URAM288s; each hop adds a register stage | **+1 cyc/hop** ([05.01](../05-optimization/01-latency-budgeting.md) §9) | ⚠️ Cascade depth is a **placement outcome** — the same RTL can build at different latencies across runs, visible only in hardware |
| Bank conflict | Two accesses to one bank in a cycle | +1 cyc, load-dependent | Single fast-path reader on the level array |
| **RMW same-address hazard** | Back-to-back updates to one `(slot, level)` — **common, not rare** | +1 cyc **if stalled** — not a tail, a **bimodal body**, firing hardest when the tape is busiest | **Write-forwarding bypass**: a 2-input mux and a comparator, well inside 6.4 ns ⇒ **0 cyc** ([04.03](../04-system-architecture/03-order-book-in-hardware.md) §8) |

> **RULE: every fast-path memory is instantiated through a wrapper with an explicit
> `RD_LATENCY` parameter, asserted against the instantiated primitive.** A latency that is a
> build outcome is not a budget.
> **RULE: `BYPASS_DEPTH = RAM_RD_LAT`, parameterised together, always.** Bypass, never
> stall. A bypass one stage too shallow produces silent book drift, just less often — harder
> to find, not easier. This couples the two rules: a retiming that adds an output register
> for Fmax silently invalidates the bypass.
> **Verify:** URAM288 geometry, cascade rules and per-hop latency from the **AMD UltraScale
> Architecture Memory Resources user guide** and the synthesis report — never from a table.

### 3.7 Credit starvation — the stall that *improves* your histogram

`credit_avail` bounds how many orders the FPGA may emit before the host has accounted for
them. It is a **risk bound, not flow control**
([04.05](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) §9). Exhausted,
the risk gate rejects with `RISK_NO_CREDIT` and the order is **not sent** — fail-closed, not
fail-slow, because a queued order is a stale order. From the strategy's view this is a
latency event of **unbounded duration**: nothing happens until credit returns, a host round
trip (**~10–50 µs, ILLUSTRATIVE**).

⚠️ **The instrumentation trap, and it is a bad one.** `u_telemetry` samples on
`order_out_valid` — when an order *leaves*. A suppressed order produces **no sample at
all**, so credit starvation makes the histogram look **better** by removing exactly the
events that occurred under the heaviest load. A system failing to trade during bursts
reports a beautiful p99.9.

> **RULE: `credit_starved` is counted, alerted, and reported *alongside* every latency
> distribution.** A latency report without the suppressed-event count is a
> survivorship-biased sample. `n_samples + credit_starved + risk_rejects` must reconcile
> against trigger count, or you are reading a filtered distribution.

⚠️ **The failure mode that looks like a fabric problem.** If host credit return is slow or
periodic (poll loop, interrupt-coalescing timer, scheduler quantum), `credit_avail` develops
a **sawtooth**: full, drained by a burst, refilled on the host's period. The symptom is a
*periodic* pattern of suppressed orders whose period matches nothing in the fabric.
Engineers spend days in timing reports. **Diagnostic:** plot `credit_starved` increments
against wall clock and look for a spectral line at the host poll period; if one exists the
problem is [04.06](../04-system-architecture/06-cpu-fpga-partitioning.md), not the RTL.
Raising `MAX_IN_FLIGHT` "to fix the stalls" trades supervised risk for order rate and is an
approved risk decision, never a performance tweak.

### 3.8 TCP retransmit on the order path

| Property | Value |
| --- | --- |
| Mechanism | A lost or corrupted segment on the OUCH/SoupBinTCP session; the sender waits a retransmission timeout |
| Magnitude | The RTO minimum — **hundreds of milliseconds**, i.e. **10⁶×** the fabric budget, roughly 10⁵ races |
| Why rare | A short, dedicated, uncongested colo cross-connect drops essentially nothing ([08.08](../08-nasdaq/08-connectivity-and-colocation.md)) |
| Why catastrophic anyway | It is not a tail *of* the distribution, it is a different distribution. No bucketing resolving 6.4 ns also resolves 200 ms |

> **Verify:** the RTO computation and its minimum from **RFC 6298**, and the effective
> minimum from your host TCP stack's configuration — they differ, and the stack's value is
> operative.

**The design consequence, and why the ownership split in
[04.05](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) §8 has its shape:**
TCP state is **host-owned with a fabric fast-send**. Retransmission is a CPU job. On
duplicate ACKs, out-of-order ACK, closed window, or SoupBin sequence mismatch the FPGA
**stops emitting and hands ownership to the CPU**. A retransmit therefore never lengthens
the fabric path — it is converted into a *counted functional event* (`tx_blocked`) instead
of an unbounded latency event. **That conversion is the mitigation.** Putting retransmission
in fabric would move a 200 ms tail *onto* the measured path, which is precisely backwards.

### 3.9 Telemetry, resets, and thermal drift

| Source | Mechanism | Magnitude | Mitigation |
| --- | --- | --- | --- |
| **Telemetry resource share** | Telemetry contends for a memory port or arbiter with the fast path | +1 cyc, **unbudgeted** — the most common way [04.01](../04-system-architecture/01-tick-to-trade-pipeline.md) §4 is violated | Observer-only: consume a `valid+delta` pulse, never backpressure; port B only |
| **Telemetry congestion** | Telemetry placed inside the fast-path pblock competes for routing | WNS loss ⇒ Fmax loss. A latency effect appearing in **no functional simulation** | Floorplan outside the pblock; constrain the readback crossing |
| **Parameter commit** | Double-buffered shadow bank, single-cycle atomic flip | **0 cyc** | ⚠️ A multi-cycle copy forces a choice between stalling (jitter) and reading a half-written record (**wrong trade**). Atomicity *is* the mitigation |
| **Reset / arm flush** | Pipeline drain after release | ≤ 20 cyc = 128 ns, once | Do not trade for a documented number of cycles post-release; `core_rst` is fail-closed |
| **`cycle_cnt` reset** | The measurement time base restarts | All deltas spanning it are garbage | ⚠️ `cycle_cnt` is **never reset after initial release** — that comment in `fpga_top.sv` is a measurement contract, not style. Discard samples whose `t0` predates the last release |

```tcl
# constraints/floorplan.xdc — telemetry may observe the fast path but not share
# its silicon. The pblock is the enforcement; a code review is not.
create_pblock pb_fastpath
add_cells_to_pblock pb_fastpath [get_cells {u_net_rx u_feed u_book u_strategy \
                                            u_risk_gate u_order_gw}]
resize_pblock pb_fastpath -add {SLR1}
set_max_delay -datapath_only 20.000 \
    -from [get_cells u_telemetry/*] -to [get_cells u_host_ctrl/*]
```

⚠️ **Never quote a latency number from a bitstream containing an ILA**
([05.04](../05-optimization/04-measurement-and-profiling.md) §6). The corollary is stronger
than it looks: **the instrumentation in §5 must be in the production bitstream**, because an
instrumented debug build measures a different design.

**Thermal and voltage drift** is where clock jitter and latency dispersion touch, and it is
a real p99.9 driver that almost nobody instruments. Static timing closes at a worst-case
corner, but propagation delay *and* clock jitter both vary with `Tj` and `Vccint` **during
the session**. ⚠️ **The failure mode is not "it gets slower"** — a synchronous pipeline takes
the same cycles at any temperature. Instead a marginal path starts **intermittently
violating setup**: a corrupted field, a dropped event, a mis-decoded message. Its signature
is a defect rate tracking the **temperature curve**, not the message rate — afternoons, hot
aisles, gone overnight in the lab.

> Log `Tj` at 1 Hz alongside every counter and **alert on correlation between any error
> counter and `Tj`**, never on `Tj` alone. Hold a WNS margin rather than closing at zero
> ([06-timing-report-forensics.md](06-timing-report-forensics.md),
> [05.02](../05-optimization/02-fmax-and-timing-optimization.md)). Record `Tj` in the
> conditions line of every report (§6).
> **Verify:** operating temperature range, `Vccint` tolerance and monitor accuracy from the
> **AMD UltraScale+ device datasheet** for your speed grade.

**The host** is slow-path only, and reaches the fast path through three bounded channels:
credit return (§3.7), parameter commit, and the kill heartbeat. DMA and telemetry readback
contribute **0 ns** to T2T — ⚠️ **but that zero is a design choice, not a law.** The moment
any fast-path structure moves to HBM, DDR, or a NoC-attached memory, host DMA and the fast
path share a controller and a queue, and PCIe becomes a first-class jitter source with an
unbounded load-dependent tail. **Every fast-path memory in this design is fabric BRAM or
URAM, and that is not negotiable for a resource saving.**

### 3.10 Master inventory

`ILL` = ILLUSTRATIVE, derived from the `fpga_top.sv` budget at 6.4 ns/cycle; measure before
relying on it.

| # | Source | Mechanism | Magnitude (cyc / ns) | Kind | Detect by | Mitigation | Residual |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | A/B feed arbitration | First-arrival wins; dedupe is the seq check | 0 | design | `feed_a_wins`, skew histogram | No arbiter exists | **0** |
| 2 | A/B port-mux collision | Two ports present a beat in one cycle | 0 → ~24 / ~154 (ILL) | data | `arb_collisions`, FIFO high-water | Fixed priority, packet-granular lock | ~0 (loser is a dup) |
| 3 | TX order vs cancel | Shared TX stream | cancel 0; order ≤ 1 frame | design | `tx_defer_cnt` | Strict priority to cancel | Deliberate, bounded |
| 4 | MAC elastic buffer | Clock compensation, gearbox slip | ±1–2 / ±6.4–12.8 | phys | Idle-load histogram width | `LOW_LATENCY(1)`, bypass where permitted | **Irreducible** |
| 5 | Store-and-forward MAC | Whole frame before first byte out | ≤ ~1214 ns | design | Idle p50 vs frame size | `CUT_THROUGH(1)` | **0** |
| 6 | Fast-path FIFOs | Occupancy = delay | 0 | design | Structural review | None exist; valid-pulse, no ready, II=1 | **0** |
| 7 | **Message straddling** | Message crosses a 64 B beat | +0/+1 → 0–6.4 | **data** | Histogram by message type | None. Budget it | **0–6.4 ns, permanent** |
| 8 | **MoldUDP64 packing** | kth book message in a datagram | +0 → +(k−1) / 0–57.6 (ILL) | **data** | Histogram conditioned on `k` | None. Budget worst realistic N | **0–58 ns, permanent** |
| 9 | MAC-boundary CDC | Async FIFO phase + occupancy | ~1 / 6.4 | phys | Idle histogram width | Confined to the MAC boundary | **~6.4 ns** |
| 10 | Fast-path CDC | Any synchronizer R0→T6 | +1 per crossing | design | CDC lint report | **Forbidden** | **0** |
| 11 | **Best-level delete rescan** | Delete empties best ⇒ new-best search | **+2 / 12.8, bounded** | data | `rescan_cnt` + 2nd histogram mode | 2nd-best cache; bitmap + bounded prio-enc | **+12.8 ns @ ~1 %** |
| 12 | Order-map set overflow | Hash set full ⇒ overflow probe | +2 / 12.8 | data | `omap_overflow_cnt` | 4-way + overflow region | +12.8 ns, rare |
| 13 | `U` Replace expansion | delete + insert = two `book_cmd`s | +1 / 6.4 | data | Message-type histogram | II = 1, so +1 not +5 | +6.4 ns |
| 14 | URAM cascade depth | Placement-dependent extra hop | +1 per hop | **build** | Post-route check vs `RD_LATENCY` | Explicit wrapper parameter + assertion | **0 if asserted** |
| 15 | Level RMW hazard | Same-address back-to-back | +1 **if stalled** | data | Would appear as a bimodal body | Bypass, never stall; `BYPASS_DEPTH = RAM_RD_LAT` | **0** |
| 16 | Parameter commit | Bank switch during a read | +1 if non-atomic | design | `param_commit_cnt` vs latency | Double-buffer, single-cycle atomic flip | **0** |
| 17 | Reset / arm flush | Pipeline drain after release | ≤ 20 / 128, once | design | `arm_flush_cycles` | No trading for N cycles post-release | **0 steady state** |
| 18 | **Credit starvation** | `credit_avail` = 0 ⇒ order suppressed | **unbounded**; ~10–50 µs to recover | load | `credit_starved`; ⚠️ **absent** from the histogram | Size `MAX_IN_FLIGHT`; fix host return rate | Counted + alerted |
| 19 | **TCP retransmit** | Lost segment ⇒ RTO | **~10² ms**, 10⁵–10⁶ cyc | rare | `tx_blocked`, session counters | Host-owned TCP + fabric fast-send; stop and hand over | Converted to a **functional** event |
| 20 | Telemetry resource share | Port / arbiter contention | +1, unbudgeted | design | Structural review | Observer-only, port B, no backpressure | **0** |
| 21 | Telemetry congestion | Routing pressure inside the pblock | WNS loss ⇒ Fmax loss | **build** | Timing report, not simulation | Floorplan outside the fast-path pblock | **0** |
| 22 | **Thermal / voltage drift** | Delay + clock jitter vary with `Tj`, `Vccint` | not cycles — **margin** | phys | Error-counter ↔ `Tj` correlation | Hold WNS margin; record `Tj` per report | Monitored |
| 23 | Host PCIe / DMA | Shared memory controller | **0 here**; unbounded if violated | design | N/A while the constraint holds | Fast-path memory is fabric BRAM/URAM only | **0, conditionally** |

---

## 4. The case for fixed latency, made rather than asserted

**Fixed latency** = the same number of cycles for every input, every data value, every load.
Not "usually". Every.

| Costs | Benefits |
| --- | --- |
| You pay the **worst case on every event**, including the 99 % that did not need it | The distribution **collapses to a spike**: p50 = p99.9 = max |
| Some resources idle on most events | The tail **does not exist**, so it cannot correlate with bursts (§1.1) |
| More logic, sometimes, to make the slow case fast rather than the fast case slow | **Verifiable**: you can assert cycle-exact latency in a testbench — a *proof*, not a measurement |
| Can be **worse in expectation** than a variable design | **Reproducible**: a simulation replay predicts hardware cycle-for-cycle, so regressions are caught in CI, not production |

The third benefit is systematically undervalued. A cycle-exact contract turns "we measured
it and it seemed fine" into "the build fails if it is not exactly this". Nothing else
converts a performance property into a compile-time property.

### 4.1 The contract, in SystemVerilog

```systemverilog
// Latency contract. Every fast-path block instantiates this.
//   FIXED_CYCLES : declared latency, matching the fpga_top.sv budget row
//   VAR_CYCLES   : the ONLY permitted excursion. 0 for a fixed-latency block.
//   var_expected : asserted combinationally at s_valid when the declared variable
//                  case applies. A PREDICTION the block must honour — not a
//                  post-hoc excuse.
`ifndef SYNTHESIS
    // 1. The envelope. Nothing may EVER land outside it.
    assert property (@(posedge clk) disable iff (rst)
        s_valid |-> ##[FIXED_CYCLES:FIXED_CYCLES+VAR_CYCLES] m_valid)
        else $error("%m: latency outside declared envelope");
    // 2. The fixed case is EXACT. Not "within". Exact.
    assert property (@(posedge clk) disable iff (rst)
        (s_valid && !var_expected) |-> ##FIXED_CYCLES m_valid)
        else $error("%m: fixed case took other than %0d cycles", FIXED_CYCLES);
    // 3. So is the variable case, at its own number. A block that "sometimes"
    //    takes the excursion has an undeclared third mode.
    assert property (@(posedge clk) disable iff (rst)
        (s_valid && var_expected) |-> ##(FIXED_CYCLES+VAR_CYCLES) m_valid)
        else $error("%m: variable case took other than %0d cycles",
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

`VAR_CYCLES = 0` collapses 1–3 into a single exact-cycle contract and makes 3 vacuous —
the correct shape for every block in this design except one.

### 4.2 The counter-argument, taken seriously

**Fixed latency at the worst case can be worse in expectation.** Pad the book stage to
always take 4 cycles instead of 2-with-a-bounded-+2:

```
Variable (current) : p50 = 2 cyc, p99.9 = 4 cyc, max = 4 cyc.   Mean ≈ 2.02 cyc
Padded to fixed    : p50 = p99.9 = max = 4 cyc.                 Mean  = 4.00 cyc

Padding costs +12.8 ns on EVERY event and removes an excursion already bounded,
already counted, already inside budget, already only 4 % of wire-to-wire.
Via §2's elasticity: 12.8 ns × 0.034 pp/ns × $47,400 of body value ≈ −$206/session,
for a p99.9 improvement of exactly ZERO — p99.9 was already 4 cycles.
```

Padding here is **strictly worse**. So the rule is conditional, not absolute:

> **THE PROJECT RULE — fixed latency on every stage where the worst case is within budget;
> variable latency only where it is declared, bounded, counted, and histogrammed.**

Padding is right when, and only when, one of these holds:

| Condition | Why padding wins |
| --- | --- |
| The excursion crosses a **competitive threshold** | Losing a race is a step function; being uniformly slower is not |
| The excursion is **unbounded or uncountable** | You cannot budget what you cannot bound. Pad it, or move it off the fast path |
| The excursion is **load-correlated** (fires in bursts) | §1.1: it lands on the valuable events. The common case |
| Determinism's **verification value** exceeds the mean cost | A cycle-exact contract catches regressions measurement will not |

⚠️ The book rescan does **not** satisfy condition 3 — it is triggered by book structure, not
by load. If it were burst-correlated the answer would flip. **`rtl/fpga_top.sv` is the
worked example of the rule:** fourteen `fixed` rows and one `var*`, footnoted, bounded,
counted in `book_stat`, and visible as a second mode in `u_telemetry`.

---

## 5. Measuring and **attributing** jitter

That p99.9 is 90 ns worse than yesterday tells you **nothing** about which of the 23 rows in
§3.10 did it. A single end-to-end number cannot be debugged.

### 5.1 Per-stage timestamps carried with the event

The design already carries `cycle_t rx_cycle` through `book_evt_t → book_top_t →
order_req_t → order_out_t`, and `u_telemetry` subtracts it at `order_out_valid` — that gives
the **total**. The extension gives the **decomposition**:

```systemverilog
// rtl/pkg/trading_pkg.sv — proposed addition. Carried alongside, never consumed.
typedef enum logic [3:0] { ST_RX=0, ST_DEFRAME=1, ST_DECODE=2, ST_FILTER=3,
    ST_OMAP=4, ST_BOOK=5, ST_STRAT=6, ST_RISK=7, ST_ENCODE=8, ST_TX=9 } stage_e;
localparam int unsigned N_STAGE = 10;

typedef struct packed {
    cycle_t                  t0;      // absolute ingress cycle — the ONE full stamp
    logic [7:0]              t_prev;  // low 8 bits of the previous stage boundary
    logic [N_STAGE-1:0][7:0] d;       // per-stage deltas, in cycles
} lat_trace_t;

// Per-stage latch, parameterised by STAGE_ID, dropped in at each boundary.
// Deltas, not absolute stamps: 8 bits (255 cyc = 1.63 us headroom) instead of 48.
// Unsigned 8-bit subtraction wraps correctly for any delta < 256, exactly as the
// free-running counter does for the total.
wire [7:0] now8 = cycle_cnt[7:0];
always_ff @(posedge clk) if (s_valid) begin
    m_trace             <= s_trace;                  // carry everything forward
    m_trace.d[STAGE_ID] <= now8 - s_trace.t_prev;    // this stage's cost
    m_trace.t_prev      <= now8;
end
```

| Cost (ILLUSTRATIVE) | Figure |
| --- | --- |
| Carried width | 48 + 8 + 10×8 = **136 bits** per in-flight event |
| Flip-flops | ~136 FF × ~20 occupied stages ≈ **2.7 k FF**, ~3 % of the 90 k FF budget in `fpga_top.sv` |
| Logic / added latency | Ten 8-bit subtracts, one LUT level / **0 cycles** |

> **RULE: the stamps are never on the critical path.** No fast-path expression may read
> `.d[]` or `.t_prev`; they ride alongside the payload and are consumed only at the terminal
> stage by observer logic. Enforce with a lint rule *and* a simulation equivalence check
> proving a `TRACE=0` build produces byte-identical outputs.
> **RULE: the trace ships in the production bitstream.** A debug build has different
> placement and routing and therefore different latency
> ([05.04](../05-optimization/04-measurement-and-profiling.md) §7) — its numbers describe a
> design you do not ship.

⚠️ **Per-stage marginal histograms cannot answer the question you have.** "Stage 8 has a
tail" and "stage 3 has a tail" does not say whether those were the *same* events. Tail work
needs the **joint** distribution for the handful of events that were actually slow, and a
histogram discards exactly that.

### 5.2 The tail-capture buffer

A small circular buffer recording the full stage decomposition **plus context** for any
event whose total exceeded a host-set threshold. The single most valuable instrument for
tail work.

```systemverilog
// rtl/telemetry/tail_capture.sv
//  Budget row : none — observer only, 0 cycles on the datapath.
//  Resources  : DEPTH x 256 b. At DEPTH=256 that is 64 Kbit = 2 BRAM36.
module tail_capture import trading_pkg::*; #(parameter int unsigned DEPTH = 256) (
    input  var logic        clk, rst,
    input  var logic        s_valid,       // one pulse per completed T2T event
    input  var lat_trace_t  s_trace,
    input  var cycle_t      s_now,
    // Context: the attribution question is "what was happening", not "which gate
    // was slow". These fields answer it.
    input  var logic [7:0]  ctx_msg_type,  // ITCH type
    input  var sym_idx_t    ctx_sym,
    input  var logic [7:0]  ctx_msg_idx,   // kth message in the Mold datagram (§3.3)
    input  var logic [15:0] ctx_rate,      // book events in the last 1024 cycles
    input  var logic [15:0] ctx_flags,     // rescan | omap_ovf | gap | credit | feed
    input  var logic [23:0] cfg_threshold_cyc,          // set from LAST session's p99.9
    input  var logic [$clog2(DEPTH)-1:0] rd_addr,
    output var logic [255:0] rd_rec,
    output var logic [31:0]  captured_cnt, overrun_cnt
);
    wire [23:0] total = 24'(s_now - s_trace.t0);
    wire        arm   = s_valid && (total > cfg_threshold_cyc);
    logic [255:0] mem [DEPTH];
    logic [$clog2(DEPTH)-1:0] wptr;
    always_ff @(posedge clk) begin
        if (rst) begin wptr <= '0; captured_cnt <= '0; overrun_cnt <= '0; end
        else if (arm) begin
            mem[wptr] <= {s_trace.t0, total, s_trace.d, ctx_msg_type, ctx_sym,
                          ctx_msg_idx, ctx_rate, ctx_flags};
            wptr <= wptr + 1'b1;  captured_cnt <= captured_cnt + 1'b1;
            if (wptr == '1) overrun_cnt <= overrun_cnt + 1'b1;   // wrapped un-drained
        end
    end
    assign rd_rec = mem[rd_addr];
endmodule
```

| Parameter | Value | Reasoning |
| --- | --- | --- |
| `DEPTH` | 256 records | 64 Kbit = 2 BRAM36, trivial against the 300-BRAM budget |
| `cfg_threshold_cyc` | **last session's p99.9**, never a constant | A constant stops capturing when the design improves and floods when it regresses |
| Arm rate | ~10⁻³ × event rate | At 10⁵ events/s ⇒ ~100 records/s ⇒ 256 records ≈ 2.5 s, ample for a 1 Hz drain |

⚠️ **`overrun_cnt > 0` means "raise the threshold", not "the buffer is too small".** A
threshold set too low fills the buffer with the *least* interesting tail events and
overwrites the worst ones — you capture the p99, discard the p99.99, and conclude the tail
is mild. The likeliest way to mis-operate this instrument.

### 5.3 Host-side attribution

```python
# host/analysis/tail_attrib.py — slow path, offline. Joins fabric tail-capture
# records against the feed log for a per-CAUSE table. Fabric says WHERE; feed says WHY.
import pandas as pd
STAGES = ["rx","deframe","decode","filter","omap","book","strat","risk","enc","tx"]
NS     = 6.4                                       # ns per core cycle @ 156.25 MHz

tails = pd.read_parquet("tail_capture.parquet")    # one row per armed event
feed  = pd.read_parquet("feed_log.parquet")        # decoded ITCH + Mold framing

# 1. Which stage overran? Compare each stage to its OWN median, not to the total.
excess = tails[STAGES].sub(tails[STAGES].median(), axis=1).clip(lower=0)
tails["worst_stage"]  = excess.idxmax(axis=1)
tails["excess_ns"]    = excess.max(axis=1) * NS
tails["explained_ns"] = excess.sum(axis=1) * NS    # ⚠️ far below the observed excess
                                                   # ⇒ time went BETWEEN stages: CDC,
                                                   # elastic buffer, or a missing boundary
# 2. Attach external context. "What was happening" beats "which gate was slow".
tails = tails.merge(feed[["t0","msg_type","mold_seq","msgs_in_pkt","session_phase"]],
                    on="t0", how="left")
# 3. Deliverable: one row per cause, ranked by TOTAL ns — never by count.
attrib = (tails
    .assign(cause=lambda d: d.worst_stage + " | " + d.ctx_flags.map(
        lambda f: "rescan" if f & 1 else "omap_ovf" if f & 2 else
                  "gap" if f & 4 else "credit" if f & 8 else "-"))
    .groupby(["cause","session_phase"])
    .agg(n=("excess_ns","size"), p50_excess=("excess_ns","median"),
         max_excess=("excess_ns","max"), total_ns=("excess_ns","sum"),
         median_k=("ctx_msg_idx","median"),      # kth-in-datagram: §3.3 in one column
         median_rate=("ctx_rate","median"))      # burst intensity at the time
    .sort_values("total_ns", ascending=False))
```

**Rank by total nanoseconds, not occurrence count.** A cause firing 5 times for 400 ns each
outranks one firing 5,000 times for 6.4 ns; the count-ordered table puts them backwards.
⚠️ **`explained_ns` far below the observed excess is the most informative single output
here** — the time went *between* instrumented boundaries. Chasing stages when the sum does
not reconcile loses a week.

---

## 6. The reporting standard

Every latency claim carries all of the following. Methodology — tap setup, rig offset, noise
floor, A/B statistics — is [05.04](../05-optimization/04-measurement-and-profiling.md) §9
and §10; satisfy it, do not restate it.

| Field | Requirement | Why mandatory |
| --- | --- | --- |
| `metric` | Convention, explicitly ([05.01](../05-optimization/01-latency-budgeting.md) §2) | Two conventions differ by 200 ns |
| `N`, `capture window` | ≥ 10⁶ trigger events for a p99.9 claim; wall-clock start/end | A p99.9 over N = 1,000 is noise |
| `session phase` | pre-open / open / mid-day / close / auction | The open is a different system ([08](08-market-open-and-close-dynamics.md)) |
| `p50 / p90 / p99 / p99.9 / max` | All five. `max` exact (a register); percentiles ±1 bucket | CLAUDE.md §5 rule 8 |
| `histogram overflow` | `rd_over` | A saturating top bucket reports a max that is not the max |
| **per-stage decomposition** | Median and p99.9 for each of the 10 stages | Without it the number cannot be debugged (§5) |
| **variable-stage occurrences** | `rescan_cnt`, `omap_overflow_cnt`, and their **rate** | §3.5 rule 3 — reconcile against the histogram's second mode |
| **suppressed events** | `credit_starved`, `risk_rejects`, `tx_blocked` | ⚠️ §3.7 — without these the distribution is survivorship-biased |
| `msgs-per-datagram` | Distribution of `k` over the load | §3.3 — makes two runs comparable |
| `build ID` + `GIT_SHA` + seed/directive | From the `fpga_top.sv` parameters and the run log | Latency is a property of a bitstream, not a repo |
| `source` | **`MEASURED`** or **`SIMULATED`**, capitalised | Not comparable, never summed |
| `conditions` | `Tj`, ambient, production bitstream, no debug cores | §3.9 — a report without `Tj` cannot be compared to an afternoon run |

---

## 7. Rules for this project

1. **"Jitter" here means latency dispersion; clock phase noise is "clock jitter".** Never one word for both.
2. **Dispersion is concentrated where the money is.** Tail excursions are load-triggered; load means bursts; bursts are when the trade is worth 10–50×. Never model the tail as random.
3. **CI gates on p99.9 and max.** Lower p50 with worse p99.9 is a regression, reverted by default.
4. **The fast path has nothing to arbitrate for.** Cancel beats order, always.
5. **No FIFOs on the fast path** — constant occupancy or none. R0→T6 is valid-pulse, no ready, II = 1, drop-and-count.
6. **No CDC between MAC RX and MAC TX.** Not one synchronizer, not defensively.
7. **Exactly one variable stage exists and it is declared in `fpga_top.sv`.** A second requires a budget row, a jitter row, a bound, a counter, a histogram mode and a cover property.
8. **Every variable stage is declared + bounded + counted + histogrammed.** Counter and histogram disagreeing is a P1.
9. **Fixed latency wherever the worst case fits the budget.** Padding is justified only against a competitive threshold, an unbounded excursion, or a load-correlated one — never reflexively.
10. **Every fast-path block carries a cycle-exact latency contract including the cover property.** An untaken cover means the tail case is untested.
11. **Every fast-path memory declares and asserts `RD_LATENCY`; `BYPASS_DEPTH = RAM_RD_LAT`.** Bypass, never stall. A latency that is a placement outcome is not a budget.
12. **Trace stamps ride in the production bitstream, alongside the payload, never consumed by fast-path logic** — proven by a `TRACE=0` equivalence check.
13. **Tail capture is armed at last session's p99.9.** `overrun_cnt > 0` means raise the threshold.
14. **Never publish a latency distribution without the suppressed-event counts.** A histogram that improved because orders stopped being sent is the worst report in this domain.
15. **Straddling and packing are budgeted, not fixed.** Condition every histogram on `k`.
16. **Record `Tj` with every measurement and alert on error-counter/`Tj` correlation**, not on temperature alone.
17. **Fast-path memory is fabric BRAM/URAM only.** The moment it is not, host DMA becomes an unbounded jitter source.

---

## Further reading

- [../00-foundations/01-digital-logic-and-timing.md](../00-foundations/01-digital-logic-and-timing.md) — §5, determinism as the product
- [../00-foundations/04-clocking-reset-and-cdc.md](../00-foundations/04-clocking-reset-and-cdc.md) — the four sanctioned CDC primitives and their costs
- [../00-foundations/05-timing-closure.md](../00-foundations/05-timing-closure.md) — clock jitter, the *other* jitter, and where margin lives
- [../01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) — II = 1 and why it removes queueing
- [../02-networking/03-multicast-feeds-and-arbitration.md](../02-networking/03-multicast-feeds-and-arbitration.md) — A/B arbitration, packing, skew histograms
- [../04-system-architecture/01-tick-to-trade-pipeline.md](../04-system-architecture/01-tick-to-trade-pipeline.md) — §5, the inventory this file expands
- [../04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md) — §6.3, the one operation that is not O(1)
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — credit, TCP ownership, fail-closed
- [../04-system-architecture/06-cpu-fpga-partitioning.md](../04-system-architecture/06-cpu-fpga-partitioning.md) — host behaviours that reach the fabric
- [../05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md) — §5, §6, §10: fixed/variable rows, four numbers per row, the CI gate
- [../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md) — histograms, percentiles from buckets, reporting, A/B method
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) — §3, running the histograms in production
- [01-queue-position-and-fill-probability.md](01-queue-position-and-fill-probability.md) — §6, the elasticity `ε` the §2 arithmetic borrows
- [03-cancel-latency-and-pickoff.md](03-cancel-latency-and-pickoff.md) — the fat-tailed downside behind cancel strict-priority
- [06-timing-report-forensics.md](06-timing-report-forensics.md) — clock jitter, WNS margin, congestion-driven latency
- [08-market-open-and-close-dynamics.md](08-market-open-and-close-dynamics.md) — why the tail regime and the payoff regime are the same regime
- [09-failure-modes-and-postmortems.md](09-failure-modes-and-postmortems.md) — what these sources look like after they have cost money
