# 10.01 — Signal Construction

> **Why this matters here:** the fabric owns rows **S0–S1** — 2 cycles, 12.8 ns, 10 %
> of the 128.0 ns budget in `rtl/fpga_top.sv`. In that window it does not *compute* a
> signal; it compares a value it already has against a number the host wrote
> milliseconds ago. This document is the bridge: for every signal a quant would
> reasonably want, it gives the arithmetic, the exact fabric cost in DSPs and cycles,
> and the verdict — **fabric, fabric-off-trigger, or host parameter**. Tiers 03 and 04
> tell you *how to build* the comparator; nothing before this tier tells you *what to
> compare*.

---

## 1. What a "signal" is in this system

Not a number. A **boolean produced in one cycle**:

```
signal  ⟶  scalar( book_top_t , my_state , strategy state )
           compared against  params[slot]   ⟶   1 bit   ⟶   fire / don't
```

Every candidate signal gets three questions, in this order. Fail any one and it does
not go in the fabric.

| # | Question | Fails if… |
| --- | --- | --- |
| **Q1 — State or window?** | Is it computable from the values already in `book_top_t` and per-symbol registers, or does it need a history of events? | It needs a rolling window **and** the window is longer than what fits in one BRAM row per symbol |
| **Q2 — Does the arithmetic fit?** | ≤ 1 DSP48E2 deep, no divide, no modulo, ≤ ~10 LUT levels ([00.01](../00-foundations/01-digital-logic-and-timing.md) §7) | Any variable-denominator division, any square root, any exponential, any loop |
| **Q3 — Does its information decay in nanoseconds?** | Would a 1 ms-old value of this signal be materially wrong? | No — then it is a **parameter**, and putting it in fabric buys nothing but latency and area |

**Q3 is the one people skip, and it is the one that decides the architecture.** A
signal whose value is essentially unchanged over a millisecond has no business being
recomputed every 6.4 ns. Push it into `sym_strat_t` and spend the cycle elsewhere.

> **RULE: a signal earns fabric residency only by being state-derived, cheap, *and*
> fast-decaying. Two out of three is a parameter.**

---

## 2. The catalogue

Everything below is derived from a single Nasdaq TotalView-ITCH 5.0 order-based feed
— the only feed the fabric decodes ([08.04](../08-nasdaq/04-totalview-itch-5.0.md)).

| Signal | Information horizon | Extra per-symbol state | Arithmetic | Verdict | § |
| --- | --- | --- | --- | --- | --- |
| **Top-of-book (queue) imbalance** | µs – ms | none — `book_top_t` carries it | 1 shift + 1 multiply + compare | **Fabric, on-trigger.** Implemented as `STRAT_IMBALANCE` | §3 |
| **Microprice / weighted mid** | µs – ms | none | 2 multiplies + compare | **Fabric candidate, on-trigger, costs +1 cycle** | §4 |
| **Depth-weighted imbalance (top-N)** | ms | none (book holds 16 levels) | N multiplies + log₂N adder tree | **Host.** The tree alone is ≥ 4 cycles | §3.4 |
| **Order-flow imbalance (OFI)** | ms | ~176 b: previous best px/qty both sides + accumulator | 4 compares, 2 adds, 1 shift | **Fabric, OFF-trigger** (one stage behind the book, read next tick) | §5 |
| **Trade-sign autocorrelation** | seconds – hours | a sign history far beyond one row | correlation over thousands of lags | **Host only** | §6 |
| **Short-horizon momentum** | 100 µs – 10 s | a price history | window regression | **Host** — except the degenerate "the touch just moved" case | §7 |
| **Short-horizon reversion** | 100 ms – 60 s | ditto | ditto | **Host** | §7 |
| **Realised volatility** | minutes | a return history | sum of squares | **Host.** Compiles into `edge_ticks` | [10.05](05-parameter-calibration.md) |
| **Queue position `q̂_ahead`** | ms | order-map ticket + per-symbol record | 1 compare + 1 saturating subtract | **Fabric, OFF-trigger** — [09.01](../09-deep-dives/01-queue-position-and-fill-probability.md) | — |

