// =============================================================================
// latency_hist.sv — Bucketed fabric-latency histogram
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/05-optimization/04-measurement-and-profiling.md §5
//           manuals/06-operations/03-monitoring-and-telemetry.md §3
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   The highest-value instrument in the system. On every completed transaction
//   it takes one cycle-count delta and folds it into a bucket, plus exact
//   min / max / sum / count. The host reads the buckets slowly and computes
//   p50 / p99 / p99.9 offline.
//
//   ⚠ WHAT THIS MEASURES — read this before quoting any number from it.
//
//   1. This instrument measures **FABRIC latency only**: the interval between
//      two core-clock cycle stamps taken inside the FPGA. It contains no
//      optics, no GT PMA/PCS, no gearbox, no elastic buffer, no cable. Per the
//      latency budget in rtl/fpga_top.sv, the IO stack the histogram cannot see
//      is roughly 180 ns of a ~321 ns wire-to-wire target — over half the
//      number. A fabric histogram is therefore NEVER the headline latency.
//
//   2. The wire-to-wire number requires EXTERNAL measurement: a passive tap and
//      a single capture device timestamping both directions on one clock, per
//      manuals/05-optimization/04-measurement-and-profiling.md §2. On-chip
//      measurement is corroborating evidence and per-stage attribution — it is
//      not the headline number, and the DUT cannot be trusted to time itself.
//
//   3. A histogram populated in **simulation is not a measurement of hardware**.
//      Simulation has no routing delay, no thermal drift, no PMA, and no
//      contention with real traffic. Label every number SIMULATED or MEASURED,
//      in capitals, always (§7 and §9 of the same manual). They are not
//      comparable and must never be averaged together.
//
//   WHY LOG2 BUCKETING, AND WHY THE TAIL IS THE POINT
//   ------------------------------------------------------------------
//   In this domain the mean is decoration. Two designs with identical means can
//   differ by hundreds of nanoseconds at p99.9, and it is the p99.9 order that
//   arrives after the queue has already filled — that is the one that loses
//   money. Determinism outranks average speed (CLAUDE.md §5.8).
//
//   A linear histogram sized for the body of the distribution truncates exactly
//   the region that matters: everything past the top bucket collapses into one
//   saturating count and the max you report is not the max. Log2 bucketing
//   spends its resolution where the density is (the body, in single cycles) and
//   still covers 2^DELTA_W cycles with only DELTA_W+1 buckets — so it CANNOT
//   overflow, and the tail is captured for free. 32 buckets covers 0 .. 2^31
//   cycles; the entire realistic range fits with room to spare.
//
//   Run a linear instance too if you want fine resolution around the expected
//   value — that is what LOG_MODE=0 with LIN_BASE/LIN_SHIFT is for. `over_cnt`
//   exists so a linear histogram can never lie about its tail: if it is
//   non-zero, your computed p99.9 is a LOWER BOUND, and you must say so.
//
// -----------------------------------------------------------------------------
// LATENCY  : 0 cycles on the datapath. This is a pure OBSERVER: it has no ready
//            signal, it cannot backpressure, and nothing downstream of it can
//            gate the fast path. Internally 2 pipeline stages from sample_valid
//            to the accumulators; read port is 2-cycle (see rd_count comment).
// RESOURCE : N_BUCKETS*CNT_W live + N_BUCKETS*CNT_W shadow FF, plus min/max/
//            sum/count. For N_BUCKETS=32, CNT_W=32, DELTA_W=24:
//              FF  ~2,300   LUT ~700   BRAM 0   DSP 0
//            ≈0.1 % of a VU9P SLR. Cheap enough that not having it is the only
//            expensive option.
// =============================================================================
`default_nettype none

module latency_hist #(
    // Number of buckets. Must be >= 2. For LOG_MODE=1, bucket k>=1 covers
    // [2^(k-1), 2^k - 1] cycles, so N_BUCKETS = DELTA_W+1 covers everything.
    parameter int unsigned N_BUCKETS = 32,
    // Sample width, in core-clock cycles. 24 b @ 156.25 MHz = 107 ms.
    parameter int unsigned DELTA_W   = 24,
    // Bucket / min / max / sum counter width.
    parameter int unsigned CNT_W     = 32,
    // 1 = log2 bucketing (tail-preserving, cannot overflow) — the default.
    // 0 = linear bucketing: bucket = (delta - LIN_BASE) >> LIN_SHIFT.
    parameter bit          LOG_MODE  = 1'b1,
    // Linear mode only: lower edge of bucket 0, and cycles per bucket = 2^shift.
    parameter logic [DELTA_W-1:0] LIN_BASE  = '0,
    parameter int unsigned        LIN_SHIFT = 0
) (
    input  var logic                     clk,
    input  var logic                     rst,          // sync, active high

    // ── observer input: one sample per completed transaction ─────────────────
    // NO ready. NO backpressure. Ever. (CLAUDE.md §5, manual 06.03 §1.2)
    input  var logic                     sample_valid,
    input  var logic [DELTA_W-1:0]       sample_cycles,

    // ── snapshot / clear, driven from the read side ──────────────────────────
    // snap  : 1-cycle pulse. Latches live accumulators into the shadow bank in
    //         ONE cycle so the host reads a mutually consistent set. Sampling
    //         continues into the live bank during the read — no events lost.
    // clear : 1-cycle pulse. Zeroes the LIVE bank only.
    //         ⚠ Clearing discards whatever has accumulated since the last snap.
    //         Prefer read-without-clear plus host-side differencing; clear only
    //         at a defined boundary such as start of day
    //         (manuals/06-operations/03-monitoring-and-telemetry.md §3).
    input  var logic                     snap,
    input  var logic                     clear,

    // ── read port (slow domain crosses OUTSIDE this module) ──────────────────
    input  var logic [$clog2(N_BUCKETS)-1:0] rd_idx,
    output var logic [CNT_W-1:0]             rd_count,
    output var logic [DELTA_W-1:0]           rd_min,
    output var logic [DELTA_W-1:0]           rd_max,
    output var logic [CNT_W+DELTA_W-1:0]     rd_sum,
    output var logic [CNT_W-1:0]             rd_n,
    output var logic [CNT_W-1:0]             rd_over,   // above the top bucket
    output var logic [DELTA_W-1:0]           rd_last,   // most recent sample
    output var logic                         rd_sat     // sticky: a counter
                                                        // saturated; buckets
                                                        // now UNDERSTATE ⚠
);

    localparam int unsigned IDX_W  = $clog2(N_BUCKETS);
    localparam int unsigned SUM_W  = CNT_W + DELTA_W;
    localparam logic [CNT_W-1:0]  CNT_MAX = {CNT_W{1'b1}};
    localparam logic [SUM_W-1:0]  SUM_MAX = {SUM_W{1'b1}};
    localparam logic [DELTA_W-1:0] DELTA_MAX = {DELTA_W{1'b1}};

    // =========================================================================
    // Stage 1 — bucket index (combinational)
    // =========================================================================
    logic [DELTA_W:0]   raw_idx;      // one bit wider: detects overflow
    logic [IDX_W-1:0]   idx_d;
    logic               over_d;
    logic [DELTA_W-1:0] rel;
    logic [DELTA_W:0]   msb_pos;      // 0 = no bit set

    always_comb begin
        // Defaults first — no latches, ever.
        rel     = '0;
        msb_pos = '0;
        raw_idx = '0;
        idx_d   = '0;
        over_d  = 1'b0;

        // Position of the most significant set bit, +1. Unrolls into a
        // priority encoder; DELTA_W is a compile-time constant (CLAUDE.md §5.2).
        for (int i = 0; i < int'(DELTA_W); i++) begin
            if (sample_cycles[i]) begin
                msb_pos = (DELTA_W+1)'(i + 1);
            end
        end

        if (LOG_MODE) begin
            // Bucket 0 = delta 0. Bucket k = [2^(k-1) .. 2^k - 1].
            raw_idx = msb_pos;
        end else begin
            rel     = (sample_cycles > LIN_BASE) ? (sample_cycles - LIN_BASE)
                                                 : DELTA_W'(0);
            raw_idx = (DELTA_W+1)'(rel >> LIN_SHIFT);
        end

        if (raw_idx >= (DELTA_W+1)'(N_BUCKETS)) begin
            idx_d  = IDX_W'(N_BUCKETS - 1);   // saturate into the top bucket
            over_d = 1'b1;                    // ...and count it separately ⚠
        end else begin
            idx_d  = raw_idx[IDX_W-1:0];
            over_d = 1'b0;
        end
    end

    // =========================================================================
    // Stage 2 — register the encoder output so it is not in the counter path
    // =========================================================================
    logic               v_q;
    logic               over_q;
    logic [IDX_W-1:0]   idx_q;
    logic [DELTA_W-1:0] dly_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            v_q    <= 1'b0;
            over_q <= 1'b0;
        end else begin
            v_q    <= sample_valid;
            over_q <= over_d;
        end
        // Datapath registers: no reset needed, they are qualified by v_q.
        idx_q <= idx_d;
        dly_q <= sample_cycles;
    end

    // =========================================================================
    // Stage 3 — live accumulators
    // -----------------------------------------------------------------------------
    // Registers, not RAM: a register array supports read-modify-write in the
    // same cycle, so back-to-back samples into the SAME bucket both count.
    // A BRAM here would silently drop one of them.
    //
    // Every counter SATURATES rather than wrapping. A wrapped histogram bucket
    // is a lie that looks like data; a saturated one is flagged by rd_sat and
    // the host knows to treat the bank as a lower bound.
    // =========================================================================
    logic [CNT_W-1:0]   bucket_q [N_BUCKETS];
    logic [DELTA_W-1:0] min_q;
    logic [DELTA_W-1:0] max_q;
    logic [SUM_W-1:0]   sum_q;
    logic [CNT_W-1:0]   n_q;
    logic [CNT_W-1:0]   over_cnt_q;
    logic [DELTA_W-1:0] last_q;
    logic               sat_q;

    always_ff @(posedge clk) begin
        if (rst || clear) begin
            for (int b = 0; b < int'(N_BUCKETS); b++) begin
                bucket_q[b] <= '0;
            end
            min_q      <= DELTA_MAX;    // so the first sample always wins
            max_q      <= '0;
            sum_q      <= '0;
            n_q        <= '0;
            over_cnt_q <= '0;
            last_q     <= '0;
            sat_q      <= 1'b0;
        end else if (v_q) begin
            if (bucket_q[idx_q] != CNT_MAX) begin
                bucket_q[idx_q] <= bucket_q[idx_q] + CNT_W'(1);
            end else begin
                sat_q <= 1'b1;
            end

            if (dly_q < min_q) min_q <= dly_q;
            if (dly_q > max_q) max_q <= dly_q;

            if (sum_q > (SUM_MAX - SUM_W'(dly_q))) begin
                sum_q <= SUM_MAX;
                sat_q <= 1'b1;
            end else begin
                sum_q <= sum_q + SUM_W'(dly_q);
            end

            if (n_q != CNT_MAX) begin
                n_q <= n_q + CNT_W'(1);
            end else begin
                sat_q <= 1'b1;
            end

            if (over_q && (over_cnt_q != CNT_MAX)) begin
                over_cnt_q <= over_cnt_q + CNT_W'(1);
            end

            last_q <= dly_q;
        end
    end

    // =========================================================================
    // Snapshot shadow — the host reads a coherent set
    // -----------------------------------------------------------------------------
    // Without this, buckets read at different instants do not sum to N, and the
    // percentile you compute describes a distribution that never existed
    // (manuals/06-operations/03-monitoring-and-telemetry.md §9).
    // Sampling continues into the live bank while the host reads the shadow, so
    // the read window loses NO events.
    // =========================================================================
    logic [CNT_W-1:0]   shadow_q [N_BUCKETS];
    logic [DELTA_W-1:0] s_min_q;
    logic [DELTA_W-1:0] s_max_q;
    logic [SUM_W-1:0]   s_sum_q;
    logic [CNT_W-1:0]   s_n_q;
    logic [CNT_W-1:0]   s_over_q;
    logic [DELTA_W-1:0] s_last_q;
    logic               s_sat_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int b = 0; b < int'(N_BUCKETS); b++) begin
                shadow_q[b] <= '0;
            end
            s_min_q  <= DELTA_MAX;
            s_max_q  <= '0;
            s_sum_q  <= '0;
            s_n_q    <= '0;
            s_over_q <= '0;
            s_last_q <= '0;
            s_sat_q  <= 1'b0;
        end else if (snap) begin
            for (int b = 0; b < int'(N_BUCKETS); b++) begin
                shadow_q[b] <= bucket_q[b];
            end
            s_min_q  <= min_q;
            s_max_q  <= max_q;
            s_sum_q  <= sum_q;
            s_n_q    <= n_q;
            s_over_q <= over_cnt_q;
            s_last_q <= last_q;
            s_sat_q  <= sat_q;
        end
    end

    // =========================================================================
    // Read port
    // -----------------------------------------------------------------------------
    // COMBINATIONAL OUTPUTS — justified exception to the registered-output rule
    // (manuals/00-foundations/03-hdl-and-rtl-coding.md §5): the only consumer is
    // telemetry.sv's read mux, which registers rdata. Registering here would add
    // a third cycle to a purely slow-path BAR read for no timing benefit, and
    // would make the telemetry read latency depend on which region was
    // addressed. All of these paths are constrained as slow-path multicycle in
    // constraints/ — they never touch the fast path.
    // =========================================================================
    assign rd_count = shadow_q[rd_idx];
    assign rd_min   = s_min_q;
    assign rd_max   = s_max_q;
    assign rd_sum   = s_sum_q;
    assign rd_n     = s_n_q;
    assign rd_over  = s_over_q;
    assign rd_last  = s_last_q;
    assign rd_sat   = s_sat_q;

    // =========================================================================
    // Assertions — simulation only
    // =========================================================================
`ifndef SYNTHESIS
    initial begin
        if (N_BUCKETS < 2) begin
            $fatal(1, "latency_hist: N_BUCKETS must be >= 2 (got %0d)", N_BUCKETS);
        end
        if (LOG_MODE && (N_BUCKETS < (DELTA_W + 1))) begin
            $warning("latency_hist: LOG_MODE with N_BUCKETS(%0d) < DELTA_W+1(%0d): the top bucket will saturate and rd_over will be non-zero. p99.9 becomes a lower bound.",
                     N_BUCKETS, DELTA_W + 1);
        end
    end

    // Log2 bucketing must never overflow when the map is fully sized.
    assert property (@(posedge clk) disable iff (rst)
        (LOG_MODE && (N_BUCKETS >= (DELTA_W + 1))) |-> !over_d
    ) else $error("latency_hist: log2 mode overflowed a fully-sized bucket map");

    // The observer must never be able to stall anything: there is no ready
    // port, so the structural property to check is that a sample is always
    // consumed exactly one cycle later.
    assert property (@(posedge clk) disable iff (rst)
        sample_valid |=> v_q
    ) else $error("latency_hist: sample dropped between stage 1 and stage 2");

    // Snapshot coherence: immediately after a snap with no intervening samples,
    // the shadow count must equal the live count.
    assert property (@(posedge clk) disable iff (rst)
        (snap && !v_q) |=> (s_n_q == $past(n_q))
    ) else $error("latency_hist: snapshot did not capture the live count");

    // min <= max whenever at least one sample has landed.
    assert property (@(posedge clk) disable iff (rst)
        (n_q != '0) |-> (min_q <= max_q)
    ) else $error("latency_hist: min exceeded max");
`endif

endmodule : latency_hist

`default_nettype wire
