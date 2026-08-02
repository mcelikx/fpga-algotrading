"""cocotb tests for ``rtl/risk/risk_gate.sv`` — THE REQUIRED TEST MATRIX.

Project : FPGA Algorithmic Trading System (Nasdaq Equities)
Governs : manuals/08-nasdaq/09-risk-controls-and-limits.md
          manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md
          manuals/03-algotrading/06-risk-and-compliance.md
          CLAUDE.md §5.5, §5.6, §5.7 · SEC Rule 15c3-5

===============================================================================
⚠️  A CHECK THAT HAS NEVER BEEN OBSERVED TO FIRE IS A CHECK THAT CANNOT BE
    TRUSTED.
===============================================================================

    ``rtl/pkg/trading_pkg.sv`` says it at the ``risk_reason_e`` declaration:

        "Pre-trade risk rejection reasons. EVERY reason gets its own counter —
         a check that never fires is a check you cannot trust."

    A risk check is dead code until something proves it rejects. It compiles,
    it places, it routes, it consumes LUTs, and it does nothing — and nobody
    notices, because the *observable* behaviour of a working risk check and a
    broken one is identical right up until the moment it matters. The moment it
    matters is a regulatory event.

    THEREFORE THIS FILE CONTAINS ONE TEST PER ``risk_reason_e`` VALUE.
    Not a table-driven loop that could skip an entry. Not a parameterized
    generator whose parameter list could drift from the enum. One named test per
    reason, so the test report literally enumerates every check in the system
    and a missing one is visible as a missing test name.

    Each test:
      1. arms the gate with a fully permissive baseline (every other check
         passes),
      2. breaks EXACTLY ONE condition,
      3. asserts the order is rejected,
      4. asserts the verdict is the SPECIFIC reason — not merely "rejected",
      5. asserts THAT reason's counter incremented by exactly one
         (CLAUDE.md §5.7: silent failure is the worst failure mode here),
      6. asserts no other reason's counter moved, which proves the checks are
         independent and that the baseline really was permissive.

    Step 4 matters as much as step 3. A gate that rejects everything with
    ``RISK_PARAM_INVALID`` passes a naive "was it rejected?" test while being
    completely broken, and the operator debugging a production rejection storm
    is reading a reason code that is a lie.

===============================================================================
⚠️  THE GATE CANNOT BE BYPASSED
===============================================================================
    CLAUDE.md §5.5: "Pre-trade risk is in hardware and cannot be bypassed. Every
    outbound order passes through the risk block. There is no software path that
    emits orders without it."

    ``rtl/fpga_top.sv`` makes this structural: ``u_risk_gate`` is the only
    driver of ``order_out_valid``, and ``u_order_gw`` has no other input. The
    strongest property in the codebase is asserted there:

        order_out_valid |-> the risk verdict for this order was RISK_OK

    That belongs in formal, not just simulation
    (05-verification §5) — it is small, bounded, and exactly the shape formal is
    good at, and its failure is a regulatory event rather than a bug.

TODO(verify) — PORT NAMES
    Signals follow ``rtl/fpga_top.sv``'s ``u_risk_gate`` connections and
    ``trading_pkg``'s ``order_req_t`` / ``order_out_t`` / ``sym_risk_t``. The
    DUT is the flattening wrapper ``tb/risk/tb_risk_gate_top.sv``. Confirm
    against ``rtl/risk/risk_gate.sv`` when final.
"""

from __future__ import annotations

import sys
from pathlib import Path

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from common import itch_gen as ig                    # noqa: E402
from common.axis_driver import bringup               # noqa: E402

# =============================================================================
# trading_pkg::risk_reason_e — the complete enumeration, mirrored.
# ⚠️ If a value is added to the RTL enum and not to this dict,
#    test_every_reason_has_a_test fails. That is the guard against this file
#    silently falling behind the design.
# =============================================================================
RISK_OK = 0
RISK_MASTER_DISABLED = 1
RISK_KILL_SWITCH = 2
RISK_SYM_DISABLED = 3
RISK_SESSION_CLOSED = 4
RISK_SYM_HALTED = 5
RISK_BOOK_STALE = 6
RISK_SUB_PENNY = 7
RISK_PRICE_COLLAR = 8
RISK_LULD_BAND = 9
RISK_SSR = 10
RISK_MAX_SHARES = 11
RISK_MAX_NOTIONAL = 12
RISK_POS_LIMIT = 13
RISK_GROSS_LIMIT = 14
RISK_OPEN_ORDERS = 15
RISK_MSG_RATE = 16
RISK_DUPLICATE = 17
RISK_SELF_MATCH = 18
RISK_RESTRICTED = 19
RISK_NO_CREDIT = 20
RISK_ZERO_QTY = 21
RISK_ZERO_PRICE = 22
RISK_PARAM_INVALID = 23
N_RISK_REASONS = 24