Two rows carry the whole design philosophy: **imbalance is in the trigger path, OFI is
in the fabric but not in the trigger path, and everything with a horizon longer than a
few milliseconds is a number in a table.**

---

## 3. Top-of-book imbalance — the one signal that is already in fabric

### 3.1 What it is and what it predicts

```
ρ  =  Qb / (Qb + Qa)        ∈ [0, 1]      0 = all ask, 1 = all bid
```

The mechanism, stated confidently because it is mechanical rather than statistical:
**at a tick-constrained price the two queues are a race, and the shorter one is
consumed first.** A bid queue of 300 against an ask queue of 5,000 will, absent new
arrivals, be exhausted long before the ask, and the touch will move up. Imbalance is a
forecast of *which side of the book runs out*, and only derivatively a forecast of the
mid.

That distinction determines what you may use it for:

| Use | Sound? | Why |
| --- | --- | --- |
| Choose **which side to quote** | **Yes** — strongest use | You want to rest on the side that will *not* be swept |
| Skew a two-sided quote | Yes | Same mechanism, continuous form |
| **Take** the thin side aggressively | Conditional | You are paying the spread against a mechanism that has already been priced by everyone else reading the same feed |
| Predict the mid over seconds | **No** | The imbalance is refreshed by new arrivals long before then |

### 3.2 Why the fabric evaluates a ratio, not a fraction

Computing `ρ` requires a divide by `Qb + Qa`, which is a variable denominator, which is
banned (CLAUDE.md §5.3, [09.04](../09-deep-dives/04-fixed-point-arithmetic-in-fabric.md)).
The comparison is restated by cross-multiplication, exactly as `strategy_pkg.sv` §5
already does:

```
    ρ > θ            with θ = imbalance_thr / IMB_SCALE
⇔   Qb·IMB_SCALE  >  Qa·imbalance_thr           (bid-heavy)
⇔   Qa·IMB_SCALE  >  Qb·imbalance_thr           (ask-heavy)
```

`IMB_SCALE = 256 = 1 << 8` is a power of two **on purpose**: the left-hand multiply
degenerates to a constant left shift, which is pure routing and free. One real
multiply survives per side. `imbalance_thr` is in units of 1/256, so `16'd384` is a
ratio of 1.50.

⚠️ **`param_table.sv` rejects `imbalance_thr < IMB_SCALE` at write time.** A threshold
below 1.00 would make the bid-heavy and ask-heavy tests *simultaneously true*, and the
fabric would fire both directions on the same tick. This is a parameter-domain check,
not a comparator fix — see [10.05](05-parameter-calibration.md) §5.

⚠️ **The operand ceiling is a correctness guard, not an area optimisation.** Operands
are clipped to `IMB_QTY_W = 24` bits so the product is 40 bits and lands in **one**
DSP48E2 (27×18) rather than a cascade. If *one* operand saturated and the other did
not, the inequality could **flip direction** — a saturated `Qa` shrinks the right-hand
side and manufactures a buy signal out of nothing. The primitive therefore refuses to
fire when *either* operand exceeds `IMB_QTY_MAX`. Fail-closed beats fail-plausible.

### 3.3 What it costs

| Item | Cost |
| --- | --- |
| Added latency | **0 cycles** — evaluates inside S1 alongside the other primitives |
| DSP48E2 | 2 (one per side), or 1 time-shared if the mux moves earlier |
| Per-symbol state | **none** — `bid_qty` and `ask_qty` arrive in `book_top_t` |
| Parameter words | 1 (`PW_IMB_THR`) |

Zero marginal latency is why this is the primitive that exists. It is not because
imbalance is the best signal available — it is because it is the best signal that is
*free*.

### 3.4 Why depth-weighted imbalance is rejected for the trigger path

The natural generalisation weights the first N levels:

```
ρ_N  =  Σ wᵢ·Qbᵢ  /  ( Σ wᵢ·Qbᵢ + Σ wᵢ·Qaᵢ )
```

