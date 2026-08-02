// =============================================================================
// cdc_sync_bit.sv — N-stage single-bit level synchronizer
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/00-foundations/04-clocking-reset-and-cdc.md §3.1
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   Carry exactly ONE bit of slowly-changing level information into `dst_clk`.
//   Legitimate users: host config enables, link-up status, the external kill
//   input, a per-domain "armed" flag. Nothing else.
//
// LATENCY
//   STAGES destination-clock cycles of pipeline, plus up to 1 further cycle of
//   sampling uncertainty (the source edge may land just after a dst edge).
//     STAGES=2 -> 2 cyc =  12.8 ns @ 156.25 MHz (6.4 ns/cyc)   (+ up to 6.4 ns)
//     STAGES=3 -> 3 cyc =  19.2 ns @ 156.25 MHz                (+ up to 6.4 ns)
//   This is NOT a fast-path element. It is control plane only.
//
// RESOURCE
//   STAGES FF. 0 LUT. 0 BRAM. 0 URAM. 0 DSP.
//
// -----------------------------------------------------------------------------
// ⚠️  SINGLE BIT ONLY — THIS IS THE HARD LIMIT
//   Instantiating this per bit across a multi-bit bus is the classic CDC bug
//   (manual §2, §7). Each bit resolves independently, so the destination can
//   observe a value that never existed in the source domain — a price that was
//   never quoted, a quantity that was never sent. For a bus use `async_fifo`
//   (streaming) or `cdc_handshake` (infrequent control writes).
//   The ONE sanctioned exception is a gray-coded pointer, where by construction
//   only one bit changes per increment; `async_fifo` does exactly that and is
//   the only module in this repo permitted to do so.
//
// ⚠️  SOURCE MUST BE STABLE FOR >= 2 DESTINATION CLOCK PERIODS
//   A single-cycle pulse crossing into a slower domain is silently dropped. For
//   pulses use `cdc_pulse`. If the source can burst, use `async_fifo`.
//
// ⚠️  REGISTER BEFORE CROSSING
//   `src_bit` must be the output of a flip-flop in the source domain, never
//   combinational logic. A glitch on a combinational source is indistinguishable
//   from a real transition once it has been sampled (manual §7).
//
// ⚠️  NO RESET, BY DESIGN
//   A synchronizer chain has no reset: a reset net into the chain is another
//   asynchronous input to the same flip-flops and defeats the ASYNC_REG
//   placement. The chain self-flushes in STAGES cycles. Power-up / bitstream
//   configuration value is INIT_VAL (default 0). If the consumer needs a
//   fail-safe power-up level (e.g. "kill asserted until proven otherwise"), set
//   INIT_VAL = 1'b1 — see CLAUDE.md §5 rule 4, fail-closed.
//
// XDC (constraints/cdc.xdc) — the source-to-first-stage path must be bounded,
// never `set_false_path`:
//   set_max_delay -datapath_only -from [get_pins -hier -filter \
//       {NAME =~ */u_*_cdc/sync_q_reg[0]/D}] <dst_period_ns>
// and declare the domains asynchronous with set_clock_groups -asynchronous.
// =============================================================================
`default_nettype none

module cdc_sync_bit #(
    // Number of destination-domain flip-flops in the chain. 2 is the project
    // minimum; use 3 for signals whose corruption is safety-relevant (the
    // external kill input in fpga_top.sv uses 3).
    parameter int unsigned STAGES   = 2,
    // Configuration / power-up value of the chain. Choose the SAFE level.
    parameter logic        INIT_VAL = 1'b0
) (
    input  var logic dst_clk,   // destination clock
    input  var logic src_bit,   // source-domain FF output, asynchronous to dst_clk
    output var logic dst_bit    // synchronized level, dst_clk domain
);

    // ASYNC_REG keeps the chain in one slice so the inter-stage settling time is
    // the full clock period. Omitting it is a real bug, not a style issue
    // (manual §3.1) — a placer that spreads the chain silently destroys MTBF.
    // The declaration initializer is the FPGA configuration (power-up) value —
    // it becomes the FF's INIT attribute in the bitstream, it is NOT a reset.
    // The PROCASSINIT lint check assumes a reset was intended; here the absence
    // of a reset is the design (see header).
    /* verilator lint_off PROCASSINIT */
    (* ASYNC_REG = "TRUE" *)
    logic [STAGES-1:0] sync_q = {STAGES{INIT_VAL}};
    /* verilator lint_on PROCASSINIT */

    always_ff @(posedge dst_clk) begin
        sync_q <= {sync_q[STAGES-2:0], src_bit};
    end

    // Combinational output by exception: this is a direct flip-flop output with
    // no logic between the FF and the port, so it is a registered output in
    // every sense that matters for timing (manual 03 §5).
    assign dst_bit = sync_q[STAGES-1];

    // -------------------------------------------------------------------------
    // Elaboration / simulation checks
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    initial begin
        if (STAGES < 2) begin
            $error("cdc_sync_bit: STAGES must be >= 2 (got %0d). A 1-FF chain is not a synchronizer.", STAGES);
            $fatal(1);
        end
    end
`endif

endmodule : cdc_sync_bit

`default_nettype wire
