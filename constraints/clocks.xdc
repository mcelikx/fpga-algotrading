## =============================================================================
## clocks.xdc — primary clocks, generated clocks, and asynchronous clock groups
## -----------------------------------------------------------------------------
## Project : FPGA Algorithmic Trading System (Nasdaq Equities)
## Device  : AMD/Xilinx UltraScale+ (VU9P-class), Vivado non-project flow
## Governs : manuals/00-foundations/05-timing-closure.md §5
##           manuals/00-foundations/04-clocking-reset-and-cdc.md §1, §5
## Applies to: rtl/fpga_top.sv
##
## PROJECT RULE (04-clocking-reset-and-cdc.md §1 rule 3):
##   "Every clock is declared in the XDC with create_clock or
##    create_generated_clock. An underived clock is an unconstrained clock, and
##    an unconstrained clock is an unverified design."
##
## ⚠️ scripts/build.tcl FAILS THE BUILD if `report_clocks` / `check_timing`
##    reports an unconstrained clock. That check exists because the failure mode
##    is silent: an unconstrained clock's paths are simply not analysed, the
##    design "closes timing", and it fails on hardware.
##
## Constraint hygiene (05-timing-closure.md §5):
##   - One file per concern. Clocks live here and nowhere else.
##   - Every constraint below states WHY, not just WHAT.
##   - Every constraint must match at least one object. build.tcl runs
##     `report_exceptions -ignored` and treats an empty match as an error.
## =============================================================================

## -----------------------------------------------------------------------------
## Board / part parameters used below
## -----------------------------------------------------------------------------
## Kept as Tcl variables so a board change is a two-line edit, not a hunt.
## ⚠️ BOARD-SPECIFIC — confirm every one of these against the card's schematic
##    and its reference design before the first hardware build.
set SYS_CLK_PERIOD_NS   10.000   ;# 100 MHz board reference oscillator
set GT_REFCLK_PERIOD_NS  6.400   ;# 156.25 MHz — the standard 10GbE GT refclk
set PCIE_REFCLK_NS      10.000   ;# 100 MHz PCIe reference (PCIe base spec)
set CORE_CLK_PERIOD_NS   6.400   ;# 156.25 MHz — THE datapath clock
set PCIE_CLK_PERIOD_NS   4.000   ;# 250 MHz PCIe Gen3 user clock

## =============================================================================
## 1. PRIMARY CLOCKS — create_clock on the physical pins
## =============================================================================
## These are the only clocks in the design that arrive from outside the FPGA.
## Everything else is derived from one of them and MUST be a generated clock.

## ── Board reference oscillator, 100 MHz differential ────────────────────────
## WHY: sys_clk_p/n feeds the MMCM inside u_clk_rst (rtl/common/clk_rst_gen.sv)
## that synthesizes core_clk. Without this create_clock the MMCM has no input
## clock, so *nothing downstream of it is timed at all*.
## Only the _p leg is constrained: Vivado derives the _n leg through IBUFDS.
create_clock -name sys_clk -period $SYS_CLK_PERIOD_NS [get_ports sys_clk_p]

## ── Market-data GT reference clock, 156.25 MHz ──────────────────────────────
## WHY: drives the GTY quad serving the two 10GbE market-data lanes (A and B
## feeds) in u_md_eth. 156.25 MHz x 64 = 10 Gbps line rate, which is why this
## particular frequency is the 10GbE convention.
## ⚠️ This is a REFERENCE clock, not a data clock. The RX data clock is
##    RECOVERED from the incoming serial stream (see §2) and is plesiochronous
##    with this one — same nominal frequency, different actual frequency by up
##    to +/-100 ppm. They are NOT the same clock and must never be treated as
##    synchronous. That is what §3 is for.
create_clock -name md_gt_refclk -period $GT_REFCLK_PERIOD_NS [get_ports md_gt_refclk_p]

## ── Order-entry GT reference clock, 156.25 MHz ──────────────────────────────
## WHY: separate quad for the order-entry link (u_oe_eth). Kept on its own
## refclk so a market-data link event cannot disturb the order-entry link — the
## order-entry session is the one whose loss is a trading incident (kill_src_e
## KILL_LINK_DOWN in rtl/pkg/trading_pkg.sv).
create_clock -name oe_gt_refclk -period $GT_REFCLK_PERIOD_NS [get_ports oe_gt_refclk_p]

