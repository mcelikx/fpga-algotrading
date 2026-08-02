# 07.03 — Toolchain Reference

> **Why this matters here:** the tools are the only source of truth about whether
> the design works and how fast it is. Everything in these manuals about timing,
> resources, and latency comes out of one of the commands below. This file exists
> so you never have to remember which report has the number you need — and so
> nobody in this project ever reports a synthesis estimate as a result.

> **Verify:** command syntax, available `-directive` values, report contents, and
> even report *names* change between tool releases. Every command below must be
> checked against the **Vivado Design Suite Tcl Command Reference (UG835)** for the
> version pinned in `scripts/env.sh`, or with `<command> -help` in an interactive
> `vivado -mode tcl` session. Where an option is version-sensitive it is flagged.

---

## 1. Environment and version pinning

```bash
# scripts/env.sh — sourced by every build. Fails loudly on mismatch.
set -euo pipefail

export FT_VIVADO_VERSION="2023.2"          # pinned; changing this is a release event
export FT_PART="xcvu9p-flga2104-2-i"
export FT_VERILATOR_VERSION="5.020"
export FT_COCOTB_VERSION="1.8.1"

source /tools/Xilinx/Vivado/${FT_VIVADO_VERSION}/settings64.sh

actual=$(vivado -version 2>/dev/null | head -1 | awk '{print $2}' | tr -d 'v')
[[ "$actual" == "$FT_VIVADO_VERSION" ]] || {
  echo "FATAL: Vivado $actual != pinned $FT_VIVADO_VERSION"; exit 1; }

verilator --version | grep -q "$FT_VERILATOR_VERSION" || {
  echo "FATAL: Verilator version mismatch"; exit 1; }
```

Rules:
- Tool versions live in **one** file. Never in a Makefile, never in CI YAML, never
  in someone's shell profile.
- Bump the version in a dedicated commit that re-runs the full seed sweep and
  records the QoR delta. A tool upgrade is a design change.
- Run builds inside a pinned container image so the OS libraries are also fixed.

---

## 2. Vivado non-project Tcl flow

**Non-project mode only.** No `.xpr`, no `.runs/`, nothing that a diff cannot show.

```bash
vivado -mode batch -nojournal -notrace \
       -log  builds/current/vivado.log \
       -source scripts/build.tcl \
       -tclargs "$FT_PART" 7 builds/current
```

| Flag | Purpose |
| --- | --- |
| `-mode batch` | Run and exit. `-mode tcl` gives an interactive shell for exploration. |
| `-nojournal` | Suppress `vivado.jou`; the script *is* the journal |
| `-notrace` | Do not echo every sourced line; keeps logs readable |
| `-log <file>` | Put the log inside the build directory so it is archived with everything else |
| `-tclargs` | Everything after this lands in `$argv` |

### The stages

```tcl
# ── Read ──────────────────────────────────────────────────────────────
read_verilog -sv [glob rtl/**/*.sv]      ;# -sv is required for SystemVerilog
read_ip      [glob ip/*/*.xci]           ;# checked in; do NOT upgrade_ip in a build
read_xdc     constraints/clocks.xdc
read_xdc     constraints/io.xdc
read_xdc     constraints/cdc.xdc
read_xdc     constraints/floorplan.xdc
# read_checkpoint <file.dcp>             ;# to resume from a prior stage

# ── Synthesize ────────────────────────────────────────────────────────
synth_design -top top_trading -part $part \
             -flatten_hierarchy rebuilt \
             -directive Default \
             -keep_equivalent_registers \
             -resource_sharing off \
             -no_lc
```

