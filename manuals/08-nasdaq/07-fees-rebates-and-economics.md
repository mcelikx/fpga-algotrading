# 08.07 — Fees, Rebates, and the Economics of Trading Nasdaq

> **Why this matters here:** on Nasdaq, the fee schedule *is* part of the strategy.
> A passive market-making strategy can capture zero spread on average and still be
> profitable on rebates alone — or capture spread beautifully and lose money to taker
> fees. The FPGA's job is not only to be fast; it is to be fast in a way that lands on
> the *right side* of the fee schedule. Every design choice in this file — post-only,
> maker/taker classification, per-fill attribution — exists because the economics
> demand it.

---

## 0. The one rule of this document

> ⚠️ **This file states no current fee, rebate, tier threshold, or cap from memory,
> and neither should you.** Exchange pricing changes by rule filing, sometimes
> monthly. A wrong rebate baked into a P&L model produces a strategy that is
> confidently, quietly unprofitable.
>
> The authoritative source for Nasdaq/BX/PSX transaction pricing is the
> **Nasdaq Price List (nasdaqtrader.com/Trader.aspx?id=PriceListTrading2)**, which is
> the operative summary of the filed fee schedule in the *Nasdaq Equity Rulebook*.
> Read it, in full, at the start of every month, and diff it.

What follows is the **structure**, which is stable and worth learning once.

---

## 1. Maker-taker, properly explained

```
    You POST a resting limit order that someone else trades against.
        → You ADDED liquidity.   You are the MAKER.   You receive a REBATE.

    You send an order that trades against a resting order.
        → You REMOVED liquidity. You are the TAKER.    You pay a FEE.
```

The exchange keeps the difference (fee − rebate) as net capture. The model exists to
buy displayed liquidity: paying makers to quote tightens spreads, which attracts
takers, which funds the rebate.

### The consequence that reshapes strategy design

| Strategy posture | Typical per-share economics |
| --- | --- |
| Pure passive (post, get filled, post the other side) | + rebate on both legs, + spread capture, − adverse selection |
| Pure aggressive (cross the spread) | − taker fee on both legs, − half spread each way, needs real alpha |
| Passive in, aggressive out | + rebate one leg, − fee the other; the common market-making shape |

> ⚠️ **For a passive strategy, the rebate can be the entire edge.** If you buy at the
> bid and sell at the bid a moment later, your spread capture is zero and your gross
> P&L is zero — but you collected two maker rebates. Many high-volume market-making
> operations are, in aggregate, rebate businesses with a spread-capture kicker.
>
> The corollary is brutal: **a change in the rebate schedule can turn a working
> strategy into a losing one overnight, with no change in your code, your latency, or
> the market.** Monitor rule filings the way you monitor latency.

### The other corollary: taker fees dominate aggressive strategies

Crossing the spread costs you the half-spread *plus* the taker fee. In a
one-cent-wide $30 stock, the half-spread is $0.005/share. A taker fee in the tenths
of a cent is a **meaningful fraction of that**. An arbitrage or latency-taking
strategy must clear the fee before it clears anything else. Latency does not reduce
the fee; it only increases how often you win the race you already decided to pay for.

---

## 2. Inverted (taker-maker) venues, and the queue-position argument

Nasdaq operates multiple US equity markets. Their **pricing models differ
deliberately**:

| Venue | Typical model | Purpose |
| --- | --- | --- |
| **Nasdaq** (The Nasdaq Stock Market) | Maker-taker | The primary listing venue; deep, high-volume book |
| **Nasdaq BX** | **Inverted** (taker-maker): pay to add, rebate to remove | Attracts takers with a rebate; short queues |
| **Nasdaq PSX** | Model has changed over time — **check the current Price List** | Differentiated pricing experiment |

> **Verify:** the current model and rates for each of the three markets in the
> *Nasdaq Price List*. Do not assume BX is still inverted or that PSX matches Nasdaq.
> Venues re-price to compete.

### Why anyone pays to post

On an inverted venue you **pay a fee to add liquidity** and **receive a rebate to
remove** it. That sounds backwards until you think about the queue:

```
    Nasdaq (maker-taker):   everybody wants to be at the front of the queue,
                            because being filled pays a rebate.
                            → Queues are LONG. Your fill probability is LOW.

    BX (inverted):          posting COSTS money, so fewer participants post.
                            → Queues are SHORT. Your fill probability is HIGH.
                            → Takers are drawn there because taking pays them.
```

