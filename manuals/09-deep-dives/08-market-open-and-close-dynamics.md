# 09.08 — Market Open and Close Dynamics

> **Why this matters here:** the sub-microsecond tick-to-trade path in `rtl/fpga_top.sv` is
> sized for line rate by construction, so it does not care what time it is. **Everything
> around it does.** Buffers, tables, counters, the DMA rings, the host and the die
> temperature all live on a load curve with two enormous peaks — and every one of them is
> validated by default at the quietest moment of the day. This is the engineering profile of
> those two moments: what changes, which structures have a queue in front of them, what the
> arithmetic says they must be sized to, and why a soak test without a real open is not
> evidence of anything.
> [08.02](../08-nasdaq/02-sessions-auctions-and-halts.md) is the venue reference — schedule,
> cross mechanics, halt taxonomy, LULD, MWCB, SSR. **Read it first.** This is what the FPGA
> has to *do* about it.

---

## 1. The trading day as a load curve

Not a schedule — a set of curves, and they do not peak together.

```
   rate │      ██                                                  ███
        │     ████                                              ███████
        │    ██████  ███                                     ████████████
        │  ██████████████████▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄████████████
        └──┴────────────────────────────────────────────────────────┴────
        pre  OPEN            "11am": the easiest hour             CLOSE  post
             ▲ breadth, live-order count, message rate,           ▲ size, notional,
               quote lifetime at its MINIMUM                        imbalance-driven
```

| Curve | Shape across the session | Peaks at | What it stresses |
| --- | --- | --- | --- |
| **Message rate** (msgs/s) | U-shaped, sharply asymmetric: near-vertical rise into the open, long midday trough, rise into the close | **Open** (usually), close second | Every queue; the DMA rings; host drain |
| **Live-order count** (live refs in our universe) | Rises through pre-open, spikes at the open, decays, partly rebuilds | **Open** | `ORDER_MAP_ENTRIES` — [05](05-hash-tables-and-lookup-structures.md) §8 |
| **Symbol breadth** (distinct locates active) | Near-total at the open; long idle tail midday | **Open** | Filter pass rate, per-symbol state write load |
| **Volatility / toxicity** | High at both ends, quiet midday | **Both**, close worst for a quoter | Strategy P&L — [02](02-adverse-selection-and-toxicity.md) |
| **Quote lifetime** (level survival) | Minimum at the open — everything is fleeting | **Open** (inverted) | Cancel path, queue-position estimator validity |
| **Notional per print** | Modest all day, then one enormous print | **Close (the cross)** | Position/notional limits, fill accounting |

Two facts the rest of this document rests on:

1. **Peak-to-median aggregate message rate is a large multiple, not a percentage.** The burst
   is a different regime, not a busy period. **Every buffer, table, counter width, ring depth
   and host consumption rate is sized to the peak — never the median, never a whole-day
   average.** An average is the one statistic guaranteed to be wrong at both ends of the day.
2. **The curves peak at different moments for different reasons.** Sizing the order map off
   the close, or the notional limits off the open, sizes the wrong thing.

> **Verify:** peak and average TotalView message rates, the *window lengths* over which
> Nasdaq publishes them (per-second, per-millisecond and per-microsecond peaks are different
> numbers), and their year-over-year growth, against **Nasdaq's published market data
> capacity / message-rate statistics** (nasdaqtrader.com). Never carry a remembered figure
> into a sizing spreadsheet; the statistic you need is the *shortest* window published.

---

## 2. The open: the burst

### 2.1 Mechanism: a breadth event as much as a rate event

From the start of order acceptance through the minutes after the continuous session opens, a
large fraction of the day's resting interest is entered, modified and cancelled in a
compressed window: overnight interest lands, pre-open pricing is adjusted repeatedly as the
imbalance publishes, cross-eligible interest is entered and pulled, and the cross re-anchors
every book with a single print — after which everyone re-quotes into a book that just moved
underneath them.

⚠️ **The distinguishing feature is breadth, not depth.** Midday a handful of names carry the
rate and the rest of the universe is idle; at the open *every* symbol is active at once.
Structures whose cost is per-active-symbol — the filter, the per-symbol state RMW, order-map
occupancy across sets, per-symbol counters — see their worst case at the open even when the
aggregate rate is not at its absolute maximum.

### 2.2 Instantaneous vs sustained rate: what actually has a queue

The RX path sustains line rate unconditionally by construction, and the proof is
[04.02](../04-system-architecture/02-feed-handler-design.md) §2: the shortest book-affecting
message plus MoldUDP64 framing cannot arrive faster than one per ~3 cycles, the pipeline runs
at II = 1, giving ≥ 2× headroom **at line rate** — a bound no market event can exceed.
CLAUDE.md hard rule 4 makes it non-negotiable: `tready` is tied high.

> **So the question at the open is never "can the fast path keep up".** It is **what has a
> queue in front of it, and what is on the other side of that queue.** A queue only overflows
> when arrival exceeds *service*; the fast path services at line rate. Every exposure is in
> front of a **variable-rate consumer**.

