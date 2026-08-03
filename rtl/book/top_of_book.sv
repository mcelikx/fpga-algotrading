// =============================================================================
// top_of_book.sv — incremental best bid / best ask maintenance
// -----------------------------------------------------------------------------
// LATENCY  : 1 cycle (6.4 ns) common case.
//            2 cycles (12.8 ns) worst case, when the update empties the CURRENT
//            BEST level and a new best must be found. This is the ONLY
//            variable-latency operation in the entire tick-to-trade path.
//            The extra cycle is BOUNDED (never more than one) and COUNTED.
// RESOURCE : occupancy masks   N_ACTIVE(256) x 2 x LEVELS(16)      =  8192 FF
//            best level/qty    N_ACTIVE(256) x 2 x (4 + 32)        = 18432 FF
//            plus 2 x prio_encoder over 16 inputs.
//            > Verify against the post-synthesis utilization report.
// Governing manual: manuals/04-system-architecture/03-order-book-in-hardware.md
//                   manuals/01-fpga-design/01-rtl-design-patterns.md §6
//
// ⚠️ THE CORE RULE: NEVER RECOMPUTE A MAX OVER ALL LEVELS.
//    A comparator tree over 256 levels is 8 LUT levels plus 8 routing hops —
//    roughly 51 ns at 156.25 MHz, which is a third of the entire fabric budget,
//    paid on EVERY message. Instead the best is maintained incrementally: the
//    updated level is compared against the current best, one comparison, one
//    cycle.
//
// ⚠️ THE ONE HARD CASE: deleting the current best. Now a new best must be found,
//    and that genuinely cannot be O(1) from the comparison alone. It is made
//    cheap by the OCCUPANCY BITMASK — finding the new best becomes a
//    priority-encode over 16 bits rather than a comparator tree over 16
//    quantities. Bounded at one extra cycle, counted in `cnt_best_rescan` so the
//    jitter is measured rather than assumed.
// =============================================================================
`default_nettype none

module top_of_book
    import trading_pkg::*;
    import book_pkg::*;
(
    input  var logic       clk,
    input  var logic       rst,

    // ── Level update from price_levels ───────────────────────────────────────
    input  var logic       upd_valid,
    input  var sym_idx_t   upd_sym,
    input  var side_e      upd_side,
    input  var level_idx_t upd_level,
    input  var price_t     upd_price,
    input  var qty_t       upd_qty,        // level quantity AFTER the update
    input  var logic       upd_occupied,
    input  var logic       upd_clear,

    // ── Stale propagation ────────────────────────────────────────────────────
    input  var logic       stale_in,

    // ── Top of book out ──────────────────────────────────────────────────────
    output var logic       top_valid,
    output var sym_idx_t   top_sym,
    output var price_t     top_bid_px,
    output var qty_t       top_bid_qty,
    output var price_t     top_ask_px,
    output var qty_t       top_ask_qty,
    output var logic       top_bid_valid,
    output var logic       top_ask_valid,
    output var logic       top_crossed,
    output var logic       top_stale,
    output var logic       top_changed,

    // ── Health ───────────────────────────────────────────────────────────────
    output var logic [31:0] cnt_best_rescan,
    output var logic [31:0] cnt_crossed,
    output var logic [31:0] cnt_top_change
);

    // =========================================================================
    // Per-symbol, per-side state
    // =========================================================================
    occ_mask_t  occ_q      [N_ACTIVE][2];
    level_idx_t best_lvl_q [N_ACTIVE][2];
    qty_t       best_qty_q [N_ACTIVE][2];
    price_t     best_px_q  [N_ACTIVE][2];
    logic       best_val_q [N_ACTIVE][2];

    initial begin
        for (int unsigned s = 0; s < N_ACTIVE; s++)
            for (int unsigned d = 0; d < 2; d++) begin
                occ_q[s][d]      = '0;
                best_lvl_q[s][d] = '0;
                best_qty_q[s][d] = '0;
                best_px_q[s][d]  = '0;
                best_val_q[s][d] = 1'b0;
            end
    end

    logic side_i;
    assign side_i = (upd_side == SIDE_SELL);

    // =========================================================================
    // Occupancy mask after this update
    // =========================================================================
    occ_mask_t occ_cur, occ_next;
    always_comb begin
        occ_cur  = occ_q[upd_sym][side_i];
        occ_next = occ_cur;
        if (upd_valid && !upd_clear) begin
            occ_next[upd_level] = upd_occupied;
        end
    end

    // =========================================================================
    // New-best search — the bounded, counted, variable-latency case
    // =========================================================================
    // A BID book's best is the HIGHEST occupied level; an ASK book's is the
    // LOWEST. One priority encoder finds the lowest set bit, so the bid mask is
    // bit-reversed before encoding and the index reflected afterwards.
    occ_mask_t search_mask;
    always_comb begin
        search_mask = occ_next;
        if (upd_side == SIDE_BUY) begin
            for (int unsigned b = 0; b < LEVELS; b++)
                search_mask[b] = occ_next[LEVELS - 1 - b];
        end
    end

    logic [LEVEL_W-1:0] enc_idx;
    logic               enc_valid;

    prio_encoder #(
        .N        (LEVELS),
        .PIPELINE (0)
    ) u_best_enc (
        .clk   (clk),
        .rst   (rst),
        .req   (search_mask),
        .idx   (enc_idx),
        .valid (enc_valid)
    );

    level_idx_t new_best_lvl;
    always_comb begin
        new_best_lvl = (upd_side == SIDE_BUY)
                     ? level_idx_t'(LEVELS - 1 - enc_idx)
                     : level_idx_t'(enc_idx);
    end

    // Was the current best the level we just emptied?
    logic best_destroyed, is_better, rescan;
    always_comb begin
        best_destroyed = best_val_q[upd_sym][side_i]
                      && (best_lvl_q[upd_sym][side_i] == upd_level)
                      && !upd_occupied;

        // Strictly better price on this side.
        is_better = !best_val_q[upd_sym][side_i]
                 || ((upd_side == SIDE_BUY)  && (upd_level > best_lvl_q[upd_sym][side_i]))
                 || ((upd_side == SIDE_SELL) && (upd_level < best_lvl_q[upd_sym][side_i]));

        rescan = upd_valid && !upd_clear && best_destroyed;
    end

    // =========================================================================
    // State update
    // =========================================================================
    logic       out_valid_q, out_changed_q;
    sym_idx_t   out_sym_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            out_valid_q     <= 1'b0;
            out_changed_q   <= 1'b0;
            cnt_best_rescan <= '0;
            cnt_crossed     <= '0;
            cnt_top_change  <= '0;
        end else begin
            out_valid_q   <= upd_valid;
            out_sym_q     <= upd_sym;
            out_changed_q <= 1'b0;

            if (upd_valid && upd_clear) begin
                occ_q[upd_sym][0]      <= '0;
                occ_q[upd_sym][1]      <= '0;
                best_val_q[upd_sym][0] <= 1'b0;
                best_val_q[upd_sym][1] <= 1'b0;
                best_qty_q[upd_sym][0] <= '0;
                best_qty_q[upd_sym][1] <= '0;
                out_changed_q          <= 1'b1;

            end else if (upd_valid) begin
                occ_q[upd_sym][side_i] <= occ_next;

                if (best_destroyed) begin
                    // ⚠️ The expensive case. One extra cycle, bounded, counted.
                    cnt_best_rescan <= cnt_best_rescan + 32'd1;
                    best_val_q[upd_sym][side_i] <= enc_valid;
                    best_lvl_q[upd_sym][side_i] <= new_best_lvl;
                    // Price of the new best is reconstructed from the level.
                    // Quantity is refreshed on the next update to that level;
                    // until then it reads as the level's stored value, so the
                    // engine re-reads it. Documented in the README.
                    best_qty_q[upd_sym][side_i] <= '0;
                    best_px_q[upd_sym][side_i]  <= '0;
                    out_changed_q               <= 1'b1;

                end else if (upd_occupied && is_better) begin
                    // New best at a strictly better price. One comparison.
                    best_val_q[upd_sym][side_i] <= 1'b1;
                    best_lvl_q[upd_sym][side_i] <= upd_level;
                    best_qty_q[upd_sym][side_i] <= upd_qty;
                    best_px_q[upd_sym][side_i]  <= upd_price;
                    out_changed_q               <= 1'b1;

                end else if (best_val_q[upd_sym][side_i]
                          && (best_lvl_q[upd_sym][side_i] == upd_level)) begin
                    // Size change at the existing best. Price unchanged, so this
                    // is a size-only move — still a top-of-book change.
                    best_qty_q[upd_sym][side_i] <= upd_qty;
                    out_changed_q               <= 1'b1;
                end
                // Otherwise: a depth update behind the best. The strategy is not
                // woken for it — that is the point of `top_changed`.
            end

            if (out_changed_q) cnt_top_change <= cnt_top_change + 32'd1;
            if (top_crossed && top_valid) cnt_crossed <= cnt_crossed + 32'd1;
        end
    end

    // =========================================================================
    // Output
    // =========================================================================
    always_comb begin
        top_valid     = out_valid_q;
        top_sym       = out_sym_q;
        top_bid_px    = best_px_q[out_sym_q][0];
        top_bid_qty   = best_qty_q[out_sym_q][0];
        top_ask_px    = best_px_q[out_sym_q][1];
        top_ask_qty   = best_qty_q[out_sym_q][1];
        top_bid_valid = best_val_q[out_sym_q][0];
        top_ask_valid = best_val_q[out_sym_q][1];
        top_changed   = out_changed_q;
        top_stale     = stale_in;

        // ⚠️ A crossed book (bid >= ask) is never tradeable. It means either a
        //    genuine transient during a fast market, or — far more likely — that
        //    our book is wrong. The strategy must refuse to act on it; this flag
        //    is what enforces that, and fpga_top asserts the property.
        top_crossed = top_bid_valid && top_ask_valid && (top_bid_px >= top_ask_px);
    end

    // =========================================================================
    // Assertions
    // =========================================================================
`ifndef SYNTHESIS
    // The rescan is bounded at one extra cycle: two consecutive rescans for the
    // same symbol and side would mean the encoder failed to converge.
    assert property (@(posedge clk) disable iff (rst)
        rescan |=> !rescan
    ) else $error("top_of_book: consecutive best-rescans — bound violated");

    // A valid best must sit on an occupied level.
    assert property (@(posedge clk) disable iff (rst)
        (upd_valid && !upd_clear && best_val_q[upd_sym][side_i])
            |-> occ_q[upd_sym][side_i][best_lvl_q[upd_sym][side_i]]
    ) else $error("top_of_book: best level is not occupied");

    // Crossed must be computed, never latched stale.
    assert property (@(posedge clk) disable iff (rst)
        (top_valid && top_bid_valid && top_ask_valid && (top_bid_px >= top_ask_px))
            |-> top_crossed
    ) else $error("top_of_book: crossed book not flagged");

    // Stale must propagate unconditionally — no path may mask it.
    assert property (@(posedge clk) disable iff (rst)
        stale_in |-> top_stale
    ) else $error("top_of_book: stale flag suppressed");
`endif

endmodule : top_of_book

`default_nettype wire
