#!/usr/bin/env bash
# =============================================================================
# scripts/seed_sweep.sh — run N implementation seeds and report the WNS spread
# -----------------------------------------------------------------------------
# Project : FPGA Algorithmic Trading System (Nasdaq Equities)
# Governs : manuals/06-operations/01-build-and-release.md §6
#           manuals/00-foundations/05-timing-closure.md §8, §9
#
# ###########################################################################
# ##                                                                       ##
# ##   ⚠️  CLOSURE ON ONE LUCKY SEED IS NOT CLOSURE.                        ##
# ##                                                                       ##
# ##   FPGA implementation is a heuristic search, not a deterministic       ##
# ##   compile. Two runs of the same RTL with different placement seeds     ##
# ##   produce different placements, different routing, different WNS —     ##
# ##   and different fast-path latency. A single passing run tells you      ##
# ##   that a passing placement EXISTS, not that the tool will find one     ##
# ##   again after your next RTL change.                                    ##
# ##                                                                       ##
# ##   From manuals/00-foundations/05-timing-closure.md §8:                 ##
# ##     "FPGA implementation is non-deterministic-ish across runs          ##
# ##      (different seeds -> different results), so a 0.05 ns              ##
# ##      'improvement' may be noise. If a change matters, it should be     ##
# ##      visible across multiple seeds. Track WNS across a seed sweep,     ##
# ##      not a single run."                                                ##
# ##                                                                       ##
# ##   And §9:                                                             ##
# ##     "If you ran a seed sweep, report the distribution, not the best    ##
# ##      seed. A design that closes on 1 of 20 seeds does not close."      ##
# ##                                                                       ##
# ##   Reporting the best seed of a sweep as "the" timing result is,        ##
# ##   per 06-operations/01-build-and-release.md §6, "the most common form  ##
# ##   of dishonest FPGA reporting." This script prints the FULL            ##
# ##   distribution and refuses to print a single headline number without   ##
# ##   it.                                                                  ##
# ##                                                                       ##
# ###########################################################################
#
# PROJECT CLOSURE CRITERION (06-operations/01-build-and-release.md §6):
#
#   | Sweep result                                  | Verdict                    |
#   |-----------------------------------------------|----------------------------|
#   | 16/16 meet timing, WNS spread < 0.15 ns       | Closed. Comfortable.       |
#   | >= 14/16 meet timing                          | Closed, margin thin.       |
#   | 8-13/16                                       | NOT closed. Marginal       |
#   |                                               | design — fix the           |
#   |                                               | architecture, not the seed.|
#   | < 8/16                                        | NOT closed. Re-architect.  |
#
#   This script evaluates that table and exits non-zero on "NOT closed", so it
#   can be a nightly CI gate rather than a number somebody eyeballs.
#
# USAGE
#   scripts/seed_sweep.sh [options]
#     -n <count>     number of seeds            (default 16)
#     -j <jobs>      parallel Vivado processes  (default 4)
#     -p <part>      target part                (default xcvu9p-flga2104-2-i)
#     -o <dir>       sweep output root          (default builds/sweep-<UTC>)
#     -s <first>     first seed number          (default 1)
#     -t <threads>   threads per Vivado process (default 4)
#     -k             keep going after a failing seed (default: yes; a failed
#                    seed IS a data point and must appear in the distribution)
#
# ⚠️ RESOURCE WARNING: each Vivado implementation of a VU9P-class design wants
#    ~32-64 GB of RAM. -j 4 with -t 4 is a reasonable default for a 16-core /
#    256 GB build machine. Oversubscribing does not just slow the sweep down —
#    it can OOM-kill runs mid-route and produce phantom "failures" that are
#    really machine failures. Check `free -g` before raising -j.
# =============================================================================

set -o pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
N_SEEDS=16
JOBS=4
PART="xcvu9p-flga2104-2-i"
FIRST_SEED=1
THREADS=4
OUTROOT=""

