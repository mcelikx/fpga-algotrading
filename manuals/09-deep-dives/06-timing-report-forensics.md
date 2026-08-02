# 09.06 — Timing Report Forensics

> **Why this matters here:** on a normal project a misdiagnosed timing failure costs a build cycle. On
> this one it costs **6.4 ns, permanently**. The universal fix for a failing path is "add a pipeline
> stage" — it always works, it closes timing, it passes CI, and it silently spends a row of the budget
> in `rtl/fpga_top.sv` that was never yours to spend. The fabric total is 20 cycles; three careless
> closure commits are a 15 % latency regression no measurement will ever attribute back to its cause.
> [00.05](../00-foundations/05-timing-closure.md) teaches you to read a report;
> [05.02](../05-optimization/02-fmax-and-timing-optimization.md) tells you what to run and what to
> change. **This is the forensics companion: diagnosing from the numbers alone, line by line, so that
> every stage added on this project is added because the *composition of the delay* proved it was the
> last option left.**

---

## 1. A negative WNS is a symptom, not a diagnosis

Two paths, same clock, same slack, opposite treatments:

| | Path P | Path Q |
| --- | --- | --- |
| Slack | **−0.400 ns** | **−0.400 ns** |
| Data Path Delay | 6.58 ns (logic 4.61 (70 %) route 1.97 (30 %)) | 6.58 ns (logic 0.92 (14 %) route 5.66 (86 %)) |
| Logic Levels | 15 | 3 |
| Endpoint sites | `SLICE_X64Y208` → `SLICE_X65Y209` | `SLICE_X61Y197` → `SLICE_X121Y318` |
| Real cause | Too much combinational work | One net, 1,800 loads, spread over half an SLR |
| Correct fix | Restructure / precompute (**free**) | Replicate the driver (**free**) |
| **Add a pipeline stage** | Works. Costs 6.4 ns. | **Does nothing** — two long routes instead of one, and 6.4 ns less budget |

The headline number is identical and carries **zero** diagnostic information. Everything you need is in
the composition: the logic/route split, the level count, the cell census, the site coordinates. WNS
tells you *that*; the path table tells you *what*.

> **RULE: no closure commit lands without the path's logic/route split, `Logic Levels` with its census,
> and both endpoint site coordinates quoted verbatim in the commit message.** That is the evidence a
> class was diagnosed rather than a fix guessed.

This file does not repeat the command sequence, the fix hierarchy, SLR floorplanning or report
locations — see [05.02](../05-optimization/02-fmax-and-timing-optimization.md) §2.1/§3/§8,
[00.05](../00-foundations/05-timing-closure.md) §4, [07.03](../07-reference/03-toolchain-reference.md).

---

## 2. Anatomy of a `report_timing` path

The worst path from a **REPRESENTATIVE** post-route run of this design — the book engine's
read-modify-write loop, reused as case study (a) in §7.1.

> ⚠️ **REPRESENTATIVE, not measured.** Values are internally consistent so the arithmetic can be
> followed, but they are constructed for teaching. Column layout, delay-type names and line wrapping
> vary by Vivado version.
>
> **Verify:** every field below against the **AMD Vivado Design Suite User Guide: Design Analysis and
> Closure Techniques (UG906)**, "Timing Reports" chapter, for the version pinned in `scripts/env.sh`.
> UG906 is authoritative; this is a reading guide.

### 2.1 Header block

```
Slack (VIOLATED) :        -0.412ns  (required time - arrival time)
  Source:                 u_book/u_level_array/lvl_ram_reg_0_0/CLKARDCLK
                            (rising edge-triggered cell RAMB36E2 clocked by core_clk
                             {rise@0.000ns fall@3.200ns period=6.400ns})
  Destination:            u_book/u_level_rmw/wr_data_q_reg[27]/D
                            (rising edge-triggered cell FDRE clocked by core_clk)
  Path Group:             core_clk
  Path Type:              Setup (Max at Slow Process Corner)
  Requirement:            6.400ns  (core_clk rise@6.400ns - core_clk rise@0.000ns)
  Data Path Delay:        6.635ns  (logic 3.198ns (48.200%)  route 3.437ns (51.800%))
  Logic Levels:           9  (CARRY8=2 LUT3=1 LUT6=4 MUXF7=1 RAMB36E2=1)
  Clock Path Skew:        -0.061ns (DCD - SCD + CPR)
    Destination Clock Delay (DCD): 2.213ns = ( 8.613 - 6.400 )
    Source Clock Delay      (SCD): 2.402ns
    Clock Pessimism Removal (CPR): 0.128ns
  Clock Uncertainty:      0.035ns  ((TSJ^2 + TIJ^2)^1/2 + DJ) / 2 + PE
    Total System Jitter (TSJ): 0.071ns   Total Input Jitter (TIJ): 0.000ns
    Discrete Jitter      (DJ): 0.000ns   Phase Error         (PE): 0.000ns
```

### 2.2 Source clock path

```
    Location      Delay type                     Incr(ns)  Path(ns)  Netlist Resource(s)
  ------------------------------------------------------------------------------------------
                  (clock core_clk rise edge)         0.000     0.000 r
    AR13          IBUFDS (Prop_IBUFCTRL_I_O)         0.630     0.630 r  u_clk_rst/u_ibufds/O
                  net (fo=1, routed)                 1.052     1.682    u_clk_rst/sys_clk_buf
    MMCM_X0Y2     MMCME4_ADV (Prop_CLKIN1_CLKOUT0)  -2.646    -0.964 r  u_clk_rst/u_mmcm/CLKOUT0
                  net (fo=1, routed)                 1.301     0.337    u_clk_rst/core_clk_int
    BUFGCE_X0Y66  BUFGCE (Prop_BUFCE_I_O)            0.081     0.418 r  u_clk_rst/u_bufg_core/O
                  net (fo=41207, routed)             1.984     2.402    u_book/core_clk        <- SCD
    RAMB36_X7Y44  RAMB36E2                                          r   .../lvl_ram_reg_0_0/CLKARDCLK
```

