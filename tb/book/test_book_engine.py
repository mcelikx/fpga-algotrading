"""cocotb tests for ``rtl/book/book_engine.sv`` — THE highest-value test here.

Project : FPGA Algorithmic Trading System (Nasdaq Equities)
Governs : manuals/01-fpga-design/05-verification-and-simulation.md §4
          manuals/04-system-architecture/03-order-book-in-hardware.md
          manuals/01-fpga-design/03-memory-and-storage.md §4 (the RMW hazard)

===============================================================================
WHAT THIS TEST IS
===============================================================================
    The hardware book and ``tb/common/golden_book.py`` are driven with the SAME
    message stream, and top-of-book is compared AFTER EVERY SINGLE MESSAGE.

    Not at the end. Not every N messages. Every message. 05-verification §4
    rule 3: "Stop at the first divergence and print context. A mismatch report
    that says '12,481 differences' is unactionable."

    The reason this test carries more weight than everything else in ``tb/``:

        "A feed handler plus an order book is a large, stateful, order-dependent
         transform. You cannot unit-test your way to confidence in it: the bugs
         live in *sequences* of messages that only appear in real market data."

    Unit tests find the bugs you thought of. This finds the rest.

===============================================================================
THE INDEPENDENCE PROPERTY — do not break it
===============================================================================
    * The DUT is driven with ``book_evt_t`` structs, translated here from ITCH.
    * The ORACLE is driven with the RAW ITCH BYTES and does its own decode.

    So the two sides share only the byte stream. If the translation below is
    wrong, the oracle disagrees and the test fails — which is the correct
    outcome, because a wrong translation means the DUT is being fed something
    the feed handler would never produce.

    ⚠️ Do NOT "fix" a failure by making the oracle mirror the DUT. That converts
       the oracle into a second copy of the implementation and this test into a
       tautology. 05-verification §4 rule 5.

TODO(verify) — PORT NAMES
    Signals follow ``rtl/fpga_top.sv``'s ``u_book`` connections and the
    ``book_evt_t`` / ``book_top_t`` fields in ``rtl/pkg/trading_pkg.sv``. The
    DUT is the flattening wrapper ``tb/book/tb_book_engine_top.sv``. Confirm
    against ``rtl/book/book_engine.sv`` once final.
"""

from __future__ import annotations

import os
import random
import sys
from pathlib import Path

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from common import itch_gen as ig                              # noqa: E402
from common.axis_driver import bringup                         # noqa: E402
from common.golden_book import BookConfig, GoldenBook, TopOfBook  # noqa: E402
from common.pcap_replay import resolve_fixture                 # noqa: E402

# trading_pkg::book_op_e
BOOK_ADD, BOOK_EXECUTE, BOOK_CANCEL = 0, 1, 2
BOOK_DELETE, BOOK_REPLACE, BOOK_CLEAR, BOOK_NOP = 3, 4, 5, 6
SIDE_BUY, SIDE_SELL = 0, 1

LOCATE = 1234
SYM_IDX = 0            # active-set index for LOCATE; the filter maps 1:1 here
STOCK = "AAPL"

#: How long the book may take to produce a top-of-book after an event.
#: rtl/fpga_top.sv budgets 2 cycles for "Book level update + incremental
#: top-of-book", with a note that a best-level delete forcing a new-best search
#: is the design's ONE variable-latency stage. This bound is deliberately larger
#: than the budget so a latency regression shows up as a timing assertion
#: (test_latency_bound) rather than as a mysterious comparison failure.
TOP_TIMEOUT_CYCLES = 32


# =============================================================================
# DUT plumbing
# =============================================================================
async def drive_evt(dut, op: int, *, sym: int = SYM_IDX, locate: int = LOCATE,
                    side: int = SIDE_BUY, price: int = 0, qty: int = 0,
                    order_ref: int = 0, new_order_ref: int = 0,
                    exch_ts: int = 0, printable: int = 1) -> None:
    """Present one ``book_evt_t`` for exactly one cycle."""
    dut.s_evt_op.value = op
    dut.s_evt_sym.value = sym
    dut.s_evt_locate.value = locate
    dut.s_evt_side.value = side
    dut.s_evt_price.value = price
    dut.s_evt_qty.value = qty
    dut.s_evt_order_ref.value = order_ref
    dut.s_evt_new_order_ref.value = new_order_ref
    dut.s_evt_exch_ts.value = exch_ts
    dut.s_evt_printable.value = printable
    dut.s_evt_valid.value = 1
    await RisingEdge(dut.clk)
    dut.s_evt_valid.value = 0


