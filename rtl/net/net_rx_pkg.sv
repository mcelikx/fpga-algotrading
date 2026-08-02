// =============================================================================
// net_rx_pkg.sv — Protocol constants and types for the network receive layer
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Layer   : rtl/net/  (MAC RX  ->  deduplicated in-order ITCH message stream)
// Governs : manuals/02-networking/02-ip-udp-tcp-in-hardware.md
//           manuals/02-networking/03-multicast-feeds-and-arbitration.md
//           manuals/04-system-architecture/02-feed-handler-design.md
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   Every protocol byte offset used by this layer lives here, exactly once.
//   Scattering `14`, `34`, `42` through the RTL is how a header parser ends up
//   four bytes off in production while passing every test in the lab.
//
//   MoldUDP64 framing constants are NOT duplicated here — they live in
//   itch_pkg (MOLD_*) and this layer imports them. One source per protocol.
//
// ⚠️ THE BEAT-WIDTH ASSUMPTION
//   trading_pkg::AXIS_W = 64 (8 bytes/beat, 10GbE @ 156.25 MHz). The (beat,lane)
//   localparams derived below are computed from the byte offsets, so a width
//   change is a compile-time recomputation — but eth_ip_udp_rx also hand-codes
//   the ONE header field that straddles a beat boundary at 64-bit width (the
//   IPv4 destination address, bytes 30..33). That module carries an elaboration
//   guard; do not silently reparameterize the bus without revisiting it.
//
//   NOTE ON THE MANUALS: manuals/02-networking/02 and /03 describe the header
//   parse against a 512-bit ingress bus ("all of this lands in beat 0"). The
//   PORT CONTRACT in rtl/fpga_top.sv is 64-bit (trading_pkg::AXIS_W), and the
//   contract wins. See rtl/net/README.md §"Beat width" for the reconciliation.
// =============================================================================
`ifndef NET_RX_PKG_SV
`define NET_RX_PKG_SV

