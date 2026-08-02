# 03.06 — Risk and Compliance

> **Why this matters here:** everything else in these manuals is about being fast. This
> chapter is about the fact that **a fast system that is wrong destroys capital faster
> than a slow one** — and that the law knows it. The regulatory requirement for
> non-bypassable, automated, pre-trade controls is the reason the risk block lives in
> fabric rather than in software, and it is the single most consequential architectural
> constraint in the project.
>
> **Read this chapter as safety-critical engineering, not as paperwork.** Nothing here
> is optional and nothing here is negotiable against latency.

⚠️ **This document is an engineering orientation, not legal advice.** Every rule number
and threshold below carries a `Verify` note. A real-money system must be reviewed by
qualified compliance counsel and validated against current rule text.

---

## 1. SEC Rule 15c3-5 — the Market Access Rule

The regulatory foundation of this entire design.

Rule 15c3-5 (the "Market Access Rule", adopted 2010) requires a broker-dealer with market
access — or providing it to others — to establish, document, and maintain **risk
management controls and supervisory procedures** reasonably designed to manage the
financial, regulatory, and other risks of that access. The features that drive our
architecture:

| Rule feature | Architectural consequence |
| --- | --- |
| Controls must be applied on an **automated, pre-trade basis** | The check happens **before** the order leaves, in the order path, not in a monitoring process reading a log |
| Controls must be under the **direct and exclusive control** of the broker-dealer | We cannot delegate our risk gate to a vendor black box or rely solely on the exchange's controls |
| The rule effectively prohibits **"naked" or unfiltered access** | There is **no path to the wire that bypasses the risk block.** Not for testing, not for emergencies, not for a "trusted" strategy |
| Financial controls must prevent orders exceeding **pre-set credit or capital thresholds** | Aggregate notional and position limits, in hardware |
| Controls must prevent **erroneous orders** | Per-order size, price collar, and duplicate detection |
| Regulatory controls must prevent orders the firm is **not permitted to send** | Restricted lists, short-sale marking, symbol permissioning |
| Periodic review and a **senior-officer certification** | The control set must be documented, enumerable, and its behaviour demonstrable |

> **Verify:** the operative text is 17 CFR § 240.15c3-5 plus SEC staff FAQs (which address,
> among other things, the limited circumstances in which a broker-dealer may reasonably
> allocate certain controls to another broker-dealer, and the treatment of
> exchange-provided controls). Confirm applicability to our entity structure and
> market-access arrangement with counsel.

**The load-bearing phrase for this project:** *pre-trade, automated, non-bypassable.* An
FPGA fast path that could emit an order without passing a check would not merely be a bad
design — it would fail the rule. Hence hard rule #5 in
[../../CLAUDE.md](../../CLAUDE.md).

---

## 2. The required control categories

Each of these is a distinct check with its own limit, its own rejection reason code, and
its own counter.

| # | Control | What it prevents | Where the limit comes from |
| --- | --- | --- | --- |
| 1 | **Per-order share quantity** | Fat-finger size; a strategy with a corrupted `clip_size` | Static, per symbol × strategy |
| 2 | **Per-order notional** (`price × qty`) | Large size in an expensive name | Static, per strategy |
| 3 | **Price collar / reasonability band** | Orders far from the current market — buying at 10× or selling at 1/10× | Dynamic: a band around a **reference price** (last trade / NBBO mid / prior close) |
| 4 | **Aggregate position, per symbol** | Accumulating an unintended directional bet | Static, per symbol × strategy, and a firm-level cap |
| 5 | **Aggregate notional / gross exposure** | Total capital at risk exceeding credit limits | Firm-level; the 15c3-5(c)(1)(i) control |
| 6 | **Message / order rate limit** | Runaway loops; venue throttle breaches | Token bucket, per session and per strategy (§ [04-order-entry-protocols.md](04-order-entry-protocols.md) §9) |
| 7 | **Duplicate order detection** | The same order emitted repeatedly by a stuck trigger | Rolling hash of `{symbol, side, price, qty}` over a short window |
| 8 | **Restricted / prohibited symbol list** | Trading a name we are not permitted to trade (issuer restrictions, halts, hard-to-borrow, compliance blocks) | Bitmap indexed by symbol ID, pushed by the CPU |
| 9 | **Short-sale marking & locate** | Naked shorting; Reg SHO violations | Per-symbol "may short" bit + locate quantity, pushed by the CPU |
| 10 | **Short-sale price test** | Shorting below the national best bid while a Rule 201 circuit breaker is active | Per-symbol flag from the feed; changes the permitted price |
| 11 | **Self-match prevention** | Wash trades ([02-order-types-and-matching-engines.md](02-order-types-and-matching-engines.md) §5) | Own resting interest table |
| 12 | **Trading-state gate** | Orders into a halted symbol or the wrong session phase | Per-symbol state register from the feed |
| 13 | **In-flight credit pools** | Outrunning our own accounting ([04-order-entry-protocols.md](04-order-entry-protocols.md) §10) | Counters, granted by the CPU |
| 14 | **Master kill / arm** | Everything | §8 |