async def read_top(dut, timeout: int = TOP_TIMEOUT_CYCLES) -> tuple[TopOfBook, int]:
    """Wait for ``m_top_valid`` and snapshot ``book_top_t``.

    Returns ``(top, cycles_taken)`` so the latency test can assert on the
    second value without a second traversal.
    """
    for cyc in range(1, timeout + 1):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.m_top_valid.value):
            t = TopOfBook(
                locate=LOCATE,
                bid_px=int(dut.m_top_bid_px.value),
                bid_qty=int(dut.m_top_bid_qty.value),
                ask_px=int(dut.m_top_ask_px.value),
                ask_qty=int(dut.m_top_ask_qty.value),
                last_px=int(dut.m_top_last_px.value),
                bid_valid=bool(int(dut.m_top_bid_valid.value)),
                ask_valid=bool(int(dut.m_top_ask_valid.value)),
                crossed=bool(int(dut.m_top_crossed.value)),
                stale=bool(int(dut.m_top_stale.value)),
            )
            return t, cyc
    raise TimeoutError(
        f"book produced no m_top_valid within {timeout} cycles "
        f"({timeout * 6.4:.0f} ns). The book must emit a top-of-book for EVERY "
        f"applied event, even when the top did not move — ``top_changed`` is "
        f"the field that says whether it moved, not the absence of a beat."
    )


def itch_to_evt(msg: bytes) -> dict | None:
    """Translate one ITCH message into ``book_evt_t`` fields for the DUT.

    This is the job ``rtl/feed/itch_decoder.sv`` does in hardware, reproduced
    here so ``book_engine`` can be tested standalone. It is deliberately
    mechanical — it must not make book decisions, only field extraction, because
    a decision made here is a decision NOT tested in the DUT.

    Returns ``None`` for messages that do not mutate the book.
    """
    p = ig.parse_itch(msg)
    t = p["type"]

    if t in (ig.MSG_ADD_ORDER, ig.MSG_ADD_ORDER_MPID):
        return dict(op=BOOK_ADD, order_ref=p["order_ref"],
                    side=SIDE_BUY if p["side"] == b"B" else SIDE_SELL,
                    qty=p["shares"], price=p["price"], exch_ts=p["ts_ns"])
    if t in (ig.MSG_ORDER_EXECUTED, ig.MSG_ORDER_EXEC_PRICE):
        return dict(op=BOOK_EXECUTE, order_ref=p["order_ref"], qty=p["shares"],
                    price=p.get("price", 0), exch_ts=p["ts_ns"],
                    printable=1 if p.get("printable", b"Y") == b"Y" else 0)
    if t == ig.MSG_ORDER_CANCEL:
        return dict(op=BOOK_CANCEL, order_ref=p["order_ref"], qty=p["shares"],
                    exch_ts=p["ts_ns"])
    if t == ig.MSG_ORDER_DELETE:
        return dict(op=BOOK_DELETE, order_ref=p["order_ref"], exch_ts=p["ts_ns"])
    if t == ig.MSG_ORDER_REPLACE:
        # ⚠️ BOTH references travel. See tb/feed/test_itch_decoder.py's
        #    test_order_replace_emits_both_references for why.
        return dict(op=BOOK_REPLACE, order_ref=p["order_ref"],
                    new_order_ref=p["new_order_ref"], qty=p["shares"],
                    price=p["price"], exch_ts=p["ts_ns"])
    return None


