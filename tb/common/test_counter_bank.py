"""Counter bank — proves the telemetry that every "we counted it" claim rests on.

INVARIANT PROVEN
    ``counter_bank`` counts EXACTLY, and never lies about it:

      * ``cnt[i]`` equals the number of cycles ``incr[i]`` was asserted.  Exact
        equality, over randomized traffic, for every counter independently and
        simultaneously.
      * The read port never disturbs a count (sticky mode) and never loses an
        increment that races it (clear-on-read mode reloads to 1, not 0).
      * ``rdata`` appears exactly one cycle after ``ren``, qualified by
        ``rvalid``; a read returns the value as of BEFORE the same cycle's
        increment.
      * Counters SATURATE at all-ones with a sticky ``saturated`` flag; they
        never wrap.
      * ⚠️ A counter cannot wrap within its documented span — both the width
        (48 bits, matching ``trading_pkg::CYCLE_CNT_W``) and the span table in
        the RTL header are checked against the arithmetic, so narrowing ``W``
        or editing the table fails here.

WHY IT MATTERS
    CLAUDE.md §5.7 is quoted in the RTL header because it is not negotiable:
    "Every drop, error, and rejected order is counted in a readable register.
    Silent failure is the worst failure mode in this domain."  Every drop
    counter, every risk rejection reason, every arbitration stall in this design
    lands in one of these.  The whole apparatus of "we drop and count rather
    than back-pressure" (CLAUDE.md §5.4) is only as good as the counting.

    Two failure modes, and the second is the reason this file exists:

      * **A counter that misses events.**  The dashboard under-reports drops.
        Somebody concludes the feed path is healthy.
      * ⚠️ **A counter that WRAPS.**  This is worse, and the header says why
        (rtl/common/counter_bank.sv:33): "A counter that wraps during a trading
        day is worse than no counter: it reads as healthy."  At 156.25 MHz
        incrementing every cycle, a 32-bit counter wraps in 27.5 SECONDS and a
        40-bit counter in under 2 hours — both inside one session.  48 bits
        gives 20.8 days.  That table is load-bearing and
        ``test_documented_span_table_is_arithmetically_true`` re-derives every
        row of it, so a well-meant "we don't need 48 bits here" cannot land
        without failing a test.

DUT
    rtl/common/counter_bank.sv.  Ports: ``clk``, ``rst``, ``incr[N-1:0]``,
    ``ren``/``raddr``/``rdata``/``rvalid``, ``clr_all``, ``saturated[N-1:0]``.
    Parameters ``N``, ``W``, ``CLEAR_ON_READ``, ``SATURATE``.

    ``CLEAR_ON_READ`` is detected BEHAVIOURALLY (read a known-nonzero counter
    twice) rather than from an environment variable, so the test cannot be told
    the wrong thing about the build it is actually running against.

RUNNING
    TOPLEVEL=counter_bank, or ``python test_counter_bank.py``, which builds the
    shipping configuration plus the narrow-width and clear-on-read variants.
"""

from __future__ import annotations

import os
import pathlib
import re
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tb_util import (  # noqa: E402
    CLK_NS,
    CORE_CLK_MHZ,
    CYCLE_CNT_W,
    REPO_ROOT,
    seed_note,
    seeded_rng,
    sim_sources,
)

RTL = REPO_ROOT / "rtl" / "common" / "counter_bank.sv"


def n_counters(dut) -> int:
    return len(dut.incr)


def width(dut) -> int:
    return len(dut.rdata)


#: cocotb runs every test in this file inside ONE simulation, so ``bringup``
#: must not leave a second task toggling ``clk``.
_CLOCK: list = []


def _start_clock(dut):
    while _CLOCK:
        _CLOCK.pop().kill()
    _CLOCK.append(cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start()))


async def bringup(dut):
    _start_clock(dut)
    dut.incr.value = 0
    dut.ren.value = 0
    dut.raddr.value = 0
    dut.clr_all.value = 0
    dut.rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    return n_counters(dut), width(dut)