| `synth_design` option | Why it matters here |
| --- | --- |
| `-flatten_hierarchy rebuilt` | Optimizes across boundaries, then rebuilds names so reports and constraints stay readable. `none` preserves boundaries (useful for debug), `full` gives unreadable names. |
| `-keep_equivalent_registers` | ⚠️ **Important for us.** Stops the tool merging registers you deliberately replicated to cut fanout. |
| `-resource_sharing off` | Prevents the tool sharing one adder between two paths, which adds muxes on a latency-critical path. Costs area. |
| `-no_lc` | Disables LUT combining. Slightly more area, better timing. |
| `-retiming on` | Lets the tool move registers to balance paths. Can help Fmax — but ⚠️ **verify your cycle-exact latency assertions still pass**, because retiming can shift where your pipeline stages land. |
| `-mode out_of_context` | Synthesize a block standalone (no IO buffers). For per-module QoR checks. |
| `-directive` | Alternative algorithm sets; see §5 |

```tcl
# ── Implement ─────────────────────────────────────────────────────────
opt_design      -directive Explore
place_design    -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design    -directive Explore
phys_opt_design -directive AggressiveExplore     ;# post-route pass

write_checkpoint -force builds/current/post_route.dcp
write_bitstream  -force -bin_file builds/current/top_trading.bit
```

| Stage | What it does | When to tune it |
| --- | --- | --- |
| `opt_design` | Netlist-level logic optimization, constant propagation, cell removal | Rarely the bottleneck |
| `place_design` | Assign cells to physical sites | The highest-leverage stage for a route-bound design |
| `phys_opt_design` | Post-place (and post-route) physical optimization: replication, retiming, hold fixing | Run it twice; it is nearly free relative to a re-place |
| `route_design` | Connect the placed cells | Tune when congestion is the problem |
| `write_bitstream` | Produce the `.bit`. `-bin_file` also emits a raw `.bin` for flash/programming tools | Always `-force` in CI |

---

## 3. Report commands

Run these into files inside the build directory. **The reports are archived
artifacts, not console output.**

| Command | What it is for | What to look for |
| --- | --- | --- |
| `report_timing_summary` | The closure verdict | **WNS, TNS, WHS, THS, failing endpoint count.** Also the "check_timing" section: unconstrained paths, missing input/output delays, no-clock endpoints |
| `report_timing` | Individual path detail | Logic vs. route delay split, logic levels, source/destination cell names, whether the path crosses an SLR |
| `report_utilization` | Resource consumption | LUT/FF/BRAM/URAM/DSP percentages. `-hierarchical` attributes them to modules. Anything > 70 % is a routing risk |
| `report_design_analysis` | Congestion + complexity + path characterization | **Congestion level per region (0–8; ≥ 5 is trouble)**, logic-level distribution, SLR crossing counts |
| `report_cdc` | Clock domain crossings | Any "Critical" or "Warning" severity crossing that is not a sanctioned synchronizer. ⚠️ **Every entry must be explained.** |
| `report_clock_interaction` | Which clock pairs have paths between them | Unexpected clock pairs with "Timed" (rather than "Asynchronous Groups") status — those are unintended CDC being analyzed as synchronous |
| `report_high_fanout_nets` | Nets driving many loads | Anything over a few hundred loads on the fast path. Prime candidate for replication |
| `report_qor_suggestions` | Tool-generated QoR advice | Suggestions can be applied automatically; treat as hints, verify each |
| `report_methodology` | UltraFast methodology rule checks | Structural problems the timing report will not show: missing constraints, bad reset structures, clocking issues |
| `report_drc` | Design rule checks | Must be clean before bitstream. Every waiver documented with an owner |
| `report_power` | Power estimate + thermal | Total watts vs. the card's budget; junction temperature estimate — relevant to timing margin |
| `report_exceptions -ignored` | Constraints that are doing nothing | A `set_false_path` matching zero objects is a silent hole in your timing analysis |
| `report_route_status` | Routing completeness | Any unrouted or partially-routed nets |
| `report_clocks` / `report_clock_networks` | Clock topology | Confirms every clock is what you think it is |

### Standard invocations

