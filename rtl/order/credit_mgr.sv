// =============================================================================
// credit_mgr.sv — In-flight order credit: the bound on FPGA/host divergence
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md
//           manuals/04-system-architecture/06-cpu-fpga-partitioning.md
//           trading_pkg::MAX_IN_FLIGHT / CREDIT_W
//
// -----------------------------------------------------------------------------
// ⚠️ THE HAZARD THIS BLOCK EXISTS TO STOP
//
//   The FPGA can emit an order every few cycles. The host cannot account for
//   orders at anything like that rate — it has a DMA ring, a scheduler, a
//   garbage-collected or at least cache-missing accounting path, and a human
//   somewhere behind all of it. There is therefore a window in which the FPGA
//   has sent orders that NOBODY ELSE KNOWS ABOUT: not the host's position
//   model, not the risk system's aggregate exposure, not the operator.
//
//   Left unbounded, that window is unbounded. A strategy bug, a wedged feed
//   producing a stuck trigger, or an unlucky burst can put thousands of orders
//   into the market in the time it takes the host to notice one. That is the
//   canonical way an automated trading system loses a career-ending amount of
//   money in under a second, and it is a scenario regulators specifically ask
//   about (SEC Rule 15c3-5).
//
//   The credit counter is the hard bound. At most MAX_IN_FLIGHT orders may be
//   outstanding — sent but not yet resolved — at any instant. When credit runs
//   out the risk gate stops passing orders (RISK_NO_CREDIT), full stop. There
//   is no override, no high-priority path, and no way for the strategy to ask
//   for more.
//
//   ⚠️ THE COUNTER IS A SAFETY DEVICE, NOT A PERFORMANCE KNOB. Raising
//      MAX_IN_FLIGHT to "fix" starvation is raising the amount of money you can
//      lose before anyone notices. Treat a change to it as a risk-limit change
//      under CLAUDE.md §6: flag it, do not bundle it with unrelated work.
//
// -----------------------------------------------------------------------------
// ACCOUNTING RULES
//
//   CONSUME one credit when an Enter Order is actually emitted.
//     ⚠️ CANCELS DO NOT CONSUME CREDIT. A cancel reduces exposure. Credit-gating
//        it would mean that the worse things get, the less able you are to get
//        out — the exact opposite of what a safety device should do. A cancel
//        must always be sendable.
//
//   RETURN one credit on:
//     * a terminal event decoded by ouch_rx (Canceled, AIQ Canceled, Rejected,
//       Broken Trade, and — see below — Executed), or
//     * an explicit host credit_return write.
//
//   ⚠️ THE EXECUTED APPROXIMATION, STATED HONESTLY. An OUCH Executed message
//      does not report the leaves quantity, so hardware cannot tell a partial
//      fill from a complete one without an in-flight order table. ouch_rx
//      therefore treats every Executed as terminal (its CREDIT_RETURN_ON_EXEC
//      parameter). Consequence: a partially-filled order returns its credit
//      early, so the true in-flight count can exceed the credit count by the
//      number of partially-filled resting orders.
//
//      Why that is acceptable, and how it is bounded:
//        a) The counter SATURATES at MAX_IN_FLIGHT and FLOORS at zero. An
//           over-return can never manufacture credit beyond the ceiling.
//        b) An over-return shows up as stat[3] (a return arriving at zero
//           in-flight). That counter is the direct, observable symptom of this
//           approximation and it is why it exists.
//        c) The host is authoritative and its explicit credit_return is the
//           correction channel.
//      If a strategy is dominated by partial fills, set CREDIT_RETURN_ON_EXEC
//      to 0 in ouch_rx and let the host return execution credits from its
//      authoritative order state. That is slower and strictly safer.
//
//   ⚠️ THE KILL SWITCH DOES NOT RESET THE COUNTER. Orders already in flight are
//      still in flight; forgetting them would understate exposure at exactly
//      the moment exposure matters most. Credits drain normally through
//      terminal events, or the host resets them deliberately after reconciling.
//
// -----------------------------------------------------------------------------
// ⚠️ SUSTAINED STARVATION IS AN ALARM, NOT A STATISTIC
//   Running out of credit means one of two things, and both need a human:
//     * the venue has stopped responding (orders sent, nothing coming back), or
//     * we are emitting far more than we thought we would.
//   Brief starvation in a burst is normal. Starvation lasting STARVE_ALARM_CYC
//   cycles is not. The block exposes both the event count and the longest
//   consecutive run, because "how many times" and "how long" are different
//   questions and the second one is the one that matters at 09:31.
//
// -----------------------------------------------------------------------------
// LATENCY / RESOURCES
//   credit_avail is REGISTERED and reflects the count as of the end of this
//   cycle, so the risk gate sees a value that is exact for the cycle in which
//   it uses it. 1 cycle. ~120 FF, ~90 LUT, 0 BRAM, 0 DSP.
// =============================================================================
`default_nettype none

module credit_mgr
    import trading_pkg::*;
#(
    // Consecutive starved cycles that constitute an alarm. 156250 cycles = 1 ms
    // at 156.25 MHz. Any sustained starvation on that timescale is abnormal.
    parameter int unsigned STARVE_ALARM_CYC = 156250
) (
    input  var logic                clk,
    input  var logic                rst,

    // ── Consumption: one credit per Enter Order actually emitted ─────────────
    input  var logic                consume,

    // ── Returns ──────────────────────────────────────────────────────────────
    input  var logic                ret_rx,     // terminal event from ouch_rx
    input  var logic                ret_host,   // explicit host credit_return

    // ── To the risk gate ─────────────────────────────────────────────────────
    output var logic                credit_avail,

    // ── Telemetry ────────────────────────────────────────────────────────────
    output var logic [CREDIT_W-1:0] in_flight,
    output var logic [31:0]         starve_run_max,
    output var logic                starve_alarm,
    output var logic [31:0]         stat [4]
);

    localparam logic [CREDIT_W:0] MAXF = (CREDIT_W+1)'(MAX_IN_FLIGHT);

    // =========================================================================
    // The counter. Saturating in BOTH directions — a wrapped safety counter is
    // a disabled safety counter (CLAUDE.md §5, trading_pkg sat_add/sat_sub).
    // =========================================================================
    logic [CREDIT_W:0] nxt;
    logic              underflow_attempt;

    always_comb begin
        nxt               = {1'b0, in_flight};
        underflow_attempt = 1'b0;

        // Consume first, then returns: this gives the correct net result when a
        // consume and a return land in the same cycle.
        if (consume) begin
            nxt = (nxt < MAXF) ? (nxt + (CREDIT_W+1)'(1)) : MAXF;
        end
        if (ret_rx) begin
            if (nxt != (CREDIT_W+1)'(0)) nxt = nxt - (CREDIT_W+1)'(1);
            else                         underflow_attempt = 1'b1;
        end
        if (ret_host) begin
            if (nxt != (CREDIT_W+1)'(0)) nxt = nxt - (CREDIT_W+1)'(1);
            else                         underflow_attempt = 1'b1;
        end
        if (nxt > MAXF) nxt = MAXF;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            in_flight    <= CREDIT_W'(0);
            credit_avail <= 1'b0;   // fail-closed: no credit until out of reset
        end else begin
            in_flight    <= nxt[CREDIT_W-1:0];
            credit_avail <= (nxt < MAXF);
        end
    end

    // =========================================================================
    // Starvation tracking
    // =========================================================================
    logic        starved;
    logic        starved_q;
    logic [31:0] starve_run;

    assign starved = !credit_avail;

    always_ff @(posedge clk) begin
        if (rst) begin
            starved_q      <= 1'b0;
            starve_run     <= 32'd0;
            starve_run_max <= 32'd0;
            starve_alarm   <= 1'b0;
        end else begin
            starved_q <= starved;
            if (starved) begin
                starve_run <= starve_run + 32'd1;
                if ((starve_run + 32'd1) > starve_run_max) begin
                    starve_run_max <= starve_run + 32'd1;
                end
                if ((starve_run + 32'd1) >= 32'(STARVE_ALARM_CYC)) begin
                    starve_alarm <= 1'b1;   // sticky until reset
                end
            end else begin
                starve_run <= 32'd0;
            end
        end
    end

    // =========================================================================
    // Counters
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 4; i++) stat[i] <= 32'd0;
        end else begin
            if (consume)                     stat[0] <= stat[0] + 32'd1;
            if (ret_rx || ret_host)          stat[1] <= stat[1] + 32'd1;
            if (starved && !starved_q)       stat[2] <= stat[2] + 32'd1;
            // ⚠️ stat[3]: a credit was returned when nothing was outstanding.
            //    This is the observable symptom of the Executed-as-terminal
            //    approximation (partial fills) or of a double return. A slowly
            //    rising count is expected for a passive strategy; a fast-rising
            //    one means the accounting is wrong somewhere.
            if (underflow_attempt)           stat[3] <= stat[3] + 32'd1;
        end
    end

    // =========================================================================
    // Assertions — the two invariants the whole safety argument rests on
    // =========================================================================
`ifndef SYNTHESIS
    // INVARIANT 1: the in-flight count NEVER exceeds MAX_IN_FLIGHT.
    assert property (@(posedge clk) disable iff (rst)
        (in_flight <= CREDIT_W'(MAX_IN_FLIGHT))
    ) else $error("credit_mgr: in_flight %0d exceeds MAX_IN_FLIGHT %0d",
                  in_flight, MAX_IN_FLIGHT);

    // INVARIANT 2: the counter NEVER underflows (wraps below zero).
    assert property (@(posedge clk) disable iff (rst)
        ((ret_rx || ret_host) && (in_flight == CREDIT_W'(0)) && !consume)
            |=> (in_flight == CREDIT_W'(0))
    ) else $error("credit_mgr: counter underflowed");

    // A consume must never be presented while credit is exhausted: the risk
    // gate is responsible for enforcing this and RISK_NO_CREDIT counts it. If
    // this fires, the gate has been bypassed — a CLAUDE.md §5.5 violation.
    assert property (@(posedge clk) disable iff (rst)
        consume |-> credit_avail
    ) else $error("credit_mgr: order emitted with no credit available -- risk gate bypassed");

    // Fail-closed out of reset.
    assert property (@(posedge clk)
        rst |=> !credit_avail
    ) else $error("credit_mgr: credit available immediately out of reset");

    initial begin
        if (MAX_IN_FLIGHT == 0)
            $fatal(1, "credit_mgr: MAX_IN_FLIGHT of 0 disables all trading");
        if ((1 << CREDIT_W) <= MAX_IN_FLIGHT)
            $fatal(1, "credit_mgr: CREDIT_W too narrow for MAX_IN_FLIGHT");
    end
`endif

endmodule : credit_mgr

`default_nettype wire
