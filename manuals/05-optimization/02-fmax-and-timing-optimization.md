# 05.02 — Fmax and Timing Optimization

> **Why this matters here:** [00-foundations/05-timing-closure.md](../00-foundations/05-timing-closure.md)
> tells you how to read a timing report and gives you a fix hierarchy. This document
> is the deep-dive: how to *diagnose* which class of failure you have before
> touching anything, and which fixes cost latency versus which are free. On a
> trading fast path the ranking is inverted from normal FPGA work — **pipelining is
> the last resort, not the first**, because every stage you add is 6.4 ns you hand
> to a competitor.

---

## 1. The two reasons Fmax matters here (and one it doesn't)

| Reason | Effect on the budget |
| --- | --- |
| **Fmax sets the cycle quantum.** At 156.25 MHz a stage costs 6.4 ns; at 250 MHz it costs 4.0 ns. | Higher Fmax makes *every* pipeline stage cheaper |
| **Failing timing forces a pipeline stage.** The commonest way to lose 6.4 ns is "we couldn't close, so we cut the path." | Closure work is latency work |
| ~~Fmax = throughput~~ | Irrelevant. At 10GbE, 64-bit @ 156.25 MHz already meets line rate. We are never throughput-bound on the fast path. |

So the objective is **not** "maximise Fmax". It is: *close comfortably at the chosen
clock with the fewest pipeline stages*. A design closing at 156.25 MHz with 17
fabric cycles beats one closing at 250 MHz with 30 (108.8 ns vs 120 ns).

> ⚠️ **Do not raise the clock to "buy margin".** Over-constraining makes the tools
> chase paths that don't matter, worsens congestion, and can make your real critical
> path slower. See [00-foundations/05-timing-closure.md](../00-foundations/05-timing-closure.md) §6.

---

## 2. Diagnose before you fix — the four classes

Every failing path is one of four things. Fixing the wrong class wastes a build
cycle (30–180 min on an UltraScale+ device), so classify first.

| Class | Signature in the report | Wrong fix that wastes a day |
| --- | --- | --- |
| **Logic-bound** | `logic > 50 %` of data path delay, logic levels ≥ 10 | Floorplanning |
| **Route-bound** | `route > 60 %`, logic levels low (≤ 6) | Adding a pipeline stage in the middle of the logic |
| **Congestion-bound** | Route-bound **and** congestion level ≥ 5 in the region, many failing endpoints, high TNS | Fixing individual paths |
| **SLR-bound** | Path crosses an SLR boundary (Laguna registers, big fixed penalty) | Anything in RTL |

### 2.1 The diagnostic command sequence

```tcl
open_run impl_1                      ;# ALWAYS post-route. Synthesis timing is fiction.

# 1. Headline: WNS / TNS / failing endpoints
report_timing_summary -delay_type max -max_paths 10 \
    -report_unconstrained -file rpt/timing_summary.rpt
# 2. Worst paths with full clock + input pin detail
report_timing -max_paths 50 -nworst 5 -path_type full_clock_expanded \
    -input_pins -routable_nets -file rpt/timing_worst.rpt
# 3. Classify: logic-level distribution and SLR crossings per path
report_design_analysis -logic_level_distribution \
    -of_timing_paths [get_timing_paths -max_paths 200 -slack_less_than 0.500] \
    -file rpt/da_paths.rpt
# 4. Congestion map + design complexity (Rent exponent)
report_design_analysis -congestion -complexity -file rpt/da_cong.rpt
# 5. High-fanout nets ranked by timing impact
report_high_fanout_nets -timing -load_types -max_nets 25 -file rpt/fanout.rpt
# 6. The tool's own opinion (Vivado 2019.2+)
report_qor_suggestions -file rpt/qor_suggestions.rpt
report_qor_assessment  -file rpt/qor_assessment.rpt
```

