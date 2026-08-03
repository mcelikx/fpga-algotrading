// =============================================================================
// tb_book_engine_top.sv — flattening wrapper around book_engine for cocotb
// -----------------------------------------------------------------------------
// SIMULATION ONLY. Never compiled into a bitstream, never listed in
// rtl/filelist.f. Its sole job is to expose book_engine's packed-struct ports as
// individual scalar signals, because driving a packed struct through the VPI
// is awkward and error-prone under Verilator.
// (A comment line starting with the simulator's name is parsed as a lint
//  pragma, hence the wording.)
//
// ⚠️ THIS WRAPPER MUST CONTAIN NO LOGIC BEYOND FIELD PLUMBING.
//    A testbench wrapper that "helpfully" registers, gates or defaults a signal
//    changes what is under test, and the resulting pass or failure is then a
//    statement about the wrapper. Every assignment below is a rename and
//    nothing else. If you find yourself adding an `if`, stop.
//
// Naming contract, relied upon by tb/book/test_book_soak.py:
//     s_evt_<field>   for every member of trading_pkg::book_evt_t
//     m_top_<field>   for every member of trading_pkg::book_top_t
// The test constructs these names dynamically, so a field renamed in
// trading_pkg.sv breaks the test loudly at elaboration rather than silently
// comparing the wrong thing.
//
// Governing manual: manuals/01-fpga-design/05-verification-and-simulation.md
// =============================================================================
`default_nettype none

module tb_book_engine_top
    import trading_pkg::*;
    import book_pkg::*;
#(
    parameter int unsigned N_LEVELS = book_pkg::LEVELS,
    parameter int unsigned ENC_PIPE = 1
) (
    input  var logic              clk,
    input  var logic              rst,

    // ── book_evt_t, flattened ────────────────────────────────────────────────
    input  var logic              s_evt_valid,
    input  var logic [2:0]        s_evt_op,             // book_op_e
    input  var logic [ACT_IDX_W-1:0] s_evt_sym,
    input  var logic [15:0]       s_evt_locate,
    input  var logic              s_evt_side,           // side_e
    input  var logic [PRICE_W-1:0] s_evt_price,
    input  var logic [QTY_W-1:0]  s_evt_qty,
    input  var logic [63:0]       s_evt_order_ref,
    input  var logic [63:0]       s_evt_new_order_ref,
    input  var logic [47:0]       s_evt_exch_ts,
    input  var logic [CYCLE_CNT_W-1:0] s_evt_rx_cycle,
    input  var logic              s_evt_printable,

    // ── Host reference-price port ────────────────────────────────────────────
    input  var logic              cfg_ref_valid,
    input  var logic [ACT_IDX_W-1:0] cfg_ref_sym,
    input  var logic [PRICE_W-1:0] cfg_ref_px,
    output var logic              cfg_ref_ready,

    // ── book_top_t, flattened ────────────────────────────────────────────────
    output var logic              m_top_valid,
    output var logic [ACT_IDX_W-1:0] m_top_sym,
    output var logic [PRICE_W-1:0] m_top_bid_px,
    output var logic [QTY_W-1:0]  m_top_bid_qty,
    output var logic [PRICE_W-1:0] m_top_ask_px,
    output var logic [QTY_W-1:0]  m_top_ask_qty,
    output var logic [PRICE_W-1:0] m_top_last_px,
    output var logic              m_top_bid_valid,
    output var logic              m_top_ask_valid,
    output var logic              m_top_crossed,
    output var logic              m_top_stale,
    output var logic              m_top_top_changed,
    output var logic [CYCLE_CNT_W-1:0] m_top_rx_cycle,

    // ── Telemetry, unpacked so cocotb can index it ───────────────────────────
    output var logic [31:0]       stat0,  output var logic [31:0] stat1,
    output var logic [31:0]       stat2,  output var logic [31:0] stat3,
    output var logic [31:0]       stat4,  output var logic [31:0] stat5,
    output var logic [31:0]       stat6,  output var logic [31:0] stat7,
    output var logic [31:0]       stat8,  output var logic [31:0] stat9,
    output var logic [31:0]       stat10, output var logic [31:0] stat11,
    output var logic [31:0]       stat12, output var logic [31:0] stat13,
    output var logic [31:0]       stat14, output var logic [31:0] stat15
);

    // ── Pack the input struct ────────────────────────────────────────────────
    book_evt_t evt;
    always_comb begin
        evt.op            = book_op_e'(s_evt_op);
        evt.sym           = s_evt_sym;
        evt.locate        = s_evt_locate;
        evt.side          = side_e'(s_evt_side);
        evt.price         = s_evt_price;
        evt.qty           = s_evt_qty;
        evt.order_ref     = s_evt_order_ref;
        evt.new_order_ref = s_evt_new_order_ref;
        evt.exch_ts       = s_evt_exch_ts;
        evt.rx_cycle      = s_evt_rx_cycle;
        evt.printable     = s_evt_printable;
    end

    book_top_t   top;
    logic [31:0] stat_arr [16];

    book_engine #(
        .N_LEVELS (N_LEVELS),
        .ENC_PIPE (ENC_PIPE)
    ) u_dut (
        .clk           (clk),
        .rst           (rst),
        .s_evt         (evt),
        .s_evt_valid   (s_evt_valid),
        .cfg_ref_valid (cfg_ref_valid),
        .cfg_ref_sym   (cfg_ref_sym),
        .cfg_ref_px    (cfg_ref_px),
        .cfg_ref_ready (cfg_ref_ready),
        .m_top         (top),
        .m_top_valid   (m_top_valid),
        .stat          (stat_arr)
    );

    // ── Unpack the output struct ─────────────────────────────────────────────
    always_comb begin
        m_top_sym         = top.sym;
        m_top_bid_px      = top.bid_px;
        m_top_bid_qty     = top.bid_qty;
        m_top_ask_px      = top.ask_px;
        m_top_ask_qty     = top.ask_qty;
        m_top_last_px     = top.last_px;
        m_top_bid_valid   = top.bid_valid;
        m_top_ask_valid   = top.ask_valid;
        m_top_crossed     = top.crossed;
        m_top_stale       = top.stale;
        m_top_top_changed = top.top_changed;
        m_top_rx_cycle    = top.rx_cycle;

        stat0  = stat_arr[0];   stat1  = stat_arr[1];
        stat2  = stat_arr[2];   stat3  = stat_arr[3];
        stat4  = stat_arr[4];   stat5  = stat_arr[5];
        stat6  = stat_arr[6];   stat7  = stat_arr[7];
        stat8  = stat_arr[8];   stat9  = stat_arr[9];
        stat10 = stat_arr[10];  stat11 = stat_arr[11];
        stat12 = stat_arr[12];  stat13 = stat_arr[13];
        stat14 = stat_arr[14];  stat15 = stat_arr[15];
    end

`ifndef SYNTHESIS
    // The wrapper's own contract: it must be transparent. If the packed value
    // the DUT sees ever disagrees with the flat inputs, every result from this
    // testbench is a statement about the wrapper rather than about the book.
    always_comb begin
        assert (evt.price == s_evt_price)
            else $error("tb_book_engine_top: wrapper corrupted price on the way in");
        assert (top.bid_px == m_top_bid_px)
            else $error("tb_book_engine_top: wrapper corrupted bid_px on the way out");
    end
`endif

endmodule : tb_book_engine_top

`default_nettype wire
