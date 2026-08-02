# 09.08 — Market Open and Close Dynamics

> **Why this matters here:** the sub-microsecond tick-to-trade path in `rtl/fpga_top.sv`
> is sized for line rate by construction, so it does not care what time it is. **Everything
> around it does.** Buffers, tables, counters, the DMA rings, the host, and the die
> temperature all live on a load curve with two enormous peaks, and every one of them is
> validated by default at the quietest moment of the day. This document is the engineering
> profile of those two moments: what actually changes, which structures have a queue in
> front of them, what the arithmetic says they must be sized to, and why a soak test that
> does not contain a real open is not evidence of anything.
> [08.02](../08-nasdaq/02-sessions-auctions-and-halts.md) is the venue reference — the
> schedule, the cross mechanics, the halt taxonomy, LULD, MWCB, SSR. **Read it first.**
> This is what the FPGA has to *do* about it.

---

## 1. The trading day as a load curve

Not a schedule — a set of curves. Five of them, and they do not peak together.

```
   rate │      ██                                                  ███
        │     ████                                              ███████
        │    ██████                                           ██████████
        │   ████████  ███                                    ████████████
        │  ██████████████████▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄████████████
        └──┴────────────────────────────────────────────────────────┴────
        pre  OPEN            "11am": the easiest hour             CLOSE  post
             ▲ breadth peak, live-order peak,                     ▲ size peak,
               message-rate peak, quote lifetime minimum            imbalance-driven
```

| Curve | Shape across the session | Peaks at | Which part of the design it stresses |
| --- | --- | --- | --- |
| **Message rate** (msgs/s aggregate) | U-shaped, sharply asymmetric — near-vertical rise into the open, long midday trough, rise into the close | **Open** (usually), close a close second | Every queue; the telemetry rings; host drain |
| **Live-order count** (simultaneously resting refs in our universe) | Rises through the pre-open, spikes at the open, decays, partially rebuilds into the close | **Open** | `ORDER_MAP_ENTRIES` — [05](05-hash-tables-and-lookup-structures.md) §8 |
| **Symbol breadth** (distinct locates active per unit time) | Near-total at the open; a long tail of inactive names midday | **Open** | Symbol filter hit rate, per-symbol state RMW locality |
| **Volatility / adverse selection** | High at both ends, quiet midday | **Both**, close worst for a passive quoter | Strategy P&L — [02](02-adverse-selection-and-toxicity.md) |
| **Quote lifetime** (level survival time) | Minimum at the open — everything is fleeting | **Open** (inverted peak) | Cancel path, queue-position estimator validity |
| **Trade size / notional per print** | Modest all day, then one enormous print | **Close (the cross)** | Position and notional limits, fill accounting |

Two facts the rest of this document rests on:

1. **Peak-to-median aggregate message rate is a large multiple, not a percentage.** The
   burst is not "a busy period"; it is a different regime. **Every buffer, table, counter
   width, ring depth and host consumption rate in this design is sized to the peak, never
   to the median, and never to a whole-day average.** An average is the one statistic that
   is guaranteed to be wrong at both ends of the day.
2. **The curves peak at different moments and for different reasons.** Sizing the order map
   off the close, or the notional limits off the open, sizes the wrong thing.

> **Verify:** peak and average TotalView message rates, the burst intervals over which
> Nasdaq publishes them (per-second, per-millisecond, per-microsecond peaks are different
> numbers), and their year-over-year growth, against **Nasdaq's published market data
> capacity / message-rate statistics** (nasdaqtrader.com market data capacity documents).
> Do not carry a remembered figure into a sizing spreadsheet. Feed rates grow every year,
> and the burst statistic you need is the *shortest* window Nasdaq publishes, not the
> per-second one.

---

## 2. The open: the burst

### 2.1 The mechanism, and why it is a breadth event as much as a rate event

Between the start of order acceptance and the minutes after the continuous session opens,
a large fraction of the day's resting interest is entered, modified, and cancelled in a
compressed window: overnight orders queued by every participant land, pre-open pricing is
adjusted repeatedly as the imbalance publishes, cross-eligible interest is entered and
pulled, and at the cross itself a single print per symbol re-anchors every book —
after which every participant re-quotes into a book that just changed underneath them.

⚠️ **The distinguishing feature is breadth, not depth.** Midday, a handful of names carry
the rate and the rest of the universe is idle. At the open, *every* symbol is active
simultaneously. Structures whose cost is per-active-symbol — the filter, the per-symbol
state RMW, the order map's occupancy across sets, the per-symbol counters — see their worst
case at the open even when the aggregate rate is not at its absolute maximum.

### 2.2 Instantaneous rate vs sustained rate: what actually has a queue

The RX path sustains line rate unconditionally, by construction, and that proof is
[04.02](../04-system-architecture/02-feed-handler-design.md) §2: the shortest book-affecting
message plus MoldUDP64 framing arrives no faster than one per ~3 cycles, and the pipeline
runs at II = 1, giving ≥ 2× headroom **at 10GbE line rate**, which is a bound no market
event can exceed. CLAUDE.md hard rule 4 makes this non-negotiable: `tready` is tied high.

> **So the question at the open is never "can the fast path keep up".** It is: **what in
> this system has a queue in front of it, and what is on the other side of that queue?**
> A queue only overflows when arrival exceeds *service*, and the fast path services at
> line rate. The exposures are all in front of **variable-rate consumers**.

