# 09.09 — Failure Modes and Postmortems

> **Why this matters here:** every choice in `rtl/fpga_top.sv` — cut-through MACs, no
> backpressure, fixed-offset decode, a 20-cycle fabric path — exists to make a decision
> arrive before anyone else's. **None of them distinguish a correct decision from a wrong
> one.** A sub-microsecond tick-to-trade path is a sub-microsecond wrong-trade path, and it
> runs at line rate, unattended, against real money. Everything that makes this system fast
> makes it fail fast, and at scale.
>
> [03.06](../03-algotrading/06-risk-and-compliance.md) §10 **states** these risks in one
> page. **This file is the operational catalogue**: each of its seven entries becomes a
> structured detection-and-prevention scenario here, and ten more are added. Read 03.06
> §10 first — it is the summary; this is the reference.

---

## 1. The failure taxonomy for this domain

A web service that breaks **stops serving**: requests error, users notice, and the blast
radius is bounded by the thing not working. A trading system that breaks **keeps trading** —
well-formed, correctly checksummed, venue-accepted orders, at full speed, in a direction
nobody intended.

| Property | Consequence for design |
| --- | --- |
| **Fails fast** | First bad event to material loss is milliseconds. No human is in that loop; detection lives in fabric or in a 1 Hz host loop, never in a dashboard someone glances at |
| **Fails profitably-looking** | Nothing errors. The only evidence is a number being wrong |
| **Fails at scale** | The same defect applies to every symbol, every tick, every order, at once |
| **Unbounded on the tail** | Position × adverse move. Nothing caps the product except a limit you deliberately built |
| **Legally consequential** | Pre-trade controls are a rule requirement, not a preference ([03.06](../03-algotrading/06-risk-and-compliance.md) §1) |

> **DOCTRINE: every failure mode below is either detected by a named counter, health bit,
> or assertion — or it is invisible, and an invisible failure in this domain is
> unbounded.** This is CLAUDE.md §5.7 restated as a coverage obligation: a failure mode
> with no row in §6 is not "unlikely", it is **unmonitored**.

Every entry in §2 has four parts: **What it looks like from outside** (the symptom to a
human, to the venue, in the P&L) / **Mechanism** (how the bug produces it) / **What would
have caught it** (the counter, health bit, assertion, or reconciliation *in this design*,
by name) / **The design feature that prevents it** (structural — something that makes the
failure inexpressible).

⚠️ If the fourth part is a procedure ("we check this before arming"), the failure is not
prevented, it is *scheduled*. Procedures decay; a flip-flop that resets to zero does not.

---

## 2. The catalogue

### F1 — The runaway order loop

**Outside.** `orders_emitted` climbing at a rate no configuration explains, the `led` kill
bit dark, everything else green. To the venue: a message-rate spike on one port, then
throttling, then a port disable. In the P&L: a one-directional position accumulating faster
than the position line refreshes. **The signature is the message rate, not the loss** — loss
lags this failure by seconds.

**Mechanism.** Two variants needing different defences:

| Variant | Loop closes through | Period |
| --- | --- | --- |
| (a) **Self-observation** — our own `A`/`F` Add appears in the feed, moves `book_top`, re-triggers the condition that emitted it | The venue sequencer and our own RX path | One order round trip — thousands/second |
| (b) **Retry storm** — an OUCH `Rejected`/`Canceled` causes an immediate re-emit with no backoff, rejected identically | `order_gateway` ack decode → `strategy_engine` | The ack latency — **faster than (a)**, and it never converges because a deterministic reject is an infinite loop |

(b) is worse: the reject path is the error path, the least-tested path in the design.

**Caught by.** The message-rate token bucket inside `u_risk_gate`, whose exhaustion
increments `risk_reject_cnt[RATE]` and sets health bit 15 (rate limiter engaged).
`credit_avail` deasserting within `K` orders (`credit_starved`). The duplicate check
(`risk_reject_cnt[DUP]`). The venue's own throttle as `venue_rejects[reason]` — but that is
the last line, and by then you are in an incident.

**Prevented by.** A `pending` bit per symbol per side in `strategy_engine` — one live order
intent per symbol, cleared only on a terminal OUCH message, so the loop cannot re-arm before
the previous order resolves. Bounded in-flight credit (`credit_avail` / `cfg_credit_return`),
capping how far the fabric outruns host accounting **by construction, not by threshold**. The
messages-per-interval limiter implemented **as a risk check inside `u_risk_gate`**, so it
cannot be routed around and its trips are attributed like every other rejection. Own-order
identification (attributed quoting,
[01-queue-position-and-fill-probability.md](01-queue-position-and-fill-probability.md) §3.3)
so variant (a) is structurally recognisable rather than heuristically guessed.

