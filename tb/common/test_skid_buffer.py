"""Skid buffer — proves the pipeline can be cut without losing a single cycle.

INVARIANT PROVEN
    ``skid_buffer`` sustains 100% throughput (one beat accepted EVERY cycle,
    indefinitely, whenever the consumer is ready), never violates the stream
    valid/ready contract in either direction, never loses, duplicates or
    reorders a beat under ANY stall pattern, and adds exactly one cycle of
    latency — always the same one cycle.

WHY IT MATTERS
    A skid buffer exists to break a combinational ``ready`` path so the design
    can close timing.  It is inserted precisely where the datapath is most
    timing-critical, which means it sits on the tick-to-trade path.  Two
    failure modes, both expensive:

      * **It bubbles.**  A skid buffer that accepts a beat only every other
        cycle halves the ingest rate.  At 10GbE line rate the MAC cannot be
        back-pressured (CLAUDE.md §5.4) — there is nowhere to push back to —
        so the bubbles become dropped market data during exactly the busy
        microseconds that matter.  ``test_full_throughput_*`` is therefore the
        headline test: it asserts beats-accepted == cycles-elapsed.

      * **It corrupts under stall.**  If data moves while the consumer is
        stalled, the corruption surfaces fifty modules downstream as a
        mis-decoded price, and the divergence-triage table
        (manuals/01-fpga-design/05-verification-and-simulation.md §4) will send
        you hunting in the parser.

DUT
    rtl/common/skid_buffer.sv.  Ports: ``clk``, ``rst`` (sync, active high),
    ``s_data[W-1:0]``/``s_valid``/``s_ready``, ``m_data[W-1:0]``/``m_valid``/
    ``m_ready``.  Parameter ``W`` (default 64).

    NOTE: this module uses bare ``s_``/``m_`` valid/ready/data names, NOT the
    AXI-Stream ``*_tvalid``/``*_tdata`` names.  ``tb_util.StreamContractChecker``
    keys off the AXI names, so a local checker is used here.  (Reported upward
    as a request: a suffix-configurable contract checker in tb/common/.)

RUNNING
    TOPLEVEL=skid_buffer, or ``python test_skid_buffer.py``.
"""

from __future__ import annotations

import os
import pathlib
import sys

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tb_util import (  # noqa: E402
    CLK_NS,
    seed_note,
    seeded_rng,
    sim_sources,
    start_clock,
)

W_BYTES = 8  # W=64


# =============================================================================
# Local stream-contract checker (bare s_/m_ naming, see docstring)
# =============================================================================

class SkidContractChecker:
    """Continuously assert the valid/ready contract on one side of the DUT.

    The contract (manuals/01-fpga-design/01-rtl-design-patterns.md §1):
    while ``valid && !ready``, ``data`` is stable and ``valid`` does not
    de-assert.  Checked every cycle rather than at the end so the failure is
    reported at the cycle it happened.
    """

    def __init__(self, dut, valid, ready, data, label, seed=None):
        self.dut = dut
        self.v = getattr(dut, valid)
        self.r = getattr(dut, ready)
        self.d = getattr(dut, data)
        self.label = label
        self.seed = seed
        self.violations: list[str] = []
        self.beats = 0
        self.stall_cycles = 0
        self._task = None

    def start(self):
        async def _run():
            prev = None
            while True:
                await RisingEdge(self.dut.clk)
                await ReadOnly()
                if int(self.dut.rst.value):
                    prev = None
                    continue
                v, r, d = int(self.v.value), int(self.r.value), int(self.d.value)
                if v and r:
                    self.beats += 1
                if v and not r:
                    self.stall_cycles += 1
                if prev is not None and prev[0] and not prev[1]:
                    if not v:
                        self.violations.append(
                            f"{self.label}: valid de-asserted while stalled"
                        )
                    if d != prev[2]:
                        self.violations.append(
                            f"{self.label}: data changed while stalled "
                            f"0x{prev[2]:016x} -> 0x{d:016x}"
                        )
                prev = (v, r, d)

        self._task = cocotb.start_soon(_run())
        return self._task

    def stop(self):
        if self._task:
            self._task.kill()
            self._task = None

    def assert_clean(self):
        assert not self.violations, (
            f"STREAM CONTRACT VIOLATED on {self.label} "
            f"({len(self.violations)} violation(s)); first 5:\n  "
            + "\n  ".join(self.violations[:5])
            + (seed_note(self.seed) if self.seed is not None else "")
        )