| Structure | Queue? | Service rate | Burst exposure | Overflow policy |
| --- | --- | --- | --- | --- |
| `msg_realign` 128 B window | Bounded window, not a queue | Line rate, II = 1 | **None** — `fill_q ≤ 128` is an asserted invariant | `window_overrun` must be 0 forever → kill |
| A/B arbitration | **No reorder buffer, deliberately** | Comparator, 0 cycles | **None.** Ahead-of-sequence is a gap, not a queue | Gap → `book_stale`, resync forward, never stall |
| Order map / level arrays | RMW hazard, not a queue | II = 1 with write-forwarding | **Capacity**, not rate — §2.4 | Eviction ⇒ *counted* miss, never silence |
| Order gateway in-flight credit | Yes | Venue ack RTT (**variable, worst at the open**) | Credit exhaustion suppresses orders | Counted suppression, not a stall |
| **Telemetry DMA ring** | **Yes** | `ttd-logger` drain (**host-variable**) | **The real exposure** — §2.3 | **Drop and count** |
| **Audit DMA ring** | **Yes** | `ttd-risk` drain (**host-variable**) | Fills/rejects spike with the burst | ⚠️ **Full ⇒ arm the kill switch** ([04.06](../04-system-architecture/06-cpu-fpga-partitioning.md) §5) |
| Host consumption | Yes, in software | Scheduler-dependent | A 10 ms stall at the open is 10 ms unsupervised | Watchdog |

### 2.3 Buffer sizing for the burst, and the trap

```
   depth_required  ≥  ( arrival_rate − service_rate ) × burst_duration      [records]

   … and it is ONLY meaningful where service_rate < arrival_rate is possible. Where
   service is line rate by construction the term is ≤ 0 and NO depth is required —
   that is precisely what "no backpressure by construction" buys us.
```

Every input is **measurement-derived**, from the §7.2 profiler over the §7.1 corpus. The
formula is the deliverable; the symbols are placeholders until measured.

| Buffer | `arrival_rate` | `service_rate` | `burst_duration` | Depth | Note |
| --- | --- | --- | --- | --- | --- |
| `msg_realign` window | line rate | line rate | — | **128 B fixed** | Invariant, not a sizing decision |
| A/B reorder window | — | — | — | **0** | Refused by design; do not add one "for the open" |
| Telemetry ring | `R_tel` peak (decisions incl. `NONE`, latency samples) | `S_log`, measured **under the same load, not idle** | `D` = window where `R_tel > S_log` | `(R_tel − S_log)·D × 1.5` | 64 B records, hugepage-backed |
| Audit ring | `R_aud` peak (orders + rejects + acks + fills) | `S_risk` under load | `D` | `(R_aud − S_risk)·D × **3**` | ⚠️ Bigger margin: overflow **kills trading** |
| Gateway credit | order rate at the open | 1 / ack RTT | RTT excursion | `ceil(rate × RTT_p99.9)` | ⚠️ Open RTT ≠ 11am RTT |

> ⚠️ **THE TRAP: the fast path is fine and the *logging* path overflows.** Zero RX drops, no
> table overflow, orders correct — and the telemetry ring silently drops for ninety seconds.
> You now have a perfect system and **no record of the most interesting minute of the day**:
> the latency samples that would have shown the tail, the decision traces, the book
> snapshots. The post-mortem ([09](09-failure-modes-and-postmortems.md)) has a hole exactly
> where the incident is. Worse, the whole-day p99.9 you then report is **biased optimistic**,
> because the samples that went missing are precisely the slow ones.

> **RULE: log-ring overflow is counted, sticky-latched with a timestamp, and alerted on the
> FIRST dropped record — not at a threshold.** Dropping log records is strictly preferable to
> backpressuring the fast path (hard rule 4 admits no exception), **but it is never allowed
> to be invisible.** `tel_ring_drops`, its first-occurrence timestamp and the ring-occupancy
> high-water mark are all readable, and a non-zero `tel_ring_drops` **invalidates that day's
> latency statistics for reporting**. Say so, rather than quoting a censored percentile.

⚠️ The audit ring has the **opposite** policy, deliberately: losing an audit record means the
host's position is wrong and unreconstructable, so a full audit ring arms the kill switch. Do
not "harmonise" the two policies.

### 2.4 The live-order-count peak sizes the order map

`ORDER_MAP_ENTRIES` is set by the **intraday high-water mark of simultaneously live order
references within our filtered universe**, and that mark occurs at or near the open.
[05](05-hash-tables-and-lookup-structures.md) §8 gives the measurement script and the rule
that the figure is recorded with its dates in `docs/`.

⚠️ Sized off an average, the failure is exact and silent: occupancy crosses the collision
knee, an insert evicts a live entry, and the later `D`/`E`/`X` for that reference **misses**.
A missed delete leaves phantom liquidity at the touch — the state in which a strategy loses
money fastest ([04.02](../04-system-architecture/02-feed-handler-design.md) §8). Counted, not
fatal, and it happens for ninety seconds a day at the moment of maximum exposure.

> **RULE: the sizing input for every capacity-bounded structure is an open-of-day measurement
> at the tightest window the profiler reports — never a session average, never a midday
> sample.**

### 2.5 The symbol filter matters more at the open

