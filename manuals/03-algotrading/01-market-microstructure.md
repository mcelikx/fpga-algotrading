# 03.01 — Market Microstructure

> **Why this matters here:** the sub-microsecond budget only pays for itself because
> of one economic fact — **queue position at a price level is a scarce, valuable
> asset, and it is allocated by arrival time**. Everything in this document exists to
> explain why nanoseconds convert into dollars, and what the market's structure
> forces our hardware to look like.

This tier is venue-neutral. Nasdaq-specific rules, sessions, order types and fees
live in [../08-nasdaq/](../08-nasdaq/) — learn the concept here, get the exact
behaviour there.

---

## 1. The limit order book

A **limit order book (LOB)** is two priority queues facing each other: buy orders
(**bids**) sorted by descending price, sell orders (**asks/offers**) sorted by
ascending price. Within a price level, orders are ordered by the venue's allocation
rule — for US equities, by arrival time.

```
        AAPL — displayed book, one venue only        (prices are ×10⁻⁴ USD)
  ───────────────────────────────────────────────────────────────────────
    orders   size      BID    │    ASK      size   orders
  ───────────────────────────────────────────────────────────────────────
                              │  1 908 800   1 400     6     ask level 3
                              │  1 908 700     900     3     ask level 2
                              │  1 908 600     500     2  ◄─ BEST ASK  (L1)
      4        700  1 908 500 │                           ◄─ BEST BID  (L1)
      7      1 200  1 908 400 │
      3        900  1 908 300 │
  ───────────────────────────────────────────────────────────────────────
    spread     = 1 908 600 − 1 908 500 = 100   ($0.0100 — exactly one tick)
    mid        = 1 908 550                     ($190.8550)
    microprice = 1 908 558                     (see §3)
    imbalance  = (700 − 500) / 1 200 = +0.167  (bid-heavy)
```

The book is also an **economic object**. Each resting order is a free option its
owner has written to the market: exercisable by anyone, at any time, at no premium.
The owner is compensated by the spread and the maker rebate, and is harmed when
someone exercises precisely because the quote has become mispriced. That asymmetry —
§5 — is the whole game.

| Term | Definition | On the fast path |
| --- | --- | --- |
| Best bid | Highest price anyone will pay | Register, 32-bit |
| Best ask | Lowest price anyone will sell at | Register, 32-bit |
| Spread | `ask − bid`, in ticks or price units | Subtract; never divide |
| Mid | `(bid + ask) / 2` | ⚠️ half-tick — see below |
| Depth | Total resting size at a level, or cumulative to N levels | Maintain incrementally |
| Imbalance | `(bid_sz − ask_sz) / (bid_sz + ask_sz)` | Avoid the divide — see §3 |
| NBBO | Best bid/offer **across all venues** | Requires all direct feeds; see §9 |
| Locked market | `bid == ask` | Legal transiently; not quotable |
| Crossed market | `bid > ask` | Almost always a stale/gapped feed — alarm on it |

> ⚠️ **The mid is not representable at tick granularity.** With a one-tick spread the
> midpoint lands on a half tick. Carry prices internally at **2× the ITCH scale**
> (i.e. 5 implied decimals) wherever a midpoint is computed, or carry the mid as
> `bid + ask` un-halved and double every threshold you compare it against. Truncating
> the mid silently biases every midpoint-relative decision in one direction.

---

## 2. Price-time priority, and what queue position is worth

US equity venues run **price-time (FIFO) priority** in continuous trading:

1. Better price always trades first.
2. At the same price, earlier arrival trades first.
3. Displayed size generally trades ahead of non-displayed size at the same price.

> **Verify:** the exact priority ranking — including how displayed, reserve,
> non-displayed and pegged interest interleave at one price — is venue rule text.
> See the Nasdaq Equity Rulebook (Equity 4, Rules 4702/4703) and
> [../08-nasdaq/03-order-types-and-routing.md](../08-nasdaq/03-order-types-and-routing.md).

Consider our order resting at the best bid with **Q shares ahead of it** in the
queue. Those Q shares must be either executed or cancelled before a single one of
our shares trades. So:

```
P(fill before the level is cleared or the price moves away)
    = f( Q_ahead , arrival rate of aggressive sell volume , cancel rate ahead of us )
```

Two consequences that people consistently underestimate:

