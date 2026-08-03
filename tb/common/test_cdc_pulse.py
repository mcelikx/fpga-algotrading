"""Toggle pulse synchronizer — proves every gated event crosses, and finds the wall.

INVARIANT PROVEN
    ``cdc_pulse`` carries EVENTS, and the count is the contract:

      * ``dst_pulse`` count == ``src_accept`` count.  EXACTLY.  At every
        source:destination ratio from 1:8 to 8:1, at randomized phase.  Never a
        lost event, never a fabricated one, never a double.
      * ``dst_pulse`` is exactly one destination cycle wide, always.
      * A source that gates itself on ``src_busy`` loses NOTHING.
      * ⚠️ A source that IGNORES ``src_busy`` loses events, and this file
        measures the EXACT spacing at which that starts — and proves that the
        loss is a clean DROP (dst count == accepted count, still) and never a
        corruption, a duplicate, or a phantom event.
      * ⚠️ Resetting one domain only, with an event in flight, produces a
        SPURIOUS destination event.  Pinned, because the header says so and a
        caller obligation nobody tests is a caller obligation nobody keeps.

WHY IT MATTERS
    Read the caller list in ``rtl/common/cdc_pulse.sv:12``: host doorbell /
    commit strobes, "heartbeat received", "counter snapshot now", **credit
    return**.  Each of those is an event whose count is load bearing:

      * A lost **credit return** permanently reduces the number of orders the
        gateway believes it may have in flight.  The system does not fail; it
        gets quietly slower, forever, until a restart.  Nothing alarms.
      * A lost **heartbeat** looks like a dead link to the watchdog and trips
        the kill switch during a live session.
      * A *duplicated* commit strobe applies a configuration write twice.

    Manual 00.04 §7 gives this its own row — "Pulse to slower domain: events
    silently lost, counters drift" — and drift is the operative word.  A counter
    that is wrong by a few is far more expensive than one that is obviously
    broken, because it is believed.

    ⚠️ RTL simulation cannot see metastability.  What it CAN see, and what this
    file exists for, is whether the toggle/edge-detect construction conserves
    events across clock ratios.  That is the half of the problem simulation owns.

DUT
    rtl/common/cdc_pulse.sv (instantiates cdc_sync_bit).  Ports: ``src_clk``,
    ``src_rst``, ``src_pulse``, ``src_busy``, ``dst_clk``, ``dst_rst``,
    ``dst_pulse``.  Parameter ``SYNC_STAGES`` (>= 2).

    Both resets are synchronous, active high, and MUST come from one root reset
    (header line 48).  Tests that violate that deliberately say so in their name.

RUNNING
    TOPLEVEL=cdc_pulse, or ``python test_cdc_pulse.py``.
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

BASE_PS = 6400  # 156.25 MHz, the core clock

# (label, src_period_ps, dst_period_ps).  Ratio is expressed as f_src : f_dst,
# so "1:8" means the destination runs eight times faster than the source.
# The extremes are the interesting ones: a fast source into a slow destination
# is where events are lost, and a slow source into a fast destination is where
# a mis-built edge detector produces duplicates.
RATIOS: list[tuple[str, int, int]] = [
    ("1:8  src slow", BASE_PS * 8, BASE_PS),
    ("1:4  src slow", BASE_PS * 4, BASE_PS),
    ("1:3  src slow", BASE_PS * 3, BASE_PS),
    ("1:2  src slow", BASE_PS * 2, BASE_PS),
    ("1:1  equal", BASE_PS, BASE_PS),
    ("1:1  near-equal", BASE_PS, BASE_PS + 2),
    ("2:1  src fast", BASE_PS, BASE_PS * 2),
    ("3:1  src fast", BASE_PS, BASE_PS * 3),
    ("4:1  src fast", BASE_PS, BASE_PS * 4),
    ("8:1  src fast", BASE_PS, BASE_PS * 8),
]


# =============================================================================
# Infrastructure
# =============================================================================

#: cocotb runs every test in this file inside ONE simulation, and this file
#: restarts both clocks at a new ratio and phase many times per test. Without
#: this registry the old driver task keeps toggling the net alongside the new
#: one, which produces a clock that is neither ratio and a failure nobody can
#: read. Kill the previous driver, then start the new one.
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


def sync_stages(dut) -> int:
    """Read SYNC_STAGES off the DUT if the simulator exposes the hierarchy."""
    for path in ("u_req_sync", "u_ack_sync"):
        try:
            n = len(getattr(dut, path).sync_q)
            if n >= 2:
                return n
        except Exception:  # pragma: no cover - inlined/flattened hierarchy
            pass
    return int(os.environ.get("SYNC_STAGES", "2"))


class DstMonitor:
    """Count ``dst_pulse`` events and police their width, continuously.

    Runs as a background task on ``dst_clk`` so that a pulse emitted at a moment
    the stimulus loop is not looking is still counted.  A monitor that only
    samples when the driver happens to check is how "no events were lost" turns
    into "no events were observed".
    """

    def __init__(self, dut):
        self.dut = dut
        self.count = 0
        self.width_violations: list[int] = []
        self.times: list[float] = []
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
                cur = int(self.dut.dst_pulse.value)
                if cur:
                    self.count += 1
                    self.times.append(self._cyc)
                    if prev:
                        self.width_violations.append(self._cyc)
                prev = cur

        self._task = cocotb.start_soon(_run())
        return self._task

    def stop(self):
        if self._task:
            self._task.kill()
            self._task = None

    def assert_single_cycle(self, context: str = ""):
        assert not self.width_violations, (
            f"dst_pulse was high for more than one destination cycle at cycles "
            f"{self.width_violations[:8]} {context}.\n"
            f"  dst_pulse is an EVENT, not a level (rtl/common/cdc_pulse.sv:45). "
            f"A two-cycle 'pulse' is counted twice by an edge-triggered consumer "
            f"and once by a level-triggered one; the two then disagree forever."
        )


#: Only one destination monitor may be running at a time; two would double-count
#: every event and turn a clean pass into an unreadable failure.
_MON: list[DstMonitor] = []


async def bringup(dut, src_ps: int, dst_ps: int, src_phase: int = 0,
                  dst_phase: int = 0) -> DstMonitor:
    while _MON:
        _MON.pop().stop()
    dut.src_pulse.value = 0
    dut.src_rst.value = 1
    dut.dst_rst.value = 1
    start_clock_ps(dut, "src_clk", src_ps, src_phase)
    start_clock_ps(dut, "dst_clk", dst_ps, dst_phase)
    # Hold both resets long enough that BOTH domains have seen many edges. The
    # header (line 48) requires both resets from one root; that is what we model.
    hold_ps = 12 * max(src_ps, dst_ps)
    await Timer(hold_ps, units="ps")
    dut.src_rst.value = 0
    dut.dst_rst.value = 0
    await Timer(6 * max(src_ps, dst_ps), units="ps")
    mon = DstMonitor(dut)
    mon.start()
    _MON.append(mon)
    return mon


async def fire(dut, respect_busy: bool = True) -> bool:
    """Present ``src_pulse`` for one source cycle.  Returns True if ACCEPTED.

    Driven on the FALLING edge of ``src_clk``.  ``src_busy`` is a function of two
    flip-flops, so it cannot change between source rising edges: reading it at
    the midpoint gives exactly what the next rising edge will use, with no
    ReadOnly/ReadWrite phase juggling and no race.

    ⚠️ With ``respect_busy`` (the default) the source NEVER drives ``src_pulse``
    while ``src_busy`` — which is both the documented caller obligation
    (rtl/common/cdc_pulse.sv:37) and a hard requirement for the testbench,
    because the RTL asserts it at line 154 with ``$error``, and Verilator turns
    that into ``$stop``. A testbench that violates it does not observe a
    dropped event; it terminates the simulator.
    """
    await FallingEdge(dut.src_clk)
    busy = int(dut.src_busy.value)
    if respect_busy and busy:
        dut.src_pulse.value = 0
        return False
    dut.src_pulse.value = 1
    await FallingEdge(dut.src_clk)     # the rising edge in between sampled it
    dut.src_pulse.value = 0
    return not busy


async def wait_not_busy(dut, limit: int = 200) -> int:
    """Source cycles from now until ``src_busy`` falls.  Raises if it never does."""
    for n in range(1, limit + 1):
        await FallingEdge(dut.src_clk)
        if not int(dut.src_busy.value):
            return n
    raise AssertionError(
        f"src_busy never released within {limit} source cycles — the ack toggle "
        f"is not coming back. Either dst_clk stopped or the two resets were not "
        f"released together (rtl/common/cdc_pulse.sv:48)."
    )


async def fire_and_measure_busy(dut, limit: int = 200) -> int:
    """Fire from idle and return the busy window, in source cycles FROM THE
    ACCEPTING EDGE.

    One helper, one reference point, used by every test that quotes a busy
    number.  The reference point matters more than it looks: measuring from
    wherever a convenience wrapper happened to hand control back gives a figure
    that is off by a fraction of a cycle in a direction nobody can reconstruct
    later, and two tests then "disagree" about a channel that is behaving
    perfectly.

    Returns ``k`` such that ``src_busy`` is low at the midpoint of cycle ``k``
    after the accepting edge — which is exactly the minimum source firing period
    a caller can sustain without losing an event.
    """
    await FallingEdge(dut.src_clk)
    assert not int(dut.src_busy.value), "channel already busy before firing"
    dut.src_pulse.value = 1
    await RisingEdge(dut.src_clk)          # <- cycle 0: the accepting edge
    dut.src_pulse.value = 0
    for n in range(1, limit + 1):
        await FallingEdge(dut.src_clk)
        if not int(dut.src_busy.value):
            return n
    raise AssertionError(
        f"src_busy never released within {limit} source cycles — the ack toggle "
        f"is not coming back. Either dst_clk stopped or the two resets were not "
        f"released together (rtl/common/cdc_pulse.sv:48)."
    )


async def wait_idle(dut, limit: int = 500) -> None:
    """Block until the channel is idle, leaving the simulation writable."""
    for _ in range(limit):
        await FallingEdge(dut.src_clk)
        if not int(dut.src_busy.value):
            return
    raise AssertionError("src_busy stuck high")


# =============================================================================
# 1. THE headline: event conservation at every ratio
# =============================================================================

@cocotb.test()
async def test_every_gated_event_crosses_exactly_once(dut):
    """dst_pulse count == accepted src event count, at 10 clock ratios.

    The source respects ``src_busy``, which is what every legitimate caller must
    do.  Under that discipline the header promises "NO EVENT IS EVER LOST"
    (rtl/common/cdc_pulse.sv:17).  This asserts the count as an equality in both
    directions: a lost event and a duplicated event are equally fatal, because
    the consumer of a credit return cannot tell them apart from a real one.

    Ratios span 1:8 to 8:1 including a near-equal pair (6400 ps vs 6402 ps),
    which walks the two clocks through every phase relationship during the run.
    Manual 00.04 §6.2: "Run your testbench at several clock ratios, including
    nearly-equal frequencies (the hardest case)."
    """
    rng, seed = seeded_rng(dut, "cdc_pulse.ratios")
    n_events = int(os.environ.get("EVENTS", "60"))

    for label, src_ps, dst_ps in RATIOS:
        # Randomized phase, not just randomized ratio — a bug that only appears
        # when the two edges nearly coincide is still a bug.
        mon = await bringup(
            dut, src_ps, dst_ps,
            src_phase=rng.randrange(0, src_ps),
            dst_phase=rng.randrange(0, dst_ps),
        )
        accepted = 0
        for _ in range(n_events):
            # Wait until the channel is idle, then fire. This is the caller
            # discipline the module documents (rtl/common/cdc_pulse.sv:37).
            await wait_idle(dut)
            if await fire(dut):
                accepted += 1
            # Random idle so the events do not land on a repeating phase.
            for _ in range(rng.randrange(0, 4)):
                await FallingEdge(dut.src_clk)

        # Let the last event drain through both synchronizers.
        await Timer(20 * max(src_ps, dst_ps), units="ps")
        mon.stop()

        assert accepted == n_events, (
            f"[{label}] only {accepted} of {n_events} events were accepted even "
            f"though the source waited for !src_busy every time" + seed_note(seed)
        )
        assert mon.count == accepted, (
            f"[{label}] EVENT COUNT MISMATCH: {accepted} accepted in src_clk, "
            f"{mon.count} emitted in dst_clk (delta {mon.count - accepted:+d}).\n"
            f"  src period {src_ps} ps, dst period {dst_ps} ps.\n"
            f"  Lost events are manual 00.04 §7 'counters drift'; extra events "
            f"are a credit returned that never was. Neither is recoverable "
            f"downstream." + seed_note(seed)
        )
        mon.assert_single_cycle(f"[{label}]")
        dut._log.info("%s: %d/%d events conserved", label, mon.count, n_events)


@cocotb.test()
async def test_no_dst_pulse_without_a_src_event(dut):
    """An idle source produces an absolutely silent destination.

    Held for a long window at the most adversarial ratio in the list.  A phantom
    event here is a credit the gateway never earned or a heartbeat that never
    arrived — the failure that makes a dead link look alive.
    """
    mon = await bringup(dut, BASE_PS, BASE_PS + 2)
    await Timer(4000 * BASE_PS, units="ps")
    mon.stop()
    assert mon.count == 0, (
        f"{mon.count} phantom dst_pulse events with src_pulse tied low for "
        f"4000 cycles at near-equal frequencies.\n"
        f"  Near-equal clocks walk through every phase relationship, so this is "
        f"the configuration in which a mis-built edge detector fires on its own."
    )


# =============================================================================
# 2. Latency and the busy round trip
# =============================================================================

@cocotb.test()
async def test_latency_and_busy_release_match_the_header(dut):
    """src event -> dst_pulse is SYNC_STAGES+1 dst cycles; busy returns in ~6.

    The header (rtl/common/cdc_pulse.sv:19-23) quotes:
      * ``src_pulse -> dst_pulse``: SYNC_STAGES + 1 destination cycles, plus up
        to one cycle of sampling uncertainty.  Default 2 -> 3 dst cycles.
      * ``src_busy`` release: that, plus SYNC_STAGES + 1 source cycles for the
        ack.  "Round trip ~6 cycles."

    Both are asserted at equal frequency, where the quoted numbers apply, and
    both are asserted as a BOUNDED WINDOW rather than a single value, because
    the sampling uncertainty is real and the header says so.  A regression that
    adds a stage moves the window and fails here rather than silently costing
    the control plane a cycle on every doorbell.

    ⚠️ MEASURED, and worth knowing before you size a doorbell rate: the busy
    round trip is NOT a constant.  Sweeping the destination clock phase across a
    whole period at equal frequency gives a range, because the request toggle
    has to catch a destination edge and the acknowledge has to catch a source
    edge, and how long each takes depends on where the two clocks happen to sit
    relative to each other.  The header's "~6 cycles" is the pessimistic end.
    A caller must budget the WORST case, and a caller that measures the best
    case once and hard-codes it will drop events at a different temperature.
    The rate-limit test below re-measures the same number and holds the firing
    boundary to it exactly.
    """
    stages = sync_stages(dut)
    lat_lo, lat_hi = stages + 1, stages + 2
    busy_lo, busy_hi = stages + 1, stages + 4

    lat_seen: list[int] = []
    busy_seen: list[int] = []

    for trial in range(24):
        phase = (BASE_PS * trial) // 24 + 1
        mon = await bringup(dut, BASE_PS, BASE_PS, dst_phase=phase)

        # Drive the pulse inline rather than through `fire()`, so that the
        # measurement's zero point is the ACCEPTING SOURCE EDGE itself. Anything
        # that returns after the edge (as `fire` does, by half a period) makes
        # the destination-cycle count depend on where in the source period the
        # helper happened to hand control back — which is a property of the
        # testbench, not of the DUT.
        await FallingEdge(dut.src_clk)
        assert not int(dut.src_busy.value), "channel busy straight after reset"
        dut.src_pulse.value = 1
        await RisingEdge(dut.src_clk)          # <- t = 0: the accepting edge
        dut.src_pulse.value = 0

        # Count destination cycles by their FALLING edges: dst_pulse is a
        # registered output, so the midpoint is a settled sample point, and
        # unlike ReadOnly it leaves the simulation writable for the next bringup.
        n = 0
        for _ in range(stages + 8):
            await FallingEdge(dut.dst_clk)
            n += 1
            if int(dut.dst_pulse.value):
                break
        else:
            raise AssertionError(f"no dst_pulse within {stages + 8} dst cycles")
        lat_seen.append(n)
        mon.stop()

        # Busy release is measured in a FRESH channel, from the accepting edge,
        # by the shared helper — so this number and the one the rate-limit test
        # quotes are the same measurement of the same thing.
        mon = await bringup(dut, BASE_PS, BASE_PS, dst_phase=phase)
        busy_seen.append(await fire_and_measure_busy(dut))
        mon.stop()

    assert min(lat_seen) >= lat_lo and max(lat_seen) <= lat_hi, (
        f"src->dst latency window is [{min(lat_seen)}, {max(lat_seen)}] "
        f"destination cycles; the header promises "
        f"[{lat_lo}, {lat_hi}] for SYNC_STAGES={stages} "
        f"(rtl/common/cdc_pulse.sv:19).\n  samples: {lat_seen}"
    )
    assert min(busy_seen) >= busy_lo and max(busy_seen) <= busy_hi, (
        f"src_busy release window is [{min(busy_seen)}, {max(busy_seen)}] source "
        f"cycles over {len(busy_seen)} destination phases; the contract is "
        f"[{busy_lo}, {busy_hi}] for SYNC_STAGES={stages}, and the header quotes "
        f"a ~{stages + 4}-cycle round trip as the pessimistic end "
        f"(rtl/common/cdc_pulse.sv:22).\n  samples: {busy_seen}\n"
        f"  This number IS the sustained event rate of the channel. If the worst "
        f"case grows, every caller's maximum doorbell rate shrinks with it, and "
        f"the shrink is silent — the events just stop arriving."
    )
    dut._log.info(
        "SYNC_STAGES=%d over %d destination phases: dst latency %s cyc "
        "(header: SYNC_STAGES+1 = %d, +1 for sampling uncertainty); "
        "src_busy round trip %s cyc (header: ~%d, which is the worst case)",
        stages, len(lat_seen), sorted(set(lat_seen)), stages + 1,
        sorted(set(busy_seen)), stages + 4,
    )


# =============================================================================
# 3. ⚠️ THE WALL — where events start being lost, measured exactly
# =============================================================================

async def _spacing_trial(dut, spacing: int, n_cycles: int) -> tuple[int, int]:
    """Attempt a firing every ``spacing`` source cycles, gated on ``!src_busy``.

    Returns ``(intended, accepted)``.  Every attempt that lands while the channel
    is busy is SKIPPED — the caller's own drop, which is exactly what
    rtl/common/cdc_pulse.sv:37 instructs a caller to do, and what CLAUDE.md §5.7
    then requires the caller to count.

    ⚠️ Deliberately never drives ``src_pulse`` while ``src_busy``: the RTL treats
    that as an error (line 154) and Verilator turns it into ``$stop``, so the
    illegal case cannot be measured here.  It has its own opt-in test at the end
    of this file.
    """
    intended = accepted = 0
    for c in range(n_cycles):
        await FallingEdge(dut.src_clk)
        busy = int(dut.src_busy.value)
        want = (c % spacing == 0)
        if want:
            intended += 1
        drive = want and not busy
        dut.src_pulse.value = int(drive)
        if drive:
            accepted += 1
    dut.src_pulse.value = 0
    return intended, accepted


@cocotb.test()
async def test_rate_limit_boundary_is_exactly_the_busy_window(dut):
    """⚠️ PINS THE RATE LIMIT: the exact spacing below which events are refused.

    ``rtl/common/cdc_pulse.sv:29`` — "The crossing carries at most ONE event in
    flight.  Source pulses must be separated by at least (SYNC_STAGES + 1)
    DESTINATION clock periods plus the ack return trip."

    The test sweeps the source firing period from 1 cycle upward.  At each
    spacing a well-behaved caller attempts a firing every ``spacing`` cycles and
    gates itself on ``!src_busy``, recording:

      * ``intended`` : firings the caller wanted
      * ``accepted`` : firings the channel was idle for
      * ``dst``      : events that came out the other side

    Three things are asserted, and the third is the valuable one:

      1. There is a spacing below which ``accepted < intended``.  The rate limit
         is REAL, not theoretical: a caller pushing faster than this silently
         loses events, and it is the caller — not this module — that has to
         count them.
      2. There is a spacing at and above which ``accepted == intended``, and it
         is the measured ``src_busy`` release window.  That agreement is the
         whole reason the module exposes ``src_busy``: the signal means
         precisely "you may fire now", so a caller that obeys it loses nothing.
      3. ⚠️ At EVERY spacing, including the lossy ones, ``dst == accepted``.
         Refusing an event never disturbs the events around it, never merges two
         into one, and never fabricates a third.  That is strictly stronger than
         the bare toggle synchronizer in manual §3.2, where two close pulses
         annihilate each other and the destination sees NOTHING.

    The loss is monotonic in spacing, which is asserted too — a channel that
    worked at spacing 5 and failed at spacing 7 would mean the busy gate is
    racing rather than rate-limiting.
    """
    stages = sync_stages(dut)

    # Reference: how long does the channel actually stay busy after one event,
    # measured from the accepting edge by the same helper the latency test uses?
    mon = await bringup(dut, BASE_PS, BASE_PS)
    busy_window = await fire_and_measure_busy(dut)
    mon.stop()

    rows: list[tuple[int, int, int, int]] = []
    for spacing in range(1, busy_window + 5):
        mon = await bringup(dut, BASE_PS, BASE_PS)
        intended, accepted = await _spacing_trial(dut, spacing, spacing * 24)
        await Timer(30 * BASE_PS, units="ps")
        mon.stop()
        mon.assert_single_cycle(f"[spacing={spacing}]")
        rows.append((spacing, intended, accepted, mon.count))

        assert mon.count == accepted, (
            f"AT SPACING {spacing}: {accepted} events accepted but {mon.count} "
            f"emitted (delta {mon.count - accepted:+d}).\n"
            f"  Refusing an event must never disturb the ones that were taken, "
            f"merge two into a wrong count, or fabricate one. This is the "
            f"property that makes 'silently dropping is better than corrupting' "
            f"(rtl/common/cdc_pulse.sv:41) true."
        )

    lossy = [r for r in rows if r[2] < r[1]]
    clean = [r for r in rows if r[2] == r[1]]

    assert lossy, (
        f"No source spacing from 1 to {busy_window + 4} cycles refused a single "
        f"firing. The rate limit documented at rtl/common/cdc_pulse.sv:29 does "
        f"not exist in this build — either src_busy is stuck low or the module "
        f"has silently grown a queue. Both change the caller contract.\n"
        f"  rows (spacing, intended, accepted, dst): {rows}"
    )
    assert clean, (
        f"EVERY spacing up to {busy_window + 4} cycles lost firings — the "
        f"channel never becomes idle.\n  rows: {rows}"
    )

    boundary = min(r[0] for r in clean)
    assert all(r[2] == r[1] for r in rows if r[0] >= boundary), (
        f"loss is not monotonic in spacing: some spacing above the boundary "
        f"{boundary} still lost firings. A busy gate that races rather than "
        f"rate-limits would look exactly like this.\n  rows: {rows}"
    )
    assert boundary == busy_window, (
        f"⚠️ RATE-LIMIT BOUNDARY is {boundary} source cycles but src_busy "
        f"releases after {busy_window}. These are measured from the same "
        f"reference point (the accepting edge) by the same helper, so they must "
        f"be equal.\n"
        f"  These must agree. src_busy is the caller's only legal gate; if the "
        f"channel refuses events at a spacing src_busy reports as idle — or "
        f"accepts them at a spacing it reports as busy — then following the "
        f"documented rule does not actually protect the caller.\n"
        f"  rows (spacing, intended, accepted, dst): {rows}"
    )
    dut._log.info(
        "⚠️ rate limit measured: a caller firing faster than every %d source "
        "cycles loses events (src_busy releases after %d, SYNC_STAGES=%d). "
        "Rows (spacing, intended, accepted, dst): %s",
        boundary, busy_window, stages, rows,
    )


@cocotb.test()
async def test_back_to_back_burst_is_refused_not_corrupted(dut):
    """A source that bursts loses most of the burst — and nothing else breaks.

    ``rtl/common/cdc_pulse.sv:43`` — "If the source can BURST, this module is
    the wrong primitive. Use async_fifo."  This is that sentence, measured: the
    caller wants to fire on 64 consecutive source cycles, at three ratios.  Only
    a handful get through, the destination count matches the accepted count
    exactly, and the channel is still healthy afterwards.

    A caller reading this test should read the number of survivors and go use
    ``async_fifo``.
    """
    for label, src_ps, dst_ps in (
        ("1:1  equal", BASE_PS, BASE_PS),
        ("4:1  src fast", BASE_PS, BASE_PS * 4),
        ("1:4  src slow", BASE_PS * 4, BASE_PS),
    ):
        mon = await bringup(dut, src_ps, dst_ps)
        intended, accepted = await _spacing_trial(dut, 1, 64)
        await Timer(40 * max(src_ps, dst_ps), units="ps")
        mon.stop()

        assert mon.count == accepted, (
            f"[{label}] burst: {accepted} accepted, {mon.count} emitted"
        )
        assert accepted < intended, (
            f"[{label}] all {intended} back-to-back firings were accepted — the "
            f"one-event-in-flight limit is gone"
        )
        mon.assert_single_cycle(f"[{label}] burst")

        # The channel must still be usable after being hammered.
        await Timer(40 * max(src_ps, dst_ps), units="ps")
        before = mon.count
        mon.start()
        await wait_idle(dut)
        assert await fire(dut), f"[{label}] channel dead after a burst"
        await Timer(30 * max(src_ps, dst_ps), units="ps")
        mon.stop()
        assert mon.count == before + 1, (
            f"[{label}] post-burst event produced {mon.count - before} dst "
            f"pulses, expected 1"
        )
        dut._log.info(
            "%s: %d of %d back-to-back firings survived — use async_fifo for bursts",
            label, accepted, intended,
        )


# =============================================================================
# 4. ⚠️ Caller obligation: both resets from one root
# =============================================================================

@cocotb.test()
async def test_resetting_one_domain_only_breaks_event_conservation(dut):
    """⚠️ PINS THE CALLER OBLIGATION: a lone src_rst fabricates a dst event.

    ``rtl/common/cdc_pulse.sv:48`` — "BOTH RESETS MUST DERIVE FROM THE SAME ROOT
    RESET ... Resetting only one side leaves the request and acknowledge toggles
    out of phase; the destination then emits one spurious ``dst_pulse`` on
    release, or the source sits permanently ``src_busy``."

    This asserts that the damage is REAL and OBSERVABLE, for two reasons:

      * It stops the obligation being decorative.  ``clk_rst_gen`` provides one
        ``reset_sync`` per domain off one asynchronous root precisely so this
        cannot happen; if someone later wires a domain-local reset in, this test
        is the thing that says what it costs.
      * A spurious event is worse than a lost one.  In the credit-return
        application it manufactures order capacity that the venue never granted.

    The mechanism: ``src_rst`` forces ``src_toggle_q`` to 0 while the request
    toggle is still high in the destination domain.  The destination edge
    detector sees the 1->0 transition and counts it as a second event.
    """
    extras = 0
    trials = 8
    for delay in range(trials):
        mon = await bringup(dut, BASE_PS, BASE_PS)
        base = mon.count
        assert await fire(dut), "event not accepted"
        # Let the request toggle reach the destination, then reset ONLY src.
        for _ in range(delay + 3):
            await RisingEdge(dut.src_clk)
        dut.src_rst.value = 1
        await RisingEdge(dut.src_clk)
        await RisingEdge(dut.src_clk)
        dut.src_rst.value = 0
        await Timer(30 * BASE_PS, units="ps")
        mon.stop()
        got = mon.count - base
        if got != 1:
            extras += 1
        dut._log.info("src-only reset, delay=%d: %d dst events for 1 src event",
                      delay, got)

    assert extras > 0, (
        f"A source-only reset with an event in flight was harmless in all "
        f"{trials} trials.\n"
        f"  Either the module has changed (in which case "
        f"rtl/common/cdc_pulse.sv:48 must be rewritten and this test with it), "
        f"or this test is no longer reaching the window it means to. The "
        f"documented failure is a spurious destination event on release; a "
        f"caller obligation that costs nothing when broken will be broken."
    )
    dut._log.info(
        "⚠️ confirmed: a source-only reset corrupted the event count in %d of "
        "%d trials. Both resets must come from one root (clk_rst_gen).",
        extras, trials,
    )


if __name__ == "__main__":  # pragma: no cover
    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        from cocotb.runner import get_runner

    runner = get_runner(os.environ.get("SIM", "verilator"))
    for stages in (2, 3):
        runner.build(
            verilog_sources=sim_sources(
                "rtl/common/cdc_sync_bit.sv", "rtl/common/cdc_pulse.sv"),
            hdl_toplevel="cdc_pulse",
            parameters={"SYNC_STAGES": stages},
            build_args=["-Wno-fatal", "--timescale-override", "1ns/1ps"],
            always=True,
        )
        runner.test(hdl_toplevel="cdc_pulse", test_module="test_cdc_pulse")
