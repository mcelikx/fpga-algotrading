# 05.03 — Resource and Power Optimization

> **Why this matters here:** you are not optimizing resources to make the design
> *fit*. A VU9P-class part has more LUTs than a trading fast path will ever need.
> You are optimizing resources because **area becomes congestion, congestion becomes
> routing detours, and routing detours become nanoseconds**. Resource discipline is
> latency work wearing a different hat. Thermals are the same story one level down:
> a hot part is a part whose links degrade and whose timing margin you have already
> spent.

---

## 1. The causal chain: area → congestion → latency

```
more logic  →  denser placement  →  routing demand exceeds local capacity
            →  router takes detours around the congested region
            →  net delay rises on paths that did not change
            →  WNS drops  →  you add a pipeline stage  →  +6.4 ns
```

Nothing in that chain mentions "running out of LUTs". The design at 22 % device
utilization that fails timing because 90 % of its logic is crammed into two clock
regions is the normal case, not the exception.

Three consequences that shape everything below:

1. **The denominator is the SLR, not the device.** The fast path is constrained to
   one SLR (see [02-fmax-and-timing-optimization.md](02-fmax-and-timing-optimization.md) §8).
   A VU9P has 3 identical SLRs, so the fast path's real budget is **one third** of
   the datasheet numbers.
2. **Local density beats total utilization** as a predictor of trouble.
3. **The biggest single congestion win is moving the slow path out of the fast
   path's SLR** (§8). Nothing you do in RTL comes close.

> **Verify:** per-device resource counts (VU9P: ~1.18 M LUTs, ~2.36 M FFs, 2,160
> BRAM36, 960 URAM288, 6,840 DSP48E2, 3 SLRs) should be read from the **UltraScale+
> FPGA product tables / device datasheet** for your exact part, not from this
> manual. Per-SLR figures assume identical SLRs — confirm for your device.

---

## 2. Reading a utilization report properly

```tcl
report_utilization -hierarchical -hierarchical_depth 3 -file rpt/util.rpt
report_utilization -slr -file rpt/util_slr.rpt      # per-SLR breakdown

# Utilization of a specific pblock — the number that actually matters
report_utilization -pblocks [get_pblocks pblock_fastpath] -file rpt/util_fp.rpt
```

| Metric | What it tells you | Trap |
| --- | --- | --- |
| **Total device LUT %** | Almost nothing | 22 % device-wide can be 95 % in one clock region |
| **Per-SLR LUT %** | Whether the fast path fits its home SLR | The real budget |
| **Per-pblock LUT %** | The number to hold to a target | **Use this one.** Target ≤ 60 %. |
| **CLB LUTs as logic vs. as memory** | LUTRAM usage — heavy LUTRAM makes SLICEM sites scarce | A LUTRAM-heavy design congests earlier than the LUT % suggests |
| **CLB registers** | FF usage | Rarely a constraint (§7) |
| **CLB (packing) %** | How full the CLBs are | > ~75 % CLB occupancy in a region is a congestion predictor even at moderate LUT % |
| **Block RAM / URAM tiles** | Memory pressure | BRAMs sit in **columns**; heavy use pins your placement |
| **DSPs** | Arithmetic | Also columnar — see §9 |

> **Rule of thumb (estimate):** hold the fast-path pblock to **≤ 60 % CLB LUT
> occupancy**. Above ~75 % the router starts taking detours in UltraScale+ and WNS
> becomes directive-sensitive. Calibrate this threshold against your own builds —
> **UG949** discusses utilization guidelines but the number that matters is the one
> your design shows.

---

## 3. Congestion: the report that predicts your timing

```tcl
# Post-place and post-route
report_design_analysis -congestion -complexity -file rpt/congestion.rpt

# The placer also prints congestion during place_design — read the log,
# don't just grep for errors.
report_design_analysis -congestion -of_timing_paths \
    [get_timing_paths -max_paths 100 -slack_less_than 0.5] -file rpt/cong_paths.rpt

# Routing resource usage after routing
report_route_status -show_all -file rpt/route_status.rpt
```

