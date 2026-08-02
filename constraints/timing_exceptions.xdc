## =============================================================================
## timing_exceptions.xdc — multicycle paths and false paths
## -----------------------------------------------------------------------------
## Project : FPGA Algorithmic Trading System (Nasdaq Equities)
## Governs : manuals/00-foundations/05-timing-closure.md §5, §6
## Applies to: rtl/fpga_top.sv and the config/parameter fan-out beneath it
##
## ⚠️ READ BEFORE ADDING ANYTHING TO THIS FILE.
##
## A timing exception is a statement to the tool that it may stop checking
## something. Every line in this file therefore REMOVES verification coverage.
## That is sometimes correct and sometimes catastrophic, and the difference is
## entirely in whether the claim is true.
##
## The three rules for this file:
##
##   1. An exception must be justified by a PROPERTY OF THE DESIGN, in a comment,
##      naming the mechanism that makes it safe. "It seemed slow" is not a
##      property. "Written once at configuration time, read thousands of cycles
##      later, protected by a commit bit" is.
##
##   2. `set_multicycle_path -setup N` is ALWAYS paired with `-hold N-1`.
##      See §0 — this is the single most common way to get this file wrong.
##
##   3. `set_false_path` is reserved for signals that are CONSTANT for the life
##      of the bitstream. Not "slow". Not "static after startup". CONSTANT.
##      Anything else uses a multicycle path, which still checks something.
##      CDC data buses NEVER appear here — see constraints/cdc.xdc for why, at
##      length.
##
## Exceptions are audited every build: `report_exceptions -ignored` is captured
## by scripts/build.tcl, and an exception that matches nothing is a build
## warning that must be resolved (it means the design was renamed underneath it,
## and the path it was supposed to relax is now being checked — or, worse, some
## OTHER path is now being relaxed).
## =============================================================================

## =============================================================================
## §0. THE -setup N / -hold N-1 RULE — why the pairing is mandatory
## =============================================================================
##
##   set_multicycle_path -setup N   moves the CAPTURE edge N-1 periods LATER.
##                                  This is what you wanted: more time to settle.
##
##   BUT the hold check is derived from the same capture edge. Moving the setup
##   capture edge late ALSO moves the hold check's reference edge late, so the
##   tool now demands that data launched at edge 0 still be stable at edge N-1.
##   For a signal that changes every cycle when it does change, that is
##   impossible, and the tool reports enormous hold violations.
##
##   `-hold N-1` moves the hold check back to where it belongs — one edge after
##   the launch, which is the real requirement.
##
##   ⚠️ WHAT HAPPENS IF YOU OMIT IT (05-timing-closure.md §6):
##      "A -setup N multicycle must be paired with -hold N-1, or you create hold
##       violations the tools will 'fix' by padding routes."
##
##      The tool does not fail. It inserts delay — routing detours and LUT1
##      buffers — to make the fictional hold requirement pass. You get:
##        * silently worse setup timing on paths sharing that routing,
##        * higher utilization from buffers that do nothing,
##        * a design where the fix for your NEXT timing problem is being eaten
##          by delay you asked for by accident.
##      It is a self-inflicted wound that looks like a congestion problem.
##
##   Mnemonic: -setup N means "N cycles to travel"; -hold N-1 means "and the
##   N-1 intermediate edges do not get to inspect it."
##
## =============================================================================

## -----------------------------------------------------------------------------
## Multicycle depths used below
## -----------------------------------------------------------------------------
## Chosen from how the RTL actually behaves, not from how much slack we want.
##
## CFG_MCP = 4: the double-buffered parameter tables in rtl/risk/risk_params.sv
## and rtl/strategy/param_table.sv are written by the host over PCIe, one 32-bit
## word at a time, at a rate bounded by PCIe transaction latency (hundreds of
## ns). The fast path only reads the *committed* buffer, and the commit bit is
## set at least one full write-burst after the last data word. Four core_clk
## cycles (25.6 ns) is a small fraction of the real settling time and leaves a
## large margin over the actual guarantee.
set CFG_MCP 4

