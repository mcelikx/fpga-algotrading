# 03.02 — Order Types and Matching Engines

> **Why this matters here:** the matching engine is the only thing that converts our
> messages into money. If you know its algorithm exactly, you can predict your fills
> before you send; if you don't, you are guessing about the one part of the system
> you cannot instrument. And its **cancel** path — not its order path — is where a
> market maker's sub-microsecond budget is actually spent.

Nasdaq's specific order types, modifiers, and cross mechanics are in
[../08-nasdaq/03-order-types-and-routing.md](../08-nasdaq/03-order-types-and-routing.md)
and [../08-nasdaq/02-sessions-auctions-and-halts.md](../08-nasdaq/02-sessions-auctions-and-halts.md).
This document is the concept layer.

---

## 1. What a matching engine actually does

Strip away the surface and a continuous-trading matching engine is a single-threaded
loop over a sequenced input stream:

```
loop forever:
    msg = next_from_sequencer()          ← total order established HERE
    validate(msg)                        ← membership, symbol state, risk, tick size
    switch msg.type:
        NEW:      match_against_book(msg); if residual: rest_or_reject(residual)
        CANCEL:   locate(order_id); remove; emit CancelAck
        REPLACE:  cancel + new, atomically, with a priority rule
    emit acks/fills to the affected members     (private, order entry session)
    emit book deltas to the public feed         (multicast market data)
```

Four properties of that loop drive everything we do:

1. **There is a single point of sequencing.** The instant your message is assigned a
   sequence number the outcome is determined. Everything before is a race; everything
   after is bookkeeping. The entire latency budget exists to reach that point first.
2. **It is deterministic and usually fully specified.** Given the book state and the
   arriving message, the fill is computable. Model it exactly.
3. **Private acks and public market data come from the same event**, but which reaches
   *you* first is the venue's plumbing, not a guarantee. Handle either order.
4. **Matching is atomic per message.** A marketable order sweeps every level its price
   permits in one indivisible step; nobody can step in mid-sweep.

> ⚠️ **The venue's clock is the only clock that matters for priority.** Your hardware
> timestamps tell you about *your* path; they say nothing about where you landed in
> the venue's sequence. Never infer priority from local timestamps — infer it from the
> acks and from the public feed.

---

## 2. Allocation algorithms

When an aggressive order consumes a price level containing several resting orders, an
**allocation algorithm** decides who gets filled. This is the venue's single most
consequential design choice for us.

| Algorithm | Rule | Rewards | Where |
| --- | --- | --- | --- |
| **Price-time (FIFO)** | Strict arrival order within a price | **Speed.** First in the queue is first filled. | US equities (all lit exchanges), most cash equity venues worldwide |
| **Pro-rata** | Each resting order gets a share proportional to its size | **Size.** Posting bigger gets you more. | Some futures/options (e.g. short-dated interest rate futures) |
| **Size pro-rata / weighted** | Pro-rata but with a minimum allocation and rounding rules | Size, with a floor for small orders | Various derivatives venues |
| **Top-order / priority + pro-rata** | The first order to establish a new best price gets a guaranteed slice, remainder pro-rata | Speed *and* size, partially | CME-style blended models |
| **Designated market maker allocation** | A DMM/LMM gets a contractual first slice in exchange for quoting obligations | Obligation compliance | Options markets, some equity DMM programs |

**Consequence: FPGA-scale latency pays in FIFO markets and pays much less in pro-rata
markets.** Under pro-rata, the correct response to wanting more fills is to post more
size, not to arrive sooner — and size is capital, not silicon. Our target market (US
equities on Nasdaq) is strict price-time, which is precisely why this project is worth
building.

> **Verify:** allocation is per-venue and sometimes per-product. Confirm the exact
> algorithm in the venue rulebook before assuming FIFO. For Nasdaq equities see the
> Nasdaq Equity Rulebook, Equity 4, Rule 4757 (Book Processing).

---

## 3. Order type taxonomy

Every order is a bundle of four independent decisions: **price instruction**,
**time-in-force**, **display instruction**, and **execution constraints**. Vendors
market these as "order types"; internally, treat them as orthogonal fields.

### Price instruction

