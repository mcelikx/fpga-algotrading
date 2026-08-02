// =============================================================================
// ouch_pkg.sv — Nasdaq OUCH 5.0 + SoupBinTCP wire-format constants
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/08-nasdaq/05-ouch-5.0-order-entry.md   (to be written)
//           manuals/03-algotrading/04-order-entry-protocols.md
//           manuals/02-networking/02-ip-udp-tcp-in-hardware.md
//
// THIS IS THE ONLY FILE IN rtl/order/ THAT ENCODES WIRE-FORMAT KNOWLEDGE.
// Every offset, length and type code used by ouch_encoder.sv, soupbin_tx.sv and
// ouch_rx.sv comes from here. That is deliberate: when the spec is verified (or
// when Nasdaq changes it) exactly ONE file needs correcting, and no RTL file
// contains a magic number describing the wire.
//
// =============================================================================
// ⚠️⚠️⚠️  VERIFY BLOCK — READ BEFORE TRUSTING ANY BYTE THIS PACKAGE PRODUCES
// =============================================================================
// The constants below are STRUCTURALLY correct — they describe a fixed-field,
// big-endian, byte-oriented protocol of the OUCH family — but the specific
// values are derived from the publicly documented OUCH 4.2 / SoupBinTCP shapes
// and HAVE NOT been checked against the current Nasdaq OUCH 5.0 specification.
// They are a scaffold, not an authority.
//
// Confirm every item below against the current spec PDFs at
//   https://www.nasdaqtrader.com/Trading/TradingSpecs
// (Nasdaq "OUCH 5.0" and "SoupBinTCP 3.00" documents, plus the port/session
// configuration document for OUR ports) and tick each line off IN THIS FILE
// before any build is pointed at a UAT — let alone a production — endpoint.
//
//   [ ] V1  SoupBinTCP header layout: 2-byte big-endian length + 1-byte type,
//           and whether the length COUNTS the type byte (assumed: yes, so
//           length = payload_len + 1).                       -> SOUP_*
//   [ ] V2  SoupBinTCP packet type letters, both directions. -> SOUP_*
//   [ ] V3  OUCH 5.0 INBOUND message type letters.           -> OUCH_IN_*
//   [ ] V4  OUCH 5.0 OUTBOUND message type letters.          -> OUCH_OUT_*
//   [ ] V5  Enter Order field order, widths, total length.   -> OUCH_O_*
//   [ ] V6  Cancel Order field order, widths, total length.  -> OUCH_X_*
//   [ ] V7  Replace / Modify Order layouts.                  -> OUCH_U_*/OUCH_M_*
//   [ ] V8  Outbound common prefix: is the Order Token really at the SAME
//           offset in every outbound message? The RX parser DEPENDS on this.
//                                                            -> OUCH_OUT_TOKEN_OFF
//   [ ] V9  Outbound Accepted / Executed / Canceled / Rejected / Replaced
//           field offsets.                                   -> OUCH_A_*/E_*/C_*/J_*
//   [ ] V10 Order Token: width (14 bytes assumed), PERMITTED CHARACTER SET,
//           and uniqueness scope. See the token note in §7 below — if the venue
//           requires printable alphanumerics, TOKEN_ASCII_HEX mode is MANDATORY
//           and the token loses 56 of its 112 bits.
//   [ ] V11 Price: 4 bytes with 4 implied decimals, or 8 bytes signed? OUCH 5.0
//           changed price handling relative to 4.2.          -> OUCH_PRICE_LEN
//   [ ] V12 Time In Force encoding (4-byte seconds vs. 1-byte enum).
//   [ ] V13 Display / Capacity / Cross Type / Customer Type code letters.
//   [ ] V14 Whether OUCH 5.0 appends an optional TagValue appendage after the
//           fixed block. If it does, OUCH_ENTER_LEN is a MINIMUM, not a fixed
//           length, and the template must carry its own length (it does — see
//           TMPL_META_LEN_W in ouch_encoder.sv).
//   [ ] V15 Cancel-on-disconnect configuration on OUR ports, in writing.
//
// ⚠️ A wrong offset here does NOT produce an obvious failure. It produces a
//    message the venue rejects, or — far worse — a message the venue ACCEPTS
//    with the wrong price or quantity. Treat every unchecked box as a
//    production blocker.
// =============================================================================
`ifndef OUCH_PKG_SV
`define OUCH_PKG_SV

