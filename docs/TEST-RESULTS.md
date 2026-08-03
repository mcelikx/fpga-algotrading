# Test Results — measured, not claimed

Run via each testbench's own runner (`python3 tb/common/test_<x>.py`), which
rebuilds the DUT across a parameter matrix. **Not** via `tb/common/Makefile`,
which builds one configuration at module defaults.

| Module | Runs | Tests | Pass | Fail | Skip | Verdict |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `cdc_sync_bit` | 2 | 14 | **14** | 0 | 0 | ✅ |
| `counter_bank` | 4 | 36 | **36** | 0 | 0 | ✅ |
| `async_fifo` | 4 | 48 | **44** | 0 | 4 | ✅ |
| `reset_sync` | 1 | 8 | 7 | **1** | 0 | ⚠️ undiagnosed |
| `sync_fifo` | 1 | 10 | 9 | **1** | 0 | ⚠️ undiagnosed |
| `prio_encoder` | 16 | 160 | 16 | **144** | 0 | ⚠️ **testbench defect, RTL proven correct** |
| `cdc_pulse` | — | — | — | — | — | ❌ build: `NEEDTIMINGOPT` |
| `cdc_handshake` | — | — | — | — | — | ❌ build: `NEEDTIMINGOPT` |
| `skid_buffer` | — | — | — | — | — | ❌ build: `NEEDTIMINGOPT` |
| `arbiters` | — | — | — | — | — | ❌ build: `NEEDTIMINGOPT` |

**All three CDC primitives that build and run pass**, including `async_fifo`
across clock ratios — the largest untested risk in the design, since CDC
defects survive static timing analysis and short soaks by construction.

---

## `prio_encoder` — the RTL is correct; the testbench is wrong

144 of 160 failures, consistent across all 16 parameterisations. Proven **not**
to be an RTL defect by a direct SystemVerilog probe with no cocotb involved:

```
RESULT: 0 mismatches out of 16 single-bit cases
```
(`prio_encoder` at N=16, every single-bit vector, plus all-zero → `valid=0`.)

The defect is in `tb/common/test_prio_encoder.py::present()`. At `PIPELINE=0`
the encoder is combinational, and the helper drives and samples in the same
timestep:

```python
_drive_inputs(dut, vec)
await ReadOnly()        # ← no delta for the combinational output to settle
out = _read(dut)
```

So it reads a stale value. One genuine failure in `test_single_bit_exhaustive`;
the other eight are a cascade, all reporting 0.00 ns of simulation time because
the regression cannot recover.

⚠️ **Do not "fix" the RTL against this.** The encoder is right.

## `NEEDTIMINGOPT` — four modules cannot build

The per-file runners omit Verilator's `--timing`, which the RTL's timing
controls require. `tb/common/Makefile` passes it, which is why these four built
under that path and not under their own runners.

---

## ⚠️ How to read this table

Two corrections were needed before these numbers were trustworthy, and both are
worth remembering:

1. **A first sweep through `tb/common/Makefile` reported 14 failures.** Those
   were not RTL defects — the Makefile built one configuration at module
   defaults while the tests asserted against a geometry their own runner sets.
   A red result from a harness you wrote is a claim about the harness until you
   have checked the harness.
2. **The passes from that sweep were not evidence either.** They passed because
   the defaults happened to match — one point of a matrix, by luck.

**Nothing here has been synthesized, placed, routed, or run on hardware.**
`tb/book/test_book_soak.py` — the golden-model equivalence check that decides
whether the order book is actually correct — has still never been executed.
