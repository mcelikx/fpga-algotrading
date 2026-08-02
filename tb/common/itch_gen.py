"""Synthetic Nasdaq TotalView-ITCH 5.0 message and frame generator.

Project : FPGA Algorithmic Trading System (Nasdaq Equities)
Governs : manuals/08-nasdaq/04-totalview-itch-5.0.md
          manuals/01-fpga-design/05-verification-and-simulation.md §2, §6
Mirrors : rtl/pkg/itch_pkg.sv   <-- THE source of truth for codes and lengths

Builds ITCH messages in wire order, packs them into MoldUDP64 packets, and wraps
those in UDP / IPv4 / Ethernet frames ready for :class:`AxisDriver`.

===============================================================================
⚠️  VERIFY BEFORE TRUSTING THIS FILE — the same caveat as rtl/pkg/itch_pkg.sv
===============================================================================
    The message type codes and lengths below are taken from
    ``rtl/pkg/itch_pkg.sv`` and reflect the TotalView-ITCH 5.0 specification,
    but **field byte offsets and lengths MUST be confirmed against the current
    spec PDF** from https://nasdaqtrader.com/Trading/TradingSpecs before they
    are relied upon.

    A wrong offset produces a decoder that "works" on some messages and
    silently corrupts others — the worst possible failure mode in this domain.

    And note the specific trap this file creates:

        THIS GENERATOR AND THE RTL DECODER SHARE A SOURCE.

    If ``itch_pkg.sv`` has an offset wrong and this file copies it, the
    testbench and the DUT agree perfectly and both are wrong. A green
    regression proves the RTL matches the model; it proves NOTHING about
    whether the model matches Nasdaq.
    (manuals/01-fpga-design/05-verification-and-simulation.md §9, last row.)

    The only defences are (a) an independent reader checking this file against
    the spec PDF, and (b) venue conformance testing. Both are release gates.
    Every constant below carries a ``VERIFY:`` marker so the reviewer knows
    exactly what to check.
===============================================================================

Prices
------
ITCH prices are 4-byte unsigned integers with **4 implied decimals**
(``trading_pkg::PRICE_SCALE = 10000``). $187.5000 is ``1_875_000``. There are no
floats anywhere in this file, in the RTL, or in the oracle — CLAUDE.md §5.3.
:func:`px` converts a dollar string for readability in tests, using
``decimal.Decimal`` so ``"187.50"`` never becomes ``1874999``.

Timestamps
----------
6 bytes, nanoseconds since midnight US/Eastern. 09:30:00 ET is
``34_200 * 10**9``.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Iterable, Sequence

# =============================================================================
# 1. Constants — mirrored from rtl/pkg/itch_pkg.sv
# =============================================================================
# VERIFY: TotalView-ITCH 5.0 spec, section "Message Formats".
MSG_SYSTEM_EVENT = b"S"
MSG_STOCK_DIRECTORY = b"R"
MSG_TRADING_ACTION = b"H"
MSG_REG_SHO = b"Y"
MSG_MKT_PARTICIPANT = b"L"
MSG_MWCB_DECLINE = b"V"
MSG_MWCB_STATUS = b"W"
MSG_IPO_QUOTING = b"K"
MSG_LULD_COLLAR = b"J"
MSG_OPERATIONAL_HALT = b"h"
MSG_ADD_ORDER = b"A"
MSG_ADD_ORDER_MPID = b"F"
MSG_ORDER_EXECUTED = b"E"
MSG_ORDER_EXEC_PRICE = b"C"
MSG_ORDER_CANCEL = b"X"
MSG_ORDER_DELETE = b"D"
MSG_ORDER_REPLACE = b"U"
MSG_TRADE = b"P"
MSG_CROSS_TRADE = b"Q"
MSG_BROKEN_TRADE = b"B"
MSG_NOII = b"I"
MSG_RPII = b"N"

#: Fixed length in bytes INCLUDING the 1-byte type code.
#: VERIFY: spec, per-message "Length" field. Mirrors itch_pkg::LEN_*.
#: ⚠️ Every ITCH message type has a FIXED length. That is what makes the FPGA
#:    decoder a fixed-offset field extraction with a type-indexed mux rather
#:    than a parsing state machine — the single most important property of the
#:    feed. The decoder MUST cross-check the MoldUDP64 block length against this
#:    table and count a mismatch as a decode error rather than proceeding.
MSG_LEN: dict[bytes, int] = {
    MSG_SYSTEM_EVENT: 12,
    MSG_STOCK_DIRECTORY: 39,
    MSG_TRADING_ACTION: 25,
    MSG_REG_SHO: 20,
    MSG_MKT_PARTICIPANT: 26,
    MSG_MWCB_DECLINE: 35,
    MSG_MWCB_STATUS: 12,
    MSG_IPO_QUOTING: 28,
    MSG_LULD_COLLAR: 35,
    MSG_OPERATIONAL_HALT: 21,
    MSG_ADD_ORDER: 36,
    MSG_ADD_ORDER_MPID: 40,
    MSG_ORDER_EXECUTED: 31,
    MSG_ORDER_EXEC_PRICE: 36,
    MSG_ORDER_CANCEL: 23,
    MSG_ORDER_DELETE: 19,
    MSG_ORDER_REPLACE: 35,
    MSG_TRADE: 44,
    MSG_CROSS_TRADE: 40,
    MSG_BROKEN_TRADE: 19,
    MSG_NOII: 50,
    MSG_RPII: 20,
}
LEN_MAX = 50

# Side encoding. VERIFY: spec.
SIDE_BUY = b"B"
SIDE_SELL = b"S"

# System Event codes — drive the global session state machine.
SYSEV_START_MESSAGES = b"O"
SYSEV_START_SYSTEM = b"S"
SYSEV_START_MARKET = b"Q"
SYSEV_END_MARKET = b"M"
SYSEV_END_SYSTEM = b"E"
SYSEV_END_MESSAGES = b"C"

# Trading Action state codes — per symbol.
TRADE_ACT_HALTED = b"H"
TRADE_ACT_PAUSED = b"P"       # LULD pause
TRADE_ACT_QUOTEONLY = b"Q"
TRADE_ACT_TRADING = b"T"

# Reg SHO Rule 201 short-sale price test state.
SHO_NONE = b"0"
SHO_INTRADAY = b"1"
SHO_RESTRICTED = b"2"

# MoldUDP64 transport framing. VERIFY: MoldUDP64 spec, nasdaqtrader.com.
#   [0..9]   Session         10 bytes alphanumeric
#   [10..17] Sequence Number  8 bytes big-endian, of the FIRST message
#   [18..19] Message Count    2 bytes big-endian
#   [20..]   N blocks, each 2-byte big-endian length + payload
MOLD_HDR_LEN = 20
MOLD_CNT_HEARTBEAT = 0x0000
MOLD_CNT_ENDSESS = 0xFFFF

#: Scale factor for prices. trading_pkg::PRICE_SCALE.
PRICE_SCALE = 10_000

#: 09:30:00 ET in nanoseconds since midnight — the regular-session open.
TS_MARKET_OPEN = 34_200 * 10**9


def px(dollars: str | Decimal | int) -> int:
    """Dollars -> ITCH scaled integer. ``px("187.50") == 1_875_000``.

    Uses ``Decimal``, never ``float``. ``float("187.50") * 10000`` is
    ``1874999.9999999998`` on some inputs, and a price off by one tick is a
    different order.
    """
    return int(Decimal(str(dollars)) * PRICE_SCALE)


def stock(sym: str) -> bytes:
    """8-byte, space-padded, right-padded ASCII stock symbol. VERIFY: spec."""
    b = sym.encode("ascii")
    if len(b) > 8:
        raise ValueError(f"stock symbol {sym!r} exceeds 8 bytes")
    return b.ljust(8, b" ")


# =============================================================================
# 2. Message builders
# =============================================================================
# Every ITCH message begins with the same 11-byte prefix:
#   [0]      Message Type    1 byte
#   [1..2]   Stock Locate    2 bytes BE   <-- the dense integer -> direct index
#   [3..4]   Tracking Number 2 bytes BE
#   [5..10]  Timestamp       6 bytes BE, ns since midnight ET
# The prefix is invariant across all types, so locate/timestamp extraction
# happens BEFORE type dispatch, in parallel with it.
# VERIFY: spec, "Common fields".
def _prefix(mtype: bytes, locate: int, tracking: int, ts_ns: int) -> bytes:
    if not 0 <= locate <= 0xFFFF:
        raise ValueError(f"locate {locate} out of range")
    if not 0 <= ts_ns < (1 << 48):
        raise ValueError(f"timestamp {ts_ns} does not fit in 6 bytes")
    return (
        mtype
        + struct.pack(">H", locate)
        + struct.pack(">H", tracking & 0xFFFF)
        + ts_ns.to_bytes(6, "big")
    )


def _check_len(msg: bytes) -> bytes:
    """Assert the built message matches the fixed length table.

    ⚠️ This is not a formality. If a builder here drifts from ``MSG_LEN``, the
    testbench feeds the DUT a message whose declared MoldUDP64 block length
    disagrees with its type — which is exactly the malformed case the decoder is
    supposed to *reject*. A drifted builder turns every test into an accidental
    error-injection test, and they all fail for the wrong reason.
    """
    want = MSG_LEN.get(msg[0:1])
    if want is not None and len(msg) != want:
        raise AssertionError(
            f"ITCH {msg[0:1]!r}: built {len(msg)} bytes, table says {want}. "
            f"Fix the builder or the table — and check both against the spec PDF."
        )
    return msg


def system_event(code: bytes, ts_ns: int = TS_MARKET_OPEN,
                 locate: int = 0, tracking: int = 0) -> bytes:
    """ITCH 'S' — System Event. 12 bytes. VERIFY: spec.

    Layout: prefix(11) + event_code(1).
    Drives ``trading_pkg::trade_state_e`` at the session level. 'Q' opens
    regular hours; the strategy may only quote in ``TRADE_OPEN``.
    """
    return _check_len(_prefix(MSG_SYSTEM_EVENT, locate, tracking, ts_ns) + code)


def trading_action(locate: int, sym: str, state: bytes, reason: bytes = b"    ",
                   ts_ns: int = TS_MARKET_OPEN, tracking: int = 0) -> bytes:
    """ITCH 'H' — Stock Trading Action. 25 bytes. VERIFY: spec.

    Layout: prefix(11) + stock(8) + trading_state(1) + reserved(1) + reason(4).
    Drives the per-symbol state: 'H' halted, 'P' LULD paused, 'Q' quote-only,
    'T' trading. A halted symbol must produce ``RISK_SYM_HALTED``.
    """
    return _check_len(
        _prefix(MSG_TRADING_ACTION, locate, tracking, ts_ns)
        + stock(sym)
        + state
        + b" "
        + reason.ljust(4, b" ")[:4]
    )


def reg_sho(locate: int, sym: str, action: bytes,
            ts_ns: int = TS_MARKET_OPEN, tracking: int = 0) -> bytes:
    """ITCH 'Y' — Reg SHO Short Sale Price Test Restriction. 20 bytes.

    Layout: prefix(11) + stock(8) + action(1). VERIFY: spec.
    Drives ``sym_risk_t.ssr_active`` and therefore ``RISK_SSR``.
    """
    return _check_len(
        _prefix(MSG_REG_SHO, locate, tracking, ts_ns) + stock(sym) + action
    )


def add_order(locate: int, order_ref: int, side: bytes, shares: int,
              sym: str, price: int, ts_ns: int = TS_MARKET_OPEN,
              tracking: int = 0) -> bytes:
    """ITCH 'A' — Add Order (No MPID Attribution). 36 bytes. VERIFY: spec.

    Layout: prefix(11) + order_ref(8) + side(1) + shares(4) + stock(8) + price(4)
    Offsets mirror itch_pkg::OFF_A_*.
    """
    if side not in (SIDE_BUY, SIDE_SELL):
        raise ValueError(f"side must be b'B' or b'S', got {side!r}")
    return _check_len(
        _prefix(MSG_ADD_ORDER, locate, tracking, ts_ns)
        + struct.pack(">Q", order_ref)
        + side
        + struct.pack(">I", shares)
        + stock(sym)
        + struct.pack(">I", price)
    )


def add_order_mpid(locate: int, order_ref: int, side: bytes, shares: int,
                   sym: str, price: int, mpid: bytes = b"NSDQ",
                   ts_ns: int = TS_MARKET_OPEN, tracking: int = 0) -> bytes:
    """ITCH 'F' — Add Order with MPID Attribution. 40 bytes. VERIFY: spec.

    Identical to 'A' plus a trailing 4-byte MPID. The book must treat 'F'
    exactly as 'A'; the MPID is attribution only. A decoder that handles 'A' and
    drops 'F' loses roughly every attributed quote in the book.
    """
    return _check_len(
        add_order(locate, order_ref, side, shares, sym, price, ts_ns, tracking)
        .replace(MSG_ADD_ORDER, MSG_ADD_ORDER_MPID, 1)
        + mpid.ljust(4, b" ")[:4]
    )


def order_executed(locate: int, order_ref: int, shares: int, match_no: int,
                   ts_ns: int = TS_MARKET_OPEN, tracking: int = 0) -> bytes:
    """ITCH 'E' — Order Executed. 31 bytes. VERIFY: spec.

    Layout: prefix(11) + order_ref(8) + executed_shares(4) + match_number(8).
    Reduces the referenced order. Executing the full remaining quantity removes
    it — the "execute to zero" case, which ``tb/book/test_book_engine.py``
    exercises explicitly because it is where an off-by-one leaves a phantom
    zero-quantity level at the top of the book.
    """
    return _check_len(
        _prefix(MSG_ORDER_EXECUTED, locate, tracking, ts_ns)
        + struct.pack(">Q", order_ref)
        + struct.pack(">I", shares)
        + struct.pack(">Q", match_no)
    )


def order_executed_with_price(locate: int, order_ref: int, shares: int,
                              match_no: int, printable: bytes, price: int,
                              ts_ns: int = TS_MARKET_OPEN,
                              tracking: int = 0) -> bytes:
    """ITCH 'C' — Order Executed With Price. 36 bytes. VERIFY: spec.

    Layout: 'E' layout + printable(1) + execution_price(4).
    ⚠️ ``printable`` = b'N' means the trade does NOT update the last-sale price,
    but it DOES still remove shares from the book. A book that skips
    non-printable executions drifts.
    """
    return _check_len(
        _prefix(MSG_ORDER_EXEC_PRICE, locate, tracking, ts_ns)
        + struct.pack(">Q", order_ref)
        + struct.pack(">I", shares)
        + struct.pack(">Q", match_no)
        + printable
        + struct.pack(">I", price)
    )


def order_cancel(locate: int, order_ref: int, shares: int,
                 ts_ns: int = TS_MARKET_OPEN, tracking: int = 0) -> bytes:
    """ITCH 'X' — Order Cancel. 23 bytes. PARTIAL reduce. VERIFY: spec.

    Layout: prefix(11) + order_ref(8) + cancelled_shares(4).
    ⚠️ 'X' reduces; it does not remove. Removal is 'D'. Treating 'X' as a delete
    empties price levels that still have resting quantity.
    """
    return _check_len(
        _prefix(MSG_ORDER_CANCEL, locate, tracking, ts_ns)
        + struct.pack(">Q", order_ref)
        + struct.pack(">I", shares)
    )


def order_delete(locate: int, order_ref: int,
                 ts_ns: int = TS_MARKET_OPEN, tracking: int = 0) -> bytes:
    """ITCH 'D' — Order Delete. 19 bytes. FULL remove. VERIFY: spec.

    Layout: prefix(11) + order_ref(8).
    """
    return _check_len(
        _prefix(MSG_ORDER_DELETE, locate, tracking, ts_ns)
        + struct.pack(">Q", order_ref)
    )


def order_replace(locate: int, orig_ref: int, new_ref: int, shares: int,
                  price: int, ts_ns: int = TS_MARKET_OPEN,
                  tracking: int = 0) -> bytes:
    """ITCH 'U' — Order Replace. 35 bytes. VERIFY: spec.

    Layout: prefix(11) + original_ref(8) + new_ref(8) + shares(4) + price(4).
    Offsets mirror itch_pkg::OFF_U_*.

    ⚠️ 'U' BOTH removes the original reference AND creates a new one. It is not
       an in-place modify. A book that treats it as one will leak order
       references and drift from the true book — and the drift is slow and
       symbol-specific, so it looks like a market data problem rather than a
       decoder bug.

       The new order inherits the ORIGINAL order's side and stock; neither is
       carried in the 'U' message. A decoder that cannot look up the original
       reference cannot process a replace at all — which is why
       ``tb/feed/test_itch_decoder.py`` asserts the decoder emits BOTH
       references and lets the book engine do the lookup.
    """
    return _check_len(
        _prefix(MSG_ORDER_REPLACE, locate, tracking, ts_ns)
        + struct.pack(">Q", orig_ref)
        + struct.pack(">Q", new_ref)
        + struct.pack(">I", shares)
        + struct.pack(">I", price)
    )


def trade_non_cross(locate: int, order_ref: int, side: bytes, shares: int,
                    sym: str, price: int, match_no: int,
                    ts_ns: int = TS_MARKET_OPEN, tracking: int = 0) -> bytes:
    """ITCH 'P' — Trade (non-cross). 44 bytes. VERIFY: spec.

    ⚠️ 'P' does NOT change the visible book — it reports a trade against a
    non-displayable order. A book that applies it double-counts. It matters only
    for last-price and for volume statistics.
    """
    return _check_len(
        _prefix(MSG_TRADE, locate, tracking, ts_ns)
        + struct.pack(">Q", order_ref)
        + side
        + struct.pack(">I", shares)
        + stock(sym)
        + struct.pack(">I", price)
        + struct.pack(">Q", match_no)
    )


def luld_collar(locate: int, sym: str, ref_price: int, upper: int, lower: int,
                extension: int = 0, ts_ns: int = TS_MARKET_OPEN,
                tracking: int = 0) -> bytes:
    """ITCH 'J' — LULD Auction Collar. 35 bytes. VERIFY: spec.

    Layout: prefix(11) + stock(8) + ref_price(4) + upper(4) + lower(4) + ext(4).
    Feeds ``sym_risk_t.luld_lo/luld_hi`` and therefore ``RISK_LULD_BAND``.
    """
    return _check_len(
        _prefix(MSG_LULD_COLLAR, locate, tracking, ts_ns)
        + stock(sym)
        + struct.pack(">I", ref_price)
        + struct.pack(">I", upper)
        + struct.pack(">I", lower)
        + struct.pack(">I", extension)
    )


def operational_halt(locate: int, sym: str, market_code: bytes = b"Q",
                     action: bytes = b"H", ts_ns: int = TS_MARKET_OPEN,
                     tracking: int = 0) -> bytes:
    """ITCH 'h' — Operational Halt. 21 bytes. VERIFY: spec.

    ⚠️ Lower-case 'h'. Distinct from 'H' (Stock Trading Action). A decoder whose
    type dispatch is case-insensitive silently conflates a regulatory halt with
    an operational one.
    """
    return _check_len(
        _prefix(MSG_OPERATIONAL_HALT, locate, tracking, ts_ns)
        + stock(sym)
        + market_code
        + action
    )


# =============================================================================
# 3. MoldUDP64 framing
# =============================================================================
def mold64(seq: int, msgs: Sequence[bytes], session: bytes = b"TESTSESS01",
           count_override: int | None = None,
           length_override: Sequence[int] | None = None) -> bytes:
    """Build one MoldUDP64 downstream packet.

    Parameters
    ----------
    seq:
        Sequence number of the FIRST message in the packet. Subsequent messages
        are implicitly ``seq+1``, ``seq+2``, ….
    msgs:
        Message payloads, each length-prefixed with a 2-byte big-endian count.
    count_override:
        Write a message-count field that disagrees with ``len(msgs)``.
        ⚠️ Malformed-input case: the deframer must detect and count this, not
        walk off the end of the packet.
    length_override:
        Per-block length fields that disagree with the actual payload lengths.
        ⚠️ Malformed-input case: this is how a length/type mismatch is injected.
    """
    if len(session) > 10:
        raise ValueError("MoldUDP64 session is 10 bytes")
    body = b""
    for i, m in enumerate(msgs):
        ln = length_override[i] if length_override is not None else len(m)
        body += struct.pack(">H", ln) + m
    count = count_override if count_override is not None else len(msgs)
    return (
        session.ljust(10, b" ")
        + struct.pack(">Q", seq)
        + struct.pack(">H", count)
        + body
    )


def mold64_heartbeat(seq: int, session: bytes = b"TESTSESS01") -> bytes:
    """MoldUDP64 heartbeat: header with message count 0, no blocks.

    ⚠️ A heartbeat must NOT advance the expected sequence number. A deframer
    that increments on a heartbeat manufactures a permanent one-message gap and
    puts the book into ``TRADE_STALE`` forever.
    """
    return mold64(seq, [], session=session, count_override=MOLD_CNT_HEARTBEAT)


def mold64_end_of_session(seq: int, session: bytes = b"TESTSESS01") -> bytes:
    """MoldUDP64 end-of-session marker: message count 0xFFFF."""
    return mold64(seq, [], session=session, count_override=MOLD_CNT_ENDSESS)


# =============================================================================
# 4. UDP / IPv4 / Ethernet framing
# =============================================================================
def _ip_checksum(data: bytes) -> int:
    """RFC 1071 one's-complement sum over 16-bit words."""
    if len(data) % 2:
        data += b"\x00"
    total = 0
    for i in range(0, len(data), 2):
        total += (data[i] << 8) | data[i + 1]
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def udp_datagram(payload: bytes, src_port: int = 26400, dst_port: int = 26477,
                 src_ip: str = "10.0.0.1", dst_ip: str = "233.54.12.111",
                 checksum: int | None = 0) -> bytes:
    """UDP header + payload.

    ``checksum=0`` (the default) means "no checksum", which is legal for IPv4
    UDP and is what several market data feeds actually send. Pass ``None`` to
    compute a real one, or an int to force a specific (possibly wrong) value.

    ⚠️ Multicast destination: Nasdaq ITCH is delivered as UDP multicast on
    redundant A/B feeds. The default ``dst_ip`` is in the 233.54.12.0/24 range
    used by Nasdaq's published feed maps — TODO(verify) the exact group and port
    against the current Nasdaq multicast map before any capture comparison. It
    does not matter for RTL tests, which filter on port, but it matters the
    moment a real pcap is replayed alongside synthetic traffic.
    """
    length = 8 + len(payload)
    if checksum is None:
        pseudo = (
            bytes(int(x) for x in src_ip.split("."))
            + bytes(int(x) for x in dst_ip.split("."))
            + b"\x00\x11"
            + struct.pack(">H", length)
        )
        hdr0 = struct.pack(">HHHH", src_port, dst_port, length, 0)
        checksum = _ip_checksum(pseudo + hdr0 + payload)
        if checksum == 0:
            checksum = 0xFFFF   # RFC 768: transmit all-ones, not all-zeros
    return struct.pack(">HHHH", src_port, dst_port, length, checksum) + payload


