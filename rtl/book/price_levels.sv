// =============================================================================
// price_levels.sv — per-symbol, per-side aggregated price levels
// -----------------------------------------------------------------------------
// LATENCY  : 2 cycles (12.8 ns @ 156.25 MHz), fixed. Read-modify-write with
//            same-address forwarding, so back-to-back updates to one level do
//            not stall.
// RESOURCE : N_ACTIVE(256) x 2 sides x LEVELS(16) x 32-bit qty = 256 Kbit
//            ~= 8 BRAM36. Window base: 256 x 2 x 32 bit in LUTRAM.
//            > Verify against the post-synthesis utilization report.
// Governing manual: manuals/04-system-architecture/03-order-book-in-hardware.md
//
// STRUCTURE CHOICE — direct index on a tick-normalized price.
//   level = (price - window_base) / TICK_UNITS,  divider-free (see book_pkg).
// Rejected alternatives:
//   * sorted list — insertion is O(n) in fabric and variable latency
//   * heap        — multi-cycle sift, variable latency, the thing we must avoid
//   * tree        — log-depth pointer chase, several BRAM reads deep
// Direct index is ONE memory access. The occupancy mask maintained alongside is
// what lets top_of_book find a new best by priority-encode instead of by a
// comparator tree over every level.
// =============================================================================
`default_nettype none

module price_levels
    import trading_pkg::*;
    import book_pkg::*;
(
    input  var logic       clk,
    input  var logic       rst,

    // ── Update request ───────────────────────────────────────────────────────
    input  var logic       upd_valid,
    input  var sym_idx_t   upd_sym,
    input  var side_e      upd_side,
    input  var price_t     upd_price,
    input  var qty_t       upd_add,      // shares joining this level
    input  var qty_t       upd_del,      // shares leaving this level
    input  var logic       upd_clear,    // BOOK_CLEAR: wipe this symbol

    // ── Result, 2 cycles later ───────────────────────────────────────────────
    output var logic       res_valid,
    output var sym_idx_t   res_sym,
    output var side_e      res_side,
    output var level_idx_t res_level,
    output var price_t     res_price,
    output var qty_t       res_qty,        // level quantity AFTER the update
    output var logic       res_occupied,   // level is non-empty after the update
    output var logic       res_in_window,  // price fell inside the maintained window

    // ── Health ───────────────────────────────────────────────────────────────
    output var logic [31:0] cnt_out_of_window,
    output var logic [31:0] cnt_underflow,
    output var logic [31:0] cnt_forward,
    output var logic [31:0] cnt_reanchor
);

    // =========================================================================
    // Window anchoring
    // =========================================================================
    // ⚠️ KNOWN LIMITATION — READ BEFORE DEPLOYING.
    //    The window base is currently auto-anchored to the first price observed
    //    on a side after a clear, and re-anchored only when that side is empty.
    //    That is adequate for simulation and bring-up but NOT for production:
    //    a symbol that gaps hard intraday will push the true top of book outside
    //    the window while the side is still occupied, and top-of-book then
    //    reports a stale best until the side empties.
    //
    //    The correct design is a HOST-WRITTEN per-symbol reference price,
    //    refreshed on a slow cadence from the last trade or the previous close.
    //    `book_engine` has no cfg port in the current `fpga_top` contract, so
    //    adding one is a deliberate two-file change.
    //    Tracked as a blocking item for the order book in TASKS.md Phase 4.
    //
    //    `cnt_out_of_window` and `cnt_reanchor` exist so this is OBSERVABLE
    //    rather than silent. A nonzero out-of-window count in production means
    //    the book is not reporting the real top.
    price_t    base_q  [N_ACTIVE][2];
    logic      anchored[N_ACTIVE][2];

    // =========================================================================
    // Level quantity storage
    // =========================================================================
    qty_t levels [N_ACTIVE][2][LEVELS];

    initial begin
        for (int unsigned s = 0; s < N_ACTIVE; s++)
            for (int unsigned d = 0; d < 2; d++) begin
                base_q[s][d]   = '0;
                anchored[s][d] = 1'b0;
                for (int unsigned l = 0; l < LEVELS; l++) levels[s][d][l] = '0;
            end
    end

    // =========================================================================
    // Stage 0 — anchor, normalize to a level index, issue the read
    // =========================================================================
    logic       s0_valid, s0_clear;
    sym_idx_t   s0_sym;
    side_e      s0_side;
    price_t     s0_price;
    qty_t       s0_add, s0_del;
    level_idx_t s0_level;
    logic       s0_in_win;

    logic       side_i;
    price_t     cur_base;
    logic       cur_anchored;
    logic [31:0] delta;
    logic [31:0] ticks;

    always_comb begin
        side_i       = (upd_side == SIDE_SELL);
        cur_base     = base_q[upd_sym][side_i];
        cur_anchored = anchored[upd_sym][side_i];

        // Centre the window on the anchor so price can move either way.
        // Anchor sits at level LEVELS/2.
        delta = 32'd0;
        ticks = 32'd0;
        s0_in_win = 1'b0;
        s0_level  = '0;

        if (!cur_anchored) begin
            // First price on this side: it defines the window centre.
            s0_in_win = 1'b1;
            s0_level  = level_idx_t'(LEVELS / 2);
        end else if (upd_price >= cur_base) begin
            delta = upd_price - cur_base;
            ticks = to_ticks(delta);
            if (ticks < 32'(LEVELS)) begin
                s0_in_win = 1'b1;
                s0_level  = level_idx_t'(ticks);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            s0_valid <= 1'b0;
        end else begin
            s0_valid <= upd_valid;
        end
        s0_clear  <= upd_valid && upd_clear;
        s0_sym    <= upd_sym;
        s0_side   <= upd_side;
        s0_price  <= upd_price;
        s0_add    <= upd_add;
        s0_del    <= upd_del;
    end

    logic       s1_valid_d, s1_clear_d, s1_in_win_d;
    level_idx_t s1_level_d;
    always_ff @(posedge clk) begin
        s1_level_d  <= s0_level;
        s1_in_win_d <= s0_in_win;
    end

    // Anchor update: only when the side is unanchored.
    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_reanchor <= '0;
        end else if (upd_valid && upd_clear) begin
            anchored[upd_sym][(upd_side == SIDE_SELL)] <= 1'b0;
        end else if (upd_valid && !cur_anchored && (upd_add != '0)) begin
            // Anchor so the first price lands at the window centre.
            base_q[upd_sym][side_i]   <= (upd_price > price_t'((LEVELS/2) * TICK_UNITS))
                                       ? (upd_price - price_t'((LEVELS/2) * TICK_UNITS))
                                       : '0;
            anchored[upd_sym][side_i] <= 1'b1;
            cnt_reanchor <= cnt_reanchor + 32'd1;
        end
    end

    // Registered read of the addressed level.
    qty_t s1_qty_raw;
    always_ff @(posedge clk) begin
        s1_qty_raw <= levels[upd_sym][(upd_side == SIDE_SELL)][s0_level];
    end

    // =========================================================================
    // Stage 1 — forward, apply the delta, write back
    // =========================================================================
    // ⚠️ SAME-LEVEL BACK-TO-BACK HAZARD. Consecutive ITCH messages very often hit
    //    the same price level — that is precisely what happens at the top of
    //    book during active trading. The second message's read was issued before
    //    the first message's write landed. Forward instead of stalling: a stall
    //    would inject jitter into the deterministic path, and jitter is the thing
    //    this whole design exists to avoid. Every forward is counted.
    logic       wb_en;
    sym_idx_t   wb_sym;
    logic       wb_side;
    level_idx_t wb_level;
    qty_t       wb_qty;

    qty_t s1_qty_eff;
    logic s1_fwd;

    always_comb begin
        s1_fwd = wb_en
              && (wb_sym   == s0_sym)
              && (wb_side  == (s0_side == SIDE_SELL))
              && (wb_level == s1_level_d);
        s1_qty_eff = s1_fwd ? wb_qty : s1_qty_raw;
    end

    qty_t s1_qty_next;
    logic s1_underflow;

    always_comb begin
        // Saturating subtract: a delete larger than the resting aggregate means
        // a gap or a decode error. Floor at zero and COUNT it — a wrapped level
        // quantity would present as an enormous phantom size at the top of book.
        s1_underflow = (s0_del > s1_qty_eff);
        s1_qty_next  = s1_underflow ? '0 : (s1_qty_eff - s0_del);
        s1_qty_next  = s1_qty_next + s0_add;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            res_valid         <= 1'b0;
            wb_en             <= 1'b0;
            cnt_out_of_window <= '0;
            cnt_underflow     <= '0;
            cnt_forward       <= '0;
        end else begin
            res_valid    <= s0_valid && s1_in_win_d && !s0_clear;
            res_sym      <= s0_sym;
            res_side     <= s0_side;
            res_level    <= s1_level_d;
            res_price    <= s0_price;
            res_qty      <= s1_qty_next;
            res_occupied <= (s1_qty_next != '0);
            res_in_window<= s1_in_win_d;

            wb_en    <= s0_valid && s1_in_win_d && !s0_clear;
            wb_sym   <= s0_sym;
            wb_side  <= (s0_side == SIDE_SELL);
            wb_level <= s1_level_d;
            wb_qty   <= s1_qty_next;

            if (s0_valid && !s1_in_win_d && !s0_clear)
                cnt_out_of_window <= cnt_out_of_window + 32'd1;
            if (s0_valid && s1_underflow)
                cnt_underflow <= cnt_underflow + 32'd1;
            if (s1_fwd)
                cnt_forward <= cnt_forward + 32'd1;
        end
    end

    always_ff @(posedge clk) begin
        if (wb_en) levels[wb_sym][wb_side][wb_level] <= wb_qty;
    end

    // =========================================================================
    // Assertions
    // =========================================================================
`ifndef SYNTHESIS
    // A level quantity must never wrap. This is the property that a wrapped
    // counter would violate, and a wrapped level presents as a phantom size.
    assert property (@(posedge clk) disable iff (rst)
        wb_en |-> (wb_qty <= (s1_qty_eff + s0_add))
    ) else $error("price_levels: level quantity wrapped");

    // An occupied result must carry a nonzero quantity.
    assert property (@(posedge clk) disable iff (rst)
        (res_valid && res_occupied) |-> (res_qty != '0)
    ) else $error("price_levels: occupied level with zero quantity");

    // Out-of-window updates must never produce a result.
    assert property (@(posedge clk) disable iff (rst)
        (res_valid) |-> res_in_window
    ) else $error("price_levels: emitted a result for an out-of-window price");
`endif

endmodule : price_levels

`default_nettype wire
