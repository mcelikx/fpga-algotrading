"""itch_decode.py — the golden ITCH 5.0 / MoldUDP64 decoder.

OPTIMIZED FOR OBVIOUS CORRECTNESS, NOT FOR SPEED.  This is the oracle the
fabric is checked against.  When the fabric and this module disagree, someone
must be able to answer "which one is wrong?" by *reading this file*, without
already knowing the answer.  Every place a clever encoding was available and a
dumb one was used instead is called out in a comment.

THE THREE DUMB-ON-PURPOSE DECISIONS IN THIS FILE
------------------------------------------------
1. **Offsets are never written down.**  Each message is a list of
   ``(field, width, kind)`` in wire order and the offsets are *derived* by
   accumulation.  A transcribed offset is a number that can be wrong on its
   own; a derived offset cannot disagree with the field it follows.  The
   derived offsets are then asserted, at import time, against the ``OFF_*``
   constants that ``rtl/pkg/itch_pkg.sv`` *does* declare (A, E, X, D, U), and
   the derived total length is asserted against ``LEN_*`` for **every** type.
   That is a real cross-check: a length and a field layout can only agree if
   both are right.
2. **No speculative extraction.**  The fabric extracts every candidate field at
   every offset in parallel and muxes by type, because LUTs are cheap and
   cycles are not.  Here we look up one table and read one message.  Same
   answer, one tenth the surface area to be wrong on.
3. **No fast paths.**  Integers are decoded with ``int.from_bytes(...,"big")``
   every time.  There is no cached slice, no memoryview trickery, no struct
   format string.  Speed is not this module's job.

⚠️ VERIFICATION STATUS OF THE OFFSETS
-------------------------------------
``rtl/pkg/itch_pkg.sv`` declares field offsets for **five** message types only
(A, E, X, D, U) and marks even those "> Verify: spec. Structure illustrative —
confirm offsets before RTL."  The other seventeen types have a *length* in
``itch_pkg.sv`` but no field layout at all, so their layouts below were derived
from manuals/08-nasdaq/04-totalview-itch-5.0.md §4 and the field-width lists
there.  Every such table carries a ``TODO(verify)``.

The strongest thing this file can say about them is this: **for all 22 types,
sum(field widths) + 11-byte prefix == the length declared in itch_pkg.sv.**
That is an independent agreement between two separately-sourced numbers, and it
is asserted at import.  It is not a substitute for the spec PDF.  It is the
best available check until someone confirms against the PDF and deletes the
TODOs.
"""

from __future__ import annotations

import enum
from dataclasses import dataclass
from typing import Mapping

from . import itch_pkg_mirror as itch
from .trading_pkg_mirror import Side

__all__ = [
    "FieldKind",
    "FieldSpec",
    "MESSAGE_LAYOUT",
    "DecodeStatus",
    "ItchMessage",
    "DecodeResult",
    "MoldPacket",
    "decode_message",
    "decode_mold_packet",
    "side_from_char",
    "field_offset",
]


# =============================================================================
# 1. Field layout tables
# =============================================================================


class FieldKind(enum.Enum):
    """How a field's bytes are interpreted.  Deliberately only three kinds."""

    UINT = "uint"  # big-endian unsigned integer.  Prices are UINT: they stay
    #                scaled integers end to end and are NEVER converted.
    CHAR = "char"  # a single ASCII byte, kept as a 1-character str
    ALPHA = "alpha"  # fixed-length ASCII, right-padded with spaces


@dataclass(frozen=True, slots=True)
class FieldSpec:
    name: str
    width: int
    kind: FieldKind
    note: str = ""


U = FieldKind.UINT
C = FieldKind.CHAR
A = FieldKind.ALPHA

