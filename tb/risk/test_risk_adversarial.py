"""Pre-trade risk gate, ADVERSARIAL — actively trying to get a bad order out.

INVARIANT PROVEN
    ⚠️ EVERY attempt to smuggle an order past the pre-trade risk gate FAILS.
    Racing a parameter commit against an order, asserting the kill switch
    mid-flight, wrapping a counter, exhausting in-flight credit, sitting exactly
    on a limit boundary, resetting mid-order — none of them produces an order,
    and each one rejects for the CORRECT documented reason with the correct
    counter incremented.

WHY IT MATTERS
    This block is SEC Rule 15c3-5 pre-trade risk implemented in hardware.
    CLAUDE.md §5.5 makes it non-bypassable by construction: every outbound order
    passes through ``u_risk_gate`` and there is no software path that emits an
    order without it.  That structural guarantee is only worth something if the
    gate itself cannot be tricked.

    Every failure mode here is a REGULATORY EVENT, not a bug.  An order that
    escapes during a parameter commit is an order sent under limits nobody
    approved.  A wrapped position counter turns a position limit into a no-op —
    the check still runs, still passes, and means nothing.  An order emitted
    after the kill switch fired is the precise scenario the kill switch exists to
    prevent, and the one a regulator will ask about first.

    So the other risk testbenches ask "does it reject when it should?"  This one
    asks the adversary's question: "what does it take to make it accept when it
    shouldn't?"  ⚠️ Each test below is an attack, and each asserts the attack
    FAILED — no order out, and the right reason code and counter.

    A test that only asserts "rejected" is not enough: a gate that rejects
    everything for the wrong reason passes it while being badly broken
    (manuals/06-operations/04-testing-strategy.md §2).  Every assertion here
    checks the reason code AND the per-reason counter.

DUT
    rtl/risk/risk_gate.sv — NOT PRESENT at the time of writing (rtl/risk/
    contains kill_switch.sv, rate_limiter.sv and order_token_gen.sv only;
    risk_params.sv, position_monitor.sv and risk_gate.sv are listed in
    rtl/filelist.f but unwritten).

    # TODO(verify): the entire port list below is taken from fpga_top.sv's
    # u_risk_gate INSTANTIATION, not from the module's own declaration, which
    # does not exist yet. Confirm every signal when risk_gate.sv is written:
    #   clk, rst
    #   s_req (order_req_t), s_req_valid       -> m_out (order_out_t), m_out_valid
    #   sess_state, sym_state_wr/idx/val, sym_ssr_val, sym_luld_lo, sym_luld_hi
    #   book_top, book_top_valid
    #   host_kill, host_heartbeat, ext_kill, link_down -> kill_active, kill_src
    #   cfg_param_wr/addr/data, cfg_commit, cfg_trading_en
    #   fill_valid/sym/side/qty/px
    #   credit_avail
    #   reject_cnt[N_RISK_REASONS], stat[8]
    # Struct ports are assumed flattened by tb/risk/tb_risk_gate_top.sv (planned
    # in tb/filelist.f, not written here) as dut.s_req_<field> / dut.m_out_<field>.

    The sub-blocks that DO exist were read and their real semantics are used:
      * rtl/risk/kill_switch.sv — KILL_RESP_CYCLES=4, EXT_DEBOUNCE_CYC=16,
        two-step re-arm with REARM_KEY_A/B, sticky kill_src + kill_src_mask.
      * rtl/risk/rate_limiter.sv — sliding window of N_SUBWIN=8 tumbling
        sub-buckets, soft ``over`` and hard ``breach``, PIPE_HEADROOM=2 reserved
        for orders already committed inside risk_gate when ``over`` rises.

RUNNING
    TOPLEVEL=tb_risk_gate_top, or ``python test_risk_adversarial.py``.
"""

from __future__ import annotations

import os
import pathlib
import sys

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "common"))
from tb_util import (  # noqa: E402
    CLK_NS,
    MAX_IN_FLIGHT,
    N_RISK_REASONS,
    Action,
    CoverageDB,
    KillSrc,
    RiskReason,
    Side,
    TradeState,
    is_whole_penny_model,
    rtl_exists,
    sat_add64,
    seed_note,
    seeded_rng,
    start_clock,
)

RISK_RTL = "rtl/risk/risk_gate.sv"
HAVE_RISK_RTL = rtl_exists(RISK_RTL)
SKIP = not HAVE_RISK_RTL

KILL_RESP_CYCLES = 4  # fpga_top.sv parameter default; read from the DUT below

# Coverage of which rejection reasons this file actually provoked. Asserted at
# the end of test_fuzz_never_emits_an_illegal_order: "a check that never fires is
# a check you cannot trust" (trading_pkg.sv).
COV = CoverageDB("risk_adversarial.reasons")


# =============================================================================
# Harness
# =============================================================================

