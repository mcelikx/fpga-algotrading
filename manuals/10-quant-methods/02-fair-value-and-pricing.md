# 10.02 — Fair Value and Pricing

> **Why this matters here:** `sym_strat_t.fair_value` is 32 bits. It is the single
> number that carries every model, every venue, every correlated instrument and every
> minute of research this firm does, across PCIe and into a comparator that fires in
> 12.8 ns. `STRAT_FAIR_VALUE_TAKE` does exactly one thing with it: `ask_px <
> fair_value − edge_ticks → buy`. Everything in this document exists to make that one
> comparison correct, and to bound how wrong it is allowed to be between refreshes.

---

## 1. What "fair value" means in this system, precisely

Not a philosophical price. A **contract**:

| Property | Value | Consequence |
| --- | --- | --- |
| Type | `price_t` — 32-bit unsigned, ITCH-native, 4 implied decimals | `$123.4500` is `32'd1234500`. Never converted, ever |
| Written by | `paramd` (host), into the **shadow** bank, committed atomically | [04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §5 |
| Parameter word | `PW_FAIR_VAL` = word 4. **Zero is invalid** | `param_table.sv` rejects it at write time |
| Refresh cadence | ~1 ms target | §7 |
| Maximum age before the fabric stops trading | `T_param_max` (e.g. 500 ms), enforced by the parameter watchdog | [04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §7 |
| What the fabric does with it | **one unsigned compare against `ask_px` or `bid_px`, ± `edge_ticks`** | nothing else |

> **RULE: `fair_value` is a *level*, and `edge_ticks` is its *error bar*.** They are
> written together, committed together, and neither is meaningful alone. A fair value
> without a matching confidence is a number that will be crossed against at the worst
> possible moment.

The rest of this document is the ladder of estimators that can occupy those 32 bits,
in increasing order of what they cost and what they can see.

---

## 2. The estimator ladder

| Rung | Estimator | Inputs | Refresh limit | Fabric-representable? | Fails when |
| ---: | --- | --- | --- | --- | --- |
| 0 | **Mid** `(Pb+Pa)/2` | our book | every event | yes, 1 add + 1 shift | one-sided book; tick-constrained names (§3) |
| 1 | **Weighted mid / microprice** | our book, both sizes | every event | yes, +1 cycle ([10.01](01-signal-construction.md) §4) | crossed/locked book; hidden liquidity |
| 2 | **Microprice, martingale-corrected** | book + a fitted state map | ~1 ms | **no** — needs a fitted lookup | regime shift invalidates the fit |
| 3 | **Multi-venue consolidated** | Nasdaq + other protected quotes | ~1 ms (host) | **no** — one feed decoder in fabric | feed skew between venues (§5.3) |
| 4 | **Lead-lag adjusted** | rung 3 + a leading instrument | ~1 ms (host) | **no** | the lead relationship inverts or the beta drifts |

**The fabric holds rung 0 and rung 1 for free and can hold nothing above them.**
Rungs 2–4 exist only as a 32-bit number arriving over PCIe. That asymmetry is the
entire architecture: *the FPGA's fair value is only as good as the host's clock rate,
and the host's fair value is only as good as the FPGA's willingness to wait for it.*

---

## 3. Rung 0: the mid, and why it is worse than it looks

```
mid = (bid_px + ask_px) >> 1        // exact only when the spread is an even
                                    // number of ITCH units
```

Four pathologies, all of which the fabric must gate on and all of which are already
bits in `book_top_t`:

| Pathology | Detection | Why the mid is wrong |
| --- | --- | --- |
| **One-sided book** | `!bid_valid \|\| !ask_valid` | The mid is undefined, not "the other side" |
| **Crossed book** | `crossed` (bid ≥ ask) | Transient feed artefact or a real cross; either way the mid is meaningless. **Never act on a crossed book** |
| **Locked book** | `bid_px == ask_px` | Mid is exact but carries zero information about direction |
| **Tick-constrained** | spread == 1 tick | The mid is a **step function** with only two reachable values per price level. It cannot express "the true price is 30 % of the way up this spread" — which is exactly the information a market maker needs |

The last one is the important one and it is structural, not statistical. In a
one-tick-wide name, the mid quantises the entire price signal into half-tick steps,
and the sub-tick information lives *only* in the queue sizes. That is what the
microprice recovers, and it is why rung 1 exists.

⚠️ **`(bid+ask) >> 1` truncates when the spread is an odd number of ITCH units.** With
4 implied decimals and a penny tick the spread is 100 units and the shift is exact —
but on sub-dollar names (tick = 1 ITCH unit) an odd spread truncates down by half a
unit, biasing the mid toward the bid on every odd spread. Either widen by one bit and
keep a half-unit of fixed-point, or state the bias and check it does not exceed
`edge_ticks`. Do not leave it undocumented.

---

## 4. Rungs 1–2: microprice

### 4.1 The naive weighted mid

```
P_micro = (Pb·Qa + Pa·Qb) / (Qb + Qa)  =  Pb + S·ρ ,   ρ = Qb/(Qb+Qa),  S = Pa−Pb
```

Derivation, sign convention, the inverted-formula trap, the cross-multiplied fabric
form and its exact DSP cost are all in
[10.01](01-signal-construction.md) §4. Not repeated here.

### 4.2 Why the naive form is a biased predictor

The weighted mid is a *description* of the current book, not an estimate of the future
mid. The quantity a fair value should approximate is

```
P_fair(t)  =  E[ mid(t + τ)  |  book state at t ]
```

and the naive weighted mid is not that expectation — it is a linear interpolation that
happens to be correlated with it. The correction is to *learn* the map from the book
state (imbalance bucket × spread bucket) to the expected forward mid, iterating until
the resulting price series is a martingale.

> **Verify:** the construction and its convergence properties from **Stoikov, "The
> Micro-Price: A High-Frequency Estimator of Future Prices"**. The published state
> discretisations are a starting point; the buckets that matter are venue-, symbol- and
> tick-regime-specific and must be refitted from your own data.

**Verdict: rung 2 is host-only, permanently.** It is a table lookup on a fitted map —
a fit that must be recomputed as the regime moves, over a state space too large to
justify in BRAM for a quantity that is then compared against a threshold anyway. The
host evaluates it and writes the *result* into `fair_value`.

### 4.3 The consequence for the fabric

If the host writes a martingale-corrected microprice at 1 ms cadence, and the fabric
*also* has a rung-1 microprice available for free, they will disagree — and the
disagreement is exactly the sub-millisecond book movement the host could not see.

| Situation | Who is right | What to do |
| --- | --- | --- |
| Book quiet since the last commit | host (rung 2 ≻ rung 1) | use `fair_value` |
| Book has moved a lot since the last commit | fabric's rung 1 | this is the case for `prim_micro` ([10.01](01-signal-construction.md) §4.3) |
| Book is crossed, one-sided, or `stale` | **neither** | do not trade |

⚠️ **Do not "blend" them in fabric.** A blend needs a weight, the weight depends on the
staleness *and* on the realised volatility, and now you have a multiply, a divide and a
parameter that nobody can reason about at 3 a.m. during an incident. Pick one per
symbol via `strat_select`, and let the host decide which.

---

## 5. Rung 3: multi-venue consolidation

### 5.1 The mechanism

US equities trade on many venues simultaneously, and a symbol's true price is a
property of the consolidated market, not of Nasdaq's book. Two consequences bind here:

- **Reg NMS order protection.** A protected quotation at a better price on another venue
  constrains where you may trade. Trading through it is a violation, not an
  inefficiency.
- **Information.** A move that starts on another venue reaches Nasdaq's book with a lag.
  A fair value built only from Nasdaq's book is, by construction, late whenever another
  venue leads.

> **Verify:** the definition of a protected quotation, the trade-through prohibition,
> the ISO exception, and the sub-penny rule from **SEC Reg NMS Rules 610, 611 and 612**
> and the current **Nasdaq Equity Rulebook**. See
> [08.06](../08-nasdaq/06-regnms-and-compliance.md). Rule numbers and their scope have
> been amended; check the current text rather than this table.

### 5.2 SIP versus direct feeds

| Source | What it gives | Latency character | Use here |
| --- | --- | --- | --- |
| **SIP (consolidated tape)** | NBBO and consolidated prints, all venues | Aggregated and redistributed — **structurally slower than the direct feeds it is built from** | Reference, compliance, reconciliation. **Never a trading signal** |
| **Direct venue feeds** | Each venue's full depth | Fastest available per venue | The only sound basis for a consolidated fair value |
| **Our fabric** | Nasdaq TotalView-ITCH only | 128 ns budget | The reaction, not the estimate |

> **Verify:** current SIP processing and distribution latencies from the **CTA/UTP plan
> operator statistics**. The gap versus direct feeds is the entire reason firms pay for
> direct feeds, and it is a published, changing number — do not quote one from memory.

⚠️ **The most expensive design error available here is building a fair value from the
SIP and then reacting to it in 128 ns.** You have spent the hardware budget racing to
respond to information that every competitor received earlier from a faster source.
The nanoseconds are wasted before the first gate toggles.

### 5.3 Consolidation is a clock problem, not a merge problem

Merging books is trivial. Merging them *at a common instant* is not.

| Problem | Effect on the consolidated fair value | Mitigation |
| --- | --- | --- |
| Different geographic feed sources → different propagation delays | The consolidated book is a mixture of instants; a fast move appears as a spurious cross or lock | Timestamp every venue's events on **our** clock at ingress; align on our receive time, not on venue timestamps |
| Venue clocks disagree | Venue timestamps are not comparable across venues | Use them for ordering *within* a venue only |
| One venue's feed gaps or lags | Its quotes go stale while still looking live | Per-venue staleness watchdog; drop that venue from the consolidation and **count it** |
| Odd lots, non-displayed, and away-market hidden liquidity | The consolidated displayed book is not the tradeable book | Accept it; size for it |

> **RULE: consolidation happens on the host, aligned on our own ingress timestamps, and
> every venue carries an independent staleness flag whose expiry removes it from the
> estimate.** A stale venue silently contributing to a fair value is the multi-venue
> analogue of the torn parameter read in
> [04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §5: a blend nobody
> designed, applied at full confidence.

⚠️ **Adding a second feed decoder to the fabric is not a consolidation feature — it is a
second full RX path** (transceiver, MAC, MoldUDP64 deframe, decoder, book, arbitration
into a single book port) and it reintroduces the arbitration jitter that
[04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §9 currently gets for
free. Cost it as a project, not as a signal.

---

## 6. Rung 4: lead-lag between correlated instruments

### 6.1 The mechanism

When two instruments track the same underlying value, price discovery does not happen
in both equally. One leads; the other follows with a lag set by the participants who
arbitrage them. If you can observe the leader before the follower's book reprices, you
have a fair value for the follower that its own book does not yet reflect.

Canonical pairs for a US equities desk:

| Pair | Direction of lead (typical, **not** guaranteed) | Why | Constraint |
| --- | --- | --- | --- |
| **Equity index future ↔ index ETF** | The future generally leads | Deeper, cheaper, one instrument versus a basket | Different data centres — the leg is a **geodesic latency problem**, not just a modelling one |
| **ETF ↔ its basket** | The ETF often leads the smaller constituents | Concentrated flow prices the ETF first | Needs the whole basket's books; creation/redemption mechanics set the arbitrage band |
| **Large-cap stock ↔ index ETF/future** | Ambiguous, and it **inverts on single-name news** | Idiosyncratic news leads from the stock | ⚠️ the sign flips exactly when the move is largest |
| **Dual-listed / cross-venue same symbol** | Whichever venue the flow hits first | Pure latency | This is rung 3, not rung 4 |

> **Verify:** which instrument leads, by how much, is an empirical and *time-varying*
> result. Establish it with a formal decomposition — **Hasbrouck information shares** or
> the **Gonzalo–Granger permanent-transitory decomposition** — on your own data, and
> refit it. Any lead-lag ordering asserted from memory is a liability.

### 6.2 The infrastructure reality for this project

Our fabric receives **one feed, from one venue, in one data centre**. A lead-lag
estimate that depends on an instrument trading in a different facility requires:

1. connectivity to that facility,
2. a low-latency inter-facility link, and
3. an honest accounting of that link's one-way latency against the follower's reaction
   window.

> **Verify:** inter-datacentre one-way latencies (e.g. Carteret ↔ Chicago-area
> equity-index venues) from your carrier's contracted figures and your own measurements.
> These are competitive, contracted numbers that change; never quote a remembered one.
> Colocation and cross-connect mechanics are in
> [08.08](../08-nasdaq/08-connectivity-and-colocation.md).

⚠️ **If the inter-facility link latency exceeds the follower's reaction window, the
lead-lag signal has no trading value no matter how good the statistics are.** Everyone
closer to the leader saw it first. This is an infrastructure question that must be
answered *before* the modelling question, and it is regularly answered in the wrong
order.

### 6.3 Where it lands

**Host, at millisecond cadence, compiled into `fair_value`.** The fabric never learns
that a second instrument exists. It sees a number that moved.

⚠️ There is one structural exception, and it is expensive: a strategy that reacts to
symbol A by quoting symbol B breaks the "one message affects exactly one symbol"
invariant that gives us zero arbitration and zero jitter. The bounded structure for it
— a fixed fan-out table, K replicated comparator banks, K `ord_req` ports into a
fixed-priority arbiter — is specified in
[04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §9. Cost: K× the S1
logic plus one cycle. Pay it explicitly or not at all.

---

## 7. The staleness contract

### 7.1 The problem stated as arithmetic

The fabric compares a price that is up to `Δt` old against a book that is current. The
error is whatever the true fair value did during `Δt`:

```
error(Δt)  ≈  σ_1ms · √(Δt / 1 ms)        (diffusive approximation)
```

`edge_ticks` must dominate that error, or the strategy systematically takes liquidity
into moves it cannot see:

```
edge_ticks   >   k · σ_1ms · √(Δt_max / 1 ms)   +   (adverse selection)  +  (fees)
```

with `k` set by how much of the error distribution you refuse to trade through.

> **RULE: `edge_ticks` is not a profit target. It is a staleness budget plus an
> adverse-selection charge plus the fee stack.** Any profit above that is what is left
> over. Sizing it as "how much I want to make" inverts the causality and produces a
> parameter that is too small on exactly the volatile days when it needed to be
> largest. Fee and rebate decomposition is in
> [08.07](../08-nasdaq/07-fees-rebates-and-economics.md).

### 7.2 ILLUSTRATIVE staleness cost

> **ILLUSTRATIVE** — the shape only. `σ_1ms` must be measured per symbol per
> time-of-day bucket from your own book history.

| Refresh cadence `Δt_max` | Staleness error at `σ_1ms = 0.2` ticks | Minimum `edge_ticks` at `k = 3` (before fees and adverse selection) |
| --- | ---: | ---: |
| 1 ms | 0.20 ticks | 0.6 |
| 10 ms | 0.63 ticks | 1.9 |
| 100 ms | 2.0 ticks | 6.0 |
| 500 ms (`T_param_max`) | 4.5 ticks | 13.4 |

**Read the bottom row as a design statement.** At the watchdog limit, the edge required
to trade safely on a stale fair value exceeds any edge that exists in a liquid
tick-constrained name. The parameter watchdog is not a nicety; by the time it fires,
the strategy has already been unprofitable for a long while. See
[10.05](05-parameter-calibration.md) §7.

⚠️ **The diffusive approximation understates the tail.** Real intraday price changes are
fat-tailed and the large moves cluster — so the worst staleness error arrives in bursts,
correlated across symbols, at exactly the moment your `paramd` process is most loaded.
Size for the tail, and make the *cadence* a function of the regime rather than a
constant ([10.05](05-parameter-calibration.md) §4).

### 7.3 The asymmetry that makes staleness dangerous

`STRAT_FAIR_VALUE_TAKE` **crosses the spread**. Compare the two failure directions:

| Direction of the error | Result | Bound |
| --- | --- | --- |
| `fair_value` too **conservative** (edge looks smaller than it is) | We do not trade | Opportunity cost. **Bounded** |
| `fair_value` too **aggressive** (edge looks larger than it is) | We cross the spread, paying the taker fee, into a market that is moving away | The adverse move plus the spread plus the fee, on the full order size. **Fat-tailed** |

And the correlation is the wrong way round: a fair value is *most* stale when the market
is moving *fastest*, which is when the aggressive error is largest. This is the same
structure as the pickoff asymmetry in
[09.01](../09-deep-dives/01-queue-position-and-fill-probability.md) §5.1, arriving from
the other side of the book.

> **RULE: when in doubt, the fair value is wrong in the direction that stops us
> trading.** `paramd` biases toward the conservative side under uncertainty, and any
> confidence widening applies to `edge_ticks` immediately — not on the next scheduled
> recalibration.

---

## 8. How the number actually gets there

```
   minutes ─▶ paramd : fit the model, choose the estimator rung per symbol,
                       set strat_select, universe, enables
                          │
   1–10 ms ─▶ paramd : consolidate venues, apply the lead-lag adjustment,
                       recompute fair_value and edge_ticks
                          │
                          │  1. DMA-write changed rows      → SHADOW bank only
                          │  2. read back the XOR checksum  → ⚠️ MANDATORY
                          │  3. write commit_mask           → one cycle, atomic
                          │  4. read active_bank_q          → confirm
                          ▼
                 param_table (double-buffered, per-symbol bank bit)
                          │
   12.8 ns ─▶  FPGA  :  ask_px < fair_value − edge_ticks  ?  BUY
                        bid_px > fair_value + edge_ticks  ?  SELL
```

The mechanism, the torn-read failure it prevents, and the read-back requirement are in
[04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §5 and
`rtl/strategy/param_table.sv`. Three points specific to fair value:

1. **`fair_value` and `edge_ticks` are different words** (`PW_FAIR_VAL`, `PW_EDGE`) and
   are therefore written by *different* DMA words. They must be in the **same commit**.
   A new fair value applied against an old edge is a strategy nobody designed — the
   exact failure class §5 of that document is about.
2. **Multi-symbol atomicity matters here more than anywhere else.** A basket or pair
   fair value updated on one leg and not the other is a directional bet the model never
   made. `commit_mask` exists for this; use it.
3. **Zero is invalid** and rejected at write time. A `fair_value` of 0 would make
   `bid_px > fair_value + edge_ticks` true for every symbol simultaneously — a
   market-wide sell. The word-level validity check in `param_table.sv` is the thing
   standing between a `paramd` bug and that outcome.

---

## 9. ⚠️ Fair-value failure modes

Each of these produces *legal, individually-plausible orders* and therefore passes the
risk gate. The risk gate bounds the size of the loss; it does not prevent it.

| Failure | Symptom | Defence | Layer |
| --- | --- | --- | --- |
| `fair_value = 0` or unwritten | Every symbol screams "sell" | Word validity check rejects at write time; `params_valid` gate | RTL |
| Anchored to a **stale book snapshot** | Systematically lags; loses on every take | `book_seq` stamped into the log record; host compares against its own book age | Host |
| Written **during a halt or auction** | Reopens against a price from a different regime | `GATE_SYM_NOT_OPEN`; invalidate fair value on any state transition into/out of `TRADE_HALTED`/`TRADE_AUCTION` | Both |
| Outside the **collar or LULD band** | Every order rejects at the risk gate — looks like a risk bug, is a model bug | Host clamps to the band *before* writing; `RISK_PRICE_COLLAR` / `RISK_LULD_BAND` counters rise together | Both |
| Correct level, **wrong symbol slot** | One symbol quoted at another's price. Catastrophic and obvious | Slot is part of the DMA address; checksum covers it; `metricsd` alerts on `\|fair_value − mid\| > N` ticks | Host |
| Frozen because `paramd` died | Trades on a fossil | Parameter watchdog clears `strat_enabled` after `T_param_max` | RTL |
| **Sign-inverted** microprice weighting | Confidently wrong in the predictable direction | Forward-mark sign check before deployment ([10.03](03-statistical-foundations.md) §2) | Host |
| Venue dropped from consolidation without notice | Silently degrades to a worse estimator | Per-venue staleness flag + a counter; alert on the *flag*, not on the P&L | Host |

> **RULE: a fair-value estimator ships with a `|fair_value − mid|` histogram in
> telemetry, reviewed daily.** It is the cheapest possible detector for six of the eight
> rows above and it costs one BRAM. Counter semantics in
> [06.03](../06-operations/03-monitoring-and-telemetry.md).

---

## 10. Rules for this project

1. **`fair_value` is a level and `edge_ticks` is its error bar.** Written together,
   committed together, never separately.
2. **`edge_ticks` = staleness budget + adverse selection + fees.** Not a profit target.
3. **The fabric holds rung 0 and rung 1 only.** Martingale-corrected microprice,
   multi-venue consolidation and lead-lag are host-side, permanently.
4. **Never build a trading fair value from the SIP.** It is structurally slower than the
   direct feeds it is built from; racing to react to it wastes the entire budget.
5. **Consolidate on our own ingress timestamps**, and give every venue an independent
   staleness flag whose expiry removes it from the estimate and increments a counter.
6. **Establish lead-lag empirically and refit it.** The sign inverts on single-name
   news — precisely when the move is largest.
7. **Answer the infrastructure question before the modelling question.** If the link is
   slower than the reaction window, the signal is worthless regardless of its `R²`.
8. **Under uncertainty, bias the fair value toward not trading.** The conservative error
   is bounded; the aggressive one is fat-tailed and correlated with volatility.
9. **Zero is invalid, out-of-band is clamped by the host, and both are counted.**
10. **Never blend the host and fabric estimates in fabric.** Select one per symbol via
    `strat_select`.
11. **Ship the `|fair_value − mid|` histogram** and review it daily. It is the model's
    only production error bar.

---

## Further reading

- [README.md](README.md) — the tier index and the FPGA/host division of labour
- [01-signal-construction.md](01-signal-construction.md) — the microprice arithmetic and its exact fabric cost
- [03-statistical-foundations.md](03-statistical-foundations.md) — proving an estimator is better than the mid, and by how much
- [04-backtesting-and-simulation.md](04-backtesting-and-simulation.md) — evaluating a fair value against forward marks without fooling yourself
- [05-parameter-calibration.md](05-parameter-calibration.md) — the cadence, the validity gate, and the watchdog
- [../03-algotrading/01-market-microstructure.md](../03-algotrading/01-market-microstructure.md) — spread, depth, adverse selection
- [../03-algotrading/03-market-data-protocols.md](../03-algotrading/03-market-data-protocols.md) — what a second feed would cost to decode
- [../04-system-architecture/04-strategy-engine-on-fpga.md](../04-system-architecture/04-strategy-engine-on-fpga.md) — the parameter table, the commit protocol, the watchdog
- [../04-system-architecture/06-cpu-fpga-partitioning.md](../04-system-architecture/06-cpu-fpga-partitioning.md) — the DMA path and its latency
- [../08-nasdaq/02-sessions-auctions-and-halts.md](../08-nasdaq/02-sessions-auctions-and-halts.md) — the state transitions that invalidate a fair value
- [../08-nasdaq/06-regnms-and-compliance.md](../08-nasdaq/06-regnms-and-compliance.md) — protected quotations, trade-through, sub-penny
- [../08-nasdaq/07-fees-rebates-and-economics.md](../08-nasdaq/07-fees-rebates-and-economics.md) — the fee stack inside `edge_ticks`
- [../08-nasdaq/08-connectivity-and-colocation.md](../08-nasdaq/08-connectivity-and-colocation.md) — the inter-facility latency that gates lead-lag
- [../09-deep-dives/01-queue-position-and-fill-probability.md](../09-deep-dives/01-queue-position-and-fill-probability.md) — the passive-side mirror of §7.3