| N | Multiplies | Adder tree depth | Added cycles | Verdict |
| ---: | ---: | ---: | ---: | --- |
| 1 | 1 | 0 | 0 | in fabric today |
| 4 | 8 | 2 | ≥ 2 | 12.8 ns — 10 % of the whole budget |
| 16 (`BOOK_LEVELS`) | 32 | 4 | ≥ 4 | 25.6 ns. Rejected outright |

The reduction tree is exactly the structure
[01.01](../01-fpga-design/01-rtl-design-patterns.md) §6 tells you not to build on the
fast path. **The correct resolution is not to build a cheaper tree — it is to move the
depth information into the threshold.** The host computes the deep measure at
millisecond cadence and calibrates `imbalance_thr` per symbol so that the level-1 test
carries as much of the deeper measure's information as a single threshold can. You lose
the residual; you keep 25.6 ns.

---

## 4. Microprice and the weighted mid

### 4.1 The formula, and the sign error that survives backtests

```
P_micro  =  ( Pb·Qa  +  Pa·Qb )  /  ( Qb + Qa )
```

⚠️ **The sizes weight the *opposite* prices, and this is the single most commonly
inverted formula in microstructure code.** The intuition: a large bid queue means you
will be filled *on the bid* — you are the seller's counterparty — so the price at which
trade is actually occurring sits nearer the **ask**. Written the other way around,

```
WRONG:   ( Pb·Qb + Pa·Qa ) / (Qb + Qa)
```

you get a quantity that still lives between the bid and the ask, still moves with the
book, still produces a plausible-looking equity curve, and is **anticorrelated with the
next mid move**. It fails no assertion. It fails no unit test that only checks bounds.
It is caught only by checking the sign against realised forward returns — which is why
[10.03](03-statistical-foundations.md) §2 insists that every signal be sign-verified
against a forward mark before it is calibrated.

Equivalent and more useful form, with `S = Pa − Pb`:

```
P_micro  =  Pb  +  S · Qb/(Qb + Qa)   =   Pb  +  S·ρ
```

### 4.2 The fabric form: never compute it, only compare it

The strategy never needs `P_micro` as a number. It needs one of

```
P_micro  >  F        (microprice above the host's fair value)
P_micro  <  F − E    (below it by the edge)
```

Substitute and cross-multiply the single divide away:

```
     Pb + S·Qb/(Qb+Qa)   >   F
⇔    (F − Pb)·(Qb + Qa)  <   S·Qb                    [ requires Qb+Qa > 0 ]
```

Both sides are single multiplies of bounded operands:

| Term | Width | Bound | Enforcement |
| --- | ---: | --- | --- |
| `F − Pb` | 16 b | `sat_sub_px`, clipped to `MICRO_OFF_MAX` | refuse to fire above it |
| `Qb + Qa` | 25 b | both clipped to `IMB_QTY_W = 24` | refuse to fire above it |
| `S = Pa − Pb` | 16 b | `sat_sub_px`, clipped | refuse to fire above it |
| `Qb` | 24 b | as above | — |
| Products | 41 b, 40 b | 25×16 and 24×16 → **one DSP48E2 each** | — |

```systemverilog
// rtl/strategy/prim_micro.sv  — CANDIDATE, not in the current primitive set.
// Budget impact: S1 splits into S1a/S1b. Strategy 2 -> 3 cycles, 12.8 -> 19.2 ns.
// Fail-closed on ANY operand out of range: a saturated operand can flip the
// inequality's direction, which manufactures a signal rather than suppressing one.
wire [15:0] s_spread = px16_sat(sat_sub_px(top.ask_px, top.bid_px));
wire [15:0] f_off    = px16_sat(sat_sub_px(p.fair_value, top.bid_px));
wire [24:0] q_tot    = {1'b0, qb24} + {1'b0, qa24};

wire        operands_ok = top.bid_valid & top.ask_valid & ~top.crossed
                        & (top.bid_qty <= IMB_QTY_MAX) & (top.ask_qty <= IMB_QTY_MAX)
                        & spread_in_range & offset_in_range & (q_tot != 25'd0);

// P_micro > fair_value   <=>   f_off * q_tot  <  s_spread * qb24
wire [40:0] lhs = f_off    * q_tot;      // 1 x DSP48E2
wire [39:0] rhs = s_spread * qb24;       // 1 x DSP48E2
wire        micro_above_fair = operands_ok & ({1'b0, rhs} > lhs);
```