## ── PCIe reference clock, 100 MHz ───────────────────────────────────────────
## WHY: PCIe Gen3 x16 host interface (u_host_ctrl). This is the slow path; it
## carries risk limits, strategy parameters, telemetry read-back and the kill
## register. Nothing latency-critical crosses it, but a missing constraint here
## means the control plane is unverified — and the control plane is what writes
## the risk limits.
create_clock -name pcie_refclk -period $PCIE_REFCLK_NS [get_ports pcie_refclk_p]

## =============================================================================
## 2. GENERATED CLOCKS
## =============================================================================

## ── core_clk: 156.25 MHz, THE datapath clock ────────────────────────────────
## Feed decode -> book -> strategy -> risk -> order encode all run here, in ONE
## clock domain (CLAUDE.md §2, fpga_top.sv hard rule 5). 6.400 ns period.
##
## WHY create_generated_clock and not create_clock:
##   core_clk is not a pin; it is the MMCM output inside u_clk_rst. Declaring it
##   with create_clock would DETACH it from sys_clk, and the two would then be
##   analysed as unrelated — the tool would stop checking the (real) synchronous
##   relationship and would silently accept phase relationships that cannot
##   happen. A derived clock must be declared as derived.
##
##   100 MHz * 25 / 16 = 156.25 MHz.  (MMCM: CLKFBOUT_MULT_F = 12.5 -> VCO
##   1250 MHz; CLKOUT0_DIVIDE_F = 8 -> 156.25 MHz. Net 25/16.)
##
## ⚠️ Vivado AUTO-DERIVES clocks on MMCM/PLL outputs from the .xci/IP
##    parameters. This explicit constraint is here because auto-derivation is
##    invisible in review and changes silently when the MMCM is re-parameterized.
##    An explicit generated clock that DISAGREES with the MMCM settings is a
##    build error (Vivado reports it); an implicit one that quietly changes to
##    140 MHz is a shipped bug. We take the loud failure.
##
## TODO(verify): confirm the MMCM instance path and its CLKIN1/CLKOUT0 pin names
##    against rtl/common/clk_rst_gen.sv once that module is final. The names
##    below assume a single MMCME4_ADV instanced as u_mmcm inside u_clk_rst.
create_generated_clock -name core_clk \
    -source [get_pins u_clk_rst/u_mmcm/CLKIN1] \
    -multiply_by 25 -divide_by 16 \
    [get_pins u_clk_rst/u_mmcm/CLKOUT0]

## ALTERNATIVE (uncomment, and comment out the MMCM version above, if the board
## brings 156.25 MHz straight in and core_clk is a BUFG_GT off the GT refclk —
## which is the LOWER-JITTER and therefore PREFERRED topology for a trading
## card, because MMCM jitter eats directly into the 6.4 ns budget):
#
# create_generated_clock -name core_clk \
#     -source [get_pins u_clk_rst/u_bufg_core/I] -divide_by 1 \
#     [get_pins u_clk_rst/u_bufg_core/O]

## ── pcie_clk: 250 MHz PCIe Gen3 user clock ──────────────────────────────────
## WHY: the PCIe hard block divides the recovered 8 GT/s link clock down to a
## 250 MHz user clock. Derived from pcie_refclk through the hard IP, so it is a
## generated clock, not a primary one.
## ⚠️ The PCIe IP's own generated .xdc normally creates this. Declaring it twice
##    is an error. TODO(verify): once ip/pcie4_uscale_plus/*.xci is checked in,
##    delete this block if the IP XDC already provides it — and record which
##    file owns it in a comment, so the next person does not re-add it.
create_generated_clock -name pcie_clk \
    -source [get_pins u_host_ctrl/u_pcie/u_hard_ip/CLKIN] \
    -multiply_by 5 -divide_by 2 \
    [get_pins u_host_ctrl/u_pcie/u_hard_ip/user_clk]

## ── Recovered RX clocks (market data A/B, order entry) ──────────────────────
## WHY: each GT recovers a clock from its incoming serial stream (CDR). These
## are the clocks the MAC RX logic runs in before the async FIFO hands data to
## core_clk. They are auto-derived by Vivado on the GT's TXOUTCLK/RXOUTCLK pins
## when the GT IP is present, which is why they are NOT created here — creating
## them by hand would produce duplicate-clock errors against the GT IP's XDC.
##
## They ARE, however, named in the asynchronous clock groups in §3. The
## `-include_generated_clocks` there catches whatever the IP named them.
##
## ⚠️ Plesiochronous, not synchronous: the far-end transmitter's oscillator is
##    not ours. Up to +/-200 ppm total offset. This is precisely why the MAC RX
##    boundary is one of the three sanctioned CDC points in this design.
## TODO(verify): after the first synth run, list the actual clock names with
##    `report_clocks` and pin the group membership below to those names rather
##    than to a wildcard, so a renamed IP clock fails loudly instead of silently
##    dropping out of the group.

