// =============================================================================
// order_id_map.sv — order reference -> resting order record
//                   BUCKETED CUCKOO HASH TABLE, d = 2 hashes x b = 4 slots
// -----------------------------------------------------------------------------
// LATENCY  (core clock 156.25 MHz, 6.4 ns period)
//   Lookup / execute / cancel / delete / replace .. 2 cycles, 12.8 ns, FIXED
//   Insert, free slot in either bucket ............ 2 cycles, 12.8 ns, FIXED
//   Insert, both buckets full ..................... 2 cycles, 12.8 ns, FIXED
//                                                   (lands in the stash and is
//                                                    findable from that instant)
//   ⚠️ EVERY operation is 2 cycles. There is no variable-latency path and no
//      stall path into this module. That is the entire reason the table probes
//      exactly two buckets and never a third: a fixed-latency pipeline cannot
//      tolerate a probing chain, however good its average.
//
//   Relocation (the cuckoo "kick chain") is OFF the request path. It runs in a
//   background engine and never delays a request. Time for a stashed record to
//   settle into a bucket, which is a TELEMETRY figure and not a latency figure
//   because the record is live and findable throughout:
//       2 granted cycles per kick step x (1 probe + MAX_KICKS) = 34 cycles
//       best case (idle machine) .......... 34 cycles = 217.6 ns
//       worst case at sustained line rate . see "BACKGROUND ENGINE" below,
//                                           ~102 cycles = 652.8 ns
//
// RESOURCE (estimate, pre-synthesis — no toolchain has run on this file)
//   Record = 138 bit {valid, key[63:0], sym[7:0], side, price[31:0], qty[31:0]}
//   Table  = 2 tables x 4 slots x 8192 buckets = 65,536 slots = 9.04 Mbit
//   Memory = 8 independent 1R1W arrays (one per table x slot), each
//            8192 x 138 bit -> 2 URAM deep x 2 URAM wide = 4 URAM288
//            => 8 x 4 = 32 URAM288 total, unchanged from the 4-way design.
//   Stash  = 16 x 138 bit in FF/LUTRAM, plus 16 x 64-bit comparators (~600 LUT)
//   Compare= 8 bucket + 16 stash + 1 in-flight = 25 x 64-bit == ~1,000 LUT
//   Hash   = 2 x CRC XOR tree over 64 bits, ~200 LUT each, 0 DSP
//   Total  ~ 32 URAM288, ~3,000 LUT, ~2,500 FF, 0 DSP, 0 BRAM
//
// Governing manual : manuals/04-system-architecture/03-order-book-in-hardware.md
// Governing plan   : docs/ORDER-BOOK-REDESIGN.md §1, §2.3, §3.1, §3.2 (task R1)
// Coding standard  : manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// =============================================================================
// WHY THIS BLOCK EXISTS
// -----------------------------------------------------------------------------
// ITCH Execute/Cancel/Delete/Replace messages carry only a 64-bit order
// reference. This map turns that reference back into
// {symbol, side, price, remaining quantity} so the price level can be updated.
//
// =============================================================================
// WHAT WAS WRONG WITH THE PREVIOUS DESIGN
// -----------------------------------------------------------------------------
// Plain 4-way set-associative, one hash, 16,384 sets, no overflow region.
// Poisson occupancy at 8,192 live orders (12.5 % load) predicts ~2.8 overflowing
// sets. The old RTL turned the FIRST such overflow into a permanent `map_stale`.
// Effective capacity of a 65,536-entry table was therefore ~8,000 orders — 62
// per symbol at 128 symbols — and the book died within milliseconds of the open.
// Measured table: docs/ORDER-BOOK-REDESIGN.md §2.3.
//
// =============================================================================
// ⚠️ RELOCATION IS NOT EVICTION — the reconciliation with the manual
// -----------------------------------------------------------------------------
// manuals/04-system-architecture/03-order-book-in-hardware.md §2.4 says
// "Never evict", and that rule is CORRECT and is preserved here in full. It
// conflates two different operations:
//
//   EVICTION (drop)  — discard an entry to make room. The order still exists at
//                      the venue; its delete resolves to nothing; its quantity
//                      is stranded in the level array forever. Silent, permanent
//                      book corruption. ❌ FORBIDDEN, and this module never does
//                      it: there is no code path that discards a valid record.
//
//   RELOCATION (kick)— move an entry to its ALTERNATE bucket. The order is still
//                      present, still findable in 2 cycles, still counted. ✅
//
// Every item that enters this table stays in it for its whole lifetime and is
// removed only by the message that retires it at the venue. The population
// counter `n_live_q` is asserted to be conserved across every relocation, which
// is the machine-checkable statement of exactly that claim.
//
// The one remaining terminal case is unchanged from the manual: both buckets
// full AND the stash full => the insert fails, `cnt_insert_fail` increments and
// `map_stale` latches. Loud, not silent. The quantity is NOT applied to the
// level array in that case, which keeps the §3.2 population invariant intact.
//
// =============================================================================
// ⚠️ FULL 64-BIT KEYS ARE STORED. NEVER TAGS.
// -----------------------------------------------------------------------------
// Partial-key cuckoo — store a fingerprint and derive the alternate bucket from
// it as `alt = bucket XOR hash(tag)` — halves the memory and is standard in
// cuckoo FILTERS, where a false positive is merely a wasted probe. Here a tag
// collision returns the WRONG ORDER, and applying an execution to the wrong
// resting order is silent mis-attribution: the book stays plausible and is
// wrong. Non-negotiable, and it also buys the involution below for free.
//
// =============================================================================
// STRUCTURE
// -----------------------------------------------------------------------------
//   key ──┬─► h0(key) ─► table 0, bucket b0 (4 slots) ──┐
//         │                                             ├─ 8 full-key compares
//         └─► h1(key) ─► table 1, bucket b1 (4 slots) ──┘
//                                                       │
//                    stash, 16 entries, 16 compares ────┤─► hit / miss, 1 cycle
//                                                       │   O(1) WORST CASE
//                    in-flight relocation register  ────┘
//
// All 25 comparators run IN PARALLEL in the same cycle. The stash is not a
// second-chance lookup after a miss; there is no "after".
//
// THE ALTERNATE-BUCKET FUNCTION IS AN INVOLUTION
//   alt(table t, key k)  =  (table ~t, bucket h_{~t}(k))
//   alt(alt(x, k), k)    =  x                                     for every k
// Because the FULL key is stored, both bucket indices are recomputable from any
// resident record, so a relocated item is always findable at exactly one of its
// two candidate locations. This is asserted below, and it is the property that
// makes a kick chain safe: a kick can only ever move an item between the two
// places the lookup already reads.
//
// =============================================================================
// BACKGROUND ENGINE — how relocation stays off the request path
// -----------------------------------------------------------------------------
// docs/ORDER-BOOK-REDESIGN.md §3.1 specifies "free slot in either bucket ->
// place; else kick, bounded at MAX_KICKS; chain fails -> stash; stash full ->
// stale". Executed literally on the request path, a chain is up to 16
// read-modify-writes, which is precisely the objection that got cuckoo rejected
// in manuals/09-deep-dives/05-hash-tables-and-lookup-structures.md §6.
//
// The order of the fallbacks is therefore inverted, and the OUTCOMES are
// identical:
//   * both buckets full on an ADD  -> the record goes STRAIGHT to the stash and
//     is live and findable from that clock edge. The request completes in its
//     fixed 2 cycles.
//   * the background engine then drains the stash into the tables using exactly
//     the specified bounded kick chain.
//   * a chain that exhausts MAX_KICKS leaves the record resting in the stash,
//     pinned, and it is retried when table space is next freed.
//   * stash full at the moment of an ADD -> insert failure, `map_stale`.
// Nothing is ever dropped, the chain is still bounded at 16, and the request
// path is still fixed-latency.
//
// =============================================================================
// ⚠️ THE PROJECT'S OWN MANUAL REJECTS CUCKOO. HERE IS WHY IT IS STILL CHOSEN.
// -----------------------------------------------------------------------------
// manuals/09-deep-dives/05-hash-tables-and-lookup-structures.md §6 and §12
// rule 11 reject cuckoo and name d-left as the sanctioned upgrade. The objection
// is precise and it is CORRECT AS WRITTEN:
//
//   "Cuckoo, d=2, bucket 4, bounded K — insert: bounded K, but K RMWs >> 1
//    cycle … Complexity: High: displacement FSM, cycle detection, cross-table
//    RMW hazard → Rejected — the insert path is real-time"
//
// Every clause of that objection is aimed at a BLOCKING insert. ITCH Add Order
// is roughly half of all book traffic, so an insert that can take 16 RMWs is
// disqualifying, and shipping one would be indefensible. Each clause is
// answered structurally above rather than argued away:
//
//   "K RMWs >> 1 cycle"    -> the insert is 2 cycles, FIXED, in every case. The
//                             chain does not run on the request path at all.
//   "cycle detection"      -> not needed and not implemented. A displacement
//                             cycle simply exhausts MAX_KICKS; the record rests
//                             in the stash and is pinned, so the engine cannot
//                             spin. Progress without inspecting the chain.
//   "cross-table RMW"      -> eliminated by the grant rule: the engine advances
//                             only on cycles with no fast-path activity, so at
//                             most one writer exists per cycle, by construction.
//   "displacement FSM"     -> real, and the honest cost: four states, an LFSR,
//                             one in-flight register, one extra comparator.
//
// Why not d-left, which the manual sanctions and which is genuinely simpler:
//
//   1. Once the insert is decoupled, d-left's decisive advantage — a strictly
//      bounded 2-cycle insert — is matched exactly. Both designs are 2 cycles,
//      always. The comparison then turns on what happens when both candidate
//      buckets are full, and there d-left has NO mechanism at all: it needs an
//      overflow region, and §7 of that same deep-dive shows the overflow region,
//      not the bucket array, is the binding constraint (the 64-entry CAM is
//      exhausted in expectation at only 24 % load).
//   2. d-left's overflow grows MONOTONICALLY — nothing ever leaves it. The
//      cuckoo stash DRAINS: the background engine returns records to the tables,
//      so occupancy is self-healing and its high-water is a load signal rather
//      than a countdown to failure.
//   3. Load factor: bucketed cuckoo d=2/b=4 sustains 0.976; d-left with the same
//      geometry fails materially earlier. Memory is not scarce here (32 of ~960
//      URAM), so this is the weakest of the three arguments and is listed last
//      deliberately — determinism was the real question, and it is settled by
//      point 1.
//
// ⚠️ Honest cost of this choice, stated so a reviewer does not have to find it:
//    the background engine needs idle cycles. Under a hypothetical 100 % duty
//    request stream forever, the stash would stop draining and would behave
//    exactly like d-left's static overflow CAM — degraded to the rejected
//    design's characteristics, but never worse than it. The duty-cycle bound
//    above is why that does not occur in practice, and `occupancy_hi` is how
//    you would find out if it ever did.
//
// The two manuals now openly contradict each other on this point:
// 04-system-architecture/03-*.md §2 has been rewritten to specify cuckoo, while
// 09-deep-dives/05-*.md §6 still rejects it. That reconciliation is task R10 and
// is deliberately not attempted here.
//
// =============================================================================
// MEASURED BEHAVIOUR OF THIS ALGORITHM
// -----------------------------------------------------------------------------
// ⚠️ PROVENANCE: these are from a Python model of the algorithm below — the same
//    two CRC hashes, the same 8192x2x4 geometry, the same emptier-bucket
//    preference, the same bounded chain, the same 15-entry fast-path stash. They
//    are NOT an RTL simulation. Nothing in this file has been simulated,
//    synthesized, or run on hardware. Treat them as a design-space result that
//    tells you where the knee is, and replace them with cocotb numbers in R7.
//
// Load knee, 65,536 slots, realistic key distribution:
//
//     live orders │ load │ insert fails │ stash high-water │ max chain depth
//     ────────────┼──────┼──────────────┼──────────────────┼────────────────
//         32,768  │  50% │            0 │                0 │        0
//         45,875  │  70% │            0 │                1 │        2
//         52,428  │  80% │            0 │                2 │       16
//         55,705  │  85% │            0 │                1 │       14
//         58,982  │  90% │          322 │               15 │       16
//
// ⇒ The default geometry is clean to 85 % load and breaks down by 90 %. Size for
//   <= 80 % of slots, not for the 0.976 theoretical threshold.
//
// WHAT THE RELOCATION ENGINE IS ACTUALLY WORTH, at 85 % load:
//     background engine disabled (stash becomes a static overflow CAM,
//     i.e. exactly the d-left arrangement) ......... 1,112 insert failures
//     background engine enabled .................... 0 insert failures
// Same memory, same lookup, same 2-cycle insert. That difference — 1,112 book
// staleness events versus none — is the entire justification for the FSM.
// Enlarging the stash instead does NOT help (15, 31, 63 and 127 entries all give
// the same answer): draining it is what matters, not buffering more.
//
// ⚠️ WARNING FOR R7, AND IT IS THE ONLY REASON THE ORIGINAL DEFECT SURVIVED:
//    with DENSE SEQUENTIAL order references, the OLD 4-way design shows ZERO
//    overflows at every load up to 90 %, because the legacy hash maps a
//    contiguous range almost bijectively. A stress test that inserts
//    ref, ref+1, ref+2 … therefore PASSES the broken design and proves nothing.
//    With a realistic key set — sequential references thinned by the symbol
//    filter and by order lifetime — the same old design strands 4 orders at
//    12.5 % load and 9,227 at 90 %, which is what
//    docs/ORDER-BOOK-REDESIGN.md §2.3 predicts. THE TEST MUST USE THINNED OR
//    REPLAYED REFERENCES, never a dense range.
//
// Hash independence, measured over 20,000 keys of each shape (agreement between
// the two bucket indices; 2.4 expected for independent 13-bit projections):
//     sequential 3   ·   stride-256 3   ·   random 1     — independent, as
// required. Each hash alone used all 8,192 buckets with a max occupancy of 9
// against a mean of 8 over 65,536 sequential keys.
//
// ⚠️ THE ENGINE NEVER CONTENDS WITH THE FAST PATH. It advances only on cycles
//    where no lookup is being issued AND none is in its compare stage
//    (`bg_grant`). That guarantee is what lets the design carry a single
//    one-deep write-forward register instead of a general coherence scheme:
//    at most one memory write happens per cycle, from exactly one source.
//
//    Duty-cycle argument for why the engine gets cycles at all: the shortest
//    book-affecting ITCH message is Order Delete at 19 bytes, which occupies 3
//    beats of the 64-bit 156.25 MHz datapath, so a sustained back-to-back stream
//    of the smallest possible messages still leaves >= 1 in 3 cycles idle.
//    ⚠️ VERIFY that 19-byte figure against the TotalView-ITCH 5.0 spec before
//       relying on the bound; the argument, not the constant, is the point.
//
// =============================================================================
// ⚠️ THE READ-MODIFY-WRITE HAZARD (and the §2.4 defect this fixes)
// -----------------------------------------------------------------------------
// Two ITCH messages for the same reference can arrive in consecutive cycles — an
// Execute immediately followed by a Delete is routine at the touch. The second
// message's bucket read is issued BEFORE the first message's write lands.
// Resolution: FORWARD, never stall.
//
// The previous implementation drove `wb_en`/`wb_set`/`wb_way`/`wb_rec` with
// non-blocking assignments in the stage-2 block and consumed them in a separate
// `always_ff`, so the write landed one cycle later than the forwarding compare
// assumed, and the bypass was off by one (docs/ORDER-BOOK-REDESIGN.md §2.4).
// Here the write port is driven COMBINATIONALLY from stage 1, so the write and
// the result register at the same edge, and `fwd_*_q` is a faithful one-deep
// record of the immediately preceding write. Cycle-accurate derivation:
//
//   cyc 0 : req A hashed; A's bucket read issued
//   edge  : A payload + A bucket data registered
//   cyc 1 : A compared; A's mutation driven combinationally onto the write port
//           req B hashed; B's bucket read issued  (sees memory BEFORE A's write)
//   edge  : A's write lands; A's result registers; B payload + B data registered
//           A's write is captured into fwd_*_q
//   cyc 2 : B compared against {bucket data OVERRIDDEN by fwd_*_q where it
//           matches}, so B sees A's mutation. Exactly one write is ever in
//           flight, so exactly one forwarding stage is correct — not two.
//
// Registers (stash, in-flight) need no forwarding: they are written at the same
// edge the reader would sample, so there is no skew to cover.
//
// =============================================================================
// ⚠️ POPULATION INVARIANT (docs/ORDER-BOOK-REDESIGN.md §3.2)
// -----------------------------------------------------------------------------
// AN ORDER IS IN THIS MAP IF AND ONLY IF ITS QUANTITY IS IN THE LEVEL ARRAY.
//
// Both halves are enforced here:
//   * `req_in_window` low on an ADD  => the order is NOT inserted and `res_hit`
//     is low, so price_levels never adds its quantity. Counted as
//     `cnt_untracked_add`, not an error.
//   * insert failure                 => `res_hit` low, so the quantity is never
//     added either. Counted, and `map_stale`.
// The invariant is what makes a delete for an untracked order a correct no-op
// rather than an error, and it bounds the population to
// symbols x window levels x orders per level rather than the venue's whole book.
//
// ⚠️ "NEVER TRACKED" IS NOT "LOST", AND CONFLATING THEM HIDES REAL BUGS.
//    A miss has two possible meanings and they demand opposite responses:
//      benign  — we deliberately declined to track this order (out of window),
//                so its delete SHOULD miss. A no-op. Not stale.
//      tracked — we believed we were tracking every live order, and a reference
//                still missed. An order was LOST. Stale, immediately.
//    Deletes carry no price and no symbol, so the specific key cannot be
//    recognised. The map instead keeps `n_untracked_q`, a credit counter:
//    incremented for every ADD declined, decremented (floored at zero) by every
//    miss. A miss is benign only while credit remains.
//    ⚠️ The counter is deliberately DRAINED BY EVERY MISS, including
//       execute/cancel misses that do not retire the order. That makes the
//       classifier drift STRICT rather than permissive over time. Over-strict
//       costs an unnecessary resync; over-permissive would let a genuinely lost
//       order be filed as benign, which is the silent corruption this whole
//       module exists to prevent.
// =============================================================================
`default_nettype none

module order_id_map
    import trading_pkg::*;
    import book_pkg::*;
#(
    // Capacity. Derived from book_pkg, which derives from the single system
    // knob trading_pkg::ORDER_MAP_ENTRIES. See the sizing table and the URAM /
    // SLR warning in book_pkg.sv §5 — capacity must come from measured ITCH
    // statistics via tools/pcap/stats.py, never from a guess.
    parameter int unsigned N_TABLE   = CUCKOO_TABLES,    // d, structurally 2
    parameter int unsigned N_SLOT    = CUCKOO_SLOTS,     // b, slots per bucket
    parameter int unsigned N_BUCK    = CUCKOO_BUCKETS,   // buckets per table
    parameter int unsigned N_STASH   = MAP_STASH,        // stash entries
    parameter int unsigned MAX_KICKS = MAP_MAX_KICKS     // relocation bound
) (
    input  var logic         clk,
    input  var logic         rst,

    // ── Request ──────────────────────────────────────────────────────────────
    input  var logic         req_valid,
    input  var book_op_e     req_op,
    input  var order_ref_t   req_key,        // reference being acted on
    input  var order_ref_t   req_new_key,    // BOOK_REPLACE only, checked only
    input  var sym_idx_t     req_sym,        // BOOK_ADD only
    input  var side_e        req_side,       // BOOK_ADD only
    input  var price_t       req_price,      // BOOK_ADD only
    input  var qty_t         req_qty,        // add: absolute; exec/cancel: delta

    // ⚠️ NEW PORT, MUST BE DRIVEN. High means "this order's price falls inside
    //    the maintained price window, so the level array will hold its
    //    quantity". Only meaningful on BOOK_ADD; ignored for every other op.
    //    Driving it low on an ADD keeps the order out of the map, which is the
    //    §3.2 invariant. Driving it constant 1 restores the old behaviour and is
    //    correct only while price_levels accepts every price.
    input  var logic         req_in_window,

    // ── Result, exactly 2 cycles later, for every operation ──────────────────
    output var logic         res_valid,
    output var logic         res_hit,        // the key was present / was inserted
    output var sym_idx_t     res_sym,
    output var side_e        res_side,
    output var price_t       res_price,
    output var qty_t         res_delta,      // quantity to remove from the level
    output var qty_t         res_add,        // quantity to add to a level
    output var logic         res_remove,     // order fully consumed, entry freed

    // ── Health ───────────────────────────────────────────────────────────────
    // ⚠️ sticky. Set on a genuine loss of book integrity; cleared only by the
    //    BOOK_CLEAR resync, and then only once the table wipe has completed.
    output var logic         map_stale,

    // ── Telemetry. Every counter saturates rather than wrapping: a wrapped
    //    counter turns an alarm into a no-op (CLAUDE.md §5.7/§5.8). ───────────
    output var logic [31:0]  cnt_insert,        // records placed in a bucket
    output var logic [31:0]  cnt_insert_fail,   // ⚠️ both buckets AND stash full
                                                //    -> map_stale. The terminal
                                                //    case. Sustained non-zero
                                                //    means the table is
                                                //    undersized; re-run
                                                //    tools/pcap/stats.py.
    output var logic [31:0]  cnt_miss,          // total misses = benign+tracked,
                                                //    kept for the existing stat
                                                //    map in book_engine
    output var logic [31:0]  cnt_delete,        // records removed by a message
    output var logic [31:0]  cnt_forward,       // RMW write-forward bypasses
                                                //    taken. Non-zero is normal
                                                //    and healthy; zero over a
                                                //    session means the hazard
                                                //    test never fired.
    output var logic [15:0]  occupancy_hi,      // ⚠️ SEMANTIC CHANGE: this was
                                                //    "high-water ways used",
                                                //    meaningless for cuckoo. It
                                                //    is now STASH OCCUPANCY
                                                //    HIGH-WATER, 0..N_STASH.
                                                //    It is the early-warning
                                                //    gauge: a stash that is
                                                //    persistently deep means
                                                //    relocation is not keeping
                                                //    up or the table is full.
    output var logic [31:0]  cnt_miss_benign,   // miss explained by a declined,
                                                //    never-tracked ADD. No-op.
    output var logic [31:0]  cnt_miss_tracked,  // ⚠️ miss with NO such
                                                //    explanation: an order was
                                                //    LOST. Sets map_stale. This
                                                //    is the counter that must
                                                //    stay at zero.
    output var logic [31:0]  cnt_stash_insert,  // ADDs that landed in the stash
                                                //    because both buckets were
                                                //    full. Correct, but it is
                                                //    the leading indicator of
                                                //    load-factor pressure.
    output var logic [31:0]  cnt_relocation,    // kick steps performed, i.e.
                                                //    records moved to their
                                                //    alternate bucket. Never a
                                                //    correctness event.
    output var logic [31:0]  cnt_untracked_add, // ADDs declined for being out of
                                                //    the price window. Expected
                                                //    to be ~0 once price_levels
                                                //    re-anchors properly (R2).
    output var logic [31:0]  cnt_kick_exhaust,  // chains that hit MAX_KICKS and
                                                //    left the record pinned in
                                                //    the stash. Not a loss.
    output var logic [31:0]  cnt_dup_add,       // ⚠️ ADD for a reference already
                                                //    live. Venue reference reuse
                                                //    or a missed delete. Sets
                                                //    map_stale.
    // Cumulative kick-depth histogram. kick_hist[d] counts kick steps taken at
    // chain depth d, so kick_hist[d] is exactly "number of chains that reached
    // depth >= d". Differencing adjacent bins gives the exact per-depth
    // histogram; the shape is the health metric (a heavy tail means the load
    // factor is past the knee). One indexed increment per kick, no extra logic.
    // Bin 0 is therefore the number of chains that kicked at all, and bin
    // MAX_KICKS is structurally always zero — "reached depth MAX_KICKS" is
    // exactly `cnt_kick_exhaust`. The bin is kept so the array indexes 0..K
    // naturally rather than being off by one for a reader.
    output var logic [31:0]  kick_hist [MAX_KICKS+1],
    output var logic [7:0]   kick_depth_hi,     // deepest chain ever observed
    output var logic [31:0]  live_hi            // live-record high-water. THIS is
                                                //    the number that sizes the
                                                //    next build.
);

    // =========================================================================
    // Derived geometry
    // =========================================================================
    localparam int unsigned BUCK_W   = $clog2(N_BUCK);
    localparam int unsigned SLOT_W   = $clog2(N_SLOT);
    localparam int unsigned TAB_W    = $clog2(N_TABLE);
    localparam int unsigned STASH_W  = $clog2(N_STASH);
    localparam int unsigned KICK_W   = $clog2(MAX_KICKS + 1);
    localparam int unsigned CAPACITY = N_TABLE * N_SLOT * N_BUCK;
    localparam int unsigned LIVE_W   = $clog2(CAPACITY + N_STASH + 2);
    localparam int unsigned MATCH_W  = (N_TABLE * N_SLOT) + N_STASH + 1;

    // Fast-path stash occupancy ceiling. One entry is reserved so a relocation
    // chain that exhausts MAX_KICKS always has somewhere to put the record it is
    // carrying. Without the reservation, exhaustion could have nowhere to land
    // and the only remaining option would be to drop a live order — an eviction.
    localparam int unsigned STASH_FP_MAX = N_STASH - 1;

    // =========================================================================
    // Hash slicing and the alternate-location function
    // =========================================================================
    // ⚠️ Disjoint bit selections: LOW bits of the Castagnoli CRC for table 0,
    //    HIGH bits of the IEEE CRC for table 1. See book_pkg.sv §5.
    function automatic logic [BUCK_W-1:0] map_bucket(input logic       tab,
                                                     input order_ref_t k);
        logic [31:0] h;
        h = tab ? map_h1_raw(k) : map_h0_raw(k);
        return tab ? h[31 -: BUCK_W] : h[BUCK_W-1:0];
    endfunction

    // The alternate TABLE. Named rather than inlined so the involution is
    // stated once and asserted against, instead of being an implicit `~t`
    // scattered through the relocation engine.
    function automatic logic map_alt_tab(input logic tab);
        return ~tab;
    endfunction

    // =========================================================================
    // Storage
    // -------------------------------------------------------------------------
    // Banked as one array per (table, slot) so that a whole bucket — all N_SLOT
    // slots — is read in ONE cycle from N_SLOT parallel memories, and both
    // buckets are read simultaneously from the two tables. Each array is 1R1W
    // (simple dual port), which is exactly what URAM/BRAM infers cleanly.
    // =========================================================================
    order_rec_t mem [N_TABLE][N_SLOT][N_BUCK];

    // ⚠️ Memories cannot be cleared by `rst`. Power-on state is zeroed here so
    //    `valid` starts low; a real device also needs the host to issue
    //    BOOK_CLEAR at start of day, which additionally runs the wipe below.
    //    Do not rely on this alone.
    initial begin
        for (int unsigned t = 0; t < N_TABLE; t++)
            for (int unsigned s = 0; s < N_SLOT; s++)
                for (int unsigned b = 0; b < N_BUCK; b++)
                    mem[t][s][b] = '0;
    end

    // =========================================================================
    // Stage 0 — hash, and issue both bucket reads
    // =========================================================================
    logic              req_act;
    logic [BUCK_W-1:0] s0_buck [N_TABLE];

    always_comb begin
        req_act = req_valid && (req_op != BOOK_NOP);
        for (int unsigned t = 0; t < N_TABLE; t++) begin
            s0_buck[t] = map_bucket((t != 0), req_key);
        end
    end

    // Background engine read request (declared here, driven far below).
    logic              bg_rd_req;
    logic [BUCK_W-1:0] bg_buck [N_TABLE];
    logic              bg_grant;

    // ⚠️ TIMING NOTE, stated rather than hidden: this cycle contains the CRC XOR
    //    tree AND the memory read. The master budget in
    //    manuals/04-system-architecture/03-*.md §11 allocates row B0 to the hash
    //    and row B1 to the read+compare, i.e. it expects the hash to be
    //    registered. Keeping them together preserves the module's 2-cycle
    //    contract with book_engine. If post-route timing fails here, the fix is
    //    to register `s0_buck`, which makes the map 3 cycles and reclaims the
    //    cycle the budget already reserved for `order_map_hash`. Do NOT "fix" it
    //    by truncating the hash to fewer input bits.
    logic [BUCK_W-1:0] rd_addr [N_TABLE];

    // The background engine borrows the read port, and only on a cycle the fast
    // path is not using it. ⚠️ Gated on `bg_rd_req` as well as the grant: on an
    // idle cycle with the engine parked, `bg_buck` is derived from an empty
    // holder and driving it onto the address would read a meaningless location.
    always_comb begin
        for (int unsigned t = 0; t < N_TABLE; t++) rd_addr[t] = s0_buck[t];
        if (bg_grant && bg_rd_req) begin
            for (int unsigned t = 0; t < N_TABLE; t++) rd_addr[t] = bg_buck[t];
        end
    end

    // Registered bucket read: N_TABLE x N_SLOT records land together.
    order_rec_t s1_rec [N_TABLE][N_SLOT];

    always_ff @(posedge clk) begin
        for (int unsigned t = 0; t < N_TABLE; t++) begin
            for (int unsigned s = 0; s < N_SLOT; s++) begin
                s1_rec[t][s] <= mem[t][s][rd_addr[t]];
            end
        end
    end

    // Stage-1 payload. Control state resets; datapath does not (§6 of the
    // coding manual — resetting datapath FFs loads the reset net for nothing).
    logic              s1_valid;
    book_op_e          s1_op;
    order_ref_t        s1_key, s1_new_key;
    sym_idx_t          s1_sym;
    side_e             s1_side;
    price_t            s1_price;
    qty_t              s1_qty;
    logic              s1_in_window;
    logic [BUCK_W-1:0] s1_buck [N_TABLE];

    always_ff @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid <= req_act;
        end
        s1_op        <= req_op;
        s1_key       <= req_key;
        s1_new_key   <= req_new_key;
        s1_sym       <= req_sym;
        s1_side      <= req_side;
        s1_price     <= req_price;
        s1_qty       <= req_qty;
        s1_in_window <= req_in_window;
        for (int unsigned t = 0; t < N_TABLE; t++) s1_buck[t] <= s0_buck[t];
    end

    // =========================================================================
    // The stash and the in-flight relocation register
    // -------------------------------------------------------------------------
    // Both are searched IN PARALLEL with the buckets, in the same cycle, by the
    // same comparators. The in-flight register holds the single record that a
    // kick chain is carrying between two buckets; without it there would be a
    // one-cycle window in which a live order is in no searchable structure, and
    // a delete arriving in that window would miss. That window is exactly the
    // kind of defect that produces a plausible, wrong book.
    // =========================================================================
    order_rec_t         stash_q  [N_STASH];
    logic [N_STASH-1:0] stash_pin_q;   // chain exhausted here; skip until space
    order_rec_t         carry_q;       // in-flight relocation register

    logic [STASH_W:0]   stash_used;
    logic [N_STASH-1:0] stash_valid;

    always_comb begin
        stash_valid = '0;
        for (int unsigned i = 0; i < N_STASH; i++) stash_valid[i] = stash_q[i].valid;
        stash_used  = (STASH_W+1)'($countones(stash_valid));
    end

    // =========================================================================
    // Stage 1 — write forwarding, then 25 parallel full-key comparators
    // =========================================================================
    logic              fwd_en_q;
    logic [TAB_W-1:0]  fwd_tab_q;
    logic [SLOT_W-1:0] fwd_slot_q;
    logic [BUCK_W-1:0] fwd_buck_q;
    order_rec_t        fwd_rec_q;

    order_rec_t s1_eff [N_TABLE][N_SLOT];
    logic       s1_fwd;

    always_comb begin
        s1_fwd = 1'b0;
        for (int unsigned t = 0; t < N_TABLE; t++) begin
            for (int unsigned s = 0; s < N_SLOT; s++) begin
                s1_eff[t][s] = s1_rec[t][s];
                if (fwd_en_q && (fwd_tab_q  == TAB_W'(t))
                             && (fwd_slot_q == SLOT_W'(s))
                             && (fwd_buck_q == s1_buck[t])) begin
                    s1_eff[t][s] = fwd_rec_q;
                    s1_fwd       = 1'b1;
                end
            end
        end
    end

    // Where a record lives. Exactly one of these, ever — asserted below.
    typedef enum logic [1:0] {
        LOC_NONE  = 2'd0,
        LOC_BUCK  = 2'd1,
        LOC_STASH = 2'd2,
        LOC_CARRY = 2'd3
    } loc_e;

    logic               s1_hit;
    loc_e               s1_loc;
    logic [TAB_W-1:0]   s1_hit_tab;
    logic [SLOT_W-1:0]  s1_hit_slot;
    logic [STASH_W-1:0] s1_hit_stash;
    order_rec_t         s1_hit_rec;
    logic [MATCH_W-1:0] s1_match;

    // Free-slot search, and the placement preference.
    logic [SLOT_W:0]    free_cnt   [N_TABLE];
    logic               has_free   [N_TABLE];
    logic [SLOT_W-1:0]  first_free [N_TABLE];
    logic               ins_ok;
    logic [TAB_W-1:0]   ins_tab;
    logic [SLOT_W-1:0]  ins_slot;

    always_comb begin
        s1_hit       = 1'b0;
        s1_loc       = LOC_NONE;
        s1_hit_tab   = '0;
        s1_hit_slot  = '0;
        s1_hit_stash = '0;
        s1_hit_rec   = '0;
        s1_match     = '0;

        for (int unsigned t = 0; t < N_TABLE; t++) begin
            for (int unsigned s = 0; s < N_SLOT; s++) begin
                if (s1_eff[t][s].valid && (s1_eff[t][s].key == s1_key)) begin
                    s1_match[(t * N_SLOT) + s] = 1'b1;
                    if (!s1_hit) begin
                        s1_hit      = 1'b1;
                        s1_loc      = LOC_BUCK;
                        s1_hit_tab  = TAB_W'(t);
                        s1_hit_slot = SLOT_W'(s);
                        s1_hit_rec  = s1_eff[t][s];
                    end
                end
            end
        end

        for (int unsigned i = 0; i < N_STASH; i++) begin
            if (stash_q[i].valid && (stash_q[i].key == s1_key)) begin
                s1_match[(N_TABLE * N_SLOT) + i] = 1'b1;
                if (!s1_hit) begin
                    s1_hit       = 1'b1;
                    s1_loc       = LOC_STASH;
                    s1_hit_stash = STASH_W'(i);
                    s1_hit_rec   = stash_q[i];
                end
            end
        end

        if (carry_q.valid && (carry_q.key == s1_key)) begin
            s1_match[MATCH_W-1] = 1'b1;
            if (!s1_hit) begin
                s1_hit     = 1'b1;
                s1_loc     = LOC_CARRY;
                s1_hit_rec = carry_q;
            end
        end
    end

    // Placement preference: the bucket with MORE free slots, ties to table 0.
    // This is the "power of two choices" — one popcount comparison, and it
    // measurably flattens the occupancy tail versus always preferring table 0,
    // which in turn shortens kick chains.
    always_comb begin
        ins_ok   = 1'b0;
        ins_tab  = '0;
        ins_slot = '0;
        for (int unsigned t = 0; t < N_TABLE; t++) begin
            free_cnt[t]   = '0;
            has_free[t]   = 1'b0;
            first_free[t] = '0;
            for (int unsigned s = 0; s < N_SLOT; s++) begin
                if (!s1_eff[t][s].valid) begin
                    free_cnt[t] = free_cnt[t] + (SLOT_W+1)'(1);
                    if (!has_free[t]) begin
                        has_free[t]   = 1'b1;
                        first_free[t] = SLOT_W'(s);
                    end
                end
            end
        end
        if (has_free[0] || has_free[1]) begin
            ins_ok = 1'b1;
            if (has_free[1] && (!has_free[0] || (free_cnt[1] > free_cnt[0]))) begin
                ins_tab  = TAB_W'(1);
                ins_slot = first_free[1];
            end else begin
                ins_tab  = TAB_W'(0);
                ins_slot = first_free[0];
            end
        end
    end

    // First free stash entry.
    logic               stash_free_ok;
    logic [STASH_W-1:0] stash_free_idx;

    always_comb begin
        stash_free_ok  = 1'b0;
        stash_free_idx = '0;
        for (int unsigned i = 0; i < N_STASH; i++) begin
            if (!stash_q[i].valid && !stash_free_ok) begin
                stash_free_ok  = 1'b1;
                stash_free_idx = STASH_W'(i);
            end
        end
    end

    // =========================================================================
    // Population gauges — declared here because the miss classifier below reads
    // the untracked credit. Their update logic lives further down, next to the
    // rest of the sequential state.
    // =========================================================================
    logic [LIVE_W-1:0] n_live_q;        // live records: buckets + stash + carry
    logic [31:0]       n_untracked_q;   // ADDs declined and not yet accounted for

    // High while a BOOK_CLEAR resync wipe is walking the bucket memory. Declared
    // here because the ADD path must decline inserts for the duration; its
    // update logic lives with the background engine below.
    logic              wipe_pending_q;

    // =========================================================================
    // Stage 1 — decide the mutation
    // =========================================================================
    logic       n_res_hit, n_res_remove;
    sym_idx_t   n_res_sym;
    side_e      n_res_side;
    price_t     n_res_price;
    qty_t       n_res_delta, n_res_add;

    logic       s1_wb_en;        // rewrite the record where it was found
    order_rec_t s1_wb_rec;
    logic       s1_ins_buck;     // place a NEW record into a bucket slot
    logic       s1_ins_stash;    // place a NEW record into the stash
    order_rec_t s1_new_rec;

    logic       p_insert, p_ins_fail, p_delete, p_miss_benign, p_miss_tracked;
    logic       p_stash_ins, p_untracked, p_dup, p_stale, p_clear;
    logic       p_live_up, p_live_dn, p_untr_up, p_untr_dn;

    qty_t       reduce_qty;
    logic       full_consume;

    always_comb begin
        // Defaults for every output of this block — no latches, no exceptions.
        n_res_hit      = 1'b0;
        n_res_remove   = 1'b0;
        n_res_sym      = '0;
        n_res_side     = SIDE_BUY;
        n_res_price    = '0;
        n_res_delta    = '0;
        n_res_add      = '0;

        s1_wb_en       = 1'b0;
        s1_wb_rec      = '0;
        s1_ins_buck    = 1'b0;
        s1_ins_stash   = 1'b0;
        s1_new_rec     = '{ valid: 1'b1,
                            key:   s1_key,
                            sym:   s1_sym,
                            side:  s1_side,
                            price: s1_price,
                            qty:   s1_qty };

        p_insert       = 1'b0;
        p_ins_fail     = 1'b0;
        p_delete       = 1'b0;
        p_miss_benign  = 1'b0;
        p_miss_tracked = 1'b0;
        p_stash_ins    = 1'b0;
        p_untracked    = 1'b0;
        p_dup          = 1'b0;
        p_stale        = 1'b0;
        p_clear        = 1'b0;
        p_live_up      = 1'b0;
        p_live_dn      = 1'b0;
        p_untr_up      = 1'b0;
        p_untr_dn      = 1'b0;

        // Saturating reduce: an execution larger than the resting quantity is a
        // decode error or a gap, never a negative book.
        full_consume   = (s1_qty >= s1_hit_rec.qty);
        reduce_qty     = full_consume ? '0 : (s1_hit_rec.qty - s1_qty);

        if (s1_valid) begin
            case (s1_op)

            // ── ADD ──────────────────────────────────────────────────────────
            BOOK_ADD: begin
                if (!s1_in_window || wipe_pending_q) begin
                    // §3.2: an order outside the price window is never added to
                    // a level, so it must never enter the map. Take a credit so
                    // its eventual delete is recognised as benign.
                    //
                    // ⚠️ The same path handles an ADD arriving during a resync
                    //    wipe. Inserting into a table that is being walked and
                    //    zeroed would leave the record's fate dependent on where
                    //    the wipe cursor happened to be — present if the wipe had
                    //    already passed its bucket, silently gone if not — while
                    //    its quantity had already been applied to a level. That
                    //    is precisely the stranded-quantity failure this module
                    //    exists to prevent, so the record is declined outright
                    //    and takes a credit like any other untracked order.
                    //    The §9.2 resync sequence should not be sending book
                    //    traffic here at all; this makes the case safe rather
                    //    than merely unlikely.
                    p_untracked = 1'b1;
                    p_untr_up   = 1'b1;
                end else if (s1_hit) begin
                    // ⚠️ The reference is already live. Either the venue reused
                    //    a reference or we missed its delete. Both mean the book
                    //    no longer matches the venue. Overwriting would strand
                    //    the old quantity in its level; refusing would strand
                    //    the new one. Neither is recoverable, so say so.
                    p_dup   = 1'b1;
                    p_stale = 1'b1;
                end else if (s1_qty == '0) begin
                    // A zero-quantity resting order is not a live order. Filing
                    // one would break the "no valid record with zero qty"
                    // invariant and leave an entry nothing will ever free.
                    p_dup   = 1'b1;
                    p_stale = 1'b1;
                end else if (ins_ok) begin
                    s1_ins_buck = 1'b1;
                    n_res_hit   = 1'b1;
                    n_res_sym   = s1_sym;
                    n_res_side  = s1_side;
                    n_res_price = s1_price;
                    n_res_add   = s1_qty;
                    p_insert    = 1'b1;
                    p_live_up   = 1'b1;
                end else if (stash_free_ok && (stash_used < (STASH_W+1)'(STASH_FP_MAX))) begin
                    // Both buckets full. The record goes to the stash NOW and is
                    // findable from this edge; the background engine relocates
                    // it into a bucket later. This is the inversion described in
                    // the header — outcome identical to the spec, latency fixed.
                    s1_ins_stash = 1'b1;
                    n_res_hit    = 1'b1;
                    n_res_sym    = s1_sym;
                    n_res_side   = s1_side;
                    n_res_price  = s1_price;
                    n_res_add    = s1_qty;
                    p_stash_ins  = 1'b1;
                    p_live_up    = 1'b1;
                end else begin
                    // ⚠️ TERMINAL CASE. Both buckets full AND the stash full.
                    //    We do NOT evict — an evicted order still exists at the
                    //    venue, its delete would resolve to nothing, and its
                    //    quantity would be stranded in a level forever.
                    //    res_hit stays low so the quantity is never added to a
                    //    level either, which keeps the §3.2 invariant true even
                    //    in failure. The book is now unreliable; say so loudly.
                    p_ins_fail = 1'b1;
                    p_stale    = 1'b1;
                end
            end

            // ── EXECUTE / CANCEL: reduce, possibly remove ────────────────────
            BOOK_EXECUTE,
            BOOK_CANCEL: begin
                if (s1_hit) begin
                    n_res_hit    = 1'b1;
                    n_res_sym    = s1_hit_rec.sym;
                    n_res_side   = s1_hit_rec.side;
                    n_res_price  = s1_hit_rec.price;
                    n_res_delta  = full_consume ? s1_hit_rec.qty : s1_qty;
                    n_res_remove = full_consume;
                    s1_wb_en     = 1'b1;
                    s1_wb_rec    = '{ valid: !full_consume,
                                      key:   s1_hit_rec.key,
                                      sym:   s1_hit_rec.sym,
                                      side:  s1_hit_rec.side,
                                      price: s1_hit_rec.price,
                                      qty:   reduce_qty };
                    if (full_consume) begin
                        p_delete  = 1'b1;
                        p_live_dn = 1'b1;
                    end
                end else begin
                    p_miss_benign  =  (n_untracked_q != '0);
                    p_miss_tracked = !(n_untracked_q != '0);
                    p_stale        = !(n_untracked_q != '0);
                    p_untr_dn      =  (n_untracked_q != '0);
                end
            end

            // ── DELETE: remove outright ──────────────────────────────────────
            BOOK_DELETE: begin
                if (s1_hit) begin
                    n_res_hit    = 1'b1;
                    n_res_sym    = s1_hit_rec.sym;
                    n_res_side   = s1_hit_rec.side;
                    n_res_price  = s1_hit_rec.price;
                    n_res_delta  = s1_hit_rec.qty;
                    n_res_remove = 1'b1;
                    s1_wb_en     = 1'b1;
                    s1_wb_rec    = '0;
                    p_delete     = 1'b1;
                    p_live_dn    = 1'b1;
                end else begin
                    p_miss_benign  =  (n_untracked_q != '0);
                    p_miss_tracked = !(n_untracked_q != '0);
                    p_stale        = !(n_untracked_q != '0);
                    p_untr_dn      =  (n_untracked_q != '0);
                end
            end

            // ── REPLACE: retire the old reference. THAT IS ALL. ──────────────
            // ⚠️ ITCH 'U' does NOT modify in place. It cancels the original
            //    reference and creates a NEW one, losing queue priority.
            //    book_engine expands 'U' into this delete plus a synthetic
            //    BOOK_ADD carrying `new_order_ref` on the following cycle, so
            //    the add — and its quantity, at the NEW price — is that
            //    injected message's job.
            // ⚠️ The previous implementation ALSO emitted `res_add = qty` here,
            //    at the OLD record's price. Combined with the engine's injected
            //    add, that double-counted the quantity and placed one of the two
            //    copies at the wrong level. Fixed: this op is a pure delete.
            BOOK_REPLACE: begin
                if (s1_hit) begin
                    n_res_hit    = 1'b1;
                    n_res_sym    = s1_hit_rec.sym;
                    n_res_side   = s1_hit_rec.side;
                    n_res_price  = s1_hit_rec.price;
                    n_res_delta  = s1_hit_rec.qty;
                    n_res_remove = 1'b1;
                    s1_wb_en     = 1'b1;
                    s1_wb_rec    = '0;
                    p_delete     = 1'b1;
                    p_live_dn    = 1'b1;
                end else begin
                    p_miss_benign  =  (n_untracked_q != '0);
                    p_miss_tracked = !(n_untracked_q != '0);
                    p_stale        = !(n_untracked_q != '0);
                    p_untr_dn      =  (n_untracked_q != '0);
                end
            end

            // ── CLEAR: start of day / post-gap resync ────────────────────────
            BOOK_CLEAR: begin
                p_clear = 1'b1;
            end

            default: begin
                // BOOK_NOP and any undecoded encoding: do nothing, touch
                // nothing. Never a latch, never a silent mutation.
                p_stale = 1'b0;
            end
            endcase
        end
    end

    // =========================================================================
    // Background engine — relocation and the post-CLEAR wipe
    // -------------------------------------------------------------------------
    // GRANT RULE: advance only when no lookup is being issued this cycle AND
    // none is in its compare stage. Then a read issued at cycle X is guaranteed
    // that the write port is free at X+1 (because s1_valid at X+1 equals req_act
    // at X, which was low), so read and write are adjacent with no window in
    // which the fast path could invalidate the snapshot. No abort logic, no
    // coherence protocol, and at most ONE memory write per cycle in the whole
    // module — which is what makes the single forwarding register sufficient.
    // =========================================================================
    typedef enum logic [2:0] {
        BG_IDLE = 3'd0,
        BG_RD   = 3'd1,   // both candidate buckets of the carried key are read
        BG_EVAL = 3'd2,   // data back: place into a free slot, or kick
        BG_WIPE = 3'd3
    } bg_e;

    bg_e                bg_state_q;
    logic [STASH_W-1:0] bg_src_q;        // stash entry currently holding it
    logic               bg_from_src_q;   // holder is that stash entry, else carry
    logic [TAB_W-1:0]   bg_from_tab_q;   // table it was just displaced from
    logic               bg_have_from_q;
    logic [KICK_W-1:0]  bg_kicks_q;
    logic [7:0]         bg_lfsr_q;

    // ⚠️ THE ENGINE NEVER KEEPS A PRIVATE COPY OF THE RECORD IT IS MOVING.
    //    It reads it live from whichever searchable structure holds it. A cached
    //    copy would be resurrected by a later place/kick if the fast path had
    //    meanwhile deleted the order or reduced its quantity — an order that the
    //    venue has retired would reappear in the book, at its original size,
    //    with no message left to remove it. That is the exact failure mode this
    //    module exists to prevent, so the copy is not made.
    //
    //    HOLDER INVARIANT: the record under relocation is, at every clock edge,
    //    in exactly one of {stash_q[bg_src_q], carry_q}. Both are compared in
    //    parallel with the buckets by the same 25 comparators, in the same
    //    cycle, so a lookup for a key that is mid-relocation ALWAYS HITS.
    //    Asserted below as `no lookup misses a key that is present-but-moving`.
    order_rec_t         bg_src_rec;
    logic               bg_live;
    logic               bg_busy;

    always_comb begin
        bg_src_rec = bg_from_src_q ? stash_q[bg_src_q] : carry_q;
        bg_live    = bg_src_rec.valid;
        bg_busy    = (bg_state_q == BG_RD) || (bg_state_q == BG_EVAL);
    end

    logic [BUCK_W-1:0]  wipe_buck_q;
    logic [SLOT_W-1:0]  wipe_slot_q;
    logic [TAB_W-1:0]   wipe_tab_q;

    // ⚠️ Sticky, and must never set. See the unreachable branch in BG_EVAL.
    //    It forces `map_stale` so a broken invariant surfaces as a resync
    //    demand rather than as a quietly wrong book.
    logic               bg_stuck_q;

    // A stash entry worth relocating: valid and not pinned.
    logic               bg_pick_ok;
    logic [STASH_W-1:0] bg_pick_idx;

    always_comb begin
        bg_pick_ok  = 1'b0;
        bg_pick_idx = '0;
        for (int unsigned i = 0; i < N_STASH; i++) begin
            if (stash_q[i].valid && !stash_pin_q[i] && !bg_pick_ok) begin
                bg_pick_ok  = 1'b1;
                bg_pick_idx = STASH_W'(i);
            end
        end
    end

    // ⚠️ THE GRANT RULE, and everything it buys.
    //    The engine advances only when no lookup is being issued this cycle and
    //    none is in its compare stage. Consequences, all of them load-bearing:
    //      * a read granted at cycle X guarantees s1_valid is low at X+1, so the
    //        evaluate-and-write cycle cannot race any fast-path mutation. There
    //        is no cross-table RMW hazard to detect, because there is no window
    //        in which one can occur.
    //      * at most ONE memory write happens per cycle in the whole module,
    //        from exactly one source, which is why a single one-deep forwarding
    //        register is sufficient rather than a coherence scheme.
    //      * the request path is never delayed by relocation, by construction
    //        rather than by arbitration.
    always_comb begin
        bg_grant  = !req_act && !s1_valid;
        bg_rd_req = (bg_state_q == BG_RD);
        for (int unsigned t = 0; t < N_TABLE; t++) begin
            bg_buck[t] = map_bucket((t != 0), bg_src_rec.key);
        end
    end

    // Kick target selection. The record is kicked into the table it was NOT
    // just displaced from — that is its alternate, and alt is an involution, so
    // the item is always at one of the two locations the lookup reads.
    logic [TAB_W-1:0]  bg_kick_tab;
    logic [SLOT_W-1:0] bg_kick_slot;
    order_rec_t        bg_victim;
    logic              bg_free_ok;
    logic [TAB_W-1:0]  bg_free_tab;
    logic [SLOT_W-1:0] bg_free_slot;

    always_comb begin
        bg_free_ok   = 1'b0;
        bg_free_tab  = '0;
        bg_free_slot = '0;
        for (int unsigned t = 0; t < N_TABLE; t++) begin
            for (int unsigned s = 0; s < N_SLOT; s++) begin
                if (!s1_rec[t][s].valid && !bg_free_ok) begin
                    bg_free_ok   = 1'b1;
                    bg_free_tab  = TAB_W'(t);
                    bg_free_slot = SLOT_W'(s);
                end
            end
        end

        // Victim slot from an LFSR, not a fixed index: a deterministic choice
        // lets two records ping-pong forever between the same pair of slots.
        bg_kick_tab  = bg_have_from_q ? TAB_W'(map_alt_tab(bg_from_tab_q))
                                      : TAB_W'(bg_lfsr_q[7]);
        bg_kick_slot = SLOT_W'(bg_lfsr_q[SLOT_W-1:0]);
        bg_victim    = s1_rec[bg_kick_tab][bg_kick_slot];
    end

    logic bg_place_now, bg_kick_now, bg_fail_now, bg_abort_now;

    always_comb begin
        // `bg_live` low means the fast path retired the order while it was
        // waiting for a grant. Abandon the move; there is nothing to place.
        bg_place_now = (bg_state_q == BG_EVAL) &&  bg_live &&  bg_free_ok;
        bg_kick_now  = (bg_state_q == BG_EVAL) &&  bg_live && !bg_free_ok
                                               && (bg_kicks_q != KICK_W'(MAX_KICKS));
        bg_fail_now  = (bg_state_q == BG_EVAL) &&  bg_live && !bg_free_ok
                                               && (bg_kicks_q == KICK_W'(MAX_KICKS));
        bg_abort_now = (bg_state_q == BG_EVAL) && !bg_live;
    end

    // =========================================================================
    // Write-port arbitration — fast path, then relocation, then wipe
    // -------------------------------------------------------------------------
    // Exactly one memory write per cycle, from exactly one source. The relocate
    // and wipe sources are mutually exclusive with the fast path by the grant
    // rule and by construction, so this is a priority mux for safety, not a
    // contention resolver.
    // =========================================================================
    logic              wr_en;
    logic [TAB_W-1:0]  wr_tab;
    logic [SLOT_W-1:0] wr_slot;
    logic [BUCK_W-1:0] wr_buck;
    order_rec_t        wr_rec;

    logic              fp_mem_wr;
    logic              fp_stash_wr;
    logic [STASH_W-1:0]fp_stash_idx;
    order_rec_t        fp_stash_rec;
    logic              fp_carry_wr;
    order_rec_t        fp_carry_rec;

    always_comb begin
        fp_mem_wr    = 1'b0;
        fp_stash_wr  = 1'b0;
        fp_stash_idx = '0;
        fp_stash_rec = '0;
        fp_carry_wr  = 1'b0;
        fp_carry_rec = '0;

        wr_en   = 1'b0;
        wr_tab  = '0;
        wr_slot = '0;
        wr_buck = '0;
        wr_rec  = '0;

        // 1. Fast path: rewrite where the record was found.
        if (s1_wb_en) begin
            case (s1_loc)
                LOC_BUCK: begin
                    fp_mem_wr = 1'b1;
                    wr_tab    = s1_hit_tab;
                    wr_slot   = s1_hit_slot;
                    wr_buck   = s1_buck[s1_hit_tab];
                    wr_rec    = s1_wb_rec;
                end
                LOC_STASH: begin
                    fp_stash_wr  = 1'b1;
                    fp_stash_idx = s1_hit_stash;
                    fp_stash_rec = s1_wb_rec;
                end
                LOC_CARRY: begin
                    fp_carry_wr  = 1'b1;
                    fp_carry_rec = s1_wb_rec;
                end
                default: begin
                    fp_mem_wr = 1'b0;
                end
            endcase
        end

        // 2. Fast path: place a brand-new record.
        if (s1_ins_buck) begin
            fp_mem_wr = 1'b1;
            wr_tab    = ins_tab;
            wr_slot   = ins_slot;
            wr_buck   = s1_buck[ins_tab];
            wr_rec    = s1_new_rec;
        end
        if (s1_ins_stash) begin
            fp_stash_wr  = 1'b1;
            fp_stash_idx = stash_free_idx;
            fp_stash_rec = s1_new_rec;
        end

        wr_en = fp_mem_wr;

        // 3. Background relocation. `bg_src_rec` is the LIVE record read from
        //    its current holder this cycle, never a cached copy.
        if (!fp_mem_wr && bg_place_now) begin
            wr_en   = 1'b1;
            wr_tab  = bg_free_tab;
            wr_slot = bg_free_slot;
            wr_buck = bg_buck[bg_free_tab];
            wr_rec  = bg_src_rec;
        end else if (!fp_mem_wr && bg_kick_now) begin
            wr_en   = 1'b1;
            wr_tab  = bg_kick_tab;
            wr_slot = bg_kick_slot;
            wr_buck = bg_buck[bg_kick_tab];
            wr_rec  = bg_src_rec;
        // 4. Post-CLEAR wipe, one slot per cycle.
        end else if (!fp_mem_wr && (bg_state_q == BG_WIPE)) begin
            wr_en   = 1'b1;
            wr_tab  = wipe_tab_q;
            wr_slot = wipe_slot_q;
            wr_buck = wipe_buck_q;
            wr_rec  = '0;
        end
    end

    // The single memory write port. wr_tab/wr_slot decode to per-array write
    // enables across the 8 banked memories.
    always_ff @(posedge clk) begin
        if (wr_en) mem[wr_tab][wr_slot][wr_buck] <= wr_rec;
    end

    // One-deep forward record of that write.
    always_ff @(posedge clk) begin
        if (rst) begin
            fwd_en_q <= 1'b0;
        end else begin
            fwd_en_q <= wr_en;
        end
        fwd_tab_q  <= wr_tab;
        fwd_slot_q <= wr_slot;
        fwd_buck_q <= wr_buck;
        fwd_rec_q  <= wr_rec;
    end

    // =========================================================================
    // Background engine state
    // =========================================================================
    logic wipe_last;
    assign wipe_last = (wipe_buck_q == BUCK_W'(N_BUCK-1))
                    && (wipe_slot_q == SLOT_W'(N_SLOT-1))
                    && (wipe_tab_q  == TAB_W'(N_TABLE-1));

    // ⚠️ DELIBERATE DEVIATION from "do not reset the datapath"
    //    (manuals/00-foundations/03-*.md §6): the stash records and the in-flight
    //    register are reset in full, not just their valid bits. They are 17
    //    records — ~2.3 k FF — so the load on the reset net is negligible, and in
    //    a design that has never been simulated, a fully determinate small CAM is
    //    worth more than the routing it costs. The 65,536-slot bucket memory is
    //    NOT reset; it cannot be, and BOOK_CLEAR wipes it instead.
    always_ff @(posedge clk) begin
        if (rst) begin
            bg_state_q     <= BG_IDLE;
            bg_kicks_q     <= '0;
            bg_have_from_q <= 1'b0;
            bg_from_src_q  <= 1'b0;
            bg_lfsr_q      <= 8'hA5;
            bg_stuck_q     <= 1'b0;
            wipe_pending_q <= 1'b0;
            wipe_buck_q    <= '0;
            wipe_slot_q    <= '0;
            wipe_tab_q     <= '0;
            carry_q        <= '0;
            stash_pin_q    <= '0;
            for (int unsigned i = 0; i < N_STASH; i++) stash_q[i] <= '0;
        end else begin
            // LFSR (x^8 + x^6 + x^5 + x^4 + 1), free-running so victim choice
            // does not correlate with the traffic pattern.
            bg_lfsr_q <= {bg_lfsr_q[6:0],
                          bg_lfsr_q[7] ^ bg_lfsr_q[5] ^ bg_lfsr_q[4] ^ bg_lfsr_q[3]};

            // Fast-path stash / in-flight writes always win.
            if (fp_stash_wr) stash_q[fp_stash_idx] <= fp_stash_rec;
            if (fp_carry_wr) carry_q               <= fp_carry_rec;

            // Any bucket record leaving the table frees space, so retry the
            // records that previously exhausted their chain.
            if (fp_mem_wr && !wr_rec.valid) stash_pin_q <= '0;

            if (p_clear) begin
                // Resync. Auxiliary state is cleared immediately; the record
                // memory is walked by the wipe below.
                bg_state_q     <= BG_WIPE;
                bg_kicks_q     <= '0;
                bg_have_from_q <= 1'b0;
                bg_from_src_q  <= 1'b0;
                carry_q        <= '0;
                stash_pin_q    <= '0;
                wipe_pending_q <= 1'b1;
                wipe_buck_q    <= '0;
                wipe_slot_q    <= '0;
                wipe_tab_q     <= '0;
                for (int unsigned i = 0; i < N_STASH; i++) stash_q[i] <= '0;
            end else begin
                case (bg_state_q)

                    // ⚠️ `!carry_q.valid` is a guard, not an optimisation. The
                    //    in-flight register holds at most one record; starting a
                    //    new chain while it is still occupied would overwrite a
                    //    live order on the next kick. That is an eviction, and it
                    //    would be invisible.
                    BG_IDLE: begin
                        if (bg_pick_ok && bg_grant && !carry_q.valid) begin
                            // The record STAYS in the stash entry. Only a
                            // pointer to its holder is taken.
                            bg_src_q       <= bg_pick_idx;
                            bg_from_src_q  <= 1'b1;
                            bg_have_from_q <= 1'b0;
                            bg_kicks_q     <= '0;
                            bg_state_q     <= BG_RD;
                        end
                    end

                    // The read address is driven this cycle when granted; data
                    // lands at the next edge. Waiting here is free — the record
                    // is live and findable in its holder the entire time.
                    BG_RD: begin
                        if (!bg_live)     bg_state_q <= BG_IDLE;  // retired meanwhile
                        else if (bg_grant)bg_state_q <= BG_EVAL;
                        else              bg_state_q <= BG_RD;
                    end

                    // ⚠️ The grant rule guarantees s1_valid is LOW in this state,
                    //    so no fast-path write can race anything below.
                    BG_EVAL: begin
                        if (bg_abort_now) begin
                            // The order was retired while we were waiting for a
                            // grant. There is nothing to move. Not an error.
                            bg_from_src_q  <= 1'b0;
                            bg_have_from_q <= 1'b0;
                            bg_state_q     <= BG_IDLE;
                        end else if (bg_place_now) begin
                            // Settled into a bucket. Release the holder at the
                            // SAME edge the bucket write lands, so the record is
                            // in exactly one searchable place before and after.
                            if (bg_from_src_q) stash_q[bg_src_q] <= '0;
                            else               carry_q           <= '0;
                            bg_from_src_q  <= 1'b0;
                            bg_have_from_q <= 1'b0;
                            bg_state_q     <= BG_IDLE;
                        end else if (bg_kick_now) begin
                            // ⚠️ CONSERVATION. In this single edge the carried
                            //    record enters the bucket slot and the incumbent
                            //    leaves it for the in-flight register. Both are
                            //    searchable before the edge and after it; there
                            //    is no cycle in which either is invisible, and
                            //    the live population is unchanged. That is what
                            //    makes a kick a relocation and not an eviction.
                            carry_q        <= bg_victim;
                            if (bg_from_src_q) stash_q[bg_src_q] <= '0;
                            bg_from_src_q  <= 1'b0;   // holder is now carry_q
                            bg_from_tab_q  <= bg_kick_tab;
                            bg_have_from_q <= 1'b1;
                            bg_kicks_q     <= bg_kicks_q + KICK_W'(1);
                            bg_state_q     <= BG_RD;
                        end else if (bg_fail_now) begin
                            // Chain exhausted at MAX_KICKS. The record rests in
                            // the stash, pinned so the engine does not spin on
                            // it, and is retried the moment table space is
                            // freed. It has been live and findable throughout —
                            // exhaustion costs occupancy, never an order.
                            if (bg_from_src_q) begin
                                stash_pin_q[bg_src_q] <= 1'b1;
                            end else if (stash_free_ok) begin
                                // The reserved entry. Provably available: with
                                // S = stash occupancy and C = in-flight valid,
                                // the fast path only inserts when S < N_STASH-1,
                                // and every engine transition preserves
                                // S + C <= N_STASH. Reaching here with C = 1
                                // therefore implies S <= N_STASH-1, so a free
                                // entry exists.
                                stash_q[stash_free_idx]     <= carry_q;
                                stash_pin_q[stash_free_idx] <= 1'b1;
                                carry_q                     <= '0;
                            end else begin
                                // ⚠️ UNREACHABLE by the argument above. If the
                                //    argument is ever broken by an edit, the
                                //    record is NOT dropped: it stays in the
                                //    in-flight register, which is still searched
                                //    every cycle, and BG_IDLE's guard stops a new
                                //    chain from overwriting it. The book goes
                                //    stale and stays stale. Wrong, loudly, with
                                //    the order still present — never wrong
                                //    silently with the order gone.
                                bg_stuck_q <= 1'b1;
                            end
                            bg_from_src_q  <= 1'b0;
                            bg_have_from_q <= 1'b0;
                            bg_state_q     <= BG_IDLE;
                        end else begin
                            bg_state_q <= BG_IDLE;
                        end
                    end

                    BG_WIPE: begin
                        if (!fp_mem_wr) begin
                            if (wipe_last) begin
                                wipe_pending_q <= 1'b0;
                                bg_state_q     <= BG_IDLE;
                            end else if (wipe_buck_q == BUCK_W'(N_BUCK-1)) begin
                                wipe_buck_q <= '0;
                                if (wipe_slot_q == SLOT_W'(N_SLOT-1)) begin
                                    wipe_slot_q <= '0;
                                    wipe_tab_q  <= wipe_tab_q + TAB_W'(1);
                                end else begin
                                    wipe_slot_q <= wipe_slot_q + SLOT_W'(1);
                                end
                            end else begin
                                wipe_buck_q <= wipe_buck_q + BUCK_W'(1);
                            end
                        end
                    end

                    default: begin
                        bg_state_q <= BG_IDLE;
                    end
                endcase
            end
        end
    end

    // =========================================================================
    // Population gauges — update logic (declarations are above stage 1)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            n_live_q      <= '0;
            n_untracked_q <= '0;
        end else if (p_clear) begin
            n_live_q      <= '0;
            n_untracked_q <= '0;
        end else begin
            if (p_live_up && !p_live_dn) n_live_q <= n_live_q + LIVE_W'(1);
            // Floored. The only way to reach a decrement at zero is a delete
            // that hits a record the resync wipe has not yet reached; a wrapped
            // gauge would report a full table and make `live_hi` useless for
            // sizing, which is the one job this counter has.
            if (p_live_dn && !p_live_up && (n_live_q != '0))
                n_live_q <= n_live_q - LIVE_W'(1);
            if (p_untr_up && !p_untr_dn) n_untracked_q <= n_untracked_q + 32'd1;
            if (p_untr_dn && !p_untr_up && (n_untracked_q != '0))
                n_untracked_q <= n_untracked_q - 32'd1;
        end
    end

    // =========================================================================
    // Stage 2 — registered outputs, telemetry
    // =========================================================================
    // Saturating increment. A wrapped alarm counter is an alarm that silently
    // rearms itself.
    function automatic logic [31:0] inc32(input logic [31:0] c, input logic e);
        return (e && (c != 32'hFFFF_FFFF)) ? (c + 32'd1) : c;
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            res_valid         <= 1'b0;
            map_stale         <= 1'b0;
            cnt_insert        <= '0;
            cnt_insert_fail   <= '0;
            cnt_miss          <= '0;
            cnt_delete        <= '0;
            cnt_forward       <= '0;
            occupancy_hi      <= '0;
            cnt_miss_benign   <= '0;
            cnt_miss_tracked  <= '0;
            cnt_stash_insert  <= '0;
            cnt_relocation    <= '0;
            cnt_untracked_add <= '0;
            cnt_kick_exhaust  <= '0;
            cnt_dup_add       <= '0;
            kick_depth_hi     <= '0;
            live_hi           <= '0;
            for (int unsigned i = 0; i <= MAX_KICKS; i++) kick_hist[i] <= '0;
        end else begin
            res_valid  <= s1_valid;
            res_hit    <= n_res_hit;
            res_sym    <= n_res_sym;
            res_side   <= n_res_side;
            res_price  <= n_res_price;
            res_delta  <= n_res_delta;
            res_add    <= n_res_add;
            res_remove <= n_res_remove;

            // ⚠️ Sticky. A resync clears it only after the wipe has finished,
            //    because until then the table still holds pre-gap records and a
            //    "clean" book would be a lie.
            if (p_stale || bg_stuck_q)         map_stale <= 1'b1;
            else if (p_clear)                  map_stale <= 1'b1;
            else if (wipe_pending_q && (bg_state_q == BG_WIPE) && wipe_last && !fp_mem_wr)
                                               map_stale <= 1'b0;

            cnt_insert        <= inc32(cnt_insert,        p_insert);
            cnt_insert_fail   <= inc32(cnt_insert_fail,   p_ins_fail);
            cnt_miss          <= inc32(cnt_miss,          p_miss_benign || p_miss_tracked);
            cnt_delete        <= inc32(cnt_delete,        p_delete);
            cnt_forward       <= inc32(cnt_forward,       s1_valid && s1_fwd);
            cnt_miss_benign   <= inc32(cnt_miss_benign,   p_miss_benign);
            cnt_miss_tracked  <= inc32(cnt_miss_tracked,  p_miss_tracked);
            cnt_stash_insert  <= inc32(cnt_stash_insert,  p_stash_ins);
            cnt_relocation    <= inc32(cnt_relocation,    bg_kick_now);
            cnt_untracked_add <= inc32(cnt_untracked_add, p_untracked);
            cnt_kick_exhaust  <= inc32(cnt_kick_exhaust,  bg_fail_now);
            cnt_dup_add       <= inc32(cnt_dup_add,       p_dup);

            // Kick-chain depth histogram, cumulative form.
            if (bg_kick_now) begin
                kick_hist[bg_kicks_q] <= inc32(kick_hist[bg_kicks_q], 1'b1);
                if (8'(bg_kicks_q) + 8'd1 > kick_depth_hi)
                    kick_depth_hi <= 8'(bg_kicks_q) + 8'd1;
            end

            // Capacity gauges. These, not the design intent, size the next build.
            if (16'(stash_used) > occupancy_hi) occupancy_hi <= 16'(stash_used);
            if (32'(n_live_q)   > live_hi)      live_hi      <= 32'(n_live_q);
        end
    end

    // =========================================================================
    // Assertions — simulation only
    // =========================================================================
`ifndef SYNTHESIS

    // ── Elaboration-time geometry ────────────────────────────────────────────
    initial begin
        if (N_TABLE != 2)
            $error("order_id_map: d=2 is structural; N_TABLE=%0d is unsupported", N_TABLE);
        if (N_BUCK != (1 << BUCK_W))
            $error("order_id_map: N_BUCK must be a power of two (no modulo on the fast path)");
        if (N_SLOT != (1 << SLOT_W))
            $error("order_id_map: N_SLOT must be a power of two");
        if (BUCK_W > 32)
            $error("order_id_map: bucket index wider than the 32-bit hash output");
        if (N_STASH < 2)
            $error("order_id_map: the stash needs at least one reserved entry");
        if (CAPACITY != (N_TABLE * N_SLOT * N_BUCK))
            $error("order_id_map: capacity derivation is inconsistent");
    end

    // ── Hash independence smoke test ─────────────────────────────────────────
    // ⚠️ If h1 ever becomes a trivial transform of h0 — a rotation, an XOR with
    //    a constant, the same polynomial with a different seed — the two bucket
    //    indices correlate and the achievable load factor collapses back to the
    //    single-hash behaviour this module was written to replace. Nasdaq issues
    //    references sequentially, so sequential keys are the case that matters.
    initial begin
        automatic int unsigned agree = 0;
        automatic int unsigned n     = 1024;
        for (int unsigned i = 0; i < n; i++) begin
            automatic order_ref_t k = 64'h0000_0000_000A_3F21 + 64'(i);
            if (map_bucket(1'b0, k) == map_bucket(1'b1, k)) agree++;
        end
        // Expected agreement for independent indices is n/N_BUCK, far below 1
        // at the default geometry. A threshold of n/64 is loose enough never to
        // false-alarm and tight enough to catch a correlated pair immediately.
        if (agree > (n >> 6))
            $error("order_id_map: h0 and h1 agree on %0d of %0d sequential keys — the two hashes are not independent", agree, n);
    end

    // ── The alternate-bucket function is an involution ────────────────────────
    // alt(alt(x, k), k) == x for every key. This is what guarantees a relocated
    // record is always at one of the two locations the lookup actually reads.
    assert property (@(posedge clk) disable iff (rst)
        s1_valid |->
            ((map_bucket(map_alt_tab(map_alt_tab(1'b0)), s1_key) == map_bucket(1'b0, s1_key)) &&
             (map_bucket(map_alt_tab(map_alt_tab(1'b1)), s1_key) == map_bucket(1'b1, s1_key)) &&
             (map_alt_tab(map_alt_tab(1'b0)) == 1'b0) &&
             (map_alt_tab(map_alt_tab(1'b1)) == 1'b1))
    ) else $error("order_id_map: alt() is not an involution — a relocated record may be unfindable");

    // ── Placement consistency: the strong form of the same property ──────────
    // Every valid record visible in a bucket must hash to that bucket for that
    // table. This catches a relocation that writes a record somewhere the lookup
    // will never look, which is an eviction with extra steps.
    for (genvar gt = 0; gt < N_TABLE; gt++) begin : g_place_chk
        for (genvar gs = 0; gs < N_SLOT; gs++) begin : g_slot_chk
            assert property (@(posedge clk) disable iff (rst)
                (s1_valid && s1_eff[gt][gs].valid)
                    |-> (s1_buck[gt] == map_bucket((gt != 0), s1_eff[gt][gs].key))
            ) else $error("order_id_map: record resident in a bucket it does not hash to (table %0d slot %0d)", gt, gs);
        end
    end

    // ── A key exists in AT MOST ONE place ────────────────────────────────────
    // Both buckets, all 16 stash entries and the in-flight register, together.
    // Two copies means a subsequent delete frees one and strands the other.
    assert property (@(posedge clk) disable iff (rst)
        s1_valid |-> ($countones(s1_match) <= 1)
    ) else $error("order_id_map: key present in more than one location");

    // ── The stash never exceeds capacity, and the reserve is respected ───────
    assert property (@(posedge clk) disable iff (rst)
        (stash_used <= (STASH_W+1)'(N_STASH))
    ) else $error("order_id_map: stash occupancy exceeds capacity");

    assert property (@(posedge clk) disable iff (rst)
        s1_ins_stash |-> (stash_used <= (STASH_W+1)'(N_STASH-2))
    ) else $error("order_id_map: fast path consumed the reserved stash entry");

    assert property (@(posedge clk) disable iff (rst)
        s1_ins_stash |-> stash_free_ok
    ) else $error("order_id_map: stash insert with no free entry");

    // ── ⚠️ THE IN-FLIGHT LOOKUP PROPERTY ─────────────────────────────────────
    // A lookup for a key that is present but MOVING must still hit. This is the
    // property that makes decoupled relocation viable at all; without it, a
    // delete arriving mid-chain would miss, the order would never be removed
    // from its level, and the book would diverge silently. It holds because the
    // record is never copied out of a searchable structure: it is in the stash
    // or in the in-flight register at every edge, and both are compared in the
    // same cycle as the buckets.
    assert property (@(posedge clk) disable iff (rst)
        (s1_valid && bg_busy && bg_live && (s1_key == bg_src_rec.key)) |-> s1_hit
    ) else $error("order_id_map: lookup missed a key that is present but mid-relocation");

    // The holder is always one of the two searched structures, never a private
    // register. (bg_src_rec is by construction one of them; this catches a
    // future edit that reintroduces a cached copy.)
    assert property (@(posedge clk) disable iff (rst)
        (bg_busy && bg_live)
            |-> (bg_from_src_q ? stash_q[bg_src_q].valid : carry_q.valid)
    ) else $error("order_id_map: record under relocation is not held by a searchable structure");

    // ── Relocation is LOSSLESS: item count is conserved across a kick ────────
    // ⚠️ This is the property that proves relocation is not eviction. A kick
    //    moves one record in and one record out of a slot in the same edge; the
    //    live population must not change, and the displaced record must appear
    //    intact in the in-flight register.
    assert property (@(posedge clk) disable iff (rst)
        bg_kick_now |=> (n_live_q == $past(n_live_q))
    ) else $error("order_id_map: live population changed across a relocation — a record was lost");

    assert property (@(posedge clk) disable iff (rst)
        (bg_kick_now && bg_victim.valid)
            |=> (carry_q.valid && (carry_q.key == $past(bg_victim.key))
                                && (carry_q.qty == $past(bg_victim.qty)))
    ) else $error("order_id_map: displaced record did not reach the in-flight register");

    // The record entering the bucket on a kick is the one that was being moved,
    // intact. A kick that wrote anything else would be a drop wearing a costume.
    assert property (@(posedge clk) disable iff (rst)
        bg_kick_now |-> (wr_en && wr_rec.valid && (wr_rec.key == bg_src_rec.key)
                               && (wr_rec.qty == bg_src_rec.qty))
    ) else $error("order_id_map: relocation wrote something other than the record it was moving");

    // The kicked record must land in the alternate of the table it came from.
    assert property (@(posedge clk) disable iff (rst)
        (bg_kick_now && bg_have_from_q)
            |-> (bg_kick_tab == TAB_W'(map_alt_tab(bg_from_tab_q)))
    ) else $error("order_id_map: relocation target is not the alternate bucket");

    // The engine only ever evaluates on a cycle with no fast-path activity.
    // Everything above depends on this, so it is checked rather than assumed.
    assert property (@(posedge clk) disable iff (rst)
        (bg_state_q == BG_EVAL) |-> (!s1_valid && !fp_mem_wr && !fp_stash_wr && !fp_carry_wr)
    ) else $error("order_id_map: background engine evaluated while the fast path was active");

    // Kicks are bounded. An unbounded displacement chain is forbidden.
    assert property (@(posedge clk) disable iff (rst)
        (bg_kicks_q <= KICK_W'(MAX_KICKS))
    ) else $error("order_id_map: kick chain exceeded MAX_KICKS");

    // ── No valid record with zero quantity ───────────────────────────────────
    // A live record with nothing left in it is an entry no message will ever
    // free: it occupies a slot for the rest of the session.
    assert property (@(posedge clk) disable iff (rst)
        wr_en |-> (wr_rec.valid -> (wr_rec.qty != '0))
    ) else $error("order_id_map: valid record written to a bucket with zero qty");

    assert property (@(posedge clk) disable iff (rst)
        fp_stash_wr |-> (fp_stash_rec.valid -> (fp_stash_rec.qty != '0))
    ) else $error("order_id_map: valid record written to the stash with zero qty");

    assert property (@(posedge clk) disable iff (rst)
        fp_carry_wr |-> (fp_carry_rec.valid -> (fp_carry_rec.qty != '0))
    ) else $error("order_id_map: valid record written to the in-flight register with zero qty");

    // ── Fixed latency: a request always produces exactly one result, 2 later ─
    assert property (@(posedge clk) disable iff (rst)
        req_act |-> ##2 res_valid
    ) else $error("order_id_map: request did not produce a result at exactly 2 cycles");

    // ── Population invariant: nothing is added to a level unless it is in the
    //    map. res_hit is the only thing price_levels acts on, so an untracked
    //    or failed add must never assert it.
    assert property (@(posedge clk) disable iff (rst)
        (s1_valid && (s1_op == BOOK_ADD) && (p_untracked || p_ins_fail)) |-> !n_res_hit
    ) else $error("order_id_map: quantity would be added to a level for an order not in the map");

    // ── A miss classified as benign must have had a credit to spend ──────────
    assert property (@(posedge clk) disable iff (rst)
        p_miss_benign |-> (n_untracked_q != '0)
    ) else $error("order_id_map: benign miss claimed with no untracked order to explain it");

    // A tracked miss is a lost order and must always stale the book.
    assert property (@(posedge clk) disable iff (rst)
        p_miss_tracked |-> p_stale
    ) else $error("order_id_map: a lost order did not stale the book");

    // Benign and tracked are mutually exclusive classifications.
    assert property (@(posedge clk) disable iff (rst)
        !(p_miss_benign && p_miss_tracked)
    ) else $error("order_id_map: miss classified as both benign and tracked");

    // ── Quantity must never increase on a reduce ─────────────────────────────
    assert property (@(posedge clk) disable iff (rst)
        (s1_valid && s1_hit && (s1_op inside {BOOK_EXECUTE, BOOK_CANCEL}))
            |-> (reduce_qty <= s1_hit_rec.qty)
    ) else $error("order_id_map: quantity increased on a reduce");

    // ── Replace must genuinely change the reference ──────────────────────────
    assert property (@(posedge clk) disable iff (rst)
        (s1_valid && (s1_op == BOOK_REPLACE)) |-> (s1_new_key != s1_key)
    ) else $error("order_id_map: BOOK_REPLACE with identical old/new reference");

    // Replace is a pure delete here; the add is a separate injected message.
    assert property (@(posedge clk) disable iff (rst)
        (s1_valid && (s1_op == BOOK_REPLACE)) |-> (n_res_add == '0)
    ) else $error("order_id_map: BOOK_REPLACE emitted an add — the engine already injects one");

    // ── Stale is sticky: it may only fall when a resync wipe has completed ───
    assert property (@(posedge clk) disable iff (rst)
        $fell(map_stale) |-> $past(wipe_pending_q && (bg_state_q == BG_WIPE) && wipe_last)
    ) else $error("order_id_map: stale flag cleared without a completed resync wipe");

    // ── The relocation chain terminates ──────────────────────────────────────
    // No cycle detection is needed and none is implemented: a displacement cycle
    // simply exhausts MAX_KICKS, the record rests in the stash, and it is pinned
    // so the engine cannot spin on it. Progress is therefore guaranteed without
    // ever inspecting the chain for repetition.
    assert property (@(posedge clk) disable iff (rst)
        bg_fail_now |=> (bg_state_q == BG_IDLE)
    ) else $error("order_id_map: exhausted chain did not terminate");

    assert property (@(posedge clk) disable iff (rst)
        bg_fail_now |=> ((|stash_pin_q) || (bg_pick_ok == 1'b0))
    ) else $error("order_id_map: exhausted chain left nothing pinned — the engine will spin");

    // The reserved stash entry is always there when an exhausted chain needs it.
    // Proof obligation for S + C <= N_STASH; if this fires, that invariant broke.
    assert property (@(posedge clk) disable iff (rst)
        (bg_fail_now && !bg_from_src_q) |-> stash_free_ok
    ) else $error("order_id_map: exhausted chain had no reserved stash entry to land in");

    assert property (@(posedge clk) disable iff (rst)
        (stash_used + (STASH_W+1)'(carry_q.valid)) <= (STASH_W+1)'(N_STASH)
    ) else $error("order_id_map: stash plus in-flight exceeds stash capacity");

    // Must never set. It exists so that if it ever does, the book stops being
    // trusted instead of quietly losing an order.
    assert property (@(posedge clk) disable iff (rst)
        !bg_stuck_q
    ) else $error("order_id_map: relocation engine stuck — an order could not be re-homed");

    // A new chain must never start while the in-flight register is occupied:
    // the first kick of that chain would overwrite the record it holds.
    assert property (@(posedge clk) disable iff (rst)
        (bg_state_q == BG_IDLE) ##1 (bg_state_q == BG_RD) |-> $past(!carry_q.valid)
    ) else $error("order_id_map: chain started with the in-flight register still occupied");

`endif

endmodule : order_id_map

`default_nettype wire
