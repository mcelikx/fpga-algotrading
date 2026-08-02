# CLAUDE.md

Project guide for Claude Code working in this repository.

---

## 1. What this project is

An **FPGA-accelerated algorithmic trading system**. The goal is a deterministic,
sub-microsecond **tick-to-trade** path: market data arrives on a wire, is decoded,
turned into a book update, evaluated by a strategy, and — if the strategy fires —
emitted as an order, entirely in hardware.

The project has two halves that must be kept honest with each other:

| Half | Runs on | Responsibility |
| --- | --- | --- |
| **Fast path** | FPGA fabric | Feed decode → book → strategy trigger → order encode → TX. Fixed latency, no dynamic allocation, no branching stalls. |
| **Slow path** | Host CPU | Strategy parameters, position/PnL accounting, reference data, order state reconciliation, logging, control plane, kill switch. |

Anything that does not need to be measured in nanoseconds belongs in the slow path.
Anything on the fast path must be justified against a latency budget
(see [manuals/05-optimization/01-latency-budgeting.md](manuals/05-optimization/01-latency-budgeting.md)).

---

## 2. Working defaults (assumptions — change here, not in code)

These were chosen so work can start. They are project-wide contracts; if one changes,
update this table **first**, then propagate.

| Decision | Default | Notes |
| --- | --- | --- |
| Primary FPGA family | AMD/Xilinx **UltraScale+** (Kintex/Virtex, e.g. VU9P-class) | Vivado flow. Alveo-class card or a dedicated trading NIC. |
| Secondary family | Intel **Agilex / Stratix 10** | Keep RTL vendor-neutral; isolate primitives behind wrappers. |
| RTL language | **SystemVerilog** (IEEE 1800-2017), synthesizable subset | No VHDL in new code. See [03-hdl-and-rtl-coding.md](manuals/00-foundations/03-hdl-and-rtl-coding.md). |
| Verification | **cocotb** + **Verilator** for unit/regression; vendor sim for gate-level | Python testbenches, pcap-driven. |
| Reference market data | **Nasdaq TotalView-ITCH 5.0**, **CME MDP 3.0 (SBE)** | Two shapes: fixed-field binary vs. templated SBE. |
| Reference order entry | **Nasdaq OUCH 5.0**, **CME iLink 3 (SBE)** | |
| Line rate | **10GbE** baseline, 25GbE forward-looking | 64-bit @ 156.25 MHz, or 32-bit @ 322 MHz for 25G. |
| Clocking | Single core clock domain for the datapath | CDC only at MAC/PCIe boundaries. |
| Number format | Fixed-point / integer only on fast path | No floating point in fabric. Prices as scaled integers. |
| Latency target | **< 1 µs** wire-to-wire, tick-to-trade | Stretch: < 500 ns for the trigger path. |
| Host interface | PCIe Gen3 x16 (DMA + BAR-mapped control regs) | Control plane is memory-mapped registers; data plane is DMA rings. |

**Nothing here is sacred.** If the real hardware or venue differs, edit this table and
say so in the commit message.

---

## 3. Repository layout

```
FPGA/
├── CLAUDE.md              ← you are here
├── TASKS.md               ← the executable plan, phased, with exit criteria
├── manuals/               ← the knowledge base; read before designing
│   ├── 00-foundations/    ← digital logic, FPGA architecture, HDL, clocking, timing
│   ├── 01-fpga-design/    ← RTL patterns, pipelining, memory, IO, verification, HLS
│   ├── 02-networking/     ← Ethernet, IP/UDP/TCP in hardware, multicast, kernel bypass
│   ├── 03-algotrading/    ← microstructure, matching, protocols, strategies, risk
│   ├── 04-system-architecture/ ← tick-to-trade, feed handler, book, strategy, gateway
│   ├── 05-optimization/   ← latency budget, Fmax, resources, measurement, playbook
│   ├── 06-operations/     ← build/release, deployment, monitoring, test strategy
│   ├── 07-reference/      ← glossary, latency numbers, toolchain, checklists
│   └── 08-nasdaq/         ← VENUE REFERENCE: rules, ITCH/OUCH, Reg NMS, risk limits
├── rtl/
│   ├── pkg/               ← trading_pkg.sv, itch_pkg.sv — THE interface contract
│   ├── common/            ← CDC, FIFOs, skid buffers, arbiters — the ONLY sanctioned primitives
│   ├── eth/               ← GT/PCS wrapper, cut-through MAC, CRC32
│   ├── net/               ← Ethernet/IP/UDP strip, MoldUDP64 deframe, A/B arbitration
│   ├── feed/              ← ITCH decoder, symbol filter, venue state
│   ├── book/              ← order-ID map, price levels, incremental top-of-book
│   ├── strategy/          ← parameter table, trade gate, trigger primitives
│   ├── risk/              ← 🔒 pre-trade risk gate, kill switch, position monitor
│   ├── order/             ← OUCH encoder, SoupBinTCP, TCP fast send, credit manager
│   ├── ctrl/              ← PCIe control plane, CSR register file, DMA log ring
│   ├── telemetry/         ← counters and the on-chip latency histogram
│   └── fpga_top.sv        ← top level; its header holds the master latency budget
├── tb/                    ← cocotb testbenches, golden software book, pcap fixtures
├── host/                  ← slow-path software: control daemon, reconciler, logger
├── constraints/           ← XDC: clocks, CDC, IO, floorplan, timing exceptions
├── scripts/               ← build.tcl, seed sweep, QoR parsing, lint
└── docs/                  ← design decisions, ADRs, measured latency reports
```

