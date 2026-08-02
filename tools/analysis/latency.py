"""latency.py — latency ingest and THE mandatory reporting format.

Project : FPGA Algorithmic Trading System (Nasdaq Equities)
Governs : manuals/05-optimization/04-measurement-and-profiling.md  §5, §7, §9
          CLAUDE.md §5.8 (determinism over average speed)

===============================================================================
THE RULE THIS FILE EXISTS TO ENFORCE
===============================================================================

    A latency number without a LOAD CONDITION and a MEASUREMENT PROVENANCE is
    not a weak result. It is not a result at all. It is a decoration.

manual 05.04 §9 lists five rules; this module makes four of them structural
rather than aspirational:

  1. Never a bare number.        -> the only public renderer emits the full block
  2. MEASURED or SIMULATED.      -> `Source` is a required field, no default
  3. State N and load.           -> `LoadCondition` is required, no default
  4. State the build.            -> `BuildIdentity` is required, no default
  5. Rig offset and noise floor. -> required for every EXTERNAL measured run

`LatencyReport.render()` raises :class:`ProvenanceError` rather than emitting a
report that is missing any of them. There is deliberately no `force` flag and
no partial-render path: if the tool could be talked into printing an unlabelled
percentile, someone would eventually paste that percentile into a design review
and it would be believed.

===============================================================================
UNITS, AND WHY THERE ARE NO FLOATS IN THE ARITHMETIC
===============================================================================

The fast path is integer-only (CLAUDE.md §5.3). Host analysis is *allowed*
floats, but latency here is natively a count of core-clock cycles, and
6.4 ns/cycle is exactly 6400 ps. So:

    every internal quantity is an INTEGER NUMBER OF PICOSECONDS

Cycles convert exactly (`* CYCLE_PS`). Percentile ranks are computed with
integer ceiling division. Floats appear only in `render()`, at the point where
a human reads the number. That means two runs of this tool on the same input
produce byte-identical output — which matters, because A/B comparison
(`ab_compare.py`) diffs these reports.

===============================================================================
WHAT THIS MODULE WILL NOT DO
===============================================================================

* It will not pair a trigger to an order by "nearest preceding". That method
  mis-pairs whenever two triggers are in flight, which is precisely the tail
  you care about (manual §2.1). `read_pairs_csv` requires an echoed correlation
  id. There is no fallback.
* It will not call an on-chip fabric histogram "wire-to-wire". The fabric
  instrument cannot see the optics, the GT PMA/PCS, the gearbox, or the cable —
  per rtl/fpga_top.sv that is ~180 ns of a ~321 ns target, over half the
  number. `Metric.WIRE_TO_WIRE` + `Instrument.ONCHIP_HISTOGRAM` is refused.
* It will not average a SIMULATED run together with a MEASURED one.
"""

from __future__ import annotations

import argparse
import csv
import enum
import json
import math
import pathlib
import sys
from dataclasses import dataclass, field
from typing import Iterable, Protocol, Sequence

__all__ = [
    "CORE_CLK_HZ",
    "CYCLE_PS",
    "ProvenanceError",
    "Source",
    "Metric",
    "Instrument",
    "LoadProfile",
    "Provenance",
    "LoadCondition",
    "BuildIdentity",
    "Conditions",
    "RunManifest",
    "Estimate",
    "Distribution",
    "SampleSet",
    "LatencyReport",
    "PERCENTILES",
    "read_samples_csv",
    "read_pairs_csv",
    "main",
]


# =============================================================================
# 1. Clock domain constants — mirrored from rtl/fpga_top.sv
# =============================================================================
# rtl/fpga_top.sv header: "156.25 MHz core clock, 6.4 ns/cycle".
# 1 / 156.25 MHz = 6.4 ns exactly = 6400 ps exactly. No rounding anywhere.
CORE_CLK_HZ: int = 156_250_000
CYCLE_PS: int = 6_400
#: The A/B effect-size floor. One core cycle. Below this, a claimed improvement
#: is a placement lottery result, not a design result (manual §10).
ONE_CYCLE_PS: int = CYCLE_PS

#: manual §12 checklist: "N >= 1e6 trigger events".
N_RECOMMENDED: int = 1_000_000

#: The percentiles this project reports. ALL of them, ALWAYS (CLAUDE.md §5.8).
#: Held as exact integer fractions so rank arithmetic never touches a float.
PERCENTILES: tuple[tuple[str, int, int], ...] = (
    ("p50", 1, 2),
    ("p99", 99, 100),
    ("p99.9", 999, 1000),
)


