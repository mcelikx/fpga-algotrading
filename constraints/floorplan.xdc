## =============================================================================
## floorplan.xdc — physical partitioning of the fast path and the slow path
## -----------------------------------------------------------------------------
## Project : FPGA Algorithmic Trading System (Nasdaq Equities)
## Device  : AMD/Xilinx UltraScale+ VU9P-class — THREE SLRs (SLR0/SLR1/SLR2)
## Governs : manuals/00-foundations/05-timing-closure.md §4 Tier 4, §7 item 5
##           manuals/05-optimization/03-resource-power-optimization.md
## Applies to: rtl/fpga_top.sv
##
## ##########################################################################
## ##                                                                      ##
## ##   ⚠️  WHY THIS FILE EXISTS: SLR CROSSINGS COST A FULL CLOCK CYCLE.   ##
## ##                                                                      ##
## ##   A VU9P is not one die. It is three dice (Super Logic Regions)      ##
## ##   stacked on a silicon interposer. A net that crosses from SLR0 to   ##
## ##   SLR1 goes through Super Long Line routing and a dedicated          ##
## ##   register-like crossing resource (Laguna). In practice the tool     ##
## ##   budgets ROUGHLY A FULL CLOCK CYCLE for the crossing — at 156.25    ##
## ##   MHz that is ~6.4 ns of the 6.4 ns you have.                        ##
## ##                                                                      ##
## ##   A single unplanned SLR crossing on the critical path therefore     ##
## ##   consumes the ENTIRE period. It does not degrade timing; it deletes ##
## ##   it. This is the classic late-stage FPGA timing failure: everything ##
## ##   closes at 80% complete, one more module is added, the placer       ##
## ##   spills it into SLR1 because SLR0 is full, and WNS goes from        ##
## ##   +0.2 ns to -5 ns overnight with no RTL change that explains it.    ##
## ##                                                                      ##
## ##   From 05-timing-closure.md §7 item 5:                               ##
## ##     "Floorplan early. Deciding at 80% complete that the fast path    ##
## ##      must be in SLR0 means moving everything."                       ##
## ##                                                                      ##
## ##   And from §4 Tier 4 item 13:                                        ##
## ##     "Constrain the fast path to a region near the transceivers,      ##
## ##      inside one SLR. This is standard practice for a trading         ##
## ##      datapath, not an exotic measure."                               ##
## ##                                                                      ##
## ##   So: THE FAST PATH LIVES IN SLR0. ENTIRELY. NO EXCEPTIONS.          ##
## ##   Every SLR crossing in this design is on the SLOW path, is          ##
## ##   deliberate, and is listed in §4 below.                             ##
## ##                                                                      ##
## ##########################################################################
##
## The tick-to-trade budget in rtl/fpga_top.sv allots 20 fabric cycles / 128 ns
## from MAC RX to MAC TX. There is no line item in that table for "SLR
## crossing", because there is no SLR crossing in it. If one appears, the budget
## is wrong by 6.4 ns per crossing and the header comment must be corrected —
## a silent one is a latency regression nobody attributes.
## =============================================================================

## -----------------------------------------------------------------------------
## 0. Enable / disable switch
## -----------------------------------------------------------------------------
## Floorplanning is a Tier-4 measure. During very early bring-up, before the
## blocks have real area, a pblock sized for the finished design can
## over-constrain the placer and produce worse results than no pblock at all.
##
## scripts/build.tcl sets FLOORPLAN_ENABLE from its --floorplan argument
## (default: on). Leaving it OFF is a decision to be recorded in the build
## manifest, not a default to drift into.
if {![info exists FLOORPLAN_ENABLE]} { set FLOORPLAN_ENABLE 1 }

