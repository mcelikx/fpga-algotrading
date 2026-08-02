"""diffing.py — make "the model and the DUT disagree" cheap to report.

When a cocotb test fails, the only thing that matters is the answer to "what
exactly differed, on which message?"  Everything in this module exists to make
that one line of output correct, complete and short.

Three levels, in the order you want them:

1. :func:`diff_struct` — field-by-field, one struct.  Use it the moment an
   assertion fails on ``book_top_t`` / ``order_req_t`` / ``book_evt_t``.
2. :func:`format_diff` — turns that into a table a human reads in one glance,
   with prices rendered as decimals (by INTEGER division; no floats).
3. :func:`dump_text` / :func:`diff_text` — a stable, sorted, line-per-fact dump
   of the WHOLE model, and a unified diff of two of them.  For "the books
   diverged somewhere in the last thousand messages".

⚠️ manuals/04-system-architecture/03-order-book-in-hardware.md §12: "'Compare at
the end of the run' is not sufficient. Two errors can cancel. Compare after
every message, and stop on the first divergence with the message index — that
index is the whole debugging session."  These helpers are cheap enough to call
on every message.  Call them on every message.
"""

from __future__ import annotations

import difflib
import enum
import json
from dataclasses import dataclass, fields, is_dataclass
from typing import Any, Mapping, Sequence

from .trading_pkg_mirror import format_price

__all__ = [
    "FieldDiff",
    "PRICE_FIELDS",
    "diff_struct",
    "format_diff",
    "dump_text",
    "diff_text",
]

#: Field names that are ITCH scaled-integer prices, so the report can render
#: them as decimals as well as raw integers.  A raw integer alone makes a
#: one-tick error look like a large number; a decimal alone hides which integer
#: the fabric actually held.  Print both.
PRICE_FIELDS: frozenset[str] = frozenset(
    {
        "price",
        "bid_px",
        "ask_px",
        "last_px",
        "fair_value",
        "edge_ticks",
        "resting_bid_px",
        "resting_ask_px",
        "luld_lo",
        "luld_hi",
        "collar_lo",
        "collar_hi",
    }
)


@dataclass(frozen=True, slots=True)
class FieldDiff:
    name: str
    model: object
    dut: object

    def render(self) -> str:
        model_text = _render_value(self.name, self.model)
        dut_text = _render_value(self.name, self.dut)
        return f"{self.name:<14} model={model_text:<24} dut={dut_text}"


def _as_comparable(value: Any) -> Any:
    """Normalise a value so a model enum/bool compares equal to a DUT integer.

    ⚠️ This is the one place a type coercion happens.  It is here, and not
    scattered through the testbenches, so that "the model said BUY and the DUT
    said 0" can never be reported as a mismatch when it is not one.
    """
    if isinstance(value, enum.IntEnum):
        return int(value)
    if isinstance(value, bool):
        return int(value)
    return value


def _render_value(name: str, value: Any) -> str:
    if isinstance(value, enum.Enum):
        return f"{value.name}({int(value.value) if isinstance(value.value, int) else value.value})"
    if isinstance(value, bool):
        return f"{int(value)}"
    if isinstance(value, int) and name in PRICE_FIELDS:
        return f"{value} (${format_price(value)})"
    return repr(value)


def diff_struct(
    model: Any,
    dut: Mapping[str, Any] | Any,
    *,
    ignore: Sequence[str] = (),
) -> list[FieldDiff]:
    """Compare a model dataclass against a DUT struct dump, field by field.

    ``dut`` may be a mapping (the usual cocotb shape: ``{name: int}``) or
    another dataclass of the same type.  Fields present in the model but absent
    from ``dut`` are reported as differing against ``"<missing>"`` rather than
    skipped — a field a testbench forgot to sample is exactly the field the bug
    is in.
    """
    if not is_dataclass(model):
        raise TypeError(f"{type(model).__name__} is not a dataclass")
    dut_map: Mapping[str, Any]
    if isinstance(dut, Mapping):
        dut_map = dut
    elif is_dataclass(dut):
        dut_map = {f.name: getattr(dut, f.name) for f in fields(dut)}
    else:
        raise TypeError("dut must be a mapping or a dataclass")

    ignored = set(ignore)
    out: list[FieldDiff] = []
    for f in fields(model):
        if f.name in ignored:
            continue
        model_value = getattr(model, f.name)
        if f.name not in dut_map:
            out.append(FieldDiff(f.name, model_value, "<missing>"))
            continue
        dut_value = dut_map[f.name]
        if _as_comparable(model_value) != _as_comparable(dut_value):
            out.append(FieldDiff(f.name, model_value, dut_value))
    return out


def format_diff(
    diffs: Sequence[FieldDiff],
    *,
    header: str = "",
    context: str = "",
) -> str:
    """Render a diff list as the body of an assertion message."""
    if not diffs:
        return f"{header}: no differences" if header else "no differences"
    lines: list[str] = []
    if header:
        lines.append(header)
    if context:
        lines.append(f"  context: {context}")
    for d in diffs:
        lines.append("  " + d.render())
    return "\n".join(lines)


def dump_text(snapshot: Mapping[str, Any]) -> str:
    """Stable, sorted, JSON text for a model snapshot.

    Determinism is the whole point: two runs that behaved identically must
    produce byte-identical text, so that :func:`diff_text` shows only real
    divergence.  ``sort_keys=True`` plus the model's own sorted containers give
    that.
    """
    return json.dumps(snapshot, indent=2, sort_keys=True, default=_json_default)


def _json_default(value: Any) -> Any:
    if isinstance(value, enum.Enum):
        return value.name
    if isinstance(value, (set, frozenset, tuple)):
        return list(value)
    if is_dataclass(value) and not isinstance(value, type):
        return {f.name: getattr(value, f.name) for f in fields(value)}
    return str(value)


def diff_text(
    left: Mapping[str, Any] | str,
    right: Mapping[str, Any] | str,
    *,
    left_name: str = "model",
    right_name: str = "dut",
    lines_of_context: int = 3,
) -> str:
    """Unified diff between two model snapshots (or two rendered dumps)."""
    left_text = left if isinstance(left, str) else dump_text(left)
    right_text = right if isinstance(right, str) else dump_text(right)
    if left_text == right_text:
        return ""
    return "".join(
        difflib.unified_diff(
            left_text.splitlines(keepends=True),
            right_text.splitlines(keepends=True),
            fromfile=left_name,
            tofile=right_name,
            n=lines_of_context,
        )
    )
