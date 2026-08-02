"""tb_util.py — the shared foundation every cocotb testbench in this repo imports.

WHY THIS FILE EXISTS
--------------------
Two things in this project are easy to get silently wrong across a suite of
testbenches written by different people at different times:

1. **The latency budget drifting away from the RTL.**  ``rtl/fpga_top.sv``'s
   header holds the master per-stage cycle budget.  If a testbench hardcodes
   "the risk gate takes 2 cycles" and someone later adds a pipeline stage *and*
   updates the header table, the test keeps passing while the design gets
   slower.  So this module **parses the budget table out of ``fpga_top.sv`` at
   import time**.  The RTL header is the single source of truth; a test that
   asserts against ``BUDGET`` cannot go stale, and a regression that adds a
   pipeline stage fails the build instead of quietly costing nanoseconds.

2. **Unreproducible random failures.**  Every randomized test in this suite pulls
   its RNG from :func:`seeded_rng`, which logs ``SEED=<n>`` as the first line of
   output and threads that seed into every assertion message.  A random failure
   you cannot reproduce is a rumour, not a finding
   (manuals/01-fpga-design/05-verification-and-simulation.md §6).

This file is SHARED AND FROZEN.  Import from it; do not edit it as part of
writing a testbench.  If you need something here that is missing, say so in your
report rather than adding it locally.

Standard import shim for a test file in ``tb/<block>/``::

    import sys, pathlib
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "common"))
    from tb_util import BUDGET, seeded_rng, start_clock, reset_dut  # noqa: E402
"""

from __future__ import annotations

import enum
import os
import pathlib
import random
import re
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable, Sequence

# cocotb is optional at import time so that this module can be exercised by
# plain pytest / a REPL without a simulator present.
try:
    import cocotb
    from cocotb.clock import Clock
    from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge, Timer

    HAVE_COCOTB = True
except ImportError:  # pragma: no cover - only hit outside a cocotb run
    HAVE_COCOTB = False
    cocotb = None  # type: ignore[assignment]


# =============================================================================
# 1. Repository geography
# =============================================================================

TB_COMMON_DIR = pathlib.Path(__file__).resolve().parent
TB_DIR = TB_COMMON_DIR.parent
REPO_ROOT = TB_DIR.parent
RTL_DIR = REPO_ROOT / "rtl"
FPGA_TOP = RTL_DIR / "fpga_top.sv"
RTL_FILELIST = RTL_DIR / "filelist.f"
TB_FILELIST = TB_DIR / "filelist.f"


def rtl_exists(relpath: str) -> bool:
    """True if an RTL source exists.  Path is relative to the repository root.

    Most of ``rtl/`` is not written yet; a testbench can use this to emit a clear
    skip rather than an inscrutable elaboration error.
    """
    return (REPO_ROOT / relpath).is_file()


def parse_filelist(path: pathlib.Path | str = RTL_FILELIST) -> list[pathlib.Path]:
    """Parse a ``filelist.f`` into absolute paths of the sources that EXIST.

    Honours the documented format: one repo-root-relative path per line, ``//``
    comments, ``+incdir+`` lines (returned separately by :func:`parse_incdirs`).
    Non-existent entries are skipped so a partially-built tree still elaborates.
    """
    path = pathlib.Path(path)
    out: list[pathlib.Path] = []
    if not path.is_file():
        return out
    for raw in path.read_text().splitlines():
        line = raw.split("//", 1)[0].strip()
        if not line or line.startswith("+") or line.startswith("-"):
            continue
        cand = REPO_ROOT / line
        if cand.is_file():
            out.append(cand)
    return out


def parse_incdirs(path: pathlib.Path | str = RTL_FILELIST) -> list[pathlib.Path]:
    """Return the ``+incdir+`` search paths from a filelist, as absolute paths."""
    path = pathlib.Path(path)
    out: list[pathlib.Path] = []
    if not path.is_file():
        return out
    for raw in path.read_text().splitlines():
        line = raw.split("//", 1)[0].strip()
        if line.startswith("+incdir+"):
            d = REPO_ROOT / line[len("+incdir+"):]
            if d.is_dir():
                out.append(d)
    return out


#: Every RTL source in the canonical filelist that actually exists right now.
RTL: list[pathlib.Path] = parse_filelist()

#: The packages, always needed first in any compile order.
PKG_SOURCES: list[pathlib.Path] = [
    p for p in (RTL_DIR / "pkg" / "trading_pkg.sv", RTL_DIR / "pkg" / "itch_pkg.sv")
    if p.is_file()
]


def sim_sources(*extra: str | pathlib.Path) -> list[str]:
    """Source list for a cocotb runner: packages, then the named extras.

    ``extra`` entries are repo-root-relative paths or absolute paths.  Missing
    files are dropped (the tree is partially built) and duplicates collapsed,
    preserving order.
    """
    ordered: list[pathlib.Path] = list(PKG_SOURCES)
    for e in extra:
        p = pathlib.Path(e)
        p = p if p.is_absolute() else (REPO_ROOT / p)
        if p.is_file():
            ordered.append(p)
    seen: set[pathlib.Path] = set()
    uniq: list[str] = []
    for p in ordered:
        if p not in seen:
            seen.add(p)
            uniq.append(str(p))
    return uniq


