# 09.03 — Cancel Latency and the Pickoff Race

> **Why this matters here:** the `rtl/fpga_top.sv` budget is written as one path — wire in,
> order out. It is actually **two** paths sharing a prefix, and the one nobody budgets
> separately is the one that decides whether this business makes money. Entry latency buys
> queue position; cancel latency buys survival. This document builds the pickoff race
> arithmetically, shows why US equities give you no business-rule escape from it, and
> specifies the dedicated cancel datapath — its templates, arbitration, credit rules, budget
> rows and histograms. [03.02](../03-algotrading/02-order-types-and-matching-engines.md) §8
> states the case; [09.01](01-queue-position-and-fill-probability.md) §5.1 states the
> asymmetry. This is the implementation.

---

## 1. The asymmetry, stated first

**Entry latency competes for a gain you might not have had. Cancel latency avoids a loss
you will otherwise definitely take.** Not symmetric bets; not symmetric engineering.

| | **Entry path** (add / requote) | **Cancel path** (pull a stale quote) |
| --- | --- | --- |
| Who you race | Other **liquidity providers** joining the same new level | **Liquidity takers** who have already decided to hit you |
| Their intent toward you | Indifferent — they want the slot, not your money | **Adversarial and specific.** You are the target |
| Outcome if you win | A queue slot: a lottery ticket worth `P(fill) × E[value \| fill]` | Nothing happens. You keep what you had |
| Outcome if you lose | A worse slot, or none. Bounded, often ~zero | **A fill at a price you have already priced as wrong** |
| Payoff distribution | Bounded above by one half-spread + rebate | **Unbounded on the tail** — full adverse move × full quote size |
| Can you decline after the fact? | n/a | **No.** §3 |
| Frequency | Once per level formation | **Every requote, fade, widen and risk trip** |

### 1.1 The frequency asymmetry, which is the one people miss

A market-making system emits far more cancels than it receives fills. Every quote move is a
cancel plus an add; every fade, widen, halt and risk trip is a cancel with no add. Fills are
the *rare* terminal event. **Cancel is the highest-rate latency-critical message class in
the system.** Three structural consequences:

1. **Its tail is sampled far more often.** A 1-in-1,000 slow event across 50,000 cancels a
   session is ~50 hits a day — burst-correlated, i.e. concentrated on exactly the events a
   pickoff is live on. p99.9, not p50, is the cancel-path metric
   ([07-jitter-sources-and-determinism.md](07-jitter-sources-and-determinism.md)).
2. **Cancels dominate rate-limit consumption.** Any shared token bucket is drained by
   cancels and then fails an order — or, catastrophically, the reverse (§4.5).
3. **Cancels dominate the order-to-trade ratio**, hence the messaging economics.

> **Verify:** current order-entry message-rate thresholds, burst allowances, and
> order-to-trade / excess-messaging fee provisions in the **Nasdaq Price List
> (nasdaqtrader.com)** and the relevant rulebook sections
> ([08.05](../08-nasdaq/05-ouch-5.0-order-entry.md) §9). Never design a quoting cadence
> against an assumed limit.

---

## 2. The pickoff race, modelled

### 2.1 The timeline, with named events

```
t0   PRICE-FORMING EVENT hits a wire: a trade printing on another venue, a large
     add/cancel here, a futures print in Aurora, an index/ETF arb signal.
t1   It reaches OUR optic in Carteret.       t1' It reaches THEIRS.  t1 ≈ t1' (§2.3)
t2   We decode, apply to the book, and X0    t2' They decode and decide to TAKE.
     fires: "a quote we own is mispriced."
t3   Our CANCEL leaves our TX optic.         t3' Their IOC leaves their TX optic.
t4   Our cancel is sequenced at the venue.   t4' Their IOC is sequenced at the SAME
                                                  gateway.
     ── ONE sequencer, arrival order only. It does not know who started ──
     ── first, and there is no tiebreak. Only t4 vs t4' exists.        ──
t5   WE WIN:   `Canceled`. Cost: one message.
     THEY WIN: `Executed`. We own shares we had already decided were wrong.
```

### 2.2 The inequality

```
   t_detect_me  +  t_react_me  +  t_wire_me→venue
        <
   t_detect_them + t_react_them + t_wire_them→venue
```

| Component | Ours | Control? | Specified in |
| --- | --- | --- | --- |
| `t_detect` — optic → book event applied | **173.2 ns** | **Full** — feed handler, decoder, book | `rtl/fpga_top.sv` rows |
| `t_react` — book event → photons on TX fibre | **128.4 ns** | **Full** — this document | §6 |
| `t_wire` — TX optic → venue sequencer | fibre + venue ingress | **None, by design** | §2.3 |
| Competitor's equivalents | Unknown | **None** | §2.4 |

**You control ~300 ns of a race whose total is ~300 ns plus a shared, uncontrollable
constant.** That constant cancels out of the inequality — which is precisely why the fabric
numbers matter this much.

### 2.3 The part you do not control, and why that is good news

> **Verify:** Nasdaq equalises the physical path length from every colocation cabinet to the
> matching-engine handoff using **standardized-length cables**. Read the current
> standardized-cabling policy in the **Nasdaq colocation service description**, and re-read
> it at renewal — it is a filed service that can change
> ([08.08](../08-nasdaq/08-connectivity-and-colocation.md) §1).

