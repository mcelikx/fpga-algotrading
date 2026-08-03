"""trading_pkg_mirror.py — Python mirror of ``rtl/pkg/trading_pkg.sv``.

⚠️ THIS FILE IS A MIRROR, NOT A SOURCE.  ``rtl/pkg/trading_pkg.sv`` is the
interface contract for the whole system.  At import time this module re-reads
it and raises :class:`ContractMismatch` if a parameter value, an enum's
numbering, a struct's member order, or a struct's total bit width has moved.
That is the Python equivalent of the ``static_assert``s the C++ half of
``host/`` carries, and it exists for the same reason: the golden model decides
what "correct" means, so it must not be allowed to mean something stale.

NUMBER FORMAT — READ THIS BEFORE EDITING
----------------------------------------
Prices and quantities are **ITCH-native scaled integers, 4 implied decimals**
(``PRICE_SCALE = 10000``).  ``$12.3400`` is the integer ``123400``.

    NO FLOATS.  NO ``Decimal``.  ANYWHERE ON THE MODEL PATH.

In RTL that rule is enforced by the language.  In Python it is enforced by
discipline, so: every arithmetic operation in this package is integer
arithmetic; :func:`format_price` renders a price for humans using integer
division and string formatting and never touches a float; and the only place a
float may legally appear is an analysis helper explicitly commented
``ANALYSIS ONLY — never on the model path``.
"""

from __future__ import annotations

import enum
import pathlib
from dataclasses import dataclass, fields

from ._svparse import ContractMismatch, SvPackage, load_package

__all__ = [
    "ContractMismatch",
    "TRADING_PKG_SV",
    "RTL_CROSSCHECK_DONE",
    "Side",
    "TradeState",
    "BookOp",
    "Action",
    "RiskReason",
    "KillSrc",
    "BookEvt",
    "BookTop",
    "OrderReq",
    "SymStrat",
    "OrderToken",
    "PRICE_SCALE",
    "TICK_ITCH_UNITS",
    "format_price",
    "crosscheck_against_rtl",
]

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
TRADING_PKG_SV = REPO_ROOT / "rtl" / "pkg" / "trading_pkg.sv"


# =============================================================================
# 1. System configuration                   (trading_pkg.sv §1)
# =============================================================================
CORE_CLK_KHZ = 156_250
CORE_CLK_PS = 6_400

AXIS_W = 64
AXIS_KEEP_W = AXIS_W // 8

ITCH_MSG_MAX_BYTES = 64
ITCH_MSG_W = ITCH_MSG_MAX_BYTES * 8  # 512
ITCH_LEN_W = 8

N_SYMBOLS = 8192  # raw ITCH stock-locate space
SYM_IDX_W = 13
N_ACTIVE = 256  # filtered / traded set
ACT_IDX_W = 8

BOOK_LEVELS = 2048
LEVEL_IDX_W = 11

ORDER_MAP_ENTRIES = 1 << 16
ORDER_MAP_WAYS = 4

MAX_IN_FLIGHT = 64
CREDIT_W = 7


# =============================================================================
# 2. Scalar types                           (trading_pkg.sv §2)
# =============================================================================
PRICE_W = 32
PRICE_SCALE = 10_000  # ITCH: 4 implied decimals
QTY_W = 32
NOTIONAL_W = 64
POS_W = 40
CYCLE_CNT_W = 48
TOKEN_W = 112  # OUCH order token, 14 bytes

ORDER_REF_W = 64
LOCATE_W = 16
TS_NS_W = 48

PRICE_MAX = (1 << PRICE_W) - 1
QTY_MAX = (1 << QTY_W) - 1
NOTIONAL_MAX = (1 << NOTIONAL_W) - 1
TOKEN_MAX = (1 << TOKEN_W) - 1

#: One tick for an NMS stock >= $1.00 is $0.01, which is 100 ITCH units.
#: ``sym_strat_t.edge_ticks`` is "a threshold, in ticks", so converting it to
#: ITCH price units is a multiply by this constant.  SEC Rule 612.
#: ⚠️ Sub-dollar names quote in $0.0001 (a tick of 1 ITCH unit).  This model
#:    uses the >= $1.00 tick unconditionally, matching ``is_whole_penny()`` in
#:    trading_pkg.sv, which also assumes the penny tick.
TICK_ITCH_UNITS = 100