> **Verify:** command names, options and report layouts are version-dependent.
> Cross-check against **UG906** (*Vivado Design Suite User Guide: Design Analysis
> and Closure Techniques*) and **UG904** (*Implementation*) for your Vivado version
> before scripting them into CI.

### 2.2 What to read in each report

| Report | Read this | Means |
| --- | --- | --- |
| `timing_summary` | WNS / TNS / #endpoints | 1 endpoint = a path. 800 endpoints = a pattern. |
| `timing_worst` | `Data Path Delay: X (logic A% route B%)` | The logic/route split — your primary classifier |
| `timing_worst` | `Logic Levels: N (LUT6=.. CARRY8=.. MUXF7=..)` | MUXF7/MUXF8 in quantity = a wide mux, see §5.3 |
| `da_paths` | `Logic Level Distribution` histogram | A long tail beyond 10 = systemic, restructure |
| `da_paths` | `SLR Crossings` column | Non-zero on the fast path = stop, fix the floorplan |
| `da_cong` | Congestion levels per region (0–8) | ≥ 5 is a real problem; see §5 of [03-resource-power-optimization.md](03-resource-power-optimization.md) |
| `da_cong` | `Rent Exponent` per hierarchy | > ~0.65 flags a module whose interconnect demand grows faster than its logic |
| `fanout` | Nets with fanout > 100 **and** negative slack | Replication candidates (§4) |

> **Verify:** the congestion scale (levels 1–8, each level a doubling of the
> congested window) and the Rent-exponent guidance are documented in **UG906**.
> Thresholds are heuristics — calibrate against your own designs.

---

## 3. Finding SLR crossings before they find you

On a VU9P-class device the fast path must live in **one SLR** — the one containing
the transceiver quads used by the network interface. An SLR crossing costs a
Laguna hop and takes a fixed, unrecoverable chunk of your cycle.

```tcl
# Which SLR is a given cell in?
get_slrs -of_objects [get_cells u_fastpath/u_book/level_q_reg[0][0]]

# Timing paths that cross an SLR (read the "SLR Crossings" column)
report_design_analysis -of_timing_paths \
    [get_timing_paths -max_paths 500 -slack_less_than 1.0] -file rpt/slr.rpt

# Force the issue: hard assignment, alongside the pblock in §8
set_property USER_SLR_ASSIGNMENT SLR0 [get_cells u_fastpath]
```

The CI check that asserts *zero* escaped fast-path cells is in
[03-resource-power-optimization.md](03-resource-power-optimization.md) §4.

> ⚠️ An unintended SLR crossing is the classic "it closed last week and doesn't
> today" failure. Nothing in the RTL changed; the placer just made a different
> choice. **Constrain it, don't hope.** Add a CI check that asserts zero fast-path
> SLR crossings.

---

## 4. High fanout: analysis and fixes

A net with 500 loads cannot be placed compactly; the placer spreads the loads and
the net delay explodes. This shows up as route-bound failures on *many* endpoints
sharing one source.

### 4.1 Find them

```tcl
report_high_fanout_nets -timing -load_types -max_nets 25 -file rpt/fanout.rpt

# Nets above a threshold, with their driver
foreach n [get_nets -hier -filter {FLAT_PIN_COUNT > 200}] {
    puts "[get_property FLAT_PIN_COUNT $n]  $n"
}
```

### 4.2 Fix them, in order of preference

| # | Fix | Cost | When |
| --- | --- | --- | --- |
| 1 | **Let the tool do it.** Vivado replicates automatically during `opt_design`/`phys_opt_design`. | Free | Fanout < ~200 and the net is not on the worst path. Check `phys_opt` log for "Replication". |
| 2 | `MAX_FANOUT` attribute — tool replicates to the limit | Free, a few FFs | Fanout 200–2000, driver is a register |
| 3 | **Manual replication with `DONT_TOUCH`** | A few FFs, some code noise | The tool refuses (common when the driver is a control signal with a `KEEP` or crosses a hierarchy boundary) |
| 4 | **Tree buffering** — a 1→4→16→64 register fanout tree | +1 cycle per level ⚠️ | Global signals **off** the fast path (reset, config valid, mode) |
| 5 | Restructure so the signal isn't needed everywhere | Design work | Best answer when available |

