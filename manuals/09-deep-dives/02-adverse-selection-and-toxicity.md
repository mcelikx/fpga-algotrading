# 09.02 — Adverse Selection and Toxicity

> **Why this matters here:** the honest justification for every nanosecond in
> `rtl/fpga_top.sv` is not that speed earns money. Speed *loses less*. A resting quote is
> a written option; adverse selection is the premium you failed to charge; and the only
> lever hardware gives you is the width of the window in which that option can be
> exercised against a price you no longer believe.
> [03.01](../03-algotrading/01-market-microstructure.md) §5 introduces the concept and
> [08.07](../08-nasdaq/07-fees-rebates-and-economics.md) §6 puts it in the P&L. This is
> the measurement instrument, the toxicity metrics that are actually computable, and the
> six fabric levers — with their costs.

---

## 1. The core problem, stated precisely

You are short an option to every participant who sees the world before you do. The strike
is your quote, the expiry is your cancel latency, and you collect no premium beyond the
spread and the rebate.

```
Per-share realized P&L of one passive fill

  Π  =  rebate                    ← schedule + tier, deterministic, 08.07 §3
      + effective half-spread e   ← e = s·(M(t) − P),  s = +1 bought / −1 sold
      − adverse selection a(h)    ← a(h) = s·(M(t) − M(t+h)),  the whole game
      − fees                      ← taker/Section 31/TAF/CAT/clearing, 08.07 §5
      − inventory & impact cost   ← own footprint plus carry on the position

  identity:  realized half-spread  r(h) = e − a(h)     ⇒  Π = rebate + r(h) − fees
```

| Term | Known at fill time? | Latency helps? |
| --- | --- | --- |
| Rebate; fees | **Yes** — fee schedule | No |
| Effective half-spread `e` | **Yes** | Weakly, via queue rank ([01](01-queue-position-and-fill-probability.md)) |
| **Adverse selection `a(h)`** | **No — unknown for hours** | **Yes. This is the mechanism** |
| Inventory / impact | No | Slightly |

> ⚠️ **The backtest failure mode that has killed more market-making programmes than any
> other.** A simulator that assumes a fill whenever the touch trades and marks it at the
> quote computes `rebate + e` — the two terms that are *known in advance and always
> positive*. It cannot compute `a(h)`, because `a(h)` depends on what the market did after
> a fill that did not happen. Such a backtest reports a profit for **every** strategy that
> quotes, including strategies that lose on every fill. This extends the warning in
> [08.07](../08-nasdaq/07-fees-rebates-and-economics.md) §6 with its cause: the omitted term
> is the only stochastic one, and its mean is negative.
> **RULE: no strategy is promoted past simulation without a measured mark-out curve from
> real fills** — not a modelled one. A strategy with no fills has no evidence and gets
> canary size ([06.04](../06-operations/04-testing-strategy.md)), never conviction.

---

## 2. Mark-out analysis — the measurement instrument

### 2.1 Definition

A **mark-out** is the sign-corrected P&L of a single fill against a reference price at a
horizon `h` after that fill.

```
  fill:  Q shares at price P, at time t;  s = +1 if we bought, −1 if we sold
  M(u):  reference mid at time u, EXCLUDING our own displayed interest (§2.2)

    e     =  s · (M(t)   − P)                  effective half-spread — horizon-free
    r(h)  =  s · (M(t+h) − P)                  the mark-out — what we kept
    a(h)  =  e − r(h) = s · (M(t) − M(t+h))    adverse selection at horizon h
```

`e > 0` good, `r(h) > 0` good, `a(h) > 0` is a **cost** — same signs as
[08.07](../08-nasdaq/07-fees-rebates-and-economics.md) §6; do not re-derive them locally.

> **RULE: the deliverable is `r(h)` as a *function*, per symbol and per regime, with
> dispersion.** "Our mark-out is −0.2 mils" answers no question. The **shape of the curve is
> the diagnostic**, and the tail matters more than the mean — a strategy can be fine at p50
> and insolvent at p1.

### 2.2 ⚠️ The reference-price convention

Marking against the same venue's raw mid **double-counts your own quote**: your resting
order is part of the displayed depth that sets the bid, and the fill mechanically removes
it. Alone at the touch, the bid drops the instant you are filled and the raw mid
manufactures a loss containing zero information; one of many, it manufactures a small gain.
Either way the number is an artefact of your own order.

| Reference | Use | Problem |
| --- | --- | --- |
| Nasdaq raw mid | ❌ never | Contains our order; the artefact dominates at short `h` |
| Nasdaq mid **ex-self** (our shares subtracted; level drops out if emptied) | ✅ diagnostic | Needs exact reconstruction of our resting state |
| **NBBO mid, ex-self** | ✅ **primary** | Needs a consolidated view; SIP timestamps are not our clock |
| Microprice ex-self ([03.01](../03-algotrading/01-market-microstructure.md) §3) | ✅ secondary | Sharper sub-ms, noisier, imbalance-dependent |

