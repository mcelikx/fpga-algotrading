## =============================================================================
## io.xdc — IO timing constraints and pin assignments
## -----------------------------------------------------------------------------
## Project : FPGA Algorithmic Trading System (Nasdaq Equities)
## Governs : manuals/00-foundations/05-timing-closure.md §1, §5
## Applies to: the GPIO-class ports of rtl/fpga_top.sv —
##             led[7:0], ext_kill_n, sys_rst_n
##
## ##########################################################################
## ##  ⚠️  AN UNCONSTRAINED IO PATH IS AN UNCHECKED PATH.                  ##
## ##                                                                      ##
## ##  From 05-timing-closure.md §1: STA checks four path types, and the   ##
## ##  input/output ones are constrained ONLY by set_input_delay /         ##
## ##  set_output_delay. Without them the tool does not analyse the path   ##
## ##  at all — it does not warn that the path is fast, it does not warn   ##
## ##  that the path is slow, it simply does not look.                     ##
## ##                                                                      ##
## ##  "This is how designs pass timing and fail on hardware."             ##
## ##                                                                      ##
## ##  Every port in this design is either constrained below, or is a      ##
## ##  serial GT / PCIe pin whose timing is owned by the hard IP (and      ##
## ##  therefore has no fabric IO path to constrain). There is no third    ##
## ##  category. `check_timing -verbose` lists unconstrained endpoints and ##
## ##  scripts/build.tcl fails the build if the list is non-empty.         ##
## ##########################################################################
##
## Note on the serial pins: md_rx_p/n, md_tx_p/n, oe_rx_p/n, oe_tx_p/n,
## pcie_rx_p/n, pcie_tx_p/n, and the *_gt_refclk_p/n pairs are GT transceiver
## pins. They are placed by GT quad/site selection, not by PACKAGE_PIN, and
## their electrical spec is fixed by the transceiver. They get LOC constraints
## in §5, not IO delays.
## =============================================================================

## -----------------------------------------------------------------------------
## Reference values
## -----------------------------------------------------------------------------
set CORE_CLK_PERIOD_NS 6.400    ;# 156.25 MHz, from clocks.xdc

## Board-level flight time budget for slow GPIO. These are deliberately
## generous: the LEDs and the kill input are not timing-critical in the
## picosecond sense, and over-constraining them costs router effort that belongs
## on the fast path (05-timing-closure.md §6).
##
## ⚠️ BOARD-SPECIFIC — these numbers should come from the board's trace lengths
##    and the driving/receiving device's datasheet, not from this file's
##    defaults. Replace them for the actual card.
set GPIO_IN_MAX_NS   2.000      ;# worst-case external delay before our pin
set GPIO_IN_MIN_NS   0.500      ;# best-case  (hold analysis)
set GPIO_OUT_MAX_NS  2.000      ;# setup requirement of whatever we drive
set GPIO_OUT_MIN_NS  0.500      ;# hold requirement

## =============================================================================
## 1. STATUS LEDs — output paths
## =============================================================================
## led[7:0] is registered off core_clk in fpga_top.sv (kill_active,
## cfg_trading_en, feed_gap, link states, heartbeat blink, power-on).
##
## WHY constrain an LED at all: not because an LED cares about 2 ns, but because
## (a) an unconstrained output is invisible to `check_timing`, so it cannot be
## distinguished from an output someone FORGOT, and (b) these bits are the only
## out-of-band indication that the kill switch has fired — during an incident,
## with the host possibly unresponsive, this is the signal a human reads. It is
## worth having the tool confirm the path exists and closes.
set_output_delay -clock core_clk -max $GPIO_OUT_MAX_NS [get_ports {led[*]}]
set_output_delay -clock core_clk -min $GPIO_OUT_MIN_NS [get_ports {led[*]}]

## =============================================================================
## 2. sys_rst_n — board reset input
## =============================================================================
## Asynchronous, active low, from the board's reset controller.
##
## WHY it still gets an input delay: it is captured by the reset synchronizer in
## rtl/common/clk_rst_gen.sv (reset_sync per 04-clocking-reset-and-cdc.md §4).
## The synchronizer handles the metastability; the constraint bounds the route
## so the first synchronizer FF is not fed through 9 ns of fabric — which would
## stretch the reset assertion across so many cycles that different parts of the
## design would see reset assert on different edges.
set_input_delay -clock sys_clk -max $GPIO_IN_MAX_NS [get_ports sys_rst_n]
set_input_delay -clock sys_clk -min $GPIO_IN_MIN_NS [get_ports sys_rst_n]