⚠️ A limiter that *drops* silently instead of rejecting-and-counting turns a runaway into an
invisible runaway. Its counter firing at all is a page — the strategy has already lost its mind.

### F2 — Stale parameters

**Outside.** Nothing. Quotes placed, fills arriving, latency nominal. The P&L bleeds at a
rate consistent with "the strategy is slightly wrong", indistinguishable from "the market
changed" until someone diffs loaded parameters against intended ones.

**Mechanism.** Three bugs, one symptom: the host parameter process died or hung after arming,
so the fabric holds this morning's — or yesterday's — values; the load ran but targeted the
wrong bank, slot, or file, so `cfg_strat_commit` fired over content nobody intended; or the
load never ran and the fabric trades on whatever survived the last reconfiguration.

**Caught by.** `param_crc` — the fabric-computed CRC of the live bank, read back and compared
against the CRC of what the host believes it sent; mismatch sets health bit 12.
`param_reload_count` not incrementing across a scheduled load. The `cfg_heartbeat` watchdog
(`host_heartbeat_age_ms`, health bit 9), which **blocks** new orders, not merely warns. A
parameter *generation* counter written alongside the values and covered by the CRC, so "right
CRC, wrong generation" is caught too.

**Prevented by.** Rule 4 of the `fpga_top.sv` header — reset state is trading disabled with
all limits zero — plus the assertion `core_rst |-> !cfg_trading_en`. A zeroed limit set
rejects everything, so "never loaded" fails closed instead of trading unconstrained. The arm
sequence refuses `cfg_trading_en` unless the host has read back `BUILD_ID`/`GIT_SHA` **and**
the parameter generation and CRC it expects. Daily full-bank readback is a required pre-open
step.

⚠️ The insidious form is a *partial* load that CRCs correctly because the host computed the
CRC over what it wrote rather than what it intended. The generation counter must come from
the parameter **source artifact**, not from the writer.

### F3 — Position drift from missed fills

**Outside.** The fabric's position register says one thing, the drop copy another. Risk
checks pass on orders that should be rejected, because the projected-position check is
computed against a fiction. In the P&L: an exposure nobody sized, appearing at the close.

**Mechanism.** An `Executed` is missed (SoupBinTCP gap, unhandled message type, length bug);
a fill arrives for a token already retired and is dropped rather than applied; a fill lands on
the wrong `fill_sym` because a token→slot mapping was reused; a bust arrives out of band; or
an out-of-band cancel (cancel-on-disconnect, venue self-match prevention) removes interest the
fabric still believes is live
([04.05](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) §10). **Drift is
monotonic and silent** — nothing in the fabric can notice, because the fabric's position is
its only view of the truth.

**Caught by.** Reconciliation only, and only against an *independent* source: the host's own
position derived from the **raw ack bytes** on the DMA audit ring — not from the fabric's
decoded `fill_*` outputs, since a shared decoder reproduces the shared bug and reconciles
perfectly against a wrong answer — compared against `position[slot]` on a bounded cadence and
against the venue drop copy. A divergence counter with an alert threshold, and the
fabric↔host↔drop-copy mismatch Tier 1 page, which
[06.03](../06-operations/03-monitoring-and-telemetry.md) §7 rightly calls the most dangerous
alert in the system. Bounded-lag contract:
[08.09](../08-nasdaq/09-risk-controls-and-limits.md) §7.

**Prevented by.** Bounded in-flight credit: `credit_avail` caps orders emitted ahead of host
accounting, so **drift is bounded by construction** — worst-case unsupervised exposure is
`K × max_notional`, a number you state to a risk committee rather than hope about. Plus the
structural point that makes the whole thing tractable:

> **RULE: the fabric's position is a *safety estimate*, not an accounting record.** Its job
> is to be **conservative**, never accurate. Over-estimating exposure costs a quote we did
> not place; under-estimating costs a position we did not intend, uncapped. So every
> ambiguity resolves toward *more* exposure: unacked orders count against the limit,
> in-flight cancels do not relieve it, an unattributable fill moves position in the
> direction that tightens the check. The accounting record lives on the host.

⚠️ A routinely-used "position correction" register hides the bug that makes it necessary.
Reconciliation **overwrites** through the atomic parameter path and is logged and reviewed;
it never incrementally adjusts.

### F4 — A wrapped counter defeating a risk check

**Outside.** Nothing at all. Zero rejections, position reads small. The purest silent failure
in the design: a check that is present, enabled, correct, and evaluating a number that lost
its top bit.