def ipv4_packet(payload: bytes, src_ip: str = "10.0.0.1",
                dst_ip: str = "233.54.12.111", ident: int = 0,
                ttl: int = 8, proto: int = 17,
                bad_checksum: bool = False) -> bytes:
    """IPv4 header (20 bytes, no options) + payload.

    ``bad_checksum`` corrupts the header checksum for the malformed-input tests.
    ⚠️ The RTL must DROP and COUNT a bad-checksum packet, not silently pass it
    (CLAUDE.md §5.7).
    """
    total_len = 20 + len(payload)
    hdr = (
        bytes([0x45, 0x00])
        + struct.pack(">H", total_len)
        + struct.pack(">H", ident)
        + b"\x00\x00"
        + bytes([ttl, proto])
        + b"\x00\x00"
        + bytes(int(x) for x in src_ip.split("."))
        + bytes(int(x) for x in dst_ip.split("."))
    )
    csum = _ip_checksum(hdr)
    if bad_checksum:
        csum ^= 0xFFFF
    return hdr[:10] + struct.pack(">H", csum) + hdr[12:] + payload


def eth_frame(payload: bytes,
              dst_mac: bytes = b"\x01\x00\x5e\x36\x0c\x6f",
              src_mac: bytes = b"\x02\x00\x00\x00\x00\x01",
              ethertype: int = 0x0800,
              vlan: int | None = None,
              pad_to_min: bool = True) -> bytes:
    """Ethernet II frame WITHOUT the FCS.

    The MAC appends/checks the FCS; ``tuser`` on the AXI-Stream interface
    signals a bad FCS to the fabric (rtl/fpga_top.sv ``md_axis_tuser``), so the
    testbench injects FCS errors via ``AxisDriver(tuser_last=1)`` rather than by
    corrupting bytes here.

    ``vlan`` inserts an 802.1Q tag, which shifts every subsequent header by 4
    bytes. ⚠️ That is a real and commonly-missed case: a header-strip block with
    hardcoded offsets decodes VLAN-tagged traffic as garbage. Worth a directed
    test even if the production feed is untagged, because the day a switch
    starts tagging is not the day you want to find out.
    """
    hdr = dst_mac + src_mac
    if vlan is not None:
        hdr += struct.pack(">HH", 0x8100, vlan & 0x0FFF)
    hdr += struct.pack(">H", ethertype)
    frame = hdr + payload
    if pad_to_min and len(frame) < 60:
        frame += b"\x00" * (60 - len(frame))
    return frame


