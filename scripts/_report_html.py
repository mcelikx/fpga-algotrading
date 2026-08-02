"""
_report_html.py — HTML renderer for the deliverable validation report.

Visual identity: a measurement instrument, not a document. The subject is a
system whose entire purpose is measuring nanoseconds, so the report reads like
the front panel of a piece of test equipment — monospace as the display face,
a single scope-trace teal as the accent, and semantic pass/warn/fail kept
separate from that accent so state reads at a glance without competing with it.

Imported by validate.py. No external assets — the page is fully self-contained.
"""

from __future__ import annotations

from html import escape
from collections import Counter

SEV_RANK = {"error": 0, "warn": 1, "info": 2}
SEV_CLASS = {"error": "fail", "warn": "warn", "info": "info"}

CATEGORY_LABEL = {
    "broken-link": "Cross-reference integrity",
    "contract": "Top-level module contract",
    "rtl-discipline": "RTL coding rules",
    "latch-risk": "Latch inference risk",
    "header": "Module header discipline",
    "style": "Style guards",
    "coverage": "Testbench coverage",
}

CSS = """
:root {
  --ground:#F7F8F9; --surface:#FFFFFF; --raise:#FDFDFE;
  --line:#E2E6EA; --line-soft:#EDF0F3;
  --ink:#171D22; --ink-2:#3D4952; --muted:#69767F;
  --accent:#0C6F79; --accent-soft:#E3F1F2;
  --pass:#1C7A4C; --pass-soft:#E4F2EA;
  --warn:#8A6210; --warn-soft:#FAF0DC;
  --fail:#9E2C2C; --fail-soft:#FAE9E9;
  --track:#E7EBEE;
  --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
  --sans: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
}
@media (prefers-color-scheme: dark) {
  :root {
    --ground:#0F1317; --surface:#161B21; --raise:#1B2129;
    --line:#252D35; --line-soft:#1E252C;
    --ink:#E2E8ED; --ink-2:#B4C0C9; --muted:#7E8C97;
    --accent:#4FCBD6; --accent-soft:#102B2E;
    --pass:#4FD394; --pass-soft:#0F2A1E;
    --warn:#E4B45C; --warn-soft:#2C2313;
    --fail:#F08A8A; --fail-soft:#2E1919;
    --track:#232B33;
  }
}
:root[data-theme="dark"] {
  --ground:#0F1317; --surface:#161B21; --raise:#1B2129;
  --line:#252D35; --line-soft:#1E252C;
  --ink:#E2E8ED; --ink-2:#B4C0C9; --muted:#7E8C97;
  --accent:#4FCBD6; --accent-soft:#102B2E;
  --pass:#4FD394; --pass-soft:#0F2A1E;
  --warn:#E4B45C; --warn-soft:#2C2313;
  --fail:#F08A8A; --fail-soft:#2E1919;
  --track:#232B33;
}
:root[data-theme="light"] {
  --ground:#F7F8F9; --surface:#FFFFFF; --raise:#FDFDFE;
  --line:#E2E6EA; --line-soft:#EDF0F3;
  --ink:#171D22; --ink-2:#3D4952; --muted:#69767F;
  --accent:#0C6F79; --accent-soft:#E3F1F2;
  --pass:#1C7A4C; --pass-soft:#E4F2EA;
  --warn:#8A6210; --warn-soft:#FAF0DC;
  --fail:#9E2C2C; --fail-soft:#FAE9E9;
  --track:#E7EBEE;
}

* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin:0; background:var(--ground); color:var(--ink);
  font-family:var(--sans); font-size:15px; line-height:1.6;
  -webkit-font-smoothing:antialiased;
  font-variant-numeric: tabular-nums;
}
.wrap { max-width:1120px; margin:0 auto; padding:40px 22px 88px; }

/* ── masthead ─────────────────────────────────────────────── */
.masthead { display:flex; flex-wrap:wrap; align-items:flex-end; gap:20px 32px;
            padding-bottom:22px; border-bottom:2px solid var(--ink); }
.masthead h1 { margin:0; font-size:23px; font-weight:640; letter-spacing:-.015em; text-wrap:balance; }
.eyebrow { font-family:var(--mono); font-size:11px; letter-spacing:.16em;
           text-transform:uppercase; color:var(--accent); margin:0 0 7px; font-weight:600; }
.masthead .meta { margin-left:auto; font-family:var(--mono); font-size:11.5px;
                  color:var(--muted); text-align:right; line-height:1.75; }

/* ── verdict strip ────────────────────────────────────────── */
.verdict { display:flex; align-items:center; gap:14px; margin:22px 0 4px;
           padding:15px 20px; border-radius:3px; border:1px solid var(--line);
           background:var(--surface); border-left:4px solid var(--accent); }
.verdict.is-fail { border-left-color:var(--fail); }
.verdict.is-warn { border-left-color:var(--warn); }
.verdict .lamp { width:9px; height:9px; border-radius:50%; background:var(--accent); flex:none; }
.verdict.is-fail .lamp { background:var(--fail); }
.verdict.is-warn .lamp { background:var(--warn); }
.verdict .txt { font-size:14.5px; color:var(--ink-2); }
.verdict .txt b { color:var(--ink); font-weight:640; }

/* ── readouts ─────────────────────────────────────────────── */
.readouts { display:grid; grid-template-columns:repeat(auto-fit,minmax(138px,1fr));
            gap:1px; background:var(--line); border:1px solid var(--line);
            border-radius:3px; overflow:hidden; margin:18px 0 6px; }
.ro { background:var(--surface); padding:14px 16px 15px; }
.ro .k { font-family:var(--mono); font-size:10.5px; letter-spacing:.11em;
         text-transform:uppercase; color:var(--muted); }
.ro .v { font-family:var(--mono); font-size:25px; font-weight:600;
         letter-spacing:-.02em; margin-top:5px; line-height:1.1; }
.ro .u { font-size:12px; color:var(--muted); font-weight:400; margin-left:2px; }
.ro.pass .v { color:var(--pass); } .ro.warn .v { color:var(--warn); } .ro.fail .v { color:var(--fail); }

/* ── sections ─────────────────────────────────────────────── */
section { margin-top:44px; }
.shead { display:flex; align-items:baseline; gap:12px; flex-wrap:wrap;
         padding-bottom:9px; margin-bottom:14px; border-bottom:1px solid var(--line); }
.shead h2 { margin:0; font-size:16.5px; font-weight:620; letter-spacing:-.01em; }
.shead .desc { color:var(--muted); font-size:13.5px; margin-left:auto; text-align:right; }
.lede { color:var(--ink-2); font-size:14px; margin:0 0 14px; max-width:66ch; }

/* ── chips ────────────────────────────────────────────────── */
.chip { display:inline-block; font-family:var(--mono); font-size:10.5px; font-weight:670;
        letter-spacing:.08em; padding:2.5px 8px; border-radius:2px; white-space:nowrap;
        text-transform:uppercase; }
.chip.pass { background:var(--pass-soft); color:var(--pass); }
.chip.warn { background:var(--warn-soft); color:var(--warn); }
.chip.fail { background:var(--fail-soft); color:var(--fail); }
.chip.info { background:var(--accent-soft); color:var(--accent); }

/* ── tables ───────────────────────────────────────────────── */
.scroll { overflow-x:auto; border:1px solid var(--line); border-radius:3px; background:var(--surface); }
table { border-collapse:collapse; width:100%; font-size:13.5px; min-width:560px; }
th, td { text-align:left; padding:9px 14px; border-bottom:1px solid var(--line-soft); vertical-align:top; }
thead th { font-family:var(--mono); font-size:10.5px; letter-spacing:.1em; text-transform:uppercase;
           color:var(--muted); font-weight:600; background:var(--raise);
           border-bottom:1px solid var(--line); position:sticky; top:0; z-index:1; }
tbody tr:last-child td { border-bottom:none; }
tbody tr:hover { background:var(--raise); }
td.n { text-align:right; white-space:nowrap; font-family:var(--mono); font-size:12.5px; }
td.mono, .mono { font-family:var(--mono); }
td.dim { color:var(--muted); font-size:12px; }
.empty { color:var(--muted); text-align:center; padding:26px; font-size:13.5px; }

/* severity stripe on finding rows */
tr.sev td:first-child { border-left:3px solid transparent; }
tr.sev-error td:first-child { border-left-color:var(--fail); }
tr.sev-warn  td:first-child { border-left-color:var(--warn); }
tr.sev-info  td:first-child { border-left-color:var(--muted); }

/* ── meters ───────────────────────────────────────────────── */
.meter { display:block; height:5px; background:var(--track); border-radius:2px;
         min-width:70px; overflow:hidden; }
.meter i { display:block; height:5px; background:var(--accent); border-radius:2px; }
.meter.pass i { background:var(--pass); } .meter.warn i { background:var(--warn); }
.meter.fail i { background:var(--fail); }

.gauges { display:grid; grid-template-columns:repeat(auto-fit,minmax(260px,1fr)); gap:14px; }
.gauge { border:1px solid var(--line); border-radius:3px; background:var(--surface); padding:16px 18px; }
.gauge .k { font-family:var(--mono); font-size:10.5px; letter-spacing:.11em;
            text-transform:uppercase; color:var(--muted); }
.gauge .v { font-family:var(--mono); font-size:27px; font-weight:600; letter-spacing:-.02em;
            margin:6px 0 10px; line-height:1; }
.gauge.pass .v { color:var(--pass); } .gauge.warn .v { color:var(--warn); } .gauge.fail .v { color:var(--fail); }
.gauge .note { font-size:12.5px; color:var(--muted); margin-top:9px; line-height:1.55; }

code { font-family:var(--mono); font-size:12px; background:var(--raise);
       border:1px solid var(--line); border-radius:2px; padding:1px 5px; color:var(--ink-2); }

/* ── callout ──────────────────────────────────────────────── */
.callout { border:1px solid var(--line); border-left:3px solid var(--accent);
           background:var(--surface); border-radius:0 3px 3px 0; padding:15px 20px;
           margin:20px 0 0; font-size:14px; color:var(--ink-2); }
.callout b { color:var(--ink); font-weight:640; }
.callout p { margin:0; }
.callout p + p { margin-top:9px; }

footer { margin-top:52px; padding-top:18px; border-top:1px solid var(--line);
         color:var(--muted); font-size:12.5px; font-family:var(--mono); line-height:1.8; }

@media (max-width:640px) {
  .masthead .meta { margin-left:0; text-align:left; }
  .shead .desc { margin-left:0; text-align:left; width:100%; }
}
@media (prefers-reduced-motion: reduce) { * { transition:none !important; animation:none !important; } }
"""


