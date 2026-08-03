"""Priority encoder — proves the new-best search is exact, and exactly on time.

INVARIANT PROVEN
    ``prio_encoder`` reports the EXTREME occupied index of its request vector —
    the lowest set bit with ``REVERSE=0``, the highest with ``REVERSE=1`` — for
    every input, at every N, in both directions; ``valid`` is low if and only if
    the request vector is all zeros; and the answer arrives after EXACTLY
    ``PIPELINE`` cycles, never more, never fewer, never data-dependent.

    Every ``PIPELINE`` setting produces the SAME answer for the same input.
    ``test_pipeline_equivalence_across_builds`` proves that across separate
    elaborations by replaying one deterministic vector list into each build and
    comparing the recorded results.

WHY IT MATTERS
    The order book maintains a per-symbol occupancy bitmap, one bit per price
    level, and priority-encodes it when a delete empties the current best level.
    That is the ONLY variable-latency operation on the tick-to-trade path
    (rtl/book/top_of_book.sv header), so two distinct things can go wrong and
    both are expensive:

      * **The index is wrong.**  The book then quotes against a level that is
        empty, or misses the level that is actually best.  With a two-level
        hierarchy the plausible failure is a boundary one — the first or last
        bit of a group, or a group index that is right while the sub-index is
        stale — which produces an answer that is *nearly* right and therefore
        survives casual inspection.  Hence: every single-bit position is tested
        exhaustively, including all 2048 of them at N=2048, and every group
        boundary is tested directly.

      * **The direction is wrong.**  A bid book's best is the HIGHEST occupied
        level, an ask book's the LOWEST.  Getting that backwards means quoting
        on the wrong side of the book.  It is also invisible in any test that
        only ever sets one bit, because with one bit set both directions agree.
        Hence ``test_direction_prefix_and_suffix``: at every position it
        presents a vector whose lowest and highest set bits are different and
        checks the DUT picks the end its parameters say it should.

    The bitmap is moving from 16 to 2048 bits (docs/ORDER-BOOK-REDESIGN.md §3.3)
    and the encoder is being restructured to survive that.  This file is the
    thing that says the restructure did not change the answers.

DUT
    rtl/common/prio_encoder.sv.  Ports: ``clk``, ``rst`` (sync, active high),
    ``req[N-1:0]`` -> ``idx[IDX_W-1:0]``, ``valid``; optional ``dir_rev``
    (runtime direction, honoured only when ``DYN_DIR=1``) and
    ``grp_sum_in[NGROUPS-1:0]`` (precomputed natural-order group summary,
    honoured only when ``SUMMARY_IN=1``).

    Geometry that CAN be read off the DUT is read off the DUT: N from
    ``len(dut.req)``, NGROUPS from ``len(dut.grp_sum_in)``.  Latency and
    direction cannot be, so they are DISCOVERED by probing the DUT and then
    cross-checked against ``$PE_PIPELINE`` / ``$PE_REVERSE`` when those are set.
    A build whose measured latency disagrees with the latency its parameters
    claim fails ``test_latency_is_exactly_pipeline_cycles`` — which is the point,
    because a silent extra cycle here is a silent extra cycle on the fast path.

RUNNING
    ``python3 test_prio_encoder.py`` sweeps the configuration matrix in
    ``CONFIG_MATRIX`` below, building and running each one.  Or drive a single
    configuration from a cocotb Makefile with TOPLEVEL=prio_encoder and the
    ``PE_*`` environment variables set to match the ``-G`` parameters.

    ⚠️ NOT YET EXECUTED.  There is no Verilator, no cocotb and no Python
       simulator installed in the environment this file was written in, so it
       has never been run and nothing here should be read as a passing result.
       It is written to be runnable, not reported as run.

    ⚠️ ``tb/common`` is not in ``scripts/Makefile``'s ``BLOCKS`` list, so
       ``make -C scripts sim`` does not pick this up today.  Adding ``common``
       to ``BLOCKS`` (and a cocotb Makefile in this directory) is a one-line
       change that belongs with whoever wires this into CI.
"""

from __future__ import annotations

import json
import os
import pathlib
import sys
import tempfile

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tb_util import (  # noqa: E402
    CLK_NS,
    cycles_to_ns,
    seed_note,
    seeded_rng,
    sim_sources,
    start_clock,
)


# =============================================================================
# Expected parameters.  Set by the runner below; only used to CHECK what the
# DUT actually does, never to substitute for it.
# =============================================================================

def _env_int(name: str) -> int | None:
    v = os.environ.get(name)
    return None if v is None or v == "" else int(v, 0)


EXP_PIPELINE = _env_int("PE_PIPELINE")
EXP_REVERSE = _env_int("PE_REVERSE")
EXP_GROUP_W = _env_int("PE_GROUP_W")
DYN_DIR = _env_int("PE_DYN_DIR") or 0
SUMMARY_IN = _env_int("PE_SUMMARY_IN") or 0

