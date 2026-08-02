// =============================================================================
// telemetry.sv — Telemetry aggregation top
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/06-operations/03-monitoring-and-telemetry.md
//           manuals/05-optimization/04-measurement-and-profiling.md
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   Collects every counter array in the design into ONE flat, snapshot-coherent
//   read space, and owns the fabric latency histogram. Instantiated by
//   rtl/fpga_top.sv with N_BUCKETS=32; read by rtl/ctrl/csr_regfile.sv through
//   the CSR telemetry window at BAR offset 0x800.
//
//   The address map below is THE CONTRACT for the host collection agent. It is
//   defined once, in rtl/telemetry/telemetry_pkg.sv, so host software can be
//   generated from or checked against it. Do not duplicate constants here.
//
// -----------------------------------------------------------------------------
// ADDRESS MAP (word index on `raddr`; CSR converts byte offset >> 2)
//
//   word addr   count  R/W  contents
//   ----------  -----  ---  ---------------------------------------------------
//   0x0000        1    RO   STATUS       live: link_up, kill_active, kill_src,
//                                        histogram saturation/overflow flags
//   0x0001        1    RO   UPTIME_LO    cycle_cnt[31:0]         (snapshotted)
//   0x0002        1    RO   UPTIME_HI    cycle_cnt[47:32]        (snapshotted)
//   0x0003        1    RO   VERSION      {MAGIC, MAJOR, MINOR}
//   0x0004        1    RO*  SNAP         ⚠ READ LATCHES THE SHADOW BANK.
//                                        Returns the new snapshot sequence no.
//   0x0005        1    RO*  HIST_CLEAR   ⚠ READ ZEROES THE HISTOGRAM.
//                                        Start-of-day only. Returns 0.
//   0x0006        1    RO   SNAP_SEQ     snapshot sequence number (no effect)
//   0x0007        1    RO   LAT_CFG      {LOG_MODE, DELTA_W, N_BUCKETS}
//   0x0008-000F   8    --   reserved, reads 0
//   0x0010-0017   8    RO   md_mac_stat[feed][i]   index = feed*4 + i
//   0x0018-001B   4    RO   oe_mac_stat[i]
//   0x001C-001F   4    --   reserved
//   0x0020-0027   8    RO   net_stat[i]
//   0x0028-002F   8    --   reserved
//   0x0030-003F  16    RO   feed_stat[i]
//   0x0040-004F  16    RO   book_stat[i]
//   0x0050-005F  16    RO   strat_stat[i]
//   0x0060-0067   8    RO   risk_stat[i]
//   0x0068-006F   8    --   reserved
//   0x0070-0087  24    RO   risk_reject_cnt[reason]  index == risk_reason_e ⚠
//   0x0088-008F   8    --   reserved
//   0x0090-009F  16    RO   order_stat[i]
//   0x00A0-00BF  32    --   reserved
//   0x00C0-00DF  32    RO   latency histogram bucket[i]   (i >= N_BUCKETS -> 0)
//   0x00E0        1    RO   LAT_MIN      cycles, EXACT (a register, not a bucket)
//   0x00E1        1    RO   LAT_MAX      cycles, EXACT
//   0x00E2        1    RO   LAT_SUM_LO
//   0x00E3        1    RO   LAT_SUM_HI   mean = SUM / N, computed on the HOST
//   0x00E4        1    RO   LAT_N
//   0x00E5        1    RO   LAT_OVER     ⚠ non-zero => p99.9 is a LOWER BOUND
//   0x00E6        1    RO   LAT_LAST     most recent sample
//   0x00E7-00FF  25    --   reserved
//   anything else      RO   0xDEAD_C0DE  (unmapped sentinel — never 0)
//
//   * = read has a side effect. These two addresses are the ONLY ones that do,
//     because fpga_top gives telemetry an address bus and nothing else — there
//     is no write strobe and no control port in the instantiation contract.
//     The CSR block parks `raddr` at TELEM_A_IDLE (0xFFFF) between accesses, so
//     every read is a fresh address transition and each side effect fires
//     exactly once per host read.
//
// ⚠ READ PROTOCOL — the host MUST follow this or the numbers are fiction:
//     1. read SNAP           (latches the whole bank in one cycle; note the seq)
//     2. read the words it wants, in any order, at any speed
//     3. read SNAP_SEQ and confirm it still equals the value from step 1
//   Counters read without snapshotting describe a set of values that never
//   coexisted (manuals/06-operations/03-monitoring-and-telemetry.md §9).
//
// ⚠ NO CLEAR-ON-READ ANYWHERE. Every counter is free-running or saturating;
//   the host differences successive snapshots. Clear-on-read loses every event
//   between the read and the clear, and two collectors each see part of the
//   truth (same manual, §9).
//
// -----------------------------------------------------------------------------
// LATENCY  : 0 cycles on the datapath. Telemetry is a pure observer: it has no
//            ready/backpressure port on any input and structurally cannot stall
//            the fast path (CLAUDE.md §5.7, manual 06.03 §1.2).
//            Read port: rdata is valid 2 core cycles after raddr is presented.
//            Latency sample path: 2 cycles from lat_valid to the histogram.
// RESOURCE : shadow bank 116 x 32 b = ~3.7 k FF, histogram ~2.3 k FF,
//            read mux ~600 LUT. Total est. LUT ~1.4 k, FF ~6.5 k, BRAM 0, DSP 0.
//            ≈0.3 % of a VU9P SLR.
// =============================================================================
`default_nettype none

module telemetry
    import trading_pkg::*;
    import telemetry_pkg::*;
#(
    parameter int unsigned N_BUCKETS = 32
) (
    input  var logic         clk,
    input  var logic         rst,

    // ── time base ────────────────────────────────────────────────────────────
    input  var cycle_t       cycle_cnt,

    // ── latency sample: one per emitted order ────────────────────────────────
    input  var logic         lat_valid,
    input  var cycle_t       lat_start,     // ingress cycle carried with the msg

    // ── counter sources (all free-running, owned by the producing block) ─────
    input  var logic [31:0]  md_mac_stat     [2][4],
    input  var logic [31:0]  oe_mac_stat     [4],
    input  var logic [31:0]  net_stat        [8],
    input  var logic [31:0]  feed_stat       [16],
    input  var logic [31:0]  book_stat       [16],
    input  var logic [31:0]  strat_stat      [16],
    input  var logic [31:0]  risk_stat       [8],
    input  var logic [31:0]  risk_reject_cnt [N_RISK_REASONS],
    input  var logic [31:0]  order_stat      [16],

    // ── live status ──────────────────────────────────────────────────────────
    input  var logic [2:0]   link_up,        // {oe, md_b, md_a}
    input  var logic         kill_active,
    input  var kill_src_e    kill_src,

    // ── read port for the CSR block (core_clk; CDC lives in host_ctrl) ───────
    input  var logic [15:0]  raddr,
    output var logic [31:0]  rdata
);

    localparam int unsigned IDX_W = $clog2(N_BUCKETS);
    localparam int unsigned SUM_W = LAT_CNT_W + LAT_DELTA_W;

    // Region bases, truncated to the 8 bits the decoder actually compares.
    localparam logic [7:0] A_MD     = TELEM_A_MD_MAC[7:0];
    localparam logic [7:0] A_OE     = TELEM_A_OE_MAC[7:0];
    localparam logic [7:0] A_NET    = TELEM_A_NET[7:0];
    localparam logic [7:0] A_FEED   = TELEM_A_FEED[7:0];
    localparam logic [7:0] A_BOOK   = TELEM_A_BOOK[7:0];
    localparam logic [7:0] A_STRAT  = TELEM_A_STRAT[7:0];
    localparam logic [7:0] A_RISK   = TELEM_A_RISK[7:0];
    localparam logic [7:0] A_REJECT = TELEM_A_REJECT[7:0];
    localparam logic [7:0] A_ORDER  = TELEM_A_ORDER[7:0];
    localparam logic [7:0] A_HIST   = TELEM_A_HIST[7:0];

    // =========================================================================
    // 1. Latency sample pipeline
    // -----------------------------------------------------------------------------
    // cycle_cnt and lat_start are captured TOGETHER so the delta is taken
    // against the counter value at the instant of the sample. The counter is
    // free-running and never reset after release, so an unsigned subtraction is
    // correct across wrap — never compare absolute values, only deltas
    // (manuals/05-optimization/04-measurement-and-profiling.md §5.1).
    // =========================================================================
    logic   lv_q;
    cycle_t ls_q;
    cycle_t cc_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            lv_q <= 1'b0;
        end else begin
            lv_q <= lat_valid;
        end
        ls_q <= lat_start;   // datapath: qualified by lv_q, no reset needed
        cc_q <= cycle_cnt;
    end

    cycle_t                  delta48;
    logic                    delta_ovf;
    logic                    lv2_q;
    logic [LAT_DELTA_W-1:0]  delta_q;

    always_comb begin
        delta48   = cc_q - ls_q;                       // wraps correctly
        delta_ovf = (delta48[CYCLE_CNT_W-1:LAT_DELTA_W] != '0);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            lv2_q <= 1'b0;
        end else begin
            lv2_q <= lv_q;
        end
        // Saturate rather than truncate: a truncated delta reports a large
        // latency as a small one, which is the single most dangerous way an
        // instrument can lie.
        delta_q <= delta_ovf ? {LAT_DELTA_W{1'b1}} : delta48[LAT_DELTA_W-1:0];
    end

    // =========================================================================
    // 2. Address pipeline, snapshot and clear pulses
    // -----------------------------------------------------------------------------
    // fpga_top's telemetry instantiation carries no write strobe and no control
    // port, so the snapshot and histogram-clear controls are encoded as
    // address transitions. The CSR parks raddr at TELEM_A_IDLE between reads,
    // which guarantees a transition per access and therefore exactly one pulse.
    // =========================================================================
    logic [15:0] ra_q;
    logic [15:0] ra_q2;

    always_ff @(posedge clk) begin
        if (rst) begin
            ra_q  <= TELEM_A_IDLE;
            ra_q2 <= TELEM_A_IDLE;
        end else begin
            ra_q  <= raddr;
            ra_q2 <= ra_q;
        end
    end

    logic snap_pulse;
    logic hist_clr_pulse;

    always_comb begin
        snap_pulse     = (ra_q == TELEM_A_SNAP)       && (ra_q2 != TELEM_A_SNAP);
        hist_clr_pulse = (ra_q == TELEM_A_HIST_CLEAR) && (ra_q2 != TELEM_A_HIST_CLEAR);
    end

    logic [31:0] snap_seq_q;
    always_ff @(posedge clk) begin
        if (rst)             snap_seq_q <= 32'd0;
        else if (snap_pulse) snap_seq_q <= snap_seq_q + 32'd1;
    end

    // =========================================================================
    // 3. Shadow bank — one-cycle atomic latch of every counter
    // =========================================================================
    logic [31:0] s_md_q     [8];
    logic [31:0] s_oe_q     [4];
    logic [31:0] s_net_q    [8];
    logic [31:0] s_feed_q   [16];
    logic [31:0] s_book_q   [16];
    logic [31:0] s_strat_q  [16];
    logic [31:0] s_risk_q   [8];
    logic [31:0] s_reject_q [N_RISK_REASONS];
    logic [31:0] s_order_q  [16];
    cycle_t      s_cycle_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 8;  i++) s_md_q[i]     <= 32'd0;
            for (int i = 0; i < 4;  i++) s_oe_q[i]     <= 32'd0;
            for (int i = 0; i < 8;  i++) s_net_q[i]    <= 32'd0;
            for (int i = 0; i < 16; i++) s_feed_q[i]   <= 32'd0;
            for (int i = 0; i < 16; i++) s_book_q[i]   <= 32'd0;
            for (int i = 0; i < 16; i++) s_strat_q[i]  <= 32'd0;
            for (int i = 0; i < 8;  i++) s_risk_q[i]   <= 32'd0;
            for (int i = 0; i < int'(N_RISK_REASONS); i++) s_reject_q[i] <= 32'd0;
            for (int i = 0; i < 16; i++) s_order_q[i]  <= 32'd0;
            s_cycle_q <= '0;
        end else if (snap_pulse) begin
            for (int f = 0; f < 2; f++) begin
                for (int i = 0; i < 4; i++) begin
                    s_md_q[f*4 + i] <= md_mac_stat[f][i];
                end
            end
            for (int i = 0; i < 4;  i++) s_oe_q[i]    <= oe_mac_stat[i];
            for (int i = 0; i < 8;  i++) s_net_q[i]   <= net_stat[i];
            for (int i = 0; i < 16; i++) s_feed_q[i]  <= feed_stat[i];
            for (int i = 0; i < 16; i++) s_book_q[i]  <= book_stat[i];
            for (int i = 0; i < 16; i++) s_strat_q[i] <= strat_stat[i];
            for (int i = 0; i < 8;  i++) s_risk_q[i]  <= risk_stat[i];
            for (int i = 0; i < int'(N_RISK_REASONS); i++) begin
                s_reject_q[i] <= risk_reject_cnt[i];
            end
            for (int i = 0; i < 16; i++) s_order_q[i] <= order_stat[i];
            s_cycle_q <= cycle_cnt;
        end
    end

    // =========================================================================
    // 4. Latency histogram
    // -----------------------------------------------------------------------------
    // LOG_MODE=1: 32 buckets over a 24-bit delta. Bucket k>=1 covers
    // [2^(k-1) .. 2^k - 1] cycles, so buckets 0..24 span the whole 24-bit range
    // and the map CANNOT overflow — the tail is captured for free, which is the
    // entire point (see latency_hist.sv header).
    // =========================================================================
    logic [IDX_W-1:0]         hist_rd_idx;
    logic [LAT_CNT_W-1:0]     hist_count;
    logic [LAT_DELTA_W-1:0]   hist_min;
    logic [LAT_DELTA_W-1:0]   hist_max;
    logic [SUM_W-1:0]         hist_sum;
    logic [LAT_CNT_W-1:0]     hist_n;
    logic [LAT_CNT_W-1:0]     hist_over;
    logic [LAT_DELTA_W-1:0]   hist_last;
    logic                     hist_sat;

    latency_hist #(
        .N_BUCKETS (N_BUCKETS),
        .DELTA_W   (LAT_DELTA_W),
        .CNT_W     (LAT_CNT_W),
        .LOG_MODE  (1'b1)
    ) u_lat_hist (
        .clk           (clk),
        .rst           (rst),
        .sample_valid  (lv2_q),
        .sample_cycles (delta_q),
        .snap          (snap_pulse),
        .clear         (hist_clr_pulse),
        .rd_idx        (hist_rd_idx),
        .rd_count      (hist_count),
        .rd_min        (hist_min),
        .rd_max        (hist_max),
        .rd_sum        (hist_sum),
        .rd_n          (hist_n),
        .rd_over       (hist_over),
        .rd_last       (hist_last),
        .rd_sat        (hist_sat)
    );

    // =========================================================================
    // 5. Read decode
    // =========================================================================
    logic [7:0]  a8;
    logic        hi_zero;
    logic [7:0]  off;
    logic [31:0] status_w;
    logic [31:0] lat_cfg_w;
    logic [31:0] rdata_d;

    always_comb begin
        a8      = ra_q[7:0];
        hi_zero = (ra_q[15:8] == 8'h00);
        off     = 8'h00;

        // ── live status: one word, therefore atomic without a snapshot ───────
        status_w                              = 32'h0000_0000;
        status_w[TELEM_ST_LINK_LSB +: 3]      = link_up;
        status_w[TELEM_ST_KILL_ACTIVE]        = kill_active;
        status_w[TELEM_ST_KILL_SRC_LSB +: 3]  = kill_src;
        // These two reflect the LAST SNAPSHOT, not the live bank — they are
        // warning flags, and a flag that has been true at any point since the
        // last snapshot is the flag the operator needs to see.
        status_w[TELEM_ST_LAT_SAT]            = hist_sat;
        status_w[TELEM_ST_LAT_OVER]           = (hist_over != '0);

        lat_cfg_w = {7'd0, 1'b1, 8'(LAT_DELTA_W), 16'(N_BUCKETS)};

        // Histogram read index tracks the address so rd_count is ready in the
        // same cycle as the rest of the mux.
        hist_rd_idx = IDX_W'(a8 - A_HIST);

        // ── the mux. Default first: unmapped reads a distinctive sentinel, so
        //    a host pointed at the wrong window finds out immediately rather
        //    than believing a bank of zeros. ────────────────────────────────
        rdata_d = TELEM_UNMAPPED;

        if (hi_zero) begin
            if (a8 == TELEM_A_STATUS[7:0]) begin
                rdata_d = status_w;
            end else if (a8 == TELEM_A_UPTIME_LO[7:0]) begin
                rdata_d = s_cycle_q[31:0];
            end else if (a8 == TELEM_A_UPTIME_HI[7:0]) begin
                rdata_d = {16'd0, s_cycle_q[CYCLE_CNT_W-1:32]};
            end else if (a8 == TELEM_A_VERSION[7:0]) begin
                rdata_d = {TELEM_MAP_MAGIC, TELEM_MAP_MAJOR, TELEM_MAP_MINOR};
            end else if (a8 == TELEM_A_SNAP[7:0]) begin
                rdata_d = snap_seq_q + 32'd1;      // seq OF the snapshot taken
            end else if (a8 == TELEM_A_HIST_CLEAR[7:0]) begin
                rdata_d = 32'd0;
            end else if (a8 == TELEM_A_SNAP_SEQ[7:0]) begin
                rdata_d = snap_seq_q;
            end else if (a8 == TELEM_A_LAT_CFG[7:0]) begin
                rdata_d = lat_cfg_w;
            end else if ((a8 >= A_MD) && (a8 < (A_MD + 8'd8))) begin
                off     = a8 - A_MD;
                rdata_d = s_md_q[off[2:0]];
            end else if ((a8 >= A_OE) && (a8 < (A_OE + 8'd4))) begin
                off     = a8 - A_OE;
                rdata_d = s_oe_q[off[1:0]];
            end else if ((a8 >= A_NET) && (a8 < (A_NET + 8'd8))) begin
                off     = a8 - A_NET;
                rdata_d = s_net_q[off[2:0]];
            end else if ((a8 >= A_FEED) && (a8 < (A_FEED + 8'd16))) begin
                off     = a8 - A_FEED;
                rdata_d = s_feed_q[off[3:0]];
            end else if ((a8 >= A_BOOK) && (a8 < (A_BOOK + 8'd16))) begin
                off     = a8 - A_BOOK;
                rdata_d = s_book_q[off[3:0]];
            end else if ((a8 >= A_STRAT) && (a8 < (A_STRAT + 8'd16))) begin
                off     = a8 - A_STRAT;
                rdata_d = s_strat_q[off[3:0]];
            end else if ((a8 >= A_RISK) && (a8 < (A_RISK + 8'd8))) begin
                off     = a8 - A_RISK;
                rdata_d = s_risk_q[off[2:0]];
            end else if ((a8 >= A_REJECT) && (a8 < (A_REJECT + 8'(N_RISK_REASONS)))) begin
                off     = a8 - A_REJECT;
                rdata_d = s_reject_q[off[4:0]];
            end else if ((a8 >= A_ORDER) && (a8 < (A_ORDER + 8'd16))) begin
                off     = a8 - A_ORDER;
                rdata_d = s_order_q[off[3:0]];
            end else if ((a8 >= A_HIST) && (a8 < (A_HIST + 8'(TELEM_HIST_MAX)))) begin
                off     = a8 - A_HIST;
                // Buckets above the built N_BUCKETS read 0, not the sentinel:
                // they are a legitimate part of the reserved map.
                rdata_d = (off < 8'(N_BUCKETS)) ? hist_count : 32'd0;
            end else if (a8 == TELEM_A_LAT_MIN[7:0]) begin
                rdata_d = 32'(hist_min);
            end else if (a8 == TELEM_A_LAT_MAX[7:0]) begin
                rdata_d = 32'(hist_max);
            end else if (a8 == TELEM_A_LAT_SUM_LO[7:0]) begin
                rdata_d = hist_sum[31:0];
            end else if (a8 == TELEM_A_LAT_SUM_HI[7:0]) begin
                rdata_d = 32'(hist_sum[SUM_W-1:32]);
            end else if (a8 == TELEM_A_LAT_N[7:0]) begin
                rdata_d = hist_n;
            end else if (a8 == TELEM_A_LAT_OVER[7:0]) begin
                rdata_d = hist_over;
            end else if (a8 == TELEM_A_LAT_LAST[7:0]) begin
                rdata_d = 32'(hist_last);
            end else begin
                // Reserved words inside the map read 0; only addresses outside
                // the map read the sentinel.
                rdata_d = 32'd0;
            end
        end
    end

    // Registered output (project default). rdata is valid 2 cycles after raddr.
    always_ff @(posedge clk) begin
        if (rst) rdata <= 32'd0;
        else     rdata <= rdata_d;
    end

    // =========================================================================
    // Assertions — simulation only
    // =========================================================================
`ifndef SYNTHESIS
    initial begin
        if (N_BUCKETS > int'(TELEM_HIST_MAX)) begin
            $fatal(1, "telemetry: N_BUCKETS(%0d) exceeds the %0d slots reserved in the address map",
                   N_BUCKETS, TELEM_HIST_MAX);
        end
    end

    // The snapshot is what makes the bank consistent. If the host ever reads a
    // counter word before the first snapshot, it reads zero — which is a
    // meaningful, safe value, but the protocol violation is worth flagging.
    logic snapped_q;
    always_ff @(posedge clk) begin
        if (rst)             snapped_q <= 1'b0;
        else if (snap_pulse) snapped_q <= 1'b1;
    end

    assert property (@(posedge clk) disable iff (rst)
        ((ra_q >= TELEM_A_MD_MAC) && (ra_q <= TELEM_A_LAT_LAST)) |-> snapped_q
    ) else $error("telemetry: counter read at 0x%04h before any SNAP — the value is not coherent",
                  ra_q);

    // The snapshot must capture cycle_cnt at the snapshot instant, so a host
    // that reads UPTIME after two snapshots always sees it advance.
    assert property (@(posedge clk) disable iff (rst)
        snap_pulse |=> (s_cycle_q == $past(cycle_cnt))
    ) else $error("telemetry: UPTIME did not latch at the snapshot instant");

    // A snapshot must be a single-cycle event, never a level.
    assert property (@(posedge clk) disable iff (rst)
        snap_pulse |=> !snap_pulse
    ) else $error("telemetry: snapshot pulse was not one cycle");
`endif

endmodule : telemetry

`default_nettype wire
