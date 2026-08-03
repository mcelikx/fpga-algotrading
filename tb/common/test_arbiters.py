"""Arbiters — round-robin fairness, fixed-priority determinism, real starvation counts.

INVARIANT PROVEN
    ``rr_arbiter``:
      * ``grant`` is one-hot-or-zero, never to a non-requester, silent when
        ``en`` is low, and issued in the SAME cycle a request appears (0 cycles);
      * the rotation is exact — under uniform demand the grant order is
        0,1,2,...,N-1,0,... and every requester's share is within one grant of
        every other's;
      * ⚠️ the worst-case wait is BOUNDED at N-1 grant opportunities for a
        continuously-asserted request, at every N and under adversarial demand;
      * the first grant after reset goes to requester 0 — a deterministic
        start-up state, not whatever the mask happened to power up as.

    ``fixed_arbiter``:
      * ⚠️ requester 0 is granted in the same cycle it asks, ALWAYS, whatever
        anyone else is doing.  Zero jitter.  This is the module's entire reason
        to exist;
      * strict priority: ``grant[i]`` implies no ``j < i`` was asking;
      * ``starve_cnt[i]`` counts EVERY cycle requester i asked and did not get
        the resource — including cycles when ``en`` is low — and the count is
        exact, not approximate;
      * the counters SATURATE and set a sticky ``starve_sat``; they never wrap.

WHY IT MATTERS
    Manual 01.01 §4 and CLAUDE.md §5.8 put determinism above average speed, so
    the two arbiters are not interchangeable and picking the wrong one is a
    latency bug that no functional test would ever catch:

      * ``fixed_arbiter`` belongs on the tick-to-trade path with the
        market-data/order-emit requester at index 0.  Round robin there would
        add up to N-1 grants of JITTER to the one path whose jitter is the
        product (rtl/common/rr_arbiter.sv:21).
      * ``rr_arbiter`` belongs on the A/B feed arbitration and telemetry paths,
        where fairness matters and the bounded wait is the guarantee.

    And the starvation counters are not decoration.  Fixed priority starves
    lower-priority requesters BY DESIGN (rtl/common/fixed_arbiter.sv:30); the
    manual's instruction is to COUNT the starvation so you know whether the
    low-priority path is being neglected, because "a low-priority path that is
    quietly never served looks exactly like a path that has nothing to do, right
    up until the day it matters."  A starvation counter that does not actually
    count is worse than none, because it is believed.  ``test_starve_counter_is
    _exact`` asserts the delta to the cycle.

DUT
    rtl/common/rr_arbiter.sv and rtl/common/fixed_arbiter.sv.  One toplevel per
    simulator run; each test detects which module is loaded (``fixed_arbiter``
    is the one with a ``starve_cnt`` port) and stands down if it is not the one
    under test.  ``python test_arbiters.py`` builds and runs both.

RUNNING
    TOPLEVEL=rr_arbiter or TOPLEVEL=fixed_arbiter, or ``python test_arbiters.py``.
"""

from __future__ import annotations

import os
import pathlib
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tb_util import CLK_NS, seed_note, seeded_rng, sim_sources  # noqa: E402

TOPLEVEL = os.environ.get("TOPLEVEL", "").lower()
IS_FIXED_ENV = "fixed_arbiter" in TOPLEVEL
IS_RR_ENV = "rr_arbiter" in TOPLEVEL
# With TOPLEVEL unset (a bare pytest/manual invocation) neither skip fires and
# the runtime probe below decides. Never skip both: a suite that silently runs
# nothing is indistinguishable from a suite that passes.
SKIP_RR = IS_FIXED_ENV
SKIP_FIXED = IS_RR_ENV


def is_fixed(dut) -> bool:
    return hasattr(dut, "starve_cnt")


def n_req(dut) -> int:
    return len(dut.req)


def starve_w(dut) -> int:
    try:
        return len(dut.starve_cnt[0])
    except Exception:  # pragma: no cover
        return int(os.environ.get("STARVE_W", "32"))


#: cocotb runs every test in this file inside ONE simulation, so ``bringup``
#: must not leave a second task toggling ``clk``.
_CLOCK: list = []