# -----------------------------------------------------------------------------
# The common 11-byte prefix, present on EVERY message.
#   [0]      Message Type      1 byte
#   [1..2]   Stock Locate      2 bytes, big-endian  <-- the direct index
#   [3..4]   Tracking Number   2 bytes, big-endian
#   [5..10]  Timestamp         6 bytes, big-endian, ns since midnight ET
# > Verify: TotalView-ITCH 5.0 spec, "Common fields".  (Mirrored offsets for
#   this prefix ARE declared in itch_pkg.sv and are asserted below.)
# -----------------------------------------------------------------------------
_PREFIX: tuple[FieldSpec, ...] = (
    FieldSpec("msg_type", 1, C),
    FieldSpec("stock_locate", 2, U),
    FieldSpec("tracking_number", 2, U),
    FieldSpec("timestamp", 6, U, "ns since midnight ET"),
)


def _msg(*body: FieldSpec) -> tuple[FieldSpec, ...]:
    """A message layout is the invariant prefix followed by its body."""
    return _PREFIX + body


#: type code -> full wire layout, in wire order.  Offsets are DERIVED from this
#: table (see :func:`field_offset`); they are never written down.
MESSAGE_LAYOUT: dict[str, tuple[FieldSpec, ...]] = {
    # -- §4.1 Administrative and reference data -----------------------------
    # TODO(verify): body layout not declared in itch_pkg.sv; derived from
    # manuals/08-nasdaq/04-totalview-itch-5.0.md §4.1.  Confirm against the
    # TotalView-ITCH 5.0 spec PDF.
    itch.MSG_SYSTEM_EVENT: _msg(  # 'S', 12
        FieldSpec("event_code", 1, C, "SYSEV_* in itch_pkg.sv §5"),
    ),
    itch.MSG_STOCK_DIRECTORY: _msg(  # 'R', 39
        FieldSpec("stock", 8, A),
        FieldSpec("market_category", 1, C),
        FieldSpec("financial_status_indicator", 1, C),
        FieldSpec("round_lot_size", 4, U),
        FieldSpec("round_lots_only", 1, C),
        FieldSpec("issue_classification", 1, C),
        FieldSpec("issue_subtype", 2, A),
        FieldSpec("authenticity", 1, C),
        FieldSpec("short_sale_threshold_indicator", 1, C),
        FieldSpec("ipo_flag", 1, C),
        FieldSpec("luld_reference_price_tier", 1, C),
        FieldSpec("etp_flag", 1, C),
        FieldSpec("etp_leverage_factor", 4, U),
        FieldSpec("inverse_indicator", 1, C),
    ),
    itch.MSG_TRADING_ACTION: _msg(  # 'H', 25
        FieldSpec("stock", 8, A),
        FieldSpec("trading_state", 1, C, "TRADE_ACT_* in itch_pkg.sv §5"),
        FieldSpec("reserved", 1, C),
        FieldSpec("reason", 4, A),
    ),
    itch.MSG_REG_SHO: _msg(  # 'Y', 20
        FieldSpec("stock", 8, A),
        FieldSpec("reg_sho_action", 1, C, "SHO_* in itch_pkg.sv §5"),
    ),
    itch.MSG_MKT_PARTICIPANT: _msg(  # 'L', 26
        FieldSpec("mpid", 4, A),
        FieldSpec("stock", 8, A),
        FieldSpec("primary_market_maker", 1, C),
        FieldSpec("market_maker_mode", 1, C),
        FieldSpec("market_participant_state", 1, C),
    ),
    itch.MSG_MWCB_DECLINE: _msg(  # 'V', 35
        # ⚠️ DIFFERENT PRICE SCALE.  manuals/08-nasdaq/04-*.md §3: "The MWCB
        #    Decline Level (V) message carries prices with a *different* number
        #    of implied decimals from the ordinary 4."  These are 8-byte
        #    fields; the model keeps them as raw integers and does NOT apply
        #    PRICE_SCALE to them.  TODO(verify): the actual implied-decimal
        #    count, per field, against the spec PDF.
        FieldSpec("level_1", 8, U, "MWCB price, NOT 4 implied decimals"),
        FieldSpec("level_2", 8, U, "MWCB price, NOT 4 implied decimals"),
        FieldSpec("level_3", 8, U, "MWCB price, NOT 4 implied decimals"),
    ),
    itch.MSG_MWCB_STATUS: _msg(  # 'W', 12
        FieldSpec("breached_level", 1, C),
    ),
    itch.MSG_IPO_QUOTING: _msg(  # 'K', 28
        FieldSpec("stock", 8, A),
        FieldSpec("ipo_quotation_release_time", 4, U, "seconds since midnight"),
        FieldSpec("ipo_quotation_release_qualifier", 1, C),
        FieldSpec("ipo_price", 4, U),
    ),
    itch.MSG_LULD_COLLAR: _msg(  # 'J', 35
        FieldSpec("stock", 8, A),
        FieldSpec("auction_collar_reference_price", 4, U),
        FieldSpec("upper_auction_collar_price", 4, U),
        FieldSpec("lower_auction_collar_price", 4, U),
        FieldSpec("auction_collar_extension", 4, U),
    ),
    itch.MSG_OPERATIONAL_HALT: _msg(  # 'h', 21
        FieldSpec("stock", 8, A),
        FieldSpec("market_code", 1, C),
        FieldSpec("operational_halt_action", 1, C),
    ),
    # -- §4.2 Order book messages — the fast path ---------------------------
    # These five (A, E, X, D, U) have their offsets DECLARED in itch_pkg.sv §4.
    # The derived offsets below are asserted against them at import time.
    itch.MSG_ADD_ORDER: _msg(  # 'A', 36
        FieldSpec("order_reference_number", 8, U),
        FieldSpec("buy_sell_indicator", 1, C),
        FieldSpec("shares", 4, U),
        FieldSpec("stock", 8, A),
        FieldSpec("price", 4, U, "4 implied decimals"),
    ),
    itch.MSG_ADD_ORDER_MPID: _msg(  # 'F', 40 — 'A' plus attribution
        FieldSpec("order_reference_number", 8, U),
        FieldSpec("buy_sell_indicator", 1, C),
        FieldSpec("shares", 4, U),
        FieldSpec("stock", 8, A),
        FieldSpec("price", 4, U, "4 implied decimals"),
        FieldSpec("attribution", 4, A, "MPID"),
    ),
    itch.MSG_ORDER_EXECUTED: _msg(  # 'E', 31
        FieldSpec("order_reference_number", 8, U),
        FieldSpec("executed_shares", 4, U),
        FieldSpec("match_number", 8, U),
    ),
    itch.MSG_ORDER_EXEC_PRICE: _msg(  # 'C', 36
        FieldSpec("order_reference_number", 8, U),
        FieldSpec("executed_shares", 4, U),
        FieldSpec("match_number", 8, U),
        # ⚠️ `printable` affects the TAPE, not the book.  The shares leave the
        #    book either way.  Treating printable='N' as "no book effect" is a
        #    classic and expensive error (04.03 §6.2).
        FieldSpec("printable", 1, C, "'Y'/'N' — tape only, NOT a book gate"),
        # ⚠️ The execution price is NOT the resting price.  Never use it to
        #    locate the level (08-nasdaq/04 §7).
        FieldSpec("execution_price", 4, U, "NOT the resting price"),
    ),
    itch.MSG_ORDER_CANCEL: _msg(  # 'X', 23 — partial reduce
        FieldSpec("order_reference_number", 8, U),
        FieldSpec("cancelled_shares", 4, U),
    ),
    itch.MSG_ORDER_DELETE: _msg(  # 'D', 19 — full remove
        FieldSpec("order_reference_number", 8, U),
    ),
    itch.MSG_ORDER_REPLACE: _msg(  # 'U', 35
        # ⚠️ 'U' DELETES the original reference and CREATES a new one.  It is
        #    not an in-place modify.  See book.py apply_replace().
        FieldSpec("original_order_reference_number", 8, U),
        FieldSpec("new_order_reference_number", 8, U),
        FieldSpec("shares", 4, U),
        FieldSpec("price", 4, U, "4 implied decimals"),
    ),
    # -- §4.3 Trade and auction messages ------------------------------------
    # TODO(verify): body layout not declared in itch_pkg.sv; derived from
    # manuals/08-nasdaq/04-totalview-itch-5.0.md §4.3.
    itch.MSG_TRADE: _msg(  # 'P', 44
        # ⚠️ NO BOOK EFFECT.  This reports an execution against non-displayed
        #    liquidity that was never in the displayed book.  Applying it
        #    corrupts the book.  It is a tape/statistics message.
        FieldSpec("order_reference_number", 8, U, "NOT a live book reference"),
        FieldSpec("buy_sell_indicator", 1, C),
        FieldSpec("shares", 4, U),
        FieldSpec("stock", 8, A),
        FieldSpec("price", 4, U, "4 implied decimals"),
        FieldSpec("match_number", 8, U),
    ),
    itch.MSG_CROSS_TRADE: _msg(  # 'Q', 40
        FieldSpec("shares", 8, U, "8 bytes here, unlike A/P"),
        FieldSpec("stock", 8, A),
        FieldSpec("cross_price", 4, U, "4 implied decimals"),
        FieldSpec("match_number", 8, U),
        FieldSpec("cross_type", 1, C),
    ),
    itch.MSG_BROKEN_TRADE: _msg(  # 'B', 19
        FieldSpec("match_number", 8, U),
    ),
    itch.MSG_NOII: _msg(  # 'I', 50
        FieldSpec("paired_shares", 8, U),
        FieldSpec("imbalance_shares", 8, U),
        FieldSpec("imbalance_direction", 1, C),
        FieldSpec("stock", 8, A),
        FieldSpec("far_price", 4, U),
        FieldSpec("near_price", 4, U),
        FieldSpec("current_reference_price", 4, U),
        FieldSpec("cross_type", 1, C),
        FieldSpec("price_variation_indicator", 1, C),
    ),
    itch.MSG_RPII: _msg(  # 'N', 20
        FieldSpec("stock", 8, A),
        FieldSpec("interest_flag", 1, C),
    ),
}