# =============================================================================
# 2. Clocking constants — mirrored from trading_pkg.sv §1
# =============================================================================

CORE_CLK_MHZ = 156.25
CORE_CLK_NS = 6.400
CLK_NS = CORE_CLK_NS  # the datapath clock period; alias used by most testbenches


def cycles_to_ns(cycles: float) -> float:
    """Convert a core-clock cycle count to nanoseconds."""
    return cycles * CORE_CLK_NS


def ns_to_cycles(ns: float) -> float:
    """Convert nanoseconds to core-clock cycles (may be fractional)."""
    return ns / CORE_CLK_NS


# =============================================================================
# 3. THE LATENCY BUDGET — parsed from rtl/fpga_top.sv, never hardcoded
# =============================================================================

# Canonical stage ids -> the distinguishing text of the row in fpga_top.sv's
# header table.  Matching is done on a lowercase substring so that cosmetic
# rewording of a row does not break every testbench, but a stage that DISAPPEARS
# from the table raises loudly at import time.
_STAGE_MATCH: dict[str, str] = {
    "gt_rx": "optics + gt rx",
    "mac_rx": "mac rx",
    "eth_ip_udp": "ethernet/ipv4/udp header strip",
    "mold_ab": "moldudp64 deframe",
    "itch_assemble": "itch message assembly",
    "itch_decode": "itch decode",
    "symbol_filter": "symbol filter",
    "order_id_map": "order-id map lookup",
    "book_update": "book level update",
    "strategy": "strategy parameter read",
    "risk_gate": "pre-trade risk gate",
    "ouch_encode": "ouch template read",
    "soupbin_tcp": "tcp/soupbintcp framing",
    "mac_tx": "mac tx",
    "gt_tx": "gt tx pcs/pma",
}

# Stages implemented in fabric (i.e. that a cocotb test can actually measure).
# The two hard-IP optics/GT rows are not measurable in RTL simulation.
FABRIC_STAGES: tuple[str, ...] = tuple(
    s for s in _STAGE_MATCH if s not in ("gt_rx", "gt_tx")
)


@dataclass(frozen=True)
class BudgetRow:
    """One row of the master latency budget in ``rtl/fpga_top.sv``."""

    stage_id: str
    description: str
    cycles: int | None  # None for the hard-IP rows, which quote ns only
    ns: float
    cum_ns: float
    fixed: bool  # False => the documented variable-latency stage (bounded)

    def __str__(self) -> str:  # pragma: no cover - diagnostics only
        cyc = "-" if self.cycles is None else str(self.cycles)
        kind = "fixed" if self.fixed else "var(bounded)"
        return f"{self.stage_id}: {cyc} cyc / {self.ns} ns [{kind}] — {self.description}"


class BudgetParseError(RuntimeError):
    """Raised when ``rtl/fpga_top.sv``'s budget table cannot be read.

    This is deliberately fatal.  A suite that silently falls back to hardcoded
    numbers is exactly the failure mode this module exists to prevent.
    """


# "//   MAC RX (cut-through)          2    12.8     102.8   fixed"
# "//   Optics + GT RX PMA/PCS ...     -   ~90.0      90.0   fixed"
_ROW_RE = re.compile(
    r"^//\s+(?P<desc>\S(?:.*?\S)?)\s{2,}"
    r"(?P<cyc>-|\d+)\s+"
    r"~?(?P<ns>\d+(?:\.\d+)?)\s+"
    r"~?(?P<cum>\d+(?:\.\d+)?)\s+"
    r"(?P<kind>fixed|var\*?)\s*$"
)
# "//   FABRIC total                                 20   128.0"
_TOTAL_RE = re.compile(
    r"^//\s+FABRIC total\s+(?P<cyc>\d+)\s+(?P<ns>\d+(?:\.\d+)?)\s*$", re.IGNORECASE
)