If that holds, `t_wire` is identical for every colocated participant and the inequality
collapses to `t_detect + t_react` — pure engineering. Two corollaries: **do not buy a
"closer" cabinet** (there is none to buy), and ⚠️ **every switch hop inside your own cage is
a self-inflicted loss** of tens to hundreds of nanoseconds — comparable to your *entire*
fabric budget. `handoff → optic → FPGA`, nothing between
([02.04](../02-networking/04-nics-kernel-bypass-and-switching.md)).

⚠️ **`t1 ≈ t1'` fails when the price-forming event happens somewhere else.** If `t0` is a
CME print in Aurora, the race includes a ~1,200 km leg decided by *wireless versus fibre*,
not by your fabric. Know which regime each symbol is in: single-venue microstructure signals
are a fabric race; cross-asset lead-lag signals are a telecoms race you have not entered
([03.05](../03-algotrading/05-strategy-taxonomy.md)).

### 2.4 A worked race — ILLUSTRATIVE

> **ILLUSTRATIVE.** Our column is derived from the `rtl/fpga_top.sv` rows and §6 — a
> *target*, not a measurement. The competitor column is a placeholder.
> **Verify:** any competitor figure against dated, methodology-stated sources — published
> vendor tick-to-trade datasheets, **STAC** benchmark reports, and your own measured
> `hist_cancel_ack_rtt` (§5). Never a conference anecdote or a sales deck.

| Stage | Us — cancel | Sniper — IOC take | Note |
| --- | ---: | ---: | --- |
| Optics + GT RX PMA/PCS | 90.0 | 90.0 | Hard IP; comparable for anyone on FPGA |
| MAC RX → ITCH decoded | 51.2 | ? | 8 fabric cycles |
| Symbol filter + order map + book apply | 32.0 | ? | 5 cycles. A sniper may skip the book |
| **Decision** | 6.4 | ? | X0: one comparator (§4.1) |
| Gate + encode + framing | 19.2 | ? | X1–X3 |
| MAC TX | 12.8 | ? | Cut-through |
| GT TX PCS/PMA + optics | 90.0 | 90.0 | Hard IP |
| **Wire-to-wire** | **301.6 ns** | **`T`** | §6 |
| Cross-connect + venue ingress | `W` | `W` | Identical if §2.3 holds |
| **Sequenced at** | `301.6 + W` | `T + W` | **We survive iff `T > 301.6 ns`** |

**Note the shape.** 180 ns of our 302 ns is hard IP at the two optics — untouchable. Of the
122 ns of fabric, only **25.6 ns** is cancel-specific logic; the rest is the shared
feed-and-book prefix. *Optimising the cancel path mostly means optimising the feed handler.*

### 2.5 How much faster do I need to be — ILLUSTRATIVE

| Competitor class (ILLUSTRATIVE) | Their `T` | Margin at 301.6 ns | Outcome |
| --- | ---: | ---: | --- |
| Best-in-class FPGA, book-free trigger | ~250 ns | **−52 ns** | **Lose. Every time** |
| Peer FPGA, comparable pipeline | ~300 ns | +2 ns | **Coin flip decided by jitter** |
| FPGA trigger, software decision | ~700 ns | +398 ns | Win |
| Kernel-bypass software, tuned | 2–5 µs | +1.7–4.7 µs | Win comfortably |
| Colocated but untuned / kernel stack | 10–50 µs | — | Not in the race |

> **Verify:** every row. These are placeholders whose only job is to show that the function
> is a **step**, not a slope. Keep consistent with
> [07.02](../07-reference/02-latency-reference-numbers.md).

### 2.6 ⚠️ The race is against the *fastest* watcher, not the average one

Being second-fastest is worth **almost exactly nothing on any individual event**. With `N`
participants reacting to this symbol, each independently beating you with probability `F`:

```
P(we cancel in time) = (1 − F)^N
```

| Our speed rank among reactors | N=1 | N=2 | N=4 | N=8 | N=16 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Faster than 50 % of them | 0.50 | 0.25 | 0.063 | 0.004 | ~0 |
| Faster than 75 % | 0.75 | 0.56 | 0.32 | 0.10 | 0.010 |
| Faster than 90 % | 0.90 | 0.81 | 0.66 | 0.43 | 0.19 |
| Faster than 99 % | 0.99 | 0.98 | 0.96 | 0.92 | 0.85 |
| **Faster than 99.9 %** | 0.999 | 0.998 | 0.996 | **0.992** | **0.984** |

**This table is the whole argument for determinism over mean speed.** Moving from "faster
than 90 %" to "faster than 99 %" is worth twice as much at N=8 as at N=1 — and popular
symbols have large `N`. A p50 of 300 ns with a p99.9 of 900 ns is **not** a 300 ns system:
on 0.1 % of events you drop into the top row, and those events are burst-correlated, which
means they are the pickoff events. **Your effective speed is your p99.9**
([07-jitter-sources-and-determinism.md](07-jitter-sources-and-determinism.md), CLAUDE.md §5
rule 8).

---

## 3. The "last look" you do not get in US equities