// This package documents the COMPLETE header layout, not only the fields the
// current fast path happens to read. An offset that is present and named is an
// offset nobody re-derives by hand later — which is the entire point of the
// file. Unused-parameter warnings on the documentation constants are expected.
/* verilator lint_off UNUSEDPARAM */
package net_rx_pkg;

    // -------------------------------------------------------------------------
    // 1. Ethernet II header (post preamble/SFD, post FCS strip — what the MAC
    //    hands us). Byte offsets are from the first byte of the frame.
    // > Verify: IEEE 802.3 §3.1. Stable since 1985; low risk.
    // -------------------------------------------------------------------------
    parameter int unsigned ETH_DST_MAC_OFF = 0;
    parameter int unsigned ETH_SRC_MAC_OFF = 6;
    parameter int unsigned ETH_TYPE_OFF    = 12;
    parameter int unsigned ETH_HDR_LEN     = 14;

    parameter logic [15:0] ETYPE_IPV4      = 16'h0800;
    parameter logic [15:0] ETYPE_ARP       = 16'h0806;
    parameter logic [15:0] ETYPE_VLAN      = 16'h8100;   // 802.1Q  — shifts +4
    parameter logic [15:0] ETYPE_QINQ      = 16'h88A8;   // 802.1ad — shifts +8
    parameter logic [15:0] ETYPE_QINQ_ALT  = 16'h9100;   // legacy QinQ TPID
    parameter logic [15:0] ETYPE_IPV6      = 16'h86DD;

    // -------------------------------------------------------------------------
    // 2. IPv4 header (base = ETH_HDR_LEN). Fast path assumes IHL == 5.
    // > Verify: RFC 791.
    // -------------------------------------------------------------------------
    parameter int unsigned IP_OFF          = ETH_HDR_LEN;          // 14
    parameter int unsigned IP_VER_IHL_OFF  = IP_OFF + 0;           // 14
    parameter int unsigned IP_DSCP_OFF     = IP_OFF + 1;           // 15
    parameter int unsigned IP_TOTLEN_OFF   = IP_OFF + 2;           // 16
    parameter int unsigned IP_ID_OFF       = IP_OFF + 4;           // 18
    parameter int unsigned IP_FRAGOFF_OFF  = IP_OFF + 6;           // 20
    parameter int unsigned IP_TTL_OFF      = IP_OFF + 8;           // 22
    parameter int unsigned IP_PROTO_OFF    = IP_OFF + 9;           // 23
    parameter int unsigned IP_CSUM_OFF     = IP_OFF + 10;          // 24
    parameter int unsigned IP_SRC_OFF      = IP_OFF + 12;          // 26
    parameter int unsigned IP_DST_OFF      = IP_OFF + 16;          // 30
    parameter int unsigned IP_HDR_LEN      = 20;                   // IHL == 5
    parameter int unsigned IP_HDR_WORDS16  = IP_HDR_LEN / 2;       // 10

    // The ONLY accepted first header byte: version 4, IHL 5 (no options).
    parameter logic [7:0]  IP_VER_IHL_OK   = 8'h45;
    parameter logic [7:0]  IP_PROTO_UDP    = 8'd17;
    parameter logic [7:0]  IP_PROTO_TCP    = 8'd6;

    // Flags/fragment-offset word: bit 15 reserved, bit 14 DF, bit 13 MF,
    // bits 12:0 fragment offset. DF is allowed; MF or a non-zero offset is not.
    parameter int unsigned IP_FLAG_MF_BIT  = 13;
    parameter int unsigned IP_FLAG_DF_BIT  = 14;

    // A valid IPv4 header summed as ten 16-bit ones'-complement words
    // (checksum field included) folds to this constant. See 02.02 §3.
    parameter logic [15:0] IP_CSUM_RESIDUE = 16'hFFFF;

    // -------------------------------------------------------------------------
    // 3. UDP header (base = IP_OFF + IP_HDR_LEN).
    // > Verify: RFC 768.
    // -------------------------------------------------------------------------
    parameter int unsigned UDP_OFF         = IP_OFF + IP_HDR_LEN;  // 34
    parameter int unsigned UDP_SPORT_OFF   = UDP_OFF + 0;          // 34
    parameter int unsigned UDP_DPORT_OFF   = UDP_OFF + 2;          // 36
    parameter int unsigned UDP_LEN_OFF     = UDP_OFF + 4;          // 38
    parameter int unsigned UDP_CSUM_OFF    = UDP_OFF + 6;          // 40
    parameter int unsigned UDP_HDR_LEN     = 8;

    // First byte of the UDP payload == first byte of the MoldUDP64 header.
    parameter int unsigned PAYLOAD_OFF     = UDP_OFF + UDP_HDR_LEN; // 42

    // Smallest UDP length we will look at: 8 (UDP header) + 20 (Mold header).
    // A packet shorter than this cannot carry a sequence number.
    parameter int unsigned UDP_LEN_MIN     = UDP_HDR_LEN + 20;     // 28

    // Largest UDP payload we will accept: MTU 1500 minus IP+UDP headers.
    // Jumbo frames are a configuration error on a trading link (02.01 §8).
    parameter int unsigned MTU_BYTES       = 1500;
    parameter int unsigned PAY_MAX_BYTES   = MTU_BYTES - IP_HDR_LEN - UDP_HDR_LEN; // 1472
    parameter int unsigned PAY_LEN_W       = 16;

    // -------------------------------------------------------------------------
    // 4. Feed match table (the multicast filter)
    // -------------------------------------------------------------------------
    // Feed identity is (destination IP, destination UDP port) — never the MAC
    // address (02.02 §8 rule 4). One record per subscribed group. A packet that
    // matches no enabled record is dropped and counted before it can reach the
    // deframer; foreign traffic must never touch the sequencer.
    typedef struct packed {
        logic        en;         // record is live
        logic [31:0] dst_ip;     // network order, MSB-first as on the wire
        logic [15:0] dst_port;
    } match_rec_t;

    // -------------------------------------------------------------------------
    // 5. Drop / error reason codes
    // -------------------------------------------------------------------------
    // ⚠️ "packets dropped" with no reason code is useless at 09:31 on a bad
    //    morning (02.02 §2). Each reason is a distinct bit; the reason mask is
    //    latched sticky and published alongside the aggregate count.

    parameter int unsigned N_HDR_DROP = 8;
    typedef enum logic [2:0] {
        HDR_DROP_NOT_IPV4 = 3'd0,  // EtherType is not 0x0800 (and not VLAN)
        HDR_DROP_VLAN     = 3'd1,  // 802.1Q / QinQ — every offset shifts
        HDR_DROP_OPTIONS  = 3'd2,  // IHL > 5 — UDP header moved
        HDR_DROP_FRAG     = 3'd3,  // MF set or fragment offset != 0
        HDR_DROP_PROTO    = 3'd4,  // IP protocol is not UDP
        HDR_DROP_IPCSUM   = 3'd5,  // IPv4 header checksum failed
        HDR_DROP_NOMATCH  = 3'd6,  // not one of our (dst IP, dst port) groups
        HDR_DROP_LEN      = 3'd7   // runt frame, or UDP length inconsistent
    } hdr_drop_e;

    parameter int unsigned N_MOLD_EVT = 8;
    typedef enum logic [2:0] {
        MOLD_EVT_TRUNC    = 3'd0,  // packet ended mid-message block
        MOLD_EVT_BLKLEN   = 3'd1,  // block length 0, or > ITCH_MSG_MAX_BYTES
        MOLD_EVT_ITCHLEN  = 3'd2,  // block length != itch_msg_len(type)
        MOLD_EVT_UNKTYPE  = 3'd3,  // unknown ITCH type (NOT an error — counted)
        MOLD_EVT_TRAILING = 3'd4,  // bytes left over after MessageCount blocks
        MOLD_EVT_SESSION  = 3'd5,  // MoldUDP64 session ID changed
        MOLD_EVT_ENDSESS  = 3'd6,  // MessageCount == 0xFFFF, end of session
        MOLD_EVT_OVERRUN  = 3'd7   // new packet arrived before the last drained
                                   // ⚠️ DESIGN INVARIANT — must always read 0
    } mold_evt_e;

    // -------------------------------------------------------------------------
    // 6. MoldUDP64 deframer state
    // -------------------------------------------------------------------------
    // MOLD_S_HDR   — collecting the 20-byte packet header at fixed offsets
    // MOLD_S_BODY  — walking the length-prefixed message blocks, II = 1
    // MOLD_S_DRAIN — all MessageCount blocks emitted; swallow the tail
    // MOLD_S_ABORT — malformed: abandon the rest of the packet and poison it.
    //                ⚠️ A length error must abandon the WHOLE remaining packet,
    //                never just one message: once the read pointer is wrong,
    //                every following block decodes from the wrong offset and
    //                arbitrary bytes are a plausible ITCH type ~1 time in 10.
    //                (04.02 §6.2)
    typedef enum logic [2:0] {
        MOLD_S_IDLE  = 3'd0,
        MOLD_S_HDR   = 3'd1,
        MOLD_S_BODY  = 3'd2,
        MOLD_S_DRAIN = 3'd3,
        MOLD_S_ABORT = 3'd4
    } mold_state_e;

    // -------------------------------------------------------------------------
    // 7. net_rx_path stat[] index map (see net_rx_path.sv header for encodings)
    // -------------------------------------------------------------------------
    parameter int unsigned STAT_RX_FRAMES  = 0;
    parameter int unsigned STAT_DROP_HDR   = 1;
    parameter int unsigned STAT_MOLD_EVT   = 2;
    parameter int unsigned STAT_DROP_FCS   = 3;
    parameter int unsigned STAT_MSGS_OUT   = 4;
    parameter int unsigned STAT_DEDUPE     = 5;
    parameter int unsigned STAT_FEED_WINS  = 6;
    parameter int unsigned STAT_GAP        = 7;
    parameter int unsigned N_NET_STAT      = 8;

    // -------------------------------------------------------------------------
    // 8. Helpers
    // -------------------------------------------------------------------------
    // Big-endian 16-bit field at byte lane `lane` of a 64-bit beat.
    // Convention (02.02 §1): beat[8*n +: 8] is the n-th byte received.
    // Always called with a compile-time constant lane, so this is pure wiring.
    function automatic logic [15:0] be16_lane(input logic [63:0] beat,
                                              input int unsigned lane);
        return {beat[8*lane +: 8], beat[8*(lane+1) +: 8]};
    endfunction

    function automatic logic [7:0] byte_lane(input logic [63:0] beat,
                                             input int unsigned lane);
        return beat[8*lane +: 8];
    endfunction

    // Number of valid bytes in a contiguous AXI-Stream tkeep (8-bit).
    // Contiguity is an AXIS requirement for a byte stream; asserted at the port.
    function automatic logic [3:0] keep_bytes8(input logic [7:0] keep);
        logic [3:0] n;
        n = 4'd0;
        for (int unsigned i = 0; i < 8; i++) begin
            n = n + 4'(keep[i]);
        end
        return n;
    endfunction

    // Ones'-complement fold of a wide accumulator down to 16 bits.
    // Two folds always suffice for accumulators up to 32 bits.
    function automatic logic [15:0] csum_fold(input logic [31:0] acc);
        logic [16:0] f0;
        logic [16:0] f1;
        f0 = {1'b0, acc[15:0]} + {1'b0, acc[31:16]};
        f1 = {1'b0, f0[15:0]}  + {16'd0, f0[16]};
        // The third carry is unreachable for a 10-word IPv4 header, but folding
        // it costs one LUT and removes a corner case from the argument.
        return f1[15:0] + {15'd0, f1[16]};
    endfunction

    // Saturating counters. CLAUDE.md §5.7: every drop is counted, and a wrapped
    // counter is a counter that lies. Saturate, never wrap.
    function automatic logic [31:0] sat_inc32(input logic [31:0] c,
                                              input logic        en);
        return (!en || (c == 32'hFFFF_FFFF)) ? c : (c + 32'd1);
    endfunction

    function automatic logic [23:0] sat_inc24(input logic [23:0] c,
                                              input logic        en);
        return (!en || (c == 24'hFF_FFFF)) ? c : (c + 24'd1);
    endfunction

    function automatic logic [15:0] sat_inc16(input logic [15:0] c,
                                              input logic        en);
        return (!en || (c == 16'hFFFF)) ? c : (c + 16'd1);
    endfunction

endpackage : net_rx_pkg
/* verilator lint_on UNUSEDPARAM */

`endif
