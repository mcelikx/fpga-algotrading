"""Decoder semantics that must never regress.

The two headline cases, both required by
manuals/04-system-architecture/02-feed-handler-design.md §6.2 and
manuals/08-nasdaq/04-totalview-itch-5.0.md §5:

  * an UNKNOWN message type is NOT an error — count it and skip it by its
    MoldUDP64-DECLARED length, never by a guess;
  * a LENGTH MISMATCH between the block length prefix and the type's fixed
    length IS an error, and it abandons the rest of the packet.
"""

from __future__ import annotations

import pytest

from host.pymodel import (
    DecodeStatus,
    GoldenModel,
    SymbolFilter,
    decode_message,
    decode_mold_packet,
    encode_message,
    mold_packet,
    raw_block,
)
from host.pymodel import itch_pkg_mirror as itch


def add_order(ref: int = 1, px: int = 1_000_000, qty: int = 100, side: str = "B") -> bytes:
    return encode_message(
        "A",
        stock_locate=7,
        timestamp=1_000,
        order_reference_number=ref,
        buy_sell_indicator=side,
        shares=qty,
        stock="TEST",
        price=px,
    )


# =============================================================================
# Round trip of the layout tables
# =============================================================================


@pytest.mark.parametrize("type_code", sorted(itch.MSG_LEN))
def test_every_message_type_decodes_at_its_declared_length(type_code: str) -> None:
    raw = encode_message(type_code, stock_locate=42, timestamp=7)
    assert len(raw) == itch.MSG_LEN[type_code]
    result = decode_message(raw, declared_len=len(raw))
    assert result.status is DecodeStatus.OK
    assert result.message is not None
    assert result.message.locate == 42
    assert result.message.timestamp == 7
    assert result.skip_bytes == itch.MSG_LEN[type_code]


def test_big_endian_field_extraction() -> None:
    raw = add_order(ref=0x0102_0304_0506_0708, px=0xDEAD_BEEF, qty=0x0000_1234)
    msg = decode_message(raw).message
    assert msg is not None
    assert msg.u("order_reference_number") == 0x0102_0304_0506_0708
    assert msg.u("price") == 0xDEAD_BEEF
    assert msg.u("shares") == 0x1234
    assert msg.c("stock") == "TEST"  # space padding is stripped


# =============================================================================
# ⚠️ Unknown type: NOT an error, skip by the DECLARED length
# =============================================================================


def test_unknown_type_is_not_an_error_and_skips_by_declared_length() -> None:
    payload = b"z" + b"\x00" * 20  # 'z' is not an ITCH 5.0 type code
    result = decode_message(payload, declared_len=len(payload))
    assert result.status is DecodeStatus.UNKNOWN_TYPE
    assert not result.status.is_error
    assert result.message is None
    # The skip is the DECLARED length, not the payload length we happened to
    # be handed, and certainly not a guess.
    assert result.skip_bytes == len(payload)


def test_unknown_type_with_no_declared_length_refuses_to_guess() -> None:
    result = decode_message(b"z" + b"\x00" * 20, declared_len=None)
    assert result.status is DecodeStatus.UNKNOWN_TYPE
    assert result.skip_bytes == 0, "a decoder with no length must not guess one"


def test_unknown_type_in_a_packet_is_counted_and_the_stream_continues() -> None:
    model = GoldenModel(symbols=SymbolFilter({7: 0}))
    unknown = b"z" + bytes(range(20))
    packet = mold_packet([add_order(ref=1), unknown, add_order(ref=2)], sequence=1)
    result = model.step_packet(packet)

    assert [r.status for r in result.results] == [
        DecodeStatus.OK,
        DecodeStatus.UNKNOWN_TYPE,
        DecodeStatus.OK,
    ]
    assert result.abandoned == "", "an unknown type must not abandon the packet"
    assert model.counters.unknown_message_type == 1
    assert model.counters.msgs_to_book == 2
    # Both adds landed: the unknown type was skipped by its length prefix and
    # the next message decoded cleanly from the right offset.
    assert sorted(model.book.orders) == [1, 2]


# =============================================================================
# ⚠️ Length mismatch: an ERROR, and it abandons the rest of the packet
# =============================================================================


def test_length_mismatch_is_a_decode_error() -> None:
    raw = add_order()
    result = decode_message(raw, declared_len=len(raw) - 1)
    assert result.status is DecodeStatus.LENGTH_MISMATCH
    assert result.status.is_error
    assert result.message is None
    assert result.skip_bytes == 0
    assert "36" in result.detail  # LEN_ADD_ORDER


def test_length_mismatch_abandons_the_remaining_packet() -> None:
    """⚠️ 04.02 §6.2: once the length is wrong the read pointer is wrong, and
    every later message in the packet decodes from the wrong offset — and it
    WILL decode, because arbitrary bytes are a valid type byte roughly one time
    in ten.  That is a silently corrupted book."""
    model = GoldenModel(symbols=SymbolFilter({7: 0}))
    good, bad, after = add_order(ref=1), add_order(ref=2), add_order(ref=3)
    packet = mold_packet(
        [good, bad, after], sequence=1, declared_lens=[None, len(bad) + 4, None]
    )
    result = model.step_packet(packet)

    assert len(result.results) == 2, "decoding must stop at the bad block"
    assert result.results[1].status is DecodeStatus.LENGTH_MISMATCH
    assert "length mismatch" in result.abandoned
    assert model.counters.drop_len_mismatch == 1
    assert model.counters.packet_blocks_abandoned == 1
    # Only the first add was applied, and the symbol is now stale.
    assert sorted(model.book.orders) == [1]
    assert model.top(0).stale is True
    # Sticky first-fault latch.
    assert model.counters.first_error_type == "length_mismatch"


