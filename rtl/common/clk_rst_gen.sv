// =============================================================================
// clk_rst_gen.sv — Clock generation and per-domain reset synchronization
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Device  : AMD/Xilinx UltraScale+ (MMCME4_BASE)
// Governs : manuals/00-foundations/04-clocking-reset-and-cdc.md §1, §4
//           manuals/00-foundations/03-hdl-and-rtl-coding.md §6
//
// PURPOSE
//   Produce THE datapath clock — `core_clk` at 156.25 MHz — from the 100 MHz
//   board reference, and hand every clock domain a properly synchronized,
//   active-high, synchronous reset. Ports are the contract in fpga_top.sv.
//
//   Clock plan (manual §1). Frequencies are carried as integer kHz/ps because
//   trading_pkg bans `real` from packages; the only `real` values in this file
//   are the vendor MMCM primitive parameters, which have no integer form:
//     sys_clk_p/n  100.000 MHz  differential board reference
//        -> IBUFDS -> MMCME4_BASE, VCO 1250 MHz (DIVCLK=1, MULT=12.5)
//           CLKOUT0 /8   -> core_clk 156.250 MHz  (10 Gb/s / 64 bit) EXACT
//           CLKOUT1 /5   -> pcie_clk 250.000 MHz                     EXACT
//   Both divisors are integers off a legal VCO frequency, so neither clock has
//   any frequency error. That matters: a core clock derived with a fractional
//   divider carries extra jitter, and jitter eats directly into the tick-to-
//   trade timing margin.
//
// LATENCY / RESOURCE
//   Not on the datapath. 1 MMCM, 1 IBUFDS, 2 BUFG, ~8 FF (the reset chains).
//   MMCM lock time is device- and configuration-dependent, of the order of
//   100 us. Nothing may leave reset before `locked`.
//
// -----------------------------------------------------------------------------
// ⚠️  SIMULATION USES A BEHAVIOURAL CLOCK. ONLY HARDWARE PROVES THE REAL ONE.
//   With `SIMULATION` defined, this module generates `core_clk` and `pcie_clk`
//   from `initial`/`forever` delay loops. That model has: no jitter, no phase
//   noise, no lock time, exact frequency, instant startup, and no relationship
//   whatsoever to the physical MMCM. It exists so Verilator and cocotb do not
//   need vendor primitives (CLAUDE.md §2 keeps the RTL vendor-neutral).
//
//   Consequences you must not forget:
//     * A design that passes simulation has proved NOTHING about clocking. The
//       MMCM configuration, the VCO range, the lock behaviour and the reset
//       release ordering are only proved by a real bitstream on real silicon.
//     * `locked` is forced high after a token delay in simulation. Any bug
//       involving logic running before lock is invisible in simulation.
//     * Report clocking results per CLAUDE.md §4: say "simulated" or
//       "measured, N=..." — they are not interchangeable.
//     * The MMCM branch must be compiled by Vivado at least once per change to
//       this file, because nothing in the simulation flow ever elaborates it.
//
// ⚠️  `pcie_clk` HERE IS A PLACEHOLDER AND MUST BE REVIEWED BEFORE ANY REAL
//   BUILD. On a real UltraScale+ design the PCIe user clock is an OUTPUT of the
//   PCIe hard block (which `host_ctrl` instantiates from the same
//   `pcie_refclk_p/n`), not something an MMCM should manufacture. Two different
//   250 MHz clocks driving the same logic is a bug. The port contract in
//   fpga_top.sv asks for `pcie_clk` from this module, so it is provided, but the
//   integration step is: delete the CLKOUT1 branch, take `pcie_clk` from the
//   PCIe IP, and reduce this module's PCIe role to the `reset_sync` below.
//   FLAGGED FOR REVIEW — do not build to hardware without resolving it.
//
// ⚠️  RESET POLICY (manual §4, CLAUDE.md §5.4). The asynchronous reset root is
//   (board reset) OR (MMCM not locked). Each domain gets its own `reset_sync`,
//   so each domain releases synchronously to its own clock. Downstream, EVERY
//   use of reset is synchronous. `core_rst` releases last, after `pcie_rst`,
//   so the control plane is alive before the datapath starts.
// =============================================================================
`default_nettype none

module clk_rst_gen
    import trading_pkg::*;
#(
    // Board reference frequency, in kHz. Integer, per trading_pkg: `real` is
    // banned in packages and kept out of RTL wherever it is avoidable
    // (CLAUDE.md §5.3). Change here, not in the MMCM literals below — and if you
    // change it, recompute the MMCM constants and say so.
    parameter int unsigned SYS_CLK_KHZ    = 100_000,
    // Extra cycles to hold each domain in reset after its synchronizer releases.
    // core_rst is held longer so the control plane comes up first.
    parameter int unsigned CORE_RST_HOLD  = 16,
    parameter int unsigned PCIE_RST_HOLD  = 4
) (
    // ── Board reference ──────────────────────────────────────────────────────
    input  var logic sys_clk_p,       // 100 MHz differential board reference
    input  var logic sys_clk_n,
    input  var logic sys_rst_n,       // active-LOW board reset, asynchronous

    // ── Core datapath domain ─────────────────────────────────────────────────
    output var logic core_clk,        // 156.25 MHz — THE datapath clock
    output var logic core_rst,        // synchronous, active high, core_clk

    // ── PCIe / control-plane domain ──────────────────────────────────────────
    input  var logic pcie_refclk_p,
    input  var logic pcie_refclk_n,
    input  var logic pcie_rst_n,      // PERST#, active low, asynchronous
    output var logic pcie_clk,        // 250 MHz
    output var logic pcie_rst         // synchronous, active high, pcie_clk
);

    // MMCM constants for a 100 MHz reference. VCO = 100 * 12.5 / 1 = 1250 MHz,
    // inside the UltraScale+ MMCM VCO range (800-1600 MHz for -2 speed grade).
    //
    // These four are `real` because the vendor primitive declares them `real`;
    // there is no integer form of CLKFBOUT_MULT_F. That is precisely why they
    // live HERE, in the vendor isolation wrapper, and not in a package
    // (trading_pkg §1, CLAUDE.md §2). No `real` crosses this module boundary.
    localparam real CLKIN_PERIOD_NS  = 10.000;     // 100 MHz
    localparam real CLKFB_MULT_F     = 12.500;     // -> VCO 1250 MHz
    localparam int  DIVCLK_DIVIDE    = 1;
    localparam real CLKOUT0_DIVIDE_F = 8.000;      // 1250 / 8 = 156.250 MHz
    localparam int  CLKOUT1_DIVIDE   = 5;          // 1250 / 5 = 250.000 MHz

    // The same arithmetic in integer kHz, for the elaboration check below.
    // All constant-folded; no hardware divider (CLAUDE.md §5.3).
    localparam int unsigned VCO_KHZ      = (SYS_CLK_KHZ * 125) / (10 * DIVCLK_DIVIDE);
    localparam int unsigned CORE_GEN_KHZ = (VCO_KHZ * 10) / 80;          // /8.0
    localparam int unsigned PCIE_GEN_KHZ = VCO_KHZ / CLKOUT1_DIVIDE;

    // Half periods for the behavioural simulation model, in integer picoseconds.
    // Sourced from trading_pkg so the model can never drift from the contract.
    localparam int unsigned CORE_HALF_PS = CORE_CLK_PS / 2;    // 3200 ps
    localparam int unsigned PCIE_HALF_PS = 2_000;              // 250 MHz

    logic mmcm_locked;
    logic async_rst_root;    // active high: board reset OR MMCM unlocked

    // -------------------------------------------------------------------------
    // Clock generation
    // -------------------------------------------------------------------------
`ifdef SIMULATION
    // =========================================================================
    // BEHAVIOURAL MODEL — SIMULATION ONLY. NOT SYNTHESIZABLE. NOT THE HARDWARE.
    // See the warning in the header: this proves nothing about the real clock.
    // `forever` inside `initial` rather than a bare `always`, so the project
    // rule "always_ff / always_comb only" still holds for every synthesizable
    // construct in this repo (manual 00.03 §2).
    // =========================================================================
    logic core_clk_beh;
    logic pcie_clk_beh;

    initial begin
        core_clk_beh = 1'b0;
        forever #(CORE_HALF_PS * 1ps) core_clk_beh = ~core_clk_beh;
    end

    initial begin
        pcie_clk_beh = 1'b0;
        forever #(PCIE_HALF_PS * 1ps) pcie_clk_beh = ~pcie_clk_beh;
    end

    // Token lock delay so testbenches exercise the "held in reset until locked"
    // path at all. It is a placeholder, not a model of MMCM lock time.
    initial begin
        mmcm_locked = 1'b0;
        #1000ns;
        mmcm_locked = 1'b1;
    end

    assign core_clk = core_clk_beh;
    assign pcie_clk = pcie_clk_beh;

    // The differential reference pins are unused by the behavioural model.
    /* verilator lint_off UNUSED */
    logic unused_sim;
    assign unused_sim = &{1'b0, sys_clk_p, sys_clk_n,
                          pcie_refclk_p, pcie_refclk_n, 1'b0};
    /* verilator lint_on UNUSED */

`else
    // =========================================================================
    // HARDWARE — AMD/Xilinx UltraScale+ primitives.
    // Vendor-specific by necessity: this is the isolation wrapper CLAUDE.md §2
    // calls for. An Intel Agilex port replaces THIS BRANCH ONLY.
    // =========================================================================
    logic sys_clk_ibuf;
    logic clk_fb_out, clk_fb_in;
    logic core_clk_raw, pcie_clk_raw;

    IBUFDS #(
        .DQS_BIAS ("FALSE")
    ) u_sys_clk_ibufds (
        .I  (sys_clk_p),
        .IB (sys_clk_n),
        .O  (sys_clk_ibuf)
    );

    MMCME4_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKIN1_PERIOD      (CLKIN_PERIOD_NS),
        .DIVCLK_DIVIDE      (DIVCLK_DIVIDE),
        .CLKFBOUT_MULT_F    (CLKFB_MULT_F),
        .CLKFBOUT_PHASE     (0.000),
        .CLKOUT0_DIVIDE_F   (CLKOUT0_DIVIDE_F),   // core_clk 156.25 MHz
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT0_PHASE      (0.000),
        .CLKOUT1_DIVIDE     (CLKOUT1_DIVIDE),     // pcie_clk 250 MHz
        .CLKOUT1_DUTY_CYCLE (0.500),
        .CLKOUT1_PHASE      (0.000),
        .STARTUP_WAIT       ("FALSE")
    ) u_mmcm (
        .CLKIN1   (sys_clk_ibuf),
        .CLKFBIN  (clk_fb_in),
        .CLKFBOUT (clk_fb_out),
        .CLKFBOUTB(),
        .CLKOUT0  (core_clk_raw),
        .CLKOUT0B (),
        .CLKOUT1  (pcie_clk_raw),
        .CLKOUT1B (),
        .CLKOUT2  (),
        .CLKOUT2B (),
        .CLKOUT3  (),
        .CLKOUT3B (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .LOCKED   (mmcm_locked),
        .PWRDWN   (1'b0),
        .RST      (~sys_rst_n)
    );

    BUFG u_fb_bufg   (.I (clk_fb_out),   .O (clk_fb_in));
    BUFG u_core_bufg (.I (core_clk_raw), .O (core_clk));
    BUFG u_pcie_bufg (.I (pcie_clk_raw), .O (pcie_clk));

    // The PCIe reference pins are consumed by the PCIe hard block inside
    // host_ctrl, not here — see the placeholder warning in the header.
    /* verilator lint_off UNUSED */
    logic unused_hw;
    assign unused_hw = &{1'b0, pcie_refclk_p, pcie_refclk_n, 1'b0};
    /* verilator lint_on UNUSED */
`endif

    // -------------------------------------------------------------------------
    // Reset tree. IDENTICAL IN SIMULATION AND HARDWARE — deliberately, so the
    // one part of this module whose behaviour testbenches can genuinely prove is
    // the same code that ships.
    // -------------------------------------------------------------------------
    // Fail-closed root: reset asserted while the board says so OR the clock is
    // not yet trustworthy.
    assign async_rst_root = ~sys_rst_n | ~mmcm_locked;

    reset_sync #(
        .STAGES         (3),
        .RELEASE_CYCLES (CORE_RST_HOLD)
    ) u_core_rst_sync (
        .clk           (core_clk),
        .async_rst_in  (async_rst_root),
        .sync_rst_out  (core_rst)
    );

    // PCIe domain also honours PERST#.
    reset_sync #(
        .STAGES         (3),
        .RELEASE_CYCLES (PCIE_RST_HOLD)
    ) u_pcie_rst_sync (
        .clk           (pcie_clk),
        .async_rst_in  (async_rst_root | ~pcie_rst_n),
        .sync_rst_out  (pcie_rst)
    );

    // -------------------------------------------------------------------------
    // Elaboration / simulation checks
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    initial begin
        // Keep the MMCM configuration honest against the project-wide contract.
        // If trading_pkg::CORE_CLK_KHZ moves, this fires and forces the MMCM
        // constants (and the latency budget in the manuals) to move with it.
        if (CORE_GEN_KHZ != CORE_CLK_KHZ) begin
            $error("clk_rst_gen: MMCM produces %0d kHz but trading_pkg::CORE_CLK_KHZ is %0d kHz. Fix the MMCM constants AND the latency budget.",
                   CORE_GEN_KHZ, CORE_CLK_KHZ);
            $fatal(1);
        end
        if ((CORE_HALF_PS * 2) != CORE_CLK_PS) begin
            $error("clk_rst_gen: CORE_CLK_PS (%0d) is not an even number of picoseconds; the behavioural clock cannot represent it.", CORE_CLK_PS);
            $fatal(1);
        end
        if (SYS_CLK_KHZ != 100_000) begin
            $error("clk_rst_gen: MMCM constants are hand-computed for a 100 MHz reference; SYS_CLK_KHZ = %0d. Recompute them.", SYS_CLK_KHZ);
            $fatal(1);
        end
        if (PCIE_GEN_KHZ != 250_000) begin
            $error("clk_rst_gen: CLKOUT1 produces %0d kHz, expected 250000.", PCIE_GEN_KHZ);
            $fatal(1);
        end
    end

    // Nothing may leave reset before the clock is trustworthy.
    assert property (@(posedge core_clk) !mmcm_locked |-> core_rst)
        else $error("clk_rst_gen: core_rst released while MMCM unlocked");

    assert property (@(posedge pcie_clk) !mmcm_locked |-> pcie_rst)
        else $error("clk_rst_gen: pcie_rst released while MMCM unlocked");

    assert property (@(posedge core_clk) !sys_rst_n |-> core_rst)
        else $error("clk_rst_gen: core_rst released while board reset asserted");
`endif

endmodule : clk_rst_gen

`default_nettype wire
