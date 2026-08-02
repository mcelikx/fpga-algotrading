#!/usr/bin/env python3
"""Reference Nasdaq TotalView-ITCH 5.0 / MoldUDP64 parser.

Project : FPGA Algorithmic Trading System (Nasdaq Equities)
Governs : manuals/08-nasdaq/04-totalview-itch-5.0.md
          manuals/06-operations/04-testing-strategy.md  §3, §4, §11
Mirrors : rtl/pkg/itch_pkg.sv   <-- the RTL's copy of the same constants

Reads a pcap / pcapng capture (optionally gzipped) or a raw length-prefixed
ITCH file, and yields decoded messages.

===============================================================================
WHAT THIS FILE IS FOR
===============================================================================
This is the *corpus inspection* parser. It is the thing you point at a capture
to answer "what is actually in this file, and is any of it wrong?" — before any
of it becomes a regression fixture. It is deliberately paranoid: it decodes
every message type, cross-checks every declared length, and refuses to skip
anything silently.

It is NOT the golden model. The golden decoder (TASKS.md P1.2,
``host/golden/itch_decoder.*``) is written separately, from the spec, by a
different reader, precisely so that a shared misunderstanding cannot hide.
See manuals/06-operations/04-testing-strategy.md §4:

    "A golden model that inherits the RTL's misunderstanding tests nothing."

Do not import this module into the golden model, and do not import the golden
model here.

===============================================================================
THE ONE RULE THIS PARSER EXISTS TO ENFORCE
===============================================================================
    ⚠️ EVERY MESSAGE'S DECLARED LENGTH IS CROSS-CHECKED AGAINST ITS TYPE,
       AND EVERY MISMATCH IS REPORTED. NOTHING IS EVER SILENTLY SKIPPED.

In ITCH 5.0 the message length is a pure function of the message type: there
are no repeating groups, no optional fields, no varints. The MoldUDP64 block
length prefix is therefore *redundant* with the type byte — which makes it a
free integrity check, and makes ignoring it inexcusable.

A capture where ``declared_length != spec_length(type)`` means one of:
  * the capture is corrupt,
  * the venue has revised the spec and this table is stale,
  * or this table was wrong from the start.

All three are things you must be told about. A parser that "helpfully" skips
the bad message desynchronizes the stream and produces a book that is subtly,
confidently wrong — the exact failure mode
manuals/06-operations/04-testing-strategy.md §3 calls out as the most dangerous
decoder bug class there is.

Anomalies are therefore *counted, classified, and retained* — never dropped.
See :class:`Diagnostics`.

===============================================================================
⚠️  VERIFY BEFORE TRUSTING ANY NUMBER IN THIS FILE
===============================================================================
Message type codes, field orders, field widths, byte offsets, message lengths
and enumeration values are all defined by the **Nasdaq TotalView-ITCH 5.0
specification** (https://nasdaqtrader.com/Trading/TradingSpecs) and by the
**MoldUDP64 specification** on the same site. Both are versioned and amended.

Every constant below carries a ``VERIFY:`` marker naming what to check it
against. They currently agree with ``rtl/pkg/itch_pkg.sv`` and with
manuals/08-nasdaq/04-totalview-itch-5.0.md §4 — which is a consistency check
between three files in this repo, and is *not* the same thing as agreeing with
Nasdaq. Confirm against the spec PDF once, in one place, and lock it down
(see manual §9.4 on generating all three headers from one source).

The layout table is self-checked at import time: the sum of each message's
field widths plus the 11-byte common prefix must equal that type's declared
length. A typo in either fails loudly on import rather than at 3 a.m. in a
regression. See :func:`_selfcheck_layouts`.

===============================================================================
Prices and timestamps
===============================================================================
Prices are 4-byte big-endian unsigned integers with **4 implied decimals**
(``trading_pkg::PRICE_SCALE = 10000``): ``$187.5000`` on the wire is
``1_875_000``. They are kept as scaled integers everywhere in this file. There
is no floating point in the decode path — CLAUDE.md §5.3. Formatting to a
decimal string happens only in :func:`format_price`, using integer division.

⚠️ The price scale is NOT uniform across message types. The MWCB Decline Level
(``V``) message carries 8-byte levels whose implied-decimal count differs from
the ordinary 4. This parser reports those fields as raw integers and marks them
unverified rather than guessing a scale. See :data:`MWCB_LEVEL_SCALE`.

Timestamps are 6 bytes, nanoseconds since midnight US/Eastern. 09:30:00 ET is
``34_200 * 10**9``.

===============================================================================
Dependencies
===============================================================================
Standard library only, deliberately. Reasons, in order of weight:

1. Nothing to pin. manuals/01-fpga-design/05-verification-and-simulation.md §7
   rule 5: "pin everything ... A suite whose results change on a tool upgrade
   is not a regression suite."
2. scapy and dpkt *interpret* packets. This tool must report the exact bytes
   that were on the wire, including malformed ones that a library would
   normalize, reassemble, or refuse. A library that "fixes" a truncated frame
   deletes the finding.
3. It is a few hundred lines of struct unpacking.

Usage
-----
    python3 tools/pcap/itch_parse.py CAPTURE.pcap --summary
    python3 tools/pcap/itch_parse.py CAPTURE.pcap.gz --types A,U,D --limit 20
    python3 tools/pcap/itch_parse.py CAPTURE.pcap --json --limit 1000 > msgs.jsonl
    python3 tools/pcap/itch_parse.py ITCH_FILE.bin --raw --summary
    python3 tools/pcap/itch_parse.py CAPTURE.pcap --anomalies-only

Exit status: 0 = parsed with no ERROR-severity anomalies, 1 = errors found,
2 = the file could not be read at all. Suitable as a CI corpus gate.
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import struct
import sys
from collections import Counter
from dataclasses import dataclass, field
from typing import Any, BinaryIO, Callable, Dict, Iterator, List, Optional, Sequence, Tuple

__all__ = [
    "PRICE_SCALE",
    "MOLD_HDR_LEN",
    "ITCH_MSG_LEN",
    "ITCH_MSG_NAME",
    "Anomaly",
    "Severity",
    "Diagnostics",
    "ParsedMessage",
    "MoldPacket",
    "ItchReader",
    "iter_messages",
    "decode_itch_message",
    "format_price",
    "format_ts_ns",
]

VERSION = "1.0.0"

# =============================================================================
# 1. MoldUDP64 transport framing
# =============================================================================
# VERIFY: MoldUDP64 specification, nasdaqtrader.com. Mirrors itch_pkg.sv §1.
#
#   [0..9]   Session          10 bytes, alphanumeric
#   [10..17] Sequence Number   8 bytes, big-endian, of the FIRST message
#   [18..19] Message Count     2 bytes, big-endian
#   [20..]   N blocks, each: 2-byte big-endian length + payload
MOLD_SESSION_OFF = 0
MOLD_SESSION_LEN = 10
MOLD_SEQNUM_OFF = 10
MOLD_SEQNUM_LEN = 8
MOLD_MSGCNT_OFF = 18
MOLD_MSGCNT_LEN = 2
MOLD_HDR_LEN = 20

#: Message Count 0 = heartbeat (keeps the sequence alive; NOT a gap).
#: VERIFY: MoldUDP64 spec. Mirrors itch_pkg::MOLD_CNT_HEARTBEAT.
MOLD_CNT_HEARTBEAT = 0x0000
#: Message Count 0xFFFF = end-of-session marker.
#: VERIFY: MoldUDP64 spec. Mirrors itch_pkg::MOLD_CNT_ENDSESS.
MOLD_CNT_ENDSESS = 0xFFFF

# =============================================================================
# 2. ITCH 5.0 common prefix and scale factors
# =============================================================================
# VERIFY: TotalView-ITCH 5.0 spec, "Common fields". Mirrors itch_pkg.sv §4.
#
#   [0]      Message Type      1 byte  (ASCII, case-sensitive)
#   [1..2]   Stock Locate      2 bytes big-endian  <-- the dense symbol index
#   [3..4]   Tracking Number   2 bytes big-endian  (Nasdaq-internal)
#   [5..10]  Timestamp         6 bytes big-endian, ns since midnight ET
OFF_MSG_TYPE = 0
OFF_LOCATE = 1
OFF_TRACKING = 3
OFF_TIMESTAMP = 5
LEN_TIMESTAMP = 6
HDR_PREFIX_LEN = 11

#: Implied decimals on an ordinary 4-byte ITCH price.
#: Mirrors trading_pkg::PRICE_SCALE. VERIFY: spec, per-field.
PRICE_SCALE = 10_000

#: ⚠️ The MWCB Decline Level ('V') message's three levels are 8 bytes each and
#: use a DIFFERENT implied-decimal count from the ordinary 4. This parser does
#: not guess it. Set this to the value from the spec once verified, and the
#: 'V' fields will start being formatted as prices instead of raw integers.
#: VERIFY: TotalView-ITCH 5.0 spec, MWCB Decline Level message.
MWCB_LEVEL_SCALE: Optional[int] = None

#: Nanoseconds in a day. A timestamp at or above this is out of range and is
#: reported — it means a decode misalignment far more often than a venue bug.
NS_PER_DAY = 86_400 * 1_000_000_000

# =============================================================================
# 3. Message catalogue: type -> (name, length INCLUDING the type byte)
# =============================================================================
# VERIFY: TotalView-ITCH 5.0 spec, per-message "Length" field.
#         Mirrors itch_pkg::LEN_* exactly; a divergence between this table and
#         itch_pkg.sv is a repo-level bug worth failing a build over.
#
# ⚠️ Type codes are case-sensitive: 'h' (Operational Halt) and 'H' (Stock
#    Trading Action) are DIFFERENT messages.
ITCH_MSG_LEN: Dict[str, int] = {
    "S": 12,   # System Event
    "R": 39,   # Stock Directory
    "H": 25,   # Stock Trading Action
    "Y": 20,   # Reg SHO Restriction
    "L": 26,   # Market Participant Position
    "V": 35,   # MWCB Decline Level
    "W": 12,   # MWCB Status
    "K": 28,   # IPO Quoting Period Update
    "J": 35,   # LULD Auction Collar
    "h": 21,   # Operational Halt
    "A": 36,   # Add Order — no MPID
    "F": 40,   # Add Order — with MPID
    "E": 31,   # Order Executed
    "C": 36,   # Order Executed with Price
    "X": 23,   # Order Cancel (partial reduce)
    "D": 19,   # Order Delete (full remove)
    "U": 35,   # Order Replace (delete old ref, insert new ref)
    "P": 44,   # Trade — non-cross (statistics only; NO book effect)
    "Q": 40,   # Cross Trade
    "B": 19,   # Broken Trade
    "I": 50,   # NOII (net order imbalance indicator)
    "N": 20,   # RPII (retail price improvement interest)
}

ITCH_MSG_NAME: Dict[str, str] = {
    "S": "SystemEvent",
    "R": "StockDirectory",
    "H": "StockTradingAction",
    "Y": "RegSHORestriction",
    "L": "MarketParticipantPosition",
    "V": "MWCBDeclineLevel",
    "W": "MWCBStatus",
    "K": "IPOQuotingPeriodUpdate",
    "J": "LULDAuctionCollar",
    "h": "OperationalHalt",
    "A": "AddOrder",
    "F": "AddOrderMPID",
    "E": "OrderExecuted",
    "C": "OrderExecutedWithPrice",
    "X": "OrderCancel",
    "D": "OrderDelete",
    "U": "OrderReplace",
    "P": "TradeNonCross",
    "Q": "CrossTrade",
    "B": "BrokenTrade",
    "I": "NOII",
    "N": "RPII",
}

#: Types that mutate the order book. Mirrors itch_pkg::is_book_msg().
#: ⚠️ 'P' is NOT here: a non-cross Trade reports an execution against
#:    non-displayed liquidity that was never in the displayed book. Applying it
#:    corrupts the book; ignoring it for volume understates volume.
BOOK_MSG_TYPES = frozenset("AFECXDU")

#: The maximum ITCH message length. trading_pkg::ITCH_MSG_MAX_BYTES is 64, i.e.
#: the fabric's one-beat message bus has headroom above this.
LEN_MAX = max(ITCH_MSG_LEN.values())

# =============================================================================
# 4. Field layouts
# =============================================================================
# Field widths and ORDER come from manuals/08-nasdaq/04-totalview-itch-5.0.md §4
# and agree with the offsets in itch_pkg.sv §4 for A/E/X/D/U.
#
# Offsets are DERIVED by accumulation, not typed in — a hand-typed offset table
# is exactly how off-by-one decoder bugs are born. The accumulated total is
# checked against ITCH_MSG_LEN at import time (:func:`_selfcheck_layouts`).
#
# Field kinds:
#   u8/u16/u32/u48/u64  big-endian unsigned integer
#   px4                 4-byte price, PRICE_SCALE implied decimals
#   px8v                8-byte price, scale UNVERIFIED (see MWCB_LEVEL_SCALE)
#   ch                  1 ASCII character (enumeration code)
#   a<N>                N-byte ASCII, right-padded with spaces
_KIND_WIDTH = {"u8": 1, "u16": 2, "u32": 4, "u48": 6, "u64": 8, "px4": 4, "px8v": 8, "ch": 1}


def _w(kind: str) -> int:
    if kind.startswith("a"):
        return int(kind[1:])
    return _KIND_WIDTH[kind]


# (field_name, kind) in wire order, starting immediately after the 11-byte
# common prefix. VERIFY: spec, per-message field table.
_BODY: Dict[str, Sequence[Tuple[str, str]]] = {
    # --- Administrative / reference data -------------------------------------
    "S": (("event_code", "ch"),),
    "R": (
        ("stock", "a8"), ("market_category", "ch"), ("financial_status", "ch"),
        ("round_lot_size", "u32"), ("round_lots_only", "ch"),
        ("issue_classification", "ch"), ("issue_subtype", "a2"),
        ("authenticity", "ch"), ("short_sale_threshold", "ch"),
        ("ipo_flag", "ch"), ("luld_tier", "ch"), ("etp_flag", "ch"),
        ("etp_leverage_factor", "u32"), ("inverse_indicator", "ch"),
    ),
    "H": (
        ("stock", "a8"), ("trading_state", "ch"), ("reserved", "ch"),
        ("reason", "a4"),
    ),
    "Y": (("stock", "a8"), ("sho_action", "ch")),
    "L": (
        ("mpid", "a4"), ("stock", "a8"), ("primary_market_maker", "ch"),
        ("market_maker_mode", "ch"), ("market_participant_state", "ch"),
    ),
    # ⚠️ px8v: implied decimals differ from the usual 4. Not guessed here.
    "V": (("level_1", "px8v"), ("level_2", "px8v"), ("level_3", "px8v")),
    "W": (("breached_level", "ch"),),
    "K": (
        ("stock", "a8"), ("ipo_release_time", "u32"),
        ("ipo_release_qualifier", "ch"), ("ipo_price", "px4"),
    ),
    "J": (
        ("stock", "a8"), ("auction_collar_reference", "px4"),
        ("upper_auction_collar", "px4"), ("lower_auction_collar", "px4"),
        ("auction_collar_extension", "u32"),
    ),
    "h": (("stock", "a8"), ("market_code", "ch"), ("operational_halt_action", "ch")),
    # --- Order book messages — the fast path ---------------------------------
    "A": (
        ("order_ref", "u64"), ("side", "ch"), ("shares", "u32"),
        ("stock", "a8"), ("price", "px4"),
    ),
    "F": (
        ("order_ref", "u64"), ("side", "ch"), ("shares", "u32"),
        ("stock", "a8"), ("price", "px4"), ("attribution", "a4"),
    ),
    "E": (("order_ref", "u64"), ("executed_shares", "u32"), ("match_number", "u64")),
    "C": (
        ("order_ref", "u64"), ("executed_shares", "u32"), ("match_number", "u64"),
        ("printable", "ch"), ("execution_price", "px4"),
    ),
    "X": (("order_ref", "u64"), ("cancelled_shares", "u32")),
    "D": (("order_ref", "u64"),),
    # ⚠️ 'U' removes original_order_ref AND creates new_order_ref with LOST
    #    queue priority. A book that treats it as an in-place modify leaks
    #    references and drifts. See manual §7 and itch_pkg.sv.
    "U": (
        ("original_order_ref", "u64"), ("new_order_ref", "u64"),
        ("shares", "u32"), ("price", "px4"),
    ),
    # --- Trade and auction messages ------------------------------------------
    "P": (
        ("order_ref", "u64"), ("side", "ch"), ("shares", "u32"),
        ("stock", "a8"), ("price", "px4"), ("match_number", "u64"),
    ),
    "Q": (
        ("shares", "u64"), ("stock", "a8"), ("cross_price", "px4"),
        ("match_number", "u64"), ("cross_type", "ch"),
    ),
    "B": (("match_number", "u64"),),
    "I": (
        ("paired_shares", "u64"), ("imbalance_shares", "u64"),
        ("imbalance_direction", "ch"), ("stock", "a8"), ("far_price", "px4"),
        ("near_price", "px4"), ("current_reference_price", "px4"),
        ("cross_type", "ch"), ("price_variation_indicator", "ch"),
    ),
    "N": (("stock", "a8"), ("interest_flag", "ch")),
}


@dataclass(frozen=True)
class _Field:
    name: str
    off: int          # absolute offset from the start of the message
    width: int
    kind: str


def _build_layouts() -> Dict[str, Tuple[_Field, ...]]:
    """Accumulate field offsets from widths. Never type an offset by hand."""
    out: Dict[str, Tuple[_Field, ...]] = {}
    for t, body in _BODY.items():
        off = HDR_PREFIX_LEN
        flds: List[_Field] = []
        for name, kind in body:
            width = _w(kind)
            flds.append(_Field(name, off, width, kind))
            off += width
        out[t] = tuple(flds)
    return out


ITCH_LAYOUT: Dict[str, Tuple[_Field, ...]] = _build_layouts()


def _selfcheck_layouts() -> None:
    """Fail loudly at import if the layout table contradicts the length table.

    Two independent statements of the same fact — the per-type total length,
    and the list of field widths — must agree. When they do not, one of them is
    a typo, and a typo here is a decoder that works on 99.9 % of the feed and
    produces a catastrophically wrong price on the rest
    (manuals/06-operations/04-testing-strategy.md §3).
    """
    problems: List[str] = []
    for t, declared in sorted(ITCH_MSG_LEN.items()):
        flds = ITCH_LAYOUT.get(t)
        if flds is None:
            problems.append(f"type {t!r}: length declared ({declared}) but no field layout")
            continue
        end = flds[-1].off + flds[-1].width if flds else HDR_PREFIX_LEN
        if end != declared:
            problems.append(
                f"type {t!r} ({ITCH_MSG_NAME.get(t, '?')}): fields end at byte {end} "
                f"but ITCH_MSG_LEN says {declared} (delta {end - declared:+d})"
            )
    for t in sorted(ITCH_LAYOUT):
        if t not in ITCH_MSG_LEN:
            problems.append(f"type {t!r}: field layout present but no declared length")
    if max((f[-1].off + f[-1].width) for f in ITCH_LAYOUT.values()) != LEN_MAX:
        problems.append("LEN_MAX does not match the widest layout")
    if problems:
        raise AssertionError(
            "itch_parse.py layout self-check FAILED — the message table is "
            "internally inconsistent and MUST NOT be used to parse a corpus:\n  "
            + "\n  ".join(problems)
        )


_selfcheck_layouts()


# =============================================================================
# 5. Diagnostics — anomalies are counted and classified, never swallowed
# =============================================================================
class Severity:
    """Anomaly severity. INFO is normal protocol traffic worth counting."""

    INFO = "INFO"
    WARN = "WARN"
    ERROR = "ERROR"


#: code -> (severity, one-line meaning). CLAUDE.md §5.7: every drop, error and
#: rejection is counted and attributable. That rule applies to the tooling too:
#: if this parser discards a byte, there is a counter for it.
ANOMALY_CATALOG: Dict[str, Tuple[str, str]] = {
    # --- capture container ---------------------------------------------------
    "PCAP_TRUNCATED_RECORD": (Severity.ERROR, "capture ends mid-record; file is truncated"),
    "PCAP_SNAPLEN_CLIPPED": (Severity.WARN, "caplen < wirelen: capture was snaplen-clipped, bytes are missing"),
    "PCAP_ZERO_LENGTH": (Severity.WARN, "zero-length packet record"),
    "PCAPNG_UNKNOWN_BLOCK": (Severity.INFO, "pcapng block type skipped"),
    "LINKTYPE_UNSUPPORTED": (Severity.ERROR, "link-layer type this parser cannot decode"),
    # --- L2 / L3 / L4 --------------------------------------------------------
    "ETH_SHORT": (Severity.WARN, "frame shorter than an Ethernet header"),
    "ETH_NOT_IPV4": (Severity.INFO, "non-IPv4 ethertype, ignored for ITCH"),
    "VLAN_DEPTH": (Severity.WARN, "more stacked VLAN tags than this parser unwinds"),
    "IP_SHORT": (Severity.WARN, "truncated IPv4 header"),
    "IP_BAD_IHL": (Severity.WARN, "IPv4 IHL below the 20-byte minimum"),
    "IP_FRAGMENT": (Severity.ERROR, "IPv4 fragment: not reassembled, MoldUDP64 payload incomplete"),
    "IP_NOT_UDP": (Severity.INFO, "IPv4 protocol is not UDP, ignored for ITCH"),
    "IP_LEN_MISMATCH": (Severity.WARN, "IPv4 total-length disagrees with captured bytes"),
    "UDP_SHORT": (Severity.WARN, "truncated UDP header"),
    "UDP_LEN_MISMATCH": (Severity.WARN, "UDP length disagrees with captured payload"),
    # --- MoldUDP64 -----------------------------------------------------------
    "MOLD_SHORT_HEADER": (Severity.ERROR, "UDP payload shorter than the 20-byte MoldUDP64 header"),
    "MOLD_BLOCK_TRUNCATED": (Severity.ERROR, "block length prefix runs past the end of the packet"),
    "MOLD_BLOCK_ZERO_LEN": (Severity.ERROR, "zero-length MoldUDP64 block"),
    "MOLD_COUNT_MISMATCH": (Severity.ERROR, "fewer blocks present than the header's message count"),
    "MOLD_TRAILING_BYTES": (Severity.WARN, "bytes left over after the declared message count"),
    "MOLD_HEARTBEAT": (Severity.INFO, "message count 0: heartbeat, NOT a gap"),
    "MOLD_END_OF_SESSION": (Severity.INFO, "end-of-session sentinel count"),
    "MOLD_SESSION_CHANGE": (Severity.WARN, "MoldUDP64 session identifier changed mid-capture"),
    # --- sequencing ----------------------------------------------------------
    "SEQ_GAP": (Severity.ERROR, "sequence numbers skipped: messages are missing from this stream"),
    "SEQ_DUPLICATE": (Severity.INFO, "sequence already seen (normal for a merged A/B capture)"),
    "SEQ_REGRESSION": (Severity.WARN, "sequence number went backwards beyond a plain duplicate"),
    # --- ITCH ----------------------------------------------------------------
    "ITCH_UNKNOWN_TYPE": (Severity.WARN, "message type not in the catalogue: skipped by DECLARED length, counted"),
    "ITCH_LENGTH_MISMATCH": (Severity.ERROR, "declared block length != the spec length for this type"),
    "ITCH_SHORT_BODY": (Severity.ERROR, "message body shorter than its own declared length"),
    "ITCH_TS_OUT_OF_RANGE": (Severity.WARN, "timestamp >= 24h in nanoseconds: likely a decode misalignment"),
    "ITCH_BAD_SIDE": (Severity.WARN, "buy/sell indicator is neither 'B' nor 'S'"),
    "ITCH_ZERO_LOCATE": (Severity.INFO, "stock locate 0 (used by some system-wide messages)"),
    # --- raw ITCH file mode --------------------------------------------------
    "RAW_TRUNCATED": (Severity.ERROR, "raw ITCH file ends mid-message"),
}


@dataclass(frozen=True)
class Anomaly:
    """One thing that was wrong, or noteworthy, at one byte position."""

    code: str
    detail: str
    pkt_index: int = -1          # index of the capture record, 0-based
    file_offset: int = -1        # byte offset of the record in the capture
    seq: Optional[int] = None    # MoldUDP64 sequence, when known
    msg_type: Optional[str] = None

    @property
    def severity(self) -> str:
        return ANOMALY_CATALOG.get(self.code, (Severity.ERROR, ""))[0]

    def __str__(self) -> str:  # pragma: no cover - formatting only
        loc = f"pkt#{self.pkt_index}"
        if self.file_offset >= 0:
            loc += f"@0x{self.file_offset:x}"
        if self.seq is not None:
            loc += f" seq={self.seq}"
        if self.msg_type:
            loc += f" type={self.msg_type!r}"
        return f"[{self.severity:5s}] {self.code:24s} {loc}: {self.detail}"

    def to_dict(self) -> Dict[str, Any]:
        return {
            "code": self.code,
            "severity": self.severity,
            "detail": self.detail,
            "pkt_index": self.pkt_index,
            "file_offset": self.file_offset,
            "seq": self.seq,
            "msg_type": self.msg_type,
        }


@dataclass
class Diagnostics:
    """Every anomaly is counted; a bounded sample of each is retained.

    Counts are exact and unbounded. Retained examples are capped per code
    (``keep_per_code``) so that pointing this at a multi-gigabyte capture with
    a systemic fault does not exhaust memory — the count still tells you the
    true magnitude. Nothing is ever *un*counted.
    """

    keep_per_code: int = 50
    counts: Counter = field(default_factory=Counter)
    examples: Dict[str, List[Anomaly]] = field(default_factory=dict)
    on_anomaly: Optional[Callable[[Anomaly], None]] = None

    def add(self, a: Anomaly) -> None:
        self.counts[a.code] += 1
        bucket = self.examples.setdefault(a.code, [])
        if len(bucket) < self.keep_per_code:
            bucket.append(a)
        if self.on_anomaly is not None:
            self.on_anomaly(a)

    def note(self, code: str, detail: str, **kw: Any) -> None:
        self.add(Anomaly(code=code, detail=detail, **kw))

    # -- queries --------------------------------------------------------------
    def count_by_severity(self, sev: str) -> int:
        return sum(
            n for c, n in self.counts.items()
            if ANOMALY_CATALOG.get(c, (Severity.ERROR, ""))[0] == sev
        )

    @property
    def errors(self) -> int:
        return self.count_by_severity(Severity.ERROR)

    @property
    def warnings(self) -> int:
        return self.count_by_severity(Severity.WARN)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "counts": dict(sorted(self.counts.items())),
            "by_severity": {
                s: self.count_by_severity(s)
                for s in (Severity.ERROR, Severity.WARN, Severity.INFO)
            },
            "examples": {
                c: [a.to_dict() for a in v] for c, v in sorted(self.examples.items())
            },
            "examples_truncated": {
                c: max(0, self.counts[c] - len(v)) for c, v in sorted(self.examples.items())
            },
        }


# =============================================================================
# 6. Decoded objects
# =============================================================================
@dataclass
class MoldPacket:
    """One MoldUDP64 downstream packet, before its blocks are decoded."""

    session: str
    seq: int              # sequence number of the FIRST message in this packet
    count: int            # declared message count (0 = heartbeat, 0xFFFF = EOS)
    payload: bytes        # bytes after the 20-byte header
    pkt_index: int
    file_offset: int
    ts_ns: int            # CAPTURE timestamp, ns since the Unix epoch
    src: str = ""
    dst: str = ""
    src_port: int = 0
    dst_port: int = 0

    @property
    def stream_key(self) -> Tuple[str, int, str]:
        """Identity of the feed line this packet arrived on.

        A/B are byte-identical streams on different multicast groups. Keying
        the sequence tracker on the destination group tracks each line
        independently, so a gap on A alone is visible as a gap on A —
        which is exactly what the arbitration logic has to survive
        (manuals/02-networking/03-multicast-feeds-and-arbitration.md).
        """
        return (self.dst, self.dst_port, self.session)


@dataclass
class ParsedMessage:
    """One decoded ITCH message, with its provenance."""

    msg_type: str
    name: str
    seq: int                    # MoldUDP64 sequence of THIS message
    locate: int
    tracking: int
    ts_ns: int                  # exchange timestamp, ns since midnight ET
    fields: Dict[str, Any]
    declared_len: int           # from the MoldUDP64 block length prefix
    spec_len: Optional[int]     # from ITCH_MSG_LEN, None if type is unknown
    length_ok: bool
    raw: bytes
    pkt_index: int
    pkt_ts_ns: int              # capture timestamp
    index_in_packet: int
    session: str = ""
    src: str = ""
    dst: str = ""
    dst_port: int = 0

    @property
    def is_book_msg(self) -> bool:
        return self.msg_type in BOOK_MSG_TYPES

    def to_dict(self, include_raw: bool = False) -> Dict[str, Any]:
        d: Dict[str, Any] = {
            "seq": self.seq,
            "type": self.msg_type,
            "name": self.name,
            "locate": self.locate,
            "tracking": self.tracking,
            "ts_ns": self.ts_ns,
            "ts": format_ts_ns(self.ts_ns),
            "declared_len": self.declared_len,
            "spec_len": self.spec_len,
            "length_ok": self.length_ok,
            "pkt_index": self.pkt_index,
            "pkt_ts_ns": self.pkt_ts_ns,
            "index_in_packet": self.index_in_packet,
            "fields": self.fields,
        }
        if include_raw:
            d["raw"] = self.raw.hex()
        return d

    def __str__(self) -> str:  # pragma: no cover - formatting only
        parts = []
        for k, v in self.fields.items():
            if k.endswith("price") or k == "price":
                parts.append(f"{k}={format_price(v)}" if isinstance(v, int) else f"{k}={v}")
            else:
                parts.append(f"{k}={v}")
        flag = "" if self.length_ok else "  ⚠️LEN"
        return (
            f"seq={self.seq:<12d} {format_ts_ns(self.ts_ns)} "
            f"{self.msg_type} {self.name:<26s} locate={self.locate:<6d} "
            + " ".join(parts) + flag
        )


# =============================================================================
# 7. Field decoding
# =============================================================================
def _be(b: bytes) -> int:
    return int.from_bytes(b, "big", signed=False)


def format_price(px: int, scale: int = PRICE_SCALE) -> str:
    """Integer-only decimal rendering. No float ever touches a price."""
    if scale <= 0:
        return str(px)
    digits = len(str(scale)) - 1
    return f"{px // scale}.{px % scale:0{digits}d}"


def format_ts_ns(ts: int) -> str:
    """ITCH timestamp (ns since midnight ET) as HH:MM:SS.nnnnnnnnn."""
    if ts < 0:
        return str(ts)
    s, ns = divmod(ts, 1_000_000_000)
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{sec:02d}.{ns:09d}"


def decode_itch_message(
    buf: bytes,
    diag: Optional[Diagnostics] = None,
    *,
    pkt_index: int = -1,
    file_offset: int = -1,
    seq: int = -1,
) -> Optional[ParsedMessage]:
    """Decode one complete ITCH message from ``buf``.

    ``buf`` must be exactly the message, starting at the type byte. Returns
    ``None`` only if the buffer is too short to hold even the common prefix —
    in which case an anomaly is recorded. Unknown types return a
    :class:`ParsedMessage` with ``fields={}`` and ``spec_len=None``: an unknown
    type is *not* an error (Nasdaq adds message types), but it is counted, and
    it is skipped by its declared length, never by a guess.
    """
    d = diag if diag is not None else Diagnostics()
    n = len(buf)
    if n < HDR_PREFIX_LEN:
        d.note("ITCH_SHORT_BODY", f"{n} bytes, less than the {HDR_PREFIX_LEN}-byte common prefix",
               pkt_index=pkt_index, file_offset=file_offset, seq=seq if seq >= 0 else None)
        return None

    t = chr(buf[OFF_MSG_TYPE])
    locate = _be(buf[OFF_LOCATE:OFF_LOCATE + 2])
    tracking = _be(buf[OFF_TRACKING:OFF_TRACKING + 2])
    ts = _be(buf[OFF_TIMESTAMP:OFF_TIMESTAMP + LEN_TIMESTAMP])
    spec_len = ITCH_MSG_LEN.get(t)
    name = ITCH_MSG_NAME.get(t, "UNKNOWN")

    if ts >= NS_PER_DAY:
        d.note("ITCH_TS_OUT_OF_RANGE",
               f"timestamp {ts} ns >= 24h; check byte alignment",
               pkt_index=pkt_index, file_offset=file_offset,
               seq=seq if seq >= 0 else None, msg_type=t)
    if locate == 0:
        d.note("ITCH_ZERO_LOCATE", "stock locate is 0",
               pkt_index=pkt_index, file_offset=file_offset,
               seq=seq if seq >= 0 else None, msg_type=t)

    fields: Dict[str, Any] = {}
    if spec_len is None:
        d.note("ITCH_UNKNOWN_TYPE",
               f"type {t!r} (0x{buf[0]:02x}) not in the catalogue; "
               f"{n} declared bytes skipped intact",
               pkt_index=pkt_index, file_offset=file_offset,
               seq=seq if seq >= 0 else None, msg_type=t)
    else:
        if n < spec_len:
            d.note("ITCH_SHORT_BODY",
                   f"type {t!r} needs {spec_len} bytes, only {n} present",
                   pkt_index=pkt_index, file_offset=file_offset,
                   seq=seq if seq >= 0 else None, msg_type=t)
        else:
            for f in ITCH_LAYOUT[t]:
                raw = buf[f.off:f.off + f.width]
                if f.kind == "ch":
                    fields[f.name] = raw.decode("latin-1")
                elif f.kind.startswith("a"):
                    # ASCII, right-padded with spaces. Keep the stripped form
                    # for readability; the raw bytes stay in ParsedMessage.raw.
                    fields[f.name] = raw.decode("latin-1").rstrip(" ")
                else:
                    fields[f.name] = _be(raw)
            side = fields.get("side")
            if side is not None and side not in ("B", "S"):
                d.note("ITCH_BAD_SIDE", f"side={side!r} on type {t!r}",
                       pkt_index=pkt_index, file_offset=file_offset,
                       seq=seq if seq >= 0 else None, msg_type=t)

    return ParsedMessage(
        msg_type=t,
        name=name,
        seq=seq,
        locate=locate,
        tracking=tracking,
        ts_ns=ts,
        fields=fields,
        declared_len=n,
        spec_len=spec_len,
        length_ok=(spec_len is not None and spec_len == n),
        raw=bytes(buf),
        pkt_index=pkt_index,
        pkt_ts_ns=0,
        index_in_packet=0,
    )


# =============================================================================
# 8. Capture container readers (classic pcap and pcapng)
# =============================================================================
LINKTYPE_ETHERNET = 1
LINKTYPE_RAW = 101
LINKTYPE_LINUX_SLL = 113
LINKTYPE_IPV4 = 228
LINKTYPE_LINUX_SLL2 = 276

#: VERIFY: link-layer type numbers are assigned by tcpdump.org
#: (https://www.tcpdump.org/linktypes.html). A colo capture from an optical tap
#: is usually LINKTYPE_ETHERNET; some host capture stacks emit LINUX_SLL.
_SUPPORTED_LINKTYPES = {
    LINKTYPE_ETHERNET, LINKTYPE_RAW, LINKTYPE_LINUX_SLL,
    LINKTYPE_IPV4, LINKTYPE_LINUX_SLL2,
}

PCAP_MAGIC_US_LE = 0xA1B2C3D4      # microsecond resolution
PCAP_MAGIC_NS_LE = 0xA1B23C4D      # nanosecond resolution
PCAPNG_SHB_TYPE = 0x0A0D0D0A
PCAPNG_BOM = 0x1A2B3C4D


@dataclass
class CaptureRecord:
    """One packet as it came out of the capture container."""

    index: int
    file_offset: int
    ts_ns: int          # ns since the Unix epoch
    wirelen: int
    data: bytes
    linktype: int


def open_maybe_gzip(path: str) -> BinaryIO:
    """Open a capture, transparently decompressing .gz.

    Detection is by magic bytes, not by extension: a corpus file that was
    gzipped and renamed still has to open.
    """
    fh = open(path, "rb")
    head = fh.read(2)
    fh.seek(0)
    if head == b"\x1f\x8b":
        fh.close()
        return gzip.open(path, "rb")  # type: ignore[return-value]
    return fh


def _read_exact(fh: BinaryIO, n: int) -> bytes:
    """Read exactly n bytes or return what there was (possibly short)."""
    buf = bytearray()
    while len(buf) < n:
        chunk = fh.read(n - len(buf))
        if not chunk:
            break
        buf += chunk
    return bytes(buf)


def read_classic_pcap(fh: BinaryIO, diag: Diagnostics) -> Iterator[CaptureRecord]:
    hdr = _read_exact(fh, 24)
    if len(hdr) < 24:
        raise ValueError("file is shorter than a 24-byte pcap file header")
    magic = struct.unpack("<I", hdr[:4])[0]
    if magic in (PCAP_MAGIC_US_LE, PCAP_MAGIC_NS_LE):
        endian, ts_mult = "<", (1000 if magic == PCAP_MAGIC_US_LE else 1)
    else:
        magic_be = struct.unpack(">I", hdr[:4])[0]
        if magic_be in (PCAP_MAGIC_US_LE, PCAP_MAGIC_NS_LE):
            endian, ts_mult = ">", (1000 if magic_be == PCAP_MAGIC_US_LE else 1)
        else:
            raise ValueError(f"not a classic pcap file (magic 0x{magic:08x})")
    _vmaj, _vmin, _tz, _sig, _snap, linktype = struct.unpack(endian + "HHiIII", hdr[4:24])
    if linktype not in _SUPPORTED_LINKTYPES:
        diag.note("LINKTYPE_UNSUPPORTED",
                  f"pcap linktype {linktype}; only {sorted(_SUPPORTED_LINKTYPES)} are decoded")
    rec_fmt = endian + "IIII"
    idx = 0
    off = 24
    while True:
        rh = _read_exact(fh, 16)
        if not rh:
            return
        if len(rh) < 16:
            diag.note("PCAP_TRUNCATED_RECORD",
                      f"{len(rh)} trailing bytes where a 16-byte record header was expected",
                      pkt_index=idx, file_offset=off)
            return
        ts_sec, ts_frac, caplen, wirelen = struct.unpack(rec_fmt, rh)
        data = _read_exact(fh, caplen)
        if len(data) < caplen:
            diag.note("PCAP_TRUNCATED_RECORD",
                      f"record declares {caplen} bytes, only {len(data)} present; "
                      "capture is truncated",
                      pkt_index=idx, file_offset=off)
            return
        if caplen < wirelen:
            diag.note("PCAP_SNAPLEN_CLIPPED",
                      f"caplen {caplen} < wirelen {wirelen}: {wirelen - caplen} bytes "
                      "were never captured",
                      pkt_index=idx, file_offset=off)
        if caplen == 0:
            diag.note("PCAP_ZERO_LENGTH", "zero-length record", pkt_index=idx, file_offset=off)
        yield CaptureRecord(
            index=idx, file_offset=off,
            ts_ns=ts_sec * 1_000_000_000 + ts_frac * ts_mult,
            wirelen=wirelen, data=data, linktype=linktype,
        )
        idx += 1
        off += 16 + caplen


def read_pcapng(fh: BinaryIO, diag: Diagnostics) -> Iterator[CaptureRecord]:
    """Minimal pcapng reader: SHB, IDB, EPB, SPB. Enough for a tap capture.

    Per-interface timestamp resolution honours the ``if_tsresol`` option
    (code 9); the pcapng default is 10^-6 s.
    VERIFY: pcapng specification, https://ietf-opsawg-wg.github.io/draft-ietf-opsawg-pcap/
    """
    endian = "<"
    if_linktype: List[int] = []
    if_tsdiv: List[int] = []       # divisor to convert raw ticks -> seconds
    if_snaplen: List[int] = []
    idx = 0
    off = 0
    first = True
    while True:
        bh = _read_exact(fh, 8)
        if not bh:
            return
        if len(bh) < 8:
            diag.note("PCAP_TRUNCATED_RECORD", "trailing bytes where a pcapng block header was expected",
                      pkt_index=idx, file_offset=off)
            return
        if first:
            btype = struct.unpack("<I", bh[:4])[0]
            if btype != PCAPNG_SHB_TYPE:
                raise ValueError("not a pcapng file (no Section Header Block)")
            blen_le = struct.unpack("<I", bh[4:8])[0]
            body = _read_exact(fh, max(0, blen_le - 8))
            if len(body) >= 4 and struct.unpack("<I", body[:4])[0] != PCAPNG_BOM:
                endian = ">"
                # Re-read length with the correct endianness.
                blen_be = struct.unpack(">I", bh[4:8])[0]
                if blen_be != blen_le:
                    raise ValueError("pcapng SHB length is ambiguous; refusing to guess")
            first = False
            off += 8 + len(body)
            idx += 0
            continue
        btype, blen = struct.unpack(endian + "II", bh)
        if blen < 12:
            diag.note("PCAP_TRUNCATED_RECORD", f"pcapng block length {blen} < 12",
                      pkt_index=idx, file_offset=off)
            return
        body = _read_exact(fh, blen - 8)
        if len(body) < blen - 8:
            diag.note("PCAP_TRUNCATED_RECORD", "pcapng block truncated",
                      pkt_index=idx, file_offset=off)
            return
        payload = body[:-4]  # strip the trailing block-total-length
        if btype == 0x00000001:  # IDB
            lt, _res, snap = struct.unpack(endian + "HHI", payload[:8])
            tsdiv = 1_000_000
            opts = payload[8:]
            p = 0
            while p + 4 <= len(opts):
                ocode, olen = struct.unpack(endian + "HH", opts[p:p + 4])
                oval = opts[p + 4:p + 4 + olen]
                if ocode == 0:
                    break
                if ocode == 9 and olen >= 1:  # if_tsresol
                    r = oval[0]
                    tsdiv = (1 << (r & 0x7F)) if (r & 0x80) else (10 ** (r & 0x7F))
                p += 4 + ((olen + 3) & ~3)
            if lt not in _SUPPORTED_LINKTYPES:
                diag.note("LINKTYPE_UNSUPPORTED", f"pcapng interface linktype {lt}")
            if_linktype.append(lt)
            if_tsdiv.append(tsdiv)
            if_snaplen.append(snap)
        elif btype == 0x00000006:  # EPB
            iface, ts_hi, ts_lo, caplen, wirelen = struct.unpack(endian + "IIIII", payload[:20])
            data = payload[20:20 + caplen]
            div = if_tsdiv[iface] if iface < len(if_tsdiv) else 1_000_000
            lt = if_linktype[iface] if iface < len(if_linktype) else LINKTYPE_ETHERNET
            ticks = (ts_hi << 32) | ts_lo
            if caplen < wirelen:
                diag.note("PCAP_SNAPLEN_CLIPPED",
                          f"caplen {caplen} < wirelen {wirelen}", pkt_index=idx, file_offset=off)
            yield CaptureRecord(
                index=idx, file_offset=off,
                ts_ns=(ticks * 1_000_000_000) // div,
                wirelen=wirelen, data=bytes(data), linktype=lt,
            )
            idx += 1
        elif btype == 0x00000003:  # SPB — no timestamp
            (wirelen,) = struct.unpack(endian + "I", payload[:4])
            snap = if_snaplen[0] if if_snaplen else 0
            caplen = min(wirelen, snap) if snap else wirelen
            data = payload[4:4 + caplen]
            lt = if_linktype[0] if if_linktype else LINKTYPE_ETHERNET
            yield CaptureRecord(index=idx, file_offset=off, ts_ns=0,
                                wirelen=wirelen, data=bytes(data), linktype=lt)
            idx += 1
        elif btype not in (0x0A0D0D0A, 0x00000005, 0x00000004):
            diag.note("PCAPNG_UNKNOWN_BLOCK", f"block type 0x{btype:08x} skipped",
                      pkt_index=idx, file_offset=off)
        off += blen


def read_capture(fh: BinaryIO, diag: Diagnostics) -> Iterator[CaptureRecord]:
    """Dispatch on the file magic. pcap and pcapng only."""
    head = fh.read(4)
    if len(head) < 4:
        raise ValueError("file is too short to be a capture")
    # Rewind. gzip file objects support seek(0); plain files certainly do.
    fh.seek(0)
    m_le = struct.unpack("<I", head)[0]
    m_be = struct.unpack(">I", head)[0]
    if m_le == PCAPNG_SHB_TYPE or m_be == PCAPNG_SHB_TYPE:
        return read_pcapng(fh, diag)
    if m_le in (PCAP_MAGIC_US_LE, PCAP_MAGIC_NS_LE) or m_be in (PCAP_MAGIC_US_LE, PCAP_MAGIC_NS_LE):
        return read_classic_pcap(fh, diag)
    raise ValueError(
        f"unrecognised capture magic 0x{m_be:08x}; expected classic pcap or pcapng. "
        "For a raw length-prefixed Nasdaq ITCH file, pass --raw."
    )


# =============================================================================
# 9. L2/L3/L4 decode down to the UDP payload
# =============================================================================
ETHERTYPE_IPV4 = 0x0800
ETHERTYPE_VLAN = 0x8100
ETHERTYPE_QINQ = 0x88A8
ETHERTYPE_QINQ_ALT = 0x9100
_MAX_VLAN_TAGS = 3
IPPROTO_UDP = 17


def _ipv4_str(b: bytes) -> str:
    return ".".join(str(x) for x in b)


def extract_udp(rec: CaptureRecord, diag: Diagnostics
                ) -> Optional[Tuple[str, str, int, int, bytes]]:
    """Return (src_ip, dst_ip, src_port, dst_port, udp_payload) or None.

    Anything not decodable to IPv4/UDP is counted with a reason and dropped —
    never silently. ⚠️ IPv4 fragments are NOT reassembled: an ITCH MoldUDP64
    packet arriving fragmented means the capture cannot be replayed
    byte-for-byte into a fabric MAC that does not reassemble either, so this is
    an ERROR you want to see, not a thing to paper over.
    """
    data = rec.data
    lt = rec.linktype
    off = 0
    if lt == LINKTYPE_ETHERNET:
        if len(data) < 14:
            diag.note("ETH_SHORT", f"{len(data)} bytes", pkt_index=rec.index,
                      file_offset=rec.file_offset)
            return None
        etype = struct.unpack(">H", data[12:14])[0]
        off = 14
        tags = 0
        while etype in (ETHERTYPE_VLAN, ETHERTYPE_QINQ, ETHERTYPE_QINQ_ALT):
            tags += 1
            if tags > _MAX_VLAN_TAGS:
                diag.note("VLAN_DEPTH", f">{_MAX_VLAN_TAGS} stacked tags",
                          pkt_index=rec.index, file_offset=rec.file_offset)
                return None
            if len(data) < off + 4:
                diag.note("ETH_SHORT", "truncated VLAN tag", pkt_index=rec.index,
                          file_offset=rec.file_offset)
                return None
            etype = struct.unpack(">H", data[off + 2:off + 4])[0]
            off += 4
        if etype != ETHERTYPE_IPV4:
            diag.note("ETH_NOT_IPV4", f"ethertype 0x{etype:04x}", pkt_index=rec.index,
                      file_offset=rec.file_offset)
            return None
    elif lt == LINKTYPE_LINUX_SLL:
        off = 16
        if len(data) < off:
            diag.note("ETH_SHORT", "truncated LINUX_SLL header", pkt_index=rec.index,
                      file_offset=rec.file_offset)
            return None
        if struct.unpack(">H", data[14:16])[0] != ETHERTYPE_IPV4:
            diag.note("ETH_NOT_IPV4", "SLL protocol is not IPv4", pkt_index=rec.index,
                      file_offset=rec.file_offset)
            return None
    elif lt == LINKTYPE_LINUX_SLL2:
        off = 20
        if len(data) < off:
            diag.note("ETH_SHORT", "truncated LINUX_SLL2 header", pkt_index=rec.index,
                      file_offset=rec.file_offset)
            return None
        if struct.unpack(">H", data[0:2])[0] != ETHERTYPE_IPV4:
            diag.note("ETH_NOT_IPV4", "SLL2 protocol is not IPv4", pkt_index=rec.index,
                      file_offset=rec.file_offset)
            return None
    elif lt in (LINKTYPE_RAW, LINKTYPE_IPV4):
        off = 0
    else:
        diag.note("LINKTYPE_UNSUPPORTED", f"linktype {lt}", pkt_index=rec.index,
                  file_offset=rec.file_offset)
        return None

    if len(data) < off + 20:
        diag.note("IP_SHORT", f"{len(data) - off} bytes of IPv4 header",
                  pkt_index=rec.index, file_offset=rec.file_offset)
        return None
    vihl = data[off]
    ihl = (vihl & 0x0F) * 4
    if (vihl >> 4) != 4 or ihl < 20:
        diag.note("IP_BAD_IHL", f"version/IHL byte 0x{vihl:02x}", pkt_index=rec.index,
                  file_offset=rec.file_offset)
        return None
    total_len = struct.unpack(">H", data[off + 2:off + 4])[0]
    frag = struct.unpack(">H", data[off + 6:off + 8])[0]
    more_frags = bool(frag & 0x2000)
    frag_off = frag & 0x1FFF
    proto = data[off + 9]
    src_ip = _ipv4_str(data[off + 12:off + 16])
    dst_ip = _ipv4_str(data[off + 16:off + 20])
    if more_frags or frag_off:
        diag.note("IP_FRAGMENT",
                  f"{src_ip} -> {dst_ip} frag_off={frag_off} MF={int(more_frags)}; "
                  "not reassembled",
                  pkt_index=rec.index, file_offset=rec.file_offset)
        return None
    if proto != IPPROTO_UDP:
        diag.note("IP_NOT_UDP", f"protocol {proto}", pkt_index=rec.index,
                  file_offset=rec.file_offset)
        return None
    avail = len(data) - off
    if total_len > avail:
        diag.note("IP_LEN_MISMATCH",
                  f"IPv4 total_length {total_len} > {avail} captured bytes",
                  pkt_index=rec.index, file_offset=rec.file_offset)
    l4 = off + ihl
    if len(data) < l4 + 8:
        diag.note("UDP_SHORT", f"{len(data) - l4} bytes of UDP header",
                  pkt_index=rec.index, file_offset=rec.file_offset)
        return None
    sport, dport, ulen, _csum = struct.unpack(">HHHH", data[l4:l4 + 8])
    payload = data[l4 + 8:]
    if total_len and total_len <= avail:
        payload = payload[:max(0, total_len - ihl - 8)]
    declared_payload = max(0, ulen - 8)
    if declared_payload != len(payload):
        diag.note("UDP_LEN_MISMATCH",
                  f"UDP length says {declared_payload} payload bytes, {len(payload)} present",
                  pkt_index=rec.index, file_offset=rec.file_offset)
    return src_ip, dst_ip, sport, dport, bytes(payload)


# =============================================================================
# 10. The reader
# =============================================================================
class ItchReader:
    """Streaming ITCH reader over a capture (or a raw ITCH file).

    Bounded memory: capture records are consumed one at a time and nothing but
    per-stream sequence state is retained. Pointing this at a full-session
    multi-gigabyte capture is expected and supported.

    Example
    -------
        r = ItchReader("open.pcap", ports={26477})
        for msg in r.messages():
            ...
        print(r.diag.errors, "errors")
    """

    def __init__(
        self,
        path: str,
        *,
        ports: Optional[Sequence[int]] = None,
        groups: Optional[Sequence[str]] = None,
        merge_ab: bool = False,
        raw_itch: bool = False,
        keep_per_code: int = 50,
        on_anomaly: Optional[Callable[[Anomaly], None]] = None,
        strict_length: bool = False,
    ) -> None:
        """
        Parameters
        ----------
        ports, groups
            Optional UDP destination-port / destination-IP filters, for a
            capture holding several feeds. ⚠️ Use these to *select a feed*,
            never to make a failing parse pass. Filtered packets are counted.
        merge_ab
            ``False`` (default): track sequence continuity per destination
            group, so an A-only gap shows up as a gap on A. ``True``: track one
            sequence space across all groups, which is what the arbiter output
            looks like — then the B copy of every packet is a SEQ_DUPLICATE,
            which is normal and INFO-severity.
        raw_itch
            Parse a raw Nasdaq ITCH file (2-byte big-endian length prefix +
            message, repeated) instead of a capture. No transport framing, so
            no sequence numbers exist; ``seq`` is a synthetic ordinal.
        strict_length
            Stop at the first ITCH_LENGTH_MISMATCH instead of continuing. The
            default is to continue *and* report, because seeing all of them is
            how you tell "one corrupt packet" from "the spec moved".
        """
        self.path = path
        self.ports = set(ports) if ports else None
        self.groups = set(groups) if groups else None
        self.merge_ab = merge_ab
        self.raw_itch = raw_itch
        self.strict_length = strict_length
        self.diag = Diagnostics(keep_per_code=keep_per_code, on_anomaly=on_anomaly)

        # Counters. CLAUDE.md §5.7 applied to tooling: everything attributable.
        self.packets_read = 0
        self.packets_filtered = 0
        self.packets_mold = 0
        self.heartbeats = 0
        self.end_of_session = 0
        self.msgs_decoded = 0
        self.msgs_by_type: Counter = Counter()
        self.bytes_capture = 0
        self.bytes_udp = 0
        self.first_pkt_ts_ns: Optional[int] = None
        self.last_pkt_ts_ns: Optional[int] = None
        self.sessions: Counter = Counter()
        self._seq_state: Dict[Tuple[str, int, str], int] = {}
        self._seq_seen_max: Dict[Tuple[str, int, str], int] = {}

    # -- public API -----------------------------------------------------------
    def messages(self) -> Iterator[ParsedMessage]:  # type: ignore[override]
        """Yield every decoded ITCH message, in capture order."""
        if self.raw_itch:
            yield from self._iter_raw()
        else:
            yield from self._iter_capture()

    def packets(self) -> Iterator[MoldPacket]:
        """Yield MoldUDP64 packets without decoding their ITCH blocks.

        Useful for rate analysis and slicing, where the message *bodies* are
        not needed and decoding them would be wasted work on a large capture.
        """
        fh = open_maybe_gzip(self.path)
        try:
            for rec in read_capture(fh, self.diag):
                mp = self._record_to_mold(rec)
                if mp is not None:
                    yield mp
        finally:
            fh.close()

    def summary(self) -> Dict[str, Any]:
        dur = None
        if self.first_pkt_ts_ns is not None and self.last_pkt_ts_ns is not None:
            dur = (self.last_pkt_ts_ns - self.first_pkt_ts_ns) / 1e9
        return {
            "tool": "itch_parse.py",
            "tool_version": VERSION,
            "path": self.path,
            "packets_read": self.packets_read,
            "packets_filtered_out": self.packets_filtered,
            "packets_moldudp64": self.packets_mold,
            "heartbeats": self.heartbeats,
            "end_of_session_markers": self.end_of_session,
            "messages_decoded": self.msgs_decoded,
            "messages_by_type": {
                f"{t} {ITCH_MSG_NAME.get(t, 'UNKNOWN')}": n
                for t, n in sorted(self.msgs_by_type.items(), key=lambda kv: -kv[1])
            },
            "bytes_capture": self.bytes_capture,
            "bytes_udp_payload": self.bytes_udp,
            "capture_first_ts_ns": self.first_pkt_ts_ns,
            "capture_last_ts_ns": self.last_pkt_ts_ns,
            "capture_duration_s": dur,
            "sessions": dict(self.sessions),
            "diagnostics": self.diag.to_dict(),
        }

    # -- internals ------------------------------------------------------------
    def _record_to_mold(self, rec: CaptureRecord) -> Optional[MoldPacket]:
        self.packets_read += 1
        self.bytes_capture += len(rec.data)
        if self.first_pkt_ts_ns is None or rec.ts_ns < self.first_pkt_ts_ns:
            self.first_pkt_ts_ns = rec.ts_ns
        if self.last_pkt_ts_ns is None or rec.ts_ns > self.last_pkt_ts_ns:
            self.last_pkt_ts_ns = rec.ts_ns

        udp = extract_udp(rec, self.diag)
        if udp is None:
            return None
        src, dst, sport, dport, payload = udp
        if self.ports is not None and dport not in self.ports:
            self.packets_filtered += 1
            return None
        if self.groups is not None and dst not in self.groups:
            self.packets_filtered += 1
            return None

        self.bytes_udp += len(payload)
        if len(payload) < MOLD_HDR_LEN:
            self.diag.note("MOLD_SHORT_HEADER",
                           f"{len(payload)} byte UDP payload, need {MOLD_HDR_LEN}",
                           pkt_index=rec.index, file_offset=rec.file_offset)
            return None
        session = payload[MOLD_SESSION_OFF:MOLD_SESSION_OFF + MOLD_SESSION_LEN]
        session_s = session.decode("latin-1").rstrip(" \x00")
        seq = _be(payload[MOLD_SEQNUM_OFF:MOLD_SEQNUM_OFF + MOLD_SEQNUM_LEN])
        count = _be(payload[MOLD_MSGCNT_OFF:MOLD_MSGCNT_OFF + MOLD_MSGCNT_LEN])
        self.packets_mold += 1
        if self.sessions and session_s not in self.sessions:
            self.diag.note("MOLD_SESSION_CHANGE",
                           f"new session {session_s!r}, already saw {sorted(self.sessions)}",
                           pkt_index=rec.index, file_offset=rec.file_offset, seq=seq)
        self.sessions[session_s] += 1
        return MoldPacket(
            session=session_s, seq=seq, count=count,
            payload=payload[MOLD_HDR_LEN:], pkt_index=rec.index,
            file_offset=rec.file_offset, ts_ns=rec.ts_ns,
            src=src, dst=dst, src_port=sport, dst_port=dport,
        )

    def _check_sequence(self, mp: MoldPacket, n_msgs: int) -> None:
        """Gap / duplicate / regression detection on one feed line.

        ⚠️ A heartbeat (count 0) advances nothing and is NOT a gap. A gap in
        ITCH is unrecoverable in fabric: the feed is a pure delta stream with
        no snapshot on the multicast channel, so a missed Add Order is missing
        from the book forever. See manuals/08-nasdaq/04-*.md §2.
        """
        key = ("", 0, mp.session) if self.merge_ab else mp.stream_key
        if n_msgs == 0:
            return
        expect = self._seq_state.get(key)
        if expect is None:
            self._seq_state[key] = mp.seq + n_msgs
            self._seq_seen_max[key] = mp.seq + n_msgs - 1
            return
        if mp.seq == expect:
            pass
        elif mp.seq > expect:
            self.diag.note("SEQ_GAP",
                           f"{mp.dst}:{mp.dst_port} session {mp.session!r}: expected {expect}, "
                           f"got {mp.seq} — {mp.seq - expect} message(s) missing",
                           pkt_index=mp.pkt_index, file_offset=mp.file_offset, seq=mp.seq)
        else:
            last_seen = self._seq_seen_max.get(key, expect - 1)
            if mp.seq + n_msgs - 1 <= last_seen:
                self.diag.note("SEQ_DUPLICATE",
                               f"{mp.dst}:{mp.dst_port}: seq {mp.seq}..{mp.seq + n_msgs - 1} "
                               "already seen",
                               pkt_index=mp.pkt_index, file_offset=mp.file_offset, seq=mp.seq)
            else:
                self.diag.note("SEQ_REGRESSION",
                               f"{mp.dst}:{mp.dst_port}: seq {mp.seq} < expected {expect} "
                               "but extends past the last seen sequence",
                               pkt_index=mp.pkt_index, file_offset=mp.file_offset, seq=mp.seq)
        self._seq_state[key] = max(expect, mp.seq + n_msgs)
        self._seq_seen_max[key] = max(self._seq_seen_max.get(key, 0), mp.seq + n_msgs - 1)

    def _iter_capture(self) -> Iterator[ParsedMessage]:
        fh = open_maybe_gzip(self.path)
        try:
            for rec in read_capture(fh, self.diag):
                mp = self._record_to_mold(rec)
                if mp is None:
                    continue
                if mp.count == MOLD_CNT_HEARTBEAT:
                    self.heartbeats += 1
                    self.diag.note("MOLD_HEARTBEAT", f"session {mp.session!r} seq {mp.seq}",
                                   pkt_index=mp.pkt_index, file_offset=mp.file_offset, seq=mp.seq)
                    if mp.payload:
                        self.diag.note("MOLD_TRAILING_BYTES",
                                       f"{len(mp.payload)} bytes after a count-0 heartbeat",
                                       pkt_index=mp.pkt_index, file_offset=mp.file_offset,
                                       seq=mp.seq)
                    continue
                if mp.count == MOLD_CNT_ENDSESS:
                    self.end_of_session += 1
                    self.diag.note("MOLD_END_OF_SESSION", f"session {mp.session!r} seq {mp.seq}",
                                   pkt_index=mp.pkt_index, file_offset=mp.file_offset, seq=mp.seq)
                    continue
                # Sequence continuity is judged on the DECLARED count, before
                # decode: a packet whose blocks are corrupt still occupies its
                # sequence range, and calling that a gap would double-report
                # one fault as two.
                self._check_sequence(mp, mp.count)
                yield from self._iter_blocks(mp)
        finally:
            fh.close()

    def _iter_blocks(self, mp: MoldPacket) -> Iterator[ParsedMessage]:
        """Walk the length-prefixed blocks of one MoldUDP64 packet.

        The loop is bounded by the packet length and by the declared message
        count — CLAUDE.md §5.2 (no unbounded loops) is a fabric rule, but the
        same bound is what keeps a corrupt capture from spinning here.
        """
        buf = mp.payload
        pos = 0
        i = 0
        while i < mp.count and pos < len(buf):
            if pos + 2 > len(buf):
                self.diag.note("MOLD_BLOCK_TRUNCATED",
                               f"block {i}: {len(buf) - pos} bytes left, need a 2-byte length",
                               pkt_index=mp.pkt_index, file_offset=mp.file_offset,
                               seq=mp.seq + i)
                return
            blen = _be(buf[pos:pos + 2])
            pos += 2
            if blen == 0:
                self.diag.note("MOLD_BLOCK_ZERO_LEN", f"block {i} declares length 0",
                               pkt_index=mp.pkt_index, file_offset=mp.file_offset,
                               seq=mp.seq + i)
                return
            if pos + blen > len(buf):
                self.diag.note("MOLD_BLOCK_TRUNCATED",
                               f"block {i} declares {blen} bytes, only {len(buf) - pos} present",
                               pkt_index=mp.pkt_index, file_offset=mp.file_offset,
                               seq=mp.seq + i)
                return
            body = buf[pos:pos + blen]
            pos += blen
            seq = mp.seq + i

            # ⚠️ THE CROSS-CHECK. The block length prefix is redundant with the
            #    type byte; disagreement is reported, never silently absorbed.
            t = chr(body[0]) if body else "?"
            spec = ITCH_MSG_LEN.get(t)
            if spec is not None and spec != blen:
                self.diag.note(
                    "ITCH_LENGTH_MISMATCH",
                    f"type {t!r} ({ITCH_MSG_NAME[t]}): MoldUDP64 block declares {blen} bytes, "
                    f"spec says {spec} (delta {blen - spec:+d}). Either the capture is corrupt "
                    "or this length table is stale — verify against the ITCH 5.0 spec PDF.",
                    pkt_index=mp.pkt_index, file_offset=mp.file_offset, seq=seq, msg_type=t,
                )
                if self.strict_length:
                    raise ValueError(
                        f"ITCH_LENGTH_MISMATCH at pkt#{mp.pkt_index} seq={seq} type={t!r}: "
                        f"declared {blen}, spec {spec} (--strict-length)"
                    )

            msg = decode_itch_message(body, self.diag, pkt_index=mp.pkt_index,
                                      file_offset=mp.file_offset, seq=seq)
            i += 1
            if msg is None:
                continue
            msg.pkt_ts_ns = mp.ts_ns
            msg.index_in_packet = i - 1
            msg.session = mp.session
            msg.src = mp.src
            msg.dst = mp.dst
            msg.dst_port = mp.dst_port
            self.msgs_decoded += 1
            self.msgs_by_type[msg.msg_type] += 1
            yield msg

        if i < mp.count:
            self.diag.note("MOLD_COUNT_MISMATCH",
                           f"ran out of payload after {i} of {mp.count} declared messages",
                           pkt_index=mp.pkt_index, file_offset=mp.file_offset, seq=mp.seq)
        elif pos < len(buf):
            self.diag.note("MOLD_TRAILING_BYTES",
                           f"{len(buf) - pos} bytes after the {mp.count} declared messages",
                           pkt_index=mp.pkt_index, file_offset=mp.file_offset, seq=mp.seq)

    def _iter_raw(self) -> Iterator[ParsedMessage]:
        """Raw Nasdaq ITCH file: repeated (2-byte BE length, message).

        Nasdaq's published sample TotalView-ITCH files are distributed in this
        form rather than as pcaps (TASKS.md P1.1). There is no transport, so
        there is no sequence number and no A/B duplication; ``seq`` here is an
        ordinal so that traces remain comparable.
        """
        fh = open_maybe_gzip(self.path)
        try:
            seq = 1
            off = 0
            while True:
                lb = _read_exact(fh, 2)
                if not lb:
                    break
                if len(lb) < 2:
                    self.diag.note("RAW_TRUNCATED", "1 trailing byte where a length prefix was expected",
                                   pkt_index=seq, file_offset=off)
                    break
                blen = _be(lb)
                body = _read_exact(fh, blen)
                if len(body) < blen:
                    self.diag.note("RAW_TRUNCATED",
                                   f"length prefix says {blen}, only {len(body)} bytes left",
                                   pkt_index=seq, file_offset=off)
                    break
                t = chr(body[0]) if body else "?"
                spec = ITCH_MSG_LEN.get(t)
                if spec is not None and spec != blen:
                    self.diag.note(
                        "ITCH_LENGTH_MISMATCH",
                        f"type {t!r}: file declares {blen} bytes, spec says {spec} "
                        f"(delta {blen - spec:+d})",
                        pkt_index=seq, file_offset=off, seq=seq, msg_type=t,
                    )
                    if self.strict_length:
                        raise ValueError(f"ITCH_LENGTH_MISMATCH at offset {off}: {t!r} {blen}!={spec}")
                msg = decode_itch_message(body, self.diag, pkt_index=seq, file_offset=off, seq=seq)
                off += 2 + blen
                self.packets_read += 1
                self.bytes_capture += 2 + blen
                if msg is None:
                    seq += 1
                    continue
                self.msgs_decoded += 1
                self.msgs_by_type[msg.msg_type] += 1
                yield msg
                seq += 1
        finally:
            fh.close()


def iter_messages(path: str, **kw: Any) -> Iterator[ParsedMessage]:
    """Convenience: yield decoded messages from ``path``.

    Diagnostics are discarded. Use :class:`ItchReader` directly when you care
    about anomalies — and in a corpus tool, you always care about anomalies.
    """
    return ItchReader(path, **kw).messages()


# =============================================================================
# 11. CLI
# =============================================================================
def _fmt_int(n: int) -> str:
    return f"{n:,}"


def _print_summary(r: ItchReader, out) -> None:
    s = r.summary()
    print("=" * 78, file=out)
    print(f"ITCH parse summary — {os.path.basename(r.path)}", file=out)
    print("=" * 78, file=out)
    print(f"  capture records read     {_fmt_int(s['packets_read'])}", file=out)
    print(f"  filtered out (not feed)  {_fmt_int(s['packets_filtered_out'])}", file=out)
    print(f"  MoldUDP64 packets        {_fmt_int(s['packets_moldudp64'])}", file=out)
    print(f"  heartbeats               {_fmt_int(s['heartbeats'])}", file=out)
    print(f"  end-of-session markers   {_fmt_int(s['end_of_session_markers'])}", file=out)
    print(f"  ITCH messages decoded    {_fmt_int(s['messages_decoded'])}", file=out)
    print(f"  capture bytes            {_fmt_int(s['bytes_capture'])}", file=out)
    if s["capture_duration_s"]:
        print(f"  capture duration         {s['capture_duration_s']:.6f} s", file=out)
        print(f"  mean message rate        "
              f"{s['messages_decoded'] / s['capture_duration_s']:,.0f} msg/s "
              f"(mean only — see stats.py for p50/p99/p99.9/max)", file=out)
    if s["sessions"]:
        print(f"  MoldUDP64 sessions       {', '.join(repr(k) for k in s['sessions'])}", file=out)

    print("\n  message type histogram", file=out)
    print("  " + "-" * 60, file=out)
    total = max(1, s["messages_decoded"])
    for label, n in s["messages_by_type"].items():
        t = label.split()[0]
        book = " book" if t in BOOK_MSG_TYPES else ""
        print(f"    {label:<34s} {_fmt_int(n):>12s}  {100.0 * n / total:5.2f}%{book}", file=out)

    d = s["diagnostics"]
    print("\n  diagnostics  "
          f"ERROR={d['by_severity']['ERROR']}  WARN={d['by_severity']['WARN']}  "
          f"INFO={d['by_severity']['INFO']}", file=out)
    print("  " + "-" * 60, file=out)
    if not d["counts"]:
        print("    (none)", file=out)
    for code, n in sorted(d["counts"].items(),
                          key=lambda kv: (ANOMALY_CATALOG.get(kv[0], ("", ""))[0] != "ERROR", -kv[1])):
        sev, meaning = ANOMALY_CATALOG.get(code, ("ERROR", ""))
        print(f"    [{sev:5s}] {code:<24s} {_fmt_int(n):>10s}  {meaning}", file=out)
    for code, exs in d["examples"].items():
        if ANOMALY_CATALOG.get(code, ("", ""))[0] != Severity.ERROR:
            continue
        print(f"\n    first {len(exs)} of {d['counts'][code]} {code}:", file=out)
        for e in exs[:5]:
            print(f"      pkt#{e['pkt_index']} seq={e['seq']}: {e['detail']}", file=out)
    print("", file=out)
    if d["by_severity"]["ERROR"]:
        print("  ⚠️  ERROR-severity anomalies present. This capture is NOT clean.\n"
              "     Do not promote it to the regression corpus until each one is\n"
              "     explained — a corpus entry with an unexplained anomaly teaches\n"
              "     the regression to accept it.\n", file=out)


def main(argv: Optional[Sequence[str]] = None) -> int:
    p = argparse.ArgumentParser(
        prog="itch_parse.py",
        description="Reference Nasdaq TotalView-ITCH 5.0 / MoldUDP64 parser. "
                    "Cross-checks every declared message length against the type "
                    "and reports every mismatch.",
        epilog="⚠️ Recorded exchange market data is licensed. Do not redistribute "
               "captures without checking the terms — see tools/pcap/README.md.",
    )
    p.add_argument("capture", help="pcap / pcapng file (.gz ok), or a raw ITCH file with --raw")
    p.add_argument("--raw", action="store_true",
                   help="input is a raw length-prefixed Nasdaq ITCH file, not a capture")
    p.add_argument("--ports", help="comma-separated UDP destination ports to keep")
    p.add_argument("--groups", help="comma-separated destination IPs (multicast groups) to keep")
    p.add_argument("--merge-ab", action="store_true",
                   help="treat all groups as one sequence space (B copies become duplicates)")
    p.add_argument("--types", help="comma-separated ITCH type codes to print, e.g. A,U,D")
    p.add_argument("--locate", type=int, action="append",
                   help="only print messages with this stock locate (repeatable)")
    p.add_argument("--limit", type=int, default=0, help="stop after N printed messages (0 = all)")
    p.add_argument("--json", action="store_true", help="print messages as JSON lines")
    p.add_argument("--raw-bytes", action="store_true", help="include hex of each message in JSON")
    p.add_argument("--summary", action="store_true", help="print the summary table at the end")
    p.add_argument("--summary-json", action="store_true", help="print the summary as JSON")
    p.add_argument("--anomalies-only", action="store_true",
                   help="print no messages; report anomalies and the summary only")
    p.add_argument("--strict-length", action="store_true",
                   help="abort on the first length mismatch instead of reporting and continuing")
    p.add_argument("--keep-per-code", type=int, default=50,
                   help="anomaly examples retained per code (counts are always exact)")
    args = p.parse_args(argv)

    ports = [int(x) for x in args.ports.split(",")] if args.ports else None
    groups = [x.strip() for x in args.groups.split(",")] if args.groups else None
    want_types = set(args.types.split(",")) if args.types else None
    want_locates = set(args.locate) if args.locate else None

    try:
        r = ItchReader(args.capture, ports=ports, groups=groups, merge_ab=args.merge_ab,
                       raw_itch=args.raw, keep_per_code=args.keep_per_code,
                       strict_length=args.strict_length)
    except OSError as e:
        print(f"itch_parse: cannot open {args.capture}: {e}", file=sys.stderr)
        return 2

    printed = 0
    try:
        for msg in r.messages():
            if args.anomalies_only:
                continue
            if want_types and msg.msg_type not in want_types:
                continue
            if want_locates and msg.locate not in want_locates:
                continue
            if args.json:
                print(json.dumps(msg.to_dict(include_raw=args.raw_bytes), separators=(",", ":")))
            else:
                print(msg)
            printed += 1
            if args.limit and printed >= args.limit:
                break
    except ValueError as e:
        print(f"itch_parse: {e}", file=sys.stderr)
        return 1
    except BrokenPipeError:  # pragma: no cover - `| head`
        try:
            sys.stdout.close()
        finally:
            return 0

    if args.summary_json:
        print(json.dumps(r.summary(), indent=2, default=str))
    elif args.summary or args.anomalies_only:
        _print_summary(r, sys.stdout)

    return 1 if r.diag.errors else 0


if __name__ == "__main__":
    sys.exit(main())
