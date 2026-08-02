// =============================================================================
// mac_tx.sv — Cut-through 10GbE MAC transmit, 64-bit datapath
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/02-networking/01-ethernet-phy-mac.md §4, §7, §9
//           manuals/01-fpga-design/02-pipelining-and-parallelism.md §5
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   Turn an AXI-Stream frame body (DA..payload, no preamble, no FCS) into a
//   conformant 10GBASE-R transmit stream on a 64-bit XGMII-like interface:
//     * preamble + SFD insertion       (802.3 §3.2.1-3.2.2)
//     * padding to the 64-byte minimum (802.3 §3.2.8, §4.2.3.3)
//     * CRC-32 generation and append   (802.3 §3.2.9)
//     * inter-frame gap enforcement    (802.3 §4.4.2, §46.3.1.4)
//
//   TX cut-through is FREE: the FCS lives at the end of the frame, which is
//   exactly where a streaming computation naturally lands. Nothing is buffered.
//
// -----------------------------------------------------------------------------
// ⚠️⚠️  THE `abort` INPUT — DELIBERATE FCS CORRUPTION  ⚠️⚠️
// -----------------------------------------------------------------------------
//   Asserting `abort` at any point between the first accepted beat of a frame
//   and the emission of its FCS causes the transmitted FCS to be XORed with
//   32'hFFFF_FFFF. The frame reaches the peer looking structurally normal and
//   fails its FCS check, so the peer drops it and counts an FCS error.
//
//   WHY IT EXISTS. manuals/01-fpga-design/02-pipelining-and-parallelism.md §5
//   ("Speculative transmission") permits streaming an order's leading bytes
//   onto the wire before the decision is final, because the first N bytes are
//   identical either way. That optimization is only sound if the frame can be
//   killed in flight. This input is that kill. It is also the escape used when
//   the kill switch fires mid-frame or a risk check resolves late.
//
//   ⚠️ USING THIS IN PRODUCTION REQUIRES WRITTEN VENUE APPROVAL.
//   Deliberately-invalid frames count against the exchange's link error-rate
//   policy. Enough of them and the venue may raise an alarm, throttle, or
//   disconnect the session. Confirm in writing, with the venue and the colo
//   provider, that intentional FCS-invalid frames are acceptable and will not
//   trip an error-rate or disconnection threshold, BEFORE any build that can
//   assert this signal reaches a live session.
//
//   ⚠️ AN ABORTED ORDER IS NOT A CANCELLED ORDER. You do not know whether the
//   venue's receiver committed part of it downstream. Treat every abort as an
//   UNKNOWN-STATE order and reconcile it on the slow path
//   (manuals/02-networking/01-ethernet-phy-mac.md §7). Designing so that
//   aborts never happen — risk checks complete before the first byte leaves —
//   is strictly better than relying on abort.
//
//   Every abort increments `evt_abort`, which is surfaced in the wrapper's
//   stat[] word. Silent aborts are forbidden (CLAUDE.md §5 rule 7).
//
//   The alternative mechanism, asserting the PCS error input so /E/ control
//   characters are emitted, is cleaner semantically ("the sender aborted") but
//   needs vendor core support that the PCS/PMA-only configuration used here
//   does not expose. FCS inversion works with every MAC and every peer.
//
// -----------------------------------------------------------------------------
// ⚠️ UNDERRUN. XGMII cannot be stalled mid-frame. If the source stops supplying
//   beats after transmission has begun, the frame is terminated immediately with
//   an inverted FCS (i.e. the abort mechanism) and `evt_underrun` fires. This is
//   the only correct behaviour — emitting idle or stale bytes into the middle of
//   a frame would produce a frame that might still pass FCS. The wrapper sizes
//   its TX skid buffer to make underrun unreachable in steady state; any
//   non-zero underrun count is a design bug, not a runtime condition.
//
// -----------------------------------------------------------------------------
// ⚠️ NEVER SHORTEN THE PREAMBLE OR THE IFG. The nanoseconds are not worth a
//   conformance failure at the venue (manuals/02-networking/01-ethernet-phy-mac.md
//   §9 rule 8). IFG_BEATS counts FULL idle beats held in T_IFG; the state costs
//   one extra beat on exit, so IFG_BEATS=N puts N+1 idle beats (8N+8 bytes) on
//   the wire between /T/ and the next /S/, plus whatever idle lanes trailed /T/
//   in the terminate beat itself. The default of 2 therefore guarantees >= 24
//   idle bytes against a 12-byte requirement. IFG_BEATS=1 (>= 16 bytes) is the
//   analysed minimum; 0 is non-conformant and is rejected at elaboration.
//   Being generous here costs ~10 ns of TX-to-TX gap and buys conformance
//   margin — the right side of that trade for a venue-facing link.
//
// -----------------------------------------------------------------------------
// LATENCY
//   s_axis_tvalid rising -> first preamble byte on XGMII: 2 cycles, 12.8 ns
//   @ 156.25 MHz (6.4 ns/cycle):
//     stage 1  state decision + preamble beat select      (1 cycle)
//     stage 2  registered XGMII output                    (1 cycle)
//   The first PAYLOAD byte follows 8 bytes (6.4 ns of serialization) later,
//   because the preamble occupies exactly one beat. Matches the
//   "MAC TX (cut-through)  2 cyc  12.8 ns" line in the fpga_top.sv budget.
//   Fixed: no data-dependent jitter on the frame-start path.
//
// RESOURCE ESTIMATE (DATA_W=64, UltraScale+)
//   LUT ~2200 (of which ~1800 is the crc32_eth XOR cone)
//   FF  ~200    BRAM 0    URAM 0    DSP 0
//
// INTERFACES
//   s_axis_*  : frame body only — DA(6) SA(6) EtherType(2) payload. No preamble,
//               no FCS, no padding. tkeep must be contiguous from lane 0 and is
//               only inspected on tlast.
//   xgmii_tx* : lane 0 is xgmii_txd[7:0], the first byte on the wire.
//               Starts are emitted LANE-0 ALIGNED, matching the contract in
//               mac_rx.sv.
//
// HARD RULES (CLAUDE.md §5)
//   3. No floating point.  7. Every abort/underrun is counted.
//   8. Determinism: the frame-start path is fixed-latency.
// =============================================================================
`default_nettype none

module mac_tx #(
    parameter int unsigned DATA_W          = 64,
    // Minimum frame body before the FCS. 60 + 4 = the 64-byte minimum frame.
    parameter int unsigned MIN_BODY_BYTES  = 60,
    // Full idle beats emitted after the terminate beat. 2 => >= 16 idle bytes.
    // ⚠️ Do not reduce below 2; see the header.
    parameter int unsigned IFG_BEATS       = 2
) (
    input  var logic                   clk,     // transceiver TX clock
    input  var logic                   rst,     // synchronous, active high

    // ── AXI-Stream input: the frame body ─────────────────────────────────────
    input  var logic [DATA_W-1:0]      s_axis_tdata,
    input  var logic [DATA_W/8-1:0]    s_axis_tkeep,
    input  var logic                   s_axis_tvalid,
    input  var logic                   s_axis_tlast,
    output var logic                   s_axis_tready,

    // ── ⚠️ Deliberate frame abort. See the header before wiring this. ────────
    input  var logic                   abort,

    // ── XGMII-like output to the PCS ─────────────────────────────────────────
    output var logic [DATA_W-1:0]      xgmii_txd,
    output var logic [DATA_W/8-1:0]    xgmii_txc,

    // ── Telemetry: single-cycle strobes ──────────────────────────────────────
    output var logic                   evt_frame_sent,
    output var logic                   evt_abort,
    output var logic                   evt_underrun
);

    // -------------------------------------------------------------------------
    // Local constants
    // -------------------------------------------------------------------------
    localparam int unsigned KEEP_W  = DATA_W / 8;             // 8
    localparam int unsigned CNT_W   = $clog2(KEEP_W + 1);     // 4
    localparam int unsigned BYTES_W = 16;
    localparam int unsigned IFG_W   = (IFG_BEATS < 2) ? 2 : $clog2(IFG_BEATS + 1);

    localparam logic [7:0] XGMII_IDLE  = 8'h07;
    localparam logic [7:0] XGMII_START = 8'hFB;
    localparam logic [7:0] XGMII_TERM  = 8'hFD;
    localparam logic [7:0] ETH_PRE     = 8'h55;
    localparam logic [7:0] ETH_SFD     = 8'hD5;

    localparam logic [31:0] CRC_INIT   = 32'hFFFF_FFFF;
    localparam logic [31:0] CRC_XOROUT = 32'hFFFF_FFFF;

    // A full beat of idle, and the preamble beat (/S/ replaces preamble byte 0).
    localparam logic [DATA_W-1:0] IDLE_BEAT = {KEEP_W{XGMII_IDLE}};
    localparam logic [DATA_W-1:0] PRE_BEAT  = {ETH_SFD, ETH_PRE, ETH_PRE, ETH_PRE,
                                               ETH_PRE, ETH_PRE, ETH_PRE, XGMII_START};

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------
    // T_IDLE emits the preamble beat and steps straight to T_DATA, so the first
    // body beat lands on the wire in the cycle immediately after the preamble —
    // no gap, no separate preamble state.
    typedef enum logic [2:0] {
        T_IDLE = 3'd0,   // emitting idle / launching the preamble beat
        T_DATA = 3'd1,   // streaming the frame body
        T_PAD  = 3'd2,   // padding out to MIN_BODY_BYTES
        T_TAIL = 3'd3,   // second half of the FCS + /T/
        T_IFG  = 3'd4    // inter-frame gap
    } tx_state_e;

    tx_state_e          st, st_d;
    logic [31:0]        crc_q;
    logic [BYTES_W-1:0] body_bytes;      // body bytes already emitted
    logic               abort_q;         // abort latched for this frame
    logic               underrun_q;      // underrun latched for this frame
    logic               tail_abort_q;    // verdict carried into T_TAIL
    logic               tail_under_q;
    logic [IFG_W-1:0]   ifg_cnt;
    logic [DATA_W-1:0]  tail_d_q;        // latched second tail beat
    logic [KEEP_W-1:0]  tail_c_q;

    // -------------------------------------------------------------------------
    // How many bytes does this input beat carry?
    // Only meaningful on tlast; every other beat is a full beat.
    // -------------------------------------------------------------------------
    logic [CNT_W-1:0] keep_bytes;
    always_comb begin
        keep_bytes = CNT_W'(KEEP_W);              // default: full beat, no latch
        unique case (s_axis_tkeep)
            8'h01:   keep_bytes = CNT_W'(1);
            8'h03:   keep_bytes = CNT_W'(2);
            8'h07:   keep_bytes = CNT_W'(3);
            8'h0F:   keep_bytes = CNT_W'(4);
            8'h1F:   keep_bytes = CNT_W'(5);
            8'h3F:   keep_bytes = CNT_W'(6);
            8'h7F:   keep_bytes = CNT_W'(7);
            8'hFF:   keep_bytes = CNT_W'(8);
            default: keep_bytes = CNT_W'(KEEP_W); // non-contiguous: assert below
        endcase
    end

    // -------------------------------------------------------------------------
    // Beat composition for this cycle
    //   beat_data : the frame bytes to hand the CRC and place on the wire
    //   beat_v    : how many of them are real frame bytes (0..8)
    //   terminal  : this is the last beat carrying frame bytes; append the FCS
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0] beat_data;
    logic [CNT_W-1:0]  beat_v;
    logic              terminal;
    logic              consume;          // pop one beat from s_axis this cycle
    logic              underrun;

    // Bytes still owed to reach the minimum body length.
    logic [BYTES_W-1:0] pad_left;
    assign pad_left = (body_bytes >= BYTES_W'(MIN_BODY_BYTES))
                      ? BYTES_W'(0)
                      : (BYTES_W'(MIN_BODY_BYTES) - body_bytes);

    // Mask off lanes above keep_bytes so padding within the last data beat is
    // zeros, not stale bus content.
    logic [DATA_W-1:0] masked_tdata;
    always_comb begin
        masked_tdata = '0;
        for (int unsigned i = 0; i < KEEP_W; i++) begin
            if (CNT_W'(i) < keep_bytes) begin
                masked_tdata[i*8 +: 8] = s_axis_tdata[i*8 +: 8];
            end
        end
    end

    always_comb begin
        beat_data = '0;
        beat_v    = CNT_W'(KEEP_W);
        terminal  = 1'b0;
        consume   = 1'b0;
        underrun  = 1'b0;

        unique case (st)
            T_DATA: begin
                if (!s_axis_tvalid) begin
                    // ⚠️ Source starved mid-frame. Terminate NOW with a bad FCS.
                    underrun = 1'b1;
                    beat_v   = CNT_W'(0);
                    terminal = 1'b1;
                end else begin
                    consume   = 1'b1;
                    beat_data = s_axis_tlast ? masked_tdata : s_axis_tdata;
                    if (!s_axis_tlast) begin
                        beat_v   = CNT_W'(KEEP_W);
                        terminal = 1'b0;
                    end else if ((body_bytes + BYTES_W'(keep_bytes)) >=
                                 BYTES_W'(MIN_BODY_BYTES)) begin
                        // Long enough already: this beat ends the body.
                        beat_v   = keep_bytes;
                        terminal = 1'b1;
                    end else if (pad_left >= BYTES_W'(KEEP_W)) begin
                        // Pad this beat out to 8 and keep padding next cycle.
                        beat_v   = CNT_W'(KEEP_W);
                        terminal = 1'b0;
                    end else begin
                        // Final beat: real bytes + just enough zero padding.
                        beat_v   = CNT_W'(pad_left);
                        terminal = 1'b1;
                    end
                end
            end

            T_PAD: begin
                beat_data = '0;
                if (pad_left >= BYTES_W'(KEEP_W)) begin
                    beat_v   = CNT_W'(KEEP_W);
                    terminal = 1'b0;
                end else begin
                    beat_v   = CNT_W'(pad_left);
                    terminal = 1'b1;
                end
            end

            default: begin
                beat_data = '0;
                beat_v    = CNT_W'(0);
                terminal  = 1'b0;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // CRC. One instance: the accumulate step and the final step never coincide,
    // because the beat that ends the body is never also accumulated.
    // -------------------------------------------------------------------------
    logic [31:0] crc_res;
    logic [31:0] fcs_word;

    crc32_eth #(
        .DATA_W          (DATA_W),
        .PARTIAL_SUPPORT (1)
    ) u_crc (
        .crc_in  (crc_q),
        .data    (beat_data),
        .bytes   (beat_v),
        .crc_out (crc_res)
    );

    // Normal FCS is the CRC register complemented. ⚠️ On abort we complement it
    // a second time, which is exactly "XOR the computed CRC with 0xFFFFFFFF"
    // from manuals/02-networking/01-ethernet-phy-mac.md §7.
    logic abort_eff;
    assign abort_eff = abort_q | abort | underrun;
    assign fcs_word  = crc_res ^ (abort_eff ? 32'h0000_0000 : CRC_XOROUT);

    // -------------------------------------------------------------------------
    // Tail builder — where the FCS and /T/ land relative to the last body bytes.
    //
    //   beat0 lane i :  i <  v      -> body byte i
    //                   i <  v+4    -> FCS byte (i - v)
    //                   i == v+4    -> /T/
    //                   else        -> /I/
    //   beat1 lane i :  i <  v-4    -> FCS byte (i + 8 - v)
    //                   i == v-4    -> /T/
    //                   else        -> /I/
    //   beat1 is only needed when v >= 4 (the FCS or /T/ spills past lane 7).
    //
    //   v=0 -> FCS at lanes 0..3, /T/ at lane 4, one beat  (the underrun/abort case)
    //   v=3 -> FCS at lanes 3..6, /T/ at lane 7, one beat
    //   v=4 -> FCS at lanes 4..7, /T/ at lane 0 of beat1
    //   v=8 -> body fills beat0,  FCS at 0..3 and /T/ at lane 4 of beat1
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0] tail0_d, tail1_d;
    logic [KEEP_W-1:0] tail0_c, tail1_c;
    logic              need_tail1;

    always_comb begin
        tail0_d = IDLE_BEAT;
        tail0_c = {KEEP_W{1'b1}};
        tail1_d = IDLE_BEAT;
        tail1_c = {KEEP_W{1'b1}};

        for (int unsigned i = 0; i < KEEP_W; i++) begin
            // ---- beat 0 ----
            if (CNT_W'(i) < beat_v) begin
                tail0_d[i*8 +: 8] = beat_data[i*8 +: 8];
                tail0_c[i]        = 1'b0;
            end else if (CNT_W'(i) < (beat_v + CNT_W'(4))) begin
                tail0_d[i*8 +: 8] = fcs_word[(CNT_W'(i) - beat_v)*8 +: 8];
                tail0_c[i]        = 1'b0;
            end else if (CNT_W'(i) == (beat_v + CNT_W'(4))) begin
                tail0_d[i*8 +: 8] = XGMII_TERM;
                tail0_c[i]        = 1'b1;
            end else begin
                tail0_d[i*8 +: 8] = XGMII_IDLE;
                tail0_c[i]        = 1'b1;
            end

            // ---- beat 1 ----
            if ((beat_v >= CNT_W'(4)) && (CNT_W'(i) < (beat_v - CNT_W'(4)))) begin
                tail1_d[i*8 +: 8] = fcs_word[(CNT_W'(i) + CNT_W'(KEEP_W) - beat_v)*8 +: 8];
                tail1_c[i]        = 1'b0;
            end else if ((beat_v >= CNT_W'(4)) && (CNT_W'(i) == (beat_v - CNT_W'(4)))) begin
                tail1_d[i*8 +: 8] = XGMII_TERM;
                tail1_c[i]        = 1'b1;
            end else begin
                tail1_d[i*8 +: 8] = XGMII_IDLE;
                tail1_c[i]        = 1'b1;
            end
        end

        need_tail1 = (beat_v >= CNT_W'(4));
    end

    // -------------------------------------------------------------------------
    // Output beat select + next state
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0] txd_d;
    logic [KEEP_W-1:0] txc_d;
    logic              evt_frame_sent_d, evt_abort_d, evt_underrun_d;

    always_comb begin
        txd_d            = IDLE_BEAT;
        txc_d            = {KEEP_W{1'b1}};
        st_d             = st;
        evt_frame_sent_d = 1'b0;
        evt_abort_d      = 1'b0;
        evt_underrun_d   = 1'b0;

        unique case (st)
            T_IDLE: begin
                // Launch: the preamble beat is registered out this cycle and
                // appears on the wire next cycle, at which point st == T_DATA
                // composes the first body beat. No gap between them.
                if (s_axis_tvalid) begin
                    txd_d = PRE_BEAT;
                    txc_d = KEEP_W'(1);       // /S/ in lane 0 only, rest is data
                    st_d  = T_DATA;
                end
            end

            T_DATA, T_PAD: begin
                if (terminal) begin
                    // Last beat carrying body bytes: FCS (and maybe /T/) go out
                    // in the same beat.
                    txd_d            = tail0_d;
                    txc_d            = tail0_c;
                    st_d             = need_tail1 ? T_TAIL : T_IFG;
                    evt_frame_sent_d = !need_tail1 && !abort_eff;
                    evt_abort_d      = !need_tail1 && abort_eff && !underrun;
                    evt_underrun_d   = !need_tail1 && underrun;
                end else begin
                    txd_d = beat_data;
                    txc_d = '0;                // all lanes are data
                    st_d  = ((st == T_DATA) && consume && s_axis_tlast) ? T_PAD : st;
                end
            end

            T_TAIL: begin
                txd_d            = tail_d_q;
                txc_d            = tail_c_q;
                st_d             = T_IFG;
                evt_frame_sent_d = !tail_abort_q;
                evt_abort_d      = tail_abort_q && !tail_under_q;
                evt_underrun_d   = tail_under_q;
            end

            T_IFG: begin
                if (ifg_cnt == '0) begin
                    st_d = T_IDLE;
                end
            end

            default: st_d = T_IDLE;
        endcase
    end

    // ⚠️ tready is combinational. This is the sanctioned exception in
    // manuals/00-foundations/03-hdl-and-rtl-coding.md §5; the wrapper's skid
    // buffer absorbs it so it never becomes a long path back into the fabric.
    assign s_axis_tready = consume;

    // -------------------------------------------------------------------------
    // Registers
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        // ---- datapath: no reset (coding standard §6) -----------------------
        xgmii_txd <= txd_d;
        tail_d_q  <= tail1_d;
        tail_c_q  <= tail1_c;

        if (rst) begin
            st             <= T_IDLE;
            xgmii_txc      <= {KEEP_W{1'b1}};
            crc_q          <= CRC_INIT;
            body_bytes     <= '0;
            abort_q        <= 1'b0;
            underrun_q     <= 1'b0;
            tail_abort_q   <= 1'b0;
            tail_under_q   <= 1'b0;
            ifg_cnt        <= IFG_W'(IFG_BEATS);
            evt_frame_sent <= 1'b0;
            evt_abort      <= 1'b0;
            evt_underrun   <= 1'b0;
        end else begin
            st        <= st_d;
            xgmii_txc <= txc_d;

            // ---- CRC / length accounting -----------------------------------
            // The terminal beat's CRC is consumed combinationally as the FCS, so
            // it is never written back into crc_q.
            if (st == T_IDLE) begin
                crc_q      <= CRC_INIT;
                body_bytes <= '0;
                abort_q    <= 1'b0;
                underrun_q <= 1'b0;
            end else begin
                if (((st == T_DATA) || (st == T_PAD)) && !terminal) begin
                    crc_q      <= crc_res;
                    body_bytes <= body_bytes + BYTES_W'(beat_v);
                end
                // ⚠️ abort latch: sticky from the first accepted beat until the
                // FCS is emitted, so a one-cycle abort pulse cannot be missed.
                abort_q    <= abort_q    | abort | underrun;
                underrun_q <= underrun_q | underrun;
            end

            // Freeze the verdict for the second tail beat.
            if (((st == T_DATA) || (st == T_PAD)) && terminal) begin
                tail_abort_q <= abort_q | abort | underrun;
                tail_under_q <= underrun_q | underrun;
            end

            // ---- IFG counter -----------------------------------------------
            if (st != T_IFG) begin
                ifg_cnt <= IFG_W'(IFG_BEATS);
            end else if (ifg_cnt != '0) begin
                ifg_cnt <= ifg_cnt - IFG_W'(1);
            end

            evt_frame_sent <= evt_frame_sent_d;
            evt_abort      <= evt_abort_d;
            evt_underrun   <= evt_underrun_d;
        end
    end

    // =========================================================================
    // Assertions
    // =========================================================================
`ifndef SYNTHESIS

    initial begin : b_elab
        if (DATA_W != 64) begin
            $fatal(1, "mac_tx: only DATA_W=64 (10GbE, 156.25 MHz) is validated, got %0d", DATA_W);
        end
        if (IFG_BEATS < 1) begin
            $fatal(1, "mac_tx: IFG_BEATS=0 is NON-CONFORMANT (802.3 requires >= 96 bit times = 12 bytes). Minimum is 1.");
        end
        if (IFG_BEATS < 2) begin
            $warning("mac_tx: IFG_BEATS=1 leaves only 16 idle bytes of margin. 2 is the project default.");
        end
    end

    // --- AXI-Stream contract: data must be stable while stalled -------------
    a_axis_stable: assert property (@(posedge clk) disable iff (rst)
        (s_axis_tvalid && !s_axis_tready) |=> (s_axis_tvalid && $stable(s_axis_tdata)
                                               && $stable(s_axis_tkeep)
                                               && $stable(s_axis_tlast))
    ) else $error("mac_tx: AXI-Stream contract violated on the input");

    // --- tkeep must be contiguous from lane 0 -------------------------------
    a_keep_contiguous: assert property (@(posedge clk) disable iff (rst)
        (s_axis_tvalid && s_axis_tlast) |->
            (s_axis_tkeep inside {8'h01,8'h03,8'h07,8'h0F,8'h1F,8'h3F,8'h7F,8'hFF})
    ) else $error("mac_tx: non-contiguous tkeep %b on tlast", s_axis_tkeep);

    // --- a start character may only ever appear in lane 0 -------------------
    a_start_lane0: assert property (@(posedge clk) disable iff (rst)
        (xgmii_txc != '0) |->
            !((xgmii_txc[1] && xgmii_txd[15:8]  == XGMII_START) ||
              (xgmii_txc[2] && xgmii_txd[23:16] == XGMII_START) ||
              (xgmii_txc[3] && xgmii_txd[31:24] == XGMII_START) ||
              (xgmii_txc[4] && xgmii_txd[39:32] == XGMII_START) ||
              (xgmii_txc[5] && xgmii_txd[47:40] == XGMII_START) ||
              (xgmii_txc[6] && xgmii_txd[55:48] == XGMII_START) ||
              (xgmii_txc[7] && xgmii_txd[63:56] == XGMII_START))
    ) else $error("mac_tx: /S/ emitted outside lane 0");

    // --- ⚠️ underrun is a design bug, not a runtime condition ---------------
    a_no_underrun: assert property (@(posedge clk) disable iff (rst)
        !evt_underrun
    ) else $error("mac_tx: TX UNDERRUN — the source starved mid-frame and the frame was aborted with a bad FCS. Size the wrapper's TX skid buffer.");

    // --- a corrupted frame is NEVER counted as sent OK ----------------------
    //     CLAUDE.md §5.7: silent failure is the worst failure mode.
    a_abort_counted: assert property (@(posedge clk) disable iff (rst)
        !(evt_frame_sent && (evt_abort || evt_underrun))
    ) else $error("mac_tx: a frame with a deliberately corrupted FCS was counted as sent OK");

    // --- the frame body never exceeds a sane bound before terminating -------
    a_bounded_body: assert property (@(posedge clk) disable iff (rst)
        (st == T_PAD) |-> ##[1:16] (st != T_PAD)
    ) else $error("mac_tx: padding state did not terminate");

`endif

endmodule : mac_tx

`default_nettype wire
