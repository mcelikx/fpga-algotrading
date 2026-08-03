"""req/ack wide-bus crossing — proves the unsynchronized data bus is safe.

INVARIANT PROVEN
    ``cdc_handshake`` delivers every accepted word, unmodified, exactly once,
    in order, at every clock ratio from 1:8 to 8:1 and at randomized phase:

      * ``dst_data`` at each ``dst_valid`` equals the word the source presented
        when ``src_valid && src_ready`` — bit for bit, including all-zeros,
        all-ones and every walking-one pattern.
      * ``dst_valid`` fires exactly once per accepted transfer and is exactly
        one destination cycle wide.
      * Once a transfer is accepted, changing ``src_data`` cannot affect it.
        The word is captured in the source hold register at the accepting edge.
      * Round-trip latency matches the header: ``src_ready`` returns 9-11 source
        cycles after acceptance at equal frequency, i.e. one word per ~10
        cycles sustained.
      * Back-to-back transfers never deadlock, at any ratio, over hundreds of
        words.

WHY IT MATTERS
    This is the primitive the host uses to push **risk limits** into the fabric
    (rtl/common/cdc_handshake.sv:11): position limits, notional caps,
    price collars, strategy parameters, OUCH templates.  A torn transfer here is
    not a dropped message — it is a *wrong limit installed in the risk gate*,
    and the risk gate will then enforce it perfectly.

    The reason this primitive is dangerous enough to deserve its own file is on
    line 35 of the RTL: **the data bus is not synchronized, and must not be.**
    ``src_data_q`` goes straight into ``dst_data_q`` as a plain asynchronous
    path.  That is correct only because the four-phase protocol guarantees the
    bus is stable for the whole window in which the destination samples it.  So
    the protocol IS the safety argument, and this file's job is to prove the
    protocol.

    ⚠️ WHAT THIS FILE CANNOT PROVE, AND NOTHING IN SIMULATION CAN:
    that the bus actually arrives inside one destination period in silicon.
    RTL simulation delivers all 32 bits at the same zero-delay instant, every
    time, forever.  Bit skew is created by ROUTING, and it is bounded by the
    XDC block at rtl/common/cdc_handshake.sv:53-95 — ``set_max_delay
    -datapath_only`` plus ``set_bus_skew``, never ``set_false_path``.  Manual
    00.04 §5 and §7 (last row): a false-pathed CDC bus tears under temperature,
    in production, months later.  Passing this file is necessary and nowhere
    near sufficient; ``report_cdc`` (merge gate 5) is the other half.

DUT
    rtl/common/cdc_handshake.sv (instantiates cdc_sync_bit).  Ports:
    ``src_clk``/``src_rst``/``src_data``/``src_valid``/``src_ready`` and
    ``dst_clk``/``dst_rst``/``dst_data``/``dst_valid``.  Parameters ``W`` and
    ``SYNC_STAGES``.

RUNNING
    TOPLEVEL=cdc_handshake, or ``python test_cdc_handshake.py``.
"""

from __future__ import annotations

import os
import pathlib
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tb_util import seed_note, seeded_rng, sim_sources  # noqa: E402

BASE_PS = 6400          # core_clk, 156.25 MHz
PCIE_PS = 4000          # pcie_clk, 250 MHz — the real crossing in this design

RATIOS: list[tuple[str, int, int]] = [
    ("1:8  src slow", BASE_PS * 8, BASE_PS),
    ("1:4  src slow", BASE_PS * 4, BASE_PS),
    ("1:2  src slow", BASE_PS * 2, BASE_PS),
    ("1:1  equal", BASE_PS, BASE_PS),
    ("1:1  near-equal", BASE_PS, BASE_PS + 2),
    ("pcie->core", PCIE_PS, BASE_PS),      # the real one: 250 MHz -> 156.25 MHz
    ("core->pcie", BASE_PS, PCIE_PS),      # and the return path
    ("2:1  src fast", BASE_PS, BASE_PS * 2),
    ("4:1  src fast", BASE_PS, BASE_PS * 4),
    ("8:1  src fast", BASE_PS, BASE_PS * 8),
]


