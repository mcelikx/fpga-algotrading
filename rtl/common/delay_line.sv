// =============================================================================
// delay_line.sv — SRL-inferring pipeline-matching delay line
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/01-fpga-design/01-rtl-design-patterns.md §7
//           manuals/00-foundations/03-hdl-and-rtl-coding.md §6
//
// PURPOSE
//   Delay the fast branch of a forked datapath so it rejoins the slow branch in
//   step. Canonical uses here: carrying `rx_cycle` / `sym` / `side` alongside a
//   BRAM order-map lookup, and holding a decoded ITCH field while the book
//   engine takes its two cycles.
//
//   Use ONE shared `PIPE_DEPTH` parameter for the branch that sets the depth and
//   for this delay line (manual §7). Two hand-maintained constants that must
//   match is a bug waiting for the day someone adds a pipeline stage.
//
// LATENCY
//   Exactly DEPTH cycles = DEPTH * 6.4 ns @ 156.25 MHz. Fixed, no jitter.
//   DEPTH = 0 is legal and is a wire (0 cycles).
//
// RESOURCE
//   With SRL inference: ceil(DEPTH/32) LUT per data bit, plus DEPTH FF for the
//   valid chain.  W=64, DEPTH=16 -> ~64 LUT + 16 FF, versus 1024 FF if the data
//   were reset. That is the ~32x the manual is talking about.
//   For DEPTH > 32 the tool cascades SRL32s; above ~128 consider a BRAM FIFO.
//
// -----------------------------------------------------------------------------
// ⚠️  THE DATA PATH IS DELIBERATELY NOT RESET — THIS IS THE WHOLE POINT
//   A Xilinx SRL (SRL16/SRL32) is a LUT configured as a shift register. It has a
//   clock enable but NO reset input. The moment you write `if (rst) dl[i] <= 0`,
//   the tool can no longer map the shift register into a LUT and falls back to
//   discrete flip-flops: ~32x the resource for a deep line, plus every one of
//   those FFs becomes a sink on the global reset net, which costs Fmax
//   (manual 03 §6, manual 01.01 §7).
//
//   The consequence you must accept: FOR THE FIRST `DEPTH` CYCLES AFTER RESET,
//   `out_data` IS STALE GARBAGE FROM BEFORE THE RESET. That is safe — and only
//   safe — because `out_valid` comes from a separate chain that IS reset, and no
//   consumer may look at `out_data` when `out_valid` is low. The assertion below
//   enforces the discipline on the producer side; the consumer's own assertions
//   must enforce it downstream.
//
// ⚠️  `en` GATES BOTH CHAINS TOGETHER. If you stall the data you must stall the
//   valid, or the two desynchronize and every sample is misattributed. There is
//   exactly one `en`, used by both, for that reason. Tie it to 1'b1 unless the
//   consuming pipeline genuinely stalls.
// =============================================================================
`default_nettype none

module delay_line #(
    parameter int unsigned W     = 64,   // payload width
    parameter int unsigned DEPTH = 1     // delay in cycles; 0 = passthrough
) (
    input  var logic         clk,
    input  var logic         rst,        // synchronous, active high (valid only)
    input  var logic         en,         // clock enable for BOTH chains
    input  var logic [W-1:0] in_data,
    input  var logic         in_valid,
    output var logic [W-1:0] out_data,
    output var logic         out_valid
);

    generate
        if (DEPTH == 0) begin : g_passthrough
            // Combinational passthrough, justified: a zero-cycle delay line is a
            // wire by definition. Present so callers can parameterize DEPTH to 0
            // without a special case at the instantiation site.
            assign out_data  = in_data;
            assign out_valid = in_valid;

        end else begin : g_srl

            // -----------------------------------------------------------------
            // Data chain: NO RESET (see header). SRL_STYLE nudges Vivado toward
            // the SRL primitive; verify with report_utilization that it landed
            // as SRL and not as FFs, because a silent fallback is a 32x resource
            // regression that nothing else will flag.
            // -----------------------------------------------------------------
            (* SHREG_EXTRACT = "YES", SRL_STYLE = "srl" *)
            logic [W-1:0] dl_q [DEPTH];

            always_ff @(posedge clk) begin
                if (en) begin
                    dl_q[0] <= in_data;
                    for (int unsigned i = 1; i < DEPTH; i++) begin
                        dl_q[i] <= dl_q[i-1];
                    end
                end
            end

            // -----------------------------------------------------------------
            // Valid chain: IS RESET. Control state (manual 03 §6). This is what
            // makes the unreset data chain safe.
            // The width cast truncates the MSB of {vld_q, in_valid}, which is
            // exactly a shift-left-by-one with in_valid shifted in, and is
            // correct for DEPTH == 1 as well.
            // -----------------------------------------------------------------
            logic [DEPTH-1:0] vld_q;

            always_ff @(posedge clk) begin
                if (rst)     vld_q <= '0;
                else if (en) vld_q <= DEPTH'({vld_q, in_valid});
            end

            // Both outputs are direct flip-flop / SRL outputs with no logic in
            // between: registered outputs (manual 03 §5).
            assign out_data  = dl_q[DEPTH-1];
            assign out_valid = vld_q[DEPTH-1];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    initial begin
        if (W < 1) begin
            $error("delay_line: W must be >= 1 (got %0d).", W);
            $fatal(1);
        end
    end

    // The delay really is DEPTH cycles, and the data really did arrive DEPTH
    // cycles ago. This is the assertion that catches a pipeline-depth mismatch
    // after someone adds a stage upstream and forgets to bump PIPE_DEPTH.
    //
    // `$past(x, DEPTH)` counts CLOCK ticks, not enabled ticks, so the checks are
    // disabled unless `en` has been continuously high across the whole window —
    // which is the normal case (`en` tied to 1'b1).
    if (DEPTH > 0) begin : g_assert_depth
        logic [DEPTH:0] en_hist_q;

        always_ff @(posedge clk) begin
            if (rst) en_hist_q <= '0;
            else     en_hist_q <= {en_hist_q[DEPTH-1:0], en};
        end

        assert property (@(posedge clk) disable iff (rst || !(&en_hist_q))
            out_valid == $past(in_valid, DEPTH))
            else $error("delay_line: out_valid does not match in_valid delayed by %0d", DEPTH);

        assert property (@(posedge clk) disable iff (rst || !(&en_hist_q))
            out_valid |-> (out_data == $past(in_data, DEPTH)))
            else $error("delay_line: out_data does not match in_data delayed by %0d", DEPTH);
    end
`endif

endmodule : delay_line

`default_nettype wire