The R5 filter drops every unsubscribed locate, saving 7 of 20 fabric cycles of pipeline
*occupancy* per filtered message ([04.02](../04-system-architecture/02-feed-handler-design.md)
§7). With `N_ACTIVE = 256` against several thousand locates the reduction is large — but it
is not constant across the day.

| Regime | Breadth | Filter pass fraction | What the filter buys |
| --- | --- | --- | --- |
| Midday | Narrow; the active names are largely ours | **Highest** (least reduction) | Least — our names *are* the active ones |
| **Open / close** | Near-total; the whole universe is live | **Lowest** (greatest reduction) | **Most.** What it discards is what we would otherwise queue behind |

⚠️ **Bucket `msgs_filtered / rx_msgs` by time of day.** A daily figure understates the
filter's contribution at the open by exactly the amount that matters, and overstates the
occupancy headroom you actually have midday.

Do this in the network too: Nasdaq splits ITCH across multiple multicast groups, so
subscribing only to the groups covering our universe removes traffic before the MAC sees it —
the largest reduction available at the open, because it is the only one that reduces *bytes
on the wire*.
> **Verify:** the current channel / multicast-group partitioning of TotalView-ITCH and
> whether it is by symbol range, against the **Nasdaq TotalView-ITCH 5.0 specification** and
> Nasdaq's market data connectivity documentation.

---

## 3. The close: the concentration

Different mechanism, different problem. The open is a **rate and breadth** event; the close is
a **size and information** event.

| Dimension | Open | Close |
| --- | --- | --- |
| Driver | Overnight interest entering; every symbol re-pricing at once | Benchmark, index, ETF/NAV and MOC/LOC flow converging on the **official closing price** |
| Peak quantity | Message rate, breadth, live-order count | Notional per print; imbalance magnitude |
| Where price is discovered | Continuous book, right after the cross | ⚠️ **In the auction**, not continuously |
| Dominant hardware risk | Buffer / table / ring capacity | Limit widths, position accounting |
| Dominant strategy risk | Stale book, mis-sized queue estimate | **Worst adverse selection of the day** |

The last row is the one that matters. In the final minutes a large, price-insensitive,
*directional* flow is known to exist and its direction is publicly disseminated. A strategy
quoting continuously through that window is writing a two-sided option to a counterparty
population with strictly better information about the terminal price than the continuous book
contains — because the price that matters is forming somewhere the continuous book cannot
see. `P(fill)` rises exactly where `E[value | fill]` is most negative
([01](01-queue-position-and-fill-probability.md) §5,
[02](02-adverse-selection-and-toxicity.md)).

⚠️ The close is also the largest single-print notional of the day. Any continuous-book
position carried into the cross is marked against a price formed by an auction — a case
limits sized on continuous prints have never been tested against.

> **RULE: the closing window is a distinct strategy regime with its own parameter set,
> selected by the session state machine — not the continuous regime running on.** Fade width,
> quote size and maximum position are per-regime parameters delivered through the existing
> double-buffered path, and the default posture is *narrower, smaller, or absent*, chosen on
> measured P&L per time-of-day bucket rather than on assumption.

---

## 4. The crosses, as they affect a hardware strategy

[08.02](../08-nasdaq/02-sessions-auctions-and-halts.md) §2 has how a cross works; this is what
the fabric must do. `sess_state` (`trade_state_e`) reaches `u_strategy` **and** `u_risk_gate`
independently, and that redundancy is the design.

| Phase (`trade_state_e`) | Strategy permitted to… | Strategy-side gate | **Independent** risk-gate enforcement |
| --- | --- | --- | --- |
| `TRADE_CLOSED` | nothing | `sess_state != TRADE_OPEN` ⇒ no trigger | Global suppression, counted |
| `TRADE_PREOPEN` | maintain book state; emit nothing | trigger gated | Suppression + per-symbol `tradable` = 0 |
| `TRADE_AUCTION` | maintain state; **emit nothing** | trigger gated | Suppression; ⚠️ §4.2 |
| `TRADE_OPEN` | quote and cancel, subject to §4.3 inhibit | normal path | LULD band, SSR, position, notional, kill, credit |
| `TRADE_HALTED` / `TRADE_PAUSED` | **cancel only** | per-symbol state | `tradable` = 0, **combinational** (§6.1) |
| `TRADE_STALE` | nothing in affected symbols | `book_stale` | `book_stale` is a risk-gate input too |
| `TRADE_DISABLED` | nothing | reset value | Fail-closed |

⚠️ **The two gates must not share a derivation.** If both consume one precomputed `may_quote`
bit, a bug in that derivation removes both layers at once. Each takes `sess_state` and the
per-symbol state record separately and computes its own predicate — which is why both ports
exist in `fpga_top.sv`.

### 4.1 Auction orders are a slow-path concern

> **RULE: on-open and on-close order types (MOO/LOO/MOC/LOC/IO) are never emitted by the
> fabric. They are host-entered, through the same hardware risk gate, and the fabric OUCH
> encoder carries no templates for them.**