## =============================================================================
## §1. CONFIGURATION AND PARAMETER REGISTERS -> FAST-PATH READERS
## =============================================================================
## What these paths are:
##   The host writes risk limits, strategy parameters, the symbol filter table
##   and OUCH templates through u_host_ctrl. Those values fan out across the SLR
##   boundary (constraints/floorplan.xdc §4) into wide, deep parameter memories
##   and comparator trees in the risk gate and strategy engine.
##
## Why they are genuinely multicycle — the mechanism, not the vibe:
##   1. Double-buffered with a commit bit (trading_pkg.sv §4: "double-buffered
##      with a commit bit so the fast path never reads a half-written record").
##      The fast path reads buffer A while the host writes buffer B. The switch
##      happens on the commit, which is a SEPARATE single-bit path that is NOT
##      relaxed below — it gets full single-cycle analysis, because it is the
##      signal whose timing actually matters.
##   2. The write side is PCIe-rate. Consecutive writes to the same register are
##      hundreds of nanoseconds apart, so there is no back-to-back toggling for
##      a hold check to worry about.
##
## ⚠️ WHAT IS DELIBERATELY NOT RELAXED HERE:
##      cfg_kill        — the kill switch. Bounded by KILL_RESP_CYCLES=4 and
##                        asserted in SVA. Relaxing it would make the assertion
##                        a lie. FULL single-cycle analysis. (CLAUDE.md §5.6)
##      cfg_trading_en  — arming. Fail-closed on reset; must be timed.
##      *_commit        — the commit bits above. If a commit arrives before the
##                        data it commits, the double-buffer scheme is defeated
##                        and the fast path reads a half-written risk limit.
##      cfg_heartbeat   — feeds the watchdog that raises KILL_WATCHDOG.
##
##   Those four are excluded by the -to filters below and are listed again in
##   §4 as a standing checklist.