def field_offset(type_code: str, field_name: str) -> int:
    """Byte offset of a field, DERIVED by accumulating the widths before it."""
    offset = 0
    for spec in MESSAGE_LAYOUT[type_code]:
        if spec.name == field_name:
            return offset
        offset += spec.width
    raise KeyError(f"message {type_code!r} has no field {field_name!r}")


def layout_length(type_code: str) -> int:
    """Total wire length implied by the field table."""
    return sum(spec.width for spec in MESSAGE_LAYOUT[type_code])


# =============================================================================
# 2. Import-time structural self-check
# =============================================================================
# This is the whole reason the layout tables are written as widths and not as
# offsets.  If any of these fail, the mirror, the manual and the RTL package
# disagree with each other, and no decode should be attempted until a human has
# looked at the spec PDF.


def _selfcheck() -> list[str]:
    problems: list[str] = []

    # (a) Every type in itch_pkg.sv's length table has a layout, and vice versa.
    if set(MESSAGE_LAYOUT) != set(itch.MSG_LEN):
        missing = set(itch.MSG_LEN) - set(MESSAGE_LAYOUT)
        extra = set(MESSAGE_LAYOUT) - set(itch.MSG_LEN)
        problems.append(
            f"layout/length table mismatch: no layout for {sorted(missing)}, "
            f"no length for {sorted(extra)}"
        )

    # (b) sum(field widths) == itch_pkg.sv's declared length, for EVERY type.
    for type_code, layout in MESSAGE_LAYOUT.items():
        declared = itch.MSG_LEN.get(type_code)
        derived = sum(s.width for s in layout)
        if declared is not None and derived != declared:
            problems.append(
                f"'{type_code}' ({itch.MSG_NAME.get(type_code, '?')}): field table "
                f"sums to {derived} bytes, itch_pkg.sv declares {declared}"
            )

    # (c) The invariant prefix really is invariant.
    for type_code, layout in MESSAGE_LAYOUT.items():
        if layout[: len(_PREFIX)] != _PREFIX:
            problems.append(f"'{type_code}' does not start with the common prefix")

    # (d) The common-prefix offsets match itch_pkg.sv §4.
    for field_name, off_const, const_name in (
        ("msg_type", itch.OFF_MSG_TYPE, "OFF_MSG_TYPE"),
        ("stock_locate", itch.OFF_LOCATE, "OFF_LOCATE"),
        ("tracking_number", itch.OFF_TRACKING, "OFF_TRACKING"),
        ("timestamp", itch.OFF_TIMESTAMP, "OFF_TIMESTAMP"),
    ):
        derived_off = field_offset(itch.MSG_ADD_ORDER, field_name)
        if derived_off != off_const:
            problems.append(
                f"prefix field {field_name}: derived offset {derived_off}, "
                f"itch_pkg.sv {const_name}={off_const}"
            )
    if sum(s.width for s in _PREFIX) != itch.HDR_PREFIX_LEN:
        problems.append(
            f"prefix is {sum(s.width for s in _PREFIX)} bytes, "
            f"itch_pkg.sv HDR_PREFIX_LEN={itch.HDR_PREFIX_LEN}"
        )
    if _PREFIX[3].width != itch.LEN_TIMESTAMP:
        problems.append("timestamp width != itch_pkg.sv LEN_TIMESTAMP")

    # (e) The five layouts itch_pkg.sv DOES declare offsets for must agree,
    #     field by field.  This is the tightest check available.
    declared_offsets: tuple[tuple[str, str, int, str], ...] = (
        (itch.MSG_ADD_ORDER, "order_reference_number", itch.OFF_A_ORDER_REF, "OFF_A_ORDER_REF"),
        (itch.MSG_ADD_ORDER, "buy_sell_indicator", itch.OFF_A_SIDE, "OFF_A_SIDE"),
        (itch.MSG_ADD_ORDER, "shares", itch.OFF_A_SHARES, "OFF_A_SHARES"),
        (itch.MSG_ADD_ORDER, "stock", itch.OFF_A_STOCK, "OFF_A_STOCK"),
        (itch.MSG_ADD_ORDER, "price", itch.OFF_A_PRICE, "OFF_A_PRICE"),
        (itch.MSG_ORDER_EXECUTED, "order_reference_number", itch.OFF_E_ORDER_REF, "OFF_E_ORDER_REF"),
        (itch.MSG_ORDER_EXECUTED, "executed_shares", itch.OFF_E_SHARES, "OFF_E_SHARES"),
        (itch.MSG_ORDER_EXECUTED, "match_number", itch.OFF_E_MATCH, "OFF_E_MATCH"),
        (itch.MSG_ORDER_CANCEL, "order_reference_number", itch.OFF_X_ORDER_REF, "OFF_X_ORDER_REF"),
        (itch.MSG_ORDER_CANCEL, "cancelled_shares", itch.OFF_X_SHARES, "OFF_X_SHARES"),
        (itch.MSG_ORDER_DELETE, "order_reference_number", itch.OFF_D_ORDER_REF, "OFF_D_ORDER_REF"),
        (itch.MSG_ORDER_REPLACE, "original_order_reference_number", itch.OFF_U_ORIG_REF, "OFF_U_ORIG_REF"),
        (itch.MSG_ORDER_REPLACE, "new_order_reference_number", itch.OFF_U_NEW_REF, "OFF_U_NEW_REF"),
        (itch.MSG_ORDER_REPLACE, "shares", itch.OFF_U_SHARES, "OFF_U_SHARES"),
        (itch.MSG_ORDER_REPLACE, "price", itch.OFF_U_PRICE, "OFF_U_PRICE"),
    )
    for type_code, field_name, off_const, const_name in declared_offsets:
        derived_off = field_offset(type_code, field_name)
        if derived_off != off_const:
            problems.append(
                f"'{type_code}'.{field_name}: derived offset {derived_off}, "
                f"itch_pkg.sv {const_name}={off_const}"
            )

    # (f) Field names are unique within a message (a duplicate would make the
    #     decoded dict silently lose one of them).
    for type_code, layout in MESSAGE_LAYOUT.items():
        names = [s.name for s in layout]
        if len(names) != len(set(names)):
            problems.append(f"'{type_code}' has duplicate field names: {names}")

    return problems


