// =============================================================================
// eth_10g_wrapper.sv — 10GbE port: GT/PCS + MAC + MAC/core clock crossing
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/02-networking/01-ethernet-phy-mac.md
//           manuals/01-fpga-design/04-io-transceivers-and-serdes.md
//           manuals/00-foundations/04-clocking-reset-and-cdc.md
//
// PURPOSE
//   The single project-local shim around one 10GbE port. Instantiated twice by
//   fpga_top.sv: twice for the market-data A/B feeds (RX_ONLY=1) and once for
//   the order-entry link (RX_ONLY=0). This is THE place where vendor differences
//   are normalized, per manuals/02-networking/01-ethernet-phy-mac.md §9 rule 6:
//   tuser polarity, error semantics and byte order are fixed here so that no
//   other block in the design knows which core it is talking to.
//
//     serial ── GT/PCS ── XGMII ── mac_rx ──┐
//                                            async_fifo (rx_clk -> core_clk) ──> m_axis
//     serial ── GT/PCS ── XGMII ── mac_tx ──┐
//                                            async_fifo (core_clk -> tx_clk) <── s_axis
//
// =============================================================================
// ⚠️⚠️  THE RX PATH NEVER BACKPRESSURES. IT DROPS AND COUNTS.  ⚠️⚠️
// =============================================================================
//   CLAUDE.md §5 rule 4: "No backpressure stalls into the MAC RX. The receive
//   path must accept line rate unconditionally; drop deliberately and count
//   drops, never block."
//
//   There is no tready anywhere on the RX path — not on mac_rx, not on m_axis,
//   not into the RX async FIFO. When the RX FIFO cannot take a frame:
//
//     ADMISSION CONTROL. A frame is admitted at its FIRST beat, and only if
//     wr_almost_full is low. ALMOST_FULL_LEVEL is set so the remaining headroom
//     exceeds one maximum-length frame (191 beats at 1522 B), so an admitted
//     frame ALWAYS fits even if the reader never reads. A frame refused
//     admission is discarded in its entirety — never partially forwarded — and
//     `frames_dropped` increments once.
//
//     MID-FRAME OVERFLOW (should be unreachable; see above). If the FIFO fills
//     anyway — because ALMOST_FULL_LEVEL was set too tight — the wrapper stops
//     writing and, at the first cycle with room, injects a single synthetic beat
//     with tlast=1 and tuser=1. Downstream therefore still sees a well-formed
//     stream in which every frame ends with tlast, and the truncated frame is
//     explicitly marked BAD so the invalidate path discards it. `frames_dropped`
//     increments. Correctness does not depend on the almost-full threshold;
//     only the drop RATE does.
//
//   ⚠️ Dropping is a DESIGN BEHAVIOUR, not an error path to be "fixed" by adding
//   flow control. A PAUSE frame or a tready would put market data behind a
//   buffer while the market moves. Disable flow control in both directions and
//   drop instead (manuals/02-networking/01-ethernet-phy-mac.md §8).
//   A non-zero drop count on a healthy 10G link means a downstream block is not
//   keeping up: that is a design bug to be found, not throttled away.
//
// =============================================================================
// ⚠️ THE CUT-THROUGH / FCS CONTRACT PROPAGATED TO m_axis
//   m_axis_tuser is valid ONLY on the beat where m_axis_tlast is high, and
//   m_axis_tuser == 1 means THE WHOLE FRAME IS BAD — its payload was already
//   forwarded speculatively and must now be unwound. Polarity is normalized
//   here: AMD's 10G/25G Ethernet Subsystem drives rx_axis_tuser LOW on tlast for
//   a bad frame (PG210); everything downstream of this module sees 1 == bad.
//   The full contract, and downstream's obligations, are in mac_rx.sv's header.
//   ⚠️ No byte of an outbound order may leave the MAC before the tlast/tuser
//   verdict for the frame that caused it.
//
// =============================================================================
// stat[4] — TELEMETRY MAPPING (core_clk domain, free-running, reset-cleared)
//   Consumed by telemetry.sv via fpga_top's md_mac_stat / oe_mac_stat.
//   CLAUDE.md §5 rule 7: every drop, error and rejected frame is counted.
//
//   stat[0]  frames_ok        [31:0]  RX frames delivered to core_clk with
//                                     tuser == 0. The good-traffic counter.
//   stat[1]  frames_dropped   [31:0]  RX frames that NEVER REACHED core_clk:
//                                     FIFO admission refusal, mid-frame FIFO
//                                     overflow, store-and-forward buffer
//                                     overflow. Should be 0 forever.
//   stat[2]  fcs_errors       [31:0]  RX frames delivered with tuser == 1, i.e.
//                                     bad-frame verdicts: FCS mismatch, runt,
//                                     oversize, XGMII /E/, malformed preamble,
//                                     misaligned start. Alarm on ANY non-zero
//                                     rate — a healthy 10G link shows zero for
//                                     days (manuals/.../04-io-...md §5 rule 1).
//   stat[3]  fifo_high_water          packed, see below:
//              [15:0]   RX async FIFO occupancy high-water mark, sticky. The
//                       early warning: a FIFO quietly running near full in
//                       production is a drop waiting for a busy morning.
//              [23:16]  TX underrun count, saturating at 8'hFF. ⚠️ Any non-zero
//                       value is a design bug — the TX skid ran dry mid-frame
//                       and the frame went out with a corrupted FCS.
//              [31:24]  TX deliberate-abort count, saturating at 8'hFF.
//                       ⚠️ Non-zero means frames were intentionally invalidated
//                       on the wire. See the abort warning in mac_tx.sv.
//
//   Counters are 32-bit free-running and WRAP. The host differences successive
//   reads; it must handle wrap. Sub-word counters saturate instead, because a
//   wrapped 8-bit error counter reads as "healthy".
//
// =============================================================================
// LATENCY BUDGET OWNED BY THIS LAYER  (156.25 MHz, 6.4 ns/cycle)
//   Booked against the fpga_top.sv table. Everything below is a TARGET until a
//   wire-to-wire measurement replaces it (manuals/05-optimization/04-*.md).
//
//     RX  optics + GT PMA + PCS (hard IP, buffer bypassed)   -    ~90.0 ns
//     RX  mac_rx cut-through                                 2 cyc  12.8 ns
//     RX  async_fifo rx_clk -> core_clk                      3 cyc  19.2 ns
//         (SYNC_STAGES=2 => 2 sync + 1 read = 3 core cycles)
//     ------------------------------------------------------------------
//     RX  wire -> m_axis                                          ~122 ns
//
//     TX  s_axis -> async_fifo -> skid                       4 cyc  25.6 ns
//     TX  mac_tx cut-through (tvalid -> preamble on XGMII)   2 cyc  12.8 ns
//     TX  GT PCS/PMA + optics (hard IP)                      -    ~90.0 ns
//     ------------------------------------------------------------------
//     TX  s_axis -> wire                                          ~128 ns
//
//   ⚠️ The two async FIFOs are 5 of the ~20 fabric cycles in the whole
//   tick-to-trade budget. They are NOT optional: rx_clk is the recovered clock
//   and has no defined relationship to core_clk. The only way to remove them is
//   to run the entire fast path on the recovered clock, which breaks the moment
//   the link drops. Do not.
//
//   ⚠️ RECORD THE REAL GT/PCS NUMBERS. The ~90 ns figures above are planning
//   numbers. Take the configured latency from the Vivado GT wizard report for
//   this exact configuration and put it here and in docs/, per
//   manuals/02-networking/01-ethernet-phy-mac.md §9 rule 7. It changes whenever
//   someone re-runs the wizard.
//
// RESOURCE ESTIMATE (per instance, UltraScale+, RX_ONLY=0)
//   LUT ~5500   FF ~1800   BRAM 4 (two 512x74 async FIFOs)   URAM 0   DSP 0
//   RX_ONLY=1 drops mac_tx and the TX FIFO: LUT ~3000, FF ~900, BRAM 2.
//   Plus one GT quad channel (hard IP, not counted in fabric).
//
// =============================================================================
// ⚠️ BUILD NOTE — `SIMULATION`
//   With `SIMULATION` defined, the transceiver is gt_wrapper_stub.sv, a
//   behavioural model, so the whole design elaborates and runs under Verilator
//   with NO vendor IP present. Without it, gt_wrapper.sv is instantiated: the
//   real GTY/GTH + 10GBASE-R PCS shim generated by the Vivado wizard. That file
//   is a build artifact, not source, and is not in rtl/eth/. A synthesis build
//   must generate it first. Both present the identical port list, so nothing
//   else in the design changes between the two.
// =============================================================================
`default_nettype none

module eth_10g_wrapper
    import trading_pkg::*;
#(
    // 1 = cut-through MAC. ⚠️ 0 (store-and-forward) costs a full frame time,
    // up to 1.2 us at 1500 B / 10G, and is banned on the fast path.
    parameter int unsigned CUT_THROUGH     = 1,
    // 1 = market-data port: no TX datapath is built, the serial TX is held quiet.
    parameter int unsigned RX_ONLY         = 0,
    // 1 = GT RX elastic buffer bypassed, RX datapath on the recovered clock.
    // The single largest available saving (~25-60 ns) — see
    // manuals/01-fpga-design/04-io-transceivers-and-serdes.md §3.
    parameter int unsigned LOW_LATENCY     = 1,

    // MTU 1500 + 14 header + 4 FCS + 4 VLAN.
    parameter int unsigned MAX_FRAME_BYTES = 1522,
    // Power of two. Must exceed one maximum frame by a wide margin so the
    // admission rule below is a hard guarantee.
    parameter int unsigned RX_FIFO_DEPTH   = 512,
    parameter int unsigned TX_FIFO_DEPTH   = 512,
    // Beats of TX cushion required before a frame is launched. Covers the async
    // FIFO's SYNC_STAGES+1 write-to-readable latency plus the 1-cycle pop
    // latency, so mac_tx cannot underrun. 4 beats = 25.6 ns of added TX latency.
    parameter int unsigned TX_PREFILL      = 4
) (
    // ── Transceiver reference clock and serial pins ──────────────────────────
    input  var logic                    gt_refclk_p,
    input  var logic                    gt_refclk_n,
    input  var logic                    rxp,
    input  var logic                    rxn,
    output var logic                    txp,
    output var logic                    txn,

    // ── Recovered RX clock, exported for constraints and debug ───────────────
    output var logic                    rx_clk,

    // ── Core clock domain ────────────────────────────────────────────────────
    input  var logic                    core_clk,
    input  var logic                    core_rst,

    // ── RX to core. ⚠️ NO tready. Downstream MUST accept unconditionally. ────
    output var logic [AXIS_W-1:0]       m_axis_tdata,
    output var logic [AXIS_KEEP_W-1:0]  m_axis_tkeep,
    output var logic                    m_axis_tvalid,
    output var logic                    m_axis_tlast,
    output var logic                    m_axis_tuser,   // 1 on tlast == BAD FRAME

    // ── TX from core ─────────────────────────────────────────────────────────
    input  var logic [AXIS_W-1:0]       s_axis_tdata,
    input  var logic [AXIS_KEEP_W-1:0]  s_axis_tkeep,
    input  var logic                    s_axis_tvalid,
    input  var logic                    s_axis_tlast,
    output var logic                    s_axis_tready,

    // ── Status ───────────────────────────────────────────────────────────────
    output var logic                    link_up,
    output var logic [31:0]             stat [4]
);

    // =========================================================================
    // Local constants
    // =========================================================================
    localparam int unsigned RX_FIFO_W  = AXIS_W + AXIS_KEEP_W + 2;  // +tlast +tuser
    localparam int unsigned TX_FIFO_W  = AXIS_W + AXIS_KEEP_W + 1;  // +tlast
    localparam int unsigned MAX_BEATS  = (MAX_FRAME_BYTES + AXIS_KEEP_W - 1) / AXIS_KEEP_W;

    // ⚠️ THE ADMISSION GUARANTEE. Headroom above the almost-full level must
    // exceed one maximum-length frame, so a frame admitted at its first beat
    // always fits even if the core never reads a single beat.
    //   headroom = DEPTH - RX_AFULL_LEVEL = MAX_BEATS + 8 > MAX_BEATS   ✓
    // With the defaults: 512 - 199 = 313, headroom 199 against 191 beats for a
    // 1522-byte frame. The 8-beat slack covers the almost-full flag's own
    // reporting latency (the write side sees a pessimistic occupancy, which is
    // the safe direction, but it is still worth budgeting for).
    localparam int unsigned RX_AFULL_LEVEL = RX_FIFO_DEPTH - MAX_BEATS - 8;

    localparam int unsigned HW_W  = $clog2(RX_FIFO_DEPTH) + 1;
    localparam int unsigned SK_D  = 8;                       // TX prefetch beats
    localparam int unsigned SK_AW = $clog2(SK_D);

    // =========================================================================
    // Clocks and resets
    //
    // rx_clk is the RECOVERED clock (LOW_LATENCY=1 bypasses the GT elastic
    // buffer, so the RX datapath has no choice but to run on it). tx_clk is the
    // local reference — the standard arrangement; loop timing is non-standard
    // for a host endpoint and needs written confirmation from the peer switch.
    // manuals/01-fpga-design/04-io-transceivers-and-serdes.md §7.
    //
    // ⚠️ The RX datapath upstream of the async FIFO DOES NOT EXIST during
    // link-down. Reset sequencing must survive "link up, down, up again"
    // without wedging: rx_rst is the OR of the core reset (synchronized in) and
    // the GT's own rx-side reset, registered in the rx_clk domain.
    // =========================================================================
    logic gt_rx_clk, gt_tx_clk;
    logic gt_rx_rst, gt_tx_rst;
    logic rx_rst_core, tx_rst_core;
    logic rx_rst, tx_rst;
    logic gt_link_up;

    assign rx_clk = gt_rx_clk;

    reset_sync #(.STAGES(3)) u_rx_reset_sync (
        .clk          (gt_rx_clk),
        .async_rst_in (core_rst),
        .sync_rst_out (rx_rst_core)
    );

    reset_sync #(.STAGES(3)) u_tx_reset_sync (
        .clk          (gt_tx_clk),
        .async_rst_in (core_rst),
        .sync_rst_out (tx_rst_core)
    );

    // Both terms are already synchronous to their own domain, so the OR is
    // registered rather than fed straight into a synchronizer.
    always_ff @(posedge gt_rx_clk) rx_rst <= rx_rst_core | gt_rx_rst;
    always_ff @(posedge gt_tx_clk) tx_rst <= tx_rst_core | gt_tx_rst;

    // =========================================================================
    // Transceiver + PCS
    // =========================================================================
    logic [AXIS_W-1:0]      xgmii_rxd;
    logic [AXIS_KEEP_W-1:0] xgmii_rxc;
    logic [AXIS_W-1:0]      xgmii_txd;
    logic [AXIS_KEEP_W-1:0] xgmii_txc;
    logic                   gt_block_lock, gt_hi_ber, gt_local_fault, gt_remote_fault;

`ifdef SIMULATION
    // -------------------------------------------------------------------------
    // ⚠️ BEHAVIOURAL MODEL. No SerDes, no 64b/66b, no CDR. Lets the whole
    // tick-to-trade design run under Verilator with no vendor IP. See
    // gt_wrapper_stub.sv for how a testbench drives it.
    // -------------------------------------------------------------------------
    gt_wrapper_stub #(
        .DATA_W          (AXIS_W),
        .LOOPBACK        (1),
        .LOOPBACK_CYCLES (4),
        .LINK_UP_CYCLES  (64),
        .RX_ONLY         (RX_ONLY)
    ) u_gt (
        .gt_refclk_p  (gt_refclk_p),
        .gt_refclk_n  (gt_refclk_n),
        .rxp          (rxp),
        .rxn          (rxn),
        .txp          (txp),
        .txn          (txn),
        .free_clk     (core_clk),
        .free_rst     (core_rst),
        .rx_clk       (gt_rx_clk),
        .tx_clk       (gt_tx_clk),
        .rx_rst       (gt_rx_rst),
        .tx_rst       (gt_tx_rst),
        .xgmii_rxd    (xgmii_rxd),
        .xgmii_rxc    (xgmii_rxc),
        .xgmii_txd    (xgmii_txd),
        .xgmii_txc    (xgmii_txc),
        .link_up      (gt_link_up),
        .block_lock   (gt_block_lock),
        .hi_ber       (gt_hi_ber),
        .local_fault  (gt_local_fault),
        .remote_fault (gt_remote_fault)
    );
