// =============================================================================
// price_levels.sv — per-symbol, per-side aggregated price levels
// -----------------------------------------------------------------------------
// PURPOSE
//   Structure 2 of the order book: (sym, side, price) -> aggregate resting
//   quantity, held as a DIRECT-INDEXED array over a bounded, host-anchored price
//   window, plus the occupancy bitmap that makes "find the new best" a priority
//   encode instead of a comparator tree over every level.
//
// LATENCY  : 2 cycles (12.8 ns @ 156.25 MHz), FIXED, no stall path.
//              A  price classification + level/occupancy read issue
//              B  forward, saturating read-modify-write, registered outputs
//            Level lookup port (lk_*): 1 cycle after the transfer fires.
//            Early window check (chk_*): 1 cycle, registered.
//            Host config (cfg_*): 4 cycles, slow path, back-pressured.
//
// RESOURCE : (N_ACTIVE=256, N_LEVELS=2048, LVL_PACK=2, QTY_W=32)
//            Level array
//              entries = 256 sym x 2 sides x 2048 levels = 1,048,576
//              bits    = 1,048,576 x 32                  = 33.55 Mbit
//              packed LVL_PACK=2 -> 524,288 words x 64 bit
//              URAM288 is 4096 x 72 -> 524,288 / 4096     = 128 URAM288
//              (unpacked, one 32-bit entry per address, this would be 256
//               URAM288 — half of them wasted on the unused 40 bits. The
//               packing is what makes the array fit an SLR beside the map.)
//            Occupancy bitmap
//              256 sym x (2 x 2048) bit = 256 x 4096      = 1.05 Mbit
//              256 deep x 4096 wide, both sides in ONE word so a symbol clear
//              is a single write -> ceil(4096/72) = 57 BRAM36 (512x72 each,
//              256 of 512 addresses used).
//            Window/config state  256 x (32 base + 1 valid + 1 stale + 1
//              re-anchor + 7 oow count) = ~10.5 kbit in FF/LUTRAM.
//            2 x (DELTA_W x 32) reciprocal multipliers -> ~4 DSP48E2.
//            > Verify against the post-synthesis utilization report. Nothing in
//              this file has been synthesized, simulated, or linted.
//
// Governing manual: manuals/04-system-architecture/03-order-book-in-hardware.md
//                   §4 (tick normalization, the window and its base)
//                   §5 (memory budget)  §8 (the read-modify-write hazard)
//                   §9 (resynchronization)
//                   manuals/00-foundations/03-hdl-and-rtl-coding.md
//                   docs/ORDER-BOOK-REDESIGN.md §2.2, §3.2, §3.3
//
// -----------------------------------------------------------------------------
// STRUCTURE CHOICE — direct index on a tick-normalized price.
//   level = (price - window_base) / TICK_UNITS,  by reciprocal multiply.
// Rejected alternatives:
//   * sorted list — insertion is O(n) in fabric and variable latency
//   * heap        — multi-cycle sift, variable latency, the thing we must avoid
//   * tree        — log-depth pointer chase, several memory reads deep
// Direct index is ONE memory access.
//
// ⚠️ THE WINDOW IS HOST-ANCHORED. It is NOT auto-anchored on the first price
//    seen. The previous implementation anchored on the first price after a clear
//    and re-anchored only when the side was empty — which for a liquid symbol
//    never happens. Once the price drifted past the window every subsequent
//    order was silently dropped and the book became fiction while still looking
//    plausible. See docs/ORDER-BOOK-REDESIGN.md §2.2.
//
//    A symbol is DEAD (every update rejected, `stale` asserted, re-anchor
//    requested) until the host writes its reference price through cfg_*. That is
//    the fail-closed direction: no reference means no book, not a guessed book.
//
// ⚠️ OUT-OF-WINDOW IS NEVER A SILENT DISCARD. Every rejected update
//      (a) is counted, split by whether it could have changed the top of book,
//      (b) raises a per-symbol re-anchor request to the host, and
//      (c) is reported to the consumer as res_in_window = 0 so the order map can
//          honour the §3.2 invariant.
//    The split matters and is the whole out-of-window correctness argument:
//      * a BID above the window / an ASK below it is BETTER than everything the
//        window holds. The published top of book is therefore WRONG -> the
//        symbol goes STALE immediately.
//      * a BID below the window / an ASK above it is worse than everything the
//        window holds (the "stink bid" at $1 on a $100 name — routine, not an
//        error). Top of book is still correct, so the symbol is NOT staled; it
//        is counted, and OOW_THRESH of them stales the symbol anyway because the
//        window is evidently drifting.
//
// ⚠️ THE OCCUPANCY BIT IS THE VALIDITY BIT. A level's stored quantity counts
//    only when its occupancy bit is set. That makes BOOK_CLEAR and host
//    re-anchor O(1) — one write of one 4096-bit word zeroes both sides of a
//    symbol — with none of the aliasing that the epoch-tag scheme of manual §9.1
//    carries (a 4-bit epoch wraps after 16 resyncs and resurrects a phantom
//    book; this cannot, because there is no tag to wrap).
//
// ⚠️ TICK_UNITS AND ITS RECIPROCAL ARE LINKED HERE, AT ELABORATION.
//    book_pkg hardcodes TICK_RECIP to the /100 value while TICK_UNITS is a
//    parameter; changing TICK_UNITS to 50 for a half-penny regime (SEC Rule 612)
//    would silently produce wrong level indices. This module derives the
//    reciprocal from TICK_UNITS, proves the reciprocal is EXACT over the whole
//    operand range, and asserts agreement with book_pkg at elaboration. There is
//    no runtime division anywhere.
// =============================================================================
`default_nettype none

module price_levels
    import trading_pkg::*;
    import book_pkg::*;
#(
    // Levels per side. The governing manual specifies 2048 (a $20.48 window at a
    // one-cent tick). This tracks book_pkg::LEVELS so the package stays the
    // single source of truth — R6 must set trading_pkg::BOOK_LEVELS = 2048.
    parameter int unsigned N_LEVELS   = book_pkg::LEVELS,
    // Level quantities packed per physical memory word. 2 x 32 bit = 64 of the
    // 72 bits a URAM288 offers, which halves the URAM count. Power of two.
    parameter int unsigned LVL_PACK   = 2,
    // Benign (worse-than-window) out-of-window events tolerated per symbol
    // before the symbol is staled anyway.
    parameter int unsigned OOW_THRESH = 64,
    // DERIVED — never override at an instantiation site. It lives in the
    // parameter list only because SystemVerilog will not let a body-scoped
    // localparam size a port.
    parameter int unsigned LVL_W      = (N_LEVELS > 1) ? $clog2(N_LEVELS) : 1
) (
    input  var logic       clk,
    input  var logic       rst,

    // ── Host configuration — per-symbol reference price ──────────────────────
    // Written from the previous close at start of day and re-centred from the
    // last trade at a slow (millisecond) cadence. Applying it CLEARS the
    // symbol's book: every stored level index is relative to the base, so a new
    // base makes the old contents meaningless.
    // ⚠️ The order map must be cleared for this symbol at the same time or the
    //    §3.2 invariant breaks — see the report / book_engine (R5).
    input  var logic       cfg_valid,
    input  var sym_idx_t   cfg_sym,
    input  var price_t     cfg_ref_px,     // must be a whole tick
    output var logic       cfg_ready,      // handshake: combinational by exception

    // ── Early window check — gates the ORDER MAP insert (§3.2 invariant) ─────
    // The order map sits UPSTREAM of this block, so it cannot gate on
    // res_in_window. This port answers "would this price land in the window?"
    // one cycle after the request, from the same base registers and the same
    // arithmetic, so the map and the level array agree by construction.
    input  var logic       chk_valid,
    input  var sym_idx_t   chk_sym,
    input  var price_t     chk_price,
    output var logic       chk_ack,
    output var logic       chk_in_window,
    output var logic       chk_stale,

    // ── Update request ───────────────────────────────────────────────────────
    input  var logic       upd_valid,
    input  var sym_idx_t   upd_sym,
    input  var side_e      upd_side,
    input  var price_t     upd_price,
    input  var qty_t       upd_add,      // shares joining this level
    input  var qty_t       upd_del,      // shares leaving this level
    input  var logic       upd_clear,    // BOOK_CLEAR: wipe this symbol

    // ── Level lookup (port B) — top_of_book's rescan quantity fetch ──────────
    // Shares the level array read port with the fast path. The fast path always
    // wins; lk_ready is low while a book update is being classified. The 10GbE
    // feed cannot present a book event on every cycle (the shortest ITCH message
    // is several 64-bit beats), so the port is free most cycles.
    input  var logic       lk_valid,
    input  var sym_idx_t   lk_sym,
    input  var side_e      lk_side,
    input  var logic [LVL_W-1:0] lk_level,
    output var logic       lk_ready,     // combinational by exception (ready)
    output var logic       lk_ack,       // 1 cycle after lk_valid && lk_ready
    output var qty_t       lk_qty,

    // ── Result, 2 cycles later ───────────────────────────────────────────────
    // res_valid marks a result BEAT. What it means is qualified by res_clear and
    // res_in_window:
    //   res_clear                    -> wipe this symbol
    //   !res_clear &&  res_in_window -> level update, apply it
    //   !res_clear && !res_in_window -> rejected update, do NOT apply; res_stale
    //                                   carries the consequence
    output var logic       res_valid,
    output var sym_idx_t   res_sym,
    output var side_e      res_side,
    output var logic [LVL_W-1:0] res_level,
    output var price_t     res_price,
    output var price_t     res_base,       // window base used for this symbol
    output var qty_t       res_qty,        // level quantity AFTER the update
    output var logic       res_occupied,   // level is non-empty after the update
    output var logic       res_in_window,  // price fell inside the window
    output var logic       res_clear,      // this beat was a BOOK_CLEAR
    output var logic       res_stale,      // this SYMBOL is stale
    output var logic [N_LEVELS-1:0] res_occ, // post-update occupancy, res_side

    // ── Re-anchor request to the host (registered pulse) ─────────────────────
    output var logic       ranch_valid,
    output var sym_idx_t   ranch_sym,

    // ── Health ───────────────────────────────────────────────────────────────
    output var logic [31:0] cnt_oow_better,   // ⚠️ top of book was wrong
    output var logic [31:0] cnt_oow_worse,    // benign, window drifting
    output var logic [31:0] cnt_subtick,      // ⚠️ price not on a tick boundary
    output var logic [31:0] cnt_no_anchor,    // ⚠️ symbol never configured
    output var logic [31:0] cnt_underflow,    // ⚠️ delete exceeded resting qty
    output var logic [31:0] cnt_forward,      // level-word RMW forwards
    output var logic [31:0] cnt_forward_occ,  // occupancy-word RMW forwards
    output var logic [31:0] cnt_reanchor,     // host reference prices applied
    output var logic [31:0] cnt_cfg_reject,   // ⚠️ host wrote a sub-tick price
    output var logic [31:0] cnt_stale_sym,    // symbols entering STALE
    output var logic [31:0] cnt_clear,        // BOOK_CLEAR beats
    output var logic [31:0] cnt_lookup        // rescan quantity fetches served
);

    // =========================================================================
    // 1. Geometry — all elaboration-time. No hardware divider (CLAUDE.md §5.3).
    // =========================================================================
    localparam int unsigned N_SIDES    = 2;
    localparam int unsigned SIDE_W     = $clog2(N_SIDES);           // 1
    localparam int unsigned PACK_W     = $clog2(LVL_PACK);          // 1
    localparam int unsigned WORD_W     = LVL_PACK * QTY_W;          // 64
    localparam int unsigned WORD_IDX_W = LVL_W - PACK_W;            // 10
    localparam int unsigned LVL_ADDR_W = ACT_IDX_W + SIDE_W + WORD_IDX_W; // 19
    localparam int unsigned LVL_WORDS  = 1 << LVL_ADDR_W;           // 524288
    localparam int unsigned OCC_IDX_W  = LVL_W + SIDE_W;            // 12
    localparam int unsigned OCC_W      = 1 << OCC_IDX_W;            // 4096
    localparam int unsigned SPAN_UNITS = N_LEVELS * TICK_UNITS;     // 204800
    localparam int unsigned HALF_SPAN  = (N_LEVELS >> 1) * TICK_UNITS;
    // Any delta at or beyond the span is rejected by a plain magnitude compare,
    // so the reciprocal multiplier only ever sees an operand below the span.
    // That keeps it to one narrow multiply instead of a full 32x32.
    localparam int unsigned DELTA_W    = $clog2(SPAN_UNITS);        // 18
    localparam int unsigned OOW_CNT_W  = $clog2(OOW_THRESH + 1);

    // ── Tick reciprocal, derived from TICK_UNITS at elaboration ──────────────
    // q = (x * M) >> S  with  M = ceil(2^S / TICK_UNITS).
    // Granlund-Montgomery: with e = M*TICK_UNITS - 2^S, the identity
    // floor(x*M >> S) == floor(x / TICK_UNITS) holds for every x with x*e < 2^S.
    // That bound is checked below against the widest operand this module can
    // present, so the divide is EXACT, not approximate.
    localparam int unsigned TICK_SH = 37;

    function automatic logic [63:0] f_ceil_div(input logic [63:0] a,
                                               input logic [63:0] b);
        return (a + b - 64'd1) / b;  // validate: allow divide — elaboration-time constant fold; the result is a localparam, no divider is inferred
    endfunction

    localparam logic [63:0] TICK_RECIP_W = f_ceil_div(64'd1 << TICK_SH,
                                                      64'(TICK_UNITS));
    localparam logic [31:0] TICK_RECIP_L = TICK_RECIP_W[31:0];
    localparam logic [63:0] TICK_ERR     = (TICK_RECIP_W * 64'(TICK_UNITS))
                                         - (64'd1 << TICK_SH);
    localparam logic [63:0] TICK_XMAX    = (64'd1 << DELTA_W) - 64'd1;

    typedef logic [LVL_W-1:0]      lvl_t;
    typedef logic [LVL_ADDR_W-1:0] laddr_t;
    typedef logic [OCC_W-1:0]      occw_t;

    // Saturating unsigned add. A wrapped level quantity presents as a ~4.29
    // billion share phantom at the touch and a strategy will act on it.
    function automatic qty_t qty_sat_add(input qty_t a, input qty_t b);
        logic [QTY_W:0] s;
        s = {1'b0, a} + {1'b0, b};
        return s[QTY_W] ? {QTY_W{1'b1}} : s[QTY_W-1:0];
    endfunction

    // =========================================================================
    // 2. Storage
    // =========================================================================
    // Level quantities. LVL_PACK entries per physical word.
    // Address = {sym, side, level[LVL_W-1:PACK_W]}; slot = level[PACK_W-1:0].
    (* ram_style = "ultra" *)
    logic [WORD_W-1:0] lvl_mem [LVL_WORDS];

    // Occupancy bitmap. BOTH SIDES in one word, so clearing a symbol is a single
    // write and never needs a second cycle or a stall.
    // Bit index = {side, level}.
    (* ram_style = "block" *)
    occw_t occ_mem [N_ACTIVE];

    // Per-symbol window state. Control/config -> reset. base_q is datapath and
    // is qualified by base_val_q, so it needs no reset.
    price_t               base_q     [N_ACTIVE];
    logic                 base_val_q [N_ACTIVE];
    logic                 stale_q    [N_ACTIVE];
    logic                 ranch_q    [N_ACTIVE];
    logic [OOW_CNT_W-1:0] oow_cnt_q  [N_ACTIVE];

    // The occupancy bitmap is the validity bitmap, so it is the one memory whose
    // power-up contents matter. FPGA block RAM initializes to zero at
    // configuration; this makes that explicit and gives simulation the same
    // starting state.
    initial begin
        for (int unsigned s = 0; s < N_ACTIVE; s++) occ_mem[s] = '0;
    end

    // =========================================================================
    // 3. Stage A — classify the price against the symbol's window
    // =========================================================================
    logic               a_sidx;
    price_t             a_base;
    logic               a_bval;
    logic [31:0]        a_delta_full;
    logic [DELTA_W-1:0] a_delta;
    logic [63:0]        a_prod;
    logic [31:0]        a_ticks;
    logic               a_below, a_above, a_exact, a_inwin;
    lvl_t               a_level;
    logic               a_oow_hi, a_oow_lo;
    logic               a_oow_better, a_oow_worse, a_subtick, a_noanchor;

    always_comb begin
        a_sidx       = (upd_side == SIDE_SELL);
        a_base       = base_q[upd_sym];
        a_bval       = base_val_q[upd_sym];

        a_below      = (upd_price < a_base);
        a_delta_full = upd_price - a_base;
        a_above      = !a_below && (a_delta_full >= 32'(SPAN_UNITS));

        // Only meaningful when the price is inside the span; a_above is decided
        // on the untruncated difference above, so the truncation is safe.
        a_delta      = a_delta_full[DELTA_W-1:0];
        a_prod       = 64'(a_delta) * 64'(TICK_RECIP_L);
        a_ticks      = 32'(a_prod >> TICK_SH);
        a_level      = a_ticks[LVL_W-1:0];

        // ⚠️ Sub-tick detection is not optional (manual §4). Truncating a
        //    sub-penny price maps two distinct prices onto one level and that
        //    level's aggregate is permanently wrong.
        a_exact      = (a_ticks * 32'(TICK_UNITS)) == 32'(a_delta);

        a_inwin      = a_bval && !a_below && !a_above && a_exact;
        a_oow_hi     = a_bval && a_above;
        a_oow_lo     = a_bval && a_below;
        a_oow_better = (upd_side == SIDE_BUY) ? a_oow_hi : a_oow_lo;
        a_oow_worse  = (upd_side == SIDE_BUY) ? a_oow_lo : a_oow_hi;
        a_subtick    = a_bval && !a_below && !a_above && !a_exact;
        a_noanchor   = !a_bval;
    end

    // =========================================================================
    // 3b. Early window check — the §3.2 invariant gate for the order map
    // =========================================================================
    // "An order is in the order map IF AND ONLY IF its quantity is in the level
    //  array." The map is UPSTREAM of this block, so it cannot gate on
    // res_in_window — by the time that exists the insert has already happened.
    // This port answers the same question from the same base registers with the
    // same arithmetic, one cycle after the request, so the two structures agree
    // by construction rather than by hope.
    //
    // Side is deliberately absent: the window is per SYMBOL, not per side, so
    // bid and ask level indices are directly comparable.
    //
    // ⚠️ The base can only change on a host re-anchor, which also clears the
    //    symbol and stales it. The integrator must clear the order map for that
    //    symbol at the same time; otherwise the handful of orders in flight
    //    across the re-anchor violate the invariant.
    price_t             c_base;
    logic               c_bval;
    logic [31:0]        c_delta_full;
    logic [DELTA_W-1:0] c_delta;
    logic [63:0]        c_prod;
    logic [31:0]        c_ticks;
    logic               c_below, c_above, c_exact, c_in;

    always_comb begin
        c_base       = base_q[chk_sym];
        c_bval       = base_val_q[chk_sym];
        c_below      = (chk_price < c_base);
        c_delta_full = chk_price - c_base;
        c_above      = !c_below && (c_delta_full >= 32'(SPAN_UNITS));
        c_delta      = c_delta_full[DELTA_W-1:0];
        c_prod       = 64'(c_delta) * 64'(TICK_RECIP_L);
        c_ticks      = 32'(c_prod >> TICK_SH);
        c_exact      = (c_ticks * 32'(TICK_UNITS)) == 32'(c_delta);
        c_in         = c_bval && !c_below && !c_above && c_exact;
    end

    always_ff @(posedge clk) begin
        if (rst) chk_ack <= 1'b0;
        else     chk_ack <= chk_valid;
        chk_in_window <= c_in;
        chk_stale     <= stale_q[chk_sym];
    end

    // =========================================================================
    // 4. Read port arbitration — fast path always wins
    // =========================================================================
    logic     lk_fire, lk_sidx;

    assign lk_ready = !upd_valid;          // combinational by exception (ready)
    assign lk_fire  = lk_valid && lk_ready;
    assign lk_sidx  = (lk_side == SIDE_SELL);

    laddr_t               rd_addr_c;
    sym_idx_t             rd_sym_c;
    logic [OCC_IDX_W-1:0] rd_occidx_c;
    logic [LVL_PACK-1:0]  rd_slot_c;
    lvl_t                 rd_level_c;

    always_comb begin
        if (lk_fire) begin
            rd_sym_c    = lk_sym;
            rd_level_c  = lk_level;
            rd_occidx_c = {lk_sidx, lk_level};
            rd_addr_c   = {lk_sym, lk_sidx, lk_level[LVL_W-1:PACK_W]};
        end else begin
            rd_sym_c    = upd_sym;
            rd_level_c  = a_level;
            rd_occidx_c = {a_sidx, a_level};
            rd_addr_c   = {upd_sym, a_sidx, a_level[LVL_W-1:PACK_W]};
        end
        rd_slot_c = '0;
        for (int unsigned p = 0; p < LVL_PACK; p++) begin
            rd_slot_c[p] = ((rd_level_c & lvl_t'(LVL_PACK - 1)) == lvl_t'(p));
        end
    end

    // =========================================================================
    // 5. Memories — synchronous read, synchronous write, 1-deep bypass
    // =========================================================================
    // ⚠️ SAME-LEVEL BACK-TO-BACK HAZARD. Consecutive ITCH messages very often hit
    //    the same price level — that is precisely what happens at the touch
    //    during active trading. The second message's read is issued in the same
    //    cycle as the first message's write, and an inferred RAM is read-first,
    //    so it returns the pre-write value. Forward instead of stalling: a stall
    //    would inject jitter into the deterministic path, and jitter is the thing
    //    this whole design exists to avoid. Every forward is counted.
    //
    // ⚠️ THE BYPASS IS EXACTLY AS DEEP AS THE READ LATENCY (manual §8). The write
    //    below is driven by COMBINATIONAL stage-B signals, so it lands one cycle
    //    after the read was issued and a 1-deep bypass is sufficient and
    //    necessary. Driving the memory from REGISTERED write signals — as the
    //    previous revision did — pushes the write out a further cycle and makes
    //    the 1-deep bypass one stage too shallow, which produces exactly the
    //    silent quantity drift of manual §8 but less often.
    //
    //    The bypass compares the read address and the write address as they were
    //    in the SAME cycle, so it overrides the memory output on every collision.
    //    The design therefore does not depend on the primitive's read-first /
    //    write-first / undefined collision behaviour — which matters, because
    //    UltraRAM does not guarantee it across ports.
    logic              lvl_we_c;
    laddr_t            lvl_wa_c;
    logic [WORD_W-1:0] lvl_wd_c;
    logic              occ_we_c;
    sym_idx_t          occ_wa_c;
    occw_t             occ_wd_c;

    logic [WORD_W-1:0] rd_word_q;
    occw_t             rd_occ_q;
    laddr_t            rd_addr_q;
    sym_idx_t          rd_sym_q;
    logic [OCC_IDX_W-1:0] rd_occidx_q;
    logic [LVL_PACK-1:0]  rd_slot_q;

    always_ff @(posedge clk) begin
        if (lvl_we_c) lvl_mem[lvl_wa_c] <= lvl_wd_c;
        rd_word_q <= lvl_mem[rd_addr_c];
    end

    always_ff @(posedge clk) begin
        if (occ_we_c) occ_mem[occ_wa_c] <= occ_wd_c;
        rd_occ_q <= occ_mem[rd_sym_c];
    end

    always_ff @(posedge clk) begin
        rd_addr_q   <= rd_addr_c;
        rd_sym_q    <= rd_sym_c;
        rd_occidx_q <= rd_occidx_c;
        rd_slot_q   <= rd_slot_c;
    end

    // 1-deep bypass registers, captured from the ACTUAL write signals.
    logic              fwd_lvl_en_q;
    laddr_t            fwd_lvl_addr_q;
    logic [WORD_W-1:0] fwd_lvl_data_q;
    logic              fwd_occ_en_q;
    sym_idx_t          fwd_occ_addr_q;
    occw_t             fwd_occ_data_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            fwd_lvl_en_q <= 1'b0;
            fwd_occ_en_q <= 1'b0;
        end else begin
            fwd_lvl_en_q <= lvl_we_c;
            fwd_occ_en_q <= occ_we_c;
        end
        fwd_lvl_addr_q <= lvl_wa_c;
        fwd_lvl_data_q <= lvl_wd_c;
        fwd_occ_addr_q <= occ_wa_c;
        fwd_occ_data_q <= occ_wd_c;
    end

    logic              fwd_lvl_hit, fwd_occ_hit;
    logic [WORD_W-1:0] word_eff;
    occw_t             occ_eff;

    always_comb begin
        fwd_lvl_hit = fwd_lvl_en_q && (fwd_lvl_addr_q == rd_addr_q);
        fwd_occ_hit = fwd_occ_en_q && (fwd_occ_addr_q == rd_sym_q);
        word_eff    = fwd_lvl_hit ? fwd_lvl_data_q : rd_word_q;
        occ_eff     = fwd_occ_hit ? fwd_occ_data_q : rd_occ_q;
    end

    // =========================================================================
    // 6. Stage-A -> Stage-B pipeline registers (fast path)
    // =========================================================================
    logic     b_valid_q, b_clear_q, b_inwin_q, b_sidx_q;
    sym_idx_t b_sym_q;
    side_e    b_side_q;
    price_t   b_price_q, b_base_q;
    qty_t     b_add_q, b_del_q;
    lvl_t     b_level_q;
    logic     b_oowb_q, b_ooww_q, b_sub_q, b_noanc_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            b_valid_q <= 1'b0;
            b_clear_q <= 1'b0;
        end else begin
            b_valid_q <= upd_valid;
            b_clear_q <= upd_valid && upd_clear;
        end
        b_sym_q   <= upd_sym;
        b_side_q  <= upd_side;
        b_sidx_q  <= a_sidx;
        b_price_q <= upd_price;
        b_base_q  <= a_base;
        b_add_q   <= upd_add;
        b_del_q   <= upd_del;
        b_level_q <= a_level;
        b_inwin_q <= a_inwin  && !upd_clear;
        b_oowb_q  <= a_oow_better && !upd_clear;
        b_ooww_q  <= a_oow_worse  && !upd_clear;
        b_sub_q   <= a_subtick    && !upd_clear;
        b_noanc_q <= a_noanchor   && !upd_clear;
    end

    // Lookup-port pipeline register.
    logic lk_pend_q;

    always_ff @(posedge clk) begin
        if (rst) lk_pend_q <= 1'b0;
        else     lk_pend_q <= lk_fire;
    end

    // =========================================================================
    // 7. Stage B — forward, saturating read-modify-write, write back
    // =========================================================================
    qty_t  raw_qty, eff_qty, sub_qty, new_qty;
    logic  occ_bit, new_occ, underflow;
    occw_t occ_next;

    always_comb begin
        raw_qty = '0;
        for (int unsigned p = 0; p < LVL_PACK; p++) begin
            raw_qty = raw_qty | (word_eff[p*QTY_W +: QTY_W] & {QTY_W{rd_slot_q[p]}});
        end

        // The occupancy bit IS the validity bit: a level whose bit is clear
        // reads as zero no matter what is physically stored there. This is what
        // makes clear and re-anchor a single-word write.
        occ_bit = occ_eff[rd_occidx_q];
        eff_qty = occ_bit ? raw_qty : '0;

        // Saturating subtract. A delete larger than the resting aggregate means
        // a gap or a decode error. Floor at zero and COUNT it.
        underflow = (b_del_q > eff_qty);
        sub_qty   = underflow ? '0 : (eff_qty - b_del_q);

        // Saturating add. NEVER wrap (see qty_sat_add).
        new_qty = qty_sat_add(sub_qty, b_add_q);
        new_occ = (new_qty != '0);

        // ⚠️ occ_next is the TRUE post-update occupancy in every case, because
        //    top_of_book priority-encodes it to find a new best. A rejected
        //    update must not perturb one bit of it — the level index of an
        //    out-of-window price is meaningless, and a spurious bit there would
        //    send the new-best search to a level that holds nothing.
        if (b_clear_q) begin
            occ_next = '0;
        end else begin
            occ_next = occ_eff;
            if (b_valid_q && b_inwin_q) occ_next[rd_occidx_q] = new_occ;
        end
    end

    // ── Level array write ────────────────────────────────────────────────────
    always_comb begin
        lvl_we_c = b_valid_q && b_inwin_q && !b_clear_q;
        lvl_wa_c = rd_addr_q;
        // Slots other than the addressed one are written back unchanged. Their
        // occupancy bits are untouched, so a slot holding stale bits from before
        // a clear still reads as zero.
        lvl_wd_c = word_eff;
        for (int unsigned p = 0; p < LVL_PACK; p++) begin
            if (rd_slot_q[p]) lvl_wd_c[p*QTY_W +: QTY_W] = new_qty;
        end
    end

    // =========================================================================
    // 8. Host configuration FSM (slow path)
    // =========================================================================
    typedef enum logic [1:0] {
        CFG_IDLE  = 2'd0,
        CFG_CALC  = 2'd1,   // reciprocal multiply
        CFG_CHK   = 2'd2,   // tick-alignment proof + window base
        CFG_APPLY = 2'd3    // wait for the occupancy write slot, then commit
    } cfg_state_e;

    cfg_state_e  cfg_st_q;
    sym_idx_t    cfg_sym_q;
    price_t      cfg_px_q, cfg_base_q;
    logic [31:0] cfg_ticks_q;

    logic        cfg_apply;
    logic        occ_beat_we;
    logic [63:0] cfg_prod;
    logic [31:0] cfg_ticks_c;
    logic        cfg_aligned_c;
    price_t      cfg_base_c;

    assign cfg_ready = (cfg_st_q == CFG_IDLE);

    always_comb begin
        cfg_prod      = 64'(cfg_px_q) * 64'(TICK_RECIP_L);
        cfg_ticks_c   = 32'(cfg_prod >> TICK_SH);
        // Constant multiply -> shifts and adds, no DSP, no divider.
        cfg_aligned_c = (cfg_ticks_q * 32'(TICK_UNITS)) == cfg_px_q;
        // Centre the window on the reference so the price can move either way.
        cfg_base_c    = (cfg_px_q > price_t'(HALF_SPAN))
                      ? (cfg_px_q - price_t'(HALF_SPAN))
                      : '0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            cfg_st_q <= CFG_IDLE;
        end else begin
            unique case (cfg_st_q)
                CFG_IDLE:  if (cfg_valid) cfg_st_q <= CFG_CALC;
                CFG_CALC:                 cfg_st_q <= CFG_CHK;
                CFG_CHK:   cfg_st_q <= cfg_aligned_c ? CFG_APPLY : CFG_IDLE;
                CFG_APPLY: if (cfg_apply) cfg_st_q <= CFG_IDLE;
                default:                  cfg_st_q <= CFG_IDLE;
            endcase
        end

        if (cfg_valid && cfg_ready) begin
            cfg_sym_q <= cfg_sym;
            cfg_px_q  <= cfg_ref_px;
        end
        if (cfg_st_q == CFG_CALC) cfg_ticks_q <= cfg_ticks_c;
        if (cfg_st_q == CFG_CHK)  cfg_base_q  <= cfg_base_c;
    end

    // ── Occupancy array write: beat first, configuration on a free cycle ─────
    always_comb begin
        occ_beat_we = b_valid_q && (b_clear_q || b_inwin_q);
        cfg_apply   = (cfg_st_q == CFG_APPLY) && !occ_beat_we;
        occ_we_c    = occ_beat_we || cfg_apply;
        occ_wa_c    = cfg_apply ? cfg_sym_q : b_sym_q;
        occ_wd_c    = cfg_apply ? '0 : occ_next;   // occ_next is already '0 on a clear
    end

    // =========================================================================
    // 9. Per-symbol window state, stale, and the re-anchor request
    // =========================================================================
    logic b_reject, b_stale_set, b_oow_sat, b_ranch_set;

    always_comb begin
        // Every rejected update raises a re-anchor request. None is silent.
        b_reject    = b_valid_q && !b_clear_q && !b_inwin_q;
        b_oow_sat   = b_ooww_q && (oow_cnt_q[b_sym_q] >= OOW_CNT_W'(OOW_THRESH));
        // A price BETTER than the whole window means the published top of book
        // is wrong -> stale now. A sub-tick price cannot be represented -> stale
        // now. No host reference at all -> the symbol has no book -> stale.
        b_stale_set = b_valid_q && (b_oowb_q || b_sub_q || b_noanc_q || b_oow_sat);
        b_ranch_set = b_reject && !ranch_q[b_sym_q];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned s = 0; s < N_ACTIVE; s++) begin
                base_val_q[s] <= 1'b0;
                stale_q[s]    <= 1'b0;
                ranch_q[s]    <= 1'b0;
                oow_cnt_q[s]  <= '0;
            end
        end else begin
            // Fast-path effects.
            if (b_stale_set)          stale_q[b_sym_q] <= 1'b1;
            if (b_reject)             ranch_q[b_sym_q] <= 1'b1;
            if (b_ooww_q && !b_oow_sat)
                oow_cnt_q[b_sym_q] <= oow_cnt_q[b_sym_q] + OOW_CNT_W'(1);
            // BOOK_CLEAR restarts the drift accounting but does NOT lift STALE:
            // a symbol leaves STALE only when the host writes a fresh reference.
            if (b_valid_q && b_clear_q) oow_cnt_q[b_sym_q] <= '0;

            // Host configuration wins over the fast path for these registers;
            // it only ever fires on a cycle with no occupancy beat write, so it
            // cannot race a same-symbol update.
            if (cfg_apply) begin
                base_val_q[cfg_sym_q] <= 1'b1;
                stale_q[cfg_sym_q]    <= 1'b0;
                ranch_q[cfg_sym_q]    <= 1'b0;
                oow_cnt_q[cfg_sym_q]  <= '0;
            end
        end

        if (cfg_apply) base_q[cfg_sym_q] <= cfg_base_q;   // datapath: no reset
    end

    always_ff @(posedge clk) begin
        if (rst) ranch_valid <= 1'b0;
        else     ranch_valid <= b_ranch_set;
        ranch_sym <= b_sym_q;
    end

    // =========================================================================
    // 10. Registered outputs
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            res_valid <= 1'b0;
            lk_ack    <= 1'b0;
        end else begin
            res_valid <= b_valid_q;
            lk_ack    <= lk_pend_q;
        end

        res_sym       <= b_sym_q;
        res_side      <= b_side_q;
        res_level     <= b_level_q;
        res_price     <= b_price_q;
        res_base      <= b_base_q;
        res_qty       <= new_qty;
        res_occupied  <= new_occ;
        res_in_window <= b_inwin_q;
        res_clear     <= b_clear_q;
        res_stale     <= stale_q[b_sym_q] || b_stale_set;
        res_occ       <= b_sidx_q ? occ_next[OCC_W-1:N_LEVELS]
                                  : occ_next[N_LEVELS-1:0];

        lk_qty        <= eff_qty;
    end

    // =========================================================================
    // 11. Health counters
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_oow_better  <= '0;
            cnt_oow_worse   <= '0;
            cnt_subtick     <= '0;
            cnt_no_anchor   <= '0;
            cnt_underflow   <= '0;
            cnt_forward     <= '0;
            cnt_forward_occ <= '0;
            cnt_reanchor    <= '0;
            cnt_cfg_reject  <= '0;
            cnt_stale_sym   <= '0;
            cnt_clear       <= '0;
            cnt_lookup      <= '0;
        end else begin
            if (b_valid_q && b_oowb_q)   cnt_oow_better  <= cnt_oow_better  + 32'd1;
            if (b_valid_q && b_ooww_q)   cnt_oow_worse   <= cnt_oow_worse   + 32'd1;
            if (b_valid_q && b_sub_q)    cnt_subtick     <= cnt_subtick     + 32'd1;
            if (b_valid_q && b_noanc_q)  cnt_no_anchor   <= cnt_no_anchor   + 32'd1;
            if (b_valid_q && b_inwin_q && underflow)
                                         cnt_underflow   <= cnt_underflow   + 32'd1;
            if (b_valid_q && fwd_lvl_hit) cnt_forward    <= cnt_forward     + 32'd1;
            if (b_valid_q && fwd_occ_hit) cnt_forward_occ<= cnt_forward_occ + 32'd1;
            if (cfg_apply)               cnt_reanchor    <= cnt_reanchor    + 32'd1;
            if ((cfg_st_q == CFG_CHK) && !cfg_aligned_c)
                                         cnt_cfg_reject  <= cnt_cfg_reject  + 32'd1;
            if (b_stale_set && !stale_q[b_sym_q])
                                         cnt_stale_sym   <= cnt_stale_sym   + 32'd1;
            if (b_valid_q && b_clear_q)  cnt_clear       <= cnt_clear       + 32'd1;
            if (lk_pend_q)               cnt_lookup      <= cnt_lookup      + 32'd1;
        end
    end

    // =========================================================================
    // 12. Assertions
    // =========================================================================
`ifndef SYNTHESIS
    // ── Elaboration-time geometry and tick-linkage proofs ────────────────────
    initial begin
        if (N_LEVELS < 2 || ((N_LEVELS & (N_LEVELS - 1)) != 0)) begin
            $error("price_levels: N_LEVELS must be a power of two >= 2 (got %0d) — the level index is a bit-slice of the tick count.", N_LEVELS);
            $fatal(1);
        end
        if ((LVL_PACK == 0) || ((LVL_PACK & (LVL_PACK - 1)) != 0)) begin
            $error("price_levels: LVL_PACK must be a power of two (got %0d).", LVL_PACK);
            $fatal(1);
        end
        if (LVL_PACK > N_LEVELS) begin
            $error("price_levels: LVL_PACK (%0d) exceeds N_LEVELS (%0d).", LVL_PACK, N_LEVELS);
            $fatal(1);
        end
        // ⚠️ TICK_UNITS <-> reciprocal linkage. Changing TICK_UNITS for a
        //    half-penny regime without changing the reciprocal silently yields
        //    wrong level indices; this makes that impossible.
        if (TICK_RECIP_W[63:32] != 32'd0) begin
            $error("price_levels: ceil(2^%0d / %0d) = %0d does not fit 32 bits. Lower TICK_SH or widen the reciprocal.", TICK_SH, TICK_UNITS, TICK_RECIP_W);
            $fatal(1);
        end
        if ((TICK_ERR != 64'd0) && ((TICK_XMAX * TICK_ERR) >= (64'd1 << TICK_SH))) begin
            $error("price_levels: reciprocal /%0d is not exact over 0..%0d at shift %0d (error term %0d). Raise TICK_SH.", TICK_UNITS, TICK_XMAX, TICK_SH, TICK_ERR);
            $fatal(1);
        end
        if (TICK_RECIP_L != book_pkg::TICK_RECIP || TICK_SH != book_pkg::TICK_SHIFT) begin
            $error("price_levels: book_pkg::TICK_RECIP/TICK_SHIFT (%0d >> %0d) disagree with the value derived from TICK_UNITS=%0d (%0d >> %0d). book_pkg must derive them, not hardcode them.", book_pkg::TICK_RECIP, book_pkg::TICK_SHIFT, TICK_UNITS, TICK_RECIP_L, TICK_SH);
            $fatal(1);
        end
        if (N_LEVELS < 2048) begin
            $warning("price_levels: N_LEVELS = %0d gives a $%0d.%02d window. manuals/04-system-architecture/03-order-book-in-hardware.md §4 specifies 2048 levels ($20.48). Set trading_pkg::BOOK_LEVELS = 2048 (task R6).", N_LEVELS, SPAN_UNITS / PRICE_SCALE, (SPAN_UNITS % PRICE_SCALE) / 100);
        end
    end

    // ── The window arithmetic must be self-consistent ────────────────────────
    // If this ever fails, a published price and its level index disagree — which
    // is the defect class that produced bid = $0.00 (redesign §2.1).
    assert property (@(posedge clk) disable iff (rst)
        (res_valid && res_in_window)
            |-> (res_price == (res_base + price_t'(res_level) * price_t'(TICK_UNITS)))
    ) else $error("price_levels: price/level/base disagree");

    // ── §3.2 invariant, local half: quantity present <=> occupancy bit set ───
    assert property (@(posedge clk) disable iff (rst)
        (res_valid && res_in_window) |-> (res_occ[res_level] == res_occupied)
    ) else $error("price_levels: occupancy bit disagrees with the level quantity");

    assert property (@(posedge clk) disable iff (rst)
        (res_valid && res_in_window && res_occupied) |-> (res_qty != '0)
    ) else $error("price_levels: occupied level with zero quantity");

    // ── Saturation, never wrap ───────────────────────────────────────────────
    assert property (@(posedge clk) disable iff (rst)
        lvl_we_c |-> (new_qty >= sub_qty)
    ) else $error("price_levels: level quantity wrapped");

    assert property (@(posedge clk) disable iff (rst)
        (b_valid_q && b_inwin_q) |-> (new_qty >= b_add_q || new_qty == {QTY_W{1'b1}})
    ) else $error("price_levels: saturating add lost shares");

    // ── Nothing is applied outside the window, and nothing is silent ─────────
    assert property (@(posedge clk) disable iff (rst)
        (b_valid_q && !b_clear_q && !b_inwin_q) |-> !lvl_we_c
    ) else $error("price_levels: wrote a level for an out-of-window price");

    assert property (@(posedge clk) disable iff (rst)
        (b_valid_q && !b_clear_q && !b_inwin_q)
            |-> (b_oowb_q || b_ooww_q || b_sub_q || b_noanc_q)
    ) else $error("price_levels: rejected an update without a reason — silent discard");

    assert property (@(posedge clk) disable iff (rst)
        (b_valid_q && !b_clear_q && !b_inwin_q) |=> ranch_q[$past(b_sym_q)]
    ) else $error("price_levels: rejected an update without requesting a re-anchor");

    // A price better than the whole window means the published best is wrong.
    assert property (@(posedge clk) disable iff (rst)
        (b_valid_q && b_oowb_q) |-> b_stale_set
    ) else $error("price_levels: better-than-window price did not stale the symbol");

    // ── An unconfigured symbol must have no book at all (fail-closed) ────────
    assert property (@(posedge clk) disable iff (rst)
        (b_valid_q && b_noanc_q) |-> (!b_inwin_q && !lvl_we_c)
    ) else $error("price_levels: applied an update to an unanchored symbol");

    // ── The level index must be inside the window whenever it is used ────────
    assert property (@(posedge clk) disable iff (rst)
        (b_valid_q && b_inwin_q) |-> (32'(b_level_q) < 32'(N_LEVELS))
    ) else $error("price_levels: level index outside the window");

    // ── Early window check must never green-light an unconfigured symbol ─────
    // If it did, the order map would hold entries whose quantity is in no level,
    // and the §3.2 invariant — the entire correctness argument for out-of-window
    // handling — would be false.
    assert property (@(posedge clk) disable iff (rst)
        (chk_ack && chk_in_window) |-> base_val_q[$past(chk_sym)]
    ) else $error("price_levels: window check passed a symbol with no host reference");

    assert property (@(posedge clk) disable iff (rst)
        (chk_ack && chk_in_window) |-> ($past(c_ticks) < 32'(N_LEVELS))
    ) else $error("price_levels: window check passed a level outside the window");

    // ── Lookup port contract ─────────────────────────────────────────────────
    assert property (@(posedge clk) disable iff (rst)
        (lk_valid && lk_ready) |=> lk_pend_q
    ) else $error("price_levels: lookup accepted but not issued");

    assert property (@(posedge clk) disable iff (rst)
        lk_ready |-> !upd_valid
    ) else $error("price_levels: lookup port granted while the fast path was reading");

    // ── Configuration writes a tick-aligned base, or writes nothing ──────────
    assert property (@(posedge clk) disable iff (rst)
        cfg_apply |-> ((cfg_base_q + price_t'(HALF_SPAN)) >= cfg_base_q)
    ) else $error("price_levels: window base overflowed");

    assert property (@(posedge clk) disable iff (rst)
        ((cfg_st_q == CFG_CHK) && !cfg_aligned_c) |=> (cfg_st_q == CFG_IDLE)
    ) else $error("price_levels: sub-tick reference price was not rejected");
`endif

endmodule : price_levels

`default_nettype wire