**Mechanism.** An accumulator sized for a reasonable day overflows on an unreasonable one.
`pos + qty` wraps modulo 2^W, projected position appears near zero, `pos_after <= max_position`
passes — and so does every order after it. The check has not failed; it has been **fed a
lie**, which is worse, because its own counters stay at zero and every alarm keyed to
`risk_reject_cnt` stays silent.

**Caught by.** A **saturation flag per accumulator** wired into `risk_stat` and the health
register, plus the assertion that no fast-path accumulator ever wraps — as a *synthesizable*
checker driving a sticky counter, not a simulation-only `$error` (§3). `risk_reject_total`
reconciling against `Σ risk_reject_cnt[*]` catches the adjacent bug in the counters themselves.

**Prevented by.** Saturating arithmetic on **everything feeding a limit comparison** —
`sat_add`/`sat_sub` from `trading_pkg`, including intermediate products — and width proofs
against a worst-case day plus a bit of margin
([04-fixed-point-arithmetic-in-fabric.md](04-fixed-point-arithmetic-in-fabric.md)).

> **RULE: saturation is an alarm, not a clamp.** An accumulator pinning at max means the
> design left the range it reasoned about. Every saturation sets a sticky bit, increments a
> counter, and is a kill trigger. A clamp you cannot hear is indistinguishable from the wrap
> it replaced.

### F5 — A book that silently diverges

**Outside.** Nothing errors. `book_updates` climbs normally, latency is nominal, the venue
accepts everything. The quotes are simply **wrong** — priced off a market that does not
exist — and you are adversely selected on every one, at line rate. ⚠️ **The archetypal
silent failure of this domain**: no symptom except the P&L, and the P&L is the slowest
instrument in the building.

**Mechanism.** Any of: an order-map eviction (a tracked `order_ref` displaced by a collision,
so its later Delete finds nothing and the level never decrements); a `U` Replace treated as a
resize instead of delete-plus-tail-insert; an unhandled message type skipped by length,
losing its book effect; a level underflow clamped to zero, permanently losing true depth; or
an off-by-one in a fixed-field offset that reads the right *shape* of data from the wrong
place — a plausible price at the wrong scale, a quantity that is really half a timestamp.

**Caught by.** In fabric: `book_underflow`, `book_level_overflow`, `book_crossed_events` (all
sticky + count), `msg_unknown_type` (non-zero ⇒ the venue changed something or we misparsed a
length), and the `book_top.crossed` flag already asserted on in `fpga_top.sv`
(`book_top_valid && book_top.crossed |=> !order_req_valid`). On the host: periodic comparison
of published top-of-book against an **independently reconstructed software book**, plus
cross-checks against the feed's own aggregate messages. An "impossible book" assertion set:
crossed, negative size, best price outside the LULD band the risk gate already holds in
`sym_luld_lo`/`sym_luld_hi`.

**Prevented by.** The **never-evict-a-tracked-record** rule in the order map — an insert that
would displace a live entry fails into the overflow region and counts, never silently
overwrites
([05-hash-tables-and-lookup-structures.md](05-hash-tables-and-lookup-structures.md)). The
**golden-model differential replay**: the same pcap through fabric and software book, compared
event-by-event, as a gating regression
([06.04](../06-operations/04-testing-strategy.md) §4). And the disposition rule — any anomaly
sets `book_stale` and demands a resync. The design never continues and hopes: a book that has
been wrong once has no known state.

⚠️ Clamping a level underflow to zero *and not counting it* is the easiest way to build this
bug. The clamp is correct; the silence is the defect.

### F6 — A feed gap traded through

**Outside.** Briefly indistinguishable from normal operation, then a burst of fills at prices
that were correct a few hundred microseconds ago. The venue sees ordinary orders.
`seq_gap_events` incremented and nobody noticed, because the strategy kept firing.

**Mechanism.** `feed_gap` from `u_net_rx` is consumed as telemetry rather than as a gate; or
it gates the strategy but not the risk gate, and a strategy bug fires anyway; or it clears on
a **timeout** ("no gap for N ms, assume recovered") instead of a positive resync, so the book
resumes missing whatever happened during the gap; or A/B arbitration masks a gap on one side
while the other is also degrading.

**Caught by.** `feed_gap` and `feed_seq`, surfaced as `seq_gap_events[feed]`,
`seq_msgs_missed[feed]`, `seq_gap_recovered[feed]`, and — the one that matters —
`seq_gap_unrecovered` (sticky + count, health bit 2, Tier 1). A per-symbol time-in-stale-state
counter, because "how long did we hold a stale book" is the detection-latency number the
postmortem will demand. `arb_wins[A]/arb_wins[B]` drifting off ~50/50 is the leading indicator
that one path is degrading before either gaps.