# =============================================================================
# Infrastructure
# =============================================================================

#: One simulation runs every test in this file, and each ratio restarts both
#: clocks. Without this registry the previous driver task keeps toggling the net
#: alongside the new one. Kill the old driver first.
_CLOCKS: dict[str, object] = {}


def start_clock_ps(dut, name: str, period_ps: int, phase_ps: int = 0):
    old = _CLOCKS.pop(name, None)
    if old is not None:
        old.kill()
    handle = getattr(dut, name)

    async def _run():
        if phase_ps:
            await Timer(phase_ps, units="ps")
        await Clock(handle, period_ps, units="ps").start()

    task = cocotb.start_soon(_run())
    _CLOCKS[name] = task
    return task


def dut_width(dut) -> int:
    return len(dut.src_data)


def sync_stages(dut) -> int:
    for path in ("u_req_sync", "u_ack_sync"):
        try:
            n = len(getattr(dut, path).sync_q)
            if n >= 2:
                return n
        except Exception:  # pragma: no cover - flattened hierarchy
            pass
    return int(os.environ.get("SYNC_STAGES", "2"))


class DstCollector:
    """Capture every ``dst_valid`` beat and police the one-cycle width.

    Runs continuously on ``dst_clk``.  ``dst_data`` is registered and only
    changes on the capture edge, so reading it in the ReadOnly phase of the
    cycle ``dst_valid`` is high yields exactly the captured word.
    """

    def __init__(self, dut):
        self.dut = dut
        self.words: list[int] = []
        self.cycles: list[int] = []
        self.width_violations: list[int] = []
        self._task = None
        self._cyc = 0

    def start(self):
        async def _run():
            prev = 0
            while True:
                await RisingEdge(self.dut.dst_clk)
                await ReadOnly()
                self._cyc += 1
                if int(self.dut.dst_rst.value):
                    prev = 0
                    continue
                v = int(self.dut.dst_valid.value)
                if v:
                    self.words.append(int(self.dut.dst_data.value))
                    self.cycles.append(self._cyc)
                    if prev:
                        self.width_violations.append(self._cyc)
                prev = v

        self._task = cocotb.start_soon(_run())
        return self._task

    def stop(self):
        if self._task:
            self._task.kill()
            self._task = None

    def assert_single_cycle(self, ctx: str = ""):
        assert not self.width_violations, (
            f"dst_valid was high for more than one destination cycle at "
            f"{self.width_violations[:8]} {ctx}.\n"
            f"  dst_valid is a single-cycle strobe "
            f"(rtl/common/cdc_handshake.sv:113). A consumer that treats it as a "
            f"level applies the same risk-limit write twice."
        )


#: Only one destination collector may run at a time; two would double-count
#: every transfer.
_COL: list[DstCollector] = []


async def bringup(dut, src_ps: int, dst_ps: int, src_phase: int = 0,
                  dst_phase: int = 0) -> DstCollector:
    while _COL:
        _COL.pop().stop()
    dut.src_valid.value = 0
    dut.src_data.value = 0
    dut.src_rst.value = 1
    dut.dst_rst.value = 1
    start_clock_ps(dut, "src_clk", src_ps, src_phase)
    start_clock_ps(dut, "dst_clk", dst_ps, dst_phase)
    # Both resets asserted and released together — the caller obligation at
    # rtl/common/cdc_handshake.sv:48. Deviating from it is a separate test.
    await Timer(12 * max(src_ps, dst_ps), units="ps")
    dut.src_rst.value = 0
    dut.dst_rst.value = 0
    await Timer(6 * max(src_ps, dst_ps), units="ps")
    col = DstCollector(dut)
    col.start()
    _COL.append(col)
    return col


