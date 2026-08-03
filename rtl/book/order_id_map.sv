// =============================================================================
// order_id_map.sv — order reference -> resting order record
// -----------------------------------------------------------------------------
// LATENCY  : 2 cycles (12.8 ns @ 156.25 MHz), fixed. Lookup and update are
//            pipelined; there is no stall in the common case.
// RESOURCE : 4 ways x 16384 sets x ~140 bits ~= 9.2 Mbit.
//            Estimate ~32 URAM288 (or ~256 BRAM36). Verify against the
//            post-synthesis utilization report — this is the largest single
//            memory consumer in the design.
// Governing manual: manuals/04-system-architecture/03-order-book-in-hardware.md
//
// WHY THIS BLOCK EXISTS
// ---------------------
// ITCH Execute/Cancel/Delete/Replace messages carry only a 64-bit order
// reference. This map is what turns that reference back into
// {symbol, side, price, remaining quantity} so the price level can be updated.
//
// ⚠️ CORRECTNESS OVER CAPACITY. If this table cannot hold an order, the book
//    WILL diverge from the venue's book — the quantity that order contributed
//    can never be removed, because the delete message that would remove it
//    resolves to nothing. There is no recovery except a resync. So a failed
//    insert marks the book STALE rather than being quietly counted.
//    A book that is subtly wrong is the most expensive defect in this system:
//    it produces plausible prices, so nothing alarms, and the strategy trades
//    on them.
// =============================================================================
`default_nettype none

module order_id_map
    import trading_pkg::*;
    import book_pkg::*;
(
    input  var logic         clk,
    input  var logic         rst,

    // ── Request ──────────────────────────────────────────────────────────────
    input  var logic         req_valid,
    input  var book_op_e     req_op,
    input  var order_ref_t   req_key,        // reference being acted on
    input  var order_ref_t   req_new_key,    // BOOK_REPLACE only
    input  var sym_idx_t     req_sym,        // BOOK_ADD only
    input  var side_e        req_side,       // BOOK_ADD only
    input  var price_t       req_price,      // BOOK_ADD / BOOK_REPLACE
    input  var qty_t         req_qty,        // add: absolute; exec/cancel: delta

    // ── Result, 2 cycles later ───────────────────────────────────────────────
    output var logic         res_valid,
    output var logic         res_hit,        // the key was present
    output var sym_idx_t     res_sym,
    output var side_e        res_side,
    output var price_t       res_price,
    output var qty_t         res_delta,      // quantity to remove from the level
    output var qty_t         res_add,        // quantity to add to a level
    output var logic         res_remove,     // order fully consumed, entry freed

    // ── Health ───────────────────────────────────────────────────────────────
    output var logic         map_stale,      // ⚠️ sticky: the book can no longer
                                             //    be trusted until a resync
    output var logic [31:0]  cnt_insert,
    output var logic [31:0]  cnt_insert_fail,
    output var logic [31:0]  cnt_miss,
    output var logic [31:0]  cnt_delete,
    output var logic [31:0]  cnt_forward,    // RMW bypasses taken
    output var logic [15:0]  occupancy_hi    // high-water ways-used, for sizing
);

    // =========================================================================
    // Storage — one memory per way so a set is read in parallel in one cycle.
    // =========================================================================
    order_rec_t mem [MAP_WAYS][MAP_SETS];

    // ⚠️ Memories cannot be cleared by `rst`. Power-on state is zeroed here so
    //    `valid` starts low; a real device also needs the host to issue
    //    BOOK_CLEAR at start of day. Do not rely on this alone.
    initial begin
        for (int unsigned w = 0; w < MAP_WAYS; w++)
            for (int unsigned s = 0; s < MAP_SETS; s++)
                mem[w][s] = '0;
    end

    // =========================================================================
    // Stage 0 — hash and issue the set read
    // =========================================================================
    logic [MAP_SET_W-1:0] s0_set, s0_set_new;
    logic                 s0_valid;
    book_op_e             s0_op;
    order_ref_t           s0_key, s0_new_key;
    sym_idx_t             s0_sym;
    side_e                s0_side;
    price_t               s0_price;
    qty_t                 s0_qty;

    always_comb begin
        s0_set     = map_hash(req_key);
        s0_set_new = map_hash(req_new_key);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            s0_valid <= 1'b0;
        end else begin
            s0_valid <= req_valid && (req_op != BOOK_NOP);
        end
        s0_op      <= req_op;
        s0_key     <= req_key;
        s0_new_key <= req_new_key;
        s0_sym     <= req_sym;
        s0_side    <= req_side;
        s0_price   <= req_price;
        s0_qty     <= req_qty;
    end

    logic [MAP_SET_W-1:0] s1_set, s1_set_new;
    always_ff @(posedge clk) begin
        s1_set     <= s0_set;
        s1_set_new <= s0_set_new;
    end

    // Registered set read, one port per way.
    order_rec_t s1_way [MAP_WAYS];
    always_ff @(posedge clk) begin
        for (int unsigned w = 0; w < MAP_WAYS; w++)
            s1_way[w] <= mem[w][s0_set];
    end

    // =========================================================================
    // Stage 1 — match, and apply the write-forwarding bypass
    // =========================================================================
    // ⚠️ THE READ-MODIFY-WRITE HAZARD. Two ITCH messages for the same order
    //    reference can arrive in consecutive cycles — an Execute immediately
    //    followed by a Delete is common at the top of book. The second message's
    //    set read was issued BEFORE the first message's write landed, so it sees
    //    stale quantity.
    //
    //    Resolution: FORWARD. The in-flight write from the previous message is
    //    compared against this message's key, and forwarded combinationally when
    //    they match. Chosen over stalling because a stall injects jitter into
    //    the one path that must stay deterministic, and because the forward is
    //    a 64-bit compare plus a mux — cheap.
    //    Every forward is COUNTED so the rate is observable rather than assumed.

    // Write-back record from the previous message (stage 2 result).
    logic                 wb_en;
    logic [MAP_SET_W-1:0] wb_set;
    logic [$clog2(MAP_WAYS)-1:0] wb_way;
    order_rec_t           wb_rec;

    order_rec_t s1_eff [MAP_WAYS];
    logic       s1_fwd;

    always_comb begin
        s1_fwd = 1'b0;
        for (int unsigned w = 0; w < MAP_WAYS; w++) begin
            s1_eff[w] = s1_way[w];
            if (wb_en && (wb_set == s1_set) && (wb_way == w[$clog2(MAP_WAYS)-1:0])) begin
                s1_eff[w] = wb_rec;
                s1_fwd    = 1'b1;
            end
        end
    end

    // Match against the full key.
    logic [MAP_WAYS-1:0]         s1_match;
    logic [MAP_WAYS-1:0]         s1_free;
    logic [$clog2(MAP_WAYS)-1:0] s1_match_way, s1_free_way;
    logic                        s1_hit, s1_has_free;

    always_comb begin
        s1_match     = '0;
        s1_free      = '0;
        s1_match_way = '0;
        s1_free_way  = '0;
        s1_hit       = 1'b0;
        s1_has_free  = 1'b0;
        for (int unsigned w = 0; w < MAP_WAYS; w++) begin
            if (s1_eff[w].valid && (s1_eff[w].key == s0_key)) begin
                s1_match[w] = 1'b1;
                if (!s1_hit) begin
                    s1_match_way = w[$clog2(MAP_WAYS)-1:0];
                    s1_hit       = 1'b1;
                end
            end
            if (!s1_eff[w].valid) begin
                s1_free[w] = 1'b1;
                if (!s1_has_free) begin
                    s1_free_way = w[$clog2(MAP_WAYS)-1:0];
                    s1_has_free = 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // Stage 2 — decide the mutation, drive the result and the write-back
    // =========================================================================
    order_rec_t rec;
    qty_t       new_qty;
    logic       full_consume;

    always_comb begin
        rec          = s1_eff[s1_match_way];
        // Saturating: an execution larger than the resting quantity is a decode
        // error or a gap, never a negative book.
        full_consume = (s1_op == BOOK_DELETE) || (s0_qty >= rec.qty);
        new_qty      = full_consume ? '0 : (rec.qty - s0_qty);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            res_valid       <= 1'b0;
            wb_en           <= 1'b0;
            map_stale       <= 1'b0;
            cnt_insert      <= '0;
            cnt_insert_fail <= '0;
            cnt_miss        <= '0;
            cnt_delete      <= '0;
            cnt_forward     <= '0;
            occupancy_hi    <= '0;
        end else begin
            res_valid  <= s0_valid;
            res_hit    <= 1'b0;
            res_sym    <= '0;
            res_side   <= SIDE_BUY;
            res_price  <= '0;
            res_delta  <= '0;
            res_add    <= '0;
            res_remove <= 1'b0;
            wb_en      <= 1'b0;

            if (s1_fwd) cnt_forward <= cnt_forward + 32'd1;

            if (s0_valid) begin
                unique case (s0_op)

                    // ── ADD: insert a new resting order ──────────────────────
                    BOOK_ADD: begin
                        if (s1_has_free) begin
                            wb_en  <= 1'b1;
                            wb_set <= s1_set;
                            wb_way <= s1_free_way;
                            wb_rec <= '{valid: 1'b1,
                                        key:   s0_key,
                                        sym:   s0_sym,
                                        side:  s0_side,
                                        price: s0_price,
                                        qty:   s0_qty};
                            res_hit   <= 1'b1;
                            res_sym   <= s0_sym;
                            res_side  <= s0_side;
                            res_price <= s0_price;
                            res_add   <= s0_qty;
                            cnt_insert <= cnt_insert + 32'd1;
                        end else begin
                            // ⚠️ Set full. We CANNOT evict — evicting a live
                            //    order means its eventual delete resolves to
                            //    nothing and its quantity is stranded in the
                            //    level forever. The book is now unreliable.
                            cnt_insert_fail <= cnt_insert_fail + 32'd1;
                            map_stale       <= 1'b1;   // sticky until resync
                        end
                    end

                    // ── EXECUTE / CANCEL: reduce, possibly remove ────────────
                    BOOK_EXECUTE,
                    BOOK_CANCEL: begin
                        if (s1_hit) begin
                            res_hit    <= 1'b1;
                            res_sym    <= rec.sym;
                            res_side   <= rec.side;
                            res_price  <= rec.price;
                            res_delta  <= full_consume ? rec.qty : s0_qty;
                            res_remove <= full_consume;
                            wb_en  <= 1'b1;
                            wb_set <= s1_set;
                            wb_way <= s1_match_way;
                            wb_rec <= '{valid: !full_consume,
                                        key:   rec.key,
                                        sym:   rec.sym,
                                        side:  rec.side,
                                        price: rec.price,
                                        qty:   new_qty};
                            if (full_consume) cnt_delete <= cnt_delete + 32'd1;
                        end else begin
                            // A reference we never saw added. Means a gap or a
                            // decode bug. Either way the book is suspect.
                            cnt_miss  <= cnt_miss + 32'd1;
                            map_stale <= 1'b1;
                        end
                    end

                    // ── DELETE: remove outright ──────────────────────────────
                    BOOK_DELETE: begin
                        if (s1_hit) begin
                            res_hit    <= 1'b1;
                            res_sym    <= rec.sym;
                            res_side   <= rec.side;
                            res_price  <= rec.price;
                            res_delta  <= rec.qty;
                            res_remove <= 1'b1;
                            wb_en      <= 1'b1;
                            wb_set     <= s1_set;
                            wb_way     <= s1_match_way;
                            wb_rec     <= '0;
                            cnt_delete <= cnt_delete + 32'd1;
                        end else begin
                            cnt_miss  <= cnt_miss + 32'd1;
                            map_stale <= 1'b1;
                        end
                    end

                    // ── REPLACE: old reference out, NEW reference in ─────────
                    // ⚠️ ITCH 'U' does NOT modify in place. It cancels the
                    //    original reference and creates a new one with a new
                    //    reference number. A book that treats it as an in-place
                    //    edit leaks the old reference and loses queue priority
                    //    semantics. Handled here as delete-then-add; the engine
                    //    sees both a removal and an addition.
                    BOOK_REPLACE: begin
                        if (s1_hit) begin
                            res_hit    <= 1'b1;
                            res_sym    <= rec.sym;
                            res_side   <= rec.side;
                            res_price  <= rec.price;
                            res_delta  <= rec.qty;      // remove the old level qty
                            res_remove <= 1'b1;
                            res_add    <= s0_qty;       // add at the new price
                            wb_en      <= 1'b1;
                            wb_set     <= s1_set;
                            wb_way     <= s1_match_way;
                            wb_rec     <= '0;           // free the old entry
                            // The new reference is inserted by the engine
                            // re-issuing a BOOK_ADD on the following cycle.
                            cnt_delete <= cnt_delete + 32'd1;
                        end else begin
                            cnt_miss  <= cnt_miss + 32'd1;
                            map_stale <= 1'b1;
                        end
                    end

                    BOOK_CLEAR: begin
                        map_stale <= 1'b0;   // resync clears the sticky flag
                    end

                    default: ; // BOOK_NOP
                endcase
            end

            // Occupancy high-water, for capacity sizing in production.
            if (s0_valid && !s1_has_free && (occupancy_hi < 16'(MAP_WAYS)))
                occupancy_hi <= 16'(MAP_WAYS);
        end
    end

    // =========================================================================
    // Write port
    // =========================================================================
    always_ff @(posedge clk) begin
        if (wb_en) mem[wb_way][wb_set] <= wb_rec;
    end

    // =========================================================================
    // Assertions
    // =========================================================================
`ifndef SYNTHESIS
    // A record must never carry a valid flag with zero quantity — that is a
    // stranded entry that will never be freed.
    assert property (@(posedge clk) disable iff (rst)
        wb_en |-> (wb_rec.valid -> (wb_rec.qty != '0))
    ) else $error("order_id_map: valid record written with zero qty");

    // Quantity must never increase on an execute or cancel.
    assert property (@(posedge clk) disable iff (rst)
        (s0_valid && s1_hit && (s0_op inside {BOOK_EXECUTE, BOOK_CANCEL}))
            |-> (new_qty <= rec.qty)
    ) else $error("order_id_map: quantity increased on a reduce");

    // Replace must genuinely change the reference.
    assert property (@(posedge clk) disable iff (rst)
        (s0_valid && (s0_op == BOOK_REPLACE)) |-> (s0_new_key != s0_key)
    ) else $error("order_id_map: BOOK_REPLACE with identical old/new reference");

    // Stale is sticky: it must never clear except on BOOK_CLEAR.
    assert property (@(posedge clk) disable iff (rst)
        ($fell(map_stale)) |-> $past(s0_valid && (s0_op == BOOK_CLEAR))
    ) else $error("order_id_map: stale flag cleared without a resync");
`endif

endmodule : order_id_map

`default_nettype wire