class LatencyBudget:
    """The master per-stage latency budget, read from ``rtl/fpga_top.sv``.

    Assert against this, never against a literal.  ``fpga_top.sv``'s header is
    the contract; this class is the only sanctioned way for a testbench to read
    it, so the budget cannot drift out of sync with the design.
    """

    def __init__(self, top_sv: pathlib.Path = FPGA_TOP):
        self.source = top_sv
        self.rows: dict[str, BudgetRow] = {}
        self.fabric_total_cycles: int = 0
        self.fabric_total_ns: float = 0.0
        self._parse(top_sv)

    # -- parsing ----------------------------------------------------------
    def _parse(self, top_sv: pathlib.Path) -> None:
        if not top_sv.is_file():
            raise BudgetParseError(
                f"{top_sv} not found — the master latency budget lives in its header "
                "and every latency assertion in the suite depends on it."
            )
        text = top_sv.read_text()
        for raw in text.splitlines():
            line = raw.rstrip()
            m_total = _TOTAL_RE.match(line)
            if m_total:
                self.fabric_total_cycles = int(m_total.group("cyc"))
                self.fabric_total_ns = float(m_total.group("ns"))
                continue
            m = _ROW_RE.match(line)
            if not m:
                continue
            desc = m.group("desc").strip()
            key = desc.lower()
            stage_id = next(
                (sid for sid, frag in _STAGE_MATCH.items() if frag in key), None
            )
            if stage_id is None or stage_id in self.rows:
                continue
            self.rows[stage_id] = BudgetRow(
                stage_id=stage_id,
                description=desc,
                cycles=None if m.group("cyc") == "-" else int(m.group("cyc")),
                ns=float(m.group("ns")),
                cum_ns=float(m.group("cum")),
                fixed=m.group("kind").startswith("fixed"),
            )

        missing = [s for s in _STAGE_MATCH if s not in self.rows]
        if missing:
            raise BudgetParseError(
                f"latency budget rows missing from {top_sv}: {missing}. "
                "Either the header table was reworded or a pipeline stage was "
                "removed — both are system-wide changes (CLAUDE.md §3) and must "
                "be reflected in tb/common/tb_util.py's _STAGE_MATCH."
            )
        if not self.fabric_total_cycles:
            raise BudgetParseError(f"'FABRIC total' row not found in {top_sv}")

    # -- queries ----------------------------------------------------------
    def __contains__(self, stage_id: str) -> bool:
        return stage_id in self.rows

    def row(self, stage_id: str) -> BudgetRow:
        try:
            return self.rows[stage_id]
        except KeyError:
            raise KeyError(
                f"unknown budget stage {stage_id!r}; known stages: "
                f"{sorted(self.rows)} (+ 'fabric_total')"
            ) from None

    def cycles(self, stage_id: str) -> int:
        """Budgeted cycle count for a fabric stage."""
        if stage_id == "fabric_total":
            return self.fabric_total_cycles
        c = self.row(stage_id).cycles
        if c is None:
            raise ValueError(
                f"stage {stage_id!r} is hard IP (optics/GT) and has no cycle budget; "
                "it cannot be measured in RTL simulation."
            )
        return c

    def ns(self, stage_id: str) -> float:
        """Budgeted nanoseconds for a stage."""
        if stage_id == "fabric_total":
            return self.fabric_total_ns
        return self.row(stage_id).ns

    def is_fixed(self, stage_id: str) -> bool:
        """True if the stage is documented as fixed-latency (assert equality)."""
        if stage_id == "fabric_total":
            return True
        return self.row(stage_id).fixed

    # -- assertions -------------------------------------------------------
    def _msg(self, stage_id: str, measured: int, seed: int | None, extra: str) -> str:
        row = None if stage_id == "fabric_total" else self.row(stage_id)
        desc = row.description if row else "FABRIC total"
        seed_s = "" if seed is None else f"  SEED={seed}"
        return (
            f"LATENCY BUDGET VIOLATION [{stage_id}] {extra}\n"
            f"  stage      : {desc}\n"
            f"  budget     : {self.cycles(stage_id)} cyc "
            f"({cycles_to_ns(self.cycles(stage_id)):.1f} ns)\n"
            f"  measured   : {measured} cyc ({cycles_to_ns(measured):.1f} ns)\n"
            f"  delta      : {measured - self.cycles(stage_id):+d} cyc "
            f"({cycles_to_ns(measured - self.cycles(stage_id)):+.1f} ns)\n"
            f"  budget src : {self.source}  (header table — update it in the same\n"
            f"               commit as any pipeline-depth change, CLAUDE.md §3)"
            f"{seed_s}"
        )

    def assert_exact(
        self, measured: int, stage_id: str, seed: int | None = None
    ) -> None:
        """Assert a FIXED-latency stage takes exactly its budgeted cycle count.

        Equality, not ``<=``: on this design determinism is the product
        (CLAUDE.md §5.8).  A stage that is sometimes faster has jitter, and
        jitter is a bug even when the mean improves.
        """
        budget = self.cycles(stage_id)
        if not self.is_fixed(stage_id):
            raise ValueError(
                f"stage {stage_id!r} is documented variable-latency in "
                f"{self.source}; use assert_bounded()"
            )
        assert measured == budget, self._msg(
            stage_id, measured, seed, "(fixed-latency stage: expected EXACT equality)"
        )

    def assert_bounded(
        self, measured: int, stage_id: str, seed: int | None = None
    ) -> None:
        """Assert a variable-latency stage stays within its documented bound.

        Only legitimate for stages the RTL header marks ``var*``.  The bound must
        still hold every single time — "bounded and counted" is the design claim.
        """
        budget = self.cycles(stage_id)
        assert measured <= budget, self._msg(
            stage_id, measured, seed, "(variable-latency stage exceeded its BOUND)"
        )

    def assert_total(self, measured: int, seed: int | None = None) -> None:
        """Assert the end-to-end fabric latency matches the budgeted total."""
        assert measured <= self.fabric_total_cycles, self._msg(
            "fabric_total", measured, seed, "(end-to-end fabric path)"
        )

    def table(self) -> str:  # pragma: no cover - diagnostics only
        lines = [f"latency budget parsed from {self.source}:"]
        for sid in _STAGE_MATCH:
            lines.append("  " + str(self.rows[sid]))
        lines.append(
            f"  fabric_total: {self.fabric_total_cycles} cyc / "
            f"{self.fabric_total_ns} ns"
        )
        return "\n".join(lines)