async def offer(dut, value: int) -> bool:
    """Present one word for exactly one source cycle.  True if it was ACCEPTED.

    Driven on the FALLING edge.  ``src_ready`` is ``!req_q && !ack_sync`` — two
    flip-flop outputs — so it cannot change between source rising edges, and
    reading it at the midpoint is exactly what the next rising edge will see.
    It does not depend on ``src_valid``, so reading it before driving is sound.

    Returns just after the accepting edge, so the caller may immediately drop
    ``src_valid`` or present the next word without cancelling this one.
    Consumes exactly one source cycle either way, which is what makes the
    caller's re-offer loop hold ``src_data`` stable while stalled — the stream
    contract the RTL asserts at rtl/common/cdc_handshake.sv:208.
    """
    await FallingEdge(dut.src_clk)
    ready = int(dut.src_ready.value)
    dut.src_data.value = value
    dut.src_valid.value = 1
    await RisingEdge(dut.src_clk)
    return bool(ready)


async def send_word(dut, value: int, limit: int = 400) -> None:
    """Offer ``value`` until accepted, holding the stream contract while stalled.

    While ``src_valid && !src_ready`` the source must hold both ``src_valid``
    and ``src_data`` (rtl/common/cdc_handshake.sv:207) — so this loop re-drives
    the SAME value rather than withdrawing.
    """
    for _ in range(limit):
        if await offer(dut, value):
            dut.src_valid.value = 0
            return
    raise AssertionError(
        f"src_ready never returned within {limit} source cycles while offering "
        f"0x{value:x} — the channel is deadlocked. rtl/common/cdc_handshake.sv:229 "
        f"calls this out as 'dst_clk stopped or resets out of phase'."
    )


def patterns(w: int, rng) -> list[int]:
    """Payloads chosen to expose a stuck bit or a torn capture immediately."""
    mask = (1 << w) - 1
    out = [0, mask, 0xA5A5_A5A5_A5A5_A5A5 & mask, 0x5A5A_5A5A_5A5A_5A5A & mask]
    out += [(1 << b) for b in range(w)]           # walking one
    out += [mask ^ (1 << b) for b in range(w)]    # walking zero
    out += [rng.getrandbits(w) for _ in range(64)]
    return out


# =============================================================================
# 1. THE headline: data integrity across ratios
# =============================================================================

@cocotb.test()
async def test_data_integrity_across_clock_ratios(dut):
    """Every accepted word arrives, unmodified, exactly once, in order.

    Ten source:destination ratios including the two that actually exist in this
    design (250 MHz pcie_clk <-> 156.25 MHz core_clk) and a near-equal pair that
    walks the two clocks through every phase relationship during the run.
    Phase is randomized per ratio from the logged seed.

    The payload set is deliberately hostile: all-zeros, all-ones, walking ones,
    walking zeros, then random.  A single-bit tear or a stuck bit in the
    unsynchronized bus shows up as one wrong word, and the first-divergence
    report names the bit.
    """
    rng, seed = seeded_rng(dut, "cdc_handshake.ratios")
    w = dut_width(dut)

    for label, src_ps, dst_ps in RATIOS:
        col = await bringup(
            dut, src_ps, dst_ps,
            src_phase=rng.randrange(0, src_ps),
            dst_phase=rng.randrange(0, dst_ps),
        )
        words = patterns(w, rng)
        for value in words:
            await send_word(dut, value)
            # Random idle between transfers so acceptance does not land on a
            # repeating phase.
            for _ in range(rng.randrange(0, 3)):
                await RisingEdge(dut.src_clk)

        await Timer(40 * max(src_ps, dst_ps), units="ps")
        col.stop()
        col.assert_single_cycle(f"[{label}]")

        assert len(col.words) == len(words), (
            f"[{label}] transfer COUNT wrong: sent {len(words)}, received "
            f"{len(col.words)}.\n"
            f"  src period {src_ps} ps, dst period {dst_ps} ps. A missing "
            f"transfer is a risk limit that was never installed; a duplicate is "
            f"one installed twice." + seed_note(seed)
        )
        for i, (got, exp) in enumerate(zip(col.words, words)):
            if got != exp:
                raise AssertionError(
                    f"[{label}] FIRST DIVERGENCE at transfer {i}\n"
                    f"  expected : 0x{exp:0{(w + 3) // 4}x}\n"
                    f"  actual   : 0x{got:0{(w + 3) // 4}x}\n"
                    f"  xor      : 0x{got ^ exp:0{(w + 3) // 4}x}  "
                    f"({bin(got ^ exp).count('1')} bit(s) differ)\n"
                    f"  A partial-word difference is TORN DATA: the destination "
                    f"captured while the source bus was still settling. In "
                    f"silicon that is a bus-skew failure "
                    f"(rtl/common/cdc_handshake.sv:70). In simulation it means "
                    f"the four-phase protocol itself is broken."
                    + seed_note(seed)
                )
        dut._log.info("%s: %d words intact", label, len(col.words))


