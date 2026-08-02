# 12.04 — Resilience and Failure Isolation

> **Why this matters here:** in most systems, resilience means "keep serving
> through the failure". Here it usually means the opposite. A trading system whose
> view of the world is degraded is not a system delivering reduced service — it is
> a system making full-confidence financial commitments on bad information, at
> 8 million potential orders per second, against counterparties who are not
> degraded. The engineering goal is not uptime. It is a **bounded, provable,
> automatic stop** for every failure mode we can name, and a fail-closed default
> for the ones we cannot.

---

## 1. Fail-closed as a system-wide principle

Fail-closed is already scattered through the design as individual decisions. Read
them together and they are a single architectural stance:

| Mechanism | Default / failure state | Where |
| --- | --- | --- |
| Kill switch on reset | `KS_ARMED` — **killed**, not disarmed | `rtl/risk/kill_switch.sv` |
| CSR `CONTROL` on reset | `0x0000_0002` — kill asserted, trading disabled | `rtl/ctrl/csr_regfile.sv` |
| `HEARTBEAT_AGE` on reset | `0xFFFF` — already past the watchdog timeout | `csr_regfile.sv` |
| Risk limits on reset | Zero — every order fails the check | `rtl/risk/risk_params.sv` |
| `params_valid` on reset | 0 — the gate rejects with `RISK_PARAM_INVALID` | `risk_params.sv` |
| Unmapped BAR read | `0xDEAD_C0DE`, never plausible zeros | `csr_regfile.sv` |
| Parameter commit with bad CRC | Refused; sticky error; counter increments | `risk_params.sv` |
| Kill latch | Never self-clears — not on timeout, not on link-up, not when the trigger goes away | `kill_switch.sv` |
| RX overrun | Drop and count; **never** stall the MAC | `CLAUDE.md` §5.4 |

**The single rule they all express:**

> **Permission to trade is a positive, continuously re-established conjunction of
> healthy conditions. It is never the absence of a fault.**

That distinction is the whole thing. "No fault flag is set" is false after a
reset, after a reconfiguration, after a partial initialisation, and after any bug
that prevents a flag from being written. "All of these N conditions are
affirmatively true" is false in exactly the same situations — but it is false in
the *safe* direction.

```systemverilog
// The shape every permission signal in this design should have.
// NOT: assign may_trade = !any_fault;          <-- ⚠️ unsafe default
// BUT: an AND of affirmative, individually-observable health conditions.

logic may_trade_q;

always_ff @(posedge core_clk) begin
    if (core_rst) begin
        may_trade_q <= 1'b0;                 // ⚠️ reset value is NO
    end else begin
        may_trade_q <= trading_en_effective  // host armed + enabled (two-step)
                     & ~kill_active          // kill switch latch clear
                     & params_valid          // risk table committed + CRC ok
                     & position_loaded       // reconciled position was written
                     & session_up            // order-entry session established
                     & md_feed_healthy       // at least one MD feed in sequence
                     & ~watchdog_expired;    // host heartbeat is live
    end
end
```

Four properties this shape buys you, none of which the `!any_fault` form has:

1. A new failure mode is added by **AND-ing in another term**, not by remembering
   to raise a flag somewhere.
2. Reset, partial configuration, and an un-run initialisation all produce `0`.
3. Every term is separately observable in `STATUS`, so "why can't we trade?" is a
   register read, not an investigation.
4. It cannot be defeated by a single stuck-at-zero fault on a fault line.

⚠️ **Do not add an override bit.** Someone will eventually ask for one "for
testing". The test environment gets a different bitstream with different
parameters, not a bypass in the production one. An override bit that exists will
be set at 09:29 one morning by someone who is late.

---

## 2. Blast radius per component

Blast radius = *the worst financial or operational outcome if this component is
wrong, and how long it lasts before something stops it.* Do this analysis per
block; it is what tells you where to spend verification effort.

