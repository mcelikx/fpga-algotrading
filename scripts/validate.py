#!/usr/bin/env python3
"""
validate.py — Deliverable validator for the FPGA algorithmic trading project.

Scans the repository and produces a machine-readable validation report covering:

  1. INVENTORY      — every deliverable file, its tier, size, and line count
  2. LINK INTEGRITY — every relative markdown link resolves to a real file
  3. RTL DISCIPLINE — the forbidden-construct rules from CLAUDE.md §4/§5
  4. CONTRACT       — declared modules in fpga_top.sv vs. files that exist
  5. COVERAGE       — RTL modules vs. testbenches that exercise them
  6. REQUIREMENTS   — the user's stated requests vs. what was produced

Output: JSON on stdout, or --html <path> to render the report.

This is a VALIDATOR, not a build. It proves the tree is internally consistent.
It does NOT prove the design is correct — that requires simulation against the
golden model and post-route timing closure. See manuals/06-operations/04-testing-strategy.md.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# ── Tier definitions ─────────────────────────────────────────────────────────
TIERS = {
    "manuals/00-foundations":       ("Manuals · Foundations", "knowledge"),
    "manuals/01-fpga-design":       ("Manuals · FPGA Design", "knowledge"),
    "manuals/02-networking":        ("Manuals · Networking", "knowledge"),
    "manuals/03-algotrading":       ("Manuals · Algotrading", "knowledge"),
    "manuals/04-system-architecture":("Manuals · System Architecture", "knowledge"),
    "manuals/05-optimization":      ("Manuals · Optimization", "knowledge"),
    "manuals/06-operations":        ("Manuals · Operations", "knowledge"),
    "manuals/07-reference":         ("Manuals · Reference", "knowledge"),
    "manuals/08-nasdaq":            ("Manuals · Nasdaq", "knowledge"),
    "manuals/09-deep-dives":        ("Manuals · Deep Dives", "knowledge"),
    "rtl/pkg":                      ("RTL · Packages", "rtl"),
    "rtl/common":                   ("RTL · Common primitives", "rtl"),
    "rtl/eth":                      ("RTL · Ethernet/MAC", "rtl"),
    "rtl/net":                      ("RTL · Network RX", "rtl"),
    "rtl/feed":                     ("RTL · Feed handler", "rtl"),
    "rtl/book":                     ("RTL · Order book", "rtl"),
    "rtl/strategy":                 ("RTL · Strategy engine", "rtl"),
    "rtl/risk":                     ("RTL · Risk gate", "rtl"),
    "rtl/order":                    ("RTL · Order gateway", "rtl"),
    "rtl/ctrl":                     ("RTL · Control plane", "rtl"),
    "rtl/telemetry":                ("RTL · Telemetry", "rtl"),
    "tb":                           ("Verification", "verify"),
    "host":                         ("Host software", "host"),
    "constraints":                  ("Constraints", "build"),
    "scripts":                      ("Build scripts", "build"),
    "docs":                         ("Design docs", "docs"),
}

SKIP_DIRS = {".git", "__pycache__", ".pytest_cache", "node_modules", "build",
             "sim_build", "obj_dir",
             # Third-party clones kept locally for study. Not ours, not our
             # licence, not our coding standard — see docs/REFERENCE-*.md
             "reference"}

# ── Modules the top level declares. The contract check compares against these. ─
def declared_modules(top: Path) -> list[str]:
    """Extract instantiated module names from fpga_top.sv."""
    if not top.exists():
        return []
    text = top.read_text(errors="replace")
    # `module_name #(...) u_inst (`  or  `module_name u_inst (`
    pat = re.compile(r"^\s{4}([a-z][a-z0-9_]{3,})\s+(?:#\s*\(|u_[a-z0-9_]+\s*\()", re.M)
    found = {m.group(1) for m in pat.finditer(text)}
    found -= {"logic", "always_ff", "always_comb", "assign", "generate", "endgenerate",
              "parameter", "localparam", "typedef", "import", "assert", "property"}
    return sorted(found)


# ── Data model ───────────────────────────────────────────────────────────────
@dataclass
class Finding:
    severity: str          # "error" | "warn" | "info"
    category: str
    location: str
    message: str


@dataclass
class Report:
    inventory: dict = field(default_factory=dict)
    totals: dict = field(default_factory=dict)
    findings: list = field(default_factory=list)
    contract: dict = field(default_factory=dict)
    coverage: dict = field(default_factory=dict)
    requirements: list = field(default_factory=list)


# ── 1. Inventory ─────────────────────────────────────────────────────────────
def tier_of(rel: Path) -> tuple[str, str]:
    s = str(rel)
    best = ""
    for prefix in TIERS:
        if s.startswith(prefix + "/") or s == prefix:
            if len(prefix) > len(best):
                best = prefix
    if best:
        return TIERS[best]
    return ("Root", "root")


def walk_files() -> list[Path]:
    out = []
    for p in ROOT.rglob("*"):
        if not p.is_file():
            continue
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        if p.suffix.lower() in {".png", ".jpg", ".pdf", ".pcap", ".bit", ".pyc"}:
            continue
        out.append(p)
    return sorted(out)


def build_inventory(files: list[Path], rep: Report) -> None:
    inv: dict[str, dict] = {}
    for p in files:
        rel = p.relative_to(ROOT)
        label, kind = tier_of(rel)
        try:
            lines = len(p.read_text(errors="replace").splitlines())
        except Exception:
            lines = 0
        entry = inv.setdefault(label, {"kind": kind, "files": [], "lines": 0})
        entry["files"].append({"path": str(rel), "lines": lines,
                               "bytes": p.stat().st_size})
        entry["lines"] += lines

    rep.inventory = inv
    rep.totals = {
        "files": sum(len(v["files"]) for v in inv.values()),
        "lines": sum(v["lines"] for v in inv.values()),
        "tiers": len(inv),
    }


# ── 2. Link integrity ────────────────────────────────────────────────────────
LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")


def check_links(files: list[Path], rep: Report) -> None:
    checked = broken = 0
    for p in files:
        if p.suffix != ".md":
            continue
        rel = p.relative_to(ROOT)
        for m in LINK_RE.finditer(p.read_text(errors="replace")):
            target = m.group(1).split("#")[0].strip()
            if not target or target.startswith(("http://", "https://", "mailto:")):
                continue
            checked += 1
            resolved = (p.parent / target).resolve()
            if not resolved.exists():
                broken += 1
                rep.findings.append(asdict(Finding(
                    "error", "broken-link", str(rel),
                    f"link target does not exist: {target}")))
    rep.totals["links_checked"] = checked
    rep.totals["links_broken"] = broken


# ── 3. RTL discipline (CLAUDE.md §4 / §5) ────────────────────────────────────
RTL_RULES = [
    # (rule-name, regex, severity, message)
    # rule-name is what an author writes in `// validate: allow <name> — why`
    ("bare-always", re.compile(r"^\s*always\s*@"), "error",
     "bare `always` — use always_ff or always_comb (manuals/00-foundations/03 §2)"),
    ("reg-decl", re.compile(r"^\s*(?:input|output|inout)?\s*\breg\b\s"), "error",
     "`reg` declaration — use `logic` (manuals/00-foundations/03 §4)"),
    ("real", re.compile(r"\breal\b|\bshortreal\b"), "error",
     "floating point type — fast path is fixed-point only (CLAUDE.md §5.3)"),
    ("divide", re.compile(r"[^/*]\s/\s(?!/)"), "warn",
     "possible division — no dividers on the fast path (manuals/00-foundations/03 §7)"),
    ("modulo", re.compile(r"\s%\s"), "warn",
     "possible modulo — no dividers on the fast path (manuals/00-foundations/03 §7)"),
]

REQUIRED_HEADER_TOKENS = ["LATENCY", "manual"]


def _strip_comments(text: str) -> str:
    """Blank out comments while preserving offsets and line count.

    Required before any structural scan of HDL. Prose inside comments contains
    keywords — "end of frame", "in the default case" — and a scanner that counts
    `begin`/`end` depth over raw text will silently mis-parse the block, then
    report a violation in code that is perfectly correct.
    """
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        elif text[i] in "\"":
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            for k in range(i, min(j + 1, n)):
                out[k] = " "
            i = j + 1
        else:
            i += 1
    return "".join(out)


def _synthesis_excluded(lines: list[str]) -> list[bool]:
    """Mark lines sitting inside an `ifndef SYNTHESIS` / `ifdef SIMULATION` block.

    Code that never reaches synthesis is not bound by the synthesizable-subset
    rules. A concurrent assertion on a purely combinational module, for example,
    legitimately needs a bare `always` because there is no clock to attach to.
    """
    out, depth, sim_depth = [], 0, 0
    for line in lines:
        s = line.strip()
        if re.match(r"`(ifndef\s+SYNTHESIS|ifdef\s+SIMULATION)\b", s):
            sim_depth += 1
            depth += 1
        elif re.match(r"`if(n?def)\b", s):
            depth += 1
        elif re.match(r"`endif\b", s):
            if sim_depth and depth == sim_depth:
                sim_depth -= 1
            depth = max(0, depth - 1)
        out.append(sim_depth > 0)
    return out


# An author may suppress a rule on a line, or file-wide in the header, with
#   // validate: allow <rule> — <justification>
# The justification is mandatory: a suppression without a stated reason is
# itself reported, so silencing a check always leaves an auditable trace.
SUPPRESS_RE = re.compile(r"//\s*validate:\s*allow\s+([a-z-]+)\s*(?:[—-]\s*(.+))?$")


def check_rtl(files: list[Path], rep: Report) -> None:
    modules = latch_risk = 0
    for p in files:
        if p.suffix != ".sv":
            continue
        rel = p.relative_to(ROOT)
        text = p.read_text(errors="replace")
        lines = text.splitlines()
        is_pkg = "/pkg/" in str(rel) or rel.name.endswith("_pkg.sv")
        sim_only = _synthesis_excluded(lines)
        if re.search(r"^\s*module\s", text, re.M):
            modules += 1

        # File-wide suppressions declared in the first 60 lines.
        file_allow: set[str] = set()
        for line in lines[:60]:
            m = SUPPRESS_RE.search(line)
            if m:
                if not (m.group(2) or "").strip():
                    rep.findings.append(asdict(Finding(
                        "warn", "suppression", str(rel),
                        f"`validate: allow {m.group(1)}` with no justification — "
                        "state why, so the exemption is auditable")))
                file_allow.add(m.group(1))

        for i, line in enumerate(lines, 1):
            if sim_only[i - 1]:
                continue                      # not synthesized, rules do not apply
            stripped = line.split("//")[0]
            if not stripped.strip():
                continue
            local = SUPPRESS_RE.search(line)
            allow = set(file_allow) | ({local.group(1)} if local else set())
            for rule, rx, sev, msg in RTL_RULES:
                if rule in allow:
                    continue
                # div/mod warnings are noisy in packages doing elaboration math
                if sev == "warn" and is_pkg:
                    continue
                # `real` is legitimate on localparams feeding a vendor primitive
                # that declares them `real` (MMCM/PLL). Only flag it on signals.
                if rule == "real" and re.match(r"\s*(local)?param(eter)?\s+real\s", stripped):
                    continue
                if rx.search(stripped):
                    rep.findings.append(asdict(Finding(
                        sev, "rtl-discipline", f"{rel}:{i}", msg)))

        # always_comb containing a `case` with no `default` is the latch trap.
        # Scan by begin/end depth rather than a fixed character window — a short
        # window truncates long bodies and reports a `default` that is really
        # there, which is worse than not checking at all.
        code = _strip_comments(text)
        for m in re.finditer(r"\balways_comb\b", code):
            if sim_only[code[:m.start()].count("\n")]:
                continue
            depth, i, n, body = 0, m.end(), len(code), []
            started = False
            while i < n:
                word = re.match(r"\b(begin|endcase|end|case[xz]?)\b", code[i:])
                if word:
                    w = word.group(1)
                    if w == "begin":
                        depth += 1
                        started = True
                    elif w == "end":
                        depth -= 1
                        if started and depth <= 0:
                            break
                    i += len(w)
                    body.append(w)
                    continue
                if not started and code[i] == ";":
                    break                     # single-statement always_comb
                body.append(code[i])
                i += 1
            blob = "".join(body)
            if re.search(r"\bcase[xz]?\b", blob) and not re.search(r"\bdefault\b", blob):
                latch_risk += 1
                ln = code[:m.start()].count("\n") + 1
                rep.findings.append(asdict(Finding(
                    "error", "latch-risk", f"{rel}:{ln}",
                    "always_comb contains a `case` with no `default` — latch inference "
                    "(manuals/00-foundations/03 §3)")))

        # header discipline
        if not is_pkg and re.search(r"^\s*module\s", text, re.M):
            head = "\n".join(lines[:40])
            for tok in REQUIRED_HEADER_TOKENS:
                if tok.lower() not in head.lower():
                    rep.findings.append(asdict(Finding(
                        "warn", "header", str(rel),
                        f"module header missing `{tok}` (CLAUDE.md §4)")))

        # `default_nettype discipline
        if re.search(r"^\s*module\s", text, re.M) and "`default_nettype none" not in text:
            rep.findings.append(asdict(Finding(
                "warn", "style", str(rel),
                "missing `` `default_nettype none `` guard")))

    rep.totals["rtl_modules"] = modules
    rep.totals["latch_risks"] = latch_risk


# ── 4. Contract: does every module fpga_top instantiates exist? ──────────────
def check_contract(rep: Report) -> None:
    top = ROOT / "rtl" / "fpga_top.sv"
    declared = declared_modules(top)
    present, missing = [], []
    for mod in declared:
        hits = list((ROOT / "rtl").rglob(f"{mod}.sv"))
        (present if hits else missing).append(mod)
    for mod in missing:
        rep.findings.append(asdict(Finding(
            "error", "contract", "rtl/fpga_top.sv",
            f"instantiates `{mod}` but rtl/**/{mod}.sv does not exist")))
    rep.contract = {
        "declared": declared,
        "present": present,
        "missing": missing,
        "complete_pct": round(100 * len(present) / len(declared), 1) if declared else 0.0,
    }


# ── 5. Coverage: RTL modules vs testbenches ──────────────────────────────────
def check_coverage(rep: Report) -> None:
    rtl_mods = {}
    for p in (ROOT / "rtl").rglob("*.sv"):
        if p.name.endswith("_pkg.sv"):
            continue
        rtl_mods[p.stem] = str(p.relative_to(ROOT))

    tb_text = ""
    tb_dir = ROOT / "tb"
    if tb_dir.exists():
        for p in tb_dir.rglob("*.py"):
            tb_text += p.read_text(errors="replace")

    covered = {m: path for m, path in rtl_mods.items() if m in tb_text}
    uncovered = {m: path for m, path in rtl_mods.items() if m not in tb_text}

    for m, path in uncovered.items():
        rep.findings.append(asdict(Finding(
            "warn", "coverage", path,
            f"no testbench references `{m}` — CLAUDE.md §4 requires a testbench "
            "for every fast-path module")))

    rep.coverage = {
        "rtl_modules": len(rtl_mods),
        "covered": sorted(covered),
        "uncovered": sorted(uncovered),
        "pct": round(100 * len(covered) / len(rtl_mods), 1) if rtl_mods else 0.0,
    }


# ── 5b. Mirror consistency ───────────────────────────────────────────────────
# The host software and the testbenches hand-copy geometry constants out of
# trading_pkg.sv. When BOOK_LEVELS went 16 -> 2048, FIVE files kept the old
# value and nothing complained — a golden-model comparison against a 16-level
# software book and a 2048-level hardware book would have "passed" while
# comparing two different machines. That is the worst kind of test: one that
# reports success for a reason unrelated to correctness.
MIRRORED = ["BOOK_LEVELS", "N_ACTIVE", "N_SYMBOLS", "ORDER_MAP_ENTRIES", "TOKEN_W"]

MIRROR_FILES = [
    "host/include/trading/types.hpp",
    "host/pymodel/trading_pkg_mirror.py",
    "tb/common/tb_util.py",
]


def check_mirrors(rep: Report) -> None:
    pkg = ROOT / "rtl" / "pkg" / "trading_pkg.sv"
    if not pkg.exists():
        return
    text = pkg.read_text(errors="replace")

    def as_int(expr: str) -> int | None:
        """Evaluate the small set of constant forms these files actually use.

        Both sides write `1 << 16` as often as `65536`, and a naive `(\\d+)`
        capture reads that as 1 — which produced three confident false
        mismatches on first run. A checker that misreads the code it checks is
        worse than no checker, so parse the shift form explicitly rather than
        grabbing the first digits and hoping.
        """
        e = expr.strip().rstrip(";").strip()
        e = re.sub(r"\b(\d+)[uU]\b", r"\1", e)          # C++ `1u`
        m_shift = re.fullmatch(r"(\d+)\s*<<\s*(\d+)", e)
        if m_shift:
            return int(m_shift.group(1)) << int(m_shift.group(2))
        if re.fullmatch(r"\d+", e):
            return int(e)
        return None                                      # anything else: skip

    truth: dict[str, int] = {}
    for name in MIRRORED:
        m = re.search(rf"parameter\s+int\s+unsigned\s+{name}\s*=\s*([^;]+);", text)
        if m:
            v = as_int(m.group(1))
            if v is not None:
                truth[name] = v

    checked = mismatched = 0
    for rel in MIRROR_FILES:
        p = ROOT / rel
        if not p.exists():
            continue
        body = p.read_text(errors="replace")
        for name, want in truth.items():
            # Capture the whole right-hand side, then evaluate it the same way
            # as the RTL side — never compare a parsed value against a raw one.
            m = re.search(rf"^[^\n#/]*\b{name}\b\s*(?::\s*\w+\s*)?=\s*([^;\n#]+)",
                          body, re.M)
            if not m:
                continue
            got = as_int(m.group(1))
            if got is None:
                continue
            checked += 1
            if got != want:
                mismatched += 1
                rep.findings.append(asdict(Finding(
                    "error", "mirror-drift", rel,
                    f"{name} = {got} but rtl/pkg/trading_pkg.sv says {want} — "
                    "a mirror that disagrees with the RTL makes every comparison "
                    "against it meaningless")))

    rep.totals["mirrors_checked"] = checked
    rep.totals["mirrors_mismatched"] = mismatched


# ── 6. Requirements traceability ─────────────────────────────────────────────
# Each entry: (requirement as the user stated it, list of glob patterns that
# satisfy it, minimum count to consider it met).
REQUIREMENTS = [
    ("Create a CLAUDE.md file", ["CLAUDE.md"], 1),
    ("Create a manuals folder", ["manuals/README.md"], 1),
    ("Manuals cover main FPGA concepts, hierarchically",
     ["manuals/00-foundations/*.md", "manuals/01-fpga-design/*.md",
      "manuals/02-networking/*.md"], 12),
    ("Manuals cover main Algotrading concepts, hierarchically",
     ["manuals/03-algotrading/*.md", "manuals/04-system-architecture/*.md"], 10),
    ("Optimization guidance for the trading system",
     ["manuals/05-optimization/*.md"], 5),
    ("Operations and reference tiers",
     ["manuals/06-operations/*.md", "manuals/07-reference/*.md"], 6),
    ("Task list for full FPGA-driven algotrading", ["TASKS.md"], 1),
    ("Detailed manuals on Nasdaq algotrading rules",
     ["manuals/08-nasdaq/*.md"], 9),
    ("FPGA top module code", ["rtl/fpga_top.sv"], 1),
    ("Shared type/interface contract", ["rtl/pkg/*.sv"], 2),
    ("Remaining RTL — common primitives", ["rtl/common/*.sv"], 10),
    ("Remaining RTL — Ethernet/MAC", ["rtl/eth/*.sv"], 4),
    ("Remaining RTL — network RX", ["rtl/net/*.sv"], 4),
    ("Remaining RTL — feed handler", ["rtl/feed/*.sv"], 4),
    ("Remaining RTL — order book", ["rtl/book/*.sv"], 4),
    ("Remaining RTL — strategy engine", ["rtl/strategy/*.sv"], 5),
    ("Remaining RTL — risk gate and kill switch", ["rtl/risk/*.sv"], 5),
    ("Remaining RTL — order gateway", ["rtl/order/*.sv"], 6),
    ("Remaining RTL — control plane and telemetry",
     ["rtl/ctrl/*.sv", "rtl/telemetry/*.sv"], 6),
    ("Constraints and build flow", ["constraints/*.xdc", "scripts/*"], 8),
    ("Verification scaffolding and testbenches", ["tb/**/*.py"], 10),
    ("Host slow-path software", ["host/**/*"], 5),
    ("Design decision records", ["docs/**/*.md"], 5),
    ("Deep-dive manual tier", ["manuals/09-deep-dives/*.md"], 10),
]


def check_requirements(rep: Report) -> None:
    for name, patterns, minimum in REQUIREMENTS:
        hits = []
        for pat in patterns:
            hits.extend(sorted(str(p.relative_to(ROOT))
                               for p in ROOT.glob(pat) if p.is_file()))
        n = len(hits)
        if n >= minimum:
            status = "met"
        elif n > 0:
            status = "partial"
        else:
            status = "missing"
        rep.requirements.append({
            "requirement": name,
            "patterns": patterns,
            "found": n,
            "required": minimum,
            "status": status,
            "examples": hits[:6],
        })


# ── HTML rendering ───────────────────────────────────────────────────────────
def render_html(rep) -> str:
    """Delegates to scripts/_report_html.py so the renderer stays readable."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import _report_html
    return _report_html.render(rep)


# ── main ─────────────────────────────────────────────────────────────────────
def main(argv: list[str]) -> int:
    rep = Report()
    files = walk_files()
    build_inventory(files, rep)
    check_links(files, rep)
    check_rtl(files, rep)
    check_contract(rep)
    check_coverage(rep)
    check_mirrors(rep)
    check_requirements(rep)

    if "--html" in argv:
        out = Path(argv[argv.index("--html") + 1])
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(render_html(rep))
        print(f"wrote {out}", file=sys.stderr)

    if "--quiet" not in argv:
        print(json.dumps(asdict(rep), indent=2))

    # CI gates on structural defects. Broken links to manual tiers that are
    # knowingly incomplete are tracked but must not block a build — pass
    # `--ignore-category broken-link` to separate the two.
    ignored: set[str] = set()
    while "--ignore-category" in argv:
        i = argv.index("--ignore-category")
        ignored.add(argv[i + 1])
        del argv[i:i + 2]

    errors = [f for f in rep.findings
              if f["severity"] == "error" and f["category"] not in ignored]
    if errors:
        print(f"\n{len(errors)} blocking finding(s):", file=sys.stderr)
        for f in errors[:20]:
            print(f"  {f['category']}: {f['location']} — {f['message']}",
                  file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
