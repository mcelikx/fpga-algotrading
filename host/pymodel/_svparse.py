"""_svparse.py — a deliberately small SystemVerilog constant scraper.

WHY THIS EXISTS
---------------
``host/pymodel`` is the verification ORACLE.  It mirrors constants, enum
numbering and struct widths out of ``rtl/pkg/itch_pkg.sv`` and
``rtl/pkg/trading_pkg.sv``.  A mirror that can drift is worse than no mirror at
all: the fabric and the oracle would disagree, and the disagreement would look
like an RTL bug.

The C++ half of ``host/`` catches drift with ``static_assert``.  Python has no
compile step, so this module supplies the equivalent: at import time the mirror
modules re-read the SystemVerilog packages and raise
:class:`ContractMismatch` if a single value has moved.

DESIGN NOTE — DUMB ON PURPOSE
-----------------------------
This is not a SystemVerilog parser.  It is a regex scraper that understands
exactly the four constructs the two packages actually use:

    parameter <type> NAME = <expr>;
    typedef logic [<hi>:<lo>] name_t;
    typedef enum logic [<hi>:<lo>] { A = 3'd0, B = 3'd1 } name_e;
    typedef struct packed { <type> field; ... } name_t;

Anything more general would need to be verified itself, and an unverified
verifier is worthless.  If the packages ever grow a construct this cannot read,
this module raises loudly rather than guessing.

NO FLOATS: every value produced here is a Python ``int``.
"""

from __future__ import annotations

import pathlib
import re
from dataclasses import dataclass, field

__all__ = [
    "ContractMismatch",
    "SvPackage",
    "SvStruct",
    "SvStructMember",
    "load_package",
]


class ContractMismatch(RuntimeError):
    """The Python mirror disagrees with the SystemVerilog source of truth.

    This is always a hard failure.  There is no "close enough" here: an oracle
    that mirrors a stale constant certifies the wrong answer.
    """


# =============================================================================
# 1. Expression evaluation
# =============================================================================
# The RHS of a `parameter` in these two packages is one of:
#   a plain integer            8192, 156_250
#   a sized literal            32'd1_374_389_535, 16'hFFFF, 3'd0
#   a character literal        "S"          (an 8-bit ASCII code)
#   arithmetic over the above  AXIS_W / 8,  1 << 16,  PRICE_W-1
#   $clog2(<expr>)
# That is the whole grammar.  We rewrite it into Python and evaluate it in an
# empty namespace containing only previously-resolved parameters.

_COMMENT_LINE = re.compile(r"//[^\n]*")
_COMMENT_BLOCK = re.compile(r"/\*.*?\*/", re.DOTALL)

# <width>'<base><digits>  e.g.  32'd1_374_389_535   16'hFFFF   3'd0   1'b1
_SIZED_LITERAL = re.compile(r"\b(\d+)'([sS]?)([hdboHDBO])([0-9a-fA-F_]+)")
_CHAR_LITERAL = re.compile(r'"(.)"')
# After rewriting, only these characters may remain.  Anything else means the
# grammar grew and we must not guess.
_SAFE_EXPR = re.compile(r"^[0-9a-zA-Z_+\-*/%()<>\s]*$")

_BASE_RADIX = {"h": 16, "d": 10, "b": 2, "o": 8}


def _clog2(value: int) -> int:
    """``$clog2`` — ceil(log2(x)), with ``$clog2(0) == 0`` and ``$clog2(1) == 0``."""
    if value <= 1:
        return 0
    return (value - 1).bit_length()


def strip_comments(text: str) -> str:
    """Remove ``//`` and ``/* */`` comments.  No string literals span lines here."""
    return _COMMENT_LINE.sub("", _COMMENT_BLOCK.sub("", text))


def eval_sv_expr(expr: str, known: dict[str, int]) -> int:
    """Evaluate one SystemVerilog constant expression to a Python ``int``.

    ``known`` supplies parameters already resolved from the same package.
    Raises :class:`ContractMismatch` if the expression uses anything outside the
    tiny grammar above — deliberately, so an unreadable package is a build
    failure and not a silent default.
    """
    src = strip_comments(expr).strip()

    def _sized(m: re.Match[str]) -> str:
        digits = m.group(4).replace("_", "")
        radix = _BASE_RADIX[m.group(3).lower()]
        return str(int(digits, radix))

    src = _SIZED_LITERAL.sub(_sized, src)
    src = _CHAR_LITERAL.sub(lambda m: str(ord(m.group(1))), src)
    src = src.replace("$clog2", "clog2")
    # SystemVerilog `/` on `int unsigned` is INTEGER division.  Python's `/` is
    # not, and a float leaking out of here would be a float leaking into a
    # width or a price.  Comments are already stripped, so no `//` survives to
    # be mangled by this.
    src = src.replace("/", "//")

    if not _SAFE_EXPR.match(src):
        raise ContractMismatch(
            f"_svparse cannot evaluate SystemVerilog expression {expr!r} "
            f"(rewritten to {src!r}).  The package grammar grew; extend "
            f"_svparse.py rather than letting the mirror guess."
        )
    namespace: dict[str, object] = {"__builtins__": {}, "clog2": _clog2}
    namespace.update(known)
    try:
        value = eval(src, namespace)  # noqa: S307 - restricted grammar, repo-local input
    except Exception as exc:  # pragma: no cover - defensive
        raise ContractMismatch(f"failed to evaluate {expr!r}: {exc}") from exc
    if not isinstance(value, int):
        raise ContractMismatch(f"{expr!r} evaluated to non-int {value!r}")
    return value


# =============================================================================
# 2. Declaration scraping
# =============================================================================

