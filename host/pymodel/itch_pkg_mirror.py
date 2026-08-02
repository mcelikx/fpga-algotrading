"""itch_pkg_mirror.py — Python mirror of ``rtl/pkg/itch_pkg.sv``.

⚠️ THIS FILE IS A MIRROR, NOT A SOURCE.  Every constant below is transcribed
from ``rtl/pkg/itch_pkg.sv``.  At import time :func:`crosscheck_against_rtl`
re-reads that file and raises :class:`ContractMismatch` if any mirrored value
has moved.  That is this module's entire reason to exist: the C++ half of
``host/`` uses ``static_assert`` for the same job; Python needs an explicit
check or the oracle silently certifies the wrong answer after an RTL edit.

The ⚠️ / ``// > Verify:`` warnings from ``itch_pkg.sv`` are carried across
verbatim, because they apply with MORE force here — this model is the thing
that would bake a wrong offset into the definition of "correct".

    ⚠️  VERIFY BEFORE IMPLEMENTING RTL AGAINST THIS FILE.
        Message type codes and lengths below reflect the TotalView-ITCH 5.0
        specification, but field byte offsets and lengths MUST be confirmed
        against the current spec PDF from
        https://nasdaqtrader.com/Trading/TradingSpecs before they are baked
        into a decoder.  A wrong offset produces a decoder that "works" on some
        messages and silently corrupts others — the worst possible failure
        mode.  Every offset constant here is marked with its verification
        status.
        — rtl/pkg/itch_pkg.sv header

NO FLOATS.  Every value here is an ``int``.
"""

from __future__ import annotations

import pathlib

from ._svparse import ContractMismatch, SvPackage, load_package

__all__ = [
    "ContractMismatch",
    "ITCH_PKG_SV",
    "RTL_CROSSCHECK_DONE",
    "MSG_LEN",
    "MSG_NAME",
    "crosscheck_against_rtl",
    "itch_msg_len",
    "is_book_msg",
]

# =============================================================================
# 0. Where the source of truth lives
# =============================================================================
# host/pymodel/itch_pkg_mirror.py -> host/pymodel -> host -> <repo root>
REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
ITCH_PKG_SV = REPO_ROOT / "rtl" / "pkg" / "itch_pkg.sv"
TRADING_PKG_SV = REPO_ROOT / "rtl" / "pkg" / "trading_pkg.sv"


# =============================================================================
# 1. MoldUDP64 transport framing            (itch_pkg.sv §1)
# =============================================================================
# ITCH rides on MoldUDP64 over UDP multicast, on redundant A/B feeds.
#   [0..9]   Session          10 bytes, alphanumeric
#   [10..17] Sequence Number   8 bytes, big-endian, of the FIRST message
#   [18..19] Message Count     2 bytes, big-endian
#   [20..]   N message blocks, each: 2-byte big-endian length + payload
# > Verify: MoldUDP64 specification, nasdaqtrader.com.
MOLD_SESSION_OFF = 0
MOLD_SESSION_LEN = 10
MOLD_SEQNUM_OFF = 10
MOLD_SEQNUM_LEN = 8
MOLD_MSGCNT_OFF = 18
MOLD_MSGCNT_LEN = 2
MOLD_HDR_LEN = 20
MOLD_CNT_HEARTBEAT = 0x0000
MOLD_CNT_ENDSESS = 0xFFFF


