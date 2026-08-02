// =============================================================================
// itch_pkg.sv — Nasdaq TotalView-ITCH 5.0 and MoldUDP64 constants
// -----------------------------------------------------------------------------
// Governs : manuals/08-nasdaq/04-totalview-itch-5.0.md
//
// ⚠️  VERIFY BEFORE IMPLEMENTING RTL AGAINST THIS FILE.
//     Message type codes and lengths below reflect the TotalView-ITCH 5.0
//     specification, but field byte offsets and lengths MUST be confirmed
//     against the current spec PDF from
//     https://nasdaqtrader.com/Trading/TradingSpecs before they are baked into
//     a decoder. A wrong offset produces a decoder that "works" on some
//     messages and silently corrupts others — the worst possible failure mode.
//     Every offset constant here is marked with its verification status.
// =============================================================================
`ifndef ITCH_PKG_SV
`define ITCH_PKG_SV

package itch_pkg;

    // -------------------------------------------------------------------------
    // 1. MoldUDP64 transport framing
    // -------------------------------------------------------------------------
    // ITCH rides on MoldUDP64 over UDP multicast, on redundant A/B feeds.
    // Packet layout:
    //   [0..9]   Session          10 bytes, alphanumeric
    //   [10..17] Sequence Number   8 bytes, big-endian, of the FIRST message
    //   [18..19] Message Count     2 bytes, big-endian
    //   [20..]   N message blocks, each: 2-byte big-endian length + payload
    // A Message Count of 0xFFFF is an end-of-session marker.
    // > Verify: MoldUDP64 specification, nasdaqtrader.com.
    parameter int unsigned MOLD_SESSION_OFF   = 0;
    parameter int unsigned MOLD_SESSION_LEN   = 10;
    parameter int unsigned MOLD_SEQNUM_OFF    = 10;
    parameter int unsigned MOLD_SEQNUM_LEN    = 8;
    parameter int unsigned MOLD_MSGCNT_OFF    = 18;
    parameter int unsigned MOLD_MSGCNT_LEN    = 2;
    parameter int unsigned MOLD_HDR_LEN       = 20;
    parameter logic [15:0] MOLD_CNT_HEARTBEAT = 16'h0000;
    parameter logic [15:0] MOLD_CNT_ENDSESS   = 16'hFFFF;

    // -------------------------------------------------------------------------
    // 2. ITCH 5.0 message type codes
    // -------------------------------------------------------------------------
    // > Verify: TotalView-ITCH 5.0 spec, section "Message Formats".
    parameter logic [7:0] MSG_SYSTEM_EVENT      = "S";
    parameter logic [7:0] MSG_STOCK_DIRECTORY   = "R";
    parameter logic [7:0] MSG_TRADING_ACTION    = "H";
    parameter logic [7:0] MSG_REG_SHO           = "Y";
    parameter logic [7:0] MSG_MKT_PARTICIPANT   = "L";
    parameter logic [7:0] MSG_MWCB_DECLINE      = "V";
    parameter logic [7:0] MSG_MWCB_STATUS       = "W";
    parameter logic [7:0] MSG_IPO_QUOTING       = "K";
    parameter logic [7:0] MSG_LULD_COLLAR       = "J";
    parameter logic [7:0] MSG_OPERATIONAL_HALT  = "h";
    parameter logic [7:0] MSG_ADD_ORDER         = "A";   // no MPID
    parameter logic [7:0] MSG_ADD_ORDER_MPID    = "F";   // with MPID
    parameter logic [7:0] MSG_ORDER_EXECUTED    = "E";
    parameter logic [7:0] MSG_ORDER_EXEC_PRICE  = "C";
    parameter logic [7:0] MSG_ORDER_CANCEL      = "X";   // partial reduce
    parameter logic [7:0] MSG_ORDER_DELETE      = "D";   // full remove
    parameter logic [7:0] MSG_ORDER_REPLACE     = "U";   // old ref out, new ref in
    parameter logic [7:0] MSG_TRADE             = "P";   // non-cross
    parameter logic [7:0] MSG_CROSS_TRADE       = "Q";
    parameter logic [7:0] MSG_BROKEN_TRADE      = "B";
    parameter logic [7:0] MSG_NOII              = "I";   // net order imbalance
    parameter logic [7:0] MSG_RPII              = "N";   // retail price improvement

    // -------------------------------------------------------------------------
    // 3. Message lengths (bytes, INCLUDING the 1-byte type code)
    // -------------------------------------------------------------------------
    // Every ITCH message type has a FIXED length. This is what makes an FPGA
    // decoder a fixed-offset field extraction with a type-indexed mux, and not
    // a parsing state machine — the single most important property of the feed.
    //
    // ⚠️ These lengths are the primary thing to verify against the spec. The
    //    decoder MUST cross-check the MoldUDP64 block length against this table
    //    and count a mismatch as a decode error rather than proceeding.
    // > Verify: TotalView-ITCH 5.0 spec, per-message "Length" field.
    parameter int unsigned LEN_SYSTEM_EVENT     = 12;
    parameter int unsigned LEN_STOCK_DIRECTORY  = 39;
    parameter int unsigned LEN_TRADING_ACTION   = 25;
    parameter int unsigned LEN_REG_SHO          = 20;
    parameter int unsigned LEN_MKT_PARTICIPANT  = 26;
    parameter int unsigned LEN_MWCB_DECLINE     = 35;
    parameter int unsigned LEN_MWCB_STATUS      = 12;
    parameter int unsigned LEN_IPO_QUOTING      = 28;
    parameter int unsigned LEN_LULD_COLLAR      = 35;
    parameter int unsigned LEN_OPERATIONAL_HALT = 21;
    parameter int unsigned LEN_ADD_ORDER        = 36;
    parameter int unsigned LEN_ADD_ORDER_MPID   = 40;
    parameter int unsigned LEN_ORDER_EXECUTED   = 31;
    parameter int unsigned LEN_ORDER_EXEC_PRICE = 36;
    parameter int unsigned LEN_ORDER_CANCEL     = 23;
    parameter int unsigned LEN_ORDER_DELETE     = 19;
    parameter int unsigned LEN_ORDER_REPLACE    = 35;
    parameter int unsigned LEN_TRADE            = 44;
    parameter int unsigned LEN_CROSS_TRADE      = 40;
    parameter int unsigned LEN_BROKEN_TRADE     = 19;
    parameter int unsigned LEN_NOII             = 50;
    parameter int unsigned LEN_RPII             = 20;
    parameter int unsigned LEN_MAX              = 50;

    // -------------------------------------------------------------------------
    // 4. Common field offsets
    // -------------------------------------------------------------------------
    // Every ITCH message begins with the same 11-byte prefix:
    //   [0]      Message Type      1 byte
    //   [1..2]   Stock Locate      2 bytes, big-endian  <-- the direct index
    //   [3..4]   Tracking Number   2 bytes, big-endian
    //   [5..10]  Timestamp         6 bytes, big-endian, ns since midnight ET
    // This prefix is invariant across all types, so locate/timestamp extraction
    // happens BEFORE type dispatch, in parallel with it.
    // > Verify: TotalView-ITCH 5.0 spec, "Common fields".
    parameter int unsigned OFF_MSG_TYPE   = 0;
    parameter int unsigned OFF_LOCATE     = 1;
    parameter int unsigned OFF_TRACKING   = 3;
    parameter int unsigned OFF_TIMESTAMP  = 5;
    parameter int unsigned LEN_TIMESTAMP  = 6;
    parameter int unsigned HDR_PREFIX_LEN = 11;

    // Add Order (A) — offsets after the common prefix.
    //   [11..18] Order Reference   8 bytes
    //   [19]     Buy/Sell          1 byte ('B' or 'S')
    //   [20..23] Shares            4 bytes
    //   [24..31] Stock             8 bytes, space-padded ASCII
    //   [32..35] Price             4 bytes, 4 implied decimals
    // > Verify: spec. Structure illustrative — confirm offsets before RTL.
    parameter int unsigned OFF_A_ORDER_REF = 11;
    parameter int unsigned OFF_A_SIDE      = 19;
    parameter int unsigned OFF_A_SHARES    = 20;
    parameter int unsigned OFF_A_STOCK     = 24;
    parameter int unsigned OFF_A_PRICE     = 32;

    // Order Executed (E): common prefix, order ref, executed shares, match no.
    parameter int unsigned OFF_E_ORDER_REF = 11;
    parameter int unsigned OFF_E_SHARES    = 19;
    parameter int unsigned OFF_E_MATCH     = 23;

    // Order Cancel (X): common prefix, order ref, cancelled shares.
    parameter int unsigned OFF_X_ORDER_REF = 11;
    parameter int unsigned OFF_X_SHARES    = 19;

    // Order Delete (D): common prefix, order ref.
    parameter int unsigned OFF_D_ORDER_REF = 11;

    // Order Replace (U): common prefix, ORIGINAL ref, NEW ref, shares, price.
    // ⚠️ 'U' both removes the original reference and creates a new one. A book
    //    that treats it as an in-place modify will leak order references and
    //    drift from the true book. See manuals/08-nasdaq/04-*.md.
    parameter int unsigned OFF_U_ORIG_REF  = 11;
    parameter int unsigned OFF_U_NEW_REF   = 19;
    parameter int unsigned OFF_U_SHARES    = 27;
    parameter int unsigned OFF_U_PRICE     = 31;

    // -------------------------------------------------------------------------
    // 5. Field encodings
    // -------------------------------------------------------------------------
    parameter logic [7:0] SIDE_CHAR_BUY  = "B";
    parameter logic [7:0] SIDE_CHAR_SELL = "S";

    // System Event (S) codes — drive the global session state machine.
    parameter logic [7:0] SYSEV_START_MESSAGES = "O";
    parameter logic [7:0] SYSEV_START_SYSTEM   = "S";
    parameter logic [7:0] SYSEV_START_MARKET   = "Q";
    parameter logic [7:0] SYSEV_END_MARKET     = "M";
    parameter logic [7:0] SYSEV_END_SYSTEM     = "E";
    parameter logic [7:0] SYSEV_END_MESSAGES   = "C";

    // Trading Action (H) state codes — per symbol.
    parameter logic [7:0] TRADE_ACT_HALTED   = "H";
    parameter logic [7:0] TRADE_ACT_PAUSED   = "P";  // LULD pause
    parameter logic [7:0] TRADE_ACT_QUOTEONLY= "Q";
    parameter logic [7:0] TRADE_ACT_TRADING  = "T";

    // Reg SHO (Y) action codes — Rule 201 short-sale price test state.
    parameter logic [7:0] SHO_NONE      = "0";
    parameter logic [7:0] SHO_INTRADAY  = "1";   // triggered today
    parameter logic [7:0] SHO_RESTRICTED= "2";   // in force

    // -------------------------------------------------------------------------
    // 6. Decode helpers
    // -------------------------------------------------------------------------
    // Returns the expected message length for a type code, or 0 if unknown.
    // The decoder uses this to validate the MoldUDP64 block length. An unknown
    // type is NOT an error — Nasdaq adds message types — but it must be counted
    // and skipped by its declared length, never by a guess.
    function automatic int unsigned itch_msg_len(input logic [7:0] t);
        case (t)
            MSG_SYSTEM_EVENT     : return LEN_SYSTEM_EVENT;
            MSG_STOCK_DIRECTORY  : return LEN_STOCK_DIRECTORY;
            MSG_TRADING_ACTION   : return LEN_TRADING_ACTION;
            MSG_REG_SHO          : return LEN_REG_SHO;
            MSG_MKT_PARTICIPANT  : return LEN_MKT_PARTICIPANT;
            MSG_MWCB_DECLINE     : return LEN_MWCB_DECLINE;
            MSG_MWCB_STATUS      : return LEN_MWCB_STATUS;
            MSG_IPO_QUOTING      : return LEN_IPO_QUOTING;
            MSG_LULD_COLLAR      : return LEN_LULD_COLLAR;
            MSG_OPERATIONAL_HALT : return LEN_OPERATIONAL_HALT;
            MSG_ADD_ORDER        : return LEN_ADD_ORDER;
            MSG_ADD_ORDER_MPID   : return LEN_ADD_ORDER_MPID;
            MSG_ORDER_EXECUTED   : return LEN_ORDER_EXECUTED;
            MSG_ORDER_EXEC_PRICE : return LEN_ORDER_EXEC_PRICE;
            MSG_ORDER_CANCEL     : return LEN_ORDER_CANCEL;
            MSG_ORDER_DELETE     : return LEN_ORDER_DELETE;
            MSG_ORDER_REPLACE    : return LEN_ORDER_REPLACE;
            MSG_TRADE            : return LEN_TRADE;
            MSG_CROSS_TRADE      : return LEN_CROSS_TRADE;
            MSG_BROKEN_TRADE     : return LEN_BROKEN_TRADE;
            MSG_NOII             : return LEN_NOII;
            MSG_RPII             : return LEN_RPII;
            default              : return 0;
        endcase
    endfunction

    // True for message types that mutate the order book.
    function automatic logic is_book_msg(input logic [7:0] t);
        return (t == MSG_ADD_ORDER)       || (t == MSG_ADD_ORDER_MPID) ||
               (t == MSG_ORDER_EXECUTED)  || (t == MSG_ORDER_EXEC_PRICE) ||
               (t == MSG_ORDER_CANCEL)    || (t == MSG_ORDER_DELETE) ||
               (t == MSG_ORDER_REPLACE);
    endfunction

endpackage : itch_pkg

`endif
