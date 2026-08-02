"""histogram.py — decode the fabric latency histogram; reconstruct percentiles.

Project : FPGA Algorithmic Trading System (Nasdaq Equities)
Mirrors : rtl/telemetry/latency_hist.sv    (bucket semantics — EXACTLY)
          rtl/telemetry/telemetry_pkg.sv   (word address map, LAT_CFG packing)
Governs : manuals/05-optimization/04-measurement-and-profiling.md §5.3, §5.4
          manuals/06-operations/03-monitoring-and-telemetry.md §3, §9

===============================================================================
⚠️  THIS FILE IS A MIRROR OF RTL. IF THE RTL MOVES, THIS IS WRONG SILENTLY.
===============================================================================

The bucket-index arithmetic below is transcribed from `latency_hist.sv` stage 1,
including its edge cases. A decoder that is *nearly* right produces percentiles
that are plausible and wrong, which is worse than a decoder that crashes.

Transcribed semantics, with the RTL line they come from:

  LOG_MODE = 1   (`raw_idx = msb_pos`)
      bucket 0     -> delta == 0                (msb_pos == 0)
      bucket k>=1  -> delta in [2^(k-1), 2^k-1] (msb_pos == k)
      With N_BUCKETS >= DELTA_W+1 this CANNOT overflow — that is the whole
      argument for log2 bucketing.

  LOG_MODE = 0   (`rel = (delta > LIN_BASE) ? delta - LIN_BASE : 0`
                  `raw_idx = rel >> LIN_SHIFT`)
      ⚠ Note `>` not `>=`. Everything at or below LIN_BASE lands in bucket 0
        together with the first real bucket's worth of samples. So with
        LIN_BASE > 0, **bucket 0 is an UNDERFLOW CATCH-ALL**, not a bucket.
        Its lower edge is 0, not LIN_BASE. Any percentile that lands in bucket
        0 of an offset linear histogram is uninformative, and this module says
        so rather than quietly reporting the bucket's nominal edge.

  Overflow (both modes): `raw_idx >= N_BUCKETS` saturates INTO the top bucket
      and ALSO increments `over_cnt`. Overflowed samples are therefore counted
      TWICE in the register file — once in bucket[N-1], once in `over`. They
      are counted ONCE in `n`. sum(buckets) == n still holds.

===============================================================================
THE THREE WAYS A HISTOGRAM LIES, AND HOW THIS MODULE CATCHES THEM
===============================================================================

  1. OVERFLOW (`over != 0`). Samples above the top bucket were folded into it.
     Every percentile that lands in the top bucket is a LOWER BOUND. manual
     §5.3: "a histogram that saturates its top bucket silently reports a max
     that isn't the max" — except here `max` is a register and IS exact, so the
     tool reports the exact max next to the bounded percentile.

  2. COUNTER SATURATION (`sat` sticky). A 32-bit bucket counter hit 2^32-1 and
     stopped. The bank now UNDERSTATES, non-uniformly, in whichever bucket
     saturated first — which is the mode, i.e. the body of the distribution.
     Every percentile derived from a saturated bank is meaningless, not merely
     imprecise. This module refuses percentiles from a saturated bank in strict
     mode and screams in normal mode.

  3. TORN READ (`sum(buckets) != n`). The host read the buckets without
     pulsing SNAP, so the values never coexisted (manual §7, last row;
     06-operations 03 §9). The resulting "distribution" describes nothing.
     This is checked FIRST, before any percentile is computed.
"""

from __future__ import annotations

import argparse
import csv
import json
import pathlib
import sys
from dataclasses import dataclass, field
from typing import Sequence

try:  # package import
    from .latency import (
        CYCLE_PS,
        PERCENTILES,
        Estimate,
        LatencyReport,
        N_RECOMMENDED,
        ProvenanceError,
        RunManifest,
    )