_LAYOUT_PROBLEMS = _selfcheck()
if _LAYOUT_PROBLEMS:
    raise itch.ContractMismatch(
        "host/pymodel/itch_decode.py field layouts disagree with "
        "rtl/pkg/itch_pkg.sv:\n  " + "\n  ".join(_LAYOUT_PROBLEMS)
    )


# =============================================================================
# 3. Decoded message representation
# =============================================================================


class DecodeStatus(enum.Enum):
    """Outcome of decoding one ITCH message block.

    ⚠️ ``UNKNOWN_TYPE`` is NOT an error.  Nasdaq adds message types; a decoder
    that treats an unknown type as a fault will fall over on a spec revision.
    It must be COUNTED and SKIPPED BY ITS DECLARED LENGTH, never by a guess.

    ⚠️ ``LENGTH_MISMATCH`` IS an error, and a serious one.  Once the length is
    wrong the read pointer advances by the wrong amount and every subsequent
    message in the packet is garbage read from the wrong offset — and it will
    *decode*, because arbitrary bytes are a valid type byte roughly one time in
    ten.  manuals/04-system-architecture/02-feed-handler-design.md §6.2:
    abandon the whole remaining packet.
    """

    OK = "ok"
    UNKNOWN_TYPE = "unknown_type"
    LENGTH_MISMATCH = "length_mismatch"
    TRUNCATED = "truncated"
    EMPTY = "empty"

    @property
    def is_error(self) -> bool:
        return self in (
            DecodeStatus.LENGTH_MISMATCH,
            DecodeStatus.TRUNCATED,
            DecodeStatus.EMPTY,
        )