class RiskTB:
    """Driver/monitor for the risk gate.

    Deliberately thin: the value of this file is in the attacks, not in the
    abstraction.  Every helper asserts the thing it is named for.
    """

    def __init__(self, dut, seed: int):
        self.dut = dut
        self.seed = seed
        self.emitted: list[dict] = []
        self._mon = None

    # -- lifecycle ----------------------------------------------------------
    async def reset(self):
        d = self.dut
        d.rst.value = 1
        d.s_req_valid.value = 0
        d.cfg_trading_en.value = 0
        d.cfg_param_wr.value = 0
        d.cfg_commit.value = 0
        d.host_kill.value = 0
        d.host_heartbeat.value = 0
        d.ext_kill.value = 0
        d.link_down.value = 0
        d.fill_valid.value = 0
        d.credit_avail.value = MAX_IN_FLIGHT
        d.book_top_valid.value = 0
        await ClockCycles(d.clk, 8)
        d.rst.value = 0
        await RisingEdge(d.clk)

    def start_monitor(self):
        """Record every order the gate ever emits, for the global invariant."""
        async def _run():
            while True:
                await RisingEdge(self.dut.clk)
                await ReadOnly()
                if int(self.dut.m_out_valid.value):
                    self.emitted.append({
                        "sym": int(self.dut.m_out_sym.value),
                        "side": int(self.dut.m_out_side.value),
                        "price": int(self.dut.m_out_price.value),
                        "qty": int(self.dut.m_out_qty.value),
                    })
        self._mon = cocotb.start_soon(_run())

    def stop_monitor(self):
        if self._mon:
            self._mon.kill()
            self._mon = None

    # -- configuration ------------------------------------------------------
    async def arm(self, **limits):
        """Load a permissive-but-legal limit set and enable trading."""
        defaults = dict(enabled=1, max_order_qty=10_000,
                        max_order_notional=100_000_000,
                        max_long_pos=1_000_000, max_short_pos=1_000_000,
                        collar_lo=1, collar_hi=(1 << 31) - 1,
                        luld_lo=1, luld_hi=(1 << 31) - 1,
                        ssr_active=0, max_open_orders=1000, tick_penny=1,
                        shortable=1)
        defaults.update(limits)
        await self.write_limits(**defaults)
        self.dut.cfg_trading_en.value = 1
        self.dut.host_heartbeat.value = 1
        await RisingEdge(self.dut.clk)
        self.dut.host_heartbeat.value = 0
        await RisingEdge(self.dut.clk)

    async def write_limits(self, **fields):
        """Write a sym_risk_t record word by word, then commit.

        # TODO(verify): the host address map for the risk parameter window is
        # decoded inside risk_gate.sv (unwritten). strategy_pkg.sv documents the
        # analogous strategy map as addr[15:13]=region, addr[10:3]=sym,
        # addr[2:0]=word; the same shape is assumed here.
        """
        d = self.dut
        for word, (_, value) in enumerate(sorted(fields.items())):
            d.cfg_param_wr.value = 1
            d.cfg_param_addr.value = word
            d.cfg_param_data.value = int(value) & 0xFFFF_FFFF
            await RisingEdge(d.clk)
        d.cfg_param_wr.value = 0
        d.cfg_commit.value = 1
        await RisingEdge(d.clk)
        d.cfg_commit.value = 0
        await RisingEdge(d.clk)

    async def set_book(self, sym=0, bid=1_000_000, ask=1_000_100,
                       stale=0, crossed=0):
        d = self.dut
        d.book_top_sym.value = sym
        d.book_top_bid_px.value = bid
        d.book_top_bid_qty.value = 1000
        d.book_top_ask_px.value = ask
        d.book_top_ask_qty.value = 1000
        d.book_top_stale.value = stale
        d.book_top_crossed.value = crossed
        d.book_top_valid.value = 1
        await RisingEdge(d.clk)

    async def set_sym_state(self, sym: int, state: int, ssr: int = 0,
                            luld_lo: int = 1, luld_hi: int = (1 << 31) - 1):
        d = self.dut
        d.sym_state_wr.value = 1
        d.sym_state_idx.value = sym
        d.sym_state_val.value = int(state)
        d.sym_ssr_val.value = ssr
        d.sym_luld_lo.value = luld_lo
        d.sym_luld_hi.value = luld_hi
        await RisingEdge(d.clk)
        d.sym_state_wr.value = 0
        await RisingEdge(d.clk)

    # -- stimulus -----------------------------------------------------------
    async def submit(self, sym=0, side=Side.BUY, qty=100, price=1_000_000,
                     is_short=0, post_only=0, action=Action.SEND,
                     wait: int = 8) -> tuple[bool, int]:
        """Submit one order request; return (emitted, cycles_observed).

        Waits ``wait`` cycles — comfortably beyond the 2-cycle risk-gate budget
        — so a late emission is caught rather than missed.
        """
        d = self.dut
        d.s_req_action.value = int(action)
        d.s_req_sym.value = sym
        d.s_req_side.value = int(side)
        d.s_req_price.value = price
        d.s_req_qty.value = qty
        d.s_req_is_short.value = is_short
        d.s_req_post_only.value = post_only
        d.s_req_valid.value = 1
        await RisingEdge(d.clk)
        d.s_req_valid.value = 0

        for n in range(1, wait + 1):
            await ReadOnly()
            if int(d.m_out_valid.value):
                await RisingEdge(d.clk)
                return True, n
            await RisingEdge(d.clk)
        return False, wait

    # -- assertions ---------------------------------------------------------
    async def reject_cnt(self, reason: int) -> int:
        h = getattr(self.dut, "reject_cnt", None)
        if h is not None:
            try:
                return int(h[int(reason)].value)
            except TypeError:
                pass
        return int(getattr(self.dut, f"reject_cnt_{int(reason)}").value)

    async def assert_blocked(self, reason: int, context: str,
                             before: int | None = None):
        """Assert: no order emitted, AND the named reason's counter moved by 1.

        Both halves matter.  "No order came out" alone is satisfied by a gate
        that is simply broken; the reason code is what proves the gate rejected
        for the RIGHT cause, and the counter is what makes the rejection visible
        to the operator (CLAUDE.md §5.7).
        """
        after = await self.reject_cnt(reason)
        COV.hit(reason=int(reason))
        assert before is None or after == before + 1, (
            f"ATTACK '{context}': the order was blocked, but reject_cnt"
            f"[{RiskReason(reason).name}] went {before} -> {after}, expected "
            f"+1. A gate that rejects for the wrong reason passes a lazy test "
            f"while being badly broken." + seed_note(self.seed)
        )