| Consideration | Auction order | Continuous quote |
| --- | --- | --- |
| Latency sensitivity | **None.** The cut-off is a wall-clock deadline seconds or minutes away | Nanoseconds are the product |
| What speed buys | Nothing — a single-price call auction is not a FIFO race | Queue position ([01](01-queue-position-and-fill-probability.md)) |
| Fabric cost | New templates, encoder paths, risk predicates, state | Already built |
| Risk surface | ⚠️ An order that after the cut-off **cannot be cancelled** — unhedgeable exposure to a price that does not exist yet, emitted autonomously by a state machine | Cancellable at any time |
| Verdict | **Host, supervised, deliberate** | **Fabric** |

Adding them to the fabric buys nothing measurable and costs resources plus the worst risk
surface in the system — [08.02](../08-nasdaq/02-sessions-auctions-and-halts.md) §2.2 restated
as a partitioning decision ([04.06](../04-system-architecture/06-cpu-fpga-partitioning.md)).

### 4.2 ⚠️ The continuous book is not the auction book

During the cross period both exist and they hold **different contents**. An order-based
reconstructor consuming TotalView sees the continuous book's adds, cancels and deletes;
cross-eligible interest not resting in the continuous book is **not** in that stream as
ordinary book events. The auction's state is disseminated separately, on a different cadence,
with different semantics.

The hazard for our design: during the cross window `book_top` is a *correct* top of the
*continuous* book and a **wrong** estimate of where the symbol is about to trade. A strategy
treating it as fair value mis-prices systematically, in a publicly known direction that is
being traded against. Symptoms, in the order they present: fills clustered on one side; an
execution printing far from your quoted level (the cross print); a queue-position estimator
resetting on a level that vanished.

> **RULE: during `TRADE_AUCTION`, `book_top` is maintained but is not a valid fair-value
> input.** The strategy does not quote, and any signal computed from the continuous book
> across the cross boundary is discarded rather than carried through.

⚠️ Related decoder hazard: the **cross print** must not be applied to the book as if it
consumed resting orders in the ordinary way, and must not reach volume- or trade-based signal
features untagged.
> **Verify:** which ITCH message carries the cross print, its cross-type field, whether it is
> a distinct type from ordinary trade messages, and the treatment of non-displayable trades,
> against the **Nasdaq TotalView-ITCH 5.0 specification**.

### 4.3 The transition edges are the dangerous moments

The danger is not the phases but the **edges**: the instant continuous trading opens, the
instant it closes, and every halt resume (§6). At an edge the book was built under the
previous regime's rules, resting-order beliefs may be stale, and the first prints are the
most volatile of the phase.

> **RULE: every `sess_state` and per-symbol state transition is edge-detected in fabric and
> forces a conservative posture for a host-configured number of cycles.** Conservative = no
> new quotes; cancels still permitted (cancel always outranks quote —
> [03](03-cancel-latency-and-pickoff.md)); `book_stale` semantics where the transition implies
> a discontinuity; a counter per transition type. The window is a **parameter, not a
> constant**, and the same mechanism serves the open, the close and every resume.

```systemverilog
// rtl/strategy/sess_edge.sv — ZERO latency rows: the inhibit is one bit ANDed into an
// existing gate, evaluated on the SAME cycle the transition is applied.
trade_state_e sess_q;
logic [15:0]  inhibit_q;                    // host-configured, per transition class

always_ff @(posedge clk) begin
    sess_q <= sess_state;
    if (sess_state != sess_q) begin         // ANY edge, in EITHER direction
        inhibit_q              <= cfg_inhibit_cycles[sess_state];
        edge_cnt_q[sess_state] <= edge_cnt_q[sess_state] + 1'b1;
    end else if (inhibit_q != '0) inhibit_q <= inhibit_q - 1'b1;
end
assign quote_inhibit = (inhibit_q != '0);   // gates NEW orders only; cancels pass
```

⚠️ Both directions. An edge *into* `TRADE_OPEN` is obviously dangerous; an edge *out of* it is
too, because something just changed that you have not modelled.

---

## 5. The imbalance feed (NOII) and whether it belongs in fabric

### 5.1 What it carries, at the level an engineer needs

During the pre-cross dissemination window the venue broadcasts, per symbol, a description of
the pending auction: how much quantity would pair at the current reference price, how much
would remain unpaired and on which side, and indicative prices — a current reference price
and cross-price estimates computed with and without continuous-book interest. Field-level
detail is [08.02](../08-nasdaq/02-sessions-auctions-and-halts.md) §2.3.

It is informative about one thing, and it is valuable: **the direction and magnitude of
auction pressure**, hence a partly predictable price move into the cross. That is why the
imbalance window is one of the most heavily modelled periods in US equities.

> **Verify:** the message type, every field name and width, the dissemination **cadence**
> during the pre-cross window (increased over time by rule filing), the window start for each
> cross, and whether the cadence differs between the opening, closing and halt crosses —
> against the **Nasdaq TotalView-ITCH 5.0 specification** and **Nasdaq's opening/closing cross
> documentation and Equity Rulebook (Rules 4752/4753/4754)**. ⚠️ Assert none of these from
> memory: the cadence figure is load-bearing for §5.2, and a wrong one inverts the conclusion.