class ProvenanceError(Exception):
    """Raised instead of emitting a report that cannot be interpreted.

    Every message names the missing field AND the manual section that requires
    it, because the person who hits this is usually in a hurry and about to
    reach for a shortcut.
    """


# =============================================================================
# 2. Provenance vocabulary
# =============================================================================
class Source(enum.Enum):
    """Rendered in CAPITALS, always (manual §9 rule 2)."""

    MEASURED = "MEASURED"
    SIMULATED = "SIMULATED"

    def __str__(self) -> str:  # pragma: no cover - trivial
        return self.value


class Metric(enum.Enum):
    """What interval the number actually spans.

    The distinction is not pedantry: WIRE_TO_WIRE and FABRIC differ by the
    whole IO stack, and quoting one where the other is meant is the single
    easiest way to be wrong by 2x in this project.
    """

    WIRE_TO_WIRE = "wire-to-wire, first-bit-in -> first-bit-out"
    FABRIC_END_TO_END = "fabric end-to-end, MAC RX SOF -> MAC TX SOF (no IO stack)"
    STAGE = "single pipeline stage, ingress stamp -> stage exit"


class Instrument(enum.Enum):
    """How the timestamps were taken (manual §3)."""

    TAP_L1 = "passive tap + L1 timestamping appliance"
    TAP_NIC = "passive tap + hardware-timestamping capture NIC"
    SECOND_FPGA = "passive tap + second FPGA used as an instrument"
    SCOPE = "oscilloscope on the SFP electrical lanes"
    ONCHIP_HISTOGRAM = "on-chip latency_hist read over PCIe"
    SIMULATION = "simulator (cocotb/Verilator or vendor sim)"

    @property
    def is_external(self) -> bool:
        """External instruments have a rig, and therefore a rig offset."""
        return self in (
            Instrument.TAP_L1,
            Instrument.TAP_NIC,
            Instrument.SECOND_FPGA,
            Instrument.SCOPE,
        )

    @property
    def sees_io_stack(self) -> bool:
        """Can this instrument observe the optics / GT / gearbox / cable?"""
        return self.is_external


class LoadProfile(enum.Enum):
    """The load profiles of manual §8. Each is reported SEPARATELY.

    ⚠ A design that meets its budget on IDLE and blows it on
    OPEN_REPLAY_COMPRESSED has not met its budget. The published number is the
    loaded one.
    """

    IDLE = "idle (single trigger, quiet wire)"
    OPEN_REPLAY_ORIGINAL = "market-open replay, original inter-packet timing"
    OPEN_REPLAY_COMPRESSED = "market-open replay, inter-packet gaps compressed"
    SUSTAINED_MIN_FRAME = "sustained line rate, minimum-size frames"
    BURST_MAXFRAME = "max-size frames interleaved with triggers"
    AB_GAP_RECOVERY = "A/B gap + recovery during a burst"
    SYNTHETIC = "synthetic / hand-crafted stimulus"

    @property
    def is_representative(self) -> bool:
        """Is this a load a real venue would produce?

        IDLE is the floor and SYNTHETIC is a lab curiosity. Neither may be
        published as *the* number (manual §7, "measuring with an idle feed" and
        "test packets take a different code path").
        """
        return self not in (LoadProfile.IDLE, LoadProfile.SYNTHETIC)