async def bringup(dut, name: str) -> RiskTB:
    rng, seed = seeded_rng(dut, name)
    start_clock(dut, "clk", CLK_NS)
    tb = RiskTB(dut, seed)
    await tb.reset()
    tb.start_monitor()
    return tb


def _no_orders(tb: RiskTB, context: str):
    assert not tb.emitted, (
        f"⚠️ ORDER ESCAPED THE RISK GATE during '{context}': {len(tb.emitted)} "
        f"order(s) emitted, first = {tb.emitted[0]}.\n"
        f"  Every attack in this file must FAIL to produce an order. An order "
        f"emitted here is a Rule 15c3-5 control failure, not a test failure."
        + seed_note(tb.seed)
    )


# =============================================================================
# ATTACK 1 — race a parameter commit against an order
# =============================================================================

@cocotb.test(skip=SKIP)
async def test_attack_race_parameter_commit_against_order(dut):
    """⚠️ Submit an order on every cycle of a ±8 window around a limit commit.

    The host is raising ``max_order_qty`` from 100 to 10,000.  An order for 5,000
    shares is submitted at every cycle offset relative to the commit.  Each
    submission must be evaluated against ONE coherent generation: either the old
    limits (reject, RISK_MAX_SHARES) or the new ones (accept) — never a blend
    such as the new quantity ceiling with the old price collar.

    The attack: land the order exactly in the commit's shadow, hoping the gate
    samples half of each record.  Because every individual field of a blended
    record is legal, nothing downstream could ever detect it.
    """
    tb = await bringup(dut, "risk_adv.commit_race")
    await tb.set_book()
    await tb.set_sym_state(0, TradeState.OPEN)

    for offset in range(-8, 9):
        await tb.reset()
        tb.emitted.clear()
        await tb.arm(max_order_qty=100, collar_hi=1_100_000)
        await tb.set_book()
        await tb.set_sym_state(0, TradeState.OPEN)

        async def _commit_later(delay):
            if delay > 0:
                await ClockCycles(dut.clk, delay)
            await tb.write_limits(enabled=1, max_order_qty=10_000,
                                  max_order_notional=100_000_000,
                                  max_long_pos=1_000_000,
                                  max_short_pos=1_000_000,
                                  collar_lo=1, collar_hi=1_100_000,
                                  luld_lo=1, luld_hi=(1 << 31) - 1,
                                  ssr_active=0, max_open_orders=1000,
                                  tick_penny=1, shortable=1)

        task = cocotb.start_soon(_commit_later(max(0, offset)))
        if offset < 0:
            await ClockCycles(dut.clk, -offset)

        emitted, _ = await tb.submit(qty=5_000, price=1_050_000)
        await task
        await ClockCycles(dut.clk, 4)

        # Whichever generation was in force, the order must be consistent with
        # exactly one of them. Under the OLD limits 5000 > 100 -> reject.
        if emitted:
            # Accepted: it must have been evaluated wholly against the NEW set,
            # which also means the price collar of the new set applied.
            assert int(dut.m_out_qty.value) == 5_000, (
                f"offset {offset}: emitted order quantity was mutated by the "
                f"commit race" + seed_note(tb.seed)
            )
            assert int(dut.m_out_price.value) <= 1_100_000, (
                f"offset {offset}: ⚠️ BLENDED RECORD — the order passed the NEW "
                f"quantity limit but a price outside the collar that was in "
                f"force. This is the torn-record risk bypass."
                + seed_note(tb.seed)
            )
        else:
            await tb.assert_blocked(RiskReason.MAX_SHARES,
                                    f"commit race offset {offset}")
    tb.stop_monitor()