def format_price(px: int) -> str:
    """Render an ITCH scaled-integer price for a human.

    INTEGER ONLY.  ``123400 -> '12.3400'``.  This is a display helper for
    mismatch reports; it never feeds back into the model.
    """
    if px < 0:
        return "-" + format_price(-px)
    whole, frac = divmod(px, PRICE_SCALE)
    return f"{whole}.{frac:04d}"


def mask(value: int, width: int) -> int:
    """Truncate ``value`` to ``width`` bits, the way a hardware register would."""
    return value & ((1 << width) - 1)


def sat_add64(a: int, b: int) -> int:
    """``trading_pkg::sat_add64`` — saturating, never wraps."""
    s = a + b
    return NOTIONAL_MAX if s > NOTIONAL_MAX else s


def sat_sub64(a: int, b: int) -> int:
    """``trading_pkg::sat_sub64`` — floors at zero."""
    return a - b if a > b else 0


RECIP_100 = 1_374_389_535
RECIP_100_SHIFT = 37


def div100(px: int) -> int:
    """Bit-exact model of ``trading_pkg::div100`` (reciprocal multiply, no divider)."""
    return mask((px * RECIP_100) >> RECIP_100_SHIFT, PRICE_W)


def is_whole_penny(px: int) -> bool:
    """Bit-exact model of ``trading_pkg::is_whole_penny`` — SEC Rule 612."""
    return px == mask(div100(px) * 100, PRICE_W)


# =============================================================================
# 3. Enumerations                           (trading_pkg.sv §3)
# =============================================================================
# ⚠️ Numbering is part of the contract: these values are written into telemetry
#    registers and DMA log records and decoded by tooling that is not this
#    process.  The import-time cross-check pins every one of them.


class Side(enum.IntEnum):
    """``side_e``."""

    BUY = 0
    SELL = 1


class TradeState(enum.IntEnum):
    """``trade_state_e``.  The strategy may only quote in ``OPEN``.

    ``DISABLED`` is the RESET VALUE — fail-closed.
    """

    CLOSED = 0  # outside session
    PREOPEN = 1  # pre-market / accepting cross orders only
    OPEN = 2  # regular hours, quoting permitted
    HALTED = 3  # regulatory or operational halt
    PAUSED = 4  # LULD pause
    AUCTION = 5  # in a cross
    STALE = 6  # sequence gap: book not trustworthy
    DISABLED = 7  # host- or risk-disabled.  RESET VALUE.


class BookOp(enum.IntEnum):
    """``book_op_e`` — what the decoder tells the book engine to do."""

    ADD = 0  # ITCH 'A' / 'F'
    EXECUTE = 1  # ITCH 'E' / 'C'
    CANCEL = 2  # ITCH 'X'  (partial reduce)
    DELETE = 3  # ITCH 'D'  (full remove)
    REPLACE = 4  # ITCH 'U'  (delete old ref, add new ref)
    CLEAR = 5  # resync / start of day
    NOP = 6


class Action(enum.IntEnum):
    """``action_e`` — the strategy's decision alphabet."""

    NONE = 0
    SEND = 1  # new order
    CANCEL = 2  # cancel an existing order by token


class RiskReason(enum.IntEnum):
    """``risk_reason_e``.  Mirrored for completeness and for shared dumps.

    ⚠️ The risk gate itself is NOT modelled here — the host never emits an
    order and this model never decides an order is safe.  ``host/pymodel``
    stops at ``order_req_t``, which is a *request*.
    """

    OK = 0
    MASTER_DISABLED = 1
    KILL_SWITCH = 2
    SYM_DISABLED = 3
    SESSION_CLOSED = 4
    SYM_HALTED = 5
    BOOK_STALE = 6
    SUB_PENNY = 7
    PRICE_COLLAR = 8
    LULD_BAND = 9
    SSR = 10
    MAX_SHARES = 11
    MAX_NOTIONAL = 12
    POS_LIMIT = 13
    GROSS_LIMIT = 14
    OPEN_ORDERS = 15
    MSG_RATE = 16
    DUPLICATE = 17
    SELF_MATCH = 18
    RESTRICTED = 19
    NO_CREDIT = 20
    ZERO_QTY = 21
    ZERO_PRICE = 22
    PARAM_INVALID = 23