```systemverilog
// (2) Tool-driven replication
(* MAX_FANOUT = 32 *) logic sym_match_q;

// (3) Manual replication when the tool won't cooperate.
//     Each copy drives one consumer region; DONT_TOUCH stops the
//     optimizer from merging them straight back together.
localparam int NCOPY = 4;
(* DONT_TOUCH = "TRUE" *) logic [NCOPY-1:0] tradeable_q;
always_ff @(posedge clk) begin
  for (int i = 0; i < NCOPY; i++) tradeable_q[i] <= tradeable_d;
end
// u_book uses tradeable_q[0], u_strat uses [1], u_risk uses [2], ...
```

> ⚠️ **Replication without partitioning the loads does nothing.** If all four copies
> still drive all the loads, you have added flip-flops and changed no delay. Assign
> each replica to a specific consumer explicitly, in RTL.

> ⚠️ **Never tree-buffer a fast-path signal.** Each level is a cycle. Reset and
> config are fine; `book_update_valid` is not.

---

## 5. Free fixes: restructure so the logic is smaller

These change *what* is computed, not *when*. They cost zero latency and are the
first thing to try on a logic-bound path.

### 5.1 Precompute — the highest-yield timing fix in a trading FPGA

Anything that does not depend on **this cycle's** input can be computed earlier, by
the slow path or by an off-critical-path pipeline, and read as a registered
constant.

| Runtime work on the critical path | Precomputed replacement | Saved |
| --- | --- | --- |
| `qty * price > notional_limit` (DSP: 3–4 stages, or a wide LUT multiply) | Host precomputes `limit_qty = notional_limit / price_ref` per symbol; fabric does `qty > limit_qty` | A multiply → one compare |
| Rebuild the OUCH message from fields | Per-symbol OUCH template in BRAM; splice ~10 mutable bytes | A serializer → one read + mux |
| Evaluate 8 static risk predicates per tick | Fold statics into a per-symbol `tradeable` bit, updated on parameter change | 8 compares → 1 bit |
| `threshold = f(params, ref_price)` each tick | Recompute on parameter write (slow path), store per symbol | Whole expression → a table read |
| `spread = ask − bid; spread > k` | Maintain `spread` incrementally in the book update; compare against a stored `k` | A subtract off the path |
| Tick-size / price-band lookup by arithmetic | Per-symbol band table indexed by stock locate | Divide/compare chain → read |

**The pattern:** move the computation to the edge where the *parameter* changes,
not the edge where the *market data* arrives. Parameters change thousands of times
less often than ticks.

> ⚠️ Precomputed tables are state. Every one needs a defined update protocol
> (atomic double-buffer or a per-entry valid bit) or you will trade on a
> half-written limit. A torn risk limit is a working-but-wrong design.

### 5.2 Speculation

Compute all outcomes in parallel, select at the end. Costs area (cheap), saves
depth (expensive). See
[01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) §5.

```systemverilog
// Serial: lookup THEN compare — two dependent logic cones in one cycle
// assign fire = (book_px[side_sel] > thresh_sel);

// Speculative: both cones evaluate in parallel, a 2:1 mux resolves
logic fire_buy, fire_sell;
always_comb begin
  fire_buy  = (ask_px_q < buy_thresh_q);
  fire_sell = (bid_px_q > sell_thresh_q);
end
assign fire = side_q ? fire_sell : fire_buy;
```

Apply to: order encode (build buy *and* sell templates, discard one), risk
(evaluate both candidate sizes), symbol lookup (issue the template read on every
book update, not after the trigger).