| Structure | Queue? | Service rate | Burst exposure | Overflow policy |
| --- | --- | --- | --- | --- |
| `msg_realign` 128-byte window | Bounded window, not a queue | Line rate, II = 1 | **None** — `fill_q ≤ 128` is a design invariant, asserted ([04.02](../04-system-architecture/02-feed-handler-design.md) §4.3) | `window_overrun` must be 0 forever → kill switch |
| A/B arbitration | **No reorder buffer, deliberately** | Comparator, 0 cycles | **None.** An ahead-of-sequence packet is a gap, not a queue ([04.02](../04-system-architecture/02-feed-handler-design.md) §5.3) | Gap → `book_stale`, resync forward, never stall |
| Order map / level arrays | RMW hazard, not a queue | II = 1 with write-forwarding | **Capacity**, not rate — §2.4 | Eviction ⇒ counted miss, not silence |
| Order gateway TX / in-flight credit | Yes — credit-bounded | Venue ack RTT (**variable, and worst at the open**) | Credit exhaustion suppresses orders | Counted suppression, not a stall |
| **Telemetry DMA ring** | **Yes** | `ttd-logger` drain (**host-variable**) | **The real exposure** — §2.3 | **Drop and count** |
| **Audit DMA ring** | **Yes** | `ttd-risk` drain (**host-variable**) | Fills and rejects spike with the burst | ⚠️ **Ring full ⇒ arm the kill switch** ([04.06](../04-system-architecture/06-cpu-fpga-partitioning.md) §5) |
| Host consumption (`ttd-params`, `ttd-risk`) | Yes, in software | Scheduler-dependent | A 10 ms stall at the open is 10 ms of unsupervised trading | Watchdog |

### 2.3 Buffer sizing for the burst, and the trap

A buffer absorbs the integral of the rate mismatch over the burst:

```
   depth_required  ≥  ( arrival_rate − service_rate ) × burst_duration        [records]

   … and it is ONLY meaningful where service_rate < arrival_rate is possible.
   Where service_rate is line rate by construction, the term is ≤ 0 and no depth
   is required — that is what "no backpressure by construction" buys us.
```

Every input below is **measurement-derived**, from the §7 profiler run over the corpus.
The formula is the deliverable; the numbers are placeholders until measured.

| Buffer | `arrival_rate` (measured) | `service_rate` (measured) | `burst_duration` (measured) | Depth | Notes |
| --- | --- | --- | --- | --- | --- |
| `msg_realign` window | line rate | line rate | — | **128 B, fixed** | Invariant, not a sizing decision |
| A/B reorder window | — | — | — | **0** | Refused by design; do not add one "for the open" |
| Telemetry ring | `R_tel_peak` records/s at the open (order decisions incl. `NONE`, latency samples) | `S_log` = `ttd-logger` sustained drain, **measured under the same load, not idle** | `D_burst` = window over which `R_tel_peak > S_log` | `(R_tel_peak − S_log) × D_burst` × 1.5 | Sized in 64 B records; hugepage-backed |
| Audit ring | `R_aud_peak` = orders + rejects + acks + fills/s at the open | `S_risk` = `ttd-risk` drain under load | `D_burst` | `(R_aud_peak − S_risk) × D_burst` × **3** | ⚠️ Larger margin: overflow here **kills trading**, so it must not be a routine event |
| Order gateway in-flight credit | Order emission rate at the open | 1 / venue ack RTT | Duration of an RTT excursion | `ceil(peak_rate × RTT_p99.9)` | RTT at the open is not RTT at 11am |

> ⚠️ **THE TRAP, and it is the most common way this goes wrong: the fast path is fine and
> the *logging* path overflows.** The design succeeds — zero drops on RX, zero table
> overflow, orders emitted correctly — and the telemetry ring silently drops records for
> ninety seconds. You then have a perfect system and **no record of the single most
> interesting minute of the trading day**: the latency samples that would have shown the
> tail, the decision traces, the book snapshots. The post-mortem
> ([09](09-failure-modes-and-postmortems.md)) has a hole in it exactly where the incident
> is. Worse, the whole-day p99.9 you report is now *biased optimistic*, because the samples
> that went missing are precisely the slow ones.

> **RULE: log-ring overflow is counted, sticky-latched with a timestamp, and alerted at the
> first dropped record — not at a threshold.** Dropping log records is strictly preferable
> to backpressuring the fast path (CLAUDE.md hard rule 4 admits no exception), **but a
> dropped log record is never allowed to be invisible.** `tel_ring_drops`, its
> first-occurrence timestamp, and the high-water mark of ring occupancy are all readable,
> and a non-zero `tel_ring_drops` invalidates that day's latency statistics for reporting
> purposes. Say so in the report rather than quoting a number computed from a censored
> sample.

⚠️ The audit ring has the **opposite** policy and it is deliberate. Losing an audit record
means the host's position is wrong and cannot be reconstructed, so a full audit ring arms
the kill switch. Sizing it generously is not paranoia; it is the difference between a
capacity margin and an outage. Do not "harmonise" the two policies.

### 2.4 The live-order-count peak sizes the order map

`ORDER_MAP_ENTRIES` is set by the **intraday high-water mark of simultaneously live order
references within our filtered universe** — and that high-water mark occurs at or near the
open. [05](05-hash-tables-and-lookup-structures.md) §8 gives the measurement script and the
rule that the figure is recorded with its dates in `docs/`.

⚠️ The failure mode when this is sized off an average is exact and silent: the set-associative
table's occupancy crosses the collision knee, an insert evicts a live entry, and the
subsequent `D`/`E`/`X` for the evicted reference **misses**. A missed delete leaves phantom
liquidity at the touch — which is the single state in which a strategy loses money fastest
([04.02](../04-system-architecture/02-feed-handler-design.md) §8). It is counted, it is not
fatal, and it happens for ninety seconds a day at the exact moment the strategy is most
exposed.

> **RULE: the sizing input for every capacity-bounded structure is an open-of-day
> measurement over the §7 corpus, taken at the tightest window the profiler reports —
> never a session average, never a midday sample.**

### 2.5 The symbol filter matters more at the open

The filter at row R5 drops every message whose locate is not in our set, saving 7 of 20
fabric cycles of pipeline *occupancy* per filtered message
([04.02](../04-system-architecture/02-feed-handler-design.md) §7). With `N_ACTIVE = 256`
against a Nasdaq-listed plus regional universe of several thousand locates, the reduction
is large — but it is not constant across the day.