N_RISK_REASONS = 24


class KillSrc(enum.IntEnum):
    """``kill_src_e``."""

    NONE = 0
    HOST = 1
    WATCHDOG = 2
    MSG_RATE = 3
    POS_BREACH = 4
    GPIO = 5
    LINK_DOWN = 6
    SEQ_FAULT = 7


# =============================================================================
# 4. Fast-path structs                      (trading_pkg.sv §4)
# =============================================================================
# ⚠️ FIELD ORDER IS PART OF THE CONTRACT.  The dataclass field order below must
#    equal the SystemVerilog struct member order, and the cross-check enforces
#    it.  That is what lets a testbench zip a dumped RTL struct against the
#    model's ``as_tuple()`` and get a field-by-field diff for free.


@dataclass(frozen=True, slots=True)
class BookEvt:
    """``book_evt_t`` — decoded ITCH message handed to the book engine."""

    op: BookOp
    sym: int  # active-set index (post-filter)
    locate: int  # raw ITCH stock locate, for telemetry
    side: Side
    price: int  # ITCH scaled integer
    qty: int
    order_ref: int  # key into the order-ID map
    new_order_ref: int  # ITCH 'U' only: the replacement reference
    exch_ts: int  # exchange timestamp from the message (ns since midnight ET)
    rx_cycle: int  # OUR ingress timestamp, for latency measurement
    printable: bool  # trade is printable (affects last-price)


@dataclass(frozen=True, slots=True)
class BookTop:
    """``book_top_t`` — top of book after this update.

    ⚠️ ``crossed`` and ``stale`` are the two bits ``fpga_top.sv`` asserts on:
    a crossed book must never produce an order, and a stale book must never
    produce an order.  Both are modelled in :mod:`host.pymodel.book`.
    """

    sym: int
    bid_px: int
    bid_qty: int
    ask_px: int
    ask_qty: int
    last_px: int
    bid_valid: bool
    ask_valid: bool
    crossed: bool  # bid >= ask: never act on a crossed book
    stale: bool  # sequence gap / unknown ref seen; book not trustworthy
    top_changed: bool  # top-of-book actually moved this update
    rx_cycle: int


@dataclass(frozen=True, slots=True)
class OrderReq:
    """``order_req_t`` — a strategy REQUEST.  The risk gate may reject it.

    ⚠️ This model produces requests and stops.  It has no path to a wire, by
    construction (host/README.md §3.2: the host never bypasses the risk gate).
    """

    action: Action
    sym: int
    side: Side
    price: int
    qty: int
    post_only: bool  # add-liquidity-only: never cross the spread
    is_short: bool  # short sale -> triggers the SSR check
    strat_id: int  # which strategy primitive fired
    cancel_token: int  # ACT_CANCEL only
    rx_cycle: int


@dataclass(frozen=True, slots=True)
class SymStrat:
    """``sym_strat_t`` — per-symbol strategy parameters, written by the host.

    Reset value is all-zero, which means ``strat_enabled = 0``: fail-closed.
    """

    strat_enabled: bool = False
    strat_select: int = 0  # which hardened primitive to run (4 bits)
    quote_qty: int = 0  # shares
    edge_ticks: int = 0  # threshold, in TICKS (see TICK_ITCH_UNITS)
    min_book_qty: int = 0  # don't act on a thin book
    fair_value: int = 0  # ITCH scaled integer, written by the host at ms cadence
    imbalance_thr: int = 0  # Q8.8 ratio (256 == 1.0)