### 5.3 Structural rewrites that shorten logic cones

| Anti-pattern | Replacement | Why it's faster |
| --- | --- | --- |
| `if/else if` chain over 16 conditions | Bitmask of all conditions + priority encoder | Chain is O(N) LUT depth; mask+encoder is O(log N) |
| Sequential `max` over 32 book levels | Balanced binary tree, or maintain top-of-book incrementally | O(N) → O(log N) → O(1) |
| 64:1 mux on a wide word | Two-level 8:1 → 8:1, or a BRAM/LUTRAM read | Wide muxes chain MUXF7/MUXF8 and route badly |
| `a + b + c + d + e + f` | Balanced adder tree `((a+b)+(c+d))+(e+f)` | Depth 5 → 3 |
| Comparator on a sum: `(a + b) > c` | `a > (c − b)` with `c − b` precomputed | Removes the adder from the compare's cone |
| Unrelated arithmetic broken across the carry chain | Keep additions contiguous so CARRY8 is inferred | A dedicated carry chain is far faster than LUT-built ripple |
| Priority arbiter over 32 requesters | Two-level: 4 groups of 8, then arbitrate groups | Depth halves |
| Wide equality against many constants | ROM/LUTRAM lookup keyed on the value | One read replaces N comparators |

```systemverilog
// Comparison chain → bitmask + priority encoder.
// The 16 comparisons are independent (parallel), only the encoder is deep.
logic [15:0] hit;
always_comb
  for (int i = 0; i < 16; i++) hit[i] = (px_q >= level_px_q[i]);

logic [3:0] idx;
always_comb begin
  idx = '0;
  for (int i = 15; i >= 0; i--) if (hit[i]) idx = i[3:0];  // priority encoder
end
```

---

## 6. Memory as an Fmax lever

Memory choice is a timing decision as much as a capacity one.

| Resource | Read latency | Fmax comfort | Use for |
| --- | --- | --- | --- |
| **LUTRAM / distributed RAM** | 0 (async) or 1 (registered) | Highest, if small and shallow | Small hot tables: order templates for the top N symbols, per-symbol limits |
| **BRAM 36 Kb, output reg OFF** | 1 | ⚠️ Often < ~350 MHz, and the output is a long combinational route | Almost never — see below |
| **BRAM 36 Kb, output reg ON** | 2 | Comfortable well past our clock | **Default for the fast path** |
| **URAM 288 Kb** | 2 (+ **1 per cascade hop**) | Good, but cascade latency is brutal | Deep book storage **off** the trigger path |

Three concrete rules:

1. **Always enable the BRAM output register on the fast path.** The cost is one
   cycle and it is almost always cheaper than the timing failure that follows from
   omitting it. Budget the cycle up front (see §9 of
   [01-latency-budgeting.md](01-latency-budgeting.md)).
2. **⚠️ Never put a URAM cascade on the trigger path.** Cascading URAMs to build a
   deep memory adds a pipeline register *per hop*; an 8-deep cascade is ~8 extra
   cycles = 51 ns. It is invisible in RTL and shows up as "why is our book read 10
   cycles?".
3. **Trade BRAM for LUTRAM when the table is small and hot.** A 64-entry × 128-bit
   template table in LUTRAM is one cycle and no BRAM routing; the same in BRAM is
   two cycles.