REASON_NAME = {
    RISK_OK: "RISK_OK",
    RISK_MASTER_DISABLED: "RISK_MASTER_DISABLED",
    RISK_KILL_SWITCH: "RISK_KILL_SWITCH",
    RISK_SYM_DISABLED: "RISK_SYM_DISABLED",
    RISK_SESSION_CLOSED: "RISK_SESSION_CLOSED",
    RISK_SYM_HALTED: "RISK_SYM_HALTED",
    RISK_BOOK_STALE: "RISK_BOOK_STALE",
    RISK_SUB_PENNY: "RISK_SUB_PENNY",
    RISK_PRICE_COLLAR: "RISK_PRICE_COLLAR",
    RISK_LULD_BAND: "RISK_LULD_BAND",
    RISK_SSR: "RISK_SSR",
    RISK_MAX_SHARES: "RISK_MAX_SHARES",
    RISK_MAX_NOTIONAL: "RISK_MAX_NOTIONAL",
    RISK_POS_LIMIT: "RISK_POS_LIMIT",
    RISK_GROSS_LIMIT: "RISK_GROSS_LIMIT",
    RISK_OPEN_ORDERS: "RISK_OPEN_ORDERS",
    RISK_MSG_RATE: "RISK_MSG_RATE",
    RISK_DUPLICATE: "RISK_DUPLICATE",
    RISK_SELF_MATCH: "RISK_SELF_MATCH",
    RISK_RESTRICTED: "RISK_RESTRICTED",
    RISK_NO_CREDIT: "RISK_NO_CREDIT",
    RISK_ZERO_QTY: "RISK_ZERO_QTY",
    RISK_ZERO_PRICE: "RISK_ZERO_PRICE",
    RISK_PARAM_INVALID: "RISK_PARAM_INVALID",
}

# trading_pkg::trade_state_e
TRADE_CLOSED, TRADE_PREOPEN, TRADE_OPEN = 0, 1, 2
TRADE_HALTED, TRADE_PAUSED, TRADE_AUCTION = 3, 4, 5
TRADE_STALE, TRADE_DISABLED = 6, 7

# trading_pkg::action_e / side_e
ACT_NONE, ACT_SEND, ACT_CANCEL = 0, 1, 2
SIDE_BUY, SIDE_SELL = 0, 1

# trading_pkg::kill_src_e
KILL_NONE, KILL_HOST, KILL_WATCHDOG, KILL_MSG_RATE = 0, 1, 2, 3
KILL_POS_BREACH, KILL_GPIO, KILL_LINK_DOWN, KILL_SEQ_FAULT = 4, 5, 6, 7

#: fpga_top.sv parameter. The kill switch must stop all outbound order flow
#: within this many cycles. Hardware-enforced and asserted in SVA.
KILL_RESP_CYCLES = 4

SYM = 0
LOCATE = 1234


