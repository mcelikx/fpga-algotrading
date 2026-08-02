// =============================================================================
// tb/filelist.f — testbench-ONLY SystemVerilog sources
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
//
// ⚠️ NOTHING IN THIS FILE IS SYNTHESIZED. If a file is needed by the bitstream
//    it belongs in rtl/filelist.f, not here. `scripts/build.tcl` never reads
//    this file; only the simulation flows do.
//
// USAGE
//   Simulation compile order is:  rtl/filelist.f  THEN  tb/filelist.f
//   (the bind files reference RTL module names, so the RTL must exist first).
//
//     verilator --lint-only -f rtl/filelist.f -f tb/filelist.f
//     make -C tb/book sim            # cocotb; see scripts/Makefile
//
// WHY THE ASSERTIONS LIVE HERE AND NOT INLINE IN THE RTL
//   manuals/01-fpga-design/05-verification-and-simulation.md §5: properties go
//   in separate `bind` files. The synthesizable source stays free of `ifdef`
//   clutter, and the properties may use non-synthesizable constructs freely.
//   fpga_top.sv keeps a small inline set for the four top-level safety
//   invariants only — those are deliberate and are documented in its header.
//
// FORMAT: identical to rtl/filelist.f — `//` comments, `+incdir+`, one path per
// line relative to the repository root.
// =============================================================================

// -----------------------------------------------------------------------------
// Include search paths
// -----------------------------------------------------------------------------
+incdir+rtl/pkg
+incdir+tb/sva

// =============================================================================
// 1. SVA property modules — one per RTL module, bound in section 2
// -----------------------------------------------------------------------------
// Naming rule: <rtl_module>_props.sv, ports connected with `.*`.
// A module with no _props file has no protocol checking, and a fast-path module
// with no protocol checking does not pass review.
// =============================================================================
tb/sva/axis_props.sv             // the reusable AXI-Stream contract checker
tb/sva/fifo_props.sv             // never write-when-full / read-when-empty
tb/sva/mac_rx_props.sv           // ⚠️ asserts tready is ALWAYS high (CLAUDE.md §5.4)
tb/sva/net_rx_path_props.sv
tb/sva/itch_decoder_props.sv     // decoded locate in range; length checked
tb/sva/book_engine_props.sv      // never crossed-and-actionable; qty never wraps
tb/sva/strategy_engine_props.sv
tb/sva/risk_gate_props.sv        // ⚠️ order_out_valid |-> risk verdict was RISK_OK
tb/sva/kill_switch_props.sv      // ⚠️ kill |-> ##[0:KILL_RESP_CYCLES] !out_valid
tb/sva/ouch_encoder_props.sv     // emitted length == OUCH length field
tb/sva/host_ctrl_props.sv        // handshake req/ack protocol on every CDC

// =============================================================================
// 2. Bind file — attaches section 1 to the RTL
// -----------------------------------------------------------------------------
// Single file so the whole assertion attachment surface is reviewable in one
// diff, and so a rename that breaks a bind fails loudly in one place.
// =============================================================================
tb/sva/bind_all.sv

// =============================================================================
// 3. Simulation-only models and shims
// -----------------------------------------------------------------------------
// Behavioural stand-ins for vendor IP that Verilator cannot compile (encrypted
// GT/PCIe models). Tier 4 (vendor sim) swaps these for the real .xci models —
// see manuals/01-fpga-design/05-verification-and-simulation.md §3.
// =============================================================================
tb/model/gt_loopback_model.sv    // TX->RX fibre loopback for tier-6 rehearsal in sim
tb/model/pcie_bfm.sv             // BAR read/write bus-functional model
tb/model/clk_phase_jitter.sv     // randomized CDC clock phase (§6.2 of the CDC manual)

// =============================================================================
// 4. Per-block cocotb top wrappers
// -----------------------------------------------------------------------------
// cocotb needs a concrete toplevel per test target. These wrappers exist only to
// expose flat, stable port names to Python (packed structs are awkward to poke
// through the VPI) and to instance the DUT unchanged.
// ⚠️ A wrapper must never contain logic. If it does, the test is testing the
//    wrapper. Wiring and width adaptation only.
// =============================================================================
tb/feed/tb_itch_decoder_top.sv
tb/book/tb_book_engine_top.sv
tb/risk/tb_risk_gate_top.sv
tb/order/tb_ouch_encoder_top.sv
tb/net/tb_net_rx_path_top.sv
tb/strategy/tb_strategy_engine_top.sv