#: Where the cross-build equivalence results are accumulated.  One file per
#: (N, group width, direction); one entry per elaborated variant.
EQUIV_DIR = pathlib.Path(
    os.environ.get("PE_EQUIV_DIR", str(pathlib.Path(tempfile.gettempdir()) / "prio_equiv"))
)

#: Geometry discovered from the DUT on first bring-up.
GEO: dict[str, int] = {}


# =============================================================================
# Reference model — the golden answer, computed the obvious way
# =============================================================================

def ref_extreme(vec: int, n: int, reverse: int) -> int | None:
    """Index of the extreme set bit, or None when ``vec`` is zero.

    Deliberately written with Python's own bit primitives rather than a loop
    that mirrors the RTL's structure.  An oracle that reproduces the design's
    hierarchy would reproduce the design's boundary bugs along with it.
    """
    vec &= (1 << n) - 1
    if vec == 0:
        return None
    if reverse:
        return vec.bit_length() - 1
    return (vec & -vec).bit_length() - 1


def group_summary(vec: int, n: int, gw: int) -> int:
    """Natural-order per-group "any bit set" summary, as ``grp_sum_in`` wants it.

    ⚠️ NATURAL order — bit g means ``req[g*GROUP_W +: GROUP_W] != 0`` — even when
    the encoder is running reversed.  The DUT reverses the group order itself;
    a caller that pre-reverses this gets a confidently wrong best level.
    """
    ng = n // gw
    mask = (1 << gw) - 1
    out = 0
    for g in range(ng):
        if (vec >> (g * gw)) & mask:
            out |= 1 << g
    return out


def describe(vec: int, n: int) -> str:
    """Compact description of a request vector for a failure message."""
    pop = bin(vec).count("1")
    if pop == 0:
        return "req = 0 (empty)"
    if pop <= 8:
        return f"req = bits {sorted(i for i in range(n) if (vec >> i) & 1)}"
    lo = (vec & -vec).bit_length() - 1
    hi = vec.bit_length() - 1
    return f"req = {pop} bits set, lowest {lo}, highest {hi}"


# =============================================================================
# Bring-up, geometry discovery, and the per-vector driver
# =============================================================================

def _read(dut) -> tuple[int, int]:
    return int(dut.valid.value), int(dut.idx.value)


def _drive_inputs(dut, vec: int) -> None:
    """Apply a request vector and the matching group summary.

    The summary is driven on EVERY vector regardless of ``SUMMARY_IN``: when the
    DUT ignores it nothing happens, and when it honours it the RTL assertion that
    cross-checks ``grp_sum_in`` against ``req`` stays satisfied.  A testbench that
    drove it only sometimes would trip that assertion in the SUMMARY_IN builds.
    """
    dut.req.value = vec
    if hasattr(dut, "grp_sum_in"):
        dut.grp_sum_in.value = group_summary(vec, GEO["n"], GEO["gw"])


#: The task driving ``clk``.
#:
#: ⚠️ cocotb runs every test in this file inside ONE simulation, but it does NOT
#: let a task outlive the test that started it. cocotb 2.0 cancels every task a
#: test spawned the moment that test ends (``cocotb/_test.py``: "Set outcome and
#: cancel Tasks"). A clock started once, under an ``if not GEO`` first-test-only
#: guard, therefore stops the instant the first test passes: from the second
#: test onward nothing toggles ``clk``, Verilator runs out of scheduled events
#: one half-period later and exits, and cocotb reports every remaining test as
#: ``SimFailure: Simulator shut down prematurely`` at 0.00 ns of sim time.
#:
#: So the clock is (re)started per test, and any predecessor is cancelled first
#: so two tasks can never drive ``clk`` in the same timestep — the same shape
#: test_sync_fifo.py and test_counter_bank.py already use.
_CLOCK: list = []


def _start_clock(dut) -> None:
    while _CLOCK:
        task = _CLOCK.pop()
        if not task.done():
            task.cancel()
    _CLOCK.append(start_clock(dut, "clk", CLK_NS))


async def bringup(dut):
    """Clock, reset, and — once — discover the DUT's latency and direction."""
    _start_clock(dut)
    if not GEO:
        GEO["n"] = len(dut.req)
        GEO["idx_w"] = len(dut.idx)
        GEO["ng"] = len(dut.grp_sum_in) if hasattr(dut, "grp_sum_in") else 1
        GEO["gw"] = GEO["n"] // GEO["ng"]

    dut.rst.value = 1
    _drive_inputs(dut, 0)
    if hasattr(dut, "dir_rev"):
        dut.dir_rev.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    if "lat" not in GEO:
        GEO["lat"] = await _discover_latency(dut)
        GEO["rev"] = await _discover_direction(dut)
        dut._log.info(
            "geometry: N=%d NGROUPS=%d GROUP_W=%d IDX_W=%d  latency=%d cyc (%.1f ns)  "
            "direction=%s",
            GEO["n"], GEO["ng"], GEO["gw"], GEO["idx_w"], GEO["lat"],
            cycles_to_ns(GEO["lat"]),
            "highest set bit (REVERSE=1)" if GEO["rev"] else "lowest set bit (REVERSE=0)",
        )
    return GEO