@dataclass(frozen=True, slots=True)
class ItchMessage:
    """One fully decoded ITCH message.

    Fields are exposed as a plain mapping keyed by the wire field name.  A
    generic mapping rather than 22 dataclasses is a deliberate choice: it keeps
    the decoder's behaviour visible in ONE table, so "is the decoder right?" is
    a question about :data:`MESSAGE_LAYOUT` and nothing else.
    """

    type_code: str
    length: int
    locate: int
    tracking: int
    timestamp: int  # ns since midnight ET
    values: Mapping[str, int | str]
    raw: bytes

    def __getitem__(self, name: str) -> int | str:
        return self.values[name]

    def u(self, name: str) -> int:
        """Read an unsigned field, asserting it really is one."""
        value = self.values[name]
        if not isinstance(value, int):
            raise TypeError(f"{self.type_code}.{name} is not an integer field")
        return value

    def c(self, name: str) -> str:
        """Read a character / alpha field."""
        value = self.values[name]
        if not isinstance(value, str):
            raise TypeError(f"{self.type_code}.{name} is not a character field")
        return value

    def get(self, name: str, default: int | str | None = None) -> int | str | None:
        return self.values.get(name, default)

    @property
    def name(self) -> str:
        return itch.MSG_NAME.get(self.type_code, f"Unknown({self.type_code!r})")