def _start_clock(dut):
    while _CLOCK:
        _CLOCK.pop().kill()
    _CLOCK.append(cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start()))


async def bringup(dut):
    _start_clock(dut)
    dut.req.value = 0
    dut.en.value = 1
    if is_fixed(dut):
        dut.starve_clr.value = 0
    dut.rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    return n_req(dut)


async def arbitrate(dut, req: int) -> tuple[int, int, int]:
    """Drive ``req`` and return ``(grant, grant_valid, grant_idx)`` for this cycle.

    ``grant`` is COMBINATIONAL from ``req`` in both arbiters — a deliberate
    exception to registered-outputs-by-default (rtl/common/rr_arbiter.sv:36),
    because a registered grant would cost a cycle on every transfer and change
    the protocol.  So the grant for a request presented now is visible now, and
    the rotation pointer (rr) and starvation counters (fixed) update on the
    following rising edge.

    Driven at the falling edge and read one delta later, so the combinational
    grant has settled; returns just after the rising edge that consumed it, so
    the caller is always free to drive again.
    """
    await FallingEdge(dut.clk)
    dut.req.value = req
    await Timer(1, units="ps")          # let the combinational grant settle
    g = int(dut.grant.value)
    gv = int(dut.grant_valid.value)
    gi = int(dut.grant_idx.value)
    await RisingEdge(dut.clk)
    return g, gv, gi


def check_grant_shape(g: int, gv: int, gi: int, req: int, en: int, n: int,
                      ctx: str) -> None:
    """The invariants that must hold on EVERY cycle of EVERY test."""
    assert g == 0 or (g & (g - 1)) == 0, (
        f"{ctx}: grant 0b{g:0{n}b} is not one-hot — two requesters believe they "
        f"own the resource simultaneously")
    if not en:
        assert g == 0 and gv == 0, (
            f"{ctx}: granted 0b{g:0{n}b} while en was low")
        return
    assert (g & ~req) == 0, (
        f"{ctx}: granted 0b{g:0{n}b} to a requester that did not ask "
        f"(req=0b{req:0{n}b})")
    assert gv == (g != 0), (
        f"{ctx}: grant_valid={gv} disagrees with grant 0b{g:0{n}b}")
    if req and not g:
        raise AssertionError(
            f"{ctx}: req=0b{req:0{n}b} with en high but NO grant issued — a "
            f"wasted arbitration cycle")
    if g:
        assert (g >> gi) & 1, (
            f"{ctx}: grant_idx={gi} does not select the granted bit "
            f"0b{g:0{n}b}")


# =============================================================================
# rr_arbiter
# =============================================================================

@cocotb.test(skip=SKIP_RR)
async def test_rr_rotation_is_exact_under_uniform_demand(dut):
    """All N asking, every cycle: grants go 0,1,2,...,N-1,0,... exactly.

    ``rr_arbiter``'s value is entirely in the ORDER.  A rotation that skips or
    repeats still looks "fair" over a long run while giving one requester twice
    the service of another during any short burst — and on the A/B feed
    arbitration a short burst is the whole event.
    """
    if is_fixed(dut):
        dut._log.info("toplevel is fixed_arbiter — rr_arbiter test not applicable")
        return
    n = await bringup(dut)
    all_req = (1 << n) - 1

    order = []
    for cyc in range(4 * n):
        g, gv, gi = await arbitrate(dut, all_req)
        check_grant_shape(g, gv, gi, all_req, 1, n, f"cycle {cyc}")
        order.append(gi)

    expected = [i % n for i in range(4 * n)]
    assert order == expected, (
        f"round-robin order is {order}, expected {expected}.\n"
        f"  The first grant after reset must go to requester 0 (mask_q resets "
        f"to all ones, rtl/common/rr_arbiter.sv:67) and the pointer must then "
        f"advance by exactly one each cycle. Anything else is not round robin, "
        f"whatever the long-run averages say."
    )
    dut._log.info("N=%d: exact rotation over %d grants", n, len(order))