### 2.3 Data path

```
    Location      Delay type                     Incr(ns)  Path(ns)  Netlist Resource(s)
  ------------------------------------------------------------------------------------------
    RAMB36_X7Y44  RAMB36E2 (Prop_CLKARDCLK_DOUTADOUT[15])
                                                     1.708     4.110 r  .../lvl_ram_reg_0_0/DOUTADOUT[15]
                  net (fo=3, routed)                 0.412     4.522    u_level_array/lvl_from_ram[31]
    SLICE_X64Y208 LUT3   (Prop_H6LUT_I1_O)           0.124     4.646 r  u_level_rmw/same_addr_i_1/O
                  net (fo=48, routed)                0.531     5.177    u_level_rmw/same_addr
    SLICE_X66Y210 LUT6   (Prop_D6LUT_I2_O)           0.132     5.309 r  u_level_rmw/lvl_eff[31]_i_2/O
                  net (fo=1, routed)                 0.088     5.397    u_level_rmw/lvl_eff[31]
    SLICE_X66Y210 CARRY8 (Prop_CARRY8_S[0]_CO[7])    0.526     5.923 r  u_level_rmw/new_qty0_carry/CO[7]
                  net (fo=1, routed)                 0.041     5.964    u_level_rmw/new_qty0_carry_n_0
    SLICE_X66Y211 CARRY8 (Prop_CARRY8_CI_O[3])       0.219     6.183 r  u_level_rmw/new_qty1_carry/O[3]
                  net (fo=2, routed)                 0.604     6.787    u_level_rmw/new_qty[27]
    SLICE_X70Y214 LUT6   (Prop_A6LUT_I0_O)           0.124     6.911 r  u_level_rmw/new_cnt_i_4/O
                  net (fo=1, routed)                 0.376     7.287    u_level_rmw/new_cnt_i_4_n_0
    SLICE_X70Y214 MUXF7  (Prop_MUXF7_I0_O)           0.117     7.404 r  u_level_rmw/new_cnt_mux/O
                  net (fo=1, routed)                 0.318     7.722    u_level_rmw/new_cnt_mux_n_0
    SLICE_X72Y216 LUT6   (Prop_C6LUT_I3_O)           0.124     7.846 r  u_tob_track/tob_cmp_i_9/O
                  net (fo=6, routed)                 0.287     8.133    u_tob_track/tob_better
    SLICE_X74Y219 LUT6   (Prop_B6LUT_I5_O)           0.124     8.257 r  u_level_rmw/wr_data_q[27]_i_1/O
                  net (fo=1, routed)                 0.780     9.037    u_level_rmw/wr_data_q_reg[27]_0
    SLICE_X68Y212 FDRE                                                r u_level_rmw/wr_data_q_reg[27]/D
  ------------------------------------------------------------------------------------------
                  arrival time                                 9.037
```

### 2.4 Destination clock path and the arithmetic

```
                  (clock core_clk rise edge)         6.400     6.400 r
       < IBUFDS / MMCME4_ADV / BUFGCE rows identical to the source clock path >
    BUFGCE_X0Y66  BUFGCE (Prop_BUFCE_I_O)            0.081     6.818 r  u_clk_rst/u_bufg_core/O
                  net (fo=41207, routed)             1.795     8.613    u_level_rmw/core_clk   <- DCD
    SLICE_X68Y212 FDRE                                                r u_level_rmw/wr_data_q_reg[27]/C
                  clock pessimism                    0.128     8.741
                  clock uncertainty                 -0.035     8.706
    SLICE_X68Y212 FDRE (Setup_HFF_SLICEL_C_D)       -0.081     8.625    u_level_rmw/wr_data_q_reg[27]
  ------------------------------------------------------------------------------------------
                  required time  8.625      arrival time  -9.037      slack  -0.412
```

### 2.5 Field by field

| Field | What it tells you | What it does **not** tell you |
| --- | --- | --- |
| `Slack (VIOLATED)` | Magnitude → triage priority | Which of the seven classes in §3 you have |
| `Source` / `Destination` | Cell, **pin** and cell type. `/CLKARDCLK` = a BRAM launched this; `/C` = a flop did. The cell type sets the clock-to-out floor | Anything about the logic between them |
| `Path Group` | Which clock's group. `**async_default**` or `none` = a constraint is missing | — |
| `Path Type` | Setup vs hold **and the corner**. Hold failures live in the Min/Fast report and have a different fix set (route padding, not restructuring) | — |
| `Requirement` | Launch-edge → capture-edge distance. **≠ 6.400 on a `core_clk`→`core_clk` path means an exception is in play** | — |
| `Data Path Delay` | The **composition**: the primary classifier (§3) | Severity — see §2.6 (2) |
| `Logic Levels` | Depth **in cells**, plus the census. The census is worth more than the integer | — |
| `Clock Path Skew` | Signed; enters the **required** side. Positive = capture clock later = free setup time, stolen hold margin | — |
| `DCD` / `SCD` | Where each clock edge physically arrives. A big gap on a single-clock design is a **clocking** defect | — |
| `CPR` | **A credit.** Removes pessimism the tool introduced by derating the shared clock segment twice | — |
| `Clock Uncertainty` | Jitter + phase error, applied against you. Large ⇒ look at the MMCM or your `set_clock_uncertainty` | — |
| `Incr(ns)` column | **The most diagnostic column in the report.** One outlier row is a different problem from twenty even rows | — |
| `Location` (`SLICE_X64Y208`) | **Where the diagnosis lives**: endpoint spread, direction of travel, whether the path loops back | Which SLR — get that from `get_slrs` |
| `net (fo=N, routed)` | Fanout and routing status. `estimated`/`unrouted` ⇒ you are reading a post-**place** report and the numbers are fiction | — |

