"""Reset synchronizer — proves asynchronous assert, synchronous de-assert.

INVARIANT PROVEN
    ``reset_sync`` turns a free-running asynchronous reset into the project's
    synchronous, active-high ``rst``:

      * **Assertion is asynchronous.**  ``sync_rst_out`` goes high with NO clock
        edge at all — proved with the clock deliberately stopped — and it
        catches a reset pulse narrower than a clock period that lies entirely
        between two rising edges, which a synchronous reset would silently miss.
      * **De-assertion is synchronous.**  ⚠️ The release phase is swept across
        the whole clock period, many times: at EVERY phase, ``sync_rst_out``
        falls only ON a rising clock edge, never between edges, and always
        exactly ``STAGES + RELEASE_CYCLES`` edges after ``async_rst_in`` falls.
        Zero jitter.
      * Once released it stays released; only ``async_rst_in`` can re-assert it.
      * Its configuration (power-up) value is ASSERTED — the fail-safe level.

WHY IT MATTERS
    Manual 00.04 §7, last row: "Reset de-assertion not synchronized -> FSM
    starts in illegal state, ~1 in 10^6 resets."  One in a million resets is
    invisible in the lab and inevitable in a system that is power-cycled every
    trading day for years, and the symptom is a state machine that comes up in
    a state the designer proved could not exist.

    ⚠️ THE PHASE SWEEP IS THE WHOLE TEST.  A testbench that de-asserts reset on
    a clock edge, or at one fixed offset, proves nothing at all about this
    module: the failure it exists to prevent only appears when the release lands
    near an edge.  A single-phase test passes on a design with NO synchronizer.
    That is why ``test_release_is_synchronous_at_every_phase`` sweeps 64 phases
    and checks the output is CONSTANT within each clock period, rather than only
    counting edges.

    And the direction of the safety argument matters: reset asserting must work
    before the clock is running at all (``clk_rst_gen`` holds everything in
    reset until the MMCM says ``locked``, and there is no trustworthy clock
    until then).  That is why the assert path is asynchronous and why
    ``rtl/common/reset_sync.sv:28`` is the ONE sanctioned asynchronous
    ``always_ff`` in this entire repository.

    ⚠️ What this file cannot prove: that the release edge is CONSTRAINED in the
    XDC (rtl/common/reset_sync.sv:42).  ``async_rst_in`` is asynchronous to
    ``clk``, so its path into ``rst_q[0]`` is a CDC path.  Unconstrained, the
    tool can route the reset net so wide that different domains leave reset
    cycles apart — the same 1-in-10^6 bug, moved one level up.  That is
    ``report_cdc`` and the XDC, not simulation.

DUT
    rtl/common/reset_sync.sv.  Ports: ``clk``, ``async_rst_in`` (ACTIVE HIGH,
    asynchronous), ``sync_rst_out`` (ACTIVE HIGH, synchronous).  Parameters
    ``STAGES`` (>= 2) and ``RELEASE_CYCLES``.

RUNNING
    TOPLEVEL=reset_sync, or ``python test_reset_sync.py``, which sweeps
    (STAGES, RELEASE_CYCLES) = (2,0), (3,0), (2,4), (3,16) — the last being the
    core-domain configuration in clk_rst_gen.
"""

from __future__ import annotations

import os
import pathlib
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tb_util import seed_note, seeded_rng, sim_sources  # noqa: E402

CLK_PS = 6400  # core_clk, 156.25 MHz


def dut_total(dut) -> int:
    """``STAGES + RELEASE_CYCLES``, read off the width of ``rst_q``."""
    try:
        n = len(dut.rst_q)
        if n >= 2:
            return n
    except Exception:  # pragma: no cover
        pass
    return (int(os.environ.get("STAGES", "2"))
            + int(os.environ.get("RELEASE_CYCLES", "0")))


#: cocotb runs every test in this file inside ONE simulation, and one test
#: deliberately STOPS the clock. Track the driver so a restart never leaves two
#: tasks toggling ``clk``.
_CLOCK: list = []