async def bringup(dut, seed=None):
    start_clock(dut, "clk", CLK_NS)
    dut.rst.value = 1
    dut.s_valid.value = 0
    dut.s_data.value = 0
    dut.m_ready.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    s = SkidContractChecker(dut, "s_valid", "s_ready", "s_data", "slave", seed)
    m = SkidContractChecker(dut, "m_valid", "m_ready", "m_data", "master", seed)
    s.start()
    m.start()
    return s, m


# =============================================================================
# ⚠️ The headline property: 100% throughput
# =============================================================================

@cocotb.test()
async def test_full_throughput_consumer_always_ready(dut):
    """One beat accepted EVERY cycle for a long run, with zero bubbles.

    Consumer never stalls, producer always offers.  After the pipe has filled,
    ``s_ready`` must be high on every single cycle — not most cycles.  The
    assertion is on the exact count: beats accepted == cycles elapsed.

    A skid buffer that inserts even one bubble per N beats reduces the sustained
    ingest rate below line rate, and there is no back-pressure available to
    absorb it (CLAUDE.md §5.4).
    """
    s, m = await bringup(dut)
    n = int(os.environ.get("BEATS", "2000"))

    dut.m_ready.value = 1
    dut.s_valid.value = 1

    sent, recvd = [], []
    word = 0
    not_ready_cycles = 0

    for _ in range(n):
        dut.s_data.value = word
        await ReadOnly()
        accepted = bool(int(dut.s_ready.value))
        if int(dut.m_valid.value) and int(dut.m_ready.value):
            recvd.append(int(dut.m_data.value))
        if not accepted:
            not_ready_cycles += 1
        await RisingEdge(dut.clk)
        if accepted:
            sent.append(word)
            word += 1

    dut.s_valid.value = 0
    # Drain
    for _ in range(8):
        await ReadOnly()
        if int(dut.m_valid.value) and int(dut.m_ready.value):
            recvd.append(int(dut.m_data.value))
        await RisingEdge(dut.clk)

    assert not_ready_cycles == 0, (
        f"THROUGHPUT LOSS: s_ready was low on {not_ready_cycles} of {n} cycles "
        f"while the consumer was continuously ready. A skid buffer must accept "
        f"a beat every cycle when the downstream never stalls; every low cycle "
        f"is a cycle of market data the MAC cannot re-send."
    )
    assert len(sent) == n, f"accepted {len(sent)} of {n} offered beats"
    assert recvd == sent, (
        f"data corrupted at full rate: {len(recvd)} received vs {len(sent)} sent; "
        f"first mismatch at index "
        f"{next((i for i, (a, b) in enumerate(zip(recvd, sent)) if a != b), 'n/a')}"
    )
    s.assert_clean()
    m.assert_clean()
    dut._log.info("sustained %d beats with zero bubbles", n)


@cocotb.test()
async def test_latency_is_exactly_one_cycle_always(dut):
    """Registered output: input at cycle N appears at cycle N+1, every time.

    Asserted as EQUALITY across many single-beat transfers.  A skid buffer whose
    latency varies with occupancy is a jitter source, and on this design
    determinism is the product (CLAUDE.md §5.8).
    """
    s, m = await bringup(dut)
    dut.m_ready.value = 1

    latencies = set()
    for i in range(64):
        dut.s_data.value = 0xA5A5_0000 + i
        dut.s_valid.value = 1
        # wait for acceptance
        while True:
            await ReadOnly()
            if int(dut.s_ready.value):
                break
            await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)
        dut.s_valid.value = 0

        cycles = 0
        while True:
            cycles += 1
            await ReadOnly()
            if int(dut.m_valid.value):
                got = int(dut.m_data.value)
                break
            await RisingEdge(dut.clk)
            assert cycles < 16, "beat never emerged from the skid buffer"
        assert got == 0xA5A5_0000 + i, f"data mangled: 0x{got:x}"
        latencies.add(cycles)
        await RisingEdge(dut.clk)

    assert latencies == {1}, (
        f"skid buffer latency is not a constant 1 cycle: observed {sorted(latencies)}. "
        f"Variable latency here becomes jitter on the tick-to-trade path."
    )
    s.assert_clean()
    m.assert_clean()


# =============================================================================
# Data integrity under every stall shape
# =============================================================================