| Component | If it silently misbehaves | Bounded by | Radius |
| --- | --- | --- | --- |
| `rtl/risk/risk_gate.sv` | Orders leave with no effective limit | Nothing downstream | 🔴 **Unbounded** |
| `rtl/risk/kill_switch.sv` | The stop does not work | Ext. GPIO, session logout, venue desk | 🔴 **Unbounded** |
| `rtl/risk/risk_params.sv` | Wrong limits applied | Aggregate limits, kill triggers | 🔴 Very large |
| `rtl/risk/position_monitor.sv` | Position understated → real limits ineffective | Daily loss limit, drop-copy reconciliation | 🔴 Very large |
| `rtl/order/ouch_encoder.sv` | Well-formed but wrong field: side, size, symbol, price | Risk gate checks the *candidate*, not the encoding ⚠️ | 🔴 Large |
| `rtl/strategy/*` | Bad decisions, at full rate | Risk limits, rate limiter | 🟠 Bounded by limits |
| `rtl/book/*` | Wrong book → wrong decisions | Price collars, golden-model divergence check | 🟠 Bounded by limits |
| `rtl/feed/*`, `rtl/net/*` | Misparsed messages → wrong book | Same as book | 🟠 Bounded |
| `rtl/eth/*` (RX) | Dropped frames | Drop counters, gap detection | 🟡 Missed opportunity |
| `rtl/telemetry/*` | Wrong metrics | Nothing — ⚠️ you are blind, not broken | 🟡 Detection loss |
| `rtl/ctrl/dma_log_ring.sv` | Lost audit records | `LOG_GAP_MARKER`, `LOG_DROP_CNT` | 🟡 Reconstruction loss |
| Host `paramd` | Wrong parameters written | Fabric CRC + readback | 🟠 Bounded |
| Host `heartbeat` | Stops | Watchdog → kill. **Fails safe** | 🟢 Safe |
| Host `reconciler` | Undetected position divergence | Daily loss limit, clearing | 🟠 Large, slow |

⚠️ **The encoder row is the subtle one and it is worth re-reading.** The risk gate
validates the *order candidate* — a struct. What reaches the venue is *bytes*. If
the encoder splices the wrong field into an OUCH template, the risk gate approved
something that is not what was sent, and every counter in the system will
cheerfully report a clean, approved, in-limit order. The defences are byte-exact
golden-vector conformance tests
([../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md) §3)
and post-trade drop-copy reconciliation. There is no runtime fabric check that
closes this gap, and pretending otherwise is how it stays open.

**Design consequence:** the red rows get exhaustive verification, formal property
checks where practical, hardware-in-the-loop proof per release, and the tightest
review requirements. Effort follows radius, not line count.

---

## 3. Failure of each subsystem

For each: how it is detected, how fast, what the safe state is, and how you come
back.

### 3.1 Host dies (process crash, kernel panic, power loss)

| | |
| --- | --- |
| **Detection** | Heartbeat writes to `0x018` stop |
| **Time to detect** | `WATCHDOG_WARN_MS` = 50 ms (alert) → `WATCHDOG_MS` = 100 ms (act) |
| **Automatic action** | `arm_state → DISARMED`, kill asserted (`KILL_WATCHDOG`), `LOG_WATCHDOG` record emitted |
| **Safe state** | No new orders. ⚠️ Resting orders are **still at the venue** |
| **Residual risk** | Whatever is resting. This is why cancel-on-disconnect and a venue mass-cancel facility matter |
| **Recovery** | Restart host → reconcile position from drop copy → reload params → two-step arm → canary |

The watchdog **blocks; it does not merely warn**, and it does so in `risk_gate` in
the core domain, independent of whether `csr_regfile` is healthy — `host_ctrl`
additionally stops forwarding heartbeat pulses, so the core-domain watchdog fires
on its own. Two independent paths to the same safe state.

⚠️ **A dead host is not just "no new decisions".** It is no position accounting,
no reconciliation, no fill processing, and no human able to see anything. Trading
on through it is unthinkable, which is exactly why the fabric refuses to.

### 3.2 FPGA fails (configuration loss, clock loss, thermal, SEU)

