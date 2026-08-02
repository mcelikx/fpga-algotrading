// =============================================================================
// dma_log_ring.sv — Audit-record DMA ring (fabric -> host memory)
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/06-operations/03-monitoring-and-telemetry.md §5, §10
//           manuals/00-foundations/04-clocking-reset-and-cdc.md §3.3
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   Streams one fixed-size record to host memory for every order decision,
//   every fill, every risk rejection, and every control-plane state change.
//   This is the COMPLIANCE AUDIT TRAIL (CAT) and the post-trade analysis input.
//   It is how you answer "why did the machine send that order at 14:32:07.412".
//
//   Record layout, record types and the integrity fold live in
//   rtl/telemetry/telemetry_pkg.sv so host software is generated from, or
//   checked against, one definition. One record = 512 bits = 64 B = one host
//   cache line = ONE DMA beat, so a record can never be torn by the fabric.
//
// ⚠ THE TWO RULES THAT SHAPE THIS BLOCK
//
//   1. IT NEVER BACKPRESSURES THE FAST PATH. There is no ready signal on the
//      ingest port. It observes; it does not gate. A telemetry FIFO that can
//      stall the datapath has converted a monitoring problem into a trading
//      outage (manuals/06-operations/03-*.md §5 rule 3, CLAUDE.md §5.4).
//
//   2. IT IS NEVER SILENTLY DROPPABLE. Loss is inevitable if the host stalls,
//      but it must be LOUD and it must be EXACTLY QUANTIFIED:
//        a. `seq` increments for every record the fabric decides to emit,
//           INCLUDING ones it then drops. A gap in `seq` at the host is a
//           precise, self-describing count of what was lost and where.
//        b. `drop_cnt` counts lost records in a readable register and sets a
//           sticky flag. Non-zero is an ALERTABLE condition
//           (manuals/06-operations/03-*.md §7 Tier 2, and Tier 1 if it is
//           climbing while armed — you are trading without an audit trail).
//        c. A LOG_GAP_MARKER record is pushed as soon as space returns,
//           carrying the lost count and the first lost seq, and it takes
//           PRIORITY over resuming live records so the marker cannot itself be
//           starved out. The host therefore learns about the loss in-band even
//           if it never reads a CSR.
//      Silent failure is the worst failure mode in this domain; a silently
//      lossy audit trail is worse than no audit trail, because it looks
//      complete.
//
// ⚠ WHAT chk32 IS NOT. The per-record fold catches torn, zeroed, stale and
//   transposed records — the failure modes a DMA ring actually has. It is not
//   a CRC and not tamper evidence. Compliance-grade integrity is the host's
//   per-file digest over the archived trading-day file
//   (manuals/06-operations/03-*.md §10).
//
// -----------------------------------------------------------------------------
// CDC INVENTORY (this block sits inside host_ctrl; these are part of its table)
//   R1  record payload   core -> pcie   async_fifo (gray-coded)   512 b
//   R2  drop_cnt         core -> pcie   cdc_handshake  W=32, refreshed /1024
//   All other ring state (head, tail, base, size) is pcie-domain only and
//   crosses nothing.
//
// LATENCY  : 0 cycles on the datapath (pure observer, no ready port).
//            Ingest to host memory: 2 core cycles + async FIFO (~3 cycles) +
//            3 pcie cycles + PCIe posted-write time. Irrelevant and untimed —
//            this is the slow path (CLAUDE.md §1).
// RESOURCE : async FIFO 512 b x 512 = 8 BRAM36. Logic est. LUT ~1.1 k, FF ~2 k,
//            DSP 0. The chk32 fold is a pure XOR tree, ~2 LUT6 levels.
// =============================================================================
`default_nettype none

module dma_log_ring
    import trading_pkg::*;
    import telemetry_pkg::*;
#(
    // Fabric-side elasticity. Sized to absorb a burst of decisions while the
    // host is between polls. 512 records = 32 KiB = 8 BRAM36.
    parameter int unsigned FIFO_DEPTH = 512,
    // Must equal LOG_REC_W. A narrower bus means a record spans beats and CAN
    // be torn in host memory — checked at elaboration below.
    parameter int unsigned DMA_W      = 512,
    // Set 1 if rtl/common/async_fifo.sv is FIRST-WORD-FALL-THROUGH (rd_data is
    // valid whenever !rd_empty). 0 = standard synchronous read (rd_data valid
    // the cycle after rd_en). ⚠ Getting this wrong reads the wrong record; it
    // is checked by an assertion on the record sequence numbers below.
    parameter bit          FIFO_FWFT  = 1'b0,
    // BUILD_ID[15:0], stamped into every record so a record can always be tied
    // back to the exact bitstream that produced it
    // (manuals/06-operations/01-build-and-release.md §4).
    parameter logic [15:0] BUILD_TAG  = 16'h0000
) (
    // ═══ core_clk observer side ══════════════════════════════════════════════
    input  var logic                  core_clk,
    input  var logic                  core_rst,
    input  var cycle_t                cycle_cnt,

    // Ingest. NO READY. NO BACKPRESSURE. EVER.
    // The producer fills rec_type, trig_cycle, sym, flags, reason, price, qty,
    // token, strat_ctx, aux0, aux1. This block OVERWRITES ver, build_tag,
    // ts_cycle, seq and chk32 — a producer cannot forge provenance.
    input  var logic                  s_valid,
    input  var log_rec_t              s_rec,

    // ═══ pcie_clk DMA side ═══════════════════════════════════════════════════
    input  var logic                  pcie_clk,
    input  var logic                  pcie_rst,

    // Ring configuration, owned by the host through the CSR block.
    input  var logic                  ring_en,
    input  var logic [63:0]           ring_base,        // host physical address
    input  var logic [4:0]            ring_size_log2,   // entries = 2^n
    input  var logic [31:0]           ring_tail,        // host consume pointer
    output var logic [31:0]           ring_head,        // fabric produce pointer

    // Health. ⚠ Both are alertable.
    output var logic [31:0]           drop_cnt,         // records LOST
    output var logic                  drop_sticky,      // ever lost anything
    output var logic [31:0]           ring_full_cnt,    // blocked episodes
    output var logic [31:0]           rec_cnt,          // records delivered
    input  var logic                  clr_sticky,

    // DMA write master
    output var logic                  dma_wr_valid,
    input  var logic                  dma_wr_ready,
    output var logic [63:0]           dma_wr_addr,
    output var logic [DMA_W-1:0]      dma_wr_data,
    output var logic                  dma_wr_last
);

    localparam int unsigned REFRESH_LOG2 = 10;   // drop_cnt refresh: /1024

    // =========================================================================
    // CORE DOMAIN — record assembly, sequencing, drop accounting
    // =========================================================================

    // ── stage 1: stamp provenance ────────────────────────────────────────────
    logic [47:0]              seq_q;
    logic                     v1_q;
    logic [LOG_BODY_W-1:0]    body1_q;
    logic [LOG_BODY_W-1:0]    body_in;

    always_comb begin
        // Field order must match log_rec_t exactly, minus the trailing chk32.
        body_in = { LOG_REC_VERSION,        // [479:472]  ver
                    s_rec.rec_type,         // [471:464]
                    BUILD_TAG,              // [463:448]
                    cycle_cnt,              // [447:400]  ts_cycle  (ours)
                    s_rec.trig_cycle,       // [399:352]
                    seq_q,                  // [351:304]  seq       (ours)
                    s_rec.sym,              // [303:288]
                    s_rec.flags,            // [287:280]
                    s_rec.reason,           // [279:272]
                    s_rec.price,            // [271:240]
                    s_rec.qty,              // [239:208]
                    s_rec.token,            // [207:96]
                    s_rec.strat_ctx,        // [95:64]
                    s_rec.aux0,             // [63:32]
                    s_rec.aux1 };           // [31:0]
    end

    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            v1_q  <= 1'b0;
            seq_q <= 48'd0;
        end else begin
            v1_q <= s_valid;
            // ⚠ seq counts DECISIONS, not deliveries. It advances even for a
            //   record that is about to be dropped — that is what makes loss
            //   exactly quantifiable at the host.
            if (s_valid) seq_q <= seq_q + 48'd1;
        end
        body1_q <= body_in;   // datapath, qualified by v1_q: no reset needed
    end

    // ── stage 2: integrity fold, then push ───────────────────────────────────
    logic                  v2_q;
    logic [LOG_BODY_W-1:0] body2_q;

    always_ff @(posedge core_clk) begin
        if (core_rst) v2_q <= 1'b0;
        else          v2_q <= v1_q;
        body2_q <= body1_q;
    end

    logic [31:0] lost_run_q;      // records lost since the last gap marker
    logic [47:0] first_lost_q;    // seq of the first record in that run
    logic [31:0] drop_cnt_q;      // core-domain total

    logic [LOG_BODY_W-1:0] gap_body;
    always_comb begin
        gap_body = { LOG_REC_VERSION,
                     8'(LOG_GAP_MARKER),
                     BUILD_TAG,
                     cycle_cnt,
                     48'd0,                  // trig_cycle: not a market event
                     seq_q,                  // marker does NOT consume a seq;
                                             // this is "seq at time of marker"
                     16'd0,                  // sym
                     8'd0,                   // flags
                     8'd0,                   // reason
                     32'd0,                  // price
                     32'd0,                  // qty
                     112'd0,                 // token
                     32'd0,                  // strat_ctx
                     lost_run_q,             // aux0 = RECORDS LOST ⚠
                     32'(first_lost_q[31:0]) };  // aux1 = first lost seq (low)
    end

    logic                  fifo_full;
    logic                  fifo_wr_en;
    logic [LOG_REC_W-1:0]  fifo_wr_data;
    logic                  push_gap;
    logic                  push_live;
    logic                  drop_live;

    always_comb begin
        // Gap markers take PRIORITY so the loss report cannot itself be starved
        // out by a sustained flood of live records.
        push_gap  = !fifo_full && (lost_run_q != 32'd0);
        push_live = !fifo_full && (lost_run_q == 32'd0) && v2_q;
        drop_live = v2_q && !push_live;

        fifo_wr_en   = push_gap || push_live;
        fifo_wr_data = push_gap ? {gap_body, log_chk32(gap_body)}
                                : {body2_q,  log_chk32(body2_q)};
    end

    logic drop_sticky_core_q;

    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            lost_run_q         <= 32'd0;
            first_lost_q       <= 48'd0;
            drop_cnt_q         <= 32'd0;
            drop_sticky_core_q <= 1'b0;
        end else begin
            // Run length: a marker clears it, a fresh drop in the same cycle
            // immediately starts the next run.
            if (push_gap && drop_live) begin
                lost_run_q   <= 32'd1;
                first_lost_q <= body2_q[351:304];       // this record's seq
            end else if (push_gap) begin
                lost_run_q   <= 32'd0;
            end else if (drop_live) begin
                if (lost_run_q == 32'd0) begin
                    first_lost_q <= body2_q[351:304];
                end
                if (lost_run_q != 32'hFFFF_FFFF) begin
                    lost_run_q <= lost_run_q + 32'd1;
                end
            end

            if (drop_live) begin
                drop_sticky_core_q <= 1'b1;
                if (drop_cnt_q != 32'hFFFF_FFFF) begin
                    drop_cnt_q <= drop_cnt_q + 32'd1;   // saturating: a wrapped
                end                                     // loss count reads as OK
            end
        end
    end

    // =========================================================================
    // CDC R1 — record payload, core -> pcie, gray-coded async FIFO
    // The ONLY multi-bit crossing in this block, and the sanctioned primitive
    // for it (manuals/00-foundations/04-*.md §3.3).
    // ⚠ fifo_full is NOT connected to anything upstream. That is the structural
    //   guarantee behind "never backpressures the fast path".
    // =========================================================================
    logic                 fifo_rd_en;
    logic                 fifo_empty;
    logic [LOG_REC_W-1:0] fifo_rd_data;

    async_fifo #(
        .W     (LOG_REC_W),
        .DEPTH (FIFO_DEPTH)
    ) u_rec_fifo (
        .wr_clk   (core_clk),
        .wr_rst   (core_rst),
        .wr_en    (fifo_wr_en),
        .wr_data  (fifo_wr_data),
        .wr_full  (fifo_full),
        .rd_clk   (pcie_clk),
        .rd_rst   (pcie_rst),
        .rd_en    (fifo_rd_en),
        .rd_data  (fifo_rd_data),
        .rd_empty (fifo_empty)
    );

    // =========================================================================
    // CDC R2 — drop_cnt, core -> pcie, handshake
    // Refreshed every 2^10 core cycles (~6.5 us). The refresh period is orders
    // of magnitude longer than the handshake round trip (~6 cycles), so the
    // source data is trivially stable for the whole transfer — which is the
    // protocol's only requirement (manuals/00-foundations/04-*.md §3.4).
    // =========================================================================
    logic [REFRESH_LOG2-1:0] refresh_ctr_q;
    logic                    refresh_tick;
    logic [31:0]             hs_data_q;
    logic                    hs_valid_q;
    logic                    hs_src_ready;

    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            refresh_ctr_q <= '0;
            hs_valid_q    <= 1'b0;
            hs_data_q     <= 32'd0;
        end else begin
            refresh_ctr_q <= refresh_ctr_q + 1'b1;
            hs_valid_q    <= refresh_tick;
            if (refresh_tick) hs_data_q <= drop_cnt_q;
        end
    end

    assign refresh_tick = (refresh_ctr_q == '1);

    cdc_handshake #(
        .W (32)
    ) u_drop_cdc (
        .src_clk   (core_clk),
        .src_rst   (core_rst),
        .src_data  (hs_data_q),
        .src_valid (hs_valid_q),
        .src_ready (hs_src_ready),
        .dst_clk   (pcie_clk),
        .dst_rst   (pcie_rst),
        .dst_data  (drop_cnt),
        .dst_valid (/* level output: drop_cnt holds its last value */)
    );

    // =========================================================================
    // PCIE DOMAIN — ring pointers and the DMA write engine
    // =========================================================================
    logic [31:0] head_q;
    logic [31:0] ring_mask_q;
    logic [31:0] occupancy;
    logic        space_avail;
    logic        can_pop;
    logic        blocked;
    logic        blocked_q;

    // Registered mask: one barrel shifter, updated only when the host changes
    // the ring size, and never on any timed path. Power-of-two size is what
    // lets the wrap be a mask instead of a modulo (CLAUDE.md §5.3).
    always_ff @(posedge pcie_clk) begin
        if (pcie_rst) ring_mask_q <= 32'd0;
        else          ring_mask_q <= (32'd1 << ring_size_log2) - 32'd1;
    end

    always_comb begin
        // Free-running pointers: unsigned subtraction is correct across wrap.
        occupancy   = head_q - ring_tail;
        space_avail = (occupancy <= ring_mask_q);   // mask = size-1
        can_pop     = ring_en && !fifo_empty && space_avail;
        blocked     = ring_en && !fifo_empty && !space_avail;
    end

    typedef enum logic [1:0] {
        RD_IDLE = 2'd0,
        RD_WAIT = 2'd1,
        RD_SEND = 2'd2
    } rd_state_e;

    rd_state_e            rd_state;
    logic [LOG_REC_W-1:0] hold_q;
    logic [63:0]          addr_q;

    // Combinational read enable so the FIFO output is presented on the cycle
    // this FSM expects it, for both FIFO flavours (see FIFO_FWFT).
    assign fifo_rd_en = (rd_state == RD_IDLE) && can_pop;

    always_ff @(posedge pcie_clk) begin
        if (pcie_rst) begin
            rd_state      <= RD_IDLE;
            head_q        <= 32'd0;
            dma_wr_valid  <= 1'b0;
            rec_cnt       <= 32'd0;
            ring_full_cnt <= 32'd0;
            blocked_q     <= 1'b0;
            addr_q        <= 64'd0;
        end else begin
            blocked_q <= blocked;
            // Count blocked EPISODES, not blocked cycles: a cycle counter here
            // would swamp the register with a number that says only "the host
            // is slow", while the episode count says how often it happened.
            if (blocked && !blocked_q && (ring_full_cnt != 32'hFFFF_FFFF)) begin
                ring_full_cnt <= ring_full_cnt + 32'd1;
            end

            unique case (rd_state)
                RD_IDLE: begin
                    if (can_pop) begin
                        // byte offset = (head & mask) * 64 -> a fixed shift, so
                        // no multiplier and no divider (CLAUDE.md §5.3).
                        addr_q <= ring_base +
                                  64'({head_q & ring_mask_q, 6'd0});
                        if (FIFO_FWFT) begin
                            hold_q       <= fifo_rd_data;
                            dma_wr_valid <= 1'b1;
                            rd_state     <= RD_SEND;
                        end else begin
                            rd_state <= RD_WAIT;
                        end
                    end
                end

                RD_WAIT: begin
                    // Standard synchronous FIFO: rd_data is valid now.
                    hold_q       <= fifo_rd_data;
                    dma_wr_valid <= 1'b1;
                    rd_state     <= RD_SEND;
                end

                RD_SEND: begin
                    if (dma_wr_ready) begin
                        dma_wr_valid <= 1'b0;
                        head_q       <= head_q + 32'd1;
                        rd_state     <= RD_IDLE;
                        if (rec_cnt != 32'hFFFF_FFFF) begin
                            rec_cnt <= rec_cnt + 32'd1;
                        end
                    end
                end

                default: rd_state <= RD_IDLE;
            endcase
        end
    end

    assign ring_head   = head_q;
    assign dma_wr_addr = addr_q;
    assign dma_wr_data = hold_q;
    assign dma_wr_last = 1'b1;             // one record = one beat, always

    // Sticky, derived in the pcie domain from the crossed count so no reverse
    // crossing is needed for the clear.
    logic [31:0] drop_cnt_seen_q;
    always_ff @(posedge pcie_clk) begin
        if (pcie_rst) begin
            drop_sticky     <= 1'b0;
            drop_cnt_seen_q <= 32'd0;
        end else begin
            drop_cnt_seen_q <= drop_cnt;
            if (clr_sticky) begin
                drop_sticky <= 1'b0;         // clear has priority; the host logs
            end                              // the count BEFORE clearing
            else if (drop_cnt != drop_cnt_seen_q) begin
                drop_sticky <= 1'b1;
            end
        end
    end

    /* verilator lint_off UNUSED */
    logic unused_ok;
    assign unused_ok = &{1'b1, hs_src_ready, drop_sticky_core_q};
    /* verilator lint_on UNUSED */

    // =========================================================================
    // Assertions — simulation only
    // =========================================================================
`ifndef SYNTHESIS
    initial begin
        if (DMA_W != int'(LOG_REC_W)) begin
            $fatal(1, "dma_log_ring: DMA_W(%0d) != LOG_REC_W(%0d). A record would span beats and could be torn in host memory.",
                   DMA_W, LOG_REC_W);
        end
        if (FIFO_DEPTH < 16) begin
            $fatal(1, "dma_log_ring: FIFO_DEPTH(%0d) too small to absorb a decision burst", FIFO_DEPTH);
        end
    end

    // THE defining property: the ingest pipeline advances every cycle,
    // unconditionally, whether or not the FIFO is full. If a future edit ever
    // makes the pipeline depend on fifo_full, this fails — and that edit would
    // have turned a monitoring problem into a trading outage.
    assert property (@(posedge core_clk) disable iff (core_rst)
        v1_q |=> v2_q
    ) else $error("dma_log_ring: ingest pipeline stalled — the observer is gating the fast path");

    // Every offered record is either pushed or counted as lost. Never neither.
    assert property (@(posedge core_clk) disable iff (core_rst)
        v2_q |-> (push_live ^ drop_live)
    ) else $error("dma_log_ring: a record was neither delivered nor counted as lost");

    // seq must advance monotonically, one per offered record.
    assert property (@(posedge core_clk) disable iff (core_rst)
        s_valid |=> (seq_q == ($past(seq_q) + 48'd1))
    ) else $error("dma_log_ring: record sequence number did not advance");

    // A gap marker must never be emitted with a zero lost count — that would
    // report a loss that did not happen and destroy trust in the alert.
    assert property (@(posedge core_clk) disable iff (core_rst)
        push_gap |-> (lost_run_q != 32'd0)
    ) else $error("dma_log_ring: gap marker with zero lost count");

    // The instant space exists and something has been lost, the marker goes
    // out. This is what makes the loss report unstarvable.
    assert property (@(posedge core_clk) disable iff (core_rst)
        (!fifo_full && (lost_run_q != 32'd0)) |-> push_gap
    ) else $error("dma_log_ring: gap marker starved while the FIFO had space");

    // The DMA engine must never write outside the configured ring.
    assert property (@(posedge pcie_clk) disable iff (pcie_rst)
        dma_wr_valid |-> ((dma_wr_addr >= ring_base) &&
                          (dma_wr_addr <  (ring_base +
                                           64'({ring_mask_q, 6'd0}) + 64'd64)))
    ) else $error("dma_log_ring: DMA address outside the configured ring");

    // Never START a transfer with the ring disabled or unsized. An in-flight
    // record is allowed to complete if the host disables the ring mid-burst.
    assert property (@(posedge pcie_clk) disable iff (pcie_rst)
        fifo_rd_en |-> (ring_en && (ring_size_log2 != 5'd0))
    ) else $error("dma_log_ring: pop attempted with the ring disabled or unsized");
`endif

endmodule : dma_log_ring

`default_nettype wire
