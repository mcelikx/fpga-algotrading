# 08.02 — Sessions, Auctions, Halts, and Volatility Controls

> **Why this matters here:** the FPGA does not get to assume the market is open and
> continuous. It must know, per symbol, per microsecond, whether that symbol is
> tradable, what price band it is confined to, whether short sales are restricted,
> and whether an auction is in progress. **Every one of these is a hardware gate on
> the order path**, and every one of them arrives as an ITCH message the feed handler
> must decode and act on. Getting this wrong does not produce a slow system — it
> produces orders sent into a halted stock, which is a regulatory event.

---

## 1. The trading day

```
 04:00 ─────────────── 09:30 ──────────────────────── 16:00 ─────────────── 20:00
   │   PRE-MARKET        │       REGULAR HOURS           │    POST-MARKET      │
   │                     │                               │                     │
   │  no auction until  OPENING                       CLOSING                  │
   │  the cross         CROSS                          CROSS                   │
   │                                                                           │
   └── system hours start                                    system hours end ──┘

           09:28 ──► opening imbalance (NOII) dissemination begins
                           15:50 ──► closing imbalance (NOII) dissemination begins
```

| Phase | Approx. ET window | What happens | Fast-path relevance |
| --- | --- | --- | --- |
| System start / order acceptance | early morning | Session comes up; ITCH `System Event` "start of messages"/"start of system hours" | FPGA arms; symbol tables loaded |
| **Pre-market** | 04:00 – 09:30 | Continuous trading, thin, wide spreads, no NBBO protection obligations comparable to regular hours | Usually **disabled** for our strategies |
| Opening imbalance period | from ~09:28 | NOII messages disseminate the projected cross | Signal source; not an order trigger |
| **Opening Cross** | 09:30 | Single-price auction; establishes the official opening price | FPGA must **not** be resting continuous quotes it does not intend to participate with |
| **Regular hours** | 09:30 – 16:00 | Continuous price-time trading | The main event |
| Closing imbalance period | from ~15:50 | Closing NOII disseminates | Signal source |
| **Closing Cross** | 16:00 | Single-price auction; establishes the **official closing price** | Highest-volume moment of the day |
| **Post-market** | 16:00 – 20:00 | Continuous, thin | Usually **disabled** |
| System end | after post-market | `end of system hours`, `end of messages` | FPGA disarms, counters snapshotted |

> ⚠️ **Verify all times.** Extended-hours schedules have been changed (including
> proposals and moves toward longer or overnight sessions), holiday and half-day
> schedules change annually, and imbalance dissemination start times and cut-offs have
> been amended by rule filing. The authoritative sources are **nasdaqtrader.com**
> (trading schedule and holiday calendar), the **Nasdaq Equity Rulebook** (Equity 4,
> Rules 4701/4702/4752/4754 series), and **Nasdaq Equity Trader Alerts**. Treat the
> table above as the *shape* of the day, and load the actual times from a host-side
> calendar file, never from a constant baked into RTL.

**Project rule:** the FPGA holds a small **session schedule table** in registers,
written by the host at start of day (start/end of each phase in nanoseconds-since-
midnight, matching the ITCH timestamp base). The FPGA compares the incoming ITCH
timestamp against it. This means a schedule change is a config push, not a rebuild.

---

## 2. The Nasdaq crosses

Nasdaq runs three single-price auctions ("crosses"). All are the same mechanism with
different triggers.

| Cross | When | Purpose | ITCH `Cross Type` (verify) |
| --- | --- | --- | --- |
| **Opening Cross** | 09:30 | Sets the official opening price for Nasdaq-listed securities | "O" |
| **Closing Cross** | 16:00 | Sets the **official closing price** — the benchmark index/ETF/NAV price | "C" |
| **Halt / IPO Cross** | on resumption | Reopens a halted or paused security; launches an IPO | "H" |
| Intraday / post-close cross | as scheduled | Nasdaq Cross Network | "I" |

> **Verify:** cross-type character codes appear in ITCH **Cross Trade (Q)** and
> **NOII (I)** messages. Confirm against the **Nasdaq TotalView-ITCH 5.0
> specification (nasdaqtrader.com/Trading/TradingSpecs)**.

### 2.1 How a cross works, conceptually

A cross is a **call auction**: instead of matching continuously, the engine collects
interest and computes the single price that maximises executable volume.