### 2.6 ⚠️ The five fields people misread

1. **`Logic Levels` counts cells, not LUT levels.** Of the 9 here, one is a `RAMB36E2` costing 1.708 ns
   — 53 % of all logic delay in a single "level" — and two are `CARRY8` cells spanning 16 adder bits for
   0.745 ns combined. **Read the census; the integer alone is noise.**
2. **The percentages are of the Data Path Delay, not of the requirement.** A *composition*, never a
   severity. 3.0 ns total at 85 % route is healthy; 6.6 ns at 48 % route is failing. Reading "48 % route"
   as "mostly fine" is the commonest misdiagnosis in this report.
3. **`Clock Path Skew` is signed and is not part of the data path.** No RTL change moves it. Skew of
   −0.400 ns is a clocking defect — second BUFG, unbalanced root, a leaf across a clock region
   ([00.04](../00-foundations/04-clocking-reset-and-cdc.md)) — and restructuring the logic is pure waste.
4. **`CPR` is a credit, not a cost.** The positive number is the tool *giving delay back*. A CPR near
   zero on a same-clock path is the anomaly worth chasing.
5. **The site coordinates are the diagnosis.** The last hop runs `SLICE_X74Y219 → SLICE_X68Y212` —
   **backwards** — for 0.780 ns on a `fo=1` net. That expensive between nearby slices means the placer
   had no good option, and here it had none because **the path is a loop** (§7.1). Pipelining does not
   un-loop a loop.

---

## 3. Classifying from the numbers alone

Pattern-match the signature; confirm with the corroborating report; only then change anything.

| Class | logic % | route % | Logic Levels | Endpoint coords | Corroborating report | Fix | ⚠️ Wrong fix |
| --- | ---: | ---: | ---: | --- | --- | --- | --- |
| **Logic-bound** | **> 55** | < 45 | **≥ 10**, LUT6/MUXF7-heavy census | A few slices apart | `-logic_level_distribution` tail past 10 | Precompute, balance the reduction, restructure | Floorplanning — the cells are already adjacent; you cannot place your way out of depth |
| **Route-bound** | < 35 | **> 60** | **≤ 6** | **Far apart**, tens of columns/rows | Few large `Incr` on single nets | Floorplan, pblock, directive sweep | **Pipelining.** One long route becomes two, and you pay 6.4 ns |
| **Congestion-bound** | < 35 | **> 60** | ≤ 8 | **Adjacent cells still show large net `Incr`** | `-congestion` **≥ 5** in that region; many failing paths share the **region**, not a signal | Reduce area, spread logic, evict the slow path ([05.03](../05-optimization/03-resource-power-optimization.md) §3) | Fixing individual paths — you fix ten and the eleventh appears |
| **SLR-bound** | < 30 | **> 70** | ≤ 4 | **Y coords on opposite sides of the SLR boundary**; one net carries a large fixed `Incr` | `SLR Crossings` ≠ 0; `LAGUNA_X..Y..` sites in the table | pblock + `USER_SLR_ASSIGNMENT` ([05.02](../05-optimization/02-fmax-and-timing-optimization.md) §3) | Anything in RTL — the penalty is architectural and fixed |
| **Fanout-bound** | < 30 | **> 75** | ≤ 5 | One driver; destinations everywhere | **Large `Incr` on the FIRST hop out of the driver**; net tops `report_high_fanout_nets` *with negative slack*; same source in hundreds of endpoints | Replicate the driver, partition loads explicitly ([05.02](../05-optimization/02-fmax-and-timing-optimization.md) §4) | Tree-buffering (a cycle per level), or unconstrained tool replication of a **safety** signal (§7.3) |
| **Clock-bound** | any | any | any | any | Large `Clock Path Skew`; oversized `Clock Uncertainty`; `report_clock_interaction`; two BUFGs on one logical clock | Fix the clock tree / MMCM / CDC constraint | Restructuring the datapath — it is innocent |
| **Constraint-bound** | any | any | any | any | `Requirement` ≠ 6.400 on a same-clock path; group `**async_default**`; `report_exceptions -ignored` | Write the missing `set_false_path` / `set_multicycle_path`, or **stop over-constraining** ([00.05](../00-foundations/05-timing-closure.md) §6) | Fixing the RTL. **The path was never real** — cheapest class, most often missed |

> **RULE: check constraint-bound and clock-bound FIRST**, before consulting the split. They are free to
> test and free to fix; an hour restructuring a path a `set_false_path` deletes is an hour gone.

⚠️ **The mixed case is normal and is not a licence to guess.** The §2 path is 48/52 — no threshold
fires. When the split is ambiguous the split is not the classifier; the **`Incr` column** is.

---

## 4. `report_design_analysis` — the triage table

`-timing` is the best first look: the split, level count and SLR crossings for *every* failing path in
one table, with no per-path `report_timing` invocations.