### 4.3 The verdict, and the price of it

⚠️ **Two cascaded DSP48E2 multiplies plus a 41-bit compare will not close at 6.4 ns
combinationally on UltraScale+.** You must use the DSP's internal `M` register, which
adds a pipeline stage. The honest accounting:

| | Cycles | ns | Share of the 128.0 ns budget |
| --- | ---: | ---: | ---: |
| Strategy today (S0–S1) | 2 | 12.8 | 10.0 % |
| Strategy with `prim_micro` (S0–S1a–S1b) | 3 | 19.2 | 15.0 % |
| **Marginal cost** | **+1** | **+6.4** | **+5.0 %** |

> **RULE: `prim_micro` is built only when measurement shows that the staleness of the
> host-written `fair_value` — not our latency — is the binding error.**
> [10.02](02-fair-value-and-pricing.md) §7 defines that measurement. Spending 6.4 ns to
> recompute something the host already estimated better is the trade
> [09.01](../09-deep-dives/01-queue-position-and-fill-probability.md) §4.4 forbids;
> spending it because the host *cannot* track a quantity that moves on every book event
> is the trade that justifies the hardware. Only a measurement distinguishes the two.

> **Verify:** DSP48E2 combinational multiply delay and the `M`-register requirement at
> your speed grade, from the **AMD UltraScale Architecture DSP Slice user guide** and
> your own post-route timing report. Never take the cycle count above on faith — read
> it off the WNS on the `prim_micro` path.

---

## 5. Order-flow imbalance — the best signal that fits off the trigger path

### 5.1 Definition

Depth imbalance is a *level*. OFI is a *flow*: it accumulates the signed changes in
displayed size at the touch, so a book that is repeatedly refilled on the bid registers
buying pressure even though its instantaneous imbalance never moves.

For consecutive top-of-book observations `n−1 → n`:

```
e_n =  1[Pbⁿ ≥ Pbⁿ⁻¹]·Qbⁿ  −  1[Pbⁿ ≤ Pbⁿ⁻¹]·Qbⁿ⁻¹
     − 1[Paⁿ ≤ Paⁿ⁻¹]·Qaⁿ  +  1[Paⁿ ≥ Paⁿ⁻¹]·Qaⁿ⁻¹

OFI over a window  =  Σ e_n          and empirically   ΔP  ≈  β · OFI
```

> **Verify:** the exact indicator form and the linear-impact result from **Cont,
> Kukanov and Stoikov, "The Price Impact of Order Book Events"** (Journal of Financial
> Econometrics). Treat the published `R²` figures as literature, not as a forecast of
> your own — refit `β` per symbol per regime from your own data
> ([10.05](05-parameter-calibration.md) §3).

Every term is a comparison and a select. **No multiplies.** That is what makes it
affordable.

### 5.2 The windowing problem, and the decay that solves it

A true rolling sum over the last `W` events needs a `W`-deep shift register per symbol:
256 symbols × 64 events × 32 b = 512 Kbit ≈ 15 BRAM36, plus a subtract of the evicted
term. Affordable, but pointless — an exponential decay gives the same shape for two
adds and a shift:

```
ofi  ←  ofi  −  (ofi >>> k)  +  e_n              k = decay parameter, per symbol
```

⚠️ **This decays per *event*, not per *unit time*, and the two are not the same
statistic.** On a quiet symbol the accumulator holds information from minutes ago; at
the open it forgets in milliseconds — and the open is precisely when the event rate and
the information rate diverge most. Two honest options:

| Option | Mechanism | Cost | When |
| --- | --- | --- | --- |
| **Event-clock decay** (`k` fixed) | as above | 0 extra | Accept it, and calibrate `k` per symbol **per time-of-day bucket** so the event clock and the wall clock are locally aligned |
| **Wall-clock decay** | multiply by a decay factor read from a 16-entry ROM indexed by `log₂(Δt_ns)` | 1 DSP + 1 BRAM | Only if the event-rate variation within a bucket is measured to matter |

Start with the first. It is free, and calibrating `k` per bucket is work the host does
anyway.

### 5.3 Where it runs

> **RULE: the OFI accumulator is fabric state, updated one stage behind the book
> engine, and read by the strategy on the *next* event. Zero rows in the latency
> budget.** This is the same structure and the same justification as `queue_pos`
> ([09.01](../09-deep-dives/01-queue-position-and-fill-probability.md) §4.4): the
> update is cheap, the *value* changes on a millisecond scale, and a trigger that
> depended on an OFI computed from *this* tick would spend a trigger-path cycle
> refining a millisecond-scale input.

| Item | Sizing | Cost |
| --- | --- | --- |
| Per-symbol record: `Pb_prev`(32) `Qb_prev`(24) `Pa_prev`(32) `Qa_prev`(24) `ofi`(32 signed) `k`(4) | 148 b → 176 b padded | 256 × 176 b = 45 Kbit ≈ **2 BRAM36** |
| Update logic | 4 compares, 2 adds, 1 arithmetic shift, 4 selects | ~500 LUT / ~400 FF (estimate, pre-synthesis) |
| **Added trigger-path latency** | | **0 cycles** |
| Parameter words | `ofi_thr` (threshold), `k` (decay) | 2 |

⚠️ `ofi` is **signed and must saturate.** A wrapped accumulator inverts the sign of the
signal — it does not disable the strategy, it reverses it. Use a signed saturating add
(`sat_add_pos` pattern from `strategy_pkg.sv` §6) and count saturation events.

---

## 6. Trade-sign autocorrelation

### 6.1 On an order-based feed the sign is free

The classical problem — deciding whether a print was buyer- or seller-initiated —
requires the Lee-Ready tick/quote test on a level-aggregated feed. **On ITCH it is not
a problem at all.** An `E` / `C` execution names the *resting* order's reference; the
order map already holds that order's side; the aggressor is the other side. No
heuristic, no ambiguity, no test.

⚠️ Two exclusions that silently corrupt the statistic if you forget them:

- **Non-printable executions** (`printable = 0` in `book_evt_t`) are not tape prints and
  must not enter a trade-sign series.
- **Cross and auction executions** are not directional aggressions; the opening and
  closing crosses will otherwise dominate the series
  ([08.02](../08-nasdaq/02-sessions-auctions-and-halts.md)).

> **Verify:** which ITCH message types carry the printable flag and how cross
> executions are represented, from the **Nasdaq TotalView-ITCH 5.0 specification**.

### 6.2 What it means, and the trap

Signed order flow has **long memory**: the autocorrelation of trade signs decays as a
slow power law over hundreds to thousands of trades, not exponentially over a handful.

> **Verify:** the power-law decay and its exponent from **Lillo & Farmer, "The Long
> Memory of the Efficient Market"** and the subsequent literature. The exponent is
> venue- and period-specific; measure yours.

⚠️ **Autocorrelated signs do *not* imply predictable prices, and assuming they do is
the most expensive inference in this document.** A large parent order sliced into
thousands of children generates strongly autocorrelated signs while the price stays a
near-martingale, because market makers widen and lean against the predictable flow and
because impact is largely transient. The predictability is *in the flow*, and it has
already been arbitraged into the *quotes* you are reading. A strategy that buys because
the last 50 prints were buys is trading against the thing that already priced them.

### 6.3 Verdict

**Host only.** The statistic needs thousands of trades and hours of history; it has no
fabric representation and no fast-decaying component. It is an input to the
adverse-selection model, which compiles into `edge_ticks` and into whether a symbol is
enabled at all — never into a trigger.

---

## 7. Short-horizon momentum and reversion

### 7.1 One series, two horizons, opposite signs