## =============================================================================
## 3. ext_kill_n — EXTERNAL HARDWARE KILL INPUT
## =============================================================================
## Front-panel switch or BMC GPIO. Active low, fully asynchronous to every clock
## in the design. Crosses into core_clk through the 3-stage cdc_sync_bit
## `u_ext_kill_cdc` instanced in fpga_top.sv, and drives kill_src_e KILL_GPIO.
##
## ⚠️ THIS IS A SAFETY INPUT. CLAUDE.md §5.6: "The kill switch is
##    hardware-enforced. A single register write must stop all outbound order
##    flow within a bounded, documented number of cycles." The external pin is
##    the version of that which works when the host is wedged and the register
##    write cannot happen. It is the last line of defence and it must be timed.
##
## Constraining an asynchronous input, correctly:
##   A virtual clock is used as the reference. WHY: there is no real clock that
##   launches this signal — a human presses a switch. Referencing it to core_clk
##   would be a lie about a phase relationship that does not exist. A virtual
##   clock lets us declare "there is an external delay, and here is its bound"
##   without inventing a launch edge.
create_clock -name virt_async_in -period $CORE_CLK_PERIOD_NS

set_input_delay -clock virt_async_in -max $GPIO_IN_MAX_NS [get_ports ext_kill_n]
set_input_delay -clock virt_async_in -min $GPIO_IN_MIN_NS [get_ports ext_kill_n]

## The virtual clock is asynchronous to everything, so it is grouped out of the
## real domains — otherwise Vivado analyses port->synchronizer paths against a
## fictional synchronous requirement and reports a violation that cannot be
## fixed because it is not real.
set_clock_groups -asynchronous \
    -group [get_clocks virt_async_in] \
    -group [get_clocks -include_generated_clocks core_clk] \
    -group [get_clocks -include_generated_clocks sys_clk]

## Having declared it asynchronous, we must still BOUND THE ROUTE to the first
## synchronizer stage — for exactly the reason spelled out at length in
## constraints/cdc.xdc: "asynchronous" must never be allowed to degrade into
## "unbounded". A 12 ns route into a synchronizer is a synchronizer that is
## sampling a signal which has been in flight for two clock periods.
##
## set_max_delay (not -datapath_only, because the startpoint is a port with no
## launching clock edge to subtract) pins the port-to-first-FF flight time.
## TODO(verify): confirm the synchronizer's internal register name once
##   rtl/common/cdc_sync_bit.sv is final. The manual's reference implementation
##   names the chain `sync_q`, so the first stage is sync_q_reg[0].
set_max_delay 4.000 \
    -from [get_ports ext_kill_n] \
    -to   [get_cells -hier -filter {NAME =~ *u_ext_kill_cdc/sync_q_reg[0]}]