except ImportError:  # executed as a plain script from tools/analysis/
    from latency import (  # type: ignore[no-redef]
        CYCLE_PS,
        PERCENTILES,
        Estimate,
        LatencyReport,
        N_RECOMMENDED,
        ProvenanceError,
        RunManifest,
    )

__all__ = [
    "HistogramGeometry",
    "HistogramSnapshot",
    "TELEM_MAP_MAJOR",
    "decode_words",
    "main",
]


# =============================================================================
# 1. Constants mirrored from rtl/telemetry/telemetry_pkg.sv
# =============================================================================
TELEM_MAP_MAGIC = 0x4654  # "FT"
TELEM_MAP_MAJOR = 1  # host refuses to collect on a MAJOR mismatch
TELEM_UNMAPPED = 0xDEAD_C0DE

A_STATUS = 0x0000
A_VERSION = 0x0003
A_SNAP_SEQ = 0x0006
A_LAT_CFG = 0x0007
A_HIST = 0x00C0
A_LAT_MIN = 0x00E0
A_LAT_MAX = 0x00E1
A_LAT_SUM_LO = 0x00E2
A_LAT_SUM_HI = 0x00E3
A_LAT_N = 0x00E4
A_LAT_OVER = 0x00E5
A_LAT_LAST = 0x00E6

TELEM_HIST_MAX = 32  # words reserved for buckets in the address map

# STATUS bit positions
ST_LAT_SAT = 7
ST_LAT_OVER = 8

# latency_hist.sv counter widths (telemetry_pkg §3)
LAT_DELTA_W = 24
LAT_CNT_W = 32
CNT_MAX = (1 << LAT_CNT_W) - 1
SUM_W = LAT_CNT_W + LAT_DELTA_W  # 56
SUM_MAX = (1 << SUM_W) - 1


# =============================================================================
# 2. Geometry — the bucket-index function, transcribed from the RTL
# =============================================================================
@dataclass(frozen=True)
class HistogramGeometry:
    n_buckets: int
    delta_w: int = LAT_DELTA_W
    log_mode: bool = True
    lin_base: int = 0
    lin_shift: int = 0

    def __post_init__(self) -> None:
        if self.n_buckets < 2:
            raise ProvenanceError(
                f"histogram: N_BUCKETS must be >= 2 (got {self.n_buckets}); "
                "latency_hist.sv $fatals on this."
            )

    # -- forward map: delta (cycles) -> bucket index --------------------
    def bucket_of(self, delta_cycles: int) -> tuple[int, bool]:
        """Return (bucket index, overflowed). Transcribed from stage 1."""
        if self.log_mode:
            # msb_pos = position of MSB + 1; 0 when delta == 0
            raw = delta_cycles.bit_length()
        else:
            rel = delta_cycles - self.lin_base if delta_cycles > self.lin_base else 0
            raw = rel >> self.lin_shift
        if raw >= self.n_buckets:
            return self.n_buckets - 1, True
        return raw, False

    # -- inverse map: bucket index -> [lo, hi] cycles --------------------
    def edges(self, idx: int) -> tuple[int, int | None]:
        """Inclusive cycle range a bucket covers. `hi is None` = unbounded.

        The top bucket is unbounded whenever a sample could have saturated into
        it, because a saturated sample has lost its magnitude.
        """
        top = idx == self.n_buckets - 1
        if self.log_mode:
            if idx == 0:
                lo, hi = 0, 0
            else:
                lo, hi = 1 << (idx - 1), (1 << idx) - 1
        else:
            width = 1 << self.lin_shift
            if idx == 0:
                # ⚠ catch-all: `>` in the RTL puts everything <= LIN_BASE here.
                lo, hi = 0, self.lin_base + width - 1
            else:
                lo = self.lin_base + idx * width
                hi = lo + width - 1
        return (lo, None if top else hi)

    @property
    def cannot_overflow(self) -> bool:
        """Log2 mode with a fully-sized map cannot lose the tail."""
        return self.log_mode and self.n_buckets >= self.delta_w + 1


