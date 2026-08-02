// =============================================================================
// feed_handler.sv — ITCH feed handler: decode + symbol filter + venue state
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/04-system-architecture/02-feed-handler-design.md
//           manuals/08-nasdaq/04-totalview-itch-5.0.md
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
// Layer   : rtl/feed — see rtl/feed/README.md
// Parent  : rtl/fpga_top.sv (instance u_feed) — THE port contract
//
// PURPOSE
//   Top of the feed layer. Consumes one whole ITCH 5.0 message per beat from
//   net_rx_path and produces:
//     • a trading_pkg::book_evt_t stream for the book engine, filtered down to
//       the symbols we actually trade;
//     • the global session state and the per-symbol venue-state side-channel
//       that gate the strategy engine and the pre-trade risk gate;
//     • sixteen 32-bit counters for telemetry.
//
// -----------------------------------------------------------------------------
// STRUCTURE
//
//   s_msg/s_len/s_valid/s_rx_cycle
//        │
//        ▼
//   ┌───────────────┐  book event      ┌───────────────┐  m_evt
//   │ itch_decoder  ├─────────────────►│               ├──────────► book_engine
//   │   1 cycle     │                  │ symbol_filter │  m_evt_valid
//   │ fixed-offset  │  venue side-band │   1 cycle     │
//   │ field extract ├──────┐           │ direct-index  │  q_sym/q_hit
//   └───────────────┘      │      ┌───►│ BRAM, 2 ports ├──────┐
//                          │      │    └───────────────┘      │
//                          ▼      │ q_locate                  ▼
//                    ┌──────────┐ │                    ┌─────────────┐
//                    │ align reg├─┴───────────────────►│ venue_state │
//                    │ 1 cycle  │                      │  2 cycles   │
//                    └──────────┘        s_gap ───────►│ fail-closed │
//                                                      └──────┬──────┘
//                                                             ▼
//                                            sess_state, sym_state_* side-channel
//
// -----------------------------------------------------------------------------
// LATENCY
//   BOOK EVENT PATH: 2 cycles, fixed, 12.8 ns @ 156.25 MHz (CORE_CLK_NS 6.4).
//     Budget rows owned, from fpga_top.sv's header table:
//       "ITCH decode (fixed-offset extraction)      1 cyc   6.4 ns"
//       "Symbol filter + active-index map           1 cyc   6.4 ns"
//     Initiation interval = 1: a message may be presented every cycle and one
//     comes out every cycle. No FIFOs, no backpressure, no stalls anywhere in
//     this layer (CLAUDE.md §5.4 — the RX path must accept line rate
//     unconditionally; drop deliberately and count, never block).
//     ACHIEVED: 2 cycles (SVA p_book_latency).
//
//   VENUE SIDE-CHANNEL: 4 cycles, 25.6 ns (decode 1 + filter port B 1 +
//     venue_state 2). NOT on the tick-to-trade path.
//
//   GAP BROADCAST: N_ACTIVE + 4 cycles = 260 cycles = ~1.66 us to stale the
//     whole active set. Bounded and counted. Decoding continues throughout.
//
// RESOURCE ESTIMATE (unmeasured, pre-synthesis — replace with real utilization
//                    from the Vivado report per CLAUDE.md §4)
//   LUT ~2,900   FF ~2,900   BRAM36 ~5   URAM 0   DSP 0
//     itch_decoder   LUT ~1,500  FF   ~360  BRAM 0
//     symbol_filter  LUT    ~80  FF   ~230  BRAM ~4
//     venue_state    LUT   ~650  FF ~1,600  BRAM ~1
//     counters/glue  LUT   ~670  FF   ~710  BRAM 0
//
// -----------------------------------------------------------------------------
// ⚠️  OFFSET VERIFICATION — THIS LAYER IS NOT PRODUCTION-TRUSTWORTHY YET
//     See the full ⚠️ VERIFY OFFSETS block in itch_decoder.sv and the ⚠️ header
//     of rtl/pkg/itch_pkg.sv. Every ITCH field offset and message length used
//     below is UNVERIFIED against the TotalView-ITCH 5.0 specification PDF
//     (https://nasdaqtrader.com/Trading/TradingSpecs) and has NOT been
//     validated against a golden software model over a pcap corpus.
//     Do not point this at a venue session — not even UAT — until both are done.
// =============================================================================
`default_nettype none

module feed_handler
    import trading_pkg::*;
    import itch_pkg::*;
#(
    // ⚠️ CONTRACT with fpga_top.sv (`logic [31:0] feed_stat [16]`). Do not
    //    override; the telemetry block's counter map depends on it.
    parameter int unsigned N_STAT = 16
) (
    input  var logic                   clk,
    input  var logic                   rst,          // synchronous, active high

    // ── One whole ITCH message per beat, from net_rx_path ────────────────────
    input  var logic [ITCH_MSG_W-1:0]  s_msg,
    input  var logic [ITCH_LEN_W-1:0]  s_len,
    input  var logic                   s_valid,
    input  var cycle_t                 s_rx_cycle,   // latency measurement baseline
    input  var logic                   s_gap,        // sequence discontinuity

    // ── Book event out, to book_engine ───────────────────────────────────────
    output var book_evt_t              m_evt,
    output var logic                   m_evt_valid,

    // ── Venue state side-channel, to strategy_engine and risk_gate ───────────
    output var trade_state_e           sess_state,
    output var logic                   sym_state_wr,
    output var sym_idx_t               sym_state_idx,
    output var trade_state_e           sym_state_val,
    output var logic                   sym_ssr_val,
    output var price_t                 sym_luld_lo,
    output var price_t                 sym_luld_hi,

    // ── Host write port (from host_ctrl, PCIe slow path) ─────────────────────
    input  var logic                   cfg_clk,
    input  var logic                   cfg_filter_wr,
    input  var logic [15:0]            cfg_filter_addr,
    input  var logic [31:0]            cfg_filter_data,

    // ── Telemetry ────────────────────────────────────────────────────────────
    output var logic [31:0]            stat [N_STAT]
);

    // =========================================================================
    // 1. stat[16] COUNTER MAP
    // -------------------------------------------------------------------------
    // All of stat[0..14] are SATURATING 32-bit counters (they stop at
    // 32'hFFFF_FFFF rather than wrapping — a wrapped counter turns a health
    // check into a no-op). stat[15] is a bit-packed STATUS word, not a counter.
    //
    // Class column: [E] = error, page on any non-zero. [N] = normal traffic,
    // absence may itself be the alarm. [V] = volume.
    //
    //  idx  name                class  meaning
    //  ---  ------------------  -----  -------------------------------------
    //   0   msgs_in              [V]   messages presented on s_valid
    //   1   msgs_accepted        [V]   passed length validation (any type)
    //   2   err_len_mismatch     [E]   declared length != type-implied length.
    //                                  MESSAGE DROPPED — we never guess a
    //                                  length; a wrong length means the field
    //                                  offsets are not trustworthy.
    //   3   unknown_type         [N]   type code not in itch_msg_len(). NOT an
    //                                  error — Nasdaq adds message types.
    //                                  Counted, emitted as BOOK_NOP, never
    //                                  forwarded to the book.
    //   4   filter_hit           [V]   locate mapped to an active symbol
    //   5   filter_miss          [N]   locate not subscribed. NORMAL — this is
    //                                  the >85% of the feed we chose not to do
    //                                  work for.
    //   6   err_bad_locate       [E]   locate == 0 or >= N_SYMBOLS on a
    //                                  book-affecting message
    //   7   evt_out              [V]   book events forwarded to book_engine
    //   8   op_add               [V]   BOOK_ADD      ('A' / 'F')
    //   9   op_exec              [V]   BOOK_EXECUTE  ('E' / 'C')
    //  10   op_cancel_delete     [V]   BOOK_CANCEL + BOOK_DELETE ('X' / 'D')
    //  11   op_replace           [V]   BOOK_REPLACE  ('U')
    //  12   venue_sysevent       [V]   'S' System Event
    //  13   venue_halt           [V]   'H' Trading Action + 'h' Operational Halt
    //  14   venue_ssr_luld       [V]   'Y' Reg SHO + 'J' LULD Auction Collar
    //  15   STATUS               [-]   bit-packed, see below
    //
    // stat[15] STATUS word:
    //   [ 2: 0]  sess_state       trading_pkg::trade_state_e
    //   [ 4: 3]  mwcb_level       0 = none, else MWCB level 1 / 2 / 3
    //   [ 5]     mwcb_l3          ⚠️ Level 3 breach: the system must stop
    //   [ 6]     gap_sticky       a sequence gap is outstanding, books stale
    //   [ 7]     resync_pending   a republish scan is running
    //   [15: 8]  ipo_msg_cnt      'K' IPO Quoting Period,   saturating 8-bit
    //   [23:16]  mwcb_msg_cnt     'V' + 'W' MWCB messages,  saturating 8-bit
    //   [31:24]  err_replace_ref  ⚠️ 'U' with new_order_ref == order_ref,
    //                             saturating 8-bit. MUST BE ZERO. Any non-zero
    //                             value means the book is leaking order
    //                             references or OFF_U_NEW_REF is wrong.
    // =========================================================================
    localparam int unsigned N_CNT = 15;   // stat[0..14]; stat[15] is the status

    // =========================================================================
    // 2. HOST CONFIG ADDRESS MAP (cfg_filter_addr)
    // -------------------------------------------------------------------------
    //   addr[15] == 0 : SYMBOL FILTER TABLE
    //       addr[14:0]              = ITCH stock locate code
    //       data[0]                 = subscribed
    //       data[8 +: ACT_IDX_W]    = compact active-set index
    //     The host builds this at session start from the ITCH Stock Directory
    //     ('R') messages intersected with the traded-universe config file.
    //
    //   addr[15] == 1 : VENUE CONTROL
    //       addr[3:0] == 0  RESYNC COMPLETE (the host-writable resync input)
    //           data[31]              = 1 -> apply to ALL symbols; also clears
    //                                        the global gap flag
    //           data[ACT_IDX_W-1:0]   = symbol index when data[31] == 0
    //       addr[3:0] == 1  STICKY CLEAR
    //           data[0]               = clear the MWCB level.
    //                                   ⚠️ After a Level 3 breach this is a
    //                                      deliberate operator decision and it
    //                                      should NOT be taken — a Level 3
    //                                      MWCB halts the market for the day.
    //
    // ⚠️ cfg_clk MUST be the same clock as clk. fpga_top ties both to core_clk
    //    and host_ctrl owns ALL CDC on its own side. cfg_clk is passed to
    //    symbol_filter (whose table is a dual-clock memory and could therefore
    //    move to the PCIe domain later); the venue control registers below are
    //    captured on `clk`. If the two clocks are ever made different, those
    //    registers must move with the table, and there must be a sanctioned
    //    synchroniser between them (never hand-rolled — CLAUDE.md §4).
    // =========================================================================
    localparam int unsigned CFG_REGION_BIT = 15;
    localparam logic [3:0]  VREG_RESYNC    = 4'd0;
    localparam logic [3:0]  VREG_CLEAR     = 4'd1;

    logic cfg_tab_wr;
    logic cfg_vreg_wr;
    logic cfg_resync_wr;
    logic cfg_resync_all;
    logic cfg_clr_mwcb;

    assign cfg_tab_wr  = cfg_filter_wr && !cfg_filter_addr[CFG_REGION_BIT];
    assign cfg_vreg_wr = cfg_filter_wr &&  cfg_filter_addr[CFG_REGION_BIT];

    assign cfg_resync_wr  = cfg_vreg_wr && (cfg_filter_addr[3:0] == VREG_RESYNC);
    assign cfg_resync_all = cfg_filter_data[31];
    assign cfg_clr_mwcb   = cfg_vreg_wr && (cfg_filter_addr[3:0] == VREG_CLEAR)
                                        && cfg_filter_data[0];

    // =========================================================================
    // 3. ITCH decoder — 1 cycle, fixed-offset extraction (NOT a parser)
    // =========================================================================
    book_evt_t  dec_evt;
    logic       dec_evt_valid;
    logic       dec_accept;
    logic       dec_len_err;
    logic       dec_unknown;
    logic       dec_repl_ref_err;
    logic       dec_venue_valid;
    logic [7:0] dec_venue_type;
    locate_t    dec_venue_locate;
    logic [7:0] dec_venue_code;
    price_t     dec_venue_px_lo;
    price_t     dec_venue_px_hi;

    itch_decoder u_decoder (
        .clk               (clk),
        .rst               (rst),
        .s_msg             (s_msg),
        .s_len             (s_len),
        .s_valid           (s_valid),
        .s_rx_cycle        (s_rx_cycle),
        .m_evt             (dec_evt),
        .m_evt_valid       (dec_evt_valid),
        .m_accept          (dec_accept),
        .m_len_err         (dec_len_err),
        .m_unknown         (dec_unknown),
        .m_replace_ref_err (dec_repl_ref_err),
        .m_venue_valid     (dec_venue_valid),
        .m_venue_type      (dec_venue_type),
        .m_venue_locate    (dec_venue_locate),
        .m_venue_code      (dec_venue_code),
        .m_venue_px_lo     (dec_venue_px_lo),
        .m_venue_px_hi     (dec_venue_px_hi)
    );

    // =========================================================================
    // 4. Symbol filter — 1 cycle, direct-index BRAM (NOT a hash, NOT a CAM)
    // -------------------------------------------------------------------------
    // Port A carries the book-event stream. Port B resolves the locate on the
    // venue side-band to the same compact index, so venue_state can key its
    // per-symbol records off the active-set index rather than duplicating the
    // table.
    // =========================================================================
    book_evt_t filt_evt;
    logic      filt_valid;
    logic      filt_miss;
    logic      filt_bad;

    sym_idx_t  vq_sym;
    logic      vq_hit;
    logic      vq_valid;

    symbol_filter #(
        .N_LOCATE      (N_SYMBOLS)
    ) u_filter (
        .clk           (clk),
        .rst           (rst),
        // Port A: book event stream
        .s_evt         (dec_evt),
        .s_valid       (dec_evt_valid),
        .m_evt         (filt_evt),
        .m_valid       (filt_valid),
        .m_miss        (filt_miss),
        .m_bad_locate  (filt_bad),
        // Port B: venue-state locate lookup
        .q_locate      (dec_venue_locate),
        .q_valid       (dec_venue_valid),
        .q_sym         (vq_sym),
        .q_hit         (vq_hit),
        .q_valid_o     (vq_valid),
        // Host table load
        .cfg_clk       (cfg_clk),
        .cfg_wr        (cfg_tab_wr),
        .cfg_addr      (cfg_filter_addr),
        .cfg_data      (cfg_filter_data)
    );

    // =========================================================================
    // 5. Venue side-band alignment
    // -------------------------------------------------------------------------
    // symbol_filter port B returns its result one cycle after q_valid. The
    // decoder's venue payload is one cycle ahead of that, so it gets one
    // pipeline register to line up. Datapath only — no reset.
    // =========================================================================
    logic [7:0] vn_type;
    logic [7:0] vn_code;
    price_t     vn_px_lo;
    price_t     vn_px_hi;

    always_ff @(posedge clk) begin
        if (dec_venue_valid) begin
            vn_type  <= dec_venue_type;
            vn_code  <= dec_venue_code;
            vn_px_lo <= dec_venue_px_lo;
            vn_px_hi <= dec_venue_px_hi;
        end
    end

    // =========================================================================
    // 6. Venue state tracker — fail-closed, TRADE_DISABLED at reset
    // =========================================================================
    logic [1:0] mwcb_level;
    logic       mwcb_l3;
    logic       gap_sticky;
    logic       resync_pending;

    trade_state_e sess_state_int;

    venue_state u_venue (
        .clk             (clk),
        .rst             (rst),
        .s_valid         (vq_valid),
        .s_type          (vn_type),
        .s_sym           (vq_sym),
        .s_sym_hit       (vq_hit),
        .s_code          (vn_code),
        .s_px_lo         (vn_px_lo),
        .s_px_hi         (vn_px_hi),
        .s_gap           (s_gap),
        .cfg_resync_wr   (cfg_resync_wr),
        .cfg_resync_all  (cfg_resync_all),
        .cfg_resync_sym  (cfg_filter_data[ACT_IDX_W-1:0]),
        .cfg_clr_mwcb    (cfg_clr_mwcb),
        .sess_state      (sess_state_int),
        .sym_state_wr    (sym_state_wr),
        .sym_state_idx   (sym_state_idx),
        .sym_state_val   (sym_state_val),
        .sym_ssr_val     (sym_ssr_val),
        .sym_luld_lo     (sym_luld_lo),
        .sym_luld_hi     (sym_luld_hi),
        .mwcb_level      (mwcb_level),
        .mwcb_l3         (mwcb_l3),
        .gap_sticky      (gap_sticky),
        .resync_pending  (resync_pending)
    );

    assign sess_state = sess_state_int;

    // =========================================================================
    // 7. Book event output
    // -------------------------------------------------------------------------
    // m_evt is the filter's registered output, unmodified.
    //
    // m_evt_valid gates out BOOK_NOP so the book engine never spends a pipeline
    // slot on a message that cannot change the book (unknown types are the only
    // way a NOP reaches here — known non-book types never enter the book path
    // at all). This is a single 3-bit compare off two flip-flops; registering it
    // would add a cycle to the tick-to-trade path for one LUT level, so the
    // combinational-output exception of the coding standard §5 is taken
    // deliberately here.
    // =========================================================================
    assign m_evt       = filt_evt;
    assign m_evt_valid = filt_valid && (filt_evt.op != BOOK_NOP);

    // =========================================================================
    // 8. Telemetry counters
    // =========================================================================
    logic [N_CNT-1:0] cnt_inc;
    logic [31:0]      cnt_q [N_CNT];

    always_comb begin
        cnt_inc = '0;
        cnt_inc[0]  = s_valid;
        cnt_inc[1]  = dec_accept;
        cnt_inc[2]  = dec_len_err;
        cnt_inc[3]  = dec_unknown;
        cnt_inc[4]  = filt_valid;
        cnt_inc[5]  = filt_miss;
        cnt_inc[6]  = filt_bad;
        cnt_inc[7]  = m_evt_valid;
        cnt_inc[8]  = m_evt_valid && (filt_evt.op == BOOK_ADD);
        cnt_inc[9]  = m_evt_valid && (filt_evt.op == BOOK_EXECUTE);
        cnt_inc[10] = m_evt_valid && ((filt_evt.op == BOOK_CANCEL) ||
                                      (filt_evt.op == BOOK_DELETE));
        cnt_inc[11] = m_evt_valid && (filt_evt.op == BOOK_REPLACE);
        cnt_inc[12] = dec_venue_valid && (dec_venue_type == MSG_SYSTEM_EVENT);
        cnt_inc[13] = dec_venue_valid && ((dec_venue_type == MSG_TRADING_ACTION) ||
                                          (dec_venue_type == MSG_OPERATIONAL_HALT));
        cnt_inc[14] = dec_venue_valid && ((dec_venue_type == MSG_REG_SHO) ||
                                          (dec_venue_type == MSG_LULD_COLLAR));
    end

    // Saturating: a wrapped counter turns a health check into a no-op.
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned i = 0; i < N_CNT; i++) begin
                cnt_q[i] <= 32'd0;
            end
        end else begin
            for (int unsigned i = 0; i < N_CNT; i++) begin
                if (cnt_inc[i] && (cnt_q[i] != 32'hFFFF_FFFF)) begin
                    cnt_q[i] <= cnt_q[i] + 32'd1;
                end
            end
        end
    end

    // Small saturating counters packed into the status word.
    logic [7:0] ipo_cnt_q;
    logic [7:0] mwcb_cnt_q;
    logic [7:0] repl_err_q;

    logic ipo_inc;
    logic mwcb_inc;

    assign ipo_inc  = dec_venue_valid && (dec_venue_type == MSG_IPO_QUOTING);
    assign mwcb_inc = dec_venue_valid && ((dec_venue_type == MSG_MWCB_STATUS) ||
                                          (dec_venue_type == MSG_MWCB_DECLINE));

    always_ff @(posedge clk) begin
        if (rst) begin
            ipo_cnt_q  <= 8'd0;
            mwcb_cnt_q <= 8'd0;
            repl_err_q <= 8'd0;
        end else begin
            if (ipo_inc          && (ipo_cnt_q  != 8'hFF)) ipo_cnt_q  <= ipo_cnt_q  + 8'd1;
            if (mwcb_inc         && (mwcb_cnt_q != 8'hFF)) mwcb_cnt_q <= mwcb_cnt_q + 8'd1;
            if (dec_repl_ref_err && (repl_err_q != 8'hFF)) repl_err_q <= repl_err_q + 8'd1;
        end
    end

    // stat is a pure fan-out of register outputs.
    logic [2:0] sess_bits;
    assign sess_bits = sess_state_int;

    always_comb begin
        for (int unsigned i = 0; i < N_CNT; i++) begin
            stat[i] = cnt_q[i];
        end
        stat[15] = {repl_err_q,           // [31:24]
                    mwcb_cnt_q,           // [23:16]
                    ipo_cnt_q,            // [15: 8]
                    resync_pending,       // [ 7]
                    gap_sticky,           // [ 6]
                    mwcb_l3,              // [ 5]
                    mwcb_level,           // [ 4: 3]
                    sess_bits};           // [ 2: 0]
    end

    // =========================================================================
    // 9. Assertions — simulation only
    // =========================================================================
`ifndef SYNTHESIS

    // ── Latency contract: the book path is exactly 2 cycles ──────────────────
    // Decode is 1 cycle (asserted inside itch_decoder as p_one_cycle); the
    // filter stage below adds exactly 1 more and always resolves to exactly one
    // of hit / miss / bad-locate. 1 + 1 = the two budget rows this layer owns.
    p_filter_latency: assert property (@(posedge clk) disable iff (rst)
        dec_evt_valid |=> (filt_valid ^ filt_miss ^ filt_bad)
    ) else $error("feed_handler: filter stage did not resolve in 1 cycle");

    // Every input either produces a decoder outcome next cycle or was dropped.
    p_input_resolves: assert property (@(posedge clk) disable iff (rst)
        s_valid |=> (dec_accept ^ dec_len_err)
    ) else $error("feed_handler: input did not resolve in 1 cycle");

    // The latency measurement baseline survives the whole layer untouched.
    p_rx_cycle_carried: assert property (@(posedge clk) disable iff (rst)
        m_evt_valid |-> (m_evt.rx_cycle == $past(s_rx_cycle, 2))
    ) else $error("feed_handler: rx_cycle was not carried through unchanged");

    // ── The book engine must never see a no-op ───────────────────────────────
    p_no_nop_downstream: assert property (@(posedge clk) disable iff (rst)
        m_evt_valid |-> (m_evt.op != BOOK_NOP)
    ) else $error("feed_handler: BOOK_NOP forwarded to the book engine");

    // ── Order Replace carries two distinct references ────────────────────────
    // Restated here as well as in the decoder: a book that treats 'U' as an
    // in-place modify leaks order references and drifts from the true book.
    p_replace_distinct: assert property (@(posedge clk) disable iff (rst)
        (m_evt_valid && (m_evt.op == BOOK_REPLACE))
            |-> (m_evt.new_order_ref != m_evt.order_ref)
    ) else $error("feed_handler: ITCH 'U' with new_order_ref == order_ref");

    // ── Nothing reaches the book for a symbol we do not trade ────────────────
    p_filtered_early: assert property (@(posedge clk) disable iff (rst)
        (filt_miss || filt_bad) |-> !m_evt_valid
    ) else $error("feed_handler: an unsubscribed symbol reached the book engine");

    // ── A gap must stale the whole active set, and must do it in bounded time ─
    p_gap_stales: assert property (@(posedge clk) disable iff (rst)
        $rose(s_gap) |-> ##[1:(N_ACTIVE+8)] (sym_state_wr &&
                                             (sym_state_val == TRADE_STALE))
    ) else $error("feed_handler: a sequence gap did not produce TRADE_STALE");

    // ── ⚠️ A Level 3 MWCB must stop the system ───────────────────────────────
    p_mwcb_l3: assert property (@(posedge clk) disable iff (rst)
        mwcb_l3 |-> (sess_state == TRADE_CLOSED)
    ) else $error("feed_handler: Level 3 MWCB did not close the session");

    // ── Counters saturate, never wrap. A wrapped counter is a silent failure. ─
    genvar gi;
    generate
        for (gi = 0; gi < N_CNT; gi++) begin : g_cnt_assert
            // Bind the genvar to a localparam: a genvar is an elaboration-time
            // object and must not appear in a runtime expression.
            localparam int unsigned CNT_IDX = gi;
            p_no_wrap: assert property (@(posedge clk) disable iff (rst)
                (cnt_q[CNT_IDX] == 32'hFFFF_FFFF) |=> (cnt_q[CNT_IDX] == 32'hFFFF_FFFF)
            ) else $error("feed_handler: counter %0d wrapped", CNT_IDX);
        end
    endgenerate

    // ── ⚠️ MUST BE ZERO in any healthy run ───────────────────────────────────
    p_no_replace_ref_err: assert property (@(posedge clk) disable iff (rst)
        repl_err_q == 8'd0
    ) else $error("feed_handler: Order Replace reference error — VERIFY OFF_U_NEW_REF");

    // ── The host must never map locate 0 to a tradeable symbol ───────────────
    // Locate 0 means "not applicable" and is used by the global messages.
    p_no_locate_zero_write: assert property (@(posedge clk) disable iff (rst)
        (cfg_tab_wr && (cfg_filter_addr[14:0] == 15'd0)) |-> (cfg_filter_data[0] == 1'b0)
    ) else $error("feed_handler: host subscribed stock locate 0");

`endif

endmodule : feed_handler

`default_nettype wire
