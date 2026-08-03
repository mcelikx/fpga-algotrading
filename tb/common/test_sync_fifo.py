"""Single-clock FIFO — proves the flags are exact and the error flags are sticky.

INVARIANT PROVEN
    ``sync_fifo`` is an exact, lossless elastic buffer within one clock domain:

      * exactly ``DEPTH`` words fit — not one more, not one fewer;
      * ``full`` and ``empty`` agree with the true occupancy on EVERY cycle,
        with no lag in either direction (unlike ``async_fifo``, which is
        allowed to be conservative because its view has crossed a synchronizer);
      * no loss, no duplication, no reordering under any push/pop pattern,
        including simultaneous push and pop sustained indefinitely;
      * ``overflow`` and ``underflow`` latch on the FIRST occurrence and stay
        latched until ``rst`` or ``err_clr`` — they are the only record that a
        transient drop happened between two host polls;
      * ``high_water`` equals the true maximum occupancy exactly, is monotonic,
        and is cleared only by ``rst``;
      * ⚠️ at ``full``, a same-cycle read does NOT open a slot for the same-cycle
        write.  That is a consequence of registered flags, it is what the RTL
        does, and it is pinned here so it cannot change unnoticed.

WHY IT MATTERS
    ``sync_fifo`` absorbs a burst of ITCH messages behind a slower consumer and
    queues outbound orders behind the TX MAC.  Its interface and read timing
    deliberately match ``async_fifo`` so the two are interchangeable at a call
    site — which is exactly why it is in this CDC test suite.  ⚠️ It is NOT a
    CDC primitive (rtl/common/sync_fifo.sv:15): if the two ends are on different
    clocks, ``async_fifo`` is the only correct answer, and a reviewer who cannot
    tell the two apart at a call site will substitute the wrong one.  Sharing a
    port shape is a convenience with a sharp edge, and the sharp edge is worth a
    sentence in this docstring every time somebody reads it.

    The sticky error flags carry more weight than they look like they do
    (rtl/common/sync_fifo.sv:29, CLAUDE.md §5.7): "a transient overflow between
    two host polls is exactly the event you must not miss — it is a dropped
    market-data message or a dropped order.  Silent failure is the worst failure
    mode in this domain."  A flag that self-clears turns a dropped order into
    nothing at all.

DUT
    rtl/common/sync_fifo.sv.  Ports: ``clk``, ``rst``, ``wr_data``/``wr_en``/
    ``full``/``almost_full``, ``rd_data``/``rd_en``/``empty``/``rd_valid``,
    ``high_water``/``overflow``/``underflow``/``err_clr``.

TESTBENCH TIMING DISCIPLINE
    Stimulus is driven on the FALLING edge.  ``full``, ``empty``, ``rd_valid``
    and the sticky flags are all registered, so they are constant between rising
    edges: sampling and deciding at the midpoint means the testbench's model of
    what the DUT will do is exact, and it never presents ``wr_en`` while
    ``full`` except in the tests that mean to.

RUNNING
    TOPLEVEL=sync_fifo, or ``python test_sync_fifo.py``.
"""

from __future__ import annotations

import os
import pathlib
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tb_util import CLK_NS, seed_note, seeded_rng, sim_sources  # noqa: E402


def dut_depth(dut) -> int:
    """DEPTH from the width of ``high_water`` (``[$clog2(DEPTH):0]``)."""
    return 1 << (len(dut.high_water) - 1)


def dut_width(dut) -> int:
    return len(dut.wr_data)


def almost_full_level(dut) -> int:
    return int(os.environ.get("ALMOST_FULL_LEVEL", dut_depth(dut) - 2))