The trade is explicit: on an inverted venue you pay to add, but you get **queue
position** and therefore **fill rate**. Whether that trade is good depends entirely
on your alpha:

| If your passive fills are… | Inverted venue is… |
| --- | --- |
| Mostly benign (you get filled by uninformed flow) | **Good** — more fills, and you pay for the privilege out of spread capture |
| Mostly adverse (you get filled right before the price moves against you) | **Bad** — you are paying a fee to be picked off faster |

> ⚠️ **Queue position on an inverted venue is a *concentrated adverse selection
> bet*.** The people taking on an inverted venue are being paid to take; some of them
> are being paid to take *because they know something*. Measure the realized spread
> on inverted-venue fills separately from primary-venue fills. If you cannot separate
> them, you cannot evaluate the venue.

The FPGA angle: a multi-venue quoting strategy needs **separate order-entry sessions,
separate risk attribution, and separate fill classification per venue**, because the
sign of the fee flips. A single global "rebate per share" constant is wrong the
moment you add BX.

---

## 3. Tiered pricing — how the schedule is actually structured

Nasdaq's fee schedule is not one number. It is a matrix.

### The dimensions

| Dimension | Typical values | Why it exists |
| --- | --- | --- |
| **Add vs. remove** | Maker rebate / taker fee | The core model |
| **Displayed vs. non-displayed** | Different rates, usually less favourable for hidden | Displayed liquidity is what the exchange is buying |
| **Tape** | A (NYSE-listed), B (regional-listed), C (Nasdaq-listed) | Nasdaq competes harder for some tapes than others |
| **Order type / routing strategy** | Different rates for routed, midpoint, retail, auction | Behaviour-specific pricing |
| **Volume tier** | Multiple tiers, best rate at the top | Volume incentive |
| **Qualification basis** | Usually a **percentage of total Consolidated Volume**, sometimes with add/remove sub-conditions | Scales with the market, not with a fixed share count |
| **Session** | Regular hours vs. extended hours vs. auction | Auctions are priced separately |
| **Attribution level** | MPID, or aggregated across a firm's MPIDs | Determines whether splitting MPIDs helps or hurts |

### How volume tiers work

A tier reads roughly like: *"achieve an average daily volume of shares added on
Nasdaq equal to at least X % of total Consolidated Volume during the month, and
optionally satisfy a secondary condition, to receive rebate R."*

Two structural points that matter more than the numbers:

1. **Qualification is measured over the calendar month, applied to the whole
   month's volume.** Crossing a tier threshold on the 28th re-prices everything you
   did since the 1st.
2. **Therefore your marginal rate and your average rate are different**, and the
   marginal rate near a threshold can be enormous.

```
    Suppose a tier boundary at V shares/month, and rebates r_low < r_high.

    Average rate below the tier:      r_low
    Average rate above:               r_high  (on ALL volume)

    Marginal value of the share that crosses the boundary:
        Δ = (r_high − r_low) × V_month
    …which is not a per-share number at all. It is a cliff.
```

> ⚠️ **This is the single most misunderstood thing in exchange economics.** Two
> failure modes follow directly:
>
> - **Under-trading:** you sit 3 % below a tier all month and leave a large,
>   knowable amount on the table.
> - **Over-trading:** you trade *unprofitably* to reach a tier. This can be correct —
>   the cliff can exceed the losses — but it must be an explicit, modelled decision
>   made by a human who understands it, not an emergent property of the algorithm.
>   And it is the kind of behaviour that draws scrutiny if it distorts the market.
>
> Build the tier tracker into your daily reporting on day one: **month-to-date
> qualifying volume, current tier, distance to the next tier, and the modelled value
> of closing that distance.**

> **Verify:** every threshold, every rate, every qualification condition, and every
> tape distinction in the *Nasdaq Price List*. They change by rule filing.

### The access fee cap as the ceiling

Rule 610(c) caps what a venue may charge to access a protected quotation, which puts
a ceiling on the taker fee and — since the rebate is funded from it — an indirect
ceiling on the maker rebate.

> ⚠️ The cap has been amended by the SEC in conjunction with the tick-size changes.
> **Do not use the historical $0.0030 figure.** See
> [06-regnms-and-compliance.md](06-regnms-and-compliance.md) §3.1 and verify against
> *SEC Regulation NMS (17 CFR 242.610)* and the current *Nasdaq Price List*.

