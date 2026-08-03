// =============================================================================
// prio_encoder.sv — hierarchical priority encoder, either direction
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/01-fpga-design/01-rtl-design-patterns.md §4, §6
//           manuals/00-foundations/03-hdl-and-rtl-coding.md (coding standard)
//           manuals/00-foundations/05-timing-closure.md §3 (logic-level budget)
//           docs/ORDER-BOOK-REDESIGN.md §3.3, §3.4 (why 2048 levels)
//
// PURPOSE
//   Find the EXTREME occupied index of an N-bit request vector.
//
//     REVERSE = 0  ->  the LOWEST  set bit.  Ask book: best = lowest price level.
//     REVERSE = 1  ->  the HIGHEST set bit.  Bid book: best = highest price level.
//
//   This is the order book's "find the new best level" primitive. When a delete
//   empties the CURRENT BEST level, the new best is found by priority-encoding
//   that side's occupancy bitmap. It is the only variable-latency operation in
//   the whole tick-to-trade path, so both its cycle bound and its Fmax are
//   load-bearing. It is also the core of both arbiters.
//
// LATENCY  (cycles, and ns at 6.400 ns/cycle — core_clk = 156.25 MHz)
//   PIPELINE = 0 : 0 cycles,   0.0 ns   fully combinational; idx and valid comb.
//   PIPELINE = 1 : 1 cycle,    6.4 ns   one register between the two levels.
//                                       `valid` is registered; `idx` is 2-3 LUT
//                                       levels of combinational logic out of
//                                       that register (see §4 below).
//   PIPELINE = 2 : 2 cycles,  12.8 ns   as PIPELINE=1, plus registered outputs.
//
//   ⚠️ THE CYCLE COUNT IS EXACTLY `PIPELINE`, FOR EVERY INPUT, ALWAYS. There is
//      no data-dependent path anywhere in this module: the structure is a fixed
//      reduction tree, not a search loop. That is the whole point — the book
//      needs a BOUNDED new-best latency, and this bound is a constant, not a
//      worst case. tb/common/test_prio_encoder.py asserts it as an equality.
//
// RESOURCE (ESTIMATES — NOTHING HERE HAS BEEN SYNTHESIZED, see §5)
//   N=2048, GROUP_W=32  ->  NG=64 groups x 32 bits, IDX_W=11
//     level 1  : 64 x (32-bit isolate + 32-input OR + one-hot->5-bit OR tree)
//     level 2  : 64-bit isolate + 6-bit OR tree + 64-way 5-bit OR-mux
//     LUT6     : ~3.2 k  (band 2.5 k - 4.5 k; Vivado will re-map the isolate
//                onto CARRY8 and the OR trees onto LUT6 cascades)
//     FF       : PIPELINE=0 -> 0
//                PIPELINE=1 -> 386  (64 one-hot + 64x5 sub-index + valid + dir)
//                PIPELINE=2 -> 398  (+ 11 idx + 1 valid)
//     BRAM/DSP : 0 / 0
//   N=16, GROUP_W=32 (clamped to 8) -> NG=2: ~20 LUT6. This is the geometry
//   rtl/book/top_of_book.sv gets today, unchanged from the previous GROUP=8.
//   > Verify every number above against the post-synthesis utilization report.
//
// -----------------------------------------------------------------------------
// 1. STRUCTURE — why not a flat encoder
// -----------------------------------------------------------------------------
//   A flat 2048-input priority chain is a deep LUT chain and will not close
//   timing at 156.25 MHz, let alone leave headroom (manual 00.03 §7 names it
//   explicitly; manual 01.01 §4 says "build it hierarchically"). So:
//
//     N bits ─┬─ per-group encode  x NG, ALL IN PARALLEL ──┐
//             │    isolate lowest set bit in the group,    │
//             │    one-hot -> SUB_W binary                 │  grp_sub[g]
//             │                                            │
//             └─ group summary  (OR-reduce per group, or ──┤  grp_any[g]
//                  supplied by the caller — see §3)        │
//                                     │                    │
//                     isolate lowest set group ────────────┤  grp_onehot
//                                     │                    │
//                          ┌──────────┴───────────┐        │
//                     grp_idx (GRP_W)        sub_sel  <────┘
//                          └──────────┬───────────┘   (OR-mux, one-hot select)
//                                     │
//                       idx = {grp_idx, sub_sel}  ── pure CONCATENATION
//
//   The two levels overlap in time: the NG per-group encoders run concurrently
//   with the group summary and the group-level isolate. Only the final 5-bit
//   OR-mux is genuinely serialised after level 2, and it is 5 bits wide rather
//   than 32, which is why the sub-indices are computed up front instead of
//   muxing the winning group's raw 32 bits.
//
//   GROUP_W is a power of two, so `idx = grp_idx * GROUP_W + sub_sel` is a plain
//   concatenation: no multiplier, no adder (CLAUDE.md §5.3).
//
//   Each isolate is `x & (~x + 1)`. On UltraScale+ that two's-complement negate
//   maps onto the dedicated CARRY8 chain — a 32-bit isolate is 4 CARRY8 (~0.6 ns)
//   against roughly 16 LUT levels for a `for`-loop priority chain. One-hot to
//   binary is then a balanced OR tree, log2 deep, never a priority mux chain.
//
// -----------------------------------------------------------------------------
// 2. DIRECTION — do NOT bit-reverse a 2048-bit vector at the call site
// -----------------------------------------------------------------------------
//   A bid book's best is the HIGHEST occupied level; an ask book's is the
//   LOWEST. rtl/book/top_of_book.sv currently reverses the bid mask itself in an
//   always_comb before calling this module and reflects the index afterwards.
//   At 16 levels that is merely ugly. At 2048 it is expensive and it is exactly
//   the kind of index arithmetic that is easy to get backwards — and getting it
//   backwards means quoting on the wrong side of the book.
//
//   So the reversal lives HERE, where it costs nothing:
//     * the input remap is pure WIRING when the direction is a parameter;
//     * the output reflect is `N-1-idx`, which for a power-of-two N is exactly
//       `~idx` — a bitwise NOT, one LUT level that folds into the output.
//
//   REVERSE  : compile-time direction. FREE. This is what the book should use —
//              it instantiates one encoder per side and each side's direction is
//              fixed forever.
//   dir_rev  : optional RUNTIME direction, XORed with REVERSE. Only generated
//              when DYN_DIR=1; then it costs a 2:1 mux per input bit (~N/2 LUT)
//              and one extra LUT level at the front. Leave DYN_DIR=0 unless a
//              caller genuinely needs to flip direction cycle by cycle.
//
// -----------------------------------------------------------------------------
// 3. GROUP SUMMARY — the caller may already have one
// -----------------------------------------------------------------------------
//   By default the module OR-reduces each group itself. That costs ~7 LUT per
//   group and, more importantly, sits at the FRONT of the critical path.
//
//   If the caller already maintains a per-group "any level occupied" summary —
//   and rtl/book/price_levels.sv does, because it has to touch the group on
//   every level update anyway — set SUMMARY_IN=1 and drive `grp_sum_in`. That
//   removes the OR-reduce entirely and takes roughly 0.5-0.7 ns off the level-2
//   path.
//
//   ⚠️ `grp_sum_in` is ALWAYS IN NATURAL ORDER: bit g means "req[g*GROUP_W +:
//      GROUP_W] is non-zero". The module reverses the group order internally
//      when the direction is reversed. Do not pre-reverse it. There is an
//      assertion below that recomputes the summary from `req` and fails if the
//      supplied one disagrees, because a wrong summary produces a confidently
//      wrong best level with no other symptom.
//
// -----------------------------------------------------------------------------
// 4. Fmax — ESTIMATES ONLY. Nothing in this file has been synthesized.
// -----------------------------------------------------------------------------
//   Hand-counted logic levels plus typical UltraScale+ (-2) delays, with routing
//   guessed at 40-60 % of the path because a 2048-bit fan-in spreads over a
//   large region. Manual 00.05 §2 is blunt about this: synthesis estimates are
//   optimistic by 20-40 % and only post-route timing counts. Treat every number
//   below as a hypothesis to be falsified by `make -C scripts impl`.
//
//     N=2048, GROUP_W=32       est. worst path      est. Fmax    at 156.25 MHz
//     PIPELINE=0               4.5 - 5.5 ns         180-220 MHz  ⚠️ 70-85 % of
//                                                                the period. Do
//                                                                not use.
//     PIPELINE=1               3.0 - 3.5 ns         285-330 MHz  ~3 ns headroom
//     PIPELINE=2               3.0 - 3.5 ns         285-330 MHz  same, and both
//                                                                boundaries are
//                                                                registered
//     N=16, any PIPELINE       < 2.0 ns             > 500 MHz
//
//   PIPELINE=1 and PIPELINE=2 have the SAME internal worst stage (level 1 plus
//   the group isolate). The difference is whose cycle the final OR-mux eats:
//   at PIPELINE=1 it comes out of the CONSUMER's period, at PIPELINE=2 it does
//   not. Choose 2 only if the consumer is itself tight, and then update the
//   latency table in rtl/fpga_top.sv, because it is a real extra cycle.
//
// -----------------------------------------------------------------------------
// 5. ⚠️ CAVEATS
// -----------------------------------------------------------------------------
//   ⚠️ `valid` IS NOT OPTIONAL, AND `idx` IS NOT ZEROED WHEN IT IS LOW. With
//      `req` all zeros, `idx` reads 0 for REVERSE=0 and N-1 for REVERSE=1 —
//      both of which are perfectly legal answers that the consumer cannot tell
//      apart from a real one. It is left that way on purpose: forcing idx to
//      zero costs an AND on every output bit, on the critical path, to produce
//      a value that is still a lie. Consumers MUST qualify with `valid`.
//      `valid` itself is asserted below to be low if and only if req == 0, in
//      both directions and at every PIPELINE setting.
//
//   ⚠️ DO NOT USE THIS TO RECOMPUTE A MAXIMUM EVERY TICK. Maintain the best
//      level incrementally and call this only on the delete-the-best case, which
//      is the one variable-latency stage the top-level budget accounts for
//      (manual 01.01 §6, rtl/fpga_top.sv latency table).
//
//   ⚠️ N must be a POWER OF TWO. The index concatenation and the `~idx` reflect
//      both depend on it. Checked at elaboration.
//
//   ⚠️ The optional ports carry IEEE 1800-2017 default port values, so an
//      existing connection list that does not mention them still elaborates and
//      still behaves exactly as before. If a tool in your flow predates default
//      port values, tie `dir_rev` to 1'b0 and `grp_sum_in` to '0 explicitly.
// =============================================================================
`default_nettype none

module prio_encoder #(
    parameter int unsigned N          = 64,   // request bits; power of two, 16..4096
    parameter int unsigned GROUP_W    = 32,   // bits per group; power of two
    parameter int unsigned PIPELINE   = 0,    // 0 = comb, 1 = mid reg, 2 = + reg out
    parameter int unsigned REVERSE    = 0,    // 0 = lowest set bit, 1 = highest
    parameter int unsigned DYN_DIR    = 0,    // 1 = honour the `dir_rev` input
    parameter int unsigned SUMMARY_IN = 0,    // 1 = take `grp_sum_in`, skip OR-reduce
    // DERIVED — never override at an instantiation site. These live in the
    // parameter list only because SystemVerilog will not let a body-scoped
    // localparam size a port.
    parameter int unsigned IDX_W      = $clog2(N),
    parameter int unsigned NGROUPS    = N >> $clog2((GROUP_W >= N) ? (N >> 1) : GROUP_W)
) (
    // clk/rst are unused when PIPELINE == 0. They stay in the port list so the
    // parameter can be changed at an instantiation site without editing the
    // connection list.
    /* verilator lint_off UNUSED */
    input  var logic                 clk,
    input  var logic                 rst,          // synchronous, active high
    /* verilator lint_on UNUSED */
    input  var logic [N-1:0]         req,
    output var logic [IDX_W-1:0]     idx,          // extreme set index, per direction
    output var logic                 valid,        // 1 = at least one request

    // ── Optional inputs. Defaulted so every existing caller is unaffected. ────
    input  var logic                 dir_rev    = 1'b0,   // ignored if DYN_DIR=0
    input  var logic [NGROUPS-1:0]   grp_sum_in = '0      // ignored if SUMMARY_IN=0
);

    // -------------------------------------------------------------------------
    // Geometry. All elaboration-time. No divider, no modulo (CLAUDE.md §5.3):
    // N and GROUP_W are powers of two, so the division is a shift.
    // -------------------------------------------------------------------------
    // GROUP_W is clamped to N/2 so there are always at least two groups. With
    // the default GROUP_W=32 and N=16 this yields 2 groups of 8 — bit-identical
    // geometry to the previous GROUP=8 default, which is what top_of_book.sv
    // instantiates today.
    localparam int unsigned GW    = (GROUP_W >= N) ? (N >> 1) : GROUP_W;
    localparam int unsigned SUB_W = $clog2(GW);
    localparam int unsigned NG    = NGROUPS;               // == N >> SUB_W
    localparam int unsigned GRP_W = $clog2(NG);            // IDX_W == GRP_W + SUB_W

    localparam logic [GW-1:0] GW_ONE = GW'(1);
    localparam logic [NG-1:0] NG_ONE = NG'(1);

    // -------------------------------------------------------------------------
    // Direction. Constant-folded away entirely when DYN_DIR = 0.
    // -------------------------------------------------------------------------
    logic rev;                                   // 1 = report the HIGHEST set bit
    assign rev = (DYN_DIR != 0) ? ((REVERSE != 0) ^ dir_rev)
                                : (REVERSE != 0);

    // Direction-mapped request vector. Reversing the bit order turns "highest
    // set bit" into "lowest set bit", so exactly one encoder structure is built
    // and only the wiring differs. Pure wiring when `rev` is a constant.
    logic [N-1:0] req_eff;
    always_comb begin
        req_eff = req;                                     // default (no latch)
        if (rev) begin
            for (int unsigned i = 0; i < N; i++) begin
                req_eff[i] = req[(N - 1) - i];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Level 1 — NG per-group encoders, all in parallel
    // -------------------------------------------------------------------------
    logic [NG-1:0][GW-1:0]    g_vec;         // this group's slice of req_eff
    logic [NG-1:0][GW-1:0]    g_onehot;      // its lowest set bit, isolated
    logic [NG-1:0][SUB_W-1:0] grp_sub;       // that bit's index within the group
    logic [NG-1:0]            sum_nat;       // group summary, NATURAL order
    logic [NG-1:0]            grp_any;       // group summary, direction-mapped

    // The group summary: OR-reduce here, or take the caller's precomputed one.
    // See §3 — `grp_sum_in` is natural order and is reversed below with the rest.
    always_comb begin
        sum_nat = '0;                                      // default (no latch)
        if (SUMMARY_IN != 0) begin
            sum_nat = grp_sum_in;
        end else begin
            for (int unsigned g = 0; g < NG; g++) begin
                sum_nat[g] = |req[g*GW +: GW];
            end
        end
    end

    // Effective group g is natural group NG-1-g when the direction is reversed,
    // because req_eff is req bit-reversed. Wiring only.
    always_comb begin
        grp_any = sum_nat;                                 // default (no latch)
        if (rev) begin
            for (int unsigned g = 0; g < NG; g++) begin
                grp_any[g] = sum_nat[(NG - 1) - g];
            end
        end
    end

    // All NG group encoders in one always_comb — they are independent and run
    // concurrently in hardware; a single block keeps each signal to one driver.
    // The loops unroll at elaboration (manual 00.03 §1).
    always_comb begin
        g_vec    = '0;                                     // defaults (no latch)
        g_onehot = '0;
        grp_sub  = '0;
        for (int unsigned g = 0; g < NG; g++) begin
            g_vec[g]    = req_eff[g*GW +: GW];
            // Isolate the lowest set bit. Maps to the CARRY8 chain.
            g_onehot[g] = g_vec[g] & (~g_vec[g] + GW_ONE);
            // One-hot -> binary as a balanced OR tree. g_onehot has at most one
            // bit set, so OR-ing the masked indices IS a select, and synthesis
            // builds it log2(GW) deep instead of as a priority mux chain.
            for (int unsigned i = 0; i < GW; i++) begin
                grp_sub[g] = grp_sub[g] | (SUB_W'(i) & {SUB_W{g_onehot[g][i]}});
            end
        end
    end

    // -------------------------------------------------------------------------
    // Level 2a — isolate the winning group
    // -------------------------------------------------------------------------
    logic [NG-1:0] grp_onehot_c;
    logic          valid_c;

    assign grp_onehot_c = grp_any & (~grp_any + NG_ONE);
    assign valid_c      = |grp_any;

    // -------------------------------------------------------------------------
    // The pipeline cut (PIPELINE >= 1)
    // -------------------------------------------------------------------------
    // Placed here, after the group isolate rather than before it, because that
    // is the BALANCED split: level 1 plus the NG-bit carry chain is the long
    // half, and the final encode-and-select is the short one. Cutting before the
    // isolate would leave ~2.1 ns downstream of the register instead of ~1.0 ns,
    // and the consumer pays that difference out of its own period.
    logic [NG-1:0]            grp_onehot_s;
    logic [NG-1:0][SUB_W-1:0] grp_sub_s;
    logic                     valid_s;
    logic                     rev_s;

    generate
        if (PIPELINE >= 1) begin : g_stage1_reg
            logic [NG-1:0]            oh_q;
            logic                     v_q;
            logic                     rev_q;
            logic [NG-1:0][SUB_W-1:0] sub_q;

            // One-hot select and valid are qualifiers -> reset (manual 00.03 §6).
            always_ff @(posedge clk) begin
                if (rst) begin
                    oh_q <= '0;
                    v_q  <= 1'b0;
                end else begin
                    oh_q <= grp_onehot_c;
                    v_q  <= valid_c;
                end
            end

            // Datapath -> no reset. `rev_q` travels WITH the data: if a caller
            // flips dir_rev while a result is in flight, the reflect at the end
            // must use the direction that produced it, not the current one.
            always_ff @(posedge clk) begin
                sub_q <= grp_sub;
                rev_q <= rev;
            end

            assign grp_onehot_s = oh_q;
            assign grp_sub_s    = sub_q;
            assign valid_s      = v_q;
            assign rev_s        = rev_q;
        end else begin : g_stage1_comb
            assign grp_onehot_s = grp_onehot_c;
            assign grp_sub_s    = grp_sub;
            assign valid_s      = valid_c;
            assign rev_s        = rev;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Level 2b — encode the group, select its sub-index, reflect if reversed
    // -------------------------------------------------------------------------
    logic [GRP_W-1:0] grp_idx;
    logic [SUB_W-1:0] sub_sel;
    logic [IDX_W-1:0] idx_low;                  // index into the EFFECTIVE vector
    logic [IDX_W-1:0] idx_c;

    // Both reductions are OR-trees driven by a one-hot mask, not mux chains.
    always_comb begin
        grp_idx = '0;                                      // defaults (no latch)
        sub_sel = '0;
        for (int unsigned g = 0; g < NG; g++) begin
            grp_idx = grp_idx | (GRP_W'(g)      & {GRP_W{grp_onehot_s[g]}});
            sub_sel = sub_sel | (grp_sub_s[g]   & {SUB_W{grp_onehot_s[g]}});
        end
    end

    // GROUP_W is a power of two, so this is a concatenation, not a multiply-add.
    assign idx_low = {grp_idx, sub_sel};

    // Reflect back into the caller's index space. N is a power of two and
    // IDX_W = log2(N), so N-1-idx_low is exactly ~idx_low — a bitwise NOT.
    assign idx_c = rev_s ? ~idx_low : idx_low;

    // -------------------------------------------------------------------------
    // Optional output register (PIPELINE >= 2)
    // -------------------------------------------------------------------------
    generate
        if (PIPELINE >= 2) begin : g_out_reg
            always_ff @(posedge clk) begin
                if (rst) valid <= 1'b0;                    // control state
                else     valid <= valid_s;
            end
            always_ff @(posedge clk) begin
                idx <= idx_c;                              // datapath: no reset
            end
        end else begin : g_out_comb
            // Combinational outputs by exception (manual 00.03 §5). A registered
            // output would add a cycle to the book's new-best search, which is
            // the one variable-latency stage in the whole pipeline. Note that at
            // PIPELINE=1 `valid` is already registered — only `idx` is comb, and
            // it is 2-3 LUT levels deep, not a module-spanning path.
            assign valid = valid_s;
            assign idx   = idx_c;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    initial begin
        if (N < 16 || N > 4096) begin
            $error("prio_encoder: N must be in 16..4096 (got %0d).", N);
            $fatal(1);
        end
        if ((N & (N - 1)) != 0) begin
            $error("prio_encoder: N must be a power of two (got %0d) — the index concatenation and the ~idx reflect both depend on it.", N);
            $fatal(1);
        end
        if (GROUP_W < 2) begin
            $error("prio_encoder: GROUP_W must be >= 2 (got %0d).", GROUP_W);
            $fatal(1);
        end
        if ((GROUP_W & (GROUP_W - 1)) != 0) begin
            $error("prio_encoder: GROUP_W must be a power of two (got %0d).", GROUP_W);
            $fatal(1);
        end
        if (PIPELINE > 2) begin
            $error("prio_encoder: PIPELINE must be 0, 1 or 2 (got %0d).", PIPELINE);
            $fatal(1);
        end
        if (NG * GW != N) begin
            $error("prio_encoder: geometry broken — NG(%0d) x GW(%0d) != N(%0d).", NG, GW, N);
            $fatal(1);
        end
        if (GRP_W + SUB_W != IDX_W) begin
            $error("prio_encoder: geometry broken — GRP_W(%0d) + SUB_W(%0d) != IDX_W(%0d).", GRP_W, SUB_W, IDX_W);
            $fatal(1);
        end
        // Both levels the same width keeps the two halves balanced; a very
        // lopsided split pushes the whole problem into one level and defeats
        // the point of the hierarchy.
        if ((NG > (GW * 16)) || (GW > (NG * 16))) begin
            $warning("prio_encoder: lopsided split — %0d groups of %0d for N=%0d. Aim for GROUP_W ~ sqrt(N).", NG, GW, N);
        end
    end

    // ── Reference model: the golden answer, computed the slow obvious way. ────
    function automatic int unsigned ref_extreme(input logic [N-1:0] v,
                                                input logic         r);
        int unsigned found;
        int unsigned k;
        found = N;                                   // sentinel: nothing set
        for (int unsigned i = 0; i < N; i++) begin
            k = r ? ((N - 1) - i) : i;
            if (v[k] && (found == N)) found = k;
        end
        return found;
    endfunction

    int unsigned      ref_pos;
    logic             ref_v;
    logic [IDX_W-1:0] ref_i;
    always_comb begin
        ref_pos = ref_extreme(req, rev);
        ref_v   = (ref_pos != N);
        ref_i   = ref_v ? IDX_W'(ref_pos) : '0;
    end

    // The reference summary, so a lying `grp_sum_in` is caught here rather than
    // as a plausible-but-wrong best level fifty modules downstream.
    logic [NG-1:0] sum_ref;
    always_comb begin
        sum_ref = '0;
        for (int unsigned g = 0; g < NG; g++) begin
            sum_ref[g] = |req[g*GW +: GW];
        end
    end

    // $past needs PIPELINE cycles of history before it means anything.
    logic [3:0] sva_age_q;
    logic       sva_armed;
    always_ff @(posedge clk) begin
        if (rst)                    sva_age_q <= 4'd0;
        else if (sva_age_q != 4'd8) sva_age_q <= sva_age_q + 4'd1;
    end
    assign sva_armed = (sva_age_q > 4'(PIPELINE));

    generate
        if (PIPELINE == 0) begin : g_sva_comb
            // The combinational result must equal the reference, always. The
            // hierarchy is an optimization and must be observationally identical
            // to a flat encoder, in both directions.
            assert property (@(posedge clk) valid == ref_v)
                else $error("prio_encoder: valid=%0b but reference says %0b (req=%0h rev=%0b)",
                            valid, ref_v, req, rev);

            assert property (@(posedge clk) valid |-> (idx == ref_i))
                else $error("prio_encoder: idx %0d disagrees with reference %0d (rev=%0b)",
                            idx, ref_i, rev);

            // Structural cross-check: the selected index is a set request bit.
            assert property (@(posedge clk) disable iff (rst) valid |-> req[idx])
                else $error("prio_encoder: selected index %0d is not a set request bit", idx);
        end else begin : g_sva_piped
            // ⚠️ THIS IS THE EQUIVALENCE PROPERTY. `ref_v`/`ref_i` are what the
            //    PIPELINE=0 build would have produced for this input, so
            //    asserting the registered output against $past(ref, PIPELINE) is
            //    exactly "the pipelined variants agree with the combinational
            //    one for the same input" — and it also pins the latency to
            //    exactly PIPELINE cycles, no more and no less.
            assert property (@(posedge clk) disable iff (rst)
                sva_armed |-> (valid == $past(ref_v, PIPELINE)))
                else $error("prio_encoder: valid=%0b disagrees with the combinational result from %0d cycle(s) ago",
                            valid, PIPELINE);

            assert property (@(posedge clk) disable iff (rst)
                (sva_armed && valid) |-> (idx == $past(ref_i, PIPELINE)))
                else $error("prio_encoder: idx %0d disagrees with the combinational result from %0d cycle(s) ago",
                            idx, PIPELINE);
        end
    endgenerate

    // `valid` is low if and only if `req` is all zeros — the property every
    // consumer relies on to tell "index 0" apart from "nothing".
    generate
        if (PIPELINE == 0) begin : g_sva_valid_comb
            assert property (@(posedge clk) valid == (|req))
                else $error("prio_encoder: valid=%0b but |req=%0b", valid, |req);
        end else begin : g_sva_valid_piped
            assert property (@(posedge clk) disable iff (rst)
                sva_armed |-> (valid == $past(|req, PIPELINE)))
                else $error("prio_encoder: valid=%0b contradicts whether req was all zeros %0d cycle(s) ago",
                            valid, PIPELINE);
        end
    endgenerate

    // The isolate trick must produce at most one bit. If this ever fails the
    // OR-mux below it is summing two sub-indices and the answer is garbage.
    assert property (@(posedge clk) $onehot0(grp_onehot_c))
        else $error("prio_encoder: group one-hot has more than one bit set");
    assert property (@(posedge clk) $onehot0(grp_onehot_s))
        else $error("prio_encoder: registered group one-hot has more than one bit set");

    // A supplied summary that disagrees with `req` is silent book corruption.
    assert property (@(posedge clk) disable iff (rst)
        (SUMMARY_IN != 0) |-> (grp_sum_in == sum_ref))
        else $error("prio_encoder: grp_sum_in %0h disagrees with the summary derived from req %0h — it must be NATURAL order, one bit per group of GROUP_W",
                    grp_sum_in, sum_ref);
`endif

endmodule : prio_encoder

`default_nettype wire