```
  1. Collect: continuous book orders eligible for the cross
             + on-open / on-close orders (MOO, LOO, MOC, LOC)
             + imbalance-only orders (IO)

  2. For each candidate price P, compute:
         executable(P) = min( total buy interest at ≥ P ,
                              total sell interest at ≤ P )

  3. Choose P* maximising executable(P).
     Tie-breaks, in order (conceptually):
        a. minimise the residual imbalance at P
        b. prefer the price closer to a reference (e.g. the current book / prior close)
        c. venue-specified final rule

  4. Print the crossed volume at P* as a single Cross Trade.
     Residual on-open/on-close interest either joins the continuous book or cancels,
     per its order type.
```

> ⚠️ **Verify the exact tie-break hierarchy and the reference price definition** in
> the **Nasdaq Equity Rulebook** (Rule 4752 for the Opening Cross, 4753 for the Halt
> Cross, 4754 for the Closing Cross). The four-step *shape* above is stable; the
> precise ordering, the treatment of the "Nasdaq Official Opening/Closing Price"
> when no cross occurs, and collar behaviour are rule text.

### 2.2 Order types that participate

| Type | Name | Behaviour | Cancellable? |
| --- | --- | --- | --- |
| **MOO** | Market on Open | Executes at the opening cross price, any price | Until the cut-off |
| **LOO** | Limit on Open | Participates only if the cross price is at or better than the limit | Until the cut-off |
| **MOC** | Market on Close | Executes at the closing cross price | Until the cut-off, then locked |
| **LOC** | Limit on Close | Limit-constrained close participation | Until the cut-off, then locked |
| **IO / OIO / CIO** | Imbalance Only | **Only** provides liquidity against an imbalance; never initiates one; effectively a limit order that can only offset | Per rule |
| Continuous book orders | — | Eligible displayed/non-displayed interest is swept into the cross | Normally |

> ⚠️ **Verify the entry cut-off times and the cancel/modify restrictions.** The
> pattern is: on-open/on-close orders may be entered up to a cut-off; after a later
> point they may not be cancelled or modified at all (except to correct a bona fide
> error); imbalance-only orders have their own, later, window. The specific clock
> times have been amended more than once. Read Rules 4752/4754 and the current
> **Nasdaq Trader** closing-cross FAQ.

⚠️ **A MOC or LOC that you can no longer cancel is an unhedgeable, unbounded
exposure to the auction price.** For an FPGA system this is a categorical rule:
**auction orders are never emitted by the fast path.** They are CPU-originated,
human-or-supervised-process approved, and pass through the same hardware risk gate.

### 2.3 The Net Order Imbalance Indicator (NOII)

During the imbalance dissemination period Nasdaq broadcasts, per symbol, a periodic
**NOII** message (ITCH type **I**) describing the state of the pending cross.

| NOII field (conceptual) | Meaning | Use |
| --- | --- | --- |
| Paired shares | Shares that would execute at the current reference price | Size of the auction |
| Imbalance shares | Unpaired shares remaining | The tradable opportunity |
| Imbalance direction | Buy-side / sell-side / none / insufficient orders | Sign of the pressure |
| **Current reference price** | Price at which paired shares are maximised right now | The auction's current clearing estimate |
| **Near price** | Cross price using *both* cross and continuous book interest | Best estimate of where the auction clears |
| **Far price** | Cross price using cross-eligible interest only | Auction-only view |
| Cross type | Which cross this refers to (open/close/halt) | Dispatch |
| Price variation indicator | How far the near price sits from the current reference | Dislocation measure |

> **Verify** the field list, order, widths, the exact definitions of near/far/current
> reference price, and the dissemination interval against the **TotalView-ITCH 5.0
> specification**. Dissemination frequency has been increased over time (historically
> every few seconds, later more frequent).

**Why the close is the biggest moment of the day:** index funds, ETFs, mutual fund
NAV strikes, benchmark executions and index rebalances all reference the **official
closing price**. A meaningful share of the day's total volume prints in the closing
cross in a single instant. The NOII is the market's only pre-trade view of it, which
makes the imbalance period one of the most heavily modelled windows in US equities.

For our system the closing cross is a **slow-path opportunity, not a fast-path one**:
the signal horizon is seconds-to-minutes, the order type is not fast-path legal, and
the competition is on modelling quality, not nanoseconds.

---

## 3. Trading halts

### 3.1 Categories

