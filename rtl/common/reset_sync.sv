// =============================================================================
// reset_sync.sv — Asynchronous-assert / synchronous-de-assert reset synchronizer
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/00-foundations/04-clocking-reset-and-cdc.md §4
//           manuals/00-foundations/03-hdl-and-rtl-coding.md §6
//
// PURPOSE
//   Turn a free-running asynchronous reset (board pushbutton, PLL `locked`
//   de-assertion, PCIe PERST#) into the project-standard synchronous active-high
//   `rst` for ONE clock domain. Every clock domain in the design gets its own
//   instance; the output of this module is the ONLY reset that downstream RTL is
//   allowed to use, and it is used synchronously (`if (rst)` inside always_ff).
//
//   Assert asynchronously  -> works even before the clock is running.
//   De-assert synchronously -> every FF leaves reset on the same clock edge, so
//                              no FSM can start in an illegal state.
//
// LATENCY
//   Assertion : 0 cycles (asynchronous).
//   Release   : STAGES + RELEASE_CYCLES clock edges after `async_rst_in` falls.
//               Default STAGES=2, RELEASE_CYCLES=0 -> 2 cyc = 12.8 ns @ 156.25 MHz.
//
// RESOURCE
//   STAGES + RELEASE_CYCLES FF. 0 LUT. 0 BRAM. 0 DSP.
//
// -----------------------------------------------------------------------------
// ⚠️  THIS IS THE ONLY PLACE IN THE DESIGN WITH AN ASYNCHRONOUS `always_ff`
//   SENSITIVITY LIST. `always_ff @(posedge clk or posedge async_rst_in)` is
//   deliberate and correct here and is a review failure anywhere else — see
//   manual 03 §6 (synchronous, active-high reset project-wide).
//
// ⚠️  RESET RELEASE IS A CDC EVENT. `async_rst_in` is asynchronous to `clk`, so
//   the release edge must be constrained. Without it the tool may route the
//   reset net so wide that different domains leave reset cycles apart, which is
//   exactly the "1-in-10^6 resets, FSM starts illegal" bug in manual §7.
//
// ⚠️  RESET TO THE SAFE STATE, NOT THE USEFUL ONE (manual §4, CLAUDE.md §5.4).
//   Everything downstream must come out of reset with trading disabled and all
//   risk limits at zero. A bitstream reload must never come up armed.
//
// XDC (constraints/cdc.xdc):
//   set_false_path -from [get_ports sys_rst_n]                 ;# async assert only
//   set_max_delay -datapath_only \
//       -from [get_pins -hier -filter {NAME =~ */u_*rst_sync/rst_q_reg[*]/CLR}] \
//       <dst_period_ns>
//   # and constrain the release path:
//   set_property ASYNC_REG TRUE [get_cells -hier -filter {NAME =~ */rst_q_reg[*]}]
// =============================================================================
`default_nettype none

module reset_sync #(
    // Synchronizer depth for the release edge. 2 minimum, 3 for domains whose
    // mis-timed release is safety-relevant.
    parameter int unsigned STAGES         = 2,
    // Extra clock cycles to hold reset asserted after the synchronizer has
    // released. Use to guarantee a minimum reset pulse width for hard IP or to
    // stagger the release order between domains. 0 = release immediately.
    parameter int unsigned RELEASE_CYCLES = 0
) (
    input  var logic clk,            // destination clock
    // SYNCASYNCNET is expected here and only here: `async_rst_in` is used
    // asynchronously by the reset FF (by design) and synchronously by the
    // simulation-only assertions below. Both uses are intentional.
    /* verilator lint_off SYNCASYNCNET */
    input  var logic async_rst_in,   // ACTIVE HIGH, asynchronous, from anywhere
    /* verilator lint_on SYNCASYNCNET */
    output var logic sync_rst_out    // ACTIVE HIGH, synchronous to clk
);

    localparam int unsigned TOTAL = STAGES + RELEASE_CYCLES;

    // Reset value is 1 (asserted): a configuration/power-up state of "in reset"
    // is the fail-safe one. ASYNC_REG for the same reason as cdc_sync_bit: the
    // release edge is an asynchronous input to rst_q[0].
    /* verilator lint_off PROCASSINIT */
    (* ASYNC_REG = "TRUE" *)
    logic [TOTAL-1:0] rst_q = {TOTAL{1'b1}};   // FPGA config value, not a reset
    /* verilator lint_on PROCASSINIT */

    // The ONE sanctioned asynchronous always_ff in this project (see header).
    always_ff @(posedge clk or posedge async_rst_in) begin
        if (async_rst_in) begin
            rst_q <= {TOTAL{1'b1}};              // asynchronous assert
        end else begin
            rst_q <= {rst_q[TOTAL-2:0], 1'b0};   // synchronous release, shifted in
        end
    end

    // Direct FF output, no logic in between — registered output (manual 03 §5).
    assign sync_rst_out = rst_q[TOTAL-1];

    // -------------------------------------------------------------------------
    // Elaboration / simulation checks
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    initial begin
        if (STAGES < 2) begin
            $error("reset_sync: STAGES must be >= 2 (got %0d).", STAGES);
            $fatal(1);
        end
    end

    // Assertion is immediate and unconditional.
    assert property (@(posedge clk) async_rst_in |-> sync_rst_out)
        else $error("reset_sync: reset asserted but sync_rst_out low");

    // Release is monotonic: once released, reset may only re-assert via
    // async_rst_in. Catches a shift-register that got wired backwards.
    assert property (@(posedge clk)
        (!async_rst_in && !sync_rst_out) |=> (async_rst_in || !sync_rst_out))
        else $error("reset_sync: spurious re-assertion of sync_rst_out");
`endif

endmodule : reset_sync

`default_nettype wire
