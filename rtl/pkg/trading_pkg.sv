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

    // Order-book geometry. Depth is deliberately shallow: most hardware
    // strategies need top-of-book or top-N only.
    // See manuals/04-system-architecture/03-order-book-in-hardware.md.
    parameter int unsigned BOOK_LEVELS = 16;
    parameter int unsigned LEVEL_IDX_W = $clog2(BOOK_LEVELS);

    // Live order-reference map (ITCH is an order-based feed).
    parameter int unsigned ORDER_MAP_ENTRIES = 1 << 16;
    parameter int unsigned ORDER_MAP_WAYS    = 4;

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

    // Pre-trade risk rejection reasons. EVERY reason gets its own counter —
    // a check that never fires is a check you cannot trust.
    // See manuals/08-nasdaq/09-risk-controls-and-limits.md.
    typedef enum logic [4:0] {
        RISK_OK              = 5'd0,
        RISK_MASTER_DISABLED = 5'd1,
        RISK_KILL_SWITCH     = 5'd2,
        RISK_SYM_DISABLED    = 5'd3,
        RISK_SESSION_CLOSED  = 5'd4,
        RISK_SYM_HALTED      = 5'd5,
        RISK_BOOK_STALE      = 5'd6,
        RISK_SUB_PENNY       = 5'd7,    // SEC Rule 612
        RISK_PRICE_COLLAR    = 5'd8,
        RISK_LULD_BAND       = 5'd9,    // outside the LULD band
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
        RISK_PARAM_INVALID   = 5'd23
    } risk_reason_e;
    parameter int unsigned N_RISK_REASONS = 24;

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
    // RESET VALUE IS ALL-ZERO = trading disabled, all limits zero (fail-closed).
    typedef struct packed {
        logic        enabled;
        logic        shortable;      // not on the restricted / hard-to-borrow list
        qty_t        max_order_qty;
        notional_t   max_order_notional;
        position_t   max_long_pos;
        position_t   max_short_pos;  // stored as a positive magnitude
        price_t      collar_lo;      // hard price floor
        price_t      collar_hi;      // hard price ceiling
        price_t      luld_lo;        // current LULD lower band
        price_t      luld_hi;        // current LULD upper band
        logic        ssr_active;     // Reg SHO Rule 201 in force for this symbol
        logic [15:0] max_open_orders;
        logic        tick_penny;     // Rule 612: price must be a whole cent
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

    // Rule 612 sub-penny test for stocks >= $1.00: price must be a whole cent.
    // ITCH price has 4 implied decimals, so a whole cent means px % 100 == 0.
    //
    // NO MODULO / NO DIVIDER (CLAUDE.md §5, manuals/00-foundations/03-*.md §7).
    // Divide-by-100 is done with a reciprocal multiply: q = (px * M) >> 37,
    // M = ceil(2^37 / 100) = 1_374_389_535. Exact for px < 2^31, which covers
    // the full ITCH price range ($0.0000 .. $429_496.7295).
    // The multiply maps to one DSP48; pipeline it if it lands on a critical path.
    // See manuals/08-nasdaq/06-regnms-and-compliance.md.
    parameter logic [31:0] RECIP_100 = 32'd1_374_389_535;
    parameter int unsigned RECIP_100_SHIFT = 37;

    function automatic price_t div100(input price_t px);
        logic [63:0] prod;
        prod = 64'(px) * 64'(RECIP_100);
        return price_t'(prod >> RECIP_100_SHIFT);
    endfunction

    function automatic logic is_whole_penny(input price_t px);
        return (px == (div100(px) * 32'd100));
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