@cocotb.test()
async def test_source_may_scribble_the_bus_once_the_word_is_accepted(dut):
    """A word in flight is immune to whatever the source does to ``src_data``.

    The protocol says the source may change data only after it has seen the ack
    (rtl/common/cdc_handshake.sv:16).  The module makes that safe by latching
    into ``src_data_q`` at the accepting edge, and it is ``src_data_q`` — not
    ``src_data`` — that crosses.  This test proves the latch: after each accept
    the source drops ``src_valid`` (legal) and then drives a different value
    onto ``src_data`` on every single cycle until the transfer completes.

    If ``dst_data`` ever showed the scribble, the crossing would be sampling a
    bus that is moving, which is precisely the unconstrained-``set_false_path``
    failure the header forbids.

    The illegal direction — moving ``src_data_q`` while ``req_q`` is asserted —
    is covered by the RTL's own assertion at rtl/common/cdc_handshake.sv:214,
    which a testbench cannot provoke through the ports.
    """
    rng, seed = seeded_rng(dut, "cdc_handshake.scribble")
    w = dut_width(dut)
    mask = (1 << w) - 1
    col = await bringup(dut, BASE_PS, BASE_PS + 2)

    sent = []
    for i in range(48):
        value = rng.getrandbits(w)
        await send_word(dut, value)
        sent.append(value)
        # src_valid is low: the source is free to do anything to src_data.
        for _ in range(14):
            dut.src_data.value = rng.getrandbits(w) ^ mask
            await RisingEdge(dut.src_clk)
        dut.src_data.value = 0
        for _ in range(6):
            await RisingEdge(dut.src_clk)

    await Timer(40 * BASE_PS, units="ps")
    col.stop()
    assert col.words == sent, (
        f"dst_data was affected by src_data changing AFTER the word was "
        f"accepted.\n"
        f"  sent     : {[hex(v) for v in sent[:4]]} ...\n"
        f"  received : {[hex(v) for v in col.words[:4]]} ...\n"
        f"  The source hold register src_data_q is the entire justification for "
        f"not synchronizing the bus (rtl/common/cdc_handshake.sv:35). If it is "
        f"not holding, every wide crossing in the control plane is unsafe."
        + seed_note(seed)
    )
    dut._log.info("%d words survived a scribbled source bus", len(sent))


# =============================================================================
# 2. Latency and throughput — the numbers the control plane budgets against
# =============================================================================