Vivado reports congestion as a **level 0–8**, where each level is a doubling of the
side of the congested window (level 1 ≈ a 2×2 tile region, level 8 ≈ 256×256), per
direction (North/South/East/West), for short and long routing.

| Level | Interpretation | Action |
| --- | --- | --- |
| 0–2 | Normal | None |
| 3–4 | Localised pressure | Watch; check whether it coincides with failing paths |
| **5** | **Real problem** | Reduce area in that region or spread logic |
| 6–7 | Severe — router is detouring heavily; runtime balloons | Restructure. `Congestion_SpreadLogic_high` is a band-aid. |
| 8 | Likely unroutable or absurd runtime | Architectural change required |

> **Verify:** the congestion-level scale and its interpretation are documented in
> **UG906** (*Design Analysis and Closure Techniques*). Treat the level→action
> mapping above as project heuristics.

**The `-complexity` half of that report** gives a **Rent exponent** per hierarchy.
Rent exponent measures how fast a module's external connection count grows with its
size. A module with Rent > ~0.65 demands interconnect faster than the fabric
provides and will congest wherever you put it. Typical offenders in this design:

| Module | Why it congests | Fix |
| --- | --- | --- |
| Wide crossbar / all-to-all arbiter | Rent ≈ 1.0 by construction | Bank it; use a tree of small arbiters |
| 512-bit barrel shifter (byte aligner) | Every output bit touches every input byte | Use a narrower datapath, or a two-stage coarse+fine shift |
| Statistics/telemetry fan-in from every stage | One collector, hundreds of sources | Pipeline the collection tree; it is off the fast path, so depth is free |
| Debug/ILA nets | Probes reach across the whole design | **Strip from production builds** (§6) |

---

## 4. SLR crossings: budget them, then find the ones you didn't budget

An SLR crossing is a fixed, unrecoverable delay hop (Laguna registers on
UltraScale+). Fast-path budget: **zero**.

Legitimate crossings, all off the fast path:

| Crossing | Direction | Acceptable because |
| --- | --- | --- |
| Fast path → telemetry collector | Out | Latency-insensitive; pipeline it as deep as you like |
| Host control registers → fast path | In | Multicycle-pathed config (see [00-foundations/05-timing-closure.md](../00-foundations/05-timing-closure.md) §6) |
| PCIe DMA ↔ slow path | Both | Entirely in the slow-path SLR |

Finding the ones you didn't intend:

```tcl
# 1. Timing paths that cross SLRs (look at the "SLR Crossings" column)
report_design_analysis -of_timing_paths \
    [get_timing_paths -max_paths 1000 -slack_less_than 1.0] -file rpt/slr_paths.rpt

# 2. THE CI GATE: fast-path cells placed outside their SLR. Run post-place.
set escaped 0
foreach c [get_cells -hier -filter {NAME =~ *u_fastpath* && IS_PRIMITIVE}] {
    if {[get_property NAME [get_slrs -of_objects $c]] ne "SLR0"} {
        incr escaped; puts "ESCAPED: $c"
    }
}
if {$escaped > 0} { error "fast path escaped SLR0: $escaped cells" }
```

> ⚠️ **An unbudgeted SLR crossing appears without any RTL change.** Grow the fast
> path past what fits comfortably in its SLR and the placer will spill it across
> the boundary, silently costing you a hop on a path that was fine yesterday. This
> is why the pblock ≤ 60 % rule exists.

---

## 5. LUT reduction that actually helps

Ordered cheapest-first. "Gain" is area in the fast-path pblock, which is a proxy
for congestion relief.

