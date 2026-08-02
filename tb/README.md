# `tb/` — Verification Strategy

> A bug in a web service returns a 500. A bug in this system sends a wrong order
> to a live venue at 10 Gbps and keeps doing it until someone notices. There is
> no exception handler, no retry, and no rollback. Verification is not a phase of
> this project; it is most of it.

Governing manuals:
[01-fpga-design/05-verification-and-simulation.md](../manuals/01-fpga-design/05-verification-and-simulation.md) ·
[06-operations/04-testing-strategy.md](../manuals/06-operations/04-testing-strategy.md) ·
[06-operations/01-build-and-release.md §5](../manuals/06-operations/01-build-and-release.md)

---

## 1. The tiers

Each tier catches a class of bug the tier below it **cannot**. Run them in order.
A failure at tier N means you do not proceed to N+1 — not because of process, but
because a tier-N failure makes tier N+1's result uninterpretable.

| # | Tier | Tool | Runtime | What it catches — and only it catches | Runs |
|---|------|------|---------|----------------------------------------|------|
| **0** | **Lint** | `verilator --lint-only -Wall` + `scripts/lint.sh` grep checks | seconds | Latches, width truncation, blocking-in-`always_ff`, undriven nets, forbidden constructs (`always`, `reg`/`wire`, `/`, `%`, `real`) | pre-commit hook, every push |
| **1** | **Unit sim** | cocotb + Verilator, one dir per RTL module | seconds–minutes | Module-level functional bugs; AXI-Stream contract violations; every branch of a decode mux | every commit |
| **2** | **Block integration** | cocotb + Verilator, `tb/<block>/` | minutes | Interface mismatches, **pipeline-depth mismatches**, valid/data skew, backpressure interactions between modules that each passed tier 1 | every commit |
| **3** | **pcap replay vs. golden model** | cocotb + Verilator + `tb/common/golden_book.py` | minutes–hours | **Feed decode and book correctness.** Long-range order-reference bugs, halts, crosses, executions against orders added 40 M messages earlier. **The tier that matters most.** | every commit (60 s pcap), nightly (full session) |
| **4** | **Full-path sim** | xsim / Questa with the real vendor IP | hours | MAC/GT/PCIe IP integration, reset sequencing, real framing, encrypted-model behaviour Verilator cannot compile | nightly |
| **5** | **Gate-level sim** | xsim + post-P&R netlist + SDF | hours–days | Synthesis/simulation mismatch, X-propagation through un-reset registers at power-up, logic the optimizer removed | per release candidate |
| **6** | **Hardware loopback** | Real bitstream, fibre TX→RX, pin timestamping | minutes | Link behaviour, **actual latency in nanoseconds**, everything simulation cannot model | per release candidate |
| **7** | **Venue conformance / UAT** | Real bitstream against Nasdaq's test system | days | Protocol conformance, session-layer behaviour, the venue disagreeing with your reading of the spec | before any production deployment |

Tiers 0–3 run on RTL, in one clock domain, with an idealised MAC. They are cheap
and fast, so they run constantly — **which is exactly why they get trusted more
than they deserve.** See §5.

---

## 2. Directory layout

```
tb/
├── README.md                    ← this file
├── filelist.f                   SVA property modules + bind + sim-only models
├── common/                      shared infrastructure — imported everywhere
│   ├── axis_driver.py           AXI-Stream master (64-bit beats, gaps, no-backpressure mode)
│   ├── axis_monitor.py          AXI-Stream monitor + runtime contract assertions
│   ├── itch_gen.py              ITCH 5.0 builders + MoldUDP64/UDP/IPv4/Ethernet framing
│   ├── golden_book.py           ⚠️ THE ORACLE — reference order book
│   └── pcap_replay.py           pcap → UDP payloads → AxisDriver, at a configurable rate
├── feed/   test_itch_decoder.py
├── book/   test_book_engine.py  ⚠️ the highest-value test in the repo
├── risk/   test_risk_gate.py    ⚠️ the required test matrix
├── order/  test_ouch_encoder.py
├── net/    (moldudp64 deframe, A/B arbitration)
├── strategy/
├── sva/    <module>_props.sv + bind_all.sv
└── pcap/   fixtures — HASHES committed, blobs fetched (see §6)
```