### 5.2 The decision: NOII is not on the fast path

| Question | Answer | Consequence |
| --- | --- | --- |
| How often does the value change? | On the dissemination cadence — **seconds**, at best sub-second (verify) | A nanosecond decode saves ~10⁻⁹ of the update interval. It buys nothing |
| Is it a *tick* or a *state*? | A **slowly-moving parameter** conditioning behaviour for many seconds | Parameter path, not event path |
| Where is the strategy value? | Reacting to the **continuous book** *with knowledge of* the imbalance — the fast event is the book event | The fast path already handles the fast part |
| Fabric cost | Largest ITCH message; new fields, per-symbol state, predicates | Real area, real verification surface |
| Failure mode | A mis-decode silently biases every quote in that symbol for minutes | High blast radius, low observability |

> **RULE: NOII is decoded on the host and delivered as a per-symbol parameter through the
> existing double-buffered, checksum-verified parameter path**
> ([04.04](../04-system-architecture/04-strategy-engine-on-fpga.md),
> [04.06](../04-system-architecture/06-cpu-fpga-partitioning.md)). **The fabric decoder
> forwards the message to the host and does not interpret it.** No new fast-path fields, no
> new trigger inputs, zero rows in the budget in `rtl/fpga_top.sv`.

**The counter-argument, stated fairly.** Some firms *do* race the imbalance print: at the
instant a new imbalance disseminates the continuous book reprices, and there is a genuine
sub-microsecond race to trade against stale continuous quotes — structurally identical to
racing a scheduled economic release. It is a real strategy and hardware is the right tool.

**This project declines it**, for scope reasons, not because it does not work:

1. It is a **different strategy** — an event-driven taker on a scheduled dissemination — not
   the passive queue-position business the budget was built for.
2. It fires **twice a day per symbol** in a bounded window; a second decode-to-trigger path
   amortises over very few opportunities.
3. It requires the fabric to hold and interpret auction state — exactly the coupling §4.2
   warns against, on the day's highest-consequence prints.
4. ⚠️ It races firms who have specialised their whole system for it. Entering that as a side
   feature of a market-making design is how you lose money quickly.

Revisit it as a **separate strategy block with its own budget and P&L attribution**, never as
a feature bolted onto the quoting path.

---

## 6. Halt and resume handling

[08.02](../08-nasdaq/02-sessions-auctions-and-halts.md) §3 has the taxonomy and reason codes.
This is the engineering.

### 6.1 The halt: the ordering guarantee

When a halt is decoded, quoting must stop **before the next order can be emitted**. That is an
ordering property, not a latency target, and it is met structurally: `u_feed` writes the
per-symbol state, and `u_risk_gate` reads it **after** the strategy has decided, so any halt
decoded before an order reaches the gate is honoured on that order.

> **RULE: the halt gate is combinational on the state-table read in the risk gate, not a state
> machine transition that takes cycles.** A multi-cycle transition creates a window in which
> an order passes a stale `tradable` bit. The residual exposure — the cycles between the state
> write and the gate read — is **documented, bounded, and every order emitted inside it is
> counted** (`order_near_state_change`).

⚠️ An unrecognised trading state or reason code maps to **halted**, never tradable.

### 6.2 ⚠️ The resume is more dangerous than the halt

The halt is easy: stop. The resume is where the money is lost.

| On resume | Why it hurts |
| --- | --- |
| The book is empty, or radically different from pre-halt | Every level index, queue-position estimate and derived signal is anchored to a book that no longer exists |
| Resumption is via a **reopening auction**, not a return to continuous trading | The first print is a cross print, at a price the continuous book never held (§4.2) |
| The timing is **not fixed** — collars widen, auctions are delayed ([08.02](../08-nasdaq/02-sessions-auctions-and-halts.md) §3.4) | A design assuming "pause, then trading" quotes into a market that is not there |
| The first minutes are the symbol's most volatile of the day | Worst adverse selection, thinnest book, widest spread |
| Your resting orders may or may not still exist | §6.3 |

> **RULE: a resume forces `book_stale` for that symbol until a bounded number of book events
> have been applied, AND quoting is inhibited for a host-configured post-resume window (§4.3),
> counted per symbol.** Both must clear: the event count proves the book was rebuilt, the
> timer proves the initial volatility burst passed. Neither alone suffices — an event count
> alone clears instantly in a fast symbol, a timer alone clears on an empty book.

### 6.3 ⚠️ Your own resting orders across a halt

What happens to orders resting at the venue when a symbol halts, and whether they survive to
the reopening, is **a venue policy question — and possibly an order-type and time-in-force
question. It is not an assumption you are entitled to make.**

> **Verify:** the treatment of resting orders across a trading halt and into the reopening
> auction — cancelled, retained, or retained conditionally on order type — against the
> **Nasdaq Equity Rulebook** (halt-cross and order-type rules), and what the venue reports to
> you when it happens, against the **Nasdaq OUCH 5.0 specification**.

