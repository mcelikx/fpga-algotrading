// =============================================================================
// moldudp64_deframer.sv — MoldUDP64 packet -> one ITCH message per beat
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/04-system-architecture/02-feed-handler-design.md (§4, §5)
//           manuals/02-networking/03-multicast-feeds-and-arbitration.md (§2)
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//           rtl/pkg/itch_pkg.sv  (MOLD_* framing, itch_msg_len())
//
// ⚠️ THIS IS THE HARDEST BLOCK IN THE LAYER. Read §A before changing anything.
//
// LATENCY
//   1 cycle = 6.40 ns @ 156.25 MHz, from the payload beat that carries a
//   message's LAST byte to that message appearing on m_msg. Fixed, and
//   independent of where in the beat the message starts or ends — that
//   invariance is the whole point of the design and is worth more than a lower
//   mean (CLAUDE.md §5.8).
//   Together with ab_arbiter (1 cycle) this is the "MoldUDP64 deframe + A/B
//   arbitration  2 cyc  12.8 ns" row of the fpga_top budget.
//
//   The 1-cycle figure depends on the WRITE-FORWARDING path in §3: the beat
//   arriving this cycle is muxed into the extraction window before it has been
//   registered. Without it this block is 2 cycles. If that path fails timing,
//   remove FWD_BYPASS and update the budget row to 3 cycles — do not pretend.
//
// RESOURCE (estimate, pre-synthesis — replace with real utilization)
//   LUT ~5,200   FF ~1,500   BRAM 0   URAM 0   DSP 0
//   Breakdown: 10 x 16:1 64-bit word mux (~3,200), 528-bit x 3-level byte
//   barrel shifter (~1,600), length/type compare + mask (~400).
//   This is the most expensive block in rtl/net/ and the one most likely to
//   limit Fmax. See §A.4.
//
// =============================================================================
// §A  DESIGN NOTE — WHY A REALIGNMENT WINDOW, AND HOW IT WORKS
// =============================================================================
//
// A.1  THE PROBLEM
//   One MoldUDP64 packet carries a 20-byte header followed by MessageCount
//   length-prefixed ITCH messages, packed with NO padding and NO alignment:
//
//     ┌────────────────────────────────────────────────────────────────────┐
//     │ Session (10 B) │ SequenceNumber (8 B, BE) │ MessageCount (2 B, BE) │
//     ├────────────────────────────────────────────────────────────────────┤
//     │ len0 │ ITCH msg 0 … │ len1 │ ITCH msg 1 … │ len2 │ ITCH msg 2 … │ …│
//     └────────────────────────────────────────────────────────────────────┘
//        2 B      len0 B       2 B      len1 B       2 B      len2 B
//
//   ITCH messages are 12..50 bytes; the ingress bus is 8 bytes/cycle. So a
//   message starts at an ARBITRARY byte offset in a beat and straddles an
//   ARBITRARY number of beat boundaries. There is no alignment to exploit.
//
//   SequenceNumber is the sequence of the FIRST message and it counts
//   MESSAGES, not packets. Message k in the packet has sequence
//   SequenceNumber + k, and next_expected = SequenceNumber + MessageCount.
//
// A.2  WHY NOT THE OBVIOUS DESIGNS
//   | design                      | latency/msg | verdict                    |
//   |-----------------------------|-------------|----------------------------|
//   | byte-serial parse FSM       | +3..6 cyc   | too slow, length-dependent |
//   | gearbox to 512-bit beats    | +0..7 cyc   | JITTER as a function of    |
//   |                             |             | byte alignment. Fatal.     |
//   | 128 B window + byte shifter | +1 cyc FIXED| chosen                     |
//   We pay in a barrel shifter instead of in time (04.02 §3).
//
// A.3  THE STRUCTURE
//
//    write side: 8 B/cycle from the UDP payload      read side: BYTE granular
//                        │                                     │
//                        ▼                                     ▼
//   ┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
//   │w0 │w1 │w2 │w3 │w4 │w5 │w6 │w7 │w8 │w9 │w10│w11│w12│w13│w14│w15│ 16 x 64b
//   └───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘  = 128 B
//         ▲                                   ▲
//       rd_ptr_q (7 bits, BYTE, mod 128)    wr_ptr_q (4 bits, WORD)
//
//   step 1: gather VIEW_WORDS=10 consecutive words starting at rd_ptr_q[6:3]
//           (the 4-bit index adder wraps mod 16 for free) -> 640 bits
//           ...with write-forwarding: if a gathered index == wr_ptr_q and a
//           beat is arriving this cycle, take the beat directly. This is what
//           makes the block 1 cycle instead of 2.
//   step 2: barrel-shift right by rd_ptr_q[2:0] bytes -> a 66-byte view whose
//           byte 0 IS the first byte of the next message block
//   step 3: blk_len = BE16(view[0..1]);  message body = view[2 .. 2+blk_len-1]
//
//   10 words, not 9, because a 66-byte view (2 B length + 64 B max message)
//   starting at byte offset 7 spans 73 bytes.
//
//   ⚠️ THE CLASSIC BUG: treating rd_ptr wrap and wr_ptr wrap as independent.
//      They are the SAME 128-byte modulus at different granularities —
//      rd_ptr_q[6:3] IS the word index. Deriving one from the other removes
//      the entire bug class. Never add a second modulus.
//
// A.4  WHY THERE IS NO STATE MACHINE IN THE MESSAGE LOOP
//   fill_q counts bytes available ahead of rd_ptr. The completion test is a
//   pure comparator:
//
//       have_msg = (fill >= 2 + blk_len)
//
//   so m_valid can be high on CONSECUTIVE cycles — II = 1 — with no handshake.
//   rd_ptr advances by 2+blk_len, msgs_left decrements, and the next message
//   is presented on the very next cycle if its bytes are already buffered.
//
// A.5  THROUGHPUT AND BUFFER SIZING — THE STRESS CASE
//   Worst case is a maximally packed 1500-byte frame of the shortest
//   book-affecting message, Order Delete ('D', 19 B):
//
//     frame 1500 B -> UDP payload 1458 B -> body 1438 B after the Mold header
//     block size    = 19 + 2 (length prefix) = 21 B
//     messages      = floor(1438 / 21) = 68
//     frame arrival = 1500 / 8 = 188 cycles
//     emission @ II=1 = 68 cycles                     -> 2.76x headroom
//
//   Peak window occupancy: emission of a message needs fill >= 2 + blk_len.
//   The largest ITCH message is NOII ('I', 50 B), so fill peaks at
//   52 + 8 (one beat in flight) = 60 bytes. The 128-byte window is never more
//   than 47 % full. THERE IS NO OUTPUT FIFO AND NONE IS NEEDED — and per
//   04.02 §1 that is deliberate: a FIFO on the RX fast path is a place to fall
//   behind, and you cannot ask the wire to resend.
//
//   Post-packet drain: at eop at most 60 buffered bytes remain = ceil(60/21)
//   = 3 messages = 3 cycles. The next packet's first payload byte cannot
//   arrive for at least 12 B IFG + 8 B preamble + 42 B headers = 62 B
//   = 7.75 beats. Margin > 2x. If it ever happens anyway it is caught, poisoned
//   and counted as MOLD_EVT_OVERRUN, which must always read zero.
//
// A.6  ERROR POLICY
//   * blk_len == 0, or blk_len > ITCH_MSG_MAX_BYTES  -> ABANDON THE PACKET.
//     (Also prevents a deadlock: fill can never reach 2 + 1000.)
//   * blk_len != itch_msg_len(type) for a KNOWN type -> ABANDON THE PACKET.
//     ⚠️ Not just the message. Once rd_ptr advances by the wrong amount, every
//        following block is read from the wrong offset — and arbitrary bytes
//        are a plausible ITCH type roughly 1 time in 10, so it will DECODE.
//        That is a silently corrupted book (04.02 §6.2).
//   * UNKNOWN type -> counted, and FORWARDED, skipped by its DECLARED length,
//     never by a guess. Forwarding (rather than dropping) is deliberate: an
//     unknown type still consumes a sequence number, and swallowing it here
//     would manufacture a phantom gap in ab_arbiter. The ITCH decoder ignores
//     types it does not recognise.
//   * Packet ends mid-block -> truncated, abandon, poison.
//   * Session ID changed -> abandon, poison. NEVER auto-adopt a new session
//     (02.03 §9 rule 11): a session change is a start-of-day event driven by
//     the host, not something hardware infers from a packet. Reset == SOD.
//   * s_pay_err at eop (bad FCS or truncated frame) -> poison. The messages
//     from that packet have ALREADY been forwarded — the MAC is cut-through
//     (02.01 §6) — so poison is the only available remedy and the channel is
//     staled by ab_arbiter.
//
// A.7  SPECIAL MESSAGE COUNTS
//   0x0000 = heartbeat. No message blocks. SequenceNumber is the NEXT sequence
//            the publisher will send, so it is a live gap probe: forwarded on
//            m_hb / m_ctl_seq for ab_arbiter to compare against expected.
//   0xFFFF = end of session. No message blocks. Forwarded on m_endsess.
//   Both must be tested BEFORE treating MessageCount as a block count.
// =============================================================================
`default_nettype none

module moldudp64_deframer
    import trading_pkg::*;
    import itch_pkg::*;
    import net_rx_pkg::*;
#(
    // Write-forwarding bypass: costs one 2:1 mux level on the window read and
    // buys one cycle of latency. Set to 0 if it fails timing (and update the
    // budget row in fpga_top.sv — do not silently absorb the cycle).
    parameter bit CHECK_ITCH_LEN = 1'b1,
    parameter bit FWD_BYPASS     = 1'b1
) (
    input  var logic                     clk,
    input  var logic                     rst,

    // ── UDP payload in, from eth_ip_udp_rx (NO backpressure) ─────────────────
    input  var logic                     s_pay_valid,
    input  var logic [AXIS_W-1:0]        s_pay_data,
    input  var logic [3:0]               s_pay_bytes,   // 1..8
    input  var logic                     s_pay_sop,
    input  var logic                     s_pay_eop,
    input  var logic                     s_pay_err,     // valid with eop
    input  var cycle_t                   s_pay_t0,

    // ── ITCH message out: ONE message per beat, II = 1 ───────────────────────
    output var logic                     m_valid,
    output var logic [ITCH_MSG_W-1:0]    m_msg,         // byte 0 = ITCH type code
    output var logic [ITCH_LEN_W-1:0]    m_len,         // bytes, == Mold block length
    output var logic [63:0]              m_seq,         // packet seq + index in packet
    output var cycle_t                   m_rx_cycle,    // t0 of the carrying frame

    // ── Out-of-band control (applied immediately, not stream-ordered) ────────
    output var logic                     m_poison,      // last packet is untrustworthy
    output var logic                     m_hb,          // heartbeat packet
    output var logic                     m_endsess,     // end-of-session marker
    output var logic [63:0]              m_ctl_seq,     // seq carried by hb/endsess

    // ── Telemetry event pulses (counted in net_rx_path) ──────────────────────
    output var logic                     evt_pkt,       // a Mold packet was parsed
    output var logic                     evt_msg,       // == m_valid
    output var logic [N_MOLD_EVT-1:0]    evt_mold       // multi-hot reason mask
);

    // =========================================================================
    // 0. Geometry
    // =========================================================================
    localparam int unsigned WIN_WORDS  = 16;
    localparam int unsigned WIN_BYTES  = WIN_WORDS * 8;                 // 128
    localparam int unsigned WPTR_W     = $clog2(WIN_WORDS);             // 4
    localparam int unsigned RPTR_W     = $clog2(WIN_BYTES);             // 7
    localparam int unsigned VIEW_WORDS = 10;                            // 80 B
    localparam int unsigned VIEW_BITS  = VIEW_WORDS * 64;               // 640
    localparam int unsigned BLK_BYTES  = 2 + ITCH_MSG_MAX_BYTES;        // 66
    localparam int unsigned BLK_BITS   = BLK_BYTES * 8;                 // 528
    localparam int unsigned FILL_W     = 10;                            // signed

`ifndef SYNTHESIS
    initial begin
        if (AXIS_W != 32'd64) begin
            $fatal(1, "moldudp64_deframer: window geometry assumes AXIS_W==64");
        end
        // 7 bytes of shift + a 66-byte view must fit inside the gathered words.
        if ((VIEW_WORDS * 8) < (BLK_BYTES + 7)) begin
            $fatal(1, "moldudp64_deframer: VIEW_WORDS too small for BLK_BYTES");
        end
    end
`endif

    // =========================================================================
    // 1. State
    // =========================================================================
    mold_state_e             state_q;
    logic [63:0]             buf_q [WIN_WORDS];
    logic [WPTR_W-1:0]       wr_ptr_q;
    logic [RPTR_W-1:0]       rd_ptr_q;
    logic signed [FILL_W-1:0] fill_q;
    logic [1:0]              pw_cnt_q;      // payload word index, saturates at 3
    logic                    eop_seen_q;

    logic [63:0]             sess_hi_q;     // Mold session bytes 0..7
    logic [15:0]             sess_lo_q;     // Mold session bytes 8..9
    logic [79:0]             sess_ref_q;    // latched at start of day
    logic                    sess_valid_q;
    logic [47:0]             seq_hi_q;      // Mold sequence bytes 0..5 (MSB first)

    // The packet's base sequence is published on m_ctl_seq; cur_seq_q carries
    // the per-message value (packet sequence + index within the packet).
    logic [63:0]             cur_seq_q;
    logic [15:0]             msgs_left_q;
    cycle_t                  t0_q;

    // =========================================================================
    // 2. Window write pointers and fill accounting
    // =========================================================================
    logic [WPTR_W-1:0]        wr_idx_c;
    logic signed [FILL_W-1:0] fill_add_c;
    logic signed [FILL_W-1:0] fill_avail_c;   // bytes available ahead of rd_ptr
    logic signed [FILL_W-1:0] fill_next_c;
    logic [7:0]               consumed_c;

    // On sop the packet restarts at window word 0 / byte 0, and the read
    // pointer jumps straight to the first message block at Mold byte 20.
    assign wr_idx_c   = s_pay_sop ? WPTR_W'(0) : wr_ptr_q;
    // ⚠️ Every comparison against fill is SIGNED. fill is negative while the
    //    20-byte Mold header is still being absorbed; an unsigned compare
    //    would read -12 as 1012 and emit a message from an empty window.
    assign fill_add_c = s_pay_valid ? $signed({{(FILL_W-4){1'b0}}, s_pay_bytes})
                                    : {FILL_W{1'b0}};
    // fill starts at -MOLD_HDR_LEN so that it reaches 0 exactly when the first
    // message-block length byte becomes available. One counter, no special case.
    assign fill_avail_c = fill_q + fill_add_c;
    assign fill_next_c  = fill_avail_c - $signed({2'b00, consumed_c});

    always_ff @(posedge clk) begin
        if (s_pay_valid) begin
            buf_q[wr_idx_c] <= s_pay_data;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr_q <= '0;
            rd_ptr_q <= '0;
            fill_q   <= '0;
        end else begin
            if (s_pay_valid) begin
                wr_ptr_q <= wr_idx_c + WPTR_W'(1);
            end
            if (s_pay_sop) begin
                rd_ptr_q <= RPTR_W'(MOLD_HDR_LEN);
                fill_q   <= -$signed(FILL_W'(MOLD_HDR_LEN)) + $signed(fill_add_c);
            end else begin
                rd_ptr_q <= rd_ptr_q + RPTR_W'(consumed_c);
                fill_q   <= fill_next_c;
            end
        end
    end

    // =========================================================================
    // 3. Window read: 10-word gather (wrapping) + byte barrel shift
    // =========================================================================
    logic [WPTR_W-1:0]     view_idx  [VIEW_WORDS];
    logic [63:0]           view_word [VIEW_WORDS];
    logic [VIEW_BITS-1:0]  view_raw;
    logic [BLK_BITS-1:0]   blk_view;

    // The 4-bit adder wraps mod 16 for free — the SAME modulus as rd_ptr_q.
    always_comb begin
        for (int unsigned i = 0; i < VIEW_WORDS; i++) begin
            view_idx[i] = rd_ptr_q[RPTR_W-1:3] + WPTR_W'(i);
        end
    end

    always_comb begin
        for (int unsigned i = 0; i < VIEW_WORDS; i++) begin
            view_word[i] = buf_q[view_idx[i]];
            if (FWD_BYPASS && s_pay_valid && (view_idx[i] == wr_idx_c)) begin
                // Write-forwarding: the beat arriving this cycle has not been
                // registered yet, but its bytes may complete the message. This
                // is the one cycle of latency this block would otherwise cost.
                view_word[i] = s_pay_data;
            end
        end
    end

    always_comb begin
        view_raw = '0;
        for (int unsigned i = 0; i < VIEW_WORDS; i++) begin
            view_raw[64*i +: 64] = view_word[i];
        end
    end

    // 3 levels of 2:1 byte mux (shift 1, 2, 4 bytes). Byte 0 of blk_view is
    // now the first byte of the next message block, by construction.
    // Base is 0, 8, ..., 56 and BLK_BITS = 528, so the select never runs past
    // VIEW_BITS = 640 (checked at elaboration above).
    logic [9:0] shift_bits_c;
    assign shift_bits_c = {4'd0, rd_ptr_q[2:0], 3'b000};
    assign blk_view     = view_raw[shift_bits_c +: BLK_BITS];

    // =========================================================================
    // 4. Message-block decode
    // =========================================================================
    logic [15:0]              blk_len_c;      // big-endian on the wire
    logic [7:0]               msg_type_c;
    logic [15:0]              exp_len_c;
    logic                     blk_sane_c;
    logic                     known_type_c;
    logic                     len_ok_c;
    logic                     have_len_c;
    logic                     have_msg_c;
    logic signed [FILL_W-1:0] need_c;
    logic                     emit_c;
    logic                     abort_c;
    logic                     trunc_c;
    logic [ITCH_MSG_W-1:0]    msg_c;

    assign blk_len_c    = {blk_view[7:0], blk_view[15:8]};
    assign msg_type_c   = blk_view[23:16];
    assign exp_len_c    = 16'(itch_msg_len(msg_type_c));
    assign known_type_c = (exp_len_c != 16'd0);
    assign blk_sane_c   = (blk_len_c != 16'd0) &&
                          (blk_len_c <= 16'(ITCH_MSG_MAX_BYTES));
    assign len_ok_c     = !CHECK_ITCH_LEN || !known_type_c ||
                          (blk_len_c == exp_len_c);

    assign have_len_c   = (fill_avail_c >= 10'sd2);
    // need_c is only meaningful when blk_sane_c; blk_len_c[6:0] then holds the
    // whole value (<= 64), so the compare stays inside FILL_W.
    assign need_c       = 10'sd2 + $signed({{(FILL_W-7){1'b0}}, blk_len_c[6:0]});
    assign have_msg_c   = blk_sane_c && (fill_avail_c >= need_c);

    assign emit_c  = (state_q == MOLD_S_BODY) && (msgs_left_q != 16'd0) &&
                     have_msg_c && len_ok_c;

    // Abandon the packet as soon as the framing is provably broken. Checking
    // blk_sane on have_len (not have_msg) is what prevents a deadlock on a
    // corrupt length: fill can never reach 2 + 1000.
    assign abort_c = (state_q == MOLD_S_BODY) && (msgs_left_q != 16'd0) &&
                     ((have_len_c && !blk_sane_c) ||
                      (have_msg_c && !len_ok_c));

    // Packet ended and the remaining blocks can never complete.
    assign trunc_c = (state_q == MOLD_S_BODY) && (msgs_left_q != 16'd0) &&
                     eop_seen_q && !emit_c && !abort_c;

    assign consumed_c = emit_c ? (8'd2 + {1'b0, blk_len_c[6:0]}) : 8'd0;

    // Mask the message body to its declared length so the output is
    // deterministic and byte-exact against the golden model. Bytes beyond
    // m_len are window residue and must never leak downstream.
    always_comb begin
        msg_c = '0;
        for (int unsigned i = 0; i < ITCH_MSG_MAX_BYTES; i++) begin
            if (32'(i) < 32'(blk_len_c)) begin
                msg_c[8*i +: 8] = blk_view[16 + 8*i +: 8];
            end
        end
    end

    // =========================================================================
    // 5. Packet header capture (fixed offsets — the header never straddles)
    // =========================================================================
    //   payload word 0 : Mold bytes  0.. 7  session[0..7]
    //   payload word 1 : Mold bytes  8..15  session[8..9], seq[0..5]
    //   payload word 2 : Mold bytes 16..23  seq[6..7], count, (first blk len)
    logic [1:0]  pw_idx_c;
    logic [15:0] seq_lo_c;
    logic [15:0] msg_cnt_c;
    logic [79:0] sess_c;
    logic [63:0] pkt_seq_c;
    logic        hdr_done_c;
    logic        is_hb_c;
    logic        is_endsess_c;
    logic        sess_bad_c;

    assign pw_idx_c   = s_pay_sop ? 2'd0 : pw_cnt_q;
    assign seq_lo_c   = be16_lane(s_pay_data, 0);
    assign msg_cnt_c  = be16_lane(s_pay_data, 2);
    assign sess_c     = {sess_hi_q, sess_lo_q};
    assign pkt_seq_c  = {seq_hi_q, seq_lo_c};
    assign hdr_done_c = s_pay_valid && (state_q == MOLD_S_HDR) && (pw_idx_c == 2'd2);
    assign is_hb_c      = (msg_cnt_c == MOLD_CNT_HEARTBEAT);
    assign is_endsess_c = (msg_cnt_c == MOLD_CNT_ENDSESS);
    // ⚠️ Never auto-adopt a new session ID (02.03 §9 rule 11).
    assign sess_bad_c   = sess_valid_q && (sess_c != sess_ref_q);

    always_ff @(posedge clk) begin
        if (s_pay_valid) begin
            case (pw_idx_c)
                2'd0: sess_hi_q <= s_pay_data;                       // bytes 0..7
                2'd1: begin
                    sess_lo_q <= be16_lane(s_pay_data, 0);           // bytes 8,9
                    seq_hi_q  <= {byte_lane(s_pay_data, 2), byte_lane(s_pay_data, 3),
                                  byte_lane(s_pay_data, 4), byte_lane(s_pay_data, 5),
                                  byte_lane(s_pay_data, 6), byte_lane(s_pay_data, 7)};
                end
                default: begin
                    sess_hi_q <= sess_hi_q;
                end
            endcase
        end
        if (s_pay_sop) begin
            t0_q <= s_pay_t0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            pw_cnt_q <= 2'd0;
        end else if (s_pay_valid) begin
            pw_cnt_q <= (pw_idx_c == 2'd3) ? 2'd3 : (pw_idx_c + 2'd1);
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sess_ref_q   <= '0;
            sess_valid_q <= 1'b0;
        end else if (hdr_done_c && !sess_valid_q) begin
            // Start of day: the first session seen after reset is THE session.
            sess_ref_q   <= sess_c;
            sess_valid_q <= 1'b1;
        end
    end

    // =========================================================================
    // 6. Control FSM
    // =========================================================================
    logic overrun_c;
    assign overrun_c = s_pay_sop && (state_q != MOLD_S_IDLE);

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q     <= MOLD_S_IDLE;
            msgs_left_q <= 16'd0;
            eop_seen_q  <= 1'b0;
            cur_seq_q   <= '0;
        end else begin
            // --- packet start (also the recovery path for an overrun) --------
            if (s_pay_sop) begin
                state_q     <= MOLD_S_HDR;
                msgs_left_q <= 16'd0;
                eop_seen_q  <= s_pay_eop;
            end else begin
                if (s_pay_eop) begin
                    eop_seen_q <= 1'b1;
                end

                case (state_q)
                    MOLD_S_HDR: begin
                        if (hdr_done_c) begin
                            cur_seq_q <= pkt_seq_c;
                            if (sess_bad_c) begin
                                state_q     <= MOLD_S_ABORT;
                                msgs_left_q <= 16'd0;
                            end else if (is_hb_c || is_endsess_c) begin
                                state_q     <= MOLD_S_DRAIN;
                                msgs_left_q <= 16'd0;
                            end else begin
                                state_q     <= MOLD_S_BODY;
                                msgs_left_q <= msg_cnt_c;
                            end
                        end else if (eop_seen_q || s_pay_eop) begin
                            // Packet ended before the 20-byte header completed.
                            state_q <= MOLD_S_ABORT;
                        end
                    end

                    MOLD_S_BODY: begin
                        if (abort_c || trunc_c) begin
                            state_q <= MOLD_S_ABORT;
                        end else if (emit_c) begin
                            cur_seq_q <= cur_seq_q + 64'd1;
                            if (msgs_left_q == 16'd1) begin
                                state_q <= MOLD_S_DRAIN;
                            end
                            msgs_left_q <= msgs_left_q - 16'd1;
                        end
                    end

                    MOLD_S_DRAIN: begin
                        if (eop_seen_q || s_pay_eop) begin
                            state_q <= MOLD_S_IDLE;
                        end
                    end

                    MOLD_S_ABORT: begin
                        if (eop_seen_q || s_pay_eop) begin
                            state_q <= MOLD_S_IDLE;
                        end
                    end

                    default: begin   // MOLD_S_IDLE
                        state_q <= MOLD_S_IDLE;
                    end
                endcase
            end
        end
    end

    // Packet completion: the cycle on which we leave HDR/BODY/DRAIN/ABORT.
    logic pkt_close_c;
    logic pkt_bad_close_c;
    logic trailing_c;

    assign pkt_close_c     = ((state_q == MOLD_S_DRAIN) || (state_q == MOLD_S_ABORT)) &&
                             (eop_seen_q || s_pay_eop) && !s_pay_sop;
    assign pkt_bad_close_c = pkt_close_c && (state_q == MOLD_S_ABORT);
    // Bytes left over after MessageCount blocks were consumed.
    assign trailing_c      = pkt_close_c && (state_q == MOLD_S_DRAIN) &&
                             (fill_avail_c > 10'sd0) && (msgs_left_q == 16'd0);

    // =========================================================================
    // 7. Registered outputs
    // =========================================================================
    logic pay_err_c;
    assign pay_err_c = s_pay_eop && s_pay_err;

    always_ff @(posedge clk) begin
        if (rst) begin
            m_valid   <= 1'b0;
            m_poison  <= 1'b0;
            m_hb      <= 1'b0;
            m_endsess <= 1'b0;
        end else begin
            m_valid   <= emit_c;
            // ⚠️ Poison means "everything you just took from this packet is
            //    untrustworthy". ab_arbiter turns it into a channel stale.
            m_poison  <= pay_err_c || pkt_bad_close_c || abort_c || trunc_c ||
                         overrun_c || (hdr_done_c && sess_bad_c);
            m_hb      <= hdr_done_c && !sess_bad_c && is_hb_c;
            m_endsess <= hdr_done_c && !sess_bad_c && is_endsess_c;
        end
    end

    always_ff @(posedge clk) begin
        m_msg      <= msg_c;
        m_len      <= blk_len_c[ITCH_LEN_W-1:0];
        m_seq      <= cur_seq_q;
        m_rx_cycle <= t0_q;
        if (hdr_done_c) begin
            m_ctl_seq <= pkt_seq_c;
        end
    end

    // =========================================================================
    // 8. Telemetry
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            evt_pkt  <= 1'b0;
            evt_msg  <= 1'b0;
            evt_mold <= '0;
        end else begin
            evt_pkt <= hdr_done_c;
            evt_msg <= emit_c;

            evt_mold <= '0;
            if (trunc_c)                        evt_mold[MOLD_EVT_TRUNC]    <= 1'b1;
            if (abort_c && !blk_sane_c)         evt_mold[MOLD_EVT_BLKLEN]   <= 1'b1;
            if (abort_c && blk_sane_c)          evt_mold[MOLD_EVT_ITCHLEN]  <= 1'b1;
            if (emit_c && !known_type_c)        evt_mold[MOLD_EVT_UNKTYPE]  <= 1'b1;
            if (trailing_c)                     evt_mold[MOLD_EVT_TRAILING] <= 1'b1;
            if (hdr_done_c && sess_bad_c)       evt_mold[MOLD_EVT_SESSION]  <= 1'b1;
            if (hdr_done_c && is_endsess_c)     evt_mold[MOLD_EVT_ENDSESS]  <= 1'b1;
            if (overrun_c)                      evt_mold[MOLD_EVT_OVERRUN]  <= 1'b1;
        end
    end

    // =========================================================================
    // 9. Assertions — the invariants that make §A.5 true
    // =========================================================================
`ifndef SYNTHESIS
    // THE window-sizing invariant. If this fires, §A.5's arithmetic is wrong
    // and the read side is no longer outpacing the write side. That is a design
    // bug, not a runtime condition.
    assert property (@(posedge clk) disable iff (rst)
        fill_avail_c <= $signed(FILL_W'(WIN_BYTES))
    ) else $error("moldudp64_deframer: window overrun — buffer sizing invariant broken");

    // fill must never go negative once the header has been consumed: that would
    // mean rd_ptr passed wr_ptr and we emitted bytes that never arrived.
    assert property (@(posedge clk) disable iff (rst)
        (state_q == MOLD_S_BODY) |-> (fill_next_c >= 10'sd0)
    ) else $error("moldudp64_deframer: read pointer overtook write pointer");

    // Output contract.
    assert property (@(posedge clk) disable iff (rst)
        m_valid |-> ((m_len != '0) && (m_len <= ITCH_LEN_W'(ITCH_MSG_MAX_BYTES)))
    ) else $error("moldudp64_deframer: message emitted with an illegal length");

    assert property (@(posedge clk) disable iff (rst)
        emit_c |-> ((state_q == MOLD_S_BODY) && (msgs_left_q != 16'd0))
    ) else $error("moldudp64_deframer: emit outside the message-block body");

    // Sequence numbering: message k of a packet carries pkt_seq + k.
    assert property (@(posedge clk) disable iff (rst)
        (emit_c && $past(emit_c)) |-> (cur_seq_q == ($past(cur_seq_q) + 64'd1))
    ) else $error("moldudp64_deframer: per-message sequence is not contiguous");

    // ⚠️ DESIGN INVARIANT — must never fire. If it does, the drain-vs-arrival
    //    margin in §A.5 is wrong and messages are being lost.
    assert property (@(posedge clk) disable iff (rst)
        !overrun_c
    ) else $error("moldudp64_deframer: new packet arrived before the last one drained");

    // A malformed packet must never close silently.
    assert property (@(posedge clk) disable iff (rst)
        (abort_c || trunc_c) |=> m_poison
    ) else $error("moldudp64_deframer: packet abandoned without poisoning the channel");
`endif

endmodule : moldudp64_deframer

`default_nettype wire