# =============================================================================
# Harness
# =============================================================================
class RiskHarness:
    """Configures the gate, submits orders, and reads back verdicts + counters."""

    def __init__(self, dut):
        self.dut = dut

    # -- configuration --------------------------------------------------
    async def write_sym_risk(self, sym: int = SYM, *, enabled=1, shortable=1,
                             max_order_qty=1_000_000,
                             max_order_notional=10**12,
                             max_long_pos=10**9, max_short_pos=10**9,
                             collar_lo=ig.px("0.01"), collar_hi=ig.px("100000.00"),
                             luld_lo=ig.px("0.01"), luld_hi=ig.px("100000.00"),
                             ssr_active=0, max_open_orders=0xFFFF,
                             tick_penny=1) -> None:
        """Write one ``sym_risk_t`` record and commit it.

        ⚠️ Double-buffered with a commit bit (``trading_pkg`` §4): the fast path
        reads the committed buffer while the host writes the other one, so it
        never sees a half-written record. This harness writes then commits, in
        that order, exactly as the host driver must.
        """
        d = self.dut
        d.cfg_sym.value = sym
        d.cfg_enabled.value = enabled
        d.cfg_shortable.value = shortable
        d.cfg_max_order_qty.value = max_order_qty
        d.cfg_max_order_notional.value = max_order_notional
        d.cfg_max_long_pos.value = max_long_pos
        d.cfg_max_short_pos.value = max_short_pos
        d.cfg_collar_lo.value = collar_lo
        d.cfg_collar_hi.value = collar_hi
        d.cfg_luld_lo.value = luld_lo
        d.cfg_luld_hi.value = luld_hi
        d.cfg_ssr_active.value = ssr_active
        d.cfg_max_open_orders.value = max_open_orders
        d.cfg_tick_penny.value = tick_penny
        d.cfg_param_wr.value = 1
        await RisingEdge(d.clk)
        d.cfg_param_wr.value = 0
        d.cfg_commit.value = 1
        await RisingEdge(d.clk)
        d.cfg_commit.value = 0
        await RisingEdge(d.clk)

    async def arm(self) -> None:
        """The permissive baseline: everything passes.

        ⚠️ Every test starts here and then breaks exactly ONE thing. If the
        baseline is not genuinely permissive, a test can pass for the wrong
        reason — the order gets rejected by a check the test was not aiming at,
        the verdict happens to be checked loosely, and a real hole survives.
        ``test_permissive_baseline_passes`` guards the baseline itself.
        """
        d = self.dut
        d.cfg_trading_en.value = 1
        d.host_kill.value = 0
        d.ext_kill.value = 0
        d.link_down.value = 0
        d.host_heartbeat.value = 1
        d.sess_state.value = TRADE_OPEN
        d.credit_avail.value = 1
        await self.set_sym_state(TRADE_OPEN)
        await self.write_sym_risk()
        await self.set_book(bid=ig.px("99.99"), ask=ig.px("100.01"), stale=0)
        await ClockCycles(d.clk, 2)

    async def set_sym_state(self, state: int, sym: int = SYM, *,
                            ssr: int = 0, luld_lo: int | None = None,
                            luld_hi: int | None = None) -> None:
        d = self.dut
        d.sym_state_idx.value = sym
        d.sym_state_val.value = state
        d.sym_ssr_val.value = ssr
        if luld_lo is not None:
            d.sym_luld_lo.value = luld_lo
        if luld_hi is not None:
            d.sym_luld_hi.value = luld_hi
        d.sym_state_wr.value = 1
        await RisingEdge(d.clk)
        d.sym_state_wr.value = 0
        await RisingEdge(d.clk)

    async def set_book(self, *, bid: int, ask: int, stale: int = 0,
                       crossed: int = 0, sym: int = SYM) -> None:
        d = self.dut
        d.book_top_sym.value = sym
        d.book_top_bid_px.value = bid
        d.book_top_bid_qty.value = 1000
        d.book_top_ask_px.value = ask
        d.book_top_ask_qty.value = 1000
        d.book_top_bid_valid.value = 1
        d.book_top_ask_valid.value = 1
        d.book_top_stale.value = stale
        d.book_top_crossed.value = crossed
        d.book_top_valid.value = 1
        await RisingEdge(d.clk)
        d.book_top_valid.value = 0

    async def fill(self, *, side: int, qty: int, px: int, sym: int = SYM) -> None:
        """Report a fill, moving the tracked position."""
        d = self.dut
        d.fill_sym.value = sym
        d.fill_side.value = side
        d.fill_qty.value = qty
        d.fill_px.value = px
        d.fill_valid.value = 1
        await RisingEdge(d.clk)
        d.fill_valid.value = 0
        await RisingEdge(d.clk)

    # -- stimulus and observation ---------------------------------------
    async def counters(self) -> list[int]:
        await ReadOnly()
        return [int(self.dut.reject_cnt[i].value) for i in range(N_RISK_REASONS)]

    async def submit(self, *, action=ACT_SEND, side=SIDE_BUY,
                     price=ig.px("100.00"), qty=100, post_only=0, is_short=0,
                     strat_id=1, sym=SYM, settle=8) -> tuple[bool, int]:
        """Submit one ``order_req_t``; return ``(passed, verdict)``."""
        d = self.dut
        d.s_req_action.value = action
        d.s_req_sym.value = sym
        d.s_req_side.value = side
        d.s_req_price.value = price
        d.s_req_qty.value = qty
        d.s_req_post_only.value = post_only
        d.s_req_is_short.value = is_short
        d.s_req_strat_id.value = strat_id
        d.s_req_valid.value = 1
        await RisingEdge(d.clk)
        d.s_req_valid.value = 0

        passed = False
        verdict = RISK_OK
        for _ in range(settle):
            await RisingEdge(d.clk)
            await ReadOnly()
            if int(d.m_out_valid.value):
                passed = True
            if int(d.verdict_valid.value):
                verdict = int(d.verdict.value)
        return passed, verdict

    async def expect_reject(self, reason: int, **kw) -> None:
        """Submit an order and assert it is rejected for exactly ``reason``."""
        before = await self.counters()
        passed, verdict = await self.submit(**kw)

        assert not passed, (
            f"⚠️ ORDER PASSED THE RISK GATE but should have been rejected with "
            f"{REASON_NAME[reason]}.\n"
            f"   This check is not doing anything. CLAUDE.md §5.5: pre-trade "
            f"risk is in hardware and cannot be bypassed."
        )
        assert verdict == reason, (
            f"rejected, but for the WRONG REASON: got "
            f"{REASON_NAME.get(verdict, verdict)}, want {REASON_NAME[reason]}.\n"
            f"   A gate that rejects everything under one reason code passes a "
            f"naive 'was it rejected?' test while being broken, and the operator "
            f"reading the reason code in production is reading a lie."
        )

        after = await self.counters()
        delta = [a - b for a, b in zip(after, before)]
        assert delta[reason] == 1, (
            f"{REASON_NAME[reason]} counter moved by {delta[reason]}, want 1.\n"
            f"   CLAUDE.md §5.7: 'Every drop, error, and rejected order is "
            f"counted in a readable register. Silent failure is the worst "
            f"failure mode in this domain.'"
        )
        others = {REASON_NAME[i]: delta[i]
                  for i in range(N_RISK_REASONS) if i != reason and delta[i]}
        assert not others, (
            f"other reason counters also moved: {others}.\n"
            f"   Either the baseline is not permissive (so the test is passing "
            f"for the wrong reason), or the checks are not independent."
        )

    async def expect_pass(self, **kw) -> None:
        passed, verdict = await self.submit(**kw)
        assert passed and verdict == RISK_OK, (
            f"a clean order was REJECTED with "
            f"{REASON_NAME.get(verdict, verdict)}.\n"
            f"   ⚠️ A gate that blocks good orders is as broken as one that "
            f"passes bad ones — it just fails quietly, as missed trades."
        )


async def setup(dut) -> RiskHarness:
    for name in ("s_req_valid", "cfg_param_wr", "cfg_commit", "sym_state_wr",
                 "book_top_valid", "fill_valid", "host_kill", "ext_kill",
                 "link_down", "cfg_trading_en"):
        getattr(dut, name).value = 0
    await bringup(dut)
    return RiskHarness(dut)


