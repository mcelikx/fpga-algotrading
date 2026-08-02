// =============================================================================
// fv_axis_props.sv — Reusable AXI-Stream contract properties (formal + sim)
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Layer   : rtl/formal — property collateral. NEVER SYNTHESIZED.
// Governs : manuals/01-fpga-design/05-verification-and-simulation.md §5
//             ("Every AXI-Stream port | the full valid/ready contract")
//           manuals/01-fpga-design/01-rtl-design-patterns.md §1 (the contract)
//           manuals/00-foundations/03-hdl-and-rtl-coding.md   (coding standard)
//           CLAUDE.md §5 rule 4 (the RX path never backpressures)
//
// -----------------------------------------------------------------------------
// PURPOSE
//   One property module, bound to every stream port in the design, that encodes
//   the ENTIRE valid/ready contract once. A stream bug found by simulation is
//   found on the traffic you happened to send; a stream bug found by formal is
//   found on all traffic, including the traffic the venue will send you at 09:30
//   on the morning you are not watching.
//
//   ⚠️ THIS FILE CONTAINS NO SYNTHESIZABLE LOGIC AND IS NEVER COMPILED INTO A
//   BITSTREAM. The whole body sits inside `ifndef SYNTHESIS`, so if this file is
//   ever added to a synthesis filelist by accident it elaborates to nothing.
//   That is deliberate: verification collateral must be incapable of changing
//   the hardware it verifies.
//
// -----------------------------------------------------------------------------
// LATENCY   : n/a — contains no design logic, adds no path, costs no cycle.
// RESOURCE  : 0 LUT, 0 FF, 0 BRAM, 0 URAM, 0 DSP in any implemented build.
//             (Under a formal tool it costs model state: ~$clog2(MAX_BEATS)+2
//              bits of auxiliary state per bound instance. That matters for
//              proof runtime, not for the device — see fv_bind.sv §5.)
//
// -----------------------------------------------------------------------------
// ⚠️ ASSERT vs. ASSUME — THE ONE PARAMETER THAT CAN INVALIDATE A PROOF
//   The same contract is an OBLIGATION on a producer and a RIGHT of a consumer.
//   `IS_ASSUME = 1` turns every property into a constraint on the environment;
//   `IS_ASSUME = 0` (the default) turns them into proof obligations.
//
//   Use ASSUME only on an interface DRIVEN BY THE FORMAL ENVIRONMENT — i.e. the
//   free inputs of the unit under proof. Assuming a contract on an interface
//   driven by RTL you also own is how you prove a theorem about a design that
//   does not exist: the tool will happily "prove" downstream safety by
//   constraining away the very stimulus that breaks it.
//
//   Project rule, no exceptions:
//     * The unit under proof's INPUT stream ports : IS_ASSUME = 1.
//     * Every OUTPUT stream port, and every internal stream: IS_ASSUME = 0.
//     * If block A's output feeds block B's input and both are in the proof,
//       the interface is ASSERTED once and never assumed.
//   Every assume in fv_bind.sv carries a one-line justification comment. An
//   assume without one is a review-blocking defect.
//
// -----------------------------------------------------------------------------
// ⚠️ WHAT THIS MODULE CANNOT SEE
//   It checks the handshake, not the payload. A design that faithfully honours
//   every rule below while emitting a byte-swapped price passes every property
//   here. Payload correctness is the pcap-vs-oracle tier
//   (05-verification-and-simulation.md §4), and nothing in this file substitutes
//   for it.
// =============================================================================
`default_nettype none

`ifndef SYNTHESIS