async def _discover_latency(dut, max_lat: int = 6) -> int:
    """Cycles from applying a vector to the answer appearing.  Probe, don't assume.

    A single-bit vector is used because its answer is the same in both
    directions, so latency can be measured before the direction is known.
    """
    n = GEO["n"]
    probe = n // 2 + 1                       # not 0: idx must visibly change
    _drive_inputs(dut, 0)
    await ClockCycles(dut.clk, max_lat + 2)

    _drive_inputs(dut, 1 << probe)
    await ReadOnly()
    v, i = _read(dut)
    if v == 1 and i == probe:
        found = 0
    else:
        found = None
        for k in range(1, max_lat + 1):
            await RisingEdge(dut.clk)
            await ReadOnly()
            v, i = _read(dut)
            if v == 1 and i == probe:
                found = k
                break
    await RisingEdge(dut.clk)
    _drive_inputs(dut, 0)
    await ClockCycles(dut.clk, max_lat + 2)

    assert found is not None, (
        f"the DUT never produced the answer for a single set bit at index {probe} "
        f"within {max_lat} cycles. Either the encoder is broken outright or its "
        f"latency exceeds anything this module documents (PIPELINE is 0, 1 or 2)."
    )
    return found


async def _discover_direction(dut) -> int:
    """0 = reports the lowest set bit, 1 = reports the highest."""
    n = GEO["n"]
    _, i = await present(dut, (1 << (n - 1)) | 1)
    assert i in (0, n - 1), (
        f"with bits 0 and {n - 1} set the encoder returned idx={i}; it must return "
        f"one END of the vector, not something in between. The hierarchy is wrong."
    )
    return 1 if i == n - 1 else 0


async def present(dut, vec: int) -> tuple[int, int]:
    """Apply one vector, wait out the latency, return ``(valid, idx)``.

    Costs ``latency + 1`` cycles per vector.  The streaming case — a new vector
    every single cycle — is covered separately by
    :func:`test_back_to_back_every_cycle`.
    """
    lat = GEO["lat"]
    _drive_inputs(dut, vec)
    if lat == 0:
        await ReadOnly()
        out = _read(dut)
        await RisingEdge(dut.clk)
        return out
    for _ in range(lat):
        await RisingEdge(dut.clk)
    await ReadOnly()
    out = _read(dut)
    await RisingEdge(dut.clk)
    return out


async def check(dut, vec: int, why: str, seed: int | None = None) -> None:
    """Present one vector and assert the DUT matches the reference model."""
    n, rev = GEO["n"], GEO["rev"]
    exp = ref_extreme(vec, n, rev)
    v, i = await present(dut, vec)

    suffix = seed_note(seed) if seed is not None else ""
    direction = "highest" if rev else "lowest"

    if exp is None:
        assert v == 0, (
            f"PHANTOM RESULT [{why}]: valid=1 with an all-zero request vector, "
            f"idx={i}.\n"
            f"  `valid` is the ONLY thing that distinguishes 'index 0 is set' from "
            f"'nothing is set'. A consumer that trusts it now quotes a level that "
            f"does not exist.{suffix}"
        )
        return

    assert v == 1, (
        f"MISSED RESULT [{why}]: valid=0 but the request vector is non-empty.\n"
        f"  {describe(vec, n)}\n"
        f"  expected idx={exp} ({direction} set bit){suffix}"
    )
    assert i == exp, (
        f"WRONG INDEX [{why}]: encoder returned {i}, reference says {exp}.\n"
        f"  {describe(vec, n)}\n"
        f"  direction : {direction} set bit (REVERSE={rev})\n"
        f"  geometry  : N={n}, {GEO['ng']} groups x {GEO['gw']} bits\n"
        f"  group of returned index {i} = {i // GEO['gw']}, sub-index "
        f"{i % GEO['gw']}\n"
        f"  group of expected index {exp} = {exp // GEO['gw']}, sub-index "
        f"{exp % GEO['gw']}{suffix}"
    )


# =============================================================================
# 1. The empty case — the one that has no safe wrong answer
# =============================================================================

@cocotb.test()
async def test_all_zero_input_never_validates(dut):
    """``valid`` stays low for an all-zero request, indefinitely.

    ``idx`` reads 0 when nothing is set, which is indistinguishable from "index
    0 is set". Everything downstream depends on ``valid`` to tell the two apart,
    so this is checked continuously rather than once.
    """
    await bringup(dut)
    _drive_inputs(dut, 0)
    await ClockCycles(dut.clk, GEO["lat"] + 2)

    for cycle in range(200):
        await ReadOnly()
        v = int(dut.valid.value)
        assert v == 0, (
            f"valid asserted on cycle {cycle} with an all-zero request vector "
            f"(idx={int(dut.idx.value)}). The book would treat this as 'the new "
            f"best level is 0' and quote against an empty level."
        )
        await RisingEdge(dut.clk)


# =============================================================================
# 2. Exhaustive single-bit — every position, no sampling
# =============================================================================