| Type | What it is for | Hardware implication |
| --- | --- | --- |
| **Market** | Immediate execution, any price | ⚠️ Never emit from the fast path. Unbounded price risk; a fat-finger and a market order are indistinguishable to the risk block. Use a marketable limit instead. |
| **Limit** | Execute at price P or better | The default. One 32-bit price field in the template. |
| **Midpoint peg** | Execute at the NBBO midpoint | Requires a *maintained NBBO*, which requires all direct feeds. Non-displayed. |
| **Primary peg** | Rest at the near-side NBBO, tracking it | Venue re-prices for you; you give up control of exact price. |
| **Market peg** | Rest at the far-side NBBO | Aggressive pegging; used to seek midpoint-ish fills. |
| **Discretionary** | Display at P, silently willing to trade to P′ | The discretionary range is invisible to others; complicates your own fill prediction. |
| **Stop / stop-limit** | Becomes live when a trigger price prints | ⚠️ Triggering lives in the *venue's* logic and its timing is not yours. Prefer to implement stop semantics in our own hardware where we control the trigger. |

### Time in force

| TIF | Meaning | Use here |
| --- | --- | --- |
| **DAY** | Rests until the close of the regular session | Standard for quoting |
| **IOC** (Immediate-Or-Cancel) | Take what's available now, cancel the rest | **The workhorse for aggressive/taking strategies.** Bounded exposure: it either fills or it's gone, no resting risk. |
| **FOK** (Fill-Or-Kill) | All of it now, or none | Rare; useful when a partial fill is worse than no fill (leg risk in arbitrage) |
| **GTC** / GTD | Good till cancelled / date | ⚠️ Not for the fast path. Multi-day state is a reconciliation liability. If used at all, owned by the CPU. |
| **On-open / on-close** | Participates only in the auction | Auction strategies only; see §6 |

### Display and execution constraints

| Instruction | Purpose | Hardware implication |
| --- | --- | --- |
| **Post-only / add-liquidity-only** | Guarantee we never take | See §4 — critical, read it |
| **Non-displayed** | Hide entirely; rank behind displayed at the same price | Priority model changes; fill prediction gets harder |
| **Reserve / iceberg** | Show a tip, hide the rest; tip refreshes on execution | ⚠️ Each refresh is a **new** priority timestamp — refreshed size goes to the *back* of the queue |
| **Minimum quantity** | Do not fill me for less than N | Reduces micro-fill churn; may reduce fill rate materially |
| **Self-match prevention** | Do not trade against my own resting interest | See §5 — mandatory for us |
| **Routable vs. non-routable** | May the venue send the order elsewhere? | **Always non-routable on the fast path.** Routing hands control (and latency, and fees) to the venue. |

**Rule for this project:** the fast path emits exactly three shapes — **post-only
limit DAY** (quoting), **non-routable IOC limit** (taking), and **cancel**. Everything
else, if it is ever needed, is generated by the CPU on the slow path. Every additional
message shape is another template, another risk-check path, and another way to be
wrong at 3 a.m.

---

## 4. Post-only, and why it matters

A **post-only** (add-liquidity-only) order instructs the venue: *if this order would
execute immediately against resting interest, do not execute it.* Depending on the
venue and the modifier chosen, the order is either rejected, or re-priced one tick
away so that it rests.

Two reasons it is essential:

**(a) Fee economics.** On a maker-taker venue, adding liquidity earns a rebate and
removing it pays a fee. The gap is a substantial fraction of a penny per share and,
for a high-turnover market maker, frequently decides profitability. Accidentally
crossing turns a rebate into a fee — roughly a full tick of swing on a trade whose
gross edge was half a tick.

> **Verify:** access fees are capped by Reg NMS Rule 610, and both the cap and
> Nasdaq's own maker/taker schedule change. Get current numbers from the Nasdaq Price
> List and see [../08-nasdaq/07-fees-rebates-and-economics.md](../08-nasdaq/07-fees-rebates-and-economics.md).
> Do not hardcode a fee assumption in strategy parameters without a dated source.

**(b) Race protection.** Our quote is computed from a book state that is already tens
of nanoseconds old by the time the order reaches the venue. If the market moved in
that window, an ordinary limit order that was meant to *join* the bid can arrive as a
*marketable* order and take. That is the exact opposite of the intent: we wanted to be
paid to provide liquidity, and instead we paid to consume it, at the worst possible
moment (the market just moved). Post-only makes that failure mode structurally
impossible.

