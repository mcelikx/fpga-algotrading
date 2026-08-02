# 03.05 — Strategy Taxonomy

> **Why this matters here:** an FPGA buys exactly one thing — **nanoseconds** — and it
> buys them at enormous cost in flexibility. A strategy whose edge is *prediction* gets
> nothing from that purchase; a strategy whose edge is *speed* gets everything. Getting
> this classification wrong is the most expensive mistake available in this project,
> because it is a mistake you make once, at the start, and discover eighteen months
> later.

---

## 1. The discriminator: speed edge vs. prediction edge

Every strategy sits somewhere on one axis, and it determines whether hardware is the
right tool.

| | **Speed edge** | **Prediction edge** |
| --- | --- | --- |
| Claim | "I will act on this known fact before you do" | "I know something about the future that you don't" |
| Horizon | Nanoseconds to milliseconds | Seconds to days |
| Information | **Public**, just-arrived, unambiguous | Derived, statistical, uncertain |
| Competition | A race with a small number of fast firms | A modelling contest with everybody |
| Decays because | Someone builds faster hardware | Everyone finds the same signal |
| Compute needed | Almost none — a comparison | Substantial — regressions, factors, optimisation |
| Marginal value of 100 ns | **Enormous** | Zero |
| Right platform | **FPGA** | CPU / GPU |

> **The project's founding assumption, stated plainly: we are building a machine that
> wins races over public information, not a machine that is smarter than the market. If
> a strategy proposal cannot be phrased as "when X becomes true on the wire, do Y,
> faster than anyone else", it does not belong in fabric.**

The corollary is liberating: the FPGA does not need to be clever. It needs a comparator,
a parameter table, and a very short path to the wire.

---

## 2. Strategy families

Ratings are **FPGA suitability**, not profitability. `★★★★★` = the FPGA is the reason
it works; `★☆☆☆☆` = the FPGA adds nothing.

### Passive market making — ★★★★★

Post two-sided quotes, earn the spread and the maker rebate, manage inventory, and above
all **avoid adverse selection**
([01-market-microstructure.md](01-market-microstructure.md) §5).

- **Edge**: queue position (speed to join a new level) plus speed to cancel a stale
  quote. Both pure latency. The cancel race in
  [02-order-types-and-matching-engines.md](02-order-types-and-matching-engines.md) §8 is
  the entire P&L; nothing else moves `f`, the toxic-fill fraction.
- **Hardware shape**: book event → compare against a per-symbol parameter set →
  emit/amend/cancel. Trivial arithmetic, brutal latency requirement.
- **This is the primary strategy for this project.**

### Aggressive liquidity taking / quote sniping — ★★★★★

When a resting quote goes stale relative to a signal you already have, take it before its
owner cancels — you are the counterparty to the market maker who lost the race in §8.

- **Edge**: pure latency, on the offensive side of the same race. The whole opportunity
  window is hundreds of nanoseconds.
- **Hardware shape**: signal event → threshold compare → IOC limit order. Simpler than
  market making: no inventory state, no resting risk, bounded exposure per action.
- **Note**: pays the *taking* fee, so per-trade edge must clear the fee, not just the
  spread.

### Cross-venue latency arbitrage — ★★★★★

The instrument's price moves on venue A; act on venue B before B's participants have
processed A's move.

- **Edge**: latency, plus **network topology** — as much a cabling and colo problem as a
  silicon one. The arbitrage window is the inter-venue propagation delay: physics,
  therefore fixed and small.
- **Cost**: multiple direct feeds, colo presences, order entry sessions, and the
  cross-connects between them. Infrastructure-heavy.
- **Fit for us**: architecturally identical to what we are building. Phase 2, once a
  single-venue path is proven.

### Feed-vs-quote arbitrage (direct feed vs. SIP) — ★★★☆☆

Trade against participants pricing off the consolidated feed while you price off direct
feeds ([01-market-microstructure.md](01-market-microstructure.md) §9).