def eth_udp_frame(mold_payload: bytes, **kw) -> bytes:
    """Convenience: MoldUDP64 payload -> full Ethernet frame ready for the driver."""
    udp_kw = {k: kw.pop(k) for k in
              ("src_port", "dst_port", "src_ip", "dst_ip", "checksum") if k in kw}
    ip_kw = {k: kw.pop(k) for k in
             ("ident", "ttl", "bad_checksum") if k in kw}
    ip_kw.setdefault("src_ip", udp_kw.get("src_ip", "10.0.0.1"))
    ip_kw.setdefault("dst_ip", udp_kw.get("dst_ip", "233.54.12.111"))
    return eth_frame(ipv4_packet(udp_datagram(mold_payload, **udp_kw), **ip_kw), **kw)


# =============================================================================
# 5. Stream generation with a running sequence number
# =============================================================================
@dataclass
class FeedGenerator:
    """Stateful generator producing a correctly-sequenced MoldUDP64 stream.

    Also the place where every *deliberately malformed* case is produced, so a
    test can ask for one by name instead of hand-rolling byte surgery.

    ⚠️ 05-verification §6: "Malformed-input tests assert on the counter, not on
       'didn't crash'. The correct behaviour for a truncated packet is *drop it
       and increment rx_malformed_count*. A design that silently discards it
       passes a 'didn't crash' test and violates CLAUDE.md §5.7."
    """

    session: bytes = b"TESTSESS01"
    seq: int = 1
    ts_ns: int = TS_MARKET_OPEN
    ts_step_ns: int = 1_000
    packets: list[bytes] = field(default_factory=list)

    # -- helpers ------------------------------------------------------------
    def tick(self) -> int:
        self.ts_ns += self.ts_step_ns
        return self.ts_ns

    def emit(self, msgs: Sequence[bytes], **mold_kw) -> bytes:
        """Wrap ``msgs`` in a correctly-sequenced MoldUDP64 packet and advance."""
        pkt = mold64(self.seq, msgs, session=self.session, **mold_kw)
        self.seq += len(msgs)
        self.packets.append(pkt)
        return pkt

    def frame(self, msgs: Sequence[bytes], **kw) -> bytes:
        """Same as :meth:`emit` but returns a full Ethernet frame."""
        return eth_udp_frame(self.emit(msgs), **kw)

    # -- malformed cases ----------------------------------------------------
    def bad_length(self, msg: bytes, delta: int = +1) -> bytes:
        """Block length field disagrees with the message's fixed length.

        ⚠️ THE decode-error case. ``itch_pkg::itch_msg_len()`` exists precisely
        so the decoder can cross-check the MoldUDP64 block length against the
        type's fixed length. The expected behaviour is: drop the message,
        increment a length-mismatch counter, and continue processing the rest of
        the packet — NOT abandon the packet, and NOT decode it anyway.
        """
        pkt = mold64(self.seq, [msg], session=self.session,
                     length_override=[len(msg) + delta])
        self.seq += 1
        self.packets.append(pkt)
        return pkt

    def unknown_type(self, type_code: bytes = b"z", length: int = 20) -> bytes:
        """A message with a type code the decoder does not know.

        ⚠️ NOT an error. Nasdaq adds message types, and a decoder that treats an
        unknown type as fatal stops working the day the venue ships a new
        message. The required behaviour is: count it, skip it BY ITS DECLARED
        LENGTH (never by a guess), and carry on with the next block in the
        packet. ``tb/feed/test_itch_decoder.py`` asserts exactly that.
        """
        body = type_code + b"\x00" * (length - 1)
        pkt = mold64(self.seq, [body], session=self.session)
        self.seq += 1
        self.packets.append(pkt)
        return pkt

    def sequence_gap(self, msgs: Sequence[bytes], gap: int = 1) -> bytes:
        """Skip ``gap`` sequence numbers before this packet.

        ⚠️ A gap means the book is no longer trustworthy. Required behaviour:
        raise the gap flag, put affected symbols into
        ``trading_pkg::TRADE_STALE``, and let the risk gate reject with
        ``RISK_BOOK_STALE``. Trading through a gap is trading on a book you know
        is wrong.
        """
        self.seq += gap
        return self.emit(msgs)

    def duplicate(self, prev_index: int = -1) -> bytes:
        """Re-send a previously generated packet verbatim.

        Models the A/B feed arbitration case: the same MoldUDP64 packet arrives
        on both feeds. The arbiter must forward the first copy and DISCARD the
        second by sequence number — not de-duplicate by payload comparison,
        which would be both slow and wrong (two distinct packets can share a
        payload).
        """
        pkt = self.packets[prev_index]
        self.packets.append(pkt)
        return pkt

    def straddle(self, msg: bytes, offset: int, beat_bytes: int = 8) -> bytes:
        """Place ``msg`` so it starts ``offset`` bytes into a bus beat.

        ⚠️ THE #1 DEFECT CLASS in ITCH parsers (05-verification §6, first row):
        "A 36-byte message at offset 0 and at offset 5 exercise completely
        different reassembly paths." Bugs here appear at some offsets and not
        others, which makes them look intermittent rather than systematic.

        Implemented by prepending short filler messages so the target message
        lands at the requested offset within the 64-bit bus. The filler is an
        Order Delete ('D', 19 bytes) plus padding blocks as needed.

        Returns a full Ethernet frame; the test drives it and asserts the target
        message decodes identically for every ``offset`` in 0..7.
        """
        if not 0 <= offset < beat_bytes:
            raise ValueError("offset must be within one beat")

        # Bytes ahead of the message inside the MoldUDP64 payload: header(20) +
        # per-block (2-byte length + payload) for each filler + this block's
        # 2-byte length. Ethernet(14) + IPv4(20) + UDP(8) = 42 bytes of framing
        # precede the MoldUDP64 header on the bus.
        FRAMING = 14 + 20 + 8
        base = FRAMING + MOLD_HDR_LEN + 2      # offset of msg[0] with no filler
        need = (offset - base) % beat_bytes

        fillers: list[bytes] = []
        # Each filler costs 2 (length field) + len(payload) bytes. An unknown
        # type of arbitrary length lets us hit any residue exactly.
        if need:
            pad_len = need - 2
            while pad_len < 1:
                pad_len += beat_bytes
            fillers.append(b"z" + b"\x00" * (pad_len - 1))

        pkt = mold64(self.seq, fillers + [msg], session=self.session)
        self.seq += len(fillers) + 1
        self.packets.append(pkt)
        return eth_udp_frame(pkt)

    def truncated(self, msgs: Sequence[bytes], cut: int = 4) -> bytes:
        """A packet whose final message is cut short mid-payload.

        Happens for real: a truncated capture, a fragmented datagram, a MAC
        error. Required behaviour is drop-and-count, same as ``bad_length``.
        """
        pkt = self.emit(msgs)
        return pkt[:-cut] if cut < len(pkt) else pkt[:MOLD_HDR_LEN]