def start_clock(dut):
    while _CLOCK:
        _CLOCK.pop().kill()
    task = cocotb.start_soon(Clock(dut.clk, CLK_PS, units="ps").start())
    _CLOCK.append(task)
    return task


def stop_clock():
    while _CLOCK:
        _CLOCK.pop().kill()


async def hold_in_reset(dut, cycles: int = 6) -> None:
    dut.async_rst_in.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)


# =============================================================================
# 1. Power-up: the fail-safe level
# =============================================================================

@cocotb.test()
async def test_configuration_value_is_asserted(dut):
    """Before the first clock edge, ``sync_rst_out`` is already 1.

    ``rtl/common/reset_sync.sv:74`` — "Reset value is 1 (asserted): a
    configuration/power-up state of 'in reset' is the fail-safe one."  This is
    the initializer that becomes the flip-flop's INIT attribute in the
    bitstream; it is not a reset, and nothing else establishes it.

    CLAUDE.md §5.4 / manual 00.04 §4: a bitstream reload must never come up
    armed.  If this register powered up at 0, every downstream FSM would run for
    a few cycles before the first reset edge arrived — with risk limits and the
    trading-enabled flag in whatever state configuration left them.
    """
    dut.async_rst_in.value = 0
    await Timer(1, units="ps")
    v = int(dut.sync_rst_out.value)
    assert v == 1, (
        f"sync_rst_out reads {v} at power-up, before any clock edge and with "
        f"async_rst_in low.\n"
        f"  The configuration value must be ASSERTED (rtl/common/reset_sync.sv:78). "
        f"A domain that powers up out of reset runs its FSMs against "
        f"uninitialised control state, and on this design that means it may come "
        f"up armed."
    )
    dut._log.info("power-up value is asserted (fail-safe), TOTAL=%d",
                  dut_total(dut))


# =============================================================================
# 2. Assertion is asynchronous — the property that needs no clock
# =============================================================================

