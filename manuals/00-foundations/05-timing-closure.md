# 00.05 — Timing Closure

> **Why this matters here:** a design that doesn't close timing doesn't ship. A
> design that closes at 150 MHz when you needed 322 MHz forces you to double your
> datapath width and re-architect. Timing is not a final polishing step — it is a
> constraint you design against from the first module.

---

## 1. What static timing analysis does

**STA** exhaustively checks every register-to-register path in the design against
the timing equation from
[01-digital-logic-and-timing.md](01-digital-logic-and-timing.md), across all
specified process/voltage/temperature corners. It is not simulation — it does not
depend on stimulus and it does not miss cases.

The four path types it checks:

| Path type | From → To | Constrained by |
| --- | --- | --- |
| **Reg-to-reg** | FF → FF | `create_clock` |
| **Input** | port → FF | `set_input_delay` |
| **Output** | FF → port | `set_output_delay` |
| **Combinational (pad-to-pad)** | port → port | `set_max_delay` |

For an FPGA trading design, reg-to-reg dominates. But **an unconstrained input or
output path is simply not checked**, which is how designs pass timing and fail on
hardware.

---

## 2. Reading the numbers

| Term | Meaning |
| --- | --- |
| **Slack** | `required time − arrival time`. Positive = met. |
| **WNS** | Worst Negative Slack — the single worst setup path. The headline number. |
| **TNS** | Total Negative Slack — sum of all negative setup slack. Tells you *how many* paths fail. |
| **WHS / THS** | Same for hold. |
| **Failing endpoints** | Count of endpoints with negative slack. |

Interpretation:

```
WNS = -0.05 ns, TNS = -0.05 ns, 1 endpoint   → one path, one small fix. Easy.
WNS = -0.30 ns, TNS = -45 ns, 800 endpoints  → systemic. Architecture or congestion.
WNS = -2.5 ns,  TNS = -3000 ns               → wrong frequency target or a huge
                                                combinational blob. Re-architect.
```

**Do not chase WNS alone.** TNS and endpoint count tell you whether you're fixing a
path or a pattern. Fixing the worst path in a systemic failure just promotes the
next one.

> ⚠️ **Synthesis timing estimates are not real.** Only post-route timing counts.
> Synthesis is routinely optimistic by 20–40 % because it has no placement
> information and therefore fictional routing delays. Never report a synthesis
> number as "timing closed."

---

## 3. Reading a timing report

```
Slack (VIOLATED) :        -0.412ns
  Source:      u_book/level_q_reg[3][31]/C  (rising edge-triggered, core_clk @ 322.27 MHz)
  Destination: u_strat/trigger_q_reg/D
  Path Group:  core_clk
  Requirement: 3.103ns
  Data Path Delay: 3.401ns  (logic 0.912ns (26.8%)  route 2.489ns (73.2%))
  Logic Levels: 9  (LUT6=6 CARRY8=2 MUXF7=1)
```

The two numbers that tell you what to do:

**Logic % vs. route %**
- **Route-dominated (>60 % route)** → placement/congestion/fanout problem.
  Adding pipeline stages helps less than you'd hope. Look at floorplanning,
  fanout replication, and whether the two endpoints are physically far apart
  (possibly in different SLRs — check).
- **Logic-dominated (>50 % logic, high logic levels)** → too much combinational
  work between registers. Pipeline it.

**Logic levels**
- 1–6: comfortable at almost any frequency
- 7–12: typical; fine up to ~250 MHz
- 13–20: will fail above ~200 MHz
- 20+: needs restructuring, not tweaking

Rule of thumb at 322 MHz (3.1 ns): budget **~6–8 logic levels** max.

---

## 4. The fix hierarchy — try these in order

### Tier 1 — free, do these first
1. **Check your constraints are right.** A wrong `create_clock`, a missing
   `set_clock_groups`, or an over-constrained input delay produces phantom
   violations. Fixing a real design to satisfy a fictional constraint is pure waste.