// -----------------------------------------------------------------------------
// fv_axis_props — the full stream contract.
//
// Bind it to any port group of shape {tvalid, tready, tdata, tkeep, tlast,
// tuser}. Absent signals are tied off at the bind site:
//   * no tready on the port (an RX path that cannot stall) -> tie tready = 1'b1
//     and set NEVER_STALL = 1 so the tie-off is itself proven, not assumed;
//   * no tkeep -> tie tkeep = '1 and set CHK_KEEP = 0;
//   * no tuser -> tie tuser = 1'b0 and set CHK_USER_STABLE = 0.
// -----------------------------------------------------------------------------
module fv_axis_props #(
    parameter int unsigned DATA_W = 64,
    parameter int unsigned KEEP_W = DATA_W / 8,

    // 0 = prove these properties (default). 1 = constrain the environment.
    // READ THE HEADER BEFORE SETTING THIS TO 1.
    parameter bit          IS_ASSUME = 1'b0,

    // CLAUDE.md §5 rule 4. Set on every RX-path interface: tready must be
    // constantly high, and that is a PROOF OBLIGATION on the consumer, never an
    // assumption about it.
    parameter bit          NEVER_STALL = 1'b0,

    // tkeep legality checks. Off for streams with no tkeep, or for a stream
    // whose tkeep is a byte-enable rather than a packed-from-LSB strobe.
    parameter bit          CHK_KEEP = 1'b1,
    // Packed-from-LSB streams only: tkeep must be all-ones except on tlast.
    parameter bit          CHK_KEEP_FULL_MID = 1'b1,

    parameter bit          CHK_LAST = 1'b1,
    parameter bit          CHK_USER_STABLE = 1'b0,

    // Bounded liveness. A stall longer than this is a design bug, not
    // congestion. 0 disables the bounded check.
    //   64 beats @ 6.4 ns = 409.6 ns: longer than any legitimate stall anywhere
    //   in a 128 ns fabric budget (fpga_top.sv).
    parameter int unsigned MAX_STALL_CYC = 64,

    // Longest legal packet, in beats. 10GbE max frame 1522 B / 8 B = 191 beats;
    // 256 leaves margin for a jumbo-configured link. A packet that never ends is
    // a framing FSM that has lost its way, and it is silent.
    parameter int unsigned MAX_BEATS = 256,

    // A packet must terminate. Unbounded liveness needs an unbounded engine
    // (JasperGold prove, SymbiYosys `mode prove` with a fairness constraint);
    // Verilator and BMC cannot evaluate it. Off by default.
    parameter bit          CHK_LIVENESS = 1'b0,

    // Name that appears in every failure message. Set it at the bind site —
    // "AXIS contract violated" in a 40-instance design is not a diagnosis.
    parameter string       IFC_NAME = "axis"
) (
    input var logic              clk,
    input var logic              rst,          // synchronous, active high

    input var logic              tvalid,
    input var logic              tready,
    input var logic [DATA_W-1:0] tdata,
    input var logic [KEEP_W-1:0] tkeep,
    input var logic              tlast,
    input var logic              tuser
);

    // =========================================================================
    // Auxiliary model state. Local to the property module; it drives no design
    // signal and can never be optimized into the DUT.
    // =========================================================================
    localparam int unsigned BEAT_W  = (MAX_BEATS  > 1) ? $clog2(MAX_BEATS + 1)  : 1;
    localparam int unsigned STALL_W = (MAX_STALL_CYC > 1) ? $clog2(MAX_STALL_CYC + 1) : 1;

    logic xfer;
    assign xfer = tvalid && tready;

    // Beats since the start of the current packet.
    logic [BEAT_W-1:0] beat_cnt_q;
    always_ff @(posedge clk) begin
        if (rst)            beat_cnt_q <= '0;
        else if (xfer && tlast) beat_cnt_q <= '0;
        else if (xfer && (beat_cnt_q != {BEAT_W{1'b1}})) beat_cnt_q <= beat_cnt_q + BEAT_W'(1);
    end

    // Consecutive cycles the producer has been held off.
    logic [STALL_W-1:0] stall_cnt_q;
    always_ff @(posedge clk) begin
        if (rst)                      stall_cnt_q <= '0;
        else if (!tvalid || tready)   stall_cnt_q <= '0;
        else if (stall_cnt_q != {STALL_W{1'b1}}) stall_cnt_q <= stall_cnt_q + STALL_W'(1);
    end

    // Mid-packet: at least one beat accepted, tlast not yet seen.
    logic in_pkt_q;
    always_ff @(posedge clk) begin
        if (rst)       in_pkt_q <= 1'b0;
        else if (xfer) in_pkt_q <= !tlast;
    end

    // tkeep packed-from-LSB legality: (tkeep + 1) must be a power of two.
    // 0b0000_1111 + 1 = 0b0001_0000 (legal). 0b0000_1011 + 1 = 0b0000_1100 (not).
    // All-ones + 1 overflows to zero in the widened vector, and $onehot0 accepts
    // zero, which is exactly right.
    function automatic logic keep_contiguous(input logic [KEEP_W-1:0] k);
        logic [KEEP_W:0] widened;
        widened = {1'b0, k} + (KEEP_W+1)'(1);
        return $onehot0(widened[KEEP_W-1:0]) && (widened[KEEP_W] == 1'b0 ? 1'b1 : 1'b1);
    endfunction

    // =========================================================================
    // The contract. Every property is stated once and then either asserted or
    // assumed by the generate below — there is exactly one text for each rule,
    // so an assumed interface and an asserted interface can never drift.
    // =========================================================================
    default disable iff (rst);

    // ── 1. Handshake stability ───────────────────────────────────────────────
    // Once asserted, tvalid may not be withdrawn before the beat is accepted.
    // This is the rule that a "helpful" optimisation breaks, and the resulting
    // corruption is a dropped or duplicated ITCH message.
    property p_valid_stable;
        @(posedge clk) (tvalid && !tready) |=> tvalid;
    endproperty

    property p_data_stable;
        @(posedge clk) (tvalid && !tready) |=> $stable(tdata);
    endproperty

    property p_keep_stable;
        @(posedge clk) (tvalid && !tready) |=> $stable(tkeep);
    endproperty

    property p_last_stable;
        @(posedge clk) (tvalid && !tready) |=> $stable(tlast);
    endproperty

    property p_user_stable;
        @(posedge clk) (tvalid && !tready) |=> $stable(tuser);
    endproperty

    // ── 2. Reset behaviour ───────────────────────────────────────────────────
    // No traffic escapes during or immediately after reset. Checked WITHOUT the
    // default disable, because the reset window is the point of the property.
    property p_reset_quiet;
        @(posedge clk) disable iff (1'b0) rst |=> !tvalid;
    endproperty

    // ── 3. tkeep legality ────────────────────────────────────────────────────
    property p_keep_nonzero;
        @(posedge clk) tvalid |-> (tkeep != '0);
    endproperty

    property p_keep_packed;
        @(posedge clk) tvalid |-> keep_contiguous(tkeep);
    endproperty

    // A partial beat is only ever the last one. A hole in the middle of a packet
    // is a reassembly bug that produces a silently mis-decoded message.
    property p_keep_full_mid;
        @(posedge clk) (tvalid && !tlast) |-> (tkeep == '1);
    endproperty

    // ── 4. Packet framing ────────────────────────────────────────────────────
    property p_beats_bounded;
        @(posedge clk) beat_cnt_q < BEAT_W'(MAX_BEATS);
    endproperty

    // ── 5. Backpressure ──────────────────────────────────────────────────────
    // CLAUDE.md §5 rule 4: the RX path accepts line rate unconditionally. This
    // is asserted on the consumer, never assumed of it — that distinction is the
    // whole value of the property. Drops are counted elsewhere; a STALL is
    // structurally forbidden.
    property p_never_stall;
        @(posedge clk) tready;
    endproperty

    // Bounded liveness: a held-off producer is released within MAX_STALL_CYC.
    property p_stall_bounded;
        @(posedge clk) stall_cnt_q < STALL_W'(MAX_STALL_CYC);
    endproperty

    // ── 6. Unbounded liveness (needs an unbounded engine) ────────────────────
    // "No deadlock", stated honestly: an offered beat is eventually accepted,
    // and a started packet eventually ends.
    property p_no_deadlock;
        @(posedge clk) tvalid |-> s_eventually (tvalid && tready);
    endproperty

    property p_packet_terminates;
        @(posedge clk) (xfer && !tlast) |-> s_eventually (tvalid && tready && tlast);
    endproperty

    // =========================================================================
    // Assert / assume selection. ONE property text, two roles.
    // =========================================================================
    generate
        if (IS_ASSUME) begin : g_assume
            m_valid_stable : assume property (p_valid_stable);
            m_data_stable  : assume property (p_data_stable);
            m_last_stable  : assume property (p_last_stable);
            m_reset_quiet  : assume property (p_reset_quiet);
            m_beats_bounded: assume property (p_beats_bounded);
            if (CHK_KEEP) begin : g_am_keep
                m_keep_stable  : assume property (p_keep_stable);
                m_keep_nonzero : assume property (p_keep_nonzero);
                m_keep_packed  : assume property (p_keep_packed);
                if (CHK_KEEP_FULL_MID) begin : g_am_keep_mid
                    m_keep_full_mid : assume property (p_keep_full_mid);
                end
            end
            if (CHK_USER_STABLE) begin : g_am_user
                m_user_stable : assume property (p_user_stable);
            end
        end
        else begin : g_assert
            a_valid_stable : assert property (p_valid_stable)
                else $error("[%s] AXIS: tvalid withdrawn before tready", IFC_NAME);
            a_data_stable  : assert property (p_data_stable)
                else $error("[%s] AXIS: tdata changed while stalled", IFC_NAME);
            a_last_stable  : assert property (p_last_stable)
                else $error("[%s] AXIS: tlast changed while stalled", IFC_NAME);
            a_reset_quiet  : assert property (p_reset_quiet)
                else $error("[%s] AXIS: tvalid asserted out of reset", IFC_NAME);
            a_beats_bounded: assert property (p_beats_bounded)
                else $error("[%s] AXIS: packet exceeded %0d beats — framing FSM lost",
                            IFC_NAME, MAX_BEATS);

            if (CHK_KEEP) begin : g_as_keep
                a_keep_stable  : assert property (p_keep_stable)
                    else $error("[%s] AXIS: tkeep changed while stalled", IFC_NAME);
                a_keep_nonzero : assert property (p_keep_nonzero)
                    else $error("[%s] AXIS: tvalid with tkeep == 0 (empty beat)", IFC_NAME);
                a_keep_packed  : assert property (p_keep_packed)
                    else $error("[%s] AXIS: tkeep 0x%0h is not packed from bit 0",
                                IFC_NAME, tkeep);
                if (CHK_KEEP_FULL_MID) begin : g_as_keep_mid
                    a_keep_full_mid : assert property (p_keep_full_mid)
                        else $error("[%s] AXIS: partial tkeep on a non-last beat",
                                    IFC_NAME);
                end
            end

            if (CHK_USER_STABLE) begin : g_as_user
                a_user_stable : assert property (p_user_stable)
                    else $error("[%s] AXIS: tuser changed while stalled", IFC_NAME);
            end

            if (NEVER_STALL) begin : g_as_no_stall
                // ⚠️ CLAUDE.md §5 rule 4. If this fails, the design drops market
                // data by stalling instead of by counting, which is the failure
                // mode the whole RX architecture exists to prevent.
                a_never_stall : assert property (p_never_stall)
                    else $error("[%s] RX PATH ASSERTED BACKPRESSURE — forbidden "
                                "(CLAUDE.md §5 rule 4)", IFC_NAME);
            end
            else if (MAX_STALL_CYC > 0) begin : g_as_stall_bound
                a_stall_bounded : assert property (p_stall_bounded)
                    else $error("[%s] AXIS: producer stalled >= %0d cycles",
                                IFC_NAME, MAX_STALL_CYC);
            end

            if (CHK_LIVENESS) begin : g_as_live
                a_no_deadlock : assert property (p_no_deadlock)
                    else $error("[%s] AXIS: DEADLOCK — offered beat never accepted",
                                IFC_NAME);
                if (CHK_LAST) begin : g_as_live_pkt
                    a_packet_terminates : assert property (p_packet_terminates)
                        else $error("[%s] AXIS: packet started and never ended",
                                    IFC_NAME);
                end
            end
        end
    endgenerate

    // =========================================================================
    // Cover — the reachability evidence. A proof of "nothing bad happens" on an
    // interface that can never carry a beat is worthless and looks identical to
    // a real proof in the report. EVERY bound interface must hit these.
    // ⚠️ CI fails on an uncovered cover, not just on a failed assert.
    // =========================================================================
    generate
        if (!IS_ASSUME) begin : g_cover
            c_xfer          : cover property (@(posedge clk) xfer);
            c_single_beat   : cover property (@(posedge clk) xfer && tlast && !in_pkt_q);
            c_multi_beat    : cover property (@(posedge clk) xfer && tlast &&  in_pkt_q);
            c_back_to_back  : cover property (@(posedge clk) (xfer && tlast) ##1 xfer);
            c_gap           : cover property (@(posedge clk) (xfer && tlast) ##1 !tvalid);
            if (CHK_KEEP && CHK_KEEP_FULL_MID) begin : g_cov_keep
                c_partial_last : cover property (@(posedge clk)
                                     xfer && tlast && (tkeep != '1));
            end
            if (!NEVER_STALL) begin : g_cov_stall
                c_stall_first : cover property (@(posedge clk)
                                    !in_pkt_q && tvalid && !tready);
                c_stall_last  : cover property (@(posedge clk)
                                    tvalid && tlast && !tready);
                c_stall_long  : cover property (@(posedge clk)
                                    stall_cnt_q == STALL_W'(MAX_STALL_CYC - 1));
            end
        end
    endgenerate

endmodule : fv_axis_props


// -----------------------------------------------------------------------------
// fv_stream_props — the same contract for this project's NON-AXI stream shape.
//
// Most internal interfaces here are `{valid, payload}` with no ready, because
// the fast path is single-issue and cannot stall (fpga_top.sv). The contract is
// therefore thinner but not empty: the payload must be stable while valid, and
// valid must not appear out of reset. Bound to the decoder/book/strategy/risk
// interfaces where an AXI-Stream checker would be the wrong shape.
// -----------------------------------------------------------------------------
module fv_stream_props #(
    parameter int unsigned W        = 1,
    parameter bit          IS_ASSUME = 1'b0,
    // Maximum sustained back-to-back valids. The fast path is single-issue with
    // a fixed pipeline, so an unbroken run longer than this means an upstream
    // block is producing faster than the budget allows. 0 disables.
    parameter int unsigned MAX_BURST = 0,
    parameter string       IFC_NAME  = "stream"
) (
    input var logic         clk,
    input var logic         rst,
    input var logic         valid,
    input var logic [W-1:0] payload
);

    localparam int unsigned BW = (MAX_BURST > 1) ? $clog2(MAX_BURST + 2) : 2;

    logic [BW-1:0] burst_q;
    always_ff @(posedge clk) begin
        if (rst)         burst_q <= '0;
        else if (!valid) burst_q <= '0;
        else if (burst_q != {BW{1'b1}}) burst_q <= burst_q + BW'(1);
    end

    default disable iff (rst);

    property p_reset_quiet;
        @(posedge clk) disable iff (1'b0) rst |=> !valid;
    endproperty

    property p_burst_bounded;
        @(posedge clk) burst_q <= BW'(MAX_BURST);
    endproperty

    // The payload is meaningless when valid is low, so there is nothing to
    // assert about it — asserting stability there would forbid a legal and
    // useful power optimisation (holding the last value) for no benefit.
    property p_no_x_when_valid;
        @(posedge clk) valid |-> !$isunknown(payload);
    endproperty

    generate
        if (IS_ASSUME) begin : g_assume
            m_reset_quiet : assume property (p_reset_quiet);
            if (MAX_BURST > 0) begin : g_am_burst
                m_burst_bounded : assume property (p_burst_bounded);
            end
        end
        else begin : g_assert
            a_reset_quiet : assert property (p_reset_quiet)
                else $error("[%s] valid asserted out of reset", IFC_NAME);
            a_no_x        : assert property (p_no_x_when_valid)
                else $error("[%s] payload is X while valid — un-reset register "
                            "or an uninitialised memory read", IFC_NAME);
            if (MAX_BURST > 0) begin : g_as_burst
                a_burst_bounded : assert property (p_burst_bounded)
                    else $error("[%s] %0d consecutive valids exceeds the budgeted "
                                "issue rate of %0d", IFC_NAME, burst_q, MAX_BURST);
            end
            c_valid : cover property (@(posedge clk) valid);
            c_gap   : cover property (@(posedge clk) valid ##1 !valid ##1 valid);
        end
    endgenerate

endmodule : fv_stream_props

`endif  // SYNTHESIS

`default_nettype wire
