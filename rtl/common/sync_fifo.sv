// =============================================================================
// sync_fifo.sv — Single-clock FIFO with high-water and sticky error telemetry
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/01-fpga-design/03-memory-and-storage.md
//           manuals/01-fpga-design/01-rtl-design-patterns.md §1, §9
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   Elastic buffering WITHIN core_clk: absorbing a burst of ITCH messages behind
//   a slower consumer, queueing outbound orders behind the TX MAC, holding
//   telemetry samples for the host. Same interface shape and same read timing as
//   `async_fifo`, so the two are interchangeable at a call site.
//
//   ⚠️ THIS IS NOT A CDC PRIMITIVE. One clock only. If the two ends are on
//      different clocks, `async_fifo` is the ONLY correct answer.
//
// LATENCY
//   Write to readable (`empty` falls) : 1 cycle  =  6.4 ns @ 156.25 MHz.
//   Read command to data              : 1 cycle  =  6.4 ns  (rd_en -> rd_valid).
//   Throughput: one write and one read per cycle, concurrently.
//
// RESOURCE (W=64, DEPTH=16)
//   Memory : DEPTH*W bits -> 1024 b, inferred LUTRAM (small) or BRAM (large).
//   Logic  : ~2*(AW+1) pointer FF + (AW+1) count FF + (AW+1) high-water FF
//            + 2 sticky FF + ~30 LUT.  0 DSP.
//
// -----------------------------------------------------------------------------
// ⚠️  OVERFLOW AND UNDERFLOW ARE STICKY, BY DESIGN (manual §9, CLAUDE.md §5.7)
//   A transient overflow between two host polls is exactly the event you must
//   not miss — it is a dropped market-data message or a dropped order. The flags
//   latch on the first occurrence and stay latched until `rst` or an explicit
//   `err_clr`. Silent failure is the worst failure mode in this domain.
//   The flags say IT HAPPENED, not HOW OFTEN: pair them with a `counter_bank`
//   entry if you need the count.
//
// ⚠️  OVERFLOW DROPS THE WRITE, IT DOES NOT CORRUPT THE FIFO. A write while full
//   is ignored and flagged. Underflow returns stale data with `rd_valid` low.
//   Neither ever advances a pointer past the other.
// =============================================================================
`default_nettype none

module sync_fifo #(
    parameter int unsigned W     = 64,   // data width
    parameter int unsigned DEPTH = 16,   // MUST be a power of two, >= 2
    parameter int unsigned ALMOST_FULL_LEVEL = DEPTH - 2
) (
    input  var logic                    clk,
    input  var logic                    rst,          // sync, active high

    // ── Write side ───────────────────────────────────────────────────────────
    input  var logic [W-1:0]            wr_data,
    input  var logic                    wr_en,
    output var logic                    full,
    output var logic                    almost_full,

    // ── Read side ────────────────────────────────────────────────────────────
    output var logic [W-1:0]            rd_data,
    input  var logic                    rd_en,
    output var logic                    empty,
    output var logic                    rd_valid,

    // ── Telemetry ────────────────────────────────────────────────────────────
    output var logic [$clog2(DEPTH):0]  high_water,   // max occupancy since rst
    output var logic                    overflow,     // STICKY: write while full
    output var logic                    underflow,    // STICKY: read while empty
    input  var logic                    err_clr       // 1-cycle strobe: clear both
);

    localparam int unsigned AW = $clog2(DEPTH);
    localparam int unsigned CW = AW + 1;                       // count width
    localparam logic [CW-1:0] CNT_ONE = CW'(1);
    localparam logic [AW-1:0] PTR_ONE = AW'(1);

    // -------------------------------------------------------------------------
    // Storage. No reset (datapath, manual 03 §6).
    // -------------------------------------------------------------------------
    logic [W-1:0] mem [DEPTH];

    logic [AW-1:0] wr_ptr_q, rd_ptr_q;
    logic [CW-1:0] count_q, count_d;
    logic          push, pop;
    logic          full_d, empty_d, almost_full_d;

    assign push = wr_en && !full;
    assign pop  = rd_en && !empty;

    // count_d: +1 on a push, -1 on a pop, unchanged when both or neither.
    always_comb begin
        count_d = count_q;                                  // default: hold
        unique case ({push, pop})
            2'b10:   count_d = count_q + CNT_ONE;
            2'b01:   count_d = count_q - CNT_ONE;
            2'b11:   count_d = count_q;
            2'b00:   count_d = count_q;
            default: count_d = count_q;
        endcase
    end

    assign full_d        = (count_d == CW'(DEPTH));
    assign empty_d       = (count_d == '0);
    assign almost_full_d = (count_d >= CW'(ALMOST_FULL_LEVEL));

    // -------------------------------------------------------------------------
    // Pointers and occupancy. Counters: reset (manual 04 §4).
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr_q <= '0;
            rd_ptr_q <= '0;
            count_q  <= '0;
        end else begin
            if (push) wr_ptr_q <= wr_ptr_q + PTR_ONE;
            if (pop)  rd_ptr_q <= rd_ptr_q + PTR_ONE;
            count_q  <= count_d;
        end
    end

    // Registered status outputs.
    always_ff @(posedge clk) begin
        if (rst) begin
            full        <= 1'b0;
            empty       <= 1'b1;          // empty out of reset — fail-closed
            almost_full <= 1'b0;
        end else begin
            full        <= full_d;
            empty       <= empty_d;
            almost_full <= almost_full_d;
        end
    end

    // -------------------------------------------------------------------------
    // Memory access. Registered read output: rd_data is presented one cycle
    // after the pop, qualified by rd_valid. Datapath, so rd_data has no reset.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (push) mem[wr_ptr_q] <= wr_data;
    end

    always_ff @(posedge clk) begin
        if (pop) rd_data <= mem[rd_ptr_q];
    end

    always_ff @(posedge clk) begin
        if (rst) rd_valid <= 1'b0;
        else     rd_valid <= pop;
    end

    // -------------------------------------------------------------------------
    // Telemetry: high-water mark and sticky error flags
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst)                       high_water <= '0;
        else if (count_d > high_water) high_water <= count_d;
    end

    always_ff @(posedge clk) begin
        if (rst || err_clr) begin
            overflow  <= 1'b0;
            underflow <= 1'b0;
        end else begin
            if (wr_en && full) overflow  <= 1'b1;   // sticky
            if (rd_en && empty) underflow <= 1'b1;  // sticky
        end
    end

    // -------------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    initial begin
        if (DEPTH < 2) begin
            $error("sync_fifo: DEPTH must be >= 2 (got %0d).", DEPTH);
            $fatal(1);
        end
        if ((DEPTH & (DEPTH - 1)) != 0) begin
            $error("sync_fifo: DEPTH must be a power of two (got %0d).", DEPTH);
            $fatal(1);
        end
        if ((ALMOST_FULL_LEVEL == 0) || (ALMOST_FULL_LEVEL > DEPTH)) begin
            $error("sync_fifo: ALMOST_FULL_LEVEL must be in [1, DEPTH] (got %0d).", ALMOST_FULL_LEVEL);
            $fatal(1);
        end
    end

    // Occupancy is bounded, always.
    assert property (@(posedge clk) disable iff (rst)
        count_q <= CW'(DEPTH))
        else $error("sync_fifo: count %0d exceeds DEPTH %0d", count_q, DEPTH);

    // Flags agree with the count.
    assert property (@(posedge clk) disable iff (rst)
        full == (count_q == CW'(DEPTH)))
        else $error("sync_fifo: full flag disagrees with count");

    assert property (@(posedge clk) disable iff (rst)
        empty == (count_q == '0))
        else $error("sync_fifo: empty flag disagrees with count");

    assert property (@(posedge clk) disable iff (rst)
        full |-> almost_full)
        else $error("sync_fifo: full without almost_full");

    assert property (@(posedge clk) disable iff (rst)
        !(full && empty))
        else $error("sync_fifo: full and empty simultaneously");

    // Read timing contract.
    assert property (@(posedge clk) disable iff (rst)
        pop |=> rd_valid)
        else $error("sync_fifo: pop did not produce rd_valid");

    assert property (@(posedge clk) disable iff (rst)
        rd_valid |-> $past(pop))
        else $error("sync_fifo: rd_valid without a preceding pop");

    // Error flags are sticky: they may only fall on rst or err_clr.
    assert property (@(posedge clk) disable iff (rst)
        (overflow && !err_clr) |=> overflow)
        else $error("sync_fifo: sticky overflow flag cleared without err_clr");

    assert property (@(posedge clk) disable iff (rst)
        (underflow && !err_clr) |=> underflow)
        else $error("sync_fifo: sticky underflow flag cleared without err_clr");

    // High-water mark is monotonic and bounded.
    assert property (@(posedge clk) disable iff (rst)
        high_water >= $past(high_water))
        else $error("sync_fifo: high-water mark decreased");

    assert property (@(posedge clk) disable iff (rst)
        high_water <= CW'(DEPTH))
        else $error("sync_fifo: high-water mark exceeds DEPTH");

    // These are NOT fatal — overflow on the RX path is a counted drop, not a
    // stall (CLAUDE.md §5.4) — but they must be visible in every regression run.
    assert property (@(posedge clk) disable iff (rst)
        !(wr_en && full))
        else $warning("sync_fifo: write while full — DATA DROPPED (sticky overflow set)");

    assert property (@(posedge clk) disable iff (rst)
        !(rd_en && empty))
        else $warning("sync_fifo: read while empty (sticky underflow set)");
`endif

endmodule : sync_fifo

`default_nettype wire