@cocotb.test()
async def test_round_trip_latency_matches_the_header(dut):
    """src_ready returns 9-11 source cycles after acceptance, at every phase.

    ``rtl/common/cdc_handshake.sv:24`` quotes "~9-11 src cycles until src_ready
    returns" at SYNC_STAGES=2, "~60-70 ns per transfer", "roughly one word per
    10 cycles".  That figure is what sizes the host's parameter-load time: a
    64-entry risk-limit table at ~64 ns per word is ~4 us, and the arming
    sequence budget in the operations runbook depends on it.

    Both halves are measured over a full sweep of destination phase:
      * source-side: accept -> ``src_ready`` again, in source cycles;
      * destination-side: accept -> ``dst_valid``, in destination cycles.

    ⚠️ The destination-side figure is asserted against the STRUCTURAL bound
    ``[SYNC_STAGES+1, 5]``.  The structural minimum is SYNC_STAGES cycles for
    the request synchronizer plus one for the registered strobe; the header's
    prose says "~5 dst cycles to dst_valid", which is the loose upper end. The
    measured value is logged on every run so a change is visible even when it
    stays inside the window.
    """
    stages = sync_stages(dut)
    w = dut_width(dut)
    src_seen: list[int] = []
    dst_seen: list[int] = []

    for trial in range(24):
        phase = (BASE_PS * trial) // 24 + 1
        col = await bringup(dut, BASE_PS, BASE_PS, dst_phase=phase)
        assert await offer(dut, (0xC0FFEE + trial) & ((1 << w) - 1)), (
            "first transfer after reset was not accepted — src_ready should be "
            "high out of reset"
        )
        # Stamped AFTER the accepting edge: `offer` returns at that edge, and a
        # source cycle can contain a destination edge, so stamping before the
        # call would make the measurement one cycle long.
        base_cyc = col._cyc
        dut.src_valid.value = 0

        n = 0
        for _ in range(64):
            await FallingEdge(dut.src_clk)
            n += 1
            if int(dut.src_ready.value):
                break
        else:
            raise AssertionError("src_ready never returned within 64 cycles")
        src_seen.append(n)

        await Timer(20 * BASE_PS, units="ps")
        col.stop()
        assert col.cycles, "no dst_valid observed"
        dst_seen.append(col.cycles[0] - base_cyc)

    assert min(src_seen) >= 9 and max(src_seen) <= 11, (
        f"round-trip src_ready window is [{min(src_seen)}, {max(src_seen)}] "
        f"source cycles; the header (rtl/common/cdc_handshake.sv:24) promises "
        f"9-11 at SYNC_STAGES={stages}.\n  samples: {src_seen}\n"
        f"  This number is the sustained control-plane write rate. If it grew, "
        f"every host parameter load got slower and the header must say so."
    )
    assert min(dst_seen) >= stages + 1 and max(dst_seen) <= 5, (
        f"accept -> dst_valid window is [{min(dst_seen)}, {max(dst_seen)}] "
        f"destination cycles; contract is [{stages + 1}, 5].\n"
        f"  samples: {dst_seen}"
    )
    dut._log.info(
        "SYNC_STAGES=%d: src_ready returns in %s src cycles; dst_valid in %s "
        "dst cycles (header prose says '~5')",
        stages, sorted(set(src_seen)), sorted(set(dst_seen)),
    )


