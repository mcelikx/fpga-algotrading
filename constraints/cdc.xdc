## =============================================================================
## cdc.xdc — clock-domain-crossing constraints
## -----------------------------------------------------------------------------
## Project : FPGA Algorithmic Trading System (Nasdaq Equities)
## Governs : manuals/00-foundations/04-clocking-reset-and-cdc.md §5  (READ IT)
##           manuals/00-foundations/05-timing-closure.md §5
## Applies to: rtl/ctrl/host_ctrl.sv (u_host_ctrl) — the PCIe <-> core_clk
##             control-plane boundary, and the only handshake CDC in the design.
##
## ##########################################################################
## ##                                                                      ##
## ##   P R O J E C T   R U L E  —  N O   E X C E P T I O N S              ##
## ##                                                                      ##
## ##   ⚠️  NEVER `set_false_path` A CDC DATA BUS.  ⚠️                      ##
## ##                                                                      ##
## ##   `set_false_path` tells the router: "I do not care how long this     ##
## ##   takes."  The router believes you.  It will then happily route one   ##
## ##   bit of a 32-bit bus in 0.5 ns and another in 8 ns, because nothing  ##
## ##   in the timing model says otherwise.  Your handshake protocol        ##
## ##   guarantees the SOURCE data is stable — it guarantees nothing about  ##
## ##   when each bit ARRIVES.  The destination register bank then captures ##
## ##   some bits from the new value and some from the old one.            ##
## ##                                                                      ##
## ##   That is TORN DATA.  It is not a theoretical concern:               ##
## ##     - it passes RTL simulation, every time, because simulation has no ##
## ##       notion of per-bit route delay;                                  ##
## ##     - it passes static timing analysis, because you excluded the path ##
## ##       from analysis yourself;                                         ##
## ##     - it appears after a placement change, a tool upgrade, or a       ##
## ##       temperature swing, months later, at a rate of roughly never     ##
## ##       until it is often.                                             ##
## ##                                                                      ##
## ##   In THIS design the buses below carry RISK LIMITS. A torn            ##
## ##   max_order_qty is a max_order_qty that was never configured by       ##
## ##   anybody. See manuals/00-foundations/04-clocking-reset-and-cdc.md §5 ##
## ##   and its §7 table row: "set_false_path on a data bus -> torn data    ##
## ##   under temperature/voltage change".                                  ##
## ##                                                                      ##
## ##   THE CORRECT CONSTRUCT IS ALWAYS:                                    ##
## ##       set_max_delay -datapath_only   (bounds absolute flight time)    ##
## ##     + set_bus_skew                   (bounds bit-to-bit spread)       ##
## ##                                                                      ##
## ##   Both. Not one. -datapath_only bounds each bit individually;         ##
## ##   set_bus_skew bounds them RELATIVE TO EACH OTHER, which is the       ##
## ##   property that actually prevents tearing.                            ##
## ##                                                                      ##
## ##   The ONLY sanctioned false paths in this project are in              ##
## ##   constraints/timing_exceptions.xdc, and they are limited to          ##
## ##   genuinely static build-ID / version constants that are written once ##
## ##   at configuration time and never change again.                       ##
## ##                                                                      ##
## ##########################################################################
##
## What set_clock_groups -asynchronous in clocks.xdc §3 does and does not do:
##   DOES  — stop Vivado analysing pcie_clk <-> core_clk paths against a
##           meaningless synchronous requirement.
##   DOES NOT — bound the flight time or the skew of any individual bus.
## That is the gap this file closes. Grouping the clocks without constraining
## the buses is the same mistake as set_false_path, spelled differently.
## =============================================================================

## -----------------------------------------------------------------------------
## Timing budget for the crossings below
## -----------------------------------------------------------------------------
## Rule of thumb from 04-clocking-reset-and-cdc.md §5 and Xilinx UG903:
##   set_max_delay -datapath_only  <=  min(src_period, dst_period)
##   set_bus_skew                  <=  min(src_period, dst_period)
##
## Here: pcie_clk = 4.000 ns (250 MHz), core_clk = 6.400 ns (156.25 MHz).
## min = 4.000 ns, so both budgets are 4.000 ns in both directions.
##
## WHY min() and not the destination period: the source register may change its
## output one source-clock-period after the handshake req/ack edge that made the
## transfer legal. Budgeting the shorter of the two periods keeps the constraint
## valid regardless of which side is faster, and survives a future clock change
## in either domain without silently becoming wrong.
set CDC_MAX_DELAY_NS 4.000
set CDC_BUS_SKEW_NS  4.000