| # | Technique | Typical gain | Cost / risk | Fast path safe? |
| --- | --- | --- | --- | --- |
| 1 | **Delete dead features.** Unused feed types, disabled strategies, unreachable message handlers. | Often 10–30 % | None | Yes |
| 2 | **Strip debug from production builds** (ILA, VIO, debug hub, wide probe nets) | 5–20 % LUT + BRAM, plus large routing relief | Must maintain two build configs | Yes — **and mandatory**, see §6 |
| 3 | **Narrow the datapath where the width isn't real.** ITCH 5.0 prices are 32-bit scaled integers, quantities 32-bit. Carrying them as 64-bit doubles every comparator and register. | 10–40 % on the arithmetic | Needs a documented scale/range analysis | Yes |
| 4 | **Memory instead of logic.** A truth table, a threshold band, a tick-size ladder → LUTRAM/BRAM read. | Replaces N comparators with 1 read | Costs 1–2 cycles if BRAM; 0–1 if LUTRAM | Yes if LUTRAM |
| 5 | **Constant-fold at elaboration.** Tie off parameters for the symbol universe you actually trade; synthesis prunes the rest. | Proportional to what you pruned | Rebuild needed to change the universe (§11) | Yes |
| 6 | **Bank wide structures** instead of building one wide one (arbiters, muxes, memories) | Cuts Rent exponent, big congestion relief | Adds a collision case to handle | Yes, with care |
| 7 | **Share rarely-used logic** (one divider for the whole control plane) | Large, but only for expensive blocks | ⚠️ Sharing serialises → variable latency | **Slow path only** |

> ⚠️ **Resource *sharing* is the one technique on this list that is banned on the
> fast path.** Sharing means arbitration, arbitration means a stall case, a stall
> case means jitter. Determinism outranks area. See [CLAUDE.md](../../CLAUDE.md) §5.

---

## 6. Debug logic is production latency

An ILA with a deep capture buffer consumes BRAM, adds hundreds of probe nets that
route across the design, and inserts its own clocking. It changes placement, which
changes routing, which changes your latency.

Project policy:

| Build | Debug cores | Ships to a venue? |
| --- | --- | --- |
| `debug` | ILA/VIO permitted, probes as needed | **Never** |
| `production` | Zero ILA, zero VIO, zero debug hub. Only the always-on latency histogram and counters (which are part of the design, not debug). | Yes |

```tcl
# Fail the build if any debug core survived into a production bitstream
if {[llength [get_debug_cores]] > 0} {
    error "debug cores present in a production build: [get_debug_cores]"
}
```

> ⚠️ **A latency number measured on a bitstream containing an ILA is not the
> latency of your production bitstream.** Re-measure after stripping debug, every
> time. See [04-measurement-and-profiling.md](04-measurement-and-profiling.md) §7.

---

## 7. Flip-flop reduction: don't bother

UltraScale+ parts carry roughly **two flip-flops per LUT** (VU9P: ~2.36 M FF vs
~1.18 M LUT). A trading fast path will exhaust routing, then LUTs, then BRAM, and
will never come close to exhausting FFs.

**Do not spend engineering time reducing flip-flop count.** Specifically, do *not*:

- remove pipeline registers on the slow path to "save FFs";
- avoid replicating high-fanout registers because "it costs FFs" (§4 of
  [02-fmax-and-timing-optimization.md](02-fmax-and-timing-optimization.md));
- pack state into narrower registers at the cost of decode logic.

The one FF-related thing worth watching is **control-set count**. Too many distinct
{clock, reset, clock-enable} combinations prevents CLB packing and wastes sites:

```tcl
report_control_sets -verbose -file rpt/control_sets.rpt
```

Fix by using fewer distinct clock enables and by **not resetting datapath
registers** — project policy already (see [CLAUDE.md](../../CLAUDE.md) §4).

---

## 8. The single biggest win: evict the slow path

Everything in the fast path's SLR competes for the same routing. The slow path is
large, latency-insensitive, and has no business being there.