```tcl
report_timing_summary -delay_type min_max -report_unconstrained \
                      -check_timing_verbose -max_paths 10 -input_pins \
                      -warn_on_violation -file $rpt/post_route_timing.rpt

report_timing -max_paths 50 -nworst 10 -path_type full_clock_expanded \
              -sort_by group -file $rpt/post_route_paths.rpt

# Only the paths that actually fail
report_timing -slack_lesser_than 0 -max_paths 200 -file $rpt/failing.rpt

# Only the fast path, for a focused view
report_timing -from [get_cells -hier -filter {NAME =~ *u_fastpath*}] \
              -max_paths 20 -file $rpt/fastpath_timing.rpt

report_utilization -hierarchical -hierarchical_depth 3 -file $rpt/util_hier.rpt
report_utilization -slr                                -file $rpt/util_slr.rpt

report_design_analysis -complexity -congestion -timing -logic_level_distribution \
                       -of_timing_paths [get_timing_paths -max_paths 50] \
                       -file $rpt/design_analysis.rpt

report_cdc               -details        -file $rpt/cdc.rpt
report_clock_interaction -delay_type min_max -significant_digits 3 \
                                          -file $rpt/clock_interaction.rpt
report_high_fanout_nets  -fanout_greater_than 200 -max_nets 50 -timing -load_types \
                                          -file $rpt/high_fanout.rpt
report_qor_suggestions   -file $rpt/qor_suggestions.rpt
report_methodology       -file $rpt/methodology.rpt
report_drc               -file $rpt/drc.rpt
report_power             -file $rpt/power.rpt
report_exceptions -ignored -file $rpt/exceptions_ignored.rpt
```

> **Verify:** `-logic_level_distribution`, `-load_types`, `report_qor_suggestions`,
> and `report_pipeline_analysis` are among the options/commands that appeared or
> changed in specific releases. Confirm availability with `-help` before putting
> them in `build.tcl`, or the whole build fails on an unknown option.

### Report naming and location

```
builds/<YYYYMMDD>-<gitsha7>-s<seed>/
├── manifest.json
├── vivado.log
├── top_trading.bit
├── post_synth.dcp
├── post_route.dcp
└── rpt/
    ├── 00_post_synth_util.rpt
    ├── 01_post_synth_timing.rpt
    ├── 10_post_route_timing.rpt      ← the closure number lives here
    ├── 11_post_route_paths.rpt
    ├── 12_failing.rpt
    ├── 13_fastpath_timing.rpt
    ├── 20_util_hier.rpt
    ├── 21_util_slr.rpt
    ├── 30_design_analysis.rpt
    ├── 40_cdc.rpt
    ├── 41_clock_interaction.rpt
    ├── 42_high_fanout.rpt
    ├── 50_methodology.rpt
    ├── 51_drc.rpt
    ├── 52_exceptions_ignored.rpt
    └── 60_power.rpt
```

Numeric prefixes keep flow order in a directory listing. Never write reports to a
scratch directory — if it is not next to the bitstream, it did not happen.

---

## 4. Extracting numbers for CI

```tcl
# scripts/tcl/util.tcl — sourced after report_timing_summary
proc ft_dump_qor {outfile} {
    report_timing_summary -quiet -no_header -file /dev/null
    set d [current_design]
    set fh [open $outfile w]
    puts $fh [format {{"wns":%s,"tns":%s,"whs":%s,"ths":%s}} \
        [get_property STATS.WNS $d] [get_property STATS.TNS $d] \
        [get_property STATS.WHS $d] [get_property STATS.THS $d]]
    close $fh
}

# Alternative, always available: read the worst path directly
set wns [get_property SLACK [lindex [get_timing_paths -delay_type max -max_paths 1 -nworst 1] 0]]
set whs [get_property SLACK [lindex [get_timing_paths -delay_type min -max_paths 1 -nworst 1] 0]]
```

> **Verify:** the `STATS.WNS` / `STATS.TNS` design properties are populated by
> `report_timing_summary` and their availability is version-dependent. The
> `get_timing_paths` form is the more portable fallback. Confirm both on the pinned
> version and pick one — do not mix.

