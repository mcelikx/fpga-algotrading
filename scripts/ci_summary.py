#!/usr/bin/env python3
"""Render a GitHub Actions step summary from validate.py's JSON output.

    python3 scripts/validate.py | python3 scripts/ci_summary.py >> "$GITHUB_STEP_SUMMARY"
"""
from __future__ import annotations

import json
import sys


def main() -> int:
    r = json.load(sys.stdin)
    t = r["totals"]
    ok = t["links_checked"] - t["links_broken"]
    met = sum(1 for q in r["requirements"] if q["status"] == "met")
    cov = r["coverage"]
    con = r["contract"]

    def mark(good: bool) -> str:
        return "✅" if good else "⚠️"

    print("## Validation summary\n")
    print("| Metric | Value | |")
    print("|---|---:|:-:|")
    print(f"| Files | {t['files']:,} | |")
    print(f"| Lines | {t['lines']:,} | |")
    print(f"| RTL modules | {t['rtl_modules']} | |")
    print(f"| Top-level contract | {con['complete_pct']}% | {mark(con['complete_pct'] >= 100)} |")
    print(f"| Testbench coverage | {cov['pct']}% | {mark(cov['pct'] >= 90)} |")
    print(f"| Cross-references | {ok:,} / {t['links_checked']:,} | {mark(t['links_broken'] == 0)} |")
    print(f"| Requirements met | {met} / {len(r['requirements'])} | {mark(met == len(r['requirements']))} |")

    if con.get("missing"):
        print(f"\n**Missing modules:** {', '.join('`' + m + '`' for m in con['missing'])}")
    if cov.get("uncovered"):
        print(f"\n<details><summary>{len(cov['uncovered'])} modules without a testbench</summary>\n")
        print(" ".join("`" + m + "`" for m in cov["uncovered"]))
        print("\n</details>")

    print("\n> This proves the tree is internally consistent. It does **not** prove the")
    print("> design is correct or fast — that needs simulation against the golden model")
    print("> and a post-route timing report.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