#: The parsed master budget.  Import this; do not re-instantiate.
BUDGET = LatencyBudget()


# =============================================================================
# 4. Mirrored enums from trading_pkg.sv §3
# =============================================================================
# These MUST track rtl/pkg/trading_pkg.sv.  They are duplicated here rather than
# parsed because an enum-value typo should be caught by a failing test, not by a
# parser that silently agrees with a broken package.


class Side(enum.IntEnum):
    BUY = 0
    SELL = 1


class TradeState(enum.IntEnum):
    """``trade_state_e``.  DISABLED is the reset value — fail-closed."""

    CLOSED = 0
    PREOPEN = 1
    OPEN = 2
    HALTED = 3
    PAUSED = 4
    AUCTION = 5
    STALE = 6
    DISABLED = 7


class BookOp(enum.IntEnum):
    ADD = 0
    EXECUTE = 1
    CANCEL = 2
    DELETE = 3
    REPLACE = 4
    CLEAR = 5
    NOP = 6


class Action(enum.IntEnum):
    NONE = 0
    SEND = 1
    CANCEL = 2


class RiskReason(enum.IntEnum):
    """``risk_reason_e``.  Every reason has its own counter in ``reject_cnt``."""

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
    NONE = 0
    HOST = 1
    WATCHDOG = 2
    MSG_RATE = 3
    POS_BREACH = 4
    GPIO = 5
    LINK_DOWN = 6
    SEQ_FAULT = 7


# =============================================================================
# 5. Mirrored parameters from trading_pkg.sv §1-2
# =============================================================================

AXIS_W = 64
AXIS_KEEP_W = AXIS_W // 8
ITCH_MSG_MAX_BYTES = 64
ITCH_MSG_W = ITCH_MSG_MAX_BYTES * 8
ITCH_LEN_W = 8

N_SYMBOLS = 8192
SYM_IDX_W = 13
N_ACTIVE = 256
ACT_IDX_W = 8

BOOK_LEVELS = 16
LEVEL_IDX_W = 4
ORDER_MAP_ENTRIES = 1 << 16
ORDER_MAP_WAYS = 4

MAX_IN_FLIGHT = 64
CREDIT_W = 7

PRICE_W = 32
PRICE_SCALE = 10_000  # ITCH: 4 implied decimals
QTY_W = 32
NOTIONAL_W = 64
POS_W = 40
CYCLE_CNT_W = 48
TOKEN_W = 112

PRICE_MAX = (1 << PRICE_W) - 1
QTY_MAX = (1 << QTY_W) - 1
NOTIONAL_MAX = (1 << NOTIONAL_W) - 1

KILL_RESP_CYCLES_DEFAULT = 4  # fpga_top.sv parameter default

# div100 reciprocal-multiply constants (trading_pkg.sv §6)
RECIP_100 = 1_374_389_535
RECIP_100_SHIFT = 37


def assert_package_mirror() -> None:
    """Assert the constants mirrored above still match ``rtl/pkg/trading_pkg.sv``.

    The values in §5 are duplicated from the package rather than parsed, so that
    an enum-value typo is caught by a failing test rather than by a parser that
    silently agrees with a broken package.  The cost of duplication is DRIFT, and
    this function is the guard against it: it re-parses the integer parameters
    from the package and compares.

    This is not hypothetical.  During this suite's construction the package
    changed ``CORE_CLK_MHZ = 156.25`` / ``CORE_CLK_NS = 6.400`` (typed ``real``)
    into ``CORE_CLK_KHZ = 156_250`` / ``CORE_CLK_PS = 6_400`` (integer), to
    honour CLAUDE.md §5.3's ban on floating point.  The physical values were
    unchanged, so nothing broke — but nothing would have caught it either.

    Call it from any testbench; it is cheap.  ``test_latency_budget.py`` calls it
    so a package change cannot land without at least one test noticing.
    """
    src = (RTL_DIR / "pkg" / "trading_pkg.sv")
    if not src.is_file():
        return
    text = src.read_text()

    def param(name: str) -> int | None:
        m = re.search(
            rf"parameter\s+(?:int\s+unsigned|logic\s*\[[^\]]*\])\s+{name}\s*=\s*"
            r"(?:\d+'d)?([0-9_]+)",
            text,
        )
        return int(m.group(1).replace("_", "")) if m else None

    expected = {
        "AXIS_W": AXIS_W,
        "ITCH_MSG_MAX_BYTES": ITCH_MSG_MAX_BYTES,
        "N_SYMBOLS": N_SYMBOLS,
        "N_ACTIVE": N_ACTIVE,
        "BOOK_LEVELS": BOOK_LEVELS,
        "ORDER_MAP_WAYS": ORDER_MAP_WAYS,
        "MAX_IN_FLIGHT": MAX_IN_FLIGHT,
        "PRICE_W": PRICE_W,
        "PRICE_SCALE": PRICE_SCALE,
        "QTY_W": QTY_W,
        "NOTIONAL_W": NOTIONAL_W,
        "POS_W": POS_W,
        "CYCLE_CNT_W": CYCLE_CNT_W,
        "TOKEN_W": TOKEN_W,
        "N_RISK_REASONS": N_RISK_REASONS,
        "RECIP_100": RECIP_100,
        "RECIP_100_SHIFT": RECIP_100_SHIFT,
    }
    drift = {}
    for name, mirrored in expected.items():
        actual = param(name)
        if actual is not None and actual != mirrored:
            drift[name] = (mirrored, actual)

    # The clock is expressed in integer kHz/ps in the package; the testbench
    # works in MHz/ns floats for cocotb's Clock().
    khz, ps = param("CORE_CLK_KHZ"), param("CORE_CLK_PS")
    if khz is not None and abs(khz / 1000.0 - CORE_CLK_MHZ) > 1e-6:
        drift["CORE_CLK_KHZ"] = (CORE_CLK_MHZ * 1000, khz)
    if ps is not None and abs(ps / 1000.0 - CORE_CLK_NS) > 1e-6:
        drift["CORE_CLK_PS"] = (CORE_CLK_NS * 1000, ps)

    assert not drift, (
        f"tb_util's mirror of trading_pkg.sv has DRIFTED: "
        f"{{name: (tb_util, rtl)}} = {drift}\n"
        f"  rtl/pkg/trading_pkg.sv is THE interface contract (CLAUDE.md §3). "
        f"Update the mirror in tb/common/tb_util.py §5 to match, and check "
        f"whether the change invalidates any test's assumptions."
    )