**Rules:**

1. `tb/common/` **never imports** from the oracle, and the oracle never imports
   from `tb/common/`. The stimulus builder and the oracle must be able to
   disagree. If one file both generates and checks, it checks only that it is
   self-consistent.
2. Anything on the fast path with no test directory **does not go on the fast
   path**.
3. Assertions live in `tb/sva/` bind files, not inline in `rtl/`
   ([05-verification §5](../manuals/01-fpga-design/05-verification-and-simulation.md)).
   `fpga_top.sv` keeps four inline top-level safety invariants; that is
   deliberate and documented in its header.

---

## 3. What gates a merge

From [06-operations/01-build-and-release.md §5](../manuals/06-operations/01-build-and-release.md).
**All five must be green.** `make -C scripts ci-pr` runs them.

| # | Gate | Command | Failure means |
|---|------|---------|---------------|
| 1 | Verilator lint clean — zero warnings, no waivers except in `waivers/verilator.vlt` with a comment and a named owner | `make -C scripts lint` | Stop. Fix it. It takes seconds. |
| 2 | All cocotb unit + integration tests pass | `make -C scripts sim` | Stop. |
| 3 | pcap replay: hardware book output **bit-identical** to `golden_book.py` over the whole corpus | `make -C scripts replay` | Stop. This is the one that finds real bugs. |
| 4 | Simulated tick-to-trade latency within the budget in `rtl/fpga_top.sv`'s header, and **unchanged** unless the PR says it changes | cocotb latency assertions | A silent latency change is a regression even when everything still "works". |
| 5 | No new CDC findings in `report_cdc` vs. the last nightly | nightly `report_cdc` diff | See §5 — simulation will never tell you about this one. |

**Deliberately NOT a merge gate: full P&R timing closure.** The feedback loop is
hours, engineers respond by batching changes, and batched changes are harder to
bisect than a nightly regression. Timing is caught in the nightly
(`make -C scripts ci-nightly`) and a WNS regression is a P1 with a named owner.

**Merge-gate discipline** ([05-verification §7](../manuals/01-fpga-design/05-verification-and-simulation.md)):

- `main` is always green. A red `main` means nobody can tell whether their own
  change broke something, and the apparatus stops being useful within a day.
- **A bug fix without a test that fails before the fix is not a fix.**
- **Never disable a test to get a build through.** Mark it `xfail` with an issue
  number and an owner, or fix it. A commented-out test is a lie in the coverage
  report.
- **Every random test logs its seed on its first line.** A random failure you
  cannot reproduce is not a finding, it is a rumour. Every reproduced failure
  gets its seed frozen into `tb/pcap/seeds/` as a permanent directed test, so
  the suite grows monotonically.

---

## 4. Coverage targets before a release candidate

Verilator has no covergroups, so coverage is collected in Python —
`COVER[(msg_type, beat_offset, is_last_beat)] += 1`. **Report coverage per run
and fail CI on a decrease**, not on an absolute threshold.

| Axis | Goal |
|---|---|
| Every ITCH message type the design claims to handle | seen ≥ 100 times |
| message type × starting byte offset 0–7 | every bin hit |
| message type × is-last-in-packet | every bin hit |
| Every FSM state and every legal transition | hit |
| Book: empty side, single level, full depth, crossed (rejected), best level deleted | all hit |
| **Risk gate: every `risk_reason_e` value fired** | **all 24, individually** — see `risk/test_risk_gate.py` |

---

## 5. ⚠️ What this whole apparatus cannot catch

**Keep this list visible. Every item here has ended somebody's trading day.**

A perfectly green regression suite proves that the RTL matches the model. It
proves nothing else. In particular, **simulation cannot catch CDC bugs, timing
failures, or real link behaviour** — those three are structurally invisible to
it, not merely under-tested:

| Not catchable in RTL simulation | Why it is *structurally* invisible | What catches it instead |
|---|---|---|
| **CDC / metastability** | RTL simulation has no notion of setup/hold *across* clock domains. It samples cleanly on every edge, every time, forever. A design with parallel 2-FF chains on a 32-bit bus simulates perfectly and tears in hardware. | `report_cdc` (build gate 5), structural CDC lint, gate-level sim with SDF, and using **only** the sanctioned primitives in `rtl/common/`. Constraints in `constraints/cdc.xdc`. |
| **Timing failure** | Simulation is untimed. Every path takes zero time, so a 40-level combinational blob and a single LUT behave identically. | Static timing analysis. Post-route WNS/TNS from `scripts/report_qor.py`. **Never** a synthesis estimate. |
| **Real link behaviour** | There are no bit errors, no FEC, no link flap, no auto-negotiation, no dirty optics, and no far-end oscillator drift in a testbench. | Hardware (tier 6): PRBS31 BER soak, eye scan, and physically pulling the fibre repeatedly under traffic. |
| Reset release / power-up state | Simulation starts from a defined reset. Verilator's 2-state default reads an un-reset register as `0`; xsim reads `X`; the FPGA reads whatever it powered up with. | Gate-level sim with X-propagation; one nightly Verilator pass with `--x-assign unique --x-initial unique`; explicit reset of every control register. |
| **Actual latency in nanoseconds** | Simulation gives *cycles*. The ~90 ns each way through the GT PMA/PCS is a number from a datasheet, not from a testbench. | Hardware loopback with pin timestamps, histogrammed in fabric. Report p50/p99/p99.9/max — **never** the mean. |
| Congestion / routing delay | Not modelled at all. | Implementation reports; `report_design_analysis`. |
| Vendor IP quirks | Encrypted models are approximations. Some behaviours exist only in silicon. | Tiers 4 and 6, plus the vendor's answer records. |
| Thermal, power, SEU | Not modelled at all. | Hardware soak, SEM IP, monitoring. |
| Venue protocol quirks | Your model of Nasdaq is your model, not Nasdaq. | Venue UAT / conformance (tier 7). |
| **The spec being wrong in your head** | The oracle and the RTL can share a misreading, and then they agree perfectly — forever. | An independent reader checking `golden_book.py` and `itch_gen.py` against the spec PDF. Budget time for it. |

That last row is the dangerous one, and it is why `rtl/pkg/itch_pkg.sv` carries a
`⚠️ VERIFY` marker on every offset constant and why `tb/common/itch_gen.py`
repeats the same caveat. A wrong offset produces a decoder that works on some
messages and silently corrupts others — the worst possible failure mode.

**Corollary for reporting** (CLAUDE.md §4): if a latency number came from a
testbench, say **"simulated"**. If it came from a card, say
**"measured, N=…"**. They are not interchangeable, and quietly using the first
where the second is expected is the most common way an FPGA project misleads
itself.

---

## 6. pcap fixtures

⚠️ **Exchange market data is licensed.** Do not commit real venue captures to
this repository, public or private, without checking the redistribution terms.

- `tb/pcap/` holds **hashes and manifests**, not blobs. Captures are fetched by
  hash from an access-controlled artifact store.
- Golden traces are the same: commit the **hash** of the canonical trace, not
  the multi-gigabyte trace itself. Multi-GB blobs in git end the project's
  ability to clone.
- **Replay the capture byte-for-byte.** Do not filter, de-duplicate, reorder or
  "clean" it. Retransmissions, A/B duplicates, gaps and malformed frames are
  exactly the inputs that need testing. If the pcap has a truncated packet at
  the end, feed it in and check the drop counter increments.

Synthetic stimulus from `itch_gen.py` is for **directed edge cases only** — it
has high control and low realism. It cannot substitute for tier 3.

---

## 7. Running things

```bash
make -C scripts lint            # tier 0                        seconds
make -C scripts sim             # tiers 1-2, all blocks         minutes
make -C scripts sim-book        # one block, for the edit loop
make -C scripts sim-risk SEED=0xC0FFEE   # reproduce a logged random failure
make -C scripts replay          # tier 3 vs. the golden book
make -C scripts ci-pr           # exactly the merge gate
make -C scripts synth           # tier 4-ish: latch + unconstrained-clock check
make -C scripts impl            # full P&R — the only stage that means closure
make -C scripts seed-sweep      # ⚠️ the only thing that means closure at all
make -C scripts qor             # parse the reports into JSON + a table
```

Waveforms: `WAVES=1`. Off by default because they are slow and because a test
that needs a waveform to interpret its own failure has a reporting bug — see the
first-divergence reporting requirement in `tb/book/test_book_engine.py`.