async def _run_pattern(dut, s, m, ready_pattern, n_beats, seed, label):
    """Drive n_beats through the DUT with a scripted m_ready pattern."""
    sent, recvd = [], []
    word, i = 0, 0
    guard = 0
    dut.s_valid.value = 1
    while len(recvd) < n_beats:
        guard += 1
        assert guard < n_beats * 50 + 1000, (
            f"{label}: deadlock — {len(recvd)}/{n_beats} beats after {guard} cycles"
            + seed_note(seed)
        )
        dut.m_ready.value = int(ready_pattern(i))
        if word < n_beats:
            dut.s_data.value = word
            dut.s_valid.value = 1
        else:
            dut.s_valid.value = 0

        await ReadOnly()
        s_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        m_fire = int(dut.m_valid.value) and int(dut.m_ready.value)
        m_word = int(dut.m_data.value) if m_fire else None
        await RisingEdge(dut.clk)

        if s_fire:
            sent.append(word)
            word += 1
        if m_fire:
            recvd.append(m_word)
        i += 1

    dut.s_valid.value = 0
    assert recvd == list(range(n_beats)), (
        f"{label}: beats lost, duplicated or reordered.\n"
        f"  expected {list(range(min(8, n_beats)))}...\n"
        f"  got      {recvd[:8]}...\n"
        f"  len sent={len(sent)} recvd={len(recvd)}" + seed_note(seed)
    )
    s.assert_clean()
    m.assert_clean()


