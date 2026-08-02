// =============================================================================
// order_token_gen.sv — OUCH order token generator (monotonic, session-unique)
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Layer   : rtl/risk — pre-trade risk / SEC Rule 15c3-5 control block
// Governs : manuals/08-nasdaq/09-risk-controls-and-limits.md §6, §9
//           manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md §7
//           manuals/08-nasdaq/05-ouch-5.0-order-entry.md
//           rtl/pkg/trading_pkg.sv  (order_token_t is the contract)
//
// -----------------------------------------------------------------------------
// PURPOSE
//   Produce the `order_token_t` that is spliced into every outbound OUCH order.
//
//   THE TOKEN IS THE ONLY LINK between an order the FPGA emitted and the host's
//   accounting, its audit trail, and its CAT reporting. If two live orders ever
//   carry the same token the host cannot tell them apart, cannot attribute a
//   fill, and cannot reconcile its position. That is a reportable incident, not
//   a bug. Hence: monotonic, never reused, never wrapped, asserted.
//
//   Layout (trading_pkg::order_token_t, 112 bits):
//       [111:96] magic    — host-written per session; host REJECTS a mismatch
//       [ 95:92] strat_id — which strategy primitive fired
//       [ 91:80] sym      — active-set index, zero-extended (self-describing:
//                           an ack/fill is attributable with zero lookups)
//       [ 79:32] counter  — monotonic, never reused within a session
//       [ 31: 0] rsvd     — TIED ZERO. The host must reject a non-zero rsvd;
//                           it is a free integrity check on the whole token.
//
// -----------------------------------------------------------------------------
// LATENCY
//   `token` is COMBINATIONAL — 0 cycles. This is a deliberate, justified
//   exception to the registered-output rule (manuals/00-foundations/
//   03-hdl-and-rtl-coding.md §5): the token must be present in the same cycle
//   the risk verdict registers into `order_out_t`, because the whole gate has a
//   2-cycle budget (fpga_top.sv latency table, "Pre-trade risk gate  2  12.8").
//   Registering it would cost a third cycle and change the system budget.
//   The token is a pure concatenation of registers — 0 logic levels, no LUTs on
//   the path, so it costs nothing in Fmax terms.
//
//   `issue` is sampled on the same edge that registers the order out.
//
// -----------------------------------------------------------------------------
// RESOURCE (estimate, pre-synthesis, VU9P-class)
//   LUT ~90   FF ~150   BRAM 0   DSP 0
//   (48-bit counter + 32-bit issued counter + 16-bit magic + control FFs)
//
// -----------------------------------------------------------------------------
// REGULATORY OBLIGATIONS IMPLEMENTED
//   * SEC Rule 15c3-5(b)/(c)  — order attribution and post-trade reconciliation
//                               depend on a unique, non-reused client order ID.
//   * SEC Rule 613 (CAT)      — every order event must be reportable and
//                               linkable; the token is the linkage key.
//   * FINRA/venue books-and-records — an unattributable order is an
//                               unreconcilable order.
//
// -----------------------------------------------------------------------------
// ⚠️ COUNTER EXHAUSTION — WHAT HAPPENS (required by the task spec)
//   The counter is 48 bits and starts at 1 (0 is reserved as "no token").
//   Worst case issue rate is one order per core clock = 156.25 Mtoken/s, so
//   2^48 - 1 tokens last 2^48 / 156.25e6 s ≈ 1.8e6 s ≈ 20.8 days of *continuous
//   back-to-back issuance*. It cannot be reached in a trading session.
//
//   It is still handled, because "unreachable" is an assumption and this counter
//   is the thing that tells you the assumption was wrong:
//     * At COUNTER_MAX - NEAR_EXHAUST_MARGIN, `near_exhaust` asserts (sticky).
//       Telemetry alarms; the host is expected to end the session cleanly.
//     * At COUNTER_MAX, `exhausted` asserts (sticky) and `token_ready` DROPS.
//       ⚠️ THE COUNTER NEVER WRAPS. The increment is guarded. risk_gate turns
//       !token_ready into RISK_PARAM_INVALID and raises KILL_SEQ_FAULT — i.e.
//       the design STOPS TRADING. It does not wrap, it does not reuse, it does
//       not "roll to a new epoch" on its own. Recovery is an explicit host
//       session restart (new `magic`, `session_start`), which is only accepted
//       while the kill switch is asserted.
//
// ⚠️ MAGIC — the session tag.
//   `magic` is host-written per session and must change on every session
//   establishment (including reconnects). A late ack for a pre-reconnect order
//   therefore cannot alias onto a live order. `magic_valid` resets to 0 and is
//   cleared by `session_start`: no magic, no tokens, no orders. Fail-closed.
//   Writing magic == 0 is rejected (0 is reserved as "unprogrammed").
// =============================================================================
`default_nettype none

module order_token_gen
    import trading_pkg::*;
#(
    // Sticky warning margin before hard exhaustion.
    parameter logic [47:0] NEAR_EXHAUST_MARGIN = 48'd1_000_000
) (
    input  var logic         clk,
    input  var logic         rst,              // synchronous, active high

    // ── Host session control (slow path) ─────────────────────────────────────
    input  var logic         magic_wr,         // pulse: write `magic_in`
    input  var logic [15:0]  magic_in,
    input  var logic         session_start,    // pulse: begin a new session
                                               // (counter -> 1, magic invalidated)

    // ── Issue port (fast path) ───────────────────────────────────────────────
    input  var logic         issue,            // pulse: this token is being used
    input  var logic [3:0]   strat_id,
    input  var sym_idx_t     sym,

    // ── Token out (COMBINATIONAL — see LATENCY note above) ───────────────────
    output var token_t       token,
    output var logic         token_ready,      // 0 => risk_gate must reject

    // ── Telemetry / status (registered) ──────────────────────────────────────
    output var logic [15:0]  magic_q,
    output var logic         magic_valid,
    output var logic [47:0]  counter,          // next counter value to be issued
    output var logic         near_exhaust,     // sticky
    output var logic         exhausted,        // sticky
    output var logic [31:0]  issued_cnt        // saturating
);

    // -------------------------------------------------------------------------
    // Local constants
    // -------------------------------------------------------------------------
    localparam int unsigned  COUNTER_W   = 48;
    localparam logic [47:0]  COUNTER_MAX = 48'hFFFF_FFFF_FFFF;
    localparam logic [47:0]  COUNTER_MIN = 48'd1;          // 0 == "no token"
    localparam logic [47:0]  NEAR_THRESH = COUNTER_MAX - NEAR_EXHAUST_MARGIN;
    localparam logic [31:0]  CNT32_MAX   = 32'hFFFF_FFFF;

    // -------------------------------------------------------------------------
    // Session magic. Reset value 0 / invalid => no orders can be tokenised.
    // -------------------------------------------------------------------------
    logic [15:0] magic_r;
    logic        magic_vld_r;

    always_ff @(posedge clk) begin
        if (rst) begin
            magic_r     <= 16'd0;
            magic_vld_r <= 1'b0;
        end else if (session_start) begin
            // A new session invalidates the old magic. The host MUST write a new
            // one. This is what stops a reconnect from reusing the old tag.
            magic_r     <= 16'd0;
            magic_vld_r <= 1'b0;
        end else if (magic_wr) begin
            magic_r     <= magic_in;
            // magic == 0 is reserved for "unprogrammed" and is never accepted.
            magic_vld_r <= (magic_in != 16'd0);
        end else begin
            magic_r     <= magic_r;
            magic_vld_r <= magic_vld_r;
        end
    end

    // -------------------------------------------------------------------------
    // Monotonic counter. NEVER WRAPS — the increment is guarded by `exhausted`.
    // -------------------------------------------------------------------------
    logic [47:0] counter_r;
    logic        exhausted_r;
    logic        near_r;
    logic [31:0] issued_r;

    logic can_issue;
    assign can_issue = magic_vld_r && !exhausted_r;

    always_ff @(posedge clk) begin
        if (rst) begin
            counter_r   <= COUNTER_MIN;
            exhausted_r <= 1'b0;
            near_r      <= 1'b0;
            issued_r    <= 32'd0;
        end else if (session_start) begin
            // Explicit host session restart. This is the ONLY way to move the
            // counter backwards, it clears the exhaustion latches, and the host
            // control plane only permits it while the kill switch is asserted
            // (enforced in risk_gate).
            counter_r   <= COUNTER_MIN;
            exhausted_r <= 1'b0;
            near_r      <= 1'b0;
            issued_r    <= issued_r;      // lifetime counter, not per session
        end else begin
            if (issue && can_issue) begin
                if (counter_r >= COUNTER_MAX) begin
                    // Guarded: hold at max, latch exhausted, never wrap.
                    counter_r   <= COUNTER_MAX;
                    exhausted_r <= 1'b1;
                end else begin
                    counter_r <= counter_r + 48'd1;
                    // Latch exhaustion one issue EARLY so the last usable token
                    // is COUNTER_MAX-1 and COUNTER_MAX itself is never issued
                    // twice under any race.
                    if ((counter_r + 48'd1) >= COUNTER_MAX) exhausted_r <= 1'b1;
                    else                                    exhausted_r <= exhausted_r;
                end
                issued_r <= (issued_r == CNT32_MAX) ? CNT32_MAX : issued_r + 32'd1;
            end else begin
                counter_r   <= counter_r;
                exhausted_r <= exhausted_r;
                issued_r    <= issued_r;
            end
            // Sticky near-exhaustion warning.
            near_r <= near_r || (counter_r >= NEAR_THRESH);
        end
    end

    // -------------------------------------------------------------------------
    // Token assembly — pure concatenation of registers. 0 logic levels.
    // -------------------------------------------------------------------------
    order_token_t tk;

    always_comb begin
        tk          = '0;                       // default assignment: no latches
        tk.magic    = magic_r;
        tk.strat_id = strat_id;
        tk.sym      = 12'(sym);                 // zero-extended active-set index
        tk.counter  = counter_r;
        tk.rsvd     = 32'd0;                    // TIED ZERO — host integrity check
    end

    assign token       = token_t'(tk);
    assign token_ready = can_issue;

    // -------------------------------------------------------------------------
    // Registered status outputs
    // -------------------------------------------------------------------------
    assign magic_q      = magic_r;
    assign magic_valid  = magic_vld_r;
    assign counter      = counter_r;
    assign exhausted    = exhausted_r;
    assign near_exhaust = near_r;
    assign issued_cnt   = issued_r;

    // =========================================================================
    // Assertions — simulation only
    // =========================================================================
`ifndef SYNTHESIS
    // The package contract: the struct really is TOKEN_W wide and the counter
    // field really is 48 bits. A silent change to trading_pkg must break here.
    initial begin
        if ($bits(order_token_t) != TOKEN_W)
            $error("order_token_t width %0d != TOKEN_W %0d",
                   $bits(order_token_t), TOKEN_W);
        if ($bits(tk.counter) != COUNTER_W)
            $error("token counter field is not %0d bits", COUNTER_W);
    end

    // ⚠️ THE central property: MONOTONICITY. The counter strictly increases on
    // every issue and never decreases except on an explicit session restart.
    assert property (@(posedge clk) disable iff (rst)
        (issue && can_issue && !session_start && (counter_r < COUNTER_MAX))
        |=> (counter_r == $past(counter_r) + 48'd1)
    ) else $error("FATAL: token counter did not advance monotonically on issue");

    assert property (@(posedge clk) disable iff (rst)
        (!session_start) |=> (counter_r >= $past(counter_r))
    ) else $error("FATAL: token counter moved BACKWARDS without session_start");

    // ⚠️ NEVER WRAPS. The counter may reach COUNTER_MAX and stop; it may never
    // roll through zero.
    assert property (@(posedge clk) disable iff (rst)
        (!session_start && $past(counter_r) == COUNTER_MAX)
        |-> (counter_r == COUNTER_MAX)
    ) else $error("FATAL: token counter WRAPPED — live orders can now alias");

    assert property (@(posedge clk) disable iff (rst)
        counter_r != 48'd0
    ) else $error("FATAL: token counter is zero (0 is reserved for 'no token')");

    // No token without a programmed session magic.
    assert property (@(posedge clk) disable iff (rst)
        token_ready |-> (magic_vld_r && magic_r != 16'd0)
    ) else $error("token_ready asserted without a valid session magic");

    // Exhaustion is sticky and blocks issuance.
    assert property (@(posedge clk) disable iff (rst)
        exhausted_r |-> !token_ready
    ) else $error("FATAL: token issued after exhaustion");

    assert property (@(posedge clk) disable iff (rst)
        (exhausted_r && !session_start) |=> exhausted_r
    ) else $error("exhausted latch cleared without a session restart");

    // rsvd must be zero on the wire — the host uses this as an integrity check.
    assert property (@(posedge clk) disable iff (rst)
        token[31:0] == 32'd0
    ) else $error("token rsvd field is non-zero");

    // Reset => nothing issuable.
    assert property (@(posedge clk) rst |=> !token_ready)
        else $error("token_ready survived reset (fail-closed violated)");

    // ⚠️ REQUIRED COVERAGE — see rtl/risk/README.md test matrix.
    // A check that has never been observed to fire is a check you cannot trust.
    c_issue        : cover property (@(posedge clk) disable iff (rst) issue && can_issue);
    c_no_magic     : cover property (@(posedge clk) disable iff (rst) issue && !magic_vld_r);
    c_near_exhaust : cover property (@(posedge clk) disable iff (rst) $rose(near_r));
    c_exhausted    : cover property (@(posedge clk) disable iff (rst) $rose(exhausted_r));
    c_session_new  : cover property (@(posedge clk) disable iff (rst) session_start);
`endif

endmodule : order_token_gen

`default_nettype wire