| Category | Trigger | Who calls it | Resumption |
| --- | --- | --- | --- |
| **Regulatory — news** | Material news pending or released | Primary listing market | Quotation period, then Halt Cross |
| **Regulatory — LULD pause** | Price band limit state persists (see §4) | Automatic, per the LULD Plan | 5-minute pause, then reopening auction |
| **Regulatory — MWCB** | Market-wide circuit breaker level breached | Market-wide | Per level (see §5) |
| **Regulatory — other** | Extraordinary market activity, additional information requested, non-compliance | Primary listing market | Varies |
| **Operational** | Exchange systems issue on **one** venue | That venue | Trading continues elsewhere |
| **IPO** | New listing, pre-launch | Listing market | IPO Cross |

⚠️ **A regulatory halt binds all US markets. An operational halt binds only the
halting venue.** These arrive as *different ITCH messages* — Stock Trading Action
(**H**) versus Operational Halt (**h**) — and must be handled differently. Halting
your own trading in a symbol because one venue had an operational problem costs you
opportunity; *failing* to halt on a regulatory halt costs you a rule violation.

### 3.2 Halt reason codes

Nasdaq publishes a short alphanumeric reason code with each trading action. The
familiar families:

| Family | Meaning (conceptual) |
| --- | --- |
| `T1` | News pending |
| `T2` | News released |
| `T5`-type | Single-stock volatility / trading pause |
| `T6`-type | Extraordinary market activity |
| `T8`-type | Market-wide circuit breaker halt |
| `T12` | Additional information requested from the company |
| `H`-family | Halts related to regulatory filing delinquency / non-compliance |
| `LUDP` / `LUDS` | LULD pause / LULD straddle condition |
| `M1` / `M2` | MWCB Level 1 / Level 2 |
| `IPO`-family | IPO issue not yet trading / quotation period / released for quotation |
| `D`, `R`-family | News dissemination, resumption qualifiers |

> ⚠️ **Verify every code.** The authoritative list of trading-halt reason codes is
> published by Nasdaq (nasdaqtrader.com trading-halt resources) and the code set
> carried in ITCH is defined in the **TotalView-ITCH 5.0 specification**. Codes are
> added and retired. **Design the FPGA so that an unrecognised reason code is treated
> as "halted", not as "tradable".** Fail safe.

### 3.3 Trading state, as the FPGA must see it

The ITCH **Stock Trading Action (H)** message carries a per-symbol *trading state*.
The states, conceptually:

| State | Meaning | FPGA action |
| --- | --- | --- |
| **Trading** | Normal continuous trading on Nasdaq | Orders permitted |
| **Halted** | Halted across all US markets | ⚠️ **Block all order entry in this symbol, everywhere.** Cancel resting orders if policy requires |
| **Paused** | LULD trading pause (Nasdaq-listed) | ⚠️ Block order entry; expect a reopening auction |
| **Quotation only** | Quoting permitted, no executions — the period before a resumption cross | Quotes may be permitted by policy; **executions will not occur** — do not model fills |

> **Verify** the exact single-character state codes and their precise definitions in
> the **TotalView-ITCH 5.0 specification**. The four-state structure is stable.

⚠️ **Absolute requirement.** The order path must contain a per-symbol *tradable* bit
derived from this state, and that bit must gate order emission **in the order gateway,
downstream of the strategy** — not inside the strategy. A strategy bug must not be
able to emit into a halted symbol. This sits alongside the kill switch and the risk
gate in [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md).

### 3.4 The Halt Cross and IPO Cross

Resumption from a halt is not a return to continuous trading — it is an **auction**:

```
   HALTED  ──►  QUOTATION-ONLY period  ──►  HALT CROSS  ──►  TRADING
               (orders accepted,           (single price     (continuous)
                no executions,              print)
                NOII disseminated,
                LULD auction collars
                published via ITCH "J")
```

- The quotation period lets the market re-form a two-sided quote before any print.
- **LULD Auction Collar (ITCH `J`)** messages publish the upper/lower collar prices
  within which the reopening auction may print, plus extension information. If the
  auction cannot clear inside the collar, the collar is widened and the auction is
  delayed. ⚠️ **The FPGA must not assume the reopening will happen at a fixed time.**
- An **IPO** follows the same shape, with a display-only / pre-launch period, an
  IPO quotation release time and qualifier (ITCH **IPO Quoting Period Update, `K`**),
  and then the cross.