async def read_counter(dut, idx: int) -> int:
    """One read: ``ren``+``raddr`` for a cycle, ``rdata``/``rvalid`` the next.

    Driven and sampled on the FALLING edge.  ``rdata`` and ``rvalid`` are
    registered, so they are constant between rising edges and the midpoint is
    the settled sample point; it also leaves the simulation writable, which the
    ReadOnly phase does not.

    Also asserts the read timing contract every single time it is used, so that
    contract is covered by every other test in this file as a side effect.
    """
    await FallingEdge(dut.clk)
    dut.raddr.value = idx
    dut.ren.value = 1
    await FallingEdge(dut.clk)      # the rising edge in between sampled ren=1
    dut.ren.value = 0
    assert int(dut.rvalid.value) == 1, (
        f"rvalid low one cycle after ren (counter {idx}) — the read port "
        f"contract is 1 cycle, ren -> rdata/rvalid "
        f"(rtl/common/counter_bank.sv:21)")
    val = int(dut.rdata.value)
    await FallingEdge(dut.clk)      # the next rising edge sampled ren=0
    assert int(dut.rvalid.value) == 0, (
        "rvalid stayed high for a second cycle after a single-cycle ren")
    return val


async def read_all(dut, n: int) -> list[int]:
    return [await read_counter(dut, i) for i in range(n)]


async def detect_clear_on_read(dut, n: int) -> bool:
    """Behavioural probe: does a read zero the counter?

    Uses counter 0, restores nothing, and is always called before the real test
    body sets up its own state.  Probing beats trusting a parameter passed in an
    environment variable, which is exactly the kind of thing that gets stale.
    """
    dut.incr.value = 1 << 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.incr.value = 0
    await RisingEdge(dut.clk)
    first = await read_counter(dut, 0)
    second = await read_counter(dut, 0)
    assert first == 4, (
        f"counter 0 reads {first} after exactly 4 increment cycles — the bank "
        f"is not counting correctly, before any mode question arises")
    return second == 0


async def clear_all(dut, n: int) -> None:
    dut.incr.value = 0
    dut.clr_all.value = 1
    await RisingEdge(dut.clk)
    dut.clr_all.value = 0
    await RisingEdge(dut.clk)


# =============================================================================
# 1. Counting
# =============================================================================

@cocotb.test()
async def test_every_increment_is_counted(dut):
    """``cnt[i]`` == the number of cycles ``incr[i]`` was high.  Exactly.

    Randomized, independent per-counter increment patterns, run simultaneously
    so that a bank which shares an adder or mis-indexes ``raddr`` shows up as a
    cross-counter discrepancy rather than as a plausible total.

    This is the property every "we drop and count" claim in the design reduces
    to (CLAUDE.md §5.7).  If the count is approximate, the drop-and-count
    strategy is just dropping.
    """
    rng, seed = seeded_rng(dut, "counter_bank.count")
    n, w = await bringup(dut)
    cor = await detect_clear_on_read(dut, n)
    await clear_all(dut, n)

    # The model must SATURATE exactly as the DUT does, or a narrow-W build
    # reports a "miscount" that is really the module doing its job
    # (rtl/common/counter_bank.sv:41 — saturate, never wrap).
    maxv = (1 << w) - 1
    model = [0] * n
    cycles = 3000
    for _ in range(cycles):
        vec = 0
        for i in range(n):
            if rng.random() < 0.3:
                vec |= 1 << i
                model[i] = min(model[i] + 1, maxv)
        dut.incr.value = vec
        await RisingEdge(dut.clk)
    dut.incr.value = 0
    await RisingEdge(dut.clk)

    if cor:
        dut._log.info("CLEAR_ON_READ build: reading destructively, once each")
    actual = await read_all(dut, n)
    assert actual == model, (
        f"counter bank miscounted over {cycles} cycles.\n"
        f"  model : {model}\n"
        f"  dut   : {actual}\n"
        f"  delta : {[a - m for a, m in zip(actual, model)]}\n"
        f"  A telemetry counter that is nearly right is a dashboard that is "
        f"confidently wrong (CLAUDE.md §5.7)." + seed_note(seed))
    if maxv > cycles:
        assert int(dut.saturated.value) == 0, (
            f"a counter reported saturation after only {cycles} increments in a "
            f"{w}-bit bank (max {maxv})")
    dut._log.info("N=%d W=%d: %d cycles counted exactly", n, w, cycles)