---

## 4. Routing fees, and why post-only-no-route matters economically

If your order leaves Nasdaq to execute on another venue, you pay:

```
    Nasdaq's routing fee   +   (implicitly) the away venue's taker fee
                           +   you lose the Nasdaq rebate you would have earned
```

Routing fees vary by **routing strategy** (Nasdaq offers many named strategies) and
are frequently *worse* than Nasdaq's own taker fee, because Nasdaq is passing through
the away venue's cost plus its own.

### The economic case for book-only / post-only

| Instruction | Economic effect |
| --- | --- |
| **Book-only / non-routable** | Order never leaves Nasdaq. You never pay a routing fee. Worst case is a cancel. |
| **Post-only** | Order is guaranteed not to remove liquidity. You can never accidentally pay a taker fee. |
| **Post-only with price sliding** | You may rest at a different price — but you will rest, as a maker. |
| Routable | Convenience; you pay for it. |

> **Design rule for this project: the FPGA emits book-only orders, and passive quotes
> are post-only.** This is simultaneously the *simplest* hardware (no away-market
> state), the *safest* compliance posture (no Rule 611 exposure — see
> [06-regnms-and-compliance.md](06-regnms-and-compliance.md) §2), and the *cheapest*
> economics. Three arguments pointing the same way is unusual; take it.

> ⚠️ Post-only is not free. An order that would have locked or crossed is re-priced or
> rejected. If your strategy *needed* that fill, post-only converted a taker fee into
> a missed trade. Which is worse is an empirical question — measure the post-only
> rejection/slide rate and the opportunity cost, per symbol.

See [03-order-types-and-routing.md](03-order-types-and-routing.md) for the mechanics.

---

## 5. The full cost stack for an HFT operation

Everything below is a real line item. The point of the table is that **exchange
transaction fees are often not the largest one.**

| Cost category | What it is | Structure | Where to verify |
| --- | --- | --- | --- |
| **Exchange transaction fees / rebates** | Per-share, per-fill, maker or taker | Tiered, per-venue, per-tape, displayed/non-displayed | *Nasdaq Price List* |
| **Market data — TotalView** | Full depth-of-book for Nasdaq-listed | Per-subscriber and/or enterprise; separate for depth vs. top-of-book | *Nasdaq Global Data Products price list* on nasdaqtrader.com |
| **Market data — non-display use** | Using data in an algorithm rather than showing it on a screen | Separate, usually substantial, licence category | Nasdaq data policies |
| **Market data — per-user device fees** | Professional vs. non-professional subscriber counts | Per user per month | Nasdaq data policies |
| **Market data — redistribution** | If you pass data to affiliates or clients | Vendor/redistributor agreement + fees | Nasdaq data policies |
| **Other venues' data** | BX, PSX, NYSE, Arca, Cboe, MEMX, IEX depth feeds | Each its own schedule | Each venue's price list |
| **SIP data** | UTP/CTA consolidated feeds, if consumed | Plan-set fees | UTP/CTA Plan fee schedules |
| **Order entry ports** | OUCH / RASH / FIX ports | ⚠️ **Per port, per month** — and you will want many | *Nasdaq Price List*, ports section |
| **Market data ports / connectivity** | Direct data delivery ports, handoff bandwidth | Per port, per month, often by speed (1G/10G/40G) | *Nasdaq Price List* |
| **Colocation cabinet** | Rack space in Carteret | Per cabinet, per month, by size | *Nasdaq colocation service description* |
| **Colocation power** | kW committed to the cabinet | Per kW, per month; often the binding constraint | *Nasdaq colocation service description* |
| **Cross-connects** | Fibre from your cage to Nasdaq's handoff | Per cross-connect, per month | *Nasdaq colocation service description* |
| **Clearing** | Per-trade / per-share clearing broker charges | Negotiated; volume-sensitive | Your clearing agreement |
| **Settlement (NSCC/DTC)** | CNS, trade recording, position charges | Published schedules, passed through by your clearer | NSCC/DTC fee schedules |
| **SEC Section 31 fee** | Statutory fee on **covered sales** (sell side only) | Rate per $1,000,000 of covered sales; **the SEC adjusts it periodically, sometimes mid-year** | SEC fee rate advisories |
| **FINRA TAF** | Trading Activity Fee on covered sales | Per-share with a per-trade cap; rate changes | *FINRA By-Laws Schedule A* / FINRA TAF page |
| **CAT fees** | Consolidated Audit Trail funding | Executed-share-based model, billed through the SROs | CAT LLC fee filings; *the CAT NMS Plan* |
| **Regulatory / membership** | FINRA membership, exchange membership, SIPC, state fees | Annual + activity-based | FINRA, exchange rulebooks |
| **Hardware** | FPGA cards, servers, switches, optics, spares | Capex + depreciation | — |
| **People** | The largest line for most small firms | — | — |

