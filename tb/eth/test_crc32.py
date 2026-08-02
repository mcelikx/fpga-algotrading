"""Ethernet CRC-32 (FCS) — proves the frame-integrity primitive is exactly IEEE 802.3.

INVARIANT PROVEN
    ``crc32_eth`` computes the IEEE 802.3 §3.2.9 CRC-32 for EVERY legal beat
    shape — full 8-byte beats and all eight widths of ragged final beat — and
    the receiver-side residue property holds: absorbing ``message || FCS``
    always leaves the register at the standard residue constant.

WHY IT MATTERS
    The FCS is the ONLY thing that distinguishes a market-data frame that
    arrived intact from one a bit-error mangled in the optics.  This system runs
    a CUT-THROUGH MAC (fpga_top.sv: ``CUT_THROUGH(1)``): payload bytes are
    forwarded into the decoder BEFORE the FCS is known, so the FCS check is not
    a gate, it is an after-the-fact verdict that marks the frame bad on
    ``tuser`` at ``tlast``.  If that verdict is wrong, a corrupted price is
    already inside the order book, and the book stays wrong for the rest of the
    session.

    The specific failure this file hunts: a CRC that is correct for full 8-byte
    beats and wrong for a 3-byte tail.  Ethernet frame lengths are not multiples
    of 8, so *most* real frames end on a partial beat.  A design with that bug
    passes any test written with 64-byte payloads and rejects a large fraction
    of live traffic — or, far worse, accepts corrupt frames.  All eight tail
    widths are therefore enumerated explicitly, not sampled.

DUT
    rtl/eth/crc32_eth.sv — PURELY COMBINATIONAL (0 cycles, deliberate exception
    to the registered-output rule; the consumer registers the result).  Ports:
    ``crc_in[31:0]``, ``data[DATA_W-1:0]``, ``bytes[$clog2(DATA_W/8+1)-1:0]``,
    ``crc_out[31:0]``.  Byte order: ``data[7:0]`` is the FIRST byte on the wire.

    Register convention is REFLECTED (LSB-first, zlib-style): poly 0xEDB88320,
    init 0xFFFFFFFF, xorout 0xFFFFFFFF, residue 0xDEBB20E3.  The module header
    notes that manuals/02-networking/01-ethernet-phy-mac.md quotes the residue
    as 0xC704DD7B, which is the same constant bit-reversed (the non-reflected
    form).  Both are asserted below so the two conventions can never silently
    diverge.

    Because the module is combinational there is no clock and no reset; a
    settling delay is used between stimulus and sample.

RUNNING
    TOPLEVEL=crc32_eth, or ``python test_crc32.py`` to drive the runner.
"""

from __future__ import annotations

import os
import pathlib
import sys
import zlib

import cocotb
from cocotb.triggers import Timer

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "common"))
from tb_util import CoverageDB, seed_note, seeded_rng, sim_sources  # noqa: E402

# --- constants, mirrored from rtl/eth/crc32_eth.sv -------------------------
CRC_INIT = 0xFFFF_FFFF
CRC_XOROUT = 0xFFFF_FFFF
CRC_RESIDUE_REFLECTED = 0xDEBB_20E3
CRC_RESIDUE_NORMAL = 0xC704_DD7B  # the manual's form == bitrev(reflected)
CHECK_VECTOR_123456789 = 0xCBF4_3926  # IEEE "check" value

BYTES_PER_BEAT = 8  # DATA_W=64
SETTLE_NS = 1  # combinational settling time


def bitrev32(v: int) -> int:
    """Bit-reverse a 32-bit word — converts between the reflected and normal
    CRC register conventions."""
    return int(f"{v & 0xFFFF_FFFF:032b}"[::-1], 2)


def crc_register_model(payload: bytes) -> int:
    """Reference RAW CRC REGISTER value after absorbing ``payload``.

    Derived from zlib (which implements the same reflected IEEE 802.3 CRC-32)
    rather than copied from a table of magic numbers, so this oracle is
    independently checkable.  zlib returns the FINAL crc (xorout applied); the
    RTL exposes the raw register, hence the xor back out.
    """
    return zlib.crc32(payload) ^ CRC_XOROUT


def fcs_bytes(payload: bytes) -> bytes:
    """The 4 FCS bytes as transmitted on the wire, LSB of the final CRC first."""
    return (zlib.crc32(payload) & 0xFFFF_FFFF).to_bytes(4, "little")


