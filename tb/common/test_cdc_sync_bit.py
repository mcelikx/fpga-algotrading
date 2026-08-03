"""Level synchronizer — proves the contract, INCLUDING what it deliberately drops.

INVARIANT PROVEN
    ``cdc_sync_bit`` is a pure ``STAGES``-deep delay of the sampled source level
    in the destination domain:

      * a source level that is stable for >= 2 destination periods ALWAYS
        arrives, at EVERY phase relationship, with EXACTLY ``STAGES`` cycles of
        destination-domain latency and no jitter;
      * a source level narrower than one destination period is SILENTLY LOST at
        some phases — this is the documented limitation, and it is pinned here
        as a positive assertion so no caller can later claim otherwise;
      * the chain never invents a transition the source did not make, and it
        self-flushes from its configuration value in ``STAGES`` cycles with no
        reset.

WHY IT MATTERS
    This primitive carries the external kill input, the host "trading enabled"
    bit, and link-up status into ``core_clk``.  Two failure modes, both of which
    reach production because neither STA nor a single-clock-ratio simulation
    sees them:

      * **A caller uses it for a pulse.**  ``rtl/common/cdc_sync_bit.sv:34``
        warns that a single-cycle pulse into a slower domain is dropped.  A
        dropped credit return or a dropped "kill asserted" strobe is not a
        degraded mode, it is a wrong one.  ``test_sub_period_source_is_missed``
        exists so that the limitation is a *tested fact* rather than a comment
        that a future reader may talk themselves out of.
      * **A caller uses it for a bus.**  Per-bit chains resolve independently
        and produce a value that never existed in the source domain — manual
        00.04 §2, "a price that was never quoted".  Nothing in simulation can
        catch that (RTL sim samples cleanly, every edge, forever), so
        ``test_source_forbids_multibit_use`` checks the RTL *text* for the
        guard-rails instead: the single-bit port, the ``ASYNC_REG`` attribute
        and the ``STAGES >= 2`` elaboration check.  A structural check is the
        only kind available here; see manuals/00-foundations/04 §6.

    ⚠️ NOTHING IN THIS FILE CAN PROVE THE DESIGN IS METASTABILITY-SAFE.  RTL
    simulation has no notion of setup/hold across domains.  What it can prove is
    the *functional* contract — latency, no invention, and the exact shape of
    the documented hole.  MTBF is proved by ``report_cdc`` plus the ASYNC_REG
    placement, never by this file.

DUT
    rtl/common/cdc_sync_bit.sv.  Ports: ``dst_clk``, ``src_bit``, ``dst_bit``.
    Parameters ``STAGES`` (>= 2) and ``INIT_VAL``.  There is NO source clock
    port and NO reset — the testbench drives ``src_bit`` on its own time base,
    which is exactly the asynchronous relationship the module has to survive.

RUNNING
    TOPLEVEL=cdc_sync_bit, or ``python test_cdc_sync_bit.py`` which builds and
    runs STAGES=2 and STAGES=3 back to back.
"""

from __future__ import annotations

import os
import pathlib
import re
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tb_util import REPO_ROOT, seed_note, seeded_rng  # noqa: E402

# Destination clock, in integer picoseconds.  Everything in the CDC suite works
# in ps: 156.25 MHz is 6400 ps exactly, and the nearly-equal-frequency cases in
# test_async_fifo.py need 1 ps of resolution to express at all.
DST_PS = 6400

RTL = REPO_ROOT / "rtl" / "common" / "cdc_sync_bit.sv"


# =============================================================================
# Helpers
# =============================================================================

#: Live clock-driver tasks, keyed by port name.  cocotb runs every test in this
#: file inside ONE simulation, so a helper that starts a clock per test would
#: leave several tasks toggling the same net and produce a garbled clock.
#: Restarting through this registry kills the previous driver first.
_CLOCKS: dict[str, object] = {}


