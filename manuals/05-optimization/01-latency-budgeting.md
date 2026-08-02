# 05.01 — Latency Budgeting

> **Why this matters here:** every other document in this tier is an *answer*. This
> one is the *question*. A latency budget is the single artifact that turns "make it
> faster" into a list of named, owned, measurable line items. Without it you will
> spend three weeks removing a 6.4 ns pipeline stage while a 30 m cross-connect
> quietly costs you 147 ns in each direction. The budget is how you find out which
> nanoseconds are worth having.

---

## 1. What a latency budget is

A latency budget is a **table with one row per stage of the wire-to-wire path**,
where every row has:

| Field | Why it's mandatory |
| --- | --- |
| **Stage** | A physical or logical block with a defined entry and exit event |
| **Owner** | One named person. Not a team. Not "TBD". |
| **Cycles** | At the stated clock (156.25 MHz → 6.4 ns/cycle) |
| **ns (p50)** | Median contribution |
| **Cumulative ns** | Running total — this is what makes overruns visible |
| **Fixed / Variable** | Does this stage always take the same time? |
| **Control** | Controllable / Physical / Uncontrollable (§4) |

If a row is missing an owner, it is unowned latency and it will grow. If a row is
missing a fixed/variable classification, you have not thought about jitter, and
jitter is what actually loses the trade (§6).

The budget lives in `docs/latency-budget.md` and is **updated in the same PR** as
any change that moves a number. A budget refreshed quarterly is decoration.

---

## 2. Choosing the measurement convention — do this first

Two systems quoting "400 ns tick-to-trade" can differ by 200 ns purely from
convention. Pick one, write it at the top of the budget, and never quote a number
without it.

| Convention | Definition | Comment |
| --- | --- | --- |
| **First-bit-in → first-bit-out** | Start of inbound preamble at our tap → start of outbound preamble at the same tap | **Project default.** Honest, includes serialization, comparable. |
| Last-bit-in → first-bit-out | End of inbound frame → start of outbound frame | Flatters you. Can be *negative* with speculative TX. Vendors love it. |
| Last-bit-in → last-bit-out | | Penalises you for your own frame size. Rare. |
| Fabric-only | MAC RX SOF → MAC TX SOF | Useful internally, **never** quote externally. |

> **Project rule:** all external numbers are **first-bit-in → first-bit-out,
> measured at a single tap point with a single clock**. Fabric-only numbers are
> always labelled "fabric".

Also fix the *reference plane*: are you measuring at your own SFP port, or at the
venue's demarcation point in the meet-me room? The difference is your cross-connect
— and it is usually the largest single line in the budget (§8).

---

## 3. The worked budget for this system

Baseline: 10GbE (0.8 ns/byte at the MAC layer), core clock 156.25 MHz
(6.4 ns/cycle), Nasdaq TotalView-ITCH 5.0 in over MoldUDP64, OUCH 5.0 out,
UltraScale+ with the fast path in one SLR. Trigger message: an ITCH `Add Order`
that improves the inside.

Reference plane: **the venue demarc**, 30 m of single-mode fibre each way.

