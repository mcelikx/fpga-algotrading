# `tb/common/` — CDC and common-primitive testbenches

> ## ⚠️ NOTHING IN THIS DIRECTORY HAS EVER BEEN EXECUTED
>
> **`cocotb` is not installed on this machine and no simulator is available
> here.** Every file below has been syntax-checked (`python -m py_compile`),
> import-checked against a stub, and reviewed line by line against the RTL port
> lists — and **not one assertion in any of them has ever been evaluated by a
> simulator.** No test in this directory has passed. No test in this directory
> has failed. They are *hypotheses about the RTL*, written from the RTL, and
> they are worth exactly nothing until `make -C scripts sim` runs them green.
>
> Treat every claim in this README as "written and reviewed", never as
> "passing". This is the same caveat `tb/COVERAGE.md` §5.1 already carries for
> the rest of the suite, and it is the most important sentence on the page.

---

## 1. Why this directory exists

Coverage of `rtl/common/` was 56%, and the untested half was **every
clock-domain-crossing primitive in the design**. That gap matters more than the
percentage suggests:

- **CDC bugs pass simulation, pass timing analysis, pass a week of soak testing,
  and then corrupt one order in ten million on a hot afternoon.** Static timing
  analysis does not check CDC correctness — by definition those paths are
  excluded from STA (manual `00-foundations/04-clocking-reset-and-cdc.md` §6).
- Manual 00.04 §1 rule 2: CDC exists in exactly three places in this design —
  MAC RX → core, core → MAC TX, PCIe → core. **All three are `async_fifo`.**
  Market data in, orders out. There is no other crossing.
- `rtl/common/async_fifo.sv:43` makes running an async-FIFO testbench at several
  clock ratios, *including nearly-equal frequencies, with randomized phase*, an
  explicit **precondition for the module being allowed to exist** in preference
  to the vendor macro. Until `test_async_fifo.py` has been run, the module is
  being used outside the terms it was permitted under.

---

## 2. ⚠️ What these tests fundamentally CANNOT prove

Read this before quoting any result from this directory.

| Not provable here | Why it is *structurally* invisible | What actually proves it |
|---|---|---|
| **Metastability / MTBF** | RTL simulation has no notion of setup/hold *across* domains. It samples cleanly on every edge, every time, forever. A design with parallel 2-FF chains on a 32-bit bus simulates perfectly and tears in silicon. | `report_cdc` (merge gate 5), structural CDC lint, `ASYNC_REG` placement, gate-level sim with SDF |
| **Bus skew on the `cdc_handshake` data path** | All W bits arrive at the same zero-delay instant in simulation. Skew is created by *routing*. | `set_max_delay -datapath_only` + `set_bus_skew` in `constraints/cdc.xdc` — **never** `set_false_path` (manual 00.04 §5) |
| **Reset-release routing skew between domains** | Simulation has one global time. | XDC constraint on the `async_rst_in` → `rst_q[0]` path (`rtl/common/reset_sync.sv:42`) |
| **That `ASYNC_REG` survived the last edit** | An attribute has no simulation semantics. | `test_cdc_sync_bit.py::test_source_forbids_multibit_use` reads the RTL *text*; `report_cdc` reads the netlist |

What simulation **can** own is the *functional* contract: no loss, no
duplication, no reordering, correct flags, exact latency, and the precise shape
of every documented limitation. That is what this directory is for.

---

## 3. The files

| File | DUT | Headline property |
|---|---|---|
| `test_cdc_sync_bit.py` | `rtl/common/cdc_sync_bit.sv` | Exactly `STAGES` cycles of latency at every source phase; a ≥2-period level always arrives; **a sub-period pulse IS silently dropped at some phases** — asserted, not assumed |
| `test_cdc_pulse.py` | `rtl/common/cdc_pulse.sv` | `dst_pulse` count == accepted event count at 10 ratios (1:8…8:1); **the exact source spacing below which events are lost, proved equal to the `src_busy` window**; over-driving drops, never merges or fabricates |
| `test_cdc_handshake.py` | `rtl/common/cdc_handshake.sv` | Bit-exact wide-bus delivery at 10 ratios incl. the real 250 MHz↔156.25 MHz pair; data immune to a scribbled source bus once accepted; round trip 9–11 source cycles; no deadlock over hundreds of back-to-back transfers |
| `test_async_fifo.py` | `rtl/common/async_fifo.sv` | ⚠️ **The most important file here.** No loss / duplication / reordering at write:read ratios 1:10…10:1 **including 6400 ps vs 6401 ps**, randomized phase; flags never wrong in the direction that costs data; `wr_almost_full` threshold and headroom; `wr_high_water` exact; staggered-phase reset from both domains; burst-then-drain; drain-faster-than-fill; gray-pointer Hamming distance ≤ 1 |
| `test_sync_fifo.py` | `rtl/common/sync_fifo.sv` | Exactly `DEPTH` fits; flags exact against a cycle-accurate occupancy model; sticky `overflow`/`underflow` survive 300 cycles and clear only on `err_clr`/`rst`; `high_water` exact; ⚠️ pins that a same-cycle read does **not** free a slot for a same-cycle write at full |
| `test_reset_sync.py` | `rtl/common/reset_sync.sv` | ⚠️ **64 release phases swept across the clock period**, each checked for mid-period constancy and an exact `STAGES + RELEASE_CYCLES` edge count; assert works with the clock **stopped**; a sub-period reset glitch between two edges is still captured |
| `test_arbiters.py` | `rr_arbiter.sv`, `fixed_arbiter.sv` | RR: exact rotation, share within one, **bounded N−1 wait under adversarial demand**, deterministic post-reset start. Fixed: **priority 0 granted the same cycle, exhaustively**; strict order for every request pattern; `starve_cnt` exact to the cycle in three regimes; saturates without wrapping |
| `test_counter_bank.py` | `rtl/common/counter_bank.sv` | Every increment counted exactly under random traffic; read/increment race resolves to the pre-increment value; sticky vs clear-on-read semantics (mode detected **behaviourally**); saturation without wrap; ⚠️ **re-derives the wrap-span table in the RTL header from 2^W / 156.25 MHz** so narrowing `W` fails a test |