async def crc_step(dut, crc_in: int, beat: bytes) -> int:
    """One combinational CRC step over ``beat`` (1..8 bytes, or empty)."""
    dut.crc_in.value = crc_in & 0xFFFF_FFFF
    # data[7:0] is the FIRST byte on the wire, so pack little-endian.
    dut.data.value = int.from_bytes(beat.ljust(BYTES_PER_BEAT, b"\x00"), "little")
    dut.bytes.value = len(beat)
    await Timer(SETTLE_NS, units="ns")
    return int(dut.crc_out.value)


async def crc_stream(dut, payload: bytes, crc_in: int = CRC_INIT) -> int:
    """Absorb a whole payload as a sequence of beats, returning the raw register.

    The final beat carries ``len(payload) % 8`` bytes (or 8 when it divides
    evenly) — i.e. exactly the ragged-tail case the MAC presents.
    """
    crc = crc_in
    for off in range(0, len(payload), BYTES_PER_BEAT):
        crc = await crc_step(dut, crc, payload[off:off + BYTES_PER_BEAT])
    return crc


# =============================================================================
# Directed: the constants the standard itself names
# =============================================================================

@cocotb.test()
async def test_ieee_check_value(dut):
    """CRC32("123456789") == 0xCBF43926 — the check value named in IEEE 802.3.

    This is the one vector every CRC implementation in the world is measured
    against.  If this fails, nothing else in this file is meaningful.  It is
    driven through the real beat interface (9 bytes = one full beat + a 1-byte
    tail), so it also exercises the partial-beat path.
    """
    reg = await crc_stream(dut, b"123456789")
    final = reg ^ CRC_XOROUT
    assert final == CHECK_VECTOR_123456789, (
        f"IEEE 802.3 check value wrong: got 0x{final:08X}, "
        f"expected 0x{CHECK_VECTOR_123456789:08X}. The polynomial, the "
        f"reflection convention, or the init/xorout constants are wrong."
    )


@cocotb.test()
async def test_residue_constant_conventions_agree(dut):
    """The reflected residue and the manual's normal-form residue are one constant.

    manuals/02-networking/01-ethernet-phy-mac.md quotes 0xC704DD7B; crc32_eth.sv
    implements the reflected register whose residue is 0xDEBB20E3.  Asserting
    ``bitrev(one) == other`` here means a future edit to either document cannot
    silently introduce a real disagreement — the two numbers stay provably the
    same constant viewed two ways.
    """
    assert bitrev32(CRC_RESIDUE_REFLECTED) == CRC_RESIDUE_NORMAL, (
        f"residue conventions diverged: bitrev(0x{CRC_RESIDUE_REFLECTED:08X}) = "
        f"0x{bitrev32(CRC_RESIDUE_REFLECTED):08X} != 0x{CRC_RESIDUE_NORMAL:08X}"
    )
    dut._log.info(
        "residue: reflected 0x%08X == normal 0x%08X (bit-reversed)",
        CRC_RESIDUE_REFLECTED, CRC_RESIDUE_NORMAL,
    )


@cocotb.test()
async def test_hand_checked_ethernet_vectors(dut):
    """Three literal frame vectors, each chosen to prove a different thing.

    Golden vectors are legitimate here because the SPEC is the oracle for a
    byte layout (manuals/06-operations/04-testing-strategy.md §3).  Each carries
    a comment naming what it proves.
    """
    vectors = [
        # 64-byte minimum Ethernet frame payload (the length the MAC pads to).
        # Proves the common full-beat-only path with no ragged tail.
        ("64B minimum frame, all 0x00", bytes(64)),
        # All-zero content is the classic way to catch a CRC whose init value is
        # wrong: with init=0 instead of 0xFFFFFFFF, this vector returns 0.
        ("46B all-zero payload", bytes(46)),
        # Incrementing bytes: every data bit position participates, so a wrong
        # tap in the XOR tree cannot cancel out.
        ("60B incrementing", bytes(range(60))),
    ]
    for name, payload in vectors:
        reg = await crc_stream(dut, payload)
        expect = crc_register_model(payload)
        assert reg == expect, (
            f"vector {name!r}: register 0x{reg:08X} != expected 0x{expect:08X}"
        )
        # An all-zero payload must NOT produce an all-zero CRC — that is the
        # signature of a missing init value.
        if set(payload) == {0}:
            assert reg != 0, (
                f"vector {name!r} produced a zero CRC register for an all-zero "
                f"payload — CRC_INIT is not being applied (init must be "
                f"0x{CRC_INIT:08X})."
            )