- **Edge**: latency — but the specific gap has narrowed enormously as SIP processing
  improved and more participants moved to direct feeds.
- **Caution**: this family attracted sustained regulatory and public attention.
  Consuming a faster public feed is not unlawful — exchanges sell them to everyone — but
  strategies designed around *other participants' data disadvantage* need explicit
  compliance review before they are built.
- **Fit for us**: falls out of the architecture anyway; do not make it the thesis.

### Statistical arbitrage — ★☆☆☆☆

Multi-factor models, cointegration, mean reversion over seconds to days.

- **Edge**: prediction. Latency is irrelevant to the signal; only execution benefits, and
  milliseconds are plenty.
- **Why not FPGA**: matrix algebra, floating point, large state, frequent model changes —
  every property fabric is worst at. Correct platform is the CPU, with an FPGA (if at
  all) only as a low-latency execution layer for parent orders.

### Index / ETF arbitrage — ★★★★☆

An ETF's price diverges from its basket value; trade the divergence.

- **Edge**: **hybrid, and a textbook case for our architecture.** Basket weights and NAV
  computation are slow, complex, and change rarely. The *trigger* — "ETF bid is now above
  computed fair value + threshold" — is a single comparison that must happen in
  nanoseconds. CPU pushes per-instrument fair value and thresholds; FPGA compares
  incoming book updates against them and fires.
- **Complication**: the basket leg is a many-symbol, many-order problem with real leg
  risk. FOK/IOC discipline matters.

### Pairs / relative value — ★★☆☆☆

Two correlated instruments diverge; trade the spread. Mostly prediction (is the
divergence real?), partly speed (who gets the leg?). Same hybrid pattern as ETF arb with
a weaker speed component — justified only when the pair is tight enough that the
divergence is arbitrage rather than a bet.

### Order anticipation — ★★★☆☆

Detect the footprint of a large parent order being worked and trade ahead of its
remaining children. Pattern detection over order flow (prediction) plus reaction speed.

- ⚠️ **Regulatory sensitivity.** Inferring a large order from *public* market data is
  generally legitimate; acting on **non-public** knowledge of a customer order is not,
  and the boundary depends on your relationships and data sources. Requires compliance
  sign-off documenting exactly what data the strategy uses.
- **Fit**: implementable as a counting/threshold trigger, but the detection logic belongs
  on the CPU.

### Rebate capture — ★★★★☆

Post liquidity primarily to earn the maker rebate, aiming for a flat position. Queue
position (speed) plus fee-schedule optimisation. It is market making with the spread
component removed, so **adverse selection is an even larger fraction of the P&L** and the
cancel race is everything.

- ⚠️ Not a free lunch: the rebate is small and the adverse-selection cost is not. Any
  model must use a dated, verified fee schedule —
  [../08-nasdaq/07-fees-rebates-and-economics.md](../08-nasdaq/07-fees-rebates-and-economics.md).

### Auction strategies — ★★☆☆☆

Trade the opening/closing crosses using disseminated imbalance information. The decision
horizon is **milliseconds to seconds** — the accumulation window is long and nothing is
latency-bound in the nanosecond sense. CPU strategy; the FPGA is only the low-latency
order path near the cutoff.

### Momentum ignition — ✗ DO NOT BUILD

Deliberately initiating a price move — typically with orders you intend to cancel — to
induce other participants' algorithms to react, then trading against the reaction.
Closely related to **spoofing** and **layering**: entering orders without genuine intent
to trade in order to create a false impression of supply or demand.

**This is market manipulation. We do not build it, we do not prototype it, and we do
not accidentally approximate it.**

> **Verify:** manipulative and deceptive practices in securities are addressed by
> Securities Exchange Act §9(a)(2) and §10(b) with SEC Rule 10b-5, by FINRA Rules 2020
> and 5210, and by exchange rules; spoofing in commodities was explicitly defined by
> Dodd-Frank §747 (CEA §4c(a)(5)(C)). Firms have been fined and individuals prosecuted.
> Confirm current text with counsel — this note is orientation, not legal advice.

