# Verification coverage matrix

Every RTL module in `rtl/filelist.f`, against the testbenches that cover it.

**This document's job is to be honest about the gaps.** A coverage matrix that
only lists what is covered is marketing. Sections 3–5 are the ones to read.

- Generated: 2026-08-02. Regenerate whenever `rtl/filelist.f` changes.
- Scope of this pass: **deep per-module verification** beyond the scaffolding.
- ⚠️ **Nothing in this suite has been executed.** `cocotb` is not installed in
  this environment (`verilator 5.050` is). See §5.1 — this is the single most
  important caveat on the whole document.

Legend:

| Mark | Meaning |
| --- | --- |
| ✅ | Test exists, targets the real module, port list verified against the RTL source |
| 🟡 | Test exists but codes to an **assumed** interface (RTL absent when written) — see `# TODO(verify)` in the file |
| ⬜ | **No test.** Named here so it cannot be forgotten |
| n/a | Package / no testable logic, or vendor IP wrapper |

---

## 1. Coverage matrix

### `rtl/pkg/` — the interface contract

| Module | Test | Status | Notes |
| --- | --- | --- | --- |
| `trading_pkg.sv` | `tb_util.assert_package_mirror()` | ✅ | Guards the hand-mirrored constants in `tb/common/tb_util.py` §5 against drift. Already earned its keep — see §4.2 |
| `itch_pkg.sv` | `tb/common/itch_gen.py` (scaffolding) | 🟡 | Message lengths/offsets exercised indirectly; no direct spec-conformance test of `itch_msg_len()` |
| `sat_arith_pkg.sv` | — | ⬜ | **Not covered.** Saturating arithmetic is a risk-critical primitive; `tb_util.sat_add64/sat_sub64` are models awaiting a DUT comparison |

### `rtl/common/` — sanctioned primitives

| Module | Test | Status | Notes |
| --- | --- | --- | --- |
| `cdc_sync_bit.sv` | — | ⬜ | **Not covered** (planned `test_cdc.py`) |
| `reset_sync.sv` | — | ⬜ | **Not covered** |
| `cdc_pulse.sv` | — | ⬜ | **Not covered.** Exactly-one-pulse and `src_busy` semantics unproven |
| `cdc_handshake.sv` | — | ⬜ | **Not covered.** ⚠️ This is the primitive the host uses to push **risk limits**; a torn transfer is a wrong limit in the fabric |
| `sync_fifo.sv` | — | ⬜ | **Not covered** (planned `test_fifos.py`) |
| `async_fifo.sv` | — | ⬜ | **Not covered.** ⚠️ Highest-risk gap in `common/` — see §3.1 |
| `skid_buffer.sv` | `tb/common/test_skid_buffer.py` | ✅ | 100% throughput, 1-cycle fixed latency, contract under 7 directed stall shapes + random soak, reset-mid-transaction, no-phantom-beat |
| `delay_line.sv` | — | ⬜ | **Not covered.** Pipeline valid/data skew is an assertion target |
| `prio_encoder.sv` | — | ⬜ | **Not covered.** N=1024 correctness and PIPELINE-depth latency unproven |
| `rr_arbiter.sv` | — | ⬜ | **Not covered.** Fairness and the starvation counter unproven |
| `fixed_arbiter.sv` | — | ⬜ | **Not covered** |
| `clk_rst_gen.sv` | — | ⬜ | Wraps MMCM/BUFG; needs vendor sim (tier 4), not Verilator |
| `counter_bank.sv` | — | ⬜ | **Not covered.** Every telemetry counter flows through this |

### `rtl/eth/` — MAC

| Module | Test | Status | Notes |
| --- | --- | --- | --- |
| `crc32_eth.sv` | `tb/eth/test_crc32.py` | ✅ | IEEE check value, **all 8 partial-final-beat widths**, residue property over random frames, single-bit-error detection, beat-chunking invariance, `bytes==0` identity, randomized vs zlib |
| `mac_rx.sv` | — | ⬜ | **Not covered.** ⚠️ Cut-through-before-FCS and bad-FCS-on-`tuser`-at-`tlast` unproven — see §3.2 |
| `mac_tx.sv` | — | ⬜ | **Not covered.** ⚠️ The **abort path** is unproven: nothing shows an aborted frame is actually rejected by a receiver |
| `gt_wrapper_stub.sv` | — | n/a | Simulation stub for vendor GT IP |
| `eth_10g_wrapper.sv` | — | ⬜ | **Not covered** |

### `rtl/net/` — network RX

