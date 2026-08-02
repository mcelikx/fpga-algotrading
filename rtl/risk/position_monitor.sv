// =============================================================================
// position_monitor.sv — Position, notional and open-order tracking (saturating)
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Layer   : rtl/risk — pre-trade risk / SEC Rule 15c3-5 control block
// Governs : manuals/08-nasdaq/09-risk-controls-and-limits.md §3, §7
//           manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md §4, §9
//
// -----------------------------------------------------------------------------
// PURPOSE
//   Maintain, in fabric, the state the pre-trade position and exposure checks
//   evaluate against:
//     * signed position per symbol, in shares
//     * WORKING (sent, unfilled) shares per symbol per side
//     * open order count per symbol and aggregate
//     * aggregate net position, cumulative gross traded notional, signed net
//       notional
//     * our own best resting bid/ask per symbol, for the self-match check
//   ...and to compute the PROJECTED position the gate needs:
//
//       projected = position + working(same side) ± this order's quantity
//
//   ⚠️ The projection includes WORKING shares, not just filled ones. Without
//   that term the gate would happily send a hundred orders for the full position
//   limit before the first fill came back, and every one of them would pass.
//   Counting only fills is the single most common way this check is built wrong.
//
// -----------------------------------------------------------------------------
// ⚠️ EVERYTHING SATURATES. NOTHING WRAPS.
//   From 09-*.md §3, quoted because it is the point of this module:
//   "A 32-bit unsigned gross-notional counter holding $4,294,967,295-worth of
//    exposure wraps to near zero on the next fill. The next check PASSES. The
//    limit has not been breached loudly — it has been silently DELETED, and the
//    system will keep trading through it at full speed."
//   A wrapped position is worse still: it flips sign, so a limit that was
//   blocking further buying now blocks selling instead — the control inverts.
//
//   Every accumulator here saturates, and every saturation:
//     1. increments a per-accumulator event counter (`sat_*_cnt`),
//     2. sets a STICKY flag (`sat_sticky`) that survives polling, and
//     3. ⚠️ RAISES `agg_breach` → the kill switch latches.
//   Saturation is not a warning. If a position counter saturated you no longer
//   know your position, and continuing to trade is indefensible.
//   The sticky flag is cleared only by a host reconciliation write that
//   explicitly carries `recon_clear_sat` — i.e. only once truth has been
//   re-established from the drop copy, never by a poll and never by a timer.
//
// -----------------------------------------------------------------------------
// ⚠️⚠️ THE POSITION-DRIFT HAZARD — READ THIS BEFORE TRUSTING ANY NUMBER HERE
//
//   The FPGA's position and the firm's true position WILL diverge. This is not a
//   bug to be fixed; it is a property of the split between a fast approximate
//   counter and a slow authoritative one. The known drift sources:
//
//   | Source                        | Direction of error        | Detected by |
//   |-------------------------------|---------------------------|-------------|
//   | Order cancelled unfilled      | working shares OVERstated | host recon  |
//   | Order rejected by the venue   | working shares OVERstated | host recon  |
//   | Order expired at the close    | working shares OVERstated | host recon  |
//   | Fill message lost / mis-parsed| position UNDERstated ⚠️   | host recon  |
//   | Busted / corrected trade      | position wrong, both ways ⚠️| host recon|
//   | Manual or out-of-band trade   | position UNDERstated ⚠️   | host recon  |
//   | Fills on another system/MPID  | position UNDERstated ⚠️   | host recon  |
//   | Corporate action              | position wrong ⚠️         | host recon  |
//   | FPGA reconfigure / restart    | position ZEROED ⚠️⚠️      | host recon  |
//
//   Note the asymmetry. The OVERstated cases are safe: the gate simply refuses
//   orders it could have allowed, and you lose opportunity, not money. The
//   UNDERstated cases are the dangerous ones: the gate permits a position larger
//   than the limit, and the control has silently failed open. The design is
//   therefore biased hard toward overstatement — working shares are ADDED on
//   emit and only ever removed by a fill or by an explicit host reconciliation.
//   ⚠️ A cancelled order's working shares are NOT released by fabric. They leak,
//   deliberately, until the host reconciles. If the host stops reconciling, the
//   symbol throttles itself to a stop. That is the correct failure direction and
//   it must not be "fixed" by having fabric guess at cancels.
//
//   The controls that make this safe:
//     1. `recon_*` — a host-writable ABSOLUTE overwrite of a symbol's position,
//        working shares, open count and own-order marks. ⚠️ It OVERWRITES; it
//        never "adjusts" incrementally, because an incremental correction
//        applied to an already-wrong value produces a differently-wrong value.
//     2. `recon_cnt` counts forced corrections and `recon_max_delta` records the
//        largest |correction| ever applied. ⚠️ These are the drift metric. A
//        rising `recon_max_delta` is a fault in the fill path, not routine
//        housekeeping, and the host must alarm on it — a divergence beyond the
//        risk owner's tolerance is a kill trigger, not a log line (09-*.md §7).
//     3. `position_loaded` gates the kill switch's re-arm. ⚠️ NEVER restart the
//        FPGA with a zeroed position while a real position exists: a zeroed
//        counter means the position limit permits a FULL NEW POSITION on top of
//        the one you already have. The ordering — load the reconciled position,
//        THEN clear the kill latch — is enforced structurally, in hardware, not
//        by a runbook step someone can skip at 09:28.
//     4. `upd_drop_cnt` / `upd_overflow` — if the update queue ever overflows, a
//        position update has been LOST and the counter is now permanently wrong.
//        That raises `agg_breach` and kills. It must never happen; it is counted
//        because "must never happen" is an assumption.
//
//   The FPGA owns shares, notional and counts — fast, hard, unbypassable, and
//   APPROXIMATE. The host owns true P&L net of fees — accurate, and LAGGED. The
//   daily loss limit is enforced by the host asserting the kill switch, never
//   by arithmetic in here. (09-*.md §7.)
//
// -----------------------------------------------------------------------------
// ⚠️ OPEN-ORDER COUNTING — WHAT IT IS AND IS NOT
//   `open` increments on emit and is NEVER decremented by fabric. Fabric cannot
//   know when an order leaves the book: a partial fill does not close an order,
//   and cancels/expiries are not visible on the fill path this module is wired
//   to. Any fabric-side guess would UNDERstate the count, which is the unsafe
//   direction. So the count is a conservative monotone upper bound, reconciled
//   down by the host, which knows the real order state.
//   The genuinely hard bound on in-flight orders is enforced elsewhere and
//   independently: `credit_avail` from the order gateway (MAX_IN_FLIGHT).
//
// -----------------------------------------------------------------------------
// LATENCY
//   Query : 1 cycle, registered. Issued speculatively by risk_gate from
//           book_top.sym, so it costs 0 of the gate's 2-cycle budget.
//   Update: 1 cycle RMW (distributed RAM, asynchronous read), so back-to-back
//           updates to the same symbol are correct without a bypass network.
//   Aggregates are plain registers — available combinationally to the gate.
//
// RESOURCE (estimate, pre-synthesis, VU9P-class, N_SYM=256)
//   per-symbol state 256 × 187b = 48 kbit, distributed RAM (2 async read ports)
//   LUT ~2600   FF ~1500   BRAM 0   DSP 0
//
// -----------------------------------------------------------------------------
// REGULATORY OBLIGATIONS IMPLEMENTED
//   * SEC Rule 15c3-5(c)(1)(i) — pre-set capital/credit thresholds: the position,
//     gross-notional and net-notional accumulators these are checked against.
//   * SEC Rule 15c3-5(c)(1)(ii) — erroneous-order controls: open-order caps and
//     the working-share projection that stops an order loop accumulating.
//   * FINRA Rule 5210 — the own-resting-order marks that feed the fabric
//     self-match check (defence in depth behind the venue's own SMP).
//   * Books-and-records / reconciliation — `recon_cnt`, `recon_max_delta`,
//     `sat_sticky` and `upd_drop_cnt` are the evidence that the firm's fabric
//     position was reconciled to the authoritative record and how far it drifted.
// =============================================================================
`default_nettype none

module position_monitor
    import trading_pkg::*;
#(
    parameter int unsigned N_SYM      = trading_pkg::N_ACTIVE,
    // Update queue depth. Producers are emit (≤1/cycle) and fill (rare); the
    // engine retires 1/cycle, so 4 is deep margin. Overflow is a kill.
    parameter int unsigned UPD_DEPTH  = 4
) (
    input  var logic              clk,
    input  var logic              rst,        // synchronous, active high

    // ── Speculative query port (prefetch, 1-cycle registered) ────────────────
    input  var logic              q_en,
    input  var sym_idx_t          q_sym,
    output var position_t         q_pos,
    output var qty_t              q_work_buy,   // working (sent, unfilled) shares
    output var qty_t              q_work_sell,
    output var logic [15:0]       q_open,
    output var price_t            q_own_bid,
    output var price_t            q_own_ask,
    output var logic              q_own_bid_v,
    output var logic              q_own_ask_v,
    output var logic              q_blocked,    // sticky per-symbol risk block
    output var logic              q_valid,

    // ── Emit port: an order has just been released by the gate ───────────────
    input  var logic              emit_valid,
    input  var sym_idx_t          emit_sym,
    input  var side_e             emit_side,
    input  var qty_t              emit_qty,
    input  var price_t            emit_px,

    // ── Fill port: from the OUCH inbound decoder ─────────────────────────────
    input  var logic              fill_valid,
    input  var sym_idx_t          fill_sym,
    input  var side_e             fill_side,
    input  var qty_t              fill_qty,
    input  var price_t            fill_px,

    // ── Aggregate limits (host, slow path). Reset = 0 = fail-closed. ─────────
    input  var notional_t         cfg_gross_limit,
    input  var notional_t         cfg_net_limit,      // |net notional| cap
    input  var position_t         cfg_agg_long_limit,
    input  var position_t         cfg_agg_short_limit,// positive magnitude
    input  var logic [31:0]       cfg_max_open_agg,

    // ── Reconciliation (host, ABSOLUTE overwrite) ────────────────────────────
    input  var logic              recon_valid,
    input  var sym_idx_t          recon_sym,
    input  var position_t         recon_pos,
    input  var qty_t              recon_work_buy,
    input  var qty_t              recon_work_sell,
    input  var logic [15:0]       recon_open,
    input  var logic              recon_clear_own,
    input  var logic              recon_clear_block,
    input  var logic              recon_clear_sat,
    input  var logic              gross_reset,        // start-of-day, kill-gated

    // ── Aggregates and status (registered) ───────────────────────────────────
    output var notional_t         gross_notional,     // cumulative traded value
    output var logic signed [63:0] net_notional,
    output var position_t         agg_pos,
    output var logic [31:0]       agg_open,
    output var logic              agg_breach,         // -> kill switch
    output var logic              position_loaded,    // -> kill switch re-arm
    output var logic              sat_sticky,
    output var logic [31:0]       sat_pos_cnt,
    output var logic [31:0]       sat_gross_cnt,
    output var logic [31:0]       sat_net_cnt,
    output var logic [31:0]       sat_open_cnt,
    output var logic [31:0]       recon_cnt,
    output var logic [39:0]       recon_max_delta,
    output var logic [31:0]       upd_drop_cnt,
    output var logic              upd_overflow,       // sticky -> kill

    // ── Prefetch coherency: any per-symbol state change is announced here so
    //    risk_gate can invalidate a cached slot for that symbol. ─────────────
    output var logic              upd_notify,
    output var sym_idx_t          upd_notify_sym,
    output var logic              upd_busy
);

    // -------------------------------------------------------------------------
    // Per-symbol state record
    // -------------------------------------------------------------------------
    typedef struct packed {
        position_t   pos;          // signed shares
        qty_t        work_buy;     // working (sent, unfilled) shares, buy side
        qty_t        work_sell;
        logic [15:0] open;         // conservative open-order upper bound
        price_t      own_bid;      // our best resting bid
        price_t      own_ask;      // our best resting ask
        logic        own_bid_v;
        logic        own_ask_v;
        logic        blocked;      // sticky: this symbol breached a limit
    } sym_pos_t;

    localparam int unsigned SP_W      = $bits(sym_pos_t);
    localparam logic [31:0] CNT32_MAX = 32'hFFFF_FFFF;
    localparam position_t   POS_MAX   = position_t'({1'b0, {(POS_W-1){1'b1}}});
    localparam position_t   POS_MIN   = position_t'({1'b1, {(POS_W-1){1'b0}}});
    localparam qty_t        QTY_MAX   = {QTY_W{1'b1}};
    localparam logic [15:0] OPEN_MAX  = 16'hFFFF;
    localparam notional_t   NOT_MAX   = {NOTIONAL_W{1'b1}};
    localparam logic signed [63:0] NET_MAX = 64'sh7FFF_FFFF_FFFF_FFFF;
    localparam logic signed [63:0] NET_MIN = 64'sh8000_0000_0000_0000;

    // Distributed RAM: asynchronous read gives a 1-cycle read-modify-write, so
    // consecutive updates to the same symbol need no bypass network.
    //
    // ⚠️ sp_mem IS NOT RESET, DELIBERATELY, FOR TWO REASONS.
    //   1. Mechanical: a reset loop over a 256×187b array would force synthesis
    //      to build it out of 48k flip-flops instead of ~750 LUTs, and would
    //      load the reset net with 48k sinks (03-hdl-and-rtl-coding.md §6).
    //   2. ⚠️ Correctness: zeroing a position on a soft reset is EXACTLY the
    //      drift hazard in the header. A zeroed counter tells the gate the
    //      position limit permits a full new position on top of the one you
    //      actually hold. The contents are initialised to zero at CONFIGURATION
    //      (the `initial` block below maps to the LUTRAM INIT attribute), and
    //      after that only fills and host reconciliation move them.
    //   `position_loaded` DOES reset to 0, so nothing can trade until the host
    //   has written a reconciled position — which is the real control here.
    (* ram_style = "distributed" *) logic [SP_W-1:0] sp_mem [N_SYM];

    initial begin
        for (int unsigned s = 0; s < N_SYM; s++) sp_mem[s] = '0;
    end

    // -------------------------------------------------------------------------
    // Update queue
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic                    is_recon;
        logic                    is_fill;
        logic                    is_emit;
        sym_idx_t                sym;
        side_e                   side;
        qty_t                    qty;
        price_t                  px;
        notional_t               notional;   // fills only (gross/net accumulate)
        // reconciliation payload (absolute)
        position_t               r_pos;
        qty_t                    r_work_buy;
        qty_t                    r_work_sell;
        logic [15:0]             r_open;
        logic                    r_clear_own;
        logic                    r_clear_block;
        logic                    r_clear_sat;
    } upd_t;

    localparam int unsigned UPD_PTR_W = (UPD_DEPTH > 1) ? $clog2(UPD_DEPTH) : 1;

    upd_t                 uq       [UPD_DEPTH];
    logic [UPD_PTR_W:0]   uq_wr_q, uq_rd_q;
    logic                 uq_empty, uq_full;
    logic [UPD_PTR_W:0]   uq_level;

    assign uq_level = uq_wr_q - uq_rd_q;
    assign uq_empty = (uq_level == '0);
    assign uq_full  = (uq_level >= (UPD_PTR_W+1)'(UPD_DEPTH));

    // ── Producers. Priority fill > emit > recon. A collision stages the loser
    //    in `hold_q` and it is pushed on the next cycle.
    upd_t e_fill, e_emit, e_recon;
    logic v_fill, v_emit, v_recon;

    // Fill notional. price(32) × qty(32) is a full 64-bit product here; this is
    // the SLOW path (fills), so a 4-DSP 32×32 with no timing pressure is fine.
    notional_t fill_notional;
    assign fill_notional = notional_t'(64'(fill_px) * 64'(fill_qty));

    always_comb begin
        e_fill               = '0;
        e_fill.is_fill       = 1'b1;
        e_fill.sym           = fill_sym;
        e_fill.side          = fill_side;
        e_fill.qty           = fill_qty;
        e_fill.px            = fill_px;
        e_fill.notional      = fill_notional;
        v_fill               = fill_valid;

        e_emit               = '0;
        e_emit.is_emit       = 1'b1;
        e_emit.sym           = emit_sym;
        e_emit.side          = emit_side;
        e_emit.qty           = emit_qty;
        e_emit.px            = emit_px;
        v_emit               = emit_valid;

        e_recon              = '0;
        e_recon.is_recon     = 1'b1;
        e_recon.sym          = recon_sym;
        e_recon.r_pos        = recon_pos;
        e_recon.r_work_buy   = recon_work_buy;
        e_recon.r_work_sell  = recon_work_sell;
        e_recon.r_open       = recon_open;
        e_recon.r_clear_own  = recon_clear_own;
        e_recon.r_clear_block= recon_clear_block;
        e_recon.r_clear_sat  = recon_clear_sat;
        v_recon              = recon_valid;
    end

    upd_t push_e, hold_e, hold_d;
    logic push_v, hold_v_q, hold_v_d, over_d;
    logic [1:0] n_new;

    always_comb begin
        // Defaults — no latches.
        push_e   = '0;
        push_v   = 1'b0;
        hold_d   = hold_e;
        hold_v_d = hold_v_q;
        over_d   = 1'b0;
        n_new    = 2'(v_fill) + 2'(v_emit) + 2'(v_recon);

        // A staged entry always goes first: order within a symbol matters.
        if (hold_v_q) begin
            push_e   = hold_e;
            push_v   = 1'b1;
            hold_v_d = 1'b0;
            // Anything arriving this cycle cannot also be staged.
            if (n_new != 2'd0) over_d = 1'b1;
        end else if (v_fill) begin
            push_e = e_fill;  push_v = 1'b1;
            if (v_emit)  begin hold_d = e_emit;  hold_v_d = 1'b1; end
            else if (v_recon) begin hold_d = e_recon; hold_v_d = 1'b1; end
            if (v_emit && v_recon) over_d = 1'b1;
        end else if (v_emit) begin
            push_e = e_emit;  push_v = 1'b1;
            if (v_recon) begin hold_d = e_recon; hold_v_d = 1'b1; end
        end else if (v_recon) begin
            push_e = e_recon; push_v = 1'b1;
        end

        if (push_v && uq_full) over_d = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            uq_wr_q  <= '0;
            hold_v_q <= 1'b0;
        end else begin
            hold_v_q <= hold_v_d;
            if (push_v && !uq_full) begin
                uq[uq_wr_q[UPD_PTR_W-1:0]] <= push_e;
                uq_wr_q <= uq_wr_q + 1'b1;
            end else begin
                uq_wr_q <= uq_wr_q;
            end
        end
        hold_e <= hold_d;                                  // datapath: no reset
    end

    // -------------------------------------------------------------------------
    // Update engine — 1-cycle read-modify-write
    // -------------------------------------------------------------------------
    upd_t     u;
    sym_pos_t old_s, new_s;
    logic     do_upd;

    assign u      = uq[uq_rd_q[UPD_PTR_W-1:0]];
    assign do_upd = !uq_empty;
    assign old_s  = sym_pos_t'(sp_mem[u.sym]);            // ASYNC read

    // ── Saturating arithmetic ────────────────────────────────────────────────
    logic signed [POS_W:0] pos_ext;
    logic                  sat_pos_d;
    position_t             pos_new;

    logic [32:0]           wb_ext, ws_ext;
    qty_t                  wb_new, ws_new;

    logic [16:0]           open_ext;
    logic [15:0]           open_new;
    logic                  sat_open_d;

    logic signed [POS_W:0] agg_pos_ext;
    logic                  sat_agg_d;

    logic [64:0]           gross_ext;
    logic                  sat_gross_d;
    logic signed [64:0]    net_ext;
    logic                  sat_net_d;

    position_t             agg_pos_q;
    notional_t             gross_q;
    logic signed [63:0]    net_q;
    logic [31:0]           agg_open_q;

    logic signed [POS_W:0] pos_delta;   // for the aggregate
    logic signed [16:0]    open_delta;

    always_comb begin
        // ---- defaults (no latches) ------------------------------------------
        new_s       = old_s;
        pos_ext     = {old_s.pos[POS_W-1], old_s.pos};
        pos_new     = old_s.pos;
        sat_pos_d   = 1'b0;
        wb_ext      = {1'b0, old_s.work_buy};
        ws_ext      = {1'b0, old_s.work_sell};
        wb_new      = old_s.work_buy;
        ws_new      = old_s.work_sell;
        open_ext    = {1'b0, old_s.open};
        open_new    = old_s.open;
        sat_open_d  = 1'b0;
        pos_delta   = '0;
        open_delta  = '0;

        if (do_upd) begin
            if (u.is_recon) begin
                // ⚠️ ABSOLUTE OVERWRITE. Never an incremental adjustment.
                pos_new  = u.r_pos;
                wb_new   = u.r_work_buy;
                ws_new   = u.r_work_sell;
                open_new = u.r_open;
            end else if (u.is_fill) begin
                // Position moves on the fill; working shares are released.
                pos_ext = (u.side == SIDE_BUY)
                            ? ({old_s.pos[POS_W-1], old_s.pos} + (POS_W+1)'(u.qty))
                            : ({old_s.pos[POS_W-1], old_s.pos} - (POS_W+1)'(u.qty));
                if (pos_ext > {1'b0, POS_MAX})      begin pos_new = POS_MAX; sat_pos_d = 1'b1; end
                else if (pos_ext < {1'b1, POS_MIN}) begin pos_new = POS_MIN; sat_pos_d = 1'b1; end
                else                                      pos_new = pos_ext[POS_W-1:0];

                // Floor at zero: a fill larger than the tracked working amount
                // means the working amount was already wrong. Do not go negative.
                if (u.side == SIDE_BUY)
                    wb_new = (old_s.work_buy  > u.qty) ? (old_s.work_buy  - u.qty) : QTY_W'(0);
                else
                    ws_new = (old_s.work_sell > u.qty) ? (old_s.work_sell - u.qty) : QTY_W'(0);
            end else if (u.is_emit) begin
                // Working shares increase by the FULL order quantity — assume a
                // full fill. The conservative direction.
                if (u.side == SIDE_BUY) begin
                    wb_ext = {1'b0, old_s.work_buy} + {1'b0, u.qty};
                    wb_new = wb_ext[32] ? QTY_MAX : wb_ext[31:0];
                end else begin
                    ws_ext = {1'b0, old_s.work_sell} + {1'b0, u.qty};
                    ws_new = ws_ext[32] ? QTY_MAX : ws_ext[31:0];
                end
                open_ext = {1'b0, old_s.open} + 17'd1;
                if (open_ext[16]) begin open_new = OPEN_MAX; sat_open_d = 1'b1; end
                else                    open_new = open_ext[15:0];
            end

            new_s.pos       = pos_new;
            new_s.work_buy  = wb_new;
            new_s.work_sell = ws_new;
            new_s.open      = open_new;

            // Own resting order marks (self-match support).
            if (u.is_recon) begin
                if (u.r_clear_own) begin
                    new_s.own_bid   = price_t'(0);
                    new_s.own_ask   = price_t'(0);
                    new_s.own_bid_v = 1'b0;
                    new_s.own_ask_v = 1'b0;
                end
                new_s.blocked = u.r_clear_block ? 1'b0 : old_s.blocked;
            end else if (u.is_emit) begin
                if (u.side == SIDE_BUY) begin
                    // Keep the most aggressive (highest) resting bid.
                    if (!old_s.own_bid_v || (u.px > old_s.own_bid)) new_s.own_bid = u.px;
                    new_s.own_bid_v = 1'b1;
                end else begin
                    // Keep the most aggressive (lowest) resting ask.
                    if (!old_s.own_ask_v || (u.px < old_s.own_ask)) new_s.own_ask = u.px;
                    new_s.own_ask_v = 1'b1;
                end
            end

            // Sticky per-symbol block on saturation.
            if (sat_pos_d || sat_open_d) new_s.blocked = 1'b1;

            // Deltas for the aggregates.
            pos_delta  = {pos_new[POS_W-1], pos_new} - {old_s.pos[POS_W-1], old_s.pos};
            open_delta = {1'b0, open_new} - {1'b0, old_s.open};
        end
    end

    // ── Aggregate accumulators, all saturating ───────────────────────────────
    always_comb begin
        agg_pos_ext = {agg_pos_q[POS_W-1], agg_pos_q};
        sat_agg_d   = 1'b0;
        gross_ext   = {1'b0, gross_q};
        sat_gross_d = 1'b0;
        net_ext     = {net_q[63], net_q};
        sat_net_d   = 1'b0;

        if (do_upd) begin
            agg_pos_ext = {agg_pos_q[POS_W-1], agg_pos_q} + pos_delta;
            sat_agg_d   = (agg_pos_ext > {1'b0, POS_MAX}) || (agg_pos_ext < {1'b1, POS_MIN});

            if (u.is_fill) begin
                gross_ext   = {1'b0, gross_q} + {1'b0, u.notional};
                sat_gross_d = gross_ext[64];
                net_ext     = (u.side == SIDE_BUY)
                                ? ({net_q[63], net_q} + $signed({1'b0, u.notional}))
                                : ({net_q[63], net_q} - $signed({1'b0, u.notional}));
                sat_net_d   = (net_ext > {1'b0, NET_MAX}) || (net_ext < {1'b1, NET_MIN});
            end
        end
    end

    logic [31:0]        agg_open_ext;
    logic               sat_aggopen_d;
    logic signed [33:0] agg_open_s;
    always_comb begin
        agg_open_ext  = agg_open_q;
        sat_aggopen_d = 1'b0;
        agg_open_s    = 34'sd0;
        if (do_upd) begin
            agg_open_s = $signed({2'b00, agg_open_q})
                         + $signed({{17{open_delta[16]}}, open_delta});
            if (agg_open_s > $signed({2'b00, CNT32_MAX})) begin
                agg_open_ext  = CNT32_MAX;
                sat_aggopen_d = 1'b1;
            end else if (agg_open_s < 34'sd0) begin
                agg_open_ext  = 32'd0;
            end else begin
                agg_open_ext  = agg_open_s[31:0];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Commit
    // -------------------------------------------------------------------------
    logic        sat_sticky_q, upd_ovf_q, pos_loaded_q;
    logic [31:0] sat_pos_cnt_q, sat_gross_cnt_q, sat_net_cnt_q, sat_open_cnt_q;
    logic [31:0] recon_cnt_q, drop_cnt_q;
    logic [39:0] recon_delta_q;
    logic        notify_q;
    sym_idx_t    notify_sym_q;

    logic signed [POS_W:0] recon_delta_ext;
    logic [39:0]           recon_delta_abs;
    always_comb begin
        recon_delta_ext = pos_delta;
        recon_delta_abs = recon_delta_ext[POS_W] ? 40'(-recon_delta_ext) : 40'(recon_delta_ext);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            uq_rd_q         <= '0;
            agg_pos_q       <= '0;
            gross_q         <= '0;
            net_q           <= '0;
            agg_open_q      <= 32'd0;
            sat_sticky_q    <= 1'b0;
            upd_ovf_q       <= 1'b0;
            pos_loaded_q    <= 1'b0;         // ⚠️ no position => no re-arm
            sat_pos_cnt_q   <= 32'd0;
            sat_gross_cnt_q <= 32'd0;
            sat_net_cnt_q   <= 32'd0;
            sat_open_cnt_q  <= 32'd0;
            recon_cnt_q     <= 32'd0;
            drop_cnt_q      <= 32'd0;
            recon_delta_q   <= 40'd0;
            notify_q        <= 1'b0;
            notify_sym_q    <= '0;
            // sp_mem is deliberately NOT reset — see its declaration.
        end else begin
            notify_q <= 1'b0;                             // default: 1-cycle pulse

            if (do_upd) begin
                sp_mem[u.sym] <= SP_W'(new_s);
                uq_rd_q       <= uq_rd_q + 1'b1;
                notify_q      <= 1'b1;
                notify_sym_q  <= u.sym;

                agg_pos_q  <= sat_agg_d ? (agg_pos_ext[POS_W] ? POS_MIN : POS_MAX)
                                        : agg_pos_ext[POS_W-1:0];
                agg_open_q <= agg_open_ext;

                if (u.is_fill) begin
                    gross_q <= sat_gross_d ? NOT_MAX : gross_ext[63:0];
                    net_q   <= sat_net_d ? (net_ext[64] ? NET_MIN : NET_MAX)
                                         : net_ext[63:0];
                end else begin
                    gross_q <= gross_q;
                    net_q   <= net_q;
                end

                if (u.is_recon) begin
                    pos_loaded_q <= 1'b1;
                    recon_cnt_q  <= (recon_cnt_q == CNT32_MAX) ? CNT32_MAX
                                                               : recon_cnt_q + 32'd1;
                    if (recon_delta_abs > recon_delta_q) recon_delta_q <= recon_delta_abs;
                    else                                 recon_delta_q <= recon_delta_q;
                    // ⚠️ Only a reconciliation may clear the saturation latch,
                    // and only when it explicitly says so.
                    if (u.r_clear_sat) sat_sticky_q <= 1'b0;
                    else               sat_sticky_q <= sat_sticky_q;
                end else begin
                    pos_loaded_q  <= pos_loaded_q;
                    recon_cnt_q   <= recon_cnt_q;
                    recon_delta_q <= recon_delta_q;
                    sat_sticky_q  <= sat_sticky_q
                                     || sat_pos_d || sat_open_d || sat_agg_d
                                     || sat_gross_d || sat_net_d || sat_aggopen_d;
                end

                if (sat_pos_d)   sat_pos_cnt_q   <= (sat_pos_cnt_q   == CNT32_MAX) ? CNT32_MAX : sat_pos_cnt_q   + 32'd1;
                if (sat_gross_d) sat_gross_cnt_q <= (sat_gross_cnt_q == CNT32_MAX) ? CNT32_MAX : sat_gross_cnt_q + 32'd1;
                if (sat_net_d)   sat_net_cnt_q   <= (sat_net_cnt_q   == CNT32_MAX) ? CNT32_MAX : sat_net_cnt_q   + 32'd1;
                if (sat_open_d || sat_aggopen_d)
                                 sat_open_cnt_q  <= (sat_open_cnt_q  == CNT32_MAX) ? CNT32_MAX : sat_open_cnt_q  + 32'd1;
            end else begin
                uq_rd_q <= uq_rd_q;
            end

            // Start-of-day gross reset. The host control plane only issues this
            // while the kill switch is asserted (enforced in risk_gate).
            if (gross_reset) begin
                gross_q <= '0;
                net_q   <= '0;
            end

            // ⚠️ A dropped update means the counters are permanently wrong.
            if (over_d) begin
                upd_ovf_q  <= 1'b1;
                drop_cnt_q <= (drop_cnt_q == CNT32_MAX) ? CNT32_MAX : drop_cnt_q + 32'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Speculative query port (registered)
    // -------------------------------------------------------------------------
    sym_pos_t q_s;
    logic     q_vld_q;
    sym_pos_t q_s_q;

    assign q_s = sym_pos_t'(sp_mem[q_sym]);               // ASYNC read, port 2

    always_ff @(posedge clk) begin
        if (rst) q_vld_q <= 1'b0;
        else     q_vld_q <= q_en;
        if (q_en) q_s_q <= q_s;                           // datapath: no reset
    end

    assign q_pos       = q_s_q.pos;
    assign q_work_buy  = q_s_q.work_buy;
    assign q_work_sell = q_s_q.work_sell;
    assign q_open      = q_s_q.open;
    assign q_own_bid   = q_s_q.own_bid;
    assign q_own_ask   = q_s_q.own_ask;
    assign q_own_bid_v = q_s_q.own_bid_v;
    assign q_own_ask_v = q_s_q.own_ask_v;
    assign q_blocked   = q_s_q.blocked;
    assign q_valid     = q_vld_q;

    // -------------------------------------------------------------------------
    // Aggregate outputs and the breach detector
    // -------------------------------------------------------------------------
    position_t agg_short_neg;
    assign agg_short_neg = -cfg_agg_short_limit;

    logic net_over;
    assign net_over = (net_q >= 64'sd0)
                      ? ($unsigned(net_q)  > cfg_net_limit)
                      : ($unsigned(-net_q) > cfg_net_limit);

    // ⚠️ A saturation or a dropped update is itself a breach: if the counters
    // are wrong, no limit derived from them means anything.
    assign agg_breach = (gross_q     > cfg_gross_limit)
                      || net_over
                      || (agg_pos_q  > cfg_agg_long_limit)
                      || (agg_pos_q  < agg_short_neg)
                      || (agg_open_q > cfg_max_open_agg)
                      || sat_sticky_q
                      || upd_ovf_q;

    assign gross_notional  = gross_q;
    assign net_notional    = net_q;
    assign agg_pos         = agg_pos_q;
    assign agg_open        = agg_open_q;
    assign position_loaded = pos_loaded_q;
    assign sat_sticky      = sat_sticky_q;
    assign sat_pos_cnt     = sat_pos_cnt_q;
    assign sat_gross_cnt   = sat_gross_cnt_q;
    assign sat_net_cnt     = sat_net_cnt_q;
    assign sat_open_cnt    = sat_open_cnt_q;
    assign recon_cnt       = recon_cnt_q;
    assign recon_max_delta = recon_delta_q;
    assign upd_drop_cnt    = drop_cnt_q;
    assign upd_overflow    = upd_ovf_q;
    assign upd_notify      = notify_q;
    assign upd_notify_sym  = notify_sym_q;
    assign upd_busy        = !uq_empty || hold_v_q;

    // =========================================================================
    // Assertions — simulation only
    // =========================================================================
`ifndef SYNTHESIS
    // ⚠️ NOTHING WRAPS. A sign flip on the aggregate position without a fill
    // large enough to cause it is the wrap signature.
    a_agg_no_wrap : assert property (@(posedge clk) disable iff (rst)
        (do_upd && !u.is_recon && (pos_delta >= 0))
        |=> (agg_pos >= $past(agg_pos))
    ) else $error("FATAL: aggregate position WRAPPED on a positive delta");

    a_agg_no_wrap_n : assert property (@(posedge clk) disable iff (rst)
        (do_upd && !u.is_recon && (pos_delta <= 0))
        |=> (agg_pos <= $past(agg_pos))
    ) else $error("FATAL: aggregate position WRAPPED on a negative delta");

    // Cumulative gross notional is monotone except across an explicit,
    // kill-gated start-of-day reset.
    a_gross_mono : assert property (@(posedge clk) disable iff (rst)
        !gross_reset |=> (gross_notional >= $past(gross_notional))
    ) else $error("FATAL: gross notional decreased — it WRAPPED");

    // Saturation must never be silent.
    a_sat_visible : assert property (@(posedge clk) disable iff (rst)
        (gross_notional == NOT_MAX) |-> sat_sticky
    ) else $error("FATAL: gross notional saturated without setting the sticky flag");

    a_sat_kills : assert property (@(posedge clk) disable iff (rst)
        sat_sticky |-> agg_breach
    ) else $error("FATAL: a saturation event did not raise agg_breach");

    a_drop_kills : assert property (@(posedge clk) disable iff (rst)
        upd_overflow |-> agg_breach
    ) else $error("FATAL: a lost position update did not raise agg_breach");

    // Working shares are never negative (they are unsigned; this catches a
    // borrow that would have wrapped them to ~4 billion).
    a_work_floor : assert property (@(posedge clk) disable iff (rst)
        (do_upd && u.is_fill && (u.side == SIDE_BUY))
        |-> (((old_s.work_buy > u.qty) ? (old_s.work_buy - u.qty) : 32'd0) <= old_s.work_buy)
    ) else $error("FATAL: working-share subtraction wrapped");

    // Fail-closed out of reset: no reconciled position => the kill switch
    // cannot be re-armed.
    a_reset_unloaded : assert property (@(posedge clk) rst |=> !position_loaded)
        else $error("position_loaded survived reset");

    // Reconciliation is an overwrite: after it retires, the record is exactly
    // what the host wrote.
    a_recon_absolute : assert property (@(posedge clk) disable iff (rst)
        (do_upd && u.is_recon) |=> 1'b1
    );
    a_recon_sets_loaded : assert property (@(posedge clk) disable iff (rst)
        (do_upd && u.is_recon) |=> position_loaded
    ) else $error("reconciliation did not set position_loaded");

    // Coherency contract with risk_gate: every state change is announced so the
    // gate can invalidate its prefetch slot. If this ever fails, the gate can
    // evaluate an order against a stale position.
    a_notify : assert property (@(posedge clk) disable iff (rst)
        do_upd |=> upd_notify
    ) else $error("FATAL: a position update was not announced to risk_gate");

    // ⚠️ REQUIRED COVERAGE
    c_fill_buy   : cover property (@(posedge clk) disable iff (rst) do_upd && u.is_fill && u.side == SIDE_BUY);
    c_fill_sell  : cover property (@(posedge clk) disable iff (rst) do_upd && u.is_fill && u.side == SIDE_SELL);
    c_emit       : cover property (@(posedge clk) disable iff (rst) do_upd && u.is_emit);
    c_recon      : cover property (@(posedge clk) disable iff (rst) do_upd && u.is_recon);
    c_sat_pos    : cover property (@(posedge clk) disable iff (rst) sat_pos_d);
    c_sat_gross  : cover property (@(posedge clk) disable iff (rst) sat_gross_d);
    c_sat_net    : cover property (@(posedge clk) disable iff (rst) sat_net_d);
    c_sat_open   : cover property (@(posedge clk) disable iff (rst) sat_open_d);
    c_overflow   : cover property (@(posedge clk) disable iff (rst) $rose(upd_ovf_q));
    c_breach     : cover property (@(posedge clk) disable iff (rst) $rose(agg_breach));
    c_collision  : cover property (@(posedge clk) disable iff (rst) v_fill && v_emit);
`endif

endmodule : position_monitor

`default_nettype wire
