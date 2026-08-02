// =============================================================================
// fixed_arbiter.sv — Fixed-priority arbiter with per-requester starvation counters
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/01-fpga-design/01-rtl-design-patterns.md §4, §9
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   Grant to the lowest-numbered requester. Requester 0 is the HIGHEST priority
//   and is granted in zero extra cycles, always, regardless of what anyone else
//   is doing.
//
//   This is the arbiter for the tick-to-trade path (manual §4): "for a trading
//   fast path, prefer fixed priority with the latency-critical path at priority
//   0. Determinism on the path that matters beats fairness across paths that
//   don't." Put the market-data / order-emit path at index 0 and the control,
//   telemetry, and host paths behind it.
//
// LATENCY
//   0 cycles, and — unlike round robin — ZERO JITTER for requester 0. That
//   determinism is the whole point (CLAUDE.md §5.8).
//
// RESOURCE (N=4, STARVE_W=32)
//   1 N-bit carry chain + small OR tree + N * STARVE_W counter FF.
//   N=4, STARVE_W=32 -> ~128 FF + ~4 adders + ~30 LUT. 0 BRAM. 0 DSP.
//   The counters dominate; drop STARVE_W if the bank is expensive, but do not
//   drop the counters (see below).
//
// -----------------------------------------------------------------------------
// ⚠️  FIXED PRIORITY STARVES LOWER-PRIORITY REQUESTERS UNDER SUSTAINED LOAD.
//   That is a design choice, not an accident — but the manual is explicit
//   (§4): "Count starvation events so you know if the low-priority path is
//   being neglected." `starve_cnt[i]` counts every CYCLE requester i asked and
//   did not get the resource. Wire it into `counter_bank` / telemetry and put it
//   on the dashboard. A low-priority path that is quietly never served looks
//   exactly like a path that has nothing to do, right up until the day it
//   matters — and CLAUDE.md §5.7 makes silent failure the worst failure mode.
//
// ⚠️  THE COUNTERS SATURATE, THEY DO NOT WRAP (manual §9). A wrapped starvation
//   counter reads as "healthy" and is worse than no counter at all. `starve_sat`
//   is a sticky per-requester flag telling the host the number is a floor, not
//   a value. STARVE_W = 32 at 156.25 MHz saturates after ~27 s of CONTINUOUS
//   starvation; use 48 if you want a full session without saturating.
//
// ⚠️  `grant` IS COMBINATIONAL — the same justified exception as rr_arbiter.
//   Registering it would add a cycle to the highest-priority path, which is the
//   one thing this module exists to protect.
// =============================================================================
`default_nettype none

module fixed_arbiter #(
    parameter int unsigned N        = 4,    // requesters; index 0 = highest priority
    parameter int unsigned STARVE_W = 32,   // starvation counter width
    // DERIVED — do not override.
    parameter int unsigned IDX_W    = (N > 1) ? $clog2(N) : 1
) (
    input  var logic                clk,
    input  var logic                rst,           // synchronous, active high
    input  var logic                en,            // 0 = hold all grants low
    input  var logic [N-1:0]        req,
    output var logic [N-1:0]        grant,         // ONE-HOT, or all zero
    output var logic                grant_valid,
    output var logic [IDX_W-1:0]    grant_idx,

    // ── Telemetry (CLAUDE.md §5.7, manual 01.01 §4) ──────────────────────────
    // Cycles requester i asserted req and was not granted. Saturating.
    output var logic [STARVE_W-1:0] starve_cnt  [N],
    // Sticky: this requester's counter has saturated; the count is a floor.
    output var logic [N-1:0]        starve_sat,
    input  var logic                starve_clr     // 1-cycle strobe: zero the bank
);

    localparam logic [N-1:0]        N_ONE      = N'(1);
    localparam logic [STARVE_W-1:0] STARVE_ONE = STARVE_W'(1);
    localparam logic [STARVE_W-1:0] STARVE_MAX = {STARVE_W{1'b1}};

    // -------------------------------------------------------------------------
    // Arbitration: isolate the lowest set bit. On UltraScale+ this maps to the
    // CARRY8 chain, not to a LUT priority chain (see prio_encoder for why that
    // matters). For N > 32 use prio_encoder hierarchically instead.
    // -------------------------------------------------------------------------
    logic [N-1:0] grant_c;

    assign grant_c = req & (~req + N_ONE);

    always_comb begin
        grant       = '0;                     // default (no latch)
        grant_valid = 1'b0;
        if (en) begin
            grant       = grant_c;
            grant_valid = |req;
        end
    end

    // One-hot -> binary by OR reduction.
    always_comb begin
        grant_idx = '0;                       // default (no latch)
        for (int unsigned i = 0; i < N; i++) begin
            grant_idx = grant_idx | (IDX_W'(i) & {IDX_W{grant[i]}});
        end
    end

    // -------------------------------------------------------------------------
    // Starvation telemetry. A requester is starved on any cycle it is asking and
    // not being granted — including cycles where `en` is low, because a resource
    // that is switched off is still a resource the requester is not getting.
    // -------------------------------------------------------------------------
    logic [N-1:0] starving;

    always_comb begin
        starving = '0;                        // default (no latch)
        for (int unsigned i = 0; i < N; i++) begin
            starving[i] = req[i] && !grant[i];
        end
    end

    // One always_ff for the whole bank: a single driver for `starve_cnt` and for
    // every bit of `starve_sat`. Splitting this across generate blocks would
    // give the packed `starve_sat` vector N procedural drivers.
    always_ff @(posedge clk) begin
        for (int unsigned c = 0; c < N; c++) begin
            if (rst || starve_clr) begin
                starve_cnt[c] <= '0;
                starve_sat[c] <= 1'b0;
            end else if (starving[c]) begin
                if (starve_cnt[c] == STARVE_MAX) begin
                    starve_cnt[c] <= STARVE_MAX;      // SATURATE, never wrap
                    starve_sat[c] <= 1'b1;            // sticky
                end else begin
                    starve_cnt[c] <= starve_cnt[c] + STARVE_ONE;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    initial begin
        if (N < 2) begin
            $error("fixed_arbiter: N must be >= 2 (got %0d).", N);
            $fatal(1);
        end
        if (STARVE_W < 8) begin
            $error("fixed_arbiter: STARVE_W must be >= 8 (got %0d).", STARVE_W);
            $fatal(1);
        end
        if (N > 32) begin
            $warning("fixed_arbiter: N = %0d. Above ~32 the flat isolate becomes a long carry chain; build it hierarchically (manual 01.01 §4).", N);
        end
    end

    // Grant is one-hot or zero.
    assert property (@(posedge clk) disable iff (rst)
        $onehot0(grant))
        else $error("fixed_arbiter: grant is not one-hot");

    assert property (@(posedge clk) disable iff (rst)
        grant_valid == (grant != '0))
        else $error("fixed_arbiter: grant_valid disagrees with grant");

    assert property (@(posedge clk) disable iff (rst)
        (grant & ~req) == '0)
        else $error("fixed_arbiter: granted a non-requester");

    assert property (@(posedge clk) disable iff (rst)
        !en |-> (grant == '0 && !grant_valid))
        else $error("fixed_arbiter: granted while disabled");

    // THE defining property: requester 0 is never made to wait. If this fails,
    // the fast path has lost its determinism guarantee.
    assert property (@(posedge clk) disable iff (rst)
        (en && req[0]) |-> grant[0])
        else $error("fixed_arbiter: priority-0 requester not granted immediately — determinism lost");

    // No grant to i while any j < i is asking.
    genvar a;
    for (a = 1; a < int'(N); a++) begin : g_priority
        assert property (@(posedge clk) disable iff (rst)
            grant[a] |-> (req[a-1:0] == '0))
            else $error("fixed_arbiter: granted %0d while a higher-priority requester was asking", a);
    end

    assert property (@(posedge clk) disable iff (rst)
        grant_valid |-> grant[grant_idx])
        else $error("fixed_arbiter: grant_idx %0d does not match the one-hot grant", grant_idx);

    // Counters saturate rather than wrap — the whole point of §9.
    for (a = 0; a < int'(N); a++) begin : g_sat
        assert property (@(posedge clk) disable iff (rst || starve_clr)
            starve_cnt[a] >= $past(starve_cnt[a]))
            else $error("fixed_arbiter: starve_cnt[%0d] WRAPPED — a wrapped counter reads as healthy", a);

        assert property (@(posedge clk) disable iff (rst || starve_clr)
            starve_sat[a] |-> (starve_cnt[a] == STARVE_MAX))
            else $error("fixed_arbiter: starve_sat[%0d] set without a saturated count", a);
    end
`endif

endmodule : fixed_arbiter

`default_nettype wire
