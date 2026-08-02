# 09.01 — Queue Position and Fill Probability

> **Why this matters here:** queue position is the only place in this system where a nanosecond converts
> into a dollar by a mechanism you can write down. Everything else latency buys — less pickoff, faster
> reaction — is a hedge. Being first in a FIFO is *revenue*, and it is why the budget in
> `rtl/fpga_top.sv` is denominated in nanoseconds. This document prices that slot, gives the hardware
> algorithm that estimates where we sit in it, and states what that algorithm may cost.
> [03.01](../03-algotrading/01-market-microstructure.md) §2 and
> [08.07](../08-nasdaq/07-fees-rebates-and-economics.md) §2 introduce queue position — read those first.

---
## 1. A queue slot is a short option, and position is its strike

A resting displayed bid grants every participant a free option to sell you shares at your price. FIFO
position does not change the option's terms — only **how likely you are to be assigned when it is
exercised**.

```
EV(quote) = P(fill | A, Q, flow) × E[ value of a fill | filled ]
E[value | filled] =  rebate/share  +  effective half-spread captured
                   − adverse selection given fill  −  fees/clearing/regulatory
```

The second factor is the trap. **A fill is conditionally informative**: you are filled precisely when
somebody decided trading against your price was worth doing. The distribution of the next move
*conditional on having just been filled* is not the unconditional one, and it leans away from you.

| Term | Sensitive to queue position? | How |
| --- | --- | --- |
| Rebate / share | No | Schedule + tier only ([08.07](../08-nasdaq/07-fees-rebates-and-economics.md) §3) |
| Effective half-spread | Weakly | Front fills happen at the touch; deep fills happen after the touch has been chewed on |
| **P(fill)** | **Strongly, convexly** | §2 |
| **Adverse selection given fill** | **Strongly, wrong direction** | below |
| Fees, Section 31, TAF, clearing | No | Fixed per share |

**The back of the queue is punished twice.** To reach an order behind `A` shares the market must push
`A` shares of aggressive flow through that price, and large one-directional flow is disproportionately
informed. Front fills come from the odd lot; back fills come only after thousands of shares of
someone's conviction cleared everything ahead of you. Both factors therefore **decline together**, and
their product is far more convex than either alone. Toxicity conditional on rank is
[02-adverse-selection-and-toxicity.md](02-adverse-selection-and-toxicity.md).

---
## 2. The queue as a depletion process

### 2.1 The five-way race

| # | Event | Effect on you | Effect on `ahead` |
| --- | --- | --- | --- |
| (a) | Aggressive flow executes from the front | Promotes you, then fills you | `−= exec_shares` |
| (b) | Someone **ahead** cancels/deletes | **Free promotion.** Best thing that can happen to a resting order | `−= cancelled_shares` |
| (c) | Someone **behind** cancels/deletes | Irrelevant to your rank; relevant to the level's survival | none |
| (d) | Price moves **away** (a better price appears) | You never fill; the option expires worthless — which is fine | frozen |
| (e) | Price moves **through** you (level exhausted, market continues) | You fill, and the market keeps going against you | → 0, badly |

(a) and (b) are the product. (d) is a non-event. (e) is what you are paid to avoid —
[03-cancel-latency-and-pickoff.md](03-cancel-latency-and-pickoff.md).

### 2.2 A tractable model, with its assumptions on the table

**Assumptions, all wrong in interesting ways, listed so you know where:** aggressive volume is Poisson
at `μ_x` shares/s consuming strictly from the front; cancels are Poisson at `μ_c`, a fraction `φ` of
them ahead of you, so front-depletion runs at `d = μ_x + φ·μ_c`; the level's lifetime is exponential
with hazard `λ`; `ahead` decays as a fluid, not in jumps; no hidden, reserve or pegged interest exists;
you never cancel.

```
Time to reach the front = A/d ;  P(fill) = P(level outlives that) = exp(−λ·A/d)
  queue reach R = d/λ  ← shares consumed from the front over a level lifetime
  turnover    κ = R/Q  ← relative to level depth Q
  rel. pos.   a = A/Q  ← 0 at the front, 1 at the back
                         P(fill) = exp(−A/R) = exp(−a/κ)
```