def test_truncated_message_is_an_error() -> None:
    raw = add_order()[:20]
    result = decode_message(raw)
    assert result.status is DecodeStatus.TRUNCATED
    assert result.status.is_error
    assert result.skip_bytes == 0


def test_empty_block_is_an_error() -> None:
    assert decode_message(b"").status is DecodeStatus.EMPTY


# =============================================================================
# MoldUDP64 framing
# =============================================================================


def test_mold_header_fields() -> None:
    packet = decode_mold_packet(mold_packet([add_order()], sequence=1234))
    assert packet.session == "PYMODEL001"
    assert packet.sequence == 1234
    assert packet.count == 1
    assert packet.next_expected == 1235  # sequence counts MESSAGES, not packets
    assert packet.malformed == ""


def test_heartbeat_and_end_of_session() -> None:
    model = GoldenModel()
    hb = mold_packet([], sequence=5, count=itch.MOLD_CNT_HEARTBEAT)
    eos = mold_packet([], sequence=5, count=itch.MOLD_CNT_ENDSESS)
    assert decode_mold_packet(hb).is_heartbeat
    assert decode_mold_packet(eos).is_end_of_session
    model.step_packet(hb)
    model.step_packet(eos)
    assert model.counters.heartbeats == 1
    assert model.counters.end_of_session == 1
    # ⚠️ A heartbeat is not a gap.
    assert model.counters.seq_gaps == 0


def test_truncated_packet_is_malformed_not_an_exception() -> None:
    raw = mold_packet([add_order()], sequence=1)[:-5]
    packet = decode_mold_packet(raw)
    assert packet.malformed != ""
    model = GoldenModel(symbols=SymbolFilter({7: 0}))
    result = model.step_packet(raw)
    assert model.counters.drop_malformed == 1
    assert result.abandoned != ""


def test_short_packet_below_the_header_length() -> None:
    packet = decode_mold_packet(b"\x00" * 4)
    assert packet.malformed != ""
    assert packet.blocks == ()


# =============================================================================
# Sequence tracking: gap, duplicate
# =============================================================================


def test_sequence_gap_stales_every_symbol_and_resyncs_forward() -> None:
    model = GoldenModel(symbols=SymbolFilter({7: 0, 8: 1}))
    model.step_packet(mold_packet([add_order(ref=1)], sequence=1))
    assert model.top(0).stale is False

    # seq 2 is missing; the next packet starts at 5.
    result = model.step_packet(mold_packet([add_order(ref=2)], sequence=5))
    assert result.gap == 4
    assert model.counters.seq_gaps == 1
    assert model.counters.gap_max_size == 4
    # ⚠️ A gap invalidates the book — every symbol on the channel, not just the
    #    one the next message happens to mention.
    assert model.top(0).stale is True
    assert model.top(1).stale is True
    # ...and we resync FORWARD; we never stall waiting for recovery.
    assert model.next_expected == 6


def test_duplicate_packet_is_normal_and_is_not_applied() -> None:
    model = GoldenModel(symbols=SymbolFilter({7: 0}))
    packet = mold_packet([add_order(ref=1)], sequence=1)
    model.step_packet(packet)
    result = model.step_packet(packet)  # the B feed's copy
    assert result.duplicate is True
    assert result.results == ()
    assert model.counters.dup_packets == 1
    assert model.counters.seq_gaps == 0
    assert model.top(0).stale is False, "a duplicate is NORMAL, not a fault"
    assert sorted(model.book.orders) == [1]


# =============================================================================
# Filtering and locate range
# =============================================================================


def test_unsubscribed_locate_is_filtered_not_dropped() -> None:
    model = GoldenModel(symbols=SymbolFilter({7: 0}))
    step = model.step_message(
        encode_message("A", stock_locate=99, order_reference_number=1, shares=1, price=1)
    )
    assert step.status is DecodeStatus.OK
    assert step.filtered is True
    assert step.evt is None
    assert model.counters.msgs_filtered == 1
    assert model.counters.msgs_to_book == 0
    # ⚠️ NORMAL, not an error: no sticky fault latched.
    assert model.counters.first_error_type == ""


def test_bad_side_character_is_counted() -> None:
    """The RTL decodes side as ``(byte == 'B')``; so does the model.  A byte
    that is neither 'B' nor 'S' therefore becomes a SELL in both — and the
    counter is how you find out it happened."""
    model = GoldenModel(symbols=SymbolFilter({7: 0}))
    step = model.step_message(add_order(ref=1, side="Z"))
    assert model.counters.bad_side_char == 1
    assert step.evt is not None
    assert step.evt.side.name == "SELL"