Every file opens with a docstring stating the invariant it proves and why that
invariant matters to the trading system, not what module it pokes.

---

## 4. Running one

There is no `Makefile` in this directory (matching `test_skid_buffer.py`, which
already lives here). Each file is self-hosting:

```bash
cd tb/common
python3 test_async_fifo.py            # builds every parameter variant, runs all tests
python3 test_reset_sync.py
python3 test_arbiters.py              # builds rr_arbiter AND fixed_arbiter
```

Or through cocotb's normal `TOPLEVEL`/`MODULE` mechanism:

```bash
TOPLEVEL=async_fifo MODULE=test_async_fifo make -f $(cocotb-config --makefiles)/Makefile.sim
```

Knobs, all optional:

| Variable | Effect |
|---|---|
| `SEED=<n>` \| `SEED=random` | Every randomized test logs `SEED=…` on its first line and threads it into every assertion message. A random failure you cannot reproduce is a rumour, not a finding. |
| `SIM=verilator` (default) | Simulator selection |
| `WORDS`, `SOAK_WORDS` | Per-ratio word counts in `test_async_fifo.py` |
| `EVENTS`, `TRANSFERS`, `BEATS` | Stimulus counts in the CDC files |
| `PHASE_STEPS`, `PHASE_TRIALS` | Release-phase sweep density in `test_reset_sync.py` |
| `PROBE_ILLEGAL=1` | Enables `test_async_fifo.py::test_illegal_write_while_full_does_not_corrupt`, which deliberately violates the RTL's own assertion. Off by default: a suite that prints an expected error every run trains people to ignore errors. |

---

## 5. Testbench conventions used here

Three of these are not decoration; getting them wrong makes a CDC test prove
nothing while appearing to pass.

1. **Everything is in integer picoseconds.** 156.25 MHz is 6400 ps exactly, and
   the nearly-equal-frequency cases (6400 vs 6401) cannot be expressed at all in
   nanoseconds. The runners pass `--timescale-override 1ns/1ps` to Verilator for
   this reason. ⚠️ That build flag has never been exercised here; if a build
   rejects it, that is the first thing to check.
2. **Clock PHASE is randomized, not just the ratio** (manual 00.04 §6.2). A
   pointer or handshake bug that only bites at one alignment is still a bug, and
   it is precisely the kind that survives soak testing. Every dual-clock file
   starts its clocks through a helper that takes a phase offset.
3. **Clock drivers are tracked in a module-level registry and killed before
   restart.** cocotb runs every test in a file inside ONE simulation, so a naive
   "start a clock in `bringup`" leaves several tasks toggling the same net: the
   DUT then sees a clock that is neither period, every ratio test silently
   becomes the same test, and a real bug is masked by a testbench bug.
4. **Dual-clock stimulus is driven on the FALLING edge of its own clock.** Every
   status flag the testbench conditions on (`wr_full`, `rd_empty`, `rd_valid`,
   `src_ready`, `src_busy`) is a registered output, so it is constant between
   rising edges; sampling and deciding at the midpoint is race-free *and* means
   the testbench never presents `wr_en` while `wr_full`, which would trip the
   RTL's own assertion and hide a real failure behind a testbench artefact.
5. **Payloads are self-describing** in both FIFO tests: the high half of each
   word is the complement of the low half. A torn read (some bits from word N,
   some from N+1) breaks the complement even when the low half still looks like
   a plausible index, so a tear is reported as a tear rather than as a
   reordering.
6. **Limitations documented in an RTL header get a test that PINS them**, so the
   limitation cannot silently change and a caller cannot later argue it away.
   Those tests are marked ⚠️ in their docstrings and assert that the documented
   loss *happens*.
7. **Two tests deliberately stand down and say so loudly** when a build cannot
   reach the condition they exist for (`starve_cnt` saturation above
   `STARVE_W=12`, counter saturation above `W=20`). A test that quietly passes
   without having checked anything is worse than a missing test.