> **RULE: the primary reference is the NBBO mid computed ex-self; the Nasdaq-only ex-self
> microprice is reported alongside as a short-horizon diagnostic. Never the raw book.**
> Both are host reconstructions from the archived feed
> ([04.06](../04-system-architecture/06-cpu-fpga-partitioning.md)) — the fabric computes no
> mark-outs, ever.

### 2.3 The horizon ladder — what each `h` tells you

| `h` | Dominated by | Question answered |
| --- | --- | --- |
| **~0** | — | Reference point. `r(0) = e` |
| **1 µs** | The latency race | Picked off on a quote we should already have cancelled? A loss here is **ours** — cancel-path latency, priced in [03](03-cancel-latency-and-pickoff.md) |
| **10 µs** | Same-venue reaction of everyone who saw the trigger | Are we last among colocated participants? |
| **100 µs** | Cross-venue propagation, rest of a sweep | Was the counterparty acting on an event visible elsewhere first? |
| **1 ms** | Short-horizon order-flow information | The workhorse horizon. Genuine microstructure alpha in the counterparty |
| **10 ms** | Continuation of a parent order | Are we quoting into someone's child-order schedule? |
| **100 ms** | Real information — news, a real decision | The counterparty knows something. Speed cannot fix this |
| **1 s** | Classical realized spread | Comparable to the literature and [08.07](../08-nasdaq/07-fees-rebates-and-economics.md) §9 |
| **10 s** | Our own impact decaying, plus drift | If `r` *improves* from 1 s to 10 s, we caused the move |
| **EOD** | Inventory, hedging, market drift | Not adverse selection at all. Do not confuse the two |

> **Verify:** the physical floor on cross-venue propagation (Carteret ↔ Secaucus ↔ Mahwah)
> determines whether the 100 µs row is even meaningful for us. Take fibre distances and
> switch counts from [08.08](../08-nasdaq/08-connectivity-and-colocation.md) and the
> venue's own colocation documentation — never from a rule of thumb.

### 2.4 Curve shapes → diagnosis → fix