⚠️ **The design implication is concrete, not moral posturing.** A strategy posting orders
it does not intend to trade is indistinguishable *in the audit trail* from spoofing,
whatever its author intended. Therefore: every quote we post must be one we are willing
to be filled on at the moment we post it; **order-to-trade ratios are monitored and
alerted on** per strategy and per symbol, because a sharply rising ratio is either a bug
or a compliance problem and both need immediate attention; and cancels driven by *changed
market conditions* are legitimate while cancels driven by *the reaction our own order
provoked* are not — a distinction that must be visible in the strategy's design
documentation.

---

## 3. What a strategy looks like as hardware

**A strategy in fabric is a trigger condition over book state, plus a parameter table.
It is not a general computation engine, and any attempt to make it one will fail.**

```systemverilog
// The entire shape of a fast-path strategy. Combinational, one to two cycles.
//   book_*   : maintained incrementally by the book engine
//   p        : the ACTIVE parameter bank for this (strategy_slot, symbol) pair
//
// Note the arithmetic: compares, adds, and ONE multiply pair to avoid a divide.
always_comb begin
    // Imbalance test  (bid_sz - ask_sz)/(bid_sz + ask_sz) > p.imb_num/p.imb_den
    imb_fires = (p.imb_den * (book_bid_sz - book_ask_sz))
              > (p.imb_num * (book_bid_sz + book_ask_sz));

    spread_ok = (book_ask_px - book_bid_px) <= p.max_spread_ticks;
    depth_ok  = (book_bid_sz >= p.min_depth) && (book_ask_sz >= p.min_depth);
    pos_ok    = (position_q  <  p.max_long) && (position_q > p.max_short);
    state_ok  = (sym_state_q == SYM_CONTINUOUS) && p.enabled && !kill_q;

    fire      = imb_fires && spread_ok && depth_ok && pos_ok && state_ok;

    out_px    = book_bid_px + p.px_offset_ticks;   // no division anywhere
    out_qty   = p.clip_size;
end
```

That is genuinely all of it. The intelligence lives in `p`, and `p` is computed by the
CPU. The FPGA's contribution is that `fire` is true **150 ns after the causing bit
arrived at the PHY**, with an order leaving the die a few tens of nanoseconds later.
Constraints that fall out of this:

| Constraint | Reason |
| --- | --- |
| No division, no floating point | [../00-foundations/01-digital-logic-and-timing.md](../00-foundations/01-digital-logic-and-timing.md) §6 |
| No loops with data-dependent bounds | Determinism; and they do not synthesise into a fixed-latency path |
| Every threshold is a **table entry**, never a literal | Changing a number must not require a rebuild (§8) |
| Trigger evaluated on **every** book-mutating message | No conflation ([03-market-data-protocols.md](03-market-data-protocols.md) §8) |
| Strategy state is small and fixed | Position, own-order slots, queue-position counters — that's the list |
| The trigger fails **closed** | Any unknown/abnormal condition ⇒ `fire = 0`, and quotes pull |

---

## 4. The hybrid architecture — the recommended pattern