| # | Stage | Owner | Cyc | ns | Cum ns | Fix/Var | Control |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P1 | Cross-connect fibre, venue → us (30 m @ 4.9 ns/m) | Infra | — | 147.0 | 147.0 | Fixed | **Physical** |
| P2 | SFP+ optical RX (ROSA + limiting amp) | Infra | — | 8.0 | 155.0 | Fixed | Uncontrollable |
| S1 | Serialization: preamble+SFD+Eth+IP+UDP+Mold hdr (70 B) | — | — | 56.0 | 211.0 | Fixed | **Uncontrollable** |
| S2 | Serialization: ITCH body to last needed field (~30 B) | Feed | — | 24.0 | 235.0 | Var (msg type) | Semi |
| R1 | GT RX PMA — CDR, deserialize, RX buffer **bypassed** | IO | — | 35.0 | 270.0 | Fixed | Controllable |
| R2 | PCS RX — block sync, gearbox, descramble, 64b/66b | IO | — | 25.0 | 295.0 | Fixed | Controllable |
| R3 | MAC RX — cut-through, preamble strip, no FCS wait | IO | 2 | 12.8 | 307.8 | Fixed | Controllable |
| R4 | A/B feed arbitration + sequence check | Feed | 2 | 12.8 | 320.6 | **Var** | Controllable |
| R5 | Deframe — MoldUDP64 strip, message split | Feed | 1 | 6.4 | 327.0 | **Var** (msg N in pkt) | Controllable |
| R6 | Decode — type demux, field extract | Feed | 1 | 6.4 | 333.4 | Fixed | Controllable |
| R7 | Symbol lookup — stock locate → book slot (BRAM + outreg) | Book | 2 | 12.8 | 346.2 | Fixed | Controllable |
| R8 | Book update + top-of-book maintain | Book | 2 | 12.8 | 359.0 | **Var** (bank collision) | Controllable |
| R9 | Strategy trigger evaluation | Strat | 1 | 6.4 | 365.4 | Fixed | Controllable |
| R10 | **Pre-trade risk gate** | Risk | 2 | 12.8 | 378.2 | Fixed | **Mandatory — do not remove** |
| R11 | Order encode — template read + field splice | Gwy | 2 | 12.8 | 391.0 | Fixed | Controllable |
| T1 | MAC TX — SOF to first bit at PCS | IO | 2 | 12.8 | 403.8 | **Var** (TX busy) | Controllable |
| T2 | PCS TX — scramble, 64b/66b encode, gearbox | IO | — | 20.0 | 423.8 | Fixed | Controllable |
| T3 | GT TX PMA — serialize, TX buffer bypassed | IO | — | 30.0 | 453.8 | Fixed | Controllable |
| P3 | SFP+ optical TX (driver + TOSA) | Infra | — | 8.0 | 461.8 | Fixed | Uncontrollable |
| P4 | Cross-connect fibre, us → venue (30 m) | Infra | — | 147.0 | **608.8** | Fixed | **Physical** |

**Subtotals — read these, not the total:**

| Group | Rows | ns | % of budget |
| --- | --- | --- | --- |
| Fibre + optics (physical) | P1–P4 | 310.0 | 50.9 % |
| Serialization (uncontrollable) | S1–S2 | 80.0 | 13.1 % |
| SerDes + PCS (IO stack, both ways) | R1, R2, T2, T3 | 110.0 | 18.1 % |
| **Our fabric (MAC RX → MAC TX)** | R3–T1 | **108.8** | **17.9 %** |

> **Verify:** the GT PMA and PCS figures (R1, R2, T2, T3) are **estimates** for
> UltraScale+ GTY in a low-latency 10GBASE-R configuration with TX/RX buffers
> bypassed. Compute the exact latency for your configuration from the latency
> tables in **UG578** (*UltraScale Architecture GTY Transceivers*) / **UG576**
> (GTH), and the PCS/MAC figures from your Ethernet IP product guide (e.g. **PG210**,
> *10G/25G High Speed Ethernet Subsystem*) — then **measure on your hardware**.
> Fibre propagation at 4.9 ns/m assumes a group index of ~1.468; confirm against
> your fibre datasheet.

**The lesson from the subtotal table:** you own 17.9 % of the number. Half the
budget is glass. That does not make the fabric work pointless — 108.8 ns of fabric
versus a competitor's 300 ns is the whole game — but it does mean **the fibre line
must be attacked with the same rigour as the decode pipeline**, by the same team,
in the same table.

---

## 4. Controllable vs uncontrollable lines

The discipline that saves the most engineering time is refusing to attack lines you
cannot move.

| Class | Definition | Examples here | Correct response |
| --- | --- | --- | --- |
| **Uncontrollable** | Physics or protocol. No engineering changes it. | Serialization of the bytes you must receive (S1); speed of light in fibre; optical PMD delay | Record it, subtract it, stop thinking about it |
| **Physical** | Not logic, but a decision someone can make | Cross-connect length, cable type, switch hops, rack position | Escalate to whoever owns procurement/colo. Usually the cheapest ns in the building. |
| **Semi-controllable** | Fixed given a choice you already made | S2 — you must wait for the field you trigger on, but *which* field is a design choice | Re-open the design choice |
| **Controllable** | Your RTL, your IP config, your floorplan | R3–T1, GT config | This is where optimization work goes |
| **Mandatory** | Controllable but off-limits | R10 pre-trade risk, gap detection, drop counters | **Do not touch.** See [05-optimization-playbook.md](05-optimization-playbook.md) §8. |

Three sharp consequences:

1. **You cannot beat serialization.** If your trigger depends on a field 60 bytes
   into the frame, you wait 48 ns for it. The only lever is *depending on an
   earlier field* — which is a strategy decision, not an RTL one.
