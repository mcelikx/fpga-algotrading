"""strategy.py — the golden strategy model (``sym_strat_t`` -> ``order_req_t``).

OPTIMIZED FOR OBVIOUS CORRECTNESS, NOT FOR SPEED.

⚠️ THIS MODEL NEVER EMITS ANYTHING.  It produces ``order_req_t`` values — a
*request*, which the hardware risk gate may reject.  host/README.md §3.2: "The
host never bypasses the risk gate. There is no software path that emits an
order."  There is deliberately no method on this class that returns bytes, a
socket, or an ``order_out_t``.

WHAT IS AND IS NOT MODELLED
---------------------------
``trading_pkg::sym_strat_t`` has SEVEN parameters:

    strat_enabled, strat_select, quote_qty, edge_ticks,
    min_book_qty, fair_value, imbalance_thr

manuals/04-system-architecture/04-strategy-engine-on-fpga.md §3 describes a
much larger 256-bit parameter row (``px_offset_bid``, ``skew``, ``min_spread``,
``max_spread``, ``cooldown``, ``side_mask``, ``tif`` ...).  **This model
implements exactly the seven fields that exist in the RTL contract and nothing
else.**  Where the manual's primitive needs a parameter ``sym_strat_t`` does not
carry, the substitution is stated in that primitive's docstring.  Inventing a
parameter would make the oracle disagree with the fabric for a reason that is
not in either specification.

⚠️ COMPARISON DIRECTION IS PINNED, ON PURPOSE
---------------------------------------------
Manual §12.3: "`>` versus `>=` on `edge_ticks` is the difference between two
different strategies, and only one of them was approved."  This model uses
**"at or through" (>= / <=) everywhere**, i.e. a touch exactly ``edge_ticks``
away from fair value FIRES.  Every comparison below is written with that
convention and marked.  If the fabric disagrees, that is a one-line difference
and this paragraph is where the conversation starts.

NO FLOATS.  The imbalance ratio is Q8.8 fixed point and is evaluated by
cross-multiplication, never by division.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from .trading_pkg_mirror import (
    TICK_ITCH_UNITS,
    Action,
    BookTop,
    OrderReq,
    OrderToken,
    Side,
    SymStrat,
    TradeState,
    pack_order_token,
)
from .venue import VenueState

__all__ = [
    "Primitive",
    "StrategyState",
    "StrategyCounters",
    "StrategyDecision",
    "StrategyModel",
    "IMBALANCE_ONE",
]

#: ``sym_strat_t.imbalance_thr`` is a Q8.8 ratio: 256 == 1.0 (manual §3).
IMBALANCE_ONE = 256


class Primitive:
    """``sym_strat_t.strat_select`` values, per manual §6's ``prim_id`` table.

    Plain ints rather than an ``IntEnum`` because the RTL field is a bare
    ``logic [3:0]`` with no enum in ``trading_pkg.sv`` to mirror; inventing one
    here would be a contract this model made up.
    """

    NULL = 0  # never fires
    QUOTE = 1  # maintain a resting two-sided quote
    TAKE = 2  # cross the spread when the touch is through fair value
    FADE = 3  # cancel a resting order when the book moves against it
    JOIN = 4  # rest at the touch when the touch is thick enough
    IMBAL = 5  # act on a bid/ask quantity imbalance
    # 6, 7 and 8..15: reserved.  Reserved means NEVER FIRE, and it is counted.

    NAMES: dict[int, str] = {
        NULL: "null",
        QUOTE: "quote",
        TAKE: "take",
        FADE: "fade",
        JOIN: "join",
        IMBAL: "imbal",
    }


@dataclass(slots=True)
class StrategyState:
    """``my_state[slot]`` — OUR state, as opposed to the market's (manual §8)."""

    position: int = 0  # signed shares.  Long positive, short negative.
    #: ⚠️ Set on send, cleared on a terminal ack/fill.  Without it the strategy
    #: fires again on every book update until the ack lands — one order per
    #: update — which is the classic runaway (manual §8).  This is defence #1
    #: of three; defence #3 (the hardware rate limiter in the risk gate) is not
    #: modelled here because it lives in a block this one cannot influence.
    pending: bool = False
    resting_bid_token: int = 0  # 0 == none
    resting_bid_px: int = 0
    resting_bid_qty: int = 0
    resting_ask_token: int = 0
    resting_ask_px: int = 0
    resting_ask_qty: int = 0
    last_action_cycle: int = 0