⚠️ Never parse WNS out of the human-readable report with a regex in CI. The report
format changes between releases; the Tcl properties do not change as often, and
when they do it fails loudly instead of silently reporting `0.000`.

---

## 5. Directives and strategies worth trying

For a latency-critical, moderately-utilized design, this is the order to try.

| Stage | Directive | Try when |
| --- | --- | --- |
| `opt_design` | `Explore` | Default choice for a timing-critical design |
| `place_design` | `ExtraTimingOpt` | Baseline for timing-critical work |
| `place_design` | `ExtraNetDelay_high` | Route-dominated failures (route > 60 % of path delay) |
| `place_design` | `AltSpreadLogic_high` / `SSI_SpreadLogic_high` | Congestion level ≥ 5 in `report_design_analysis` |
| `place_design` | `SSI_BalanceSLLs` / `SSI_SpreadSLLs` | SSI (multi-SLR) devices with many SLR crossings |
| `place_design` | `EarlyBlockPlacement` | BRAM/DSP-heavy designs where block placement is driving the failures |
| `phys_opt_design` | `AggressiveExplore` | Default; run both post-place and post-route |
| `phys_opt_design` | `AggressiveFanoutOpt` | High-fanout nets identified in `report_high_fanout_nets` |
| `phys_opt_design` | `ExploreWithHoldFix` | Hold violations survive routing |
| `route_design` | `Explore` | Default |
| `route_design` | `AggressiveExplore` | Last ~0.1–0.3 ns of setup slack |
| `route_design` | `MoreGlobalIterations` | Congested designs |
| `route_design` | `NoTimingRelaxation` | You want the router to refuse to give up on timing (longer runtime) |

> **Verify:** directive names are release-specific and differ per command. Get the
> authoritative list from `place_design -help` (etc.) on the pinned version, or
> from **UG904**. Do not copy a directive name from an older manual — an invalid
> directive aborts the run.

⚠️ A directive change that improves WNS by 0.05 ns on one seed is noise. Validate
any directive change across the seed sweep before adopting it
(see [../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md) §6).

---

## 6. Verilator

### Lint

```bash
verilator --lint-only -Wall \
          --top-module top_trading \
          -Irtl/common -Irtl/feed -Irtl/book \
          $(find rtl -name '*.sv')
```

| Warning | Why it matters here |
| --- | --- |
| `LATCH` | ⚠️ An inferred latch. **Always a bug in this project.** |
| `WIDTH` / `WIDTHEXPAND` / `WIDTHTRUNC` | Silent bit truncation — the classic path from "works" to "wrong order size" |
| `CASEINCOMPLETE` | A `case` without `default`; produces a latch or an undefined state |
| `BLKSEQ` / `COMBDLY` | Blocking assignment in sequential logic or vice versa — simulation/synthesis mismatch |
| `MULTIDRIVEN` | Two drivers on one signal |
| `UNOPTFLAT` | A combinational loop, or a false one caused by bit-level dependencies |
| `IMPLICIT` | An undeclared signal silently created as a 1-bit wire |
| `UNDRIVEN` / `UNUSED` | Dead logic or a forgotten connection |
| `PINMISSING` | An unconnected module port |
| `SYNCASYNCNET` | A signal used as both synchronous data and an async reset |
| `ALWCOMBORDER` | An `always_comb` block that reads a variable before assigning it |

**Project rule:** lint is clean with `-Wall`, zero warnings. Waivers live in
`waivers/verilator.vlt` with a one-line justification and an owner — never as an
inline `/* verilator lint_off */` without a comment.

### Simulation

```bash
verilator --binary -j 0 -Wall --assert \
          --trace-fst --trace-structs --trace-depth 6 \
          --x-assign unique --x-initial unique \
          --timing \
          --top-module tb_book \
          rtl/book/book.sv tb/sv/tb_book.sv \
          -o Vtb_book
./obj_dir/Vtb_book
```