| Move out of the fast path's SLR | Why it's there today | Where it belongs |
| --- | --- | --- |
| PCIe/DMA engine + host register file | "It was in the template project" | Slow-path SLR |
| Statistics counters, histograms, telemetry aggregation | Fan-in from everywhere | Collector in the slow-path SLR; only the per-stage counters stay local |
| Logging / capture ring buffers | Needs the data | Deep FIFO out of the fast path, drained in the slow SLR |
| Order state reconciliation, position accounting | "Risk is nearby" | Slow path — the *hardware risk gate* stays; the accounting doesn't |
| TCP/session-layer state machines (OUCH session, heartbeats, retransmit) | Same MAC | Separate module, separate SLR, only the frame emit path is fast |
| Reference data tables not read per tick | Convenience | Slow-path SLR, DMA'd into fast-path tables on change |

```tcl
set_property USER_SLR_ASSIGNMENT SLR0 [get_cells u_top/u_fastpath]
set_property USER_SLR_ASSIGNMENT SLR2 [get_cells u_top/u_slowpath]
set_property USER_SLR_ASSIGNMENT SLR2 [get_cells u_top/u_pcie]
set_property USER_SLR_ASSIGNMENT SLR2 [get_cells u_top/u_telemetry_collect]
```

> ⚠️ The **pre-trade risk gate stays in the fast path.** Evicting the slow path
> does not mean evicting risk. Risk is a fast-path budget row (R10) and a hard rule.
> See [CLAUDE.md](../../CLAUDE.md) §5 and
> [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md).

---

## 9. Memory budgeting: a worked example

The order book and symbol tables are the only genuinely large consumers on the fast
path. Get the arithmetic right *before* writing RTL, because the answer determines
whether you fit in one SLR.

**Per-price-level record (project default):**

| Field | Bits |
| --- | --- |
| Price (ITCH 5.0 scaled integer, 4 implied decimals) | 32 |
| Aggregate quantity | 32 |
| Order count | 16 |
| **Total** | **80** (pad to 96 or 128 for BRAM aspect ratios) |

**Symbol universe:** ITCH 5.0 assigns a 16-bit *stock locate* per session. Nasdaq's
tradeable universe is order-10⁴ symbols; we allocate **8192** (2¹³) with a filter,
and note the fully-general case at 65536.

**Cost per symbol, and total, at 8192 symbols:**

| Structure | Bits/symbol | Total | BRAM36 (36,864 b) | URAM288 (294,912 b) | Read latency |
| --- | --- | --- | --- | --- | --- |
| Top-of-book only (bid px/qty, ask px/qty) | 128 | 1.05 Mb | **29** (4 % of an SLR) | 4 | 2 cyc |
| TOB + second level | 256 | 2.10 Mb | 57 | 8 | 2 cyc |
| 10 levels × 2 sides @ 80 b | 1,600 | 13.1 Mb | **356** (49 % of an SLR) | 45 | 2 cyc + cascade |
| 32 levels × 2 sides @ 80 b | 5,120 | 41.9 Mb | **1,138 — exceeds one SLR (720)** | 143 | 2 cyc + cascade |
| Per-symbol OUCH template (64 B) | 512 | 4.19 Mb | 114 | 15 | 2 cyc |
| Per-symbol risk limits (qty, notional, band, flags) | 128 | 1.05 Mb | 29 | 4 | 2 cyc |

> **Verify:** BRAM36 = 36,864 bits and URAM288 = 294,912 bits per tile, and the
> supported aspect ratios that determine real packing efficiency, are in **UG573**
> (*UltraScale Architecture Memory Resources*). Expect 10–25 % worse than the ideal
> figures above once width padding and port configuration are accounted for.
> Per-SLR tile counts (VU9P: 720 BRAM36, 320 URAM per SLR) — confirm for your part.

**What the table tells you to build:**

```
Tier 0  Hot 256 symbols, top-of-book        LUTRAM   ~0.5–0.7k LUT   1 cycle
Tier 1  All 8192 symbols, top-of-book       BRAM     29 tiles        2 cycles
Tier 2  All 8192 symbols, 10 levels deep    URAM     45 tiles        2 cyc + cascade
        └─ off the trigger path; feeds analytics and the slow path
```