# =============================================================================
# 6. Scenario builders — the sequences worth testing over and over
# =============================================================================
def scenario_open_book(gen: FeedGenerator, locate: int = 1234,
                       sym: str = "AAPL") -> list[bytes]:
    """A minimal, correct session: open, build a two-sided book, trade.

    Returned as a list of Ethernet frames. The same message sequence is fed to
    ``golden_book.py`` in ``tb/book/test_book_engine.py``, so any divergence is
    a hardware bug rather than a stimulus difference.
    """
    frames = [
        gen.frame([system_event(SYSEV_START_MESSAGES, gen.tick())]),
        gen.frame([system_event(SYSEV_START_MARKET, gen.tick())]),
        gen.frame([trading_action(locate, sym, TRADE_ACT_TRADING, ts_ns=gen.tick())]),
        # Two-sided book, three levels a side.
        gen.frame([add_order(locate, 0x1001, SIDE_BUY, 300, sym, px("187.50"), gen.tick()),
                   add_order(locate, 0x1002, SIDE_BUY, 200, sym, px("187.49"), gen.tick()),
                   add_order(locate, 0x1003, SIDE_BUY, 100, sym, px("187.48"), gen.tick())]),
        gen.frame([add_order(locate, 0x2001, SIDE_SELL, 400, sym, px("187.51"), gen.tick()),
                   add_order(locate, 0x2002, SIDE_SELL, 150, sym, px("187.52"), gen.tick()),
                   add_order(locate, 0x2003, SIDE_SELL, 250, sym, px("187.53"), gen.tick())]),
    ]
    return frames