| Flag | Purpose |
| --- | --- |
| `--binary` | Build a self-contained executable (shorthand for `--cc --exe --build --main --timing`) |
| `-j 0` | Use all cores for the C++ build |
| `--assert` | Enable SystemVerilog assertions — otherwise your SVA does nothing |
| `--trace-fst` | FST waveform output; far smaller and faster than VCD |
| `--trace-structs` | Keep struct field names in the waveform instead of flattened bit vectors |
| `--x-assign unique` / `--x-initial unique` | ⚠️ **Randomize X values instead of defaulting to 0.** Verilator is 2-state; without this it will hide uninitialized-state bugs that a 4-state simulator would catch. |
| `--timing` | Support delays and event controls used by testbenches |
| `--coverage` | Line/toggle coverage collection |

> **Verify:** `--binary`, `--timing`, and `--main` were added/changed across
> Verilator 4.x → 5.x. Confirm against `verilator --help` and the Verilator manual
> for the pinned version.

⚠️ Verilator is 2-state. It will **not** propagate X for uninitialized registers
the way a 4-state simulator does. For reset-correctness and initialization bugs,
run the vendor simulator on a release candidate as well.

---

## 7. cocotb

### Layout and Makefile

```makefile
# tb/unit/Makefile
SIM           ?= verilator
TOPLEVEL_LANG ?= verilog
RTL           := $(PWD)/../../rtl

VERILOG_SOURCES := $(RTL)/common/skid_buffer.sv \
                   $(RTL)/book/book.sv
TOPLEVEL      := book
MODULE        := test_book

EXTRA_ARGS    += -Wall --assert --x-assign unique --x-initial unique
ifeq ($(WAVES),1)
  EXTRA_ARGS  += --trace-fst --trace-structs --trace-depth 6
endif

COCOTB_HDL_TIMEUNIT      = 1ns
COCOTB_HDL_TIMEPRECISION = 1ps

include $(shell cocotb-config --makefiles)/Makefile.sim
```

```bash
make                                    # run every test in MODULE
make TESTCASE=test_max_order_qty_reject # run exactly one test
make WAVES=1 TESTCASE=test_book_cross   # one test, with a waveform
make SIM=questa                         # same testbench, vendor simulator
make clean
```

### pytest-driven (preferred for regression and parameter sweeps)

```python
# tb/unit/test_book_runner.py
import pytest
from cocotb.runner import get_runner   # cocotb >= 1.7

@pytest.mark.parametrize("levels", [8, 16, 32])
def test_book_depth(levels):
    runner = get_runner("verilator")
    runner.build(
        sources=["rtl/book/book.sv"],
        hdl_toplevel="book",
        parameters={"N_LEVELS": levels},
        build_args=["-Wall", "--assert", "--x-assign", "unique"],
    )
    runner.test(hdl_toplevel="book", test_module="test_book")
```

```bash
pytest tb/unit -k "test_book_depth[16]" -v      # a single parameterization
pytest tb/ -n auto                              # full regression, parallel
```

> **Verify:** `cocotb.runner` / `cocotb_tools.runner` moved between cocotb releases,
> and cocotb 2.x changed several APIs. Pin the version in `scripts/env.sh` and
> check the import path against the installed release.

**Useful environment variables:**

| Variable | Effect |
| --- | --- |
| `TESTCASE=name` | Run one test function |
| `MODULE=mod1,mod2` | Run multiple test modules |
| `COCOTB_LOG_LEVEL=DEBUG` | Verbose logging |
| `RANDOM_SEED=n` | Reproduce a randomized failure — **always print the seed on failure** |
| `COCOTB_RESOLVE_X=ZEROS` | ⚠️ Convenient and dangerous; it hides X propagation. Do not use in regression. |

---

## 8. Waveform workflow

```bash
make WAVES=1 TESTCASE=test_book_cross
gtkwave dump.fst tb/waves/book.gtkw &     # .gtkw = saved signal/grouping layout
```

