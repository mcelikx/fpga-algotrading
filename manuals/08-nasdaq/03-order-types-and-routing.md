# 08.03 — Nasdaq Order Types, Attributes, and Routing

> **Why this matters here:** the order type is the *only* instruction the FPGA gets to
> give the matching engine. It decides whether you add or remove liquidity, whether
> you pay or are paid, whether you rest where you asked to rest, and whether you get a
> fill at all. It is also the largest single source of "working but wrong" designs in
> this project: an order that is silently re-priced, silently routed away, or silently
> converted to a taker changes your economics without producing a single error message.

Venue-neutral theory is in
[../03-algotrading/02-order-types-and-matching-engines.md](../03-algotrading/02-order-types-and-matching-engines.md).
This document is Nasdaq's catalogue.

> ⚠️ **Global verify note for this entire document.** Nasdaq splits this into
> **Order Types (Rule 4702)**, **Order Attributes (Rule 4703)** and **Routing (Rule
> 4758)** in the **Nasdaq Equity Rulebook (nasdaq.cchwallstreet.com)**. The wire-level
> encoding of every field below is in the **Nasdaq OUCH 5.0 specification**. Both are
> amended regularly. Everything here describes *mechanism*; **no code, mnemonic, or
> threshold below may be baked into RTL without reading the current rule text and the
> current OUCH spec.**

---

## 1. Order type vs. order attribute — Nasdaq's model

Nasdaq does not have one flat list. It has:

```
   ORDER TYPE            what the order fundamentally is
     └─ Price to Comply, Price to Display, Non-Displayed, Post-Only,
        Midpoint Peg Post-Only, Market Maker Peg, Retail, RPI, …

   ORDER ATTRIBUTES      modifiers applied on top
     └─ Time in Force, Size, Price, Display, Reserve Size, Peg, Discretion,
        Minimum Quantity, Routing, Intermarket Sweep, Attribution,
        Self Match Prevention, Trade Now, …
```

The combination is what the matching engine actually enforces. A "post-only IOC with
minimum quantity and no routing" is one *type* plus four *attributes*, and each one
you set is a field in the OUCH Enter Order message.

---

## 2. The core catalogue

### 2.1 Basic types and time-in-force

| Name | What it does | Key parameters | Fast-path? |
| --- | --- | --- | --- |
| **Limit** | Rest or execute at a price no worse than the limit | price, shares, side, TIF, display | ✅ **Yes** |
| **Market** | Execute at any price available | shares, side | ⚠️ **No** — unbounded price risk; never emitted from fabric |
| **IOC** (Immediate or Cancel) | Execute what it can immediately; cancel the remainder. Never rests | price, shares | ✅ **Yes** — the primary taking instruction |
| **FOK** (Fill or Kill) | Fill entirely and immediately, or cancel entirely | price, shares | ⚠️ Rare; adds all-or-none matching semantics |
| **Day** | Rests until end of the regular session | — | ✅ Yes (for resting quotes) |
| **GTX / extended TIF** | Rests through extended-hours sessions per the venue's definition | — | Slow path |
| **GTC** | Good till cancelled across days | — | ⚠️ Support varies by venue and is generally broker-simulated; **verify Nasdaq's supported TIF set in Rule 4703 and OUCH 5.0** |
| **On-open / on-close** | See §2.5 | — | ❌ Never from fabric |

> **Verify:** the exact time-in-force encodings in OUCH 5.0 (historically a numeric
> seconds-based field in older OUCH versions, with special sentinel values for IOC and
> day) — **this specific field changed between OUCH versions and must be read from the
> 5.0 spec.**

### 2.2 Liquidity-adding types and price sliding

These are where Nasdaq's specifics really bite.