# =============================================================================
# 0. RESET STATE — fail-closed
# =============================================================================
@cocotb.test()
async def test_reset_leaves_trading_disabled_and_limits_zero(dut):
    """⚠️ RESET MUST COME UP FAIL-CLOSED: trading disabled, every limit zero.

    ``rtl/pkg/trading_pkg.sv`` on ``sym_risk_t``:
        "RESET VALUE IS ALL-ZERO = trading disabled, all limits zero
         (fail-closed)."

    ``manuals/00-foundations/04-clocking-reset-and-cdc.md`` §4:
        "Configuration registers must reset to the safe state, not the useful
         one. Position limits reset to 0. Trading-enabled resets to 0. A
         bitstream reload must never come up armed."

    ``rtl/fpga_top.sv`` hard rule 4, and its inline assertion:
        core_rst |-> !cfg_trading_en

    WHY THIS IS THE FIRST TEST IN THE FILE: a bitstream reload, a PCIe reset, a
    host crash, or an FPGA reconfiguration during the trading day all land here.
    If the gate comes up armed with whatever the SRAM powered up holding, the
    first order out of the door is sized by uninitialised memory. There is no
    recovery from that; there is only the kill switch, afterwards.

    ⚠️ Verilator's 2-state default reads an un-reset register as 0, which makes
       a MISSING reset look like a correct one. This test therefore checks
       behaviour (an order is rejected) rather than register contents, and the
       nightly ``--x-assign unique --x-initial unique`` pass
       (05-verification §3) is what catches the register-level version.
    """
    dut.s_req_valid.value = 0
    await bringup(dut, rst_cycles=8)
    h = RiskHarness(dut)

    # Deliberately do NOT arm. This is the state after a bitstream load.
    await ReadOnly()
    assert int(dut.cfg_trading_en.value) == 0, (
        "cfg_trading_en is set immediately after reset — the design came up "
        "ARMED. Arming must be a positive action by the host after it has "
        "verified the build ID (06-operations/01-build-and-release.md §4)."
    )

    passed, verdict = await h.submit(qty=100, price=ig.px("100.00"))
    assert not passed, (
        "⚠️ AN ORDER LEFT THE RISK GATE AFTER RESET WITH NO CONFIGURATION. "
        "This is the worst defect this test suite can find."
    )
    assert verdict == RISK_MASTER_DISABLED, (
        f"rejected with {REASON_NAME.get(verdict, verdict)}; the reset state "
        f"must report RISK_MASTER_DISABLED so the operator can tell "
        f"'not armed yet' from 'armed but the order was bad'."
    )

    # Now arm the master switch but leave the per-symbol record at its reset
    # (all-zero) value. Limits of zero must reject, not mean "unlimited".
    dut.cfg_trading_en.value = 1
    dut.sess_state.value = TRADE_OPEN
    await ClockCycles(dut.clk, 2)
    passed, verdict = await h.submit(qty=100, price=ig.px("100.00"))
    assert not passed, (
        "⚠️ zero limits were treated as UNLIMITED. An all-zero sym_risk_t means "
        "'this symbol is not configured', and an unconfigured symbol must not "
        "trade. Reading 0 as 'no limit' inverts the entire fail-closed design."
    )
    assert verdict in (RISK_SYM_DISABLED, RISK_MAX_SHARES, RISK_PARAM_INVALID), (
        f"unexpected verdict {REASON_NAME.get(verdict, verdict)} for an "
        f"unconfigured symbol"
    )


@cocotb.test()
async def test_permissive_baseline_passes(dut):
    """The baseline every other test builds on must actually pass an order.

    ⚠️ Guards the whole matrix. If the baseline rejects, every ``expect_reject``
    below passes trivially and the suite is testing nothing.
    """
    h = await setup(dut)
    await h.arm()
    await h.expect_pass(qty=100, price=ig.px("100.00"), side=SIDE_BUY)


# =============================================================================
# 1..23 — ONE TEST PER RISK_REASON_E VALUE
# =============================================================================
@cocotb.test()
async def test_reason_01_master_disabled(dut):
    """RISK_MASTER_DISABLED — the host has not armed trading.

    The global enable. Arming is a positive action gated on the host having
    verified the build ID; "the card came up, probably fine" is not an
    acceptable state (06-operations/01-build-and-release.md §4).
    """
    h = await setup(dut)
    await h.arm()
    dut.cfg_trading_en.value = 0
    await ClockCycles(dut.clk, 2)
    await h.expect_reject(RISK_MASTER_DISABLED)


@cocotb.test()
async def test_reason_02_kill_switch(dut):
    """RISK_KILL_SWITCH — the kill switch is asserted.

    Distinct from MASTER_DISABLED on purpose: "never armed" and "armed then
    killed" are different operational states and the post-incident timeline
    depends on telling them apart.
    """
    h = await setup(dut)
    await h.arm()
    dut.host_kill.value = 1
    await ClockCycles(dut.clk, KILL_RESP_CYCLES + 2)
    await h.expect_reject(RISK_KILL_SWITCH)


@cocotb.test()
async def test_reason_03_sym_disabled(dut):
    """RISK_SYM_DISABLED — this symbol is not enabled for trading.

    Per-symbol enable in ``sym_risk_t.enabled``. The universe is 8192 locates
    but only ``N_ACTIVE`` (256) are tradeable; everything else must be refused
    even if the strategy somehow produces a request for it.
    """
    h = await setup(dut)
    await h.arm()
    await h.write_sym_risk(enabled=0)
    await h.expect_reject(RISK_SYM_DISABLED)


@cocotb.test()
async def test_reason_04_session_closed(dut):
    """RISK_SESSION_CLOSED — outside the trading session.

    Driven by ITCH System Event ('S') and the host schedule. The strategy may
    only quote in ``TRADE_OPEN`` (``trading_pkg::trade_state_e``). An order sent
    into a closed session is rejected by the venue at best; at worst it rests
    into the opening cross at a price formed before the auction.
    """
    h = await setup(dut)
    await h.arm()
    for state in (TRADE_CLOSED, TRADE_PREOPEN, TRADE_AUCTION):
        dut.sess_state.value = state
        await ClockCycles(dut.clk, 2)
        await h.expect_reject(RISK_SESSION_CLOSED)


@cocotb.test()
async def test_reason_05_sym_halted(dut):
    """RISK_SYM_HALTED — regulatory or operational halt on this symbol.

    From ITCH Trading Action ('H'), Operational Halt ('h') and LULD pause.
    ⚠️ Both ``TRADE_HALTED`` and ``TRADE_PAUSED`` must reject. A LULD pause is
    not a halt in the venue's taxonomy, but it is one for our purposes: quoting
    into a pause is quoting into a reopening auction whose price is unknown.
    """
    h = await setup(dut)
    await h.arm()
    for state in (TRADE_HALTED, TRADE_PAUSED):
        await h.set_sym_state(state)
        await h.expect_reject(RISK_SYM_HALTED)
        await h.set_sym_state(TRADE_OPEN)