| Module | Test | Status | Notes |
| --- | --- | --- | --- |
| `net_rx_pkg.sv` | — | n/a | Package |
| `eth_ip_udp_rx.sv` | — | ⬜ | **Not covered.** ⚠️ VLAN / IHL>5 / fragment drop-and-count unproven — see §3.3 |
| `moldudp64_deframer.sv` | — | ⬜ | **Not covered.** ⚠️ Beat-straddle at all 8 alignments is the #1 ITCH defect class and is untested |
| `ab_arbiter.sv` | — | ⬜ | **Not covered.** ⚠️ First-arrival dedupe, true-gap vs duplicate, skew measurement all unproven |
| `net_rx_path.sv` | — | ⬜ | **Not covered** |

### `rtl/feed/` — feed handler

| Module | Test | Status | Notes |
| --- | --- | --- | --- |
| `itch_decoder.sv` | `tb/feed/test_itch_decoder.py` | ✅ | Scaffolding-owned (other team) |
| `symbol_filter.sv` | — | ⬜ | **Not covered.** 1-cycle direct-index property and out-of-range-locate handling unproven |
| `venue_state.sv` | — | ⬜ | **Not covered.** ⚠️ Halt/LULD/Reg SHO state machine entirely unverified — see §3.4 |
| `feed_handler.sv` | — | ⬜ | **Not covered** |

### `rtl/book/` — order book ⚠️ **THE RTL DOES NOT EXIST**

| Module | Test | Status | Notes |
| --- | --- | --- | --- |
| `book_pkg.sv` | — | ⬜ | RTL absent |
| `order_id_map.sv` | — | ⬜ | RTL absent; no test |
| `price_levels.sv` | — | ⬜ | RTL absent; no test |
| `top_of_book.sv` | — | ⬜ | RTL absent; no test |
| `book_engine.sv` | `tb/book/test_book_soak.py`, `tb/book/test_book_engine.py` | 🟡 | Tests written against the `fpga_top.sv` instantiation. **Cannot run until the RTL lands.** See §3.5 |

### `rtl/strategy/`

| Module | Test | Status | Notes |
| --- | --- | --- | --- |
| `strategy_pkg.sv` | — | n/a | Package (word map consumed by `test_param_table.py`) |
| `param_table.sv` | `tb/strategy/test_param_table.py` | ✅ | ⚠️ **Commit atomicity under continuous hammering**, commit-edge swept across every read offset, uncommitted-write invisibility, partial-record commit refused + counted, all 6 write-validation rules, fail-closed reset (all 256 entries), 1-cycle deterministic read |
| `trigger_logic.sv` | — | ⬜ | **Not covered.** Per-primitive threshold boundaries (`>=` vs `>`) unproven |
| `position_track.sv` | — | ⬜ | **Not covered.** ⚠️ `is_short` is a **Reg SHO Rule 201 compliance property** and is unverified |
| `trade_gate.sv` | — | ⬜ | **Not covered.** Per-reason rejection + fail-closed reset unproven |
| `strategy_engine.sv` | — | ⬜ | **Not covered** |

### `rtl/risk/` — 🔒 pre-trade risk

| Module | Test | Status | Notes |
| --- | --- | --- | --- |
| `risk_params.sv` | — | ⬜ | **Not covered.** Double-buffered limit atomicity unproven (the analogous strategy-side property IS proven) |
| `position_monitor.sv` | — | ⬜ | **Not covered.** ⚠️ Saturating-never-wrapping is only partially exercised, via `test_risk_adversarial` ATTACK 3 |
| `rate_limiter.sv` | — | ⬜ | **Not covered** directly. Sliding-window rollover and `PIPE_HEADROOM` unproven |
| `order_token_gen.sv` | — | ⬜ | **Not covered.** Token uniqueness/monotonicity — the only link to host accounting — unproven |
| `kill_switch.sv` | `tb/risk/test_risk_adversarial.py` (partial) | 🟡 | Mid-flight kill and stickiness covered; **per-source provenance, watchdog boundary, two-step re-arm, `EXT_DEBOUNCE_CYC` NOT covered** |
| `risk_gate.sv` | `tb/risk/test_risk_gate.py`, `tb/risk/test_risk_adversarial.py` | 🟡 | 8 adversarial attacks + fuzz with a global "emitted ⇒ all checks passed" invariant. Written before the RTL existed — **port list assumed, must be re-verified** |

### `rtl/order/` — order gateway

| Module | Test | Status | Notes |
| --- | --- | --- | --- |
| `ouch_pkg.sv` | — | n/a | Package |
| `ouch_encoder.sv` | `tb/order/test_ouch_encoder.py` | ⬜ | **Scaffolding file not yet written** by the other team |
| `ouch_rx.sv` | — | ⬜ | **Not covered** |
| `soupbin_tx.sv` | — | ⬜ | **Not covered** |
| `tcp_tx_lite.sv` | — | ⬜ | **Not covered** |
| `credit_mgr.sv` | — | ⬜ | **Not covered** directly (credit exhaustion probed from the risk side) |
| `order_gateway.sv` | — | ⬜ | **Not covered** |