def start_clock_ps(dut, name: str, period_ps: int, phase_ps: int = 0):
    """(Re)start a free-running clock, optionally delayed by ``phase_ps``.

    Phase control is the whole point of this suite: a CDC bug that only shows up
    at one phase relationship is still a CDC bug, and it is the kind that
    survives a week of soak testing (manual 00.04, opening note).
    """
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


def dut_stages(dut) -> int:
    """Read ``STAGES`` off the DUT instead of trusting an environment variable.

    ``sync_q`` is ``[STAGES-1:0]``, so its width IS the parameter.  A test that
    hardcodes 2 keeps passing when someone builds it with 3 and the latency
    contract silently changes.
    """
    try:
        n = len(dut.sync_q)
        if n >= 2:
            return n
    except Exception:  # pragma: no cover - simulator without internal access
        pass
    return int(os.environ.get("STAGES", "2"))


async def bringup(dut, period_ps: int = DST_PS, phase_ps: int = 0):
    dut.src_bit.value = 0
    start_clock_ps(dut, "dst_clk", period_ps, phase_ps)
    # Flush the chain: it has no reset by design and self-clears in STAGES
    # cycles (rtl/common/cdc_sync_bit.sv:43).
    for _ in range(dut_stages(dut) + 2):
        await RisingEdge(dut.dst_clk)
    return dut_stages(dut)


async def settle_level(dut, level: int, stages: int) -> None:
    """Drive ``src_bit`` and wait long enough that it must have propagated."""
    dut.src_bit.value = level
    for _ in range(stages + 2):
        await RisingEdge(dut.dst_clk)


# =============================================================================
# 0. Power-up — ⚠️ MUST BE THE FIRST TEST IN THIS FILE
# -----------------------------------------------------------------------------
# cocotb runs every test in a module inside ONE simulation, in definition order.
# The synchronizer chain has NO RESET (by design), so once any other test has
# run, `sync_q` holds whatever that test left in it and the configuration value
# is no longer observable. This test therefore has to go first, and must run
# before the clock starts.
# =============================================================================

@cocotb.test()
async def test_power_up_value_is_the_safe_level(dut):
    """The chain reads INIT_VAL until a real source value has walked through it.

    ``rtl/common/cdc_sync_bit.sv:43`` — the chain has no reset by design, and
    its power-up value is the FPGA configuration value baked into the bitstream.
    With the default INIT_VAL=0 the destination must read 0 before the first
    clock edge even with the source already high, must stay 0 for STAGES cycles,
    and must not glitch to the source value early.

    CLAUDE.md §5 rule 4 (fail-closed) is what makes this worth a test: a
    consumer that needs "kill asserted until proven otherwise" sets
    INIT_VAL=1'b1, and the whole scheme depends on the chain genuinely holding
    its configuration value rather than powering up as X or as the source.
    """
    stages = dut_stages(dut)
    dut.src_bit.value = 1  # source already high before the first edge
    await Timer(1, units="ps")
    assert int(dut.dst_bit.value) == 0, (
        "dst_bit is high before any clock edge with INIT_VAL=0 — the chain did "
        "not take its configuration value")

    start_clock_ps(dut, "dst_clk", DST_PS)

    # The source is already high, so the first edge samples it into sync_q[0]
    # and the STAGES-th edge is where it reaches sync_q[STAGES-1]. So the INIT
    # value must hold for the first STAGES-1 edges, and the source must arrive
    # on edge STAGES exactly.
    early = []
    for cyc in range(stages - 1):
        await RisingEdge(dut.dst_clk)
        await ReadOnly()
        if int(dut.dst_bit.value) != 0:
            early.append(cyc + 1)

    assert not early, (
        f"dst_bit left its INIT_VAL before the source had walked the full chain "
        f"(high at edge(s) {early}, STAGES={stages}).\n"
        f"  The power-up level is the fail-safe level (CLAUDE.md §5 rule 4). A "
        f"chain that jumps to the source value early defeats INIT_VAL entirely."
    )

    await RisingEdge(dut.dst_clk)
    await ReadOnly()
    assert int(dut.dst_bit.value) == 1, (
        f"after {stages} edges with src_bit held high from before the clock "
        f"started, dst_bit is still low — the chain is deeper than STAGES"
    )
    dut._log.info("power-up value held for %d edges, source arrived on edge %d",
                  stages - 1, stages)