### Reg SHO specifics

Short selling adds obligations enforced **before** the order goes out: **order marking**
(every sale marked long, short, or short-exempt); **locate** (reasonable grounds to
believe the security can be borrowed and delivered by settlement, obtained *before* the
order); **close-out** of fails to deliver within specified timeframes; and a **price test
circuit breaker** that, once a security declines by a specified percentage from the prior
close, restricts short sales to prices above the national best bid for the rest of that
day and the following day.

> **Verify:** Regulation SHO, 17 CFR §§ 242.200–204 — Rule 200(g) (marking), 203(b)
> (locate), 204 (close-out), and 201 (price test and its trigger threshold). Confirm the
> current trigger percentage and restriction duration against the rule text.

**Hardware consequence:** the locate is a *slow-path* asset (the CPU obtains it pre-open
and intraday) but *enforcement* is fast-path. Per symbol the FPGA holds `may_short`
(1 bit), `short_qty_available` (saturating counter, decremented per short order emitted),
and `price_test_active` (1 bit, set from the feed). A short order with `may_short == 0`,
`short_qty_available == 0`, or a price at or below the NBB while `price_test_active` is
rejected and counted.

⚠️ **Marking a short sale as long is a serious violation and trivially easy to do by
accident** — e.g. when a position crosses from long to short mid-burst and the marking
logic reads a stale position. The marking decision must use the **same position register,
in the same cycle**, as the position limit check.

---

## 3. Pre-trade risk block design

### The critical insight: risk checks are parallel, not serial

The checks in §2 are almost all independent comparisons against independent limits. A
sequential pipeline of them would cost 12+ cycles (~77 ns at 156.25 MHz) for no reason.
Build **one parallel bank feeding an AND-reduce**:

```
                 ┌──────────────────────────────────────────────┐
   order         │  All checks evaluate IN PARALLEL              │
   candidate ───►│                                              │
   + book ref    │  ok[0]  qty     <= lim.max_qty        1 cyc  │
   + position    │  ok[1]  notional<= lim.max_notional   2 cyc ◄─── deepest (DSP mul)
   + params      │  ok[2]  |px - ref_px| <= lim.collar   1 cyc  │
                 │  ok[3]  pos_after in [min,max]        1 cyc  │
                 │  ok[4]  gross_notional <= lim         1 cyc  │
                 │  ok[5]  rate bucket has a token       1 cyc  │
                 │  ok[6]  not a duplicate (hash)        1 cyc  │
                 │  ok[7]  symbol not restricted         1 cyc  │
                 │  ok[8]  short permitted + located     1 cyc  │
                 │  ok[9]  price test satisfied          1 cyc  │
                 │  ok[10] no self-cross                 1 cyc  │
                 │  ok[11] symbol state == tradable      1 cyc  │
                 │  ok[12] credits available             1 cyc  │
                 └────────────────────┬─────────────────────────┘
                                      │  AND-reduce tree (2 levels)
                                      ▼
                        risk_ok = &ok  &  armed_q  &  ~kill_q
                                      │
                          ┌───────────┴────────────┐
                     risk_ok=1                risk_ok=0
                          ▼                        ▼
                     ENCODE & SEND        reject_reason = first_zero(ok)
                                          counter[reason][strat][sym]++
                                          → DMA reject record to CPU
```