while getopts "n:j:p:o:s:t:kh" opt; do
  case "$opt" in
    n) N_SEEDS="$OPTARG" ;;
    j) JOBS="$OPTARG" ;;
    p) PART="$OPTARG" ;;
    o) OUTROOT="$OPTARG" ;;
    s) FIRST_SEED="$OPTARG" ;;
    t) THREADS="$OPTARG" ;;
    k) ;;  # accepted for symmetry; keep-going is the only behaviour (see below)
    h) sed -n '1,80p' "$0"; exit 0 ;;
    *) echo "unknown option; try -h" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if [[ -z "$OUTROOT" ]]; then
  OUTROOT="builds/sweep-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$OUTROOT"

GIT_SHA7="$(git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  echo "WARNING: git tree is dirty. build.tcl will refuse each seed unless"
  echo "WARNING: --allow-dirty is passed. A sweep of an uncommitted tree cannot"
  echo "WARNING: be reproduced and must not be used as a closure claim."
fi

command -v vivado >/dev/null 2>&1 || {
  echo "ERROR: vivado not on PATH. Source the pinned settings64.sh first." >&2
  echo "ERROR: The tool version is part of the build inputs" >&2
  echo "ERROR: (manuals/06-operations/01-build-and-release.md §1)." >&2
  exit 1
}

echo "=========================================================================="
echo " SEED SWEEP   n=$N_SEEDS  jobs=$JOBS  part=$PART"
echo " git          $GIT_SHA7"
echo " out          $OUTROOT"
echo " tool         $(vivado -version 2>/dev/null | head -1)"
echo "=========================================================================="

# ── Launch ──────────────────────────────────────────────────────────────────
# ⚠️ A FAILING SEED IS A RESULT, NOT AN ERROR. It is never skipped, retried, or
#    dropped from the summary. "13 of 16 passed" is the finding; hiding the 3 is
#    how a marginal design ships.
run_seed() {
  local seed="$1"
  local dir="$OUTROOT/s${seed}"
  mkdir -p "$dir"
  echo "  [seed $seed] starting -> $dir"
  vivado -mode batch -nojournal -notrace \
         -log "$dir/vivado.log" \
         -source "$REPO_ROOT/scripts/build.tcl" \
         -tclargs --part "$PART" --seed "$seed" --out "$dir" \
                  --threads "$THREADS" --stop-after route \
         >"$dir/stdout.log" 2>&1
  local rc=$?
  echo "  [seed $seed] finished rc=$rc"
  return 0   # never propagate; the summary is built from the manifests
}

pids=()
running=0
for (( s=FIRST_SEED; s<FIRST_SEED+N_SEEDS; s++ )); do
  run_seed "$s" &
  pids+=($!)
  running=$((running+1))
  if (( running >= JOBS )); then
    wait -n 2>/dev/null || wait "${pids[0]}" 2>/dev/null || true
    running=$((running-1))
  fi
done
wait

echo
echo "All seeds finished. Building the distribution."
echo

# ── Summarize ───────────────────────────────────────────────────────────────
# report_qor.py reads each seed's manifest.json + reports and emits per-seed
# JSON; the sweep mode aggregates them into the distribution and applies the
# §6 closure table.
PY=$(command -v python3 || command -v python)
if [[ -z "$PY" ]]; then
  echo "ERROR: python3 not found; cannot summarize. Raw manifests are in $OUTROOT" >&2
  exit 1
fi

"$PY" "$REPO_ROOT/scripts/report_qor.py" \
      --sweep "$OUTROOT" \
      --csv   "$OUTROOT/summary.csv" \
      --json  "$OUTROOT/summary.json" \
      --table
rc=$?

echo
echo "Artifacts:"
echo "  per-seed builds : $OUTROOT/s*/"
echo "  CSV             : $OUTROOT/summary.csv"
echo "  JSON (CI trend) : $OUTROOT/summary.json"
echo
echo "⚠️ When reporting this result, quote the DISTRIBUTION — pass rate, median,"
echo "   worst, and spread — not the best seed. See"
echo "   manuals/00-foundations/05-timing-closure.md §9."
echo
echo "⚠️ Pick the release seed FROM this sweep, record it in the manifest, and"
echo "   never change it silently. Changing it is a new release with a new build"
echo "   ID and a new latency measurement"
echo "   (manuals/06-operations/01-build-and-release.md §6)."

exit $rc