| Regime | Breadth of active symbols | Filter pass fraction | What the filter buys |
| --- | --- | --- | --- |
| Midday | Narrow — a few hundred names carry the rate, and our 256 are mostly among them | **Highest** (least reduction) | Least; our names *are* the active ones |
| **Open / close** | Near-total — the whole universe is live at once | **Lowest** (greatest reduction) | **Most.** The messages we discard are the ones we would otherwise queue behind |

⚠️ **Measure the pass fraction per time-of-day bucket, not as a daily number.** A daily
figure understates the filter's contribution at the open by exactly the amount that matters
and overstates the pipeline occupancy headroom you actually have midday. `msgs_filtered /
rx_msgs` is already counted; bucket it.

**Do this in the network too.** Nasdaq splits ITCH across multiple multicast groups by
symbol range; subscribing only to the groups covering our universe removes the traffic
before the MAC ever sees it, and it is the single largest reduction available at the open
because it is the only one that reduces *bytes on the wire*.
> **Verify:** the current channel/multicast-group partitioning of TotalView-ITCH and
> whether it is by symbol range or otherwise, against the **Nasdaq TotalView-ITCH 5.0
> specification** and the **Nasdaq market data connectivity/channel documentation**.

---

## 3. The close: the concentration

Different mechanism, different problem. The open is a **rate and breadth** event. The close
is a **size and information** event.

| Dimension | Open | Close |
| --- | --- | --- |
| Driver | Overnight interest entering; every symbol re-pricing at once | Benchmark, index, ETF/NAV and MOC/LOC flow converging on the **official closing price** |
| Peak quantity | Message rate, symbol breadth, live-order count | Notional per print; imbalance magnitude |
| Where price is discovered | Continuous book, immediately after the cross | ⚠️ **In the auction**, not continuously |
| Dominant hardware risk | Buffer/table/ring capacity | Limit widths, position accounting, adverse selection |
| Dominant strategy risk | Stale book, mis-sized queue estimate | **Worst adverse selection of the day** |

The last row is the important one. In the final minutes, a large, price-insensitive,
*directional* flow is known to exist and its direction is publicly disseminated in the
imbalance messages. Continuous-market participants position against it. A market-making
strategy quoting continuously through that window is offering a two-sided option to a
counterparty population that has strictly better information about the terminal price than
the continuous book contains — because the price that matters is being formed somewhere the
continuous book cannot see. This is the textbook case of `P(fill)` rising exactly when
`E[value | fill]` is most negative ([01](01-queue-position-and-fill-probability.md) §5,
[02](02-adverse-selection-and-toxicity.md)).

⚠️ **Also: the close is the biggest single-print notional exposure of the day.** Any
continuous-book position carried into the cross is marked against a price formed by an
auction. Position and notional limits sized on continuous-market prints will not have been
tested against it.

> **RULE: the closing window is a distinct strategy regime with its own parameter set,
> selected by the session state machine, not a continuation of the continuous regime with
> the same parameters.** Fade width, quote size, and maximum position are per-regime
> parameters delivered through the existing double-buffered parameter path, and the default
> posture for the closing window is *narrower, smaller, or absent* — chosen on measured
> P&L per time-of-day bucket, not on assumption.

---

## 4. The crosses, as they affect a hardware strategy

[08.02](../08-nasdaq/02-sessions-auctions-and-halts.md) §2 has how a cross works. This is
what the fabric must do about it. `sess_state` (`trade_state_e`) is the enforcement handle;
it reaches `u_strategy` **and** `u_risk_gate` independently, and that redundancy is the
design.

| Session phase (`trade_state_e`) | Strategy permitted to… | Enforced by (strategy side) | **Independently** enforced by the risk gate |
| --- | --- | --- | --- |
| `TRADE_CLOSED` | nothing | `sess_state != TRADE_OPEN` ⇒ no trigger | Global suppression; counted |
| `TRADE_PREOPEN` | maintain book state only; emit nothing | trigger gated | Suppression + per-symbol `tradable` = 0 |
| `TRADE_AUCTION` (cross in progress) | maintain state; **emit nothing** | trigger gated | Suppression; ⚠️ see §4.2 |
| `TRADE_OPEN` | quote and cancel, subject to §4.3 post-transition inhibit | normal path | LULD band, SSR, position, notional, kill, credit |
| `TRADE_HALTED` / `TRADE_PAUSED` | **cancel only** | per-symbol state | Per-symbol `tradable` = 0; **combinational**, §6.1 |
| `TRADE_STALE` (gap) | nothing in the affected symbols | `book_stale` bit | `book_stale` is a risk-gate input too |
| `TRADE_DISABLED` | nothing | reset value | Fail-closed |

⚠️ **The strategy gate and the risk gate must not share the derivation.** If `u_strategy`
and `u_risk_gate` both consume one precomputed `may_quote` bit, a bug in that derivation
removes both layers at once. They take `sess_state` and the per-symbol state record
separately and each computes its own predicate. That is why both ports exist in
`fpga_top.sv`.

### 4.1 Auction orders are a slow-path concern

> **RULE: on-open and on-close order types (MOO/LOO/MOC/LOC/IO) are never emitted by the
> fabric. They are entered by the host, through the same hardware risk gate, and the fabric
> OUCH encoder does not carry templates for them.**

The argument, on the merits:

| Consideration | Auction order | Continuous quote |
| --- | --- | --- |
| Latency sensitivity | **None.** The cut-off is a wall-clock deadline seconds or minutes away; being 300 ns earlier is worth exactly zero | Nanoseconds are the product |
| What being fast buys | Nothing — the auction is a single-price call, not a FIFO race | Queue position ([01](01-queue-position-and-fill-probability.md)) |
| Fabric cost to support | New OUCH templates, new encoder paths, new risk predicates, new state | Already built |
| Risk surface added | ⚠️ An order type that after the cut-off **cannot be cancelled** — an unhedgeable exposure to a price that does not exist yet, emitted autonomously by a state machine | Cancellable at any time |
| Verdict | **Host, supervised, deliberate** | **Fabric** |