# =============================================================================
# ⚠️ All eight partial-final-beat widths — the defect class this file exists for
# =============================================================================

@cocotb.test()
async def test_all_eight_partial_final_beat_widths(dut):
    """Every one of the 8 possible final-beat byte counts is exact.

    The datapath is 64-bit, so a frame ends with 1..8 valid bytes in its last
    beat.  ``bytes`` selects which tap of the internal byte chain is muxed out.
    A wrong tap is invisible for full beats and corrupts every frame whose
    length is not a multiple of 8 — which is most frames.

    Enumerated exhaustively, with several payload lengths per tail width so a
    tail-width bug cannot hide behind one particular preceding beat count.
    """
    cov = CoverageDB("crc32.partial_widths")
    for tail in range(1, BYTES_PER_BEAT + 1):
        for n_full_beats in (0, 1, 2, 7):
            length = n_full_beats * BYTES_PER_BEAT + tail
            payload = bytes((i * 7 + tail) & 0xFF for i in range(length))
            reg = await crc_stream(dut, payload)
            expect = crc_register_model(payload)
            assert reg == expect, (
                f"PARTIAL FINAL BEAT WRONG: tail={tail} byte(s) after "
                f"{n_full_beats} full beat(s) (len={length})\n"
                f"  register 0x{reg:08X} != expected 0x{expect:08X}\n"
                f"  This is the #1 CRC defect class: correct for full beats, "
                f"wrong for a {tail}-byte tail, so most real frame lengths fail."
            )
            cov.hit(tail=tail, full_beats=n_full_beats)
    cov.assert_all_hit(
        [{"tail": t, "full_beats": f}
         for t in range(1, BYTES_PER_BEAT + 1) for f in (0, 1, 2, 7)]
    )
    dut._log.info("partial-beat coverage: %s", cov.summary())


@cocotb.test()
async def test_bytes_zero_is_identity(dut):
    """``bytes == 0`` returns ``crc_in`` unchanged.

    The module header documents this as legal: mac_rx presents it when the XGMII
    terminate character lands in lane 0.  If a zero-byte beat perturbed the
    register, every frame whose length is an exact multiple of 8 would fail its
    FCS check — a bug that looks like random packet loss.
    """
    for crc_in in (CRC_INIT, 0x0000_0000, 0xDEAD_BEEF, CRC_RESIDUE_REFLECTED):
        out = await crc_step(dut, crc_in, b"")
        assert out == crc_in, (
            f"bytes==0 perturbed the register: in 0x{crc_in:08X} -> "
            f"out 0x{out:08X}; a zero-byte beat must be the identity."
        )


# =============================================================================
# ⚠️ The residue property — the strongest available check
# =============================================================================

@cocotb.test()
async def test_residue_property_random_frames(dut):
    """For random frames: absorbing ``message || FCS`` yields the residue constant.

    This is the RECEIVER-side check the MAC actually performs, and it is a far
    stronger statement than any fixed vector: it says the CRC is correct for
    this message AND that the transmit-side byte ordering of the FCS agrees with
    the receive-side interpretation.  A byte-swapped FCS passes a naive
    "compare the CRC" test and fails this one.

    Random lengths 60..1518 (the legal Ethernet frame range) so every tail width
    and every beat count is exercised without being enumerated.
    """
    rng, seed = seeded_rng(dut, "crc32.residue")
    n_frames = int(os.environ.get("FRAMES", "300"))
    widths_seen = set()

    for i in range(n_frames):
        length = rng.randrange(60, 1519)
        payload = bytes(rng.randrange(256) for _ in range(length))
        framed = payload + fcs_bytes(payload)
        reg = await crc_stream(dut, framed)
        assert reg == CRC_RESIDUE_REFLECTED, (
            f"RESIDUE CHECK FAILED on frame {i} (payload len {length}, "
            f"framed len {len(framed)})\n"
            f"  register 0x{reg:08X} != residue 0x{CRC_RESIDUE_REFLECTED:08X}\n"
            f"  A receiver using the residue test would reject this good frame, "
            f"or accept a corrupt one." + seed_note(seed)
        )
        widths_seen.add(len(framed) % BYTES_PER_BEAT or BYTES_PER_BEAT)

    assert widths_seen == set(range(1, BYTES_PER_BEAT + 1)), (
        f"random frames did not exercise every tail width: saw "
        f"{sorted(widths_seen)}, wanted 1..8. Increase FRAMES."
        + seed_note(seed)
    )
    dut._log.info("residue property held for %d random frames", n_frames)