@dataclass(slots=True)
class StrategyCounters:
    evaluations: int = 0
    fires: int = 0
    fires_by_primitive: dict[int, int] = field(default_factory=dict)
    #: Why an evaluation did NOT fire.  This is the single most useful thing in
    #: the whole model when the fabric fires and the model does not: it names
    #: the gate, immediately, instead of leaving you to bisect the parameters.
    gated_by: dict[str, int] = field(default_factory=dict)

    def note_gate(self, reason: str) -> None:
        self.gated_by[reason] = self.gated_by.get(reason, 0) + 1

    def note_fire(self, primitive: int) -> None:
        self.fires += 1
        self.fires_by_primitive[primitive] = (
            self.fires_by_primitive.get(primitive, 0) + 1
        )

    def snapshot(self) -> dict[str, object]:
        return {
            "evaluations": self.evaluations,
            "fires": self.fires,
            "fires_by_primitive": {
                Primitive.NAMES.get(k, f"prim{k}"): v
                for k, v in sorted(self.fires_by_primitive.items())
            },
            "gated_by": dict(sorted(self.gated_by.items())),
        }


@dataclass(frozen=True, slots=True)
class StrategyDecision:
    """One evaluation's result.

    ``req`` is ALWAYS present.  ``Action.NONE`` is the overwhelmingly common
    answer and it takes exactly the same path as a fire — manual §2: "`NONE`
    must cost exactly the same as `BUY`".  Modelling it as ``None`` would let a
    testbench accidentally skip the no-trade case.
    """

    req: OrderReq
    #: A one-line, human-readable explanation.  Present for BOTH outcomes.
    reason: str
    #: The gate that blocked, or ``""`` when nothing blocked.
    gate: str = ""

    @property
    def fired(self) -> bool:
        return self.req.action is not Action.NONE


def _none_req(sym: int, rx_cycle: int) -> OrderReq:
    return OrderReq(
        action=Action.NONE,
        sym=sym,
        side=Side.BUY,  # don't-care; zero-equivalent
        price=0,
        qty=0,
        post_only=False,
        is_short=False,
        strat_id=0,
        cancel_token=0,
        rx_cycle=rx_cycle,
    )