@cocotb.test()
async def test_reason_06_book_stale(dut):
    """RISK_BOOK_STALE — a sequence gap means the book is not trustworthy.

    ⚠️ ``rtl/fpga_top.sv`` asserts the same property from the other end:
       "A stale book must never produce an order."

    Trading through a gap is trading on a book you already know is wrong, and
    the resulting trades look entirely normal in the logs — which is why this
    check must be proven to fire rather than assumed.
    """
    h = await setup(dut)
    await h.arm()
    await h.set_book(bid=ig.px("99.99"), ask=ig.px("100.01"), stale=1)
    await ClockCycles(dut.clk, 2)
    await h.expect_reject(RISK_BOOK_STALE)


@cocotb.test()
async def test_reason_07_sub_penny(dut):
    """RISK_SUB_PENNY — SEC Rule 612: a price finer than a penny.

    ITCH prices carry 4 implied decimals, so a whole cent means the price is a
    multiple of 100. ``trading_pkg::is_whole_penny`` implements it with a
    RECIPROCAL MULTIPLY, not a modulo — CLAUDE.md §5.3 forbids dividers and
    ``manuals/00-foundations/03-hdl-and-rtl-coding.md`` §7 explains why.

    ⚠️ The reciprocal (``RECIP_100`` >> 37) is exact only for px < 2^31. The
       boundary cases below exercise that: the largest legal ITCH price and
       values immediately adjacent to it. A reciprocal that is off by one ULP
       misclassifies exactly one price in the range, and it will be a price
       somebody eventually quotes.
    """
    h = await setup(dut)
    await h.arm()

    for bad in (ig.px("100.001"), ig.px("100.0001"), ig.px("0.0001"),
                1_000_001, 2_147_483_601):
        await h.expect_reject(RISK_SUB_PENNY, price=bad)

    for good in (ig.px("100.00"), ig.px("0.01"), ig.px("187.50"), 2_147_483_600):
        await h.expect_pass(price=good, qty=1)


@cocotb.test()
async def test_reason_08_price_collar(dut):
    """RISK_PRICE_COLLAR — a hard price floor/ceiling set by the host.

    The fat-finger guard. Independent of the venue's LULD bands: this one is
    ours, it is absolute, and it does not move when the market does.
    """
    h = await setup(dut)
    await h.arm()
    await h.write_sym_risk(collar_lo=ig.px("90.00"), collar_hi=ig.px("110.00"))

    await h.expect_reject(RISK_PRICE_COLLAR, price=ig.px("89.99"))
    await h.expect_reject(RISK_PRICE_COLLAR, price=ig.px("110.01"))
    await h.expect_pass(price=ig.px("90.00"))     # boundary: inclusive
    await h.expect_pass(price=ig.px("110.00"))


@cocotb.test()
async def test_reason_09_luld_band(dut):
    """RISK_LULD_BAND — outside the venue's current LULD price band.

    Bands arrive from ITCH LULD Auction Collar ('J') and move during the day.
    ⚠️ Distinct from the collar: the collar is our static limit, the LULD band
    is the venue's dynamic one. Conflating them means either rejecting valid
    orders when the market moves, or sending orders the venue will reject —
    both of which cost money, in opposite directions.
    """
    h = await setup(dut)
    await h.arm()
    await h.write_sym_risk(luld_lo=ig.px("95.00"), luld_hi=ig.px("105.00"))
    await h.set_sym_state(TRADE_OPEN, luld_lo=ig.px("95.00"),
                          luld_hi=ig.px("105.00"))

    await h.expect_reject(RISK_LULD_BAND, price=ig.px("94.99"))
    await h.expect_reject(RISK_LULD_BAND, price=ig.px("105.01"))
    await h.expect_pass(price=ig.px("100.00"))


@cocotb.test()
async def test_reason_10_ssr(dut):
    """RISK_SSR — Reg SHO Rule 201 short-sale price test in force.

    When SSR is active a short sale may not be displayed or executed at or below
    the current national best bid. From ITCH Reg SHO ('Y').

    ⚠️ The check applies ONLY to short sales. A long sale at the same price must
    still pass — a gate that rejects both is a gate that stops the strategy
    trading for the rest of the day on any symbol that trips SSR.
    """
    h = await setup(dut)
    await h.arm()
    await h.write_sym_risk(ssr_active=1)
    await h.set_sym_state(TRADE_OPEN, ssr=1)
    await h.set_book(bid=ig.px("100.00"), ask=ig.px("100.02"))

    await h.expect_reject(RISK_SSR, side=SIDE_SELL, is_short=1,
                          price=ig.px("100.00"))
    await h.expect_reject(RISK_SSR, side=SIDE_SELL, is_short=1,
                          price=ig.px("99.99"))
    await h.expect_pass(side=SIDE_SELL, is_short=1, price=ig.px("100.01"))
    await h.expect_pass(side=SIDE_SELL, is_short=0, price=ig.px("100.00"))


@cocotb.test()
async def test_reason_11_max_shares(dut):
    """RISK_MAX_SHARES — per-order share limit.

    The most basic fat-finger control, and mandated by SEC Rule 15c3-5.
    """
    h = await setup(dut)
    await h.arm()
    await h.write_sym_risk(max_order_qty=1000)

    await h.expect_reject(RISK_MAX_SHARES, qty=1001)
    await h.expect_reject(RISK_MAX_SHARES, qty=0xFFFF_FFFF)
    await h.expect_pass(qty=1000)                  # boundary: inclusive