---

## 6. RTL findings raised while writing these tests

None of these were fixed here — `rtl/` is owned by other agents this session.
All line numbers are as of the revision these tests were written against.

1. **`rtl/common/sync_fifo.sv:46` — the default `ALMOST_FULL_LEVEL` is illegal at
   the module's own documented minimum `DEPTH`.** `DEPTH = 2` is declared legal
   at line 45 ("MUST be a power of two, >= 2") and accepted by the guard at line
   172, but `ALMOST_FULL_LEVEL = DEPTH - 2` is then 0 and the guard at line 180
   rejects 0 and calls `$fatal(1)`. `sync_fifo #(.DEPTH(2))` cannot be
   elaborated. Suggested fix: `= (DEPTH > 2) ? DEPTH - 2 : 1`. The runner in
   `test_sync_fifo.py` builds `DEPTH=4` instead and carries a comment saying why.
2. **`rtl/common/cdc_handshake.sv:48` describes the wrong failure mode for a
   single-domain reset.** It says the channel "deadlocks (`src_ready` never
   returns)". By inspection, a `dst_rst` pulse with a transfer in flight leaves
   `req_sync` high (the synchronizer chain has no reset) while `req_sync_q` is
   forced low, so the destination re-detects a rising edge on release and emits
   a **second `dst_valid` for one source transfer** — a duplicated control-plane
   write — and then completes normally. A `src_rst` before the destination has
   captured **loses** the transfer instead. The mitigation is unchanged (one root
   reset, one `reset_sync` per domain) but the documented symptom would send
   someone debugging a duplicated risk-limit write in the wrong direction.
   `test_cdc_handshake.py::test_destination_only_reset_does_not_wedge_the_channel`
   asserts the no-deadlock half and logs duplicates.
3. **`rtl/common/cdc_pulse.sv:48` has the same issue.** It predicts "one spurious
   `dst_pulse` on release, or the source sits permanently `src_busy`". The
   permanent-busy case does not appear reachable: `ack_sync` re-converges on
   `src_toggle_q` once the reset is released. The reachable damage is a
   duplicated or spurious destination event.
   `test_cdc_pulse.py::test_resetting_one_domain_only_breaks_event_conservation`
   pins the event-count corruption without claiming a specific symptom.
4. **`rtl/common/cdc_handshake.sv:24` overstates the destination latency.** The
   header says "~5 dst cycles to `dst_valid`"; the structure gives
   `SYNC_STAGES` cycles through `u_req_sync` plus one for the registered strobe,
   i.e. **3** at the default. The error is in the safe direction, and the
   round-trip figure (9–11 source cycles) is correct, so this is documentation
   only. `test_round_trip_latency_matches_the_header` asserts
   `[SYNC_STAGES+1, 5]` and logs the measured value on every run.
5. **`rtl/common/counter_bank.sv:120` can set `saturated[i]` when nothing was
   lost.** In `CLEAR_ON_READ` mode with `incr[i]` and `rd_clear[i]` both high on
   a cycle where `cnt_q[i] == CNT_MAX`, the sticky flag is set even though the
   counter reloads to 1 and the increment is preserved. `saturated` means "an
   increment was lost"; here it reports a loss that did not happen. Narrow, but
   it is a *false* health signal on the telemetry path, which is the direction
   CLAUDE.md §5.7 cares about.
6. **Observation, not a defect — `rtl/common/async_fifo.sv:317` and `:321` use
   `$error` for `wr_en && wr_full` and `rd_en && rd_empty`.** `sync_fifo` uses
   `$warning` for the same two conditions, and `async_fifo`'s own header
   (line 58) describes `wr_full` on the MAC RX crossing as a designed
   drop-and-count event. Whether a legal RX producer trips this depends on
   whether it gates `wr_en` with `!wr_full` or relies on the FIFO to refuse. It
   is worth settling deliberately: a regression that errors on designed
   behaviour teaches people to ignore errors. These testbenches gate `wr_en`
   with `!wr_full` throughout, so they never trip it, and the one test that does
   is opt-in behind `PROBE_ILLEGAL=1`.

---

## 7. What to do first when a simulator is available

1. `pip install cocotb` and run `python3 test_reset_sync.py` — no dependencies
   beyond one RTL file and the fastest way to find out whether the harness
   conventions in §5 hold on this simulator.
2. `python3 test_async_fifo.py`. This is the one that closes `tb/COVERAGE.md`
   §3.1 and satisfies `rtl/common/async_fifo.sv:43`. Expect it to be the longest
   run in the directory: ~20 clock-ratio configurations plus a multi-revolution
   near-equal soak, across four parameter builds.
3. Then the rest, in any order.
4. Update `tb/COVERAGE.md` §1 (`rtl/common/` rows) and §3.1 **only after a green
   run** — and mark them ✅ meaning "passing", which is a different and much
   stronger claim than the one this README is currently allowed to make.