#: ``sym_strat_t`` member widths, in DECLARATION order.  Total = 149 bits.
SYM_STRAT_MEMBERS: tuple[tuple[str, int], ...] = (
    ("strat_enabled", 1),
    ("strat_select", 4),
    ("quote_qty", QTY_W),
    ("edge_ticks", PRICE_W),
    ("min_book_qty", QTY_W),
    ("fair_value", PRICE_W),
    ("imbalance_thr", 16),
)
SYM_STRAT_BITS = sum(w for _, w in SYM_STRAT_MEMBERS)  # 149
SYM_STRAT_WORDS = (SYM_STRAT_BITS + 31) // 32  # 5, per SHARED_CONTRACT


@dataclass(frozen=True, slots=True)
class OrderToken:
    """``order_token_t`` — the ONLY link between an FPGA order and host accounting.

    112 bits = 14 bytes = ``TOKEN_W``.  Layout per SHARED_CONTRACT:
    ``magic(16) strat_id(4) sym(12) counter(48) rsvd(32)``.
    """

    magic: int = 0  # build/session tag; host rejects a mismatch
    strat_id: int = 0
    sym: int = 0  # active-set index, zero-extended to 12 bits
    counter: int = 0  # monotonic, never reused within a session
    rsvd: int = 0


ORDER_TOKEN_MEMBERS: tuple[tuple[str, int], ...] = (
    ("magic", 16),
    ("strat_id", 4),
    ("sym", 12),
    ("counter", 48),
    ("rsvd", 32),
)
ORDER_TOKEN_BITS = sum(w for _, w in ORDER_TOKEN_MEMBERS)  # 112 == TOKEN_W


# =============================================================================
# 5. Packed-record encoding                 (SHARED_CONTRACT.md)
# =============================================================================
# ⚠️ BIT DIRECTION, STATED ONCE, HERE, AND NOWHERE ELSE.
#
# SystemVerilog places the FIRST declared member of a `struct packed` in the
# HIGH bits.  This module follows the language, not a convention:
#
#     bits[SYM_STRAT_BITS-1 : ...]  = strat_enabled   (first member, high bits)
#     bits[15:0]                    = imbalance_thr   (last member,  low bits)
#
# SHARED_CONTRACT.md offers both directions and asks the implementer to pick
# one, write it down, and assert the total width.  This is the pick, this is
# the writing-down, and :func:`crosscheck_against_rtl` is the assert.
#
# The 32-bit word serialisation is then exactly SHARED_CONTRACT's: the packed
# value is cut LSB-first into little-endian u32 words, so ``word[0]`` holds
# bits [31:0].


def pack_bits(members: tuple[tuple[str, int], ...], values: dict[str, int]) -> int:
    """Pack named fields MSB-first (first member -> high bits) into one integer."""
    out = 0
    for name, width in members:
        value = int(values[name])
        if value != mask(value, width):
            raise ValueError(
                f"{name}={value} does not fit in {width} bits "
                f"(max {(1 << width) - 1}); the fabric would silently truncate it"
            )
        out = (out << width) | value
    return out


def unpack_bits(members: tuple[tuple[str, int], ...], packed: int) -> dict[str, int]:
    """Inverse of :func:`pack_bits`."""
    out: dict[str, int] = {}
    total = sum(w for _, w in members)
    pos = total
    for name, width in members:
        pos -= width
        out[name] = (packed >> pos) & ((1 << width) - 1)
    return out


def bits_to_words(packed: int, n_words: int) -> list[int]:
    """Cut a packed value LSB-first into ``n_words`` little-endian u32 words."""
    return [(packed >> (32 * i)) & 0xFFFF_FFFF for i in range(n_words)]


def words_to_bits(words: list[int] | tuple[int, ...]) -> int:
    """Inverse of :func:`bits_to_words`."""
    out = 0
    for i, w in enumerate(words):
        out |= (w & 0xFFFF_FFFF) << (32 * i)
    return out