**(a) The value of position is convex, not linear.** 50 000 shares ahead versus
40 000 barely matters. 200 ahead versus 0 changes everything — at the front you fill
on *every* incoming marketable order, including the small, uninformed ones.

**(b) Deep queue position is adversely selected by construction.** To reach an order
behind 50 000 shares, the market must push 50 000 shares of aggressive flow through
that level, and large aggressive volume is *disproportionately informed*. Queue
position does not just change *how often* you fill — it changes *the conditional
distribution of what happens after you fill*.

**This is the latency argument, stated economically.** When a new price level is
created — a level that did not exist a microsecond ago — the queue is empty and
priority is assigned purely by arrival order. Whoever's order lands first owns
position 1. That race is decided in tens to hundreds of nanoseconds. An FPGA does not
make our forecasts better; it makes us first in a queue whose front is worth
materially more than its back.

The same argument applies in reverse to cancels — see
[02-order-types-and-matching-engines.md](02-order-types-and-matching-engines.md) §9.

---

## 3. Microprice and imbalance

The mid is a bad estimator of the next trade price when the book is lopsided. The
**microprice** (size-weighted midpoint) weights each side's price by the *opposite*
side's size:

```
microprice = (P_bid × Q_ask  +  P_ask × Q_bid) / (Q_bid + Q_ask)
```

A large bid and a small ask pull it toward the ask — the thin side gets consumed
first. In the ladder above: `(1908500×500 + 1908600×700)/1200 = 1 908 558`, 8 units
above the mid, leaning up. **Order book imbalance** `I = (Q_bid − Q_ask)/(Q_bid +
Q_ask)` is the same signal normalised to `[−1, +1]` — the most-used short-horizon
predictor in equity microstructure, and the most crowded. Assume every competitor
computes it.

> ⚠️ **Do not put a divider on the fast path.** Both formulas divide, and integer
> division in fabric is many cycles and wide. Restructure into a comparison:
> to test `I > θ` with `θ = a/b` (`a`,`b` positive integers from the parameter table),
> test `b·(Q_bid − Q_ask) > a·(Q_bid + Q_ask)` — two multiplies (DSP, 1–2 cycles) and
> a compare. Same for the microprice: compare cross-multiplied forms, or maintain a
> reciprocal lookup of `1/(Q_bid+Q_ask)` in BRAM if you truly need the value rather
> than a comparison. See
> [../00-foundations/01-digital-logic-and-timing.md](../00-foundations/01-digital-logic-and-timing.md) §6.

---

## 4. Effective spread, realized spread, and impact

Quoted spread is what you see. Effective spread is what you paid. Realized spread is
what the maker actually kept.

| Measure | Formula (D = +1 buy, −1 sell; M = mid at order time) | Answers |
| --- | --- | --- |
| Quoted spread | `ask − bid` | What the screen advertises |
| Effective spread | `2 · D · (P_trade − M)` | What the taker actually paid, round-trip equivalent |
| Realized spread | `2 · D · (P_trade − M_{t+Δ})`, Δ ≈ 1 s–5 min | What the maker kept after the price moved |
| Price impact | `effective − realized` = `2 · D · (M_{t+Δ} − M)` | The information content of the trade |

The identity that matters:

```
maker gross revenue  =  realized spread  =  effective spread  −  price impact
```

A market maker does not earn the quoted spread; it earns the quoted spread **minus
adverse selection**, and half of it can vanish into impact on a well-informed name.
Effective spread is usually *narrower* than quoted (midpoint executions, hidden price
improvement, size inside the NBBO), so quoted spread alone is a poor profitability
input.

---

## 5. Adverse selection — the concept that governs everything

**The single most important idea for a market maker.** Formally: your counterparty
chooses when to trade with you, and they choose the moments when your quote is wrong.
You are short an option and the holder exercises it optimally.

### The picked-off scenario, step by step

```
t0     Our bid rests at 1 908 500, 500 shares, position 1 in queue.
       Fair value (our estimate) is 1 908 550. We expect to buy 0.5 ticks cheap.

t1     A large aggressive buyer lifts offers on three other venues.
       True fair value is now ~1 909 100. Our bid at 1 908 500 is stale and
       generous by ~6 ticks.

t2     Every fast participant who saw t1 tries to do exactly two things:
         (a) sell to our stale bid   — they are taking us
         (b) cancel their own bid    — they are us, but faster

t3a    If our cancel wins the race: we lose nothing. Cost = one cancel message.
t3b    If their sell wins the race: we buy 500 shares at 1 908 500 with fair
       value at 1 909 100. Instant mark-to-market loss ≈ 500 × 600 units
       = $30.00 on a single fill, against a captured spread of a few dollars.
```