| Name | What it does | FPGA relevance |
| --- | --- | --- |
| **Price to Comply** | If the order would lock or cross a protected quotation, it is **displayed one tick less aggressively** and given a **non-displayed price at the more aggressive level**, so it can still execute there | ⚠️ Your order rests at a price you did not send. Order state must record the *slid* price from the OUCH `Accepted` message, not the sent price |
| **Price to Display** | Same idea, different display/non-display treatment of the slid price | Same hazard |
| **Post-Only / Add Liquidity Only** | Will not remove liquidity. If it would lock/cross, it is re-priced (slid) — **or**, under a specific economic test, it *is* permitted to remove | ⚠️ See the trap below |
| **Non-Displayed** | Rests without being shown. No display, no protected quote, lower priority at the same price | Useful for hiding intent; worse queue position |
| **Midpoint Peg Post-Only** | Rests non-displayed at the NBBO midpoint, and will not remove liquidity | Price moves with the NBBO without you sending anything |
| **Market Maker Peg** | Automatically maintains a compliant two-sided quote at the designated percentage from the NBBO for a registered market maker | Useful precisely because it discharges the §5-of-08.01 obligation without per-tick messaging |
| **Supplemental Order** | Non-displayed interest that participates only in specific circumstances | Verify current availability |

⚠️ **The post-only trap.** Nasdaq's post-only behaviour is not simply "never take".
The historical rule is that a post-only order **will** remove liquidity when the
*price improvement it receives exceeds the economic cost* (the taker fee it would pay
plus the maker rebate it would forgo). This means:

```
   You send:   POST-ONLY BUY @ 190.86, expecting to REST and earn a rebate.
   Market has: ASK 190.85 (one tick better than your limit)
   Outcome:    the order may EXECUTE as a TAKER at 190.85 — you pay the fee.
```

Your P&L attribution, your fee model, and your "am I a maker or a taker" state all
change. ⚠️ **Verify the current post-only economic test in Rule 4702 and the current
fee figures in the Nasdaq Price List.** Then decide, per strategy, whether that
behaviour is wanted — and make it a configurable per-strategy parameter, not an
assumption.

### 2.3 Hidden and partially-hidden size

| Name | What it does | Key parameters | FPGA relevance |
| --- | --- | --- | --- |
| **Reserve / Iceberg** | A displayed portion plus a hidden reserve. When the displayed portion is exhausted it is **replenished** from reserve | display quantity, reserve quantity, replenishment size | ⚠️ **Replenishment loses queue priority** — the refreshed slice goes to the back of the queue at that price. This is invisible unless you track it |
| **Non-Displayed** | 100 % hidden | — | Ranks behind displayed at the same price |
| **Minimum Quantity (MQTY)** | Will not execute unless at least N shares can trade | minimum quantity | Prevents being pinged by 1-lot probes; ⚠️ may make the order non-displayable |
| **Discretionary** | Displays at one price, but is willing to execute up to a hidden "discretionary" price | display price, discretionary offset | Complex matching semantics — slow path |

⚠️ **Iceberg replenishment is a signal, not just a mechanic.** On the ITCH feed a
replenishment appears as a *new* Add Order at the same price — an order reference
number you have never seen, appearing instantly after an execution consumed a
different one. A book model that does not notice this will mis-estimate available
size and queue depth. See
[04-totalview-itch-5.0.md](04-totalview-itch-5.0.md) §7.

### 2.4 Pegged orders

| Peg | Reference | Behaviour |
| --- | --- | --- |
| **Midpoint peg** | NBBO midpoint | Rests at the midpoint; re-prices automatically as the NBBO moves |
| **Primary peg** | Same-side NBBO (NBB for a buy) | Tracks your own side; optional offset |
| **Market peg** | Opposite-side NBBO (NBO for a buy) | Aggressive tracking; optional offset |

Peg semantics that matter to hardware:

- The **exchange** re-prices the order. You send it once and it follows the market.
  This is a *latency win* — no message per re-price — and a *control loss*: you do
  not know its instantaneous price without tracking the NBBO yourself.
- ⚠️ Midpoint pegs sit on a **half tick** when the spread is one tick. Your internal
  price representation must handle this (carry prices at 2× the ITCH scale where a
  midpoint is computed — see
  [../03-algotrading/01-market-microstructure.md](../03-algotrading/01-market-microstructure.md) §1).