@cocotb.test(skip=SKIP_RR)
async def test_rr_worst_case_wait_is_bounded(dut):
    """⚠️ A continuously-asserted request is granted within N-1 grants. Always.

    ``rtl/common/rr_arbiter.sv:14`` — "Bounded worst-case wait of N-1 grant
    opportunities — no requester can be starved."  That bound IS the reason to
    accept round robin's jitter, so it is measured rather than assumed, under
    two shapes:

      * every requester asking continuously (the dense case);
      * a randomized adversarial pattern where the other requesters come and go
        while one requester holds its request high throughout.

    The measurement counts GRANTS ISSUED, not cycles, because a cycle in which
    nobody is granted is not an opportunity anyone was denied.
    """
    if is_fixed(dut):
        dut._log.info("toplevel is fixed_arbiter — rr_arbiter test not applicable")
        return
    rng, seed = seeded_rng(dut, "rr.bound")
    n = await bringup(dut)
    worst = 0

    for victim in range(n):
        waited = 0
        for cyc in range(400):
            others = rng.getrandbits(n) & ~(1 << victim)
            req = others | (1 << victim)
            g, gv, gi = await arbitrate(dut, req)
            check_grant_shape(g, gv, gi, req, 1, n, f"victim {victim} cyc {cyc}")
            if g:
                if (g >> victim) & 1:
                    worst = max(worst, waited)
                    waited = 0
                else:
                    waited += 1
                    assert waited <= n - 1, (
                        f"⚠️ STARVATION: requester {victim} held req high and "
                        f"was passed over {waited} times in a row; the bound is "
                        f"N-1 = {n - 1} (rtl/common/rr_arbiter.sv:14).\n"
                        f"  The bounded wait is the ONLY thing round robin buys "
                        f"in exchange for its jitter. Without it, use "
                        f"fixed_arbiter and count the starvation instead."
                        + seed_note(seed))
    dut._log.info("N=%d: worst observed wait %d grants (bound %d)",
                  n, worst, n - 1)


@cocotb.test(skip=SKIP_RR)
async def test_rr_share_is_even(dut):
    """Under uniform continuous demand, every requester's share is within one.

    Long-run fairness, which is a different property from the rotation order and
    can be broken independently (a rotation that resets its mask too often
    favours low indices without ever violating the per-request bound).
    """
    if is_fixed(dut):
        dut._log.info("toplevel is fixed_arbiter — rr_arbiter test not applicable")
        return
    n = await bringup(dut)
    all_req = (1 << n) - 1
    counts = [0] * n
    total = 200 * n

    for _ in range(total):
        g, gv, gi = await arbitrate(dut, all_req)
        if g:
            counts[gi] += 1

    assert sum(counts) == total, f"{sum(counts)} grants issued in {total} cycles"
    assert max(counts) - min(counts) <= 1, (
        f"grant shares differ by more than one: {counts}.\n"
        f"  Round robin's contract is equal service under equal demand; an "
        f"uneven share means the rotation is biased toward some indices."
    )
    dut._log.info("N=%d shares: %s", n, counts)


@cocotb.test(skip=SKIP_RR)
async def test_rr_random_soak_and_disable(dut):
    """Constrained-random requests, ``en`` toggling, contract checked every cycle.

    ``en`` low must be completely silent — a grant issued while the resource is
    switched off is a requester driving a bus nobody is listening to.
    """
    if is_fixed(dut):
        dut._log.info("toplevel is fixed_arbiter — rr_arbiter test not applicable")
        return
    rng, seed = seeded_rng(dut, "rr.soak")
    n = await bringup(dut)

    grants = 0
    disabled_cycles = 0
    for cyc in range(4000):
        req = rng.getrandbits(n)
        en = int(rng.random() < 0.85)
        dut.en.value = en
        g, gv, gi = await arbitrate(dut, req)
        check_grant_shape(g, gv, gi, req, en, n, f"soak cycle {cyc}"
                          + seed_note(seed))
        if g:
            grants += 1
        if not en:
            disabled_cycles += 1
    dut.en.value = 1
    assert grants > 100, f"only {grants} grants in 4000 random cycles"
    assert disabled_cycles > 100, "en was almost never low — the soak is thin"
    dut._log.info("random soak: %d grants, %d disabled cycles, contract clean",
                  grants, disabled_cycles)