**Prevented by.** `book_stale` propagating to **three** independent consumers — the published
`book_top.stale` bit, the strategy's own gating, and an independent `u_risk_gate` T0 gate — so
a strategy bug does not reach the wire
([04.03](../04-system-architecture/03-order-book-in-hardware.md) §10). Both gates are
single-cycle ANDs against precomputed bits: **the duplication costs zero latency.** The
top-level assertion `book_top_valid && book_top.stale |=> !order_req_valid` proves it in
simulation.

> **RULE: `book_stale` is sticky and fail-closed.** Set by hardware, cleared only by an
> explicit per-symbol host register write after a **positive resync** — never by a timeout,
> never by hardware deciding things look fine again.

### F7 — A risk check that passes on reset

**Outside.** A window, usually seconds, between configuration and arming in which the fabric
accepts anything. Nobody is watching, because the system is not "live" yet. A stale trigger or
a leftover test injection in that window emits orders against effectively infinite limits.

**Mechanism.** An uninitialised limit register reads as all-ones (or as whatever survived the
previous bitstream), so `qty <= max_qty` is trivially true. Or a check whose `enable` defaults
to *disabled* — present in the RTL, present in the review, not evaluated. Or `cfg_trading_en`
surviving a soft reset that cleared the limits.

**Caught by.** The reset-state assertion already in `fpga_top.sv`
(`core_rst |-> !cfg_trading_en`), extended to the limit bank: no `order_out_valid` while
`limits_loaded == 0`. A **mandatory post-reset readback** of the whole limit bank, compared
field-by-field against intent. `uptime_cycles` resetting unexpectedly — the cheapest possible
detector of an unnoticed reconfiguration.

**Prevented by.** Fail-closed reset semantics on **every** limit: limits reset to zero (a zero
limit rejects everything, correct for an unconfigured system), `kill_active` resets asserted,
`cfg_trading_en` resets low, credits reset to zero. A per-symbol `limits_loaded` bit set only
by the host write that loads the record — no bit, no trading. And an arm *sequence*: build ID
match → limits loaded and read back → parameter generation match → position loaded → kill
latch cleared → `cfg_trading_en`, with the ordering enforced in hardware rather than by the
operator's memory.

### F8 — A partially-applied parameter update

**Outside.** One or a handful of orders priced or sized off a record that never existed in any
configuration file — the new `max_order_qty` with the old `tick_class`. Usually a single
anomalous order nobody can reproduce, which is why it gets closed as "transient".

**Mechanism.** A multi-register logical parameter written while the fast path reads it.
**A half-written record is not a smaller limit — it is an undefined limit**
([08.09](../08-nasdaq/09-risk-controls-and-limits.md) §6).

**Caught by.** A **parameter generation counter carried alongside the values and checked on
read** — the fast path reads `{gen, values}` in one access, and a generation that does not
match the bank's committed generation is a fault, not a value. The commit protocol's own
check: `cfg_risk_commit`/`cfg_strat_commit` verify the shadow bank's CRC and **refuse to
flip** on mismatch, setting a sticky error. `param_crc` readback (health bit 12) closes the
loop from the host side.

**Prevented by.** The double-buffered commit already wired in `fpga_top.sv`: the host writes
only `~active_bank`, the gate reads only `active_bank`, and the switch is one flip-flop
toggling on one edge. There is no intermediate state to observe.

⚠️ **The subtle version defeats all of that.** Each register write is atomic and the bank flip
is atomic — but if the **host** writes a logical parameter spanning several registers as
several independent commits, it has re-created the hazard one level up: two commits are two
atomic transitions through a state the operator never intended. **RULE: one logical parameter
change = one shadow write set = one commit.** A write set that never reaches `COMMIT` must be
detectable and discardable.

⚠️ A commit that fails CRC must never quietly fall back to "keep the old parameters and log a
warning". Old parameters are usually safe, but the operator's *intent* was not achieved and
they must know now.

### F9 — Clock / sequence desync

**Outside.** (a) Latency measurements subtly wrong, an audit trail whose timestamps cannot be
defended, and an optimisation programme chasing a phantom because the reference drifted.
(b) The order session stops working — or worse, keeps working while the venue and the fabric
disagree about what was sent.