@cocotb.test()
async def test_read_returns_the_value_before_this_cycles_increment(dut):
    """A read racing an increment returns the PRE-increment value.

    ``rtl/common/counter_bank.sv:143`` — "The read samples the value BEFORE any
    clear-on-read takes effect, because both are non-blocking assignments
    evaluated against the same old value."  The same applies to a plain
    increment: ``rdata`` is ``cnt_q[raddr]``, the value as of the start of the
    cycle.

    Pinned because the host computes DELTAS between polls.  If a read sometimes
    included and sometimes excluded a same-cycle increment, consecutive deltas
    would be off by one in an unpredictable direction — and a rate that is
    occasionally wrong by one is indistinguishable from a genuine event.
    """
    n, w = await bringup(dut)
    cor = await detect_clear_on_read(dut, n)
    await clear_all(dut, n)

    # Put a known value in counter 1, then read it while it is still counting.
    dut.incr.value = 1 << 1
    for _ in range(10):
        await RisingEdge(dut.clk)
    # Read on a cycle that also increments.
    dut.raddr.value = 1
    dut.ren.value = 1
    await RisingEdge(dut.clk)          # this edge: 11th increment AND the read
    dut.ren.value = 0
    dut.incr.value = 0
    await FallingEdge(dut.clk)
    assert int(dut.rvalid.value) == 1
    got = int(dut.rdata.value)
    await RisingEdge(dut.clk)

    assert got == 10, (
        f"a read issued on the same cycle as the 11th increment returned {got}, "
        f"expected the pre-increment value 10.\n"
        f"  Deltas between host polls depend on this being deterministic."
    )
    if not cor:
        after = await read_counter(dut, 1)
        assert after == 11, (
            f"counter 1 reads {after} after 11 increment cycles and one read; "
            f"the read must not disturb the count in sticky mode")
    dut._log.info("read/increment race resolves to the pre-increment value")


@cocotb.test()
async def test_sticky_mode_reads_are_non_destructive(dut):
    """STICKY (the default): reading returns the count and leaves it alone.

    ``rtl/common/counter_bank.sv:48`` — sticky is the default "FOR A REASON":
    the host computes deltas, which is robust to a missed poll, robust to two
    readers, and leaves the absolute value meaningful after an incident.  A
    build that quietly became clear-on-read would give a second reader zeroes
    and destroy the incident record.

    Stands down on a clear-on-read build; the complementary test covers that.
    """
    n, w = await bringup(dut)
    if await detect_clear_on_read(dut, n):
        dut._log.info("CLEAR_ON_READ build — sticky test not applicable")
        return
    await clear_all(dut, n)

    dut.incr.value = 0b101 & ((1 << n) - 1)
    for _ in range(37):
        await RisingEdge(dut.clk)
    dut.incr.value = 0
    await RisingEdge(dut.clk)

    for attempt in range(5):
        v0 = await read_counter(dut, 0)
        assert v0 == 37, (
            f"read #{attempt} of counter 0 returned {v0}, expected 37 — a "
            f"sticky counter changed value because it was read")
    dut._log.info("sticky: 5 consecutive reads all returned 37")