# =============================================================================
# The comparison harness
# =============================================================================
class Comparator:
    """Drives DUT + oracle from one message stream and compares after each."""

    def __init__(self, dut, cfg: BookConfig | None = None):
        self.dut = dut
        self.book = GoldenBook(cfg or BookConfig(active_locates={LOCATE}))
        self.n = 0
        self.max_cycles = 0

    async def step(self, msg: bytes, seq: int | None = None,
                   expect_book_event: bool | None = None) -> None:
        """Apply one ITCH message to both sides and compare top-of-book."""
        self.n += 1
        seq = seq if seq is not None else self.n

        evt = itch_to_evt(msg)
        self.book.apply(msg, seq=seq)
        expected = self.book.top_of_book(LOCATE)

        if evt is None:
            if expect_book_event:
                raise AssertionError(
                    f"msg #{self.n} was expected to mutate the book but "
                    f"translated to no event: {ig.parse_itch(msg)}"
                )
            return

        await drive_evt(self.dut, **evt)
        actual, cycles = await read_top(self.dut)
        self.max_cycles = max(self.max_cycles, cycles)

        if actual.as_tuple() != expected.as_tuple():
            # ⚠️ STOP AT THE FIRST DIVERGENCE and print the context that turns a
            #    failure into a fix — including the last N messages for this
            #    symbol (05-verification §4 rule 3).
            raise AssertionError(
                self.book.divergence_report(LOCATE, expected, actual, seq)
                + f"\n  message #{self.n}: {ig.parse_itch(msg)}\n"
            )

        # The oracle audits itself too. If the oracle is inconsistent, nothing
        # it says about the DUT means anything.
        self.book.verify_consistency()

    async def run(self, msgs: list[bytes], start_seq: int = 1) -> None:
        for i, m in enumerate(msgs):
            await self.step(m, seq=start_seq + i)


async def setup(dut) -> Comparator:
    dut.s_evt_valid.value = 0
    for f in ("s_evt_op", "s_evt_sym", "s_evt_locate", "s_evt_side",
              "s_evt_price", "s_evt_qty", "s_evt_order_ref",
              "s_evt_new_order_ref", "s_evt_exch_ts", "s_evt_printable"):
        getattr(dut, f).value = 0
    await bringup(dut)
    return Comparator(dut)


# =============================================================================
# 1. The baseline: a correct session
# =============================================================================
@cocotb.test()
async def test_build_two_sided_book(dut):
    """Build a three-level two-sided book; compare after every message."""
    cmp_ = await setup(dut)
    msgs = [
        ig.add_order(LOCATE, 0x1001, ig.SIDE_BUY, 300, STOCK, ig.px("187.50")),
        ig.add_order(LOCATE, 0x1002, ig.SIDE_BUY, 200, STOCK, ig.px("187.49")),
        ig.add_order(LOCATE, 0x1003, ig.SIDE_BUY, 100, STOCK, ig.px("187.48")),
        ig.add_order(LOCATE, 0x2001, ig.SIDE_SELL, 400, STOCK, ig.px("187.51")),
        ig.add_order(LOCATE, 0x2002, ig.SIDE_SELL, 150, STOCK, ig.px("187.52")),
        ig.add_order(LOCATE, 0x2003, ig.SIDE_SELL, 250, STOCK, ig.px("187.53")),
    ]
    await cmp_.run(msgs)

    top = cmp_.book.top_of_book(LOCATE)
    assert (top.bid_px, top.bid_qty) == (ig.px("187.50"), 300)
    assert (top.ask_px, top.ask_qty) == (ig.px("187.51"), 400)
    assert not top.crossed