### `rtl/telemetry/`, `rtl/ctrl/`

| Module | Test | Status | Notes |
| --- | --- | --- | --- |
| `latency_hist.sv` | — | ⬜ | **Not covered.** The histogram is how p99.9 is reported; a wrong bucket edge silently misreports latency |
| `telemetry.sv` | — | ⬜ | **Not covered** |
| `counter_bank.sv` | — | ⬜ | **Not covered** |
| `csr_regfile.sv` | — | ⬜ | **Not covered** |
| `dma_log_ring.sv` | — | ⬜ | **Not covered** |
| `pcie_wrapper.sv` | — | n/a | Vendor IP; tier 4 |
| `host_ctrl.sv` | — | ⬜ | **Not covered.** All host→fabric CDC lives here |

### Cross-cutting

| Target | Test | Status | Notes |
| --- | --- | --- | --- |
| Master latency budget | `tb/integration/test_latency_budget.py` | ✅ | Budget **parsed from `fpga_top.sv`'s header**, never hardcoded. Per-stage equality for fixed stages, bounded for `book_update`, end-to-end total, jitter bound, budget-table self-consistency, package-mirror guard. Skips missing stages **loudly** and fails if it measured nothing |
| Tick-to-trade path | `tb/integration/test_tick_to_trade.py` | ⬜ | **Not written** |
| Fault injection | `tb/integration/test_fault_injection.py` | ⬜ | **Not written** |
| Simulated venue | `tb/integration/sim_venue.py` | ⬜ | **Not written** |

---

## 2. What this pass added

| File | Invariant proven |
| --- | --- |
| `tb/common/tb_util.py` | Shared foundation: latency budget **parsed from `fpga_top.sv`**, deterministic seeding, scoreboard with first-divergence reporting, coverage DB, stream-contract and no-backpressure checkers, counter-delta checks, package-mirror drift guard |
| `tb/common/test_skid_buffer.py` | 100% throughput; contract never violated; 1-cycle fixed latency; no loss/dup/reorder under any stall shape |
| `tb/eth/test_crc32.py` | IEEE 802.3 CRC-32 exact for **all 8 partial-beat widths**; residue property; single-bit-error detection |
| `tb/strategy/test_param_table.py` | **Double-buffered commit is atomic** — no torn record under continuous hammering; fail-closed reset; all write-validation rules |
| `tb/book/test_book_soak.py` | RTL vs golden book after **every** message, with an adversarial generator whose hard-case density is itself asserted |
| `tb/risk/test_risk_adversarial.py` | **Every attempt to smuggle an order past the risk gate fails**, with the correct reason code and counter |
| `tb/integration/test_latency_budget.py` | Every stage's cycle count against the budget table; a new pipeline stage fails the build |

---

## 3. ⚠️ The gaps that matter most

Ranked by expected cost of the bug going undetected.

### 3.1 `async_fifo.sv` — every CDC on the design crosses it
Untested. This FIFO carries market data from the MAC clock into the core domain
and orders back out. RTL simulation cannot see metastability at all
(05-verification §9), so the *functional* properties — no loss, no duplication,
strict ordering, conservative flags — are the only thing simulation can prove,
and none of them is currently proven. **The nearly-equal-clock-frequency case
(6.4 ns vs 6.401 ns) is the one that finds gray-pointer comparison bugs**, and it
is exactly the case nobody writes by hand.

### 3.2 `mac_rx.sv` cut-through / bad-FCS flagging
The design forwards payload into the decoder **before** the FCS is known. That
bargain is only safe if a bad FCS reliably raises `tuser` at `tlast`. Untested,
a corrupt frame's prices enter the order book and stay there.

### 3.3 `eth_ip_udp_rx.sv` — the attack surface
VLAN, IHL>5, and fragmented packets must be **dropped and counted, never
mis-parsed**. A VLAN frame parsed with headers shifted by 4 bytes yields
plausible-looking garbage. Untested.

### 3.4 `venue_state.sv` — halts, LULD, Reg SHO
Entirely unverified. This is what stops the system quoting into a halted stock,
and `is_short`/SSR handling is a **compliance** control. The `'h'` operational
halt (distinct from `'H'`) is the classic omission.

### 3.5 The order book does not exist
`rtl/book/` is the **only** block in `filelist.f` with no RTL at all, while
everything else has landed. The project's highest-value test
(`test_book_soak.py`) is written and its stimulus generator is validated
(§4.1) — but it cannot run. **This is the critical path for verification.**

### 3.6 Order gateway is wholly untested
`ouch_encoder`, `ouch_rx`, `soupbin_tx`, `tcp_tx_lite`, `credit_mgr`,
`order_gateway` — nothing. This is the code that puts bytes on the wire to the
venue. OUCH byte-layout conformance needs golden vectors traceable to numbered
spec sections (06-operations/04 §3).

