#!/usr/bin/env python3
# =============================================================================
# scripts/report_qor.py — parse Vivado reports into a machine-readable QoR line
# -----------------------------------------------------------------------------
# Project : FPGA Algorithmic Trading System (Nasdaq Equities)
# Governs : manuals/06-operations/01-build-and-release.md §5 (metrics tracked
#             over time), §6 (seed sweeps as the closure criterion)
#           manuals/00-foundations/05-timing-closure.md §2 (reading the numbers),
#             §9 (reporting timing honestly)
#
# WHAT THIS DOES
#   Reads a build directory produced by scripts/build.tcl and emits:
#     1. ONE LINE of JSON on stdout, suitable for `>> qor.jsonl` and a CI
#        time-series ingest. One line per build, append-only, forever.
#     2. Optionally (--table) a human-readable summary on stderr.
#
#   In --sweep mode it does the same for every seed under a sweep root and
#   applies the project closure criterion from
#   manuals/06-operations/01-build-and-release.md §6.
#
# WHY ONE LINE OF JSON
#   Because the value of these numbers is in the TREND, not in any single build.
#   06-operations/01-build-and-release.md §5: "Push one row per nightly build
#   into a time-series store and plot it. These are the health signals of the
#   whole project ... Timing and resources degrade gradually and then suddenly;
#   the graph gives weeks of warning."
#
# ⚠️ WHAT THIS SCRIPT WILL NOT DO
#   - It will not estimate, interpolate, or "clean up" a number. Every field is
#     read from a report or is null. CLAUDE.md §4: "Report WNS/TNS and
#     utilization from the actual report, quoted verbatim. Never estimate or
#     predict these."
#   - It will not report a synthesis WNS as a closure number. Synthesis timing
#     is optimistic by 20-40% because it has no placement information
#     (05-timing-closure.md §2). Synth numbers are tagged `stage: "post_synth"`
#     and the `timing_closed` field is null for them, never true.
#   - It will not report the best seed of a sweep as "the" result.
#
# USAGE
#   scripts/report_qor.py --build builds/20260802-9f1c3ae-s7            # one build
#   scripts/report_qor.py --build <dir> --table                        # + human table
#   scripts/report_qor.py --sweep builds/sweep-… --csv s.csv --table   # a sweep
#   scripts/report_qor.py --build <dir> >> ci/qor.jsonl                 # trending
# =============================================================================

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import statistics
import sys
from typing import Any

# -----------------------------------------------------------------------------
# Device capacity table — for the percentage columns.
# -----------------------------------------------------------------------------
# ⚠️ Vivado's own report_utilization already prints percentages against the real
#    part. These numbers are ONLY a fallback for when the report's percentage
#    column cannot be parsed (older/newer report formats move columns around).
#    A parsed percentage always wins over a computed one, and the output records
#    which was used in `util_pct_source`, so a wrong table here can never
#    silently become a wrong headline number.
#
# TODO(verify): confirm against the datasheet for the exact part before relying
#    on the fallback. xcvu9p: 3 SLRs, values below are the whole device.
DEVICE_CAPACITY: dict[str, dict[str, int]] = {
    "xcvu9p": {"lut": 1182240, "ff": 2364480, "bram": 2160, "uram": 960, "dsp": 6840},
    "xcvu13p": {"lut": 1728000, "ff": 3456000, "bram": 2688, "uram": 1280, "dsp": 12288},
    "xcku15p": {"lut": 522720, "ff": 1045440, "bram": 984, "uram": 480, "dsp": 1968},
}

# Resource-headroom alert threshold. 06-operations/01-build-and-release.md §5:
# "> 70 % of any resource" is an alert condition, because congestion rises
# sharply past that point and the NEXT change is the one that fails to route.
UTIL_ALERT_PCT = 70.0