# =============================================================================
# 2. ⚠️ HARD CASE: delete the current best
# =============================================================================
@cocotb.test()
async def test_delete_current_best(dut):
    """Deleting the best bid must promote the next level.

    ⚠️ This is the design's ONE variable-latency stage. From the latency table
    in ``rtl/fpga_top.sv``:

        "The single variable-latency stage is a best-level delete that forces a
         new-best search. Bounded and counted; see book_engine.sv."

    Two things must hold:
      1. The new best is correct — a book that maintains top-of-book
         incrementally has to actually search when its cached best disappears,
         and a naive implementation leaves the deleted level in place at zero
         quantity (the phantom-top bug).
      2. The search is BOUNDED. An unbounded search on the fast path violates
         CLAUDE.md §5.2 and blows the latency budget.

    Repeated deletion peels the book one level at a time, ending with an empty
    side — which must set ``bid_valid=0``, not leave a stale best.
    """
    cmp_ = await setup(dut)
    await cmp_.run([
        ig.add_order(LOCATE, 0x1001, ig.SIDE_BUY, 300, STOCK, ig.px("187.50")),
        ig.add_order(LOCATE, 0x1002, ig.SIDE_BUY, 200, STOCK, ig.px("187.49")),
        ig.add_order(LOCATE, 0x1003, ig.SIDE_BUY, 100, STOCK, ig.px("187.48")),
        ig.add_order(LOCATE, 0x2001, ig.SIDE_SELL, 400, STOCK, ig.px("187.51")),
    ])

    # Peel the bid side down to empty, one best-level delete at a time.
    for ref, want_px, want_qty in ((0x1001, ig.px("187.49"), 200),
                                   (0x1002, ig.px("187.48"), 100)):
        await cmp_.step(ig.order_delete(LOCATE, ref))
        top = cmp_.book.top_of_book(LOCATE)
        assert (top.bid_px, top.bid_qty) == (want_px, want_qty), (
            f"after deleting 0x{ref:X} the new best should be "
            f"{want_px}@{want_qty}, oracle says {top.bid_px}@{top.bid_qty}"
        )

    await cmp_.step(ig.order_delete(LOCATE, 0x1003))
    top = cmp_.book.top_of_book(LOCATE)
    assert not top.bid_valid, (
        "the bid side is empty but bid_valid is still set — a stale best price "
        "on an empty side is a quote the strategy will act on"
    )
    assert not top.crossed, "an empty side cannot be crossed"

    assert cmp_.max_cycles <= TOP_TIMEOUT_CYCLES, (
        f"best-level delete took {cmp_.max_cycles} cycles; the search must be "
        f"BOUNDED (CLAUDE.md §5.2 — no unbounded loops on the fast path)"
    )


# =============================================================================
# 3. ⚠️ HARD CASE: back-to-back updates to the same price level
# =============================================================================
@cocotb.test()
async def test_back_to_back_same_level(dut):
    """N consecutive updates to ONE price level, with no gap between them.

    ⚠️ THE READ-MODIFY-WRITE HAZARD.
       ``rtl/book/price_levels.sv`` reads a level's aggregate quantity from
       BRAM, adds to it, and writes it back. BRAM read latency is >= 1 cycle
       (03-hdl-and-rtl-coding.md §7, "Reading a BRAM and using it same cycle |
       Impossible"). Two updates to the SAME address in consecutive cycles mean
       the second read returns the PRE-update value unless the design forwards
       the in-flight write.

       Symptom: quantity is short by exactly the amount of the shadowed update.
       From the divergence triage table: "Wrong only on back-to-back updates to
       one price level -> missing write-forwarding on the book RMW."

       It CANNOT be found by a test that leaves gaps between messages, and real
       market data produces these constantly — a burst of adds at the touch is
       the normal state of an active symbol.

    Swept for N = 1 .. bypass_depth+2 as 05-verification §6 prescribes, so a
    forwarding path that is one stage too shallow is caught rather than a
    forwarding path that is entirely absent.
    """
    cmp_ = await setup(dut)
    level = ig.px("187.49")

    for n in range(1, 7):          # 1 .. bypass_depth+2 for a depth of 4
        base = 0x3000 + n * 0x100
        for i in range(n):
            await cmp_.step(ig.add_order(LOCATE, base + i, ig.SIDE_BUY,
                                         100, STOCK, level))
        top = cmp_.book.top_of_book(LOCATE)
        assert top.bid_qty == 100 * n, (
            f"N={n}: oracle aggregate {top.bid_qty} != {100*n} — the ORACLE is "
            f"wrong, fix it before reading anything else here"
        )
        # Tear down so the next N starts clean.
        for i in range(n):
            await cmp_.step(ig.order_delete(LOCATE, base + i))


@cocotb.test()
async def test_back_to_back_execute_same_level(dut):
    """The RMW hazard in the SUBTRACT direction.

    A forwarding path that handles adds but not subtracts is a real and common
    partial implementation — the add path is the one people test.
    """
    cmp_ = await setup(dut)
    refs = [0x4001, 0x4002, 0x4003, 0x4004]
    level = ig.px("50.00")
    for r in refs:
        await cmp_.step(ig.add_order(LOCATE, r, ig.SIDE_SELL, 100, STOCK, level))
    for i, r in enumerate(refs):
        await cmp_.step(ig.order_executed(LOCATE, r, 100, 0xE000 + i))

    top = cmp_.book.top_of_book(LOCATE)
    assert not top.ask_valid, (
        "every order at the only ask level was executed to zero; the level must "
        "be gone, not resting at quantity 0"
    )