| Failure | Detection | Safe state |
| --- | --- | --- |
| Configuration lost / card reset | `STATUS.core_alive` clears; BAR reads return the sentinel; `BUILD_ID` mismatch | Reset state = killed, limits zero |
| `core_clk` stops (MMCM unlock) | `cycle_cnt` frozen; telemetry reads time out (`TELEM_ERR_CNT`) | ⚠️ Nothing in fabric can act — a stopped clock stops the kill logic too |
| Over-temperature | Device monitor; card telemetry | Host-driven kill, then power action |
| Single-event upset in a config bit | Configuration memory scrubbing / ECC where the family supports it | Depends on which bit — see below |

⚠️ **A stopped core clock is the one failure the fabric cannot protect against**,
because every protective mechanism in the design is synchronous to it. The
compensating controls are all external: the host notices `cycle_cnt` is frozen
and pulls the session; cancel-on-disconnect and the venue's facilities handle the
rest. Do not write "the kill switch handles this" anywhere near a clock-failure
scenario.

⚠️ **SEU in a risk limit is a silent limit change.** The realistic mitigations are
configuration scrubbing (family-dependent), storing critical parameters with a
CRC that is periodically re-verified rather than only checked at commit, and
periodic host readback of the active limits compared against what `paramd`
believes it wrote. The last of these costs nothing on the fast path and should be
a standing background task.
> **Verify:** the SEU mitigation and configuration-scrubbing options for your
> device family and their published upset rates — check the vendor's
> soft-error/reliability documentation and the SEM IP guidance for your part.

### 3.3 Market data link fails

| Failure | Detection | Correct response |
| --- | --- | --- |
| One feed (A or B) down | `md_link_up[n]` low; per-feed counters flat | Continue on the survivor, **alert**, and treat the state as degraded |
| Sequence gap on one feed | MoldUDP64 sequence tracking in `rtl/net/moldudp64_deframer.sv` | Fill from the other feed; count |
| Gap on **both** feeds | Both sequence trackers advanced past expected | ⚠️ **The book is now wrong.** Stop trading affected symbols; recover via retransmission/snapshot in the host |
| Both links down | `md_link_up` = 0 | Stop. There is no book |
| Silent staleness (link up, no data) | Time-since-last-message per feed | Stop after a configured threshold — ⚠️ this is not a link-down event and needs its own detector |

⚠️ **Silent staleness is the failure mode that gets missed.** A link that is up
and delivering nothing looks perfectly healthy on every link-level counter. In a
liquid symbol during regular hours, "no messages for N milliseconds" means
something upstream is broken, not that the market went quiet. Every feed needs a
time-since-last-message watchdog with a per-session-phase threshold, and it must
be an *affirmative health term* in §1's conjunction, not an alert someone reads.

### 3.4 Order-entry link or session fails

| Failure | Detection | Automatic response |
| --- | --- | --- |
| Link down | `md/oe link_up` | `KILL_LINK_DOWN` — kill asserted |
| TCP reset | `sessiond` | Session teardown; kill |
| Sequence fault (unrecoverable) | SoupBinTCP sequencing in `sessiond` | `KILL_SEQ_FAULT` |
| Venue rejects rising | Per-reason reject counters | ⚠️ Alert and investigate — a rising reject rate is a symptom of a wrong model, not a nuisance |
| Credit exhausted / in-flight limit | `RISK_NO_CREDIT` rejections | Bounded by design; alert if sustained |

⚠️ **Losing the session does not flatten you.** Cancel-on-disconnect may or may
not be enabled, may or may not cover every order type, and executes on the
venue's schedule rather than yours.
> **Verify:** the exact cancel-on-disconnect semantics, coverage, and timing for
> your Nasdaq port configuration, and the availability and invocation procedure
> for a mass-cancel facility. Confirm with the venue — never assume the default.

### 3.5 Venue misbehaves or halts

| Event | Response |
| --- | --- |
| Symbol halt / LULD pause | Stop quoting that symbol; ⚠️ resting orders' treatment is venue-specific — know it in advance |
| Market-wide circuit breaker | Stop everything; this is a full stop, not a degradation |
| Venue-side outage | Kill, cancel what you can, reconcile against the drop copy before assuming anything |
| Erroneous prints / a broken feed at the venue | Price collars catch most of it; divergence between A/B and the SIP is a signal |

### 3.6 Clock / time discipline fails

