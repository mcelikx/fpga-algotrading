// =============================================================================
// sat_arith_pkg.sv — Saturating arithmetic for positions, notionals and counters
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/01-fpga-design/01-rtl-design-patterns.md §9
//           manuals/03-algotrading/06-risk-and-compliance.md
//           manuals/00-foundations/03-hdl-and-rtl-coding.md §7
//
// PURPOSE
//   Every piece of position, notional, exposure and counter arithmetic on the
//   fast path goes through these functions. They saturate at the type limit and
//   they RETURN A FLAG saying they did, so the caller can count the event and
//   the host can see it.
//
//   This package supersedes `trading_pkg::sat_add64` / `sat_sub64` for any new
//   code: those two return a value with no saturation flag, which makes the
//   event invisible. They remain only because the package interface contract is
//   frozen; do not add callers.
//
// LATENCY / RESOURCE
//   All functions are pure combinational. One (W+1)-bit adder plus a 2:1 mux.
//   On UltraScale+ a 64-bit saturating add is 8 CARRY8 + 64 LUT, ~1.5-2 ns.
//   Pipeline the CALLER if a chain of these lands on the critical path; there
//   is nothing to pipeline inside a function.
//   No division, no modulo, no floating point (CLAUDE.md §5.3).
//
// -----------------------------------------------------------------------------
// ⚠️  WRAPPING A POSITION COUNTER TURNS A RISK CHECK INTO A NO-OP
//   This is the single reason this package exists. Consider a 40-bit signed
//   position at +2^39-1 and a buy fill of 1000 shares. Wrapped, the new position
//   is a large NEGATIVE number. The next `pos <= max_long_pos` check passes
//   trivially, and the gate that exists to stop an unbounded long position now
//   waves through every order. The system does not fail loudly — it keeps
//   trading, faster than a human can intervene, with its principal safety check
//   silently disabled.
//
//   That is the difference between a bug and a regulatory incident
//   (manual 01.01 §9, SEC Rule 15c3-5). Therefore:
//     1. NEVER use bare `+` or `-` on a position, notional, exposure, or
//        open-order count. Use these functions.
//     2. ALWAYS wire the `saturated` flag to a counter. A saturating position is
//        not a rounding error, it is a statement that the accounting is now
//        wrong and the number you are risk-checking is a floor, not a value.
//     3. Saturation must be treated as a FAIL-CLOSED condition by the risk gate:
//        if the position arithmetic saturated, reject, do not clamp and proceed.
//
// ⚠️  SATURATION IS NOT THE SAME AS CORRECTNESS. A saturated value is a lie the
//   hardware tells you deliberately, because it is a safer lie than a wrapped
//   one. The host must reconcile and re-arm; the FPGA cannot recover on its own.
//
// ⚠️  SIZE THE TYPES SO SATURATION IS UNREACHABLE IN NORMAL OPERATION. POS_W=40
//   holds +/- 549 billion shares; NOTIONAL_W=64 holds $1.8e15 at 4 implied
//   decimals. If a saturation flag ever sets in production, something upstream
//   is already broken — treat it as an incident, not as a limit working.
// =============================================================================
`ifndef SAT_ARITH_PKG_SV
`define SAT_ARITH_PKG_SV

