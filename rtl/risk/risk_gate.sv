// =============================================================================
// risk_gate.sv — Pre-trade risk gate. THE ONLY PATH FROM STRATEGY TO THE WIRE.
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Layer   : rtl/risk — top of the pre-trade risk layer, instantiated by fpga_top
// Governs : manuals/08-nasdaq/09-risk-controls-and-limits.md   (the check list)
//           manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md
//           manuals/08-nasdaq/06-regnms-and-compliance.md      (the rules)
//           manuals/03-algotrading/06-risk-and-compliance.md
//           CLAUDE.md §5 rules 5, 6, 7
//
// -----------------------------------------------------------------------------
// PURPOSE
//   Evaluate every order request the strategy produces against the complete
//   pre-trade check list, in parallel, in a fixed two cycles, and emit it only
//   if EVERY check passed. There is no bypass, no debug mux, no synthesis-time
//   escape hatch. `m_out_valid` is assigned in exactly one place in this file
//   and nowhere else in the design.
//
//   ⚠️ "Unfiltered" or "naked" access — an order reaching an exchange without
//   passing the broker-dealer's pre-trade controls — is prohibited by SEC Rule
//   15c3-5. That prohibition is the reason this module has no bypass parameter.
//   A "debug mode" that writes an order straight to the TX FIFO is not a debug
//   feature; it is unfiltered access.
//
// -----------------------------------------------------------------------------
// LATENCY — 2 CYCLES, 12.8 ns @ 156.25 MHz. FIXED. ACHIEVED.
//   Matches the fpga_top.sv budget row "Pre-trade risk gate  2  12.8  198.8"
//   and rows T0/T1 in 04-system-architecture/05-*.md §12.
//
//     T0 (1 cyc) : ALL cheap checks evaluated IN PARALLEL from a pre-fetched
//                  parameter/state/position record; two DSP multiplies launched
//                  (order notional, and the Rule 612 divide-by-100 reciprocal,
//                  reduced to the 7-bit residue px mod 100). Results registered
//                  as a 26-bit failure vector.
//     T1 (1 cyc) : the arithmetic checks that consume the DSP results, plus the
//                  per-symbol tick-class lookup on the residue, ORed into the
//                  vector; priority-encode the reason; register the output.
//
//   ⚠️ THE 2-CYCLE FIGURE IS ACHIEVED BY PARALLEL EVALUATION, NOT BY CHAINING.
//   The checks are not a sequence of tests. Every condition is computed
//   simultaneously and reduced; the "ordering" below is the ordering of
//   REPORTING (which reason is attributed when several fail), never of
//   evaluation. Adding a check costs one more bit in the vector and one more
//   input to the reduce — it does not cost a cycle. That property is what keeps
//   the check list complete instead of negotiable.
//
//   ⚠️ A REJECT COSTS EXACTLY THE SAME 2 CYCLES AS A PASS. Deliberately. If
//   rejects were cheaper, the latency of the order path would leak our own risk
//   state into our own timing measurements, and — more practically — would put
//   data-dependent jitter on the one path where everything is measured.
//
//   ⚠️ LOGIC-DEPTH RISK — THE HONEST ASSESSMENT.
//     The T0 critical path is:
//         s_req port → 4-slot prefetch mux (1 LUT level)
//                    → 32×24 and 32×32 DSP multiplies
//                    → product register
//     The DSP multiplies are the risk. A 32×32 unsigned multiply on UltraScale+
//     is 4 DSP48E2 slices with the internal cascade adder and NO internal
//     pipeline register (we cannot afford one), estimated 4.5–5.5 ns against a
//     6.4 ns period. That is the tightest path in this module and probably in
//     the tick-to-trade path.
//     Mitigations already applied: the qty operand is clamped to 24 bits (see
//     the width analysis below), which halves the notional multiply; both
//     multiplies take their operands directly from module ports so no LUT logic
//     precedes them; the parameter record is pre-fetched so no memory read is on
//     the path.
//     ⚠️ IF P&R MISSES TIMING, THE SANCTIONED FIX IS A THIRD PIPELINE STAGE —
//     and that is a change to the SYSTEM latency budget in fpga_top.sv, not a
//     local edit. Do not silently add a register here. Do not "fix" it by
//     precomputing max_qty = max_notional/px on the host either: that number is
//     approximate (which price?) and stale, and if the market has moved it is
//     approximate in the WRONG direction. Precompute is free everywhere else in
//     this system; it is not free here. Spend the DSPs.
//     The T1 path (24-bit priority encoder + 64-bit compares) is ~4 LUT levels
//     plus a carry chain and is not expected to be critical.
//
//   Prefetch (off the order path, costs 0 of the 2 cycles): the parameter,
//   venue-state, band-freshness and position records are read speculatively when
//   `book_top` arrives, two cycles before the strategy can possibly emit a
//   request for that symbol.
//
// -----------------------------------------------------------------------------
// ⚠️⚠️ WHERE THE LULD BANDS COME FROM — AND WHERE THEY DO NOT
//   The continuous LULD price bands come from the SIP (the LULD Plan's
//   processor). THIS FPGA DOES NOT CONSUME THE SIP. They are therefore
//   HOST-WRITTEN, per symbol, into the CRC-committed risk parameter record
//   (`sym_risk_t.luld_lo` / `.luld_hi` / `.luld_valid`), and that record is the
//   ONLY band source this gate reads.
//
//   ⚠️ THE BUG THIS REPLACES. The bands were previously taken from the feed
//   handler's decode of ITCH message `J`. ITCH `J` is the **LULD Auction
//   Collar**: the collar prices for a REOPENING AUCTION after a pause. It is not
//   the continuous band, it is published only around auctions, and for a symbol
//   that never pauses it never arrives at all. The bands therefore sat at 0/0
//   for essentially the whole session and — because this gate is correctly
//   fail-closed — EVERY ORDER WAS REJECTED, ALL DAY. Two different regulatory
//   objects had been given one name, and the name is what hid it. The auction
//   collars are still carried here, as `auc_lo`/`auc_hi` in the venue-state
//   record, under a name that cannot be mistaken for a band.
//
//   ⚠️ THREE DISTINCT, SEPARATELY COUNTED OUTCOMES. "No bands loaded" and "price
//   outside a live band" are not the same event — the first is a control-plane
//   outage, the second is the market moving — and one counter for both is
//   undebuggable in production. The three are made MUTUALLY EXCLUSIVE, not
//   priority-ordered, so each counter means exactly one thing:
//       luld_valid = 0                        -> RISK_LULD_NOT_LOADED
//       luld_valid = 1, record older than
//         the host-written freshness bound    -> RISK_LULD_STALE
//       luld_valid = 1, fresh, price outside  -> RISK_LULD_BAND
//
//   ⚠️ BAND FRESHNESS. `luld_valid` alone is not enough: a band published at
//   09:30 and never refreshed is worse than no band, because it looks like a
//   control. Freshness is measured per symbol from the last SUCCESSFUL parameter
//   commit for that symbol (the commit IS the band write), against the global
//   host-written bound `greg[G_LULDAGE]` in core clock cycles. Bound = 0 means
//   "never programmed" and is reported as RISK_PARAM_INVALID, not as staleness,
//   so an unconfigured control plane is never mistaken for a stale market.
//
//   ⚠️ WHAT THIS OBLIGES THE HOST TO DO — this is a NEW obligation, and if it is
//   not met the system does not trade:
//     * subscribe to the SIP band feed off-box;
//     * write luld_lo / luld_hi / luld_valid=1 into each enabled symbol's risk
//       record and re-commit it whenever the band moves, and in any case more
//       often than greg[G_LULDAGE] cycles;
//     * clear luld_valid (and re-commit) when the band becomes unknown — after a
//       pause, a SIP outage, a symbol-table reload, or at start of day.
//   Band updates go through the same CRC-checked, read-backable, counted commit
//   path as every other limit. That is deliberate: under 15c3-5(b) a band is a
//   pre-trade control input, and inputs to pre-trade controls belong in the
//   control plane, not on a side-channel from the market-data path.
//

