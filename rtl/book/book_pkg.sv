// =============================================================================
// book_pkg.sv — Internal types for the order book layer
// -----------------------------------------------------------------------------
// LATENCY  : n/a (type package)
// RESOURCE : n/a
// Governing manual: manuals/04-system-architecture/03-order-book-in-hardware.md
//
// These types are INTERNAL to rtl/book/. The cross-layer contract lives in
// rtl/pkg/trading_pkg.sv — do not move anything from here into that file
// without accepting that every other layer then depends on it.
//
// THE TWO-STRUCTURE PROBLEM
// -------------------------
// Nasdaq TotalView-ITCH is an ORDER-BASED feed. Execute (E/C), Cancel (X),
// Delete (D) and Replace (U) carry ONLY a 64-bit order reference — no symbol,
// no side, no price. So the book cannot be a price-level array alone. It needs:
//
//   (a) order_ref -> {sym, side, price, remaining_qty}   ← order_id_map.sv
//   (b) (sym, side, price) -> aggregate qty              ← price_levels.sv
//
// Every message resolves (a) to learn what to do to (b). Losing an entry in (a)
// means the corresponding quantity in (b) can never be removed, and the book
// diverges silently and permanently. That is why an insert failure marks the
// book STALE rather than being counted and ignored.
// =============================================================================
`ifndef BOOK_PKG_SV
`define BOOK_PKG_SV

package book_pkg;

    import trading_pkg::*;

    // -------------------------------------------------------------------------
    // 1. Order-ID map geometry
    // -------------------------------------------------------------------------
    parameter int unsigned MAP_WAYS     = ORDER_MAP_WAYS;                 // 4
    parameter int unsigned MAP_SETS     = ORDER_MAP_ENTRIES / MAP_WAYS;   // 16384
    parameter int unsigned MAP_SET_W    = $clog2(MAP_SETS);               // 14

    // The stored record for one live order.
    //
    // ⚠️ The FULL 64-bit key is stored, not a truncated tag. A truncated tag
    //    aliases two distinct order references onto one entry, and the book then
    //    applies an execution to the wrong resting order. That is silent
    //    mis-attribution — the book stays plausible and is wrong. The extra
    //    memory is not optional.
    typedef struct packed {
        logic                    valid;
        order_ref_t              key;      // full 64-bit ITCH order reference
        sym_idx_t                sym;
        side_e                   side;
        price_t                  price;
        qty_t                    qty;      // remaining shares
    } order_rec_t;

    parameter int unsigned ORDER_REC_W = $bits(order_rec_t);

    // -------------------------------------------------------------------------
    // 2. Price-level geometry
    // -------------------------------------------------------------------------
    // Levels are DIRECT-INDEXED on a tick-normalized price:
    //     level = (price - window_base) / TICK_UNITS
    //
    // Chosen over a sorted list (insertion is O(n) in fabric), a heap (multi-cycle
    // sift, variable latency) and a tree (log-depth pointer chase). Direct index
    // is one memory access and the occupancy bitmask makes "find the new best" a
    // priority-encode instead of a comparator tree.
    //
    // The cost is a BOUNDED WINDOW: prices outside it are counted and excluded
    // from top-of-book. That is acceptable because a hardware strategy acts on
    // the top of book, not on depth 40. See §5 of the governing manual.
    parameter int unsigned LEVELS       = BOOK_LEVELS;        // 16 per side
    parameter int unsigned LEVEL_W      = $clog2(LEVELS);     // 4

    // ITCH prices carry 4 implied decimals, so one cent = 100 units.
    //
    // ⚠️ TICK_UNITS is a PARAMETER, not a constant, because the SEC has been
    //    amending the Rule 612 minimum increment. A half-penny regime makes this
    //    50 and changes level spacing and queue economics. Do not hardcode 100
    //    anywhere downstream.
    //    > Verify: current SEC Rule 612 tick-size regime before deployment.
    //
    // Division is done by reciprocal multiply (no divider in fabric, CLAUDE.md
    // §5.3). RECIP = ceil(2^SHIFT / TICK_UNITS), exact over the ITCH price range.
    parameter int unsigned TICK_UNITS   = 100;
    parameter logic [31:0] TICK_RECIP   = 32'd1_374_389_535;   // ceil(2^37/100)
    parameter int unsigned TICK_SHIFT   = 37;

    typedef logic [LEVEL_W-1:0] level_idx_t;

    // Occupancy bitmask: one bit per level per side. This is the structure that
    // makes the delete-the-best case tractable — see top_of_book.sv.
    typedef logic [LEVELS-1:0]  occ_mask_t;

    // -------------------------------------------------------------------------
    // 3. Pipeline stage payload
    // -------------------------------------------------------------------------
    // Carried between book_engine stages. rx_cycle is threaded through unchanged
    // end-to-end; it is the baseline for every latency measurement in the system.
    typedef struct packed {
        logic        valid;
        book_op_e    op;
        sym_idx_t    sym;
        side_e       side;
        price_t      price;
        qty_t        qty;          // delta for EXECUTE/CANCEL, absolute for ADD
        order_ref_t  order_ref;
        order_ref_t  new_order_ref;
        logic        resolved;     // the order map produced a record
        logic        remove;       // this update empties the order
        cycle_t      rx_cycle;
    } stage_t;

    // -------------------------------------------------------------------------
    // 4. Helpers
    // -------------------------------------------------------------------------
    // Tick normalization without a divider.
    function automatic logic [31:0] to_ticks(input logic [31:0] delta);
        logic [63:0] prod;
        prod = 64'(delta) * 64'(TICK_RECIP);
        return 32'(prod >> TICK_SHIFT);
    endfunction

    // CRC-style hash over the 64-bit order reference, folded to the set index.
    // An XOR tree: one LUT level per fold, effectively free, and it spreads the
    // sequential order references Nasdaq issues far better than the low bits do.
    //
    // ⚠️ Using order_ref[MAP_SET_W-1:0] directly would look fine in testing and
    //    then cluster badly: references are handed out sequentially, so bursts of
    //    adds for one symbol land in adjacent sets and overflow one way at a time.
    function automatic logic [MAP_SET_W-1:0] map_hash(input order_ref_t k);
        logic [31:0] f32;
        logic [15:0] f16;
        f32 = k[63:32] ^ k[31:0];
        f16 = f32[31:16] ^ f32[15:0];
        // Golden-ratio multiply spreads the remaining correlation across bits.
        return (f16 * 16'd40_503) >> (16 - MAP_SET_W);
    endfunction

endpackage : book_pkg

`endif
