# 01.06 — HLS and Alternative Flows

> **Why this matters here:** every alternative to hand-written SystemVerilog trades
> control for productivity. On the slow path that is an excellent trade. On the
> tick-to-trade path, "control" means *knowing exactly how many cycles a block takes
> and being able to remove one*, which is the entire job. This document says where
> each flow is allowed in this codebase, and why.

---

## 1. The flows on the table

| Flow | Input | Output | Who controls pipeline depth |
| --- | --- | --- | --- |
| **Hand-written SystemVerilog** | RTL | RTL | **You**, per register |
| **Vitis HLS / Intel HLS** | C/C++ with pragmas | Generated RTL | The scheduler |
| **Chisel / SpinalHDL / Amaranth** | Scala / Python generator | Generated RTL | **You** — they are RTL, just elaborated by a program |
| **Vendor IP (wizards)** | GUI/Tcl configuration | Encrypted or open RTL | The vendor |
| **Open-source cores** | RTL you vendor in | RTL | Whoever wrote it — but you can read and edit it |

The critical distinction is **row 2 vs. row 3**. HLS is a *compiler*: it decides
where registers go. Chisel/SpinalHDL/Amaranth are *generators*: you still write
registers explicitly, in a nicer language. Those are completely different risk
profiles, and conflating them is the most common mistake in this conversation.

---

## 2. HLS: what it is genuinely good at

Vitis HLS (AMD) and the Intel HLS Compiler take C/C++ and schedule it into a
finite-state machine plus a datapath. For the right problem, it is a large
productivity win and produces hardware you would struggle to beat by hand.

| Good fit | Why HLS wins |
| --- | --- |
| **DSP-shaped math** — FIR filters, moving averages, covariance updates, matrix ops | HLS knows how to map to DSP slices, pipeline multiply-accumulate chains, and balance adder trees. Hand-writing a 64-tap filter is tedious and error-prone. |
| **Complex, control-heavy slow-path logic** | A session-layer recovery state machine with 40 states is 200 lines of C and 2,000 lines of readable-but-tedious SystemVerilog |
| **Rapid architectural exploration** | Write the algorithm, get a latency/area estimate in an hour, decide whether it's worth hand-writing. This is HLS's highest-value use in this project. |
| **Analytics and post-trade computation in fabric** | Rolling volatility, PnL attribution, histogram aggregation — none of it latency-critical |
| **Anything already written in C that you want to move to fabric** | Reuse of an existing, tested algorithm |

**Use it as a design tool even where you won't ship it.** Prototyping a strategy's
arithmetic in HLS to find out whether it needs 3 DSPs or 300 is an hour of work and
saves days of hand-written exploration.

---

## 3. Why HLS is a poor fit for the tick-to-trade datapath

Six concrete reasons, in order of severity.

### 3.1 You do not choose the pipeline depth
The scheduler places registers according to its internal delay model and your
target clock period. You can influence it (`#pragma HLS LATENCY`, changing the
target period) but you cannot say "this operation completes in exactly 2 cycles".

⚠️ **A tool version bump re-schedules your design.** Vivado/Vitis 2023.x and
2024.x can produce different cycle counts from identical C. In a system where 6.4 ns
is a budget line item, a latency you cannot pin is a latency you cannot budget, and
a silent latency regression on a tool upgrade is exactly the failure this project
cannot absorb.

### 3.2 II is a request, not a guarantee
`#pragma HLS PIPELINE II=1` asks for initiation interval 1. If the scheduler cannot
achieve it — a memory port conflict, a loop-carried dependence, a resource limit —
it **emits a warning and delivers II=2 or worse**, and synthesis succeeds.

⚠️ On the RX path, II must be 1 or you drop market data
([02-pipelining-and-parallelism.md](02-pipelining-and-parallelism.md) §2). A
warning buried in a 4,000-line log is not an adequate guard for that requirement.
If you ship HLS anywhere near a streaming path, **CI must parse `csynth.rpt` and
fail the build on II ≠ target.**

### 3.3 Interface overhead you did not write
The default block-level protocol `ap_ctrl_hs` gives every function an
`ap_start` / `ap_ready` / `ap_done` / `ap_idle` handshake. That is a per-invocation
cost in cycles for something you wanted to be a free-running pipeline. Port-level
adapters (`m_axi` burst logic, `s_axilite` register decode) add more.

