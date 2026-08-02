// =============================================================================
// crc32_eth.sv — Parallel Ethernet CRC-32 (FCS) step, 1..8 bytes per cycle
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/02-networking/01-ethernet-phy-mac.md §4 ("CRC-32 in fabric")
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//
// PURPOSE
//   One combinational CRC-32 update step over a DATA_W-bit beat, with a
//   byte-count input so the SAME instance handles both full beats and the
//   ragged final beat of a frame (1..8 valid bytes). Used by mac_rx (residue
//   check) and mac_tx (FCS generation).
//
// PARAMETERS OF THE CODE (IEEE 802.3 §3.2.9)
//   polynomial  0x04C11DB7          (normal form, as quoted in the standard)
//   reflected   0xEDB88320          (the form implemented here — see below)
//   init        0xFFFFFFFF
//   final XOR   0xFFFFFFFF
//   check       CRC32("123456789") == 0xCBF43926      <- self-checked below
//   residue     0xDEBB20E3          (register value after message||FCS)
//
//   ⚠️ NOTE ON THE RESIDUE CONSTANT. manuals/02-networking/01-ethernet-phy-mac.md
//   quotes the residue as 0xC704DD7B. That is the *bit-reversed* form, which is
//   what you get from a non-reflected (MSB-first) CRC register. This module
//   implements the reflected (LSB-first, zlib-style) register, which is the
//   natural match for Ethernet's LSB-first-per-octet transmission order, and in
//   that register the residue is 0xDEBB20E3. The two are the same constant:
//       bitreverse(0xDEBB20E3) == 0xC704DD7B
//   Both are checked in the `ifndef SYNTHESIS` block at the bottom of this file.
//
// BYTE ORDER
//   data[7:0]  is the FIRST byte on the wire (XGMII lane 0 / tkeep[0]).
//   data[63:56] is the LAST byte of the beat.
//   `bytes` = number of valid bytes, occupying lanes 0 .. bytes-1.
//   bytes == 0 is legal and returns crc_in unchanged (used by mac_rx when the
//   XGMII terminate character lands in lane 0).
//
// IMPLEMENTATION
//   partial[b] = CRC after absorbing the first b bytes of `data`. The chain
//   partial[0] -> partial[1] -> ... -> partial[8] is written as a generate loop
//   of single-byte steps; every tap of that chain IS one of the eight
//   width-specific CRC matrices, and `crc_out = partial[bytes]` is the mux.
//   Writing it as a shared chain rather than eight independent XOR trees lets
//   synthesis share every common term, so the eight variants cost far less than
//   8x one variant.
//
//   Each partial[b] flattens to a pure XOR of a subset of {crc_in, data}, i.e.
//   at most 96 inputs per output bit => XOR tree of ceil(log6(96)) = 3 LUT6
//   levels. Comfortably one cycle at 156.25 MHz (6.4 ns).
//
// LATENCY
//   0 cycles / 0.0 ns. This module is PURELY COMBINATIONAL.
//   ⚠️ Deliberate exception to the "registered outputs by default" rule of
//   manuals/00-foundations/03-hdl-and-rtl-coding.md §5: this is a shared
//   arithmetic primitive, not a pipeline stage. The consumer (mac_rx / mac_tx)
//   registers the result. Registering here would add a cycle to every frame
//   boundary for no timing benefit.
//
// RESOURCE ESTIMATE (DATA_W=64, UltraScale+)
//   PARTIAL_SUPPORT=1 : ~1400-2200 LUT, 0 FF, 0 BRAM, 0 DSP
//   PARTIAL_SUPPORT=0 : ~600-800   LUT, 0 FF, 0 BRAM, 0 DSP
//   (No registers: this block is combinational.)
//
// HARD RULES (CLAUDE.md §5)
//   - No division, modulo or floating point.  (only XOR and shifts)
//   - No unbounded loops. Every loop bound below is a compile-time constant.
// =============================================================================
`default_nettype none

module crc32_eth #(
    // Beat width in bits. Must be a whole number of bytes.
    parameter int unsigned DATA_W          = 64,
    // 1 = generate all DATA_W/8 width variants and mux on `bytes`.
    // 0 = full-width step only; `bytes` is ignored. Cheaper; use where the
    //     caller only ever presents complete beats.
    parameter int unsigned PARTIAL_SUPPORT = 1
) (
    input  var logic [31:0]                    crc_in,
    input  var logic [DATA_W-1:0]              data,
    input  var logic [$clog2(DATA_W/8+1)-1:0]  bytes,    // 0 .. DATA_W/8
    output var logic [31:0]                    crc_out
);

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------
    localparam int unsigned NBYTES     = DATA_W / 8;
    localparam int          NBYTES_I   = int'(DATA_W / 8);   // signed, for genvar
    localparam int unsigned CNT_W      = $clog2(NBYTES + 1);

    localparam logic [31:0] POLY_REFL   = 32'hEDB8_8320;  // reverse(0x04C11DB7)
    localparam logic [31:0] CRC_INIT    = 32'hFFFF_FFFF;
    localparam logic [31:0] CRC_XOROUT  = 32'hFFFF_FFFF;
    localparam logic [31:0] CRC_RESIDUE = 32'hDEBB_20E3;  // == bitrev(0xC704DD7B)

    // -------------------------------------------------------------------------
    // One-byte CRC step. Fixed bound of 8 => fully unrolled, no latch, no loop
    // at runtime. This is the ONLY place the polynomial appears.
    // -------------------------------------------------------------------------
    function automatic logic [31:0] crc32_byte(input logic [31:0] c,
                                               input logic [7:0]  d);
        logic [31:0] t;
        begin
            t = c ^ {24'h00_0000, d};
            for (int unsigned i = 0; i < 8; i++) begin
                t = (t >> 1) ^ (POLY_REFL & {32{t[0]}});
            end
            crc32_byte = t;
        end
    endfunction

    // -------------------------------------------------------------------------
    // The chain. partial[b] = CRC over the first b bytes of `data`.
    // Declared as a packed array of NETS, not variables, for two reasons:
    //   * each element gets its own continuous assignment below, and a net
    //     vector permits that without argument about per-bit driver rules;
    //   * packed (rather than unpacked) makes partial[bytes] a plain
    //     variable-index mux, which is exactly the hardware we want.
    // -------------------------------------------------------------------------
    wire [NBYTES:0][31:0] partial;

    assign partial[0] = crc_in;

    generate
        for (genvar b = 0; b < NBYTES_I; b++) begin : g_byte_step
            assign partial[b+1] = crc32_byte(partial[b], data[b*8 +: 8]);
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Output select. Default assignment first — no latch (§3 of the coding std).
    // -------------------------------------------------------------------------
    generate
        if (PARTIAL_SUPPORT != 0) begin : g_partial
            always_comb begin
                crc_out = partial[NBYTES];                    // default
                if (bytes <= CNT_W'(NBYTES)) begin
                    crc_out = partial[bytes];
                end
            end
        end else begin : g_full_only
            // `bytes` intentionally unused in this configuration.
            /* verilator lint_off UNUSED */
            wire [CNT_W-1:0] unused_bytes = bytes;
            /* verilator lint_on UNUSED */
            assign crc_out = partial[NBYTES];
        end
    endgenerate

    // =========================================================================
    // Elaboration checks and self-verification (simulation only)
    // =========================================================================
`ifndef SYNTHESIS

    initial begin : b_elab_check
        if ((DATA_W % 8) != 0) begin
            $fatal(1, "crc32_eth: DATA_W (%0d) must be a whole number of bytes", DATA_W);
        end
    end

    // -------------------------------------------------------------------------
    // KNOWN-ANSWER SELF-CHECK
    //
    // The published CRC-32 check value: CRC32("123456789") == 0xCBF43926.
    // This exercises crc32_byte(), which is the exact function synthesized into
    // the chain above, so a pass here is a real verification of the polynomial,
    // the reflection convention, and the init/xorout constants.
    //
    // Then the FCS is appended (LSB byte first, as Ethernet transmits it) and
    // the register is required to land on the residue constant — the property
    // mac_rx relies on to check a received frame against a constant instead of
    // recomputing and comparing.
    // -------------------------------------------------------------------------
    localparam logic [71:0] CHECK_MSG = "123456789";   // 9 bytes, MSB = '1'

    // Bit-reversal, used only to prove the residue matches the value quoted in
    // manuals/02-networking/01-ethernet-phy-mac.md §4.
    function automatic logic [31:0] bitrev32(input logic [31:0] x);
        logic [31:0] y;
        begin
            for (int unsigned i = 0; i < 32; i++) begin
                y[i] = x[31-i];
            end
            bitrev32 = y;
        end
    endfunction

    initial begin : b_self_check
        logic [31:0] c;
        logic [31:0] fcs;

        // --- 1. check value -------------------------------------------------
        c = CRC_INIT;
        for (int unsigned i = 0; i < 9; i++) begin
            c = crc32_byte(c, CHECK_MSG[(8-i)*8 +: 8]);
        end
        fcs = c ^ CRC_XOROUT;
        if (fcs !== 32'hCBF4_3926) begin
            $fatal(1, "crc32_eth SELF-CHECK FAILED: CRC32(\"123456789\") = %08h, expected CBF43926", fcs);
        end

        // --- 2. residue -----------------------------------------------------
        // Append the FCS in wire order (LSB of `fcs` first) and keep running.
        c = crc32_byte(c, fcs[7:0]);
        c = crc32_byte(c, fcs[15:8]);
        c = crc32_byte(c, fcs[23:16]);
        c = crc32_byte(c, fcs[31:24]);
        if (c !== CRC_RESIDUE) begin
            $fatal(1, "crc32_eth SELF-CHECK FAILED: residue = %08h, expected %08h", c, CRC_RESIDUE);
        end

        // --- 3. the residue really is the standard's 0xC704DD7B, reflected ---
        if (bitrev32(CRC_RESIDUE) !== 32'hC704_DD7B) begin
            $fatal(1, "crc32_eth SELF-CHECK FAILED: bitrev(residue) = %08h, expected C704DD7B",
                   bitrev32(CRC_RESIDUE));
        end

        // --- 4. the empty step is the identity (bytes == 0 path) ------------
        if (partial[0] !== crc_in) begin
            $fatal(1, "crc32_eth SELF-CHECK FAILED: partial[0] is not crc_in");
        end

        $display("[crc32_eth] self-check PASS: check=%08h residue=%08h (bitrev %08h)",
                 32'hCBF4_3926, CRC_RESIDUE, bitrev32(CRC_RESIDUE));
    end

    // Interface contract: the caller must never ask for more bytes than the beat
    // holds. There is no clock here, so this is a value-change monitor rather
    // than a clocked property. The RTL is safe either way — the `bytes <= NBYTES`
    // guard above falls back to the full-width result — but a caller that trips
    // this has a bug in its byte accounting, which would silently corrupt the FCS.
    //
    // ⚠️ DELIBERATE EXCEPTION to "never use bare `always`"
    // (manuals/00-foundations/03-hdl-and-rtl-coding.md §2). This module is
    // combinational and has no clock, so there is no `always_ff` to hang a
    // concurrent assertion on, and `always_comb` may not contain only an
    // assertion. It is inside `ifndef SYNTHESIS` and never reaches synthesis.
    always @(bytes) begin : b_range_check
        if ((PARTIAL_SUPPORT != 0) && (bytes > CNT_W'(NBYTES))) begin
            $error("crc32_eth: bytes=%0d exceeds beat width of %0d bytes", bytes, NBYTES);
        end
    end

`endif

endmodule : crc32_eth

`default_nettype wire
