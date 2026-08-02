# 08.01 — US Equity Market Structure and Where Nasdaq Sits

> **Why this matters here:** our tick-to-trade path is not racing "the market" — it is
> racing specific counterparties to a specific matching engine in a specific building
> in Carteret, New Jersey. Everything downstream in this tier (sessions, order types,
> ITCH, OUCH) is a consequence of the structure described here. If you get the
> structure wrong you will build a technically excellent system pointed at the wrong
> liquidity.

The concepts (limit order books, priority, adverse selection) are in
[../03-algotrading/01-market-microstructure.md](../03-algotrading/01-market-microstructure.md).
This document is the **map of the venue landscape** and Nasdaq's place in it.

---

## 1. The landscape in one picture

US equities is a fragmented, regulated, all-electronic market. A single symbol trades
simultaneously in three structurally different places:

```
                    ┌──────────────────────────────────────────────┐
   RETAIL ORDER     │  WHOLESALERS / INTERNALIZERS                 │
   (broker app)  ──►│  Citadel Securities, Virtu, Jane Street, …   │──┐
                    │  price-improve vs NBBO, print to a TRF       │  │
                    └──────────────────────────────────────────────┘  │
                                                                      │
   INSTITUTIONAL    ┌──────────────────────────────────────────────┐  │
   ORDER (algo)  ──►│  ATSs / DARK POOLS                           │──┤
                    │  broker crossing networks, midpoint venues   │  │
                    └──────────────────────────────────────────────┘  │
                                                                      ├─► TRF
   ANY ORDER        ┌──────────────────────────────────────────────┐  │  (tape print,
                 ──►│  LIT EXCHANGES  — 16+ national securities    │──┘   no quote)
                    │  exchanges, incl. Nasdaq / BX / PSX          │
                    │  displayed quotes, protected under Reg NMS   │──► SIP quote+trade
                    └──────────────────────────────────────────────┘
```

**Only the lit exchanges publish protected quotations.** Wholesaler and ATS volume
appears on the tape as a *trade print* (via a FINRA Trade Reporting Facility) after
the fact, with no ex-ante quote. This is the single most important structural fact
for a book-driven strategy: **a large fraction of the volume you see printed never
existed as displayable liquidity you could have interacted with.**

| Segment | Publishes a quote? | Where the print comes from | Can our FPGA trade here? |
| --- | --- | --- | --- |
| National securities exchange (Nasdaq, NYSE, Cboe, MEMX, IEX, …) | **Yes**, protected | The exchange itself | **Yes** — this is our target |
| ATS / dark pool | No | FINRA TRF | Only via a broker/sponsored route — not a fast path |
| Wholesaler / internalizer | No | FINRA TRF | No — requires retail order flow relationships |
| Single-dealer platform | No | FINRA TRF | No |

> **Verify:** the exact count of registered national securities exchanges changes
> (new entrants have been approved in recent years, and exchanges are periodically
> consolidated or wound down). Check the SEC's list of registered national securities
> exchanges before writing a venue table into configuration.

---

## 2. The three Nasdaq-operated equity exchanges

Nasdaq, Inc. operates **three separate US equity exchanges**, each a distinct SRO
with its own rulebook, its own matching engine instance, its own ITCH feed, its own
OUCH port, and its own fee schedule.

| Exchange | Common name | Historical origin | Fee model (see verify note) | Typical role |
| --- | --- | --- | --- | --- |
| The Nasdaq Stock Market LLC | **Nasdaq**, "the Q", INET | Nasdaq / INET | **Maker-taker** — rebate to add, fee to remove | Primary venue; largest Nasdaq-family share; runs the opening/closing crosses for Nasdaq-listed names |
| Nasdaq BX | **BX** | Boston Stock Exchange | **Taker-maker ("inverted")** — rebate to *remove*, fee to *add* | Cheap/rebated liquidity removal; queue-position venue for passive fills |
| Nasdaq PSX | **PSX** | Philadelphia Stock Exchange | Its own schedule, historically distinct from both of the above | Smallest of the three; niche allocation/fee experiments |

