// =============================================================================
// ab_arbiter.sv — A/B redundant feed arbitration and sequence deduplication
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/02-networking/03-multicast-feeds-and-arbitration.md (§4-§6)
//           manuals/04-system-architecture/02-feed-handler-design.md    (§5.3, §8)
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   Take N_FEEDS independent copies of the same logically-identical ITCH message
//   stream and behave as though we consumed one perfect feed: forward each
//   sequence number the FIRST time it arrives on ANY feed, discard the copy from
//   the slower feed, and raise a channel-stale signal the moment we can prove we
//   are missing something.
//
// LATENCY
//   1 cycle = 6.40 ns @ 156.25 MHz, fixed, common case and every case.
//   The dedupe decision is a 64-bit compare against base_q plus a bitmap read —
//   there is no timer, no waiting for the second copy, and no data-dependent
//   path. Combined with moldudp64_deframer (1 cycle) this is the "MoldUDP64
//   deframe + A/B arbitration  2 cyc  12.8 ns" row of the fpga_top budget.
//
// RESOURCE (estimate, pre-synthesis — replace with real utilization)
//   LUT ~1,900   FF ~2,600   BRAM 0   URAM 0   DSP 0
//   Ingress FIFOs: N_FEEDS x 632 bits x DEPTH — LUTRAM, ~2 x 40 LUTRAM64.
//   Skew table: 64 x 29 bits.
//
// =============================================================================
// §A  THE ALGORITHM IS: THERE ISN'T ONE
// =============================================================================
//   The naive design waits for both feeds, compares, and prefers A. DO NOT BUILD
//   THIS. Waiting for B costs the A/B skew — TENS OF MICROSECONDS — on EVERY
//   packet, to protect against a loss rate of order 1e-6 (02.03 §5).
//
//   First-arrival-wins needs no arbiter at all, because the sequence check IS
//   the dedupe:
//
//     both feeds enter the SAME sequencer
//     the first copy to arrive has an unseen sequence   -> delivered
//     the second copy arrives with a seen sequence      -> dropped, counted
//
//   No timers. No feed preference. No waiting. The loser's message is discarded
//   by logic that already had to exist.
//
// §B  THE REORDER WINDOW — WHY A BITMAP AND NOT A BUFFER
//   State is:
//     base_q     — the lowest sequence we have NOT yet seen
//     bitmap_q   — REORDER_W bits; bit k means "base_q + k has been delivered"
//     ahead_wm_q — the highest sequence+1 known to exist (from a delivery or a
//                  heartbeat). base_q < ahead_wm_q  <=>  we have a hole.
//
//   | arriving seq s              | meaning                | action            |
//   |-----------------------------|------------------------|-------------------|
//   | s <  base_q                 | already delivered      | dup, drop, count  |
//   | s in window, bit set        | already delivered      | dup, drop, count  |
//   | s in window, bit clear      | first arrival          | DELIVER, set bit  |
//   | s >= base_q + REORDER_W     | beyond the window      | HARD GAP, deliver |
//
//   ⚠️ NOTHING IS EVER BUFFERED. Per 04.02 §5.3 an ahead-of-sequence reordering
//      buffer is unbounded and puts a queue on the fast path. The window holds
//      one BIT per sequence, not one message, so a hole that fills from the
//      slower feed is recognised, base_q walks forward, and the stale signal
//      clears itself — with no storage and no timer.
//
//   Messages may therefore be delivered OUT OF ORDER while a hole is open. That
//   is intentional and safe: m_gap is asserted for the entire duration, so the
//   book is stale and nothing may trade on it. Ordering only matters for a book
//   we are allowed to act on.
//
//   SIZING: REORDER_W = 64 messages. At a sustained 1 M msg/s that covers ~64 us
//   of A/B skew, comfortably past a typical colo p99.9. A loss that outlives the
//   window becomes a HARD gap, which is the honest outcome — the data is gone
//   from both feeds and only host-side recovery (MoldUDP64 retransmission or
//   Glimpse, 02.03 §6) can fix it.
//   > Verify: size REORDER_W against a MEASURED p99.9 A/B skew and the peak
//   > message rate from a captured market open — not from the venue's published
//   > average. Both numbers belong in this header once measured.
//
// §C  ⚠️⚠️  TRADING ON A BOOK WITH A KNOWN GAP  ⚠️⚠️
//   This is the correctness hazard that justifies the whole module.
//
//   A MoldUDP64 gap DOES NOT TELL YOU WHICH SYMBOLS YOU MISSED. TotalView-ITCH
//   is a single sequenced channel covering every symbol. The missing messages
//   could be an Order Delete on your best bid, a Trade that moved the price, or
//   a Trading Action halting the name you are quoting. You cannot know.
//
//   Therefore a gap invalidates the ENTIRE book, not one symbol, and:
//     1. m_gap asserts on the CYCLE the gap is detected — before any recovery
//        attempt, before the host is told.
//     2. m_gap is a LEVEL, not a pulse, and it is an input to the strategy
//        trigger's enable term and to the risk gate. It is not advisory.
//     3. hard_gap_q clears ONLY on reset. There is deliberately NO
//        clear-on-write override register (02.03 §9 rule 5): "If you want one,
//        you want a bug." Recovery is a host-driven resync — in this build a
//        core reset (== start of day). Adding an explicit host resync port is a
//        deliberate, reviewable change to fpga_top's port contract.
//     4. The soft (in-window) hole clears AUTOMATICALLY and only when the
//        sequence is verifiably contiguous again from base_q forward.
//
//   ⚠️ The tempting failure mode is "the gap was only 3 messages, keep going".
//      Three messages is enough to leave a phantom order at the touch that you
//      will quote against and be filled on — and you will be filled precisely
//      because someone else knows it is not there. A stale book does not degrade
//      gracefully; it degrades ADVERSARIALLY.
//
// §D  THE ONE PLACE A REAL ARBITER IS NEEDED
//   A and B are on different physical ports and can present a message in the
//   same cycle. A small per-feed ingress FIFO absorbs that COLLISION (not a rate
//   mismatch — aggregate ingress is at most 2 x 1/2.625 = 0.76 msg/cycle against
//   a 1 msg/cycle drain, so the FIFOs are essentially never more than one entry
//   deep). Fixed priority, A over B: round-robin buys fairness we do not want,
//   because the loser's message is a duplicate in the overwhelming majority of
//   cases (02.03 §5).
//   A FIFO overflow drops the message and counts it. Correctness is preserved by
//   construction: a dropped message manifests as a sequence hole, and the
//   sequencer below is the single authority that decides what the book sees.
// =============================================================================
`default_nettype none

module ab_arbiter
    import trading_pkg::*;
    import net_rx_pkg::*;
#(
    parameter int unsigned N_FEEDS    = 2,
    // Reorder / dedupe window, in MESSAGES. See §B for sizing.
    parameter int unsigned REORDER_W  = 64,
    // Per-feed collision FIFO depth, in messages. See §D.
    parameter int unsigned FIFO_DEPTH = 8,
    // Max sequences base_q may walk forward per cycle when a hole fills.
    // Bounds the trailing-ones encoder to 8 bits; larger holes simply take more
    // cycles to close, which is the conservative direction.
    parameter int unsigned ADV_MAX    = 8,
    // A heartbeat carries the publisher's NEXT sequence. If that is ahead of
    // base_q we are missing messages on that feed. Treat it as a hole watermark.
    parameter bit          HB_IS_GAP  = 1'b1
) (
    input  var logic                     clk,
    input  var logic                     rst,
    // Only the low SK_TS_W bits are consumed: skew is an INTERVAL, and 2^20
    // cycles = 6.7 ms is three orders of magnitude past any credible A/B skew.
    /* verilator lint_off UNUSEDSIGNAL */
    input  var cycle_t                   cycle_cnt,
    /* verilator lint_on UNUSEDSIGNAL */

    // ── Per-feed message streams from moldudp64_deframer ─────────────────────
    input  var logic                     s_valid    [N_FEEDS],
    input  var logic [ITCH_MSG_W-1:0]    s_msg      [N_FEEDS],
    input  var logic [ITCH_LEN_W-1:0]    s_len      [N_FEEDS],
    input  var logic [63:0]              s_seq      [N_FEEDS],
    input  var cycle_t                   s_rx_cycle [N_FEEDS],

    // ── Per-feed out-of-band control (applied immediately) ───────────────────
    input  var logic                     s_poison   [N_FEEDS],
    input  var logic                     s_hb       [N_FEEDS],
    input  var logic [63:0]              s_ctl_seq  [N_FEEDS],

    // ── One deduplicated ITCH message stream out ─────────────────────────────
    output var logic                     m_valid,
    output var logic [ITCH_MSG_W-1:0]    m_msg,
    output var logic [ITCH_LEN_W-1:0]    m_len,
    output var logic [63:0]              m_seq,
    output var cycle_t                   m_rx_cycle,
    // ⚠️ LEVEL, not a pulse. "This channel has a known hole; the book built
    //    from it is not trustworthy." See §C.
    output var logic                     m_gap,

    // ── Telemetry ────────────────────────────────────────────────────────────
    output var logic                     evt_msg,       // == m_valid
    output var logic                     evt_dedupe,    // a duplicate was discarded
    output var logic                     evt_gap,       // a new hole opened
    output var logic                     evt_arb_drop,  // ingress FIFO overflow
    output var logic [15:0]              feed_wins  [N_FEEDS], // first-arrival races
    output var logic [15:0]              skew_max,      // max |t_B - t_A|, cycles
    output var logic [15:0]              gap_max        // largest gap seen, messages
);

    // =========================================================================
    // 0. Geometry
    // =========================================================================
    localparam int unsigned SEQ_W   = 64;
    localparam int unsigned IDX_W   = $clog2(REORDER_W);
    localparam int unsigned ADV_W   = $clog2(ADV_MAX + 1);

    // Ingress FIFO record layout.
    localparam int unsigned F_MSG_LO = 0;
    localparam int unsigned F_LEN_LO = F_MSG_LO + ITCH_MSG_W;
    localparam int unsigned F_TS_LO  = F_LEN_LO + ITCH_LEN_W;
    localparam int unsigned F_SEQ_LO = F_TS_LO  + CYCLE_CNT_W;
    localparam int unsigned FIFO_W   = F_SEQ_LO + SEQ_W;          // 632

    // A/B skew table: direct-mapped by the low sequence bits, tagged to make
    // aliasing detectable rather than silently wrong. Telemetry only.
    localparam int unsigned SK_IDX_W = IDX_W;
    localparam int unsigned SK_TAG_W = 8;
    localparam int unsigned SK_TS_W  = 20;        // 2^20 cycles = 6.7 ms range

`ifndef SYNTHESIS
    initial begin
        if (REORDER_W != (1 << IDX_W)) begin
            $fatal(1, "ab_arbiter: REORDER_W must be a power of two");
        end
        if (ADV_MAX > 8) begin
            $fatal(1, "ab_arbiter: ADV_MAX > 8 makes the trailing-ones encoder deep");
        end
    end
