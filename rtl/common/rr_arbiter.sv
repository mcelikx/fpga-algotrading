// =============================================================================
// rr_arbiter.sv — Round-robin arbiter
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/01-fpga-design/01-rtl-design-patterns.md §4
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   Share one resource fairly between N requesters, granting to the requester
//   AFTER the last grantee and wrapping around. Bounded worst-case wait of N-1
//   grant opportunities — no requester can be starved.
//
//   Legitimate users here: the A/B market-data feed arbitration in net_rx_path,
//   telemetry read arbitration, host command dispatch. Anywhere fairness matters
//   more than the last nanosecond.
//
// LATENCY
//   0 cycles. `grant` is combinational from `req` (see the exception note).
//   The rotation pointer updates on the clock edge after each grant.
//
// ⚠️  ROUND ROBIN ADDS JITTER — AND JITTER IS THE THING THIS PROJECT MINIMISES
//   Worst-case wait is N-1 grants worse than best case (manual §4). CLAUDE.md
//   §5.8 ranks determinism above average speed, so ON THE TICK-TO-TRADE PATH
//   USE `fixed_arbiter` WITH THE LATENCY-CRITICAL REQUESTER AT PRIORITY 0, and
//   count the starvation of everyone else. Round robin belongs on paths where
//   all requesters are equally (un)important.
//
// RESOURCE (N=8)
//   ~2 * N-bit carry chains (the two lowest-set-bit isolates) + N-bit mask
//   register + a small OR tree.  ~40 LUT + N FF. 0 BRAM. 0 DSP.
//   Scales as the flat encoders inside prio_encoder do not — for N > 32 use
//   prio_encoder-style hierarchy or accept the Fmax cost. N here is expected to
//   be small (2-8); the assertion below warns above 32.
//
// -----------------------------------------------------------------------------
// ⚠️  `grant` IS COMBINATIONAL — a justified exception to "registered outputs by
//   default" (manual 03 §5). A registered grant costs a cycle on every transfer
//   and turns a 0-cycle arbitration into a 6.4 ns one; worse, it changes the
//   protocol, because the requester must then hold `req` for an extra cycle.
//   The consequence: `req` -> `grant` is a combinational path THROUGH this
//   module. If it lands on the critical path, register `req` upstream or the
//   grant consumer downstream, not this module.
//
// ⚠️  REQUESTERS MUST HOLD `req` UNTIL GRANTED. A requester that drops `req` in
//   the same cycle it is granted still consumes the grant and still rotates the
//   pointer. Asserted below.
// =============================================================================
`default_nettype none

module rr_arbiter #(
    parameter int unsigned N = 4,   // number of requesters, >= 2
    // DERIVED — do not override (SystemVerilog cannot size a port from a
    // body-scoped localparam).
    parameter int unsigned IDX_W = (N > 1) ? $clog2(N) : 1
) (
    input  var logic             clk,
    input  var logic             rst,          // synchronous, active high
    input  var logic             en,           // 0 = hold all grants low
    input  var logic [N-1:0]     req,          // one bit per requester
    output var logic [N-1:0]     grant,        // ONE-HOT, or all zero
    output var logic             grant_valid,  // 1 = exactly one grant asserted
    output var logic [IDX_W-1:0] grant_idx     // index of the granted requester
);

    localparam logic [N-1:0] N_ONE = N'(1);

    // Rotation mask: bits STRICTLY ABOVE the last grantee. Control state -> reset.
    // Reset value all-ones = "consider everyone", so the first grant after reset
    // goes to requester 0. Deterministic start-up state.
    logic [N-1:0] mask_q;

    logic [N-1:0] masked_req;
    logic [N-1:0] grant_masked;   // winner among the requesters above last grant
    logic [N-1:0] grant_unmasked; // winner after wrapping around
    logic         masked_any;

    assign masked_req = req & mask_q;
    assign masked_any = |masked_req;

    // Isolate the lowest set bit. `x & (~x + 1)` maps to the CARRY8 chain on
    // UltraScale+ — much faster than a LUT priority chain (see prio_encoder).
    assign grant_masked   = masked_req & (~masked_req + N_ONE);
    assign grant_unmasked = req        & (~req        + N_ONE);

    always_comb begin
        grant       = '0;                      // default (no latch)
        grant_valid = 1'b0;
        if (en) begin
            grant       = masked_any ? grant_masked : grant_unmasked;
            grant_valid = |req;
        end
    end

    // One-hot -> binary by OR reduction (grant is one-hot by construction).
    always_comb begin
        grant_idx = '0;                        // default (no latch)
        for (int unsigned i = 0; i < N; i++) begin
            grant_idx = grant_idx | (IDX_W'(i) & {IDX_W{grant[i]}});
        end
    end

    // Rotate: after granting bit k, consider only bits > k next time.
    // (grant | (grant-1)) fills all bits at and below k; inverting leaves the
    // bits above k. One carry chain, no priority logic.
    always_ff @(posedge clk) begin
        if (rst) begin
            mask_q <= {N{1'b1}};
        end else if (en && grant_valid) begin
            mask_q <= ~(grant | (grant - N_ONE));
        end
    end

    // -------------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    initial begin
        if (N < 2) begin
            $error("rr_arbiter: N must be >= 2 (got %0d).", N);
            $fatal(1);
        end
        if (N > 32) begin
            $warning("rr_arbiter: N = %0d. The flat lowest-set-bit isolate becomes a long carry chain above ~32; build a hierarchical arbiter instead (manual 01.01 §4).", N);
        end
    end

    // Grant is one-hot or zero. If this ever fails, two requesters believe they
    // own the resource simultaneously.
    assert property (@(posedge clk) disable iff (rst)
        $onehot0(grant))
        else $error("rr_arbiter: grant is not one-hot");

    // grant_valid agrees with grant.
    assert property (@(posedge clk) disable iff (rst)
        grant_valid == (grant != '0))
        else $error("rr_arbiter: grant_valid disagrees with grant");

    // Never grant to a requester that did not ask.
    assert property (@(posedge clk) disable iff (rst)
        (grant & ~req) == '0)
        else $error("rr_arbiter: granted a non-requester");

    // Disabled means silent.
    assert property (@(posedge clk) disable iff (rst)
        !en |-> (grant == '0 && !grant_valid))
        else $error("rr_arbiter: granted while disabled");

    // If anyone is asking and we are enabled, somebody is granted — no idle
    // cycles wasted on an empty rotation.
    assert property (@(posedge clk) disable iff (rst)
        (en && (req != '0)) |-> grant_valid)
        else $error("rr_arbiter: requests pending but no grant issued");

    // The granted index really is the granted bit.
    assert property (@(posedge clk) disable iff (rst)
        grant_valid |-> grant[grant_idx])
        else $error("rr_arbiter: grant_idx %0d does not match the one-hot grant", grant_idx);

    // Fairness / no starvation: a continuously asserted request must be granted
    // within N grant opportunities. Bounded wait is the entire reason to choose
    // round robin, so it is asserted rather than assumed.
    genvar r;
    for (r = 0; r < int'(N); r++) begin : g_no_starve
        assert property (@(posedge clk) disable iff (rst)
            (en && req[r] && !grant[r]) |-> ##[1:N] (grant[r] || !req[r] || !en))
            else $error("rr_arbiter: requester %0d starved for more than N cycles", r);
    end

    // Requesters are EXPECTED to hold `req` until granted. Withdrawing is safe
    // here (grant is combinational, so a withdrawn request simply produces no
    // grant and does not rotate the pointer) but it is almost always a bug in
    // the requester — hence a warning, not an error.
    for (r = 0; r < int'(N); r++) begin : g_hold_req
        assert property (@(posedge clk) disable iff (rst)
            (req[r] && !grant[r]) |=> (req[r] || !en))
            else $warning("rr_arbiter: requester %0d withdrew req before being granted", r);
    end
`endif

endmodule : rr_arbiter

`default_nettype wire