# =============================================================================
# 2. ITCH 5.0 message type codes            (itch_pkg.sv §2)
# =============================================================================
# > Verify: TotalView-ITCH 5.0 spec, section "Message Formats".
# ⚠️ Type codes are CASE SENSITIVE.  'h' (Operational Halt) and 'H' (Stock
#    Trading Action) are different messages.
MSG_SYSTEM_EVENT = "S"
MSG_STOCK_DIRECTORY = "R"
MSG_TRADING_ACTION = "H"
MSG_REG_SHO = "Y"
MSG_MKT_PARTICIPANT = "L"
MSG_MWCB_DECLINE = "V"
MSG_MWCB_STATUS = "W"
MSG_IPO_QUOTING = "K"
MSG_LULD_COLLAR = "J"
MSG_OPERATIONAL_HALT = "h"
MSG_ADD_ORDER = "A"  # no MPID
MSG_ADD_ORDER_MPID = "F"  # with MPID
MSG_ORDER_EXECUTED = "E"
MSG_ORDER_EXEC_PRICE = "C"
MSG_ORDER_CANCEL = "X"  # partial reduce
MSG_ORDER_DELETE = "D"  # full remove
MSG_ORDER_REPLACE = "U"  # old ref out, new ref in
MSG_TRADE = "P"  # non-cross
MSG_CROSS_TRADE = "Q"
MSG_BROKEN_TRADE = "B"
MSG_NOII = "I"  # net order imbalance
MSG_RPII = "N"  # retail price improvement


# =============================================================================
# 3. Message lengths, bytes, INCLUDING the 1-byte type code  (itch_pkg.sv §3)
# =============================================================================
# ⚠️ These lengths are the primary thing to verify against the spec.  The
#    decoder MUST cross-check the MoldUDP64 block length against this table and
#    count a mismatch as a decode error rather than proceeding.
# > Verify: TotalView-ITCH 5.0 spec, per-message "Length" field.
LEN_SYSTEM_EVENT = 12
LEN_STOCK_DIRECTORY = 39
LEN_TRADING_ACTION = 25
LEN_REG_SHO = 20
LEN_MKT_PARTICIPANT = 26
LEN_MWCB_DECLINE = 35
LEN_MWCB_STATUS = 12
LEN_IPO_QUOTING = 28
LEN_LULD_COLLAR = 35
LEN_OPERATIONAL_HALT = 21
LEN_ADD_ORDER = 36
LEN_ADD_ORDER_MPID = 40
LEN_ORDER_EXECUTED = 31
LEN_ORDER_EXEC_PRICE = 36
LEN_ORDER_CANCEL = 23
LEN_ORDER_DELETE = 19
LEN_ORDER_REPLACE = 35
LEN_TRADE = 44
LEN_CROSS_TRADE = 40
LEN_BROKEN_TRADE = 19
LEN_NOII = 50
LEN_RPII = 20
LEN_MAX = 50

#: type code -> fixed message length.  This is ``itch_pkg::itch_msg_len()`` as
#: a dict.  A type absent from this dict is an UNKNOWN type, which is NOT an
#: error (Nasdaq adds message types) but MUST be counted and skipped by its
#: MoldUDP64-declared length, never by a guess.
MSG_LEN: dict[str, int] = {
    MSG_SYSTEM_EVENT: LEN_SYSTEM_EVENT,
    MSG_STOCK_DIRECTORY: LEN_STOCK_DIRECTORY,
    MSG_TRADING_ACTION: LEN_TRADING_ACTION,
    MSG_REG_SHO: LEN_REG_SHO,
    MSG_MKT_PARTICIPANT: LEN_MKT_PARTICIPANT,
    MSG_MWCB_DECLINE: LEN_MWCB_DECLINE,
    MSG_MWCB_STATUS: LEN_MWCB_STATUS,
    MSG_IPO_QUOTING: LEN_IPO_QUOTING,
    MSG_LULD_COLLAR: LEN_LULD_COLLAR,
    MSG_OPERATIONAL_HALT: LEN_OPERATIONAL_HALT,
    MSG_ADD_ORDER: LEN_ADD_ORDER,
    MSG_ADD_ORDER_MPID: LEN_ADD_ORDER_MPID,
    MSG_ORDER_EXECUTED: LEN_ORDER_EXECUTED,
    MSG_ORDER_EXEC_PRICE: LEN_ORDER_EXEC_PRICE,
    MSG_ORDER_CANCEL: LEN_ORDER_CANCEL,
    MSG_ORDER_DELETE: LEN_ORDER_DELETE,
    MSG_ORDER_REPLACE: LEN_ORDER_REPLACE,
    MSG_TRADE: LEN_TRADE,
    MSG_CROSS_TRADE: LEN_CROSS_TRADE,
    MSG_BROKEN_TRADE: LEN_BROKEN_TRADE,
    MSG_NOII: LEN_NOII,
    MSG_RPII: LEN_RPII,
}

