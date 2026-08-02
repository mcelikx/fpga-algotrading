// =============================================================================
// order_gateway.sv — Order entry layer: OUCH encode -> SoupBinTCP -> TCP -> MAC
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Parent  : rtl/fpga_top.sv  (instance u_order_gw — THIS PORT LIST IS A CONTRACT)
// Governs : manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md
//           manuals/03-algotrading/04-order-entry-protocols.md
//           manuals/02-networking/02-ip-udp-tcp-in-hardware.md §6
//           manuals/01-fpga-design/02-pipelining-and-parallelism.md §4
//
// -----------------------------------------------------------------------------
// THE PIPELINE
//
//   risk_gate                                                              MAC
//   ─────────┐                                                          ┌───────
//   order_out│                                                          │ TX
//            ▼                                                          ▲
//   ┌────────────────┐   ┌─────────────┐   ┌──────────────────────┐     │
//   │ ouch_encoder   │──►│ soupbin_tx  │──►│ tcp_tx_lite          │─────┘
//   │ template BRAM  │   │ 'U' framing │   │ Eth/IP/TCP template  │
//   │ + 24-byte      │   │ + heartbeat │   │ + incremental csum   │
//   │   splice       │   │             │   │ + snd_nxt            │
//   │ 2 cyc          │   │ 1 cyc       │   │ 1 cyc to first beat  │
//   └────────────────┘   └─────────────┘   └──────────────────────┘
//         │                                          ▲
//         │ credit consume                 snoop{seq,ack,win,FIN,RST}
//         ▼                                          │
//   ┌────────────────┐                     ┌──────────────────────┐   MAC RX
//   │ credit_mgr     │◄────credit return───│ ouch_rx              │◄──────────
//   │ MAX_IN_FLIGHT  │                     │ Soup/OUCH parse      │
//   └────────────────┘                     │ token decode, fills  │
//         │ credit_avail                   └──────────────────────┘
//         ▼ (to risk_gate)                          │ fill_{sym,side,qty,px}
//                                                   ▼ (to strategy + risk)
//
// -----------------------------------------------------------------------------
// LATENCY BUDGET — BUDGETED vs ACHIEVED (156.25 MHz, 6.4 ns/cycle)
//
//   fpga_top.sv owns these two budget lines:
//     "OUCH template read + splice + checksum   2 cyc  12.8 ns"
//     "TCP/SoupBinTCP framing                   1 cyc   6.4 ns"
//                                        TOTAL  3 cyc  19.2 ns
//
//   ACHIEVED, from s_out_valid to the first beat on m_axis_tdata:
//     ouch_encoder   template read + splice + checksum delta ....  2 cyc
//     soupbin_tx     'U' framing, 3-byte prepend ................  1 cyc
//     tcp_tx_lite    header patch + checksum + first beat .......  1 cyc
//                                                        TOTAL     4 cyc  25.6 ns
//
//   ⚠️ THIS IS ONE CYCLE (6.4 ns) OVER THE fpga_top BUDGET. Reported, not
//      hidden. The budget line treats framing as a single stage; the
//      implementation splits it into two registered stages because
//      soupbin_tx.sv follows the project default of registered outputs
//      (manuals/00-foundations/03-hdl-and-rtl-coding.md §5). Effect on the
//      top-level table: fabric total 20 -> 21 cycles, 128.0 -> 134.4 ns;
//      wire-to-wire target ~321 -> ~327 ns. Still inside the < 1 us budget and
//      inside the < 500 ns stretch goal.
//
//      TO RECOVER THE CYCLE: make soupbin_tx's outputs combinational. Its data
//      path is a 3-byte prepend (pure wiring) plus one 16-bit add, so the
//      logic cost of merging it into tcp_tx_lite's accept stage is ~0.5 ns
//      against 6.4 ns saved. Do it with a post-P&R timing report in hand
//      (CLAUDE.md §7), not speculatively — tcp_tx_lite's accept stage already
//      carries the header build, both checksum folds and a 1024-bit register
//      load, and it is the more likely of the two to be the Fmax limiter.
//
//   ⚠️ SERIALISATION IS NOT LATENCY. A 106-byte order frame is 14 beats on the
//      64-bit MAC bus = 89.6 ns of BUS OCCUPANCY. With a cut-through MAC the
//      first byte is on the wire long before the last beat is read out. The
//      budget above is time-to-first-beat. Do not add 89.6 ns to it, and do not
//      quote 89.6 ns as a latency in any report.
//
//   RX (feedback path, not budgeted): header validation completes 7 beats after
//   start-of-frame; a fill emerges roughly (payload offset) cycles later.
//   ~45 cycles / ~290 ns for a typical Executed. See ouch_rx.sv.
//
// -----------------------------------------------------------------------------
// ⚠️ THE KILL SWITCH IS GATED HERE **AS WELL AS** IN THE RISK GATE.
//     THIS REDUNDANCY IS DELIBERATE. IT IS NOT AN OVERSIGHT. DO NOT "TIDY" IT.
//
//   risk_gate.sv already blocks order_out_valid when kill_active is asserted,
//   within KILL_RESP_CYCLES, and fpga_top.sv asserts that property. So the
//   check in this module is, structurally, unreachable.
//
//   It is here anyway, and there are two more like it (tcp_tx_lite.sv gates the
//   frame accept, and the session arm bit gates it again), because:
//
//     1. A kill switch that depends on ONE correct block is a kill switch with
//        a single point of failure. The failure modes it must survive include a
//        stuck-at fault, a corrupted risk-parameter BRAM, a partial-reconfig
//        accident, and an RTL bug introduced by someone who has never read this
//        comment. CLAUDE.md §5.6 says the kill switch is hardware-enforced;
//        enforcing it once is not enforcing it.
//     2. Defence in depth is cheap here. Each gate is one AND term on a path
//        that is not the Fmax limiter. The cost is a LUT input. The thing it
//        protects against is an unbounded loss.
//     3. It makes the property locally provable. Each block asserts its own
//        gate, so a reviewer reading tcp_tx_lite.sv alone can verify that
//        nothing leaves the chip during a kill without also having to reason
//        about risk_gate.sv.
//
//   ⚠️ WHAT THE KILL SWITCH DOES **NOT** DO: it does not truncate a frame that
//      is already streaming. Cutting a TCP segment in half would desynchronise
//      the venue's byte stream and destroy the session — strictly worse than
//      letting one already-risk-approved order finish. The bound is therefore:
//
//        new orders blocked ............................. same cycle
//        last in-flight frame drains ................... <= 16 beats = 102.4 ns
//
//      (TX_FRAME_MAX_BEATS beats, plus MAC backpressure if any.) fpga_top's
//      KILL_RESP_CYCLES = 4 assertion applies to order_out_valid at the risk
//      gate, which this module honours immediately; the drain is downstream of
//      that boundary and is documented here rather than hidden.
//
// -----------------------------------------------------------------------------
// FLOW CONTROL — why there is no s_out_ready
//
//   The fpga_top contract gives this block NO backpressure path to the risk
//   gate: `s_out` / `s_out_valid` only. That is correct (CLAUDE.md §5.4 in
//   spirit: the fast path does not stall), but it means the gateway must be
//   able to accept or REFUSE, never block.
//
//   The chain is a fixed-latency, non-stalling pipeline: an order accepted at
//   cycle N reaches tcp_tx_lite at cycle N+3, unconditionally. So the gateway
//   RESERVES a frame-buffer slot at accept time. `tx_occ` counts reservations;
//   an order is accepted only if a slot is free. A slot is released by a
//   completed frame OR by a refusal anywhere downstream (each block emits a
//   refuse pulse) so a refusal can never leak a reservation and wedge the path.
//
//   ⚠️ IF A SLOT IS NOT FREE, THE ORDER IS DROPPED AND COUNTED (stat[4]).
//      A DROPPED ORDER IS THE MOST SERIOUS COUNTER IN THIS BLOCK. The strategy
//      believes it has an order working; it does not. That counter must page
//      someone, not appear on a dashboard. It should be structurally impossible
//      — the risk gate's message-rate limiter runs far below one order per 14
//      cycles — which is exactly why a non-zero value means something is wrong
//      in a way nobody predicted.
//
// -----------------------------------------------------------------------------
// stat[16] MAP — read by u_telemetry, exposed to the host as order_stat[]
//
//   idx  name                 kind      source                      alarm?
//   ---  -------------------  --------  --------------------------  ------------
//    0   tx_enter_orders      counter   ouch_encoder                rate
//    1   tx_cancels           counter   ouch_encoder                rate
//    2   tx_frames            counter   tcp_tx_lite                 rate
//    3   tx_heartbeats        counter   soupbin_tx                  steady
//    4   tx_dropped           counter   refusals + no TX slot       ⚠️ PAGE
//    5   tx_blocked           counter   kill/session/window/credit  expected
//    6   status_word          LIVE      packed, see below           ⚠️ flags
//    7   tcp_snd_nxt          LIVE      tcp_tx_lite                 reconcile
//    8   rx_frames_ok         counter   ouch_rx                     rate
//    9   rx_frames_dropped    counter   reject + overflow + dup     ⚠️ investigate
//   10   rx_accepted          counter   ouch_rx histogram           rate
//   11   rx_executed          counter   ouch_rx histogram           rate
//   12   rx_canceled          counter   Canceled + AIQ Canceled     rate
//   13   rx_rejected          counter   Rejected + Cancel Reject    ⚠️ PAGE ON SPIKE
//   14   tcp_snd_una          LIVE      tcp_tx_lite                 reconcile
//   15   rx_bad               counter   desync/stale/malformed/unk  ⚠️ MUST BE ZERO
//
//   stat[6], the packed status word — what is happening RIGHT NOW:
//     [31:16] longest credit-starvation run, cycles, saturating
//     [15:13] TX slot reservations in flight (0..TX_DEPTH)
//     [12: 6] orders in flight (credit_mgr)
//     [5]     credit starvation alarm (sticky)      ⚠️
//     [4]     TX path idle
//     [3]     RX byte stream desynchronised         ⚠️ trading stopped
//     [2]     inbound-silence watchdog tripped      ⚠️ trading stopped
//     [1]     hardware disarm (FIN/RST seen)        ⚠️ trading stopped
//     [0]     session armed
//
//   ⚠️ THREE OF THE SIXTEEN SLOTS ARE NOT COUNTERS (6, 7, 14). Anything that
//      graphs order_stat[] as a monotonic rate must special-case them.
//
//   ⚠️ WHY stat[13] IS A PAGE, NOT A GRAPH. A burst of rejects means the venue
//      is refusing our orders. Every rejected order is a strategy that believes
//      it has a position it does not have, and the usual causes (a bad
//      template, a stale session, a breached venue-side limit, a symbol we are
//      not entitled to trade) all get worse the longer they run.
//
//   ⚠️ COUNTER BUDGET SHORTFALL. This layer produces ~44 distinct counters; the
//      fpga_top contract publishes 16, and three of those are spent on live
//      state that has no other exposure path. Slots 4, 5, 9 and 15 are each a
//      registered SUM of several distinct reasons, which violates the spirit of
//      "a distinct counter per reason" (CLAUDE.md §5.7 /
//      manuals/02-networking/02-*.md §2). The sub-counters exist in RTL and are
//      ILA-visible; they are not host-readable. See README open item OI-2 —
//      this is a gap in the top-level contract, not a design preference.
//
// -----------------------------------------------------------------------------
// RESOURCE ESTIMATE (target, UltraScale+, one SLR — keep the whole block in one)
//   LUT  ~4.0k   FF ~6.5k   BRAM ~11 (10 template + 1 RX FIFO)   DSP 0
// =============================================================================
`default_nettype none

module order_gateway
    import trading_pkg::*;
    import ouch_pkg::*;
#(
    // Must match between ouch_encoder and ouch_rx: the token wire rendering.
    // ⚠️ See ouch_pkg §8 / VERIFY item V10 before changing this.
    parameter bit          TOKEN_ASCII_HEX  = 1'b1,
    parameter bit          CREDIT_RETURN_ON_EXEC = 1'b1,
    // Frame-buffer slots reserved at accept time. Must equal tcp_tx_lite's
    // FBUF_DEPTH — the reservation scheme is what makes overflow impossible.
    parameter int unsigned TX_DEPTH         = 2,
    parameter int unsigned RXFIFO_BEATS     = 512,
    parameter int unsigned STARVE_ALARM_CYC = 156250
) (
    input  var logic                    clk,
    input  var logic                    rst,
    input  var cycle_t                  cycle_cnt,

    // ── Risk-approved order in (no backpressure path — see the header) ───────
    input  var order_out_t              s_out,
    input  var logic                    s_out_valid,

    // ── MAC TX ───────────────────────────────────────────────────────────────
    output var logic [AXIS_W-1:0]       m_axis_tdata,
    output var logic [AXIS_KEEP_W-1:0]  m_axis_tkeep,
    output var logic                    m_axis_tvalid,
    output var logic                    m_axis_tlast,
    input  var logic                    m_axis_tready,

    // ── MAC RX (acks, fills, rejects) — NEVER backpressured ──────────────────
    input  var logic [AXIS_W-1:0]       s_axis_tdata,
    input  var logic [AXIS_KEEP_W-1:0]  s_axis_tkeep,
    input  var logic                    s_axis_tvalid,
    input  var logic                    s_axis_tlast,
    input  var logic                    s_axis_tuser,

    // ── Decoded fills back to strategy and risk ──────────────────────────────
    output var logic                    fill_valid,
    output var sym_idx_t                fill_sym,
    output var side_e                   fill_side,
    output var qty_t                    fill_qty,
    output var price_t                  fill_px,

    // ── In-flight credit ─────────────────────────────────────────────────────
    output var logic                    credit_avail,
    input  var logic                    credit_return,

    // ── Kill switch (defence in depth — see the header) ──────────────────────
    input  var logic                    kill_active,

    // ── Host-owned session state: templates, TCP 5-tuple, sequence numbers ───
    input  var logic                    cfg_tmpl_wr,
    input  var logic [15:0]             cfg_tmpl_addr,
    input  var logic [31:0]             cfg_tmpl_data,
    input  var logic                    cfg_session_wr,
    input  var logic [31:0]             cfg_session_data,

    output var logic [31:0]             stat [16]
);

    // =========================================================================
    // Host session record decode
    // -------------------------------------------------------------------------
    // ⚠️ cfg_session_* is a WRITE-DATA PORT WITH NO ADDRESS. The record is
    //    therefore a fixed 16-word burst into an auto-incrementing pointer,
    //    with SESSION_MAGIC as a resynchronisation escape (ouch_pkg §11).
    //    Writing word SW_COMMIT latches the shadow into the live registers, so
    //    a half-written record can never be used.
    //
    // ⚠️ HOST CONSTRAINT (repeated because it will otherwise be forgotten): no
    //    word of the record other than word 0 may equal SESSION_MAGIC. A magic
    //    seen at a non-zero pointer is treated as "the host restarted a record"
    //    and is counted, not silently accepted.
    // =========================================================================
    logic [31:0]              sh [SESSION_WORDS];
    logic [3:0]               sw_ptr;
    logic                     sess_commit;
    logic                     sess_magic_mid;

    always_comb begin
        sess_commit    = cfg_session_wr && (cfg_session_data != SESSION_MAGIC)
                       && (sw_ptr == 4'(SW_COMMIT));
        sess_magic_mid = cfg_session_wr && (cfg_session_data == SESSION_MAGIC)
                       && (sw_ptr != 4'(SW_MAGIC));
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sw_ptr <= 4'(SW_MAGIC);
        end else if (cfg_session_wr) begin
            if (cfg_session_data == SESSION_MAGIC) begin
                sh[SW_MAGIC] <= cfg_session_data;
                sw_ptr       <= 4'(SW_MAGIC) + 4'd1;
            end else begin
                sh[sw_ptr] <= cfg_session_data;
                sw_ptr     <= (sw_ptr == 4'(SW_COMMIT)) ? 4'(SW_MAGIC)
                                                        : (sw_ptr + 4'd1);
            end
        end
    end

    // ---- Live (committed) session registers ---------------------------------
    tcp_sess_t   sess;
    logic [15:0] armed_epoch;
    logic [15:0] token_magic;
    logic [31:0] hb_cycles;
    logic [31:0] wdog_cycles;
    logic        sess_seq_wr, sess_ack_wr, sess_clr_disarm;
    logic        commit_q1, commit_q2;
    logic        sh_arm_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            // ⚠️ FAIL-CLOSED (CLAUDE.md §5 / fpga_top rule 4): reset means
            //    disarmed, epoch 0, no heartbeats, no watchdog. Nothing leaves
            //    the chip until the host has written and committed a record.
            sess            <= '0;
            armed_epoch     <= 16'd0;
            token_magic     <= 16'd0;
            hb_cycles       <= 32'd0;
            wdog_cycles     <= 32'd0;
            sess_seq_wr     <= 1'b0;
            sess_ack_wr     <= 1'b0;
            sess_clr_disarm <= 1'b0;
            commit_q1       <= 1'b0;
            commit_q2       <= 1'b0;
            sh_arm_q        <= 1'b0;
        end else begin
            commit_q1       <= sess_commit;
            commit_q2       <= commit_q1;
            sess_seq_wr     <= 1'b0;
            sess_ack_wr     <= 1'b0;
            sess_clr_disarm <= 1'b0;

            if (sess_commit) begin
                sess.dmac           <= {sh[SW_DMAC_HI], sh[SW_MAC_MID][31:16]};
                sess.smac           <= {sh[SW_MAC_MID][15:0], sh[SW_SMAC_LO]};
                sess.sip            <=  sh[SW_SIP];
                sess.dip            <=  sh[SW_DIP];
                sess.sport          <=  sh[SW_PORTS][31:16];
                sess.dport          <=  sh[SW_PORTS][15:0];
                sess.win            <=  sh[SW_WTD][31:16];
                sess.ttl            <=  sh[SW_WTD][15:8];
                sess.dscp           <=  sh[SW_WTD][7:0];
                sess.ip_csum_const  <=  sh[SW_CSUM][31:16];
                sess.tcp_csum_const <=  sh[SW_CSUM][15:0];
                sess.epoch          <=  sh[SW_EPOCH][31:16];
                sess.wscale         <=  sh[SW_EPOCH][7:4];
                sess.hb_en          <=  sh[SW_EPOCH][SF_HB_EN];
                hb_cycles           <=  sh[SW_HB];
                wdog_cycles         <=  sh[SW_WDOG];
                token_magic         <=  sh[SW_TOKMAG][31:16];
                sh_arm_q            <=  sh[SW_EPOCH][SF_ARM];
                sess_clr_disarm     <=  sh[SW_EPOCH][SF_CLR_DISARM];

                // ⚠️ DISARM TAKES EFFECT IMMEDIATELY. ARM IS DELAYED BY TWO
                //    CYCLES. That asymmetry is deliberate: stopping is a safety
                //    action and must never be deferred, whereas arming must not
                //    race the sequence-number write in the same record —
                //    tcp_tx_lite's interlock I1 rejects a sequence write while
                //    armed, so the write must land first.
                if (!sh[SW_EPOCH][SF_ARM]) sess.armed <= 1'b0;

                // Pulse the sequence resync while still (necessarily) disarmed.
                sess_seq_wr <= 1'b1;
                sess_ack_wr <= 1'b1;
            end

            if (commit_q2 && sh_arm_q) begin
                sess.armed  <= 1'b1;
                armed_epoch <= sess.epoch;
            end
        end
    end

    // Sequence resync values are read straight from the shadow: they are stable
    // by the time the pulse is seen, and they are only honoured while disarmed.
    logic [31:0] seq_resync_val;
    logic [31:0] ack_resync_val;
    assign seq_resync_val = sh[SW_SND_NXT];
    assign ack_resync_val = sh[SW_RCV_NXT];

    // =========================================================================
    // Inbound-silence watchdog
    // -------------------------------------------------------------------------
    // ⚠️ "If the FPGA sees no inbound session traffic for a configured interval,
    //    it stops emitting new orders. It does not need the CPU's permission to
    //    do this." (manuals/03-algotrading/04-order-entry-protocols.md §8.)
    //    Silence on an order-entry session means the venue is gone, the link is
    //    one-way, or the host has wedged — and in every one of those cases
    //    continuing to send is worse than stopping. Registered so the 48-bit
    //    compare stays off the accept path.
    // =========================================================================
    cycle_t last_rx_cycle;
    logic   wdog_trip;

    always_ff @(posedge clk) begin
        if (rst) begin
            last_rx_cycle <= '0;
            wdog_trip     <= 1'b0;
        end else begin
            if (snoop_valid) last_rx_cycle <= cycle_cnt;
            wdog_trip <= (wdog_cycles != 32'd0)
                      && ((cycle_cnt - last_rx_cycle) > {{(CYCLE_CNT_W-32){1'b0}}, wdog_cycles});
        end
    end

    // =========================================================================
    // TX slot reservation
    // =========================================================================
    logic [2:0] tx_occ;
    logic       enc_ready;
    logic       hb_ready;
    logic       enc_accept;
    logic       blocked_kill;
    logic       blocked_session;

    // Inter-module signals declared ahead of use.
    logic                            enc_valid, enc_refuse, enc_is_cancel;
    logic [OUCH_IN_MAX_LEN*8-1:0]    enc_msg;
    logic [7:0]                      enc_len;
    csum_acc_t                       enc_csum;
    logic [31:0]                     enc_stat [8];

    logic [SOUP_PAY_MAX_BYTES*8-1:0] soup_pay;
    logic [7:0]                      soup_len;
    csum_acc_t                       soup_csum;
    logic                            soup_valid, soup_is_hb, soup_is_cancel;
    logic                            soup_refuse, soup_hb_fire;
    logic [31:0]                     soup_stat [4];

    logic                            tcp_frame_done, tcp_refuse, tcp_accept_enter;
    logic [31:0]                     tcp_snd_nxt, tcp_snd_una;
    logic                            tcp_hw_disarmed, tcp_tx_idle;
    logic [31:0]                     tcp_stat [8];

    logic                            snoop_valid, snoop_ack_vld, snoop_fin, snoop_rst;
    logic [31:0]                     snoop_seq, snoop_ack;
    logic [15:0]                     snoop_seglen, snoop_win;
    logic                            rx_credit_ret, rx_desync;
    logic [31:0]                     rx_msg_cnt [N_OUT_MSG_TYPES];
    logic [31:0]                     rx_stat [8];

    logic [CREDIT_W-1:0]             credit_in_flight;
    logic [31:0]                     credit_starve_max;
    logic                            credit_alarm;
    logic [31:0]                     credit_stat [4];

    always_comb begin
        enc_ready = (tx_occ < 3'(TX_DEPTH));
        // Heartbeats only when the TX path is completely idle. This is both
        // semantically right (a heartbeat exists to prove liveness on an idle
        // link) and structurally necessary: it keeps the reservation count
        // bounded by TX_DEPTH even though the heartbeat reserves from inside
        // soupbin_tx.
        hb_ready  = (tx_occ == 3'd0);

        // ⚠️ KILL GATE #1 OF 3. See the header — this redundancy is deliberate.
        blocked_kill    = s_out_valid && (s_out.action != ACT_NONE) && kill_active;
        blocked_session = s_out_valid && (s_out.action != ACT_NONE) && !kill_active
                       && (!sess.armed || tcp_hw_disarmed || wdog_trip || rx_desync);

        enc_accept = s_out_valid
                  && (s_out.action != ACT_NONE)
                  && !kill_active
                  &&  sess.armed
                  && !tcp_hw_disarmed
                  && !wdog_trip
                  && !rx_desync
                  &&  enc_ready;
    end

    logic [2:0] occ_inc, occ_dec;
    logic [3:0] occ_n;

    always_comb begin
        occ_inc = {2'd0, enc_accept} + {2'd0, soup_hb_fire};
        occ_dec = {2'd0, tcp_frame_done} + {2'd0, enc_refuse}
                + {2'd0, soup_refuse}    + {2'd0, tcp_refuse};
        occ_n   = {1'b0, tx_occ} + {1'b0, occ_inc};
        occ_n   = (occ_n >= {1'b0, occ_dec}) ? (occ_n - {1'b0, occ_dec}) : 4'd0;
        if (occ_n > 4'(TX_DEPTH)) occ_n = 4'(TX_DEPTH);
    end

    always_ff @(posedge clk) begin
        if (rst) tx_occ <= 3'd0;
        else     tx_occ <= occ_n[2:0];
    end

    // =========================================================================
    // Sub-blocks
    // =========================================================================
    order_out_t enc_in;
    logic       enc_in_valid;

    always_comb begin
        enc_in       = s_out;
        enc_in_valid = enc_accept;
    end

    ouch_encoder #(
        .TOKEN_ASCII_HEX (TOKEN_ASCII_HEX)
    ) u_enc (
        .clk           (clk),
        .rst           (rst),
        .s_out         (enc_in),
        .s_out_valid   (enc_in_valid),
        .cfg_tmpl_wr   (cfg_tmpl_wr),
        .cfg_tmpl_addr (cfg_tmpl_addr),
        .cfg_tmpl_data (cfg_tmpl_data),
        .m_msg         (enc_msg),
        .m_len         (enc_len),
        .m_csum        (enc_csum),
        .m_valid       (enc_valid),
        .m_is_cancel   (enc_is_cancel),
        .m_refuse      (enc_refuse),
        .stat          (enc_stat)
    );

    soupbin_tx u_soup (
        .clk           (clk),
        .rst           (rst),
        .s_msg         (enc_msg),
        .s_len         (enc_len),
        .s_csum        (enc_csum),
        .s_valid       (enc_valid),
        .s_is_cancel   (enc_is_cancel),
        .session_armed (sess.armed),
        .cfg_hb_en     (sess.hb_en),
        .cfg_hb_cycles (hb_cycles),
        .tx_ready      (hb_ready),
        .m_pay         (soup_pay),
        .m_len         (soup_len),
        .m_csum        (soup_csum),
        .m_valid       (soup_valid),
        .m_is_hb       (soup_is_hb),
        .m_is_cancel   (soup_is_cancel),
        .m_refuse      (soup_refuse),
        .m_hb_fire     (soup_hb_fire),
        .stat          (soup_stat)
    );

    tcp_tx_lite #(
        .FBUF_DEPTH (TX_DEPTH)
    ) u_tcp (
        .clk             (clk),
        .rst             (rst),
        .s_pay           (soup_pay),
        .s_len           (soup_len),
        .s_csum          (soup_csum),
        .s_valid         (soup_valid),
        .s_is_hb         (soup_is_hb),
        .s_is_cancel     (soup_is_cancel),
        .sess            (sess),
        .armed_epoch     (armed_epoch),
        .sess_seq_wr     (sess_seq_wr),
        .sess_seq_val    (seq_resync_val),
        .sess_ack_wr     (sess_ack_wr),
        .sess_ack_val    (ack_resync_val),
        .sess_clr_disarm (sess_clr_disarm),
        .snoop_valid     (snoop_valid),
        .snoop_seq       (snoop_seq),
        .snoop_seglen    (snoop_seglen),
        .snoop_ack       (snoop_ack),
        .snoop_win       (snoop_win),
        .snoop_ack_vld   (snoop_ack_vld),
        .snoop_fin       (snoop_fin),
        .snoop_rst       (snoop_rst),
        // ⚠️ KILL GATE #2 OF 3.
        .kill_active     (kill_active),
        .m_axis_tdata    (m_axis_tdata),
        .m_axis_tkeep    (m_axis_tkeep),
        .m_axis_tvalid   (m_axis_tvalid),
        .m_axis_tlast    (m_axis_tlast),
        .m_axis_tready   (m_axis_tready),
        .frame_done      (tcp_frame_done),
        .s_refuse        (tcp_refuse),
        .accept_enter    (tcp_accept_enter),
        .snd_nxt_o       (tcp_snd_nxt),
        .snd_una_o       (tcp_snd_una),
        .hw_disarmed     (tcp_hw_disarmed),
        .tx_idle         (tcp_tx_idle),
        .stat            (tcp_stat)
    );

    ouch_rx #(
        .TOKEN_ASCII_HEX       (TOKEN_ASCII_HEX),
        .CREDIT_RETURN_ON_EXEC (CREDIT_RETURN_ON_EXEC),
        .RXFIFO_BEATS          (RXFIFO_BEATS)
    ) u_rx (
        .clk             (clk),
        .rst             (rst),
        .s_axis_tdata    (s_axis_tdata),
        .s_axis_tkeep    (s_axis_tkeep),
        .s_axis_tvalid   (s_axis_tvalid),
        .s_axis_tlast    (s_axis_tlast),
        .s_axis_tuser    (s_axis_tuser),
        .sess            (sess),
        .cfg_token_magic (token_magic),
        .rx_resync       (sess_clr_disarm),
        .snoop_valid     (snoop_valid),
        .snoop_seq       (snoop_seq),
        .snoop_seglen    (snoop_seglen),
        .snoop_ack       (snoop_ack),
        .snoop_win       (snoop_win),
        .snoop_ack_vld   (snoop_ack_vld),
        .snoop_fin       (snoop_fin),
        .snoop_rst       (snoop_rst),
        .fill_valid      (fill_valid),
        .fill_sym        (fill_sym),
        .fill_side       (fill_side),
        .fill_qty        (fill_qty),
        .fill_px         (fill_px),
        .credit_ret      (rx_credit_ret),
        .msg_cnt         (rx_msg_cnt),
        .stat            (rx_stat),
        .desync_sticky   (rx_desync)
    );

    credit_mgr #(
        .STARVE_ALARM_CYC (STARVE_ALARM_CYC)
    ) u_credit (
        .clk            (clk),
        .rst            (rst),
        // ⚠️ Consumed only when an ENTER ORDER frame is actually committed to
        //    the wire. A refusal anywhere upstream therefore cannot burn a
        //    credit, and — see credit_mgr.sv — cancels never consume one at all.
        .consume        (tcp_accept_enter),
        .ret_rx         (rx_credit_ret),
        .ret_host       (credit_return),
        .credit_avail   (credit_avail),
        .in_flight      (credit_in_flight),
        .starve_run_max (credit_starve_max),
        .starve_alarm   (credit_alarm),
        .stat           (credit_stat)
    );

    // =========================================================================
    // Telemetry aggregation
    // =========================================================================
    // Registered sums: one cycle stale, which is irrelevant for counters read at
    // PCIe cadence, and it keeps the 32-bit adder trees off any path that could
    // interact with the datapath's timing.
    logic [31:0] cnt_blocked;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_blocked <= 32'd0;
        end else if (blocked_kill || blocked_session || sess_magic_mid) begin
            cnt_blocked <= cnt_blocked + 32'd1;
        end
    end

    // stat[6] is the only NON-counter slot: a packed live status word. Counters
    // tell you what happened; this tells you what is happening right now, which
    // is the question you actually have when the phone rings.
    logic [31:0] status_word;
    logic [15:0] starve_max_sat;

    always_comb begin
        starve_max_sat = (credit_starve_max > 32'h0000_FFFF)
                       ? 16'hFFFF : credit_starve_max[15:0];
        status_word = {starve_max_sat,          // [31:16] longest starvation run
                       tx_occ,                  // [15:13] TX slot reservations
                       7'(credit_in_flight),    // [12: 6] orders in flight
                       credit_alarm,            // [5]
                       tcp_tx_idle,             // [4]
                       rx_desync,               // [3]  ⚠️
                       wdog_trip,               // [2]  ⚠️
                       tcp_hw_disarmed,         // [1]  ⚠️ FIN/RST seen
                       sess.armed};             // [0]
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 16; i++) stat[i] <= 32'd0;
        end else begin
            stat[0]  <= enc_stat[0];                    // enter orders encoded
            stat[1]  <= enc_stat[1];                    // cancels encoded
            stat[2]  <= tcp_stat[0];                    // frames transmitted
            stat[3]  <= soup_stat[1];                   // client heartbeats sent
            // ⚠️ ORDER LOST. Template invalid / wrong type / token high-water /
            //    length error / no TX slot. Any non-zero value is an incident,
            //    not a statistic: the strategy believes it has a working order
            //    that was never sent.
            stat[4]  <= enc_stat[2] + enc_stat[3] + enc_stat[4] + enc_stat[7]
                      + soup_stat[3] + tcp_stat[3];
            // Blocked for a KNOWN and intended reason: kill, unarmed, epoch
            // mismatch, send window, hardware disarm, inbound watchdog, RX
            // desync, config error, rejected sequence write, credit starvation.
            // (Per-order credit rejections are also counted at the top level as
            // risk_reject_cnt[RISK_NO_CREDIT].)
            stat[5]  <= cnt_blocked + tcp_stat[1] + tcp_stat[2] + tcp_stat[4]
                      + tcp_stat[5] + tcp_stat[7] + credit_stat[2];
            stat[6]  <= status_word;                    // ⚠️ NOT A COUNTER
            // ⚠️ NOT A COUNTER. Live TCP sequence numbers, published because
            //    the host has no other way to see them and MUST reconcile
            //    against them. If (snd_nxt - snd_una) stops shrinking, the host
            //    disarms and takes the socket back. See tcp_tx_lite.sv.
            stat[7]  <= tcp_snd_nxt;
            stat[8]  <= rx_stat[0];                     // frames accepted
            stat[9]  <= rx_stat[1] + rx_stat[3] + rx_stat[4];
            stat[10] <= rx_msg_cnt[OMI_ACCEPTED];
            stat[11] <= rx_msg_cnt[OMI_EXECUTED];
            stat[12] <= rx_msg_cnt[OMI_CANCELED] + rx_msg_cnt[OMI_AIQ_CANCELED];
            // ⚠️ PAGE ON A SPIKE. See the stat map in the header.
            stat[13] <= rx_msg_cnt[OMI_REJECTED] + rx_msg_cnt[OMI_CANCEL_REJECT];
            stat[14] <= tcp_snd_una;                    // ⚠️ NOT A COUNTER
            // ⚠️ MUST BE ZERO. Byte-stream desync + stale-session token +
            //    malformed token + unknown outbound message type + credit
            //    over-return. Every one of these means the FPGA's view of the
            //    world and the venue's have diverged.
            stat[15] <= rx_stat[2] + rx_stat[5] + rx_stat[6]
                      + rx_msg_cnt[OMI_UNKNOWN] + credit_stat[3];
        end
    end

    // =========================================================================
    // Assertions
    // =========================================================================
`ifndef SYNTHESIS
    // CLAUDE.md §5.6 / fpga_top rule 3 — the kill switch, checked HERE as well
    // as at the risk gate. If risk_gate is ever broken or bypassed, this is the
    // gate that still holds.
    assert property (@(posedge clk) disable iff (rst)
        kill_active |-> !enc_accept
    ) else $error("order_gateway: order accepted while the kill switch is active");

    // Nothing may be encoded on an unarmed, hardware-disarmed, watchdog-tripped
    // or desynchronised session.
    assert property (@(posedge clk) disable iff (rst)
        enc_accept |-> (sess.armed && !tcp_hw_disarmed && !wdog_trip && !rx_desync)
    ) else $error("order_gateway: order accepted on an unusable session");

    // The reservation invariant: tx_occ can never exceed the frame-buffer depth,
    // which is what makes tcp_tx_lite's overflow structurally impossible.
    assert property (@(posedge clk) disable iff (rst)
        (tx_occ <= 3'(TX_DEPTH))
    ) else $error("order_gateway: TX reservation count exceeded TX_DEPTH");

    // Every accepted order must resolve exactly once: a frame, or a refusal.
    // (The pipeline is fixed-latency and non-stalling, so 4 cycles is exact.)
    assert property (@(posedge clk) disable iff (rst)
        enc_accept |-> ##[1:8] (tcp_frame_done || enc_refuse || soup_refuse || tcp_refuse)
    ) else $error("order_gateway: accepted order neither transmitted nor refused -- reservation LEAKED");

    // Fail-closed out of reset.
    assert property (@(posedge clk)
        rst |=> !sess.armed
    ) else $error("order_gateway: session armed out of reset");

    // A fill must never arrive while the session is disarmed AND desynchronised
    // -- that combination means the RX view is untrustworthy.
    assert property (@(posedge clk) disable iff (rst)
        rx_desync |-> !fill_valid
    ) else $error("order_gateway: fill emitted from a desynchronised RX stream");

    initial begin
        if (TX_DEPTH != 2)
            $fatal(1, "order_gateway: TX_DEPTH must match tcp_tx_lite FBUF_DEPTH (2)");
    end
`endif

endmodule : order_gateway

`default_nettype wire
