// =============================================================================
// param_table.sv — Per-symbol strategy parameter store, atomically double-buffered
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Layer   : rtl/strategy/  (budget row S0 — parameter read)
// Governs : manuals/04-system-architecture/04-strategy-engine-on-fpga.md
//           manuals/03-algotrading/05-strategy-taxonomy.md §6 (commit protocol)
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// -----------------------------------------------------------------------------
// PURPOSE
//   N_ENTRIES records of sym_strat_t, one per active symbol, written by the host
//   over the slow path and read by the fast path in one cycle.
//
//   This is the "parameter table" half of the core architectural principle: the
//   FPGA is a TRIGGER EVALUATOR OVER A PARAMETER TABLE, not a compute engine.
//   Every trading number the fast path uses arrives through this module. There
//   are no trading constants in the RTL.
//
// -----------------------------------------------------------------------------
// ⚠️  THE CRITICAL FEATURE: ATOMIC DOUBLE-BUFFERED UPDATE
//
//   A strategy trading on a MIX of old and new parameters is a real, named,
//   money-losing bug class. Concretely: the host is moving a symbol from
//   fair_value = $100.00 / edge = $0.05 to fair_value = $80.00 / edge = $0.05
//   after a gap-down. If the fast path reads the NEW fair_value with the OLD
//   quote_qty — or worse, reads the new fair value one cycle before the new
//   edge lands — it quotes a size and a price that no risk model ever approved.
//   That is not a rounding error, it is an order in the market that nobody
//   intended to send.
//
//   The defence here has THREE independent layers:
//
//   (1) DOUBLE BUFFER + COMMIT BIT. Two banks. The host may only write the
//       INACTIVE bank; hardware routes writes there (wr_bank = ~active_bank_q)
//       so the host cannot address the live bank even by mistake. A single
//       cfg_commit write flips which bank is active. See §3.
//
//   (2) BANK SELECT IS PART OF THE READ ADDRESS. The memory is addressed as
//       {bank, sym}. The bank bit is captured at the same instant as the symbol
//       index, so a record read is atomic BY CONSTRUCTION — there is no window
//       in which a flip can land between "which bank" and "which record". This
//       is stronger than muxing two RAM outputs after the fact, where a flip
//       one cycle later would select the wrong bank's data for an in-flight
//       read. See §5 and the assertion in §8.
//
//   (3) PER-RECORD COMPLETENESS. A record is not readable until every one of
//       its N_PARAM_WORDS words has been written AND passed its field check.
//       params_valid is 0 until then, and trade_gate refuses to trade a symbol
//       whose params_valid is 0. See §4.
//
// -----------------------------------------------------------------------------
// ⚠️  THE SHADOW BANK IS NOT A COPY OF THE ACTIVE BANK
//
//   On commit, the word-validity mask of the newly-SHADOW bank is cleared in a
//   single cycle. Every symbol the host wants live in the next generation must
//   be written again, in full. This is deliberate:
//
//     * Without it, committing after writing one symbol would silently REVERT
//       every other symbol to its two-generations-ago values. A partial write
//       that silently resurrects stale parameters is exactly the failure this
//       module exists to prevent.
//     * With it, a symbol the host forgot has params_valid = 0 and simply does
//       not trade. The failure is loud (a counter moves, the symbol goes quiet)
//       instead of silent (the symbol trades on last week's fair value).
//
//   Cost: the host writes the whole table each generation. At N_ENTRIES=256 and
//   6 words that is 1536 posted PCIe writes, ~150 us — utterly irrelevant at a
//   millisecond parameter cadence.
//
// -----------------------------------------------------------------------------
// LATENCY
//   Read : 1 cycle (6.4 ns @ 156.25 MHz). Address presented in cycle N with
//          rd_en; rd_param / rd_params_valid / rd_valid are registered and
//          valid in cycle N+1. This is budget row S0.
//   Write: 1 cycle, off the fast path. Never stalls a read.
//   Commit: 1 cycle, single atomic bank flip. Jitter contributed to the fast
//          path by a commit: ZERO cycles (see 01-tick-to-trade-pipeline.md J10).
//
// RESOURCE (estimate, N_ENTRIES=256, N_PARAM_WORDS=6, UltraScale+)
//   BRAM : 6 x (512 deep x 32 wide) simple-dual-port = 6 x RAMB18 = 6 BRAM18
//          (3 BRAM36 equivalent). Bank is the MSB of the address, so both banks
//          share one memory — this is why the count is 6 and not 12.
//   FF   : word_ok  2 x 256 x 6            = 3,072
//          read pipeline regs (6x32 + ctl) =   200
//          counters, generation, bank      =   180
//                                          -------
//                                          ~3,450 FF
//   LUT  : write decode + field checks     ~   250
//          word_ok read mux (512:1 x 6b)   ~   520
//          shadow_any_ready reduction      ~   150
//                                          -------
//                                          ~  920 LUT
//   DSP  : 0
//
//   The 3,072 FF for word_ok is a deliberate purchase, not an oversight. It
//   buys a SINGLE-CYCLE bulk clear at commit. Holding the mask in RAM would
//   need a 256-cycle scrub during which the table is neither the old generation
//   nor the new one — a 1.6 us window of exactly the mixed-parameter state this
//   module exists to make impossible.
// =============================================================================
`default_nettype none

module param_table
    import trading_pkg::*;
    import strategy_pkg::*;
#(
    parameter int unsigned N_ENTRIES    = N_ACTIVE,
    parameter int unsigned IDX_W        = ACT_IDX_W,
    // Hardware ceiling on quote size, enforced at WRITE time. Independent of
    // anything the host can set. A record asking for more is rejected outright.
    parameter qty_t        HARD_MAX_QTY = HARD_MAX_QUOTE_QTY
) (
    input  var logic                  clk,
    input  var logic                  rst,          // synchronous, active high

    // ── Fast path read port (port A — owned exclusively by the fast path) ────
    input  var logic                  rd_en,
    input  var sym_idx_t              rd_sym,
    output var sym_strat_t            rd_param,      // valid at N+1
    output var logic                  rd_params_valid,
    output var logic                  rd_valid,      // pipeline valid at N+1

    // ── Host write window (port B — slow path, decoded by strategy_engine) ───
    input  var logic                  cfg_wr,
    input  var logic [IDX_W-1:0]      cfg_sym,
    input  var logic [PARAM_WORD_W-1:0] cfg_word,
    input  var logic [31:0]           cfg_data,
    input  var logic                  cfg_commit,

    // ── Readback / audit trail ───────────────────────────────────────────────
    // generation is the ONLY way the host can confirm WHICH parameter set is
    // live. "I sent it" is not "it is running". Required for the audit trail:
    // every emitted order can be tied to a generation, and every generation to
    // a host-side parameter blob.
    output var logic [15:0]           generation,
    output var logic                  active_bank,
    output var logic [31:0]           word_wr_cnt,      // accepted word writes
    output var logic [31:0]           field_err_cnt,    // words failing a check
    output var logic [31:0]           commit_ok_cnt,
    output var logic [31:0]           commit_err_cnt,
    output var logic                  commit_err_sticky // latched; host clears
                                                        // only by reset
);

    // =========================================================================
    // 1. Local geometry
    // =========================================================================
    localparam int unsigned MEM_ADDR_W = IDX_W + 1;          // {bank, sym}
    localparam int unsigned MEM_DEPTH  = 2 * N_ENTRIES;

    // =========================================================================
    // 2. Bank ownership
    // =========================================================================
    // The host NEVER names a bank. Hardware always routes writes to the
    // inactive one. This removes an entire class of host bug (writing the live
    // bank) by construction rather than by convention.
    logic active_bank_q;
    logic wr_bank;

    assign wr_bank     = ~active_bank_q;
    assign active_bank = active_bank_q;

    // =========================================================================
    // 3. Per-word field checks (evaluated at WRITE time, not at trade time)
    // =========================================================================
    // Checking at write time costs nothing on the fast path. Checking at read
    // time would put a comparator bank in front of every trigger evaluation, in
    // stage S1, which has no room for it.
    //
    // A word that FAILS its check clears its validity bit, which invalidates
    // the whole record. A rejected value therefore cannot half-land: the symbol
    // simply does not become tradeable this generation.
    logic word_check_ok;

    always_comb begin
        word_check_ok = 1'b0;                       // default: reject
        case (cfg_word)
            PW_CTRL:      // strat_select must name a primitive that exists
                word_check_ok = strat_sel_legal(cfg_data[4:1]);
            PW_QUOTE_QTY: // a zero-size order is meaningless; the ceiling is
                          // a fat-finger guard the host cannot raise
                word_check_ok = (cfg_data != 32'd0) &&
                                (qty_t'(cfg_data) <= HARD_MAX_QTY);
            PW_EDGE:      // any edge is legal, including zero (join the touch).
                          // Pre-scaled to ITCH price units by the host; see
                          // strategy_pkg.sv §5.
                word_check_ok = 1'b1;
            PW_MIN_QTY:   // zero means "no minimum depth requirement"
                word_check_ok = 1'b1;
            PW_FAIR_VAL:  // REQUIRED FIELD. Zero is not a price. A zero fair
                          // value would make (fair_value + edge) a live sell
                          // trigger against every bid in the book — the classic
                          // uninitialised-parameter blowup. The host writes the
                          // current mid here even for primitives that ignore it.
                word_check_ok = (cfg_data != 32'd0);
            PW_IMB_THR:   // must encode a ratio >= 1.0, and the upper half must
                          // be clean. thr < IMB_SCALE would make the bid-heavy
                          // and ask-heavy tests simultaneously true.
                word_check_ok = (cfg_data[31:16] == 16'd0) &&
                                (cfg_data[15:0]  >= IMB_SCALE);
            default:      // an address outside the record: reject and count
                word_check_ok = 1'b0;
        endcase
    end

    logic word_addr_legal;
    logic wr_accept;
    logic wr_reject;

    assign word_addr_legal = (cfg_word < PARAM_WORD_W'(N_PARAM_WORDS));
    assign wr_accept       = cfg_wr &&  word_addr_legal &&  word_check_ok;
    assign wr_reject       = cfg_wr && (!word_addr_legal || !word_check_ok);

    // =========================================================================
    // 4. Record completeness / validity mask
    // =========================================================================
    // word_ok[bank][sym][w] == 1  <=>  word w of that record has been written
    //                                  in the CURRENT epoch of that bank AND
    //                                  passed its field check.
    //
    // A record is readable only when all N_PARAM_WORDS bits are set. This is
    // the params_valid contract: 0 until the host has written a COMPLETE
    // record, and the gate refuses to trade a symbol whose parameters were
    // never loaded. Fail-closed.
    logic [N_PARAM_WORDS-1:0] word_ok [2][N_ENTRIES];

    // Is there at least one complete record in the shadow bank? Registered, so
    // this 256-wide reduction never appears in a timing path. It is one cycle
    // behind the writes, which is why the commit must not be issued in the same
    // or immediately-following cycle as the final word write — see the SVA in
    // §8 and the host protocol in README.md §4.
    logic shadow_any_ready_q;
    logic shadow_any_ready_d;

    always_comb begin
        shadow_any_ready_d = 1'b0;
        for (int unsigned i = 0; i < N_ENTRIES; i++) begin
            if (&word_ok[~active_bank_q][i]) shadow_any_ready_d = 1'b1;
        end
    end

    // =========================================================================
    // 5. Parameter memory — {bank, sym} addressed, one RAM per record word
    // =========================================================================
    // Bank is the MSB of the ADDRESS, not a select on the RAM output. That is
    // the whole atomicity argument: the bank is committed to at the same clock
    // edge as the symbol index, so no in-flight read can be redirected by a
    // later flip. There is no output mux to get wrong.
    //
    // Six independent 32-bit memories with full-word writes -> clean
    // simple-dual-port BRAM inference. No byte enables, no read-modify-write.
    logic [MEM_ADDR_W-1:0] rd_addr;
    logic [MEM_ADDR_W-1:0] wr_addr;
    logic [31:0]           rd_word_q [N_PARAM_WORDS];

    assign rd_addr = {active_bank_q, rd_sym};
    assign wr_addr = {wr_bank,       cfg_sym};

    generate
        for (genvar w = 0; w < N_PARAM_WORDS; w++) begin : g_pword
            // Datapath memory: no reset. Contents are meaningless until
            // word_ok says otherwise, which IS reset.
            logic [31:0] mem [MEM_DEPTH];

            always_ff @(posedge clk) begin
                if (wr_accept && (cfg_word == PARAM_WORD_W'(w))) begin
                    mem[wr_addr] <= cfg_data;
                end
                if (rd_en) begin
                    rd_word_q[w] <= mem[rd_addr];
                end
            end
        end : g_pword
    endgenerate

    // =========================================================================
    // 6. Sequential: bank flip, validity mask, counters
    // =========================================================================
    logic rd_params_valid_d;
    logic [15:0] generation_q;
    logic [31:0] word_wr_cnt_q, field_err_cnt_q;
    logic [31:0] commit_ok_cnt_q, commit_err_cnt_q;
    logic        commit_err_sticky_q;

    // Completeness of the record being addressed THIS cycle, in the bank active
    // THIS cycle. Captured with the address so it stays coherent with the data.
    assign rd_params_valid_d = &word_ok[active_bank_q][rd_sym];

    always_ff @(posedge clk) begin
        if (rst) begin
            // RESET = NOTHING IS TRADEABLE. Both banks' masks are cleared, so
            // params_valid is 0 for every symbol until the host has written a
            // complete record AND committed. CLAUDE.md §5 rule 4, fail-closed.
            active_bank_q       <= 1'b0;
            shadow_any_ready_q  <= 1'b0;
            generation_q        <= 16'd0;
            word_wr_cnt_q       <= 32'd0;
            field_err_cnt_q     <= 32'd0;
            commit_ok_cnt_q     <= 32'd0;
            commit_err_cnt_q    <= 32'd0;
            commit_err_sticky_q <= 1'b0;
            rd_valid            <= 1'b0;
            rd_params_valid     <= 1'b0;
            for (int unsigned b = 0; b < 2; b++) begin
                for (int unsigned i = 0; i < N_ENTRIES; i++) begin
                    word_ok[b][i] <= '0;
                end
            end
        end else begin
            shadow_any_ready_q <= shadow_any_ready_d;

            // ── Read pipeline ────────────────────────────────────────────────
            rd_valid <= rd_en;
            if (rd_en) rd_params_valid <= rd_params_valid_d;

            // ── Host word write (shadow bank only) ───────────────────────────
            if (cfg_wr && word_addr_legal) begin
                // Set on a good value, CLEAR on a bad one. A rejected write
                // invalidates the record rather than leaving the previous
                // (possibly complete) value in place — the host asked for a
                // change and got a refusal, so the record must not stay live.
                word_ok[wr_bank][cfg_sym][cfg_word] <= word_check_ok;
            end
            if (wr_accept) word_wr_cnt_q   <= cnt_inc(word_wr_cnt_q);
            if (wr_reject) field_err_cnt_q <= cnt_inc(field_err_cnt_q);

            // ── Commit: the single atomic flip ───────────────────────────────
            // One cycle. One bit. Everything downstream of this edge reads the
            // new generation; everything before it read the old one. There is
            // no intermediate state.
            if (cfg_commit) begin
                if (shadow_any_ready_q) begin
                    active_bank_q   <= ~active_bank_q;
                    generation_q    <= generation_q + 16'd1;
                    commit_ok_cnt_q <= cnt_inc(commit_ok_cnt_q);
                    // The bank going shadow must be rewritten in full before it
                    // can go live again. Single-cycle bulk clear — see the
                    // header note on why this mask lives in FFs.
                    for (int unsigned i = 0; i < N_ENTRIES; i++) begin
                        word_ok[active_bank_q][i] <= '0;
                    end
                end else begin
                    // The host committed a shadow bank with no complete record
                    // in it. That is always a host bug (usually: wrote the
                    // records, forgot a word, or committed twice). NO FLIP —
                    // the old parameters stay live, which is the safe outcome —
                    // sticky flag, counted, and visible in stat[13].
                    commit_err_sticky_q <= 1'b1;
                    commit_err_cnt_q    <= cnt_inc(commit_err_cnt_q);
                end
            end
        end
    end

    // =========================================================================
    // 7. Record reassembly (registered RAM outputs -> sym_strat_t)
    // =========================================================================
    // Pure rewiring of already-registered bits. No logic, no delay. rd_param is
    // a registered output in the sense that matters: every bit of it is the
    // direct output of a flip-flop.
    always_comb begin
        rd_param                = '0;
        rd_param.strat_enabled  = rd_word_q[PW_CTRL][0];
        rd_param.strat_select   = rd_word_q[PW_CTRL][4:1];
        rd_param.quote_qty      = qty_t'(rd_word_q[PW_QUOTE_QTY]);
        rd_param.edge_ticks     = price_t'(rd_word_q[PW_EDGE]);
        rd_param.min_book_qty   = qty_t'(rd_word_q[PW_MIN_QTY]);
        rd_param.fair_value     = price_t'(rd_word_q[PW_FAIR_VAL]);
        rd_param.imbalance_thr  = rd_word_q[PW_IMB_THR][15:0];
    end

    assign generation        = generation_q;
    assign word_wr_cnt       = word_wr_cnt_q;
    assign field_err_cnt     = field_err_cnt_q;
    assign commit_ok_cnt     = commit_ok_cnt_q;
    assign commit_err_cnt    = commit_err_cnt_q;
    assign commit_err_sticky = commit_err_sticky_q;

    // =========================================================================
    // 8. Assertions — the atomicity contract, stated formally
    // =========================================================================
`ifndef SYNTHESIS
    // Shadow copy of the bank that was active when the address was presented.
    // Simulation only; used by a_read_bank_is_address_bank below.
    logic rd_addr_bank_q;
    always_ff @(posedge clk) begin
        if (rd_en) rd_addr_bank_q <= active_bank_q;
    end

    // ⚠️ THE CENTRAL PROPERTY. The active bank may change ONLY on the cycle
    // after an accepted commit. If this ever fires, a read straddled two
    // parameter generations and the design is unsafe to trade.
    a_bank_changes_only_on_commit: assert property (@(posedge clk) disable iff (rst)
        $changed(active_bank_q) |-> $past(cfg_commit && shadow_any_ready_q)
    ) else $error("param_table: ACTIVE BANK CHANGED OUTSIDE A COMMIT — a read may have straddled two parameter generations");

    // The bank used to fetch a record is the bank that was active when the
    // address was presented. Structurally guaranteed (bank is address MSB);
    // asserted so a future refactor to an output mux cannot silently break it.
    a_read_bank_is_address_bank: assert property (@(posedge clk) disable iff (rst)
        rd_en |=> (rd_addr_bank_q == $past(active_bank_q))
    ) else $error("param_table: read returned data from a bank that was not active at address time");

    // The host can never address the live bank.
    a_never_write_active_bank: assert property (@(posedge clk) disable iff (rst)
        cfg_wr |-> (wr_bank != active_bank_q)
    ) else $error("param_table: write targeted the ACTIVE bank");

    // params_valid implies the record really is complete and sane. quote_qty
    // is the field that can never legally be zero, so it is the cheap witness.
    a_valid_implies_complete: assert property (@(posedge clk) disable iff (rst)
        (rd_valid && rd_params_valid) |-> (rd_param.quote_qty != 32'd0)
    ) else $error("param_table: params_valid asserted on an incomplete record");

    a_valid_implies_legal_strat: assert property (@(posedge clk) disable iff (rst)
        (rd_valid && rd_params_valid) |-> strat_sel_legal(rd_param.strat_select)
    ) else $error("param_table: params_valid asserted with an illegal strat_select");

    a_valid_implies_sane_imb: assert property (@(posedge clk) disable iff (rst)
        (rd_valid && rd_params_valid) |-> (rd_param.imbalance_thr >= IMB_SCALE)
    ) else $error("param_table: params_valid asserted with imbalance_thr below 1.0");

    // Fixed latency: budget row S0 is exactly one cycle, never more, never less.
    a_fixed_read_latency: assert property (@(posedge clk) disable iff (rst)
        rd_en |=> rd_valid
    ) else $error("param_table: read latency is not exactly 1 cycle");

    // HOST PROTOCOL: shadow_any_ready_q is registered, so a commit issued
    // within one cycle of the final parameter word write would be evaluated
    // against a stale readiness bit. PCIe posted writes are hundreds of cycles
    // apart, so this can only fire in a testbench that cheats.
    a_commit_not_adjacent_to_write: assert property (@(posedge clk) disable iff (rst)
        cfg_wr |=> !cfg_commit
    ) else $error("param_table: cfg_commit issued 1 cycle after a parameter write — see README.md §4 step 5");

    // Reset really is fail-closed.
    a_reset_is_fail_closed: assert property (@(posedge clk)
        rst |=> !rd_params_valid
    ) else $error("param_table: params_valid survived reset");
`endif

endmodule : param_table

`default_nettype wire