#: Human names, for mismatch reports only.  Never used for dispatch.
MSG_NAME: dict[str, str] = {
    MSG_SYSTEM_EVENT: "SystemEvent",
    MSG_STOCK_DIRECTORY: "StockDirectory",
    MSG_TRADING_ACTION: "StockTradingAction",
    MSG_REG_SHO: "RegSHORestriction",
    MSG_MKT_PARTICIPANT: "MarketParticipantPosition",
    MSG_MWCB_DECLINE: "MWCBDeclineLevel",
    MSG_MWCB_STATUS: "MWCBStatus",
    MSG_IPO_QUOTING: "IPOQuotingPeriodUpdate",
    MSG_LULD_COLLAR: "LULDAuctionCollar",
    MSG_OPERATIONAL_HALT: "OperationalHalt",
    MSG_ADD_ORDER: "AddOrder",
    MSG_ADD_ORDER_MPID: "AddOrderMPID",
    MSG_ORDER_EXECUTED: "OrderExecuted",
    MSG_ORDER_EXEC_PRICE: "OrderExecutedWithPrice",
    MSG_ORDER_CANCEL: "OrderCancel",
    MSG_ORDER_DELETE: "OrderDelete",
    MSG_ORDER_REPLACE: "OrderReplace",
    MSG_TRADE: "TradeNonCross",
    MSG_CROSS_TRADE: "CrossTrade",
    MSG_BROKEN_TRADE: "BrokenTrade",
    MSG_NOII: "NOII",
    MSG_RPII: "RPII",
}


# =============================================================================
# 4. Common field offsets                   (itch_pkg.sv §4)
# =============================================================================
# Every ITCH message begins with the same 11-byte prefix:
#   [0]      Message Type      1 byte
#   [1..2]   Stock Locate      2 bytes, big-endian  <-- the direct index
#   [3..4]   Tracking Number   2 bytes, big-endian
#   [5..10]  Timestamp         6 bytes, big-endian, ns since midnight ET
# > Verify: TotalView-ITCH 5.0 spec, "Common fields".
OFF_MSG_TYPE = 0
OFF_LOCATE = 1
OFF_TRACKING = 3
OFF_TIMESTAMP = 5
LEN_TIMESTAMP = 6
HDR_PREFIX_LEN = 11

# Add Order (A) — offsets after the common prefix.
# > Verify: spec. Structure illustrative — confirm offsets before RTL.
OFF_A_ORDER_REF = 11
OFF_A_SIDE = 19
OFF_A_SHARES = 20
OFF_A_STOCK = 24
OFF_A_PRICE = 32

# Order Executed (E): common prefix, order ref, executed shares, match no.
OFF_E_ORDER_REF = 11
OFF_E_SHARES = 19
OFF_E_MATCH = 23

# Order Cancel (X): common prefix, order ref, cancelled shares.
OFF_X_ORDER_REF = 11
OFF_X_SHARES = 19

# Order Delete (D): common prefix, order ref.
OFF_D_ORDER_REF = 11

# Order Replace (U): common prefix, ORIGINAL ref, NEW ref, shares, price.
# ⚠️ 'U' both removes the original reference and creates a new one.  A book
#    that treats it as an in-place modify will leak order references and drift
#    from the true book.  See manuals/08-nasdaq/04-*.md.
OFF_U_ORIG_REF = 11
OFF_U_NEW_REF = 19
OFF_U_SHARES = 27
OFF_U_PRICE = 31


# =============================================================================
# 5. Field encodings                        (itch_pkg.sv §5)
# =============================================================================
SIDE_CHAR_BUY = "B"
SIDE_CHAR_SELL = "S"

# System Event (S) codes — drive the GLOBAL session state machine.
SYSEV_START_MESSAGES = "O"
SYSEV_START_SYSTEM = "S"
SYSEV_START_MARKET = "Q"
SYSEV_END_MARKET = "M"
SYSEV_END_SYSTEM = "E"
SYSEV_END_MESSAGES = "C"