In FX, a liquidity provider who is hit on a streamed quote gets a brief hold window in which
to price-check and **reject** the trade. It exists because FX LPs stream to many venues and
clients over heterogeneous, high-latency links and structurally *cannot* cancel fast enough
everywhere: last look is a **business rule substituting for cancel speed**.

> **Verify:** the definition of last look, disclosure obligations, and hold-window treatment
> in the **FX Global Code** (Global Foreign Exchange Committee), current edition. It is a
> conduct standard, not a statute, and its text has been revised.

| Venue model | The quote is… | Provider's post-hit rights | Your protection against a stale quote |
| --- | --- | --- | --- |
| **FX, last look** | Indicative in practice | Hold, price-check, **reject or fade** | The business rule |
| **RFQ / dealer** | Valid for a stated window, named counterparty | Decline to re-quote after expiry | The window's terms |
| **US equity firm quote (us)** | **Firm, immediately executable** | **None. Zero. There is no reject** | **A cancel that arrives first** |

Once your displayed order is on the book and an aggressive order matches it, you are done:
no reject, no fade, no hold time, no minimum-resting-time escape.

> **RULE: the only last look this system has is a cancel that reaches the sequencer before
> the taker's order.** That converts a business-rule problem into a pure latency problem —
> and a pure latency problem is one that hardware can solve. **This is why the project
> exists.**

### 3.1 Speed bumps, and what they do to this calculus

| Class | Mechanism | Effect on the §2.2 inequality |
| --- | --- | --- |
| **Symmetric access delay** | Fixed delay on *all* inbound orders and cancels | Adds the same constant to both sides — **near-neutral** to the race. The real effect lives in whether the venue's own pegged/repricing order types use undelayed data |
| **Asymmetric delay** | Delay on *aggressive* orders but not cancels/repricing | **A synthetic last look.** Your cancel goes fast, their take goes slow. Transforms the economics of resting liquidity there |
| **Batching / frequent auctions** | Inbound collected into discrete intervals and crossed | **Removes the intra-interval race entirely.** Speed inside the window is worthless; the race moves to the window boundary |

> **Verify, per venue, every time:** whether a delay mechanism exists, whether it is
> symmetric, which message classes it applies to, and its duration — from the venue's own
> rule filings and SEC approval orders. **These rules change.** In particular confirm the
> current status of any delay on **Nasdaq's main US equity book** before assuming this
> project faces an undelayed race ([08.01](../08-nasdaq/01-market-structure.md),
> [08.06](../08-nasdaq/06-regnms-and-compliance.md)).

⚠️ **Do not port a strategy across venues without re-deriving §2.2.** A strategy tuned where
an asymmetric delay granted a synthetic last look will be systematically picked off on a
venue without one — and the P&L will look like signal decay, not a structural change.

---

## 4. Design consequences

### 4.1 A dedicated cancel datapath

> **RULE: after the book event the cancel path shares no arbitration, no FIFO and no gate
> logic with the entry path.** It forks at the book event and re-converges only at `tx_mux`,
> where it has strict priority.

```
                    book_evt   (shared prefix ends — 173.2 ns cumulative)
                         │
        ┌────────────────┴──────────────────┐
        ▼                                   ▼
 ┌────────────────┐              ┌──────────────────────────┐
 │ strategy_engine│              │ cancel_trigger      X0   │ my_state[slot].px vs
 │ params, price  │              │ ONE comparator     1 cy  │ precomputed bound
 │           2 cy │              └────────────┬─────────────┘
 └───────┬────────┘                           ▼
 ┌───────▼────────┐              ┌──────────────────────────┐
 │ u_risk_gate    │              │ cancel_gate         X1   │ 4 checks — NOT the
 │ 24 checks 2 cy │              │                    1 cy  │ exposure checks
 └───────┬────────┘              └────────────┬─────────────┘
 ┌───────▼────────┐                           ▼
 │ ouch_encode    │              ┌──────────────────────────┐
 │ tmpl+splice2cy │              │ cancel_encode       X2   │ cancel_tmpl[slot],
 └───────┬────────┘              │                    1 cy  │ token PRE-spliced
         └───────────┬───────────└────────────┬─────────────┘
                     ▼                        ▼
          ┌──────────────────────────────────────────────┐
          │ soupbin/tcp framing + tx_mux            X3   │
          │ STRICT PRIORITY — cancel = grant 0      1 cy │
          └──────────────────────┬───────────────────────┘
                                 ▼   MAC TX (2 cy) → GT TX → optic
```

The cancel path is **shorter by construction**, not by tuning:

| Entry stage | Cost | Cancel equivalent | Cost | Why it is cheaper |
| --- | ---: | --- | ---: | --- |
| Strategy parameter read + price computation | 2 cy | Invalidation compare | 1 cy | The bound was precomputed into `my_state` when the quote was posted — one comparator, no parameter fetch, no arithmetic |
| Full 24-check risk gate | 2 cy | Reduced cancel gate | 1 cy | Below |
| Template read + splice price/qty/token + cksum | 2 cy | Template read + seq/ID patch | 1 cy | The token is already baked into the template (§4.2) |
| **Total after the book** | **6 cy** | | **3 cy** | **19.2 ns — plus a far better tail** |

