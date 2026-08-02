"""itch_encode.py — build ITCH 5.0 messages and MoldUDP64 packets for tests.

⚠️ THIS IS A FIXTURE BUILDER, NOT A SECOND IMPLEMENTATION.
It emits bytes from the SAME :data:`itch_decode.MESSAGE_LAYOUT` tables the
decoder reads.  Therefore:

    Round-tripping a message through encode -> decode proves NOTHING about
    conformance to the TotalView-ITCH 5.0 spec.  It proves only that the two
    directions of one table agree, which they must.

Its actual jobs are (a) making directed test vectors readable, and (b) letting
``tb/`` generate the alignment sweep and the malformed-input fixtures that
manuals/04-system-architecture/02-feed-handler-design.md §12.3 makes mandatory.
Conformance comes from replaying a real pcap, not from this file.

To build a deliberately WRONG message (a length mismatch, an unknown type),
use :func:`raw_block` / :func:`mold_packet` with hand-supplied bytes.
"""

from __future__ import annotations

from . import itch_pkg_mirror as itch
from .itch_decode import MESSAGE_LAYOUT, FieldKind

__all__ = ["encode_message", "mold_packet", "raw_block", "MOLD_SESSION_DEFAULT"]

MOLD_SESSION_DEFAULT = "PYMODEL001"  # exactly MOLD_SESSION_LEN characters


def encode_message(
    type_code: str,
    *,
    stock_locate: int = 0,
    tracking_number: int = 0,
    timestamp: int = 0,
    **body: int | str,
) -> bytes:
    """Build one well-formed ITCH message of ``type_code``.

    Unspecified body fields default to 0 / spaces.  Every supplied value is
    range-checked against its field width: a fixture that silently truncates a
    price is a test that passes for the wrong reason.
    """
    if type_code not in MESSAGE_LAYOUT:
        raise KeyError(f"no layout for ITCH type {type_code!r}")

    supplied: dict[str, int | str] = {
        "msg_type": type_code,
        "stock_locate": stock_locate,
        "tracking_number": tracking_number,
        "timestamp": timestamp,
        **body,
    }
    known = {spec.name for spec in MESSAGE_LAYOUT[type_code]}
    unknown = set(supplied) - known
    if unknown:
        raise KeyError(
            f"ITCH '{type_code}' has no field(s) {sorted(unknown)}; "
            f"known fields are {sorted(known)}"
        )

    out = bytearray()
    for spec in MESSAGE_LAYOUT[type_code]:
        value = supplied.get(spec.name)
        if spec.kind is FieldKind.UINT:
            number = int(value or 0)
            if not 0 <= number < (1 << (8 * spec.width)):
                raise ValueError(
                    f"{type_code}.{spec.name}={number} does not fit in "
                    f"{spec.width} bytes"
                )
            out += number.to_bytes(spec.width, "big")
        elif spec.kind is FieldKind.CHAR:
            text = str(value if value is not None else " ")
            if len(text) != 1:
                raise ValueError(f"{type_code}.{spec.name} must be one character")
            out += text.encode("ascii")
        else:  # ALPHA — right-padded with spaces
            text = str(value if value is not None else "")
            if len(text) > spec.width:
                raise ValueError(
                    f"{type_code}.{spec.name}={text!r} exceeds {spec.width} bytes"
                )
            out += text.ljust(spec.width).encode("ascii")

    if len(out) != itch.MSG_LEN[type_code]:  # pragma: no cover - layout self-check
        raise AssertionError(
            f"encoder produced {len(out)} bytes for '{type_code}', "
            f"itch_pkg.sv says {itch.MSG_LEN[type_code]}"
        )
    return bytes(out)


def raw_block(payload: bytes, declared_len: int | None = None) -> bytes:
    """A MoldUDP64 message block: 2-byte big-endian length + payload.

    ``declared_len`` overrides the length prefix, which is how you build the
    length-mismatch fixture that §6.2 of the feed-handler manual requires.
    """
    length = len(payload) if declared_len is None else declared_len
    return length.to_bytes(2, "big") + payload


def mold_packet(
    messages: list[bytes] | tuple[bytes, ...],
    *,
    sequence: int = 1,
    session: str = MOLD_SESSION_DEFAULT,
    count: int | None = None,
    declared_lens: list[int | None] | None = None,
) -> bytes:
    """Build a MoldUDP64 downstream packet around ``messages``.

    ``count`` overrides the message-count header field (use
    ``itch.MOLD_CNT_HEARTBEAT`` / ``itch.MOLD_CNT_ENDSESS``, or a wrong value,
    to build malformed fixtures).  ``declared_lens`` overrides individual block
    length prefixes.
    """
    if len(session) != itch.MOLD_SESSION_LEN:
        raise ValueError(
            f"MoldUDP64 session must be exactly {itch.MOLD_SESSION_LEN} characters"
        )
    header = (
        session.encode("ascii")
        + sequence.to_bytes(itch.MOLD_SEQNUM_LEN, "big")
        + (len(messages) if count is None else count).to_bytes(
            itch.MOLD_MSGCNT_LEN, "big"
        )
    )
    body = bytearray()
    for index, payload in enumerate(messages):
        override = None
        if declared_lens is not None and index < len(declared_lens):
            override = declared_lens[index]
        body += raw_block(payload, override)
    return bytes(header) + bytes(body)