@cocotb.test()
async def test_single_bit_exhaustive(dut):
    """One bit set at EVERY position: the answer must be that position.

    All N cases, including all 2048 at N=2048. This is cheap and this primitive
    is correctness-critical, so there is no reason to sample. It is the test that
    catches an off-by-one in the group/sub-index concatenation, which shows up at
    exactly one bit position per group and would survive random testing for a
    long time.
    """
    await bringup(dut)
    n = GEO["n"]
    for i in range(n):
        await check(dut, 1 << i, f"single bit at {i}")
    dut._log.info("exhaustive single-bit: all %d positions correct", n)


# =============================================================================
# 3. Direction — the failure that single-bit tests structurally cannot see
# =============================================================================

@cocotb.test()
async def test_direction_prefix_and_suffix(dut):
    """At every position, a vector whose two ends differ — the DUT must pick one.

    ``suffix(i)``  = bits i..N-1 set  -> lowest is i,   highest is N-1
    ``prefix(i)``  = bits 0..i   set  -> lowest is 0,   highest is i

    Between them, every index in the vector is the correct answer for one
    direction and the wrong answer for the other, at every position. A direction
    inversion cannot pass this, and a single-bit test cannot fail it.
    """
    await bringup(dut)
    n = GEO["n"]
    full = (1 << n) - 1
    for i in range(n):
        await check(dut, (full >> i) << i, f"suffix from {i}")
        await check(dut, (1 << (i + 1)) - 1, f"prefix through {i}")
    dut._log.info(
        "direction: %d prefix + %d suffix vectors correct for %s-set-bit mode",
        n, n, "highest" if GEO["rev"] else "lowest",
    )


# =============================================================================
# 4. Group boundaries — where a two-level encoder actually breaks
# =============================================================================

@cocotb.test()
async def test_group_boundary_patterns(dut):
    """Directed patterns straddling every group boundary.

    The hierarchy splits N into NGROUPS x GROUP_W. Every plausible structural bug
    lives at a boundary: the last bit of a group encoded as the first bit of the
    next, a group summary computed off by one, a sub-index selected from the
    neighbouring group. Random vectors hit these eventually; naming them makes
    the failure legible when it happens.
    """
    await bringup(dut)
    n, gw, ng = GEO["n"], GEO["gw"], GEO["ng"]

    for g in range(ng):
        base = g * gw
        first, last = base, base + gw - 1

        await check(dut, 1 << first, f"first bit of group {g}")
        await check(dut, 1 << last, f"last bit of group {g}")
        # Whole group set: the answer must stay inside this group.
        await check(dut, ((1 << gw) - 1) << base, f"all of group {g}")

        if g + 1 < ng:
            nxt = base + gw
            # Straddling pair: one bit either side of the boundary. The two
            # directions must disagree about which one wins, and each must be
            # right.
            await check(dut, (1 << last) | (1 << nxt), f"straddle {last}|{nxt}")
            await check(dut, (1 << first) | (1 << nxt), f"straddle {first}|{nxt}")

    # One bit in the first group and one in the last: the widest possible span.
    await check(dut, 1 | (1 << (n - 1)), "widest span")
    # Every group occupied at its own first bit, then at its own last bit.
    every_first = sum(1 << (g * gw) for g in range(ng))
    every_last = sum(1 << (g * gw + gw - 1) for g in range(ng))
    await check(dut, every_first, "first bit of every group")
    await check(dut, every_last, "last bit of every group")
    dut._log.info("group boundaries: %d groups x %d bits all correct", ng, gw)


# =============================================================================
# 5. Random multi-bit, across densities
# =============================================================================