⚠️ **Do not oversell the 19.2 ns.** The mean saving is three cycles. The real win is that the
cancel never queues behind a new order, never waits on a parameter memory another requester
is using, and has no data-dependent stage — so its p99.9 is its p50. Per
[09.01](01-queue-position-and-fill-probability.md) §5.1, buying tail is the trade.

#### Which risk checks a cancel keeps

> **RULE: a cancel bypasses every check whose purpose is to prevent *adding* exposure. It
> keeps only what is physically or protocol-necessary — and it always feeds the
> counter/telemetry path.**

| Kept in `cancel_gate` | Why |
| --- | --- |
| TX ownership held by the FPGA | Physical: the CPU may own the TCP stream ([04.05](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) §8) |
| Slot live, known token, **matching generation** | Protocol; and §4.2's safety argument |
| No cancel already in flight for this token | Dedupe; protects the message budget |
| **Separate** cancel rate bucket | Hygiene only, sized never to bind (§4.5) |

| Dropped for cancels | Why dropping it is *correct*, not a shortcut |
| --- | --- |
| Price collars, order size, notional, daily notional | A cancel has no price and no new size |
| Projected/gross position, open-order count | A cancel strictly **reduces** all three |
| Symbol enabled, session open, **halted**, params fresh | ⚠️ If we are halted or our parameters went stale we want the quote **gone**, not held |
| `book_stale` | ⚠️ A stale book is the strongest possible reason to cancel. Gating on it inverts the control |
| In-flight order credit | §4.5 |
| **The kill switch** | Below |

#### ⚠️ The kill switch must never block a cancel

```
   KILLED  ≠  SILENT
   KILLED  =  no NEW orders, cancels STILL WORK, get flat
```

A kill switch gating *all* outbound traffic leaves you holding unmanaged live quotes in a
market you have just declared unsafe — **maximally exposed, by the mechanism built to reduce
exposure** ([03.06](../03-algotrading/06-risk-and-compliance.md) §8).

⚠️ **Concrete trap in this repository.** `rtl/fpga_top.sv` asserts
`kill_active |-> ##[0:KILL_RESP_CYCLES] !order_out_valid` with `KILL_RESP_CYCLES = 4`. That
property is correct **only if `order_out_valid` means "new order", not "any outbound OUCH
frame"**. If a refactor routes cancels through the same valid, the assertion will either
fail in regression or — far worse — be "fixed" by gating cancels with `kill_active`,
silently producing the exact design §8 of the risk manual forbids. Keep the cancel valid on
a distinct signal and assert the dual property: `kill_active` must **not** inhibit
`cancel_out_valid`. Both belong in the same testbench
([06.04](../06-operations/04-testing-strategy.md)).

### 4.2 Pre-built cancel templates

A Cancel Order message is more constant than an Enter Order, and — the key insight — **its
token is known at order-accept time**, microseconds before any cancel is contemplated. The
entire frame, token included, is therefore pre-encoded per resting-order slot in BRAM.

> **Verify:** the OUCH 5.0 `Cancel Order` field set, ordering, widths, and the full-cancel
> quantity encoding, from the **Nasdaq OUCH 5.0 specification**. Generate template contents
> on the host from the spec, never by hand
> ([08.05](../08-nasdaq/05-ouch-5.0-order-entry.md) §3, §7).

```systemverilog
// rtl/order/cancel_tmpl.sv — budget row X2, 1 fabric cycle.
// Written on the SLOW side at OUCH `Accepted`: microseconds after the order was
// sent, so the write is FREE relative to the cancel it will one day serve.
module cancel_tmpl import trading_pkg::*; #(
    parameter int unsigned N_SLOT  = MAX_LIVE_ORDERS,
    parameter int unsigned FRAME_W = 8*64,     // complete Eth|IPv4|TCP|Soup|Cancel
    parameter int unsigned GEN_W   = 8
)(
    input  var logic                      clk,
    // ── slow side: one write per accepted order; never on the fast path ──────
    input  var logic                      wr_en,
    input  var logic [$clog2(N_SLOT)-1:0] wr_slot,
    input  var logic [FRAME_W-1:0]        wr_frame,  // token ALREADY spliced
    input  var logic [15:0]               wr_csum0,  // cksum with seq/IP-ID zeroed
    input  var logic [GEN_W-1:0]          wr_gen,    // ⚠️ generation of this slot
    input  var logic                      retire_en, // TERMINAL venue msg only
    input  var logic [$clog2(N_SLOT)-1:0] retire_slot,
    // ── fast side: ONE read, ONE cycle, no arbitration, no contention ────────
    input  var logic                      rd_en,
    input  var logic [$clog2(N_SLOT)-1:0] rd_slot,
    input  var logic [GEN_W-1:0]          rd_gen,    // generation the caller believes
    output var logic [FRAME_W-1:0]        rd_frame,
    output var logic [15:0]               rd_csum0,
    output var logic                      rd_valid
);
    (* ram_style = "block" *) logic [FRAME_W-1:0] mem [N_SLOT];
    logic [15:0] csum0 [N_SLOT];  logic [GEN_W-1:0] gen [N_SLOT];  logic live [N_SLOT];

    always_ff @(posedge clk) begin
        if (wr_en) begin
            mem[wr_slot] <= wr_frame;  csum0[wr_slot] <= wr_csum0;
            gen[wr_slot] <= wr_gen;    live[wr_slot]  <= 1'b1;
        end
        // ⚠️ Retire on a TERMINAL venue message, NEVER on cancel transmission:
        //    PENDING_CANCEL -> FILLED is a reachable edge (03.02 §9).
        if (retire_en) live[retire_slot] <= 1'b0;

        rd_frame <= mem[rd_slot];
        rd_csum0 <= csum0[rd_slot];
        rd_valid <= rd_en & live[rd_slot] & (gen[rd_slot] == rd_gen);  // the safety net
    end
endmodule
```