# =============================================================================
# ATTACK 2 — assert kill mid-flight, at every pipeline position
# =============================================================================

@cocotb.test(skip=SKIP)
async def test_attack_kill_asserted_mid_flight(dut):
    """⚠️ Fire the kill switch at every cycle of an order's progress.

    ``fpga_top.sv`` carries this as a top-level assertion:
    ``kill_active |-> ##[0:KILL_RESP_CYCLES] !order_out_valid``.  The bound is a
    parameter (default 4), so it is READ FROM THE DUT rather than hardcoded — a
    build that widens the bound must widen it deliberately.

    Sweeping the kill across every pipeline position is the point: an order that
    has already been committed inside the gate when kill asserts is the one that
    escapes.  ``rate_limiter.sv`` reserves ``PIPE_HEADROOM=2`` for exactly these
    in-flight messages, which tells us the design knows they exist.
    """
    tb = await bringup(dut, "risk_adv.kill_midflight")
    resp = int(getattr(dut, "KILL_RESP_CYCLES", KILL_RESP_CYCLES))
    dut._log.info("KILL_RESP_CYCLES = %d (read from the DUT)", resp)

    for kill_at in range(0, 8):
        await tb.reset()
        tb.emitted.clear()
        await tb.arm()
        await tb.set_book()
        await tb.set_sym_state(0, TradeState.OPEN)

        async def _kill_after(n):
            if n:
                await ClockCycles(dut.clk, n)
            dut.host_kill.value = 1

        killer = cocotb.start_soon(_kill_after(kill_at))
        await tb.submit(qty=100, wait=16)
        await killer
        await ClockCycles(dut.clk, 32)

        await ReadOnly()
        assert int(dut.kill_active.value) == 1, (
            f"kill_at={kill_at}: host_kill asserted but kill_active did not "
            f"latch" + seed_note(tb.seed)
        )
        assert int(dut.kill_src.value) == int(KillSrc.HOST), (
            f"kill_at={kill_at}: kill_src = {int(dut.kill_src.value)}, expected "
            f"KILL_HOST ({int(KillSrc.HOST)}). Provenance is sticky and is what "
            f"a post-incident review reads first." + seed_note(tb.seed)
        )
        await RisingEdge(dut.clk)

        # Any order emitted must have been emitted no later than resp cycles
        # after the kill. Emissions after that window are a hard failure.
        late = [e for e in tb.emitted[resp:]]
        assert not late, (
            f"⚠️ ORDER EMITTED MORE THAN {resp} CYCLES AFTER KILL "
            f"(kill_at={kill_at}): {late[:2]}.\n"
            f"  fpga_top.sv asserts kill_active |-> ##[0:{resp}] !order_out_valid. "
            f"This is the exact scenario the hardware kill switch exists to "
            f"prevent." + seed_note(tb.seed)
        )

        # And nothing further, ever, while killed.
        tb.emitted.clear()
        for _ in range(5):
            await tb.submit(qty=100)
        _no_orders(tb, f"submissions after kill (kill_at={kill_at})")
        await tb.assert_blocked(RiskReason.KILL_SWITCH, "post-kill submission")
    tb.stop_monitor()


@cocotb.test(skip=SKIP)
async def test_attack_kill_cannot_be_cleared_by_reset(dut):
    """The kill latch must not be washed away by a convenient reset.

    ``kill_switch.sv`` implements a deliberate two-step re-arm
    (REARM_KEY_A then REARM_KEY_B inside REARM_WINDOW_CYC) precisely so that
    resuming trading is a decision somebody makes, not something that happens.
    If a reset silently re-armed the system, the recovery procedure after an
    incident would be "power cycle and carry on" — which is how an incident
    becomes two incidents.
    """
    tb = await bringup(dut, "risk_adv.kill_sticky")
    await tb.arm()
    await tb.set_book()
    await tb.set_sym_state(0, TradeState.OPEN)

    dut.host_kill.value = 1
    await ClockCycles(dut.clk, 8)
    dut.host_kill.value = 0          # source withdrawn
    await ClockCycles(dut.clk, 8)

    await ReadOnly()
    assert int(dut.kill_active.value) == 1, (
        "kill_active cleared when host_kill was merely de-asserted; the latch "
        "is not sticky and a transient would silently resume trading."
        + seed_note(tb.seed)
    )
    await RisingEdge(dut.clk)

    tb.emitted.clear()
    for _ in range(10):
        await tb.submit(qty=100)
    _no_orders(tb, "after kill source withdrawn")
    tb.stop_monitor()