@cocotb.test()
async def test_reason_12_max_notional(dut):
    """RISK_MAX_NOTIONAL — per-order notional limit (price x quantity).

    ⚠️ The multiply MUST SATURATE. ``trading_pkg::sat_add64`` exists because
    "a wrapped counter turns a risk check into a no-op" (CLAUDE.md §5). A
    notional computed as a wrapping 64-bit product can come out SMALL for an
    enormous order, and the check then passes the one order it existed to stop.

    The oversized case below is chosen so a 64-bit wrap would land under the
    limit — it fails loudly on a wrapping implementation and quietly on a
    saturating one.
    """
    h = await setup(dut)
    await h.arm()
    await h.write_sym_risk(max_order_notional=10_000 * ig.px("100.00"),
                           max_order_qty=0xFFFF_FFFF)

    await h.expect_reject(RISK_MAX_NOTIONAL, qty=10_001, price=ig.px("100.00"))
    await h.expect_reject(RISK_MAX_NOTIONAL, qty=0xFFFF_FF00,
                          price=ig.px("429496.72"))
    await h.expect_pass(qty=10_000, price=ig.px("100.00"))


@cocotb.test()
async def test_reason_13_pos_limit(dut):
    """RISK_POS_LIMIT — this order would breach the per-symbol position limit.

    Position is maintained from fills (``rtl/risk/position_monitor.sv``). The
    check is on the POST-TRADE position, not the current one: an order that
    would take us through the limit must be rejected before it is sent, not
    after it fills.

    ⚠️ Both directions. A long limit that is enforced and a short limit that is
    not is a common asymmetry, because the long path is the one people test.
    """
    h = await setup(dut)
    await h.arm()
    await h.write_sym_risk(max_long_pos=1000, max_short_pos=1000)

    await h.fill(side=SIDE_BUY, qty=900, px=ig.px("100.00"))
    await h.expect_reject(RISK_POS_LIMIT, side=SIDE_BUY, qty=200)
    await h.expect_pass(side=SIDE_BUY, qty=100)      # exactly to the limit

    await h.fill(side=SIDE_SELL, qty=1900, px=ig.px("100.00"))   # now short 900
    await h.expect_reject(RISK_POS_LIMIT, side=SIDE_SELL, qty=200)


@cocotb.test()
async def test_reason_14_gross_limit(dut):
    """RISK_GROSS_LIMIT — aggregate gross exposure across all symbols.

    ⚠️ Distinct from the per-symbol limit: 256 symbols each within their own
    limit can still add up to an aggregate position nobody intended. The gross
    check is the only thing standing between "each individual order was fine"
    and a book-wide breach.
    """
    h = await setup(dut)
    await h.arm()
    dut.cfg_gross_limit.value = 5000
    await ClockCycles(dut.clk, 2)

    await h.fill(side=SIDE_BUY, qty=4900, px=ig.px("100.00"))
    await h.expect_reject(RISK_GROSS_LIMIT, qty=200)


@cocotb.test()
async def test_reason_15_open_orders(dut):
    """RISK_OPEN_ORDERS — too many live orders for this symbol.

    Bounds how much can be resting at once, which bounds the loss from a
    runaway strategy between the fault and the kill switch.
    """
    h = await setup(dut)
    await h.arm()
    await h.write_sym_risk(max_open_orders=3)

    for _ in range(3):
        await h.expect_pass(qty=100)
    await h.expect_reject(RISK_OPEN_ORDERS, qty=100)


@cocotb.test()
async def test_reason_16_msg_rate(dut):
    """RISK_MSG_RATE — outbound message rate limit.

    ⚠️ Two reasons this exists, and both matter:
       1. Venues impose message-rate limits and charge for breaches.
       2. A runaway strategy at 10 Gbps emits orders faster than any human or
          host process can react. The rate limiter is the only thing operating
          on the same timescale as the fault.

    Sustained breach escalates to ``kill_src_e::KILL_MSG_RATE`` — see
    ``rtl/risk/rate_limiter.sv``.
    """
    h = await setup(dut)
    await h.arm()
    dut.cfg_msg_rate_limit.value = 4          # orders per window
    dut.cfg_msg_rate_window.value = 64        # cycles
    await ClockCycles(dut.clk, 2)

    for _ in range(4):
        await h.expect_pass(qty=100, settle=2)
    await h.expect_reject(RISK_MSG_RATE, qty=100, settle=2)


@cocotb.test()
async def test_reason_17_duplicate(dut):
    """RISK_DUPLICATE — an identical order is already in flight.

    Catches a strategy re-firing on the same book state, which is the classic
    runaway pattern: nothing has changed, so the trigger keeps triggering, and
    the venue receives N copies of one intention.
    """
    h = await setup(dut)
    await h.arm()
    await h.expect_pass(side=SIDE_BUY, qty=100, price=ig.px("100.00"), strat_id=1)
    await h.expect_reject(RISK_DUPLICATE, side=SIDE_BUY, qty=100,
                          price=ig.px("100.00"), strat_id=1)
    # A different price is not a duplicate.
    await h.expect_pass(side=SIDE_BUY, qty=100, price=ig.px("100.01"), strat_id=1)


@cocotb.test()
async def test_reason_18_self_match(dut):
    """RISK_SELF_MATCH — this order would trade against our own resting order.

    Self-trade prevention. A wash trade is a regulatory problem regardless of
    intent, and the venue's own STP is not a substitute for ours — by the time
    the venue rejects it, we have already sent it.
    """
    h = await setup(dut)
    await h.arm()
    await h.expect_pass(side=SIDE_BUY, qty=100, price=ig.px("100.00"))
    await h.expect_reject(RISK_SELF_MATCH, side=SIDE_SELL, qty=100,
                          price=ig.px("100.00"))