## ── Risk-limit parameter writes -> risk gate parameter memory ───────────────
## ⚠️ HIGHEST BLAST RADIUS PATH IN THE DESIGN (CLAUDE.md §6). The exception is
##    justified by the commit-bit protocol above and by nothing else.
## TODO(verify): confirm cell names against rtl/risk/risk_params.sv when final.
set_multicycle_path -setup $CFG_MCP \
    -from [get_cells -quiet -hier -filter {NAME =~ *u_host_ctrl/*cfg_risk_data_q_reg[*]}] \
    -to   [get_cells -quiet -hier -filter {NAME =~ *u_risk_gate/u_risk_params/param_q_reg[*]}]
set_multicycle_path -hold [expr {$CFG_MCP - 1}] \
    -from [get_cells -quiet -hier -filter {NAME =~ *u_host_ctrl/*cfg_risk_data_q_reg[*]}] \
    -to   [get_cells -quiet -hier -filter {NAME =~ *u_risk_gate/u_risk_params/param_q_reg[*]}]

## ── Strategy parameter writes -> strategy parameter table ───────────────────
set_multicycle_path -setup $CFG_MCP \
    -from [get_cells -quiet -hier -filter {NAME =~ *u_host_ctrl/*cfg_strat_data_q_reg[*]}] \
    -to   [get_cells -quiet -hier -filter {NAME =~ *u_strategy/u_param_table/param_q_reg[*]}]
set_multicycle_path -hold [expr {$CFG_MCP - 1}] \
    -from [get_cells -quiet -hier -filter {NAME =~ *u_host_ctrl/*cfg_strat_data_q_reg[*]}] \
    -to   [get_cells -quiet -hier -filter {NAME =~ *u_strategy/u_param_table/param_q_reg[*]}]

## ── Symbol-filter table writes -> feed handler locate->active-index map ─────
## Written at start of day from the ITCH Stock Directory; effectively static
## intraday. Still multicycle rather than false path: a symbol CAN be added
## mid-session, and a false path would stop checking a real (if rare) write.
set_multicycle_path -setup $CFG_MCP \
    -from [get_cells -quiet -hier -filter {NAME =~ *u_host_ctrl/*cfg_filter_data_q_reg[*]}] \
    -to   [get_cells -quiet -hier -filter {NAME =~ *u_feed/u_symbol_filter/*_q_reg[*]}]
set_multicycle_path -hold [expr {$CFG_MCP - 1}] \
    -from [get_cells -quiet -hier -filter {NAME =~ *u_host_ctrl/*cfg_filter_data_q_reg[*]}] \
    -to   [get_cells -quiet -hier -filter {NAME =~ *u_feed/u_symbol_filter/*_q_reg[*]}]

## ── OUCH template / session writes -> order gateway template memory ────────
## The OUCH message template (fixed bytes: account, session, firm) is written
## once at session login and spliced with per-order fields at emit time.
## See rtl/order/ouch_encoder.sv and tb/order/test_ouch_encoder.py.
set_multicycle_path -setup $CFG_MCP \
    -from [get_cells -quiet -hier -filter {NAME =~ *u_host_ctrl/*cfg_tmpl_data_q_reg[*]}] \
    -to   [get_cells -quiet -hier -filter {NAME =~ *u_order_gw/*tmpl*_q_reg[*]}]
set_multicycle_path -hold [expr {$CFG_MCP - 1}] \
    -from [get_cells -quiet -hier -filter {NAME =~ *u_host_ctrl/*cfg_tmpl_data_q_reg[*]}] \
    -to   [get_cells -quiet -hier -filter {NAME =~ *u_order_gw/*tmpl*_q_reg[*]}]

## =============================================================================
## §2. TELEMETRY COUNTER READ-BACK -> HOST
## =============================================================================
## Counters are 32/48-bit values sampled by a BAR read. The read is a PCIe
## transaction; nothing downstream reacts within a cycle.
##
## Why multicycle and not false path: CLAUDE.md §5.7 — "Every drop, error, and
## rejected order is counted in a readable register. Silent failure is the worst
## failure mode in this domain." A counter that is not timed is a counter that
## can return garbage, and a garbage counter during an incident investigation is
## worse than no counter because it will be believed.
##
## The read-back path also crosses a clock domain, and the CDC constraints in
## constraints/cdc.xdc §2 apply to it. A multicycle path and a CDC max_delay are
## not alternatives; where both apply, both are present. Vivado applies the
## tighter one, which is what we want.
set_multicycle_path -setup $CFG_MCP \
    -from [get_cells -quiet -hier -filter {NAME =~ *u_telemetry/*cnt_q_reg[*]}] \
    -to   [get_cells -quiet -hier -filter {NAME =~ *u_host_ctrl/*telem_rdata_q_reg[*]}]
set_multicycle_path -hold [expr {$CFG_MCP - 1}] \
    -from [get_cells -quiet -hier -filter {NAME =~ *u_telemetry/*cnt_q_reg[*]}] \
    -to   [get_cells -quiet -hier -filter {NAME =~ *u_host_ctrl/*telem_rdata_q_reg[*]}]

## =============================================================================
## §3. FALSE PATHS — BUILD IDENTITY CONSTANTS ONLY
## =============================================================================
## ⚠️ THIS IS THE COMPLETE LIST. Nothing else in this project gets a false path.
##
## What qualifies: a register whose value is fixed at SYNTHESIS time by a
## `-generic` on synth_design, is never written by any logic, and is read only
## by a host BAR read. It is a constant that happens to be stored in flip-flops
## because it needs an address. There is no launch edge, ever, so there is
## nothing for STA to check.
##
## From rtl/fpga_top.sv: parameters BUILD_ID and GIT_SHA, injected by
## scripts/build.tcl (see manuals/06-operations/01-build-and-release.md §4).
## These feed the build-ID block the host reads at startup and compares before
## it will arm trading.
##
## WHY it is safe here and nowhere else: these bits physically cannot change
## while the bitstream is loaded. Contrast with a "static config register",
## which is only static until someone writes it — that is a MULTICYCLE path
## (§1), not a false path, and confusing the two is how a genuine write path
## stops being checked.
##
## ⚠️ Note that Vivado will very likely CONSTANT-PROPAGATE these away during
##    opt_design, at which point the constraint matches nothing and shows up in
##    `report_exceptions -ignored`. That is expected and benign for THIS
##    constraint specifically — the -quiet keeps it from erroring, and the
##    comment here is the record of why an empty match is acceptable in this one
##    case. Every OTHER empty match is a defect.
set_false_path -quiet \
    -from [get_cells -quiet -hier -filter {NAME =~ *u_host_ctrl/*build_id_q_reg[*]}]

set_false_path -quiet \
    -from [get_cells -quiet -hier -filter {NAME =~ *u_host_ctrl/*git_sha_q_reg[*]}]

## Constraint-file hash and build timestamp registers, same reasoning: injected
## as generics, never written, read-only over BAR0 at a fixed offset that must
## not move between versions (06-operations/01-build-and-release.md §4).
set_false_path -quiet \
    -from [get_cells -quiet -hier -filter {NAME =~ *u_host_ctrl/*constraint_crc_q_reg[*]}]
set_false_path -quiet \
    -from [get_cells -quiet -hier -filter {NAME =~ *u_host_ctrl/*build_ts_q_reg[*]}]
set_false_path -quiet \
    -from [get_cells -quiet -hier -filter {NAME =~ *u_host_ctrl/*build_seed_q_reg[*]}]

## =============================================================================
## §4. THE NOT-EXEMPT LIST — paths that must always be fully timed
## =============================================================================
## Reviewed on every change to this file. If a future edit's wildcard would
## catch any of these, the edit is wrong.
##
##  | Signal / path                       | Why it must be timed                |
##  |-------------------------------------|-------------------------------------|
##  | cfg_kill -> u_risk_gate/u_kill_*    | KILL_RESP_CYCLES=4 is a hard,       |
##  |                                     | asserted, hardware-enforced bound.  |
##  |                                     | CLAUDE.md §5.6.                     |
##  | ext_kill_sync -> u_kill_switch      | Same bound, external path.          |
##  | cfg_trading_en                      | Arming. Fail-closed invariant.      |
##  | cfg_*_commit                        | Defeats double-buffering if late.   |
##  | cfg_heartbeat                       | Feeds the KILL_WATCHDOG timer.      |
##  | credit_avail (gw -> risk)           | Bounds in-flight orders; a stale    |
##  |                                     | value over-permits (RISK_NO_CREDIT).|
##  | book_top -> u_strategy, u_risk_gate | THE fast path. 2-cycle budget.      |
##  | order_req -> u_risk_gate            | THE fast path.                      |
##  | order_out -> u_order_gw             | THE fast path.                      |
##  | fill_* (gw -> strategy, risk)       | Position loop. A late fill is a     |
##  |                                     | position limit computed on stale    |
##  |                                     | data.                               |
##  | Anything inside a pblock_fastpath   | The 20-cycle tick-to-trade budget   |
##  | module, module-internally           | in fpga_top.sv assumes full timing. |
##
## ⚠️ If a fast-path signal ever "needs" a multicycle path to close timing, the
##    answer is not this file. It is a pipeline stage, and it costs a documented
##    cycle in the fpga_top.sv latency table. Buying closure with an exception
##    instead buys it with a lie: the hardware still takes the extra time, the
##    report just stops saying so.
##
## =============================================================================
## §5. AUDIT
## =============================================================================
##   report_exceptions             -> everything declared here, as applied
##   report_exceptions -ignored    -> ⚠️ declared but doing nothing. Every entry
##                                    is a defect except the §3 build-ID ones.
##   report_exceptions -coverage   -> which paths each exception actually covers
##                                    — the check that a wildcard did not catch
##                                    something from §4.
##   report_timing_summary         -> path groups; a group with suspiciously
##                                    large slack often means an over-broad
##                                    exception rather than a fast design.
##
## scripts/build.tcl captures all of these per build. Review them; an exception
## file nobody reads is how an exception file grows.
## =============================================================================