| Failure | Consequence | Response |
| --- | --- | --- |
| PTP/GPS grandmaster lost | Timestamps drift out of tolerance | ⚠️ **This is a compliance failure, not just a measurement one** — audit and CAT timestamps become indefensible |
| Holdover | Slow drift | Alert on offset; define a threshold at which you stop |
| Sudden step correction | Latency measurements corrupted; log ordering suspect | Never step during the session; monitor and log every correction |

> **Verify:** applicable clock-synchronisation tolerance and the drift/offset
> monitoring obligations for your systems — CAT and FINRA clock-sync requirements
> differ by system type and timestamp granularity. Confirm with compliance.

⚠️ Note that `cycle_cnt` — the free-running counter used for on-chip latency
measurement — is deliberately *not* the same thing as wall-clock time and is
never reset after initial release. Do not "fix" a clock problem by resetting it;
you destroy the only monotonic reference the fabric has.

---

## 4. Graceful degradation vs hard stop

The decision rule, and it is short:

> **Degrade only when the degraded mode is one you have specified, implemented,
> tested, and can prove is still bounded. Otherwise, stop.**

Almost nothing qualifies. Here is the honest classification for this system:

| Condition | Tempting degradation | Correct answer |
| --- | --- | --- |
| One MD feed down | Run on the survivor | ✔ **Degrade** — this is exactly what A/B is for. Alert, count, and know you have lost gap protection |
| Recovered sequence gap | Continue | ✔ Degrade — after the book is proven re-synchronised for the affected symbols |
| Unrecovered gap | "Trade the symbols we still have" | ⚠️ **Stop the affected symbols.** Only continue with symbols provably unaffected, which requires per-symbol gap attribution you must actually have built |
| Host telemetry drain slow | Keep trading, catch up later | ⚠️ Stop-ish: `LOG_DROP_CNT` rising means you are trading without an audit trail. That is not a degraded mode, it is an unrecordable one |
| Position reconciliation mismatch | "It's small, carry on" | 🔴 **Hard stop.** You do not know your position |
| Latency p99 doubled | Keep trading, investigate later | ⚠️ Stop. Your fills are now adversely selected; the edge assumed the old distribution |
| Risk params CRC failure | Keep the old params | ⚠️ Old params are usually safe, but operator *intent* was not achieved — sticky flag, alarm, and a human decides |
| Any unexplained behaviour | Watch it | 🔴 **Hard stop.** The bar is *unexplained*, not *obviously broken* |

### ⚠️ Why "keep trading through a degraded state" is almost always wrong here

Four reasons, and they compound:

1. **Your edge is conditional on the information being right.** A market-making
   or latency-sensitive strategy is a bet that your view of the book is more
   accurate or more current than the person on the other side. In a degraded
   state that premise is inverted: you are now the slowest, least-informed
   participant quoting a firm price. Every counterparty who *is* healthy will
   preferentially trade against you. **Degradation does not scale your P&L down;
   it flips its sign.**
2. **Losses accrue at machine speed, benefits accrue at human speed.** The upside
   of trading through a 90-second glitch is 90 seconds of ordinary edge. The
   downside is 90 seconds at up to millions of orders per second of systematically
   adverse fills. That is not a symmetric bet, and no reasonable probability
   estimate makes it one.
3. **Degraded modes are unverified modes.** Your regression suite, your pcap
   corpus, and your golden-model comparison all cover the healthy path. The
   moment you are in a state you did not specify, you are running code that has
   never been tested in that state. Every famous algorithmic-trading disaster
   lives in this sentence.
4. **Stopping is nearly free and completely reversible.** The cost of an
   unnecessary stop is opportunity cost, measured in a fraction of a day's edge,
   and you get it back by re-arming. The cost of an unnecessary continue is
   unbounded and permanent. **When the payoff matrix is that asymmetric, the
   optimal policy is not "decide carefully" — it is "always stop".**

The corollary, which people find harder: **build the system so stopping is cheap.**
If a stop costs an hour of manual re-initialisation, operators will hesitate, and
hesitation is the actual failure. Fast, rehearsed, low-friction re-entry is a
safety feature, not a convenience.

### The one degradation that is always permitted

> ```
>    KILLED  ≠  SILENT
>    KILLED  =  no NEW orders, cancels STILL WORK, get flat
> ```