## =============================================================================
## 1. HOST -> CORE : configuration and risk-parameter handshake buses
## =============================================================================
## Structure (04-clocking-reset-and-cdc.md §3.4):
##   src (pcie_clk): place data on the bus, hold it stable, assert req
##   dst (core_clk): sync req through cdc_sync_bit, capture data, assert ack
##   src:            sync ack, deassert req, only THEN may change the data
##
## The data bus is deliberately NOT synchronized — synchronizing a multi-bit bus
## through parallel 2-FF chains is the classic CDC bug (§2 of the same manual).
## It is held stable by the protocol and constrained here instead.
##
## ⚠️ TODO(verify): cell paths below assume rtl/common/cdc_handshake.sv registers
##    its source-side payload in `src_data_q` and its destination-side capture in
##    `dst_data_q`, and that host_ctrl instances one per config channel named
##    u_cdc_<channel>. Confirm against rtl/ctrl/host_ctrl.sv and
##    rtl/common/cdc_handshake.sv when both are final; if the names differ, fix
##    them HERE, and re-run `report_exceptions -ignored` to prove the constraint
##    still matches objects. A CDC constraint that matches nothing is worse than
##    no constraint, because it looks like protection.

## ── Every handshake instance inside u_host_ctrl, in one pair of constraints ──
## Covers: cfg_filter_*, cfg_risk_*, cfg_strat_*, cfg_tmpl_*, cfg_session_*
##         (address + data + write-strobe payloads), as wired in fpga_top.sv.
##
## WHY one wildcarded pair rather than one pair per channel: a per-channel list
## rots the moment someone adds a channel and forgets the XDC. The wildcard
## covers new channels by construction. The cost is that it also covers channels
## that may not need it — which is harmless, since the budget is generous.
set_max_delay -datapath_only $CDC_MAX_DELAY_NS \
    -from [get_cells -hier -filter {NAME =~ *u_host_ctrl/*u_cdc_*/src_data_q_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *u_host_ctrl/*u_cdc_*/dst_data_q_reg[*]}]

## The one that actually prevents tearing.
## All bits of the bus must land within one destination clock period of each
## other, so the destination's single capture edge sees one coherent value.
set_bus_skew $CDC_BUS_SKEW_NS \
    -from [get_cells -hier -filter {NAME =~ *u_host_ctrl/*u_cdc_*/src_data_q_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *u_host_ctrl/*u_cdc_*/dst_data_q_reg[*]}]

## ── The risk-parameter channel, called out explicitly ────────────────────────
## WHY a second, tighter constraint on a bus already covered above: this is the
## bus that carries sym_risk_t — max_order_qty, max_notional, position limits,
## LULD bands, the collar. CLAUDE.md §6 calls risk-limit changes
## "high-blast-radius". A named constraint means a future edit that breaks the
## wildcard still leaves this one standing, and it shows up by name in
## `report_exceptions` so a reviewer can see it is present.
##
## Tighter budget (2.0 ns) because this crossing is infrequent and short — the
## router has no reason not to meet it, and if it cannot, that is information
## worth having early rather than a torn risk limit later.
set_max_delay -datapath_only 2.000 \
    -from [get_cells -hier -filter {NAME =~ *u_host_ctrl/u_cdc_risk/src_data_q_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *u_host_ctrl/u_cdc_risk/dst_data_q_reg[*]}]

set_bus_skew 2.000 \
    -from [get_cells -hier -filter {NAME =~ *u_host_ctrl/u_cdc_risk/src_data_q_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *u_host_ctrl/u_cdc_risk/dst_data_q_reg[*]}]

## =============================================================================
## 2. CORE -> HOST : telemetry read-back and status
## =============================================================================
## Same handshake, opposite direction: core_clk places counter/telemetry data,
## pcie_clk captures it for a BAR read.
##
## WHY this matters despite being "just telemetry": CLAUDE.md §5.7 —
## "Every drop, error, and rejected order is counted in a readable register."
## A torn counter read makes the counters lie, and a lying counter is worse than
## no counter, because it is trusted. The kill_src_e latch and the per-reason
## risk reject counts come back over this path.
set_max_delay -datapath_only $CDC_MAX_DELAY_NS \
    -from [get_cells -hier -filter {NAME =~ *u_host_ctrl/*u_cdc_*/dst_ret_q_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *u_host_ctrl/*u_cdc_*/src_ret_q_reg[*]}]

set_bus_skew $CDC_BUS_SKEW_NS \
    -from [get_cells -hier -filter {NAME =~ *u_host_ctrl/*u_cdc_*/dst_ret_q_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *u_host_ctrl/*u_cdc_*/src_ret_q_reg[*]}]