```
            ┌───────────────────────── CPU (slow path) ────────────────────────┐
            │                                                                  │
   history  │  signal models   risk appetite   fee schedule   inventory target  │
   ────────►│  volatility est. fair value      symbol universe  PnL/attribution │
            │            │                                                     │
            │            ▼                                                     │
            │   ┌───────────────────────┐                                      │
            │   │ PARAMETER GENERATION  │   millisecond–second cadence          │
            │   │ (validate, bound,     │                                      │
            │   │  version, sign)       │                                      │
            │   └──────────┬────────────┘                                      │
            └──────────────┼──────────────────────────────────────────────────┘
                           │  PCIe BAR write / DMA
                           │  atomic double-buffered commit  (§6)
   ════════════════════════▼══════════════════════════════════════════════════
            ┌───────────────────────── FPGA (fast path) ───────────────────────┐
            │                                                                  │
            │   ┌──────────┐   ┌────────┐   ┌───────────────┐   ┌───────────┐  │
   feed ───►│──►│ DECODE   │──►│  BOOK  │──►│ TRIGGER       │──►│ RISK GATE │──┼──► orders
            │   │          │   │        │   │ (§3, over the │   │ (hardware,│  │
            │   │          │   │        │   │  ACTIVE bank) │   │  non-byp) │  │
            │   └──────────┘   └────────┘   └───────────────┘   └───────────┘  │
            │        ~10-100 ns cumulative, fixed, no host involvement          │
            └──────────────────────────────────────────────────────────────────┘
                           │  fills, acks, rejects, telemetry (DMA up)
                           ▼
                     CPU accounting, reconciliation, audit trail
```

The contract between the halves:

| | CPU | FPGA |
| --- | --- | --- |
| Cadence | ms–s | ns |
| Owns | *What* to do and *under what conditions* | *When*, and *how fast* |
| Can it be wrong? | Yes — it is a model | No — it is a comparison |
| Can it be slow? | Yes | No |
| In the trade path? | **Never** | Always |

⚠️ **No trading decision may require a host round trip** — not a "rare" one, not a
"fallback" one. The moment a path exists where the FPGA waits for the CPU, that path gets
taken at the worst possible moment (a burst, a news event) and the system's real latency
becomes the CPU's tail latency. If the FPGA cannot decide, the correct action is **do
nothing and pull quotes**, never "ask the host".

---

## 5. Parameter tables

```
Parameter bank, per (strategy_slot × symbol_slot):

  ┌──────────────────────────────────────────────────────────────────┐
  │ enabled              1 b    master enable for this pair          │
  │ clip_size           16 b    shares per order                     │
  │ max_long / max_short 32 b   position bounds (strategy-level)     │
  │ px_offset_ticks      8 b    signed, where to quote vs. reference  │
  │ max_spread_ticks    16 b    do not quote when the book is wide    │
  │ min_depth           32 b    do not quote into a thin book         │
  │ imb_num / imb_den   16 b    imbalance threshold as a ratio        │
  │ fair_value          32 b    CPU-supplied reference (ETF arb etc.) │
  │ cooldown_cycles     16 b    minimum gap between actions           │
  │ generation          16 b    version tag — see §6                  │
  └──────────────────────────────────────────────────────────────────┘
```

Sizing rule: `N_STRATEGIES × N_SYMBOLS × sizeof(bank) × 2 banks`. That multiplies fast
and lands in BRAM/URAM alongside the order-reference table
([03-market-data-protocols.md](03-market-data-protocols.md) §3). Budget it explicitly
*before* the symbol universe is chosen. See
[../01-fpga-design/03-memory-and-storage.md](../01-fpga-design/03-memory-and-storage.md).

---

## 6. ⚠️ Atomic parameter updates

**The hazard:** a parameter set is many words and PCIe writes arrive one word at a time.
A strategy evaluating between the first and last write trades on a **half-old, half-new**
parameter set — a combination no human reviewed, possibly violating invariants the CPU
guaranteed (`max_long > max_short`, `imb_den != 0`), and appearing in no log. This is the
"it traded on a configuration that never existed" failure mode, and it is silent.

**The fix: double-buffer with a commit bit.**