---

## 4. LULD — Limit Up-Limit Down

The single most important volatility control for an order-emitting FPGA, because it
constrains **the price you are allowed to send**, continuously, per symbol.

### 4.1 Mechanism

A rolling **reference price** is computed per security (conceptually the average of
eligible trade prices over the preceding several minutes). Around it, a **price band**
is placed:

```
   Upper band  =  reference_price × (1 + band_percentage)
   Lower band  =  reference_price × (1 − band_percentage)
```

The bands are recalculated continuously as the reference price moves. **No trade may
print outside the bands**, and quotes are constrained relative to them.

### 4.2 Tiering and band width

| Dimension | Structure |
| --- | --- |
| **Tier 1** | S&P 500, Russell 1000 constituents, and selected ETPs — narrower bands |
| **Tier 2** | All other NMS stocks — wider bands |
| Price-dependent | Bands widen for low-priced securities; the lowest price bucket uses a percentage-or-cents floor |
| Time-of-day | Bands are **doubled** during the opening period and during the closing period |

Illustrative structure — ⚠️ **numbers must be confirmed against the LULD Plan**:

| Security | Price | Band (regular period) | Band (open/close periods) |
| --- | --- | --- | --- |
| Tier 1 | above the high-price threshold | narrow % | doubled |
| Tier 2 | above the high-price threshold | wider % | doubled |
| Either | mid price bucket | wider % | doubled |
| Either | lowest price bucket | greater of a % or a fixed cents amount | doubled |

> ⚠️ **Verify the tier definitions, the exact band percentages, the price thresholds
> that separate the buckets, and the exact clock windows during which bands are
> doubled.** The source is **the LULD Plan** (the National Market System Plan to
> Address Extraordinary Market Volatility) as currently amended, plus **Nasdaq Equity
> Trader Alerts** for operational detail. These have been amended, and proposals to
> change the band structure recur. **Do not bake percentages into RTL** — the band
> percentages belong in a host-loaded per-symbol table, and the bands themselves are
> best taken from the feed where available rather than recomputed.

### 4.3 Limit state and straddle state

| Condition | Definition (conceptual) | What it signals |
| --- | --- | --- |
| **Limit state** | The NBB is at the **upper** band, or the NBO is at the **lower** band, and the quote is non-executable | The market is pinned at the band |
| **Straddle state** | The NBB is **below** the lower band, or the NBO is **above** the upper band — the band cuts through the quote | Fragile; a pause may follow |
| **Trading pause** | Limit state persists beyond the prescribed interval | 5-minute pause, then a reopening auction |

> **Verify** the persistence interval that converts a limit state into a pause, and
> the pause duration and extension rules, against the LULD Plan. The commonly cited
> shape is *a short persistence window, then a five-minute pause*.

### 4.4 Why this is a hardware requirement, not a software one

⚠️ **The FPGA must know the current band for every symbol it can trade, and must not
emit an order priced outside it.** Reasons:

1. **Orders outside the band are rejected or repriced.** A rejected order is wasted
   latency and a wasted message-rate allowance; a *repriced* order rests somewhere you
   did not intend, which corrupts your order state (see the price-sliding discussion
   in [03-order-types-and-routing.md](03-order-types-and-routing.md)).
2. **A pause is exactly when a naive strategy is most dangerous.** Prices are moving
   fast, the book is thin, and a stale model will happily quote through the band.
3. **You cannot ask the host.** The round trip to a CPU for a band check is longer
   than the entire tick-to-trade budget. The band must be a BRAM read in the order
   path, indexed by stock locate.
4. **The check must be downstream of the strategy**, in the risk/gateway block, so a
   strategy bug cannot bypass it.

Implementation shape:

```systemverilog
// Per-symbol band table, direct-indexed by ITCH stock locate.
// Written by the host (and/or by the feed handler from band-bearing messages).
typedef struct packed {
    logic [31:0] upper_band;      // scaled integer, 4 implied decimals
    logic [31:0] lower_band;
    logic        bands_valid;     // 0 => treat as NOT tradable
    logic        limit_state;
    logic        straddle_state;
} luld_state_t;

// In the order gateway, one BRAM read + two compares, fully pipelined:
wire band_ok = luld.bands_valid
             && (order_price <= luld.upper_band)
             && (order_price >= luld.lower_band);
```