Adding them to the fabric buys nothing measurable and costs resources plus the worst risk
surface in the system. This is the same reasoning as
[08.02](../08-nasdaq/02-sessions-auctions-and-halts.md) §2.2, stated as a hardware
partitioning decision ([04.06](../04-system-architecture/06-cpu-fpga-partitioning.md)).

### 4.2 ⚠️ The continuous book is not the auction book

During the cross period both exist simultaneously and they are **different books with
different contents**. An order-based reconstructor consuming TotalView sees the continuous
book's adds, cancels and deletes; cross-eligible interest that is not resting in the
continuous book is **not** in that stream as ordinary book events. The auction's state is
disseminated separately, as imbalance messages, on a different cadence, with different
semantics.

The specific hazard for our design: the top-of-book computed by `u_book` during the cross
window is a *correct* top of the *continuous* book and a **wrong** estimate of where the
symbol is about to trade. A strategy that treats `book_top` as fair value during that window
mis-prices systematically, in a direction that is publicly known and being traded against.
Symptoms, in order of how they present: fills clustered on one side, an execution printing
far from your quoted level (the cross print), and a queue-position estimator that resets on
a level that vanished.

> **RULE: during `TRADE_AUCTION`, `book_top` is maintained but is not a valid fair-value
> input.** The strategy does not quote, and any derived signal computed from the continuous
> book across the cross boundary is discarded rather than carried through.

⚠️ Related decoder hazard: the **cross print itself** is a trade message and must not be
applied to the book as if it consumed resting orders in the ordinary way, and it must not
be fed to volume- or trade-based signal features without being tagged as an auction print.
> **Verify:** which ITCH message carries the cross print, its cross-type field, whether it
> is a distinct message type from ordinary trade messages, and the treatment of
> non-displayable trades, against the **Nasdaq TotalView-ITCH 5.0 specification**.

### 4.3 The transition edges are the dangerous moments

The dangerous instants are not the phases; they are the **edges between them**: the instant
continuous trading opens, the instant it closes, and every halt resume (§6). At an edge, the
book you hold was built under the previous regime's rules, your resting-order beliefs may be
stale, and the first prints are the most volatile of the phase.

> **RULE: every `sess_state` and per-symbol state transition is edge-detected in fabric and
> forces a conservative posture for a host-configured number of cycles.** Conservative means:
> no new quotes, cancels still permitted (cancel always outranks quote —
> [03](03-cancel-latency-and-pickoff.md)), `book_stale` semantics if the transition implies a
> discontinuity, and a counter incremented per transition type. The window length is a
> **parameter, not a constant** — it is tuned per regime from measurement, and the same
> mechanism serves the open, the close, and every resume.

```systemverilog
// rtl/strategy/sess_edge.sv — 0 latency rows: the inhibit is a bit ANDed into an
// existing gate, evaluated on the SAME cycle the transition is applied.
trade_state_e sess_q;
logic [15:0]  inhibit_q;                 // host-configured, per transition class

always_ff @(posedge clk) begin
    sess_q <= sess_state;
    if (sess_state != sess_q) begin      // ANY edge, in either direction
        inhibit_q      <= cfg_inhibit_cycles[sess_state];
        edge_cnt_q[sess_state] <= edge_cnt_q[sess_state] + 1'b1;   // per-target counter
    end else if (inhibit_q != '0)
        inhibit_q <= inhibit_q - 1'b1;
end

assign quote_inhibit = (inhibit_q != '0);   // gates NEW orders only; cancels pass
```

⚠️ Both directions. An edge *into* `TRADE_OPEN` is obviously dangerous; an edge *out of* it
is dangerous too, because it means something just changed that you have not modelled.

---

## 5. The imbalance feed (NOII) and whether it belongs in fabric

### 5.1 What it is, at the level an engineer needs to decide

During the pre-cross dissemination window, the venue broadcasts a per-symbol message
describing the pending auction: how much quantity would pair at the current reference price,
how much would be left unpaired and on which side, and a set of indicative prices — a
current reference price, and cross-price estimates computed with and without continuous-book
interest. Field-level detail is [08.02](../08-nasdaq/02-sessions-auctions-and-halts.md) §2.3.

It is informative about exactly one thing, and it is a valuable thing: **the direction and
magnitude of auction pressure**, and therefore a partly predictable price move into the
cross. That is why the imbalance window is one of the most heavily modelled periods in US
equities.

> **Verify:** the message type and every field name and width; the dissemination **cadence**
> during the pre-cross window (it has been increased over time by rule filing); the start
> time of the window for each cross; and whether the cadence differs between the opening,
> closing and halt crosses — against the **Nasdaq TotalView-ITCH 5.0 specification** and
> **Nasdaq's opening/closing cross documentation and Equity Rulebook (Rules 4752/4753/4754)**.
> ⚠️ Do not assert any of these from memory; the cadence figure is load-bearing for §5.2 and
> a wrong one inverts the conclusion.

### 5.2 The decision: NOII is not on the fast path

The analysis, with the numbers that actually decide it:

| Question | Answer | Consequence |
| --- | --- | --- |
| How often does the value change? | On the dissemination cadence — **seconds**, or at best sub-second (verify) | A nanosecond decode saves ~10⁻⁹ of the update interval. It buys nothing |
| Is the information a *tick* or a *state*? | A **slowly-moving parameter** that conditions how you behave for the next many seconds | Belongs in the parameter path, not the event path |
| Where is the strategy value? | In reacting to the **continuous book** with knowledge of the imbalance — the fast event is the book event; the imbalance is the context | The fast path already handles the fast part |
| Fabric cost to decode it | Largest ITCH message in the catalogue; new fields, new per-symbol state, new predicates | Real area, real verification surface |
| Failure mode if wrong | A mis-decoded imbalance silently biases every quote in that symbol for minutes | High blast radius, low observability |