| Encoding approach | Cycles | ns | Note |
| --- | ---: | ---: | --- |
| Serialize the Cancel message field by field | 8–12 | 51–77 | [04.05](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) §6 |
| Entry-style template + splice token/qty + cksum | 2 | 12.8 | What the entry path pays |
| **Per-slot template, token pre-spliced, seq/ID patch only** | **1** | **6.4** | **Chosen. ~45–70 ns saved vs. from scratch** |

Only three 16-bit words change at emit — TCP sequence, IP identification and the folded
checksum — so the RFC 1624 incremental patch is a three-term tree, trivially inside a cycle
([04.05](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) §6).

⚠️ **The hazard is a stale template for a reused slot.** Slot 7 held order A; A filled; slot
7 was reallocated to order B. A cancel generated against a stale view of slot 7 sends B's
pre-encoded cancel — **you pull the quote you wanted to keep and leave the one you wanted
dead.** The failure is silent: the venue accepts it, the ack looks normal, and the loss
surfaces as unexplained adverse selection.

> **RULE: every slot carries a generation counter, incremented on every allocation, and
> every cancel request carries the generation it believes.** A mismatch fails `rd_valid`,
> suppresses the frame and increments `cancel_stale_gen`, which must be **zero forever** in
> production ([06.03](../06-operations/03-monitoring-and-telemetry.md)). A `live` bit alone
> is insufficient — reallocation can occur between read issue and compare.

### 4.3 Cancel-before-quote-update ordering

```
(A) ADD-then-CANCEL  ⛔ FORBIDDEN
    t     ADD @ new price sent
    t+δ   CANCEL of old price sent
          ── window δ + venue processing with TWO LIVE QUOTES ──
          The stale one sits at a price we have ALREADY DECIDED IS WRONG.
          Worst case: filled on BOTH. Double size at the worst moment.

(B) CANCEL-then-ADD  ✅ THE RULE
    t     CANCEL of old price sent
    t+δ   ADD @ new price sent
          ── window δ with ZERO LIVE QUOTES ──
          Cost: δ of forgone queue time at the new price. BOUNDED and small —
          and we were going to the tail of the new level anyway.

(C) REPLACE          ⚠️ CONDITIONAL — slow path only
    t     REPLACE sent
          ── window 0 IF the venue applies it atomically ──
          BUT priority is generally lost, the encode is not necessarily
          cheaper, and the failure modes are venue-specific.
```

> **RULE: the fast path emits cancel-then-add. Never add-then-cancel. Never a replace.** The
> asymmetry is the point: (A) risks an unbounded double fill to save a bounded amount of
> queue time; (B) risks a bounded amount of queue time to eliminate an unbounded exposure.
> `q_ahead` ([09.01](01-queue-position-and-fill-probability.md) §4) prices the queue time
> given up — and prices it as small whenever the price is changing.

> **Verify:** whether a Nasdaq OUCH `Replace` preserves or loses time priority, and under
> exactly which conditions (price change, quantity increase, quantity *decrease*, display
> change), from the **Nasdaq OUCH 5.0 specification** and the **Nasdaq Equity Rulebook**
> ([08.03](../08-nasdaq/03-order-types-and-routing.md),
> [08.05](../08-nasdaq/05-ouch-5.0-order-entry.md)). A quantity reduction that preserves
> priority is the one case where replace may beat cancel-then-add — and it is a case the
> fast path does not need. Model replace as priority-lost until measured otherwise
> ([03.02](../03-algotrading/02-order-types-and-matching-engines.md) §10).

### 4.4 Arbitration: strict priority, and starvation is the feature

> **RULE: `tx_mux` is a strict-priority arbiter with cancel at grant 0.** Round-robin here
> is a bug, not a fairness improvement
> ([01.01](../01-fpga-design/01-rtl-design-patterns.md) §4).

Starving the new-order path during a burst of cancels is **exactly the desired behaviour**:
if we are cancelling in volume the market has moved and we do not want to be adding.
Starvation is bounded anyway — we hold at most `MAX_LIVE_ORDERS` cancellable orders.

⚠️ **Strict priority does not preempt a frame already in flight.** `tx_mux` is frame
granular: once the MAC has accepted the first beat of a new order, the cancel waits for
`tlast`. At 64-bit @ 156.25 MHz a ~74-byte frame is ~10 beats ≈ **64 ns** — 2.5× the *entire*
cancel-specific fabric budget, and the single largest jitter source on this path.