2. **Check for unintended CDC paths** being analyzed as synchronous.
3. **Check for SLR crossings** on the failing path (`report_design_analysis`).

### Tier 2 — cheap RTL changes
4. **Add a pipeline stage** at the failing point. Costs one cycle of latency;
   usually the highest-leverage fix. Budget for this from the start — see §7.
5. **Replicate high-fanout registers.** If a signal drives hundreds of loads,
   duplicate the source FF and split the loads.
   ```systemverilog
   (* MAX_FANOUT = 32 *) logic enable_q;
   ```
   Or duplicate manually with `(* DONT_TOUCH = "TRUE" *)` when the tool won't.
6. **Register BRAM outputs.** BRAM without the output register rarely exceeds
   ~350 MHz.
7. **Break wide combinational trees.** A 256-way max becomes two pipelined 16-way
   stages.
8. **Move logic across a register.** If the path is `FF → 12 levels → FF` and the
   *next* stage is `FF → 2 levels → FF`, rebalance to 7 and 7.

### Tier 3 — restructuring
9. **Precompute.** Anything not dependent on this cycle's input can be computed a
   cycle earlier and registered. This is the most under-used technique — see
   [05-optimization/02-fmax-and-timing-optimization.md](../05-optimization/02-fmax-and-timing-optimization.md).
10. **Speculate.** Compute both branches in parallel, select at the end. Trades
    area for depth.
11. **Change the data structure.** Maintaining top-of-book incrementally is vastly
    cheaper than recomputing a max over the book each update.
12. **Reduce parallel contention.** Two writers arbitrating for one memory port
    creates a mux and a stall path. Bank the memory instead.

### Tier 4 — physical
13. **Floorplan (`pblock`).** Constrain the fast path to a region near the
    transceivers, inside one SLR. This is standard practice for a trading datapath,
    not an exotic measure.
14. **Change implementation strategy.** `Performance_ExplorePostRoutePhysOpt`,
    `Performance_NetDelay_high`, etc. Try several; they can differ by 10 %+.
15. **Enable `phys_opt_design`** with multiple directives.
16. **Faster speed grade part.** A -3 over a -2 is ~10–15 % Fmax for money — often
    cheaper than weeks of engineering.

### Tier 5 — last resort
17. **Lower the clock and widen the datapath.** 64-bit @ 322 MHz becomes 128-bit @
    161 MHz — same throughput, easier timing, and possibly *lower* latency in
    messages-per-cycle terms.

---

## 5. Constraints you must write

```tcl
# ── Primary clocks ─────────────────────────────────────────────────
create_clock -name core_clk -period 3.103 [get_ports core_clk_p]
create_clock -name pcie_clk -period 4.000 [get_ports pcie_refclk_p]

# ── Asynchronous domain groups ─────────────────────────────────────
set_clock_groups -asynchronous \
    -group [get_clocks core_clk] \
    -group [get_clocks pcie_clk]

# ── Input/output delays — REQUIRED, not optional ───────────────────
set_input_delay  -clock core_clk -max 1.5 [get_ports {gpio_in[*]}]
set_input_delay  -clock core_clk -min 0.5 [get_ports {gpio_in[*]}]
set_output_delay -clock core_clk -max 1.5 [get_ports {gpio_out[*]}]
set_output_delay -clock core_clk -min 0.5 [get_ports {gpio_out[*]}]

# ── Genuinely static config registers ──────────────────────────────
# Only for signals that are stable for thousands of cycles before use.
set_false_path -from [get_cells {u_cfg/static_cfg_reg[*]}]

# ── Floorplan: keep the fast path together ─────────────────────────
create_pblock pblock_fastpath
add_cells_to_pblock [get_pblocks pblock_fastpath] \
    [get_cells -hier -filter {NAME =~ *u_fastpath*}]
resize_pblock [get_pblocks pblock_fastpath] -add {SLR0}
```