def dollars(px: float | str) -> int:
    """Convert a human price to ITCH scaled-integer form.

    ``dollars("187.50") -> 1_875_000``.  Accepts a string (exact) or a float
    (rounded).  Use this in test *setup* only — never let a float reach a
    comparison; the fast path is integer-only (CLAUDE.md §5.3).
    """
    from decimal import Decimal

    return int(Decimal(str(px)) * PRICE_SCALE)


def div100_model(px: int) -> int:
    """Bit-exact software model of ``trading_pkg::div100``."""
    return ((px * RECIP_100) >> RECIP_100_SHIFT) & PRICE_MAX


def is_whole_penny_model(px: int) -> bool:
    """Bit-exact software model of ``trading_pkg::is_whole_penny`` (SEC Rule 612)."""
    return px == ((div100_model(px) * 100) & PRICE_MAX)


def sat_add64(a: int, b: int) -> int:
    """Software model of ``trading_pkg::sat_add64`` — saturating, never wraps."""
    s = a + b
    return NOTIONAL_MAX if s > NOTIONAL_MAX else s


def sat_sub64(a: int, b: int) -> int:
    """Software model of ``trading_pkg::sat_sub64`` — floors at zero."""
    return a - b if a > b else 0


def bswap(value: int, nbytes: int) -> int:
    """Byte-swap ``value`` over ``nbytes`` — ITCH/OUCH are big-endian on the wire."""
    return int.from_bytes(int(value).to_bytes(nbytes, "big"), "little")


# =============================================================================
# 6. Deterministic randomization
# =============================================================================

def seeded_rng(dut: Any = None, name: str | None = None) -> tuple[random.Random, int]:
    """Return ``(rng, seed)`` and LOG the seed as the first line of the test.

    Seed resolution order: ``$SEED`` env var, else a per-test deterministic seed
    derived from ``name``.  The default is deterministic on purpose — a suite
    whose results change run to run is not a regression suite
    (manuals/01-fpga-design/05-verification-and-simulation.md §7.5).  Set
    ``SEED=<n>`` to reproduce a nightly random-soak failure, or ``SEED=random``
    for a fresh one.

    ALWAYS include the returned seed in every assertion message you write.
    """
    env = os.environ.get("SEED")
    if env is None:
        seed = 0xC0FFEE if name is None else (zlib_crc32(name) & 0xFFFF_FFFF)
    elif env.lower() in ("random", "rand", "auto"):
        seed = random.randrange(2**32)
    else:
        seed = int(env, 0)
    label = name or "test"
    line = f"SEED={seed}  (reproduce with: SEED={seed} <make/pytest ...>)  [{label}]"
    if dut is not None and hasattr(dut, "_log"):
        dut._log.info(line)
    return random.Random(seed), seed


def zlib_crc32(s: str) -> int:
    """Stable string -> int hash for deterministic per-test default seeds."""
    import zlib

    return zlib.crc32(s.encode())


def seed_note(seed: int) -> str:
    """Suffix for assertion messages.  Every random assertion must carry this."""
    return f"  [SEED={seed} — reproduce with SEED={seed}]"


# =============================================================================
# 7. Clock / reset helpers
# =============================================================================

def start_clock(dut: Any, clk: str = "clk", period_ns: float = CLK_NS) -> Any:
    """Start a free-running clock and return the cocotb task driving it.

    Defaults to the 156.25 MHz core datapath clock.  Pass ``period_ns`` for the
    MAC/PCIe domains, or when sweeping clock ratios in an async-FIFO test.
    """
    handle = getattr(dut, clk)
    return cocotb.start_soon(Clock(handle, period_ns, units="ns").start())


