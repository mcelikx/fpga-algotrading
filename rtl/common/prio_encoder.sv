// =============================================================================
// prio_encoder.sv — Two-level (group / sub-group) priority encoder
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/01-fpga-design/01-rtl-design-patterns.md §4, §6
//           manuals/00-foundations/03-hdl-and-rtl-coding.md §7
//
// PURPOSE
//   Find the LOWEST set bit of an N-bit request vector. Index 0 is the highest
//   priority. This is the "find the new best level" primitive for the order
//   book: when a delete removes the current best, the book must locate the next
//   populated level in one shot. It is also the core of both arbiters.
//
//   Its latency and Fmax are on the tick-to-trade path, so the flat form is not
//   acceptable: a naive N-input priority chain over N=1024 is a deep LUT chain
//   with terrible Fmax (manual 03 §7, manual 01.01 §4). This module is built as
//   TWO LEVELS instead:
//
//     Level 1  : NG = ceil(N/GROUP) independent GROUP-wide encoders, in parallel.
//     Level 2  : one NG-wide encoder over the per-group "any request" bits.
//     Combine  : index = {group_index, sub_index_of_selected_group}, which is a
//                pure concatenation because GROUP is a power of two — no
//                multiply, no adder (CLAUDE.md §5.3).
//
//   Each level isolates the lowest set bit with `x & (~x + 1)`. On UltraScale+
//   that two's-complement negate maps onto the dedicated CARRY8 chain, which is
//   far faster than the LUT chain a `for`-loop priority encoder produces:
//   a 32-bit isolate is 4 CARRY8 (~0.6 ns) versus ~16 LUT levels. The
//   one-hot-to-binary step is then a balanced OR tree, log2(GROUP) deep.
//
// SIZING GUIDANCE
//   Set GROUP ~= sqrt(N) so both levels are the same width. N=1024 -> GROUP=32
//   (32 groups of 32). GROUP=8 with N=1024 gives 128 groups and pushes the whole
//   problem into level 2, which defeats the purpose.
//
// LATENCY  (PIPELINE parameter)
//   0 : 0 cycles, fully combinational. Two carry chains + two OR trees.
//       Estimated ~2.5-3.5 ns for N=1024/GROUP=32 -> fits in 6.4 ns, but leaves
//       little room for the logic on either side. Measure, do not guess.
//   1 : 1 cycle = 6.4 ns. Outputs registered; combinational depth unchanged.
//   2 : 2 cycles = 12.8 ns. Level 1 registered, then level 2, then the output.
//       This is the form to use if N >= 256 and the encoder is on a path that
//       already has other logic in the same cycle.
//
// RESOURCE (N=1024, GROUP=32)
//   ~32 * (32-bit carry chain + 5-wide OR tree) for level 1
//   + 1 * (32-bit carry chain + 5-wide OR tree) for level 2
//   + a 32-way 5-bit OR-mux for the sub-index select
//   ~ 900-1200 LUT combinational; + 11 FF per pipeline stage. 0 BRAM. 0 DSP.
//
// -----------------------------------------------------------------------------
// ⚠️  PRIORITY IS BY INDEX, LOWEST FIRST. For a bid book (best = highest price)
//   the caller must present the levels in descending price order, or invert the
//   index. Getting this backwards means quoting on the wrong side of the book.
//
// ⚠️  `valid` IS NOT OPTIONAL. When `req` is all zeros, `idx` is zero — which is
//   indistinguishable from "index 0 is set". Consumers must qualify with
//   `valid`. Asserted below.
//
// ⚠️  DO NOT USE THIS TO RECOMPUTE A MAXIMUM EVERY TICK. Maintain the best level
//   incrementally and call this only on the delete-the-best case, which is the
//   one variable-latency stage the top-level budget accounts for (manual §6,
//   fpga_top.sv latency table).
// =============================================================================
`default_nettype none

module prio_encoder #(
    parameter int unsigned N        = 64,   // number of request bits, >= 2
    parameter int unsigned GROUP    = 8,    // bits per sub-group; power of two
    parameter int unsigned PIPELINE = 0,    // 0 = comb, 1 = reg out, 2 = reg both
    // DERIVED — never override at an instantiation site. It lives in the
    // parameter list only because SystemVerilog will not let a body-scoped
    // localparam size a port.
    parameter int unsigned IDX_W    = (N > 1) ? $clog2(N) : 1
) (
    // clk/rst are unused when PIPELINE == 0. They stay in the port list so the
    // parameter can be changed at an instantiation site without editing the
    // connection list.
    /* verilator lint_off UNUSED */
    input  var logic                clk,
    input  var logic                rst,       // synchronous, active high
    /* verilator lint_on UNUSED */
    input  var logic [N-1:0]        req,
    output var logic [IDX_W-1:0]    idx,       // index of the lowest set bit
    output var logic                valid      // 1 = at least one request
);

    // -------------------------------------------------------------------------
    // Geometry. All elaboration-time; no hardware divider (CLAUDE.md §5.3).
    // -------------------------------------------------------------------------
    localparam int unsigned SUB_W = (GROUP > 1) ? $clog2(GROUP) : 1;
    localparam int unsigned NG    = (N + GROUP - 1) / GROUP;       // ceil(N/GROUP)
    localparam int unsigned GRP_W = (NG > 1) ? $clog2(NG) : 1;
    localparam int unsigned PAD_N = NG * GROUP;                    // padded width

    localparam logic [GROUP-1:0] GRP_ONE = GROUP'(1);
    localparam logic [NG-1:0]    NG_ONE  = NG'(1);

    // -------------------------------------------------------------------------
    // Level 1 — per-group encoders, all in parallel
    // -------------------------------------------------------------------------
    logic [PAD_N-1:0]  req_pad;
    logic [NG-1:0]     grp_any;                 // does group g have any request?
    logic [SUB_W-1:0]  grp_sub  [NG];           // lowest set bit within group g
    logic [GROUP-1:0]  g_req    [NG];
    logic [GROUP-1:0]  g_onehot [NG];

    generate
        if (PAD_N > N) begin : g_pad
            assign req_pad = {{(PAD_N - N){1'b0}}, req};
        end else begin : g_nopad
            assign req_pad = req;
        end
    endgenerate

    // All NG group encoders in one always_comb — they are independent and
    // execute in parallel in hardware; a single block keeps `grp_any` to one
    // driver. The outer loop unrolls at elaboration (manual 03 §1).
    always_comb begin
        grp_any = '0;                                       // default (no latch)
        for (int unsigned g = 0; g < NG; g++) begin
            g_req[g] = req_pad[g*GROUP +: GROUP];

            // Isolate the lowest set bit. Maps to the CARRY8 chain.
            g_onehot[g] = g_req[g] & (~g_req[g] + GRP_ONE);

            grp_any[g] = |g_req[g];

            // One-hot -> binary as a balanced OR tree. Because g_onehot has at
            // most one bit set, OR-ing the masked indices is exactly a select,
            // and synthesis builds it log2(GROUP) deep instead of as a priority
            // mux chain.
            grp_sub[g] = '0;                                // default (no latch)
            for (int unsigned i = 0; i < GROUP; i++) begin
                grp_sub[g] = grp_sub[g] | (SUB_W'(i) & {SUB_W{g_onehot[g][i]}});
            end
        end
    end

    // -------------------------------------------------------------------------
    // Optional pipeline register between the two levels (PIPELINE >= 2)
    // -------------------------------------------------------------------------
    logic [NG-1:0]    grp_any_s2;
    logic [SUB_W-1:0] grp_sub_s2 [NG];

    generate
        if (PIPELINE >= 2) begin : g_pipe_l1
            logic [NG-1:0]    grp_any_q;
            logic [SUB_W-1:0] grp_sub_q [NG];

            // grp_any is a valid-like qualifier -> reset. grp_sub is datapath,
            // meaningful only where grp_any is set -> no reset (manual 03 §6).
            always_ff @(posedge clk) begin
                if (rst) grp_any_q <= '0;
                else     grp_any_q <= grp_any;
            end

            always_ff @(posedge clk) begin
                for (int unsigned g2 = 0; g2 < NG; g2++) begin
                    grp_sub_q[g2] <= grp_sub[g2];
                end
            end

            assign grp_any_s2 = grp_any_q;
            always_comb begin
                for (int unsigned g3 = 0; g3 < NG; g3++) begin
                    grp_sub_s2[g3] = grp_sub_q[g3];
                end
            end
        end else begin : g_nopipe_l1
            assign grp_any_s2 = grp_any;
            always_comb begin
                for (int unsigned g4 = 0; g4 < NG; g4++) begin
                    grp_sub_s2[g4] = grp_sub[g4];
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Level 2 — encode across groups, then select that group's sub-index
    // -------------------------------------------------------------------------
    logic [NG-1:0]              grp_onehot;
    logic [GRP_W-1:0]           grp_idx;
    logic [SUB_W-1:0]           sub_sel;
    logic [GRP_W+SUB_W-1:0]     idx_full;
    logic                       valid_c;

    assign grp_onehot = grp_any_s2 & (~grp_any_s2 + NG_ONE);
    assign valid_c    = |grp_any_s2;

    always_comb begin
        grp_idx = '0;                                        // default (no latch)
        for (int unsigned g5 = 0; g5 < NG; g5++) begin
            grp_idx = grp_idx | (GRP_W'(g5) & {GRP_W{grp_onehot[g5]}});
        end
    end

    // Select the winning group's sub-index by OR-reduction (grp_onehot is
    // one-hot), not by a mux chain.
    always_comb begin
        sub_sel = '0;                                        // default (no latch)
        for (int unsigned g6 = 0; g6 < NG; g6++) begin
            sub_sel = sub_sel | (grp_sub_s2[g6] & {SUB_W{grp_onehot[g6]}});
        end
    end

    // GROUP is a power of two, so index = grp_idx * GROUP + sub_sel is a plain
    // concatenation. No multiplier, no adder.
    assign idx_full = {grp_idx, sub_sel};

    // -------------------------------------------------------------------------
    // Optional output register (PIPELINE >= 1)
    // -------------------------------------------------------------------------
    generate
        if (PIPELINE >= 1) begin : g_pipe_out
            always_ff @(posedge clk) begin
                if (rst) valid <= 1'b0;                      // control state
                else     valid <= valid_c;
            end
            always_ff @(posedge clk) begin
                idx <= idx_full[IDX_W-1:0];                  // datapath: no reset
            end
        end else begin : g_comb_out
            // Combinational outputs by exception (manual 03 §5): a registered
            // encoder would add a cycle to the book's new-best search, which is
            // the one variable-latency stage in the whole pipeline. Use
            // PIPELINE >= 1 if timing requires it — and then update the latency
            // table in fpga_top.sv, because it is a real cycle.
            assign valid = valid_c;
            assign idx   = idx_full[IDX_W-1:0];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    initial begin
        if (N < 2) begin
            $error("prio_encoder: N must be >= 2 (got %0d).", N);
            $fatal(1);
        end
        if (GROUP < 2) begin
            $error("prio_encoder: GROUP must be >= 2 (got %0d).", GROUP);
            $fatal(1);
        end
        if ((GROUP & (GROUP - 1)) != 0) begin
            $error("prio_encoder: GROUP must be a power of two (got %0d) — the index concatenation depends on it.", GROUP);
            $fatal(1);
        end
        if (PIPELINE > 2) begin
            $error("prio_encoder: PIPELINE must be 0, 1 or 2 (got %0d).", PIPELINE);
            $fatal(1);
        end
        if (GROUP >= N) begin
            $warning("prio_encoder: GROUP (%0d) >= N (%0d) — this degenerates to a single flat encoder. Set GROUP ~ sqrt(N).", GROUP, N);
        end
    end

    // Reference model: the golden answer, computed the slow obvious way.
    function automatic int unsigned ref_lowest(input logic [N-1:0] v);
        for (int unsigned i = 0; i < N; i++) begin
            if (v[i]) return i;
        end
        return N;    // none set
    endfunction

    // The combinational result must equal the reference, always. This is the
    // check that matters: the two-level structure is an optimization and must be
    // observationally identical to the flat encoder.
    assert property (@(posedge clk)
        (PIPELINE == 0) |-> (valid_c == (ref_lowest(req) != N)))
        else $error("prio_encoder: valid disagrees with reference model");

    assert property (@(posedge clk)
        ((PIPELINE == 0) && valid_c) |-> (idx_full[IDX_W-1:0] == IDX_W'(ref_lowest(req))))
        else $error("prio_encoder: idx %0d disagrees with reference %0d", idx_full[IDX_W-1:0], ref_lowest(req));

    // The isolate-lowest-bit trick must produce at most one bit, at every level.
    assert property (@(posedge clk) $onehot0(grp_onehot))
        else $error("prio_encoder: group one-hot has more than one bit set");

    // Structural: the selected index must actually be a set request bit.
    assert property (@(posedge clk) disable iff (rst)
        ((PIPELINE == 0) && valid) |-> req[idx])
        else $error("prio_encoder: selected index %0d is not a set request bit", idx);
`endif

endmodule : prio_encoder

`default_nettype wire