# =============================================================================
# 4. ⚠️ HARD CASE: Order Replace
# =============================================================================
@cocotb.test()
async def test_replace_removes_old_and_adds_new(dut):
    """'U' is a delete plus an add, not a modify.

    ⚠️ ``itch_pkg.sv`` at ``OFF_U_ORIG_REF``: "'U' both removes the original
       reference and creates a new one. A book that treats it as an in-place
       modify will leak order references and drift from the true book."

    Three properties, in order of how badly each fails:
      1. The old reference is GONE — a later 'D' on it must be a no-op, not a
         second removal of quantity that is no longer there.
      2. The new reference EXISTS at the new price and size — the replacement
         inherits side and stock from the original, neither of which is in the
         'U' message.
      3. Aggregate quantity at each level is right afterwards.
    """
    cmp_ = await setup(dut)
    await cmp_.run([
        ig.add_order(LOCATE, 0x5001, ig.SIDE_SELL, 400, STOCK, ig.px("187.51")),
        ig.add_order(LOCATE, 0x5002, ig.SIDE_SELL, 100, STOCK, ig.px("187.52")),
    ])

    await cmp_.step(ig.order_replace(LOCATE, 0x5001, 0x5101, 500, ig.px("187.55")))

    top = cmp_.book.top_of_book(LOCATE)
    assert (top.ask_px, top.ask_qty) == (ig.px("187.52"), 100), (
        f"after replacing the 187.51 order up to 187.55, the best ask should be "
        f"187.52@100; oracle says {top.ask_px}@{top.ask_qty}. If it is still "
        f"187.51 the original reference was not removed — the in-place-modify "
        f"bug."
    )
    assert 0x5001 not in cmp_.book.orders, "original reference leaked"
    assert 0x5101 in cmp_.book.orders, "replacement reference not created"
    assert cmp_.book.orders[0x5101].side == "S", (
        "the replacement did not inherit the original's SIDE — 'U' does not "
        "carry a side field"
    )

    # A delete of the now-dead original must not remove quantity again.
    before = cmp_.book.top_of_book(LOCATE).as_tuple()
    await cmp_.step(ig.order_delete(LOCATE, 0x5001))
    assert cmp_.book.top_of_book(LOCATE).as_tuple() == before, (
        "deleting an already-replaced reference changed the book — quantity is "
        "being removed twice"
    )


@cocotb.test()
async def test_replace_at_same_price_keeps_level_correct(dut):
    """Replace to the SAME price with a different size.

    The tempting shortcut — "same price, so just adjust the quantity" — is
    exactly the in-place modify, and it is right here and wrong everywhere else.
    """
    cmp_ = await setup(dut)
    lvl = ig.px("187.50")
    await cmp_.run([
        ig.add_order(LOCATE, 0x6001, ig.SIDE_BUY, 300, STOCK, lvl),
        ig.add_order(LOCATE, 0x6002, ig.SIDE_BUY, 200, STOCK, lvl),
    ])
    await cmp_.step(ig.order_replace(LOCATE, 0x6001, 0x6101, 50, lvl))

    top = cmp_.book.top_of_book(LOCATE)
    assert top.bid_qty == 250, (
        f"level aggregate {top.bid_qty} != 250 (200 + the replaced 50)"
    )


# =============================================================================
# 5. ⚠️ HARD CASE: execute to zero, and over-execute
# =============================================================================
@cocotb.test()
async def test_execute_to_exactly_zero(dut):
    """An order executed for its full remaining size must DISAPPEAR.

    ⚠️ Leaving it resting at quantity 0 creates a phantom level: the best price
    is right, the size is zero, and a strategy sizing against the touch computes
    a zero-size trade — or, worse, a book that treats zero as "unknown" and
    quotes into it.
    """
    cmp_ = await setup(dut)
    await cmp_.run([
        ig.add_order(LOCATE, 0x7001, ig.SIDE_BUY, 100, STOCK, ig.px("10.00")),
        ig.add_order(LOCATE, 0x7002, ig.SIDE_BUY, 100, STOCK, ig.px("9.99")),
    ])
    await cmp_.step(ig.order_executed(LOCATE, 0x7001, 100, 0xF001))

    top = cmp_.book.top_of_book(LOCATE)
    assert (top.bid_px, top.bid_qty) == (ig.px("9.99"), 100), (
        f"best bid is {top.bid_px}@{top.bid_qty}; the fully-executed 10.00 "
        f"level must be gone entirely, not present at quantity 0"
    )
    assert 0x7001 not in cmp_.book.orders