⚠️ If the kill switch blocked *all* outbound messages, hitting it while holding
live quotes would leave unmanaged resting orders in a market you have just
declared unsafe — strictly worse than the state you were escaping. Risk-reducing
traffic — cancels, and fill processing on the way back in — continues.
The risk block must **never reject a cancel**: every check exists to limit risk,
and a cancel reduces it.

---

## 5. Redundancy — and where it backfires

| Redundancy | What it buys | ⚠️ What it costs |
| --- | --- | --- |
| A/B market data feeds | Gap coverage, single-path failure tolerance | Not correctness redundancy — both feeds carry the same (possibly wrong) exchange state |
| Second order-entry session | Session-failure tolerance | Two paths to the venue; the in-flight/credit accounting must span both or it bounds nothing |
| Second FPGA card | Hardware-failure tolerance | 🔴 **Two independent risk states.** Each card enforces *its* position limit; the aggregate is unbounded unless something enforces it |
| Hot-standby host | Faster recovery | Split-brain: two `ctrld` processes, both armed, is a catastrophe. The arm must be mutually exclusive by construction |
| Second site | Site-failure tolerance | Same aggregate-limit problem, plus a reconciliation lag between sites |

⚠️ **Aggregate limits across multiple order-emitting devices cannot be enforced in
fabric.** Each card knows only its own flow. If you run two, the aggregate bound
lives in the host or in a venue-side control, and it is *slower* than the thing it
bounds. State this explicitly in the risk documentation; it is a real gap and
regulators ask about it.
> **Verify:** what aggregate, cross-port pre-trade controls your venue and your
> clearing/sponsoring broker offer (e.g. exchange-side risk management tools and
> port-level limits), and how they interact with SEC Rule 15c3-5 obligations.
> Confirm with the venue and compliance.

**Position for this project:** run one card until there is a measured reason not
to. Redundancy without a shared bound is not redundancy — it is two of the thing
you were trying to limit.

---

## 6. Single points of failure inside the chip

| Shared resource | What depends on it | Mitigation |
| --- | --- | --- |
| `core_clk` / its MMCM | Everything, including the kill switch | External kill path; host-side liveness detection on `cycle_cnt` |
| `core_rst` | Everything | Reset is fail-closed; a spurious reset stops trading, which is safe |
| The risk gate | Every order | ⚠️ A genuine SPOF — and the correct design. It fails closed, so failure = no orders |
| One SLR for the fast path | Latency and timing | Deliberate; a floorplan constraint, not a reliability one |
| PCIe link | Control plane, telemetry, audit ring | Loss → watchdog → kill. Fails safe |
| The audit ring FIFO | Reconstruction after the fact | `LOG_GAP_MARKER` makes loss visible rather than silent |

⚠️ **Do not "improve" the risk gate's availability.** A redundant, voted, or
bypassable risk gate is a worse design: it multiplies the ways an order can reach
the wire and destroys the structural argument that *every* order passes through
*the* check. A single mandatory chokepoint that fails closed is the correct
architecture for a control whose failure mode must be "nothing happens". See
[../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) §1.

---

## 7. Bounded response times — the numbers this design commits to

Every automatic protective action has a number. An unbounded protective action is
not a protection.

| Trigger | Bound | Source |
| --- | --- | --- |
| Trigger present at `kill_switch` boundary → `kill_active` | **1 cycle = 6.4 ns** | `kill_switch.sv` (asserted) |
| `kill_active` → no order emitted | **2 cycles = 12.8 ns** total ≤ `KILL_RESP_CYCLES` (4) | `fpga_top.sv` / `risk_gate.sv` |
| External GPIO → `kill_active` | + 3-FF CDC + `EXT_DEBOUNCE_CYC` (16 = 102.4 ns) | `fpga_top.sv`, `kill_switch.sv` |
| Host register write → `kill_active` | + PCIe posted-write + CDC (~2–3 cycles) | `host_ctrl` |
| Heartbeat stale → warn | 50 ms | `WATCHDOG_WARN_MS` |
| Heartbeat stale → forced disarm | 100 ms | `WATCHDOG_MS` |
| Tick-to-trade fast path (context) | 20 cycles = 128.0 ns fabric | `fpga_top.sv` master budget |