package ouch_pkg;

    // =========================================================================
    // 1. SoupBinTCP framing
    // =========================================================================
    // Every SoupBinTCP packet, in both directions:
    //
    //   byte  0      1      2      3 ....
    //        ┌──────┬──────┬──────┬──────────────────────────────┐
    //        │ length (BE) │ type │ payload (length-1 bytes)     │
    //        └──────┴──────┴──────┴──────────────────────────────┘
    //          2 bytes       1 B
    //
    // ⚠️ V1: the length field is assumed to COUNT THE TYPE BYTE, so a packet
    //    carrying an N-byte OUCH message has length = N + 1 and occupies
    //    N + 3 bytes on the wire. A Client Heartbeat has length = 1 and
    //    occupies 3 bytes. Confirm against SoupBinTCP 3.00.
    parameter int unsigned SOUP_LEN_OFF   = 0;
    parameter int unsigned SOUP_LEN_LEN   = 2;
    parameter int unsigned SOUP_TYPE_OFF  = 2;
    parameter int unsigned SOUP_HDR_LEN   = 3;   // = SOUP_TYPE_OFF + 1
    parameter int unsigned SOUP_LEN_BIAS  = 1;   // length = payload_len + BIAS

    // Largest SoupBinTCP packet the FAST PATH builds: header + the longest OUCH
    // message it can emit, rounded up to an 8-byte (one AXI-Stream beat)
    // boundary. This is NOT the largest packet SoupBinTCP permits — the host
    // builds anything bigger (Login Request is 49 bytes and never touches the
    // fabric). See OUCH_IN_MAX_LEN in §5 and TX_FRAME_MAX_BYTES in §11.
    parameter int unsigned SOUP_PAY_MAX_BYTES = 72;   // >= SOUP_HDR_LEN + 64

    // ---- Packet types, CLIENT -> SERVER (us -> Nasdaq) ----------------------
    // ⚠️ V2
    parameter logic [7:0] SOUP_LOGIN_REQUEST    = "L";
    parameter logic [7:0] SOUP_UNSEQ_DATA       = "U";  // carries OUCH orders
    parameter logic [7:0] SOUP_CLIENT_HEARTBEAT = "R";
    parameter logic [7:0] SOUP_LOGOUT_REQUEST   = "O";

    // ---- Packet types, SERVER -> CLIENT (Nasdaq -> us) ----------------------
    // ⚠️ V2
    parameter logic [7:0] SOUP_LOGIN_ACCEPTED   = "A";
    parameter logic [7:0] SOUP_LOGIN_REJECTED   = "J";
    parameter logic [7:0] SOUP_SEQ_DATA         = "S";  // carries OUCH acks/fills
    parameter logic [7:0] SOUP_SERVER_HEARTBEAT = "H";
    parameter logic [7:0] SOUP_END_OF_SESSION   = "Z";
    parameter logic [7:0] SOUP_DEBUG            = "+";

    // ---- Login Request / Accepted / Rejected payload shapes -----------------
    // The FPGA NEVER builds or parses these — login and logout are 100% host
    // owned (see §2). They are listed so the RX parser can recognise and SKIP
    // them by length without misinterpreting them as data.
    parameter int unsigned SOUP_LOGIN_REQ_USER_OFF   = 0;
    parameter int unsigned SOUP_LOGIN_REQ_USER_LEN   = 6;
    parameter int unsigned SOUP_LOGIN_REQ_PASS_OFF   = 6;
    parameter int unsigned SOUP_LOGIN_REQ_PASS_LEN   = 10;
    parameter int unsigned SOUP_LOGIN_REQ_SESS_OFF   = 16;
    parameter int unsigned SOUP_LOGIN_REQ_SESS_LEN   = 10;
    parameter int unsigned SOUP_LOGIN_REQ_SEQ_OFF    = 26;
    parameter int unsigned SOUP_LOGIN_REQ_SEQ_LEN    = 20;  // ASCII decimal
    parameter int unsigned SOUP_LOGIN_REQ_PAYLOAD    = 46;

    parameter int unsigned SOUP_LOGIN_ACC_SESS_OFF   = 0;
    parameter int unsigned SOUP_LOGIN_ACC_SESS_LEN   = 10;
    parameter int unsigned SOUP_LOGIN_ACC_SEQ_OFF    = 10;
    parameter int unsigned SOUP_LOGIN_ACC_SEQ_LEN    = 20;  // ASCII decimal
    parameter int unsigned SOUP_LOGIN_ACC_PAYLOAD    = 30;

    parameter int unsigned SOUP_LOGIN_REJ_PAYLOAD    = 1;   // reason code

    // ⚠️ V2: login-reject reason letters.
    parameter logic [7:0] SOUP_REJ_NOT_AUTHORIZED = "A";
    parameter logic [7:0] SOUP_REJ_SESSION_NA     = "S";

    // =========================================================================
    // 2. ⚠️ UNSEQUENCED vs SEQUENCED — and what it means for recovery
    // =========================================================================
    // This asymmetry is the single most important session-level property of
    // SoupBinTCP, and it is why the CPU/FPGA split in this design works.
    //
    //   CLIENT -> SERVER is UNSEQUENCED ("Unsequenced Data", type 'U').
    //     There is no sequence number on what we send. The venue does not
    //     acknowledge our packets at the Soup layer at all. Ordering and
    //     delivery are TCP's problem, and TCP's alone.
    //
    //     CONSEQUENCE 1: there is no Soup-level retransmission for outbound
    //     traffic. If the TCP connection dies with bytes unacknowledged, those
    //     orders are in an UNKNOWN state — they may or may not have reached the
    //     matching engine. There is no protocol mechanism to find out. The only
    //     recovery is to reconnect and read the venue's own view (the sequenced
    //     stream, plus a drop-copy / OUCH "order state" query if available).
    //
    //     CONSEQUENCE 2: this is exactly why tcp_tx_lite.sv can be as thin as
    //     it is. There is nothing to replay at the Soup layer, so the FPGA does
    //     not need a replay buffer — but it also means the FPGA MUST hand the
    //     host the exact bytes and sequence numbers it emitted, because that is
    //     the ONLY record of what was sent.
    //
    //   SERVER -> CLIENT is SEQUENCED ("Sequenced Data", type 'S').
    //     Every inbound data packet has an implicit sequence number: the first
    //     is the number given in Login Accepted, and it increments by one per
    //     Sequenced Data packet (heartbeats and Debug do NOT advance it).
    //
    //     CONSEQUENCE 3: inbound loss IS recoverable. On reconnect the client
    //     logs in requesting the next sequence number it needs and the venue
    //     replays from there. That recovery is a HOST function — it involves a
    //     new TCP connection and a Login Request, neither of which the FPGA
    //     does.
    //
    //     CONSEQUENCE 4: ouch_rx.sv MUST count Sequenced Data packets and
    //     compare against the host's expectation. A gap in the sequenced stream
    //     means the FPGA's position and credit view are wrong, and the correct
    //     hardware response is to stop trading and let the host reconcile —
    //     NOT to guess.
    //
    // ⚠️ Heartbeats: both sides send them, and either side may drop the session
    //    on heartbeat timeout. The FPGA owns ONLY the steady-state client
    //    heartbeat (soupbin_tx.sv) so that a quiet market cannot kill the
    //    session while the host is busy. Everything else — Login Request,
    //    Logout Request, sequence negotiation, End of Session handling — is
    //    host-owned. See soupbin_tx.sv.
    //
    // ⚠️ V15: cancel-on-disconnect. Both settings are dangerous in different
    //    ways (see manuals/03-algotrading/04-order-entry-protocols.md §8).
    //    Get the setting for OUR ports in writing.
    // =========================================================================

    // =========================================================================
    // 3. OUCH message type codes
    // =========================================================================
    // ⚠️ NOTE THE DIRECTIONAL COLLISION: 'U' is "Replace Order" inbound and
    //    "Order Replaced" outbound; 'M' is "Modify Order" inbound and "Order
    //    Modified" outbound. Direction disambiguates them and nothing else
    //    does. Never write a single flat decode table over both directions.

    // ---- INBOUND (client -> server): what WE send. ⚠️ V3 --------------------
    parameter logic [7:0] OUCH_IN_ENTER_ORDER   = "O";
    parameter logic [7:0] OUCH_IN_REPLACE_ORDER = "U";
    parameter logic [7:0] OUCH_IN_CANCEL_ORDER  = "X";
    parameter logic [7:0] OUCH_IN_MODIFY_ORDER  = "M";

    // ---- OUTBOUND (server -> client): what WE receive. ⚠️ V4 ----------------
    parameter logic [7:0] OUCH_OUT_SYSTEM_EVENT   = "S";
    parameter logic [7:0] OUCH_OUT_ACCEPTED       = "A";
    parameter logic [7:0] OUCH_OUT_REPLACED       = "U";
    parameter logic [7:0] OUCH_OUT_CANCELED       = "C";
    parameter logic [7:0] OUCH_OUT_AIQ_CANCELED   = "D";
    parameter logic [7:0] OUCH_OUT_EXECUTED       = "E";
    parameter logic [7:0] OUCH_OUT_BROKEN_TRADE   = "B";
    parameter logic [7:0] OUCH_OUT_REJECTED       = "J";
    parameter logic [7:0] OUCH_OUT_CANCEL_PENDING = "P";
    parameter logic [7:0] OUCH_OUT_CANCEL_REJECT  = "I";
    parameter logic [7:0] OUCH_OUT_PRIORITY_UPD   = "T";
    parameter logic [7:0] OUCH_OUT_ORDER_MODIFIED = "M";
    parameter logic [7:0] OUCH_OUT_RESTATED       = "R";
    parameter logic [7:0] OUCH_OUT_PRICE_CORRECT  = "K";

    // Dense index for the per-type counter array in ouch_rx.sv. A counter per
    // message type is CLAUDE.md §5.7: a spike in any of these is operational
    // information, and "messages received" without a breakdown is useless.
    parameter int unsigned N_OUT_MSG_TYPES = 16;
    typedef enum logic [3:0] {
        OMI_UNKNOWN        = 4'd0,
        OMI_SYSTEM_EVENT   = 4'd1,
        OMI_ACCEPTED       = 4'd2,
        OMI_REPLACED       = 4'd3,
        OMI_CANCELED       = 4'd4,
        OMI_AIQ_CANCELED   = 4'd5,
        OMI_EXECUTED       = 4'd6,
        OMI_BROKEN_TRADE   = 4'd7,
        OMI_REJECTED       = 4'd8,
        OMI_CANCEL_PENDING = 4'd9,
        OMI_CANCEL_REJECT  = 4'd10,
        OMI_PRIORITY_UPD   = 4'd11,
        OMI_ORDER_MODIFIED = 4'd12,
        OMI_RESTATED       = 4'd13,
        OMI_PRICE_CORRECT  = 4'd14,
        OMI_RSVD15         = 4'd15
    } out_msg_idx_e;

    // =========================================================================
    // 4. Common field widths
    // =========================================================================
    // ⚠️ V10 / V11
    parameter int unsigned OUCH_TOKEN_LEN   = 14;  // Order Token, bytes
    parameter int unsigned OUCH_STOCK_LEN   = 8;   // space-padded ASCII
    parameter int unsigned OUCH_PRICE_LEN   = 4;   // 4 implied decimals
    parameter int unsigned OUCH_SHARES_LEN  = 4;
    parameter int unsigned OUCH_FIRM_LEN    = 4;
    parameter int unsigned OUCH_TIF_LEN     = 4;
    parameter int unsigned OUCH_TS_LEN      = 8;   // outbound timestamp, ns

    // =========================================================================
    // 5. INBOUND message layouts (what ouch_encoder.sv splices into)
    // =========================================================================
    // ⚠️ EVERY OFFSET BELOW IS AN ASSUMPTION (V5/V6/V7). The RTL never uses a
    //    literal; it uses these names. Correcting the spec = editing this file.
    //
    // ---- Enter Order ('O') -------------------------------------------------
    //  off len field                       constant per symbol?   spliced?
    //   0   1  Message Type = 'O'          yes                    no
    //   1  14  Order Token                 no                     YES
    //  15   1  Buy/Sell Indicator          no                     YES
    //  16   4  Shares                      no                     YES
    //  20   8  Stock (space padded)        YES  <- the whole point of templating
    //  28   4  Price                       no                     YES
    //  32   4  Time In Force               yes                    no
    //  36   4  Firm                        yes                    no
    //  40   1  Display                     no                     YES (post-only)
    //  41   1  Capacity                    yes                    no
    //  42   1  Intermarket Sweep Elig.     yes                    no
    //  43   4  Minimum Quantity            yes                    no
    //  47   1  Cross Type                  yes                    no
    //  48   1  Customer Type               yes                    no
    //  ------------------------------------------------------------------
    //  49 bytes. 5 spliced fields, 24 spliced bytes. 25 of 49 bytes constant.
    parameter int unsigned OUCH_O_TYPE_OFF    = 0;
    parameter int unsigned OUCH_O_TOKEN_OFF   = 1;
    parameter int unsigned OUCH_O_SIDE_OFF    = 15;
    parameter int unsigned OUCH_O_SHARES_OFF  = 16;
    parameter int unsigned OUCH_O_STOCK_OFF   = 20;
    parameter int unsigned OUCH_O_PRICE_OFF   = 28;
    parameter int unsigned OUCH_O_TIF_OFF     = 32;
    parameter int unsigned OUCH_O_FIRM_OFF    = 36;
    parameter int unsigned OUCH_O_DISPLAY_OFF = 40;
    parameter int unsigned OUCH_O_CAPACITY_OFF= 41;
    parameter int unsigned OUCH_O_ISE_OFF     = 42;
    parameter int unsigned OUCH_O_MINQTY_OFF  = 43;
    parameter int unsigned OUCH_O_CROSSTY_OFF = 47;
    parameter int unsigned OUCH_O_CUSTTY_OFF  = 48;
    parameter int unsigned OUCH_ENTER_LEN     = 49;

    // ---- Cancel Order ('X') ------------------------------------------------
    //  off len field
    //   0   1  Message Type = 'X'
    //   1  14  Order Token          <- the ONLY spliced field
    //  15   4  Shares (target remaining quantity; 0 = cancel the whole order)
    //  ------------------------------------------------------------------
    //  19 bytes. ONE spliced field. This is why the cancel path is the
    //  cheapest, shallowest, and (should be) the fastest path in the block.
    parameter int unsigned OUCH_X_TYPE_OFF   = 0;
    parameter int unsigned OUCH_X_TOKEN_OFF  = 1;
    parameter int unsigned OUCH_X_SHARES_OFF = 15;
    parameter int unsigned OUCH_CANCEL_LEN   = 19;

    // ---- Replace Order ('U') -----------------------------------------------
    // Not emitted by the fast path in this build. Listed for completeness and
    // so the host can build templates for it later.
    // ⚠️ Replace is NOT a cheap "modify" — it is a cancel plus a new order with
    //    a NEW token, and it LOSES QUEUE PRIORITY. For a passive strategy the
    //    cancel path is almost always what you actually want.
    parameter int unsigned OUCH_U_TYPE_OFF     = 0;
    parameter int unsigned OUCH_U_EXIST_TOK_OFF= 1;   // token being replaced
    parameter int unsigned OUCH_U_NEW_TOK_OFF  = 15;  // new token
    parameter int unsigned OUCH_U_SHARES_OFF   = 29;
    parameter int unsigned OUCH_U_PRICE_OFF    = 33;
    parameter int unsigned OUCH_U_TIF_OFF      = 37;
    parameter int unsigned OUCH_U_DISPLAY_OFF  = 41;
    parameter int unsigned OUCH_U_MINQTY_OFF   = 42;
    parameter int unsigned OUCH_REPLACE_LEN    = 46;

    // ---- Modify Order ('M') ------------------------------------------------
    // Side / quantity-down modification that (unlike Replace) may preserve
    // priority for a size DECREASE. ⚠️ V7: confirm the priority rules — they
    // are a strategy-relevant property, not just a wire-format detail.
    parameter int unsigned OUCH_M_TYPE_OFF   = 0;
    parameter int unsigned OUCH_M_TOKEN_OFF  = 1;
    parameter int unsigned OUCH_M_SIDE_OFF   = 15;
    parameter int unsigned OUCH_M_SHARES_OFF = 16;
    parameter int unsigned OUCH_MODIFY_LEN   = 20;

    // Longest inbound message we will ever build. Sizes the template BRAM row.
    parameter int unsigned OUCH_IN_MAX_LEN   = 64;

    // =========================================================================
    // 6. OUTBOUND message layouts (what ouch_rx.sv parses)
    // =========================================================================
    // ⚠️ V8 — THE LOAD-BEARING ASSUMPTION OF THE WHOLE RX PATH:
    //    every outbound message begins  [type:1][timestamp:8][order token:14]
    //    so the Order Token is ALWAYS at offset 9. ouch_rx.sv extracts the
    //    token before it has finished classifying the message type. If this is
    //    not true in OUCH 5.0, ouch_rx.sv needs a per-type token offset table
    //    (a small change — the offset is already a named parameter — but it
    //    MUST be made deliberately, not discovered in production).
    parameter int unsigned OUCH_OUT_TYPE_OFF  = 0;
    parameter int unsigned OUCH_OUT_TS_OFF    = 1;
    parameter int unsigned OUCH_OUT_TOKEN_OFF = 9;
    parameter int unsigned OUCH_OUT_HDR_LEN   = 23;  // = TOKEN_OFF + TOKEN_LEN

    // ---- Order Accepted ('A') ⚠️ V9 ----------------------------------------
    parameter int unsigned OUCH_A_SIDE_OFF    = 23;
    parameter int unsigned OUCH_A_SHARES_OFF  = 24;
    parameter int unsigned OUCH_A_STOCK_OFF   = 28;
    parameter int unsigned OUCH_A_PRICE_OFF   = 36;
    parameter int unsigned OUCH_A_ORDREF_OFF  = 49;
    parameter int unsigned OUCH_ACCEPTED_LEN  = 66;

    // ---- Order Executed ('E') ⚠️ V9 ----------------------------------------
    // ⚠️ THE EXECUTED MESSAGE DOES NOT CARRY A SIDE. That is why this design
    //    stamps the side INTO THE ORDER TOKEN (§7). Without it, decoding a fill
    //    requires an in-flight order table — state the fast path should not own.
    parameter int unsigned OUCH_E_SHARES_OFF  = 23;   // executed shares
    parameter int unsigned OUCH_E_PRICE_OFF   = 27;   // execution price
    parameter int unsigned OUCH_E_LIQFLAG_OFF = 31;
    parameter int unsigned OUCH_E_MATCHNO_OFF = 32;
    parameter int unsigned OUCH_EXECUTED_LEN  = 40;

    // ---- Order Canceled ('C') / AIQ Canceled ('D') ⚠️ V9 -------------------
    parameter int unsigned OUCH_C_SHARES_OFF  = 23;   // decrement shares
    parameter int unsigned OUCH_C_REASON_OFF  = 27;
    parameter int unsigned OUCH_CANCELED_LEN  = 28;

    // ---- Order Rejected ('J') ⚠️ V9 ----------------------------------------
    parameter int unsigned OUCH_J_REASON_OFF  = 23;
    parameter int unsigned OUCH_REJECTED_LEN  = 24;

    // ---- Order Replaced ('U') ⚠️ V9 ----------------------------------------
    // Carries the NEW token in the common prefix and the PREVIOUS token at the
    // tail. The FPGA uses only the new token; the host reconciles both.
    parameter int unsigned OUCH_RU_SIDE_OFF   = 23;
    parameter int unsigned OUCH_RU_SHARES_OFF = 24;
    parameter int unsigned OUCH_RU_PRICE_OFF  = 36;
    parameter int unsigned OUCH_RU_PREVTOK_OFF= 65;
    parameter int unsigned OUCH_REPLACED_LEN  = 79;

    parameter int unsigned OUCH_OUT_MAX_LEN   = 96;

    // =========================================================================
    // 7. Field encodings
    // =========================================================================
    // ⚠️ V13
    parameter logic [7:0] OUCH_SIDE_BUY          = "B";
    parameter logic [7:0] OUCH_SIDE_SELL         = "S";
    parameter logic [7:0] OUCH_SIDE_SELL_SHORT   = "T";
    parameter logic [7:0] OUCH_SIDE_SELL_SHORT_X = "E";  // short exempt

    parameter logic [7:0] OUCH_DISP_ANONYMOUS    = "Y";
    parameter logic [7:0] OUCH_DISP_ATTRIBUTABLE = "A";
    parameter logic [7:0] OUCH_DISP_NON_DISPLAY  = "N";
    parameter logic [7:0] OUCH_DISP_POST_ONLY    = "P";
    parameter logic [7:0] OUCH_DISP_IMBAL_ONLY   = "I";
    parameter logic [7:0] OUCH_DISP_MIDPOINT_PEG = "M";

    parameter logic [7:0] OUCH_CAP_AGENCY        = "A";
    parameter logic [7:0] OUCH_CAP_PRINCIPAL     = "P";
    parameter logic [7:0] OUCH_CAP_RISKLESS      = "R";
    parameter logic [7:0] OUCH_CAP_OTHER         = "O";

    parameter logic [7:0] OUCH_CROSS_NONE        = "N";
    parameter logic [7:0] OUCH_CROSS_OPENING     = "O";
    parameter logic [7:0] OUCH_CROSS_CLOSING     = "C";
    parameter logic [7:0] OUCH_CROSS_HALT_IPO    = "H";

    // ⚠️ V12: Time In Force. 4-byte big-endian seconds in OUCH 4.2, with two
    //    magic values. Constant per template, so the fast path never touches it.
    parameter logic [31:0] OUCH_TIF_IOC = 32'd0;
    parameter logic [31:0] OUCH_TIF_DAY = 32'd99998;
    parameter logic [31:0] OUCH_TIF_GTX = 32'd99999;

    // =========================================================================
    // 8. Order token wire rendering
    // =========================================================================
    // trading_pkg::order_token_t is 112 bits = exactly 14 bytes, which is
    // exactly OUCH_TOKEN_LEN. That is convenient but it is NOT automatically
    // legal on the wire.
    //
    // ⚠️ V10: if the venue constrains the Order Token to printable alphanumeric
    //    characters, raw 112-bit binary CANNOT be sent. The encoder therefore
    //    supports two modes, selected by the TOKEN_ASCII_HEX parameter:
    //
    //    TOKEN_ASCII_HEX = 1  (DEFAULT — the spec-safe choice)
    //      14 ASCII hex characters carry 14 x 4 = 56 bits. Hex is chosen because
    //      nibble -> ASCII is a purely combinational 4-bit LUT; base-36 or
    //      base-10 rendering needs division, which is banned (CLAUDE.md §5.3).
    //      The 112-bit struct is COMPRESSED to 56 bits as follows:
    //
    //        bit 55..48  magic     (8)  <- order_token_t.magic[7:0] only
    //        bit 47      side      (1)  <- stamped by the ENCODER, see below
    //        bit 46      post_only (1)  <- stamped by the ENCODER
    //        bit 45..42  strat_id  (4)
    //        bit 41..30  sym       (12)
    //        bit 29..0   counter   (30) <- 1.07e9 orders/session
    //
    //      ⚠️ THE COST: magic drops 16 -> 8 bits and counter drops 48 -> 30.
    //         An 8-bit magic still detects a stale prior-session token with
    //         255/256 probability per event, which is adequate ONLY because it
    //         is backed by the host's authoritative reconciliation. A 30-bit
    //         counter cannot wrap in a session at any plausible rate, but the
    //         wrap guard in ouch_encoder.sv enforces that rather than assuming.
    //
    //    TOKEN_ASCII_HEX = 0
    //      All 112 bits go on the wire big-endian, unmodified except for the
    //      side/post_only stamp. Use ONLY if V10 confirms an 8-bit-clean field.
    //
    // ⚠️ THE SIDE STAMP. OUCH's Order Executed message carries no side. To
    //    decode a fill without an in-flight order table, the encoder OVERWRITES
    //    two bits of order_token_t.rsvd with {post_only, side} before the token
    //    goes on the wire, and ouch_rx recovers them. The risk gate MUST leave
    //    rsvd zero; ouch_encoder.sv asserts that it does.
    parameter int unsigned TOKEN_HEX_BITS      = 56;
    parameter int unsigned TOKEN_HEX_MAGIC_W   = 8;
    parameter int unsigned TOKEN_HEX_STRAT_W   = 4;
    parameter int unsigned TOKEN_HEX_SYM_W     = 12;
    parameter int unsigned TOKEN_HEX_CNT_W     = 30;
    parameter int unsigned TOKEN_RSVD_SIDE_BIT = 0;
    parameter int unsigned TOKEN_RSVD_POST_BIT = 1;

    // Counter high-water mark. Passing it refuses further orders and alarms —
    // a wrapped token duplicates a live order's identifier and produces
    // permanently unattributable fills. See 04-order-entry-protocols.md §7.
    parameter logic [29:0] TOKEN_CNT_HIGH_WATER = 30'h3F00_0000;

    // Nibble -> ASCII hex. Pure combinational LUT, zero cycles.
    function automatic logic [7:0] hex_char(input logic [3:0] n);
        return (n <= 4'd9) ? (8'h30 + {4'h0, n})          // '0'..'9'
                           : (8'h41 + {4'h0, n} - 8'd10); // 'A'..'F'
    endfunction

    // ASCII hex -> nibble. `ok` is low for any character outside [0-9A-Fa-f];
    // ouch_rx counts those and refuses to act on the token.
    function automatic logic [4:0] hex_val(input logic [7:0] c);
        // [4] = ok, [3:0] = value
        if      (c >= 8'h30 && c <= 8'h39) return {1'b1, c[3:0]};              // 0-9
        else if (c >= 8'h41 && c <= 8'h46) return {1'b1, (c[3:0] + 4'd9)};     // A-F
        else if (c >= 8'h61 && c <= 8'h66) return {1'b1, (c[3:0] + 4'd9)};     // a-f
        else                               return 5'b0_0000;
    endfunction

    // =========================================================================
    // 9. One's-complement checksum arithmetic (RFC 1071)
    // =========================================================================
    // ⚠️ THE MOST DANGEROUS ARITHMETIC IN THIS DIRECTORY. A wrong checksum does
    //    NOT look like a bug: the venue's stack silently discards the segment,
    //    TCP retransmits from the host, and the symptom is "occasional latency
    //    spikes". Read manuals/02-networking/02-ip-udp-tcp-in-hardware.md §4.
    //
    // Accumulator width: 16 bits of value + 10 bits of carry headroom. We
    // accumulate at most ~40 words anywhere in this design; 10 bits allows
    // 1023. Keeping the sum UNFOLDED all the way from ouch_encoder to
    // tcp_tx_lite is deliberate: folding early would repeatedly hit the
    // 0x0000/0xFFFF equivalence and invite exactly the class of off-by-one the
    // RFC 1624 erratum is about. We fold ONCE, at the end, in tcp_tx_lite.
    parameter int unsigned CSUM_ACC_W = 26;
    typedef logic [CSUM_ACC_W-1:0] csum_acc_t;

    // Two folds are PROVABLY sufficient for a 26-bit accumulator:
    //   f0 = acc[15:0] + acc[25:16]  <=  0xFFFF + 0x3FF = 0x103FE   (17 bits)
    //   f1 = f0[15:0] + f0[16]       <=  0x03FE + 1     = 0x03FF    (no carry)
    // The f1 carry-out is therefore always 0 — asserted in tcp_tx_lite.sv.
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [15:0] csum_fold(input csum_acc_t acc);
        logic [16:0] f0;
        logic [16:0] f1;   // f1[16] is provably always 0 -- see the proof above
        f0 = {1'b0, acc[15:0]} + {7'd0, acc[CSUM_ACC_W-1:16]};
        f1 = {1'b0, f0[15:0]} + {16'd0, f0[16]};
        return f1[15:0];
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // Contribution of a SINGLE byte at byte offset `off` within the checksummed
    // region, to the 16-bit one's-complement sum.
    //
    // ⚠️ THIS IS THE OFF-BY-ONE. A byte at an EVEN offset is the HIGH half of
    //    its 16-bit word; at an ODD offset it is the LOW half. Getting this
    //    backwards produces a checksum that is wrong for every message whose
    //    patched fields sit at odd offsets — which, in this design, is ALL of
    //    them, because the SoupBinTCP header is 3 bytes long and therefore
    //    FLIPS THE PARITY of every OUCH field relative to the TCP payload.
    //    OUCH offset k lives at TCP-payload offset (SOUP_HDR_LEN + k) = k + 3.
    //    Always pass the PAYLOAD offset here, never the OUCH offset.
    function automatic logic [15:0] csum_byte_at(input int unsigned off,
                                                 input logic [7:0]  b);
        logic [31:0] o;
        o = 32'(off);
        return o[0] ? {8'h00, b} : {b, 8'h00};
    endfunction

    // =========================================================================
    // 10. Decode helpers
    // =========================================================================
    // Expected total length of an OUTBOUND message, or 0 if the type is not
    // recognised. ouch_rx uses this to skip cleanly: an unknown type is NOT an
    // error (Nasdaq adds message types) but it MUST be skipped by the
    // SoupBinTCP length, never by a guess about OUCH content.
    function automatic int unsigned ouch_out_len(input logic [7:0] t);
        case (t)
            OUCH_OUT_ACCEPTED     : return OUCH_ACCEPTED_LEN;
            OUCH_OUT_EXECUTED     : return OUCH_EXECUTED_LEN;
            OUCH_OUT_CANCELED     : return OUCH_CANCELED_LEN;
            OUCH_OUT_AIQ_CANCELED : return OUCH_CANCELED_LEN;
            OUCH_OUT_REJECTED     : return OUCH_REJECTED_LEN;
            OUCH_OUT_REPLACED     : return OUCH_REPLACED_LEN;
            default               : return 0;
        endcase
    endfunction

    // Map an outbound type letter to its dense counter index.
    function automatic out_msg_idx_e ouch_out_idx(input logic [7:0] t);
        case (t)
            OUCH_OUT_SYSTEM_EVENT  : return OMI_SYSTEM_EVENT;
            OUCH_OUT_ACCEPTED      : return OMI_ACCEPTED;
            OUCH_OUT_REPLACED      : return OMI_REPLACED;
            OUCH_OUT_CANCELED      : return OMI_CANCELED;
            OUCH_OUT_AIQ_CANCELED  : return OMI_AIQ_CANCELED;
            OUCH_OUT_EXECUTED      : return OMI_EXECUTED;
            OUCH_OUT_BROKEN_TRADE  : return OMI_BROKEN_TRADE;
            OUCH_OUT_REJECTED      : return OMI_REJECTED;
            OUCH_OUT_CANCEL_PENDING: return OMI_CANCEL_PENDING;
            OUCH_OUT_CANCEL_REJECT : return OMI_CANCEL_REJECT;
            OUCH_OUT_PRIORITY_UPD  : return OMI_PRIORITY_UPD;
            OUCH_OUT_ORDER_MODIFIED: return OMI_ORDER_MODIFIED;
            OUCH_OUT_RESTATED      : return OMI_RESTATED;
            OUCH_OUT_PRICE_CORRECT : return OMI_PRICE_CORRECT;
            default                : return OMI_UNKNOWN;
        endcase
    endfunction

    // Terminal for credit accounting: the order is (believed) no longer live.
    //
    // ⚠️ EXECUTED IS ONLY *CONDITIONALLY* TERMINAL. A partial fill leaves the
    //    order live, and the OUCH Executed message does not report the leaves
    //    quantity. Treating Executed as terminal therefore returns credit
    //    EARLY for partially-filled orders. That is a deliberate, bounded
    //    approximation — see credit_mgr.sv, which saturates at MAX_IN_FLIGHT
    //    so an over-return can never manufacture credit, and the host's
    //    explicit credit_return is the correction channel. The policy is
    //    switchable via ouch_rx.sv's CREDIT_RETURN_ON_EXEC parameter.
    function automatic logic ouch_out_is_terminal(input logic [7:0] t,
                                                  input logic       exec_terminal);
        case (t)
            OUCH_OUT_CANCELED     : return 1'b1;
            OUCH_OUT_AIQ_CANCELED : return 1'b1;
            OUCH_OUT_REJECTED     : return 1'b1;
            OUCH_OUT_BROKEN_TRADE : return 1'b1;
            OUCH_OUT_EXECUTED     : return exec_terminal;
            default               : return 1'b0;
        endcase
    endfunction

    // =========================================================================
    // 11. Ethernet / IPv4 / TCP header geometry (used only by tcp_tx_lite.sv)
    // =========================================================================
    // Untagged Ethernet II + IPv4 (IHL=5, no options) + TCP (no options).
    // ⚠️ Fixed slices only. A VLAN tag or an IP option shifts everything and is
    //    a change-control event, not something the fabric absorbs. See
    //    manuals/02-networking/02-ip-udp-tcp-in-hardware.md §2.
    parameter int unsigned ETH_HDR_LEN   = 14;
    parameter int unsigned IP4_HDR_LEN   = 20;
    parameter int unsigned TCP_HDR_LEN   = 20;
    parameter int unsigned FRAME_HDR_LEN = ETH_HDR_LEN + IP4_HDR_LEN + TCP_HDR_LEN; // 54

    parameter int unsigned ETH_DMAC_OFF   = 0;
    parameter int unsigned ETH_SMAC_OFF   = 6;
    parameter int unsigned ETH_TYPE_OFF   = 12;
    parameter logic [15:0] ETHERTYPE_IPV4 = 16'h0800;

    parameter int unsigned IP_VERIHL_OFF  = 14;
    parameter int unsigned IP_DSCP_OFF    = 15;
    parameter int unsigned IP_TOTLEN_OFF  = 16;   // PATCHED
    parameter int unsigned IP_ID_OFF      = 18;   // PATCHED
    parameter int unsigned IP_FLAGS_OFF   = 20;
    parameter int unsigned IP_TTL_OFF     = 22;
    parameter int unsigned IP_PROTO_OFF   = 23;
    parameter int unsigned IP_CSUM_OFF    = 24;   // PATCHED
    parameter int unsigned IP_SRC_OFF     = 26;
    parameter int unsigned IP_DST_OFF     = 30;
    parameter logic [7:0]  IP_VERIHL_V4   = 8'h45;
    parameter logic [15:0] IP_FLAGS_DF    = 16'h4000;
    parameter logic [7:0]  IP_PROTO_TCP   = 8'd6;

    parameter int unsigned TCP_SPORT_OFF  = 34;
    parameter int unsigned TCP_DPORT_OFF  = 36;
    parameter int unsigned TCP_SEQ_OFF    = 38;   // PATCHED
    parameter int unsigned TCP_ACK_OFF    = 42;   // PATCHED
    parameter int unsigned TCP_OFFRSV_OFF = 46;
    parameter int unsigned TCP_FLAGS_OFF  = 47;
    parameter int unsigned TCP_WIN_OFF    = 48;
    parameter int unsigned TCP_CSUM_OFF   = 50;   // PATCHED
    parameter int unsigned TCP_URG_OFF    = 52;
    parameter logic [7:0]  TCP_OFFRSV_5   = 8'h50;  // data offset = 5 words
    // PSH|ACK. PSH is mandatory: a delayed-ACK / Nagle interaction on an order
    // session is a 40 ms catastrophe hiding in a default.
    parameter logic [7:0]  TCP_FLAG_ACK   = 8'h10;
    parameter logic [7:0]  TCP_FLAG_PSH   = 8'h08;
    parameter logic [7:0]  TCP_FLAG_RST   = 8'h04;
    parameter logic [7:0]  TCP_FLAG_SYN   = 8'h02;
    parameter logic [7:0]  TCP_FLAG_FIN   = 8'h01;
    parameter logic [7:0]  TCP_FLAGS_DATA = 8'h18;  // PSH|ACK

    // ---- The host-written TCP session record --------------------------------
    // fpga_top.sv gives the gateway a WRITE-DATA port with NO ADDRESS
    // (cfg_session_wr / cfg_session_data). The record is therefore written as a
    // fixed-length burst of 32-bit words into an auto-incrementing pointer.
    // Word 0 doubles as a resynchronisation escape: ANY write whose data equals
    // SESSION_MAGIC restarts the record at word 1.
    //
    // ⚠️ HOST CONSTRAINT: no other word of the record may equal SESSION_MAGIC.
    //    This is trivially satisfiable (bias or byte-swap a colliding value) but
    //    it IS a constraint, and order_gateway.sv counts a magic seen at a
    //    non-zero pointer as an error rather than silently accepting it.
    parameter logic [31:0] SESSION_MAGIC = 32'h4F55_4348;   // "OUCH"
    parameter int unsigned SESSION_WORDS = 16;

    // Word map — see order_gateway.sv for the authoritative decode.
    parameter int unsigned SW_MAGIC   = 0;
    parameter int unsigned SW_DMAC_HI = 1;   // dmac[47:16]
    parameter int unsigned SW_MAC_MID = 2;   // {dmac[15:0], smac[47:32]}
    parameter int unsigned SW_SMAC_LO = 3;   // smac[31:0]
    parameter int unsigned SW_SIP     = 4;
    parameter int unsigned SW_DIP     = 5;
    parameter int unsigned SW_PORTS   = 6;   // {sport, dport}
    parameter int unsigned SW_WTD     = 7;   // {win, ttl, dscp}
    parameter int unsigned SW_CSUM    = 8;   // {ip_csum_const, tcp_csum_const}
    parameter int unsigned SW_SND_NXT = 9;   // TCP sequence resync value
    parameter int unsigned SW_RCV_NXT = 10;  // TCP ack resync value
    parameter int unsigned SW_HB      = 11;  // heartbeat interval, core cycles
    parameter int unsigned SW_EPOCH   = 12;  // {epoch[15:0], 8'b0, wscale[3:0], flags[3:0]}
    parameter int unsigned SW_WDOG    = 13;  // inbound-silence watchdog, core cycles
    parameter int unsigned SW_TOKMAG  = 14;  // {token_magic[15:0], 16'b0}
    parameter int unsigned SW_COMMIT  = 15;  // write latches shadow -> live

    parameter int unsigned SF_ARM       = 0; // flags[0]
    parameter int unsigned SF_HB_EN     = 1; // flags[1]
    parameter int unsigned SF_CLR_DISARM= 2; // flags[2] clear the hardware disarm latch
    parameter int unsigned SF_RSVD3     = 3;

    // The live session register set handed to tcp_tx_lite.sv and ouch_rx.sv.
    typedef struct packed {
        logic [47:0] dmac;            // venue gateway MAC (static ARP, host resolved)
        logic [47:0] smac;
        logic [31:0] sip;
        logic [31:0] dip;
        logic [15:0] sport;
        logic [15:0] dport;
        logic [15:0] win;             // our advertised receive window
        logic [7:0]  ttl;
        logic [7:0]  dscp;
        logic [15:0] ip_csum_const;   // host-precomputed partial IP header sum
        logic [15:0] tcp_csum_const;  // host-precomputed pseudo-header + const TCP words
        logic [15:0] epoch;           // session generation; stale template guard
        logic [3:0]  wscale;          // peer's window scale factor
        logic        armed;           // FPGA may transmit
        logic        hb_en;
    } tcp_sess_t;

    // Modular ("wrapping") TCP sequence comparison, RFC 9293 §3.4. Never use a
    // plain unsigned > on a sequence number: it is wrong across the 2^32 wrap
    // and the wrap WILL happen on a long-lived session.
    function automatic logic seq_gt(input logic [31:0] a, input logic [31:0] b);
        return ($signed(a - b) > 0);
    endfunction

    // Largest frame the gateway ever emits: 54 header + 3 Soup + 64 OUCH = 121.
    // Rounded to a 64-bit beat multiple with headroom for a longer OUCH 5.0
    // message (V14: an optional appendage would grow it).
    parameter int unsigned TX_FRAME_MAX_BYTES = 128;
    parameter int unsigned TX_FRAME_MAX_BEATS = TX_FRAME_MAX_BYTES / 8;  // 16
    // Minimum Ethernet payload is 46 bytes; our frames are >= 76, so the MAC
    // never needs to pad. Asserted in tcp_tx_lite.sv rather than assumed.
    parameter int unsigned ETH_MIN_FRAME_BYTES = 60;

endpackage : ouch_pkg

`endif