| Practice | Reason |
| --- | --- |
| Use **FST**, not VCD | Often an order of magnitude smaller and faster to load |
| Commit `.gtkw` save files per testbench | Reopening a debug session shouldn't mean re-finding 40 signals |
| `--trace-depth N` | Limits hierarchy depth; a full-design trace of a long run is unusable |
| Gate tracing behind `WAVES=1` | Tracing slows simulation substantially; regression runs without it |
| Trace only the failing window | Use `$dumpon`/`$dumpoff` or cocotb-controlled trace start around the event |

⚠️ Never debug a regression failure by staring at a waveform first. Read the
scoreboard mismatch, find the message index, then trace **that** window. A
full-day pcap replay produces a waveform nobody can open.

---

## 9. `scripts/` layout

```
scripts/
├── env.sh              tool version pinning; sourced by everything; fails on mismatch
├── build.tcl           full non-project flow: read → synth → impl → reports → bitstream
├── synth_only.tcl      synthesis + reports only, for fast RTL iteration
├── impl_from_dcp.tcl   resume implementation from post_synth.dcp (skip re-synthesis)
├── reports.tcl         the standard report set; sourced by build.tcl and impl_from_dcp.tcl
├── seed_sweep.sh       parallel multi-seed / multi-directive sweep + summary CSV
├── parse_timing.py     WNS/TNS/WHS/endpoints from reports or JSON → CI metrics
├── parse_util.py       utilization → CI metrics
├── manifest.py         assemble builds/*/manifest.json (git SHA, tool, seed, hashes)
├── lint.sh             Verilator lint over rtl/, honouring waivers/verilator.vlt
├── program.sh          program a card, then read back and verify the build-ID register
├── fetch_corpus.py     download + SHA256-verify the pcap corpus from the manifest
└── tcl/
    ├── util.tcl        shared procs: QoR extraction, fanout, SLR, pblock queries
    └── waivers.tcl     DRC/methodology waivers, one per line, each with an owner + reason
```

**Rules:** every script is runnable standalone from the repo root, takes explicit
arguments (no hidden environment dependencies beyond `env.sh`), and exits non-zero
on failure. A script that returns 0 after a failed build is worse than no script.

---

## 10. Useful Tcl snippets

```tcl
# ── High-fanout nets, worst first ──────────────────────────────────────
proc ft_high_fanout {{threshold 200}} {
    set nets [get_nets -hierarchical -filter "FLAT_PIN_COUNT > $threshold"]
    foreach n [lsort -decreasing -integer -index 1 \
                 [lmap x $nets {list $x [get_property FLAT_PIN_COUNT $x]}]] {
        puts [format "%-8s %s" [lindex $n 1] [lindex $n 0]]
    }
}

# ── Nets that cross an SLR boundary ────────────────────────────────────
proc ft_slr_crossings {} {
    foreach n [get_nets -hierarchical -filter {TYPE == SIGNAL}] {
        set slrs [get_slrs -quiet -of_objects $n]
        if {[llength $slrs] > 1} { puts "CROSS ([join $slrs ,]) : $n" }
    }
}

# ── Cells inside a pblock, grouped by parent module ────────────────────
proc ft_pblock_contents {pb} {
    foreach c [get_cells -quiet -of_objects [get_pblocks $pb]] {
        puts "[get_property REF_NAME $c]  $c"
    }
    puts "total: [llength [get_cells -quiet -of_objects [get_pblocks $pb]]]"
}

# ── Constraints that match nothing (silent holes in your analysis) ─────
proc ft_dead_constraints {} {
    report_exceptions -ignored
    foreach patt {u_fastpath u_risk u_book} {
        if {[llength [get_cells -quiet -hier -filter "NAME =~ *$patt*"]] == 0} {
            puts "WARNING: no cells match *$patt* — a constraint may be dead"
        }
    }
}

# ── Latency sanity: registers between two points ───────────────────────
proc ft_path_regs {from_pin to_pin} {
    set p [get_timing_paths -from $from_pin -to $to_pin -max_paths 1]
    puts "slack [get_property SLACK $p]  logic_levels [get_property LOGIC_LEVELS $p]"
}
```