> ⚠️ **Port fees multiply faster than anyone plans for.** A "small" deployment wanting
> redundancy across three Nasdaq markets, with two order-entry ports each for A/B
> resilience plus a separate cancel/drop-copy path, plus market-data ports on both
> A and B feeds, is already well into double-digit port counts *before* you add a
> second cabinet or a DR site. Model port count explicitly as a function of
> (venues × sessions × redundancy) — see
> [08-connectivity-and-colocation.md](08-connectivity-and-colocation.md) §4.

> ⚠️ **Section 31 and TAF are asymmetric: they apply to sales.** A round-trip
> market-making strategy pays them on every sell leg. They are unavoidable, are not
> reduced by latency, and must be in the per-share cost model. **Do not state the
> current rates from memory** — the SEC's Section 31 rate in particular has been
> adjusted mid-year by advisory more than once.

---

## 6. P&L decomposition for a market-making strategy

### The equation

For a round trip of `Q` shares:

```
    Net P&L  =   Spread capture
               + Rebate income
               − Adverse selection
               − Exchange & regulatory fees
               − Market impact
               − Amortised fixed cost
```

Written per share, using the standard microstructure decomposition:

```
    Let  M_t     = midpoint at the time of your fill
         M_{t+Δ} = midpoint Δ later (typically 1s, 5s, 30s — report several)
         P       = your execution price
         s       = +1 if you bought, −1 if you sold

    Effective half-spread   e = s · (M_t − P)        ← what you appeared to capture
    Realized  half-spread   r = s · (M_{t+Δ} − P)    ← what you actually kept
    Price impact / adverse
       selection            a = s · (M_t − M_{t+Δ}) = e − r
```

| Term | Meaning | Sign for a healthy maker | Does latency help? |
| --- | --- | --- | --- |
| **Effective half-spread `e`** | Distance from the midpoint at which you were filled | Positive | Indirectly — better queue position gets you filled at the touch |
| **Adverse selection `a`** | How much the midpoint moved against you after your fill | Positive (a cost) | **Yes, strongly** — this is the main thing latency buys |
| **Realized half-spread `r`** | `e − a`. What you keep before fees | Positive, and this is the real gross edge | Yes, via `a` |
| **Rebate** | Per-share maker rebate | Positive | **No.** Purely schedule + tier |
| **Fees** | Taker fee, routing fee, Section 31, TAF, CAT, clearing | Negative | **No** — except that fewer takes means fewer taker fees |
| **Impact** | Your own footprint moving the price | Negative | Slightly — smaller, better-timed orders |
| **Fixed cost** | Colo, ports, data, people, amortised per share | Negative | No |

> The single most important line in this table: **latency's economic contribution is
> almost entirely in the adverse-selection term and the fill-rate term. It does
> nothing at all for fees, rebates, or fixed cost.** If your strategy's P&L is
> dominated by rebate capture and its adverse selection is already small, more speed
> buys you very little, and the engineering money should go elsewhere.

### Why a strategy can have positive gross edge and negative net P&L

```
    Gross realized spread capture   +0.0031 /sh
    Maker rebate                    +  (verify)
    Taker fees on exits             −  (verify)
    Section 31 + TAF on sells       −  (verify)
    Clearing                        −  (verify)
    ───────────────────────────────────────────
    Net trading margin              ≈  small, possibly negative
    Fixed cost ÷ shares traded      −  (colo + data + ports + people)
    ───────────────────────────────────────────
    Actual P&L
```

This is not a hypothetical. **It is the normal state of an under-scaled equities
market-making operation.** The gross edge is genuinely there; the cost stack eats it.

> ⚠️ **A backtest that models only spread capture and ignores fees, rebates, tier
> effects, and queue position will always look profitable.** Any P&L model used to
> justify hardware spend must include the full stack of §5 and a realistic fill model
> — see [../03-algotrading/05-strategy-taxonomy.md](../03-algotrading/05-strategy-taxonomy.md).