⚠️ `bands_valid == 0` must mean **not tradable**. At start of day, after a gap, after
a halt, and after any symbol-table reload, bands are unknown — and unknown must fail
closed.

---

## 5. Market-Wide Circuit Breakers

A market-wide halt triggered by a large single-day decline in a broad index.

| Level | Trigger (decline in the reference index from the prior close) | Effect |
| --- | --- | --- |
| **Level 1** | smallest threshold | Market-wide trading halt of a fixed duration; only once per day; not triggered after a late-afternoon cut-off |
| **Level 2** | larger threshold | Same shape as Level 1, separate once-per-day allowance |
| **Level 3** | largest threshold | Trading halted **for the remainder of the day**, at any time |

> ⚠️ **Verify the percentage thresholds, the halt durations, the reference index, and
> the afternoon cut-off after which Level 1/2 halts no longer apply.** Sources: the
> **Nasdaq Equity Rulebook** (market-wide circuit breaker rule), the relevant NMS plan,
> and **Nasdaq Equity Trader Alerts**. The commonly cited shape is *three levels at
> increasing decline percentages, with the top level closing the market for the day*.

ITCH carries this directly:

- **MWCB Decline Level (`V`)** — publishes the actual price levels for each of the
  three thresholds, computed from the prior close. Sent near the start of the day.
  ⚠️ **The price fields in this message use a different scale from ordinary ITCH
  prices** — confirm the implied decimal places in the spec before decoding.
- **MWCB Status (`W`)** — announces that a level has been breached.

**FPGA action on `W`: immediate, unconditional, global order-emission stop.** This is
the same mechanism as the kill switch, triggered from the feed handler instead of from
a host register write. It should reuse the same shutdown path so it is tested by the
same tests.

---

## 6. Short Sale Restriction (Reg SHO Rule 201)

| Aspect | Behaviour |
| --- | --- |
| Trigger | A security declines by a threshold percentage from the prior day's official closing price |
| Duration | **Remainder of that trading day plus the whole of the following trading day** |
| Effect | A short sale may only be **displayed or executed at a price above the current national best bid** |
| Feed | ITCH **Reg SHO Restriction (`Y`)** message, per symbol, with an action code |

> **Verify** the trigger percentage, the precise definition of the reference closing
> price, the exemptions, and the action-code values in the `Y` message. Sources: **SEC
> Regulation SHO Rule 201** and the **TotalView-ITCH 5.0 specification**. The commonly
> cited trigger is a **10 % intraday decline**; the two-day duration is the stable part.

⚠️ **This is a hard constraint on the order encoder, not on the strategy.** When SSR
is active for a symbol:

```
   if (is_sell && is_short && ssr_active[locate])
       require: order_price > current_NBB
       (an order priced at or below the NBB must be rejected or re-priced UP)
```

Design consequences:

1. The gateway needs a per-symbol `ssr_active` bit, set/cleared by the `Y` message
   decoder and also settable by the host (because SSR persists across days, and the
   FPGA does not remember yesterday).
2. The gateway needs the **current NBB** available in the order path — which means the
   NBBO aggregation result must be routed to the risk block, not only to the strategy.
3. ⚠️ The FPGA must know whether an order is a **short sale**. That is a *position*
   question ("am I long enough to sell long?"), and position is maintained jointly by
   fabric and host. The conservative hardware rule: **if the hardware position for the
   symbol is not strictly greater than or equal to the sell quantity, treat the sell
   as short** and apply the SSR price constraint. Being conservative here costs a
   fill; being wrong here is a Reg SHO violation.
4. ⚠️ `ssr_active` unknown must fail **closed** for short sales.

---

## 7. Half days and holidays

- The market closes early (commonly **13:00 ET**, with a correspondingly shortened
  post-market session) on a handful of days each year — typically around
  Independence Day, the day after Thanksgiving, and Christmas Eve when it falls on a
  weekday.
- Full-day holidays follow the published exchange calendar.

> **Verify annually** against the **nasdaqtrader.com holiday and trading schedule**.

⚠️ **A half day changes the closing cross time, and therefore the imbalance
dissemination window and the closing-period LULD band doubling.** A system with a
hardcoded 16:00 close will, on a half day, keep quoting into a closed market and will
apply the wrong LULD band width in the last half hour of the real session. This is
exactly why §1's session table is host-loaded.

---

## 8. Hardware implications

