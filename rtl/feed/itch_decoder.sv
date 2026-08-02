// =============================================================================
// itch_decoder.sv — Nasdaq TotalView-ITCH 5.0 fixed-offset message decoder
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/04-system-architecture/02-feed-handler-design.md  §6
//           manuals/08-nasdaq/04-totalview-itch-5.0.md
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
// Layer   : rtl/feed — see rtl/feed/README.md
//
// PURPOSE
//   Convert ONE whole ITCH 5.0 message, presented in a single ITCH_MSG_W-bit
//   beat, into ONE trading_pkg::book_evt_t plus a venue-state side-band.
//
// -----------------------------------------------------------------------------
// ⚠️  THE KEY STRUCTURAL PROPERTY — READ THIS BEFORE CHANGING ANYTHING
//
//   THIS IS NOT A PARSER. THERE IS NO STATE MACHINE HERE, AND THERE MUST NEVER
//   BE ONE.
//
//   Every ITCH 5.0 message type has a FIXED length and FIXED field byte
//   offsets. The message arrives byte-0-aligned in one beat. Therefore every
//   field of every message type sits at a COMPILE-TIME CONSTANT bit offset in
//   `s_msg`, and decode reduces to:
//
//       (a) constant part-selects  +  (b) one 8-bit type-indexed mux
//
//   A byte-serial FSM would cost 3-7 cycles per message *and* make the latency
//   a function of message length — i.e. it would inject jitter proportional to
//   the message mix. Determinism is worth more than area here (CLAUDE.md §5.8).
//   The mux tree is a few hundred LUTs. Pay the area, keep the 1 cycle.
//
//   Consequence for maintainers: adding a message type is ONE `case` arm. It is
//   not a new state, not a new transition, and it cannot break the decode of
//   any other type.
// -----------------------------------------------------------------------------
// ⚠️  VERIFY OFFSETS — THIS MODULE IS NOT PRODUCTION-TRUSTWORTHY YET
//
//   The byte offsets used here come from two places, and BOTH are unverified:
//
//     1. itch_pkg.sv — see the ⚠️ header block at the top of that file. Every
//        OFF_* / LEN_* constant it exports is marked "verify against spec".
//     2. The localparams in section 2 below (OFF_S_EVENT, OFF_H_STATE,
//        OFF_h_ACTION, OFF_Y_ACTION, OFF_J_UPPER, OFF_J_LOWER, OFF_W_LEVEL,
//        OFF_K_QUAL, OFF_C_PRINTABLE, OFF_C_PRICE), which itch_pkg.sv does not
//        yet define at all and which were derived from the published message
//        layouts, not read off a spec PDF.
//
//   BEFORE THIS MODULE MAY BE POINTED AT A LIVE OR UAT VENUE SESSION:
//     • Confirm every offset and length against the current *Nasdaq
//       TotalView-ITCH 5.0* specification PDF:
//           https://nasdaqtrader.com/Trading/TradingSpecs
//       (Nasdaq has revised message lengths across minor versions.)
//     • Prefer GENERATING itch_pkg.sv from the spec tables
//       (scripts/gen_itch_pkg.py) over hand-transcription. Hand-transcribed
//       offsets are a silent-corruption bug class.
//     • Validate this RTL against an INDEPENDENT golden software model — one
//       written from the spec, not derived from this RTL — replayed over a real
//       pcap corpus plus the alignment sweep described in
//       manuals/04-system-architecture/02-feed-handler-design.md §12.
//
//   A wrong offset produces a decoder that works on some messages and silently
//   corrupts others. That is the worst available failure mode in this domain:
//   it does not stop, it does not count, it just trades on a wrong book.
// -----------------------------------------------------------------------------
// LATENCY
//   1 cycle, fixed, for every message type. 6.4 ns @ 156.25 MHz (CORE_CLK_NS).
//   Combinational field extraction + type mux, then one output register bank.
//   Initiation interval = 1: a valid input may be presented every cycle.
//   Zero latency variance — the whole point of the fixed-offset design.
//   ACHIEVED: 1 cycle (by construction; see the SVA `p_one_cycle` below).
//   Budget row: fpga_top.sv "ITCH decode (fixed-offset extraction) 1 cyc".
//
// RESOURCE ESTIMATE (unmeasured, pre-synthesis — replace with real utilization
//                    per CLAUDE.md §4 once synth has run)
//   LUT ~1,500   FF ~360   BRAM 0   URAM 0   DSP 0
//   Dominated by the ~280-bit-wide output mux over ~10 live case arms, plus the
//   itch_msg_len() length ROM (small LUT ROM, not a BRAM).
//
// BYTE ORDER
//   ITCH is BIG-ENDIAN on the wire. This module is the ONE place the conversion
//   happens (trading_pkg::bswap16/32/64 + the bswap48 wrapper below). Nothing
//   downstream ever sees wire order. Convert once, at the boundary.
//
// BIT LAYOUT OF s_msg
//   Byte N of the ITCH message occupies s_msg[8*N +: 8]; byte 0 (the type code)
//   is in s_msg[7:0]. This matches the byte-0-aligned view produced by the
//   realignment stage upstream (feed-handler-design.md §4).
// =============================================================================
`default_nettype none

module itch_decoder
    import trading_pkg::*;
    import itch_pkg::*;
(
    input  var logic                   clk,
    input  var logic                   rst,        // synchronous, active high

    // ── One whole ITCH message, one beat ─────────────────────────────────────
    /* verilator lint_off UNUSED */
    // Only the low 8*LEN_MAX bits can ever be live; the beat is sized to
    // ITCH_MSG_MAX_BYTES so the interface does not change when Nasdaq adds a
    // longer message type.
    input  var logic [ITCH_MSG_W-1:0]  s_msg,
    /* verilator lint_on UNUSED */
    input  var logic [ITCH_LEN_W-1:0]  s_len,      // declared length from MoldUDP64
    input  var logic                   s_valid,
    input  var cycle_t                 s_rx_cycle, // OUR ingress timestamp

    // ── Book event out (registered) ──────────────────────────────────────────
    // `sym` is left at zero here — symbol_filter fills it in. `locate` is the
    // raw ITCH stock locate and is always populated.
    output var book_evt_t              m_evt,
    output var logic                   m_evt_valid,   // book-affecting or unknown

    // ── Telemetry pulses (registered, aligned with the outputs above) ────────
    output var logic                   m_accept,      // passed length validation
    output var logic                   m_len_err,     // length mismatch -> DROPPED
    output var logic                   m_unknown,     // unknown type -> BOOK_NOP
    output var logic                   m_replace_ref_err, // 'U' new_ref == orig_ref

    // ── Venue-state side-band (registered) ───────────────────────────────────
    output var logic                   m_venue_valid,
    output var logic [7:0]             m_venue_type,  // raw ITCH type byte
    output var locate_t                m_venue_locate,
    output var logic [7:0]             m_venue_code,  // event / action / level byte
    output var price_t                 m_venue_px_lo, // 'J' lower auction collar
    output var price_t                 m_venue_px_hi  // 'J' upper auction collar
);

    // =========================================================================
    // 1. Bit offsets derived from itch_pkg byte offsets
    // =========================================================================
    localparam int unsigned B_TYPE        = 8 * OFF_MSG_TYPE;    //   0
    localparam int unsigned B_LOCATE      = 8 * OFF_LOCATE;      //   8
    localparam int unsigned B_TRACKING    = 8 * OFF_TRACKING;    //  24
    localparam int unsigned B_TIMESTAMP   = 8 * OFF_TIMESTAMP;   //  40

    localparam int unsigned B_A_ORDER_REF = 8 * OFF_A_ORDER_REF; //  88
    localparam int unsigned B_A_SIDE      = 8 * OFF_A_SIDE;      // 152
    localparam int unsigned B_A_SHARES    = 8 * OFF_A_SHARES;    // 160
    localparam int unsigned B_A_PRICE     = 8 * OFF_A_PRICE;     // 256

    localparam int unsigned B_E_ORDER_REF = 8 * OFF_E_ORDER_REF; //  88
    localparam int unsigned B_E_SHARES    = 8 * OFF_E_SHARES;    // 152

    localparam int unsigned B_X_ORDER_REF = 8 * OFF_X_ORDER_REF; //  88
    localparam int unsigned B_X_SHARES    = 8 * OFF_X_SHARES;    // 152

    localparam int unsigned B_D_ORDER_REF = 8 * OFF_D_ORDER_REF; //  88

    localparam int unsigned B_U_ORIG_REF  = 8 * OFF_U_ORIG_REF;  //  88
    localparam int unsigned B_U_NEW_REF   = 8 * OFF_U_NEW_REF;   // 152
    localparam int unsigned B_U_SHARES    = 8 * OFF_U_SHARES;    // 216
    localparam int unsigned B_U_PRICE     = 8 * OFF_U_PRICE;     // 248

    // =========================================================================
    // 2. ⚠️ UNVERIFIED offsets that itch_pkg.sv does not define
    // -------------------------------------------------------------------------
    // These are the non-book message types. They are derived from the published
    // ITCH 5.0 message layouts and are CONSISTENT with the LEN_* totals already
    // in itch_pkg.sv (each layout below sums exactly to the declared length),
    // which is evidence but NOT verification. Confirm against the spec PDF and
    // then move them into itch_pkg.sv so there is one source of truth.
    //
    //  'S' System Event      (12 B): [0]t [1..2]loc [3..4]trk [5..10]ts [11]event
    //  'H' Trading Action    (25 B): ... [11..18]stock [19]state [20]rsvd [21..24]reason
    //  'h' Operational Halt  (21 B): ... [11..18]stock [19]market [20]action
    //  'Y' Reg SHO           (20 B): ... [11..18]stock [19]sho_action
    //  'J' LULD Collar       (35 B): ... [11..18]stock [19..22]ref_px
    //                                    [23..26]upper [27..30]lower [31..34]ext
    //  'K' IPO Quoting       (28 B): ... [11..18]stock [19..22]release_time
    //                                    [23]qualifier [24..27]ipo_px
    //  'W' MWCB Status       (12 B): ... [11]breached_level
    //  'C' Exec w/ Price     (36 B): ... [11..18]ref [19..22]shares [23..30]match
    //                                    [31]printable [32..35]exec_price
    // =========================================================================
    localparam int unsigned OFF_S_EVENT     = 11;   // ⚠️ VERIFY
    localparam int unsigned OFF_H_STATE     = 19;   // ⚠️ VERIFY
    localparam int unsigned OFF_h_ACTION    = 20;   // ⚠️ VERIFY
    localparam int unsigned OFF_Y_ACTION    = 19;   // ⚠️ VERIFY
    localparam int unsigned OFF_J_UPPER     = 23;   // ⚠️ VERIFY
    localparam int unsigned OFF_J_LOWER     = 27;   // ⚠️ VERIFY
    localparam int unsigned OFF_K_QUAL      = 23;   // ⚠️ VERIFY
    localparam int unsigned OFF_W_LEVEL     = 11;   // ⚠️ VERIFY
    localparam int unsigned OFF_C_PRINTABLE = 31;   // ⚠️ VERIFY
    localparam int unsigned OFF_C_PRICE     = 32;   // ⚠️ VERIFY

    localparam int unsigned B_S_EVENT     = 8 * OFF_S_EVENT;
    localparam int unsigned B_H_STATE     = 8 * OFF_H_STATE;
    localparam int unsigned B_h_ACTION    = 8 * OFF_h_ACTION;
    localparam int unsigned B_Y_ACTION    = 8 * OFF_Y_ACTION;
    localparam int unsigned B_J_UPPER     = 8 * OFF_J_UPPER;
    localparam int unsigned B_J_LOWER     = 8 * OFF_J_LOWER;
    localparam int unsigned B_K_QUAL      = 8 * OFF_K_QUAL;
    localparam int unsigned B_W_LEVEL     = 8 * OFF_W_LEVEL;
    localparam int unsigned B_C_PRINTABLE = 8 * OFF_C_PRINTABLE;
    localparam int unsigned B_C_PRICE     = 8 * OFF_C_PRICE;

    // 'C' printable flag encoding. ⚠️ VERIFY.
    localparam logic [7:0] CHAR_PRINTABLE_Y = "Y";

    // =========================================================================
    // 3. bswap48 — the 6-byte ITCH timestamp
    // -------------------------------------------------------------------------
    // trading_pkg exports bswap16/32/64 only. Rather than hand-roll a fourth
    // byte-reverser (a second implementation is a second place to get it
    // wrong), widen to 64 bits with zero padding in the LOW bytes, let the
    // sanctioned bswap64 do the reversal — which moves the padding to the HIGH
    // bytes — and truncate.
    //
    //   d      = {b10,b9,b8,b7,b6,b5}          (b5 = wire MSB, in d[7:0])
    //   {d,0}  = {b10,b9,b8,b7,b6,b5, 0,0}
    //   bswap64= { 0, 0,b5,b6,b7,b8,b9,b10}
    //   [47:0] = {b5,b6,b7,b8,b9,b10}          <- the value, MSB first. ✓
    // =========================================================================
    function automatic ts_ns_t bswap48(input logic [47:0] d);
        return ts_ns_t'(trading_pkg::bswap64({d, 16'h0000}));
    endfunction

    // =========================================================================
    // 4. Common 11-byte prefix — extracted BEFORE and in parallel with dispatch
    // -------------------------------------------------------------------------
    // Every ITCH message begins with the same prefix, so none of this depends
    // on the type. It is pure wiring + byte reversal and sits off the critical
    // path of the type mux entirely.
    //
    //   [0]      Message Type      1 byte
    //   [1..2]   Stock Locate      2 bytes BE   <- the direct index (dense int)
    //   [3..4]   Tracking Number   2 bytes BE
    //   [5..10]  Timestamp         6 bytes BE, ns since midnight ET
    // =========================================================================
    logic [7:0] msg_type;
    locate_t    locate;
    ts_ns_t     exch_ts;

    /* verilator lint_off UNUSED */
    // Extracted for completeness of the invariant prefix and to document its
    // layout. book_evt_t has no field for the Nasdaq-internal tracking number,
    // so it is carried nowhere; synthesis optimises the wires away.
    logic [15:0] tracking;
    /* verilator lint_on UNUSED */

    assign msg_type = s_msg[B_TYPE      +:  8];
    assign locate   = bswap16(s_msg[B_LOCATE    +: 16]);
    assign tracking = bswap16(s_msg[B_TRACKING  +: 16]);
    assign exch_ts  = bswap48(s_msg[B_TIMESTAMP +: 48]);

    // =========================================================================
    // 5. Length validation — declared vs. type-implied
    // -------------------------------------------------------------------------
    // itch_msg_len() returns 0 for a type code it does not know. An unknown
    // type is NOT an error (Nasdaq adds message types); a KNOWN type whose
    // declared length disagrees with the spec length IS an error, and the
    // message is DROPPED. We never guess a length: a wrong length means either
    // a corrupt packet or a spec-version mismatch, and either way the field
    // offsets we are about to use are not trustworthy.
    // =========================================================================
    logic [31:0] exp_len;
    logic        type_known;
    logic        len_sane;      // plausible even for an unknown type
    logic        len_match;
    logic        accept;
    logic        len_err;

    always_comb begin
        exp_len = 32'(itch_msg_len(msg_type));
    end

    assign type_known = (exp_len != 32'd0);
    assign len_sane   = (s_len >= ITCH_LEN_W'(HDR_PREFIX_LEN)) &&
                        (s_len <= ITCH_LEN_W'(ITCH_MSG_MAX_BYTES));
    assign len_match  = (exp_len == 32'(s_len));

    assign accept  = s_valid &&  len_sane && (!type_known || len_match);
    assign len_err = s_valid && (!len_sane || ( type_known && !len_match));

    // =========================================================================
    // 6. Type dispatch — one 8-bit case over constant slices
    // =========================================================================
    book_evt_t   evt_d;
    logic        venue_valid_d;
    logic [7:0]  venue_code_d;
    price_t      venue_lo_d;
    price_t      venue_hi_d;
    logic        repl_err_d;

    always_comb begin
        // ── Defaults: assigned on EVERY path. No latches. ────────────────────
        evt_d.op            = BOOK_NOP;
        evt_d.sym           = '0;          // symbol_filter fills this in
        evt_d.locate        = locate;
        evt_d.side          = SIDE_BUY;
        evt_d.price         = '0;
        evt_d.qty           = '0;
        evt_d.order_ref     = '0;
        evt_d.new_order_ref = '0;
        evt_d.exch_ts       = exch_ts;
        evt_d.rx_cycle      = s_rx_cycle;  // carried through UNCHANGED
        evt_d.printable     = 1'b0;

        venue_valid_d = 1'b0;
        venue_code_d  = 8'h00;
        venue_lo_d    = '0;
        venue_hi_d    = '0;
        repl_err_d    = 1'b0;

        case (msg_type)

            // ── Add Order ('A') and Add Order with MPID ('F') ────────────────
            // 'F' has identical field offsets plus a trailing 4-byte MPID
            // attribution field we do not use. Same arm. ⚠️ VERIFY.
            MSG_ADD_ORDER, MSG_ADD_ORDER_MPID: begin
                evt_d.op        = BOOK_ADD;
                evt_d.order_ref = bswap64(s_msg[B_A_ORDER_REF +: 64]);
                evt_d.side      = (s_msg[B_A_SIDE +: 8] == SIDE_CHAR_BUY)
                                      ? SIDE_BUY : SIDE_SELL;
                evt_d.qty       = bswap32(s_msg[B_A_SHARES +: 32]);
                evt_d.price     = bswap32(s_msg[B_A_PRICE  +: 32]);
            end

            // ── Order Executed ('E') ────────────────────────────────────────
            // Carries EXECUTED SHARES and NO PRICE. The price of the fill is
            // the price of the RESTING ORDER, which lives in the book — the
            // book engine must look it up via order_ref. `price` is left at
            // zero here deliberately; a book that reads evt.price for an 'E'
            // will remove liquidity from a level that does not exist.
            // 'E' executions always print to the tape.
            MSG_ORDER_EXECUTED: begin
                evt_d.op        = BOOK_EXECUTE;
                evt_d.order_ref = bswap64(s_msg[B_E_ORDER_REF +: 64]);
                evt_d.qty       = bswap32(s_msg[B_E_SHARES    +: 32]);
                evt_d.price     = '0;          // see comment above
                evt_d.printable = 1'b1;
            end

            // ── Order Executed With Price ('C') ─────────────────────────────
            // Same book effect as 'E' — remove `qty` from the resting order —
            // but it ALSO carries the price the trade actually executed at,
            // which may differ from the resting order's display price, plus a
            // printable flag (a non-printable print must not move last-price).
            //
            // ⚠️ `price` here is TRADE-PRINT information, NOT a book key. The
            //    book must still remove the shares at the resting order's own
            //    price level, exactly as for 'E'. Using evt.price as the level
            //    key for a 'C' corrupts the book.
            MSG_ORDER_EXEC_PRICE: begin
                evt_d.op        = BOOK_EXECUTE;
                evt_d.order_ref = bswap64(s_msg[B_E_ORDER_REF +: 64]);
                evt_d.qty       = bswap32(s_msg[B_E_SHARES    +: 32]);
                evt_d.price     = bswap32(s_msg[B_C_PRICE     +: 32]);
                evt_d.printable = (s_msg[B_C_PRINTABLE +: 8] == CHAR_PRINTABLE_Y);
            end

            // ── Order Cancel ('X') — partial reduce ─────────────────────────
            MSG_ORDER_CANCEL: begin
                evt_d.op        = BOOK_CANCEL;
                evt_d.order_ref = bswap64(s_msg[B_X_ORDER_REF +: 64]);
                evt_d.qty       = bswap32(s_msg[B_X_SHARES    +: 32]);
            end

            // ── Order Delete ('D') — full remove ────────────────────────────
            MSG_ORDER_DELETE: begin
                evt_d.op        = BOOK_DELETE;
                evt_d.order_ref = bswap64(s_msg[B_D_ORDER_REF +: 64]);
            end

            // ── Order Replace ('U') ─────────────────────────────────────────
            // ⚠️ 'U' IS NOT AN IN-PLACE MODIFY. It removes the ORIGINAL order
            //    reference entirely and creates a NEW one with a new reference,
            //    new shares and new price. Both references are populated here:
            //      order_ref     = the original, to be REMOVED from the map
            //      new_order_ref = the replacement, to be ADDED to the map
            //    A book that keys off order_ref and mutates in place leaks the
            //    original reference forever (it will never be deleted, because
            //    all future messages name the NEW reference) and drifts from
            //    the true book. See the SVA p_replace_distinct below.
            MSG_ORDER_REPLACE: begin
                evt_d.op            = BOOK_REPLACE;
                evt_d.order_ref     = bswap64(s_msg[B_U_ORIG_REF +: 64]);
                evt_d.new_order_ref = bswap64(s_msg[B_U_NEW_REF  +: 64]);
                evt_d.qty           = bswap32(s_msg[B_U_SHARES   +: 32]);
                evt_d.price         = bswap32(s_msg[B_U_PRICE    +: 32]);
                repl_err_d          = (bswap64(s_msg[B_U_NEW_REF  +: 64]) ==
                                       bswap64(s_msg[B_U_ORIG_REF +: 64]));
            end

            // ── Venue-state messages: no book effect, side-band only ────────
            MSG_SYSTEM_EVENT: begin
                venue_valid_d = 1'b1;
                venue_code_d  = s_msg[B_S_EVENT +: 8];
            end

            MSG_TRADING_ACTION: begin
                venue_valid_d = 1'b1;
                venue_code_d  = s_msg[B_H_STATE +: 8];
            end

            MSG_OPERATIONAL_HALT: begin
                venue_valid_d = 1'b1;
                venue_code_d  = s_msg[B_h_ACTION +: 8];
            end

            MSG_REG_SHO: begin
                venue_valid_d = 1'b1;
                venue_code_d  = s_msg[B_Y_ACTION +: 8];
            end

            MSG_LULD_COLLAR: begin
                venue_valid_d = 1'b1;
                venue_hi_d    = bswap32(s_msg[B_J_UPPER +: 32]);
                venue_lo_d    = bswap32(s_msg[B_J_LOWER +: 32]);
            end

            MSG_IPO_QUOTING: begin
                venue_valid_d = 1'b1;
                venue_code_d  = s_msg[B_K_QUAL +: 8];
            end

            MSG_MWCB_STATUS: begin
                venue_valid_d = 1'b1;
                venue_code_d  = s_msg[B_W_LEVEL +: 8];
            end

            MSG_MWCB_DECLINE: begin
                // Three 8-byte decline levels. The fast path does not need the
                // absolute index values — only the breach ('W') matters — so
                // this is counted and otherwise ignored.
                venue_valid_d = 1'b1;
            end

            // Known-but-uninteresting types ('R','L','P','Q','B','I','N') and
            // unknown types both land here. They are told apart by
            // `type_known`, not by this case. Defaults already give BOOK_NOP.
            default: begin
                // no override — defaults stand
            end
        endcase
    end

    // =========================================================================
    // 7. Output registers — 1 cycle, the whole latency of this module
    // -------------------------------------------------------------------------
    // m_evt_valid asserts for book-affecting types AND for unknown types (which
    // carry BOOK_NOP). Known non-book types leave the book path idle entirely
    // and travel only on the venue side-band, which keeps the downstream
    // symbol-filter hit/miss counters meaningful.
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            // Control / valid state: MUST reset.
            m_evt_valid       <= 1'b0;
            m_accept          <= 1'b0;
            m_len_err         <= 1'b0;
            m_unknown         <= 1'b0;
            m_replace_ref_err <= 1'b0;
            m_venue_valid     <= 1'b0;
        end else begin
            m_evt_valid       <= accept && (is_book_msg(msg_type) || !type_known);
            m_accept          <= accept;
            m_len_err         <= len_err;
            m_unknown         <= accept && !type_known;
            m_replace_ref_err <= accept && repl_err_d;
            m_venue_valid     <= accept && venue_valid_d;
        end

        // Datapath: no reset (CLAUDE.md §"do not reset the datapath"). Clock
        // enable on s_valid keeps ~280 FFs quiet between messages.
        if (s_valid) begin
            m_evt          <= evt_d;
            m_venue_type   <= msg_type;
            m_venue_locate <= locate;
            m_venue_code   <= venue_code_d;
            m_venue_px_lo  <= venue_lo_d;
            m_venue_px_hi  <= venue_hi_d;
        end
    end

    // =========================================================================
    // 8. Assertions — simulation only
    // =========================================================================
`ifndef SYNTHESIS

    // Fixed 1-cycle latency, and exactly one outcome per input: either the
    // message was accepted or it was dropped for a length error. Never both,
    // never neither. This is the module's latency contract.
    p_one_cycle: assert property (@(posedge clk) disable iff (rst)
        s_valid |=> (m_accept ^ m_len_err)
    ) else $error("itch_decoder: input did not resolve to exactly one outcome in 1 cycle");

    // The latency measurement baseline must survive the decoder untouched.
    p_rx_cycle_carried: assert property (@(posedge clk) disable iff (rst)
        s_valid |=> (m_evt.rx_cycle == $past(s_rx_cycle))
    ) else $error("itch_decoder: rx_cycle was not carried through unchanged");

    // ⚠️ Order Replace must name two DIFFERENT references. If it does not, the
    //    book cannot both remove the old and insert the new, and the reference
    //    leaks. Counted via m_replace_ref_err as well as asserted here.
    p_replace_distinct: assert property (@(posedge clk) disable iff (rst)
        (m_evt_valid && (m_evt.op == BOOK_REPLACE))
            |-> (m_evt.new_order_ref != m_evt.order_ref)
    ) else $error("itch_decoder: ITCH 'U' with new_order_ref == order_ref — the book will leak this reference");

    // Every book mutation must name a live order reference.
    p_book_has_ref: assert property (@(posedge clk) disable iff (rst)
        (m_evt_valid && (m_evt.op != BOOK_NOP)) |-> (m_evt.order_ref != 64'd0)
    ) else $error("itch_decoder: book op with a zero order reference");

    // A new resting order must have a real price and size.
    p_add_sane: assert property (@(posedge clk) disable iff (rst)
        (m_evt_valid && (m_evt.op == BOOK_ADD))
            |-> ((m_evt.price != 32'd0) && (m_evt.qty != 32'd0))
    ) else $error("itch_decoder: BOOK_ADD with zero price or zero quantity");

    // 'E' carries no price by design — catch an offset regression that starts
    // filling one in.
    p_exec_e_no_price: assert property (@(posedge clk) disable iff (rst)
        (s_valid && (msg_type == MSG_ORDER_EXECUTED)) |=> (m_evt.price == 32'd0)
    ) else $error("itch_decoder: ITCH 'E' produced a non-zero price");

    // The side byte is 'B' or 'S'. Anything else means the offset is wrong, and
    // this decoder would silently call it a sell.
    p_side_char: assert property (@(posedge clk) disable iff (rst)
        (s_valid && ((msg_type == MSG_ADD_ORDER) || (msg_type == MSG_ADD_ORDER_MPID)))
            |-> ((s_msg[B_A_SIDE +: 8] == SIDE_CHAR_BUY) ||
                 (s_msg[B_A_SIDE +: 8] == SIDE_CHAR_SELL))
    ) else $error("itch_decoder: Add Order side byte is neither 'B' nor 'S' — VERIFY OFF_A_SIDE");

    // Unknown types are benign: counted, never a book mutation.
    p_unknown_is_nop: assert property (@(posedge clk) disable iff (rst)
        m_unknown |-> (m_evt_valid && (m_evt.op == BOOK_NOP))
    ) else $error("itch_decoder: unknown message type did not produce BOOK_NOP");

    // A dropped message must produce nothing at all.
    p_len_err_drops: assert property (@(posedge clk) disable iff (rst)
        m_len_err |-> (!m_evt_valid && !m_venue_valid)
    ) else $error("itch_decoder: length-mismatched message was not dropped");

`endif

endmodule : itch_decoder

`default_nettype wire
