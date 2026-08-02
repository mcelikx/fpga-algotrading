// =============================================================================
// ouch_encoder.sv — OUCH 5.0 message builder by TEMPLATE SPLICE
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/01-fpga-design/02-pipelining-and-parallelism.md §4 (precompute)
//           manuals/03-algotrading/04-order-entry-protocols.md §5 (templates)
//           manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// -----------------------------------------------------------------------------
// PURPOSE
//   Turn an `order_out_t` from the risk gate into a complete OUCH message.
//
//   THE IDEA (the single highest-leverage precompute in a trading FPGA):
//   an OUCH Enter Order is 49 bytes, of which 25 are CONSTANT for a given
//   symbol — session, account, stock symbol, capacity, time-in-force, firm,
//   minimum quantity, cross type, customer type. Those 25 bytes are built ONCE
//   by the host and parked in BRAM, one row per active symbol. On a trigger the
//   fast path reads the row and overwrites 24 bytes:
//
//        Order Token (14) | Side (1) | Shares (4) | Price (4) | Display (1)
//
//   So "encode an order" is a MEMORY READ PLUS A MUX, not a serialization.
//   Because every field offset is an elaboration-time constant from ouch_pkg,
//   the "mux" degenerates almost entirely to WIRING — see the Fmax note below.
//
//                 byte 0                                                   48
//                 ┌────┬──────────────┬───┬─────┬────────┬─────┬─────┬─...──┐
//   template BRAM │ 'O'│  0000000000  │ 00│ 0000│ AAPL   │0000 │ TIF │ ...  │
//                 └────┴──────────────┴───┴─────┴────────┴─────┴─────┴─...──┘
//                        ▲              ▲    ▲       ▲       ▲     ▲
//   spliced ────────────►│token         │side│shares │(const)│price│(const)
//                        └──────────────┴────┴───────┴───────┴─────┘
//                        host stores ZEROS at every spliced offset, and the
//                        one's-complement partial sum of THAT zeroed image.
//                        The per-order checksum delta is then simply the sum
//                        of the spliced bytes — no subtraction anywhere.
//
// -----------------------------------------------------------------------------
// LATENCY  (156.25 MHz core clock, 6.4 ns/cycle)
//
//   Path            Stage 0                    Stage 1                cyc   ns
//   -------------   ------------------------   --------------------  ----  ----
//   ENTER ORDER     issue BRAM read @sym;      BRAM data valid;        2   12.8
//                   byte-swap px/qty; render   splice 24 bytes;
//                   token; latch               checksum delta; reg out
//
//   CANCEL ORDER    read register-resident     splice 14 bytes;        2   12.8
//                   cancel template; latch     checksum delta; reg out
//
//   ACHIEVED: 2 cycles / 12.8 ns for BOTH paths, initiation interval = 1.
//   Matches the fpga_top.sv budget line "OUCH template read + splice + checksum
//   2 cyc". Fixed latency, zero jitter, no stall condition inside this module.
//
// -----------------------------------------------------------------------------
// ⚠️ THE CANCEL PATH IS NOT AN AFTERTHOUGHT — IT HAS ITS OWN BUDGET LINE
//
//   For a passive / market-making strategy, CANCEL LATENCY MATTERS MORE THAN
//   ENTRY LATENCY. Being slow to enter costs you an opportunity. Being slow to
//   cancel costs you an adverse fill — you are picked off by someone who saw
//   the same tick you did and got there first, and you pay real money for every
//   nanosecond. The cancel path is therefore given first-class treatment:
//
//     * Its own template store, and deliberately NOT in the same BRAM.
//       The cancel templates live in registers/LUTRAM (4 shapes x 32 bytes).
//       Consequence: a cancel can NEVER be delayed by, or contend for a port
//       with, an entry. There is no shared resource between the two paths
//       except the output register.
//     * Its own splice, which is 14 bytes (one field) versus 24 bytes (five
//       fields). Shorter logic, shallower mux, more timing slack.
//     * Its own counters (stat[1], and the whole cancel column in the README).
//
//   The cancel path is capable of 1-cycle emission (its template read is
//   combinational). It is deliberately ALIGNED TO 2 CYCLES so that the module
//   has a single fixed latency and an initiation interval of 1 with no output
//   arbitration. Collapsing it to 1 cycle is a real, available optimisation
//   worth 6.4 ns on the path that matters most — the cost is an entry/cancel
//   collision on the shared output register, hence jitter, hence a skid buffer.
//   Do it only with a measurement in hand (CLAUDE.md §7), and count the
//   collisions when you do.
//
// -----------------------------------------------------------------------------
// ⚠️ Fmax RISK — WHERE THIS MODULE WILL BREAK FIRST
//
//   The byte-splice mux is NOT the risk, and it is worth understanding why:
//   every splice offset (OUCH_O_TOKEN_OFF, ...) is a `parameter` resolved at
//   elaboration. The select line of every per-byte mux is therefore a CONSTANT,
//   so synthesis folds the entire 64-byte "mux" into wiring. Splice depth: 0
//   LUT levels for the field placement itself.
//
//   What IS on the critical path in stage 1, worst-first:
//     1. BRAM CLK->Q (~1.4-1.9 ns on UltraScale+ with the output register) plus
//        the routing to fan 640 bits of template out to the splice.
//     2. The 512-bit 2:1 ENTER/CANCEL output mux. One LUT level, but 512 bits
//        wide, so it is a ROUTING problem more than a logic one. Floorplan the
//        module into one SLR; a crossing here costs ~1 ns.
//     3. The checksum adder tree: 24 byte terms + template partial = a 5-level
//        16-bit carry-propagate tree, ~2.5-3.5 ns. This is the deepest LOGIC in
//        the module. It has 6 cycles of downstream slack (the TCP checksum sits
//        at frame byte 50 = beat 6 on a 64-bit bus and is not emitted until
//        then), so if timing is tight, MOVE IT ONE STAGE LATER rather than
//        pipelining the datapath.
//
//   ⚠️ THE CLIFF: if the splice offsets ever become RUNTIME-configurable — a
//      real possibility if the venue changes the message shape and someone
//      wants to fix it without a rebuild — every constant-select mux becomes a
//      64:1 byte rotator per lane. That is a barrel shifter across 512 bits:
//      ~6 LUT levels, huge routing, and Fmax collapses by roughly half. Keep
//      the offsets as elaboration constants. A wire-format change is a
//      REBUILD, not a register write.
//
// -----------------------------------------------------------------------------
// RESOURCE ESTIMATE (target, UltraScale+, one SLR)
//   Enter template BRAM : 20 banks x 256 x 32b = 160 Kb -> ~20 RAMB18 (10 RAMB36)
//   Cancel templates    : 4 x 12 x 32b = 1536 b -> LUTRAM / FF
//   Pipeline registers  : ~1400 FF   (2 stages x ~600 b + control)
//   Splice + checksum   : ~700 LUT   (checksum tree dominates)
//
// -----------------------------------------------------------------------------
// HOST CONTRACT — read this before writing a template
//   * cfg_tmpl_data[7:0] is the LOWEST-numbered byte of the 4-byte word, i.e.
//     the byte transmitted FIRST. (Little-endian packing of a big-endian wire.)
//   * Every byte at a SPLICED offset must be written as 0x00. The module
//     asserts this in simulation. If it is violated the checksum is wrong and
//     the venue silently drops the segment.
//   * The stored partial checksum (meta word 0) is the one's-complement sum of
//     the ZEROED template image, computed at TCP-PAYLOAD byte parity — that is,
//     OUCH byte k contributes at payload offset (SOUP_HDR_LEN + k). Off by one
//     here and every order is silently dropped by the venue. See ouch_pkg §9.
//   * Templates are write-protected against in-flight orders only by the host's
//     discipline: quiesce the symbol (risk-disable it), rewrite, re-enable.
//     The `valid` meta bit exists so a half-written template cannot emit.
// =============================================================================
`default_nettype none

module ouch_encoder
    import trading_pkg::*;
    import ouch_pkg::*;
#(
    // ⚠️ V10 (ouch_pkg): 1 = render the token as 14 ASCII hex characters, which
    //    is legal for an alphanumeric-constrained field but carries only 56 of
    //    the 112 token bits. 0 = raw binary. DEFAULT IS THE SAFE ONE.
    parameter bit TOKEN_ASCII_HEX = 1'b1
) (
    input  var logic                       clk,
    input  var logic                       rst,          // sync, active high

    // ── Request in (already risk-passed, kill-gated and credit-gated) ────────
    input  var order_out_t                 s_out,
    input  var logic                       s_out_valid,

    // ── Host template writes (slow path) ─────────────────────────────────────
    input  var logic                       cfg_tmpl_wr,
    input  var logic [15:0]                cfg_tmpl_addr,
    input  var logic [31:0]                cfg_tmpl_data,

    // ── OUCH message out ─────────────────────────────────────────────────────
    output var logic [OUCH_IN_MAX_LEN*8-1:0] m_msg,      // byte n = [8n +: 8]
    output var logic [7:0]                 m_len,
    output var csum_acc_t                  m_csum,       // UNFOLDED partial sum
    output var logic                       m_valid,
    output var logic                       m_is_cancel,
    // 1-cycle pulse: this request was accepted upstream but produced NO
    // message (bad template, length error, token high-water). order_gateway
    // uses it to release the TX slot it reserved, so a refusal cannot leak a
    // reservation and slowly wedge the transmit path.
    output var logic                       m_refuse,

    // ⚠️ NOTE: there is deliberately NO emit-record side channel here
    //    (token / sym / side / price / qty / rx_cycle). Those fields belong in
    //    a DMA record so the host can reconcile every order it did not
    //    originate — a regulatory obligation as much as an engineering one
    //    (manuals/02-networking/02-*.md §8). The fpga_top.sv port list provides
    //    no such ring, so the fields are carried through the pipeline
    //    registers (s1_*) for ILA visibility but are not exported. Adding the
    //    ring is README open item OI-1; re-exposing them is a 6-line change.
    output var logic [31:0]                stat [8]
);

    // =========================================================================
    // Template memory geometry
    // =========================================================================
    localparam int unsigned TMPL_MSG_WORDS  = OUCH_IN_MAX_LEN / 4;   // 16 = 64 B
    localparam int unsigned TMPL_META_WORDS = 4;
    localparam int unsigned TMPL_WORDS      = TMPL_MSG_WORDS + TMPL_META_WORDS;
    localparam int unsigned TMPL_WORD_W     = 5;                     // 0..19
    localparam int unsigned MSG_BITS        = OUCH_IN_MAX_LEN * 8;   // 512

    localparam int unsigned CXL_MSG_BYTES   = 32;
    localparam int unsigned CXL_MSG_WORDS   = CXL_MSG_BYTES / 4;     // 8
    localparam int unsigned CXL_WORDS       = CXL_MSG_WORDS + TMPL_META_WORDS;
    localparam int unsigned CXL_SHAPES      = 4;

    // Meta word offsets, relative to the start of the meta block.
    localparam int unsigned META_CSUM = 0;   // [15:0] partial one's-comp sum
    localparam int unsigned META_LEN  = 1;   // [7:0]  message length in bytes
    localparam int unsigned META_VLD  = 2;   // [0]    template is complete
    localparam int unsigned META_RSVD = 3;

    // cfg_tmpl_addr decode.  bit15: 0 = Enter Order array, 1 = Cancel array.
    //   ENTER : addr[4:0]  word (0..19), addr[12:5] active symbol index
    //   CANCEL: addr[3:0]  word (0..11), addr[5:4] shape
    localparam int unsigned TA_SEL_BIT = 15;

    logic                     tmpl_wr_enter;
    logic                     tmpl_wr_cancel;
    logic [TMPL_WORD_W-1:0]   tmpl_wr_word;
    logic [ACT_IDX_W-1:0]     tmpl_wr_sym;
    logic [3:0]               cxl_wr_word;
    logic [1:0]               cxl_wr_shape;

    always_comb begin
        tmpl_wr_enter  = cfg_tmpl_wr && (cfg_tmpl_addr[TA_SEL_BIT] == 1'b0);
        tmpl_wr_cancel = cfg_tmpl_wr && (cfg_tmpl_addr[TA_SEL_BIT] == 1'b1);
        tmpl_wr_word   = cfg_tmpl_addr[4:0];
        tmpl_wr_sym    = cfg_tmpl_addr[5 +: ACT_IDX_W];
        cxl_wr_word    = cfg_tmpl_addr[3:0];
        cxl_wr_shape   = cfg_tmpl_addr[5:4];
    end

    // =========================================================================
    // STAGE 0 — accept, address the templates, prepare the spliced bytes
    // =========================================================================
    order_token_t             tk;
    logic                     req_is_enter;
    logic                     req_is_cancel;
    logic                     side_bit;
    logic                     post_bit;

    always_comb begin
        tk            = order_token_t'(s_out.token);
        req_is_enter  = s_out_valid && (s_out.action == ACT_SEND);
        req_is_cancel = s_out_valid && (s_out.action == ACT_CANCEL);
        side_bit      = (s_out.side == SIDE_SELL);
        post_bit      = s_out.post_only;
    end

    // ---- Wire-order field renderings (pure wiring: byte swaps + 4-bit LUTs) --
    logic [7:0]  side_ch;
    logic [7:0]  disp_ch;
    logic [31:0] px_be;      // byte j of the field = px_be[8j +: 8]
    logic [31:0] qy_be;

    always_comb begin
        side_ch = OUCH_SIDE_BUY;
        if (s_out.side == SIDE_SELL) begin
            side_ch = s_out.is_short ? OUCH_SIDE_SELL_SHORT : OUCH_SIDE_SELL;
        end
        // post-only maps to Display 'P'; otherwise anonymous displayed.
        disp_ch = post_bit ? OUCH_DISP_POST_ONLY : OUCH_DISP_ANONYMOUS;
        px_be   = bswap32(s_out.price);
        qy_be   = bswap32(s_out.qty);
    end

    // ---- Order token rendering ---------------------------------------------
    // ⚠️ The side and post-only bits are STAMPED INTO THE TOKEN here. OUCH's
    //    Order Executed message carries no side; stamping it makes fill decode
    //    in ouch_rx.sv completely stateless. See ouch_pkg §8.
    logic [TOKEN_HEX_BITS-1:0] tok56;
    token_t                    tok_raw;
    logic [7:0]                token_by [OUCH_TOKEN_LEN];

    always_comb begin
        tok56   = {tk.magic[TOKEN_HEX_MAGIC_W-1:0],
                   side_bit,
                   post_bit,
                   tk.strat_id,
                   tk.sym,
                   tk.counter[TOKEN_HEX_CNT_W-1:0]};
        tok_raw                        = s_out.token;
        tok_raw[TOKEN_RSVD_SIDE_BIT]   = side_bit;
        tok_raw[TOKEN_RSVD_POST_BIT]   = post_bit;

        for (int i = 0; i < OUCH_TOKEN_LEN; i++) begin
            if (TOKEN_ASCII_HEX) begin
                token_by[i] = hex_char(tok56[4*(OUCH_TOKEN_LEN-1-i) +: 4]);
            end else begin
                token_by[i] = tok_raw[8*(OUCH_TOKEN_LEN-1-i) +: 8];
            end
        end
    end

    // ---- Token counter wrap guard ------------------------------------------
    // A wrapped token duplicates a live order's identifier and produces fills
    // that can never be attributed. Refuse to emit, loudly, long before it can
    // happen. See manuals/03-algotrading/04-order-entry-protocols.md §7.
    logic tok_hw_breach;
    always_comb begin
        tok_hw_breach = TOKEN_ASCII_HEX
                      ? (tk.counter[TOKEN_HEX_CNT_W-1:0] >= TOKEN_CNT_HIGH_WATER)
                      : 1'b0;
    end

    // The risk gate owns token generation and must leave rsvd clear so that the
    // side/post stamp is unambiguous.
    logic rsvd_dirty;
    assign rsvd_dirty = s_out_valid && (tk.rsvd != 32'd0);

    // =========================================================================
    // Enter Order template BRAM — 20 banks, each N_ACTIVE x 32b
    // -------------------------------------------------------------------------
    // Written 32 bits at a time by the host, read 640 bits at a time by the
    // fast path. Implemented as parallel banks with a decoded write enable so
    // that synthesis infers 20 clean simple-dual-port BRAMs rather than trying
    // to build one asymmetric-width memory.
    // Read is registered inside the bank: address at cycle 0, data at cycle 1.
    // =========================================================================
    logic [ACT_IDX_W-1:0] tmpl_rd_sym;
    logic [31:0]          tmpl_rd [TMPL_WORDS];

    assign tmpl_rd_sym = s_out.sym;

    generate
        for (genvar w = 0; w < TMPL_WORDS; w++) begin : g_tmpl_bank
            logic [31:0] bank [N_ACTIVE];
            always_ff @(posedge clk) begin
                if (tmpl_wr_enter && (tmpl_wr_word == TMPL_WORD_W'(w))) begin
                    bank[tmpl_wr_sym] <= cfg_tmpl_data;
                end
                tmpl_rd[w] <= bank[tmpl_rd_sym];   // datapath: no reset needed
            end
        end
    endgenerate

    // =========================================================================
    // Cancel Order templates — register/LUTRAM resident, COMBINATIONAL read
    // -------------------------------------------------------------------------
    // Deliberately not in the BRAM: no port contention with an entry, ever.
    // Small enough (4 x 12 x 32b = 1536 bits) that this costs nothing.
    // =========================================================================
    logic [31:0] cxl_tmpl [CXL_SHAPES][CXL_WORDS];
    logic [1:0]  cxl_shape_sel;
    logic [31:0] cxl_rd [CXL_WORDS];

    assign cxl_shape_sel = tk.strat_id[1:0];

    always_ff @(posedge clk) begin
        if (tmpl_wr_cancel) begin
            cxl_tmpl[cxl_wr_shape][cxl_wr_word] <= cfg_tmpl_data;
        end
    end

    always_comb begin
        for (int w = 0; w < CXL_WORDS; w++) begin
            cxl_rd[w] = cxl_tmpl[cxl_shape_sel][w];
        end
    end

    // =========================================================================
    // Stage 0 -> Stage 1 pipeline registers
    // =========================================================================
    logic                     s1_valid;
    logic                     s1_is_cancel;
    logic [7:0]               s1_token_by [OUCH_TOKEN_LEN];
    logic [31:0]              s1_px_be;
    logic [31:0]              s1_qy_be;
    logic [7:0]               s1_side_ch;
    logic [7:0]               s1_disp_ch;
    logic [31:0]              s1_cxl [CXL_WORDS];
    token_t                   s1_token;
    sym_idx_t                 s1_sym;
    side_e                    s1_side;
    price_t                   s1_price;
    qty_t                     s1_qty;
    cycle_t                   s1_rx_cycle;
    logic                     s1_tok_hw;

    always_ff @(posedge clk) begin
        if (rst) begin
            s1_valid     <= 1'b0;
            s1_is_cancel <= 1'b0;
            s1_tok_hw    <= 1'b0;
        end else begin
            s1_valid     <= req_is_enter || req_is_cancel;
            s1_is_cancel <= req_is_cancel;
            s1_tok_hw    <= tok_hw_breach;
        end
        // Datapath registers: no reset (CLAUDE.md §4 / coding standard §6).
        for (int i = 0; i < OUCH_TOKEN_LEN; i++) begin
            s1_token_by[i] <= token_by[i];
        end
        for (int w = 0; w < CXL_WORDS; w++) begin
            s1_cxl[w] <= cxl_rd[w];
        end
        s1_px_be    <= px_be;
        s1_qy_be    <= qy_be;
        s1_side_ch  <= side_ch;
        s1_disp_ch  <= disp_ch;
        s1_token    <= s_out.token;
        s1_sym      <= s_out.sym;
        s1_side     <= s_out.side;
        s1_price    <= s_out.price;
        s1_qty      <= s_out.qty;
        s1_rx_cycle <= s_out.rx_cycle;
    end

    // =========================================================================
    // STAGE 1 — splice, checksum delta, validate, register out
    // =========================================================================

    // ---- Flatten the two template images to byte-addressable form -----------
    logic [MSG_BITS-1:0] tmpl_enter_flat;
    logic [MSG_BITS-1:0] tmpl_cxl_flat;

    always_comb begin
        tmpl_enter_flat = '0;
        for (int w = 0; w < TMPL_MSG_WORDS; w++) begin
            tmpl_enter_flat[32*w +: 32] = tmpl_rd[w];
        end
        tmpl_cxl_flat = '0;
        for (int w = 0; w < CXL_MSG_WORDS; w++) begin
            tmpl_cxl_flat[32*w +: 32] = s1_cxl[w];
        end
    end

    // ---- Meta ---------------------------------------------------------------
    logic [15:0] enter_partial, cxl_partial;
    logic [7:0]  enter_len,     cxl_len;
    logic        enter_ok,      cxl_ok;

    always_comb begin
        enter_partial = tmpl_rd[TMPL_MSG_WORDS + META_CSUM][15:0];
        enter_len     = tmpl_rd[TMPL_MSG_WORDS + META_LEN][7:0];
        enter_ok      = tmpl_rd[TMPL_MSG_WORDS + META_VLD][0];
        cxl_partial   = s1_cxl[CXL_MSG_WORDS + META_CSUM][15:0];
        cxl_len       = s1_cxl[CXL_MSG_WORDS + META_LEN][7:0];
        cxl_ok        = s1_cxl[CXL_MSG_WORDS + META_VLD][0];
    end

    // ---- THE SPLICE ---------------------------------------------------------
    // Every index below is an elaboration constant, so this whole block is
    // wiring. Zero LUT levels for the field placement.
    logic [MSG_BITS-1:0] enter_msg;
    logic [MSG_BITS-1:0] cancel_msg;

    always_comb begin
        enter_msg = tmpl_enter_flat;
        for (int i = 0; i < OUCH_TOKEN_LEN; i++) begin
            enter_msg[8*(OUCH_O_TOKEN_OFF + i) +: 8] = s1_token_by[i];
        end
        enter_msg[8*OUCH_O_SIDE_OFF    +: 8 ] = s1_side_ch;
        enter_msg[8*OUCH_O_SHARES_OFF  +: 32] = s1_qy_be;
        enter_msg[8*OUCH_O_PRICE_OFF   +: 32] = s1_px_be;
        enter_msg[8*OUCH_O_DISPLAY_OFF +: 8 ] = s1_disp_ch;
    end

    always_comb begin
        cancel_msg = tmpl_cxl_flat;
        for (int i = 0; i < OUCH_TOKEN_LEN; i++) begin
            cancel_msg[8*(OUCH_X_TOKEN_OFF + i) +: 8] = s1_token_by[i];
        end
    end

    // ---- THE CHECKSUM DELTA -------------------------------------------------
    // ⚠️ EVERY OFFSET PASSED TO csum_byte_at IS A **TCP PAYLOAD** OFFSET, i.e.
    //    SOUP_HDR_LEN + <OUCH offset>. The SoupBinTCP header is 3 bytes long,
    //    so it FLIPS THE EVEN/ODD PARITY of every OUCH field. Passing the raw
    //    OUCH offset here swaps the high and low halves of every contribution
    //    and produces a checksum that is wrong for every single message.
    //    The venue then silently discards the segment and the symptom presents
    //    as "occasional latency spikes", not as a checksum bug.
    //
    // The template's own contribution is `*_partial`, precomputed by the host
    // over the image with all spliced bytes ZERO. Because the replaced bytes
    // are zero, the delta is a pure ADDITION — there is no subtraction and
    // therefore none of the RFC 1141 / RFC 1624 end-around-carry corner case.
    // (manuals/02-networking/02-ip-udp-tcp-in-hardware.md §4.)
    csum_acc_t csum_enter;
    csum_acc_t csum_cancel;

    always_comb begin
        csum_enter = {{(CSUM_ACC_W-16){1'b0}}, enter_partial};
        for (int i = 0; i < OUCH_TOKEN_LEN; i++) begin
            csum_enter = csum_enter + {{(CSUM_ACC_W-16){1'b0}},
                csum_byte_at(SOUP_HDR_LEN + OUCH_O_TOKEN_OFF + i, s1_token_by[i])};
        end
        for (int j = 0; j < OUCH_SHARES_LEN; j++) begin
            csum_enter = csum_enter + {{(CSUM_ACC_W-16){1'b0}},
                csum_byte_at(SOUP_HDR_LEN + OUCH_O_SHARES_OFF + j, s1_qy_be[8*j +: 8])};
        end
        for (int j = 0; j < OUCH_PRICE_LEN; j++) begin
            csum_enter = csum_enter + {{(CSUM_ACC_W-16){1'b0}},
                csum_byte_at(SOUP_HDR_LEN + OUCH_O_PRICE_OFF + j, s1_px_be[8*j +: 8])};
        end
        csum_enter = csum_enter + {{(CSUM_ACC_W-16){1'b0}},
            csum_byte_at(SOUP_HDR_LEN + OUCH_O_SIDE_OFF, s1_side_ch)};
        csum_enter = csum_enter + {{(CSUM_ACC_W-16){1'b0}},
            csum_byte_at(SOUP_HDR_LEN + OUCH_O_DISPLAY_OFF, s1_disp_ch)};
    end

    always_comb begin
        csum_cancel = {{(CSUM_ACC_W-16){1'b0}}, cxl_partial};
        for (int i = 0; i < OUCH_TOKEN_LEN; i++) begin
            csum_cancel = csum_cancel + {{(CSUM_ACC_W-16){1'b0}},
                csum_byte_at(SOUP_HDR_LEN + OUCH_X_TOKEN_OFF + i, s1_token_by[i])};
        end
    end

    // ---- Validation: refuse rather than emit something wrong ----------------
    logic sel_ok;
    logic sel_type_ok;
    logic sel_len_ok;
    logic emit_ok;
    logic [7:0] sel_len;
    logic [7:0] sel_type_byte;

    always_comb begin
        sel_ok        = s1_is_cancel ? cxl_ok  : enter_ok;
        sel_len       = s1_is_cancel ? cxl_len : enter_len;
        sel_type_byte = s1_is_cancel ? tmpl_cxl_flat[7:0] : tmpl_enter_flat[7:0];
        sel_type_ok   = s1_is_cancel ? (sel_type_byte == OUCH_IN_CANCEL_ORDER)
                                     : (sel_type_byte == OUCH_IN_ENTER_ORDER);
        sel_len_ok    = (sel_len != 8'd0) && (sel_len <= 8'(OUCH_IN_MAX_LEN));
        emit_ok       = s1_valid && sel_ok && sel_type_ok && sel_len_ok && !s1_tok_hw;
    end

    // ---- Registered outputs -------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            m_valid     <= 1'b0;
            m_is_cancel <= 1'b0;
            m_refuse    <= 1'b0;
        end else begin
            m_valid     <= emit_ok;
            m_is_cancel <= s1_is_cancel;
            m_refuse    <= s1_valid && !emit_ok;
        end
        m_msg      <= s1_is_cancel ? cancel_msg  : enter_msg;
        m_csum     <= s1_is_cancel ? csum_cancel : csum_enter;
        m_len      <= sel_len;
    end

    // Emit-record shadow. Held one stage past the splice purely so an ILA (or a
    // future DMA ring, OI-1) can capture what was actually sent alongside the
    // frame that carried it. Costs ~200 FF and no timing.
    /* verilator lint_off UNUSEDSIGNAL */
    token_t   rec_token;
    sym_idx_t rec_sym;
    side_e    rec_side;
    price_t   rec_price;
    qty_t     rec_qty;
    cycle_t   rec_rx_cycle;
    logic     rec_valid;
    /* verilator lint_on UNUSEDSIGNAL */

    always_ff @(posedge clk) begin
        if (rst) rec_valid <= 1'b0;
        else     rec_valid <= emit_ok;
        rec_token    <= s1_token;
        rec_sym      <= s1_sym;
        rec_side     <= s1_side;
        rec_price    <= s1_price;
        rec_qty      <= s1_qty;
        rec_rx_cycle <= s1_rx_cycle;
    end

    // =========================================================================
    // Counters — CLAUDE.md §5.7: every refusal is counted, none is silent
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 8; i++) stat[i] <= 32'd0;
        end else begin
            if (emit_ok && !s1_is_cancel)          stat[0] <= stat[0] + 32'd1;
            if (emit_ok &&  s1_is_cancel)          stat[1] <= stat[1] + 32'd1;
            if (s1_valid && !sel_ok)               stat[2] <= stat[2] + 32'd1;
            if (s1_valid &&  sel_ok && !sel_type_ok) stat[3] <= stat[3] + 32'd1;
            if (s1_valid &&  s1_tok_hw)            stat[4] <= stat[4] + 32'd1;
            if (rsvd_dirty)                        stat[5] <= stat[5] + 32'd1;
            if (s_out_valid && (s_out.action == ACT_NONE)) stat[6] <= stat[6] + 32'd1;
            if (s1_valid &&  sel_ok && !sel_len_ok) stat[7] <= stat[7] + 32'd1;
        end
    end

    // =========================================================================
    // Assertions — simulation only
    // =========================================================================
`ifndef SYNTHESIS
    // Fixed 2-cycle latency, no stall path: a valid request either emits or is
    // counted as a refusal exactly 2 cycles later. Never both, never neither.
    assert property (@(posedge clk) disable iff (rst)
        (s_out_valid && (s_out.action != ACT_NONE)) |=> s1_valid
    ) else $error("ouch_encoder: request lost between stage 0 and stage 1");

    // The risk gate owns the token; rsvd must arrive clear so the side stamp
    // is unambiguous on the way back in.
    assert property (@(posedge clk) disable iff (rst)
        s_out_valid |-> (tk.rsvd == 32'd0)
    ) else $error("ouch_encoder: risk gate set token.rsvd; side stamp ambiguous");

    // A cancel must carry a token. A cancel with a null token is a strategy bug
    // that would cancel-reject at the venue and burn a message-rate credit.
    assert property (@(posedge clk) disable iff (rst)
        (s_out_valid && (s_out.action == ACT_CANCEL)) |-> (s_out.token != '0)
    ) else $error("ouch_encoder: ACT_CANCEL with a null order token");

    // ⚠️ THE TEMPLATE-ZERO INVARIANT. The checksum delta arithmetic is only
    //    valid if the host stored 0x00 at every spliced byte. If this fires,
    //    every order this symbol emits has a wrong TCP checksum and is being
    //    silently discarded by the venue.
    logic spliced_nonzero;
    always_comb begin
        spliced_nonzero = 1'b0;
        for (int i = 0; i < OUCH_TOKEN_LEN; i++) begin
            if (tmpl_enter_flat[8*(OUCH_O_TOKEN_OFF+i) +: 8] != 8'h00) spliced_nonzero = 1'b1;
        end
        for (int j = 0; j < OUCH_SHARES_LEN; j++) begin
            if (tmpl_enter_flat[8*(OUCH_O_SHARES_OFF+j) +: 8] != 8'h00) spliced_nonzero = 1'b1;
            if (tmpl_enter_flat[8*(OUCH_O_PRICE_OFF +j) +: 8] != 8'h00) spliced_nonzero = 1'b1;
        end
        if (tmpl_enter_flat[8*OUCH_O_SIDE_OFF    +: 8] != 8'h00) spliced_nonzero = 1'b1;
        if (tmpl_enter_flat[8*OUCH_O_DISPLAY_OFF +: 8] != 8'h00) spliced_nonzero = 1'b1;
    end

    assert property (@(posedge clk) disable iff (rst)
        (s1_valid && !s1_is_cancel && enter_ok) |-> !spliced_nonzero
    ) else $error("ouch_encoder: template has non-zero bytes at a spliced offset -- checksum delta is INVALID");

    // Geometry sanity, checked once at elaboration rather than trusted.
    initial begin
        if (OUCH_ENTER_LEN  > OUCH_IN_MAX_LEN) $fatal(1, "ouch_encoder: Enter Order exceeds template row");
        if (OUCH_CANCEL_LEN > CXL_MSG_BYTES)   $fatal(1, "ouch_encoder: Cancel Order exceeds cancel template row");
        if (TOKEN_ASCII_HEX && (TOKEN_HEX_BITS != 4*OUCH_TOKEN_LEN))
            $fatal(1, "ouch_encoder: hex token width does not match OUCH_TOKEN_LEN");
    end
`endif

endmodule : ouch_encoder

`default_nettype wire
