// =============================================================================
// cdc_pulse.sv — Toggle-based single-cycle pulse synchronizer (with busy/ack)
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/00-foundations/04-clocking-reset-and-cdc.md §3.2
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   Carry a single-cycle EVENT (not a level) from `src_clk` to `dst_clk`. The
//   event is encoded as a toggle so it survives an arbitrary clock ratio, then
//   edge-detected in the destination domain. Legitimate users: host doorbell /
//   commit strobes, "heartbeat received", "counter snapshot now", credit return.
//
//   A closed-loop acknowledge toggle comes back from the destination so the
//   source can see, via `src_busy`, that the previous event has landed. Respect
//   `src_busy` and NO EVENT IS EVER LOST. Ignore it and events merge silently —
//   which in this system means a lost credit return or a missed heartbeat.
//
// LATENCY
//   src_pulse -> dst_pulse : SYNC_STAGES + 1 dst cycles (+ up to 1 cycle of
//     sampling uncertainty). Default 2 -> 3 dst cyc = 19.2 ns @ 156.25 MHz.
//   src_busy release       : that, plus SYNC_STAGES + 1 src cycles for the ack
//     to come back. Round trip ~6 cycles. Control plane only — never fast path.
//
// RESOURCE
//   ~2*SYNC_STAGES + 4 FF. A handful of LUTs. 0 BRAM. 0 DSP.
//
// -----------------------------------------------------------------------------
// ⚠️  RATE LIMITATION — THE REASON THIS MODULE HAS A `src_busy` OUTPUT
//   The crossing carries at most ONE event in flight. Source pulses must be
//   separated by at least (SYNC_STAGES + 1) DESTINATION clock periods plus the
//   ack return trip; closer together, the toggle flips twice before the
//   destination samples it and BOTH events vanish (manual §3.2, §7 "pulse to
//   slower domain: events silently lost, counters drift").
//
//   Rules for callers:
//     * Gate the source with `src_busy` (`if (!src_busy) fire`). The module
//       drops a pulse presented while busy and counts nothing — the assertion
//       below fires in simulation, but hardware is silent. This is deliberate:
//       silently dropping is better than corrupting, and the caller owns the
//       counting (CLAUDE.md §5.7: every drop is counted, by the caller).
//     * If the source can BURST, this module is the wrong primitive. Use
//       `async_fifo` and let the depth absorb the burst.
//
// ⚠️  NOT A LEVEL. `dst_pulse` is exactly one dst_clk cycle wide. Do not use it
//   to convey a state; use `cdc_sync_bit` for that.
//
// ⚠️  BOTH RESETS MUST DERIVE FROM THE SAME ROOT RESET (one `reset_sync` per
//   domain off one asynchronous source, as `clk_rst_gen` provides). Resetting
//   only one side leaves the request and acknowledge toggles out of phase; the
//   destination then emits one spurious `dst_pulse` on release, or the source
//   sits permanently `src_busy`.
//
// XDC (constraints/cdc.xdc): both toggles cross through cdc_sync_bit chains, so
// the cdc_sync_bit constraint block covers them. Do NOT set_false_path.
// =============================================================================
`default_nettype none

module cdc_pulse #(
    parameter int unsigned SYNC_STAGES = 2
) (
    // ── Source domain ────────────────────────────────────────────────────────
    input  var logic src_clk,
    input  var logic src_rst,     // synchronous, active high, src_clk domain
    input  var logic src_pulse,   // single-cycle event
    output var logic src_busy,    // 1 = an event is still in flight; do not fire

    // ── Destination domain ───────────────────────────────────────────────────
    input  var logic dst_clk,
    input  var logic dst_rst,     // synchronous, active high, dst_clk domain
    output var logic dst_pulse    // single-cycle event, dst_clk domain
);

    // -------------------------------------------------------------------------
    // Source domain: flip a level on every accepted pulse.
    // -------------------------------------------------------------------------
    logic src_toggle_q;   // crosses to dst
    logic ack_sync;       // ack toggle, synchronized back into src
    logic src_accept;

    // Accept a pulse only when the previous one has been acknowledged.
    assign src_accept = src_pulse && !src_busy;

    always_ff @(posedge src_clk) begin
        if (src_rst) begin
            src_toggle_q <= 1'b0;
        end else if (src_accept) begin
            src_toggle_q <= ~src_toggle_q;
        end
    end

    // busy = the ack toggle has not yet caught up with the request toggle.
    // Both are FF outputs; the XOR is one LUT.
    assign src_busy = (src_toggle_q ^ ack_sync);

    // -------------------------------------------------------------------------
    // Request toggle -> destination domain, edge detect
    // -------------------------------------------------------------------------
    logic tog_sync;
    logic tog_sync_q;

    cdc_sync_bit #(
        .STAGES   (SYNC_STAGES),
        .INIT_VAL (1'b0)
    ) u_req_sync (
        .dst_clk (dst_clk),
        .src_bit (src_toggle_q),
        .dst_bit (tog_sync)
    );

    always_ff @(posedge dst_clk) begin
        if (dst_rst) begin
            tog_sync_q <= 1'b0;
            dst_pulse  <= 1'b0;
        end else begin
            tog_sync_q <= tog_sync;
            dst_pulse  <= tog_sync ^ tog_sync_q;   // registered output
        end
    end

    // -------------------------------------------------------------------------
    // Acknowledge toggle -> back to the source domain
    // The ack simply mirrors the (already synchronized) request toggle, so the
    // source learns the event has been observed in dst_clk.
    // -------------------------------------------------------------------------
    logic dst_ack_toggle_q;

    always_ff @(posedge dst_clk) begin
        if (dst_rst) dst_ack_toggle_q <= 1'b0;
        else         dst_ack_toggle_q <= tog_sync;
    end

    cdc_sync_bit #(
        .STAGES   (SYNC_STAGES),
        .INIT_VAL (1'b0)
    ) u_ack_sync (
        .dst_clk (src_clk),
        .src_bit (dst_ack_toggle_q),
        .dst_bit (ack_sync)
    );

    // -------------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    initial begin
        if (SYNC_STAGES < 2) begin
            $error("cdc_pulse: SYNC_STAGES must be >= 2 (got %0d).", SYNC_STAGES);
            $fatal(1);
        end
    end

    // The caller must respect src_busy. A pulse presented while busy is DROPPED.
    assert property (@(posedge src_clk) disable iff (src_rst)
        !(src_pulse && src_busy))
        else $error("cdc_pulse: src_pulse while src_busy — EVENT DROPPED. Gate the source with src_busy or use async_fifo.");

    // dst_pulse is exactly one cycle wide.
    assert property (@(posedge dst_clk) disable iff (dst_rst)
        dst_pulse |=> !dst_pulse)
        else $error("cdc_pulse: dst_pulse wider than one cycle");

    // Liveness: every accepted source event eventually produces a dst event.
    assert property (@(posedge src_clk) disable iff (src_rst)
        src_accept |-> ##[1:$] !src_busy)
        else $error("cdc_pulse: event never acknowledged — dst_clk stopped?");
`endif

endmodule : cdc_pulse

`default_nettype wire