# =============================================================================
# 3. The manifest — the thing that makes a number mean something
# =============================================================================
@dataclass(frozen=True)
class Provenance:
    source: Source
    instrument: Instrument
    #: Rig offset already SUBTRACTED from the samples, in ps. Required for
    #: external instruments (manual §4 step 1, §9 rule 5). 0 is a legal value
    #: but must be stated explicitly, never defaulted.
    rig_offset_ps: int | None = None
    #: Instrument repeatability, in ps (manual §4 step 5). Any effect smaller
    #: than this is not measurable, full stop.
    noise_floor_ps: int | None = None
    #: manual §4 step 3. False means a systematic bias of ~4.9 ns per metre of
    #: mismatch is sitting in every number below.
    fibre_matched: bool | None = None
    #: manual §2.1. Only "echo-id" is accepted for loaded runs.
    pairing: str = "echo-id"
    notes: str = ""

    def validate(self, metric: Metric) -> None:
        if self.instrument is Instrument.SIMULATION and self.source is Source.MEASURED:
            raise ProvenanceError(
                "provenance: instrument=SIMULATION cannot produce source=MEASURED. "
                "manual 05.04 §7: 'simulation has no PMA, no gearbox, no elastic "
                "buffer, no routing delay, no thermal, no contention with real "
                "traffic. It is an architectural cycle count.'"
            )

        if metric is Metric.WIRE_TO_WIRE and not self.instrument.sees_io_stack:
            raise ProvenanceError(
                f"provenance: instrument={self.instrument.name} cannot measure "
                "metric=WIRE_TO_WIRE. It observes fabric cycle stamps only — no "
                "optics, no GT PMA/PCS, no gearbox, no cable. rtl/fpga_top.sv "
                "budgets ~180 ns of IO stack against a ~321 ns wire-to-wire "
                "target, so this instrument cannot see over half the number. "
                "Use metric=FABRIC_END_TO_END, or measure with a tap "
                "(manual 05.04 §2)."
            )

        if self.source is Source.MEASURED and self.instrument.is_external:
            if self.rig_offset_ps is None:
                raise ProvenanceError(
                    "provenance: MEASURED with an external instrument requires "
                    "rig_offset_ps (state 0 explicitly if the rig was zeroed). "
                    "manual 05.04 §4 step 1 / §9 rule 5."
                )
            if self.noise_floor_ps is None:
                raise ProvenanceError(
                    "provenance: MEASURED with an external instrument requires "
                    "noise_floor_ps. Without it no A/B result can be believed: "
                    "'a claimed 3 ns improvement from a rig with a 12 ns noise "
                    "floor is not a result' (manual 05.04 §4)."
                )
            if self.fibre_matched is None:
                raise ProvenanceError(
                    "provenance: MEASURED with an external instrument requires "
                    "fibre_matched (true/false). 1 m of fibre mismatch is "
                    "~4.9 ns of pure systematic bias (manual 05.04 §4 step 3)."
                )


@dataclass(frozen=True)
class LoadCondition:
    profile: LoadProfile
    #: Free text: what was actually replayed. "market open 2026-06-02" etc.
    description: str
    #: The replay file, so the run is reproducible byte-for-byte (manual §10.2).
    source_file: str = ""
    capture_date: str = ""

    def validate(self) -> None:
        if not self.description.strip():
            raise ProvenanceError(
                "load: description is required. 'What traffic was on the wire?' "
                "is the first question anyone will ask about this number "
                "(manual 05.04 §8)."
            )


@dataclass(frozen=True)
class BuildIdentity:
    """manual §9 rule 4: latency is a property of a bitstream, not a repo."""

    bitstream: str
    tool_version: str = ""
    impl_directive: str = ""
    #: manual §7: a debug bitstream has different placement, different routing,
    #: and therefore different latency. Measuring it measures a different design.
    production_bitstream: bool = True
    debug_cores: bool = False

    def validate(self, source: Source) -> None:
        if not self.bitstream.strip():
            raise ProvenanceError(
                "build: bitstream identity is required (hash or tag). "
                "manual 05.04 §9 rule 4: latency is a property of a bitstream."
            )
        if source is Source.MEASURED and not self.tool_version.strip():
            raise ProvenanceError(
                "build: tool_version is required for MEASURED runs. Placement "
                "noise alone moves latency-relevant routing, so numbers are not "
                "comparable across tool versions (manual 05.04 §7)."
            )


@dataclass(frozen=True)
class Conditions:
    junction_temp_c: float | None = None
    extra: str = ""