| Mitigation | Effect |
| --- | --- |
| **Single-issue TX**: no FIFO between encoder and MAC | Bounds head-of-line blocking to exactly one frame; already required by [04.05](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) §5 |
| Fixed, minimal fast-path frame length | Directly shortens the blocking window ([02.01](../02-networking/01-ethernet-phy-mac.md)) |
| ⚠️ **Never** add a TX FIFO "for throughput" | Each buffered frame is another ~64 ns of worst-case cancel delay, invisible in a p50 |

This window must appear as a distinct mode in `hist_cancel_w2w` (§5). If it does not, the
histogram is not sampling contended cases and the CI gate is measuring nothing.

### 4.5 Credit accounting

`rtl/fpga_top.sv` wires `credit_avail` from `u_order_gw` into `u_risk_gate` — the bound on
orders the FPGA may emit ahead of host accounting
([04.05](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) §9).

> **RULE: `credit_avail` gates new orders only. A cancel consumes no order credit and is
> never blocked by credit exhaustion.** Cancels reduce the very exposure credit exists to
> bound; spending credit on them is a category error.

⚠️ **Backwards, this is a trap.** If cancels drew on the same pool, a burst of quoting
exhausts credit exactly when the market is moving — and at that instant you can neither add
nor **pull**. Every resting quote is stranded at a stale price by the risk mechanism itself.
Same shape as the shared rate limiter ([08.05](../08-nasdaq/05-ouch-5.0-order-entry.md) §9)
and the shared kill gate (§4.1): one mistake in three costumes, all three with real
incidents behind them
([09-failure-modes-and-postmortems.md](09-failure-modes-and-postmortems.md)).

Cancels get a **separate** counter and a **separate**, generously sized token bucket whose
only jobs are duplicate suppression and staying inside the venue allowance. A non-zero
`cancel_bucket_block` is an incident, not a tuning opportunity.

### 4.6 Mass cancel is a slow-path escape hatch

| Mechanism | Latency class | Use |
| --- | --- | --- |
| Single targeted cancel (§4.1–4.2) | **~302 ns** | The pickoff race. The only fast-path tool |
| Walk the live-order table, one cancel per token | `N_live` × frame time + rate bucket | Kill armed, session teardown, feed loss |
| Venue mass-cancel / purge facility | Venue-dependent | ⚠️ **Verify** existence, scope and semantics on the OUCH port with **Nasdaq** |
| Cancel-on-disconnect | **Seconds** | Backstop only. ⚠️ **Verify** availability, opt-in status and scope; a transient blip destroys every queue position you own ([08.05](../08-nasdaq/05-ouch-5.0-order-entry.md) §10) |

> **RULE: mass cancel lives in a slow-path FSM that walks the live-order table. It is never
> reachable from a strategy signal and never appears in the latency budget.**

It answers a *systemic* condition — kill armed, session lost, host dead — never a per-symbol
price move. It is also the wrong tool for a pickoff: it consumes the whole message allowance
at the worst moment, and the order you actually needed to pull may be walked last.
**Measure and document its worst case**: at 64 live orders and ~80 ns per frame including
inter-frame gap, ~5.1 µs of wire time unthrottled — four orders of magnitude slower than the
targeted path.

---

## 5. Measuring the cancel path separately

⚠️ **A wire-to-wire loopback measurement of your entry path tells you nothing about your
cancel path.** Different logic, different critical paths, different fanout and placement,
and — crucially — different arbitration state. An entry-path number regressing tells you the
entry path regressed; an entry-path number *not* regressing tells you nothing at all.

> **RULE: two budgets, two histograms, two timestamp taps, two CI gates. The cancel-path
> budget is the one that must not regress.**

### 5.1 The start event is not the same event

The entry path starts at "a market data message arrived". The **cancel path starts at the
arrival, at our optic, of the message whose application to the book invalidated a resting
quote we own.** Almost no messages do that. Timestamping every RX SOF and pairing it with
the next TX frame measures a fiction.

| Tap | Start | Stop | Histogram | Isolates |
| --- | --- | --- | --- | --- |
| M0 | MD MAC RX SOF (`ts_in`, travels with the message) | `book_evt` applied | `hist_shared_prefix` | Rows shared by both paths |
| M1 | `book_evt` applied | `cancel_fire` (X0) | `hist_cancel_decide` | The trigger comparator |
| M2 | `cancel_fire` | Cancel first beat into MAC TX | `hist_cancel_encode` | X1–X3 + `tx_mux` blocking |
| **M3** | **`ts_in` of the invalidating message** | **OE MAC TX SOF of the cancel** | **`hist_cancel_w2w`** | **The headline cancel number** |
| M4 | `ord_req` valid | OE MAC TX SOF | `hist_entry_encode` | Entry path only |
| M5 | `ts_in` | OE MAC TX SOF of a new order | `hist_entry_w2w` | Entry path only |
| M6 | Cancel TX SOF | OUCH `Canceled` RX | `hist_cancel_ack_rtt` | Venue + network — not ours, but it says when the venue slows |

M3 − M0 − M1 is the cancel-specific cost; M3 versus M5 is this document's asymmetry,
measured rather than asserted. Bucket configuration and counter semantics per
[05.04](../05-optimization/04-measurement-and-profiling.md) §5 and
[06.03](../06-operations/03-monitoring-and-telemetry.md) §3.