# =============================================================================
# 1. Latency — the number the callers budget against
# =============================================================================

@cocotb.test()
async def test_latency_is_exactly_stages_cycles(dut):
    """A settled source change appears after EXACTLY ``STAGES`` cycles, always.

    Measured as an equality across many transitions in both directions.  The
    module header quotes 2 cyc / 12.8 ns for STAGES=2 and 3 cyc / 19.2 ns for
    STAGES=3; the kill-switch response budget in ``fpga_top.sv`` is built on
    that number being fixed, not typical.  A synchronizer whose latency varies
    with anything is a jitter source on a safety path.

    The source is changed at the MIDPOINT of a destination period, so the
    measurement is of the pipeline depth and not of sampling luck.  The extra
    "up to 1 further cycle of sampling uncertainty" the header mentions is the
    subject of ``test_latency_upper_bound_over_all_phases``.
    """
    stages = await bringup(dut)
    seen: set[int] = set()

    for i in range(64):
        level = i & 1
        # Establish the OPPOSITE level and let it settle all the way through
        # first. Without this the first iteration "measures" a transition that
        # never happened — dst_bit already equals the target, the search loop
        # exits on its first pass, and the test reports a 1-cycle latency that
        # is an artefact of the testbench, not of the DUT.
        await settle_level(dut, level ^ 1, stages)
        # Align, then move the source safely mid-period.
        await RisingEdge(dut.dst_clk)
        await Timer(DST_PS // 2, units="ps")
        dut.src_bit.value = level

        n = 0
        for _ in range(stages + 8):
            await RisingEdge(dut.dst_clk)
            n += 1
            await ReadOnly()
            if int(dut.dst_bit.value) == level:
                break
        else:
            raise AssertionError(
                f"src_bit -> {level} never reached dst_bit within "
                f"{stages + 8} cycles — the chain is not shifting"
            )
        seen.add(n)
        # The search loop exits inside ReadOnly; step to the next edge so the
        # following iteration is allowed to drive src_bit again.
        await RisingEdge(dut.dst_clk)

    assert seen == {stages}, (
        f"cdc_sync_bit latency is not a constant {stages} destination cycles: "
        f"observed {sorted(seen)}.\n"
        f"  The header (rtl/common/cdc_sync_bit.sv:13-18) promises exactly "
        f"STAGES cycles.  Callers budget against that: the kill path in "
        f"fpga_top.sv is sized on it.  Variable synchronizer latency is jitter "
        f"on a safety-relevant control signal."
    )
    dut._log.info("STAGES=%d, latency locked at %d destination cycles", stages, stages)


@cocotb.test()
async def test_latency_upper_bound_over_all_phases(dut):
    """Across every source-change phase, latency is STAGES or STAGES+1 — never more.

    The header allows "up to 1 further cycle of sampling uncertainty" because
    the source edge may land just after a destination edge.  This test sweeps
    the change point across a whole destination period and pins BOTH ends of the
    window, so an extra pipeline stage added by a future edit cannot hide inside
    the word "uncertainty".
    """
    stages = await bringup(dut)
    observed: dict[int, int] = {}
    steps = 32

    for k in range(steps):
        level = k & 1
        offset = (DST_PS * k) // steps + 1  # +1 ps: never coincide with the edge
        # Settle the opposite level first, so what follows is a real transition.
        await settle_level(dut, level ^ 1, stages)
        await RisingEdge(dut.dst_clk)
        await Timer(offset, units="ps")
        dut.src_bit.value = level

        n = 0
        for _ in range(stages + 8):
            await RisingEdge(dut.dst_clk)
            n += 1
            await ReadOnly()
            if int(dut.dst_bit.value) == level:
                break
        else:
            raise AssertionError(f"no propagation at phase offset {offset} ps")
        observed[offset] = n
        await RisingEdge(dut.dst_clk)   # leave ReadOnly before driving again

    lo, hi = min(observed.values()), max(observed.values())
    assert lo >= stages and hi <= stages + 1, (
        f"latency window over {steps} source phases is [{lo}, {hi}] cycles; the "
        f"contract is [{stages}, {stages + 1}] "
        f"(rtl/common/cdc_sync_bit.sv:13-18).\n"
        f"  per-phase: {observed}"
    )
    dut._log.info("latency window over %d phases: [%d, %d] cycles", steps, lo, hi)


# =============================================================================
# 2. ⚠️ THE DOCUMENTED HOLE — pinned so it cannot silently change
# =============================================================================

async def _pulse_is_seen(dut, width_ps: int, offset_ps: int, watch_cycles: int) -> bool:
    """Drive one ``src_bit`` pulse at a given phase; report whether dst saw it."""
    dut.src_bit.value = 0
    await RisingEdge(dut.dst_clk)
    await Timer(offset_ps, units="ps")
    dut.src_bit.value = 1
    await Timer(width_ps, units="ps")
    dut.src_bit.value = 0

    seen = False
    for _ in range(watch_cycles):
        await RisingEdge(dut.dst_clk)
        await ReadOnly()
        if int(dut.dst_bit.value):
            seen = True
    # Leave the ReadOnly phase before returning: the caller drives `src_bit`
    # immediately, and a write in ReadOnly is an error, not a value.
    await RisingEdge(dut.dst_clk)
    return seen


@cocotb.test()
async def test_sub_period_source_is_missed_at_some_phases(dut):
    """⚠️ PINS THE LIMITATION: a pulse shorter than one dst period IS dropped.

    ``rtl/common/cdc_sync_bit.sv:34`` — "SOURCE MUST BE STABLE FOR >= 2
    DESTINATION CLOCK PERIODS.  A single-cycle pulse crossing into a slower
    domain is silently dropped."  Manual 00.04 §7 lists it as its own row:
    "Pulse to slower domain -> events silently lost, counters drift".

    This test asserts the loss HAPPENS.  That is deliberate and it is the point:
    a limitation that is only written in a comment gets argued away by the next
    person who wants a cheap crossing for a strobe.  A limitation with a test
    that FAILS when it stops being true is a contract.

    Method: a half-period-wide pulse is swept across a whole destination period.
    Phases where the pulse straddles a rising edge are captured; phases where it
    lies entirely between two edges are lost.  Both outcomes must occur — if
    every phase were captured, the module would have grown a latch and would no
    longer be the pure sampler its safety argument depends on.

    THE FIX FOR A CALLER IS NEVER "ADD STAGES".  It is ``cdc_pulse`` for an
    event, or ``async_fifo`` if the source can burst.
    """
    stages = await bringup(dut)
    steps = 32
    width = DST_PS // 2
    missed, caught = [], []

    for k in range(steps):
        offset = (DST_PS * k) // steps + 1
        if await _pulse_is_seen(dut, width, offset, stages + 4):
            caught.append(offset)
        else:
            missed.append(offset)
        # let the chain flush before the next trial
        await settle_level(dut, 0, stages)

    assert missed, (
        f"A {width} ps source pulse (half a {DST_PS} ps destination period) was "
        f"captured at ALL {steps} phases.  Either the destination clock is not "
        f"running at the period this test assumes, or cdc_sync_bit has acquired "
        f"level-holding behaviour it must not have.\n"
        f"  The documented contract (rtl/common/cdc_sync_bit.sv:34, manual 00.04 "
        f"§3.1) is that a sub-period source IS dropped.  If that has genuinely "
        f"changed, the header, the manual and every caller's assumption change "
        f"with it — this is a system-wide change, not a local one."
    )
    assert caught, (
        f"A {width} ps source pulse was missed at ALL {steps} phases — the chain "
        f"is not sampling src_bit at all.  Check that src_bit reaches sync_q[0]."
    )
    dut._log.info(
        "⚠️ documented limitation confirmed: sub-period source pulse lost at "
        "%d of %d phases (captured at %d). Use cdc_pulse for events.",
        len(missed), steps, len(caught),
    )


@cocotb.test()
async def test_two_period_source_is_captured_at_every_phase(dut):
    """The other half of the contract: >= 2 destination periods ALWAYS arrives.

    This is the guarantee callers are allowed to rely on.  Asserted over a full
    sweep of source phases, because "works at the phase the testbench happened
    to pick" is precisely the property that passes CI and fails in the field.
    """
    stages = await bringup(dut)
    steps = 32
    width = 2 * DST_PS
    missed = []

    for k in range(steps):
        offset = (DST_PS * k) // steps + 1
        if not await _pulse_is_seen(dut, width, offset, stages + 6):
            missed.append(offset)
        await settle_level(dut, 0, stages)

    assert not missed, (
        f"A source level held for {width} ps (2 destination periods) was LOST at "
        f"{len(missed)} of {steps} phases: {missed}.\n"
        f"  This is the ONE guarantee the primitive makes "
        f"(rtl/common/cdc_sync_bit.sv:34).  If it does not hold, every kill "
        f"switch, enable and status bit in the design is unreliable."
    )
    dut._log.info("2-period source captured at all %d phases", steps)


# =============================================================================
# 3. The chain never invents a transition
# =============================================================================

@cocotb.test()
async def test_dst_bit_is_a_pure_delayed_sample_of_src_bit(dut):
    """dst_bit after edge N == the value edge N-(STAGES-1) sampled.  Every cycle.

    Constrained-random source toggling on a time base deliberately unrelated to
    the destination clock, checked against a software shift register fed from
    the same sampled values.  This is the property that says "no invention": the
    destination may LAG the source and may MISS a change, but it must never
    report a value the source never held, and it must never glitch.

    ⚠️ The depth here is ``STAGES-1``, not ``STAGES``, and the difference is not
    an off-by-one — it is a change of reference point.  The latency tests above
    measure from the INSTANT the source moved (mid-period) to the edge where
    ``dst_bit`` shows it, which is ``STAGES`` edges: one to sample it into
    ``sync_q[0]`` and ``STAGES-1`` to shift it out.  This test's reference point
    is "the value edge k sampled", which has already consumed that first edge,
    leaving ``STAGES-1`` edges of shifting.  Both statements describe the same
    hardware.

    A synchronizer that emits a transition the source did not make is manual
    00.04 §7 row 3 — "combinational logic feeding a synchronizer: glitches
    sampled as real transitions".
    """
    rng, seed = seeded_rng(dut, "cdc_sync_bit.random")
    stages = await bringup(dut)

    async def _wiggle():
        """Change src_bit at arbitrary sub-period phases, never ON an edge.

        Landing a write exactly on a destination edge would make the
        TESTBENCH's model of "what the flop sampled" ambiguous — the same
        ambiguity that is a genuine metastability window in silicon and a
        scheduling artefact in simulation.  Asserting through it would be
        asserting the simulator's event ordering.  So the source moves at a
        random point strictly inside a period, after a random number of whole
        periods: every sub-period phase is still visited.
        """
        while True:
            for _ in range(rng.randrange(1, 5)):
                await RisingEdge(dut.dst_clk)
            await Timer(rng.randrange(200, DST_PS - 200), units="ps")
            dut.src_bit.value = rng.getrandbits(1)

    wig = cocotb.start_soon(_wiggle())

    hist: list[int] = []          # hist[-1] is the value the latest edge sampled
    checked = 0
    try:
        for cyc in range(4000):
            await RisingEdge(dut.dst_clk)
            await ReadOnly()
            # The wiggle task never writes at an edge time, so src_bit read in
            # the ReadOnly phase of edge k IS the value edge k sampled.
            hist.append(int(dut.src_bit.value))
            got = int(dut.dst_bit.value)
            if len(hist) > stages:
                expect = hist[-stages]
                assert got == expect, (
                    f"cdc_sync_bit INVENTED a value at cycle {cyc}: dst_bit="
                    f"{got}, but the value sampled {stages - 1} edge(s) earlier "
                    f"was {expect}.\n"
                    f"  A synchronizer is a delay line and nothing else. A "
                    f"destination that sees a level the source never held is "
                    f"manual 00.04 §2 — 'a value that never existed'."
                    + seed_note(seed)
                )
                checked += 1
    finally:
        wig.kill()

    assert checked > 3000, f"only {checked} cycles checked — the loop exited early"
    dut._log.info("pure-delay property held for %d cycles", checked)


# =============================================================================
# 4. Structural guard-rails simulation cannot check any other way
# =============================================================================

@cocotb.test()
async def test_source_forbids_multibit_use(dut):
    """The RTL still carries the guard-rails that make this primitive safe.

    ⚠️ THIS IS A SOURCE-TEXT CHECK, NOT A SIMULATION.  It is here because the
    three things that make ``cdc_sync_bit`` safe are all structurally invisible
    to RTL simulation (manual 00.04 §6, tb/README.md §5):

      1. ``ASYNC_REG = "TRUE"`` — without it a placer may spread the chain and
         silently destroy MTBF.  The design works in the lab and fails after an
         unrelated placement change.  The header calls omitting it "a real bug,
         not a style issue".
      2. ``STAGES >= 2`` elaboration check — a 1-FF chain is not a synchronizer,
         and nothing in simulation would look any different.
      3. A single-bit ``src_bit`` port — the moment this becomes a vector,
         parallel chains across a bus become expressible and the classic
         multi-bit CDC bug (manual 00.04 §2) becomes a one-line change.

    A future edit that removes any of these passes every functional test in this
    file.  So this test reads the file.
    """
    assert RTL.is_file(), f"{RTL} not found"
    text = RTL.read_text()

    assert re.search(r'\(\*\s*ASYNC_REG\s*=\s*"TRUE"\s*\*\)', text), (
        f"{RTL}: the ASYNC_REG attribute is gone.\n"
        f"  Without it the two chain flip-flops may be placed far apart, the "
        f"inter-stage settling time collapses, and MTBF drops by orders of "
        f"magnitude — with NO change in simulation, NO change in STA, and no "
        f"warning of any kind. Manual 00.04 §3.1 and §7 row 2."
    )
    assert re.search(r"STAGES\s*<\s*2", text), (
        f"{RTL}: the `STAGES < 2` elaboration guard is gone. A 1-deep chain "
        f"simulates identically and is not a synchronizer."
    )
    assert re.search(r"input\s+var\s+logic\s+src_bit\s*,", text), (
        f"{RTL}: `src_bit` is no longer a scalar port.\n"
        f"  A vector here makes per-bit synchronization of a bus a one-line "
        f"change, and that is the single most expensive CDC bug in the manual "
        f"(§2, §7 row 1: 'a price that was never quoted'). Buses use "
        f"async_fifo or cdc_handshake."
    )
    dut._log.info("structural guard-rails present in %s", RTL.name)


if __name__ == "__main__":  # pragma: no cover
    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        from cocotb.runner import get_runner

    from tb_util import sim_sources

    runner = get_runner(os.environ.get("SIM", "verilator"))
    for stages in (2, 3):
        runner.build(
            verilog_sources=sim_sources("rtl/common/cdc_sync_bit.sv"),
            hdl_toplevel="cdc_sync_bit",
            parameters={"STAGES": stages},
            build_args=["-Wno-fatal", "--timescale-override", "1ns/1ps"],
            always=True,
        )
        runner.test(hdl_toplevel="cdc_sync_bit", test_module="test_cdc_sync_bit")