@cocotb.test()
async def test_single_bit_error_is_detected(dut):
    """Flipping ANY single bit of a framed message breaks the residue.

    CRC-32 detects all 1- and 2-bit errors by construction; this asserts the
    implementation actually delivers that guarantee.  It is the property that
    makes ``tuser`` at ``tlast`` trustworthy — and therefore the property that
    makes cut-through forwarding safe to do at all.
    """
    rng, seed = seeded_rng(dut, "crc32.bitflip")
    payload = bytes(rng.randrange(256) for _ in range(97))  # ragged tail
    framed = bytearray(payload + fcs_bytes(payload))

    baseline = await crc_stream(dut, bytes(framed))
    assert baseline == CRC_RESIDUE_REFLECTED, (
        "baseline frame failed the residue check before any corruption"
        + seed_note(seed)
    )

    for _ in range(40):
        idx = rng.randrange(len(framed))
        bit = rng.randrange(8)
        framed[idx] ^= 1 << bit
        reg = await crc_stream(dut, bytes(framed))
        assert reg != CRC_RESIDUE_REFLECTED, (
            f"UNDETECTED CORRUPTION: flipping bit {bit} of byte {idx} still "
            f"produced the residue. A corrupt frame would be forwarded with "
            f"tuser clear and its prices would enter the book."
            + seed_note(seed)
        )
        framed[idx] ^= 1 << bit  # restore


@cocotb.test()
async def test_beat_chunking_is_irrelevant(dut):
    """The same payload absorbed in different beat splits gives the same CRC.

    A CRC is a running register, so the answer must not depend on how the MAC
    happened to chunk the frame.  If it does, the CRC depends on arrival
    alignment — which varies with where the frame started in the 64-bit stream
    — and the same frame would sometimes pass and sometimes fail.
    """
    rng, seed = seeded_rng(dut, "crc32.chunking")
    for _ in range(30):
        payload = bytes(rng.randrange(256) for _ in range(rng.randrange(1, 200)))
        reference = await crc_stream(dut, payload)

        # Absorb the same payload with randomly-sized (1..8 byte) beats.
        crc = CRC_INIT
        off = 0
        while off < len(payload):
            n = min(rng.randrange(1, BYTES_PER_BEAT + 1), len(payload) - off)
            crc = await crc_step(dut, crc, payload[off:off + n])
            off += n
        assert crc == reference, (
            f"CRC depends on beat chunking: streamed 0x{reference:08X} in "
            f"8-byte beats, 0x{crc:08X} in random-width beats, same {len(payload)}"
            f"-byte payload." + seed_note(seed)
        )


@cocotb.test()
async def test_randomized_against_zlib(dut):
    """Broad randomized equivalence against the independent zlib oracle."""
    rng, seed = seeded_rng(dut, "crc32.random")
    n = int(os.environ.get("ITERS", "400"))
    for i in range(n):
        length = rng.randrange(0, 256)
        payload = bytes(rng.randrange(256) for _ in range(length))
        reg = await crc_stream(dut, payload)
        expect = crc_register_model(payload)
        assert reg == expect, (
            f"iteration {i}, len={length}: 0x{reg:08X} != 0x{expect:08X}"
            + seed_note(seed)
        )
    dut._log.info("randomized equivalence: %d payloads vs zlib", n)


# =============================================================================
# Standalone runner
# =============================================================================

if __name__ == "__main__":  # pragma: no cover
    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        from cocotb.runner import get_runner  # cocotb < 2.0

    runner = get_runner(os.environ.get("SIM", "verilator"))
    runner.build(
        verilog_sources=sim_sources("rtl/eth/crc32_eth.sv"),
        hdl_toplevel="crc32_eth",
        build_args=["--trace", "-Wno-fatal"],
        always=True,
    )
    runner.test(hdl_toplevel="crc32_eth", test_module="test_crc32")