def scenario_hard_cases(gen: FeedGenerator, locate: int = 1234,
                        sym: str = "AAPL") -> list[bytes]:
    """The book cases that actually break implementations.

    Each frame here corresponds to a named test in
    ``tb/book/test_book_engine.py``. Kept together so the sequence is
    reproducible and reviewable in one place.
    """
    return [
        # 1. Delete the current best bid -> the book must find a NEW best.
        #    This is the design's one variable-latency stage (fpga_top.sv note).
        gen.frame([order_delete(locate, 0x1001, gen.tick())]),

        # 2. Back-to-back updates to the SAME price level, in one packet.
        #    Exercises the book RMW write-forwarding hazard
        #    (01-fpga-design/03-memory-and-storage.md §4). A missing bypass
        #    shows up ONLY here.
        gen.frame([add_order(locate, 0x1101, SIDE_BUY, 100, sym, px("187.49"), gen.tick()),
                   add_order(locate, 0x1102, SIDE_BUY, 100, sym, px("187.49"), gen.tick()),
                   add_order(locate, 0x1103, SIDE_BUY, 100, sym, px("187.49"), gen.tick())]),

        # 3. Partial cancel then full delete of the same reference.
        gen.frame([order_cancel(locate, 0x1102, 50, gen.tick()),
                   order_delete(locate, 0x1102, gen.tick())]),

        # 4. Replace: old ref out, NEW ref in, at a new price and size.
        gen.frame([order_replace(locate, 0x2001, 0x2101, 500, px("187.55"), gen.tick())]),

        # 5. Execute to exactly zero — the order must disappear, not linger at 0.
        gen.frame([order_executed(locate, 0x1103, 100, 0xAA01, gen.tick())]),

        # 6. Execute more than remaining (should saturate at zero and be counted,
        #    never wrap — trading_pkg sat_sub64 exists for this).
        gen.frame([order_executed(locate, 0x1101, 999_999, 0xAA02, gen.tick())]),
    ]