> **ILLUSTRATIVE model outputs** below, from that closed form — *not* measured venue statistics. Their
> only job is the shape. Calibrate `R` per symbol and per time-of-day bucket from your own fill logs
> (§7) before this touches a sizing decision.

| `a = A/Q` | κ = 2.0 (heavy turnover) | κ = 1.0 (balanced) | κ = 0.4 (cancel-dominated) | κ = 0.15 (fleeting level) |
| --- | ---: | ---: | ---: | ---: |
| 0.00 — front | 1.00 * | 1.00 * | 1.00 * | 1.00 * |
| 0.10 | 0.95 | 0.90 | 0.78 | 0.51 |
| 0.25 | 0.88 | 0.78 | 0.54 | 0.19 |
| 0.50 | 0.78 | 0.61 | 0.29 | 0.036 |
| 0.75 | 0.69 | 0.47 | 0.15 | 0.007 |
| 1.00 — back | 0.61 | 0.37 | 0.08 | 0.001 |

`*` ⚠️ The `a = 0` row reads 1.00 only because the fluid approximation ignores the discreteness of the
first trade; a front-of-queue order still misses if the level dies with zero executions
(`μ_x/(μ_x+λ) < 1`). **Upper bound, not a guarantee.**

- **Exponential in absolute shares ahead, not in rank.** 5,000 versus 4,800 ahead is nothing; 200
  versus 0 is the business — the convexity claim of [03.01](../03-algotrading/01-market-microstructure.md) §2, made explicit.
- **`dP/dA = −P/R`** — the marginal value of one share of promotion scales with the fill probability
  you already have. **Latency compounds with itself.**
- **Low-κ regimes annihilate deep queue value.** At κ = 0.15, past halfway is indistinguishable from
  not quoting.

---
## 3. Estimating `ahead` from an order-based feed

### 3.1 Why ITCH permits this and a level-aggregated feed does not

| Feed shape | What arrives | Can you count shares ahead of your order? |
| --- | --- | --- |
| **Order-based (MBO/L3)** — TotalView-ITCH | Every `A`/`F` Add, `E`/`C` Execute, `X` Cancel, `D` Delete, `U` Replace, each with an **order reference** | **Yes.** Every share leaving the level is attributable to a named order, so ahead-vs-behind is decidable |
| **Level-aggregated (MBP/L2)** | "bid level 1 is now 4,700 @ 190.85" | **No.** 5,000 → 4,700 could be a front fill, a cancel behind you, or both. No decomposition exists |
| **Top-of-book (L1)** | Best bid/ask and size | Not even the depth history |

> **Verify:** the message catalogue, the order reference on each of `A`/`F`/`E`/`C`/`X`/`D`/`U`, and
> all field widths, from the **Nasdaq TotalView-ITCH 5.0 specification**. Decode detail in
> [08.04](../08-nasdaq/04-totalview-itch-5.0.md).

**This is the whole justification for reconstructing an order-based book in hardware**
([04.03](../04-system-architecture/03-order-book-in-hardware.md)). The order map does not exist to
produce a prettier book — a level-aggregated book is cheaper and yields the same top-of-book. It
exists so this estimator can exist.

### 3.2 Initialisation, and the direction of its error

```
On the OUCH Accepted for our own order:
    ahead₀    ← level_qty[sym][side][level]  as of the LAST book event we applied
    seq₀      ← that event's sequence number     (bounds the error window)
    my_ticket ← §4 ;  est_valid ← 1
```

⚠️ **`ahead₀` is not a fact.** Between our TX MAC and the venue's sequencer, the venue processed events
we had not seen and we processed events already sequenced ahead of ours; the error is the net level
change over that window. **And the bias has a known sign:** that window is almost always a *race* — a
level just formed, or the touch moved, and everyone reacts at once. Reaction windows are dominated by
**adds**, not cancels, so orders sequenced ahead of ours are shares we never counted.

