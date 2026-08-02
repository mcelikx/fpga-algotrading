// =============================================================================
// strategy_pkg.sv — Strategy-layer types: primitive select, decision, gate reasons
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Layer   : rtl/strategy/  (budget rows S0..S1, 2 cycles, 12.8 ns @ 6.4 ns/cyc)
// Governs : manuals/04-system-architecture/04-strategy-engine-on-fpga.md
//           manuals/03-algotrading/05-strategy-taxonomy.md
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// -----------------------------------------------------------------------------
// CORE ARCHITECTURAL PRINCIPLE
//   The FPGA is a TRIGGER EVALUATOR OVER A PARAMETER TABLE, not a general
//   compute engine. The host computes slow signals (fair value, imbalance
//   thresholds, sizing, edges) at millisecond cadence and writes them into the
//   parameter table. The FPGA evaluates a FIXED comparator/threshold expression
//   over those parameters at nanosecond cadence. Anything that needs real
//   computation — a model, a fit, an optimisation, a divide — belongs on the
//   host. This package defines the vocabulary of that fixed expression.
//
// -----------------------------------------------------------------------------
// ARITHMETIC RULES (CLAUDE.md §5)
//   * NO division, NO modulo, NO floating point. Anywhere. Ever.
//   * Prices are ITCH-native scaled integers, 4 implied decimals
//     ($12.3400 -> 32'd123400). PRICE_SCALE = 10000 (trading_pkg).
//   * Ratios are evaluated by CROSS-MULTIPLICATION against a host-written
//     fixed-point threshold. See IMB_SCALE below.
//   * Every price/position/counter arithmetic op SATURATES. A wrapped value
//     turns a limit check into a no-op.
//
// -----------------------------------------------------------------------------
// LATENCY  : none (package — types and combinational helper functions only)
// RESOURCE : none directly. The helper functions cost what their caller pays;
//            each is a 32/40-bit adder plus a 2:1 saturation mux (~2 LUT levels).
// =============================================================================
`ifndef STRATEGY_PKG_SV
`define STRATEGY_PKG_SV

