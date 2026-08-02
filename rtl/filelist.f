// =============================================================================
// rtl/filelist.f — THE canonical compile order for the synthesizable tree
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Consumed by:
//   * scripts/build.tcl   (Vivado non-project mode — parses this file)
//   * scripts/lint.sh     (Verilator: `verilator -f rtl/filelist.f`)
//   * tb/*/Makefile       (cocotb VERILOG_SOURCES, via the same parser)
//
// FORMAT
//   - One path per line, relative to the REPOSITORY ROOT.
//   - `//` starts a comment; blank lines ignored.
//   - `+incdir+<dir>` lines are include-search directories.
//   - `-f <file>` style recursion is deliberately NOT used: one flat, readable,
//     reviewable order beats a tree of includes you have to chase.
//
// ORDERING RULE — this is the whole point of the file
//   1. Packages FIRST, in dependency order. SystemVerilog `import` requires the
//      package to be *already compiled*; a package that appears after its
//      importer produces "cannot find package" from Verilator and a much less
//      helpful error from Vivado.
//   2. Then rtl/common/ — the sanctioned primitives everything else instances.
//   3. Then leaf blocks, bottom-up, in dataflow order (eth -> net -> feed ->
//      book -> strategy -> risk -> order -> ctrl -> telemetry).
//   4. Top level LAST.
//
// ⚠️ Adding a file? Put it in the right section. A file appended to the bottom
//    "because it compiled" is a latent ordering bug that surfaces the day
//    someone adds a package dependency.
// =============================================================================

// -----------------------------------------------------------------------------
// Include search paths
// -----------------------------------------------------------------------------
// rtl/pkg holds the interface-contract packages; every block `import`s from it.
+incdir+rtl/pkg
// Block-local packages are include-visible too, so a block's own testbench can
// pull in just what it needs without depending on the whole tree.
+incdir+rtl/net
+incdir+rtl/book
+incdir+rtl/strategy
+incdir+rtl/order
+incdir+rtl/telemetry
+incdir+rtl/common

// =============================================================================
// 1. PACKAGES — compiled first, in dependency order
// =============================================================================
// trading_pkg is the root interface contract (types, widths, risk reasons).
// Nothing may be compiled before it.
rtl/pkg/trading_pkg.sv
// itch_pkg depends on nothing but is used by feed/ and net/.
rtl/pkg/itch_pkg.sv
// sat_arith_pkg: saturating arithmetic helpers used by risk/ and book/.
rtl/pkg/sat_arith_pkg.sv

// Block-local packages. These import trading_pkg, hence they follow it.
rtl/net/net_rx_pkg.sv
rtl/book/book_pkg.sv
rtl/strategy/strategy_pkg.sv
rtl/order/ouch_pkg.sv
rtl/telemetry/telemetry_pkg.sv

// =============================================================================
// 2. COMMON PRIMITIVES — rtl/common/
// =============================================================================
// CDC primitives first: everything else may instance them, nothing here
// instances anything above it. See manuals/00-foundations/04-*.md §3.
rtl/common/cdc_sync_bit.sv
rtl/common/reset_sync.sv
rtl/common/cdc_pulse.sv
rtl/common/cdc_handshake.sv

// Storage and flow control.
rtl/common/sync_fifo.sv
rtl/common/async_fifo.sv         // instances cdc_sync_bit (gray pointers)
rtl/common/skid_buffer.sv
rtl/common/delay_line.sv

// Arbitration / encoding.
rtl/common/prio_encoder.sv
rtl/common/rr_arbiter.sv         // instances prio_encoder
rtl/common/fixed_arbiter.sv

// Clocking and counters.
rtl/common/clk_rst_gen.sv        // instances reset_sync; wraps MMCM/BUFG
rtl/common/counter_bank.sv

// =============================================================================
// 3. ETHERNET / MAC — rtl/eth/
// =============================================================================
rtl/eth/crc32_eth.sv
rtl/eth/gt_wrapper_stub.sv       // simulation stub; real GT IP comes from ip/*.xci
rtl/eth/mac_rx.sv                // instances crc32_eth, async_fifo
rtl/eth/mac_tx.sv                // instances crc32_eth, async_fifo
rtl/eth/eth_10g_wrapper.sv       // instances gt_wrapper_stub, mac_rx, mac_tx

// =============================================================================
// 4. NETWORK RX PATH — rtl/net/
// =============================================================================
rtl/net/eth_ip_udp_rx.sv
rtl/net/moldudp64_deframer.sv
rtl/net/ab_arbiter.sv
rtl/net/net_rx_path.sv           // instances the three above, x N_FEEDS

// =============================================================================
// 5. FEED HANDLER — rtl/feed/
// =============================================================================
rtl/feed/itch_decoder.sv
rtl/feed/symbol_filter.sv
rtl/feed/venue_state.sv
rtl/feed/feed_handler.sv         // instances the three above

// =============================================================================
// 6. ORDER BOOK — rtl/book/
// =============================================================================
rtl/book/order_id_map.sv
rtl/book/price_levels.sv
rtl/book/top_of_book.sv
rtl/book/book_engine.sv          // instances the three above

// =============================================================================
// 7. STRATEGY — rtl/strategy/
// =============================================================================
rtl/strategy/param_table.sv
rtl/strategy/trigger_logic.sv
rtl/strategy/position_track.sv
rtl/strategy/trade_gate.sv
rtl/strategy/strategy_engine.sv  // instances the four above

// =============================================================================
// 8. PRE-TRADE RISK — rtl/risk/
// -----------------------------------------------------------------------------
// CLAUDE.md §5.5: every outbound order passes through this block. There is no
// bypass, and no file here may be omitted from a build.
// =============================================================================
rtl/risk/risk_params.sv
rtl/risk/position_monitor.sv
rtl/risk/rate_limiter.sv
rtl/risk/order_token_gen.sv
rtl/risk/kill_switch.sv
rtl/risk/risk_gate.sv            // instances the five above

// =============================================================================
// 9. ORDER GATEWAY — rtl/order/
// =============================================================================
rtl/order/ouch_encoder.sv
rtl/order/ouch_rx.sv
rtl/order/soupbin_tx.sv
rtl/order/tcp_tx_lite.sv
rtl/order/credit_mgr.sv
rtl/order/order_gateway.sv       // instances the five above

// =============================================================================
// 10. TELEMETRY — rtl/telemetry/
// =============================================================================
rtl/telemetry/latency_hist.sv
rtl/telemetry/telemetry.sv       // instances latency_hist, counter_bank

// =============================================================================
// 11. HOST CONTROL PLANE — rtl/ctrl/  (SLOW PATH)
// =============================================================================
rtl/ctrl/csr_regfile.sv
rtl/ctrl/dma_log_ring.sv
rtl/ctrl/pcie_wrapper.sv
rtl/ctrl/host_ctrl.sv            // instances the three above + cdc_handshake

// =============================================================================
// 12. TOP LEVEL — always last
// =============================================================================
rtl/fpga_top.sv
