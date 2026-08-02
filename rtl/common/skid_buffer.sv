// =============================================================================
// skid_buffer.sv — Register slice for a valid/ready stream
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/01-fpga-design/01-rtl-design-patterns.md §2
//           manuals/00-foundations/03-hdl-and-rtl-coding.md §5
//
// PURPOSE
//   Break a long combinational `ready` chain without losing throughput.
//   Registering `ready` naively breaks the handshake: by the time the producer
//   observes `!ready` it has already launched another beat. The skid register
//   catches exactly that one in-flight beat, which is why one beat of storage is
//   sufficient and two is waste.
//
//   Use where timing demands it, NOT reflexively — every skid buffer is 6.4 ns
//   you are spending (manual §2). On the fast path, prefer a design that never
//   backpressures at all.
//
// LATENCY
//   1 cycle = 6.4 ns @ 156.25 MHz, fixed, in both the flowing and the stalled
//   case. Deterministic (CLAUDE.md §5.8).
//
// THROUGHPUT
//   100 %. One beat per cycle sustained while `m_ready` is high — unlike a plain
//   output register, which halves it.
//
// RESOURCE
//   2*W + 2 FF, ~4 LUT. W=64 -> 130 FF. 0 BRAM. 0 DSP.
//
// -----------------------------------------------------------------------------
// INTERFACE CONTRACT (manual §1) — asserted on BOTH sides below:
//   1. Once `valid` is asserted it must not de-assert until a transfer completes.
//   2. `data` must be stable while `valid && !ready`.
//   3. Neither side waits for the other before asserting: no deadlock by
//      construction.
//
// ⚠️  `s_ready` IS A REGISTERED SIGNAL. It is `!skid_valid_q` — one inversion of
//   a flip-flop output — and critically it has NO combinational dependence on
//   `m_ready`. That is the whole point: the downstream ready path stops here.
//   A skid buffer whose `s_ready` still depends on `m_ready` has done nothing.
//
// ⚠️  DO NOT USE THIS ON THE MAC RX PATH. The RX path has no backpressure at all
//   (CLAUDE.md §5.4); `s_ready` must be tied high there and over-run handled by
//   dropping and counting. A skid buffer in the RX path implies a stall that the
//   wire will not honour.
// =============================================================================
`default_nettype none

module skid_buffer #(
    parameter int unsigned W = 64
) (
    input  var logic         clk,
    input  var logic         rst,       // synchronous, active high

    // ── Slave (input) stream ─────────────────────────────────────────────────
    input  var logic [W-1:0] s_data,
    input  var logic         s_valid,
    output var logic         s_ready,

    // ── Master (output) stream ───────────────────────────────────────────────
    output var logic [W-1:0] m_data,
    output var logic         m_valid,
    input  var logic         m_ready
);

    // The single skid slot. Data is datapath -> no reset. The valid flag is
    // control state -> reset (manual 03 §6).
    logic [W-1:0] skid_data_q;
    logic         skid_valid_q;

    // Registered ready: depends only on internal state, never on m_ready.
    assign s_ready = !skid_valid_q;

    // Convenience terms (combinational, one LUT level each).
    logic s_xfer;      // a beat is accepted from the producer this cycle
    logic m_advance;   // the output register may take a new value this cycle

    assign s_xfer    = s_valid && s_ready;
    assign m_advance = !m_valid || m_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            m_valid      <= 1'b0;
            skid_valid_q <= 1'b0;
        end else begin
            // Fill the skid slot only when the output is stalled and the
            // producer — which cannot yet have seen a stall — sends another beat.
            if (s_xfer && !m_advance) begin
                skid_valid_q <= 1'b1;
            end

            // The output register advances whenever it is empty or being drained.
            if (m_advance) begin
                if (skid_valid_q) begin
                    m_valid      <= 1'b1;
                    skid_valid_q <= 1'b0;
                end else begin
                    m_valid      <= s_valid;
                end
            end
        end
    end

    // Datapath registers: unreset, and only ever loaded alongside their valid.
    always_ff @(posedge clk) begin
        if (s_xfer && !m_advance) begin
            skid_data_q <= s_data;
        end
        if (m_advance) begin
            m_data <= skid_valid_q ? skid_data_q : s_data;
        end
    end

    // -------------------------------------------------------------------------
    // Assertions — the stream contract, both sides.
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    initial begin
        if (W < 1) begin
            $error("skid_buffer: W must be >= 1 (got %0d).", W);
            $fatal(1);
        end
    end

    // Contract on the producer we are consuming from.
    assert property (@(posedge clk) disable iff (rst)
        (s_valid && !s_ready) |=> (s_valid && $stable(s_data)))
        else $error("skid_buffer: input stream contract violated (s_data moved while stalled)");

    // Contract we owe the consumer downstream.
    assert property (@(posedge clk) disable iff (rst)
        (m_valid && !m_ready) |=> (m_valid && $stable(m_data)))
        else $error("skid_buffer: output stream contract violated (m_data moved while stalled)");

    // One slot only: the skid must never be overwritten while occupied.
    assert property (@(posedge clk) disable iff (rst)
        !(skid_valid_q && s_xfer))
        else $error("skid_buffer: skid slot overwritten — BEAT LOST");

    // No data is created out of nothing: an output beat is either a passthrough
    // or a drained skid slot.
    assert property (@(posedge clk) disable iff (rst)
        (m_advance && !skid_valid_q && !s_valid) |=> !m_valid)
        else $error("skid_buffer: m_valid asserted with no source beat");

    // The skid slot may only fill while the output is stalled.
    assert property (@(posedge clk) disable iff (rst)
        (!skid_valid_q ##1 skid_valid_q) |-> $past(m_valid && !m_ready))
        else $error("skid_buffer: skid slot filled while the output was not stalled");

    // Full throughput: with the consumer always ready, we never backpressure.
    assert property (@(posedge clk) disable iff (rst)
        m_ready |=> s_ready)
        else $error("skid_buffer: backpressured the producer while the consumer was ready — throughput bug");
`endif

endmodule : skid_buffer

`default_nettype wire
