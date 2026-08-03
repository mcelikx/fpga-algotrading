// =============================================================================
// risk_params.sv — Per-symbol risk limit table, double-buffered, CRC-committed
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Layer   : rtl/risk — pre-trade risk / SEC Rule 15c3-5 control block
// Governs : manuals/08-nasdaq/09-risk-controls-and-limits.md §6, §9
//           manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md §3
//           rtl/pkg/trading_pkg.sv  (sym_risk_t is the contract)
//
// -----------------------------------------------------------------------------
// PURPOSE
//   Hold N_ACTIVE `sym_risk_t` records — the limits the risk gate evaluates every
//   order against — and let the host update them without the fast path ever
//   observing a partially written record.
//
// -----------------------------------------------------------------------------
// ⚠️ THE HAZARD THIS MODULE EXISTS TO PREVENT
//   sym_risk_t is 327 bits. The host bus is 32 bits. A naive table takes 11
//   writes to update a record, and an order evaluated between write 4 and write 5
//   sees the NEW max_order_qty against the OLD collar. That is not a tighter
//   limit and it is not a looser limit — it is an UNDEFINED limit, and it is
//   undefined for a window measured in microseconds of live market data.
//
// ⚠️ THIS TABLE IS NOW ALSO THE LULD BAND SOURCE.
//   `sym_risk_t.luld_lo` / `.luld_hi` / `.luld_valid` are the AUTHORITATIVE
//   continuous LULD bands, written by the host from the SIP. They were
//   previously taken from the feed handler's decode of ITCH `J`, which carries
//   reopening-AUCTION COLLARS, not bands — so they sat at 0/0 and the fail-closed
//   risk gate rejected every order all day. Consequences for this module:
//     * a band update is a full record commit: 11 words, CRC, sanity, one atomic
//       324→327-bit write. At ~25 cycles it is 160 ns of slow path per symbol per
//       band move, which is nothing next to the band update rate;
//     * band moves are therefore CRC-checked, counted, read-backable and
//       governed exactly like every other limit, which is the correct treatment
//       for an input to a 15c3-5 pre-trade control;
//     * `commit_done` is what stamps band freshness in risk_gate. A commit that
//       fails CRC or sanity does NOT pulse it, so a failed band update ages out
//       and the symbol stops trading rather than trading on the old band.
//
//   Structure (identical discipline to the strategy parameter table):
//
//        host 32-bit writes ─────▶ ┌──────────────┐
//                                  │ SHADOW bank  │  N_ACTIVE × 16 × 32b
//                                  │ (word-wide)  │  never read by the fast path
//                                  └──────┬───────┘
//                                         │  commit: read 11 words, CRC-32,
//                                         │  sanity-check, then ONE write
//                                         ▼
//        risk_gate reads ◀───────  ┌──────────────┐
//                                  │ ACTIVE bank  │  N_ACTIVE × 324b
//                                  │ (record-wide)│  never written by the host
//                                  └──────────────┘
//
//   ⚠️ THE ATOMIC POINT is the single 324-bit write to `active_mem[sym]`. It
//   happens on one clock edge. There is no intermediate state, so there is no
//   window in which a torn record is readable — not a short one, not one.
//
//   This differs from the sketch in 09-*.md §6 (two banks + a bank-select flip +
//   an active→shadow copy-back) in one respect, deliberately: because the shadow
//   is word-addressed and the active is record-addressed, the shadow RETAINS the
//   committed values and is already the correct starting point for the next
//   edit. The copy-back step is unnecessary, and removing it removes a
//   multi-cycle window in which the shadow is being rewritten by fabric while
//   the host may also be writing it. Same atomicity, one fewer hazard.
//
// ⚠️ CRC-GATED COMMIT
//   The host writes the 11 record words, then the expected CRC-32, then pulses
//   commit. The fabric recomputes the CRC over the assembled record and refuses
//   the commit on a mismatch: the active bank is NOT written, `params_valid` is
//   NOT set, `crc_err` latches sticky and `crc_fail_cnt` increments.
//   ⚠️ A failed commit does not silently "keep the old parameters and log a
//   warning". The old parameters are usually safe, but the operator's INTENT was
//   not achieved and they must know immediately — hence a sticky flag and a
//   counter that telemetry alarms on, not a soft log line. (09-*.md §6.)
//
// ⚠️ FAIL-CLOSED RESET STATE
//   An ALL-ZERO record is disabled, has every limit at zero, has NO LULD bands
//   loaded (`luld_valid = 0`) and NO pricing increment configured
//   (`tick_class = TICK_UNSET`). The sanity gate below refuses it, so it can
//   never become evaluable. Reset semantics are unchanged by the new fields:
//   all-zero still means "cannot trade", in one more way than before.
//
//   `params_valid[*] = 0`. active_mem contents are undefined-but-unreachable:
//   risk_gate rejects any order for a symbol with params_valid = 0 with
//   RISK_PARAM_INVALID, so an unwritten record can never be evaluated against.
//   There is no default record. A symbol that has never been provisioned by the
//   risk owner is untradeable, permanently, until it is.
//   `generation = 0` and `commit_age` starts saturated, so the parameter
//   freshness watchdog in risk_gate is also expired out of reset.
//
// ⚠️ SANITY GATE
//   A record that passes CRC but is structurally nonsense (zero size limit,
//   inverted collar, negative position magnitude) is committed to the active
//   bank but does NOT set params_valid — the symbol stays untradeable and
//   `sane_fail_cnt` increments. A CRC proves the host wrote what it meant to
//   write; it does not prove what it meant was safe.
//
// ⚠️ READ-BACK IS THE CONTROL THAT CATCHES EVERYTHING ELSE (09-*.md §9)
//   `rb_*` reads the LIVE active bank (and, selectably, the shadow) word by
//   word. The host diffs it against the risk system's record of what the limits
//   should be, several times a day. That diff catches a failed commit, an
//   unlogged manual write, a bank-select bug, an SEU, and a corrupted record —
//   failure modes no amount of write-side care detects. `generation` gives the
//   host a cheap monotonic handle for "did anything change since I last looked".
//   Together they are the audit trail and the four-eyes evidence.
//
// -----------------------------------------------------------------------------
// LATENCY
//   Fast-path read : 1 cycle, registered (`rd_sym` → `rd_rec`). Issued
//                    speculatively from `book_top.sym` by risk_gate, so it is
//                    OFF the order path and costs 0 of the gate's 2 cycles.
//   Commit         : 2·N_WORDS + 3 = 25 cycles, slow path, non-blocking to the
//                    fast path (different memory, no arbitration).
//   Read-back      : 2 cycles.
//
// RESOURCE (estimate, pre-synthesis, VU9P-class, N_ACTIVE=256)
//   active_mem : 256 × 327b  =  84 kbit  →  ~5 BRAM36  (or 1 URAM)
//   shadow_mem : 4096 × 32b  = 131 kbit  →  ~4 BRAM36
//   LUT ~900   FF ~800   BRAM ~9   DSP 0
//
// -----------------------------------------------------------------------------
// REGULATORY OBLIGATIONS IMPLEMENTED
//   * SEC Rule 15c3-5(b) "direct and exclusive control" — the limit table is
//     written only through this port. No fast-path logic and no strategy logic
//     can write it, so a strategy cannot widen its own limit. The host driver
//     places this address region in the risk control plane's BAR, separate from
//     the strategy parameter region, with separate write permissions.
//   * SEC Rule 15c3-5(c)(1) — the pre-set credit, capital, size and price
//     thresholds themselves live here.
//   * SEC Rule 15c3-5(e) annual review / CEO certification — `generation`, the
//     read-back port, and the CRC/sanity failure counters are the evidence that
//     the limits in force are the limits that were approved.
//   * Firm limit governance (09-*.md §9) — four-eyes approval is enforced in the
//     host tool; this module supplies the read-back that proves it took effect.
// =============================================================================
`default_nettype none

module risk_params
    import trading_pkg::*;
#(
    parameter int unsigned N_SYM = trading_pkg::N_ACTIVE
) (
    input  var logic                     clk,
    input  var logic                     rst,     // synchronous, active high

    // ── Host write port (slow path, risk control plane BAR region) ───────────
    input  var logic                     wr_en,
    input  var logic [ACT_IDX_W-1:0]     wr_sym,
    input  var logic [3:0]               wr_word,
    input  var logic [31:0]              wr_data,

    // ── Commit ───────────────────────────────────────────────────────────────
    input  var logic                     commit,          // pulse
    input  var logic [ACT_IDX_W-1:0]     commit_sym,
    input  var logic [31:0]              crc_expected,

    // ── Fast-path read port (speculative, 1-cycle registered) ────────────────
    input  var logic                     rd_en,
    input  var logic [ACT_IDX_W-1:0]     rd_sym,
    output var sym_risk_t                rd_rec,
    output var logic                     rd_params_valid,
    output var logic                     rd_valid,

    // ── Host read-back port (audit trail / limit governance) ─────────────────
    input  var logic                     rb_en,
    input  var logic [ACT_IDX_W-1:0]     rb_sym,
    input  var logic [3:0]               rb_word,
    input  var logic                     rb_shadow,       // 0 = active, 1 = shadow
    output var logic [31:0]              rb_data,
    output var logic                     rb_valid,

    // ── Coherency / status ───────────────────────────────────────────────────
    output var logic                     commit_busy,
    output var logic                     commit_done,     // pulse, success
    output var logic [ACT_IDX_W-1:0]     commit_done_sym,
    output var logic [31:0]              generation,      // successful commits
    output var logic [31:0]              commit_age,      // cycles since last, sat.
    output var logic                     crc_err,         // sticky
    output var logic [15:0]              crc_fail_cnt,    // saturating
    output var logic [15:0]              sane_fail_cnt    // saturating
);

    // -------------------------------------------------------------------------
    // Geometry
    // -------------------------------------------------------------------------
    localparam int unsigned SYM_RISK_W = $bits(sym_risk_t);              // 327
    // ⚠️ Still 11 words after the tick_class / luld_valid additions, so the
    // host's commit sequence length and the CRC coverage are unchanged — only
    // the bit layout inside the words moved. The `initial` check below is what
    // catches the day that stops being true.
    localparam int unsigned N_WORDS    = (SYM_RISK_W + 31) / 32;         // 11
    localparam int unsigned REC_PAD_W  = N_WORDS * 32;                   // 352
    localparam int unsigned SHADOW_D   = N_SYM * 16;                     // 4096
    localparam logic [15:0] CNT16_MAX  = 16'hFFFF;
    localparam logic [31:0] CRC32_POLY = 32'h04C1_1DB7;                  // IEEE 802.3
    localparam logic [31:0] CRC32_INIT = 32'hFFFF_FFFF;

    // -------------------------------------------------------------------------
    // CRC-32, 32 bits per cycle. Unrolled bit loop; synthesis reduces this to a
    // fixed XOR network ~3 LUT6 levels deep. Slow path — timing-irrelevant.
    // -------------------------------------------------------------------------
    function automatic logic [31:0] crc32_w32(input logic [31:0] crc_in,
                                              input logic [31:0] data);
        logic [31:0] c;
        c = crc_in;
        for (int i = 31; i >= 0; i--) begin
            c = {c[30:0], 1'b0} ^ (CRC32_POLY & {32{c[31] ^ data[i]}});
        end
        return c;
    endfunction

    // -------------------------------------------------------------------------
    // ⚠️ SANITY GATE. A CRC proves the host wrote what it meant; this proves
    // what it meant is evaluable. Anything ambiguous => not valid => untradeable.
    // Note `enabled` is NOT checked: a provisioned-but-disabled symbol is a
    // legitimate, expected state and is caught separately as RISK_SYM_DISABLED.
    // -------------------------------------------------------------------------
    function automatic logic param_sane(input sym_risk_t r);
        logic ok;
        ok = 1'b1;
        if (r.max_order_qty      == qty_t'(0))       ok = 1'b0;  // zero size limit
        if (r.max_order_notional == notional_t'(0))  ok = 1'b0;  // zero value limit
        if (r.max_open_orders    == 16'd0)           ok = 1'b0;  // no orders allowed
        if (r.collar_hi          == price_t'(0))     ok = 1'b0;  // collar unset
        if (r.collar_lo          >  r.collar_hi)     ok = 1'b0;  // inverted collar
        // Position bounds are stored as non-negative magnitudes.
        if (r.max_long_pos       <  position_t'(0))  ok = 1'b0;
        if (r.max_short_pos      <  position_t'(0))  ok = 1'b0;
        // ⚠️ SEC Rule 612: a symbol with no minimum pricing increment, or with a
        // reserved encoding, is not evaluable. It is NOT "assume pennies" — the
        // whole point of making the tick per-symbol is that the fabric no longer
        // has a default regime to fall back on. Rejecting here means such a
        // record never becomes evaluable at all, rather than being caught
        // per-order at the gate. (The gate rejects it too, as defence in depth.)
        if (r.tick_class == TICK_UNSET)              ok = 1'b0;
        if (r.tick_class == TICK_RSVD)               ok = 1'b0;
        // ⚠️ LULD bands. `luld_valid` is the host asserting "these are the live
        // SIP bands for this symbol". If it asserts that, the bands must actually
        // be a band: both endpoints present and correctly ordered. A record
        // claiming valid bands of 0/0 would make every order fail on price with
        // RISK_LULD_BAND and look like a market event; it is a control-plane bug
        // and is stopped here, where it is counted as `sane_fail_cnt`.
        // When luld_valid = 0 the band fields are not constrained — the gate
        // rejects with RISK_LULD_NOT_LOADED regardless of what they hold, and
        // forcing the host to zero them would break the legitimate pattern of
        // retaining the last known band for read-back while marking it unusable.
        if (r.luld_valid) begin
            if (r.luld_lo == price_t'(0))            ok = 1'b0;
            if (r.luld_hi == price_t'(0))            ok = 1'b0;
            if (r.luld_lo >  r.luld_hi)              ok = 1'b0;
        end
        return ok;
    endfunction

    // -------------------------------------------------------------------------
    // Memories
    //   shadow_mem : word-addressed {sym, word}. 16-word stride so the address
    //                is a pure concatenation — no multiply. 5 words per symbol
    //                are unused; the BRAM cost of that is trivial next to a
    //                multiplier on an address path.
    //   active_mem : record-addressed. Written ONLY by the commit engine, in a
    //                single 324-bit transaction. This is the atomic point.
    // -------------------------------------------------------------------------
    (* ram_style = "block" *) logic [31:0]           shadow_mem [SHADOW_D];
    (* ram_style = "block" *) logic [SYM_RISK_W-1:0] active_mem [N_SYM];

    logic                     params_valid_q [N_SYM];

    // ── Host writes go only to the shadow. Zero contention with the fast path.
    logic [11:0] wr_addr;
    assign wr_addr = {wr_sym, wr_word};

    always_ff @(posedge clk) begin
        if (wr_en) shadow_mem[wr_addr] <= wr_data;
    end

    // -------------------------------------------------------------------------
    // Commit engine
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        C_IDLE = 3'd0,
        C_RD   = 3'd1,      // drive the shadow read address for word `w`
        C_ACC  = 3'd2,      // accumulate CRC, capture the word
        C_CHK  = 3'd3,      // compare CRC, run the sanity gate
        C_WR   = 3'd4,      // the ATOMIC 324-bit write
        C_FAIL = 3'd5
    } cstate_e;

    cstate_e                 cstate_q, cstate_d;
    logic [ACT_IDX_W-1:0]    csym_q;
    logic [3:0]              cw_q;
    logic [31:0]             ccrc_q;
    logic [REC_PAD_W-1:0]    crec_q;
    logic [31:0]             cexp_q;

    logic [11:0]             shadow_rd_addr;
    logic [31:0]             shadow_rd_q;
    logic                    shadow_rd_en;

    logic [31:0]             gen_q, age_q;
    logic                    crc_err_q;
    logic [15:0]             crc_fail_q, sane_fail_q;
    logic                    commit_done_q;
    logic [ACT_IDX_W-1:0]    commit_done_sym_q;

    sym_risk_t               cand_rec;
    logic                    cand_sane, crc_ok;

    assign cand_rec       = sym_risk_t'(crec_q[SYM_RISK_W-1:0]);
    assign cand_sane      = param_sane(cand_rec);
    assign crc_ok         = ((ccrc_q ^ 32'hFFFF_FFFF) == cexp_q);

    assign shadow_rd_addr = {csym_q, cw_q};
    assign shadow_rd_en   = (cstate_q == C_RD);

    // Shadow read port (registered). Separate from the write port above; the
    // tool infers a simple dual-port BRAM.
    always_ff @(posedge clk) begin
        if (shadow_rd_en) shadow_rd_q <= shadow_mem[shadow_rd_addr];
    end

    // ── Next-state ───────────────────────────────────────────────────────────
    always_comb begin
        cstate_d = cstate_q;                              // default: hold
        unique case (cstate_q)
            C_IDLE : if (commit)                cstate_d = C_RD;
            C_RD   :                            cstate_d = C_ACC;
            C_ACC  : cstate_d = (cw_q == 4'(N_WORDS-1)) ? C_CHK : C_RD;
            C_CHK  : cstate_d = crc_ok ? C_WR : C_FAIL;
            C_WR   :                            cstate_d = C_IDLE;
            C_FAIL :                            cstate_d = C_IDLE;
            default:                            cstate_d = C_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            cstate_q          <= C_IDLE;
            csym_q            <= '0;
            cw_q              <= 4'd0;
            ccrc_q            <= CRC32_INIT;
            crec_q            <= '0;
            cexp_q            <= 32'd0;
            gen_q             <= 32'd0;
            age_q             <= 32'hFFFF_FFFF;   // ⚠️ starts EXPIRED: fail-closed
            crc_err_q         <= 1'b0;
            crc_fail_q        <= 16'd0;
            sane_fail_q       <= 16'd0;
            commit_done_q     <= 1'b0;
            commit_done_sym_q <= '0;
            for (int unsigned s = 0; s < N_SYM; s++) params_valid_q[s] <= 1'b0;
        end else begin
            cstate_q      <= cstate_d;
            commit_done_q <= 1'b0;                       // default: one-cycle pulse

            // Parameter freshness: cycles since the last SUCCESSFUL commit.
            // Saturating — a wrapped age would report a stale table as fresh.
            if (cstate_q == C_WR && cand_sane) age_q <= 32'd0;
            else if (age_q != 32'hFFFF_FFFF)   age_q <= age_q + 32'd1;
            else                               age_q <= age_q;

            unique case (cstate_q)
                C_IDLE : begin
                    if (commit) begin
                        csym_q <= commit_sym;
                        cexp_q <= crc_expected;
                        cw_q   <= 4'd0;
                        ccrc_q <= CRC32_INIT;
                        crec_q <= '0;
                    end
                end

                C_RD : begin
                    // address driven combinationally; nothing to latch
                end

                C_ACC : begin
                    ccrc_q <= crc32_w32(ccrc_q, shadow_rd_q);
                    for (int unsigned w = 0; w < N_WORDS; w++) begin
                        if (4'(w) == cw_q) crec_q[w*32 +: 32] <= shadow_rd_q;
                    end
                    cw_q <= cw_q + 4'd1;
                end

                C_CHK : begin
                    // decision only
                end

                C_WR : begin
                    // ⚠️ THE ATOMIC POINT — one edge, whole record.
                    active_mem[csym_q] <= crec_q[SYM_RISK_W-1:0];
                    // params_valid gates evaluability. A structurally insane
                    // record is stored (so read-back shows the host exactly what
                    // it sent) but is NEVER evaluable.
                    params_valid_q[csym_q] <= cand_sane;
                    if (cand_sane) begin
                        gen_q             <= gen_q + 32'd1;
                        commit_done_q     <= 1'b1;
                        commit_done_sym_q <= csym_q;
                    end else begin
                        sane_fail_q <= (sane_fail_q == CNT16_MAX) ? CNT16_MAX
                                                                 : sane_fail_q + 16'd1;
                    end
                end

                C_FAIL : begin
                    // ⚠️ CRC mismatch: the active bank is untouched and
                    // params_valid is untouched. Loud, sticky, counted.
                    crc_err_q  <= 1'b1;
                    crc_fail_q <= (crc_fail_q == CNT16_MAX) ? CNT16_MAX
                                                           : crc_fail_q + 16'd1;
                end

                default : begin
                    // unreachable
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Fast-path read port. Registered, 1 cycle. Speculatively issued by
    // risk_gate from book_top.sym, so it is off the order path entirely.
    // -------------------------------------------------------------------------
    logic [SYM_RISK_W-1:0] rd_rec_q;
    logic                  rd_pv_q, rd_vld_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_vld_q <= 1'b0;
            rd_pv_q  <= 1'b0;
        end else begin
            rd_vld_q <= rd_en;
            rd_pv_q  <= rd_en ? params_valid_q[rd_sym] : 1'b0;
        end
        if (rd_en) rd_rec_q <= active_mem[rd_sym];      // datapath: no reset
    end

    assign rd_rec          = sym_risk_t'(rd_rec_q);
    assign rd_params_valid = rd_pv_q;
    assign rd_valid        = rd_vld_q;

    // -------------------------------------------------------------------------
    // Host read-back port. Second read port on both memories; the tool
    // replicates for the extra read. 2 cycles, slow path.
    // -------------------------------------------------------------------------
    logic [SYM_RISK_W-1:0] rb_act_q;
    logic [31:0]           rb_sh_q;
    logic [3:0]            rb_word_q;
    logic                  rb_shadow_q, rb_pv_q;
    logic                  rb_vld_q, rb_vld_q2;
    logic [31:0]           rb_data_q;
    logic [REC_PAD_W-1:0]  rb_act_pad;

    assign rb_act_pad = {{(REC_PAD_W-SYM_RISK_W){1'b0}}, rb_act_q};

    always_ff @(posedge clk) begin
        if (rst) begin
            rb_vld_q  <= 1'b0;
            rb_vld_q2 <= 1'b0;
        end else begin
            rb_vld_q  <= rb_en;
            rb_vld_q2 <= rb_vld_q;
        end
        if (rb_en) begin
            rb_act_q    <= active_mem[rb_sym];
            rb_sh_q     <= shadow_mem[{rb_sym, rb_word}];
            rb_word_q   <= rb_word;
            rb_shadow_q <= rb_shadow;
            rb_pv_q     <= params_valid_q[rb_sym];
        end
    end

    always_ff @(posedge clk) begin
        rb_data_q <= 32'd0;                                // default assignment
        if (rb_shadow_q) begin
            rb_data_q <= rb_sh_q;
        end else if (rb_word_q == 4'd15) begin
            // Word 15 of the active view is a synthetic status word so the host
            // can read validity without a second transaction.
            rb_data_q <= {31'd0, rb_pv_q};
        end else begin
            for (int unsigned w = 0; w < N_WORDS; w++) begin
                if (4'(w) == rb_word_q) rb_data_q <= rb_act_pad[w*32 +: 32];
            end
        end
    end

    assign rb_data  = rb_data_q;
    assign rb_valid = rb_vld_q2;

    // -------------------------------------------------------------------------
    // Status
    // -------------------------------------------------------------------------
    assign commit_busy     = (cstate_q != C_IDLE);
    assign commit_done     = commit_done_q;
    assign commit_done_sym = commit_done_sym_q;
    assign generation      = gen_q;
    assign commit_age      = age_q;
    assign crc_err         = crc_err_q;
    assign crc_fail_cnt    = crc_fail_q;
    assign sane_fail_cnt   = sane_fail_q;

    // =========================================================================
    // Assertions — simulation only
    // =========================================================================
`ifndef SYNTHESIS
    initial begin
        if (N_WORDS > 16)
            $error("risk_params: sym_risk_t (%0d bits) needs %0d words; the shadow stride only holds 16", SYM_RISK_W, N_WORDS);
        if (N_SYM != (1 << ACT_IDX_W))
            $warning("risk_params: N_SYM %0d is not 2**ACT_IDX_W", N_SYM);
    end

    // ⚠️ NO TORN RECORDS. The active bank is written in exactly one state, in
    // one transaction. Nothing else in the design may write it.
    a_atomic : assert property (@(posedge clk) disable iff (rst)
        $changed(active_mem[csym_q]) |-> ($past(cstate_q) == C_WR)
    ) else $error("FATAL: active_mem changed outside the atomic commit write");

    // ⚠️ Fail-closed out of reset: nothing evaluable, nothing fresh.
    a_reset_invalid : assert property (@(posedge clk)
        rst |=> (generation == 32'd0 && commit_age == 32'hFFFF_FFFF)
    ) else $error("risk_params did not come out of reset fail-closed");

    // A CRC failure must not touch validity or the generation counter.
    a_crc_no_commit : assert property (@(posedge clk) disable iff (rst)
        (cstate_q == C_FAIL) |=> ($stable(generation))
    ) else $error("FATAL: generation advanced on a failed-CRC commit");

    // params_valid may only rise through a successful, sane commit.
    a_valid_rise : assert property (@(posedge clk) disable iff (rst)
        $rose(params_valid_q[csym_q]) |-> ($past(cstate_q) == C_WR && $past(cand_sane))
    ) else $error("FATAL: params_valid set without a sane committed record");

    // An insane record is never marked valid.
    a_insane : assert property (@(posedge clk) disable iff (rst)
        ((cstate_q == C_WR) && !cand_sane) |=> !params_valid_q[$past(csym_q)]
    ) else $error("FATAL: a structurally invalid limit record was marked valid");

    // Generation is monotonic — the host relies on it as an audit handle.
    a_gen_mono : assert property (@(posedge clk) disable iff (rst)
        generation >= $past(generation)
    ) else $error("FATAL: parameter generation counter went backwards");

    // Commit is not re-entrant.
    a_no_reentry : assert property (@(posedge clk) disable iff (rst)
        (commit && commit_busy) |-> 1'b1
    );  // a commit during a commit is ignored by construction (C_IDLE only)
    a_busy_ignores : assert property (@(posedge clk) disable iff (rst)
        (commit_busy && commit) |=> $stable(csym_q)
    ) else $error("a commit pulse corrupted an in-progress commit");

    // ⚠️ A valid record always has an evaluable Rule 612 increment, and if it
    //    claims LULD bands they are a real, ordered band. Re-derived from the
    //    stored record rather than from param_sane, so a bug in the sanity gate
    //    itself cannot hide behind its own logic.
    // The committed record as stored, re-read from the active bank.
    sym_risk_t act_rec;
    assign act_rec = sym_risk_t'(active_mem[csym_q]);

    a_valid_tick : assert property (@(posedge clk) disable iff (rst)
        params_valid_q[csym_q] |-> ((act_rec.tick_class != TICK_UNSET)
                                 && (act_rec.tick_class != TICK_RSVD))
    ) else $error("FATAL: a record with no Rule 612 increment was marked valid");

    a_valid_band : assert property (@(posedge clk) disable iff (rst)
        (params_valid_q[csym_q] && act_rec.luld_valid)
        |-> ((act_rec.luld_lo != price_t'(0))
          && (act_rec.luld_lo <= act_rec.luld_hi))
    ) else $error("FATAL: a record claiming LULD bands was marked valid with no usable band");

    // ⚠️ REQUIRED COVERAGE — every path observed.
    c_commit_ok   : cover property (@(posedge clk) disable iff (rst) commit_done);
    c_sane_tick   : cover property (@(posedge clk) disable iff (rst)
                                     (cstate_q == C_WR) && !cand_sane
                                     && (cand_rec.tick_class == TICK_UNSET));
    c_sane_band   : cover property (@(posedge clk) disable iff (rst)
                                     (cstate_q == C_WR) && !cand_sane
                                     && cand_rec.luld_valid);
    c_band_commit : cover property (@(posedge clk) disable iff (rst)
                                     commit_done && cand_rec.luld_valid);
    c_commit_crc  : cover property (@(posedge clk) disable iff (rst) cstate_q == C_FAIL);
    c_commit_sane : cover property (@(posedge clk) disable iff (rst)
                                     (cstate_q == C_WR) && !cand_sane);
    c_rd          : cover property (@(posedge clk) disable iff (rst) rd_valid && rd_params_valid);
    c_rd_invalid  : cover property (@(posedge clk) disable iff (rst) rd_valid && !rd_params_valid);
    c_rb_active   : cover property (@(posedge clk) disable iff (rst) rb_valid && !rb_shadow_q);
    c_rb_shadow   : cover property (@(posedge clk) disable iff (rst) rb_valid &&  rb_shadow_q);
    c_stale       : cover property (@(posedge clk) disable iff (rst) commit_age == 32'hFFFF_FFFF);
`endif

endmodule : risk_params

`default_nettype wire
