// =============================================================================
// cdc_handshake.sv — 4-phase req/ack handshake for a WIDE bus crossing domains
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/00-foundations/04-clocking-reset-and-cdc.md §3.4, §5
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   Move an infrequent, WIDE control value across a clock boundary without
//   paying for a FIFO. Legitimate users: host risk-limit and strategy-parameter
//   writes, OUCH template loads, session config, telemetry read-back addresses —
//   i.e. everything on the PCIe <-> core_clk control plane.
//
//   Protocol (manual §3.4):
//     src: latch data (held stable for the whole exchange) -> assert req
//     dst: sync req -> capture data -> assert ack
//     src: sync ack -> de-assert req  (data may now change)
//     dst: sync !req -> de-assert ack
//     src: sync !ack -> src_ready again
//
// LATENCY
//   Round trip = 2*(SYNC_STAGES) + a few cycles in each domain.
//   With SYNC_STAGES=2: ~5 dst cycles to `dst_valid`, ~9-11 src cycles until
//   `src_ready` returns. At 156.25 MHz that is ~60-70 ns per transfer, so the
//   sustained rate is roughly one word per 10 cycles.
//   ⚠️ CONTROL PLANE ONLY. This is two orders of magnitude too slow for the
//      tick-to-trade path (CLAUDE.md §1: anything not in nanoseconds is slow path).
//
// RESOURCE
//   W FF (source hold register) + W FF (destination capture register)
//   + ~4*SYNC_STAGES + 6 FF of control. 0 BRAM. 0 DSP.
//   W=64 -> ~140 FF, a handful of LUTs.
//
// -----------------------------------------------------------------------------
// ⚠️  THE DATA BUS IS NOT SYNCHRONIZED — AND MUST NOT BE
//   `src_data_q` goes straight into `dst_data_q` as a plain asynchronous path.
//   That is correct BECAUSE the protocol guarantees the bus is stable for the
//   entire window in which the destination samples it. Putting a 2-FF chain on
//   each bit would be the classic multi-bit CDC bug (manual §2), not a fix.
//   The price of this is that the path MUST be constrained — see the XDC block
//   below. An unconstrained "it's a false path" bus is how you get torn data at
//   the top of the temperature range and a price that was never quoted.
//
// ⚠️  NEVER `set_false_path` THIS BUS (manual §5). false_path tells the tool
//   "route it however you like", and it will happily give one bit 8 ns and
//   another 0.5 ns. Use set_max_delay -datapath_only AND set_bus_skew.
//
// ⚠️  BOTH RESETS MUST DERIVE FROM THE SAME ROOT RESET, one `reset_sync` per
//   domain. Resetting one side only leaves req/ack out of phase and the channel
//   deadlocks (src_ready never returns).
//
// =============================================================================
// XDC — COPY THIS BLOCK INTO constraints/cdc.xdc AND ADJUST THE INSTANCE PATH
// AND THE NUMBERS. `<dst_period_ns>` is the DESTINATION clock period; core_clk
// is 6.400 ns, pcie_clk is 4.000 ns. Take the smaller of the two periods for
// -datapath_only, and the destination period for -set_bus_skew.
// -----------------------------------------------------------------------------
//   # 1. Declare the domains asynchronous (once, globally).
//   set_clock_groups -asynchronous \
//       -group [get_clocks core_clk] \
//       -group [get_clocks pcie_clk]
//
//   # 2. Bound the unsynchronized data path. -datapath_only removes clock skew
//   #    and uncertainty from the check, leaving only the routing delay, which
//   #    is exactly what we care about here.
//   set_max_delay -datapath_only \
//       -from [get_cells -hier -filter {NAME =~ *u_cfg_cdc/src_data_q_reg[*]}] \
//       -to   [get_cells -hier -filter {NAME =~ *u_cfg_cdc/dst_data_q_reg[*]}] \
//       4.000
//
//   # 3. Bound the SKEW BETWEEN BITS. Without this, max_delay alone still lets
//   #    bit 0 arrive 0.4 ns and bit 63 arrive 3.9 ns; if req lands in between,
//   #    the capture is torn. Skew must be < one destination clock period.
//   set_bus_skew \
//       -from [get_cells -hier -filter {NAME =~ *u_cfg_cdc/src_data_q_reg[*]}] \
//       -to   [get_cells -hier -filter {NAME =~ *u_cfg_cdc/dst_data_q_reg[*]}] \
//       4.000
//
//   # 4. The req/ack bits cross through cdc_sync_bit chains. Keep the chains
//   #    packed and bound the source-to-first-stage hop.
//   set_property ASYNC_REG TRUE \
//       [get_cells -hier -filter {NAME =~ *u_*_sync/sync_q_reg[*]}]
//   set_max_delay -datapath_only \
//       -from [get_cells -hier -filter {NAME =~ *u_cfg_cdc/req_q_reg}] \
//       -to   [get_cells -hier -filter {NAME =~ *u_cfg_cdc/u_req_sync/sync_q_reg[0]}] \
//       4.000
//   set_max_delay -datapath_only \
//       -from [get_cells -hier -filter {NAME =~ *u_cfg_cdc/ack_q_reg}] \
//       -to   [get_cells -hier -filter {NAME =~ *u_cfg_cdc/u_ack_sync/sync_q_reg[0]}] \
//       6.400
//
//   # 5. Prove it. Run report_cdc on every build and treat findings as errors
//   #    (manual §6). STA does not check CDC correctness — by definition.
//   #    report_cdc -details -file reports/cdc.rpt
// =============================================================================
`default_nettype none

module cdc_handshake #(
    parameter int unsigned W           = 32,
    parameter int unsigned SYNC_STAGES = 2
) (
    // ── Source domain ────────────────────────────────────────────────────────
    input  var logic          src_clk,
    input  var logic          src_rst,     // synchronous, active high
    input  var logic [W-1:0]  src_data,
    input  var logic          src_valid,   // request a transfer
    output var logic          src_ready,   // 1 = channel idle, will accept

    // ── Destination domain ───────────────────────────────────────────────────
    input  var logic          dst_clk,
    input  var logic          dst_rst,     // synchronous, active high
    output var logic [W-1:0]  dst_data,    // stable; qualified by dst_valid
    output var logic          dst_valid    // single-cycle strobe, dst_clk domain
);

    // -------------------------------------------------------------------------
    // Declarations (all up front — `ack_q` is produced in the destination
    // domain and consumed by a synchronizer instantiated in the source domain)
    // -------------------------------------------------------------------------
    // Data hold register. NOT reset: it is datapath, and it is never read until
    // req has been asserted, which only happens after a real write (manual 03 §6).
    logic [W-1:0] src_data_q;

    logic req_q;        // request level, crosses to dst (unsynchronized source)
    logic ack_sync;     // ack level, synchronized into src
    logic accept;

    logic req_sync;     // req level, synchronized into dst
    logic req_sync_q;
    logic ack_q;        // ack level, crosses to src (unsynchronized source)

    // -------------------------------------------------------------------------
    // Source domain
    // -------------------------------------------------------------------------
    assign src_ready = !req_q && !ack_sync;
    assign accept    = src_valid && src_ready;

    always_ff @(posedge src_clk) begin
        if (accept) src_data_q <= src_data;      // datapath: no reset
    end

    always_ff @(posedge src_clk) begin
        if (src_rst) begin
            req_q <= 1'b0;
        end else if (accept) begin
            req_q <= 1'b1;                       // phase 1: assert req
        end else if (req_q && ack_sync) begin
            req_q <= 1'b0;                       // phase 3: ack seen, drop req
        end
    end

    cdc_sync_bit #(.STAGES(SYNC_STAGES), .INIT_VAL(1'b0)) u_ack_sync (
        .dst_clk (src_clk),
        .src_bit (ack_q),
        .dst_bit (ack_sync)
    );

    // -------------------------------------------------------------------------
    // Destination domain
    // -------------------------------------------------------------------------
    cdc_sync_bit #(.STAGES(SYNC_STAGES), .INIT_VAL(1'b0)) u_req_sync (
        .dst_clk (dst_clk),
        .src_bit (req_q),
        .dst_bit (req_sync)
    );

    always_ff @(posedge dst_clk) begin
        if (dst_rst) req_sync_q <= 1'b0;
        else         req_sync_q <= req_sync;
    end

    // Capture on the RISING edge of the synchronized request. By this point the
    // source has held src_data_q stable for at least SYNC_STAGES dst cycles, so
    // every bit has settled — that is the whole justification for not
    // synchronizing the bus. See the XDC block above; the constraint is what
    // makes "at least SYNC_STAGES cycles of settling" true in silicon.
    always_ff @(posedge dst_clk) begin
        if (req_sync && !req_sync_q) dst_data <= src_data_q;   // datapath: no reset
    end

    always_ff @(posedge dst_clk) begin
        if (dst_rst) begin
            dst_valid <= 1'b0;
            ack_q     <= 1'b0;
        end else begin
            dst_valid <= req_sync && !req_sync_q;   // registered 1-cycle strobe
            // phase 2: raise ack while req is up; phase 4: drop it when req drops
            ack_q     <= req_sync;
        end
    end

    // -------------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    initial begin
        if (SYNC_STAGES < 2) begin
            $error("cdc_handshake: SYNC_STAGES must be >= 2 (got %0d).", SYNC_STAGES);
            $fatal(1);
        end
        if (W < 1) begin
            $error("cdc_handshake: W must be >= 1 (got %0d).", W);
            $fatal(1);
        end
    end

    // Stream contract, source side: src_data must be stable while stalled.
    assert property (@(posedge src_clk) disable iff (src_rst)
        (src_valid && !src_ready) |=> (src_valid && $stable(src_data)))
        else $error("cdc_handshake: source stream contract violated");

    // The held bus must not move while a request is outstanding — this is the
    // protocol guarantee the unsynchronized data path depends on.
    assert property (@(posedge src_clk) disable iff (src_rst)
        req_q |=> $stable(src_data_q))
        else $error("cdc_handshake: src_data_q changed while req asserted — TORN DATA");

    // dst_valid is exactly one cycle wide.
    assert property (@(posedge dst_clk) disable iff (dst_rst)
        dst_valid |=> !dst_valid)
        else $error("cdc_handshake: dst_valid wider than one cycle");

    // No new request may be launched before the previous one has fully retired.
    assert property (@(posedge src_clk) disable iff (src_rst)
        accept |=> !src_ready)
        else $error("cdc_handshake: overlapping transfers");

    // Liveness: every accepted transfer completes.
    assert property (@(posedge src_clk) disable iff (src_rst)
        accept |-> ##[1:$] src_ready)
        else $error("cdc_handshake: transfer never completed — dst_clk stopped or resets out of phase");
`endif

endmodule : cdc_handshake

`default_nettype wire
