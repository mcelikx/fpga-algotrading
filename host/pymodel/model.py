"""model.py — :class:`GoldenModel`, the step-by-step API the testbenches drive.

OPTIMIZED FOR OBVIOUS CORRECTNESS, NOT FOR SPEED.

This is the front door.  A cocotb testbench feeds it exactly what it feeds the
DUT — one raw ITCH message, or one MoldUDP64 packet — and gets back, for that
input and no other, the decoded message, the ``book_evt_t``, the resulting
``book_top_t``, the ``order_req_t`` decision, and every venue-state transition.

FOUR PROPERTIES THE TESTBENCH DEPENDS ON
----------------------------------------
1. **Deterministic.**  Same inputs, same outputs, always.  No randomness, no
   iteration over an unordered container that reaches an output, no wall clock.
2. **No hidden global state.**  Every mutable thing lives on the instance.  Two
   :class:`GoldenModel` objects in one process share nothing, which is what
   lets a suite run an A-feed model and a B-feed model, or a per-test model,
   without interference.
3. **Never raises on bad input.**  The fast path cannot throw, so neither does
   the oracle.  Malformed input produces a :class:`StepResult` with a status
   and a counter, because "the DUT counted a drop and the model raised" is not
   a comparison.
4. **Everything is inspectable at every point.**  :meth:`GoldenModel.snapshot`
   is a stable, sorted, JSON-able dump of the entire model; two of them diff
   cleanly.

⚠️ WHERE THIS MODEL STOPS
-------------------------
At ``order_req_t``.  The pre-trade risk gate is in hardware and cannot be
bypassed (CLAUDE.md §5.5, host/README.md §3.2).  There is no method here that
returns an order, and there must never be one.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from . import itch_pkg_mirror as itch
from .book import OrderBookModel, SymbolFilter
from .diffing import diff_text, dump_text
from .itch_decode import (
    DecodeStatus,
    ItchMessage,
    MoldPacket,
    decode_message,
    decode_mold_packet,
    side_from_char,
)
from .strategy import StrategyDecision, StrategyModel
from .trading_pkg_mirror import (
    N_SYMBOLS,
    BookEvt,
    BookOp,
    BookTop,
    Side,
    SymStrat,
)
from .venue import StateChange, VenueState

__all__ = ["FeedCounters", "StepResult", "PacketResult", "GoldenModel"]


#: Book ops on which the strategy engine is evaluated.
#: ⚠️ This is the model's reading of the RTL: ``feed_handler`` emits an event
#: for the types in ``itch_pkg::is_book_msg()``, ``book_engine`` publishes a
#: ``book_top_t`` for each, and ``strategy_engine`` evaluates every published
#: top.  ``BOOK_NOP`` events (ITCH 'P' / 'Q') and model-driven ``BOOK_CLEAR``
#: are therefore NOT strategy evaluations — they update the book's last price
#: and its contents but do not represent a fabric ``book_top_valid`` pulse.
#: If the fabric turns out to publish a top for those too, this set is the one
#: line to change.  See the report's CONTRACT-OPEN list.
STRATEGY_EVAL_OPS: frozenset[BookOp] = frozenset(
    {BookOp.ADD, BookOp.EXECUTE, BookOp.CANCEL, BookOp.DELETE, BookOp.REPLACE}
)


@dataclass(slots=True)
class FeedCounters:
    """The counters manuals/04-system-architecture/02-feed-handler-design.md §10
    and manuals/08-nasdaq/04-*.md §9.3 make mandatory, for the parts of the
    pipeline this model covers.

    ⚠️ Two of these are NORMAL and the rest are ERRORS, and they are separate
    counters on purpose.  Conflating "I chose not to look at this"
    (``msgs_filtered``, ``dup_packets``) with "I could not look at this"
    (``drop_len_mismatch``) makes the telemetry useless.
    """

    # volume
    rx_packets: int = 0
    rx_msgs: int = 0
    msgs_filtered: int = 0  # NORMAL: locate not subscribed
    msgs_to_book: int = 0
    heartbeats: int = 0  # NORMAL
    end_of_session: int = 0

    # errors
    drop_malformed: int = 0
    drop_len_mismatch: int = 0
    drop_truncated: int = 0
    unknown_message_type: int = 0  # NOT an error, but counted and alarmed on
    drop_bad_locate: int = 0
    bad_side_char: int = 0
    msgs_after_end_of_messages: int = 0
    packet_blocks_abandoned: int = 0

    # sequencing
    seq_gaps: int = 0
    gap_max_size: int = 0
    dup_packets: int = 0

    messages_by_type: dict[str, int] = field(default_factory=dict)

    #: Sticky first-fault latch (04.02 §10).  A transient that self-clears
    #: between two polls is invisible in a plain counter delta.
    first_error_type: str = ""
    first_error_detail: str = ""
    first_error_msg_index: int = -1

    def note_type(self, type_code: str) -> None:
        self.messages_by_type[type_code] = self.messages_by_type.get(type_code, 0) + 1

    def note_error(self, kind: str, detail: str, msg_index: int) -> None:
        if not self.first_error_type:
            self.first_error_type = kind
            self.first_error_detail = detail
            self.first_error_msg_index = msg_index

    def snapshot(self) -> dict[str, object]:
        return {
            "rx_packets": self.rx_packets,
            "rx_msgs": self.rx_msgs,
            "msgs_filtered": self.msgs_filtered,
            "msgs_to_book": self.msgs_to_book,
            "heartbeats": self.heartbeats,
            "end_of_session": self.end_of_session,
            "drop_malformed": self.drop_malformed,
            "drop_len_mismatch": self.drop_len_mismatch,
            "drop_truncated": self.drop_truncated,
            "unknown_message_type": self.unknown_message_type,
            "drop_bad_locate": self.drop_bad_locate,
            "bad_side_char": self.bad_side_char,
            "msgs_after_end_of_messages": self.msgs_after_end_of_messages,
            "packet_blocks_abandoned": self.packet_blocks_abandoned,
            "seq_gaps": self.seq_gaps,
            "gap_max_size": self.gap_max_size,
            "dup_packets": self.dup_packets,
            "messages_by_type": dict(sorted(self.messages_by_type.items())),
            "first_error_type": self.first_error_type,
            "first_error_detail": self.first_error_detail,
            "first_error_msg_index": self.first_error_msg_index,
        }


@dataclass(frozen=True, slots=True)
class StepResult:
    """Everything one input message produced.  All of it, every time."""

    index: int  # monotonic message index within this model instance
    raw: bytes
    status: DecodeStatus
    message: ItchMessage | None
    #: Decoded fine, but the stock locate is not in the symbol filter.
    #: NORMAL, not an error.
    filtered: bool
    evt: BookEvt | None
    top: BookTop | None
    decision: StrategyDecision | None
    state_changes: tuple[StateChange, ...]
    detail: str = ""

    @property
    def ok(self) -> bool:
        return self.status is DecodeStatus.OK

    @property
    def is_error(self) -> bool:
        return self.status.is_error

    def describe(self) -> str:
        """One line, for a testbench log or an assertion message."""
        head = f"[{self.index}] {self.status.value}"
        if self.message is not None:
            head += (
                f" '{self.message.type_code}' {self.message.name}"
                f" locate={self.message.locate} ts={self.message.timestamp}"
            )
        if self.filtered:
            head += " FILTERED"
        if self.evt is not None:
            head += f" | evt={self.evt.op.name} sym={self.evt.sym}"
        if self.top is not None:
            head += (
                f" | top bid={self.top.bid_px}x{self.top.bid_qty}"
                f" ask={self.top.ask_px}x{self.top.ask_qty}"
                f"{' CROSSED' if self.top.crossed else ''}"
                f"{' STALE' if self.top.stale else ''}"
            )
        if self.decision is not None and self.decision.fired:
            req = self.decision.req
            head += (
                f" | REQ {req.action.name} {req.side.name} {req.qty}@{req.price}"
                f" ({self.decision.reason})"
            )
        if self.detail:
            head += f" | {self.detail}"
        return head


@dataclass(frozen=True, slots=True)
class PacketResult:
    """Everything one MoldUDP64 packet produced."""

    packet: MoldPacket
    results: tuple[StepResult, ...]
    #: Number of MISSING messages detected before this packet.  0 == in order.
    gap: int = 0
    duplicate: bool = False
    #: Non-empty when the remainder of the packet was abandoned, and why.
    abandoned: str = ""

    def describe(self) -> str:
        head = (
            f"packet seq={self.packet.sequence} count={self.packet.count} "
            f"blocks={len(self.packet.blocks)}"
        )
        if self.gap:
            head += f" GAP={self.gap}"
        if self.duplicate:
            head += " DUPLICATE"
        if self.abandoned:
            head += f" ABANDONED({self.abandoned})"
        return "\n".join([head] + ["  " + r.describe() for r in self.results])


class GoldenModel:
    """The verification oracle.  One self-contained instance; no globals."""

    def __init__(
        self,
        *,
        symbols: SymbolFilter | None = None,
        strat: dict[int, SymStrat] | None = None,
        name: str = "golden",
        token_magic: int = 0,
    ) -> None:
        #: ⚠️ The default filter subscribes locates 0..N_ACTIVE-1 with
        #: ``sym == locate``.  That is a TEST convenience.  Production
        #: configuration comes from the ITCH Stock Directory ('R') messages
        #: plus the traded-universe list, and a testbench that cares about the
        #: locate->slot mapping MUST pass its own filter.
        self.symbols = symbols if symbols is not None else SymbolFilter.identity()
        self.book = OrderBookModel()
        self.venue = VenueState()
        self.strategy = StrategyModel(strat, token_magic=token_magic)
        self.counters = FeedCounters()
        self.name = name

        #: MoldUDP64 sequence tracking.  ``None`` means "not yet synchronised";
        #: the first packet seen sets it, which is what a mid-stream join does.
        self.next_expected: int | None = None
        self.session: str = ""

        self._msg_index = 0

    # =========================================================================
    # Stepping
    # =========================================================================

    def step_message(
        self,
        raw: bytes,
        *,
        rx_cycle: int = 0,
        declared_len: int | None = None,
    ) -> StepResult:
        """Feed ONE raw ITCH message.  Never raises.

        ``declared_len`` is the MoldUDP64 block length prefix when the caller
        has one.  Passing it enables the length cross-check, which is free and
        which manuals/08-nasdaq/04-*.md §5 insists on.  Passing ``None`` skips
        that check, which is what you want when driving a bare message that
        never had a framing length.
        """
        index = self._msg_index
        self._msg_index += 1
        self.counters.rx_msgs += 1

        result = decode_message(raw, declared_len)

        if result.status is DecodeStatus.UNKNOWN_TYPE:
            # ⚠️ NOT an error.  Counted, and skipped by its DECLARED length.
            self.counters.unknown_message_type += 1
            self.counters.note_type(result.type_code)
            return StepResult(
                index=index, raw=raw, status=result.status, message=None,
                filtered=False, evt=None, top=None, decision=None,
                state_changes=(), detail=result.detail,
            )

        if result.status is DecodeStatus.LENGTH_MISMATCH:
            self.counters.drop_len_mismatch += 1
            self.counters.note_error("length_mismatch", result.detail, index)
            return StepResult(
                index=index, raw=raw, status=result.status, message=None,
                filtered=False, evt=None, top=None, decision=None,
                state_changes=(), detail=result.detail,
            )

        if result.status is DecodeStatus.TRUNCATED:
            self.counters.drop_truncated += 1
            self.counters.note_error("truncated", result.detail, index)
            return StepResult(
                index=index, raw=raw, status=result.status, message=None,
                filtered=False, evt=None, top=None, decision=None,
                state_changes=(), detail=result.detail,
            )

        if result.status is DecodeStatus.EMPTY:
            self.counters.drop_malformed += 1
            self.counters.note_error("empty_block", result.detail, index)
            return StepResult(
                index=index, raw=raw, status=result.status, message=None,
                filtered=False, evt=None, top=None, decision=None,
                state_changes=(), detail=result.detail,
            )

        assert result.message is not None  # DecodeStatus.OK
        message = result.message
        self.counters.note_type(message.type_code)
        if self.venue.messages_ended:
            # "End of messages: expect no further messages today; alarm if any
            # arrives" (08-nasdaq/04 §8).
            self.counters.msgs_after_end_of_messages += 1

        return self._dispatch(index, raw, message, rx_cycle)

    def step_packet(self, raw: bytes, *, rx_cycle: int = 0) -> PacketResult:
        """Feed ONE MoldUDP64 packet.  Never raises.

        Implements the packet-level policies the RTL is required to implement:

        * sequence tracking against ``SequenceNumber + MessageCount``;
        * a gap marks every subscribed symbol's book STALE and resynchronises
          forward — it never stalls (04.02 §8);
        * a behind-sequence packet is a duplicate, counted, and NOT applied;
        * ⚠️ a length mismatch or an unknown type with no usable length
          ABANDONS THE REST OF THE PACKET, because once the length is wrong the
          read pointer is wrong and every later message in the packet decodes
          from the wrong offset — and it *will* decode (04.02 §6.2).
        """
        self.counters.rx_packets += 1
        packet = decode_mold_packet(raw)

        if packet.malformed:
            self.counters.drop_malformed += 1
            self.counters.note_error("malformed_packet", packet.malformed, self._msg_index)
            if not packet.blocks:
                return PacketResult(
                    packet=packet, results=(), abandoned=packet.malformed
                )

        if not self.session:
            self.session = packet.session

        if packet.is_heartbeat:
            self.counters.heartbeats += 1
            return PacketResult(packet=packet, results=())
        if packet.is_end_of_session:
            self.counters.end_of_session += 1
            return PacketResult(packet=packet, results=())

        # ---- sequence tracking -------------------------------------------
        gap = 0
        duplicate = False
        if self.next_expected is None:
            self.next_expected = packet.sequence
        if packet.sequence < self.next_expected:
            # Already have it.  NORMAL on a redundant A/B feed.
            duplicate = True
            self.counters.dup_packets += 1
            return PacketResult(packet=packet, results=(), duplicate=True)
        if packet.sequence > self.next_expected:
            gap = packet.sequence - self.next_expected
            self.counters.seq_gaps += 1
            self.counters.gap_max_size = max(self.counters.gap_max_size, gap)
            self.counters.note_error(
                "sequence_gap",
                f"expected {self.next_expected}, got {packet.sequence} "
                f"({gap} message(s) missing)",
                self._msg_index,
            )
            # ⚠️ A gap invalidates the book.  ITCH is a pure delta feed with no
            #    periodic snapshot: a missed Add is missing from the book
            #    forever.  Mark every symbol stale and resync FORWARD — never
            #    stall waiting for recovery (04.02 §8).
            self._stale_everything(
                f"MoldUDP64 sequence gap of {gap} at seq {packet.sequence}"
            )
        self.next_expected = packet.next_expected

        # ---- the blocks ---------------------------------------------------
        results: list[StepResult] = []
        abandoned = ""
        for block in packet.blocks:
            step = self.step_message(
                block, rx_cycle=rx_cycle, declared_len=len(block)
            )
            results.append(step)
            if step.status is DecodeStatus.LENGTH_MISMATCH:
                abandoned = (
                    f"length mismatch at message index {step.index}: {step.detail}"
                )
                break
            if step.status.is_error:
                abandoned = f"decode error at message index {step.index}: {step.detail}"
                break
        if abandoned:
            remaining = len(packet.blocks) - len(results)
            self.counters.packet_blocks_abandoned += remaining
            self._stale_everything(f"packet abandoned: {abandoned}")

        return PacketResult(
            packet=packet,
            results=tuple(results),
            gap=gap,
            duplicate=duplicate,
            abandoned=abandoned or packet.malformed,
        )

    def step_messages(
        self, messages: list[bytes] | tuple[bytes, ...], *, rx_cycle: int = 0
    ) -> list[StepResult]:
        """Convenience: feed several bare messages in order."""
        return [self.step_message(m, rx_cycle=rx_cycle) for m in messages]

    # =========================================================================
    # Dispatch: ITCH message -> venue state and/or book_evt_t
    # =========================================================================

    def _dispatch(
        self, index: int, raw: bytes, message: ItchMessage, rx_cycle: int
    ) -> StepResult:
        type_code = message.type_code
        changes: list[StateChange] = []
        detail = ""

        # ---- GLOBAL messages: no locate filtering ------------------------
        if type_code == itch.MSG_SYSTEM_EVENT:
            changes = self.venue.apply_system_event(message.c("event_code"))
            if message.c("event_code") == itch.SYSEV_START_MESSAGES:
                # "Start of messages: reset sequence tracking; clear books."
                self._clear_all_books()
            return self._result(index, raw, message, changes=changes)
        if type_code == itch.MSG_MWCB_STATUS:
            changes = self.venue.apply_mwcb_status(message.c("breached_level"))
            return self._result(index, raw, message, changes=changes)

        # ---- locate -> active-set index ----------------------------------
        locate = message.locate
        if locate >= N_SYMBOLS:
            self.counters.drop_bad_locate += 1
            self.counters.note_error(
                "bad_locate", f"locate {locate} >= N_SYMBOLS {N_SYMBOLS}", index
            )
            return self._result(
                index, raw, message,
                detail=f"stock locate {locate} out of range (N_SYMBOLS={N_SYMBOLS})",
            )
        sym = self.symbols.sym_for(locate)
        if sym is None:
            # NORMAL.  87% or more of every packet is work we should never do.
            self.counters.msgs_filtered += 1
            return self._result(index, raw, message, filtered=True)

        # ---- PER-SYMBOL state messages -----------------------------------
        if type_code == itch.MSG_TRADING_ACTION:
            changes = self.venue.apply_trading_action(
                sym, message.c("trading_state"), message.c("reason")
            )
            return self._result(index, raw, message, changes=changes)
        if type_code == itch.MSG_OPERATIONAL_HALT:
            changes = self.venue.apply_operational_halt(
                sym, message.c("market_code"), message.c("operational_halt_action")
            )
            return self._result(index, raw, message, changes=changes)
        if type_code == itch.MSG_REG_SHO:
            changes = self.venue.apply_reg_sho(sym, message.c("reg_sho_action"))
            return self._result(index, raw, message, changes=changes)
        if type_code == itch.MSG_LULD_COLLAR:
            changes = self.venue.apply_luld_collar(
                sym,
                message.u("auction_collar_reference_price"),
                message.u("upper_auction_collar_price"),
                message.u("lower_auction_collar_price"),
                message.u("auction_collar_extension"),
            )
            return self._result(index, raw, message, changes=changes)

        # ---- BOOK / TAPE messages -----------------------------------------
        evt = self._build_event(message, sym, locate, rx_cycle)
        if evt is None:
            # 'R', 'L', 'V', 'K', 'B', 'I', 'N' — reference data and slow-path
            # statistics.  No book effect, no state effect modelled here.
            return self._result(index, raw, message, detail=detail)

        self.counters.msgs_to_book += 1
        top = self.book.apply(evt)
        decision: StrategyDecision | None = None
        if evt.op in STRATEGY_EVAL_OPS:
            decision = self.strategy.evaluate(top, self.venue)
        return self._result(
            index, raw, message, evt=evt, top=top, decision=decision, detail=detail
        )

    def _build_event(
        self, message: ItchMessage, sym: int, locate: int, rx_cycle: int
    ) -> BookEvt | None:
        """ITCH message -> ``book_evt_t``.  THE decoder/book contract, in one place.

        ⚠️ Read the ``price`` column carefully; it is where books go wrong:

        ==== ============ ============================ ==================
        Type op           price carries                printable
        ==== ============ ============================ ==================
        A/F  ADD          the RESTING price            False
        E    EXECUTE      0 (the wire has no price)    True
        C    EXECUTE      the EXECUTION price, TAPE    from the flag
                          ONLY — the book locates the
                          level by the STORED price
        X    CANCEL       0                            False
        D    DELETE       0                            False
        U    REPLACE      the NEW resting price        False
        P    NOP          the trade price, TAPE ONLY   True
        Q    NOP          the cross price, TAPE ONLY   True
        ==== ============ ============================ ==================
        """
        type_code = message.type_code

        if type_code in (itch.MSG_ADD_ORDER, itch.MSG_ADD_ORDER_MPID):
            side_char = message.c("buy_sell_indicator")
            if side_char not in (itch.SIDE_CHAR_BUY, itch.SIDE_CHAR_SELL):
                self.counters.bad_side_char += 1
            return self._evt(
                BookOp.ADD, message, sym, locate, rx_cycle,
                side=side_from_char(side_char),
                price=message.u("price"),
                qty=message.u("shares"),
                order_ref=message.u("order_reference_number"),
            )

        if type_code == itch.MSG_ORDER_EXECUTED:
            return self._evt(
                BookOp.EXECUTE, message, sym, locate, rx_cycle,
                # No price on the wire.  The book uses the order's stored
                # resting price, for the level AND for the tape.
                price=0,
                qty=message.u("executed_shares"),
                order_ref=message.u("order_reference_number"),
                printable=True,
            )

        if type_code == itch.MSG_ORDER_EXEC_PRICE:
            printable = message.c("printable") == "Y"
            return self._evt(
                BookOp.EXECUTE, message, sym, locate, rx_cycle,
                # ⚠️ TAPE ONLY.  book.py never uses this to locate a level.
                price=message.u("execution_price"),
                qty=message.u("executed_shares"),
                order_ref=message.u("order_reference_number"),
                # ⚠️ printable='N' still applies to the BOOK.  It only
                #    suppresses the tape print / last price.
                printable=printable,
            )

        if type_code == itch.MSG_ORDER_CANCEL:
            return self._evt(
                BookOp.CANCEL, message, sym, locate, rx_cycle,
                qty=message.u("cancelled_shares"),
                order_ref=message.u("order_reference_number"),
            )

        if type_code == itch.MSG_ORDER_DELETE:
            return self._evt(
                BookOp.DELETE, message, sym, locate, rx_cycle,
                order_ref=message.u("order_reference_number"),
            )

        if type_code == itch.MSG_ORDER_REPLACE:
            return self._evt(
                BookOp.REPLACE, message, sym, locate, rx_cycle,
                price=message.u("price"),
                qty=message.u("shares"),
                order_ref=message.u("original_order_reference_number"),
                new_order_ref=message.u("new_order_reference_number"),
            )

        if type_code == itch.MSG_TRADE:
            # ⚠️ NO BOOK EFFECT.  Applying 'P' to the book corrupts it.
            side_char = message.c("buy_sell_indicator")
            return self._evt(
                BookOp.NOP, message, sym, locate, rx_cycle,
                side=side_from_char(side_char),
                price=message.u("price"),
                qty=message.u("shares"),
                order_ref=message.u("order_reference_number"),
                printable=True,
            )

        if type_code == itch.MSG_CROSS_TRADE:
            return self._evt(
                BookOp.NOP, message, sym, locate, rx_cycle,
                price=message.u("cross_price"),
                qty=message.u("shares"),
                printable=True,
            )

        return None

    @staticmethod
    def _evt(
        op: BookOp,
        message: ItchMessage,
        sym: int,
        locate: int,
        rx_cycle: int,
        *,
        side: Side = Side.BUY,
        price: int = 0,
        qty: int = 0,
        order_ref: int = 0,
        new_order_ref: int = 0,
        printable: bool = False,
    ) -> BookEvt:
        return BookEvt(
            op=op,
            sym=sym,
            locate=locate,
            side=side,
            price=price,
            qty=qty,
            order_ref=order_ref,
            new_order_ref=new_order_ref,
            exch_ts=message.timestamp,
            rx_cycle=rx_cycle,
            printable=printable,
        )

    def _result(
        self,
        index: int,
        raw: bytes,
        message: ItchMessage | None,
        *,
        filtered: bool = False,
        evt: BookEvt | None = None,
        top: BookTop | None = None,
        decision: StrategyDecision | None = None,
        changes: list[StateChange] | None = None,
        detail: str = "",
    ) -> StepResult:
        return StepResult(
            index=index,
            raw=raw,
            status=DecodeStatus.OK,
            message=message,
            filtered=filtered,
            evt=evt,
            top=top,
            decision=decision,
            state_changes=tuple(changes or ()),
            detail=detail,
        )

    # =========================================================================
    # Control surface — mirrors the host's register writes
    # =========================================================================

    def set_strat(self, sym: int, params: SymStrat) -> None:
        """Mirror of a committed ``PARAM_STRAT_*`` bank write."""
        self.strategy.set_params(sym, params)

    def strat_params(self, sym: int) -> SymStrat:
        return self.strategy.get_params(sym)

    def subscribe(self, locate: int, sym: int) -> None:
        """Mirror of a ``PARAM_FILTER_*`` write: locate -> active-set index."""
        self.symbols.subscribe(locate, sym)

    def clear_stale(self, sym: int) -> None:
        """Per-symbol, explicit, after a verified resync.  ⚠️ There is no
        ``clear_all_stale``, deliberately (04.03 §9.2)."""
        self.book.clear_stale(sym)

    def mark_stale(self, sym: int, reason: str) -> None:
        self.book.mark_stale(sym, reason)

    def clear_book(self, sym: int, *, rx_cycle: int = 0) -> BookTop:
        """Apply a synthetic ``BOOK_CLEAR`` — resync or start of day.

        ⚠️ This clears the book CONTENTS.  It does NOT clear the stale bit; the
        host clears that separately, per symbol, after verifying the rebuilt
        book against this model (04.03 §9.2 steps 6-7).
        """
        evt = BookEvt(
            op=BookOp.CLEAR, sym=sym, locate=0, side=Side.BUY, price=0, qty=0,
            order_ref=0, new_order_ref=0, exch_ts=0, rx_cycle=rx_cycle,
            printable=False,
        )
        return self.book.apply(evt)

    def _clear_all_books(self) -> None:
        for sym in list(self.book.books):
            self.clear_book(sym)

    def _stale_everything(self, reason: str) -> None:
        """A channel-level fault stales every symbol on the channel."""
        for locate in self.symbols.subscribed_locates():
            sym = self.symbols.sym_for(locate)
            if sym is not None:
                self.book.mark_stale(sym, reason)

    def reset_sequence(self, sequence: int | None = None) -> None:
        """Re-arm MoldUDP64 sequence tracking (after a host-side recovery)."""
        self.next_expected = sequence

    # -- fill / ack feedback, forwarded to the strategy ---------------------

    def on_fill(self, sym: int, side: Side, qty: int, price: int = 0) -> None:
        self.strategy.on_fill(sym, side, qty, price)

    def on_terminal_ack(self, sym: int) -> None:
        self.strategy.on_terminal_ack(sym)

    def on_cancel_ack(self, sym: int, token: int) -> None:
        self.strategy.on_cancel_ack(sym, token)

    # =========================================================================
    # Inspection
    # =========================================================================

    def top(self, sym: int) -> BookTop:
        """Current ``book_top_t`` without applying anything."""
        return self.book.top(sym)

    def depth(self, sym: int, side: Side, levels: int = 16) -> list[tuple[int, int, int]]:
        """``[(price, qty, order_count), ...]``, best first."""
        return self.book.depth(sym, side, levels)

    def snapshot(self) -> dict[str, object]:
        """Complete, stable, JSON-able model state.  Two of these diff cleanly."""
        return {
            "name": self.name,
            "messages_seen": self._msg_index,
            "session": self.session,
            "next_expected": self.next_expected,
            "feed": self.counters.snapshot(),
            "venue": self.venue.snapshot(),
            "book": self.book.snapshot(),
            "strategy": self.strategy.snapshot(),
            "symbol_filter": {str(k): v for k, v in self.symbols.snapshot().items()},
        }

    def dump_text(self) -> str:
        """The snapshot as stable, sorted, diffable text."""
        return dump_text(self.snapshot())

    def diff_against(self, other: GoldenModel | dict[str, object] | str) -> str:
        """Unified diff of this model's state against another model or dump."""
        right = other.snapshot() if isinstance(other, GoldenModel) else other
        right_name = other.name if isinstance(other, GoldenModel) else "other"
        return diff_text(
            self.snapshot(), right, left_name=self.name, right_name=right_name
        )