async def reset_dut(
    dut: Any,
    clk: str = "clk",
    rst: str = "rst",
    cycles: int = 8,
    active_high: bool = True,
) -> None:
    """Apply and release the project-standard synchronous, active-high reset.

    Releases on a rising edge and returns one cycle later, so the caller starts
    with the DUT out of reset and settled.  ``active_high=False`` handles the
    board-level ``*_rst_n`` inputs.
    """
    clk_h = getattr(dut, clk)
    rst_h = getattr(dut, rst)
    rst_h.value = 1 if active_high else 0
    await ClockCycles(clk_h, cycles)
    rst_h.value = 0 if active_high else 1
    await RisingEdge(clk_h)


async def idle(dut: Any, n: int, clk: str = "clk") -> None:
    """Wait ``n`` clock cycles."""
    await ClockCycles(getattr(dut, clk), n)


# =============================================================================
# 8. Cycle-accurate latency measurement
# =============================================================================

class CycleCounter:
    """A free-running cycle counter for the testbench side of a latency measurement.

    Mirrors ``fpga_top.sv``'s ``cycle_cnt``: one time reference, started once,
    never reset.  Use it to timestamp a stimulus event and the response it
    causes, then feed the difference to :meth:`LatencyBudget.assert_exact`.
    """

    def __init__(self, dut: Any, clk: str = "clk"):
        self.dut = dut
        self.clk = getattr(dut, clk)
        self.count = 0
        self._task = None

    def start(self):
        async def _run():
            while True:
                await RisingEdge(self.clk)
                self.count += 1

        self._task = cocotb.start_soon(_run())
        return self._task

    def stop(self) -> None:
        if self._task is not None:
            self._task.kill()
            self._task = None

    def mark(self) -> int:
        """Current cycle stamp."""
        return self.count

    def since(self, mark: int) -> int:
        """Cycles elapsed since ``mark``."""
        return self.count - mark


async def measure_latency(
    dut: Any,
    stimulus: Callable[[], Any],
    is_response: Callable[[], bool],
    clk: str = "clk",
    timeout_cycles: int = 1000,
) -> int:
    """Drive ``stimulus`` and count clock edges until ``is_response()`` is true.

    Returns the latency in cycles: 1 means the response was observable on the
    edge immediately after the stimulus was accepted.  ``is_response`` is
    sampled in the ``ReadOnly`` phase so it sees settled values.

    Raises ``TimeoutError`` with a cycle count rather than hanging — a hung
    latency test tells you nothing, a timeout tells you the pipe stalled.
    """
    clk_h = getattr(dut, clk)
    res = stimulus()
    if hasattr(res, "__await__"):
        await res
    for n in range(1, timeout_cycles + 1):
        await RisingEdge(clk_h)
        await ReadOnly()
        if is_response():
            return n
    raise TimeoutError(
        f"no response within {timeout_cycles} cycles "
        f"({cycles_to_ns(timeout_cycles):.0f} ns) — the pipeline stalled"
    )


@dataclass
class LatencySamples:
    """Collected per-event latencies, reported as a distribution.

    CLAUDE.md §5.8: report p50/p99/p99.9/max, never just the mean.  On a
    fixed-latency stage every percentile must be identical; that identity IS the
    determinism claim, so :meth:`assert_deterministic` is the real test.
    """

    stage_id: str
    samples: list[int] = field(default_factory=list)

    def add(self, cycles: int) -> None:
        self.samples.append(cycles)

    def _pct(self, p: float) -> int:
        if not self.samples:
            raise ValueError("no samples")
        s = sorted(self.samples)
        idx = min(len(s) - 1, int(round((p / 100.0) * (len(s) - 1))))
        return s[idx]

    @property
    def p50(self) -> int:
        return self._pct(50)

    @property
    def p99(self) -> int:
        return self._pct(99)

    @property
    def p999(self) -> int:
        return self._pct(99.9)

    @property
    def max(self) -> int:
        return max(self.samples)

    @property
    def min(self) -> int:
        return min(self.samples)

    def summary(self) -> str:
        return (
            f"{self.stage_id}: n={len(self.samples)} "
            f"min={self.min} p50={self.p50} p99={self.p99} "
            f"p99.9={self.p999} max={self.max} cycles"
        )

    def assert_deterministic(self, seed: int | None = None) -> None:
        """Assert every sample is identical — the fixed-latency claim."""
        uniq = sorted(set(self.samples))
        assert len(uniq) == 1, (
            f"JITTER on fixed-latency stage {self.stage_id!r}: observed "
            f"{uniq} cycles across {len(self.samples)} events. "
            f"Determinism is the product here (CLAUDE.md §5.8); a stage that is "
            f"sometimes faster is still a regression.\n  {self.summary()}"
            + (seed_note(seed) if seed is not None else "")
        )

    def assert_budget(self, seed: int | None = None) -> None:
        """Assert the distribution against the budget row for this stage."""
        if BUDGET.is_fixed(self.stage_id):
            self.assert_deterministic(seed)
            BUDGET.assert_exact(self.p50, self.stage_id, seed)
        else:
            BUDGET.assert_bounded(self.max, self.stage_id, seed)


