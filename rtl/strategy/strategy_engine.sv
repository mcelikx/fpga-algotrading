// =============================================================================
// strategy_engine.sv — Strategy layer top level (instantiated by fpga_top.sv)
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Device  : AMD/Xilinx UltraScale+ (inside the single fast-path SLR pblock)
// Layer   : rtl/strategy/  (budget rows S0..S1)
// Governs : manuals/04-system-architecture/04-strategy-engine-on-fpga.md
//           manuals/04-system-architecture/01-tick-to-trade-pipeline.md
//           manuals/03-algotrading/05-strategy-taxonomy.md
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// -----------------------------------------------------------------------------
// CORE ARCHITECTURAL PRINCIPLE
//
//   The FPGA is a TRIGGER EVALUATOR OVER A PARAMETER TABLE, not a general
//   compute engine.
//
//   The host computes the slow signals — fair value, imbalance thresholds,
//   quote sizes, edges, which symbols are enabled — at millisecond cadence and
//   writes them into param_table. The FPGA evaluates a FIXED comparator and
//   threshold expression over those parameters at nanosecond cadence and emits
//   a request if it is true. That is the entire contract.
//
//   Consequences that are load-bearing for every line below:
//     * There is not one trading constant in this RTL. Every number the
//       decision depends on came through the parameter table.
//     * NO TRADING DECISION MAY REQUIRE A HOST ROUND TRIP. If the FPGA cannot
//       decide, the correct action is to do nothing — never to ask.
//     * No division, no modulo, no floating point (CLAUDE.md §5). Where a
//       strategy conceptually needs a ratio, the host precomputes the threshold
//       and the fabric cross-multiplies. See trigger_logic.sv §5.
//     * Anything requiring real computation belongs on the host. If a feature
//       request cannot be expressed as "when X becomes true on the wire, do Y",
//       it does not belong in this module.
//
// -----------------------------------------------------------------------------
// LATENCY — 2 CYCLES, 12.8 ns @ 156.25 MHz (6.4 ns/cycle). FIXED. NO JITTER.
//
//   This is the "Strategy parameter read + trigger  2 cyc  12.8 ns" row of the
//   fpga_top.sv budget table (cum 186.0 ns of the ~321 ns wire-to-wire target).
//   The layer owns exactly 2 of the 20 fabric cycles and may not exceed them.
//
//   cycle  stage  what happens                                       registers
//   -----  -----  -------------------------------------------------  ---------
//     N     S0    s_top_valid arrives. s_top.sym drives the          s0_* regs
//                 param_table and position_track read addresses;
//                 the per-symbol state array is indexed. The whole
//                 book_top_t is captured.
//    N+1    S1    Parameters, position, open-order count and symbol  m_req,
//                 state are all valid. trade_gate (combinational)    m_req_valid
//                 and trigger_logic (combinational) evaluate in
//                 parallel; the output sanity check runs; the
//                 result is registered into m_req.
//    N+2          m_req_valid is asserted to the risk gate.
//
//   Fully pipelined, II = 1: back-to-back book updates produce back-to-back
//   requests. There is no stall path, no backpressure, and no variable-latency
//   stage. A book update that produces no order simply leaves m_req_valid low
//   two cycles later — the pipeline still advances.
//
//   s_top.rx_cycle is carried through UNCHANGED into m_req.rx_cycle. It is the
//   single time reference for end-to-end latency measurement (telemetry samples
//   it at order_out) and must never be regenerated, re-stamped, or defaulted.
//
// -----------------------------------------------------------------------------
// stat[16] MAP  (read by u_telemetry as strat_stat; see fpga_top.sv)
//
//   All counters SATURATE at 32'hFFFF_FFFF rather than wrapping, so a host
//   polling at 1 Hz can never mistake a wrap for "the problem stopped".
//
//   idx  contents
//   ---  ---------------------------------------------------------------------
//    0   book_top updates presented to the engine (s_top_valid pulses)
//    1   gate PASSES
//    2   gate REJECTS, total  (0 + 2 must reconcile with 0 above)
//    3   triggers FIRED (gate passed and a primitive returned an action)
//    4   order requests EMITTED (m_req_valid pulses)
//    5   emits SUPPRESSED by the output sanity check (zero qty, zero price,
//        or a quote_qty above the hardware ceiling). ⚠️ Nonzero means a
//        primitive produced something degenerate — investigate, do not tune.
//    6   gate reject: session not TRADE_OPEN
//    7   gate reject: symbol not TRADE_OPEN (halt / pause / auction / closed)
//    8   gate reject: params_valid == 0 (never loaded this generation)
//    9   gate reject: strat_enabled == 0
//   10   gate reject: book stale (sequence gap)
//   11   gate reject: book crossed OR one-sided/zero-priced
//   12   gate reject: thin book (below min_book_qty)
//   13   parameter table: {commit_err_cnt[15:0], generation[15:0]}
//        ⚠️ generation is the AUDIT TRAIL — it identifies which parameter set
//        was live. commit_err nonzero means a commit was refused; the OLD
//        parameters are still live and the host's new set never went in.
//   14   {GATE_UNKNOWN count [31:20], last gate reject reason [19:16],
//         host bad-address writes [15:0]}
//        ⚠️ [31:20] and [15:0] MUST BE ZERO. Either one means something reached
//        this layer in a state it does not recognise. [19:16] is the most
//        recent gate_reason_e — it answers "why is this symbol quiet right now"
//        in one poll instead of two.
//   15   position force-corrections applied by the host
//        ⚠️ Nonzero AND GROWING means the FPGA's position estimate and the
//        host's reconciled position disagree repeatedly — i.e. fill feedback
//        is being lost upstream. See position_track.sv.
//
//   The FULL per-reason gate histogram (all N_GATE_REASONS entries, including
//   GATE_IN_RESET) exists on u_gate.reject_cnt. Only the seven operationally
//   interesting reasons fit in stat[16]; wire the rest into telemetry when the
//   register map grows.
//
// -----------------------------------------------------------------------------
// HOST PARAMETER WINDOW (cfg_param_*) — address map decoded in §3
//   3'b000 PARAM    addr[10:3]=sym  addr[2:0]=word(0..5)
//   3'b001 SYMSTATE addr[7:0]=sym   data[2:0]=trade_state_e
//   3'b010 POSFORCE addr[7:0]=sym   addr[8]=word (1 applies the correction)
//   The write/verify/commit sequence the host MUST follow is in README.md §4.
//
// -----------------------------------------------------------------------------
// RESOURCE BUDGET (estimate, N_ACTIVE=256, UltraScale+)
//   LUT  ~ 7,000    (position_track read mux ~4.8k dominates)
//   FF   ~18,700    (position_track ~14.5k, param_table ~3.5k)
//   BRAM      6     (param_table, 6 x RAMB18)
//   URAM      0
//   DSP       2     (the two imbalance cross-multiplies)
//   Against the fpga_top.sv fast-path budget (LUT<60k FF<90k BRAM<300 DSP<16)
//   this layer is ~12% LUT, ~21% FF, 2% BRAM, 12.5% DSP.
// =============================================================================
`default_nettype none

module strategy_engine
    import trading_pkg::*;
    import strategy_pkg::*;
#(
    parameter int unsigned N_ENTRIES          = N_ACTIVE,
    parameter int unsigned IDX_W              = ACT_IDX_W,
    // ⚠️ Reg SHO conservatism — see trigger_logic.sv §6. Compliance-relevant.
    parameter bit          CONSERVATIVE_SHORT = 1'b1,
    // Hardware ceiling on any single order. The host cannot raise it.
    parameter qty_t        HARD_MAX_QTY       = HARD_MAX_QUOTE_QTY
) (
    input  var logic         clk,
    input  var logic         rst,            // synchronous, active high

    // ── Book engine -> strategy ──────────────────────────────────────────────
    input  var book_top_t    s_top,
    input  var logic         s_top_valid,

    // ── Gating: only quote when the venue and our own state permit it ────────
    input  var trade_state_e sess_state,     // global session state (ITCH 'S')

    // ── Strategy -> pre-trade risk gate ──────────────────────────────────────
    output var order_req_t   m_req,
    output var logic         m_req_valid,

    // ── Host parameter window (double-buffered, commit-bit protected) ────────
    input  var logic         cfg_param_wr,
    // addr[12:11] are RESERVED — the region field is 3 bits so the map can grow
    // without disturbing the parameter region the host writes hottest. Decoding
    // them today would freeze that headroom. See strategy_pkg.sv §4.
    /* verilator lint_off UNUSEDSIGNAL */
    input  var logic [15:0]  cfg_param_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  var logic [31:0]  cfg_param_data,
    input  var logic         cfg_commit,

    // ── Fill feedback closes the position loop ───────────────────────────────
    input  var logic         fill_valid,
    input  var sym_idx_t     fill_sym,
    input  var side_e        fill_side,
    input  var qty_t         fill_qty,

    // ── Telemetry ────────────────────────────────────────────────────────────
    output var logic [31:0]  stat [16]
);

    // =========================================================================
    // 1. Stage S0 — capture the book update, launch the table reads
    // =========================================================================
    // The reads are launched COMBINATIONALLY from s_top so their registered
    // results land in S1 with no extra cycle. This is the only place in the
    // layer where an input port feeds logic before a flip-flop, and it feeds
    // nothing but RAM address pins and an array index.
    book_top_t    s0_top;
    logic         s0_valid;
    trade_state_e s0_sym_state;

    // Per-symbol trading state, host-mirrored.
    //
    // ⚠️ ADVISORY, NOT AUTHORITATIVE. The venue-sourced halt/LULD/SSR
    // side-channel out of feed_handler is wired to risk_gate.sv, not here (see
    // fpga_top.sv) — the risk gate is the non-bypassable enforcement point and
    // it sees halts in real time. This copy is written by the host over the
    // config window at millisecond cadence, so it can lag a halt. Two things
    // cover that lag: s_top.stale, which is real-time and gates here, and the
    // risk gate, which is authoritative and cannot be bypassed. Defence in
    // depth — this array exists so the strategy stops WASTING risk-gate
    // bandwidth and order-to-trade ratio on a halted name, not to enforce the
    // halt.
    //
    // RESET VALUE IS TRADE_DISABLED for every symbol. Nothing trades until the
    // host explicitly says a symbol is open. Fail-closed (CLAUDE.md §5 rule 4).
    trade_state_e sym_state_q [N_ENTRIES];

    always_ff @(posedge clk) begin
        if (rst) begin
            s0_valid     <= 1'b0;
            s0_sym_state <= TRADE_DISABLED;
        end else begin
            s0_valid <= s_top_valid;
            if (s_top_valid) begin
                s0_top       <= s_top;               // datapath: no reset
                s0_sym_state <= sym_state_q[s_top.sym];
            end
        end
    end

    // =========================================================================
    // 2. Parameter table — atomic double-buffered, commit-bit protected
    // =========================================================================
    sym_strat_t s1_params;
    logic       s1_params_valid;
    logic       s1_param_rd_valid;
    logic [15:0] param_generation;
    logic        param_active_bank;
    logic [31:0] param_word_wr_cnt, param_field_err_cnt;
    // Only the low 16 bits reach stat[13] / the generation assertion: generation
    // is 16 bits, so anything above 65,535 commits in a session has already
    // wrapped the thing these are compared against. The counters stay 32-bit so
    // they match every other telemetry counter's shape.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] param_commit_ok_cnt, param_commit_err_cnt;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        param_commit_err_sticky;

    // Decoded host writes (see §3).
    logic                    pt_wr;
    logic [IDX_W-1:0]        pt_sym;
    logic [PARAM_WORD_W-1:0] pt_word;

    param_table #(
        .N_ENTRIES    (N_ENTRIES),
        .IDX_W        (IDX_W),
        .HARD_MAX_QTY (HARD_MAX_QTY)
    ) u_params (
        .clk               (clk),
        .rst               (rst),
        // Fast path read — launched in S0, valid in S1
        .rd_en             (s_top_valid),
        .rd_sym            (s_top.sym),
        .rd_param          (s1_params),
        .rd_params_valid   (s1_params_valid),
        .rd_valid          (s1_param_rd_valid),
        // Host window
        .cfg_wr            (pt_wr),
        .cfg_sym           (pt_sym),
        .cfg_word          (pt_word),
        .cfg_data          (cfg_param_data),
        .cfg_commit        (cfg_commit),
        // Readback / audit trail
        .generation        (param_generation),
        .active_bank       (param_active_bank),
        .word_wr_cnt       (param_word_wr_cnt),
        .field_err_cnt     (param_field_err_cnt),
        .commit_ok_cnt     (param_commit_ok_cnt),
        .commit_err_cnt    (param_commit_err_cnt),
        .commit_err_sticky (param_commit_err_sticky)
    );

    // =========================================================================
    // 3. Host config window decode
    // =========================================================================
    // The window is on core_clk — host_ctrl.sv owns every CDC. Nothing here is
    // latency-critical; it is pure slow-path decode.
    logic [2:0]           cfg_region;
    logic [IDX_W-1:0]     cfg_param_sym;
    logic [IDX_W-1:0]     cfg_state_sym;
    logic [IDX_W-1:0]     cfg_force_sym;
    logic                 cfg_force_word;
    logic                 cfg_addr_bad;
    logic [31:0]          cfg_bad_addr_cnt_q;

    assign cfg_region     = cfg_param_addr[15:13];
    assign cfg_param_sym  = cfg_param_addr[3 +: IDX_W];
    assign cfg_state_sym  = cfg_param_addr[0 +: IDX_W];
    assign cfg_force_sym  = cfg_param_addr[0 +: IDX_W];
    assign cfg_force_word = cfg_param_addr[8];

    assign pt_wr   = cfg_param_wr && (cfg_region == CFG_REGION_PARAM);
    assign pt_sym  = cfg_param_sym;
    assign pt_word = cfg_param_addr[2:0];

    // ⚠️ A write to an address this layer does not recognise is COUNTED, never
    // silently dropped. An unnoticed typo in the host's address arithmetic
    // means the parameters the desk believes are live are not — which is the
    // same failure mode as trading on stale parameters, arrived at by a
    // different route.
    assign cfg_addr_bad = cfg_param_wr &&
                          (cfg_region != CFG_REGION_PARAM)    &&
                          (cfg_region != CFG_REGION_SYMSTATE) &&
                          (cfg_region != CFG_REGION_POSFORCE);

    // ── Per-symbol state writes ──────────────────────────────────────────────
    logic cfg_state_wr;
    assign cfg_state_wr = cfg_param_wr && (cfg_region == CFG_REGION_SYMSTATE);

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned i = 0; i < N_ENTRIES; i++) begin
                sym_state_q[i] <= TRADE_DISABLED;   // fail-closed
            end
            cfg_bad_addr_cnt_q <= 32'd0;
        end else begin
            if (cfg_state_wr) begin
                sym_state_q[cfg_state_sym] <= trade_state_e'(cfg_param_data[2:0]);
            end
            if (cfg_addr_bad) cfg_bad_addr_cnt_q <= cnt_inc(cfg_bad_addr_cnt_q);
        end
    end

    // ── Position force writes (host reconciliation) ──────────────────────────
    // position_t is POS_W=40 bits, so the correction takes two words. Word 0
    // is held; writing word 1 APPLIES the whole correction atomically, so the
    // fabric never sees a half-written position.
    localparam int unsigned FORCE_HI_W = POS_W - 32;   // 8 bits of position[39:32]

    logic [31:0] force_lo_q;
    logic        force_valid;
    sym_idx_t    force_sym;
    position_t   force_pos;
    open_cnt_t   force_open;
    logic        cfg_force_wr;

    assign cfg_force_wr = cfg_param_wr && (cfg_region == CFG_REGION_POSFORCE);

    always_ff @(posedge clk) begin
        if (rst) begin
            force_valid <= 1'b0;
            force_lo_q  <= 32'd0;
        end else begin
            force_valid <= cfg_force_wr && cfg_force_word;
            if (cfg_force_wr && !cfg_force_word) begin
                force_lo_q <= cfg_param_data;               // position[31:0]
            end
            if (cfg_force_wr && cfg_force_word) begin
                force_sym  <= sym_idx_t'(cfg_force_sym);
                force_pos  <= position_t'({cfg_param_data[FORCE_HI_W-1:0],
                                           force_lo_q});
                force_open <= open_cnt_t'(cfg_param_data[31:16]);
            end
        end
    end

    // =========================================================================
    // 4. Position and open-order tracking
    // =========================================================================
    position_t   s1_position;
    open_cnt_t   s1_open_orders;
    logic [31:0] pos_force_cnt, pos_fill_cnt, pos_emit_cnt;
    logic [31:0] pos_sat_cnt, pos_open_underflow_cnt;
    logic        emit_send;

    position_track #(
        .N_ENTRIES (N_ENTRIES)
    ) u_position (
        .clk                (clk),
        .rst                (rst),
        // Fast path read — launched in S0 alongside the parameter read
        .rd_en              (s_top_valid),
        .rd_sym             (s_top.sym),
        .rd_pos             (s1_position),
        .rd_open_orders     (s1_open_orders),
        // Our own emits raise the open-order count
        .emit_valid         (emit_send),
        .emit_sym           (m_req.sym),
        // Venue fills move the position and lower the count
        .fill_valid         (fill_valid),
        .fill_sym           (fill_sym),
        .fill_side          (fill_side),
        .fill_qty           (fill_qty),
        // Host reconciliation
        .force_valid        (force_valid),
        .force_sym          (force_sym),
        .force_pos          (force_pos),
        .force_open         (force_open),
        // Telemetry
        .force_cnt          (pos_force_cnt),
        .fill_cnt           (pos_fill_cnt),
        .emit_cnt           (pos_emit_cnt),
        .sat_cnt            (pos_sat_cnt),
        .open_underflow_cnt (pos_open_underflow_cnt)
    );

    // =========================================================================
    // 5. Stage S1 — gate, trigger, emit
    // =========================================================================
    // trade_gate and trigger_logic are both COMBINATIONAL and both live in this
    // cycle. They run in PARALLEL, not in series: the gate's verdict is a veto
    // applied at the end of trigger_logic's decision mux, so the gate's ~3 LUT
    // levels overlap the trigger's DSP path rather than adding to it. Putting
    // them in series would add ~2 ns to a cycle with under 1 ns of margin.
    logic         gate_pass;
    gate_reason_e gate_reason;
    logic [31:0]  gate_reject_cnt [N_GATE_REASONS];

    trade_gate u_gate (
        .clk          (clk),
        .rst          (rst),
        .s_valid      (s0_valid),
        .s_top        (s0_top),
        .sess_state   (sess_state),
        .sym_state    (s0_sym_state),
        .params_valid (s1_params_valid),
        .params       (s1_params),
        .pass         (gate_pass),
        .reason       (gate_reason),
        .reject_cnt   (gate_reject_cnt)
    );

    strat_decision_t decision;

    trigger_logic #(
        .CONSERVATIVE_SHORT (CONSERVATIVE_SHORT)
    ) u_trigger (
        .clk         (clk),
        .rst         (rst),
        .s_top       (s0_top),
        .params      (s1_params),
        .position    (s1_position),
        .open_orders (s1_open_orders),
        .gate_pass   (gate_pass),
        .decision    (decision)
    );

    // ── Output sanity check — the last thing between a primitive and the wire
    // Structural belt-and-braces. Every one of these is already guaranteed by
    // trigger_logic and by param_table's write-time checks; this exists so that
    // a future edit to a primitive cannot put a degenerate order on the bus
    // without tripping a counter. Cheap: three compares in parallel with the
    // decision mux.
    logic emit_ok;
    logic emit_suppressed;

    assign emit_ok = decision.fired            &&
                     (decision.qty   != 32'd0) &&
                     (decision.price != 32'd0) &&
                     (decision.qty   <= HARD_MAX_QTY);

    assign emit_suppressed = decision.fired && !emit_ok;

    // ── Registered output to the risk gate ───────────────────────────────────
    always_ff @(posedge clk) begin
        if (rst) begin
            m_req_valid <= 1'b0;
        end else begin
            m_req_valid <= s0_valid && emit_ok;
            if (s0_valid && emit_ok) begin
                m_req.action       <= decision.action;
                m_req.sym          <= s0_top.sym;
                m_req.side         <= decision.side;
                m_req.price        <= decision.price;
                m_req.qty          <= decision.qty;
                m_req.post_only    <= decision.post_only;
                m_req.is_short     <= decision.is_short;
                m_req.strat_id     <= decision.strat_id;
                // ACT_CANCEL is defined in order_req_t but is NOT produced by
                // this layer in this revision. Cancel-on-book-move needs an
                // own-order table keyed by token (my_orders.sv) so the engine
                // knows WHICH order to pull; that is future work, tracked in
                // README.md §7. Held at zero so a stray cancel cannot be
                // synthesised from uninitialised bits.
                m_req.cancel_token <= '0;
                // ⚠️ PROPAGATED UNCHANGED. rx_cycle is stamped once at ingress
                // and is the only end-to-end latency reference in the system.
                // Never regenerate it, never default it, never re-stamp it.
                m_req.rx_cycle     <= s0_top.rx_cycle;
            end
        end
    end

    // An emit raises the open-order count. Registered path, so this is the
    // cycle m_req_valid is on the bus.
    assign emit_send = m_req_valid && (m_req.action == ACT_SEND);

    // =========================================================================
    // 6. Telemetry — stat[16] (map in the header)
    // =========================================================================
    logic [31:0]  evt_cnt_q, fired_cnt_q, emit_cnt_q, suppress_cnt_q;
    logic [31:0]  gate_rej_total_q;
    // Most recent rejection reason, held until the next rejection. Cheap, and
    // it answers "why is this symbol quiet RIGHT NOW" without needing two polls
    // of the histogram to see which counter is moving.
    gate_reason_e last_reject_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            evt_cnt_q        <= 32'd0;
            fired_cnt_q      <= 32'd0;
            emit_cnt_q       <= 32'd0;
            suppress_cnt_q   <= 32'd0;
            gate_rej_total_q <= 32'd0;
            last_reject_q    <= GATE_IN_RESET;
        end else begin
            if (s0_valid && !gate_pass)      last_reject_q <= gate_reason;
            if (s_top_valid)                 evt_cnt_q      <= cnt_inc(evt_cnt_q);
            if (s0_valid && decision.fired)  fired_cnt_q    <= cnt_inc(fired_cnt_q);
            if (m_req_valid)                 emit_cnt_q     <= cnt_inc(emit_cnt_q);
            if (s0_valid && emit_suppressed) suppress_cnt_q <= cnt_inc(suppress_cnt_q);
            // Counted directly rather than summed out of the per-reason array:
            // a 10-term 32-bit adder tree is ~300 LUTs and several levels deep,
            // and telemetry has no business building one.
            if (s0_valid && !gate_pass)      gate_rej_total_q <= cnt_inc(gate_rej_total_q);
        end
    end

    // Every element is the direct output of a flip-flop, so these are
    // registered outputs in the sense that matters — no combinational logic
    // between a FF and the port.
    always_comb begin
        for (int unsigned i = 0; i < 16; i++) stat[i] = 32'd0;

        stat[0]  = evt_cnt_q;
        stat[1]  = gate_reject_cnt[GATE_OK];
        stat[2]  = gate_rej_total_q;
        stat[3]  = fired_cnt_q;
        stat[4]  = emit_cnt_q;
        stat[5]  = suppress_cnt_q;
        stat[6]  = gate_reject_cnt[GATE_SESS_NOT_OPEN];
        stat[7]  = gate_reject_cnt[GATE_SYM_NOT_OPEN];
        stat[8]  = gate_reject_cnt[GATE_PARAMS_INVALID];
        stat[9]  = gate_reject_cnt[GATE_STRAT_DISABLED];
        stat[10] = gate_reject_cnt[GATE_BOOK_STALE];
        stat[11] = gate_reject_cnt[GATE_BOOK_CROSSED] +
                   gate_reject_cnt[GATE_SIDE_INVALID];
        stat[12] = gate_reject_cnt[GATE_THIN_BOOK];
        stat[13] = {param_commit_err_cnt[15:0], param_generation};
        stat[14] = {gate_reject_cnt[GATE_UNKNOWN][11:0],
                    last_reject_q,
                    cfg_bad_addr_cnt_q[15:0]};
        stat[15] = pos_force_cnt;
    end

    // =========================================================================
    // 7. Assertions
    // =========================================================================
`ifndef SYNTHESIS
    // ── FIXED LATENCY. The budget row says 2 cycles; this says exactly 2. ────
    a_latency_is_two: assert property (@(posedge clk) disable iff (rst)
        m_req_valid |-> $past(s_top_valid, 2)
    ) else $error("strategy_engine: emitted a request without a book update 2 cycles earlier");

    // ── rx_cycle IS PROPAGATED UNCHANGED ────────────────────────────────────
    // The single most important structural property for latency measurement: if
    // this breaks, every number in the telemetry histogram is fiction.
    a_rx_cycle_unchanged: assert property (@(posedge clk) disable iff (rst)
        m_req_valid |-> (m_req.rx_cycle == $past(s_top.rx_cycle, 2))
    ) else $error("strategy_engine: rx_cycle was not propagated unchanged — latency telemetry is invalid");

    a_sym_unchanged: assert property (@(posedge clk) disable iff (rst)
        m_req_valid |-> (m_req.sym == $past(s_top.sym, 2))
    ) else $error("strategy_engine: symbol changed between book update and request");

    // ── NEVER EMIT A DEGENERATE ORDER ───────────────────────────────────────
    a_no_zero_qty: assert property (@(posedge clk) disable iff (rst)
        m_req_valid |-> (m_req.qty != 32'd0)
    ) else $error("strategy_engine: emitted a zero-quantity order");

    a_no_zero_price: assert property (@(posedge clk) disable iff (rst)
        m_req_valid |-> (m_req.price != 32'd0)
    ) else $error("strategy_engine: emitted a zero-price order");

    a_within_hard_max: assert property (@(posedge clk) disable iff (rst)
        m_req_valid |-> (m_req.qty <= HARD_MAX_QTY)
    ) else $error("strategy_engine: emitted an order above the hardware size ceiling");

    a_valid_action: assert property (@(posedge clk) disable iff (rst)
        m_req_valid |-> (m_req.action == ACT_SEND)
    ) else $error("strategy_engine: m_req_valid with an action other than ACT_SEND");

    // ── GATING IS ABSOLUTE ──────────────────────────────────────────────────
    // NOTE: fpga_top.sv asserts these with |=> (one cycle). This layer is TWO
    // cycles deep, so the |=> form passes vacuously and does not actually test
    // the property. These are the versions that bite. fpga_top.sv's copies
    // should be tightened to ##2 — recorded in README.md §8.
    a_no_order_on_crossed: assert property (@(posedge clk) disable iff (rst)
        (s_top_valid && s_top.crossed) |-> ##2 !m_req_valid
    ) else $error("strategy_engine: order requested on a CROSSED book");

    a_no_order_on_stale: assert property (@(posedge clk) disable iff (rst)
        (s_top_valid && s_top.stale) |-> ##2 !m_req_valid
    ) else $error("strategy_engine: order requested on a STALE book");

    // Sampled one cycle back: the gate reads sess_state in S1 and the request
    // appears in S1+1, so the property is about the state AT EVALUATION TIME.
    // A session that closes while a request is already registered is not a
    // violation here — the risk gate re-checks it downstream, which is the
    // whole point of having a second, authoritative gate.
    a_no_order_when_closed: assert property (@(posedge clk) disable iff (rst)
        m_req_valid |-> ($past(sess_state) == TRADE_OPEN)
    ) else $error("strategy_engine: order requested outside a TRADE_OPEN session");

    a_no_order_when_sym_shut: assert property (@(posedge clk) disable iff (rst)
        m_req_valid |-> ($past(s0_sym_state) == TRADE_OPEN)
    ) else $error("strategy_engine: order requested on a symbol that is not TRADE_OPEN");

    a_no_order_without_params: assert property (@(posedge clk) disable iff (rst)
        m_req_valid |-> $past(s1_params_valid)
    ) else $error("strategy_engine: order requested for a symbol with no valid parameters");

    a_no_order_when_gate_shut: assert property (@(posedge clk) disable iff (rst)
        m_req_valid |-> $past(gate_pass)
    ) else $error("strategy_engine: order requested with the gate closed");

    // ── FAIL-CLOSED ON RESET ────────────────────────────────────────────────
    a_reset_silent: assert property (@(posedge clk)
        rst |=> !m_req_valid
    ) else $error("strategy_engine: emitted during reset");

    // ── REG SHO ─────────────────────────────────────────────────────────────
    a_short_flagged: assert property (@(posedge clk) disable iff (rst)
        (m_req_valid && (m_req.side == SIDE_SELL) &&
         ($past(s1_position) <= position_t'(0))) |-> m_req.is_short
    ) else $error("strategy_engine: REG SHO — short sale emitted without is_short set");

    a_buy_never_short: assert property (@(posedge clk) disable iff (rst)
        (m_req_valid && (m_req.side == SIDE_BUY)) |-> !m_req.is_short
    ) else $error("strategy_engine: is_short set on a buy");

    // ── HOST WINDOW HYGIENE ─────────────────────────────────────────────────
    // Not fatal, but a growing bad-address count means the host and the fabric
    // disagree about the register map, and the desk's parameters are not where
    // it thinks they are.
    a_no_bad_cfg_addr: assert property (@(posedge clk) disable iff (rst)
        !cfg_addr_bad
    ) else $error("strategy_engine: host wrote an unrecognised config address");

    // A commit in the same cycle as a parameter write is a host sequencing bug
    // (README.md §4 requires the commit to be a separate, later transaction).
    a_commit_not_with_write: assert property (@(posedge clk) disable iff (rst)
        cfg_commit |-> !cfg_param_wr
    ) else $error("strategy_engine: cfg_commit asserted in the same cycle as a parameter write");

    // ── SUBMODULE INVARIANTS ────────────────────────────────────────────────
    // These reference the telemetry outputs that do not fit in stat[16]. They
    // are the reason those ports exist: each is a property that must hold for
    // the layer to be trustworthy, and none of them can be checked from the
    // outside.

    // The parameter read pipeline runs in lockstep with the event pipeline.
    a_param_pipeline_aligned: assert property (@(posedge clk) disable iff (rst)
        s1_param_rd_valid == s0_valid
    ) else $error("strategy_engine: parameter read pipeline is out of step with the event pipeline");

    // Bank and generation flip on the same event, both from zero, so the parity
    // of the generation counter IS the active bank. If they ever disagree, the
    // audit trail no longer identifies which parameter set was live.
    a_bank_matches_generation: assert property (@(posedge clk) disable iff (rst)
        param_active_bank == param_generation[0]
    ) else $error("strategy_engine: active bank and generation parity disagree — the audit trail is broken");

    a_generation_counts_commits: assert property (@(posedge clk) disable iff (rst)
        param_generation == param_commit_ok_cnt[15:0]
    ) else $error("strategy_engine: generation does not match the accepted-commit count");

    // ⚠️ These four must stay at zero in a healthy system. Each is a distinct
    // upstream failure, not a tuning knob.
    a_no_commit_refused: assert property (@(posedge clk) disable iff (rst)
        !param_commit_err_sticky
    ) else $error("strategy_engine: a parameter COMMIT WAS REFUSED — the old parameter set is still live and the host's new set never went in");

    a_no_param_field_errors: assert property (@(posedge clk) disable iff (rst)
        param_field_err_cnt == 32'd0
    ) else $error("strategy_engine: the host wrote a parameter value that failed its field check");

    a_no_position_saturation: assert property (@(posedge clk) disable iff (rst)
        pos_sat_cnt == 32'd0
    ) else $error("strategy_engine: position saturated — runaway accumulator or corrupt fill quantity");

    a_no_open_order_underflow: assert property (@(posedge clk) disable iff (rst)
        pos_open_underflow_cnt == 32'd0
    ) else $error("strategy_engine: a fill arrived for a symbol with no open orders — the open-order count has drifted");

    // The engine's own emit counter and position_track's must agree; if they
    // diverge, the open-order feedback loop is broken.
    a_emit_counts_agree: assert property (@(posedge clk) disable iff (rst)
        emit_cnt_q == pos_emit_cnt
    ) else $error("strategy_engine: emit counters disagree — the position feedback loop is broken");

    // Every parameter word the host wrote and every fill we saw are visible in
    // telemetry; a stuck counter means the config or fill path is dead.
    a_word_wr_progresses: assert property (@(posedge clk) disable iff (rst)
        (pt_wr && (param_field_err_cnt == 32'd0)) |=> (param_word_wr_cnt != 32'd0)
    ) else $error("strategy_engine: accepted parameter writes are not being counted");

    a_fill_cnt_progresses: assert property (@(posedge clk) disable iff (rst)
        fill_valid |=> (pos_fill_cnt != 32'd0)
    ) else $error("strategy_engine: fills are not being counted");
`endif

endmodule : strategy_engine

`default_nettype wire