> **RULE: the system reconciles rather than assumes.** On any halt in a symbol where we hold
> order state, the host marks that state **unknown** and reconciles against the venue's own
> messages and the drop copy before any new order is emitted in that symbol. Fabric `my_state`
> is invalidated and the queue-position estimator is cleared, not adjusted
> ([01](01-queue-position-and-fill-probability.md) §3.6). ⚠️ Assuming your order survived and
> quoting around it produces a **double position** if it did not, and a phantom hedge if it did.

### 6.4 The two rate realities of state messages

| Case | Rate character | Consequence |
| --- | --- | --- |
| **Halts in symbols we do not track** | A trickle, all filtered | ⚠️ They must still be *decoded*: the state table is locate-indexed and a halt is not book-affecting, so it bypasses the R5 book-event path. Confirm the state side-channel is not accidentally filtered out with the book events |
| **LULD band updates in symbols we do track** | ⚠️ **Continuous, all day, every tracked symbol** — bands recompute as the reference price moves | Not rare events. A sustained write load on the per-symbol state table that peaks with volatility, i.e. concurrently with everything in §2 |
| **Single-symbol news halt and resume** | Extreme rate in **one** symbol, unremarkable aggregate | ⚠️ A per-symbol structure can be overrun while every aggregate counter looks healthy. Keep per-symbol high-water marks |
| **MWCB** | Global, immediate | Reuses the kill-switch path, so it is exercised by the kill-switch tests |

---

## 7. ⚠️ The operational rule: a system that works at 11am may fail at 9:30am

**11am is the easiest moment of the trading day**, and it is when almost all ad-hoc testing
happens. Then, the message rate is at its daily trough, breadth is narrow, the live-order
count is well below peak, no session transitions occur, no imbalance messages disseminate, the
die has reached thermal steady state at a modest load, and every host process has had an hour
to settle. A system observed only at 11am has been observed in the regime that exercises the
fewest code paths.

| Failure | Why it cannot appear midday | Where it surfaces |
| --- | --- | --- |
| **Buffer / ring overflow** | Arrival never exceeds service at the median rate | Telemetry ring, audit ring, host queues |
| **Table capacity overflow** | Live-order count far below its high-water mark | Order-map eviction ⇒ missed deletes ⇒ phantom liquidity |
| **Counter saturation / rollover** | The counter never reaches its width midday | Rate counters, per-symbol counts, histogram buckets |
| **Log-ring drops** | `S_log > R_tel` all day | §2.3 — and it censors exactly the data you need |
| **Host consumption falling behind** | Slack is enormous midday | `ttd-risk` drain, reconciliation, watchdog margin |
| **Timing margin under thermal load** | Sustained toggle rate raises `Tj`; margin moves with it | Only under sustained burst — [06](06-timing-report-forensics.md), [07](07-jitter-sources-and-determinism.md) |
| ⚠️ **Paths only exercised by session transitions and imbalance messages** | **They literally never execute midday** | The `TRADE_AUCTION` arm, the edge-detect inhibit, the resume path, NOII forwarding, cross-print tagging — **zero coverage from a midday replay, at any duration** |

That last row is why duration does not substitute for content. **Eight hours of midday replay
gives exactly zero coverage of the transition logic.** Soak *time* is not soak *breadth*.

> **RULE: soak and load tests MUST use real open-of-day and close-of-day capture. A synthetic
> stream or a mid-day replay is not evidence — at any duration, for any capacity, latency or
> correctness claim about this system.** A latency figure quoted without a stated load profile
> that includes a real open is not a result
> ([05.04](../05-optimization/04-measurement-and-profiling.md) §8–§9).

### 7.1 The test corpus specification

Complements [06.04](../06-operations/04-testing-strategy.md) §4 with the *selection criteria*
— which dates, and why each earns its storage.

| Entry | Selection criterion | What it, and only it, exercises |
| --- | --- | --- |
| `open_normal` | An unremarkable session's pre-open into the first minutes of continuous trading | Baseline burst shape; the open edge; sizing inputs |
| `open_high_volume` | The highest-message-rate open in the archive | **The sizing case**: buffer depths, table HWM, counter widths |
| `close_index_event` | A triple-witching or index-rebalance close | Extreme imbalance magnitude and cross notional; position/notional limits |
| `close_normal` | An ordinary close | The close edge and the imbalance window at normal scale |
| `day_with_halt` | A session with a news halt and its reopening cross in a tracked symbol | §6 entirely — the only path exercising resume, and not faithfully synthesisable |
| `day_with_luld` | Heavy band activity and at least one limit state | Sustained state-table write load; band gate; straddle handling |
| `half_day` | An early-close session | ⚠️ Proves the schedule is host-loaded, not a constant. A hardcoded close quotes into a closed market ([08.02](../08-nasdaq/02-sessions-auctions-and-halts.md) §7) |
| `ipo_day` | A session with an IPO in the universe | Stock Directory mid-session, IPO quoting-period messages, a symbol appearing from nothing |

> **Verify:** that Nasdaq publishes historical TotalView-ITCH sample files (full raw days, by
> date) suitable for this, the current access terms, and that the samples are the product
> version you decode — from the **Nasdaq Trader / Nasdaq Data Link market data sample
> archives**. Record the exact file identifiers and dates in `docs/` beside every derived
> figure.