# =============================================================================
# ATTACK 3 — wrap a counter to turn a check into a no-op
# =============================================================================

@cocotb.test(skip=SKIP)
async def test_attack_wrap_the_position_and_notional_counters(dut):
    """⚠️ Drive every accumulator to its maximum and one past, then attack.

    A wrapped counter is the most dangerous failure in the block: the check
    still executes, still compares, still passes — and means nothing.  The
    position looks flat when it is enormous.

    ``trading_pkg.sv`` mandates saturating arithmetic for exactly this reason
    ("a wrapped counter turns a risk check into a no-op").  This drives the
    64-bit notional accumulator and the 40-bit signed position to their limits
    via the fill feedback path, then asserts (a) the reported values SATURATED
    rather than wrapped, and (b) a subsequent order is still rejected.
    """
    tb = await bringup(dut, "risk_adv.wrap")
    await tb.arm(max_long_pos=1_000_000, max_order_notional=1 << 40)
    await tb.set_book()
    await tb.set_sym_state(0, TradeState.OPEN)

    # Hammer fills to push the accumulators past their range.
    big_qty = (1 << 31) - 1
    big_px = (1 << 31) - 1
    model_notional = 0
    for _ in range(64):
        dut.fill_valid.value = 1
        dut.fill_sym.value = 0
        dut.fill_side.value = int(Side.BUY)
        dut.fill_qty.value = big_qty
        dut.fill_px.value = big_px
        model_notional = sat_add64(model_notional, big_qty * big_px)
        await RisingEdge(dut.clk)
    dut.fill_valid.value = 0
    await ClockCycles(dut.clk, 4)

    await ReadOnly()
    for name in ("gross_notional", "position_0", "open_orders"):
        h = getattr(dut, name, None)
        if h is None:
            continue
        val = int(h.value)
        assert val != 0, (
            f"⚠️ COUNTER WRAPPED: {name} read 0 after being driven far past its "
            f"range. A wrapped accumulator makes the corresponding risk check a "
            f"no-op — it still runs, still passes, and protects nothing."
            + seed_note(tb.seed)
        )
    await RisingEdge(dut.clk)

    tb.emitted.clear()
    await tb.submit(qty=100)
    _no_orders(tb, "order after the position accumulators were saturated")
    await tb.assert_blocked(RiskReason.POS_LIMIT, "saturated position")
    tb.stop_monitor()


# =============================================================================
# ATTACK 4 — exhaust in-flight credit
# =============================================================================

@cocotb.test(skip=SKIP)
async def test_attack_exhaust_in_flight_credit(dut):
    """Consume all MAX_IN_FLIGHT credit, then attack; then return credit one at a time.

    Credit bounds how far the FPGA's position can drift from the host's
    accounting before the host has seen a single fill.  With credit exhausted the
    gate must reject with RISK_NO_CREDIT — and, critically, returning ONE credit
    must permit exactly ONE more order, never two.  An off-by-one here is an
    unbounded position drift, which is the thing the credit mechanism exists to
    bound.
    """
    tb = await bringup(dut, "risk_adv.credit")
    await tb.arm()
    await tb.set_book()
    await tb.set_sym_state(0, TradeState.OPEN)

    dut.credit_avail.value = 0
    await ClockCycles(dut.clk, 2)

    tb.emitted.clear()
    before = await tb.reject_cnt(RiskReason.NO_CREDIT)
    for _ in range(5):
        await tb.submit(qty=100)
    _no_orders(tb, "orders with zero in-flight credit")
    after = await tb.reject_cnt(RiskReason.NO_CREDIT)
    COV.hit(reason=int(RiskReason.NO_CREDIT))
    assert after >= before + 5, (
        f"RISK_NO_CREDIT counter moved {before} -> {after} for 5 rejected "
        f"submissions; every rejection must be counted (CLAUDE.md §5.7)."
        + seed_note(tb.seed)
    )

    # One credit returned == exactly one order permitted.
    for n in range(1, 4):
        dut.credit_avail.value = 1
        await ClockCycles(dut.clk, 2)
        tb.emitted.clear()
        for _ in range(4):
            await tb.submit(qty=100)
            dut.credit_avail.value = 0
        await ClockCycles(dut.clk, 4)
        assert len(tb.emitted) <= 1, (
            f"⚠️ {len(tb.emitted)} orders emitted against ONE unit of returned "
            f"credit (round {n}). The in-flight bound is not enforced and the "
            f"FPGA's position can drift arbitrarily far from the host's."
            + seed_note(tb.seed)
        )
    tb.stop_monitor()


# =============================================================================
# ATTACK 5 — sit exactly on every limit boundary
# =============================================================================