@cocotb.test()
async def test_execute_more_than_resting_saturates(dut):
    """Executing more than is resting must SATURATE at zero, never wrap.

    ⚠️ CLAUDE.md §5 and ``trading_pkg::sat_sub64``: "ALL risk/position
       arithmetic saturates — a wrapped counter turns a risk check into a
       no-op." The same applies to book quantities: a level whose quantity wraps
       to 2^32-1 becomes, to a strategy, an enormous amount of liquidity that
       does not exist.

    Shouldn't happen against a well-formed feed — but it happens after a gap,
    and after a gap is exactly when the design must not do something insane.
    """
    cmp_ = await setup(dut)
    await cmp_.run([
        ig.add_order(LOCATE, 0x8001, ig.SIDE_SELL, 100, STOCK, ig.px("20.00")),
    ])
    await cmp_.step(ig.order_executed(LOCATE, 0x8001, 999_999, 0xF002))

    top = cmp_.book.top_of_book(LOCATE)
    assert not top.ask_valid, (
        f"over-execution left ask_valid set at {top.ask_px}@{top.ask_qty} — "
        f"if the quantity wrapped this is now a huge phantom level"
    )
    assert cmp_.book.n_execute_overflow >= 1, (
        "the oracle did not count the over-execution; CLAUDE.md §5.7 requires "
        "the DUT to count it too — check the corresponding stat register"
    )


@cocotb.test()
async def test_partial_cancel_then_delete(dut):
    """'X' reduces, 'D' removes. Both on the same reference, in order."""
    cmp_ = await setup(dut)
    await cmp_.run([
        ig.add_order(LOCATE, 0x9001, ig.SIDE_BUY, 500, STOCK, ig.px("30.00")),
    ])
    await cmp_.step(ig.order_cancel(LOCATE, 0x9001, 200))
    assert cmp_.book.top_of_book(LOCATE).bid_qty == 300, (
        "'X' must reduce by the cancelled quantity, not remove the order"
    )
    await cmp_.step(ig.order_delete(LOCATE, 0x9001))
    assert not cmp_.book.top_of_book(LOCATE).bid_valid


# =============================================================================
# 6. ⚠️ HARD CASE: sequence gap forces stale
# =============================================================================
@cocotb.test()
async def test_sequence_gap_forces_stale(dut):
    """A gap must set ``stale`` and it must LATCH until an explicit resync.

    ⚠️ After a gap the book is missing messages. It is not slightly wrong; it is
       of unknown wrongness, and no amount of subsequent correct messages fixes
       it — a deleted order we never saw added stays in the book forever.

       Required behaviour (``trading_pkg::TRADE_STALE``,
       ``risk_reason_e::RISK_BOOK_STALE``): raise stale, keep it raised, and let
       the risk gate reject every order until the host resyncs and issues
       ``BOOK_CLEAR``.

       ``fpga_top.sv`` asserts the downstream half of this:
           "A stale book must never produce an order."

       The failure mode if stale clears by itself: the system trades on a book
       it knows is wrong, and the trades look completely normal in the logs.
    """
    cmp_ = await setup(dut)
    await cmp_.run([
        ig.add_order(LOCATE, 0xA001, ig.SIDE_BUY, 100, STOCK, ig.px("40.00")),
        ig.add_order(LOCATE, 0xA002, ig.SIDE_SELL, 100, STOCK, ig.px("40.01")),
    ])

    # Signal the gap to both sides. In the system this comes from
    # rtl/net/moldudp64_deframer.sv via feed_handler's s_gap input.
    cmp_.book.set_stale(LOCATE, True)
    dut.s_gap.value = 1
    await RisingEdge(dut.clk)
    dut.s_gap.value = 0

    await drive_evt(dut, BOOK_ADD, order_ref=0xA003, side=SIDE_BUY,
                    qty=100, price=ig.px("40.00"))
    top, _ = await read_top(dut)
    assert top.stale, (
        "the book did not report stale after a sequence gap. The risk gate's "
        "RISK_BOOK_STALE check has nothing to fire on, and the design will "
        "trade through the gap."
    )

    # Stale must LATCH: more good messages do not repair a gap.
    for i in range(5):
        cmp_.book.apply(ig.add_order(LOCATE, 0xB000 + i, ig.SIDE_BUY,
                                     100, STOCK, ig.px("39.99")))
        await drive_evt(dut, BOOK_ADD, order_ref=0xB000 + i, side=SIDE_BUY,
                        qty=100, price=ig.px("39.99"))
        top, _ = await read_top(dut)
        assert top.stale, (
            f"stale cleared by itself after {i+1} good message(s). Only an "
            f"explicit resync (BOOK_CLEAR from the host) may clear it."
        )

    # BOOK_CLEAR is the resync. After it, and only after it, stale clears.
    cmp_.book.clear(LOCATE)
    cmp_.book.set_stale(LOCATE, False)
    await drive_evt(dut, BOOK_CLEAR)
    top, _ = await read_top(dut)
    assert not top.stale, "BOOK_CLEAR did not clear the stale flag"
    assert not top.bid_valid and not top.ask_valid, (
        "BOOK_CLEAR must empty the book — a resync that keeps the old levels "
        "keeps the corruption it was issued to remove"
    )