if {$FLOORPLAN_ENABLE} {

## =============================================================================
## 1. FAST PATH -> SLR0
## =============================================================================
## Contents, in dataflow order (matching the latency table in fpga_top.sv):
##   u_md_eth     x2   10GbE MAC for the A and B market-data feeds
##   u_net_rx          Ethernet/IPv4/UDP strip, MoldUDP64 deframe, A/B arbitrate
##   u_feed            ITCH decode, symbol filter, venue state
##   u_book            order-ID map, price levels, incremental top-of-book
##   u_strategy        parameter read, trigger, position tracking
##   u_risk_gate       ⚠️ mandatory pre-trade risk (CLAUDE.md §5.5)
##   u_order_gw        OUCH encode, SoupBinTCP, TCP framing, credit
##   u_oe_eth          10GbE MAC for the order-entry link
##
## WHY SLR0 specifically: it is the SLR adjacent to the transceiver quads that
## the optics land on. Placing the datapath anywhere else adds an SLR crossing
## at BOTH ends — RX into the fabric and TX back out — costing ~12.8 ns of a
## ~321 ns wire-to-wire budget for nothing.
## ⚠️ This depends on the board's GT quad assignment. See constraints/io.xdc §5:
##    if the optics route to a quad in SLR1, THIS FILE IS WRONG and must move
##    with the pins.
create_pblock pblock_fastpath

add_cells_to_pblock [get_pblocks pblock_fastpath] [get_cells -quiet -hier -filter {
    NAME =~ *u_md_eth*     || NAME =~ *u_net_rx*   || NAME =~ *u_feed*      ||
    NAME =~ *u_book*       || NAME =~ *u_strategy* || NAME =~ *u_risk_gate* ||
    NAME =~ *u_order_gw*   || NAME =~ *u_oe_eth*
}]

resize_pblock [get_pblocks pblock_fastpath] -add {SLR0}

## ⚠️ EXCLUDE_PLACEMENT (rather than a soft pblock): a cell assigned to this
##    pblock may not be placed outside it. WHY hard and not soft: a soft pblock
##    is a suggestion, and the failure mode of a suggestion is a placer that
##    quietly spills the strategy engine into SLR1 under congestion pressure and
##    hands you a -5 ns WNS with no obvious cause. A hard constraint fails
##    LOUDLY at place_design ("unable to place, pblock over-utilized"), which is
##    a fixable error message rather than a mystery.
set_property EXCLUDE_PLACEMENT TRUE [get_pblocks pblock_fastpath]

## Do NOT set CONTAIN_ROUTING on the fast-path pblock. Containing routing as
## well as placement over-constrains the router in the region that is already
## the most congested, and typically costs more in detour delay than the SLR
## discipline saves. Placement containment is the property that matters here.

## =============================================================================
## 2. SLOW PATH -> SLR1
## =============================================================================
## Contents:
##   u_host_ctrl    PCIe wrapper, CSR regfile, DMA log ring, all the CDC
##   u_telemetry    counter bank + latency histogram
##
## WHY move them out of SLR0 at all — is this not just making life harder?
## No: it is the point. These two blocks are LARGE (a PCIe hard block plus its
## bridging logic, plus a wide counter bank and a histogram in BRAM) and they
## are on nobody's critical path. Left unplaced, the tool will happily scatter
## them through SLR0 alongside the book engine, fragmenting the region the fast
## path needs and creating routing congestion exactly where congestion is most
## expensive.
##
## Evicting them buys SLR0 area and routing headroom for the datapath. The cost
## is that every cfg_*/telemetry signal now crosses an SLR — which is FINE, and
## is enumerated in §4, because those signals are already multi-cycle-tolerant
## control-plane signals (see constraints/timing_exceptions.xdc) and already
## cross a clock domain through a handshake.
##
## ⚠️ TODO(verify): confirm the PCIe hard block site for the chosen part is in
##    SLR1. On some VU9P packages PCIe blocks exist in more than one SLR; the
##    pblock must contain the one the design actually uses, or place_design
##    fails. `report_property [get_sites PCIE40E4_X*Y*]` after the first synth.
create_pblock pblock_slowpath

add_cells_to_pblock [get_pblocks pblock_slowpath] [get_cells -quiet -hier -filter {
    NAME =~ *u_host_ctrl* || NAME =~ *u_telemetry*
}]

resize_pblock [get_pblocks pblock_slowpath] -add {SLR1}

## Soft containment here, deliberately: the slow path has slack to spare, and if
## the tool finds a better placement that pokes a few cells across the boundary,
## nothing is harmed. The invariant that matters is "not in SLR0", and a pblock
## on SLR1 achieves that without the placer failing over a marginal fit.
set_property EXCLUDE_PLACEMENT FALSE [get_pblocks pblock_slowpath]

## =============================================================================
## 3. CLOCK AND RESET GENERATION — unconstrained, deliberately
## =============================================================================
## u_clk_rst is not assigned to a pblock. WHY: the MMCM must be placed in a
## clock region compatible with the input clock's pin and with the BUFGs that
## distribute core_clk across SLR0 AND SLR1. Pinning it to one SLR can force the
## clock network into a worse topology than the tool would choose freely, and
## clock-network skew is charged to every path in the design.
##
## Let the clocking be placed by the tool; constrain the LOGIC, not the clocks.

## =============================================================================
## 4. THE SANCTIONED SLR CROSSINGS — the complete list
## =============================================================================
## Any crossing not on this list is a bug. `report_design_analysis -timing`
## after place_design lists the crossings actually present; scripts/build.tcl
## captures it to rpt/design_analysis.rpt for exactly this comparison.
##
##  | Crossing                          | Direction   | Why it is acceptable        |
##  |-----------------------------------|-------------|-----------------------------|
##  | cfg_* config/limit writes         | SLR1 -> SLR0| Handshake CDC, multicycle   |
##  |                                   |             | (timing_exceptions.xdc §1)  |
##  | cfg_kill / cfg_trading_en         | SLR1 -> SLR0| ⚠️ Single-bit, synchronized.|
##  |                                   |             | Budgeted inside             |
##  |                                   |             | KILL_RESP_CYCLES=4. The SLR |
##  |                                   |             | hop is ONE of those four.   |
##  | telemetry counter reads           | SLR0 -> SLR1| Read-only, no latency need  |
##  | kill_active / kill_src to host    | SLR0 -> SLR1| Status, handshake-crossed   |
##  | core_clk distribution             | SLR0 <-> SLR1| Clock network, not a data  |
##  |                                   |             | path. BUFGs handle it.      |
##
## ⚠️ The kill row is the one to watch. fpga_top.sv parameterizes
##    KILL_RESP_CYCLES = 4 and asserts it in SVA. If the SLR crossing plus the
##    3-stage synchronizer plus the gate logic exceeds 4 cycles, the assertion
##    fires in simulation — good — but only if the simulation models the
##    crossing, which it does NOT (simulation is untimed; see
##    manuals/01-fpga-design/05-verification-and-simulation.md §9).
##    Therefore: KILL_RESP_CYCLES is verified in SIMULATION for the logic, and
##    on HARDWARE for the real number. Release gate item 9 in
##    manuals/06-operations/01-build-and-release.md §8.

## =============================================================================
## 5. NESTED PBLOCK — book engine + order-ID map (optional, off by default)
## =============================================================================
## The book update path is the design's most likely critical path
## (05-timing-closure.md §7 item 4). If post-route analysis shows it
## route-dominated (>60% route per §3 of that manual), tightening its placement
## to a couple of clock regions near the order-ID map's BRAMs is the Tier-4 fix.
##
## Left OFF by default: this is an optimization to apply against a MEASUREMENT,
## never speculatively. CLAUDE.md §7: "Do not optimize without a measurement."
## Turn it on by setting BOOK_PBLOCK_ENABLE, and record in the build manifest
## that you did.
if {[info exists BOOK_PBLOCK_ENABLE] && $BOOK_PBLOCK_ENABLE} {
    create_pblock pblock_book
    add_cells_to_pblock [get_pblocks pblock_book] \
        [get_cells -quiet -hier -filter {NAME =~ *u_book*}]
    ## ⚠️ BOARD/PART-SPECIFIC clock-region range — sized from the actual
    ##    post-synth utilization of u_book, not guessed. Replace before use.
    resize_pblock [get_pblocks pblock_book] -add {CLOCKREGION_X0Y0:CLOCKREGION_X3Y2}
    set_property EXCLUDE_PLACEMENT TRUE [get_pblocks pblock_book]
}

} else {
    puts "WARNING: floorplan.xdc — FLOORPLAN_ENABLE=0, pblocks NOT applied."
    puts "WARNING: the fast path may be placed across SLRs. Timing and the"
    puts "WARNING: tick-to-trade latency budget in fpga_top.sv are both"
    puts "WARNING: unreliable in this configuration. Do not release from it."
}

## =============================================================================
## 6. VERIFYING THE FLOORPLAN ACTUALLY HELD
## =============================================================================
## After place_design, scripts/build.tcl captures:
##
##   report_design_analysis -complexity -congestion -timing
##       -> the SLR crossing count per path, and congestion level per region.
##          ⚠️ Congestion level >= 5 in any region is a red flag even if timing
##             passes; it means the next RTL change will not route.
##
##   report_utilization -pblocks [get_pblocks pblock_fastpath]
##       -> ⚠️ if the fast path exceeds ~70% of SLR0's LUTs, the floorplan is
##          about to stop working. The resource budget in fpga_top.sv
##          (LUT < 60k, FF < 90k, BRAM < 300, URAM < 64, DSP < 16) exists to
##          keep this from happening; a build that blows it should be treated
##          as a design regression, not as a floorplan problem.
##
##   report_timing -of_objects [get_timing_paths -slr_crossings]
##       -> any fast-path cell appearing here is a bug against §4's list.
## =============================================================================