# =============================================================================
# 3. A snapshot of the instrument
# =============================================================================
@dataclass
class HistogramSnapshot:
    """One coherent read of `latency_hist` (post-SNAP), plus its health flags.

    Implements the `latency.Distribution` protocol, so a fabric histogram flows
    into exactly the same `LatencyReport` renderer as a tap capture — with the
    metric forced to FABRIC by the manifest validator, never wire-to-wire.
    """

    geometry: HistogramGeometry
    buckets: list[int]
    n_samples: int
    min_cycles: int
    max_cycles: int
    sum_cycles: int
    over: int
    saturated: bool
    last_cycles: int | None = None
    snap_seq: int | None = None
    #: Set when the tool has proven the read is torn; percentiles are refused.
    coherent: bool = field(init=False, default=True)
    coherence_detail: str = field(init=False, default="")

    def __post_init__(self) -> None:
        if len(self.buckets) != self.geometry.n_buckets:
            raise ProvenanceError(
                f"histogram: got {len(self.buckets)} bucket words but geometry "
                f"says N_BUCKETS={self.geometry.n_buckets}. Read LAT_CFG "
                "(word 0x0007) and size the read from it; do not assume."
            )
        total = sum(self.buckets)
        if total != self.n_samples:
            self.coherent = False
            self.coherence_detail = (
                f"sum(buckets) = {total:,} but LAT_N = {self.n_samples:,} "
                f"(difference {total - self.n_samples:+,})"
            )

    # -- Distribution protocol -----------------------------------------
    @property
    def n(self) -> int:
        return self.n_samples

    def _require_usable(self) -> None:
        if not self.coherent:
            raise ProvenanceError(
                "histogram: TORN READ — " + self.coherence_detail + ". The host "
                "read the bucket words without pulsing SNAP (telemetry word "
                "0x0004), so these counts never coexisted. Percentiles computed "
                "from them describe a distribution that never existed "
                "(manual 05.04 §7; 06-operations/03 §9). Re-read: SNAP, then the "
                "words, then SNAP_SEQ to confirm it did not move."
            )
        if self.n_samples == 0:
            raise ProvenanceError("histogram: LAT_N = 0. Nothing was measured.")

    def percentile(self, num: int, den: int) -> Estimate:
        """Cumulative-sum percentile with honest bucket-width uncertainty."""
        self._require_usable()
        rank = (self.n_samples * num + den - 1) // den  # ceil, 1-based
        rank = max(1, min(rank, self.n_samples))

        cum = 0
        for idx, count in enumerate(self.buckets):
            cum += count
            if cum >= rank:
                return self._estimate_for(idx)
        # Unreachable when coherent, but never fall through silently.
        return self._estimate_for(len(self.buckets) - 1)

    def _estimate_for(self, idx: int) -> Estimate:
        lo_c, hi_c = self.geometry.edges(idx)
        is_top = idx == self.geometry.n_buckets - 1
        overflowed = is_top and self.over > 0

        # min/max are exact registers, so they tighten every bucket interval.
        lo_c = max(lo_c, self.min_cycles)
        hi_c = self.max_cycles if hi_c is None else min(hi_c, self.max_cycles)
        if hi_c < lo_c:  # only possible if the registers disagree with the bank
            hi_c = lo_c

        return Estimate(
            lo_ps=lo_c * CYCLE_PS,
            hi_ps=hi_c * CYCLE_PS,
            exact=(lo_c == hi_c),
            lower_bound=overflowed,
        )

    def minimum(self) -> Estimate:
        # A register, not a bucket. Exact (manual §5.4).
        return Estimate.exact_ps(self.min_cycles * CYCLE_PS)

    def maximum(self) -> Estimate:
        # A register, not a bucket. Exact even when the buckets overflowed —
        # this is the one number an overflowed histogram still tells the truth
        # about, and it is why `over` is survivable.
        return Estimate.exact_ps(self.max_cycles * CYCLE_PS)

    def mean_ps(self) -> int | None:
        if self.n_samples == 0:
            return None
        return (self.sum_cycles * CYCLE_PS) // self.n_samples

    # -- health ---------------------------------------------------------
    def warnings(self) -> list[str]:
        w: list[str] = []
        g = self.geometry

        if not self.coherent:
            w.append(
                "TORN READ: " + self.coherence_detail + ". SNAP was not pulsed "
                "before reading. Do not use these numbers."
            )

        if self.saturated:
            w.append(
                "COUNTER SATURATION (rd_sat sticky): at least one 32-bit counter "
                f"reached {CNT_MAX:,} and stopped incrementing. The buckets now "
                "UNDERSTATE, and they understate non-uniformly — the mode "
                "saturates first. Every percentile below is meaningless, not "
                "merely imprecise. Clear at start of day and shorten the "
                "collection window (latency_hist.sv stage 3)."
            )
            if self.sum_cycles >= SUM_MAX:
                w.append(
                    "LAT_SUM is at its maximum: the mean is a lower bound only."
                )

        if self.over:
            frac = self.over / self.n_samples if self.n_samples else 0.0
            w.append(
                f"OVERFLOW: LAT_OVER = {self.over:,} sample(s) "
                f"({frac * 100:.4f}% of N) landed above the top bucket and were "
                f"folded into bucket {g.n_buckets - 1}. Any percentile that "
                "lands in the top bucket is a LOWER BOUND (manual 05.04 §5.3). "
                f"The exact max is {self.max_cycles:,} cycles = "
                f"{self.max_cycles * CYCLE_PS / 1000.0:.1f} ns — that number is "
                "a register and is still exact."
            )
            if g.cannot_overflow:
                w.append(
                    "...and that overflow should be IMPOSSIBLE: geometry is "
                    f"log2 with N_BUCKETS={g.n_buckets} >= DELTA_W+1="
                    f"{g.delta_w + 1}. latency_hist.sv asserts !over_d for this "
                    "configuration. Either LAT_CFG was misread or the decoder "
                    "and the fabric disagree about the geometry — resolve that "
                    "before believing anything here."
                )
        elif self.buckets and self.buckets[-1] and not g.cannot_overflow:
            w.append(
                f"the top bucket holds {self.buckets[-1]:,} sample(s) with "
                "LAT_OVER = 0. Nothing has been lost yet, but the distribution "
                "is touching the ceiling — widen the range before it does."
            )

        if not g.log_mode and g.lin_base > 0 and self.buckets and self.buckets[0]:
            w.append(
                f"linear geometry with LIN_BASE={g.lin_base}: bucket 0 holds "
                f"{self.buckets[0]:,} sample(s) and is an UNDERFLOW CATCH-ALL "
                f"covering 0..{g.lin_base + (1 << g.lin_shift) - 1} cycles, not "
                "one bucket-width. latency_hist.sv uses `delta > LIN_BASE`, so "
                "everything at or below the base collapses here. A percentile "
                "landing in bucket 0 is uninformative."
            )

        if self.min_cycles > self.max_cycles and self.n_samples:
            w.append(
                f"LAT_MIN ({self.min_cycles}) > LAT_MAX ({self.max_cycles}): the "
                "registers are inconsistent. Either the read was torn or the "
                "instrument was cleared mid-read."
            )

        if self.n_samples < N_RECOMMENDED:
            w.append(
                f"N = {self.n_samples:,} is below the project floor of "
                f"{N_RECOMMENDED:,} (manual 05.04 §12)."
            )
        for name, num, den in PERCENTILES:
            rank = (self.n_samples * num + den - 1) // den
            if self.n_samples - rank < 10:
                w.append(
                    f"{name} is determined by fewer than 10 samples above it at "
                    f"N={self.n_samples:,}; it is not resolvable."
                )

        # Bucket-width uncertainty is intrinsic and must always be stated.
        w.append(
            "bucketed percentiles carry bucket-width uncertainty and are "
            "rendered as +/- half a bucket (manual 05.04 §5.4). LAT_MIN and "
            "LAT_MAX are registers and are exact."
        )
        return w

    # -- presentation ---------------------------------------------------
    def render_buckets(self, width: int = 48) -> str:
        lines = [
            f"  geometry : {'log2' if self.geometry.log_mode else 'linear'}, "
            f"N_BUCKETS={self.geometry.n_buckets}, DELTA_W={self.geometry.delta_w}"
            + (
                ""
                if self.geometry.log_mode
                else f", LIN_BASE={self.geometry.lin_base}, "
                f"LIN_SHIFT={self.geometry.lin_shift}"
            ),
            f"  N        : {self.n_samples:,}    over: {self.over:,}    "
            f"sat: {'YES' if self.saturated else 'no'}    "
            f"coherent: {'yes' if self.coherent else 'NO'}",
            "",
            "  bucket        cycles          ns range              count",
            "  " + "-" * 68,
        ]
        peak = max(self.buckets) if self.buckets else 0
        for idx, count in enumerate(self.buckets):
            if count == 0:
                continue
            lo, hi = self.geometry.edges(idx)
            cyc = f"{lo}" if hi == lo else (f"{lo}..{hi}" if hi is not None else f"{lo}+")
            ns_lo = lo * CYCLE_PS / 1000.0
            ns_hi = "inf" if hi is None else f"{hi * CYCLE_PS / 1000.0:.1f}"
            bar = "#" * (count * width // peak) if peak else ""
            lines.append(
                f"  {idx:>4}   {cyc:>14}   {ns_lo:>8.1f}..{ns_hi:>9}  "
                f"{count:>12,}  {bar}"
            )
        return "\n".join(lines)


# =============================================================================
# 4. Ingest — from the telemetry word map, or from a plain snapshot dict
# =============================================================================
def _lat_cfg_decode(word: int) -> HistogramGeometry:
    """LAT_CFG packing, from telemetry.sv:337

        lat_cfg_w = {7'd0, 1'b1, 8'(LAT_DELTA_W), 16'(N_BUCKETS)};

    so bit 24 = LOG_MODE, bits 23:16 = DELTA_W, bits 15:0 = N_BUCKETS.
    """
    n_buckets = word & 0xFFFF
    delta_w = (word >> 16) & 0xFF
    log_mode = bool((word >> 24) & 0x1)
    if n_buckets == 0 or n_buckets > TELEM_HIST_MAX:
        raise ProvenanceError(
            f"LAT_CFG=0x{word:08X} decodes to N_BUCKETS={n_buckets}, which is "
            f"outside 1..{TELEM_HIST_MAX}. Are you reading the right window? "
            f"(An unmapped telemetry address reads 0x{TELEM_UNMAPPED:08X}.)"
        )
    if delta_w == 0 or delta_w > 32:
        raise ProvenanceError(
            f"LAT_CFG=0x{word:08X} decodes to DELTA_W={delta_w}, which is absurd."
        )
    return HistogramGeometry(n_buckets=n_buckets, delta_w=delta_w, log_mode=log_mode)


def decode_words(words: dict[int, int], strict_version: bool = True) -> HistogramSnapshot:
    """Decode a telemetry read-window dump into a snapshot.

    `words` maps WORD address (not byte offset) to a 32-bit value — the same
    indices telemetry_pkg.sv defines. The CSR converts a BAR byte offset with
    `word = (bar_offset - CSR_TELEM_BASE) >> 2`.
    """

    def need(addr: int, name: str) -> int:
        if addr not in words:
            raise ProvenanceError(
                f"telemetry dump is missing word 0x{addr:04X} ({name}). The "
                "histogram cannot be decoded from a partial read."
            )
        v = words[addr]
        if v == TELEM_UNMAPPED:
            raise ProvenanceError(
                f"word 0x{addr:04X} ({name}) reads 0x{TELEM_UNMAPPED:08X} — the "
                "sentinel for an unmapped address. The dump was taken against "
                "the wrong BAR window or the wrong base offset."
            )
        return v

    if A_VERSION in words:
        ver = words[A_VERSION]
        magic = (ver >> 16) & 0xFFFF
        major = (ver >> 8) & 0xFF
        minor = ver & 0xFF
        if magic != TELEM_MAP_MAGIC:
            raise ProvenanceError(
                f"telemetry VERSION magic 0x{magic:04X} != expected "
                f"0x{TELEM_MAP_MAGIC:04X}. This is not a telemetry window."
            )
        if strict_version and major != TELEM_MAP_MAJOR:
            raise ProvenanceError(
                f"telemetry map MAJOR {major} != decoder's {TELEM_MAP_MAJOR}. "
                "A MAJOR bump means a word moved or changed meaning; decoding "
                "anyway produces telemetry that is wrong rather than absent "
                "(telemetry_pkg.sv §1). Update this decoder. "
                f"(map reports v{major}.{minor})"
            )

    geometry = _lat_cfg_decode(need(A_LAT_CFG, "LAT_CFG"))

    buckets: list[int] = []
    for i in range(geometry.n_buckets):
        buckets.append(need(A_HIST + i, f"HIST[{i}]"))

    sum_lo = need(A_LAT_SUM_LO, "LAT_SUM_LO")
    sum_hi = need(A_LAT_SUM_HI, "LAT_SUM_HI")

    saturated = False
    if A_STATUS in words:
        st = words[A_STATUS]
        saturated = bool((st >> ST_LAT_SAT) & 1)
        over_flag = bool((st >> ST_LAT_OVER) & 1)
        over_val = need(A_LAT_OVER, "LAT_OVER")
        if over_flag and over_val == 0:
            raise ProvenanceError(
                "STATUS.lat_over_nz is set but LAT_OVER reads 0. The status "
                "word is LIVE while LAT_OVER is snapshotted; if these disagree "
                "the snapshot predates the overflow. Re-SNAP and re-read."
            )

    return HistogramSnapshot(
        geometry=geometry,
        buckets=buckets,
        n_samples=need(A_LAT_N, "LAT_N"),
        min_cycles=need(A_LAT_MIN, "LAT_MIN"),
        max_cycles=need(A_LAT_MAX, "LAT_MAX"),
        sum_cycles=(sum_hi << 32) | sum_lo,
        over=need(A_LAT_OVER, "LAT_OVER"),
        saturated=saturated,
        last_cycles=words.get(A_LAT_LAST),
        snap_seq=words.get(A_SNAP_SEQ),
    )


def load_words(path: str | pathlib.Path) -> dict[int, int]:
    """Read a word dump. Accepts JSON `{addr: value}` or CSV `addr,value`.

    Addresses and values may be decimal or 0x-prefixed hex, in either format.
    """
    p = pathlib.Path(path)
    if not p.is_file():
        raise ProvenanceError(f"telemetry dump not found: {p}")
    text = p.read_text()

    def num(s) -> int:
        if isinstance(s, int):
            return s
        s = str(s).strip().replace("_", "")
        return int(s, 16) if s.lower().startswith("0x") else int(s, 10)

    stripped = text.lstrip()
    if stripped.startswith("{"):
        raw = json.loads(text)
        if "buckets" in raw:
            raise ProvenanceError(
                f"{p} looks like a snapshot file, not a word dump. Use --snapshot."
            )
        return {num(k): num(v) for k, v in raw.items()}

    out: dict[int, int] = {}
    reader = csv.reader(text.splitlines())
    for row in reader:
        if not row or row[0].strip().startswith("#"):
            continue
        if len(row) < 2:
            continue
        head = row[0].strip().lower()
        if head in ("addr", "address", "word"):
            continue
        try:
            out[num(row[0])] = num(row[1])
        except ValueError:
            continue
    if not out:
        raise ProvenanceError(f"no address/value pairs parsed from {p}")
    return out


def load_snapshot(path: str | pathlib.Path) -> HistogramSnapshot:
    """Read an explicit snapshot JSON (what a host collector would archive)."""
    p = pathlib.Path(path)
    if not p.is_file():
        raise ProvenanceError(f"snapshot not found: {p}")
    d = json.loads(p.read_text())
    for key in ("buckets", "n", "min_cycles", "max_cycles", "over"):
        if key not in d:
            raise ProvenanceError(f"snapshot {p}: missing required field '{key}'")
    buckets = list(d["buckets"])
    geo = HistogramGeometry(
        n_buckets=d.get("n_buckets", len(buckets)),
        delta_w=d.get("delta_w", LAT_DELTA_W),
        log_mode=bool(d.get("log_mode", True)),
        lin_base=int(d.get("lin_base", 0)),
        lin_shift=int(d.get("lin_shift", 0)),
    )
    return HistogramSnapshot(
        geometry=geo,
        buckets=buckets,
        n_samples=int(d["n"]),
        min_cycles=int(d["min_cycles"]),
        max_cycles=int(d["max_cycles"]),
        sum_cycles=int(d.get("sum_cycles", 0)),
        over=int(d["over"]),
        saturated=bool(d.get("saturated", False)),
        last_cycles=d.get("last_cycles"),
        snap_seq=d.get("snap_seq"),
    )


# =============================================================================
# 5. CLI
# =============================================================================
def _build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="histogram.py",
        description=(
            "Decode the fabric latency histogram (linear or log2), reconstruct "
            "percentiles with honest bucket-width uncertainty, and warn on "
            "saturation, overflow, and torn reads."
        ),
    )
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument(
        "--words", help="telemetry word dump (JSON {addr: value} or CSV addr,value)"
    )
    src.add_argument("--snapshot", help="explicit snapshot JSON")
    ap.add_argument(
        "--manifest",
        help="run manifest; supplying it emits a FULL latency report. Without "
        "it only the bucket decode is printed, which is NOT a reportable "
        "latency number.",
    )
    ap.add_argument("--buckets", action="store_true", help="print the bucket table")
    ap.add_argument(
        "--allow-major-mismatch",
        action="store_true",
        help="decode even if the telemetry map MAJOR disagrees (dangerous)",
    )
    ap.add_argument("--json", action="store_true")
    return ap


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        if args.words:
            snap = decode_words(
                load_words(args.words), strict_version=not args.allow_major_mismatch
            )
        else:
            snap = load_snapshot(args.snapshot)

        if args.json:
            payload = {
                "n": snap.n,
                "over": snap.over,
                "saturated": snap.saturated,
                "coherent": snap.coherent,
                "min_ns": snap.min_cycles * CYCLE_PS / 1000.0,
                "max_ns": snap.max_cycles * CYCLE_PS / 1000.0,
                "buckets": snap.buckets,
                "warnings": snap.warnings(),
            }
            print(json.dumps(payload, indent=2))
            return 0

        if args.buckets or not args.manifest:
            print(snap.render_buckets())
            print()

        if args.manifest:
            manifest = RunManifest.load_file(args.manifest)
            print(LatencyReport(dist=snap, manifest=manifest).render())
        else:
            print(
                "  NOTE: no --manifest given, so no report was emitted. Bucket "
                "counts alone are\n        not a latency result — they carry no "
                "load condition and no provenance.\n        Re-run with "
                "--manifest to produce a quotable number."
            )
    except ProvenanceError as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