> **RULE: NOII is decoded on the host and delivered as a per-symbol parameter through the
> existing double-buffered, checksum-verified parameter path**
> ([04.04](../04-system-architecture/04-strategy-engine-on-fpga.md),
> [04.06](../04-system-architecture/06-cpu-fpga-partitioning.md)). **The fabric decoder
> forwards the message to the host and does not interpret it.** No new fast-path fields, no
> new trigger inputs, zero rows in the budget in `rtl/fpga_top.sv`.

**The counter-argument, stated fairly.** Some firms *do* race the imbalance print itself: at
the instant a new imbalance is disseminated, the continuous book reprices, and there is a
genuine sub-microsecond race to trade against stale continuous quotes on the new information
— a scheduled-event reaction, structurally identical to racing an economic release. It is a
real strategy and hardware is the right tool for it.

**This project declines it**, for reasons that are about scope, not about whether it works:

1. It is a **different strategy** — an event-driven taker on a scheduled dissemination — not
   the passive queue-position business the budget in `fpga_top.sv` was built to serve
   ([01](01-queue-position-and-fill-probability.md) §6).
2. It fires **twice a day per symbol** in a bounded window. The engineering and verification
   cost of a second decode-to-trigger path amortises over a tiny number of opportunities.
3. It requires the fabric to hold and interpret auction state, which is exactly the coupling
   §4.2 warns against, on the day's highest-consequence prints.
4. ⚠️ It competes directly with firms who have specialised the whole system for it. Entering
   that race as a side feature of a market-making design is how you lose money quickly.

Revisit it as a **separate strategy block with its own budget and its own P&L attribution**,
never as a feature bolted onto the quoting path.

---

## 6. Halt and resume handling

[08.02](../08-nasdaq/02-sessions-auctions-and-halts.md) §3 has the taxonomy and the reason
codes. This is the engineering.

### 6.1 The halt: the ordering guarantee

When a halt is decoded, quoting must stop **before the next order can be emitted**. That is
an ordering property, not a latency target, and it is met structurally: the per-symbol state
is written by `u_feed`, and `u_risk_gate` reads it **after** the strategy has decided, so any
halt decoded before an order reaches the gate is honoured on that order.

> **RULE: the halt gate is combinational on the state-table read in the risk gate, not a
> state-machine transition that takes cycles.** A multi-cycle FSM transition creates a
> window in which an order can pass a stale `tradable` bit. The residual exposure window —
> the cycles between the state write and the gate read — is **documented, bounded, and any
> order emitted inside it is counted** (`order_near_state_change`).

⚠️ An unrecognised trading-state or reason code maps to **halted**, never to tradable. Fail
safe on unknown, always.

### 6.2 ⚠️ The resume is more dangerous than the halt

The halt is easy: stop. The resume is where the money is lost.

| On resume, what is true | Why it hurts |
| --- | --- |
| The book is empty, or radically different from pre-halt | Every level index, every queue-position estimate, every derived signal is anchored to a book that no longer exists |
| Resumption is via a **reopening auction**, not a return to continuous trading | The first print is a cross print, at a price the continuous book did not contain (§4.2) |
| The timing is **not fixed** — collars can widen and the auction can be delayed ([08.02](../08-nasdaq/02-sessions-auctions-and-halts.md) §3.4) | A design that assumes "five minutes then trading" quotes into a market that is not there |
| The first minutes are the most volatile of the symbol's day | Worst adverse selection, thinnest book, widest spread |
| Your resting orders may or may not still exist | §6.3 |

> **RULE: a resume forces `book_stale` for that symbol until a bounded number of book events
> have been applied, and quoting is inhibited for a host-configured post-resume window
> (§4.3), counted per symbol.** Both conditions must clear before quoting resumes: the event
> count proves the book has been rebuilt, the timer proves the initial volatility burst has
> passed. Neither alone is sufficient — an event count alone clears instantly in a fast
> symbol, and a timer alone clears on an empty book.

### 6.3 ⚠️ Your own resting orders across a halt

What happens to orders resting at the venue when a symbol halts, and whether they survive to
the reopening, is **a venue policy question and possibly an order-type and time-in-force
question. It is not an assumption you are entitled to make.**

> **Verify:** the treatment of resting orders across a trading halt and into the reopening
> auction — whether they are cancelled, retained, or retained conditionally on order type —
> against the **Nasdaq Equity Rulebook** (the halt-cross and order-type rules) and the
> **Nasdaq OUCH 5.0 specification** for what the venue reports to you when it happens.

> **RULE: the system reconciles rather than assumes.** On any halt affecting a symbol in
> which we hold order state, the host marks that state **unknown** and reconciles against
> the venue's own messages and the drop copy before any new order is emitted in that symbol.
> Fabric-side `my_state` for the symbol is invalidated, and the queue-position estimator is
> cleared, not adjusted ([01](01-queue-position-and-fill-probability.md) §3.6). ⚠️ Assuming
> your order survived and quoting around it produces a **double position** if it did not,
> and a phantom hedge if it did.

### 6.4 The two message-rate realities of halts

| Case | Rate character | Design consequence |
| --- | --- | --- |
| **Halts for symbols we do not track** | A trickle of state messages, all filtered | ⚠️ They must still be *decoded* — the state table is indexed by locate and a halt is not book-affecting, so it bypasses the R5 filter's book-event path. Confirm the state side-channel is not accidentally filtered out with the book events |
| **LULD band updates for symbols we do track** | ⚠️ **Continuous, all day, every tracked symbol.** Bands are recalculated as the reference price moves | These are not rare events. They are a sustained write load on the per-symbol state table, and they peak with volatility — i.e. at the open and close, concurrently with everything else in §2 |
| **Single-symbol news halt and resume** | Extreme rate in **one** symbol while the aggregate is unremarkable | ⚠️ A per-symbol structure can be overrun while every aggregate counter looks healthy. Per-symbol high-water marks, not just aggregates |
| **MWCB** | Global, immediate | Reuses the kill-switch path so it is exercised by the kill-switch tests ([08.02](../08-nasdaq/02-sessions-auctions-and-halts.md) §5) |