def pack_sym_strat(s: SymStrat) -> list[int]:
    """``sym_strat_t`` -> 5 little-endian u32 words, for ``PARAM_STRAT_DATA``."""
    packed = pack_bits(
        SYM_STRAT_MEMBERS,
        {
            "strat_enabled": int(s.strat_enabled),
            "strat_select": s.strat_select,
            "quote_qty": s.quote_qty,
            "edge_ticks": s.edge_ticks,
            "min_book_qty": s.min_book_qty,
            "fair_value": s.fair_value,
            "imbalance_thr": s.imbalance_thr,
        },
    )
    return bits_to_words(packed, SYM_STRAT_WORDS)


def unpack_sym_strat(words: list[int] | tuple[int, ...]) -> SymStrat:
    """Inverse of :func:`pack_sym_strat`."""
    d = unpack_bits(SYM_STRAT_MEMBERS, words_to_bits(words))
    return SymStrat(
        strat_enabled=bool(d["strat_enabled"]),
        strat_select=d["strat_select"],
        quote_qty=d["quote_qty"],
        edge_ticks=d["edge_ticks"],
        min_book_qty=d["min_book_qty"],
        fair_value=d["fair_value"],
        imbalance_thr=d["imbalance_thr"],
    )


def pack_order_token(t: OrderToken) -> int:
    """``order_token_t`` -> a 112-bit integer.

    ⚠️ The byte order this integer takes on the OUCH wire is the ORDER GATEWAY's
    decision, not this model's.  Use :func:`order_token_bytes_be` only if you
    have confirmed big-endian with that component.
    """
    return pack_bits(
        ORDER_TOKEN_MEMBERS,
        {
            "magic": t.magic,
            "strat_id": t.strat_id,
            "sym": t.sym,
            "counter": t.counter,
            "rsvd": t.rsvd,
        },
    )


def unpack_order_token(packed: int) -> OrderToken:
    """Inverse of :func:`pack_order_token`."""
    d = unpack_bits(ORDER_TOKEN_MEMBERS, packed)
    return OrderToken(**{k: d[k] for k in ("magic", "strat_id", "sym", "counter", "rsvd")})