```systemverilog
// rtl/telemetry/cancel_tap.sv — OBSERVER ONLY. 0 datapath cycles, never backpressures.
// Feeds one lat_hist instance dedicated to the cancel path.
module cancel_tap import trading_pkg::*; (
    input  var logic        clk, rst,
    input  var cycle_t      cycle_cnt,     // fpga_top free-running counter
    input  var logic        cancel_fire,   // X0 asserted for THIS book event
    input  var cycle_t      fire_ts_in,    // the ts_in that travelled WITH that message
    input  var logic        cancel_tx_sof, // first beat of the cancel frame into the MAC
    output var logic        s_valid,
    output var logic [23:0] s_delta        // cycles; the host converts to ns
);
    // Single-issue cancel path => exactly one measurement outstanding.
    // ⚠️ If this path is ever made multi-issue, this becomes a small FIFO keyed by slot,
    //    NOT a wider register. A register silently pairs the wrong two events and
    //    reports a latency LOWER than the truth. (05.04 §7)
    cycle_t pend_ts;  logic pend;
    always_ff @(posedge clk) begin
        if (rst)                pend <= 1'b0;
        else if (cancel_fire) begin pend <= 1'b1; pend_ts <= fire_ts_in; end
        else if (cancel_tx_sof) pend <= 1'b0;
        s_valid <= cancel_tx_sof & pend;
        s_delta <= 24'(cycle_cnt - pend_ts);   // unsigned subtract is wrap-safe
    end
endmodule
```

⚠️ **`cancel_fire` with no following `cancel_tx_sof` is a suppressed cancel** — stale
generation, dead slot, lost mux grant. Count it (`cancel_suppressed`, by reason). A
suppressed cancel never enters the histogram, so a design that silently drops cancels
displays a *beautiful* latency distribution.

### 5.2 CI gates

| Gate | Metric | Threshold | On breach |
| --- | --- | --- | --- |
| Entry path | Simulated wire-to-wire, uncontended | = budget, exactly | Fail build |
| **Cancel path** | Simulated wire-to-wire, uncontended | **= budget, exactly** | **Fail build** |
| **Cancel path** | Simulated, contended (new-order frame in flight) | ≤ budget + 10 cycles (§4.4) | **Fail build** |
| Cancel path | Hardware p99.9 over a replayed open | ≤ budget + 1 cycle | Fail release |
| Cancel path | Hardware max over a soak | ≤ budget + 10 cycles | Page |
| Either path | `cancel_stale_gen`, `cancel_bucket_block`, `cancel_suppressed` | **0** | Fail release |

Both paths are fixed-latency by construction, so p50 and max should be the *same number* in
an uncontended simulation. **Any spread is a bug being reported as a statistic.** Replay
methodology and the open fixture: [06.04](../06-operations/04-testing-strategy.md) and
[08-market-open-and-close-dynamics.md](08-market-open-and-close-dynamics.md); gating and
release rules: [06.01](../06-operations/01-build-and-release.md).

---

## 6. The cancel-path latency budget

Same shape as the `rtl/fpga_top.sv` header. Rows marked **shared** are the *same silicon* as
the entry path with identical cycle counts; a change there moves both paths.

```
  Stage                                      cyc      ns     cum ns   shared?
  ---------------------------------------- -----   -----   -------   -------
  Optics + GT RX PMA/PCS (hard IP)              -   ~90.0      90.0   shared
  MAC RX (cut-through)                          2    12.8     102.8   shared
  Ethernet/IPv4/UDP header strip                1     6.4     109.2   shared
  MoldUDP64 deframe + A/B arbitration           2    12.8     122.0   shared
  ITCH message assembly (to 512-bit beat)       2    12.8     134.8   shared
  ITCH decode (fixed-offset extraction)         1     6.4     141.2   shared
  Symbol filter + active-index map              1     6.4     147.6   shared
  Order-ID map lookup (BRAM + out reg)          2    12.8     160.4   shared
  Book level update + incremental top-of-book   2    12.8     173.2   shared, var*
  X0  Cancel trigger: my_state compare          1     6.4     179.6   CANCEL ONLY
  X1  Cancel gate: 4-check AND-reduce           1     6.4     186.0   CANCEL ONLY
  X2  cancel_tmpl read + seq/IP-ID cksum patch  1     6.4     192.4   CANCEL ONLY
  X3  SoupBinTCP/TCP framing + tx_mux grant     1     6.4     198.8   CANCEL ONLY
  MAC TX (cut-through)                          2    12.8     211.6   shared
  GT TX PCS/PMA + optics (hard IP)              -   ~90.0     301.6   shared
  ---------------------------------------- -----   -----   -------
  CANCEL FABRIC total                          19   121.6
  CANCEL WIRE-TO-WIRE target                    -       -    ~302
  entry path, same rows, for comparison        22   140.8    ~321
  DELTA, cancel vs entry                        3    19.2

  * The one variable-latency shared row. It is variable on BOTH paths, so its
    jitter is a CANCEL-path problem too (09.07).
```

- **Shared: 13 fabric cycles / 83.2 ns. Cancel-specific: 4 cycles / 25.6 ns.** MAC and GT
  are shared. So **~86 % of the cancel path is not cancel logic** — the highest-leverage
  cancel optimisation available is the *feed handler*, not the encoder
  ([05.01](../05-optimization/01-latency-budgeting.md)).