### 8.1 The per-symbol trading state record

This is the central data structure this document produces. One BRAM row per stock
locate, read in the order path on **every** outbound order.

| Field | Width (suggested) | Source | Fail-safe default |
| --- | --- | --- | --- |
| `tradable` | 1 | ITCH `H` trading state | **0** |
| `trading_state` | 2 | ITCH `H` (trading / halted / paused / quote-only) | halted |
| `halt_reason` | 8 (mapped) | ITCH `H` reason field → small code | unknown ⇒ halted |
| `operational_halt` | 1 per market | ITCH `h` | 0, but gate that market only |
| `luld_upper` | 32 | Host / feed | 0 |
| `luld_lower` | 32 | Host / feed | 0 |
| `luld_valid` | 1 | derived | **0** |
| `luld_limit_state` | 1 | derived from NBBO vs. bands | 0 |
| `ssr_active` | 1 | ITCH `Y` + host start-of-day | **1 for safety until known** |
| `auction_active` | 1 | NOII / cross type / session table | 0 |
| `mwcb_stop` | 1 (global) | ITCH `W` | 0 |
| `enabled` | 1 | Host risk config | **0** |
| `round_lot_size` | 16 | ITCH `R` | 100 |
| `luld_tier` | 2 | ITCH `R` | Tier 2 (wider) |

```
Order path gate (all combinational after one BRAM read, ~1–2 cycles):

  emit_ok =  enabled
          &  tradable
          & ~mwcb_stop
          & ~kill_switch
          &  luld_valid  &  (price <= luld_upper) & (price >= luld_lower)
          & ( ~is_short_sale | (price > nbb) | ~ssr_active )
          &  risk_checks_ok
```

⚠️ Every term that is **not** satisfied must increment a distinct counter. "Order
suppressed" with no attribution is an unobservable system. See CLAUDE.md hard rule 7.

### 8.2 Reacting to state-change messages

| ITCH message | FPGA reaction | Latency requirement |
| --- | --- | --- |
| Stock Trading Action (`H`) → halted/paused | Clear `tradable` **before** any subsequent order can be emitted | Must be in the same pipeline as the order path; a race here is a violation |
| Stock Trading Action (`H`) → trading | Set `tradable` | Not urgent, but must not be lost |
| Reg SHO (`Y`) | Set/clear `ssr_active` | Same as above |
| MWCB Status (`W`) | Assert global stop | **Immediate**, highest priority |
| LULD Auction Collar (`J`) | Load collar prices; mark auction in progress | Before the reopening print |
| Operational Halt (`h`) | Gate that market only | Immediate for that market |
| System Event (`S`) | Advance session state machine | Bounded |
| NOII (`I`) | Update auction state; forward to host | Slow path |

⚠️ **Ordering hazard.** If the state-update path and the order-emission path are
separate pipelines, a halt message and an order can cross. The safe structure is:
the state table is written by the feed handler, and the order gateway reads it
**after** the strategy has decided — so any halt that was decoded before the order
reaches the gateway is honoured. Document the exact number of cycles of exposure and
count any order that is emitted within that window of a state change.

### 8.3 Session state machine

```
  RESET ──► TABLES_LOADING ──► PREOPEN ──► OPEN_AUCTION ──► CONTINUOUS
                                                                │
                                              CLOSE_AUCTION ◄────┘
                                                     │
                                                POST ──► CLOSED
```

- Transitions are driven by **both** the ITCH System Event message and the host-loaded
  schedule table; require agreement, and alarm on disagreement.
- `CONTINUOUS` is the only state in which the fast path may originate orders under
  the default project policy.
- Any state other than `CONTINUOUS` reaching the order gateway sets a global
  suppression bit with its own counter.

---

## Further reading

- [01-market-structure.md](01-market-structure.md) — who runs the auctions and why the listing venue matters
- [03-order-types-and-routing.md](03-order-types-and-routing.md) — MOO/LOO/MOC/LOC/IO and price sliding
- [04-totalview-itch-5.0.md](04-totalview-itch-5.0.md) — the `S`/`H`/`Y`/`V`/`W`/`J`/`K`/`h`/`I` messages that drive everything here
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — where the gate lives
- [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md) — the regulatory framing
- [../03-algotrading/02-order-types-and-matching-engines.md](../03-algotrading/02-order-types-and-matching-engines.md) — auctions in the abstract
