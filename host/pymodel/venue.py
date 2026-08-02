"""venue.py — the per-symbol trading-state model (``trade_state_e``).

OPTIMIZED FOR OBVIOUS CORRECTNESS, NOT FOR SPEED.

This is the model of the venue-state side-channel that ``feed_handler`` writes
in ``rtl/fpga_top.sv`` (``sess_state``, ``sym_state_*``, ``sym_ssr_val``,
``sym_luld_*``) and that both the strategy engine and — independently — the
risk gate consume.

⚠️ FROM manuals/04-system-architecture/04-strategy-engine-on-fpga.md §10:
"the mapping from ITCH `H` trading-action codes, `S` system-event codes, and
`Y` Reg SHO states onto these bits is venue semantics, not design choice. Take
it from the Nasdaq spec and the Reg SHO / LULD rules. **Getting a halt code
inverted is a compliance event, not a bug.**"  Every mapping below therefore
names the code it came from and carries a TODO(verify) where the mapping is an
interpretation rather than a transcription.

⚠️ EVERY GATE DEFAULTS TO BLOCKING.  The reset value of ``trade_state_e`` is
``TRADE_DISABLED``, and this model starts there.  A model that starts in
``TRADE_OPEN`` would let a testbench pass a strategy that trades before the
session has opened.
"""

from __future__ import annotations

from dataclasses import dataclass

from . import itch_pkg_mirror as itch
from .trading_pkg_mirror import TradeState

__all__ = ["StateChange", "SymbolVenueState", "VenueState"]


@dataclass(frozen=True, slots=True)
class StateChange:
    """One observable venue-state transition, for the step result and for dumps."""

    scope: str  # "session" | "symbol"
    sym: int | None
    what: str  # "trade_state" | "ssr" | "luld" | "mwcb"
    old: object
    new: object
    cause: str  # the ITCH message that caused it, e.g. "H:'H'"


@dataclass(slots=True)
class SymbolVenueState:
    """Per-symbol venue state.  All of it comes off the ITCH feed."""

    #: From ITCH 'H' (Stock Trading Action).  ``None`` means "no per-symbol
    #: override in force", i.e. follow the global session state.
    trading_action: TradeState | None = None
    #: From ITCH 'h' (Operational Halt).  ⚠️ lower-case 'h' and upper-case 'H'
    #: are DIFFERENT MESSAGES with different halt semantics.
    operational_halt: bool = False
    #: From ITCH 'Y' (Reg SHO).  Rule 201 short-sale price test.  This does NOT
    #: change the trading state — it gates SHORT SALES only.
    ssr_active: bool = False
    ssr_code: str = itch.SHO_NONE
    #: From ITCH 'J' (LULD Auction Collar).  Consumed by the risk gate.
    luld_lo: int = 0
    luld_hi: int = 0
    luld_reference: int = 0
    luld_extension: int = 0