| Horizon | Dominant effect | Mechanism |
| --- | --- | --- |
| ~0 – 1 s | **Momentum / continuation** | A sweep is one participant's incomplete parent order; the remainder is still coming |
| ~1 s – 60 s | **Reversion** | Transient impact decays; liquidity replenishes at the old level |
| minutes + | Neither, reliably | Whatever information caused the move is now in the price |

⚠️ **The crossover horizon is not a constant.** It varies by symbol, by tick regime, by
time of day, and by whether the move was information- or liquidity-driven. **A signal
fitted at a 5-second horizon and deployed on a 100 µs trigger is not a weaker version of
the same signal — it can be the opposite trade.** Every momentum/reversion parameter in
this system carries its fitted horizon as metadata, and
[10.04](04-backtesting-and-simulation.md) §5 requires the backtest's decision horizon to
match it.

### 7.2 What fabric can see for free

The degenerate, zero-cost case is already in `book_top_t`:

| Field | What it gives you | Cost |
| --- | --- | --- |
| `top_changed` | the touch moved on **this** event | 0 |
| `last_px` vs `bid_px`/`ask_px` | the last print relative to the current touch | 0 — one compare |
| `crossed`, `stale`, `bid_valid`, `ask_valid` | the gating that makes any of the above meaningful | 0 |

"The ask just lifted and the print was at the ask" is a one-cycle momentum signal, and
it is the *only* momentum signal the fabric gets for free. Anything with a window —
returns over the last N events, a regression slope, a realised-volatility scaling —
requires history and belongs on the host.

### 7.3 Verdict

**Host**, compiled into `fair_value` (the level) and `edge_ticks` (the confidence).
That is precisely what [10.02](02-fair-value-and-pricing.md) is about: a momentum view
does not become a fabric primitive, it becomes a shifted fair value.

---

## 8. Compilation: every signal ends up in a parameter word

The parameter record is `sym_strat_t` in `rtl/pkg/trading_pkg.sv`, written one field
per 32-bit word (`param_word_e` in `rtl/strategy/strategy_pkg.sv` §4).

| Word | Field | Which quant analysis produces it | Cadence |
| ---: | --- | --- | --- |
| 0 | `ctrl` — `strat_enabled`, `strat_select` | universe selection + regime classification (§2, [10.05](05-parameter-calibration.md) §4) | session, or on a regime change |
| 1 | `quote_qty` | sizing: edge estimate ÷ adverse-selection estimate, capped by risk | minutes |
| 2 | `edge_ticks` | realised volatility + fair-value staleness + adverse selection (§6, §7) | minutes |
| 3 | `min_book_qty` | thin-book / toxicity filter | minutes |
| 4 | `fair_value` | the whole of [10.02](02-fair-value-and-pricing.md) | **~1 ms** |
| 5 | `imbalance_thr` | §3 — calibrated so the L1 test carries the depth-weighted information | minutes |

⚠️ **`edge_ticks` is written by the host *already scaled into ITCH price units*.** The
fabric never multiplies by a tick size: that would be a per-symbol variable multiply on
the critical path, and sub-dollar names have a different tick from ≥ $1.00 names. The
host knows the tick regime; the fast path only ever adds
(`strategy_pkg.sv` §5, `TICK_SCALE_PENNY`).

> **Verify:** the tick-size regime boundary and any pilot programmes in force from
> **SEC Rule 612** and the current **Nasdaq Equity Rulebook** —
> [08.06](../08-nasdaq/06-regnms-and-compliance.md). This has changed and will change
> again; a hardcoded tick regime is a latent pricing bug.

---

## 9. The fabric signal budget, totalled

| Block | Trigger-path cycles | BRAM36 | DSP48E2 | Status |
| --- | ---: | ---: | ---: | --- |
| Imbalance comparator (`STRAT_IMBALANCE`) | 0 (inside S1) | 0 | 2 | **built** |
| `queue_pos` estimator | 0 (off-trigger) | ~2 + order-map growth | 0 | [09.01](../09-deep-dives/01-queue-position-and-fill-probability.md) |
| OFI accumulator | 0 (off-trigger) | 2 | 0 | **proposed, §5** |
| `prim_micro` | **+1 (6.4 ns)** | 0 | 2 | **candidate, gated on §4.3** |
| Everything else in this document | 0 | 0 | 0 | host |