@dataclass(frozen=True, slots=True)
class DecodeResult:
    """What :func:`decode_message` returns.  Always a value, never an exception."""

    status: DecodeStatus
    message: ItchMessage | None
    #: Bytes to advance the reader by.  For an UNKNOWN type this is the
    #: MoldUDP64-DECLARED length, never a guess.  Zero when nothing is safe to
    #: skip (LENGTH_MISMATCH / TRUNCATED with no trustworthy length).
    skip_bytes: int
    type_code: str
    declared_len: int | None
    expected_len: int | None
    detail: str = ""


def side_from_char(ch: str) -> Side:
    """ITCH buy/sell indicator -> ``side_e``.

    ⚠️ DIVERGENCE NOTE, READ BEFORE FILING A BUG.  The RTL sketch in
    manuals/04-system-architecture/02-feed-handler-design.md §6 decodes the
    side as ``(byte == "B")``, i.e. **anything that is not 'B' is a sell**.
    This model does the same thing so that a corrupt side byte produces the
    same book in both, rather than a divergence that hides the corruption.
    ``ItchDecoder`` counts non-{'B','S'} bytes in ``bad_side_char`` — a nonzero
    count means the feed or the decode is wrong, and the counter is how you
    find out.
    """
    return Side.BUY if ch == itch.SIDE_CHAR_BUY else Side.SELL