@cocotb.test()
async def test_clear_on_read_does_not_lose_a_racing_increment(dut):
    """CLEAR-ON-READ: a read zeroes the count, but an increment that lands on
    the same cycle survives as 1.

    ``rtl/common/counter_bank.sv:58`` — "In clear-on-read mode an increment
    arriving on the same cycle as the read is NOT lost — the counter reloads to
    1, not to 0."  That single edge case is the difference between a rate meter
    that is exact and one that silently under-reports by one event per poll,
    forever, at exactly the moments the system is busiest.

    Also re-states the mode's real hazard: the count now lives in exactly one
    place, so a second reader or a dropped PCIe completion destroys data that
    cannot be recovered.  Only use it where a single trusted poller is
    guaranteed.

    Stands down on a sticky build.
    """
    n, w = await bringup(dut)
    if not await detect_clear_on_read(dut, n):
        dut._log.info("sticky build — clear-on-read test not applicable")
        return
    await clear_all(dut, n)

    # Accumulate, then read WITHOUT a concurrent increment: must return to 0.
    dut.incr.value = 1 << 0
    for _ in range(12):
        await RisingEdge(dut.clk)
    dut.incr.value = 0
    await RisingEdge(dut.clk)
    v = await read_counter(dut, 0)
    assert v == 12, f"clear-on-read returned {v}, expected 12"
    v = await read_counter(dut, 0)
    assert v == 0, f"counter did not clear on read: second read returned {v}"

    # Now the racing case: read on a cycle that also increments.
    dut.incr.value = 1 << 0
    for _ in range(9):
        await RisingEdge(dut.clk)
    dut.raddr.value = 0
    dut.ren.value = 1
    await RisingEdge(dut.clk)          # 10th increment AND the read
    dut.ren.value = 0
    dut.incr.value = 0
    await FallingEdge(dut.clk)
    got = int(dut.rdata.value)
    await RisingEdge(dut.clk)
    assert got == 9, f"racing read returned {got}, expected 9"

    after = await read_counter(dut, 0)
    assert after == 1, (
        f"after a read that raced an increment the counter reads {after}, "
        f"expected 1.\n"
        f"  0 would mean the racing event was destroyed by the poll — a rate "
        f"meter that under-reports by one event per poll "
        f"(rtl/common/counter_bank.sv:58)."
    )
    dut._log.info("clear-on-read: racing increment preserved as 1")


# =============================================================================
# 2. Saturation and the wrap guarantee
# =============================================================================

@cocotb.test()
async def test_saturation_holds_and_flags_and_never_wraps(dut):
    """The counter pins at all-ones and sets a sticky ``saturated`` bit.

    ``rtl/common/counter_bank.sv:41`` — "COUNTERS SATURATE, THEY DO NOT WRAP.
    ... holding at all-ones and setting the sticky ``saturated`` bit tells the
    host the number is a FLOOR. Wrapping tells the host a comfortable lie."

    Only reachable in simulation with a narrow ``W``; the shipping 48-bit build
    would need 20.8 days.  On a wide build this test stands down LOUDLY rather
    than passing without having checked anything — the ``__main__`` runner
    builds a W=8 variant so the path is genuinely covered somewhere.
    """
    n, w = await bringup(dut)
    if w > 20:
        dut._log.warning(
            "W=%d: saturation needs 2^%d increments and is NOT checked in this "
            "build. The W=8 variant in the __main__ runner covers it.", w, w)
        return
    cor = await detect_clear_on_read(dut, n)
    await clear_all(dut, n)

    maxv = (1 << w) - 1

    # Exactly maxv increments: the counter is AT its maximum but has not yet
    # been asked to go past it, so `saturated` must still be clear.
    dut.incr.value = 1 << 0
    for _ in range(maxv):
        await RisingEdge(dut.clk)
    dut.incr.value = 0
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert (int(dut.saturated.value) & 1) == 0, (
        f"saturated[0] set after exactly {maxv} increments. The flag means "
        f"'an increment was LOST', not 'the counter is large' — setting it "
        f"early makes every real saturation indistinguishable from a full "
        f"counter that is still accurate.")
    await RisingEdge(dut.clk)

    # One more increment: the count must HOLD, and the flag must set.
    dut.incr.value = 1 << 0
    await RisingEdge(dut.clk)
    dut.incr.value = 0
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert int(dut.saturated.value) & 1, (
        f"an increment arrived with counter 0 already at {maxv} and "
        f"saturated[0] is still clear — the host has no way to know the number "
        f"is a floor, not a value (rtl/common/counter_bank.sv:41)")
    assert (int(dut.saturated.value) >> 1) == 0, (
        f"saturated = 0b{int(dut.saturated.value):b}: a counter that was never "
        f"incremented reported saturation")
    await RisingEdge(dut.clk)

    # Keep hammering it: the value must stay pinned, never roll over.
    dut.incr.value = 1 << 0
    for _ in range(200):
        await RisingEdge(dut.clk)
        assert int(dut.saturated.value) & 1, "sticky saturated[0] self-cleared"
    dut.incr.value = 0
    await RisingEdge(dut.clk)

    val = await read_counter(dut, 0)
    assert val == maxv, (
        f"counter 0 reads {val} after {maxv + 201} increments in a {w}-bit "
        f"bank.\n  It must hold at {maxv}. A lower value means it WRAPPED — "
        f"and a wrapped counter reads as healthy "
        f"(rtl/common/counter_bank.sv:33). That is the single worst thing a "
        f"telemetry counter can do.")

    # clr_all is the only way back.
    await clear_all(dut, n)
    await FallingEdge(dut.clk)
    assert int(dut.saturated.value) == 0, "clr_all did not clear saturated"
    await RisingEdge(dut.clk)
    assert await read_counter(dut, 0) == 0, "clr_all did not zero the counters"
    dut._log.info("W=%d (CLEAR_ON_READ=%d): saturated at %d, sticky flag, no wrap",
                  w, int(cor), maxv)