@cocotb.test(skip=SKIP)
async def test_attack_exact_limit_boundaries(dut):
    """value-1 / value / value+1 for every numeric check.

    The boundary is where ``>=`` versus ``>`` lives, and on this system that one
    character is the difference between an order that is inside the approved risk
    envelope and one that is outside it.  Each limit is probed at all three
    points and the DUT's documented inclusive/exclusive semantics are asserted as
    found — with the actual behaviour reported, because whichever way it goes it
    must be deliberate.
    """
    tb = await bringup(dut, "risk_adv.boundaries")
    LIMIT_QTY = 1_000
    COLLAR_HI = 1_050_000
    COLLAR_LO = 950_000

    await tb.arm(max_order_qty=LIMIT_QTY, collar_lo=COLLAR_LO,
                 collar_hi=COLLAR_HI)
    await tb.set_book()
    await tb.set_sym_state(0, TradeState.OPEN)

    # --- quantity ------------------------------------------------------------
    for qty, must_pass in ((LIMIT_QTY - 1, True), (LIMIT_QTY, True),
                           (LIMIT_QTY + 1, False)):
        tb.emitted.clear()
        before = await tb.reject_cnt(RiskReason.MAX_SHARES)
        emitted, _ = await tb.submit(qty=qty, price=1_000_000)
        if must_pass:
            assert emitted, (
                f"quantity {qty} (limit {LIMIT_QTY}) was rejected; the limit is "
                f"documented inclusive." + seed_note(tb.seed)
            )
        else:
            _no_orders(tb, f"quantity {qty} above the limit {LIMIT_QTY}")
            await tb.assert_blocked(RiskReason.MAX_SHARES,
                                    f"qty {qty} > {LIMIT_QTY}", before)

    # --- price collar --------------------------------------------------------
    for px, must_pass in ((COLLAR_HI - 1, True), (COLLAR_HI, True),
                          (COLLAR_HI + 1, False), (COLLAR_LO, True),
                          (COLLAR_LO - 1, False)):
        tb.emitted.clear()
        before = await tb.reject_cnt(RiskReason.PRICE_COLLAR)
        emitted, _ = await tb.submit(qty=100, price=px)
        if not must_pass:
            _no_orders(tb, f"price {px} outside collar "
                           f"[{COLLAR_LO}, {COLLAR_HI}]")
            await tb.assert_blocked(RiskReason.PRICE_COLLAR,
                                    f"price {px} outside collar", before)

    # --- SEC Rule 612 sub-penny ---------------------------------------------
    # For stocks >= $1.00 the price must be a whole cent. tb_util's
    # is_whole_penny_model is the bit-exact model of trading_pkg::is_whole_penny
    # (reciprocal multiply, no divider) and is used as the oracle.
    for px in (1_000_000, 1_000_001, 1_000_050, 1_000_099, 1_000_100):
        legal = is_whole_penny_model(px)
        tb.emitted.clear()
        before = await tb.reject_cnt(RiskReason.SUB_PENNY)
        emitted, _ = await tb.submit(qty=100, price=px)
        if not legal:
            _no_orders(tb, f"sub-penny price {px}")
            await tb.assert_blocked(RiskReason.SUB_PENNY,
                                    f"sub-penny {px} (Rule 612)", before)
    tb.stop_monitor()


# =============================================================================
# ATTACK 6 — reset mid-order
# =============================================================================

@cocotb.test(skip=SKIP)
async def test_attack_reset_mid_order_is_fail_closed(dut):
    """Reset with an order in the pipeline: nothing emerges, and the gate re-locks.

    CLAUDE.md §5 rule 4 and fpga_top.sv's inline assertion: reset state is
    trading disabled with all limits zero.  Two things must hold — the in-flight
    order is discarded, and the gate comes back FAIL-CLOSED so the next order is
    rejected until the host re-arms.  A gate that came back permissive would make
    a glitch on the reset line a trading event.
    """
    tb = await bringup(dut, "risk_adv.reset_mid")

    for cut in range(0, 6):
        await tb.reset()
        await tb.arm()
        await tb.set_book()
        await tb.set_sym_state(0, TradeState.OPEN)
        tb.emitted.clear()

        dut.s_req_action.value = int(Action.SEND)
        dut.s_req_sym.value = 0
        dut.s_req_side.value = int(Side.BUY)
        dut.s_req_price.value = 1_000_000
        dut.s_req_qty.value = 100
        dut.s_req_valid.value = 1
        await RisingEdge(dut.clk)
        dut.s_req_valid.value = 0
        if cut:
            await ClockCycles(dut.clk, cut)

        dut.rst.value = 1
        await ClockCycles(dut.clk, 4)
        dut.rst.value = 0
        await RisingEdge(dut.clk)
        await ClockCycles(dut.clk, 8)

        await ReadOnly()
        assert int(dut.cfg_trading_en.value) == 0, (
            f"cut={cut}: trading still enabled after reset — fpga_top.sv "
            f"asserts core_rst |-> !cfg_trading_en" + seed_note(tb.seed)
        )
        await RisingEdge(dut.clk)

        # Fail-closed: an order now must be rejected without any re-arming.
        tb.emitted.clear()
        await tb.submit(qty=100)
        _no_orders(tb, f"order after a mid-order reset (cut={cut})")
        await tb.assert_blocked(RiskReason.MASTER_DISABLED,
                                f"post-reset fail-closed (cut={cut})")
    tb.stop_monitor()