# =============================================================================
# 4. The decoder
# =============================================================================


def decode_message(raw: bytes, declared_len: int | None = None) -> DecodeResult:
    """Decode ONE ITCH message.

    ``declared_len`` is the MoldUDP64 block length prefix, when there is one.
    Supplying it enables the free integrity check that
    manuals/08-nasdaq/04-*.md §5 insists on: *the length prefix is redundant
    with the type, so cross-check them*.

    This function NEVER raises on malformed input.  It returns a status.  A
    decoder on the fast path cannot throw, so the oracle does not either — a
    thrown exception would be a different behaviour from the fabric's, which is
    exactly what an oracle must not have.
    """
    if len(raw) == 0:
        return DecodeResult(
            status=DecodeStatus.EMPTY,
            message=None,
            skip_bytes=0,
            type_code="",
            declared_len=declared_len,
            expected_len=None,
            detail="zero-length message block",
        )

    type_code = chr(raw[0])
    expected = itch.itch_msg_len(type_code)  # 0 == unknown type

    # ---- Unknown type: NOT an error.  Count it, skip by the DECLARED length.
    if expected == 0:
        return DecodeResult(
            status=DecodeStatus.UNKNOWN_TYPE,
            message=None,
            # If there is no declared length we cannot skip safely and must not
            # guess: the caller abandons the rest of the packet.
            skip_bytes=declared_len if declared_len is not None else 0,
            type_code=type_code,
            declared_len=declared_len,
            expected_len=None,
            detail=(
                f"unknown ITCH message type {type_code!r} (0x{raw[0]:02X}); "
                "skipped by its declared length"
            ),
        )

    # ---- Declared length must equal the type's fixed length.  This is an
    #      ERROR, and per 04.02 §6.2 the caller abandons the rest of the packet.
    if declared_len is not None and declared_len != expected:
        return DecodeResult(
            status=DecodeStatus.LENGTH_MISMATCH,
            message=None,
            skip_bytes=0,
            type_code=type_code,
            declared_len=declared_len,
            expected_len=expected,
            detail=(
                f"'{type_code}' ({itch.MSG_NAME[type_code]}): MoldUDP64 block "
                f"length {declared_len} != fixed length {expected}"
            ),
        )

    if len(raw) < expected:
        return DecodeResult(
            status=DecodeStatus.TRUNCATED,
            message=None,
            skip_bytes=0,
            type_code=type_code,
            declared_len=declared_len,
            expected_len=expected,
            detail=(
                f"'{type_code}' ({itch.MSG_NAME[type_code]}): only {len(raw)} "
                f"bytes available, need {expected}"
            ),
        )

    body = raw[:expected]
    values: dict[str, int | str] = {}
    offset = 0
    for spec in MESSAGE_LAYOUT[type_code]:
        chunk = body[offset : offset + spec.width]
        if spec.kind is FieldKind.UINT:
            values[spec.name] = int.from_bytes(chunk, "big")
        elif spec.kind is FieldKind.CHAR:
            values[spec.name] = chr(chunk[0])
        else:  # ALPHA — fixed length, right-padded with spaces
            values[spec.name] = chunk.decode("ascii", errors="replace").rstrip(" ")
        offset += spec.width

    message = ItchMessage(
        type_code=type_code,
        length=expected,
        locate=int(values["stock_locate"]),  # type: ignore[arg-type]
        tracking=int(values["tracking_number"]),  # type: ignore[arg-type]
        timestamp=int(values["timestamp"]),  # type: ignore[arg-type]
        values=values,
        raw=bytes(body),
    )
    return DecodeResult(
        status=DecodeStatus.OK,
        message=message,
        skip_bytes=expected,
        type_code=type_code,
        declared_len=declared_len,
        expected_len=expected,
    )