```systemverilog
// Two banks. The fast path reads only the ACTIVE bank; the CPU writes only the
// SHADOW bank. A single-bit write flips them, atomically, at a message boundary.
logic        active_bank_q;              // 0 or 1
param_t      bank [2][N_SLOTS];

// ---- CPU side (control plane) -------------------------------------------
//   1. write every word of bank[~active_bank_q][slot]
//   2. write bank[~active].generation
//   3. write COMMIT register  →  commit_req pulse
// -------------------------------------------------------------------------

// Hardware validation of the SHADOW bank, continuously. Fail closed.
assign shadow_valid = (bank[~active_bank_q][slot].imb_den   != 0)
                   && (bank[~active_bank_q][slot].max_long  >  0)
                   && (bank[~active_bank_q][slot].clip_size <= HARD_MAX_CLIP)
                   && (bank[~active_bank_q][slot].clip_size != 0);

always_ff @(posedge clk) begin
    if (rst) begin
        active_bank_q <= 1'b0;
        commit_err_q  <= 1'b0;
    end else if (commit_req && msg_boundary) begin
        // Flip ONLY at a message boundary: a single strategy evaluation can
        // never straddle two banks.
        if (shadow_valid) active_bank_q <= ~active_bank_q;
        else              commit_err_q  <= 1'b1;    // sticky; alarm; NO flip
    end
end
```

Non-negotiable properties:

1. **One-bit commit** — a single flip-flop toggle, atomic by construction, no multi-word
   race possible.
2. **Commit only at a message boundary**, so one trigger evaluation reads one bank
   throughout.
3. **Hardware validates the shadow bank before accepting the commit.** The FPGA does not
   trust the CPU. A rejected commit is sticky, counted, and alarmed, and the old
   parameters stay live — the safe outcome.
4. **`generation` is readable back by the CPU.** "I sent it" is not "it is running".
5. **A parameter staleness watchdog**: the CPU refreshes a heartbeat register, and if it
   stops the FPGA disables affected strategies after a bounded time. A crashed parameter
   generator must not leave stale quotes in the market —
   [06-risk-and-compliance.md](06-risk-and-compliance.md) §10.
6. **Reset state is `enabled = 0` everywhere.** Trading begins only by affirmative action.

---

## 7. Backtesting vs. hardware simulation — the fidelity gap

They answer different questions, and treating either as the other is how strategies
that "work" lose money.

