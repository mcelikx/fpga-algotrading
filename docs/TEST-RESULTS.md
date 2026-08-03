# Test Results — measured, not claimed

Run via each testbench's own runner (`python3 tb/common/test_<x>.py`), which
rebuilds the DUT across a parameter matrix. **Not** via `tb/common/Makefile`,
which builds one configuration at module defaults.

⚠️ **Run them ONE AT A TIME.** Nine of the ten runners do not pass `build_dir`,
so they all share `sim_build/` and overwrite each other's `Vtop.*` mid-build if
run concurrently. The symptom is a C++ compile error naming another module's
ports (`no member named 'src_pulse' in 'Vtop___024root'`), which looks like an
RTL error and is not one. Only `test_prio_encoder.py` isolates its build.

| Module | Runs | Tests | Pass | Fail | Skip | Verdict |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `prio_encoder` | 16 | 160 | **160** | 0 | 0 | ✅ |
| `arbiters` | 6 | 66 | 33 | 0 | 33 | ✅ (33 honest skips) |
| `async_fifo` | 4 | 48 | 44 | 0 | 4 | ✅ ⚠️ see below |
| `counter_bank` | 4 | 36 | **36** | 0 | 0 | ✅ |
| `cdc_handshake` | 3 | 18 | **18** | 0 | 0 | ✅ |
| `cdc_sync_bit` | 2 | 14 | **14** | 0 | 0 | ✅ |
| `cdc_pulse` | 2 | 12 | **12** | 0 | 0 | ✅ |
| `skid_buffer` | 1 | 6 | **6** | 0 | 0 | ✅ |
| `sync_fifo` | 4 | 40 | 39 | **1** | 0 | ⚠️ 1 config |
| `reset_sync` | 4 | 32 | 28 | **4** | 0 | ⚠️ convention dispute |
| **Total** | **40** | **432** | **390** | **5** | **37** | |

**All four CDC primitives pass** — `cdc_sync_bit`, `cdc_pulse`, `cdc_handshake`,
`async_fifo` — the last across clock ratios including near-equal frequencies.
That was the largest untested risk in the design: CDC defects survive static
timing analysis and short soak tests by construction.

---

## `prio_encoder` — the clock stopped after the first test

Was 16 pass / 144 fail, consistent across all 16 parameterisations. **The RTL is
correct** — that part of the previous diagnosis held up.

**The previously recorded root cause was wrong.** It said `present()` sampled a
combinational output in the same timestep it drove it, and read a stale value.
It does not. cocotb applies pending writes before entering `ReadOnly` in the
same timestep, so drive-then-`ReadOnly` reads the settled value. Two independent
facts prove it, both from real runs at `PIPELINE=0`:

* `_discover_latency()` measures **0** cycles — a stale read would have measured 1.
* `test_latency_is_exactly_pipeline_cycles` cross-checks the measured latency
  against the elaborated `$PE_PIPELINE`. An off-by-one read would fail it with
  `LATENCY CONTRACT BROKEN`. It passes.

The actual defect: **cocotb 2.0 cancels every task a test started when that test
ends** (`cocotb/_test.py` — "Set outcome and cancel Tasks"). `bringup()` started
the clock once, under an `if not GEO:` first-test-only guard, so the clock task
died with test 1. From test 2 onward nothing toggled `clk`, Verilator ran out of
scheduled events one half-period later and exited. Every remaining test was
`SimFailure: Simulator shut down prematurely` at 0.00 ns — 1 pass + 9 fail per
build, times 16 builds, is exactly the 16/144 that was recorded.

Fixed by starting the clock per test and cancelling any predecessor, the shape
`test_sync_fifo.py` and `test_counter_bank.py` already used. **160/160 now**,
verified at `PIPELINE=0`, `1` and `2`.

## `NEEDTIMINGOPT` — four modules could not build

The per-file runners omitted Verilator's `--timing`, which the RTL's delay
controls require. Added to `test_cdc_pulse`, `test_cdc_handshake`,
`test_skid_buffer` and `test_arbiters`. The other six runners build and pass
without it and do not need it; the lz4/FST flags in `tb/common/Makefile` are not
needed either, because no runner enables waves.

Getting them to build exposed real failures that had never run before:

* **`skid_buffer` — two testbench defects, now fixed.** Both violated the
  ready/valid contract the module's header states and asserts:
  `test_integrity_under_random_stalls` re-rolled its offer every cycle,
  withdrawing beats that had not been accepted; `test_reset_mid_transaction`
  advanced `s_data` every cycle while `s_ready` was low. The RTL was right to
  complain. 6/6 now.
* **`cdc_handshake` — one testbench defect, now fixed.** Two windows
  (round-trip latency, sustained period) hardcoded numbers the header scopes to
  `SYNC_STAGES=2` and applied them to the `SYNC_STAGES=3` build. The round trip
  crosses **four** synchroniser chains, so it is `4*STAGES + 2` — measured
  exactly 10 at `STAGES=2` and exactly 14 at `STAGES=3`. The bounds now scale;
  at `STAGES=2` they are unchanged. 18/18 now.