---

## 7. ⚠️ The operational rule: a system that works at 11am may fail at 9:30am

**11am is the easiest moment of the trading day**, and it is the moment at which almost all
ad-hoc testing happens. At 11am the message rate is at its daily trough, symbol breadth is
narrow, the live-order count is well below its peak, no session transitions occur, no
imbalance messages are disseminated, the die has reached thermal steady state at a modest
load, and every host process has had an hour to settle. A system that has only been observed
at 11am has been observed in the one regime that exercises the fewest code paths.

Exactly what only breaks at the open or the close:

| Failure | Why it cannot appear midday | Where it surfaces |
| --- | --- | --- |
| **Buffer / ring overflow** | Arrival never exceeds service at the median rate | Telemetry ring, audit ring, host queues |
| **Table capacity overflow** | Live-order count is far below the high-water mark | Order map eviction ⇒ missed deletes ⇒ phantom liquidity |
| **Counter saturation / rollover** | The counter simply does not reach the width midday | Rate counters, per-symbol event counts, histogram bucket counts |
| **Log-ring drops** | `S_log > R_tel` all day midday | §2.3 — and it censors the very data you need |
| **Host consumption falling behind** | Slack is enormous midday | `ttd-risk` drain, reconciliation loop, watchdog margin |
| **Timing margin under thermal load** | Sustained high toggle rate raises `Tj`; hold and setup margin move with it | Only under sustained burst — [06](06-timing-report-forensics.md), [07](07-jitter-sources-and-determinism.md) |
| ⚠️ **Code paths only exercised by session transitions and imbalance messages** | **They literally never execute midday** | The subtle one: the `TRADE_AUCTION` arm, the edge-detect inhibit, the resume path, the NOII forwarding path, the cross-print tagging. Zero coverage from a midday replay, at any duration |

That last row is why duration does not substitute for content. **Eight hours of midday
replay gives exactly zero coverage of the transition logic.** Soak time is not the same as
soak breadth.

> **RULE: soak and load tests MUST use real open-of-day and close-of-day capture. A
> synthetic stream or a mid-day replay is not evidence, at any duration, for any capacity,
> latency, or correctness claim about this system.** Any latency figure quoted without a
> stated load profile that includes a real open is not a result
> ([05.04](../05-optimization/04-measurement-and-profiling.md) §8, §9).

### 7.1 The test corpus specification

Complements [06.04](../06-operations/04-testing-strategy.md) §4 with the *selection
criteria* — which dates, and why each earns its storage.

| Corpus entry | Selection criterion | What it and only it exercises |
| --- | --- | --- |
| `open_normal` | An unremarkable session's pre-open through the first minutes of continuous trading | The baseline burst shape; the open transition edge; sizing inputs |
| `open_high_volume` | The highest-message-rate open available in the archive | **The sizing case.** Buffer depths, table high-water mark, counter widths |
| `close_index_event` | A triple-witching or index-rebalance close | Extreme imbalance magnitude, extreme cross notional, position and notional limits |
| `close_normal` | An ordinary close | The close transition edge and the imbalance window at normal scale |
| `day_with_halt` | A session containing a news halt and its reopening cross in a tracked symbol | §6 in its entirety — the only path that exercises resume, and it cannot be synthesised faithfully |
| `day_with_luld` | A session with heavy band activity and at least one limit state | Sustained state-table write load; band gate; straddle handling |
| `half_day` | An early-close session | ⚠️ Proves the schedule is host-loaded and not a constant. A hardcoded close quotes into a closed market ([08.02](../08-nasdaq/02-sessions-auctions-and-halts.md) §7) |
| `ipo_day` | A session with an IPO in the universe | Stock Directory mid-session, IPO quoting-period messages, a symbol appearing from nothing |

> **Verify:** that Nasdaq publishes historical TotalView-ITCH sample files (full raw days,
> by date) suitable for this, the current access terms, and that the samples are the same
> product version you decode — from the **Nasdaq Trader / Nasdaq Data Link market data
> sample archives**. Record the exact file identifiers and dates in `docs/` alongside every
> sizing figure derived from them.

⚠️ Not every entry will be findable for every criterion. Where a real capture does not exist,
**say so and keep the synthetic substitute clearly labelled** — never let a synthesised halt
stand in the corpus as if it were a capture.

### 7.2 The profiler: turning a captured day into sizing inputs