Three decisions fall straight out:

1. **Do not put the deep book on the trigger path.** A 32-level BRAM book does not
   fit in one SLR, and the URAM alternative pays cascade latency. The strategy
   triggers on top-of-book; depth is read at leisure.
2. **A hot-symbol LUTRAM tier is nearly free and saves a cycle** on the names you
   actually trade. 256 × 128 b ≈ 0.5 k LUTs — about 0.15 % of an SLR.
3. **Order templates are worth their BRAM.** 114 tiles (16 % of an SLR) to turn
   "encode an order" into a read plus a splice is the best BRAM you will ever spend
   — see [../01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) §4.

> ⚠️ **URAM cascades are invisible latency.** Building a deep memory by cascading
> URAMs adds a pipeline register per hop. A 45-URAM structure organised as an
> 8-deep cascade costs ~8 extra cycles (51 ns) that appear nowhere in your RTL.
> Organise deep memory as *parallel banks selected by address*, not as a cascade,
> whenever it must be fast.

---

## 10. DSPs: usually the wrong answer on the fast path

| Situation | Use a DSP? | Why |
| --- | --- | --- |
| Variable × variable, wide, off the fast path | **Yes** | That's what they're for |
| Multiply by a compile-time constant | **No** — shift/add in LUTs | `x*100 = (x<<6)+(x<<5)+(x<<2)`: one adder tree, 1 cycle, vs a registered DSP at 3–4 |
| `qty × price > notional_limit` on the fast path | **No** — precompute | Divide once per parameter change in software; compare in fabric |
| Accumulators, counters, statistics | Either | DSP48E2 makes a fine wide accumulator and it's free area |
| Anything on the trigger path needing full pipelining | **No** | A fully-registered DSP48E2 is 3–4 cycles = 19–26 ns |

Two extra reasons to avoid DSPs on the fast path:

- **DSPs live in columns.** Using them pins part of your placement to a DSP column,
  which may be nowhere near the transceivers, stretching routes.
- **An unpipelined DSP is slow.** Using DSP48E2 without its internal pipeline
  registers throws away most of its Fmax and puts a large fixed delay in your cone.

> **Verify:** DSP48E2 pipeline structure (A/B/M/P registers), latency per
> configuration, and maximum clock rates are in **UG579** (*UltraScale Architecture
> DSP Slice*) and the device datasheet. The "3–4 cycles fully registered" figure is
> a configuration-dependent estimate.

---

## 11. Build-time vs runtime trade-offs

Every knob is either baked into the bitstream (small, fast, requires a rebuild) or
written at runtime (flexible, costs area and sometimes a mux on the critical path).

| Knob | Recommended binding | Rationale |
| --- | --- | --- |
| Symbol universe size | **Elaboration parameter** | Directly sizes memory and address widths |
| Number of book levels maintained | **Elaboration parameter** | See §9 — it decides SLR fit |
| Datapath width | **Elaboration parameter** | Architectural |
| Which strategies are instantiated | **Elaboration parameter** | Unused strategies are pure congestion |
| Per-symbol risk limits | **Runtime register / table** | Changes daily; must change without a rebuild |
| Strategy thresholds and sizes | **Runtime register / table** | Changes intraday |
| Enable/disable a symbol | **Runtime bit** | Must be immediate |
| Kill switch | **Runtime register** | Non-negotiable, hardware-enforced |

Rule of thumb: **if it changes more often than the release cadence, it is a
register; otherwise it is a parameter.** Registers on the fast path should be
*read-only during a trade*, updated atomically (double-buffer or valid bit), and
multicycle-pathed so they don't constrain the datapath.

> ⚠️ Making something runtime-configurable "just in case" is how a 1-cycle compare
> becomes a 1-cycle compare plus a 4:1 mux plus a fanout problem. Every runtime knob
> is paid for in the fast-path pblock.

---

## 12. Power and thermals