@cocotb.test(skip=SKIP_RR)
async def test_rr_reset_returns_to_a_deterministic_start_state(dut):
    """After every reset the next grant goes to requester 0.

    ``rtl/common/rr_arbiter.sv:67`` — the mask resets to all ones, "so the first
    grant after reset goes to requester 0. Deterministic start-up state."
    A start-up state that depends on what happened before the reset is a
    reproducibility hole: two identical replays of the same pcap can then
    diverge, and tier-3 replay against the golden model stops being meaningful.
    """
    if is_fixed(dut):
        dut._log.info("toplevel is fixed_arbiter — rr_arbiter test not applicable")
        return
    rng, seed = seeded_rng(dut, "rr.reset")
    n = await bringup(dut)
    all_req = (1 << n) - 1

    for trial in range(12):
        # Rotate the pointer to an arbitrary position first.
        for _ in range(rng.randrange(1, 3 * n)):
            await arbitrate(dut, all_req)
        dut.req.value = 0
        dut.rst.value = 1
        for _ in range(rng.randrange(1, 4)):
            await RisingEdge(dut.clk)
        dut.rst.value = 0
        await RisingEdge(dut.clk)

        _, _, gi = await arbitrate(dut, all_req)
        assert gi == 0, (
            f"trial {trial}: the first grant after reset went to requester "
            f"{gi}, not 0 — start-up is not deterministic" + seed_note(seed))
    dut._log.info("12 resets, first grant always to requester 0")


# =============================================================================
# fixed_arbiter
# =============================================================================

@cocotb.test(skip=SKIP_FIXED)
async def test_fixed_priority_zero_never_waits(dut):
    """⚠️ THE defining property: ``req[0]`` is granted the same cycle, always.

    ``rtl/common/fixed_arbiter.sv:19`` — "0 cycles, and — unlike round robin —
    ZERO JITTER for requester 0. That determinism is the whole point."

    Exercised against every possible pattern of the other requesters (exhaustive
    for small N, randomized above that), with ``req[0]`` held.  If this ever
    fails, the tick-to-trade path has acquired jitter from a source nobody is
    measuring, and CLAUDE.md §5.8 ranks that above average speed.
    """
    if not is_fixed(dut):
        dut._log.info("toplevel is rr_arbiter — fixed_arbiter test not applicable")
        return
    rng, seed = seeded_rng(dut, "fixed.prio0")
    n = await bringup(dut)

    others = (range(1 << (n - 1)) if n <= 12
              else [rng.getrandbits(n - 1) for _ in range(4096)])
    for pat in others:
        req = 1 | (pat << 1)
        g, gv, gi = await arbitrate(dut, req)
        check_grant_shape(g, gv, gi, req, 1, n, f"req=0b{req:0{n}b}")
        assert g == 1 and gi == 0, (
            f"⚠️ DETERMINISM LOST: with req=0b{req:0{n}b} (requester 0 asking), "
            f"grant was 0b{g:0{n}b} / idx {gi}, expected bit 0.\n"
            f"  Requester 0 is the tick-to-trade path. It must never wait for "
            f"anyone (rtl/common/fixed_arbiter.sv:173)." + seed_note(seed))
    dut._log.info("N=%d: requester 0 granted immediately in %d patterns",
                  n, len(list(others)) if n <= 12 else 4096)