`default_nettype none

package sat_arith_pkg;

    import trading_pkg::*;

    // -------------------------------------------------------------------------
    // 1. Result types — value plus the flag that makes the event countable
    // -------------------------------------------------------------------------
    typedef struct packed {
        notional_t value;
        logic      saturated;
    } sat_notional_t;

    typedef struct packed {
        position_t value;
        logic      saturated;
    } sat_position_t;

    typedef struct packed {
        qty_t      value;
        logic      saturated;
    } sat_qty_t;

    typedef struct packed {
        logic [CYCLE_CNT_W-1:0] value;
        logic                   saturated;
    } sat_cnt_t;

    // -------------------------------------------------------------------------
    // 2. Type limits
    // -------------------------------------------------------------------------
    localparam notional_t NOTIONAL_MAX = {NOTIONAL_W{1'b1}};
    localparam qty_t      QTY_MAX      = {QTY_W{1'b1}};

    // Signed position bounds. POS_W bits two's complement.
    localparam position_t POS_MAX = position_t'({1'b0, {(POS_W-1){1'b1}}});
    localparam position_t POS_MIN = position_t'({1'b1, {(POS_W-1){1'b0}}});

    // -------------------------------------------------------------------------
    // 3. Unsigned notional arithmetic
    // -------------------------------------------------------------------------

    // Saturating add. One extra bit catches the carry.
    function automatic sat_notional_t sat_add_notional(input notional_t a,
                                                       input notional_t b);
        logic [NOTIONAL_W:0] s;
        sat_notional_t       r;
        s = {1'b0, a} + {1'b0, b};
        r.saturated = s[NOTIONAL_W];
        r.value     = s[NOTIONAL_W] ? NOTIONAL_MAX : s[NOTIONAL_W-1:0];
        return r;
    endfunction

    // Saturating subtract, floored at zero. `saturated` means "the subtraction
    // went below zero and was clamped" — for an exposure counter that is a
    // double-decrement, i.e. an accounting error, not a benign floor.
    function automatic sat_notional_t sat_sub_notional(input notional_t a,
                                                       input notional_t b);
        sat_notional_t r;
        r.saturated = (b > a);
        r.value     = (b > a) ? '0 : (a - b);
        return r;
    endfunction

    // price * qty -> notional. 32 x 32 = 64 bits exactly, so this CANNOT
    // overflow NOTIONAL_W=64 and `saturated` is always 0. The flag is present so
    // call sites look identical to the ones that can saturate.
    // ⚠️ Maps to a DSP48 (or a few). Pipeline the caller if it is on a critical
    //    path — the multiply is ~3 ns unregistered (manual 00.03 §7).
    // ⚠️ Scale factor: price carries 4 implied decimals (trading_pkg), so the
    //    result is notional * 10^4. Never divide it out on the fast path.
    function automatic sat_notional_t sat_mul_px_qty(input price_t px,
                                                     input qty_t   q);
        sat_notional_t r;
        // Both operands zero-extended to 64 bits; synthesis prunes the constant
        // zero halves down to a 32x32 DSP multiply. Same idiom as
        // trading_pkg::div100.
        r.value     = notional_t'(px) * notional_t'(q);
        r.saturated = 1'b0;
        return r;
    endfunction

    // -------------------------------------------------------------------------
    // 4. Unsigned quantity arithmetic (shares, open-order counts, credits)
    // -------------------------------------------------------------------------
    function automatic sat_qty_t sat_add_qty(input qty_t a, input qty_t b);
        logic [QTY_W:0] s;
        sat_qty_t       r;
        s = {1'b0, a} + {1'b0, b};
        r.saturated = s[QTY_W];
        r.value     = s[QTY_W] ? QTY_MAX : s[QTY_W-1:0];
        return r;
    endfunction

    function automatic sat_qty_t sat_sub_qty(input qty_t a, input qty_t b);
        sat_qty_t r;
        r.saturated = (b > a);
        r.value     = (b > a) ? '0 : (a - b);
        return r;
    endfunction

    // -------------------------------------------------------------------------
    // 5. Signed position arithmetic — THE ONE THAT MATTERS
    // -------------------------------------------------------------------------
    // Signed saturating add: clamps at POS_MAX / POS_MIN rather than wrapping
    // from long to short (see the header). One extra bit makes the overflow
    // visible before it is lost.
    function automatic sat_position_t sat_add_pos(input position_t a,
                                                  input position_t b);
        logic signed [POS_W:0] s;
        logic signed [POS_W:0] hi;
        logic signed [POS_W:0] lo;
        sat_position_t         r;

        s  = $signed({a[POS_W-1], a}) + $signed({b[POS_W-1], b});
        hi = $signed({POS_MAX[POS_W-1], POS_MAX});
        lo = $signed({POS_MIN[POS_W-1], POS_MIN});

        if (s > hi) begin
            r.value     = POS_MAX;
            r.saturated = 1'b1;
        end else if (s < lo) begin
            r.value     = POS_MIN;
            r.saturated = 1'b1;
        end else begin
            r.value     = position_t'(s[POS_W-1:0]);
            r.saturated = 1'b0;
        end
        return r;
    endfunction

    // Signed saturating subtract. Written directly rather than as
    // sat_add_pos(a, -b), because negating POS_MIN overflows and would
    // reintroduce exactly the bug this package exists to prevent.
    function automatic sat_position_t sat_sub_pos(input position_t a,
                                                  input position_t b);
        logic signed [POS_W:0] s;
        logic signed [POS_W:0] hi;
        logic signed [POS_W:0] lo;
        sat_position_t         r;

        s  = $signed({a[POS_W-1], a}) - $signed({b[POS_W-1], b});
        hi = $signed({POS_MAX[POS_W-1], POS_MAX});
        lo = $signed({POS_MIN[POS_W-1], POS_MIN});

        if (s > hi) begin
            r.value     = POS_MAX;
            r.saturated = 1'b1;
        end else if (s < lo) begin
            r.value     = POS_MIN;
            r.saturated = 1'b1;
        end else begin
            r.value     = position_t'(s[POS_W-1:0]);
            r.saturated = 1'b0;
        end
        return r;
    endfunction

    // Apply a fill to a position. Long is positive: a buy adds, a sell subtracts.
    // This is THE function the risk gate and the strategy use on every fill.
    // ⚠️ If `saturated` comes back set, the position is no longer trustworthy.
    //    Fail closed: assert the kill switch, do not keep quoting.
    function automatic sat_position_t sat_pos_apply_fill(input position_t pos,
                                                         input side_e     side,
                                                         input qty_t      q);
        position_t q_ext;
        q_ext = position_t'({{(POS_W-QTY_W){1'b0}}, q});   // qty is unsigned
        return (side == SIDE_BUY) ? sat_add_pos(pos, q_ext)
                                  : sat_sub_pos(pos, q_ext);
    endfunction

    // Absolute value of a position, saturating. |POS_MIN| is not representable
    // in POS_W bits, so it clamps to POS_MAX and flags — the one case where
    // taking an absolute value can itself be a saturation event.
    function automatic sat_position_t sat_abs_pos(input position_t p);
        sat_position_t r;
        if (p == POS_MIN) begin
            r.value     = POS_MAX;
            r.saturated = 1'b1;
        end else if (p[POS_W-1]) begin
            r.value     = position_t'(-p);
            r.saturated = 1'b0;
        end else begin
            r.value     = p;
            r.saturated = 1'b0;
        end
        return r;
    endfunction

    // -------------------------------------------------------------------------
    // 6. Telemetry counters
    // -------------------------------------------------------------------------
    // Saturating increment of a CYCLE_CNT_W (48-bit) event counter. 48 bits at
    // 156.25 MHz is ~20.8 days of counting every single cycle, so it cannot wrap
    // within a trading day (manual 01.01 §9). Use `counter_bank` for a bank of
    // these; this function is for one-off counters embedded in a block.
    function automatic sat_cnt_t sat_inc_cnt(input logic [CYCLE_CNT_W-1:0] c);
        sat_cnt_t r;
        if (&c) begin
            r.value     = c;                                    // hold at max
            r.saturated = 1'b1;
        end else begin
            r.value     = c + CYCLE_CNT_W'(1);
            r.saturated = 1'b0;
        end
        return r;
    endfunction

    // -------------------------------------------------------------------------
    // 7. Range checks that do NOT need arithmetic
    // -------------------------------------------------------------------------
    // "Would adding q to pos breach the long limit?" — answered WITHOUT
    // computing the sum first, so a saturating add can never mask a breach.
    // Restructured per manual 00.03 §7: never test a value you had to clamp.
    function automatic logic pos_would_breach_long(input position_t pos,
                                                   input qty_t      q,
                                                   input position_t limit);
        sat_position_t nxt;
        nxt = sat_pos_apply_fill(pos, SIDE_BUY, q);
        // Saturation counts as a breach: fail closed.
        return nxt.saturated || ($signed(nxt.value) > $signed(limit));
    endfunction

    // `limit` is a POSITIVE magnitude for the short side (see sym_risk_t).
    function automatic logic pos_would_breach_short(input position_t pos,
                                                    input qty_t      q,
                                                    input position_t limit);
        sat_position_t nxt;
        nxt = sat_pos_apply_fill(pos, SIDE_SELL, q);
        return nxt.saturated || ($signed(nxt.value) < -$signed(limit));
    endfunction

endpackage : sat_arith_pkg

`default_nettype wire

`endif
