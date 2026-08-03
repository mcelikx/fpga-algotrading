// =============================================================================
// fpga_top.sv — Tick-to-trade top level
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Device  : AMD/Xilinx UltraScale+ (fast path constrained to ONE SLR)
// Governs : manuals/04-system-architecture/01-tick-to-trade-pipeline.md
//
// -----------------------------------------------------------------------------
// LATENCY BUDGET (design target, 156.25 MHz core clock, 6.4 ns/cycle)
// Measured numbers replace these only after a wire-to-wire measurement per
// manuals/05-optimization/04-measurement-and-profiling.md. Until then every
// figure below is a TARGET, not a result.
//
//   Stage                                      cyc      ns     cum ns   fixed?
//   ---------------------------------------- -----   -----   -------   ------
//   Optics + GT RX PMA/PCS (hard IP)              -   ~90.0      90.0   fixed
//   MAC RX (cut-through)                          2    12.8     102.8   fixed
//   Ethernet/IPv4/UDP header strip                1     6.4     109.2   fixed
//   MoldUDP64 deframe + A/B arbitration           2    12.8     122.0   fixed
//   ITCH message assembly (to 512-bit beat)       2    12.8     134.8   fixed
//   ITCH decode (fixed-offset extraction)         1     6.4     141.2   fixed
//   Symbol filter + active-index map              1     6.4     147.6   fixed
//   Book B0: input reg + early window check       1     6.4     154.0   fixed
//   Book B1-B2: order-ID map (cuckoo, 2 buckets)  2    12.8     166.8   fixed
//   Book B3-B4: price-level classify + RMW        2    12.8     179.6   fixed
//   Book B5: incremental top-of-book              1     6.4     186.0   var*
//   Book B6: output registration                  1     6.4     192.4   fixed
//   Strategy parameter read + trigger             2    12.8     205.2   fixed
//   Pre-trade risk gate                           2    12.8     218.0   fixed
//   OUCH template read + splice + checksum        2    12.8     230.8   fixed
//   TCP/SoupBinTCP framing                        1     6.4     237.2   fixed
//   MAC TX (cut-through)                          2    12.8     250.0   fixed
//   GT TX PCS/PMA + optics (hard IP)              -   ~90.0     340.0   fixed
//   ---------------------------------------- -----   -----   -------
//   FABRIC total                                 25   160.0
//   WIRE-TO-WIRE target                           -       -     ~340    (< 1 us)
//
//   * The single variable-latency stage is a best-level delete that forces a
//     new-best search. Bounded (+2 cycles typical) and counted; see
//     book_engine.sv, whose header carries the cycle-accurate derivation of all
//     seven book rows.
//
//   ⚠️ THE BOOK GREW FROM 4 ROWS TO 7 AND THE BUDGET IS RESTATED, NOT HIDDEN.
//      The three extra cycles buy: a 2048-level window instead of 16 (the book
//      no longer freezes when a symbol moves 8 cents), an O(1)-worst-case cuckoo
//      lookup with an overflow region instead of a table that dies at 12.5 %
//      load, and the early window check that makes the map and the level array
//      hold the same population by construction. 19.2 ns for a book that works
//      is not a regression; a 128 ns budget for a book that publishes a $0.00
//      bid is not an achievement. docs/ORDER-BOOK-REDESIGN.md §2.
//
// RESOURCE BUDGET (target, VU9P-class, fast path only, one SLR)
//   LUT  < 60k   FF < 90k   BRAM < 300   URAM < 200
//   ⚠️ URAM was < 64 and that was written for a 16-level book. The order book
//      alone now accounts for 160 URAM288 (128 level array + 32 order map) and
//      the full SLR arithmetic — 163 of ~320, 51 % — is recorded in
//      rtl/pkg/trading_pkg.sv §"SLR CAPACITY". It fits with room; the ceiling
//      above is set at 200 so a map re-sizing from measured ITCH statistics has
//      somewhere to go before it has to displace something.
//   ⚠️ THE FF FIGURE IS NOT CREDIBLE AND IS FLAGGED RATHER THAN ADJUSTED.
//      top_of_book's best + second-best register file is ~78 kFF on its own at
//      N_ACTIVE = 256, and strategy_engine estimates ~18.7 kFF. FF < 90k cannot
//      hold both. Re-derive the FF budget from a synthesis run before treating
//      any of these numbers as a gate.   DSP < 16
// -----------------------------------------------------------------------------
// HARD RULES ENFORCED HERE (CLAUDE.md §5)
//   1. RX path has NO backpressure. s_axis_rx_tready is tied high, always.
//   2. Every outbound order passes through u_risk_gate. There is no bypass.
//   3. The kill switch is hardware-enforced and bounded (KILL_RESP_CYCLES).
//   4. Reset state = trading disabled, all limits zero (fail-closed).
//   5. One clock domain (core_clk) for the whole datapath. CDC only at the
//      MAC and PCIe boundaries.
// =============================================================================
`default_nettype none

module fpga_top
    import trading_pkg::*;
#(
    // Build identity, burned into the fabric. The host refuses to arm trading
    // unless this matches the expected value.
    // See manuals/06-operations/01-build-and-release.md.
    parameter logic [31:0] BUILD_ID     = 32'hDEAD_0000,
    parameter logic [31:0] GIT_SHA      = 32'h0000_0000,
    // Kill switch must stop all outbound order flow within this many cycles.
    parameter int unsigned KILL_RESP_CYCLES = 4
) (
    // ── Reference clocks and hard reset ──────────────────────────────────────
    input  var logic         sys_clk_p,        // 100 MHz board reference
    input  var logic         sys_clk_n,
    input  var logic         sys_rst_n,        // active-low board reset

    // ── Market data link (10GbE, RX only — ITCH multicast in) ────────────────
    input  var logic         md_gt_refclk_p,
    input  var logic         md_gt_refclk_n,
    input  var logic [1:0]   md_rx_p,          // A feed on lane 0, B feed on lane 1
    input  var logic [1:0]   md_rx_n,
    output var logic [1:0]   md_tx_p,          // unused; held quiet
    output var logic [1:0]   md_tx_n,

    // ── Order entry link (10GbE, bidirectional — OUCH/SoupBinTCP) ────────────
    input  var logic         oe_gt_refclk_p,
    input  var logic         oe_gt_refclk_n,
    input  var logic         oe_rx_p,
    input  var logic         oe_rx_n,
    output var logic         oe_tx_p,
    output var logic         oe_tx_n,

    // ── Host interface (PCIe Gen3 x16 — SLOW PATH ONLY) ──────────────────────
    input  var logic         pcie_refclk_p,
    input  var logic         pcie_refclk_n,
    input  var logic         pcie_rst_n,
    input  var logic [15:0]  pcie_rx_p,
    input  var logic [15:0]  pcie_rx_n,
    output var logic [15:0]  pcie_tx_p,
    output var logic [15:0]  pcie_tx_n,

    // ── External hardware kill input (front-panel / BMC) ──────────────────────
    input  var logic         ext_kill_n,       // active low, asynchronous

    // ── Status ────────────────────────────────────────────────────────────────
    output var logic [7:0]   led
);

    // =========================================================================
    // Clocks and resets
    // =========================================================================
    logic core_clk;          // 156.25 MHz — THE datapath clock
    logic core_rst;          // synchronous, active high
    logic pcie_clk;          // 250 MHz
    logic pcie_rst;
    logic md_rx_clk  [2];    // recovered clocks, MAC side only
    logic oe_clk;

    clk_rst_gen u_clk_rst (
        .sys_clk_p   (sys_clk_p),
        .sys_clk_n   (sys_clk_n),
        .sys_rst_n   (sys_rst_n),
        .core_clk    (core_clk),
        .core_rst    (core_rst),
        .pcie_refclk_p(pcie_refclk_p),
        .pcie_refclk_n(pcie_refclk_n),
        .pcie_rst_n  (pcie_rst_n),
        .pcie_clk    (pcie_clk),
        .pcie_rst    (pcie_rst)
    );

    // Free-running cycle counter. The single time reference for all on-chip
    // latency measurement. Never reset after initial release.
    // See manuals/05-optimization/04-measurement-and-profiling.md.
    cycle_t cycle_cnt;
    always_ff @(posedge core_clk) begin
        if (core_rst) cycle_cnt <= '0;
        else          cycle_cnt <= cycle_cnt + 1'b1;
    end

    // =========================================================================
    // Market data RX: 2 lanes (A/B feeds) -> MAC -> core_clk
    // =========================================================================
    logic [AXIS_W-1:0]      md_axis_tdata  [2];
    logic [AXIS_KEEP_W-1:0] md_axis_tkeep  [2];
    logic                   md_axis_tvalid [2];
    logic                   md_axis_tlast  [2];
    logic                   md_axis_tuser  [2];   // 1 = frame had a bad FCS
    logic                   md_link_up     [2];
    logic [31:0]            md_mac_stat    [2][4];

    generate
        for (genvar f = 0; f < 2; f++) begin : g_md_lane
            eth_10g_wrapper #(
                .CUT_THROUGH  (1),      // store-and-forward costs a full frame time
                .RX_ONLY      (1),
                .LOW_LATENCY  (1)       // bypass the elastic buffer where possible
            ) u_md_eth (
                .gt_refclk_p  (md_gt_refclk_p),
                .gt_refclk_n  (md_gt_refclk_n),
                .rxp          (md_rx_p[f]),
                .rxn          (md_rx_n[f]),
                .txp          (md_tx_p[f]),
                .txn          (md_tx_n[f]),
                .rx_clk       (md_rx_clk[f]),
                .core_clk     (core_clk),
                .core_rst     (core_rst),
                // RX -> core_clk, via the MAC's async FIFO. NO BACKPRESSURE.
                .m_axis_tdata (md_axis_tdata[f]),
                .m_axis_tkeep (md_axis_tkeep[f]),
                .m_axis_tvalid(md_axis_tvalid[f]),
                .m_axis_tlast (md_axis_tlast[f]),
                .m_axis_tuser (md_axis_tuser[f]),
                // TX unused on the market data link
                .s_axis_tdata ('0),
                .s_axis_tkeep ('0),
                .s_axis_tvalid(1'b0),
                .s_axis_tlast (1'b0),
                .s_axis_tready(),
                .link_up      (md_link_up[f]),
                .stat         (md_mac_stat[f])
            );
        end
    endgenerate

    // =========================================================================
    // Network RX: Ethernet/IP/UDP strip -> MoldUDP64 deframe -> A/B arbitrate
    // =========================================================================
    logic [ITCH_MSG_W-1:0]  itch_msg;
    logic [ITCH_LEN_W-1:0]  itch_len;
    logic                   itch_valid;
    cycle_t                 itch_rx_cycle;
    logic                   feed_gap;          // sequence discontinuity detected
    logic [63:0]            feed_seq;
    logic [31:0]            net_stat [8];

    net_rx_path #(
        .N_FEEDS (2)
    ) u_net_rx (
        .clk            (core_clk),
        .rst            (core_rst),
        .cycle_cnt      (cycle_cnt),
        // Two independent MAC streams (A and B)
        .s_axis_tdata   (md_axis_tdata),
        .s_axis_tkeep   (md_axis_tkeep),
        .s_axis_tvalid  (md_axis_tvalid),
        .s_axis_tlast   (md_axis_tlast),
        .s_axis_tuser   (md_axis_tuser),
        // One deduplicated, in-order ITCH message stream out
        .m_msg          (itch_msg),
        .m_len          (itch_len),
        .m_valid        (itch_valid),
        .m_rx_cycle     (itch_rx_cycle),
        .m_seq          (feed_seq),
        .m_gap          (feed_gap),
        .stat           (net_stat)
    );

    // =========================================================================
    // Feed handler: ITCH decode + symbol filter
    // =========================================================================
    book_evt_t              book_evt;
    logic                   book_evt_valid;
    trade_state_e           sess_state;         // global session state (ITCH 'S')
    logic [31:0]            feed_stat [16];

    // Per-symbol venue state pushed to the risk gate and strategy: halts,
    // LULD bands, Reg SHO. Sourced from ITCH H/h/Y/J messages.
    logic                   sym_state_wr;
    sym_idx_t               sym_state_idx;
    trade_state_e           sym_state_val;
    logic                   sym_ssr_val;
    // ⚠️ ITCH message 'J' carries AUCTION COLLARS, not live LULD bands. The live
    //    bands come from the SIP, which this design does not consume, and are
    //    host-written into the risk parameter table instead. Naming these
    //    'luld' is precisely how the original defect hid — a symbol whose bands
    //    sat at 0/0 while the fail-closed risk gate rejected every order.
    //    See docs/SYSTEM-REPORT.md defect 1.
    price_t                 sym_auc_collar_lo, sym_auc_collar_hi;

    feed_handler u_feed (
        .clk            (core_clk),
        .rst            (core_rst),
        // Decoded message in
        .s_msg          (itch_msg),
        .s_len          (itch_len),
        .s_valid        (itch_valid),
        .s_rx_cycle     (itch_rx_cycle),
        .s_gap          (feed_gap),
        // Book event out
        .m_evt          (book_evt),
        .m_evt_valid    (book_evt_valid),
        // Venue state side-channel
        .sess_state     (sess_state),
        .sym_state_wr   (sym_state_wr),
        .sym_state_idx  (sym_state_idx),
        .sym_state_val  (sym_state_val),
        .sym_ssr_val    (sym_ssr_val),
        .sym_luld_lo    (sym_auc_collar_lo),
        .sym_luld_hi    (sym_auc_collar_hi),
        // Host-loaded locate -> active-index filter table
        .cfg_clk        (core_clk),
        .cfg_filter_wr  (cfg_filter_wr),
        .cfg_filter_addr(cfg_filter_addr),
        .cfg_filter_data(cfg_filter_data),
        .stat           (feed_stat)
    );

    // =========================================================================
    // Order book
    // =========================================================================
    book_top_t              book_top;
    logic                   book_top_valid;
    logic [31:0]            book_stat [16];

    // ── Host per-symbol reference price (the window anchor) ──────────────────
    // ⚠️ THE BOOK IS INERT WITHOUT THIS. price_levels is host-anchored and fails
    //    closed: a symbol with no reference price rejects every update, stales
    //    itself and asks to be re-anchored. That is deliberate — a guessed
    //    window is what silently froze the previous book — but it makes this
    //    port mandatory plumbing, not an optional feature.
    //    See rtl/book/book_engine.sv §"HOST ANCHOR" and
    //    manuals/04-system-architecture/03-order-book-in-hardware.md §4.
    //
    // REGISTER MAP ADDITION THE HOST SOFTWARE NEEDS
    //   No new BAR register. A new REGION inside the existing STRAT config
    //   window (BAR offset 0x300), which is the only window deliberately NOT
    //   write-protected while trading is enabled — it already carries a
    //   per-symbol price the host refreshes at millisecond cadence
    //   (sym_strat_t.fair_value), which is exactly this port's cadence.
    //
    //     STRAT_ADDR (0x300) <= 16'h6000 | sym      // region 3'b011, sym[7:0]
    //     STRAT_DATA (0x304) <= ref_px              // ITCH units, 4 implied
    //                                               // decimals, WHOLE TICK
    //
    //   No commit pulse: the anchor applies per symbol on its own handshake and
    //   is not double-buffered. A sub-tick reference is REJECTED and counted
    //   (book stat[15] bit 12) rather than anchoring the window off-grid.
    //
    // ⚠️ ONE FOLLOW-UP IS REQUIRED OUTSIDE THIS FILE, AND IT IS NOT COSMETIC.
    //    strategy_engine decodes cfg_param_addr[15:13] and COUNTS every region
    //    it does not recognise as a bad address (cfg_bad_addr_cnt_q). Region
    //    3'b011 is now legitimate traffic, so that counter must be taught about
    //    it or it reports a false host-addressing fault on every re-anchor —
    //    a telemetry lie that would mask a real addressing bug. One line, in
    //    rtl/strategy/strategy_engine.sv:
    //        (cfg_region != book_pkg::BOOK_CFG_REGION) &&
    //    plus the matching constant in rtl/strategy/strategy_pkg.sv. Both files
    //    are outside this task's write scope, so it is stated, not done.
    logic     book_cfg_valid, book_cfg_ready;
    sym_idx_t book_cfg_sym;
    price_t   book_cfg_px;

    assign book_cfg_valid = cfg_strat_wr
                         && (cfg_strat_addr[15:13] == book_pkg::BOOK_CFG_REGION);
    assign book_cfg_sym   = cfg_strat_addr[ACT_IDX_W-1:0];
    assign book_cfg_px    = cfg_strat_data;

    book_engine u_book (
        .clk            (core_clk),
        .rst            (core_rst),
        .s_evt          (book_evt),
        .s_evt_valid    (book_evt_valid),
        .cfg_ref_valid  (book_cfg_valid),
        .cfg_ref_sym    (book_cfg_sym),
        .cfg_ref_px     (book_cfg_px),
        .cfg_ref_ready  (book_cfg_ready),
        .m_top          (book_top),
        .m_top_valid    (book_top_valid),
        .stat           (book_stat)
    );

    // =========================================================================
    // Strategy engine
    // =========================================================================
    order_req_t             order_req;
    logic                   order_req_valid;
    logic [31:0]            strat_stat [16];

    strategy_engine u_strategy (
        .clk            (core_clk),
        .rst            (core_rst),
        .s_top          (book_top),
        .s_top_valid    (book_top_valid),
        // Gating: only quote when the venue and our own state permit it
        .sess_state     (sess_state),
        .m_req          (order_req),
        .m_req_valid    (order_req_valid),
        // Host parameter window (double-buffered, commit-bit protected)
        .cfg_param_wr   (cfg_strat_wr),
        .cfg_param_addr (cfg_strat_addr),
        .cfg_param_data (cfg_strat_data),
        .cfg_commit     (cfg_strat_commit),
        // Fill feedback closes the position loop
        .fill_valid     (fill_valid),
        .fill_sym       (fill_sym),
        .fill_side      (fill_side),
        .fill_qty       (fill_qty),
        .stat           (strat_stat)
    );

    // =========================================================================
    // Pre-trade risk gate — MANDATORY, NON-BYPASSABLE (SEC Rule 15c3-5)
    // manuals/08-nasdaq/09-risk-controls-and-limits.md
    // =========================================================================
    order_out_t             order_out;
    logic                   order_out_valid;
    logic                   kill_active;
    kill_src_e              kill_src;
    logic [31:0]            risk_reject_cnt [N_RISK_REASONS];
    logic [31:0]            risk_stat [8];

    // External kill input: asynchronous, so it crosses through a synchronizer.
    logic ext_kill_sync;
    cdc_sync_bit #(.STAGES(3)) u_ext_kill_cdc (
        .dst_clk (core_clk),
        .src_bit (~ext_kill_n),
        .dst_bit (ext_kill_sync)
    );

    risk_gate #(
        .KILL_RESP_CYCLES (KILL_RESP_CYCLES)
    ) u_risk_gate (
        .clk              (core_clk),
        .rst              (core_rst),
        .s_req            (order_req),
        .s_req_valid      (order_req_valid),
        .m_out            (order_out),
        .m_out_valid      (order_out_valid),
        // Venue state
        .sess_state       (sess_state),
        .sym_state_wr     (sym_state_wr),
        .sym_state_idx    (sym_state_idx),
        .sym_state_val    (sym_state_val),
        .sym_ssr_val      (sym_ssr_val),
        .sym_auc_collar_lo(sym_auc_collar_lo),
        .sym_auc_collar_hi(sym_auc_collar_hi),
        .book_top         (book_top),
        .book_top_valid   (book_top_valid),
        // Kill switch
        .host_kill        (cfg_kill),
        .host_heartbeat   (cfg_heartbeat),
        .ext_kill         (ext_kill_sync),
        .link_down        (~oe_link_up),
        .kill_active      (kill_active),
        .kill_src         (kill_src),
        // Host risk parameters (double-buffered)
        .cfg_param_wr     (cfg_risk_wr),
        .cfg_param_addr   (cfg_risk_addr),
        .cfg_param_data   (cfg_risk_data),
        .cfg_commit       (cfg_risk_commit),
        .cfg_trading_en   (cfg_trading_en),
        // Fill feedback maintains position
        .fill_valid       (fill_valid),
        .fill_sym         (fill_sym),
        .fill_side        (fill_side),
        .fill_qty         (fill_qty),
        .fill_px          (fill_px),
        // In-flight credit from the order gateway
        .credit_avail     (credit_avail),
        // Telemetry
        .reject_cnt       (risk_reject_cnt),
        .stat             (risk_stat)
    );

    // =========================================================================
    // Order gateway: OUCH encode -> SoupBinTCP -> TCP -> MAC TX
    // =========================================================================
    logic [AXIS_W-1:0]      oe_tx_tdata;
    logic [AXIS_KEEP_W-1:0] oe_tx_tkeep;
    logic                   oe_tx_tvalid, oe_tx_tlast, oe_tx_tready;
    logic [AXIS_W-1:0]      oe_rx_tdata;
    logic [AXIS_KEEP_W-1:0] oe_rx_tkeep;
    logic                   oe_rx_tvalid, oe_rx_tlast, oe_rx_tuser;
    logic                   oe_link_up;
    logic [31:0]            oe_mac_stat [4];
    logic                   credit_avail;
    logic [31:0]            order_stat [16];

    // Fill / ack feedback from the venue (parsed from the OUCH inbound stream)
    logic                   fill_valid;
    sym_idx_t               fill_sym;
    side_e                  fill_side;
    qty_t                   fill_qty;
    price_t                 fill_px;

    order_gateway u_order_gw (
        .clk              (core_clk),
        .rst              (core_rst),
        .cycle_cnt        (cycle_cnt),
        .s_out            (order_out),
        .s_out_valid      (order_out_valid),
        // MAC TX
        .m_axis_tdata     (oe_tx_tdata),
        .m_axis_tkeep     (oe_tx_tkeep),
        .m_axis_tvalid    (oe_tx_tvalid),
        .m_axis_tlast     (oe_tx_tlast),
        .m_axis_tready    (oe_tx_tready),
        // MAC RX (acks, fills, rejects)
        .s_axis_tdata     (oe_rx_tdata),
        .s_axis_tkeep     (oe_rx_tkeep),
        .s_axis_tvalid    (oe_rx_tvalid),
        .s_axis_tlast     (oe_rx_tlast),
        .s_axis_tuser     (oe_rx_tuser),
        // Decoded fills back to strategy and risk
        .fill_valid       (fill_valid),
        .fill_sym         (fill_sym),
        .fill_side        (fill_side),
        .fill_qty         (fill_qty),
        .fill_px          (fill_px),
        // In-flight credit: bounds what we can emit before the host accounts
        .credit_avail     (credit_avail),
        .credit_return    (cfg_credit_return),
        // Kill switch also gates the TX path directly (defence in depth)
        .kill_active      (kill_active),
        // Host-owned session state: templates, TCP 5-tuple, seq numbers
        .cfg_tmpl_wr      (cfg_tmpl_wr),
        .cfg_tmpl_addr    (cfg_tmpl_addr),
        .cfg_tmpl_data    (cfg_tmpl_data),
        .cfg_session_wr   (cfg_session_wr),
        .cfg_session_data (cfg_session_data),
        .stat             (order_stat)
    );

    eth_10g_wrapper #(
        .CUT_THROUGH (1),
        .RX_ONLY     (0),
        .LOW_LATENCY (1)
    ) u_oe_eth (
        .gt_refclk_p  (oe_gt_refclk_p),
        .gt_refclk_n  (oe_gt_refclk_n),
        .rxp          (oe_rx_p),
        .rxn          (oe_rx_n),
        .txp          (oe_tx_p),
        .txn          (oe_tx_n),
        .rx_clk       (oe_clk),
        .core_clk     (core_clk),
        .core_rst     (core_rst),
        .m_axis_tdata (oe_rx_tdata),
        .m_axis_tkeep (oe_rx_tkeep),
        .m_axis_tvalid(oe_rx_tvalid),
        .m_axis_tlast (oe_rx_tlast),
        .m_axis_tuser (oe_rx_tuser),
        .s_axis_tdata (oe_tx_tdata),
        .s_axis_tkeep (oe_tx_tkeep),
        .s_axis_tvalid(oe_tx_tvalid),
        .s_axis_tlast (oe_tx_tlast),
        .s_axis_tready(oe_tx_tready),
        .link_up      (oe_link_up),
        .stat         (oe_mac_stat)
    );

    // =========================================================================
    // Telemetry: counters + on-chip latency histogram
    // =========================================================================
    logic [31:0] telem_rdata;
    logic [15:0] telem_raddr;

    telemetry #(
        .N_BUCKETS (32)
    ) u_telemetry (
        .clk            (core_clk),
        .rst            (core_rst),
        .cycle_cnt      (cycle_cnt),
        // Latency sample: taken when an order leaves, measured from ingress
        .lat_valid      (order_out_valid),
        .lat_start      (order_out.rx_cycle),
        // Counter sources
        .md_mac_stat    (md_mac_stat),
        .oe_mac_stat    (oe_mac_stat),
        .net_stat       (net_stat),
        .feed_stat      (feed_stat),
        .book_stat      (book_stat),
        .strat_stat     (strat_stat),
        .risk_stat      (risk_stat),
        .risk_reject_cnt(risk_reject_cnt),
        .order_stat     (order_stat),
        .link_up        ({oe_link_up, md_link_up[1], md_link_up[0]}),
        .kill_active    (kill_active),
        .kill_src       (kill_src),
        // Read port for the CSR block
        .raddr          (telem_raddr),
        .rdata          (telem_rdata)
    );

    // =========================================================================
    // Host control plane (PCIe) — SLOW PATH ONLY
    // Nothing latency-critical crosses this boundary.
    // manuals/04-system-architecture/06-cpu-fpga-partitioning.md
    // =========================================================================
    logic        cfg_trading_en, cfg_kill, cfg_heartbeat;
    logic        cfg_filter_wr,  cfg_risk_wr,  cfg_strat_wr;
    logic        cfg_tmpl_wr,    cfg_session_wr;
    logic        cfg_risk_commit, cfg_strat_commit;
    logic        cfg_credit_return;
    logic [15:0] cfg_filter_addr, cfg_risk_addr, cfg_strat_addr, cfg_tmpl_addr;
    logic [31:0] cfg_filter_data, cfg_risk_data, cfg_strat_data, cfg_tmpl_data;
    logic [31:0] cfg_session_data;

    host_ctrl #(
        .BUILD_ID (BUILD_ID),
        .GIT_SHA  (GIT_SHA)
    ) u_host_ctrl (
        .pcie_clk         (pcie_clk),
        .pcie_rst         (pcie_rst),
        .pcie_refclk_p    (pcie_refclk_p),
        .pcie_refclk_n    (pcie_refclk_n),
        .pcie_rst_n       (pcie_rst_n),
        .pcie_rx_p        (pcie_rx_p),
        .pcie_rx_n        (pcie_rx_n),
        .pcie_tx_p        (pcie_tx_p),
        .pcie_tx_n        (pcie_tx_n),
        // Core-clock side. All CDC lives inside this module.
        .core_clk         (core_clk),
        .core_rst         (core_rst),
        .cfg_trading_en   (cfg_trading_en),
        .cfg_kill         (cfg_kill),
        .cfg_heartbeat    (cfg_heartbeat),
        .cfg_credit_return(cfg_credit_return),
        .cfg_filter_wr    (cfg_filter_wr),
        .cfg_filter_addr  (cfg_filter_addr),
        .cfg_filter_data  (cfg_filter_data),
        .cfg_risk_wr      (cfg_risk_wr),
        .cfg_risk_addr    (cfg_risk_addr),
        .cfg_risk_data    (cfg_risk_data),
        .cfg_risk_commit  (cfg_risk_commit),
        .cfg_strat_wr     (cfg_strat_wr),
        .cfg_strat_addr   (cfg_strat_addr),
        .cfg_strat_data   (cfg_strat_data),
        .cfg_strat_commit (cfg_strat_commit),
        .cfg_tmpl_wr      (cfg_tmpl_wr),
        .cfg_tmpl_addr    (cfg_tmpl_addr),
        .cfg_tmpl_data    (cfg_tmpl_data),
        .cfg_session_wr   (cfg_session_wr),
        .cfg_session_data (cfg_session_data),
        // Telemetry read-back
        .telem_raddr      (telem_raddr),
        .telem_rdata      (telem_rdata),
        .kill_active      (kill_active),
        .kill_src         (kill_src)
    );

    // =========================================================================
    // Status LEDs
    // =========================================================================
    always_ff @(posedge core_clk) begin
        led <= {kill_active,
                cfg_trading_en,
                feed_gap,
                oe_link_up,
                md_link_up[1],
                md_link_up[0],
                cycle_cnt[25],          // heartbeat blink
                1'b1};                  // power-on indicator
    end

    // =========================================================================
    // Top-level assertions — safety invariants, simulation only
    // =========================================================================
`ifndef SYNTHESIS
    // Rule 2: no order may leave without passing the risk gate. The gate is the
    // only driver of order_out_valid, so this asserts the structural property
    // that the gateway never sees traffic while the kill switch is asserted.
    assert property (@(posedge core_clk) disable iff (core_rst)
        kill_active |-> ##[0:KILL_RESP_CYCLES] !order_out_valid
    ) else $error("FATAL: order emitted more than %0d cycles after kill assert",
                  KILL_RESP_CYCLES);

    // Rule 4: fail-closed on reset.
    assert property (@(posedge core_clk)
        core_rst |-> !cfg_trading_en
    ) else $error("FATAL: trading enabled during reset");

    // Rule 1: the RX path must never stall. If any RX consumer ever needs to
    // backpressure, that is a design bug, not a runtime condition.
    assert property (@(posedge core_clk) disable iff (core_rst)
        md_axis_tvalid[0] |-> 1'b1
    );

    // A crossed book must never produce an order.
    assert property (@(posedge core_clk) disable iff (core_rst)
        (book_top_valid && book_top.crossed) |=> !order_req_valid
    ) else $error("order requested on a crossed book");

    // A stale book must never produce an order.
    assert property (@(posedge core_clk) disable iff (core_rst)
        (book_top_valid && book_top.stale) |=> !order_req_valid
    ) else $error("order requested on a stale book");

    // The host config path has no backpressure, so book_engine's cfg_ref_ready
    // cannot be obeyed — it exists to be CHECKED. The structural claim is that
    // the PCIe->core handshake (~8 pcie + ~6 core cycles per write, host_ctrl
    // CDC #7) cannot deliver two reference-price writes inside price_levels'
    // 4-cycle configuration FSM. If this ever fires, a symbol is anchored to a
    // price the host does not believe it wrote, which is worse than not being
    // anchored at all: the book would look alive and be wrong.
    assert property (@(posedge core_clk) disable iff (core_rst)
        book_cfg_valid |-> book_cfg_ready
    ) else $error("FATAL: host reference-price write dropped — book window anchored to an unknown base");
`endif

endmodule : fpga_top

`default_nettype wire
