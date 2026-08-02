// =============================================================================
// rate_limiter.sv — Windowed outbound message-rate limiter
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Layer   : rtl/risk — pre-trade risk / SEC Rule 15c3-5 control block
// Governs : manuals/08-nasdaq/09-risk-controls-and-limits.md §1 check 21, §5
//           manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md
//           manuals/08-nasdaq/08-connectivity-and-colocation.md (port throttles)
//
// -----------------------------------------------------------------------------
// PURPOSE
//   Bound the number of messages this design puts on the order-entry session in
//   any window. Two independent thresholds:
//
//     `max_msgs`  — SOFT limit. `over` asserts; risk_gate rejects the order with
//                   RISK_MSG_RATE and counts it. Trading continues; the runaway
//                   is contained. This is the working control.
//     `kill_msgs` — HARD backstop. `breach` pulses into the kill switch
//                   (KILL_MSG_RATE), which latches. Reaching this means the soft
//                   limit did not contain the problem, and at that point the
//                   only defensible action is to stop.
//
//   Defence in depth: the soft limit is the control, the hard limit is the
//   evidence that the control failed.
//
// -----------------------------------------------------------------------------
// ⚠️ WINDOW DISCIPLINE — THIS IS A SLIDING WINDOW APPROXIMATED BY N_SUBWIN
//    TUMBLING SUB-BUCKETS. Read the burst analysis before choosing `max_msgs`.
//
//   Structure: the window W is divided into N_SUBWIN sub-buckets, each of
//   `subwin_cyc` cycles. Each outbound message increments the HEAD bucket. Every
//   `subwin_cyc` cycles the head advances and the bucket it lands on is cleared
//   (its contents leave the window). `sum` is the running total of all N_SUBWIN
//   buckets and is maintained incrementally — one add and one subtract per
//   cycle, never a re-summation. Logic depth is 2 adders regardless of N_SUBWIN.
//
//   Effective window length:   W_eff  ∈ [ subwin_cyc·(N_SUBWIN-1) , subwin_cyc·N_SUBWIN ]
//   Nominal window:            W      =   subwin_cyc·N_SUBWIN
//   Granularity (jitter in W): subwin_cyc  (= W / N_SUBWIN)
//
//   ⚠️ WORST-CASE BURST. The enforced invariant is "no more than `max_msgs` in
//   any N_SUBWIN *consecutive* buckets". An arbitrary (non-bucket-aligned)
//   interval of length W can straddle N_SUBWIN+1 buckets, and an adversarial /
//   pathological sender can place `max_msgs` at the end of the first and
//   `max_msgs` at the start of the last. Therefore:
//
//       worst-case messages in ANY interval of length W   :  < 2 · max_msgs
//       worst-case messages in any bucket-aligned window  :  ≤   max_msgs
//
//   This 2× factor is inherent to ANY bucketed counter, including a pure
//   tumbling window (N_SUBWIN = 1). What N_SUBWIN buys is not a better bound —
//   it is a much tighter *confinement in time* of the 2× excursion (the two
//   maximal bursts must be ≈W apart, and the recovery is one bucket, not one
//   full window) and far lower jitter in the enforced window.
//
//   ⚠️ THE OPERATIONAL RULE THAT FOLLOWS: if the venue publishes a hard cap of
//   C messages per interval T, set  subwin_cyc·N_SUBWIN ≈ T  and
//   max_msgs ≤ C/2. Do not set max_msgs = C. Halving it is the price of a
//   bucketed counter and it is cheap; a port throttle breach is not.
//   (An exact sliding window needs a timestamp FIFO of depth `max_msgs` — that
//   is O(max_msgs) BRAM and a variable-latency dequeue on the fast path. It was
//   rejected for that reason; this trade is documented here so it is not
//   silently "optimised" later.)
//
//   A second, structural bound also holds unconditionally: the fast path is
//   single-issue, so the instantaneous rate can never exceed 1 message per core
//   clock (156.25 Mmsg/s) no matter what this module does.
//
// ⚠️ HEADROOM. `over` is a registered output; risk_gate samples it and its own
//   pipeline is 2 stages deep, so up to PIPE_HEADROOM messages can already be
//   committed when `over` rises. The comparison therefore reserves
//   PIPE_HEADROOM: the *effective* soft limit is (max_msgs - PIPE_HEADROOM) and
//   the true count can never exceed `max_msgs`. Under-counting a rate limit is
//   not an option, so the reservation is unconditional.
//
// -----------------------------------------------------------------------------
// LATENCY
//   `over` / `breach` are registered: 1 cycle from the message that crosses the
//   threshold. They sit on risk_gate's T0 precomputed-bit vector and cost 0
//   cycles in the order path.
//
// RESOURCE (estimate, pre-synthesis, VU9P-class, N_SUBWIN=8, CNT_W=32)
//   LUT ~420   FF ~400   BRAM 0   DSP 0
//
// -----------------------------------------------------------------------------
// REGULATORY OBLIGATIONS IMPLEMENTED
//   * SEC Rule 15c3-5(c)(1)(ii) — controls "reasonably designed to prevent the
//     entry of erroneous orders", specifically the duplicative/runaway-loop case.
//   * SEC Rule 15c3-5(c)(1)(i)  — the rate cap bounds the notional a runaway can
//     reach between the breach and the kill latch.
//   * Venue port-throttle rules — exceeding a Nasdaq port's message rate is a
//     rule breach in its own right and gets the session throttled or pulled.
//
// -----------------------------------------------------------------------------
// FAIL-CLOSED RESET STATE
//   subwin_cyc / max_msgs / kill_msgs are host-written and reset to ZERO. With
//   max_msgs = 0 the reservation makes `over` assert permanently => every order
//   is rejected with RISK_MSG_RATE until the host programs a real limit. That is
//   the intended behaviour (manuals/08-nasdaq/09-*.md §2: "a limit that resets to
//   a large value is worse than no limit at all").
//   kill_msgs == 0 disables only the HARD backstop, which is safe precisely
//   because the soft path is already fully closed at that point.
// =============================================================================
`default_nettype none

module rate_limiter #(
    // Number of tumbling sub-buckets composing the sliding window.
    // Must be a power of two.
    parameter int unsigned N_SUBWIN      = 8,
    // Width of the bucket and running-sum counters.
    parameter int unsigned CNT_W         = 32,
    // Messages that can already be committed in risk_gate when `over` rises.
    // = risk_gate pipeline depth (2). Reserved unconditionally.
    parameter int unsigned PIPE_HEADROOM = 2
) (
    input  var logic              clk,
    input  var logic              rst,           // synchronous, active high

    // ── Runtime configuration (host, slow path). Reset = 0 = fail-closed. ────
    input  var logic [31:0]       subwin_cyc,    // cycles per sub-bucket
    input  var logic [CNT_W-1:0]  max_msgs,      // SOFT limit over the window
    input  var logic [CNT_W-1:0]  kill_msgs,     // HARD backstop (0 = disabled)

    // ── Event input ──────────────────────────────────────────────────────────
    input  var logic              msg_valid,     // one outbound message emitted

    // ── Outputs (registered) ─────────────────────────────────────────────────
    output var logic              over,          // soft limit reached => reject
    output var logic              breach,        // hard limit => kill (level, sticky)
    output var logic [CNT_W-1:0]  window_cnt,    // current sliding-window count
    output var logic [CNT_W-1:0]  peak_cnt,      // high-water mark, sticky
    output var logic [31:0]       over_cnt,      // saturating: rejects caused
    output var logic [31:0]       msg_cnt        // saturating: messages counted
);

    localparam int unsigned HEAD_W    = (N_SUBWIN > 1) ? $clog2(N_SUBWIN) : 1;
    localparam logic [31:0] CNT32_MAX = 32'hFFFF_FFFF;

    // -------------------------------------------------------------------------
    // Sub-bucket rotation timer
    // -------------------------------------------------------------------------
    logic [31:0]       tick_q;
    logic              rotate;
    logic [HEAD_W-1:0] head_q, head_next;

    // subwin_cyc == 0 would rotate every cycle, collapsing W to N_SUBWIN cycles.
    // That is the fail-closed direction (a shorter window rejects more), and
    // max_msgs is also 0 at reset, so nothing can be emitted anyway.
    assign rotate    = (tick_q == 32'd0);
    assign head_next = head_q + HEAD_W'(1);

    always_ff @(posedge clk) begin
        if (rst) begin
            tick_q <= 32'd0;
            head_q <= '0;
        end else if (rotate) begin
            tick_q <= (subwin_cyc == 32'd0) ? 32'd0 : (subwin_cyc - 32'd1);
            head_q <= head_next;
        end else begin
            tick_q <= tick_q - 32'd1;
            head_q <= head_q;
        end
    end

    // -------------------------------------------------------------------------
    // Buckets and the incrementally maintained running sum.
    //
    // On a rotation the bucket the head lands on leaves the window: subtract it
    // from `sum` and clear it. On a message: add 1 to the head bucket and to
    // `sum`. Both can happen in the same cycle; the head used for the increment
    // is the POST-rotation head, so the message lands in the freshly cleared
    // bucket and is never subtracted out in the same operation.
    // -------------------------------------------------------------------------
    logic [CNT_W-1:0]  bucket_q [N_SUBWIN];
    logic [CNT_W-1:0]  sum_q;
    logic [HEAD_W-1:0] wr_head;
    logic [CNT_W-1:0]  leaving;
    logic [CNT_W-1:0]  sum_d;
    logic [CNT_W:0]    sum_ext;

    assign wr_head = rotate ? head_next : head_q;
    assign leaving = rotate ? bucket_q[head_next] : CNT_W'(0);

    // Saturating so a pathological configuration cannot wrap the risk counter.
    // (manuals/08-nasdaq/09-*.md §3 — risk accumulators may not wrap.)
    always_comb begin
        sum_ext = '0;
        sum_d   = '0;
        sum_ext = ({1'b0, sum_q} - {1'b0, leaving})
                  + (msg_valid ? (CNT_W+1)'(1) : (CNT_W+1)'(0));
        sum_d   = sum_ext[CNT_W] ? {CNT_W{1'b1}} : sum_ext[CNT_W-1:0];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned b = 0; b < N_SUBWIN; b++) bucket_q[b] <= '0;
            sum_q <= '0;
        end else begin
            for (int unsigned b = 0; b < N_SUBWIN; b++) begin
                // Default: hold. Explicit, so no latch and no implied priority
                // confusion between the clear and the increment.
                if (rotate && (HEAD_W'(b) == head_next)) begin
                    bucket_q[b] <= (msg_valid && (HEAD_W'(b) == wr_head))
                                     ? CNT_W'(1) : CNT_W'(0);
                end else if (msg_valid && (HEAD_W'(b) == wr_head)) begin
                    bucket_q[b] <= (bucket_q[b] == {CNT_W{1'b1}})
                                     ? bucket_q[b] : bucket_q[b] + CNT_W'(1);
                end else begin
                    bucket_q[b] <= bucket_q[b];
                end
            end
            sum_q <= sum_d;
        end
    end

    // -------------------------------------------------------------------------
    // Threshold comparison.
    // `sum_d` (not `sum_q`) is used so the message emitted THIS cycle is already
    // counted when `over` registers — no message escapes its own increment.
    // -------------------------------------------------------------------------
    logic [CNT_W:0] eff_limit;      // max_msgs - PIPE_HEADROOM, floored at 0
    logic           over_d, breach_d;

    always_comb begin
        eff_limit = {1'b0, max_msgs};
        eff_limit = (eff_limit > (CNT_W+1)'(PIPE_HEADROOM))
                      ? (eff_limit - (CNT_W+1)'(PIPE_HEADROOM))
                      : '0;
        // max_msgs <= PIPE_HEADROOM (including the reset value 0) => eff_limit 0
        // => permanently over => everything rejected. Fail-closed.
        over_d   = ({1'b0, sum_d} >= eff_limit) || (eff_limit == '0);
        breach_d = (kill_msgs != '0) && (sum_d >= kill_msgs);
    end

    // -------------------------------------------------------------------------
    // Registered outputs and telemetry
    // -------------------------------------------------------------------------
    logic             over_q, breach_q;
    logic [CNT_W-1:0] peak_q;
    logic [31:0]      over_cnt_q, msg_cnt_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            over_q     <= 1'b1;             // ⚠️ reset = over = reject. Fail-closed.
            breach_q   <= 1'b0;
            peak_q     <= '0;
            over_cnt_q <= 32'd0;
            msg_cnt_q  <= 32'd0;
        end else begin
            over_q   <= over_d;
            // `breach` is STICKY. Nothing in hardware decides the situation has
            // improved; only reset or a host re-arm of the kill switch clears
            // the consequence. (manuals/08-nasdaq/09-*.md §5, "Latching".)
            breach_q <= breach_q || breach_d;
            peak_q   <= (sum_d > peak_q) ? sum_d : peak_q;

            if (msg_valid)
                msg_cnt_q  <= (msg_cnt_q  == CNT32_MAX) ? CNT32_MAX : msg_cnt_q + 32'd1;
            else
                msg_cnt_q  <= msg_cnt_q;

            if (over_d && !over_q)          // count rising edges of the soft limit
                over_cnt_q <= (over_cnt_q == CNT32_MAX) ? CNT32_MAX : over_cnt_q + 32'd1;
            else
                over_cnt_q <= over_cnt_q;
        end
    end

    assign over       = over_q;
    assign breach     = breach_q;
    assign window_cnt = sum_q;
    assign peak_cnt   = peak_q;
    assign over_cnt   = over_cnt_q;
    assign msg_cnt    = msg_cnt_q;

    // =========================================================================
    // Assertions — simulation only
    // =========================================================================
`ifndef SYNTHESIS
    initial begin
        if (N_SUBWIN == 0 || (N_SUBWIN & (N_SUBWIN - 1)) != 0)
            $error("rate_limiter: N_SUBWIN (%0d) must be a power of two", N_SUBWIN);
        if (PIPE_HEADROOM < 2)
            $error("rate_limiter: PIPE_HEADROOM must be >= the risk_gate pipeline depth (2)");
    end

    // The running sum must always equal the sum of the buckets. If this ever
    // fails the incremental maintenance has a bug and the limit is fiction.
    logic [CNT_W+HEAD_W:0] chk_sum;
    always_comb begin
        chk_sum = '0;
        for (int unsigned b = 0; b < N_SUBWIN; b++)
            chk_sum = chk_sum + (CNT_W+HEAD_W+1)'(bucket_q[b]);
    end
    assert property (@(posedge clk) disable iff (rst)
        (sum_q != {CNT_W{1'b1}}) |-> (chk_sum == {{(HEAD_W+1){1'b0}}, sum_q})
    ) else $error("FATAL: rate_limiter running sum diverged from its buckets");

    // ⚠️ The invariant the whole module exists to provide.
    assert property (@(posedge clk) disable iff (rst)
        (max_msgs > CNT_W'(PIPE_HEADROOM)) |-> (sum_q <= max_msgs)
    ) else $error("FATAL: sliding-window count exceeded max_msgs");

    // Fail-closed on reset.
    assert property (@(posedge clk) rst |=> over)
        else $error("rate_limiter permitted messages out of reset");

    // A zero soft limit must block everything, forever.
    assert property (@(posedge clk) disable iff (rst)
        (max_msgs <= CNT_W'(PIPE_HEADROOM)) |=> over
    ) else $error("rate_limiter allowed traffic with a zero/degenerate limit");

    // Breach is sticky.
    assert property (@(posedge clk) disable iff (rst)
        breach |=> breach
    ) else $error("rate_limiter breach latch cleared itself");

    // ⚠️ REQUIRED COVERAGE — every check observed to fire.
    c_msg        : cover property (@(posedge clk) disable iff (rst) msg_valid);
    c_rotate     : cover property (@(posedge clk) disable iff (rst) rotate && msg_valid);
    c_over_rise  : cover property (@(posedge clk) disable iff (rst) $rose(over_q));
    c_over_fall  : cover property (@(posedge clk) disable iff (rst) $fell(over_q));
    c_breach     : cover property (@(posedge clk) disable iff (rst) $rose(breach_q));
    c_full_burst : cover property (@(posedge clk) disable iff (rst)
                                   msg_valid && (sum_q + CNT_W'(1) == max_msgs));
`endif

endmodule : rate_limiter

`default_nettype wire