class StrategyModel:
    """The strategy engine as a pure function of (book_top, my_state, params).

    One instance per :class:`~host.pymodel.model.GoldenModel`.  No globals.
    """

    def __init__(
        self,
        params: dict[int, SymStrat] | None = None,
        *,
        token_magic: int = 0,
        token_counter_start: int = 0,
    ) -> None:
        self.params: dict[int, SymStrat] = dict(params or {})
        self.state: dict[int, StrategyState] = {}
        self.counters = StrategyCounters()
        # Token generation mirrors ``order_token_t`` so a testbench can compare
        # shapes.  ⚠️ The REAL assigner is the risk gate (``order_out_t.token``);
        # the strategy only ever quotes a token it already holds, in
        # ``order_req_t.cancel_token``.
        self._token_magic = token_magic
        self._token_counter = token_counter_start

    # -- parameters ---------------------------------------------------------

    def set_params(self, sym: int, params: SymStrat) -> None:
        """Mirror of a committed parameter-bank write.

        The fabric's double-buffered commit is atomic per symbol (manual §5);
        so is this, trivially, because a dataclass assignment is one operation.
        The torn-read bug the RTL has to defend against cannot occur here,
        which is exactly why the oracle can be trusted to say the fabric tore.
        """
        self.params[sym] = params

    def get_params(self, sym: int) -> SymStrat:
        return self.params.get(sym, SymStrat())

    def sym_state(self, sym: int) -> StrategyState:
        st = self.state.get(sym)
        if st is None:
            st = StrategyState()
            self.state[sym] = st
        return st

    # -- fill / ack feedback -----------------------------------------------

    def on_fill(self, sym: int, side: Side, qty: int, price: int = 0) -> None:
        """Mirror of the ``fill_*`` feedback path in ``fpga_top.sv``."""
        st = self.sym_state(sym)
        st.position += qty if side is Side.BUY else -qty
        st.pending = False
        if side is Side.BUY and st.resting_bid_token:
            st.resting_bid_qty = max(0, st.resting_bid_qty - qty)
            if st.resting_bid_qty == 0:
                st.resting_bid_token = 0
                st.resting_bid_px = 0
        if side is Side.SELL and st.resting_ask_token:
            st.resting_ask_qty = max(0, st.resting_ask_qty - qty)
            if st.resting_ask_qty == 0:
                st.resting_ask_token = 0
                st.resting_ask_px = 0

    def on_terminal_ack(self, sym: int) -> None:
        """Clear ``pending`` on any terminal outcome (ack, reject, cancel-ack)."""
        self.sym_state(sym).pending = False

    def on_cancel_ack(self, sym: int, token: int) -> None:
        st = self.sym_state(sym)
        st.pending = False
        if token and token == st.resting_bid_token:
            st.resting_bid_token = 0
            st.resting_bid_px = 0
            st.resting_bid_qty = 0
        if token and token == st.resting_ask_token:
            st.resting_ask_token = 0
            st.resting_ask_px = 0
            st.resting_ask_qty = 0

    # -- the evaluation -----------------------------------------------------

    def evaluate(self, top: BookTop, venue: VenueState) -> StrategyDecision:
        """Evaluate one ``book_top_t`` against the parameters and our state.

        THE GATE IS EVALUATED FIRST, IN A FIXED ORDER, AND EVERY BLOCKED
        EVALUATION NAMES THE GATE THAT BLOCKED IT.
        """
        self.counters.evaluations += 1
        sym = top.sym
        params = self.get_params(sym)
        st = self.sym_state(sym)
        none = _none_req(sym, top.rx_cycle)

        def blocked(gate: str, detail: str = "") -> StrategyDecision:
            self.counters.note_gate(gate)
            return StrategyDecision(
                req=none, reason=f"gated: {gate}" + (f" ({detail})" if detail else ""),
                gate=gate,
            )

        # --- GATING (manual §10; fpga_top.sv top-level assertions) ---------
        # ⚠️ ORDER MATTERS ONLY FOR THE DIAGNOSTIC.  All of these are ANDed in
        #    one cycle in the fabric; here the first failure names itself.
        if not params.strat_enabled:
            return blocked("strat_disabled")

        # ⚠️ fpga_top.sv:
        #    assert property ((book_top_valid && book_top.stale) |=> !order_req_valid)
        #    "We do not trade a stale book. Ever."  (04.02 §8)
        if top.stale:
            return blocked("book_stale")

        # ⚠️ fpga_top.sv:
        #    assert property ((book_top_valid && book_top.crossed) |=> !order_req_valid)
        if top.crossed:
            return blocked(
                "book_crossed", f"bid={top.bid_px} >= ask={top.ask_px}"
            )

        state = venue.effective_state(sym)
        if state is not TradeState.OPEN:
            # ⚠️ ONLY TRADE_OPEN QUOTES.  Everything else — CLOSED, PREOPEN,
            #    HALTED, PAUSED, AUCTION, STALE, DISABLED — is a no.
            return blocked("not_open", state.name)

        if st.pending:
            return blocked("pending")

        if params.quote_qty == 0:
            # A zero-size order is RISK_ZERO_QTY downstream; do not form one.
            return blocked("zero_quote_qty")

        # --- PRIMITIVE SELECTION -------------------------------------------
        select = params.strat_select
        if select == Primitive.NULL:
            return blocked("prim_null")
        if select == Primitive.QUOTE:
            decision = self._prim_quote(top, params, st)
        elif select == Primitive.TAKE:
            decision = self._prim_take(top, params, st)
        elif select == Primitive.FADE:
            decision = self._prim_fade(top, params, st)
        elif select == Primitive.JOIN:
            decision = self._prim_join(top, params, st)
        elif select == Primitive.IMBAL:
            decision = self._prim_imbal(top, params, st)
        else:
            # Reserved prim_id.  ⚠️ Reserved means never fire, and it is counted
            # — a symbol pointed at a reserved primitive is a configuration
            # error that must be visible, not a silent no-op.
            return blocked("prim_reserved", f"strat_select={select}")

        if decision.fired:
            self.counters.note_fire(select)
            st.pending = True
            st.last_action_cycle = top.rx_cycle
            self._record_resting(st, decision.req)
        else:
            self.counters.note_gate(decision.gate or "no_signal")
        return decision

    # -- primitives ---------------------------------------------------------
    # Each is a handful of integer comparisons.  No loops, no state beyond
    # ``my_state``, no arithmetic wider than one multiply — the same shape as
    # the fabric's comparator bank (manual §2), just written out longhand.

    def _edge(self, params: SymStrat) -> int:
        """``edge_ticks`` converted to ITCH price units.  One tick = $0.01."""
        return params.edge_ticks * TICK_ITCH_UNITS

    def _prim_quote(
        self, top: BookTop, params: SymStrat, st: StrategyState
    ) -> StrategyDecision:
        """prim_quote — maintain a resting two-sided quote, ``edge_ticks`` off
        the touch.

        SUBSTITUTION: manual §6 uses ``px_offset_bid`` / ``px_offset_ask`` for
        the placement offset.  ``sym_strat_t`` has no such field, so
        ``edge_ticks`` is used as the (symmetric) offset.  There is no
        inventory ``skew`` field either, so the quote is not skewed.

        ⚠️ ``order_req_t`` carries ONE order.  A two-sided quote therefore takes
        two evaluations.  The side chosen is deterministic: **the bid first, the
        ask only once a bid is resting.**  Any other rule would make the
        decision stream depend on evaluation history in a way the fabric's
        single-cycle comparator bank cannot reproduce.
        """
        if not (top.bid_valid and top.ask_valid):
            return StrategyDecision(
                _none_req(top.sym, top.rx_cycle), "quote: one-sided book", "one_sided"
            )
        # "don't act on a thin book" — >= is the pinned direction.
        if top.bid_qty < params.min_book_qty or top.ask_qty < params.min_book_qty:
            return StrategyDecision(
                _none_req(top.sym, top.rx_cycle),
                f"quote: thin book (bid_qty={top.bid_qty} ask_qty={top.ask_qty} "
                f"min={params.min_book_qty})",
                "thin_book",
            )
        edge = self._edge(params)
        if st.resting_bid_token == 0:
            price = top.bid_px - edge
            if price <= 0:
                return StrategyDecision(
                    _none_req(top.sym, top.rx_cycle),
                    "quote: bid price would be <= 0",
                    "zero_price",
                )
            return self._send(
                top, params, st, Side.BUY, price, params.quote_qty,
                Primitive.QUOTE, post_only=True,
                reason=f"quote: rest bid at {top.bid_px}-{edge}",
            )
        if st.resting_ask_token == 0:
            price = top.ask_px + edge
            return self._send(
                top, params, st, Side.SELL, price, params.quote_qty,
                Primitive.QUOTE, post_only=True,
                reason=f"quote: rest ask at {top.ask_px}+{edge}",
            )
        return StrategyDecision(
            _none_req(top.sym, top.rx_cycle), "quote: both sides already resting",
            "already_resting",
        )

    def _prim_take(
        self, top: BookTop, params: SymStrat, st: StrategyState
    ) -> StrategyDecision:
        """prim_take — cross the spread when the touch is through fair value.

        ⚠️ COMPARISON DIRECTION (pinned, see the module docstring):
            BUY  when  ask_px <= fair_value - edge      ("at or through")
            SELL when  bid_px >= fair_value + edge
        """
        if params.fair_value == 0:
            return StrategyDecision(
                _none_req(top.sym, top.rx_cycle),
                "take: fair_value is 0 (host has not written it)",
                "no_fair_value",
            )
        edge = self._edge(params)
        if top.ask_valid and top.ask_qty >= params.min_book_qty:
            if top.ask_px <= params.fair_value - edge:
                return self._send(
                    top, params, st, Side.BUY, top.ask_px, params.quote_qty,
                    Primitive.TAKE, post_only=False,
                    reason=(
                        f"take: ask {top.ask_px} <= fair {params.fair_value} "
                        f"- edge {edge}"
                    ),
                )
        if top.bid_valid and top.bid_qty >= params.min_book_qty:
            if top.bid_px >= params.fair_value + edge:
                return self._send(
                    top, params, st, Side.SELL, top.bid_px, params.quote_qty,
                    Primitive.TAKE, post_only=False,
                    reason=(
                        f"take: bid {top.bid_px} >= fair {params.fair_value} "
                        f"+ edge {edge}"
                    ),
                )
        return StrategyDecision(
            _none_req(top.sym, top.rx_cycle), "take: touch not through the edge",
            "no_edge",
        )

    def _prim_fade(
        self, top: BookTop, params: SymStrat, st: StrategyState
    ) -> StrategyDecision:
        """prim_fade — cancel a resting order once the book has moved against it
        by ``edge_ticks``.

        ⚠️ This is the only primitive that produces ``ACT_CANCEL``, and it is
        the only one that reads ``cancel_token``.  A cancel with a token of 0
        is a bug, not a no-op, so the guard is explicit.
        """
        edge = self._edge(params)
        if st.resting_bid_token and top.bid_valid:
            # Our bid is stale if the market's best bid has fallen to or below
            # our price minus the edge.
            if top.bid_px <= st.resting_bid_px - edge:
                return self._cancel(
                    top, st.resting_bid_token, Side.BUY, Primitive.FADE,
                    reason=(
                        f"fade: best bid {top.bid_px} <= our {st.resting_bid_px} "
                        f"- edge {edge}"
                    ),
                )
        if st.resting_ask_token and top.ask_valid:
            if top.ask_px >= st.resting_ask_px + edge:
                return self._cancel(
                    top, st.resting_ask_token, Side.SELL, Primitive.FADE,
                    reason=(
                        f"fade: best ask {top.ask_px} >= our {st.resting_ask_px} "
                        f"+ edge {edge}"
                    ),
                )
        return StrategyDecision(
            _none_req(top.sym, top.rx_cycle), "fade: nothing to pull", "no_fade"
        )

    def _prim_join(
        self, top: BookTop, params: SymStrat, st: StrategyState
    ) -> StrategyDecision:
        """prim_join — rest AT the touch, but only when the touch is thick
        enough to be worth queueing behind.

        SUBSTITUTION: manual §6 uses ``join_qty``; ``sym_strat_t`` calls the
        same idea ``min_book_qty``.
        """
        if top.bid_valid and st.resting_bid_token == 0:
            if top.bid_qty >= params.min_book_qty:  # pinned: >= joins
                return self._send(
                    top, params, st, Side.BUY, top.bid_px, params.quote_qty,
                    Primitive.JOIN, post_only=True,
                    reason=(
                        f"join: bid_qty {top.bid_qty} >= min {params.min_book_qty}"
                    ),
                )
        if top.ask_valid and st.resting_ask_token == 0:
            if top.ask_qty >= params.min_book_qty:
                return self._send(
                    top, params, st, Side.SELL, top.ask_px, params.quote_qty,
                    Primitive.JOIN, post_only=True,
                    reason=(
                        f"join: ask_qty {top.ask_qty} >= min {params.min_book_qty}"
                    ),
                )
        return StrategyDecision(
            _none_req(top.sym, top.rx_cycle), "join: touch too thin or already resting",
            "no_join",
        )

    def _prim_imbal(
        self, top: BookTop, params: SymStrat, st: StrategyState
    ) -> StrategyDecision:
        """prim_imbal — act when the bid/ask quantity ratio crosses
        ``imbalance_thr`` (Q8.8, 256 == 1.0).

        ⚠️ NO DIVISION.  ``bid_qty / ask_qty >= thr/256`` is evaluated as
        ``bid_qty * 256 >= ask_qty * thr``.  A divider on the fast path is
        forbidden (CLAUDE.md §5) and a division here would also introduce a
        rounding rule the fabric does not have.
        """
        if not (top.bid_valid and top.ask_valid):
            return StrategyDecision(
                _none_req(top.sym, top.rx_cycle), "imbal: one-sided book", "one_sided"
            )
        if params.imbalance_thr == 0:
            return StrategyDecision(
                _none_req(top.sym, top.rx_cycle), "imbal: threshold is 0", "no_threshold"
            )
        if top.bid_qty < params.min_book_qty and top.ask_qty < params.min_book_qty:
            return StrategyDecision(
                _none_req(top.sym, top.rx_cycle), "imbal: thin book", "thin_book"
            )
        # Buy pressure: many more bid shares than ask shares.
        if top.bid_qty * IMBALANCE_ONE >= top.ask_qty * params.imbalance_thr:
            return self._send(
                top, params, st, Side.BUY, top.ask_px, params.quote_qty,
                Primitive.IMBAL, post_only=False,
                reason=(
                    f"imbal: bid {top.bid_qty} * 256 >= ask {top.ask_qty} * "
                    f"thr {params.imbalance_thr}"
                ),
            )
        # Sell pressure: the mirror image.
        if top.ask_qty * IMBALANCE_ONE >= top.bid_qty * params.imbalance_thr:
            return self._send(
                top, params, st, Side.SELL, top.bid_px, params.quote_qty,
                Primitive.IMBAL, post_only=False,
                reason=(
                    f"imbal: ask {top.ask_qty} * 256 >= bid {top.bid_qty} * "
                    f"thr {params.imbalance_thr}"
                ),
            )
        return StrategyDecision(
            _none_req(top.sym, top.rx_cycle), "imbal: balanced", "balanced"
        )

    # -- request formation --------------------------------------------------

    def _send(
        self,
        top: BookTop,
        params: SymStrat,
        st: StrategyState,
        side: Side,
        price: int,
        qty: int,
        primitive: int,
        *,
        post_only: bool,
        reason: str,
    ) -> StrategyDecision:
        # A sell that takes us short (or deeper short) is a short sale, which
        # triggers the Reg SHO Rule 201 check in the risk gate.
        is_short = side is Side.SELL and (st.position - qty) < 0
        req = OrderReq(
            action=Action.SEND,
            sym=top.sym,
            side=side,
            price=price,
            qty=qty,
            post_only=post_only,
            is_short=is_short,
            strat_id=primitive,
            cancel_token=0,
            rx_cycle=top.rx_cycle,
        )
        return StrategyDecision(req=req, reason=reason)

    def _cancel(
        self,
        top: BookTop,
        token: int,
        side: Side,
        primitive: int,
        *,
        reason: str,
    ) -> StrategyDecision:
        req = OrderReq(
            action=Action.CANCEL,
            sym=top.sym,
            side=side,
            price=0,
            qty=0,
            post_only=False,
            is_short=False,
            strat_id=primitive,
            cancel_token=token,
            rx_cycle=top.rx_cycle,
        )
        return StrategyDecision(req=req, reason=reason)

    def _next_token(self, sym: int, strat_id: int) -> int:
        self._token_counter += 1
        return pack_order_token(
            OrderToken(
                magic=self._token_magic,
                strat_id=strat_id & 0xF,
                sym=sym & 0xFFF,
                counter=self._token_counter,
                rsvd=0,
            )
        )

    def _record_resting(self, st: StrategyState, req: OrderReq) -> None:
        """Track what we believe is resting, so ``prim_fade`` has something to pull.

        ⚠️ MODELLING NOTE.  The fabric learns its resting orders from OUCH acks
        arriving back through ``order_gateway``.  This model assumes the SEND is
        accepted, because it has no ack stream.  A testbench that drives fills
        and rejects through :meth:`on_fill` / :meth:`on_terminal_ack` gets the
        same answer; one that does not will see the model believe in orders the
        fabric knows were rejected.  Say so in any mismatch report before
        blaming the RTL.
        """
        if req.action is not Action.SEND:
            return
        token = self._next_token(req.sym, req.strat_id)
        if req.side is Side.BUY:
            st.resting_bid_token = token
            st.resting_bid_px = req.price
            st.resting_bid_qty = req.qty
        else:
            st.resting_ask_token = token
            st.resting_ask_px = req.price
            st.resting_ask_qty = req.qty

    # -- dump ---------------------------------------------------------------

    def snapshot(self) -> dict[str, object]:
        return {
            "counters": self.counters.snapshot(),
            "params": {
                str(sym): {
                    "strat_enabled": p.strat_enabled,
                    "strat_select": p.strat_select,
                    "quote_qty": p.quote_qty,
                    "edge_ticks": p.edge_ticks,
                    "min_book_qty": p.min_book_qty,
                    "fair_value": p.fair_value,
                    "imbalance_thr": p.imbalance_thr,
                }
                for sym, p in sorted(self.params.items())
            },
            "state": {
                str(sym): {
                    "position": s.position,
                    "pending": s.pending,
                    "resting_bid_px": s.resting_bid_px,
                    "resting_bid_qty": s.resting_bid_qty,
                    "resting_ask_px": s.resting_ask_px,
                    "resting_ask_qty": s.resting_ask_qty,
                    "last_action_cycle": s.last_action_cycle,
                }
                for sym, s in sorted(self.state.items())
            },
        }
