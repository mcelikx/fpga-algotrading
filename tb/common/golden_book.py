"""The golden (reference) order book — THE VERIFICATION ORACLE.

Project : FPGA Algorithmic Trading System (Nasdaq Equities)
Governs : manuals/01-fpga-design/05-verification-and-simulation.md §4
          manuals/04-system-architecture/03-order-book-in-hardware.md
          manuals/08-nasdaq/04-totalview-itch-5.0.md

===============================================================================
⚠️  THIS FILE IS THE ORACLE. READ THIS BEFORE CHANGING ONE LINE OF IT.
===============================================================================

    This module is the DEFINITION OF CORRECT for the hardware order book. When
    ``tb/book/test_book_engine.py`` finds a divergence, this file is assumed
    right and ``rtl/book/`` is assumed wrong. That assumption is only safe if
    this code is *obviously* correct.

    THEREFORE, DELIBERATELY:

      * It is written to be OBVIOUSLY CORRECT, NEVER FAST. There is no caching,
        no incremental top-of-book maintenance, no early exit, no clever data
        structure. Best bid is recomputed with ``max()`` over a dict on every
        query. It is O(levels) where the hardware is O(1), and that is the
        point: the hardware's incremental maintenance is precisely the thing
        under test, so the oracle must not share it.

      * It reads like the protocol spec, in the spec's own order.

      * Every ITCH semantic that is easy to get wrong carries a comment saying
        what the wrong version does and how the drift shows up.

      * It is REVIEWED LIKE PRODUCTION CODE — and specifically, it must be
        reviewed by someone reading the Nasdaq spec, not by someone reading
        ``rtl/book/``. 05-verification §4 rule 5:
            "A bug in the oracle that happens to match a bug in the RTL is the
             worst outcome available, and it is why the oracle must be written
             from the *spec*, by someone reading the spec, and not derived from
             the RTL."

    ⚠️ IF YOU MAKE THIS FASTER, YOU HAVE MADE IT WORSE.

    ⚠️ ONE MORE TIME, THE LIMIT OF WHAT A GREEN RUN PROVES: a matching oracle
       and DUT prove they agree with EACH OTHER. They prove nothing about
       whether either agrees with Nasdaq. Only venue conformance testing does
       that (05-verification §9, last row).

===============================================================================

Matching the RTL's intentional simplifications
----------------------------------------------
05-verification §4 rule 1: "The oracle must implement exactly the same
simplifications as the RTL ... Divergence caused by an intentional
simplification is indistinguishable from a bug, and chasing one is how a week
disappears."

The shared simplifications live in :class:`BookConfig`, whose defaults mirror
``rtl/pkg/trading_pkg.sv``:

  ``BOOK_LEVELS   = 16``  price levels tracked per side
  ``N_ACTIVE      = 256`` symbols in the filtered active set
  ``PRICE_SCALE   = 10000`` 4 implied decimals — integers only, never floats

TODO(verify): if ``trading_pkg.sv`` changes any of these, change them here in
the same commit. Better still, have both read one shared config file.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field
from typing import Iterator

# ITCH type codes — duplicated from tb/common/itch_gen.py ON PURPOSE.
# tb/README.md §2 rule 1: nothing in tb/common/ generation may be imported by
# the oracle, and vice versa. The stimulus builder and the oracle must be able
# to DISAGREE; sharing a constants module would make an offset error invisible
# because both sides would make it identically.
T_SYSTEM_EVENT = b"S"
T_TRADING_ACTION = b"H"
T_REG_SHO = b"Y"
T_OPERATIONAL_HALT = b"h"
T_LULD_COLLAR = b"J"
T_ADD_ORDER = b"A"
T_ADD_ORDER_MPID = b"F"
T_ORDER_EXECUTED = b"E"
T_ORDER_EXEC_PRICE = b"C"
T_ORDER_CANCEL = b"X"
T_ORDER_DELETE = b"D"
T_ORDER_REPLACE = b"U"
T_TRADE = b"P"
T_CROSS_TRADE = b"Q"
T_BROKEN_TRADE = b"B"

BUY = "B"
SELL = "S"


@dataclass
class BookConfig:
    """The simplifications the hardware makes, mirrored exactly."""

    book_levels: int = 16          # trading_pkg::BOOK_LEVELS
    n_active: int = 256            # trading_pkg::N_ACTIVE
    price_scale: int = 10_000      # trading_pkg::PRICE_SCALE
    #: Locates the design tracks. ``None`` = all of them (unit tests);
    #: a set = the filtered active universe (pcap replay must use the same
    #: filter the fabric uses, or every unfiltered symbol looks like a bug).
    active_locates: set[int] | None = None


@dataclass
class Order:
    """One live order, keyed by its ITCH order reference number.

    ITCH is an ORDER-BASED feed: every message refers to an order reference, and
    the book is reconstructed by maintaining the set of live orders. There is no
    price-level message; levels are an aggregation *we* compute.
    """

    ref: int
    locate: int
    side: str           # BUY or SELL
    price: int          # scaled integer, 4 implied decimals
    shares: int
    stock: bytes


@dataclass
class TopOfBook:
    """Top-of-book snapshot. Mirrors ``trading_pkg::book_top_t``."""

    locate: int = 0
    bid_px: int = 0
    bid_qty: int = 0
    ask_px: int = 0
    ask_qty: int = 0
    last_px: int = 0
    bid_valid: bool = False
    ask_valid: bool = False
    crossed: bool = False
    stale: bool = False

    def as_tuple(self) -> tuple:
        """The comparison key used against the DUT.

        ⚠️ ``stale`` is included. A hardware book that has the right prices but
        the wrong stale flag will happily trade through a sequence gap, which is
        worse than having the wrong prices — at least a wrong price is visible.
        """
        return (
            self.locate,
            self.bid_px if self.bid_valid else 0,
            self.bid_qty if self.bid_valid else 0,
            self.ask_px if self.ask_valid else 0,
            self.ask_qty if self.ask_valid else 0,
            int(self.bid_valid),
            int(self.ask_valid),
            int(self.crossed),
            int(self.stale),
        )

    def canonical(self) -> str:
        """One record per line, fixed width, integer only.

        05-verification §4 rule 2: fixed widths, no floats, no timestamps, no
        dict ordering — so the comparison is ``cmp``, not a fuzzy comparator you
        have to trust. Commit the HASH of the trace, not the trace.
        """
        return (
            f"loc={self.locate:05d} "
            f"bid={self.bid_px:010d}@{self.bid_qty:010d} "
            f"ask={self.ask_px:010d}@{self.ask_qty:010d} "
            f"bv={int(self.bid_valid)} av={int(self.ask_valid)} "
            f"x={int(self.crossed)} st={int(self.stale)}"
        )


class GoldenBook:
    """Order-based reference book driven by raw ITCH messages.

    Usage::

        book = GoldenBook()
        for msg in messages:
            book.apply(msg)
            top = book.top_of_book(locate)

    The book is per-locate. ``top_of_book`` recomputes from scratch every call.
    """

    def __init__(self, cfg: BookConfig | None = None) -> None:
        self.cfg = cfg or BookConfig()

        #: order_ref -> Order. THE order-ID map. In hardware this is
        #: ``rtl/book/order_id_map.sv``, a 4-way set-associative BRAM structure
        #: with a bounded capacity; here it is an unbounded dict.
        #: ⚠️ THAT IS A REAL DIFFERENCE. The hardware map can fill up and drop
        #:    orders (counted, per CLAUDE.md §5.7); this dict cannot. When
        #:    replaying a full session, a divergence that starts at high order
        #:    counts and affects random symbols is the hardware map overflowing,
        #:    not a decode bug — see the divergence triage table in
        #:    05-verification §4. Set ``max_orders`` to model it if the RTL's
        #:    overflow behaviour is what is under test.
        self.orders: dict[int, Order] = {}

        #: locate -> side -> price -> aggregate shares.
        #: Recomputed nowhere; maintained by add/remove only, which is the one
        #: piece of incremental state the oracle keeps — and it is trivially
        #: auditable because ``_rebuild_levels`` can regenerate it from
        #: ``self.orders`` and ``verify_consistency`` checks that it matches.
        self.levels: dict[int, dict[str, dict[int, int]]] = {}

        self.last_px: dict[int, int] = {}
        self.stale: dict[int, bool] = {}

        #: Per-locate trading state from 'H'/'h'/'Y'. Not used by the book
        #: itself, but carried so the same oracle can check the risk gate.
        self.trading_state: dict[int, bytes] = {}
        self.ssr: dict[int, bytes] = {}
        self.session_state: bytes = b""

        # Counters. CLAUDE.md §5.7: every drop and error is counted, in the
        # oracle too, so the DUT's counters have something to be compared with.
        self.n_applied = 0
        self.n_ignored_type = 0
        self.n_ignored_locate = 0
        self.n_unknown_ref = 0
        self.n_execute_overflow = 0
        self.n_bad_length = 0

        #: Rolling per-locate message history — the last-N-messages-for-this-
        #: symbol window that 05-verification §4 rule 3 says to build in on day
        #: one, because it is what turns a failure into a fix.
        self.history: dict[int, list[str]] = {}
        self.history_depth = 8

    # =====================================================================
    # Message application
    # =====================================================================
    def apply(self, msg: bytes, seq: int | None = None) -> None:
        """Apply one raw ITCH message.

        Written as one flat dispatch, in spec order, with no shared helpers
        between message types. Sharing code between 'X' and 'D' is how a partial
        cancel becomes a delete.
        """
        if len(msg) < 11:
            self.n_bad_length += 1
            return

        t = msg[0:1]
        locate = struct.unpack(">H", msg[1:3])[0]

        if not self._is_active(locate) and t not in (T_SYSTEM_EVENT,):
            self.n_ignored_locate += 1
            return

        self._record(locate, seq, t, msg)

        # ---- System Event 'S' --------------------------------------------
        # Global session state. 'Q' = start of regular market hours.
        if t == T_SYSTEM_EVENT:
            self.session_state = msg[11:12]
            self.n_applied += 1
            return

        # ---- Stock Trading Action 'H' ------------------------------------
        if t == T_TRADING_ACTION:
            self.trading_state[locate] = msg[19:20]
            self.n_applied += 1
            return

        # ---- Reg SHO 'Y' -------------------------------------------------
        if t == T_REG_SHO:
            self.ssr[locate] = msg[19:20]
            self.n_applied += 1
            return

        # ---- Add Order 'A' / 'F' -----------------------------------------
        # 'F' is 'A' plus a 4-byte MPID. The book must treat them identically;
        # a decoder that handles 'A' and drops 'F' loses every attributed quote.
        if t in (T_ADD_ORDER, T_ADD_ORDER_MPID):
            ref = struct.unpack(">Q", msg[11:19])[0]
            side = BUY if msg[19:20] == b"B" else SELL
            shares = struct.unpack(">I", msg[20:24])[0]
            stk = msg[24:32]
            price = struct.unpack(">I", msg[32:36])[0]
            self._add(Order(ref, locate, side, price, shares, stk))
            self.n_applied += 1
            return

        # ---- Order Executed 'E' / 'C' ------------------------------------
        # Reduce the referenced order by the executed quantity. If that takes it
        # to zero, the order is REMOVED — not left resting at zero.
        #
        # ⚠️ 'C' (Order Executed With Price) carries a `printable` flag. A
        #    non-printable execution does NOT update the last-sale price, but it
        #    DOES still remove shares from the book. A book that skips
        #    non-printable executions drifts, slowly, and only on symbols where
        #    they occur.
        if t in (T_ORDER_EXECUTED, T_ORDER_EXEC_PRICE):
            ref = struct.unpack(">Q", msg[11:19])[0]
            shares = struct.unpack(">I", msg[19:23])[0]
            printable = True
            exec_px = None
            if t == T_ORDER_EXEC_PRICE:
                printable = msg[31:32] == b"Y"
                exec_px = struct.unpack(">I", msg[32:36])[0]
            self._execute(locate, ref, shares, printable, exec_px)
            self.n_applied += 1
            return

        # ---- Order Cancel 'X' --------------------------------------------
        # PARTIAL reduce. The order stays unless the reduction takes it to zero.
        # ⚠️ 'X' is not 'D'. Treating a cancel as a delete empties price levels
        #    that still have resting quantity, and the book shows a wider spread
        #    than the market has.
        if t == T_ORDER_CANCEL:
            ref = struct.unpack(">Q", msg[11:19])[0]
            shares = struct.unpack(">I", msg[19:23])[0]
            self._reduce(locate, ref, shares)
            self.n_applied += 1
            return

        # ---- Order Delete 'D' --------------------------------------------
        if t == T_ORDER_DELETE:
            ref = struct.unpack(">Q", msg[11:19])[0]
            self._remove(ref)
            self.n_applied += 1
            return

        # ---- Order Replace 'U' -------------------------------------------
        # ⚠️ THE CASE MOST OFTEN GOT WRONG.
        #    'U' removes the ORIGINAL reference entirely and creates a NEW one.
        #    It is NOT an in-place modify. The new order inherits the original's
        #    SIDE and STOCK — neither of which appears in the 'U' message — so
        #    it can only be processed by looking the original up first.
        #    A book that modifies in place leaks order references: the original
        #    ref stays live, a later 'D' on the new ref removes only the new
        #    one, and quantity accumulates that the real book does not have.
        #    The drift is slow, symbol-specific, and looks like a feed problem.
        if t == T_ORDER_REPLACE:
            orig_ref = struct.unpack(">Q", msg[11:19])[0]
            new_ref = struct.unpack(">Q", msg[19:27])[0]
            shares = struct.unpack(">I", msg[27:31])[0]
            price = struct.unpack(">I", msg[31:35])[0]
            orig = self.orders.get(orig_ref)
            if orig is None:
                # A replace of an unknown reference. Real: it happens after a
                # gap, or for an order added before we started listening.
                # Counted, never guessed at.
                self.n_unknown_ref += 1
                self.n_applied += 1
                return
            side, stk, loc = orig.side, orig.stock, orig.locate
            self._remove(orig_ref)                       # step 1: old ref OUT
            self._add(Order(new_ref, loc, side, price, shares, stk))  # step 2: new ref IN
            self.n_applied += 1
            return

        # ---- Trade 'P' ----------------------------------------------------
        # ⚠️ 'P' reports a trade against a NON-DISPLAYABLE order. It does NOT
        #    change the visible book. A book that applies it double-counts.
        #    It updates last-sale price only.
        if t == T_TRADE:
            price = struct.unpack(">I", msg[36:40])[0]
            self.last_px[locate] = price
            self.n_applied += 1
            return

        # ---- Cross Trade 'Q', Broken Trade 'B' ----------------------------
        # 'Q' is the auction print; it does not modify the continuous book.
        # 'B' busts a previously reported trade; it does not restore book state.
        if t in (T_CROSS_TRADE, T_BROKEN_TRADE):
            self.n_applied += 1
            return

        # ---- Anything else -------------------------------------------------
        # ⚠️ An unknown or unhandled type is NOT an error. Nasdaq adds message
        #    types. Count it and move on. What is NOT acceptable is guessing at
        #    its length — that is the transport's job, and the transport
        #    (MoldUDP64) length-prefixes every block precisely so this is safe.
        self.n_ignored_type += 1

    # =====================================================================
    # Primitive book operations — each does exactly one thing
    # =====================================================================
    def _add(self, o: Order) -> None:
        if o.shares == 0:
            # A zero-share add is not a resting order. Ignore, do not create a
            # level with zero quantity that then shows up as a phantom top.
            return
        self.orders[o.ref] = o
        side_levels = self.levels.setdefault(o.locate, {BUY: {}, SELL: {}})[o.side]
        side_levels[o.price] = side_levels.get(o.price, 0) + o.shares

    def _remove(self, ref: int) -> None:
        o = self.orders.pop(ref, None)
        if o is None:
            self.n_unknown_ref += 1
            return
        self._level_sub(o.locate, o.side, o.price, o.shares)

    def _reduce(self, locate: int, ref: int, shares: int) -> None:
        o = self.orders.get(ref)
        if o is None:
            self.n_unknown_ref += 1
            return
        take = min(shares, o.shares)
        if take != shares:
            # Cancelling more than is resting. Saturate at zero; never wrap.
            # ``trading_pkg::sat_sub64`` exists in the RTL for exactly this, and
            # CLAUDE.md §5 requires saturating arithmetic — "a wrapped counter
            # turns a risk check into a no-op."
            self.n_execute_overflow += 1
        o.shares -= take
        self._level_sub(locate, o.side, o.price, take)
        if o.shares == 0:
            self.orders.pop(ref, None)

    def _execute(self, locate: int, ref: int, shares: int,
                 printable: bool, exec_px: int | None) -> None:
        o = self.orders.get(ref)
        if o is None:
            self.n_unknown_ref += 1
            return
        # Last-sale price comes from the ORDER's price for 'E', and from the
        # explicit execution price for 'C'. Non-printable executions update
        # neither, but still remove shares.
        if printable:
            self.last_px[locate] = exec_px if exec_px is not None else o.price
        self._reduce(locate, ref, shares)

    def _level_sub(self, locate: int, side: str, price: int, shares: int) -> None:
        side_levels = self.levels.setdefault(locate, {BUY: {}, SELL: {}})[side]
        remaining = side_levels.get(price, 0) - shares
        if remaining <= 0:
            # Delete the key rather than leaving a zero. A zero-quantity level
            # that stays in the dict would be selected by ``max()`` as the best
            # price with zero size — the phantom-top bug, in the oracle.
            side_levels.pop(price, None)
        else:
            side_levels[price] = remaining

    # =====================================================================
    # Queries — recomputed from scratch, every time, deliberately
    # =====================================================================
    def top_of_book(self, locate: int) -> TopOfBook:
        """Recompute top-of-book for one locate. O(levels). Intentionally naive.

        The hardware maintains this incrementally
        (04-system-architecture/03-order-book-in-hardware.md), which is the
        whole point of the hardware and therefore exactly the thing that must
        NOT be shared with the oracle. ``max()`` over a dict cannot have an
        incremental-update bug.
        """
        top = TopOfBook(locate=locate)
        sides = self.levels.get(locate, {BUY: {}, SELL: {}})

        bids = {p: q for p, q in sides[BUY].items() if q > 0}
        asks = {p: q for p, q in sides[SELL].items() if q > 0}

        if bids:
            best_bid = max(bids)
            top.bid_px, top.bid_qty, top.bid_valid = best_bid, bids[best_bid], True
        if asks:
            best_ask = min(asks)
            top.ask_px, top.ask_qty, top.ask_valid = best_ask, asks[best_ask], True

        top.last_px = self.last_px.get(locate, 0)
        top.stale = self.stale.get(locate, False)

        # A crossed book (bid >= ask) is possible transiently in an order-based
        # reconstruction and must NEVER be acted on. fpga_top.sv asserts it:
        # "A crossed book must never produce an order."
        top.crossed = bool(top.bid_valid and top.ask_valid
                           and top.bid_px >= top.ask_px)
        return top

    def depth(self, locate: int, side: str, n: int | None = None
              ) -> list[tuple[int, int]]:
        """Aggregated price levels, best first, truncated to ``book_levels``.

        Truncation mirrors the hardware's ``BOOK_LEVELS`` so a comparison beyond
        the tracked depth is not attempted. Comparing depth the fabric does not
        keep is comparing against a simplification, and 05-verification §4 rule 1
        is explicit that such a divergence is indistinguishable from a bug.
        """
        n = n or self.cfg.book_levels
        sides = self.levels.get(locate, {BUY: {}, SELL: {}})[side]
        live = [(p, q) for p, q in sides.items() if q > 0]
        live.sort(key=lambda pq: pq[0], reverse=(side == BUY))
        return live[:n]

    def set_stale(self, locate: int | None = None, value: bool = True) -> None:
        """Mark a locate (or every locate) stale after a sequence gap.

        ⚠️ A gap means the book is not trustworthy. The required system
        behaviour is: raise the gap flag, move affected symbols to
        ``trading_pkg::TRADE_STALE``, and let the risk gate reject with
        ``RISK_BOOK_STALE``. Trading through a gap is trading on a book you
        already know is wrong.
        """
        if locate is None:
            for loc in set(list(self.levels) + list(self.stale)):
                self.stale[loc] = value
        else:
            self.stale[locate] = value

    def clear(self, locate: int | None = None) -> None:
        """Start-of-day / resync clear. Mirrors ``book_op_e::BOOK_CLEAR``."""
        if locate is None:
            self.orders.clear()
            self.levels.clear()
            self.last_px.clear()
            self.stale.clear()
            return
        for ref in [r for r, o in self.orders.items() if o.locate == locate]:
            del self.orders[ref]
        self.levels.pop(locate, None)
        self.last_px.pop(locate, None)
        self.stale.pop(locate, None)

    # =====================================================================
    # Self-audit
    # =====================================================================
    def verify_consistency(self) -> None:
        """Rebuild the aggregated levels from ``self.orders`` and compare.

        The oracle keeps exactly one piece of derived state (``self.levels``).
        This proves it agrees with the ground truth (``self.orders``) — so a
        divergence against the DUT can be attributed to the DUT with
        confidence, which is the entire value of an oracle.

        Call it after every test, and after every N messages during a long
        replay. It is slow. It is meant to be.
        """
        rebuilt: dict[int, dict[str, dict[int, int]]] = {}
        for o in self.orders.values():
            side_map = rebuilt.setdefault(o.locate, {BUY: {}, SELL: {}})[o.side]
            side_map[o.price] = side_map.get(o.price, 0) + o.shares

        for locate, sides in self.levels.items():
            for side in (BUY, SELL):
                have = {p: q for p, q in sides[side].items() if q > 0}
                want = rebuilt.get(locate, {BUY: {}, SELL: {}})[side]
                if have != want:
                    raise AssertionError(
                        f"ORACLE SELF-CHECK FAILED for locate {locate} side "
                        f"{side}:\n  aggregated levels: {sorted(have.items())}\n"
                        f"  rebuilt from orders: {sorted(want.items())}\n"
                        f"The oracle has a bug. Fix it before believing anything "
                        f"it says about the DUT."
                    )

    # =====================================================================
    # Failure reporting
    # =====================================================================
    def _record(self, locate: int, seq: int | None, t: bytes, msg: bytes) -> None:
        h = self.history.setdefault(locate, [])
        ref = ""
        if len(msg) >= 19 and t in (T_ADD_ORDER, T_ADD_ORDER_MPID, T_ORDER_EXECUTED,
                                    T_ORDER_EXEC_PRICE, T_ORDER_CANCEL,
                                    T_ORDER_DELETE, T_ORDER_REPLACE):
            ref = f" ref=0x{struct.unpack('>Q', msg[11:19])[0]:016X}"
        h.append(f"{seq if seq is not None else '-':>12} "
                 f"{t.decode('ascii', 'replace')}{ref}")
        if len(h) > self.history_depth:
            del h[0]

    def divergence_report(self, locate: int, expected: TopOfBook,
                          actual: TopOfBook, seq: int | None = None) -> str:
        """The report that turns a failure into a fix.

        05-verification §4 rule 3: "A mismatch report that says '12,481
        differences' is unactionable." Stop at the FIRST divergence, print the
        expected/actual pair, and print the last N messages for THIS symbol.
        """
        lines = [
            "",
            "=" * 78,
            f"FIRST DIVERGENCE at ITCH seq {seq} (locate {locate})",
            "=" * 78,
            f"  expected  {expected.canonical()}",
            f"  actual    {actual.canonical()}",
            "",
            f"  Last {self.history_depth} messages for this locate:",
        ]
        for h in self.history.get(locate, []):
            lines.append(f"    {h}")
        lines += [
            "",
            "  Divergence triage (05-verification §4):",
            "    one field wrong on EVERY message of one type -> field offset/length",
            "    wrong ONLY when the message crosses a beat boundary -> straddle bug",
            "    wrong ONLY on back-to-back updates to one level -> missing RMW",
            "      write-forwarding (01-fpga-design/03-memory-and-storage.md §4)",
            "    byte-swapped or absurdly large -> endianness",
            "    off by a factor of 10^k -> implied-decimal scaling",
            "    random symbols wrong under load -> order-ref map full, silent drop",
            "    diverges at a DIFFERENT point every run -> a race, probably CDC;",
            "      simulation is lying to you (05-verification §9)",
            "=" * 78,
        ]
        return "\n".join(lines)

    # =====================================================================
    def _is_active(self, locate: int) -> bool:
        if self.cfg.active_locates is None:
            return True
        return locate in self.cfg.active_locates

    def canonical_trace(self, locates: list[int] | None = None) -> Iterator[str]:
        """Canonical serialization of every tracked locate's top of book."""
        for loc in sorted(locates or self.levels.keys()):
            yield self.top_of_book(loc).canonical()

    def stats(self) -> dict[str, int]:
        return {
            "applied": self.n_applied,
            "ignored_type": self.n_ignored_type,
            "ignored_locate": self.n_ignored_locate,
            "unknown_ref": self.n_unknown_ref,
            "execute_overflow": self.n_execute_overflow,
            "bad_length": self.n_bad_length,
            "live_orders": len(self.orders),
        }
