// =============================================================================
// eth_ip_udp_rx.sv — Ethernet + IPv4 + UDP header strip, one feed
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/02-networking/02-ip-udp-tcp-in-hardware.md  (§1, §2, §3)
//           manuals/02-networking/01-ethernet-phy-mac.md        (§6 cut-through)
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   Take raw 64-bit MAC RX beats and emit the UDP payload (= the MoldUDP64
//   packet) as a byte-aligned 64-bit stream with start/end markers, an ingress
//   timestamp, and an end-of-packet error verdict.
//
// LATENCY
//   1 cycle = 6.40 ns @ 156.25 MHz (6.4 ns/cycle).
//   Measured from the beat carrying a payload byte to that byte appearing on
//   m_pay_data. Fixed — there is no data-dependent path. This is the
//   "Ethernet/IPv4/UDP header strip  1 cyc  6.4 ns" row of the fpga_top budget.
//   The accept/reject decision completes at beat 4 (frame byte 39), which is
//   two beats BEFORE the first payload byte can be emitted, so filtering costs
//   nothing and never speculates.
//
// RESOURCE (estimate, pre-synthesis — replace with real utilization)
//   LUT ~650   FF ~420   BRAM 0   URAM 0   DSP 0
//   Dominated by the 10-word ones'-complement adder tree and the N_MATCH
//   48-bit comparator array. Header extraction itself is pure wiring.
//
// -----------------------------------------------------------------------------
// ⚠️⚠️  THE THING THIS MODULE EXISTS TO PREVENT  ⚠️⚠️
//
//   A SILENTLY MIS-PARSED HEADER IS THE WORST OUTCOME IN THIS ENTIRE LAYER.
//
//   Three legal-but-unexpected header shapes move every downstream byte offset:
//
//     hazard              what moves                      detected by
//     ------------------  ------------------------------  --------------------
//     802.1Q VLAN tag     everything from byte 14 by +4   EtherType == 0x8100
//     802.1ad QinQ        ...by +8                        EtherType == 0x88A8
//     IPv4 options IHL>5  UDP header by +4..+40           ver_ihl != 0x45
//     IP fragment 2..N    NO UDP HEADER AT ALL            MF set or fragoff != 0
//
//   If any of these reaches the MoldUDP64 deframer, the deframer reads
//   arbitrary payload bytes as a session ID and a 64-bit sequence number. The
//   sequencer then sees a wild sequence jump and declares a catastrophic gap —
//   or, far worse, a *plausible* one, and the book quietly diverges from
//   reality while the design reports itself healthy.
//
//   THE REQUIRED BEHAVIOUR IS THEREFORE: DROP AND COUNT, NEVER RE-PARSE.
//   There is no variable-offset shifter on this path and there must never be
//   one (02.02 §2). A barrel shifter over the header region is expensive, slow,
//   and — because only traffic we should never see exercises it — untested.
//   If production traffic genuinely acquires VLAN tags, that is a
//   change-control event, not something the hardware absorbs silently.
//
//   Every reason has its own bit in evt_hdr_drop, because "packets dropped"
//   with no reason code is useless at 09:31 on a bad morning.
// -----------------------------------------------------------------------------
//
// CUT-THROUGH / BAD-FCS CONTRACT (02.01 §6)
//   The MAC is cut-through: the payload has already been forwarded by the time
//   the FCS resolves. tuser==1 on tlast means "that frame was corrupt". We
//   cannot un-send the bytes, so we mark them — m_pay_err is asserted with
//   m_pay_eop and the deframer poisons the packet, which stales the channel.
//   Speculating is correct (colo BER target 1e-12); speculating with no
//   invalidation path is a working-but-wrong design.
//   This is also why m_pay_eop is a SEPARATE strobe from m_pay_valid: Ethernet
//   pads short frames to 60 bytes, so the declared UDP payload routinely ends
//   several beats before tlast — and the FCS verdict does not exist until
//   tlast. eop must therefore ride the frame end, not the data end.
//
// NO BACKPRESSURE (CLAUDE.md §5.4)
//   There is deliberately no s_axis_tready port. This block accepts a beat
//   every cycle, unconditionally, forever. Overload is expressed as a counted
//   drop, never as a stall.
// =============================================================================
`default_nettype none

module eth_ip_udp_rx
    import trading_pkg::*;
    import net_rx_pkg::*;
#(
    // Multicast match table. Feed identity is (dst IP, dst UDP port); never the
    // MAC address (02.02 §8 rule 4). These parameters are the RESET VALUE of a
    // runtime-writable table — see cfg_match_* below.
    parameter int unsigned              N_MATCH    = 4,
    parameter logic [N_MATCH-1:0][31:0] MATCH_IP   = '0,
    parameter logic [N_MATCH-1:0][15:0] MATCH_PORT = '0,
    parameter logic [N_MATCH-1:0]       MATCH_EN   = '0,
    // Verify the IPv4 header checksum. Free, and it catches the corruption a
    // cut-through switch can introduce after the FCS was last recomputed.
    parameter bit                       CHECK_IP_CSUM = 1'b1
) (
    input  var logic                       clk,
    input  var logic                       rst,           // sync, active high
    input  var cycle_t                     cycle_cnt,     // free-running, never reset

    // ── MAC RX stream (NO tready — see header) ───────────────────────────────
    input  var logic [AXIS_W-1:0]          s_axis_tdata,
    input  var logic [AXIS_KEEP_W-1:0]     s_axis_tkeep,
    input  var logic                       s_axis_tvalid,
    input  var logic                       s_axis_tlast,
    input  var logic                       s_axis_tuser,  // 1 = frame had a bad FCS

    // ── Host match-table write port (slow path) ──────────────────────────────
    // Not yet routed from host_ctrl: net_rx_path ties these off and uses the
    // parameters above. Threading them through is a deliberate, reviewable
    // change to fpga_top's port contract — see rtl/net/README.md.
    input  var logic                       cfg_match_wr,
    input  var logic [$clog2(N_MATCH > 1 ? N_MATCH : 2)-1:0] cfg_match_idx,
    input  var match_rec_t                 cfg_match_rec,

    // ── UDP payload out (byte-aligned, up to 8 bytes/beat) ───────────────────
    output var logic                       m_pay_valid,
    output var logic [AXIS_W-1:0]          m_pay_data,
    output var logic [3:0]                 m_pay_bytes,   // 1..8, valid with m_pay_valid
    output var logic                       m_pay_sop,     // first payload word of a packet
    output var logic                       m_pay_eop,     // last cycle of the packet
    output var logic                       m_pay_err,     // valid with eop: DISCARD packet
    output var cycle_t                     m_pay_t0,      // ingress ts, held for the packet
    output var logic [PAY_LEN_W-1:0]       m_pay_len,     // declared payload bytes

    // ── Telemetry event pulses (counted in net_rx_path) ──────────────────────
    output var logic                       evt_frame,     // a frame arrived
    output var logic                       evt_accept,    // ...and passed the predicate
    output var logic                       evt_fcs_err,   // ...and had a bad FCS
    output var logic [N_HDR_DROP-1:0]      evt_hdr_drop   // multi-hot reason mask
);

    // =========================================================================
    // 0. Elaboration guards and derived offsets
    // =========================================================================
    // The fixed-slice (beat, lane) map below is derived for an 8-byte beat, and
    // one field — the IPv4 destination address, frame bytes 30..33 — straddles
    // a beat boundary at exactly this width and is hand-stitched in §2. Do not
    // change AXIS_W without revisiting that stitch.
`ifndef SYNTHESIS
    initial begin
        if (AXIS_W != 32'd64) begin
            $fatal(1, "eth_ip_udp_rx: fixed-slice header map assumes AXIS_W==64");
        end
    end
`endif

    localparam int unsigned BPB = AXIS_KEEP_W;                 // bytes per beat = 8

    // (beat, lane) for every header field. Computed, not typed in by hand.
    localparam int unsigned B_ETYPE   = ETH_TYPE_OFF   / BPB;  // 1
    localparam int unsigned L_ETYPE   = ETH_TYPE_OFF   % BPB;  // 4
    localparam int unsigned L_VERIHL  = IP_VER_IHL_OFF % BPB;  // 6  (also IP word 0)
    localparam int unsigned B_IPHI    = IP_TOTLEN_OFF  / BPB;  // 2
    localparam int unsigned L_FRAG    = IP_FRAGOFF_OFF % BPB;  // 4
    localparam int unsigned L_PROTO   = IP_PROTO_OFF   % BPB;  // 7
    localparam int unsigned B_IPLO    = IP_CSUM_OFF    / BPB;  // 3
    localparam int unsigned L_IPDSTHI = IP_DST_OFF     % BPB;  // 6
    localparam int unsigned B_UDP     = UDP_DPORT_OFF  / BPB;  // 4
    localparam int unsigned L_IPDSTLO = 0;                     // frame bytes 32,33
    localparam int unsigned L_UDPDP   = UDP_DPORT_OFF  % BPB;  // 4
    localparam int unsigned L_UDPLEN  = UDP_LEN_OFF    % BPB;  // 6

    // Last header beat: the beat that completes the UDP length (frame byte 39).
    localparam int unsigned HDR_LAST_BEAT  = B_UDP;                          // 4
    // First beat that can complete a payload word (payload byte 49 -> beat 6).
    localparam int unsigned PAY_FIRST_BEAT = (PAYLOAD_OFF + BPB - 1) / BPB;  // 6
    // Byte lane within a beat at which the payload starts (frame byte 42 -> 2).
    localparam int unsigned PAY_SHIFT      = PAYLOAD_OFF % BPB;              // 2
    // Only the bytes ABOVE the payload split are ever re-read from the previous
    // beat, so only those are registered: 48 FFs per feed instead of 64.
    localparam int unsigned PREV_KEEP_W    = AXIS_W - (8 * PAY_SHIFT);       // 48
    localparam int unsigned BCNT_W         = 11;               // 1518 B / 8 = 190 beats

    // =========================================================================
    // 1. Frame sequencing
    // =========================================================================
    logic                  in_frame_q;
    logic [BCNT_W-1:0]     bcnt_q;
    logic [PREV_KEEP_W-1:0] prev_hi_q;    // previous beat's upper bytes (realign)
    logic                  sof;

    assign sof = s_axis_tvalid && !in_frame_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            in_frame_q <= 1'b0;
            bcnt_q     <= '0;
        end else if (s_axis_tvalid) begin
            in_frame_q <= !s_axis_tlast;
            bcnt_q     <= s_axis_tlast ? '0 : (bcnt_q + BCNT_W'(1));
        end
    end

    // Datapath register — no reset needed (03-hdl-and-rtl-coding.md §6).
    always_ff @(posedge clk) begin
        if (s_axis_tvalid) begin
            prev_hi_q <= s_axis_tdata[AXIS_W-1 : 8*PAY_SHIFT];
        end
    end

    // =========================================================================
    // 2. Fixed-slice header extraction — pure wiring, zero logic
    // =========================================================================
    logic [15:0] etype_q;
    logic [7:0]  verihl_q;
    logic [15:0] frag_q;
    logic [7:0]  proto_q;
    logic [15:0] ipdst_hi_q;      // frame bytes 30,31 (beat 3) — straddle, part 1
    logic [31:0] ipsum_q;         // ones'-complement accumulator, 10 x 16-bit words

    logic [15:0] ipdst_lo_c;      // frame bytes 32,33 (beat 4) — straddle, part 2
    logic [31:0] ip_dst_c;
    logic [15:0] udp_dport_c;
    logic [15:0] udp_len_c;
    logic [31:0] ipsum_c;

    assign ipdst_lo_c  = be16_lane(s_axis_tdata, L_IPDSTLO);
    assign ip_dst_c    = {ipdst_hi_q, ipdst_lo_c};
    assign udp_dport_c = be16_lane(s_axis_tdata, L_UDPDP);
    assign udp_len_c   = be16_lane(s_axis_tdata, L_UDPLEN);
    // Final IPv4 word (bytes 32,33) folded in combinationally on beat 4, so the
    // verdict is ready at the same edge as the last header field is latched.
    assign ipsum_c     = ipsum_q + {16'd0, ipdst_lo_c};

    always_ff @(posedge clk) begin
        if (sof) begin
            ipsum_q <= 32'd0;
        end else if (s_axis_tvalid && in_frame_q) begin
            case (bcnt_q)
                BCNT_W'(B_ETYPE): begin
                    etype_q  <= be16_lane(s_axis_tdata, L_ETYPE);
                    verihl_q <= byte_lane(s_axis_tdata, L_VERIHL);
                    // IPv4 word 0: frame bytes 14,15
                    ipsum_q  <= ipsum_q + {16'd0, be16_lane(s_axis_tdata, L_VERIHL)};
                end
                BCNT_W'(B_IPHI): begin
                    frag_q   <= be16_lane(s_axis_tdata, L_FRAG);
                    proto_q  <= byte_lane(s_axis_tdata, L_PROTO);
                    // IPv4 words 1..4: frame bytes 16..23
                    ipsum_q  <= ipsum_q + {16'd0, be16_lane(s_axis_tdata, 0)}
                                        + {16'd0, be16_lane(s_axis_tdata, 2)}
                                        + {16'd0, be16_lane(s_axis_tdata, 4)}
                                        + {16'd0, be16_lane(s_axis_tdata, 6)};
                end
                BCNT_W'(B_IPLO): begin
                    ipdst_hi_q <= be16_lane(s_axis_tdata, L_IPDSTHI);
                    // IPv4 words 5..8: frame bytes 24..31
                    ipsum_q  <= ipsum_q + {16'd0, be16_lane(s_axis_tdata, 0)}
                                        + {16'd0, be16_lane(s_axis_tdata, 2)}
                                        + {16'd0, be16_lane(s_axis_tdata, 4)}
                                        + {16'd0, be16_lane(s_axis_tdata, 6)};
                end
                default: begin
                    // Beat 0 and beats >= 4 contribute nothing to the IP header.
                    ipsum_q <= ipsum_q;
                end
            endcase
        end
    end

    // =========================================================================
    // 3. Match table — (dst IP, dst UDP port) -> accept
    // =========================================================================
    match_rec_t match_q [N_MATCH];
    logic       match_hit_c;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned i = 0; i < N_MATCH; i++) begin
                match_q[i].en       <= MATCH_EN[i];
                match_q[i].dst_ip   <= MATCH_IP[i];
                match_q[i].dst_port <= MATCH_PORT[i];
            end
        end else if (cfg_match_wr) begin
            match_q[cfg_match_idx] <= cfg_match_rec;
        end
    end

    always_comb begin
        match_hit_c = 1'b0;
        for (int unsigned i = 0; i < N_MATCH; i++) begin
            if (match_q[i].en &&
                (match_q[i].dst_ip   == ip_dst_c) &&
                (match_q[i].dst_port == udp_dport_c)) begin
                match_hit_c = 1'b1;
            end
        end
    end

    // =========================================================================
    // 4. The validity predicate — computed once, at beat 4
    // =========================================================================
    logic [N_HDR_DROP-1:0] drop_c;
    logic                  accept_c;
    logic                  ipcsum_ok_c;
    logic                  is_vlan_c;
    logic                  hdr_verdict_c;   // the beat on which accept/reject is decided
    logic                  runt_c;          // frame ended before the header completed

    assign ipcsum_ok_c   = !CHECK_IP_CSUM || (csum_fold(ipsum_c) == IP_CSUM_RESIDUE);
    assign is_vlan_c     = (etype_q == ETYPE_VLAN) || (etype_q == ETYPE_QINQ) ||
                           (etype_q == ETYPE_QINQ_ALT);
    assign hdr_verdict_c = s_axis_tvalid && in_frame_q &&
                           (bcnt_q == BCNT_W'(HDR_LAST_BEAT));
    assign runt_c        = s_axis_tvalid && s_axis_tlast &&
                           (bcnt_q < BCNT_W'(HDR_LAST_BEAT));

    always_comb begin
        drop_c = '0;
        // All reasons are evaluated; the mask is multi-hot. A VLAN-tagged frame
        // is NOT also reported as "not IPv4" — the tag is the actionable fact.
        if (is_vlan_c) begin
            drop_c[HDR_DROP_VLAN]     = 1'b1;
        end else if (etype_q != ETYPE_IPV4) begin
            drop_c[HDR_DROP_NOT_IPV4] = 1'b1;
        end else begin
            if (verihl_q != IP_VER_IHL_OK)              drop_c[HDR_DROP_OPTIONS] = 1'b1;
            if (frag_q[IP_FLAG_MF_BIT] ||
                (frag_q[12:0] != 13'd0))                drop_c[HDR_DROP_FRAG]    = 1'b1;
            if (proto_q != IP_PROTO_UDP)                drop_c[HDR_DROP_PROTO]   = 1'b1;
            if (!ipcsum_ok_c)                           drop_c[HDR_DROP_IPCSUM]  = 1'b1;
            if (!match_hit_c)                           drop_c[HDR_DROP_NOMATCH] = 1'b1;
            if ((udp_len_c < PAY_LEN_W'(UDP_LEN_MIN)) ||
                (udp_len_c > PAY_LEN_W'(PAY_MAX_BYTES + UDP_HDR_LEN)))
                                                        drop_c[HDR_DROP_LEN]     = 1'b1;
        end
    end

    assign accept_c = (drop_c == '0);

    // =========================================================================
    // 5. Payload realignment and emission
    // =========================================================================
    // The UDP payload starts at frame byte 42 = beat 5, lane 2. That offset is
    // a compile-time CONSTANT (fixed-slice fast path), so realignment is a
    // fixed 2-byte stitch between the previous beat and the current one —
    // pure wiring, no barrel shifter:
    //
    //   frame bytes:  ... 40 41 | 42 43 44 45 46 47 | 48 49 50 ...
    //   beat 5:      [ 40 ................... 47 ]
    //   beat 6:                                     [ 48 ......... 55 ]
    //   payload w0:            [ 42 43 44 45 46 47   48 49 ]
    //                          └─── prev_hi_q ──────┘└ cur 0..1 ┘
    //
    logic                  accept_q;
    logic [PAY_LEN_W-1:0]  pay_len_q;      // declared UDP payload bytes
    logic [PAY_LEN_W-1:0]  pay_cnt_q;      // payload bytes emitted so far
    logic                  sop_done_q;
    cycle_t                t0_q;

    logic [3:0]            keep_bytes_c;
    logic [3:0]            avail_c;
    logic [3:0]            eff_avail_c;
    logic [PAY_LEN_W-1:0]  want_c;
    logic [3:0]            pay_bytes_c;
    logic                  pay_emit_c;
    logic [AXIS_W-1:0]     pay_data_c;

    logic                  flush_pend_q;
    logic [3:0]            last_keep_q;
    logic                  fcs_err_q;
    logic                  flush_emit_c;
    logic [3:0]            flush_avail_c;

    assign keep_bytes_c = keep_bytes8(s_axis_tkeep);

    // Bytes of payload this beat can complete. A non-last beat always completes
    // 8 (6 from prev_q + 2 from the current beat). The last beat completes
    // 6 + min(2, valid bytes in that beat).
    always_comb begin
        if (s_axis_tlast) begin
            avail_c = 4'd6 + ((keep_bytes_c >= 4'd2) ? 4'd2 : keep_bytes_c);
        end else begin
            avail_c = 4'd8;
        end
    end

    // Tail flush: after tlast, bytes 8L+2 .. 8L+keep-1 of the final beat are
    // still sitting in prev_q. At most 6 bytes; exactly one extra cycle.
    assign flush_avail_c = (last_keep_q > 4'd2) ? (last_keep_q - 4'd2) : 4'd0;

    assign want_c      = pay_len_q - pay_cnt_q;
    assign eff_avail_c = flush_pend_q ? flush_avail_c : avail_c;
    assign pay_bytes_c = (want_c < {12'd0, eff_avail_c}) ? want_c[3:0] : eff_avail_c;

    assign pay_emit_c  = s_axis_tvalid && in_frame_q && accept_q &&
                         (bcnt_q >= BCNT_W'(PAY_FIRST_BEAT)) &&
                         (pay_cnt_q < pay_len_q);

    assign flush_emit_c = flush_pend_q && accept_q &&
                          (pay_cnt_q < pay_len_q) && (flush_avail_c != 4'd0);

    always_comb begin
        if (flush_pend_q) begin
            pay_data_c = {{(8*PAY_SHIFT){1'b0}}, prev_hi_q};
        end else begin
            pay_data_c = {s_axis_tdata[8*PAY_SHIFT-1 : 0], prev_hi_q};
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            flush_pend_q <= 1'b0;
        end else begin
            flush_pend_q <= s_axis_tvalid && s_axis_tlast && in_frame_q;
        end
    end

    always_ff @(posedge clk) begin
        if (s_axis_tvalid && s_axis_tlast) begin
            last_keep_q <= keep_bytes_c;
            fcs_err_q   <= s_axis_tuser;
        end
    end

    // Per-frame state. ⚠️ sof MUST take priority over the emit update: the MAC
    // may present the next frame's beat 0 in the very same cycle as this
    // frame's tail flush, and the new frame's counters must start at zero.
    always_ff @(posedge clk) begin
        if (rst) begin
            accept_q   <= 1'b0;
            sop_done_q <= 1'b0;
            pay_cnt_q  <= '0;
            pay_len_q  <= '0;
        end else if (sof) begin
            accept_q   <= 1'b0;
            sop_done_q <= 1'b0;
            pay_cnt_q  <= '0;
        end else begin
            if (hdr_verdict_c) begin
                accept_q  <= accept_c;
                pay_len_q <= accept_c ? (udp_len_c - PAY_LEN_W'(UDP_HDR_LEN))
                                      : PAY_LEN_W'(0);
            end
            if (pay_emit_c || flush_emit_c) begin
                sop_done_q <= 1'b1;
                pay_cnt_q  <= pay_cnt_q + {12'd0, pay_bytes_c};
            end
        end
    end

    // Ingress timestamp: captured on the FIRST beat of the frame, before any
    // parsing, before we know whether we want the frame. This is t0 for every
    // latency measurement in the system (04.02 §9). Datapath — no reset.
    always_ff @(posedge clk) begin
        if (sof) begin
            t0_q <= cycle_cnt;
        end
    end

    // =========================================================================
    // 6. Registered outputs
    // =========================================================================
    logic emit_eop_c;
    logic pay_short_c;

    // Short = the frame ended before the declared UDP length was satisfied.
    // That is a truncated packet: the payload we forwarded is incomplete.
    assign pay_short_c = (pay_cnt_q + (flush_emit_c ? {12'd0, pay_bytes_c}
                                                    : PAY_LEN_W'(0))) < pay_len_q;
    assign emit_eop_c  = flush_pend_q && accept_q && (sop_done_q || flush_emit_c);

    always_ff @(posedge clk) begin
        if (rst) begin
            m_pay_valid <= 1'b0;
            m_pay_sop   <= 1'b0;
            m_pay_eop   <= 1'b0;
            m_pay_err   <= 1'b0;
        end else begin
            m_pay_valid <= pay_emit_c || flush_emit_c;
            m_pay_sop   <= (pay_emit_c || flush_emit_c) && !sop_done_q;
            m_pay_eop   <= emit_eop_c;
            m_pay_err   <= emit_eop_c && (fcs_err_q || pay_short_c);
        end
    end

    always_ff @(posedge clk) begin
        m_pay_data  <= pay_data_c;
        m_pay_bytes <= pay_bytes_c;
        m_pay_t0    <= t0_q;
        m_pay_len   <= pay_len_q;
    end

    // =========================================================================
    // 7. Telemetry event pulses
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            evt_frame    <= 1'b0;
            evt_accept   <= 1'b0;
            evt_fcs_err  <= 1'b0;
            evt_hdr_drop <= '0;
        end else begin
            evt_frame   <= sof;
            evt_accept  <= hdr_verdict_c && accept_c;
            evt_fcs_err <= s_axis_tvalid && s_axis_tlast && s_axis_tuser;

            evt_hdr_drop <= '0;
            if (hdr_verdict_c && !accept_c) begin
                evt_hdr_drop <= drop_c;
            end else if (runt_c) begin
                // Frame too short to even contain the headers.
                evt_hdr_drop[HDR_DROP_LEN] <= 1'b1;
            end else if (flush_pend_q && accept_q &&
                         !(sop_done_q || flush_emit_c)) begin
                // Accepted, but not one payload byte ever materialised.
                evt_hdr_drop[HDR_DROP_LEN] <= 1'b1;
            end
        end
    end

    // =========================================================================
    // 8. Assertions — stream contract and parse invariants
    // =========================================================================
`ifndef SYNTHESIS
    // AXIS: tkeep must be non-zero on a valid beat, and full on a non-last
    // beat. A byte stream with holes would corrupt the realignment stitch.
    assert property (@(posedge clk) disable iff (rst)
        s_axis_tvalid |-> (s_axis_tkeep != '0)
    ) else $error("eth_ip_udp_rx: tvalid with tkeep == 0");

    assert property (@(posedge clk) disable iff (rst)
        (s_axis_tvalid && !s_axis_tlast) |-> (s_axis_tkeep == '1)
    ) else $error("eth_ip_udp_rx: partial tkeep on a non-last beat");

    // Every emitted payload word carries 1..8 bytes.
    assert property (@(posedge clk) disable iff (rst)
        m_pay_valid |-> ((m_pay_bytes != 4'd0) && (m_pay_bytes <= 4'd8))
    ) else $error("eth_ip_udp_rx: payload word with illegal byte count");

    assert property (@(posedge clk) disable iff (rst)
        m_pay_sop |-> m_pay_valid
    ) else $error("eth_ip_udp_rx: sop without valid");

    // ⚠️ THE hazard this module exists to prevent: a frame that is not the
    //    exact fast-path shape must never produce a payload byte.
    assert property (@(posedge clk) disable iff (rst)
        m_pay_valid |-> $past(accept_q)
    ) else $error("eth_ip_udp_rx: payload emitted from a frame that was not accepted");

    // Never emit more payload than UDP declared.
    assert property (@(posedge clk) disable iff (rst)
        (pay_emit_c || flush_emit_c) |->
            ((pay_cnt_q + {12'd0, pay_bytes_c}) <= pay_len_q)
    ) else $error("eth_ip_udp_rx: payload overrun past declared UDP length");

    // eop follows at least one payload word, and lands on the flush cycle.
    assert property (@(posedge clk) disable iff (rst)
        m_pay_eop |-> $past(flush_pend_q && (sop_done_q || flush_emit_c))
    ) else $error("eth_ip_udp_rx: eop with no preceding payload");

    // A dropped frame produces at least one reason bit. Silent drops are the
    // failure mode this whole project is built to eliminate (CLAUDE.md §5.7).
    assert property (@(posedge clk) disable iff (rst)
        (hdr_verdict_c && !accept_c) |=> (evt_hdr_drop != '0)
    ) else $error("eth_ip_udp_rx: frame dropped with no reason code");
`endif

endmodule : eth_ip_udp_rx

`default_nettype wire