⚠️ Where a real capture does not exist for a criterion, **say so and label the synthetic
substitute** — never let a synthesised halt stand in the corpus as if it were a capture.

### 7.2 The profiler: a captured day → sizing inputs

```python
#!/usr/bin/env python3
# host/analysis/profile_day.py — slow path, offline. One raw ITCH day in; every
# measurement-derived input that §2 and §7.3 require out.
import collections, json, sys
import numpy as np

TRACKED    = set(json.load(open(sys.argv[2])))          # our locates. ALWAYS filter.
WINDOWS_NS = [1_000, 100_000, 1_000_000, 100_000_000, 1_000_000_000]
BUCKET_NS  = 60 * 1_000_000_000                         # 1-minute time-of-day buckets

live, ref_sym = collections.Counter(), {}               # locate->live refs ; ref->locate
hwm_tot, hwm_sym, live_ts = 0, collections.Counter(), []
ts_all, ts_kept = [], []
mix     = collections.defaultdict(collections.Counter)  # bucket -> type -> count
breadth = collections.defaultdict(set)                  # bucket -> {locate}

for m in itch_messages(sys.argv[1]):                    # streaming, spec-derived decoder
    b = m.ts_ns // BUCKET_NS
    mix[b][m.type] += 1; breadth[b].add(m.locate); ts_all.append(m.ts_ns)
    if m.locate not in TRACKED:                         # everything below is post-filter
        continue
    ts_kept.append(m.ts_ns)
    if   m.type in b"AF": ref_sym[m.ref] = m.locate; live[m.locate] += 1
    elif m.type == b"U":                                # retires old ref, creates a new one
        if m.ref in ref_sym: live[ref_sym.pop(m.ref)] -= 1
        ref_sym[m.new_ref] = m.locate; live[m.locate] += 1
    elif m.type == b"D":
        if m.ref in ref_sym: live[ref_sym.pop(m.ref)] -= 1
    elif m.type in b"ECX" and m.remaining == 0:         # E/C/X can retire an order too
        if m.ref in ref_sym: live[ref_sym.pop(m.ref)] -= 1
    tot = sum(live.values()); hwm_tot = max(hwm_tot, tot)
    hwm_sym[m.locate] = max(hwm_sym[m.locate], live[m.locate])
    live_ts.append((m.ts_ns, tot))                      # KEEP THE SERIES, not just the max

def peak(ts, w):                                        # max msgs in any sliding w-ns window
    a = np.asarray(ts, dtype=np.int64)
    return int((np.searchsorted(a, a + w, "left") - np.arange(a.size)).max())

json.dump({
  "peak_msgs_per_window": {f"{w}ns": {"all": peak(ts_all, w), "tracked": peak(ts_kept, w)}
                           for w in WINDOWS_NS},        # ⚠️ SHORT windows size the buffers
  "live_order_hwm_total":   hwm_tot,                    # -> ORDER_MAP_ENTRIES (09.05 §8)
  "live_order_hwm_worst":   hwm_sym.most_common(10),    # -> per-symbol structures
  "hwm_time_of_day_ns":     max(live_ts, key=lambda x: x[1])[0],   # expect open or close
  "breadth_by_minute":      {b: len(s) for b, s in sorted(breadth.items())},
  "tracked_frac_by_minute": {b: len(breadth[b] & TRACKED) / len(breadth[b])   # §2.5
                             for b in sorted(breadth)},
  "type_mix_by_minute":     {b: dict(c) for b, c in sorted(mix.items())},
}, open(sys.argv[3], "w"), indent=1)
```

⚠️ **Report the peak over several window lengths.** A per-second peak is smooth enough to be
reassuring and useless for sizing a ring that overflows in a millisecond. The 1 µs and 100 µs
figures decide buffer depths; the 1 s figure is for a capacity conversation with the venue.

### 7.3 Acceptance criteria — evaluated on the burst window specifically

| # | Criterion | Measured over |
| --- | --- | --- |
| 1 | **Zero drops on the fast path.** All `drop_*` and `window_overrun` zero; `filtered` and `dup_*` non-zero (absence means a feed is down) | Whole replay |
| 2 | **No table overflow.** Order-map eviction count zero; every capacity HWM below its limit with stated margin | Whole replay |
| 3 | **All counters non-saturating.** No counter reaches its width; no sticky first-error latch set | Whole replay |
| 4 | **Ring drops zero.** `tel_ring_drops == 0` **and** `audit_ring_drops == 0`; occupancy HWM recorded | **Burst window** |
| 5 | **Latency p99.9 within budget** | ⚠️ **Burst window specifically — not the whole day** |
| 6 | **Every transition path executed at least once**, evidenced by its edge counter | Whole replay |
| 7 | Book matches the golden model after every message; strategy intents match the golden strategy | Whole replay |

⚠️ **Criterion 5 is the one routinely faked by accident.** A whole-day p99.9 is dominated by
the midday trough, where the system is idle and every sample sits near the floor; the burst
contributes a small fraction of samples and disappears into the tail. **A whole-day p99.9 can
look excellent while the open p99 is over budget.** Compute burst-window percentiles as a
separate population and report both. [07](07-jitter-sources-and-determinism.md) explains why
the distributions differ at all — queueing behind preceding messages in a packet, contention
and thermal effects are all load-dependent, and none exist in the idle profile.

