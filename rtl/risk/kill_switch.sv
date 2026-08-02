// =============================================================================
// kill_switch.sv — Hardware kill switch (latching, bounded, two-step re-arm)
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Layer   : rtl/risk — pre-trade risk / SEC Rule 15c3-5 control block
// Governs : manuals/08-nasdaq/09-risk-controls-and-limits.md §5 (the spec)
//           manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md §5
//           CLAUDE.md §5 rule 6 ("the kill switch is hardware-enforced")
//
// -----------------------------------------------------------------------------
// PURPOSE
//   One sticky bit, `kill_active`, that stops all outbound order flow. It is the
//   last control that still works when everything else — the strategy, the host
//   process, the PCIe link, your ability to log in — has failed.
//
//   `kill_active` is a REGISTERED output and is consumed as a same-cycle AND
//   term at every stage of the risk gate's pipeline and again at the TX mux, so
//   it squashes orders already in flight rather than letting them drain.
//
// -----------------------------------------------------------------------------
// ⚠️ BOUNDED RESPONSE — THE NUMBER THIS MODULE GUARANTEES
//
//   Every trigger input is sampled on the core clock and ORed into a single
//   combinational `trig_any`, which sets `kill_active_q` on the NEXT edge:
//
//       trigger present at the module boundary  →  kill_active asserted
//                                               =  1 core cycle = 6.4 ns
//
//   That is asserted below (a_kill_1cycle) and is unconditional — there is no
//   state, arbitration, or handshake between a trigger and the latch. From
//   `kill_active` the risk gate suppresses `m_out_valid` in a further 1 cycle
//   (risk_gate.sv), so the end-to-end bound the top level asserts is:
//
//       trigger → no order emitted :  2 cycles = 12.8 ns
//                                      ≤ KILL_RESP_CYCLES (= 4 in fpga_top.sv)
//
//   Source-specific additions OUTSIDE this module, for the record:
//     host_kill  : + PCIe posted-write latency + host_ctrl CDC (~2–3 cycles)
//     ext_kill   : + 3-FF CDC synchroniser in fpga_top (u_ext_kill_cdc)
//                  + EXT_DEBOUNCE_CYC here (default 16 = 102.4 ns)
//   The debounce is on the ASSERT edge only in the sense that it must be stable
//   for EXT_DEBOUNCE_CYC to *assert*; it is never used to de-assert, because a
//   latched kill never de-asserts on its own.
//
//   ⚠️ ONE ORDER MAY STILL REACH THE VENUE. If the first beat of a frame has
//   already been accepted by the MAC it will be transmitted; there is no
//   mechanism to recall it. The design's guarantee is "at most one order frame",
//   and that is only true because the fast path is single-issue with no queue
//   between the encoder and the MAC. See 04-system-architecture/05-*.md §5.
//   Anything already at the venue is retracted by a host mass-cancel, not here.
//
// -----------------------------------------------------------------------------
// ⚠️ RESET STATE IS ARMED (KILLED), NOT DISARMED
//   `rst` puts the FSM in KS_ARMED with kill_active = 1. A freshly configured
//   FPGA can do exactly nothing until a deliberate, authenticated, two-step host
//   sequence re-arms it. Nothing auto-recovers: not a timeout, not link-up, not
//   the trigger going away. (manuals/08-nasdaq/09-*.md §2 and §5 "Latching".)
//
// ⚠️ THE RE-ARM IS TWO-STEP BY DESIGN — NOT A REGISTER CLEAR
//   A single register write is one stray DMA descriptor, one misaddressed BAR
//   write, or one confused operator away from re-enabling a system that was
//   stopped for a reason. Required sequence, in order:
//     1. Every trigger must currently be INACTIVE (`triggers_clear`). You cannot
//        re-arm through a live fault.
//     2. `position_loaded` must be set — the host has written a reconciled
//        position. ⚠️ This ordering is STRUCTURAL, not procedural: restarting
//        with a zeroed position counter while a real position exists means the
//        position limit permits a full new position on top of the one you
//        already have. (09-*.md §7.)
//     3. Write REARM_KEY_A to the re-arm register  →  state KS_ARM_STEP1.
//     4. Write REARM_KEY_B within REARM_WINDOW_CYC →  state KS_LIVE.
//   Any other value, any timeout, or any trigger firing mid-sequence aborts back
//   to KS_ARMED and increments `rearm_fail_cnt`. The two keys are distinct
//   constants; a repeated write of the same value never advances.
//
// ⚠️ THE WATCHDOG FIRES ON HOST SILENCE — AND ON A STUCK-HIGH HEARTBEAT
//   `host_heartbeat` is EDGE-detected, never level-sampled. A "host alive" flag
//   that the host sets to 1 never becomes 0 when the host dies, which is exactly
//   the failure it was supposed to detect; a stuck-at-1 signal must not be
//   interpretable as health. The counter counts UP from the last edge and fires
//   at `wd_timeout_cyc`. `wd_timeout_cyc` resets to 0, which expires immediately
//   — fail-closed, and consistent with every other limit in this layer.
//   Recommended operating value: tens of milliseconds (09-*.md §5).
//
// ⚠️ `kill_test` — EXERCISING THE SWITCH IN PRODUCTION
//   A kill switch that has never been observed to fire is one you cannot trust,
//   and the first time you find out it is broken must not be the day you need
//   it. `kill_test` drives a real trigger through the real path: the real OR
//   tree, the real latch, the real re-arm requirement. It is deliberately NOT a
//   simulation-only or bypass path — there is no separate code path to rot.
//   Provenance is recorded distinctly (`test_fired`, sticky) so a rehearsal is
//   never mistaken for an incident in the post-mortem, and `test_resp_cyc`
//   records the measured assert latency for the operational evidence pack.
//   Intended use: run it pre-open, with trading disabled, on every session.
//
// -----------------------------------------------------------------------------
// LATENCY   : 1 cycle, trigger → kill_active. Fixed. Asserted.
// RESOURCE  : (estimate, pre-synthesis, VU9P-class)
//             LUT ~380   FF ~220   BRAM 0   DSP 0
//
// -----------------------------------------------------------------------------
// REGULATORY OBLIGATIONS IMPLEMENTED
//   * SEC Rule 15c3-5(c)(1)(i)/(ii) — the control that actually stops a runaway
//     algorithm once a financial or erroneous-order threshold has been breached.
//   * SEC Rule 15c3-5(b) "direct and exclusive control" — the trigger set
//     includes paths (ext_kill GPIO, fabric watchdog) that work with no
//     cooperation from the strategy process or the host at all, which is how a
//     broker-dealer's independent ability to stop the flow becomes enforceable
//     in hardware rather than in policy.
//   * Venue / exchange rules requiring a member to be able to halt its own order
//     flow promptly.
//   * SEC Rule 15c3-5 annual review — `kill_src`, `kill_src_mask`,
//     `kill_cnt`, `first_kill_ts` and `test_resp_cyc` are the evidence that the
//     control operates. They are sticky so a poll cannot miss an event.
// =============================================================================
`default_nettype none

module kill_switch
    import trading_pkg::*;
#(
    // Documented response bound, in core cycles, trigger → kill_active.
    // Asserted below. Passed down from fpga_top's KILL_RESP_CYCLES.
    parameter int unsigned KILL_RESP_CYCLES = 4,
    // External GPIO debounce, in core cycles (after the 3-FF CDC in fpga_top).
    parameter int unsigned EXT_DEBOUNCE_CYC = 16,
    // Window in which step 2 of the re-arm must arrive.
    parameter int unsigned REARM_WINDOW_CYC = 156_250,          // 1 ms
    // Two-step re-arm keys. Distinct, non-trivial, and not each other's
    // complement so a stuck bus cannot walk from one to the other.
    parameter logic [31:0] REARM_KEY_A      = 32'h15C3_0501,
    parameter logic [31:0] REARM_KEY_B      = 32'h0A5E_C0DE
) (
    input  var logic         clk,
    input  var logic         rst,             // synchronous, active high

    // ── Trigger sources ──────────────────────────────────────────────────────
    input  var logic         host_kill,       // host wrote the kill register
    input  var logic         host_heartbeat,  // host watchdog kick (EDGE detected)
    input  var logic         ext_kill,        // external GPIO, already CDC'd
    input  var logic         link_down,       // order-entry link lost
    input  var logic         rate_breach,     // rate_limiter hard backstop
    input  var logic         pos_breach,      // position_monitor aggregate breach
    input  var logic         seq_fault,       // unrecoverable session/sequence fault
    input  var logic         kill_test,       // pulse: exercise the switch for real

    // ── Host configuration / re-arm (slow path) ──────────────────────────────
    input  var logic [31:0]  wd_timeout_cyc,  // 0 = expire immediately (reset value)
    input  var logic         rearm_wr,        // pulse: write `rearm_data`
    input  var logic [31:0]  rearm_data,
    input  var logic         position_loaded, // reconciled position present

    // ── Outputs (all registered) ─────────────────────────────────────────────
    output var logic         kill_active,     // 1 = STOP. The one that matters.
    output var kill_src_e    kill_src,        // FIRST source, sticky
    output var logic [7:0]   kill_src_mask,   // ALL sources seen, sticky, one bit
                                              // per kill_src_e ordinal
    output var logic         test_fired,      // sticky: a kill_test was executed
    output var logic [15:0]  test_resp_cyc,   // measured assert latency, cycles
    output var logic [15:0]  kill_cnt,        // saturating: kill assertions
    output var logic [15:0]  rearm_cnt,       // saturating: successful re-arms
    output var logic [15:0]  rearm_fail_cnt,  // saturating: aborted re-arm attempts
    output var logic         wd_expired,      // live: watchdog has timed out
    output var logic [31:0]  wd_cnt           // live: cycles since last heartbeat
);

    localparam logic [15:0] CNT16_MAX = 16'hFFFF;

    // -------------------------------------------------------------------------
    // External GPIO debounce. Assert only after EXT_DEBOUNCE_CYC stable-high.
    // There is no de-assert debounce: a latched kill never de-asserts by itself,
    // so a glitch can only ever cause an EXTRA kill, never a missed one.
    // -------------------------------------------------------------------------
    localparam int unsigned DB_W = (EXT_DEBOUNCE_CYC > 1) ? $clog2(EXT_DEBOUNCE_CYC+1) : 1;
    logic [DB_W-1:0] db_cnt_q;
    logic            ext_kill_deb;

    always_ff @(posedge clk) begin
        if (rst) begin
            db_cnt_q <= '0;
        end else if (!ext_kill) begin
            db_cnt_q <= '0;
        end else if (db_cnt_q < DB_W'(EXT_DEBOUNCE_CYC)) begin
            db_cnt_q <= db_cnt_q + DB_W'(1);
        end else begin
            db_cnt_q <= db_cnt_q;
        end
    end
    assign ext_kill_deb = (db_cnt_q >= DB_W'(EXT_DEBOUNCE_CYC));

    // -------------------------------------------------------------------------
    // Host heartbeat watchdog. EDGE detected — see the header note.
    // -------------------------------------------------------------------------
    logic        hb_q;
    logic        hb_kick;
    logic [31:0] wd_cnt_q;
    logic        wd_exp;

    assign hb_kick = host_heartbeat && !hb_q;                 // rising edge only
    assign wd_exp  = (wd_cnt_q >= wd_timeout_cyc);

    always_ff @(posedge clk) begin
        if (rst) begin
            hb_q     <= 1'b0;
            wd_cnt_q <= 32'd0;
        end else begin
            hb_q <= host_heartbeat;
            if (hb_kick)                    wd_cnt_q <= 32'd0;
            else if (wd_cnt_q != 32'hFFFF_FFFF) wd_cnt_q <= wd_cnt_q + 32'd1;
            else                            wd_cnt_q <= wd_cnt_q;   // saturate
        end
    end

    // -------------------------------------------------------------------------
    // Trigger vector. Fixed priority for FIRST-source attribution; the mask
    // records everything. Ordinals match kill_src_e in trading_pkg.
    // -------------------------------------------------------------------------
    logic       trig_host, trig_wd, trig_rate, trig_pos, trig_gpio, trig_link, trig_seq;
    logic       trig_test_q;
    logic       trig_any;
    logic [7:0] trig_mask;
    kill_src_e  trig_first;

    // kill_test is stretched to one clean cycle so a host pulse of any width
    // produces exactly one traceable trigger event.
    logic kill_test_q;
    always_ff @(posedge clk) begin
        if (rst) kill_test_q <= 1'b0;
        else     kill_test_q <= kill_test;
    end
    assign trig_test_q = kill_test && !kill_test_q;

    assign trig_host = host_kill   || trig_test_q;   // test walks the real path
    assign trig_wd   = wd_exp;
    assign trig_rate = rate_breach;
    assign trig_pos  = pos_breach;
    assign trig_gpio = ext_kill_deb;
    assign trig_link = link_down;
    assign trig_seq  = seq_fault;

    always_comb begin
        trig_mask                     = 8'd0;       // default: no latches
        trig_mask[int'(KILL_HOST)]       = trig_host;
        trig_mask[int'(KILL_WATCHDOG)]   = trig_wd;
        trig_mask[int'(KILL_MSG_RATE)]   = trig_rate;
        trig_mask[int'(KILL_POS_BREACH)] = trig_pos;
        trig_mask[int'(KILL_GPIO)]       = trig_gpio;
        trig_mask[int'(KILL_LINK_DOWN)]  = trig_link;
        trig_mask[int'(KILL_SEQ_FAULT)]  = trig_seq;
    end

    assign trig_any = |trig_mask;

    // First-source priority encode. Host first (it is the deliberate act),
    // then the ones that indicate the host is gone, then the fabric detections.
    always_comb begin
        trig_first = KILL_NONE;                     // default assignment
        if      (trig_host) trig_first = KILL_HOST;
        else if (trig_wd)   trig_first = KILL_WATCHDOG;
        else if (trig_gpio) trig_first = KILL_GPIO;
        else if (trig_link) trig_first = KILL_LINK_DOWN;
        else if (trig_rate) trig_first = KILL_MSG_RATE;
        else if (trig_pos)  trig_first = KILL_POS_BREACH;
        else if (trig_seq)  trig_first = KILL_SEQ_FAULT;
        else                trig_first = KILL_NONE;
    end

    logic triggers_clear;
    assign triggers_clear = !trig_any;

    // -------------------------------------------------------------------------
    // Re-arm FSM.  KS_ARMED = KILLED (reset state).
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        KS_ARMED     = 2'd0,   // killed. RESET STATE.
        KS_ARM_STEP1 = 2'd1,   // key A accepted, waiting for key B
        KS_LIVE      = 2'd2    // trading permitted
    } ks_state_e;

    ks_state_e   state_q, state_d;
    logic [31:0] rearm_win_q, rearm_win_d;
    logic        rearm_ok_d, rearm_fail_d;

    always_comb begin
        // Defaults — every output of this block assigned on every path.
        state_d      = state_q;
        rearm_win_d  = (rearm_win_q != 32'd0) ? (rearm_win_q - 32'd1) : 32'd0;
        rearm_ok_d   = 1'b0;
        rearm_fail_d = 1'b0;

        unique case (state_q)
            KS_ARMED: begin
                if (rearm_wr) begin
                    if ((rearm_data == REARM_KEY_A) && triggers_clear
                        && position_loaded) begin
                        state_d     = KS_ARM_STEP1;
                        rearm_win_d = 32'(REARM_WINDOW_CYC);
                    end else begin
                        // Wrong key, live trigger, or no reconciled position.
                        state_d      = KS_ARMED;
                        rearm_fail_d = 1'b1;
                    end
                end
            end

            KS_ARM_STEP1: begin
                if (trig_any) begin
                    // A trigger during the sequence aborts it. You may not
                    // re-arm through a fault that is happening right now.
                    state_d      = KS_ARMED;
                    rearm_fail_d = 1'b1;
                end else if (rearm_wr) begin
                    if ((rearm_data == REARM_KEY_B) && position_loaded) begin
                        state_d    = KS_LIVE;
                        rearm_ok_d = 1'b1;
                    end else begin
                        state_d      = KS_ARMED;
                        rearm_fail_d = 1'b1;
                    end
                end else if (rearm_win_q == 32'd0) begin
                    state_d      = KS_ARMED;      // step-2 window expired
                    rearm_fail_d = 1'b1;
                end
            end

            KS_LIVE: begin
                if (trig_any) state_d = KS_ARMED;         // latch, immediately
                // A re-arm write while already live is meaningless and is
                // counted, not honoured.
                else if (rearm_wr) rearm_fail_d = 1'b1;
            end

            default: begin
                // Unreachable. Fail into the safe state, loudly.
                state_d      = KS_ARMED;
                rearm_fail_d = 1'b1;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // The latch itself, and sticky provenance.
    //
    // kill_active is driven directly from state_d so a trigger present at the
    // module boundary in cycle N asserts kill_active at cycle N+1 — the
    // 1-cycle bound in the header, with no dependence on the FSM taking an
    // extra hop.
    // -------------------------------------------------------------------------
    logic        kill_q;
    kill_src_e   src_q;
    logic [7:0]  mask_q;
    logic [15:0] kill_cnt_q, rearm_cnt_q, rearm_fail_cnt_q;
    logic        test_fired_q;
    logic [15:0] test_resp_q, test_timer_q;
    logic        test_timing_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q          <= KS_ARMED;          // ⚠️ RESET = KILLED
            rearm_win_q      <= 32'd0;
            kill_q           <= 1'b1;              // ⚠️ RESET = kill asserted
            src_q            <= KILL_NONE;
            mask_q           <= 8'd0;
            kill_cnt_q       <= 16'd0;
            rearm_cnt_q      <= 16'd0;
            rearm_fail_cnt_q <= 16'd0;
            test_fired_q     <= 1'b0;
            test_resp_q      <= 16'd0;
            test_timer_q     <= 16'd0;
            test_timing_q    <= 1'b0;
        end else begin
            state_q     <= state_d;
            rearm_win_q <= rearm_win_d;
            kill_q      <= (state_d != KS_LIVE);

            // Sticky source mask: everything that ever fired, this session.
            mask_q <= mask_q | trig_mask;

            // Sticky FIRST source. Only captured on a live -> killed transition
            // so a rehearsal or a later cascade cannot overwrite the root cause.
            if ((state_q == KS_LIVE) && trig_any && (src_q == KILL_NONE))
                src_q <= trig_first;
            else if ((state_q == KS_LIVE) && trig_any && (src_q != KILL_NONE))
                src_q <= src_q;
            else
                src_q <= src_q;

            if ((state_q == KS_LIVE) && trig_any)
                kill_cnt_q <= (kill_cnt_q == CNT16_MAX) ? CNT16_MAX : kill_cnt_q + 16'd1;
            else
                kill_cnt_q <= kill_cnt_q;

            if (rearm_ok_d)
                rearm_cnt_q <= (rearm_cnt_q == CNT16_MAX) ? CNT16_MAX : rearm_cnt_q + 16'd1;
            else
                rearm_cnt_q <= rearm_cnt_q;

            if (rearm_fail_d)
                rearm_fail_cnt_q <= (rearm_fail_cnt_q == CNT16_MAX) ? CNT16_MAX
                                                                   : rearm_fail_cnt_q + 16'd1;
            else
                rearm_fail_cnt_q <= rearm_fail_cnt_q;

            // ── kill_test instrumentation ────────────────────────────────────
            // Measures trigger -> kill_active for the operational evidence pack.
            if (trig_test_q) begin
                test_fired_q  <= 1'b1;
                test_timing_q <= 1'b1;
                test_timer_q  <= 16'd0;
            end else if (test_timing_q) begin
                if (kill_q) begin
                    test_timing_q <= 1'b0;
                    test_resp_q   <= test_timer_q + 16'd1;
                end else begin
                    test_timing_q <= 1'b1;
                    test_timer_q  <= (test_timer_q == CNT16_MAX) ? CNT16_MAX
                                                                 : test_timer_q + 16'd1;
                    test_resp_q   <= test_resp_q;
                end
                test_fired_q <= test_fired_q;
            end else begin
                test_fired_q  <= test_fired_q;
                test_timing_q <= test_timing_q;
                test_timer_q  <= test_timer_q;
                test_resp_q   <= test_resp_q;
            end
        end
    end

    assign kill_active    = kill_q;
    assign kill_src       = src_q;
    assign kill_src_mask  = mask_q;
    assign test_fired     = test_fired_q;
    assign test_resp_cyc  = test_resp_q;
    assign kill_cnt       = kill_cnt_q;
    assign rearm_cnt      = rearm_cnt_q;
    assign rearm_fail_cnt = rearm_fail_cnt_q;
    assign wd_expired     = wd_exp;
    assign wd_cnt         = wd_cnt_q;

    // =========================================================================
    // Assertions — simulation only. This module carries the heaviest set in the
    // design because its failure mode is "the stop button does not stop it".
    // =========================================================================
`ifndef SYNTHESIS
    initial begin
        if (KILL_RESP_CYCLES < 1)
            $error("kill_switch: KILL_RESP_CYCLES must be >= 1");
        if (REARM_KEY_A == REARM_KEY_B)
            $error("kill_switch: re-arm keys must be distinct (two-step re-arm)");
    end

    // ⚠️ THE BOUND. Any trigger present at the boundary asserts kill within one
    // cycle, unconditionally, from any state.
    a_kill_1cycle : assert property (@(posedge clk) disable iff (rst)
        trig_any |=> kill_active
    ) else $error("FATAL: kill_active did not assert 1 cycle after a trigger");

    // ...and therefore within the documented budget.
    a_kill_bound : assert property (@(posedge clk) disable iff (rst)
        trig_any |-> ##[0:KILL_RESP_CYCLES] kill_active
    ) else $error("FATAL: kill response exceeded KILL_RESP_CYCLES (%0d)",
                  KILL_RESP_CYCLES);

    // ⚠️ LATCHING. Once killed, only a completed two-step re-arm clears it.
    // A trigger going away NEVER clears it.
    a_sticky : assert property (@(posedge clk) disable iff (rst)
        (kill_active && !(rearm_wr && (rearm_data == REARM_KEY_B)))
        |=> kill_active
    ) else $error("FATAL: kill_active de-asserted without the re-arm key B write");

    // A single write can never re-arm: KS_LIVE is only reachable from
    // KS_ARM_STEP1, which is only reachable via a key-A write.
    a_two_step : assert property (@(posedge clk) disable iff (rst)
        (state_q == KS_ARMED) |=> (state_q != KS_LIVE)
    ) else $error("FATAL: re-armed in a single step");

    a_arm_needs_key_a : assert property (@(posedge clk) disable iff (rst)
        ((state_q == KS_ARMED) && (state_d == KS_ARM_STEP1))
        |-> (rearm_wr && (rearm_data == REARM_KEY_A) && triggers_clear && position_loaded)
    ) else $error("FATAL: entered ARM_STEP1 without key A / clear triggers / position");

    // ⚠️ Position load must precede kill-clear (09-*.md §7). Structural.
    a_pos_before_arm : assert property (@(posedge clk) disable iff (rst)
        (state_d == KS_LIVE) && (state_q != KS_LIVE) |-> position_loaded
    ) else $error("FATAL: re-armed without a reconciled position loaded");

    // Cannot re-arm through a live fault.
    a_no_arm_on_fault : assert property (@(posedge clk) disable iff (rst)
        trig_any |-> (state_d != KS_LIVE)
    ) else $error("FATAL: re-armed while a trigger was active");

    // ⚠️ Fail-closed on reset.
    a_reset_killed : assert property (@(posedge clk) rst |=> kill_active)
        else $error("FATAL: kill_active low out of reset (fail-closed violated)");

    // Watchdog: silence expires. Sampled with the configured timeout non-zero so
    // the property is meaningful.
    a_wd : assert property (@(posedge clk) disable iff (rst)
        (wd_cnt >= wd_timeout_cyc) |=> kill_active
    ) else $error("FATAL: watchdog expired but kill did not assert");

    // ⚠️ A stuck-high (or stuck-low) heartbeat must NOT hold the watchdog off.
    // The watchdog may only be reloaded by a genuine 0->1 transition; a stable
    // level, at either value, must let the counter keep climbing.
    a_wd_edge_only : assert property (@(posedge clk) disable iff (rst)
        $stable(host_heartbeat) |-> (wd_cnt > $past(wd_cnt) || wd_cnt == 32'hFFFF_FFFF)
    ) else $error("FATAL: watchdog was held off by a stable heartbeat level");

    // Provenance is sticky and never lost.
    a_src_sticky : assert property (@(posedge clk) disable iff (rst)
        (kill_src != KILL_NONE) |=> (kill_src == $past(kill_src))
    ) else $error("kill_src provenance was overwritten");

    a_mask_monotonic : assert property (@(posedge clk) disable iff (rst)
        (kill_src_mask & $past(kill_src_mask)) == $past(kill_src_mask)
    ) else $error("kill_src_mask lost a bit — provenance is not sticky");

    // ⚠️ REQUIRED COVERAGE — every trigger source individually observed to fire.
    // A source that has never been seen to kill is a source you cannot trust.
    c_host     : cover property (@(posedge clk) disable iff (rst) $rose(trig_host)  ##1 kill_active);
    c_watchdog : cover property (@(posedge clk) disable iff (rst) $rose(trig_wd)    ##1 kill_active);
    c_gpio     : cover property (@(posedge clk) disable iff (rst) $rose(trig_gpio)  ##1 kill_active);
    c_link     : cover property (@(posedge clk) disable iff (rst) $rose(trig_link)  ##1 kill_active);
    c_rate     : cover property (@(posedge clk) disable iff (rst) $rose(trig_rate)  ##1 kill_active);
    c_pos      : cover property (@(posedge clk) disable iff (rst) $rose(trig_pos)   ##1 kill_active);
    c_seq      : cover property (@(posedge clk) disable iff (rst) $rose(trig_seq)   ##1 kill_active);
    c_test     : cover property (@(posedge clk) disable iff (rst) $rose(trig_test_q) ##1 kill_active);
    c_rearm_ok : cover property (@(posedge clk) disable iff (rst) rearm_ok_d);
    c_rearm_no_key   : cover property (@(posedge clk) disable iff (rst)
                                        (state_q == KS_ARMED) && rearm_wr
                                        && (rearm_data != REARM_KEY_A));
    c_rearm_timeout  : cover property (@(posedge clk) disable iff (rst)
                                        (state_q == KS_ARM_STEP1) && (rearm_win_q == 32'd0));
    c_rearm_no_pos   : cover property (@(posedge clk) disable iff (rst)
                                        (state_q == KS_ARMED) && rearm_wr
                                        && (rearm_data == REARM_KEY_A) && !position_loaded);
    c_rearm_on_fault : cover property (@(posedge clk) disable iff (rst)
                                        (state_q == KS_ARM_STEP1) && trig_any);
`endif

endmodule : kill_switch

`default_nettype wire