# =============================================================================
# 9. Scoreboard with first-divergence reporting
# =============================================================================

class Scoreboard:
    """Compare a DUT stream against an oracle stream, stopping at the FIRST
    divergence and printing context.

    "12,481 differences" is unactionable; the first divergence plus the last N
    events that led to it is what turns a failure into a fix
    (manuals/01-fpga-design/05-verification-and-simulation.md §4).
    """

    def __init__(self, name: str, history: int = 8, seed: int | None = None):
        self.name = name
        self.history = history
        self.seed = seed
        self.n_checked = 0
        self._recent: list[str] = []

    def note(self, event: Any) -> None:
        """Record a stimulus event for the failure-context window."""
        self._recent.append(str(event))
        if len(self._recent) > self.history:
            self._recent.pop(0)

    def check(self, actual: Any, expected: Any, context: str = "") -> None:
        """Assert one record matches the oracle; report richly if it does not."""
        self.n_checked += 1
        if actual == expected:
            return
        recent = "\n".join(f"    {e}" for e in self._recent) or "    (none recorded)"
        raise AssertionError(
            f"FIRST DIVERGENCE in {self.name} at record {self.n_checked}"
            f"{(' — ' + context) if context else ''}\n"
            f"  expected : {expected}\n"
            f"  actual   : {actual}\n"
            f"  last {len(self._recent)} stimulus events:\n{recent}"
            + (seed_note(self.seed) if self.seed is not None else "")
        )

    def assert_checked(self, at_least: int) -> None:
        """Guard against a test that passed because it checked nothing."""
        assert self.n_checked >= at_least, (
            f"{self.name}: only {self.n_checked} records checked, expected "
            f">= {at_least}. A scoreboard that never fired is not a passing test."
        )


class CoverageDB:
    """Python-side functional coverage — Verilator has no covergroups.

    Cross the axes that actually interact, e.g.
    ``cov.hit(msg_type=b"A", beat_offset=3, last_in_packet=True)``.  Assert with
    :meth:`assert_all_hit` against an explicitly enumerated bin set.
    """

    def __init__(self, name: str):
        self.name = name
        self.bins: dict[tuple, int] = {}

    def hit(self, **axes: Any) -> None:
        key = tuple(sorted((k, str(v)) for k, v in axes.items()))
        self.bins[key] = self.bins.get(key, 0) + 1

    def count(self, **axes: Any) -> int:
        key = tuple(sorted((k, str(v)) for k, v in axes.items()))
        return self.bins.get(key, 0)

    def assert_all_hit(self, required: Iterable[dict], min_hits: int = 1) -> None:
        missing = [r for r in required if self.count(**r) < min_hits]
        assert not missing, (
            f"{self.name}: {len(missing)} coverage bin(s) below {min_hits} hit(s): "
            f"{missing[:20]}{' ...' if len(missing) > 20 else ''}"
        )

    def summary(self) -> str:
        return f"{self.name}: {len(self.bins)} bins hit, {sum(self.bins.values())} total"


# =============================================================================
# 10. AXI-Stream contract checking
# =============================================================================

class StreamContractChecker:
    """Background checker for the AXI-Stream handshake contract.

    Enforces, on every cycle: while ``tvalid && !tready``, ``tdata``/``tkeep``/
    ``tlast`` are stable and ``tvalid`` does not de-assert.  A driver that
    changes data under a stalled consumer produces corruption that looks like a
    decoder bug fifty modules downstream, which is why this is checked
    continuously rather than at the end.

    Use :class:`axis_driver.AxisDriver` / :class:`axis_monitor.AxisMonitor` from
    the scaffolding for stimulus and collection; this is purely a watchdog.
    """

    def __init__(self, dut: Any, clk: str = "clk", prefix: str = "s_axis",
                 rst: str | None = "rst", seed: int | None = None):
        self.dut = dut
        self.clk = getattr(dut, clk)
        self.prefix = prefix
        self.rst = getattr(dut, rst) if rst and hasattr(dut, rst) else None
        self.seed = seed
        self.violations: list[str] = []
        self.beats = 0
        self._task = None

    def _sig(self, suffix: str):
        return getattr(self.dut, f"{self.prefix}_{suffix}", None)

    def start(self):
        v = self._sig("tvalid")
        r = self._sig("tready")
        if v is None:
            raise AttributeError(f"no {self.prefix}_tvalid on DUT")
        d, k, l = self._sig("tdata"), self._sig("tkeep"), self._sig("tlast")

        async def _run():
            prev = None
            while True:
                await RisingEdge(self.clk)
                await ReadOnly()
                if self.rst is not None and int(self.rst.value):
                    prev = None
                    continue
                try:
                    vv = int(v.value)
                    rr = 1 if r is None else int(r.value)
                    cur = (
                        vv,
                        rr,
                        int(d.value) if d is not None else 0,
                        int(k.value) if k is not None else 0,
                        int(l.value) if l is not None else 0,
                    )
                except ValueError:  # X/Z during bring-up
                    prev = None
                    continue
                if vv and rr:
                    self.beats += 1
                if prev is not None and prev[0] and not prev[1]:
                    # previous cycle was a stall: everything must be stable
                    if cur[0] != 1:
                        self.violations.append(
                            "tvalid de-asserted while stalled (tvalid&&!tready)"
                        )
                    for idx, nm in ((2, "tdata"), (3, "tkeep"), (4, "tlast")):
                        if cur[idx] != prev[idx]:
                            self.violations.append(
                                f"{nm} changed while stalled: "
                                f"0x{prev[idx]:x} -> 0x{cur[idx]:x}"
                            )
                prev = cur

        self._task = cocotb.start_soon(_run())
        return self._task

    def stop(self) -> None:
        if self._task is not None:
            self._task.kill()
            self._task = None

    def assert_clean(self) -> None:
        assert not self.violations, (
            f"AXI-Stream contract violated on {self.prefix} "
            f"({len(self.violations)} violation(s)); first 5:\n  "
            + "\n  ".join(self.violations[:5])
            + (seed_note(self.seed) if self.seed is not None else "")
        )