---

## 8. Pre-open operational sequence

The fabric-facing runbook: what is specific to *this* session's open. It refines
[04.06](../04-system-architecture/06-cpu-fpga-partitioning.md) §7 and complements
[08.01](../08-nasdaq/01-market-structure.md) §9.

| # | Step | Source of truth | Verification before proceeding |
| --- | --- | --- | --- |
| 1 | **Build ID arm check** — `BUILD_ID` / `GIT_SHA` match the approved release | `docs/` release record ([06.01](../06-operations/01-build-and-release.md)) | Exact match, else **abort**. Never "probably the right bitstream" |
| 2 | **Fail-closed check after reset** | Fabric | Kill armed, `cfg_trading_en == 0`, all limits and counters zero |
| 3 | **Session schedule table** — today's phase boundaries | Venue calendar file, host-loaded | ⚠️ The **half-day / holiday check is this step**, not an afterthought |
| 4 | **Symbol filter + locate map** from today's Stock Directory | ITCH `R` replay / SOD file | Read back **every** entry — locates change daily |
| 5 | **Per-symbol venue state**: LULD tier, round lot, SSR carried from yesterday | Host config + ITCH | ⚠️ SSR persists across days; the fabric does not remember yesterday. Unknown ⇒ **restricted** |
| 6 | **Risk parameters** — per-symbol limits, notional, position, credit | Host risk config | Read back every field; posted writes are unreliable |
| 7 | **Strategy parameters**, incl. today's regime sets (§3) and NOII slots (§5) | `ttd-params` | Shadow bank → checksum → commit → read back active |
| 8 | **OUCH templates** per symbol/side | Host | Checksum read-back |
| 9 | **DMA rings** sized per §2.3 for today's expected peak; hugepages resident | Host | Inject a synthetic record; read it back |
| 10 | **Feed enable**; require unbroken sequence continuity for a stated interval | Fabric counters | `gap_*` zero over the interval; `dup_*` non-zero |
| 11 | **Book build + per-symbol verification** against the software shadow book | Fabric + host | Clear `book_stale` **per symbol**, never globally |
| 12 | **OUCH session up**, TX ownership to fabric, watchdog kicking | Host | `sess_up`; watchdog decrementing |
| 13 | **Arm trading** — `cfg_trading_en`, then kill-clear | Operator | — |

> **RULE: arming trading is the last step, and it is gated on read-back verification of every
> preceding step.** Not "the writes returned" — a read of the value written, compared. There
> is never a window in which the system can emit an order but has not been fully verified. If
> a step fails, **you stop at that step**: the cost of not trading for an hour is bounded and
> known; the cost of trading on an unverified risk limit is not
> ([06.01](../06-operations/01-build-and-release.md),
> [06.02](../06-operations/02-deployment-and-colocation.md)).

⚠️ Two open-specific additions to the generic sequence: **(a)** step 3 must fail loudly if
today's date is absent from the calendar file, rather than defaulting to a regular session —
it is the only defence against a half day; **(b)** step 9 sizes the rings for *today's*
expected peak, which on a known-heavy day (index rebalance, macro event, expiry) is not the
standing configuration.

---

## 9. Rules for this project

1. **Everything is sized to the peak, never the median** — buffers, tables, counter widths, ring depths, host drain rates.
2. **The fast path never queues; only variable-rate consumers do.** Enumerate them (§2.2) and size each with `(arrival − service) × burst_duration` from measured inputs.
3. **Log-ring overflow is counted, sticky, timestamped and alerted on the first record.** Dropping log records beats backpressuring the fast path — but a censored sample invalidates that day's latency statistics, and the report must say so.
4. **The audit ring keeps the opposite policy: full ⇒ kill.** Do not harmonise them.
5. **`ORDER_MAP_ENTRIES` and every capacity bound come from an open-of-day high-water mark** over the §7.1 corpus, recorded with dates in `docs/`.
6. **Auction order types are never emitted by the fabric.** Host-originated, supervised, through the same hardware risk gate. No fabric templates exist for them.
7. **The continuous book is not the auction book.** In `TRADE_AUCTION`, `book_top` is maintained but is not a valid fair-value input; cross prints are tagged, never treated as ordinary trades.
8. **Every state transition is edge-detected and forces a conservative posture** for a host-configured number of cycles, in **both** directions, counted per transition type.
9. **The halt gate is combinational on the state-table read in the risk gate**, downstream of the strategy. Unknown state or reason code ⇒ halted.
10. **The resume forces `book_stale` until N events applied AND a post-resume timer expires.** Both, not either.
11. **Order state across a halt is reconciled, never assumed.** Fabric `my_state` invalidated, queue estimator cleared, host reconciles against the venue and drop copy first.
12. **NOII is host-decoded and delivered as a per-symbol parameter.** Zero fast-path rows. Racing the imbalance print is a separate strategy with its own budget, or it is not done.
13. **The closing window is its own strategy regime**, selected by the session state machine.
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