# =============================================================================
# 7. Invariants that must hold on every update
# =============================================================================
@cocotb.test()
async def test_crossed_book_is_flagged_never_hidden(dut):
    """A crossed book (bid >= ask) must be FLAGGED, not silently corrected.

    ⚠️ Crossing is transiently possible in an order-based reconstruction, and
       ``fpga_top.sv`` asserts "A crossed book must never produce an order."
       That assertion is only useful if the book raises the flag. A book that
       "fixes" a cross by suppressing one side hides a real condition — usually
       a decode bug or a gap — and turns an alarm into silence.
    """
    cmp_ = await setup(dut)
    await cmp_.run([
        ig.add_order(LOCATE, 0xC001, ig.SIDE_SELL, 100, STOCK, ig.px("10.00")),
        ig.add_order(LOCATE, 0xC002, ig.SIDE_BUY, 100, STOCK, ig.px("10.05")),
    ])
    top = cmp_.book.top_of_book(LOCATE)
    assert top.crossed, "oracle failed to flag a crossed book"
    assert top.bid_valid and top.ask_valid, (
        "both sides must remain visible; suppressing one hides the condition"
    )


@cocotb.test()
async def test_latency_bound(dut):
    """The book must produce top-of-book within its declared budget.

    ⚠️ ``rtl/fpga_top.sv`` budgets 2 cycles / 12.8 ns for "Book level update +
       incremental top-of-book". Merge gate 4
       (06-operations/01-build-and-release.md §5): "Simulated tick-to-trade
       latency within the budget declared in the module header, and UNCHANGED
       unless the PR explicitly says it changes."

    Reported as SIMULATED. CLAUDE.md §4: simulated and measured numbers are not
    interchangeable.
    """
    cmp_ = await setup(dut)
    msgs = [ig.add_order(LOCATE, 0xD000 + i, ig.SIDE_BUY, 100, STOCK,
                         ig.px("50.00") + i) for i in range(64)]
    await cmp_.run(msgs)

    dut._log.info(
        f"book_engine worst-case event->top latency: {cmp_.max_cycles} cycles "
        f"({cmp_.max_cycles * 6.4:.1f} ns) — SIMULATED, not measured"
    )
    assert cmp_.max_cycles <= TOP_TIMEOUT_CYCLES, (
        f"{cmp_.max_cycles} cycles exceeds the harness bound. If this is a "
        f"deliberate change, update the latency table in rtl/fpga_top.sv in the "
        f"same commit — a silent latency change is a regression."
    )