def scenario_malformed(gen: FeedGenerator, locate: int = 1234,
                       sym: str = "AAPL") -> list[tuple[str, bytes]]:
    """Every malformed case, labelled, so a test can assert the right counter.

    ⚠️ Assert on the COUNTER, not on "didn't crash".
    """
    return [
        ("bad_length_long",
         eth_udp_frame(gen.bad_length(
             add_order(locate, 0x3001, SIDE_BUY, 100, sym, px("100.00"), gen.tick()), +1))),
        ("bad_length_short",
         eth_udp_frame(gen.bad_length(
             add_order(locate, 0x3002, SIDE_BUY, 100, sym, px("100.00"), gen.tick()), -1))),
        ("unknown_type",
         eth_udp_frame(gen.unknown_type(b"z", 20))),
        ("sequence_gap",
         eth_udp_frame(gen.sequence_gap(
             [add_order(locate, 0x3003, SIDE_BUY, 100, sym, px("100.00"), gen.tick())], gap=5))),
        ("duplicate",
         eth_udp_frame(gen.duplicate())),
        ("truncated",
         eth_udp_frame(gen.truncated(
             [add_order(locate, 0x3004, SIDE_BUY, 100, sym, px("100.00"), gen.tick())]))),
        ("bad_ip_checksum",
         eth_udp_frame(gen.emit(
             [add_order(locate, 0x3005, SIDE_BUY, 100, sym, px("100.00"), gen.tick())]),
             bad_checksum=True)),
        ("vlan_tagged",
         eth_udp_frame(gen.emit(
             [add_order(locate, 0x3006, SIDE_BUY, 100, sym, px("100.00"), gen.tick())]),
             vlan=100)),
        ("heartbeat_must_not_advance_seq",
         eth_udp_frame(mold64_heartbeat(gen.seq, gen.session))),
    ]