_PARAM = re.compile(r"\bparameter\b([^;]*);", re.DOTALL)
_IDENT = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
_TYPEDEF_SCALAR = re.compile(
    r"\btypedef\s+logic\s+(?:signed\s+)?\[([^\]]+)\]\s+(\w+)\s*;"
)
_TYPEDEF_ENUM = re.compile(
    r"\btypedef\s+enum\s+logic\s*\[([^\]]+)\]\s*\{(.*?)\}\s*(\w+)\s*;", re.DOTALL
)
_TYPEDEF_STRUCT = re.compile(
    r"\btypedef\s+struct\s+packed\s*\{(.*?)\}\s*(\w+)\s*;", re.DOTALL
)
_STRUCT_MEMBER = re.compile(r"(\w+)\s*(?:\[([^\]]+)\])?\s+(\w+)\s*;")
_ENUM_MEMBER = re.compile(r"(\w+)\s*=\s*([^,}]+)")


@dataclass(frozen=True)
class SvStructMember:
    """One member of a ``struct packed``, in DECLARATION ORDER."""

    name: str
    type_name: str
    width: int


@dataclass(frozen=True)
class SvStruct:
    """A ``struct packed`` with resolved member widths.

    ``members`` is in declaration order, i.e. the order the members appear in
    the ``.sv`` file.  ⚠️ In SystemVerilog the FIRST declared member occupies
    the HIGH bits of the packed value.  See ``trading_pkg_mirror.pack_*``.
    """

    name: str
    members: tuple[SvStructMember, ...]

    @property
    def width(self) -> int:
        return sum(m.width for m in self.members)

    def member_names(self) -> tuple[str, ...]:
        return tuple(m.name for m in self.members)


@dataclass
class SvPackage:
    """Everything we scrape out of one ``.sv`` package file."""

    path: pathlib.Path
    params: dict[str, int] = field(default_factory=dict)
    type_widths: dict[str, int] = field(default_factory=dict)
    enums: dict[str, dict[str, int]] = field(default_factory=dict)
    enum_widths: dict[str, int] = field(default_factory=dict)
    structs: dict[str, SvStruct] = field(default_factory=dict)

    # -- convenience accessors that fail loudly ------------------------------
    def param(self, name: str) -> int:
        if name not in self.params:
            raise ContractMismatch(f"{self.path.name}: no parameter named {name!r}")
        return self.params[name]

    def enum(self, name: str) -> dict[str, int]:
        if name not in self.enums:
            raise ContractMismatch(f"{self.path.name}: no enum named {name!r}")
        return self.enums[name]

    def struct(self, name: str) -> SvStruct:
        if name not in self.structs:
            raise ContractMismatch(f"{self.path.name}: no struct named {name!r}")
        return self.structs[name]


def _range_width(range_expr: str, known: dict[str, int]) -> int:
    """``"PRICE_W-1:0"`` -> 32.  ``"2:0"`` -> 3."""
    hi_s, _, lo_s = range_expr.partition(":")
    hi = eval_sv_expr(hi_s, known)
    lo = eval_sv_expr(lo_s, known)
    return hi - lo + 1


def load_package(path: pathlib.Path) -> SvPackage:
    """Scrape one SystemVerilog package file.

    Parameters are resolved in file order, so a parameter may reference any
    parameter declared above it (which is the only thing SystemVerilog allows
    inside a package anyway).
    """
    text = strip_comments(path.read_text(encoding="utf-8"))
    pkg = SvPackage(path=path)

    # ---- parameters --------------------------------------------------------
    for m in _PARAM.finditer(text):
        decl = m.group(1)
        lhs, sep, rhs = decl.partition("=")
        if not sep:
            continue  # `parameter type name;` with no default — not used here
        names = _IDENT.findall(lhs)
        if not names:
            continue
        name = names[-1]  # the last identifier before '=' is the parameter name
        pkg.params[name] = eval_sv_expr(rhs, pkg.params)

    # ---- scalar typedefs (logic [W-1:0] foo_t) -----------------------------
    for m in _TYPEDEF_SCALAR.finditer(text):
        pkg.type_widths[m.group(2)] = _range_width(m.group(1), pkg.params)

    # ---- enum typedefs -----------------------------------------------------
    for m in _TYPEDEF_ENUM.finditer(text):
        width = _range_width(m.group(1), pkg.params)
        enum_name = m.group(3)
        members: dict[str, int] = {}
        for em in _ENUM_MEMBER.finditer(m.group(2)):
            members[em.group(1)] = eval_sv_expr(em.group(2), pkg.params)
        pkg.enums[enum_name] = members
        pkg.enum_widths[enum_name] = width
        pkg.type_widths[enum_name] = width

    # ---- struct typedefs ---------------------------------------------------
    for m in _TYPEDEF_STRUCT.finditer(text):
        struct_name = m.group(2)
        members_out: list[SvStructMember] = []
        for sm in _STRUCT_MEMBER.finditer(m.group(1)):
            type_name, range_expr, member_name = sm.group(1), sm.group(2), sm.group(3)
            if range_expr is not None:
                width = _range_width(range_expr, pkg.params)
            elif type_name == "logic":
                width = 1
            elif type_name in pkg.type_widths:
                width = pkg.type_widths[type_name]
            else:
                raise ContractMismatch(
                    f"{path.name}: struct {struct_name} member {member_name!r} has "
                    f"unknown type {type_name!r}; teach _svparse.py its width."
                )
            members_out.append(
                SvStructMember(name=member_name, type_name=type_name, width=width)
            )
        pkg.structs[struct_name] = SvStruct(
            name=struct_name, members=tuple(members_out)
        )

    return pkg