@dataclass(frozen=True)
class RunManifest:
    metric: Metric
    provenance: Provenance
    load: LoadCondition
    build: BuildIdentity
    conditions: Conditions = field(default_factory=Conditions)
    label: str = ""

    def validate(self) -> None:
        self.provenance.validate(self.metric)
        self.load.validate()
        self.build.validate(self.provenance.source)

    # -- serialization -----------------------------------------------------
    @staticmethod
    def from_dict(d: dict) -> "RunManifest":
        def need(container: dict, key: str, where: str):
            if key not in container:
                raise ProvenanceError(
                    f"manifest: missing required field '{where}.{key}'. "
                    "See tools/analysis/README.md for the manifest schema; every "
                    "field exists because manual 05.04 §9 requires it."
                )
            return container[key]

        if "provenance" not in d:
            raise ProvenanceError(
                "manifest: missing 'provenance'. A latency number without "
                "measurement provenance is meaningless (manual 05.04 §9)."
            )
        if "load" not in d:
            raise ProvenanceError(
                "manifest: missing 'load'. A latency number without a load "
                "condition is meaningless — an idle system has no arbitration, "
                "no packet packing, no TX occupancy and no book contention "
                "(manual 05.04 §7, §8)."
            )
        if "build" not in d:
            raise ProvenanceError(
                "manifest: missing 'build'. manual 05.04 §9 rule 4."
            )

        p = d["provenance"]
        lo = d["load"]
        b = d["build"]
        c = d.get("conditions", {})

        prov = Provenance(
            source=_enum_by_name(Source, need(p, "source", "provenance"), "source"),
            instrument=_enum_by_name(
                Instrument, need(p, "instrument", "provenance"), "instrument"
            ),
            rig_offset_ps=_ns_to_ps_opt(p.get("rig_offset_ns")),
            noise_floor_ps=_ns_to_ps_opt(p.get("noise_floor_ns")),
            fibre_matched=p.get("fibre_matched"),
            pairing=p.get("pairing", "echo-id"),
            notes=p.get("notes", ""),
        )
        load = LoadCondition(
            profile=_enum_by_name(
                LoadProfile, need(lo, "profile", "load"), "profile"
            ),
            description=need(lo, "description", "load"),
            source_file=lo.get("source_file", ""),
            capture_date=lo.get("capture_date", ""),
        )
        build = BuildIdentity(
            bitstream=need(b, "bitstream", "build"),
            tool_version=b.get("tool_version", ""),
            impl_directive=b.get("impl_directive", ""),
            production_bitstream=b.get("production_bitstream", True),
            debug_cores=b.get("debug_cores", False),
        )
        conds = Conditions(
            junction_temp_c=c.get("junction_temp_c"),
            extra=c.get("extra", ""),
        )
        m = RunManifest(
            metric=_enum_by_name(Metric, d.get("metric", ""), "metric"),
            provenance=prov,
            load=load,
            build=build,
            conditions=conds,
            label=d.get("label", ""),
        )
        m.validate()
        return m

    @staticmethod
    def load_file(path: str | pathlib.Path) -> "RunManifest":
        p = pathlib.Path(path)
        if not p.is_file():
            raise ProvenanceError(f"manifest: file not found: {p}")
        try:
            return RunManifest.from_dict(json.loads(p.read_text()))
        except json.JSONDecodeError as exc:
            raise ProvenanceError(f"manifest: {p} is not valid JSON: {exc}") from exc


def _enum_by_name(cls, raw, what: str):
    if isinstance(raw, cls):
        return raw
    key = str(raw).strip().upper().replace("-", "_").replace(".", "_")
    try:
        return cls[key]
    except KeyError:
        names = ", ".join(m.name for m in cls)
        raise ProvenanceError(
            f"manifest: '{raw}' is not a valid {what}. Choose one of: {names}"
        ) from None


def _ns_to_ps_opt(v) -> int | None:
    if v is None:
        return None
    return int(round(float(v) * 1000.0))


# =============================================================================
# 4. Estimates — a number that knows how well it is known
# =============================================================================
@dataclass(frozen=True)
class Estimate:
    """A latency value in ps, carrying its own uncertainty.

    Two things in this system produce percentiles, and they differ in kind:

      * an exact sample list  -> an order statistic. Exact.
      * a bucketed histogram  -> "somewhere in this bucket". manual §5.4:
        "a percentile from a bucketed histogram has bucket-width uncertainty.
        With 1-cycle buckets that's +-6.4 ns; say so."

    `lower_bound` is the third case: the histogram overflowed, so the true
    value is at least `lo_ps` and there is no upper bound at all. That is not
    an uncertainty, it is a missing measurement, and it renders as ">=".
    """

    lo_ps: int
    hi_ps: int
    exact: bool
    lower_bound: bool = False

    @staticmethod
    def exact_ps(ps: int) -> "Estimate":
        return Estimate(lo_ps=ps, hi_ps=ps, exact=True)

    @property
    def point_ps(self) -> int:
        """A single representative value. Bucket midpoint when inexact."""
        if self.exact:
            return self.lo_ps
        return (self.lo_ps + self.hi_ps) // 2

    def render(self) -> str:
        if self.lower_bound:
            return f">= {_ns(self.lo_ps)} ns   (LOWER BOUND — histogram overflowed)"
        if self.exact:
            return f"{_ns(self.lo_ps)} ns"
        half = (self.hi_ps - self.lo_ps) / 2000.0
        return f"{_ns(self.point_ps)} ns  +/- {half:.1f} ns (bucket width)"


