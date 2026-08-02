// =============================================================================
// venue_state.sv — Per-symbol venue state + global session state from ITCH
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/08-nasdaq/02-sessions-auctions-and-halts.md
//           manuals/08-nasdaq/04-totalview-itch-5.0.md
//           manuals/04-system-architecture/02-feed-handler-design.md  §8
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
// Layer   : rtl/feed — see rtl/feed/README.md
//
// PURPOSE
//   Track what the VENUE says we are allowed to do, from the non-book ITCH
//   messages, and publish it on the sym_state_* side-channel that feeds both
//   the strategy engine and the pre-trade risk gate.
//
//   This module is not on the tick-to-trade path. It is on the "may we trade at
//   all" path, which is a correctness and compliance path. Every default here
//   is chosen to fail CLOSED.
//
// -----------------------------------------------------------------------------
// MESSAGE -> STATE MAPPING
//
//   'S' System Event      -> GLOBAL sess_state
//                              O, S -> TRADE_PREOPEN
//                              Q    -> TRADE_OPEN
//                              M, E -> TRADE_CLOSED
//                              C    -> TRADE_CLOSED
//                              other-> TRADE_CLOSED      (fail-closed)
//
//   'H' Stock Trading Action -> PER SYMBOL
//                              H -> TRADE_HALTED
//                              P -> TRADE_PAUSED         (LULD pause)
//                              Q -> TRADE_HALTED         (quotation only: we
//                                                         may not trade, so we
//                                                         treat it as a halt)
//                              T -> TRADE_OPEN
//                              other-> TRADE_DISABLED    (fail-closed)
//
//   'h' Operational Halt  -> PER SYMBOL, an INDEPENDENT overlay bit.
//                            action 'T' clears it; ANY other byte sets it.
//                            An operational halt and a regulatory halt are
//                            different things and can be in force at the same
//                            time; keeping them as separate state means a
//                            resumption of one does not silently clear the
//                            other. Effective state ORs them (halt wins).
//                            ⚠️ We deliberately do NOT filter on the market
//                               code byte. An operational halt on any market in
//                               the message halts the symbol for us. That is
//                               conservative in the safe direction: it can only
//                               ever stop us trading, never let us trade when
//                               we should not — and it removes a dependency on
//                               one more unverified offset.
//
//   'Y' Reg SHO           -> PER SYMBOL ssr_active (SEC Rule 201 short-sale
//                            price test). '0' clears; '1' (triggered intraday)
//                            and '2' (in force) set it; any other byte SETS it.
//                            ⚠️ This gates short sales in the risk block
//                               (risk_reason_e::RISK_SSR). Getting it wrong in
//                               the permissive direction is a regulatory
//                               violation, so the unknown case restricts.
//
//   'J' LULD Auction Collar -> PER SYMBOL upper / lower band.
//                            ⚠️ The risk gate REJECTS orders outside the band
//                               (risk_reason_e::RISK_LULD_BAND). Getting this
//                               wrong sends rejectable orders to the venue,
//                               which burns your message budget, your latency
//                               and your relationship with the venue.
//                            ⚠️⚠️ SCOPE WARNING: ITCH 'J' carries AUCTION
//                               COLLARS, which are published around auctions
//                               and LULD pauses. It is NOT the continuous LULD
//                               price band feed — that is published by the SIP
//                               (CTA / UTP LULD), which this FPGA does not
//                               consume. The host MUST write the continuous
//                               bands into risk_gate's own cfg_risk_* parameter
//                               window. Treat this side-channel as the auction
//                               overlay, never as the sole source of truth.
//
//   'K' IPO Quoting Period-> counted only (fpga_top stat word). The venue also
//                            sends 'H' Trading Action for the symbol, which is
//                            what actually gates us.
//
//   'V' MWCB Decline Level-> counted only. The absolute index levels are not
//                            needed on the fast path.
//   'W' MWCB Status       -> breached level, STICKY, host-clearable.
//                            Level 1 / 2 -> sess_state forced TRADE_HALTED.
//                            ⚠️ Level 3   -> sess_state forced TRADE_CLOSED.
//                               A Level 3 breach halts the US market for the
//                               remainder of the day. This is the mechanism by
//                               which an MWCB forces the system to STOP: every
//                               strategy and the risk gate read sess_state.
//                               Clearing it is a deliberate operator action
//                               (cfg_clr_mwcb) and after a Level 3 the operator
//                               should NOT clear it.
//
// -----------------------------------------------------------------------------
// SEQUENCE GAPS AND THE STALE-BOOK POLICY (feed-handler-design.md §8)
//   `s_gap` says: a message was missed. It tells you exactly one thing — YOU DO
//   NOT KNOW WHAT YOU MISSED. So EVERY active symbol goes to TRADE_STALE, not
//   some heuristic subset, and stays there until the host has resynchronised
//   and says so.
//
//   TRADE_STALE is carried as an independent overlay bit, exactly like the
//   operational halt, so the venue-derived state underneath keeps being updated
//   by 'S' / 'H' / 'h' / 'Y' / 'J' messages during the outage. When the host
//   signals resync-complete we restore the true venue state instead of
//   guessing — no state is lost to the gap.
//
//   Host resync interface (driven from feed_handler's cfg region 1):
//     cfg_resync_wr + cfg_resync_all      -> clear stale for ALL symbols,
//                                            clear the global gap flag,
//                                            rescan and republish everything
//     cfg_resync_wr + !cfg_resync_all     -> clear stale for cfg_resync_sym
//                                            only, republish that symbol
//
// -----------------------------------------------------------------------------
// ⚠️  RESET VALUE FOR EVERY SYMBOL IS TRADE_DISABLED — FAIL CLOSED
//     ta_state = TRADE_DISABLED, oper-halt = 0, stale = 0  =>  eff = DISABLED.
//     ssr_active resets to 1 (assume the short-sale price test is in force).
//     LULD bands reset to 0 / 0, which is a band nothing can be inside, so the
//     risk gate rejects until real bands are loaded.
//     sess_state resets to TRADE_CLOSED — the session genuinely is closed until
//     an ITCH System Event says otherwise, and CLOSED blocks quoting exactly as
//     DISABLED does.
//     A full republish scan is kicked off out of reset so the downstream copy
//     of the side-channel is definitely initialised rather than merely assumed.
//
// -----------------------------------------------------------------------------
// LATENCY
//   2 cycles from a venue message at this module's input to the corresponding
//   sym_state_wr pulse. 12.8 ns @ 156.25 MHz.
//     V0: update the per-symbol records, schedule the publish
//     V1: drive the output registers (including the LULD RAM read)
//   NOT on the tick-to-trade path — this is a control side-channel. Publishing
//   one cycle later than it could be costs nothing and buys fully registered
//   outputs.
//   Broadcast (gap / resync-all) takes N_ACTIVE + 2 cycles to walk the whole
//   active set, one symbol per cycle: 258 cycles = ~1.65 us. Bounded, counted
//   via the resync_pending status bit, and never blocking — the RX path keeps
//   decoding throughout (feed-handler-design.md §8 non-negotiable #2).
//   ACHIEVED: 2 cycles point update, N_ACTIVE+2 cycles broadcast.
//
// RESOURCE ESTIMATE (unmeasured, pre-synthesis)
//   LUT ~650   FF ~1,600   BRAM36 ~1   URAM 0   DSP 0
//   The three 1-bit-per-symbol overlays and the 3-bit trading-action state are
//   flip-flops (N_ACTIVE is small, and they need a genuine synchronous reset to
//   a fail-closed value, which a memory array cannot give). The 2 x PRICE_W
//   LULD band store is an inferred RAM with an output register.
// =============================================================================
`default_nettype none

module venue_state
    import trading_pkg::*;
    import itch_pkg::*;
(
    input  var logic         clk,
    input  var logic         rst,          // synchronous, active high

    // ── Venue message side-band (aligned with the symbol_filter port-B result)
    input  var logic         s_valid,
    input  var logic [7:0]   s_type,       // raw ITCH type byte
    input  var sym_idx_t     s_sym,        // active-set index
    input  var logic         s_sym_hit,    // 0 = global message or not subscribed
    input  var logic [7:0]   s_code,       // event / action / level byte
    input  var price_t       s_px_lo,      // 'J' lower auction collar
    input  var price_t       s_px_hi,      // 'J' upper auction collar

    // ── Feed gap ─────────────────────────────────────────────────────────────
    input  var logic         s_gap,

    // ── Host control (already in the `clk` domain) ───────────────────────────
    input  var logic         cfg_resync_wr,
    input  var logic         cfg_resync_all,
    input  var sym_idx_t     cfg_resync_sym,
    input  var logic         cfg_clr_mwcb,

    // ── Global session state ─────────────────────────────────────────────────
    output var trade_state_e sess_state,

    // ── Per-symbol side-channel to the strategy and the risk gate ────────────
    output var logic         sym_state_wr,
    output var sym_idx_t     sym_state_idx,
    output var trade_state_e sym_state_val,
    output var logic         sym_ssr_val,
    output var price_t       sym_luld_lo,
    output var price_t       sym_luld_hi,

    // ── Status (to the stat word) ────────────────────────────────────────────
    output var logic [1:0]   mwcb_level,      // 0 = none, else 1 / 2 / 3
    output var logic         mwcb_l3,         // Level 3: system must stop
    output var logic         gap_sticky,      // a gap is outstanding
    output var logic         resync_pending   // a republish scan is running
);

    // =========================================================================
    // 1. ⚠️ UNVERIFIED field-value encodings
    // -------------------------------------------------------------------------
    // itch_pkg.sv already defines SYSEV_*, TRADE_ACT_* and SHO_*. These three
    // are not there yet. Confirm against the TotalView-ITCH 5.0 spec PDF
    // (https://nasdaqtrader.com/Trading/TradingSpecs) and then move them into
    // itch_pkg.sv so there is one source of truth. See the ⚠️ VERIFY OFFSETS
    // block in itch_decoder.sv.
    // =========================================================================
    localparam logic [7:0] OPHALT_RESUMED = "T";   // ⚠️ VERIFY
    localparam logic [7:0] MWCB_LVL_1     = "1";   // ⚠️ VERIFY
    localparam logic [7:0] MWCB_LVL_2     = "2";   // ⚠️ VERIFY
    localparam logic [7:0] MWCB_LVL_3     = "3";   // ⚠️ VERIFY

    localparam sym_idx_t   SCAN_LAST      = sym_idx_t'(N_ACTIVE - 1);

    // =========================================================================
    // 2. Per-symbol records
    // -------------------------------------------------------------------------
    // Three independent overlays over one base state. Keeping them separate is
    // what lets a resumption of one condition avoid silently clearing another.
    //
    //   effective = stale     ? TRADE_STALE
    //             : oper_halt ? TRADE_HALTED
    //             :             trading_action_state
    // =========================================================================
    trade_state_e         ta_state_q [N_ACTIVE];   // from 'H'
    logic                 oh_halt_q  [N_ACTIVE];   // from 'h'
    logic                 ssr_q      [N_ACTIVE];   // from 'Y'
    logic                 stale_q    [N_ACTIVE];   // from s_gap
    logic [2*PRICE_W-1:0] luld_q     [N_ACTIVE];   // from 'J', {hi, lo}

    // Global
    trade_state_e sysev_q;
    logic [1:0]   mwcb_lvl_q;
    logic         gap_sticky_q;

    // Publish pipeline stage V0 -> V1
    logic     pend_q;
    sym_idx_t pend_idx_q;

    // Broadcast scan
    logic     scan_q;
    sym_idx_t scan_idx_q;

    // ⚠️ FAIL-CLOSED POWER-ON STATE for the LULD RAM. `rst` cannot clear a
    //    memory array; 0 / 0 is a band nothing can be inside, so the risk gate
    //    rejects every order for a symbol whose bands have never been loaded.
    initial begin
        for (int unsigned i = 0; i < N_ACTIVE; i++) begin
            luld_q[i] = '0;
        end
    end

    // Effective state. Synthesises to a mux over N_ACTIVE entries; it is read
    // once per publish, on a non-critical path.
    function automatic trade_state_e eff_state(input sym_idx_t i);
        if (stale_q[i])        return TRADE_STALE;
        else if (oh_halt_q[i]) return TRADE_HALTED;
        else                   return ta_state_q[i];
    endfunction

    // =========================================================================
    // 3. Message decode (V0, combinational)
    // =========================================================================
    logic                 ta_wr;
    logic                 oh_wr;
    logic                 ssr_wr;
    logic                 luld_wr;
    trade_state_e         ta_next;
    logic                 oh_next;
    logic                 ssr_next;
    logic [2*PRICE_W-1:0] luld_wdata;
    logic                 do_emit;      // this message needs a republish
    trade_state_e         sysev_d;
    logic [1:0]           mwcb_d;

    always_comb begin
        // ── Defaults on EVERY path. No latches. ──────────────────────────────
        ta_wr      = 1'b0;
        oh_wr      = 1'b0;
        ssr_wr     = 1'b0;
        luld_wr    = 1'b0;
        ta_next    = TRADE_DISABLED;    // fail-closed
        oh_next    = 1'b1;              // fail-closed
        ssr_next   = 1'b1;              // fail-closed
        luld_wdata = '0;
        do_emit    = 1'b0;
        sysev_d    = sysev_q;
        mwcb_d     = mwcb_lvl_q;

        if (s_valid) begin
            case (s_type)

                // ── Global session state ─────────────────────────────────────
                MSG_SYSTEM_EVENT: begin
                    case (s_code)
                        SYSEV_START_MESSAGES,
                        SYSEV_START_SYSTEM  : sysev_d = TRADE_PREOPEN;
                        SYSEV_START_MARKET  : sysev_d = TRADE_OPEN;
                        SYSEV_END_MARKET,
                        SYSEV_END_SYSTEM,
                        SYSEV_END_MESSAGES  : sysev_d = TRADE_CLOSED;
                        default             : sysev_d = TRADE_CLOSED;  // fail-closed
                    endcase
                end

                // ── Per-symbol regulatory trading action ─────────────────────
                MSG_TRADING_ACTION: begin
                    if (s_sym_hit) begin
                        ta_wr   = 1'b1;
                        do_emit = 1'b1;
                        case (s_code)
                            TRADE_ACT_HALTED    : ta_next = TRADE_HALTED;
                            TRADE_ACT_PAUSED    : ta_next = TRADE_PAUSED;
                            TRADE_ACT_QUOTEONLY : ta_next = TRADE_HALTED;
                            TRADE_ACT_TRADING   : ta_next = TRADE_OPEN;
                            default             : ta_next = TRADE_DISABLED; // fail-closed
                        endcase
                    end
                end

                // ── Per-symbol operational halt overlay ──────────────────────
                MSG_OPERATIONAL_HALT: begin
                    if (s_sym_hit) begin
                        oh_wr   = 1'b1;
                        do_emit = 1'b1;
                        oh_next = (s_code != OPHALT_RESUMED);   // fail-closed
                    end
                end

                // ── Per-symbol Reg SHO Rule 201 short-sale price test ────────
                MSG_REG_SHO: begin
                    if (s_sym_hit) begin
                        ssr_wr   = 1'b1;
                        do_emit  = 1'b1;
                        ssr_next = (s_code != SHO_NONE);        // fail-closed
                    end
                end

                // ── Per-symbol LULD auction collar ───────────────────────────
                MSG_LULD_COLLAR: begin
                    if (s_sym_hit) begin
                        luld_wr    = 1'b1;
                        do_emit    = 1'b1;
                        luld_wdata = {s_px_hi, s_px_lo};
                    end
                end

                // ── Market-Wide Circuit Breaker breach ───────────────────────
                // Sticky and monotonic: a breach never un-breaches itself.
                MSG_MWCB_STATUS: begin
                    case (s_code)
                        MWCB_LVL_1 : if (mwcb_lvl_q < 2'd1) mwcb_d = 2'd1;
                        MWCB_LVL_2 : if (mwcb_lvl_q < 2'd2) mwcb_d = 2'd2;
                        MWCB_LVL_3 :                        mwcb_d = 2'd3;
                        // An unrecognised breach code still means "the market
                        // just breached something". Halt (level 1), which
                        // blocks quoting and is host-clearable, rather than
                        // closing for the day on a byte we could not parse.
                        default    : if (mwcb_lvl_q < 2'd1) mwcb_d = 2'd1;
                    endcase
                end

                // 'K' IPO Quoting and 'V' MWCB Decline Level are counted in
                // feed_handler and carry no state here.
                default: begin
                    // no override — defaults stand
                end
            endcase
        end

        // The host's clear wins over everything decoded this cycle.
        if (cfg_clr_mwcb) begin
            mwcb_d = 2'd0;
        end
    end

    // =========================================================================
    // 4. Gap / resync triggers
    // =========================================================================
    logic gap_trig;
    logic resync_all_trig;
    logic resync_one_trig;

    assign gap_trig        = s_gap && !gap_sticky_q;
    assign resync_all_trig = cfg_resync_wr &&  cfg_resync_all;
    assign resync_one_trig = cfg_resync_wr && !cfg_resync_all;

    // =========================================================================
    // 5. Publish arbitration (V0)
    // -------------------------------------------------------------------------
    // A venue message always wins; the broadcast scan simply holds for a cycle.
    // No update can be lost by this: a message for a symbol the scan has
    // already passed publishes itself, and a message for a symbol the scan has
    // not reached yet will be picked up with its new value when the scan gets
    // there (the arrays are updated in the same cycle).
    // =========================================================================
    logic     emit_en;
    sym_idx_t emit_idx;
    logic     scan_hold;

    always_comb begin
        emit_en   = 1'b0;
        emit_idx  = '0;
        scan_hold = 1'b0;

        if (do_emit) begin
            emit_en   = 1'b1;
            emit_idx  = s_sym;
            scan_hold = 1'b1;
        end else if (resync_one_trig) begin
            emit_en   = 1'b1;
            emit_idx  = cfg_resync_sym;
            scan_hold = 1'b1;
        end else if (scan_q) begin
            emit_en   = 1'b1;
            emit_idx  = scan_idx_q;
        end
    end

    // =========================================================================
    // 6. State registers (V0)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            // ⚠️ FAIL-CLOSED RESET. Every symbol is TRADE_DISABLED.
            for (int unsigned i = 0; i < N_ACTIVE; i++) begin
                ta_state_q[i] <= TRADE_DISABLED;
                oh_halt_q[i]  <= 1'b0;   // overlay clear -> eff = DISABLED
                stale_q[i]    <= 1'b0;   // overlay clear -> eff = DISABLED
                ssr_q[i]      <= 1'b1;   // assume the price test is in force
            end
            sysev_q      <= TRADE_CLOSED;
            mwcb_lvl_q   <= 2'd0;
            gap_sticky_q <= 1'b0;
            pend_q       <= 1'b0;
            pend_idx_q   <= '0;
            // Republish the whole active set out of reset so the downstream
            // copy of the side-channel is initialised, not assumed.
            scan_q       <= 1'b1;
            scan_idx_q   <= '0;
        end else begin
            sysev_q    <= sysev_d;
            mwcb_lvl_q <= mwcb_d;

            // ── Per-symbol record updates ────────────────────────────────────
            if (ta_wr)   ta_state_q[s_sym] <= ta_next;
            if (oh_wr)   oh_halt_q[s_sym]  <= oh_next;
            if (ssr_wr)  ssr_q[s_sym]      <= ssr_next;

            // ── Stale overlay ────────────────────────────────────────────────
            if (gap_trig) begin
                // We do not know what we missed: stale EVERYTHING.
                for (int unsigned i = 0; i < N_ACTIVE; i++) begin
                    stale_q[i] <= 1'b1;
                end
                gap_sticky_q <= 1'b1;
            end else if (resync_all_trig) begin
                for (int unsigned i = 0; i < N_ACTIVE; i++) begin
                    stale_q[i] <= 1'b0;
                end
                gap_sticky_q <= 1'b0;
            end else if (resync_one_trig) begin
                // Per-symbol resync clears that symbol only. The global gap
                // flag stays set until the host issues a resync-all.
                stale_q[cfg_resync_sym] <= 1'b0;
            end

            // ── Broadcast scan control ───────────────────────────────────────
            if (gap_trig || resync_all_trig) begin
                scan_q     <= 1'b1;
                scan_idx_q <= '0;
            end else if (scan_q && !scan_hold) begin
                if (scan_idx_q == SCAN_LAST) begin
                    scan_q     <= 1'b0;
                    scan_idx_q <= '0;
                end else begin
                    scan_idx_q <= scan_idx_q + sym_idx_t'(1);
                end
            end

            // ── Publish schedule ─────────────────────────────────────────────
            pend_q     <= emit_en;
            pend_idx_q <= emit_idx;
        end

        // LULD band store. Datapath: no reset (see the `initial` above for the
        // fail-closed power-on value). Written at V0 so the V1 read below sees
        // the new value with no bypass mux needed.
        if (luld_wr) begin
            luld_q[s_sym] <= luld_wdata;
        end
    end

    // =========================================================================
    // 7. Output registers (V1)
    // -------------------------------------------------------------------------
    // Every side-channel output is a genuine flip-flop. sym_luld_* come
    // straight off the RAM output register.
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            sym_state_wr <= 1'b0;
            sess_state   <= TRADE_CLOSED;
        end else begin
            sym_state_wr <= pend_q;
            // A Level 3 MWCB CLOSES the session; Level 1 / 2 halt it. Both
            // override whatever the last System Event said, and both are
            // sticky until a deliberate host clear.
            sess_state   <= (mwcb_d == 2'd3) ? TRADE_CLOSED :
                            (mwcb_d != 2'd0) ? TRADE_HALTED : sysev_d;
        end

        // Datapath: no reset. Qualified by sym_state_wr.
        sym_state_idx <= pend_idx_q;
        sym_state_val <= eff_state(pend_idx_q);
        sym_ssr_val   <= ssr_q[pend_idx_q];
        {sym_luld_hi, sym_luld_lo} <= luld_q[pend_idx_q];
    end

    // =========================================================================
    // 8. Status outputs
    // =========================================================================
    assign mwcb_level     = mwcb_lvl_q;
    assign mwcb_l3        = (mwcb_lvl_q == 2'd3);
    assign gap_sticky     = gap_sticky_q;
    assign resync_pending = scan_q;

    // =========================================================================
    // 9. Assertions — simulation only
    // =========================================================================
`ifndef SYNTHESIS

    // The publish pipeline is exactly 2 cycles and never drops a scheduled
    // update.
    p_publish_latency: assert property (@(posedge clk) disable iff (rst)
        pend_q |=> sym_state_wr
    ) else $error("venue_state: a scheduled publish was dropped");

    // ⚠️ A stale symbol must publish TRADE_STALE. This is the single property
    //    that stands between a sequence gap and trading on a phantom book.
    p_stale_published: assert property (@(posedge clk) disable iff (rst)
        (pend_q && stale_q[pend_idx_q])
            |=> (sym_state_wr && (sym_state_val == TRADE_STALE))
    ) else $error("venue_state: a stale symbol did not publish TRADE_STALE");

    // A gap must stale every symbol, so nothing may publish TRADE_OPEN in the
    // cycle after the gap is taken.
    p_gap_stales_all: assert property (@(posedge clk) disable iff (rst)
        gap_trig |=> !(sym_state_wr && (sym_state_val == TRADE_OPEN))
    ) else $error("venue_state: published TRADE_OPEN immediately after a gap");

    // ⚠️ A Level 3 MWCB must stop the system.
    p_mwcb_l3_closes: assert property (@(posedge clk) disable iff (rst)
        mwcb_l3 |-> (sess_state == TRADE_CLOSED)
    ) else $error("venue_state: Level 3 MWCB did not close the session");

    // MWCB level is monotonic until the host clears it.
    p_mwcb_monotonic: assert property (@(posedge clk) disable iff (rst)
        !cfg_clr_mwcb |=> (mwcb_lvl_q >= $past(mwcb_lvl_q))
    ) else $error("venue_state: MWCB level went backwards without a host clear");

    // A published LULD band must be a band, not an inverted pair. All-zero is
    // the legitimate "no band loaded" value and is excluded.
    p_luld_ordered: assert property (@(posedge clk) disable iff (rst)
        (sym_state_wr && ((sym_luld_hi != 32'd0) || (sym_luld_lo != 32'd0)))
            |-> (sym_luld_hi > sym_luld_lo)
    ) else $error("venue_state: LULD upper band is not above the lower band — VERIFY OFF_J_UPPER / OFF_J_LOWER");

    // The broadcast scan is bounded. Once started it must finish.
    p_scan_bounded: assert property (@(posedge clk) disable iff (rst)
        $rose(scan_q) |-> ##[1:(2*N_ACTIVE)] !scan_q
    ) else $error("venue_state: republish scan did not terminate");

    // Reset must leave every symbol disabled. Checked on the first publish
    // after reset, which the reset-kicked scan guarantees exists.
    p_reset_disabled: assert property (@(posedge clk)
        $fell(rst) |-> ##[1:3] (sym_state_wr && (sym_state_val == TRADE_DISABLED))
    ) else $error("venue_state: reset value is not TRADE_DISABLED");

`endif

endmodule : venue_state

`default_nettype wire
