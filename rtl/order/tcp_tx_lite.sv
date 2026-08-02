// =============================================================================
// tcp_tx_lite.sv — Hybrid-split TCP transmit: steady-state send ONLY
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/02-networking/02-ip-udp-tcp-in-hardware.md §4, §5, §6
//           manuals/03-algotrading/04-order-entry-protocols.md §4, §6
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// =============================================================================
// ⚠️⚠️  WHAT THIS BLOCK DOES **NOT** DO — READ THIS FIRST
// =============================================================================
// This is NOT a TCP stack. It is the send half of a hybrid split in which the
// HOST owns the connection and the FPGA owns exactly one operation: emitting a
// pre-validated segment on an already-established connection, fast.
//
//   NO retransmission.        Nothing is buffered for replay. If a segment is
//                             lost, this block will never notice and will never
//                             resend it.
//   NO congestion control.    No cwnd, no ssthresh, no slow start, no fast
//                             recovery. It sends whenever it is asked to.
//   NO reassembly.            It does not receive. It does not reorder.
//   NO connection management. No SYN, no FIN, no handshake, no teardown, no
//                             TIME_WAIT, no RTO, no timers of any kind.
//   NO TCP options.           Fixed 20-byte header, data offset hardwired to 5.
//                             ⚠️ The host MUST NOT negotiate SACK/timestamps in
//                             a way that changes OUR header length.
//   NO PMTU discovery, no ICMP, no ARP.
//
// -----------------------------------------------------------------------------
// ⚠️ THE FAILURE MODE, STATED PLAINLY
//
//   If the venue's ACKs stop advancing, or a segment is lost, or the window
//   closes, THIS BLOCK KEEPS SENDING and keeps advancing snd_nxt. It has no way
//   to know it is wrong. The sequence space it consumes diverges from what the
//   venue has actually received, and every subsequent segment lands in a hole.
//   The venue's stack buffers them, delivers nothing to the matching engine,
//   and — because SoupBinTCP outbound is UNSEQUENCED — there is no application
//   -level acknowledgement to reveal it either. The observable symptom is
//   "orders stopped working", with no error anywhere.
//
// -----------------------------------------------------------------------------
// ⚠️ REQUIRED HOST BEHAVIOUR — the interlock this block depends on
//
//   1. ARM/DISARM IS A HANDSHAKE, NOT A HINT.
//      The host writes snd_nxt/rcv_nxt ONLY while disarmed. This module REJECTS
//      a sequence write while armed and counts it (stat[7]). Two writers to a
//      TCP sequence number is an unrecoverable stream corruption.
//
//   2. THE HOST MUST NOT TOUCH THE SOCKET WHILE ARMED. Not a keepalive, not a
//      window update, not a probe. Enforce it in the host code and assert on it.
//
//   3. THE HOST MUST MONITOR snd_una (exported here from the RX snoop). If
//      (snd_nxt - snd_una) stops shrinking, the host DISARMS, takes the socket
//      back, retransmits from software, and re-arms with a corrected snd_nxt.
//      Retransmission means the fast path already failed; shaving nanoseconds
//      off a recovery path is pointless.
//
//   4. THE HOST MUST RECONCILE EVERY SEGMENT. Outbound SoupBinTCP is
//      unsequenced, so the (seq, len) exported here is the ONLY record that an
//      order left the building. ⚠️ CONTRACT GAP: the fpga_top.sv port list has
//      no DMA ring for the exact emitted bytes. Today the host gets snd_nxt and
//      the counters, which is enough to detect divergence but NOT enough to
//      rebuild a retransmission buffer. See rtl/order/README.md, open item OI-1.
//
//   5. AFTER ANY RECONNECT THE HOST MUST BUMP THE EPOCH. A new SoupBinTCP
//      session means new sequence space and possibly a new source port; the
//      epoch check below refuses to fire a stale template.
//
// -----------------------------------------------------------------------------
// THE FIVE HARDWARE INTERLOCKS (manuals/02-networking/02-*.md §6)
//   I1 dual writers on snd_nxt ... sequence writes rejected while armed  stat[7]
//   I2 regressing ACK .......... ack_hwm high-water register             (silent)
//   I3 send-window exhaustion .. snd_wnd shadow, refuse and count        stat[4]
//   I4 send after FIN/RST ...... hardware disarm latch, same cycle       stat[5]
//   I5 stale template .......... session epoch must match the armed value stat[2]
//
// -----------------------------------------------------------------------------
// THE INCREMENTAL CHECKSUM  (manuals/02-networking/02-*.md §4)
//
//   Nothing in this design ever sums a packet. The one's-complement sum arrives
//   here already accumulated, UNFOLDED, from upstream:
//
//     ouch_encoder : tmpl_partial (host-precomputed sum of the ZEROED template)
//                    + the ~24 spliced bytes
//     soupbin_tx   : + the 3 SoupBinTCP header bytes
//     tcp_tx_lite  : + tcp_csum_const  (host-precomputed: pseudo-header src IP,
//                                       dst IP, protocol, plus the constant TCP
//                                       header words — ports, data-offset/flags,
//                                       window, urgent pointer)
//                    + tcp_seg_len     (pseudo-header length, = 20 + payload)
//                    + seq[31:16] + seq[15:0]
//                    + ack[31:16] + ack[15:0]
//                    then ONE fold, then complement.
//
//   Because the template stores ZERO at every spliced byte, the "delta" is a
//   pure ADDITION. There is no subtraction anywhere, so the RFC 1141 /
//   RFC 1624 end-around-carry erratum — the `~0` vs `0` corner case — cannot be
//   hit. This is the reason the design uses partial sums rather than the
//   RFC 1624 eqn-3 patch form. (manuals/02-networking/02-*.md §4.)
//
//   ⚠️ WHY OFF-BY-ONE HERE IS SO DANGEROUS. A wrong TCP checksum is not an
//      error you can see. The venue's stack discards the segment silently, the
//      order never reaches the matching engine, and — because we do not
//      retransmit — it never will. The strategy observes "a fill we should have
//      got, that we didn't", which looks exactly like being slow. You will
//      spend a week optimising a latency problem that does not exist.
//      MITIGATIONS, all three of which are mandatory:
//        a) csum_byte_at() in ouch_pkg is the ONLY place the even/odd byte
//           parity rule is written down. Nothing duplicates it.
//        b) Every offset passed to it is a TCP-PAYLOAD offset, never an OUCH
//           offset — the 3-byte SoupBinTCP header flips the parity of every
//           OUCH field.
//        c) The cocotb testbench MUST recompute the checksum from scratch over
//           the emitted frame, on EVERY message of the entire regression suite,
//           and compare. See tb/order/test_tcp_tx_lite.py.
//
//   ⚠️ TCP CHECKSUM 0x0000 IS A LEGAL VALUE. Do NOT substitute 0xFFFF. That
//      substitution is a UDP-only rule (where 0x0000 means "not computed") and
//      applying it to TCP corrupts one segment in 65536.
//
// -----------------------------------------------------------------------------
// LATENCY  (156.25 MHz, 6.4 ns/cycle)
//   Accept payload, build the 54-byte header, patch, checksum, register  1 cyc
//   First beat presented on the MAC TX AXI-Stream ................. cycle +1
//   ACHIEVED: 1 cycle to first beat. Fixed.
//
//   ⚠️ SERIALISATION IS NOT LATENCY. A 106-byte frame is 14 beats on a 64-bit
//      bus = 14 cycles = 89.6 ns of BUS OCCUPANCY. That is throughput, not
//      tick-to-trade latency: with a cut-through MAC the first byte is already
//      on the wire while beat 13 is still being read out of the frame buffer.
//      The budget line is time-to-first-beat. Do not add 89.6 ns to it.
//
//   ⚠️ FREE SLACK, AND HOW TO SPEND IT. The IP header checksum sits at frame
//      bytes 24-25 (beat 3) and the TCP checksum at bytes 50-51 (beat 6). Both
//      are therefore emitted 3 and 6 cycles AFTER the first beat. If either
//      adder tree ever fails timing, pipeline it by a stage rather than
//      pipelining the datapath — the result is still on the bus in time and
//      the tick-to-trade path does not move.
//
// RESOURCE ESTIMATE (target)
//   Frame buffer 2 x 1024 b ......... ~2100 FF
//   Header build + patch ............ ~450 LUT (mostly wiring)
//   Checksum trees (IP + TCP) ....... ~250 LUT
//   Beat mux 16:1 x 64 b ............ ~330 LUT, 2 levels
//   Session/sequence registers ...... ~400 FF
//   BRAM 0, DSP 0.
// =============================================================================
`default_nettype none

module tcp_tx_lite
    import trading_pkg::*;
    import ouch_pkg::*;
#(
    // Frame buffer slots. 2 is sufficient: the gateway reserves a slot before
    // an order enters the (non-stalling, fixed-latency) encoder pipeline, so
    // occupancy can never exceed this. See order_gateway.sv.
    parameter int unsigned FBUF_DEPTH = 2
) (
    input  var logic                            clk,
    input  var logic                            rst,

    // ── SoupBinTCP packet in (TCP payload) ───────────────────────────────────
    input  var logic [SOUP_PAY_MAX_BYTES*8-1:0] s_pay,
    input  var logic [7:0]                      s_len,
    input  var csum_acc_t                       s_csum,   // UNFOLDED partial sum
    input  var logic                            s_valid,
    input  var logic                            s_is_hb,
    input  var logic                            s_is_cancel,

    // ── Live session registers (host owned, committed by order_gateway) ──────
    input  var tcp_sess_t                       sess,
    input  var logic [15:0]                     armed_epoch,
    input  var logic                            sess_seq_wr,
    input  var logic [31:0]                     sess_seq_val,
    input  var logic                            sess_ack_wr,
    input  var logic [31:0]                     sess_ack_val,
    input  var logic                            sess_clr_disarm,

    // ── Inbound snoop (from ouch_rx — snoop, do not own) ─────────────────────
    input  var logic                            snoop_valid,
    input  var logic [31:0]                     snoop_seq,
    input  var logic [15:0]                     snoop_seglen,
    input  var logic [31:0]                     snoop_ack,
    input  var logic [15:0]                     snoop_win,
    input  var logic                            snoop_ack_vld,
    input  var logic                            snoop_fin,
    input  var logic                            snoop_rst,

    // ── Kill switch — DEFENCE IN DEPTH, see order_gateway.sv ─────────────────
    input  var logic                            kill_active,

    // ── MAC TX AXI-Stream ────────────────────────────────────────────────────
    output var logic [AXIS_W-1:0]               m_axis_tdata,
    output var logic [AXIS_KEEP_W-1:0]          m_axis_tkeep,
    output var logic                            m_axis_tvalid,
    output var logic                            m_axis_tlast,
    input  var logic                            m_axis_tready,

    // ── Status / host reconciliation ─────────────────────────────────────────
    output var logic                            frame_done,   // 1-cycle pulse
    // Pulse: a packet was offered and REFUSED (unarmed, epoch mismatch, no
    // slot, window). Releases the gateway's TX slot reservation.
    output var logic                            s_refuse,
    // Pulse: an ENTER ORDER frame was actually committed to the wire. This —
    // and nothing earlier in the chain — is what consumes an in-flight credit,
    // so a refusal anywhere upstream can never burn one.
    output var logic                            accept_enter,
    output var logic [31:0]                     snd_nxt_o,
    output var logic [31:0]                     snd_una_o,
    output var logic                            hw_disarmed,  // sticky, I4
    output var logic                            tx_idle,

    output var logic [31:0]                     stat [8]
);

    localparam int unsigned FRAME_BITS  = TX_FRAME_MAX_BYTES * 8;   // 1024
    localparam int unsigned BEAT_IDX_W  = $clog2(TX_FRAME_MAX_BEATS); // 4
    localparam int unsigned OCC_W       = $clog2(FBUF_DEPTH + 1);

    // =========================================================================
    // Sequence state
    // =========================================================================
    // ⚠️ snd_nxt is HARDWARE-OWNED while armed (interlock I1). The host may only
    //    write it while disarmed; a write while armed is rejected and counted.
    logic [31:0] snd_nxt;
    logic [31:0] snd_una;      // shadow, from snooped ACKs
    logic [31:0] rcv_nxt;      // shadow, from snooped segments
    logic [31:0] ack_hwm;      // interlock I2: never emit an ACK below this
    logic [31:0] snd_wnd;      // interlock I3, already window-scaled
    logic [15:0] ip_id;
    logic        hw_disarm_q;  // interlock I4 latch

    assign snd_nxt_o   = snd_nxt;
    assign snd_una_o   = snd_una;
    assign hw_disarmed = hw_disarm_q;

    // ---- The ACK we will emit: never below the high-water mark (I2) ---------
    // Emitting an ACK lower than one already sent looks like a duplicate ACK.
    // Three of them trigger fast retransmit at the venue — self-inflicted.
    logic [31:0] ack_use;
    always_comb begin
        ack_use = ack_hwm;
        if (seq_gt(rcv_nxt, ack_hwm)) ack_use = rcv_nxt;
    end

    // =========================================================================
    // Admission control
    // =========================================================================
    logic [OCC_W-1:0] occ;
    logic             have_slot;
    logic             epoch_ok;
    logic             armed_ok;
    logic             wnd_ok;
    logic             accept;
    logic [15:0]      seg_len16;
    logic [31:0]      snd_after;

    always_comb begin
        seg_len16 = {8'd0, s_len};
        snd_after = snd_nxt + {16'd0, seg_len16};
        have_slot = (occ != OCC_W'(FBUF_DEPTH));
        epoch_ok  = (sess.epoch == armed_epoch);                       // I5
        armed_ok  = sess.armed && !hw_disarm_q && !kill_active;        // I4 + kill
        // I3: (snd_nxt + len) - snd_una must fit inside the peer's window.
        // OUCH messages are tiny and Nasdaq's window is large, so this should
        // NEVER fire — which is exactly why it needs a counter, not silence.
        wnd_ok    = ((snd_after - snd_una) <= snd_wnd);
        accept    = s_valid && have_slot && epoch_ok && armed_ok && wnd_ok
                    && (s_len != 8'd0);
    end

    // =========================================================================
    // Header build + patch  (all offsets are elaboration constants -> wiring)
    // =========================================================================
    logic [15:0]      ip_totlen;
    logic [15:0]      tcp_seg_len;
    logic [7:0]       frame_len;
    csum_acc_t        ip_acc;
    csum_acc_t        tcp_acc;
    logic [15:0]      ip_csum;
    logic [15:0]      tcp_csum;
    logic [FRAME_BITS-1:0] frame_d;

    always_comb begin
        ip_totlen   = 16'(IP4_HDR_LEN + TCP_HDR_LEN) + seg_len16;
        tcp_seg_len = 16'(TCP_HDR_LEN)               + seg_len16;
        frame_len   = 8'(FRAME_HDR_LEN) + s_len;

        // ---- IP header checksum -----------------------------------------
        // ip_csum_const = host's one's-complement sum of every constant word of
        // the IP header (ver/IHL|DSCP, flags/frag, TTL|proto, src IP hi/lo,
        // dst IP hi/lo) EXCLUDING total length, identification, and the
        // checksum field itself.
        ip_acc  = {{(CSUM_ACC_W-16){1'b0}}, sess.ip_csum_const}
                + {{(CSUM_ACC_W-16){1'b0}}, ip_totlen}
                + {{(CSUM_ACC_W-16){1'b0}}, ip_id};
        ip_csum = ~csum_fold(ip_acc);

        // ---- TCP checksum -------------------------------------------------
        // ⚠️ 0x0000 is legal here. No 0xFFFF substitution. See the header.
        tcp_acc  = s_csum
                 + {{(CSUM_ACC_W-16){1'b0}}, sess.tcp_csum_const}
                 + {{(CSUM_ACC_W-16){1'b0}}, tcp_seg_len}
                 + {{(CSUM_ACC_W-16){1'b0}}, snd_nxt[31:16]}
                 + {{(CSUM_ACC_W-16){1'b0}}, snd_nxt[15:0]}
                 + {{(CSUM_ACC_W-16){1'b0}}, ack_use[31:16]}
                 + {{(CSUM_ACC_W-16){1'b0}}, ack_use[15:0]};
        tcp_csum = ~csum_fold(tcp_acc);

        // ---- Frame image ---------------------------------------------------
        frame_d = '0;
        // Ethernet II
        for (int i = 0; i < 6; i++) begin
            frame_d[8*(ETH_DMAC_OFF + i) +: 8] = sess.dmac[8*(5-i) +: 8];
            frame_d[8*(ETH_SMAC_OFF + i) +: 8] = sess.smac[8*(5-i) +: 8];
        end
        frame_d[8*(ETH_TYPE_OFF + 0) +: 8] = ETHERTYPE_IPV4[15:8];
        frame_d[8*(ETH_TYPE_OFF + 1) +: 8] = ETHERTYPE_IPV4[7:0];
        // IPv4, IHL = 5, DF set, no options
        frame_d[8*IP_VERIHL_OFF      +: 8] = IP_VERIHL_V4;
        frame_d[8*IP_DSCP_OFF        +: 8] = sess.dscp;
        frame_d[8*(IP_TOTLEN_OFF+ 0) +: 8] = ip_totlen[15:8];
        frame_d[8*(IP_TOTLEN_OFF+ 1) +: 8] = ip_totlen[7:0];
        frame_d[8*(IP_ID_OFF    + 0) +: 8] = ip_id[15:8];
        frame_d[8*(IP_ID_OFF    + 1) +: 8] = ip_id[7:0];
        frame_d[8*(IP_FLAGS_OFF + 0) +: 8] = IP_FLAGS_DF[15:8];
        frame_d[8*(IP_FLAGS_OFF + 1) +: 8] = IP_FLAGS_DF[7:0];
        frame_d[8*IP_TTL_OFF         +: 8] = sess.ttl;
        frame_d[8*IP_PROTO_OFF       +: 8] = IP_PROTO_TCP;
        frame_d[8*(IP_CSUM_OFF  + 0) +: 8] = ip_csum[15:8];
        frame_d[8*(IP_CSUM_OFF  + 1) +: 8] = ip_csum[7:0];
        for (int i = 0; i < 4; i++) begin
            frame_d[8*(IP_SRC_OFF + i) +: 8] = sess.sip[8*(3-i) +: 8];
            frame_d[8*(IP_DST_OFF + i) +: 8] = sess.dip[8*(3-i) +: 8];
        end
        // TCP, 20-byte header, PSH|ACK always set
        frame_d[8*(TCP_SPORT_OFF+ 0) +: 8] = sess.sport[15:8];
        frame_d[8*(TCP_SPORT_OFF+ 1) +: 8] = sess.sport[7:0];
        frame_d[8*(TCP_DPORT_OFF+ 0) +: 8] = sess.dport[15:8];
        frame_d[8*(TCP_DPORT_OFF+ 1) +: 8] = sess.dport[7:0];
        for (int i = 0; i < 4; i++) begin
            frame_d[8*(TCP_SEQ_OFF + i) +: 8] = snd_nxt[8*(3-i) +: 8];
            frame_d[8*(TCP_ACK_OFF + i) +: 8] = ack_use[8*(3-i) +: 8];
        end
        frame_d[8*TCP_OFFRSV_OFF     +: 8] = TCP_OFFRSV_5;
        frame_d[8*TCP_FLAGS_OFF      +: 8] = TCP_FLAGS_DATA;
        frame_d[8*(TCP_WIN_OFF  + 0) +: 8] = sess.win[15:8];
        frame_d[8*(TCP_WIN_OFF  + 1) +: 8] = sess.win[7:0];
        frame_d[8*(TCP_CSUM_OFF + 0) +: 8] = tcp_csum[15:8];
        frame_d[8*(TCP_CSUM_OFF + 1) +: 8] = tcp_csum[7:0];
        frame_d[8*(TCP_URG_OFF  + 0) +: 8] = 8'h00;
        frame_d[8*(TCP_URG_OFF  + 1) +: 8] = 8'h00;
        // Payload
        frame_d[8*FRAME_HDR_LEN +: SOUP_PAY_MAX_BYTES*8] = s_pay;
    end

    // =========================================================================
    // Frame buffer (FBUF_DEPTH slots) and sequence advance
    // =========================================================================
    logic [FRAME_BITS-1:0] fbuf     [FBUF_DEPTH];
    logic [7:0]            fbuf_len [FBUF_DEPTH];
    logic                  wr_ptr;
    logic                  rd_ptr;

    always_ff @(posedge clk) begin
        if (accept) begin
            fbuf    [wr_ptr] <= frame_d;
            fbuf_len[wr_ptr] <= frame_len;
        end
    end

    // Reservation release and credit consumption, both registered pulses.
    always_ff @(posedge clk) begin
        if (rst) begin
            s_refuse     <= 1'b0;
            accept_enter <= 1'b0;
        end else begin
            s_refuse     <= s_valid && !accept;
            accept_enter <= accept && !s_is_hb && !s_is_cancel;
        end
    end

    // =========================================================================
    // AXI-Stream serialiser — registered outputs, honours tready
    // =========================================================================
    logic                  frame_active;   // beats after beat 0 remain to load
    logic [BEAT_IDX_W-1:0] beat_ptr;       // next beat index to load
    logic                  can_load;
    logic [BEAT_IDX_W-1:0] cur_last_beat;
    logic [BEAT_IDX_W-1:0] new_last_beat;
    logic [2:0]            cur_rem;
    logic [2:0]            new_rem;
    logic                  start_frame;
    logic                  load_last;

    // last beat index = (len-1) >> 3 ; remainder = len[2:0].  Shifts only:
    // no division or modulo anywhere (CLAUDE.md §5.3).
    always_comb begin
        cur_last_beat = BEAT_IDX_W'((fbuf_len[rd_ptr] - 8'd1) >> 3);
        cur_rem       = fbuf_len[rd_ptr][2:0];
        new_last_beat = cur_last_beat;
        new_rem       = cur_rem;
        can_load      = !m_axis_tvalid || m_axis_tready;
        start_frame   = !frame_active && (occ != OCC_W'(0));
        load_last     = 1'b0;
        if (frame_active) begin
            load_last = (beat_ptr == cur_last_beat);
        end else if (start_frame) begin
            load_last = (cur_last_beat == BEAT_IDX_W'(0));
        end
    end

    // tkeep for a beat: all lanes except possibly the last beat.
    function automatic logic [AXIS_KEEP_W-1:0] keep_of(input logic is_last,
                                                       input logic [2:0] rem);
        if (!is_last || (rem == 3'd0)) return {AXIS_KEEP_W{1'b1}};
        case (rem)
            3'd1: return 8'b0000_0001;
            3'd2: return 8'b0000_0011;
            3'd3: return 8'b0000_0111;
            3'd4: return 8'b0000_1111;
            3'd5: return 8'b0001_1111;
            3'd6: return 8'b0011_1111;
            3'd7: return 8'b0111_1111;
            default: return {AXIS_KEEP_W{1'b1}};
        endcase
    endfunction

    logic [BEAT_IDX_W-1:0] load_idx;
    logic                  pop;

    always_comb begin
        load_idx = frame_active ? beat_ptr : BEAT_IDX_W'(0);
        pop      = can_load && (frame_active || start_frame) && load_last;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            frame_active  <= 1'b0;
            beat_ptr      <= BEAT_IDX_W'(0);
            rd_ptr        <= 1'b0;
            frame_done    <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            if (can_load) begin
                if (frame_active || start_frame) begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= load_last;
                    if (load_last) begin
                        frame_active <= 1'b0;
                        beat_ptr     <= BEAT_IDX_W'(0);
                        rd_ptr       <= ~rd_ptr;
                        frame_done   <= 1'b1;
                    end else begin
                        frame_active <= 1'b1;
                        beat_ptr     <= load_idx + BEAT_IDX_W'(1);
                    end
                end else begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                end
            end
        end
        // Datapath: no reset.
        if (can_load) begin
            m_axis_tdata <= fbuf[rd_ptr][64*load_idx +: 64];
            m_axis_tkeep <= keep_of(load_last, cur_rem);
        end
    end

    assign tx_idle = (occ == OCC_W'(0)) && !frame_active && !m_axis_tvalid;

    // ---- Occupancy and write pointer ---------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            occ    <= OCC_W'(0);
            wr_ptr <= 1'b0;
        end else begin
            if (accept) wr_ptr <= ~wr_ptr;
            case ({accept, pop})
                2'b10:   occ <= occ + OCC_W'(1);
                2'b01:   occ <= occ - OCC_W'(1);
                default: occ <= occ;
            endcase
        end
    end

    // =========================================================================
    // Sequence / shadow state updates
    // =========================================================================
    logic seq_wr_ok;
    logic seq_wr_rejected;

    always_comb begin
        // Interlock I1: the host may only write sequence state while disarmed.
        seq_wr_ok       = !sess.armed;
        seq_wr_rejected = (sess_seq_wr || sess_ack_wr) && sess.armed;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            snd_nxt     <= 32'd0;
            snd_una     <= 32'd0;
            rcv_nxt     <= 32'd0;
            ack_hwm     <= 32'd0;
            snd_wnd     <= 32'd0;
            ip_id       <= 16'd1;
            hw_disarm_q <= 1'b0;
        end else begin
            // ---- Host resync (disarmed only) --------------------------------
            if (sess_seq_wr && seq_wr_ok) begin
                snd_nxt <= sess_seq_val;
                snd_una <= sess_seq_val;
            end
            if (sess_ack_wr && seq_wr_ok) begin
                rcv_nxt <= sess_ack_val;
                ack_hwm <= sess_ack_val;
            end

            // ---- Advance on send --------------------------------------------
            if (accept) begin
                snd_nxt <= snd_nxt + {24'd0, s_len};
                ip_id   <= ip_id + 16'd1;
                if (seq_gt(ack_use, ack_hwm)) ack_hwm <= ack_use;   // I2
            end

            // ---- RX snoop: shadow only, never authority ----------------------
            if (snoop_valid) begin
                // Advance rcv_nxt only for the in-order segment. A gap means the
                // host's stack must sort it out; we simply stop advancing and
                // keep ACKing what we last knew was contiguous.
                if (snoop_seq == rcv_nxt) begin
                    rcv_nxt <= rcv_nxt + {16'd0, snoop_seglen};
                end
                if (snoop_ack_vld && seq_gt(snoop_ack, snd_una)) begin
                    snd_una <= snoop_ack;
                end
                // ⚠️ Window scaling is applied here from the host-written factor.
                //    If the host negotiated a wscale it did not tell us about,
                //    we will under-estimate the window and stall (safe), never
                //    over-estimate and overrun (unsafe). Fail-closed by design.
                snd_wnd <= {16'd0, snoop_win} << sess.wscale;

                // ---- Interlock I4: FIN or RST disarms in THIS cycle -----------
                // Not on the next host poll. A segment sent after a RST draws
                // another RST and can race the host's re-login.
                if (snoop_fin || snoop_rst) hw_disarm_q <= 1'b1;
            end

            if (sess_clr_disarm) hw_disarm_q <= 1'b0;
        end
    end

    // =========================================================================
    // Counters
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 8; i++) stat[i] <= 32'd0;
        end else begin
            if (accept)                                   stat[0] <= stat[0] + 32'd1;
            if (s_valid && !armed_ok)                     stat[1] <= stat[1] + 32'd1;
            if (s_valid && armed_ok && !epoch_ok)         stat[2] <= stat[2] + 32'd1;
            // ⚠️ stat[3] IS A LOST ORDER. It must alarm, not just log.
            if (s_valid && armed_ok && epoch_ok && !have_slot)
                                                          stat[3] <= stat[3] + 32'd1;
            if (s_valid && armed_ok && epoch_ok && have_slot && !wnd_ok)
                                                          stat[4] <= stat[4] + 32'd1;
            if (snoop_valid && (snoop_fin || snoop_rst) && !hw_disarm_q)
                                                          stat[5] <= stat[5] + 32'd1;
            if (m_axis_tvalid && !m_axis_tready)           stat[6] <= stat[6] + 32'd1;
            if (seq_wr_rejected)                           stat[7] <= stat[7] + 32'd1;
        end
    end

    // =========================================================================
    // Assertions
    // =========================================================================
`ifndef SYNTHESIS
    // The kill switch must stop transmission. A frame ALREADY IN FLIGHT is
    // allowed to finish — truncating a TCP segment mid-frame would desynchronise
    // the byte stream and destroy the session, which is strictly worse than the
    // <= TX_FRAME_MAX_BEATS cycles of drain. Documented in order_gateway.sv.
    assert property (@(posedge clk) disable iff (rst)
        kill_active |-> !accept
    ) else $error("tcp_tx_lite: frame accepted while the kill switch is active");

    // Interlock I1.
    assert property (@(posedge clk) disable iff (rst)
        (sess_seq_wr && sess.armed) |-> $stable(snd_nxt)
    ) else $error("tcp_tx_lite: snd_nxt written by the host while ARMED (I1)");

    // Interlock I2: the emitted ACK must never regress.
    assert property (@(posedge clk) disable iff (rst)
        accept |-> !seq_gt(ack_hwm, ack_use)
    ) else $error("tcp_tx_lite: emitted ACK below the high-water mark (I2)");

    // Interlock I4: nothing goes out after a FIN or RST until the host clears it.
    assert property (@(posedge clk) disable iff (rst)
        hw_disarm_q |-> !accept
    ) else $error("tcp_tx_lite: frame accepted after FIN/RST disarm (I4)");

    // The buffer must never overflow: the gateway reserves the slot up front.
    assert property (@(posedge clk) disable iff (rst)
        accept |-> have_slot
    ) else $error("tcp_tx_lite: frame buffer overflow -- ORDER LOST");

    // The fold bound proof from ouch_pkg §9: the second fold never carries out.
    // If this fires, CSUM_ACC_W grew and csum_fold needs a third stage.
    logic [16:0] f0_chk;
    logic [16:0] f1_chk;
    always_comb begin
        f0_chk = {1'b0, tcp_acc[15:0]} + {7'd0, tcp_acc[CSUM_ACC_W-1:16]};
        f1_chk = {1'b0, f0_chk[15:0]}  + {16'd0, f0_chk[16]};
    end
    assert property (@(posedge clk) disable iff (rst)
        s_valid |-> (f1_chk[16] == 1'b0)
    ) else $error("tcp_tx_lite: checksum fold carried out twice -- csum_fold needs a third stage");

    // AXI-Stream contract: data must be stable while stalled.
    assert property (@(posedge clk) disable iff (rst)
        (m_axis_tvalid && !m_axis_tready) |=> (m_axis_tvalid && $stable(m_axis_tdata)
                                                            && $stable(m_axis_tkeep)
                                                            && $stable(m_axis_tlast))
    ) else $error("tcp_tx_lite: AXI-Stream contract violated during backpressure");

    // The emitted frame must be a legal Ethernet frame without MAC padding.
    assert property (@(posedge clk) disable iff (rst)
        accept |-> (frame_len >= 8'(ETH_MIN_FRAME_BYTES - 4))
    ) else $error("tcp_tx_lite: frame shorter than the minimum Ethernet payload");

    initial begin
        if ((FRAME_HDR_LEN + SOUP_PAY_MAX_BYTES) > TX_FRAME_MAX_BYTES)
            $fatal(1, "tcp_tx_lite: TX_FRAME_MAX_BYTES too small");
        if (FBUF_DEPTH != 2)
            $fatal(1, "tcp_tx_lite: rd_ptr/wr_ptr are 1-bit; FBUF_DEPTH must be 2");
    end
`endif

endmodule : tcp_tx_lite

`default_nettype wire