`else
    // -------------------------------------------------------------------------
    // Real GTY/GTH + 10GBASE-R PCS. gt_wrapper.sv is a BUILD ARTIFACT generated
    // by the Vivado wizard (see scripts/), not source in rtl/eth/. It owns:
    //   * the GT quad channel and its reset FSM
    //   * 64b/66b block sync, descramble and the gearbox
    //   * RX elastic buffer BYPASS when LOW_LATENCY=1 (the ~25-60 ns win)
    //   * the reconciliation-sublayer realignment that guarantees the lane-0
    //     start contract mac_rx/mac_tx depend on
    //   * link fault (LF/RF) detect and emit
    // Its port list is identical to gt_wrapper_stub's so the two are drop-in
    // swappable and nothing else in the design changes.
    // -------------------------------------------------------------------------
    gt_wrapper #(
        .DATA_W        (AXIS_W),
        .BUFFER_BYPASS (LOW_LATENCY),
        .RX_ONLY       (RX_ONLY)
    ) u_gt (
        .gt_refclk_p  (gt_refclk_p),
        .gt_refclk_n  (gt_refclk_n),
        .rxp          (rxp),
        .rxn          (rxn),
        .txp          (txp),
        .txn          (txn),
        .free_clk     (core_clk),
        .free_rst     (core_rst),
        .rx_clk       (gt_rx_clk),
        .tx_clk       (gt_tx_clk),
        .rx_rst       (gt_rx_rst),
        .tx_rst       (gt_tx_rst),
        .xgmii_rxd    (xgmii_rxd),
        .xgmii_rxc    (xgmii_rxc),
        .xgmii_txd    (xgmii_txd),
        .xgmii_txc    (xgmii_txc),
        .link_up      (gt_link_up),
        .block_lock   (gt_block_lock),
        .hi_ber       (gt_hi_ber),
        .local_fault  (gt_local_fault),
        .remote_fault (gt_remote_fault)
    );
`endif

    // link_up is a slowly-changing level: a 2-FF synchronizer is exactly right.
    // INIT_VAL 0 = "link down" is the safe power-up state (the risk gate trips
    // the kill switch on link-down, so it must never read up before it is).
    cdc_sync_bit #(.STAGES(3), .INIT_VAL(1'b0)) u_link_up_cdc (
        .dst_clk (core_clk),
        .src_bit (gt_link_up),
        .dst_bit (link_up)
    );

    /* verilator lint_off UNUSED */
    wire unused_gt_status = gt_block_lock ^ gt_hi_ber ^ gt_local_fault ^ gt_remote_fault;
    /* verilator lint_on UNUSED */

    // =========================================================================
    // RX: MAC (rx_clk domain)
    // =========================================================================
    logic [AXIS_W-1:0]      rx_tdata;
    logic [AXIS_KEEP_W-1:0] rx_tkeep;
    logic                   rx_tvalid, rx_tlast, rx_tuser;
    logic rx_evt_ok, rx_evt_fcs, rx_evt_runt, rx_evt_over, rx_evt_align, rx_evt_sf;

    mac_rx #(
        .DATA_W            (AXIS_W),
        .STORE_AND_FORWARD ((CUT_THROUGH != 0) ? 0 : 1),
        .STRIP_FCS         (1),
        .MIN_FRAME_BYTES   (64),
        .MAX_FRAME_BYTES   (MAX_FRAME_BYTES),
        .SF_DEPTH          (512)
    ) u_mac_rx (
        .clk           (gt_rx_clk),
        .rst           (rx_rst),
        .xgmii_rxd     (xgmii_rxd),
        .xgmii_rxc     (xgmii_rxc),
        .m_axis_tdata  (rx_tdata),
        .m_axis_tkeep  (rx_tkeep),
        .m_axis_tvalid (rx_tvalid),
        .m_axis_tlast  (rx_tlast),
        .m_axis_tuser  (rx_tuser),
        .evt_frame_ok  (rx_evt_ok),
        .evt_fcs_err   (rx_evt_fcs),
        .evt_runt      (rx_evt_runt),
        .evt_oversize  (rx_evt_over),
        .evt_align_err (rx_evt_align),
        .evt_sf_drop   (rx_evt_sf)
    );

    // =========================================================================
    // ⚠️ RX ADMISSION CONTROL — THE DROP-NEVER-BLOCK MECHANISM
    // See the header. There is no tready anywhere in this block, by design.
    // =========================================================================
    typedef enum logic [1:0] {
        W_IDLE  = 2'd0,   // between frames
        W_PASS  = 2'd1,   // this frame is being written
        W_ABORT = 2'd2,   // inject a terminating error beat, then drop
        W_DROP  = 2'd3    // discard the rest of this frame
    } wr_state_e;

    wr_state_e              wst;
    logic                   abort_saw_last;
    logic [RX_FIFO_W-1:0]   rx_fifo_wdata;
    logic                   rx_fifo_wen;
    logic                   rx_fifo_full, rx_fifo_afull;
    logic [HW_W-1:0]        rx_fifo_hw;
    logic [RX_FIFO_W-1:0]   rx_fifo_rdata;
    logic                   rx_fifo_ren, rx_fifo_empty, rx_fifo_rvalid;
    logic                   evt_rx_drop;

    // A drop decision is taken once per frame, at the beat that discovers it.
    assign evt_rx_drop = (wst == W_IDLE) ? (rx_tvalid && (rx_fifo_afull || rx_fifo_full))
                       : (wst == W_PASS) ? (rx_tvalid && rx_fifo_full)
                                         : 1'b0;

    always_ff @(posedge gt_rx_clk) begin
        if (rx_rst) begin
            wst            <= W_IDLE;
            abort_saw_last <= 1'b0;
        end else begin
            unique case (wst)
                W_IDLE: begin
                    if (rx_tvalid) begin
                        if (rx_fifo_afull || rx_fifo_full) begin
                            // Refuse admission for the WHOLE frame.
                            wst <= rx_tlast ? W_IDLE : W_DROP;
                        end else begin
                            wst <= rx_tlast ? W_IDLE : W_PASS;
                        end
                    end
                end

                W_PASS: begin
                    if (rx_tvalid) begin
                        if (rx_fifo_full) begin
                            // Unreachable if RX_AFULL_LEVEL is honoured. Close
                            // the partial frame with a bad-frame terminator so
                            // downstream still sees a well-formed stream.
                            wst            <= W_ABORT;
                            abort_saw_last <= rx_tlast;
                        end else if (rx_tlast) begin
                            wst <= W_IDLE;
                        end
                    end
                end

                W_ABORT: begin
                    if (rx_tvalid && rx_tlast) begin
                        abort_saw_last <= 1'b1;
                    end
                    if (!rx_fifo_full) begin
                        wst            <= (abort_saw_last || (rx_tvalid && rx_tlast))
                                          ? W_IDLE : W_DROP;
                        abort_saw_last <= 1'b0;
                    end
                end

                W_DROP: begin
                    if (rx_tvalid && rx_tlast) begin
                        wst <= W_IDLE;
                    end
                end

                default: wst <= W_IDLE;
            endcase
        end
    end

    always_comb begin
        // Default: nothing written. No latches.
        rx_fifo_wen   = 1'b0;
        rx_fifo_wdata = {rx_tuser, rx_tlast, rx_tkeep, rx_tdata};

        if (wst == W_ABORT) begin
            // Synthetic terminator: one byte, tlast, tuser=1 (frame is BAD).
            rx_fifo_wen   = !rx_fifo_full;
            rx_fifo_wdata = {1'b1, 1'b1, AXIS_KEEP_W'(1), {AXIS_W{1'b0}}};
        end else if (rx_tvalid && !rx_fifo_full) begin
            rx_fifo_wen   = (wst == W_PASS) ||
                            ((wst == W_IDLE) && !rx_fifo_afull);
        end
    end

    // =========================================================================
    // RX async FIFO — the MAC/core clock crossing
    // ⚠️ rd_en is unconditional. That IS the no-backpressure rule in one line.
    // =========================================================================
    async_fifo #(
        .W                 (RX_FIFO_W),
        .DEPTH             (RX_FIFO_DEPTH),
        .SYNC_STAGES       (2),
        .ALMOST_FULL_LEVEL (RX_AFULL_LEVEL)
    ) u_rx_fifo (
        .wr_clk         (gt_rx_clk),
        .wr_rst         (rx_rst),
        .wr_data        (rx_fifo_wdata),
        .wr_en          (rx_fifo_wen),
        .wr_full        (rx_fifo_full),
        .wr_almost_full (rx_fifo_afull),
        .wr_high_water  (rx_fifo_hw),
        .rd_clk         (core_clk),
        .rd_rst         (core_rst),
        .rd_data        (rx_fifo_rdata),
        .rd_en          (rx_fifo_ren),
        .rd_empty       (rx_fifo_empty),
        .rd_valid       (rx_fifo_rvalid)
    );

    assign rx_fifo_ren = !rx_fifo_empty;      // ⚠️ never gated. Never.

    // The FIFO's read port is already registered, so this unpack adds no logic.
    assign m_axis_tdata  = rx_fifo_rdata[AXIS_W-1:0];
    assign m_axis_tkeep  = rx_fifo_rdata[AXIS_W +: AXIS_KEEP_W];
    assign m_axis_tlast  = rx_fifo_rdata[AXIS_W + AXIS_KEEP_W];
    assign m_axis_tuser  = rx_fifo_rdata[AXIS_W + AXIS_KEEP_W + 1];
    assign m_axis_tvalid = rx_fifo_rvalid;

    // =========================================================================
    // TX path — omitted entirely on a market-data port
    // =========================================================================
    logic tx_evt_sent, tx_evt_abort, tx_evt_under;

    generate
    if (RX_ONLY != 0) begin : g_no_tx

        // fpga_top holds md_tx_p/n quiet on the market-data lanes; the stub and
        // the real gt_wrapper both drive the serial pins directly.
        assign s_axis_tready = 1'b1;          // never stall a source that is tied off
        assign xgmii_txd     = {AXIS_KEEP_W{8'h07}};   // continuous /I/ idle
        assign xgmii_txc     = {AXIS_KEEP_W{1'b1}};
        assign tx_evt_sent   = 1'b0;
        assign tx_evt_abort  = 1'b0;
        assign tx_evt_under  = 1'b0;

        /* verilator lint_off UNUSED */
        wire unused_tx = s_axis_tvalid ^ s_axis_tlast ^ (^s_axis_tdata) ^ (^s_axis_tkeep);
        /* verilator lint_on UNUSED */

    end else begin : g_tx

        // ---------------------------------------------------------------------
        // core_clk -> tx_clk crossing. Backpressure IS legal here: refusing to
        // accept an order beat is safe, whereas refusing a market-data beat is
        // data loss.
        // ---------------------------------------------------------------------
        logic [TX_FIFO_W-1:0] tx_fifo_wdata, tx_fifo_rdata;
        logic                 tx_fifo_wen, tx_fifo_full, tx_fifo_afull;
        logic [$clog2(TX_FIFO_DEPTH):0] tx_fifo_hw;
        logic                 tx_fifo_ren, tx_fifo_empty, tx_fifo_rvalid;

        assign tx_fifo_wdata = {s_axis_tlast, s_axis_tkeep, s_axis_tdata};
        assign tx_fifo_wen   = s_axis_tvalid && !tx_fifo_full;
        // ⚠️ Combinational tready: the sanctioned exception in
        // manuals/00-foundations/03-hdl-and-rtl-coding.md §5.
        assign s_axis_tready = !tx_fifo_full;

        async_fifo #(
            .W           (TX_FIFO_W),
            .DEPTH       (TX_FIFO_DEPTH),
            .SYNC_STAGES (2)
        ) u_tx_fifo (
            .wr_clk         (core_clk),
            .wr_rst         (core_rst),
            .wr_data        (tx_fifo_wdata),
            .wr_en          (tx_fifo_wen),
            .wr_full        (tx_fifo_full),
            .wr_almost_full (tx_fifo_afull),
            .wr_high_water  (tx_fifo_hw),
            .rd_clk         (gt_tx_clk),
            .rd_rst         (tx_rst),
            .rd_data        (tx_fifo_rdata),
            .rd_en          (tx_fifo_ren),
            .rd_empty       (tx_fifo_empty),
            .rd_valid       (tx_fifo_rvalid)
        );

        /* verilator lint_off UNUSED */
        wire unused_tx_status = tx_fifo_afull ^ (^tx_fifo_hw);
        /* verilator lint_on UNUSED */

        // ---------------------------------------------------------------------
        // ⚠️ TX PREFETCH / SKID — THE UNDERRUN CUSHION
        //
        // XGMII cannot be stalled mid-frame, so mac_tx must be fed every cycle
        // once a frame starts. Two hazards:
        //   1. the async FIFO reports readable only SYNC_STAGES+1 read cycles
        //      after a write, so a producer and consumer running at the same
        //      rate would see `empty` on the first beats and starve;
        //   2. the FIFO is standard-mode: rd_en -> rd_valid one cycle later.
        // This SK_D-deep circular prefetch absorbs both. A frame is launched
        // only once TX_PREFILL beats (or the whole frame) are resident, which
        // makes underrun unreachable in steady state. mac_tx still handles it —
        // by aborting with a corrupted FCS and counting — because a silent
        // truncated frame would be far worse.
        // ---------------------------------------------------------------------
        logic [TX_FIFO_W-1:0] sk_mem [SK_D];
        logic [SK_AW:0]       sk_wr, sk_rd;
        logic [SK_AW:0]       sk_occ;
        logic                 sk_val;
        logic [SK_AW:0]       sk_last_cnt;     // tlast beats resident
        logic                 tx_run;

        logic [AXIS_W-1:0]      tx_beat_data;
        logic [AXIS_KEEP_W-1:0] tx_beat_keep;
        logic                   tx_beat_last;
        logic                   mac_tx_tready, mac_tx_tvalid;

        assign sk_occ = sk_wr - sk_rd;
        assign sk_val = (sk_wr != sk_rd);
        // Leave two slots free: one for the pop already in flight.
        assign tx_fifo_ren = !tx_fifo_empty && (sk_occ <= (SK_AW+1)'(SK_D - 2));

        assign {tx_beat_last, tx_beat_keep, tx_beat_data} = sk_mem[sk_rd[SK_AW-1:0]];

        always_ff @(posedge gt_tx_clk) begin
            if (tx_fifo_rvalid) begin
                sk_mem[sk_wr[SK_AW-1:0]] <= tx_fifo_rdata;   // datapath: no reset
            end

            if (tx_rst) begin
                sk_wr       <= '0;
                sk_rd       <= '0;
                sk_last_cnt <= '0;
                tx_run      <= 1'b0;
            end else begin
                if (tx_fifo_rvalid) begin
                    sk_wr <= sk_wr + (SK_AW+1)'(1);
                end
                if (sk_val && mac_tx_tready) begin
                    sk_rd <= sk_rd + (SK_AW+1)'(1);
                end

                // Resident tlast count: tells us a short frame is complete and
                // may be launched without waiting for TX_PREFILL beats.
                case ({tx_fifo_rvalid && tx_fifo_rdata[AXIS_W+AXIS_KEEP_W],
                       sk_val && mac_tx_tready && tx_beat_last})
                    2'b10:   sk_last_cnt <= sk_last_cnt + (SK_AW+1)'(1);
                    2'b01:   sk_last_cnt <= sk_last_cnt - (SK_AW+1)'(1);
                    default: sk_last_cnt <= sk_last_cnt;
                endcase

                // Launch gate: hold the frame until it cannot underrun.
                if (!tx_run) begin
                    if ((sk_occ >= (SK_AW+1)'(TX_PREFILL)) || (sk_last_cnt != '0)) begin
                        tx_run <= 1'b1;
                    end
                end else if (sk_val && mac_tx_tready && tx_beat_last) begin
                    tx_run <= 1'b0;
                end
            end
        end

        assign mac_tx_tvalid = sk_val && tx_run;

        mac_tx #(
            .DATA_W         (AXIS_W),
            .MIN_BODY_BYTES (60),
            .IFG_BEATS      (2)
        ) u_mac_tx (
            .clk            (gt_tx_clk),
            .rst            (tx_rst),
            .s_axis_tdata   (tx_beat_data),
            .s_axis_tkeep   (tx_beat_keep),
            .s_axis_tvalid  (mac_tx_tvalid),
            .s_axis_tlast   (tx_beat_last),
            .s_axis_tready  (mac_tx_tready),
            // ⚠️ DELIBERATE FRAME ABORT — TIED OFF.
            // mac_tx implements FCS inversion for the speculative-transmission
            // optimization in manuals/01-fpga-design/02-pipelining-and-parallelism.md
            // §5, but eth_10g_wrapper's port list is fixed by fpga_top.sv and
            // carries no abort input. Exposing it is a DELIBERATE, REVIEWED
            // change: add the port here AND in fpga_top.sv, wire it from
            // order_gateway, and only after the venue has confirmed IN WRITING
            // that intentionally-invalid frames will not trip their error-rate
            // or disconnection policy. Until then this stays 0 and the abort
            // counter stays at zero.
            .abort          (1'b0),
            .xgmii_txd      (xgmii_txd),
            .xgmii_txc      (xgmii_txc),
            .evt_frame_sent (tx_evt_sent),
            .evt_abort      (tx_evt_abort),
            .evt_underrun   (tx_evt_under)
        );

    end
    endgenerate

    // =========================================================================
    // Telemetry CDC — event strobes into core_clk, then counted there
    //
    // Counting in the source domain would force a multi-bit crossing. Crossing
    // single-cycle events with the sanctioned toggle synchronizer (cdc_pulse)
    // and counting in core_clk is both cheaper and correct.
    // ⚠️ cdc_pulse drops events that arrive closer together than its round trip
    // (~6 cycles). Frame events are >= 84 bytes apart (~11 cycles at 10G), so
    // frames_ok / fcs_errors / frames_dropped are exact. A pathological storm of
    // back-to-back malformed beats can undercount; the counter is still a
    // correct "something is wrong" indicator, which is its job.
    // =========================================================================
    logic rx_evt_bad, rx_evt_drop_all;
    logic core_evt_ok, core_evt_bad, core_evt_drop, core_evt_abort, core_evt_under;

    // Bad-frame verdicts. Mutually exclusive with evt_frame_ok, and at most one
    // per frame, so the OR loses nothing.
    assign rx_evt_bad      = rx_evt_fcs | rx_evt_runt | rx_evt_over | rx_evt_align;
    // Frames that never reached core_clk at all.
    assign rx_evt_drop_all = evt_rx_drop | rx_evt_sf;

    cdc_pulse #(.SYNC_STAGES(2)) u_evt_ok (
        .src_clk(gt_rx_clk), .src_rst(rx_rst), .src_pulse(rx_evt_ok),      .src_busy(),
        .dst_clk(core_clk),  .dst_rst(core_rst), .dst_pulse(core_evt_ok));

    cdc_pulse #(.SYNC_STAGES(2)) u_evt_bad (
        .src_clk(gt_rx_clk), .src_rst(rx_rst), .src_pulse(rx_evt_bad),     .src_busy(),
        .dst_clk(core_clk),  .dst_rst(core_rst), .dst_pulse(core_evt_bad));

    cdc_pulse #(.SYNC_STAGES(2)) u_evt_drop (
        .src_clk(gt_rx_clk), .src_rst(rx_rst), .src_pulse(rx_evt_drop_all), .src_busy(),
        .dst_clk(core_clk),  .dst_rst(core_rst), .dst_pulse(core_evt_drop));

    cdc_pulse #(.SYNC_STAGES(2)) u_evt_abort (
        .src_clk(gt_tx_clk), .src_rst(tx_rst), .src_pulse(tx_evt_abort),   .src_busy(),
        .dst_clk(core_clk),  .dst_rst(core_rst), .dst_pulse(core_evt_abort));

    cdc_pulse #(.SYNC_STAGES(2)) u_evt_under (
        .src_clk(gt_tx_clk), .src_rst(tx_rst), .src_pulse(tx_evt_under),   .src_busy(),
        .dst_clk(core_clk),  .dst_rst(core_rst), .dst_pulse(core_evt_under));

    /* verilator lint_off UNUSED */
    wire unused_tx_sent = tx_evt_sent;
    /* verilator lint_on UNUSED */

    // -------------------------------------------------------------------------
    // RX FIFO high-water mark: a multi-bit value, so it crosses through the
    // sanctioned handshake (never parallel 2-FF chains — that is the classic
    // CDC bug, manuals/00-foundations/04-clocking-reset-and-cdc.md §2). The
    // handshake round trip rate-limits it to telemetry cadence, which is all it
    // needs; the value is monotonic so a stale read is merely conservative.
    // -------------------------------------------------------------------------
    logic [HW_W-1:0] hw_core;
    logic            hw_core_valid;
    logic            hw_src_ready;

    cdc_handshake #(.W(HW_W), .SYNC_STAGES(2)) u_hw_cdc (
        .src_clk   (gt_rx_clk),
        .src_rst   (rx_rst),
        .src_data  (rx_fifo_hw),
        .src_valid (1'b1),               // free-running; src_ready paces it
        .src_ready (hw_src_ready),
        .dst_clk   (core_clk),
        .dst_rst   (core_rst),
        .dst_data  (hw_core),
        .dst_valid (hw_core_valid)
    );

    /* verilator lint_off UNUSED */
    wire unused_hw_ready = hw_src_ready;
    /* verilator lint_on UNUSED */

    // =========================================================================
    // Counters (core_clk). stat[] mapping is documented in the header.
    // =========================================================================
    logic [31:0] cnt_ok, cnt_drop, cnt_bad;
    logic [7:0]  cnt_under, cnt_abort;
    logic [15:0] hw_hold;

    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            cnt_ok    <= '0;
            cnt_drop  <= '0;
            cnt_bad   <= '0;
            cnt_under <= '0;
            cnt_abort <= '0;
            hw_hold   <= '0;
        end else begin
            // 32-bit counters WRAP; the host differences successive reads.
            if (core_evt_ok)   cnt_ok   <= cnt_ok   + 32'd1;
            if (core_evt_drop) cnt_drop <= cnt_drop + 32'd1;
            if (core_evt_bad)  cnt_bad  <= cnt_bad  + 32'd1;

            // 8-bit error counters SATURATE. A wrapped error counter reads as
            // "healthy", which is the worst possible failure mode here.
            if (core_evt_under && (cnt_under != 8'hFF)) cnt_under <= cnt_under + 8'd1;
            if (core_evt_abort && (cnt_abort != 8'hFF)) cnt_abort <= cnt_abort + 8'd1;

            if (hw_core_valid) begin
                hw_hold <= 16'(hw_core);
            end
        end
    end

    // Registered export. One cycle behind the counters, which is irrelevant for
    // telemetry and keeps the counter logic off telemetry.sv's read path.
    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            stat[0] <= 32'd0;
            stat[1] <= 32'd0;
            stat[2] <= 32'd0;
            stat[3] <= 32'd0;
        end else begin
            stat[0] <= cnt_ok;
            stat[1] <= cnt_drop;
            stat[2] <= cnt_bad;
            stat[3] <= {cnt_abort, cnt_under, hw_hold};
        end
    end

    // =========================================================================
    // Assertions
    // =========================================================================
`ifndef SYNTHESIS

    initial begin : b_elab
        if (CUT_THROUGH == 0) begin
            $warning("eth_10g_wrapper: CUT_THROUGH=0 selects store-and-forward. Up to 1.2 us added latency. BANNED on the fast path (manuals/02-networking/01-ethernet-phy-mac.md §9 rule 2).");
        end
        if (LOW_LATENCY == 0) begin
            $warning("eth_10g_wrapper: LOW_LATENCY=0 keeps the GT RX elastic buffer. That is 25-60 ns of avoidable RX latency.");
        end
        // ⚠️ THE ADMISSION GUARANTEE. If this fails, an admitted frame can
        // overflow mid-flight and the abort-injection path starts firing.
        if (RX_FIFO_DEPTH <= (MAX_BEATS + 8)) begin
            $fatal(1, "eth_10g_wrapper: RX_FIFO_DEPTH=%0d leaves no headroom above one max frame (%0d beats). The RX admission guarantee is broken.",
                   RX_FIFO_DEPTH, MAX_BEATS);
        end
        if ((RX_AFULL_LEVEL + MAX_BEATS) > RX_FIFO_DEPTH) begin
            $fatal(1, "eth_10g_wrapper: RX_AFULL_LEVEL=%0d + MAX_BEATS=%0d exceeds RX_FIFO_DEPTH=%0d — an admitted frame can overflow.",
                   RX_AFULL_LEVEL, MAX_BEATS, RX_FIFO_DEPTH);
        end
        if ((RX_FIFO_DEPTH & (RX_FIFO_DEPTH-1)) != 0) begin
            $fatal(1, "eth_10g_wrapper: RX_FIFO_DEPTH must be a power of two");
        end
        if (TX_PREFILL >= SK_D) begin
            $fatal(1, "eth_10g_wrapper: TX_PREFILL (%0d) must be < SK_D (%0d)", TX_PREFILL, SK_D);
        end
    end

    // --- ⚠️ CLAUDE.md §5 rule 4, stated as a checkable property -------------
    //     The RX FIFO read enable must be a pure function of "not empty".
    //     If anyone ever gates it on a downstream ready, this fires.
    a_rx_never_blocks: assert property (@(posedge core_clk) disable iff (core_rst)
        rx_fifo_ren == !rx_fifo_empty
    ) else $error("eth_10g_wrapper: RX FIFO read was gated — backpressure has been introduced into the MAC RX path");

    // --- tuser is only meaningful on tlast ---------------------------------
    a_tuser_on_tlast: assert property (@(posedge core_clk) disable iff (core_rst)
        (m_axis_tvalid && !m_axis_tlast) |-> !m_axis_tuser
    ) else $error("eth_10g_wrapper: tuser asserted on a non-last beat");

    // --- a valid beat always keeps at least one byte ------------------------
    a_keep_nonzero: assert property (@(posedge core_clk) disable iff (core_rst)
        m_axis_tvalid |-> (m_axis_tkeep != '0)
    ) else $error("eth_10g_wrapper: valid RX beat with tkeep == 0");

    // --- the FIFO must never overflow: writes are gated on !full ------------
    a_no_overflow: assert property (@(posedge gt_rx_clk) disable iff (rx_rst)
        rx_fifo_wen |-> !rx_fifo_full
    ) else $error("eth_10g_wrapper: wrote to a full RX FIFO");

    // --- ⚠️ the admission guarantee, checked at runtime ---------------------
    //     Reaching W_ABORT means a frame was admitted and then overflowed, i.e.
    //     ALMOST_FULL_LEVEL is too tight. Correctness is preserved, latency and
    //     drop rate are not.
    a_admission_holds: assert property (@(posedge gt_rx_clk) disable iff (rx_rst)
        wst != W_ABORT
    ) else $error("eth_10g_wrapper: RX FIFO overflowed MID-FRAME. ALMOST_FULL_LEVEL leaves less than one max frame of headroom.");

    // --- TX AXI-Stream contract on the core-clock side ----------------------
    a_tx_axis_stable: assert property (@(posedge core_clk) disable iff (core_rst)
        (s_axis_tvalid && !s_axis_tready) |=> (s_axis_tvalid && $stable(s_axis_tdata))
    ) else $error("eth_10g_wrapper: TX AXI-Stream contract violated");

    // --- no RX traffic is presented to the core while it is held in reset ---
    a_quiet_in_reset: assert property (@(posedge core_clk)
        core_rst |-> !m_axis_tvalid
    ) else $error("eth_10g_wrapper: RX beat presented while core_rst is asserted");

    // --- link_up must fall within the synchronizer depth of a core reset ----
    //     (fail-closed: the risk gate trips its kill switch on link-down, so a
    //     stale "up" is the dangerous direction).
    a_link_down_after_reset: assert property (@(posedge core_clk)
        core_rst |-> ##[1:8] !link_up
    ) else $error("eth_10g_wrapper: link_up did not drop within 8 cycles of core_rst");

`endif

endmodule : eth_10g_wrapper

`default_nettype wire