```
REPRESENTATIVE — report_design_analysis -timing -congestion -complexity   (columns vary by version)

| # | Slack  | Levels | LOGIC_DELAY | NET_DELAY | %LOGIC | %NET | SLR X | Start -> End                    |
|---|--------|--------|-------------|-----------|--------|------|-------|---------------------------------|
| 1 | -0.412 |      9 |       3.198 |     3.437 |   48.2 | 51.8 |     0 | u_book/lvl_ram_reg_0_0 -> u_book/wr_data_q_reg[27]    |
| 2 | -0.394 |      4 |       1.031 |     5.586 |   15.6 | 84.4 |     0 | u_risk_gate/kill_active_reg -> u_risk_gate/fv1_reg[1] |
| 3 | -0.381 |      4 |       1.018 |     5.502 |   15.6 | 84.4 |     0 | u_risk_gate/kill_active_reg -> u_risk_gate/fv1_reg[7] |
| 4 | -0.377 |      4 |       1.014 |     5.488 |   15.6 | 84.4 |     0 | u_risk_gate/kill_active_reg -> u_order_gw/tx_gate_reg |
| 5 | -0.287 |     14 |       4.564 |     1.946 |   70.1 | 29.9 |     0 | u_strategy/param_q_reg -> u_strategy/m_req_valid_reg  |

Placer Final Congestion Reporting          Design Complexity
| Direction | Cong | Window | Region   |   | Instance    | Rent Exp | Avg Fanout | Instances |
| North     |    5 |  16x16 | X2Y2:X3Y3|   | u_top       |     0.61 |        3.4 |   142,318 |
| South     |    5 |  16x16 | X2Y2:X3Y3|   | u_book      |     0.71 |        4.9 |    38,904 |
| East/West |    2 |    4x4 | X3Y3:X3Y3|   | u_risk_gate |     0.68 |        6.2 |    12,447 |
                                            | u_strategy  |     0.55 |        3.1 |     9,880 |
```

**Ten-second read.** Rows 2–4 **share a start point** with identical splits — one net, not three paths
(fanout-bound, §7.3). Row 1 is mixed and alone — structural (§7.1). Row 5 is 70 % logic at 14 levels —
depth (§7.2). `SLR X` is zero everywhere, eliminating the SLR-bound class at a glance. Congestion is 5 in
`X2Y2:X3Y3`; **if a failing path's endpoint coordinates sit in that region you are congestion-bound and
per-path fixes are wasted** — none of these do, so the congestion number is a distraction here.

| Mode | Gives you | The number to look at | The trap |
| --- | --- | --- | --- |
| `-timing` | Per-path split, levels, routes, SLR crossings | **Shared start points across rows** — the pattern, not the worst row | Sorting by slack hides the pattern. Sort by start point |
| `-logic_level_distribution` | Histogram of levels over selected paths | The **tail** past 10, and which module owns it | A high mean is fine; a long tail is systemic |
| `-congestion` | Placer/router congestion per direction, window, region | The level (0–8) **and the region**; ≥ 5 is real | Congestion elsewhere on the die is irrelevant — only the fast-path pblock's region counts |
| `-complexity` | Rent exponent and average fanout per hierarchy | Rent > ~0.65 = interconnect demand growing faster than logic; **it predicts congestion you have not hit yet** | Harmless on the slow path. `u_book` at 0.71 is a warning about the next feature you add |

> **Verify:** the congestion scale and what each level means, the Rent-exponent definition and its
> guidance threshold, and the exact `-timing` column set, against **UG906**. Thresholds are heuristics —
> calibrate against your own builds.

---

## 5. `report_qor_suggestions` — the tool's opinion, and where it is wrong for us

Vivado diagnoses your design and emits machine-readable **RQS objects** a later run consumes. It is
genuinely good at clocking, utilization and congestion, and **structurally unable** to reason about your
problem: it optimizes Fmax and has no representation of a latency budget.

```tcl
open_run impl_1                                  ;# post-route only
report_qor_assessment  -file rpt/qor_assessment.rpt
report_qor_suggestions -file rpt/qor_suggestions.rpt
# ⚠️ Unfiltered `write_qor_suggestions -force rpt/all.rqs` writes EVERY suggestion,
#    pipelining included. Never on this design. Write only reviewed classes:
write_qor_suggestions -of_objects [get_qor_suggestions -filter \
        {NAME =~ CLOCK-* || NAME =~ UTILIZATION-* || NAME =~ CONGESTION-*}] \
    -force rpt/qor_reviewed.rqs

# Next run: read_qor_suggestions goes BEFORE opt_design.
read_qor_suggestions rpt/qor_reviewed.rqs
opt_design; place_design; phys_opt_design; route_design
report_qor_suggestions -file rpt/qor_after.rpt   ;# did they take effect?
```

| Suggestion class | Take it? | Why |
| --- | --- | --- |
| **Clock** (BUFG insertion, clock-root placement, tree balancing) | ✅ Yes | Fixes the clock-bound class, costs zero latency, and you cannot do it better by hand |
| **Utilization** (control-set reduction, LUT combining, DSP/BRAM inference) | ✅ Yes | Area → congestion → latency ([05.03](../05-optimization/03-resource-power-optimization.md) §1). Free |
| **Congestion** (spread-logic strategies, placement directives) | ✅ Yes | Targets the class per-path fixes cannot touch |
| **XDC / constraint** (missing exceptions, missing clock groups) | ✅ After reading it | Often finds a genuinely missing `set_clock_groups`. Never apply a constraint you do not understand |
| **Strategy / directive** | ✅ As a sweep input | Feed the directive matrix ([05.02](../05-optimization/02-fmax-and-timing-optimization.md) §9); do not adopt silently |
| **Timing: "add pipeline registers to path X"** | ❌ **Never automatically on the fast path** | This is the entire problem this file exists for |
| **Timing: retiming a fast-path module** | ⚠️ Only with the stage count already committed | Retiming moves the registers your ILA probes and constraints name |