- ⚠️ Sub-penny pricing is constrained by **SEC Reg NMS Rule 612**. Midpoint execution
  is the standard exception. Do not invent sub-penny limit prices.
- **Verify** which peg types Nasdaq currently supports, their permitted offsets, and
  their display eligibility, in Rule 4702/4703.

### 2.5 Auction (on-open / on-close) types

| Type | Cross | Semantics |
| --- | --- | --- |
| **MOO** | Opening | Market on open |
| **LOO** | Opening | Limit on open |
| **MOC** | Closing | Market on close |
| **LOC** | Closing | Limit on close |
| **IO** (OIO / CIO) | Either | Imbalance-only: may only offset an existing imbalance, never create one |

⚠️ **Project rule: never emitted by the fast path.** Entry cut-offs, non-cancellable
windows and auction price risk make these a supervised, CPU-originated instruction.
Timing and imbalance mechanics are in
[02-sessions-auctions-and-halts.md](02-sessions-auctions-and-halts.md) §2.

### 2.6 Retail-specific

| Type | What it does |
| --- | --- |
| **Retail Order** | An order attested by the member as originating from a natural person, eligible to interact with RPI liquidity |
| **RPI (Retail Price Improving) Order** | Non-displayed liquidity priced better than the NBBO by at least a minimum increment, available **only** to Retail Orders |
| **RPII indicator** | ITCH message **`N`** signals, per symbol, whether RPI interest is present on the buy side, sell side, both, or neither |

> **Verify** the minimum price-improvement increment, the attestation requirements,
> and the RPII flag values in the **Nasdaq Equity Rulebook** (retail programme rules)
> and the **TotalView-ITCH 5.0 specification**. The commonly cited increment is
> **$0.001**, but confirm it.

⚠️ Retail designation is an **attestation about the origin of the order**. Attesting
falsely is a compliance violation. An FPGA must never set the retail flag by default;
it is set only for order flow the firm has genuinely designated as retail.

### 2.7 Cross and special-handling orders

| Type | Purpose |
| --- | --- |
| **Cross order** (agency cross, intermarket sweep cross, etc.) | Submit both sides of a pre-arranged trade for printing under the venue's cross rules |
| **Intermarket Sweep Order (ISO)** | ⚠️ An attribute asserting that the sender has **simultaneously routed orders to clear all better-priced protected quotations**, permitting this venue to execute without a trade-through check |

⚠️ **ISO is a legal representation, not a speed feature.** Marking an order ISO
asserts you have satisfied Reg NMS Rule 611 yourself. If your system marks ISO without
actually sweeping the away markets, that is a Reg NMS violation. **Do not enable ISO
in fabric unless the sweep logic that justifies it is also in the system and tested.**
See [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md).

---

## 3. Price sliding, in detail

**Price sliding is Nasdaq re-pricing your order so it does not lock or cross a
protected quotation.** It is the mechanism behind Price to Comply, Price to Display
and post-only re-pricing.

### When it applies

| Trigger | Result |
| --- | --- |
| Your buy limit ≥ the away protected offer (would cross) | Slid down |
| Your buy limit == the away protected offer (would lock) | Slid down |
| Post-only order that would remove liquidity | Slid (or executed, per the economic test in §2.2) |
| Away quote moves away later | The order may **slide back** to its original, more aggressive price |

### The layered price model

```
   You send:      BUY 100 @ 190.8600     (Price to Comply)
   Away market:   protected ASK @ 190.8600  → your order would LOCK

   Nasdaq rests:
        displayed price      190.8500     ← what the world sees
        non-displayed price  190.8600     ← what it can actually execute at

   Later, away ASK moves to 190.8700:
        the order may slide BACK UP to display at 190.8600
```

⚠️ **Three separate hazards for the FPGA's order state:**