> ⚠️ **Know your venue's post-only behaviour precisely: reject vs. re-price.** They
> have opposite consequences.
> - *Reject*: the gateway must handle a rejection that is **not** an error, and must
>   not trip an error counter or a risk trip on it.
> - *Re-price*: you now have a **live order at a price you did not choose**, and the
>   FPGA's model of its own orders is wrong unless it consumes the ack's actual price.
>
> The gateway must take the resting price from the **acknowledgement**, never from
> what it sent. This is a two-line change that prevents a whole class of position and
> quoting bugs.

---

## 5. Self-match prevention

If two of our own strategies quote the same symbol on opposite sides, they will
eventually trade with each other. That is a **wash trade**: no economic risk transfer,
but real fees, real prints on the tape, real distortion of reported volume, and real
regulatory exposure.

> **Verify:** self-trading is addressed by FINRA Rule 5210 and its supplementary
> material on self-trades, and exchanges maintain their own self-trade prevention
> mechanisms and surveillance. Confirm current obligations and the venue's available
> SMP modifiers before relying on either.

Three layers, all of which we implement:

| Layer | Mechanism | Latency cost |
| --- | --- | --- |
| **Venue-side SMP** | Tag orders with an SMP group ID; the venue cancels one side (cancel-newest / cancel-oldest / decrement-both) | Zero — it is a field in the message |
| **Gateway-side** | The FPGA order gateway refuses to send an order that would cross our own known resting interest in that symbol | 1–2 cycles: compare against our own best bid/ask table |
| **Design-side** | One symbol is owned by one strategy instance at a time | Free, and by far the most robust |

**Rule for this project:** design-side ownership is the primary control — a symbol has
exactly one owning strategy slot. Venue SMP is set on every order as a backstop.
Gateway-side crossing detection is implemented and **counted**; a non-zero counter is
an incident, not a nuisance, because it means the design-side invariant broke.

---

## 6. Auctions, conceptually

Continuous trading is not the whole day. Auctions are **single-price, batched**
events: orders accumulate over a period, the venue computes the price that maximises
executable volume (with published tie-breaks), and everything crosses at that one
price.

| Auction | Purpose | Character |
| --- | --- | --- |
| **Opening** | Establish the day's first price, clear overnight order imbalance | High volume, wide participation, published imbalance information during the accumulation window |
| **Closing** | Establish the official closing price | The largest single liquidity event of the day; index and benchmark flow concentrates here |
| **Halt / reopening** | Restart trading after a halt (news, LULD, regulatory) | Unpredictable timing, elevated uncertainty |
| **IPO / new listing** | Price discovery for a first print | Special rules |

Why they matter even if we never trade them: **continuous-trading assumptions are
invalid during an auction** (book state, message semantics, and which messages appear
all change); **auction imbalance information is disseminated on the feed** and is a
genuine signal, but a *slow* one (ms–s scale) that belongs on the CPU, not in the
trigger path; and the transitions in and out are the highest-risk moments of the day.

**Rule for this project:** the FPGA maintains a per-symbol **trading-state register**
(pre-open / auction / continuous / halted / post). Order emission is gated on
`state == continuous` unless a strategy is explicitly certified for auction
participation. Fail closed: unknown state ⇒ no orders. Nasdaq's cross mechanics,
imbalance messages, and session boundaries are in
[../08-nasdaq/02-sessions-auctions-and-halts.md](../08-nasdaq/02-sessions-auctions-and-halts.md).

---

## 7. The order lifecycle on the wire

```
   US (our FPGA)                                 VENUE

     ├── New Order ──────────────────────────────►│  t=0
     │                                            │  sequenced, matched
     │◄─────────────────── Accepted / Rejected ───┤  RTT_ack
     │                                            │
     │◄─────────────────── Executed (partial) ────┤  whenever it fills
     │◄─────────────────── Executed (remainder) ──┤
     │                                            │
     ├── Cancel ─────────────────────────────────►│
     │◄─────────────────── Cancelled ─────────────┤  RTT_cancel
     │                     (or "too late to cancel")
```

| Event | Meaning | Where it must land |
| --- | --- | --- |
| **Accepted / order ack** | Order is live and has a place in the queue | FPGA (updates own-order table) **and** CPU (authoritative record) |
| **Reject** | Never live. Position unchanged. | FPGA (free the slot), CPU (count and classify) |
| **Partial fill** | Position changed by less than the order size; remainder still live | Both. Position update must be **atomic** with the risk counters. |
| **Fill (complete)** | Order done | Both; slot freed |
| **Cancel ack** | Order removed, no further fills possible | Both; slot freed |
| **"Too late to cancel"** | The cancel lost the race to a fill | ⚠️ Must be handled as a *fill is coming*, not as an error |
| **Cancel-replace ack** | Old order gone, new order live (new ID) | Both; the priority consequence is in §8 |