## =============================================================================
## 4. IO STANDARDS
## =============================================================================
## ⚠️ BOARD-SPECIFIC — replace for the actual card.
## The IOSTANDARD must match the bank's VCCO rail. A mismatch is a DRC error at
## best and a damaged bank at worst. Take these from the board schematic, not
## from a reference design for a different card.
set_property IOSTANDARD LVCMOS18 [get_ports {led[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS18 [get_ports ext_kill_n]
set_property IOSTANDARD LVDS     [get_ports {sys_clk_p sys_clk_n}]

## Drive strength and slew: low and slow for the LEDs. WHY: there is no reason
## for a status LED to have fast edges, and fast edges on a long board trace are
## a needless source of SSO noise into neighbouring pins in the same bank.
set_property DRIVE 4    [get_ports {led[*]}]
set_property SLEW  SLOW [get_ports {led[*]}]

## ext_kill_n: pull-up so an unconnected or broken kill line reads as "not
## killed"... NO. Deliberately the opposite of the usual reflex:
## ⚠️ FAIL-CLOSED. ext_kill_n is ACTIVE LOW, so a floating pin must read LOW
##    (= kill asserted), not HIGH. A severed kill cable must stop trading, not
##    silently disable the emergency stop. This mirrors CLAUDE.md §5 fail-closed
##    reset behaviour (limits zero, trading disabled).
## TODO(verify): confirm against the board — if the front-panel circuit already
##    provides a defined pull, an internal one that fights it is a mistake.
##    Whatever is chosen, the bench test is: unplug the cable, confirm trading
##    stops. That test is a release gate (06-operations/01-build-and-release.md
##    §8 item 9).
set_property PULLDOWN true [get_ports ext_kill_n]

## =============================================================================
## 5. PIN ASSIGNMENTS
## =============================================================================
## ############################################################################
## ##  BOARD-SPECIFIC — replace for the actual card.                         ##
## ##                                                                        ##
## ##  Every PACKAGE_PIN below is a PLACEHOLDER taken from a generic         ##
## ##  VU9P-class layout. They are here so that the design elaborates,       ##
## ##  places, and produces meaningful timing/utilization numbers during     ##
## ##  bring-up — NOT because they are correct for any real board.           ##
## ##                                                                        ##
## ##  ⚠️ DO NOT GENERATE A BITSTREAM FOR REAL HARDWARE WITH THESE VALUES.   ##
## ##     Wrong pin assignments can drive a signal into a supply rail.       ##
## ##     scripts/build.tcl checks for the marker property set at the end of ##
## ##     this section and refuses to write a bitstream while it is present. ##
## ##                                                                        ##
## ##  Replacement procedure:                                                ##
## ##    1. Take pin numbers from the board's schematic / pinout XLS.        ##
## ##    2. Take GT quad + lane assignments from the board's reference       ##
## ##       design; a GT lane cannot be arbitrarily reassigned.              ##
## ##    3. Confirm bank VCCO against the IOSTANDARDs in §4.                 ##
## ##    4. Delete the BOARD_PINS_ARE_PLACEHOLDERS marker below.             ##
## ############################################################################

## ── Board reference clock, 100 MHz LVDS ─────────────────────────────────────
set_property PACKAGE_PIN AY23 [get_ports sys_clk_p]     ;# BOARD-SPECIFIC
set_property PACKAGE_PIN AY24 [get_ports sys_clk_n]     ;# BOARD-SPECIFIC

## ── Board reset, active low ─────────────────────────────────────────────────
set_property PACKAGE_PIN BC23 [get_ports sys_rst_n]     ;# BOARD-SPECIFIC

## ── External kill input ─────────────────────────────────────────────────────
## Put this on a pin that is physically reachable and clearly labelled on the
## bracket. During an incident someone will be looking for it in a hurry.
set_property PACKAGE_PIN BB21 [get_ports ext_kill_n]    ;# BOARD-SPECIFIC

## ── Status LEDs ─────────────────────────────────────────────────────────────
set_property PACKAGE_PIN BA20 [get_ports {led[0]}]      ;# BOARD-SPECIFIC power-on
set_property PACKAGE_PIN BB20 [get_ports {led[1]}]      ;# BOARD-SPECIFIC heartbeat
set_property PACKAGE_PIN BA22 [get_ports {led[2]}]      ;# BOARD-SPECIFIC md link A
set_property PACKAGE_PIN BB22 [get_ports {led[3]}]      ;# BOARD-SPECIFIC md link B
set_property PACKAGE_PIN BC21 [get_ports {led[4]}]      ;# BOARD-SPECIFIC oe link
set_property PACKAGE_PIN BD21 [get_ports {led[5]}]      ;# BOARD-SPECIFIC feed gap
set_property PACKAGE_PIN BD22 [get_ports {led[6]}]      ;# BOARD-SPECIFIC trading en
set_property PACKAGE_PIN BE22 [get_ports {led[7]}]      ;# BOARD-SPECIFIC KILL ACTIVE

## ── GT reference clocks and lanes ───────────────────────────────────────────
## GT refclks must land on the dedicated MGTREFCLK pins of the quad that serves
## the lanes; they cannot be moved to general IO.
##
## ⚠️ FLOORPLAN COUPLING: the quad chosen here determines which SLR the fast
##    path must live in. constraints/floorplan.xdc pins the fast path to SLR0
##    on the assumption that both 10GbE quads are SLR0-adjacent. If the board
##    routes the market-data optics to a quad in SLR1 or SLR2, the floorplan is
##    WRONG and must change with these pins — not later, when timing fails.
set_property PACKAGE_PIN AT38 [get_ports md_gt_refclk_p]  ;# BOARD-SPECIFIC (MGTREFCLK)
set_property PACKAGE_PIN AT39 [get_ports md_gt_refclk_n]  ;# BOARD-SPECIFIC
set_property PACKAGE_PIN AR36 [get_ports oe_gt_refclk_p]  ;# BOARD-SPECIFIC (MGTREFCLK)
set_property PACKAGE_PIN AR37 [get_ports oe_gt_refclk_n]  ;# BOARD-SPECIFIC

## Serial lanes: assigned by GT site (LOC on the GT cell), not by PACKAGE_PIN on
## the port. Left to the GT IP's own XDC.
## TODO(verify): once ip/gtwizard_*/…​.xci is checked in, record here which quad
##   and which lanes each of md_rx[1:0] / oe_rx map to, so the floorplan comment
##   above can be checked without opening the IP.

## ── PCIe ────────────────────────────────────────────────────────────────────
## PCIe lanes, refclk and PERST are fixed by the card edge connector and the
## chosen PCIe hard block. Owned entirely by the PCIe IP's generated XDC.
## Nothing to assign here — noted so the absence is obviously deliberate rather
## than an omission.

## ── Placeholder marker — DELETE when real pins are in ───────────────────────
## scripts/build.tcl greps this file for the string below and refuses
## `write_bitstream` while it is present. Simulation, synthesis and
## implementation all still run, so bring-up numbers are available immediately;
## only the artifact that could reach hardware is blocked.
set_property BOARD_PINS_ARE_PLACEHOLDERS TRUE [current_design]

## =============================================================================
## 6. WHAT IS DELIBERATELY NOT HERE
## =============================================================================
##   - Nothing is `set_false_path`-ed. Not one port. If a path genuinely does
##     not need checking, it is asynchronous and gets the §3 treatment (virtual
##     clock + clock group + bounded max_delay), which documents WHY it is
##     unchecked. `set_false_path` on an IO documents nothing.
##   - No `set_max_delay` pad-to-pad constraints: this design has no purely
##     combinational port-to-port path, and if one ever appears it is a bug to
##     be removed, not a path to be constrained.
##   - No `set_input_delay` on the GT serial pins: they have no fabric IO path.
##     Their budget is inside the transceiver and is fixed by the hard IP —
##     ~90 ns each way, per the latency table in rtl/fpga_top.sv.
## =============================================================================