> ⚠️ **Verify before trusting any of the above economics.** Fee models, rebate tiers,
> and even the *sign* of a venue's maker/taker relationship are changed by rule filing
> and can flip. BX's inverted model and PSX's distinct model are the historical
> pattern, not a guarantee of today's schedule. Read **the Nasdaq Price List
> (nasdaqtrader.com)** for the current fee schedule of each of the three markets, and
> **the Nasdaq Equity Rules / Rulebook (nasdaq.cchwallstreet.com)** for the allocation
> rules. PSX in particular has historically experimented with size-related priority at
> the inside rather than pure price-time — **confirm the current PSX allocation
> algorithm in its rulebook before assuming FIFO.**

### Why an FPGA firm connects to more than one

1. **Different fee sign ⇒ different optimal strategy.** On a maker-taker venue you
   are paid to rest and charged to hit. On an inverted venue the reverse. The same
   signal can be profitable as a passive strategy on Nasdaq and as an aggressive
   strategy on BX.
2. **Queue position is cheaper where volume is thinner.** Being first in queue on
   Nasdaq for a liquid name is nearly impossible; on BX/PSX it may be achievable,
   and an inverted venue pays you to take from that queue.
3. **Reg NMS forces you to care about all protected quotes anyway.** You must know
   the NBBO to price correctly, and the NBBO is formed from every protected venue.
4. **Failover.** A venue outage is a real, recurring event.

⚠️ Three exchanges means **three ITCH feeds, three symbol-locate namespaces, three
OUCH sessions, three sets of trading-state machines**. The stock locate code on
Nasdaq's feed is *not* the same integer as the stock locate code for the same symbol
on BX's feed. See §7 and
[../04-system-architecture/02-feed-handler-design.md](../04-system-architecture/02-feed-handler-design.md).

---

## 3. Listing tiers and tape attribution

### Nasdaq listing tiers

Nasdaq lists companies into three tiers with different quantitative and governance
standards. The tier is disseminated in the ITCH **Stock Directory (R)** message's
market category field.

| Tier | Character | Standard |
| --- | --- | --- |
| Nasdaq **Global Select** Market | highest financial + liquidity requirements | large caps |
| Nasdaq **Global** Market | mid-tier | |
| Nasdaq **Capital** Market | lowest listing standard | small caps, higher halt/volatility risk |