Constraint hygiene rules:
- **One file per concern**: `clocks.xdc`, `io.xdc`, `cdc.xdc`, `floorplan.xdc`.
- Constraints reference **cells and nets by hierarchical name**. Renaming a module
  silently breaks them. Add a check that every constraint matches at least one
  object (`get_cells` returning empty is a warning most people ignore — don't).
- Run `report_exceptions -ignored` to find constraints that are being overridden or
  are doing nothing.

---

## 6. The over-constraining trap

Setting a clock faster than you need "for margin" is a common and expensive
mistake:

- The tools spend enormous runtime chasing paths that don't matter.
- `phys_opt` makes bad global trade-offs to fix an artificial worst path.
- You get a design that's harder to route, more congested, and possibly *slower*
  in the paths you actually care about.

**Constrain to what you need.** If you need 156.25 MHz, constrain 156.25 MHz. If a
specific path needs to be faster, use a `set_multicycle_path` on the ones that
don't, rather than raising the global clock.

Conversely, `set_multicycle_path` is genuinely useful for the control plane:

```tcl
# Config register updates only need to settle within 4 cycles
set_multicycle_path -setup 4 -from [get_cells {u_cfg/*_reg[*]}] -to [get_cells {u_dp/cfg_*_reg[*]}]
set_multicycle_path -hold  3 -from [get_cells {u_cfg/*_reg[*]}] -to [get_cells {u_dp/cfg_*_reg[*]}]
```

⚠️ A `-setup N` multicycle **must** be paired with `-hold N-1`, or you create hold
violations the tools will "fix" by padding routes.

---

## 7. Designing for closure from the start

The cheapest timing fix is the one you never needed. Practices that pay for
themselves:

1. **Register module outputs.** Makes each module's timing locally analyzable and
   prevents cross-module path explosions.
2. **Budget pipeline slack.** If your latency budget allows 12 cycles for a block,
   design it in 9 and keep 3 in reserve for closure. Discovering at P&R that you
   have no cycles to spend is the worst position to be in.
3. **Run implementation early and often.** Don't write 20 modules and then
   implement. Run a full P&R as soon as a skeleton exists, and track WNS over time
   as a CI metric. See [06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md).
4. **Know your critical path before the tools tell you.** For a trading datapath
   it's almost always one of: the book update path, the wide comparison in the
   strategy trigger, the symbol lookup, or a high-fanout enable.
5. **Floorplan early.** Deciding at 80 % complete that the fast path must be in
   SLR0 means moving everything.

---

## 8. Timing closure workflow

```
1. Fix constraints first          → are you solving a real problem?
2. report_timing_summary          → WNS, TNS, endpoint count
3. report_timing -max_paths 20 -nworst 5 -path_type full_clock_expanded
4. Classify: logic-bound or route-bound?  (§3)
5. Cluster the failures            → same module? same net? same SLR crossing?
6. Apply the cheapest fix from §4 that addresses the class
7. Re-run implementation           → did WNS improve AND TNS improve?
8. Repeat
```

Rules for step 7: **change one thing at a time.** FPGA implementation is
non-deterministic-ish across runs (different seeds → different results), so a 0.05 ns
"improvement" may be noise. If a change matters, it should be visible across
multiple seeds. Track WNS across a seed sweep, not a single run.

---

## 9. Reporting timing honestly

When reporting results in this project:

- Quote WNS, TNS, WHS, and failing-endpoint count from the **post-route** report.
- State the target frequency and the tool version.
- If you ran a seed sweep, report the distribution, not the best seed.
  A design that closes on 1 of 20 seeds does not close.
- Never say "timing closed" based on synthesis.

---

## Further reading

- [05-optimization/02-fmax-and-timing-optimization.md](../05-optimization/02-fmax-and-timing-optimization.md) — the deep-dive techniques
- [01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) — where the pipeline stages go
- [07-reference/03-toolchain-reference.md](../07-reference/03-toolchain-reference.md) — exact commands and report locations
