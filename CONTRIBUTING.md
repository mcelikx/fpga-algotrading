# Contributing

This is a real-money trading system. The bar is higher than for most codebases, and the
reasons are in [`CLAUDE.md`](CLAUDE.md) §5 and §6. Read those first.

---

## Before you write RTL

1. **Read the governing manual.** Every block has one; it is named in the module header.
   The manuals encode the constraints that make the design correct *and* fast. Skipping
   them produces code that synthesizes, misses timing, and blows the latency budget.
2. **State the latency budget** in nanoseconds and cycles, in the module header. A block
   without a budget is not reviewable.
3. **State the resource budget** — LUT/FF/BRAM/URAM/DSP — in the same header.

## Coding standard

Full detail in [`manuals/00-foundations/03-hdl-and-rtl-coding.md`](manuals/00-foundations/03-hdl-and-rtl-coding.md).

- Synthesizable **SystemVerilog IEEE 1800-2017**. `logic` only, never `reg`/`wire`.
- `always_ff` / `always_comb` only. Never bare `always`. `<=` in ff, `=` in comb.
- **No latches.** Default assignments open every `always_comb`; every `case` has a `default`.
- Synchronous active-high `rst`. Reset control state only, never datapath registers.
- Registered outputs by default; exceptions justified in a comment.
- All literals sized (`8'd5`), all parameters typed (`parameter int unsigned`).
- Named generate blocks. One module per file, filename == module name.
- `` `default_nettype none `` at the top, `` `default_nettype wire `` at the bottom.
- SVA assertions inside `` `ifndef SYNTHESIS `` on every stream interface and invariant.
- **No division, no modulo, no floating point.**

CDC uses only the sanctioned primitives in [`rtl/common/`](rtl/common/). Hand-rolling a
synchronizer is a review failure, not a style disagreement — the failure mode is a design
that works for months and then corrupts one order.

## Before you open a PR

```bash
python3 scripts/validate.py --ignore-category broken-link   # must exit 0
./scripts/lint.sh                                            # Verilator, -Wall clean
make -C scripts sim                                          # testbenches pass
```

- **Every fast-path module needs a testbench.** No exceptions.
- Do not report "done" until place-and-route timing closes.
- Quote **WNS/TNS and utilization verbatim from the report**. Never estimate them.
- If a latency number was simulated, say "simulated". If measured on hardware, say
  "measured, N=…". These are not interchangeable and conflating them wastes everyone's time.

## Suppressing a validator rule

Rules can be suppressed, but never silently:

```systemverilog
localparam real CLKFB_MULT_F = 12.500;  // validate: allow real — vendor MMCM declares it real
```

The justification is mandatory. A suppression without one is itself reported.

---

## 🔒 Changes that need extra care

These have a blast radius beyond the file you are editing.

| Change | Requirement |
|---|---|
| **Risk limits, order sizing, kill switch** | Separate commit, separate review, separate audit entry. **Never bundled with other work.** |
| **`rtl/pkg/trading_pkg.sv`** | System-wide contract. Say so explicitly and update the latency budget in the same commit. |
| **`rtl/fpga_top.sv`** | Holds the master latency budget. Any added cycle must be justified in the PR. |
| **ITCH/OUCH field offsets** | Must be verified against the current spec PDF and the verification recorded. A wrong offset produces a decoder that corrupts *some* messages silently. |
| **Anything touching a live venue** | Never. Simulated and UAT endpoints only, until conformance certification is complete. |

## What must never be optimized away

The risk gate, the kill switch, gap detection, and the error counters. Removing a check to
save a cycle converts a latency problem into a solvency problem.

## Never commit

Venue credentials, comp IDs, session IDs, MPIDs, production IP addresses, or recorded
exchange market data. `.gitignore` covers the common cases; it is not a substitute for
looking at your diff.

---

## Commit messages

Conventional-Commit prefixes (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`,
`build:`), imperative mood, subject ≤ 72 chars. The body explains **why**, not a file-by-file
recap — and in this codebase the *why* is usually a failure mode being prevented. Say what
it is.