@cocotb.test(skip=SKIP_FIXED)
async def test_fixed_strict_priority_order(dut):
    """``grant[i]`` implies every ``j < i`` was silent.  Exhaustively, for small N.

    Iterating every request pattern is cheap for N <= 12 and leaves no gap: a
    priority encoder that is wrong for exactly one input pattern is a plausible
    defect and a random test can miss it for a long time.
    """
    if not is_fixed(dut):
        dut._log.info("toplevel is rr_arbiter — fixed_arbiter test not applicable")
        return
    rng, seed = seeded_rng(dut, "fixed.order")
    n = await bringup(dut)
    pats = range(1 << n) if n <= 12 else [rng.getrandbits(n) for _ in range(8192)]

    for req in pats:
        g, gv, gi = await arbitrate(dut, req)
        check_grant_shape(g, gv, gi, req, 1, n, f"req=0b{req:0{n}b}")
        if req:
            expect = req & (~req + 1)          # lowest set bit
            assert g == expect, (
                f"req=0b{req:0{n}b}: granted 0b{g:0{n}b}, expected the "
                f"lowest-numbered requester 0b{expect:0{n}b}"
                + seed_note(seed))
        else:
            assert g == 0 and gv == 0, "granted with no requests"
    dut._log.info("N=%d: strict priority holds for every request pattern", n)


@cocotb.test(skip=SKIP_FIXED)
async def test_starve_counter_is_exact(dut):
    """⚠️ ``starve_cnt[i]`` counts EVERY denied cycle. Asserted as an exact delta.

    ``rtl/common/fixed_arbiter.sv:30`` — the counters exist because fixed
    priority starves lower-priority requesters by design and the manual's answer
    is to measure it.  ``CounterCheck``-style exact-delta assertion, because a
    counter that is approximately right is a dashboard that is confidently wrong
    (CLAUDE.md §5.7).

    Three regimes:
      * requester 0 holds the resource for K cycles while 1..N-1 also ask:
        every lower-priority counter must advance by exactly K, and
        ``starve_cnt[0]`` must not move at all;
      * ⚠️ ``en`` low: the header is explicit that a requester asking while the
        resource is switched off IS starved — "a resource that is switched off
        is still a resource the requester is not getting";
      * nobody asking: nothing counts.
    """
    if not is_fixed(dut):
        dut._log.info("toplevel is rr_arbiter — fixed_arbiter test not applicable")
        return
    n = await bringup(dut)

    def read_cnt() -> list[int]:
        return [int(dut.starve_cnt[i].value) for i in range(n)]

    async def clear():
        # req low throughout, so the clear window cannot itself accrue counts.
        dut.req.value = 0
        dut.starve_clr.value = 1
        # ⚠️ TWO cycles, not the ONE the port documents
        # (rtl/common/fixed_arbiter.sv:70 "1-cycle strobe: zero the bank").
        # A single-cycle strobe trips the module's own assertion at
        # rtl/common/fixed_arbiter.sv:191 — see the dedicated test at the end of
        # this file. Using the port exactly as documented is not currently
        # possible with assertions enabled.
        await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)
        dut.starve_clr.value = 0
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        assert read_cnt() == [0] * n, "starve_clr did not zero the bank"
        await RisingEdge(dut.clk)

    # --- Regime 1: everyone asks, requester 0 always wins.
    await clear()
    k = 64
    all_req = (1 << n) - 1
    for _ in range(k):
        await arbitrate(dut, all_req)
    dut.req.value = 0
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    cnt = read_cnt()
    assert cnt[0] == 0, (
        f"starve_cnt[0] = {cnt[0]} after {k} cycles in which requester 0 was "
        f"granted every single time. The highest-priority path is never starved "
        f"by definition; a non-zero count here means `starving` is not "
        f"``req & ~grant``.")
    for i in range(1, n):
        assert cnt[i] == k, (
            f"starve_cnt[{i}] = {cnt[i]} after exactly {k} cycles of being "
            f"denied. Off by {cnt[i] - k}.\n"
            f"  This counter is the ONLY visibility into a low-priority path "
            f"being neglected (rtl/common/fixed_arbiter.sv:33). A count that is "
            f"nearly right is worse than none, because it is trusted.")

    # --- Regime 2: en low. Asking while disabled is still starving.
    await clear()
    dut.en.value = 0
    m = 32
    for cyc in range(m):
        g, gv, gi = await arbitrate(dut, all_req)
        check_grant_shape(g, gv, gi, all_req, 0, n, f"disabled cycle {cyc}")
    dut.req.value = 0
    dut.en.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    cnt = read_cnt()
    assert cnt == [m] * n, (
        f"with en low for {m} cycles and everyone asking, starve_cnt = {cnt}, "
        f"expected {[m] * n}.\n"
        f"  rtl/common/fixed_arbiter.sv:104 is explicit: cycles where `en` is "
        f"low count as starvation, because 'a resource that is switched off is "
        f"still a resource the requester is not getting'. If they did not "
        f"count, a permanently disabled arbiter would read as perfectly healthy.")

    # --- Regime 3: nobody asking, nothing counts.
    await clear()
    for _ in range(50):
        await arbitrate(dut, 0)
    await FallingEdge(dut.clk)
    assert read_cnt() == [0] * n, (
        f"starve_cnt moved with no requests asserted: {read_cnt()}")
    dut._log.info("N=%d: starvation counts exact in all three regimes", n)


