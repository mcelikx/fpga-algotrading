// =============================================================================
// pcie_wrapper.sv — PCIe hard-block wrapper + simulation stub
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/00-foundations/04-clocking-reset-and-cdc.md
//           manuals/06-operations/01-build-and-release.md §1 (pinned IP versions)
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   THE ONLY FILE IN THIS PROJECT THAT MAY CONTAIN VENDOR PCIe PRIMITIVES.
//   Everything above it sees two plain, vendor-neutral interfaces:
//
//     * a simple register port  { reg_addr, reg_wdata, reg_we, reg_re,
//                                 reg_rdata, reg_rvalid }   — the BAR
//     * a DMA write stream      { dma_wr_valid/ready/addr/data/last }
//                                                            — the log ring
//
//   Porting to Intel Agilex, or to a different Xilinx PCIe IP, is a change to
//   this file and nothing else (CLAUDE.md §2: keep RTL vendor-neutral, isolate
//   primitives behind wrappers).
//
// ⚠ SIMULATION
//   `ifdef SIMULATION replaces the vendor IP with a stub whose register port
//   and DMA sink are driven directly by the testbench. This is what makes the
//   ENTIRE design simulate in Verilator with no vendor IP present — every
//   cocotb test of the control plane, the CSR map, the arm sequence and the
//   watchdog runs against real RTL for everything except the transport.
//
//   Lint and simulate with:   verilator -Wall +define+SIMULATION ...
//   Without +define+SIMULATION the vendor instance is elaborated and the build
//   requires the checked-in .xci — that is the synthesis path only.
//
// ⚠ CLOCKING CONTRACT
//   `pcie_clk` / `pcie_rst` are INPUTS. rtl/clk_rst_gen.sv is the single owner
//   of clock generation in this design (see rtl/fpga_top.sv). In a real
//   UltraScale+ build the PCIe integrated block emits `user_clk`; clk_rst_gen
//   must therefore either instantiate that clocking itself or the core must be
//   configured so `user_clk` IS the net clk_rst_gen drives. Two independently
//   generated 250 MHz clocks connected as if they were one is a CDC bug that
//   passes timing — see manuals/00-foundations/04-*.md §7.
//   ⚠ Verify this against the .xci before the first hardware bring-up.
//
// -----------------------------------------------------------------------------
// LATENCY  : Slow path only. Nothing latency-critical crosses PCIe (CLAUDE.md
//            §1). Register access is a split transaction: reg_re asserts, the
//            CSR replies with reg_rvalid an unbounded number of cycles later.
//            DMA write: one 64 B record = one 512-bit beat = one AXI burst of
//            length 1.
// RESOURCE : Hard block (PCIE4C) + AXI bridges. Soft logic estimate:
//            LUT ~1.2 k, FF ~1.5 k, BRAM 0 (the vendor IP's own usage is on top
//            and is reported by the .xci, not estimated here).
// =============================================================================
`default_nettype none

module pcie_wrapper #(
    parameter int unsigned N_LANES    = 16,
    parameter int unsigned BAR_ADDR_W = 16,     // 64 KiB BAR0
    parameter int unsigned DMA_W      = 512     // one 64 B log record per beat
) (
    // ── PCIe physical ────────────────────────────────────────────────────────
    input  var logic                  pcie_refclk_p,
    input  var logic                  pcie_refclk_n,
    input  var logic                  pcie_rst_n,       // active-low PERST#
    input  var logic [N_LANES-1:0]    pcie_rx_p,
    input  var logic [N_LANES-1:0]    pcie_rx_n,
    output var logic [N_LANES-1:0]    pcie_tx_p,
    output var logic [N_LANES-1:0]    pcie_tx_n,

    // ── user clock / reset (single source: clk_rst_gen — see header) ────────
    input  var logic                  pcie_clk,
    input  var logic                  pcie_rst,         // sync, active high

    // ── simple register interface (BAR0), pcie_clk domain ───────────────────
    output var logic [BAR_ADDR_W-1:0] reg_addr,         // BYTE address, [1:0]=0
    output var logic [31:0]           reg_wdata,
    output var logic                  reg_we,           // 1-cycle strobe
    output var logic                  reg_re,           // 1-cycle strobe
    input  var logic [31:0]           reg_rdata,
    input  var logic                  reg_rvalid,       // 1-cycle reply strobe

    // ── DMA write stream to host memory, pcie_clk domain ────────────────────
    input  var logic                  dma_wr_valid,
    output var logic                  dma_wr_ready,
    input  var logic [63:0]           dma_wr_addr,      // host physical address
    input  var logic [DMA_W-1:0]      dma_wr_data,
    input  var logic                  dma_wr_last,

    // ── status ───────────────────────────────────────────────────────────────
    output var logic                  link_up,
    output var logic [2:0]            link_speed,       // 1=Gen1 .. 3=Gen3
    output var logic [5:0]            link_width,       // negotiated lanes
    output var logic [31:0]           pcie_err_cnt      // sticky + count
);

    localparam int unsigned DMA_STRB_W = DMA_W / 8;

`ifdef SIMULATION
    // =========================================================================
    // SIMULATION STUB — no vendor IP, no TLPs, no enumeration.
    // -----------------------------------------------------------------------------
    // The testbench pokes the `sim_*` signals by hierarchical name, e.g. cocotb:
    //
    //   dut.u_host_ctrl.u_pcie.sim_reg_addr.value  = 0x010
    //   dut.u_host_ctrl.u_pcie.sim_reg_wdata.value = 0x0000_0002
    //   dut.u_host_ctrl.u_pcie.sim_reg_we.value    = 1     # one cycle
    //
    // and reads back through sim_reg_rdata / sim_reg_rvalid. Verilator needs the
    // public_flat attributes below (or --public-flat-rw) for VPI access.
    // =========================================================================
    /* verilator lint_off UNDRIVEN */
    logic [BAR_ADDR_W-1:0] sim_reg_addr   /* verilator public_flat_rw */;
    logic [31:0]           sim_reg_wdata  /* verilator public_flat_rw */;
    logic                  sim_reg_we     /* verilator public_flat_rw */;
    logic                  sim_reg_re     /* verilator public_flat_rw */;
    logic                  sim_dma_ready  /* verilator public_flat_rw */;
    logic                  sim_link_force /* verilator public_flat_rw */;
    /* verilator lint_on UNDRIVEN */

    logic [31:0]           sim_reg_rdata  /* verilator public_flat_rd */;
    logic                  sim_reg_rvalid /* verilator public_flat_rd */;
    logic [63:0]           sim_dma_addr   /* verilator public_flat_rd */;
    logic [DMA_W-1:0]      sim_dma_data   /* verilator public_flat_rd */;
    logic [31:0]           sim_dma_cnt    /* verilator public_flat_rd */;

    initial begin
        sim_reg_addr   = '0;
        sim_reg_wdata  = '0;
        sim_reg_we     = 1'b0;
        sim_reg_re     = 1'b0;
        sim_dma_ready  = 1'b1;      // TB may drop this to model ring backpressure
        sim_link_force = 1'b1;
    end

    assign reg_addr  = sim_reg_addr;
    assign reg_wdata = sim_reg_wdata;
    assign reg_we    = sim_reg_we;
    assign reg_re    = sim_reg_re;

    // Read replies are captured so the TB can poll them without racing.
    always_ff @(posedge pcie_clk) begin
        if (pcie_rst) begin
            sim_reg_rdata  <= 32'd0;
            sim_reg_rvalid <= 1'b0;
        end else begin
            sim_reg_rvalid <= reg_rvalid;
            if (reg_rvalid) sim_reg_rdata <= reg_rdata;
        end
    end

    // DMA sink. Records are captured, counted, and (by default) always accepted.
    // Drop sim_dma_ready to model a slow host and exercise the drop/gap-marker
    // path in dma_log_ring — that path MUST be tested, not assumed.
    assign dma_wr_ready = sim_dma_ready;

    always_ff @(posedge pcie_clk) begin
        if (pcie_rst) begin
            sim_dma_cnt <= 32'd0;
        end else if (dma_wr_valid && dma_wr_ready) begin
            sim_dma_addr <= dma_wr_addr;
            sim_dma_data <= dma_wr_data;
            sim_dma_cnt  <= sim_dma_cnt + 32'd1;
        end
    end

    // Model enumeration: the link does NOT come up instantly. A host_ctrl or
    // startup-sequence test that assumes link_up at t=0 is not testing reality.
    localparam int unsigned SIM_LINK_DELAY = 64;
    logic [7:0] sim_link_ctr;

    always_ff @(posedge pcie_clk) begin
        if (pcie_rst) begin
            sim_link_ctr <= 8'd0;
            link_up      <= 1'b0;
        end else begin
            if (sim_link_ctr != 8'(SIM_LINK_DELAY)) begin
                sim_link_ctr <= sim_link_ctr + 8'd1;
            end
            link_up <= sim_link_force && (sim_link_ctr == 8'(SIM_LINK_DELAY));
        end
    end

    assign link_speed   = 3'd3;                    // Gen3
    assign link_width   = 6'(N_LANES);
    assign pcie_err_cnt = 32'd0;
    assign pcie_tx_p    = '0;
    assign pcie_tx_n    = '0;

    // Tie off the unused physical inputs without hiding them from lint.
    /* verilator lint_off UNUSED */
    logic sim_unused;
    assign sim_unused = &{1'b1, pcie_refclk_p, pcie_refclk_n, pcie_rst_n,
                          pcie_rx_p, pcie_rx_n, dma_wr_last};
    /* verilator lint_on UNUSED */

`else
    // =========================================================================
    // SYNTHESIS — vendor PCIe integrated block
    // -----------------------------------------------------------------------------
    // ⚠ The instance below is the AMD/Xilinx XDMA/PCIe-Bridge IP. The module
    //   name and port list MUST come from the CHECKED-IN .xci (ip/xdma_0/) —
    //   manuals/06-operations/01-build-and-release.md §1 forbids auto-upgrading
    //   IP, because `upgrade_ip` silently changes MAC/PCS/PCIe latency. If this
    //   file does not match the .xci, fix the file, do not regenerate the IP.
    //
    //   IP configuration this wrapper assumes:
    //     * PCIe Gen3 x16, 250 MHz user clock
    //     * BAR0: 64 KiB, non-prefetchable, exposed as an AXI4-Lite MASTER
    //       (m_axil_*) into the fabric  -> the CSR register port
    //     * AXI4 SLAVE bridge (s_axib_*), 512-bit, exposed to the fabric as a
    //       master port -> host-memory writes for the DMA log ring
    //     * MSI-X: not used. The control plane is polled at 1-10 Hz
    //       (manuals/06-operations/03-*.md §5); an interrupt on the log ring
    //       would be a per-record host wake-up and is exactly the wrong shape.
    // =========================================================================

    // ── AXI4-Lite (BAR0) from the IP ─────────────────────────────────────────
    logic [31:0]            m_axil_awaddr;
    logic                   m_axil_awvalid;
    logic                   m_axil_awready;
    logic [31:0]            m_axil_wdata;
    logic [3:0]             m_axil_wstrb;
    logic                   m_axil_wvalid;
    logic                   m_axil_wready;
    logic [1:0]             m_axil_bresp;
    logic                   m_axil_bvalid;
    logic                   m_axil_bready;
    logic [31:0]            m_axil_araddr;
    logic                   m_axil_arvalid;
    logic                   m_axil_arready;
    logic [31:0]            m_axil_rdata;
    logic [1:0]             m_axil_rresp;
    logic                   m_axil_rvalid;
    logic                   m_axil_rready;

    // ── AXI4 write channel into the IP's host-memory bridge ──────────────────
    logic [63:0]            s_axib_awaddr;
    logic [7:0]             s_axib_awlen;
    logic [2:0]             s_axib_awsize;
    logic [1:0]             s_axib_awburst;
    logic                   s_axib_awvalid;
    logic                   s_axib_awready;
    logic [DMA_W-1:0]       s_axib_wdata;
    logic [DMA_STRB_W-1:0]  s_axib_wstrb;
    logic                   s_axib_wlast;
    logic                   s_axib_wvalid;
    logic                   s_axib_wready;
    logic [1:0]             s_axib_bresp;
    logic                   s_axib_bvalid;
    logic                   s_axib_bready;

    xdma_0 u_xdma (
        .sys_clk        (pcie_refclk_p),
        .sys_clk_gt     (pcie_refclk_n),
        .sys_rst_n      (pcie_rst_n),
        .pci_exp_rxp    (pcie_rx_p),
        .pci_exp_rxn    (pcie_rx_n),
        .pci_exp_txp    (pcie_tx_p),
        .pci_exp_txn    (pcie_tx_n),
        .axi_aclk       (pcie_clk),
        .axi_aresetn    (~pcie_rst),
        .user_lnk_up    (link_up),
        // BAR0 -> AXI4-Lite master
        .m_axil_awaddr  (m_axil_awaddr),
        .m_axil_awvalid (m_axil_awvalid),
        .m_axil_awready (m_axil_awready),
        .m_axil_wdata   (m_axil_wdata),
        .m_axil_wstrb   (m_axil_wstrb),
        .m_axil_wvalid  (m_axil_wvalid),
        .m_axil_wready  (m_axil_wready),
        .m_axil_bresp   (m_axil_bresp),
        .m_axil_bvalid  (m_axil_bvalid),
        .m_axil_bready  (m_axil_bready),
        .m_axil_araddr  (m_axil_araddr),
        .m_axil_arvalid (m_axil_arvalid),
        .m_axil_arready (m_axil_arready),
        .m_axil_rdata   (m_axil_rdata),
        .m_axil_rresp   (m_axil_rresp),
        .m_axil_rvalid  (m_axil_rvalid),
        .m_axil_rready  (m_axil_rready),
        // AXI4 slave bridge -> host memory writes
        .s_axib_awaddr  (s_axib_awaddr),
        .s_axib_awlen   (s_axib_awlen),
        .s_axib_awsize  (s_axib_awsize),
        .s_axib_awburst (s_axib_awburst),
        .s_axib_awvalid (s_axib_awvalid),
        .s_axib_awready (s_axib_awready),
        .s_axib_wdata   (s_axib_wdata),
        .s_axib_wstrb   (s_axib_wstrb),
        .s_axib_wlast   (s_axib_wlast),
        .s_axib_wvalid  (s_axib_wvalid),
        .s_axib_wready  (s_axib_wready),
        .s_axib_bresp   (s_axib_bresp),
        .s_axib_bvalid  (s_axib_bvalid),
        .s_axib_bready  (s_axib_bready),
        // status
        .cfg_ltssm_state(),
        .cfg_negotiated_width (link_width),
        .cfg_current_speed    (link_speed)
    );

    // =========================================================================
    // AXI4-Lite slave -> simple register port. Vendor-neutral.
    // -----------------------------------------------------------------------------
    // One outstanding transaction. PCIe config access is a handful of MMIO per
    // second (manuals/06-operations/03-*.md §5 caps the scrape at 1-10 Hz), so
    // there is no throughput argument for pipelining this, and a single
    // outstanding transaction makes the CSR side-effect ordering trivially
    // correct — which matters, because reads of the telemetry window and the
    // arm-sequence writes both have side effects.
    // =========================================================================
    typedef enum logic [1:0] {
        AXL_IDLE  = 2'd0,
        AXL_WRITE = 2'd1,
        AXL_READ  = 2'd2,
        AXL_RESP  = 2'd3
    } axl_state_e;

    axl_state_e            axl_state;
    logic [BAR_ADDR_W-1:0] axl_addr_q;
    logic [31:0]           axl_wdata_q;
    logic [31:0]           axl_rdata_q;
    logic                  axl_is_read_q;

    always_ff @(posedge pcie_clk) begin
        if (pcie_rst) begin
            axl_state      <= AXL_IDLE;
            axl_is_read_q  <= 1'b0;
            reg_we         <= 1'b0;
            reg_re         <= 1'b0;
            m_axil_awready <= 1'b0;
            m_axil_wready  <= 1'b0;
            m_axil_arready <= 1'b0;
            m_axil_bvalid  <= 1'b0;
            m_axil_rvalid  <= 1'b0;
            axl_addr_q     <= '0;
            axl_wdata_q    <= '0;
            axl_rdata_q    <= '0;
        end else begin
            reg_we         <= 1'b0;
            reg_re         <= 1'b0;
            m_axil_awready <= 1'b0;
            m_axil_wready  <= 1'b0;
            m_axil_arready <= 1'b0;

            unique case (axl_state)
                AXL_IDLE: begin
                    // Writes take priority: a kill write must never queue behind
                    // a telemetry read.
                    if (m_axil_awvalid && m_axil_wvalid) begin
                        m_axil_awready <= 1'b1;
                        m_axil_wready  <= 1'b1;
                        axl_addr_q     <= m_axil_awaddr[BAR_ADDR_W-1:0];
                        axl_wdata_q    <= m_axil_wdata;
                        axl_is_read_q  <= 1'b0;
                        // Address, data and strobe all land on the same edge, so
                        // the CSR sees a coherent single-cycle write.
                        reg_we         <= 1'b1;
                        axl_state      <= AXL_WRITE;
                    end else if (m_axil_arvalid) begin
                        m_axil_arready <= 1'b1;
                        axl_addr_q     <= m_axil_araddr[BAR_ADDR_W-1:0];
                        axl_is_read_q  <= 1'b1;
                        reg_re         <= 1'b1;
                        axl_state      <= AXL_READ;
                    end
                end

                AXL_WRITE: begin
                    // reg_we self-clears (defaulted low above): one cycle only.
                    m_axil_bvalid <= 1'b1;
                    axl_state     <= AXL_RESP;
                end

                AXL_READ: begin
                    // reg_re self-clears. Wait for the CSR's split reply, which
                    // may be many cycles away when the address falls in the
                    // telemetry window and has to cross to core_clk and back.
                    if (reg_rvalid) begin
                        axl_rdata_q   <= reg_rdata;
                        m_axil_rvalid <= 1'b1;
                        axl_state     <= AXL_RESP;
                    end
                end

                AXL_RESP: begin
                    if (m_axil_bvalid && m_axil_bready) begin
                        m_axil_bvalid <= 1'b0;
                        axl_state     <= AXL_IDLE;
                    end
                    if (m_axil_rvalid && m_axil_rready) begin
                        m_axil_rvalid <= 1'b0;
                        axl_state     <= AXL_IDLE;
                    end
                end

                default: axl_state <= AXL_IDLE;
            endcase
        end
    end

    assign reg_addr     = axl_addr_q;
    assign reg_wdata    = axl_wdata_q;
    assign m_axil_bresp = 2'b00;                // OKAY: unmapped reads return a
    assign m_axil_rresp = 2'b00;                // sentinel, never a SLVERR
    assign m_axil_rdata = axl_rdata_q;

    // =========================================================================
    // DMA write stream -> AXI4 single-beat burst. Vendor-neutral.
    // =========================================================================
    typedef enum logic [1:0] {
        DMA_IDLE = 2'd0,
        DMA_ADDR = 2'd1,
        DMA_DATA = 2'd2,
        DMA_BRSP = 2'd3
    } dma_state_e;

    dma_state_e dma_state;
    logic       aw_done_q;
    logic       w_done_q;

    always_ff @(posedge pcie_clk) begin
        if (pcie_rst) begin
            dma_state      <= DMA_IDLE;
            s_axib_awvalid <= 1'b0;
            s_axib_wvalid  <= 1'b0;
            aw_done_q      <= 1'b0;
            w_done_q       <= 1'b0;
            s_axib_awaddr  <= '0;
            s_axib_wdata   <= '0;
            dma_wr_ready   <= 1'b0;
        end else begin
            dma_wr_ready <= 1'b0;

            unique case (dma_state)
                DMA_IDLE: begin
                    if (dma_wr_valid) begin
                        s_axib_awaddr  <= dma_wr_addr;
                        s_axib_wdata   <= dma_wr_data;
                        s_axib_awvalid <= 1'b1;
                        s_axib_wvalid  <= 1'b1;
                        aw_done_q      <= 1'b0;
                        w_done_q       <= 1'b0;
                        dma_state      <= DMA_ADDR;
                    end
                end

                DMA_ADDR, DMA_DATA: begin
                    if (s_axib_awvalid && s_axib_awready) begin
                        s_axib_awvalid <= 1'b0;
                        aw_done_q      <= 1'b1;
                    end
                    if (s_axib_wvalid && s_axib_wready) begin
                        s_axib_wvalid <= 1'b0;
                        w_done_q      <= 1'b1;
                    end
                    if ((aw_done_q || (s_axib_awvalid && s_axib_awready)) &&
                        (w_done_q  || (s_axib_wvalid  && s_axib_wready))) begin
                        dma_state <= DMA_BRSP;
                    end else begin
                        dma_state <= DMA_DATA;
                    end
                end

                DMA_BRSP: begin
                    if (s_axib_bvalid) begin
                        dma_wr_ready <= 1'b1;    // record retired
                        dma_state    <= DMA_IDLE;
                    end
                end

                default: dma_state <= DMA_IDLE;
            endcase
        end
    end

    assign s_axib_awlen   = 8'd0;                    // single beat
    assign s_axib_awsize  = 3'd6;                    // 2^6 = 64 bytes
    assign s_axib_awburst = 2'b01;                   // INCR
    assign s_axib_wstrb   = {DMA_STRB_W{1'b1}};
    assign s_axib_wlast   = 1'b1;
    assign s_axib_bready  = 1'b1;

    // =========================================================================
    // Error counting. ⚠ CLAUDE.md §5.7: every error is counted in a readable
    // register. A PCIe error while armed is a Tier-1 alert
    // (manuals/06-operations/03-*.md §7).
    // =========================================================================
    always_ff @(posedge pcie_clk) begin
        if (pcie_rst) begin
            pcie_err_cnt <= 32'd0;
        end else if (((m_axil_bvalid && (m_axil_bresp != 2'b00)) ||
                      (s_axib_bvalid && (s_axib_bresp != 2'b00))) &&
                     (pcie_err_cnt != 32'hFFFF_FFFF)) begin
            pcie_err_cnt <= pcie_err_cnt + 32'd1;
        end
    end

    /* verilator lint_off UNUSED */
    logic syn_unused;
    assign syn_unused = &{1'b1, m_axil_wstrb, m_axil_awaddr[31:BAR_ADDR_W],
                          m_axil_araddr[31:BAR_ADDR_W], dma_wr_last,
                          axl_is_read_q};
    /* verilator lint_on UNUSED */
`endif

    // =========================================================================
    // Assertions — simulation only
    // =========================================================================
`ifndef SYNTHESIS
    initial begin
        if (DMA_W != 512) begin
            $warning("pcie_wrapper: DMA_W=%0d. dma_log_ring emits 512-bit records; a mismatch means a record spans beats and CAN be torn.",
                     DMA_W);
        end
    end

    // The register port is a strobe interface: we and re are mutually exclusive
    // and must never be levels.
    assert property (@(posedge pcie_clk) disable iff (pcie_rst)
        !(reg_we && reg_re)
    ) else $error("pcie_wrapper: simultaneous register read and write");

    assert property (@(posedge pcie_clk) disable iff (pcie_rst)
        reg_we |=> !reg_we
    ) else $error("pcie_wrapper: reg_we was not a one-cycle strobe");

    // The DMA stream must hold data stable while valid is waiting for ready:
    // a record that changes mid-handshake lands half-written in host memory.
    assert property (@(posedge pcie_clk) disable iff (pcie_rst)
        (dma_wr_valid && !dma_wr_ready) |=> (dma_wr_valid && $stable(dma_wr_data)
                                                          && $stable(dma_wr_addr))
    ) else $error("pcie_wrapper: DMA record changed while awaiting ready");
`endif

endmodule : pcie_wrapper

`default_nettype wire