**The signal layer adds at most one cycle to the tick-to-trade path, and only if a
measurement demands it.** That is the target, and it is achievable because the
expensive part of every signal here is its *calibration*, not its evaluation — and
calibration happens on a CPU with milliseconds to spare
([04.06](../04-system-architecture/06-cpu-fpga-partitioning.md)).

---

## 10. Rules for this project

1. **A signal enters the fabric only if it is state-derived, single-DSP-cheap, *and*
   fast-decaying.** Two out of three makes it a parameter.
2. **No divides.** Every ratio is a cross-multiplied inequality against a host-written
   fixed-point threshold, with the scale a power of two wherever a side can be a shift.
3. **Clip operands before multiplying, and refuse to fire when a clip binds.** A
   one-sided saturation can flip an inequality's *direction* and manufacture a signal.
4. **Every accumulator is signed-saturating and counted.** A wrapped OFI reverses the
   strategy; it does not stop it.
5. **Off-trigger fabric state is read on the *next* event, never this one.** OFI,
   `q̂_ahead` and every other accumulator obey the
   [09.01](../09-deep-dives/01-queue-position-and-fill-probability.md) §4.4 rule.
6. **Verify every signal's *sign* against forward marks before calibrating its
   magnitude.** The microprice weighting (§4.1) is the canonical inverted formula and it
   passes every bounds check ever written.
7. **A signal's fitted horizon travels with it** and must match the horizon at which it
   is deployed. Momentum at 5 s is not momentum at 100 µs.
8. **Depth information goes into the threshold, not into an adder tree.** The fast path
   never reduces over levels.
9. **Trade signs come from the order map, not from a tick test**, and exclude
   non-printable and cross executions.
10. **Long-memory order flow is not price predictability.** Signed-flow statistics feed
    the adverse-selection model and `edge_ticks`; they never feed a trigger.
11. **Adding a trigger-path cycle requires a measurement showing the *host* is the
    binding error**, not an argument that the fabric could do it.

---

## Further reading

- [README.md](README.md) — the tier index and the FPGA/host division of labour
- [02-fair-value-and-pricing.md](02-fair-value-and-pricing.md) — where `fair_value` comes from and how stale it is allowed to be
- [03-statistical-foundations.md](03-statistical-foundations.md) — proving a signal's sign and magnitude are real
- [04-backtesting-and-simulation.md](04-backtesting-and-simulation.md) — why the P&L attributed to a signal is mostly a fill assumption
- [05-parameter-calibration.md](05-parameter-calibration.md) — the pipeline that turns these signals into `sym_strat_t` rows
- [../03-algotrading/01-market-microstructure.md](../03-algotrading/01-market-microstructure.md) — queue position, spread, adverse selection
- [../03-algotrading/05-strategy-taxonomy.md](../03-algotrading/05-strategy-taxonomy.md) — which strategies these signals serve
- [../04-system-architecture/04-strategy-engine-on-fpga.md](../04-system-architecture/04-strategy-engine-on-fpga.md) — the comparator bank and the parameter table
- [../04-system-architecture/06-cpu-fpga-partitioning.md](../04-system-architecture/06-cpu-fpga-partitioning.md) — the DMA path these parameters travel
- [../05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md) — the 128.0 ns this document spends from
- [../08-nasdaq/04-totalview-itch-5.0.md](../08-nasdaq/04-totalview-itch-5.0.md) — the feed every signal here is derived from
- [../09-deep-dives/01-queue-position-and-fill-probability.md](../09-deep-dives/01-queue-position-and-fill-probability.md) — the off-trigger estimator pattern
- [../09-deep-dives/04-fixed-point-arithmetic-in-fabric.md](../09-deep-dives/04-fixed-point-arithmetic-in-fabric.md) — scaling, saturation, and the ban on division