@cocotb.test()
async def test_back_to_back_transfers_never_deadlock(dut):
    """``src_valid`` tied high for hundreds of transfers, at every ratio.

    The hostile pattern for a four-phase handshake: the source never idles, so
    every phase transition happens at the earliest possible moment and any
    missing "wait for the previous transfer to fully retire" shows up as either
    a stall that never ends or a transfer that overtakes its predecessor.

    Asserted: every word arrives in order, the transfer period is stable
    (~10 source cycles), and no single transfer ever takes more than a bounded
    number of cycles.  A jittery period here is not a correctness bug but it is
    a symptom — it means the phase machine is racing.
    """
    rng, seed = seeded_rng(dut, "cdc_handshake.b2b")
    w = dut_width(dut)
    n = int(os.environ.get("TRANSFERS", "150"))

    for label, src_ps, dst_ps in (
        ("1:1  equal", BASE_PS, BASE_PS),
        ("1:1  near-equal", BASE_PS, BASE_PS + 2),
        ("pcie->core", PCIE_PS, BASE_PS),
        ("1:8  src slow", BASE_PS * 8, BASE_PS),
        ("8:1  src fast", BASE_PS, BASE_PS * 8),
    ):
        col = await bringup(dut, src_ps, dst_ps,
                            dst_phase=rng.randrange(0, dst_ps))
        sent: list[int] = []
        gaps: list[int] = []
        cycles_since = 0
        guard = 0
        word = 0
        # ⚠️ Do NOT pre-assert src_valid here. `src_ready` is high out of reset,
        # so raising src_valid before the first `offer()` has driven src_data
        # hands the DUT a transfer carrying whatever was left on the bus — a
        # phantom risk-limit write of 0x0 that then shows up as an unexplained
        # extra word at index 0. `offer()` owns src_valid.
        while word < n:
            guard += 1
            assert guard < n * 200 + 2000, (
                f"[{label}] DEADLOCK: {word}/{n} transfers after {guard} source "
                f"cycles. src_ready never came back." + seed_note(seed)
            )
            value = ((word << 8) ^ 0xA5A5_A5A5) & ((1 << w) - 1)
            cycles_since += 1
            if await offer(dut, value):
                sent.append(value)
                if word:
                    gaps.append(cycles_since)
                cycles_since = 0
                word += 1
        dut.src_valid.value = 0

        await Timer(40 * max(src_ps, dst_ps), units="ps")
        col.stop()
        col.assert_single_cycle(f"[{label}]")

        assert col.words == sent, (
            f"[{label}] back-to-back stream lost, duplicated or reordered a "
            f"word: sent {len(sent)}, received {len(col.words)}; first "
            f"divergence at index "
            f"{next((i for i, (a, b) in enumerate(zip(col.words, sent)) if a != b), 'n/a')}"
            + seed_note(seed)
        )
        assert gaps, f"[{label}] no inter-transfer gaps recorded"
        dut._log.info(
            "%s: %d transfers, period min/max = %d/%d source cycles",
            label, len(sent), min(gaps), max(gaps),
        )

    # At equal frequency the header's "one word per 10 cycles" is checkable.
    col = await bringup(dut, BASE_PS, BASE_PS)
    gaps = []
    cycles_since = 0
    got = 0
    while got < 40:
        cycles_since += 1
        if await offer(dut, got & ((1 << w) - 1)):
            if got:
                gaps.append(cycles_since)
            cycles_since = 0
            got += 1
    dut.src_valid.value = 0
    col.stop()
    assert 9 <= min(gaps) and max(gaps) <= 13, (
        f"sustained transfer period at equal frequency is "
        f"[{min(gaps)}, {max(gaps)}] source cycles; the header "
        f"(rtl/common/cdc_handshake.sv:26) says 'roughly one word per 10 "
        f"cycles'.\n  gaps: {gaps}"
    )
    dut._log.info("sustained period: %d-%d source cycles per word",
                  min(gaps), max(gaps))


# =============================================================================
# 3. Reset behaviour
# =============================================================================

@cocotb.test()
async def test_channel_is_idle_and_silent_out_of_reset(dut):
    """``src_ready`` high, ``dst_valid`` silent, no phantom first transfer.

    A control-plane channel that emits one spurious ``dst_valid`` at power-up
    installs whatever happens to be on the bus as a risk limit, before the host
    has written anything.  CLAUDE.md §5.4: a bitstream reload must never come up
    armed, and "armed with a garbage limit" is the same failure.
    """
    col = await bringup(dut, BASE_PS, BASE_PS + 2)
    await FallingEdge(dut.src_clk)
    assert int(dut.src_ready.value) == 1, (
        "src_ready is low immediately out of reset — the channel came up with a "
        "phantom transfer in flight"
    )
    await Timer(2000 * BASE_PS, units="ps")
    col.stop()
    assert not col.words, (
        f"{len(col.words)} phantom dst_valid strobes with src_valid tied low "
        f"for 2000 cycles: {[hex(v) for v in col.words[:4]]}\n"
        f"  Each one is an unrequested control-plane write."
    )