def _chip(kind: str, text: str) -> str:
    return f'<span class="chip {kind}">{escape(text)}</span>'


def _meter(pct: float, kind: str = "") -> str:
    pct = max(0.0, min(100.0, pct))
    cls = f"meter {kind}".strip()
    return f'<span class="{cls}"><i style="width:{pct:.4g}%"></i></span>'


def render(rep) -> str:
    findings = sorted(
        rep.findings,
        key=lambda f: (SEV_RANK.get(f["severity"], 3), f["category"], f["location"]),
    )
    n_err = sum(1 for f in findings if f["severity"] == "error")
    n_warn = sum(1 for f in findings if f["severity"] == "warn")

    reqs = rep.requirements
    r_met = sum(1 for r in reqs if r["status"] == "met")
    r_part = sum(1 for r in reqs if r["status"] == "partial")
    r_miss = sum(1 for r in reqs if r["status"] == "missing")
    r_pct = round(100 * r_met / len(reqs), 1) if reqs else 0.0

    t = rep.totals
    contract = rep.contract
    cov = rep.coverage

    # ── verdict ───────────────────────────────────────────────
    if r_miss == 0 and n_err == 0:
        v_cls, v_txt = "", (
            "<b>All requirements met and no blocking findings.</b> "
            "The tree is internally consistent — every instantiated module exists, "
            "every cross-reference resolves, and the RTL obeys the project coding rules."
        )
    elif r_miss or n_err:
        v_cls = "is-fail"
        v_txt = (
            f"<b>{n_err} blocking finding{'s' if n_err != 1 else ''} "
            f"and {r_miss} unmet requirement{'s' if r_miss != 1 else ''}.</b> "
            "Work is still landing — sections below show exactly which artifacts are "
            "outstanding and which references do not yet resolve."
        )
    else:
        v_cls = "is-warn"
        v_txt = f"<b>{n_warn} advisory finding{'s' if n_warn != 1 else ''}, nothing blocking.</b>"

    # ── requirements table ────────────────────────────────────
    req_rows = []
    for r in reqs:
        kind = {"met": "pass", "partial": "warn", "missing": "fail"}[r["status"]]
        label = {"met": "met", "partial": "partial", "missing": "missing"}[r["status"]]
        pct = 100 * r["found"] / r["required"] if r["required"] else 0
        ex = escape(", ".join(r["examples"][:2])) if r["examples"] else "—"
        req_rows.append(
            f'<tr><td>{escape(r["requirement"])}</td>'
            f'<td class="n">{r["found"]}<span style="color:var(--muted)">/{r["required"]}</span></td>'
            f'<td style="width:110px">{_meter(pct, kind)}</td>'
            f'<td>{_chip(kind, label)}</td>'
            f'<td class="dim mono">{ex}</td></tr>'
        )

    # ── inventory table ───────────────────────────────────────
    inv = sorted(rep.inventory.items(), key=lambda kv: -kv[1]["lines"])
    max_lines = max((v["lines"] for _, v in inv), default=1) or 1
    inv_rows = [
        f'<tr><td>{escape(label)}</td>'
        f'<td class="n">{len(v["files"])}</td>'
        f'<td class="n">{v["lines"]:,}</td>'
        f'<td style="width:190px">{_meter(100 * v["lines"] / max_lines)}</td></tr>'
        for label, v in inv
    ]

    # ── findings ──────────────────────────────────────────────
    cat_counts = Counter(f["category"] for f in findings)
    cat_rows = [
        f'<tr><td>{escape(CATEGORY_LABEL.get(c, c))}</td>'
        f'<td class="mono dim">{escape(c)}</td>'
        f'<td class="n">{n}</td></tr>'
        for c, n in cat_counts.most_common()
    ] or ['<tr><td colspan="3" class="empty">No findings.</td></tr>']

    LIMIT = 250
    if findings:
        find_rows = [
            f'<tr class="sev sev-{f["severity"]}">'
            f'<td>{_chip(SEV_CLASS.get(f["severity"], "info"), f["severity"])}</td>'
            f'<td class="mono dim">{escape(f["category"])}</td>'
            f'<td class="mono" style="font-size:12px">{escape(f["location"])}</td>'
            f'<td>{escape(f["message"])}</td></tr>'
            for f in findings[:LIMIT]
        ]
        overflow = (
            "" if len(findings) <= LIMIT
            else f'<p class="lede" style="margin-top:10px">Showing the first {LIMIT} '
                 f'of {len(findings):,} findings, most severe first.</p>'
        )
    else:
        find_rows = ['<tr><td colspan="4" class="empty">No findings.</td></tr>']
        overflow = ""

    # ── gauges ────────────────────────────────────────────────
    c_pct = contract.get("complete_pct", 0.0)
    c_kind = "pass" if c_pct >= 100 else "warn" if c_pct >= 50 else "fail"
    missing = contract.get("missing", [])
    missing_txt = (
        " ".join(f"<code>{escape(m)}</code>" for m in missing[:12])
        + (f" <span style='color:var(--muted)'>+{len(missing)-12} more</span>" if len(missing) > 12 else "")
    ) if missing else "Every instantiated module has a file."

    v_pct = cov.get("pct", 0.0)
    v_kind = "pass" if v_pct >= 90 else "warn" if v_pct >= 40 else "fail"
    unc = cov.get("uncovered", [])
    unc_txt = (
        " ".join(f"<code>{escape(m)}</code>" for m in unc[:12])
        + (f" <span style='color:var(--muted)'>+{len(unc)-12} more</span>" if len(unc) > 12 else "")
    ) if unc else "Every RTL module is referenced by a testbench."

    link_broken = t.get("links_broken", 0)
    link_total = t.get("links_checked", 0)
    l_pct = 100 * (link_total - link_broken) / link_total if link_total else 100.0
    l_kind = "pass" if link_broken == 0 else "warn" if l_pct > 90 else "fail"

    # ── assemble ──────────────────────────────────────────────
    return f"""<title>Deliverable Validation — FPGA Algotrading System</title>
<style>{CSS}</style>
<div class="wrap">

<div class="masthead">
  <div>
    <p class="eyebrow">Validation Report</p>
    <h1>FPGA Algorithmic Trading System &middot; Nasdaq Equities</h1>
  </div>
  <div class="meta">
    generated by scripts/validate.py<br>
    {t.get('files', 0):,} files &middot; {t.get('lines', 0):,} lines &middot; {t.get('tiers', 0)} tiers
  </div>
</div>

<div class="verdict {v_cls}"><span class="lamp"></span><span class="txt">{v_txt}</span></div>

<div class="readouts">
  <div class="ro"><div class="k">Deliverables</div><div class="v">{t.get('files',0):,}<span class="u">files</span></div></div>
  <div class="ro"><div class="k">Written</div><div class="v">{t.get('lines',0):,}<span class="u">lines</span></div></div>
  <div class="ro"><div class="k">RTL modules</div><div class="v">{t.get('rtl_modules',0)}</div></div>
  <div class="ro {'pass' if r_pct==100 else 'warn'}"><div class="k">Reqs met</div><div class="v">{r_pct:g}<span class="u">%</span></div></div>
  <div class="ro {'pass' if n_err==0 else 'fail'}"><div class="k">Blocking</div><div class="v">{n_err}</div></div>
  <div class="ro {'pass' if n_warn==0 else 'warn'}"><div class="k">Advisory</div><div class="v">{n_warn}</div></div>
</div>

<section>
  <div class="shead">
    <h2>Requirements traceability</h2>
    {_chip('pass', f'{r_met} met')} {_chip('warn', f'{r_part} partial')} {_chip('fail', f'{r_miss} missing')}
    <span class="desc">every stated request &rarr; the artifacts that satisfy it</span>
  </div>
  <p class="lede">Each row is something that was asked for, resolved against files that
  actually exist on disk. <b>Found / required</b> is a file count, not a quality judgement —
  a met row means the artifacts are present, not that they are correct.</p>
  <div class="scroll"><table>
    <thead><tr><th>Requirement</th><th style="text-align:right">Found</th><th>Progress</th><th>Status</th><th>Example artifacts</th></tr></thead>
    <tbody>{''.join(req_rows)}</tbody>
  </table></div>
</section>

<section>
  <div class="shead">
    <h2>Structural checks</h2>
    <span class="desc">internal consistency of the tree</span>
  </div>
  <div class="gauges">
    <div class="gauge {c_kind}">
      <div class="k">Top-level contract</div>
      <div class="v">{c_pct:g}<span class="u">%</span></div>
      {_meter(c_pct, c_kind)}
      <div class="note">{len(contract.get('present',[]))} of {len(contract.get('declared',[]))} modules
      instantiated in <code>rtl/fpga_top.sv</code> have a matching file.<br>{missing_txt}</div>
    </div>
    <div class="gauge {l_kind}">
      <div class="k">Cross-references</div>
      <div class="v">{link_broken}<span class="u">broken</span></div>
      {_meter(l_pct, l_kind)}
      <div class="note">{link_total:,} relative links checked across every markdown file.
      A broken link usually means a manual was renamed after something linked to it.</div>
    </div>
    <div class="gauge {v_kind}">
      <div class="k">Testbench coverage</div>
      <div class="v">{v_pct:g}<span class="u">%</span></div>
      {_meter(v_pct, v_kind)}
      <div class="note">{len(cov.get('covered',[]))} of {cov.get('rtl_modules',0)} RTL modules are
      referenced by a file under <code>tb/</code>.<br>{unc_txt}</div>
    </div>
  </div>
</section>

<section>
  <div class="shead">
    <h2>Inventory</h2>
    <span class="desc">what exists, by tier</span>
  </div>
  <div class="scroll"><table>
    <thead><tr><th>Tier</th><th style="text-align:right">Files</th><th style="text-align:right">Lines</th><th>Relative volume</th></tr></thead>
    <tbody>{''.join(inv_rows)}</tbody>
  </table></div>
</section>

<section>
  <div class="shead">
    <h2>Findings by class</h2>
    <span class="desc">grouped, most frequent first</span>
  </div>
  <div class="scroll"><table>
    <thead><tr><th>Class</th><th>Key</th><th style="text-align:right">Count</th></tr></thead>
    <tbody>{''.join(cat_rows)}</tbody>
  </table></div>
</section>

<section>
  <div class="shead">
    <h2>Finding log</h2>
    <span class="desc">most severe first</span>
  </div>
  {overflow}
  <div class="scroll"><table>
    <thead><tr><th style="width:76px">Severity</th><th>Class</th><th>Location</th><th>Detail</th></tr></thead>
    <tbody>{''.join(find_rows)}</tbody>
  </table></div>
</section>

<div class="callout">
  <p><b>What this report proves.</b> The repository is internally consistent: every module
  the top level instantiates exists, every cross-reference resolves, and the RTL obeys the
  coding rules in <code>CLAUDE.md</code>.</p>
  <p><b>What it does not prove.</b> That the design is correct, or fast. Correctness requires
  simulating the order book against the golden software model over a real market-data corpus.
  Speed requires a post-route timing report and an external wire-to-wire measurement.
  <b>Every latency figure in this repository is currently a design target, not a measurement</b> —
  nothing here has run on hardware.</p>
</div>

<footer>
  re-run: python3 scripts/validate.py --html docs/validation-report.html<br>
  ERROR findings are build-blocking; WARN findings are advisory.
</footer>

</div>
"""