* **`arbiters` — an RTL defect (below), plus a runner that hid two thirds of the
  matrix.** The `$stop` killed the whole sweep at build 4 of 6, so two
  `fixed_arbiter` parameterisations were never measured at all. The runner now
  records a failing configuration and continues. Note `except Exception` is not
  enough — cocotb reports a failed simulation by *exiting*, and `SystemExit` is
  not an `Exception`.

## The one RTL defect behind all five remaining failures

Three modules assert a monotonic counter as an **immediate** comparison under a
`disable iff` that does not cover the recovery cycle:

```systemverilog
assert property (@(posedge clk) disable iff (rst)
    high_water >= $past(high_water))
```

Clear the counter for exactly **one** cycle — which every one of these ports
documents as legal — and the first re-enabled evaluation compares the
post-clear value against a `$past` still holding the pre-clear one. The counter
did not decrease; it was cleared, by the port provided for clearing it.

Each was reproduced with a **standalone SystemVerilog probe driving the DUT
directly, no cocotb involved**:

| Site | 1-cycle clear | 2+ cycles | Functional behaviour |
| --- | --- | --- | --- |
| `sync_fifo.sv:228` (`rst`) | ❌ `$stop` | ✅ clean | correct — `high_water` cleared |
| `fixed_arbiter.sv:192` (`starve_clr`) | ❌ `$stop` | ✅ clean | correct — `starve_cnt` cleared |
| `reset_sync.sv:112` (sub-period pulse) | ❌ `$stop` | — | correct — pulse **was** captured |

`reset_sync` is the same family seen from the other side: its property samples
`async_rst_in` only at `posedge clk`, so a reset pulse that asserts and
de-asserts between two edges is invisible to it and the (correct, asynchronous,
entirely intended) assertion of `sync_rst_out` reads as a spurious
re-assertion. `clk_rst_gen` feeds this module a bouncing pushbutton and an
asynchronous `mmcm_locked`, so sub-period pulses are not hypothetical.

**`counter_bank` shows the correct shape** and is why it passes 36/36 while
driving a genuine 1-cycle `clr_all`: its property is an *implication* whose
consequent lands a cycle later, so the disable window covers the recovery edge.

```systemverilog
assert property (@(posedge clk) disable iff (rst || clr_all)
    (!rd_clear[c]) |=> (cnt_q[c] >= $past(cnt_q[c])))
```

⚠️ **`async_fifo.sv:354` has the un-fixed immediate shape and is never
exercised.** Its testbench holds `wr_rst` for `12 * max(wr_ps, rd_ps)` — always
many cycles, never a short one — so its 44/48 green says nothing about this
case. A probe driving a **1-cycle `wr_rst`** aborts, though on a louder property
first: `async_fifo.sv:299`, *"write pointer gray code changed more than one bit
— CROSSING IS UNSAFE"*. Two or more cycles are clean. Whether that one is the
same recovery-window artefact or a genuine constraint on minimum reset width
across the two domains is a call for the RTL owner; it is recorded here because
nothing in the suite currently asks the question.

---

## ⚠️ How to read this table

Four corrections were needed before these numbers were trustworthy, and all
four are worth remembering:

1. **A first sweep through `tb/common/Makefile` reported 14 failures.** Those
   were not RTL defects — the Makefile built one configuration at module
   defaults while the tests asserted against a geometry their own runner sets.
   A red result from a harness you wrote is a claim about the harness until you
   have checked the harness.
2. **The passes from that sweep were not evidence either.** They passed because
   the defaults happened to match — one point of a matrix, by luck.
3. **A recorded root cause is a claim too.** `prio_encoder`'s 144 failures had a
   plausible, specific, written-down explanation — combinational sampling — and
   it was wrong. The evidence that settled it took one run: the DUT was
   reporting `SimFailure`, not a bad value, and the latency the testbench
   measured was right. Read the failure that actually happened, not the one the
   note predicts.
4. **A green test that never ran is not a pass.** Fixing the four builds turned
   up defects in three of them; the `arbiters` `$stop` was hiding two whole
   parameterisations behind an exit code. Check the run count, not just the bar.

### Passes that assert nothing

Counted as PASS, but the body returns early — real, honest, and not evidence of
anything:

* `prio_encoder`: 32 of 160. `test_back_to_back_every_cycle` and
  `test_reset_forces_valid_low` return immediately at `PIPELINE=0` (5 builds
  each); `test_runtime_direction` returns unless `DYN_DIR=1` (15 builds);
  `test_pipeline_equivalence_across_builds` has nothing to compare against in
  the first build of each (N, GROUP_W, REVERSE) group (7 builds).
* `arbiters`: 33 of 66 are honest `SKIP`s — the file serves two toplevels and
  half its tests do not apply to whichever one is built.

**Nothing here has been synthesized, placed, routed, or run on hardware.**
`tb/book/test_book_soak.py` — the golden-model equivalence check that decides
whether the order book is actually correct — has still never been executed.