@cocotb.test(skip=SKIP_FIXED)
async def test_starve_counter_saturates_and_never_wraps(dut):
    """The counter holds at all-ones and sets a sticky flag.  It does not wrap.

    ``rtl/common/fixed_arbiter.sv:39`` — "A wrapped starvation counter reads as
    'healthy' and is worse than no counter at all."  ``starve_sat`` tells the
    host the number is a FLOOR, not a value.

    Only meaningful with a narrow ``STARVE_W``; the default 32 bits takes ~27 s
    of continuous starvation to saturate at 156.25 MHz and cannot be simulated.
    The ``__main__`` runner therefore builds an 8-bit variant, and this test
    stands down (loudly) on a wide build rather than pretending to have checked.
    """
    if not is_fixed(dut):
        dut._log.info("toplevel is rr_arbiter — fixed_arbiter test not applicable")
        return
    n = await bringup(dut)
    sw = starve_w(dut)
    if sw > 12:
        dut._log.warning(
            "STARVE_W=%d: saturation would need %d cycles of continuous "
            "starvation and is NOT being checked in this build. Run the "
            "STARVE_W=8 variant (see the __main__ runner) to cover it.",
            sw, (1 << sw))
        return

    maxv = (1 << sw) - 1
    dut.starve_clr.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)      # 2 cycles — see the note in `clear()` above
    dut.starve_clr.value = 0
    await RisingEdge(dut.clk)

    prev = 0
    all_req = (1 << n) - 1
    for cyc in range(maxv + 64):
        await arbitrate(dut, all_req)
        cur = int(dut.starve_cnt[1].value)
        assert cur >= prev, (
            f"⚠️ starve_cnt[1] WRAPPED at cycle {cyc}: {prev} -> {cur}.\n"
            f"  A wrapped counter reads as healthy "
            f"(rtl/common/fixed_arbiter.sv:39). This is the single worst thing "
            f"a telemetry counter can do.")
        prev = cur
    dut.req.value = 0
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)

    assert int(dut.starve_cnt[1].value) == maxv, (
        f"starve_cnt[1] = {int(dut.starve_cnt[1].value)} after "
        f"{maxv + 64} starving cycles; it should be held at {maxv}")
    assert (int(dut.starve_sat.value) >> 1) & 1, (
        f"starve_sat[1] is clear although the counter is pinned at {maxv} — the "
        f"host has no way to know the number is a floor")
    assert not (int(dut.starve_sat.value) & 1), (
        "starve_sat[0] set although requester 0 was never starved")
    dut._log.info("STARVE_W=%d: saturated at %d, sticky flag set, no wrap",
                  sw, maxv)


