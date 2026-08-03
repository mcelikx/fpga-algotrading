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
    //
    // ⚠️ [R6] 2048 PER SIDE — a $20.48 window at a one-cent tick. This tracked
    //    trading_pkg::BOOK_LEVELS when that was 16 ($0.16), which is the fatal
    //    window defect of docs/ORDER-BOOK-REDESIGN.md §2.2. The single knob is
    //    still trading_pkg::BOOK_LEVELS; the SLR arithmetic that justifies the
    //    value lives there, next to N_ACTIVE, because the two multiply.
    parameter int unsigned LEVELS       = BOOK_LEVELS;        // 2048 per side
    parameter int unsigned LEVEL_W      = $clog2(LEVELS);     // 11

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
    parameter int unsigned TICK_SHIFT   = 37;

    // ⚠️ [R6] THE RECIPROCAL IS DERIVED FROM TICK_UNITS, NOT WRITTEN BESIDE IT.
    //    It used to be the literal 32'd1_374_389_535 sitting next to a
    //    parameterised TICK_UNITS. Setting TICK_UNITS = 50 for a half-penny
    //    regime then left the reciprocal at the /100 value and every level index
    //    in the system was silently wrong by a factor of two — the parameter
    //    changes, the constant does not, and nothing errors.
    //    docs/ORDER-BOOK-REDESIGN.md §2.6.
    //    rtl/book/price_levels.sv re-derives this independently and $fatal()s at
    //    elaboration if the two disagree, so the linkage cannot drift back.
    function automatic logic [63:0] tick_ceil_div(input logic [63:0] a,
                                                  input logic [63:0] b);
        // validate: allow divide — elaboration-time constant fold into a
        // localparam. No divider is inferred; there is no runtime operand.
        return (a + b - 64'd1) / b;
    endfunction

    parameter logic [31:0] TICK_RECIP =
        32'(tick_ceil_div(64'd1 << TICK_SHIFT, 64'(TICK_UNITS)));  // ceil(2^37/100)

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

    // ⚠️ [R6] `map_hash()` WAS HERE AND HAS BEEN DELETED. DO NOT RE-ADD IT.
    // -------------------------------------------------------------------------
    // It was the set-index hash of the original 4-way map, and it was WRONG:
    //
    //     f16 = f32[31:16] ^ f32[15:0];                  // 16 bits
    //     return (f16 * 16'd40_503) >> (16 - MAP_SET_W);
    //
    // Both multiply operands are 16 bits, so under the IEEE 1800 self-determined
    // sizing rules the product is a 16-BIT expression and the top half of the
    // true 32-bit product is DISCARDED BEFORE THE SHIFT. Verilator 5.050 reports
    // it exactly: "Operator ASSIGN expects 14 bits on the Assign RHS, but Assign
    // RHS's SHIFTR generates 16 bits."
    //
    // A golden-ratio (Fibonacci) multiply works by driving entropy UP into the
    // high half of the product and then shifting it back down. Those are the
    // bits that were thrown away. What survived was bits [15:2] of the LOW half —
    // very nearly the raw low-order bits of the folded key, which is precisely
    // the clustering the deleted comment warned against. Nasdaq issues order
    // references SEQUENTIALLY, so this degraded on exactly its real input.
    //
    // The correct form, recorded so the mistake is not repeated rather than so
    // the function can be restored, is to widen BEFORE multiplying:
    //     logic [31:0] prod;
    //     prod = 32'(f16) * 32'd40_503;
    //     return prod[31 -: MAP_SET_W];
    //
    // It is deleted rather than fixed because it has NO CALLERS ANYWHERE: not in
    // rtl/ (the map is cuckoo now and uses map_h0_raw/map_h1_raw below), not in
    // tb/, not in host/. A subtly-wrong helper left in a package is a trap for
    // whoever reaches for it next, and "it was already there" is how a weak hash
    // gets into a test that then PASSES A BROKEN DESIGN.
    //
    // MAP_WAYS / MAP_SETS / MAP_SET_W above are RETAINED rather than deleted with
    // it, because §5's fence banner states they are kept for the tb/ and host/
    // mirrors and reversing another task's declared decision is not this task's
    // call. Two facts for whoever settles it:
    //   * MAP_SET_W existed only to size map_hash's return, so with the function
    //     gone it has NO reader at all and Verilator now reports
    //     UNUSEDPARAM on it. MAP_SETS exists only to compute MAP_SET_W.
    //   * The claim in the §5 banner does not survive a grep: tb/ and host/
    //     mirror `trading_pkg::ORDER_MAP_WAYS`, not these three. Nothing outside
    //     this file reads MAP_WAYS, MAP_SETS or MAP_SET_W.
    // On that evidence all three are deletion candidates.

    // =========================================================================
    // 5. [R1 · CUCKOO ORDER MAP] — begin fenced section
    // -------------------------------------------------------------------------
    // ⚠️ EDIT FENCE. Everything between this banner and the matching "end fenced
    //    section" banner was added by task R1 (docs/ORDER-BOOK-REDESIGN.md §3.1)
    //    and is consumed exclusively by rtl/book/order_id_map.sv. If you are a
    //    different task touching this package, please open your own fenced
    //    section rather than interleaving edits here. Nothing above this banner
    //    was moved, renamed, or reformatted.
    //
    // WHY A SECOND GEOMETRY EXISTS ALONGSIDE MAP_WAYS / MAP_SETS
    // ----------------------------------------------------------
    // `MAP_WAYS` / `MAP_SETS` / `map_hash` above describe the ORIGINAL 4-way
    // set-associative map. That design overflows at 12.5 % load and has no
    // overflow region, so it disables the book within milliseconds of the open
    // (docs/ORDER-BOOK-REDESIGN.md §2.3). They are left in place because
    // tb/ and host/ mirrors still reference them; the RTL no longer does.
    // New work uses the CUCKOO_* geometry below.
    // =========================================================================

    // ── Geometry: d = 2 hash functions × b = 4 slots per bucket ───────────────
    // Published load thresholds before insertion failure (§3.1):
    //   d=2,b=1 → 0.500   d=2,b=2 → 0.897   d=2,b=4 → 0.976   d=2,b=8 → 0.996
    //
    // ⚠️ d = 2 is STRUCTURAL, not merely a default. The relocation engine kicks
    //    a victim to "the other table"; with d > 2 that becomes a choice and the
    //    involution below no longer holds. Changing it is a redesign.
    parameter int unsigned CUCKOO_TABLES  = 2;
    parameter int unsigned CUCKOO_SLOTS   = 4;

    // ⚠️ CAPACITY IS A MEASUREMENT, NOT A PREFERENCE.
    //    The single knob is `trading_pkg::ORDER_MAP_ENTRIES`. It must be set
    //    from the measured live-order histogram produced by
    //    `tools/pcap/stats.py` over a full TotalView-ITCH session for the ACTUAL
    //    subscribed universe — not from the 65,536 guess inherited from the
    //    original manual. Sizing table (docs/ORDER-BOOK-REDESIGN.md §3.1,
    //    140-bit record; ours is 138 bits, padded to 144 in URAM):
    //
    //      live orders │ slots @90% load │  memory  │ URAM288
    //      ────────────┼─────────────────┼──────────┼────────
    //          58,982  │      65,536     │  9.0 Mbit│   32     ← current default
    //         100,000  │     111,112     │ 15.6 Mbit│   55
    //         117,964  │     131,072     │ 18.1 Mbit│   64
    //         250,000  │     277,778     │ 38.9 Mbit│  136
    //         500,000  │     555,556     │ 77.8 Mbit│  271     ← does not fit
    //
    // ⚠️ THAT TABLE IS SIZED AT 90 % LOAD AND 90 % IS THE WRONG NUMBER.
    //    A model of the actual algorithm (see the MEASURED BEHAVIOUR block in
    //    order_id_map.sv) puts the knee between 85 % and 90 %: zero insert
    //    failures at 85 %, 322 at 90 %. Size for <= 80 % of slots, which for the
    //    manual's realistic p99 of 102,400 live orders means 131,072 slots
    //    (78 % load, 64 URAM288) — NOT the 111,112 the 90 % column suggests.
    //    The published 0.976 threshold for d=2/b=4 is an asymptotic result for
    //    an unbounded insert-time random-walk; it is not reachable by a bounded
    //    16-kick chain and must not be used as a sizing input.
    //
    // ⚠️ A VU9P SLR holds ~320 URAM288 and the ENTIRE fast path must fit in one
    //    SLR (manuals/04-system-architecture/03-*.md §5). With the redesigned
    //    2048-level array at 256 symbols (33.6 Mbit = 117 URAM), the order map
    //    may not exceed ~180 URAM without displacing the level array across an
    //    SLR boundary, which costs a pipeline register on every book access.
    //    The 500k row above is therefore unreachable at this symbol count; if
    //    measurement demands it, the tracked symbol count must come down.
    parameter int unsigned MAP_CAPACITY   = ORDER_MAP_ENTRIES;
    parameter int unsigned CUCKOO_BUCKETS = MAP_CAPACITY / (CUCKOO_TABLES * CUCKOO_SLOTS);

    // Fully-associative stash, searched IN PARALLEL with the two buckets.
    // One entry is reserved as the landing pad for a relocation chain that
    // exhausts MAX_KICKS, so the fast path may only occupy MAP_STASH-1.
    parameter int unsigned MAP_STASH      = 16;

    // Relocation chain bound. Unbounded displacement is forbidden on this path
    // (CLAUDE.md §5.2); on exhaustion the record rests in the stash.
    parameter int unsigned MAP_MAX_KICKS  = 16;

    // ── The two hash functions ────────────────────────────────────────────────
    // ⚠️ h1 MUST NOT be a trivial transform of h0. If h1 = rot(h0) or h0 ^ K,
    //    the two candidate buckets are perfectly correlated and the load factor
    //    collapses to the single-hash 12.5 % behaviour we are replacing.
    //    Independence here is bought three ways at once:
    //      1. Two DIFFERENT primitive polynomials — CRC-32C (Castagnoli) and
    //         CRC-32 (IEEE 802.3). As GF(2) linear maps they are different
    //         64→32 matrices; neither row space contains the other's.
    //      2. Two different non-zero seeds.
    //      3. DISJOINT bit selections: order_id_map takes the LOW bits of h0 and
    //         the HIGH bits of h1, so even a shared structural artefact in the
    //         middle of the word cannot correlate the two bucket indices.
    //    An independence smoke test runs in simulation — see order_id_map.sv.
    //
    // Both are pure XOR trees: no DSP, no multiply, no divider. ~200 LUT each.
    parameter logic [31:0] MAP_H0_POLY = 32'h1EDC_6F41;   // CRC-32C, Castagnoli
    parameter logic [31:0] MAP_H0_SEED = 32'hFFFF_FFFF;
    parameter logic [31:0] MAP_H1_POLY = 32'h04C1_1DB7;   // CRC-32, IEEE 802.3
    parameter logic [31:0] MAP_H1_SEED = 32'h5A5A_A5A5;

    // Bit-parallel CRC over the whole 64-bit reference. Written as an unrolled
    // shift-register recurrence; every output bit reduces to the parity of a
    // fixed subset of the 64 input bits, which synthesis flattens into a 2–3
    // LUT-level XOR tree. It is NOT a 64-deep serial chain in hardware.
    function automatic logic [31:0] map_crc32(input order_ref_t   k,
                                              input logic [31:0]  poly,
                                              input logic [31:0]  seed);
        logic [31:0] c;
        c = seed;
        for (int unsigned i = 0; i < 64; i++) begin
            c = {c[30:0], 1'b0} ^ (poly & {32{c[31] ^ k[63 - i]}});
        end
        return c;
    endfunction

    // Full-width hashes. The consuming module slices them to its own bucket
    // width, so capacity can be re-parameterized without touching the hashes.
    function automatic logic [31:0] map_h0_raw(input order_ref_t k);
        return map_crc32(k, MAP_H0_POLY, MAP_H0_SEED);
    endfunction

    function automatic logic [31:0] map_h1_raw(input order_ref_t k);
        return map_crc32(k, MAP_H1_POLY, MAP_H1_SEED);
    endfunction

    // =========================================================================
    // [R1 · CUCKOO ORDER MAP] — end fenced section
    // =========================================================================

    // =========================================================================
    // 6. [R6 · HOST BOOK CONFIGURATION] — begin fenced section
    // -------------------------------------------------------------------------
    // ⚠️ EDIT FENCE, opened per the convention of the R1 banner above. Added by
    //    task R6 (docs/ORDER-BOOK-REDESIGN.md §3.3, "book config port"). Nothing
    //    above was moved or renamed except the deletion recorded in §4.
    // =========================================================================

    // Region selector for the per-symbol reference price, carried in the top
    // three bits of the fabric config address inside the host's STRAT window.
    //
    //   fabric address = {BOOK_CFG_REGION, 5'b0, sym[ACT_IDX_W-1:0]}
    //                  = 16'h6000 | sym
    //   data           = reference price, ITCH units, MUST be a whole tick
    //
    // ⚠️ WHY IT LIVES IN THE STRATEGY WINDOW AND NOT IN ONE OF ITS OWN. The
    //    control plane has five config targets (telemetry_pkg::cfg_target_e) and
    //    the encoding has two spare values, so the architecturally correct answer
    //    is a sixth target CFG_TGT_BOOK with its own 0x600 CSR window. That is a
    //    three-file change in rtl/ctrl/ and rtl/telemetry/ which task R5/R6 does
    //    not own. The STRAT window is the right interim home for a specific
    //    reason, not for convenience: it is the ONE window csr_regfile
    //    deliberately leaves un-write-protected while trading is enabled,
    //    because it already carries a per-symbol price the host rewrites at
    //    millisecond cadence. The reference price has identical cadence and
    //    protection requirements. Putting it in RISK or TMPL would make
    //    re-anchoring impossible without disarming the card.
    //
    // ⚠️ Regions 3'b000/001/010 belong to strategy_engine (PARAM, SYMSTATE,
    //    POSFORCE — see rtl/strategy/strategy_pkg.sv). This value must stay
    //    distinct from all three, and strategy_engine's bad-address counter must
    //    be taught to ignore it. See the note in rtl/fpga_top.sv.
    parameter logic [2:0] BOOK_CFG_REGION = 3'b011;

    // =========================================================================
    // [R6 · HOST BOOK CONFIGURATION] — end fenced section
    // =========================================================================

endpackage : book_pkg

`endif