⚠️ **Race: fill and cancel cross on the wire.** You send a cancel; the venue fills
first. You receive the fill *after* sending the cancel, possibly after you decided the
order was dead. **An order is not dead until the venue says it is dead.** Treating a
sent cancel as immediate order death drifts your position — the failure mode that ends
firms. See [06-risk-and-compliance.md](06-risk-and-compliance.md) §10.

### Cancel-replace and priority

Replacing an order is `cancel + new` performed atomically by the venue. The critical
question is what happens to time priority:

- Reducing quantity, leaving price unchanged: priority is **typically retained**.
- Changing price, or increasing quantity: priority is **lost** — you go to the back of
  the new level's queue.

> **Verify:** this is venue-specific and it is exactly the kind of detail that
> silently invalidates a queue-position model. Confirm against the Nasdaq Equity
> Rulebook and the OUCH specification's Replace Order semantics before relying on it —
> [../08-nasdaq/05-ouch-5.0-order-entry.md](../08-nasdaq/05-ouch-5.0-order-entry.md).

**Rule for this project:** the queue-position model treats every replace as
**priority-lost** unless the venue behaviour has been confirmed *and* verified in
replay against real fills. Optimism here costs money in a way that is invisible until
you measure fill rates.

---

## 8. The cancel race — why cancel latency dominates

Return to the picked-off scenario from
[01-market-microstructure.md](01-market-microstructure.md) §5. An adverse event
occurs. Two populations react to the same public message:

- **Takers**: send an IOC to hit our now-stale quote.
- **Us**: send a cancel to remove it.

Both start their clocks at the same wire event. We survive if our cancel is sequenced
before their take. The margin is measured in **tens to hundreds of nanoseconds**, and
it is decided by decode latency, book update latency, trigger latency, and order
encode/TX latency — the entire fast path, in its defensive direction.

### The arithmetic that justifies the project

Illustrative, with round numbers; substitute your own fitted values.

```
Quote size                 300 shares
Spread capture per fill    0.5 tick   = $0.005/share  →  +$1.50 per benign fill
Adverse move when toxic    5.0 ticks  = $0.050/share  →  −$15.00 per toxic fill

Expected P&L per fill  =  (1 − f) × $1.50  −  f × $15.00      [f = toxic fraction]

    f = 3 %  →  +$1.455 − $0.45  =  +$1.01   healthy
    f = 5 %  →  +$1.425 − $0.75  =  +$0.68   fine
    f = 8 %  →  +$1.380 − $1.20  =  +$0.18   marginal
    f = 9.1% →  +$1.364 − $1.365 =   $0.00   BREAK-EVEN
    f = 12 % →  +$1.320 − $1.80  =  −$0.48   losing money on every fill
```

The entire business lives between roughly 3 % and 9 % toxic fills, and **`f` is
essentially a function of cancel latency relative to the field.** No improvement in
signal quality changes `f`; only being faster at withdrawing does. Two non-obvious
conclusions:

1. **Optimise the cancel path first.** Given a choice between 20 ns off order entry and
   20 ns off cancel, take the cancel every time.
2. **The cancel trigger must be reachable directly from a book event in fabric.** A
   cancel requiring a CPU decision has already lost — a PCIe round trip plus software
   is orders of magnitude too slow. The strategy block emits cancels with no host
   involvement, and the risk block never delays one (cancels *reduce* risk; see
   [06-risk-and-compliance.md](06-risk-and-compliance.md) §8).

⚠️ **Cancels must never be throttled by the same mechanism that throttles new
orders.** If a rate limiter blocks cancels during a burst, it converts a busy moment
into a loss event. Give cancels their own credit pool and their own priority in the TX
arbiter.

---

## 9. Order state machine, and where the state lives