def _ns(ps: int) -> str:
    """Render picoseconds as nanoseconds. The ONLY float in the arithmetic."""
    return f"{ps / 1000.0:.1f}"


class Distribution(Protocol):
    """What `LatencyReport` needs. Implemented by `SampleSet` here and by
    `histogram.HistogramSnapshot` — so a report reads identically whether it
    came from a tap capture or from the fabric's own buckets."""

    @property
    def n(self) -> int: ...

    def percentile(self, num: int, den: int) -> Estimate: ...

    def minimum(self) -> Estimate: ...

    def maximum(self) -> Estimate: ...

    def mean_ps(self) -> int | None: ...

    def warnings(self) -> list[str]: ...


# =============================================================================
# 5. Exact sample sets
# =============================================================================
@dataclass
class SampleSet:
    """An exact list of per-event latencies, in picoseconds.

    Percentiles are NEAREST-RANK order statistics: no interpolation, no
    smoothing, no float. rank = ceil(n * num / den), 1-based. Interpolating
    between two order statistics invents a latency the system never produced,
    which is the wrong kind of wrong for a determinism report.
    """

    values_ps: list[int]
    #: Events that could not be paired / were rejected during ingest. Counted,
    #: never silently discarded (CLAUDE.md §5.7 applied to the analysis side).
    dropped: dict[str, int] = field(default_factory=dict)

    def __post_init__(self) -> None:
        self.values_ps = sorted(self.values_ps)

    @property
    def n(self) -> int:
        return len(self.values_ps)

    def percentile(self, num: int, den: int) -> Estimate:
        if self.n == 0:
            raise ProvenanceError("percentile requested from an empty sample set")
        rank = (self.n * num + den - 1) // den  # ceil, integer only
        rank = max(1, min(rank, self.n))
        return Estimate.exact_ps(self.values_ps[rank - 1])

    def minimum(self) -> Estimate:
        return Estimate.exact_ps(self.values_ps[0])

    def maximum(self) -> Estimate:
        return Estimate.exact_ps(self.values_ps[-1])

    def mean_ps(self) -> int | None:
        if self.n == 0:
            return None
        return sum(self.values_ps) // self.n

    def warnings(self) -> list[str]:
        w: list[str] = []
        if self.n < N_RECOMMENDED:
            w.append(
                f"N = {self.n:,} is below the project floor of {N_RECOMMENDED:,} "
                "(manual 05.04 §12). p99.9 from a short run is an anecdote."
            )
        for name, num, den in PERCENTILES:
            rank = (self.n * num + den - 1) // den
            above = self.n - rank
            if above < 10:
                w.append(
                    f"{name} is determined by only {above} sample(s) above it "
                    f"(N={self.n:,}). It is not resolvable at this N; collect "
                    f"at least {den * 10:,} events."
                )
        for reason, count in sorted(self.dropped.items()):
            if count:
                w.append(f"ingest dropped {count:,} event(s): {reason}")
        return w


# =============================================================================
# 6. Ingest
# =============================================================================
_UNIT_TO_PS = {"ps": 1, "ns": 1000, "us": 1_000_000, "cycles": CYCLE_PS}


def _to_ps(value: str, unit: str) -> int:
    scale = _UNIT_TO_PS[unit]
    if unit == "cycles":
        # Cycle counts are integers by construction; a fractional cycle in the
        # input means the producer already did a lossy conversion.
        c = float(value)
        if abs(c - round(c)) > 1e-9:
            raise ValueError(
                f"non-integer cycle count {value!r}: cycles come from a counter "
                "and are integers. Someone has already converted this number."
            )
        return int(round(c)) * scale
    return int(round(float(value) * scale))