**Latency: the deepest single check plus the reduce tree — roughly 3–4 cycles (≈ 20–26 ns
at 156.25 MHz), not 12.** An entirely acceptable price, and there is no version of this
project in which we shave it by removing a check.

The **ordering** still matters, for two reasons: it sets the priority used to report a
single attributable `reject_reason` when several checks fail at once, and a few checks
have genuine dependencies (position-after-fill needs the position read; notional needs
the multiply). Order by severity, so the most serious reason is the one reported.

### Fail-closed

```systemverilog
// The output enable. Note the polarity of everything: this expression must be
// affirmatively TRUE for an order to exist. Every unknown resolves to "no".
assign tx_order_valid = order_candidate_valid
                      & risk_all_ok        // AND of every check, default 0
                      & armed_q            // explicit operator arm, 0 at reset
                      & ~kill_q            // kill switch, 1 at reset
                      & session_up_q       // TCP session owned and healthy
                      & ~param_stale_q     // CPU heartbeat alive
                      & ~feed_gap_q;       // book believed correct
```

The design rules behind that expression:

1. **Every gating signal resets to its safe value**, and safe means "do not trade":
   `armed_q = 0`, `kill_q = 1`, `session_up_q = 0`, `risk_ok = 0`.
2. **Limits reset to zero, not to maximum.** A limit coming out of reset at `0xFFFFFFFF`
   is a check that passes on reset — §10.
3. **Unknown is not permitted.** No limit record loaded ⇒ not tradable. Unknown trading
   state ⇒ not tradable.
4. **Exactly one place in the design asserts `tx_order_valid`.** Grep for it; there must
   be one driver. A second appearing in review fails the review.
5. **Cancels take a different path.** A cancel reduces risk and must not be blocked by
   position, notional, collar, or credit checks — it is gated only by `session_up_q`. See
   §8 for the kill-switch interaction.

### Counters and attribution

Every rejection increments a **saturating** counter indexed by `{reason, strategy_slot,
symbol_slot}` and emits a DMA reject record carrying the full order candidate and reason.

- **Saturating, never wrapping** — a wrapped counter reads as zero and hides an incident
  ([../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) §9).
- **Attributable** — "we rejected 4 000 orders today" is useless; "strategy 3 on symbol
  slot 118 hit the duplicate check 4 000 times between 09:31:02 and 09:31:04" is an
  incident report.
- **Alertable** — a non-zero credit-exhaustion or self-cross counter is a **P1**, not a
  statistic. Severe reasons also carry **sticky first-occurrence flags** so a transient
  between polls is never lost.

---

## 4. The kill switch

**Requirement:** a single, unambiguous action that stops all outbound order flow and, on
most designs, also cancels resting orders — with a **bounded, documented, and measured**
response time.

| Property | Requirement for this project |
| --- | --- |
| **Trigger surface** | (a) a single BAR register write from the CPU; (b) a hardware watchdog (CPU heartbeat lost); (c) an internal invariant violation (counter saturation, credit over-return, feed gap, session loss); (d) an operator action via the control plane; (e) the venue-side kill switch, independently |
| **Response bound** | Order emission stops within a **documented number of clock cycles** from the register write reaching the FPGA — target: single-digit cycles, i.e. tens of nanoseconds. This number is measured and published, not estimated. |
| **Enforcement** | **Hardware.** `kill_q` gates `tx_order_valid` directly. Not a software flag, not a message to a process, not a strategy parameter. |
| **Scope** | Global (all strategies, all symbols, all sessions). Per-strategy and per-symbol disables exist separately and are *not* the kill switch. |
| **Reset behaviour** | `kill_q` is **set** on reset. Trading requires an explicit disarm-and-arm sequence. |
| **Latching** | Sticky. Once tripped, only an explicit, deliberate, logged operator action clears it. It must not auto-clear on the condition going away. |
| **Cancels** | Killing **must not** prevent cancels. The safe state is "no new orders, and get flat", not "no messages at all". |
| **Independence** | The kill path must not depend on the strategy logic, the parameter tables, or the book being healthy — it is a direct gate on the output. |