# =============================================================================
# 5. MoldUDP64 deframing
# =============================================================================


@dataclass(frozen=True, slots=True)
class MoldPacket:
    """A parsed MoldUDP64 downstream packet.

    Layout (itch_pkg.sv §1):
      [0..9]   Session          10 bytes, alphanumeric
      [10..17] Sequence Number   8 bytes, big-endian, of the FIRST message
      [18..19] Message Count     2 bytes, big-endian
      [20..]   N message blocks, each: 2-byte big-endian length + payload
    """

    session: str
    sequence: int
    count: int
    blocks: tuple[bytes, ...]
    malformed: str = ""

    @property
    def is_heartbeat(self) -> bool:
        return self.count == itch.MOLD_CNT_HEARTBEAT

    @property
    def is_end_of_session(self) -> bool:
        return self.count == itch.MOLD_CNT_ENDSESS

    @property
    def next_expected(self) -> int:
        """``SequenceNumber + MessageCount`` — the sequence counts MESSAGES."""
        if self.is_end_of_session:
            return self.sequence
        return self.sequence + self.count


def decode_mold_packet(raw: bytes) -> MoldPacket:
    """Deframe a MoldUDP64 packet into its message blocks.

    Never raises.  A short or inconsistent packet comes back with
    ``malformed`` set and whatever blocks were readable; the caller counts it
    as ``drop_malformed`` and abandons it.
    """
    if len(raw) < itch.MOLD_HDR_LEN:
        return MoldPacket(
            session="",
            sequence=0,
            count=0,
            blocks=(),
            malformed=f"packet is {len(raw)} bytes, header is {itch.MOLD_HDR_LEN}",
        )

    session = (
        raw[itch.MOLD_SESSION_OFF : itch.MOLD_SESSION_OFF + itch.MOLD_SESSION_LEN]
        .decode("ascii", errors="replace")
        .rstrip(" ")
    )
    sequence = int.from_bytes(
        raw[itch.MOLD_SEQNUM_OFF : itch.MOLD_SEQNUM_OFF + itch.MOLD_SEQNUM_LEN], "big"
    )
    count = int.from_bytes(
        raw[itch.MOLD_MSGCNT_OFF : itch.MOLD_MSGCNT_OFF + itch.MOLD_MSGCNT_LEN], "big"
    )

    blocks: list[bytes] = []
    malformed = ""
    pos = itch.MOLD_HDR_LEN
    expected_blocks = 0 if count in (itch.MOLD_CNT_HEARTBEAT, itch.MOLD_CNT_ENDSESS) else count

    for index in range(expected_blocks):
        if pos + 2 > len(raw):
            malformed = (
                f"block {index}: truncated length prefix at byte {pos} "
                f"of a {len(raw)}-byte packet"
            )
            break
        block_len = int.from_bytes(raw[pos : pos + 2], "big")
        pos += 2
        if pos + block_len > len(raw):
            malformed = (
                f"block {index}: declared length {block_len} runs past the "
                f"end of a {len(raw)}-byte packet"
            )
            break
        blocks.append(raw[pos : pos + block_len])
        pos += block_len

    if not malformed and pos != len(raw):
        # Trailing bytes are not necessarily fatal (padding happens) but they
        # are never expected, so they are reported rather than ignored.
        malformed = f"{len(raw) - pos} trailing byte(s) after the last block"

    return MoldPacket(
        session=session,
        sequence=sequence,
        count=count,
        blocks=tuple(blocks),
        malformed=malformed,
    )
