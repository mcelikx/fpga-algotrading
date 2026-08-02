// =============================================================================
// telemetry_pkg.sv — Telemetry address map + DMA audit-log record format
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/06-operations/03-monitoring-and-telemetry.md
//           manuals/05-optimization/04-measurement-and-profiling.md
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   This file is the SINGLE SOURCE OF TRUTH for two host-software contracts:
//
//     1. The telemetry read-window address map (rtl/telemetry/telemetry.sv),
//        proxied to the host through CSR window 0x800 (rtl/ctrl/csr_regfile.sv).
//     2. The DMA audit-log record layout (rtl/ctrl/dma_log_ring.sv).
//
//   Host code MUST be generated from, or checked against, this file. A silent
//   disagreement between fabric and host on either map produces telemetry that
//   is wrong rather than absent — which is the failure mode
//   manuals/06-operations/03-monitoring-and-telemetry.md exists to prevent.
//
//   Bump TELEM_MAP_MINOR for additive changes (new words in reserved space).
//   Bump TELEM_MAP_MAJOR for anything that moves or redefines an existing word.
//   The host refuses to collect if MAJOR does not match its expectation.
//
// LATENCY  : n/a (package — no hardware)
// RESOURCE : n/a
// =============================================================================
`ifndef TELEMETRY_PKG_SV
`define TELEMETRY_PKG_SV