**Mechanism.** (a) The disciplining source (PTP/GPS) loses lock or chases a degraded
grandmaster, so the host's wall-clock mapping of `cycle_cnt` drifts. `cycle_cnt` itself is
free-running and perfectly monotonic; the drift is entirely in the *mapping* to real time —
which is exactly the mapping the audit trail uses. Clock synchronisation for order-event
reporting is a regulatory obligation, not a nicety
([03.06](../03-algotrading/06-risk-and-compliance.md) §7). (b) SoupBinTCP/OUCH sequence
numbers held by `order_gateway` and by the venue diverge — a retransmission handled as new
data, a login resumed from the wrong point, or the fabric emitting a message the host's
session bookkeeping never recorded. The session becomes unrecoverable: you cannot resume, and
you cannot know what is resting.

**Caught by.** A **PTP offset and lock-state health register** scraped on the telemetry loop,
with offset magnitude *and* time-since-lock alarmed — a drifting clock is Tier 1 even though
nothing is trading wrong yet. `soup_seq_tx`/`soup_seq_rx` compared against host session state
with a sequence-mismatch counter. `heartbeat_missed`, `session_drops`, `uptime_cycles`.

**Prevented by.** **Host-owned session sequencing with fabric fast-send**: the host owns the
SoupBinTCP session, the sequence space, and the TCP state; the fabric splices pre-approved
templates into a stream whose sequencing the host can always reconstruct
([04.05](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) §8).

> **RULE: the fabric never invents a sequence number it cannot reconcile.** Every emitted
> message's sequence position is derivable by the host from the DMA audit ring alone. If the
> fabric would have to guess, it does not send.

### F10 — An unnoticed link flap

**Outside.** Absolutely nothing. The dashboard shows every link **up**, because by the time
anyone looks, it is. Meanwhile a few hundred microseconds of market data went missing, the
book is subtly wrong for the affected symbols, and if the flap was on the order-entry link,
resting orders may have been cancelled by cancel-on-disconnect while the fabric still believes
they are live.

**Mechanism.** A degrading optic, a marginal cross-connect, a switch port renegotiating, or
PCS block lock lost and regained. `md_link_up[f]` deasserts and reasserts inside one telemetry
scrape interval. ⚠️ **The classic mistake is monitoring `link_up` as a *level*.** A level-only
monitor samples "up", reports healthy, and the thousand messages you missed are completely
invisible — including to the postmortem, which will conclude "no infrastructure events".

**Caught by.** Link **edge** counters: `link_flap_count[port]` and `pcs_block_lock_lost[port]`,
free-running and latching regardless of scrape phase. `seq_gap_events`/`seq_gap_unrecovered`
for the data actually lost. `session_drops`, `session_logins`/`logouts` on the order path.
`fec_corrected` trending up catches the optic before it flaps at all.

**Prevented by.** A latching flap counter in the MAC wrapper, so a transition is *evidence*
rather than a coincidence of sampling. `link_down` already wired as a kill trigger in
`fpga_top.sv` — `u_risk_gate` takes `.link_down(~oe_link_up)` directly, so an order-entry link
loss stops new orders in hardware within `KILL_RESP_CYCLES`, with `kill_src` recording why.
And the venue's **cancel-on-disconnect** as the backstop for resting interest — a facility to
configure deliberately and reconcile against on reconnect, never to assume.

⚠️ On reconnect, resting order state is **re-verified, never assumed**
([06.04](../06-operations/04-testing-strategy.md) §11).

---

## 3. Cross-cutting: the anti-patterns that generate all of the above

Each feels like good engineering. Each generates a class of failure above.