## =============================================================================
## 3. SINGLE-BIT LEVEL SYNCHRONIZERS
## =============================================================================
## Single bits through cdc_sync_bit (2 or 3 FF, ASYNC_REG="TRUE") do NOT need a
## set_bus_skew — there is no bus, so there is nothing to skew against. They do
## need their flight time bounded, so that the first synchronizer FF's setup
## window is not eaten by a 9 ns route, which would defeat the whole point of
## the synchronizer.
##
## The crossings, by name, from rtl/fpga_top.sv:
##   cfg_trading_en, cfg_kill, cfg_heartbeat, cfg_credit_return  (pcie -> core)
##   kill_active, kill_src[*]                                    (core -> pcie)
##   ext_kill_sync  <- ext_kill_n, an ASYNC PIN (see constraints/io.xdc §3)
##   link_up[*]                                     (GT refclk domains -> core)
##
## ⚠️ kill_src[2:0] is a 3-BIT BUS, not a single bit. If it is ever crossed
##    through three parallel cdc_sync_bit instances, that is the exact bug in
##    04-clocking-reset-and-cdc.md §2, and the host would occasionally read a
##    kill provenance that never happened — during a post-incident
##    investigation, which is the worst possible moment to be reading fiction.
##    It MUST cross through a handshake or an async FIFO alongside kill_active,
##    so the pair stays coherent (the reconvergence row of §7's table).
##    The constraint below assumes it does; the RTL review must confirm it.
set_max_delay -datapath_only $CDC_MAX_DELAY_NS \
    -from [get_cells -hier -filter {NAME =~ *u_host_ctrl/*u_cdc_bit_*/src_q_reg}] \
    -to   [get_cells -hier -filter {NAME =~ *u_host_ctrl/*u_cdc_bit_*/sync_q_reg[0]}]

## ASYNC_REG placement is set in the RTL by the (* ASYNC_REG = "TRUE" *)
## attribute on the synchronizer chain, not here. It tells the placer to keep
## the chain FFs adjacent, maximizing settling time between stages.
## 04-clocking-reset-and-cdc.md §3.1: "Omitting it is a real bug, not a style
## issue." scripts/lint.sh does not check for it — RTL review must.

## =============================================================================
## 4. ASYNC FIFO CROSSINGS — MAC RX/TX <-> core_clk
## =============================================================================
## NOT constrained here, deliberately.
##
## WHY: a gray-coded async FIFO (rtl/common/async_fifo.sv, or XPM
## xpm_fifo_async) is self-constraining by construction — the pointer crossing
## is gray-coded so a mis-sampled pointer is off by at most one position, never
## incorrectly, and the FIFO memory is written and read in a single domain each.
## The vendor XPM ships its own XDC. Hand-adding constraints on top of an XPM's
## own is how you end up with two constraints that disagree, and the one that
## wins is whichever Vivado read last.
##
## If rtl/common/async_fifo.sv is a hand-written (non-XPM) implementation, its
## gray-pointer crossings need `set_max_delay -datapath_only` on the pointer
## buses. TODO(verify): once that file exists, either confirm it is XPM-based,
## or add the pointer constraints HERE with a comment saying which.
##
## Either way `report_cdc` is the check that catches a missing one — see §6.

## =============================================================================
## 5. VERIFICATION — what proves this file is doing its job
## =============================================================================
## STA does NOT check CDC correctness. By definition these paths are excluded
## from the synchronous analysis, so a clean timing report says nothing at all
## about whether the crossings are safe.
## (manuals/00-foundations/04-clocking-reset-and-cdc.md §6.)
##
## scripts/build.tcl runs, and gates the build on, all of:
##
##   report_cdc -details -file <out>/rpt/cdc.rpt
##       ⚠️ Any CRITICAL severity is a BUILD FAILURE. Catches: missing
##       synchronizers, multi-bit buses through parallel 2-FF chains,
##       reconvergence after separate synchronizers, combinational logic before
##       a synchronizer (glitches get sampled as real transitions).
##
##   report_clock_interaction -file <out>/rpt/clock_interaction.rpt
##       Every clock pair must be "Safely Timed", "Asynchronous Groups", or
##       "Max Delay Datapath Only". ⚠️ "Timed (unsafe)" or "Partial False Path"
##       means a crossing escaped both this file and clocks.xdc.
##
##   report_exceptions -ignored
##       Constraints that match nothing, or are overridden by a broader one.
##       An ignored CDC constraint is an unprotected crossing wearing a costume.
##
## Simulation cannot substitute for any of the above. See
## manuals/01-fpga-design/05-verification-and-simulation.md §9, first row, and
## tb/README.md §"What this whole apparatus cannot catch".
## =============================================================================