2. **You cannot beat the speed of light in glass.** 4.9 ns/m is not negotiable.
   The *number of metres* is.
3. **You absolutely can beat your own decode pipeline**, and it is the only part of
   the budget that responds to RTL work. Spend your engineering there and your
   political capital on the physical lines.

> ⚠️ A budget that lists only controllable lines looks great and is useless. It
> hides the fact that your 108 ns of fabric sits inside a 609 ns reality, and it
> lets a physical decision (a 60 m cross-connect) be made by someone who never sees
> the table.

---

## 5. Fixed vs variable, and where the variance comes from

Every `Var` row in §3 is a jitter source with a named cause. Name it or you cannot
bound it.

| Row | Variance source | Typical excursion (estimate) |
| --- | --- | --- |
| S2 | Message type and length differ; trigger field position varies | 0–40 ns |
| R4 | A vs B feed arrival skew; which line wins | 0 to the A/B skew (µs-scale worst case) |
| R5 | **Your message is the Nth in a MoldUDP64 packet** — you decode N−1 first | 0 to (N−1) × decode cost |
| R8 | Book bank collision → 1-cycle stall | 0–6.4 ns |
| T1 | **TX busy with another frame** — you wait for it to finish | 0 to (frame bytes × 0.8 ns) + 16 ns |

The T1 and R5 rows are the two that ruin real systems:

- **R5 (packet packing).** MoldUDP64 packs multiple ITCH messages into one UDP
  datagram. If your `Add Order` is message 7 of 9, a serial decoder pays for six
  irrelevant messages first. Mitigations: decode multiple messages per beat, or
  dispatch by type in parallel across the packet. Budget the *worst realistic* N,
  not N=1.
- **T1 (TX occupancy).** A 1500-byte frame in flight costs 1200 ns. If a heartbeat
  or a slow-path DMA-injected frame is transmitting when you decide to trade, you
  lose more than your entire fabric budget. **Rule: nothing large ever shares the
  order-path MAC**, and low-priority frames are pre-empted or scheduled into known
  quiet windows. Count every deferral.

> ⚠️ **A "fixed-latency design" with an unbounded TX-occupancy line is not
> fixed-latency.** Deterministic fabric plus a shared transmitter equals
> nondeterministic system.

---

## 6. Budget for jitter, not just the mean

The mean is the least useful statistic in this project. **Every budget row carries
four numbers, not one:**

| Stage | p50 | p99 | p99.9 | max | N | Load |
| --- | --- | --- | --- | --- | --- | --- |
| R4 arbitration | 12.8 | 12.8 | 19.2 | 25.6 | 4.1e6 | open replay |
| R5 deframe | 6.4 | 25.6 | 51.2 | 89.6 | 4.1e6 | open replay |
| R8 book | 12.8 | 12.8 | 19.2 | 19.2 | 4.1e6 | open replay |
| T1 MAC TX | 12.8 | 12.8 | 12.8 | 76.8 | 4.1e6 | open replay |
| **Wire-to-wire** | **608.8** | **628.0** | **672.0** | **736.0** | 4.1e6 | open replay |

Rules for this table:

1. **Percentiles do not add.** The p99 of the total is *not* the sum of per-stage
   p99s — that sum is an upper bound, usually a loose one. Measure the total
   end-to-end and use per-stage percentiles only for attribution.
2. **Max is a real number, not an outlier to discard.** In trading, the max is a
   trade you lost or a risk check you delayed. Report it. If you truncate the
   distribution, say exactly what you truncated and why.
3. **Always state N and the load condition.** A p99.9 over N=1000 is noise. See
   [04-measurement-and-profiling.md](04-measurement-and-profiling.md) §9.
4. **A design with lower p50 and worse p99.9 is a regression**, unless someone
   argues otherwise in writing. Project default: determinism ≥ mean speed.

---

## 7. Budget debt

Blocks overrun. The failure mode is not the overrun — it's the silence.

> **Budget debt:** when a stage exceeds its allocation, the excess is a debt. It
> must be **repaid from another stage's slack, or the target moves.** There is no
> third option, and "we'll get it back later" is not a plan, it is the debt.

Keep a ledger next to the budget:

| Date | Stage | Allocated | Actual | Debt (ns) | Repayment plan | Owner | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-06-14 | R8 book update | 1 cyc / 6.4 | 2 cyc / 12.8 | +6.4 | Merge R7 outreg into R8 addressing | Book | Open |
| 2026-06-21 | R11 encode | 3 cyc / 19.2 | 2 cyc / 12.8 | −6.4 | Credit — offsets R8 | Gwy | Closed |
| 2026-07-02 | T1 MAC TX | 1 cyc / 6.4 | 2 cyc / 12.8 | +6.4 | **None. Target moved 600 → 609 ns.** | IO | Accepted |

Practices that make this work:

- **Debt is reviewed weekly, in public.** Unreviewed debt compounds: two teams each
  quietly take one cycle and the target slips 12.8 ns with nobody responsible.
- **Credits are real.** A block that comes in under budget banks slack. This is the
  only incentive that makes people optimize blocks that already "meet" budget.
- **Debt older than one sprint gets converted**: either someone repays it, or the
  published target changes and everyone is told. Never carry silent debt into a
  release.
- **Design new blocks with reserve.** If a block is allocated 12 cycles, build it in
  9. Timing closure will consume the difference (see
  [00-foundations/05-timing-closure.md](../00-foundations/05-timing-closure.md) §7).

---

## 8. Physical lines belong in the same table

The most common structural mistake is keeping a "latency budget" for RTL and a
separate spreadsheet for the data centre. They are one table.

| Physical decision | Latency effect | Estimate | Who decides today? |
| --- | --- | --- | --- |
| Cross-connect length (each way) | 4.9 ns/m fibre; ~4.3 ns/m twinax copper | 30 m → 147 ns | Colo/infra |
| Cage position relative to the meet-me room | Sets the above | 10–100+ m | Contract negotiation |
| One extra store-and-forward switch hop | Frame must be fully received | 64 B frame → ≥ 51 ns + switch | Network |
| One extra **cut-through** switch hop | Fixed per-hop | ~300–500 ns (typical ToR class) | Network |
| One extra **layer-1 / low-latency** hop | Fixed per-hop | ~4–130 ns depending on class | Network |
| Optics vs passive DAC at short reach | Skips the optical PMD | ~5–15 ns/end | Infra |
| Direct venue feed vs consolidated/SIP feed | Feed pipeline delay | 10²–10⁵ µs (dominates everything) | Market data |

> **Verify:** switch and layer-1 device latencies vary by an order of magnitude
> across product classes. Take them from the vendor's published port-to-port
> figures for **your** exact model and frame size, then **measure on your hardware**
> with the tap method in [04-measurement-and-profiling.md](04-measurement-and-profiling.md).

The point of putting these in the same table is that the numbers become comparable.
"Remove a switch hop: −400 ns, cost = one change request" sits directly above
"merge two pipeline stages: −6.4 ns, cost = two weeks and a new class of bug", and
the ordering becomes obvious to everyone, including people who do not write RTL.

---

## 9. Allocating a budget to a block that doesn't exist yet

You must give a number *before* the RTL is written, or the RTL will define the
number. Procedure:

1. **Find the remaining slack.** `target − sum(committed rows)`. If it's negative,
   stop and renegotiate before writing code.
2. **Estimate from the shape of the work, in cycles:**

   | Work shape | Cycles (estimate) |
   | --- | --- |
   | Field extract / mux from a registered beat | 1 |
   | Comparison chain ≤ 8 wide | 1 |
   | BRAM read | 1 + 1 (output register) |
   | URAM read | 1 + 1, **+1 per cascade hop** |
   | Arbitration between N sources | 1, +1 if it needs a skid buffer |
   | Read-modify-write with same-address forwarding | 2 |
   | Wide reduction (max over 32+ entries) | 2–3, or 1 if maintained incrementally |
   | 27×18 DSP multiply, registered | 3–4 |

3. **Add one cycle of closure reserve** per 3–4 cycles of logic. Declare it as
   reserve in the budget, not as work.
4. **Write the allocation into the module header** before the first `always_ff`:

   ```systemverilog
   // ─────────────────────────────────────────────────────────────
   //  Module      : book_update
   //  Owner       : <name>
   //  Latency     : 2 cycles (12.8 ns @ 156.25 MHz), FIXED
   //  Reserve     : 0 cycles  (spent at 2026-06-14, see debt ledger)
   //  Jitter      : +1 cycle on bank collision; counted in stall_cnt_o
   //  Budget row  : R8
   //  II          : 1 (must accept a beat every cycle)
   // ─────────────────────────────────────────────────────────────
   ```