The only HLS shape that behaves like a streaming RTL block is:
`ap_ctrl_none` + `hls::stream` with `axis` interfaces + `PIPELINE II=1`. Anything
else is paying handshake latency.

### 3.4 Fixed latency is hard to guarantee
HLS is happy to generate variable-latency control flow (a loop whose trip count
depends on data, an `if` that skips work). That is normally a feature. Here it is
jitter, and jitter is the thing we are selling determinism against
([00-foundations/01-digital-logic-and-timing.md](../00-foundations/01-digital-logic-and-timing.md) §5).

### 3.5 Debugging is indirect
The generated Verilog has names like `grp_process_fu_142`. ILA-probing it, reading
its timing report, and mapping a critical path back to a line of C is genuinely
painful. On a block you will optimize for months, this compounds.

### 3.6 Vendor lock
Vitis HLS C++ is not Intel HLS C++ — different pragma syntax, different interface
models, different libraries. The project's stated secondary target is Intel Agilex.
Hand-written SystemVerilog ports; HLS source does not.

---

## 4. HLS pragma essentials (for where it *is* allowed)

| Pragma | Effect | Notes for this project |
| --- | --- | --- |
| `#pragma HLS PIPELINE II=1` | Pipeline the enclosing loop/function | The one you always want. **Verify it was achieved in the report.** |
| `#pragma HLS UNROLL factor=N` | Replicate loop body | Full unroll for small fixed loops; costs area linearly |
| `#pragma HLS ARRAY_PARTITION variable=a complete dim=1` | Split an array into registers or separate memories | The fix for "unable to schedule load due to limited memory ports". `cyclic`/`block` for partial |
| `#pragma HLS INTERFACE mode=ap_ctrl_none port=return` | Remove the block-level handshake → free-running | **Mandatory** for any streaming HLS block here |
| `#pragma HLS INTERFACE mode=axis port=in` | AXI4-Stream with TVALID/TREADY | The only interface that composes with the datapath |
| `#pragma HLS INTERFACE mode=ap_none port=param` | Raw wire, no handshake | For stable parameter inputs |
| `#pragma HLS INTERFACE mode=s_axilite port=ctrl` | AXI4-Lite register file | Control plane only |
| `#pragma HLS INTERFACE mode=m_axi ...` | AXI master with burst inference | ⚠️ **Never on or near the fast path** — it implies external memory |
| `#pragma HLS DATAFLOW` | Run sub-functions concurrently, connected by channels | Powerful for slow-path processing chains; adds channel FIFOs (and their latency) |
| `#pragma HLS DEPENDENCE variable=a inter false` | Assert a loop-carried dependence doesn't exist | ⚠️ **This is you promising the tool something.** If the dependence is real, HLS builds silently-wrong hardware. Prove it before you write it. |
| `#pragma HLS INLINE` / `INLINE off` | Control function boundaries | `INLINE off` keeps a module boundary you can find in the report |
| `#pragma HLS BIND_OP op=mul impl=dsp latency=2` | Force an operator implementation | Use when the tool picks LUTs over DSPs or vice versa |

### Reading the schedule report

The file is `<project>/<solution>/syn/report/<top>_csynth.rpt`. Read it in this
order:

1. **Timing Estimate** — "Estimated" vs "Target". If Estimated > Target, the design
   will not close timing and everything below is fiction.
2. **Latency (cycles): min / max** — if min ≠ max, **you have a variable-latency
   block.** On or near the fast path, that is a defect. Find the data-dependent
   control flow and remove it.
3. **Interval (cycles): min / max** — this is your II. Compare against what you
   asked for.
4. **Loop table** — per-loop trip count, latency, achieved II, and a "Pipelined
   yes/no" column. This is where an un-pipelined inner loop hides.
5. **Utilization estimates** — treat as a rough guide only; real numbers come from
   Vivado synthesis of the generated RTL.
6. **The console log / `vitis_hls.log`** — search for `WARNING: [HLS 200-...]`.
   The important ones:
   - `Unable to enforce a carried dependence constraint` → real loop-carried
     dependence; restructure, or `DEPENDENCE` only if you can prove it false
   - `Unable to schedule 'load' operation ... due to limited memory ports` →
     `ARRAY_PARTITION`
   - `Unable to satisfy pipeline directive: II = N (target II = 1)` → your II
     request was silently downgraded