def read_samples_csv(
    path: str | pathlib.Path,
    column: str,
    unit: str = "cycles",
) -> SampleSet:
    """Read one column of per-event latency deltas.

    The file is the output of a capture post-processor or a
    `histogram.py --dump-samples` style export. One row per trigger event.
    """
    if unit not in _UNIT_TO_PS:
        raise ProvenanceError(
            f"unit '{unit}' unknown; choose one of {sorted(_UNIT_TO_PS)}"
        )
    p = pathlib.Path(path)
    if not p.is_file():
        raise ProvenanceError(f"samples: file not found: {p}")

    values: list[int] = []
    dropped: dict[str, int] = {"unparseable row": 0, "negative delta": 0}
    with p.open(newline="") as fh:
        reader = csv.DictReader(fh)
        if reader.fieldnames is None or column not in reader.fieldnames:
            raise ProvenanceError(
                f"samples: column '{column}' not in {p} "
                f"(columns: {reader.fieldnames})"
            )
        for row in reader:
            raw = (row.get(column) or "").strip()
            if not raw:
                dropped["unparseable row"] += 1
                continue
            try:
                ps = _to_ps(raw, unit)
            except ValueError:
                dropped["unparseable row"] += 1
                continue
            if ps < 0:
                # A negative latency is a pairing or clock-domain error, not a
                # fast design. Never silently take abs().
                dropped["negative delta"] += 1
                continue
            values.append(ps)

    if not values:
        raise ProvenanceError(f"samples: no usable rows in {p}")
    return SampleSet(values_ps=values, dropped=dropped)


def read_pairs_csv(
    path: str | pathlib.Path,
    id_col: str = "echo_id",
    tin_col: str = "t_in_ns",
    tout_col: str = "t_out_ns",
    unit: str = "ns",
) -> SampleSet:
    """Pair inbound triggers with outbound orders by ECHOED CORRELATION ID.

    manual 05.04 §2.1: the outbound OUCH client order token carries the
    trigger's identity so the pairing is exact under load. This function
    implements that and ONLY that.

    ⚠ There is deliberately no nearest-preceding fallback. Nearest-preceding
    pairing mis-pairs whenever two triggers are in flight, which corrupts
    exactly the tail the whole exercise is about. If your capture lacks an echo
    id, the correct action is to fix the order encoder, not to guess here.
    """
    p = pathlib.Path(path)
    if not p.is_file():
        raise ProvenanceError(f"pairs: file not found: {p}")

    ins: dict[str, int] = {}
    outs: dict[str, int] = {}
    dropped = {
        "duplicate echo id (in)": 0,
        "duplicate echo id (out)": 0,
        "unparseable row": 0,
    }

    with p.open(newline="") as fh:
        reader = csv.DictReader(fh)
        cols = reader.fieldnames or []
        for needed in (id_col, tin_col, tout_col):
            if needed not in cols:
                raise ProvenanceError(
                    f"pairs: column '{needed}' not in {p} (columns: {cols}). "
                    "Trigger<->order pairing REQUIRES an echoed correlation id "
                    "(manual 05.04 §2.1); there is no nearest-preceding mode."
                )
        for row in reader:
            key = (row.get(id_col) or "").strip()
            if not key:
                dropped["unparseable row"] += 1
                continue
            try:
                t_in = _to_ps(row[tin_col], unit) if (row[tin_col] or "").strip() else None
                t_out = _to_ps(row[tout_col], unit) if (row[tout_col] or "").strip() else None
            except ValueError:
                dropped["unparseable row"] += 1
                continue
            if t_in is not None:
                if key in ins:
                    dropped["duplicate echo id (in)"] += 1
                else:
                    ins[key] = t_in
            if t_out is not None:
                if key in outs:
                    dropped["duplicate echo id (out)"] += 1
                else:
                    outs[key] = t_out

    values: list[int] = []
    unmatched_in = 0
    unmatched_out = 0
    negative = 0
    for key, t_in in ins.items():
        t_out = outs.get(key)
        if t_out is None:
            unmatched_in += 1
            continue
        d = t_out - t_in
        if d < 0:
            negative += 1
            continue
        values.append(d)
    unmatched_out = sum(1 for k in outs if k not in ins)

    dropped["trigger with no order (no fire, or order lost)"] = unmatched_in
    dropped["order with no trigger (pairing broken)"] = unmatched_out
    dropped["negative delta (clock skew or mis-pairing)"] = negative

    if not values:
        raise ProvenanceError(
            f"pairs: no trigger/order pairs matched in {p}. Check that the echo "
            "id in the OUCH token really is the id the capture recorded."
        )
    return SampleSet(values_ps=values, dropped=dropped)


