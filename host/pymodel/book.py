"""book.py — the golden ORDER-BASED order book.

OPTIMIZED FOR OBVIOUS CORRECTNESS, NOT FOR SPEED.

ITCH 5.0 is an ORDER-based feed, not a level-based one.  ``Order Executed``,
``Order Cancel`` and ``Order Delete`` carry a 64-bit order reference and
nothing else about the order — no side, no price, no quantity.  So the book is
not one data structure, it is two
(manuals/04-system-architecture/03-order-book-in-hardware.md §1):

    ORDER MAP    order_ref -> {sym, locate, side, price, qty}
    LEVELS       (sym, side, price) -> {qty, order_count}

and the top of book is derived from the second.

WHERE THIS MODEL IS DELIBERATELY DUMBER THAN THE FABRIC
-------------------------------------------------------
Each of these is a place where a clever implementation was available and the
stupid one was chosen on purpose, because this file defines what "correct"
means and its correctness has to be visible by reading it:

* **Best bid/ask is recomputed with ``max()``/``min()`` over the level dict on
  every single update.**  The fabric maintains the top incrementally with a
  second-best cache and a bounded occupancy-bitmap rescan (04.03 §6), which is
  the single subtlest piece of logic in the design.  A recompute cannot have a
  cache-coherence bug because it has no cache.  If the model and the fabric
  disagree about the best price, the incremental maintenance is the suspect.
* **The order map is a plain Python ``dict`` with the full 64-bit key.**  No
  hash, no sets, no ways, no overflow region, no eviction — so no
  mis-attribution is possible.  The fabric's 4-way table is where a tag
  collision could silently apply a delete to the wrong order (04.03 §2.3); the
  oracle has no such failure mode to share.
* **Empty levels are deleted from the dict.**  "Occupied" therefore means
  "present", and there is no separate occupancy bitmap to fall out of sync with
  the quantities.
* **There is no price-to-level-index normalisation.**  The fabric divides by
  the tick to index a level array, with a bounded window and a per-symbol base
  (04.03 §4).  The model keys levels by the raw ITCH price integer, so it has
  no window, no re-centring, and no aliasing.  A divergence that appears only
  for prices far from the fabric's window base is a window bug, not a book bug,
  and this asymmetry is how you tell.
* **Read-modify-write hazards cannot exist**, because updates are applied one
  at a time, to completion, in a single thread.  The fabric needs a write
  forwarding bypass for exactly this (04.03 §8) and getting its depth wrong
  produces slow drift — which this model will catch, message by message.

NO FLOATS.  Prices and quantities are ``int`` throughout.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from .trading_pkg_mirror import (
    BOOK_LEVELS,
    N_ACTIVE,
    BookEvt,
    BookOp,
    BookTop,
    Side,
    format_price,
)

__all__ = [
    "SymbolFilter",
    "LiveOrder",
    "Level",
    "SymbolBook",
    "BookCounters",
    "OrderBookModel",
]


# =============================================================================
# 1. Symbol filter — raw ITCH locate -> active-set index
# =============================================================================


class SymbolFilter:
    """``rtl/feed/symbol_filter.sv`` as a dict.

    The fabric filters on the raw 16-bit stock locate at R5, before the order
    map, because the locate is present on EVERY ITCH message including the ones
    that carry no symbol string (04.02 §7).  This model does the same, at the
    same point, so that "the order map never contains orders for unsubscribed
    symbols" is true in both.
    """

    def __init__(self, mapping: dict[int, int] | None = None) -> None:
        self._locate_to_sym: dict[int, int] = {}
        for locate, sym in (mapping or {}).items():
            self.subscribe(locate, sym)

    def subscribe(self, locate: int, sym: int) -> None:
        if not 0 <= sym < N_ACTIVE:
            raise ValueError(
                f"active-set index {sym} out of range (N_ACTIVE={N_ACTIVE})"
            )
        self._locate_to_sym[locate] = sym

    def sym_for(self, locate: int) -> int | None:
        """Active-set index, or ``None`` when the locate is not subscribed."""
        return self._locate_to_sym.get(locate)

    def is_subscribed(self, locate: int) -> bool:
        return locate in self._locate_to_sym

    def subscribed_locates(self) -> tuple[int, ...]:
        return tuple(sorted(self._locate_to_sym))

    def snapshot(self) -> dict[int, int]:
        return dict(sorted(self._locate_to_sym.items()))

    @classmethod
    def identity(cls, count: int = N_ACTIVE) -> SymbolFilter:
        """Locate ``n`` -> sym ``n`` for ``n`` in ``[0, count)``.

        A convenience for tests.  Production configuration comes from the ITCH
        Stock Directory ('R') messages plus the traded-universe list; the host
        writes it into the fabric via ``PARAM_FILTER_*``.
        """
        return cls({n: n for n in range(min(count, N_ACTIVE))})


# =============================================================================
# 2. Book state
# =============================================================================


@dataclass(slots=True)
class LiveOrder:
    """One resting order.  What the order map has to remember to apply a delete."""

    order_ref: int
    sym: int
    locate: int
    side: Side
    price: int  # the RESTING price.  Never the execution price from a 'C'.
    qty: int  # remaining, not original


@dataclass(slots=True)
class Level:
    """Aggregate state of one price level on one side of one symbol."""

    qty: int = 0
    order_count: int = 0


@dataclass(slots=True)
class SymbolBook:
    """Everything the book knows about one active symbol."""

    sym: int
    bids: dict[int, Level] = field(default_factory=dict)  # price -> Level
    asks: dict[int, Level] = field(default_factory=dict)
    last_px: int = 0
    #: ⚠️ STICKY.  Set by hardware-equivalent conditions; cleared ONLY by an
    #: explicit per-symbol :meth:`OrderBookModel.clear_stale`.  The model never
    #: decides on its own that things look fine again (04.03 §10).
    stale: bool = False
    stale_reasons: list[str] = field(default_factory=list)
    #: The last published top, used to compute ``top_changed``.
    _last_published: tuple[bool, int, int, bool, int, int] | None = None

    def side_levels(self, side: Side) -> dict[int, Level]:
        return self.bids if side is Side.BUY else self.asks

    def best_bid(self) -> tuple[int, int] | None:
        """(price, qty) of the highest bid, or None.  Recomputed, never cached."""
        if not self.bids:
            return None
        px = max(self.bids)
        return px, self.bids[px].qty

    def best_ask(self) -> tuple[int, int] | None:
        """(price, qty) of the lowest ask, or None.  Recomputed, never cached."""
        if not self.asks:
            return None
        px = min(self.asks)
        return px, self.asks[px].qty


@dataclass(slots=True)
class BookCounters:
    """Every counter ``manuals/08-nasdaq/04-*.md §9.3`` calls mandatory that the
    book (rather than the feed handler) owns.

    ⚠️ ``negative_book_qty_attempts`` deserves special mention: a level going
    negative is arithmetically impossible if the decode is correct.  A nonzero
    count is PROOF of a decode bug, and it is the cheapest possible self-test.
    Saturate at zero, count, and mark the book stale — never wrap.
    """

    adds: int = 0
    executes: int = 0
    cancels: int = 0
    deletes: int = 0
    replaces: int = 0
    clears: int = 0
    nops: int = 0

    unknown_order_ref: int = 0
    duplicate_order_ref: int = 0
    negative_book_qty_attempts: int = 0
    book_stale_events: int = 0
    orders_removed_at_zero: int = 0
    #: Occupied levels on one side exceeded ``trading_pkg::BOOK_LEVELS``.
    #: ⚠️ NOT an error for the model, which keeps the whole book.  It means the
    #: fabric's level storage cannot represent this book, so a divergence
    #: beyond that depth is expected rather than a bug.  See the note in
    #: :meth:`OrderBookModel.apply`.
    levels_over_book_levels: int = 0
    live_orders_max: int = 0

    def snapshot(self) -> dict[str, int]:
        return {
            "adds": self.adds,
            "executes": self.executes,
            "cancels": self.cancels,
            "deletes": self.deletes,
            "replaces": self.replaces,
            "clears": self.clears,
            "nops": self.nops,
            "unknown_order_ref": self.unknown_order_ref,
            "duplicate_order_ref": self.duplicate_order_ref,
            "negative_book_qty_attempts": self.negative_book_qty_attempts,
            "book_stale_events": self.book_stale_events,
            "orders_removed_at_zero": self.orders_removed_at_zero,
            "levels_over_book_levels": self.levels_over_book_levels,
            "live_orders_max": self.live_orders_max,
        }


# =============================================================================
# 3. The book
# =============================================================================


class OrderBookModel:
    """The reference order book.  One instance per model; no global state."""

    def __init__(self) -> None:
        # order_ref -> LiveOrder.  Full 64-bit key, plain dict, no eviction.
        self.orders: dict[int, LiveOrder] = {}
        # active-set index -> SymbolBook.  Created on first touch.
        self.books: dict[int, SymbolBook] = {}
        self.counters = BookCounters()

    # -- state access -------------------------------------------------------

    def book_for(self, sym: int) -> SymbolBook:
        book = self.books.get(sym)
        if book is None:
            book = SymbolBook(sym=sym)
            self.books[sym] = book
        return book

    def live_order(self, order_ref: int) -> LiveOrder | None:
        return self.orders.get(order_ref)

    # -- stale bit ----------------------------------------------------------

    def mark_stale(self, sym: int, reason: str) -> None:
        """Set the sticky per-symbol stale bit.

        ⚠️ Once set, no order may be produced for this symbol until the host
        explicitly clears it after a verified resync (04.03 §9.2 step 7).
        There is no automatic recovery, here or in the fabric.
        """
        book = self.book_for(sym)
        if not book.stale:
            self.counters.book_stale_events += 1
        book.stale = True
        if reason not in book.stale_reasons:
            book.stale_reasons.append(reason)

    def clear_stale(self, sym: int) -> None:
        """Explicit, per-symbol stale clear.  Mirrors the host register write.

        ⚠️ There is deliberately no ``clear_all_stale``.  "Clear all stale" is a
        foot-gun that will eventually be used at 3 a.m. by someone trying to
        get trading back up (04.03 §9.2).
        """
        book = self.book_for(sym)
        book.stale = False
        book.stale_reasons.clear()

    # -- the update itself --------------------------------------------------

    def apply(self, evt: BookEvt) -> BookTop:
        """Apply one ``book_evt_t`` and return the resulting ``book_top_t``.

        Every branch below either applies a fully-determined update or counts
        a fault and marks the symbol stale.  There is no branch that guesses.
        A miss is information; a guess is corruption (04.03 §9.3).
        """
        book = self.book_for(evt.sym)

        if evt.op is BookOp.CLEAR:
            self._apply_clear(book)
        elif evt.op is BookOp.ADD:
            self._apply_add(book, evt)
        elif evt.op is BookOp.EXECUTE:
            self._apply_reduce(book, evt, executed=True)
        elif evt.op is BookOp.CANCEL:
            self._apply_reduce(book, evt, executed=False)
        elif evt.op is BookOp.DELETE:
            self._apply_delete(book, evt)
        elif evt.op is BookOp.REPLACE:
            self._apply_replace(book, evt)
        elif evt.op is BookOp.NOP:
            self.counters.nops += 1
            # 'P' (non-cross trade) and 'Q' (cross trade) reach here.  They
            # have NO book effect — applying them corrupts the book — but they
            # ARE tape prints, so they move last price.
            self._update_last_price(book, evt)
        else:  # pragma: no cover - BookOp is exhaustive
            raise ValueError(f"unhandled book op {evt.op!r}")

        self.counters.live_orders_max = max(
            self.counters.live_orders_max, len(self.orders)
        )
        # Depth observability, not an error.  See BookCounters.
        for levels in (book.bids, book.asks):
            if len(levels) > BOOK_LEVELS:
                self.counters.levels_over_book_levels += 1
                break

        return self._publish(book, evt)

    # -- individual operations ---------------------------------------------

    def _apply_clear(self, book: SymbolBook) -> None:
        """``BOOK_CLEAR`` — resync / start of day.

        ⚠️ Clearing the book does NOT clear the stale bit.  In the fabric this
        is an epoch bump (04.03 §9.1); the stale bit is cleared separately, per
        symbol, after the host has verified the rebuilt book.
        """
        self.counters.clears += 1
        for order_ref in [r for r, o in self.orders.items() if o.sym == book.sym]:
            del self.orders[order_ref]
        book.bids.clear()
        book.asks.clear()
        # last_px survives a clear: it is tape history, not book state.

    def _apply_add(self, book: SymbolBook, evt: BookEvt) -> None:
        """ITCH 'A' / 'F'."""
        self.counters.adds += 1
        if evt.order_ref in self.orders:
            # The venue never reuses a live reference.  If we see one, either
            # we missed the delete or the decode is wrong.  Overwriting would
            # silently orphan the level quantity of the old order.
            self.counters.duplicate_order_ref += 1
            self.mark_stale(evt.sym, f"duplicate add for order_ref {evt.order_ref}")
            return
        if evt.qty == 0:
            # A zero-share add is not a book entry.  Refuse it rather than
            # creating an order that can never be reduced and a level whose
            # order count can never come back down.
            self.mark_stale(evt.sym, f"zero-share add for order_ref {evt.order_ref}")
            return
        self.orders[evt.order_ref] = LiveOrder(
            order_ref=evt.order_ref,
            sym=evt.sym,
            locate=evt.locate,
            side=evt.side,
            price=evt.price,
            qty=evt.qty,
        )
        self._level_add(book, evt.side, evt.price, evt.qty)

    def _apply_reduce(self, book: SymbolBook, evt: BookEvt, *, executed: bool) -> None:
        """ITCH 'E' / 'C' (executed) and 'X' (partial cancel).

        ⚠️ THE LEVEL IS ALWAYS LOCATED BY THE ORDER'S **STORED** PRICE.
        ``C`` (Order Executed With Price) carries an execution price that can
        differ from the resting price — price sliding, pegs and hidden levels
        all produce this.  Using it to find the level subtracts liquidity from
        a level that never had it, and adds a phantom to the one that did
        (08-nasdaq/04 §7).  ``evt.price`` is used for the TAPE only.

        ⚠️ ``E``, ``C`` and ``X`` can all drive the remaining quantity to zero,
        which must remove the order and decrement the level's order count.
        Handling removal only in ``D`` is a classic bug: the book keeps phantom
        zero-quantity orders and the order count becomes meaningless.
        """
        if executed:
            self.counters.executes += 1
        else:
            self.counters.cancels += 1

        order = self.orders.get(evt.order_ref)
        if order is None:
            self.counters.unknown_order_ref += 1
            self.mark_stale(
                evt.sym,
                f"{'execute' if executed else 'cancel'} for unknown order_ref "
                f"{evt.order_ref}",
            )
            return

        delta = evt.qty
        if delta > order.qty:
            # Arithmetically impossible if the decode is correct.
            self.counters.negative_book_qty_attempts += 1
            self.mark_stale(
                evt.sym,
                f"reduce of {delta} against order_ref {evt.order_ref} holding "
                f"{order.qty}",
            )
            delta = order.qty  # saturate at zero, never wrap

        order.qty -= delta
        fully_gone = order.qty == 0
        self._level_remove(
            book, order.side, order.price, delta, remove_order=fully_gone
        )
        if fully_gone:
            del self.orders[evt.order_ref]
            self.counters.orders_removed_at_zero += 1

        if executed:
            self._update_last_price(book, evt, fallback_price=order.price)

    def _apply_delete(self, book: SymbolBook, evt: BookEvt) -> None:
        """ITCH 'D' — remove the order entirely, at its REMAINING quantity."""
        self.counters.deletes += 1
        order = self.orders.pop(evt.order_ref, None)
        if order is None:
            self.counters.unknown_order_ref += 1
            self.mark_stale(evt.sym, f"delete for unknown order_ref {evt.order_ref}")
            return
        self._level_remove(
            book, order.side, order.price, order.qty, remove_order=True
        )

    def _apply_replace(self, book: SymbolBook, evt: BookEvt) -> None:
        """ITCH 'U' — ⚠️ DELETE THE ORIGINAL REFERENCE, THEN CREATE A NEW ONE.

        This is the single most commonly mis-implemented message in ITCH, and
        ``itch_pkg.sv`` §4 calls it out explicitly.  Two things go wrong if you
        treat it as an in-place modify:

          1. The old reference is never removed from the order map, so the map
             fills with dead keys and eventually overflows.
          2. Every subsequent message for that order arrives with the NEW
             reference, misses, and is dropped — so the order becomes a
             permanent phantom at its price level.

        And one more, quieter: the order being replaced may have been PARTIALLY
        EXECUTED since it was added, so the quantity removed from the old level
        is its **current remaining quantity from the order map**, not the
        quantity it was added with.  Subtracting the original quantity drifts
        the book negative over the day.

        ⚠️ The 'U' message does NOT carry a side.  The side comes from the
        original order.  Therefore a miss on the original reference means the
        add half cannot be applied either — there is nowhere to put it.  Nothing
        is applied, the miss is counted, and the symbol goes stale.
        """
        self.counters.replaces += 1
        order = self.orders.pop(evt.order_ref, None)
        if order is None:
            self.counters.unknown_order_ref += 1
            self.mark_stale(
                evt.sym,
                f"replace of unknown original order_ref {evt.order_ref} "
                f"(side unknown, so the new order cannot be placed either)",
            )
            return
        if evt.new_order_ref in self.orders:
            self.counters.duplicate_order_ref += 1
            self.mark_stale(
                evt.sym, f"replace into live order_ref {evt.new_order_ref}"
            )
            # The original has already been popped; put it back so the book and
            # the map stay consistent with each other.
            self.orders[evt.order_ref] = order
            return

        # 1. delete the old reference, at its CURRENT remaining quantity
        self._level_remove(
            book, order.side, order.price, order.qty, remove_order=True
        )
        # 2. insert the new reference, at the message's shares and price
        self.orders[evt.new_order_ref] = LiveOrder(
            order_ref=evt.new_order_ref,
            sym=evt.sym,
            locate=evt.locate,
            side=order.side,  # inherited: 'U' carries no side
            price=evt.price,
            qty=evt.qty,
        )
        self._level_add(book, order.side, evt.price, evt.qty)

    # -- level arithmetic ---------------------------------------------------

    def _level_add(self, book: SymbolBook, side: Side, price: int, qty: int) -> None:
        levels = book.side_levels(side)
        level = levels.get(price)
        if level is None:
            level = Level()
            levels[price] = level
        level.qty += qty
        level.order_count += 1

    def _level_remove(
        self,
        book: SymbolBook,
        side: Side,
        price: int,
        qty: int,
        *,
        remove_order: bool,
    ) -> None:
        """Subtract ``qty`` from a level, decrementing the order count only if
        the order itself is gone.

        ⚠️ ``remove_order`` is the difference between a partial cancel and a
        delete, and getting it wrong is invisible in the aggregate quantity.
        An 'X' that reduces an order from 500 to 460 must NOT decrement the
        level's order count — the order is still there.  A book that
        decrements on every reduce drifts its order counts toward zero and
        then starts deleting occupied levels, which shows up as a missing
        price level long after the message that caused it.
        """
        levels = book.side_levels(side)
        level = levels.get(price)
        if level is None:
            # The order map said there was an order here.  There was not.
            self.counters.negative_book_qty_attempts += 1
            self.mark_stale(
                book.sym,
                f"remove {qty} from empty level {format_price(price)} "
                f"{side.name}",
            )
            return
        if qty > level.qty:
            self.counters.negative_book_qty_attempts += 1
            self.mark_stale(
                book.sym,
                f"remove {qty} from level {format_price(price)} {side.name} "
                f"holding {level.qty}",
            )
            qty = level.qty  # saturate at zero, never wrap
        level.qty -= qty
        if remove_order:
            level.order_count -= 1

        if level.order_count <= 0:
            # Empty levels are deleted so that "occupied" == "present".
            if level.qty != 0 or level.order_count < 0:
                self.counters.negative_book_qty_attempts += 1
                self.mark_stale(
                    book.sym,
                    f"level {format_price(price)} {side.name} emptied with "
                    f"qty={level.qty} count={level.order_count}",
                )
            del levels[price]

    def _update_last_price(
        self, book: SymbolBook, evt: BookEvt, fallback_price: int | None = None
    ) -> None:
        """Maintain ``last_px`` from tape prints.

        ⚠️ CONTRACT-OPEN.  ``book_evt_t.printable`` is documented as "trade is
        printable (affects last-price)", which is the rule implemented here:
        a printable event with a price moves last price, a non-printable one
        does not — but a non-printable 'C' STILL updates the book.  What is not
        yet pinned by any RTL is whether ``feed_handler`` emits an event at all
        for 'P' and 'Q' (``itch_pkg::is_book_msg()`` says they are not book
        messages).  If the fabric maintains last price somewhere else, this is
        where the two will differ, and it is a contract question, not a bug in
        either.  Flagged in the module report.
        """
        if not evt.printable:
            return
        price = evt.price if evt.price != 0 else (fallback_price or 0)
        if price != 0:
            book.last_px = price

    # -- publication --------------------------------------------------------

    def _publish(self, book: SymbolBook, evt: BookEvt) -> BookTop:
        bid = book.best_bid()
        ask = book.best_ask()
        bid_px, bid_qty = bid if bid is not None else (0, 0)
        ask_px, ask_qty = ask if ask is not None else (0, 0)
        bid_valid = bid is not None
        ask_valid = ask is not None

        published = (bid_valid, bid_px, bid_qty, ask_valid, ask_px, ask_qty)
        # ⚠️ ``last_px`` is deliberately EXCLUDED from the top-changed test.
        # ``book_top_t.top_changed`` is documented as "top-of-book actually
        # moved this update", and a trade print that does not touch a level has
        # not moved the top.  This is a decision, not an oversight; if the
        # fabric includes last_px, this is the line to change.
        top_changed = published != book._last_published
        book._last_published = published

        return BookTop(
            sym=book.sym,
            bid_px=bid_px,
            bid_qty=bid_qty,
            ask_px=ask_px,
            ask_qty=ask_qty,
            last_px=book.last_px,
            bid_valid=bid_valid,
            ask_valid=ask_valid,
            # bid >= ask on a valid two-sided book.  Never act on it.
            crossed=bid_valid and ask_valid and bid_px >= ask_px,
            stale=book.stale,
            top_changed=top_changed,
            rx_cycle=evt.rx_cycle,
        )

    def top(self, sym: int) -> BookTop:
        """Current top of book WITHOUT applying anything.

        ``top_changed`` is always ``False`` here and ``rx_cycle`` is 0 — this
        is an observation, not a publication, so it must not disturb the
        change-detection state a testbench is comparing against.
        """
        book = self.book_for(sym)
        bid = book.best_bid()
        ask = book.best_ask()
        bid_px, bid_qty = bid if bid is not None else (0, 0)
        ask_px, ask_qty = ask if ask is not None else (0, 0)
        return BookTop(
            sym=sym,
            bid_px=bid_px,
            bid_qty=bid_qty,
            ask_px=ask_px,
            ask_qty=ask_qty,
            last_px=book.last_px,
            bid_valid=bid is not None,
            ask_valid=ask is not None,
            crossed=bid is not None and ask is not None and bid_px >= ask_px,
            stale=book.stale,
            top_changed=False,
            rx_cycle=0,
        )

    # -- dumps --------------------------------------------------------------

    def depth(self, sym: int, side: Side, levels: int = BOOK_LEVELS) -> list[tuple[int, int, int]]:
        """Top ``levels`` of one side as ``[(price, qty, order_count), ...]``.

        Bids descend, asks ascend — best first, always.
        """
        book = self.book_for(sym)
        table = book.side_levels(side)
        prices = sorted(table, reverse=(side is Side.BUY))[:levels]
        return [(px, table[px].qty, table[px].order_count) for px in prices]

    def snapshot(self) -> dict[str, object]:
        """A stable, ordered, JSON-able dump of the whole book.

        Deterministic ordering is the point: two dumps of two runs must diff
        cleanly, and a diff is the entire debugging session.
        """
        return {
            "live_orders": len(self.orders),
            "counters": self.counters.snapshot(),
            "symbols": {
                str(sym): {
                    "stale": self.books[sym].stale,
                    "stale_reasons": list(self.books[sym].stale_reasons),
                    "last_px": self.books[sym].last_px,
                    "bids": [
                        [px, lv.qty, lv.order_count]
                        for px, lv in sorted(
                            self.books[sym].bids.items(), reverse=True
                        )
                    ],
                    "asks": [
                        [px, lv.qty, lv.order_count]
                        for px, lv in sorted(self.books[sym].asks.items())
                    ],
                }
                for sym in sorted(self.books)
            },
            "orders": {
                str(ref): {
                    "sym": o.sym,
                    "locate": o.locate,
                    "side": o.side.name,
                    "price": o.price,
                    "qty": o.qty,
                }
                for ref, o in sorted(self.orders.items())
            },
        }