| | **Backtest (CPU, historical data)** | **Hardware simulation (cocotb/Verilator, pcap)** |
| --- | --- | --- |
| Answers | "Would this signal have been profitable?" | "Does this RTL produce the right bytes, in how many cycles?" |
| Fidelity on P&L | Low | None (it doesn't model P&L) |
| Fidelity on latency | None | **Cycle-exact** |
| Fidelity on fills | **The weak point** — see below | N/A |
| Speed | Fast — years of data | Slow — seconds of data |
| Use | Choose the strategy family and the parameter ranges | Verify the implementation and measure the budget |

### Where backtests lie, specifically

1. **Fill assumption.** "The price traded at my limit, so I filled." In a FIFO market you
   fill only if the queue ahead cleared. A backtest without an explicit queue-position
   model **overstates passive fill rates dramatically**, and the fills it invents are
   disproportionately *benign* — it under-samples exactly the toxic fills that determine
   profitability ([01-market-microstructure.md](01-market-microstructure.md) §5).
2. **No self-impact.** Historical data does not contain your orders; your quote would
   have changed what others did.
3. **Latency is assumed, not simulated.** The backtest sees a message at the venue
   timestamp; your hardware sees it later and acts later still.
4. **Survivorship in the data.** Halts, gaps, symbol changes, and bad prints are cleaned
   out of research data and very much present in production.
5. **Fees and rebates are frequently stale or wrong** — for a rebate-sensitive strategy
   that alone can flip the sign.

**Rule for this project:** the accepted evidence chain is **(a)** CPU backtest with an
explicit queue-position model to select family and parameter ranges, **(b)**
cycle-accurate hardware simulation on captured pcap for behaviour and latency, **(c)** a
live canary at minimum size to measure *real* fill rate and toxicity, **(d)** only then,
scale. No step is skippable, and (c) is the one that tells the truth. See
[../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md).

---

## 8. Capacity, alpha decay, and designing for change

Two facts that should shape the hardware before a strategy is chosen.

**Capacity is bounded.** A speed-edge strategy monetises a fixed number of races per day.
Doubling size does not double P&L — it increases impact and adverse selection until the
edge is consumed ([01-market-microstructure.md](01-market-microstructure.md) §6). These
are high-return-on-capital, **low-absolute-capacity** strategies: plan for many small
ones across many symbols, not one large one.

**Alpha decays.** Competitors get faster, venues change fee schedules and order types,
tick-size rules change, regimes shift. The half-life of a specific trading edge is far
shorter than the half-life of an FPGA design.

```
   Parameter change      hours          →  register write, no rebuild
   Threshold / logic     days–weeks      →  must NOT require a rebuild if avoidable
   New strategy family   months          →  partial reconfiguration, or a new bitstream
   Feed / protocol       years           →  full rebuild, expected
   Board / platform      many years      →  full port
```

⚠️ **A full Vivado build for an UltraScale+ trading design takes hours, and its timing
results are not perfectly reproducible across seeds.** Coupling routine strategy
adjustment to a rebuild couples a fast-changing thing to a slow, risky process — and the
pressure will be to skip verification. That is how bad bitstreams reach production.

**Therefore, design for reconfiguration without rebuild from day one:**

| Mechanism | Changes without a rebuild |
| --- | --- |
| Parameter tables (§5, §6) | Thresholds, sizes, enables, fair values, symbol universe |
| **Programmable trigger**: a small set of generic comparators wired to a configurable condition mask/opcode table | The *shape* of the condition, within a designed envelope |
| Multiple strategy slots, individually enabled | Which strategies run, and on which symbols |
| **Partial reconfiguration** of a strategy region | A genuinely new trigger implementation, without disturbing the feed/book/gateway/risk logic |

The generic-trigger idea deserves emphasis: rather than hardcoding one condition,
implement `M` comparators over a fixed menu of book quantities, each with a
table-supplied operand and operator, combined by a table-supplied boolean mask. It costs
LUTs and one pipeline stage, and buys the ability to change *what the strategy tests*
with a PCIe write — close to always the right trade in this domain.

Implementation is in
[../04-system-architecture/04-strategy-engine-on-fpga.md](../04-system-architecture/04-strategy-engine-on-fpga.md).

---

## 9. Rules for this project

1. **Fabric is for speed-edge strategies only.** A prediction-edge proposal is a CPU
   project, full stop.
2. **Primary strategy: passive market making**, optimised around the cancel race.
   Aggressive IOC taking is the natural second.
3. **The FPGA never asks the host for a decision.** Cannot decide ⇒ pull quotes.
4. **Every constant is a table entry.** No trading number is a literal in RTL.
5. **Parameter commits are one-bit atomic, validated in hardware, at a message
   boundary, with a readable generation tag and a staleness watchdog.**
6. **Reset means disabled.** Trading requires an affirmative enable.
7. **No momentum ignition, spoofing, or layering** — and order-to-trade ratios are
   monitored per strategy as a design requirement, not an afterthought.
8. **Evidence chain: queue-aware backtest → cycle-accurate sim → minimum-size canary →
   scale.** No shortcuts.
9. **Design for change without rebuild**: parameter tables, generic triggers, strategy
   slots, partial reconfiguration.

---

## Further reading

- [01-market-microstructure.md](01-market-microstructure.md) — the economics every strategy here is exploiting
- [02-order-types-and-matching-engines.md](02-order-types-and-matching-engines.md) — the cancel-race arithmetic behind the ★★★★★ ratings
- [06-risk-and-compliance.md](06-risk-and-compliance.md) — the gate that sits after every trigger
- [../04-system-architecture/04-strategy-engine-on-fpga.md](../04-system-architecture/04-strategy-engine-on-fpga.md) — implementing §3–§6
- [../04-system-architecture/06-cpu-fpga-partitioning.md](../04-system-architecture/06-cpu-fpga-partitioning.md) — implementing §4
- [../08-nasdaq/07-fees-rebates-and-economics.md](../08-nasdaq/07-fees-rebates-and-economics.md) — the fee schedule that decides whether rebate capture works