> **RULE: no RQS suggestion that adds a register stage between MAC RX and MAC TX is ever applied
> automatically.** `report_qor_suggestions` optimizes Fmax; the `fpga_top.sv` budget optimizes
> nanoseconds; on this design those objectives are opposed. A pipelining suggestion is read as
> *diagnosis* ("the tool also thinks this path is deep") and discarded as *prescription*. A stage is
> added only by a human, in a commit that edits the budget table in `rtl/fpga_top.sv` in the same diff.

⚠️ RQS files are **build inputs**. An `.rqs` not in version control and not named in the build manifest
makes the build irreproducible ([06.01](../06-operations/01-build-and-release.md)).

> **Verify:** the Vivado release in which `report_qor_suggestions`, `write_qor_suggestions` and
> `read_qor_suggestions` became available (a Vivado 2019.x-era addition; the RQS object model has changed
> since), the valid suggestion-name prefixes, and whether `read_qor_suggestions` must precede
> `opt_design` in your version — against **UG906** and the release notes for the pinned version.

---

## 6. The decision tree: symptom → next measurement → leaf

Distinct from the fix-shaped flowchart in
[05.02](../05-optimization/02-fmax-and-timing-optimization.md) §11: every node here is **a measurement
you take**, not a change you make.

```
POST-ROUTE WNS < 0
 │
 ├ M1  Path Type: setup or hold?   HOLD ► open the Min/Fast corner report. Different
 │       problem, different fixes (route padding, never restructuring).          ►LEAF
 ├ M2  Requirement != 6.400 on core_clk->core_clk, or group **async_default**?
 │       YES ► report_exceptions -ignored ; report_clock_interaction
 │             ► CONSTRAINT-BOUND — the path may not be real.                    ►LEAF
 ├ M3  |Clock Path Skew| large, or Uncertainty >> the jitter spec?
 │       YES ► report_clock_networks ; report_clock_utilization
 │             ► CLOCK-BOUND — the datapath is innocent.                         ►LEAF
 ├ M4  report_design_analysis -timing over all paths < +0.3 ns:
 │     do the failing rows SHARE A START POINT?
 │       YES ► report_high_fanout_nets -timing ; is the first-hop Incr large?
 │             ► FANOUT-BOUND — replicate, partition loads by name.              ►LEAF
 ├ M5  SLR Crossings != 0, endpoint Y coords across the boundary
 │     (get_slrs -of_objects), or LAGUNA sites in the table?
 │       YES ► SLR-BOUND — floorplan; nothing in RTL helps.                      ►LEAF
 ├ M6  -congestion level >= 5 in the region holding the endpoint coordinates,
 │     with many failing paths sharing the REGION rather than a SIGNAL?
 │       YES ► CONGESTION-BOUND — area work, not path work.                      ►LEAF
 ├ M7  Read the Incr column. ONE outlier row?
 │       hard macro (RAMB/DSP/URAM clock-to-out) ► MACRO-BOUND: enable the output
 │             register, absorb the cycle where it is cheapest (§7.1).           ►LEAF
 │       single net Incr at fo=1 ► the endpoints cannot be co-placed. Ask WHY: a
 │             loop? a pblock edge? a fixed site? (§7.1)                         ►LEAF
 └ M8  logic % > 55 AND Levels >= 10 AND census LUT6/MUXF7-dominated?
         YES ► LOGIC-BOUND — precompute → balance → speculate → rebalance across
               the existing boundary. Pipeline LAST, budget diff included.       ►LEAF
         NO  ► YOU HAVE NOT CLASSIFIED IT. Change nothing. Return to M4 with
               -max_paths 500 and look for the pattern.                          ►LEAF
```

---

## 7. Three worked case studies

### 7.1 (a) `u_book` — the read-modify-write loop

**Symptom** — the §2 report: `Slack -0.412ns`, `Data Path Delay 6.635ns (logic 3.198 (48.2%) route
3.437 (51.8%))`, `Logic Levels 9 (CARRY8=2 LUT3=1 LUT6=4 MUXF7=1 RAMB36E2=1)`, source
`.../lvl_ram_reg_0_0/CLKARDCLK` at `RAMB36_X7Y44`, destination `.../wr_data_q_reg[27]/D` at
`SLICE_X68Y212`.

**Diagnosis, shown.**

1. 48/52 — **neither classifier fires**. §3 is inconclusive; go to the `Incr` column (M7).
2. Outlier one: `RAMB36E2` clock-to-out **1.708 ns** — 53 % of all logic delay and 27 % of the whole
   6.4 ns period, in a cell `Logic Levels` counts as **one**. The level count of 9 was never the problem.
3. Outlier two: the final `net (fo=1) 0.780 ns` running `SLICE_X74Y219 → SLICE_X68Y212`, **backwards**.
   The path is `BRAM read → arithmetic → bypass mux → BRAM write address/data` — **a loop**, and a loop
   has no free end for the placer to pull on.
4. The hot congestion region is `X2Y2:X3Y3`; these coordinates are outside it and `SLR X = 0`. Not
   congestion-bound, not SLR-bound. `same_addr` at `fo=48` costs 0.531 ns — a tenth of the problem.

**Verdict: macro-bound plus loop-bound.** The period is eaten at both ends (BRAM clock-to-out at the
front, setup at the back) and the middle cannot be placed tightly because it closes back on itself.