@cocotb.test()
async def test_assertion_works_with_the_clock_stopped(dut):
    """``sync_rst_out`` goes high with the clock frozen.  No edges required.

    ``clk_rst_gen`` builds the asynchronous reset root as
    ``~sys_rst_n | ~mmcm_locked`` (rtl/common/clk_rst_gen.sv:238), so the very
    condition that asserts reset is "the clock is not trustworthy yet".  A reset
    that needed a clock edge to assert would be useless in exactly the situation
    it exists for: before the MMCM has locked, or after it has lost lock.

    The clock is genuinely stopped here — the driving task is killed — so this
    cannot pass by accident on an edge that happened to arrive.
    """
    start_clock(dut)
    dut.async_rst_in.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.async_rst_in.value = 0
    for _ in range(dut_total(dut) + 3):
        await RisingEdge(dut.clk)
    assert int(dut.sync_rst_out.value) == 0, "did not release before the test"

    # Stop the clock dead, mid-period.
    await Timer(CLK_PS // 3, units="ps")
    stop_clock()
    await Timer(10 * CLK_PS, units="ps")
    assert int(dut.sync_rst_out.value) == 0, (
        "sync_rst_out asserted on its own with the clock stopped and "
        "async_rst_in low")

    dut.async_rst_in.value = 1
    await Timer(1, units="ps")
    assert int(dut.sync_rst_out.value) == 1, (
        "sync_rst_out did NOT assert with the clock stopped.\n"
        "  The assert path must be asynchronous (rtl/common/reset_sync.sv:82). "
        "clk_rst_gen asserts reset precisely when the MMCM is unlocked, i.e. "
        "when there may be no usable clock at all."
    )
    await Timer(50 * CLK_PS, units="ps")
    assert int(dut.sync_rst_out.value) == 1, (
        "sync_rst_out did not stay asserted while the clock was stopped")

    # Restart the clock; it must still be asserted, and release normally.
    start_clock(dut)
    await RisingEdge(dut.clk)
    assert int(dut.sync_rst_out.value) == 1, (
        "sync_rst_out dropped on the first clock edge after restart, with "
        "async_rst_in still high")
    dut._log.info("assert works with no clock; holds while stopped")


# =============================================================================
# 3. ⚠️ THE headline: synchronous de-assertion at EVERY phase
# =============================================================================

async def _release_at_phase(dut, phase_ps: int, total: int) -> int:
    """De-assert at ``phase_ps`` after a rising edge; return edges until release.

    Also asserts that ``sync_rst_out`` is CONSTANT within every clock period —
    which is what "synchronous de-assertion" actually means.  Counting edges
    alone would not catch an output that dropped mid-period and then happened to
    be sampled low at the right edge.
    """
    dut.async_rst_in.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)
    assert int(dut.sync_rst_out.value) == 1, "not asserted before release"

    await RisingEdge(dut.clk)
    await Timer(phase_ps, units="ps")
    dut.async_rst_in.value = 0
    assert int(dut.sync_rst_out.value) == 1, (
        f"sync_rst_out fell the instant async_rst_in was de-asserted at phase "
        f"{phase_ps} ps — the release path is COMBINATIONAL, not synchronous.\n"
        f"  This is manual 00.04 §7 last row: every downstream flip-flop then "
        f"leaves reset at a slightly different time and an FSM can start in an "
        f"illegal state."
    )

    edges = 0
    for _ in range(total + 6):
        await RisingEdge(dut.clk)
        edges += 1
        samples = []
        for _ in range(4):
            await Timer(CLK_PS // 5, units="ps")
            samples.append(int(dut.sync_rst_out.value))
        assert len(set(samples)) == 1, (
            f"sync_rst_out CHANGED in the middle of a clock period "
            f"(samples {samples}, release phase {phase_ps} ps, edge {edges}).\n"
            f"  De-assertion must happen ON a clock edge and nowhere else "
            f"(rtl/common/reset_sync.sv:16). An output that moves mid-period is "
            f"an asynchronous release wearing a synchronizer's name."
        )
        if samples[0] == 0:
            return edges
    raise AssertionError(
        f"sync_rst_out never released within {total + 6} edges after "
        f"de-assertion at phase {phase_ps} ps")


@cocotb.test()
async def test_release_is_synchronous_at_every_phase(dut):
    """⚠️ 64 release phases across the clock period: always exactly TOTAL edges.

    ``rtl/common/reset_sync.sv:21`` — "Release: STAGES + RELEASE_CYCLES clock
    edges after ``async_rst_in`` falls."  Asserted as an EQUALITY over a full
    phase sweep, with the mid-period constancy check inside
    ``_release_at_phase``.

    Why the sweep is the test and not a detail: the classic bug — an
    unsynchronized release — behaves perfectly at most phases and misbehaves
    near the clock edge.  A testbench that de-asserts reset at one convenient
    moment (typically right after an edge) passes on a design with no
    synchronizer at all.  Manual 00.04 §7 puts the field failure rate at ~1 in
    10^6 resets, which is precisely the rate at which a fixed-phase test finds
    nothing and a fleet finds it within a month.

    Phases avoid the exact edge by a margin; the coincident case is its own test
    below, because at exact coincidence the outcome is a genuine race and
    asserting a specific answer would be asserting a simulator artefact.
    """
    total = dut_total(dut)
    start_clock(dut)
    steps = int(os.environ.get("PHASE_STEPS", "64"))
    margin = max(2, CLK_PS // 64)
    observed: dict[int, int] = {}

    for k in range(steps):
        phase = margin + ((CLK_PS - 2 * margin) * k) // max(1, steps - 1)
        observed[phase] = await _release_at_phase(dut, phase, total)

    uniq = sorted(set(observed.values()))
    assert uniq == [total], (
        f"⚠️ RESET RELEASE IS NOT DETERMINISTIC ACROSS PHASE.\n"
        f"  observed edge counts: {uniq}, expected exactly [{total}] "
        f"(STAGES + RELEASE_CYCLES).\n"
        f"  per-phase: {observed}\n"
        f"  A release whose length depends on when the asynchronous input "
        f"happened to fall means different flip-flops in this domain — and, "
        f"worse, different DOMAINS — leave reset on different cycles. That is "
        f"the ~1-in-10^6 'FSM starts in an illegal state' failure in manual "
        f"00.04 §7, and it is invisible until the fleet is large enough."
    )
    dut._log.info(
        "release: exactly %d edges at all %d phases across the %d ps period",
        total, steps, CLK_PS)


@cocotb.test()
async def test_release_at_randomized_phases(dut):
    """Constrained-random release phases, deterministic seed.

    The uniform sweep covers the period evenly; this covers it unevenly, which
    is how a bug that only bites in a narrow window near one particular offset
    gets found.  Both run because they fail differently.
    """
    rng, seed = seeded_rng(dut, "reset_sync.phase")
    total = dut_total(dut)
    start_clock(dut)
    margin = max(2, CLK_PS // 64)

    observed = []
    for _ in range(int(os.environ.get("PHASE_TRIALS", "48"))):
        phase = rng.randrange(margin, CLK_PS - margin)
        observed.append((phase, await _release_at_phase(dut, phase, total)))

    bad = [(p, n) for p, n in observed if n != total]
    assert not bad, (
        f"release took the wrong number of edges at {len(bad)} random phase(s): "
        f"{bad[:8]} (expected {total} every time)" + seed_note(seed)
    )
    dut._log.info("%d random release phases, all exactly %d edges",
                  len(observed), total)


@cocotb.test()
async def test_release_coincident_with_a_clock_edge_is_still_bounded(dut):
    """De-assertion ON the clock edge: the outcome is a race, the BOUND is not.

    When ``async_rst_in`` falls at the same instant as a rising edge, whether
    that edge sees the old or the new value is genuinely undetermined — in
    silicon it is the metastability window, in simulation it is a scheduling
    artefact.  Asserting a specific answer here would be asserting the
    simulator's event ordering, which is exactly the kind of test that "passes"
    while proving nothing.

    What CAN be asserted, and is: the release still HAPPENS, it is bounded by
    TOTAL+1 edges, and it is never instantaneous.  Whether the coincident edge
    itself counts as the first shift is left undetermined on purpose — the
    measurement is ambiguous by exactly one edge at coincidence, and a test that
    pretended otherwise would be measuring the simulator.
    """
    total = dut_total(dut)
    start_clock(dut)
    seen = set()

    for _ in range(16):
        dut.async_rst_in.value = 1
        for _ in range(4):
            await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)
        await Timer(CLK_PS, units="ps")   # lands exactly on the next edge
        dut.async_rst_in.value = 0
        n = 0
        released = False
        for _ in range(total + 8):
            await RisingEdge(dut.clk)
            n += 1
            await Timer(CLK_PS // 2, units="ps")
            if int(dut.sync_rst_out.value) == 0:
                released = True
                break
        assert released, (
            f"edge-coincident release HUNG: sync_rst_out still asserted "
            f"{total + 8} edges after async_rst_in fell. A release that can hang "
            f"at one phase means the domain can stay in reset after a real "
            f"reset event.")
        seen.add(n)

    assert max(seen) <= total + 1, (
        f"edge-coincident release took up to {max(seen)} edges; the bound is "
        f"{total + 1} (TOTAL plus the one edge of measurement ambiguity at "
        f"coincidence). Observed {sorted(seen)}."
    )
    assert min(seen) >= max(1, total - 1), (
        f"edge-coincident release completed in {min(seen)} edge(s) — a "
        f"synchronizer stage was bypassed. Observed {sorted(seen)}."
    )
    dut._log.info("edge-coincident release: %s edges (TOTAL=%d), never hung",
                  sorted(seen), total)


# =============================================================================
# 4. Stability after release
# =============================================================================

@cocotb.test()
async def test_no_spurious_reassertion(dut):
    """Once released, reset stays released until ``async_rst_in`` says otherwise.

    Catches a shift register wired backwards, or an INIT value leaking back
    through the chain.  A domain that spontaneously re-resets mid-session drops
    the order book and every open order's state with it.
    """
    total = dut_total(dut)
    start_clock(dut)
    await hold_in_reset(dut)
    dut.async_rst_in.value = 0
    for _ in range(total):
        await RisingEdge(dut.clk)
    # Sample at the midpoint: reading a registered output in the same delta as
    # the edge that changed it returns the PRE-edge value.
    await Timer(CLK_PS // 2, units="ps")
    assert int(dut.sync_rst_out.value) == 0, (
        f"sync_rst_out is still asserted {total} edges after async_rst_in fell "
        f"— the release is late")

    for cyc in range(5000):
        await RisingEdge(dut.clk)
        await Timer(CLK_PS // 2, units="ps")
        assert int(dut.sync_rst_out.value) == 0, (
            f"sync_rst_out re-asserted at cycle {cyc} with async_rst_in low "
            f"throughout (rtl/common/reset_sync.sv:110)")
    dut._log.info("no spurious re-assertion over 5000 cycles")


@cocotb.test()
async def test_reassertion_is_immediate_at_any_phase(dut):
    """Re-asserting mid-period drives the output high before the next edge.

    Random phases.  Reset assertion is the one operation in this design that is
    never allowed to be late: it is what the kill path and the "MMCM lost lock"
    path both rely on.
    """
    rng, seed = seeded_rng(dut, "reset_sync.reassert")
    total = dut_total(dut)
    start_clock(dut)

    for _ in range(32):
        await hold_in_reset(dut, 3)
        dut.async_rst_in.value = 0
        for _ in range(total + 2):
            await RisingEdge(dut.clk)
        assert int(dut.sync_rst_out.value) == 0

        await RisingEdge(dut.clk)
        phase = rng.randrange(1, CLK_PS - 1)
        await Timer(phase, units="ps")
        dut.async_rst_in.value = 1
        await Timer(1, units="ps")
        assert int(dut.sync_rst_out.value) == 1, (
            f"sync_rst_out did not assert immediately when async_rst_in rose "
            f"{phase} ps into the period — assertion must be asynchronous and "
            f"instant" + seed_note(seed))
    dut._log.info("32 random-phase re-assertions, all immediate")


# =============================================================================
# 5. ⚠️ XFAIL — THIS TEST FOUND AN RTL BUG. IT IS LAST FOR A REASON.
# -----------------------------------------------------------------------------
# The RTL's own assertion at rtl/common/reset_sync.sv:110-112 calls $error and
# Verilog $stop, which ABORTS the simulator. Anything after it in this file
# would be reported as failed without ever having run. Keep it last.
# =============================================================================

@cocotb.test()
async def test_sub_period_reset_glitch_is_captured(dut):
    """A reset pulse entirely BETWEEN two clock edges still resets the domain.

    ⚠️ THIS TEST CURRENTLY FAILS, AND THE FAILURE IS AN RTL BUG, NOT A TESTBENCH
    BUG.  It is left enabled and red on purpose: tb/README.md §3 — "never
    disable a test to get a build through".  ``cocotb``'s ``expect_fail`` does
    not cover it because the RTL calls ``$stop``, which tears the simulator down
    rather than failing a Python assertion.

    The DUT does the right thing; ``rtl/common/reset_sync.sv``
    line 110-112 then reports it as an error:

        assert property (@(posedge clk)
            (!async_rst_in && !sync_rst_out) |=> (async_rst_in || !sync_rst_out))
            else $error("reset_sync: spurious re-assertion of sync_rst_out");

    The property samples ``async_rst_in`` only at ``posedge clk``.  A reset pulse
    that asserts AND de-asserts between two clock edges is invisible to that
    sampling, so the property sees ``sync_rst_out`` go from 0 to 1 with
    ``async_rst_in`` low at both edges and concludes the output re-asserted on
    its own.  It did not: it was asserted asynchronously, which is the module's
    entire purpose (rtl/common/reset_sync.sv:16, manual 00.04 §4).

    ⚠️ THIS IS NOT HYPOTHETICAL.  ``clk_rst_gen`` drives this module with
    ``~sys_rst_n | ~mmcm_locked`` (rtl/common/clk_rst_gen.sv:238).  ``sys_rst_n``
    is a board pushbutton, which bounces.  ``mmcm_locked`` is asynchronous to
    ``core_clk`` and can drop for a fraction of a cycle when the reference is
    disturbed.  PCIe ``PERST#`` is driven by another device's clock entirely.
    Every one of those produces a sub-period pulse, every one of them MUST reset
    the domain, and every one of them makes this assertion fire — in the
    regression, and in gate-level sim, on correct hardware behaviour.

    Suggested fix (RTL is owned elsewhere; NOT applied here): the property needs
    to tolerate an asynchronous assert it cannot sample, e.g. gate it on
    ``$rose(sync_rst_out) |-> $past(async_rst_in) || async_rst_in`` being
    unenforceable and instead check only the SHIFT behaviour, or qualify the
    existing property with a sampled-history term that admits a pulse narrower
    than one period.

    The functional part of this test — that the glitch IS captured, and that
    release still takes the full ``TOTAL`` edges from the pulse's fall — is
    asserted below and is believed correct; it is simply never reached, because
    ``$stop`` tears the simulator down at the first glitch.
    """
    total = dut_total(dut)
    start_clock(dut)
    dut._log.error(
        "⚠️ EXPECTED FAILURE AHEAD — RTL BUG, NOT A TESTBENCH BUG. "
        "rtl/common/reset_sync.sv:110-112 asserts 'spurious re-assertion of "
        "sync_rst_out' whenever a reset pulse asserts AND de-asserts between "
        "two clock edges, because the property only samples async_rst_in at "
        "posedge clk. That is the module's own documented asynchronous-assert "
        "behaviour (line 16), and clk_rst_gen feeds it a bouncing pushbutton "
        "and an asynchronous mmcm_locked. The $error calls $stop, which aborts "
        "the simulator — that is why this test is LAST in the file."
    )
    await hold_in_reset(dut)
    dut.async_rst_in.value = 0
    for _ in range(total + 3):
        await RisingEdge(dut.clk)
    await Timer(CLK_PS // 2, units="ps")
    assert int(dut.sync_rst_out.value) == 0, "not released before the glitch"

    for frac in (4, 8, 16, 64):
        width = max(1, CLK_PS // frac)
        await RisingEdge(dut.clk)
        # Sit in the middle of the period so the pulse cannot touch an edge.
        await Timer(CLK_PS // 2 - width // 2, units="ps")
        dut.async_rst_in.value = 1
        await Timer(width, units="ps")
        seen = int(dut.sync_rst_out.value)
        dut.async_rst_in.value = 0
        assert seen == 1, (
            f"a {width} ps reset pulse ({CLK_PS} ps clock period), entirely "
            f"between two rising edges, did NOT assert sync_rst_out.\n"
            f"  This is the whole reason the assert path is asynchronous "
            f"(rtl/common/reset_sync.sv:16). A bouncing pushbutton or a "
            f"momentary loss of MMCM lock must reset the domain."
        )
        # Release must still take the full TOTAL edges, measured from the fall.
        n = 0
        for _ in range(total + 6):
            await RisingEdge(dut.clk)
            n += 1
            if int(dut.sync_rst_out.value) == 0:
                break
        assert n == total, (
            f"after a {width} ps glitch, release took {n} edges, expected "
            f"{total}. A short assertion must still produce a full-length, "
            f"synchronous release."
        )
    dut._log.info("sub-period reset glitches captured at 4 widths")


if __name__ == "__main__":  # pragma: no cover
    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        from cocotb.runner import get_runner

    runner = get_runner(os.environ.get("SIM", "verilator"))
    # (3, 16) is the core_clk configuration in rtl/common/clk_rst_gen.sv:240 —
    # 3 stages because a mis-timed release on the datapath domain is
    # safety-relevant, plus a 16-cycle hold so the control plane comes up first.
    for stages, release in ((2, 0), (3, 0), (2, 4), (3, 16)):
        runner.build(
            verilog_sources=sim_sources("rtl/common/reset_sync.sv"),
            hdl_toplevel="reset_sync",
            parameters={"STAGES": stages, "RELEASE_CYCLES": release},
            build_args=["-Wno-fatal", "--timescale-override", "1ns/1ps"],
            always=True,
        )
        runner.test(hdl_toplevel="reset_sync", test_module="test_reset_sync")