1. **The resting price is not the sent price.** The authoritative price is in the
   OUCH **`Accepted`** message (and any subsequent **`Restated`** / **`Priority
   Update`** message). The FPGA's in-flight order record must be *updated from the
   ack*, not assumed from the request.
2. **The price can change again after acceptance**, with no action from you, as away
   quotes move. Nasdaq notifies via a priority/restatement message — you must consume
   it.
3. **A slid order has a different queue position than an unslid one**, so your
   fill-probability model is wrong if you assume otherwise.

**Project rule:** the FPGA maintains an in-flight order table keyed by order token
with a `state` field of `{SENT, ACCEPTED, RESTING, CANCEL_SENT, DEAD}` and a
`resting_price` field that is **only ever written from an inbound OUCH message**.
Never from the outbound request. Any strategy logic that needs "where is my order"
reads `resting_price`, and must handle `SENT` (unknown) explicitly.

---

## 4. Self Match Prevention (SMP / AIQ)

If two of your own orders would trade with each other, the resulting wash trade is a
regulatory problem and an economic own-goal (you pay both sides' fees).

Nasdaq provides self-match prevention configured at the **MPID** level, with
per-order selection of the action:

| Action (conceptual) | Result when a self-match is detected |
| --- | --- |
| Cancel **oldest** | The resting order is cancelled; the incoming order proceeds |
| Cancel **newest** | The incoming order is cancelled; the resting order remains |
| Cancel **both** | Both are cancelled |
| Decrement / partial | Reduce both by the overlapping quantity |

> **Verify** the supported SMP/AIQ values, the OUCH field that carries them, and how
> the scope is defined (MPID, group of MPIDs, or firm) in **Rule 4703** and the
> **OUCH 5.0 specification**. Nasdaq's outbound **AIQ Canceled** message reports the
> event — see [05-ouch-5.0-order-entry.md](05-ouch-5.0-order-entry.md).

⚠️ **SMP is not a substitute for not doing it.** Relying on the exchange to prevent
self-matches means:
- you burn message-rate allowance on orders that get cancelled,
- **cancel-oldest can destroy a valuable queue position you spent minutes earning**,
- and the cancel is asynchronous, so your book model briefly disagrees with reality.

The right answer is a **hardware-side self-match check** in the order gateway: before
emitting, compare the outgoing order against your own resting orders in the same
symbol on the opposite side. That is a small CAM or a per-symbol "my best bid / my
best ask" register pair — cheap, one cycle, and it prevents the message from ever
leaving. Configure exchange SMP as the *backstop*, not the primary mechanism.

---

## 5. Displayed vs. non-displayed priority

Within a price level, Nasdaq's continuous-trading allocation is price-time, with
display status as an intervening rank:

```
   At one price level, in execution order (conceptually):

     1. Displayed interest, by time
     2. Non-displayed interest, by time
     ( pegged / discretionary / reserve replenishment interleave per rule )
```

> ⚠️ **Verify the exact ranking** — including where reserve replenishment, pegged
> interest, discretionary interest and minimum-quantity orders sit — in **Rule
> 4703 (Order Attributes)** and the Nasdaq execution-algorithm rule text. The
> two-tier displayed-then-non-displayed shape is stable; the interleaving details are
> not something to trust from memory.

Practical consequences:

| Choice | You gain | You lose |
| --- | --- | --- |
| Display | Better queue rank; you form the protected quote; rebate eligibility | You broadcast your intent; you are the target for adverse selection |
| Hide | No information leakage | Rank behind all displayed size at the same price — often equivalent to no fill in a liquid name |
| Iceberg | Some display rank with less leakage | Replenishment resets your time priority |

For a queue-position-driven strategy, **display is nearly always correct on Nasdaq** —
the whole point is to be early in the displayed queue.

---

## 6. Routing strategies

Nasdaq can route unexecuted portions of an order to away venues. Routing strategies
are identified by short mnemonics in the order's routing attribute.

⚠️ **Verify note, emphatically:** Nasdaq's routing strategies are enumerated in
**Rule 4758** and encoded in the **OUCH 5.0** specification. They have names like
`DOT`, `SCAN`, `STGY`, `SKIP`, `SKNY`, `TFTY`, `RFTY`, `MOPP`, `CART`, `QDRK`,
`QMOP`, `LIST`, `SOLV` — **but the exact set, and precisely what each one does, is
rule text that has been amended repeatedly. Do not map a mnemonic to a behaviour from
memory. Read Rule 4758 and the current OUCH spec.** What follows are the *categories*
of behaviour, which are stable.

| Category | Behaviour | Latency character | Fast-path? |
| --- | --- | --- | --- |
| **No route / book only** | Execute against the Nasdaq book only; post or cancel the remainder. Never leaves the venue | Deterministic, minimal | ✅ **This is what we use** |
| **Post-only, no route** | As above, plus refuse to remove liquidity | Deterministic | ✅ Yes |
| **Route then post** | Sweep away protected quotes, then post the remainder on Nasdaq | ⚠️ Hundreds of µs+ for the route legs | ❌ No |
| **Route and cancel** | Sweep away venues, cancel any remainder | ⚠️ Same | ❌ No |
| **Dark then lit** | Attempt dark/midpoint liquidity first, then displayed venues | ⚠️ Highest latency; multi-hop | ❌ No |
| **Directed / list-based** | Route to a specified subset of venues in a specified order | ⚠️ Variable | ❌ No |

⚠️ **Project rule: every fast-path order carries a no-route designation, enforced in
hardware.** Reasons:

1. **Latency.** The exchange's router adds latency measured in *hundreds of
   microseconds* — larger than our entire budget by two to three orders of magnitude.
2. **Determinism.** A routed order's fate depends on away venues; the latency
   distribution has a long, unbounded tail.
3. **Cost.** Routed executions are billed at away-venue rates plus routing fees.
4. **Risk.** A routed order can execute somewhere your risk model was not watching.

Implement this as a constant in the pre-built OUCH template
([05-ouch-5.0-order-entry.md](05-ouch-5.0-order-entry.md) §7): the routing field is a
*static byte* in the template that the fast path cannot modify. To send a routable
order, use the CPU path.

---

## 7. What belongs on the FPGA — the project rule

⚠️ **Only three order shapes are permitted to originate in fabric:**

| Permitted | Why |
| --- | --- |
| **Limit, Day, Displayed, No-Route** | The passive quote. Fixed fields except price/size/side |
| **Limit, IOC, No-Route** | The aggressive take. Fixed fields except price/size/side |
| **Post-Only, Day, Displayed, No-Route** | The passive quote that refuses to pay the taker fee |
| **Cancel** (by token) | Always permitted, always fastest — see §8 |

**Everything else is CPU-originated**, and still passes through the same hardware
risk gate. Rationale:

1. **Template size.** Each order shape is a separate pre-built byte template in BRAM.
   Three shapes is cheap; twenty is a memory and mux problem on the critical path.
2. **State complexity.** Pegs, discretion, reserve and MQTY all create order states
   whose evolution the FPGA would have to model to know what it owns. That model is
   where wrong-but-working designs come from.
3. **The exotic types are not latency-sensitive.** If a peg is the right instrument,
   the exchange is doing the re-pricing for you — the send latency barely matters.
4. **Verification cost.** Every order shape needs conformance testing against the
   venue. Three shapes is a testable matrix.

If a strategy needs a fourth shape, that is a design change with a written
justification, a latency budget, and a conformance test — not an incremental RTL edit.

---

## 8. Hardware implications

### 8.1 Field mutability classification

Every field of the OUCH Enter Order message falls into exactly one class. This
classification **is** the template design.

| Class | Fields (illustrative — confirm the field list against the OUCH 5.0 spec) | Storage |
| --- | --- | --- |
| **Constant for the session** | Firm/MPID, capacity, customer type, routing (no-route), ISO flag (off), cross type (continuous) | Baked into the BRAM template at session start |
| **Constant per symbol** | Stock symbol (8-byte alpha, space-padded) | Per-symbol template row in BRAM, indexed by stock locate |
| **Constant per strategy** | Display flag, time in force, post-only/type selector, minimum quantity, SMP action | Selects *which* template row / a small mux |
| **Variable per order** | **Price, shares, side, order token** | Spliced in at emit time — the only bytes that move |

⚠️ This is why §7's three-shape rule matters: each (strategy × symbol) pair needs a
template row, and the variable fields must be few, contiguous, and byte-aligned.

### 8.2 Required per-order state

| Field | Width | Written by | Notes |
| --- | --- | --- | --- |
| `token` | 56–112 bits | FPGA at emit | Key of the in-flight table; see [05-ouch-5.0-order-entry.md](05-ouch-5.0-order-entry.md) §6 |
| `locate` | 16 | FPGA at emit | For symbol-indexed lookups |
| `side` | 1 | FPGA at emit | |
| `sent_price` | 32 | FPGA at emit | For reconciliation only |
| `resting_price` | 32 | ⚠️ **inbound OUCH only** | Price sliding makes this ≠ `sent_price` |
| `leaves_qty` | 32 | inbound OUCH | Decremented by executions |
| `state` | 3 | both | `SENT / ACCEPTED / RESTING / CANCEL_SENT / DEAD` |
| `is_short_sale` | 1 | FPGA at emit | Drives the SSR check ([02-sessions-auctions-and-halts.md](02-sessions-auctions-and-halts.md) §6) |
| `strategy_id` | 8 | FPGA at emit | Encoded in the token; also stored for fast lookup |

### 8.3 Gateway-enforced invariants

These are hardware checks, downstream of the strategy, that no strategy can bypass:

| Invariant | Check |
| --- | --- |
| No routing | Routing byte is a template constant; the mutable-field mux physically cannot reach it |
| No market orders | Price field is mandatory and non-zero; a zero/sentinel price is rejected and counted |
| No ISO | ISO byte is a template constant `off` |
| No auction types | Cross-type byte is a template constant `continuous` |
| Self-match | Compare against own resting best bid/ask for the symbol; suppress and count (§4) |
| LULD band | See [02-sessions-auctions-and-halts.md](02-sessions-auctions-and-halts.md) §4.4 |
| SSR | Short sells must be priced above the NBB when active |
| Halt | Per-symbol `tradable` bit |
| Size / notional | Per-symbol and per-strategy limits |
| In-flight credit | Bounded outstanding orders — see [../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) §8 |

Each failing check increments its own counter. A suppressed order with no attribution
is an unobservable failure.

### 8.4 Latency shape

| Step | Cycles @ 156.25 MHz | ns |
| --- | --- | --- |
| Strategy fires → order request | (strategy budget) | — |
| Template BRAM read (per-symbol row) | 2 | ~13 |
| Field splice (price / shares / side / token) | 1 | ~6 |
| Risk + state gate (parallel with splice) | 1–2 | ~6–13 |
| TCP checksum incremental update | 1 | ~6 |
| Hand to MAC | 1 | ~6 |

⚠️ These are *design targets to be measured*, not measurements. The point of the
table is the shape: **the mutable-field splice must be a single cycle**, which is only
possible if the number of mutable fields is small and their byte positions are fixed —
i.e. if §7's rule is respected.

---

## Further reading

- [05-ouch-5.0-order-entry.md](05-ouch-5.0-order-entry.md) — the wire encoding of everything here
- [02-sessions-auctions-and-halts.md](02-sessions-auctions-and-halts.md) — the state gates the order must pass
- [04-totalview-itch-5.0.md](04-totalview-itch-5.0.md) — how these order types appear in the public feed
- [../03-algotrading/02-order-types-and-matching-engines.md](../03-algotrading/02-order-types-and-matching-engines.md) — venue-neutral theory
- [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md) — ISO, Reg NMS, wash trades
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — where the invariants live
