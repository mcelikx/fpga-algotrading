"""host.pymodel — the golden reference model for the FPGA trading pipeline.

⚠️ THIS PACKAGE IS THE VERIFICATION ORACLE FOR THE HARDWARE.

It is the ``goldenbook`` component of host/README.md §2: "the reference
order-book implementation, used as the verification oracle in ``tb/``, and in
production as an independent shadow book for divergence detection."

It contains a Nasdaq TotalView-ITCH 5.0 / MoldUDP64 decoder, an order-based
order book, a per-symbol venue-state machine, and a model of the strategy
engine — all in pure Python, all producing exactly the types in
``rtl/pkg/trading_pkg.sv``.

=============================================================================
OPTIMIZED FOR OBVIOUS CORRECTNESS, NOT FOR SPEED
=============================================================================
If the fabric and this model disagree, someone has to answer "which one is
wrong?" — and they have to be able to answer it by READING THIS CODE, without
already knowing the answer.  That requirement outranks every other one here.
So, throughout, where a clever implementation was available and a dumb one was
chosen, the dumb one won and the choice is stated in a comment.  The catalogue:

* **Best bid/ask is recomputed with ``max()``/``min()`` on every update**
  (``book.py``).  The fabric maintains it incrementally with a second-best
  cache and a bounded rescan, which is the subtlest logic in the design.  A
  recompute cannot have a cache-coherence bug because it has no cache.
* **The order map is a plain ``dict`` on the full 64-bit reference**
  (``book.py``).  No hash, no ways, no overflow region, no eviction — so the
  mis-attribution failure mode the fabric's 4-way table has does not exist here
  to be shared.
* **Levels are keyed by the raw ITCH price integer** (``book.py``).  No tick
  normalisation, no windowing, no per-symbol base — so a divergence that only
  appears far from the fabric's window base is a *window* bug, and the
  asymmetry is how you tell.
* **Field offsets are never written down; they are derived by accumulating
  field widths** (``itch_decode.py``), then asserted against the ``OFF_*``
  constants ``itch_pkg.sv`` declares and against every ``LEN_*``.
* **No speculative extraction** (``itch_decode.py``).  One table lookup, one
  message, in order.  The fabric extracts every candidate field at every offset
  in parallel because LUTs are cheap; here that would only be more surface to
  be wrong on.
* **Read-modify-write hazards cannot exist** — updates are applied one at a
  time, to completion, single-threaded.  The fabric needs a write-forwarding
  bypass for exactly this, and getting its depth wrong produces slow drift that
  this model will catch message by message.
* **Every mirrored constant is re-checked against the ``.sv`` source at import
  time** (``itch_pkg_mirror.py``, ``trading_pkg_mirror.py``).  The C++ half of
  ``host/`` uses ``static_assert`` for this; Python needs the explicit check or
  the oracle silently certifies a stale contract.

NO FLOATS.  Prices are ITCH-native scaled integers with 4 implied decimals
(``PRICE_SCALE = 10000``); ``$12.3400`` is ``123400``.  Nothing on the model
path is a ``float`` or a ``Decimal``.  ``format_price()`` renders a price for
humans using integer division and string formatting.  The only legal float in
this package is in an analysis helper explicitly commented as such — there
currently are none.

=============================================================================
THE STEP-BY-STEP API (what ``tb/`` drives)
=============================================================================
::

    from host.pymodel import GoldenModel, SymbolFilter, SymStrat

    model = GoldenModel(symbols=SymbolFilter({7: 0}), name="A-feed")

    step = model.step_message(raw_itch_bytes, rx_cycle=cycle)   # one message
    pkt  = model.step_packet(raw_mold_packet, rx_cycle=cycle)   # one packet

    step.status        # DecodeStatus.OK / UNKNOWN_TYPE / LENGTH_MISMATCH / ...
    step.message       # ItchMessage, or None
    step.filtered      # locate not subscribed (NORMAL, not an error)
    step.evt           # book_evt_t equivalent, or None
    step.top           # book_top_t equivalent, or None
    step.decision      # StrategyDecision (.req is order_req_t), or None
    step.state_changes # tuple[StateChange, ...] from S / H / h / Y / J / W
    step.describe()    # one log line

    model.top(sym)               # book_top_t without applying anything
    model.depth(sym, Side.BUY)   # [(price, qty, order_count), ...] best first
    model.snapshot()             # complete, stable, JSON-able state
    model.dump_text()            # the same, as diffable text
    model.diff_against(other)    # unified diff between two models

and for mismatch reporting::

    from host.pymodel import diff_struct, format_diff
    diffs = diff_struct(step.top, dut_top_as_dict)
    assert not diffs, format_diff(diffs, header="book_top_t mismatch",
                                  context=step.describe())

There is NO hidden global state.  Multiple :class:`GoldenModel` instances
coexist in one process and share nothing.

=============================================================================
⚠️ ``tb/common/golden_book.py`` MUST BE A THIN SHIM OVER THIS PACKAGE
=============================================================================
As of this writing ``tb/common/golden_book.py`` DOES NOT EXIST.  When it is
written, it must be a re-export shim and nothing else.

**A second, divergent book implementation destroys the entire value of having
an oracle.**  Two books that disagree tell you nothing about the DUT; they only
tell you that two people wrote a book.  The whole point of a reference model is
that there is exactly ONE definition of "correct" in the repository, that it is
reviewable in one place, and that a fix to it fixes every testbench at once.
If ``tb/`` forks its own book, every future divergence becomes a three-way
argument, and the RTL — the only artifact that actually matters — is the one
thing nobody is looking at.

The shim, in full::

    \"\"\"tb/common/golden_book.py — THIN SHIM. Do not implement anything here.

    The golden order book lives in host/pymodel/ and is the single definition
    of "correct" for this repository.  This file only makes it importable from
    a cocotb test without a sys.path dance.  If you need behaviour that is not
    re-exported below, ADD IT TO host/pymodel/ — never fork a second book.
    \"\"\"
    from __future__ import annotations

    import pathlib
    import sys

    REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
    if str(REPO_ROOT) not in sys.path:
        sys.path.insert(0, str(REPO_ROOT))

    from host.pymodel import (           # noqa: E402
        # --- the step API ---
        GoldenModel, StepResult, PacketResult, FeedCounters,
        # --- configuration ---
        SymbolFilter, SymStrat,
        # --- the trading_pkg.sv types ---
        BookEvt, BookTop, OrderReq, OrderToken,
        Side, TradeState, BookOp, Action, RiskReason, KillSrc,
        # --- book internals, for directed tests ---
        OrderBookModel, SymbolBook, LiveOrder, Level, BookCounters,
        # --- venue state ---
        VenueState, SymbolVenueState, StateChange,
        # --- strategy ---
        StrategyModel, StrategyDecision, StrategyState, Primitive,
        # --- ITCH decode / encode ---
        decode_message, decode_mold_packet, DecodeStatus, ItchMessage,
        MoldPacket, MESSAGE_LAYOUT, encode_message, mold_packet, raw_block,
        # --- mismatch reporting ---
        diff_struct, format_diff, dump_text, diff_text, FieldDiff,
        # --- constants ---
        PRICE_SCALE, TICK_ITCH_UNITS, format_price,
    )

    __all__ = [n for n in dir() if not n.startswith("_")]

That is the entire file.  It must contain no book logic, no decode logic, and
no second copy of any constant.
"""

