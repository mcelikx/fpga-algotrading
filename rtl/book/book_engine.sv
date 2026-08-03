// =============================================================================
// book_engine.sv — order book top level
// -----------------------------------------------------------------------------
// LATENCY  : 5 cycles (32.0 ns @ 156.25 MHz) typical, 6 cycles (38.4 ns) when a
//            best-level delete forces a rescan.
//            Owns these lines of the master budget in rtl/fpga_top.sv:
//              "Order-ID map lookup (BRAM + out reg)      2 cyc  12.8 ns"
//              "Book level update + incremental top       2 cyc  12.8 ns  var"
//            plus one cycle of input registration.
//            ⚠️ These are DESIGN TARGETS. Nothing here has been simulated or
//               placed and routed. Replace with measured figures per
//               manuals/05-optimization/04-measurement-and-profiling.md.
// RESOURCE : dominated by order_id_map (~32 URAM) and price_levels (~8 BRAM36).
// Governing manual: manuals/04-system-architecture/03-order-book-in-hardware.md
//
// PIPELINE
//   B0  register the incoming book_evt_t, issue the order-map hash + set read
//   B1  order-map way match, write-forward bypass
//   B2  order-map mutation decided -> {sym, side, price, add, del}
//   B3  price level read + forward
//   B4  price level write-back, occupancy update, incremental top-of-book
//
// The `rx_cycle` field is threaded through UNCHANGED from input to output. It is
// the ingress timestamp captured by the network layer and is the baseline for
// every latency measurement in the system — corrupting it silently invalidates
// all performance telemetry.
// =============================================================================
`default_nettype none

module book_engine
    import trading_pkg::*;
    import book_pkg::*;
(
    input  var logic       clk,
    input  var logic       rst,

    input  var book_evt_t  s_evt,
    input  var logic       s_evt_valid,

    output var book_top_t  m_top,
    output var logic       m_top_valid,

    output var logic [31:0] stat [16]
);

    // =========================================================================
    // B0 — input registration
    // =========================================================================
    book_evt_t evt_q;
    logic      evt_valid_q;

    always_ff @(posedge clk) begin
        if (rst) evt_valid_q <= 1'b0;
        else     evt_valid_q <= s_evt_valid;
        evt_q <= s_evt;
    end

    // ── ITCH Order Replace ('U') is a DELETE plus an ADD ──────────────────────
    // ⚠️ 'U' does not modify in place: it retires the original order reference
    //    and creates a new one at a new price and size, losing queue priority.
    //    Modelling it as an in-place edit leaks the old reference and produces a
    //    book that slowly diverges. Here the original event performs the delete,
    //    and a synthetic BOOK_ADD is injected on the following cycle carrying the
    //    NEW reference. `replay_q` holds that injection.
    book_evt_t replay_q;
    logic      replay_valid_q;

    book_evt_t map_in;
    logic      map_in_valid;

    always_comb begin
        // The injected add takes priority so the pair stays adjacent and the
        // forwarding logic in order_id_map sees them back to back.
        if (replay_valid_q) begin
            map_in       = replay_q;
            map_in_valid = 1'b1;
        end else begin
            map_in       = evt_q;
            map_in_valid = evt_valid_q;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            replay_valid_q <= 1'b0;
        end else begin
            replay_valid_q <= evt_valid_q && (evt_q.op == BOOK_REPLACE);
            replay_q       <= '{ op:            BOOK_ADD,
                                 sym:           evt_q.sym,
                                 locate:        evt_q.locate,
                                 side:          evt_q.side,
                                 price:         evt_q.price,
                                 qty:           evt_q.qty,
                                 order_ref:     evt_q.new_order_ref,
                                 new_order_ref: '0,
                                 exch_ts:       evt_q.exch_ts,
                                 rx_cycle:      evt_q.rx_cycle,
                                 printable:     evt_q.printable };
        end
    end

    // ⚠️ Backpressure note: injecting a replay cycle means the engine consumes
    //    two cycles for one 'U'. The feed handler does not backpressure, so a
    //    sustained burst of Replace messages at line rate would overrun. ITCH
    //    Replace rates are far below that in practice, but the condition is
    //    counted below (`stat[13]`) so it is observable rather than assumed.
    logic replay_collision;
    assign replay_collision = replay_valid_q && evt_valid_q;

    // =========================================================================
    // B1..B2 — order id map
    // =========================================================================
    logic       map_res_valid, map_res_hit, map_res_remove, map_stale;
    sym_idx_t   map_res_sym;
    side_e      map_res_side;
    price_t     map_res_price;
    qty_t       map_res_delta, map_res_add;
    logic [31:0] m_cnt_insert, m_cnt_ifail, m_cnt_miss, m_cnt_delete, m_cnt_fwd;
    logic [15:0] m_occ_hi;

    order_id_map u_map (
        .clk             (clk),
        .rst             (rst),
        .req_valid       (map_in_valid),
        .req_op          (map_in.op),
        .req_key         (map_in.order_ref),
        .req_new_key     (map_in.new_order_ref),
        .req_sym         (map_in.sym),
        .req_side        (map_in.side),
        .req_price       (map_in.price),
        .req_qty         (map_in.qty),
        .res_valid       (map_res_valid),
        .res_hit         (map_res_hit),
        .res_sym         (map_res_sym),
        .res_side        (map_res_side),
        .res_price       (map_res_price),
        .res_delta       (map_res_delta),
        .res_add         (map_res_add),
        .res_remove      (map_res_remove),
        .map_stale       (map_stale),
        .cnt_insert      (m_cnt_insert),
        .cnt_insert_fail (m_cnt_ifail),
        .cnt_miss        (m_cnt_miss),
        .cnt_delete      (m_cnt_delete),
        .cnt_forward     (m_cnt_fwd),
        .occupancy_hi    (m_occ_hi)
    );

    // Carry rx_cycle alongside the map pipeline (2 deep) so it stays aligned.
    cycle_t  rx_pipe_q [3];
    book_op_e op_pipe_q [3];
    always_ff @(posedge clk) begin
        rx_pipe_q[0] <= map_in.rx_cycle;
        rx_pipe_q[1] <= rx_pipe_q[0];
        rx_pipe_q[2] <= rx_pipe_q[1];
        op_pipe_q[0] <= map_in.op;
        op_pipe_q[1] <= op_pipe_q[0];
        op_pipe_q[2] <= op_pipe_q[1];
    end

    // =========================================================================
    // B3..B4 — price levels and top of book
    // =========================================================================
    logic       lvl_valid;
    sym_idx_t   lvl_sym;
    side_e      lvl_side;
    level_idx_t lvl_level;
    price_t     lvl_price;
    qty_t       lvl_qty;
    logic       lvl_occupied, lvl_in_window;
    logic [31:0] l_cnt_oow, l_cnt_uf, l_cnt_fwd, l_cnt_anchor;

    logic is_clear;
    assign is_clear = map_res_valid && (op_pipe_q[1] == BOOK_CLEAR);

    price_levels u_levels (
        .clk               (clk),
        .rst               (rst),
        .upd_valid         (map_res_valid && (map_res_hit || is_clear)),
        .upd_sym           (map_res_sym),
        .upd_side          (map_res_side),
        .upd_price         (map_res_price),
        .upd_add           (map_res_add),
        .upd_del           (map_res_delta),
        .upd_clear         (is_clear),
        .res_valid         (lvl_valid),
        .res_sym           (lvl_sym),
        .res_side          (lvl_side),
        .res_level         (lvl_level),
        .res_price         (lvl_price),
        .res_qty           (lvl_qty),
        .res_occupied      (lvl_occupied),
        .res_in_window     (lvl_in_window),
        .cnt_out_of_window (l_cnt_oow),
        .cnt_underflow     (l_cnt_uf),
        .cnt_forward       (l_cnt_fwd),
        .cnt_reanchor      (l_cnt_anchor)
    );

    logic       tob_valid, tob_bid_v, tob_ask_v, tob_crossed, tob_stale, tob_changed;
    sym_idx_t   tob_sym;
    price_t     tob_bid_px, tob_ask_px;
    qty_t       tob_bid_qty, tob_ask_qty;
    logic [31:0] t_cnt_rescan, t_cnt_crossed, t_cnt_change;

    top_of_book u_tob (
        .clk             (clk),
        .rst             (rst),
        .upd_valid       (lvl_valid),
        .upd_sym         (lvl_sym),
        .upd_side        (lvl_side),
        .upd_level       (lvl_level),
        .upd_price       (lvl_price),
        .upd_qty         (lvl_qty),
        .upd_occupied    (lvl_occupied),
        .upd_clear       (is_clear),
        .stale_in        (map_stale),
        .top_valid       (tob_valid),
        .top_sym         (tob_sym),
        .top_bid_px      (tob_bid_px),
        .top_bid_qty     (tob_bid_qty),
        .top_ask_px      (tob_ask_px),
        .top_ask_qty     (tob_ask_qty),
        .top_bid_valid   (tob_bid_v),
        .top_ask_valid   (tob_ask_v),
        .top_crossed     (tob_crossed),
        .top_stale       (tob_stale),
        .top_changed     (tob_changed),
        .cnt_best_rescan (t_cnt_rescan),
        .cnt_crossed     (t_cnt_crossed),
        .cnt_top_change  (t_cnt_change)
    );

    // Last trade price, tracked from printable executions.
    price_t last_px_q [N_ACTIVE];
    initial for (int unsigned s = 0; s < N_ACTIVE; s++) last_px_q[s] = '0;

    always_ff @(posedge clk) begin
        if (map_res_valid && map_res_hit && (op_pipe_q[1] == BOOK_EXECUTE))
            last_px_q[map_res_sym] <= map_res_price;
    end

    // =========================================================================
    // Output
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            m_top_valid <= 1'b0;
        end else begin
            m_top_valid <= tob_valid;
        end
        m_top <= '{ sym:         tob_sym,
                    bid_px:      tob_bid_px,
                    bid_qty:     tob_bid_qty,
                    ask_px:      tob_ask_px,
                    ask_qty:     tob_ask_qty,
                    last_px:     last_px_q[tob_sym],
                    bid_valid:   tob_bid_v,
                    ask_valid:   tob_ask_v,
                    crossed:     tob_crossed,
                    stale:       tob_stale,
                    top_changed: tob_changed,
                    rx_cycle:    rx_pipe_q[2] };
    end

    // =========================================================================
    // Telemetry — stat[16] map, mirrored in README.md and consumed by
    // rtl/telemetry/telemetry.sv
    // =========================================================================
    logic [31:0] cnt_evt_q, cnt_replay_q, cnt_collision_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_evt_q       <= '0;
            cnt_replay_q    <= '0;
            cnt_collision_q <= '0;
        end else begin
            if (s_evt_valid)      cnt_evt_q       <= cnt_evt_q + 32'd1;
            if (replay_valid_q)   cnt_replay_q    <= cnt_replay_q + 32'd1;
            if (replay_collision) cnt_collision_q <= cnt_collision_q + 32'd1;
        end
    end

    always_comb begin
        stat[0]  = cnt_evt_q;          // events in
        stat[1]  = m_cnt_insert;       // orders inserted
        stat[2]  = m_cnt_delete;       // orders removed
        stat[3]  = m_cnt_ifail;        // ⚠️ insert failures -> book stale
        stat[4]  = m_cnt_miss;         // ⚠️ unknown order reference -> book stale
        stat[5]  = m_cnt_fwd;          // order-map RMW forwards
        stat[6]  = {16'd0, m_occ_hi};  // order-map ways high-water
        stat[7]  = l_cnt_oow;          // ⚠️ price outside the maintained window
        stat[8]  = l_cnt_uf;           // ⚠️ level quantity underflow (saturated)
        stat[9]  = l_cnt_fwd;          // level RMW forwards
        stat[10] = l_cnt_anchor;       // window re-anchors
        stat[11] = t_cnt_rescan;       // best-level rescans (the jitter source)
        stat[12] = t_cnt_crossed;      // ⚠️ crossed book observations
        stat[13] = cnt_collision_q;    // ⚠️ replay collided with a new event
        stat[14] = t_cnt_change;       // genuine top-of-book changes
        stat[15] = cnt_replay_q;       // ITCH Replace injections
    end

    // =========================================================================
    // Assertions
    // =========================================================================
`ifndef SYNTHESIS
    // The ingress timestamp must survive the pipeline untouched — all latency
    // telemetry depends on it.
    assert property (@(posedge clk) disable iff (rst)
        m_top_valid |-> (m_top.rx_cycle == $past(rx_pipe_q[2]))
    ) else $error("book_engine: rx_cycle corrupted in the pipeline");

    // Stale must reach the output whenever the map is stale.
    assert property (@(posedge clk) disable iff (rst)
        (map_stale && m_top_valid) |-> m_top.stale
    ) else $error("book_engine: stale not propagated to the strategy");

    // A crossed or stale book must still be emitted — suppressing it would leave
    // the strategy acting on the previous, stale top of book.
    assert property (@(posedge clk) disable iff (rst)
        (m_top_valid && m_top.crossed) |-> (m_top.bid_px >= m_top.ask_px)
    ) else $error("book_engine: crossed flag set without a crossed book");
`endif

endmodule : book_engine

`default_nettype wire