The **Schedule Viewer** in the GUI shows every operation's cycle assignment and
will tell you *which* dependency forced an II violation. It is the only efficient
way to debug an II problem.

**Project rule:** any HLS block that ships must have its `csynth.rpt` latency and
II values committed to `docs/` alongside the source, and CI must re-check them.
An HLS block whose latency is not written down is not reviewable.

---

## 5. Chisel, SpinalHDL, Amaranth — the generator argument

| | Chisel | SpinalHDL | Amaranth |
| --- | --- | --- | --- |
| Host language | Scala | Scala | Python |
| Emits | Verilog (via FIRRTL/CIRCT) | VHDL **and** Verilog | Verilog |
| Maturity / ecosystem | Largest (Rocket, BOOM, SiFive) | Smaller, very capable | Youngest |
| Generated code readability | Poor — machine names everywhere | **Good** — deliberately readable output | Moderate |
| Built-in helpers | Decoupled/Valid interfaces, Queue | Decoupled/Flow, **CDC helpers, formal helpers, clock domains as first-class** | Streams, FSM DSL |
| Vendor attribute / constraint escape hatches | Awkward | Reasonable | Reasonable |
| Testbench story | ChiselTest / verilator | Same | **cocotb-native — same language as our TB** |
| Toolchain burden | JVM + sbt | JVM + sbt | pip |

### The real argument for them

It is **not** productivity. It is **one source of truth**. Consider the
set-associative order-reference table from
[03-memory-and-storage.md](03-memory-and-storage.md) §7. It has: a way count, a set
count, a tag width derived from the key width and set count, a hash polynomial, a
payload layout, and a victim-CAM depth. Those same parameters must appear in:

- the RTL,
- the golden model in `tb/model/`,
- the host software's view of the table for initialization and readback,
- the register map documentation,
- the constraints (memory primitive choice, pblock sizing).

SystemVerilog `parameter` + `generate` can build the RTL, but it cannot emit the
Python model, the C++ header, or the register map. A generator can emit all five
from one config object, and they cannot drift.

### The argument against them, for this project

1. **Debugging happens in the generated Verilog.** Vivado's timing report, the
   Device view, and the ILA all speak Verilog. If the generated names are opaque,
   every timing-closure session is worse.
2. **The fast path is small and heavily hand-tuned.** The parser, book, strategy,
   risk gate, and encoder are perhaps a few thousand lines of RTL that you will
   revise dozens of times chasing nanoseconds. Generator indirection is friction
   exactly where you least want it.
3. **Vendor attributes matter here** (`RAM_STYLE`, `SHREG_EXTRACT`, `DONT_TOUCH`,
   `KEEP_HIERARCHY`, `MAX_FANOUT`). Every generator has an escape hatch for them,
   and every escape hatch is uglier than writing the attribute.
4. **Another toolchain to pin, version, and reproduce** in the build
   ([06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md)).

### The recommendation

**Get the one-source-of-truth benefit without the generator toolchain: use a small
Python + Jinja2 generator that emits plain, readable SystemVerilog**, plus the
matching Python model, C++ header, and register-map markdown, from a single YAML
config. You keep hand-readable RTL, keep vendor attributes natural, keep the
debugging story intact, and eliminate the drift.

If you do adopt one of these languages, **SpinalHDL** is the best fit (readable
output, first-class clock domains and CDC helpers) and **Amaranth** is the best fit
if the deciding factor is sharing Python with the cocotb testbench.

Non-negotiable if you generate RTL by any means:
- **The generated RTL is committed to the repository**, alongside its generator.
- **The generator is deterministic** — no timestamps, no dict-ordering
  nondeterminism, no absolute paths in the output. A rebuild must produce a
  byte-identical file, or reproducible bitstreams are impossible.
- **CI regenerates and diffs.** A commit where the checked-in RTL doesn't match
  what the generator produces fails the build.

---

## 6. Vendor IP: when to use it, and the case for a hand-written MAC