```python
#!/usr/bin/env python3
# host/analysis/profile_day.py — slow path, offline.
# Emits every measurement-derived input that §2 and §7.3 require, from one raw ITCH day.
import collections, itertools, json, sys
import numpy as np

TRACKED = set(json.load(open(sys.argv[2])))          # our locates. ALWAYS apply the filter.
WINDOWS_NS = [1_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000]
BUCKET_NS  = 60 * 1_000_000_000                      # 1-minute time-of-day buckets

live, ref_sym = collections.Counter(), {}            # locate -> live refs ; ref -> locate
hwm_total, hwm_sym = 0, collections.Counter()
stamps_all, stamps_kept = [], []                     # ns timestamps, for rate windows
mix       = collections.defaultdict(collections.Counter)   # bucket -> type -> count
breadth   = collections.defaultdict(set)                   # bucket -> {locate}
live_ts   = []                                             # (ns, live_total)

for m in itch_messages(sys.argv[1]):                 # streaming decoder, spec-derived
    b = m.ts_ns // BUCKET_NS
    mix[b][m.type] += 1
    breadth[b].add(m.locate)
    stamps_all.append(m.ts_ns)
    if m.locate not in TRACKED:                      # everything below is post-filter
        continue
    stamps_kept.append(m.ts_ns)
    if m.type in b"AF":
        ref_sym[m.ref] = m.locate; live[m.locate] += 1
    elif m.type == b"U":                             # retire old ref, create new one
        if m.ref in ref_sym: live[ref_sym.pop(m.ref)] -= 1
        ref_sym[m.new_ref] = m.locate; live[m.locate] += 1
    elif m.type == b"D":
        if m.ref in ref_sym: live[ref_sym.pop(m.ref)] -= 1
    elif m.type in b"ECX" and m.remaining == 0:      # E/C/X can retire an order too
        if m.ref in ref_sym: live[ref_sym.pop(m.ref)] -= 1
    tot = sum(live.values())
    if tot > hwm_total: hwm_total = tot
    hwm_sym[m.locate] = max(hwm_sym[m.locate], live[m.locate])
    live_ts.append((m.ts_ns, tot))                   # KEEP THE SERIES, not just the max

def peak_rate(ts, w):
    """Max messages in any sliding window of w ns. ts must be sorted."""
    a = np.asarray(ts, dtype=np.int64)
    return int((np.searchsorted(a, a + w, "left") - np.arange(a.size)).max())

report = {
  "peak_msgs_per_window": {                          # ⚠️ the SHORT windows size the buffers
      f"{w}ns": {"all": peak_rate(stamps_all, w), "tracked": peak_rate(stamps_kept, w)}
      for w in WINDOWS_NS},
  "live_order_hwm_total": hwm_total,                 # -> ORDER_MAP_ENTRIES (09.05 §8)
  "live_order_hwm_worst_symbols": hwm_sym.most_common(10),
  "hwm_time_of_day_ns": max(live_ts, key=lambda x: x[1])[0],   # expect open or close
  "breadth_by_minute": {b: len(s) for b, s in sorted(breadth.items())},
  "filter_pass_frac_by_minute": {                    # §2.5: bucket it, never a daily number
      b: sum(c for t, c in mix[b].items()) and len(breadth[b] & TRACKED) / len(breadth[b])
      for b in sorted(mix)},
  "type_mix_by_minute": {b: dict(c) for b, c in sorted(mix.items())},
}
json.dump(report, open(sys.argv[3], "w"), indent=1)
```

⚠️ **Report the peak over several window lengths.** A per-second peak is smooth enough to be
reassuring and useless for sizing a ring that overflows in a millisecond. The 1 µs and 100 µs
figures are the ones that decide buffer depths; the 1 s figure is the one for a capacity
conversation with the venue.

### 7.3 Acceptance criteria — evaluated on the burst window specifically

| # | Criterion | Measured over |
| --- | --- | --- |
| 1 | **Zero drops on the fast path.** `drop_*` and `window_overrun` all zero; `filtered` and `dup_*` non-zero (their absence means a feed is down) | Whole replay |
| 2 | **No table overflow.** Order-map eviction count zero; every capacity high-water mark below its configured limit with stated margin | Whole replay |
| 3 | **All counters non-saturating.** No counter reaches its width; no sticky first-error latch set | Whole replay |
| 4 | **Ring drops zero.** `tel_ring_drops == 0` **and** `audit_ring_drops == 0`; ring occupancy high-water mark recorded | **Burst window** |
| 5 | **p99.9 latency within budget** | ⚠️ **The burst window specifically — not the whole day** |
| 6 | **Every transition path executed at least once**, evidenced by its edge counter | Whole replay |
| 7 | Book matches the golden model after every message; strategy intents match the golden strategy | Whole replay |

⚠️ **Criterion 5 is the one that is routinely faked by accident.** A whole-day p99.9 is
dominated by the midday trough, where the system is idle and every sample is near the floor;
the burst contributes a small fraction of the samples and vanishes into the tail. **A
whole-day p99.9 can look excellent while the open p99 is over budget.** Compute the
percentiles over the burst window as a separate population and report both.
[07](07-jitter-sources-and-determinism.md) is why the burst distribution differs at all —
queueing behind preceding messages in a packet, contention, and thermal effects are all
load-dependent, and none of them exist in the idle profile
([05.04](../05-optimization/04-measurement-and-profiling.md) §7, §8).

---

## 8. Pre-open operational sequence

The fabric-facing runbook. It refines
[04.06](../04-system-architecture/06-cpu-fpga-partitioning.md) §7 with what is specific to
*this* session's open, and it complements
[08.01](../08-nasdaq/01-market-structure.md) §9's list of what must be loaded.

| # | Step | Source of truth | Verification before proceeding |
| --- | --- | --- | --- |
| 1 | **Build ID arm check** — `BUILD_ID` / `GIT_SHA` match the approved release | `docs/` release record ([06.01](../06-operations/01-build-and-release.md)) | Exact match, else **abort**. Never "probably the right bitstream" |
| 2 | **Fail-closed check after reset** | Fabric | `kill` armed, `cfg_trading_en == 0`, all limits zero, all counters zero |
| 3 | **Session schedule table** — today's phase boundaries, from the calendar file | Venue calendar, host-loaded | ⚠️ **Half-day / holiday check is part of this step**, not an afterthought |
| 4 | **Symbol filter + locate map**, from today's Stock Directory | ITCH `R` replay / start-of-day file | Read back **every** entry. Locates change daily |
| 5 | **Per-symbol venue state**: LULD tier, round lot, SSR carried from yesterday | Host config + ITCH | ⚠️ SSR persists across days and the fabric does not remember yesterday. Unknown ⇒ **restricted** |
| 6 | **Risk parameters** — per-symbol limits, notional, position, credit | Host risk config | Read back every field. Posted writes are unreliable |
| 7 | **Strategy parameters**, including today's regime sets (§3) and NOII parameter slots (§5) | `ttd-params` | Shadow bank + checksum + commit + read-back of active |
| 8 | **OUCH templates** per symbol/side | Host | Checksum read-back |
| 9 | **DMA rings** sized per §2.3 for today's expected peak; hugepages resident | Host | Inject a synthetic record; read it back |
| 10 | **Feed enable**, require unbroken sequence continuity for a stated interval | Fabric counters | `gap_*` zero over the interval; `dup_*` non-zero |
| 11 | **Book build and per-symbol verification** against the software shadow book | Fabric + host | Clear `book_stale` **per symbol**, never globally |
| 12 | **OUCH session up**, TX ownership handed to fabric, watchdog kicking | Host | `sess_up`, watchdog decrementing |
| 13 | **Arm trading** — `cfg_trading_en`, then kill-clear | Operator | — |