The economics: winning the spread is worth *half a tick*; being picked off costs
*several ticks*. A market maker can be right on 95 % of fills and still lose money if
the other 5 % are all adversely selected. **Latency is not about capturing more
spread; it is overwhelmingly about not paying that 5 %.**

Corollaries that shape the hardware:

- The **cancel path is at least as latency-critical as the order-entry path**, and
  often more. It is a defensive weapon.
- A **stale quote is worse than no quote.** Any condition where the strategy cannot
  update its view (feed gap, sequence reset, parameter update in flight, inconsistent
  book) must default to *pulling quotes*, not to holding them.
- **Order flow toxicity** — the informed fraction of counterparty flow — is a property
  of a symbol, a time of day, and a venue. It spikes at the open, on news, and around
  index events. The strategy must be able to widen or withdraw from a CPU parameter.

> **Verify:** VPIN and similar toxicity metrics are academic constructions with
> contested empirical support (Easley, López de Prado & O'Hara, 2012, and subsequent
> critiques). Treat any toxicity threshold as a fitted parameter, not a constant.

---

## 6. Market impact

Trading moves the price against you: a **temporary** component (liquidity consumption,
decays as the book refills) and a **permanent** one (the information your trade
revealed). Impact of a parent order is strongly concave in size, commonly modelled as
roughly proportional to `√(Q / ADV) × σ` — the "square-root law".

> **Verify:** the square-root law is an empirical regularity (Almgren et al.; Tóth et
> al.), not a rule with a canonical coefficient. Fit any constant on our own fills.

Impact matters less directly at our clip sizes but matters enormously for **capacity**:
it is why a profitable low-latency strategy stops scaling. See
[05-strategy-taxonomy.md](05-strategy-taxonomy.md) §8.

---

## 7. Tick size and queue dynamics

The **tick** is the minimum price increment. Its size *relative to the spread* is the
single biggest determinant of what the book looks like and which skills pay.

Under Reg NMS Rule 612 the baseline US equity quoting increment is $0.01 for stocks
priced at or above $1.00, and $0.0001 below $1.00.

> **Verify:** the SEC adopted amendments to Rule 612 in September 2024 introducing a
> sub-penny ($0.005) quoting increment for "tick-constrained" NMS stocks, together
> with a reduction of the Rule 610 access fee cap. Compliance dates have been subject
> to extension and litigation. **Check the current effective state of Rule 612 and
> Rule 610 before assuming a $0.01 minimum increment anywhere in this system** —
> a half-penny increment changes the price encoding assumptions, the level spacing in
> the book, and the queue economics below. See
> [../08-nasdaq/06-regnms-and-compliance.md](../08-nasdaq/06-regnms-and-compliance.md).

| Regime | Looks like | What wins |
| --- | --- | --- |
| **Large tick** (spread pinned at 1 tick; e.g. a $20 stock with huge volume) | Very long queues, thousands of shares deep, spread never widens | **Queue position.** You cannot outbid — there is nowhere to go. Speed to join a newly created level, and speed to cancel, are the entire edge. |
| **Small tick** (spread many ticks; e.g. a $900 stock) | Thin levels, few orders per level, spread flickers | **Price improvement.** Stepping ahead by one tick costs almost nothing, so priority is cheap and prediction of the mid dominates. |

**Large-tick names are the natural target for this system** — that is where FIFO
priority binds and nanoseconds are literally the product. Queue-jumping is cheap in
small-tick names, so the value of our latency decays there. Universe selection must be
explicitly tick-aware.

---

## 8. What you cannot see: hidden and iceberg liquidity

The displayed book is a **lower bound** on available liquidity.

| Type | What it is | Visible in the feed? |
| --- | --- | --- |
| **Non-displayed / dark** limit order | Full size hidden, still price-priority ranked (behind displayed at the same price) | No — only when it trades |
| **Reserve / iceberg** | Small displayed tip, large hidden reserve; the tip refreshes after execution | Only the tip; refresh looks like a new add |
| **Midpoint peg** | Executes at the NBBO midpoint, never displayed | No |
| **Primary / market peg** | Tracks a reference price; may or may not display | Depends on display instruction |
| **Minimum quantity** | Displayed but only executable above a size floor | Size visible; the constraint is not |