| Block | Verdict | Reasoning |
| --- | --- | --- |
| **PCIe hard block + DMA (XDMA / QDMA)** | **Always vendor.** | It is a hard block wrapped in an enormous protocol. It is slow path, so there is no latency argument. Hand-rolling it is months of work and unbounded risk. |
| **GT transceiver wrapper** | **Always vendor** (Transceiver Wizard) | You cannot meaningfully instantiate and reset a GTY otherwise. Configure it for low latency (§ [04-io-transceivers-and-serdes.md](04-io-transceivers-and-serdes.md) §3) and wrap it. |
| **10G/25G PCS** | **Vendor initially.** | Hand-rolled 64b/66b block sync + descramble is possible and saves ns, but you inherit block lock, hi-BER monitoring, and fault handling. Do it only if measurement puts the PCS in your top three line items — it usually isn't. |
| **Ethernet MAC** | **Hand-write.** See below. | The one place where a small amount of RTL buys real, measurable nanoseconds and capabilities the vendor core does not expose. |
| **Sync / async FIFO** | **Vendor XPM** (`xpm_fifo_sync`, `xpm_fifo_async`) | XPM async FIFOs come with correct CDC constraints. Hand-rolled async FIFOs are a classic source of once-a-week, undebuggable failures. This is not the place to be clever. |
| **Memories** | **XPM_MEMORY**, primitive pinned explicitly | You need explicit control over `READ_LATENCY` and `MEMORY_PRIMITIVE` ([03-memory-and-storage.md](03-memory-and-storage.md) §3) |
| **MMCM / PLL / clock buffers** | Vendor primitive, behind a thin wrapper | Isolate for Agilex portability |
| **AXI Interconnect / SmartConnect** | **Slow path only.** Never on the datapath. | Arbitrary, unbounded latency by design |
| **Floating-point / math IP** | N/A | No floating point on the fast path, ever |

### The specific case for hand-writing a cut-through MAC

The folklore claim is "vendor MACs are store-and-forward, so they add a full frame
time". Modern AMD 10G/25G subsystem MACs generally **do** stream on RX with a late
error indication on the last beat, so that claim is weaker than it is usually
stated.

> **Verify:** whether *your* configuration of the AMD 10G/25G Ethernet Subsystem
> presents RX data as it arrives with a `rx_axis_tuser` error flag on `tlast`, and
> what its published RX/TX latency is — PG210 latency tables, then confirmed by
> simulating the core against a raw-PCS reference and counting cycles.

The real, defensible wins from a hand-written MAC are:

1. **Fusing the MAC with the first parse stage.** A vendor MAC presents you a clean
   Ethernet frame, then *you* start parsing the Ethernet/IP/UDP/MoldUDP64 headers.
   A fused block strips the preamble/SFD and decodes EtherType, IP protocol, and
   UDP port **in the same cycles**. That is a genuine multi-cycle saving that no
   vendor core will ever give you, because it requires knowing your protocol stack.
2. **Removing the vendor core's internal pipeline stages and FIFOs**, which exist
   for generality you do not need (VLAN handling, pause frames, jumbo support,
   statistics you don't read, a configurable interface width).
3. **Aborting a frame in flight** by deliberately corrupting the outgoing FCS. This
   is what makes speculative transmission
   ([02-pipelining-and-parallelism.md](02-pipelining-and-parallelism.md) §5) possible.
   Vendor MACs generally do not expose it.
4. **Starting TX before the payload is finalized**, for the same reason.

**Rule:** start with the vendor MAC, measure it in hardware loopback, and hand-write
a replacement only against a number. "Vendor IP is slow" is not a number.
⚠️ Do not begin the project by writing a MAC — you will spend two weeks on
something that might buy 15 ns, while the elastic buffer bypass sitting untouched
in the GT config is worth 40.

---

## 7. Open-source cores worth knowing

| Project | What | Why it matters here |
| --- | --- | --- |
| **`alexforencich/verilog-ethernet`** | 1G/10G/25G/100G MAC + PCS in plain Verilog | The reference low-latency open MAC. Readable, well-structured, widely deployed. Excellent to read even if you write your own. |
| **`alexforencich/taxi`** | The same author's newer SystemVerilog Ethernet/IO library | Successor work; check maturity for your rate |
| **`corundum`** | Full open-source 100G NIC platform (Alveo, Agilex) | Even if you don't use it, its PCIe/DMA and queue architecture is the best available reference for the host interface |
| **`alexforencich/verilog-pcie`** | PCIe DMA components layered on the vendor hard block | A middle path between vendor XDMA and rolling your own |
| **`cocotbext-axi` / `-eth` / `-pcie`** | cocotb bus models, same author | Testbench side — saves writing AXI-Stream and Ethernet models by hand |
| **LiteX / LiteEth** | Migen-based SoC and Ethernet generator | Generator-based, mostly 1G-focused; good ideas, wrong rate for us |

> **Verify:** each project's licence (verilog-ethernet and Corundum are MIT at time
> of writing, but check), current maintenance status, and support for your exact
> device family and line rate. **Pin a specific commit hash and vendor the code into
> `rtl/third_party/`** — do not use a submodule that can move under you. Record the
> hash in the build manifest.