def payload(i: int, w: int) -> int:
    half = max(1, w // 2)
    m = (1 << half) - 1
    return (((~i) & m) << half) | (i & m)


def decode(v: int, w: int) -> tuple[int, bool]:
    half = max(1, w // 2)
    m = (1 << half) - 1
    lo, hi = v & m, (v >> half) & m
    return lo, hi == ((~lo) & m)


#: cocotb runs every test in this file inside ONE simulation, so ``bringup``
#: must not leave a second task toggling ``clk``.
_CLOCK: list = []


def _start_clock(dut):
    while _CLOCK:
        _CLOCK.pop().kill()
    _CLOCK.append(cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start()))


async def bringup(dut):
    _start_clock(dut)
    dut.wr_en.value = 0
    dut.rd_en.value = 0
    dut.wr_data.value = 0
    dut.err_clr.value = 0
    # ⚠️ `rst` must be high BEFORE the very first clock edge. `empty` has no
    # FPGA configuration value in the RTL, so out of configuration it reads 0
    # while the FIFO holds nothing, and the module's own assertion at
    # rtl/common/sync_fifo.sv:196 ("empty flag disagrees with count") fires on
    # the first edge unless `disable iff (rst)` is already covering it. Reported
    # upward as a (minor, fail-open) power-up observation.
    dut.rst.value = 1
    # ⚠️ Thereafter `rst` moves only at FALLING edges, here and everywhere in
    # this file. Writing it in the same timestep as a rising edge leaves it
    # undetermined whether that edge saw the old or the new value — and the RTL
    # samples `rst` both in its always_ff and in the `disable iff (rst)` of its
    # own assertions, so a raced write can make the two disagree and the module
    # then reports a violation it did not commit.
    for _ in range(6):
        await FallingEdge(dut.clk)
    dut.rst.value = 0
    await FallingEdge(dut.clk)
    return dut_depth(dut), dut_width(dut)


async def drain(dut, recvd: list[int], w: int, target: int,
                limit: int | None = None) -> None:
    """Drain from the CURRENT falling edge onward until ``target`` words are out.

    ⚠️ Collects BEFORE advancing.  A drain loop that starts with
    ``await FallingEdge`` skips whatever ``rd_valid`` is already presented at the
    moment it is entered — which is exactly one word, every time, and it reads
    like a FIFO that lost a word rather than like a testbench that never looked.
    """
    limit = limit or (target * 8 + 64)
    for _ in range(limit):
        if int(dut.rd_valid.value):
            v, ok = decode(int(dut.rd_data.value), w)
            assert ok, f"torn word 0x{v:x} out of a single-clock FIFO"
            recvd.append(v)
        empty = int(dut.empty.value)
        dut.rd_en.value = int(not empty)
        if len(recvd) >= target and empty:
            break
        await FallingEdge(dut.clk)
    dut.rd_en.value = 0


# =============================================================================
# 1. Capacity and flag exactness
# =============================================================================

@cocotb.test()
async def test_exactly_depth_words_fit(dut):
    """DEPTH words go in, the DEPTH+1'th is refused, DEPTH words come out.

    An off-by-one in either direction is expensive in a different way: one too
    many silently overwrites a queued order, one too few costs buffering on a
    path that has none to spare.
    """
    depth, w = await bringup(dut)

    accepted = 0
    for i in range(depth + 4):
        await FallingEdge(dut.clk)
        if int(dut.full.value):
            dut.wr_en.value = 0
            continue
        dut.wr_en.value = 1
        dut.wr_data.value = payload(i, w)
        accepted += 1
    await FallingEdge(dut.clk)
    dut.wr_en.value = 0

    assert accepted == depth, (
        f"{accepted} writes accepted into a DEPTH={depth} sync_fifo. More than "
        f"DEPTH means `full` let a write overwrite a queued word; fewer means "
        f"capacity is being thrown away."
    )
    assert int(dut.full.value) == 1, "full is low after DEPTH writes"
    assert int(dut.empty.value) == 0, "empty is high with DEPTH words inside"
    assert int(dut.almost_full.value) == 1, (
        "full without almost_full (rtl/common/sync_fifo.sv:200)")
    assert int(dut.high_water.value) == depth, (
        f"high_water is {int(dut.high_water.value)} after filling to {depth}")

    got: list[int] = []
    for _ in range(depth * 4 + 16):
        await FallingEdge(dut.clk)
        if int(dut.rd_valid.value):
            v, ok = decode(int(dut.rd_data.value), w)
            assert ok, f"torn word 0x{v:x} out of a single-clock FIFO"
            got.append(v)
        empty = int(dut.empty.value)
        dut.rd_en.value = int(not empty)
        if len(got) >= depth and empty:
            break
    dut.rd_en.value = 0
    assert got == list(range(depth)), (
        f"drain returned {got[:8]}..., expected 0..{depth - 1}")
    assert int(dut.empty.value) == 1, "empty low after the FIFO was drained"
    assert int(dut.overflow.value) == 0 and int(dut.underflow.value) == 0, (
        "an error flag set during a perfectly legal fill/drain")


@cocotb.test()
async def test_flags_agree_with_occupancy_on_every_cycle(dut):
    """``full``/``empty``/``almost_full`` match a cycle-exact occupancy model.

    ``async_fifo``'s flags are allowed to lag — its occupancy view has been
    through a synchronizer and is deliberately conservative.  ``sync_fifo`` has
    no such excuse: ``full``, ``empty`` and ``almost_full`` are registered from
    ``count_d``, so they describe the occupancy AT THIS CYCLE, exactly.  This
    test holds them to that, cycle by cycle, under random traffic.

    A lagging ``empty`` on a single-clock FIFO would cost a cycle of latency on
    every message boundary in the feed path.
    """
    rng, seed = seeded_rng(dut, "sync_fifo.flags")
    depth, w = await bringup(dut)
    level = almost_full_level(dut)

    occ = 0
    word = 0
    sent: list[int] = []
    recvd: list[int] = []
    for cyc in range(4000):
        await FallingEdge(dut.clk)
        f, e, af = (int(dut.full.value), int(dut.empty.value),
                    int(dut.almost_full.value))
        assert f == (occ == depth), (
            f"cycle {cyc}: full={f} at true occupancy {occ} (DEPTH={depth})"
            + seed_note(seed))
        assert e == (occ == 0), (
            f"cycle {cyc}: empty={e} at true occupancy {occ}" + seed_note(seed))
        assert af == (occ >= level), (
            f"cycle {cyc}: almost_full={af} at true occupancy {occ} "
            f"(ALMOST_FULL_LEVEL={level})" + seed_note(seed))
        assert not (f and e), f"cycle {cyc}: full and empty together"

        if int(dut.rd_valid.value):
            v, ok = decode(int(dut.rd_data.value), w)
            assert ok, f"cycle {cyc}: torn word" + seed_note(seed)
            recvd.append(v)

        push = (not f) and rng.random() < 0.55
        pop = (not e) and rng.random() < 0.5
        dut.wr_en.value = int(push)
        dut.rd_en.value = int(pop)
        if push:
            dut.wr_data.value = payload(word, w)
            sent.append(word)
            word += 1
        occ += int(push) - int(pop)

    # ⚠️ Step to the NEXT falling edge before de-asserting wr_en. Clearing it at
    # the same falling edge the loop's last iteration drove it cancels that
    # final write before the rising edge ever samples it — the model then
    # believes in a word the FIFO never received.
    await FallingEdge(dut.clk)
    dut.wr_en.value = 0
    await drain(dut, recvd, w, len(sent))

    assert recvd == sent, (
        f"random push/pop soak lost, duplicated or reordered a word: "
        f"{len(sent)} in, {len(recvd)} out; first divergence at index "
        f"{next((i for i, (a, b) in enumerate(zip(recvd, sent)) if a != b), 'n/a')}"
        + seed_note(seed))
    assert int(dut.overflow.value) == 0 and int(dut.underflow.value) == 0, (
        "an error flag set although the testbench never wrote when full nor "
        "read when empty — the flags are firing on legal traffic"
        + seed_note(seed))
    dut._log.info("flags exact for 4000 cycles, %d words through", len(sent))


@cocotb.test()
async def test_simultaneous_push_and_pop_sustains_one_word_per_cycle(dut):
    """Push and pop every cycle, forever: occupancy holds, throughput is 1/cycle.

    The header claims "one write and one read per cycle, concurrently"
    (rtl/common/sync_fifo.sv:21).  This is the shape the order queue runs at
    when the TX MAC is keeping up, and a FIFO that quietly halves it turns into
    a latency source under load rather than the elastic buffer it is meant to be.
    """
    depth, w = await bringup(dut)

    # Prime it half full.
    half = depth // 2
    word = 0
    for _ in range(half):
        await FallingEdge(dut.clk)
        dut.wr_en.value = 1
        dut.wr_data.value = payload(word, w)
        word += 1
    # ⚠️ De-assert before leaving the priming loop. `wr_en` left high with the
    # last word still on `wr_data` writes that word a SECOND time on the next
    # rising edge — a testbench-manufactured duplicate that then reads exactly
    # like a FIFO bug.
    await FallingEdge(dut.clk)
    dut.wr_en.value = 0
    await FallingEdge(dut.clk)

    sent = list(range(half))
    recvd: list[int] = []
    n = 500
    for _ in range(n):
        await FallingEdge(dut.clk)
        assert not int(dut.full.value), "full during steady-state 1-in-1-out"
        assert not int(dut.empty.value), "empty during steady-state 1-in-1-out"
        if int(dut.rd_valid.value):
            v, ok = decode(int(dut.rd_data.value), w)
            assert ok, "torn word"
            recvd.append(v)
        dut.wr_en.value = 1
        dut.rd_en.value = 1
        dut.wr_data.value = payload(word, w)
        sent.append(word)
        word += 1

    await FallingEdge(dut.clk)
    dut.wr_en.value = 0
    await drain(dut, recvd, w, len(sent))

    assert recvd == sent, (
        f"simultaneous push/pop corrupted the stream: {len(sent)} in, "
        f"{len(recvd)} out; first divergence at index "
        f"{next((i for i, (a, b) in enumerate(zip(recvd, sent)) if a != b), 'n/a')}")
    assert int(dut.overflow.value) == 0 and int(dut.underflow.value) == 0
    dut._log.info("%d cycles of simultaneous push+pop, zero bubbles", n)


@cocotb.test()
async def test_write_at_full_is_dropped_even_with_a_simultaneous_read(dut):
    """⚠️ PINS A REAL BEHAVIOUR: a read does not free a slot for the same cycle.

    ``full`` is a registered flag and ``push = wr_en && !full``, so on the cycle
    the FIFO is full a concurrent ``rd_en`` does NOT let the concurrent ``wr_en``
    through.  The write is dropped and ``overflow`` latches; the slot becomes
    usable one cycle later.

    This is consistent with the header — "OVERFLOW DROPS THE WRITE, IT DOES NOT
    CORRUPT THE FIFO" (rtl/common/sync_fifo.sv:37) — and it is the normal
    behaviour of a registered-flag FIFO.  It is pinned because it is exactly the
    kind of one-cycle detail a caller assumes the other way round: a producer
    that treats "the consumer is reading, so there must be room" as true will
    lose one beat per full-cycle, and will lose it silently apart from a sticky
    flag nobody polls.

    The property asserted is the important half: the drop is CLEAN.  Nothing
    already queued is disturbed, the order is preserved, and the loss is
    visible in ``overflow``.
    """
    depth, w = await bringup(dut)

    accepted: list[int] = []
    for i in range(depth):
        await FallingEdge(dut.clk)
        dut.wr_en.value = 1
        dut.wr_data.value = payload(i, w)
        accepted.append(i)
    await FallingEdge(dut.clk)
    assert int(dut.full.value) == 1, "not full after DEPTH writes"

    # Now: full, and we push AND pop on the same cycle for several cycles.
    recvd: list[int] = []
    idx = depth
    drops = 0
    for _ in range(8):
        f = int(dut.full.value)
        if int(dut.rd_valid.value):
            v, ok = decode(int(dut.rd_data.value), w)
            assert ok, "torn word"
            recvd.append(v)
        dut.wr_en.value = 1
        dut.wr_data.value = payload(idx, w)
        dut.rd_en.value = 1
        if f:
            drops += 1          # the write on this cycle will be refused
        else:
            accepted.append(idx)
        idx += 1
        await FallingEdge(dut.clk)

    dut.wr_en.value = 0
    await drain(dut, recvd, w, len(accepted))

    assert drops >= 1, (
        "the FIFO accepted a write on the very cycle it reported `full`, even "
        "with no read having retired yet. If that is now intended, "
        "rtl/common/sync_fifo.sv:37 and every producer's assumption change "
        "with it."
    )
    assert recvd == accepted, (
        f"dropping a write at full disturbed the queued data.\n"
        f"  accepted : {accepted} ({len(accepted)})\n"
        f"  received : {recvd} ({len(recvd)})\n"
        f"  drops    : {drops}\n"
        f"  A drop must never reorder or corrupt what is already inside — that "
        f"is the difference between a lost message and a corrupted book."
    )
    assert int(dut.overflow.value) == 1, (
        f"{drops} write(s) were dropped at full but the sticky overflow flag is "
        f"clear. A silent drop is the worst failure mode in this domain "
        f"(CLAUDE.md §5.7)."
    )
    dut._log.info(
        "⚠️ %d same-cycle read+write at full: writes dropped cleanly, overflow set",
        drops)


# =============================================================================
# 2. Sticky error telemetry
# =============================================================================

@cocotb.test()
async def test_overflow_and_underflow_are_sticky(dut):
    """The error flags latch on the FIRST event and never self-clear.

    ``rtl/common/sync_fifo.sv:29`` — the flags exist because "a transient
    overflow between two host polls is exactly the event you must not miss."
    Three properties, all asserted:

      * they are clear after reset and stay clear under legal traffic;
      * one event sets them, and they stay set through hundreds of subsequent
        legal cycles (this is what makes a poll every few milliseconds
        sufficient);
      * only ``err_clr`` or ``rst`` clears them, and ``err_clr`` clears both.

    The flags say IT HAPPENED, not HOW OFTEN — pair them with a ``counter_bank``
    entry if the rate matters.  That is a design note, not a defect, and this
    test does not pretend otherwise.
    """
    rng, seed = seeded_rng(dut, "sync_fifo.sticky")
    depth, w = await bringup(dut)

    assert int(dut.overflow.value) == 0 and int(dut.underflow.value) == 0, (
        "an error flag is set out of reset")

    # --- underflow: read an empty FIFO exactly once.
    dut.rd_en.value = 1
    await FallingEdge(dut.clk)
    dut.rd_en.value = 0
    await FallingEdge(dut.clk)
    assert int(dut.underflow.value) == 1, (
        "underflow did not latch on a read of an empty FIFO")
    assert int(dut.rd_valid.value) == 0, (
        "rd_valid asserted for a read of an empty FIFO — the consumer would "
        "act on stale rd_data (rtl/common/sync_fifo.sv:38)")
    assert int(dut.overflow.value) == 0, "underflow set overflow too"

    for _ in range(300):
        await FallingEdge(dut.clk)
        assert int(dut.underflow.value) == 1, (
            "sticky underflow self-cleared" + seed_note(seed))

    # --- overflow: fill and then offer one more.
    for i in range(depth):
        await FallingEdge(dut.clk)
        dut.wr_en.value = 1
        dut.wr_data.value = payload(i, w)
    await FallingEdge(dut.clk)
    assert int(dut.full.value) == 1
    dut.wr_en.value = 1
    dut.wr_data.value = payload(0xDEAD, w)
    await FallingEdge(dut.clk)
    dut.wr_en.value = 0
    await FallingEdge(dut.clk)
    assert int(dut.overflow.value) == 1, (
        "overflow did not latch on a write to a full FIFO")

    for _ in range(300):
        await FallingEdge(dut.clk)
        assert int(dut.overflow.value) == 1 and int(dut.underflow.value) == 1, (
            "a sticky error flag self-cleared" + seed_note(seed))

    # --- err_clr is a single-cycle strobe and clears BOTH.
    dut.err_clr.value = 1
    await FallingEdge(dut.clk)
    dut.err_clr.value = 0
    await FallingEdge(dut.clk)
    assert int(dut.overflow.value) == 0 and int(dut.underflow.value) == 0, (
        "err_clr did not clear both sticky flags")

    # And they stay clear under legal traffic.
    for _ in range(200):
        await FallingEdge(dut.clk)
        e, f = int(dut.empty.value), int(dut.full.value)
        dut.rd_en.value = int((not e) and rng.random() < 0.6)
        dut.wr_en.value = int((not f) and rng.random() < 0.4)
        dut.wr_data.value = payload(rng.randrange(1 << 16), w)
        assert int(dut.overflow.value) == 0 and int(dut.underflow.value) == 0, (
            "an error flag set during legal traffic after err_clr"
            + seed_note(seed))
    dut.wr_en.value = 0
    dut.rd_en.value = 0

    # --- rst clears them too. Drain to empty first so the read really underflows
    # (at small DEPTH the legal-traffic loop above can leave words behind).
    for _ in range(depth * 8 + 32):
        await FallingEdge(dut.clk)
        empty = int(dut.empty.value)
        dut.rd_en.value = int(not empty)
        if empty:
            break
    dut.rd_en.value = 0
    await FallingEdge(dut.clk)
    dut.rd_en.value = 1
    await FallingEdge(dut.clk)
    dut.rd_en.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert int(dut.underflow.value) == 1, "underflow did not re-latch"
    dut.rst.value = 1
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    await FallingEdge(dut.clk)
    assert int(dut.underflow.value) == 0 and int(dut.overflow.value) == 0, (
        "rst did not clear the sticky flags")
    dut._log.info("sticky overflow/underflow, err_clr and rst all behave")


@cocotb.test()
async def test_high_water_is_the_true_maximum(dut):
    """``high_water`` equals the true peak occupancy, exactly, and is monotonic.

    Single clock, so there is no synchronizer lag to hide behind: this must be
    an equality.  The number tells operations whether the buffer is sized right
    (CLAUDE.md §5.7).  An under-report is the reassuring lie that stops anyone
    resizing it before the busy morning.
    """
    rng, seed = seeded_rng(dut, "sync_fifo.hw")
    depth, w = await bringup(dut)

    assert int(dut.high_water.value) == 0, "high_water non-zero out of reset"

    peak = 0
    prev = 0
    targets = sorted({1, 2, 3, depth // 2 or 1, depth - 1, depth,
                      depth // 4 or 1})
    for target in targets:
        # Fill to `target`, then drain completely.
        for i in range(target):
            await FallingEdge(dut.clk)
            assert not int(dut.full.value), "full early"
            dut.wr_en.value = 1
            dut.wr_data.value = payload(i, w)
        await FallingEdge(dut.clk)
        dut.wr_en.value = 0
        peak = max(peak, target)

        hw = int(dut.high_water.value)
        assert hw == peak, (
            f"high_water is {hw} after filling to {target} (running peak "
            f"{peak}).\n  Single-clock occupancy is exact — this must be an "
            f"equality, not a bound." + seed_note(seed))
        assert hw >= prev, f"high_water decreased: {prev} -> {hw}"
        prev = hw

        drained = 0
        for _ in range(depth * 4 + 32):
            await FallingEdge(dut.clk)
            if int(dut.rd_valid.value):
                drained += 1
            empty = int(dut.empty.value)
            dut.rd_en.value = int(not empty)
            if drained >= target and empty:
                break
        dut.rd_en.value = 0
        await FallingEdge(dut.clk)
        assert int(dut.high_water.value) == peak, (
            "high_water moved during a drain — it is a maximum, not an occupancy")

    dut.rst.value = 1
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    await FallingEdge(dut.clk)
    assert int(dut.high_water.value) == 0, "rst did not clear high_water"
    dut._log.info("high_water exact across %d fill depths, peak %d",
                  len(targets), peak)


@cocotb.test()
async def test_almost_full_threshold(dut):
    """``almost_full`` asserts at ``ALMOST_FULL_LEVEL`` and implies room remains.

    The producer's early-warning line.  On a queue in front of the TX MAC this
    is where the order gateway should stop accepting new orders rather than
    start dropping them, so the exact threshold and the exact headroom are both
    part of the interface.
    """
    depth, w = await bringup(dut)
    level = almost_full_level(dut)

    first_af = None
    accepted = 0
    for i in range(depth + 2):
        await FallingEdge(dut.clk)
        if int(dut.almost_full.value) and first_af is None:
            first_af = accepted
        if int(dut.full.value):
            dut.wr_en.value = 0
            continue
        dut.wr_en.value = 1
        dut.wr_data.value = payload(i, w)
        accepted += 1
    await FallingEdge(dut.clk)
    dut.wr_en.value = 0

    assert first_af == level, (
        f"almost_full first observed at occupancy {first_af}, expected "
        f"ALMOST_FULL_LEVEL={level} (rtl/common/sync_fifo.sv:46)")
    assert accepted - first_af == depth - level, (
        f"headroom after almost_full is {accepted - first_af}, expected "
        f"{depth - level}")
    dut._log.info("almost_full at %d of %d, headroom %d",
                  first_af, depth, depth - level)


@cocotb.test()
async def test_rd_valid_contract(dut):
    """``rd_valid`` follows exactly one cycle after an accepted pop, never else.

    Same read timing as ``async_fifo`` by design (rtl/common/sync_fifo.sv:13),
    which is what makes the two interchangeable at a call site.  A consumer
    written against one and dropped in front of the other must see identical
    timing, or the substitution silently costs or gains a cycle.
    """
    rng, seed = seeded_rng(dut, "sync_fifo.rdvalid")
    depth, w = await bringup(dut)

    # Prime.
    for i in range(depth):
        await FallingEdge(dut.clk)
        dut.wr_en.value = 1
        dut.wr_data.value = payload(i, w)
    await FallingEdge(dut.clk)
    dut.wr_en.value = 0

    expect_valid = False
    got = 0
    for cyc in range(400):
        await FallingEdge(dut.clk)
        v = int(dut.rd_valid.value)
        assert v == int(expect_valid), (
            f"cycle {cyc}: rd_valid={v}, expected {int(expect_valid)} "
            f"(a pop {'did' if expect_valid else 'did not'} happen last cycle)"
            + seed_note(seed))
        if v:
            got += 1
        e = int(dut.empty.value)
        pop = (not e) and rng.random() < 0.5
        dut.rd_en.value = int(pop)
        expect_valid = pop
    dut.rd_en.value = 0
    assert got == depth, f"{got} words came out of a FIFO holding {depth}"
    dut._log.info("rd_valid tracked %d pops exactly", got)


@cocotb.test()
async def test_reset_discards_contents_and_clears_telemetry(dut):
    """A reset mid-traffic leaves an empty FIFO with no survivor.

    A queued outbound order that survives a reset is an order sent into a
    session the venue no longer has open.
    """
    rng, seed = seeded_rng(dut, "sync_fifo.reset")
    depth, w = await bringup(dut)

    for trial in range(6):
        n = rng.randrange(1, depth + 1)
        for i in range(n):
            await FallingEdge(dut.clk)
            dut.wr_en.value = 1
            dut.wr_data.value = payload(0xAA0000 + i, w)
        await FallingEdge(dut.clk)
        dut.wr_en.value = 0
        dut.rd_en.value = int(rng.random() < 0.5)

        dut.rst.value = 1
        # >= 2 cycles: a ONE-cycle reset trips the module's own high-water
        # assertion, which is pinned separately at the end of this file.
        for _ in range(rng.randrange(2, 5)):
            await FallingEdge(dut.clk)
        dut.rst.value = 0
        dut.rd_en.value = 0
        await FallingEdge(dut.clk)

        assert int(dut.empty.value) == 1, (
            f"trial {trial}: not empty after reset" + seed_note(seed))
        assert int(dut.full.value) == 0, f"trial {trial}: full after reset"
        assert int(dut.high_water.value) == 0, (
            f"trial {trial}: high_water survived reset")
        assert int(dut.rd_valid.value) == 0, (
            f"trial {trial}: rd_valid high after reset")
        assert int(dut.overflow.value) == 0 and int(dut.underflow.value) == 0

        marker = 0xBB0000 + trial
        await FallingEdge(dut.clk)
        dut.wr_en.value = 1
        dut.wr_data.value = payload(marker, w)
        await FallingEdge(dut.clk)
        dut.wr_en.value = 0
        dut.rd_en.value = 1
        await FallingEdge(dut.clk)
        dut.rd_en.value = 0
        assert int(dut.rd_valid.value) == 1, (
            f"trial {trial}: no data after a post-reset write")
        v, ok = decode(int(dut.rd_data.value), w)
        assert ok and v == marker, (
            f"trial {trial}: first post-reset word was {v} "
            f"(complement {'ok' if ok else 'BROKEN'}), expected {marker} — a "
            f"pre-reset word survived" + seed_note(seed))
        await FallingEdge(dut.clk)
    dut._log.info("6 mid-traffic resets: no survivors, telemetry cleared")


# =============================================================================
# ⚠️ XFAIL-BY-OBSERVATION — THIS TEST FOUND AN RTL ASSERTION BUG.
#    IT IS LAST BECAUSE THE RTL CALLS $stop, WHICH ABORTS THE SIMULATOR.
# =============================================================================

@cocotb.test()
async def test_one_cycle_reset_trips_the_high_water_assertion(dut):
    """⚠️ A reset asserted for exactly ONE clock edge makes ``sync_fifo`` report
    a violation it did not commit.

    THIS FAILURE IS AN RTL BUG, NOT A TESTBENCH BUG.  The logic is right — the
    high-water mark really is cleared to 0 by the reset, which is what it is
    supposed to do.  What fires is the module's own assertion at
    ``rtl/common/sync_fifo.sv:227``:

        assert property (@(posedge clk) disable iff (rst)
            high_water >= $past(high_water))
            else $error("sync_fifo: high-water mark decreased");

    With ``rst`` high for a single clock edge, the first RE-ENABLED evaluation
    compares ``high_water`` (now 0) against ``$past(high_water)`` (still the
    pre-reset value, because the only intervening cycle was disabled).  0 is
    less than 5, so the module reports that its high-water mark decreased.
    Hold reset for two or more edges and it never fires — which is what makes
    this precise rather than a vague "assertions are noisy" complaint.

    MEASURED, by bisection on the reset width (see the report):
        rst held 1 falling edge  -> assertion FIRES, $stop, simulator aborts
        rst held 2 falling edges -> clean
        rst held 3 falling edges -> clean
        rst held 4 falling edges -> clean

    ⚠️ WHY IT MATTERS.  A one-cycle synchronous reset is legal on this port —
    nothing in the module's header requires a minimum width — and a
    ``counter_bank``-style ``clr_all`` strobe next door is explicitly a
    single-cycle strobe.  More importantly the SAME ``X >= $past(X)`` +
    ``disable iff`` shape appears in three other modules:

        rtl/common/async_fifo.sv:353     wr_high_water >= $past(wr_high_water)
        rtl/common/counter_bank.sv:195   cnt_q[c]      >= $past(cnt_q[c])
        rtl/common/fixed_arbiter.sv:191  starve_cnt[a] >= $past(starve_cnt[a])

    so if this is real it is systemic, and every one of those guards a counter
    whose whole job is to be believed (CLAUDE.md §5.7).  An assertion that cries
    wolf on a legal reset is how a regression full of expected errors trains
    people to stop reading them.

    Suggested fix (RTL is owned elsewhere; NOT applied here): widen the disable
    to cover the recovery cycle, e.g. ``disable iff (rst || $past(rst))``.
    """
    depth, w = await bringup(dut)

    dut._log.error(
        "⚠️ EXPECTED FAILURE AHEAD — RTL ASSERTION BUG, NOT A TESTBENCH BUG. "
        "rtl/common/sync_fifo.sv:227 compares high_water against "
        "$past(high_water) with `disable iff (rst)`; after a ONE-cycle reset "
        "the $past value is still the pre-reset one, so clearing the mark reads "
        "as the mark decreasing. Two or more reset cycles are clean. The $error "
        "calls $stop, which aborts the simulator — that is why this test is "
        "LAST in the file."
    )

    n_fill = min(5, depth)
    for i in range(n_fill):
        await FallingEdge(dut.clk)
        dut.wr_en.value = 1
        dut.wr_data.value = payload(i, w)
    await FallingEdge(dut.clk)
    dut.wr_en.value = 0
    await FallingEdge(dut.clk)
    before = int(dut.high_water.value)
    assert before == n_fill, (
        f"expected high_water {n_fill} before the reset, got {before}")

    dut.rst.value = 1
    await FallingEdge(dut.clk)          # exactly one rising edge sees rst
    dut.rst.value = 0
    for _ in range(6):
        await FallingEdge(dut.clk)

    assert int(dut.high_water.value) == 0, (
        "high_water was not cleared by the one-cycle reset")
    dut._log.info(
        "one-cycle reset survived without the RTL assertion firing — the bug "
        "described in this test's docstring has been FIXED; delete the test's "
        "xfail framing and fold it back into the reset test.")


if __name__ == "__main__":  # pragma: no cover
    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        from cocotb.runner import get_runner

    runner = get_runner(os.environ.get("SIM", "verilator"))
    # ⚠️ DEPTH=2 is the module's own documented minimum (rtl/common/sync_fifo.sv:45
    #    "MUST be a power of two, >= 2") but CANNOT BE ELABORATED with the default
    #    ALMOST_FULL_LEVEL: the default is `DEPTH - 2`, which is 0 at DEPTH=2, and
    #    the guard at rtl/common/sync_fifo.sv:180 rejects 0 and calls $fatal.
    #    Reported upward as an RTL finding; DEPTH=4 is used here instead so the
    #    small-depth edge cases still get covered. If the default is fixed to
    #    something like `(DEPTH > 2) ? DEPTH - 2 : 1`, add DEPTH=2 back to this list.
    for w, depth in ((64, 16), (64, 4), (32, 8), (64, 64)):
        runner.build(
            verilog_sources=sim_sources("rtl/common/sync_fifo.sv"),
            hdl_toplevel="sync_fifo",
            parameters={"W": w, "DEPTH": depth},
            build_args=["-Wno-fatal", "--timescale-override", "1ns/1ps"],
            always=True,
        )
        runner.test(hdl_toplevel="sync_fifo", test_module="test_sync_fifo")