package strategy_pkg;

    // trading_pkg is THE interface contract. It is imported, not duplicated.
    // Note: SystemVerilog `import` does not re-export. A module that uses both
    // packages must import BOTH:  import trading_pkg::*; import strategy_pkg::*;
    import trading_pkg::*;

    // -------------------------------------------------------------------------
    // 1. Strategy primitive select
    // -------------------------------------------------------------------------
    // Selected per symbol by sym_strat_t.strat_select (4 bits). This set is
    // DELIBERATELY SMALL. A fixed menu of hardened primitives selected by a
    // parameter means a new trading idea is usually a parameter change (host,
    // microseconds) rather than a bitstream rebuild (hours, plus a P&R timing
    // risk and a redeploy window). Adding a primitive is a fabric change and
    // must be justified against the S1 logic-depth budget in trigger_logic.sv.
    //
    // RESET / UNWRITTEN VALUE IS 4'd0 = STRAT_NONE = disabled. Fail-closed.
    typedef enum logic [3:0] {
        STRAT_NONE            = 4'd0,  // always ACT_NONE
        STRAT_PASSIVE_QUOTE   = 4'd1,  // post-only quote inside the touch
        STRAT_FAIR_VALUE_TAKE = 4'd2,  // take against a host-written fair value
        STRAT_IMBALANCE       = 4'd3   // act on top-of-book size imbalance
    } strat_sel_e;

    // Referenced by testbenches and by the host's parameter generator, not by
    // synthesizable RTL — hence the waiver. (trading_pkg.sv has a dozen
    // parameters in the same category; the project lint invocation should carry
    // -Wno-UNUSEDPARAM for package files rather than sprinkling waivers.)
    /* verilator lint_off UNUSEDPARAM */
    parameter int unsigned N_STRATS = 4;
    /* verilator lint_on UNUSEDPARAM */

    // Any strat_select value outside this set is ILLEGAL and rejects (the gate
    // raises GATE_UNKNOWN). This is the "unknown state fails closed" rule.
    function automatic logic strat_sel_legal(input logic [3:0] s);
        return (s == STRAT_NONE)          ||
               (s == STRAT_PASSIVE_QUOTE) ||
               (s == STRAT_FAIR_VALUE_TAKE) ||
               (s == STRAT_IMBALANCE);
    endfunction

    // -------------------------------------------------------------------------
    // 2. Gate rejection reasons
    // -------------------------------------------------------------------------
    // EVERY reason gets its own counter. A gate whose rejections are not
    // attributable cannot be debugged in production: "we stopped quoting at
    // 09:47" is not an incident report, "12,431 rejects on GATE_THIN_BOOK
    // starting at 09:47" is.
    //
    // Index 0 (GATE_OK) is the PASS counter, so reject_cnt[] is a complete
    // histogram of every gate evaluation, not just the failures.
    typedef enum logic [3:0] {
        GATE_OK              = 4'd0,   // passed — counted as the pass count
        GATE_IN_RESET        = 4'd1,   // rst asserted: reject unconditionally
        GATE_SESS_NOT_OPEN   = 4'd2,   // global sess_state != TRADE_OPEN
        GATE_SYM_NOT_OPEN    = 4'd3,   // per-symbol state != TRADE_OPEN
        GATE_PARAMS_INVALID  = 4'd4,   // params_valid == 0 (never fully loaded)
        GATE_STRAT_DISABLED  = 4'd5,   // params.strat_enabled == 0
        GATE_BOOK_STALE      = 4'd6,   // s_top.stale: sequence gap seen
        GATE_BOOK_CROSSED    = 4'd7,   // s_top.crossed: bid >= ask
        GATE_SIDE_INVALID    = 4'd8,   // a side missing, or a zero price
        GATE_THIN_BOOK       = 4'd9,   // qty < params.min_book_qty
        GATE_UNKNOWN         = 4'd10   // unrecognised state. MUST stay at zero.
    } gate_reason_e;

    parameter int unsigned N_GATE_REASONS = 11;

    // -------------------------------------------------------------------------
    // 3. Internal decision struct (trigger_logic -> strategy_engine)
    // -------------------------------------------------------------------------
    // This is NOT an order. It is the combinational verdict of one primitive,
    // produced in stage S1 and registered by strategy_engine into order_req_t.
    // `fired` is redundant with (action != ACT_NONE) and exists so the emit
    // path can be asserted structurally.
    typedef struct packed {
        action_e     action;       // ACT_NONE | ACT_SEND  (ACT_CANCEL unused, §7)
        side_e       side;
        price_t      price;
        qty_t        qty;
        logic        post_only;    // add-liquidity-only; never cross the spread
        logic        is_short;     // Reg SHO: sale not covered by a long position
        logic [3:0]  strat_id;     // which primitive produced this
        logic        fired;
    } strat_decision_t;

    // -------------------------------------------------------------------------
    // 4. Parameter-table record layout (host <-> param_table)
    // -------------------------------------------------------------------------
    // ONE FIELD PER 32-BIT WORD. No field straddles a word boundary. This is a
    // deliberate choice with three consequences that all matter:
    //   1. The host can compute a word address without a bit-packing table.
    //   2. Each word carries its OWN validity check (see param_table.sv §4), so
    //      a bad value invalidates the record at write time, not at trade time.
    //   3. The memory is 6 independent 32-bit-wide RAMs with full-word writes,
    //      which infers cleanly as simple-dual-port BRAM. A packed 149-bit
    //      record would need partial writes and would not.
    //
    //   word  field                 notes
    //   ----  --------------------  ----------------------------------------
    //     0   ctrl                  [0]=strat_enabled, [4:1]=strat_select
    //     1   quote_qty             shares; 0 is invalid
    //     2   edge_ticks            ITCH price units, PRE-SCALED BY THE HOST
    //     3   min_book_qty          shares; 0 is legal (means "no minimum")
    //     4   fair_value            ITCH price units; 0 is invalid
    //     5   imbalance_thr         [15:0], fixed-point /IMB_SCALE; >= IMB_SCALE
    typedef enum logic [2:0] {
        PW_CTRL      = 3'd0,
        PW_QUOTE_QTY = 3'd1,
        PW_EDGE      = 3'd2,
        PW_MIN_QTY   = 3'd3,
        PW_FAIR_VAL  = 3'd4,
        PW_IMB_THR   = 3'd5
    } param_word_e;

    parameter int unsigned N_PARAM_WORDS = 6;
    parameter int unsigned PARAM_WORD_W  = 3;   // $clog2(8), 6 words used

    // ── Host config window address map (cfg_param_addr[15:0]) ────────────────
    // Decoded in strategy_engine.sv. Regions are 3 bits so the map has room to
    // grow without disturbing the parameter region the host writes hottest.
    //
    //   addr[15:13]  region
    //   -----------  ----------------------------------------------------------
    //   3'b000       PARAM     : addr[10:3]=sym, addr[2:0]=word (0..5)
    //   3'b001       SYMSTATE  : addr[7:0]=sym,  data[2:0]=trade_state_e
    //   3'b010       POSFORCE  : addr[7:0]=sym,  addr[8]=word
    //                              word0 data[31:0]  = position[31:0]  (held)
    //                              word1 data[7:0]   = position[39:32]
    //                                    data[31:16] = open_orders[15:0]
    //                                    (writing word1 APPLIES the correction)
    //   others       reserved  : ignored, counted in the bad-address counter
    parameter logic [2:0] CFG_REGION_PARAM    = 3'b000;
    parameter logic [2:0] CFG_REGION_SYMSTATE = 3'b001;
    parameter logic [2:0] CFG_REGION_POSFORCE = 3'b010;

    // -------------------------------------------------------------------------
    // 5. Fixed-point scaling constants
    // -------------------------------------------------------------------------
    // ── Imbalance ────────────────────────────────────────────────────────────
    // The concept is a RATIO:   bid_qty / ask_qty  >  imbalance_thr / IMB_SCALE
    // There is no divider in the fabric, so it is evaluated by cross-multiply:
    //
    //     bid_qty * IMB_SCALE   >   ask_qty * imbalance_thr        (bid-heavy)
    //     ask_qty * IMB_SCALE   >   bid_qty * imbalance_thr        (ask-heavy)
    //
    // IMB_SCALE is a POWER OF TWO on purpose: the left-hand multiply degenerates
    // to a constant left shift (free — pure routing), so only ONE real multiply
    // per side survives into the S1 critical path. See trigger_logic.sv §5.
    //
    // imbalance_thr is therefore in units of 1/256:
    //     16'd256  = ratio 1.00   (any imbalance at all)
    //     16'd384  = ratio 1.50
    //     16'd512  = ratio 2.00
    //     16'd65535 = ratio 255.99  (practical maximum)
    //
    // A threshold BELOW IMB_SCALE would make the bid-heavy and ask-heavy tests
    // simultaneously true. param_table.sv rejects imbalance_thr < IMB_SCALE at
    // write time, which makes the two tests provably mutually exclusive.
    parameter int unsigned IMB_SCALE_SHIFT = 8;
    parameter logic [15:0] IMB_SCALE       = 16'd256;   // 1 << IMB_SCALE_SHIFT

    // OVERFLOW GUARD. Quantities are QTY_W=32 bits, but a 32x16 multiply is a
    // 48-bit product and two DSP48E2 slices cascaded — too deep for one cycle at
    // 156.25 MHz. The operands are therefore restricted to IMB_QTY_W bits:
    //
    //   * 24 bits = 16,777,215 shares at a single top-of-book level. Real
    //     Nasdaq top-of-book sizes are 3-5 orders of magnitude smaller.
    //   * 24 x 16 -> 40-bit product: ONE DSP48E2 (27x18), no cascade.
    //   * bid_qty << 8 -> 32 bits, widened to 40. Cannot overflow.
    //
    // If EITHER side exceeds IMB_QTY_MAX the imbalance primitive does not fire.
    // This is not cosmetic: if only one operand saturated, the inequality could
    // flip DIRECTION (a saturated ask_qty shrinks the right-hand side and would
    // manufacture a spurious buy signal). Refusing to fire when either operand
    // is out of range removes the ambiguity entirely. Fail-closed.
    parameter int unsigned IMB_QTY_W    = 24;
    parameter int unsigned IMB_PROD_W   = IMB_QTY_W + 16;         // 40
    parameter qty_t        IMB_QTY_MAX  = qty_t'((1 << IMB_QTY_W) - 1);

    // ── Ticks ────────────────────────────────────────────────────────────────
    // sym_strat_t.edge_ticks is typed price_t and documented "threshold, in
    // ticks". The FPGA NEVER multiplies by a tick size — that would be a
    // per-symbol variable multiply on the critical path, and sub-dollar names
    // have a different tick than >= $1.00 names.
    //
    // CONTRACT: the host writes edge_ticks ALREADY SCALED INTO ITCH PRICE UNITS.
    //     stock >= $1.00 : tick = $0.01 = 100 ITCH units -> host writes N * 100
    //     stock <  $1.00 : tick = $0.0001 = 1 ITCH unit  -> host writes N * 1
    // This is the parameter-table doctrine applied to the tick size: the slow
    // path knows the tick regime per symbol, the fast path only ever adds.
    /* verilator lint_off UNUSEDPARAM */
    parameter int unsigned TICK_SCALE_PENNY = 100;   // host-side constant only
    /* verilator lint_on UNUSEDPARAM */

    // ── Hardware ceilings (independent of anything the host writes) ──────────
    // A defence against a fat-fingered or corrupted parameter write. The risk
    // gate enforces the real per-symbol limits; this is the strategy layer
    // refusing to even ASK for something absurd.
    parameter qty_t             HARD_MAX_QUOTE_QTY = qty_t'(32'd100_000);
    parameter int unsigned      OPEN_CNT_W         = 16;
    typedef logic [OPEN_CNT_W-1:0] open_cnt_t;

    // -------------------------------------------------------------------------
    // 6. Saturating arithmetic helpers
    // -------------------------------------------------------------------------
    // NOTE: these belong in rtl/pkg/sat_arith_pkg.sv, which does not exist in
    // the tree yet. trading_pkg.sv provides sat_add64 / sat_sub64 (unsigned,
    // 64-bit) only, and position arithmetic is SIGNED and 40-bit. When
    // sat_arith_pkg.sv lands, MOVE these there verbatim and delete them here —
    // do not leave two copies. Tracked in rtl/strategy/README.md §8.

    parameter position_t POS_MAX = position_t'({1'b0, {(POS_W-1){1'b1}}});
    parameter position_t POS_MIN = position_t'({1'b1, {(POS_W-1){1'b0}}});

    // Saturating SIGNED add on position_t. Long positive, short negative.
    function automatic position_t sat_add_pos(input position_t a,
                                              input position_t b);
        logic signed [POS_W:0] sum;
        sum = {a[POS_W-1], a} + {b[POS_W-1], b};
        if      (sum > {1'b0, POS_MAX}) return POS_MAX;
        else if (sum < {1'b1, POS_MIN}) return POS_MIN;
        else                            return position_t'(sum[POS_W-1:0]);
    endfunction

    // Zero-extend an unsigned qty into the signed position domain. QTY_W=32,
    // POS_W=40, so the result is always non-negative — no sign-extension trap.
    function automatic position_t qty_to_pos(input qty_t q);
        return position_t'({{(POS_W-QTY_W){1'b0}}, q});
    endfunction

    // Saturating UNSIGNED add/sub on price_t. A price that wraps through zero
    // is a limit order at $0.0000 or $429,496.7295 — either would be a
    // catastrophic quote, so both directions clamp instead.
    function automatic price_t sat_add_px(input price_t a, input price_t b);
        logic [PRICE_W:0] sum;
        sum = {1'b0, a} + {1'b0, b};
        return sum[PRICE_W] ? {PRICE_W{1'b1}} : sum[PRICE_W-1:0];
    endfunction

    function automatic price_t sat_sub_px(input price_t a, input price_t b);
        return (a > b) ? (a - b) : price_t'(32'd0);
    endfunction

    // Saturating open-order counter. Increments on emit, decrements on fill.
    // It floors at zero rather than wrapping to 65535: an underflow that wrapped
    // would look like 65,535 working orders and would jam the gate permanently.
    function automatic open_cnt_t sat_inc_open(input open_cnt_t c);
        return (c == {OPEN_CNT_W{1'b1}}) ? c : open_cnt_t'(c + 1'b1);
    endfunction

    function automatic open_cnt_t sat_dec_open(input open_cnt_t c);
        return (c == {OPEN_CNT_W{1'b0}}) ? c : open_cnt_t'(c - 1'b1);
    endfunction

    // Saturating 32-bit telemetry counter. Saturation rather than wrap so that
    // a host polling at 1 Hz can never mistake a wrap for "the problem stopped".
    function automatic logic [31:0] cnt_inc(input logic [31:0] c);
        return (c == 32'hFFFF_FFFF) ? c : (c + 32'd1);
    endfunction

    // Minimum of two quantities. Used to clip a take to the displayed size.
    function automatic qty_t qty_min(input qty_t a, input qty_t b);
        return (a < b) ? a : b;
    endfunction

endpackage : strategy_pkg

`endif
