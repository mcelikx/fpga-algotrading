// =============================================================================
// top_of_book.sv — incremental best bid / best ask maintenance
// -----------------------------------------------------------------------------
// PURPOSE
//   Structure 3 of the order book: the derived top of book, maintained
//   INCREMENTALLY from price_levels' per-update result and never recomputed.
//   Holds a cached second best per symbol per side so that the common
//   delete-the-best case is resolved with no extra cycles at all.
//
// LATENCY  : 1 cycle (6.4 ns @ 156.25 MHz) for every update, including a
//            best-level delete that the cached second best covers.
//            3 cycles (19.2 ns) when the second-best cache misses and the new
//            best must be found: +1 to priority-encode the occupancy word, +1
//            to fetch that level's TRUE quantity from the level array, then
//            publish. This is the ONLY variable-latency operation in the entire
//            tick-to-trade path. It is bounded, counted (`cnt_best_rescan`) and,
//            per manual §6.4, expected on order 1 % of book messages.
//            The quantity fetch shares price_levels' read port with the fast
//            path and yields to it, so a rescan can wait additional cycles under
//            a burst. The wait is counted; the state is never wrong, only later.
//
// RESOURCE : (N_ACTIVE=256, N_LEVELS=2048)
//            best + second best, both sides
//              2 records x 256 sym x 2 sides x (1 valid + 11 level + 32 price
//              + 32 qty = 76 bit)                            = 77,824 FF
//              (two write ports — the fast path and the rescan commit — so this
//               is a register file, not LUTRAM. Halving N_ACTIVE to the manual's
//               128 symbols halves it.)
//            per-symbol stale                                 =    256 FF
//            2048-bit priority encoder (64 groups x 32)       ~ 1.8-2.4 kLUT
//            bid-side mask reflection (2048-bit 2:1 mux)      ~   2.0 kLUT
//            2 x 512-entry x 76-bit read mux                  ~    26 kLUT
//            0 BRAM. 0 URAM. 0 DSP.
//            > Verify against the post-synthesis utilization report. Nothing in
//              this file has been synthesized, simulated, or linted.
//
// Governing manual: manuals/04-system-architecture/03-order-book-in-hardware.md
//                   §6 (incremental top of book, the rescan, the second-best
//                       cache)  §7 (publish depth)
//                   manuals/01-fpga-design/01-rtl-design-patterns.md §6
//                   manuals/00-foundations/03-hdl-and-rtl-coding.md
//                   docs/ORDER-BOOK-REDESIGN.md §2.1, §3.4
//
// -----------------------------------------------------------------------------
// ⚠️ THE DEFECT THIS FILE EXISTS TO FIX. The previous revision found the correct
//    new best LEVEL with a priority encoder and then wrote:
//        best_qty_q[sym][side] <= '0;
//        best_px_q [sym][side] <= '0;      // price set to ZERO
//    After the first best-level delete — which happens continuously in any
//    active book — the system published bid = $0.00 and every downstream
//    consumer acted on it. The price is trivially recoverable from the level:
//        price = window_base + level x TICK_UNITS
//    and the quantity is recoverable by reading the level array. Both are done
//    here, and an assertion below fails if a published best ever carries a zero
//    price or a zero quantity. See docs/ORDER-BOOK-REDESIGN.md §2.1.
//
// ⚠️ THE CORE RULE: NEVER RECOMPUTE A MAX OVER ALL LEVELS. A comparator tree
//    over 2048 levels is 11 levels deep — more than the entire book budget, paid
//    on EVERY message. The best is maintained incrementally: the updated level
//    is compared against the current best, one comparison, one cycle.
//
// ⚠️ THE ONE HARD CASE: deleting the current best. Three mitigations, in order:
//      (a) CACHED SECOND BEST. If it is valid, promotion is 0 extra cycles and
//          carries a true price and a true quantity, because both were
//          maintained incrementally alongside the best.
//      (b) OCCUPANCY BITMAP + HIERARCHICAL PRIORITY ENCODE. price_levels hands
//          over the post-update 2048-bit occupancy word for the touched side, so
//          finding the next occupied level is one encode, not a search.
//      (c) A LEVEL-ARRAY READ for that level's quantity. Publishing the level
//          without its quantity is what produced the defect above.
//    The second-best cache is deliberately NOT refilled by a second search after
//    a promotion — it refills from ordinary traffic, because any add or update
//    at a level between the new best and the old second best becomes the new
//    second best. Coverage is therefore traffic-dependent and is MEASURED
//    (`cnt_promote` against `cnt_best_rescan`), not assumed.
//
// ⚠️ WHILE THE BEST IS UNKNOWN, IT IS PUBLISHED AS INVALID. During a rescan the
//    side reports bid_valid / ask_valid = 0 rather than the deleted price. That
//    is the honest answer and the safe one — the strategy is gated on it — and
//    it lasts 2 cycles in the normal case.
// =============================================================================
`default_nettype none

module top_of_book
    import trading_pkg::*;
    import book_pkg::*;
#(
    // Must match price_levels. Tracks book_pkg::LEVELS; the manual specifies
    // 2048 and R6 must set trading_pkg::BOOK_LEVELS accordingly.
    parameter int unsigned N_LEVELS = book_pkg::LEVELS,
    // Pipeline depth of the new-best priority encoder. 1 = registered output.
    // See the instantiation for why 0 is not acceptable at N_LEVELS = 2048.
    parameter int unsigned ENC_PIPE = 1,
    // DERIVED — never override at an instantiation site.
    parameter int unsigned LVL_W    = (N_LEVELS > 1) ? $clog2(N_LEVELS) : 1
) (
    input  var logic       clk,
    input  var logic       rst,

    // ── Level update from price_levels ───────────────────────────────────────
    input  var logic       upd_valid,
    input  var sym_idx_t   upd_sym,
    input  var side_e      upd_side,
    input  var logic [LVL_W-1:0] upd_level,
    input  var price_t     upd_price,
    input  var price_t     upd_base,      // window base, for price reconstruction
    input  var qty_t       upd_qty,       // level quantity AFTER the update
    input  var logic       upd_occupied,
    input  var logic       upd_in_window, // 0 = rejected, do not touch the book
    input  var logic       upd_clear,     // BOOK_CLEAR: wipe this symbol
    input  var logic       upd_stale,     // this SYMBOL is stale
    input  var logic [N_LEVELS-1:0] upd_occ, // post-update occupancy, upd_side

    // ── Level-array quantity fetch (to price_levels port B) ─────────────────
    output var logic       lk_valid,
    output var sym_idx_t   lk_sym,
    output var side_e      lk_side,
    output var logic [LVL_W-1:0] lk_level,
    input  var logic       lk_ready,
    input  var logic       lk_ack,
    input  var qty_t       lk_qty,

    // ── Stale propagation ────────────────────────────────────────────────────
    input  var logic       stale_in,      // global (order map)

    // ── Top of book out (registered) ─────────────────────────────────────────
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
    output var logic [31:0] cnt_best_rescan,    // the jitter source
    output var logic [31:0] cnt_promote,        // second-best cache hits
    output var logic [31:0] cnt_rescan_empty,   // side emptied inside the window
    output var logic [31:0] cnt_rescan_cancel,  // superseded by a fresher update
    output var logic [31:0] cnt_rescan_drop,    // ⚠️ engine busy -> symbol staled
    output var logic [31:0] cnt_lk_wait,        // cycles yielded to the fast path
    output var logic [31:0] cnt_crossed,        // ⚠️ crossed book observations
    output var logic [31:0] cnt_top_change,     // genuine top-of-book changes
    output var logic [31:0] cnt_pub_defer,      // rescan publish delayed 1 cycle
    output var logic [31:0] cnt_pub_drop        // ⚠️ a deferred publish was lost
);

    localparam int unsigned N_SIDES = 2;

    typedef logic [LVL_W-1:0] lvl_t;

    // Bid: a HIGHER level index is a better price. Ask: a LOWER one is.
    function automatic logic lvl_better(input logic is_buy,
                                        input lvl_t a,
                                        input lvl_t b);
        return is_buy ? (a > b) : (a < b);
    endfunction

    // =========================================================================
    // 1. Per-symbol, per-side state
    // =========================================================================
    // b1 = best, b2 = cached second best. The price is stored, not recomputed at
    // read time, so the publish path stays a pure mux; an assertion below proves
    // the stored price always equals base + level x tick.
    logic   b1v_q [N_ACTIVE][N_SIDES];
    lvl_t   b1l_q [N_ACTIVE][N_SIDES];
    price_t b1p_q [N_ACTIVE][N_SIDES];
    qty_t   b1q_q [N_ACTIVE][N_SIDES];
    logic   b2v_q [N_ACTIVE][N_SIDES];
    lvl_t   b2l_q [N_ACTIVE][N_SIDES];
    price_t b2p_q [N_ACTIVE][N_SIDES];
    qty_t   b2q_q [N_ACTIVE][N_SIDES];
    logic   sstale_q [N_ACTIVE];

    initial begin
        for (int unsigned s = 0; s < N_ACTIVE; s++) begin
            sstale_q[s] = 1'b0;
            for (int unsigned d = 0; d < N_SIDES; d++) begin
                b1v_q[s][d] = 1'b0;  b1l_q[s][d] = '0;
                b1p_q[s][d] = '0;    b1q_q[s][d] = '0;
                b2v_q[s][d] = 1'b0;  b2l_q[s][d] = '0;
                b2p_q[s][d] = '0;    b2q_q[s][d] = '0;
            end
        end
    end

    logic sidx, is_buy;
    assign sidx   = (upd_side == SIDE_SELL);
    assign is_buy = (upd_side == SIDE_BUY);

    // Current state for the touched entry, and the other side's best.
    logic   c1v, c2v, o1v;
    lvl_t   c1l, c2l;
    price_t c1p, c2p, o1p;
    qty_t   c1q, c2q, o1q;

    always_comb begin
        c1v = b1v_q[upd_sym][sidx];   c1l = b1l_q[upd_sym][sidx];
        c1p = b1p_q[upd_sym][sidx];   c1q = b1q_q[upd_sym][sidx];
        c2v = b2v_q[upd_sym][sidx];   c2l = b2l_q[upd_sym][sidx];
        c2p = b2p_q[upd_sym][sidx];   c2q = b2q_q[upd_sym][sidx];
        // The OTHER side of this symbol, forwarded past an in-flight rescan
        // commit landing on it in this very cycle. Without the bypass the beat
        // would publish a top of book whose opposite side is one cycle stale —
        // and on a rescan commit that stale value is the deleted best.
        o1v = b1v_q[upd_sym][!sidx];
        o1p = b1p_q[upd_sym][!sidx];
        o1q = b1q_q[upd_sym][!sidx];
        if (rs_commit && (rsL_sym_q == upd_sym) && (rsL_sidx_q != sidx)) begin
            o1v = 1'b1;
            o1p = rs_px;
            o1q = lk_qty;
        end
    end

    // =========================================================================
    // 2. Incremental update rules (manual §6.2, plus second-best maintenance)
    // =========================================================================
    // ⚠️ THE SUBTLE PART, and the single highest-value unit test in the book
    //    (manual §6.3b): an update at a level between the second best and the
    //    best must BECOME the new second best. Getting this wrong promotes a
    //    stale level and publishes a best that does not exist.
    logic   n1v, n2v, tob_touch, promoted;
    lvl_t   n1l, n2l;
    price_t n1p, n2p;
    qty_t   n1q, n2q;

    always_comb begin
        n1v = c1v; n1l = c1l; n1p = c1p; n1q = c1q;
        n2v = c2v; n2l = c2l; n2p = c2p; n2q = c2q;
        tob_touch = 1'b0;
        promoted  = 1'b0;

        if (upd_valid && upd_clear) begin
            // O(1) wipe. The level array and the occupancy bitmap are cleared by
            // price_levels in the same beat.
            n1v = 1'b0;
            n2v = 1'b0;
            tob_touch = 1'b1;
        end else if (upd_valid && upd_in_window) begin
            if (upd_occupied) begin
                if (!c1v || lvl_better(is_buy, upd_level, c1l)) begin
                    // Strictly better price. The old best becomes the second.
                    n2v = c1v; n2l = c1l; n2p = c1p; n2q = c1q;
                    n1v = 1'b1; n1l = upd_level; n1p = upd_price; n1q = upd_qty;
                    tob_touch = 1'b1;
                end else if (upd_level == c1l) begin
                    // Size change at the existing best.
                    n1q = upd_qty;
                    tob_touch = 1'b1;
                end else if (!c2v || lvl_better(is_buy, upd_level, c2l)) begin
                    n2v = 1'b1; n2l = upd_level; n2p = upd_price; n2q = upd_qty;
                end else if (upd_level == c2l) begin
                    n2q = upd_qty;
                end else begin
                    // Depth behind the cached second best. The strategy is not
                    // woken for it — that is the point of `top_changed`.
                    n1v = c1v;
                end
            end else begin
                if (c1v && (upd_level == c1l)) begin
                    // The expensive case, made cheap by the cache.
                    if (c2v) begin
                        n1v = 1'b1; n1l = c2l; n1p = c2p; n1q = c2q;
                        n2v = 1'b0;
                        promoted = 1'b1;
                    end else begin
                        n1v = 1'b0;
                    end
                    tob_touch = 1'b1;
                end else if (c2v && (upd_level == c2l)) begin
                    n2v = 1'b0;
                end else begin
                    n1v = c1v;
                end
            end
        end else begin
            // Rejected (out-of-window) update: the book is untouched. The stale
            // flag it carries is still published.
            n1v = c1v;
        end
    end

    // =========================================================================
    // 3. New-best search — the bounded, counted, variable-latency case
    // =========================================================================
    // A BID book's best is the HIGHEST occupied level; an ASK book's is the
    // LOWEST. The encoder finds the lowest set bit, so the bid mask is reflected
    // before encoding and the index reflected back afterwards. Reflection is
    // pure routing.
    logic [N_LEVELS-1:0] search_mask;

    always_comb begin
        search_mask = '0;
        for (int unsigned b = 0; b < N_LEVELS; b++) begin
            search_mask[b] = is_buy ? upd_occ[N_LEVELS - 1 - b] : upd_occ[b];
        end
    end

    lvl_t enc_idx;
    logic enc_valid;

    // ⚠️ At N_LEVELS = 2048 this must elaborate as a HIERARCHICAL encoder of 64
    //    groups x 32 (GROUP = 32 ~ sqrt(N)) with a registered output. A flat
    //    2048-input priority chain is a deep LUT chain and will not close 6.4 ns
    //    (manuals/00-foundations/03 §7). Only N and PIPELINE are set here; the
    //    grouping is prio_encoder's to derive (task R4). If the encoder still
    //    defaults to a narrow GROUP the design remains FUNCTIONALLY correct and
    //    only loses Fmax — this is a timing contract, not a correctness one.
    prio_encoder #(
        .N        (N_LEVELS),
        .PIPELINE (ENC_PIPE)
    ) u_best_enc (
        .clk   (clk),
        .rst   (rst),
        .req   (search_mask),
        .idx   (enc_idx),
        .valid (enc_valid)
    );

    // ── Rescan stage E: launched with the beat, encoder result next cycle ────
    logic     rsE_v_q, rsE_buy_q, rsE_sidx_q;
    sym_idx_t rsE_sym_q;
    price_t   rsE_base_q;

    // ── Rescan stage L: level known, waiting for its quantity ────────────────
    logic     rsL_v_q, rsL_sidx_q, rsL_fired_q;
    sym_idx_t rsL_sym_q;
    price_t   rsL_base_q;
    lvl_t     rsL_lvl_q;

    // Launch whenever, after this beat, the best would be UNKNOWN while the side
    // still holds occupied levels. That single condition covers the best-level
    // delete, a cancelled rescan, and any other path that leaves b1 invalid, so
    // the best can never be left permanently unknown on a non-empty side.
    logic rs_launch, rs_any_occ;
    assign rs_any_occ = |upd_occ;
    assign rs_launch  = upd_valid && !n1v && rs_any_occ;

    // The reflected index. N_LEVELS is a power of two, so N_LEVELS-1-idx is a
    // bitwise complement — no adder.
    lvl_t enc_lvl;
    assign enc_lvl = rsE_buy_q ? (lvl_t'(N_LEVELS - 1) - enc_idx) : enc_idx;

    // A fresher update for the same symbol and side supersedes an in-flight
    // rescan: that update carries its own post-update occupancy word and will
    // either set the best directly or launch a new search.
    logic rs_cancel_e, rs_cancel_l;
    assign rs_cancel_e = rsE_v_q && upd_valid && (upd_sym == rsE_sym_q)
                                 && (sidx == rsE_sidx_q);
    assign rs_cancel_l = rsL_v_q && upd_valid && (upd_sym == rsL_sym_q)
                                 && (sidx == rsL_sidx_q);

    logic rs_e_go, rs_e_empty, rs_e_drop, rs_l_free, rsL_retire;
    assign rsL_retire = rs_commit || rs_cancel_l;
    assign rs_l_free  = !rsL_v_q || rsL_retire;
    assign rs_e_empty = rsE_v_q && !rs_cancel_e && !enc_valid;
    assign rs_e_go    = rsE_v_q && !rs_cancel_e &&  enc_valid &&  rs_l_free;
    assign rs_e_drop  = rsE_v_q && !rs_cancel_e &&  enc_valid && !rs_l_free;

    // Quantity fetch handshake. price_levels yields the read port to the fast
    // path, so this can wait; the wait is counted, never hidden.
    assign lk_valid = rsL_v_q && !rsL_fired_q;
    assign lk_sym   = rsL_sym_q;
    assign lk_side  = rsL_sidx_q ? SIDE_SELL : SIDE_BUY;
    assign lk_level = rsL_lvl_q;

    logic lk_go, rs_commit;
    assign lk_go     = lk_valid && lk_ready;
    assign rs_commit = rsL_v_q && rsL_fired_q && lk_ack && !rs_cancel_l;

    price_t rs_px;
    assign rs_px = rsL_base_q + (price_t'(rsL_lvl_q) * price_t'(TICK_UNITS));

    always_ff @(posedge clk) begin
        if (rst) begin
            rsE_v_q     <= 1'b0;
            rsL_v_q     <= 1'b0;
            rsL_fired_q <= 1'b0;
        end else begin
            // Stage E
            if (rs_launch) begin
                rsE_v_q <= 1'b1;
            end else if (rsE_v_q) begin
                rsE_v_q <= 1'b0;      // consumed, cancelled, empty, or dropped
            end

            // Stage L. rs_e_go already requires rs_l_free, which includes the
            // cycle L retires in, so a back-to-back rescan does not stall.
            if (rs_e_go) begin
                rsL_v_q     <= 1'b1;
                rsL_fired_q <= 1'b0;
            end else if (rsL_retire) begin
                rsL_v_q     <= 1'b0;
                rsL_fired_q <= 1'b0;
            end else if (lk_go) begin
                rsL_fired_q <= 1'b1;
            end
        end

        if (rs_launch) begin
            rsE_sym_q  <= upd_sym;
            rsE_sidx_q <= sidx;
            rsE_buy_q  <= is_buy;
            rsE_base_q <= upd_base;
        end
        if (rs_e_go) begin
            rsL_sym_q  <= rsE_sym_q;
            rsL_sidx_q <= rsE_sidx_q;
            rsL_base_q <= rsE_base_q;
            rsL_lvl_q  <= enc_lvl;
        end
    end

    // =========================================================================
    // 4. State write-back
    // =========================================================================
    // Two write ports: the fast path (upd_*) and the rescan commit. They can
    // never target the same entry in the same cycle, because an update for the
    // rescan's symbol and side cancels the rescan (asserted below).
    always_ff @(posedge clk) begin
        if (upd_valid) begin
            b1v_q[upd_sym][sidx] <= n1v;
            b1l_q[upd_sym][sidx] <= n1l;
            b1p_q[upd_sym][sidx] <= n1p;
            b1q_q[upd_sym][sidx] <= n1q;
            b2v_q[upd_sym][sidx] <= n2v;
            b2l_q[upd_sym][sidx] <= n2l;
            b2p_q[upd_sym][sidx] <= n2p;
            b2q_q[upd_sym][sidx] <= n2q;
            if (upd_clear) begin
                b1v_q[upd_sym][!sidx] <= 1'b0;
                b2v_q[upd_sym][!sidx] <= 1'b0;
            end
        end

        if (rs_commit) begin
            b1v_q[rsL_sym_q][rsL_sidx_q] <= 1'b1;
            b1l_q[rsL_sym_q][rsL_sidx_q] <= rsL_lvl_q;
            b1p_q[rsL_sym_q][rsL_sidx_q] <= rs_px;
            b1q_q[rsL_sym_q][rsL_sidx_q] <= lk_qty;
            b2v_q[rsL_sym_q][rsL_sidx_q] <= 1'b0;
        end

        // Per-symbol stale. A dropped rescan means the best for that symbol is
        // unknown and no search is in flight — fail loud rather than publish a
        // book we cannot vouch for.
        if (upd_valid) sstale_q[upd_sym]    <= upd_stale;
        if (rs_e_drop) sstale_q[rsE_sym_q]  <= 1'b1;
    end

    // =========================================================================
    // 5. Publish
    // =========================================================================
    // One registered output bus. Sources, in priority order:
    //   1. the incoming beat            — fast path, must never be delayed
    //   2. a rescan commit              — takes a free cycle
    //   3. a deferred rescan commit     — snapshot taken when 1 and 2 collided
    // A deferred publish only delays notification; the state behind it is
    // already correct and the next beat for that symbol republishes it.
    logic     pubd_v_q, pubd_bv_q, pubd_av_q, pubd_st_q;
    sym_idx_t pubd_sym_q;
    price_t   pubd_bpx_q, pubd_apx_q;
    qty_t     pubd_bq_q, pubd_aq_q;

    // ── candidate 1: the incoming beat ───────────────────────────────────────
    logic   u_bv, u_av;
    price_t u_bpx, u_apx;
    qty_t   u_bq, u_aq;

    always_comb begin
        u_bv  = sidx ? o1v : n1v;
        u_bpx = sidx ? o1p : n1p;
        u_bq  = sidx ? o1q : n1q;
        u_av  = sidx ? n1v : o1v;
        u_apx = sidx ? n1p : o1p;
        u_aq  = sidx ? n1q : o1q;
    end

    // ── candidate 2: the rescan commit ───────────────────────────────────────
    logic   r_ov;
    price_t r_op;
    qty_t   r_oq;
    logic   r_bv, r_av;
    price_t r_bpx, r_apx;
    qty_t   r_bq, r_aq;

    always_comb begin
        // Same bypass in the other direction: a beat updating the opposite side
        // of the rescanned symbol in this cycle is fresher than the array.
        r_ov  = b1v_q[rsL_sym_q][!rsL_sidx_q];
        r_op  = b1p_q[rsL_sym_q][!rsL_sidx_q];
        r_oq  = b1q_q[rsL_sym_q][!rsL_sidx_q];
        if (upd_valid && (upd_sym == rsL_sym_q) && (sidx != rsL_sidx_q)) begin
            r_ov = n1v;
            r_op = n1p;
            r_oq = n1q;
        end
        r_bv  = rsL_sidx_q ? r_ov  : 1'b1;
        r_bpx = rsL_sidx_q ? r_op  : rs_px;
        r_bq  = rsL_sidx_q ? r_oq  : lk_qty;
        r_av  = rsL_sidx_q ? 1'b1  : r_ov;
        r_apx = rsL_sidx_q ? rs_px : r_op;
        r_aq  = rsL_sidx_q ? lk_qty: r_oq;
    end

    // ── arbitrate ────────────────────────────────────────────────────────────
    logic     pub_v, pub_bv, pub_av, pub_chg, pub_st;
    sym_idx_t pub_sym;
    price_t   pub_bpx, pub_apx;
    qty_t     pub_bq, pub_aq;
    logic     pub_defer;

    always_comb begin
        pub_v     = 1'b0;
        pub_sym   = upd_sym;
        pub_bv    = 1'b0;
        pub_av    = 1'b0;
        pub_bpx   = '0;
        pub_apx   = '0;
        pub_bq    = '0;
        pub_aq    = '0;
        pub_chg   = 1'b0;
        pub_st    = stale_in;
        pub_defer = 1'b0;

        if (upd_valid) begin
            pub_v     = 1'b1;
            pub_sym   = upd_sym;
            pub_bv    = u_bv;   pub_bpx = u_bpx;  pub_bq = u_bq;
            pub_av    = u_av;   pub_apx = u_apx;  pub_aq = u_aq;
            pub_chg   = tob_touch;
            pub_st    = stale_in || upd_stale;
            pub_defer = rs_commit;
        end else if (rs_commit) begin
            pub_v     = 1'b1;
            pub_sym   = rsL_sym_q;
            pub_bv    = r_bv;   pub_bpx = r_bpx;  pub_bq = r_bq;
            pub_av    = r_av;   pub_apx = r_apx;  pub_aq = r_aq;
            pub_chg   = 1'b1;
            pub_st    = stale_in || sstale_q[rsL_sym_q];
        end else if (pubd_v_q) begin
            pub_v     = 1'b1;
            pub_sym   = pubd_sym_q;
            pub_bv    = pubd_bv_q;  pub_bpx = pubd_bpx_q;  pub_bq = pubd_bq_q;
            pub_av    = pubd_av_q;  pub_apx = pubd_apx_q;  pub_aq = pubd_aq_q;
            pub_chg   = 1'b1;
            pub_st    = stale_in || pubd_st_q;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            pubd_v_q <= 1'b0;
        end else if (pub_defer) begin
            pubd_v_q <= 1'b1;
        end else if (pubd_v_q && !upd_valid && !rs_commit) begin
            pubd_v_q <= 1'b0;
        end

        if (pub_defer) begin
            pubd_sym_q <= rsL_sym_q;
            pubd_bv_q  <= r_bv;   pubd_bpx_q <= r_bpx;  pubd_bq_q <= r_bq;
            pubd_av_q  <= r_av;   pubd_apx_q <= r_apx;  pubd_aq_q <= r_aq;
            pubd_st_q  <= sstale_q[rsL_sym_q];
        end
    end

    // ⚠️ A crossed book (bid >= ask) is never tradeable. It means either a
    //    genuine transient in a fast market, or — far more likely — that our
    //    book is wrong. The strategy must refuse to act on it; this flag is what
    //    enforces that, and fpga_top asserts the property.
    logic pub_crossed;
    assign pub_crossed = pub_bv && pub_av && (pub_bpx >= pub_apx);

    always_ff @(posedge clk) begin
        if (rst) begin
            top_valid   <= 1'b0;
            top_changed <= 1'b0;
        end else begin
            top_valid   <= pub_v;
            top_changed <= pub_v && pub_chg;
        end
        top_sym       <= pub_sym;
        top_bid_px    <= pub_bpx;
        top_bid_qty   <= pub_bq;
        top_ask_px    <= pub_apx;
        top_ask_qty   <= pub_aq;
        top_bid_valid <= pub_bv;
        top_ask_valid <= pub_av;
        top_crossed   <= pub_crossed;
        top_stale     <= pub_st;
    end

    // =========================================================================
    // 6. Health counters
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_best_rescan   <= '0;
            cnt_promote       <= '0;
            cnt_rescan_empty  <= '0;
            cnt_rescan_cancel <= '0;
            cnt_rescan_drop   <= '0;
            cnt_lk_wait       <= '0;
            cnt_crossed       <= '0;
            cnt_top_change    <= '0;
            cnt_pub_defer     <= '0;
            cnt_pub_drop      <= '0;
        end else begin
            if (rs_launch)                cnt_best_rescan   <= cnt_best_rescan   + 32'd1;
            if (upd_valid && promoted)    cnt_promote       <= cnt_promote       + 32'd1;
            if (rs_e_empty)               cnt_rescan_empty  <= cnt_rescan_empty  + 32'd1;
            if (rs_cancel_e || rs_cancel_l)
                                          cnt_rescan_cancel <= cnt_rescan_cancel + 32'd1;
            if (rs_e_drop)                cnt_rescan_drop   <= cnt_rescan_drop   + 32'd1;
            if (lk_valid && !lk_ready)    cnt_lk_wait       <= cnt_lk_wait       + 32'd1;
            if (pub_v && pub_crossed)     cnt_crossed       <= cnt_crossed       + 32'd1;
            if (pub_v && pub_chg)         cnt_top_change    <= cnt_top_change    + 32'd1;
            if (pub_defer)                cnt_pub_defer     <= cnt_pub_defer     + 32'd1;
            if (pub_defer && pubd_v_q)    cnt_pub_drop      <= cnt_pub_drop      + 32'd1;
        end
    end

    // =========================================================================
    // 7. Assertions
    // =========================================================================
`ifndef SYNTHESIS
    initial begin
        if (N_LEVELS < 2 || ((N_LEVELS & (N_LEVELS - 1)) != 0)) begin
            $error("top_of_book: N_LEVELS must be a power of two >= 2 (got %0d) — the bid-side index reflection depends on it.", N_LEVELS);
            $fatal(1);
        end
        // ⚠️ This is a CORRECTNESS requirement, not only a timing one. The
        //    encoder is fed the search mask of the launching beat and its result
        //    is consumed one cycle later, so its output must be registered
        //    exactly once. ENC_PIPE = 0 would hand back the result for whatever
        //    mask happens to be on the wires in the following cycle; ENC_PIPE = 2
        //    would hand it back a cycle late.
        if (ENC_PIPE != 1) begin
            $error("top_of_book: ENC_PIPE must be 1 (got %0d) — the rescan consumes the encoder result exactly one cycle after launch.", ENC_PIPE);
            $fatal(1);
        end
    end

    // ── THE defect of docs/ORDER-BOOK-REDESIGN.md §2.1 ───────────────────────
    // A published best must never carry a zero price or a zero quantity. This is
    // the assertion whose absence let bid = $0.00 ship.
    assert property (@(posedge clk) disable iff (rst)
        (top_valid && top_bid_valid) |-> ((top_bid_px != '0) && (top_bid_qty != '0))
    ) else $error("top_of_book: published a bid with a zero price or zero size");

    assert property (@(posedge clk) disable iff (rst)
        (top_valid && top_ask_valid) |-> ((top_ask_px != '0) && (top_ask_qty != '0))
    ) else $error("top_of_book: published an ask with a zero price or zero size");

    // ── The stored price must always be the reconstruction of the level ──────
    assert property (@(posedge clk) disable iff (rst)
        (upd_valid && upd_in_window && !upd_clear)
            |-> (upd_price == (upd_base + price_t'(upd_level) * price_t'(TICK_UNITS)))
    ) else $error("top_of_book: price and level index disagree at the input");

    assert property (@(posedge clk) disable iff (rst)
        rs_commit |-> (rs_px == (rsL_base_q + price_t'(rsL_lvl_q) * price_t'(TICK_UNITS)))
    ) else $error("top_of_book: rescan price reconstruction is wrong");

    assert property (@(posedge clk) disable iff (rst)
        rs_commit |-> (lk_qty != '0)
    ) else $error("top_of_book: rescan found an occupied level with zero quantity");

    // ── Best / second-best ordering invariant ────────────────────────────────
    assert property (@(posedge clk) disable iff (rst)
        (upd_valid && c2v) |-> c1v
    ) else $error("top_of_book: second best valid while the best is not");

    assert property (@(posedge clk) disable iff (rst)
        (upd_valid && c1v && c2v) |-> lvl_better(is_buy, c1l, c2l)
    ) else $error("top_of_book: second best is not worse than the best");

    // ── The two write ports can never collide ────────────────────────────────
    assert property (@(posedge clk) disable iff (rst)
        (upd_valid && rs_commit)
            |-> !((upd_sym == rsL_sym_q) && (sidx == rsL_sidx_q))
    ) else $error("top_of_book: fast path and rescan commit wrote the same entry");

    // ── The best is never left unknown while the side is occupied ────────────
    // Either the beat resolves it, or a search is launched, or the engine was
    // busy and the symbol was staled.
    assert property (@(posedge clk) disable iff (rst)
        (upd_valid && !n1v && rs_any_occ)
            |=> ((rsE_v_q && (rsE_sym_q == $past(upd_sym)))
                 || sstale_q[$past(upd_sym)])
    ) else $error("top_of_book: best unknown on a non-empty side with no search in flight");

    assert property (@(posedge clk) disable iff (rst)
        rs_e_drop |=> sstale_q[$past(rsE_sym_q)]
    ) else $error("top_of_book: dropped a rescan without staling the symbol");

    // ── Rescan is bounded: stage E is consumed in exactly one cycle ──────────
    assert property (@(posedge clk) disable iff (rst)
        rsE_v_q |=> !rsE_v_q || $past(rs_launch)
    ) else $error("top_of_book: rescan stage E did not retire");

    // ── Lookup handshake contract ────────────────────────────────────────────
    assert property (@(posedge clk) disable iff (rst)
        lk_go |=> lk_ack
    ) else $error("top_of_book: level lookup was not acknowledged in one cycle");

    assert property (@(posedge clk) disable iff (rst)
        rs_commit |-> rsL_v_q
    ) else $error("top_of_book: committed a rescan that was not in flight");

    // ── Crossed must be computed, never latched stale ────────────────────────
    assert property (@(posedge clk) disable iff (rst)
        (top_valid && top_bid_valid && top_ask_valid && (top_bid_px >= top_ask_px))
            |-> top_crossed
    ) else $error("top_of_book: crossed book not flagged");

    // ── Stale must propagate unconditionally — no path may mask it ───────────
    assert property (@(posedge clk) disable iff (rst)
        stale_in |=> top_stale
    ) else $error("top_of_book: stale flag suppressed");

    assert property (@(posedge clk) disable iff (rst)
        (upd_valid && upd_stale) |=> top_stale
    ) else $error("top_of_book: per-symbol stale flag suppressed");

    // ── A clear must leave nothing behind ────────────────────────────────────
    assert property (@(posedge clk) disable iff (rst)
        (upd_valid && upd_clear) |=> (!b1v_q[$past(upd_sym)][0] &&
                                      !b1v_q[$past(upd_sym)][1] &&
                                      !b2v_q[$past(upd_sym)][0] &&
                                      !b2v_q[$past(upd_sym)][1])
    ) else $error("top_of_book: BOOK_CLEAR left a best behind");
`endif

endmodule : top_of_book

`default_nettype wire