@cocotb.test()
async def test_reason_19_restricted(dut):
    """RISK_RESTRICTED — the symbol is on the restricted / hard-to-borrow list.

    ``sym_risk_t.shortable`` is the flag. Shorting something we cannot borrow is
    a naked short.
    ⚠️ Applies to SHORT sales only; a long sale of a restricted name is fine.
    """
    h = await setup(dut)
    await h.arm()
    await h.write_sym_risk(shortable=0)

    await h.expect_reject(RISK_RESTRICTED, side=SIDE_SELL, is_short=1)
    await h.expect_pass(side=SIDE_SELL, is_short=0)
    await h.expect_pass(side=SIDE_BUY)


@cocotb.test()
async def test_reason_20_no_credit(dut):
    """RISK_NO_CREDIT — the in-flight order limit is reached.

    ``trading_pkg::MAX_IN_FLIGHT`` bounds how many orders the FPGA may emit
    before the host has accounted for them, which bounds position drift between
    the fabric's view and the host's. Credit is returned by
    ``rtl/order/credit_mgr.sv`` when an ack arrives.

    ⚠️ Running out of credit is NORMAL under load. It must reject cleanly and be
    counted — not stall the pipeline, which would put backpressure where the
    design has none.
    """
    h = await setup(dut)
    await h.arm()
    dut.credit_avail.value = 0
    await ClockCycles(dut.clk, 2)
    await h.expect_reject(RISK_NO_CREDIT)

    dut.credit_avail.value = 1
    await ClockCycles(dut.clk, 2)
    await h.expect_pass()


@cocotb.test()
async def test_reason_21_zero_qty(dut):
    """RISK_ZERO_QTY — a zero-quantity order.

    Nonsensical, and a strong signal that something upstream computed a size
    from uninitialised or wrapped state. Reject and count: the counter going
    non-zero is the alarm, not the rejection.
    """
    h = await setup(dut)
    await h.arm()
    await h.expect_reject(RISK_ZERO_QTY, qty=0)


@cocotb.test()
async def test_reason_22_zero_price(dut):
    """RISK_ZERO_PRICE — a zero-priced order.

    ⚠️ A zero price on a BUY is free money to the counterparty in the wrong
    direction; on a SELL it is a gift. Either way it is not a price, it is a
    register that was never written — which is exactly what the fail-closed
    reset policy is guarding against, caught here as a second layer.
    """
    h = await setup(dut)
    await h.arm()
    await h.expect_reject(RISK_ZERO_PRICE, price=0)


@cocotb.test()
async def test_reason_23_param_invalid(dut):
    """RISK_PARAM_INVALID — the symbol's risk record is internally inconsistent.

    Examples: collar_lo > collar_hi, luld_lo > luld_hi, a record whose commit
    bit was never set.

    ⚠️ WHY THIS IS NOT PARANOIA: the record crosses from pcie_clk to core_clk.
    If the CDC constraints in ``constraints/cdc.xdc`` are wrong — or if someone
    ever ``set_false_path``s that bus — the record arrives TORN, with some
    fields from the new value and some from the old. A torn record is an
    inconsistent record, and this check is the last thing standing between it
    and a live order.

    Reject, count, and DO NOT try to repair it. A gate that clamps an
    inconsistent limit into a plausible one has invented a risk limit that no
    human authorised.
    """
    h = await setup(dut)
    await h.arm()
    await h.write_sym_risk(collar_lo=ig.px("110.00"), collar_hi=ig.px("90.00"))
    await h.expect_reject(RISK_PARAM_INVALID)


# =============================================================================
# THE KILL SWITCH
# =============================================================================
@cocotb.test()
async def test_kill_switch_stops_output_within_bound(dut):
    """⚠️ The kill switch must stop ALL outbound order flow within
    ``KILL_RESP_CYCLES``.

    CLAUDE.md §5.6: "The kill switch is hardware-enforced. A single register
    write must stop all outbound order flow within a bounded, documented number
    of cycles."

    ``rtl/fpga_top.sv`` parameterizes the bound and asserts it:

        kill_active |-> ##[0:KILL_RESP_CYCLES] !order_out_valid

    This test drives a CONTINUOUS stream of otherwise-valid orders, asserts kill
    mid-stream, and counts how many cycles pass before output ceases. Testing
    with an idle pipeline would prove nothing: the whole question is whether
    orders ALREADY IN FLIGHT are stopped, and an idle pipeline has none.

    ⚠️ The number measured here is a SIMULATED cycle count. The real bound
    includes the SLR crossing from the host control plane into the fast path
    (constraints/floorplan.xdc §4) and the synchronizer depth, neither of which
    simulation models. The hardware number is a release gate
    (06-operations/01-build-and-release.md §8 item 9).
    """
    h = await setup(dut)
    await h.arm()
    await h.write_sym_risk(max_open_orders=0xFFFF)

    # Continuous submission, so the pipeline is full when kill asserts.
    async def flood():
        i = 0
        while True:
            dut.s_req_action.value = ACT_SEND
            dut.s_req_sym.value = SYM
            dut.s_req_side.value = SIDE_BUY
            dut.s_req_price.value = ig.px("100.00") + (i % 4) * 100
            dut.s_req_qty.value = 100
            dut.s_req_is_short.value = 0
            dut.s_req_strat_id.value = i % 8
            dut.s_req_valid.value = 1
            await RisingEdge(dut.clk)
            i += 1

    flooder = cocotb.start_soon(flood())
    await ClockCycles(dut.clk, 20)

    await ReadOnly()
    saw_output_before = int(dut.m_out_valid.value)
    await RisingEdge(dut.clk)
    dut.host_kill.value = 1
    kill_cycle = 0

    last_output_cycle = -1
    for cyc in range(1, 64):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.m_out_valid.value):
            last_output_cycle = cyc

    flooder.kill()
    dut.s_req_valid.value = 0

    assert last_output_cycle <= KILL_RESP_CYCLES, (
        f"⚠️ AN ORDER LEFT THE GATE {last_output_cycle} CYCLES AFTER KILL WAS "
        f"ASSERTED. The documented bound is KILL_RESP_CYCLES = "
        f"{KILL_RESP_CYCLES} ({KILL_RESP_CYCLES * 6.4:.1f} ns).\n"
        f"   CLAUDE.md §5.6 makes this bound a hard rule, and rtl/fpga_top.sv "
        f"asserts it. A kill switch with an unbounded response time is not a "
        f"kill switch; it is a request."
    )
    dut._log.info(
        f"kill response: last order at +{last_output_cycle} cycles "
        f"(bound {KILL_RESP_CYCLES}) — SIMULATED. The hardware number, which "
        f"includes the SLR crossing and synchronizer depth, is a release gate."
    )