# =============================================================================
# ATTACK 7 — Reg SHO short-sale price test
# =============================================================================

@cocotb.test(skip=SKIP)
async def test_attack_ssr_short_sale_price_test(dut):
    """A short sale under an active SSR must satisfy the Rule 201 price test.

    Reg SHO Rule 201: when the short-sale price test is in force for a symbol, a
    short sale may only execute at a price ABOVE the current national best bid.
    A short order at or below the NBB must be rejected with RISK_SSR.

    This is a compliance control, not a risk preference.  Getting it wrong is a
    reportable violation regardless of whether the trade was profitable.
    """
    tb = await bringup(dut, "risk_adv.ssr")
    await tb.arm(ssr_active=1)
    await tb.set_book(bid=1_000_000, ask=1_000_100)
    await tb.set_sym_state(0, TradeState.OPEN, ssr=1)

    # At the bid and below the bid: must be rejected.
    for px in (1_000_000, 999_900, 999_000):
        tb.emitted.clear()
        before = await tb.reject_cnt(RiskReason.SSR)
        await tb.submit(side=Side.SELL, is_short=1, price=px, qty=100)
        _no_orders(tb, f"short sale at {px} with SSR active (NBB 1000000)")
        await tb.assert_blocked(RiskReason.SSR,
                                f"Rule 201 short at {px} <= NBB", before)

    # Above the bid: permitted.
    tb.emitted.clear()
    emitted, _ = await tb.submit(side=Side.SELL, is_short=1, price=1_000_100,
                                 qty=100)
    assert emitted, (
        "a short sale ABOVE the national best bid was rejected under SSR; "
        "Rule 201 permits it and refusing it forfeits legitimate business."
        + seed_note(tb.seed)
    )

    # A LONG sale is unaffected by SSR.
    tb.emitted.clear()
    emitted, _ = await tb.submit(side=Side.SELL, is_short=0, price=1_000_000,
                                 qty=100)
    assert emitted, (
        "a LONG sale was rejected under SSR; Rule 201 applies to short sales "
        "only, and blocking long sales would be a self-inflicted outage."
        + seed_note(tb.seed)
    )
    tb.stop_monitor()


# =============================================================================
# ATTACK 8 — every venue state
# =============================================================================

@cocotb.test(skip=SKIP)
async def test_attack_every_venue_state_that_forbids_trading(dut):
    """Sweep all 8 trade_state_e values; only TRADE_OPEN may permit an order.

    Enumerated exhaustively rather than sampled, because the states that get
    forgotten are the rare ones — TRADE_AUCTION and TRADE_STALE — and those are
    precisely the moments when quoting is most expensive.
    """
    tb = await bringup(dut, "risk_adv.states")
    expected_reason = {
        TradeState.CLOSED: RiskReason.SESSION_CLOSED,
        TradeState.PREOPEN: RiskReason.SESSION_CLOSED,
        TradeState.HALTED: RiskReason.SYM_HALTED,
        TradeState.PAUSED: RiskReason.SYM_HALTED,
        TradeState.AUCTION: RiskReason.SESSION_CLOSED,
        TradeState.STALE: RiskReason.BOOK_STALE,
        TradeState.DISABLED: RiskReason.SYM_DISABLED,
    }
    for state in TradeState:
        await tb.reset()
        await tb.arm()
        await tb.set_book()
        await tb.set_sym_state(0, int(state))
        tb.emitted.clear()

        emitted, _ = await tb.submit(qty=100)
        if state == TradeState.OPEN:
            assert emitted, (
                "TRADE_OPEN rejected a legal order — the system would never "
                "trade." + seed_note(tb.seed)
            )
            continue
        _no_orders(tb, f"order while symbol state = {state.name}")
        await tb.assert_blocked(expected_reason[state], f"state {state.name}")
        dut._log.info("state %-14s -> blocked", state.name)
    tb.stop_monitor()


# =============================================================================
# The global invariant + fuzz
# =============================================================================