In an order-based feed like ITCH, executions of **non-displayed** interest appear as
trade messages that carry no order reference and do **not** modify the displayed book
(ITCH 5.0 message type `P`, "Trade — Non-Cross"). Executions against **displayed**
orders arrive as `E`/`C` and *do* modify the book.

> ⚠️ **Do not apply non-displayed trade messages to the book.** Decrementing a level
> on a `P` message desynchronises your book from the venue's for the rest of the
> session, and the error is silent — your book stays *plausible*, just wrong. This is
> the single most common ITCH book bug. See
> [../08-nasdaq/04-totalview-itch-5.0.md](../08-nasdaq/04-totalview-itch-5.0.md).

The iceberg refresh is a useful signal — repeated add/execute cycles of the same
display size at one price indicate size you cannot see — and also a trap: you can
queue behind a reserve order that keeps refreshing ahead of you.

---

## 9. Fragmentation, the SIP, and direct feeds

The same stock trades on many registered exchanges plus a large number of ATSs and
wholesalers. A meaningful fraction of US equity share volume executes off-exchange.

> **Verify:** the current count of registered US equity exchanges and the
> off-exchange share of volume both change. Cite Cboe Global Markets US Equities
> Market Volume Summary or SEC market structure data for a current figure; do not
> quote a number from memory.

| | **SIP / consolidated feed** | **Direct feed (e.g. TotalView-ITCH)** |
| --- | --- | --- |
| Source | Plan processor aggregating all exchanges | One exchange, its own matching engine |
| Content | NBBO + last sale; limited depth | Full depth, order-by-order, plus imbalance and status |
| Path | Exchange → processor → you (extra hop + aggregation) | Exchange → you |
| Latency | Strictly worse by construction | The reference |
| Use here | Reference/reconciliation only | **The fast path** |

**The latency argument for direct feeds is structural, not incidental.** The SIP must
receive from every exchange, normalise, compute a consolidated best, and redistribute
— at minimum one extra hop plus aggregation, with geographic distribution on top. You
cannot beat a participant reading the direct feed while you read the SIP, not because
the SIP is badly built, but because it is downstream of the thing you are racing.

> **Verify:** SIP-vs-direct differentials are frequently quoted and frequently stale;
> modern SIP processing is far better than millisecond-era figures in older
> literature. Measure it in our own colo rather than citing a number. Separately, the
> SEC's 2020 Market Data Infrastructure Rule (decentralised consolidation, competing
> consolidators, expanded "core data") has a protracted implementation and litigation
> history — confirm current status before designing around it.

**Rule for this project:** we consume **Nasdaq TotalView-ITCH direct** on the fast
path. Any NBBO we act on is one we construct ourselves from direct feeds, and
NBBO-dependent logic must state which venues it derives from and what happens when one
is stale. Order protection obligations:
[../08-nasdaq/06-regnms-and-compliance.md](../08-nasdaq/06-regnms-and-compliance.md).

---

## 10. A book event sequence, message by message

This is what "a tick" actually is. Order-based feed, one symbol, starting from an
empty book.

```
 #   MSG                                        BOOK AFTER
 ─────────────────────────────────────────────────────────────────────────
 1   A  ref=1001 B 300 @ 1908500                bid 1908500 × 300
 2   A  ref=1002 B 200 @ 1908500                bid 1908500 × 500   (1001 ahead)
 3   A  ref=1003 S 400 @ 1908600                ask 1908600 × 400   spread=1 tick
 4   A  ref=1004 S 100 @ 1908600                ask 1908600 × 500
 ─────────────────────────────────────────────────────────────────────────
 5   E  ref=1001 exec 300                       bid 1908500 × 200
        (a marketable sell hit the bid; order 1001 fully consumed but
         E does not say "fully" — you infer it from your own size tracking)
 6   D  ref=1001                                (no book change — already 0)
        ⚠️ E-to-zero followed by D is normal. Handle the double-decrement.
 ─────────────────────────────────────────────────────────────────────────
 7   X  ref=1002 cancel 150                     bid 1908500 × 50
 8   U  ref=1002 → ref=1005, 50 @ 1908400       bid 1908500 × 0  (level gone)
                                                bid 1908400 × 50
        ⚠️ Replace = delete + add. It LOSES time priority. Two book ops,
           and the new reference number is different.
 ─────────────────────────────────────────────────────────────────────────
 9   A  ref=1006 B 700 @ 1908500                bid 1908500 × 700  ← NEW LEVEL
        This is the race. The level was empty at message 8 and re-created at
        message 9. Whoever's Add landed first here owns position 1.
─────────────────────────────────────────────────────────────────────────
10   P  (non-cross trade) 200 @ 1908550         NO BOOK CHANGE
        A hidden midpoint order traded. Liquidity existed that the book
        never showed. Update your trade tape / VWAP; do NOT touch the book.
─────────────────────────────────────────────────────────────────────────
11   C  ref=1003 exec 400 @ 1908580, printable  ask 1908600 × 100
        Executed at a price different from the order's display price
        (price improvement / retail interaction). Book decrements by 400
        at 1908600 — the DISPLAY price, not the execution price.
        ⚠️ Getting this backwards corrupts the level. Very common bug.
```