@cocotb.test(skip=SKIP_FIXED)
async def test_fixed_random_soak(dut):
    """Constrained-random requests and ``en``, contract checked every cycle."""
    if not is_fixed(dut):
        dut._log.info("toplevel is rr_arbiter — fixed_arbiter test not applicable")
        return
    rng, seed = seeded_rng(dut, "fixed.soak")
    n = await bringup(dut)
    # The model must SATURATE exactly as the DUT does, or a narrow-STARVE_W
    # build reports a "miscount" that is really the module doing its job
    # (rtl/common/fixed_arbiter.sv:39 — saturate, never wrap).
    maxv = (1 << starve_w(dut)) - 1

    model = [0] * n
    dut.starve_clr.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)      # 2 cycles — see the note in `clear()` above
    dut.starve_clr.value = 0
    await RisingEdge(dut.clk)

    for cyc in range(3000):
        req = rng.getrandbits(n)
        en = int(rng.random() < 0.8)
        dut.en.value = en
        g, gv, gi = await arbitrate(dut, req)
        check_grant_shape(g, gv, gi, req, en, n, f"soak cycle {cyc}"
                          + seed_note(seed))
        for i in range(n):
            if (req >> i) & 1 and not ((g >> i) & 1):
                model[i] = min(model[i] + 1, maxv)
    dut.req.value = 0
    dut.en.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    actual = [int(dut.starve_cnt[i].value) for i in range(n)]
    assert actual == model, (
        f"starvation counts after a 3000-cycle random soak (STARVE_W max "
        f"{maxv}):\n"
        f"  model : {model}\n"
        f"  dut   : {actual}\n"
        f"  delta : {[a - m for a, m in zip(actual, model)]}"
        + seed_note(seed))
    dut._log.info("random soak: starvation counts match the model exactly: %s",
                  actual)


# =============================================================================
# ⚠️ XFAIL-BY-OBSERVATION — RTL ASSERTION BUG. LAST, BECAUSE $stop ABORTS THE SIM.
# =============================================================================

@cocotb.test(skip=SKIP_FIXED)
async def test_one_cycle_starve_clr_trips_the_monotonicity_assertion(dut):
    """⚠️ Using ``starve_clr`` EXACTLY AS DOCUMENTED trips the module's own assertion.

    THIS FAILURE IS AN RTL BUG, NOT A TESTBENCH BUG.  ``starve_clr`` is declared
    at ``rtl/common/fixed_arbiter.sv:70`` as a **"1-cycle strobe: zero the
    bank"**.  Drive it for exactly one cycle — the documented usage — and
    ``rtl/common/fixed_arbiter.sv:191`` reports:

        fixed_arbiter: starve_cnt[1] WRAPPED — a wrapped counter reads as healthy

    from this property:

        assert property (@(posedge clk) disable iff (rst || starve_clr)
            starve_cnt[a] >= $past(starve_cnt[a]))

    The counter did not wrap.  It was cleared, on purpose, by the port provided
    for clearing it.  With ``starve_clr`` high for a single edge, the first
    RE-ENABLED evaluation compares ``starve_cnt`` (now 0) against
    ``$past(starve_cnt)`` (still the pre-clear value, because the only
    intervening cycle was disabled).  Hold the strobe for two cycles and it
    never fires.

    ⚠️ THIS IS THE SAME DEFECT AS ``sync_fifo``'s high-water assertion, and the
    shape appears in four modules:

        rtl/common/sync_fifo.sv:227      high_water    >= $past(high_water)
        rtl/common/async_fifo.sv:353     wr_high_water >= $past(wr_high_water)
        rtl/common/counter_bank.sv:195   cnt_q[c]      >= $past(cnt_q[c])
        rtl/common/fixed_arbiter.sv:191  starve_cnt[a] >= $past(starve_cnt[a])

    Two of those (``starve_clr`` here, ``clr_all`` in ``counter_bank``) are
    reachable through a documented single-cycle strobe, so the modules cannot be
    driven as specified without reporting a violation they did not commit.  The
    message is the worst possible one to cry wolf with — "a wrapped counter
    reads as healthy" is precisely the failure CLAUDE.md §5.7 exists to prevent,
    and a regression that prints it on every legal clear teaches people to
    ignore it.

    Suggested fix (RTL is owned elsewhere; NOT applied here): widen the disable
    to cover the recovery cycle, e.g.
    ``disable iff (rst || starve_clr || $past(starve_clr))``.
    """
    if not is_fixed(dut):
        dut._log.info("toplevel is rr_arbiter — fixed_arbiter test not applicable")
        return
    n = await bringup(dut)

    dut._log.error(
        "⚠️ EXPECTED FAILURE AHEAD — RTL ASSERTION BUG, NOT A TESTBENCH BUG. "
        "starve_clr is documented as a 1-cycle strobe "
        "(rtl/common/fixed_arbiter.sv:70); driving it for exactly one cycle "
        "makes rtl/common/fixed_arbiter.sv:191 report the counter WRAPPED. "
        "It was cleared, not wrapped. Two-cycle strobes are clean. The $error "
        "calls $stop, which aborts the simulator — hence this test is LAST."
    )

    all_req = (1 << n) - 1
    for _ in range(20):
        await arbitrate(dut, all_req)
    dut.req.value = 0
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    before = int(dut.starve_cnt[1].value)
    assert before > 0, f"starve_cnt[1] is {before}; expected a non-zero count"

    dut.starve_clr.value = 1
    await RisingEdge(dut.clk)          # exactly ONE cycle, as documented
    dut.starve_clr.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)

    assert int(dut.starve_cnt[1].value) == 0, "one-cycle starve_clr did not clear"
    dut._log.info(
        "a one-cycle starve_clr no longer trips the assertion — the bug in this "
        "test's docstring has been FIXED; fold this test back into "
        "test_starve_counter_is_exact and restore the 1-cycle clear() strobe.")