## =============================================================================
## 3. ASYNCHRONOUS CLOCK GROUPS
## =============================================================================
## WHY: these domains have no fixed phase relationship. Left ungrouped, Vivado
## analyses paths between them against a meaningless (and often impossibly
## short) requirement derived from the least-common-multiple of the two periods.
## The result is thousands of phantom violations that hide the real ones.
##
## ⚠️ set_clock_groups -asynchronous IS a false path between the groups. That is
##    correct and safe HERE — at the *clock* level, where every crossing goes
##    through a sanctioned CDC primitive (async FIFO, 2-FF sync, handshake) and
##    the crossing is therefore protocol-safe by construction.
##    It is NOT a licence to skip the per-bus constraints. The handshake DATA
##    buses still need `set_max_delay -datapath_only` + `set_bus_skew` to bound
##    per-bit skew — see constraints/cdc.xdc, which explains why at length.
##
## -include_generated_clocks: every derived clock inherits its parent's group.
## Omitting it is a classic near-miss — the parent is grouped, the MMCM output
## is not, and the real datapath crossing stays analysed as synchronous.

set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks core_clk] \
    -group [get_clocks -include_generated_clocks pcie_clk] \
    -group [get_clocks -include_generated_clocks pcie_refclk]

## Market-data recovered RX clocks vs. the core domain.
## Crossing point: the async FIFO inside rtl/eth/mac_rx.sv. Two independent
## lanes (A feed, B feed) with two independent CDRs — they are asynchronous to
## each other as well as to core_clk, hence separate groups.
## TODO(verify): replace the wildcards with the GT IP's real clock names after
##    the first `report_clocks`. A wildcard that matches nothing silently
##    removes the group; build.tcl's empty-match check is the backstop.
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks core_clk] \
    -group [get_clocks -include_generated_clocks -quiet {*md_rx_clk*  *md*RXOUTCLK*}] \
    -group [get_clocks -include_generated_clocks -quiet {*oe_rx_clk*  *oe*RXOUTCLK*}]

## GT reference clocks vs. core_clk.
## WHY separately: the refclk feeds the GT's PLL, and a stray path from a
## refclk-domain status register into core_clk (link_up, for instance) would
## otherwise be analysed synchronously. link_up crosses through cdc_sync_bit;
## the group makes that explicit.
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks core_clk] \
    -group [get_clocks -include_generated_clocks md_gt_refclk] \
    -group [get_clocks -include_generated_clocks oe_gt_refclk]

## sys_clk vs. everything derived from the other references.
## WHY: sys_clk is core_clk's PARENT, so those two are synchronous and must NOT
## be grouped apart — doing so would stop the tool checking the MMCM's own
## input-to-output path. Only the unrelated references are grouped against it.
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks sys_clk] \
    -group [get_clocks -include_generated_clocks pcie_refclk] \
    -group [get_clocks -include_generated_clocks md_gt_refclk] \
    -group [get_clocks -include_generated_clocks oe_gt_refclk]

## =============================================================================
## 4. CLOCK UNCERTAINTY
## =============================================================================
## WHY: Vivado already models jitter from the MMCM and the input clock's
## declared jitter. Adding extra uncertainty is over-constraining by another
## name, and 05-timing-closure.md §6 is explicit about the cost: longer runtime,
## worse global trade-offs, a harder-to-route design that may be SLOWER on the
## paths you actually care about.
##
## So: no blanket `set_clock_uncertainty`. If the board's oscillator is worse
## than its datasheet default, model it at the source with `set_input_jitter`
## on sys_clk — which is honest about *where* the uncertainty comes from —
## rather than by padding every path in the design.
#
# set_input_jitter sys_clk 0.050   ;# TODO(verify) against the oscillator datasheet

## =============================================================================
## 5. SANITY CHECKS — run by scripts/build.tcl, listed here for the reader
## =============================================================================
##   check_timing -verbose                 -> unconstrained endpoints/clocks
##   report_clocks                         -> every clock, its period and source
##   report_clock_interaction              -> ⚠️ every cell must be "Safely
##                                            Timed", "Timed (unsafe)" only
##                                            where cdc.xdc explains it
##   report_cdc                            -> structural CDC check (STA does not
##                                            check CDC correctness — see
##                                            04-clocking-reset-and-cdc.md §6)
##   report_exceptions -ignored            -> constraints doing nothing
## =============================================================================