Every ⚠️ line above is a book-corruption bug that produces a *plausible* book. No
exception, no assertion, no symptom — you simply start quoting against a fiction. Book
correctness is verified by replaying full sessions of captured pcap against an
independently-built reference book, never by inspection. See
[../01-fpga-design/05-verification-and-simulation.md](../01-fpga-design/05-verification-and-simulation.md).

---

## 11. What this means for the FPGA design

The concrete hardware implications of everything above:

| Microstructure fact | Hardware consequence |
| --- | --- |
| Priority is by arrival time at a *new* level | The **add-order path** on a level-creation event is the highest-value latency in the system. Optimise that specific trigger→TX path, not the average. |
| Being picked off costs multiples of the spread | The **cancel path must be as fast as the add path**, and must be reachable from a book event without a CPU round trip. |
| A stale book is worse than no book | Every abnormal condition (gap, crossed book, decode error, parameter update in flight) drives a **hardware quote-pull**, fail-closed, by default. |
| Feed is order-based (add/exec/cancel/delete/replace by 64-bit ref) | Need an **order-reference → (symbol, side, price, qty)** table. 64-bit sparse keys, millions of live refs → hashed set-associative BRAM/URAM structure, bounded-latency lookup. See [../01-fpga-design/03-memory-and-storage.md](../01-fpga-design/03-memory-and-storage.md). |
| Strategy needs *aggregate* level size, feed gives *individual* orders | Maintain **price-level aggregates incrementally** — one add/subtract per message, never a re-scan of the level. |
| Top of book is read every message; deeper levels rarely | **Top N levels in registers**, remainder in BRAM. A BRAM read on the critical path is a cycle you probably cannot afford. |
| Best-price recomputation only needed on level deletion | Do **not** build a max-reduction tree over all levels. Maintain incrementally; treat "best level emptied" as a slower, jittery path and count how often it happens. See [../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) §6. |
| Imbalance and microprice involve division | **No dividers.** Cross-multiply into comparisons, using multiplier constants from the parameter table. |
| Mid lands on half ticks | Carry prices at **2× ITCH scale** internally where midpoints are used, or compare against doubled thresholds. |
| Queue position determines fill value | Maintain, **per own resting order**, a `shares_ahead` counter decremented on every execute/cancel at that price with an earlier reference. This is real state and real BRAM — budget for it. |
| Hidden liquidity exists | Book size is a lower bound. Never assume "no displayed size ⇒ no liquidity". Non-displayed trade messages must **not** mutate the book. |
| Fragmentation | Multiple direct feeds ⇒ multiple decode pipelines feeding one consolidated view; arbitration between them adds jitter — use fixed priority and count. |
| Tick regime varies by symbol | Thresholds are **per-symbol parameters in a table**, not constants in RTL. |
| Message rates burst at open/close/news | Size for **peak burst**, not average. See [03-market-data-protocols.md](03-market-data-protocols.md) §7. |

---

## Further reading

- [02-order-types-and-matching-engines.md](02-order-types-and-matching-engines.md) — how the venue turns these orders into fills
- [03-market-data-protocols.md](03-market-data-protocols.md) — the wire format that carries the events in §10
- [05-strategy-taxonomy.md](05-strategy-taxonomy.md) — which strategies actually monetise §2 and §5
- [../04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md) — the implementation of §11
- [../08-nasdaq/01-market-structure.md](../08-nasdaq/01-market-structure.md) — Nasdaq-specific structure, sessions, and priority rules
