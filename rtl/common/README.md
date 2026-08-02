# `rtl/common` — the shared primitive library

This directory holds the project's sanctioned building blocks: the clock/reset
generator, the four CDC primitives, the two FIFOs, the stream register slice, the
delay line, the priority encoder, the two arbiters, and the telemetry counter
bank (saturating arithmetic lives alongside the other packages, in
[`rtl/pkg/sat_arith_pkg.sv`](../pkg/sat_arith_pkg.sv)). **These are the ONLY
sanctioned CDC and flow-control primitives in the design.** CLAUDE.md §4 states
it plainly — "Any CDC uses the sanctioned primitives in `rtl/common/cdc/` (2-FF
sync for single bits, gray-coded async FIFO for buses, handshake for slow
control). Never hand-roll a synchronizer" — and
[`manuals/00-foundations/04-clocking-reset-and-cdc.md`](../../manuals/00-foundations/04-clocking-reset-and-cdc.md)
§3 names them one by one. A hand-rolled synchronizer, a private FIFO, a local
`always_ff @(posedge clk or posedge rst)`, or a bare `+` on a position counter is
a **review failure**, not a style preference: CDC and saturation bugs pass
simulation, pass timing, pass a week of soak testing, and then corrupt one order
in ten million on a hot afternoon. If a primitive here does not fit your case,
extend it here and re-review it — do not fork it into your block. (CLAUDE.md
places the CDC primitives under `rtl/common/cdc/`; this library realizes them as
the `cdc_*.sv` files in this directory. Same rule, flatter tree.)

## Index

| File | What it is | Latency | Use it for |
| --- | --- | --- | --- |
| [`clk_rst_gen.sv`](clk_rst_gen.sv) | MMCM wrapper: 100 MHz ref → `core_clk` 156.25 MHz + `pcie_clk` 250 MHz, plus a `reset_sync` per domain. Behavioural clock under `` `ifdef SIMULATION ``. | n/a | Top level only, once. |
| [`reset_sync.sv`](reset_sync.sv) | Async assert / sync de-assert reset synchronizer. The only asynchronous `always_ff` in the project. | 0 to assert, 2+ cyc to release | One instance per clock domain. |
| [`cdc_sync_bit.sv`](cdc_sync_bit.sv) | N-stage single-bit level synchronizer with `ASYNC_REG`. | STAGES cyc | **One bit only**, source stable ≥2 dst periods. |
| [`cdc_pulse.sv`](cdc_pulse.sv) | Toggle pulse synchronizer with an ack loop and `src_busy`. | ~3 dst cyc | Single-cycle events. Rate limited — respect `src_busy`. |
| [`cdc_handshake.sv`](cdc_handshake.sv) | 4-phase req/ack for a wide bus; data is held stable, not synchronized. Carries the XDC snippet for `constraints/cdc.xdc`. | ~5 dst cyc, ~10 cyc round trip | Infrequent control/config writes. |
| [`async_fifo.sv`](async_fifo.sv) | Gray-coded dual-clock FIFO with `wr_high_water` telemetry. | ~3 cyc crossing + 1 cyc read | **Any multi-bit data crossing.** The default. |
| [`sync_fifo.sv`](sync_fifo.sv) | Single-clock FIFO, `high_water` + sticky overflow/underflow. | 1 cyc read | Elastic buffering inside `core_clk`. Not a CDC. |
| [`skid_buffer.sv`](skid_buffer.sv) | Valid/ready register slice, 100 % throughput. | 1 cyc | Breaking a long `ready` chain. Never on MAC RX. |
| [`delay_line.sv`](delay_line.sv) | SRL-inferring delay; data **unreset** (so it maps to SRL32), valid path reset. | DEPTH cyc | Matching pipeline depths. |
| [`prio_encoder.sv`](prio_encoder.sv) | Two-level group/sub-group priority encoder, optional `PIPELINE`. Scales to N=1024. | 0/1/2 cyc | Order book "find the new best level"; arbiter cores. |
| [`rr_arbiter.sv`](rr_arbiter.sv) | Round-robin arbiter, bounded wait. | 0 cyc (comb grant) | Fair sharing off the fast path. |
| [`fixed_arbiter.sv`](fixed_arbiter.sv) | Fixed-priority arbiter (0 = highest) with per-requester `starve_cnt`. | 0 cyc (comb grant) | The fast path — determinism over fairness. |
| [`counter_bank.sv`](counter_bank.sv) | N × 48-bit saturating event counters, read port, sticky or clear-on-read. | 1 cyc read | All telemetry (CLAUDE.md §5.7). |
| [`../pkg/sat_arith_pkg.sv`](../pkg/sat_arith_pkg.sv) | Saturating add/sub for positions, notionals, quantities and counters, each returning a `saturated` flag. | comb | **All** position and risk arithmetic. |

## The three rules that get people

1. **A 2-FF synchronizer works for one bit and one bit only.** Per-bit chains on
   a bus produce values that never existed in the source domain. Bus → use
   `async_fifo` or `cdc_handshake`.
2. **Never `set_false_path` a CDC data bus.** Use `set_max_delay -datapath_only`
   plus `set_bus_skew`; the snippet is in the `cdc_handshake.sv` header, ready to
   copy into `constraints/cdc.xdc`. Run `report_cdc` on every build and treat
   findings as errors — STA does not check CDC by definition.
3. **Never wrap a position counter.** Use `sat_arith_pkg` and count every
   `saturated` event. A wrapped position turns a risk check into a no-op, which
   is the difference between a bug and a regulatory incident.

Every module here carries its own latency and resource budget, its ⚠️ caveats,
and SVA assertions under `` `ifndef SYNTHESIS ``. Read the header before you
instantiate; the caveats are the part that took the longest to learn.