---

## 7. Break-even analysis

Fixed costs are per-month and largely independent of volume. Trading margin is
per-share. So:

```
    Shares/month needed to break even  =        Fixed cost per month
                                          ────────────────────────────────
                                            Net trading margin per share
```

Two things fall out of that single division:

1. **Small net margins make the required volume explode.** If your net margin is a
   tenth of the size you assumed, your break-even volume is ten times larger.
   Sensitivity to the margin estimate is *hyperbolic*, not linear.
2. **Break-even volume interacts with the tier structure.** Higher volume improves
   the rebate, which improves the margin, which lowers break-even volume. This is a
   positive feedback that makes the business strongly increasing-returns-to-scale —
   and it is why exchange economics favour large participants.

Do this analysis in a spreadsheet with the *actual verified* rates, three scenarios
(pessimistic / base / optimistic net margin), and the tier feedback modelled. Then
compare against realistic achievable volume for the symbols you can actually quote.

> ⚠️ Do the break-even analysis **before** the FPGA build, not after. It determines
> whether the project should exist and at what scale. It also tells you the *maximum
> justified engineering spend*, which is the number this whole repository is
> implicitly betting against.

---

## 8. The economic case for the FPGA

Framed as: *here is how to justify the engineering spend, with numbers you can
actually measure.*

| Mechanism | What speed changes | How to quantify it |
| --- | --- | --- |
| **Queue position on new price levels** | When a new best price forms, orders arriving first sit at the front of the FIFO queue. Price-time priority makes this a pure latency race | Measure your **queue rank at rest** (from ITCH `Add Order` sequence around your own adds) and your **fill ratio by rank**. Fill probability falls steeply with rank |
| **Fill rate on passive quotes** | More fills at the same edge = linear increase in gross P&L | Fills per quote-minute, before/after |
| **Cancel-before-pickoff** | When the book moves, the trader who cancels first avoids being executed at a now-stale price | Measure adverse selection `a` on fills that occurred **within N µs of a book event**. That slice is your pickoff cost |
| **Reduced adverse selection generally** | Faster reaction to the signal that predicts the move | Realized-vs-effective spread gap, by latency bucket |
| **Determinism** | Bounded tail latency means bounded worst-case pickoff | p99.9 and max of your own tick-to-trade, correlated with `a` |
| **Higher achievable quote count** | Hardware handles more symbols at line rate without tail blowups | Symbols quoted at target spread without message-rate breaches |

### The honest framing

```
    Value of latency reduction ≈
          Δ(fill rate) × (realized spread + rebate) × volume
        + Δ(pickoff avoided) × (average pickoff loss) × pickoff frequency
```

Both terms are **measurable on your existing system before you build anything**.
Instrument first:

1. Log your own quote lifecycle with hardware timestamps.
2. Compute realized vs. effective spread, bucketed by your latency at the time.
3. Compute the fraction of adverse fills that occurred within a plausible
   reaction window.
4. Extrapolate: if your reaction time went from X µs to Y ns, how many of those
   fills would you have avoided?

> ⚠️ **Beware the infinite-speed fallacy.** The extrapolation above assumes everyone
> else stands still. They do not. What speed actually buys is *relative position in a
> queue of competitors*, and the marginal value of another 50 ns is highly non-linear:
> it is near-zero if you are already first, and near-zero if you are hopelessly last.
> The honest version of the business case names your competitive position, not just
> your absolute latency.

---

## 9. Measurement — the metrics to track per strategy

If it is not in this list with a number attached, you do not know whether the
strategy works.

| Metric | Definition | Why |
| --- | --- | --- |
| **Fill ratio** | Fills ÷ orders posted | Are you getting filled at all? |
| **Fill ratio by queue rank** | Same, bucketed by rank at rest | The direct latency-value signal |
| **Effective half-spread** | `s · (M_t − P)` per share | Apparent capture |
| **Realized half-spread** | `s · (M_{t+Δ} − P)`, several Δ | Actual gross edge |
| **Adverse selection cost** | `e − r`, per share and total | The term latency attacks |
| **Adverse fills within N µs of a book event** | Count and cost | The pickoff bill |
| **Rebate capture rate** | Maker fills ÷ total fills | Are you actually a maker? |
| **Maker/taker mix** | Shares added vs. removed, per venue | Drives the whole cost model |
| **Post-only slide/reject rate** | Slid or rejected ÷ post-only sent | Cost of the safe posture |
| **Cost per share** | All-in fees ÷ shares, by category | The denominator of everything |
| **Net margin per share** | Net P&L ÷ shares | The break-even input |
| **Month-to-date tier progress** | Qualifying volume, tier, distance to next | The cliff in §3 |
| **Cancel-to-trade ratio** | Cancels ÷ executions | Some venues price on it; surveillance watches it |
| **Message rate vs. port limit** | Peak and sustained, per port | Capacity + fee planning — see [08](08-connectivity-and-colocation.md) §4 |
| **Rejects by reason** | Per-check counter from the risk gate | Free diagnostics; see [09](09-risk-controls-and-limits.md) §4 |