# =============================================================================
# 7. The report
# =============================================================================
@dataclass
class LatencyReport:
    """The only sanctioned way to state a latency in this project."""

    dist: Distribution
    manifest: RunManifest

    def __post_init__(self) -> None:
        # Fail at construction, not at render: nothing downstream should be
        # able to hold a half-valid report object.
        self.manifest.validate()
        if self.dist.n == 0:
            raise ProvenanceError("report: N = 0. There is nothing to report.")

    # -- derived ----------------------------------------------------------
    def percentiles(self) -> dict[str, Estimate]:
        return {name: self.dist.percentile(num, den) for name, num, den in PERCENTILES}

    def all_warnings(self) -> list[str]:
        w = list(self.dist.warnings())
        m = self.manifest

        if not m.load.profile.is_representative:
            w.append(
                f"load profile '{m.load.profile.name}' is not representative. "
                "manual 05.04 §8: the published number is the loaded one; an "
                "idle or synthetic run is a floor, not a result."
            )
        if m.provenance.source is Source.SIMULATED:
            w.append(
                "SIMULATED. No PMA, no gearbox, no elastic buffer, no routing "
                "delay, no thermal drift, no contention with real traffic. This "
                "is an architectural cycle count and is NOT comparable with a "
                "measured number (manual 05.04 §7)."
            )
        if m.provenance.fibre_matched is False:
            w.append(
                "tap fibres NOT matched: a systematic bias of ~4.9 ns per metre "
                "of mismatch is present in every number above and has not been "
                "subtracted (manual 05.04 §4 step 3)."
            )
        if m.provenance.source is Source.MEASURED and not m.build.production_bitstream:
            w.append(
                "not a production bitstream: different placement and routing, "
                "therefore a different latency. This measures a different "
                "design (manual 05.04 §2 property 4)."
            )
        if m.build.debug_cores:
            w.append(
                "debug cores present in the bitstream. ILA probe nets change "
                "placement and routing. manual 05.04 §6: never quote a latency "
                "obtained from a debug build."
            )
        if m.metric is Metric.FABRIC_END_TO_END:
            w.append(
                "FABRIC metric: this excludes optics, GT PMA/PCS, gearbox and "
                "cable — per rtl/fpga_top.sv roughly 180 ns of a ~321 ns "
                "wire-to-wire target. This is attribution evidence, NOT the "
                "headline number (manual 05.04 §1)."
            )
        if (
            m.provenance.source is Source.MEASURED
            and m.provenance.noise_floor_ps is not None
        ):
            nf = m.provenance.noise_floor_ps
            if nf >= ONE_CYCLE_PS:
                w.append(
                    f"rig noise floor {_ns(nf)} ns >= one core cycle "
                    f"({_ns(ONE_CYCLE_PS)} ns): this rig cannot resolve a "
                    "single-cycle improvement, so no A/B result at the project's "
                    "minimum effect size is measurable on it (manual §4 step 5)."
                )
        return w

    # -- rendering --------------------------------------------------------
    def render(self) -> str:
        m = self.manifest
        p = self.percentiles()
        prov = m.provenance

        src_line = f"{prov.source}  ({prov.instrument.value}"
        if prov.source is Source.MEASURED and prov.instrument.is_external:
            src_line += f", rig offset {_ns(prov.rig_offset_ps or 0)} ns subtracted"
        src_line += ")"

        lines: list[str] = []
        if m.label:
            lines.append(f"=== {m.label} ===")
        lines.append(f"  metric      : {m.metric.value}")
        for name, _num, _den in PERCENTILES:
            lines.append(f"  {name:<12}: {p[name].render()}")
        lines.append(f"  {'max':<12}: {self.dist.maximum().render()}")
        lines.append(f"  {'min':<12}: {self.dist.minimum().render()}")

        mean = self.dist.mean_ps()
        if mean is not None:
            # The mean is printed LAST and labelled, so it can never be mistaken
            # for the headline. CLAUDE.md §5.8 / manual §7 row 1.
            lines.append(
                f"  {'mean':<12}: {_ns(mean)} ns   "
                "(context only — the mean hides the tail; never quote it alone)"
            )

        lines.append(f"  {'N':<12}: {self.dist.n:,} trigger events")
        load_txt = f"{m.load.profile.value}"
        if m.load.description:
            load_txt += f" — {m.load.description}"
        if m.load.capture_date:
            load_txt += f" [{m.load.capture_date}]"
        lines.append(f"  {'load':<12}: {load_txt}")
        if m.load.source_file:
            lines.append(f"  {'replay':<12}: {m.load.source_file}")
        lines.append(f"  {'source':<12}: {src_line}")
        if prov.source is Source.MEASURED and prov.instrument.is_external:
            lines.append(
                f"  {'noise floor':<12}: {_ns(prov.noise_floor_ps or 0)} ns "
                "(rig repeatability)"
            )
            lines.append(
                f"  {'fibres':<12}: "
                f"{'matched' if prov.fibre_matched else 'NOT MATCHED'}"
            )
        lines.append(f"  {'pairing':<12}: {prov.pairing}")
        build_txt = m.build.bitstream
        if m.build.tool_version:
            build_txt += f", {m.build.tool_version}"
        if m.build.impl_directive:
            build_txt += f", impl directive {m.build.impl_directive}"
        lines.append(f"  {'build':<12}: {build_txt}")
        cond_bits = []
        if m.conditions.junction_temp_c is not None:
            cond_bits.append(f"Tj {m.conditions.junction_temp_c:g} degC")
        cond_bits.append(
            "production bitstream" if m.build.production_bitstream else "NON-PRODUCTION bitstream"
        )
        cond_bits.append("debug cores present" if m.build.debug_cores else "no debug cores")
        if m.conditions.extra:
            cond_bits.append(m.conditions.extra)
        lines.append(f"  {'conditions':<12}: {', '.join(cond_bits)}")
        if prov.notes:
            lines.append(f"  {'notes':<12}: {prov.notes}")

        warns = self.all_warnings()
        if warns:
            lines.append("")
            lines.append("  CAVEATS (all of these belong in any quote of the above):")
            for wmsg in warns:
                for i, chunk in enumerate(_wrap(wmsg, 66)):
                    lines.append(("    ! " if i == 0 else "      ") + chunk)
        return "\n".join(lines)

    def to_dict(self) -> dict:
        m = self.manifest
        out = {
            "label": m.label,
            "metric": m.metric.name,
            "source": m.provenance.source.name,
            "instrument": m.provenance.instrument.name,
            "load_profile": m.load.profile.name,
            "load_description": m.load.description,
            "n": self.dist.n,
            "build": m.build.bitstream,
            "percentiles_ns": {},
            "warnings": self.all_warnings(),
        }
        for name, num, den in PERCENTILES:
            e = self.dist.percentile(num, den)
            out["percentiles_ns"][name] = {
                "ns": e.point_ps / 1000.0,
                "exact": e.exact,
                "lower_bound": e.lower_bound,
            }
        mx = self.dist.maximum()
        out["percentiles_ns"]["max"] = {
            "ns": mx.point_ps / 1000.0,
            "exact": mx.exact,
            "lower_bound": mx.lower_bound,
        }
        return out