> **Verify:** BRAM/URAM structure, the `DOUT_REG`/cascade register behaviour, and
> maximum clock rates are in **UG573** (*UltraScale Architecture Memory Resources*)
> and the device datasheet (**DS922**/**DS923**, *Kintex/Virtex UltraScale+ DC and
> AC Switching Characteristics*). The "~350 MHz unregistered BRAM" figure is an
> estimate — confirm for your speed grade.

---

## 7. Pipelining: last resort on the fast path, first resort off it

| Location | Policy |
| --- | --- |
| **Fast path** (MAC RX → risk → MAC TX) | Pipeline only after §4–§6 are exhausted. Every stage needs a PR justification and a debt-ledger entry. |
| **Slow path** (stats, logging, PCIe, control) | Pipeline freely. Deep pipelines here reduce congestion pressure on the fast path. |
| **Retiming** | Place N back-to-back registers and let `synth_design -retiming on` distribute the logic. Good on the fast path *when the stage count is already committed*. |

If you must add a stage, add it where it buys the most:

1. Run `report_design_analysis -logic_level_distribution` to find the **deepest**
   stage, not the *slowest-slack* one.
2. Rebalance first: if stage A has 12 logic levels and stage B has 2, move logic
   from A to B (zero latency cost) before adding stage C.
3. If you add a stage, add it where it also breaks a long *route*, not just long
   logic.

> ⚠️ **Retiming moves your registers.** ILA probes, `set_multicycle_path` targets
> and any constraint naming a specific register will silently attach to the wrong
> thing. Retime the datapath; don't retime blocks you are actively debugging.

---

## 8. Floorplanning the fast path

Standard practice for a trading datapath, not an exotic measure. The goal: the
entire MAC-RX-to-MAC-TX chain sits in one SLR, close to the transceiver quads,
with the slow path pushed out of the way.

### 8.1 Recipe

1. **Find the GT quads** your network interface uses, and the clock regions
   adjacent to them.
2. **Create one pblock** spanning those clock regions, sized to ~2–3× the fast
   path's area (a tight pblock is worse than no pblock — it creates local
   congestion).
3. **Put only the fast path in it.** Instantiate the slow path *outside*, with its
   own pblock in a different SLR if the device has one.
4. **Do not** pblock the GT/MAC IP itself — it is placed at fixed sites.
5. **Iterate**: run implementation, look at the congestion map, resize.

```tcl
# ── constraints/floorplan.xdc ──────────────────────────────────────
# Confirm the clock-region grid for your exact device before using
# these coordinates — they differ between VU9P, KU15P, etc.

create_pblock pblock_fastpath
add_cells_to_pblock [get_pblocks pblock_fastpath] \
    [get_cells -hier -filter {NAME =~ u_top/u_fastpath*}]
resize_pblock [get_pblocks pblock_fastpath] \
    -add {CLOCKREGION_X0Y0:CLOCKREGION_X3Y4}
set_property USER_SLR_ASSIGNMENT SLR0 [get_cells u_top/u_fastpath]

# Keep the fast path packed but not suffocated. EXCLUDE_PLACEMENT stops
# other logic drifting in; do NOT set CONTAIN_ROUTING on a tight pblock.
set_property EXCLUDE_PLACEMENT TRUE [get_pblocks pblock_fastpath]

# ── Push the slow path away ────────────────────────────────────────
create_pblock pblock_slowpath
add_cells_to_pblock [get_pblocks pblock_slowpath] \
    [get_cells -hier -filter {NAME =~ u_top/u_slowpath* || NAME =~ u_top/u_pcie*}]
resize_pblock [get_pblocks pblock_slowpath] \
    -add {CLOCKREGION_X0Y10:CLOCKREGION_X5Y14}
set_property USER_SLR_ASSIGNMENT SLR2 [get_cells u_top/u_slowpath]
```

> **Verify:** clock-region coordinates, SLR row boundaries and GT quad locations
> are device-specific. Read them from the Vivado device view or
> `report_clock_regions` / `get_sites -filter {SITE_TYPE =~ GTY*}` on **your**
> part, and cross-check against the device's packaging/pinout file. **UG949**
> (*UltraFast Design Methodology*) has the general floorplanning guidance.

### 8.2 Floorplanning anti-patterns

| Anti-pattern | Consequence |
| --- | --- |
| Pblock sized exactly to utilization | Local congestion; routing detours; *worse* timing |
| `CONTAIN_ROUTING` on a tight pblock | Routes forced into a full region; frequently unroutable |
| Pblocking individual small modules | You out-guess the placer badly; it is better than you at local placement |
| Floorplanning at 80 % design completion | Everything moves; weeks lost. Floorplan from the skeleton. |
| No pblock at all on an SSI device | The placer will eventually split your fast path across SLRs |

---

## 9. Tool strategies, directives, and the seed-sweep discipline

### 9.1 What to sweep

```tcl
set place_dirs {Default Explore ExtraNetDelay_high ExtraTimingOpt \
                SSI_SpreadLogic_high AltSpreadLogic_medium WLDrivenBlockPlacement}
set route_dirs {Default Explore AggressiveExplore NoTimingRelaxation \
                MoreGlobalIterations HigherDelayCost}
# phys_opt directives worth adding to the matrix: Explore, AggressiveExplore,
# AlternateReplication, AggressiveFanoutOpt, AddRetime.

foreach p $place_dirs { foreach r $route_dirs {
    set n impl_${p}_${r}
    create_run $n -parent_run synth_1 -flow {Vivado Implementation 2023}
    set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE $p [get_runs $n]
    set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE $r [get_runs $n]
    set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs $n]
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs $n]
}}
launch_runs [get_runs impl_*] -jobs 16
```

Useful pre-canned strategies: `Performance_Explore`,
`Performance_ExplorePostRoutePhysOpt`, `Performance_NetDelay_high`,
`Performance_ExtraTimingOpt`, `Performance_RefinePlacement`,
`Performance_BalanceSLRs`, `Congestion_SpreadLogic_high`,
`Congestion_SSI_SpreadLogic`.

> **Verify:** the set of valid directive names changes between Vivado releases.
> Enumerate them for your version with
> `get_property -help STEPS.PLACE_DESIGN.ARGS.DIRECTIVE` / **UG904**, rather than
> copying this list blindly. Note that **Vivado explores the solution space by
> *directive and strategy*, not by a documented free-form numeric seed** (unlike
> Quartus's fitter seed); "seed sweep" in this project means "directive sweep".
> Vivado ML's Intelligent Design Runs / `report_qor_suggestions` automate some of
> this — check availability in your release.

### 9.2 The seed-sweep rule

> ⚠️ **One lucky run is not timing closure.** Implementation results vary by
> 0.1–0.3 ns of WNS across directives on the same netlist for reasons that have
> nothing to do with your RTL. A design that closes on 1 of 20 runs will fail the
> next time anyone touches a comment.

Project standard:

| Requirement | Value |
| --- | --- |
| Runs per release candidate | ≥ 8 directive combinations |
| Required closure rate | **100 % of runs must have WNS ≥ 0** |
| Required margin | WNS ≥ +0.150 ns on the worst run (thermal/aging/process reserve) |
| What gets reported | The **distribution** — min/median/max WNS across runs, not the best |
| What gets shipped | A specific, recorded directive combination + tool version + netlist hash |

If only some runs close, you have a design problem, not a tool problem. Go back to
§2 and re-diagnose.

---

## 10. When to accept a lower clock and widen instead

Sometimes the right answer is to stop fighting.

```
64-bit  @ 322 MHz (3.10 ns)  — 8 B/cycle,  a 36 B ITCH msg spans 5 beats
128-bit @ 161 MHz (6.21 ns)  — 16 B/cycle, spans 3 beats
256-bit @ 161 MHz (6.21 ns)  — 32 B/cycle, spans 2 beats
512-bit @ 156 MHz (6.40 ns)  — 64 B/cycle, spans 1 beat
```

Widening is usually **strictly better than raising the clock** for this workload:

- Fewer beats per message → fewer reassembly cycles → often *lower absolute latency*
  even at the slower clock.
- No message-straddles-beat-boundary state machine → an entire bug class deleted.
- Timing closes far more easily at 156 MHz, so you spend zero cycles on
  closure-driven pipelining.

Costs: area scales ~linearly with width; byte-alignment barrel shifters get
expensive at 512 bits; congestion rises.

> ⚠️ **Do not width-convert twice.** 64-bit MAC → 512-bit core → 64-bit MAC pays
> gearbox latency at both ends, and the RX gearbox must *accumulate* 8 beats before
> presenting one wide beat — that is 8 × 6.4 = 51.2 ns of pure waiting you invented
> yourself. If the MAC is 64-bit, prefer a 64-bit *streaming* parser with a wide
> *dispatch* over widening the whole datapath. See
> [01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) §3.

---

## 11. Decision flowchart

```
  ┌─ Post-route WNS < 0 ─────────────────────────────────────────────────┐
  │                                                                      │
  │ Q1. Constraints correct? (clock, IO delay, exceptions, CDC groups)   │
  │        NO  → fix constraints, re-run. STOP — you were solving a       │
  │              fictional problem.                                       │
  │        YES ↓                                                          │
  │ Q2. Does the path cross an SLR?          (report_design_analysis §3)  │
  │        YES → pblock + USER_SLR_ASSIGNMENT (§8), re-run. STOP.         │
  │        NO  ↓                                                          │
  │ Q3. Congestion level ≥ 5 in that region? (§2.2, and 03-resource §3)   │
  │        YES → reduce area, spread logic, evict the slow path from the  │
  │              SLR (03-resource §8), re-run. STOP.                      │
  │        NO  ↓                                                          │
  │ Q4. Is route > 60 % of the data path delay?                          │
  │        YES ↓ ROUTE-BOUND                     NO ↓ LOGIC-BOUND         │
  │        │  fanout > 200 on the net?           │  1. Precompute   §5.1  │
  │        │     YES → replicate (§4)            │  2. Speculate    §5.2  │
  │        │     NO  → floorplan (§8) +          │  3. Restructure  §5.3  │
  │        │            directive sweep (§9)     │  4. Rebalance    §7    │
  │        │                                     │  5. Pipeline — LAST,   │
  │        │                                     │     costs 6.4 ns       │
  │        └──────────────┬──────────────────────┘                        │
  │                       ▼                                               │
  │ Still failing?  → faster speed grade (-2 → -3; playbook Tier 1.7)     │
  │                 → lower the clock and widen the datapath (§10)        │
  └──────────────────────────────────────────────────────────────────────┘
```

---

## 12. Rules for this project

1. **Diagnose the class before applying a fix.** One wasted build is an hour; ten
   are a sprint.
2. **Post-route only.** Synthesis timing is not evidence.
3. **Zero SLR crossings on the fast path**, enforced by a CI check.
4. **Precompute and restructure before you pipeline.** A pipeline stage is a debt
   ledger entry.
5. **Closure means closure across the sweep**, with ≥ 0.150 ns margin on the worst
   run.
6. **Floorplan from the skeleton**, not from 80 % complete.
7. **Record the exact directive combination, tool version, and netlist hash** of
   any bitstream that goes near a venue.

---

## Further reading

- [../00-foundations/05-timing-closure.md](../00-foundations/05-timing-closure.md) — STA fundamentals and the fix hierarchy this extends
- [../00-foundations/02-fpga-architecture.md](../00-foundations/02-fpga-architecture.md) — LUTs, CARRY8, MUXF7/F8, SLRs and Laguna
- [../01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) — width vs depth, retiming, speculation
- [../01-fpga-design/03-memory-and-storage.md](../01-fpga-design/03-memory-and-storage.md) — BRAM/URAM/LUTRAM trade-offs in detail
- [01-latency-budgeting.md](01-latency-budgeting.md) — where the cycles you spend get recorded
- [03-resource-power-optimization.md](03-resource-power-optimization.md) — congestion, SLR pressure, and thermal derating
- [05-optimization-playbook.md](05-optimization-playbook.md) — the ordered technique list