> **RULE: arming trading is the last step, and it is gated on read-back verification of
> every preceding step.** Not "the writes returned" — a read-back of the value that was
> written, compared. There is never a window in which the system can emit an order but has
> not been fully verified. If any step fails, **you stop at that step**: the cost of not
> trading for an hour is bounded and known; the cost of trading on an unverified risk limit
> is not ([06.02](../06-operations/02-deployment-and-colocation.md),
> [06.01](../06-operations/01-build-and-release.md)).

⚠️ Two open-specific additions to the generic sequence: **(a)** step 3's calendar check is
the only defence against a half day, and it must fail loudly if today's date is absent from
the calendar file rather than defaulting to a regular session; **(b)** step 9 sizes the rings
for *today's expected peak*, which on a known-heavy day (index rebalance, macro event,
options expiry) is not the same as the standing configuration.

---

## 9. Rules for this project

1. **Everything is sized to the peak, never the median.** Buffers, tables, counter widths, ring depths, host drain rates. An average is wrong at both ends of the day.
2. **The fast path never queues; only variable-rate consumers do.** Enumerate them (§2.2) and size each with `(arrival − service) × burst_duration` from measured inputs.
3. **Log-ring overflow is counted, sticky, timestamped, and alerted on the first record.** Dropping log records beats backpressuring the fast path — but a censored sample invalidates that day's latency statistics, and the report must say so.
4. **The audit ring keeps the opposite policy: full ⇒ kill.** Do not harmonise them.
5. **`ORDER_MAP_ENTRIES` and every capacity bound come from an open-of-day high-water mark** over the §7.1 corpus, recorded with dates in `docs/`.
6. **Auction order types are never emitted by the fabric.** Host-originated, supervised, through the same hardware risk gate. No fabric templates exist for them.
7. **The continuous book is not the auction book.** During `TRADE_AUCTION`, `book_top` is maintained but is not a valid fair-value input, and cross prints are tagged, never treated as ordinary trades.
8. **Every state transition is edge-detected and forces a conservative posture** for a host-configured number of cycles, in **both** directions, counted per transition type.
9. **The halt gate is combinational on the state-table read in the risk gate**, downstream of the strategy. Unknown state or reason code ⇒ halted.
10. **The resume forces `book_stale` until N events applied AND a post-resume timer expires.** Both, not either.
11. **Order state across a halt is reconciled, never assumed.** Fabric `my_state` invalidated, queue estimator cleared, host reconciles against the venue and the drop copy first.
12. **NOII is host-decoded and delivered as a per-symbol parameter.** Zero fast-path rows. Racing the imbalance print is a different strategy with its own budget, or it is not done.
13. **The closing window is its own strategy regime** with its own parameters, selected by the session state machine.
14. **Soak and load tests use real open- and close-of-day capture.** Midday or synthetic replay is not evidence, at any duration.
15. **Burst-window percentiles are reported separately from whole-day percentiles.** A whole-day p99.9 hides the open by construction.
16. **Arming trading is the last step and is gated on read-back verification of everything before it.** Stop at the first failed step.

---

## Further reading

- [../08-nasdaq/02-sessions-auctions-and-halts.md](../08-nasdaq/02-sessions-auctions-and-halts.md) — **read first**: the schedule, the crosses, the halt taxonomy, LULD, MWCB, SSR
- [../08-nasdaq/01-market-structure.md](../08-nasdaq/01-market-structure.md) — §9, the configuration that must be loaded before the open
- [../08-nasdaq/04-totalview-itch-5.0.md](../08-nasdaq/04-totalview-itch-5.0.md) — the `S`/`H`/`h`/`Y`/`J`/`K`/`I`/`Q` messages this document reacts to
- [../04-system-architecture/02-feed-handler-design.md](../04-system-architecture/02-feed-handler-design.md) — §1 no backpressure, §2 the throughput proof, §7 the filter, §8 the stale-book policy
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — where the halt, LULD and session gates are enforced
- [../04-system-architecture/06-cpu-fpga-partitioning.md](../04-system-architecture/06-cpu-fpga-partitioning.md) — §5 the two DMA rings, §7 the startup sequence
- [../04-system-architecture/04-strategy-engine-on-fpga.md](../04-system-architecture/04-strategy-engine-on-fpga.md) — the double-buffered parameter path NOII rides on
- [../03-algotrading/03-market-data-protocols.md](../03-algotrading/03-market-data-protocols.md) — §7 message rates, bursts, and how to size
- [../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md) — §8 load profiles, §9 the reporting standard
- [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md) — §4 the replay corpus, §8 soak
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) — counter and ring-drop semantics
- [05-hash-tables-and-lookup-structures.md](05-hash-tables-and-lookup-structures.md) — §8, sizing the order map from the open-of-day high-water mark
- [07-jitter-sources-and-determinism.md](07-jitter-sources-and-determinism.md) — why the burst distribution differs, and why a whole-day p99.9 hides it
- [02-adverse-selection-and-toxicity.md](02-adverse-selection-and-toxicity.md) — the closing window's real cost to a passive quoter
- [01-queue-position-and-fill-probability.md](01-queue-position-and-fill-probability.md) — why calibration must be time-of-day bucketed
- [09-failure-modes-and-postmortems.md](09-failure-modes-and-postmortems.md) — what a censored telemetry ring does to an investigation