@cocotb.test()
async def test_destination_only_reset_does_not_wedge_the_channel(dut):
    """⚠️ Caller obligation probe: resetting one domain only.

    ``rtl/common/cdc_handshake.sv:48`` — "BOTH RESETS MUST DERIVE FROM THE SAME
    ROOT RESET ... Resetting one side only leaves req/ack out of phase and the
    channel deadlocks (src_ready never returns)."

    This test asserts the SAFETY half of that claim in the direction that can be
    asserted without depending on exact phase: after a destination-only reset
    pulse the channel must still be usable — ``src_ready`` must come back and
    subsequent words must still arrive intact.  A permanently wedged control
    plane means the host can no longer lower a risk limit, which is the one
    operation that must always work.

    It also RECORDS whether the destination emitted an extra ``dst_valid``
    during the disturbance and logs it loudly, because a duplicated
    control-plane write is a distinct hazard from a deadlock and the two want
    different mitigations.
    """
    w = dut_width(dut)
    duplicates = 0
    trials = 8

    for delay in range(trials):
        col = await bringup(dut, BASE_PS, BASE_PS)
        assert await offer(dut, (0xDEAD_0000 + delay) & ((1 << w) - 1)), (
            "transfer not accepted out of reset")
        dut.src_valid.value = 0
        for _ in range(delay + 1):
            await RisingEdge(dut.src_clk)

        dut.dst_rst.value = 1
        await Timer(3 * BASE_PS, units="ps")
        dut.dst_rst.value = 0
        await Timer(40 * BASE_PS, units="ps")

        # The channel must recover.
        recovered = False
        for _ in range(200):
            await FallingEdge(dut.src_clk)
            if int(dut.src_ready.value):
                recovered = True
                break
        assert recovered, (
            f"⚠️ DEADLOCK after a destination-only reset (delay={delay}): "
            f"src_ready never returned within 200 source cycles.\n"
            f"  The host can no longer write a risk limit. Both resets must "
            f"come from one root (clk_rst_gen provides exactly that)."
        )

        n_before = len(col.words)
        marker = (0xBEEF_0000 + delay) & ((1 << w) - 1)
        await send_word(dut, marker)
        await Timer(40 * BASE_PS, units="ps")
        col.stop()

        after = col.words[n_before:]
        assert marker in after, (
            f"after a destination-only reset the next real transfer "
            f"(0x{marker:x}) never arrived; got {[hex(v) for v in after]}"
        )
        if len(after) > 1 or n_before != 1:
            duplicates += 1
            dut._log.warning(
                "destination-only reset (delay=%d) produced %d dst_valid "
                "strobes for 2 source transfers: %s",
                delay, len(col.words), [hex(v) for v in col.words],
            )

    dut._log.info(
        "destination-only reset: channel recovered in all %d trials; "
        "%d trial(s) showed an extra/duplicated control-plane write",
        trials, duplicates,
    )


if __name__ == "__main__":  # pragma: no cover
    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        from cocotb.runner import get_runner

    runner = get_runner(os.environ.get("SIM", "verilator"))
    for w, stages in ((32, 2), (64, 2), (64, 3)):
        runner.build(
            verilog_sources=sim_sources(
                "rtl/common/cdc_sync_bit.sv", "rtl/common/cdc_handshake.sv"),
            hdl_toplevel="cdc_handshake",
            parameters={"W": w, "SYNC_STAGES": stages},
            build_args=["-Wno-fatal", "--timescale-override", "1ns/1ps"],
            always=True,
        )
        runner.test(hdl_toplevel="cdc_handshake", test_module="test_cdc_handshake")
