// =============================================================================
// position_track.sv — The strategy's own view of position and open orders
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Layer   : rtl/strategy/  (budget row S0 — read alongside the parameter read)
// Governs : manuals/04-system-architecture/04-strategy-engine-on-fpga.md
//           manuals/04-system-architecture/06-cpu-fpga-partitioning.md
//           manuals/08-nasdaq/09-risk-controls-and-limits.md
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// -----------------------------------------------------------------------------
// PURPOSE
//   Per-symbol signed position and open-order count, maintained from the fill
//   feedback the order gateway decodes out of the OUCH inbound stream. The
//   strategy needs these in ONE CYCLE, in the fabric, to decide side (which way
//   to skew a quote) and — critically — to set is_short.
//
// -----------------------------------------------------------------------------
// ⚠️  THE POSITION-DRIFT HAZARD — READ THIS BEFORE TRUSTING ANY NUMBER HERE
//
//   THE POSITION IN THIS MODULE IS AN ESTIMATE. It is not the position. The
//   position is what the clearing firm says it is at the end of the day, and
//   during the day the closest available truth is the drop copy. Everything
//   here is a local reconstruction from one message stream, and it drifts:
//
//   1. IN-FLIGHT FILLS. A fill that happened at the venue but whose message has
//      not yet crossed the wire is invisible. Unavoidable — speed of light.
//      Bounded by MAX_IN_FLIGHT (trading_pkg) and by the in-flight credit the
//      order gateway hands out.
//
//   2. MISSED OR DROPPED FEEDBACK. If a fill message is lost, corrupted, or
//      dropped by a downstream block under load, the position here is wrong
//      FOREVER — there is no self-correcting mechanism in a delta-accumulator.
//      This is the dangerous one: the error is permanent and silent.
//
//   3. NO ACK/CANCEL VISIBILITY. The port contract from fpga_top.sv gives this
//      layer fill_valid/sym/side/qty and NOTHING ELSE. There is no ack, no
//      cancel-accepted, no reject. So open_orders is incremented on every emit
//      and decremented only on a FILL. It is therefore an UPPER BOUND on
//      working orders, and it ratchets upward every time an order is cancelled
//      or rejected. See §3 — this is deliberate and conservative, but it MUST
//      be re-synced by the host or the symbol eventually stops quoting.
//
//   4. OUT-OF-BAND ACTIVITY. Anything the desk does in the same symbol through
//      another channel is invisible here by construction.
//
//   THE MITIGATIONS, all of which are in this module:
//
//   * EXPOSE the FPGA's estimate (rd_pos / rd_open_orders are read by the fast
//     path; the host reads the same arrays through the telemetry counters and
//     by comparing emitted-order and fill counts). The host reconciles against
//     drop-copy and clearing data at its own cadence.
//   * ACCEPT a host-written FORCE POSITION (force_valid). Reconciliation is a
//     slow-path job and its result must be able to reach the fabric.
//   * COUNT forced corrections (force_cnt). ⚠️ A nonzero and GROWING count is
//     the alarm: it means the FPGA and the host disagree repeatedly, which
//     means feedback is being lost somewhere upstream. One correction at
//     session start is housekeeping. Ten an hour is an incident.
//   * COUNT saturations and open-order underflows — both are impossible in a
//     healthy system, so a nonzero value is a bug report.
//
//   AND THE BACKSTOP: rtl/risk/risk_gate.sv keeps its OWN position from the
//   same fill feed and enforces the real position limits. Nothing in this
//   module is a risk control. It is an input to a trading decision.
//
// -----------------------------------------------------------------------------
// LATENCY
//   Read  : 1 cycle (6.4 ns). Address in cycle N, rd_pos / rd_open_orders
//           registered and valid in cycle N+1. Runs in parallel with the
//           param_table read — both are budget row S0.
//   Update: 1 cycle, from any combination of emit / fill / force, all of which
//           may land in the SAME cycle on DIFFERENT symbols. No arbitration, no
//           queue, no drops. See §2.
//
//   ⚠️ STALENESS WINDOW. The registered read means the value used in stage S1
//   reflects updates up to and including cycle N-1. An update landing in cycle
//   N or N+1 is not seen by the evaluation in flight. Worst case: two book
//   events one cycle apart in the same symbol both read the pre-emit
//   open-order count. Forwarding into the fast path was rejected — it would put
//   an adder and a same-address compare into S1, which has no room (see
//   trigger_logic.sv §7). The consequence is bounded (one extra clip of
//   exposure) and is covered by CONSERVATIVE_SHORT and by the risk gate.
//
// RESOURCE (estimate, N_ENTRIES=256, POS_W=40, OPEN_CNT_W=16, UltraScale+)
//   FF  : position  256 x 40   = 10,240
//         open_cnt  256 x 16   =  4,096
//         read regs + counters =    170
//                              --------
//                              ~14,500 FF
//   LUT : read mux 256:1 x 56b ~ 4,800
//         write decode + sat   ~   400
//                              --------
//                              ~ 5,200 LUT
//   BRAM: 0     DSP: 0
//
//   ⚠️ WHY A REGISTER FILE AND NOT BRAM. 14.5k FF is ~16% of the fast-path FF
//   budget and it is bought on purpose. A register file accepts emit, fill and
//   force in the SAME cycle on THREE DIFFERENT symbols with no arbitration, no
//   read-modify-write pipeline, no same-address forwarding, and — the point —
//   NO POSSIBILITY OF A DROPPED UPDATE. A BRAM implementation needs a
//   serialised update port with a FIFO, a bypass network, and a drop counter,
//   and every one of those is a new way to silently lose a fill. Given that the
//   entire subject of this module is "the position quietly goes wrong", paying
//   fabric for a structure that cannot lose an update is the right trade.
//
//   REVISIT above N_ENTRIES ~= 512, where the 256:1 read mux depth (currently
//   ~3 LUT6 levels) becomes the binding constraint rather than the FF count.
//   At that size, move to BRAM and add the FIFO + bypass + drop counter, and
//   budget a testbench for the bypass specifically.
// =============================================================================
`default_nettype none

module position_track
    import trading_pkg::*;
    import strategy_pkg::*;
#(
    parameter int unsigned N_ENTRIES = N_ACTIVE
) (
    input  var logic       clk,
    input  var logic       rst,          // synchronous, active high

    // ── Fast path read (budget row S0) ───────────────────────────────────────
    input  var logic       rd_en,
    input  var sym_idx_t   rd_sym,
    output var position_t  rd_pos,        // valid at N+1
    output var open_cnt_t  rd_open_orders,// valid at N+1

    // ── Emit feedback (from our own m_req_valid) ─────────────────────────────
    // An emit does NOT move the position — only a fill does. It moves the
    // open-order count, which is what bounds how much unknown exposure we are
    // carrying at any instant.
    input  var logic       emit_valid,
    input  var sym_idx_t   emit_sym,

    // ── Fill feedback (from order_gateway, decoded from OUCH inbound) ────────
    input  var logic       fill_valid,
    input  var sym_idx_t   fill_sym,
    input  var side_e      fill_side,
    input  var qty_t       fill_qty,

    // ── Host reconciliation (slow path) ──────────────────────────────────────
    // ⚠️ The escape hatch that makes drift survivable. The host reconciles
    // against drop-copy/clearing and writes the truth back.
    input  var logic       force_valid,
    input  var sym_idx_t   force_sym,
    input  var position_t  force_pos,
    input  var open_cnt_t  force_open,

    // ── Telemetry ────────────────────────────────────────────────────────────
    output var logic [31:0] force_cnt,       // ⚠️ growing = feedback is lost
    output var logic [31:0] fill_cnt,
    output var logic [31:0] emit_cnt,
    output var logic [31:0] sat_cnt,         // position saturated: MUST be 0
    output var logic [31:0] open_underflow_cnt // fill with no order: MUST be 0
);

    // =========================================================================
    // 1. Storage
    // =========================================================================
    // Datapath state. Reset IS applied here, unusually for a datapath array —
    // justified because "unknown position" is not a safe starting condition:
    // is_short and the quote-side skew both read it before any fill has ever
    // arrived. Flat-at-reset is the only defensible power-on value, and it
    // costs one reset fanout on a structure that is already large.
    position_t pos_q  [N_ENTRIES];
    open_cnt_t open_q [N_ENTRIES];

    // =========================================================================
    // 2. Per-symbol update — three concurrent sources, no arbitration
    // =========================================================================
    // emit / fill / force may all fire in the same cycle on different symbols.
    // Because every entry is its own flip-flop bank with its own enable, all
    // three land simultaneously. There is nothing to arbitrate and nothing to
    // drop. When two sources hit the SAME symbol in the same cycle, force wins
    // outright (it is the reconciled truth and must not be perturbed by a
    // delta), and emit + fill combine — an emit only touches open_q, a fill
    // touches both, so a same-cycle emit and fill on one symbol nets to
    // "+1 order, -1 order, position moves", which is exactly right.
    position_t pos_delta;
    position_t pos_next_sat;
    logic      pos_saturated;

    // A buy adds shares, a sell removes them. Signed, saturating.
    assign pos_delta = (fill_side == SIDE_BUY) ?  qty_to_pos(fill_qty)
                                               : -qty_to_pos(fill_qty);

    // Saturation is evaluated for the addressed symbol only. The mux that picks
    // pos_q[fill_sym] is the same 256:1 structure as the read port; it is off
    // the fast path (fills are a slow, sporadic stream) so its depth is free.
    position_t pos_at_fill;
    assign pos_at_fill  = pos_q[fill_sym];
    assign pos_next_sat = sat_add_pos(pos_at_fill, pos_delta);

    // ⚠️ A saturated position means POS_W has been exceeded — 2^39 shares. That
    // is not a market event, it is a runaway accumulator or a corrupted fill
    // qty. Counted so it can never be silent.
    assign pos_saturated = fill_valid &&
                           ((pos_next_sat == POS_MAX) || (pos_next_sat == POS_MIN));

    // ⚠️ A fill on a symbol with zero open orders means we are being filled on
    // an order we do not believe exists. Either the count drifted (most likely)
    // or we are receiving someone else's fills (much worse). Counted.
    logic open_underflow;
    assign open_underflow = fill_valid && (open_q[fill_sym] == {OPEN_CNT_W{1'b0}});

    // =========================================================================
    // 3. Open-order accounting
    // =========================================================================
    // increment on EMIT, decrement on FILL.
    //
    // ⚠️ There is no ack and no cancel on this interface (see the header, drift
    // cause 3). A cancelled or rejected order therefore leaves its increment
    // behind permanently. The count is an UPPER BOUND: it is never lower than
    // the true number of working orders. That direction is chosen deliberately,
    // because the count feeds:
    //     * trigger_logic's CONSERVATIVE_SHORT term — an over-count marks MORE
    //       sales as short, which is the safe direction for Reg SHO;
    //     * the host's "is this symbol wedged?" telemetry.
    // The correction path is force_open, which the host writes during the same
    // reconciliation pass that fixes the position.
    open_cnt_t open_at_emit;
    open_cnt_t open_at_fill;
    assign open_at_emit = open_q[emit_sym];
    assign open_at_fill = open_q[fill_sym];

    // Same-symbol emit AND fill in one cycle: +1 and -1 on the same entry. Both
    // branches below would write open_q[sym] and the later one would win,
    // silently losing a count. Detect the collision and net the two deltas to
    // zero in the fill branch instead. One compare; the case is rare but it is
    // exactly the kind of quiet off-by-one that turns into an unexplained
    // "why did this symbol stop quoting" three weeks later.
    logic same_sym_emit_fill;
    assign same_sym_emit_fill = emit_valid && fill_valid && (emit_sym == fill_sym);

    // =========================================================================
    // 4. Sequential
    // =========================================================================
    logic [31:0] force_cnt_q, fill_cnt_q, emit_cnt_q;
    logic [31:0] sat_cnt_q, open_underflow_cnt_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned i = 0; i < N_ENTRIES; i++) begin
                pos_q[i]  <= '0;    // flat
                open_q[i] <= '0;    // nothing working
            end
            rd_pos               <= '0;
            rd_open_orders       <= '0;
            force_cnt_q          <= 32'd0;
            fill_cnt_q           <= 32'd0;
            emit_cnt_q           <= 32'd0;
            sat_cnt_q            <= 32'd0;
            open_underflow_cnt_q <= 32'd0;
        end else begin
            // ── Read port ────────────────────────────────────────────────────
            if (rd_en) begin
                rd_pos         <= pos_q[rd_sym];
                rd_open_orders <= open_q[rd_sym];
            end

            // ── Emit: +1 working order ───────────────────────────────────────
            // Skipped if force targets the same symbol this cycle (the host's
            // reconciled count is authoritative and must not be perturbed), and
            // skipped on a same-symbol collision, where the fill branch below
            // applies the netted delta instead.
            if (emit_valid && !same_sym_emit_fill &&
                !(force_valid && (force_sym == emit_sym))) begin
                open_q[emit_sym] <= sat_inc_open(open_at_emit);
            end
            if (emit_valid) emit_cnt_q <= cnt_inc(emit_cnt_q);

            // ── Fill: position moves, -1 working order ───────────────────────
            if (fill_valid && !(force_valid && (force_sym == fill_sym))) begin
                pos_q[fill_sym] <= pos_next_sat;
                // sat_dec_open floors at zero. A wrap to 65535 would look like
                // 65k working orders and would jam the symbol permanently.
                // On a same-symbol emit collision the +1 and -1 net to zero.
                open_q[fill_sym] <= same_sym_emit_fill ? open_at_fill
                                                       : sat_dec_open(open_at_fill);
            end
            if (fill_valid)     fill_cnt_q           <= cnt_inc(fill_cnt_q);
            if (pos_saturated)  sat_cnt_q            <= cnt_inc(sat_cnt_q);
            if (open_underflow) open_underflow_cnt_q <= cnt_inc(open_underflow_cnt_q);

            // ── Force: host reconciliation wins over everything ──────────────
            // Written last in source order so it also wins in the (illegal but
            // possible) case of the same symbol being hit by two sources.
            if (force_valid) begin
                pos_q[force_sym]  <= force_pos;
                open_q[force_sym] <= force_open;
                force_cnt_q       <= cnt_inc(force_cnt_q);
            end
        end
    end

    assign force_cnt          = force_cnt_q;
    assign fill_cnt           = fill_cnt_q;
    assign emit_cnt           = emit_cnt_q;
    assign sat_cnt            = sat_cnt_q;
    assign open_underflow_cnt = open_underflow_cnt_q;

    // =========================================================================
    // 5. Assertions
    // =========================================================================
`ifndef SYNTHESIS
    // Reset really means flat.
    a_reset_flat: assert property (@(posedge clk)
        rst |=> (rd_pos == '0 && rd_open_orders == '0)
    ) else $error("position_track: position not flat after reset");

    // A fill must carry a nonzero quantity — a zero-qty fill is a decode bug
    // upstream and would silently do nothing here.
    a_fill_nonzero: assert property (@(posedge clk) disable iff (rst)
        fill_valid |-> (fill_qty != 32'd0)
    ) else $error("position_track: zero-quantity fill");

    // ⚠️ These two must NEVER fire in a healthy system. They are not warnings.
    a_no_saturation: assert property (@(posedge clk) disable iff (rst)
        !pos_saturated
    ) else $error("position_track: POSITION SATURATED — runaway accumulator or corrupt fill qty");

    a_no_open_underflow: assert property (@(posedge clk) disable iff (rst)
        !open_underflow
    ) else $error("position_track: fill received on a symbol with zero open orders — the open-order count has drifted, or these are not our fills");

    // The same-symbol emit+fill collision is HANDLED (§3), not merely counted.
    // This asserts the handling: the open-order count must be UNCHANGED,
    // because +1 and -1 net to zero.
    logic      coll_seen_q;
    open_cnt_t coll_prev_q;
    sym_idx_t  coll_sym_q;
    always_ff @(posedge clk) begin
        coll_seen_q <= same_sym_emit_fill && !force_valid;
        coll_prev_q <= open_at_fill;
        coll_sym_q  <= fill_sym;
    end

    a_emit_fill_collision_nets: assert property (@(posedge clk) disable iff (rst)
        coll_seen_q |-> (open_q[coll_sym_q] == coll_prev_q)
    ) else $error("position_track: same-cycle emit+fill on one symbol did not net to zero");

    // Force is a rare, deliberate act. If the host is forcing every cycle,
    // something upstream is broken and the forcing is masking it.
    a_force_is_rare: assert property (@(posedge clk) disable iff (rst)
        force_valid |=> !force_valid
    ) else $error("position_track: back-to-back force writes — reconciliation is being used to paper over a feedback failure");
`endif

endmodule : position_track

`default_nettype wire
