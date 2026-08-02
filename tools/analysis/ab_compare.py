"""ab_compare.py — A/B comparison of two measurement runs, done honestly.

Project : FPGA Algorithmic Trading System (Nasdaq Equities)
Governs : manuals/05-optimization/04-measurement-and-profiling.md §10
          CLAUDE.md §7 (measure -> attribute -> change one thing -> re-measure)

===============================================================================
THE STATEMENT THIS TOOL EXISTS TO MAKE
===============================================================================

    ⚠ A SUB-CYCLE "IMPROVEMENT" IS NOISE, NOT A RESULT.

    One core cycle is 6.4 ns. The fabric cannot produce a latency that is not a
    whole number of cycles, so a reported gain of 2 ns did not come from the
    design — it came from which events happened to land in the sample, or from
    the placer's random seed. With N = 10^6, that 2 ns will have p < 10^-15 and
    still mean nothing.

    Project rule (manual 05.04 §10): an accepted improvement must be
      * >= 1 core cycle (6.4 ns) at p50,
      * AND not worse at p99.9,
      * AND larger than the rig noise floor,
      * AND hold across the directive sweep.
    Effect size in nanoseconds first. The p-value second, if at all.

This module prints that statement on every run, in every mode, whether or not
the result is favourable. It is not a footnote.

===============================================================================
WHY THE DEFAULT INTERVAL IS NOT A BOOTSTRAP
===============================================================================

manual §10 step 7 says "bootstrap a confidence interval on p99.9 (percentiles
have no simple parametric CI)". That is right about the parametric part and
conservative about the rest: an order statistic HAS an exact distribution-free
interval. The number of resampled points below the true p-quantile is
Binomial(n, p), so [x_(k_lo), x_(k_hi)] with k from the binomial tails is a
valid CI for ANY continuous-ish distribution, with no resampling.

That method is used here by default because it is:
  * exact (not an approximation to an approximation),
  * O(n) instead of O(B n log n) — a bootstrap over 10^6 samples is minutes,
  * and DETERMINISTIC. This output gates a keep-or-revert decision. A tool that
    returns a different answer on the same data because of an RNG seed is the
    wrong tool for that job.

`--bootstrap B` is still available for anyone who wants it; it is seeded, and
the seed is printed.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import statistics
import sys
from dataclasses import dataclass
from typing import Sequence

try:  # package import
    from .latency import (
        ONE_CYCLE_PS,
        PERCENTILES,
        LoadProfile,
        ProvenanceError,
        RunManifest,
        SampleSet,
        Source,
        read_samples_csv,
    )
except ImportError:  # executed as a plain script
    from latency import (  # type: ignore[no-redef]
        ONE_CYCLE_PS,
        PERCENTILES,
        LoadProfile,
        ProvenanceError,
        RunManifest,
        SampleSet,
        Source,
        read_samples_csv,
    )

__all__ = [
    "NOISE_BANNER",
    "SWEEP_MIN_BUILDS",
    "Verdict",
    "quantile_ci",
    "wilcoxon_signed_rank",
    "mann_whitney_u",
    "compare",
    "main",
]


#: manual §10 step 3.
SWEEP_MIN_BUILDS = 8

NOISE_BANNER = """\
  ┌────────────────────────────────────────────────────────────────────────┐
  │  A SUB-CYCLE "IMPROVEMENT" IS NOISE, NOT A RESULT.                     │
  │                                                                        │
  │  One core cycle = 6.4 ns @ 156.25 MHz. Fabric latency is quantised to  │
  │  whole cycles; anything finer came from sampling or from the placer's   │
  │  seed, not from the design. At N=1e6 a 0.3 ns "gain" has p < 1e-15 and  │
  │  means nothing. Effect size in ns first; p-value second, if at all.     │
  │                                                                        │
  │  ACCEPT requires: >= 6.4 ns at p50, no worse at p99.9, above the rig    │
  │  noise floor, and holding across the directive sweep (manual 05.04 §10).│
  └────────────────────────────────────────────────────────────────────────┘"""


def _ns(ps: float) -> str:
    return f"{ps / 1000.0:+.2f}"


def _ns_abs(ps: float) -> str:
    return f"{ps / 1000.0:.2f}"


# =============================================================================
# 1. Distribution-free interval for an order statistic
# =============================================================================
_Z95 = 1.959963984540054


def _norm_cdf(z: float) -> float:
    return 0.5 * math.erfc(-z / math.sqrt(2.0))


@dataclass(frozen=True)
class Interval:
    lo_ps: int
    hi_ps: int
    method: str
    trustworthy: bool
    note: str = ""

    def render(self) -> str:
        base = f"[{self.lo_ps / 1000.0:.2f}, {self.hi_ps / 1000.0:.2f}] ns"
        if not self.trustworthy:
            base += f"  (UNRELIABLE: {self.note})"
        return base


def quantile_ci(
    sorted_ps: Sequence[int], num: int, den: int, conf: float = 0.95
) -> Interval:
    """Exact distribution-free CI for the (num/den) quantile.

    The count of observations below the true quantile is Binomial(n, p); the
    interval is the pair of order statistics bracketing that binomial's tails.
    A normal approximation to the binomial is used, which is accurate when
    n*p*(1-p) >= 10 — and the interval is flagged UNRELIABLE when it is not,
    rather than being quietly wrong at the tail, which is the only place it
    would ever matter.
    """
    n = len(sorted_ps)
    if n == 0:
        raise ProvenanceError("quantile_ci: empty sample")
    p = num / den
    var = n * p * (1.0 - p)
    z = _Z95 if abs(conf - 0.95) < 1e-9 else _inv_norm((1.0 + conf) / 2.0)

    centre = n * p
    sd = math.sqrt(var) if var > 0 else 0.0
    k_lo = max(1, int(math.floor(centre - z * sd)))
    k_hi = min(n, int(math.ceil(centre + z * sd)) + 1)

    trustworthy = var >= 10.0
    note = ""
    if not trustworthy:
        note = (
            f"n*p*(1-p) = {var:.1f} < 10; at N={n:,} the {num}/{den} quantile is "
            f"pinned by ~{max(1, n - int(centre))} sample(s)"
        )
    return Interval(
        lo_ps=sorted_ps[k_lo - 1],
        hi_ps=sorted_ps[k_hi - 1],
        method="binomial order statistic (exact, deterministic)",
        trustworthy=trustworthy,
        note=note,
    )


def _inv_norm(q: float) -> float:
    """Acklam-style inverse normal, adequate for CI levels."""
    if not 0.0 < q < 1.0:
        raise ValueError("quantile out of range")
    lo, hi = -10.0, 10.0
    for _ in range(200):
        mid = (lo + hi) / 2.0
        if _norm_cdf(mid) < q:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2.0


def bootstrap_quantile_diff_ci(
    a: Sequence[int],
    b: Sequence[int],
    num: int,
    den: int,
    reps: int,
    seed: int,
    paired: bool,
) -> Interval:
    """Bootstrap CI on (quantile(b) - quantile(a)). Seeded, so reproducible.

    Provided because manual §10 asks for it. Prefer `quantile_ci` unless you
    specifically need an interval on the DIFFERENCE.
    """
    rng = random.Random(seed)
    n_a, n_b = len(a), len(b)
    if paired and n_a != n_b:
        raise ProvenanceError("bootstrap: paired mode needs equal-length inputs")

    def q(sorted_vals: list[int]) -> int:
        rank = (len(sorted_vals) * num + den - 1) // den
        return sorted_vals[max(1, min(rank, len(sorted_vals))) - 1]

    diffs: list[int] = []
    for _ in range(reps):
        if paired:
            idx = [rng.randrange(n_a) for _ in range(n_a)]
            sa = sorted(a[i] for i in idx)
            sb = sorted(b[i] for i in idx)
        else:
            sa = sorted(a[rng.randrange(n_a)] for _ in range(n_a))
            sb = sorted(b[rng.randrange(n_b)] for _ in range(n_b))
        diffs.append(q(sb) - q(sa))
    diffs.sort()
    lo = diffs[max(0, int(0.025 * reps) - 1)]
    hi = diffs[min(reps - 1, int(0.975 * reps))]
    return Interval(
        lo_ps=lo,
        hi_ps=hi,
        method=f"bootstrap, B={reps}, seed={seed}",
        trustworthy=True,
    )


# =============================================================================
# 2. Nonparametric tests (manual §10 step 5)
# =============================================================================
@dataclass(frozen=True)
class TestResult:
    name: str
    statistic: float
    z: float
    p_two_sided: float
    n_used: int
    n_zero: int = 0
    note: str = ""


def wilcoxon_signed_rank(deltas: Sequence[int]) -> TestResult:
    """Paired, nonparametric, tie-corrected, normal approximation.

    ⚠ Latency deltas are CYCLE-QUANTISED, so exact zeros dominate: two builds
    that differ only in routing will produce d = 0 for most events. Zeros are
    dropped (Wilcoxon's own convention) and their count is reported, because a
    test run on 400 non-zero pairs out of 10^6 is describing 0.04% of the data
    and the reader must know that.
    """
    nz = [d for d in deltas if d != 0]
    n_zero = len(deltas) - len(nz)
    n = len(nz)
    if n == 0:
        return TestResult(
            "Wilcoxon signed-rank",
            0.0,
            0.0,
            1.0,
            0,
            n_zero,
            "every paired difference was exactly zero: the two runs are "
            "cycle-for-cycle identical on this input",
        )

    order = sorted(range(n), key=lambda i: abs(nz[i]))
    ranks = [0.0] * n
    tie_term = 0.0
    i = 0
    while i < n:
        j = i
        while j + 1 < n and abs(nz[order[j + 1]]) == abs(nz[order[i]]):
            j += 1
        avg = (i + 1 + j + 1) / 2.0
        t = j - i + 1
        tie_term += t**3 - t
        for k in range(i, j + 1):
            ranks[order[k]] = avg
        i = j + 1

    w_plus = sum(r for r, d in zip(ranks, nz) if d > 0)
    mean = n * (n + 1) / 4.0
    var = n * (n + 1) * (2 * n + 1) / 24.0 - tie_term / 48.0
    if var <= 0:
        return TestResult("Wilcoxon signed-rank", w_plus, 0.0, 1.0, n, n_zero,
                          "zero variance after tie correction")
    cc = 0.5 if w_plus > mean else -0.5
    z = (w_plus - mean - cc) / math.sqrt(var)
    p = 2.0 * (1.0 - _norm_cdf(abs(z)))
    return TestResult("Wilcoxon signed-rank", w_plus, z, min(1.0, p), n, n_zero)


def mann_whitney_u(a: Sequence[int], b: Sequence[int]) -> TestResult:
    """Unpaired, nonparametric, tie-corrected, normal approximation."""
    n1, n2 = len(a), len(b)
    if n1 == 0 or n2 == 0:
        raise ProvenanceError("mann_whitney_u: empty input")
    combined = sorted([(v, 0) for v in a] + [(v, 1) for v in b])
    n = n1 + n2
    ranks = [0.0] * n
    tie_term = 0.0
    i = 0
    while i < n:
        j = i
        while j + 1 < n and combined[j + 1][0] == combined[i][0]:
            j += 1
        avg = (i + 1 + j + 1) / 2.0
        t = j - i + 1
        tie_term += t**3 - t
        for k in range(i, j + 1):
            ranks[k] = avg
        i = j + 1

    r1 = sum(r for r, (_v, grp) in zip(ranks, combined) if grp == 0)
    u1 = r1 - n1 * (n1 + 1) / 2.0
    mean = n1 * n2 / 2.0
    var = (n1 * n2 / 12.0) * ((n + 1) - tie_term / (n * (n - 1))) if n > 1 else 0.0
    if var <= 0:
        return TestResult("Mann-Whitney U", u1, 0.0, 1.0, n, 0, "zero variance")
    cc = 0.5 if u1 > mean else -0.5
    z = (u1 - mean - cc) / math.sqrt(var)
    p = 2.0 * (1.0 - _norm_cdf(abs(z)))
    return TestResult("Mann-Whitney U", u1, z, min(1.0, p), n)


# =============================================================================
# 3. The decision (manual §10 decision table)
# =============================================================================
class Verdict:
    ACCEPT = "ACCEPT"
    ACCEPT_TAIL = "ACCEPT (tail win)"
    ACCEPT_CAVEAT = "ACCEPT — with a caveat"
    REJECT = "REJECT"
    REVERT = "REVERT"


def _decide(d50: int, d999: int, floor_ps: int) -> tuple[str, str]:
    """delta = B - A, in ps. Negative = B is faster."""
    improved50 = d50 <= -floor_ps
    worse50 = d50 >= floor_ps
    improved999 = d999 <= -floor_ps
    worse999 = d999 >= floor_ps

    if worse50:
        return Verdict.REJECT, "p50 got worse. No tail improvement redeems that."
    if improved50:
        if d999 <= 0:
            return Verdict.ACCEPT, "p50 improved by >= the effect floor and p99.9 is no worse."
        if worse999:
            return (
                Verdict.REJECT,
                "p50 improved but p99.9 got worse by more than the effect floor. "
                "Determinism outranks the mean (CLAUDE.md §5.8). Overriding this "
                "requires an explicit written argument and a sign-off.",
            )
        return (
            Verdict.ACCEPT_CAVEAT,
            "p50 improved by >= the effect floor; p99.9 rose but by less than "
            "the floor, so the rise is itself within noise. Re-measure the tail "
            "on a longer run before treating this as settled.",
        )
    # p50 within noise
    if improved999:
        return Verdict.ACCEPT_TAIL, "p50 unchanged, p99.9 improved. Tail wins count."
    if worse999:
        return Verdict.REJECT, "p50 unchanged and p99.9 got worse."
    return (
        Verdict.REVERT,
        "Both p50 and p99.9 are within noise. manual 05.04 §10: complexity with "
        "no measured benefit is a defect. Revert the change.",
    )


# =============================================================================
# 4. Comparison
# =============================================================================
@dataclass
class Side:
    name: str
    manifest: RunManifest
    builds: list[SampleSet]

    @property
    def n_builds(self) -> int:
        return len(self.builds)

    def pct_across_builds(self, num: int, den: int) -> list[int]:
        return [b.percentile(num, den).lo_ps for b in self.builds]


def _cross_checks(a: Side, b: Side) -> list[str]:
    """Things that make a comparison invalid rather than merely noisy."""
    problems: list[str] = []
    warns: list[str] = []

    if a.manifest.provenance.source is not b.manifest.provenance.source:
        problems.append(
            f"A is {a.manifest.provenance.source} and B is "
            f"{b.manifest.provenance.source}. These are not comparable — "
            "simulation has no PMA, no gearbox, no routing delay and no "
            "contention (manual 05.04 §7). Comparing them produces a number "
            "with no meaning."
        )
    if a.manifest.load.profile is not b.manifest.load.profile:
        problems.append(
            f"A ran under load '{a.manifest.load.profile.name}' and B under "
            f"'{b.manifest.load.profile.name}'. Different load, different "
            "arbitration, different TX occupancy, different book contention. "
            "This is not an A/B test of the change (manual 05.04 §8)."
        )
    if a.manifest.metric is not b.manifest.metric:
        problems.append(
            f"A measures {a.manifest.metric.name} and B measures "
            f"{b.manifest.metric.name}. Different intervals."
        )
    if (
        a.manifest.load.source_file
        and b.manifest.load.source_file
        and a.manifest.load.source_file != b.manifest.load.source_file
    ):
        problems.append(
            "A and B replayed different files. manual 05.04 §10 step 2 requires "
            "the SAME replay file, byte-identical, in the same order — the "
            "samples must be paired, not merely similar."
        )

    if (
        a.manifest.build.tool_version
        and b.manifest.build.tool_version
        and a.manifest.build.tool_version != b.manifest.build.tool_version
    ):
        warns.append(
            f"different tool versions ({a.manifest.build.tool_version} vs "
            f"{b.manifest.build.tool_version}). Placement noise alone moves "
            "latency-relevant routing; part of any difference below is the "
            "toolchain, not the change (manual 05.04 §7)."
        )
    if a.manifest.build.bitstream == b.manifest.build.bitstream:
        warns.append(
            "A and B name the SAME bitstream. Either the manifests are wrong or "
            "this is a repeatability run, not an A/B test."
        )
    for side in (a, b):
        if side.n_builds < SWEEP_MIN_BUILDS:
            warns.append(
                f"{side.name} is backed by {side.n_builds} build(s); manual "
                f"05.04 §10 step 3 requires >= {SWEEP_MIN_BUILDS} across a "
                "directive sweep. A single build of each variant is a "
                "comparison of two random placement samples."
            )
        if not side.manifest.load.profile.is_representative:
            warns.append(
                f"{side.name} load profile '{side.manifest.load.profile.name}' "
                "is not representative; an optimization validated on synthetic "
                "or idle traffic is not validated (manual 05.04 §8)."
            )
    return problems + [f"(warning) {w}" for w in warns]


def compare(
    a: Side,
    b: Side,
    paired: bool,
    bootstrap: int = 0,
    seed: int = 20260802,
) -> str:
    issues = _cross_checks(a, b)
    hard = [i for i in issues if not i.startswith("(warning)")]
    if hard:
        raise ProvenanceError(
            "these runs cannot be compared:\n    - " + "\n    - ".join(hard)
        )

    nf = [
        x
        for x in (
            a.manifest.provenance.noise_floor_ps,
            b.manifest.provenance.noise_floor_ps,
        )
        if x is not None
    ]
    rig_floor = max(nf) if nf else 0
    floor_ps = max(ONE_CYCLE_PS, rig_floor)

    out: list[str] = [NOISE_BANNER, ""]
    out.append(f"  A : {a.name}  [{a.manifest.build.bitstream}]  "
               f"{a.n_builds} build(s), N={sum(s.n for s in a.builds):,}")
    out.append(f"  B : {b.name}  [{b.manifest.build.bitstream}]  "
               f"{b.n_builds} build(s), N={sum(s.n for s in b.builds):,}")
    out.append(f"  load        : {a.manifest.load.profile.value}")
    out.append(f"  metric      : {a.manifest.metric.value}")
    out.append(f"  source      : {a.manifest.provenance.source}")
    out.append(
        f"  effect floor: {_ns_abs(floor_ps)} ns "
        f"(1 core cycle = {_ns_abs(ONE_CYCLE_PS)} ns"
        + (f"; rig noise floor = {_ns_abs(rig_floor)} ns" if rig_floor else
           "; NO RIG NOISE FLOOR DECLARED")
        + ")"
    )
    out.append("")

    # -- per-percentile effect sizes, median across the build sweep --------
    out.append("  EFFECT SIZE (B - A; negative = B is faster). Median across builds:")
    out.append("")
    out.append("    metric      A (median)     B (median)      delta      verdict at floor")
    out.append("    " + "-" * 72)

    deltas: dict[str, int] = {}
    for name, num, den in PERCENTILES:
        av = a.pct_across_builds(num, den)
        bv = b.pct_across_builds(num, den)
        a_med = int(statistics.median(av))
        b_med = int(statistics.median(bv))
        d = b_med - a_med
        deltas[name] = d
        tag = (
            "improvement"
            if d <= -floor_ps
            else ("REGRESSION" if d >= floor_ps else "within noise")
        )
        out.append(
            f"    {name:<10} {a_med / 1000.0:>10.2f} ns {b_med / 1000.0:>10.2f} ns "
            f"{_ns(d):>10} ns   {tag}"
        )
    a_max = int(statistics.median([s.maximum().lo_ps for s in a.builds]))
    b_max = int(statistics.median([s.maximum().lo_ps for s in b.builds]))
    out.append(
        f"    {'max':<10} {a_max / 1000.0:>10.2f} ns {b_max / 1000.0:>10.2f} ns "
        f"{_ns(b_max - a_max):>10} ns   (max is not a percentile; it is one event)"
    )
    out.append("")

    # -- build-to-build spread: the placement lottery, quantified ----------
    if a.n_builds > 1 or b.n_builds > 1:
        out.append("  BUILD-TO-BUILD SPREAD (implementation noise, p50):")
        for side in (a, b):
            v = side.pct_across_builds(1, 2)
            spread = max(v) - min(v)
            out.append(
                f"    {side.name:<3}: min {min(v) / 1000.0:.2f} ns  "
                f"median {statistics.median(v) / 1000.0:.2f} ns  "
                f"max {max(v) / 1000.0:.2f} ns   spread {spread / 1000.0:.2f} ns"
            )
            if spread >= abs(deltas["p50"]) and abs(deltas["p50"]) > 0:
                out.append(
                    f"         ! the spread WITHIN {side.name} "
                    f"({spread / 1000.0:.2f} ns) is at least as large as the "
                    f"A/B difference ({abs(deltas['p50']) / 1000.0:.2f} ns). "
                    "The change is not distinguishable from the placer."
                )
        out.append("")

    # -- interval on p99.9 --------------------------------------------------
    out.append("  p99.9 INTERVAL (95%), the tail is checked separately (§10 step 7):")
    for side in (a, b):
        pooled = sorted(v for s in side.builds for v in s.values_ps)
        ci = quantile_ci(pooled, 999, 1000)
        out.append(f"    {side.name:<3}: {ci.render()}   [{ci.method}]")
    if bootstrap:
        pa = [v for s in a.builds for v in s.values_ps]
        pb = [v for s in b.builds for v in s.values_ps]
        can_pair = paired and len(pa) == len(pb)
        ci = bootstrap_quantile_diff_ci(
            pa, pb, 999, 1000, bootstrap, seed, paired=can_pair
        )
        out.append(f"    diff (B-A): {ci.render()}   [{ci.method}]")
    out.append("")

    # -- the test, reported after the effect size, as the manual demands ----
    out.append("  SIGNIFICANCE TEST (reported second, and it is the lesser number):")
    if paired:
        pairs_run = 0
        for i in range(min(a.n_builds, b.n_builds)):
            av, bv = a.builds[i].values_ps, b.builds[i].values_ps
            if len(av) != len(bv):
                out.append(
                    f"    build pair {i}: N differs ({len(av):,} vs {len(bv):,}) — "
                    "cannot pair. Either an event was dropped in one run or the "
                    "replay was not byte-identical. Falling back to unpaired for "
                    "this pair would hide that, so it is skipped."
                )
                continue
            res = wilcoxon_signed_rank([y - x for x, y in zip(av, bv)])
            pairs_run += 1
            out.append(
                f"    build pair {i}: {res.name}  z={res.z:+.3f}  "
                f"p={res.p_two_sided:.3g}  non-zero pairs={res.n_used:,}  "
                f"exact ties={res.n_zero:,}"
            )
            if res.note:
                out.append(f"                    note: {res.note}")
            if res.n_used and res.n_zero and res.n_zero > 20 * res.n_used:
                out.append(
                    f"                    ! {res.n_zero:,} of "
                    f"{res.n_zero + res.n_used:,} events were cycle-identical. "
                    "The test describes a small minority of the traffic."
                )
        if pairs_run == 0:
            out.append("    no build pair could be paired; no test was run.")
    else:
        pa = [v for s in a.builds for v in s.values_ps]
        pb = [v for s in b.builds for v in s.values_ps]
        res = mann_whitney_u(pa, pb)
        out.append(
            f"    {res.name}  z={res.z:+.3f}  p={res.p_two_sided:.3g}  N={res.n_used:,}"
        )
        out.append(
            "    ! unpaired. manual 05.04 §10 step 2 wants paired samples from a "
            "byte-identical replay; unpaired comparison needs a far larger "
            "effect to say anything."
        )
    out.append(
        "    With N in the millions everything is significant. The p-value above "
        "does not\n    upgrade a sub-cycle difference into a result."
    )
    out.append("")

    # -- sweep consistency --------------------------------------------------
    if a.n_builds > 1 and a.n_builds == b.n_builds:
        agree = sum(
            1
            for i in range(a.n_builds)
            if (b.builds[i].percentile(1, 2).lo_ps - a.builds[i].percentile(1, 2).lo_ps)
            <= -floor_ps
        )
        out.append(
            f"  SWEEP CONSISTENCY: the p50 improvement holds in {agree}/"
            f"{a.n_builds} build pairs."
        )
        if agree != a.n_builds:
            out.append(
                "    ! manual 05.04 §10 requires the improvement to hold ACROSS "
                "the sweep. It does not."
            )
        out.append("")

    # -- verdict ------------------------------------------------------------
    verdict, why = _decide(deltas["p50"], deltas["p99.9"], floor_ps)
    if a.n_builds > 1 and a.n_builds == b.n_builds:
        agree = sum(
            1
            for i in range(a.n_builds)
            if (b.builds[i].percentile(1, 2).lo_ps - a.builds[i].percentile(1, 2).lo_ps)
            <= -floor_ps
        )
        if verdict.startswith("ACCEPT") and agree != a.n_builds:
            verdict = Verdict.REJECT
            why = (
                "the effect size qualifies, but it does not hold across the "
                "directive sweep — it is a placement result, not a design result."
            )
    if a.n_builds < SWEEP_MIN_BUILDS or b.n_builds < SWEEP_MIN_BUILDS:
        why += (
            f"  [PROVISIONAL: fewer than {SWEEP_MIN_BUILDS} builds per variant; "
            "not yet a sweep-backed conclusion.]"
        )

    out.append(f"  VERDICT: {verdict}")
    for chunk in _wrap(why, 70):
        out.append(f"           {chunk}")

    warns = [i[len("(warning) "):] for i in issues if i.startswith("(warning)")]
    if warns:
        out.append("")
        out.append("  CAVEATS:")
        for wmsg in warns:
            for i, chunk in enumerate(_wrap(wmsg, 68)):
                out.append(("    ! " if i == 0 else "      ") + chunk)
    return "\n".join(out)


def _wrap(text: str, width: int) -> list[str]:
    words, out, line = text.split(), [], ""
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
# 5. CLI
# =============================================================================
def _build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="ab_compare.py",
        description=(
            "Compare two measurement runs with a one-core-cycle effect-size "
            "floor. Prints the effect size first, the p-value second, and the "
            "reminder that a sub-cycle improvement is noise, always."
        ),
    )
    ap.add_argument("--a-manifest", required=True)
    ap.add_argument(
        "--a-samples",
        required=True,
        nargs="+",
        help="one CSV per build in the directive sweep",
    )
    ap.add_argument("--b-manifest", required=True)
    ap.add_argument("--b-samples", required=True, nargs="+")
    ap.add_argument("--a-name", default="A")
    ap.add_argument("--b-name", default="B")
    ap.add_argument("--column", default="delta_cycles")
    ap.add_argument("--unit", default="cycles", choices=["cycles", "ns", "ps", "us"])
    ap.add_argument(
        "--unpaired",
        action="store_true",
        help="use Mann-Whitney U instead of Wilcoxon; only correct when the two "
        "runs did NOT see the same replay",
    )
    ap.add_argument(
        "--bootstrap",
        type=int,
        default=0,
        metavar="B",
        help="also bootstrap a CI on the p99.9 difference (seeded; slow at "
        "large N). The default binomial interval is exact and deterministic.",
    )
    ap.add_argument("--seed", type=int, default=20260802)
    return ap


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        a = Side(
            name=args.a_name,
            manifest=RunManifest.load_file(args.a_manifest),
            builds=[read_samples_csv(f, args.column, args.unit) for f in args.a_samples],
        )
        b = Side(
            name=args.b_name,
            manifest=RunManifest.load_file(args.b_manifest),
            builds=[read_samples_csv(f, args.column, args.unit) for f in args.b_samples],
        )
        print(compare(a, b, paired=not args.unpaired, bootstrap=args.bootstrap,
                      seed=args.seed))
    except ProvenanceError as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
