// =============================================================================
// counter_bank.sv — Bank of N wide event counters with a read port
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/01-fpga-design/01-rtl-design-patterns.md §9
//           manuals/05-optimization/04-measurement-and-profiling.md
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   The telemetry workhorse. Every drop, error, reject, retry, saturation and
//   arbitration stall in the design lands in one of these. CLAUDE.md §5.7 is not
//   negotiable: "Every drop, error, and rejected order is counted in a readable
//   register. Silent failure is the worst failure mode in this domain."
//
//   One increment bit per counter, one registered read port for the CSR block.
//   Increment and read are independent: counting never stalls for a read, and a
//   read never misses an increment that happened on the same cycle.
//
// LATENCY
//   Increment : 1 cycle, always. Never stalls, never backpressures.
//   Read      : 1 cycle from `ren` to `rdata`/`rvalid` = 6.4 ns @ 156.25 MHz.
//
// RESOURCE
//   N * W FF plus N increment adders plus an N:1 read mux.
//   N=32, W=48 -> 1536 FF + 32 short carry chains + ~200 LUT for the mux.
//   ⚠️ Cost is linear in N*W. For N above ~64 this stops being sensible in
//      flip-flops: move to a BRAM-backed read-modify-write counter array
//      (manual 01.03), which trades 2 cycles of increment latency for a single
//      BRAM. This module deliberately does NOT do that, because a fabric
//      counter can never miss a same-cycle double increment and a RMW one can.
//
// -----------------------------------------------------------------------------
// ⚠️  WIDTH: 48 BITS BY DEFAULT, AND DO NOT NARROW IT WITHOUT DOING THE ARITHMETIC
//   A counter that wraps during a trading day is worse than no counter: it reads
//   as healthy (manual §9). At 156.25 MHz, incrementing EVERY cycle:
//       32 bits ->    27.5 seconds     <-- wraps inside one session. Never use.
//       40 bits ->     1.95 hours      <-- wraps inside one session. Never use.
//       48 bits ->    20.8 days        <-- safe for a session, and for a week.
//       64 bits -> ~3700 years
//   48 is the project default and matches trading_pkg::CYCLE_CNT_W.
//
// ⚠️  COUNTERS SATURATE, THEY DO NOT WRAP (SATURATE=1, the default). If a counter
//   somehow does reach its maximum, holding at all-ones and setting the sticky
//   `saturated` bit tells the host the number is a FLOOR. Wrapping tells the
//   host a comfortable lie. Set SATURATE=0 only for a free-running timebase that
//   is meant to roll over, and then document why at the instantiation site.
//
// ⚠️  STICKY vs CLEAR-ON-READ — PICK DELIBERATELY (CLEAR_ON_READ parameter)
//   STICKY (default, CLEAR_ON_READ=0): counters accumulate until `clr_all`. The
//     host computes deltas between polls. Robust to a missed poll, robust to two
//     readers, and the absolute value is meaningful after an incident. THIS IS
//     THE DEFAULT FOR A REASON — use it unless you have a specific need not to.
//   CLEAR-ON-READ (CLEAR_ON_READ=1): a read returns the count and zeroes it, so
//     the host sees a per-interval rate with no subtraction. But the count now
//     lives in exactly one place: A SECOND READER, OR A DROPPED PCIe COMPLETION,
//     DESTROYS DATA THAT CANNOT BE RECOVERED. Only use where a single trusted
//     poller is guaranteed.
//   In clear-on-read mode an increment arriving on the same cycle as the read is
//   NOT lost — the counter reloads to 1, not to 0. That edge case is asserted.
// =============================================================================
`default_nettype none

module counter_bank #(
    parameter int unsigned N             = 16,     // number of counters, >= 1
    parameter int unsigned W             = 48,     // counter width (see above)
    parameter bit          CLEAR_ON_READ = 1'b0,   // 0 = sticky (default)
    parameter bit          SATURATE      = 1'b1,   // 1 = hold at max (default)
    // DERIVED — do not override.
    parameter int unsigned AW            = (N > 1) ? $clog2(N) : 1
) (
    input  var logic             clk,
    input  var logic             rst,        // synchronous, active high

    // ── Event inputs: one bit per counter, +1 per asserted cycle ─────────────
    input  var logic [N-1:0]     incr,

    // ── Read port (CSR / telemetry side) ────────────────────────────────────
    input  var logic             ren,
    input  var logic [AW-1:0]    raddr,
    output var logic [W-1:0]     rdata,
    output var logic             rvalid,

    // ── Bank control and health ─────────────────────────────────────────────
    input  var logic             clr_all,    // 1-cycle strobe: zero everything
    output var logic [N-1:0]     saturated   // STICKY: this counter hit its max
);

    localparam logic [W-1:0] CNT_ONE = W'(1);
    localparam logic [W-1:0] CNT_MAX = {W{1'b1}};

    logic [W-1:0] cnt_q [N];

    // Per-counter read hit. Only meaningful when CLEAR_ON_READ is set, but
    // computed unconditionally so the two modes share one always_ff.
    logic [N-1:0] rd_clear;

    always_comb begin
        rd_clear = '0;                                    // default (no latch)
        if (CLEAR_ON_READ && ren) begin
            for (int unsigned i = 0; i < N; i++) begin
                rd_clear[i] = (raddr == AW'(i));
            end
        end
    end

    // -------------------------------------------------------------------------
    // The bank. ONE always_ff for the whole array so `cnt_q` and every bit of
    // `saturated` has exactly one driver. The loop unrolls at elaboration into N
    // independent counters that all run in parallel (manual 03 §1).
    // Counters are control state -> they DO get reset (manual 04 §4).
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        for (int unsigned i = 0; i < N; i++) begin
            if (rst || clr_all) begin
                cnt_q[i]     <= '0;
                saturated[i] <= 1'b0;
            end else begin
                // Sticky saturation flag: set on the cycle an increment is lost
                // (or would have wrapped). Never self-clears.
                if (incr[i] && (cnt_q[i] == CNT_MAX)) begin
                    saturated[i] <= 1'b1;
                end

                if (rd_clear[i]) begin
                    // Clear-on-read. A simultaneous increment is preserved: the
                    // counter restarts at 1, not 0, so no event is ever lost to
                    // a poll landing on the same cycle.
                    cnt_q[i] <= incr[i] ? CNT_ONE : '0;
                end else if (incr[i]) begin
                    if (SATURATE && (cnt_q[i] == CNT_MAX)) begin
                        cnt_q[i] <= CNT_MAX;              // hold, do not wrap
                    end else begin
                        cnt_q[i] <= cnt_q[i] + CNT_ONE;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Read port. Registered output (manual 03 §5). The read samples the value
    // BEFORE any clear-on-read takes effect, because both are non-blocking
    // assignments evaluated against the same old value.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (ren) rdata <= cnt_q[raddr];                   // datapath: no reset
    end

    always_ff @(posedge clk) begin
        if (rst) rvalid <= 1'b0;
        else     rvalid <= ren;
    end

    // -------------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    initial begin
        if (N < 1) begin
            $error("counter_bank: N must be >= 1 (got %0d).", N);
            $fatal(1);
        end
        if (W < 8) begin
            $error("counter_bank: W must be >= 8 (got %0d).", W);
            $fatal(1);
        end
        if (W < 48) begin
            $warning("counter_bank: W = %0d. A counter narrower than 48 bits can wrap inside a trading day at 156.25 MHz and will then read as healthy (manual 01.01 §9). Justify this at the instantiation site.", W);
        end
        if (!SATURATE) begin
            $warning("counter_bank: SATURATE = 0. This bank WRAPS. Only correct for a deliberate free-running timebase.");
        end
        if (CLEAR_ON_READ) begin
            $info("counter_bank: CLEAR_ON_READ = 1. Exactly one trusted poller may read this bank; a lost read destroys counts.");
        end
    end

    // Read address must be in range — an out-of-range read returns another
    // counter's value and quietly corrupts a dashboard. Only meaningful when N
    // is not a power of two; otherwise every raddr encoding is a valid counter.
    if ((1 << AW) != int'(N)) begin : g_raddr_range
        assert property (@(posedge clk) disable iff (rst)
            ren |-> (raddr < AW'(N)))
            else $error("counter_bank: read address %0d out of range (N = %0d)", raddr, N);
    end

    assert property (@(posedge clk) disable iff (rst)
        rvalid |-> $past(ren))
        else $error("counter_bank: rvalid without a preceding read");

    genvar c;
    for (c = 0; c < int'(N); c++) begin : g_cnt_checks
        // Counters are monotonic unless deliberately cleared. This is the
        // assertion that catches a wrap.
        assert property (@(posedge clk) disable iff (rst || clr_all)
            (!rd_clear[c]) |=> (cnt_q[c] >= $past(cnt_q[c])))
            else $error("counter_bank: counter %0d WRAPPED — a wrapped counter reads as healthy", c);

        // Saturation is sticky.
        assert property (@(posedge clk) disable iff (rst || clr_all)
            saturated[c] |=> saturated[c])
            else $error("counter_bank: sticky saturated[%0d] self-cleared", c);

        // With SATURATE set, the count never exceeds the maximum and never
        // rolls past it.
        if (SATURATE) begin : g_sat_hold
            assert property (@(posedge clk) disable iff (rst || clr_all)
                ((cnt_q[c] == CNT_MAX) && !rd_clear[c]) |=> (cnt_q[c] == CNT_MAX))
                else $error("counter_bank: counter %0d rolled over despite SATURATE", c);
        end

        // Clear-on-read must not lose a same-cycle increment.
        if (CLEAR_ON_READ) begin : g_cor_no_loss
            assert property (@(posedge clk) disable iff (rst || clr_all)
                (rd_clear[c] && incr[c]) |=> (cnt_q[c] == CNT_ONE))
                else $error("counter_bank: counter %0d lost an increment that raced its read", c);
        end
    end
`endif

endmodule : counter_bank

`default_nettype wire