⚠️ **A kill switch that requires healthy software to work is not a kill switch** — the
failure mode you are protecting against includes "the software is the thing that broke".
Hence a flip-flop gate in the output path, a hardware watchdog, and the venue-side kill
switch as an independent second layer.

⚠️ **Test it.** Exercised in every regression run, every hardware soak test, and a
rehearsed operational drill on a schedule. An untested kill switch is a comment. Measure
its response on real hardware and record the number with `N=`, per
[../../CLAUDE.md](../../CLAUDE.md) §4.

> **Verify:** exchanges also provide their own kill-switch and risk-management
> facilities. Confirm what Nasdaq offers on our ports, how it is invoked, and its
> response characteristics — [../08-nasdaq/09-risk-controls-and-limits.md](../08-nasdaq/09-risk-controls-and-limits.md).

---

## 5. Erroneous orders, halts, and volatility mechanisms

Three separate mechanisms that all change what "normal" means, and all of which our
hardware must recognise.

### Clearly erroneous executions

Exchanges may review and break trades executed at prices substantially away from the
market, under numerical guidelines varying by reference price and time of day.

> **Verify:** Nasdaq's clearly erroneous execution rule and guidelines (Nasdaq Equity 11,
> historically Rule 11890) — confirm current thresholds and filing deadlines.

**Consequence:** a fill can be **broken after the fact**, so our position is not final at
fill time. The CPU handles break messages, and the FPGA's position register must be
correctable through an explicit, audited adjustment path — itself a risk, see §10.

### Limit Up-Limit Down (LULD)

Per-security price bands computed around a rolling reference price. Quotations outside
the band are not permitted, and a market that does not exit a limit state within a
specified period enters a brief trading pause. Band widths are percentage-based and vary
by security tier, price level, and time of day (widening near the open and close).

> **Verify:** the National Market System Plan to Address Extraordinary Market Volatility
> (the "LULD Plan") — tier definitions, percentage parameters, doubling periods, and
> pause durations, from the plan text.

**Consequence:** band information and auction-collar messages arrive **on the feed**. The
FPGA consumes them, holds per-symbol upper/lower band registers, and **rejects any order
priced outside the band** — both because the venue will reject it anyway, and because an
out-of-band price is strong evidence our pricing logic has malfunctioned.

### Market-wide circuit breakers (MWCB)

Market-wide halts triggered by a percentage decline in a broad market index from the
prior close, at escalating levels, with durations depending on level and time of day.

> **Verify:** MWCB levels, reference index, thresholds, durations, and time-of-day rules
> are in exchange rules (e.g. Nasdaq Equity 4, Rule 4121) and associated SEC filings.
> Do not hardcode a percentage from memory.

**Consequence:** MWCB decline-level and status messages arrive on the ITCH feed. On any
status change the FPGA transitions to a non-trading state **immediately and by default**,
resuming only on explicit operator action. Halts are the highest-risk moments to be
holding a position, so the response is "flatten and stop", not "wait". Nasdaq detail:
[../08-nasdaq/02-sessions-auctions-and-halts.md](../08-nasdaq/02-sessions-auctions-and-halts.md).

---

## 6. Reg SCI, briefly

**Regulation SCI** imposes requirements on designated "SCI entities" — exchanges,
clearing agencies, certain ATSs, plan processors — covering system capacity, integrity,
resiliency, availability, BC/DR testing, SEC incident notification, and change management.

> **Verify:** 17 CFR §§ 242.1000–1007. A proprietary trading firm is generally **not** an
> SCI entity, though certain firms may be designated "SCI members" for mandatory BC/DR
> testing, and the SEC has proposed expanding the rule's scope. Confirm with counsel.