5. **A block without a header budget is not reviewable.** This is a hard rule in
   [CLAUDE.md](../../CLAUDE.md) §4.

---

## 10. Regression gating: defending the budget in CI

A budget that is not enforced by a machine will be eroded by humans who each had a
good reason.

**What to gate on:**

| Gate | Mechanism | Failure action |
| --- | --- | --- |
| Fabric cycle count | cocotb test replays a golden pcap, asserts exact ingress→egress cycle delta per message class | Fail the PR |
| Cycle count **distribution** | Same test, asserts p99.9 and max cycle deltas | Fail the PR |
| Post-route WNS/TNS | Parse `report_timing_summary` | Fail if WNS < 0, warn if WNS drops > 0.1 ns |
| Stage-level counts | Per-stage counters read at end of sim, compared to `latency-budget.json` | Fail on any increase |

**The PR rule:** *a change that adds a cycle to any fast-path stage must state, in
the PR description, (a) which stage, (b) how many ns, (c) which row of the debt
ledger absorbs it, and (d) why the alternative (precompute, widen, restructure) was
rejected.* Reviewers reject on a missing (d) more often than a missing (a).

Emit the machine-readable artifact from the testbench so the gate has something to
diff:

```
{ "clock_mhz": 156.25,
  "stages": { "R3": 2, "R4": 2, "R5": 1, "R6": 1, "R7": 2,
              "R8": 2, "R9": 1, "R10": 2, "R11": 2, "T1": 2 },
  "fabric_cycles_p50": 17, "fabric_cycles_p999": 21, "fabric_cycles_max": 24,
  "n": 4132880, "source": "simulated", "trace": "itch_20260602_open.pcap" }
```

> ⚠️ **Simulated cycle counts are not measured latency.** A CI gate on simulated
> cycles catches *architectural* regressions only. It will not catch a GT
> reconfiguration, a floorplan change that adds route delay, or a MAC IP upgrade.
> Those need the hardware loop in
> [04-measurement-and-profiling.md](04-measurement-and-profiling.md).

---

## 11. Template — copy this for a new block

```markdown
### Budget row: <ID> — <block name>

| Field | Value |
| --- | --- |
| Owner | <one name> |
| Entry event | <signal / condition that starts the clock> |
| Exit event | <signal / condition that stops it> |
| Allocated | <N> cycles / <N × 6.4> ns |
| Reserve included | <N> cycles |
| Fixed or variable | Fixed \| Variable (cause: ______) |
| Control class | Controllable \| Physical \| Uncontrollable \| Mandatory |
| Jitter bound | +<N> cycles worst case, counted in `<counter_name>` |
| II | 1 |
| Measured p50 / p99 / p99.9 / max | — / — / — / — (N=, load=) |
| Source of measurement | simulated \| measured |
| Debt | <ns, or "none"> |
| Repayment plan | <text, or "n/a"> |
```

---

## 12. Rules for this project

1. **One owner per row.** No shared ownership, no "TBD".
2. **First-bit-in → first-bit-out**, at one tap, with one clock, or it isn't a
   quotable number.
3. **Physical lines live in the same table as RTL lines.**
4. **Four numbers per row** (p50/p99/p99.9/max), plus N and load.
5. **Every overrun becomes a ledger entry the same day.**
6. **Every new block gets an allocation before it gets a file.**
7. **Attack controllable lines only** — until the physical lines are demonstrably
   optimal, in which case escalate them, don't ignore them.
8. **The risk gate is a budget row like any other, and it is never the answer to a
   debt.** See [CLAUDE.md](../../CLAUDE.md) §5.

---

## Further reading

- [02-fmax-and-timing-optimization.md](02-fmax-and-timing-optimization.md) — buying back cycles by closing timing harder
- [03-resource-power-optimization.md](03-resource-power-optimization.md) — why congestion shows up as latency
- [04-measurement-and-profiling.md](04-measurement-and-profiling.md) — how to fill in the p50/p99/p99.9/max columns honestly
- [05-optimization-playbook.md](05-optimization-playbook.md) — the ordered list of ways to shrink a row
- [../00-foundations/05-timing-closure.md](../00-foundations/05-timing-closure.md) — why you hold pipeline reserve
- [../01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) — the worked decode budget this table extends
- [../04-system-architecture/01-tick-to-trade-pipeline.md](../04-system-architecture/01-tick-to-trade-pipeline.md) — the block diagram behind the rows