# =============================================================================
# Report parsing
# =============================================================================
def _read(path: str) -> str | None:
    try:
        with open(path, "r", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def parse_timing_summary(text: str) -> dict[str, Any]:
    """Extract WNS/TNS/WHS/THS and endpoint counts from report_timing_summary.

    The 'Design Timing Summary' block looks like:

        WNS(ns)  TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints  WHS(ns) ...
        -------  -------  ---------------------  -------------------  -------
          0.113    0.000                      0               412031    0.021

    ⚠️ Parsed positionally from the numeric row that follows the dashed rule,
       because the header wraps differently across Vivado versions. If the row
       cannot be found, every field stays None — a missing number is reported as
       missing, never as zero. A zero WNS that is really "I could not parse it"
       would read as a design that exactly met timing, which is the most
       misleading possible failure of this script.
    """
    out: dict[str, Any] = {
        "wns_ns": None, "tns_ns": None, "whs_ns": None, "ths_ns": None,
        "failing_endpoints_setup": None, "failing_endpoints_hold": None,
        "total_endpoints_setup": None,
        "wpws_ns": None, "tpws_ns": None, "failing_endpoints_pulse": None,
    }
    if not text:
        return out

    # Locate the design timing summary section, then the first all-numeric row.
    sec = text
    m = re.search(r"Design Timing Summary\s*\n\s*-+\s*\n(.*?)(?:\n\s*\n|\Z)",
                  text, re.S)
    if m:
        sec = m.group(1)

    num = r"(-?\d+\.\d+|-?\d+|NA)"
    row = re.search(
        rf"^\s*{num}\s+{num}\s+(\d+)\s+(\d+)\s+"
        rf"{num}\s+{num}\s+(\d+)\s+(\d+)\s+"
        rf"{num}\s+{num}\s+(\d+)\s+(\d+)",
        sec, re.M)

    def f(v: str) -> float | None:
        if v is None or v == "NA":
            return None
        try:
            return float(v)
        except ValueError:
            return None

    if row:
        g = row.groups()
        out["wns_ns"] = f(g[0])
        out["tns_ns"] = f(g[1])
        out["failing_endpoints_setup"] = int(g[2])
        out["total_endpoints_setup"] = int(g[3])
        out["whs_ns"] = f(g[4])
        out["ths_ns"] = f(g[5])
        out["failing_endpoints_hold"] = int(g[6])
        out["wpws_ns"] = f(g[8])
        out["tpws_ns"] = f(g[9])
        out["failing_endpoints_pulse"] = int(g[10])
        return out

    # Fallback: labelled single-value forms used by some report variants.
    for key, label in (("wns_ns", "WNS"), ("tns_ns", "TNS"),
                       ("whs_ns", "WHS"), ("ths_ns", "THS")):
        m = re.search(rf"\b{label}\s*\(ns\)\s*[:=]?\s*(-?\d+\.\d+)", text)
        if m:
            out[key] = float(m.group(1))
    return out


def parse_utilization(text: str) -> dict[str, Any]:
    """Extract LUT/FF/BRAM/URAM/DSP counts and percentages.

    report_utilization emits table rows of the form:
        | CLB LUTs                   | 48213 |     0 |      0 |   1182240 |  4.08 |
    The site-type name varies by family (CLB LUTs / Slice LUTs / LUT as Logic),
    so each resource is matched against a set of aliases rather than one string.
    """
    out: dict[str, Any] = {
        "lut": None, "ff": None, "bram": None, "uram": None, "dsp": None,
        "lut_pct": None, "ff_pct": None, "bram_pct": None,
        "uram_pct": None, "dsp_pct": None,
        "util_pct_source": "report",
    }
    if not text:
        out["util_pct_source"] = None
        return out

    aliases = {
        "lut": [r"CLB LUTs\*?", r"Slice LUTs\*?", r"LUT as Logic"],
        "ff": [r"CLB Registers", r"Slice Registers", r"Register as Flip Flop"],
        "bram": [r"Block RAM Tile", r"BRAM Tile", r"RAMB36/FIFO\*?"],
        "uram": [r"URAM", r"UltraRAM"],
        "dsp": [r"DSPs", r"DSP48E2 only", r"DSP Slices"],
    }

    for key, pats in aliases.items():
        for pat in pats:
            # | <name> | <used> | <fixed> | <prohibited> | <available> | <pct> |
            m = re.search(
                rf"^\s*\|\s*{pat}\s*\|\s*(\d+)\s*\|"
                rf"(?:[^|]*\|){{0,3}}\s*(\d+)\s*\|\s*([\d.]+)\s*\|",
                text, re.M)
            if m:
                out[key] = int(m.group(1))
                out[f"{key}_pct"] = float(m.group(3))
                break
            # Shorter table variant: | <name> | <used> | <available> | <pct> |
            m = re.search(rf"^\s*\|\s*{pat}\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|",
                          text, re.M)
            if m:
                out[key] = int(m.group(1))
                out[f"{key}_pct"] = float(m.group(3))
                break
    return out


def fill_pct_from_part(util: dict[str, Any], part: str | None) -> None:
    """Compute percentages from the device table when the report had none."""
    if not part:
        return
    cap = None
    for prefix, table in DEVICE_CAPACITY.items():
        if part.startswith(prefix):
            cap = table
            break
    if cap is None:
        return
    filled = False
    for key in ("lut", "ff", "bram", "uram", "dsp"):
        if util.get(f"{key}_pct") is None and util.get(key) is not None and cap.get(key):
            util[f"{key}_pct"] = round(100.0 * util[key] / cap[key], 2)
            filled = True
    if filled and util.get("util_pct_source") != "report":
        util["util_pct_source"] = "device_table"


def count_matches(text: str | None, pattern: str) -> int | None:
    if text is None:
        return None
    return len(re.findall(pattern, text, re.M))


def parse_drc(text: str | None) -> dict[str, Any]:
    """Count DRC violations by severity."""
    if text is None:
        return {"drc_critical": None, "drc_error": None, "drc_warning": None}
    return {
        "drc_critical": count_matches(text, r"^CRITICAL WARNING"),
        "drc_error": count_matches(text, r"^ERROR"),
        "drc_warning": count_matches(text, r"^WARNING"),
    }


def parse_cdc(text: str | None) -> dict[str, Any]:
    """Count CDC findings by severity from report_cdc.

    ⚠️ report_cdc is the ONLY structural CDC check available — STA excludes
       these paths from analysis by definition, so a clean timing report says
       nothing about CDC safety
       (manuals/00-foundations/04-clocking-reset-and-cdc.md §6).
       A non-zero critical count is a build failure in scripts/build.tcl; it is
       surfaced here so the CI trend shows the day it appeared.
    """
    if text is None:
        return {"cdc_critical": None, "cdc_warning": None}
    return {
        "cdc_critical": count_matches(text, r"\bCritical\b"),
        "cdc_warning": count_matches(text, r"\bWarning\b"),
    }


def parse_congestion(text: str | None) -> dict[str, Any]:
    """Peak congestion level from report_design_analysis.

    06-operations/01-build-and-release.md §5 alerts at "congestion level >= 5".
    Congestion is the leading indicator: it rises before timing falls, and it is
    the number that predicts whether the NEXT change will route.
    """
    if text is None:
        return {"congestion_max": None}
    levels = [int(x) for x in re.findall(r"^\s*\|\s*Level\s*\|\s*(\d)\s*\|", text, re.M)]
    if not levels:
        levels = [int(x) for x in re.findall(r"Congestion Level\s*[:=]?\s*(\d)", text)]
    return {"congestion_max": max(levels) if levels else None}


def parse_slr_crossings(text: str | None) -> dict[str, Any]:
    """SLR crossing count from report_design_analysis.

    ⚠️ constraints/floorplan.xdc exists to keep this at zero for the fast path.
       An SLR crossing costs roughly a full clock cycle; at 6.4 ns that is the
       whole period. A crossing appearing on a fast-path timing path is a
       regression against the latency budget in rtl/fpga_top.sv, not merely a
       timing problem.
    """
    if text is None:
        return {"slr_crossings": None}
    m = re.findall(r"SLR\s*Cross(?:ing)?s?\s*[:|]\s*(\d+)", text, re.I)
    if m:
        return {"slr_crossings": max(int(x) for x in m)}
    return {"slr_crossings": None}


# =============================================================================
# One build -> one QoR record
# =============================================================================
def collect_build(build_dir: str, stage: str = "post_route") -> dict[str, Any]:
    rpt = os.path.join(build_dir, "rpt")

    manifest: dict[str, Any] = {}
    mpath = os.path.join(build_dir, "manifest.json")
    raw = _read(mpath)
    if raw:
        try:
            manifest = json.loads(raw)
        except json.JSONDecodeError:
            manifest = {}

    timing = parse_timing_summary(_read(os.path.join(rpt, f"{stage}_timing_summary.rpt")) or "")
    util = parse_utilization(_read(os.path.join(rpt, f"{stage}_utilization.rpt")) or "")
    fill_pct_from_part(util, manifest.get("part"))

    drc = parse_drc(_read(os.path.join(rpt, f"{stage}_drc.rpt")))
    cdc = parse_cdc(_read(os.path.join(rpt, f"{stage}_cdc.rpt")))
    da_text = _read(os.path.join(rpt, f"{stage}_design_analysis.rpt"))
    cong = parse_congestion(da_text)
    slr = parse_slr_crossings(da_text)

    # ⚠️ timing_closed is ONLY meaningful post-route. For any earlier stage it is
    #    null, never true — 05-timing-closure.md §2: "Never report a synthesis
    #    number as 'timing closed.'"
    closed: bool | None = None
    if stage == "post_route" and timing["wns_ns"] is not None and timing["whs_ns"] is not None:
        closed = (timing["wns_ns"] >= 0.0) and (timing["whs_ns"] >= 0.0)

    rec: dict[str, Any] = {
        "schema": 1,
        "build_dir": os.path.relpath(build_dir),
        "stage": stage,
        # Provenance — every one of these changes the result and must travel
        # with it (06-operations/01-build-and-release.md §1).
        "git_sha": manifest.get("git_sha"),
        "git_dirty": manifest.get("git_dirty"),
        "tool": manifest.get("tool"),
        "part": manifest.get("part"),
        "seed": manifest.get("seed"),
        "threads": manifest.get("threads"),
        "directives": manifest.get("directives"),
        "constraint_sha256": manifest.get("constraint_sha256"),
        "floorplan_enabled": manifest.get("floorplan_enabled"),
        "built_at_utc": manifest.get("built_at_utc"),
        "wall_seconds": manifest.get("wall_seconds"),
    }
    rec.update(timing)
    rec.update({k: util[k] for k in
                ("lut", "ff", "bram", "uram", "dsp",
                 "lut_pct", "ff_pct", "bram_pct", "uram_pct", "dsp_pct",
                 "util_pct_source")})
    rec.update(drc)
    rec.update(cdc)
    rec.update(cong)
    rec.update(slr)
    rec["timing_closed"] = closed

    # Alerts, computed here so CI does not have to re-encode the thresholds.
    alerts: list[str] = []
    if closed is False:
        alerts.append("TIMING_NOT_CLOSED")
    for key in ("lut", "ff", "bram", "uram", "dsp"):
        pct = rec.get(f"{key}_pct")
        if pct is not None and pct > UTIL_ALERT_PCT:
            alerts.append(f"UTIL_{key.upper()}_OVER_{int(UTIL_ALERT_PCT)}PCT")
    if rec.get("congestion_max") is not None and rec["congestion_max"] >= 5:
        alerts.append("CONGESTION_GE_5")
    if rec.get("cdc_critical"):
        alerts.append("CDC_CRITICAL")
    if rec.get("drc_critical"):
        alerts.append("DRC_CRITICAL")
    if rec.get("git_dirty"):
        alerts.append("GIT_DIRTY")
    rec["alerts"] = alerts
    return rec


# =============================================================================
# Human-readable rendering
# =============================================================================
def _fmt(v: Any, width: int = 10, prec: int = 3) -> str:
    if v is None:
        return "n/a".rjust(width)
    if isinstance(v, float):
        return f"{v:.{prec}f}".rjust(width)
    return str(v).rjust(width)


def render_table(rec: dict[str, Any]) -> str:
    L: list[str] = []
    add = L.append
    add("=" * 76)
    add(f" QoR  {rec.get('build_dir')}   stage={rec.get('stage')}")
    add(f" part {rec.get('part')}   seed {rec.get('seed')}   tool {rec.get('tool')}")
    add(f" git  {str(rec.get('git_sha'))[:12]}   dirty={rec.get('git_dirty')}"
        f"   constraints {str(rec.get('constraint_sha256'))[:12]}")
    add("=" * 76)
    add("")
    add(" TIMING (post-route numbers are the only ones that mean closure)")
    add(f"   WNS {_fmt(rec['wns_ns'])} ns    TNS {_fmt(rec['tns_ns'])} ns"
        f"    failing setup endpoints {rec['failing_endpoints_setup']}")
    add(f"   WHS {_fmt(rec['whs_ns'])} ns    THS {_fmt(rec['ths_ns'])} ns"
        f"    failing hold  endpoints {rec['failing_endpoints_hold']}")
    if rec.get("total_endpoints_setup"):
        add(f"   total setup endpoints analysed: {rec['total_endpoints_setup']}")
    add("")

    # 05-timing-closure.md §2 interpretation guidance, applied automatically.
    wns, tns, nfail = rec["wns_ns"], rec["tns_ns"], rec["failing_endpoints_setup"]
    if wns is not None and wns < 0 and nfail:
        if nfail <= 5 and (tns is None or tns > -1.0):
            add("   READ: few failing endpoints, small TNS -> a PATH problem.")
            add("         One or two localized fixes. 05-timing-closure.md §4 Tier 2.")
        elif wns > -0.5:
            add("   READ: many failing endpoints, modest WNS -> a PATTERN problem")
            add("         (systemic). Fixing the worst path just promotes the next.")
            add("         Look at congestion, fanout, SLR crossings. §4 Tier 1/4.")
        else:
            add("   READ: large WNS -> wrong frequency target or a large")
            add("         combinational blob. Re-architect. §4 Tier 3/5.")
    elif wns is not None and wns >= 0:
        add("   READ: this seed meets timing. ⚠️ One seed is not closure —")
        add("         run scripts/seed_sweep.sh. (06-operations/01 §6)")
    add("")

    add(" UTILIZATION" + (f"  (percentages from {rec['util_pct_source']})"
                          if rec.get("util_pct_source") else ""))
    add(f"   {'resource':<8}{'used':>12}{'%':>10}")
    for key, label in (("lut", "LUT"), ("ff", "FF"), ("bram", "BRAM"),
                       ("uram", "URAM"), ("dsp", "DSP")):
        used = rec.get(key)
        pct = rec.get(f"{key}_pct")
        flag = ""
        if pct is not None and pct > UTIL_ALERT_PCT:
            flag = f"   <-- over {UTIL_ALERT_PCT:.0f}% ⚠️"
        add(f"   {label:<8}{_fmt(used, 12)}{_fmt(pct, 10, 2)}{flag}")
    add("")
    add(" STRUCTURAL")
    add(f"   DRC critical {rec.get('drc_critical')}"
        f"    CDC critical {rec.get('cdc_critical')}"
        f"    congestion {rec.get('congestion_max')}"
        f"    SLR crossings {rec.get('slr_crossings')}")
    add("")
    if rec["alerts"]:
        add(" ⚠️ ALERTS: " + ", ".join(rec["alerts"]))
    else:
        add(" no alerts")
    add("=" * 76)
    return "\n".join(L)


# =============================================================================
# Sweep aggregation
# =============================================================================
# Project closure criterion, verbatim from
# manuals/06-operations/01-build-and-release.md §6.
def sweep_verdict(n_total: int, n_pass: int, spread: float | None) -> tuple[str, bool]:
    if n_total == 0:
        return ("NO DATA — the sweep produced no parseable builds", False)
    frac = n_pass / n_total
    if n_pass == n_total and spread is not None and spread < 0.15:
        return ("CLOSED. Comfortable. (all seeds pass, WNS spread < 0.15 ns)", True)
    if frac >= 14.0 / 16.0:
        return ("CLOSED, but margin is thin — do NOT add logic without re-sweeping.", True)
    if frac >= 8.0 / 16.0:
        return ("NOT CLOSED. Marginal design. Fix the architecture, not the seed.", False)
    return ("NOT CLOSED. Re-architect the failing path.", False)


def collect_sweep(root: str, stage: str) -> list[dict[str, Any]]:
    recs = []
    for d in sorted(glob.glob(os.path.join(root, "s*")),
                    key=lambda p: (len(p), p)):
        if os.path.isdir(d):
            recs.append(collect_build(d, stage))
    return recs


def render_sweep(recs: list[dict[str, Any]]) -> tuple[str, bool]:
    L: list[str] = []
    add = L.append
    wns = [r["wns_ns"] for r in recs if r["wns_ns"] is not None]
    n_total = len(recs)
    n_parsed = len(wns)
    n_pass = sum(1 for r in recs if r.get("timing_closed") is True)
    spread = (max(wns) - min(wns)) if len(wns) >= 2 else None

    add("=" * 76)
    add(f" SEED SWEEP — {n_total} seed(s), {n_parsed} with parseable timing")
    add("=" * 76)
    add(f" {'seed':>5} {'WNS(ns)':>10} {'TNS(ns)':>12} {'fail':>6} "
        f"{'WHS(ns)':>10} {'LUT%':>7} {'cong':>5}  verdict")
    add(" " + "-" * 74)
    for r in recs:
        verdict = "PASS" if r.get("timing_closed") is True else \
                  ("FAIL" if r.get("timing_closed") is False else "?")
        add(f" {str(r.get('seed')):>5} {_fmt(r['wns_ns'])} {_fmt(r['tns_ns'], 12)} "
            f"{str(r['failing_endpoints_setup']):>6} {_fmt(r['whs_ns'])} "
            f"{_fmt(r.get('lut_pct'), 7, 1)} {str(r.get('congestion_max')):>5}  {verdict}")
    add("")
    if wns:
        add(" DISTRIBUTION (report this, never the best seed —")
        add("               manuals/00-foundations/05-timing-closure.md §9)")
        add(f"   pass rate : {n_pass}/{n_total}")
        add(f"   worst WNS : {min(wns):+.3f} ns")
        add(f"   median WNS: {statistics.median(wns):+.3f} ns")
        add(f"   best  WNS : {max(wns):+.3f} ns")
        if spread is not None:
            add(f"   spread    : {spread:.3f} ns")
        if len(wns) >= 2:
            add(f"   stdev     : {statistics.pstdev(wns):.3f} ns")
    add("")
    verdict, ok = sweep_verdict(n_total, n_pass, spread)
    add(f" VERDICT: {verdict}")
    add("")
    add(" ⚠️ A design that closes on 1 of 20 seeds does not close. Pick the")
    add("    release seed FROM this sweep and record it in the manifest;")
    add("    changing it later is a new release, a new build ID, and a new")
    add("    latency measurement. (06-operations/01-build-and-release.md §6)")
    add("=" * 76)
    return "\n".join(L), ok


CSV_COLUMNS = [
    "seed", "wns_ns", "tns_ns", "failing_endpoints_setup",
    "whs_ns", "ths_ns", "failing_endpoints_hold",
    "lut", "lut_pct", "ff", "ff_pct", "bram", "bram_pct",
    "uram", "uram_pct", "dsp", "dsp_pct",
    "congestion_max", "slr_crossings", "drc_critical", "cdc_critical",
    "timing_closed", "git_sha", "tool", "part", "wall_seconds",
]


def write_csv(path: str, recs: list[dict[str, Any]]) -> None:
    import csv
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=CSV_COLUMNS, extrasaction="ignore")
        w.writeheader()
        for r in recs:
            w.writerow(r)