| Anti-pattern | Why it feels reasonable | What it costs |
| --- | --- | --- |
| **Monitoring a level, not an edge** | The level *is* the state; it is what the operator cares about | F10 entirely. Anything shorter than the scrape interval is invisible — and short events are the diagnostic ones |
| **Clamping instead of alarming** | The clamp is correct: it prevents the wrap, prevents the underflow, keeps the pipeline running | F4, F5. The design keeps running while reasoning about a value that left its valid range. Correct behaviour, zero information |
| **Treating "unknown" as "benign"** | Skipping an unknown message type by its length field is exactly what the spec says to do | F5. The venue added a message with book impact and you now apply a subset of the market. `msg_unknown_type` is a **page**, not a statistic |
| **A counter that saturates silently** | Saturation is safer than wrapping — that is why we chose it | F4. A pinned counter and a quiet one look identical. Saturation needs its own sticky flag |
| **A test environment differing from production, undocumented** | The difference is "obviously" irrelevant — a smaller symbol set, a shorter session, a relaxed limit | F7 and the whole class where the tested path is not the shipped path. Write the delta down or it does not exist |
| **A manual step in the arming sequence** | An operator in the loop is a safety feature | F2, F7. The step that gets skipped is the one done every day. Order the sequence in hardware; make a register write fail when its prerequisite is unset |
| **An assertion compiled out of the production build** | `` `ifndef SYNTHESIS `` around SVA is standard; assertions are a simulation construct | The safety property is proven where it cannot fail and absent where it can. **The correct answer: synthesizable checkers driving counters and sticky bits**, not `$error` — keep the SVA for regression, add a twin for the device |

> **RULE: every top-level assertion in `fpga_top.sv` has a synthesizable twin** driving
> `risk_stat` or a health bit. An invariant worth asserting is worth observing on hardware.

---

## 4. Reference: the shapes of real industry incidents

⚠️ **Described as shapes, deliberately.** No firm, figure, date, or cause is asserted here as
fact. Learn the mechanism; verify specifics from primary sources before repeating them
anywhere, especially to a risk committee.

**Shape 1 — the partial rollout.** A US broker-dealer's runaway deployment in the early 2010s
is the canonical example of a partial rollout leaving old code active on a subset of servers,
where a repurposed configuration flag meant something different to the old code than to the
new — producing automated order flow that nothing in the firm's stack stopped, reportedly
costing a sum large enough to end the firm's independence.
> **Verify:** the SEC administrative proceeding and contemporaneous press coverage of this
> incident; do not cite figures from memory.

*Lesson:* the deployed artifact must be **identifiable at runtime on every unit**, and the
host must refuse to arm on a mismatch — hence `BUILD_ID`/`GIT_SHA` as elaboration parameters
burned into the fabric and checked by `u_host_ctrl`, and "Build ID ≠ expected" as a Tier 1
page. And: never repurpose a field, flag, or register bit. Deprecate, then allocate a new one.

**Shape 2 — the erroneous order.** An order entered with a size or price off by orders of
magnitude — a quantity typed into a price field, a notional entered as a share count —
reaching a market and executing against everything available before anyone can react. Trade
breaks are slow, partial, and discretionary.
> **Verify:** exchange clearly-erroneous-execution rules and published reviews of specific
> incidents; confirm current thresholds and filing deadlines against rule text.

*Lesson:* per-order quantity, notional, and price-collar checks are not about *our* strategy
being wrong — they are about any input path being wrong. They belong in `u_risk_gate` where
nothing routes around them, and the collar reference price needs a component independent of
the book the strategy used.

**Shape 3 — the runaway algorithm that disrupted a venue.** One participant's automated system
generating order or quote traffic at a rate that degraded a venue's own systems, so the
failure escaped the firm and became everyone's.
> **Verify:** regulatory findings and exchange notices covering algorithmic-trading
> disruptions and message-rate obligations; do not attribute a specific event from memory.

*Lesson:* the message-rate limiter is a *risk check*, not a courtesy. Your throughput ceiling
is one you enforce before the venue enforces it on you; blowing a venue throttle is a
compliance event as well as an outage.

**Shape 4 — the market-data-driven cascade.** A market-wide dislocation amplified by automated
systems reacting to degraded, delayed, or anomalous market data — participants withdrawing or
trading through stale prices near-simultaneously, each rationally, with a collective result
nobody chose.
> **Verify:** the joint regulatory staff reports on major market-disruption events, and the
> LULD Plan and market-wide circuit-breaker rules adopted in response.

*Lesson:* the correct response to any data-integrity doubt is to **stop**, not to degrade
gracefully. `book_stale` fails closed. A system that keeps quoting on a book it distrusts is
contributing to the cascade, not surviving it.

---

## 5. The postmortem template for this project

Copy verbatim into `docs/postmortems/YYYY-MM-DD-<slug>.md`. Timestamps come from `cycle_cnt`
(free-running, never reset after release) mapped to wall clock via the PTP offset record —
**quote both**, because the mapping is itself a suspect in F9.

```
# Postmortem: <one-line description>
Date: <YYYY-MM-DD>   Author: <name>   Status: draft | reviewed | CLOSED
Build: BUILD_ID=<hex>  GIT_SHA=<hex>  bitstream=<artifact id>

## 1. Timeline  (fabric cycle -> wall clock; PTP offset quoted at each point)
  cycle 0x......  T+0       first bad event (define it precisely)
  cycle 0x......  T+ ..ms   first counter movement:  <counter> <delta>
  cycle 0x......  T+ ..ms   first ALARM raised:      <health bit / alert name>
  cycle 0x......  T+ ..s    first HUMAN action:      <what>
  cycle 0x......  T+ ..s    kill asserted (kill_src=<src>); last order at +N cycles
  cycle 0x......  T+ ..s    trading stopped confirmed (orders_emitted flat)