@cocotb.test()
async def test_integrity_under_every_stall_shape(dut):
    """No loss, duplication or reordering under each characteristic stall shape.

    Each pattern targets a different internal transition of the two-register
    skid structure: the moment it fills, the moment it drains, and the
    single-cycle stall that is the whole reason the second register exists.
    """
    rng, seed = seeded_rng(dut, "skid.patterns")
    s, m = await bringup(dut, seed)

    patterns = {
        "always ready": lambda i: True,
        "alternating": lambda i: i % 2 == 0,
        "1-in-3": lambda i: i % 3 == 0,
        "long stalls (16 on, 16 off)": lambda i: (i // 16) % 2 == 0,
        "single-cycle stalls": lambda i: i % 7 != 3,
        "stall immediately (first 20 cycles)": lambda i: i >= 20,
        "mostly stalled": lambda i: i % 11 == 0,
    }
    for label, pat in patterns.items():
        dut.rst.value = 1
        await ClockCycles(dut.clk, 3)
        dut.rst.value = 0
        await RisingEdge(dut.clk)
        await _run_pattern(dut, s, m, pat, 200, seed, label)
        dut._log.info("stall pattern OK: %s", label)


@cocotb.test()
async def test_integrity_under_random_stalls(dut):
    """Constrained-random producer/consumer stalling, deterministic seed.

    Directed patterns find the shapes you thought of; this finds the rest.  The
    producer also leaves random GAPS between beats — cycles where it offers
    nothing — which is legal and must not disturb anything held in the skid
    register.

    ⚠️ A gap is only legal BETWEEN beats.  ``rtl/common/skid_buffer.sv``'s header
    states the interface contract this module is entitled to assume, and asserts
    it at line 127:

        1. Once `valid` is asserted it must not de-assert until a transfer
           completes.
        2. `data` must be stable while `valid && !ready`.

    So a beat that has been offered and not yet accepted must be HELD — same
    ``s_valid``, same ``s_data`` — until ``s_ready`` takes it.  Re-rolling the
    offer every cycle withdraws un-accepted beats and trips the module's own
    input-contract assertion, which is a defect in the stimulus, not in the DUT.
    ``_run_pattern`` above holds ``s_valid`` for exactly this reason.
    """
    rng, seed = seeded_rng(dut, "skid.random")
    s, m = await bringup(dut, seed)
    n = int(os.environ.get("BEATS", "3000"))

    sent, recvd = [], []
    word = 0
    guard = 0
    offering = False        # a beat offered and not yet accepted — must be held
    while len(recvd) < n:
        guard += 1
        assert guard < n * 50 + 1000, (
            f"deadlock: {len(recvd)}/{n} beats after {guard} cycles" + seed_note(seed)
        )
        # Roll a new offer only when none is outstanding; hold an outstanding one.
        if not offering:
            offering = word < n and rng.random() < 0.75
        dut.s_valid.value = int(offering)
        if offering:
            dut.s_data.value = word
        dut.m_ready.value = int(rng.random() < 0.6)

        await ReadOnly()
        s_fire = int(dut.s_valid.value) and int(dut.s_ready.value)
        m_fire = int(dut.m_valid.value) and int(dut.m_ready.value)
        m_word = int(dut.m_data.value) if m_fire else None
        await RisingEdge(dut.clk)

        if s_fire:
            sent.append(word)
            word += 1
            offering = False
        if m_fire:
            recvd.append(m_word)

    assert recvd == list(range(n)), (
        "random-stall soak lost, duplicated or reordered beats; first divergence "
        f"at index {next((i for i, v in enumerate(recvd) if v != i), 'n/a')}"
        + seed_note(seed)
    )
    s.assert_clean()
    m.assert_clean()
    dut._log.info(
        "random soak: %d beats, %d slave stall cycles, %d master stall cycles",
        n, s.stall_cycles, m.stall_cycles,
    )


# =============================================================================
# Reset
# =============================================================================

@cocotb.test()
async def test_reset_mid_transaction_discards_cleanly(dut):
    """A reset asserted with beats in flight leaves the buffer empty, not stale.

    After release, ``m_valid`` must be low and the next beat through must be the
    NEW beat — never a survivor from before the reset.  A skid buffer that
    replays a pre-reset beat injects a stale market-data update into a freshly
    re-armed pipeline, which is how a book comes up already wrong.
    """
    rng, seed = seeded_rng(dut, "skid.reset")
    s, m = await bringup(dut, seed)

    for stall_before_reset in range(0, 6):
        # Fill the buffer: offer beats with the consumer stalled.
        #
        # ⚠️ Only TWO beats can be accepted with `m_ready` low (output register
        # + skid slot); after that `s_ready` falls and the third beat sits
        # un-accepted at the input. Contract rule 2 (skid_buffer.sv header) says
        # `s_data` must be STABLE while `s_valid && !s_ready`, so the offered
        # word may only advance on a cycle the DUT actually took it. Advancing
        # it every cycle regardless — as this loop used to — moves data under a
        # stalled handshake and trips the module's input-contract assertion.
        dut.m_ready.value = 0
        dut.s_valid.value = 1
        k = 0
        for _ in range(4):
            dut.s_data.value = 0xDEAD_0000 + k
            await ReadOnly()
            accepted = int(dut.s_ready.value)
            await RisingEdge(dut.clk)
            if accepted:
                k += 1
        await ClockCycles(dut.clk, stall_before_reset)

        dut.rst.value = 1
        dut.s_valid.value = 0
        await ClockCycles(dut.clk, 3)
        dut.rst.value = 0
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.m_valid.value) == 0, (
            f"m_valid still asserted after reset (stall_before_reset="
            f"{stall_before_reset}) — a pre-reset beat survived and would be "
            f"injected into a freshly re-armed pipeline." + seed_note(seed)
        )
        assert int(dut.s_ready.value) == 1, (
            "s_ready low immediately after reset — the buffer did not empty"
            + seed_note(seed)
        )
        await RisingEdge(dut.clk)

        # The next beat through must be the new one.
        dut.m_ready.value = 1
        dut.s_valid.value = 1
        dut.s_data.value = 0xBEEF_0000 + stall_before_reset
        await RisingEdge(dut.clk)
        dut.s_valid.value = 0
        await ReadOnly()
        got = int(dut.m_data.value)
        assert int(dut.m_valid.value) and got == 0xBEEF_0000 + stall_before_reset, (
            f"first post-reset beat was 0x{got:x}, expected "
            f"0x{0xBEEF_0000 + stall_before_reset:x} — stale data survived reset."
            + seed_note(seed)
        )
        await RisingEdge(dut.clk)

    s.assert_clean()
    m.assert_clean()


@cocotb.test()
async def test_no_output_when_empty(dut):
    """``m_valid`` is never asserted with nothing inside.

    A phantom beat is worse than a dropped one: it is a book update that never
    happened.
    """
    s, m = await bringup(dut)
    dut.m_ready.value = 1
    dut.s_valid.value = 0
    for _ in range(200):
        await ReadOnly()
        assert int(dut.m_valid.value) == 0, (
            "m_valid asserted with an empty skid buffer — phantom beat"
        )
        await RisingEdge(dut.clk)
    s.assert_clean()
    m.assert_clean()


if __name__ == "__main__":  # pragma: no cover
    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        from cocotb.runner import get_runner

    runner = get_runner(os.environ.get("SIM", "verilator"))
    runner.build(
        verilog_sources=sim_sources("rtl/common/skid_buffer.sv"),
        hdl_toplevel="skid_buffer",
        # --timing: the RTL uses delay controls that Verilator refuses to
        # compile without an explicit timing mode (NEEDTIMINGOPT).
        # tb/common/Makefile passes it, which is why this module built under
        # that path and not under this runner.
        build_args=["-Wno-fatal", "--timing"],
        always=True,
    )
    runner.test(hdl_toplevel="skid_buffer", test_module="test_skid_buffer")
