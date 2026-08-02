// =============================================================================
// trigger_logic.sv — The hardened strategy primitives
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Layer   : rtl/strategy/  (budget row S1 — comparator bank -> decision)
// Governs : manuals/04-system-architecture/04-strategy-engine-on-fpga.md
//           manuals/03-algotrading/05-strategy-taxonomy.md
//           manuals/08-nasdaq/06-regnms-and-compliance.md   (Reg SHO, is_short)
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// -----------------------------------------------------------------------------
// CORE ARCHITECTURAL PRINCIPLE — THIS MODULE IS WHERE IT BITES
//
//   The FPGA is a TRIGGER EVALUATOR OVER A PARAMETER TABLE, not a general
//   compute engine. Every primitive below is a SHALLOW COMBINATIONAL EXPRESSION
//   over registered inputs: a handful of compares, one add, one multiply, a
//   mux. There is no accumulator, no filter, no state, no loop, no divide.
//
//   Everything that looks like intelligence — what fair value IS, what
//   imbalance threshold is right for this name at this time of day, how wide
//   the edge should be — is a NUMBER IN THE PARAMETER TABLE, computed by the
//   host at millisecond cadence. The fabric only ever asks "is the comparison
//   true right now?"
//
//   The primitive SET is deliberately small and fixed. That is the point: a new
//   trading idea is normally a new set of parameters (host-side, microseconds,
//   reversible) rather than a new bitstream (hours of P&R, a timing risk, and a
//   deploy window). Adding a fifth primitive is a fabric change and must be
//   argued against the S1 logic-depth budget in §7 below.
//
// -----------------------------------------------------------------------------
// LATENCY
//   0 cycles. PURELY COMBINATIONAL — a documented exception to the
//   registered-outputs rule (03-hdl-and-rtl-coding.md §5). Justification: this
//   module IS budget row S1's combinational cloud. Its inputs are the
//   registered outputs of param_table / position_track / the stage-0 book
//   register, and its output is registered immediately by strategy_engine.sv.
//   The path is therefore FF -> this module -> FF and is locally analysable.
//
//   `clk` and `rst` are consumed ONLY by the assertions in §8. The datapath
//   contains no sequential element.
//
// RESOURCE (estimate, UltraScale+)
//   DSP  : 2   (one 24x16 multiply per imbalance direction, one DSP48E2 each)
//   LUT  : ~700   price adders/saturation ~180, compares ~260, clip/mux ~180,
//                 short-sale logic ~40, decision mux ~40
//   FF   : 0
//   BRAM : 0
// =============================================================================
`default_nettype none

module trigger_logic
    import trading_pkg::*;
    import strategy_pkg::*;
#(
    // ⚠️ Reg SHO conservatism. See §6. When 1 (the default), a sell is marked
    // short whenever ANY order is working in the symbol, because our position
    // estimate is uncertain by at least one clip while an order is live.
    // Setting this to 0 marks short strictly on the position arithmetic and is
    // a COMPLIANCE-RELEVANT change — do not flip it without desk sign-off.
    parameter bit CONSERVATIVE_SHORT = 1'b1
) (
    // Assertion clock only — the datapath below is combinational.
    input  var logic            clk,
    input  var logic            rst,

    // ── Registered inputs (stage S1) ─────────────────────────────────────────
    // The primitives read only top-of-book prices and sizes; sym, last_px,
    // top_changed, the valid bits and rx_cycle are the gate's or the engine's
    // business. Whole structs are passed so the port list survives either one
    // growing a field.
    /* verilator lint_off UNUSEDSIGNAL */
    input  var book_top_t       s_top,        // top of book after this update
    input  var sym_strat_t      params,       // ACTIVE bank, complete record
    /* verilator lint_on UNUSEDSIGNAL */
    input  var position_t       position,     // our signed position, this symbol
    input  var open_cnt_t       open_orders,  // orders we believe are working
    input  var logic            gate_pass,    // trade_gate verdict, same cycle

    // ── Combinational verdict ────────────────────────────────────────────────
    output var strat_decision_t decision
);

    // =========================================================================
    // 1. Shared price arithmetic (computed once, used by several primitives)
    // =========================================================================
    // All saturating. An edge that pushes a price past 0 or past $429,496.7295
    // clamps rather than wrapping; a wrapped price is an order at the far end of
    // the book, which is the single worst thing this module could emit.
    //
    // edge_ticks arrives PRE-SCALED to ITCH price units (host multiplies by the
    // tick size — strategy_pkg.sv §5). The fabric never multiplies by a tick.
    price_t px_join_bid;     // bid + edge  : improve the bid
    price_t px_join_ask;     // ask - edge  : improve the offer
    price_t fv_buy_thresh;   // fair_value - edge
    price_t fv_sell_thresh;  // fair_value + edge

    assign px_join_bid    = sat_add_px(s_top.bid_px,     params.edge_ticks);
    assign px_join_ask    = sat_sub_px(s_top.ask_px,     params.edge_ticks);
    assign fv_buy_thresh  = sat_sub_px(params.fair_value, params.edge_ticks);
    assign fv_sell_thresh = sat_add_px(params.fair_value, params.edge_ticks);

    // =========================================================================
    // 2. Size clipping
    // =========================================================================
    // A take is clipped to the displayed size on the far side. Asking for more
    // than is shown leaks intent, and the residue rests in the book at a price
    // the trigger never evaluated. A quote is not clipped — it is adding
    // liquidity, not consuming it.
    qty_t take_buy_qty;
    qty_t take_sell_qty;

    assign take_buy_qty  = qty_min(params.quote_qty, s_top.ask_qty);
    assign take_sell_qty = qty_min(params.quote_qty, s_top.bid_qty);

    // =========================================================================
    // 3. STRAT_PASSIVE_QUOTE
    // =========================================================================
    // Post-only quote inside the touch: buy at (best_bid + edge), sell at
    // (best_ask - edge), sized quote_qty. post_only is set, so the venue will
    // reject or reprice rather than let us cross — but we also refuse to EMIT a
    // crossing quote, because a post-only reject still costs a round trip and
    // still counts against the order-to-trade ratio.
    //
    // ⚠️ SIDE SELECTION. order_req_t carries ONE order, and one book event
    // produces one request. A real two-sided quoter needs two emits per event
    // (or a wider request struct). Rather than pretend, this primitive picks
    // the side that reduces inventory:
    //     position > 0  -> offer   (sell, work the long back toward flat)
    //     position <= 0 -> bid     (buy)
    // The other side is quoted on the next book event in the symbol. This is a
    // deliberate, documented scope limit — see README.md §7.
    logic   pq_is_sell;
    price_t pq_px;
    logic   pq_would_cross;
    logic   pq_fire;

    assign pq_is_sell     = (position > position_t'(0));
    assign pq_px          = pq_is_sell ? px_join_ask : px_join_bid;

    // Post-only integrity: a bid at or above the offer, or an offer at or below
    // the bid, would cross. Suppress and let strategy_engine count it.
    assign pq_would_cross = pq_is_sell ? (px_join_ask <= s_top.bid_px)
                                       : (px_join_bid >= s_top.ask_px);

    assign pq_fire        = !pq_would_cross && (params.quote_qty != 32'd0);

    // =========================================================================
    // 4. STRAT_FAIR_VALUE_TAKE
    // =========================================================================
    // fair_value is HOST-WRITTEN at millisecond cadence. That is the whole
    // partitioning argument in one field: computing a fair value is a model
    // (a basket, a lead-lag regression, an ETF NAV) and models belong on the
    // CPU. Comparing a fair value to a live quote is one 32-bit subtract and
    // one 32-bit compare, and that belongs in fabric.
    //
    //   best_ask < fair_value - edge   -> the offer is cheap  -> BUY  the offer
    //   best_bid > fair_value + edge   -> the bid  is rich    -> SELL the bid
    //
    // Both are takes: price = the resting quote we are lifting/hitting, so the
    // order is marketable. post_only is 0.
    //
    // fair_value == 0 cannot reach here: param_table rejects a zero fair_value
    // at write time (an uninitialised fair value would make fv_sell_thresh
    // equal to `edge`, i.e. a live sell trigger against essentially every bid
    // in the book — the classic uninitialised-parameter blowup).
    logic fv_buy;
    logic fv_sell;

    assign fv_buy  = (s_top.ask_px < fv_buy_thresh);
    assign fv_sell = (s_top.bid_px > fv_sell_thresh);

    // =========================================================================
    // 5. STRAT_IMBALANCE  — the ratio, without a divide
    // =========================================================================
    // The idea is a RATIO of top-of-book sizes:
    //
    //     bid_qty / ask_qty  >  imbalance_thr / IMB_SCALE     -> bid-heavy, BUY
    //     ask_qty / bid_qty  >  imbalance_thr / IMB_SCALE     -> ask-heavy, SELL
    //
    // There is no divider in the fabric (CLAUDE.md §5) and there will not be
    // one: a 32-bit restoring divider is ~32 cycles or an enormous
    // combinational tree, and either destroys the 2-cycle budget. Both sides
    // are therefore CROSS-MULTIPLIED, which is exact — no reciprocal, no
    // rounding, no lost precision:
    //
    //     bid_qty * IMB_SCALE      >  ask_qty * imbalance_thr
    //     ask_qty * IMB_SCALE      >  bid_qty * imbalance_thr
    //
    // FIXED-POINT SCALING
    //   imbalance_thr is a UQ8.8-style fixed-point ratio in units of 1/256:
    //       16'd256 -> 1.00,  16'd384 -> 1.50,  16'd512 -> 2.00
    //   IMB_SCALE = 256 = 2^IMB_SCALE_SHIFT is a POWER OF TWO on purpose, so
    //   the left-hand multiply degenerates to a constant left shift — free,
    //   pure routing, zero LUTs, zero delay. Only ONE real multiply per
    //   direction survives, and it is 24x16, which is a single DSP48E2 (27x18)
    //   with no cascade.
    //
    // OVERFLOW GUARD
    //   Operands are clamped to IMB_QTY_W = 24 bits (16,777,215 shares at one
    //   top-of-book level — three to five orders of magnitude above anything
    //   Nasdaq shows). Products are then 24+16 = 40 bits and CANNOT overflow
    //   the 40-bit accumulator; the shifted side is 24+8 = 32 bits, also safe.
    //
    //   ⚠️ If either side exceeds the clamp the primitive DOES NOT FIRE. This
    //   is not laziness. If only ONE operand saturated, the inequality could
    //   flip DIRECTION: a saturated ask_qty shrinks the right-hand side of the
    //   bid-heavy test and would MANUFACTURE a buy signal out of an arithmetic
    //   artefact. Refusing to evaluate when either operand is out of range
    //   removes the ambiguity completely. Fail-closed beats clever.
    //
    // MUTUAL EXCLUSION
    //   param_table rejects imbalance_thr < IMB_SCALE at write time, so the
    //   threshold ratio is always >= 1.0 and imb_buy / imb_sell are provably
    //   mutually exclusive. Asserted in §8.
    logic                   imb_operands_ok;
    logic [IMB_QTY_W-1:0]   bid_q24;
    logic [IMB_QTY_W-1:0]   ask_q24;
    logic [IMB_PROD_W-1:0]  bid_scaled;   // bid_qty << IMB_SCALE_SHIFT
    logic [IMB_PROD_W-1:0]  ask_scaled;   // ask_qty << IMB_SCALE_SHIFT
    logic [IMB_PROD_W-1:0]  bid_x_thr;    // bid_qty * imbalance_thr
    logic [IMB_PROD_W-1:0]  ask_x_thr;    // ask_qty * imbalance_thr
    logic                   imb_buy;
    logic                   imb_sell;

    assign imb_operands_ok = (s_top.bid_qty <= IMB_QTY_MAX) &&
                             (s_top.ask_qty <= IMB_QTY_MAX);

    assign bid_q24    = s_top.bid_qty[IMB_QTY_W-1:0];
    assign ask_q24    = s_top.ask_qty[IMB_QTY_W-1:0];

    // Constant shift — no multiplier, no DSP, no delay.
    assign bid_scaled = IMB_PROD_W'(bid_q24) << IMB_SCALE_SHIFT;
    assign ask_scaled = IMB_PROD_W'(ask_q24) << IMB_SCALE_SHIFT;

    // The only real multiplies in the strategy layer. One DSP48E2 each.
    assign bid_x_thr  = IMB_PROD_W'(bid_q24) * IMB_PROD_W'(params.imbalance_thr);
    assign ask_x_thr  = IMB_PROD_W'(ask_q24) * IMB_PROD_W'(params.imbalance_thr);

    assign imb_buy    = imb_operands_ok && (bid_scaled > ask_x_thr);
    assign imb_sell   = imb_operands_ok && (ask_scaled > bid_x_thr);

    // =========================================================================
    // 6. Short-sale determination — ⚠️ Reg SHO, not just a flag
    // =========================================================================
    // is_short drives the SSR (Rule 201) price test in risk_gate.sv. Marking a
    // short sale as long is a REGULATORY breach, not a missed trade. Marking a
    // long sale as short costs us a fill when SSR is active for the name. The
    // asymmetry is total, so this errs hard toward "short".
    //
    // Two conditions, ORed:
    //
    //  (a) POSITION ARITHMETIC. A sale is short to the extent it exceeds the
    //      long position. So the test is (position < qty), NOT (position <= 0):
    //      selling 200 while long 100 is a 100-share short sale even though the
    //      position is positive. This is strictly stronger than "sell when
    //      position <= 0 is short", and subsumes it, since qty > 0 always.
    //
    //  (b) OPEN-ORDER UNCERTAINTY (CONSERVATIVE_SHORT, default on). While any
    //      order is working in the symbol our position estimate is uncertain by
    //      at least one clip — a sell could fill a microsecond before this one
    //      reaches the venue. position_track cannot see cancels or acks through
    //      the fill-only feedback interface (see position_track.sv §3), so the
    //      open-order count is an UPPER bound, which makes this term
    //      conservative in the correct direction.
    //
    // Residual gap, stated plainly: a fill that has occurred at the venue but
    // whose message has not yet reached us is invisible to both terms. Nothing
    // in fabric can close that — it is a speed-of-light problem. It is bounded
    // by the in-flight credit limit (MAX_IN_FLIGHT) and backstopped by
    // risk_gate.sv, which owns the authoritative SSR check and the
    // authoritative position.
    logic sell_uncovered;    // set inside the decision mux, per candidate size
    logic sell_uncertain;
    logic unc_quote_qty;     // a quote-sized sell would exceed the long position
    logic unc_take_sell;     // a bid-clipped sell would exceed the long position

    // Both candidate sell sizes are evaluated in parallel; the decision mux
    // selects the one that matches the primitive that fired. Two 40-bit signed
    // compares, off the critical path (they run alongside the DSP).
    assign unc_quote_qty  = (position < qty_to_pos(params.quote_qty));
    assign unc_take_sell  = (position < qty_to_pos(take_sell_qty));

    assign sell_uncertain = CONSERVATIVE_SHORT && (open_orders != {OPEN_CNT_W{1'b0}});

    // =========================================================================
    // 7. Primitive select and decision mux
    // =========================================================================
    // ⚠️ LOGIC DEPTH — READ BEFORE ADDING A PRIMITIVE
    //
    //   This whole module is one combinational cloud inside budget row S1
    //   (6.4 ns at 156.25 MHz). The critical path is the imbalance branch:
    //
    //       param_table FF -> DSP48E2 (24x16, MREG bypassed, ~2.5-3.0 ns)
    //         -> 40-bit magnitude compare (~1.5 ns)
    //         -> AND with gate_pass and imb_operands_ok (~0.6 ns)
    //         -> 4:1 decision mux (~0.6 ns)
    //         -> strategy_engine output FF setup
    //       ~5.3-5.8 ns of 6.4 ns. It fits, with little margin.
    //
    //   IF TIMING FAILS, in preference order:
    //
    //   1. FREE — constrain imbalance_thr to a power of two. The host writes
    //      log2 and both multiplies become constant shifts, removing the DSP
    //      from the path entirely (~3 ns recovered). This is a PARAMETER-TABLE
    //      change and a param_table field check; no fabric change, no rebuild
    //      of anything else, no latency change.
    //
    //   2. ONE CYCLE — enable the DSP48E2 MREG, i.e. register bid_x_thr /
    //      ask_x_thr and split this module into S1a (products) and S1b
    //      (compares + mux). The insertion point is exactly at the two
    //      `assign bid_x_thr / ask_x_thr` statements above; nothing else moves.
    //      COST: the strategy layer becomes 3 cycles and breaks the 20-cycle
    //      fabric envelope. Per the budget rules, to add a cycle you must
    //      remove one — so this option is only available alongside a cycle
    //      recovered in the book or gateway. Do not take it silently.
    //
    //   3. LAST RESORT — narrow IMB_QTY_W from 24 to 18 bits, which shrinks the
    //      DSP and the compare. Raises the rate at which imb_operands_ok goes
    //      false (i.e. the primitive silently stops firing on deep books), so
    //      it must be paired with a counter on that condition.
    //
    //   Adding a FIFTH primitive widens the decision mux from 4:1 to 8:1
    //   (+1 LUT level, ~0.6 ns) and adds its own arithmetic in parallel. There
    //   is roughly one LUT level of headroom. Budget it before writing it.
    logic [3:0] sel;
    assign sel = params.strat_select;

    always_comb begin
        // ── Defaults: do nothing. Every path below either overwrites these or
        //    leaves them, and an unrecognised select leaves them. No latches.
        decision           = '0;
        decision.action    = ACT_NONE;
        decision.side      = SIDE_BUY;
        decision.price     = 32'd0;
        decision.qty       = 32'd0;
        decision.post_only = 1'b0;
        decision.is_short  = 1'b0;
        decision.strat_id  = sel;
        decision.fired     = 1'b0;
        sell_uncovered     = 1'b0;

        // Plain `case`, not `unique case`: an illegal strat_select is an
        // EXPECTED runtime condition (a corrupted or partial host write), and
        // it is handled fail-closed here. `unique` would additionally raise a
        // simulation error on a condition the design deliberately survives.
        case (sel)

            // ── Disabled. Never fires, no matter what the book does. ────────
            STRAT_NONE: begin
                decision.action = ACT_NONE;
            end

            // ── Post-only quote inside the touch ─────────────────────────────
            STRAT_PASSIVE_QUOTE: begin
                if (pq_fire) begin
                    decision.action    = ACT_SEND;
                    decision.side      = pq_is_sell ? SIDE_SELL : SIDE_BUY;
                    decision.price     = pq_px;
                    decision.qty       = params.quote_qty;
                    decision.post_only = 1'b1;          // add liquidity only
                    decision.fired     = 1'b1;
                    sell_uncovered     = unc_quote_qty;
                end
            end

            // ── Take against a host-written fair value ───────────────────────
            STRAT_FAIR_VALUE_TAKE: begin
                if (fv_buy) begin
                    decision.action    = ACT_SEND;
                    decision.side      = SIDE_BUY;
                    decision.price     = s_top.ask_px;  // lift the offer
                    decision.qty       = take_buy_qty;
                    decision.post_only = 1'b0;
                    decision.fired     = 1'b1;
                end else if (fv_sell) begin
                    decision.action    = ACT_SEND;
                    decision.side      = SIDE_SELL;
                    decision.price     = s_top.bid_px;  // hit the bid
                    decision.qty       = take_sell_qty;
                    decision.post_only = 1'b0;
                    decision.fired     = 1'b1;
                    sell_uncovered     = unc_take_sell;
                end
            end

            // ── Top-of-book size imbalance ──────────────────────────────────
            // Bid-heavy implies upward pressure -> take the offer before it
            // lifts. Ask-heavy implies the reverse. imb_buy and imb_sell are
            // mutually exclusive (see §5), so the else-if is documentation of
            // priority, not a real arbitration.
            STRAT_IMBALANCE: begin
                if (imb_buy) begin
                    decision.action    = ACT_SEND;
                    decision.side      = SIDE_BUY;
                    decision.price     = s_top.ask_px;
                    decision.qty       = take_buy_qty;
                    decision.post_only = 1'b0;
                    decision.fired     = 1'b1;
                end else if (imb_sell) begin
                    decision.action    = ACT_SEND;
                    decision.side      = SIDE_SELL;
                    decision.price     = s_top.bid_px;
                    decision.qty       = take_sell_qty;
                    decision.post_only = 1'b0;
                    decision.fired     = 1'b1;
                    sell_uncovered     = unc_take_sell;
                end
            end

            // ── Unrecognised select: do nothing. Fail-closed. ───────────────
            default: begin
                decision.action = ACT_NONE;
            end
        endcase

        // ── Reg SHO flag, applied after the size is known ────────────────────
        decision.is_short = decision.fired && (decision.side == SIDE_SELL) &&
                            (sell_uncovered || sell_uncertain);

        // ── The gate has absolute veto ───────────────────────────────────────
        // Applied last and unconditionally, so no primitive can route around
        // it and no future edit can accidentally reorder it away.
        if (!gate_pass) begin
            decision           = '0;
            decision.action    = ACT_NONE;
            decision.side      = SIDE_BUY;
            decision.post_only = 1'b0;
            decision.is_short  = 1'b0;
            decision.strat_id  = sel;
            decision.fired     = 1'b0;
        end
    end

    // =========================================================================
    // 8. Assertions
    // =========================================================================
`ifndef SYNTHESIS
    // The gate veto is absolute.
    a_gate_veto: assert property (@(posedge clk) disable iff (rst)
        !gate_pass |-> (decision.action == ACT_NONE)
    ) else $error("trigger_logic: fired with gate_pass low");

    // STRAT_NONE is genuinely inert.
    a_strat_none_silent: assert property (@(posedge clk) disable iff (rst)
        (sel == STRAT_NONE) |-> (decision.action == ACT_NONE)
    ) else $error("trigger_logic: STRAT_NONE produced an action");

    // An unrecognised primitive is inert.
    a_illegal_sel_silent: assert property (@(posedge clk) disable iff (rst)
        !strat_sel_legal(sel) |-> (decision.action == ACT_NONE)
    ) else $error("trigger_logic: illegal strat_select produced an action");

    // Never emit a degenerate order.
    a_no_zero_qty: assert property (@(posedge clk) disable iff (rst)
        decision.fired |-> (decision.qty != 32'd0)
    ) else $error("trigger_logic: fired with zero quantity");

    a_no_zero_price: assert property (@(posedge clk) disable iff (rst)
        decision.fired |-> (decision.price != 32'd0)
    ) else $error("trigger_logic: fired with zero price");

    // ⚠️ POST-ONLY INTEGRITY. A post_only order must never be marketable.
    a_post_only_never_crosses: assert property (@(posedge clk) disable iff (rst)
        (decision.fired && decision.post_only && (decision.side == SIDE_BUY))
            |-> (decision.price < s_top.ask_px)
    ) else $error("trigger_logic: post-only BUY at or above the offer");

    a_post_only_never_crosses_sell: assert property (@(posedge clk) disable iff (rst)
        (decision.fired && decision.post_only && (decision.side == SIDE_SELL))
            |-> (decision.price > s_top.bid_px)
    ) else $error("trigger_logic: post-only SELL at or below the bid");

    // ⚠️ REG SHO. The literal rule — a sell with a non-positive position is a
    // short sale — must always be flagged. This is the compliance floor; the
    // implementation above is strictly stronger.
    a_short_flagged: assert property (@(posedge clk) disable iff (rst)
        (decision.fired && (decision.side == SIDE_SELL) &&
         (position <= position_t'(0))) |-> decision.is_short
    ) else $error("trigger_logic: REG SHO — short sale not flagged as short");

    // ...and the stronger form: any sell exceeding the long position.
    a_short_flagged_partial: assert property (@(posedge clk) disable iff (rst)
        (decision.fired && (decision.side == SIDE_SELL) &&
         (position < qty_to_pos(decision.qty))) |-> decision.is_short
    ) else $error("trigger_logic: REG SHO — sale exceeding the long position not flagged short");

    // A buy is never a short sale.
    a_buy_never_short: assert property (@(posedge clk) disable iff (rst)
        (decision.side == SIDE_BUY) |-> !decision.is_short
    ) else $error("trigger_logic: is_short set on a buy");

    // A take never clips above the displayed size.
    a_take_within_display: assert property (@(posedge clk) disable iff (rst)
        (decision.fired && !decision.post_only && (decision.side == SIDE_BUY))
            |-> (decision.qty <= s_top.ask_qty)
    ) else $error("trigger_logic: buy take exceeds displayed offer size");

    // Imbalance directions are mutually exclusive — the guarantee that
    // param_table's imbalance_thr >= IMB_SCALE check buys us.
    a_imb_exclusive: assert property (@(posedge clk) disable iff (rst)
        !(imb_buy && imb_sell)
    ) else $error("trigger_logic: imbalance fired both directions — imbalance_thr below IMB_SCALE reached the fast path");

    // The overflow guard really guards.
    a_imb_guard: assert property (@(posedge clk) disable iff (rst)
        ((s_top.bid_qty > IMB_QTY_MAX) || (s_top.ask_qty > IMB_QTY_MAX))
            |-> (!imb_buy && !imb_sell)
    ) else $error("trigger_logic: imbalance evaluated with a saturating operand");

    // `fired` and `action` are two views of one fact.
    a_fired_consistent: assert property (@(posedge clk) disable iff (rst)
        decision.fired == (decision.action == ACT_SEND)
    ) else $error("trigger_logic: fired/action disagree");
`endif

endmodule : trigger_logic

`default_nettype wire
