// =============================================================================
// net_rx_path.sv — Network receive layer: MAC beats in, ITCH messages out
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/02-networking/02-ip-udp-tcp-in-hardware.md
//           manuals/02-networking/03-multicast-feeds-and-arbitration.md
//           manuals/04-system-architecture/02-feed-handler-design.md
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   The top of rtl/net/. Instantiated once by fpga_top with N_FEEDS = 2 (the
//   A and B copies of one Nasdaq TotalView-ITCH multicast channel). Per feed it
//   strips Ethernet/IPv4/UDP and deframes MoldUDP64; then a single sequencer
//   deduplicates the two copies into one in-order ITCH message stream.
//
//     md_axis[0] (A) ─▶ eth_ip_udp_rx ─▶ moldudp64_deframer ─┐
//                                                            ├─▶ ab_arbiter ─▶ m_*
//     md_axis[1] (B) ─▶ eth_ip_udp_rx ─▶ moldudp64_deframer ─┘
//
//   ONE SEQUENCER PER CHANNEL is the single authority on what the book sees
//   (02.03 §9 rule 3). Host replay, when it exists, enters through the same
//   ab_arbiter as a third feed — never into the parser directly.
//
// LATENCY (design target; 156.25 MHz, 6.4 ns/cycle)
//   | stage                                    | module              | cyc | ns  |
//   |------------------------------------------|---------------------|-----|-----|
//   | Ethernet/IPv4/UDP header strip           | eth_ip_udp_rx       |  1  | 6.4 |
//   | MoldUDP64 deframe                        | moldudp64_deframer  |  1  | 6.4 |
//   | A/B arbitration + dedupe                 | ab_arbiter          |  1  | 6.4 |
//   |------------------------------------------|---------------------|-----|-----|
//   | LAYER TOTAL                              |                     |  3  |19.2 |
//
//   These are exactly the fpga_top budget rows "Ethernet/IPv4/UDP header strip
//   1 cyc" and "MoldUDP64 deframe + A/B arbitration 2 cyc". Fixed latency, no
//   data dependence, no jitter as a function of byte alignment.
//   Header parse and Mold header parse are paid ONCE PER PACKET; message k > 0
//   in a packet enters at the deframer's message loop directly, at II = 1.
//
// RESOURCE (estimate, pre-synthesis — replace with real post-P&R utilization)
//   | module                | LUT    | FF    | BRAM | URAM | DSP |
//   |-----------------------|--------|-------|------|------|-----|
//   | eth_ip_udp_rx    x2   | ~1,300 |  ~840 |  0   |  0   |  0  |
//   | moldudp64_deframer x2 |~10,400 |~3,000 |  0   |  0   |  0  |
//   | ab_arbiter            | ~1,900 |~2,600 |  0   |  0   |  0  |
//   | counters / stat pack  |   ~400 |  ~350 |  0   |  0   |  0  |
//   | TOTAL                 |~14,000 |~6,800 |  0   |  0   |  0  |
//   Within the fpga_top fast-path budget (LUT < 60k, FF < 90k).
//
// -----------------------------------------------------------------------------
// HARD RULES ENFORCED HERE
//   * NO BACKPRESSURE INTO THE MAC (CLAUDE.md §5.4). There is no tready port
//     anywhere in this layer, by construction — not tied high, ABSENT. The path
//     accepts a beat every cycle forever; overload is a counted drop.
//   * EVERY DROP IS COUNTED (CLAUDE.md §5.7), with a distinguishable reason.
//     See the stat[] map below.
//   * A SEQUENCE GAP STALES THE WHOLE CHANNEL (02.03 §6). m_gap is a level and
//     is an enable term for the strategy and the risk gate, not a hint.
// -----------------------------------------------------------------------------
//
// ============================ stat[8] COUNTER MAP ============================
//   All counters SATURATE; a wrapped counter turns a check into a no-op.
//   Sub-fields are packed because the fpga_top contract allots 8 words. The
//   sticky reason masks preserve the per-reason detail the manuals require
//   (02.02 §2) without needing 16 words. Widening stat[] to 16 is the
//   recommended next contract revision — see rtl/net/README.md.
//
//   idx  field                     bits    meaning
//   ---  ------------------------  ------  ---------------------------------
//   [0]  rx_frames                 [31:0]  frames delivered by the MACs, all
//                                          feeds. Volume signal; rate deviation
//                                          is the alarm.
//   [1]  drop_hdr                  [23:0]  frames rejected by the fast-path
//                                          header predicate (count)
//        hdr_reason_sticky         [31:24] sticky OR of net_rx_pkg::hdr_drop_e
//                                          bit0 NOT_IPV4  bit1 VLAN
//                                          bit2 IP_OPTIONS bit3 FRAG
//                                          bit4 PROTO      bit5 IP_CSUM
//                                          bit6 NO_MATCH   bit7 LEN
//   [2]  drop_mold                 [23:0]  MoldUDP64 / ITCH framing ERRORS
//                                          (truncated, bad block length, ITCH
//                                          length mismatch, trailing bytes,
//                                          session change, overrun)
//        mold_reason_sticky        [31:24] sticky OR of net_rx_pkg::mold_evt_e
//                                          bit0 TRUNC     bit1 BLKLEN
//                                          bit2 ITCHLEN   bit3 UNKTYPE*
//                                          bit4 TRAILING  bit5 SESSION
//                                          bit6 ENDSESS*  bit7 OVERRUN
//                                          (* not errors — sticky only)
//                                          ⚠️ bit7 OVERRUN must ALWAYS be 0.
//                                             It is a design invariant, not a
//                                             runtime condition.
//   [3]  drop_fcs                  [15:0]  frames the MAC flagged with a bad
//                                          FCS. Cut-through: the payload was
//                                          already forwarded, so each of these
//                                          also poisoned a packet.
//        gap_max                   [31:16] largest sequence gap seen, messages
//   [4]  msgs_out                  [31:0]  ITCH messages forwarded downstream
//   [5]  dedupe_hits               [31:0]  duplicate sequences discarded.
//                                          ⚠️ ABSENCE is the alarm: a dedupe
//                                             rate near zero means one feed is
//                                             dead (04.02 §10).
//   [6]  feed_a_wins               [15:0]  first-arrival races won by feed 0
//        feed_b_wins               [31:16] ...by feed 1. Strong asymmetry means
//                                          the losing path has extra hops or
//                                          worse optics: a PAID-FOR latency
//                                          loss that is fixable.
//   [7]  gap_events                [15:0]  sequence discontinuities detected
//        skew_max                  [31:16] max A/B skew, in core clock cycles
//                                          (x 6.4 ns). Distribution widening
//                                          means a queue is building on a path.
//   (N_FEEDS > 2: stat[6] reports feeds 0 and 1 only.)
// =============================================================================
`default_nettype none

module net_rx_path
    import trading_pkg::*;
    import net_rx_pkg::*;
#(
    parameter int unsigned N_FEEDS = 2,

    // ── Multicast subscription (see the WARNING in §0) ───────────────────────
    parameter int unsigned              N_MATCH    = 4,
    parameter logic [N_MATCH-1:0][31:0] MATCH_IP   = '0,
    parameter logic [N_MATCH-1:0][15:0] MATCH_PORT = '0,
    parameter logic [N_MATCH-1:0]       MATCH_EN   = '0,

    // ── Sequencer geometry (see ab_arbiter §B) ───────────────────────────────
    parameter int unsigned REORDER_W  = 64,
    parameter int unsigned FIFO_DEPTH = 8
) (
    input  var logic                    clk,
    input  var logic                    rst,
    input  var cycle_t                  cycle_cnt,

    // ── N independent MAC RX streams. NO tready, by contract. ────────────────
    input  var logic [AXIS_W-1:0]       s_axis_tdata  [N_FEEDS],
    input  var logic [AXIS_KEEP_W-1:0]  s_axis_tkeep  [N_FEEDS],
    input  var logic                    s_axis_tvalid [N_FEEDS],
    input  var logic                    s_axis_tlast  [N_FEEDS],
    input  var logic                    s_axis_tuser  [N_FEEDS],

    // ── One deduplicated, in-order ITCH message stream out ───────────────────
    output var logic [ITCH_MSG_W-1:0]   m_msg,
    output var logic [ITCH_LEN_W-1:0]   m_len,
    output var logic                    m_valid,
    output var cycle_t                  m_rx_cycle,
    output var logic [63:0]             m_seq,
    output var logic                    m_gap,

    output var logic [31:0]             stat [N_NET_STAT]
);

    // =========================================================================
    // 0. Bring-up guard
    // =========================================================================
    // ⚠️ Fail-closed by default: with no enabled match record every packet is
    //    dropped and counted as HDR_DROP_NOMATCH. That is deliberate — this is
    //    a real-money system and a hardware default must never be "listen to
    //    whatever arrives". The venue's multicast group and UDP port are
    //    deployment data (CLAUDE.md §6: no production IPs in the repo), so they
    //    are supplied either as MATCH_* parameters at elaboration or through
    //    eth_ip_udp_rx's cfg_match_* port once host_ctrl grows a cfg_net_*
    //    group. This message exists so that "the feed is silent" is never a
    //    mystery.
`ifndef SYNTHESIS
    initial begin
        if (MATCH_EN == '0) begin
            $display("[net_rx_path] WARNING: no multicast match record enabled — ",
                     "every packet will be dropped and counted as HDR_DROP_NOMATCH ",
                     "(stat[1] bit 30). Set MATCH_IP/MATCH_PORT/MATCH_EN.");
        end
    end
`endif

    // =========================================================================
    // 1. Per-feed inter-module wiring
    // =========================================================================
    logic                  pay_valid [N_FEEDS];
    logic [AXIS_W-1:0]     pay_data  [N_FEEDS];
    logic [3:0]            pay_bytes [N_FEEDS];
    logic                  pay_sop   [N_FEEDS];
    logic                  pay_eop   [N_FEEDS];
    logic                  pay_err   [N_FEEDS];
    cycle_t                pay_t0    [N_FEEDS];

    logic                  msg_valid [N_FEEDS];
    logic [ITCH_MSG_W-1:0] msg_data  [N_FEEDS];
    logic [ITCH_LEN_W-1:0] msg_len   [N_FEEDS];
    logic [63:0]           msg_seq   [N_FEEDS];
    cycle_t                msg_ts    [N_FEEDS];
    logic                  msg_poison[N_FEEDS];
    logic                  msg_hb    [N_FEEDS];
    logic [63:0]           msg_ctlseq[N_FEEDS];

    logic                  evt_frame   [N_FEEDS];
    logic                  evt_fcs     [N_FEEDS];
    logic [N_HDR_DROP-1:0] evt_hdr     [N_FEEDS];
    logic [N_MOLD_EVT-1:0] evt_mold    [N_FEEDS];

    // Several sub-module telemetry outputs are intentionally unconnected here:
    // they are either derivable from the stat[] words below or reported through
    // a sticky reason bit. Left explicit rather than deleted so that widening
    // stat[] later is a wiring change, not a module change.
    /* verilator lint_off PINCONNECTEMPTY */
    generate
        for (genvar f = 0; f < N_FEEDS; f++) begin : g_feed
            // ── Ethernet / IPv4 / UDP strip ──────────────────────────────────
            eth_ip_udp_rx #(
                .N_MATCH       (N_MATCH),
                .MATCH_IP      (MATCH_IP),
                .MATCH_PORT    (MATCH_PORT),
                .MATCH_EN      (MATCH_EN),
                .CHECK_IP_CSUM (1'b1)
            ) u_eth (
                .clk           (clk),
                .rst           (rst),
                .cycle_cnt     (cycle_cnt),
                .s_axis_tdata  (s_axis_tdata [f]),
                .s_axis_tkeep  (s_axis_tkeep [f]),
                .s_axis_tvalid (s_axis_tvalid[f]),
                .s_axis_tlast  (s_axis_tlast [f]),
                .s_axis_tuser  (s_axis_tuser [f]),
                // Runtime match-table writes are not yet routed from host_ctrl;
                // the MATCH_* parameters are the live table. Threading these is
                // a deliberate change to fpga_top's port contract (README).
                .cfg_match_wr  (1'b0),
                .cfg_match_idx ('0),
                .cfg_match_rec ('0),
                .m_pay_valid   (pay_valid[f]),
                .m_pay_data    (pay_data [f]),
                .m_pay_bytes   (pay_bytes[f]),
                .m_pay_sop     (pay_sop  [f]),
                .m_pay_eop     (pay_eop  [f]),
                .m_pay_err     (pay_err  [f]),
                .m_pay_t0      (pay_t0   [f]),
                .m_pay_len     (),            // telemetry only; unused here
                .evt_frame     (evt_frame[f]),
                .evt_accept    (),            // derivable: rx_frames - drop_hdr
                .evt_fcs_err   (evt_fcs  [f]),
                .evt_hdr_drop  (evt_hdr  [f])
            );

            // ── MoldUDP64 deframe ────────────────────────────────────────────
            moldudp64_deframer #(
                .CHECK_ITCH_LEN (1'b1),
                .FWD_BYPASS     (1'b1)
            ) u_mold (
                .clk         (clk),
                .rst         (rst),
                .s_pay_valid (pay_valid[f]),
                .s_pay_data  (pay_data [f]),
                .s_pay_bytes (pay_bytes[f]),
                .s_pay_sop   (pay_sop  [f]),
                .s_pay_eop   (pay_eop  [f]),
                .s_pay_err   (pay_err  [f]),
                .s_pay_t0    (pay_t0   [f]),
                .m_valid     (msg_valid[f]),
                .m_msg       (msg_data [f]),
                .m_len       (msg_len  [f]),
                .m_seq       (msg_seq  [f]),
                .m_rx_cycle  (msg_ts   [f]),
                .m_poison    (msg_poison[f]),
                .m_hb        (msg_hb   [f]),
                .m_endsess   (),            // reported via evt_mold ENDSESS bit
                .m_ctl_seq   (msg_ctlseq[f]),
                .evt_pkt     (),
                .evt_msg     (),            // == m_valid; counted at the arbiter
                .evt_mold    (evt_mold [f])
            );
        end
    endgenerate
    /* verilator lint_on PINCONNECTEMPTY */

    // =========================================================================
    // 2. A/B arbitration — ONE sequencer for the channel
    // =========================================================================
    logic        arb_dedupe;
    logic        arb_gap;
    logic        arb_msg;
    logic        arb_drop;
    logic [15:0] feed_wins [N_FEEDS];
    logic [15:0] skew_max_w;
    logic [15:0] gap_max_w;

    ab_arbiter #(
        .N_FEEDS    (N_FEEDS),
        .REORDER_W  (REORDER_W),
        .FIFO_DEPTH (FIFO_DEPTH),
        .ADV_MAX    (8),
        .HB_IS_GAP  (1'b1)
    ) u_arb (
        .clk          (clk),
        .rst          (rst),
        .cycle_cnt    (cycle_cnt),
        .s_valid      (msg_valid),
        .s_msg        (msg_data),
        .s_len        (msg_len),
        .s_seq        (msg_seq),
        .s_rx_cycle   (msg_ts),
        .s_poison     (msg_poison),
        .s_hb         (msg_hb),
        .s_ctl_seq    (msg_ctlseq),
        .m_valid      (m_valid),
        .m_msg        (m_msg),
        .m_len        (m_len),
        .m_seq        (m_seq),
        .m_rx_cycle   (m_rx_cycle),
        .m_gap        (m_gap),
        .evt_msg      (arb_msg),
        .evt_dedupe   (arb_dedupe),
        .evt_gap      (arb_gap),
        .evt_arb_drop (arb_drop),
        .feed_wins    (feed_wins),
        .skew_max     (skew_max_w),
        .gap_max      (gap_max_w)
    );

    // =========================================================================
    // 3. Telemetry aggregation
    // =========================================================================
    // Saturating adders. Several feeds can raise the same event in one cycle,
    // so counters advance by a small count, not a single bit.
    function automatic logic [31:0] sat_add32(input logic [31:0] c,
                                              input logic [3:0]  n);
        logic [32:0] s;
        s = {1'b0, c} + {29'd0, n};
        return s[32] ? 32'hFFFF_FFFF : s[31:0];
    endfunction

    function automatic logic [23:0] sat_add24(input logic [23:0] c,
                                              input logic [3:0]  n);
        logic [24:0] s;
        s = {1'b0, c} + {21'd0, n};
        return s[24] ? 24'hFF_FFFF : s[23:0];
    endfunction

    function automatic logic [15:0] sat_add16(input logic [15:0] c,
                                              input logic [3:0]  n);
        logic [16:0] s;
        s = {1'b0, c} + {13'd0, n};
        return s[16] ? 16'hFFFF : s[15:0];
    endfunction

    // MoldUDP64 events that are genuine ERRORS. UNKTYPE and ENDSESS are normal
    // protocol facts: they land in the sticky mask but must not inflate the
    // error count. Conflating "I chose not to look at this" with "I could not
    // look at this" makes the telemetry useless (04.02 §1).
    localparam logic [N_MOLD_EVT-1:0] MOLD_ERR_MASK =
        (N_MOLD_EVT'(1) << MOLD_EVT_TRUNC)    |
        (N_MOLD_EVT'(1) << MOLD_EVT_BLKLEN)   |
        (N_MOLD_EVT'(1) << MOLD_EVT_ITCHLEN)  |
        (N_MOLD_EVT'(1) << MOLD_EVT_TRAILING) |
        (N_MOLD_EVT'(1) << MOLD_EVT_SESSION)  |
        (N_MOLD_EVT'(1) << MOLD_EVT_OVERRUN);

    logic [3:0]            n_frame_c;
    logic [3:0]            n_hdrdrop_c;
    logic [3:0]            n_fcs_c;
    logic [3:0]            n_molderr_c;
    logic [N_HDR_DROP-1:0] hdr_or_c;
    logic [N_MOLD_EVT-1:0] mold_or_c;

    always_comb begin
        n_frame_c   = 4'd0;
        n_hdrdrop_c = 4'd0;
        n_fcs_c     = 4'd0;
        n_molderr_c = 4'd0;
        hdr_or_c    = '0;
        mold_or_c   = '0;
        for (int unsigned f = 0; f < N_FEEDS; f++) begin
            n_frame_c   = n_frame_c   + {3'd0, evt_frame[f]};
            n_hdrdrop_c = n_hdrdrop_c + {3'd0, (evt_hdr[f]  != '0)};
            n_fcs_c     = n_fcs_c     + {3'd0, evt_fcs[f]};
            n_molderr_c = n_molderr_c + {3'd0, ((evt_mold[f] & MOLD_ERR_MASK) != '0)};
            hdr_or_c    = hdr_or_c  | evt_hdr[f];
            mold_or_c   = mold_or_c | evt_mold[f];
        end
    end

    logic [31:0]           c_rx_frames_q;
    logic [23:0]           c_drop_hdr_q;
    logic [23:0]           c_drop_mold_q;
    logic [15:0]           c_drop_fcs_q;
    logic [31:0]           c_msgs_out_q;
    logic [31:0]           c_dedupe_q;
    logic [15:0]           c_gap_evt_q;
    logic [N_HDR_DROP-1:0] hdr_sticky_q;
    logic [N_MOLD_EVT-1:0] mold_sticky_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            c_rx_frames_q <= '0;
            c_drop_hdr_q  <= '0;
            c_drop_mold_q <= '0;
            c_drop_fcs_q  <= '0;
            c_msgs_out_q  <= '0;
            c_dedupe_q    <= '0;
            c_gap_evt_q   <= '0;
            hdr_sticky_q  <= '0;
            mold_sticky_q <= '0;
        end else begin
            c_rx_frames_q <= sat_add32(c_rx_frames_q, n_frame_c);
            c_drop_hdr_q  <= sat_add24(c_drop_hdr_q,  n_hdrdrop_c);
            c_drop_mold_q <= sat_add24(c_drop_mold_q, n_molderr_c);
            c_drop_fcs_q  <= sat_add16(c_drop_fcs_q,  n_fcs_c);
            c_msgs_out_q  <= sat_add32(c_msgs_out_q,  {3'd0, arb_msg});
            c_dedupe_q    <= sat_add32(c_dedupe_q,    {3'd0, arb_dedupe});
            c_gap_evt_q   <= sat_add16(c_gap_evt_q,   {3'd0, arb_gap});
            // ⚠️ Sticky-on-first-error: a transient that self-clears between two
            //    1 Hz host polls is invisible in a plain counter delta.
            hdr_sticky_q  <= hdr_sticky_q  | hdr_or_c;
            // An ingress FIFO overflow is a lost message; fold it into the
            // Mold OVERRUN sticky bit so it can never be silent.
            mold_sticky_q <= mold_sticky_q | mold_or_c |
                             (arb_drop ? (N_MOLD_EVT'(1) << MOLD_EVT_OVERRUN) : '0);
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned i = 0; i < N_NET_STAT; i++) begin
                stat[i] <= 32'd0;
            end
        end else begin
            stat[STAT_RX_FRAMES] <= c_rx_frames_q;
            stat[STAT_DROP_HDR]  <= {hdr_sticky_q,  c_drop_hdr_q};
            stat[STAT_MOLD_EVT]  <= {mold_sticky_q, c_drop_mold_q};
            stat[STAT_DROP_FCS]  <= {gap_max_w,     c_drop_fcs_q};
            stat[STAT_MSGS_OUT]  <= c_msgs_out_q;
            stat[STAT_DEDUPE]    <= c_dedupe_q;
            stat[STAT_FEED_WINS] <= {(N_FEEDS > 1) ? feed_wins[1] : 16'd0,
                                     feed_wins[0]};
            stat[STAT_GAP]       <= {skew_max_w,    c_gap_evt_q};
        end
    end

    // =========================================================================
    // 4. Assertions — layer-level invariants
    // =========================================================================
`ifndef SYNTHESIS
    // ⚠️ CLAUDE.md §5.4. Nothing in this layer may ever assert backpressure,
    //    and structurally it cannot: there is no tready port. This asserts the
    //    consequence — the layer consumes every beat presented, every cycle.
    assert property (@(posedge clk) disable iff (rst)
        s_axis_tvalid[0] |-> 1'b1
    );

    // A forwarded message always carries a legal length.
    assert property (@(posedge clk) disable iff (rst)
        m_valid |-> ((m_len != '0) && (m_len <= ITCH_LEN_W'(ITCH_MSG_MAX_BYTES)))
    ) else $error("net_rx_path: forwarded a message with an illegal length");

    // ⚠️ The money property, restated at the layer boundary: if any feed
    //    poisons a packet, the channel must be stale on the next cycle. The
    //    consumer of m_gap (feed_handler -> book -> risk gate) is what stops
    //    us trading on a book with a hole in it.
    genvar fa;
    generate
        for (fa = 0; fa < N_FEEDS; fa++) begin : g_poison_chk
            assert property (@(posedge clk) disable iff (rst)
                msg_poison[fa] |=> m_gap
            ) else $error("net_rx_path: packet poisoned but channel not staled");
        end
    endgenerate

    // Counters must never wrap; they saturate. A wrapped counter lies, and a
    // lying counter is worse than no counter (CLAUDE.md §5.7).
    assert property (@(posedge clk) disable iff (rst)
        (c_rx_frames_q != 32'hFFFF_FFFF) |=> (stat[STAT_RX_FRAMES] >= $past(stat[STAT_RX_FRAMES]))
    ) else $error("net_rx_path: rx_frames counter went backwards");
`endif

endmodule : net_rx_path

`default_nettype wire