from __future__ import annotations

from ._svparse import ContractMismatch
from .book import (
    BookCounters,
    Level,
    LiveOrder,
    OrderBookModel,
    SymbolBook,
    SymbolFilter,
)
from .diffing import FieldDiff, diff_struct, diff_text, dump_text, format_diff
from .itch_decode import (
    MESSAGE_LAYOUT,
    DecodeResult,
    DecodeStatus,
    FieldKind,
    FieldSpec,
    ItchMessage,
    MoldPacket,
    decode_message,
    decode_mold_packet,
    field_offset,
    side_from_char,
)
from .itch_encode import encode_message, mold_packet, raw_block
from .itch_pkg_mirror import MSG_LEN, MSG_NAME, is_book_msg, itch_msg_len
from .model import FeedCounters, GoldenModel, PacketResult, StepResult
from .strategy import (
    Primitive,
    StrategyCounters,
    StrategyDecision,
    StrategyModel,
    StrategyState,
)
from .trading_pkg_mirror import (
    N_ACTIVE,
    N_SYMBOLS,
    PRICE_SCALE,
    TICK_ITCH_UNITS,
    TOKEN_W,
    Action,
    BookEvt,
    BookOp,
    BookTop,
    KillSrc,
    OrderReq,
    OrderToken,
    RiskReason,
    Side,
    SymStrat,
    TradeState,
    format_price,
    pack_order_token,
    pack_sym_strat,
    unpack_order_token,
    unpack_sym_strat,
)
from .venue import StateChange, SymbolVenueState, VenueState

__version__ = "0.1.0"

__all__ = [
    # step API
    "GoldenModel",
    "StepResult",
    "PacketResult",
    "FeedCounters",
    # configuration
    "SymbolFilter",
    "SymStrat",
    # trading_pkg.sv types
    "BookEvt",
    "BookTop",
    "OrderReq",
    "OrderToken",
    "Side",
    "TradeState",
    "BookOp",
    "Action",
    "RiskReason",
    "KillSrc",
    # book
    "OrderBookModel",
    "SymbolBook",
    "LiveOrder",
    "Level",
    "BookCounters",
    # venue
    "VenueState",
    "SymbolVenueState",
    "StateChange",
    # strategy
    "StrategyModel",
    "StrategyDecision",
    "StrategyState",
    "StrategyCounters",
    "Primitive",
    # ITCH decode / encode
    "decode_message",
    "decode_mold_packet",
    "DecodeStatus",
    "DecodeResult",
    "ItchMessage",
    "MoldPacket",
    "MESSAGE_LAYOUT",
    "FieldKind",
    "FieldSpec",
    "field_offset",
    "side_from_char",
    "encode_message",
    "mold_packet",
    "raw_block",
    "MSG_LEN",
    "MSG_NAME",
    "itch_msg_len",
    "is_book_msg",
    # mismatch reporting
    "diff_struct",
    "format_diff",
    "dump_text",
    "diff_text",
    "FieldDiff",
    # constants and helpers
    "PRICE_SCALE",
    "TICK_ITCH_UNITS",
    "TOKEN_W",
    "N_ACTIVE",
    "N_SYMBOLS",
    "format_price",
    "pack_sym_strat",
    "unpack_sym_strat",
    "pack_order_token",
    "unpack_order_token",
    "ContractMismatch",
    "__version__",
]