@cocotb.test()
async def test_random_multi_bit(dut):
    """Constrained-random vectors at several densities, deterministic seed.

    Directed patterns find the shapes somebody thought of. Density is swept
    explicitly because a uniformly random 2048-bit vector is ~50 % ones and its
    answer is almost always in the first (or last) group — which exercises none
    of the group-selection logic. The sparse buckets are the interesting ones.
    """
    await bringup(dut)
    rng, seed = seeded_rng(dut, "prio.random")
    n = GEO["n"]

    n_vec = int(os.environ.get("VECTORS", "600"))
    densities = [1, 2, 3, 4, 8, 16, 64, 256]
    checked = 0

    for _ in range(n_vec):
        k = rng.choice(densities)
        k = min(k, n)
        vec = 0
        for _ in range(k):
            vec |= 1 << rng.randrange(n)
        await check(dut, vec, f"random {k}-bit", seed)
        checked += 1

    # The extremes, explicitly: all ones, and each half.
    full = (1 << n) - 1
    await check(dut, full, "all ones", seed)
    await check(dut, full >> (n // 2), "low half only", seed)
    await check(dut, (full >> (n // 2)) << (n // 2), "high half only", seed)
    checked += 3

    dut._log.info("random multi-bit: %d vectors correct", checked)


# =============================================================================
# 6. Latency — a fixed, documented, bounded number of cycles
# =============================================================================

@cocotb.test()
async def test_latency_is_exactly_pipeline_cycles(dut):
    """The answer takes EXACTLY PIPELINE cycles, for every input.

    Equality across many different inputs, not ``<=``: the book's whole claim is
    that the new-best search is BOUNDED, and a stage that is sometimes faster is
    jitter on the tick-to-trade path (CLAUDE.md §5.8). If the module ever became
    data-dependent — a search loop instead of a reduction tree — this is what
    would catch it.

    Also cross-checks the measured latency against ``$PE_PIPELINE``, so a build
    that quietly gained a pipeline stage fails here rather than silently costing
    6.4 ns per delete-the-best event.
    """
    await bringup(dut)
    n, lat = GEO["n"], GEO["lat"]

    if EXP_PIPELINE is not None:
        assert lat == EXP_PIPELINE, (
            f"LATENCY CONTRACT BROKEN: the build was elaborated with "
            f"PIPELINE={EXP_PIPELINE} but the measured latency is {lat} cycle(s) "
            f"({cycles_to_ns(lat):.1f} ns vs {cycles_to_ns(EXP_PIPELINE):.1f} ns).\n"
            f"  rtl/common/prio_encoder.sv's header states the cycle count IS the "
            f"PIPELINE value. If that changed, the header and rtl/fpga_top.sv's "
            f"latency table change in the same commit (CLAUDE.md §3)."
        )
    if EXP_REVERSE is not None:
        assert GEO["rev"] == EXP_REVERSE, (
            f"DIRECTION CONTRACT BROKEN: built with REVERSE={EXP_REVERSE} but the "
            f"DUT reports the {'highest' if GEO['rev'] else 'lowest'} set bit. "
            f"A bid book wired to an ask-direction encoder quotes the wrong side."
        )
    if EXP_GROUP_W is not None:
        expect_gw = min(EXP_GROUP_W, n // 2)
        assert GEO["gw"] == expect_gw, (
            f"GEOMETRY MISMATCH: built with GROUP_W={EXP_GROUP_W} (clamped to "
            f"{expect_gw} at N={n}) but the DUT has {GEO['ng']} groups of "
            f"{GEO['gw']}."
        )

    # Measure, repeatedly, over inputs whose answers land in different groups.
    observed: set[int] = set()
    probes = sorted({
        x for x in (0, 1, n // 4, n // 2, n - 2, n - 1, GEO["gw"], GEO["gw"] - 1)
        if 0 <= x < n
    })
    for p in probes:
        _drive_inputs(dut, 0)
        await ClockCycles(dut.clk, lat + 3)
        await ReadOnly()
        assert int(dut.valid.value) == 0, "encoder did not settle back to invalid"
        await RisingEdge(dut.clk)               # leave ReadOnly before driving

        _drive_inputs(dut, 1 << p)
        cycles = 0
        await ReadOnly()
        got = _read(dut)
        while got != (1, p):
            await RisingEdge(dut.clk)
            cycles += 1
            assert cycles <= lat + 4, (
                f"answer for a single bit at {p} never appeared "
                f"({cycles} cycles); expected it at cycle {lat}"
            )
            await ReadOnly()
            got = _read(dut)
        observed.add(cycles)
        await RisingEdge(dut.clk)

    assert observed == {lat}, (
        f"JITTER: latency varied across inputs — observed {sorted(observed)} "
        f"cycles, expected exactly {{{lat}}}.\n"
        f"  This module must be fixed-latency. The book budgets ONE bounded extra "
        f"cycle for the delete-the-best rescan; a data-dependent encoder turns "
        f"that bound into a hope."
    )
    dut._log.info(
        "latency is exactly %d cycle(s) = %.1f ns across %d probe positions",
        lat, cycles_to_ns(lat), len(probes),
    )


# =============================================================================
# 7. Throughput — a new vector every cycle
# =============================================================================

@cocotb.test()
async def test_back_to_back_every_cycle(dut):
    """A new request vector on EVERY cycle produces one correct answer per cycle.

    Only meaningful for the pipelined builds, where the outputs come out of
    registers. It is the test that catches a pipeline stage that forgot to carry
    something alongside the data — the direction bit, say, or one group's
    sub-index — because a stale companion signal is invisible when vectors are
    presented one at a time with idle cycles between them.
    """
    await bringup(dut)
    lat = GEO["lat"]
    if lat == 0:
        dut._log.info("PIPELINE=0 build: combinational, no pipeline to stress. Skipped.")
        return

    rng, seed = seeded_rng(dut, "prio.b2b")
    n = GEO["n"]
    n_vec = int(os.environ.get("VECTORS", "600"))

    seq = [0]
    for _ in range(n_vec):
        k = rng.choice([0, 1, 1, 2, 3, 8, 64])
        vec = 0
        for _ in range(min(k, n)):
            vec |= 1 << rng.randrange(n)
        seq.append(vec)

    # The monitor runs as its own coroutine so the driver never has to write a
    # signal from the ReadOnly phase, which cocotb forbids. Sampling in ReadOnly
    # after edge k is safe even though the driver has already applied seq[k+1] by
    # then: at every PIPELINE >= 1 the entire output cone hangs off the stage-1
    # registers, so `req` is not in it.
    samples: list[tuple[int, int]] = []

    async def _monitor():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            samples.append(_read(dut))

    mon = cocotb.start_soon(_monitor())

    # Sampled after edge k, the output corresponds to seq[k - (lat - 1)].
    n_iter = len(seq) + (lat - 1)
    for k in range(n_iter):
        _drive_inputs(dut, seq[k] if k < len(seq) else 0)
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    mon.kill()

    mismatches = []
    for k, got in enumerate(samples):
        src = k - (lat - 1)
        if src < 0 or src >= len(seq):
            continue
        exp = ref_extreme(seq[src], n, GEO["rev"])
        want = (0, None) if exp is None else (1, exp)
        if got[0] != want[0] or (want[0] and got[1] != want[1]):
            mismatches.append((src, seq[src], got, want))
        if len(mismatches) >= 5:
            break

    # If the whole stream is shifted rather than corrupted, say so explicitly.
    # A uniform shift is a testbench alignment bug or a changed pipeline depth;
    # scattered mismatches are a real data bug. Telling them apart in the message
    # saves the next person an hour with a waveform.
    hint = ""
    if mismatches:
        for shift in (-2, -1, 1, 2):
            ok = True
            for k, got in enumerate(samples):
                src = k - (lat - 1) + shift
                if src < 0 or src >= len(seq):
                    continue
                exp = ref_extreme(seq[src], n, GEO["rev"])
                if got[0] != int(exp is not None) or (exp is not None and got[1] != exp):
                    ok = False
                    break
            if ok:
                hint = (
                    f"\n  ⚠️ The ENTIRE stream matches at a shift of {shift:+d} "
                    f"cycles, i.e. the observed depth is {lat - shift} rather than "
                    f"the {lat} this test measured. That is a uniform latency "
                    f"change, not data corruption — check the pipeline depth and "
                    f"the module header's LATENCY table together."
                )
                break

    assert not mismatches, (
        "BACK-TO-BACK STREAM CORRUPTED — the pipeline does not hold one result "
        f"per cycle. First {len(mismatches)} divergence(s):\n"
        + "\n".join(
            f"  vector #{s}: {describe(v, n)}\n"
            f"    got      valid={g[0]} idx={g[1]}\n"
            f"    expected valid={w[0]} idx={w[1]}"
            for s, v, g, w in mismatches
        )
        + hint
        + seed_note(seed)
    )
    dut._log.info("back-to-back: %d vectors, one correct result per cycle", len(seq))


# =============================================================================
# 8. Reset
# =============================================================================

@cocotb.test()
async def test_reset_forces_valid_low(dut):
    """Reset drives ``valid`` low and no pre-reset answer survives it.

    Only the pipelined builds hold state. A stale ``valid`` surviving reset would
    hand the book a "new best level" derived from the occupancy bitmap of a
    previous session.
    """
    await bringup(dut)
    if GEO["lat"] == 0:
        dut._log.info("PIPELINE=0 build: no state to reset. Skipped.")
        return

    n = GEO["n"]
    stale = 1 << (n // 3)
    fresh_pos = (n // 3) + 1 if (n // 3) + 1 < n else 0

    for hold in range(1, 5):
        _drive_inputs(dut, stale)
        await ClockCycles(dut.clk, GEO["lat"] + 2)

        dut.rst.value = 1
        _drive_inputs(dut, 0)
        await ClockCycles(dut.clk, hold)
        await ReadOnly()
        assert int(dut.valid.value) == 0, (
            f"valid still asserted during reset (held {hold} cycle(s)) — a "
            f"pre-reset best level would be injected into a freshly re-armed book."
        )
        await RisingEdge(dut.clk)
        dut.rst.value = 0
        await RisingEdge(dut.clk)

        await ReadOnly()
        assert int(dut.valid.value) == 0, (
            f"valid asserted on the first cycle after reset release (held {hold}) "
            f"with an all-zero request vector."
        )
        await RisingEdge(dut.clk)

        await check(dut, 1 << fresh_pos, f"first vector after reset (hold={hold})")


# =============================================================================
# 9. Runtime direction (DYN_DIR builds only)
# =============================================================================

@cocotb.test()
async def test_runtime_direction(dut):
    """``dir_rev`` flips the direction at runtime, and only when DYN_DIR=1.

    The point of the parameter/port pair is that callers never bit-reverse a
    2048-bit vector themselves. This checks the module does it for them, in both
    settings, and that the reflect is exact at every position rather than only
    at the ends.
    """
    await bringup(dut)
    if not DYN_DIR:
        dut._log.info("DYN_DIR=0 build: dir_rev is ignored by construction. Skipped.")
        return

    rng, seed = seeded_rng(dut, "prio.dyndir")
    n, lat, base_rev = GEO["n"], GEO["lat"], GEO["rev"]

    async def present_dir(vec: int, d: int) -> tuple[int, int]:
        dut.dir_rev.value = d
        _drive_inputs(dut, vec)
        if lat == 0:
            await ReadOnly()
            out = _read(dut)
            await RisingEdge(dut.clk)
            return out
        for _ in range(lat):
            await RisingEdge(dut.clk)
        await ReadOnly()
        out = _read(dut)
        await RisingEdge(dut.clk)
        return out

    vectors = [1 | (1 << (n - 1))]
    for i in range(0, n, max(1, n // 64)):
        j = (i + n // 2) % n
        if i != j:
            vectors.append((1 << i) | (1 << j))
    for _ in range(128):
        vec = 0
        for _ in range(rng.choice([2, 3, 5, 17])):
            vec |= 1 << rng.randrange(n)
        vectors.append(vec)

    for vec in vectors:
        for d in (0, 1):
            eff_rev = base_rev ^ d
            exp = ref_extreme(vec, n, eff_rev)
            v, i = await present_dir(vec, d)
            assert (v == 1) == (exp is not None) and (exp is None or i == exp), (
                f"RUNTIME DIRECTION WRONG: dir_rev={d} with REVERSE={base_rev} "
                f"means 'report the {'highest' if eff_rev else 'lowest'} set bit'.\n"
                f"  {describe(vec, n)}\n"
                f"  got      valid={v} idx={i}\n"
                f"  expected valid={int(exp is not None)} idx={exp}{seed_note(seed)}"
            )
    dut.dir_rev.value = 0
    await RisingEdge(dut.clk)
    dut._log.info("runtime direction: %d vectors x 2 directions correct", len(vectors))


# =============================================================================
# 10. Cross-build equivalence: every variant gives the same answers
# =============================================================================

def _equiv_file(n: int, gw: int, rev: int) -> pathlib.Path:
    return EQUIV_DIR / f"prio_n{n}_g{gw}_rev{rev}.json"


def _variant_label() -> str:
    p = "?" if EXP_PIPELINE is None else str(EXP_PIPELINE)
    return f"PIPELINE={p},DYN_DIR={DYN_DIR},SUMMARY_IN={SUMMARY_IN}"


def _equiv_vectors(n: int) -> list[int]:
    """The same deterministic vector list in every build, derived from N alone."""
    import random

    rng = random.Random(0xE9C0DE ^ n)
    vecs = [0, 1, 1 << (n - 1), (1 << n) - 1]
    for i in range(0, n, max(1, n // 32)):
        vecs.append(1 << i)
    for _ in range(384):
        vec = 0
        for _ in range(rng.choice([1, 2, 3, 5, 9, 33])):
            vec |= 1 << rng.randrange(n)
        vecs.append(vec)
    return vecs


@cocotb.test()
async def test_pipeline_equivalence_across_builds(dut):
    """Every PIPELINE / DYN_DIR / SUMMARY_IN variant agrees, vector for vector.

    PIPELINE is an elaboration parameter, so the variants cannot be compared
    inside one simulation. Instead each build replays the SAME deterministic
    vector list — derived from N alone, so it is identical across builds — and
    records its results under ``$PE_EQUIV_DIR``. Every later build compares
    against every earlier one for the same (N, GROUP_W, direction).

    The first build to run for a given geometry has nothing to compare against
    and says so. Run the sweep in ``__main__`` (or ``make`` the whole matrix) and
    the comparison is real from the second variant onward.

    Note that agreement with the reference model is already asserted vector by
    vector everywhere above, and in SVA inside the RTL. This test exists because
    "the pipelined build agrees with the combinational build" is the property the
    order book is actually relying on when it changes PIPELINE, and it deserves
    to be checked directly rather than inferred.
    """
    await bringup(dut)
    n, gw, rev = GEO["n"], GEO["gw"], GEO["rev"]

    results = []
    for vec in _equiv_vectors(n):
        v, i = await present(dut, vec)
        results.append([v, i if v else 0])

    path = _equiv_file(n, gw, rev)
    path.parent.mkdir(parents=True, exist_ok=True)
    store: dict[str, list] = {}
    if path.is_file():
        try:
            store = json.loads(path.read_text())
        except (ValueError, OSError):
            store = {}

    label = _variant_label()
    peers = {k: v for k, v in store.items() if k != label}

    divergences = []
    vectors = _equiv_vectors(n)
    for peer_label, peer in peers.items():
        if len(peer) != len(results):
            divergences.append(
                f"  {peer_label}: recorded {len(peer)} results, this build produced "
                f"{len(results)} — the vector lists disagree, which means "
                f"{path} is stale. Delete it and re-run the sweep."
            )
            continue
        for k, (a, b) in enumerate(zip(results, peer)):
            if a != b:
                divergences.append(
                    f"  vector #{k}: {describe(vectors[k], n)}\n"
                    f"    {label:<40} valid={a[0]} idx={a[1]}\n"
                    f"    {peer_label:<40} valid={b[0]} idx={b[1]}"
                )
            if len(divergences) >= 5:
                break

    store[label] = results
    path.write_text(json.dumps(store))

    assert not divergences, (
        "PIPELINE VARIANTS DISAGREE — the same request vector produced different "
        "answers in different elaborations of prio_encoder. The pipeline registers "
        "are supposed to be latency, not semantics.\n"
        f"  geometry: N={n}, {GEO['ng']} groups x {gw}, "
        f"{'highest' if rev else 'lowest'} set bit\n"
        f"  record  : {path}\n" + "\n".join(divergences)
    )

    if not peers:
        dut._log.info(
            "equivalence: first variant recorded for N=%d/GROUP_W=%d/REVERSE=%d "
            "(%s). Nothing to compare against yet — run the full sweep.",
            n, gw, rev, label,
        )
    else:
        dut._log.info(
            "equivalence: %s agrees with %d other variant(s) over %d vectors",
            label, len(peers), len(results),
        )


# =============================================================================
# Runner — sweeps the configuration matrix
# =============================================================================

#: (N, GROUP_W, PIPELINE, REVERSE, DYN_DIR, SUMMARY_IN)
#:
#: The PIPELINE 0/1/2 rows at each N share a geometry, so the equivalence test
#: compares them against each other. N=2048 is the configuration the order-book
#: redesign needs (docs/ORDER-BOOK-REDESIGN.md §3.3); N=16 is what
#: rtl/book/top_of_book.sv instantiates today and must keep working.
CONFIG_MATRIX = [
    # N,   GROUP_W, PIPELINE, REVERSE, DYN_DIR, SUMMARY_IN
    (16,   32,      0,        0,       0,       0),   # today's top_of_book (ask)
    (16,   32,      0,        1,       0,       0),   # today's top_of_book (bid)
    (16,   32,      1,        1,       0,       0),
    (256,  32,      0,        0,       0,       0),
    (256,  32,      1,        0,       0,       0),
    (256,  32,      2,        0,       0,       0),
    (256,  32,      1,        1,       0,       0),
    (2048, 32,      0,        0,       0,       0),
    (2048, 32,      1,        0,       0,       0),
    (2048, 32,      2,        0,       0,       0),
    (2048, 32,      0,        1,       0,       0),
    (2048, 32,      1,        1,       0,       0),   # ⚠️ what the bid book should use
    (2048, 32,      2,        1,       0,       0),
    (2048, 32,      1,        0,       0,       1),   # precomputed group summary
    (2048, 32,      1,        0,       1,       0),   # runtime direction
    (4096, 64,      1,        0,       0,       0),   # the documented upper bound
]


def _run_one(cfg, equiv_dir):  # pragma: no cover - exercised by __main__ only
    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        from cocotb.runner import get_runner

    n, gw, pipeline, reverse, dyn_dir, summary_in = cfg
    tag = f"n{n}_g{gw}_p{pipeline}_r{reverse}_d{dyn_dir}_s{summary_in}"
    build_dir = pathlib.Path("sim_build") / f"prio_{tag}"

    env = {
        "PE_N": str(n),
        "PE_GROUP_W": str(gw),
        "PE_PIPELINE": str(pipeline),
        "PE_REVERSE": str(reverse),
        "PE_DYN_DIR": str(dyn_dir),
        "PE_SUMMARY_IN": str(summary_in),
        "PE_EQUIV_DIR": str(equiv_dir),
    }
    os.environ.update(env)

    # `--assert` turns on the SVA inside the RTL, so a cocotb run checks the
    # module's own invariants as well as this file's. Set PE_ASSERT=0 if a
    # simulator rejects one of the assertion constructs — the Python checks here
    # are independent of the SVA and cover every stated requirement on their own.
    build_args = ["-Wno-fatal"]
    if os.environ.get("PE_ASSERT", "1") != "0":
        build_args.append("--assert")

    runner = get_runner(os.environ.get("SIM", "verilator"))
    runner.build(
        verilog_sources=sim_sources("rtl/common/prio_encoder.sv"),
        hdl_toplevel="prio_encoder",
        parameters={
            "N": n,
            "GROUP_W": gw,
            "PIPELINE": pipeline,
            "REVERSE": reverse,
            "DYN_DIR": dyn_dir,
            "SUMMARY_IN": summary_in,
        },
        build_args=build_args,
        build_dir=str(build_dir),
        always=True,
    )
    runner.test(
        hdl_toplevel="prio_encoder",
        test_module="test_prio_encoder",
        build_dir=str(build_dir),
        extra_env=env,
    )


if __name__ == "__main__":  # pragma: no cover
    # One equivalence record set per sweep, so a stale file from a previous run
    # cannot make two builds look like they agree when they were never compared.
    equiv = pathlib.Path(tempfile.mkdtemp(prefix="prio_equiv_"))
    only = os.environ.get("PE_ONLY")
    for _cfg in CONFIG_MATRIX:
        tag = "x".join(str(x) for x in _cfg)
        if only and only not in tag:
            continue
        print(f"=== prio_encoder: N={_cfg[0]} GROUP_W={_cfg[1]} PIPELINE={_cfg[2]} "
              f"REVERSE={_cfg[3]} DYN_DIR={_cfg[4]} SUMMARY_IN={_cfg[5]} ===")
        _run_one(_cfg, equiv)
    print(f"equivalence records: {equiv}")