class NoBackpressureChecker:
    """Assert an RX-side ``tready`` is high on EVERY cycle out of reset.

    CLAUDE.md §5.4: the receive path accepts line rate unconditionally.  If any
    RX consumer ever needs to back-pressure, that is a design bug, not a runtime
    condition — it means dropping frames on the floor at 10 Gbps somewhere the
    counters cannot see.
    """

    def __init__(self, dut: Any, clk: str = "clk", ready: str = "s_axis_tready",
                 rst: str = "rst"):
        self.dut = dut
        self.clk = getattr(dut, clk)
        self.ready = getattr(dut, ready)
        self.ready_name = ready
        self.rst = getattr(dut, rst) if hasattr(dut, rst) else None
        self.stalls = 0
        self._task = None

    def start(self):
        async def _run():
            while True:
                await RisingEdge(self.clk)
                await ReadOnly()
                if self.rst is not None and int(self.rst.value):
                    continue
                try:
                    if not int(self.ready.value):
                        self.stalls += 1
                except ValueError:
                    pass

        self._task = cocotb.start_soon(_run())
        return self._task

    def stop(self) -> None:
        if self._task is not None:
            self._task.kill()
            self._task = None

    def assert_clean(self) -> None:
        assert self.stalls == 0, (
            f"{self.ready_name} de-asserted on {self.stalls} cycle(s). The RX path "
            f"must NEVER back-pressure (CLAUDE.md §5.4) — drop and count instead."
        )


# =============================================================================
# 11. Counter helpers
# =============================================================================

async def read_stat(dut: Any, array: str, index: int) -> int:
    """Read one entry of a DUT ``stat[]`` / counter array port."""
    handle = getattr(dut, array)
    try:
        return int(handle[index].value)
    except TypeError:
        # Flattened by a wrapper: stat_0, stat_1, ...
        return int(getattr(dut, f"{array}_{index}").value)


class CounterCheck:
    """Snapshot counters, run stimulus, assert the exact deltas.

    CLAUDE.md §5.7: every drop, error, and rejected order is counted.  A test
    that asserts "nothing came out" passes on a design that silently discarded
    the input; a test that asserts "the drop counter went up by exactly one"
    does not.
    """

    def __init__(self, dut: Any, array: str, width: int):
        self.dut = dut
        self.array = array
        self.width = width
        self.before: list[int] = []

    async def snapshot(self) -> None:
        self.before = [await read_stat(self.dut, self.array, i) for i in range(self.width)]

    async def assert_delta(self, expected: dict[int, int], seed: int | None = None) -> None:
        """Assert exactly the named counters moved, by exactly the named amounts."""
        after = [await read_stat(self.dut, self.array, i) for i in range(self.width)]
        actual = {
            i: after[i] - self.before[i]
            for i in range(self.width)
            if after[i] != self.before[i]
        }
        exp = {k: v for k, v in expected.items() if v}
        assert actual == exp, (
            f"counter delta mismatch on {self.array}[]\n"
            f"  expected : {exp}\n"
            f"  actual   : {actual}\n"
            f"  (a counter that never fires is a check you cannot trust; an "
            f"unexpected counter moving means the DUT took a different path)"
            + (seed_note(seed) if seed is not None else "")
        )


# =============================================================================
# 12. Misc
# =============================================================================

def as_int(handle: Any, default: int | None = None) -> int:
    """Read a signal as an int, tolerating X/Z by returning ``default``.

    Verilator is 2-state so X should not appear; this exists so a testbench
    shared with a 4-state simulator does not explode during bring-up.
    """
    try:
        return int(handle.value)
    except (ValueError, AttributeError):
        if default is None:
            raise
        return default


def bits(value: int, hi: int, lo: int) -> int:
    """Extract ``value[hi:lo]`` from a packed-struct read."""
    return (int(value) >> lo) & ((1 << (hi - lo + 1)) - 1)


def pack_fields(fields: Sequence[tuple[int, int]]) -> int:
    """Pack ``[(width, value), ...]`` MSB-first, matching SystemVerilog packed
    struct declaration order."""
    out = 0
    for width, value in fields:
        out = (out << width) | (int(value) & ((1 << width) - 1))
    return out


__all__ = [n for n in dir() if not n.startswith("_")]