# Trading Action (H) state codes — PER SYMBOL.
TRADE_ACT_HALTED = "H"
TRADE_ACT_PAUSED = "P"  # LULD pause
TRADE_ACT_QUOTEONLY = "Q"
TRADE_ACT_TRADING = "T"

# Reg SHO (Y) action codes — Rule 201 short-sale price test state.
SHO_NONE = "0"
SHO_INTRADAY = "1"  # triggered today
SHO_RESTRICTED = "2"  # in force


# =============================================================================
# 6. Decode helpers                         (itch_pkg.sv §6)
# =============================================================================


def itch_msg_len(type_code: str) -> int:
    """``itch_pkg::itch_msg_len`` — expected length for a type, 0 if unknown.

    An unknown type is NOT an error (Nasdaq adds message types) but it must be
    counted and skipped by its MoldUDP64-declared length, never by a guess.
    """
    return MSG_LEN.get(type_code, 0)


def is_book_msg(type_code: str) -> bool:
    """``itch_pkg::is_book_msg`` — true for types that MUTATE the order book.

    ⚠️ Note what is NOT here: 'P' (Trade, non-cross) and 'Q' (Cross Trade)
    report executions against non-displayed interest and auctions.  Applying
    either to the book CORRUPTS it (manuals/08-nasdaq/04-*.md §4.3).  They are
    statistics/tape messages, and this model carries them as ``BOOK_NOP``
    events so last-price can still be maintained.
    """
    return type_code in (
        MSG_ADD_ORDER,
        MSG_ADD_ORDER_MPID,
        MSG_ORDER_EXECUTED,
        MSG_ORDER_EXEC_PRICE,
        MSG_ORDER_CANCEL,
        MSG_ORDER_DELETE,
        MSG_ORDER_REPLACE,
    )


# =============================================================================
# 7. The cross-check — this module's reason to exist
# =============================================================================

#: Names mirrored above that must equal the ``itch_pkg.sv`` parameter of the
#: same name.  Character parameters are stored in the RTL as 8-bit ASCII codes,
#: so they are compared as ``ord()``.
_INT_PARAMS: tuple[str, ...] = (
    "MOLD_SESSION_OFF",
    "MOLD_SESSION_LEN",
    "MOLD_SEQNUM_OFF",
    "MOLD_SEQNUM_LEN",
    "MOLD_MSGCNT_OFF",
    "MOLD_MSGCNT_LEN",
    "MOLD_HDR_LEN",
    "MOLD_CNT_HEARTBEAT",
    "MOLD_CNT_ENDSESS",
    "LEN_SYSTEM_EVENT",
    "LEN_STOCK_DIRECTORY",
    "LEN_TRADING_ACTION",
    "LEN_REG_SHO",
    "LEN_MKT_PARTICIPANT",
    "LEN_MWCB_DECLINE",
    "LEN_MWCB_STATUS",
    "LEN_IPO_QUOTING",
    "LEN_LULD_COLLAR",
    "LEN_OPERATIONAL_HALT",
    "LEN_ADD_ORDER",
    "LEN_ADD_ORDER_MPID",
    "LEN_ORDER_EXECUTED",
    "LEN_ORDER_EXEC_PRICE",
    "LEN_ORDER_CANCEL",
    "LEN_ORDER_DELETE",
    "LEN_ORDER_REPLACE",
    "LEN_TRADE",
    "LEN_CROSS_TRADE",
    "LEN_BROKEN_TRADE",
    "LEN_NOII",
    "LEN_RPII",
    "LEN_MAX",
    "OFF_MSG_TYPE",
    "OFF_LOCATE",
    "OFF_TRACKING",
    "OFF_TIMESTAMP",
    "LEN_TIMESTAMP",
    "HDR_PREFIX_LEN",
    "OFF_A_ORDER_REF",
    "OFF_A_SIDE",
    "OFF_A_SHARES",
    "OFF_A_STOCK",
    "OFF_A_PRICE",
    "OFF_E_ORDER_REF",
    "OFF_E_SHARES",
    "OFF_E_MATCH",
    "OFF_X_ORDER_REF",
    "OFF_X_SHARES",
    "OFF_D_ORDER_REF",
    "OFF_U_ORIG_REF",
    "OFF_U_NEW_REF",
    "OFF_U_SHARES",
    "OFF_U_PRICE",
)