@cocotb.test()
async def test_documented_span_table_is_arithmetically_true(dut):
    """⚠️ PINS THE WIDTH RULE: re-derives the wrap-span table in the RTL header.

    ``rtl/common/counter_bank.sv:33`` carries the table that justifies W=48:

        32 bits ->    27.5 seconds     <-- wraps inside one session. Never use.
        40 bits ->     1.95 hours      <-- wraps inside one session. Never use.
        48 bits ->    20.8 days        <-- safe for a session, and for a week.
        64 bits -> ~3700 years

    Simulation cannot run a 48-bit counter to its limit, so the guarantee "a
    counter does not wrap within its documented span" has to be established
    another way: prove the width is what it claims to be, prove the span
    arithmetic in the header is correct, and prove the counter is monotonic and
    unsaturated over the longest run that can actually be simulated.  All three
    are here.

    This test fails if somebody narrows ``W`` on the shipping build, if the
    header table is edited to say something untrue, or if the table row for the
    project default stops matching ``trading_pkg::CYCLE_CNT_W``.  Each of those
    is the start of a counter that "reads as healthy" during an incident.
    """
    n, w = await bringup(dut)

    # --- 1. The header table must be arithmetically true.
    assert RTL.is_file(), f"{RTL} not found"
    text = RTL.read_text()
    rows = re.findall(
        r"^//\s+(\d+)\s+bits\s*->\s*~?([\d.]+)\s+(seconds|hours|days|years)",
        text, re.M)
    assert len(rows) >= 4, (
        f"{RTL}: the counter-width span table (header, 'WIDTH: 48 BITS BY "
        f"DEFAULT') is gone or was reformatted.\n"
        f"  That table is the justification for W=48 and the reason 32 and 40 "
        f"are banned. It is not decoration; found rows: {rows}")

    per_unit = {"seconds": 1.0, "hours": 3600.0, "days": 86400.0,
                "years": 365.0 * 86400.0}
    hz = CORE_CLK_MHZ * 1e6
    for bits_s, qty_s, unit in rows:
        bits, qty = int(bits_s), float(qty_s)
        true_s = (1 << bits) / hz
        claim_s = qty * per_unit[unit]
        assert abs(true_s - claim_s) <= 0.05 * true_s, (
            f"{RTL} header claims a {bits}-bit counter lasts {qty} {unit} "
            f"({claim_s:.3g} s) at {CORE_CLK_MHZ} MHz, but 2^{bits}/f is "
            f"{true_s:.6g} s.\n"
            f"  If the core clock moved, this table and the whole 48-bit "
            f"justification move with it (CLAUDE.md §3: a package change is a "
            f"system-wide change).")

    # --- 2. Anything that wraps inside a session must be named as banned.
    for bits_s, qty_s, unit in rows:
        bits = int(bits_s)
        if (1 << bits) / hz < 8 * 3600:      # shorter than a trading session
            line = next(ln for ln in text.splitlines()
                        if re.search(rf"^//\s+{bits}\s+bits\s*->", ln))
            assert "Never use" in line, (
                f"{RTL}: a {bits}-bit counter wraps in "
                f"{(1 << bits) / hz:.3g} s — inside one trading session — but "
                f"its row is not marked 'Never use'.")

    # --- 3. The shipping default must actually be 48 bits.
    m = re.search(r"parameter\s+int\s+unsigned\s+W\s*=\s*(\d+)", text)
    assert m and int(m.group(1)) == CYCLE_CNT_W, (
        f"{RTL}: default W is {m.group(1) if m else '?'}, expected "
        f"{CYCLE_CNT_W} (trading_pkg::CYCLE_CNT_W).\n"
        f"  A narrower default silently re-arms the 27.5-second wrap.")

    # --- 4. And this build must be at least as wide as it claims.
    cor = await detect_clear_on_read(dut, n)
    if w < CYCLE_CNT_W:
        dut._log.warning(
            "this build is W=%d, narrower than the %d-bit project default — "
            "acceptable only for a deliberately narrow variant under test",
            w, CYCLE_CNT_W)
    elif cor:
        dut._log.info(
            "CLEAR_ON_READ build: the monotonicity checkpoints below need "
            "non-destructive reads and are covered by the sticky builds")
    else:
        # --- 5. Monotonic and unsaturated over the longest simulable run.
        # 10 000 increments is nowhere near 2^48; what it establishes is that
        # the counter really is W bits wide and really is monotonic, which,
        # combined with the verified span table above, is as close to "does not
        # wrap within its documented span" as simulation can get.
        await clear_all(dut, n)
        checkpoints = []
        for k in range(20):
            dut.incr.value = (1 << n) - 1
            for _ in range(500):
                await RisingEdge(dut.clk)
            dut.incr.value = 0
            await RisingEdge(dut.clk)
            await FallingEdge(dut.clk)
            assert int(dut.saturated.value) == 0, (
                f"a {w}-bit counter reported saturation after {(k + 1) * 500} "
                f"increments — it is not {w} bits wide")
            await RisingEdge(dut.clk)
            checkpoints.append(await read_counter(dut, 0))
        assert checkpoints == sorted(checkpoints) and len(set(checkpoints)) == 20, (
            f"counter 0 is not strictly increasing across checkpoints: "
            f"{checkpoints}")
        assert checkpoints[-1] == 20 * 500, (
            f"after 10 000 increment cycles counter 0 reads {checkpoints[-1]}, "
            f"expected 10000")

    dut._log.info(
        "span table verified against 2^W/%.2f MHz for %d widths; default W=%d",
        CORE_CLK_MHZ, len(rows), CYCLE_CNT_W)