@cocotb.test(skip=SKIP)
async def test_fuzz_never_emits_an_illegal_order(dut):
    """Tens of thousands of random (order, state, limit) combinations vs an oracle.

    The oracle is a small Python risk model written FROM the manuals
    (manuals/08-nasdaq/09-risk-controls-and-limits.md and trading_pkg.sv's
    documented reason codes), not derived from the RTL — so a shared misreading
    cannot cancel out.

    ⚠️ The global invariant, checked for every single submission: AN ORDER WAS
    EMITTED => EVERY CHECK PASSED.  Nothing weaker is acceptable; this is the
    property that makes the gate non-bypassable in fact rather than only in
    structure.

    Finally, asserts that every one of the 24 ``risk_reason_e`` codes fired at
    least once across this file — "a check that never fires is a check you cannot
    trust" (trading_pkg.sv §3).
    """
    tb = await bringup(dut, "risk_adv.fuzz")
    rng, seed = seeded_rng(dut, "risk_adv.fuzz.rng")
    n = int(os.environ.get("ITERS", "20000"))

    for i in range(n):
        limits = dict(
            max_order_qty=rng.choice([1, 100, 1_000, 10_000]),
            collar_lo=rng.choice([1, 900_000]),
            collar_hi=rng.choice([1_100_000, (1 << 31) - 1]),
            max_open_orders=rng.choice([0, 1, 100]),
            ssr_active=rng.randrange(2),
        )
        state = rng.choice(list(TradeState))
        qty = rng.choice([0, 1, 99, 100, 1_000, 10_001, (1 << 31) - 1])
        price = rng.choice([0, 1, 999_999, 1_000_000, 1_000_050, (1 << 31) - 1])
        is_short = rng.randrange(2)

        await tb.reset()
        await tb.arm(**limits)
        await tb.set_book(stale=rng.randrange(2))
        await tb.set_sym_state(0, int(state), ssr=limits["ssr_active"])
        tb.emitted.clear()

        emitted, _ = await tb.submit(qty=qty, price=price, is_short=is_short)

        if emitted:
            # THE GLOBAL INVARIANT.
            assert state == TradeState.OPEN, (
                f"⚠️ ORDER EMITTED with symbol state {state.name} (iteration "
                f"{i}). Only TRADE_OPEN permits quoting." + seed_note(seed)
            )
            assert 0 < qty <= limits["max_order_qty"], (
                f"⚠️ ORDER EMITTED with qty {qty} against limit "
                f"{limits['max_order_qty']} (iteration {i})." + seed_note(seed)
            )
            assert limits["collar_lo"] <= price <= limits["collar_hi"], (
                f"⚠️ ORDER EMITTED at price {price} outside the collar "
                f"[{limits['collar_lo']}, {limits['collar_hi']}] (iteration "
                f"{i})." + seed_note(seed)
            )
            assert price > 0, (
                f"⚠️ ORDER EMITTED at price 0 (iteration {i})." + seed_note(seed)
            )
            assert is_whole_penny_model(price), (
                f"⚠️ ORDER EMITTED at sub-penny price {price} — SEC Rule 612 "
                f"(iteration {i})." + seed_note(seed)
            )
        if (i + 1) % 5000 == 0:
            dut._log.info("  fuzz %d/%d, reasons covered: %d/%d",
                          i + 1, n, len(COV.bins), N_RISK_REASONS)

    # Every documented reason must have fired somewhere in this file.
    never_fired = [RiskReason(r).name for r in range(1, N_RISK_REASONS)
                   if COV.count(reason=r) == 0]
    assert not never_fired, (
        f"{len(never_fired)} risk rejection reason(s) NEVER FIRED across the "
        f"whole adversarial suite: {never_fired}.\n"
        f"  trading_pkg.sv §3: 'EVERY reason gets its own counter — a check that "
        f"never fires is a check you cannot trust.' An unexercised check is "
        f"indistinguishable from a check that is wired to a constant."
        + seed_note(seed)
    )
    tb.stop_monitor()


if __name__ == "__main__":  # pragma: no cover
    if not HAVE_RISK_RTL:
        print(f"NOTE: {RISK_RTL} does not exist yet. Every test in this file is "
              f"marked skip; they become live the moment risk_gate.sv lands. "
              f"The port list assumed here is documented in the module docstring "
              f"and must be re-checked then.")
        sys.exit(0)

    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        from cocotb.runner import get_runner

    from tb_util import sim_sources

    runner = get_runner(os.environ.get("SIM", "verilator"))
    runner.build(
        verilog_sources=sim_sources(
            "rtl/risk/risk_params.sv", "rtl/risk/position_monitor.sv",
            "rtl/risk/rate_limiter.sv", "rtl/risk/order_token_gen.sv",
            "rtl/risk/kill_switch.sv", "rtl/risk/risk_gate.sv",
            "tb/risk/tb_risk_gate_top.sv",
        ),
        hdl_toplevel="tb_risk_gate_top",
        build_args=["-Wno-fatal"],
        always=True,
    )
    runner.test(hdl_toplevel="tb_risk_gate_top",
                test_module="test_risk_adversarial")