_CHAR_PARAMS: tuple[str, ...] = (
    "MSG_SYSTEM_EVENT",
    "MSG_STOCK_DIRECTORY",
    "MSG_TRADING_ACTION",
    "MSG_REG_SHO",
    "MSG_MKT_PARTICIPANT",
    "MSG_MWCB_DECLINE",
    "MSG_MWCB_STATUS",
    "MSG_IPO_QUOTING",
    "MSG_LULD_COLLAR",
    "MSG_OPERATIONAL_HALT",
    "MSG_ADD_ORDER",
    "MSG_ADD_ORDER_MPID",
    "MSG_ORDER_EXECUTED",
    "MSG_ORDER_EXEC_PRICE",
    "MSG_ORDER_CANCEL",
    "MSG_ORDER_DELETE",
    "MSG_ORDER_REPLACE",
    "MSG_TRADE",
    "MSG_CROSS_TRADE",
    "MSG_BROKEN_TRADE",
    "MSG_NOII",
    "MSG_RPII",
    "SIDE_CHAR_BUY",
    "SIDE_CHAR_SELL",
    "SYSEV_START_MESSAGES",
    "SYSEV_START_SYSTEM",
    "SYSEV_START_MARKET",
    "SYSEV_END_MARKET",
    "SYSEV_END_SYSTEM",
    "SYSEV_END_MESSAGES",
    "TRADE_ACT_HALTED",
    "TRADE_ACT_PAUSED",
    "TRADE_ACT_QUOTEONLY",
    "TRADE_ACT_TRADING",
    "SHO_NONE",
    "SHO_INTRADAY",
    "SHO_RESTRICTED",
)


def crosscheck_against_rtl(pkg: SvPackage | None = None) -> list[str]:
    """Compare every mirrored constant against ``rtl/pkg/itch_pkg.sv``.

    Returns the list of mismatch descriptions (empty == mirror is correct).
    Raising is the caller's choice so that a test can report ALL mismatches at
    once instead of one per run.
    """
    if pkg is None:
        pkg = load_package(ITCH_PKG_SV)
    here = globals()
    problems: list[str] = []

    for name in _INT_PARAMS:
        rtl = pkg.params.get(name)
        if rtl is None:
            problems.append(f"itch_pkg.sv no longer defines {name}")
        elif rtl != here[name]:
            problems.append(f"{name}: mirror={here[name]} itch_pkg.sv={rtl}")

    for name in _CHAR_PARAMS:
        rtl = pkg.params.get(name)
        if rtl is None:
            problems.append(f"itch_pkg.sv no longer defines {name}")
        elif rtl != ord(here[name]):
            problems.append(
                f"{name}: mirror={here[name]!r}({ord(here[name])}) itch_pkg.sv={rtl}"
            )

    # Internal consistency of the length table itself.
    if MSG_LEN and max(MSG_LEN.values()) != LEN_MAX:
        problems.append(
            f"LEN_MAX={LEN_MAX} but the longest message in MSG_LEN is "
            f"{max(MSG_LEN.values())}"
        )
    if set(MSG_LEN) != set(MSG_NAME):
        problems.append("MSG_LEN and MSG_NAME cover different type codes")

    return problems


#: True when the RTL package was present and every mirrored value matched.
#: ⚠️ A test suite MUST assert this is True — see tests/test_contract_mirror.py.
#: It is False (with no exception) when ``host/`` is deployed without ``rtl/``,
#: which is legitimate in production but must never be the case in CI.
RTL_CROSSCHECK_DONE: bool = False

if ITCH_PKG_SV.is_file():
    _problems = crosscheck_against_rtl()
    if _problems:
        raise ContractMismatch(
            "host/pymodel/itch_pkg_mirror.py has drifted from "
            f"{ITCH_PKG_SV}:\n  " + "\n  ".join(_problems)
        )
    RTL_CROSSCHECK_DONE = True
