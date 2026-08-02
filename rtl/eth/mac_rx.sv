// =============================================================================
// mac_rx.sv — Cut-through 10GbE MAC receive, 64-bit datapath
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/02-networking/01-ethernet-phy-mac.md §4, §5, §6, §9
//           manuals/01-fpga-design/04-io-transceivers-and-serdes.md §5
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// =============================================================================
// ⚠️⚠️  THE CENTRAL DESIGN POINT OF THIS MODULE: SPECULATIVE FORWARDING  ⚠️⚠️
// =============================================================================
//
// The Ethernet FCS is the LAST four bytes of the frame. A cut-through MAC has
// already handed every payload byte downstream by the time it learns whether
// those bytes were valid:
//
//   t=0                                         t=end      t=end+4B
//   |------- payload streamed to the parser ----|--- FCS ---|
//                                                ^
//        the book may already be updated here    you learn it was corrupt here
//
// THIS MODULE FORWARDS FIRST AND JUDGES AFTERWARDS.
//
//   THE CONTRACT WITH DOWNSTREAM
//   ----------------------------
//   * Every beat is presented the cycle it is ready. There is NO tready.
//     Downstream MUST accept unconditionally (CLAUDE.md §5 rule 4).
//   * `m_axis_tuser` is valid ONLY on the beat where `m_axis_tlast` is high.
//     On every other beat it is driven 0 and carries no meaning.
//   * `m_axis_tuser == 1` on tlast means: THIS FRAME IS BAD. Everything you
//     were given for this frame must be treated as never having happened.
//     Bad covers: FCS mismatch, runt, oversize, XGMII /E/ error character,
//     malformed preamble, and an aborted/truncated frame.
//   * Polarity is normalized here. ⚠️ AMD's 10G/25G Ethernet Subsystem drives
//     rx_axis_tuser LOW on tlast for a BAD frame (PG210). We invert that at the
//     wrapper/PCS boundary so the rest of the design only ever sees
//     "1 == bad", per manuals/02-networking/01-ethernet-phy-mac.md §9 rule 6.
//
//   WHAT DOWNSTREAM OWES US
//   -----------------------
//   Speculative forwarding is only safe if someone can unwind. Per
//   manuals/02-networking/01-ethernet-phy-mac.md §6 the required rule set is:
//     1. the feed handler decodes speculatively, tagging updates with a frame id
//     2. book updates are journaled so one frame can be rolled back
//     3. the strategy may fire and the order encoder may fully build the frame
//     4. ⚠️ THE ORDER GATEWAY MUST NOT PUT THE FIRST BYTE OF AN ORDER ON THE
//        WIRE UNTIL frame_commit FOR THE FRAME THAT PRODUCED IT. This module
//        supplies that commit/abort signal as tlast+tuser. It is the ONLY hard
//        interlock, and it is cheap: the verdict lands ~4 bytes (3.2 ns) after
//        the last payload byte.
//     5. on abort: roll back, count rx_fcs_error, and treat the frame as a
//        MoldUDP64 sequence hole.
//   ⚠️ A speculative design with no commit gate is a working-but-wrong design.
//   It passes every clean-pcap test, runs for months in colo, and then sends a
//   real order derived from a corrupted frame the first time an optic degrades.
//
//   THE ALTERNATIVE, AND WHY IT IS REJECTED
//   ---------------------------------------
//   Store-and-forward buffers the whole frame, checks the FCS, and only then
//   releases it. Downstream needs no unwind logic at all. The cost is one full
//   frame serialization time, ALWAYS, on the happy path:
//
//        frame size |  S&F penalty @10G   (0.8 ns/byte)
//        -----------+---------------------------------
//         64 B      |    51 ns
//        100 B      |    80 ns   <- typical MoldUDP64/ITCH packet
//        512 B      |   410 ns
//       1500 B      |  1200 ns   <- blows the ENTIRE <1 us wire-to-wire budget
//       9000 B      |  7200 ns
//
//   The 1500 B row alone is the whole argument. Store-and-forward is banned on
//   the fast path (manuals/02-networking/01-ethernet-phy-mac.md §9 rule 2).
//   It is nevertheless IMPLEMENTED here behind STORE_AND_FORWARD=1 so the
//   trade-off is measurable in simulation rather than merely asserted.
//   ⚠️ Setting STORE_AND_FORWARD=1 on a market-data or order-entry link is a
//   latency regression of up to 1.2 us. It exists for experiments only.
//
// -----------------------------------------------------------------------------
// LATENCY  (STORE_AND_FORWARD = 0, the fast-path configuration)
//   XGMII beat in -> corresponding AXI-Stream beat out: 2 cycles, 12.8 ns
//   @ 156.25 MHz (6.4 ns/cycle). FIXED for every beat, including the last —
//   there is no data-dependent jitter.
//     stage 1  register the XGMII beat                       (1 cycle)
//     stage 2  register the AXI-Stream output beat           (1 cycle)
//   The end-of-frame lookahead needed to place tkeep/tlast is taken from the
//   UNREGISTERED XGMII bus, which is what buys the 2-cycle figure instead of 3.
//   This matches the "MAC RX (cut-through)  2 cyc  12.8 ns" line in the
//   fpga_top.sv latency budget.
//
//   With STORE_AND_FORWARD = 1: 2 cycles + one full frame time + 2 cycles.
//
// RESOURCE ESTIMATE (DATA_W=64, UltraScale+, STORE_AND_FORWARD=0)
//   LUT ~2500 (of which ~1800 is the crc32_eth XOR cone)
//   FF  ~250    BRAM 0    URAM 0    DSP 0
//   With STORE_AND_FORWARD=1, add ~2 BRAM36 (SF_DEPTH x 73 bit) and ~120 FF.
//
// -----------------------------------------------------------------------------
// INPUT INTERFACE — XGMII-like, 64-bit, LANE-0-ALIGNED STARTS
//   xgmii_rxd[7:0]   is the FIRST byte on the wire (lane 0).
//   xgmii_rxc[i]     is 1 when lane i holds a control character.
//   Control characters used: /I/ 0x07 idle, /S/ 0xFB start, /T/ 0xFD terminate,
//   /E/ 0xFE error.
//
//   ⚠️ CONTRACT: /S/ ONLY EVER APPEARS IN LANE 0.
//   IEEE 802.3 Clause 46 permits start-of-frame in lane 0 or lane 4 on a 64-bit
//   XGMII. Realignment is a reconciliation-sublayer job and is done in
//   gt_wrapper (real) / gt_wrapper_stub (simulation), which is also where the
//   vendor core's native AXI-Stream is normalized when the PCS+MAC variant is
//   used. Keeping it out of here keeps this module 2 cycles instead of 3.
//   A lane-4 start is DETECTED, counted as an error and dropped, never silently
//   mis-parsed — see `evt_align_err`.
//
//   ⚠️ THE GEARBOX STALL IS REAL. One cycle in 33 the 64b/66b PCS presents no
//   new data. Everything in this module is valid-qualified off the XGMII
//   control/terminate decode; nothing free-runs on an unqualified counter.
//   (manuals/02-networking/01-ethernet-phy-mac.md §2.)
//
// OUTPUT INTERFACE — AXI-Stream, no tready
//   FCS is STRIPPED (STRIP_FCS=1, the default): tkeep on the last beat excludes
//   the four FCS bytes. Set STRIP_FCS=0 to pass the FCS through to the parser.
//
// HARD RULES ENFORCED HERE (CLAUDE.md §5)
//   4. NO BACKPRESSURE. There is no tready port on this module, by design.
//      Overload is handled by dropping and counting, in eth_10g_wrapper.
//   7. Every drop and error is counted and exported as an event strobe.
//   8. Fixed latency, not low mean latency.
// =============================================================================
`default_nettype none

module mac_rx #(
    // Datapath width. 64-bit @ 156.25 MHz == 10 Gbps.
    parameter int unsigned DATA_W            = 64,
    // 0 = cut-through (REQUIRED on the fast path). 1 = store-and-forward.
    parameter int unsigned STORE_AND_FORWARD = 0,
    // Remove the 4 FCS bytes from the forwarded payload.
    parameter int unsigned STRIP_FCS         = 1,
    // IEEE 802.3 minimum frame, including FCS.
    parameter int unsigned MIN_FRAME_BYTES   = 64,
    // MTU 1500 + 14 header + 4 FCS + 4 VLAN = 1522.
    // manuals/02-networking/01-ethernet-phy-mac.md §8: MTU 1500 on all trading
    // links; oversize frames are dropped and counted.
    parameter int unsigned MAX_FRAME_BYTES   = 1522,
    // Store-and-forward buffer depth in beats. Must hold two max frames so a
    // committed frame can drain while the next one fills. Power of two.
    parameter int unsigned SF_DEPTH          = 512
) (
    input  var logic                   clk,     // recovered RX clock
    input  var logic                   rst,     // synchronous, active high

    // ── XGMII-like input from the PCS ────────────────────────────────────────
    input  var logic [DATA_W-1:0]      xgmii_rxd,
    input  var logic [DATA_W/8-1:0]    xgmii_rxc,

    // ── AXI-Stream output. NO tready — see the header. ───────────────────────
    output var logic [DATA_W-1:0]      m_axis_tdata,
    output var logic [DATA_W/8-1:0]    m_axis_tkeep,
    output var logic                   m_axis_tvalid,
    output var logic                   m_axis_tlast,
    output var logic                   m_axis_tuser,   // 1 on tlast == BAD FRAME

    // ── Telemetry: single-cycle strobes, one per frame ───────────────────────
    output var logic                   evt_frame_ok,
    output var logic                   evt_fcs_err,
    output var logic                   evt_runt,
    output var logic                   evt_oversize,
    output var logic                   evt_align_err,  // /S/ not in lane 0
    output var logic                   evt_sf_drop     // S&F buffer overflow
);

    // -------------------------------------------------------------------------
    // Local constants
    // -------------------------------------------------------------------------
    localparam int unsigned KEEP_W  = DATA_W / 8;               // 8
    localparam int unsigned LANE_W  = $clog2(KEEP_W);           // 3
    localparam int unsigned CNT_W   = $clog2(KEEP_W + 1);       // 4
    localparam int unsigned BYTES_W = 16;                       // frame byte counter

    localparam logic [7:0] XGMII_IDLE  = 8'h07;
    localparam logic [7:0] XGMII_START = 8'hFB;
    localparam logic [7:0] XGMII_TERM  = 8'hFD;
    localparam logic [7:0] XGMII_ERR   = 8'hFE;
    localparam logic [7:0] ETH_PRE     = 8'h55;
    localparam logic [7:0] ETH_SFD     = 8'hD5;

    localparam logic [31:0] CRC_INIT    = 32'hFFFF_FFFF;
    localparam logic [31:0] CRC_RESIDUE = 32'hDEBB_20E3;   // see crc32_eth.sv

    // Number of trailing bytes the FCS occupies in the forwarded payload.
    localparam int unsigned FCS_BYTES = (STRIP_FCS != 0) ? 4 : 0;

    // keep-mask helper: n valid bytes -> n low bits set. n may be 0..KEEP_W.
    function automatic logic [KEEP_W-1:0] keep_mask(input logic [CNT_W-1:0] n);
        logic [KEEP_W:0] m;
        begin
            m = ({{KEEP_W{1'b0}}, 1'b1} << n) - {{KEEP_W{1'b0}}, 1'b1};
            keep_mask = m[KEEP_W-1:0];
        end
    endfunction

    // =========================================================================
    // 1. Lookahead decode of the UNREGISTERED XGMII beat
    //    This is beat B while the registered stage holds beat B-1. Seeing B is
    //    what lets us mark B-1 as the last beat and place its tkeep.
    //    Combinational, but shallow: 8 byte compares plus a priority pick.
    // =========================================================================
    logic              la_start;      // /S/ in lane 0 (legal start)
    logic              la_start_mis;  // /S/ in a lane other than 0 (illegal)
    logic              la_term;       // /T/ present
    logic [LANE_W-1:0] la_tpos;       // lane index of /T/
    logic              la_ctrl_err;   // /E/, or an unexpected control char

    always_comb begin
        la_start     = xgmii_rxc[0] && (xgmii_rxd[7:0] == XGMII_START);
        la_start_mis = 1'b0;
        la_term      = 1'b0;
        la_tpos      = '0;
        la_ctrl_err  = 1'b0;

        for (int unsigned i = 0; i < KEEP_W; i++) begin
            if (xgmii_rxc[i]) begin
                if (xgmii_rxd[i*8 +: 8] == XGMII_TERM) begin
                    if (!la_term) begin
                        la_term = 1'b1;
                        la_tpos = LANE_W'(i);
                    end
                end else if (xgmii_rxd[i*8 +: 8] == XGMII_ERR) begin
                    la_ctrl_err = 1'b1;
                end else if (xgmii_rxd[i*8 +: 8] == XGMII_START) begin
                    // /S/ anywhere but lane 0 violates the alignment contract.
                    if (i != 0) begin
                        la_start_mis = 1'b1;
                    end
                end else if (!la_term) begin
                    // Any other control character before the terminate (e.g. an
                    // idle appearing mid-frame) means the frame is broken.
                    la_ctrl_err = 1'b1;
                end
            end
        end
    end

    // Preamble sanity on a start beat: /S/ 55 55 55 55 55 55 D5.
    logic la_pre_ok;
    always_comb begin
        la_pre_ok = (xgmii_rxd[63:56] == ETH_SFD);
        for (int unsigned i = 1; i < KEEP_W-1; i++) begin
            if (xgmii_rxd[i*8 +: 8] != ETH_PRE) begin
                la_pre_ok = 1'b0;
            end
        end
    end

    // =========================================================================
    // 2. Stage 1 — registered XGMII beat. This is the beat that gets EMITTED.
    // =========================================================================
    typedef enum logic [1:0] {
        S_IDLE  = 2'd0,   // d_q holds nothing of interest (or the start beat)
        S_DATA  = 2'd1,   // d_q holds a frame data beat, emit it
        S_TAIL  = 2'd2,   // d_q holds the final ragged beat, emit it
        S_FLUSH = 2'd3    // frame abandoned; discard until /T/
    } rx_state_e;

    rx_state_e               st;
    logic [DATA_W-1:0]       d_q;         // beat B-1  (datapath: no reset)
    logic                    dq_start;    // d_q is the /S/ preamble beat
    logic                    dq_pre_ok;   // that preamble was well formed
    logic [31:0]             crc_q;       // CRC over frame beats up to B-1
    logic [BYTES_W-1:0]      frm_bytes;   // frame bytes counted up to B-1
    logic                    err_q;       // sticky "this frame is bad"
    logic [KEEP_W-1:0]       tail_keep;   // latched for S_TAIL
    logic                    tail_user;

    // =========================================================================
    // 3. CRC
    //    ONE crc32_eth instance serves both jobs, because they never coincide:
    //      * on a normal beat  -> bytes = 8, result feeds crc_q   (accumulate)
    //      * on a /T/ beat     -> bytes = la_tpos, result is FINAL (no accumulate)
    //    When /T/ lands in lane 0 the terminate beat contributes no frame bytes,
    //    bytes = 0, and crc32_eth returns crc_in unchanged — so `crc_res` is the
    //    correct final value in that case too, with zero extra logic.
    //
    //    Alignment proof. crc_q is updated from the UNREGISTERED beat, so at any
    //    cycle where the raw bus holds beat B, crc_q already covers beats
    //    F0..B-1 — i.e. it covers d_q. Therefore:
    //      /T/ in lane 0     : last frame byte ends d_q  -> final = crc_q
    //      /T/ in lane k>0   : last k bytes are in B     -> final = step(crc_q,B,k)
    //    Exactly one combinational CRC step on the critical path, never two.
    // =========================================================================
    logic [31:0]      crc_seed;
    logic [CNT_W-1:0] crc_bytes;
    logic [31:0]      crc_res;
    logic             fcs_ok;

    // The first frame beat seeds with the all-ones init value.
    assign crc_seed  = (st == S_IDLE) ? CRC_INIT : crc_q;
    assign crc_bytes = la_term ? {1'b0, la_tpos} : CNT_W'(KEEP_W);
    assign fcs_ok    = (crc_res == CRC_RESIDUE);

    crc32_eth #(
        .DATA_W          (DATA_W),
        .PARTIAL_SUPPORT (1)
    ) u_crc (
        .crc_in  (crc_seed),
        .data    (xgmii_rxd),
        .bytes   (crc_bytes),
        .crc_out (crc_res)
    );

    // Is the raw bus presenting a complete 8-byte frame data beat this cycle?
    logic raw_is_frame_beat;
    logic accumulate;
    assign raw_is_frame_beat = ((st == S_IDLE) && dq_start) || (st == S_DATA);
    assign accumulate        = raw_is_frame_beat && !la_term && !la_start;

    // =========================================================================
    // 4. Frame geometry at the terminate
    // =========================================================================
    logic [BYTES_W-1:0] total_bytes;      // whole frame, FCS included
    logic               is_runt;
    logic               oversize_now;
    logic               err_now;

    assign total_bytes  = frm_bytes + BYTES_W'(la_tpos);
    assign is_runt      = (total_bytes < BYTES_W'(MIN_FRAME_BYTES));
    assign oversize_now = (frm_bytes   > BYTES_W'(MAX_FRAME_BYTES));
    assign err_now      = err_q | la_ctrl_err | la_start_mis | !dq_pre_ok;

    // =========================================================================
    // 5. Cut-through beat generation (combinational -> registered below)
    // =========================================================================
    logic [DATA_W-1:0] ct_tdata_d;
    logic [KEEP_W-1:0] ct_tkeep_d;
    logic              ct_tvalid_d;
    logic              ct_tlast_d;
    logic              ct_tuser_d;
    rx_state_e         st_d;
    logic [KEEP_W-1:0] tail_keep_d;
    logic              tail_user_d;

    logic evt_frame_ok_d, evt_fcs_err_d, evt_runt_d, evt_oversize_d, evt_align_err_d;

    always_comb begin
        // ---- defaults: no latches, ever (coding standard §3) ---------------
        ct_tdata_d      = d_q;
        ct_tkeep_d      = {KEEP_W{1'b1}};
        ct_tvalid_d     = 1'b0;
        ct_tlast_d      = 1'b0;
        ct_tuser_d      = 1'b0;
        st_d            = st;
        tail_keep_d     = tail_keep;
        tail_user_d     = tail_user;
        evt_frame_ok_d  = 1'b0;
        evt_fcs_err_d   = 1'b0;
        evt_runt_d      = 1'b0;
        evt_oversize_d  = 1'b0;
        evt_align_err_d = la_start_mis;

        unique case (st)
            // -----------------------------------------------------------------
            S_IDLE: begin
                // d_q holds the preamble beat exactly when dq_start is set; the
                // raw bus is then the first frame data beat and S_DATA follows.
                // The preamble itself is never forwarded.
                if (dq_start) begin
                    // Degenerate case: a frame that terminates before a single
                    // full data beat exists. Nothing can be forwarded; discard.
                    // The terminate is already consumed here, so return to
                    // S_IDLE directly rather than flushing to the next /T/.
                    st_d       = la_term ? S_IDLE : S_DATA;
                    evt_runt_d = la_term;
                end
            end

            // -----------------------------------------------------------------
            S_DATA: begin
                // d_q = beat B-1 (a frame data beat). Raw bus = beat B.
                ct_tvalid_d = 1'b1;

                if (la_term) begin
                    // ---- end of frame -------------------------------------
                    // la_tpos = number of frame bytes carried by beat B.
                    // The last FCS_BYTES bytes of the frame are stripped.
                    ct_tuser_d     = err_now | !fcs_ok | is_runt;
                    evt_fcs_err_d  = !fcs_ok;
                    evt_runt_d     = is_runt;
                    evt_frame_ok_d = !(err_now | !fcs_ok | is_runt);

                    if (la_tpos <= LANE_W'(FCS_BYTES)) begin
                        // The FCS ends inside (or exactly at the end of) d_q.
                        // Payload keeps KEEP_W - (FCS_BYTES - la_tpos) bytes.
                        // la_tpos == 0 is the "/T/ in lane 0" case and lands
                        // here too: keep = 8 - 4 = 4 bytes.
                        ct_tkeep_d = keep_mask(CNT_W'(KEEP_W) -
                                               (CNT_W'(FCS_BYTES) - {1'b0, la_tpos}));
                        ct_tlast_d = 1'b1;
                        st_d       = S_IDLE;
                    end else begin
                        // Payload continues into beat B: emit d_q in full now,
                        // and the ragged remainder next cycle from S_TAIL.
                        ct_tkeep_d  = {KEEP_W{1'b1}};
                        ct_tlast_d  = 1'b0;
                        tail_keep_d = keep_mask({1'b0, la_tpos} - CNT_W'(FCS_BYTES));
                        tail_user_d = err_now | !fcs_ok | is_runt;
                        st_d        = S_TAIL;
                    end

                end else if (oversize_now) begin
                    // ---- oversize: truncate here, mark bad, flush the rest --
                    ct_tkeep_d     = {KEEP_W{1'b1}};
                    ct_tlast_d     = 1'b1;
                    ct_tuser_d     = 1'b1;
                    evt_oversize_d = 1'b1;
                    st_d           = S_FLUSH;

                end else if (la_start) begin
                    // ---- a new /S/ inside a frame: the current one is lost --
                    ct_tlast_d = 1'b1;
                    ct_tuser_d = 1'b1;
                    st_d       = S_IDLE;     // dq_start will pick the new frame up

                end else begin
                    // ---- ordinary mid-frame beat ---------------------------
                    ct_tkeep_d = {KEEP_W{1'b1}};
                    ct_tlast_d = 1'b0;
                end
            end

            // -----------------------------------------------------------------
            S_TAIL: begin
                // d_q = the terminate beat; lanes below tail_keep are payload.
                ct_tvalid_d = 1'b1;
                ct_tkeep_d  = tail_keep;
                ct_tlast_d  = 1'b1;
                ct_tuser_d  = tail_user;
                st_d        = S_IDLE;
            end

            // -----------------------------------------------------------------
            S_FLUSH: begin
                if (la_term) begin
                    st_d = S_IDLE;
                end
            end

            default: st_d = S_IDLE;
        endcase

        // A misaligned /S/ can never be parsed; abandon whatever is in flight.
        if (la_start_mis) begin
            st_d = S_FLUSH;
        end
    end

    // =========================================================================
    // 6. Stage 1 / stage 2 registers
    //    Reset covers control state only (coding standard §6). d_q, crc_q and
    //    the data half of the output are datapath and are deliberately not reset.
    // =========================================================================
    logic [DATA_W-1:0] ct_tdata;
    logic [KEEP_W-1:0] ct_tkeep;
    logic              ct_tvalid;
    logic              ct_tlast;
    logic              ct_tuser;

    always_ff @(posedge clk) begin
        // ---- stage 1: capture the XGMII beat ------------------------------
        d_q       <= xgmii_rxd;

        // ---- stage 2: the AXI-Stream beat ---------------------------------
        ct_tdata  <= ct_tdata_d;
        ct_tkeep  <= ct_tkeep_d;
        ct_tlast  <= ct_tlast_d;
        ct_tuser  <= ct_tuser_d;

        // ---- CRC / byte accounting ----------------------------------------
        if (accumulate) begin
            crc_q     <= crc_res;
            frm_bytes <= ((st == S_IDLE) ? BYTES_W'(0) : frm_bytes) + BYTES_W'(KEEP_W);
        end

        tail_keep <= tail_keep_d;
        tail_user <= tail_user_d;

        if (rst) begin
            st            <= S_IDLE;
            dq_start      <= 1'b0;
            dq_pre_ok     <= 1'b1;
            ct_tvalid     <= 1'b0;
            err_q         <= 1'b0;
            frm_bytes     <= '0;
            evt_frame_ok  <= 1'b0;
            evt_fcs_err   <= 1'b0;
            evt_runt      <= 1'b0;
            evt_oversize  <= 1'b0;
            evt_align_err <= 1'b0;
        end else begin
            st        <= st_d;
            dq_start  <= la_start;
            dq_pre_ok <= la_start ? la_pre_ok : dq_pre_ok;
            ct_tvalid <= ct_tvalid_d;

            // Sticky per-frame error flag: armed at the start beat, accumulated
            // across the frame, consumed at tlast.
            if (la_start) begin
                err_q <= !la_pre_ok;
            end else if (st != S_IDLE) begin
                err_q <= err_q | la_ctrl_err;
            end else begin
                err_q <= 1'b0;
            end

            evt_frame_ok  <= evt_frame_ok_d;
            evt_fcs_err   <= evt_fcs_err_d;
            evt_runt      <= evt_runt_d;
            evt_oversize  <= evt_oversize_d;
            evt_align_err <= evt_align_err_d;
        end
    end

    // =========================================================================
    // 7. Output stage — cut-through, or the store-and-forward experiment
    // =========================================================================
    generate
    if (STORE_AND_FORWARD == 0) begin : g_cut_through

        // ---------------------------------------------------------------------
        // THE FAST PATH. Beats leave the moment they are formed; the verdict
        // rides on tuser at tlast. 2 cycles, fixed.
        // ---------------------------------------------------------------------
        assign m_axis_tdata  = ct_tdata;
        assign m_axis_tkeep  = ct_tkeep;
        assign m_axis_tvalid = ct_tvalid;
        assign m_axis_tlast  = ct_tlast;
        assign m_axis_tuser  = ct_tuser;
        assign evt_sf_drop   = 1'b0;

    end else begin : g_store_forward

        // ---------------------------------------------------------------------
        // ⚠️ STORE-AND-FORWARD. NOT FOR THE FAST PATH. Costs a full frame time
        // (up to 1.2 us at 1500 B / 10G). Present only so the trade-off can be
        // measured rather than argued about.
        //
        // Circular buffer with a COMMIT pointer:
        //   wr_ptr advances speculatively as beats arrive
        //   on a good tlast : cm_ptr <- wr_ptr        (frame becomes visible)
        //   on a bad  tlast : wr_ptr <- cm_ptr        (frame rewound, never seen)
        //   the read side only ever consumes up to cm_ptr
        // Downstream therefore never sees a bad frame and m_axis_tuser is 0.
        // ---------------------------------------------------------------------
        localparam int unsigned SF_AW = $clog2(SF_DEPTH);
        localparam int unsigned SF_W  = DATA_W + KEEP_W + 1;   // {tlast,tkeep,tdata}

        logic [SF_W-1:0] sf_mem [SF_DEPTH];
        logic [SF_AW:0]  wr_ptr, cm_ptr, rd_ptr;
        logic [SF_AW:0]  occ;
        logic            sf_full;
        logic            sf_drop_q;      // this frame overflowed the buffer

        assign occ     = wr_ptr - rd_ptr;
        assign sf_full = (occ >= (SF_AW+1)'(SF_DEPTH));

        always_ff @(posedge clk) begin
            if (rst) begin
                wr_ptr      <= '0;
                cm_ptr      <= '0;
                sf_drop_q   <= 1'b0;
                evt_sf_drop <= 1'b0;
            end else begin
                evt_sf_drop <= 1'b0;

                if (ct_tvalid) begin
                    if (sf_full && !sf_drop_q) begin
                        sf_drop_q   <= 1'b1;
                        evt_sf_drop <= 1'b1;
                    end else if (!sf_drop_q) begin
                        sf_mem[wr_ptr[SF_AW-1:0]] <= {ct_tlast, ct_tkeep, ct_tdata};
                        wr_ptr <= wr_ptr + (SF_AW+1)'(1);
                    end

                    if (ct_tlast) begin
                        if (ct_tuser || sf_drop_q || sf_full) begin
                            wr_ptr <= cm_ptr;               // rewind: frame vanishes
                        end else begin
                            cm_ptr <= wr_ptr + (SF_AW+1)'(1);
                        end
                        sf_drop_q <= 1'b0;
                    end
                end
            end
        end

        always_ff @(posedge clk) begin
            // Datapath read: no reset.
            {m_axis_tlast, m_axis_tkeep, m_axis_tdata} <= sf_mem[rd_ptr[SF_AW-1:0]];

            if (rst) begin
                rd_ptr        <= '0;
                m_axis_tvalid <= 1'b0;
            end else begin
                m_axis_tvalid <= 1'b0;
                if (cm_ptr != rd_ptr) begin
                    m_axis_tvalid <= 1'b1;
                    rd_ptr        <= rd_ptr + (SF_AW+1)'(1);
                end
            end
        end

        // A released frame passed its FCS check by construction.
        assign m_axis_tuser = 1'b0;

    end
    endgenerate

    // =========================================================================
    // 8. Assertions — stream contract and design invariants
    // =========================================================================
`ifndef SYNTHESIS

    initial begin : b_elab
        if (DATA_W != 64) begin
            $fatal(1, "mac_rx: only DATA_W=64 (10GbE, 156.25 MHz) is validated, got %0d", DATA_W);
        end
        if (STORE_AND_FORWARD != 0) begin
            $warning("mac_rx: STORE_AND_FORWARD=1 costs a FULL FRAME TIME (up to 1.2 us at 10G). Fast path must use 0.");
        end
        if ((SF_DEPTH & (SF_DEPTH-1)) != 0) begin
            $fatal(1, "mac_rx: SF_DEPTH must be a power of two, got %0d", SF_DEPTH);
        end
    end

    // --- tuser is meaningful ONLY on tlast; it must be 0 otherwise -----------
    a_tuser_only_on_tlast: assert property (@(posedge clk) disable iff (rst)
        (m_axis_tvalid && !m_axis_tlast) |-> !m_axis_tuser
    ) else $error("mac_rx: tuser asserted on a non-last beat — the FCS contract says it is only valid at tlast");

    // --- tkeep must be contiguous from lane 0 (an AXI-Stream requirement) ---
    a_tkeep_contiguous: assert property (@(posedge clk) disable iff (rst)
        m_axis_tvalid |-> (m_axis_tkeep == keep_mask(CNT_W'($countones(m_axis_tkeep))))
    ) else $error("mac_rx: non-contiguous tkeep %b", m_axis_tkeep);

    // --- every non-last beat is a full beat ---------------------------------
    a_full_mid_beats: assert property (@(posedge clk) disable iff (rst)
        (m_axis_tvalid && !m_axis_tlast) |-> (m_axis_tkeep == {KEEP_W{1'b1}})
    ) else $error("mac_rx: partial tkeep on a non-last beat");

    // --- tkeep is never zero on a valid beat --------------------------------
    a_keep_nonzero: assert property (@(posedge clk) disable iff (rst)
        m_axis_tvalid |-> (m_axis_tkeep != '0)
    ) else $error("mac_rx: valid beat with tkeep == 0");

    // --- CLAUDE.md §5.4: there is no tready. Prove no one added one. --------
    //     A frame must always terminate: once a frame starts, tlast must follow
    //     within the beats of one maximum-size frame. If it does not, the frame
    //     delineation logic is wedged.
    a_frame_terminates: assert property (@(posedge clk) disable iff (rst)
        (m_axis_tvalid && !m_axis_tlast) |->
            ##[1:(MAX_FRAME_BYTES/KEEP_W + 4)] (m_axis_tvalid && m_axis_tlast)
    ) else $error("mac_rx: frame did not terminate within one max-frame time");

    // --- exactly one telemetry verdict per completed frame ------------------
    a_one_verdict: assert property (@(posedge clk) disable iff (rst)
        evt_frame_ok |-> !(evt_fcs_err || evt_runt || evt_oversize)
    ) else $error("mac_rx: frame counted as both good and bad");

    // --- the alignment contract from the header -----------------------------
    a_start_lane0: assert property (@(posedge clk) disable iff (rst)
        !evt_align_err
    ) else $error("mac_rx: /S/ seen outside lane 0 — the PCS shim is not realigning starts (see module header)");

`endif

endmodule : mac_rx

`default_nettype wire