| # | Fix | Cost | Effect |
| --- | --- | --- | --- |
| 1 | **Enable the BRAM output register (`DOUT_REG`)** on the level array; absorb the cycle at B2 | **1 cycle, 6.4 ns — budgeted, not stolen** | Replaces 1.708 ns of combinational clock-to-out with an internal register. The largest `Incr` disappears ([01.03](../01-fpga-design/03-memory-and-storage.md)) |
| 2 | **Register the bypass select.** `same_addr` compares addresses already known a cycle early — compute it at B2 | Free | Removes a LUT3 and a `fo=48` net (0.655 ns) from the head of the cone |
| 3 | **Restructure the `new_cnt` compare.** The LUT6+MUXF7 pair is `(new_qty==0) ? cnt−1 : cnt`, waiting on the CARRY8 | Free | Speculate both and select, or zero-detect off the carry chain — 0.935 ns of serial depth ([05.02](../05-optimization/02-fmax-and-timing-optimization.md) §5.2) |
| 4 | **Split the RMW.** `cnt` needs a one-bit "this level just emptied", not the 32-bit sum | Free | Breaks the dependency that put the MUXF7 behind the CARRY8 |

⚠️ **The wrong fix: a pipeline register in the middle of the RMW loop.** It closes timing immediately and
it is a **silent data-corruption bug**. The write-forwarding bypass in `level_rmw` is **exactly one deep**
because the read latency is exactly one cycle. A stage inside the loop puts two writes in flight while the
bypass still forwards one, so back-to-back updates to the same price level — **the most common traffic
pattern in the whole feed** — read a stale aggregate and the book drifts. Nothing errors, nothing counts,
and the strategy trades on a wrong book
([04.03](../04-system-architecture/03-order-book-in-hardware.md) §8 "Depth of the bypass";
[05-hash-tables-and-lookup-structures.md](05-hash-tables-and-lookup-structures.md) for the identical
hazard on the order map's write port).

> **RULE: any change to `u_book`'s pipeline depth changes the bypass depth parameter in the same commit,
> with the back-to-back-same-level directed test
> ([04.03](../04-system-architecture/03-order-book-in-hardware.md) §12) re-run and quoted.** Fix 1 above
> triggers this rule — a two-cycle read needs a two-deep bypass.

### 7.2 (b) `u_strategy` — the wide comparison

**Symptom.**

```
Slack (VIOLATED) :        -0.287ns
  Source:      u_strategy/u_param_table/param_q_reg[bank0][412]/C  (SLICE_X70Y224)
  Destination: u_strategy/u_trade_gate/m_req_valid_reg/D           (SLICE_X73Y228)
  Requirement:            6.400ns
  Data Path Delay:        6.510ns  (logic 4.564ns (70.108%)  route 1.946ns (29.892%))
  Logic Levels:           14  (CARRY8=3 LUT2=1 LUT6=8 MUXF7=2)

report_high_fanout_nets: u_strategy/param_bank_sel_q  fanout 1140, on 60+ failing endpoints
```

**Diagnosis, shown.** 70 % logic, 14 levels, endpoints three slices apart — **logic-bound, textbook**.
The census names the culprits: 3 × `CARRY8` are the price/qty comparators (cheap, ~0.2 ns each on a
dedicated chain); 8 × `LUT6` are a **linear** reduction of the trigger conditions, because `trade_gate`
is an `if / else if` priority ladder; 2 × `MUXF7` are the `strat_select` mux — **a wide mux at the end of
the cone instead of the start**. Nothing here is a routing problem.

**The fixes — all four cost zero cycles.**

1. **Precompute the comparison constants host-side.** `fv_buy_thresh = fair_value − edge_ticks` is a
   `sat_sub_px` sitting in the cone. Ship the *thresholds* in the parameter row instead of the operands
   and the fabric does `ask_px < thresh_q` — a subtract-and-take-the-sign-bit on one CARRY8. Parameters
   change at millisecond cadence; ticks arrive at nanosecond cadence
   ([05.02](../05-optimization/02-fmax-and-timing-optimization.md) §5.1,
   [04-fixed-point-arithmetic-in-fabric.md](04-fixed-point-arithmetic-in-fabric.md)).
2. **Balance the reduction.** Condition bitmask + priority encoder: O(N) LUT depth becomes O(log N)
   ([05.02](../05-optimization/02-fmax-and-timing-optimization.md) §5.3).
3. **Move `strat_select` to the front.** Select the *parameters* at S0, not the *decisions* at S1 — one
   mux on a registered value instead of two MUXF7 levels on the critical cone.
4. **Replicate `param_bank_sel_q`** with `MAX_FANOUT`, one copy per primitive.

⚠️ **The wrong fix: pipeline the trigger.** `strategy_engine.sv` owns **exactly 2 of the 20 fabric
cycles** and says so in its header. A third stage is +6.4 ns — 5 % of the whole 128 ns fabric budget —
spent on a path four free restructurings close outright. It is also the *easiest* commit to justify to
yourself, because the strategy layer feels like where complexity belongs. It is not: it is a comparator
over a table, and a feature that will not fit in two cycles belongs on the host
([04.04](../04-system-architecture/04-strategy-engine-on-fpga.md),
[05.01](../05-optimization/01-latency-budgeting.md)).

### 7.3 (c) `u_risk_gate` — the kill switch and the parallel check set

**Symptom.**

```
REPRESENTATIVE — report_high_fanout_nets -timing -load_types -max_nets 3
| # | Net Name                              | Fanout | Driver | FF  | LUT  | WNS    |
| 1 | u_risk_gate/u_kill_switch/kill_active |   1874 | FDRE   | 612 | 1262 | -0.394 |
| 2 | u_risk_gate/trading_en_q              |    986 | FDRE   | 204 |  782 | -0.331 |
| 3 | u_book/u_tob_track/bbo_upd            |    412 | FDRE   | 118 |  294 | +0.180 |

Slack (VIOLATED) :        -0.394ns
  Source:      u_risk_gate/u_kill_switch/kill_active_reg/C  (SLICE_X61Y197)
  Destination: u_risk_gate/fv1_reg[1]/D                     (SLICE_X89Y231)
  Data Path Delay:        6.617ns  (logic 1.031ns (15.581%)  route 5.586ns (84.419%))
  Logic Levels:           4  (LUT6=4)
    SLICE_X61Y197  FDRE (Prop_CFF_SLICEL_C_Q)  0.093  ...  kill_active_reg/Q
                   net (fo=1874, routed)       3.118  ...  u_risk_gate/kill_active
```

**Diagnosis, shown.** 84 % route at 4 logic levels says route-bound — but **not** distance-bound and
**not** congestion-bound, and three numbers prove it: (i) **the first hop out of the driver costs
3.118 ns**, 47 % of the period before any logic happens — distance-bound paths spread route delay across
hops, fanout-bound paths dump it on hop one; (ii) the net tops `report_high_fanout_nets` **with negative
slack** — high fanout alone is not a defect, high fanout *on failing paths* is; (iii) `-timing` rows 2–4
(§4) **share the start point** with near-identical splits, whereas congestion produces many *different*
nets failing in one *region*.

```systemverilog
// rtl/risk/kill_switch.sv — replicating a SAFETY signal is STRUCTURAL, never
// delegated to the fanout optimizer. Every copy is driven from the SAME
// combinational D in the SAME cycle: parallel replication, NOT a buffer tree.
// It costs zero cycles and therefore cannot change KILL_RESP_CYCLES; a TREE
// costs a cycle per level and is forbidden on this net.
localparam int N_KILL_COPY = 6;
(* DONT_TOUCH = "TRUE" *) logic [N_KILL_COPY-1:0] kill_active_r;
always_ff @(posedge clk) begin
    if (rst) kill_active_r <= {N_KILL_COPY{1'b1}};   // fail-closed (CLAUDE.md §5)
    else     kill_active_r <= {N_KILL_COPY{kill_d}};
end
// Loads partitioned EXPLICITLY, by name, one consumer per copy:
//   [0] T0 failure vector     [1] T1 re-apply      [2] risk_gate output register
//   [3] order_gateway TX gate [4] token generator  [5] telemetry / LED
```

Then **balance the verdict reduction** — `pass_d = (fv1 == '0)` over 24 bits should map to a carry-chain
zero-detect, not a 4-deep LUT6 NOR tree; let the tool see an equality against zero, not a hand-written
`|` reduction. And **pre-reduce at T0** — fold every static per-symbol predicate into the prefetched
`enabled`/`blocked` bits so T1's live input count stays small
([05.02](../05-optimization/02-fmax-and-timing-optimization.md) §5.1). That is already the design's
structure; the rule is to keep it that way as checks are added.

⚠️ **Wrong fix 1: let `phys_opt_design`'s fanout optimizer replicate the kill register.** You get an
unknown number of copies with tool-chosen names. The `fpga_top.sv` assertion
`kill_active |-> ##[0:KILL_RESP_CYCLES] !order_out_valid` now names *one* of them, the compliance
question "which register gates the TX path?" has no reviewable answer, and the replication set changes on
every rebuild. **A safety signal's fanout structure is a design artefact, not a tool outcome**
([08.09](../08-nasdaq/09-risk-controls-and-limits.md),
[04.05](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md)).

⚠️ **Wrong fix 2: register the kill signal once more to break the route.** That adds a cycle to the kill
path. `KILL_RESP_CYCLES = 4` in `fpga_top.sv` is an assertion, a documented bound, and a claim made to a
compliance owner. Changing it inside a timing-closure commit is a risk-limit change bundled with
unrelated work — prohibited by CLAUDE.md §6, and exactly the shape of the incidents in
[09-failure-modes-and-postmortems.md](09-failure-modes-and-postmortems.md).

> **RULE: `kill_active` and `trading_en` are replicated, never buffered, never tree-buffered, never
> tool-replicated.** Replication is latency-free; a tree is not. Every copy is enumerated in RTL with its
> consumer named, and the `KILL_RESP_CYCLES` assertion is restated per copy.

---

## 8. Reporting honestly

Restated from [00.05](../00-foundations/05-timing-closure.md) §9 and CLAUDE.md §4, not duplicated: **quote
verbatim, name the directive combination, the tool version, the part and the corner, and never report a
number you did not read out of a file.** A synthesis estimate is not a result; one lucky run is not
closure ([05.02](../05-optimization/02-fmax-and-timing-optimization.md) §9.2).

```tcl
# scripts/timing_forensics.tcl — sourced at the END of every implementation run. Produces
# the exact artefact set a §3 diagnosis needs. None of it is optional: a build whose reports
# are missing cannot be diagnosed later, and re-running P&R to get them costs an hour and
# lands on a different placement.
set d rpt/$::env(FT_BUILD_ID) ; file mkdir $d

report_timing_summary    -delay_type min_max -report_unconstrained -max_paths 10 \
                         -file $d/00_summary.rpt
report_timing            -max_paths 100 -nworst 10 -path_type full_clock_expanded \
                         -input_pins -routable_nets -file $d/01_worst.rpt
report_design_analysis   -timing -logic_level_distribution \
                         -of_timing_paths [get_timing_paths -max_paths 200 \
                                           -slack_less_than 0.300] -file $d/02_da_timing.rpt
report_design_analysis   -congestion -complexity          -file $d/03_da_cong.rpt
report_high_fanout_nets  -timing -load_types -max_nets 25 -file $d/04_fanout.rpt
report_exceptions        -ignored                         -file $d/05_exceptions.rpt
report_clock_interaction -delay_type min_max              -file $d/06_clock_interaction.rpt
report_qor_suggestions                                    -file $d/07_qor.rpt
report_utilization -pblocks [get_pblocks pblock_fastpath] -file $d/08_util_fp.rpt

# The one machine-readable line for the build manifest, beside the git SHA, the part, the
# Vivado version and the directive pair.
set wp [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
puts "QOR build=$::env(FT_BUILD_ID) part=$::env(FT_PART) wns=[get_property SLACK $wp] \
      levels=[get_property LOGIC_LEVELS $wp] src=[get_property STARTPOINT_PIN $wp] \
      dst=[get_property ENDPOINT_PIN $wp]"
```

> **Verify:** the property names on a timing-path object (`SLACK`, `LOGIC_LEVELS`, `STARTPOINT_PIN`,
> `ENDPOINT_PIN`, and the delay-split properties) against **UG906** and
> `report_property [get_timing_paths -max_paths 1]` in your pinned Vivado — they are version-sensitive.
> Report locations and the manifest schema are in [07.03](../07-reference/03-toolchain-reference.md) and
> [06.01](../06-operations/01-build-and-release.md).

---

## 9. Rules for this project

1. **A negative WNS is a symptom.** Classify against §3 before changing a character of RTL.
2. **Quote the composition, not the total** — split, `Logic Levels` + census, both endpoint coordinates — in every closure commit message.
3. **Check constraint-bound and clock-bound first.** Free to test, free to fix.
4. **`Logic Levels` is a cell count.** Read the census: a `RAMB36E2` is one level and five LUT6 worth of delay.
5. **Percentages are composition, never severity.** Judge against the 6.4 ns period.
6. **When the split is ambiguous, read the `Incr` column.** One outlier row is a different problem from twenty even rows.
7. **Shared start points across failing rows means one net, not many paths.** Sort `-timing` by start point before by slack.
8. **Post-route only.** Synthesis timing and `estimated` net delays are not evidence.
9. **RQS output is diagnosis, never automatic prescription.** No pipelining suggestion is scripted onto the fast path, ever.
10. **A pipeline stage on the fast path is a budget edit.** It lands with a diff to the table in `rtl/fpga_top.sv` or it does not land.
11. **Changing `u_book`'s pipeline depth changes the write-forwarding bypass depth** in the same commit, with the directed test re-run and quoted.
12. **Safety signals are replicated structurally in RTL** — never tree-buffered, never left to the fanout optimizer. `KILL_RESP_CYCLES` is not a timing-closure variable.
13. **Every build emits the §8 artefact set.** A build you cannot diagnose afterwards is a build you will run again.

---

## Further reading

- [../00-foundations/01-digital-logic-and-timing.md](../00-foundations/01-digital-logic-and-timing.md) — the setup equation §2.4 implements
- [../00-foundations/02-fpga-architecture.md](../00-foundations/02-fpga-architecture.md) — what `LUT6`, `CARRY8`, `MUXF7`, `RAMB36E2` and Laguna sites are
- [../00-foundations/04-clocking-reset-and-cdc.md](../00-foundations/04-clocking-reset-and-cdc.md) — the clock-bound class: skew, uncertainty, BUFG structure
- [../00-foundations/05-timing-closure.md](../00-foundations/05-timing-closure.md) — the introduction to reading a report, and the fix hierarchy
- [../01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) — speculation and rebalancing, the free alternatives to a stage
- [../01-fpga-design/03-memory-and-storage.md](../01-fpga-design/03-memory-and-storage.md) — BRAM output registers, the case-study (a) fix
- [../04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md) — §8 write forwarding, §11 the B0–B4 budget rows
- [../04-system-architecture/04-strategy-engine-on-fpga.md](../04-system-architecture/04-strategy-engine-on-fpga.md) — the two-cycle contract case study (b) must not break
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — the kill path case study (c) must not lengthen
- [../05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md) — what a pipeline stage actually costs
- [../05-optimization/02-fmax-and-timing-optimization.md](../05-optimization/02-fmax-and-timing-optimization.md) — the commands, the fixes, floorplanning, directive sweeps
- [../05-optimization/03-resource-power-optimization.md](../05-optimization/03-resource-power-optimization.md) — §3 congestion reports in depth
- [../05-optimization/05-optimization-playbook.md](../05-optimization/05-optimization-playbook.md) — the ordered, cheapest-first technique list
- [../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md) — build manifests, RQS files as build inputs, reproducibility
- [../07-reference/03-toolchain-reference.md](../07-reference/03-toolchain-reference.md) — command syntax and report locations
- [../07-reference/04-checklists.md](../07-reference/04-checklists.md) — the timing-closure checklist this file supplies evidence for
- [../08-nasdaq/09-risk-controls-and-limits.md](../08-nasdaq/09-risk-controls-and-limits.md) — why the kill switch's fanout structure is a compliance artefact
- [04-fixed-point-arithmetic-in-fabric.md](04-fixed-point-arithmetic-in-fabric.md) — precomputed thresholds and comparator width, case study (b)
- [05-hash-tables-and-lookup-structures.md](05-hash-tables-and-lookup-structures.md) — the same read-during-write hazard on the order map
- [07-jitter-sources-and-determinism.md](07-jitter-sources-and-determinism.md) — why a bypass beats a stall, and why rescans are counted
- [09-failure-modes-and-postmortems.md](09-failure-modes-and-postmortems.md) — what a bundled risk-limit change looks like after it fails