### 3.7 No integration or fault-injection tests
`test_tick_to_trade.py`, `test_fault_injection.py`, `sim_venue.py` are unwritten.
Nothing currently proves an ITCH frame in produces an OUCH order out, nor that
the **arming sequence is fail-closed** if any step is skipped.

---

## 4. Findings

### 4.1 The adversarial generator caught its own weakness
`test_book_soak.py` asserts that each adversarial case fires ≥50 times. On the
first run `empty_a_side` fired **too rarely to be meaningful** — emptying a book
side cannot be reached by a per-message probability; the side must be drained
order by order. Fixed with an explicit drain mode. Now every case fires
1000–4000 times per 30k messages, and the oracle reports zero `unknown_ref` /
`execute_overflow` / `bad_length`, confirming the stream is strictly legal ITCH.

### 4.2 `trading_pkg.sv` changed under the suite
`CORE_CLK_MHZ = 156.25` / `CORE_CLK_NS = 6.400` (typed `real`) became
`CORE_CLK_KHZ = 156_250` / `CORE_CLK_PS = 6_400` (integer) — correctly, since
CLAUDE.md §5.3 bans floating point. Physical values unchanged, so nothing broke;
**nothing would have caught it either.** `tb_util.assert_package_mirror()` now
guards all 17 mirrored constants and is called from the latency gate.

### 4.3 `rtl/formal/fv_axis_props.sv` is outside `filelist.f`
`filelist.f` is documented as *"THE canonical compile order"*, consumed by
`build.tcl`, `lint.sh`, and every cocotb Makefile. A source outside it is not
linted and not built. Either add it or document why it is excluded.

### 4.4 `filelist.f` currently references five non-existent files
The five `rtl/book/*.sv` entries. Any tool that consumes `filelist.f` literally
(`verilator -f rtl/filelist.f`) fails today. `tb_util.parse_filelist()`
deliberately skips missing entries so a partially-built tree still elaborates.

### 4.5 CRC residue: manual vs RTL, already reconciled
`manuals/02-networking/01-ethernet-phy-mac.md` quotes the residue as
`0xC704DD7B`; `crc32_eth.sv` implements the reflected register whose residue is
`0xDEBB20E3`. They are the same constant bit-reversed. The RTL header flags this
itself; `test_crc32.py` now **asserts** `bitrev(one) == other` so the two
conventions cannot silently diverge.

### 4.6 `tb_util.StreamContractChecker` assumes AXI-Stream names
It keys off `<prefix>_tvalid`/`_tdata`. `skid_buffer.sv` uses bare
`s_valid`/`s_data`, so `test_skid_buffer.py` carries a local checker. A
suffix-configurable checker in `tb/common/` would remove that duplication.

### 4.7 Port lists verified by elaboration
Every module named ✅ above was linted standalone under Verilator 5.050 with its
packages (`--lint-only -Wall`) and elaborates cleanly — only benign
`UNUSEDPARAM` noise from the packages. The port lists used by the ✅ tests are
therefore confirmed against the real RTL, not assumed.

---

## 5. How to trust this document

### 5.1 ⚠️ Nothing here has been executed
`cocotb` is **not installed** (`ModuleNotFoundError: No module named 'cocotb'`);
`verilator 5.050` is present. Every testbench is syntax-checked
(`python -m py_compile`) and every ✅ module is lint-verified, but **no
assertion in this suite has ever fired against a simulator.** Until
`pip install cocotb` and a green run, treat every ✅ as "written and reviewed",
not "passing". An untested testbench is a hypothesis.

The one exception: `test_book_soak.py --selftest` runs today without a simulator
and **does** pass (§4.1) — it validates the stimulus generator and the oracle,
which is half of that test's value available immediately.

### 5.2 Which tests can run the moment cocotb is installed
`test_crc32.py`, `test_skid_buffer.py`, `test_param_table.py` — real DUTs,
verified port lists. `test_latency_budget.py` will run and report a mostly-skipped
profile until the book lands. `test_book_soak.py` and `test_risk_adversarial.py`
need `rtl/book/` and a re-check of the assumed `risk_gate` port list respectively.

### 5.3 Recommended next actions, in order
1. `pip install cocotb` and get the three ✅ files green. Nothing else is
   meaningful until the suite can run.
2. Write `rtl/book/` — it blocks the project's highest-value test (§3.5).
3. Close §3.1 (`async_fifo`) and §3.2 (`mac_rx`) — the two silent-corruption
   paths.
4. Re-verify `test_risk_adversarial.py`'s assumed port list against the now-real
   `rtl/risk/risk_gate.sv` and clear its `# TODO(verify)` markers.
5. Write the integration tier (§3.7).
