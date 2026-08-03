// =============================================================================
// book_engine.sv — order book top level
// -----------------------------------------------------------------------------
// PURPOSE
//   Wires the three order-book structures into one fixed-latency pipeline and
//   owns everything that is a PROPERTY OF THE JOIN rather than of a leaf:
//     * the early price-window check that gates the order-map insert, which is
//       what makes the §3.2 population invariant true BY CONSTRUCTION,
//     * the ITCH 'U' (Replace) delete-then-add decomposition,
//     * the host per-symbol reference-price port (without it every symbol is
//       dead by design — the book fails closed, see §"HOST ANCHOR" below),
//     * the side-band pipeline that keeps op / symbol / rx_cycle aligned with
//       the beat they belong to, which is where the inter-module form of the
//       manual §8 write-back skew lives,
//     * the stat[16] telemetry map.
//
// LATENCY  : 7 cycles (44.8 ns @ 156.25 MHz, 6.4 ns period), input beat to
//            m_top_valid, FIXED for the fast path. Breakdown, and the row of
//            the master budget in rtl/fpga_top.sv that each one owns:
//              B0  input registration + early window check   1 cyc   6.4 ns
//              B1  order-map hash + bucket read              1 cyc   6.4 ns
//              B2  order-map compare + mutation              1 cyc   6.4 ns
//              B3  price-level classify + array read         1 cyc   6.4 ns
//              B4  price-level forward + RMW + write-back    1 cyc   6.4 ns
//              B5  incremental top of book                   1 cyc   6.4 ns
//              B6  output registration                       1 cyc   6.4 ns
//            +2 cycles (12.8 ns) when a best-level delete misses the cached
//            second best and forces a rescan: +1 to priority-encode the 2048-bit
//            occupancy word, +1 to fetch that level's true quantity over the
//            level-array port B. That fetch yields to the fast path, so under a
//            burst it waits; the wait is counted (`cnt_lk_wait`), the state is
//            never wrong, only later. This is the ONLY variable-latency
//            operation in the whole tick-to-trade path.
//            ⚠️ DESIGN TARGETS. Nothing here has been simulated, placed or
//               routed. cocotb and iverilog are not installed in this
//               environment, so this file has been LINTED ONLY. Replace these
//               with measured figures per
//               manuals/05-optimization/04-measurement-and-profiling.md.
//
// RESOURCE : dominated by the two leaves it instances, at N_ACTIVE = 256 and
//            BOOK_LEVELS = 2048:
//              order_id_map   ~32 URAM288  (65,536 slots x 138 bit)
//              price_levels   128 URAM288 (level array) + 57 BRAM36 (occupancy)
//              top_of_book    ~78 kFF (best + second best, both sides) + ~30 kLUT
//            This file itself adds:
//              rx_sym_q   256 x 48 bit  = 12.3 kbit LUTRAM
//              last_px_q  256 x 32 bit  =  8.2 kbit LUTRAM
//              side-band pipes, cfg holding register, stat mux  ~1 kLUT
//            Full SLR arithmetic: rtl/pkg/trading_pkg.sv §"SLR CAPACITY".
//            > Verify against the post-synthesis utilization report.
//
// Governing manual: manuals/04-system-architecture/03-order-book-in-hardware.md
//                   §4 (the window and its base)  §5 (memory budget)
//                   §8 (the read-modify-write hazard and the write-back skew)
//                   §9 (resynchronization)  §10 (book_stale)  §11 (B0-B4)
//                   manuals/00-foundations/03-hdl-and-rtl-coding.md
//                   docs/ORDER-BOOK-REDESIGN.md §2.4, §3.2 (task R5)
//
// =============================================================================
// CYCLE-ACCURATE TIMING — DERIVED, NOT ASSUMED
// -----------------------------------------------------------------------------
// One row per core clock. A signal is listed in the cycle during which it is
// STABLE at the output of the register that drives it. `E` is one book event.
//
//  cyc │ stable this cycle                              │ driven by
//  ────┼────────────────────────────────────────────────┼──────────────────────
//   0  │ s_evt, s_evt_valid                = E          │ feed_handler out reg
//      │ chk_valid / chk_sym / chk_price   = E          │ COMBINATIONAL, see ⚠️
//   1  │ evt_q, evt_valid_q                = E          │ B0 input register
//      │ map_in, map_in_valid              = E          │ comb mux, replay first
//      │ chk_ack, chk_in_window     = THE ANSWER FOR E  │ price_levels chk reg
//      │   -> req_in_window is consumed in the SAME cycle the map samples E
//   2  │ order_id_map stage 1: 8 bucket + 16 stash compares, mutation driven
//      │   combinationally onto the bucket write port (no wb_* skew — §8)
//   3  │ map res_valid / res_hit / res_sym / res_side   │ order_id_map out reg
//      │     / res_price / res_delta / res_add / res_remove
//      │ mp_op_q[1], mp_sym_q[1], mp_prn_q[1] = E       │ side-band pipe
//      │ price_levels upd_valid            = E          │ comb from the above
//   4  │ price_levels stage B: forward, saturating RMW, level write driven
//      │   combinationally (again: no wb_* skew)
//   5  │ lvl res_valid / res_sym / res_side / res_level │ price_levels out reg
//      │     / res_price / res_base / res_qty / res_occupied
//      │     / res_in_window / res_clear / res_stale / res_occ
//      │ rx_pipe_q[3]                      = E.rx_cycle │ side-band pipe
//      │   -> rx_sym_q[lvl_sym] takes E.rx_cycle at the 5->6 edge
//   6  │ top_valid / top_sym / top_bid_* / top_ask_*    │ top_of_book pub reg
//      │     / top_crossed / top_stale / top_changed
//      │   -> rx_sym_q[tob_sym] now reads E.rx_cycle
//   7  │ m_top, m_top_valid                             │ B6 output register
//
// ⚠️ THE ONE TIMING RISK IN THIS FILE. `chk_*` is driven COMBINATIONALLY from
//    `s_evt`, one cycle ahead of the map request it gates, because the answer
//    must exist in the same cycle the map samples the request. The path is
//    therefore: feed_handler output register -> this file's mux -> price_levels'
//    window arithmetic (32-bit magnitude compare, an 18x32 reciprocal multiply,
//    a shift and a multiply-compare) -> price_levels' chk register. That is a
//    full period for a non-trivial datapath and it is the first thing to check
//    in post-route timing. If it does not close, the fix is to register the mux
//    and add one cycle to B0 — a latency change, not a correctness change, and
//    the diagram above is what you re-derive it from.
//
// =============================================================================
// ⚠️ THE WRITE-BACK SKEW — ITS INTER-MODULE FORM, WHICH IS THIS FILE'S JOB
// -----------------------------------------------------------------------------
// manuals/.../03-order-book-in-hardware.md §8 and docs/ORDER-BOOK-REDESIGN.md
// §2.4 describe the defect in its INTRA-module form: `wb_en`/`wb_set`/`wb_way`/
// `wb_rec` assigned NON-BLOCKING inside a compare stage's always_ff and then
// consumed by a SEPARATE always_ff that performs the memory write. That second
// block sees the PREVIOUS cycle's values, so the write lands one cycle later
// than the forwarding comparison assumes and the one-deep bypass silently covers
// the wrong cycle. Both leaves now drive their write ports COMBINATIONALLY from
// the compare stage, so the write and the result register at the same edge and
// exactly one bypass stage is correct — see order_id_map.sv §"THE READ-MODIFY-
// WRITE HAZARD" and price_levels.sv §5.
//
// The identical defect has an INTER-MODULE form: a signal DERIVED at one stage
// of the diagram above and CONSUMED at another. It is not visible from reading
// either module; it is only visible from the diagram. The previous revision of
// this file had three instances, and all three are corrected here:
//
//   1. `is_clear` was computed at the MAP RESULT stage (cycle 3) and driven into
//      BOTH `price_levels.upd_clear` (sampled at cycle 3 — correct) AND
//      `top_of_book.upd_clear` (sampled at cycle 5 — TWO CYCLES EARLY). A clear
//      therefore wiped top-of-book for whatever beat happened to be at cycle 5,
//      and the real clear beat passed through top_of_book as an ordinary update.
//      FIX: top_of_book takes price_levels' own `res_clear`, which is aligned
//      with `res_valid` by construction and cannot drift from it.
//
//   2. `price_levels.upd_sym` for a BOOK_CLEAR was taken from `map_res_sym`.
//      order_id_map has no record to report for a clear, so it returns
//      `res_sym = '0`: every BOOK_CLEAR cleared symbol 0 and no other, and the
//      symbol that actually needed clearing kept its stale book. FIX: the clear
//      symbol comes from `mp_sym_q[1]`, the event's own symbol carried down the
//      side-band pipeline to exactly the map-result stage.
//
//   3. `rx_cycle` was carried in a 3-deep shift register and sampled six cycles
//      after the event entered — off by two, so every latency sample in the
//      system was attributed to the wrong message. A deeper shift register is
//      NOT the fix, for two reasons: it silently desynchronises the day any leaf
//      changes latency, and top_of_book has a second publish path (the rescan
//      commit) that has no fixed distance from any input beat at all.
//      FIX: `rx_sym_q[]`, one rx_cycle per symbol, written from the aligned
//      `rx_pipe_q[3]` on every price-level beat and read back by the published
//      symbol. For a fast-path publish that is exactly the beat's own rx_cycle;
//      for a rescan commit it is the rx_cycle of the beat that LAUNCHED the
//      rescan, which is the correct latency baseline for it, because that beat
//      is the market event the new top of book is a response to. Correct on both
//      paths, and immune to a leaf latency change.
//
// The `rx_cycle` field is threaded through UNCHANGED in value from input to
// output. It is the ingress timestamp captured by the network layer and is the
// baseline for every latency measurement in the system — corrupting it silently
// invalidates all performance telemetry.
//
// =============================================================================
// ⚠️ THE §3.2 POPULATION INVARIANT — WHY THE chk_* PORT EXISTS
// -----------------------------------------------------------------------------
// AN ORDER IS IN THE ORDER MAP IF AND ONLY IF ITS QUANTITY IS IN THE LEVEL
// ARRAY (docs/ORDER-BOOK-REDESIGN.md §3.2).
//
// The map sits UPSTREAM of price_levels, so it cannot gate on `res_in_window` —
// by the time that exists the insert has already happened. price_levels
// therefore exposes `chk_*`, a second port onto the SAME base registers running
// the SAME arithmetic, which answers "would this price land in the window?" one
// cycle after the request. This file issues that check one cycle ahead of the
// map request, from the same mux that will select the map request, so the answer
// and the request are the same message BY CONSTRUCTION rather than by timing
// luck. `map_req_in_window` is then a pure wire from `chk_in_window`.
//
// What this buys, and it is the whole correctness argument for out-of-window
// handling: an order outside the window was never added to a level, so it must
// never enter the map; its later delete then MISSES, and a miss for an order
// that was never tracked is a correct NO-OP rather than a book that has
// permanently lost quantity it can never remove.
//
// ⚠️ It is NOT gated on `chk_stale`. A stale symbol still applies in-window
//    updates in price_levels (staleness gates the STRATEGY, not the arithmetic),
//    so gating the insert on staleness would break the invariant in the other
//    direction. Staleness is counted here instead.
//
// =============================================================================
// HOST ANCHOR — THE BOOK IS DEAD UNTIL THE HOST WRITES A REFERENCE PRICE
// -----------------------------------------------------------------------------
// price_levels is HOST-ANCHORED and fails closed: a symbol with no reference
// price rejects every update, counts `cnt_no_anchor`, stales itself and raises a
// re-anchor request. That is deliberate — the alternative is a guessed window,
// which is what silently froze the previous book (redesign §2.2) — but it means
// `cfg_*` is not optional plumbing. WITHOUT IT THE ENTIRE BOOK IS INERT.
//
// The port is carried up to fpga_top and driven from the existing host_ctrl
// config path. Register map, host side:
//
//   window : STRAT (BAR offset 0x300), which is the one config window that is
//            deliberately NOT write-protected while trading is enabled, because
//            it already carries a per-symbol price the host refreshes at
//            millisecond cadence (sym_strat_t.fair_value). The reference price
//            has exactly that cadence requirement.
//   fabric address : {3'b011, 5'b0, sym[7:0]}   i.e. 0x6000 | sym
//   data           : reference price, ITCH units (4 implied decimals).
//                    MUST be a whole tick — price_levels rejects a sub-tick
//                    reference and counts `cnt_cfg_reject` rather than anchoring
//                    the window off-grid.
//   sequence       : write STRAT_ADDR = 0x6000|sym, then STRAT_DATA = ref_px.
//                    No commit pulse: the anchor takes effect on its own
//                    handshake, per symbol, and is not double-buffered.
//
// ⚠️ APPLYING A REFERENCE PRICE CLEARS THAT SYMBOL'S LEVEL ARRAY. Every stored
//    level index is relative to the base, so a new base makes the old contents
//    meaningless. price_levels does that clear in one occupancy write.
// ⚠️ IT DOES NOT CLEAR THE ORDER MAP, AND IT CANNOT. order_id_map's only clear
//    is BOOK_CLEAR, which wipes ALL symbols; issuing it for a one-symbol
//    re-anchor would destroy every other symbol's map population while leaving
//    their level quantities in place — a far worse invariant break than the one
//    it would fix. So orders resting across a re-anchor stay in the map with
//    their quantity gone from the array. Consequences are bounded and counted,
//    not silent: their deletes underflow and saturate at zero (`cnt_underflow`).
//    The residual exposure is a delete arriving after a NEW order has rebuilt
//    the same level, which subtracts from quantity that is not its own.
//    Manual §9.2 covers this operationally — the symbol is stale and not trading
//    across a re-anchor, and step 6 reconciles hardware against the host shadow
//    book before it is re-enabled. The structural fix is a per-symbol clear on
//    order_id_map (or the epoch scheme of manual §9.1 bumped in BOTH structures
//    from the same signal); that is order_id_map's interface, not this file's.
// =============================================================================
`default_nettype none

module book_engine
    import trading_pkg::*;
    import book_pkg::*;
#(
    // Levels per side. Tracks book_pkg::LEVELS so the package stays the single
    // source of truth. Both leaves default to the same expression; it is passed
    // explicitly so an accidental override at one instance cannot silently
    // produce two different geometries either side of the res_occ / upd_occ bus.
    parameter int unsigned N_LEVELS = book_pkg::LEVELS,
    // Pipeline depth of top_of_book's new-best priority encoder. 1 = registered
    // output. 0 puts a 2048-bit encode, a 2048-bit reflection mux and the
    // best-update logic in one 6.4 ns cycle; do not use it without post-route
    // evidence.
    parameter int unsigned ENC_PIPE = 1
) (
    input  var logic       clk,
    input  var logic       rst,            // synchronous, active high

    // ── Book events from the feed handler. NO BACKPRESSURE (CLAUDE.md §5.1) ──
    input  var book_evt_t  s_evt,
    input  var logic       s_evt_valid,

    // ── Host per-symbol reference price (SLOW PATH) ──────────────────────────
    // See §"HOST ANCHOR" above. cfg_ref_ready is a genuine handshake; the host
    // path has no backpressure, so it exists to be ASSERTED against rather than
    // obeyed, and a write that arrives while one is in flight is counted, never
    // silently dropped.
    input  var logic       cfg_ref_valid,
    input  var sym_idx_t   cfg_ref_sym,
    input  var price_t     cfg_ref_px,
    output var logic       cfg_ref_ready,

    // ── Top of book out (registered) ─────────────────────────────────────────
    output var book_top_t  m_top,
    output var logic       m_top_valid,

    // ── Telemetry. Map documented in §"STAT MAP" at the bottom of this file. ─
    output var logic [31:0] stat [16]
);

    localparam int unsigned LVL_W = (N_LEVELS > 1) ? $clog2(N_LEVELS) : 1;

    // =========================================================================
    // SLR CAPACITY — an ELABORATION CHECK, not a comment
    // =========================================================================
    // The whole fast path must fit one SLR. That claim is written out in prose
    // in rtl/pkg/trading_pkg.sv §"SLR CAPACITY"; here it is arithmetic that
    // $fatal()s. The point is that the next person to raise N_ACTIVE,
    // BOOK_LEVELS or ORDER_MAP_ENTRIES is STOPPED rather than silently pushed
    // across an SLR boundary — which costs a pipeline register on every book
    // access and is a latency change discovered at place-and-route.
    // ⚠️ Capacity is a measurement, not a preference.
    localparam int unsigned URAM_DEPTH = 4096;   // URAM288 is 4096 x 72
    localparam int unsigned URAM_WIDTH = 72;
    localparam int unsigned BRAM_WIDTH = 72;     // BRAM36 in 512 x 72 mode
    // ⚠️ Mirrors price_levels' LVL_PACK default. If that instantiation ever
    //    passes a different value, this number moves with it and the check below
    //    goes wrong in the SAFE direction only by luck — pass it here too.
    localparam int unsigned LVL_PACK_MIRROR = 2;

    localparam int unsigned LVL_WORDS =
        (N_ACTIVE * 2 * N_LEVELS) / LVL_PACK_MIRROR;   // validate: allow divide — elaboration-time constant fold, no operand exists at runtime
    localparam int unsigned URAM_LEVELS = LVL_WORDS / URAM_DEPTH;                                   // validate: allow divide — as above
    localparam int unsigned MAP_BUCK_PER_TABLE =
        ORDER_MAP_ENTRIES / (CUCKOO_TABLES * CUCKOO_SLOTS);                                          // validate: allow divide — as above
    localparam int unsigned URAM_MAP =
          CUCKOO_TABLES * CUCKOO_SLOTS
        * ((MAP_BUCK_PER_TABLE + URAM_DEPTH - 1) / URAM_DEPTH)                                       // validate: allow divide — as above
        * ((ORDER_REC_W       + URAM_WIDTH - 1) / URAM_WIDTH);                                       // validate: allow divide — as above
    localparam int unsigned URAM_SYMTAB = 3;     // manuals/04-*/02-*.md
    localparam int unsigned URAM_TOTAL  = URAM_LEVELS + URAM_MAP + URAM_SYMTAB;

    localparam int unsigned BRAM_OCC =
        ((2 * N_LEVELS) + BRAM_WIDTH - 1) / BRAM_WIDTH;                                              // validate: allow divide — as above
    localparam int unsigned BRAM_TOTAL = BRAM_OCC + 3;   // + symbol tables + top of book

    // =========================================================================
    // B0 — input registration
    // =========================================================================
    book_evt_t evt_q;
    logic      evt_valid_q;

    always_ff @(posedge clk) begin
        if (rst) evt_valid_q <= 1'b0;
        else     evt_valid_q <= s_evt_valid;
        evt_q <= s_evt;                       // datapath: qualified, no reset
    end

    // ── ITCH Order Replace ('U') is a DELETE plus an ADD ──────────────────────
    // ⚠️ 'U' does not modify in place: it retires the original order reference
    //    and creates a new one at a new price and size, losing queue priority.
    //    Modelling it as an in-place edit leaks the old reference and produces a
    //    book that slowly diverges. Here the original event performs the delete,
    //    and a synthetic BOOK_ADD is injected on the following cycle carrying the
    //    NEW reference. `replay_q` holds that injection.
    book_evt_t replay_q;
    logic      replay_valid_q;

    // High while evt_q holds a Replace, i.e. exactly one cycle before the
    // synthetic ADD is presented to the map. The early window check uses this to
    // stay one cycle ahead of the map mux below.
    logic replace_pending;
    assign replace_pending = evt_valid_q && (evt_q.op == BOOK_REPLACE);

    // `locate` and `exch_ts` ride the struct for telemetry and are deliberately
    // not consumed by any book structure: the book indexes on the compact active
    // symbol index, and it timestamps with OUR ingress cycle, never the venue's
    // clock. Scoped so the waiver names exactly what is unused and why, rather
    // than blanket-disabling the check for the file.
    /* verilator lint_off UNUSEDSIGNAL */
    book_evt_t map_in;
    /* verilator lint_on UNUSEDSIGNAL */
    logic      map_in_valid;

    always_comb begin
        map_in       = evt_q;              // defaults open the block: no latch
        map_in_valid = evt_valid_q;
        // The injected add takes priority so the pair stays adjacent and the
        // forwarding logic in order_id_map sees them back to back.
        if (replay_valid_q) begin
            map_in       = replay_q;
            map_in_valid = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            replay_valid_q <= 1'b0;
        end else begin
            replay_valid_q <= replace_pending;
        end
        replay_q <= '{ op:            BOOK_ADD,
                       sym:           evt_q.sym,
                       locate:        evt_q.locate,
                       side:          evt_q.side,
                       price:         evt_q.price,
                       qty:           evt_q.qty,
                       order_ref:     evt_q.new_order_ref,
                       new_order_ref: '0,
                       exch_ts:       evt_q.exch_ts,
                       rx_cycle:      evt_q.rx_cycle,
                       printable:     evt_q.printable };
    end

    // ⚠️ Backpressure note: injecting a replay cycle means the engine consumes
    //    two cycles for one 'U'. The feed handler does not backpressure, so a
    //    Replace immediately followed by another book event on the very next
    //    cycle would lose the second one. That cannot happen with a 10GbE feed:
    //    the shortest book-affecting ITCH message is Order Delete at 19 bytes,
    //    which is 3 beats of the 64-bit 156.25 MHz datapath, so consecutive book
    //    events are >= 3 cycles apart. The condition is a structural
    //    impossibility, which is exactly why it is counted (stat[15] bit 24)
    //    rather than assumed — an assumption that is never checked is a defect
    //    waiting for the day the datapath width changes.
    //    ⚠️ VERIFY the 19-byte figure against the TotalView-ITCH 5.0 spec.
    logic replay_collision;
    assign replay_collision = replay_valid_q && evt_valid_q;

    // =========================================================================
    // B0 — early price-window check (gates the order-map insert, §3.2)
    // =========================================================================
    // Issued ONE CYCLE AHEAD of the map request, from a mux with the same
    // priority as the map mux above, so the answer that arrives at cycle 1 is
    // the answer for the message the map samples at cycle 1. Only BOOK_ADD needs
    // it (`req_in_window` is ignored for every other op), and the synthetic ADD
    // of a Replace needs it a cycle later than the Replace itself — which is
    // exactly what `replace_pending` selects.
    logic     chk_valid;
    sym_idx_t chk_sym;
    price_t   chk_price;
    logic     chk_ack, chk_in_window, chk_stale;

    always_comb begin
        chk_valid = 1'b0;
        chk_sym   = s_evt.sym;
        chk_price = s_evt.price;
        if (replace_pending) begin
            // The synthetic ADD that will be presented next cycle carries the
            // Replace's NEW price and size at the same symbol.
            chk_valid = 1'b1;
            chk_sym   = evt_q.sym;
            chk_price = evt_q.price;
        end else if (s_evt_valid && (s_evt.op == BOOK_ADD)) begin
            chk_valid = 1'b1;
        end
    end

    // A pure wire, and that is the point: the map's insert gate and the level
    // array's classification come from one arithmetic block, one cycle apart.
    logic map_req_in_window;
    assign map_req_in_window = chk_ack && chk_in_window;

    // Counted, not acted on — see §"THE §3.2 POPULATION INVARIANT".
    logic add_on_stale;
    assign add_on_stale = chk_ack && chk_stale;

    // =========================================================================
    // B1..B2 — order id map (cuckoo, d = 2 x b = 4)
    // =========================================================================
    logic        map_res_valid, map_res_hit, map_res_remove, map_stale;
    sym_idx_t    map_res_sym;
    side_e       map_res_side;
    price_t      map_res_price;
    qty_t        map_res_delta, map_res_add;

    logic [31:0] m_cnt_insert, m_cnt_ifail, m_cnt_miss, m_cnt_delete, m_cnt_fwd;
    logic [15:0] m_occ_hi;
    logic [31:0] m_cnt_miss_benign, m_cnt_miss_tracked, m_cnt_stash_ins;
    logic [31:0] m_cnt_reloc, m_cnt_untracked, m_cnt_kick_exh, m_cnt_dup_add;
    logic [31:0] m_kick_hist [MAP_MAX_KICKS+1];
    logic [7:0]  m_kick_depth_hi;
    logic [31:0] m_live_hi;

    order_id_map u_map (
        .clk               (clk),
        .rst               (rst),
        .req_valid         (map_in_valid),
        .req_op            (map_in.op),
        .req_key           (map_in.order_ref),
        .req_new_key       (map_in.new_order_ref),
        .req_sym           (map_in.sym),
        .req_side          (map_in.side),
        .req_price         (map_in.price),
        .req_qty           (map_in.qty),
        .req_in_window     (map_req_in_window),
        .res_valid         (map_res_valid),
        .res_hit           (map_res_hit),
        .res_sym           (map_res_sym),
        .res_side          (map_res_side),
        .res_price         (map_res_price),
        .res_delta         (map_res_delta),
        .res_add           (map_res_add),
        .res_remove        (map_res_remove),
        .map_stale         (map_stale),
        .cnt_insert        (m_cnt_insert),
        .cnt_insert_fail   (m_cnt_ifail),
        .cnt_miss          (m_cnt_miss),
        .cnt_delete        (m_cnt_delete),
        .cnt_forward       (m_cnt_fwd),
        .occupancy_hi      (m_occ_hi),
        .cnt_miss_benign   (m_cnt_miss_benign),
        .cnt_miss_tracked  (m_cnt_miss_tracked),
        .cnt_stash_insert  (m_cnt_stash_ins),
        .cnt_relocation    (m_cnt_reloc),
        .cnt_untracked_add (m_cnt_untracked),
        .cnt_kick_exhaust  (m_cnt_kick_exh),
        .cnt_dup_add       (m_cnt_dup_add),
        .kick_hist         (m_kick_hist),
        .kick_depth_hi     (m_kick_depth_hi),
        .live_hi           (m_live_hi)
    );

    // =========================================================================
    // Side-band pipeline — op, symbol, printable, rx_cycle
    // =========================================================================
    // ⚠️ THIS IS WHERE THE INTER-MODULE WRITE-BACK SKEW WAS. Every one of these
    //    exists because a field of the event is needed at a stage where the
    //    module that would otherwise carry it does not have it:
    //      * `op`        — order_id_map does not report the opcode back, and a
    //                      BOOK_CLEAR must be recognised at the map-result stage.
    //      * `sym`       — order_id_map returns res_sym = '0 for BOOK_CLEAR
    //                      (there is no record to report), so the clear's symbol
    //                      must come from here or symbol 0 gets cleared instead.
    //      * `printable` — the last-trade price must only track PRINTABLE
    //                      executions; ITCH 'C' carries a non-printable form.
    //      * `rx_cycle`  — the latency baseline; see rx_sym_q below.
    //    Depths are read straight off the timing diagram in the header:
    //    index 1 is stable at cycle 3 (the map result), index 3 at cycle 5 (the
    //    price-level result).
    book_op_e mp_op_q  [2];
    sym_idx_t mp_sym_q [2];
    logic     mp_prn_q [2];
    cycle_t   rx_pipe_q [4];

    always_ff @(posedge clk) begin
        mp_op_q[0]  <= map_in.op;
        mp_op_q[1]  <= mp_op_q[0];
        mp_sym_q[0] <= map_in.sym;
        mp_sym_q[1] <= mp_sym_q[0];
        mp_prn_q[0] <= map_in.printable;
        mp_prn_q[1] <= mp_prn_q[0];

        rx_pipe_q[0] <= map_in.rx_cycle;
        rx_pipe_q[1] <= rx_pipe_q[0];
        rx_pipe_q[2] <= rx_pipe_q[1];
        rx_pipe_q[3] <= rx_pipe_q[2];
    end

    // =========================================================================
    // Host reference-price holding register (slow path)
    // =========================================================================
    // price_levels' cfg port is a 3-4 cycle handshake; the host config path
    // delivers at most one write per PCIe->core handshake round trip (~8 pcie +
    // ~6 core cycles, rtl/ctrl/host_ctrl.sv). One entry is therefore sufficient
    // by a wide margin. `cfg_drop` is the proof rather than the assumption.
    logic     cfg_pend_q;
    sym_idx_t cfg_pend_sym_q;
    price_t   cfg_pend_px_q;
    logic     lvl_cfg_ready, cfg_take, cfg_load, cfg_drop;

    assign cfg_ref_ready = !cfg_pend_q;
    assign cfg_take      = cfg_pend_q && lvl_cfg_ready;
    assign cfg_load      = cfg_ref_valid && (cfg_ref_ready || cfg_take);
    assign cfg_drop      = cfg_ref_valid && !cfg_ref_ready && !cfg_take;

    always_ff @(posedge clk) begin
        if (rst) begin
            cfg_pend_q <= 1'b0;
        end else if (cfg_load) begin
            cfg_pend_q <= 1'b1;
        end else if (cfg_take) begin
            cfg_pend_q <= 1'b0;
        end

        if (cfg_load) begin                   // datapath: qualified, no reset
            cfg_pend_sym_q <= cfg_ref_sym;
            cfg_pend_px_q  <= cfg_ref_px;
        end
    end

    // =========================================================================
    // B3..B4 — price levels
    // =========================================================================
    logic                lvl_valid, lvl_occupied, lvl_in_window, lvl_clear;
    logic                lvl_stale;
    sym_idx_t            lvl_sym;
    side_e               lvl_side;
    logic [LVL_W-1:0]    lvl_level;
    price_t              lvl_price, lvl_base;
    qty_t                lvl_qty;
    occ_mask_t           lvl_occ;
    logic                lvl_ranch_valid;
    sym_idx_t            lvl_ranch_sym;

    logic [31:0] l_cnt_oow_b, l_cnt_oow_w, l_cnt_subtick, l_cnt_no_anchor;
    logic [31:0] l_cnt_uf, l_cnt_fwd, l_cnt_fwd_occ, l_cnt_reanchor;
    logic [31:0] l_cnt_cfg_rej, l_cnt_stale_sym, l_cnt_clear, l_cnt_lookup;

    // Level-array port B — top_of_book's rescan quantity fetch.
    logic             lk_valid, lk_ready, lk_ack;
    sym_idx_t         lk_sym;
    side_e            lk_side;
    logic [LVL_W-1:0] lk_level;
    qty_t             lk_qty;

    // A BOOK_CLEAR is recognised at the map-result stage from the side-band
    // opcode, and carries the event's OWN symbol — see skew instance 2 in the
    // header. order_id_map returns res_hit = 0 for a clear, so the clear is the
    // one beat that reaches price_levels without a map hit.
    logic mp_is_clear;
    assign mp_is_clear = map_res_valid && (mp_op_q[1] == BOOK_CLEAR);

    logic     lvl_upd_valid;
    sym_idx_t lvl_upd_sym;
    assign lvl_upd_valid = map_res_valid && (map_res_hit || mp_is_clear);
    assign lvl_upd_sym   = mp_is_clear ? mp_sym_q[1] : map_res_sym;

    price_levels #(
        .N_LEVELS (N_LEVELS)
    ) u_levels (
        .clk             (clk),
        .rst             (rst),
        // Host anchor
        .cfg_valid       (cfg_pend_q),
        .cfg_sym         (cfg_pend_sym_q),
        .cfg_ref_px      (cfg_pend_px_q),
        .cfg_ready       (lvl_cfg_ready),
        // Early window check — one cycle ahead of the map request it gates
        .chk_valid       (chk_valid),
        .chk_sym         (chk_sym),
        .chk_price       (chk_price),
        .chk_ack         (chk_ack),
        .chk_in_window   (chk_in_window),
        .chk_stale       (chk_stale),
        // Update
        .upd_valid       (lvl_upd_valid),
        .upd_sym         (lvl_upd_sym),
        .upd_side        (map_res_side),
        .upd_price       (map_res_price),
        .upd_add         (map_res_add),
        .upd_del         (map_res_delta),
        .upd_clear       (mp_is_clear),
        // Port B — top_of_book's rescan quantity fetch
        .lk_valid        (lk_valid),
        .lk_sym          (lk_sym),
        .lk_side         (lk_side),
        .lk_level        (lk_level),
        .lk_ready        (lk_ready),
        .lk_ack          (lk_ack),
        .lk_qty          (lk_qty),
        // Result
        .res_valid       (lvl_valid),
        .res_sym         (lvl_sym),
        .res_side        (lvl_side),
        .res_level       (lvl_level),
        .res_price       (lvl_price),
        .res_base        (lvl_base),
        .res_qty         (lvl_qty),
        .res_occupied    (lvl_occupied),
        .res_in_window   (lvl_in_window),
        .res_clear       (lvl_clear),
        .res_stale       (lvl_stale),
        .res_occ         (lvl_occ),
        // Re-anchor request to the host
        .ranch_valid     (lvl_ranch_valid),
        .ranch_sym       (lvl_ranch_sym),
        // Health
        .cnt_oow_better  (l_cnt_oow_b),
        .cnt_oow_worse   (l_cnt_oow_w),
        .cnt_subtick     (l_cnt_subtick),
        .cnt_no_anchor   (l_cnt_no_anchor),
        .cnt_underflow   (l_cnt_uf),
        .cnt_forward     (l_cnt_fwd),
        .cnt_forward_occ (l_cnt_fwd_occ),
        .cnt_reanchor    (l_cnt_reanchor),
        .cnt_cfg_reject  (l_cnt_cfg_rej),
        .cnt_stale_sym   (l_cnt_stale_sym),
        .cnt_clear       (l_cnt_clear),
        .cnt_lookup      (l_cnt_lookup)
    );

    // =========================================================================
    // B5 — incremental top of book
    // =========================================================================
    // ⚠️ EVERY qualifier here comes from price_levels' OWN result registers, not
    //    from an earlier stage of this file. That is the fix for skew instance 1
    //    in the header: `upd_clear` is `res_clear`, not the map-stage `is_clear`.
    logic        tob_valid, tob_bid_v, tob_ask_v, tob_crossed, tob_stale;
    logic        tob_changed;
    sym_idx_t    tob_sym;
    price_t      tob_bid_px, tob_ask_px;
    qty_t        tob_bid_qty, tob_ask_qty;

    logic [31:0] t_cnt_rescan, t_cnt_promote, t_cnt_rs_empty, t_cnt_rs_cancel;
    logic [31:0] t_cnt_rs_drop, t_cnt_lk_wait, t_cnt_crossed, t_cnt_change;
    logic [31:0] t_cnt_pub_defer, t_cnt_pub_drop;

    top_of_book #(
        .N_LEVELS (N_LEVELS),
        .ENC_PIPE (ENC_PIPE)
    ) u_tob (
        .clk               (clk),
        .rst               (rst),
        .upd_valid         (lvl_valid),
        .upd_sym           (lvl_sym),
        .upd_side          (lvl_side),
        .upd_level         (lvl_level),
        .upd_price         (lvl_price),
        .upd_base          (lvl_base),
        .upd_qty           (lvl_qty),
        .upd_occupied      (lvl_occupied),
        .upd_in_window     (lvl_in_window),
        .upd_clear         (lvl_clear),
        .upd_stale         (lvl_stale),
        .upd_occ           (lvl_occ),
        // Quantity fetch into price_levels port B. lk_ready is low while the
        // fast path is reading; the fetch waits and the wait is counted.
        .lk_valid          (lk_valid),
        .lk_sym            (lk_sym),
        .lk_side           (lk_side),
        .lk_level          (lk_level),
        .lk_ready          (lk_ready),
        .lk_ack            (lk_ack),
        .lk_qty            (lk_qty),
        // Global stale from the order map
        .stale_in          (map_stale),
        .top_valid         (tob_valid),
        .top_sym           (tob_sym),
        .top_bid_px        (tob_bid_px),
        .top_bid_qty       (tob_bid_qty),
        .top_ask_px        (tob_ask_px),
        .top_ask_qty       (tob_ask_qty),
        .top_bid_valid     (tob_bid_v),
        .top_ask_valid     (tob_ask_v),
        .top_crossed       (tob_crossed),
        .top_stale         (tob_stale),
        .top_changed       (tob_changed),
        .cnt_best_rescan   (t_cnt_rescan),
        .cnt_promote       (t_cnt_promote),
        .cnt_rescan_empty  (t_cnt_rs_empty),
        .cnt_rescan_cancel (t_cnt_rs_cancel),
        .cnt_rescan_drop   (t_cnt_rs_drop),
        .cnt_lk_wait       (t_cnt_lk_wait),
        .cnt_crossed       (t_cnt_crossed),
        .cnt_top_change    (t_cnt_change),
        .cnt_pub_defer     (t_cnt_pub_defer),
        .cnt_pub_drop      (t_cnt_pub_drop)
    );

    // =========================================================================
    // Per-symbol ingress timestamp and last trade price
    // =========================================================================
    // rx_sym_q: see skew instance 3 in the header. Written from the aligned
    // side-band pipe on every price-level beat, read back by the symbol that is
    // being published. Correct for the fast path AND for a rescan commit, and it
    // does not need re-deriving if a leaf's latency changes.
    cycle_t rx_sym_q  [N_ACTIVE];
    price_t last_px_q [N_ACTIVE];

    initial begin
        for (int unsigned s = 0; s < N_ACTIVE; s++) begin
            rx_sym_q[s]  = '0;
            last_px_q[s] = '0;
        end
    end

    always_ff @(posedge clk) begin
        if (lvl_valid) rx_sym_q[lvl_sym] <= rx_pipe_q[3];
    end

    // ⚠️ PRINTABLE executions only. ITCH 'C' (Order Executed With Price) carries
    //    a printable flag; a non-printable print does not update the consolidated
    //    last sale and must not update ours either, or the host reconciliation
    //    and the strategy's reference price disagree with the tape.
    always_ff @(posedge clk) begin
        if (map_res_valid && map_res_hit && mp_prn_q[1]
                          && (mp_op_q[1] == BOOK_EXECUTE)) begin
            last_px_q[map_res_sym] <= map_res_price;
        end
    end

    // =========================================================================
    // B6 — output registration
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            m_top_valid <= 1'b0;
        end else begin
            m_top_valid <= tob_valid;
        end
        m_top <= '{ sym:         tob_sym,
                    bid_px:      tob_bid_px,
                    bid_qty:     tob_bid_qty,
                    ask_px:      tob_ask_px,
                    ask_qty:     tob_ask_qty,
                    last_px:     last_px_q[tob_sym],
                    bid_valid:   tob_bid_v,
                    ask_valid:   tob_ask_v,
                    crossed:     tob_crossed,
                    stale:       tob_stale,
                    top_changed: tob_changed,
                    rx_cycle:    rx_sym_q[tob_sym] };
    end

    // =========================================================================
    // Engine-local counters
    // =========================================================================
    logic [31:0]         cnt_evt_q;
    logic [ACT_IDX_W-1:0] ranch_sym_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_evt_q   <= '0;
            ranch_sym_q <= '0;
        end else begin
            // Saturating: a wrapped counter turns an alarm into a no-op.
            if (s_evt_valid && (cnt_evt_q != 32'hFFFF_FFFF))
                cnt_evt_q <= cnt_evt_q + 32'd1;
            // ⚠️ LAST, not ALL. The host needs to know WHICH symbol asked to be
            //    re-anchored, and one symbol index is all stat[16] has room for.
            //    The correct interface is a per-symbol book-health window in the
            //    telemetry map; see the note under §"STAT MAP".
            if (lvl_ranch_valid) ranch_sym_q <= lvl_ranch_sym;
        end
    end

    // =========================================================================
    // STAT MAP — stat[16], consumed by rtl/telemetry/telemetry.sv
    // -----------------------------------------------------------------------------
    // ⚠️ 16 WORDS IS NOW THE BINDING CONSTRAINT, AND THAT IS A REAL LIMITATION.
    //    The three leaves expose 38 counters between them. Sixteen 32-bit words
    //    cannot carry 38 counters, and truncating a 32-bit saturating counter to
    //    16 bits would make it WRAP — turning an alarm into a no-op, which is the
    //    one thing the counter discipline exists to prevent. So the words below
    //    carry the counters whose RATE is needed, and stat[15] carries a
    //    one-bit-per-counter EVER-FIRED bitmap for the rest. That idiom is
    //    borrowed from KILL_SRC.ever_mask in rtl/ctrl/csr_regfile.sv: a counter
    //    that has never fired is a code path you have never actually tested, and
    //    knowing which ones have fired at all is most of the operational value.
    //    ⚠️ RECOMMENDED FOLLOW-UP: widen book_stat to 32 words. That is a
    //       telemetry.sv + csr_regfile.sv change and is outside this task's file
    //       scope, so it is stated here rather than done.
    //
    //   word  source                     meaning
    //   ----  -------------------------  ------------------------------------------
    //     0   engine                     book events accepted at B0 (the denominator)
    //     1   map.cnt_insert             records placed in the map
    //     2   map.cnt_delete             records retired by a message
    //     3   map.cnt_insert_fail    ⚠️  buckets AND stash full -> map_stale. The
    //                                    terminal case: the table is undersized.
    //     4   map.cnt_miss_tracked   ⚠️  a miss with no declined-ADD to explain it:
    //                                    AN ORDER WAS LOST. Must stay at zero.
    //     5   map.cnt_dup_add        ⚠️  ADD for an already-live reference: venue
    //                                    reference reuse or a missed delete.
    //     6   map.live_hi                live-record high-water. THIS is the number
    //                                    that sizes the next build (trading_pkg
    //                                    §"SLR CAPACITY").
    //     7   packed high-water word:
    //           [31:24] last symbol to request a host re-anchor
    //           [23:16] deepest cuckoo kick chain ever observed
    //           [15: 0] stash occupancy high-water (0..MAP_STASH)
    //     8   map.cnt_untracked_add      ADDs declined for being out of the price
    //                                    window — the §3.2 gate firing. Expected to
    //                                    fall to ~0 once symbols are anchored.
    //     9   lvl.cnt_oow_better     ⚠️  a price BETTER than the whole window: the
    //                                    published top of book was WRONG.
    //    10   lvl.cnt_no_anchor      ⚠️  update for a symbol the host never gave a
    //                                    reference price. Fail-closed, and the
    //                                    first thing to check on a dead book.
    //    11   lvl.cnt_underflow      ⚠️  a delete exceeded the resting quantity and
    //                                    saturated at zero: the book had drifted.
    //    12   lvl.cnt_stale_sym      ⚠️  symbols entering STALE.
    //    13   tob.cnt_best_rescan        best-level rescans — THE jitter source, and
    //                                    the only variable-latency operation.
    //    14   tob.cnt_crossed        ⚠️  crossed-book observations.
    //    15   EVER-FIRED bitmap, one bit per counter with no word of its own:
    //           [ 0] map.cnt_miss            total misses (benign + tracked)
    //           [ 1] map.cnt_forward         order-map RMW write-forward taken
    //           [ 2] map.cnt_miss_benign     miss explained by a declined ADD
    //           [ 3] map.cnt_stash_insert    an ADD landed in the stash
    //           [ 4] map.cnt_relocation      a cuckoo kick was performed
    //           [ 5] map.cnt_kick_exhaust ⚠️ chain hit MAX_KICKS, record pinned
    //           [ 6] map.kick_hist[MAX]   ⚠️ STRUCTURALLY IMPOSSIBLE. Must stay 0.
    //           [ 7] lvl.cnt_oow_worse       benign out-of-window (stink bid)
    //           [ 8] lvl.cnt_subtick      ⚠️ price off the tick grid -> stale
    //           [ 9] lvl.cnt_forward         level-word RMW forward taken
    //           [10] lvl.cnt_forward_occ     occupancy-word RMW forward taken
    //           [11] lvl.cnt_reanchor        a host reference price was applied
    //           [12] lvl.cnt_cfg_reject   ⚠️ host wrote a SUB-TICK reference price
    //           [13] lvl.cnt_clear           BOOK_CLEAR beats
    //           [14] lvl.cnt_lookup          rescan quantity fetches served
    //           [15] tob.cnt_promote         second-best cache hit (cheap rescan)
    //           [16] tob.cnt_rescan_empty    a side emptied inside the window
    //           [17] tob.cnt_rescan_cancel   rescan superseded by a fresher update
    //           [18] tob.cnt_rescan_drop  ⚠️ rescan engine busy -> symbol staled
    //           [19] tob.cnt_lk_wait         a fetch yielded a cycle to the fast path
    //           [20] tob.cnt_top_change      a genuine top-of-book change
    //           [21] tob.cnt_pub_defer       a rescan publish was delayed one cycle
    //           [22] tob.cnt_pub_drop     ⚠️ a deferred publish was LOST
    //           [23] eng.replay              an ITCH 'U' synthetic ADD was injected
    //           [24] eng.replay_collision ⚠️ STRUCTURALLY IMPOSSIBLE (>=3 cycles
    //                                        between book events). A set bit means
    //                                        a book event was DROPPED.
    //           [25] eng.cfg_drop         ⚠️ STRUCTURALLY IMPOSSIBLE. A set bit
    //                                        means a host reference-price write was
    //                                        DROPPED and a symbol is anchored to a
    //                                        price the host does not think it has.
    //           [26] eng.add_on_stale        an ADD arrived for an already-stale
    //                                        symbol (tracked anyway — the invariant
    //                                        does not care about staleness)
    //           [27] eng.ranch               a host re-anchor request was raised
    //           [31:28] reserved, read 0
    // =========================================================================
    localparam int unsigned EVER_N = 28;

    logic [EVER_N-1:0] ever_set;
    logic [31:0]       ever_q;

    always_comb begin
        ever_set = '0;
        ever_set[0]  = (m_cnt_miss                != 32'd0);
        ever_set[1]  = (m_cnt_fwd                 != 32'd0);
        ever_set[2]  = (m_cnt_miss_benign         != 32'd0);
        ever_set[3]  = (m_cnt_stash_ins           != 32'd0);
        ever_set[4]  = (m_cnt_reloc               != 32'd0);
        ever_set[5]  = (m_cnt_kick_exh            != 32'd0);
        ever_set[6]  = (m_kick_hist[MAP_MAX_KICKS]!= 32'd0);
        ever_set[7]  = (l_cnt_oow_w               != 32'd0);
        ever_set[8]  = (l_cnt_subtick             != 32'd0);
        ever_set[9]  = (l_cnt_fwd                 != 32'd0);
        ever_set[10] = (l_cnt_fwd_occ             != 32'd0);
        ever_set[11] = (l_cnt_reanchor            != 32'd0);
        ever_set[12] = (l_cnt_cfg_rej             != 32'd0);
        ever_set[13] = (l_cnt_clear               != 32'd0);
        ever_set[14] = (l_cnt_lookup              != 32'd0);
        ever_set[15] = (t_cnt_promote             != 32'd0);
        ever_set[16] = (t_cnt_rs_empty            != 32'd0);
        ever_set[17] = (t_cnt_rs_cancel           != 32'd0);
        ever_set[18] = (t_cnt_rs_drop             != 32'd0);
        ever_set[19] = (t_cnt_lk_wait             != 32'd0);
        ever_set[20] = (t_cnt_change              != 32'd0);
        ever_set[21] = (t_cnt_pub_defer           != 32'd0);
        ever_set[22] = (t_cnt_pub_drop            != 32'd0);
        ever_set[23] = replay_valid_q;
        ever_set[24] = replay_collision;
        ever_set[25] = cfg_drop;
        ever_set[26] = add_on_stale;
        ever_set[27] = lvl_ranch_valid;
    end

    always_ff @(posedge clk) begin
        if (rst) ever_q <= 32'd0;
        else     ever_q <= ever_q | {{(32 - EVER_N){1'b0}}, ever_set};
    end

    always_comb begin
        stat        = '{default: 32'd0};
        stat[0]     = cnt_evt_q;
        stat[1]     = m_cnt_insert;
        stat[2]     = m_cnt_delete;
        stat[3]     = m_cnt_ifail;
        stat[4]     = m_cnt_miss_tracked;
        stat[5]     = m_cnt_dup_add;
        stat[6]     = m_live_hi;
        stat[7]     = {8'(ranch_sym_q), m_kick_depth_hi, m_occ_hi};
        stat[8]     = m_cnt_untracked;
        stat[9]     = l_cnt_oow_b;
        stat[10]    = l_cnt_no_anchor;
        stat[11]    = l_cnt_uf;
        stat[12]    = l_cnt_stale_sym;
        stat[13]    = t_cnt_rescan;
        stat[14]    = t_cnt_crossed;
        stat[15]    = ever_q;
    end

    // =========================================================================
    // Assertions
    // =========================================================================
`ifndef SYNTHESIS
    initial begin
        if (ACT_IDX_W > 8) begin
            $error("book_engine: ACT_IDX_W = %0d does not fit stat[7][31:24]. Widen the packed high-water word or drop the re-anchor symbol from it.", ACT_IDX_W);
            $fatal(1);
        end
        if (N_LEVELS != book_pkg::LEVELS) begin
            $error("book_engine: N_LEVELS = %0d overridden away from book_pkg::LEVELS = %0d. price_levels and top_of_book would then disagree on the width of the occupancy bus.", N_LEVELS, book_pkg::LEVELS);
            $fatal(1);
        end
        // ⚠️ THE SLR CEILING. Level array + order map + symbol tables must fit
        //    ONE SLR or the fast path is split and every book access costs a
        //    pipeline register. See rtl/pkg/trading_pkg.sv §"SLR CAPACITY".
        if (URAM_TOTAL > SLR_URAM288) begin
            $error("book_engine: the book needs %0d URAM288 (level array %0d + order map %0d + symbol tables %0d) but one SLR holds %0d. N_ACTIVE=%0d x BOOK_LEVELS=%0d x ORDER_MAP_ENTRIES=%0d does not fit. Capacity is a measurement: re-run tools/pcap/stats.py, size the map from the live-order high-water (book stat[6]), and bring the SYMBOL COUNT down — it is the free variable, the map size is not.", URAM_TOTAL, URAM_LEVELS, URAM_MAP, URAM_SYMTAB, SLR_URAM288, N_ACTIVE, N_LEVELS, ORDER_MAP_ENTRIES);
            $fatal(1);
        end
        if (BRAM_TOTAL > SLR_BRAM36) begin
            $error("book_engine: the occupancy bitmap and friends need %0d BRAM36 but one SLR holds %0d.", BRAM_TOTAL, SLR_BRAM36);
            $fatal(1);
        end
        $display("book_engine: N_ACTIVE=%0d BOOK_LEVELS=%0d ORDER_MAP_ENTRIES=%0d -> %0d/%0d URAM288 (levels %0d + map %0d + symtab %0d), %0d/%0d BRAM36.", N_ACTIVE, N_LEVELS, ORDER_MAP_ENTRIES, URAM_TOTAL, SLR_URAM288, URAM_LEVELS, URAM_MAP, URAM_SYMTAB, BRAM_TOTAL, SLR_BRAM36);
    end

    // ── The early window check must answer the message the map is sampling ───
    // If either of these fails, `req_in_window` is a different order's answer and
    // the §3.2 invariant is being enforced against the wrong message — which is
    // exactly the class of defect the timing diagram in the header exists to
    // make visible.
    assert property (@(posedge clk) disable iff (rst)
        (map_in_valid && (map_in.op == BOOK_ADD)) |-> chk_ack
    ) else $error("book_engine: an ADD reached the order map with no window answer");

    assert property (@(posedge clk) disable iff (rst)
        chk_ack |-> map_in_valid
    ) else $error("book_engine: a window answer arrived with no request to gate");

    // ── §3.2 POPULATION INVARIANT ────────────────────────────────────────────
    // An order is in the map IFF its quantity is in the level array. Locally
    // that reads: every beat that reaches price_levels came either from a map
    // HIT (so the order IS in the map, so it was admitted in-window, so its
    // price must still classify in-window) or is a BOOK_CLEAR. If a non-clear
    // beat is ever rejected as out-of-window, the two structures hold different
    // populations from that moment on and the book is quietly wrong.
    //
    // ⚠️ There is one window in which this can legitimately fail and it is the
    //    documented gap, not a bug in the check: a host re-anchor that lands
    //    BETWEEN a beat's window check (cycle 1) and its classification (cycle
    //    4) moves the base underneath it. The shadow counter below suppresses
    //    the assertion for exactly that interval, and the interval is the reason
    //    the manual holds a symbol stale and out of trading across a re-anchor
    //    (§9.2). Do not widen the shadow to hide a real failure.
    logic [3:0] ranch_shadow_q;
    always_ff @(posedge clk) begin
        if (rst)                     ranch_shadow_q <= 4'd0;
        else if (cfg_take)           ranch_shadow_q <= 4'd12;
        else if (ranch_shadow_q != 4'd0)
                                     ranch_shadow_q <= ranch_shadow_q - 4'd1;
    end

    assert property (@(posedge clk) disable iff (rst || (ranch_shadow_q != 4'd0))
        (lvl_valid && !lvl_clear) |-> lvl_in_window
    ) else $error("book_engine: §3.2 invariant broken — a mapped order's quantity was rejected by the level array");

    // The other half, enforced by construction rather than hoped for: an ADD the
    // window check declined must never be presented to the map as insertable.
    assert property (@(posedge clk) disable iff (rst)
        (chk_ack && !chk_in_window) |-> !map_req_in_window
    ) else $error("book_engine: an out-of-window ADD was offered to the order map");

    // ── You cannot retire a record you did not find ──────────────────────────
    assert property (@(posedge clk) disable iff (rst)
        (map_res_valid && map_res_remove) |-> map_res_hit
    ) else $error("book_engine: order map reported a removal without a hit");

    // ── BOOK_CLEAR must carry the event's own symbol, never the map's ────────
    // order_id_map returns res_sym = '0 for a clear. This is skew instance 2.
    assert property (@(posedge clk) disable iff (rst)
        mp_is_clear |-> (lvl_upd_sym == mp_sym_q[1])
    ) else $error("book_engine: BOOK_CLEAR took its symbol from the order map");

    // ── The ingress timestamp must survive the pipeline untouched ────────────
    // All latency telemetry is measured from it; a corrupted or misattributed
    // rx_cycle invalidates the entire histogram in rtl/telemetry/latency_hist.sv.
    assert property (@(posedge clk) disable iff (rst)
        m_top_valid |-> (m_top.rx_cycle == $past(rx_sym_q[tob_sym]))
    ) else $error("book_engine: rx_cycle corrupted or misattributed in the pipeline");

    assert property (@(posedge clk) disable iff (rst)
        lvl_valid |=> (rx_sym_q[$past(lvl_sym)] == $past(rx_pipe_q[3]))
    ) else $error("book_engine: per-symbol rx_cycle not captured on a level beat");

    // ── Stale must reach the strategy. No path may mask it. ──────────────────
    assert property (@(posedge clk) disable iff (rst)
        (map_stale && m_top_valid) |-> m_top.stale
    ) else $error("book_engine: stale not propagated to the strategy");

    // A crossed or stale book must still be EMITTED — suppressing it would leave
    // the strategy acting on the previous, stale top of book.
    assert property (@(posedge clk) disable iff (rst)
        (m_top_valid && m_top.crossed) |-> (m_top.bid_px >= m_top.ask_px)
    ) else $error("book_engine: crossed flag set without a crossed book");

    // ── The host anchor handshake must never drop a write ────────────────────
    // Structural claim: the PCIe->core config path cannot deliver two writes
    // inside price_levels' 4-cycle configuration FSM. This is where that claim
    // is checked rather than believed.
    assert property (@(posedge clk) disable iff (rst)
        cfg_ref_valid |-> cfg_ref_ready
    ) else $error("book_engine: host reference-price write arrived while one was in flight — it was DROPPED");

    // ── The Replace injection must never collide ─────────────────────────────
    // Same shape of claim: book events are >= 3 cycles apart on a 64-bit feed.
    assert property (@(posedge clk) disable iff (rst)
        !replay_collision
    ) else $error("book_engine: ITCH Replace injection collided with a new event — a book event was DROPPED");
`endif

endmodule : book_engine

`default_nettype wire
