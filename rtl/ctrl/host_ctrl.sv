// =============================================================================
// host_ctrl.sv — PCIe control-plane top
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/00-foundations/04-clocking-reset-and-cdc.md  ⚠ ALL of it
//           manuals/04-system-architecture/06-cpu-fpga-partitioning.md
//           manuals/06-operations/03-monitoring-and-telemetry.md
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   The whole slow path. Instantiated by rtl/fpga_top.sv. Contains:
//     * pcie_wrapper   — the only vendor PCIe primitive in the design
//     * csr_regfile    — the BAR-mapped register map (host-software contract)
//     * dma_log_ring   — the compliance audit trail to host memory
//     * EVERY clock-domain crossing between pcie_clk and core_clk
//
//   PCIe is the SLOW PATH ONLY. Nothing latency-critical crosses this boundary
//   (CLAUDE.md §1). This layer is latency-tolerant and correctness-critical: it
//   is how a human arms trading, sets risk limits, and sees what the machine is
//   doing.
//
// -----------------------------------------------------------------------------
// ⚠ CDC INVENTORY — EVERY pcie_clk <-> core_clk CROSSING IN THE DESIGN
//   (manuals/00-foundations/04-clocking-reset-and-cdc.md §3: four sanctioned
//   primitives, nothing else, no hand-rolled synchronizers anywhere.)
//
//  #   signal / bus                     dir           primitive        width
//  --  -------------------------------  ------------  ---------------  -----
//  1   cfg_trading_en                   pcie -> core  cdc_sync_bit(2)   1
//  2   cfg_kill                         pcie -> core  cdc_sync_bit(2)   1
//  3   cfg_heartbeat                    pcie -> core  cdc_pulse         1
//  4   cfg_credit_return                pcie -> core  cdc_pulse         1
//  5   cfg_risk_commit                  pcie -> core  cdc_pulse         1
//  6   cfg_strat_commit                 pcie -> core  cdc_pulse         1
//  7   config write {tgt,addr,data}     pcie -> core  cdc_handshake    51
//  8   telemetry read address           pcie -> core  cdc_handshake    16
//  9   telemetry read data              core -> pcie  cdc_handshake    32
//  10  telemetry STATUS mirror          core -> pcie  cdc_handshake    32
//  11  {kill_active, kill_src}          core -> pcie  cdc_handshake     4
//  12  control-plane audit event        pcie -> core  cdc_handshake    80
//  13  pcie liveness toggle             pcie -> core  cdc_sync_bit(2)   1
//  14  core liveness toggle             core -> pcie  cdc_sync_bit(2)   1
//  15  audit record payload             core -> pcie  async_fifo      512  (in
//                                                                     u_log_ring)
//  16  audit drop count                 core -> pcie  cdc_handshake    32  (in
//                                                                     u_log_ring)
//
//   Design notes on the choices, because the wrong primitive here is the class
//   of bug that passes simulation, passes timing, passes a week of soak, and
//   then corrupts one order in ten million:
//
//   * #1/#2 are slowly-changing LEVELS, held for millions of cycles. 2-FF is
//     correct and cheapest.
//   * #3-#6 are single-cycle PULSES. A 2-FF level synchronizer would MISS them.
//     ⚠ cdc_pulse merges pulses spaced closer than ~2 destination periods, so
//     csr_regfile paces every one of them with an 8-cycle hold-off. For
//     credit_return a merged pulse permanently leaks an in-flight order slot.
//   * #7/#8/#12 are WIDE and INFREQUENT — exactly the handshake's use case. A
//     bus through parallel 2-FF chains is the classic CDC bug: different bits
//     resolve on different cycles and you get a value that never existed.
//   * #11 crosses kill_active AND kill_src TOGETHER through ONE handshake.
//     ⚠ Synchronizing them separately and combining them at the destination is
//     RECONVERGENCE (manual §7): you would momentarily latch "killed" with a
//     stale source, and the sticky provenance register — the thing you read
//     after an incident — would name the wrong cause.
//   * #15 is high-rate multi-bit data: gray-coded async FIFO, the default for
//     any bus crossing.
//
//   ⚠ Constrain these in constraints/cdc.xdc with `set_max_delay
//     -datapath_only` plus `set_bus_skew` on every handshake data bus. NEVER
//     `set_false_path` a CDC bus: the router will then happily place one bit
//     8 ns away and another 0.5 ns away, and handshake-protected data gets
//     captured torn (manual §5).
//
// -----------------------------------------------------------------------------
// ⚠ THE FROZEN-CLOCK HAZARD, AND WHY #13 EXISTS
//
//   cfg_trading_en and cfg_kill are LEVELS crossed by 2-FF synchronizers. If
//   pcie_clk stops — host power loss, PERST# assertion, surprise link down, a
//   crashed refclk source — those synchronizers simply hold their last value.
//   The card would sit there with cfg_trading_en = 1 and cfg_kill = 0, armed,
//   trading, with no host on the other end and no way for anyone to stop it.
//
//   That is the worst failure mode this block can have, and no amount of
//   correct synchronizer design prevents it: a 2-FF synchronizer faithfully
//   holds a value whose source has died.
//
//   Mitigation: the pcie domain emits a free-running toggle (#13). The CORE
//   domain watches it. If the toggle stops for PCIE_DEAD_CYCLES core clocks,
//   `pcie_dead` asserts and, in the core domain, independently of anything on
//   the PCIe side:
//       cfg_kill        is forced to 1
//       cfg_trading_en  is forced to 0
//       cfg_heartbeat   stops, so risk_gate's own watchdog also fires
//   This is the same reasoning as the host watchdog: the fabric must be able to
//   fail safe by itself, with no functioning host and no human present.
//
//   #14 is the mirror image so the host can see that the core domain is alive;
//   csr_regfile disarms if it is not.
//
// -----------------------------------------------------------------------------
// ⚠ OPEN CONTRACT GAP — FAST-PATH AUDIT RECORDS
//
//   dma_log_ring is instantiated here and is fed with CONTROL-PLANE records
//   (arm, disarm, kill assert/clear with provenance, parameter commit with
//   checksum and generation, watchdog fire, trading enable/disable). Those are
//   real compliance records and they are complete.
//
//   The FAST-PATH records — every order decision, every fill, every risk
//   rejection — originate at u_risk_gate and u_order_gw in rtl/fpga_top.sv, and
//   the host_ctrl port list in the current fpga_top.sv carries no path for
//   them. Wiring them requires ONE additive change to fpga_top:
//
//       output/input added to host_ctrl:
//           input  var logic     log_valid,   // from an arbiter over the
//           input  var log_rec_t log_rec,     //   risk gate + order gateway
//           input  var cycle_t   cycle_cnt    // the global counter (see below)
//
//       and in fpga_top, an arbiter muxing:
//           u_risk_gate : order emitted / order rejected (reason = risk_reason_e)
//           u_order_gw  : fill / venue ack / venue reject
//
//   Until that lands, the DMA ring carries control-plane records only, and the
//   CAT trail is INCOMPLETE. This is stated here rather than papered over,
//   because a partial audit trail that looks complete is worse than none.
//   See rtl/ctrl/README.md §"Open items".
//
// -----------------------------------------------------------------------------
// LATENCY  : Slow path. Config write pcie->core: ~8 pcie + ~6 core cycles.
//            Telemetry read round trip: ~25 pcie cycles typical, bounded by
//            csr_regfile's TELEM_TIMEOUT.
//            ⚠ NOTHING here is on the tick-to-trade path. The kill switch is
//            NOT gated on this module's latency: risk_gate enforces the
//            KILL_RESP_CYCLES bound in the core domain from cfg_kill, which is
//            a level and therefore live within 2 core cycles of the crossing.
// RESOURCE : est. LUT ~6.5 k, FF ~7 k, BRAM 8 (the audit FIFO), DSP 0, plus the
//            PCIe hard block. ≈0.6 % of a VU9P SLR.
// =============================================================================
`default_nettype none

module host_ctrl
    import trading_pkg::*;
    import telemetry_pkg::*;
#(
    parameter logic [31:0] BUILD_ID        = 32'hDEAD_0000,
    parameter logic [31:0] GIT_SHA         = 32'h0000_0000,
    parameter logic [31:0] BUILD_TIMESTAMP = 32'h0000_0000,
    parameter int unsigned N_LANES         = 16,
    parameter int unsigned PCIE_CLK_MHZ    = 250,
    // Core cycles without a pcie liveness toggle before the fabric declares the
    // host side dead and fails closed. The toggle period is 2^8 pcie cycles
    // (~1.0 us at 250 MHz), so 2^13 core cycles (~52 us at 156.25 MHz) is ~50
    // missed toggles — far outside any plausible jitter, far inside any human
    // or market timescale.
    parameter int unsigned PCIE_DEAD_LOG2  = 13,
    parameter int unsigned CORE_DEAD_LOG2  = 13
) (
    // ── PCIe physical + user clock ───────────────────────────────────────────
    input  var logic         pcie_clk,
    input  var logic         pcie_rst,
    input  var logic         pcie_refclk_p,
    input  var logic         pcie_refclk_n,
    input  var logic         pcie_rst_n,
    input  var logic [15:0]  pcie_rx_p,
    input  var logic [15:0]  pcie_rx_n,
    output var logic [15:0]  pcie_tx_p,
    output var logic [15:0]  pcie_tx_n,

    // ── core-clock side. ALL CDC LIVES INSIDE THIS MODULE. ──────────────────
    input  var logic         core_clk,
    input  var logic         core_rst,

    output var logic         cfg_trading_en,
    output var logic         cfg_kill,
    output var logic         cfg_heartbeat,
    output var logic         cfg_credit_return,

    output var logic         cfg_filter_wr,
    output var logic [15:0]  cfg_filter_addr,
    output var logic [31:0]  cfg_filter_data,

    output var logic         cfg_risk_wr,
    output var logic [15:0]  cfg_risk_addr,
    output var logic [31:0]  cfg_risk_data,
    output var logic         cfg_risk_commit,

    output var logic         cfg_strat_wr,
    output var logic [15:0]  cfg_strat_addr,
    output var logic [31:0]  cfg_strat_data,
    output var logic         cfg_strat_commit,

    output var logic         cfg_tmpl_wr,
    output var logic [15:0]  cfg_tmpl_addr,
    output var logic [31:0]  cfg_tmpl_data,

    output var logic         cfg_session_wr,
    output var logic [31:0]  cfg_session_data,

    // ── telemetry read port (core domain) ───────────────────────────────────
    output var logic [15:0]  telem_raddr,
    input  var logic [31:0]  telem_rdata,

    // ── fabric kill state (core domain) ─────────────────────────────────────
    input  var logic         kill_active,
    input  var kill_src_e    kill_src
);

    localparam int unsigned BAR_ADDR_W = 16;
    localparam int unsigned DMA_W      = 512;
    localparam int unsigned EVT_W_BITS = 8 + 8 + 32 + 32;   // 80
    localparam int unsigned CFG_W_BITS = 3 + 16 + 32;       // 51

    // Telemetry read latency, in core cycles, from raddr change to rdata valid.
    // telemetry.sv registers the address then registers the mux output => 2.
    // One extra cycle of margin so a future pipeline stage there does not
    // silently corrupt every telemetry read.
    localparam int unsigned TELEM_RD_LAT = 3;

    // =========================================================================
    // Local core-clock cycle counter
    // -----------------------------------------------------------------------------
    // ⚠ Why this is EXACT and not an approximation of fpga_top's cycle_cnt:
    //   both counters reset to zero on the same core_rst, are clocked by the
    //   same core_clk, and increment unconditionally every cycle. They are
    //   therefore bit-identical at every instant, so a timestamp taken here is
    //   directly comparable with book_evt_t.rx_cycle and order_out_t.rx_cycle.
    //   If fpga_top ever gates or re-seeds its counter, this stops being true
    //   and cycle_cnt must become a port (see the OPEN CONTRACT GAP above).
    // =========================================================================
    cycle_t log_cycle_q;
    always_ff @(posedge core_clk) begin
        if (core_rst) log_cycle_q <= '0;
        else          log_cycle_q <= log_cycle_q + 1'b1;
    end

    // =========================================================================
    // PCIe hard block / simulation stub
    // =========================================================================
    logic [BAR_ADDR_W-1:0] reg_addr;
    logic [31:0]           reg_wdata;
    logic                  reg_we;
    logic                  reg_re;
    logic [31:0]           reg_rdata;
    logic                  reg_rvalid;

    logic                  dma_wr_valid;
    logic                  dma_wr_ready;
    logic [63:0]           dma_wr_addr;
    logic [DMA_W-1:0]      dma_wr_data;
    logic                  dma_wr_last;

    logic                  pcie_link_up;
    logic [2:0]            pcie_link_speed;
    logic [5:0]            pcie_link_width;
    logic [31:0]           pcie_err_cnt;

    pcie_wrapper #(
        .N_LANES    (N_LANES),
        .BAR_ADDR_W (BAR_ADDR_W),
        .DMA_W      (DMA_W)
    ) u_pcie (
        .pcie_refclk_p (pcie_refclk_p),
        .pcie_refclk_n (pcie_refclk_n),
        .pcie_rst_n    (pcie_rst_n),
        .pcie_rx_p     (pcie_rx_p),
        .pcie_rx_n     (pcie_rx_n),
        .pcie_tx_p     (pcie_tx_p),
        .pcie_tx_n     (pcie_tx_n),
        .pcie_clk      (pcie_clk),
        .pcie_rst      (pcie_rst),
        .reg_addr      (reg_addr),
        .reg_wdata     (reg_wdata),
        .reg_we        (reg_we),
        .reg_re        (reg_re),
        .reg_rdata     (reg_rdata),
        .reg_rvalid    (reg_rvalid),
        .dma_wr_valid  (dma_wr_valid),
        .dma_wr_ready  (dma_wr_ready),
        .dma_wr_addr   (dma_wr_addr),
        .dma_wr_data   (dma_wr_data),
        .dma_wr_last   (dma_wr_last),
        .link_up       (pcie_link_up),
        .link_speed    (pcie_link_speed),
        .link_width    (pcie_link_width),
        .pcie_err_cnt  (pcie_err_cnt)
    );

    // =========================================================================
    // CDC #13/#14 — liveness toggles in both directions
    // =========================================================================
    logic [7:0] pcie_hb_ctr_q;
    logic       pcie_hb_tog_q;

    always_ff @(posedge pcie_clk) begin
        if (pcie_rst) begin
            pcie_hb_ctr_q <= 8'd0;
            pcie_hb_tog_q <= 1'b0;
        end else begin
            pcie_hb_ctr_q <= pcie_hb_ctr_q + 8'd1;
            if (pcie_hb_ctr_q == 8'hFF) pcie_hb_tog_q <= ~pcie_hb_tog_q;
        end
    end

    logic pcie_hb_core;
    cdc_sync_bit #(.STAGES(2)) u_pcie_hb_sync (
        .dst_clk (core_clk),
        .src_bit (pcie_hb_tog_q),
        .dst_bit (pcie_hb_core)
    );

    logic                       pcie_hb_core_q;
    logic [PCIE_DEAD_LOG2-1:0]  pcie_dead_ctr_q;
    logic                       pcie_dead_q;

    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            pcie_hb_core_q  <= 1'b0;
            pcie_dead_ctr_q <= '0;
            pcie_dead_q     <= 1'b1;      // ⚠ assume dead until proven alive
        end else begin
            pcie_hb_core_q <= pcie_hb_core;
            if (pcie_hb_core != pcie_hb_core_q) begin
                pcie_dead_ctr_q <= '0;
                pcie_dead_q     <= 1'b0;
            end else if (pcie_dead_ctr_q == '1) begin
                pcie_dead_q <= 1'b1;      // ⚠ FAIL CLOSED
            end else begin
                pcie_dead_ctr_q <= pcie_dead_ctr_q + 1'b1;
            end
        end
    end

    logic [7:0] core_hb_ctr_q;
    logic       core_hb_tog_q;

    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            core_hb_ctr_q <= 8'd0;
            core_hb_tog_q <= 1'b0;
        end else begin
            core_hb_ctr_q <= core_hb_ctr_q + 8'd1;
            if (core_hb_ctr_q == 8'hFF) core_hb_tog_q <= ~core_hb_tog_q;
        end
    end

    logic core_hb_pcie;
    cdc_sync_bit #(.STAGES(2)) u_core_hb_sync (
        .dst_clk (pcie_clk),
        .src_bit (core_hb_tog_q),
        .dst_bit (core_hb_pcie)
    );

    logic                      core_hb_pcie_q;
    logic [CORE_DEAD_LOG2-1:0] core_dead_ctr_q;
    logic                      core_alive_q;

    always_ff @(posedge pcie_clk) begin
        if (pcie_rst) begin
            core_hb_pcie_q  <= 1'b0;
            core_dead_ctr_q <= '0;
            core_alive_q    <= 1'b0;      // ⚠ not alive until proven
        end else begin
            core_hb_pcie_q <= core_hb_pcie;
            if (core_hb_pcie != core_hb_pcie_q) begin
                core_dead_ctr_q <= '0;
                core_alive_q    <= 1'b1;
            end else if (core_dead_ctr_q == '1) begin
                core_alive_q <= 1'b0;
            end else begin
                core_dead_ctr_q <= core_dead_ctr_q + 1'b1;
            end
        end
    end

    // =========================================================================
    // CSR register file (pcie domain)
    // =========================================================================
    logic        csr_trading_en;
    logic        csr_kill;
    logic        csr_hb_pulse;
    logic        csr_credit_pulse;
    logic        csr_rcommit_pulse;
    logic        csr_scommit_pulse;
    logic        csr_counters_rst;

    logic        cfg_wr_valid;
    logic        cfg_wr_ready;
    cfg_target_e cfg_wr_target;
    logic [15:0] cfg_wr_addr_p;
    logic [31:0] cfg_wr_data_p;

    logic        telem_req;
    logic [15:0] telem_addr_p;
    logic        telem_ack;
    logic [31:0] telem_data_p;

    logic        kill_active_s;
    logic [2:0]  kill_src_s;
    logic [31:0] core_status_s;

    logic        ring_en;
    logic [63:0] ring_base;
    logic [4:0]  ring_size_log2;
    logic [31:0] ring_tail;
    logic        ring_clr_sticky;
    logic [31:0] ring_head;
    logic [31:0] ring_drop_cnt;
    logic        ring_drop_sticky;
    logic [31:0] ring_full_cnt;
    logic [31:0] ring_rec_cnt;

    logic        evt_valid;
    logic        evt_ready;
    logic [7:0]  evt_type;
    logic [7:0]  evt_reason;
    logic [31:0] evt_aux0;
    logic [31:0] evt_aux1;

    logic        watchdog_expired;
    logic [2:0]  arm_state;

    csr_regfile #(
        .BUILD_ID        (BUILD_ID),
        .GIT_SHA         (GIT_SHA),
        .BUILD_TIMESTAMP (BUILD_TIMESTAMP),
        .BAR_ADDR_W      (BAR_ADDR_W),
        .PCIE_CLK_MHZ    (PCIE_CLK_MHZ)
    ) u_csr (
        .clk                (pcie_clk),
        .rst                (pcie_rst),
        .reg_addr           (reg_addr),
        .reg_wdata          (reg_wdata),
        .reg_we             (reg_we),
        .reg_re             (reg_re),
        .reg_rdata          (reg_rdata),
        .reg_rvalid         (reg_rvalid),
        .trading_en         (csr_trading_en),
        .kill               (csr_kill),
        .hb_pulse           (csr_hb_pulse),
        .credit_ret_pulse   (csr_credit_pulse),
        .risk_commit_pulse  (csr_rcommit_pulse),
        .strat_commit_pulse (csr_scommit_pulse),
        .counters_rst_pulse (csr_counters_rst),
        .cfg_wr_valid       (cfg_wr_valid),
        .cfg_wr_ready       (cfg_wr_ready),
        .cfg_wr_target      (cfg_wr_target),
        .cfg_wr_addr        (cfg_wr_addr_p),
        .cfg_wr_data        (cfg_wr_data_p),
        .telem_req          (telem_req),
        .telem_addr         (telem_addr_p),
        .telem_ack          (telem_ack),
        .telem_data         (telem_data_p),
        .kill_active_s      (kill_active_s),
        .kill_src_s         (kill_src_s),
        .core_status_s      (core_status_s),
        .core_alive         (core_alive_q),
        .pcie_link_up       (pcie_link_up),
        .ring_en            (ring_en),
        .ring_base          (ring_base),
        .ring_size_log2     (ring_size_log2),
        .ring_tail          (ring_tail),
        .ring_clr_sticky    (ring_clr_sticky),
        .ring_head          (ring_head),
        .ring_drop_cnt      (ring_drop_cnt),
        .ring_drop_sticky   (ring_drop_sticky),
        .ring_full_cnt      (ring_full_cnt),
        .ring_rec_cnt       (ring_rec_cnt),
        .evt_valid          (evt_valid),
        .evt_ready          (evt_ready),
        .evt_type           (evt_type),
        .evt_reason         (evt_reason),
        .evt_aux0           (evt_aux0),
        .evt_aux1           (evt_aux1),
        .watchdog_expired   (watchdog_expired),
        .arm_state_o        (arm_state)
    );

    // =========================================================================
    // CDC #1/#2 — level controls, pcie -> core
    // -----------------------------------------------------------------------------
    // ⚠ Both are gated in the CORE domain by pcie_dead and by core_rst, so the
    //   fail-closed state does not depend on the PCIe side being alive, and
    //   holds in the SAME cycle core_rst asserts (fpga_top asserts exactly
    //   that: core_rst |-> !cfg_trading_en).
    // =========================================================================
    logic trading_en_core;
    logic kill_core;

    cdc_sync_bit #(.STAGES(2)) u_trading_sync (
        .dst_clk (core_clk),
        .src_bit (csr_trading_en),
        .dst_bit (trading_en_core)
    );

    cdc_sync_bit #(.STAGES(2)) u_kill_sync (
        .dst_clk (core_clk),
        .src_bit (csr_kill),
        .dst_bit (kill_core)
    );

    logic trading_en_q;
    logic kill_q;

    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            trading_en_q <= 1'b0;         // ⚠ SAFE VALUE
            kill_q       <= 1'b1;         // ⚠ SAFE VALUE
        end else begin
            trading_en_q <= trading_en_core && !pcie_dead_q;
            kill_q       <= kill_core     ||  pcie_dead_q;
        end
    end

    // Combinational reset/dead override on top of a registered value. Justified
    // exception to the registered-output rule: the fail-closed property must
    // hold in the same cycle the condition appears, not one cycle later.
    assign cfg_trading_en = trading_en_q && !core_rst && !pcie_dead_q;
    assign cfg_kill       = kill_q       ||  core_rst ||  pcie_dead_q;

    // =========================================================================
    // CDC #3-#6 — control pulses, pcie -> core
    // =========================================================================
    logic hb_core_pulse;
    logic credit_core_pulse;
    logic rcommit_core_pulse;
    logic scommit_core_pulse;

    cdc_pulse u_hb_pulse (
        .src_clk   (pcie_clk),
        .src_rst   (pcie_rst),
        .src_pulse (csr_hb_pulse),
        .dst_clk   (core_clk),
        .dst_rst   (core_rst),
        .dst_pulse (hb_core_pulse)
    );

    cdc_pulse u_credit_pulse (
        .src_clk   (pcie_clk),
        .src_rst   (pcie_rst),
        .src_pulse (csr_credit_pulse),
        .dst_clk   (core_clk),
        .dst_rst   (core_rst),
        .dst_pulse (credit_core_pulse)
    );

    cdc_pulse u_rcommit_pulse (
        .src_clk   (pcie_clk),
        .src_rst   (pcie_rst),
        .src_pulse (csr_rcommit_pulse),
        .dst_clk   (core_clk),
        .dst_rst   (core_rst),
        .dst_pulse (rcommit_core_pulse)
    );

    cdc_pulse u_scommit_pulse (
        .src_clk   (pcie_clk),
        .src_rst   (pcie_rst),
        .src_pulse (csr_scommit_pulse),
        .dst_clk   (core_clk),
        .dst_rst   (core_rst),
        .dst_pulse (scommit_core_pulse)
    );

    // ⚠ The heartbeat is suppressed when the PCIe side is dead, so risk_gate's
    //   own watchdog fires independently of anything decided here.
    assign cfg_heartbeat     = hb_core_pulse      && !core_rst && !pcie_dead_q;
    assign cfg_credit_return = credit_core_pulse  && !core_rst;
    assign cfg_risk_commit   = rcommit_core_pulse && !core_rst;
    assign cfg_strat_commit  = scommit_core_pulse && !core_rst;

    // =========================================================================
    // CDC #7 — config writes, pcie -> core
    // -----------------------------------------------------------------------------
    // ONE handshake carries all five targets, serialized. That is deliberate:
    // five parallel crossings would be five reconvergence opportunities, and
    // serializing makes the ordering between a parameter write and its commit
    // pulse structural rather than a host-timing assumption.
    // =========================================================================
    logic [CFG_W_BITS-1:0] cfg_dst_data;
    logic                  cfg_dst_valid;

    cdc_handshake #(
        .W (CFG_W_BITS)
    ) u_cfg_cdc (
        .src_clk   (pcie_clk),
        .src_rst   (pcie_rst),
        .src_data  ({cfg_wr_target, cfg_wr_addr_p, cfg_wr_data_p}),
        .src_valid (cfg_wr_valid),
        .src_ready (cfg_wr_ready),
        .dst_clk   (core_clk),
        .dst_rst   (core_rst),
        .dst_data  (cfg_dst_data),
        .dst_valid (cfg_dst_valid)
    );

    cfg_target_e cfg_dst_target;
    logic [15:0] cfg_dst_addr;
    logic [31:0] cfg_dst_wdata;

    always_comb begin
        cfg_dst_target = cfg_target_e'(cfg_dst_data[50:48]);
        cfg_dst_addr   = cfg_dst_data[47:32];
        cfg_dst_wdata  = cfg_dst_data[31:0];
    end

    // Fan-out. All five address/data buses carry the same captured word; each
    // is qualified by its own write strobe, which is the only thing a consumer
    // may look at.
    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            cfg_filter_wr  <= 1'b0;
            cfg_risk_wr    <= 1'b0;
            cfg_strat_wr   <= 1'b0;
            cfg_tmpl_wr    <= 1'b0;
            cfg_session_wr <= 1'b0;
        end else begin
            cfg_filter_wr  <= 1'b0;
            cfg_risk_wr    <= 1'b0;
            cfg_strat_wr   <= 1'b0;
            cfg_tmpl_wr    <= 1'b0;
            cfg_session_wr <= 1'b0;
            if (cfg_dst_valid) begin
                unique case (cfg_dst_target)
                    CFG_TGT_FILTER:  cfg_filter_wr  <= 1'b1;
                    CFG_TGT_RISK:    cfg_risk_wr    <= 1'b1;
                    CFG_TGT_STRAT:   cfg_strat_wr   <= 1'b1;
                    CFG_TGT_TMPL:    cfg_tmpl_wr    <= 1'b1;
                    CFG_TGT_SESSION: cfg_session_wr <= 1'b1;
                    default:         ;   // CFG_TGT_NONE: silently ignored — the
                                         // CSR never emits it
                endcase
            end
        end
    end

    always_ff @(posedge core_clk) begin
        // Datapath registers: qualified by the strobes above, no reset needed.
        if (cfg_dst_valid) begin
            cfg_filter_addr  <= cfg_dst_addr;
            cfg_filter_data  <= cfg_dst_wdata;
            cfg_risk_addr    <= cfg_dst_addr;
            cfg_risk_data    <= cfg_dst_wdata;
            cfg_strat_addr   <= cfg_dst_addr;
            cfg_strat_data   <= cfg_dst_wdata;
            cfg_tmpl_addr    <= cfg_dst_addr;
            cfg_tmpl_data    <= cfg_dst_wdata;
            cfg_session_data <= cfg_dst_wdata;
        end
    end

    // =========================================================================
    // CDC #8/#9/#10 — telemetry read proxy and the STATUS mirror
    // -----------------------------------------------------------------------------
    // One core-side arbiter owns telem_raddr. Two clients: the host read
    // (higher priority) and a background refresh of the telemetry STATUS word
    // that keeps csr_regfile's STATUS register a genuine single-access read.
    //
    // ⚠ telem_raddr is parked at TELEM_A_IDLE between accesses. telemetry.sv
    //   derives its snapshot and histogram-clear side effects from ADDRESS
    //   TRANSITIONS (it has no write strobe in the fpga_top contract), so the
    //   parking is not cosmetic — without it a snapshot would fire once and
    //   then never again, and every subsequent scrape would return the same
    //   frozen bank.
    // =========================================================================
    logic [15:0] telem_addr_core;
    logic        telem_req_core;

    cdc_handshake #(
        .W (16)
    ) u_telem_req_cdc (
        .src_clk   (pcie_clk),
        .src_rst   (pcie_rst),
        .src_data  (telem_addr_p),
        .src_valid (telem_req),
        .src_ready (/* unused: csr_regfile issues one read at a time */),
        .dst_clk   (core_clk),
        .dst_rst   (core_rst),
        .dst_data  (telem_addr_core),
        .dst_valid (telem_req_core)
    );

    typedef enum logic [1:0] {
        TA_IDLE  = 2'd0,
        TA_DRIVE = 2'd1,
        TA_WAIT  = 2'd2,
        TA_DONE  = 2'd3
    } ta_state_e;

    ta_state_e   ta_state_q;
    logic [15:0] ta_addr_q;
    logic        ta_is_host_q;
    logic [2:0]  ta_wait_q;
    logic [31:0] ta_data_q;
    logic [31:0] ret_hold_q;
    logic        ta_host_done;
    logic        ta_mirror_done;

    // Background refresh tick: ~2^12 core cycles (~26 us). Fast enough that the
    // host never sees a stale link state, slow enough to be invisible.
    logic [11:0] mirror_ctr_q;
    logic        mirror_tick;
    logic        mirror_pend_q;

    always_ff @(posedge core_clk) begin
        if (core_rst) mirror_ctr_q <= '0;
        else          mirror_ctr_q <= mirror_ctr_q + 1'b1;
    end
    assign mirror_tick = (mirror_ctr_q == '1);

    logic        host_pend_q;
    logic [15:0] host_addr_q;

    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            ta_state_q     <= TA_IDLE;
            ta_addr_q      <= TELEM_A_IDLE;
            ta_is_host_q   <= 1'b0;
            ta_wait_q      <= 3'd0;
            ta_data_q      <= 32'd0;
            ret_hold_q     <= 32'd0;
            ta_host_done   <= 1'b0;
            ta_mirror_done <= 1'b0;
            telem_raddr    <= TELEM_A_IDLE;
            host_pend_q    <= 1'b0;
            host_addr_q    <= TELEM_A_IDLE;
            mirror_pend_q  <= 1'b0;
        end else begin
            ta_host_done   <= 1'b0;
            ta_mirror_done <= 1'b0;

            if (telem_req_core) begin
                host_pend_q <= 1'b1;
                host_addr_q <= telem_addr_core;
            end
            if (mirror_tick) mirror_pend_q <= 1'b1;

            unique case (ta_state_q)
                TA_IDLE: begin
                    telem_raddr <= TELEM_A_IDLE;
                    if (host_pend_q) begin
                        ta_addr_q    <= host_addr_q;
                        ta_is_host_q <= 1'b1;
                        host_pend_q  <= 1'b0;
                        ta_state_q   <= TA_DRIVE;
                    end else if (mirror_pend_q) begin
                        ta_addr_q     <= TELEM_A_STATUS;
                        ta_is_host_q  <= 1'b0;
                        mirror_pend_q <= 1'b0;
                        ta_state_q    <= TA_DRIVE;
                    end
                end

                TA_DRIVE: begin
                    telem_raddr <= ta_addr_q;
                    ta_wait_q   <= 3'd0;
                    ta_state_q  <= TA_WAIT;
                end

                TA_WAIT: begin
                    if (ta_wait_q == 3'(TELEM_RD_LAT)) begin
                        ta_data_q  <= telem_rdata;
                        ta_state_q <= TA_DONE;
                    end else begin
                        ta_wait_q <= ta_wait_q + 3'd1;
                    end
                end

                TA_DONE: begin
                    telem_raddr <= TELEM_A_IDLE;
                    if (ta_is_host_q) begin
                        // ⚠ Latch into a dedicated hold register. ta_data_q is
                        //   shared with the background mirror read, which can
                        //   start again within a few cycles and would otherwise
                        //   move the handshake's data bus mid-transfer.
                        ret_hold_q   <= ta_data_q;
                        ta_host_done <= 1'b1;
                    end else begin
                        ta_mirror_done <= 1'b1;
                    end
                    ta_state_q <= TA_IDLE;
                end

                default: ta_state_q <= TA_IDLE;
            endcase
        end
    end

    cdc_handshake #(
        .W (32)
    ) u_telem_ret_cdc (
        .src_clk   (core_clk),
        .src_rst   (core_rst),
        .src_data  (ret_hold_q),
        .src_valid (ta_host_done),
        .src_ready (/* unused: one outstanding read by construction */),
        .dst_clk   (pcie_clk),
        .dst_rst   (pcie_rst),
        .dst_data  (telem_data_p),
        .dst_valid (telem_ack)
    );

    logic [31:0] mirror_data_q;
    always_ff @(posedge core_clk) begin
        if (core_rst)            mirror_data_q <= 32'd0;
        else if (ta_mirror_done) mirror_data_q <= ta_data_q;
    end

    cdc_handshake #(
        .W (32)
    ) u_mirror_cdc (
        .src_clk   (core_clk),
        .src_rst   (core_rst),
        .src_data  (mirror_data_q),
        .src_valid (ta_mirror_done),
        .src_ready (/* unused: refresh period >> handshake round trip */),
        .dst_clk   (pcie_clk),
        .dst_rst   (pcie_rst),
        .dst_data  (core_status_s),
        .dst_valid (/* level: core_status_s holds its last value */)
    );

    // =========================================================================
    // CDC #11 — {kill_active, kill_src}, core -> pcie, AS A PAIR
    // -----------------------------------------------------------------------------
    // ⚠ Crossing these separately and recombining them would be reconvergence:
    //   the pcie side would momentarily see "killed" alongside a stale source,
    //   and csr_regfile's sticky provenance register — the register you read
    //   after an incident to find out WHY — would latch the wrong cause.
    //   One handshake, one atomic pair, always consistent.
    //
    //   Re-issued whenever the pair changes, plus a periodic refresh so the
    //   pcie side always converges. A pulse shorter than the handshake round
    //   trip can be missed; kill_active is a latched condition in risk_gate, so
    //   that is acceptable, and risk_gate's own counters record the truth.
    // =========================================================================
    logic [3:0] kill_pair;
    logic [3:0] kill_pair_d_q;      // previous value, for edge detection
    logic [3:0] kill_pair_hold_q;   // ⚠ the handshake payload: latched at send
    logic       kill_pair_send;
    logic       kill_pair_pend_q;
    logic       kill_pair_ready;

    assign kill_pair = {kill_active, kill_src};

    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            kill_pair_d_q    <= 4'b1000;   // ⚠ killed, source NONE, until told
            kill_pair_hold_q <= 4'b1000;
            kill_pair_pend_q <= 1'b1;
            kill_pair_send   <= 1'b0;
        end else begin
            kill_pair_send <= 1'b0;
            kill_pair_d_q  <= kill_pair;
            if ((kill_pair != kill_pair_d_q) || mirror_tick) begin
                kill_pair_pend_q <= 1'b1;
            end
            if (kill_pair_pend_q && kill_pair_ready && !kill_pair_send) begin
                // ⚠ The payload is latched on the SAME edge that raises
                //   src_valid and does not move again until the next accepted
                //   transfer. The handshake protocol requires the data bus to
                //   be stable for the whole transfer — it is never
                //   synchronized, only constrained (manual 00.04 §3.4).
                kill_pair_hold_q <= kill_pair;
                kill_pair_send   <= 1'b1;
                kill_pair_pend_q <= 1'b0;
            end
        end
    end

    logic [3:0] kill_pair_pcie;

    cdc_handshake #(
        .W (4)
    ) u_killpair_cdc (
        .src_clk   (core_clk),
        .src_rst   (core_rst),
        .src_data  (kill_pair_hold_q),
        .src_valid (kill_pair_send),
        .src_ready (kill_pair_ready),
        .dst_clk   (pcie_clk),
        .dst_rst   (pcie_rst),
        .dst_data  (kill_pair_pcie),
        .dst_valid (/* level: holds its last value */)
    );

    assign kill_active_s = kill_pair_pcie[3];
    assign kill_src_s    = kill_pair_pcie[2:0];

    // =========================================================================
    // CDC #12 — control-plane audit events, pcie -> core
    // -----------------------------------------------------------------------------
    // Crossed into the CORE domain so every audit record — control-plane and
    // fast-path alike — is timestamped from the SAME free-running core counter
    // and lands in the SAME ordered ring. Two timebases in one audit file is
    // an unresolvable ambiguity at exactly the moment you need the file.
    // =========================================================================
    logic [EVT_W_BITS-1:0] evt_dst_data;
    logic                  evt_dst_valid;

    cdc_handshake #(
        .W (EVT_W_BITS)
    ) u_evt_cdc (
        .src_clk   (pcie_clk),
        .src_rst   (pcie_rst),
        .src_data  ({evt_type, evt_reason, evt_aux0, evt_aux1}),
        .src_valid (evt_valid),
        .src_ready (evt_ready),
        .dst_clk   (core_clk),
        .dst_rst   (core_rst),
        .dst_data  (evt_dst_data),
        .dst_valid (evt_dst_valid)
    );

    // =========================================================================
    // DMA audit log ring
    // ⚠ See the OPEN CONTRACT GAP note in the header: this currently carries
    //   control-plane records only.
    // =========================================================================
    log_rec_t log_rec;
    logic     log_valid;

    always_comb begin
        log_rec            = '0;
        log_rec.rec_type   = evt_dst_data[79:72];
        log_rec.reason     = evt_dst_data[71:64];
        log_rec.aux0       = evt_dst_data[63:32];
        log_rec.aux1       = evt_dst_data[31:0];
        log_rec.trig_cycle = 48'd0;    // control-plane events have no tick
        log_valid          = evt_dst_valid;
        // ver / build_tag / ts_cycle / seq / chk32 are stamped by dma_log_ring.
    end

    dma_log_ring #(
        .FIFO_DEPTH (512),
        .DMA_W      (DMA_W),
        .FIFO_FWFT  (1'b0),
        .BUILD_TAG  (BUILD_ID[15:0])
    ) u_log_ring (
        .core_clk       (core_clk),
        .core_rst       (core_rst),
        .cycle_cnt      (log_cycle_q),
        .s_valid        (log_valid),
        .s_rec          (log_rec),
        .pcie_clk       (pcie_clk),
        .pcie_rst       (pcie_rst),
        .ring_en        (ring_en),
        .ring_base      (ring_base),
        .ring_size_log2 (ring_size_log2),
        .ring_tail      (ring_tail),
        .ring_head      (ring_head),
        .drop_cnt       (ring_drop_cnt),
        .drop_sticky    (ring_drop_sticky),
        .ring_full_cnt  (ring_full_cnt),
        .rec_cnt        (ring_rec_cnt),
        .clr_sticky     (ring_clr_sticky),
        .dma_wr_valid   (dma_wr_valid),
        .dma_wr_ready   (dma_wr_ready),
        .dma_wr_addr    (dma_wr_addr),
        .dma_wr_data    (dma_wr_data),
        .dma_wr_last    (dma_wr_last)
    );

    // =========================================================================
    // Signals present for observability / future wiring
    // -----------------------------------------------------------------------------
    // csr_counters_rst has no destination in the current fpga_top port list;
    // it clears the CSR's own diagnostic counters inside csr_regfile. Fabric
    // counters are free-running by design and the host differences snapshots
    // (manuals/06-operations/03-monitoring-and-telemetry.md §9).
    // pcie_err_cnt / link_speed / link_width are surfaced by the vendor IP and
    // will be added to the CSR map when the .xci port names are pinned.
    // =========================================================================
    /* verilator lint_off UNUSED */
    logic hc_unused;
    assign hc_unused = &{1'b1, csr_counters_rst, pcie_err_cnt, pcie_link_speed,
                         pcie_link_width, watchdog_expired, arm_state,
                         reg_addr[1:0]};
    /* verilator lint_on UNUSED */

    // =========================================================================
    // Assertions — simulation only
    // =========================================================================
`ifndef SYNTHESIS
    // ⚠ fpga_top asserts this at the top level; assert it here too so a unit
    //   test of host_ctrl alone catches a regression.
    assert property (@(posedge core_clk)
        core_rst |-> (!cfg_trading_en && cfg_kill)
    ) else $error("host_ctrl: FATAL - not fail-closed during core reset");

    // ⚠ THE frozen-clock property. If the PCIe side stops, the fabric kills
    //   itself, in the core domain, with no help from anyone.
    assert property (@(posedge core_clk) disable iff (core_rst)
        pcie_dead_q |-> (cfg_kill && !cfg_trading_en && !cfg_heartbeat)
    ) else $error("host_ctrl: FATAL - pcie domain is dead and the card is still armed");

    // Trading enabled implies not killed. There is no state where both hold.
    assert property (@(posedge core_clk) disable iff (core_rst)
        cfg_trading_en |-> !cfg_kill
    ) else $error("host_ctrl: trading enabled while kill asserted");

    // Exactly one config target strobes per crossed write. Two would mean the
    // same word was written into two different tables.
    assert property (@(posedge core_clk) disable iff (core_rst)
        $onehot0({cfg_filter_wr, cfg_risk_wr, cfg_strat_wr,
                  cfg_tmpl_wr, cfg_session_wr})
    ) else $error("host_ctrl: more than one config write strobe asserted");

    // Every crossed config write produces exactly one strobe.
    assert property (@(posedge core_clk) disable iff (core_rst)
        (cfg_dst_valid && (cfg_dst_target != CFG_TGT_NONE))
            |=> (cfg_filter_wr || cfg_risk_wr || cfg_strat_wr ||
                 cfg_tmpl_wr   || cfg_session_wr)
    ) else $error("host_ctrl: a config write crossed the domain and vanished");

    // telem_raddr must return to the parking address between accesses, or
    // telemetry's address-transition side effects fire once and never again.
    assert property (@(posedge core_clk) disable iff (core_rst)
        (ta_state_q == TA_IDLE) |-> (telem_raddr == TELEM_A_IDLE)
    ) else $error("host_ctrl: telemetry address not parked at idle");

    // Commit pulses must be single-cycle in the core domain.
    assert property (@(posedge core_clk) disable iff (core_rst)
        cfg_risk_commit |=> !cfg_risk_commit
    ) else $error("host_ctrl: risk commit was not a one-cycle pulse");

    assert property (@(posedge core_clk) disable iff (core_rst)
        cfg_strat_commit |=> !cfg_strat_commit
    ) else $error("host_ctrl: strategy commit was not a one-cycle pulse");

    // Heartbeat must be a pulse, not a level: risk_gate edge-detects it.
    assert property (@(posedge core_clk) disable iff (core_rst)
        cfg_heartbeat |=> !cfg_heartbeat
    ) else $error("host_ctrl: heartbeat was not a one-cycle pulse");
`endif

endmodule : host_ctrl

`default_nettype wire