### 12.1 Why a trading desk cares

FPGAs do not thermally throttle — there is no DVFS to save you. What actually
happens when the part runs hot:

| Effect | Consequence for us |
| --- | --- |
| **Leakage power rises with junction temperature** | More heat → more leakage → more heat. Thermal runaway is real on large 16 nm parts. |
| **Transistor delay shifts with temperature and voltage** | Your STA margin was computed at a corner; if you narrowed the corner, you have no margin |
| **Transceiver jitter and BER degrade at temperature extremes** | Link errors → 64b/66b block errors → **link retrain**, which is a multi-millisecond latency spike, not a nanosecond one |
| **Fan speed increases / airflow alarms** | Colo remote hands, an incident, a maintenance window |

The transceiver row is the one that bites in production. A fabric that is 2 %
slower is invisible; a GT link that retrains during the open is a catastrophic
outage measured in trades.

### 12.2 Close at the worst-case corner

By default Vivado analyses the worst-case process/voltage/temperature corners from
the speed files. The danger is *narrowing* them:

```tcl
# ⚠️ THIS IS THE TRAP. Narrowing operating conditions buys you fake slack.
# set_operating_conditions -junction_temp 25 -process typical

# What you should do instead: verify you are at the default worst case,
# and report the conditions alongside WNS.
report_operating_conditions -file rpt/opcond.rpt
```

> ⚠️ **A design that closes timing at a 25 °C / typical-process corner and fails at
> 100 °C / slow-process is a design that closes in the lab and loses money in the
> cage.** Never ship a bitstream whose timing was signed off with narrowed
> operating conditions. If someone narrows the corner to close a build, that is a
> failed build, not a closed one.

> **Verify:** UltraScale+ (16 nm) exhibits **inverted temperature dependence** in
> some voltage/threshold regimes — delay can *decrease* with temperature — which is
> why the tools analyse both temperature extremes rather than assuming "hot is
> slow". Confirm the analysed corners for your part and speed grade against
> **DS922/DS923** and **UG906**; do not reason about this from first principles.

### 12.3 Monitoring and the cage

Required always-on telemetry, BAR-readable and alerted on: junction temperature
(SYSMON) with warn/critical thresholds; VCCINT/VCCAUX/VCCBRAM rails; per-GT RX BER
proxy (66b block errors), CDR lock and loss-of-signal; link retrain/realign counters
latched with timestamps; card BMC fan and board sensors if present.

| Practice | Why |
| --- | --- |
| Alert on Tj **trend**, not just threshold | A 5 °C rise over a week is a failing fan or a dust-blocked filter |
| Blanking panels in every empty U | Without them, hot exhaust recirculates to the intake |
| Never place the FPGA card downstream of a GPU/high-TDP card in the same airflow | Intake temperature is what matters, not room ambient |
| Know the facility's contracted intake temperature and its allowable excursion | ASHRAE-class limits vary; a "within SLA" hot day can be well above your bench conditions |
| Estimate power before you build the cage layout | `report_power` post-route + the vendor power estimator spreadsheet |

```tcl
report_power -file rpt/power.rpt
report_power -advisory -file rpt/power_advisory.rpt
```

> **Verify:** SYSMON/System Monitor register map, accuracy and alarm configuration
> are in **UG580** (*UltraScale Architecture System Monitor*). Power estimation
> methodology and the accuracy you can expect from `report_power` are in **UG907**
> (*Power Analysis and Optimization*) — pre-silicon power estimates are estimates;
> **measure on your hardware** with the card's own sensors.

### 12.4 Power optimization that does not cost latency