## 2. Blast radius
  Orders emitted after first bad event : <n>   (orders_emitted delta)
  Notional                             : <$>   (host, from drop copy)
  Symbols affected                     : <list / count>
  Peak position per symbol             : <table>
  Realised P&L impact                  : <$, host-computed, net of fees>
  External impact                      : venue rejects <n>, throttles, notices

## 3. DETECTION LATENCY   <-- the single most important number in this document
  first bad event -> first counter movement : ..... ms
  first bad event -> first alarm            : ..... ms
  first alarm     -> kill asserted          : ..... s
  Detected by a counter that already existed?   YES / NO
  If NO: which counter should have existed?  -> action item + a row in 09.09 §6

## 4. Counter evidence (snapshot bank, pre- and post-, atomically latched)
  | counter / health bit | before | after | expected | notes |
  Include every counter that moved AND every counter that should have and did not.

## 5. Root cause (mechanism, not blame; ask "why" until it lands on a design property)

## 6. Structural fix
  What makes this failure INEXPRESSIBLE?  (not "we will be careful")
  If the fix is procedural, say so explicitly and justify why no structural fix exists.

## 7. Regression test
  Test id:      tb/regress/<name>
  Reproduces:   the exact mechanism in §5, and FAILS on the pre-fix RTL
  Runs in:      the gating regression suite (not a manual script)
  Coverage:     09.09 §6 row <n> added / updated