**Why it appears here even if it does not bind us:** it is the regulator's articulated
standard for disciplined operation of a critical trading system, and our venue is bound
by it. Adopt the posture regardless — documented, reviewable **change management** for
every bitstream reaching production
([../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md));
pre-deployment testing with a defined regression suite and a canary stage
([../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md));
capacity planning with evidence (for us, "sustains line rate",
[03-market-data-protocols.md](03-market-data-protocols.md) §7); incident detection,
escalation, and post-mortem discipline; and business continuity for the loss of the
primary card, host, or site.

---

## 7. Audit trail and record-keeping

### CAT

The **Consolidated Audit Trail** (SEC Rule 613) requires reporting of order and trade
events across US equities and listed options with prescribed event types, fields, and
timestamps, so regulators can reconstruct order lifecycles market-wide.

> **Verify:** SEC Rule 613, the CAT NMS Plan, and the industry-member technical
> specifications published by FINRA CAT. Clock-synchronisation obligations (e.g. FINRA
> Rule 4590) specify NIST-relative tolerances that differ by system type and timestamp
> granularity — confirm current requirements rather than assuming a figure.

**What the FPGA must produce so the CPU can satisfy this:**

| Field | Source |
| --- | --- |
| Order token / ClOrdID | Generated in fabric ([04-order-entry-protocols.md](04-order-entry-protocols.md) §7) |
| Symbol, side, quantity, price, order type, TIF, capacity | The order candidate record |
| **Event timestamp** at the required granularity | Hardware timestamp at the TX PHY boundary, from a disciplined clock |
| Originating strategy / decision attribution | `strategy_id`, carried in the token and the DMA record |
| The market data event that **caused** the order | The RX timestamp and feed sequence number, carried through the pipeline |
| Rejections and their reasons | The reject records from §3 |

⚠️ **Every order candidate must produce a DMA record, including rejected ones.** A
rejection is a decision the system made; losing it means you cannot reconstruct why the
system did what it did. Rejects are also the highest-value diagnostic data in the system.

⚠️ **The causal link matters more than you expect.** Carrying `{rx_timestamp,
feed_sequence_number}` from the triggering market data message through to the order
record costs a few dozen bits of pipeline width and turns "we sent a strange order at
10:14:03" into "message #4 812 991 caused it, and here it is". Budget the bits.

All timestamps derive from a **single, disciplined clock** (PTP/GPS) with offset and
drift monitored and logged — a timestamp you cannot defend is not an audit trail. See
[../06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md).

---

## 8. Kill-switch interaction with cancels — the rule people get wrong

```
   KILLED  ≠  SILENT
   KILLED  =  no NEW orders, cancels STILL WORK, get flat
```

If the kill switch blocks *all* outbound messages, hitting it while holding live quotes
leaves you with **unmanaged resting orders in a market you have decided is unsafe** —
worse than the condition you were escaping. The correct safe state: (1) new order
emission stops within a bounded number of cycles; (2) **mass cancel is issued** for all
live orders, from hardware where possible, via the venue's mass-cancel facility where
available; (3) cancels remain permitted for the rest of the session; (4) fills continue
to be processed and accounted for, because you are still receiving them.

⚠️ Similarly, **the risk block must never reject a cancel.** Every check in §2 limits
risk; a cancel *reduces* it. Wiring cancels through the same rejection logic as new
orders turns a protective mechanism into a trap — the same principle as the separate
cancel token bucket in [04-order-entry-protocols.md](04-order-entry-protocols.md) §9.

---

## 9. MiFID II / RTS 6 — the European analogue

If this system ever trades in the EU/UK, the applicable framework is **MiFID II** and in
particular **RTS 6** (Commission Delegated Regulation (EU) 2017/589), covering
organisational requirements for investment firms engaged in algorithmic trading. Its
themes map closely onto everything above:

| RTS 6 theme | Our equivalent |
| --- | --- |
| **Kill functionality** — the ability to cancel all unexecuted orders immediately | §4 and §8 |
| Pre-trade controls on price, value, volume, and message rate | §2, §3 |
| Post-trade controls and real-time monitoring | Drop-copy reconciliation, telemetry |
| **Testing** — conformance testing with the venue, and testing in a non-live environment | [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md) |
| **Annual self-assessment and validation**, documented | Documented control inventory and its review |
| Staff competence, governance, and clear responsibility for algorithms | Strategy ownership, sign-off |
| Business continuity | Operations tier |

> **Verify:** RTS 6 (Reg. (EU) 2017/589), RTS 7 for venues, the UK's onshored
> equivalents, and the algorithmic-trading notification and record-keeping requirements
> in MiFID II Article 17. Confirm with counsel before any EU/UK activity.

The practical takeaway: **a control architecture built to satisfy 15c3-5 properly already
satisfies most of RTS 6.** Build it once, build it right.

---

## 10. What can go catastrophically wrong

Real failure modes, each with a concrete design defence. Read this section twice.

### (a) The runaway loop

A strategy fires, the order is emitted, the resulting book event re-triggers the
strategy, and the loop closes — at FPGA rates, thousands of orders per millisecond.
**This is the shape of every famous algorithmic trading disaster**: a fast component
doing the wrong thing at full speed while every slow component remained unaware. The
most-cited example (Knight Capital, 2012) lost roughly $460 million in about 45 minutes
from a deployment defect combined with repurposed logic — a change-management failure
whose consequences were delivered by an automated system that nothing stopped.

> **Verify:** the SEC administrative proceeding against Knight Capital Americas LLC
> (2013) is the authoritative public account, and instructive precisely because it is a
> 15c3-5 case.

**Defences, layered:** rate limiting (token bucket, §2.6) → duplicate detection (§2.7) →
in-flight credit pools including `unaccounted_by_cpu`
([04-order-entry-protocols.md](04-order-entry-protocols.md) §10) → position and notional
limits (§2.4, §2.5) → per-(strategy, symbol) cooldown timer in the trigger → watchdog
kill. **No single one is sufficient. All of them are cheap.**

### (b) Stale parameters

The CPU parameter process dies, hangs, or is mid-deploy. The FPGA keeps trading on the
last values it received; fair values drift, the volatility regime changes, and quotes
that were correct at 09:35 are giving money away at 09:50.

**Defence:** the parameter heartbeat/staleness watchdog
([05-strategy-taxonomy.md](05-strategy-taxonomy.md) §6). No refresh within a bounded time
⇒ affected strategies disable themselves. The FPGA does not need permission to stop.

### (c) Wrapped counters

A position, notional, or credit counter overflows and wraps to a small value. **The risk
check then passes.** The system believes it is flat while holding an enormous position —
no error, no exception, no alert, the numbers simply look fine.

**Defence:** all risk arithmetic **saturates**, and every saturation event is counted and
alarmed
([../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) §9).
Width every risk register for the true worst case, then add a bit. A saturation event
trips the kill switch — it means a value left the range the design reasoned about.

### (d) Position drift from missed or misapplied fills

A fill is dropped, misparsed, arrives after we freed the slot, arrives for an
unrecognised token, or arrives while the order was in `PENDING_CANCEL`. Position and
reality diverge quietly, and every subsequent risk check is computed against a fiction.

**Defences:** implement the `PENDING_CANCEL → FILLED` transition
([02-order-types-and-matching-engines.md](02-order-types-and-matching-engines.md) §9);
free order slots **only** on a terminal venue message; use self-describing tokens so an
unrecognised fill is still attributable
([04-order-entry-protocols.md](04-order-entry-protocols.md) §7); reconcile against an
**independent drop copy**, with divergence beyond a tight tolerance tripping the kill
switch. Any CPU correction of the FPGA position register is explicit, logged, audited,
and triggers a review — a routine correction path hides the bug that makes it necessary.

### (e) A risk check that passes on reset