package telemetry_pkg;

    import trading_pkg::*;

    // =========================================================================
    // 1. Map identity
    // =========================================================================
    parameter logic [15:0] TELEM_MAP_MAGIC = 16'h4654;   // "FT" — fabric trading
    parameter logic [7:0]  TELEM_MAP_MAJOR = 8'd1;
    parameter logic [7:0]  TELEM_MAP_MINOR = 8'd0;

    parameter int unsigned TELEM_ADDR_W = 16;
    parameter int unsigned TELEM_DATA_W = 32;

    // Maximum histogram buckets the address map reserves space for. The
    // telemetry instance may be built with fewer (N_BUCKETS parameter); unused
    // slots read as zero.
    parameter int unsigned TELEM_HIST_MAX = 32;

    // Read data returned for an address outside the map. Chosen so a host that
    // is reading the wrong window sees it immediately instead of seeing 0.
    parameter logic [31:0] TELEM_UNMAPPED = 32'hDEAD_C0DE;

    // =========================================================================
    // 2. Telemetry word-address map  (raddr is a WORD index, not a byte address)
    // -----------------------------------------------------------------------------
    // The CSR block converts a BAR byte offset into a word index:
    //     word = (bar_offset - CSR_TELEM_BASE) >> 2
    //
    // ┌────────────┬───────┬──────────────────────────────────────────────────┐
    // │ word addr  │ count │ contents                                          │
    // ├────────────┼───────┼──────────────────────────────────────────────────┤
    // │ 0x0000     │   1   │ STATUS      (LIVE, not snapshotted)               │
    // │ 0x0001     │   1   │ UPTIME_LO   cycle_cnt[31:0]        (snapshotted)  │
    // │ 0x0002     │   1   │ UPTIME_HI   {16'b0, cycle_cnt[47:32]}             │
    // │ 0x0003     │   1   │ VERSION     {MAGIC, MAJOR, MINOR}                 │
    // │ 0x0004     │   1   │ SNAP        ⚠ READ HAS A SIDE EFFECT: latches the │
    // │            │       │             whole shadow bank, returns new seq    │
    // │ 0x0005     │   1   │ HIST_CLEAR  ⚠ READ HAS A SIDE EFFECT: zeroes the  │
    // │            │       │             latency histogram. Start-of-day only. │
    // │ 0x0006     │   1   │ SNAP_SEQ    snapshot sequence number (no effect)   │
    // │ 0x0007     │   1   │ LAT_CFG     {LOG_MODE, DELTA_W, N_BUCKETS}         │
    // │ 0x0008-0F  │   8   │ reserved                                          │
    // │ 0x0010-17  │   8   │ md_mac_stat[feed][idx]  feed*4 + idx              │
    // │ 0x0018-1B  │   4   │ oe_mac_stat[idx]                                  │
    // │ 0x001C-1F  │   4   │ reserved                                          │
    // │ 0x0020-27  │   8   │ net_stat[idx]                                     │
    // │ 0x0028-2F  │   8   │ reserved                                          │
    // │ 0x0030-3F  │  16   │ feed_stat[idx]                                    │
    // │ 0x0040-4F  │  16   │ book_stat[idx]                                    │
    // │ 0x0050-5F  │  16   │ strat_stat[idx]                                   │
    // │ 0x0060-67  │   8   │ risk_stat[idx]                                    │
    // │ 0x0068-6F  │   8   │ reserved                                          │
    // │ 0x0070-87  │  24   │ risk_reject_cnt[reason]  — index == risk_reason_e  │
    // │ 0x0088-8F  │   8   │ reserved                                          │
    // │ 0x0090-9F  │  16   │ order_stat[idx]                                   │
    // │ 0x00A0-BF  │  32   │ reserved                                          │
    // │ 0x00C0-DF  │  32   │ latency histogram bucket[idx]                     │
    // │ 0x00E0     │   1   │ LAT_MIN     cycles (exact)                        │
    // │ 0x00E1     │   1   │ LAT_MAX     cycles (exact)                        │
    // │ 0x00E2     │   1   │ LAT_SUM_LO                                        │
    // │ 0x00E3     │   1   │ LAT_SUM_HI                                        │
    // │ 0x00E4     │   1   │ LAT_N       sample count                          │
    // │ 0x00E5     │   1   │ LAT_OVER    samples above the top bucket ⚠        │
    // │ 0x00E6     │   1   │ LAT_LAST    most recent sample, cycles            │
    // │ 0x00E7-FF  │  25   │ reserved                                          │
    // │ 0xFFFF     │   -   │ IDLE — the address the CSR parks on between reads  │
    // └────────────┴───────┴──────────────────────────────────────────────────┘
    //
    // ⚠ CONSISTENCY CONTRACT: every word except STATUS, VERSION and LAT_CFG is
    //   read from a SHADOW bank. The host MUST read SNAP first, then read the
    //   words it wants, then (optionally) read SNAP_SEQ and confirm it is
    //   unchanged. Reading counters without snapshotting gives a set of values
    //   that never coexisted — see manuals/06-operations/03-*.md §9.
    // =========================================================================
    parameter logic [15:0] TELEM_A_STATUS     = 16'h0000;
    parameter logic [15:0] TELEM_A_UPTIME_LO  = 16'h0001;
    parameter logic [15:0] TELEM_A_UPTIME_HI  = 16'h0002;
    parameter logic [15:0] TELEM_A_VERSION    = 16'h0003;
    parameter logic [15:0] TELEM_A_SNAP       = 16'h0004;
    parameter logic [15:0] TELEM_A_HIST_CLEAR = 16'h0005;
    parameter logic [15:0] TELEM_A_SNAP_SEQ   = 16'h0006;
    parameter logic [15:0] TELEM_A_LAT_CFG    = 16'h0007;

    parameter logic [15:0] TELEM_A_MD_MAC     = 16'h0010;   // 8  words
    parameter logic [15:0] TELEM_A_OE_MAC     = 16'h0018;   // 4  words
    parameter logic [15:0] TELEM_A_NET        = 16'h0020;   // 8  words
    parameter logic [15:0] TELEM_A_FEED       = 16'h0030;   // 16 words
    parameter logic [15:0] TELEM_A_BOOK       = 16'h0040;   // 16 words
    parameter logic [15:0] TELEM_A_STRAT      = 16'h0050;   // 16 words
    parameter logic [15:0] TELEM_A_RISK       = 16'h0060;   // 8  words
    parameter logic [15:0] TELEM_A_REJECT     = 16'h0070;   // 24 words
    parameter logic [15:0] TELEM_A_ORDER      = 16'h0090;   // 16 words
    parameter logic [15:0] TELEM_A_HIST       = 16'h00C0;   // 32 words

    parameter logic [15:0] TELEM_A_LAT_MIN    = 16'h00E0;
    parameter logic [15:0] TELEM_A_LAT_MAX    = 16'h00E1;
    parameter logic [15:0] TELEM_A_LAT_SUM_LO = 16'h00E2;
    parameter logic [15:0] TELEM_A_LAT_SUM_HI = 16'h00E3;
    parameter logic [15:0] TELEM_A_LAT_N      = 16'h00E4;
    parameter logic [15:0] TELEM_A_LAT_OVER   = 16'h00E5;
    parameter logic [15:0] TELEM_A_LAT_LAST   = 16'h00E6;

    parameter logic [15:0] TELEM_A_LAST       = 16'h00FF;   // top of the map
    parameter logic [15:0] TELEM_A_IDLE       = 16'hFFFF;   // parking address

    // Region element counts (host-side bounds checking)
    parameter int unsigned TELEM_N_MD_MAC = 8;
    parameter int unsigned TELEM_N_OE_MAC = 4;
    parameter int unsigned TELEM_N_NET    = 8;
    parameter int unsigned TELEM_N_FEED   = 16;
    parameter int unsigned TELEM_N_BOOK   = 16;
    parameter int unsigned TELEM_N_STRAT  = 16;
    parameter int unsigned TELEM_N_RISK   = 8;
    parameter int unsigned TELEM_N_REJECT = N_RISK_REASONS;   // 24
    parameter int unsigned TELEM_N_ORDER  = 16;

    // -------------------------------------------------------------------------
    // STATUS word (0x0000) bit layout — LIVE, single word, therefore atomic.
    // -------------------------------------------------------------------------
    //   [2:0]  link_up      {oe, md_b, md_a}
    //   [3]    kill_active
    //   [6:4]  kill_src     (kill_src_e)
    //   [7]    lat_sat      histogram counter saturated ⚠ buckets now understate
    //   [8]    lat_over_nz  at least one sample landed above the top bucket ⚠
    //   [31:9] reserved, reads 0
    // -------------------------------------------------------------------------
    parameter int unsigned TELEM_ST_LINK_LSB    = 0;
    parameter int unsigned TELEM_ST_KILL_ACTIVE = 3;
    parameter int unsigned TELEM_ST_KILL_SRC_LSB= 4;
    parameter int unsigned TELEM_ST_LAT_SAT     = 7;
    parameter int unsigned TELEM_ST_LAT_OVER    = 8;

    // =========================================================================
    // 3. Latency instrument geometry
    // =========================================================================
    // 24 bits of cycles at 156.25 MHz = 107 ms of span — four orders of
    // magnitude above any latency this system should ever produce. Anything
    // that overflows 24 bits is a wedge, not a latency.
    parameter int unsigned LAT_DELTA_W = 24;
    parameter int unsigned LAT_CNT_W   = 32;

    // =========================================================================
    // 4. Config write-window geometry (host <-> CSR <-> fabric agreement)
    // -----------------------------------------------------------------------------
    // The CSR is a TRANSPORT: it forwards {addr, data} unchanged to the owning
    // block, which defines the exact word packing. These constants fix only the
    // address STRIDE, so host and fabric agree on where symbol N's record starts.
    //
    //   risk  entry address = sym_idx * RISK_WORDS_PER_SYM  + word_idx
    //   strat entry address = sym_idx * STRAT_WORDS_PER_SYM + word_idx
    //
    // sym_risk_t  is 324 bits -> 11 words used, 12 allocated (1 pad).
    // sym_strat_t is 149 bits ->  5 words used,  8 allocated (3 pad, room to grow).
    // =========================================================================
    parameter int unsigned RISK_WORDS_PER_SYM  = 12;
    parameter int unsigned STRAT_WORDS_PER_SYM = 8;
    parameter int unsigned FILTER_WORDS        = N_SYMBOLS;   // one word per locate
    parameter int unsigned TMPL_WORDS_MAX      = 2048;
    parameter int unsigned SESSION_WORDS_MAX   = 32;

    // Config-write target select, carried across the pcie->core handshake.
    typedef enum logic [2:0] {
        CFG_TGT_NONE    = 3'd0,
        CFG_TGT_FILTER  = 3'd1,
        CFG_TGT_RISK    = 3'd2,
        CFG_TGT_STRAT   = 3'd3,
        CFG_TGT_TMPL    = 3'd4,
        CFG_TGT_SESSION = 3'd5
    } cfg_target_e;

    // =========================================================================
    // 5. DMA audit-log record  — the compliance (CAT) trail
    // -----------------------------------------------------------------------------
    // manuals/06-operations/03-monitoring-and-telemetry.md §10.
    //
    // EXACTLY 512 bits = 64 bytes = one host cache line. One record is one DMA
    // beat on a 512-bit datapath, so a record can never be torn by the fabric.
    //
    // ⚠ VERSIONING: `ver` is the FIRST field so a host reading a record from a
    //   bitstream it does not recognise can reject it without guessing at the
    //   layout. Any change to a field's position or meaning bumps LOG_REC_VERSION.
    //
    // ⚠ LOSS DETECTION: `seq` increments for EVERY record the fabric decides to
    //   emit, INCLUDING records it then had to drop. A host that sees a gap in
    //   `seq` knows exactly how many records it lost and between which two it
    //   lost them. A LOG_GAP_MARKER record is additionally emitted once space
    //   returns, carrying the lost count in aux0. Loss is therefore never silent.
    //
    // ┌────────────┬─────┬──────────────────────────────────────────────────────┐
    // │ field      │ bits│ meaning                                               │
    // ├────────────┼─────┼──────────────────────────────────────────────────────┤
    // │ ver        │   8 │ LOG_REC_VERSION                                       │
    // │ rec_type   │   8 │ log_rec_e                                             │
    // │ build_tag  │  16 │ BUILD_ID[15:0] — ties the record to a bitstream       │
    // │ ts_cycle   │  48 │ core cycle counter when the record was created        │
    // │ trig_cycle │  48 │ ingress cycle of the triggering tick (order_out.rx_   │
    // │            │     │ cycle). ts_cycle - trig_cycle = fabric latency.       │
    // │ seq        │  48 │ monotonic, per-record, never reused in a session      │
    // │ sym        │  16 │ active-set symbol index                               │
    // │ flags      │   8 │ {4'b0, kill_active, post_only, is_short, side}        │
    // │ reason     │   8 │ risk_reason_e / venue reject code / kill_src_e         │
    // │ price      │  32 │ ITCH-scaled integer, 4 implied decimals               │
    // │ qty        │  32 │ shares                                                │
    // │ token      │ 112 │ OUCH client order token (order_token_t)               │
    // │ strat_ctx  │  32 │ {strat_id[3:0], 4'b0, param_gen[15:0], 8'b0}          │
    // │ aux0       │  32 │ type-specific (gap marker: records lost)              │
    // │ aux1       │  32 │ type-specific                                         │
    // │ chk32      │  32 │ integrity check over the preceding 480 bits           │
    // └────────────┴─────┴──────────────────────────────────────────────────────┘
    //
    // ⚠ `chk32` is a rotate-XOR fold, NOT a CRC and NOT cryptographic. It exists
    //   to catch the failure modes a DMA ring actually has — a torn, zeroed,
    //   stale or transposed record — at one LUT level of cost on an observer
    //   path. Compliance-grade integrity is the host's per-file SHA-256 over the
    //   archived day file (manuals/06-operations/03-*.md §10). Do not represent
    //   chk32 as tamper evidence.
    // =========================================================================
    parameter logic [7:0]  LOG_REC_VERSION = 8'd1;
    parameter int unsigned LOG_REC_W       = 512;
    parameter int unsigned LOG_REC_BYTES   = LOG_REC_W / 8;      // 64
    parameter int unsigned LOG_REC_BYTES_LOG2 = 6;               // shift, no multiply
    parameter int unsigned LOG_CHK_W       = 32;
    parameter int unsigned LOG_BODY_W      = LOG_REC_W - LOG_CHK_W;  // 480

    typedef enum logic [7:0] {
        // ── fast-path decisions (the CAT trail proper) ────────────────────────
        LOG_ORDER_SENT     = 8'h01,   // an order left the risk gate
        LOG_ORDER_CANCEL   = 8'h02,
        LOG_RISK_REJECT    = 8'h03,   // risk gate refused; reason = risk_reason_e
        LOG_STRAT_SUPPRESS = 8'h04,   // strategy declined to fire, and why
        LOG_FILL           = 8'h05,
        LOG_VENUE_ACK      = 8'h06,
        LOG_VENUE_REJECT   = 8'h07,
        LOG_VENUE_BREAK    = 8'h08,   // broken trade
        // ── control-plane events (who armed it, when, with what) ──────────────
        LOG_KILL_ASSERT    = 8'h10,   // reason = kill_src_e
        LOG_KILL_CLEAR     = 8'h11,
        LOG_ARM            = 8'h12,   // two-step arm completed
        LOG_DISARM         = 8'h13,
        LOG_PARAM_COMMIT   = 8'h14,   // aux0 = write-side checksum, aux1 = gen
        LOG_WATCHDOG       = 8'h15,   // host heartbeat stopped
        LOG_TRADING_EN     = 8'h16,
        LOG_TRADING_DIS    = 8'h17,
        // ── ring self-reporting ───────────────────────────────────────────────
        LOG_GAP_MARKER     = 8'hFE,   // ⚠ aux0 = records lost, aux1 = first lost seq
        LOG_SESSION_MARK   = 8'hFF    // start of day / ring re-arm
    } log_rec_e;

    typedef struct packed {
        logic [7:0]   ver;
        logic [7:0]   rec_type;
        logic [15:0]  build_tag;
        logic [47:0]  ts_cycle;
        logic [47:0]  trig_cycle;
        logic [47:0]  seq;
        logic [15:0]  sym;
        logic [7:0]   flags;
        logic [7:0]   reason;
        logic [31:0]  price;
        logic [31:0]  qty;
        logic [111:0] token;
        logic [31:0]  strat_ctx;
        logic [31:0]  aux0;
        logic [31:0]  aux1;
        logic [31:0]  chk32;
    } log_rec_t;

    // flags[] bit positions
    parameter int unsigned LOG_FLAG_SIDE      = 0;   // 0 = buy, 1 = sell
    parameter int unsigned LOG_FLAG_IS_SHORT  = 1;
    parameter int unsigned LOG_FLAG_POST_ONLY = 2;
    parameter int unsigned LOG_FLAG_KILL      = 3;

    // -------------------------------------------------------------------------
    // Integrity fold. Pure XOR tree after constant rotation, so synthesis
    // collapses it to ~2 LUT6 levels regardless of how it is written here.
    // Seed is non-zero so an all-zero record does NOT produce a zero check.
    // -------------------------------------------------------------------------
    parameter logic [31:0] LOG_CHK_SEED = 32'hA5A5_5A5A;

    function automatic logic [31:0] log_chk32(input logic [LOG_BODY_W-1:0] body);
        logic [31:0] acc;
        acc = LOG_CHK_SEED;
        for (int w = 0; w < (LOG_BODY_W / 32); w++) begin
            // rotate left 1, then XOR the word: position-sensitive, so a
            // transposed pair of words does not cancel.
            acc = {acc[30:0], acc[31]} ^ body[w*32 +: 32];
        end
        return acc;
    endfunction

    // =========================================================================
    // 6. Log ring geometry
    // =========================================================================
    // The ring lives in host memory. The fabric owns `head`, the host owns
    // `tail`, both counted in RECORDS (not bytes) and both free-running 32-bit
    // so wrap arithmetic is plain unsigned subtraction.
    //
    //   occupancy = head - tail        (unsigned, wraps correctly)
    //   ring full = occupancy >= (1 << ring_size_log2)
    //   byte addr = ring_base + ((head & mask) << LOG_REC_BYTES_LOG2)
    //
    // Size is a LOG2 so the wrap is a mask, never a modulo (CLAUDE.md §5.3).
    parameter int unsigned LOG_RING_LOG2_MIN = 8;    // 256 records  = 16 KiB
    parameter int unsigned LOG_RING_LOG2_MAX = 22;   // 4 M records  = 256 MiB
    parameter int unsigned LOG_RING_LOG2_DEF = 16;   // 64 K records = 4 MiB

endpackage : telemetry_pkg

`endif