```

> **RULE: no postmortem closes without a test in the gating regression suite that fails on the
> pre-fix RTL.** Action items of "be careful" and "add a dashboard" document an incident
> without removing it. If the mechanism cannot be reproduced in the testbench, *that* is the
> finding — the observability gap is the root cause.

> **RULE: detection latency is reported for every incident, always, even when it was
> excellent.** It is the only number that improves systematically, and the only one that
> predicts the cost of the next incident.

---

## 6. The detection-coverage matrix

The reference artifact of this file. Every scenario in §2 has a row; a failure mode with no
row is unmonitored. Detection latency is by mechanism: *fabric* = the cycle it happens,
*scrape* = the telemetry poll interval, *recon* = the reconciliation cadence.

| # | Failure mode | Detecting counter / register | Latency | Alerting action | Preventing design feature | Regression test |
| --- | --- | --- | --- | --- | --- | --- |
| F1 | Runaway order loop | `risk_reject_cnt[RATE]`, `[DUP]`, `credit_starved`, health bit 15 | fabric | **Tier 1 page**; limiter trip auto-kills | `pending` bit per symbol; `credit_avail`; rate limiter *as a risk check*; own-order ID | Reject-storm + self-observation loop injection; assert order count bounded |
| F2 | Stale parameters | `param_crc` + health bit 12; `param_reload_count`; `host_heartbeat_age_ms` + bit 9 | scrape | Tier 1 page; watchdog blocks new orders | Reset = limits zero + `!cfg_trading_en`; arm requires generation + CRC match; daily readback | Arm-without-load must be refused; CRC-mismatch commit must not flip the bank |
| F3 | Position drift | Fabric↔host↔drop-copy divergence counter; `credit_starved` | recon | **Tier 1 — the most dangerous alert**; auto-kill on divergence | Bounded in-flight credit; conservative-estimate rule; overwrite-not-adjust reconciliation | Missed / duplicated / misrouted fill injection; assert drift ≤ `K` orders |
| F4 | Wrapped accumulator | Per-accumulator saturation sticky in `risk_stat`; `risk_reject_total` vs `Σ risk_reject_cnt[*]` | fabric | Tier 1 page; saturation is a kill trigger | `sat_add`/`sat_sub` on everything feeding a comparison; width proofs | Directed overflow of every accumulator; assert no wrap and sticky sets |
| F5 | Silently divergent book | `book_underflow`, `book_level_overflow`, `book_crossed_events`, `msg_unknown_type`, `book_top.crossed` | fabric (integrity) / scrape (host diff) | Tier 1 page; `book_stale` + resync | Never-evict order map; golden-model differential replay; anomaly ⇒ `book_stale` | pcap replay vs software book, event-by-event; replace / eviction / underflow cases |
| F6 | Feed gap traded through | `feed_gap`, `seq_gap_events`, `seq_gap_unrecovered` + health bit 2, time-in-stale counter | fabric | Tier 1 page | `book_stale` → three consumers incl. `u_risk_gate`; clears only on positive resync | Gap on A only; gap on both; assert `!order_req_valid` while stale |
| F7 | Risk check passes on reset | `core_rst \|-> !cfg_trading_en` + synthesizable twin; `limits_loaded`; `uptime_cycles` | fabric | Tier 1 page on unexpected uptime reset | Limits reset zero; `kill_active` set at reset; hardware-ordered arm sequence | Post-reset order injection rejects on every check; full-bank readback compare |
| F8 | Partial parameter update | Generation counter checked on read; commit CRC reject; `param_crc` / health bit 12 | fabric | Tier 1 page — commit failures never silent | Double-buffered bank, single-edge commit; one logical change = one commit | Write-during-read torture; assert the gate never observes a mixed record |
| F9 | Clock / sequence desync | PTP offset + lock-state health register; `soup_seq_tx`/`soup_seq_rx` mismatch counter; `heartbeat_missed` | scrape | Tier 1 page (clock **and** sequence) | Host-owned session sequencing; fabric never invents an unreconcilable sequence | Session drop-and-resume; forced clock step; assert audit trail reconstructable |
| F10 | Unnoticed link flap | `link_flap_count[port]` (**edge**), `pcs_block_lock_lost`, `session_drops`, `fec_corrected` trend | fabric (latched) | Tier 2 for a feed flap; **Tier 1** for order entry while armed | Latching flap counters; `link_down` → kill within `KILL_RESP_CYCLES`; cancel-on-disconnect | Flap shorter than the scrape interval must still be counted and visible |

⚠️ Read the latency column as the honest scope of each defence. Anything at *recon* cadence
bounds damage rather than preventing it — F3 is caught after the drift happened, which is
exactly why F3's prevention is `credit_avail` and not the reconciliation.

---

## 7. Rules for this project

1. **Every failure mode has a row in §6, or it is unmonitored.** A newly discovered mode gets
   a row, a counter, and a regression test in the same commit.
2. **Detection latency is the headline metric of every incident** — first bad event to first
   alarm, reported always.
3. **No postmortem closes without a gating regression test that fails on the pre-fix RTL.**
4. **Monitor edges, not levels**, for anything whose duration can be shorter than a scrape.
5. **Every clamp and every saturation raises a sticky bit.** A silent clamp is a wrap with
   better manners.
6. **Unknown is never benign** — unknown message type, unknown reject reason, unknown token:
   counted, sticky, alarmed, fail-closed.
7. **Every SVA in `fpga_top.sv` has a synthesizable twin** driving a counter or health bit.
8. **The fabric's position is a conservative safety estimate, never an accounting record.**
   Ambiguity always resolves toward more exposure.
9. **`book_stale` and `kill_active` are sticky** and clear only on explicit operator action
   after a positive resync — never on a timeout.
10. **One logical parameter change = one shadow write set = one commit**, host side included.
11. **The arm sequence is ordered in hardware.** A register write whose prerequisite has not
    happened fails; it is not a checklist item.
12. **No incident number, dollar figure, or firm attribution enters this repository without a
    primary source.** §4 gives shapes; specifics are verified or omitted.

---

## Further reading

- [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md) — §10 states these risks; the regulatory basis for every control named here
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — risk gate, credit mechanism, position drift in RTL terms
- [../04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md) — `book_stale`, underflow, resync
- [../04-system-architecture/02-feed-handler-design.md](../04-system-architecture/02-feed-handler-design.md) — gap detection and A/B arbitration
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) — the counter taxonomy, health register, and alert tiers this file indexes into
- [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md) — §11 fault injection: the tests in the §6 matrix
- [../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md) — build identity, the defence against the §4 Shape 1 mechanism
- [../08-nasdaq/09-risk-controls-and-limits.md](../08-nasdaq/09-risk-controls-and-limits.md) — check spec, saturating arithmetic, commit protocol, bounded-lag contract
- [../02-networking/03-multicast-feeds-and-arbitration.md](../02-networking/03-multicast-feeds-and-arbitration.md) — what A/B arbitration does and does not hide
- [04-fixed-point-arithmetic-in-fabric.md](04-fixed-point-arithmetic-in-fabric.md) — width proofs and saturation, the F4 defence
- [05-hash-tables-and-lookup-structures.md](05-hash-tables-and-lookup-structures.md) — the never-evict rule, the F5 defence
- [03-cancel-latency-and-pickoff.md](03-cancel-latency-and-pickoff.md) — the fat tail that makes F5 and F6 expensive
- [07-jitter-sources-and-determinism.md](07-jitter-sources-and-determinism.md) — the timing failures this file does not cover
- [10-partial-reconfiguration-and-field-updates.md](10-partial-reconfiguration-and-field-updates.md) — updating a live system without creating §4 Shape 1
- [../07-reference/04-checklists.md](../07-reference/04-checklists.md) — the pre-open, arm, and incident-response checklists