⚠️ **At most one order frame may still reach the venue after a kill.** If the
first beat of a frame has already been accepted by the MAC it will be
transmitted; there is no recall. The guarantee is *at most one*, and it holds only
because the fast path is single-issue with no queue between the encoder and the
MAC. Anything already resting at the venue is retracted by a host mass-cancel,
not by the kill switch.

---

## 8. Proving it: fault injection

A resilience claim that has not been tested is a hypothesis. Every row of §3 gets
a test, and the test lives in the regression suite permanently.

| Injected fault | Where | Expected, asserted outcome |
| --- | --- | --- |
| Stop the heartbeat | HIL / sim | Warn at 50 ms, disarm at 100 ms, `KILL_WATCHDOG`, `LOG_WATCHDOG` record |
| Drop MD link A mid-session | HIL | Continue on B, `md_link_up[0]` low, alert raised, counters attribute it |
| Inject a sequence gap on both feeds | pcap replay | Affected symbols stop; gap counted; recovery path exercised |
| Feed goes silent, link stays up | pcap replay | Staleness detector fires within threshold |
| Assert `ext_kill_n` | HIL | `kill_active` within CDC + debounce; `KILL_SRC.ever_mask` bit set |
| Commit a risk record with a bad CRC | sim + HIL | Commit refused, `crc_err` sticky, `crc_fail_cnt`++, old params retained |
| Attempt a risk-window write while enabled | HIL | Rejected, `CFG_ERR` set, nothing changed |
| Attempt `arm_step1|arm_step2` in one write | HIL | Rejected as operator error |
| Over-limit order (each of 24 `risk_reason_e`) | sim | Rejected with the *correct* reason code, counter increments |
| Order-entry TCP reset | HIL | `KILL_SEQ_FAULT` / link-down kill, session teardown, no orphaned state |
| Fill the audit ring | HIL | `LOG_DROP_CNT` rises, `LOG_GAP_MARKER` emitted, alert fires |
| Program a mismatched `BUILD_ID` | HIL | Host refuses to arm |

⚠️ **A `kill_src_e` value that has never fired in a test is a control you have
never actually exercised.** That is precisely what `KILL_SRC.ever_mask` is for:
after a release's HIL run, every bit should be set. An empty bit is a gap in your
evidence, not a quiet source.

---

## 9. RULES FOR THIS PROJECT

1. **Permission to trade is an AND of affirmative health conditions**, reset to 0,
   with every term separately visible in `STATUS`.
2. **No override, force, or bypass bit exists in a production bitstream.** Test
   configurations get a different bitstream, not a back door.
3. **Every automatic protective action has a documented cycle or millisecond
   bound**, asserted in simulation and verified on hardware.
4. **Every failure mode in §3 has a detector, and the detector is an affirmative
   health term** — not merely an alert a human is expected to notice.
5. **Silence is a failure.** Time-since-last-message watchdogs on every input,
   including ones whose link is up.
6. **Degrade only into a specified, implemented, tested mode.** Everything else is
   a stop.
7. **Cancels always work, including while killed.** The risk block never rejects a
   cancel.
8. **Stopping must be cheap and rehearsed**, because an expensive stop is a stop
   that gets delayed.
9. **Do not add redundancy without a shared bound.** Two order-emitting devices
   without an enforced aggregate limit are worse than one.
10. **Every resilience claim in this document is a test in the regression suite**,
    added the day the claim is made — not the day it is disproved.

---

## Further reading

- [01-threat-model.md](01-threat-model.md) — the failure modes that have an adversary behind them
- [05-incident-preparedness.md](05-incident-preparedness.md) — what humans do when §3 fires
- [../08-nasdaq/09-risk-controls-and-limits.md](../08-nasdaq/09-risk-controls-and-limits.md) §2, §5 — fail-closed and the kill-switch specification
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) §1, §3 — structural non-bypassability and fail-closed in the gateway
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) §4, §7 — the watchdog and what pages a human
- [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md) §11 — fault injection method
- [../06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md) §10 — disaster recovery and failover
- [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md) §8, §10 — cancels while killed, and what goes catastrophically wrong