// -----------------------------------------------------------------------------
// ⚠️ PREFETCH COHERENCY RULE — how this design stays fail-closed
//   A prefetched record is a cached copy, and a cached risk limit is a hazard.
//   A slot is therefore INVALIDATED, and the order consequently REJECTED with
//   RISK_PARAM_INVALID, on ANY of:
//       * age > `pf_max_age_cyc` (default 8 cycles) — the request must belong to
//         the book event that caused it;
//       * any position/working-share/open-order update for that symbol
//         (position_monitor.upd_notify) — so a fill can never be missed;
//       * any parameter commit for that symbol, or any commit in progress —
//         which is also what makes a newly committed LULD band visible on the
//         very next prefetch rather than up to `pf_max_age_cyc` later;
//       * any venue-state write for that symbol (halt, auction collar, SSR);
//       * a symbol mismatch against the request;
//       * kill or reset — everything invalidates.
//   Every one of these turns "I might be stale" into "reject", never into
//   "allow because probably fine". Rejections from this cause are counted
//   separately (`pf_miss_cnt`, stat[5]) because a non-zero rate means the
//   pipeline assumptions are wrong, not that the market is busy.
//
// -----------------------------------------------------------------------------
// ⚠️ NOTIONAL MULTIPLY — WIDTH ANALYSIS PROVING NO OVERFLOW
//   notional = price × qty, both ITCH-native scaled integers (price has 4
//   implied decimals).
//     price : 32 bits unsigned, max 2^32 − 1        ($429,496.7295)
//     qty   : 32 bits unsigned, CLAMPED to HARD_MAX_QTY = 2^24 − 1 for the
//             multiply operand only (16,777,215 shares)
//     product ≤ (2^32 − 1)(2^24 − 1) < 2^56
//     result held in notional_t = 64 bits  ⇒  8 bits of headroom.
//     THE PRODUCT CANNOT OVERFLOW. No saturation is needed on the multiply
//     itself; the accumulate into gross notional saturates (sat_add64).
//
//   ⚠️ WHY CLAMPING THE OPERAND IS SAFE (this is the load-bearing argument):
//   clamping REDUCES the product, and a smaller notional is the direction that
//   could let a bad order through. It cannot, because `qty > HARD_MAX_QTY`
//   independently and unconditionally sets RISK_MAX_SHARES in the SAME failure
//   vector, in the same cycle. An order whose quantity is large enough for the
//   clamp to matter is already rejected on size before the notional check is
//   consulted. The clamp exists only to bound the multiplier to 32×24 (≈4
//   DSP48E2 instead of ≈8) so it closes timing in one cycle.
//   HARD_MAX_QTY is an absolute build-time ceiling, independent of, and always
//   tighter-or-equal in effect to, the per-symbol `max_order_qty`.
//
// -----------------------------------------------------------------------------
// RESOURCE BUDGET (estimate, pre-synthesis, VU9P-class — this module + children)
//   LUT   ~9,900      (prefetch muxes, comparator bank, dup CAM, glue,
//                      +~200 LUTRAM for the 256×48 band-stamp memory,
//                      +~200 for its second read port and the age subtract)
//   FF    ~9,300      (4 prefetch slots ≈ 2.7k, config regs, counters, logs,
//                      +256 band-stamped bits, +32 free-cycle counter widening)
//   BRAM  ~9          (risk_params active + shadow banks)
//   URAM  0
//   DSP   ~8          (4: notional 32×24; 4: Rule 612 reciprocal 32×32)
//   ⚠️ DSP COUNT IS UNCHANGED BY THE PER-SYMBOL TICK SIZE. The reciprocal
//   constant does not depend on tick_class — one residue serves every regime —
//   so making the tick per-symbol cost a 7-bit lookup, not a second multiplier.
//   Within the fpga_top budget (LUT<60k, FF<90k, BRAM<300, DSP<16), but note
//   that this block alone is half the DSP budget. See the Rule 612 note below
//   for the reduction available if DSP pressure appears.
//
// -----------------------------------------------------------------------------
// REGULATORY OBLIGATIONS IMPLEMENTED BY THIS MODULE
//   * SEC Rule 15c3-5(b)      — controls under the broker-dealer's direct and
//                               exclusive control; no fast-path or strategy
//                               logic can write a limit.
//   * SEC Rule 15c3-5(c)(1)(i)  — pre-set credit/capital thresholds:
//                               RISK_MAX_NOTIONAL, RISK_POS_LIMIT,
//                               RISK_GROSS_LIMIT, RISK_NO_CREDIT.
//   * SEC Rule 15c3-5(c)(1)(ii) — erroneous-order controls: RISK_MAX_SHARES,
//                               RISK_PRICE_COLLAR, RISK_DUPLICATE,
//                               RISK_ZERO_QTY, RISK_ZERO_PRICE,
//                               RISK_BOOK_STALE, RISK_MSG_RATE.
//   * SEC Rule 15c3-5(c)(2)   — regulatory controls applied pre-trade:
//                               RISK_SUB_PENNY, RISK_LULD_BAND,
//                               RISK_LULD_NOT_LOADED, RISK_LULD_STALE, RISK_SSR,
//                               RISK_SYM_HALTED, RISK_SESSION_CLOSED,
//                               RISK_RESTRICTED, RISK_SYM_DISABLED.
//   * SEC Rule 612            — RISK_SUB_PENNY, evaluated against the SYMBOL'S
//                               OWN minimum pricing increment
//                               (sym_risk_t.tick_class), not a hardcoded penny.
//   * Reg SHO Rule 201        — RISK_SSR (short sale strictly above the NBB).
//   * Reg SHO 203(b) / firm policy — RISK_RESTRICTED (locate / hard-to-borrow).
//   * LULD Plan               — RISK_LULD_BAND / _NOT_LOADED / _STALE, from
//                               host-published SIP bands (see above).
//   * Nasdaq halt rules       — RISK_SYM_HALTED, RISK_SESSION_CLOSED.
//   * FINRA Rule 5210         — RISK_SELF_MATCH (wash-trade prevention,
//                               defence in depth behind the venue's own SMP).
//   * SEC Rule 611            — the ISO bit is structurally absent from
//                               order_out_t; there is no field to set. The OUCH
//                               encoder must tie it to 0 and CI must verify it.
//   * CLAUDE.md §5 rule 7     — every rejection is counted and attributable.
//
// -----------------------------------------------------------------------------
// ⚠️ KNOWN GAPS — CHECKS SPECIFIED IN 08-nasdaq/09-*.md §1 THAT sym_risk_t
//    CANNOT EXPRESS. These are NOT silently dropped; they are listed here and in
//    rtl/risk/README.md so the compliance owner can accept them or the package
//    contract can be extended (a trading_pkg change is a system-wide change).
//      #11 locate quantity (Reg SHO 203(b)) — sym_risk_t has `shortable` but no
//          `locate_qty`. The risk owner must only set `shortable` when a locate
//          exists for the intended size. Coarser than the manual specifies.
//      #12 long-sale backing (Reg SHO 200(g)) — no `long_avail_qty` field. A
//          sell that is not marked short is not verified against inventory.
//      #26 ISO — structurally satisfied (no field exists), see above.
//      #27/#28 force_post_only / allow_taking — implemented as a GLOBAL flag
//          (FLAGS.force_post_only, reset value 1) ORed into m_out.post_only
//          rather than per-symbol. A post-only order cannot remove liquidity, so
//          this subsumes allow_taking = 0. No new reject code was invented;
//          risk_reason_e is the package contract.
//      #6 per-symbol staleness threshold (`stale_ns`) — no field; the global
//          `pf_max_age_cyc` plus the book's own `stale`/`crossed` flags are used.
//          The LULD band freshness bound (`greg[G_LULDAGE]`) is likewise global
//          rather than per-symbol: the bound is a firm policy about how stale a
//          band may be, not a property of an instrument. If a per-symbol bound is
//          ever required it is a `sym_risk_t` field and therefore a package
//          change, not a local edit.
//      #10 the LULD-derived limit/straddle states are not tracked. Only the band
//          itself is enforced. A symbol pinned at its band is rejected on price,
//          not on state.
//
// ⚠️ THE ITCH `J` AUCTION COLLAR IS CARRIED BUT NOT ENFORCED AS A GATE.
//   `auc_lo`/`auc_hi` are stored per symbol and are readable through the
//   read-back mux (selector 2, sub-index 1/2) for diagnostics and for proving
//   the feed decode is alive. They are deliberately NOT turned into a price
//   check, because every state in which an auction collar applies
//   (TRADE_AUCTION, TRADE_PAUSED) already rejects all order entry via
//   RISK_SYM_HALTED. A check that can never fire is worse than no check: it
//   creates the appearance of a control and it can never be covered, which
//   would silently defeat the "every reason must be observed to reject" gate in
//   §12. If order entry during a reopening auction is ever enabled, THAT is when
//   an `RISK_AUCTION_COLLAR` reason and its counter get added — together.
//
// =============================================================================
`default_nettype none

module risk_gate
    import trading_pkg::*;
#(
    // MUST match fpga_top.sv. The kill switch closes this gate in 1 cycle; this
    // is the budget the top-level assertion holds us to.
    parameter int unsigned KILL_RESP_CYCLES = 4,
    // Prefetch slots. 2 suffices for the strategy's 2-cycle pipeline; 4 is
    // margin. Each slot is ~670 FF.
    parameter int unsigned PF_DEPTH         = 4,
    // Duplicate-order detector depth (exact match CAM, not a hash — no false
    // positives, and at this depth it is cheaper than a hash table).
    parameter int unsigned DUP_DEPTH        = 8,
    // Circular log of the last N rejected orders, in full.
    parameter int unsigned REJ_LOG_DEPTH    = 16,
    // Absolute build-time share ceiling. Bounds the notional multiplier to
    // 32×24. See the width analysis in the header.
    parameter logic [31:0] HARD_MAX_QTY     = 32'h00FF_FFFF
) (
    input  var logic         clk,
    input  var logic         rst,              // synchronous, active high

    // ── Strategy request in ──────────────────────────────────────────────────
    input  var order_req_t   s_req,
    input  var logic         s_req_valid,

    // ── Order out — ONLY ever produced when every check passed ───────────────
    output var order_out_t   m_out,
    output var logic         m_out_valid,

    // ── Venue state ──────────────────────────────────────────────────────────
    input  var trade_state_e sess_state,
    input  var logic         sym_state_wr,
    input  var sym_idx_t     sym_state_idx,
    input  var trade_state_e sym_state_val,
    input  var logic         sym_ssr_val,
    // ⚠️ RENAMED, DELIBERATELY AND BREAKINGLY. These are the ITCH `J` LULD
    // AUCTION COLLAR prices from the feed handler. They are NOT the continuous
    // LULD bands and must never again be wired to anything called `luld`. The
    // bands are read from the risk parameter record; see the header.
    // ⚠️ fpga_top.sv and rtl/feed/venue_state.sv still name these `sym_luld_*`
    // and MUST be renamed to match — an elaboration error is the intended
    // outcome until they are, because a silent rename is how this bug survived.
    input  var price_t       sym_auc_collar_lo,
    input  var price_t       sym_auc_collar_hi,
    input  var book_top_t    book_top,
    input  var logic         book_top_valid,

    // ── Kill switch ──────────────────────────────────────────────────────────
    input  var logic         host_kill,
    input  var logic         host_heartbeat,
    input  var logic         ext_kill,
    input  var logic         link_down,
    output var logic         kill_active,
    output var kill_src_e    kill_src,

    // ── Host risk control plane (separate BAR region from the strategy's) ────
    input  var logic         cfg_param_wr,
    // addr[14:12] are reserved (region-select expansion); decoded as 0 today.
    /* verilator lint_off UNUSEDSIGNAL */
    input  var logic [15:0]  cfg_param_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  var logic [31:0]  cfg_param_data,
    input  var logic         cfg_commit,
    input  var logic         cfg_trading_en,

    // ── Fill feedback ────────────────────────────────────────────────────────
    input  var logic         fill_valid,
    input  var sym_idx_t     fill_sym,
    input  var side_e        fill_side,
    input  var qty_t         fill_qty,
    input  var price_t       fill_px,

    // ── In-flight credit from the order gateway ──────────────────────────────
    input  var logic         credit_avail,

    // ── Telemetry ────────────────────────────────────────────────────────────
    output var logic [31:0]  reject_cnt [N_RISK_REASONS],
    output var logic [31:0]  stat [8]
);

    // =========================================================================
    // Local constants
    // =========================================================================
    localparam logic [31:0] CNT32_MAX     = 32'hFFFF_FFFF;
    localparam price_t      ONE_DOLLAR    = price_t'(32'd10_000);  // $1.0000
    localparam int unsigned N_GREG        = 40;
    localparam int unsigned PF_PTR_W      = (PF_DEPTH  > 1) ? $clog2(PF_DEPTH)  : 1;
    localparam int unsigned DUP_PTR_W     = (DUP_DEPTH > 1) ? $clog2(DUP_DEPTH) : 1;
    localparam int unsigned LOG_PTR_W     = (REJ_LOG_DEPTH > 1) ? $clog2(REJ_LOG_DEPTH) : 1;
    localparam position_t   POS_MAX       = position_t'({1'b0, {(POS_W-1){1'b1}}});
    localparam position_t   POS_MIN       = position_t'({1'b1, {(POS_W-1){1'b0}}});

    // Global register indices. Full map in rtl/risk/README.md.
    localparam int unsigned G_GROSS_LO=0,  G_GROSS_HI=1,  G_NET_LO=2,   G_NET_HI=3;
    localparam int unsigned G_AGGL_LO=4,   G_AGGL_HI=5,   G_AGGS_LO=6,  G_AGGS_HI=7;
    localparam int unsigned G_MAXOPEN=8,   G_RATE_MAX=9,  G_RATE_KILL=10, G_RATE_WIN=11;
    localparam int unsigned G_WD_TMO=12,   G_REARM=13,    G_MAGIC=14,   G_SESSION=15;
    localparam int unsigned G_KILLTEST=16, G_KILLSET=17,  G_DUPWIN=18,  G_PFAGE=19;
    localparam int unsigned G_PARAMAGE=20, G_FLAGS=21,    G_PCRC=22,    G_RBADDR=23;
    localparam int unsigned G_RC_SYM=24,   G_RC_POSLO=25, G_RC_POSHI=26;
    localparam int unsigned G_RC_WKB=27,   G_RC_WKS=28,   G_RC_OPEN=29, G_RC_GO=30;
    localparam int unsigned G_GROSSRST=31, G_CLRFREJ=32;
    // ⚠️ NEW. Maximum age, in core clock cycles, of the last successful parameter
    // commit for a symbol before that symbol's LULD bands are treated as no
    // longer describing the live band. Reset 0 = never programmed = the design
    // cannot trade (reported as RISK_PARAM_INVALID, see fv0 below), which is the
    // same discipline already applied to G_DUPWIN and G_PFAGE.
    // Range: 1 .. 2^32-1 cycles = 6.4 ns .. 27.5 s @ 156.25 MHz. The ceiling is
    // deliberate — a band freshness bound longer than half a minute is not a
    // freshness bound, and if one is ever wanted the honest change is to widen
    // this register and say why, not to disable the check.
    localparam int unsigned G_LULDAGE=33;

    // FLAGS bits
    localparam int unsigned F_FORCE_PO   = 0;   // reset 1
    // ⚠️ F_LULD_REQ no longer GATES the LULD checks — they are unconditional.
    // The bit is retained at its old position, and a host that clears it is
    // REJECTED rather than obeyed (see RISK_PARAM_INVALID below). A control that
    // the controlled party can switch off is not a control, and an old host image
    // must not be able to believe it disabled a Rule/Plan check and carry on.
    localparam int unsigned F_LULD_REQ   = 1;   // reset 1, must stay 1
    localparam int unsigned F_SSR_REQ_BID= 2;   // reset 1

    // Saturate a 16-bit counter into a byte for the packed telemetry words.
    function automatic logic [7:0] sat8(input logic [15:0] v);
        return (v > 16'd255) ? 8'hFF : v[7:0];
    endfunction

    // =========================================================================
    // Forward declarations — the T0→T1 pipeline registers are referenced by the
    // token generator instance below (the token is spliced at T1) and by the
    // prefetch invalidation logic. Declared here so every use follows its
    // declaration.
    // =========================================================================
    logic                      t1_valid_q;
    order_req_t                t1_req_q;
    logic [N_RISK_REASONS-1:0] t1_fv_q;
    notional_t                 t1_notional_q, t1_max_notional_q, t1_gross_base_q,
                               t1_gross_limit_q;
    // Rule 612: the 7-bit residue px mod 100 computed at T0 from the DSP
    // reciprocal, and the symbol's minimum increment. The class-dependent lookup
    // happens at T1 — see §7.
    logic [6:0]                t1_resid100_q;
    tick_class_e               t1_tick_class_q;
    logic                      t1_px_ge_dollar_q;
    position_t                 t1_pos_base_q, t1_qty_signed_q,
                               t1_max_long_q, t1_max_short_q;
    logic                      t1_is_send_q, t1_is_cancel_q;
    logic                      accept_d, reject_d;
    risk_reason_e              verdict_d;

    // Free-running core-clock counter. Two consumers: the low 16 bits stamp the
    // reject ring log, and the full width stamps the per-symbol LULD band age.
    // ⚠️ 48 bits is not decoration. The band age is a wrapping subtract, so the
    // counter must not wrap within the interval being measured. 2^48 cycles at
    // 156.25 MHz is ~20 days; 2^32 would be 27.5 s, and a band older than that
    // would wrap and read as FRESH — a fail-OPEN. Width here is a safety
    // property, not a resource choice.
    cycle_t                    free_cyc_q;

    // =========================================================================
    // 1. Host control plane decode
    //    addr[15] = 0 : per-symbol risk record   {sym[ACT_IDX_W-1:0], word[3:0]}
    //    addr[15] = 1 : global register file     index = addr[7:0]
    //    ⚠️ This region belongs to the RISK control plane. The host driver must
    //    map it into a different BAR window from the strategy parameter region,
    //    with different write permissions — that is how 15c3-5(b) "direct and
    //    exclusive control" becomes enforceable in software rather than policy.
    // =========================================================================
    localparam int unsigned GIDX_W = $clog2(N_GREG);

    logic                 cfg_is_global;
    logic [ACT_IDX_W-1:0] cfg_sym;
    logic [3:0]           cfg_word;
    logic [7:0]           cfg_gidx;
    logic [GIDX_W-1:0]    cfg_gsel;
    logic                 greg_wr;

    assign cfg_is_global = cfg_param_addr[15];
    assign cfg_sym       = cfg_param_addr[ACT_IDX_W+3:4];
    assign cfg_word      = cfg_param_addr[3:0];
    assign cfg_gidx      = cfg_param_addr[7:0];
    assign cfg_gsel      = cfg_gidx[GIDX_W-1:0];
    // Out-of-range global writes are DROPPED, not aliased onto a real register.
    // An aliased write to a limit register is the definition of an unlogged
    // limit change.
    assign greg_wr       = cfg_param_wr && cfg_is_global && (cfg_gidx < 8'(N_GREG));

    logic [31:0] greg [N_GREG];

    // One-shot decodes for the "write-1-to-act" registers.
    logic g_hit_session, g_hit_killtest, g_hit_rearm, g_hit_recon;
    logic g_hit_grossrst, g_hit_clrfrej;
    assign g_hit_session  = greg_wr && (cfg_gidx == 8'(G_SESSION))  && cfg_param_data[0];
    assign g_hit_killtest = greg_wr && (cfg_gidx == 8'(G_KILLTEST)) && cfg_param_data[0];
    assign g_hit_rearm    = greg_wr && (cfg_gidx == 8'(G_REARM));
    assign g_hit_recon    = greg_wr && (cfg_gidx == 8'(G_RC_GO))    && cfg_param_data[0];
    assign g_hit_grossrst = greg_wr && (cfg_gidx == 8'(G_GROSSRST)) && cfg_param_data[0];
    assign g_hit_clrfrej  = greg_wr && (cfg_gidx == 8'(G_CLRFREJ))  && cfg_param_data[0];

    always_ff @(posedge clk) begin
        if (rst) begin
            // ⚠️ EVERY LIMIT RESETS TO ZERO. A limit that resets to a large
            // value is worse than no limit at all, because it creates the
            // appearance of a control. (09-*.md §2.)
            for (int unsigned g = 0; g < N_GREG; g++) greg[g] <= 32'd0;
            // ...except the FLAGS, whose SAFE value is all-ones: post-only
            // forced, LULD bands required, SSR requires a valid best bid.
            greg[G_FLAGS] <= 32'h0000_0007;
        end else if (greg_wr) begin
            greg[cfg_gsel] <= cfg_param_data;
        end
    end

    // Named views of the global registers.
    notional_t   cfg_gross_limit, cfg_net_limit;
    position_t   cfg_agg_long, cfg_agg_short;
    logic [31:0] cfg_max_open_agg, cfg_dup_window, cfg_pf_max_age, cfg_param_max_age;
    logic [31:0] cfg_luld_max_age;
    logic        flg_force_po, flg_luld_req, flg_ssr_req_bid;

    assign cfg_gross_limit   = {greg[G_GROSS_HI], greg[G_GROSS_LO]};
    assign cfg_net_limit     = {greg[G_NET_HI],   greg[G_NET_LO]};
    assign cfg_agg_long      = position_t'({greg[G_AGGL_HI][POS_W-33:0], greg[G_AGGL_LO]});
    assign cfg_agg_short     = position_t'({greg[G_AGGS_HI][POS_W-33:0], greg[G_AGGS_LO]});
    assign cfg_max_open_agg  = greg[G_MAXOPEN];
    assign cfg_dup_window    = greg[G_DUPWIN];
    assign cfg_pf_max_age    = greg[G_PFAGE];
    assign cfg_param_max_age = greg[G_PARAMAGE];
    assign cfg_luld_max_age  = greg[G_LULDAGE];
    assign flg_force_po      = greg[G_FLAGS][F_FORCE_PO];
    assign flg_luld_req      = greg[G_FLAGS][F_LULD_REQ];
    assign flg_ssr_req_bid   = greg[G_FLAGS][F_SSR_REQ_BID];

    // =========================================================================
    // 2. Sub-blocks
    // =========================================================================

    // ── 2.1 Per-symbol risk parameter table (double-buffered, CRC-committed) ─
    logic                 rp_rd_en;
    sym_idx_t             rp_rd_sym;
    sym_risk_t            rp_rec;
    logic                 rp_pv, rp_rd_valid;
    logic                 rp_commit_busy, rp_commit_done;
    logic [ACT_IDX_W-1:0] rp_commit_sym;
    logic [31:0]          rp_generation, rp_commit_age;
    logic                 rp_crc_err;
    logic [15:0]          rp_crc_fail, rp_sane_fail;
    logic [31:0]          rp_rb_data;
    logic                 rp_rb_valid;

    risk_params #(
        .N_SYM (N_ACTIVE)
    ) u_params (
        .clk             (clk),
        .rst             (rst),
        .wr_en           (cfg_param_wr && !cfg_is_global),
        .wr_sym          (cfg_sym),
        .wr_word         (cfg_word),
        .wr_data         (cfg_param_data),
        .commit          (cfg_commit),
        .commit_sym      (cfg_sym),
        .crc_expected    (greg[G_PCRC]),
        .rd_en           (rp_rd_en),
        .rd_sym          (rp_rd_sym),
        .rd_rec          (rp_rec),
        .rd_params_valid (rp_pv),
        .rd_valid        (rp_rd_valid),
        .rb_en           (1'b1),
        .rb_sym          (greg[G_RBADDR][ACT_IDX_W+3:4]),
        .rb_word         (greg[G_RBADDR][3:0]),
        .rb_shadow       (greg[G_RBADDR][12]),
        .rb_data         (rp_rb_data),
        .rb_valid        (rp_rb_valid),
        .commit_busy     (rp_commit_busy),
        .commit_done     (rp_commit_done),
        .commit_done_sym (rp_commit_sym),
        .generation      (rp_generation),
        .commit_age      (rp_commit_age),
        .crc_err         (rp_crc_err),
        .crc_fail_cnt    (rp_crc_fail),
        .sane_fail_cnt   (rp_sane_fail)
    );

    // ── 2.2 Position / exposure monitor ──────────────────────────────────────
    logic        pm_q_en;
    sym_idx_t    pm_q_sym;
    position_t   pm_q_pos;
    qty_t        pm_q_wkb, pm_q_wks;
    logic [15:0] pm_q_open;
    price_t      pm_q_own_bid, pm_q_own_ask;
    logic        pm_q_own_bid_v, pm_q_own_ask_v, pm_q_blocked, pm_q_valid;

    logic        emit_valid_d;
    sym_idx_t    emit_sym_d;
    side_e       emit_side_d;
    qty_t        emit_qty_d;
    price_t      emit_px_d;

    notional_t         pm_gross;
    logic signed [63:0] pm_net;
    position_t         pm_agg_pos;
    logic [31:0]       pm_agg_open;
    logic              pm_agg_breach, pm_pos_loaded, pm_sat_sticky;
    logic [31:0]       pm_sat_pos, pm_sat_gross, pm_sat_net, pm_sat_open;
    logic [31:0]       pm_recon_cnt, pm_drop_cnt;
    logic [39:0]       pm_recon_delta;
    logic              pm_upd_ovf, pm_notify, pm_busy;
    sym_idx_t          pm_notify_sym;

    position_monitor #(
        .N_SYM (N_ACTIVE)
    ) u_pos (
        .clk                 (clk),
        .rst                 (rst),
        .q_en                (pm_q_en),
        .q_sym               (pm_q_sym),
        .q_pos               (pm_q_pos),
        .q_work_buy          (pm_q_wkb),
        .q_work_sell         (pm_q_wks),
        .q_open              (pm_q_open),
        .q_own_bid           (pm_q_own_bid),
        .q_own_ask           (pm_q_own_ask),
        .q_own_bid_v         (pm_q_own_bid_v),
        .q_own_ask_v         (pm_q_own_ask_v),
        .q_blocked           (pm_q_blocked),
        .q_valid             (pm_q_valid),
        .emit_valid          (emit_valid_d),
        .emit_sym            (emit_sym_d),
        .emit_side           (emit_side_d),
        .emit_qty            (emit_qty_d),
        .emit_px             (emit_px_d),
        .fill_valid          (fill_valid),
        .fill_sym            (fill_sym),
        .fill_side           (fill_side),
        .fill_qty            (fill_qty),
        .fill_px             (fill_px),
        .cfg_gross_limit     (cfg_gross_limit),
        .cfg_net_limit       (cfg_net_limit),
        .cfg_agg_long_limit  (cfg_agg_long),
        .cfg_agg_short_limit (cfg_agg_short),
        .cfg_max_open_agg    (cfg_max_open_agg),
        .recon_valid         (g_hit_recon),
        .recon_sym           (sym_idx_t'(greg[G_RC_SYM][ACT_IDX_W-1:0])),
        .recon_pos           (position_t'({greg[G_RC_POSHI][POS_W-33:0], greg[G_RC_POSLO]})),
        .recon_work_buy      (qty_t'(greg[G_RC_WKB])),
        .recon_work_sell     (qty_t'(greg[G_RC_WKS])),
        .recon_open          (greg[G_RC_OPEN][15:0]),
        .recon_clear_own     (greg[G_RC_OPEN][16]),
        .recon_clear_block   (greg[G_RC_OPEN][17]),
        .recon_clear_sat     (greg[G_RC_OPEN][18]),
        .gross_reset         (g_hit_grossrst && kill_active),   // kill-gated
        .gross_notional      (pm_gross),
        .net_notional        (pm_net),
        .agg_pos             (pm_agg_pos),
        .agg_open            (pm_agg_open),
        .agg_breach          (pm_agg_breach),
        .position_loaded     (pm_pos_loaded),
        .sat_sticky          (pm_sat_sticky),
        .sat_pos_cnt         (pm_sat_pos),
        .sat_gross_cnt       (pm_sat_gross),
        .sat_net_cnt         (pm_sat_net),
        .sat_open_cnt        (pm_sat_open),
        .recon_cnt           (pm_recon_cnt),
        .recon_max_delta     (pm_recon_delta),
        .upd_drop_cnt        (pm_drop_cnt),
        .upd_overflow        (pm_upd_ovf),
        .upd_notify          (pm_notify),
        .upd_notify_sym      (pm_notify_sym),
        .upd_busy            (pm_busy)
    );

    // ── 2.3 Outbound message rate limiter ────────────────────────────────────
    logic        rl_over, rl_breach;
    logic [31:0] rl_window, rl_peak, rl_over_cnt, rl_msg_cnt;

    rate_limiter #(
        .N_SUBWIN      (8),
        .CNT_W         (32),
        .PIPE_HEADROOM (2)          // = this gate's pipeline depth
    ) u_rate (
        .clk        (clk),
        .rst        (rst),
        .subwin_cyc (greg[G_RATE_WIN]),
        .max_msgs   (greg[G_RATE_MAX]),
        .kill_msgs  (greg[G_RATE_KILL]),
        .msg_valid  (emit_valid_d),
        .over       (rl_over),
        .breach     (rl_breach),
        .window_cnt (rl_window),
        .peak_cnt   (rl_peak),
        .over_cnt   (rl_over_cnt),
        .msg_cnt    (rl_msg_cnt)
    );

    // ── 2.4 Order token generator ────────────────────────────────────────────
    logic        tk_ready, tk_exhausted, tk_near, tk_magic_valid;
    logic [15:0] tk_magic_q;
    logic [47:0] tk_counter;
    logic [31:0] tk_issued;
    token_t      tk_token;
    logic        tk_issue;

    order_token_gen u_token (
        .clk           (clk),
        .rst           (rst),
        .magic_wr      (greg_wr && (cfg_gidx == 8'(G_MAGIC))),
        .magic_in      (cfg_param_data[15:0]),
        // ⚠️ A session restart resets the token counter and is only accepted
        // while the kill switch is asserted. Restarting the token sequence with
        // orders live would let a new token alias a working one.
        .session_start (g_hit_session && kill_active),
        .issue         (tk_issue),
        .strat_id      (t1_req_q.strat_id),
        .sym           (t1_req_q.sym),
        .token         (tk_token),
        .token_ready   (tk_ready),
        .magic_q       (tk_magic_q),
        .magic_valid   (tk_magic_valid),
        .counter       (tk_counter),
        .near_exhaust  (tk_near),
        .exhausted     (tk_exhausted),
        .issued_cnt    (tk_issued)
    );

    // ── 2.5 Kill switch ──────────────────────────────────────────────────────
    logic        ks_test_fired;
    logic [15:0] ks_test_resp, ks_cnt, ks_rearm_cnt, ks_rearm_fail;
    logic [7:0]  ks_src_mask;
    logic        ks_wd_expired;
    logic [31:0] ks_wd_cnt;
    logic        seq_fault;

    // ⚠️ An exhausted token counter or a corrupt parameter bank is an
    // unrecoverable session fault: we can no longer guarantee attribution or
    // that the limits in force are the limits that were approved.
    assign seq_fault = tk_exhausted || rp_crc_err;

    kill_switch #(
        .KILL_RESP_CYCLES (KILL_RESP_CYCLES)
    ) u_kill (
        .clk             (clk),
        .rst             (rst),
        .host_kill       (host_kill || (greg_wr && (cfg_gidx == 8'(G_KILLSET))
                                                && cfg_param_data[0])),
        .host_heartbeat  (host_heartbeat),
        .ext_kill        (ext_kill),
        .link_down       (link_down),
        .rate_breach     (rl_breach),
        .pos_breach      (pm_agg_breach),
        .seq_fault       (seq_fault),
        .kill_test       (g_hit_killtest),
        .wd_timeout_cyc  (greg[G_WD_TMO]),
        .rearm_wr        (g_hit_rearm),
        .rearm_data      (cfg_param_data),
        .position_loaded (pm_pos_loaded),
        .kill_active     (kill_active),
        .kill_src        (kill_src),
        .kill_src_mask   (ks_src_mask),
        .test_fired      (ks_test_fired),
        .test_resp_cyc   (ks_test_resp),
        .kill_cnt        (ks_cnt),
        .rearm_cnt       (ks_rearm_cnt),
        .rearm_fail_cnt  (ks_rearm_fail),
        .wd_expired      (ks_wd_expired),
        .wd_cnt          (ks_wd_cnt)
    );

    // =========================================================================
    // 3. Per-symbol venue state table (halt / SSR / auction collar, from ITCH)
    //    Distributed RAM + a resettable init bitmap, so an unwritten symbol
    //    reads as TRADE_DISABLED with SSR assumed active. Fail-closed by
    //    construction.
    //    ⚠️ `auc_lo`/`auc_hi` are the ITCH `J` LULD AUCTION COLLAR prices. They
    //    are NOT the continuous LULD bands and are NOT used as a price gate —
    //    see the scope note in the header. They are stored so the collar decode
    //    is observable through the read-back mux, and so that the day someone
    //    enables order entry during a reopening auction, the data is already
    //    here under a name that says what it is.
    // =========================================================================
    typedef struct packed {
        trade_state_e st;
        logic         ssr;
        price_t       auc_lo;      // ITCH 'J' lower auction collar
        price_t       auc_hi;      // ITCH 'J' upper auction collar
    } vstate_t;

    localparam int unsigned VS_W = $bits(vstate_t);
    (* ram_style = "distributed" *) logic [VS_W-1:0] vs_mem [N_ACTIVE];
    logic vs_init_q [N_ACTIVE];

    initial begin
        for (int unsigned s = 0; s < N_ACTIVE; s++) vs_mem[s] = '0;
    end

    vstate_t vs_wr;
    always_comb begin
        vs_wr        = '0;
        vs_wr.st     = sym_state_val;
        vs_wr.ssr    = sym_ssr_val;
        vs_wr.auc_lo = sym_auc_collar_lo;
        vs_wr.auc_hi = sym_auc_collar_hi;
    end

    always_ff @(posedge clk) begin
        if (sym_state_wr) vs_mem[sym_state_idx] <= VS_W'(vs_wr);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned s = 0; s < N_ACTIVE; s++) vs_init_q[s] <= 1'b0;
        end else if (sym_state_wr) begin
            vs_init_q[sym_state_idx] <= 1'b1;
        end
    end

    // =========================================================================
    // 3b. LULD BAND FRESHNESS — per-symbol commit stamp
    // =========================================================================
    // The bands live in the CRC-committed risk record, so "when were this
    // symbol's bands last written" is exactly "when did this symbol's record
    // last commit successfully". One 48-bit stamp per symbol, written by the
    // commit engine's done pulse, plus a resettable "has ever been stamped" bit.
    //
    // ⚠️ THE STAMPED BIT IS NOT REDUNDANT with params_valid. The stamp memory has
    // no reset (it is LUTRAM), so out of reset it holds whatever it held before.
    // Without the bit, a symbol could read an ancient stamp that happens to look
    // fresh against a wrapped counter. The bit resets to 0 and only a real commit
    // sets it: unstamped ⇒ stale ⇒ reject.
    //
    // ⚠️ The age is evaluated at PREFETCH time, not at T0, so it costs zero of
    // the gate's two cycles. The slot it lands in may be up to `pf_max_age_cyc`
    // (default 8) cycles old when used, so the enforced bound is effectively
    // (G_LULDAGE + 8) cycles. Against a bound measured in seconds that is
    // 51 ns of slack in the wrong direction, and it is recorded here rather than
    // rounded away.
    (* ram_style = "distributed" *) logic [CYCLE_CNT_W-1:0] band_stamp_mem [N_ACTIVE];
    logic band_stamped_q [N_ACTIVE];

    initial begin
        for (int unsigned s = 0; s < N_ACTIVE; s++) band_stamp_mem[s] = '0;
    end

    always_ff @(posedge clk) begin
        if (rp_commit_done) band_stamp_mem[rp_commit_sym] <= free_cyc_q;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned s = 0; s < N_ACTIVE; s++) band_stamped_q[s] <= 1'b0;
        end else if (rp_commit_done) begin
            band_stamped_q[rp_commit_sym] <= 1'b1;
        end
    end

    // =========================================================================
    // 4. Prefetch — issued from book_top, OFF the order path
    // =========================================================================
    // bt_q holds the WHOLE book_top for one cycle. Only the fields the checks
    // need are copied into the prefetch slot; the rest (last_px, qty depths,
    // top_changed, rx_cycle) are captured deliberately so a future check can be
    // added without touching the prefetch timing.
    /* verilator lint_off UNUSEDSIGNAL */
    book_top_t bt_q;
    /* verilator lint_on UNUSEDSIGNAL */
    logic      bt_v_q;

    assign rp_rd_en  = book_top_valid;
    assign rp_rd_sym = book_top.sym;
    assign pm_q_en   = book_top_valid;
    assign pm_q_sym  = book_top.sym;

    vstate_t  vs_rd;
    logic     vs_rd_init;
    assign vs_rd      = vstate_t'(vs_mem[book_top.sym]);   // async read
    assign vs_rd_init = vs_init_q[book_top.sym];

    // Band-freshness reads, same stage, same index.
    cycle_t   band_stamp_rd;
    logic     band_stamped_rd;
    assign band_stamp_rd   = band_stamp_mem[book_top.sym]; // async read
    assign band_stamped_rd = band_stamped_q[book_top.sym];

    vstate_t  vs_q;
    logic     vs_init_r;
    cycle_t   band_stamp_r;
    logic     band_stamped_r;

    always_ff @(posedge clk) begin
        if (rst) begin
            bt_v_q         <= 1'b0;
            vs_init_r      <= 1'b0;
            band_stamped_r <= 1'b0;                        // ⚠️ fail-closed
        end else begin
            bt_v_q         <= book_top_valid;
            vs_init_r      <= book_top_valid ? vs_rd_init     : 1'b0;
            band_stamped_r <= book_top_valid ? band_stamped_rd : 1'b0;
        end
        if (book_top_valid) begin                          // datapath: no reset
            bt_q         <= book_top;
            vs_q         <= vs_rd;
            band_stamp_r <= band_stamp_rd;
        end
    end

    // ── Band age, evaluated OFF the order path. ──────────────────────────────
    // Unsigned wrapping subtract on a counter that cannot wrap within the
    // measured interval (see the free_cyc_q declaration), so this is an exact
    // elapsed-cycle count, not an approximation.
    cycle_t band_age_d;
    logic   bands_stale_d;
    always_comb begin
        band_age_d    = free_cyc_q - band_stamp_r;
        // ⚠️ Never stamped ⇒ stale, unconditionally, whatever the arithmetic says.
        bands_stale_d = !band_stamped_r
                     || (band_age_d > cycle_t'({16'd0, cfg_luld_max_age}));
    end

    typedef struct packed {
        logic         valid;
        sym_idx_t     sym;
        logic [7:0]   age;
        sym_risk_t    rec;
        logic         params_valid;
        logic         bands_stale;   // LULD band freshness, resolved at prefetch
        vstate_t      vs;
        logic         vs_init;
        price_t       bid_px;
        price_t       ask_px;
        logic         bid_valid;
        logic         ask_valid;
        logic         stale;
        logic         crossed;
        position_t    pos;
        qty_t         work_buy;
        qty_t         work_sell;
        logic [15:0]  open;
        price_t       own_bid;
        price_t       own_ask;
        logic         own_bid_v;
        logic         own_ask_v;
        logic         blocked;
    } pf_slot_t;

    pf_slot_t          pf [PF_DEPTH];
    logic [PF_PTR_W-1:0] pf_wr_q;

    // ⚠️ Coherency: anything that could change what a cached slot says.
    logic pf_kill_all;
    assign pf_kill_all = kill_active || rp_commit_busy;

    pf_slot_t pf_new;
    always_comb begin
        pf_new              = '0;
        pf_new.valid        = 1'b1;
        pf_new.sym          = bt_q.sym;
        pf_new.age          = 8'd0;
        pf_new.rec          = rp_rec;
        pf_new.params_valid = rp_pv;
        pf_new.bands_stale  = bands_stale_d;
        pf_new.vs           = vs_q;
        pf_new.vs_init      = vs_init_r;
        pf_new.bid_px       = bt_q.bid_px;
        pf_new.ask_px       = bt_q.ask_px;
        pf_new.bid_valid    = bt_q.bid_valid;
        pf_new.ask_valid    = bt_q.ask_valid;
        pf_new.stale        = bt_q.stale;
        pf_new.crossed      = bt_q.crossed;
        pf_new.pos          = pm_q_pos;
        pf_new.work_buy     = pm_q_wkb;
        pf_new.work_sell    = pm_q_wks;
        pf_new.open         = pm_q_open;
        pf_new.own_bid      = pm_q_own_bid;
        pf_new.own_ask      = pm_q_own_ask;
        pf_new.own_bid_v    = pm_q_own_bid_v;
        pf_new.own_ask_v    = pm_q_own_ask_v;
        pf_new.blocked      = pm_q_blocked;
    end

    logic pf_capture;
    assign pf_capture = bt_v_q && rp_rd_valid && pm_q_valid && !pf_kill_all;

    // Slot match (used at T0). Exactly one slot per symbol can be valid — a
    // capture invalidates any older slot for the same symbol — so the hit is
    // unique and the mux is a simple OR of masked slots.
    logic [PF_DEPTH-1:0] pf_hit;
    pf_slot_t            pf_sel;

    always_comb begin
        pf_hit = '0;
        pf_sel = '0;
        // ⚠️ Fail-closed default for the no-hit case. All-zero already means
        // "disabled, no bands loaded, TICK_UNSET", but all-zero ALSO means
        // bands_stale = 0, i.e. "fresh" — the one field whose safe value is 1.
        // Spelling it out here means the miss path cannot be read as a fresh band
        // even if the reason attribution above it is ever reordered.
        pf_sel.bands_stale = 1'b1;
        for (int unsigned i = 0; i < PF_DEPTH; i++) begin
            pf_hit[i] = pf[i].valid
                        && (pf[i].sym == s_req.sym)
                        && ({24'd0, pf[i].age} < cfg_pf_max_age);
        end
        for (int unsigned i = 0; i < PF_DEPTH; i++) begin
            if (pf_hit[i]) pf_sel = pf[i];
        end
    end

    logic pf_valid_hit;
    assign pf_valid_hit = |pf_hit;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned i = 0; i < PF_DEPTH; i++) pf[i] <= '0;
            pf_wr_q <= '0;
        end else begin
            for (int unsigned i = 0; i < PF_DEPTH; i++) begin
                // Default: age the slot (saturating at 255).
                if (pf[i].valid && (pf[i].age != 8'hFF)) pf[i].age <= pf[i].age + 8'd1;

                // ── Invalidation, in priority order ──────────────────────────
                if (pf_kill_all) begin
                    pf[i].valid <= 1'b0;
                end else if (pf[i].valid && (
                        ({24'd0, pf[i].age} >= cfg_pf_max_age)
                     || (pm_notify      && (pm_notify_sym  == pf[i].sym))
                     || (rp_commit_done && (rp_commit_sym  == pf[i].sym))
                     || (sym_state_wr   && (sym_state_idx  == pf[i].sym))
                     || (pf_capture     && (bt_q.sym       == pf[i].sym))
                     || (accept_d       && (t1_req_q.sym   == pf[i].sym)))) begin
                    pf[i].valid <= 1'b0;
                end else begin
                    pf[i].valid <= pf[i].valid;
                end
            end

            if (pf_capture) begin
                pf[pf_wr_q] <= pf_new;
                pf_wr_q     <= pf_wr_q + PF_PTR_W'(1);
            end else begin
                pf_wr_q <= pf_wr_q;
            end
        end
    end

    // =========================================================================
    // 5. Duplicate-order detector (exact-match CAM over a time window)
    //    ⚠️ 15c3-5(c)(1)(ii) names duplicate-order detection explicitly. An
    //    exact CAM is used rather than a hash: at DUP_DEPTH=8 it is cheaper than
    //    a hash table AND has no false positives to explain away.
    // =========================================================================
    typedef struct packed {
        logic        valid;
        sym_idx_t    sym;
        side_e       side;
        price_t      price;
        qty_t        qty;
        logic [31:0] age;
    } dup_t;

    dup_t                 dup [DUP_DEPTH];
    logic [DUP_PTR_W-1:0] dup_wr_q;
    logic                 dup_hit;

    always_comb begin
        dup_hit = 1'b0;
        for (int unsigned i = 0; i < DUP_DEPTH; i++) begin
            if (dup[i].valid
                && (dup[i].age  <  cfg_dup_window)
                && (dup[i].sym  == s_req.sym)
                && (dup[i].side == s_req.side)
                && (dup[i].price== s_req.price)
                && (dup[i].qty  == s_req.qty)) dup_hit = 1'b1;
        end
    end

    // =========================================================================
    // 6. T0 — every cheap check, IN PARALLEL
    // =========================================================================
    trade_state_e sess_state_q;
    logic         trading_en_q, credit_q, rate_over_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            sess_state_q <= TRADE_DISABLED;   // ⚠️ fail-closed reset value
            trading_en_q <= 1'b0;
            credit_q     <= 1'b0;
            rate_over_q  <= 1'b1;             // ⚠️ reset = over = reject
        end else begin
            sess_state_q <= sess_state;
            trading_en_q <= cfg_trading_en;
            credit_q     <= credit_avail;
            rate_over_q  <= rl_over;
        end
    end

    logic is_send, is_cancel, is_bad_action;
    assign is_send       = (s_req.action == ACT_SEND);
    assign is_cancel     = (s_req.action == ACT_CANCEL);
    assign is_bad_action = !(s_req.action inside {ACT_NONE, ACT_SEND, ACT_CANCEL});

    // ── LULD bands. ONE SOURCE: the CRC-committed, host-written risk record.
    //    ⚠️ The old code intersected this record with the ITCH `J` side-channel
    //    and treated 0 as "unset" in both. That conflated the continuous LULD
    //    band with the reopening-auction collar, and because `J` almost never
    //    arrives, the intersection was 0/0 all session and rejected everything.
    //    The auction collar is now `pf_sel.vs.auc_*` and is not consulted here.
    //    There is deliberately no "take the tighter of two sources" logic left:
    //    with one authoritative source there is nothing to intersect, and the
    //    absence of the intersection is what stops the two concepts re-merging.
    price_t luld_lo_eff, luld_hi_eff;
    logic   luld_loaded, luld_usable;
    always_comb begin
        luld_lo_eff = pf_sel.rec.luld_lo;
        luld_hi_eff = pf_sel.rec.luld_hi;
        // "Loaded" is the host's explicit assertion, NOT an inference from the
        // values. A band of 0/0 with luld_valid=1 is caught by the sanity gate in
        // risk_params and can never reach here.
        luld_loaded = pf_sel.rec.luld_valid;
        luld_usable = luld_loaded && !pf_sel.bands_stale;
    end

    // ── SSR. Live feed flag OR'd with the committed record: if EITHER says the
    //    price test is in force, it is in force. Fail-closed.
    logic ssr_eff;
    assign ssr_eff = pf_sel.rec.ssr_active || pf_sel.vs.ssr || !pf_sel.vs_init;

    // ⚠️⚠️ REG SHO RULE 201 — SYNTHETIC BEST BID, NOT THE OFFICIAL SIP NBBO.
    //   The rule requires a short sale to be priced STRICTLY ABOVE the current
    //   NATIONAL best bid, as the trading centre sees it. `book_top.bid_px` is
    //   OUR best bid, reconstructed in fabric from the Nasdaq TotalView-ITCH
    //   direct feed. It is:
    //     * Nasdaq-only. It does not include any away venue, so the true NBB can
    //       be HIGHER than ours — and a price that clears our bid may fail to
    //       clear the national one. That is the direction that produces a
    //       VIOLATION, not merely a venue reject.
    //     * Not the official SIP quote. It has no regulatory standing. We may
    //       trade on it; we may NOT use it to argue that Rule 201 was satisfied
    //       when the official NBBO said otherwise.
    //       (08-nasdaq/06-regnms-and-compliance.md §6, §8.)
    //   ⚠️ ACTION REQUIRED OF THE COMPLIANCE OWNER — this is not a TODO for an
    //   engineer. One of the following must be true before this build goes near
    //   production, and which one must be recorded:
    //     (a) The compliance owner accepts a Nasdaq-only best bid as the SSR
    //         reference, on the documented basis that we quote only on Nasdaq
    //         and rely on the venue's own price-test rejection as the primary
    //         control with this check as defence in depth; the venue-reject
    //         counter is monitored as the evidence the two views agree; OR
    //     (b) the check is TIGHTENED: an SIP/NBBO feed is brought into fabric,
    //         or a conservative per-symbol `nbb` with an `nbb_valid` staleness
    //         timer is pushed down by the host, and the comparison is made
    //         against that.
    //   Until (a) is recorded or (b) is built, the conservative behaviour below
    //   applies: a short sale is rejected whenever the reference bid is absent,
    //   stale, or crossed, and the comparison is STRICTLY greater-than.
    //   ⚠️ The comparison is `>`, never `>=`. An off-by-one here is a rule
    //   violation that fires thousands of times before anyone notices.
    logic ssr_fail;
    always_comb begin
        ssr_fail = 1'b0;
        if (ssr_eff && s_req.is_short && is_send) begin
            if (flg_ssr_req_bid && (!pf_sel.bid_valid || pf_sel.stale || pf_sel.crossed))
                ssr_fail = 1'b1;                        // reference unusable
            else if (!(s_req.price > pf_sel.bid_px))
                ssr_fail = 1'b1;                        // STRICTLY above
        end
    end

    // ── Self-match (FINRA 5210). Defence in depth only: fabric sees one MPID
    //    and one session. The venue's own SMP is the primary mechanism and must
    //    also be enabled.
    logic self_match;
    always_comb begin
        self_match = 1'b0;
        if (is_send) begin
            if (s_req.side == SIDE_BUY)
                self_match = pf_sel.own_ask_v && (s_req.price >= pf_sel.own_ask);
            else
                self_match = pf_sel.own_bid_v && (s_req.price <= pf_sel.own_bid);
        end
    end

    // ── Parameter freshness watchdog. 0xFFFFFFFF disables it (a deliberate
    //    write); the reset value 0 means "immediately stale" — fail-closed.
    logic param_stale;
    assign param_stale = (rp_commit_age > cfg_param_max_age);

    // ── Symbol state classification
    logic st_halted, st_not_open, st_stale;
    always_comb begin
        st_halted   = (pf_sel.vs.st == TRADE_HALTED)
                   || (pf_sel.vs.st == TRADE_PAUSED)
                   || (pf_sel.vs.st == TRADE_AUCTION);
        st_stale    = (pf_sel.vs.st == TRADE_STALE);
        st_not_open = (pf_sel.vs.st != TRADE_OPEN);
    end

    // ── DSP operands. Clamped per the width analysis in the header.
    qty_t   mul_qty;
    logic   qty_over_hard;
    assign qty_over_hard = (s_req.qty > HARD_MAX_QTY);
    assign mul_qty       = qty_over_hard ? HARD_MAX_QTY : s_req.qty;

    notional_t notional_d;
    assign notional_d = notional_t'(64'(s_req.price) * 64'(mul_qty));

    // ⚠️ SEC RULE 612 — PER-SYMBOL minimum pricing increment.
    // `trading_pkg::resid100` is a reciprocal-multiply (px * 1_374_389_535 >> 37)
    // followed by a shift-add subtract, NOT a divider and NOT a modulo
    // (CLAUDE.md §5 rule 3, 00-foundations/03-*.md §7). It costs the second DSP
    // cluster in T0. The exactness proof over the full ITCH price span
    // ($0.0000 .. $429,496.7295) is in trading_pkg.sv §6 and is the reason this
    // is allowed to be a multiply at all.
    //
    // ⚠️ THE TICK SIZE IS NO LONGER A CONSTANT. It was `is_whole_penny`, which
    // baked the whole-cent regime into the package. The SEC's 2024 Rule 612
    // amendments introduce a half-penny increment for certain symbols,
    // reassigned periodically — under which that test rejects valid orders.
    // The increment now comes from `sym_risk_t.tick_class`, and the ONLY thing
    // that varies with it is a 7-bit set-membership lookup at T1.
    //
    // ⚠️ WHY THE SPLIT IS FREE. The DSP constant is 1/100 for every tick class,
    // because every supported increment divides 100 (see tick_class_e). So the
    // multiply operand path carries no mux, T0 is unchanged from the whole-penny
    // version (multiply → shift-add → subtract, in place of
    // multiply → shift-add → compare), and the class-dependent part is one LUT
    // in T1, which the header records as the non-critical stage.
    logic [6:0] resid100_d;
    logic       px_ge_dollar_d;
    assign resid100_d     = resid100(s_req.price);
    assign px_ge_dollar_d = (s_req.price >= ONE_DOLLAR);

    // ── Projected position base: current position + working shares on the side
    //    this order would add to. ⚠️ Working shares are included; see
    //    position_monitor.sv.
    position_t pos_base_d, qty_signed_d;
    always_comb begin
        if (s_req.side == SIDE_BUY) begin
            pos_base_d   = pf_sel.pos + position_t'({8'd0, pf_sel.work_buy});
            qty_signed_d = position_t'({8'd0, s_req.qty});
        end else begin
            pos_base_d   = pf_sel.pos - position_t'({8'd0, pf_sel.work_sell});
            qty_signed_d = -position_t'({8'd0, s_req.qty});
        end
    end

    // ── THE T0 FAILURE VECTOR. Every bit computed in parallel. ───────────────
    logic [N_RISK_REASONS-1:0] fv0;

    always_comb begin
        fv0 = '0;                                   // default: no latches

        // 1..2 global gates
        fv0[RISK_MASTER_DISABLED] = !trading_en_q;
        fv0[RISK_KILL_SWITCH]     = kill_active;

        // 3 per-symbol enable
        fv0[RISK_SYM_DISABLED]    = !pf_sel.rec.enabled || pf_sel.blocked;

        // 4 session / venue window
        fv0[RISK_SESSION_CLOSED]  = (sess_state_q != TRADE_OPEN)
                                    || (st_not_open && !st_halted && !st_stale);

        // 5 symbol halted / paused / in a cross
        fv0[RISK_SYM_HALTED]      = st_halted;

        // 6 stale or untrustworthy book
        fv0[RISK_BOOK_STALE]      = pf_sel.stale || pf_sel.crossed || st_stale;

        // 8 hard price collar
        fv0[RISK_PRICE_COLLAR]    = is_send && ((s_req.price < pf_sel.rec.collar_lo)
                                             || (s_req.price > pf_sel.rec.collar_hi));

        // 9 / 24 / 25 LULD, as THREE MUTUALLY EXCLUSIVE outcomes.
        // ⚠️ Mutual exclusion is deliberate and is not an optimisation. Reason
        // attribution reports the LOWEST set index, and RISK_LULD_BAND (9) is
        // numerically below the two appended reasons (24, 25). If all three could
        // be set at once, a symbol whose bands had NEVER been loaded would be
        // reported as "price outside the band" — the exact misattribution that
        // made the original defect invisible. Each of the three conditions below
        // therefore excludes the others by construction, and each has its own
        // saturating counter in `reject_cnt`.
        // ⚠️ The checks are unconditional. There is no flag that disables them;
        // see F_LULD_REQ, which is now a fail-closed assertion rather than a gate.
        fv0[RISK_LULD_NOT_LOADED] = is_send && !luld_loaded;
        fv0[RISK_LULD_STALE]      = is_send &&  luld_loaded && pf_sel.bands_stale;
        fv0[RISK_LULD_BAND]       = is_send &&  luld_usable
                                             && ((s_req.price < luld_lo_eff)
                                              || (s_req.price > luld_hi_eff));

        // 10 Reg SHO Rule 201
        fv0[RISK_SSR]             = ssr_fail;

        // 11 max shares (per-symbol limit AND the absolute build ceiling)
        fv0[RISK_MAX_SHARES]      = is_send && ((s_req.qty > pf_sel.rec.max_order_qty)
                                             || qty_over_hard);

        // 15 open orders, per-symbol and aggregate
        fv0[RISK_OPEN_ORDERS]     = is_send && ((pf_sel.open >= pf_sel.rec.max_open_orders)
                                             || (pm_agg_open >= cfg_max_open_agg));

        // 16 outbound message rate
        fv0[RISK_MSG_RATE]        = rate_over_q;

        // 17 duplicate order
        fv0[RISK_DUPLICATE]       = is_send && dup_hit;

        // 18 self-match
        fv0[RISK_SELF_MATCH]      = self_match;

        // 19 restricted / hard-to-borrow
        fv0[RISK_RESTRICTED]      = is_send && s_req.is_short && !pf_sel.rec.shortable;

        // 20 in-flight credit
        fv0[RISK_NO_CREDIT]       = !credit_q;

        // 21..22 sanity
        fv0[RISK_ZERO_QTY]        = is_send && (s_req.qty   == qty_t'(0));
        fv0[RISK_ZERO_PRICE]      = is_send && (s_req.price == price_t'(0));

        // 23 parameter / input validity. Everything ambiguous lands here.
        // ⚠️ Note the last two terms: a design whose duplicate window or
        // prefetch-age window has never been programmed cannot trade at all.
        // Those two checks are the only ones whose "unconfigured" value would
        // otherwise silently disable them rather than block, so they are folded
        // into parameter validity to keep the fail-closed property total.
        fv0[RISK_PARAM_INVALID]   = !pf_valid_hit            // no fresh prefetch
                                 || !pf_sel.params_valid     // record never written
                                 || !pf_sel.vs_init          // venue state unknown
                                 ||  param_stale             // host stopped committing
                                 ||  rp_commit_busy          // a commit is in flight
                                 ||  rp_crc_err              // bank integrity failed
                                 ||  pm_upd_ovf              // a position update was lost
                                 || !tk_ready                // no token available
                                 ||  is_bad_action           // illegal action encoding
                                 || (cfg_dup_window   == 32'd0)
                                 || (cfg_pf_max_age   == 32'd0)
                                 // ⚠️ Band freshness bound never programmed. This
                                 // is a CONFIGURATION fault, not a stale market,
                                 // and reporting it as RISK_LULD_STALE would send
                                 // an operator hunting the SIP feed for a bug that
                                 // is in their own arming script.
                                 || (cfg_luld_max_age == 32'd0)
                                 // ⚠️ The host tried to disable the LULD checks.
                                 // Refused, loudly: a pre-trade control the
                                 // controlled party can switch off is not a
                                 // control. Clearing this bit stops trading; it
                                 // does not weaken the check.
                                 || !flg_luld_req;

        // ⚠️ CANCELS ARE RISK-REDUCING. A cancel carries no price, size or
        // position exposure, and blocking cancels is how a bad situation becomes
        // a worse one. Only the gates that must hold for ANY outbound message
        // apply. The kill switch DOES block cancels, because the top-level
        // assertion in fpga_top.sv requires that no order_out_valid survives it;
        // retracting what is already at the venue is the host's mass-cancel job.
        if (is_cancel) begin
            fv0 = '0;
            fv0[RISK_KILL_SWITCH]   = kill_active;
            fv0[RISK_NO_CREDIT]     = !credit_q;
            fv0[RISK_MSG_RATE]      = rate_over_q;
            fv0[RISK_PARAM_INVALID] = is_bad_action || rp_crc_err;
        end
    end

    // ── T0 → T1 pipeline registers (declared above, near the top) ────────────
    always_ff @(posedge clk) begin
        if (rst) begin
            t1_valid_q <= 1'b0;
        end else begin
            // ⚠️ The kill is ANDed into EVERY pipeline stage's valid bit, not
            // just the entry. That is what makes the in-flight squash real
            // rather than aspirational, and it is the line most likely to be
            // "simplified" by someone optimising for Fmax. It is not optional.
            // (08-nasdaq/09-*.md §5, §Hardware implications 7.)
            t1_valid_q <= s_req_valid && (s_req.action != ACT_NONE) && !kill_active;
        end
        // Datapath registers: no reset (03-hdl-and-rtl-coding.md §6).
        t1_req_q          <= s_req;
        t1_fv_q           <= fv0;
        t1_notional_q     <= notional_d;
        t1_max_notional_q <= pf_sel.rec.max_order_notional;
        t1_gross_base_q   <= pm_gross;
        t1_gross_limit_q  <= cfg_gross_limit;
        t1_resid100_q     <= resid100_d;
        t1_tick_class_q   <= pf_sel.rec.tick_class;
        t1_px_ge_dollar_q <= px_ge_dollar_d;
        t1_pos_base_q     <= pos_base_d;
        t1_qty_signed_q   <= qty_signed_d;
        t1_max_long_q     <= pf_sel.rec.max_long_pos;
        t1_max_short_q    <= pf_sel.rec.max_short_pos;
        t1_is_send_q      <= is_send;
        t1_is_cancel_q    <= is_cancel;
    end

    // =========================================================================
    // 7. T1 — the arithmetic checks, the reduce, and the verdict
    // =========================================================================
    logic signed [POS_W:0] proj_ext;
    position_t             proj_pos;
    logic                  proj_sat;
    notional_t             gross_new;
    logic [N_RISK_REASONS-1:0] fv1;

    always_comb begin
        proj_ext = {t1_pos_base_q[POS_W-1], t1_pos_base_q}
                 + {t1_qty_signed_q[POS_W-1], t1_qty_signed_q};
        proj_sat = (proj_ext > {1'b0, POS_MAX}) || (proj_ext < {1'b1, POS_MIN});
        proj_pos = proj_sat ? (proj_ext[POS_W] ? POS_MIN : POS_MAX)
                            : proj_ext[POS_W-1:0];
    end

    assign gross_new = sat_add64(t1_gross_base_q, t1_notional_q);

    // ── SEC Rule 612, second half: is the T0 residue on this symbol's grid?
    //    Below $1.00 the minimum increment is $0.0001 = 1 ITCH unit, which every
    //    representable price already meets — but the symbol must still have a
    //    real tick class, or it is unprovisioned and untradeable at any price.
    //    ⚠️ This is `trading_pkg::tick_resid_ok`, the same function the reference
    //    `tick_price_ok` calls. There is no local copy of the rule here.
    logic tick_ok;
    always_comb begin
        tick_ok = 1'b0;                             // default: fail-closed, no latches
        if (t1_px_ge_dollar_q)
            tick_ok = tick_resid_ok(t1_resid100_q, t1_tick_class_q);
        else
            tick_ok = (t1_tick_class_q != TICK_UNSET)
                   && (t1_tick_class_q != TICK_RSVD);
    end

    always_comb begin
        fv1 = t1_fv_q;                              // default: carry T0 forward

        // ⚠️ Re-evaluated LIVE, not from the T0 register: this is the in-flight
        // squash. An order that passed T0 one cycle ago must still die here.
        fv1[RISK_KILL_SWITCH] = fv1[RISK_KILL_SWITCH] || kill_active;

        if (t1_is_send_q) begin
            // 7 SEC Rule 612 — price on the SYMBOL'S minimum-increment grid.
            fv1[RISK_SUB_PENNY]    = !tick_ok;
            // 14 max order notional (the DSP product from T0)
            fv1[RISK_MAX_NOTIONAL] = (t1_notional_q > t1_max_notional_q);
            // 15/16 projected position within [-max_short, +max_long].
            // ⚠️ Saturation of the projection is itself a failure: if we cannot
            // represent the projected position we cannot check it.
            fv1[RISK_POS_LIMIT]    = proj_sat
                                     || (proj_pos > t1_max_long_q)
                                     || (proj_pos < -t1_max_short_q);
            // 17 aggregate gross notional
            fv1[RISK_GROSS_LIMIT]  = (gross_new > t1_gross_limit_q);
        end

        if (t1_is_cancel_q) begin
            // Cancels skip every priced/sized check; only re-apply the kill.
            fv1                   = '0;
            fv1[RISK_KILL_SWITCH] = t1_fv_q[RISK_KILL_SWITCH] || kill_active;
            fv1[RISK_NO_CREDIT]   = t1_fv_q[RISK_NO_CREDIT];
            fv1[RISK_MSG_RATE]    = t1_fv_q[RISK_MSG_RATE];
            fv1[RISK_PARAM_INVALID] = t1_fv_q[RISK_PARAM_INVALID];
        end
    end

    // ── Reason attribution: the FIRST failure in risk_reason_e order wins.
    //    Descending loop with last-assignment-wins yields the LOWEST set index.
    logic pass_d;

    always_comb begin
        verdict_d = RISK_OK;                        // default: no latches
        for (int i = N_RISK_REASONS-1; i >= 1; i--) begin
            if (fv1[i]) verdict_d = risk_reason_e'(i);
        end
    end

    assign pass_d = (fv1 == '0);

    // ⚠️ THE ONLY ASSIGNMENT TO m_out_valid IN THE DESIGN.
    assign accept_d = t1_valid_q && pass_d && !kill_active;
    assign reject_d = t1_valid_q && !pass_d;
    assign tk_issue = accept_d && t1_is_send_q;

    order_out_t out_d;
    always_comb begin
        out_d           = '0;
        out_d.action    = t1_req_q.action;
        out_d.sym       = t1_req_q.sym;
        out_d.side      = t1_req_q.side;
        out_d.price     = t1_req_q.price;
        out_d.qty       = t1_req_q.qty;
        // ⚠️ force_post_only is ORed in, never ANDed out. Reset value is 1, so
        // a freshly configured design can only ever add liquidity. This also
        // subsumes the `allow_taking = 0` control: a post-only order cannot
        // remove liquidity. (09-*.md §1 checks 27/28, §10 canary profile.)
        out_d.post_only = t1_req_q.post_only || flg_force_po;
        out_d.is_short  = t1_req_q.is_short;
        // A cancel carries the token of the order being cancelled; a new order
        // gets a freshly issued monotonic token.
        out_d.token     = t1_is_cancel_q ? t1_req_q.cancel_token : tk_token;
        out_d.rx_cycle  = t1_req_q.rx_cycle;
    end

    always_ff @(posedge clk) begin
        if (rst) m_out_valid <= 1'b0;
        else     m_out_valid <= accept_d;
        m_out <= out_d;                             // datapath: no reset
    end

    // Emit feedback to position_monitor / rate_limiter / duplicate CAM.
    always_ff @(posedge clk) begin
        if (rst) emit_valid_d <= 1'b0;
        else     emit_valid_d <= accept_d && t1_is_send_q;
        emit_sym_d  <= t1_req_q.sym;
        emit_side_d <= t1_req_q.side;
        emit_qty_d  <= t1_req_q.qty;
        emit_px_d   <= t1_req_q.price;
    end

    // =========================================================================
    // 8. Duplicate CAM maintenance
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned i = 0; i < DUP_DEPTH; i++) dup[i] <= '0;
            dup_wr_q <= '0;
        end else begin
            for (int unsigned i = 0; i < DUP_DEPTH; i++) begin
                if (dup[i].valid) begin
                    if (dup[i].age >= cfg_dup_window) dup[i].valid <= 1'b0;
                    else if (dup[i].age != CNT32_MAX) dup[i].age   <= dup[i].age + 32'd1;
                end
            end
            if (accept_d && t1_is_send_q) begin
                dup[dup_wr_q].valid <= 1'b1;
                dup[dup_wr_q].sym   <= t1_req_q.sym;
                dup[dup_wr_q].side  <= t1_req_q.side;
                dup[dup_wr_q].price <= t1_req_q.price;
                dup[dup_wr_q].qty   <= t1_req_q.qty;
                dup[dup_wr_q].age   <= 32'd0;
                dup_wr_q            <= dup_wr_q + DUP_PTR_W'(1);
            end else begin
                dup_wr_q <= dup_wr_q;
            end
        end
    end

    // =========================================================================
    // 9. Rejection accounting — CLAUDE.md §5 rule 7
    //    reject_cnt[RISK_OK] is repurposed as the ACCEPTED counter so a single
    //    array read reconciles: sum(reject_cnt[1..]) + reject_cnt[0] == requests.
    //    Counters SATURATE. A wrapped reject counter under-reports a control's
    //    activity, which is the direction that hides a problem.
    //    ⚠️ 09-*.md §4 prefers 48-bit counters; the fpga_top port contract is
    //    32-bit. Saturating at 2^32-1 plus the host's polling cadence covers a
    //    trading day with margin; this deviation is recorded in README.md.
    // =========================================================================
    logic [31:0] req_cnt_q, acc_cnt_q, rej_cnt_tot_q, pf_miss_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned r = 0; r < N_RISK_REASONS; r++) reject_cnt[r] <= 32'd0;
            req_cnt_q     <= 32'd0;
            acc_cnt_q     <= 32'd0;
            rej_cnt_tot_q <= 32'd0;
            pf_miss_q     <= 32'd0;
        end else begin
            if (t1_valid_q)
                req_cnt_q <= (req_cnt_q == CNT32_MAX) ? CNT32_MAX : req_cnt_q + 32'd1;

            if (accept_d) begin
                acc_cnt_q <= (acc_cnt_q == CNT32_MAX) ? CNT32_MAX : acc_cnt_q + 32'd1;
                reject_cnt[int'(RISK_OK)] <=
                    (reject_cnt[int'(RISK_OK)] == CNT32_MAX) ? CNT32_MAX
                                                             : reject_cnt[int'(RISK_OK)] + 32'd1;
            end

            if (reject_d) begin
                rej_cnt_tot_q <= (rej_cnt_tot_q == CNT32_MAX) ? CNT32_MAX
                                                              : rej_cnt_tot_q + 32'd1;
                reject_cnt[int'(verdict_d)] <=
                    (reject_cnt[int'(verdict_d)] == CNT32_MAX) ? CNT32_MAX
                                                               : reject_cnt[int'(verdict_d)] + 32'd1;
            end

            // A prefetch miss is a pipeline-assumption failure, not a market
            // event. Counted separately so it can be alarmed on separately.
            if (t1_valid_q && !pf_valid_hit)
                pf_miss_q <= (pf_miss_q == CNT32_MAX) ? CNT32_MAX : pf_miss_q + 32'd1;
        end
    end

    // ── Per-symbol first-reject latch (09-*.md §4: "answers 'why did this
    //    symbol stop working?' for a few hundred flip-flops").
    (* ram_style = "distributed" *) logic [4:0] frej_mem [N_ACTIVE];
    logic frej_vld_q [N_ACTIVE];

    initial begin
        for (int unsigned s = 0; s < N_ACTIVE; s++) frej_mem[s] = 5'd0;
    end

    always_ff @(posedge clk) begin
        if (reject_d && !frej_vld_q[t1_req_q.sym])
            frej_mem[t1_req_q.sym] <= 5'(verdict_d);
    end

    always_ff @(posedge clk) begin
        if (rst || g_hit_clrfrej) begin
            for (int unsigned s = 0; s < N_ACTIVE; s++) frej_vld_q[s] <= 1'b0;
        end else if (reject_d) begin
            frej_vld_q[t1_req_q.sym] <= 1'b1;
        end
    end

    // ── Circular log of the last N rejected orders, in full.
    typedef struct packed {
        risk_reason_e reason;
        sym_idx_t     sym;
        side_e        side;
        logic         is_short;
        price_t       price;
        qty_t         qty;
        logic [15:0]  cycle_lo;
    } rej_log_t;

    localparam int unsigned RL_W     = $bits(rej_log_t);
    localparam int unsigned RL_PAD_W = 128;          // read back as 4×32-bit words
    (* ram_style = "distributed" *) logic [RL_W-1:0] rej_log [REJ_LOG_DEPTH];
    logic [LOG_PTR_W-1:0] rej_log_wr_q;
    // `free_cyc_q` is declared with the forward references at the top of the
    // module: it is 48 bits wide and is also the LULD band-age time base.

    rej_log_t rej_log_d;
    always_comb begin
        rej_log_d          = '0;
        rej_log_d.reason   = verdict_d;
        rej_log_d.sym      = t1_req_q.sym;
        rej_log_d.side     = t1_req_q.side;
        rej_log_d.is_short = t1_req_q.is_short;
        rej_log_d.price    = t1_req_q.price;
        rej_log_d.qty      = t1_req_q.qty;
        rej_log_d.cycle_lo = free_cyc_q[15:0];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rej_log_wr_q <= '0;
            free_cyc_q   <= '0;
        end else begin
            // ⚠️ Free-running and NEVER saturating: this is a time base, not a
            // counter of events. Saturating it would freeze every band age at
            // "fresh" after 20 days of uptime — a fail-open. It wraps, and the
            // subtract that consumes it is exact across the wrap.
            free_cyc_q <= free_cyc_q + cycle_t'(1);
            if (reject_d) begin
                rej_log[rej_log_wr_q] <= RL_W'(rej_log_d);
                rej_log_wr_q          <= rej_log_wr_q + LOG_PTR_W'(1);
            end else begin
                rej_log_wr_q <= rej_log_wr_q;
            end
        end
    end

    // =========================================================================
    // 10. Kill-response measurement — proves the documented bound on hardware
    // =========================================================================
    logic [7:0] kill_resp_cnt_q, kill_resp_max_q;
    logic       pipe_live;
    assign pipe_live = t1_valid_q || m_out_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            kill_resp_cnt_q <= 8'd0;
            kill_resp_max_q <= 8'd0;
        end else if (kill_active && pipe_live) begin
            kill_resp_cnt_q <= (kill_resp_cnt_q == 8'hFF) ? 8'hFF
                                                          : kill_resp_cnt_q + 8'd1;
            if ((kill_resp_cnt_q + 8'd1) > kill_resp_max_q)
                kill_resp_max_q <= kill_resp_cnt_q + 8'd1;
        end else if (!kill_active) begin
            kill_resp_cnt_q <= 8'd0;
        end
    end

    // =========================================================================
    // 11. Read-back mux and telemetry (stat[0..7]) — map in README.md
    // =========================================================================
    // RB_ADDR layout: [14:12] = selector, [11:0] = index (see README.md).
    logic [2:0]           rb_sel;
    logic [11:0]          rb_idx;
    logic [31:0]          rb_mux_q;
    logic [ACT_IDX_W-1:0] rb_sidx;
    logic [3:0]           rb_ssub;
    logic [LOG_PTR_W-1:0] rb_lidx;
    logic [1:0]           rb_lwrd;
    logic [RL_PAD_W-1:0]  rb_log_pad;
    vstate_t              rb_vs;
    cycle_t               rb_stamp;

    assign rb_sel     = greg[G_RBADDR][14:12];
    assign rb_idx     = greg[G_RBADDR][11:0];
    assign rb_sidx    = rb_idx[ACT_IDX_W-1:0];
    // ⚠️ Sub-selector for the per-symbol window. rb_idx[11:8] was previously
    // ignored (ACT_IDX_W = 8), so sub-index 0 is exactly the old behaviour and
    // existing host readers are unaffected. Additive, never renumbering.
    assign rb_ssub    = rb_idx[11:8];
    assign rb_lidx    = rb_idx[LOG_PTR_W-1:0];
    assign rb_lwrd    = rb_idx[LOG_PTR_W+1 -: 2];
    assign rb_log_pad = {{(RL_PAD_W-RL_W){1'b0}}, rej_log[rb_lidx]};
    assign rb_vs      = vstate_t'(vs_mem[rb_sidx]);
    assign rb_stamp   = band_stamp_mem[rb_sidx];

    always_ff @(posedge clk) begin
        rb_mux_q <= 32'd0;                          // default assignment
        unique case (rb_sel)
            // 0/1: per-symbol limit record, active and shadow banks.
            3'd0, 3'd1 : rb_mux_q <= rp_rb_data;
            // 2: per-symbol diagnostics window. idx[7:0] = symbol,
            //    idx[11:8] = sub-index (0 = the original first-reject latch).
            //    ⚠️ Sub-indices 1..5 exist so the ITCH `J` auction collar and the
            //    LULD band-freshness stamp are OBSERVABLE. The defect this
            //    replaces was invisible for exactly one reason: nothing in the
            //    machine could be asked "what bands do you think you have, and
            //    when did you last get them?".
            3'd2       : begin
                unique case (rb_ssub)
                    4'd0 : rb_mux_q <= {26'd0, frej_vld_q[rb_sidx], frej_mem[rb_sidx]};
                    4'd1 : rb_mux_q <= rb_vs.auc_lo;       // ITCH 'J' collar, NOT a band
                    4'd2 : rb_mux_q <= rb_vs.auc_hi;       // ITCH 'J' collar, NOT a band
                    4'd3 : rb_mux_q <= {27'd0, vs_init_q[rb_sidx], rb_vs.ssr,
                                               rb_vs.st};
                    4'd4 : rb_mux_q <= rb_stamp[31:0];     // last commit stamp, lo
                    4'd5 : rb_mux_q <= {15'd0, band_stamped_q[rb_sidx],
                                        rb_stamp[CYCLE_CNT_W-1:32]};
                    default: rb_mux_q <= 32'd0;
                endcase
            end
            // 3: reject ring log. idx[3:0] = entry, idx[5:4] = 32-bit word.
            3'd3       : rb_mux_q <= rb_log_pad[{rb_lwrd, 5'd0} +: 32];
            // 4: per-reason rejection counters (same data as the reject_cnt port,
            //    reachable through the single stat[6] window).
            3'd4       : rb_mux_q <= (rb_idx < 12'(N_RISK_REASONS))
                                       ? reject_cnt[rb_idx[4:0]] : 32'd0;
            // 5: aggregate exposure.
            3'd5       : begin
                unique case (rb_idx[3:0])
                    4'd0 : rb_mux_q <= pm_gross[31:0];
                    4'd1 : rb_mux_q <= pm_gross[63:32];
                    4'd2 : rb_mux_q <= pm_net[31:0];
                    4'd3 : rb_mux_q <= pm_net[63:32];
                    4'd4 : rb_mux_q <= pm_agg_pos[31:0];
                    4'd5 : rb_mux_q <= {24'd0, pm_agg_pos[POS_W-1:32]};
                    4'd6 : rb_mux_q <= pm_agg_open;
                    4'd7 : rb_mux_q <= pm_recon_cnt;
                    4'd8 : rb_mux_q <= pm_recon_delta[31:0];
                    4'd9 : rb_mux_q <= pm_drop_cnt;
                    4'd10: rb_mux_q <= pm_sat_pos;
                    4'd11: rb_mux_q <= pm_sat_gross;
                    4'd12: rb_mux_q <= pm_sat_net;
                    4'd13: rb_mux_q <= pm_sat_open;
                    4'd14: rb_mux_q <= tk_counter[31:0];
                    4'd15: rb_mux_q <= {16'd0, tk_counter[47:32]};
                    default: rb_mux_q <= 32'd0;
                endcase
            end
            // 6: rate limiter.
            3'd6       : begin
                unique case (rb_idx[1:0])
                    2'd0 : rb_mux_q <= rl_window;
                    2'd1 : rb_mux_q <= rl_peak;
                    2'd2 : rb_mux_q <= rl_over_cnt;
                    2'd3 : rb_mux_q <= rl_msg_cnt;
                    default: rb_mux_q <= 32'd0;
                endcase
            end
            // 7: kill switch / token / parameter-bank status.
            3'd7       : begin
                unique case (rb_idx[2:0])
                    3'd0 : rb_mux_q <= ks_wd_cnt;
                    3'd1 : rb_mux_q <= {ks_rearm_cnt, ks_rearm_fail};
                    3'd2 : rb_mux_q <= {ks_cnt, ks_test_resp};
                    3'd3 : rb_mux_q <= tk_issued;
                    3'd4 : rb_mux_q <= {16'd0, tk_magic_q};
                    3'd5 : rb_mux_q <= {26'd0, rp_rb_valid, pm_busy, ks_wd_expired,
                                               tk_magic_valid, tk_near, rp_commit_busy};
                    3'd6 : rb_mux_q <= {24'd0, pm_recon_delta[39:32]};
                    3'd7 : rb_mux_q <= rp_commit_age;
                    default: rb_mux_q <= 32'd0;
                endcase
            end
            default    : rb_mux_q <= 32'd0;
        endcase
    end

    always_comb begin
        stat    = '{default: 32'd0};
        stat[0] = req_cnt_q;
        stat[1] = acc_cnt_q;
        stat[2] = rej_cnt_tot_q;
        stat[3] = {ks_src_mask,
                   sat8(ks_cnt),
                   kill_resp_max_q,
                   kill_active, ks_test_fired, tk_exhausted, rate_over_q,
                   rp_crc_err, pm_sat_sticky, pm_upd_ovf, param_stale};
        stat[4] = rp_generation;
        stat[5] = pf_miss_q;
        stat[6] = rb_mux_q;
        stat[7] = {sat8(ks_test_resp), sat8(ks_rearm_fail),
                   sat8(rp_crc_fail),  sat8(rp_sane_fail)};
    end

    // =========================================================================
    // 12. Assertions — THE MOST IMPORTANT SET IN THE PROJECT
    //     "Prove the invariant `tx_valid` implies `all_checks_passed_q` holds
    //      unconditionally. This is a small, tractable formal property and it is
    //      the single most valuable one in the design." (09-*.md §8.)
    // =========================================================================
`ifndef SYNTHESIS
    initial begin
        if (KILL_RESP_CYCLES < 2)
            $error("risk_gate: KILL_RESP_CYCLES (%0d) must be >= 2: kill_switch latch 1 cyc + output squash 1 cyc", KILL_RESP_CYCLES);
        if (PF_DEPTH < 2)
            $error("risk_gate: PF_DEPTH must be >= the strategy pipeline depth (2)");
        if ($bits(fv0) != N_RISK_REASONS)
            $error("risk_gate: failure vector width != N_RISK_REASONS");
    end

    // ⚠️ PROOF-BY-SWEEP OF THE RULE 612 ARITHMETIC, run at elaboration.
    //   The algebraic proof that (px * 1_374_389_535) >> 37 == floor(px/100) for
    //   every px in [0, 2^32-1] is written out in trading_pkg.sv §6. THIS block
    //   checks that the proof was transcribed into RTL correctly, which is a
    //   different question and the one that actually goes wrong.
    //   `/` and `%` appear here and NOWHERE else in the design: this block is
    //   inside `ifndef SYNTHESIS` and is never synthesized. Using a real divider
    //   as the oracle is the whole point — the fabric must match it exactly.
    //   Coverage: every price 0..$2.0000 (both sides of the $1.00 boundary and
    //   every residue), a stride across the full 32-bit span, and the top of the
    //   ITCH range where a reciprocal that is off by one fails first.
    initial begin : b_tick_sweep
        int unsigned errs;
        int unsigned units;
        logic        want, got;
        price_t      px;
        errs = 0;

        for (int unsigned k = 0; k < 250_000; k++) begin
            // 0..20000 exhaustive, then a coprime stride to the top of the range,
            // then the last 200 codes below 2^32.
            if      (k <= 20_000)  px = price_t'(k);
            else if (k <  249_800) px = price_t'((k * 32'd17_389) & 32'hFFFF_FFFF);
            else                   px = price_t'(32'hFFFF_FFFF - (249_999 - k));

            if (resid100(px) != 7'(px % 32'd100)) begin
                errs++;
                if (errs < 5)
                    $error("resid100(%0d) = %0d, expected %0d",
                           px, resid100(px), px % 32'd100);
            end
            if (div100(px) != (px / 32'd100)) begin
                errs++;
                if (errs < 5)
                    $error("div100(%0d) = %0d, expected %0d",
                           px, div100(px), px / 32'd100);
            end

            for (int unsigned c = 0; c < 8; c++) begin
                units = int'(tick_units(tick_class_e'(c[2:0])));
                if (units == 0)                     want = 1'b0;  // UNSET / RSVD
                else if (px < RULE612_DOLLAR_PX)    want = 1'b1;  // $0.0001 grid
                else                                want = ((px % price_t'(units)) == 32'd0);
                got = tick_price_ok(px, tick_class_e'(c[2:0]));
                if (got !== want) begin
                    errs++;
                    if (errs < 5)
                        $error("tick_price_ok(%0d, class %0d) = %0b, expected %0b",
                               px, c, got, want);
                end
            end
        end

        if (errs != 0)
            $fatal(1, "SEC RULE 612: tick arithmetic is not exact (%0d mismatches)", errs);
    end

    // ⚠️⚠️ THE CENTRAL INVARIANT. An order is emitted only if EVERY check
    // passed. If this ever fails, the design has market access it is not
    // entitled to.
    a_gate_breach : assert property (@(posedge clk) disable iff (rst)
        m_out_valid |-> ($past(fv1) == '0)
    ) else $fatal(1, "RISK GATE BREACH: order emitted without a full check pass");

    a_gate_verdict : assert property (@(posedge clk) disable iff (rst)
        m_out_valid |-> ($past(verdict_d) == RISK_OK)
    ) else $fatal(1, "RISK GATE BREACH: order emitted with a non-OK verdict");

    // ⚠️ The bound fpga_top.sv asserts. kill_active gates the output register
    // combinationally, so m_out_valid is low the very next cycle.
    a_kill_bound : assert property (@(posedge clk) disable iff (rst)
        kill_active |-> ##[0:KILL_RESP_CYCLES] !m_out_valid
    ) else $fatal(1, "FATAL: order emitted more than %0d cycles after kill",
                  KILL_RESP_CYCLES);

    a_kill_1cyc : assert property (@(posedge clk) disable iff (rst)
        kill_active |=> !m_out_valid
    ) else $fatal(1, "FATAL: kill did not suppress the output in 1 cycle");

    a_kill_squash : assert property (@(posedge clk) disable iff (rst)
        kill_active |=> !t1_valid_q
    ) else $error("FATAL: an in-flight order survived the kill (no squash)");

    a_kill_measured : assert property (@(posedge clk) disable iff (rst)
        kill_resp_max_q <= 8'(KILL_RESP_CYCLES)
    ) else $fatal(1, "FATAL: measured kill response %0d exceeded the bound %0d",
                  kill_resp_max_q, KILL_RESP_CYCLES);

    // ⚠️ Fail-closed on reset.
    a_reset_no_out : assert property (@(posedge clk) rst |=> !m_out_valid)
        else $fatal(1, "FATAL: order emitted during/after reset");

    a_reset_killed : assert property (@(posedge clk) rst |=> kill_active)
        else $fatal(1, "FATAL: not killed out of reset (fail-closed violated)");

    // ── Fixed latency, both outcomes. A reject is never faster than a pass.
    a_latency : assert property (@(posedge clk) disable iff (rst)
        (s_req_valid && (s_req.action != ACT_NONE) && !kill_active)
        |=> (t1_valid_q) ##1 (m_out_valid || $past(reject_d))
    ) else $error("risk_gate latency is not a fixed 2 cycles");

    // ── Per-check restatements. Each one independently re-derives the property
    //    from the OUTPUT, so a bug in the vector construction cannot hide.
    a_no_out_disabled : assert property (@(posedge clk) disable iff (rst)
        m_out_valid |-> $past(trading_en_q, 2)
    ) else $error("order emitted with master trading disabled");

    a_no_out_zero_qty : assert property (@(posedge clk) disable iff (rst)
        (m_out_valid && (m_out.action == ACT_SEND)) |-> (m_out.qty != qty_t'(0))
    ) else $error("order emitted with zero quantity");

    a_no_out_zero_px : assert property (@(posedge clk) disable iff (rst)
        (m_out_valid && (m_out.action == ACT_SEND)) |-> (m_out.price != price_t'(0))
    ) else $error("order emitted with zero price");

    a_no_out_no_credit : assert property (@(posedge clk) disable iff (rst)
        m_out_valid |-> $past(credit_q, 2)
    ) else $error("order emitted with no in-flight credit");

    // ── SEC Rule 612, per-symbol tick size ───────────────────────────────────
    // ⚠️ No emitted order is ever off its symbol's minimum-increment grid. This
    // covers every tick class including TICK_UNSET and TICK_RSVD, both of which
    // make `tick_ok` false, so an unprovisioned symbol cannot emit at any price.
    a_tick_grid : assert property (@(posedge clk) disable iff (rst)
        (m_out_valid && (m_out.action == ACT_SEND)) |-> $past(tick_ok)
    ) else $fatal(1, "SEC RULE 612 VIOLATION: order priced off the symbol's tick grid");

    // ⚠️ THE SPLIT IMPLEMENTATION EQUALS THE REFERENCE, EXACTLY, EVERY TIME.
    // The gate computes the residue at T0 and the class lookup at T1 for timing;
    // `trading_pkg::tick_price_ok` computes both in one call. If those two ever
    // disagree — a pipelining bug, a stale registered class, a boundary price —
    // this fires. It is the assertion that makes the T0/T1 split safe to do at
    // all, and it is checked at EVERY price the strategy actually presents,
    // including the $1.00 boundary and the top of the ITCH range.
    a_tick_reference : assert property (@(posedge clk) disable iff (rst)
        (t1_valid_q && t1_is_send_q)
        |-> (tick_ok == tick_price_ok(t1_req_q.price, t1_tick_class_q))
    ) else $fatal(1, "Rule 612 pipeline split diverged from trading_pkg::tick_price_ok at price %0d class %0d",
                  t1_req_q.price, t1_tick_class_q);

    // ── LULD, all three outcomes ─────────────────────────────────────────────
    // ⚠️ A symbol whose bands were never loaded NEVER passes. This is the
    // property the original defect inverted: bands sourced from ITCH `J` were
    // absent, so this held — by rejecting everything. It must now hold while the
    // system is actually trading.
    a_luld_loaded : assert property (@(posedge clk) disable iff (rst)
        (accept_d && t1_is_send_q) |-> $past(luld_loaded)
    ) else $fatal(1, "LULD PLAN VIOLATION: order accepted for a symbol with no bands loaded");

    a_luld_fresh : assert property (@(posedge clk) disable iff (rst)
        (accept_d && t1_is_send_q) |-> !$past(pf_sel.bands_stale)
    ) else $fatal(1, "LULD PLAN VIOLATION: order accepted against stale bands");

    // ⚠️ An order priced outside the live band never passes. Stated against the
    // BANDS THEMSELVES rather than against the failure vector, so a bug in how
    // fv0[RISK_LULD_BAND] is built cannot hide behind its own construction.
    a_luld_inside : assert property (@(posedge clk) disable iff (rst)
        (accept_d && t1_is_send_q)
        |-> ((t1_req_q.price >= $past(luld_lo_eff))
          && (t1_req_q.price <= $past(luld_hi_eff)))
    ) else $fatal(1, "LULD PLAN VIOLATION: order priced outside the live band emitted");

    // ⚠️ The three LULD reasons are mutually exclusive, so each counter means
    // exactly one thing. If this fails, the counters are no longer attributable
    // even though the gate is still safe — which is the failure mode that makes
    // a control undebuggable rather than unsafe.
    a_luld_exclusive : assert property (@(posedge clk) disable iff (rst)
        $onehot0({fv0[RISK_LULD_BAND], fv0[RISK_LULD_NOT_LOADED],
                  fv0[RISK_LULD_STALE]})
    ) else $error("LULD reject reasons are not mutually exclusive — counters are not attributable");

    // ⚠️ The LULD checks cannot be switched off by the host. Clearing F_LULD_REQ
    // stops trading; it must never let an order through.
    a_luld_not_disableable : assert property (@(posedge clk) disable iff (rst)
        m_out_valid |-> $past(flg_luld_req, 2)
    ) else $fatal(1, "order emitted with the LULD checks disabled");

    a_qty_ceiling : assert property (@(posedge clk) disable iff (rst)
        (m_out_valid && (m_out.action == ACT_SEND)) |-> (m_out.qty <= HARD_MAX_QTY)
    ) else $error("order emitted above HARD_MAX_QTY: the notional multiply operand was clamped for this order");

    a_post_only_forced : assert property (@(posedge clk) disable iff (rst)
        (m_out_valid && $past(flg_force_po)) |-> m_out.post_only
    ) else $error("force_post_only was set but the emitted order was not post-only");

    a_token_magic : assert property (@(posedge clk) disable iff (rst)
        (m_out_valid && (m_out.action == ACT_SEND))
        |-> (m_out.token[TOKEN_W-1 -: 16] == $past(tk_magic_q))
    ) else $error("emitted token carries the wrong session magic");

    a_token_unique : assert property (@(posedge clk) disable iff (rst)
        (m_out_valid && (m_out.action == ACT_SEND)
         && $past(m_out_valid) && ($past(m_out.action) == ACT_SEND))
        |-> (m_out.token[79:32] != $past(m_out.token[79:32]))
    ) else $fatal(1, "FATAL: two consecutive orders carry the same token counter");

    // ── Exactly one reason is attributed per rejection, and it is the lowest
    //    set bit — the first failure in enum order.
    // Bits strictly below the attributed reason must all be clear.
    logic [N_RISK_REASONS-1:0] below_mask;
    assign below_mask = ~({N_RISK_REASONS{1'b1}} << verdict_d);

    a_reason_lowest : assert property (@(posedge clk) disable iff (rst)
        reject_d |-> (fv1[int'(verdict_d)] && ((fv1 & below_mask) == '0))
    ) else $error("reject reason is not the first failing check");

    a_reason_nonzero : assert property (@(posedge clk) disable iff (rst)
        reject_d |-> (verdict_d != RISK_OK)
    ) else $error("a rejection was attributed to RISK_OK");

    // Accounting closes: every request is either accepted or rejected, never
    // both and never neither.
    a_accounting : assert property (@(posedge clk) disable iff (rst)
        t1_valid_q |-> (accept_d ^ reject_d)
    ) else $error("a request was neither accepted nor rejected (or both)");

    // ── Stream contract on the request interface.
    a_req_action : assert property (@(posedge clk) disable iff (rst)
        s_req_valid |-> (s_req.action inside {ACT_NONE, ACT_SEND, ACT_CANCEL})
    ) else $error("strategy presented an illegal action encoding");

    // ── Prefetch coherency: an accepted order always had a fresh, matching slot.
    a_pf_fresh : assert property (@(posedge clk) disable iff (rst)
        accept_d |-> $past(pf_valid_hit)
    ) else $fatal(1, "FATAL: order accepted without a valid prefetched record");

    // =========================================================================
    // ⚠️ REQUIRED COVERAGE — EVERY CHECK MUST BE OBSERVED TO REJECT.
    //   "A check that has never been observed to fire is a check you cannot
    //    trust. There is no exception to this. Not 'it's obviously correct'.
    //    Not 'it's one comparator'. Not 'we tested a similar one.'"
    //    (08-nasdaq/09-*.md §8.)
    //   The generated cover below is the machine-checkable half of the test
    //   matrix in rtl/risk/README.md. CI must fail on ANY uncovered reason.
    // =========================================================================
    generate
        for (genvar r = 1; r < N_RISK_REASONS; r++) begin : g_cov_reason
            c_reason : cover property (@(posedge clk) disable iff (rst)
                reject_d && (verdict_d == risk_reason_e'(r))
            );
        end
    endgenerate

    c_accept        : cover property (@(posedge clk) disable iff (rst) accept_d);
    c_accept_cancel : cover property (@(posedge clk) disable iff (rst)
                                       accept_d && t1_is_cancel_q);
    c_kill_inflight : cover property (@(posedge clk) disable iff (rst)
                                       t1_valid_q && $rose(kill_active));
    c_boundary_qty  : cover property (@(posedge clk) disable iff (rst)
                                       accept_d && (t1_req_q.qty == $past(pf_sel.rec.max_order_qty)));
    c_boundary_ssr  : cover property (@(posedge clk) disable iff (rst)
                                       reject_d && (verdict_d == RISK_SSR)
                                       && (t1_req_q.price == $past(pf_sel.bid_px)));
    c_pf_miss       : cover property (@(posedge clk) disable iff (rst)
                                       t1_valid_q && !pf_valid_hit);
    c_dup_expire    : cover property (@(posedge clk) disable iff (rst)
                                       dup[0].valid && (dup[0].age == cfg_dup_window));

    // ⚠️ The half-penny regime must be EXERCISED, not merely supported. A tick
    // class that has never been traded against is a compliance claim nobody has
    // tested. CI must see all three of these.
    c_tick_penny    : cover property (@(posedge clk) disable iff (rst)
                                       accept_d && t1_is_send_q
                                       && (t1_tick_class_q == TICK_0100));
    c_tick_half     : cover property (@(posedge clk) disable iff (rst)
                                       accept_d && t1_is_send_q
                                       && (t1_tick_class_q == TICK_0050));
    c_tick_half_rej : cover property (@(posedge clk) disable iff (rst)
                                       reject_d && (verdict_d == RISK_SUB_PENNY)
                                       && (t1_tick_class_q == TICK_0050));
    // Boundary prices: exactly $1.00 (coarse grid applies, and 10000 is on every
    // supported grid) and one unit below (fine grid, always legal).
    c_tick_at_dollar : cover property (@(posedge clk) disable iff (rst)
                                       accept_d && t1_is_send_q
                                       && (t1_req_q.price == RULE612_DOLLAR_PX));
    c_tick_sub_dollar: cover property (@(posedge clk) disable iff (rst)
                                       accept_d && t1_is_send_q
                                       && (t1_req_q.price == (RULE612_DOLLAR_PX - 32'd1)));

    // ⚠️ Each LULD outcome observed independently. "Bands loaded and wide" must
    // be seen to ACCEPT — otherwise the fix for the original defect has not been
    // demonstrated, only asserted.
    c_luld_accept   : cover property (@(posedge clk) disable iff (rst)
                                       accept_d && t1_is_send_q);
    c_luld_edge_lo  : cover property (@(posedge clk) disable iff (rst)
                                       accept_d && t1_is_send_q
                                       && (t1_req_q.price == $past(luld_lo_eff)));
    c_luld_edge_hi  : cover property (@(posedge clk) disable iff (rst)
                                       accept_d && t1_is_send_q
                                       && (t1_req_q.price == $past(luld_hi_eff)));
    c_luld_stale    : cover property (@(posedge clk) disable iff (rst)
                                       reject_d && (verdict_d == RISK_LULD_STALE));
    c_luld_unloaded : cover property (@(posedge clk) disable iff (rst)
                                       reject_d && (verdict_d == RISK_LULD_NOT_LOADED));
`endif

endmodule : risk_gate

`default_nettype wire
