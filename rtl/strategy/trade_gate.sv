// =============================================================================
// trade_gate.sv — "Should I even consider quoting this symbol?"
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Layer   : rtl/strategy/  (budget row S0/S1 — gating, combinational)
// Governs : manuals/04-system-architecture/04-strategy-engine-on-fpga.md
//           manuals/08-nasdaq/02-sessions-auctions-and-halts.md
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// -----------------------------------------------------------------------------
// PURPOSE
//   Evaluated BEFORE any trigger logic, on every book update. Answers exactly
//   one question: is this symbol, right now, in a state where a quote is even
//   admissible? It says nothing about whether a quote is a good idea — that is
//   trigger_logic.sv's job.
//
//   Separating the two matters operationally. When the system goes quiet, the
//   first question is always "did the strategy stop firing, or did the gate
//   stop letting it?" — and those have completely different causes and
//   completely different fixes. Keeping them in separate modules with separate
//   counters makes that question answerable from a register dump.
//
// -----------------------------------------------------------------------------
// ⚠️  FAIL-CLOSED IS THE WHOLE DESIGN
//
//   `pass` is built as a conjunction of positive assertions, never as the
//   negation of a list of known-bad conditions. The difference:
//
//     WRONG: pass = !halted && !stale && !crossed;
//            A state nobody thought of (a new venue state, an uninitialised
//            symbol, an X in simulation) passes.
//
//     RIGHT: pass = (state == TRADE_OPEN) && params_valid && ... ;
//            A state nobody thought of fails. Silence is the safe failure.
//
//   Concretely: the per-symbol state must EQUAL TRADE_OPEN. HALTED, PAUSED,
//   AUCTION, STALE, CLOSED, PREOPEN and DISABLED all reject, and so would a
//   ninth value if trade_state_e ever grew one. Reset rejects. An unrecognised
//   strat_select rejects on GATE_UNKNOWN.
//
// -----------------------------------------------------------------------------
// SCOPE NOTE — THIS IS NOT THE RISK GATE
//
//   This is a STRATEGY-side admission check. The non-bypassable pre-trade risk
//   controls (SEC Rule 15c3-5: collars, LULD bands, SSR, position and notional
//   limits, kill switch) live in rtl/risk/risk_gate.sv, which every order
//   passes through afterwards. Nothing here may be relied on for compliance;
//   everything here exists to stop the strategy wasting risk-gate bandwidth and
//   order-to-trade ratio on quotes that were never going to be sensible.
//
//   In particular the per-symbol venue state seen here is ADVISORY. The
//   authoritative halt/LULD/SSR side-channel from feed_handler is wired to
//   risk_gate, not to strategy_engine (see fpga_top.sv). The copy this gate
//   consumes is host-mirrored at millisecond cadence, so it can lag a halt by
//   milliseconds. That lag is covered by two things: s_top.stale, which is
//   real-time, and the risk gate, which is authoritative. Defence in depth.
//
// -----------------------------------------------------------------------------
// LATENCY
//   0 cycles. `pass` and `reason` are COMBINATIONAL — a documented exception to
//   the registered-outputs rule (03-hdl-and-rtl-coding.md §5). Justification:
//   the gate result must be ANDed with the trigger result inside the same cycle
//   (budget row S1) to hold the 2-cycle strategy budget. Registering it would
//   add a third cycle to a 20-cycle fabric envelope that has none to give.
//   All inputs arrive from flip-flops and the output is consumed by a flip-flop
//   in the same module, so the path is locally analysable.
//
//   Logic depth: one 32-bit compare (min_book_qty, ~2 LUT levels via carry
//   chain) feeding a ~10-term AND. ~3 LUT levels, well inside 6.4 ns.
//
//   The counters ARE registered.
//
// RESOURCE (estimate, N_GATE_REASONS=11, UltraScale+)
//   LUT : compare + priority chain + reason encode   ~  90
//   FF  : 11 x 32-bit counters                       ~ 352
//   DSP : 0     BRAM : 0
// =============================================================================
`default_nettype none

module trade_gate
    import trading_pkg::*;
    import strategy_pkg::*;
(
    input  var logic         clk,
    input  var logic         rst,          // synchronous, active high

    // ── Evaluation input (all registered upstream, stage S1) ─────────────────
    input  var logic         s_valid,      // a book update is being evaluated
    // The gate reads only the integrity and depth fields of book_top_t
    // (bid/ask px+qty+valid, crossed, stale) and only min_book_qty,
    // strat_enabled and strat_select of sym_strat_t. The rest of both structs
    // is the trigger's business, not the gate's — passing whole structs keeps
    // the port list stable when either grows.
    /* verilator lint_off UNUSEDSIGNAL */
    input  var book_top_t    s_top,
    input  var sym_strat_t   params,
    /* verilator lint_on UNUSEDSIGNAL */
    input  var trade_state_e sess_state,   // global session state (ITCH 'S')
    input  var trade_state_e sym_state,    // per-symbol state, host-mirrored
    input  var logic         params_valid, // from param_table

    // ── Verdict (COMBINATIONAL — see LATENCY above) ──────────────────────────
    output var logic         pass,
    output var gate_reason_e reason,

    // ── Telemetry: rejections BY REASON. index 0 = passes. ───────────────────
    output var logic [31:0]  reject_cnt [N_GATE_REASONS]
);

    // =========================================================================
    // 1. Individual admission conditions
    // =========================================================================
    // Each is a positive statement of something that must be TRUE. Named
    // separately so the reason encoder below is a plain priority chain and so
    // each condition is individually probeable in an ILA.
    logic cond_not_reset;
    logic cond_sess_open;
    logic cond_sym_open;
    logic cond_params_valid;
    logic cond_strat_enabled;
    logic cond_book_fresh;
    logic cond_book_uncrossed;
    logic cond_sides_valid;
    logic cond_depth_ok;
    logic cond_strat_known;

    // rst is an explicit input to the verdict, not just a reset on the
    // counters. During reset the gate rejects: CLAUDE.md §5 rule 4.
    assign cond_not_reset      = !rst;

    // EQUALITY, not inequality. See the fail-closed note in the header.
    assign cond_sess_open      = (sess_state == TRADE_OPEN);
    assign cond_sym_open       = (sym_state  == TRADE_OPEN);

    // The host must have written a COMPLETE parameter record for this symbol in
    // the live generation. A symbol whose parameters were never loaded does not
    // trade — it does not trade on zeros, and it does not trade on whatever the
    // RAM powered up holding.
    assign cond_params_valid   = params_valid;
    assign cond_strat_enabled  = params.strat_enabled;

    // Real-time book integrity, straight from the book engine.
    assign cond_book_fresh     = !s_top.stale;      // no sequence gap
    assign cond_book_uncrossed = !s_top.crossed;    // bid < ask

    // Both sides present AND both prices non-zero. A "valid" side at price zero
    // is a decoder or book bug; quoting against it would produce an order at
    // $0.0000 or, worse, make every take-trigger true.
    assign cond_sides_valid    = s_top.bid_valid && s_top.ask_valid &&
                                 (s_top.bid_px != 32'd0) &&
                                 (s_top.ask_px != 32'd0);

    // Don't act on a thin book. Both sides must carry min_book_qty: a strategy
    // that quotes the bid still needs a real offer on the other side, because
    // the offer is what its own quote will eventually trade against.
    assign cond_depth_ok       = (s_top.bid_qty >= params.min_book_qty) &&
                                 (s_top.ask_qty >= params.min_book_qty);

    // The catch-all. trade_state_e is 3 bits and fully populated, so an
    // unrecognised STATE is not representable — but strat_select is 4 bits with
    // 4 legal values, so 12 of 16 encodings are illegal. param_table rejects
    // them at write time; this is the second line of defence in case a record
    // reaches the fast path some other way.
    assign cond_strat_known    = strat_sel_legal(params.strat_select);

    // =========================================================================
    // 2. Verdict and reason attribution
    // =========================================================================
    // A priority chain, not a case: the first failing condition names the
    // reason. Order is chosen so the reason a human would give FIRST wins —
    // "the market is closed" beats "the book is thin", because during a closed
    // market the book is also thin and reporting the thin book would send the
    // operator chasing the wrong thing.
    always_comb begin
        // Defaults first — no latches (03-hdl-and-rtl-coding.md §3).
        pass   = 1'b0;
        reason = GATE_UNKNOWN;

        if      (!cond_not_reset)      reason = GATE_IN_RESET;
        else if (!cond_sess_open)      reason = GATE_SESS_NOT_OPEN;
        else if (!cond_sym_open)       reason = GATE_SYM_NOT_OPEN;
        else if (!cond_params_valid)   reason = GATE_PARAMS_INVALID;
        else if (!cond_strat_enabled)  reason = GATE_STRAT_DISABLED;
        else if (!cond_strat_known)    reason = GATE_UNKNOWN;
        else if (!cond_book_fresh)     reason = GATE_BOOK_STALE;
        else if (!cond_book_uncrossed) reason = GATE_BOOK_CROSSED;
        else if (!cond_sides_valid)    reason = GATE_SIDE_INVALID;
        else if (!cond_depth_ok)       reason = GATE_THIN_BOOK;
        else begin
            pass   = 1'b1;
            reason = GATE_OK;
        end
    end

    // =========================================================================
    // 3. Rejection counters — one per reason
    // =========================================================================
    // ⚠️ "The strategy stopped quoting" is not a diagnosis. This array turns it
    // into one. Index 0 counts PASSES, so the array is a complete histogram of
    // every evaluation the gate ever made and the totals must reconcile:
    //     sum(reject_cnt[0..N-1]) == number of s_valid pulses   (modulo
    //     saturation of individual entries).
    //
    // Counters saturate rather than wrap: a host polling once a second must
    // never mistake a wrap for "the problem went away".
    logic [31:0] cnt_q [N_GATE_REASONS];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned i = 0; i < N_GATE_REASONS; i++) begin
                cnt_q[i] <= 32'd0;
            end
        end else if (s_valid) begin
            cnt_q[reason] <= cnt_inc(cnt_q[reason]);
        end
    end

    always_comb begin
        for (int unsigned i = 0; i < N_GATE_REASONS; i++) begin
            reject_cnt[i] = cnt_q[i];
        end
    end

    // =========================================================================
    // 4. Assertions
    // =========================================================================
`ifndef SYNTHESIS
    // The conjunction really is a conjunction: pass implies EVERY condition.
    a_pass_implies_all: assert property (@(posedge clk)
        pass |-> (cond_not_reset && cond_sess_open && cond_sym_open &&
                  cond_params_valid && cond_strat_enabled && cond_strat_known &&
                  cond_book_fresh && cond_book_uncrossed &&
                  cond_sides_valid && cond_depth_ok)
    ) else $error("trade_gate: pass asserted with a failing condition");

    // ...and the reason is exactly consistent with the verdict.
    a_reason_matches_pass: assert property (@(posedge clk)
        (reason == GATE_OK) == pass
    ) else $error("trade_gate: reason/pass disagree — rejections are not attributable");

    // Reset rejects. Unconditionally, with no disable iff.
    a_reset_rejects: assert property (@(posedge clk)
        rst |-> !pass
    ) else $error("trade_gate: passed during reset");

    // The named hazards, stated individually so a failure points at the cause.
    a_no_pass_when_closed: assert property (@(posedge clk) disable iff (rst)
        (sess_state != TRADE_OPEN) |-> !pass
    ) else $error("trade_gate: passed outside TRADE_OPEN session");

    a_no_pass_when_sym_shut: assert property (@(posedge clk) disable iff (rst)
        (sym_state != TRADE_OPEN) |-> !pass
    ) else $error("trade_gate: passed on a symbol that is not TRADE_OPEN");

    a_no_pass_on_crossed: assert property (@(posedge clk) disable iff (rst)
        s_top.crossed |-> !pass
    ) else $error("trade_gate: passed on a crossed book");

    a_no_pass_on_stale: assert property (@(posedge clk) disable iff (rst)
        s_top.stale |-> !pass
    ) else $error("trade_gate: passed on a stale book");

    a_no_pass_unloaded: assert property (@(posedge clk) disable iff (rst)
        !params_valid |-> !pass
    ) else $error("trade_gate: passed a symbol whose parameters were never loaded");

    // GATE_UNKNOWN must never fire in a correct system. If it does, either the
    // parameter path let an illegal strat_select through or a state encoding
    // changed without this gate being updated. Treat any hit as a build bug.
    a_unknown_never_fires: assert property (@(posedge clk) disable iff (rst)
        s_valid |-> (reason != GATE_UNKNOWN)
    ) else $error("trade_gate: GATE_UNKNOWN — an unrecognised state reached the gate");
`endif

endmodule : trade_gate

`default_nettype wire
