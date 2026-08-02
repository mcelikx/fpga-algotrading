# 08.06 — Regulation NMS and US Equities Compliance

> **Why this matters here:** in US equities, regulation is not paperwork that happens
> after the trade — it is a set of *arithmetic constraints on the order message you
> are about to emit from fabric*. A price that is not a whole penny, a short sale at
> the wrong price, an order marked ISO that you did not actually sweep for: each is a
> rule violation encoded in a few bits of a 47-byte OUCH message. This document turns
> the rulebook into hardware requirements.

---

## 0. How to use this document

Every subsection ends with an implication for the fast path. The consolidated
mapping is in [§11](#11-compliance-obligation--hardware-feature-map), and the
concrete parameterised checks are specified in
[09-risk-controls-and-limits.md](09-risk-controls-and-limits.md).

> ⚠️ **Nothing in this file is legal advice, and rule numbers, thresholds, and
> effective dates change.** State the *mechanism* from here; confirm every *number*
> against the cited primary source before it becomes a constant in RTL or a risk
> parameter. Where this document says **Verify**, treat the value as unknown.

---

## 1. Regulation NMS — the shape of the rulebook

Regulation NMS (**17 CFR 242.600 et seq.**, adopted 2005, phased in through 2007)
is the SEC rule set that makes ~16 exchanges and ~30 ATSs behave like one market.
Four rules matter to a tick-to-trade system.

| Rule | Name | One-line effect on us |
| --- | --- | --- |
| **610** | Access Rule | Fair access to quotes; caps what a venue may charge to take; prohibits locking/crossing protected quotes |
| **611** | Order Protection Rule ("trade-through rule") | You may not execute at a price inferior to a *protected quotation* on another venue, except under an enumerated exception |
| **612** | Sub-Penny Rule | Hard constraint on the price field of every order you send |
| **603** | Market data / dissemination | Defines the SIP, and constrains how venues may release data — the reason your direct feed and the SIP differ |

Supporting cast you will meet: **Rule 600** (definitions — *NBBO*, *protected
quotation*, *automated quotation*), **Rule 604** (limit order display), **Rule 605**
(execution-quality statistics), **Rule 606** (order-routing disclosure).

> **Verify:** the current text of each rule at *SEC Regulation NMS (17 CFR 242.600 et
> seq.)*. The SEC has amended 610, 612, and 605 in recent rulemakings with staggered
> compliance dates — read the adopting release *and* the compliance-date table, not a
> summary.

---

## 2. Rule 611 — Order Protection (trade-through)

### The mechanism

A **protected quotation** is:
1. the **top-of-book** best bid or best offer,
2. of an **automated trading center** (immediately and automatically accessible,
   no human intervention, no intentional delay beyond what the SEC permits),
3. **displayed** (hidden/reserve size is *not* protected),
4. disseminated through the SIP.

Only the *top of book* is protected. Depth is not. Nasdaq's second price level has
no Rule 611 protection at all — see [01-market-structure.md](01-market-structure.md).

**Trade-through** = executing a trade at a price worse than a protected quotation on
another venue. Rule 611 places the obligation on the **trading center** (the
exchange/ATS), not directly on you — but the venue discharges it by rejecting,
re-pricing, or routing *your* order, which is very much your problem.

### What Nasdaq does with your order when it would trade through

| Your instruction | Nasdaq behaviour when a better protected quote exists away | Where covered |
| --- | --- | --- |
| Routable order | Routes the marketable portion out to the away venue, then posts/executes the remainder | [03-order-types-and-routing.md](03-order-types-and-routing.md) |
| Non-routable / "book-only" | Cancels or re-prices the offending portion rather than trading through | [03-order-types-and-routing.md](03-order-types-and-routing.md) |
| Post-only | Re-prices (price slide) or rejects rather than lock/cross or trade through | [03-order-types-and-routing.md](03-order-types-and-routing.md) |
| Marked **ISO** | Executes immediately against Nasdaq's book without routing — you asserted you handled the away quotes | §4 below |

### Rule 611 exceptions (the ones that matter)

| Exception | Gist |
| --- | --- |
| **ISO** | You simultaneously routed ISOs to the protected quotes — §4 |
| Self-help | Venue declared another venue unreachable/non-automated |
| Flickering quote | Protected quote was displayed for less than one second |
| Single-price auction | Opening/closing/reopening cross prints at one price |
| Crossed market | The protected market itself is crossed |
| Benchmark / stopped order | VWAP-type and stopped-stock trades priced off a benchmark |

> ⚠️ **Latency-sensitive consequence:** because only *displayed top-of-book* is
> protected, a strategy that "sees" a better price in depth or in a hidden order has
> no protection claim and no routing obligation. Do not build routing logic that
> assumes Rule 611 covers depth. It does not.

**Fast-path implication:** the FPGA's simplest and safest posture is to emit
**non-routable, book-only** orders and never assert ISO. That removes Rule 611 from
the hardware critical path entirely and moves it into Nasdaq's matching engine. Any
decision to send routable or ISO orders is an *architectural* decision that pulls
away-market state into the fast path.

---

## 3. Rule 610 — Access, locked/crossed markets, and the fee cap

### 3.1 Access and the fee cap

Rule 610 requires trading centers to provide fair and non-discriminatory access to
their protected quotations, and caps the fee a venue may charge to *access* (take) a
protected quotation.

| Aspect | Status |
| --- | --- |
| Mechanism | Per-share cap on the access fee for protected quotations; separate (lower) treatment for stocks priced below $1.00 |
| Historical cap for stocks ≥ $1.00 | $0.0030/share (the number the industry quoted for ~two decades) |
| Current cap | ⚠️ **Do not use the historical number.** The SEC adopted amendments to Rule 610(c) that lower the cap and tie it to the tick-size regime, with its own compliance date. |

> **Verify:** *SEC Regulation NMS (17 CFR 242.610)* adopting release and current
> compliance-date schedule, cross-checked against the *Nasdaq Price List
> (nasdaqtrader.com/Trader.aspx?id=PriceListTrading2)*, which shows the fee actually
> charged. See [07-fees-rebates-and-economics.md](07-fees-rebates-and-economics.md).

### 3.2 Locked and crossed markets

| Term | Definition |
| --- | --- |
| **Locked** | Best bid == best offer across venues (e.g. you bid 10.00, another venue offers 10.00) |
| **Crossed** | Best bid > best offer across venues |

Rule 610(d) requires SROs to have rules reasonably designed to prevent their members
from **displaying** quotations that lock or cross a protected quotation during
regular trading hours. It is a prohibition on *displaying*, not on *taking* — if
someone is offering at your bid price, the correct action is to **take it**, not to
post alongside it.

Nasdaq enforces this on your behalf via **price sliding** and post-only re-pricing.
The consequences you must handle in hardware:

- Your order may **rest at a different price than you sent**. The OUCH accept/ack
  carries the actual resting price — believe the ack, not your intent.
- A post-only order may be **rejected** rather than slid, depending on the order
  type and instruction chosen.
- Locked/crossed restrictions apply during regular hours; pre-open and post-close
  behaviour differs. See [02-sessions-auctions-and-halts.md](02-sessions-auctions-and-halts.md).

> ⚠️ A hardware strategy that maintains a mirrored copy of "where my order is" must
> update that mirror from the **ack**, never from the send. Price sliding makes the
> send price and the resting price legitimately different, and a stale mirror will
> compute the wrong quote-improvement decision and the wrong position.

---

## 4. Intermarket Sweep Orders (ISO)

### What an ISO is

A limit order marked with the ISO flag, sent to a venue with the instruction:
*execute immediately at your book price without regard to protected quotations
elsewhere.* The venue is permitted to do so under the Rule 611 ISO exception.

### What you are asserting when you set that flag

By marking an order ISO you represent that, **simultaneously with routing that
order**, you routed one or more additional ISOs to execute against the **full
displayed size** of every protected quotation with a better price. That is an
affirmative obligation on the *sender*, discharged by the sender's own systems.

```
    Protected quotes:  ARCA offer 100 @ 10.00 (better)
                       NSDQ  offer 500 @ 10.01

    Legal ISO buy:  send ISO buy 100 @ 10.00 → ARCA     (sweep the better quote)
                    send ISO buy 500 @ 10.01 → NSDQ     (simultaneously)

    Illegal:        send ISO buy 500 @ 10.01 → NSDQ only
                    (marked ISO, never swept ARCA — this is a rule violation,
                     not a routing inefficiency)
```

> ⚠️ **Marking an order ISO without performing the sweep is a violation, not a bug.**
> It is a false representation to the exchange that the Rule 611 exception applies.
> This is materially different from most FPGA errors: there is no "we lost money on
> it, oh well" outcome — there is a regulatory finding.

### Design rule for this project

**Default: never assert ISO from fabric.** Asserting ISO correctly requires:
- a consolidated view of protected quotations across all automated trading centers,
- the ability to emit multiple orders to multiple venues *simultaneously*,
- sessions and risk approval on every one of those venues,
- a demonstrable audit trail proving the simultaneous sweep for every ISO sent.

If ISO ever becomes a requirement, it is a whole subsystem, and the ISO bit must be
generated by the same block that generated the sweep — never by a parameter register
a human can set. See [09-risk-controls-and-limits.md](09-risk-controls-and-limits.md)
for the "ISO flag must be hard-tied to 0 unless the sweep engine is present" check.

---

## 5. Rule 612 — the Sub-Penny Rule (a hard hardware constraint)

### The rule

No market participant may **display, rank, or accept** an order, quotation, or
indication of interest in an NMS stock priced in an increment finer than the minimum
pricing increment.

| Stock price | Minimum pricing increment (classic regime) |
| --- | --- |
| ≥ $1.00 | $0.01 (whole pennies) |
| < $1.00 | $0.0001 |

> ⚠️ **The tick-size regime is being amended.** The SEC adopted amendments to Rule
> 612 introducing a **finer quoting increment (a half-penny, $0.005) for certain NMS
> stocks** selected by a quoted-spread measurement, with periodic reassignment and
> its own compliance date. The set of affected symbols is *data-driven and changes
> periodically*.
>
> **Verify:** *SEC Regulation NMS (17 CFR 242.612)*, the adopting release, the
> current compliance date, and — critically — **where the per-symbol tick-size
> assignment is published**. Nasdaq will announce operational handling via *Nasdaq
> Equity Trader Alerts*.

### Why this is an FPGA design constraint, not a config item

The classic regime lets you assume "price mod 100 == 0" for stocks ≥ $1.00, with
prices as ITCH/OUCH scaled integers (4 implied decimals, so $10.00 → `100000`). A
half-penny regime makes the valid increment **per-symbol and time-varying**.

```
    Classic:     valid  ⇔  (price_i % 100 == 0)          for price ≥ 10000
    Two-regime:  valid  ⇔  (price_i % tick_i == 0)       tick_i ∈ {50, 100} (or 1 for sub-$1)
```

**Therefore: the tick size must be a per-symbol parameter field in the risk/symbol
table, not a hardcoded constant.** Sizing that field now costs nothing; retrofitting
it into a placed-and-routed design during a compliance deadline is expensive.

Implementation note: `% 100` is not a modulo in fabric. Because ticks are small
powers-of-two-friendly constants, store `tick_i` and check divisibility with a
precomputed reciprocal-multiply, or — simpler and exact — store the price as
`(ticks_from_zero)` and reconstruct, or restrict to a small enumerated set of tick
sizes and use a per-tick comparator. A 3-bit `tick_class` field indexing a tiny
lookup of {1, 50, 100} is one LUT level.

### The important nuance: pricing vs. executing

Rule 612 governs the price at which orders are **displayed, ranked, and accepted**.
It does **not** prohibit sub-penny *executions*. Midpoint executions in a
one-cent-wide market print at a half cent; price-improvement and benchmark trades
print in sub-pennies routinely.

> ⚠️ Your fill-processing and P&L path must therefore accept **sub-penny execution
> prices** even while your order-generation path may only emit whole-penny order
> prices. Two different validity domains. Hard-coding "prices are whole cents" into
> the fill handler produces silently wrong average-price and P&L arithmetic.

---

## 6. Rule 603, the SIP, and the two NBBOs

### The consolidated tape

| Tape | Contents | Plan / processor |
| --- | --- | --- |
| **A** | NYSE-listed | CTA/CQ Plan |
| **B** | NYSE American, Arca, Cboe/BZX-listed and others | CTA/CQ Plan |
| **C** | **Nasdaq-listed** | **UTP Plan** (Nasdaq is the plan processor) |

The SIP consolidates quotes and trades from every exchange and computes the
**official NBBO**. Rule 603(a) constrains how a venue may distribute its own data —
in particular, a venue may not release core data to some recipients on a materially
more timely basis than to others, and independent distribution must be on terms that
are fair and reasonable and not unreasonably discriminatory.

> **Verify:** the current market-data architecture. The SEC's Market Data
> Infrastructure Rule contemplates competing consolidators and an expanded "core
> data" definition, with an implementation timeline that has moved. Check the current
> status before designing anything that depends on it.

### ⚠️ SIP NBBO vs. your synthetic NBBO — the most important distinction in this file

You will build a **synthetic NBBO** by decoding direct feeds (Nasdaq TotalView-ITCH,
plus BX, PSX, NYSE, Arca, Cboe, MEMX, IEX…) in fabric. It will be **faster** than the
SIP — typically by tens of microseconds — because the SIP aggregates, normalizes, and
redistributes.

| Property | SIP NBBO | Your synthetic NBBO |
| --- | --- | --- |
| Latency | Slower (aggregation + redistribution hops) | Fast (direct feed, decoded in fabric) |
| Completeness | All protected quotes, by construction | Only the venues you actually consume |
| Authority | **Official.** Referenced by rules and by venues | Yours. No regulatory standing |
| Failure mode | Stale but consistent | Silently *incomplete* if a feed drops |

**The compliance implication:** several obligations reference the *official* NBBO or
the venue's own view of it, not yours.

- **Reg SHO Rule 201** short-sale price test is evaluated against the **national best
  bid** as the trading center sees it.
- **Rule 611** protection attaches to quotes disseminated through the SIP.
- **Best execution** analysis under *FINRA Rule 5310* is conducted against
  consolidated data.

> ⚠️ **You may trade on your fast synthetic NBBO. You may not use it to argue that a
> rule was satisfied when the official NBBO said otherwise.** Practical consequence:
> for any check whose *regulatory basis* is the official NBBO (notably SSR), the
> hardware check must be **conservative** — reject when your view is uncertain, stale,
> or incomplete — and the venue's own rejection is the backstop, not the primary
> control. Build the check to fail closed, and count how often the venue rejects
> something you allowed: that counter is your evidence that the two views agree.

Feed-completeness monitoring (gap detection, per-venue staleness timers) is therefore
a *compliance* feature, not just a data-quality feature. See
[../02-networking/03-multicast-feeds-and-arbitration.md](../02-networking/03-multicast-feeds-and-arbitration.md).

---

## 7. SEC Rule 15c3-5 — the Market Access Rule

The single most architecturally consequential rule for this project.

### What it requires

A broker-dealer with market access — or providing market access to a customer — must
have **risk management controls and supervisory procedures reasonably designed to
manage the financial, regulatory, and other risks** of that access.

| Requirement | Substance | Our implementation |
| --- | --- | --- |
| Financial controls | Pre-set credit and capital thresholds; controls that **prevent** orders exceeding them | Notional/position/credit limits in the risk gate |
| Erroneous-order controls | Price and size parameters; duplicate-order detection | Price collars, max shares/notional, duplicate detect |
| Regulatory controls | Prevent orders that would violate regulatory requirements on a pre-trade basis; restrict access to authorised persons | Sub-penny, LULD band, SSR, halt, restricted-list checks |
| **Automated and pre-trade** | Controls applied **before** the order routes, systematically, not by human review | Everything above lives in fabric, in the order path |
| **Direct and exclusive control** | The controls must be under the broker-dealer's direct and exclusive control | The BD owns the limit parameters and the kill switch |
| Regular review + certification | Annual review of business activity and effectiveness; CEO certification | Slow-path process, evidence produced from FPGA counters |

### The prohibition on unfiltered access

"Unfiltered" or "**naked**" access — a customer's orders reaching an exchange without
passing through the broker-dealer's pre-trade controls — is prohibited. This is the
reason the fast path cannot have a bypass.

> ⚠️ **This is why CLAUDE.md §5.5 exists as a hard rule: there is no software path
> that emits orders without passing the hardware risk gate.** A "debug mode" that
> writes an OUCH message straight to the TX FIFO is not a debug feature; it is
> unfiltered access. If such a path is needed for lab bring-up, it must be physically
> impossible to build into a production bitstream (guarded by a synthesis-time
> parameter that is asserted `= 0` in the production build script, with the assertion
> checked in CI).

### "Direct and exclusive control" and the FPGA

The controls must be the broker-dealer's. Practical consequences for hardware:

1. **Limit parameters are written by the BD's risk system**, not by the strategy
   process. Separate the control-plane BAR region for risk parameters from the
   strategy-parameter region, with separate write permissions in the host driver.
2. **The strategy cannot widen a limit.** The risk gate reads parameters; no fast-path
   logic may write them.
3. **The kill switch is reachable by the BD independently of the strategy process** —
   ideally including an out-of-band path (see
   [09-risk-controls-and-limits.md](09-risk-controls-and-limits.md) §5).
4. **The bitstream is part of the control.** A change to the risk block is a change to
   a 15c3-5 control and needs the corresponding change-management evidence.

Cross-references:
[../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md) ·
[../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md)

> **Verify:** *SEC Rule 15c3-5* text and the SEC staff FAQs, which address permissible
> allocation of certain controls to another registered broker-dealer.

---

## 8. Regulation SHO — short sales

| Rule | Requirement | Fast-path impact |
| --- | --- | --- |
| **200(g)** | Every sell order must be **marked** long, short, or short exempt | A 2-bit field in the order record; must be *derived*, not defaulted |
| **203(b)(1)** | **Locate** required before effecting a short sale: reasonable grounds to believe the security can be borrowed and delivered by settlement | Locate is a slow-path/stock-loan function; the FPGA enforces the *result* (a per-symbol shortable flag + available quantity) |
| **203(b)(2)(iii)** | Limited exception for **bona fide market making** | Do not assume it applies. It is narrow, fact-specific, and heavily scrutinised |
| **204** | **Close-out**: fails to deliver must be closed out on a defined timetable | Slow path; feeds back into the shortable flag |
| **201** | **Short sale price test** ("alternative uptick rule") | Live, per-symbol, intraday state that the FPGA must honour |

### Marking: long vs short

"Long" requires that you are **net long** the security and deliver from that
position. A sell that takes you from +200 to −300 is not one order — under the
marking rules the portion that goes short is a short sale.

> ⚠️ **The FPGA cannot mark orders correctly from strategy intent alone.** Marking
> depends on the firm's *position of record*, including positions held elsewhere,
> pending settlements, and allocation. The practical hardware design is:
>
> - the risk gate holds a per-symbol **`long_available_qty`** pushed by the slow path,
> - a sell order of size `S` is permitted as **long** only while `S ≤ long_available_qty`
>   (decremented on send, reconciled by the slow path),
> - anything else is either marked **short** — and then only if the symbol's
>   `shortable` flag and `locate_qty` allow it — or **rejected**.
>
> The conservative default is: **reject** rather than guess the mark.

### Rule 201 — the short sale price test (SSR)

| Element | Behaviour |
| --- | --- |
| Trigger | Intraday decline of **10 % or more** from the prior day's official closing price |
| Duration | Remainder of that day **and** all of the following trading day |
| Restriction | Short sales may only be **displayed or executed at a price above the current national best bid** |
| Exception | Orders marked **short exempt** (narrow; do not use casually) |
| Notification | Nasdaq disseminates SSR state; ITCH carries a short-sale-price-test flag per symbol — see [04-totalview-itch-5.0.md](04-totalview-itch-5.0.md) |

Hardware check (specified fully in
[09-risk-controls-and-limits.md](09-risk-controls-and-limits.md)):

```
    if (side == SELL_SHORT && ssr_active[sym])
        require (order_price > national_best_bid)      // strictly greater
```

> ⚠️ Two traps. (1) It is **strictly above**, not at-or-above. An off-by-one in a
> `>=` is a rule violation that will fire thousands of times before anyone notices.
> (2) The comparison is against the **national** best bid, not Nasdaq's best bid.
> See §6 — build it conservative and count venue rejections as the reconciliation.

> **Verify:** *SEC Regulation SHO* (17 CFR 242.200–204), and the current close-out
> timetable under T+1 settlement, which changed the day counts.

---

## 9. CAT — the Consolidated Audit Trail

### What is reportable

CAT (SEC **Rule 613** and the **CAT NMS Plan**, implemented for industry members
through the FINRA/exchange Consolidated Audit Trail Compliance Rules) requires
reporting of the full lifecycle of every order in NMS securities.

| Event category | Examples |
| --- | --- |
| Origination | New order received or originated |
| Routing | Order or child order sent to a venue or another broker-dealer |
| Modification | Replace, cancel/replace, quantity or price change |
| Cancellation | Full or partial cancel, venue-initiated cancel |
| Execution | Fill, partial fill, and its allocation |

Plus reference data: the account, the MPID, the capacity (principal/agency), the
Reg SHO mark, the order type and time-in-force, and identifiers that let the
regulator stitch a parent order to its children across firms and venues.

### Clock synchronisation and timestamp granularity

| Requirement | Value |
| --- | --- |
| Business-clock synchronisation to NIST | Within a defined tolerance — historically **50 ms** for industry members, with a much tighter standard for exchanges/plan processors |
| Timestamp granularity | At least **milliseconds**, **but** if your system captures finer granularity you must **report that finer granularity** |
| Reporting deadline | Next trading day, early morning, with a correction window |

> **Verify:** *the CAT NMS Plan* (Section 6.8) and the corresponding FINRA/exchange
> CAT Compliance Rules for the current tolerance, granularity, and deadlines.

**What this means for an FPGA — and it is not what people expect.** The 50 ms clock
tolerance is trivially easy to meet. The *granularity* rule is the one that bites:
because your hardware timestamps at nanosecond resolution, you must **report at
nanosecond resolution**. That has three consequences:

1. Every fast-path event that becomes a CAT reportable event must carry a
   **nanosecond hardware timestamp** captured at the point of the event, not
   reconstructed later by the host.
2. That timestamp must be **traceable to UTC**, which means the FPGA free-running
   counter must be disciplined by PTP/GPS, not merely free-running. See
   [08-connectivity-and-colocation.md](08-connectivity-and-colocation.md) §8.
3. A timestamp you report must be *defensible*: you must be able to state its
   accuracy and its capture point. "The host read the DMA descriptor at time T" is
   not the order-origination time.

### What the system must log (fast path → slow path)

| Field | Source | Note |
| --- | --- | --- |
| Nanosecond hardware timestamp | FPGA PTP-disciplined counter | Capture at the emit/receive register stage |
| Order token / client order ID | Order generator | Must be unique and reconstructible |
| Symbol, side, price, size, TIF, display | Order record | Exactly as sent |
| Reg SHO mark | Risk gate | Long / short / short exempt |
| Capacity, account, MPID | Session config | Per-session constant |
| Risk decision + reject reason code | Risk gate | Rejected orders are also evidence |
| Sequence numbers (in and out) | Feed handler, OUCH session | For reconstruction |

> ⚠️ **Rejected orders matter.** A pre-trade rejection that never reached the
> exchange is generally not a CAT-reportable *route*, but it is the evidence that
> your 15c3-5 controls worked. Log it with the same fidelity, in a separate stream.

---

## 10. Reg SCI, manipulation, and FINRA

### 10.1 Reg SCI (17 CFR 242.1000–1007)

Regulation Systems Compliance and Integrity applies to **SCI entities** — exchanges,
certain ATSs above volume thresholds, plan processors, clearing agencies. **A
proprietary trading firm is generally not an SCI entity.**

Two reasons it still shows up in your life:

1. **You inherit the discipline.** Reg SCI's structure — capacity/integrity testing,
   change management, business-continuity and disaster-recovery plans, incident
   classification and reporting timelines, annual review — is the template every
   examiner has in their head for "what a well-run trading system looks like."
   Adopt it voluntarily; it costs little and it is the vocabulary of the examination.
2. **You may be a designated member for BC/DR testing.** SCI entities must designate
   members required to participate in **annual business-continuity and
   disaster-recovery testing**. If you are designated, participation is mandatory and
   dated — see [08-connectivity-and-colocation.md](08-connectivity-and-colocation.md) §9.

Concretely, for this repo: bitstream versioning, reproducible builds, a change log
tying every production bitstream to a reviewed diff, and a documented rollback.
See [../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md).

### 10.2 Manipulation an algorithm can commit by accident

| Pattern | What it is | How an honest algo trips it |
| --- | --- | --- |
| **Spoofing** | Entering orders with intent to cancel before execution, to induce others to trade | A quoting algo that posts size and cancels on any adverse signal produces *the same message pattern* |
| **Layering** | Multiple price levels of non-bona-fide orders on one side | A ladder-quoting strategy looks identical from the outside |
| **Marking the close** | Trading to influence the closing price | A poorly-designed inventory-flattening routine that fires into the closing auction |
| **Wash trades / self-trades** | Trades with no change in beneficial ownership | Two of *your* strategies crossing on the book |
| **Momentum ignition** | Aggressive orders to trigger others' algorithms | An unthrottled taker reacting to itself in a feedback loop |

> ⚠️ **A fast cancel pattern is not spoofing, but it looks exactly like spoofing in a
> surveillance report.** Intent is the legal element; the surveillance system cannot
> see intent, only messages. Your defences are:
>
> 1. **Document the intent up front.** A written strategy description stating *why*
>    the algorithm cancels (adverse selection avoidance, inventory limit, quote
>    refresh on book change) is worth far more written before the inquiry than after.
> 2. **Make the intent visible in the code and the audit trail.** Emit a *reason code*
>    with every cancel — hardware knows exactly which condition fired. A cancel log
>    reading `REASON=BOOK_MOVED_AGAINST` across millions of events is a powerful,
>    contemporaneous, machine-generated record of intent.
> 3. **Keep the orders bona fide.** If the order would have been executed had someone
>    hit it, at the size and price shown, that is the substantive answer.
> 4. **Surveil yourself.** Run your own layering/spoofing pattern detection on your
>    own outbound flow. Finding it first is the whole game.

**Self-match prevention (SMP)** is not merely hygiene — self-trades can be treated as
wash trades, and *FINRA Rule 5210* Supplementary Material requires firms to have
policies reasonably designed to review for and prevent self-trades resulting from
orders originating from the same beneficial owner. SMP therefore has a **regulatory
basis**, which is why it appears as a mandatory pre-trade check in
[09-risk-controls-and-limits.md](09-risk-controls-and-limits.md) and why the MPID/SMP
group configuration in [08-connectivity-and-colocation.md](08-connectivity-and-colocation.md)
§5 is a compliance decision, not an operations one.

### 10.3 FINRA rules relevant to algorithmic trading

| Rule | Relevance |
| --- | --- |
| **3110** — Supervision | Written supervisory procedures covering algorithm development, deployment, and monitoring |
| **3120** — Supervisory control system | Testing and verification of those procedures |
| **5310** — Best Execution | Reasonable diligence for customer orders; "regular and rigorous" review of execution quality. Principal-only flow changes the analysis but does not make it disappear |
| **5210** — Publication of transactions and quotations | Self-trade prevention policies; no fictitious transactions |
| **2010** — Standards of commercial honor | The catch-all under which conduct cases are brought |
| **Registration** | Persons **primarily responsible for the design, development, or significant modification of an algorithmic trading strategy** — and those supervising them — are generally required to register as **Securities Traders** |

> ⚠️ **The registration point catches engineers by surprise.** If you write the RTL
> that decides when to send an order, you may personally need a securities
> registration and exam. Settle this with compliance **before** the first line of
> strategy RTL, not after. **Verify:** *FINRA Rule 1220* (Securities Trader
> registration category) and the associated FINRA Regulatory Notice, plus *FINRA
> Regulatory Notice 15-09* on effective supervision of algorithmic trading.

### 10.4 Clearly erroneous executions

When a trade prints at an absurd price, it can be broken.

| Element | Mechanism |
| --- | --- |
| Basis | Exchange rule (Nasdaq's clearly-erroneous rule, harmonised across US exchanges) |
| Trigger | Execution price deviates from a reference price by more than a **numerical guideline**, which varies by stock price band, time of day, and whether it is a multi-stock event |
| Process | A party files a request within a **short deadline measured in minutes** from the execution; the exchange officer rules; there is an appeal path |
| Interaction | **LULD** greatly reduced clearly-erroneous events by preventing the prints in the first place — see [02-sessions-auctions-and-halts.md](02-sessions-auctions-and-halts.md) |

> **Verify:** the current numerical guidelines and filing deadline in the *Nasdaq
> Equity Rulebook* (listingcenter.nasdaq.com / nasdaq.cchwallstreet.com). Exchanges
> have been migrating toward a limit-based framework; confirm which regime is live.

**Operational consequence:** a trade you believe you have can be **taken away hours
later**. Your position accounting must tolerate a retroactive bust, and your kill
criteria must not assume the fill set is immutable. The FPGA's position counter will
be wrong until the slow path reconciles it — this is one of the reasons the FPGA's
position is a *risk control*, not a *book of record*.

---

## 11. Compliance obligation → hardware feature map

| Obligation | Source | Hardware feature that discharges it | Fails how |
| --- | --- | --- | --- |
| Whole-penny order prices | Rule 612 | Per-symbol `tick_size` field + divisibility check in risk gate | Exchange rejects; repeated → rule violation |
| Correct tick for half-penny symbols | Rule 612 (amended) | Same field, populated from the published assignment list | Silent: orders rejected only for *some* symbols |
| No trade-through | Rule 611 | Emit non-routable/book-only orders; let Nasdaq enforce | Trades through if you assert ISO falsely |
| ISO correctness | Rule 611 exception | ISO bit **hard-tied 0** unless a real sweep engine exists | Rule violation |
| No locked/crossed display | Rule 610(d) | Post-only + price sliding; update mirror from **ack** | Stale mirror → wrong quotes, wrong position |
| Pre-trade risk, no bypass | Rule 15c3-5 | Risk gate is the only path to TX; no synthesis-time bypass in production | Unfiltered access — a serious finding |
| Credit/capital limits | Rule 15c3-5(c)(1)(i) | Saturating notional + position counters, per symbol and aggregate | Wrapped counter → limit silently passes |
| Erroneous-order prevention | Rule 15c3-5(c)(1)(ii) | Price collar, max shares, max notional, duplicate detect | Fat-finger reaches the market |
| Controls under BD's exclusive control | Rule 15c3-5(b) | Separate BAR region + write permissions for risk params; strategy cannot write them | Strategy widens its own limit |
| Short-sale marking | Reg SHO 200(g) | 2-bit mark derived from `long_available_qty`; reject if ambiguous | Mismarked sales — a common enforcement theme |
| Locate before short | Reg SHO 203(b) | Per-symbol `shortable` flag + `locate_qty`, pushed by slow path | Naked short |
| SSR price test | Reg SHO 201 | `ssr_active[sym]` from ITCH; `price > NBB` strict comparison | Off-by-one → thousands of violations |
| LULD band compliance | LULD Plan | Per-symbol band registers; reject outside band | Order rejected or, worse, executed at a bad price |
| Halt handling | Nasdaq rules / LULD | `halted[sym]` from ITCH `H`/`h`; block new orders | Orders into a halted symbol |
| Self-trade prevention | FINRA 5210 | SMP group in OUCH; plus own-order-ID check in fabric | Wash-trade exposure |
| Nanosecond audit timestamps | CAT NMS Plan | PTP-disciplined FPGA counter; timestamp at emit/receive stage | Under-granular or undefensible timestamps |
| Full order lifecycle capture | CAT / Rule 613 | Every fast-path event DMA'd to the host log, lossless | Gaps in the audit trail |
| Cancel-intent evidence | Anti-manipulation | Reason code on every cancel | No contemporaneous record of intent |
| Change management | Reg SCI discipline / 3110 | Bitstream versioning, reproducible builds, reviewed diffs | Cannot prove what was running when |
| Kill switch | Rule 15c3-5 + venue rules | Hardware kill, bounded cycles, blocks in-flight | Runaway algorithm |

---

## Hardware implications

1. **`tick_size` is a per-symbol register field, not a constant.** Size it now
   (3 bits of `tick_class` indexing {$0.0001, $0.005, $0.01} is sufficient) even if
   today's regime only uses one value. Rule 612 is being amended.
2. **The order-price validity check is on the critical path** and must be one or two
   logic levels. Use a `tick_class` lookup + comparator, not a divider.
3. **Two price-validity domains.** Orders out: whole increments only. Fills in:
   sub-penny prices are legal and must be accepted by the fill/P&L path without
   truncation. Size the price field and the average-price accumulator accordingly.
4. **The ISO bit is hard-tied to zero** by a synthesis parameter that the production
   build script asserts. A CI check greps the elaborated design for it.
5. **The order mirror is updated from the OUCH ack, never from the send**, because
   price sliding legitimately changes the resting price.
6. **The risk gate is the sole path to TX.** Any lab bypass is guarded by a
   synthesis-time parameter forced to 0 in the production flow, checked in CI. There
   is no runtime register that enables it.
7. **Risk parameters live in a separate BAR region** from strategy parameters, with
   separate host write permissions, so "direct and exclusive control" is enforceable
   in the driver as well as in policy.
8. **The SSR comparison is strictly greater-than, against a conservative NBB.**
   Implement it once, in one place, with a directed test that proves the boundary
   case (`price == NBB` must reject).
9. **Feed staleness and gap counters are compliance instrumentation.** A per-venue
   staleness timer that invalidates your synthetic NBBO must gate the checks that
   reference the national best bid.
10. **Every fast-path event carries a PTP-disciplined nanosecond timestamp**, captured
    at the register stage where the event occurs, and is DMA'd to the host losslessly.
    A dropped log record is a hole in the audit trail — count drops and alarm on any
    nonzero value.
11. **Every cancel carries a machine-generated reason code.** It is the cheapest
    anti-spoofing defence available and it costs 4 bits.
12. **All position and notional arithmetic saturates and counts saturation.** A
    wrapped counter turns a risk control into a rubber stamp — see
    [../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) §9.
13. **Position on the FPGA is a risk control, not a book of record.** Clearly-erroneous
    busts and post-trade adjustments mean the true position lives on the slow path.
    Design for a bounded, monitored divergence — see
    [09-risk-controls-and-limits.md](09-risk-controls-and-limits.md) §7.

---

## Further reading

- [01-market-structure.md](01-market-structure.md) — venues, protected quotes, the Nasdaq family
- [02-sessions-auctions-and-halts.md](02-sessions-auctions-and-halts.md) — LULD, halts, SSR triggers in context
- [03-order-types-and-routing.md](03-order-types-and-routing.md) — post-only, price sliding, routable vs book-only
- [04-totalview-itch-5.0.md](04-totalview-itch-5.0.md) — where SSR, halt, and LULD state arrives
- [05-ouch-5.0-order-entry.md](05-ouch-5.0-order-entry.md) — the fields these rules constrain
- [07-fees-rebates-and-economics.md](07-fees-rebates-and-economics.md) — the access fee cap in economic context
- [08-connectivity-and-colocation.md](08-connectivity-and-colocation.md) — clock sync, DR testing, MPIDs
- [09-risk-controls-and-limits.md](09-risk-controls-and-limits.md) — the implementable check specification
- [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md) — the general risk framework
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — the gate in the pipeline