| Shape of `r(h)` | Diagnosis | Fix |
| --- | --- | --- |
| Sharply negative by 1–10 µs, **recovers** by 1–10 ms | **Picked off on a stale quote.** A racer exploited a price we had not cancelled; no lasting information | **Cancel latency** ([03](03-cancel-latency-and-pickoff.md)). An engineering defect, not a strategy problem |
| Flat to 100 µs, then **monotonically worsening** through 1 s | Counterparty has **real information**. No amount of speed helps | Widen (§4.2) or stop quoting the symbol. Speed spend here is wasted |
| **Positive** short, **decaying to zero** by 1–10 s | **We** are the impact; our size moved the price and it reverted | Reduce size (§4.5); slow the requote |
| Flat, slightly positive at every `h` | Healthy passive capture | Nothing — but verify the ex-self convention before believing it |
| Mean flat, **p1/p5 deeply negative** | Fat-tail pickoff: rare, large, concentrated | Look at the tail, not the mean. Almost always §4.3 or §4.6 |
| Repeatable step at one specific `h` | A scheduled or mechanical event (auction, index print, a peer's timer) | Gate the clock window ([08](08-market-open-and-close-dynamics.md)) |
| Bad in one symbol / one hour only | Regime, not strategy | Per-symbol, per-bucket parameters. Never pool |
| Positive short, negative only at EOD | **Inventory drift** mis-labelled as toxicity | Skew and hedge. Do not touch the cancel path |

### 2.5 The tooling — slow path, offline, host only

```python
# host/analysis/markout.py — SLOW PATH. Nightly, on archived feed + fill logs.
# No fabric counterpart exists or should: the FPGA logs raw fills and nothing more.
import numpy as np, pandas as pd
H_NS = [1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000]
fills = pd.read_parquet("fills.parquet")        # ts_ns, sym, side, px, qty, q_rank_bkt
mids  = pd.read_parquet("nbbo_exself.parquet")  # ts_ns, sym, mid   (§2.2 convention)

def markout(fills, mids, horizons=H_NS):
    s, m_ = np.where(fills.side.eq("B"), 1.0, -1.0), mids.sort_values("ts_ns")
    out = fills[["ts_ns", "sym", "qty", "q_rank_bkt"]].copy()
    at  = pd.merge_asof(fills.sort_values("ts_ns"), m_, on="ts_ns", by="sym",
                        direction="backward")
    out["e"] = s * (at.mid - fills.px)                             # horizon-free
    for h in horizons:
        f = fills.assign(ts_ns=fills.ts_ns + h).sort_values("ts_ns")
        m = pd.merge_asof(f, m_, on="ts_ns", by="sym", direction="backward")
        out[f"r_{h}"] = s * (m.mid - fills.px)                     # the mark-out
        out[f"a_{h}"] = out["e"] - out[f"r_{h}"]                   # adverse selection
    return out

curve = markout(fills, mids).groupby(["sym", "q_rank_bkt"])[[f"r_{h}" for h in H_NS]] \
          .agg(["mean", "count", lambda x: x.quantile(0.05)])  # SHAPE and TAIL, not a mean
```

⚠️ `direction="backward"` returns the last mid *at or before* `t+h`; if the book is quiet
that mid may be far older than `t+h`, so carry the reference's own staleness alongside the
value or the short-horizon columns are noise. ⚠️ Fills are **not independent** — one parent
order produces many — so naive standard errors are far too tight. Cluster by
`(symbol, minute)` at minimum.

---

## 3. Toxicity metrics

### 3.1 Order flow imbalance (OFI) — the recommended fabric signal

Book imbalance `I = (Q_bid − Q_ask)/(Q_bid + Q_ask)` is a **state**: a ratio describing the
book right now. **OFI is a flow**: the signed change in depth at the best quotes,
accumulated over adds, cancels and executions. A book can sit at `I = +0.6` all day and
carry no information; OFI is nonzero only when something *happened*. Per top-of-book update
`n`, with previous state `(P_b, Q_b, P_a, Q_a)`:

```
 e_n =  [P_b,n ≥ P_b,n−1]·Q_b,n  −  [P_b,n ≤ P_b,n−1]·Q_b,n−1      ← bid side
      − [P_a,n ≤ P_a,n−1]·Q_a,n  +  [P_a,n ≥ P_a,n−1]·Q_a,n−1      ← ask side
 OFI over a window = Σ e_n            (positive = buy pressure)
```

Four price comparisons, four conditional adds. **No multiplies, no divides.** Every input is
already registered in `book_top_t`; the previous beat is one register file.

> **Verify:** the exact OFI construction and its empirical relation to short-horizon returns
> from **Cont, Kukanov & Stoikov, "The Price Impact of Order Book Events"**. The form used
> here is the top-of-book variant; deeper variants exist and cost more.

```systemverilog
// rtl/strategy/ofi_track.sv — STRATEGY STATE, NOT A TRIGGER INPUT.
// One stage behind book_engine; read by the strategy on the NEXT event. 0 budget rows.
always_ff @(posedge clk) if (top_valid) begin
    automatic logic signed [OFI_W-1:0] e =
          (top.bid_px >= pb[top.sym] ? OFI_W'(top.bid_qty) : '0)
        - (top.bid_px <= pb[top.sym] ? OFI_W'(qb[top.sym]) : '0)
        - (top.ask_px <= pa[top.sym] ? OFI_W'(top.ask_qty) : '0)
        + (top.ask_px >= pa[top.sym] ? OFI_W'(qa[top.sym]) : '0);
    // Leaky integrator: decay is an ARITHMETIC RIGHT SHIFT, never a divide.
    // ⚠️ sat_add_s is mandatory. A wrapped OFI inverts the §4.4 trigger and pulls
    //    exactly the side that should have stayed up.
    ofi[top.sym] <= sat_add_s(ofi[top.sym] - (ofi[top.sym] >>> DECAY_SH), e);
    pb[top.sym] <= top.bid_px;  qb[top.sym] <= top.bid_qty;
    pa[top.sym] <= top.ask_px;  qa[top.sym] <= top.ask_qty;
end
```

⚠️ `>>>` on a signed negative rounds toward −∞, so a small negative OFI decays to −1 and
**sticks there forever**, silently arming one side of §4.4. Clamp `|ofi| < 2^DECAY_SH` to
zero — [04](04-fixed-point-arithmetic-in-fabric.md) §5.

### 3.2 Trade sign imbalance — and why Lee-Ready does not apply

Tick-test/quote-test classification exists because the public tape does not say who was the
aggressor. **On TotalView-ITCH the question does not arise.** An `E`/`C` Order Executed names
an order reference; that order is in our order map with its resting side; the aggressor is on
the **opposite** side. An execution against a resting bid was **seller-initiated**, with
certainty and zero inference — `signed_vol += (resting side == BID) ? −exec_shares :
+exec_shares`, one conditional add on a lookup we already perform at book stage B1
([04.03](../04-system-architecture/03-order-book-in-hardware.md) §11). The second-cheapest
toxicity signal available.

> **Verify:** that `E` and `C` carry no side field of their own and that side must be taken
> from the referenced resting order; and separately the semantics of the side field on `P`
> (Trade — non-cross), i.e. whether it denotes the non-displayed order's side or the
> aggressor's. Source: the **Nasdaq TotalView-ITCH 5.0 specification**; decoder detail in
> [08.04](../08-nasdaq/04-totalview-itch-5.0.md). Getting `P` backwards inverts the signal on
> exactly the hidden flow most likely to be informed.

### 3.2 Trade sign imbalance — and why Lee-Ready does not apply

Tick-test/quote-test classification exists because the public tape does not say who was the
aggressor. **On TotalView-ITCH the question does not arise.** An `E`/`C` Order Executed
names an order reference; that order is in our order map with its resting side; the
aggressor is on the **opposite** side. An execution against a resting bid was
**seller-initiated**, with certainty and zero inference.

```
signed_vol  +=  (resting side == BID) ? −exec_shares : +exec_shares
```

One lookup we already perform at book stage B1
([04.03](../04-system-architecture/03-order-book-in-hardware.md) §11) and one conditional
add — the second-cheapest toxicity signal available.

> **Verify:** that `E` and `C` carry no side field of their own and that side must be taken
> from the referenced resting order; and separately the semantics of the side field on `P`
> (Trade — non-cross), i.e. whether it denotes the non-displayed order's side or the
> aggressor's. Source: the **Nasdaq TotalView-ITCH 5.0 specification**; decoder detail in
> [08.04](../08-nasdaq/04-totalview-itch-5.0.md). Getting `P` backwards inverts the signal
> on exactly the hidden flow most likely to be informed.

### 3.3 VPIN — what it is, and why it is not a trigger

**VPIN** (Volume-Synchronized Probability of Informed Trading) runs on a *volume* clock,
not a time clock: partition the tape into buckets of exactly `V` shares; within each
bucket split volume into buy and sell parts by **bulk volume classification** — allocating
a fraction determined by the standardized price change over the bucket via a chosen CDF,
rather than classifying trades individually; then
`VPIN = ⟨ |V_buy − V_sell| / V ⟩` averaged over a rolling window of `n` buckets.

The honest assessment, which this project adopts:

| Objection | Consequence for us |
| --- | --- |
| Bulk classification is contested — it can generate imbalance from volatility alone, with no informed trading present | It partly measures σ, which we measure directly and far more cheaply |
| The best-known predictive claim (flash-crash forewarning) has been challenged in the published literature | Do not treat it as an early-warning system |
| Highly sensitive to bucket size `V` and window `n`, with no canonical choice | Two defensible parameterisations can disagree in sign |
| **Minutes-scale by construction** — a bucket takes minutes to fill | **It cannot inform a nanosecond decision.** No version of it belongs on the trigger path |

> **Verify:** the original construction and claims in **Easley, López de Prado & O'Hara,
> "Flow Toxicity and Liquidity in a High-Frequency World"** and the related VPIN papers,
> and the published critiques — notably **Andersen & Bondarenko, "VPIN and the Flash
> Crash"**. Read both sides; do not take this table as a substitute for the sources.

> **RULE: VPIN is a slow-path regime indicator that may set a parameter. It is NEVER a
> fast-path trigger.** If it earns a place at all, it does so by nudging
> `edge_ticks`/`size` in the host's 1 kHz parameter refresh
> ([04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §3).

### 3.4 Comparison

| Metric | Measures | Timescale | In fabric? | Where it lives here |
| --- | --- | --- | --- | --- |
| **Book imbalance `I`** | Book *state* | Instant | Yes — cross-multiplied compare, no divide | Trigger input, `imb_thresh` |
| **OFI** | Signed *flow* at the touch | µs–ms | **Yes — adds/subtracts on events already decoded** | **Primary fabric toxicity signal** (§3.1) |
| **Signed volume** | Aggressor-side flow | µs–s | Yes — one conditional add | Secondary (§3.2) |
| **Volatility proxy** | EWMA of \|Δmid\| | ms–s | Yes — abs + add + shift | Stress detector (§4.2) |
| **Mark-out `r(h)`** | Realized toxicity — ground truth | Hours (needs the future) | **No — impossible by construction** | Host, nightly (§2.5) |
| **VPIN** | Bulk-classified volume imbalance | **Minutes** | No, and pointless if it were | Host regime indicator only (§3.3) |

---

## 4. The hardware levers

Six, in descending order of leverage: mechanism / latency cost / resource cost / failure mode.

### 4.1 Faster cancels — the highest-leverage lever, by a wide margin

**Mechanism:** shorten the window in which the written option can be exercised at a price
we have already repudiated. **Latency cost:** negative — this *is* the latency work.
**Resource cost:** arbitration priority and a dedicated cancel template. **Failure mode:** a
cancel path that is fast but not *deterministic* leaves the fat tail intact, and the tail
is where the whole loss lives ([07](07-jitter-sources-and-determinism.md)).

The race and its queue-priority consequences are derived in
[03-cancel-latency-and-pickoff.md](03-cancel-latency-and-pickoff.md) and not repeated. The
only claim this document adds is the empirical test: **a mark-out curve sharply negative at
1–10 µs that recovers by 1 ms is a cancel-latency defect and nothing else.** No parameter
change fixes it.

### 4.2 Widening under stress

**Mechanism:** a spread multiplier selected by a fabric-computed stress bit, applied to the
quote offsets already in the parameter table.

```
stress[sym] = (|ofi[sym]|      > ofi_thresh[sym])    // §3.1, host-loaded ABSOLUTE
            | (vol_ewma[sym]   > vol_thresh[sym])    // EWMA of |Δmid|, shift-decayed
eff_offset  =  px_offset[sym] + (stress[sym] ? widen_ticks[sym] : 0)
```

Both thresholds are **absolute, per-symbol, host-loaded in shares and price units**, so the
fabric does a subtract and a compare and **never a division or a normalisation**;
recalibrating them against current depth is the host's 1 kHz job. This is the
host-precomputed-constant rule of [04](04-fixed-point-arithmetic-in-fabric.md) §8.2 applied
to a toxicity signal.

**Latency:** zero added rows — `eff_offset` is an adder in the existing S1 stage.
**Resources:** two comparators, one adder, two parameter fields. **Failure mode:**
thresholds that arm constantly — a permanently-widened quote never fills and the strategy
is silently off. Instrument `widen_active_frac` (§7).

⚠️ `widen_ticks`, `ofi_thresh` and `vol_thresh` arrive through the **same double-buffered,
commit-bit parameter window** as every other parameter
([04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §5). A torn update that
applies a new threshold against an old multiplier produces a quote nobody designed.

### 4.3 Stale-book detection — hard, and *soft*

`book_top.stale` already exists, is sticky, gates the strategy at S0 and the risk gate at T0
independently ([04.03](../04-system-architecture/03-order-book-in-hardware.md) §10), and is
asserted at top level in `fpga_top.sv`. That covers **hard** staleness: a gap, an overflow,
a resync.

**Soft staleness is the uncovered case.** A book that is technically current but has
received no update for `N` cycles *while the venue as a whole is busy* is suspect: the world
is moving and our symbol's picture is not. That is the precondition for a pickoff.

⚠️ **The trap:** you cannot evaluate this on the event that would use it. If an event for
symbol `X` just arrived, `X`'s staleness is zero by construction. The check must be driven
from outside `X`'s own event stream. **The design: a round-robin scrubber**, one slot/cycle.

```systemverilog
// rtl/strategy/soft_stale.sv — one comparator, one subtract, one BRAM port.
// Sweep period = N_ACTIVE cycles = 256 × 6.4 ns ≈ 1.64 µs at 156.25 MHz.
// That period IS the detection latency. Document it; do not pretend it is zero.
always_ff @(posedge clk) begin
    if (top_valid) last_upd[top.sym] <= cycle_cnt;   // one write port
    scrub_idx <= scrub_idx + 1'b1;                   // free-running sweep
    soft_stale[scrub_idx] <= venue_busy              // global leaky event rate
        && ((cycle_cnt - last_upd[scrub_idx]) > stale_cycles[scrub_idx]);
end
```

`venue_busy` is a global leaky counter of book events compared against a host threshold.
Without it, a genuinely quiet market marks **every** symbol soft-stale at once and pulls the
entire book — the failure mode this lever must not have.

> **RULE: `soft_stale[sym]` is a HARD GATE, ANDed into the S0 gating reduction beside
> `book_stale` ([04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §10) — not
> a soft input to sizing.** Because that gate is already an AND-reduction of precomputed
> bits, this costs **zero** additional trigger-path latency. A quote priced off a picture we
> know to be old is precisely what gets picked off; there is no defensible middle setting.

Unlike `book_stale`, `soft_stale` is **self-clearing** — one update for the symbol restores
it. It describes a transient condition, not a corrupted structure.

### 4.4 Imbalance triggers — and the asymmetry

**Mechanism:** when OFI crosses a threshold, pull **one** side.

| OFI | Interpretation | Action | ⚠️ Not this |
| --- | --- | --- | --- |
| Strongly **negative** (sell pressure) | Sellers are working through the bid | **Pull the bid.** Keep the ask — it is about to be a good ask | Pulling both |
| Strongly **positive** (buy pressure) | Buyers are lifting the offer | **Pull the ask.** Keep the bid | Pulling both |
| Near zero | Two-sided flow | Quote both | — |

Pulling both sides is the intuitive response and it is wrong twice: it forfeits the side that
just became *more* attractive, and it burns queue position on a level that was never at risk
([01](01-queue-position-and-fill-probability.md) §5.1). **Latency:** one comparator in S0/S1.
**Resources:** trivial. **Failure mode:** OFI sign inversion (§3.1) pulls exactly the wrong
side, converting a defence into an accelerant.

### 4.5 Size reduction instead of withdrawal

**Mechanism:** cut displayed quantity rather than cancelling. You keep a presence and,
crucially, may keep **queue position** — the asset
[01](01-queue-position-and-fill-probability.md) prices — while capping the loss on a toxic
fill proportionally.

| Response | Queue position | Loss exposure | When |
| --- | --- | --- | --- |
| Do nothing | Kept | Full | Signal is weak |
| **Reduce size** | **Possibly kept — verify** | Scaled down | Moderate signal, high queue value |
| Widen (§4.2) | **Lost** (new price = new queue) | Reduced | Signal is real and persistent |
| Pull one side (§4.4) | Lost | Zero on that side | Strong directional signal |
| Pull both | Lost | Zero | `soft_stale`, kill, gap |

> **Verify:** whether a downward quantity change preserves time priority for the remaining
> shares on Nasdaq, and whether the mechanism is a partial cancel or a replace. The
> distinction is decisive — a replace goes to the **back** of the queue
> ([08.05](../08-nasdaq/05-ouch-5.0-order-entry.md)), converting a defensive size cut into a
> total loss of the asset being defended. Source: the **Nasdaq OUCH 5.0 specification** and
> the **Nasdaq Equity Rulebook** priority rules
> ([08.03](../08-nasdaq/03-order-types-and-routing.md)). ⚠️ Do not implement this lever until
> that answer is in writing.

### 4.6 Fade on your own fill

**The most information-rich message you will ever receive is your own execution.** It is the
one event that tells you, with certainty, that a counterparty evaluated your price and
decided it was worth taking. Everything else in the feed is about other people.

> **RULE: on any fill, the strategy re-evaluates before requoting, and the default is to
> widen.** Requoting the same price immediately after a fill is the single most reliable way
> to be filled again by the remainder of the same informed order.

`fill_valid` — already wired from `order_gateway` to `strategy_engine` in `fpga_top.sv` —
sets a per-symbol `post_fill` bit and loads the existing `cooldown` counter
([04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §3). While `post_fill` is
set, `eff_offset` takes the widened value of §4.2 unconditionally. It clears after
`fade_cycles` with no further fill, and **each new fill reloads the counter** — so a sequence
of fills widens progressively, which is exactly right when a parent order is walking through
us. **Latency:** zero — `post_fill` is a precomputed bit in the existing AND-reduction.
**Resources:** one bit and one counter per symbol. **Failure mode:** `fade_cycles` too long
turns a market maker into a one-shot participant.

### 4.7 Summary

| Lever | Signal needed | Fabric cost | Latency added | Reduces adverse selection | Risk if misconfigured |
| --- | --- | --- | --- | --- | --- |
| **Faster cancels** (§4.1) | none — always on | Arbiter priority, cancel template | **Negative** | **Most** | Jitter leaves the tail intact |
| **Widen under stress** (§4.2) | OFI, vol EWMA, host thresholds | 2 cmp + 1 add | 0 rows | High | Always-armed ⇒ never fills, silently off |
| **Soft stale gate** (§4.3) | `last_upd[sym]`, `venue_busy` | 1 BRAM + cmp + scrubber | 0 rows (~1.64 µs detect) | High, on the fat tail | Too tight ⇒ the whole book is pulled |
| **Asymmetric OFI pull** (§4.4) | OFI sign + magnitude | 1 cmp | 0 rows | Medium-high | Sign error pulls the wrong side |
| **Size reduction** (§4.5) | any toxicity signal | Parameter mux | 0 rows | Medium — keeps queue | Loses priority if it is really a replace |
| **Fade on own fill** (§4.6) | `fill_valid` | 1 bit + counter | 0 rows | High on repeat-fill toxicity | Too long ⇒ one-shot maker |

**Five of six cost zero trigger-path latency**, because each reduces to a precomputed bit
entering an AND-reduction or an adder that already exists. That is not a coincidence — it is
the constraint that made these six the chosen six.

---

## 5. Toxicity conditional on queue rank

[01](01-queue-position-and-fill-probability.md) §1 defers this here. The claim:
**back-of-queue fills are systematically more toxic than front-of-queue fills**, and the
mechanism is arithmetic, not behavioural. To reach an order behind `A` shares, the market
must push `A` shares of one-directional aggressive flow through that price. Small uninformed
prints never get that deep; large one-directional flow is disproportionately informed. **Deep
fills are conditioned on exactly the flow that hurts.**

**The empirical test.** Join the `q_ahead_est / depth_at_entry` bucket from the
[01](01-queue-position-and-fill-probability.md) §7.1 log record onto §2.5's output
(`q_rank_bkt` is in the snippet for this reason) and compute a mark-out curve *per bucket*:

| `a = q̂/Q₀` at entry | Expected `r(1 ms)` | Expected `P(fill)` | Product |
| --- | --- | --- | --- |
| Front (0.0–0.1) | Least negative | Highest | **Best, by a wide margin** |
| Middle (0.1–0.5) | Worse | Lower | Marginal |
| Back (0.5–1.0) | **Worst** | Lowest | **Often negative** |

⚠️ **The confound that will fool you.** Deep-queue fills happen disproportionately during
high-flow, high-volatility episodes, so an unbucketed comparison attributes to *rank* what
belongs to *regime*. Bucket jointly by rank **and** volatility regime, or the result is
unusable.

**Design consequence.** `P(fill)` and `E[value | fill]` decline *together* with rank, so
their product is far more convex than either alone. The response to "we cannot get near the
front in this symbol" is therefore **not** to quote smaller — it is **not to quote**. This is
also the strongest economic argument for the attributed-quoting rule of
[01](01-queue-position-and-fill-probability.md) §3.3: without a real rank measurement this
analysis cannot be performed at all.

---

## 6. Where each computation lives

| Computation | Fast path (fabric, ns) | Fabric-slow (µs, on chip) | Host (ms) | Research (offline) |
| --- | --- | --- | --- | --- |
| Book imbalance compare | ✅ S1 | | | |
| OFI accumulate (§3.1) | | ✅ one stage behind book | | |
| Volatility EWMA | | ✅ | | |
| `soft_stale` scrubber (§4.3) | gate bit ✅ S0 | ✅ 1.64 µs sweep | | |
| Stress / pull / fade decision | ✅ S0–S1 | | | |
| Threshold calibration | | | ✅ 1 kHz param push | |
| VPIN, regime classification | | | ✅ | |
| Mark-out curves (§2) | | | | ✅ nightly |
| Rank-conditional toxicity (§5) | | | | ✅ nightly |
| Symbol enable/disable | | | ✅ commit bit | recommended offline |

The partition follows one rule from
[04.06](../04-system-architecture/06-cpu-fpga-partitioning.md): **a computation belongs in
fabric only if the decision it feeds is made in nanoseconds.** Every metric in §3 whose
natural timescale exceeds a millisecond is a parameter source, not a signal. Spending a
trigger-path cycle to refine a minutes-scale input is the worst trade in this system.

---

## 7. What to measure in production

### 7.1 Fabric counters — the pickoff proxy the FPGA *can* compute

The fabric cannot compute a mark-out; it needs the future. It **can** compute the cheapest
useful proxy: fills arriving immediately after our side's top of book moved.

| Counter | Width | Semantics | Why |
| --- | --- | --- | --- |
| `fill_after_move_cnt[n]` | 32 × 4 | Free-running | Fills within `n` ∈ {64, 256, 1k, 4k} cycles of a top change on **our** side. **The pickoff bill, live** |
| `fills_total` | 32 | Free-running | The denominator |
| `ofi_at_fill_hist[b]` | 32 × 16 | Free-running | Signed OFI bucket at fill. Skew ⇒ we fill into flow |
| `widen_active_frac` | 16 | Live | Fraction of quoting time widened (§4.2). Near 1 ⇒ silently off |
| `soft_stale_pull_cnt` | 32 | Free-running | §4.3 firings, per reason |
| `fade_active_frac` | 16 | Live | §4.6 duty cycle |
| `ofi_sat_cnt` | 16 | Sticky + count | OFI saturation. **Must be zero.** Non-zero ⇒ §3.1 width bug |

Counter semantics and read-out per
[06.03](../06-operations/03-monitoring-and-telemetry.md) §2; these ride in `strat_stat`
through the existing `telemetry` block — never over a new path.

### 7.2 The log record and the host job

Every fill is logged on the DMA ring with the **book state at fill**: both sides' price and
quantity, `ofi`, `vol_ewma`, `q_ahead_est`, `depth_at_entry`, `cycle_cnt`, and the
requoted-vs-pulled-vs-faded decision the strategy took next. That last field is what makes
§4 auditable: without it you can measure toxicity but never whether your response helped.

The nightly host job runs §2.5 against the archived feed, produces `r(h)` per symbol, regime
and rank bucket, and writes a *proposed* parameter set. ⚠️ **The loop is not closed
automatically.** A parameter set derived from mark-outs reaches the fabric only through the
normal double-buffered commit with a human in the path
([04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §5,
[06.01](../06-operations/01-build-and-release.md)).

### 7.3 Alerts

| Condition | Severity | Action |
| --- | --- | --- |
| `r(1 ms)` negative for a symbol over a rolling window, `n` sufficient | **Page** | Disable the symbol; investigate before re-enabling |
| `fill_after_move_cnt[64] / fills_total` rises vs. baseline | **Page** | Cancel-path regression — [03](03-cancel-latency-and-pickoff.md), [06](06-timing-report-forensics.md) |
| `ofi_sat_cnt > 0` | **Page** | Arithmetic bug; §4.4 may be inverted. Kill first, diagnose second |
| `widen_active_frac > 0.9` sustained | Warn | Thresholds mis-set; the strategy is off and nobody noticed |
| `soft_stale_pull_cnt` spike across many symbols | Warn | `venue_busy` mis-tuned, or a real feed problem — [09](09-failure-modes-and-postmortems.md) |
| Mark-out curve changes shape category (§2.4) | Warn | Regime change. Re-fit; do not re-engineer |

---

## 8. Rules for this project

1. **`a(h)` is the only stochastic term in the P&L and its mean is negative.** Any model omitting it reports a profit for every strategy.
2. **No strategy is promoted on a simulated mark-out.** Real fills, or canary size.
3. **Mark-outs use the NBBO mid ex-self**, at the full horizon ladder, reported as a shape with a tail — never a single mean, never the raw book.
4. **The fabric computes no mark-outs.** It logs fills with book state; the host does the rest.
5. **OFI is the primary fabric toxicity signal** — adds and subtracts on events already decoded, leaky-integrated by arithmetic shift, saturating.
6. **All toxicity thresholds are absolute, per-symbol, host-precomputed.** No division, no normalisation in fabric.
7. **VPIN never touches the fast path.** A slow-path regime indicator at most.
8. **Aggressor side comes from the resting order's side via the order map.** No tick test, ever.
9. **`soft_stale` is a hard gate** ANDed at S0 beside `book_stale`, armed only when `venue_busy`, self-clearing on the next update.
10. **Pull one side, not both.** The side under pressure fills you; the other side just got better.
11. **On any fill, re-evaluate before requoting; the default is to widen.** Each fill reloads the fade counter.
12. **Never trade queue position for a size reduction until the priority rule is verified in writing** ([08.05](../08-nasdaq/05-ouch-5.0-order-entry.md)).
13. **If we cannot reach the front of the queue in a symbol, we do not quote it.** Rank-conditional toxicity makes the deep-queue product negative.
14. **`fill_after_move_cnt` and `ofi_sat_cnt` are reviewed daily.** They are this document's fast-path conscience, and they are free.

---

## Further reading

- [01-queue-position-and-fill-probability.md](01-queue-position-and-fill-probability.md) — `P(fill)`, and the rank §5 is conditional on
- [03-cancel-latency-and-pickoff.md](03-cancel-latency-and-pickoff.md) — the race behind §4.1 and the 1–10 µs mark-out
- [04-fixed-point-arithmetic-in-fabric.md](04-fixed-point-arithmetic-in-fabric.md) — saturation, shift-decay, division elimination for §3.1 and §4.2
- [07-jitter-sources-and-determinism.md](07-jitter-sources-and-determinism.md) — why the cancel-path tail, not its mean, sets the pickoff bill
- [08-market-open-and-close-dynamics.md](08-market-open-and-close-dynamics.md) — the regimes §2.5 and §5 must bucket by
- [09-failure-modes-and-postmortems.md](09-failure-modes-and-postmortems.md) — what a toxicity-driven loss looks like after the fact
- [../03-algotrading/01-market-microstructure.md](../03-algotrading/01-market-microstructure.md) — effective/realized spread, impact, the picked-off scenario
- [../03-algotrading/05-strategy-taxonomy.md](../03-algotrading/05-strategy-taxonomy.md) — which strategies this term dominates
- [../04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md) — `book_stale`, and the order map that gives §3.2 its side
- [../04-system-architecture/04-strategy-engine-on-fpga.md](../04-system-architecture/04-strategy-engine-on-fpga.md) — parameter table, double-buffered commit, S0 gating
- [../04-system-architecture/06-cpu-fpga-partitioning.md](../04-system-architecture/06-cpu-fpga-partitioning.md) — the partitioning principle §6 applies
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) — counter semantics for §7.1
- [../08-nasdaq/04-totalview-itch-5.0.md](../08-nasdaq/04-totalview-itch-5.0.md) — `E`/`C`/`P` semantics behind §3.2
- [../08-nasdaq/05-ouch-5.0-order-entry.md](../08-nasdaq/05-ouch-5.0-order-entry.md) — cancel/replace priority for §4.5
- [../08-nasdaq/07-fees-rebates-and-economics.md](../08-nasdaq/07-fees-rebates-and-economics.md) — the P&L decomposition §1 refines
