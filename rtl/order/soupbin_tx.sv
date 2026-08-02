// =============================================================================
// soupbin_tx.sv — SoupBinTCP session framing, outbound (client -> venue)
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/03-algotrading/04-order-entry-protocols.md §3
//           manuals/08-nasdaq/05-ouch-5.0-order-entry.md   (to be written)
//           ouch_pkg.sv §1 and §2
//
// -----------------------------------------------------------------------------
// PURPOSE
//   Wrap an OUCH message in a SoupBinTCP **Unsequenced Data** packet, and keep
//   the session alive with client heartbeats when the market is quiet.
//
//        byte 0      1      2      3 ..............................
//       ┌───────────────┬──────┬──────────────────────────────────┐
//       │ length (BE16) │ 'U'  │ OUCH message (length-1 bytes)     │
//       └───────────────┴──────┴──────────────────────────────────┘
//         = ouch_len + 1
//
//   That is the whole data path. Three bytes, one 16-bit add.
//
// -----------------------------------------------------------------------------
// ⚠️ SCOPE — WHAT THE FPGA OWNS AND, EMPHATICALLY, WHAT IT DOES NOT
//
//   THE FPGA OWNS EXACTLY TWO THINGS AT THIS LAYER:
//     1. Framing a steady-state Unsequenced Data packet around an OUCH message.
//     2. Emitting a Client Heartbeat when the link has been idle too long.
//
//   THE CPU OWNS EVERYTHING ELSE:
//     * Login Request  -> Login Accepted / Login Rejected. Including the
//       requested session ID and the requested sequence number, which is where
//       inbound recovery actually happens.
//     * Logout Request and clean session teardown.
//     * The INBOUND sequence number. Server->client is SEQUENCED; the host
//       tracks the count, detects gaps, and drives re-login with the right
//       "requested sequence number" to replay what was missed.
//     * End of Session ('Z') handling and end-of-day.
//     * Re-login after any disconnect, and the state resynchronisation that
//       MUST follow it (never trust local memory after a reconnect — see
//       manuals/03-algotrading/04-order-entry-protocols.md §8).
//
//   Why the split is drawn here: everything the CPU owns happens at most a few
//   times a day, involves ASCII decimal parsing and multi-second timeouts, and
//   is never on the critical path. Everything the FPGA owns happens on every
//   order. Putting a login state machine in fabric buys nothing and costs a
//   class of bug you cannot debug with tcpdump.
//
//   ⚠️ OUTBOUND IS UNSEQUENCED. There is no Soup-level acknowledgement of
//      anything we send and no Soup-level replay. If the connection dies with
//      bytes unacknowledged at the TCP layer, those orders are in an UNKNOWN
//      state and only the venue can say what happened. This is precisely why
//      tcp_tx_lite.sv must report every (seq, len, bytes) it emitted to the
//      host: that report is the ONLY record that the order left the building.
//
// -----------------------------------------------------------------------------
// ⚠️ HEARTBEAT POLICY
//   The heartbeat timer is reloaded by ANY transmission, order or heartbeat —
//   an order proves liveness just as well as a heartbeat does, and sending both
//   wastes a message-rate credit. If a heartbeat comes due in the same cycle as
//   an order, the ORDER WINS and the heartbeat is dropped (not queued), because
//   the order has already reset the timer. That event is still counted: a high
//   deferral count is normal in a busy market and suspicious in a quiet one.
//
//   The interval is host-configurable (cfg_hb_cycles) because the venue's
//   heartbeat timeout is a session parameter, not a constant. ⚠️ VERIFY the
//   required client heartbeat interval and the server's timeout for OUR ports.
//   Set the FPGA interval to roughly ONE THIRD of the venue's timeout so that
//   two consecutive losses do not drop the session.
//
//   ⚠️ Heartbeats stop the instant the session is not armed. A heartbeat sent
//      on a torn-down connection is a segment on a dead 4-tuple: at best it is
//      ignored, at worst it draws an RST that races the host's re-login.
//
// -----------------------------------------------------------------------------
// LATENCY  (156.25 MHz, 6.4 ns/cycle)
//   Prepend header + length add + registered output ......... 1 cycle,  6.4 ns
//   Contributes to the fpga_top.sv budget line "TCP/SoupBinTCP framing 1 cyc"
//   (this module is the SoupBinTCP half; tcp_tx_lite.sv overlaps the TCP half
//   with the first beat of frame emission, so the pair costs 1 cycle, not 2).
//   ACHIEVED: 1 cycle, fixed, initiation interval 1.
//
// RESOURCE ESTIMATE
//   ~560 FF (payload register + control), ~120 LUT, 0 BRAM, 0 DSP.
// =============================================================================
`default_nettype none

module soupbin_tx
    import trading_pkg::*;
    import ouch_pkg::*;
(
    input  var logic                          clk,
    input  var logic                          rst,

    // ── OUCH message in (from ouch_encoder) ──────────────────────────────────
    input  var logic [OUCH_IN_MAX_LEN*8-1:0]  s_msg,
    input  var logic [7:0]                    s_len,
    input  var csum_acc_t                     s_csum,     // UNFOLDED partial sum
    input  var logic                          s_valid,
    input  var logic                          s_is_cancel,

    // ── Session state (host owned, forwarded by order_gateway) ───────────────
    input  var logic                          session_armed,
    input  var logic                          cfg_hb_en,
    input  var logic [31:0]                   cfg_hb_cycles,  // core-clock cycles
    input  var logic                          tx_ready,       // TX path has a slot

    // ── SoupBinTCP packet out (TCP payload) ──────────────────────────────────
    output var logic [SOUP_PAY_MAX_BYTES*8-1:0] m_pay,
    output var logic [7:0]                    m_len,
    output var csum_acc_t                     m_csum,
    output var logic                          m_valid,
    output var logic                          m_is_hb,
    output var logic                          m_is_cancel,
    // 1-cycle pulse: an OUCH message arrived but was NOT framed (length error,
    // or the session went unarmed underneath it). Releases the gateway's TX
    // slot reservation. See order_gateway.sv.
    output var logic                          m_refuse,
    // COMBINATIONAL, deliberately: the gateway must reserve the TX slot in the
    // SAME cycle the heartbeat is decided, otherwise an order accepted in the
    // intervening cycle could over-subscribe the frame buffer. This is the
    // documented exception to "registered outputs by default"
    // (manuals/00-foundations/03-hdl-and-rtl-coding.md §5): it is a 1-bit
    // control flag derived from registered state, not a datapath output.
    output var logic                          m_hb_fire,

    output var logic [31:0]                   stat [4]
);

    // Largest SoupBinTCP packet the fast path ever builds.
    localparam int unsigned PAY_BITS = SOUP_PAY_MAX_BYTES * 8;

    // =========================================================================
    // Packet construction
    // =========================================================================
    // ⚠️ SOUP_LEN_BIAS (= 1) is the "does the length count the type byte?"
    //    question from ouch_pkg V1. It is a named constant precisely so that a
    //    spec correction is a one-line edit and not an archaeology exercise.
    logic [15:0]         soup_len;
    logic [7:0]          pkt_bytes;
    logic [PAY_BITS-1:0] data_pay;
    logic [PAY_BITS-1:0] hb_pay;
    csum_acc_t           data_csum;
    csum_acc_t           hb_csum;
    logic                len_err;

    always_comb begin
        soup_len  = {8'd0, s_len} + 16'(SOUP_LEN_BIAS);
        pkt_bytes = s_len + 8'(SOUP_HDR_LEN);
        len_err   = s_valid && ((s_len == 8'd0) ||
                                (pkt_bytes > 8'(SOUP_PAY_MAX_BYTES)));

        // ---- Unsequenced Data packet ----------------------------------------
        data_pay = '0;
        data_pay[8*SOUP_LEN_OFF       +: 8] = soup_len[15:8];   // big-endian
        data_pay[8*(SOUP_LEN_OFF + 1) +: 8] = soup_len[7:0];
        data_pay[8*SOUP_TYPE_OFF      +: 8] = SOUP_UNSEQ_DATA;
        data_pay[8*SOUP_HDR_LEN +: OUCH_IN_MAX_LEN*8] = s_msg;

        // ---- Client Heartbeat packet: header only, length = 1 ---------------
        hb_pay = '0;
        hb_pay[8*SOUP_LEN_OFF       +: 8] = 8'(SOUP_LEN_BIAS >> 8);
        hb_pay[8*(SOUP_LEN_OFF + 1) +: 8] = 8'(SOUP_LEN_BIAS);
        hb_pay[8*SOUP_TYPE_OFF      +: 8] = SOUP_CLIENT_HEARTBEAT;
    end

    // ---- Checksum contribution of the three header bytes --------------------
    // ⚠️ These are offsets 0, 1 and 2 of the TCP PAYLOAD, which is exactly the
    //    parity basis every other stage uses. csum_byte_at() owns the even/odd
    //    rule; nothing in this file duplicates it. See ouch_pkg §9.
    always_comb begin
        data_csum = s_csum
                  + {{(CSUM_ACC_W-16){1'b0}}, csum_byte_at(SOUP_LEN_OFF,     soup_len[15:8])}
                  + {{(CSUM_ACC_W-16){1'b0}}, csum_byte_at(SOUP_LEN_OFF + 1, soup_len[7:0])}
                  + {{(CSUM_ACC_W-16){1'b0}}, csum_byte_at(SOUP_TYPE_OFF,    SOUP_UNSEQ_DATA)};

        hb_csum   = {{(CSUM_ACC_W-16){1'b0}}, csum_byte_at(SOUP_LEN_OFF,     8'(SOUP_LEN_BIAS >> 8))}
                  + {{(CSUM_ACC_W-16){1'b0}}, csum_byte_at(SOUP_LEN_OFF + 1, 8'(SOUP_LEN_BIAS))}
                  + {{(CSUM_ACC_W-16){1'b0}}, csum_byte_at(SOUP_TYPE_OFF,    SOUP_CLIENT_HEARTBEAT)};
    end

    // =========================================================================
    // Heartbeat timer
    // =========================================================================
    // Down-counter, reloaded by any transmission. A zero interval or a cleared
    // enable disables heartbeats entirely (the host may prefer to own them
    // while it is doing its own session work).
    logic [31:0] hb_cnt;
    logic        hb_due;
    logic        hb_go;
    logic        data_go;

    assign hb_due  = cfg_hb_en && session_armed && (cfg_hb_cycles != 32'd0)
                  && (hb_cnt == 32'd0);
    assign data_go = s_valid && session_armed && !len_err;
    // The order wins. It has already reloaded the timer, so the heartbeat is
    // dropped rather than queued — see the heartbeat policy note in the header.
    assign hb_go   = hb_due && !data_go && tx_ready;
    assign m_hb_fire = hb_go;

    always_ff @(posedge clk) begin
        if (rst) begin
            hb_cnt <= 32'd0;
        end else if (data_go || hb_go || !session_armed || (cfg_hb_cycles == 32'd0)) begin
            hb_cnt <= cfg_hb_cycles;
        end else if (hb_cnt != 32'd0) begin
            hb_cnt <= hb_cnt - 32'd1;
        end
    end

    // =========================================================================
    // Registered outputs
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            m_valid     <= 1'b0;
            m_is_hb     <= 1'b0;
            m_is_cancel <= 1'b0;
            m_refuse    <= 1'b0;
        end else begin
            m_valid     <= data_go || hb_go;
            m_is_hb     <= hb_go && !data_go;
            m_is_cancel <= data_go && s_is_cancel;
            m_refuse    <= s_valid && !data_go;
        end
        m_pay  <= data_go ? data_pay  : hb_pay;
        m_len  <= data_go ? pkt_bytes : 8'(SOUP_HDR_LEN);
        m_csum <= data_go ? data_csum : hb_csum;
    end

    // =========================================================================
    // Counters
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 4; i++) stat[i] <= 32'd0;
        end else begin
            if (data_go)                     stat[0] <= stat[0] + 32'd1;
            if (hb_go)                       stat[1] <= stat[1] + 32'd1;
            if (hb_due && (data_go || !tx_ready)) stat[2] <= stat[2] + 32'd1;
            if (len_err)                     stat[3] <= stat[3] + 32'd1;
            // ⚠️ An order arriving while the session is NOT armed is a lost
            //    order. It is counted at the gateway (drop_not_armed); this
            //    module simply refuses to frame it.
        end
    end

    // =========================================================================
    // Assertions
    // =========================================================================
`ifndef SYNTHESIS
    // Stream contract: exactly one packet out per accepted request, next cycle.
    assert property (@(posedge clk) disable iff (rst)
        data_go |=> (m_valid && !m_is_hb)
    ) else $error("soupbin_tx: accepted OUCH message did not produce a packet");

    // A heartbeat and a data packet must never be framed in the same cycle.
    assert property (@(posedge clk) disable iff (rst)
        !(data_go && hb_go)
    ) else $error("soupbin_tx: heartbeat and data collided");

    // The Soup length field must describe the packet we actually emit.
    assert property (@(posedge clk) disable iff (rst)
        (m_valid && !m_is_hb) |->
            ({8'd0, m_len} == ({m_pay[8*SOUP_LEN_OFF +: 8], m_pay[8*(SOUP_LEN_OFF+1) +: 8]}
                               - 16'(SOUP_LEN_BIAS) + 16'(SOUP_HDR_LEN)))
    ) else $error("soupbin_tx: Soup length field disagrees with the packet length");

    // Nothing may be framed while the session is not armed.
    assert property (@(posedge clk) disable iff (rst)
        !session_armed |=> !m_valid
    ) else $error("soupbin_tx: packet framed on an unarmed session");

    initial begin
        if (SOUP_PAY_MAX_BYTES < (SOUP_HDR_LEN + OUCH_IN_MAX_LEN))
            $fatal(1, "soupbin_tx: SOUP_PAY_MAX_BYTES too small for the OUCH row");
    end
`endif

endmodule : soupbin_tx

`default_nettype wire
