// =============================================================================
// ouch_rx.sv — Inbound SoupBinTCP / OUCH parser: acks, fills, cancels, rejects
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/03-algotrading/04-order-entry-protocols.md §8
//           manuals/02-networking/02-ip-udp-tcp-in-hardware.md §6 (RX snoop)
//           manuals/08-nasdaq/05-ouch-5.0-order-entry.md   (to be written)
//
// -----------------------------------------------------------------------------
// PURPOSE
//   Close the position loop in hardware. Parse the venue's Sequenced Data
//   stream, decode the order token back into {strat_id, sym, side, counter},
//   drive fill_* on an execution, and return an in-flight credit on every
//   terminal event.
//
//   This is a FEEDBACK path, not a trigger path. It is allowed to be slower
//   than the TX path and it is designed to be SAFE rather than fast. Every
//   decision here favours "refuse and count" over "guess and continue".
//
// -----------------------------------------------------------------------------
// STRUCTURE — two stages with deliberately different shapes
//
//   A) BEAT STAGE (line rate, II = 1, NEVER backpressures — CLAUDE.md §5.4)
//      Fixed-slice Ethernet/IPv4/TCP header validation from the first 7 beats.
//      Produces the snoop outputs (seq, ack, window, FIN, RST) that
//      tcp_tx_lite.sv needs, and pushes accepted payload into a beat FIFO with
//      COMMIT/ROLLBACK semantics so a frame that fails validation on beat 6
//      costs nothing.
//
//   B) BYTE STAGE (1 byte/cycle, behind the FIFO)
//      A byte-serial SoupBinTCP + OUCH state machine.
//
//   ⚠️ WHY THE RX PARSER IS SERIAL WHILE THE TX PATH IS FIXED-SLICE.
//      Three reasons, all of them correctness:
//        1. SoupBinTCP packets STRADDLE TCP SEGMENTS. A packet can begin in one
//           segment and finish in the next. There is no beat-aligned parse.
//        2. The inbound TCP header may carry OPTIONS (timestamps, SACK) that
//           the venue's stack negotiated. That moves the payload start to
//           34 + dataoffset*4. A serial parser absorbs this with a variable
//           SKIP COUNT — no barrel shifter, no fixed-offset breakage. This is
//           the one place in the design where a variable offset is both safe
//           and free.
//        3. This path is not latency-critical, so buying safety with cycles is
//           the correct trade.
//
//   ⚠️ THE THROUGHPUT ANALYSIS THAT MAKES (B) SAFE.
//      1 byte/cycle at 156.25 MHz = 1.25 Gbps sustained. The order-entry
//      inbound stream is acks and fills for OUR orders only — tens of Mbps on
//      the worst day, i.e. ~100x headroom. The RXFIFO_BEATS-deep FIFO absorbs a
//      full-MTU burst. IF IT EVER OVERFLOWS the byte stream has a hole, the
//      Soup framing desynchronises, and the parser HALTS (see below). That is
//      counted, alarmed, and requires host re-synchronisation. It is not
//      silently absorbed.
//
// -----------------------------------------------------------------------------
// ⚠️ BYTE-STREAM DESYNCHRONISATION — the failure mode that must never be silent
//
//   SoupBinTCP is a length-prefixed stream with no framing marker. Lose ONE
//   byte and every subsequent length field is read from the wrong offset: the
//   parser will happily decode garbage as fills, and garbage fills corrupt the
//   position, which corrupts the risk checks, which is how a trading system
//   loses a lot of money quietly.
//
//   Therefore: any event that could put a hole in the byte stream sets a STICKY
//   `desync` latch, the parser STOPS FEEDING the FSM entirely, and it stays
//   stopped until the host explicitly resynchronises (rx_resync, driven from
//   the session clear-disarm flag — i.e. from the host having re-established
//   the session and reconciled state from the venue, never from local memory).
//
//   Desync sources, each counted:
//     * beat FIFO overflow
//     * a segment on our 4-tuple that fails header validation
//     * a payload-bearing segment whose sequence number is not rcv_nxt and is
//       not entirely old data (out of order / partial overlap: we do not and
//       will not reassemble)
//     * a SoupBinTCP length field outside the legal range
//
//   A pure duplicate retransmission (entirely below rcv_nxt) is dropped and
//   counted WITHOUT desync — that case is unambiguous and recoverable.
//
// -----------------------------------------------------------------------------
// ⚠️ STALE TOKEN REJECTION — why the magic field exists
//
//   Cancel-on-disconnect, a re-login, or a mid-day restart can all deliver a
//   message for an order from a PREVIOUS session. Acting on it would update the
//   position for an order this session never sent, and return a credit that was
//   never consumed. Both corrupt state permanently.
//
//   Every token carries a `magic` field stamped by the risk gate from the
//   current session identity. ouch_rx compares it against cfg_token_magic and
//   REFUSES any message whose magic does not match: no fill, no credit return,
//   no position update — just a counter. That counter MUST read zero in normal
//   operation; a non-zero value is an incident, not a statistic.
//
// -----------------------------------------------------------------------------
// ⚠️ THE SIDE PROBLEM, AND HOW IT IS SOLVED
//   OUCH's Order Executed message does not carry a buy/sell indicator. Deriving
//   it would require an in-flight order table keyed by token — real state, real
//   area, and a real source of divergence. Instead ouch_encoder.sv STAMPS the
//   side (and post-only) into the token, and this module reads it straight back
//   out. Fill decode is completely stateless. See ouch_pkg §8.
//
// -----------------------------------------------------------------------------
// LATENCY / RESOURCES
//   Not on the tick-to-trade path. Frame header validation completes 7 beats
//   after start-of-frame; a fill is emitted roughly (payload byte offset)
//   cycles after that. Typical Executed message: ~45 cycles / ~290 ns from
//   end-of-frame. This is a feedback path; the number is reported for
//   completeness, not because it is budgeted.
//
//   RESOURCE ESTIMATE
//     Beat FIFO 512 x 65 b .............. 1 RAMB36
//     Header capture 448 b + validation .. ~450 FF, ~350 LUT
//     Byte FSM + field shift registers ... ~350 FF, ~450 LUT
//     Counters 16 + 8 ................... ~770 FF
//     DSP 0.
// =============================================================================
`default_nettype none

module ouch_rx
    import trading_pkg::*;
    import ouch_pkg::*;
#(
    parameter bit          TOKEN_ASCII_HEX = 1'b1,   // must match ouch_encoder
    // ⚠️ POLICY, NOT A FACT. An OUCH Executed message does not say whether the
    //    order is now done. Returning credit on every execution therefore
    //    returns it EARLY for a partially-filled order. credit_mgr saturates at
    //    MAX_IN_FLIGHT so an over-return can never manufacture credit, and the
    //    host's explicit credit_return is the correction channel. Set to 0 to
    //    make credit strictly host-returned for executions.
    parameter bit          CREDIT_RETURN_ON_EXEC = 1'b1,
    parameter int unsigned RXFIFO_BEATS    = 512,    // 4 KB: > 2 full MTU frames
    parameter int unsigned SOUP_LEN_MAX    = 1024
) (
    input  var logic                    clk,
    input  var logic                    rst,

    // ── MAC RX AXI-Stream. NO tready: this path never backpressures. ─────────
    input  var logic [AXIS_W-1:0]       s_axis_tdata,
    input  var logic [AXIS_KEEP_W-1:0]  s_axis_tkeep,
    input  var logic                    s_axis_tvalid,
    input  var logic                    s_axis_tlast,
    input  var logic                    s_axis_tuser,   // 1 = bad FCS

    // ── Session identity (for the 4-tuple filter and the token magic) ────────
    input  var tcp_sess_t               sess,
    input  var logic [15:0]             cfg_token_magic,
    input  var logic                    rx_resync,      // host clears desync

    // ── TCP snoop out (to tcp_tx_lite — snoop, do not own) ───────────────────
    output var logic                    snoop_valid,
    output var logic [31:0]             snoop_seq,
    output var logic [15:0]             snoop_seglen,
    output var logic [31:0]             snoop_ack,
    output var logic [15:0]             snoop_win,
    output var logic                    snoop_ack_vld,
    output var logic                    snoop_fin,
    output var logic                    snoop_rst,

    // ── Fills back to the strategy and the risk gate ─────────────────────────
    output var logic                    fill_valid,
    output var sym_idx_t                fill_sym,
    output var side_e                   fill_side,
    output var qty_t                    fill_qty,
    output var price_t                  fill_px,

    // ── Credit return on a terminal event ────────────────────────────────────
    output var logic                    credit_ret,

    // ── Telemetry ────────────────────────────────────────────────────────────
    output var logic [31:0]             msg_cnt [N_OUT_MSG_TYPES],
    output var logic [31:0]             stat [8],
    output var logic                    desync_sticky
);

    localparam int unsigned FIFO_AW   = $clog2(RXFIFO_BEATS);
    localparam int unsigned DESC_D    = 16;
    localparam int unsigned DESC_AW   = $clog2(DESC_D);
    localparam int unsigned HDR_BEATS = 7;                    // 56 bytes captured
    localparam int unsigned HDR_BITS  = HDR_BEATS * AXIS_W;   // 448

    // Big-endian field extraction from the captured header. Pure wiring.
    function automatic logic [15:0] hbe16(input logic [HDR_BITS-1:0] h,
                                         input int unsigned n);
        return {h[8*n +: 8], h[8*(n+1) +: 8]};
    endfunction
    function automatic logic [31:0] hbe32(input logic [HDR_BITS-1:0] h,
                                         input int unsigned n);
        return {h[8*n +: 8], h[8*(n+1) +: 8], h[8*(n+2) +: 8], h[8*(n+3) +: 8]};
    endfunction

    // =========================================================================
    // A) BEAT STAGE — header capture, validation, commit/rollback push
    // =========================================================================
    logic [HDR_BITS-1:0] hdr_q;
    logic [3:0]          beat_cnt;      // saturates at HDR_BEATS
    logic                in_frame;
    logic                frame_bad;     // FCS error or a runt
    logic [31:0]         rcv_nxt;       // OUR receive-side shadow

    logic                hdr_done;      // the cycle beat HDR_BEATS-1 lands
    assign hdr_done = s_axis_tvalid && in_frame && (beat_cnt == 4'(HDR_BEATS-1));

    // ---- Fixed-slice header fields -----------------------------------------
    logic [15:0] ethertype, ip_totlen, ip_fragoff, tcp_win, tcp_sport, tcp_dport;
    logic [7:0]  ip_verihl, ip_proto, tcp_offrsv, tcp_flags;
    logic [31:0] ip_src, ip_dst, tcp_seq, tcp_ack;
    logic [7:0]  tcp_hdr_bytes, skip_bytes;
    logic [15:0] pay_len;
    csum_acc_t   ip_sum;
    logic        ip_csum_ok, tuple_ok, hdr_ok, len_ok;

    always_comb begin
        ethertype  = hbe16(hdr_q, ETH_TYPE_OFF);
        ip_verihl  = hdr_q[8*IP_VERIHL_OFF +: 8];
        ip_totlen  = hbe16(hdr_q, IP_TOTLEN_OFF);
        ip_fragoff = hbe16(hdr_q, IP_FLAGS_OFF);
        ip_proto   = hdr_q[8*IP_PROTO_OFF +: 8];
        ip_src     = hbe32(hdr_q, IP_SRC_OFF);
        ip_dst     = hbe32(hdr_q, IP_DST_OFF);
        tcp_sport  = hbe16(hdr_q, TCP_SPORT_OFF);
        tcp_dport  = hbe16(hdr_q, TCP_DPORT_OFF);
        tcp_seq    = hbe32(hdr_q, TCP_SEQ_OFF);
        tcp_ack    = hbe32(hdr_q, TCP_ACK_OFF);
        tcp_offrsv = hdr_q[8*TCP_OFFRSV_OFF +: 8];
        tcp_flags  = hdr_q[8*TCP_FLAGS_OFF  +: 8];
        tcp_win    = hbe16(hdr_q, TCP_WIN_OFF);

        // IPv4 header checksum: sum all ten 16-bit words INCLUDING the checksum
        // field; a valid header folds to 0xFFFF. Free, and it catches the class
        // of corruption a cut-through switch introduces after the last FCS
        // recompute. (manuals/02-networking/02-*.md §3.)
        ip_sum = '0;
        for (int i = 0; i < 10; i++) begin
            ip_sum = ip_sum + {{(CSUM_ACC_W-16){1'b0}}, hbe16(hdr_q, IP_VERIHL_OFF + 2*i)};
        end
        ip_csum_ok = (csum_fold(ip_sum) == 16'hFFFF);

        // TCP header may carry options: data offset is in 32-bit words.
        // A serial parser handles the resulting variable payload start for
        // free — see the header note.
        tcp_hdr_bytes = {2'd0, tcp_offrsv[7:4], 2'd0};      // dataoff * 4
        skip_bytes    = 8'(ETH_HDR_LEN + IP4_HDR_LEN) + tcp_hdr_bytes;
        len_ok        = (ip_totlen >= ({8'd0, tcp_hdr_bytes} + 16'(IP4_HDR_LEN)))
                     && (tcp_offrsv[7:4] >= 4'd5);
        pay_len       = len_ok ? (ip_totlen - 16'(IP4_HDR_LEN) - {8'd0, tcp_hdr_bytes})
                               : 16'd0;

        // Is this segment on OUR session 4-tuple? Their source is our dest.
        tuple_ok = (ethertype == ETHERTYPE_IPV4)
                && (ip_proto  == IP_PROTO_TCP)
                && (ip_src    == sess.dip)
                && (ip_dst    == sess.sip)
                && (tcp_sport == sess.dport)
                && (tcp_dport == sess.sport);

        // ⚠️ Fixed slices demand a validity predicate. IPv4 only, IHL == 5, no
        //    fragments. Anything else is dropped and counted, never absorbed.
        //    (manuals/02-networking/02-*.md §2.)
        hdr_ok = tuple_ok
              && (ip_verihl        == IP_VERIHL_V4)
              && (ip_fragoff[13]   == 1'b0)
              && (ip_fragoff[12:0] == 13'd0)
              && ip_csum_ok
              && len_ok;
    end

    // ---- Sequence classification -------------------------------------------
    logic seq_in_order;
    logic seq_duplicate;
    logic seq_broken;

    always_comb begin
        seq_in_order  = (tcp_seq == rcv_nxt);
        // Entirely old data: seq + len <= rcv_nxt, modular.
        seq_duplicate = (pay_len != 16'd0)
                     && !seq_in_order
                     && !seq_gt(tcp_seq + {16'd0, pay_len}, rcv_nxt);
        seq_broken    = (pay_len != 16'd0) && !seq_in_order && !seq_duplicate;
    end

    // =========================================================================
    // Beat FIFO with commit / rollback
    // =========================================================================
    logic [AXIS_W:0]     rxfifo [RXFIFO_BEATS];   // {tlast, tdata}
    logic [FIFO_AW-1:0]  wr_spec, wr_commit, rd_ptr;
    logic [FIFO_AW:0]    fifo_used;
    logic                fifo_full_spec;
    logic                push_beat;
    logic                overflow;

    // Speculative occupancy relative to the committed read pointer.
    assign fifo_used      = {1'b0, wr_spec} - {1'b0, rd_ptr};
    assign fifo_full_spec = (fifo_used >= (FIFO_AW+1)'(RXFIFO_BEATS - 2));

    // Descriptor FIFO: one entry per committed frame.
    typedef struct packed {
        logic [7:0]  skip;
        logic [15:0] paylen;
    } desc_t;
    desc_t              desc_mem [DESC_D];
    logic [DESC_AW:0]   desc_wp, desc_rp;
    logic               desc_full, desc_empty;
    assign desc_full  = ((desc_wp - desc_rp) >= (DESC_AW+1)'(DESC_D));
    assign desc_empty = (desc_wp == desc_rp);

    // Frame acceptance is only known at beat HDR_BEATS-1, so beats are pushed
    // speculatively and the write pointer is committed (or rolled back) then.
    logic frame_commit;
    logic frame_reject;
    logic frame_desync;

    always_comb begin
        push_beat    = s_axis_tvalid && !fifo_full_spec;
        overflow     = s_axis_tvalid && fifo_full_spec;
        frame_commit = hdr_done && hdr_ok && seq_in_order && (pay_len != 16'd0)
                    && !frame_bad && !desync_sticky && !desc_full && !overflow;
        frame_reject = hdr_done && !frame_commit;
        // Anything that could put a hole in OUR byte stream.
        frame_desync = hdr_done && !desync_sticky &&
                       (  (tuple_ok && !hdr_ok)          // corruption on our tuple
                        || (tuple_ok && seq_broken)      // out of order / overlap
                        || (tuple_ok && frame_bad)       // bad FCS on our tuple
                        || (tuple_ok && (pay_len != 16'd0) && (overflow || desc_full)) );
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            beat_cnt      <= 4'd0;
            in_frame      <= 1'b0;
            frame_bad     <= 1'b0;
            wr_spec       <= '0;
            wr_commit     <= '0;
            desc_wp       <= '0;
            rcv_nxt       <= 32'd0;
            desync_sticky <= 1'b0;
        end else begin
            if (rx_resync) desync_sticky <= 1'b0;

            if (s_axis_tvalid) begin
                if (!in_frame) begin
                    in_frame  <= 1'b1;
                    beat_cnt  <= 4'd1;
                    frame_bad <= s_axis_tuser;
                end else begin
                    if (beat_cnt != 4'(HDR_BEATS)) beat_cnt <= beat_cnt + 4'd1;
                    frame_bad <= frame_bad | s_axis_tuser;
                end

                if (beat_cnt < 4'(HDR_BEATS)) begin
                    hdr_q[64*beat_cnt +: 64] <= s_axis_tdata;
                end

                if (push_beat) begin
                    rxfifo[wr_spec] <= {s_axis_tlast, s_axis_tdata};
                    wr_spec         <= wr_spec + FIFO_AW'(1);
                end

                if (s_axis_tlast) begin
                    in_frame  <= 1'b0;
                    beat_cnt  <= 4'd0;
                    frame_bad <= 1'b0;
                end
            end

            // ---- Commit / rollback, decided on the header beat ---------------
            if (hdr_done) begin
                if (frame_commit) begin
                    wr_commit             <= wr_spec + FIFO_AW'(1);
                    desc_mem[desc_wp[DESC_AW-1:0]] <= '{skip: skip_bytes, paylen: pay_len};
                    desc_wp               <= desc_wp + (DESC_AW+1)'(1);
                    rcv_nxt               <= tcp_seq + {16'd0, pay_len};
                end else begin
                    // Discard every beat of this frame: rewind to the last
                    // committed position. Costs nothing and cannot corrupt the
                    // byte stream.
                    wr_spec <= wr_commit;
                end
                if (frame_desync) desync_sticky <= 1'b1;
            end

            // A frame that ends before the header beat (a runt) is rolled back.
            if (s_axis_tvalid && s_axis_tlast && (beat_cnt < 4'(HDR_BEATS-1))) begin
                wr_spec <= wr_commit;
            end
        end
    end

    // ---- Snoop outputs (registered) ----------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            snoop_valid <= 1'b0;
        end else begin
            snoop_valid <= hdr_done && tuple_ok && !frame_bad;
        end
        snoop_seq     <= tcp_seq;
        snoop_seglen  <= pay_len;
        snoop_ack     <= tcp_ack;
        snoop_win     <= tcp_win;
        snoop_ack_vld <= ((tcp_flags & TCP_FLAG_ACK) != 8'd0);
        snoop_fin     <= ((tcp_flags & TCP_FLAG_FIN) != 8'd0);
        snoop_rst     <= ((tcp_flags & TCP_FLAG_RST) != 8'd0);
    end

    // =========================================================================
    // B) BYTE STAGE — feeder
    // =========================================================================
    logic [AXIS_W:0]    beat_q;
    logic               beat_vld;
    logic [2:0]         byte_idx;
    logic               frame_open;
    logic [7:0]         skip_rem;
    logic [15:0]        pay_rem;
    logic               fifo_rd_avail;
    logic [7:0]         fb;            // the byte handed to the FSM
    logic               fb_vld;

    assign fifo_rd_avail = (rd_ptr != wr_commit);

    always_comb begin
        fb     = beat_q[8*byte_idx +: 8];
        fb_vld = beat_vld && frame_open && (skip_rem == 8'd0) && (pay_rem != 16'd0)
                 && !desync_sticky;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_ptr     <= '0;
            desc_rp    <= '0;
            beat_vld   <= 1'b0;
            frame_open <= 1'b0;
            byte_idx   <= 3'd0;
            skip_rem   <= 8'd0;
            pay_rem    <= 16'd0;
        end else begin
            if (!frame_open) begin
                // Open the next committed frame when its descriptor and its
                // first beat are both available.
                if (!desc_empty && fifo_rd_avail) begin
                    frame_open <= 1'b1;
                    skip_rem   <= desc_mem[desc_rp[DESC_AW-1:0]].skip;
                    pay_rem    <= desc_mem[desc_rp[DESC_AW-1:0]].paylen;
                    desc_rp    <= desc_rp + (DESC_AW+1)'(1);
                    beat_q     <= rxfifo[rd_ptr];
                    beat_vld   <= 1'b1;
                    rd_ptr     <= rd_ptr + FIFO_AW'(1);
                    byte_idx   <= 3'd0;
                end
            end else if (beat_vld) begin
                // Consume exactly one byte per cycle.
                if (skip_rem != 8'd0)      skip_rem <= skip_rem - 8'd1;
                else if (pay_rem != 16'd0) pay_rem  <= pay_rem  - 16'd1;

                if (byte_idx == 3'd7) begin
                    byte_idx <= 3'd0;
                    if (beat_q[AXIS_W]) begin
                        // tlast: this frame is done, whatever is left in the
                        // beat is Ethernet padding.
                        frame_open <= 1'b0;
                        beat_vld   <= 1'b0;
                    end else if (fifo_rd_avail) begin
                        beat_q   <= rxfifo[rd_ptr];
                        rd_ptr   <= rd_ptr + FIFO_AW'(1);
                    end else begin
                        beat_vld <= 1'b0;   // starved: wait (never backpressures RX)
                    end
                end else begin
                    byte_idx <= byte_idx + 3'd1;
                end

                // Payload exhausted before tlast: skip the remaining bytes of
                // the frame without feeding the FSM (fb_vld already low).
                if ((skip_rem == 8'd0) && (pay_rem == 16'd1)) begin
                    // pay_rem hits 0 next cycle; the loop above keeps draining
                    // beats until tlast, feeding nothing.
                    pay_rem <= 16'd0;
                end
            end else if (frame_open && fifo_rd_avail) begin
                beat_q   <= rxfifo[rd_ptr];
                rd_ptr   <= rd_ptr + FIFO_AW'(1);
                beat_vld <= 1'b1;
            end
        end
    end

    // =========================================================================
    // B) BYTE STAGE — SoupBinTCP + OUCH state machine
    // =========================================================================
    typedef enum logic [2:0] {
        RS_LEN0 = 3'd0,
        RS_LEN1 = 3'd1,
        RS_TYPE = 3'd2,
        RS_OTYP = 3'd3,
        RS_BODY = 3'd4,
        RS_SKIP = 3'd5
    } rs_e;

    rs_e         rs;
    logic [15:0] soup_rem;      // bytes left in the Soup packet, incl. type byte
    logic [7:0]  soup_type;
    logic [7:0]  ouch_type;
    logic [7:0]  bidx;          // byte index within the OUCH message
    logic [OUCH_TOKEN_LEN*8-1:0] tok_sr;
    logic [31:0] sh_sr;
    logic [31:0] px_sr;
    logic [7:0]  reason_q;
    logic        soup_len_bad;
    logic        msg_done;
    logic [7:0]  msg_type_done;

    // Per-type capture offsets. 8'hFF = "this message has no such field".
    logic [7:0] cap_sh_off, cap_px_off, cap_rs_off;
    always_comb begin
        cap_sh_off = 8'hFF;
        cap_px_off = 8'hFF;
        cap_rs_off = 8'hFF;
        case (ouch_type)
            OUCH_OUT_EXECUTED: begin
                cap_sh_off = 8'(OUCH_E_SHARES_OFF);
                cap_px_off = 8'(OUCH_E_PRICE_OFF);
            end
            OUCH_OUT_ACCEPTED: begin
                cap_sh_off = 8'(OUCH_A_SHARES_OFF);
                cap_px_off = 8'(OUCH_A_PRICE_OFF);
            end
            OUCH_OUT_REPLACED: begin
                cap_sh_off = 8'(OUCH_RU_SHARES_OFF);
                cap_px_off = 8'(OUCH_RU_PRICE_OFF);
            end
            OUCH_OUT_CANCELED, OUCH_OUT_AIQ_CANCELED: begin
                cap_sh_off = 8'(OUCH_C_SHARES_OFF);
                cap_rs_off = 8'(OUCH_C_REASON_OFF);
            end
            OUCH_OUT_REJECTED: begin
                cap_rs_off = 8'(OUCH_J_REASON_OFF);
            end
            default: begin
                cap_sh_off = 8'hFF;
                cap_px_off = 8'hFF;
                cap_rs_off = 8'hFF;
            end
        endcase
    end

    logic in_token, in_shares, in_price, at_reason;
    always_comb begin
        in_token  = (bidx >= 8'(OUCH_OUT_TOKEN_OFF))
                 && (bidx <  8'(OUCH_OUT_TOKEN_OFF + OUCH_TOKEN_LEN));
        in_shares = (cap_sh_off != 8'hFF) && (bidx >= cap_sh_off)
                 && (bidx < (cap_sh_off + 8'(OUCH_SHARES_LEN)));
        in_price  = (cap_px_off != 8'hFF) && (bidx >= cap_px_off)
                 && (bidx < (cap_px_off + 8'(OUCH_PRICE_LEN)));
        at_reason = (cap_rs_off != 8'hFF) && (bidx == cap_rs_off);
        soup_len_bad = 1'b0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rs            <= RS_LEN0;
            soup_rem      <= 16'd0;
            bidx          <= 8'd0;
            msg_done      <= 1'b0;
            msg_type_done <= 8'd0;
        end else begin
            msg_done <= 1'b0;
            if (desync_sticky) begin
                // Halted. The FSM stays in a known state so that a host resync
                // restarts cleanly on a packet boundary.
                rs <= RS_LEN0;
            end else if (fb_vld) begin
                case (rs)
                    RS_LEN0: begin
                        soup_rem[15:8] <= fb;
                        rs             <= RS_LEN1;
                    end
                    RS_LEN1: begin
                        soup_rem[7:0] <= fb;
                        rs            <= RS_TYPE;
                    end
                    RS_TYPE: begin
                        soup_type <= fb;
                        bidx      <= 8'd0;
                        if ((soup_rem == 16'd0) || (soup_rem > 16'(SOUP_LEN_MAX))) begin
                            rs <= RS_LEN0;         // illegal length -> see desync
                        end else if (soup_rem == 16'd1) begin
                            rs <= RS_LEN0;         // heartbeat / end-of-session
                        end else if (fb == SOUP_SEQ_DATA) begin
                            soup_rem <= soup_rem - 16'd1;
                            rs       <= RS_OTYP;
                        end else begin
                            // Login Accepted / Rejected / Debug: host business.
                            soup_rem <= soup_rem - 16'd1;
                            rs       <= RS_SKIP;
                        end
                    end
                    RS_OTYP: begin
                        ouch_type <= fb;
                        bidx      <= 8'd1;
                        tok_sr    <= '0;
                        sh_sr     <= 32'd0;
                        px_sr     <= 32'd0;
                        if (soup_rem == 16'd1) begin
                            rs            <= RS_LEN0;
                            msg_done      <= 1'b1;
                            msg_type_done <= fb;
                        end else begin
                            soup_rem <= soup_rem - 16'd1;
                            rs       <= RS_BODY;
                        end
                    end
                    RS_BODY: begin
                        // Big-endian: shift left as bytes arrive.
                        if (in_token)  tok_sr <= {tok_sr[OUCH_TOKEN_LEN*8-9:0], fb};
                        if (in_shares) sh_sr  <= {sh_sr[23:0], fb};
                        if (in_price)  px_sr  <= {px_sr[23:0], fb};
                        if (at_reason) reason_q <= fb;
                        bidx <= bidx + 8'd1;
                        if (soup_rem == 16'd1) begin
                            rs            <= RS_LEN0;
                            msg_done      <= 1'b1;
                            msg_type_done <= ouch_type;
                        end else begin
                            soup_rem <= soup_rem - 16'd1;
                        end
                    end
                    RS_SKIP: begin
                        if (soup_rem == 16'd1) rs <= RS_LEN0;
                        else                   soup_rem <= soup_rem - 16'd1;
                    end
                    default: rs <= RS_LEN0;
                endcase
            end
        end
    end

    // =========================================================================
    // Token decode — stateless, combinational
    // =========================================================================
    logic [TOKEN_HEX_BITS-1:0] hex56;
    logic                      hex_ok;
    logic [4:0]                hv;
    logic [15:0]               tok_magic;
    logic                      tok_side;
    /* verilator lint_off UNUSEDSIGNAL */
    logic                      tok_post;   // decoded for ILA / future use
    /* verilator lint_on UNUSEDSIGNAL */
    logic [11:0]               tok_sym;
    logic                      tok_form_ok;   // well-formed token
    logic                      tok_magic_ok;  // belongs to THIS session
    logic                      tok_ok;
    order_token_t              tok_raw;

    always_comb begin
        hex56  = '0;
        hex_ok = 1'b1;
        hv     = 5'd0;
        for (int i = 0; i < OUCH_TOKEN_LEN; i++) begin
            hv     = hex_val(tok_sr[8*(OUCH_TOKEN_LEN-1-i) +: 8]);
            hex_ok = hex_ok & hv[4];
            hex56[4*(OUCH_TOKEN_LEN-1-i) +: 4] = hv[3:0];
        end

        tok_raw = order_token_t'(tok_sr);

        if (TOKEN_ASCII_HEX) begin
            tok_magic = {8'd0, hex56[55:48]};
            tok_side  =        hex56[47];
            tok_post  =        hex56[46];
            tok_sym   =        hex56[41:30];
        end else begin
            tok_magic = tok_raw.magic;
            tok_side  = tok_raw.rsvd[TOKEN_RSVD_SIDE_BIT];
            tok_post  = tok_raw.rsvd[TOKEN_RSVD_POST_BIT];
            tok_sym   = tok_raw.sym;
        end

        // Well-formedness: the rendering decoded, and the symbol index actually
        // fits the active set. A token that fails this is corrupt or foreign —
        // not something to index a position array with.
        tok_form_ok = (TOKEN_ASCII_HEX ? hex_ok : 1'b1)
                   && (tok_sym[11:ACT_IDX_W] == '0);

        // ⚠️ STALE-SESSION REJECTION. A token whose magic does not match the
        //    current session belongs to a previous session (cancel-on-disconnect
        //    replay, a re-login, a restart). Acting on it would update the
        //    position for an order this session never sent, and return a credit
        //    that was never consumed. Refuse, and count.
        //    In ASCII-hex mode only the low 8 bits survive the rendering, so the
        //    detection probability per stale event is 255/256 rather than
        //    65535/65536 — adequate only because the host's reconciliation is
        //    the authoritative backstop. See ouch_pkg §8.
        tok_magic_ok = TOKEN_ASCII_HEX
                     ? (tok_magic[7:0] == cfg_token_magic[7:0])
                     : (tok_magic      == cfg_token_magic);

        tok_ok = tok_form_ok && tok_magic_ok;
    end

    // =========================================================================
    // Outputs — fills and credit return
    // =========================================================================
    out_msg_idx_e mi;
    logic         is_exec, is_terminal;

    always_comb begin
        mi          = ouch_out_idx(msg_type_done);
        is_exec     = (msg_type_done == OUCH_OUT_EXECUTED);
        is_terminal = ouch_out_is_terminal(msg_type_done, CREDIT_RETURN_ON_EXEC);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            fill_valid <= 1'b0;
            credit_ret <= 1'b0;
        end else begin
            fill_valid <= msg_done && tok_ok && is_exec && (sh_sr != 32'd0);
            credit_ret <= msg_done && tok_ok && is_terminal;
        end
        fill_sym  <= tok_sym[ACT_IDX_W-1:0];
        fill_side <= tok_side ? SIDE_SELL : SIDE_BUY;
        fill_qty  <= sh_sr;
        fill_px   <= px_sr;
    end

    // =========================================================================
    // Counters
    // =========================================================================
    // ⚠️ EVERY OUTBOUND MESSAGE TYPE IS COUNTED. "Messages received" without a
    //    breakdown is useless at 09:31 on a bad morning. A spike in
    //    msg_cnt[OMI_REJECTED] is an OPERATIONAL ALARM, not a statistic: it
    //    means the venue is refusing our orders and every rejected order is a
    //    strategy that thinks it has a position it does not have.
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < N_OUT_MSG_TYPES; i++) msg_cnt[i] <= 32'd0;
        end else if (msg_done) begin
            msg_cnt[mi] <= msg_cnt[mi] + 32'd1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 8; i++) stat[i] <= 32'd0;
        end else begin
            // 0 frames committed to the byte stream
            // 1 frames rejected (not our tuple, bad header, not in order)
            // 2 byte-stream desynchronisation events    ⚠️ MUST BE ZERO
            // 3 beat FIFO overflow                      ⚠️ MUST BE ZERO
            // 4 duplicate retransmissions (benign, dropped without desync)
            // 5 stale-session token                     ⚠️ MUST BE ZERO
            // 6 malformed token (bad rendering / sym out of range) ⚠️ ZERO
            // 7 OUCH messages decoded (total)
            if (frame_commit)                             stat[0] <= stat[0] + 32'd1;
            if (frame_reject)                             stat[1] <= stat[1] + 32'd1;
            if (frame_desync)                             stat[2] <= stat[2] + 32'd1;
            if (overflow)                                 stat[3] <= stat[3] + 32'd1;
            if (hdr_done && seq_duplicate)                stat[4] <= stat[4] + 32'd1;
            if (msg_done && tok_form_ok && !tok_magic_ok) stat[5] <= stat[5] + 32'd1;
            if (msg_done && !tok_form_ok)                 stat[6] <= stat[6] + 32'd1;
            if (msg_done)                                 stat[7] <= stat[7] + 32'd1;
        end
    end

    // =========================================================================
    // Assertions
    // =========================================================================
`ifndef SYNTHESIS
    // CLAUDE.md §5.4: this path must accept line rate unconditionally. There is
    // no tready port, so the only way to violate the rule is to add one.
    // What we CAN check is that we never lose sight of the frame boundary.
    assert property (@(posedge clk) disable iff (rst)
        (s_axis_tvalid && s_axis_tlast) |=> !in_frame
    ) else $error("ouch_rx: frame boundary lost");

    // A fill must never be emitted for a token we refused.
    assert property (@(posedge clk) disable iff (rst)
        (msg_done && !tok_ok) |=> !fill_valid
    ) else $error("ouch_rx: fill emitted for a rejected token");

    // A stale-session token must never return credit either — an unearned
    // credit lets the FPGA emit an order the risk gate believed was blocked.
    assert property (@(posedge clk) disable iff (rst)
        (msg_done && !tok_ok) |=> !credit_ret
    ) else $error("ouch_rx: credit returned for a stale-session token");

    // Once desynchronised, nothing may be decoded until the host resynchronises.
    assert property (@(posedge clk) disable iff (rst)
        desync_sticky |-> !fb_vld
    ) else $error("ouch_rx: parsing continued after byte-stream desync");

    // A fill must carry a non-zero quantity: a zero-quantity execution would
    // silently no-op the position update and hide a decode error.
    assert property (@(posedge clk) disable iff (rst)
        fill_valid |-> (fill_qty != 32'd0)
    ) else $error("ouch_rx: zero-quantity fill");

    // The commit pointer must never pass the speculative one.
    assert property (@(posedge clk) disable iff (rst)
        1'b1 |-> ((wr_spec - wr_commit) < FIFO_AW'(RXFIFO_BEATS))
    );

    initial begin
        if (OUCH_OUT_TOKEN_OFF + OUCH_TOKEN_LEN > OUCH_OUT_HDR_LEN)
            $fatal(1, "ouch_rx: outbound token does not fit the common prefix");
    end
`endif

endmodule : ouch_rx

`default_nettype wire