> Every one of these is computable from the **fill and order-event stream** that the
> FPGA already produces for the audit trail. The marginal cost of the economics
> pipeline, given the CAT pipeline, is nearly zero. Build them together.

---

## Hardware implications

1. **Every fill must be classified maker vs. taker, in hardware or from the venue's
   own liquidity flag on the execution message.** Do not infer it later from order
   type — post-only slides and partial routing make inference wrong. Carry the flag
   from the OUCH execution message into the fill record. See
   [05-ouch-5.0-order-entry.md](05-ouch-5.0-order-entry.md).
2. **Post-only must be enforceable in fabric**, as a bit in the order record that the
   strategy sets and the risk gate can *force on* per symbol. A per-symbol
   `force_post_only` parameter is a one-bit field that makes an entire class of
   accidental taker fees impossible.
3. **A per-symbol `allow_taking` gate.** During bring-up, and for symbols where the
   strategy is passive-only, taking should be structurally impossible, not merely
   unintended.
4. **Fill attribution counters in fabric**: per symbol and per venue, count
   `shares_added`, `shares_removed`, `fills_maker`, `fills_taker`, and the
   corresponding notionals. These feed the cost model and the tier tracker directly,
   with no host-side reconstruction.
5. **Nanosecond timestamps on the fill event and on the market-data event that
   preceded it.** The adverse-selection measurement in §9 is only as good as the
   timestamp pair. This is the same instrumentation CAT requires — see
   [06-regnms-and-compliance.md](06-regnms-and-compliance.md) §9.
6. **Capture the book midpoint at fill time, in fabric.** Reconstructing `M_t` on the
   host from a replayed feed is possible but error-prone and expensive; the FPGA
   already has the top of book in registers when the fill arrives. Snapshot it into
   the fill record — it costs a few registers and makes the entire §6 decomposition
   exact.
7. **Per-venue fee sign is configuration, not a constant.** A `venue_id` in the fill
   record, and a host-side table of (venue, add/remove) → rate. An inverted venue
   flips the sign; hardcoding "rebate" anywhere is a bug waiting for BX.
8. **Message-rate counters per port**, windowed, readable — both to stay under the
   venue's throttle and because message rates drive port-count decisions and therefore
   a real monthly cost. See [09-risk-controls-and-limits.md](09-risk-controls-and-limits.md) §3.
9. **The reject-reason counters are economics instrumentation too.** A high post-only
   slide rate is a measurable opportunity cost, not just an operational curiosity.
10. **Lossless export of the fill/order-event stream.** The economics pipeline and the
    audit pipeline are the same DMA stream. A dropped record corrupts both the P&L
    attribution and the regulatory record — count drops, alarm on nonzero.

---

## Further reading

- [01-market-structure.md](01-market-structure.md) — the venue landscape the fees apply to
- [03-order-types-and-routing.md](03-order-types-and-routing.md) — post-only, book-only, routing strategies
- [05-ouch-5.0-order-entry.md](05-ouch-5.0-order-entry.md) — where the liquidity flag arrives
- [06-regnms-and-compliance.md](06-regnms-and-compliance.md) — the Rule 610 access fee cap
- [08-connectivity-and-colocation.md](08-connectivity-and-colocation.md) — ports, cabinets, and cross-connects as cost drivers
- [09-risk-controls-and-limits.md](09-risk-controls-and-limits.md) — the counters that feed the cost model
- [../03-algotrading/01-market-microstructure.md](../03-algotrading/01-market-microstructure.md) — queue position and adverse selection theory
- [../03-algotrading/05-strategy-taxonomy.md](../03-algotrading/05-strategy-taxonomy.md) — which strategies these economics favour
- [../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md) — the measurement discipline §9 depends on