def _wrap(text: str, width: int) -> list[str]:
    words = text.split()
    out: list[str] = []
    line = ""
    for w in words:
        if line and len(line) + 1 + len(w) > width:
            out.append(line)
            line = w
        else:
            line = f"{line} {w}".strip()
    if line:
        out.append(line)
    return out or [""]


# =============================================================================
# 8. CLI
# =============================================================================
def _build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="latency.py",
        description=(
            "Ingest latency samples and emit the project's mandatory report "
            "format (p50/p99/p99.9/max, N, load, provenance). Refuses to emit "
            "a report that cannot be interpreted."
        ),
        epilog="See tools/analysis/README.md for the manifest schema.",
    )
    ap.add_argument(
        "--manifest",
        required=True,
        help="JSON run manifest: metric, provenance, load, build. REQUIRED — "
        "there is no way to report without one.",
    )
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--samples", help="CSV of per-event latency deltas")
    src.add_argument(
        "--pairs",
        help="CSV of capture events with an echoed correlation id "
        "(columns: echo_id, t_in_ns, t_out_ns)",
    )
    ap.add_argument("--column", default="delta_cycles", help="column for --samples")
    ap.add_argument(
        "--unit",
        default="cycles",
        choices=sorted(_UNIT_TO_PS),
        help="unit of the input values (default: cycles)",
    )
    ap.add_argument("--id-col", default="echo_id")
    ap.add_argument("--tin-col", default="t_in_ns")
    ap.add_argument("--tout-col", default="t_out_ns")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    return ap


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        manifest = RunManifest.load_file(args.manifest)
        if args.samples:
            dist: Distribution = read_samples_csv(args.samples, args.column, args.unit)
        else:
            dist = read_pairs_csv(
                args.pairs,
                id_col=args.id_col,
                tin_col=args.tin_col,
                tout_col=args.tout_col,
                unit="ns" if args.unit == "cycles" else args.unit,
            )
        report = LatencyReport(dist=dist, manifest=manifest)
    except ProvenanceError as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(report.to_dict(), indent=2, sort_keys=True))
    else:
        print(report.render())
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