> **Verify:** `get_slrs -of_objects`, `FLAT_PIN_COUNT`, and `LOGIC_LEVELS` are
> object properties whose availability depends on the device family (SSI vs.
> monolithic) and the tool version. Test each snippet interactively before wiring
> it into CI.

---

## 11. Quartus equivalents (secondary flow)

| Concept | Vivado / AMD | Quartus / Intel |
| --- | --- | --- |
| Constraint file | `.xdc` (`read_xdc`) | `.sdc` (`set_global_assignment -name SDC_FILE`) |
| Add SystemVerilog source | `read_verilog -sv f.sv` | `set_global_assignment -name SYSTEMVERILOG_FILE f.sv` |
| Synthesis | `synth_design` | `quartus_syn` (Prime Pro) / `quartus_map` (Standard) |
| Place & route | `opt_design`+`place_design`+`route_design` | `quartus_fit` (the Fitter) |
| Timing analysis | `report_timing_summary` | `quartus_sta` + `report_timing` / `create_timing_summary` |
| Bitstream generation | `write_bitstream` → `.bit` | `quartus_asm` → `.sof` / `.pof` |
| Full flow, one command | `vivado -mode batch -source build.tcl` | `quartus_sh --flow compile <project>` |
| Design database snapshot | `.dcp` checkpoint | `.qdb` Quartus database |
| Floorplan region | `create_pblock` | LogicLock region |
| Embedded logic analyzer | ILA (`.ltx`) | Signal Tap Logic Analyzer |
| On-die monitor | SYSMON / XADC | Temperature Sensor / Voltage Sensor IP |
| Block memory | BRAM (18K/36K), URAM (288K) | M20K |
| DSP block | DSP48E2 | Variable-precision DSP block |
| Clock manager | MMCM / PLL | IOPLL / fPLL |
| Multi-die partitioning | SLR (SSI devices) | Sectors / tiles (family-dependent) |
| IP configuration | `.xci` (IP catalog) | `.ip` / `.qsys` (Platform Designer) |
| Run-to-run variation knob | `-directive` (and, version permitting, a seed) | `set_global_assignment -name SEED <n>` — an explicit numeric fitter seed |
| Effort/strategy | Implementation strategy / directives | Optimization Mode: "Aggressive Performance", "High Performance Effort", etc. |
| CDC checking | `report_cdc` | Timing Analyzer CDC reports / Design Assistant |

```bash
# Quartus, whole flow from a project revision
quartus_sh --flow compile top_trading
# Or stage by stage
quartus_syn top_trading -c top_trading
quartus_fit top_trading -c top_trading
quartus_sta top_trading -c top_trading
quartus_asm top_trading -c top_trading
```

> **Verify:** Quartus Prime **Standard** and **Pro** editions differ substantially
> in executable names (`quartus_map` vs `quartus_syn`), supported device families,
> and Tcl API. Confirm against the Quartus Prime Pro Edition user guides for the
> version you install. Agilex requires Prime Pro.

**Portability rule for this project:** keep RTL vendor-neutral and isolate every
vendor primitive (transceivers, memory macros, PLLs, PCIe) behind a wrapper in
`rtl/common/`. The flow scripts diverge; the RTL should not.

---

## Further reading

- [02-latency-reference-numbers.md](02-latency-reference-numbers.md) — what the numbers these tools produce should look like
- [04-checklists.md](04-checklists.md) — pre-synthesis and timing-closure checklists
- [../00-foundations/05-timing-closure.md](../00-foundations/05-timing-closure.md) — how to act on the reports in §3
- [../01-fpga-design/05-verification-and-simulation.md](../01-fpga-design/05-verification-and-simulation.md) — cocotb and Verilator in depth
- [../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md) — the build flow these commands assemble into
- [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md) — what CI runs with these tools