# =============================================================================
# 8. Randomized soak
# =============================================================================
@cocotb.test()
async def test_random_stream_vs_golden(dut):
    """Randomized order flow, compared after every message.

    Seed logged on the first line. Freeze any failing seed into a directed test.
    """
    seed = int(os.environ.get("SEED", random.randrange(2**32)))
    dut._log.info(f"SEED={seed}")
    rng = random.Random(seed)

    cmp_ = await setup(dut)
    live: list[int] = []
    next_ref = 0x10_0000
    # A deliberately NARROW price band, so collisions on the same level are
    # frequent — that is where the RMW hazard lives.
    prices = [ig.px("100.00") + i * 100 for i in range(6)]

    for _ in range(1500):
        r = rng.random()
        if r < 0.45 or len(live) < 4:
            ref = next_ref
            next_ref += 1
            await cmp_.step(ig.add_order(
                LOCATE, ref, rng.choice([ig.SIDE_BUY, ig.SIDE_SELL]),
                rng.randrange(1, 1000) * 100, STOCK, rng.choice(prices)))
            live.append(ref)
        elif r < 0.65:
            ref = rng.choice(live)
            await cmp_.step(ig.order_executed(LOCATE, ref,
                                              rng.randrange(1, 500) * 100,
                                              rng.getrandbits(32)))
            if ref in cmp_.book.orders:
                pass
            else:
                live.remove(ref)
        elif r < 0.80:
            ref = rng.choice(live)
            await cmp_.step(ig.order_cancel(LOCATE, ref,
                                            rng.randrange(1, 500) * 100))
            if ref not in cmp_.book.orders:
                live.remove(ref)
        elif r < 0.92:
            ref = rng.choice(live)
            await cmp_.step(ig.order_delete(LOCATE, ref))
            live.remove(ref)
        else:
            ref = rng.choice(live)
            new_ref = next_ref
            next_ref += 1
            await cmp_.step(ig.order_replace(LOCATE, ref, new_ref,
                                             rng.randrange(1, 1000) * 100,
                                             rng.choice(prices)))
            live.remove(ref)
            live.append(new_ref)

    dut._log.info(f"SEED={seed} oracle stats: {cmp_.book.stats()}")


# =============================================================================
# 9. ⚠️ TIER 3: pcap replay against the golden model
# =============================================================================
@cocotb.test()
async def test_pcap_replay_vs_golden(dut):
    """Replay real market data; compare top-of-book after every message.

    ⚠️ THIS IS MERGE GATE 3 (06-operations/01-build-and-release.md §5):
       "pcap replay regression: hardware book output bit-identical to the golden
        software model over the whole corpus."

    Skips — never fails — when the fixture is absent. Exchange market data is
    licensed and is not committed to this repository; ``tb/pcap/`` holds hashes
    and the blobs are fetched into ``tb/pcap/local/`` or pointed at by
    ``$FPGA_PCAP_DIR``. A suite that is red for everyone without the data stops
    being read, and a suite nobody reads gates nothing.

    ⚠️ Replay the capture BYTE-FOR-BYTE (05-verification §4 rule 4). No
       filtering, no de-duplication, no reordering. Retransmissions, A/B
       duplicates, gaps and malformed frames are the inputs that matter.
    """
    from common.itch_gen import parse_mold64

    fixture = resolve_fixture(os.environ.get("PCAP", "itch_short.pcap"))
    if fixture is None:
        dut._log.warning(
            "pcap fixture not found — tier 3 SKIPPED. This is the highest-value "
            "test in the repository and it did not run. Fetch the fixture per "
            "tb/pcap/README, or set $FPGA_PCAP_DIR."
        )
        return

    from common.pcap_replay import PcapReplayer

    cmp_ = await setup(dut)
    # active_locates mirrors the fabric's symbol filter. 05-verification §4
    # rule 1: the oracle must implement exactly the same simplifications as the
    # RTL, or an intentional difference is indistinguishable from a bug.
    cmp_.book = GoldenBook(BookConfig(active_locates={LOCATE}))

    replayer = PcapReplayer(driver=None, clk=dut.clk, log=dut._log)
    n_msgs = 0
    for payload in replayer.payloads(fixture):
        try:
            _session, seq, _count, msgs = parse_mold64(payload)
        except ValueError as exc:
            # A malformed packet in a real capture is a real input. The DUT must
            # drop-and-count it; the harness records it and continues.
            dut._log.debug(f"malformed MoldUDP64 packet skipped: {exc}")
            continue
        for i, m in enumerate(msgs):
            await cmp_.step(m, seq=seq + i)
            n_msgs += 1

    dut._log.info(f"pcap replay: {n_msgs} messages, "
                  f"oracle stats {cmp_.book.stats()}")
    assert n_msgs > 0, f"fixture {fixture} yielded no ITCH messages"