class VenueState:
    """Global session state plus per-symbol overrides.  No global variables."""

    def __init__(self) -> None:
        #: ⚠️ RESET VALUE.  Fail-closed: nothing trades until ITCH says so.
        self.session_state: TradeState = TradeState.DISABLED
        self.last_system_event: str = ""
        #: ITCH 'W' (MWCB Status): a market-wide circuit breaker level has been
        #: breached.  manuals/08-nasdaq/04-*.md §4.1: "⚠️ Global order-emission
        #: stop."  Sticky — only a new session clears it.
        self.mwcb_breached: bool = False
        self.mwcb_level: str = ""
        self.symbols: dict[int, SymbolVenueState] = {}
        #: True once ITCH 'S'/'C' (End of Messages) has been seen.  Any further
        #: message after that is an anomaly worth counting (08-nasdaq/04 §8).
        self.messages_ended: bool = False

    # -- state access -------------------------------------------------------

    def sym_state(self, sym: int) -> SymbolVenueState:
        state = self.symbols.get(sym)
        if state is None:
            state = SymbolVenueState()
            self.symbols[sym] = state
        return state

    def effective_state(self, sym: int) -> TradeState:
        """The per-symbol ``trade_state_e`` the strategy gates on.

        MOST RESTRICTIVE WINS, evaluated in this fixed order:

          1. market-wide circuit breaker ('W')      -> HALTED
          2. operational halt ('h')                 -> HALTED
          3. stock trading action ('H')             -> HALTED / PAUSED / AUCTION
          4. otherwise the global session state ('S')

        ⚠️ ``TRADE_STALE`` is deliberately NOT produced here.  Book staleness
        lives in ``book_top_t.stale`` and is an independent gate, because the
        two have different causes (venue message vs. our own sequence gap) and
        different clearing procedures.  The strategy checks both.
        """
        state = self.sym_state(sym)
        if self.mwcb_breached:
            return TradeState.HALTED
        if state.operational_halt:
            return TradeState.HALTED
        if state.trading_action is not None:
            return state.trading_action
        return self.session_state

    def ssr_active(self, sym: int) -> bool:
        return self.sym_state(sym).ssr_active

    # -- ITCH 'S' — System Event (GLOBAL) -----------------------------------

    #: ITCH 'S' event code -> global session state.
    #: > Verify: the single-character event codes against the TotalView-ITCH
    #:   5.0 spec.  ITCH 5.0 removed some emergency-market-condition codes that
    #:   existed in earlier versions (08-nasdaq/04 §8).
    #: TODO(verify): the STATE each code maps to is this project's
    #:   interpretation of 08-nasdaq/04 §8's "FPGA action" column.  In
    #:   particular ``END_MARKET`` maps to CLOSED rather than to a post-market
    #:   state, because ``trade_state_e`` has no post-market value and the
    #:   manual's instruction is "disarm the fast path".  Fail-closed by
    #:   construction, but confirm it is what the session schedule expects.
    SYSTEM_EVENT_STATE: dict[str, TradeState] = {
        itch.SYSEV_START_MESSAGES: TradeState.CLOSED,  # 'O' feed up for the day
        itch.SYSEV_START_SYSTEM: TradeState.PREOPEN,  # 'S' pre-market
        itch.SYSEV_START_MARKET: TradeState.OPEN,  # 'Q' ⚠️ arms the fast path
        itch.SYSEV_END_MARKET: TradeState.CLOSED,  # 'M' ⚠️ disarms it
        itch.SYSEV_END_SYSTEM: TradeState.CLOSED,  # 'E'
        itch.SYSEV_END_MESSAGES: TradeState.CLOSED,  # 'C'
    }

    def apply_system_event(self, code: str) -> list[StateChange]:
        changes: list[StateChange] = []
        self.last_system_event = code
        new_state = self.SYSTEM_EVENT_STATE.get(code)
        if new_state is None:
            # An unrecognised system-event code must not silently open the
            # session.  Fail closed and let the counter surface it.
            new_state = TradeState.DISABLED
        if code == itch.SYSEV_START_MESSAGES:
            # "Start of messages: reset sequence tracking; clear books."  The
            # book clear is the caller's job (it owns the book); the venue
            # state clears its own sticky flags here.
            self.mwcb_breached = False
            self.mwcb_level = ""
            self.messages_ended = False
        if code == itch.SYSEV_END_MESSAGES:
            self.messages_ended = True
        if new_state is not self.session_state:
            changes.append(
                StateChange(
                    scope="session",
                    sym=None,
                    what="trade_state",
                    old=self.session_state,
                    new=new_state,
                    cause=f"S:{code!r}",
                )
            )
            self.session_state = new_state
        return changes

    # -- ITCH 'H' — Stock Trading Action (PER SYMBOL) -----------------------

    #: ITCH 'H' trading-state code -> per-symbol override.
    #: ``TRADE_ACT_TRADING`` ('T') clears the override so the symbol follows
    #: the session state again.
    #: TODO(verify): 'Q' (quotation only) maps to ``TRADE_AUCTION`` here.  A
    #:   quotation-only period is the pre-reopening state in which quotes are
    #:   accepted but continuous trading is not happening, which is the closest
    #:   value ``trade_state_e`` offers.  The consequence is that the strategy
    #:   does not quote during it (only ``TRADE_OPEN`` quotes), which is the
    #:   fail-closed reading.  Confirm against 08-nasdaq/02 §3.3.
    TRADING_ACTION_STATE: dict[str, TradeState | None] = {
        itch.TRADE_ACT_HALTED: TradeState.HALTED,  # 'H'
        itch.TRADE_ACT_PAUSED: TradeState.PAUSED,  # 'P' LULD pause
        itch.TRADE_ACT_QUOTEONLY: TradeState.AUCTION,  # 'Q'
        itch.TRADE_ACT_TRADING: None,  # 'T' resume: follow the session
    }

    def apply_trading_action(
        self, sym: int, state_code: str, reason: str = ""
    ) -> list[StateChange]:
        state = self.sym_state(sym)
        before = self.effective_state(sym)
        if state_code in self.TRADING_ACTION_STATE:
            state.trading_action = self.TRADING_ACTION_STATE[state_code]
        else:
            # ⚠️ An unknown trading-state code must HALT, not resume.  Getting a
            # halt code inverted is a compliance event.
            state.trading_action = TradeState.HALTED
        after = self.effective_state(sym)
        if after is not before:
            return [
                StateChange(
                    scope="symbol",
                    sym=sym,
                    what="trade_state",
                    old=before,
                    new=after,
                    cause=f"H:{state_code!r}" + (f" reason={reason!r}" if reason else ""),
                )
            ]
        return []

    # -- ITCH 'h' — Operational Halt (PER SYMBOL, PER MARKET) ---------------

    def apply_operational_halt(
        self, sym: int, market_code: str, action_code: str
    ) -> list[StateChange]:
        """⚠️ lower-case 'h'.  A different message from upper-case 'H'.

        TODO(verify): the action code alphabet ('H' = halted, 'T' = trading
        resumed) against the spec PDF.  As with 'H', an UNRECOGNISED code halts
        rather than resumes.
        """
        state = self.sym_state(sym)
        before = self.effective_state(sym)
        state.operational_halt = action_code != "T"
        after = self.effective_state(sym)
        if after is not before:
            return [
                StateChange(
                    scope="symbol",
                    sym=sym,
                    what="trade_state",
                    old=before,
                    new=after,
                    cause=f"h:{action_code!r} market={market_code!r}",
                )
            ]
        return []

    # -- ITCH 'Y' — Reg SHO Restriction (PER SYMBOL) ------------------------

    def apply_reg_sho(self, sym: int, action_code: str) -> list[StateChange]:
        """Rule 201 short-sale price test.

        ⚠️ This does NOT change the trading state.  It gates SHORT SALES only,
        via ``sym_risk_t.ssr_active`` in the risk gate and ``order_req_t.is_short``
        from the strategy.  A model that halted the symbol on a Reg SHO
        restriction would stop legitimate long trading.
        """
        state = self.sym_state(sym)
        before = state.ssr_active
        # SHO_NONE ('0') = not restricted.  '1' (triggered intraday) and '2'
        # (in force) both mean the price test applies.
        # TODO(verify): that '1' should be treated as active.  '1' means the
        #   test was triggered TODAY; the restriction is in force for the rest
        #   of today and tomorrow.  Treating it as active is the fail-closed
        #   reading.  Confirm against Reg SHO Rule 201.
        state.ssr_code = action_code
        state.ssr_active = action_code in (itch.SHO_INTRADAY, itch.SHO_RESTRICTED)
        if state.ssr_active != before:
            return [
                StateChange(
                    scope="symbol",
                    sym=sym,
                    what="ssr",
                    old=before,
                    new=state.ssr_active,
                    cause=f"Y:{action_code!r}",
                )
            ]
        return []

    # -- ITCH 'J' — LULD Auction Collar (PER SYMBOL) ------------------------

    def apply_luld_collar(
        self,
        sym: int,
        reference_price: int,
        upper: int,
        lower: int,
        extension: int,
    ) -> list[StateChange]:
        """Record the reopening collar.  Does not itself change the state.

        The LULD PAUSE arrives as an 'H' with ``TRADE_ACT_PAUSED``; 'J' carries
        the band the risk gate checks orders against
        (``sym_risk_t.luld_lo`` / ``luld_hi``).
        """
        state = self.sym_state(sym)
        before = (state.luld_lo, state.luld_hi)
        state.luld_reference = reference_price
        state.luld_hi = upper
        state.luld_lo = lower
        state.luld_extension = extension
        after = (state.luld_lo, state.luld_hi)
        if after != before:
            return [
                StateChange(
                    scope="symbol",
                    sym=sym,
                    what="luld",
                    old=before,
                    new=after,
                    cause="J",
                )
            ]
        return []

    # -- ITCH 'W' — MWCB Status (GLOBAL) ------------------------------------

    def apply_mwcb_status(self, breached_level: str) -> list[StateChange]:
        """A market-wide circuit breaker level has been breached.

        ⚠️ Global order-emission stop (08-nasdaq/04 §4.1).  Sticky until the
        next 'S'/'O' (Start of Messages).
        """
        before = self.mwcb_breached
        self.mwcb_breached = True
        self.mwcb_level = breached_level
        if not before:
            return [
                StateChange(
                    scope="session",
                    sym=None,
                    what="mwcb",
                    old=False,
                    new=True,
                    cause=f"W:{breached_level!r}",
                )
            ]
        return []

    # -- dump ---------------------------------------------------------------

    def snapshot(self) -> dict[str, object]:
        return {
            "session_state": self.session_state.name,
            "last_system_event": self.last_system_event,
            "messages_ended": self.messages_ended,
            "mwcb_breached": self.mwcb_breached,
            "mwcb_level": self.mwcb_level,
            "symbols": {
                str(sym): {
                    "effective_state": self.effective_state(sym).name,
                    "trading_action": (
                        None if s.trading_action is None else s.trading_action.name
                    ),
                    "operational_halt": s.operational_halt,
                    "ssr_active": s.ssr_active,
                    "ssr_code": s.ssr_code,
                    "luld_lo": s.luld_lo,
                    "luld_hi": s.luld_hi,
                }
                for sym, s in sorted(self.symbols.items())
            },
        }