# =============================================================================
def main() -> int:
    ap = argparse.ArgumentParser(
        description="Parse Vivado reports into a one-line JSON QoR record.")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--build", help="a single build directory from scripts/build.tcl")
    g.add_argument("--sweep", help="a sweep root containing s1/, s2/, … subdirectories")
    ap.add_argument("--stage", default="post_route",
                    choices=["post_synth", "post_opt", "post_place", "post_route"],
                    help="which stage's reports to read (default post_route — the "
                         "only stage whose timing means closure)")
    ap.add_argument("--table", action="store_true",
                    help="also print a human-readable table on stderr")
    ap.add_argument("--csv", help="write a CSV (sweep mode: one row per seed)")
    ap.add_argument("--json", help="write the full JSON to a file as well as stdout")
    ap.add_argument("--fail-on-alert", action="store_true",
                    help="exit non-zero if any alert fired (for CI gating)")
    args = ap.parse_args()

    if args.stage != "post_route":
        print("NOTE: --stage %s selected. Timing at this stage is an ESTIMATE and "
              "is optimistic by 20-40%% (05-timing-closure.md §2). timing_closed "
              "will be null." % args.stage, file=sys.stderr)

    if args.build:
        rec = collect_build(args.build, args.stage)
        # THE one line, for `>> qor.jsonl`.
        line = json.dumps(rec, separators=(",", ":"), sort_keys=True)
        print(line)
        if args.json:
            with open(args.json, "w") as fh:
                fh.write(line + "\n")
        if args.csv:
            write_csv(args.csv, [rec])
        if args.table:
            print(render_table(rec), file=sys.stderr)
        if args.fail_on_alert and rec["alerts"]:
            return 1
        return 0

    recs = collect_sweep(args.sweep, args.stage)
    wns = [r["wns_ns"] for r in recs if r["wns_ns"] is not None]
    n_pass = sum(1 for r in recs if r.get("timing_closed") is True)
    spread = (max(wns) - min(wns)) if len(wns) >= 2 else None
    verdict, ok = sweep_verdict(len(recs), n_pass, spread)

    summary = {
        "schema": 1,
        "kind": "seed_sweep",
        "sweep_dir": os.path.relpath(args.sweep),
        "stage": args.stage,
        "n_seeds": len(recs),
        "n_pass": n_pass,
        "pass_rate": round(n_pass / len(recs), 4) if recs else None,
        "wns_worst": min(wns) if wns else None,
        "wns_median": statistics.median(wns) if wns else None,
        "wns_best": max(wns) if wns else None,
        "wns_spread": spread,
        "wns_stdev": statistics.pstdev(wns) if len(wns) >= 2 else None,
        "verdict": verdict,
        "closed": ok,
        "git_sha": recs[0].get("git_sha") if recs else None,
        "tool": recs[0].get("tool") if recs else None,
        "part": recs[0].get("part") if recs else None,
        "seeds": [{"seed": r.get("seed"), "wns_ns": r["wns_ns"],
                   "tns_ns": r["tns_ns"], "whs_ns": r["whs_ns"],
                   "closed": r.get("timing_closed")} for r in recs],
    }
    line = json.dumps(summary, separators=(",", ":"), sort_keys=True)
    print(line)
    if args.json:
        with open(args.json, "w") as fh:
            fh.write(line + "\n")
    if args.csv:
        write_csv(args.csv, recs)
    if args.table:
        text, _ = render_sweep(recs)
        print(text, file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