Limits initialise to `0xFF…F` (or to unwritten flash, which is the same thing). The FPGA
comes up, the strategy is somehow enabled, and every check passes because every limit is
effectively infinite. The most insidious item here, because it exists only in the window
between power-on and configuration — the window in which nobody is watching.

**Defence:** **limits reset to zero and `kill_q` resets to 1.** A zero limit rejects
everything, the correct behaviour for an unconfigured system. Add an explicit `armed_q`
that only an operator sets and a per-symbol `limits_loaded` bit set by the CPU write that
loads the limits — no bit, no trading. Assert in simulation that no order can be emitted
before both are set, and put an ILA trigger on it in hardware.

### (f) The feed is wrong, so the book is wrong, so the price is wrong

A sequence gap, a mis-applied non-displayed trade, or a message-length bug corrupts the
book. The strategy computes correct-looking prices from a fictional market, and the risk
collar — referenced to *our* book — approves them.

**Defence:** the collar's reference price must have an **independent component** (last
trade from the feed, prior close from the CPU, or the LULD band) rather than deriving
solely from the same book the strategy used. Plus gap ⇒ immediate quote pull
([03-market-data-protocols.md](03-market-data-protocols.md) §5) and crossed-book
detection as a hard alarm.

### (g) The test that becomes production

A "temporary" bypass, a debug register that disables a check, a simulation-only path left
in the build, a UAT endpoint left pointing at production.

**Defence:** there is **no bypass to build in the first place** — the risk block has no
disable bit and no alternate path (§1). Debug facilities that could weaken a control do
not exist in a production bitstream, and the build system distinguishes production from
debug by an identifier readable at runtime and checked by the host before arming.

---

## 11. RULES FOR THIS PROJECT

These are enforceable review criteria. A change that violates one does not merit
discussion about latency.

1. **There is exactly one path to the wire, and it passes through the hardware risk
   block.** No bypass exists in any bitstream, for any reason.
2. **Every gate resets to "do not trade."** `kill_q = 1`, `armed_q = 0`, all limits `= 0`,
   `limits_loaded = 0`, credits `= 0`.
3. **All risk arithmetic saturates**, and every saturation event trips the kill switch.
4. **Every rejection is counted and attributable** by `{reason, strategy, symbol}`, and
   emits a DMA record.
5. **Every order candidate produces an audit record — including rejects** — carrying the
   causing `{rx_timestamp, feed_sequence_number}`.
6. **The kill switch is a hardware gate on the output**, sticky, with a measured and
   published cycle-count response bound, tested in every regression and rehearsed on a
   schedule.
7. **Killed means no new orders, not no messages.** Cancels always work. The risk block
   never rejects a cancel.
8. **A parameter staleness watchdog disables trading without CPU involvement.**
9. **Position is reconciled against an independent drop copy** by a separate process;
   divergence trips the kill switch.
10. **Feed gap, crossed book, session loss, retransmit, credit exhaustion, or counter
    saturation ⇒ quotes pull, immediately, in hardware.**
11. **Changes to limits, sizing, the kill switch, or the risk block are high blast
    radius**: isolated commits, explicit review, never bundled
    ([../../CLAUDE.md](../../CLAUDE.md) §6).
12. **Every specific threshold, percentage, and rule citation in this document is
    verified against current primary sources before it is encoded anywhere.**

---

## Further reading

- [02-order-types-and-matching-engines.md](02-order-types-and-matching-engines.md) — the order state machine the position accounting depends on
- [04-order-entry-protocols.md](04-order-entry-protocols.md) — credit pools, throttles, drop copies
- [05-strategy-taxonomy.md](05-strategy-taxonomy.md) — parameter atomicity and the staleness watchdog
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — the RTL implementation of §3 and §4
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) — surfacing the counters in §3
- [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md) — proving the controls work
- [../08-nasdaq/09-risk-controls-and-limits.md](../08-nasdaq/09-risk-controls-and-limits.md) — Nasdaq's own risk facilities and member obligations
- [../08-nasdaq/06-regnms-and-compliance.md](../08-nasdaq/06-regnms-and-compliance.md) — Reg NMS, order protection, LULD in Nasdaq terms