| Technique | Effect | Fast path safe? |
| --- | --- | --- |
| Clock-gate the slow path / unused strategies | Meaningful dynamic power | Yes — gate the *slow* path only |
| `opt_design -directive ExploreSequentialArea`, `power_opt_design` | Modest dynamic power | ⚠️ `power_opt_design` inserts clock enables; run it **after** timing closure and re-verify WNS |
| Remove unused GT lanes / power down unused quads | Real, and reduces heat near the fast path | Yes |
| Lower the core clock and widen (§10 of [02-fmax...](02-fmax-and-timing-optimization.md)) | Dynamic power scales with frequency | Yes — often a latency win too |
| Reduce toggling on wide buses (gate the data, not just the valid) | Dynamic power | Yes, if it doesn't add a mux to the critical path |

> ⚠️ Never run `power_opt_design` on the fast path before timing closure. It trades
> timing for power and you will spend the difference back at 6.4 ns per cycle.

---

## 13. Resource budget template

Copy into `docs/resource-budget.md`. One row per fast-path module, plus a slow-path
total. Denominator is **one SLR**, not the device.

```markdown
## Fast-path resource budget — target SLR: SLR0, pblock: pblock_fastpath

| Module | Owner | LUT | LUTRAM | FF | BRAM36 | URAM | DSP | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| u_mac_rx           |     |     |     |     |     |     |     | vendor IP, fixed |
| u_feed_arb         |     |     |     |     |     |     |     | |
| u_deframe          |     |     |     |     |     |     |     | |
| u_decode           |     |     |     |     |     |     |     | |
| u_symtab           |     |     |     |     |     |     |     | 8192 × 128 b |
| u_book_tob         |     |     |     |     |     |     |     | BRAM tier |
| u_book_hot         |     |     |     |     |     |     |     | LUTRAM tier, 256 sym |
| u_strategy         |     |     |     |     |     |     |     | |
| u_risk_gate        |     |     |     |     |     |     |     | MANDATORY |
| u_order_encode     |     |     |     |     |     |     |     | template table |
| u_mac_tx           |     |     |     |     |     |     |     | vendor IP, fixed |
| **Fast-path total**|     |     |     |     |     |     |     | |
| **SLR0 capacity**  |  —  |     |     |     |     |     |     | from the datasheet |
| **Occupancy %**    |  —  |     |     |     |     |     |     | **target ≤ 60 % LUT** |

Congestion (post-route, worst level in pblock_fastpath): ___  (target ≤ 4)
SLR crossings on the fast path: ___  (target: 0)
Debug cores in this build: ___  (production target: 0)
```

---

## 14. Rules for this project

1. **Budget against one SLR**, not the device.
2. **Fast-path pblock ≤ 60 % LUT occupancy**, congestion ≤ level 4, SLR crossings
   = 0 — all three enforced in CI.
3. **Slow path lives in a different SLR.** Risk gate does not.
4. **No resource sharing on the fast path.** Sharing is jitter.
5. **Never reduce FF count.** Reduce LUTs, LUTRAM density, and interconnect demand.
6. **Do the memory arithmetic before the RTL.** It decides your floorplan.
7. **No URAM cascades on the trigger path.**
8. **Zero debug cores in a production bitstream**, and re-measure latency after
   stripping them.
9. **Close at the default worst-case corner.** Narrowing operating conditions is a
   failed build.
10. **Junction temperature and GT retrain counters are always-on production
    telemetry**, alerted on trend.

---

## Further reading

- [02-fmax-and-timing-optimization.md](02-fmax-and-timing-optimization.md) — congestion as a timing failure class, and floorplanning XDC
- [01-latency-budgeting.md](01-latency-budgeting.md) — where a URAM cascade shows up as budget debt
- [04-measurement-and-profiling.md](04-measurement-and-profiling.md) — re-measuring after a debug strip
- [05-optimization-playbook.md](05-optimization-playbook.md) — congestion relief in the ordered technique list
- [../00-foundations/02-fpga-architecture.md](../00-foundations/02-fpga-architecture.md) — CLBs, BRAM/URAM columns, DSP slices, SLRs
- [../01-fpga-design/03-memory-and-storage.md](../01-fpga-design/03-memory-and-storage.md) — memory primitives and banking
- [../04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md) — the book structure being budgeted here
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) — thermal and link telemetry in production