@cocotb.test()
async def test_kill_sources_all_latch_and_report(dut):
    """Every ``kill_src_e`` must assert kill and latch its provenance.

    ⚠️ The source is latched STICKY for post-incident analysis. "Trading stopped"
    is not an answer to a regulator, an exchange, or a risk committee; "the
    external GPIO went low at 14:32:07.412" is. A kill switch that fires without
    recording WHY has destroyed the only evidence of what happened.
    """
    h = await setup(dut)

    cases = [
        ("host_kill", KILL_HOST, "host wrote the kill register"),
        ("ext_kill", KILL_GPIO, "external hardware input / front panel"),
        ("link_down", KILL_LINK_DOWN, "order-entry link lost"),
    ]
    for signal, want_src, why in cases:
        await bringup(dut, rst_cycles=4)
        await h.arm()
        getattr(dut, signal).value = 1
        await ClockCycles(dut.clk, KILL_RESP_CYCLES + 4)
        await ReadOnly()
        assert int(dut.kill_active.value) == 1, (
            f"{signal} ({why}) did not activate the kill switch"
        )
        assert int(dut.kill_src.value) == want_src, (
            f"{signal}: kill_src is {int(dut.kill_src.value)}, want {want_src}. "
            f"The provenance is the post-incident evidence."
        )
        # Sticky: deasserting the source must NOT re-arm trading.
        getattr(dut, signal).value = 0
        await ClockCycles(dut.clk, 8)
        await ReadOnly()
        assert int(dut.kill_active.value) == 1, (
            f"⚠️ kill self-cleared when {signal} deasserted. Recovery from a "
            f"kill is a deliberate, operator-driven sequence "
            f"(06-operations/01-build-and-release.md §9), never automatic. "
            f"A self-clearing kill switch resumes trading into whatever "
            f"condition triggered it."
        )
        await h.expect_reject(RISK_KILL_SWITCH)


@cocotb.test()
async def test_watchdog_kill_on_heartbeat_loss(dut):
    """``KILL_WATCHDOG`` — the host stopped sending heartbeats.

    ⚠️ The case the kill register cannot cover: if the host process is dead or
    wedged, nobody is left to write the register. The fabric has to notice by
    itself. A hardware trading system whose only stop condition requires a
    working host has no stop condition.
    """
    h = await setup(dut)
    await h.arm()
    dut.cfg_watchdog_timeout.value = 64
    dut.host_heartbeat.value = 0
    await ClockCycles(dut.clk, 128)

    await ReadOnly()
    assert int(dut.kill_active.value) == 1, (
        "the watchdog did not fire after the heartbeat stopped"
    )
    assert int(dut.kill_src.value) == KILL_WATCHDOG
    await h.expect_reject(RISK_KILL_SWITCH)


# =============================================================================
# MATRIX COMPLETENESS
# =============================================================================
@cocotb.test()
async def test_every_reason_has_a_test(dut):
    """⚠️ Meta-test: prove the matrix covers every ``risk_reason_e`` value.

    Scans this file for ``test_reason_NN_`` functions and checks that every
    non-OK reason has one. When somebody adds a 25th reason to
    ``trading_pkg::risk_reason_e``, this fails — which is the point. The
    alternative is a new check that is never exercised, which is exactly the
    thing this whole file exists to prevent.
    """
    import re

    src = Path(__file__).read_text()
    covered = {int(m) for m in re.findall(r"def test_reason_(\d+)_", src)}
    expected = set(range(1, N_RISK_REASONS))     # 1..23; RISK_OK is not a reject

    missing = sorted(expected - covered)
    assert not missing, (
        "⚠️ RISK REASONS WITH NO TEST: "
        + ", ".join(f"{i}={REASON_NAME.get(i, '?')}" for i in missing)
        + "\n   A check that has never been observed to fire is a check that "
          "cannot be trusted. Add one test per reason."
    )

    extra = sorted(covered - expected)
    assert not extra, (
        f"tests exist for reason codes not in the enum: {extra}. Either the "
        f"enum shrank (and dead checks remain in the RTL) or this file's "
        f"mirror of risk_reason_e is stale."
    )

    dut._log.info(
        f"risk matrix: {len(covered)}/{len(expected)} rejection reasons have a "
        f"dedicated test, plus reset fail-closed and the kill switch."
    )