if __name__ == "__main__":  # pragma: no cover
    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        from cocotb.runner import get_runner

    runner = get_runner(os.environ.get("SIM", "verilator"))

    # ⚠️ A failing test here can take the SIMULATOR down, not just the test:
    # rtl/common/fixed_arbiter.sv:193's $error calls $stop. Run every
    # parameterisation anyway and re-raise at the end, so one aborting
    # configuration does not leave the later ones unmeasured — an unrun
    # parameterisation is not a passing one, and silently skipping it is how a
    # matrix comes to mean less than it looks like it does.
    _failed: list[str] = []

    def _run(tag, **kw):
        try:
            runner.test(**kw)
        # ⚠️ SystemExit too, NOT just Exception: cocotb's runner reports a failed
        # simulation by exiting, and SystemExit derives from BaseException, so a
        # bare `except Exception` silently lets the whole sweep die on the first
        # bad configuration — which is the behaviour this wrapper exists to stop.
        except (Exception, SystemExit) as exc:  # noqa: BLE001 - reported below
            _failed.append(f"{tag}: {type(exc).__name__}: {exc}")
            print(f"!!! configuration FAILED: {tag} — continuing to the next one")

    for n in (2, 4, 8):
        runner.build(
            verilog_sources=sim_sources("rtl/common/rr_arbiter.sv"),
            hdl_toplevel="rr_arbiter",
            parameters={"N": n},
            # --timing: the RTL uses delay controls that Verilator refuses to
            # compile without an explicit timing mode (NEEDTIMINGOPT).
            # tb/common/Makefile passes it, which is why these modules built
            # under that path and not under this runner.
            build_args=["-Wno-fatal", "--timing"],
            always=True,
        )
        os.environ["TOPLEVEL"] = "rr_arbiter"
        _run(f"rr_arbiter N={n}",
             hdl_toplevel="rr_arbiter", test_module="test_arbiters")

    # STARVE_W=8 is the minimum the module allows and the only width at which
    # saturation is reachable in simulation. STARVE_W=32 is the default and is
    # built too, so the exact-count tests run against the shipping parameters.
    for n, sw in ((4, 8), (8, 8), (4, 32)):
        runner.build(
            verilog_sources=sim_sources("rtl/common/fixed_arbiter.sv"),
            hdl_toplevel="fixed_arbiter",
            parameters={"N": n, "STARVE_W": sw},
            # --timing: see the rr_arbiter build above.
            build_args=["-Wno-fatal", "--timing"],
            always=True,
        )
        os.environ["TOPLEVEL"] = "fixed_arbiter"
        _run(f"fixed_arbiter N={n} STARVE_W={sw}",
             hdl_toplevel="fixed_arbiter", test_module="test_arbiters")

    if _failed:
        print("\n=== configurations that failed ===")
        for line in _failed:
            print(f"  {line}")
        sys.exit(1)