> **RULE: `q̂_ahead` is a systematically optimistic lower bound on true shares ahead.** Never a hard
> condition — a soft input to sizing and fading, sized as if the truth is worse. This puts a sign on
> the warning in [04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §8.

⚠️ The OUCH `Accepted` carries the **actual resting price**, which differs from what we sent if the
order was price-slid. On `accepted_price != sent_price` the estimate is anchored to the wrong level and
must be **discarded, not adjusted** ([08.05](../08-nasdaq/05-ouch-5.0-order-entry.md)).

### 3.3 Collapsing the error: find your own Add in the feed

Our displayed order appears in TotalView as an `A` (or `F`) like anyone else's. **The instant we see it
the estimate stops being an estimate** — the level quantity immediately before that message is exactly
the shares ahead of us.

| Approach | Identification | Residual error |
| --- | --- | --- |
| **Attributed quoting (`F`, our MPID)** | Exact | None, except hidden interest |
| **Heuristic match on unattributed `A`** | `(sym, side, price, shares)` inside the expected round-trip window | Ambiguous when another firm posts an identical order in the same window — i.e. precisely during a race |
| **No self-identification** | — | Full §3.2 error, permanently |

> **RULE: on symbols where queue position drives the P&L, quote attributed.** It turns an estimate into
> a measurement and makes the estimator's error auditable rather than assumed; accept the information
> leakage deliberately, per symbol, as a parameter. **Verify:** whether MPID attribution is a per-order
> flag or a per-port setting, and its cost, from the **Nasdaq OUCH 5.0 specification** and the **Nasdaq
> Equity Rulebook** ([08.03](../08-nasdaq/03-order-types-and-routing.md)).

### 3.4 Per-event update rules

For every event at `(our sym, our side, our level)` while `est_valid`:

| ITCH | Level semantics | Effect on `ahead` | Note |
| --- | --- | --- | --- |
| `A` / `F` Add | New order joins | **none** | Behind us by construction |
| `E` Order Executed | Named order loses shares | `−= exec_shares` if ahead | Ref given; no guessing |
| `C` Executed with Price | Same book effect as `E` | as `E` | ⚠️ the execution price is **not** the resting price — never locate the level with it |
| `X` Order Cancel | Named order shrinks | `−= cancelled_shares` if ahead | The ambiguity — §3.5 |
| `D` Order Delete | Named order removed | `−= remaining_qty` if ahead | The ambiguity — §3.5 |
| `U` Order Replace | Delete old ref, **insert new ref at the tail** | `−= old_remaining_qty` if the old was ahead; the new contributes **nothing** ahead | ⚠️ a replace ahead of us is a **full-size free promotion** |
| Our own fill | — | terminate, log | §3.6 |

⚠️ **`U` is the most commonly mis-implemented case.** A replace is not a quantity modification; it is a
delete plus a fresh arrival at the tail. Treating it as a resize loses a large, systematic source of
promotion.

⚠️ **An execution of an order we believe is *behind* us is evidence of a bug or of hidden liquidity**
(non-displayed interest at the same price, minimum-quantity skips, self-match prevention). It is never
normal. Count it (`qpos_exec_behind`) and treat a rising count as an invalidated model, not a curiosity.

### 3.5 The ahead-or-behind problem, and the two solutions

A cancel gives you the order reference. It does **not** say which side of you that order sat on.

| | (a) Per-order arrival ordinal | (b) Uniform approximation: `ahead −= qty × ahead/Q` |
| --- | --- | --- |
| Correctness | Exact for displayed interest | Right on average, wrong on every individual level |
| When cancels are non-uniform | — | **Always, in the cases that matter.** A queue's front is stable — it is valuable and nobody abandons it. The back is where the flickering, opportunistic, latency-sensitive orders live. Cancel intensity is strongly skewed to the back |
| Resulting bias | none | Over-credits promotion — thinks you are further forward than you are, **same sign as the §3.2 bias** |
| Cost | A ticket field in the order-map entry (§4) | Zero storage; a multiply and a divide |
| Verdict | **Chosen, for quoted symbols** | **Rejected** |

**Why (b) is rejected** is not that it is inaccurate on average. Its error is largest in exactly the
regime the strategy exists to trade — a deep tick-constrained level with a churning back and a stable
front — and it carries the *same sign* as the initialisation bias. Two optimistic estimators in series
produce a `q̂` claiming "near the front" precisely when you are not, and a strategy sizing on that
over-quotes into adversely-selected fills.

> **RULE: implement (a), and only for symbols we actually quote.** An arrival ticket for every order in
> the universe is affordable (§4); *estimator state* per order is not, and is unnecessary — we hold at
> most one resting order per side per symbol.

### 3.6 Reset conditions

`est_valid` clears — and the strategy falls back to "assume no queue value" — on:

| Condition | Why | Recovery |
| --- | --- | --- |
| Our order fills (full or partial) | `ahead` is 0 by definition | `ahead = 0`; keep validity for the residual |
| We cancel or replace | The order is gone, or has gone to the tail | Clear; re-init on the new Accepted |
| `book_stale` (gap) or order-map epoch change | We missed events; every later decrement is unsound | Clear. Do **not** patch. Re-init after resync |
| Level price is not where we think (slide, stale view) | Anchored to the wrong index | Clear |
| Ticket wrap for the symbol (§4) | Comparisons become meaningless | Clear all estimators for that symbol |
| `qpos_exec_behind` fires on our level | Model contradicted by observation | Clear, count, escalate to the host |

⚠️ **A stale estimate is worse than none.** "50 shares from the front" when the truth is 4,000 makes the
strategy hold a quote it should have pulled. Failing closed costs a quote; failing open costs a fill you
did not want.

---
## 4. The hardware cost, and the design that makes it cheap

### 4.1 A monotonic per-symbol arrival ticket

A true ordinal rank — "how many orders at this level arrived before order X" — is an order-statistic
query over a dynamic set. In fabric that is a per-level linked list (pointer chasing in BRAM, one cycle
per hop, unbounded — rejected for the same reason the book rejects linked lists) or a counter tree
(large, touched on every add anywhere). Both wrong, and both unnecessary: **we never need a rank, we
need one bit — *is this order ahead of mine?*** Within a level, arrival order is a subsequence of the
per-symbol arrival order, so a **per-symbol** counter suffices, collapsing the structure from
`N_ACTIVE × N_LVL` to `N_ACTIVE`:

```
next_ticket[sym]              one counter per active symbol
on every Add for sym:         ticket ← next_ticket[sym]++, stored in the order-map
                              entry beside {slot, side, level, qty}
"is order X ahead of mine?"  ⇔  ticket_X < my_ticket        ← ONE comparison
```

The order-map entry is **already read** at book stage B1 to apply the event
([04.03](../04-system-architecture/03-order-book-in-hardware.md) §11), so the ticket rides along in that
read: no second lookup, no second structure, no extra stage.

```systemverilog
// rtl/strategy/queue_pos.sv — STRATEGY STATE, NOT A TRIGGER INPUT. Consumes the same
// book_evt_t as the book engine ONE STAGE LATER; output read on the NEXT event. 0 budget rows.
// Ports elided: {clk, rst, evt, evt_valid, evt_ticket (order-map entry @B1), evt_hit,
// own_sym, own_side} -> q_ahead. qrec[sym][side] = {valid, my_ticket, my_price, ahead, Q0}.
    logic [TICKET_W-1:0] next_ticket [N_ACTIVE];            // LUTRAM / 1 BRAM36
    qrec_t               qrec        [N_ACTIVE][2];         // my_price is the LEVEL

    wire same_level = qrec[evt.sym][evt.side].valid
                   && (evt.price == qrec[evt.sym][evt.side].my_price);
    // The whole trick: ONE comparison decides ahead-vs-behind.
    wire is_ahead   = evt_hit && (evt_ticket < qrec[evt.sym][evt.side].my_ticket);
    // ⚠️ REPLACE = delete-old + tail-insert: the old order's FULL remaining qty leaves the
    // space ahead of us, the new order adds nothing ahead. Never model it as a resize.
    wire depletes   = evt.op inside {BOOK_EXEC, BOOK_CANCEL, BOOK_DELETE, BOOK_REPLACE};
    wire allocates  = evt.op inside {BOOK_ADD,  BOOK_REPLACE};   // adds land behind us

    always_ff @(posedge clk) begin
        if (rst) for (int s = 0; s < N_ACTIVE; s++) next_ticket[s] <= '0;
        else if (evt_valid) begin
            if (allocates) next_ticket[evt.sym] <= next_ticket[evt.sym] + 1'b1;
            if (depletes && same_level && is_ahead)          // saturating — see below
                qrec[evt.sym][evt.side].ahead <= qty_t'(sat_sub64(
                    64'(qrec[evt.sym][evt.side].ahead), 64'(evt.qty)));
        end
    end
```

⚠️ `sat_sub64` (`rtl/pkg/trading_pkg.sv`) is mandatory, not stylistic. A wrapped `ahead` reads as
billions of shares ahead and silently disables quoting for that symbol for the rest of the day, with no
error reported anywhere.

> **RULE: the queue-position estimator is never on the trigger path.** It runs one stage behind the book
> engine and writes strategy state read on the **next** event — zero rows in the budget in
> `rtl/fpga_top.sv`. A change making the trigger depend on a `q_ahead` computed from *this* tick is
> rejected on principle: `q_ahead` feeds sizing and fading, whose value changes over milliseconds, while
> the trigger path is a race decided in nanoseconds ([05.01](../05-optimization/01-latency-budgeting.md)).

### 4.2 Sizing

| Item | Sizing | Cost |
| --- | --- | --- |
| `TICKET_W` | **32 bits** | Wrap after 2³² adds *for one symbol in one session* — unreachable. 24 bits (~16.7 M) is marginal for a heavily quoted name; 16 bits is not viable |
| `next_ticket[N_ACTIVE]` | 256 × 32 b = 8.2 Kbit | LUTRAM, or 1 BRAM36 |
| Order-map entry growth | 128 b → 160 b; 65,536 × 160 b = 10.5 Mbit (was 8.39) | **~40 URAM288, up from 32.** The ticket is the only new field |
| `qrec[N_ACTIVE][2]` | 256 × 2 × ~120 b ≈ 61 Kbit | 2 BRAM36, or folded into the existing `my_state` array |
| `ahead` width | `QTY_W` = 32, saturating | Matches the level array's `aggregate_qty`; narrower re-introduces the wrap bug |
| **Added pipeline stages** | **0** | Runs in parallel with B4, one stage behind the book RMW |
| Added logic | ~400 LUT / ~600 FF (estimate, pre-synthesis) | One comparator, one saturating subtract, address decode |

> **Verify:** URAM288 geometry (4096 × 72 b) and per-device URAM/BRAM counts from the **AMD UltraScale+
> device datasheet and Memory Resources user guide** — the 32 → 40 URAM step depends on packing
> granularity, so read it off the synthesis report, never off this table. Verify `N_ACTIVE`,
> `ORDER_MAP_ENTRIES` and `QTY_W` against `rtl/pkg/trading_pkg.sv`; that file is the contract.

---
## 5. The decay of queue value

Queue position is worth the most the instant you acquire it, and never more.

| Driver | `P(fill)` | Conditional value of the fill | Net |
| --- | --- | --- | --- |
| Level consumed from the front; we advance | **Up** | Slightly worse — sustained flow correlates with information | **Good** |
| Someone ahead cancels — free promotion | **Up** | Unchanged | **Best case** |
| Others queue **behind** us | Indirect: better-supported level ⇒ `λ` falls, `R` rises | Unchanged | **Good** |
| The level **thins** behind us | `λ` rises, `R` falls | Worse — remaining flow is more selective | **Bad** |
| Time passes with no executions | Unchanged | **Worse** — information accrues, our price ages | **Bad. Queue value has a half-life** |
| Fair value moves **against** our price | **Up sharply** | **Strongly negative** | **Worst case: the pickoff** |

The last row is the one to internalise: **the moments when fill probability spikes are the moments you
least want the fill.** `P(fill)` and `E[value|fill]` are negatively correlated exactly when it matters,
which is why maximising fill rate is not, and never was, a strategy objective.

**The join-early / cancel-late asymmetry.** Joining a level early is worth at most one half-spread plus
a rebate, realised with probability `P(fill) < 1` — *bounded*. Failing to cancel in time costs the full
adverse move on the full quote size, with no cap — *unbounded on the tail*. So:

> **RULE: the cancel path has strict priority over the new-order path in every arbiter, and the risk
> gate must never queue a cancel behind a new order**
> ([04.05](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md),
> [03-cancel-latency-and-pickoff.md](03-cancel-latency-and-pickoff.md)).

> **RULE: never replace a resting order to improve its price without pricing the queue position burned.**
> A replace sends you to the tail of the new level ([08.05](../08-nasdaq/05-ouch-5.0-order-entry.md));
> `q_ahead` is exactly the input that prices that trade — the estimator's highest-value use.

---
## 6. Why this is the clearest quantitative case for latency spend

When a new price level forms, `N` participants react. Their reaction times have density `f(τ)` around
our latency `τ`, and orders reach the sequencer in reaction-time order:

```
Competitors ahead of us ≈ N·F(τ) ;  removed by shaving Δ ≈ N·f(τ)·Δ
Shares removed from ahead of us  ΔA = N·f(τ)·Δ·s        (s = mean competitor size)
From §2:  ΔP(fill) = (P/R)·ΔA   ⇒   Δ EV/quote = ΔP × quote_size × E[value | fill]
```

> Every input below is a **placeholder to be replaced with a measurement**. The arithmetic is the
> deliverable; the number is not.

```
ILLUSTRATIVE — derived here, not measured

  Competitor density near our latency N·f  1 per 100 ns   Level depth  Q  3,000 sh
  Mean competitor order size            s  200 shares     Queue reach  R  4,000 sh
  Latency improvement Δ = 100 ns  ⇒  ΔA =  200 shares     Our position A  1,500 sh

    P(fill) = exp(−1500/4000) = 0.687 ;  dP/dA = P/R = 1.72e−4 /share
    ΔP      = 1.72e−4 × 200   = +0.034  (3.4 percentage points)

  Quote 300 sh × net $0.0015/sh given fill (from 08.07 §6, MEASURED)
    ⇒ Δ EV per race $0.0155 ; races/session ≈ 256 symbols × 780 (one per 30 s) = 200,000
    ⇒ Δ EV/session ~$3,100 ; Δ EV/year (252) ~$780,000 ; PER ns PER YEAR ~$7,800
```

> **Verify:** the number of US equity sessions per year from the **Nasdaq trading calendar**. The
> per-share net value must come from your own realised P&L decomposition per
> [08.07](../08-nasdaq/07-fees-rebates-and-economics.md) §6 — never from a quoted-spread assumption.

**The decision rule.** If the fully-loaded annual cost of the hardware programme is `C` — card, colo,
cross-connects, ports, data, engineers, the full stack in
[08.07](../08-nasdaq/07-fees-rebates-and-economics.md) §5 — the improvement that pays for it is
`C / 7,800` nanoseconds, with the per-nanosecond figure recomputed from *your* measurements. That is a
number you can put in front of a risk committee, and it is the only latency argument in this repository
that produces one.

⚠️ Every input is multiplicative: a 2× error in one is a 2× error in the conclusion, and three
optimistic inputs compound to 8×. Run pessimistic / base / optimistic, exactly as
[08.07](../08-nasdaq/07-fees-rebates-and-economics.md) §7 requires. Note too that the elasticity is
**not constant** — from `dP/dA = −P/R`, the same 200 shares of improvement is worth (ILLUSTRATIVE,
R = 4,000) `+0.050` at `A = 0`, `+0.034` at `A = 1,500`, `+0.018` at `A = 4,000`, `+0.0025` at
`A = 12,000`. **Speed is a complement to speed:** if you are already slow enough to land 12,000 deep,
100 ns changes nothing — you need a different order of magnitude, or a different symbol.

### 6.1 Decision table: symbol regime → what latency buys

| Regime | Book shape | What latency buys | Priority here |
| --- | --- | --- | --- |
| **Tick-constrained, deep queue** — high-volume large-cap, spread pinned at one tick, `Q` in the thousands | Long queues; spread never widens | **Queue rank on level creation, plus cancel-before-pickoff. Queue position IS the strategy** — you cannot outbid, there is nowhere to go | **Primary target. Highest elasticity** |
| **Tick-constrained, moderate queue** | Queues of a few hundred | Mixed queue rank and pickoff avoidance; elasticity real but lower | Secondary |
| **Wide spread, thin queue** — high-priced name, spread many ticks | Few orders per level; spread flickers | **Not queue position** — stepping in front costs one tick, so priority is cheap. Latency buys *taking* edge and cancel speed | Different primitive — [03.05](../03-algotrading/05-strategy-taxonomy.md) |
| **Illiquid / very wide** | Levels persist for seconds | Almost nothing passively; the edge is pricing, not speed | Not a target |
| **Inverted venue** — short queues by construction | Everyone is near the front already | Less queue value, more adverse fill mix | Evaluate separately — [08.07](../08-nasdaq/07-fees-rebates-and-economics.md) §2 |

> **RULE: universe selection is tick-aware and elasticity-aware.** Quoting a wide-spread name with a
> queue-position strategy spends the hardware's entire advantage on a mechanism that does not bind
> there — [03.01](../03-algotrading/01-market-microstructure.md) §7 restated as capital allocation.

---
## 7. Measuring it: validating the model in production

One free parameter per symbol per regime (`R`), calibrated rather than assumed, from data that trading
produces anyway. The log record is emitted on the DMA log ring at entry and at terminal state — **off
the fast path** ([04.06](../04-system-architecture/06-cpu-fpga-partitioning.md)).

| Field | When | Why |
| --- | --- | --- |
| `token`, `sym`, `side`, `price` | entry | Join key to host order state |
| `q_ahead_est` (`q̂`), `depth_at_entry` (`Q₀`) | entry | The prediction under test, and the denominator for `a = q̂/Q₀` |
| `book_seq_at_entry` | entry | Bounds the §3.2 error window |
| `est_source` ∈ {accept-latched, self-Add-observed, attributed} | entry | The §3.3 quality tier. **Never pool these** |
| `outcome` ∈ {filled, partial, our-cancel, level-died} | terminal | The label |
| `time_to_outcome`, `shares_consumed_ahead` | terminal | Fit `λ` and `d` ⇒ `R = d/λ` |
| `mid_at_fill`, `mid_at_fill+Δ` (Δ = 1 s, 5 s, 30 s) | terminal | The conditional value term ([08.07](../08-nasdaq/07-fees-rebates-and-economics.md) §6) |

### 7.1 Counters required in `telemetry`

Semantics per [06.03](../06-operations/03-monitoring-and-telemetry.md) §2.

| Counter | Width | Semantics | Why it exists |
| --- | --- | --- | --- |
| `qpos_est_hist[b]` | 32 × 16 | Free-running | `q̂` at entry, log₂-bucketed — the prior |
| `qpos_fill_hist[b]` | 32 × 16 | Free-running | Fills in the same buckets. Ratio ⇒ empirical `P(fill \| q̂)` |
| `qpos_reset_reason[r]` | 32 × 8 | Free-running | One per §3.6 condition — *why* the estimator is unavailable |
| `qpos_clamp_zero` | 32 | Free-running | `q̂` reached 0 and we did **not** fill. **Direct proof of the §3.2/§3.5 optimistic bias.** The most valuable counter here |
| `qpos_fill_with_ahead` | 32 | Free-running | We filled while `q̂ > 0` — over-estimation, or hidden interest |
| `qpos_exec_behind` | 32 | Sticky + count | An order believed behind us executed. Model contradicted (§3.4) |
| `qpos_ticket_wrap` | 16 | Sticky + count | Must be zero forever at `TICKET_W = 32`. Non-zero ⇒ sizing error |
| `qpos_est_valid_frac` | 16 | Live | Fraction of resting time with a usable estimate. Low ⇒ the mechanism is decorative |

`qpos_clamp_zero` and `qpos_fill_with_ahead` are a matched pair bracketing the estimator's error **in
production, without a backtest**. `clamp_zero` alone ⇒ optimistic (expected). Both large ⇒ noisy rather
than biased, and the fix differs.

### 7.2 Building the empirical curve

```python
# host/analysis/queue_curve.py — slow path, offline.  log P(fill) = -A/R, so R = -1/slope
import numpy as np, pandas as pd
df = pd.read_parquet("quote_log.parquet")
df = df[df.est_source == "attributed"]              # never pool estimate qualities
df["filled"] = df.outcome == "filled"
fits = {}
for sym, g in df.groupby("symbol"):
    e = (g.groupby(pd.cut(g.q_ahead_est, 12)).filled
          .agg(["mean", "size"]).query("size >= 200 and mean > 0.01"))
    A = np.array([iv.mid for iv in e.index])
    fits[sym] = -1.0 / np.polyfit(A, np.log(e["mean"]), 1)[0]      # = R
```

`R` is written back as a per-symbol strategy parameter under the same double-buffered commit discipline
as every other ([04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §3, §5).

⚠️ **The curve is survivorship-biased by your own cancels.** Every `our-cancel` is a *censored*
observation, not a failure to fill; counting them as no-fills understates `P(fill)` in exactly the
buckets the strategy lives in. Use a survival estimator, or restrict the fit to never-cancelled orders —
and say which.

⚠️ If the curve does not bend the way §2 predicts, **the model is wrong, not the market.** The usual
cause is pooling: mixing symbols, times of day (the open is a different world —
[08-market-open-and-close-dynamics.md](08-market-open-and-close-dynamics.md)) and estimate-quality tiers
into one curve yields a flat, straight, useless line.

---
## 8. Rules for this project

1. **The estimator is never on the trigger path.** Zero latency-budget rows; strategy state, consumed on the next tick.
2. **`q̂_ahead` is an optimistic lower bound, never a fact.** Soft input to sizing and fading only.
3. **Ahead-vs-behind is resolved by a per-symbol monotonic arrival ticket** in the order-map entry — one comparison. The uniform approximation is rejected.
4. **The estimator fails closed.** On gap, resync, slide, wrap or contradiction: clear `est_valid` and quote as if there is no queue value.
5. **All `ahead` arithmetic saturates** — `sat_sub64` from `trading_pkg`, always.
6. **`U` Replace is delete-plus-tail-insert** in the estimator exactly as in the book engine. A replace ahead of us is a full-size free promotion.
7. **Quote attributed where queue position drives P&L**, as an explicit per-symbol parameter, to turn the estimate into a measurement.
8. **Cancel beats quote in every arbiter and every risk-gate queue.** Bounded upside against a fat-tailed downside is not a close call.
9. **Never replace to improve price without pricing the queue position burned**, and select the universe by elasticity — tick-constrained, deep-queue names only for this primitive.
10. **`R` is calibrated from production fills**, per symbol and per time-of-day bucket. Every `P(fill)` figure here is ILLUSTRATIVE until measured.
11. **`qpos_clamp_zero` and `qpos_fill_with_ahead` are reviewed daily.** They are the estimator's error bars and they are free.

---
## Further reading

- [../03-algotrading/01-market-microstructure.md](../03-algotrading/01-market-microstructure.md) — price-time priority, tick regimes, what queue position *is*
- [../03-algotrading/02-order-types-and-matching-engines.md](../03-algotrading/02-order-types-and-matching-engines.md) — how priority is assigned and lost
- [../03-algotrading/05-strategy-taxonomy.md](../03-algotrading/05-strategy-taxonomy.md) — which strategies queue position is load-bearing for
- [../04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md) — the order map that makes the ticket free
- [../04-system-architecture/04-strategy-engine-on-fpga.md](../04-system-architecture/04-strategy-engine-on-fpga.md) — `my_state`, where `queue_ahead` lives
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — cancel-over-quote arbitration
- [../05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md) — where the nanoseconds priced here are spent
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) — counter semantics for §7.1
- [../08-nasdaq/04-totalview-itch-5.0.md](../08-nasdaq/04-totalview-itch-5.0.md) — the order-based feed this depends on
- [../08-nasdaq/05-ouch-5.0-order-entry.md](../08-nasdaq/05-ouch-5.0-order-entry.md) — Accepted, price sliding, replace semantics
- [../08-nasdaq/07-fees-rebates-and-economics.md](../08-nasdaq/07-fees-rebates-and-economics.md) — the P&L decomposition supplying `E[value | fill]`
- [02-adverse-selection-and-toxicity.md](02-adverse-selection-and-toxicity.md) — the other half of `EV(quote)`
- [03-cancel-latency-and-pickoff.md](03-cancel-latency-and-pickoff.md) — the fat tail §5 is about
- [08-market-open-and-close-dynamics.md](08-market-open-and-close-dynamics.md) — why calibration must be time-of-day bucketed