**`rtl/fpga_top.sv` is the integration contract.** Its header comment holds the
master per-stage latency budget and the resource budget; `rtl/pkg/trading_pkg.sv`
holds every cross-block type. Changing either is a system-wide change — say so
explicitly and update the budget in the same commit.

---

## 4. How to work in this repo

### Before writing RTL
1. Read the relevant manual section. The manuals encode the constraints that make
   the design correct *and* fast; skipping them produces code that synthesizes but
   misses timing or blows the latency budget.
2. State the **latency budget** for the block in nanoseconds and cycles, in the
   module header comment. A block without a budget is not reviewable.
3. State the **resource budget** (LUT/FF/BRAM/URAM/DSP) in the same header.

### While writing RTL
- **Every module gets a testbench.** No exceptions on the fast path.
- **Registered outputs by default.** Combinational output ports are opt-in and must
  be justified in a comment.
- **No latches, ever.** Full `case` with `default`, full `if/else`.
- **Reset**: synchronous, active-high, and only where it's needed. Datapath
  registers generally do not need reset; control/state registers do.
- **One clock domain** for the datapath. Any CDC uses the sanctioned primitives in
  `rtl/common/cdc/` (2-FF sync for single bits, gray-coded async FIFO for buses,
  handshake for slow control). Never hand-roll a synchronizer.
- **Fixed-latency preferred over variable-latency.** Determinism (low jitter) is
  worth more than a lower mean.
- Parameterize widths; never hardcode `64`.

### After writing RTL
- Run lint (Verilator `-Wall`) → sim → synth → P&R, in that order. Do not report
  "done" until place-and-route timing closes.
- Report **WNS/TNS** and utilization from the actual report, quoted verbatim.
  Never estimate or predict these.

### Reporting results
- Quote real tool output. If synthesis failed, say it failed and paste the error.
- If a latency number was simulated, say "simulated". If measured on hardware, say
  "measured, N=…". These are not interchangeable.

---

## 5. Hard rules on the fast path

These are non-negotiable design constraints. Violations are bugs even if the design
functions.

1. **No dynamic memory.** All storage is statically sized at elaboration.
2. **No unbounded loops.** Every loop bound is a compile-time constant.
3. **No floating point.** Scaled integers; document the scale factor.
4. **No backpressure stalls into the MAC RX.** The receive path must accept line
   rate unconditionally; drop deliberately and count drops, never block.
5. **Pre-trade risk is in hardware and cannot be bypassed.** Every outbound order
   passes through the risk block. There is no software path that emits orders
   without it. See [05-order-gateway-and-pre-trade-risk.md](manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md).
6. **The kill switch is hardware-enforced.** A single register write must stop all
   outbound order flow within a bounded, documented number of cycles.
7. **Every drop, error, and rejected order is counted** in a readable register.
   Silent failure is the worst failure mode in this domain.
8. **Determinism over average speed.** Report p50/p99/p99.9/max, never just the mean.

---

## 6. Risk, safety, and scope

This is a real-money trading system. Treat it accordingly:

- **Never** wire a build to a live venue session. Simulated/UAT endpoints only,
  unless the user explicitly and specifically instructs otherwise for a given task.
- Changes to risk limits, order sizing, or the kill switch are high-blast-radius.
  Flag them, and do not bundle them with unrelated work.
- Exchange protocol specs and conformance requirements are authoritative. If a
  manual here contradicts the venue spec, the venue spec wins — and the manual
  should be corrected.
- Do not commit venue credentials, session IDs, comp IDs, or production IPs.

---

## 7. Optimization loop

The intended workflow for the optimization phase of this project:

```
measure → attribute → hypothesize → change one thing → re-measure → keep or revert
```

- Measurement methodology and the required instrumentation are in
  [manuals/05-optimization/04-measurement-and-profiling.md](manuals/05-optimization/04-measurement-and-profiling.md).
- The ordered list of optimization techniques, cheapest-first, is in
  [manuals/05-optimization/05-optimization-playbook.md](manuals/05-optimization/05-optimization-playbook.md).
- **Do not optimize without a measurement.** Intuition about FPGA latency is
  reliably wrong; the tools' reports are not.

---

## 8. Manual index

Start at [manuals/README.md](manuals/README.md) for the reading order and a
one-line description of every document.