`endif

    // Trailing ones of an 8-bit vector, via popcount(v & ~(v+1)). The add wraps
    // at 8 bits, which is exactly the behaviour wanted for the all-ones case.
    // One carry chain plus a 3-level adder tree; no priority chain, so the
    // depth does not grow with the window.
    function automatic logic [ADV_W-1:0] trailing_ones8(input logic [7:0] v);
        logic [7:0] msk;
        logic [3:0] n;
        msk = v & ~(v + 8'd1);
        n   = 4'd0;
        for (int unsigned i = 0; i < 8; i++) begin
            n = n + {3'd0, msk[i]};
        end
        return ADV_W'(n);
    endfunction

    // =========================================================================
    // 1. Per-feed ingress FIFOs (collision absorption only — see §D)
    // =========================================================================
    // ⚠️⚠️ ASSUMED CONTRACT FOR rtl/common/sync_fifo.sv (written in parallel):
    //        parameters : W (data width), DEPTH (entries, power of two)
    //        ports      : clk, rst, wr_en, wr_data, full, rd_en, rd_data, empty
    //        semantics  : FIRST-WORD-FALL-THROUGH — rd_data is valid whenever
    //                     !empty; rd_en pops the entry that was presented.
    //      If rtl/common/sync_fifo.sv differs, fix THESE FOUR LINES ONLY; the
    //      logic around them makes no other assumption. Recorded in
    //      rtl/net/README.md as an integration dependency.
    logic [FIFO_W-1:0] fifo_wdata [N_FEEDS];
    logic [FIFO_W-1:0] fifo_rdata [N_FEEDS];
    logic              fifo_wr    [N_FEEDS];
    logic              fifo_rd    [N_FEEDS];
    logic              fifo_full  [N_FEEDS];
    logic              fifo_empty [N_FEEDS];

    generate
        for (genvar f = 0; f < N_FEEDS; f++) begin : g_feed_fifo
            assign fifo_wdata[f] = {s_seq[f], s_rx_cycle[f], s_len[f], s_msg[f]};
            // NO BACKPRESSURE upstream (CLAUDE.md §5.4): on overflow we drop and
            // count. The lost message becomes a sequence hole, which the
            // sequencer below detects and turns into a channel stale.
            assign fifo_wr[f]    = s_valid[f] && !fifo_full[f];

            sync_fifo #(
                .W     (FIFO_W),
                .DEPTH (FIFO_DEPTH)
            ) u_fifo (
                .clk     (clk),
                .rst     (rst),
                .wr_en   (fifo_wr[f]),
                .wr_data (fifo_wdata[f]),
                .full    (fifo_full[f]),
                .rd_en   (fifo_rd[f]),
                .rd_data (fifo_rdata[f]),
                .empty   (fifo_empty[f])
            );
        end
    endgenerate

    // =========================================================================
    // 2. Fixed-priority pop — feed 0 (A) over feed 1 (B), message-atomic
    // =========================================================================
    logic [N_FEEDS-1:0]     pop_c;
    logic                   win_valid_c;
    logic [FIFO_W-1:0]      win_rec_c;

    always_comb begin
        pop_c = '0;
        // Iterate downwards so the LAST assignment — the lowest index — wins.
        for (int f = int'(N_FEEDS) - 1; f >= 0; f--) begin
            if (!fifo_empty[f]) begin
                pop_c    = '0;
                pop_c[f] = 1'b1;
            end
        end
    end

    always_comb begin
        win_valid_c = 1'b0;
        win_rec_c   = '0;
        for (int unsigned f = 0; f < N_FEEDS; f++) begin
            if (pop_c[f]) begin
                win_valid_c = 1'b1;
                win_rec_c   = fifo_rdata[f];
            end
        end
    end

    generate
        for (genvar f = 0; f < N_FEEDS; f++) begin : g_feed_pop
            assign fifo_rd[f] = pop_c[f];
        end
    endgenerate

    logic [SEQ_W-1:0]      win_seq_c;
    cycle_t                win_ts_c;
    logic [ITCH_LEN_W-1:0] win_len_c;
    logic [ITCH_MSG_W-1:0] win_msg_c;

    assign win_msg_c = win_rec_c[F_MSG_LO +: ITCH_MSG_W];
    assign win_len_c = win_rec_c[F_LEN_LO +: ITCH_LEN_W];
    assign win_ts_c  = win_rec_c[F_TS_LO  +: CYCLE_CNT_W];
    assign win_seq_c = win_rec_c[F_SEQ_LO +: SEQ_W];

    // =========================================================================
    // 3. Sequence state
    // =========================================================================
    logic [SEQ_W-1:0]       base_q;       // lowest sequence NOT yet seen
    logic [REORDER_W-1:0]   bitmap_q;     // bit k <=> base_q + k delivered
    logic [SEQ_W-1:0]       ahead_wm_q;   // highest known sequence + 1
    logic                   synced_q;     // start-of-day latch
    logic                   hard_gap_q;   // sticky, cleared only by reset (§C.3)

    logic [SEQ_W-1:0]       diff_c;
    logic                   behind_c;
    logic                   in_win_c;
    logic [IDX_W-1:0]       delta_c;
    logic                   already_c;
    logic                   dup_c;
    logic                   hardgap_c;
    logic                   deliver_c;
    logic                   first_c;

    assign diff_c   = win_seq_c - base_q;
    assign behind_c = (win_seq_c < base_q);
    assign in_win_c = !behind_c && (diff_c < SEQ_W'(REORDER_W));
    assign delta_c  = diff_c[IDX_W-1:0];
    assign already_c = in_win_c && bitmap_q[delta_c];
    assign first_c   = win_valid_c && !synced_q;

    // Start of day: the first message ever seen defines base_q. Without this
    // every session would open by reporting a gap of ~2^63.
    assign dup_c     = win_valid_c && synced_q && (behind_c || already_c);
    assign hardgap_c = win_valid_c && synced_q && !behind_c && !in_win_c;
    assign deliver_c = win_valid_c && !dup_c;

    // --- bitmap set + contiguity walk ----------------------------------------
    logic [REORDER_W-1:0] bm_set_c;
    logic [ADV_W-1:0]     adv_c;
    logic [REORDER_W-1:0] bm_next_c;
    logic [SEQ_W-1:0]     base_next_c;

    always_comb begin
        bm_set_c = bitmap_q;
        if (deliver_c && synced_q && !hardgap_c && in_win_c) begin
            // Decoder, not a variable shift: REORDER_W 6-bit compares, 1 level.
            for (int unsigned k = 0; k < REORDER_W; k++) begin
                if (delta_c == IDX_W'(k)) begin
                    bm_set_c[k] = 1'b1;
                end
            end
        end
    end

    // Walk base_q forward over the contiguous run of delivered sequences. Done
    // EVERY cycle, not only on a delivery, so a hole filled by the slower feed
    // closes promptly even if the channel then goes quiet.
    assign adv_c     = trailing_ones8(bm_set_c[7:0]);
    assign bm_next_c = bm_set_c >> adv_c;

    always_comb begin
        if (first_c) begin
            base_next_c = win_seq_c + SEQ_W'(1);
        end else if (hardgap_c) begin
            // Resync forward and do NOT stall (04.02 §8 rule 2). The feed
            // handler stays healthy; the BOOK is what is invalid.
            base_next_c = win_seq_c + SEQ_W'(1);
        end else begin
            base_next_c = base_q + SEQ_W'(adv_c);
        end
    end

    // --- heartbeats: the publisher's next sequence is a hole watermark --------
    logic             hb_any_c;
    logic [SEQ_W-1:0] hb_seq_c;
    logic             poison_any_c;

    always_comb begin
        hb_any_c     = 1'b0;
        hb_seq_c     = '0;
        poison_any_c = 1'b0;
        for (int unsigned f = 0; f < N_FEEDS; f++) begin
            if (s_hb[f] && HB_IS_GAP) begin
                hb_any_c = 1'b1;
                if (s_ctl_seq[f] > hb_seq_c) begin
                    hb_seq_c = s_ctl_seq[f];
                end
            end
            if (s_poison[f]) begin
                poison_any_c = 1'b1;
            end
        end
    end

    // ahead_wm_q is the single self-clearing staleness term: it records the
    // highest sequence we know EXISTS, from a delivery or a heartbeat. While
    // base_q < ahead_wm_q there is a sequence we know about and do not have.
    logic [SEQ_W-1:0] wm_cand_c;
    logic [SEQ_W-1:0] wm_next_c;

    always_comb begin
        wm_cand_c = ahead_wm_q;
        if (deliver_c && ((win_seq_c + SEQ_W'(1)) > wm_cand_c)) begin
            wm_cand_c = win_seq_c + SEQ_W'(1);
        end
        if (hb_any_c && (hb_seq_c > wm_cand_c)) begin
            wm_cand_c = hb_seq_c;
        end
        wm_next_c = first_c ? (win_seq_c + SEQ_W'(1)) : wm_cand_c;
    end

    logic hole_open_c;
    assign hole_open_c = (wm_next_c > base_next_c) && !(ahead_wm_q > base_q);

    always_ff @(posedge clk) begin
        if (rst) begin
            base_q     <= '0;
            bitmap_q   <= '0;
            ahead_wm_q <= '0;
            synced_q   <= 1'b0;
            hard_gap_q <= 1'b0;
        end else begin
            base_q     <= base_next_c;
            bitmap_q   <= (first_c || hardgap_c) ? '0 : bm_next_c;
            ahead_wm_q <= wm_next_c;
            if (win_valid_c) begin
                synced_q <= 1'b1;
            end
            // ⚠️ Sticky. No clear-on-write. See §C.3.
            if (hardgap_c || poison_any_c) begin
                hard_gap_q <= 1'b1;
            end
        end
    end

    // =========================================================================
    // 4. A/B skew measurement (telemetry — one of the highest-value signals
    //    in the system: it turns a network problem into a number, 02.03 §5)
    // =========================================================================
    logic [SK_TS_W-1:0]  sk_ts_q  [REORDER_W];
    logic [SK_TAG_W-1:0] sk_tag_q [REORDER_W];
    logic                sk_vld_q [REORDER_W];

    logic [SK_IDX_W-1:0] sk_idx_c;
    logic [SK_TAG_W-1:0] sk_tag_c;
    logic                sk_hit_c;
    logic [SK_TS_W-1:0]  sk_delta_c;
    logic [15:0]         sk_sat_c;

    assign sk_idx_c   = win_seq_c[SK_IDX_W-1:0];
    assign sk_tag_c   = win_seq_c[SK_IDX_W + SK_TAG_W - 1 : SK_IDX_W];
    assign sk_hit_c   = sk_vld_q[sk_idx_c] && (sk_tag_q[sk_idx_c] == sk_tag_c);
    assign sk_delta_c = cycle_cnt[SK_TS_W-1:0] - sk_ts_q[sk_idx_c];
    assign sk_sat_c   = (sk_delta_c[SK_TS_W-1:16] != '0) ? 16'hFFFF
                                                         : sk_delta_c[15:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned k = 0; k < REORDER_W; k++) begin
                sk_vld_q[k] <= 1'b0;
            end
        end else if (deliver_c) begin
            sk_vld_q[sk_idx_c] <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (deliver_c) begin
            sk_ts_q[sk_idx_c]  <= cycle_cnt[SK_TS_W-1:0];
            sk_tag_q[sk_idx_c] <= sk_tag_c;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            skew_max <= '0;
            gap_max  <= '0;
        end else begin
            if (dup_c && sk_hit_c && (sk_sat_c > skew_max)) begin
                skew_max <= sk_sat_c;
            end
            if (hardgap_c) begin
                if (diff_c[SEQ_W-1:16] != '0) begin
                    gap_max <= 16'hFFFF;
                end else if (diff_c[15:0] > gap_max) begin
                    gap_max <= diff_c[15:0];
                end
            end
        end
    end

    // =========================================================================
    // 5. Per-feed win counters — a feed winning ~100 % of races means the other
    //    path has extra hops or worse optics: a fixable, PAID-FOR latency loss.
    // =========================================================================
    generate
        for (genvar f = 0; f < N_FEEDS; f++) begin : g_feed_stat
            always_ff @(posedge clk) begin
                if (rst) begin
                    feed_wins[f] <= '0;
                end else begin
                    feed_wins[f] <= sat_inc16(feed_wins[f],
                                              deliver_c && pop_c[f]);
                end
            end
        end
    endgenerate

    // =========================================================================
    // 6. Registered outputs
    // =========================================================================
    logic arb_drop_c;
    always_comb begin
        arb_drop_c = 1'b0;
        for (int unsigned f = 0; f < N_FEEDS; f++) begin
            if (s_valid[f] && fifo_full[f]) begin
                arb_drop_c = 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            m_valid      <= 1'b0;
            m_gap        <= 1'b0;
            evt_msg      <= 1'b0;
            evt_dedupe   <= 1'b0;
            evt_gap      <= 1'b0;
            evt_arb_drop <= 1'b0;
        end else begin
            m_valid      <= deliver_c;
            // LEVEL. Sticky hard gap OR an open in-window hole.
            m_gap        <= hard_gap_q || hardgap_c || poison_any_c ||
                            (wm_next_c > base_next_c);
            evt_msg      <= deliver_c;
            evt_dedupe   <= dup_c;
            evt_gap      <= hardgap_c || poison_any_c || hole_open_c;
            evt_arb_drop <= arb_drop_c;
        end
    end

    always_ff @(posedge clk) begin
        m_msg      <= win_msg_c;
        m_len      <= win_len_c;
        m_seq      <= win_seq_c;
        m_rx_cycle <= win_ts_c;
    end

    // =========================================================================
    // 7. Assertions
    // =========================================================================
`ifndef SYNTHESIS
    // A message is either delivered or deduped — never both, never neither.
    assert property (@(posedge clk) disable iff (rst)
        win_valid_c |-> (deliver_c ^ dup_c)
    ) else $error("ab_arbiter: message neither delivered nor deduped");

    // Exactly one feed is popped per cycle. Interleaving two feeds onto one
    // stream corrupts both (02.03 §5).
    assert property (@(posedge clk) disable iff (rst)
        $onehot0(pop_c)
    ) else $error("ab_arbiter: more than one feed popped in a cycle");

    // base_q is monotonic non-decreasing. If it ever regresses, a sequence we
    // already delivered could be delivered again and the book double-applies.
    assert property (@(posedge clk) disable iff (rst)
        synced_q |-> (base_next_c >= base_q)
    ) else $error("ab_arbiter: base sequence regressed");

    // ⚠️ THE money property: a known hole must raise m_gap on the next cycle,
    //    with no delay and no condition.
    assert property (@(posedge clk) disable iff (rst)
        (hardgap_c || poison_any_c) |=> m_gap
    ) else $error("ab_arbiter: gap detected but the channel was not staled");

    // hard_gap_q is sticky for the life of the session.
    assert property (@(posedge clk) disable iff (rst)
        hard_gap_q |=> hard_gap_q
    ) else $error("ab_arbiter: hard gap cleared without a reset");

    // Once sticky, m_gap stays asserted for the life of the session.
    assert property (@(posedge clk) disable iff (rst)
        hard_gap_q |=> m_gap
    ) else $error("ab_arbiter: hard gap not reflected in m_gap");

    // Output contract.
    assert property (@(posedge clk) disable iff (rst)
        m_valid |-> ((m_len != '0) && (m_len <= ITCH_LEN_W'(ITCH_MSG_MAX_BYTES)))
    ) else $error("ab_arbiter: forwarded a message with an illegal length");

    // The FIFOs exist for collision, not rate mismatch. If this fires, the
    // arithmetic in §D is wrong and the ingress assumptions need revisiting.
    assert property (@(posedge clk) disable iff (rst)
        !arb_drop_c
    ) else $error("ab_arbiter: ingress FIFO overflow — collision assumption broken");
`endif

endmodule : ab_arbiter

`default_nettype wire