# =============================================================================
# 7. Parsing back — used by the monitor side of a test
# =============================================================================
def parse_mold64(payload: bytes) -> tuple[bytes, int, int, list[bytes]]:
    """Split a MoldUDP64 packet into (session, seq, count, [messages]).

    Deliberately strict: raises on anything inconsistent, because this function
    is used to check what the DUT *should* have seen. Lenient parsing here would
    let a malformed-stimulus bug masquerade as a DUT bug.
    """
    if len(payload) < MOLD_HDR_LEN:
        raise ValueError(f"MoldUDP64 packet shorter than header: {len(payload)}B")
    session = payload[0:10]
    seq = struct.unpack(">Q", payload[10:18])[0]
    count = struct.unpack(">H", payload[18:20])[0]
    msgs: list[bytes] = []
    off = MOLD_HDR_LEN
    if count in (MOLD_CNT_HEARTBEAT, MOLD_CNT_ENDSESS):
        return session, seq, count, msgs
    for _ in range(count):
        if off + 2 > len(payload):
            raise ValueError(f"truncated block length field at offset {off}")
        ln = struct.unpack(">H", payload[off:off + 2])[0]
        off += 2
        if off + ln > len(payload):
            raise ValueError(f"block claims {ln}B but only "
                             f"{len(payload) - off}B remain")
        msgs.append(payload[off:off + ln])
        off += ln
    return session, seq, count, msgs


