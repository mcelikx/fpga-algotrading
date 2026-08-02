// =============================================================================
// async_fifo.sv — Gray-coded dual-clock FIFO
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/00-foundations/04-clocking-reset-and-cdc.md §3.3
//           manuals/01-fpga-design/03-memory-and-storage.md
//           manuals/01-fpga-design/01-rtl-design-patterns.md §1
//
// PURPOSE
//   THE default primitive for any multi-bit data crossing (manual §3.3).
//   Used at: MAC RX -> core_clk, core_clk -> MAC TX, PCIe -> core_clk. Those are
//   the only three CDC locations in this design (manual §1 rule 2).
//
//   Write and read pointers are gray-coded before crossing, so a pointer
//   sampled mid-transition can only ever be the old value or the new one —
//   never a third value that never existed. That property is the entire reason
//   this construction is safe, and it is why the pointers, and ONLY the
//   pointers, may cross through parallel 2-FF chains.
//
// LATENCY
//   Write to readable (`rd_empty` falls): SYNC_STAGES + 1 read cycles after the
//     write, i.e. 3 read cycles = 19.2 ns @ 156.25 MHz with SYNC_STAGES=2.
//   Read command to data: 1 read cycle (`rd_en` -> `rd_valid` + `rd_data`).
//   Full de-assert after a read: SYNC_STAGES + 1 write cycles.
//   Budget ~2-3 destination cycles for the crossing, per manual §3.3.
//
// RESOURCE (W=64, DEPTH=16, SYNC_STAGES=2)
//   Memory : DEPTH*W bits -> 1024 b. Inferred as LUTRAM (distributed) for small
//            DEPTH, BRAM for DEPTH*W above ~1-2 kb. Force with RAM_STYLE.
//   Logic  : 2*(AW+1) pointer FF + 2*SYNC_STAGES*(AW+1) synchronizer FF
//            + AW+1 high-water FF + ~40 LUT.  0 DSP.
//   -> ~ 60 FF + ~60 LUT + 1 LUTRAM block for the 64x16 case.
//
// -----------------------------------------------------------------------------
// ⚠️  THE MANUAL SAYS "DO NOT WRITE YOUR OWN" (§3.3) — READ THIS BEFORE USING
//   The manual's preference is the vendor macro (`xpm_fifo_async`) precisely
//   because the pointer arithmetic and the full/empty edge cases are subtle and
//   the failure mode is SILENT CORRUPTION. This module exists because the
//   project must stay vendor-neutral (CLAUDE.md §2) and because the high-water
//   telemetry below is not available from the XPM. It is therefore held to a
//   higher bar than ordinary RTL:
//     * It is the Cummings/`fifo2` construction, unmodified in its essentials.
//     * Every full/empty edge case is asserted below.
//     * It MUST be simulated at several clock ratios INCLUDING nearly-equal
//       frequencies (the hardest case) with randomized phase, per manual §6.2.
//     * `report_cdc` must be clean on every build.
//   If any of that is not done, use `xpm_fifo_async` instead and lose the
//   high-water counter.
//
// ⚠️  BOTH RESETS MUST BE ASSERTED TOGETHER AND DERIVE FROM ONE ROOT RESET.
//   `wr_rst` and `rd_rst` each come from a `reset_sync` in their own domain, fed
//   from the same asynchronous source. Resetting ONE side zeroes one pointer and
//   not the other: the FIFO then reports a nonsense occupancy, `rd_empty` can be
//   low with no data behind it, and you read stale memory. There is no way for
//   this module to detect that from inside one domain, so it is a caller
//   obligation. The `wr_high_water` telemetry is your canary in the field.
//
// ⚠️  NO BACKPRESSURE ON THE MAC RX PATH (CLAUDE.md §5.4). On the RX crossing,
//   `wr_full` must be treated as a DROP-AND-COUNT event, never as a stall.
//   `wr_almost_full` exists so the caller can start dropping deliberately at a
//   chosen boundary (whole messages, not half messages) before it hits full.
//
// ⚠️  OCCUPANCY IS MEASURED IN THE WRITE DOMAIN AND IS CONSERVATIVE. The read
//   pointer it uses has been through a synchronizer, so it lags reality. The
//   reported occupancy is therefore >= the true occupancy: safe for
//   almost-full, and `wr_high_water` may read one or two entries pessimistic.
//   That is the right direction for a telemetry high-water mark.
// =============================================================================
`default_nettype none

module async_fifo #(
    parameter int unsigned W           = 64,   // data width
    parameter int unsigned DEPTH       = 16,   // MUST be a power of two, >= 4
    parameter int unsigned SYNC_STAGES = 2,    // pointer synchronizer depth
    // Occupancy at which wr_almost_full asserts. Leave enough headroom for the
    // in-flight beats the producer cannot retract (on the MAC RX path: one
    // maximum-length message).
    parameter int unsigned ALMOST_FULL_LEVEL = DEPTH - 2
) (
    // ── Write domain ─────────────────────────────────────────────────────────
    input  var logic                        wr_clk,
    input  var logic                        wr_rst,          // sync, active high
    input  var logic [W-1:0]                wr_data,
    input  var logic                        wr_en,
    output var logic                        wr_full,
    output var logic                        wr_almost_full,
    // Occupancy high-water mark, write domain, sticky until wr_rst. Telemetry
    // per CLAUDE.md §5.7 — a FIFO that quietly runs at 15/16 in production is a
    // drop waiting for a busy morning.
    output var logic [$clog2(DEPTH):0]      wr_high_water,

    // ── Read domain ──────────────────────────────────────────────────────────
    input  var logic                        rd_clk,
    input  var logic                        rd_rst,          // sync, active high
    output var logic [W-1:0]                rd_data,
    input  var logic                        rd_en,
    output var logic                        rd_empty,
    output var logic                        rd_valid         // rd_data is valid
);

    // AW = address bits. Pointers carry ONE extra bit so that "pointers equal"
    // (empty) is distinguishable from "pointers equal but wrapped once" (full).
    localparam int unsigned AW  = $clog2(DEPTH);
    localparam int unsigned PW  = AW + 1;
    localparam logic [PW-1:0] PTR_ONE = PW'(1);

    // -------------------------------------------------------------------------
    // Gray <-> binary. Both are pure XOR networks: 1 LUT level per output bit.
    // -------------------------------------------------------------------------
    function automatic logic [PW-1:0] bin2gray(input logic [PW-1:0] b);
        return b ^ (b >> 1);
    endfunction

    function automatic logic [PW-1:0] gray2bin(input logic [PW-1:0] g);
        logic [PW-1:0] b;
        b = '0;
        // Unrolled at elaboration: b[i] = XOR of all gray bits at or above i.
        for (int unsigned i = 0; i < PW; i++) begin
            b[i] = ^(g >> i);
        end
        return b;
    endfunction

    // -------------------------------------------------------------------------
    // Storage. Simple dual-port: one write port on wr_clk, one read port on
    // rd_clk. No reset (datapath, manual 03 §6) — contents are meaningless until
    // the pointers say otherwise.
    // -------------------------------------------------------------------------
    logic [W-1:0] mem [DEPTH];

    // -------------------------------------------------------------------------
    // Write domain
    // -------------------------------------------------------------------------
    logic [PW-1:0] wr_ptr_bin_q,  wr_ptr_bin_d;
    logic [PW-1:0] wr_ptr_gray_q, wr_ptr_gray_d;
    logic [PW-1:0] rd_ptr_gray_wsync;    // read pointer, gray, in wr_clk
    logic [PW-1:0] rd_ptr_bin_wsync;
    logic [PW-1:0] occupancy_w;
    logic          wr_push;
    logic          wr_full_d;
    logic          wr_almost_full_d;

    assign wr_push       = wr_en && !wr_full;
    assign wr_ptr_bin_d  = wr_ptr_bin_q + (wr_push ? PTR_ONE : '0);
    assign wr_ptr_gray_d = bin2gray(wr_ptr_bin_d);

    always_ff @(posedge wr_clk) begin
        if (wr_rst) begin
            wr_ptr_bin_q  <= '0;
            wr_ptr_gray_q <= '0;
        end else begin
            wr_ptr_bin_q  <= wr_ptr_bin_d;
            wr_ptr_gray_q <= wr_ptr_gray_d;
        end
    end

    always_ff @(posedge wr_clk) begin
        if (wr_push) mem[wr_ptr_bin_q[AW-1:0]] <= wr_data;   // datapath: no reset
    end

    // FULL: the write pointer has caught the read pointer from behind, i.e. the
    // NEXT write pointer equals the read pointer with its top two gray bits
    // inverted. Inverting the top two bits of a gray code is the gray-domain
    // equivalent of "same address, opposite wrap bit".
    // THIS IS THE EDGE CASE THAT GETS WRITTEN WRONG. It is asserted below.
    assign wr_full_d = (wr_ptr_gray_d ==
                        {~rd_ptr_gray_wsync[PW-1:PW-2], rd_ptr_gray_wsync[PW-3:0]});

    always_ff @(posedge wr_clk) begin
        if (wr_rst) wr_full <= 1'b0;
        else        wr_full <= wr_full_d;
    end

    // Occupancy in the write domain. Modular subtraction on PW bits: the extra
    // wrap bit makes this correct across the wrap, and the result is always in
    // [0, DEPTH].
    assign rd_ptr_bin_wsync = gray2bin(rd_ptr_gray_wsync);
    assign occupancy_w      = wr_ptr_bin_d - rd_ptr_bin_wsync;

    assign wr_almost_full_d = (occupancy_w >= PW'(ALMOST_FULL_LEVEL));

    always_ff @(posedge wr_clk) begin
        if (wr_rst) wr_almost_full <= 1'b0;
        else        wr_almost_full <= wr_almost_full_d;
    end

    always_ff @(posedge wr_clk) begin
        if (wr_rst)                             wr_high_water <= '0;
        else if (occupancy_w > wr_high_water)   wr_high_water <= occupancy_w;
    end

    // -------------------------------------------------------------------------
    // Read domain
    // -------------------------------------------------------------------------
    logic [PW-1:0] rd_ptr_bin_q,  rd_ptr_bin_d;
    logic [PW-1:0] rd_ptr_gray_q, rd_ptr_gray_d;
    logic [PW-1:0] wr_ptr_gray_rsync;    // write pointer, gray, in rd_clk
    logic          rd_pop;
    logic          rd_empty_d;

    assign rd_pop        = rd_en && !rd_empty;
    assign rd_ptr_bin_d  = rd_ptr_bin_q + (rd_pop ? PTR_ONE : '0);
    assign rd_ptr_gray_d = bin2gray(rd_ptr_bin_d);

    always_ff @(posedge rd_clk) begin
        if (rd_rst) begin
            rd_ptr_bin_q  <= '0;
            rd_ptr_gray_q <= '0;
        end else begin
            rd_ptr_bin_q  <= rd_ptr_bin_d;
            rd_ptr_gray_q <= rd_ptr_gray_d;
        end
    end

    // EMPTY: pointers identical, including the wrap bit. Compared in gray, which
    // is exact for equality (gray is a bijection).
    assign rd_empty_d = (rd_ptr_gray_d == wr_ptr_gray_rsync);

    always_ff @(posedge rd_clk) begin
        if (rd_rst) rd_empty <= 1'b1;      // empty out of reset — fail-closed
        else        rd_empty <= rd_empty_d;
    end

    // Synchronous read with a registered output: rd_data is presented one cycle
    // after the pop, qualified by rd_valid. Datapath, so no reset on rd_data.
    always_ff @(posedge rd_clk) begin
        if (rd_pop) rd_data <= mem[rd_ptr_bin_q[AW-1:0]];
    end

    always_ff @(posedge rd_clk) begin
        if (rd_rst) rd_valid <= 1'b0;
        else        rd_valid <= rd_pop;
    end

    // -------------------------------------------------------------------------
    // Pointer synchronizers — the ONLY sanctioned multi-bit 2-FF crossing in the
    // project, legal solely because the value is gray coded (see header).
    // -------------------------------------------------------------------------
    // Per-bit synchronizer outputs land in unpacked arrays (one driver each),
    // then are gathered into the packed pointers by a single always_comb. This
    // is a lint hygiene detail, not a functional one.
    logic rd_gray_sync_bit [PW];
    logic wr_gray_sync_bit [PW];

    generate
        for (genvar i = 0; i < int'(PW); i++) begin : g_rd_ptr_sync
            cdc_sync_bit #(.STAGES(SYNC_STAGES), .INIT_VAL(1'b0)) u_sync (
                .dst_clk (wr_clk),
                .src_bit (rd_ptr_gray_q[i]),
                .dst_bit (rd_gray_sync_bit[i])
            );
        end
        for (genvar i = 0; i < int'(PW); i++) begin : g_wr_ptr_sync
            cdc_sync_bit #(.STAGES(SYNC_STAGES), .INIT_VAL(1'b0)) u_sync (
                .dst_clk (rd_clk),
                .src_bit (wr_ptr_gray_q[i]),
                .dst_bit (wr_gray_sync_bit[i])
            );
        end
    endgenerate

    always_comb begin
        rd_ptr_gray_wsync = '0;                          // default (no latch)
        wr_ptr_gray_rsync = '0;
        for (int unsigned i = 0; i < PW; i++) begin
            rd_ptr_gray_wsync[i] = rd_gray_sync_bit[i];
            wr_ptr_gray_rsync[i] = wr_gray_sync_bit[i];
        end
    end

    // -------------------------------------------------------------------------
    // Assertions — the full/empty edge cases, asserted because getting them
    // wrong is silent data corruption (manual §3.3).
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    initial begin
        if (DEPTH < 4) begin
            $error("async_fifo: DEPTH must be >= 4 (got %0d).", DEPTH);
            $fatal(1);
        end
        if ((DEPTH & (DEPTH - 1)) != 0) begin
            $error("async_fifo: DEPTH must be a power of two (got %0d). Gray-coded pointers require it.", DEPTH);
            $fatal(1);
        end
        if (SYNC_STAGES < 2) begin
            $error("async_fifo: SYNC_STAGES must be >= 2 (got %0d).", SYNC_STAGES);
            $fatal(1);
        end
        if ((ALMOST_FULL_LEVEL == 0) || (ALMOST_FULL_LEVEL > DEPTH)) begin
            $error("async_fifo: ALMOST_FULL_LEVEL must be in [1, DEPTH] (got %0d).", ALMOST_FULL_LEVEL);
            $fatal(1);
        end
    end

    // --- Gray-code invariant: exactly one bit changes per pointer increment.
    // If this ever fires, the whole safety argument for the crossing is void.
    assert property (@(posedge wr_clk) disable iff (wr_rst)
        $onehot0(wr_ptr_gray_q ^ $past(wr_ptr_gray_q)))
        else $error("async_fifo: write pointer gray code changed more than one bit — CROSSING IS UNSAFE");

    assert property (@(posedge rd_clk) disable iff (rd_rst)
        $onehot0(rd_ptr_gray_q ^ $past(rd_ptr_gray_q)))
        else $error("async_fifo: read pointer gray code changed more than one bit — CROSSING IS UNSAFE");

    // --- Gray/binary pointers must agree at all times.
    assert property (@(posedge wr_clk) disable iff (wr_rst)
        wr_ptr_gray_q == bin2gray(wr_ptr_bin_q))
        else $error("async_fifo: write gray/binary pointers diverged");

    assert property (@(posedge rd_clk) disable iff (rd_rst)
        rd_ptr_gray_q == bin2gray(rd_ptr_bin_q))
        else $error("async_fifo: read gray/binary pointers diverged");

    // --- Overflow / underflow. On the RX path these are DROP events the caller
    // must count (CLAUDE.md §5.4, §5.7); they are still design errors anywhere
    // a producer claimed it would respect wr_full.
    assert property (@(posedge wr_clk) disable iff (wr_rst)
        !(wr_en && wr_full))
        else $error("async_fifo: write while full — DATA DROPPED");

    assert property (@(posedge rd_clk) disable iff (rd_rst)
        !(rd_en && rd_empty))
        else $error("async_fifo: read while empty");

    // --- Occupancy can never exceed DEPTH, in either direction of measurement.
    assert property (@(posedge wr_clk) disable iff (wr_rst)
        occupancy_w <= PW'(DEPTH))
        else $error("async_fifo: occupancy %0d exceeds DEPTH %0d", occupancy_w, DEPTH);

    // --- full and almost_full are consistent.
    assert property (@(posedge wr_clk) disable iff (wr_rst)
        wr_full |-> wr_almost_full)
        else $error("async_fifo: full asserted without almost_full");

    // --- The full flag really means the FIFO held DEPTH entries when it was
    // computed. ($past, because wr_full is registered and the synchronized read
    // pointer may already have moved on by the time the flag is visible — that
    // lag is the conservative direction and is intentional.)
    assert property (@(posedge wr_clk) disable iff (wr_rst)
        wr_full |-> ($past(occupancy_w) == PW'(DEPTH)))
        else $error("async_fifo: wr_full asserted at occupancy %0d, expected %0d", $past(occupancy_w), DEPTH);

    // --- rd_valid follows exactly one cycle after an accepted pop.
    assert property (@(posedge rd_clk) disable iff (rd_rst)
        rd_pop |=> rd_valid)
        else $error("async_fifo: pop did not produce rd_valid");

    assert property (@(posedge rd_clk) disable iff (rd_rst)
        rd_valid |-> $past(rd_pop))
        else $error("async_fifo: rd_valid without a preceding pop");

    // --- High-water mark is monotonic and bounded.
    assert property (@(posedge wr_clk) disable iff (wr_rst)
        wr_high_water >= $past(wr_high_water))
        else $error("async_fifo: high-water mark decreased");

    assert property (@(posedge wr_clk) disable iff (wr_rst)
        wr_high_water <= PW'(DEPTH))
        else $error("async_fifo: high-water mark exceeds DEPTH");
`endif

endmodule : async_fifo

`default_nettype wire
