// =============================================================================
// trading_pkg.sv — Global types, parameters, and interface contracts
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/04-system-architecture/01-tick-to-trade-pipeline.md
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// THIS FILE IS THE INTERFACE CONTRACT. Every block in rtl/ uses these types.
// Changing a type here is a system-wide change — update the latency budget in
// manuals/05-optimization/01-latency-budgeting.md at the same time.
//
// Design rules enforced by this package (CLAUDE.md §5):
//   * Fixed-point / integer only. No floating point anywhere on the fast path.
//   * Prices are ITCH-native scaled integers (4 implied decimals). Never convert.
//   * All widths parameterized; no magic numbers in RTL.
// =============================================================================
`ifndef TRADING_PKG_SV
`define TRADING_PKG_SV

package trading_pkg;

    // -------------------------------------------------------------------------
    // 1. System configuration
    // -------------------------------------------------------------------------
    // Core datapath clock. 10GbE / 64-bit = 156.25 MHz. One domain for the whole
    // fast path; CDC only at the MAC and PCIe boundaries.
    //
    // Expressed in integer picoseconds, not `real`. The project bans floating
    // point in RTL (CLAUDE.md §5.3) and `real` in a package leaks into any file
    // that imports it — including synthesizable ones. Latency arithmetic in
    // assertions and testbenches uses these integers.
    //   156.25 MHz  ->  6400 ps period.
    parameter int unsigned CORE_CLK_KHZ    = 156_250;
    parameter int unsigned CORE_CLK_PS     = 6_400;

    // MAC-facing AXI-Stream width (10GbE, 64-bit @ 156.25 MHz = 8 B/cycle).
    parameter int unsigned AXIS_W      = 64;
    parameter int unsigned AXIS_KEEP_W = AXIS_W / 8;

    // Widened internal message bus. A whole ITCH message lands in ONE beat so
    // the decoder needs no parsing state machine.
    // See manuals/01-fpga-design/02-pipelining-and-parallelism.md §3.
    parameter int unsigned ITCH_MSG_MAX_BYTES = 64;
    parameter int unsigned ITCH_MSG_W         = ITCH_MSG_MAX_BYTES * 8;   // 512
    parameter int unsigned ITCH_LEN_W         = 8;

    // Tradeable universe. Nasdaq stock-locate codes are dense integers, so the
    // symbol lookup is a 1-cycle direct index — never a hash.
    // See manuals/08-nasdaq/04-totalview-itch-5.0.md.
    parameter int unsigned N_SYMBOLS   = 8192;                       // locate space
    parameter int unsigned SYM_IDX_W   = $clog2(N_SYMBOLS);          // 13
    parameter int unsigned N_ACTIVE    = 256;                        // filtered set
    parameter int unsigned ACT_IDX_W   = $clog2(N_ACTIVE);           // 8

    // -------------------------------------------------------------------------
    // Order-book geometry — THE PRICE WINDOW
    // -------------------------------------------------------------------------
    // Levels tracked per symbol PER SIDE, direct-indexed on a tick-normalized
    // price inside a bounded, host-anchored window:
    //     level = (price - window_base) / TICK_UNITS
    //
    // ⚠️ THIS WAS 16 AND THAT WAS A FATAL DEFECT, NOT A TUNING CHOICE.
    //    16 levels is a $0.16 window. A symbol that moved eight cents from its
    //    anchor had left the window entirely, every subsequent update was
    //    rejected, and the published book froze while still looking plausible.
    //    The governing manual specified 2048 ($20.48) from the start; the RTL
    //    diverged from its own specification.
    //    See manuals/04-system-architecture/03-order-book-in-hardware.md §4
    //    ("The window and its base") and docs/ORDER-BOOK-REDESIGN.md §2.2.
    //
    // ⚠️ CHANGING THIS CHANGES THE MEMORY FOOTPRINT QUADRATICALLY WITH N_ACTIVE.
    //    The arithmetic is recorded in full below and in rtl/book/book_pkg.sv §2.
    //    Re-derive it before touching either number — capacity is a measurement,
    //    not a preference.
    parameter int unsigned BOOK_LEVELS = 2048;
    parameter int unsigned LEVEL_IDX_W = $clog2(BOOK_LEVELS);          // 11

    // Live order-reference map (ITCH is an order-based feed).
    //
    // ⚠️ THIS NUMBER MUST COME FROM MEASUREMENT, NOT FROM THIS FILE. It is the
    //    number of SLOTS in the cuckoo table; the usable live-order population
    //    is ~0.90 of it (d=2, b=4 sustains 0.976, and 0.90 leaves stash margin).
    //    Size it from the live-order histogram that tools/pcap/stats.py produces
    //    over a full TotalView-ITCH session for the ACTUAL subscribed universe,
    //    then check it against the SLR budget below. 65,536 is the value
    //    inherited from the first edition and is retained ONLY because no
    //    measurement has been run — it is not an endorsement.
    //    The fabric reports the number that would settle this: book_engine
    //    stat[6] = order_id_map.live_hi, the live-record high-water mark.
    parameter int unsigned ORDER_MAP_ENTRIES = 1 << 16;
    // Legacy 4-way set-associative geometry. The RTL no longer uses it (the map
    // is cuckoo, d=2 x b=4 — see book_pkg §5); tb/ and host/ mirrors still do.
    parameter int unsigned ORDER_MAP_WAYS    = 4;

    // =========================================================================
    // ⚠️ SLR CAPACITY — the binding constraint, computed, not asserted
    // =========================================================================
    // The ENTIRE fast path must fit in ONE SLR. A VU9P SLR holds ~320 URAM288
    // (4096 x 72) and ~720 BRAM36. Crossing an SLR boundary costs a pipeline
    // register on every book access, which is a latency change, not a placement
    // detail (manuals/04-system-architecture/03-*.md §5, 01-*.md §6).
    //
    // Level array (rtl/book/price_levels.sv, LVL_PACK = 2, QTY_W = 32)
    //   entries = N_ACTIVE x 2 sides x BOOK_LEVELS
    //           = 256 x 2 x 2048            = 1,048,576
    //   bits    = 1,048,576 x 32            = 33.55 Mbit
    //   packed 2 x 32 = 64 bit per word     =   524,288 words
    //   URAM288 is 4096 deep x 72 wide, so 64 bits is ONE URAM wide:
    //           524,288 / 4096              =       128 URAM288
    //   (Unpacked — one 32-bit entry per address — this is 256 URAM288, half of
    //    them paying for the unused 40 bits. The packing is what makes the array
    //    fit beside the order map.)
    //
    // Occupancy bitmap (the validity bitmap; makes clear/re-anchor O(1))
    //   256 sym x (2 x 2048) bit            =  1.05 Mbit
    //   256 deep x 4096 wide, both sides in ONE word
    //           ceil(4096 / 72)             =        57 BRAM36
    //
    // Order map (rtl/book/order_id_map.sv, 138-bit record, d=2 x b=4)
    //   buckets per table = 65,536 / 8      =     8,192
    //   8 arrays (2 tables x 4 slots), each 8,192 x 138 bit
    //           depth 8,192 / 4096 = 2 URAM, width ceil(138/72) = 2 URAM
    //           2 x 2 x 8                   =        32 URAM288
    //   Rate: 1 URAM288 per 2,048 slots. That ratio is the whole budget below.
    //
    // Symbol tables (manuals/04-system-architecture/02-*.md)
    //                                       =         3 URAM288 + 2 BRAM36
    // Top of book: registers only           =         0 URAM288
    //
    //   ────────────────────────────────────────────────────────────────────
    //   TOTAL at N_ACTIVE=256, BOOK_LEVELS=2048, ORDER_MAP_ENTRIES=65,536
    //           128 + 32 + 3 = 163 URAM288  of ~320 = 51 % of one SLR   ✅ FITS
    //           57 + 2 + 1   =  60 BRAM36   of ~720 =  8 %              ✅
    //   ────────────────────────────────────────────────────────────────────
    //
    // How far the order map can then grow, with N_ACTIVE held at 256:
    //
    //   map slots │ live @0.90 │ map URAM │ +levels+sym │ of 320 │ verdict
    //   ──────────┼────────────┼──────────┼─────────────┼────────┼──────────
    //      65,536 │     58,982 │       32 │         163 │   51 % │ fits (now)
    //     131,072 │    117,964 │       64 │         195 │   61 % │ fits
    //     262,144 │    235,929 │      128 │         259 │   81 % │ fits, tight
    //     524,288 │    471,859 │      256 │         387 │  121 % │ ❌ does not
    //
    // ⚠️ N_ACTIVE = 256 IS THEREFORE KEPT. It was questioned because the manual's
    //    memory budget is written for 128 symbols and the level array doubles at
    //    256. It doubles to 128 URAM288, which still leaves 189 URAM288 for the
    //    map — 387,072 slots, ~348,000 live orders at the 0.90 load ceiling.
    //    Nothing about the measured universe requires cutting symbols; if a
    //    future measurement lands above ~348k live orders, the symbol count is
    //    the free variable and comes down THEN, from that measurement.
    //    ⚠️ The 500k-live-order row of the redesign sizing table does not fit at
    //    ANY symbol count that also carries a 2048-level window: at 128 symbols
    //    the level array is 64 URAM288 and 64 + 256 + 3 = 323 > 320.
    parameter int unsigned SLR_URAM288    = 320;   // VU9P SLR budget, for asserts
    parameter int unsigned SLR_BRAM36     = 720;

    // Outstanding orders the FPGA may emit before the host has accounted for
    // them. Bounds position drift. See manuals/04-system-architecture/05-*.
    parameter int unsigned MAX_IN_FLIGHT = 64;
    parameter int unsigned CREDIT_W      = $clog2(MAX_IN_FLIGHT + 1);

    // -------------------------------------------------------------------------
    // 2. Scalar types
    // -------------------------------------------------------------------------
    // ITCH price: 4 bytes, 4 implied decimals. $12.3400 -> 32'd123400.
    parameter int unsigned PRICE_W  = 32;
    parameter int unsigned PRICE_SCALE = 10000;      // implied decimals
    typedef logic [PRICE_W-1:0]  price_t;

    // Shares. ITCH uses 4 bytes.
    parameter int unsigned QTY_W    = 32;
    typedef logic [QTY_W-1:0]     qty_t;

    // Notional = price * qty. Widened to avoid overflow; ALWAYS saturating.
    parameter int unsigned NOTIONAL_W = 64;
    typedef logic [NOTIONAL_W-1:0] notional_t;

    // Signed position (shares). Long positive, short negative.
    parameter int unsigned POS_W    = 40;
    typedef logic signed [POS_W-1:0] position_t;

    // ITCH order reference number: 8 bytes.
    typedef logic [63:0]          order_ref_t;

    // ITCH stock locate code: 2 bytes, dense integer -> direct index.
    typedef logic [15:0]          locate_t;

    // ITCH timestamp: 6 bytes, nanoseconds since midnight ET.
    typedef logic [47:0]          ts_ns_t;

    // Free-running core-clock cycle counter, for on-chip latency measurement.
    // See manuals/05-optimization/04-measurement-and-profiling.md.
    parameter int unsigned CYCLE_CNT_W = 48;
    typedef logic [CYCLE_CNT_W-1:0] cycle_t;

    // Index into the active (filtered) symbol arrays.
    typedef logic [ACT_IDX_W-1:0]  sym_idx_t;

    // Client order token, unique per order. Layout below (see order_token_t).
    parameter int unsigned TOKEN_W = 112;            // OUCH order token, 14 bytes
    typedef logic [TOKEN_W-1:0]    token_t;

    // -------------------------------------------------------------------------
    // 3. Enumerations
    // -------------------------------------------------------------------------
    typedef enum logic [0:0] {
        SIDE_BUY  = 1'b0,
        SIDE_SELL = 1'b1
    } side_e;

    // Per-symbol trading state. The strategy may only quote in TRADE_OPEN.
    // Driven by ITCH System Event (S), Trading Action (H), Operational Halt (h),
    // Reg SHO (Y), and the host session schedule.
    // See manuals/08-nasdaq/02-sessions-auctions-and-halts.md.
    typedef enum logic [2:0] {
        TRADE_CLOSED   = 3'd0,   // outside session
        TRADE_PREOPEN  = 3'd1,   // pre-market / accepting cross orders only
        TRADE_OPEN     = 3'd2,   // regular hours, quoting permitted
        TRADE_HALTED   = 3'd3,   // regulatory or operational halt
        TRADE_PAUSED   = 3'd4,   // LULD pause
        TRADE_AUCTION  = 3'd5,   // in a cross
        TRADE_STALE    = 3'd6,   // sequence gap: book not trustworthy
        TRADE_DISABLED = 3'd7    // host- or risk-disabled. RESET VALUE.
    } trade_state_e;

    // Book event emitted by the decoder for the book engine.
    typedef enum logic [2:0] {
        BOOK_ADD     = 3'd0,   // ITCH 'A' / 'F'
        BOOK_EXECUTE = 3'd1,   // ITCH 'E' / 'C'
        BOOK_CANCEL  = 3'd2,   // ITCH 'X'  (partial reduce)
        BOOK_DELETE  = 3'd3,   // ITCH 'D'  (full remove)
        BOOK_REPLACE = 3'd4,   // ITCH 'U'  (delete old ref, add new ref)
        BOOK_CLEAR   = 3'd5,   // resync / start of day
        BOOK_NOP     = 3'd6
    } book_op_e;

    // Strategy decision.
    typedef enum logic [1:0] {
        ACT_NONE   = 2'd0,
        ACT_SEND   = 2'd1,     // new order
        ACT_CANCEL = 2'd2      // cancel an existing order by token
    } action_e;

    // -------------------------------------------------------------------------
    // Minimum pricing increment (SEC Rule 612), PER SYMBOL.
    // -------------------------------------------------------------------------
    // ⚠️ THIS IS NOT A CONSTANT AND MUST NEVER BE BAKED INTO RTL AGAIN.
    // The classic regime is $0.01 for NMS stocks priced >= $1.00 and $0.0001
    // below $1.00. The SEC's 2024 amendments to Rule 612 introduce a finer
    // quoting increment ($0.005) for certain NMS stocks, selected by a
    // quoted-spread measurement and REASSIGNED PERIODICALLY. The assignment is
    // therefore data, not architecture: the host writes it per symbol into
    // sym_risk_t.tick_class and rewrites it when the venue reassigns.
    //
    // > **Verify:** *SEC Regulation NMS (17 CFR 242.612)*, the adopting release
    // > for the 2024 amendments, the current compliance date, and — critically —
    // > **where the per-symbol tick-size assignment is published**. Nasdaq
    // > announces operational handling via *Nasdaq Equity Trader Alerts*. Do not
    // > assert the current regime from memory; the set of affected symbols and
    // > the effective date both change.
    //   See manuals/08-nasdaq/06-regnms-and-compliance.md §5.
    //
    // ⚠️ CONSTRAINT ON THIS ENUM: every encoded increment MUST BE A DIVISOR OF
    // 100 ITCH units ($0.0100). The fabric test computes ONE residue, px mod 100,
    // with a fixed reciprocal multiply, and then tests that residue against the
    // per-symbol increment — which is only valid when the increment divides 100.
    // {1, 5, 10, 25, 50, 100} all do. A future regime with an increment that does
    // NOT divide 100 (e.g. $0.0003) needs a different residue base and is a
    // deliberate redesign, NOT a new enum value. See §6 `tick_price_ok`.
    //
    // ⚠️ ALL EIGHT ENCODINGS ARE NAMED. A packed record arriving from the host
    // can hold any 3-bit pattern; leaving one unnamed would make the cast to this
    // type produce an X in simulation and an unchecked don't-care in synthesis.
    // Both unusable encodings map to "reject".
    typedef enum logic [2:0] {
        TICK_UNSET = 3'd0,   // RESET VALUE — no increment configured ⇒ REJECT
        TICK_0001  = 3'd1,   // $0.0001 —   1 ITCH unit  (sub-dollar classic)
        TICK_0005  = 3'd2,   // $0.0005 —   5 ITCH units
        TICK_0010  = 3'd3,   // $0.0010 —  10 ITCH units
        TICK_0025  = 3'd4,   // $0.0025 —  25 ITCH units
        TICK_0050  = 3'd5,   // $0.0050 —  50 ITCH units (Rule 612 half-penny)
        TICK_0100  = 3'd6,   // $0.0100 — 100 ITCH units (classic whole penny)
        TICK_RSVD  = 3'd7    // reserved encoding ⇒ REJECT (fail-closed)
    } tick_class_e;

    // Pre-trade risk rejection reasons. EVERY reason gets its own counter —
    // a check that never fires is a check you cannot trust.
    // See manuals/08-nasdaq/09-risk-controls-and-limits.md.
    //
    // ⚠️ THE NUMBERING IS A CROSS-LAYER CONTRACT. These codes are written into
    // telemetry registers, the per-symbol first-reject latch and the DMA reject
    // log, and are decoded by host tooling that is not this process. NEW REASONS
    // ARE APPENDED, NEVER INSERTED — renumbering silently re-labels every
    // historical record the host has already stored.
    //
    // ⚠️ Attribution order: the risk gate reports the LOWEST set index, so the
    // position of a reason in this list is its reporting priority when several
    // checks fail at once. Appended reasons therefore report only when no
    // lower-numbered check also failed, which is why the three LULD outcomes are
    // made MUTUALLY EXCLUSIVE in risk_gate rather than relying on priority.
    typedef enum logic [4:0] {
        RISK_OK              = 5'd0,
        RISK_MASTER_DISABLED = 5'd1,
        RISK_KILL_SWITCH     = 5'd2,
        RISK_SYM_DISABLED    = 5'd3,
        RISK_SESSION_CLOSED  = 5'd4,
        RISK_SYM_HALTED      = 5'd5,
        RISK_BOOK_STALE      = 5'd6,
        RISK_SUB_PENNY       = 5'd7,    // SEC Rule 612: price off the symbol's
                                        //   minimum-increment grid (tick_class)
        RISK_PRICE_COLLAR    = 5'd8,
        RISK_LULD_BAND       = 5'd9,    // bands ARE loaded and fresh, and the
                                        //   price is outside them
        RISK_SSR             = 5'd10,   // Reg SHO Rule 201 short-sale price test
        RISK_MAX_SHARES      = 5'd11,
        RISK_MAX_NOTIONAL    = 5'd12,
        RISK_POS_LIMIT       = 5'd13,
        RISK_GROSS_LIMIT     = 5'd14,
        RISK_OPEN_ORDERS     = 5'd15,
        RISK_MSG_RATE        = 5'd16,
        RISK_DUPLICATE       = 5'd17,
        RISK_SELF_MATCH      = 5'd18,
        RISK_RESTRICTED      = 5'd19,
        RISK_NO_CREDIT       = 5'd20,   // in-flight limit reached
        RISK_ZERO_QTY        = 5'd21,
        RISK_ZERO_PRICE      = 5'd22,
        RISK_PARAM_INVALID   = 5'd23,
        // ── appended 2026-08 with the LULD band-source fix ───────────────────
        // ⚠️ These three states were previously indistinguishable. "No bands
        // have ever been loaded for this symbol" and "the price is outside a
        // live band" are completely different operational problems — the first
        // is a control-plane outage, the second is a market event — and a single
        // counter for both cannot tell you which is happening.
        RISK_LULD_NOT_LOADED = 5'd24,   // sym_risk_t.luld_valid = 0: the host has
                                        //   never published SIP bands for this
                                        //   symbol. Fail-closed, NOT a market event.
        RISK_LULD_STALE      = 5'd25    // bands were published but are older than
                                        //   the host-written freshness bound: we
                                        //   no longer know the live band.
    } risk_reason_e;
    parameter int unsigned N_RISK_REASONS = 26;

    // Kill-switch trigger provenance, latched sticky for post-incident analysis.
    typedef enum logic [2:0] {
        KILL_NONE       = 3'd0,
        KILL_HOST       = 3'd1,   // host wrote the kill register
        KILL_WATCHDOG   = 3'd2,   // host heartbeat stopped
        KILL_MSG_RATE   = 3'd3,   // outbound rate limit breached
        KILL_POS_BREACH = 3'd4,   // aggregate position limit breached
        KILL_GPIO       = 3'd5,   // external hardware input
        KILL_LINK_DOWN  = 3'd6,   // order-entry link lost
        KILL_SEQ_FAULT  = 3'd7    // unrecoverable session sequence fault
    } kill_src_e;

    // -------------------------------------------------------------------------
    // 4. Fast-path structs
    // -------------------------------------------------------------------------

    // Decoded ITCH message -> book engine. One beat, fixed offsets.
    // Produced by rtl/feed/itch_decoder.sv.
    typedef struct packed {
        book_op_e    op;
        sym_idx_t    sym;          // active-set index (post-filter)
        locate_t     locate;       // raw ITCH stock locate, for telemetry
        side_e       side;
        price_t      price;
        qty_t        qty;
        order_ref_t  order_ref;    // key into the order-ID map
        order_ref_t  new_order_ref;// ITCH 'U' only: the replacement reference
        ts_ns_t      exch_ts;      // exchange timestamp from the message
        cycle_t      rx_cycle;     // OUR ingress timestamp, for latency measurement
        logic        printable;    // trade is printable (affects last-price)
    } book_evt_t;

    // Book engine -> strategy. Top-of-book after this update.
    // Produced by rtl/book/book_engine.sv.
    typedef struct packed {
        sym_idx_t    sym;
        price_t      bid_px;
        qty_t        bid_qty;
        price_t      ask_px;
        qty_t        ask_qty;
        price_t      last_px;
        logic        bid_valid;
        logic        ask_valid;
        logic        crossed;      // bid >= ask: never act on a crossed book
        logic        stale;        // sequence gap seen; book not trustworthy
        logic        top_changed;  // top-of-book actually moved this update
        cycle_t      rx_cycle;     // carried through for end-to-end latency
    } book_top_t;

    // Strategy -> risk gate. A *request*; risk may reject it.
    // Produced by rtl/strategy/strategy_engine.sv.
    typedef struct packed {
        action_e     action;
        sym_idx_t    sym;
        side_e       side;
        price_t      price;
        qty_t        qty;
        logic        post_only;    // add-liquidity-only: never cross the spread
        logic        is_short;     // short sale -> triggers the SSR check
        logic [3:0]  strat_id;     // which strategy primitive fired
        token_t      cancel_token; // ACT_CANCEL only
        cycle_t      rx_cycle;
    } order_req_t;

    // Risk gate -> order encoder. Only ever produced when verdict == RISK_OK.
    // Produced by rtl/risk/risk_gate.sv.
    typedef struct packed {
        action_e      action;
        sym_idx_t     sym;
        side_e        side;
        price_t       price;
        qty_t         qty;
        logic         post_only;
        logic         is_short;
        token_t       token;       // generated here; unique and reconcilable
        cycle_t       rx_cycle;
    } order_out_t;

    // Per-symbol risk parameters. Written by the host, double-buffered with a
    // commit bit so the fast path never reads a half-written record.
    // RESET VALUE IS ALL-ZERO = trading disabled, all limits zero, no LULD bands
    // loaded, no tick increment configured (fail-closed).
    //
    // ⚠️⚠️ HOST SOFTWARE MIRRORS THIS STRUCT BIT FOR BIT. Changing it is a
    // cross-layer change. Total width is 327 bits = 11 host words of 32 bits;
    // record bits [32w+31 : 32w] are carried in word w (w = 0..10, LSB word
    // first), word 10 carrying bits [326:320] in its low 7 bits. Word count is
    // UNCHANGED at 11, so the commit sequence length and the CRC coverage are
    // unchanged; only the bit layout moved.
    //
    //   field                 width  bits          notes
    //   enabled                   1  [326]
    //   shortable                 1  [325]
    //   max_order_qty            32  [324:293]
    //   max_order_notional       64  [292:229]
    //   max_long_pos             40  [228:189]
    //   max_short_pos            40  [188:149]     positive magnitude
    //   collar_lo                32  [148:117]
    //   collar_hi                32  [116: 85]
    //   luld_lo                  32  [ 84: 53]     ⚠️ SIP LULD band, host-written
    //   luld_hi                  32  [ 52: 21]     ⚠️ SIP LULD band, host-written
    //   luld_valid                1  [ 20]         ⚠️ NEW
    //   ssr_active                1  [ 19]
    //   max_open_orders          16  [ 18:  3]
    //   tick_class                3  [  2:  0]     ⚠️ NEW (replaces tick_penny)
    //
    // ⚠️⚠️ LULD BANDS ARE HOST-WRITTEN AND ARE **NOT** THE ITCH `J` VALUES.
    //   ITCH `J` (LULD Auction Collar) carries the collar prices for a REOPENING
    //   AUCTION after a pause. The continuous LULD price bands that constrain
    //   ordinary order entry come from the SIP (the LULD Plan's processor) and
    //   this FPGA does not consume the SIP. Sourcing `luld_lo`/`luld_hi` from
    //   ITCH `J` left them at 0/0 for essentially the whole session and, because
    //   the risk gate is correctly fail-closed, rejected every order all day.
    //   These two fields are therefore the AUTHORITATIVE band source and the host
    //   is obliged to keep them current. The ITCH `J` collars are carried
    //   separately, under their own name, in risk_gate's venue-state record.
    //   See manuals/08-nasdaq/02-sessions-auctions-and-halts.md §4.
    typedef struct packed {
        logic        enabled;
        logic        shortable;      // not on the restricted / hard-to-borrow list
        qty_t        max_order_qty;
        notional_t   max_order_notional;
        position_t   max_long_pos;
        position_t   max_short_pos;  // stored as a positive magnitude
        price_t      collar_lo;      // hard price floor
        price_t      collar_hi;      // hard price ceiling
        price_t      luld_lo;        // SIP LULD lower band  (host-written)
        price_t      luld_hi;        // SIP LULD upper band  (host-written)
        // ⚠️ Bands are only usable when the host asserts this bit. 0 is NOT
        // "no constraint" — it is "we do not know the band", which rejects
        // (RISK_LULD_NOT_LOADED). This is what makes "bands never loaded"
        // distinguishable from "bands loaded and wide"; the old design could not
        // tell those apart because both looked like 0/0.
        logic        luld_valid;
        logic        ssr_active;     // Reg SHO Rule 201 in force for this symbol
        logic [15:0] max_open_orders;
        // ⚠️ Rule 612 minimum pricing increment for THIS symbol. Reset value
        // TICK_UNSET rejects every priced order. See tick_class_e above.
        tick_class_e tick_class;
    } sym_risk_t;

    // Per-symbol strategy parameters. Same double-buffered discipline.
    typedef struct packed {
        logic        strat_enabled;
        logic [3:0]  strat_select;   // which hardened primitive to run
        qty_t        quote_qty;
        price_t      edge_ticks;     // threshold, in ticks
        qty_t        min_book_qty;   // don't act on a thin book
        price_t      fair_value;     // written by the host at ms cadence
        logic [15:0] imbalance_thr;
    } sym_strat_t;

    // -------------------------------------------------------------------------
    // 5. Order token layout
    // -------------------------------------------------------------------------
    // The token is the ONLY link between an FPGA-emitted order and the host's
    // accounting. It must be unique for the life of the session and must be
    // decodable by the host without a lookup.
    // See manuals/08-nasdaq/05-ouch-5.0-order-entry.md.
    typedef struct packed {
        logic [15:0] magic;      // build/session tag; host rejects a mismatch
        logic [3:0]  strat_id;
        logic [11:0] sym;        // active-set index, zero-extended
        logic [47:0] counter;    // monotonic, never reused within a session
        logic [31:0] rsvd;
    } order_token_t;             // = 112 bits = TOKEN_W

    // -------------------------------------------------------------------------
    // 6. Helper functions (synthesizable, combinational)
    // -------------------------------------------------------------------------

    // Saturating unsigned add. ALL risk/position arithmetic saturates —
    // a wrapped counter turns a risk check into a no-op. See CLAUDE.md §5.
    function automatic logic [63:0] sat_add64(input logic [63:0] a,
                                             input logic [63:0] b);
        logic [64:0] s;
        s = {1'b0, a} + {1'b0, b};
        return s[64] ? 64'hFFFF_FFFF_FFFF_FFFF : s[63:0];
    endfunction

    // Saturating unsigned subtract (floor at zero).
    function automatic logic [63:0] sat_sub64(input logic [63:0] a,
                                              input logic [63:0] b);
        return (a > b) ? (a - b) : 64'd0;
    endfunction

    // =========================================================================
    // SEC RULE 612 — PER-SYMBOL MINIMUM PRICING INCREMENT ("tick validity")
    // =========================================================================
    // NO MODULO / NO DIVIDER / NO FLOATING POINT anywhere below
    // (CLAUDE.md §5, manuals/00-foundations/03-hdl-and-rtl-coding.md §7).
    //
    // ── The arithmetic, in full ───────────────────────────────────────────────
    //   1. q = floor(px / 100) via a fixed reciprocal multiply:
    //          q = (px * M) >> S,    M = ceil(2^S / 100) = 1_374_389_535, S = 37.
    //      One 32x32 unsigned multiply (≈4 DSP48E2) and a wired shift.
    //   2. r = px - 100*q, with 100*q formed as (q<<6) + (q<<5) + (q<<2).
    //      Shifts and one adder — no second multiplier. r is 7 bits, 0..99.
    //   3. valid  <=>  r is a multiple of the symbol's increment T,
    //      which is a 7-bit set-membership test (one small LUT).
    //
    // ── WHY STEP 3 IS LEGITIMATE ─────────────────────────────────────────────
    //   For any T that DIVIDES 100:  px = 100q + r  and  T | 100  ⇒  100q ≡ 0
    //   (mod T)  ⇒  px ≡ r (mod T). So testing the residue mod 100 against T is
    //   EXACTLY testing px against T. Every increment in tick_class_e divides 100
    //   ({1,5,10,25,50,100}); that constraint is stated on the enum and is the
    //   load-bearing assumption of this whole scheme.
    //   ⚠️ This is why one fixed reciprocal serves every tick regime: the DSP
    //   constant never depends on tick_class, so a tick-size change is a table
    //   write, never a re-synthesis, and the DSP operand path carries no mux.
    //
    // ── EXACTNESS OF STEP 1 OVER THE FULL ITCH PRICE SPAN ────────────────────
    //   Claim: (px * M) >> S == floor(px/100) for EVERY px in
    //          [0, 2^32-1] = [$0.0000, $429,496.7295]  — the entire ITCH span.
    //   Proof. Let d = 100, e = M*d - 2^S = 137,438,953,500 - 137,438,953,472 = 28.
    //   Write px = q*d + r with 0 <= r <= 99. Then
    //          px*M = q*2^S + q*e + r*M,
    //   so     (px*M) >> S = q + floor( (q*e + r*M) / 2^S ).
    //   The result is exactly q iff  q*e + r*M < 2^S.
    //   Over px <= 2^32-1 the numerator is maximised at q = 42,949,671, r = 99:
    //          42,949,671*28 + 99*1,374,389,535
    //        = 1,202,590,788 + 136,064,563,965
    //        = 137,267,154,753  <  137,438,953,472 = 2^37.   ∎
    //   Margin 171,798,719 — the bound is met with room, not by luck.
    //   ⚠️ The previous comment here claimed exactness only for px < 2^31. That
    //   understated it; the bound above covers the full 32-bit range, and the
    //   distinction matters because prices above $214,748.3647 are representable
    //   and must not silently mis-validate.
    //   ⚠️ VERIFIED EXHAUSTIVELY, not sampled: all 4,294,967,296 values of px were
    //   checked against a real divider. Zero mismatches. The algebra above is the
    //   reason; the sweep is the evidence that the algebra was transcribed
    //   correctly, and they are not the same claim. risk_gate.sv §12 re-runs a
    //   250k-point subset at elaboration so a future edit to M or S cannot land
    //   quietly.
    //
    //   ⚠️ IF YOU CHANGE M OR S, REDO THE INEQUALITY. A reciprocal that is
    //   "obviously right" and off by one at the top of the range produces a
    //   Rule 612 check that passes every test price anyone thinks to try.
    //
    // See manuals/08-nasdaq/06-regnms-and-compliance.md §5.
    parameter logic [31:0] RECIP_100       = 32'd1_374_389_535;
    parameter int unsigned RECIP_100_SHIFT = 37;

    // Rule 612's price threshold: at or above $1.00 the coarse increment applies;
    // below it the increment is $0.0001, which every ITCH-representable price
    // already satisfies.
    // > **Verify:** the threshold, and whether the 2024 amendments changed it,
    // > against 17 CFR 242.612 as currently in force.
    parameter price_t RULE612_DOLLAR_PX = price_t'(32'd10_000);   // $1.0000

    function automatic price_t div100(input price_t px);
        logic [63:0] prod;
        prod = 64'(px) * 64'(RECIP_100);
        return price_t'(prod >> RECIP_100_SHIFT);
    endfunction

    // px mod 100, exact for all px, with no divider and no second multiplier.
    // 100*q cannot overflow price_t because 100*q <= px <= 2^32-1 by construction.
    function automatic logic [6:0] resid100(input price_t px);
        price_t q, q_x100;
        q      = div100(px);
        q_x100 = price_t'((q << 6) + (q << 5) + (q << 2));   // q*100, shifts only
        return 7'(px - q_x100);
    endfunction

    // The increment, in ITCH units, for a tick class. 0 means "no legal
    // increment" — TICK_UNSET and TICK_RSVD both reject. Host/testbench facing;
    // the fabric uses the residue test below rather than this value.
    function automatic logic [7:0] tick_units(input tick_class_e c);
        logic [7:0] u;
        unique case (c)
            TICK_0001 : u = 8'd1;
            TICK_0005 : u = 8'd5;
            TICK_0010 : u = 8'd10;
            TICK_0025 : u = 8'd25;
            TICK_0050 : u = 8'd50;
            TICK_0100 : u = 8'd100;
            default   : u = 8'd0;        // TICK_UNSET / TICK_RSVD: fail-closed
        endcase
        return u;
    endfunction

    // Is a residue-mod-100 on the symbol's increment grid? Constant sets, so this
    // is one small LUT per class and a mux — no arithmetic at all.
    // ⚠️ `default` REJECTS. An unconfigured or reserved tick class must never
    // read as "any price is fine".
    function automatic logic tick_resid_ok(input logic [6:0]  r,
                                           input tick_class_e c);
        logic ok;
        unique case (c)
            TICK_0001 : ok = 1'b1;                       // every unit is on-grid
            TICK_0005 : ok = (r inside {7'd0,  7'd5,  7'd10, 7'd15, 7'd20, 7'd25,
                                        7'd30, 7'd35, 7'd40, 7'd45, 7'd50, 7'd55,
                                        7'd60, 7'd65, 7'd70, 7'd75, 7'd80, 7'd85,
                                        7'd90, 7'd95});
            TICK_0010 : ok = (r inside {7'd0,  7'd10, 7'd20, 7'd30, 7'd40,
                                        7'd50, 7'd60, 7'd70, 7'd80, 7'd90});
            TICK_0025 : ok = (r inside {7'd0,  7'd25, 7'd50, 7'd75});
            TICK_0050 : ok = (r inside {7'd0,  7'd50});
            TICK_0100 : ok = (r == 7'd0);
            default   : ok = 1'b0;                       // fail-closed
        endcase
        return ok;
    endfunction

    // The complete per-symbol Rule 612 test, as one call. This is the REFERENCE
    // form: the host mirror, the testbenches and the SVA use it.
    // ⚠️ risk_gate evaluates the two halves in different pipeline stages
    // (resid100 at T0, tick_resid_ok at T1) for timing. It calls THESE SAME
    // package functions to do it, so the split cannot drift from the reference —
    // a divergent local copy of a Rule 612 test is exactly the failure this
    // package exists to prevent.
    function automatic logic tick_price_ok(input price_t px, input tick_class_e c);
        logic ok;
        if (px < RULE612_DOLLAR_PX) begin
            // Sub-$1.00: the increment is $0.0001 = 1 ITCH unit, which every
            // representable price meets. The class must still be a real class:
            // an unprovisioned symbol does not become tradeable by being cheap.
            ok = (c != TICK_UNSET) && (c != TICK_RSVD);
        end else begin
            ok = tick_resid_ok(resid100(px), c);
        end
        return ok;
    endfunction

    // Byte-swap helpers: ITCH and OUCH are big-endian on the wire; the fabric
    // is little-endian by convention here. Convert once, at the boundary.
    function automatic logic [15:0] bswap16(input logic [15:0] d);
        return {d[7:0], d[15:8]};
    endfunction

    function automatic logic [31:0] bswap32(input logic [31:0] d);
        return {d[7:0], d[15:8], d[23:16], d[31:24]};
    endfunction

    function automatic logic [63:0] bswap64(input logic [63:0] d);
        return {d[7:0],   d[15:8],  d[23:16], d[31:24],
                d[39:32], d[47:40], d[55:48], d[63:56]};
    endfunction

endpackage : trading_pkg

`endif