```
                    ┌──────────────┐
      send new ───► │ PENDING_NEW  │
                    └──────┬───────┘
                  reject   │   accept
              ┌────────────┴────────────┐
              ▼                         ▼
        ┌──────────┐              ┌──────────┐
        │ REJECTED │              │   LIVE   │◄──────────┐
        └──────────┘              └────┬─────┘           │ replace ack
                                       │                 │ (new ID)
                  partial fill ────────┤                 │
                                       ▼                 │
                              ┌─────────────────┐        │
                              │ PARTIALLY_FILLED│────────┘
                              └────┬────────┬───┘
                     final fill    │        │  send cancel
                                   ▼        ▼
                            ┌────────┐  ┌───────────────┐
                            │ FILLED │  │ PENDING_CANCEL│
                            └────────┘  └───┬───────┬───┘
                                cancel ack  │       │ fill wins the race
                                            ▼       ▼
                                     ┌───────────┐ ┌────────┐
                                     │ CANCELLED │ │ FILLED │
                                     └───────────┘ └────────┘
```

⚠️ **`PENDING_CANCEL` can transition to `FILLED`.** Any state machine that omits that
edge will lose track of a position. It is the most commonly forgotten transition in
order gateways.

### Partitioning: what the FPGA holds vs. what the CPU holds

| State | FPGA | CPU | Rationale |
| --- | --- | --- | --- |
| Order token / ClOrdID | ✔ (generated) | ✔ (mirrored) | FPGA must generate it at line rate; CPU must reconcile it |
| Symbol, side, price, remaining qty | ✔ | ✔ | FPGA needs it to cancel and to prevent self-crossing |
| Lifecycle state (above) | ✔ minimal (live / not live / cancel-pending) | ✔ full | FPGA only needs "may I still cancel this?" |
| Queue-position estimate | ✔ | — | Fast-path input; stale on the CPU by definition |
| Position, PnL, average price | ✔ **position only**, saturating | ✔ authoritative PnL | Risk needs position in hardware; accounting does not need to be fast |
| Fill history, audit record | — | ✔ | Regulatory record-keeping is a slow-path job |
| Parent/child, allocations, clearing | — | ✔ | Never on the fast path |

**Sizing rule:** the FPGA's own-order table is a **statically sized array** —
`MAX_LIVE_ORDERS` entries on a free list. Empty free list ⇒ new orders **refused and
counted**, never queued. This bounds resource usage and, more importantly, bounds
in-flight exposure by construction. See
[04-order-entry-protocols.md](04-order-entry-protocols.md) §10.

---

## 10. Hardware implications

| Matching-engine fact | What we build |
| --- | --- |
| Single sequencing point; first-to-sequence wins | Fixed-latency TX path with minimum jitter. Determinism > mean. |
| FIFO allocation in US equities | Optimise the **level-creation add** and the **defensive cancel** specifically; they are the two paid paths. |
| Cancel latency dominates the P&L (§8) | Cancel gets its own trigger path, its own TX credits, its own arbiter priority, and is never blocked by risk. |
| Ack carries the *actual* resting price (post-only re-price) | Own-order table is updated from the **ack**, not from the sent message. |
| `PENDING_CANCEL → FILLED` is reachable | Order slot is freed only on a terminal venue message, never on cancel *transmission*. |
| Replace usually loses priority | Prefer **cancel + new** with explicit modelling over replace, unless replace is measured to be better. Model replace as priority-lost. |
| Three message shapes suffice | Three pre-built templates in ROM: post-only limit, IOC limit, cancel. See [04-order-entry-protocols.md](04-order-entry-protocols.md) §6. |
| Self-match is a regulatory event | Per-symbol single-owner design + venue SMP field + gateway crossing check with a counter. |
| Auctions change all semantics | Per-symbol trading-state register gating order emission; fail closed on unknown state. |
| Market orders are unbounded risk | Fast path never emits a market order. The encoder has no template for one. |
| Order table must be bounded | Static `MAX_LIVE_ORDERS` array + free list; exhaustion is refuse-and-count. |

---

## Further reading

- [01-market-microstructure.md](01-market-microstructure.md) — why queue position and cancels are worth this much
- [04-order-entry-protocols.md](04-order-entry-protocols.md) — the wire encoding of every message in §7
- [06-risk-and-compliance.md](06-risk-and-compliance.md) — why the risk gate must not delay cancels
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — the gateway that owns §9
- [../08-nasdaq/03-order-types-and-routing.md](../08-nasdaq/03-order-types-and-routing.md) — Nasdaq's actual order type matrix
- [../08-nasdaq/02-sessions-auctions-and-halts.md](../08-nasdaq/02-sessions-auctions-and-halts.md) — the Nasdaq crosses in detail