def parse_itch(msg: bytes) -> dict:
    """Decode one ITCH message into a dict. The testbench-side reference decode.

    ⚠️ This shares its offsets with the builders above and therefore with
    ``itch_pkg.sv``. It is a convenience for reading test failures, NOT an
    independent check. The independent check is a human with the spec PDF.
    """
    t = msg[0:1]
    d: dict = {
        "type": t,
        "locate": struct.unpack(">H", msg[1:3])[0],
        "tracking": struct.unpack(">H", msg[3:5])[0],
        "ts_ns": int.from_bytes(msg[5:11], "big"),
        "len": len(msg),
        "len_ok": MSG_LEN.get(t) == len(msg),
    }
    if t in (MSG_ADD_ORDER, MSG_ADD_ORDER_MPID):
        d.update(order_ref=struct.unpack(">Q", msg[11:19])[0],
                 side=msg[19:20],
                 shares=struct.unpack(">I", msg[20:24])[0],
                 stock=msg[24:32].rstrip(b" "),
                 price=struct.unpack(">I", msg[32:36])[0])
    elif t in (MSG_ORDER_EXECUTED, MSG_ORDER_EXEC_PRICE):
        d.update(order_ref=struct.unpack(">Q", msg[11:19])[0],
                 shares=struct.unpack(">I", msg[19:23])[0],
                 match_no=struct.unpack(">Q", msg[23:31])[0])
        if t == MSG_ORDER_EXEC_PRICE:
            d.update(printable=msg[31:32],
                     price=struct.unpack(">I", msg[32:36])[0])
    elif t == MSG_ORDER_CANCEL:
        d.update(order_ref=struct.unpack(">Q", msg[11:19])[0],
                 shares=struct.unpack(">I", msg[19:23])[0])
    elif t == MSG_ORDER_DELETE:
        d.update(order_ref=struct.unpack(">Q", msg[11:19])[0])
    elif t == MSG_ORDER_REPLACE:
        d.update(order_ref=struct.unpack(">Q", msg[11:19])[0],
                 new_order_ref=struct.unpack(">Q", msg[19:27])[0],
                 shares=struct.unpack(">I", msg[27:31])[0],
                 price=struct.unpack(">I", msg[31:35])[0])
    elif t == MSG_SYSTEM_EVENT:
        d.update(event=msg[11:12])
    elif t == MSG_TRADING_ACTION:
        d.update(stock=msg[11:19].rstrip(b" "), state=msg[19:20],
                 reason=msg[21:25])
    elif t == MSG_REG_SHO:
        d.update(stock=msg[11:19].rstrip(b" "), action=msg[19:20])
    return d