> **Verify:** the single-character market-category codes carried in the ITCH Stock
> Directory message (and the additional codes used for NYSE/Arca/BATS-listed issues
> that also appear on Nasdaq's feed) must be read from the **Nasdaq TotalView-ITCH 5.0
> specification (nasdaqtrader.com/Trading/TradingSpecs)**.

### Tapes

Every NMS security is attributed to exactly one **tape**, determined by its *listing*
venue. The tape decides which SIP consolidates it, and which plan governs its data.

| Tape | Securities | SIP / plan | Processor operated by |
| --- | --- | --- | --- |
| **A** | NYSE-listed | CTA / CQS | NYSE |
| **B** | NYSE Arca, NYSE American, Cboe BZX and other non-Nasdaq-listed | CTA / CQS | NYSE |
| **C** | **Nasdaq-listed** | UTP (UTDF trades / UQDF quotes) | **Nasdaq** |

Why the tape matters to us:

- **The listing venue runs the auctions.** A Nasdaq-listed (Tape C) name's opening
  and closing crosses happen *on Nasdaq*. A Tape A name's closing auction happens on
  NYSE, and Nasdaq's closing cross in that name is a small side-show. If your strategy
  is auction-adjacent, tape determines where you must be.
- **The listing venue runs the halts.** Regulatory halts originate from the primary
  listing market and propagate to all venues.
- **Data entitlement and cost are per-tape.**
- Nasdaq's ITCH feed carries **all NMS securities traded on Nasdaq**, not just
  Nasdaq-listed ones. Do not confuse "on the Nasdaq feed" with "Tape C".

---

## 4. SIP vs. direct feeds

Two ways to learn what the market is doing:

| | **SIP** (UTP for Tape C, CTA/CQS for A/B) | **Direct exchange feed** (e.g. TotalView-ITCH) |
| --- | --- | --- |
| Content | Consolidated **top of book** per venue + last sale; core data | **Full depth, order-by-order**, every event on that one venue |
| Coverage | All venues in one stream | One venue per feed — you subscribe to all of them yourself |
| Path | Venue → SIP processor → aggregation → you | Venue matching engine → multicast → you |
| Added latency | Extra network hops + consolidation processing at the SIP | ~none beyond the exchange's own publication |
| Order of magnitude | tens of µs to ms of additional delay vs. direct, depending on era and geography | the reference point |
| Cost | Comparatively cheap | Expensive: data fees + cross-connects + colocation × N venues |
| Use in our system | **Slow path only** — reference, reconciliation, compliance | **Fast path** — the only acceptable input to the strategy trigger |

> **Verify:** SIP latency has been reduced substantially over time and cited figures
> age badly. Do not quote a number without a current measurement or a current
> published statistic. What is *structurally* true and does not age: the SIP has
> strictly more hops and strictly more work to do than a direct feed, so it is
> strictly later.

⚠️ **A strategy that computes the NBBO from direct feeds sees a different NBBO than
the SIP publishes, at any given instant.** Both are "correct". Regulatory obligations
(e.g. order protection, and trade-through analysis) are generally assessed against
protected quotations as disseminated; your internal book is a *prediction* of that.
Keep them separate, log both, and never let the fast path's view silently become the
compliance record. See
[../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md).

> **Verify:** the SEC's **Market Data Infrastructure Rule** re-architects consolidated
> data (decentralised consolidation via competing consolidators, an expanded "core
> data" definition including some depth-of-book, auction information and odd-lot
> quotes). Its implementation has been staged and litigated. Check the current status
> before making a build-vs-buy data decision — the relative advantage of direct feeds
> is exactly what this rule narrows.

---

## 5. Participant taxonomy — who you are racing

| Participant | What they do | Speed | Do we race them? |
| --- | --- | --- | --- |
| **Registered market maker** (Nasdaq) | Registered per-symbol; must maintain continuous two-sided quotes within a designated percentage of the NBBO | Very fast; often FPGA | **Yes, directly** |
| **DMM** (NYSE only — contrast) | *One* designated market maker per listed security, with affirmative obligations and a role in the NYSE open/close | Fast, but a structurally different role | Not on Nasdaq — **Nasdaq has no DMM**; it has many competing registered MMs |
| **Proprietary HFT** (unregistered) | Latency arb, stat arb, taking strategies. No quoting obligation | Very fast; FPGA | **Yes** |
| **Wholesaler / internalizer** | Executes retail flow off-exchange; hedges/lays off residual risk on-exchange | Fast | Indirectly — their hedging flow *is* exchange flow |
| **Institutional buy-side** (via broker algos) | Works large parent orders over minutes/hours in child slices | Slow by design | We are the counterparty they are trying not to be picked off by |
| **Retail** | Small marketable orders | Slow | Mostly never reaches us — see §6 |

### Nasdaq market maker registration and quoting obligations

A firm may register as a market maker in specific Nasdaq-listed securities. In
exchange for certain benefits, a registered MM takes on **continuous two-sided
quoting obligations**: it must maintain a displayed bid and offer of at least a
minimum size, priced within a **designated percentage** of the NBBO, for a required
proportion of the trading day.

The structure of the obligation, which is stable:

```
  bid_price  ≥  NBB × (1 − designated_percentage)
  ask_price  ≤  NBO × (1 + designated_percentage)

  designated_percentage widens for less liquid tiers,
  and widens further during the opening and closing periods,
  and is tied to the LULD tiering of the security.
```

> ⚠️ **Verify every number.** The designated percentages by LULD tier and by
> time-of-day, the minimum displayed size, and the required daily coverage are rule
> text and have been amended. Read the **Nasdaq Equity Rulebook** (market maker
> quotation requirements, Equity 2 / Rule 4613 series) and any relevant **Nasdaq
> Equity Trader Alerts**. Do not hardcode a percentage from memory — if a quoting
> obligation is not met, that is a regulatory matter, not a performance issue.

**Design consequence:** if we register as a market maker, the FPGA acquires a
*positive obligation*, not just a permission. The quote-maintenance logic becomes
safety-critical: a strategy that pulls quotes on a volatility spike is exactly the
behaviour the obligation exists to prevent. That decision belongs to the firm, not to
the RTL — but the RTL must be able to enforce "always quote within X% of NBBO" as a
hardware invariant if the firm takes it on.

---

## 6. Payment for order flow and what the book does *not* show you

Most US retail marketable order flow is not routed to an exchange. A retail broker
sells (or is otherwise compensated for) its order flow to a **wholesaler**, which
internalizes the order — executing it as principal at or inside the NBBO, giving the
retail customer **price improvement**, and printing the trade to a TRF.

Consequences that directly shape what our FPGA sees:

1. **The exchange book is disproportionately institutional and professional flow.**
   The "uninformed retail" counterparty that classically pays the spread has largely
   been intercepted before the exchange.
2. **Adverse selection on-exchange is therefore higher than a naive model predicts.**
   If you rest a displayed quote on Nasdaq and get filled, the counterparty is more
   likely to be informed than if you had been filled by a random slice of all US
   retail. Price your passive strategies accordingly — see
   [../03-algotrading/05-strategy-taxonomy.md](../03-algotrading/05-strategy-taxonomy.md).
3. **Off-exchange prints arrive on the tape with no prior quote**, and often with a
   reporting delay relative to the execution. Using TRF prints as a real-time signal
   is treacherous.
4. Nasdaq's **Retail Price Improvement (RPI)** programme is the exchange's answer:
   it lets a member post non-displayed price-improving interest that interacts only
   with identified retail orders. See
   [03-order-types-and-routing.md](03-order-types-and-routing.md) and the ITCH
   **RPII (N)** message in [04-totalview-itch-5.0.md](04-totalview-itch-5.0.md).

> **Verify:** the off-exchange share of consolidated volume moves and has trended up
> over time; the exchange/off-exchange split and Nasdaq's own market share are
> published periodically. Cite **nasdaqtrader.com** market share statistics or a
> current SEC/FINRA statistic rather than a remembered percentage.

---

## 7. Physical and logical organisation of the venue

| Thing | What it is | Note |
| --- | --- | --- |
| Matching engine | Per-market, partitioned by symbol across engine instances | A symbol lives on one partition; different symbols may have independent latency |
| Primary data centre | **Carteret, New Jersey** — Nasdaq's US equity markets data centre | **Verify** current facility and any migration plans on nasdaqtrader.com |
| Colocation | Cabinets in the same facility, with standardised cable lengths | Latency equalisation between cabinets is a stated policy — **verify the current colo product** |
| Cross-connect | Your cabinet → Nasdaq's access switches | Distinct connects for market data (multicast) and order entry (TCP) |
| Peer venues | NYSE (Mahwah NJ), Cboe / MEMX / IEX (Secaucus NJ area) | Inter-venue distances are the physical floor on any cross-venue strategy |

```
   Carteret (Nasdaq)  ────── microwave / mmWave / fibre ──────  Secaucus (Cboe, MEMX)
          │                                                            │
          └────────────────── fibre ─────────── Mahwah (NYSE) ─────────┘

   Fibre ≈ 5 ns per metre. A cross-venue strategy's latency floor is
   set by geography, not by your RTL.  Know the numbers for YOUR links.
```

> **Verify:** inter-datacentre distances, latencies and the availability of
> wireless routes are commercial facts about your specific connectivity vendor.
> Measure them; do not assume them. See
> [../06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md).

---

## 8. Fragmentation, market share, and why it matters to a strategy

No US venue has a dominant share. Consolidated volume is split across the exchanges,
the ATSs and the wholesalers, and each exchange's share of *lit* volume is itself
split across a dozen venues.

What fragmentation does to a strategy:

| Effect | Consequence for our design |
| --- | --- |
| The NBBO is formed from many venues | To know the NBBO first, you need **every** protected venue's direct feed, decoded in parallel |
| A large order sweeps many venues | Venue A's trade is a *predictor* of venue B's trade microseconds later — the classic latency-arb signal |
| Liquidity at one venue is thin | Your fill probability at any single venue is low; queue position matters more |
| Quotes lock/cross across venues transiently | Locked/crossed markets are normal on the microsecond scale, and drive **price sliding** (see [03-order-types-and-routing.md](03-order-types-and-routing.md)) |
| Routing between venues is slow | An exchange's outbound router adds hundreds of µs+; **routing away is never a fast-path action** |

⚠️ **Project rule: our fast path is single-venue-decision, single-venue-action.**
Cross-venue signals may *feed* the trigger (multiple feed handlers into one strategy
block), but the order always goes directly to a venue we are connected to. We never
ask an exchange to route on our behalf on the fast path — an exchange router's
latency is orders of magnitude larger than our entire budget.

---

## 9. Hardware implications

| Structural fact | Concrete FPGA requirement |
| --- | --- |
| 3 Nasdaq markets, each a separate SRO | 3 independent feed-handler instances and 3 independent order-gateway sessions, parameterised by market. **Do not share state between them.** |
| Stock locate codes are per-market and per-day | Symbol table is a **per-market BRAM**, loaded at session start from the Stock Directory (R) messages of *that* market's feed. Never index market B's table with market A's locate. |
| Many venues form the NBBO | N parallel decode pipelines feeding one NBBO aggregation block. Budget the aggregation: it is a max/min over N venues, so keep it **incremental**, not a reduction tree ([../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) §6) |
| Direct feed is the only fast-path input | The SIP feed, if consumed at all, terminates in the **host**, never in the trigger path |
| Auctions live at the listing venue | Auction/imbalance logic is only meaningful for Tape C symbols on Nasdaq. Gate it by a per-symbol "is primary listing" bit in the symbol table |
| Halts originate at the listing venue and bind everywhere | Per-symbol trading state must be maintained **per market**, and a halt seen on any feed must gate order emission on all of them. See [02-sessions-auctions-and-halts.md](02-sessions-auctions-and-halts.md) |
| Registered MM obligations (if taken on) | A hardware invariant block that can enforce "quote present and within X% of NBBO" independently of the strategy, with a counter for every breach-second |
| Fee sign differs per market | Strategy parameter tables are **per-market**. A single "aggressive/passive" flag is not sufficient; the sign of the rebate is a per-market constant loaded over PCIe |
| Exchange routing is slow | The order gateway must be able to force a **no-route / post-only** designation in hardware, so a misconfigured strategy cannot emit a routable order |
| Off-exchange volume is invisible pre-trade | Volume-based strategy features derived from ITCH cover only Nasdaq's own volume. Do not calibrate a "% of market volume" parameter against consolidated volume using single-venue data |

### Configuration that must be loaded before the open

| Item | Source | Where it lives in fabric |
| --- | --- | --- |
| Symbol → locate map, per market | ITCH Stock Directory (R) replay or a start-of-day file | BRAM, direct-indexed by locate |
| Round lot size, tier, LULD tier, ETP flags | Stock Directory (R) | Same BRAM row |
| Per-market fee sign / rebate parameters | Host config from the Nasdaq Price List | Strategy parameter BRAM |
| Enabled-symbol bitmap | Host risk config | 1 bit per locate — the cheapest possible kill for a symbol |
| Per-symbol position and notional limits | Host risk config | Pre-trade risk block ([../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md)) |

---

## Further reading

- [02-sessions-auctions-and-halts.md](02-sessions-auctions-and-halts.md) — when the market is open, and when it stops
- [03-order-types-and-routing.md](03-order-types-and-routing.md) — what you can actually send
- [04-totalview-itch-5.0.md](04-totalview-itch-5.0.md) — the feed this document's structure is delivered over
- [../03-algotrading/01-market-microstructure.md](../03-algotrading/01-market-microstructure.md) — the venue-neutral theory
- [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md) — Reg NMS, market access, and obligations
- [../02-networking/03-multicast-feeds-and-arbitration.md](../02-networking/03-multicast-feeds-and-arbitration.md) — receiving N venues at once
- [../04-system-architecture/02-feed-handler-design.md](../04-system-architecture/02-feed-handler-design.md) — the per-market decode instance