⚠️ Open-source cores are read-and-adopt, not trust-and-forget. Anything on the fast
path gets the same review, the same testbench, and the same assertions as code you
wrote. If you can't afford to review it, you can't afford to run it.

---

## 8. PROJECT POLICY

This is the normative section. Everything above is justification.

| Zone | Permitted flows | Forbidden |
| --- | --- | --- |
| **Fast path** — MAC RX → parser → symbol table → book → strategy → risk gate → order encoder → MAC TX | Hand-written SystemVerilog. XPM memory/FIFO primitives. The GT wizard wrapper. Reviewed, vendored open-source RTL. | **HLS. AXI Interconnect/SmartConnect. `m_axi` anything. Any IP whose cycle latency is not documented. Generated RTL that is not committed and diffed in CI.** |
| **Near path** — telemetry, latency histograms, capture, counters, packet journal | Hand-written SystemVerilog preferred; committed generated SystemVerilog allowed | HLS unless the block is provably off the latency path and behind a skid buffer |
| **In-fabric slow path** — control registers, table loading, OUCH session layer bookkeeping, analytics, statistics aggregation | **HLS permitted.** Vendor IP permitted. Generated RTL permitted. | — |
| **Host interface** — PCIe, DMA rings, BAR register file | **Vendor PCIe/DMA IP mandatory.** | Hand-rolled PCIe. Custom DMA engines. |
| **Host software** — `host/` | C++ / Rust / Python, whatever fits | — |
| **Testbench** — `tb/` | Python (cocotb). SystemVerilog for `bind`-ed SVA property modules only. | UVM |

### Conditions attached to any HLS block that ships

1. Interfaces are `ap_ctrl_none` + `axis` (or `s_axilite` for pure control). No
   `ap_ctrl_hs`, no `m_axi`.
2. `csynth.rpt` **Latency min == Latency max** — the block is fixed-latency — and
   the achieved II equals the requested II.
3. Those numbers are committed to `docs/` and **re-checked by CI**, which fails the
   build if they change.
4. The block sits **behind a skid buffer** on both sides, so its latency and any
   backpressure it generates cannot propagate into a hand-written pipeline.
5. It has a cocotb testbench against the generated RTL, exactly like hand-written
   RTL. Verifying the C is not verifying the hardware.
6. The Vitis HLS version is **pinned in the build manifest**, because the version is
   part of the design.

### Conditions attached to any generated RTL

1. Generator and generated output are both committed.
2. The generator is deterministic and CI regenerates-and-diffs.
3. The generated file carries a header naming the generator, its version, and the
   config file hash.

### Conditions attached to any vendored open-source core

1. Pinned commit hash, recorded in the build manifest.
2. Licence recorded in `docs/`.
3. Same review, testbench, and assertion coverage as first-party fast-path RTL.
4. Local modifications kept as a visible patch series, never silently merged into
   the vendored tree.

**Default answer when in doubt: hand-written SystemVerilog.** The fast path is a
few thousand lines. It is worth writing them.

---

## Further reading

- [01-rtl-design-patterns.md](01-rtl-design-patterns.md) — the patterns you'd be hand-writing
- [02-pipelining-and-parallelism.md](02-pipelining-and-parallelism.md) — why controlling pipeline depth is the whole game
- [03-memory-and-storage.md](03-memory-and-storage.md) — XPM memory configuration and the parameters a generator would emit
- [04-io-transceivers-and-serdes.md](04-io-transceivers-and-serdes.md) — GT wizard, vendor MAC, and where the real IO nanoseconds are
- [05-verification-and-simulation.md](05-verification-and-simulation.md) — verifying generated and HLS-produced RTL
- [00-foundations/03-hdl-and-rtl-coding.md](../00-foundations/03-hdl-and-rtl-coding.md) — the synthesizable subset this project writes in
- [06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md) — pinning tool versions and reproducible builds