# =============================================================================
# 3. Bank control
# =============================================================================

@cocotb.test()
async def test_clr_all_and_reset_zero_the_bank(dut):
    """``clr_all`` and ``rst`` both zero every counter and every sticky flag.

    A bank that clears "most" counters leaves a stale absolute value in one of
    them, and the host's next delta is then enormous and meaningless — which is
    indistinguishable from a genuine incident at exactly the moment somebody is
    trying to work out whether there was one.
    """
    rng, seed = seeded_rng(dut, "counter_bank.clear")
    n, w = await bringup(dut)
    cor = await detect_clear_on_read(dut, n)

    for use_rst in (False, True):
        await clear_all(dut, n)
        for _ in range(200):
            dut.incr.value = rng.getrandbits(n)
            await RisingEdge(dut.clk)
        dut.incr.value = 0
        await RisingEdge(dut.clk)

        if use_rst:
            dut.rst.value = 1
            for _ in range(rng.randrange(1, 4)):
                await RisingEdge(dut.clk)
            dut.rst.value = 0
            await RisingEdge(dut.clk)
        else:
            await clear_all(dut, n)

        vals = await read_all(dut, n)
        assert vals == [0] * n, (
            f"{'rst' if use_rst else 'clr_all'} left non-zero counters: {vals}"
            + seed_note(seed))
        assert int(dut.saturated.value) == 0, (
            f"{'rst' if use_rst else 'clr_all'} left saturated flags set")
    dut._log.info("clr_all and rst both zero the whole bank (CLEAR_ON_READ=%d)",
                  int(cor))