- **Contended worst case: +10 cycles (+64 ns) → ~366 ns**, from a new-order frame already in
  the MAC (§4.4). That, not 302 ns, is the number to race against §2.5.

⚠️ **A note on the `fpga_top.sv` header.** Its stage rows sum to **22 cycles / 140.8 ns**,
consistent with its own cumulative column (90.0 + 140.8 + 90.0 = 320.8), while its summary
line reads `FABRIC total 20 / 128.0`. **The rows and the cumulative column govern**; the
summary line is arithmetically stale. Reconcile it in the same commit that first measures
the path, per CLAUDE.md §3.

---

## 7. Rules for this project

1. **Cancel latency outranks entry latency.** Given 20 ns on either, take the cancel, every time.
2. **The cancel path is a separate datapath** from book event to `tx_mux`: own trigger, own gate, own template memory, own budget rows X0–X3, own histogram.
3. **The only last look in US equities is a cancel that arrives first.** Design as though there is no other protection, because there is none.
4. **The cancel gate keeps only the physically and protocol-necessary checks** and drops every check that exists to prevent adding exposure — including `book_stale`, halt state and parameter freshness.
5. **The kill switch never blocks a cancel.** `kill_active` gates `order_out_valid` only; assert the dual property that it does *not* gate `cancel_out_valid`.
6. **Cancels consume no order credit and share no token bucket with orders.** Separate pool, separate counter, sized never to bind.
7. **`tx_mux` is strict priority with cancel at grant 0.** Starving new orders is intended. No TX FIFO, ever.
8. **Cancel templates are per-slot with the token pre-spliced, written at `Accepted`**, and every one is guarded by a generation counter plus a live bit. `cancel_stale_gen` is zero forever.
9. **A slot retires on a terminal venue message, never on cancel transmission.** `PENDING_CANCEL → FILLED` is reachable.
10. **Cancel-then-add on the fast path. Never add-then-cancel. Never replace.** Replace is a measured, slow-path option only.
11. **Mass cancel is a slow-path FSM** answering systemic conditions, with a documented, measured worst case. Never a fast-path tool.
12. **The cancel path is budgeted, measured and CI-gated independently** — uncontended *and* contended — and it is the budget that must not regress.
13. **Report p99.9, not p50.** §2.6 is the reason; it is not a stylistic preference.
14. **Every competitor latency figure here is ILLUSTRATIVE** until replaced by a dated, sourced measurement.

---

## Further reading

- [../03-algotrading/01-market-microstructure.md](../03-algotrading/01-market-microstructure.md) — §5, the picked-off scenario this formalises
- [../03-algotrading/02-order-types-and-matching-engines.md](../03-algotrading/02-order-types-and-matching-engines.md) — §8 the cancel race, §9 `PENDING_CANCEL → FILLED`
- [../03-algotrading/05-strategy-taxonomy.md](../03-algotrading/05-strategy-taxonomy.md) — which races are fabric races and which are telecoms races
- [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md) — §8, the kill-switch/cancel rule
- [../04-system-architecture/01-tick-to-trade-pipeline.md](../04-system-architecture/01-tick-to-trade-pipeline.md) — the shared prefix that dominates §6
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — the gate, templates, credit mechanism, rows T0–T6
- [../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) — strict-priority arbiters, and why round-robin is wrong here
- [../02-networking/01-ethernet-phy-mac.md](../02-networking/01-ethernet-phy-mac.md) — frame time, the §4.4 blocking window
- [../02-networking/04-nics-kernel-bypass-and-switching.md](../02-networking/04-nics-kernel-bypass-and-switching.md) — the switch hops that undo all of this
- [../05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md) — how to defend the §6 rows
- [../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md) — timestamp taps and histogram methodology
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) — counter and histogram semantics for §5
- [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md) — the contended-cancel testbench and replay fixtures
- [../07-reference/02-latency-reference-numbers.md](../07-reference/02-latency-reference-numbers.md) — the anchors §2.5 must not contradict
- [../08-nasdaq/05-ouch-5.0-order-entry.md](../08-nasdaq/05-ouch-5.0-order-entry.md) — §8 cancel path, §9 rate limits, §10 cancel-on-disconnect
- [../08-nasdaq/08-connectivity-and-colocation.md](../08-nasdaq/08-connectivity-and-colocation.md) — standardized cable lengths, the §2.3 claim
- [../08-nasdaq/09-risk-controls-and-limits.md](../08-nasdaq/09-risk-controls-and-limits.md) — the limit set the cancel gate subsets
- [01-queue-position-and-fill-probability.md](01-queue-position-and-fill-probability.md) — §5.1, the bounded-upside/fat-tail asymmetry
- [02-adverse-selection-and-toxicity.md](02-adverse-selection-and-toxicity.md) — what a lost race costs, measured
- [07-jitter-sources-and-determinism.md](07-jitter-sources-and-determinism.md) — why §2.6 makes p99.9 the metric
- [09-failure-modes-and-postmortems.md](09-failure-modes-and-postmortems.md) — the shared-gate family of incidents in §4.5