def order_token_bytes_be(t: OrderToken) -> bytes:
    """14 bytes, most-significant byte first.  See the warning on :func:`pack_order_token`."""
    return pack_order_token(t).to_bytes(TOKEN_W // 8, "big")


# =============================================================================
# 6. The cross-check — this module's reason to exist
# =============================================================================

_INT_PARAMS: tuple[str, ...] = (
    "CORE_CLK_KHZ",
    "CORE_CLK_PS",
    "AXIS_W",
    "AXIS_KEEP_W",
    "ITCH_MSG_MAX_BYTES",
    "ITCH_MSG_W",
    "ITCH_LEN_W",
    "N_SYMBOLS",
    "SYM_IDX_W",
    "N_ACTIVE",
    "ACT_IDX_W",
    "BOOK_LEVELS",
    "LEVEL_IDX_W",
    "ORDER_MAP_ENTRIES",
    "ORDER_MAP_WAYS",
    "MAX_IN_FLIGHT",
    "CREDIT_W",
    "PRICE_W",
    "PRICE_SCALE",
    "QTY_W",
    "NOTIONAL_W",
    "POS_W",
    "CYCLE_CNT_W",
    "TOKEN_W",
    "N_RISK_REASONS",
    "RECIP_100",
    "RECIP_100_SHIFT",
)

#: SystemVerilog enum name -> (Python IntEnum, prefix stripped from members).
_ENUM_MAP: tuple[tuple[str, type[enum.IntEnum], str], ...] = (
    ("side_e", Side, "SIDE_"),
    ("trade_state_e", TradeState, "TRADE_"),
    ("book_op_e", BookOp, "BOOK_"),
    ("action_e", Action, "ACT_"),
    ("risk_reason_e", RiskReason, "RISK_"),
    ("kill_src_e", KillSrc, "KILL_"),
)

#: SystemVerilog struct name -> the dataclass whose FIELD ORDER must match.
_STRUCT_MAP: tuple[tuple[str, type], ...] = (
    ("book_evt_t", BookEvt),
    ("book_top_t", BookTop),
    ("order_req_t", OrderReq),
    ("sym_strat_t", SymStrat),
    ("order_token_t", OrderToken),
)


def crosscheck_against_rtl(pkg: SvPackage | None = None) -> list[str]:
    """Compare the mirror against ``rtl/pkg/trading_pkg.sv``.

    Returns a list of mismatch descriptions; empty means the mirror is correct.
    """
    if pkg is None:
        pkg = load_package(TRADING_PKG_SV)
    here = globals()
    problems: list[str] = []

    # -- scalar parameters ---------------------------------------------------
    for name in _INT_PARAMS:
        rtl = pkg.params.get(name)
        if rtl is None:
            problems.append(f"trading_pkg.sv no longer defines {name}")
        elif rtl != here[name]:
            problems.append(f"{name}: mirror={here[name]} trading_pkg.sv={rtl}")

    # -- enum numbering ------------------------------------------------------
    for sv_name, py_enum, prefix in _ENUM_MAP:
        rtl_members = pkg.enums.get(sv_name)
        if rtl_members is None:
            problems.append(f"trading_pkg.sv no longer defines enum {sv_name}")
            continue
        py_members = {m.name: int(m.value) for m in py_enum}
        rtl_stripped = {
            (k[len(prefix):] if k.startswith(prefix) else k): v
            for k, v in rtl_members.items()
        }
        if rtl_stripped != py_members:
            problems.append(
                f"enum {sv_name}: mirror={py_members} trading_pkg.sv={rtl_stripped}"
            )

    # -- struct member ORDER and NAMES --------------------------------------
    for sv_name, py_cls in _STRUCT_MAP:
        try:
            sv_struct = pkg.struct(sv_name)
        except ContractMismatch as exc:
            problems.append(str(exc))
            continue
        sv_names = sv_struct.member_names()
        py_names = tuple(f.name for f in fields(py_cls))
        if sv_names != py_names:
            problems.append(
                f"struct {sv_name}: member order/names differ\n"
                f"      trading_pkg.sv: {sv_names}\n"
                f"      {py_cls.__name__}: {py_names}"
            )

    # -- packed widths (the SHARED_CONTRACT numbers) -------------------------
    for sv_name, expected_bits, label in (
        ("sym_strat_t", SYM_STRAT_BITS, "SYM_STRAT_BITS"),
        ("order_token_t", ORDER_TOKEN_BITS, "ORDER_TOKEN_BITS"),
    ):
        if sv_name in pkg.structs:
            actual = pkg.struct(sv_name).width
            if actual != expected_bits:
                problems.append(
                    f"{label}: mirror={expected_bits} trading_pkg.sv={actual}"
                )
    if ORDER_TOKEN_BITS != TOKEN_W:
        problems.append(f"ORDER_TOKEN_BITS={ORDER_TOKEN_BITS} != TOKEN_W={TOKEN_W}")
    if SYM_STRAT_WORDS != 5:
        problems.append(
            f"SYM_STRAT_WORDS={SYM_STRAT_WORDS} != 5 (SHARED_CONTRACT.md)"
        )

    # -- member widths of the packed records --------------------------------
    for sv_name, members in (
        ("sym_strat_t", SYM_STRAT_MEMBERS),
        ("order_token_t", ORDER_TOKEN_MEMBERS),
    ):
        if sv_name not in pkg.structs:
            continue
        rtl_widths = {m.name: m.width for m in pkg.struct(sv_name).members}
        for name, width in members:
            if rtl_widths.get(name) != width:
                problems.append(
                    f"{sv_name}.{name}: mirror width={width} "
                    f"trading_pkg.sv={rtl_widths.get(name)}"
                )

    return problems


#: True when the RTL package was present and every mirrored value matched.
#: ⚠️ CI MUST assert this — see tests/test_contract_mirror.py.
RTL_CROSSCHECK_DONE: bool = False

if TRADING_PKG_SV.is_file():
    _problems = crosscheck_against_rtl()
    if _problems:
        raise ContractMismatch(
            "host/pymodel/trading_pkg_mirror.py has drifted from "
            f"{TRADING_PKG_SV}:\n  " + "\n  ".join(_problems)
        )
    RTL_CROSSCHECK_DONE = True