@cocotb.test()
async def test_counters_are_independent(dut):
    """One counter's traffic never appears in another.

    A shared adder, an off-by-one in ``raddr``, or a mis-sized ``AW`` all show
    up here.  It matters because the risk gate gives every ``risk_reason_e``
    value its own counter (tb/README.md §4) — if two reasons alias, the
    post-incident question "why were these orders rejected?" gets the wrong
    answer, with full confidence.
    """
    n, w = await bringup(dut)
    cor = await detect_clear_on_read(dut, n)
    await clear_all(dut, n)

    expect = [0] * n
    for i in range(n):
        k = 3 + i * 5
        dut.incr.value = 1 << i
        for _ in range(k):
            await RisingEdge(dut.clk)
        expect[i] = k
    dut.incr.value = 0
    await RisingEdge(dut.clk)

    actual = await read_all(dut, n)
    assert actual == expect, (
        f"counters are not independent.\n  expected {expect}\n  actual   "
        f"{actual}\n  A counter that picks up another's events makes every "
        f"per-reason rejection count untrustworthy.")
    dut._log.info("N=%d counters independently addressed and counted "
                  "(CLEAR_ON_READ=%d)", n, int(cor))


@cocotb.test()
async def test_rvalid_never_without_a_read(dut):
    """``rvalid`` is high if and only if ``ren`` was high on the previous cycle.

    A spurious ``rvalid`` hands the CSR block a stale ``rdata`` it will publish
    as a live counter value.
    """
    rng, seed = seeded_rng(dut, "counter_bank.rvalid")
    n, w = await bringup(dut)
    await detect_clear_on_read(dut, n)
    await clear_all(dut, n)

    # Drive -> ReadOnly -> sample -> RisingEdge. `rvalid` read in the ReadOnly
    # phase is the result of the PREVIOUS edge, so it must equal the `ren` that
    # edge sampled — which is what `prev_ren` holds.
    prev_ren = 0
    for cyc in range(1500):
        ren = int(rng.random() < 0.35)
        dut.ren.value = ren
        dut.raddr.value = rng.randrange(n)
        dut.incr.value = rng.getrandbits(n)
        await FallingEdge(dut.clk)
        v = int(dut.rvalid.value)
        assert v == prev_ren, (
            f"cycle {cyc}: rvalid={v} but the previous edge sampled ren="
            f"{prev_ren}.\n  A spurious rvalid hands the CSR block a stale "
            f"rdata that it publishes as a live counter value."
            + seed_note(seed))
        await RisingEdge(dut.clk)
        prev_ren = ren
    dut.ren.value = 0
    dut.incr.value = 0
    await RisingEdge(dut.clk)
    dut._log.info("rvalid tracked ren exactly for 1500 cycles")


if __name__ == "__main__":  # pragma: no cover
    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        from cocotb.runner import get_runner

    runner = get_runner(os.environ.get("SIM", "verilator"))
    # (N, W, CLEAR_ON_READ, SATURATE)
    #   16/48/0/1 — the shipping configuration
    #    4/ 8/0/1 — narrow enough that saturation is reachable in simulation
    #    4/48/1/1 — clear-on-read semantics
    #    8/48/0/1 — a different N, to catch AW/raddr sizing
    for n, w, cor, sat in ((16, 48, 0, 1), (4, 8, 0, 1), (4, 48, 1, 1),
                           (8, 48, 0, 1)):
        runner.build(
            verilog_sources=sim_sources("rtl/common/counter_bank.sv"),
            hdl_toplevel="counter_bank",
            parameters={"N": n, "W": w, "CLEAR_ON_READ": cor, "SATURATE": sat},
            build_args=["-Wno-fatal"],
            always=True,
        )
        runner.test(hdl_toplevel="counter_bank", test_module="test_counter_bank")
