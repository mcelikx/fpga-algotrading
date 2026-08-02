# TASKS — FPGA Algorithmic Trading System (Nasdaq Equities)

The master build plan: from an empty repository to a live single-symbol canary on
Nasdaq, and then into the optimization phase that this project actually exists for.

---

## How to use this file

- **This is the plan of record.** If work is happening and it isn't here, either add
  it here or stop doing it.
- **Every task cites the manual that governs it.** The manuals encode the constraints
  that make a design correct *and* fast. A task executed without reading its manual
  will produce something that synthesizes and is wrong. If a manual and the Nasdaq
  spec disagree, [the spec wins and the manual gets fixed](CLAUDE.md#6-risk-safety-and-scope).
- **Task IDs are stable and permanent.** Reference them in commit messages
  (`P4.5: fix delete-the-best rescan bound`), in PR titles, in ADRs, and in
  discussion. Never renumber. If a task dies, mark it `~~P3.9~~ dropped — reason`.
- **Phases gate on exit criteria, not on vibes.** A phase is done when every box in
  its exit-criteria block is ticked with evidence you can point at.
- **No dates anywhere.** Sizes are effort, not schedule.

### Status legend

| Mark | Meaning |
| --- | --- |
| `- [ ]` | Not started |
| `- [~]` | In progress |
| `- [x]` | Done — evidence linked in the commit or the ADR |
| `- [!]` | Blocked — the blocker is named in the task line |
| `~~ ~~` | Dropped — reason recorded inline |

### Task markers

| Marker | Meaning |
| --- | --- |
| 🔒 | **Safety-critical.** Touches risk, the kill switch, order emission, or limits. High blast radius. Never bundled with unrelated work; always reviewed by a second person. See [CLAUDE.md §6](CLAUDE.md#6-risk-safety-and-scope). |
| ⏱ | **Latency-critical.** Sits on the tick-to-trade path. Needs a stated ns/cycle budget in the module header before code is written, and a measurement after. |

### Effort sizing

For one competent engineer, working uninterrupted. Not a schedule.

| Size | Rough scale |
| --- | --- |
| **S** | A day or two |
| **M** | Up to two weeks |
| **L** | Weeks — a month-ish |
| **XL** | Multiple months, or a workstream in its own right |

### Line format

```
- [ ] **P4.5** `L` ⏱ — Imperative description of what to do.
  ↳ Manual: [link] · Output: `path/it/produces`
```

> **Note on manual links.** Tier `manuals/08-nasdaq/` is the venue-specific tier —
> it is being written in parallel and is not yet listed in
> [manuals/README.md](manuals/README.md). Links to it are forward references and are
> expected to resolve as that tier lands.

---

# Phase 0 — Foundations & Decisions

**Goal.** Turn a directory containing a `CLAUDE.md` into a repository a team can work
in, and convert every unspoken assumption into a written, dated decision. Nothing in
this phase produces a gate or a flip-flop. All of it is load-bearing anyway: the two
most expensive failures in a project like this are *choosing the wrong part* and
*discovering in month six that nobody agreed what the strategy was*.

**Exit criteria**

> - [ ] Part number, board, and transceiver plan are fixed in an ADR, with the SLR
>       layout and the GT-to-fabric distance understood.
> - [ ] `vivado -version`, `verilator --version`, `python --version`, and the cocotb
>       version are pinned in a lockfile and reproduced inside a container image that
>       CI uses.
> - [ ] `rtl/ tb/ host/ constraints/ scripts/ docs/` exist, and a trivial "hello
>       flip-flop" module goes lint → sim → synth → P&R in CI and reports WNS.
> - [ ] The strategy is written down in one page that a trader and an RTL engineer
>       both agree describes the same thing.
> - [ ] `docs/latency-budget.md` exists with a per-stage nanosecond budget summing to
>       under the target, in the style of
>       [01.02 §8](manuals/01-fpga-design/02-pipelining-and-parallelism.md).
> - [ ] The market-access path (own MPID vs. sponsored access) is decided, and the
>       15c3-5 responsibility split is written down and agreed with the broker-dealer.

### Hardware and toolchain

- [ ] **P0.1** `M` — Select the target card and part. Compare an Alveo-class
  UltraScale+ card against a purpose-built trading NIC (Exablaze/Cisco Nexus SmartNIC
  class). Decide on the basis of: GT-to-fabric latency, how many SLRs the fast path
  must cross, whether the vendor shell is on the critical path, and whether you can
  get a -3 speed grade. Record the losing options and why.
  ↳ Manual: [00.02 FPGA Architecture](manuals/00-foundations/02-fpga-architecture.md), [01.04 IO, Transceivers, SerDes](manuals/01-fpga-design/04-io-transceivers-and-serdes.md) · Output: `docs/adr/0001-hardware-selection.md`

- [ ] **P0.2** `S` — Pin every tool version and freeze them in a lockfile plus a
  build container. Vivado, Verilator, cocotb, Python, the C++ toolchain, and the
  Nasdaq spec revision numbers. Bitstreams must be reproducible; a floating toolchain
  makes "reproducible build" a lie.
  ↳ Manual: [07.03 Toolchain Reference](manuals/07-reference/03-toolchain-reference.md), [06.01 Build and Release](manuals/06-operations/01-build-and-release.md) · Output: `scripts/toolchain.lock`, `scripts/Dockerfile`

- [ ] **P0.3** `S` — Scaffold the repository to the layout in
  [CLAUDE.md §3](CLAUDE.md#3-repository-layout): `rtl/` (with `rtl/common/cdc/`
  pre-seeded with the sanctioned 2-FF synchronizer, gray-coded async FIFO, and
  handshake primitives), `tb/`, `host/`, `constraints/` (split `clocks.xdc`,
  `io.xdc`, `cdc.xdc`, `floorplan.xdc`), `scripts/`, `docs/adr/`.
  ↳ Manual: [00.04 Clocking, Reset, and CDC](manuals/00-foundations/04-clocking-reset-and-cdc.md) · Output: repository tree

- [ ] **P0.4** `S` — Adopt the coding standard mechanically, not by exhortation.
  Write the module header template (name, purpose, **latency budget in ns and
  cycles**, **resource budget in LUT/FF/BRAM/URAM/DSP**, clock domain, reset
  policy), a Verilator `-Wall` lint config with the project's waivers explicitly
  enumerated, and a pre-commit hook that rejects a module with no header budget.
  Per [CLAUDE.md §4](CLAUDE.md#4-how-to-work-in-this-repo), a block without a budget
  is not reviewable.
  ↳ Manual: [00.03 HDL and RTL Coding](manuals/00-foundations/03-hdl-and-rtl-coding.md) · Output: `scripts/lint/`, `docs/rtl-style.md`, `rtl/template.sv`

- [ ] **P0.5** `M` — Stand up the CI skeleton on a trivial design: lint → Verilator
  sim → synth → **place-and-route**, in that order, with WNS/TNS/failing-endpoint
  count and LUT/FF/BRAM utilization extracted from the *post-route* report and
  stored as a time series. Getting a real P&R running on day one is what stops you
  discovering at 80 % complete that nothing closes.
  ↳ Manual: [06.01 Build and Release](manuals/06-operations/01-build-and-release.md), [00.05 Timing Closure §7](manuals/00-foundations/05-timing-closure.md) · Output: `.github/workflows/` or `scripts/ci/`, `docs/ci-metrics.md`

### Architecture decisions

- [ ] **P0.6** `M` ⏱ — Decide the datapath width and core clock. The live question is
  512-bit @ 156.25 MHz (an ITCH `Add Order` in one beat, no reassembly state machine)
  versus 64-bit @ 322 MHz. Widen before you deepen; make this call now, because
  reversing it re-architects everything downstream.
  ↳ Manual: [01.02 Pipelining and Parallelism §3](manuals/01-fpga-design/02-pipelining-and-parallelism.md) · Output: `docs/adr/0002-datapath-width.md`

- [ ] **P0.7** `M` ⏱ — Write the **master latency budget**: a stage-by-stage table
  from wire-in to wire-out, in nanoseconds and cycles, at the clock chosen in P0.6,
  with SerDes/PCS/MAC entry and exit costs called out as fixed overheads. Every
  subsequent RTL task inherits its budget from a row in this table. Leave explicit
  slack per block for timing closure — design a 12-cycle budget in 9.
  ↳ Manual: [05.01 Latency Budgeting](manuals/05-optimization/01-latency-budgeting.md), [01.02 §8](manuals/01-fpga-design/02-pipelining-and-parallelism.md), [04.01 Tick-to-Trade Pipeline](manuals/04-system-architecture/01-tick-to-trade-pipeline.md) · Output: `docs/latency-budget.md`

- [ ] **P0.8** `S` — Write the **resource budget** and the floorplan intent: which
  blocks live in which SLR, which must be adjacent to the transceivers, and the LUT/
  BRAM/URAM ceiling per block. Floorplanning is standard practice for a trading
  datapath, not an exotic measure — decide it before, not after.
  ↳ Manual: [05.03 Resource and Power Optimization](manuals/05-optimization/03-resource-power-optimization.md), [00.05 Timing Closure §4](manuals/00-foundations/05-timing-closure.md) · Output: `docs/resource-budget.md`, `constraints/floorplan.xdc` (skeleton)

- [ ] **P0.9** `S` — Fix the numeric representation. Prices as scaled integers with a
  documented scale factor (Nasdaq ITCH prices are 4-decimal fixed point; decide
  whether you keep that or rescale), sizes as unsigned shares, notional as a width
  that cannot overflow at your position limits. **No floating point on the fast
  path** — this is a [hard rule](CLAUDE.md#5-hard-rules-on-the-fast-path), and the
  golden model in Phase 1 must use the identical representation or the comparison is
  meaningless.
  ↳ Manual: [00.03 HDL and RTL Coding](manuals/00-foundations/03-hdl-and-rtl-coding.md), [08.04 TotalView-ITCH Reference](manuals/08-nasdaq/04-totalview-itch-5.0.md) · Output: `docs/adr/0003-number-formats.md`, `host/include/fixed.hpp`

### Market access and strategy

- [ ] **P0.10** `L` 🔒 — Decide the market-access route: Nasdaq membership with your
  own MPID, or sponsored access through a broker-dealer. This determines who owns the
  Rule 15c3-5 obligation, what limits you are contractually required to enforce, and
  who signs off before you can send a live order. Get the responsibility split in
  writing.
  ↳ Manual: [08.01 Nasdaq Market Structure](manuals/08-nasdaq/01-market-structure.md), [03.06 Risk and Compliance](manuals/03-algotrading/06-risk-and-compliance.md) · Output: `docs/market-access.md`, signed responsibility matrix

- [ ] **P0.11** `M` — Decide market data entitlement and feed topology: TotalView-ITCH
  direct (A and B lines), which multicast groups, which UDP ports, colo delivery,
  and whether you also take Glimpse and the retransmission service (you do — see
  P7.8). Record the entitlement contract terms and the redistribution constraints.
  ↳ Manual: [03.03 Market Data Protocols](manuals/03-algotrading/03-market-data-protocols.md), [02.03 Multicast Feeds and Arbitration](manuals/02-networking/03-multicast-feeds-and-arbitration.md), [08.04 TotalView-ITCH Reference](manuals/08-nasdaq/04-totalview-itch-5.0.md) · Output: `docs/market-data-entitlements.md`

- [ ] **P0.12** `L` — **Decide what strategy we are actually running**, in one page,
  concretely enough to implement: the signal, the trigger condition, the order type,
  the size, the hold horizon, the exit, and the symbol universe. "Market making" is
  not a strategy; "post at the far touch on symbols in set S when the imbalance ratio
  crosses θ and the spread is ≥ 2 ticks, size Q, cancel on any top-of-book change" is.
  Everything in Phases 4–6 is shaped by this answer.
  ↳ Manual: [03.05 Strategy Taxonomy](manuals/03-algotrading/05-strategy-taxonomy.md), [03.01 Market Microstructure](manuals/03-algotrading/01-market-microstructure.md), [04.04 Strategy Engine on FPGA](manuals/04-system-architecture/04-strategy-engine-on-fpga.md) · Output: `docs/strategy-spec.md`

- [ ] **P0.13** `M` — Build the economic sanity model *before* building the system.
  At the fee/rebate schedule, an assumed fill rate, and an assumed adverse-selection
  cost, does the strategy make money at 400 ns? At 1 µs? At 5 µs? If the answer is
  "yes at 5 µs", you have just saved yourself this entire project. If it is "only
  under 500 ns", you now know your real target.
  ↳ Manual: [08.07 Fees and Rebates](manuals/08-nasdaq/07-fees-rebates-and-economics.md), [03.01 Market Microstructure](manuals/03-algotrading/01-market-microstructure.md), [07.02 Latency Reference Numbers](manuals/07-reference/02-latency-reference-numbers.md) · Output: `docs/economics-model.md`, `host/tools/economics/`

### Governance

- [ ] **P0.14** `S` 🔒 — Establish risk governance up front: who is allowed to change
  a risk limit, what approval a limit change needs, where limits are stored, and how
  a change is audited. Per [CLAUDE.md §6](CLAUDE.md#6-risk-safety-and-scope), limit
  changes are high-blast-radius and never ride along with unrelated work.
  ↳ Manual: [03.06 Risk and Compliance](manuals/03-algotrading/06-risk-and-compliance.md), [08.09 Risk Controls and Limits](manuals/08-nasdaq/09-risk-controls-and-limits.md) · Output: `docs/risk-governance.md`

- [ ] **P0.15** `S` — Set up the ADR process and the decision log, and write the
  secrets policy: no venue credentials, session IDs, MPIDs, comp IDs, or production
  IPs in the repository — ever. Add a secret-scanning hook that enforces it.
  ↳ Manual: [CLAUDE.md §6](CLAUDE.md#6-risk-safety-and-scope) · Output: `docs/adr/README.md`, `scripts/lint/secrets.sh`

---

# Phase 1 — Simulation-first Reference Model

**Goal.** Build a *software* trading system first: ITCH decoder, order book, strategy,
risk — in C++ (or Python where speed doesn't matter) — plus the pcap corpus and the
replay harness. This is the oracle. **You cannot verify a hardware order book without
a reference order book**; every book bug found in RTL simulation is found by
disagreement with this model, and every book bug not found here is found in
production, expensively.

This phase is not optional and it is not "the fun part later". It is the single
highest-leverage phase in the project, and it gates Phases 3 and 4 completely.

**Exit criteria**

> - [ ] The golden model replays a full trading day of TotalView-ITCH without error
>       and produces a deterministic, byte-stable event trace.
> - [ ] The golden book is independently corroborated — its closing state, its trade
>       prints, and its NBBO agree with an external source on at least three
>       different session days.
> - [ ] The corpus contains at least: a normal high-volume day, a day with a halt and
>       resumption, a day with an IPO/cross, and a day with an unusually high message
>       rate.
> - [ ] A crafted corner-case corpus exists covering every hard case listed in P1.10,
>       with expected outputs.
> - [ ] The pcap → wire-stimulus generator produces frames that a MAC would accept,
>       including A/B duplication and injectable gaps.
> - [ ] The strategy has been backtested against the corpus with a latency model, and
>       there is a written go/no-go on P0.12.

- [ ] **P1.1** `M` — Acquire and organize the pcap / ITCH corpus. Nasdaq publishes
  sample TotalView-ITCH files; supplement with captured colo traffic if available.
  Store them out of git (LFS or object storage) with a manifest recording date,
  session, message count, and file hash. Every regression run cites corpus version.
  ↳ Manual: [01.05 Verification and Simulation](manuals/01-fpga-design/05-verification-and-simulation.md), [08.04 TotalView-ITCH Reference](manuals/08-nasdaq/04-totalview-itch-5.0.md) · Output: `tb/corpus/manifest.yaml`, corpus store

- [ ] **P1.2** `M` — Write the golden ITCH 5.0 decoder in C++. **Every** message type,
  including the ones you think you don't care about (System Event, Stock Directory,
  Trading Action, Reg SHO Restriction, Market Participant Position, MWCB, IPO
  Quoting Period, LULD Auction Collar, Operational Halt, Add Order (both forms),
  Order Executed (both), Order Cancel, Order Delete, Order Replace, Trade,
  Cross Trade, Broken Trade, NOII, RPII). Getting the message-length table wrong is
  the classic ITCH bug and it silently desynchronizes the whole stream.
  ↳ Manual: [08.04 TotalView-ITCH Reference](manuals/08-nasdaq/04-totalview-itch-5.0.md), [03.03 Market Data Protocols](manuals/03-algotrading/03-market-data-protocols.md) · Output: `host/golden/itch_decoder.{hpp,cpp}`

- [ ] **P1.3** `L` — Write the golden order book: order-ID → (symbol, side, price,
  size) map, per-symbol price-level aggregation, full depth, correct handling of
  partial executions, replaces (delete + add with a new reference number and *lost*
  queue priority), and cancels that reduce rather than remove. Maintain top-of-book
  and expose the full book for comparison.
  ↳ Manual: [03.01 Market Microstructure](manuals/03-algotrading/01-market-microstructure.md), [04.03 Order Book in Hardware](manuals/04-system-architecture/03-order-book-in-hardware.md) · Output: `host/golden/order_book.{hpp,cpp}`

- [ ] **P1.4** `M` — Write the golden strategy model, using **the exact integer
  arithmetic the RTL will use** — same widths, same scale factors, same truncation
  and rounding behaviour. A golden model in `double` is not a golden model; it is a
  second, differently-wrong implementation.
  ↳ Manual: [04.04 Strategy Engine on FPGA](manuals/04-system-architecture/04-strategy-engine-on-fpga.md), P0.9 · Output: `host/golden/strategy.{hpp,cpp}`

- [ ] **P1.5** `M` 🔒 — Write the golden pre-trade risk model, mirroring every check
  that Phase 6 will implement in fabric, including the fail-closed default and the
  saturating counter semantics.
  ↳ Manual: [08.09 Risk Controls and Limits](manuals/08-nasdaq/09-risk-controls-and-limits.md), [04.05 Order Gateway and Pre-Trade Risk](manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md) · Output: `host/golden/risk.{hpp,cpp}`

- [ ] **P1.6** `M` — Define the **canonical event trace format** and write the replay
  harness that produces it: one record per decoded message and per book mutation,
  with sequence number, timestamp, symbol, and post-state digest. This format is the
  contract between the golden model and every testbench for the rest of the project.
  Version it.
  ↳ Manual: [01.05 Verification and Simulation](manuals/01-fpga-design/05-verification-and-simulation.md), [06.04 Testing Strategy](manuals/06-operations/04-testing-strategy.md) · Output: `docs/trace-format.md`, `host/golden/replay`

- [ ] **P1.7** `S` — Write the trace diff tool: given two traces, report the first
  divergence with full context (message that caused it, both book states, the delta).
  You will run this thousands of times; make its output good.
  ↳ Manual: [01.05 Verification and Simulation](manuals/01-fpga-design/05-verification-and-simulation.md) · Output: `host/tools/tracediff`

- [ ] **P1.8** `M` — **Corroborate the golden book against an independent source.**
  Compare its trade prints against the official trade tape, its closing book against
  end-of-day data, and spot-check its NBBO. A golden model that has only ever been
  checked against itself is a confident liar.
  ↳ Manual: [03.01 Market Microstructure](manuals/03-algotrading/01-market-microstructure.md), [08.04 TotalView-ITCH Reference](manuals/08-nasdaq/04-totalview-itch-5.0.md) · Output: `docs/golden-model-validation.md`

- [ ] **P1.9** `M` — Write the pcap → wire-stimulus generator: takes ITCH message
  streams and emits proper MoldUDP64 / UDP / IPv4 / Ethernet frames suitable for
  driving a cocotb testbench or a hardware traffic generator, with switchable A/B
  duplication, configurable inter-packet gaps, and injectable sequence gaps,
  reordering, and truncation.
  ↳ Manual: [02.03 Multicast Feeds and Arbitration](manuals/02-networking/03-multicast-feeds-and-arbitration.md), [01.05 Verification and Simulation](manuals/01-fpga-design/05-verification-and-simulation.md) · Output: `tb/stimgen/`

- [ ] **P1.10** `M` — Synthesize the corner-case corpus. Hand-crafted streams for:
  delete-the-best-order, delete-the-last-order-at-the-only-level, execute-the-entire-
  top-level, replace across price levels, back-to-back updates to the same price
  level (the read-modify-write hazard), crossed/locked book, a sequence gap in the
  middle of a burst, a symbol going halted and resuming, an LULD band update, an SSR
  trigger, an odd-lot at the top, order-ID reuse across the day boundary, and book
  capacity overflow. Each with the expected golden output committed alongside.
  ↳ Manual: [04.03 Order Book in Hardware](manuals/04-system-architecture/03-order-book-in-hardware.md), [08.02 Sessions and Auctions](manuals/08-nasdaq/02-sessions-auctions-and-halts.md) · Output: `tb/corpus/corner/`

- [ ] **P1.11** `L` — Backtest the strategy over the corpus with an explicit latency
  model (parameterize on the tick-to-trade number, sweep 200 ns → 10 µs), and produce
  a go/no-go on P0.12 with a PnL-vs-latency curve. This is the last cheap moment to
  change your mind about what you're building.
  ↳ Manual: [03.05 Strategy Taxonomy](manuals/03-algotrading/05-strategy-taxonomy.md), [08.07 Fees and Rebates](manuals/08-nasdaq/07-fees-rebates-and-economics.md) · Output: `docs/backtest-report.md`

- [ ] **P1.12** `S` — Freeze and version the golden model's interface, tag it, and
  declare it the verification oracle in `docs/`. From here, "the RTL is wrong" and
  "the golden model is wrong" are both bugs, and both need an explicit ruling.
  ↳ Manual: [06.04 Testing Strategy](manuals/06-operations/04-testing-strategy.md) · Output: `docs/verification-oracle.md`, git tag

---

# Phase 2 — Networking Foundation

**Goal.** Get bytes off the fibre and into the fabric at line rate, deterministically,
with every error counted. Nothing above this layer can be trusted until the RX path
accepts line rate unconditionally and the MAC/PCS/SerDes latency is a *measured*
number in the budget rather than a guess.

**Exit criteria**

> - [ ] Link comes up on real optics against real switch hardware; PCS/PMA stable
>       over an 8-hour soak with zero unexplained errors.
> - [ ] Loopback runs at 10 Gbps line rate with minimum-size frames back-to-back and
>       zero drops, sustained for one hour.
> - [ ] MoldUDP64 deframing produces the exact ITCH message stream that the golden
>       model's decoder consumes, for the whole corpus, byte-identical.
> - [ ] A/B arbitration is proven with a stimulus where each line independently drops,
>       reorders, and delays packets.
> - [ ] MAC + PCS + SerDes latency is **measured on hardware** in both directions and
>       written into `docs/latency-budget.md` as a fixed cost.
> - [ ] Every error condition has a counter, and every counter has been made to
>       increment in a directed test.

- [ ] **P2.1** `M` ⏱ — Bring up the GT transceivers and PCS/PMA. Configure the GT
  wizard for 10GBASE-R, get link and lock indications, verify against the actual
  optics and the actual switch. Record the configuration knobs that affect latency
  (buffer bypass, RX elastic buffer settings) — these are worth nanoseconds later.
  ↳ Manual: [01.04 IO, Transceivers, and SerDes](manuals/01-fpga-design/04-io-transceivers-and-serdes.md), [02.01 Ethernet PHY and MAC](manuals/02-networking/01-ethernet-phy-mac.md) · Output: `rtl/net/gt_wrapper.sv`, `docs/gt-config.md`

- [ ] **P2.2** `L` ⏱ — Evaluate the vendor 10G MAC against a custom cut-through MAC.
  Build both far enough to measure, then measure. Vendor MACs are frequently
  store-and-forward and can cost 100 ns+ per direction; a cut-through MAC is not hard
  and is often the single largest free win in the whole design. Decide with numbers,
  not preference.
  ↳ Manual: [02.01 Ethernet PHY and MAC](manuals/02-networking/01-ethernet-phy-mac.md), [05.05 Optimization Playbook](manuals/05-optimization/05-optimization-playbook.md) · Output: `rtl/net/mac_rx.sv`, `rtl/net/mac_tx.sv`, `docs/adr/0004-mac-selection.md`

- [ ] **P2.3** `M` — Build the line-rate loopback test: generate minimum-size frames
  back-to-back at 100 % utilization, loop them, and count. Any drop at line rate is a
  design failure, not a tuning issue. Per
  [CLAUDE.md §5](CLAUDE.md#5-hard-rules-on-the-fast-path), the RX path must accept
  line rate unconditionally; it may drop deliberately and count, never block.
  ↳ Manual: [02.01 Ethernet PHY and MAC](manuals/02-networking/01-ethernet-phy-mac.md), [01.02 §2 (II = 1)](manuals/01-fpga-design/02-pipelining-and-parallelism.md) · Output: `tb/net/tb_loopback.py`, `docs/loopback-results.md`

- [ ] **P2.4** `M` ⏱ — Implement Ethernet + IPv4 header parse and the multicast group
  filter. Fixed-latency, no state machine if the datapath is wide enough. Drop and
  count anything that isn't an entitled group.
  ↳ Manual: [02.02 IP, UDP, TCP in Hardware](manuals/02-networking/02-ip-udp-tcp-in-hardware.md) · Output: `rtl/net/eth_ip_parse.sv`

- [ ] **P2.5** `S` ⏱ — Implement UDP parse and decide the checksum policy explicitly:
  validating the UDP checksum costs you the whole payload before you can act on it,
  which is fatal on a cut-through path. The right answer is almost certainly "compute
  it in parallel, act early, and count mismatches to raise an alarm" — but write down
  which you chose and why.
  ↳ Manual: [02.02 IP, UDP, TCP in Hardware](manuals/02-networking/02-ip-udp-tcp-in-hardware.md) · Output: `rtl/net/udp_parse.sv`, `docs/adr/0005-checksum-policy.md`

- [ ] **P2.6** `M` ⏱ — Implement MoldUDP64 deframing: session ID, sequence number,
  message count, and the length-prefixed message blocks. Emit a clean per-message
  stream with sequence numbers attached. Handle heartbeats (count 0) and end-of-
  session packets.
  ↳ Manual: [03.03 Market Data Protocols](manuals/03-algotrading/03-market-data-protocols.md), [08.04 TotalView-ITCH Reference](manuals/08-nasdaq/04-totalview-itch-5.0.md) · Output: `rtl/feed/mold_deframer.sv`

- [ ] **P2.7** `M` ⏱ — Implement A/B feed arbitration: first-arrival-wins with
  deduplication by sequence number, a bounded reorder window, and no dependence on
  the two lines being in step. Count per-line arrivals, wins, and duplicates — the
  win ratio is an operational health metric that tells you when a line is degrading.
  ↳ Manual: [02.03 Multicast Feeds and Arbitration](manuals/02-networking/03-multicast-feeds-and-arbitration.md) · Output: `rtl/feed/ab_arbiter.sv`

- [ ] **P2.8** `M` 🔒 — Implement sequence gap detection and the gap event path to the
  host. A gap means the book is potentially wrong, and a wrong book must not trade.
  Raise the event, latch it, and make it visible in a register within a bounded
  number of cycles.
  ↳ Manual: [02.03 Multicast Feeds and Arbitration](manuals/02-networking/03-multicast-feeds-and-arbitration.md) · Output: `rtl/feed/gap_detect.sv`

- [ ] **P2.9** `S` — Implement the link/error/status counter block: frames in, bytes
  in, CRC errors, undersize/oversize, dropped-not-entitled, per-line packet counts,
  link up/down transitions, and a link-flap timestamp. Per
  [CLAUDE.md §5](CLAUDE.md#5-hard-rules-on-the-fast-path), everything dropped is
  counted. Saturating, not wrapping.
  ↳ Manual: [06.03 Monitoring and Telemetry](manuals/06-operations/03-monitoring-and-telemetry.md) · Output: `rtl/net/net_counters.sv`

- [ ] **P2.10** `S` — Implement the CDC at the MAC/core boundary using **only** the
  sanctioned primitives in `rtl/common/cdc/`. No hand-rolled synchronizers, ever.
  Constrain the crossings in `constraints/cdc.xdc` and verify they are not being
  analyzed as synchronous paths.
  ↳ Manual: [00.04 Clocking, Reset, and CDC](manuals/00-foundations/04-clocking-reset-and-cdc.md), [00.05 §4 Tier 1](manuals/00-foundations/05-timing-closure.md) · Output: `rtl/net/mac_cdc.sv`, `constraints/cdc.xdc`

- [ ] **P2.11** `M` ⏱ — Build the TX framing skeleton for order entry: Ethernet /
  IPv4 / TCP header emission with correct checksums, driven by a payload interface.
  ARP, routing, and the TCP handshake stay on the host (see P6.9); the fabric owns
  only the steady-state send.
  ↳ Manual: [02.02 IP, UDP, TCP in Hardware](manuals/02-networking/02-ip-udp-tcp-in-hardware.md) · Output: `rtl/net/tx_framer.sv`

- [ ] **P2.12** `M` ⏱ — **Measure** MAC + PCS + SerDes latency on real hardware in
  both directions, with an external timestamping reference or a known-good loopback,
  and write the measured number into the budget. Say "measured, N=…" — never quote
  the datasheet as if it were a measurement.
  ↳ Manual: [05.04 Measurement and Profiling](manuals/05-optimization/04-measurement-and-profiling.md), [CLAUDE.md §4](CLAUDE.md#4-how-to-work-in-this-repo) · Output: `docs/latency-budget.md` (updated), `docs/measurements/mac-latency.md`

---

# Phase 3 — Feed Handler

**Goal.** Turn the MoldUDP64 message stream into decoded, dispatched, symbol-filtered
ITCH events at II = 1, with the correct message every time. This block is validated
by bit-exact comparison against the Phase 1 golden decoder over the entire corpus —
there is no other acceptable standard of evidence.

**Exit criteria**

> - [ ] Every ITCH 5.0 message type is decoded, and the length table is verified
>       against the spec by an independent reviewer (this is the #1 ITCH bug).
> - [ ] A full trading day replays through the RTL in simulation with **zero**
>       divergences from the golden decoder trace.
> - [ ] II = 1 sustained at line rate with a worst-case message-rate burst; no
>       backpressure reaches the MAC RX.
> - [ ] A sequence gap sets the stale-book flag for the affected symbols and disables
>       trading on them, proven in a directed test.
> - [ ] Per-message-type counters all proven to increment.
> - [ ] Post-route timing closes at the target clock, with WNS/TNS quoted verbatim.

- [ ] **P3.1** `M` ⏱ — Implement the ITCH message type and length table as a
  synthesizable lookup, and the framing logic that walks the message stream. Have the
  table reviewed against the Nasdaq spec by a second person, line by line. An
  off-by-one here desynchronizes every subsequent message and looks like a book bug.
  ↳ Manual: [08.04 TotalView-ITCH Reference](manuals/08-nasdaq/04-totalview-itch-5.0.md), [04.02 Feed Handler Design](manuals/04-system-architecture/02-feed-handler-design.md) · Output: `rtl/feed/itch_framer.sv`, `rtl/feed/itch_msg_pkg.sv`

- [ ] **P3.2** `L` ⏱ — Implement the ITCH 5.0 field-extraction decoder. Fixed-latency
  mux-based extraction, not a serial state machine. Handle both `Add Order` forms,
  both `Order Executed` forms, `Order Replace` (which must be treated as delete + add
  with lost priority), `Order Cancel` (partial), and `Order Delete`.
  ↳ Manual: [08.04 TotalView-ITCH Reference](manuals/08-nasdaq/04-totalview-itch-5.0.md), [04.02 Feed Handler Design](manuals/04-system-architecture/02-feed-handler-design.md), [01.02 §3](manuals/01-fpga-design/02-pipelining-and-parallelism.md) · Output: `rtl/feed/itch_decoder.sv`

- [ ] **P3.3** `M` ⏱ — Implement the symbol table as a **direct-indexed** lookup on
  the ITCH stock-locate field. Nasdaq hands you a dense integer index for free; there
  is no reason to hash a ticker string in fabric. Populate the table from `Stock
  Directory` messages at start of day, with host override.
  ↳ Manual: [04.02 Feed Handler Design](manuals/04-system-architecture/02-feed-handler-design.md), [01.03 Memory and Storage](manuals/01-fpga-design/03-memory-and-storage.md) · Output: `rtl/feed/symbol_table.sv`

- [ ] **P3.4** `S` ⏱ — Implement the symbol filter: a per-locate "we trade this" bit,
  writable from the host. Messages for uninteresting symbols are dropped at the
  earliest possible stage — this is the cheapest bandwidth reduction available and it
  shrinks every downstream memory.
  ↳ Manual: [04.02 Feed Handler Design](manuals/04-system-architecture/02-feed-handler-design.md) · Output: `rtl/feed/symbol_filter.sv`

- [ ] **P3.5** `M` ⏱ — Implement message dispatch: route decoded messages to the book
  engine, the trading-state tracker, or the discard path, with a fixed latency per
  route and no arbitration on the hot path.
  ↳ Manual: [01.01 RTL Design Patterns](manuals/01-fpga-design/01-rtl-design-patterns.md), [04.02 Feed Handler Design](manuals/04-system-architecture/02-feed-handler-design.md) · Output: `rtl/feed/dispatch.sv`

- [ ] **P3.6** `M` 🔒 — Implement the stale-book flag: on a sequence gap, mark every
  symbol's book as untrusted and gate trading off until the host clears it after a
  successful resync (P4.7 / P7.8). Fail-closed: the flag defaults to *stale* at reset.
  ↳ Manual: [02.03 Multicast Feeds and Arbitration](manuals/02-networking/03-multicast-feeds-and-arbitration.md), [08.09 Risk Controls and Limits](manuals/08-nasdaq/09-risk-controls-and-limits.md) · Output: `rtl/feed/stale_flags.sv`

- [ ] **P3.7** `S` — Implement per-message-type counters plus decode-error, unknown-
  type, and filtered-out counters. Saturating. Every one must be provably reachable.
  ↳ Manual: [06.03 Monitoring and Telemetry](manuals/06-operations/03-monitoring-and-telemetry.md) · Output: `rtl/feed/feed_counters.sv`

- [ ] **P3.8** `S` ⏱ — Capture a free-running fabric timestamp at the **first byte**
  of every inbound frame and carry it down the pipeline. This is the `t0` that every
  latency measurement in Phase 8 and Phase 11 is relative to; retrofitting it later is
  painful and inaccurate.
  ↳ Manual: [05.04 Measurement and Profiling](manuals/05-optimization/04-measurement-and-profiling.md) · Output: `rtl/common/timestamp.sv`

- [ ] **P3.9** `M` 🔒 — Track per-symbol trading state from the feed: `Stock Trading
  Action` (halted / paused / quotation-only / trading), `Reg SHO Restriction`, LULD
  auction collar, MWCB levels, IPO quoting period, and `System Event` session
  transitions. This state feeds the Phase 5 gate and the Phase 6 risk block.
  ↳ Manual: [08.02 Sessions and Auctions](manuals/08-nasdaq/02-sessions-auctions-and-halts.md), [08.06 Reg NMS and Compliance](manuals/08-nasdaq/06-regnms-and-compliance.md) · Output: `rtl/feed/trading_state.sv`

- [ ] **P3.10** `L` — Build the cocotb regression that drives the full corpus through
  the RTL feed handler and diffs the emitted decode trace against the golden model,
  message by message. Wire it into CI. Anything less than zero divergences is a fail.
  ↳ Manual: [01.05 Verification and Simulation](manuals/01-fpga-design/05-verification-and-simulation.md), [06.04 Testing Strategy](manuals/06-operations/04-testing-strategy.md) · Output: `tb/feed/test_itch_regression.py`

- [ ] **P3.11** `M` ⏱ — Close post-route timing and hit the resource budget for the
  feed handler standalone. Quote WNS/TNS/failing endpoints and utilization from the
  post-route report verbatim, across a seed sweep — not the best seed.
  ↳ Manual: [00.05 Timing Closure §9](manuals/00-foundations/05-timing-closure.md) · Output: `docs/timing/feed-handler.md`

---

# Phase 4 — Order Book

**Goal.** Maintain a correct book in fabric at II = 1. This is the hardest block in
the system and the one most likely to be subtly wrong. It is also where the RMW
hazard, the delete-the-best rescan, and the capacity-overflow policy all live.

Correctness standard: **exhaustive, per-message comparison against the golden book**
over the entire corpus plus randomized flow. Not sampled. Not end-of-day. Every
message.

**Exit criteria**

> - [ ] Full-corpus replay produces zero book divergences from the golden model,
>       compared after every single message.
> - [ ] Every corner case in P1.10 passes, individually and in a combined stream.
> - [ ] Back-to-back updates to the same price level are handled at II = 1 with
>       correct data — proven with a directed adversarial stimulus.
> - [ ] The delete-the-best path has a **bounded, documented** worst-case cycle count,
>       and that bound is asserted in simulation.
> - [ ] Book capacity overflow marks the symbol untradeable and increments a counter;
>       it never corrupts the book and never silently drops.
> - [ ] Resync after a gap restores a book that matches the golden model from the
>       resync point onward.
> - [ ] Post-route timing closes; WNS/TNS quoted verbatim.

- [ ] **P4.1** `M` ⏱ — Choose and document the book data structure. The decision set:
  order-ID map (direct-index vs. bounded-probe hash), price-level representation
  (dense array over a price window vs. sorted level list), depth limit, and how many
  symbols fit. Write the ADR with the memory sizing arithmetic shown.
  ↳ Manual: [04.03 Order Book in Hardware](manuals/04-system-architecture/03-order-book-in-hardware.md), [01.03 Memory and Storage](manuals/01-fpga-design/03-memory-and-storage.md) · Output: `docs/adr/0006-book-structure.md`

- [ ] **P4.2** `L` ⏱ — Implement the order-ID map. ITCH order reference numbers are
  64-bit and sparse, so this is a hash with a **bounded** probe count — unbounded
  probing violates [CLAUDE.md §5](CLAUDE.md#5-hard-rules-on-the-fast-path). Decide
  and count the collision-overflow behaviour explicitly.
  ↳ Manual: [01.03 Memory and Storage](manuals/01-fpga-design/03-memory-and-storage.md), [01.01 RTL Design Patterns](manuals/01-fpga-design/01-rtl-design-patterns.md) · Output: `rtl/book/order_map.sv`

- [ ] **P4.3** `L` ⏱ — Implement price-level aggregation memory, banked so that
  consecutive updates to different levels don't contend for a port. Sizing, banking
  scheme, and the collision-stall policy all get documented in the module header.
  ↳ Manual: [04.03 Order Book in Hardware](manuals/04-system-architecture/03-order-book-in-hardware.md), [01.03 Memory and Storage](manuals/01-fpga-design/03-memory-and-storage.md) · Output: `rtl/book/level_mem.sv`

- [ ] **P4.4** `M` ⏱ — Maintain **incremental** top-of-book: best bid/ask price and
  size updated as a side effect of each mutation. Never recompute a max over the
  book — that is the single most common way to blow both the latency budget and
  timing closure at once.
  ↳ Manual: [04.03 Order Book in Hardware](manuals/04-system-architecture/03-order-book-in-hardware.md), [00.05 §4 Tier 3 item 11](manuals/00-foundations/05-timing-closure.md) · Output: `rtl/book/top_of_book.sv`

- [ ] **P4.5** `L` ⏱ — Implement the **delete-the-best** case: when the last order at
  the best price is removed, the new best must be found. This is the one genuinely
  variable-latency operation in the book and it must be given a hard bound (scan a
  fixed window, or maintain a level-occupancy bitmap and use a priority encoder —
  prefer the bitmap). Document the bound, assert it, count every occurrence, and
  count every time the bound was hit.
  ↳ Manual: [04.03 Order Book in Hardware](manuals/04-system-architecture/03-order-book-in-hardware.md), [01.02 §9 rule 4](manuals/01-fpga-design/02-pipelining-and-parallelism.md) · Output: `rtl/book/best_search.sv`

- [ ] **P4.6** `M` ⏱ — Implement read-modify-write forwarding for back-to-back updates
  to the same price level. Two updates to the same level in consecutive cycles means
  the second reads stale data unless you detect the address match and forward the
  in-flight value combinationally. This is the classic II = 1 feedback-loop breaker
  and it is a correctness bug, not a performance one.
  ↳ Manual: [01.02 §2](manuals/01-fpga-design/02-pipelining-and-parallelism.md) · Output: `rtl/book/rmw_forward.sv`

- [ ] **P4.7** `M` 🔒 — Implement book resync after a gap: clear the affected books,
  accept a snapshot load from the host (Glimpse — see P7.8), and re-enter live
  tracking at the correct sequence number without double-applying messages that
  arrived during the rebuild.
  ↳ Manual: [02.03 Multicast Feeds and Arbitration](manuals/02-networking/03-multicast-feeds-and-arbitration.md), [04.03 Order Book in Hardware](manuals/04-system-architecture/03-order-book-in-hardware.md) · Output: `rtl/book/resync.sv`

- [ ] **P4.8** `S` 🔒 — Implement the capacity-overflow policy: when a symbol exceeds
  its order or level capacity, mark it untradeable, latch the event, count it, and
  keep going. Never wrap, never evict silently, never let the book become quietly
  wrong. Silent failure is the worst failure mode in this domain.
  ↳ Manual: [CLAUDE.md §5](CLAUDE.md#5-hard-rules-on-the-fast-path), [06.03 Monitoring and Telemetry](manuals/06-operations/03-monitoring-and-telemetry.md) · Output: `rtl/book/overflow.sv`

- [ ] **P4.9** `L` — Build the exhaustive golden-comparison regression: full corpus,
  book state digest compared against the golden model after **every** message, first
  divergence reported by the P1.7 diff tool. This is the gate on the whole phase.
  ↳ Manual: [01.05 Verification and Simulation](manuals/01-fpga-design/05-verification-and-simulation.md), [06.04 Testing Strategy](manuals/06-operations/04-testing-strategy.md) · Output: `tb/book/test_book_regression.py`

- [ ] **P4.10** `M` — Add constrained-random order-flow generation on top of the
  corpus: random adds/cancels/executes/replaces concentrated around the touch, with
  seeds recorded, run nightly. Random flow finds the state-space corners that
  historical data never visits.
  ↳ Manual: [01.05 Verification and Simulation](manuals/01-fpga-design/05-verification-and-simulation.md) · Output: `tb/book/test_book_random.py`

- [ ] **P4.11** `M` ⏱ — Close post-route timing and the resource budget for feed +
  book together. The book update path is one of the four paths that are almost always
  critical in a trading datapath — expect to work for this one.
  ↳ Manual: [00.05 Timing Closure §7](manuals/00-foundations/05-timing-closure.md), [05.02 Fmax and Timing Optimization](manuals/05-optimization/02-fmax-and-timing-optimization.md) · Output: `docs/timing/book.md`

---

# Phase 5 — Strategy Engine

**Goal.** Implement the trigger from `docs/strategy-spec.md` as a fixed-latency,
table-driven block whose behaviour can be changed from the host **without a
rebuild**, and which cannot fire on a symbol that isn't currently tradeable.

**Exit criteria**

> - [ ] The strategy's decisions match the golden strategy model bit-for-bit over the
>       full corpus.
> - [ ] A parameter update applied mid-stream is atomic: no message ever sees a
>       half-updated parameter set. Proven with a directed test that updates
>       parameters on every cycle for a sustained burst.
> - [ ] The trading-state gate has been proven to block firing for each of: halted,
>       LULD paused, SSR-restricted (wrong side), outside session, stale book, and
>       symbol-not-armed.
> - [ ] Trigger latency is fixed — the same number of cycles every time — and stated
>       in the module header.
> - [ ] Post-route timing closes; WNS/TNS quoted verbatim.

- [ ] **P5.1** `M` ⏱ — Define and implement the per-symbol parameter table: memory
  layout, field widths, scale factors, and the host-visible address map. Everything
  is a scaled integer with the scale documented — [no floating
  point](CLAUDE.md#5-hard-rules-on-the-fast-path).
  ↳ Manual: [04.04 Strategy Engine on FPGA](manuals/04-system-architecture/04-strategy-engine-on-fpga.md) · Output: `rtl/strategy/param_table.sv`, `docs/param-map.md`

- [ ] **P5.2** `M` 🔒 — Implement atomic double-buffered parameter update: the host
  writes the shadow bank, then a single commit register write swaps banks between
  messages. Half-applied parameters are a real way to lose real money.
  ↳ Manual: [04.04 Strategy Engine on FPGA](manuals/04-system-architecture/04-strategy-engine-on-fpga.md), [04.06 CPU/FPGA Partitioning](manuals/04-system-architecture/06-cpu-fpga-partitioning.md) · Output: `rtl/strategy/param_swap.sv`

- [ ] **P5.3** `L` ⏱ — Implement the trigger logic per `docs/strategy-spec.md`.
  Precompute everything that doesn't depend on this tick — thresholds, derived
  limits, per-symbol constants — in the host and store them in the table. Comparisons
  on the fast path, arithmetic on the slow path.
  ↳ Manual: [04.04 Strategy Engine on FPGA](manuals/04-system-architecture/04-strategy-engine-on-fpga.md), [01.02 §4 Precompute](manuals/01-fpga-design/02-pipelining-and-parallelism.md) · Output: `rtl/strategy/trigger.sv`

- [ ] **P5.4** `M` 🔒 ⏱ — Implement the per-symbol trading-state gate: fold halted,
  LULD paused, SSR active, session state, stale book, capacity overflow, and
  "symbol armed by host" into a single precomputed per-symbol **tradeable bit**,
  updated off the critical path and consumed as one AND on it.
  ↳ Manual: [08.02 Sessions and Auctions](manuals/08-nasdaq/02-sessions-auctions-and-halts.md), [08.06 Reg NMS and Compliance](manuals/08-nasdaq/06-regnms-and-compliance.md), [01.02 §4](manuals/01-fpga-design/02-pipelining-and-parallelism.md) · Output: `rtl/strategy/tradeable_gate.sv`

- [ ] **P5.5** `S` — Implement the host-side parameter computation that fills the
  table: derive per-symbol thresholds, notional-to-share limits, and tick-size
  constants from the strategy config. This is where the division lives, so that the
  fabric only ever compares.
  ↳ Manual: [04.06 CPU/FPGA Partitioning](manuals/04-system-architecture/06-cpu-fpga-partitioning.md) · Output: `host/control/param_builder.cpp`

- [ ] **P5.6** `M` 🔒 ⏱ — Implement per-symbol message-rate throttling and trigger
  hysteresis: a bound on triggers per symbol per time window, enforced in fabric.
  This is the anti-runaway backstop that sits *underneath* the Phase 6 risk block —
  defence in depth, not a duplicate.
  ↳ Manual: [08.09 Risk Controls and Limits](manuals/08-nasdaq/09-risk-controls-and-limits.md), [03.06 Risk and Compliance](manuals/03-algotrading/06-risk-and-compliance.md) · Output: `rtl/strategy/throttle.sv`

- [ ] **P5.7** `M` — Write the deterministic strategy test suite: directed vectors for
  every trigger condition and every gate condition, plus a full-corpus comparison
  against the golden strategy model. Deterministic means "same input, same output,
  same cycle" — assert the cycle, not just the value.
  ↳ Manual: [01.05 Verification and Simulation](manuals/01-fpga-design/05-verification-and-simulation.md) · Output: `tb/strategy/test_trigger.py`

- [ ] **P5.8** `M` ⏱ — Close post-route timing and resource budget for feed + book +
  strategy. Watch for the wide comparison in the trigger — it is one of the four
  usual critical paths.
  ↳ Manual: [00.05 Timing Closure](manuals/00-foundations/05-timing-closure.md) · Output: `docs/timing/strategy.md`

---

# Phase 6 — Order Gateway & Pre-Trade Risk 🔒

**Goal.** Emit valid OUCH orders, and make it structurally impossible to emit one that
hasn't passed every risk check. This phase is the reason the project can exist as a
real-money system. Per
[CLAUDE.md §5](CLAUDE.md#5-hard-rules-on-the-fast-path): **pre-trade risk is in
hardware and cannot be bypassed — there is no software path that emits orders without
it**, and the kill switch is hardware-enforced with a bounded response time.

Treat every task in this phase as high-blast-radius. Second reviewer required. Never
bundled with unrelated changes.

**Exit criteria**

> - [ ] Every check in [08.09](manuals/08-nasdaq/09-risk-controls-and-limits.md) is
>       implemented, enumerated in `docs/risk-checks.md`, and mapped to a register
>       address and a rejection counter.
> - [ ] **The test matrix proves every single check fires**, individually, with a
>       directed test per check, and the matrix is CI-gated. A check with no test that
>       makes it reject is an unimplemented check.
> - [ ] Fail-closed proven: after reset, with no host configuration at all, the
>       gateway rejects 100 % of orders.
> - [ ] Kill switch response time measured in cycles in simulation and on hardware,
>       and it is bounded, documented, and asserted.
> - [ ] A netlist-level check proves there is no combinational or sequential path from
>       the strategy trigger to the TX framer that does not pass through the risk
>       block.
> - [ ] Generated OUCH messages are byte-validated against the spec and accepted by
>       the Nasdaq test environment.
> - [ ] Counters saturate; none wrap.

- [ ] **P6.1** `M` 🔒 — Write `docs/risk-checks.md`: enumerate **every** check from
  [08.09](manuals/08-nasdaq/09-risk-controls-and-limits.md) into a table with, per
  check: the limit register address, the reject reason code, the counter address, the
  test that proves it fires, and whether it is regulatory-mandated or house policy.
  Nothing gets implemented until it has a row here.
  ↳ Manual: [08.09 Risk Controls and Limits](manuals/08-nasdaq/09-risk-controls-and-limits.md), [03.06 Risk and Compliance](manuals/03-algotrading/06-risk-and-compliance.md) · Output: `docs/risk-checks.md`

- [ ] **P6.2** `XL` 🔒 ⏱ — Implement the pre-trade risk block. At minimum: max shares
  per order, max notional per order, price collar (limit price within a band of the
  reference price), max long position, max short position, max open orders per
  symbol, max orders per second (per symbol and aggregate), max daily notional
  traded, max daily gross/net exposure, duplicate-order detection, symbol-tradeable
  gate, restricted/hard-to-borrow list, short-sale marking validity and SSR
  compliance, sub-penny (Rule 612) tick validity, self-match prevention, session-state
  validity, and the in-flight credit limit. All limits are scaled integers; all
  comparisons are precomputed where possible (compare `qty > limit_qty` rather than
  `qty * price > notional_limit`).
  ↳ Manual: [08.09 Risk Controls and Limits](manuals/08-nasdaq/09-risk-controls-and-limits.md), [04.05 Order Gateway and Pre-Trade Risk](manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md), [01.02 §4](manuals/01-fpga-design/02-pipelining-and-parallelism.md) · Output: `rtl/risk/pretrade_risk.sv`

- [ ] **P6.3** `S` 🔒 — Implement fail-closed behaviour: all limit registers reset to
  zero, the armed bit resets to 0, and the block rejects everything until explicitly
  configured and armed by the host. A power-cycle or a partial host crash must never
  leave the system able to trade with default limits.
  ↳ Manual: [08.09 Risk Controls and Limits](manuals/08-nasdaq/09-risk-controls-and-limits.md), [CLAUDE.md §5](CLAUDE.md#5-hard-rules-on-the-fast-path) · Output: `rtl/risk/arm_control.sv`

- [ ] **P6.4** `S` 🔒 — Implement position, exposure, and message-rate accumulators as
  **saturating** counters with widths proven sufficient for a full session at maximum
  rate. A wrapping position counter turns a limit breach into an unlimited position.
  ↳ Manual: [08.09 Risk Controls and Limits](manuals/08-nasdaq/09-risk-controls-and-limits.md) · Output: `rtl/risk/accumulators.sv`

- [ ] **P6.5** `S` 🔒 — Implement a per-check rejection counter plus a
  last-rejection register capturing (symbol, check ID, timestamp, offending value).
  When the desk asks "why did it stop trading", the answer must be a register read,
  not an investigation.
  ↳ Manual: [06.03 Monitoring and Telemetry](manuals/06-operations/03-monitoring-and-telemetry.md), [CLAUDE.md §5](CLAUDE.md#5-hard-rules-on-the-fast-path) · Output: `rtl/risk/reject_counters.sv`

- [ ] **P6.6** `M` 🔒 — Implement the **kill switch**: a single register write stops
  all outbound order flow within a bounded, documented number of cycles. Also define
  and implement what happens to in-flight orders and whether it triggers mass-cancel.
  Provide at least two independent trip paths (host write, and host-heartbeat
  timeout — see P7.10). Assert the cycle bound in simulation.
  ↳ Manual: [04.05 Order Gateway and Pre-Trade Risk](manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md), [03.06 Risk and Compliance](manuals/03-algotrading/06-risk-and-compliance.md) · Output: `rtl/risk/kill_switch.sv`, `docs/kill-switch.md`

- [ ] **P6.7** `M` ⏱ — Implement the OUCH 5.0 encoder using **pre-built per-symbol
  templates in BRAM**. Almost every field is constant per symbol; on trigger, read the
  template and splice in price, size, side, and token. This turns "encode an order"
  from a serialization into a memory read plus a mux, and it is described in the
  manuals as the single highest-leverage precompute in a trading FPGA.
  ↳ Manual: [08.05 OUCH Reference](manuals/08-nasdaq/05-ouch-5.0-order-entry.md), [01.02 §4](manuals/01-fpga-design/02-pipelining-and-parallelism.md), [04.05 Order Gateway and Pre-Trade Risk](manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md) · Output: `rtl/gateway/ouch_encoder.sv`, `rtl/gateway/order_templates.sv`

- [ ] **P6.8** `M` 🔒 — Implement order token generation: unique, monotonic, encoding
  enough to reconstruct provenance (session, sequence, symbol), and recoverable across
  a restart without reuse. Token collision means you cannot reconcile fills, which
  means you do not know your position.
  ↳ Manual: [08.05 OUCH Reference](manuals/08-nasdaq/05-ouch-5.0-order-entry.md), [03.04 Order Entry Protocols](manuals/03-algotrading/04-order-entry-protocols.md) · Output: `rtl/gateway/token_gen.sv`

- [ ] **P6.9** `L` ⏱ — Implement the hybrid SoupBinTCP/TCP send path: the host owns
  the TCP handshake, the SoupBinTCP login, sequence negotiation, and teardown; the
  fabric owns steady-state transmission with a handed-off TCP sequence number and
  window. Define precisely how control transfers between them and what happens if the
  host and fabric disagree about the sequence number (answer: stop trading and
  resynchronize — never guess).
  ↳ Manual: [02.02 IP, UDP, TCP in Hardware](manuals/02-networking/02-ip-udp-tcp-in-hardware.md), [03.04 Order Entry Protocols](manuals/03-algotrading/04-order-entry-protocols.md), [08.05 OUCH Reference](manuals/08-nasdaq/05-ouch-5.0-order-entry.md) · Output: `rtl/gateway/soup_tx.sv`, `host/gateway/session.cpp`

- [ ] **P6.10** `M` 🔒 — Implement in-flight credit limiting: a bounded number of
  unacknowledged orders outstanding, decremented on ack. Without this, an ack-path
  stall lets the strategy fire unboundedly into a venue that isn't responding.
  ↳ Manual: [01.01 RTL Design Patterns](manuals/01-fpga-design/01-rtl-design-patterns.md), [04.05 Order Gateway and Pre-Trade Risk](manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md) · Output: `rtl/gateway/credit.sv`

- [ ] **P6.11** `M` 🔒 ⏱ — Implement and measure the **cancel** path. For a passive
  strategy the cancel is where the money is; a cancel that is slower than the order
  path is a design error. The risk block must not delay cancels — cancels reduce
  exposure and should pass a reduced check set.
  ↳ Manual: [03.02 Order Types and Matching Engines](manuals/03-algotrading/02-order-types-and-matching-engines.md), [08.05 OUCH Reference](manuals/08-nasdaq/05-ouch-5.0-order-entry.md) · Output: `rtl/gateway/cancel_path.sv`

- [ ] **P6.12** `L` 🔒 — Build the **"every check proven to fire" test matrix**: one
  directed cocotb test per row of `docs/risk-checks.md` that drives the block into
  rejecting for exactly that reason, asserts the correct reject code, asserts the
  correct counter incremented, and asserts no order left the block. Generate an
  evidence table from the test run and publish it as a CI artifact — this is what you
  hand to the compliance reviewer in Phase 9.
  ↳ Manual: [06.04 Testing Strategy](manuals/06-operations/04-testing-strategy.md), [08.09 Risk Controls and Limits](manuals/08-nasdaq/09-risk-controls-and-limits.md) · Output: `tb/risk/test_matrix.py`, `docs/risk-evidence.md`

- [ ] **P6.13** `M` 🔒 — Prove **structurally** that risk cannot be bypassed: SVA
  assertions in RTL plus a post-synthesis netlist connectivity check that no path
  exists from the strategy trigger or from any host-writable data path to the TX
  framer except through the risk block. Run it in CI on every build. An assertion in
  a testbench proves a scenario; a netlist check proves the invariant.
  ↳ Manual: [04.05 Order Gateway and Pre-Trade Risk](manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md), [CLAUDE.md §5](CLAUDE.md#5-hard-rules-on-the-fast-path) · Output: `scripts/ci/check_risk_path.tcl`, `rtl/risk/risk_sva.sv`

- [ ] **P6.14** `M` ⏱ — Close post-route timing and resource budget for the full fast
  path: feed → book → strategy → risk → encode → TX. This is the first build of the
  whole datapath; expect the four usual suspects (book update, trigger comparison,
  symbol lookup, high-fanout enable).
  ↳ Manual: [00.05 Timing Closure](manuals/00-foundations/05-timing-closure.md), [05.02 Fmax and Timing Optimization](manuals/05-optimization/02-fmax-and-timing-optimization.md) · Output: `docs/timing/fastpath-v1.md`

---

# Phase 7 — Host Software & Control Plane

**Goal.** Everything that must be correct but need not be fast. This phase can and
should run **in parallel with Phases 2–6** — it has no RTL dependency beyond an agreed
register map, which is why P7.2 comes early and is generated rather than
hand-maintained.

**Exit criteria**

> - [ ] The register map is generated from one source into both SystemVerilog and C++;
>       a mismatch is a build failure, not a debugging session.
> - [ ] The control daemon can arm, disarm, kill, load parameters, and read every
>       counter, and does so through a scriptable interface.
> - [ ] Position and PnL reconcile exactly against OUCH acks/fills and the drop copy
>       for a full simulated session, with zero unexplained drift.
> - [ ] A gap triggers automatic Glimpse-based recovery, and the book is verified
>       correct after recovery.
> - [ ] Killing the control daemon with `SIGKILL` trips the hardware kill switch
>       within the documented bound — tested, not assumed.
> - [ ] Every order, reject, parameter change, arm/disarm, and kill is in a durable,
>       timestamped, tamper-evident audit log.

- [ ] **P7.1** `M` — Bring up PCIe and DMA: BAR-mapped control registers plus DMA
  rings for bulk telemetry and logging. Keep the control plane and the data plane
  distinct — a slow log drain must never stall a register read.
  ↳ Manual: [04.06 CPU/FPGA Partitioning](manuals/04-system-architecture/06-cpu-fpga-partitioning.md), [01.04 IO, Transceivers, and SerDes](manuals/01-fpga-design/04-io-transceivers-and-serdes.md) · Output: `rtl/host/pcie_shell.sv`, `host/driver/`

- [ ] **P7.2** `M` — Define the control register map in **one** machine-readable
  source (YAML), and generate from it: the SystemVerilog register file, the C++
  accessor header, the documentation table, and the CI check that RTL and host agree.
  Hand-maintained register maps drift, and the drift is discovered at 3 a.m.
  ↳ Manual: [04.06 CPU/FPGA Partitioning](manuals/04-system-architecture/06-cpu-fpga-partitioning.md), [06.03 Monitoring and Telemetry](manuals/06-operations/03-monitoring-and-telemetry.md) · Output: `docs/regmap.yaml`, `scripts/gen_regmap.py`, `rtl/host/regfile.sv`, `host/include/regmap.hpp`

- [ ] **P7.3** `L` 🔒 — Build the control daemon: start-of-day arming sequence,
  parameter load, health polling, counter scraping, kill-switch trigger, and a
  scriptable CLI. Design it so the *safe* action is the default and the dangerous
  action requires an explicit confirmation.
  ↳ Manual: [04.06 CPU/FPGA Partitioning](manuals/04-system-architecture/06-cpu-fpga-partitioning.md), [06.03 Monitoring and Telemetry](manuals/06-operations/03-monitoring-and-telemetry.md) · Output: `host/control/daemon.cpp`, `host/control/cli.cpp`

- [ ] **P7.4** `M` — Implement symbol table loading: consume `Stock Directory`
  messages at start of day, intersect with the configured trading universe, produce
  the locate → slot mapping, and push it to fabric. Handle symbol changes, new
  listings, and the case where a symbol you trade isn't in today's directory.
  ↳ Manual: [08.04 TotalView-ITCH Reference](manuals/08-nasdaq/04-totalview-itch-5.0.md), [04.02 Feed Handler Design](manuals/04-system-architecture/02-feed-handler-design.md) · Output: `host/control/symbol_loader.cpp`

- [ ] **P7.5** `M` 🔒 — Implement parameter loading with atomic commit and mandatory
  **readback verification**: write shadow, read back, compare, then commit. Never
  trust a write you didn't verify — a stuck bit in a limit register is a limit you
  don't have.
  ↳ Manual: [04.04 Strategy Engine on FPGA](manuals/04-system-architecture/04-strategy-engine-on-fpga.md) · Output: `host/control/param_loader.cpp`

- [ ] **P7.6** `L` 🔒 — Implement position and PnL reconciliation: track every order
  by token, apply every ack/fill/cancel/reject, reconcile against the venue's drop
  copy and end-of-day statement, and alarm on any discrepancy immediately rather than
  at end of day. Position drift is how a bounded strategy becomes an unbounded one.
  ↳ Manual: [03.04 Order Entry Protocols](manuals/03-algotrading/04-order-entry-protocols.md), [03.06 Risk and Compliance](manuals/03-algotrading/06-risk-and-compliance.md) · Output: `host/control/position.cpp`, `host/control/recon.cpp`

- [ ] **P7.7** `L` 🔒 — Implement session management and recovery: SoupBinTCP login,
  sequence negotiation, heartbeats, reconnect with correct sequence resumption, and
  the cancel-on-disconnect policy. Decide and document what the system does on an
  unexpected disconnect mid-session — including whether it re-arms automatically
  (it should not).
  ↳ Manual: [03.04 Order Entry Protocols](manuals/03-algotrading/04-order-entry-protocols.md), [08.05 OUCH Reference](manuals/08-nasdaq/05-ouch-5.0-order-entry.md) · Output: `host/gateway/session.cpp`

- [ ] **P7.8** `L` — Implement gap recovery: MoldUDP64 retransmission requests for
  small gaps, and a Glimpse snapshot for large ones, feeding the P4.7 resync path.
  Include the decision rule for which to use and the timeout that escalates from one
  to the other. Verify the recovered book against the golden model.
  ↳ Manual: [02.03 Multicast Feeds and Arbitration](manuals/02-networking/03-multicast-feeds-and-arbitration.md), [08.04 TotalView-ITCH Reference](manuals/08-nasdaq/04-totalview-itch-5.0.md) · Output: `host/feed/recovery.cpp`

- [ ] **P7.9** `M` 🔒 — Implement logging and the audit trail: every outbound order,
  every reject with its reason code, every parameter change with before/after values
  and the identity that made it, every arm/disarm, every kill. Durable, timestamped
  to the same clock as the CAT requirement, and write-once.
  ↳ Manual: [03.06 Risk and Compliance](manuals/03-algotrading/06-risk-and-compliance.md), [06.03 Monitoring and Telemetry](manuals/06-operations/03-monitoring-and-telemetry.md) · Output: `host/log/audit.cpp`

- [ ] **P7.10** `M` 🔒 — Implement the host watchdog as a **hardware** timer: the
  daemon writes a heartbeat register; if the heartbeat stops for longer than the
  configured window, the fabric trips the kill switch autonomously. A software
  watchdog cannot save you from a dead host.
  ↳ Manual: [04.05 Order Gateway and Pre-Trade Risk](manuals/04-system-architecture/05-order-gateway-and-pre-trade-risk.md), [06.03 Monitoring and Telemetry](manuals/06-operations/03-monitoring-and-telemetry.md) · Output: `rtl/host/watchdog.sv`, `host/control/heartbeat.cpp`

- [ ] **P7.11** `M` — Export telemetry: scrape all fabric counters and latency
  histograms on a fixed cadence into a metrics backend, with alert rules on drops,
  gaps, rejects, kill-switch state, position, and latency percentiles.
  ↳ Manual: [06.03 Monitoring and Telemetry](manuals/06-operations/03-monitoring-and-telemetry.md) · Output: `host/telemetry/`, `docs/alerts.md`

- [ ] **P7.12** `M` — Automate the start-of-day and end-of-day sequences as scripts,
  not as tribal knowledge: link check, feed check, symbol load, parameter load,
  readback verify, arm, and the reverse. Every step logs, and any failure halts the
  sequence rather than continuing.
  ↳ Manual: [06.02 Deployment and Colocation](manuals/06-operations/02-deployment-and-colocation.md), [07.04 Checklists](manuals/07-reference/04-checklists.md) · Output: `scripts/ops/sod.sh`, `scripts/ops/eod.sh`

- [ ] **P7.13** `S` 🔒 — Pair the build ID and the config ID: the daemon reads the
  bitstream build ID from a register, hashes the loaded configuration, and refuses to
  arm if either doesn't match what the release manifest says should be running.
  ↳ Manual: [06.01 Build and Release](manuals/06-operations/01-build-and-release.md) · Output: `host/control/build_check.cpp`

---

# Phase 8 — Integration & Verification

**Goal.** Put it all together, break it deliberately, and produce **the first honest
end-to-end tick-to-trade number**, measured on hardware, reported as a distribution.

**Exit criteria**

> - [ ] Full-path simulation (pcap in → OUCH bytes out) matches the golden end-to-end
>       model over the full corpus, with zero divergences.
> - [ ] Hardware-in-the-loop against a market simulator runs a full simulated session
>       cleanly, including fills, partial fills, rejects, and cancels.
> - [ ] Every fault in the P8.4 injection list has been injected and the system's
>       response is documented and correct — degraded and counted, never silent and
>       never wrong.
> - [ ] 8-hour soak at realistic peak rate: zero drops, zero unexplained counter
>       increments, no drift in latency distribution.
> - [ ] On-chip latency histograms live and readable per stage.
> - [ ] `docs/measurements/tick-to-trade-v1.md` exists with p50/p99/p99.9/max and N,
>       labelled **measured**, with the loopback calibration subtracted and stated.
> - [ ] Determinism proven: the same stimulus twice produces identical output bytes at
>       identical cycle offsets.

- [ ] **P8.1** `L` — Build the full-path simulation: pcap in, OUCH bytes out, compared
  against an end-to-end golden pipeline (P1.2 → P1.3 → P1.4 → P1.5 → encoder). This is
  the regression that guards every subsequent change.
  ↳ Manual: [06.04 Testing Strategy](manuals/06-operations/04-testing-strategy.md), [01.05 Verification and Simulation](manuals/01-fpga-design/05-verification-and-simulation.md) · Output: `tb/system/test_e2e.py`

- [ ] **P8.2** `L` — Build the market simulator: accepts SoupBinTCP/OUCH, validates
  messages against the spec, generates acks, fills, partial fills, rejects, and
  cancel-acks with configurable latency and failure modes, and emits the corresponding
  ITCH back on the feed so the book sees your own orders. Without this you cannot test
  the closed loop.
  ↳ Manual: [06.04 Testing Strategy](manuals/06-operations/04-testing-strategy.md), [08.05 OUCH Reference](manuals/08-nasdaq/05-ouch-5.0-order-entry.md) · Output: `host/tools/marketsim/`

- [ ] **P8.3** `M` — Stand up hardware-in-the-loop: the FPGA on real optics talking to
  the market simulator on another machine, running the corpus at real time and at
  accelerated rates.
  ↳ Manual: [06.04 Testing Strategy](manuals/06-operations/04-testing-strategy.md), [06.02 Deployment and Colocation](manuals/06-operations/02-deployment-and-colocation.md) · Output: `docs/hil-setup.md`, `scripts/hil/`

- [ ] **P8.4** `L` 🔒 — Fault injection campaign. At minimum: CRC errors, truncated
  frames, oversized frames, sequence gaps of 1/100/100000, duplicate sequences,
  out-of-order arrival, one line of the A/B pair dying, both lines dying, TCP
  disconnect mid-order, TCP window collapse, venue silence (no acks), PCIe stall,
  host daemon `SIGKILL`, clock loss, link flap, book capacity overflow, order-map
  collision overflow, and a parameter table with deliberately absurd values. Document
  the expected and observed behaviour for each.
  ↳ Manual: [06.04 Testing Strategy](manuals/06-operations/04-testing-strategy.md), [02.03 Multicast Feeds and Arbitration](manuals/02-networking/03-multicast-feeds-and-arbitration.md) · Output: `tb/system/faults/`, `docs/fault-injection-results.md`

- [ ] **P8.5** `M` — Run the soak: minimum 8 hours continuous at realistic peak rate,
  ideally overnight and repeatedly. Watch for slow leaks — counter drift, latency
  creep, a FIFO that fills over hours, a token counter approaching its width.
  ↳ Manual: [06.04 Testing Strategy](manuals/06-operations/04-testing-strategy.md) · Output: `docs/soak-results.md`

- [ ] **P8.6** `M` ⏱ — Implement on-chip latency instrumentation: per-stage timestamp
  deltas accumulated into hardware histograms (log-spaced buckets), readable over
  PCIe without perturbing the fast path. This is the instrument that makes Phase 11
  possible; build it properly.
  ↳ Manual: [05.04 Measurement and Profiling](manuals/05-optimization/04-measurement-and-profiling.md), [06.03 Monitoring and Telemetry](manuals/06-operations/03-monitoring-and-telemetry.md) · Output: `rtl/common/latency_hist.sv`, `host/telemetry/hist_reader.cpp`

- [ ] **P8.7** `M` ⏱ — Calibrate the measurement harness: characterize the loopback,
  the timestamping resolution, and the test equipment's own latency, so that the
  number you report is the system's and not the harness's. State the calibration
  method in the results document.
  ↳ Manual: [05.04 Measurement and Profiling](manuals/05-optimization/04-measurement-and-profiling.md) · Output: `docs/measurements/calibration.md`

- [ ] **P8.8** `M` ⏱ — **Produce the first measured end-to-end tick-to-trade number.**
  Wire-to-wire, on hardware, with N stated, reported as p50 / p99 / p99.9 / max —
  never as a mean, per [CLAUDE.md §5](CLAUDE.md#5-hard-rules-on-the-fast-path). Break
  it down per stage against `docs/latency-budget.md` and record every place reality
  differs from the budget. This document is the baseline that Phase 11 optimizes
  against.
  ↳ Manual: [05.04 Measurement and Profiling](manuals/05-optimization/04-measurement-and-profiling.md), [05.01 Latency Budgeting](manuals/05-optimization/01-latency-budgeting.md) · Output: `docs/measurements/tick-to-trade-v1.md`

- [ ] **P8.9** `S` ⏱ — Prove determinism: replay the same stimulus twice and assert
  byte-identical output at identical cycle offsets. Then measure jitter under load and
  quantify every source of it (arbitration, the delete-the-best rescan, bank
  collisions). Determinism is worth more than a lower mean.
  ↳ Manual: [01.02 §9](manuals/01-fpga-design/02-pipelining-and-parallelism.md), [05.04 Measurement and Profiling](manuals/05-optimization/04-measurement-and-profiling.md) · Output: `tb/system/test_determinism.py`, `docs/jitter-analysis.md`

- [ ] **P8.10** `M` — Sign off coverage: every ITCH message type exercised, every book
  operation exercised, every risk check exercised, every FSM state and legal
  transition reached, every counter incremented at least once. Publish the gaps you
  are consciously accepting.
  ↳ Manual: [01.05 Verification and Simulation](manuals/01-fpga-design/05-verification-and-simulation.md), [06.04 Testing Strategy](manuals/06-operations/04-testing-strategy.md) · Output: `docs/coverage-signoff.md`

- [ ] **P8.11** `S` — Lock the full regression into CI as the merge gate: lint, unit
  sims, corpus regression, risk matrix, netlist risk-path check, P&R timing, and the
  latency check from P11.12 once it exists.
  ↳ Manual: [06.01 Build and Release](manuals/06-operations/01-build-and-release.md) · Output: `scripts/ci/gate.sh`

---

# Phase 9 — Compliance & Conformance

**Goal.** Make the system legally able to trade, and be able to *prove* it — with an
evidence trail that maps each obligation to a specific feature, a specific test, and a
specific register. Start this phase early; conformance scheduling and sponsor sign-off
are the classic long-lead-time items and they are not compressible by working harder.

**Exit criteria**

> - [ ] Nasdaq conformance testing passed for every ITCH message consumed and every
>       OUCH message and order type sent, with the certificate on file.
> - [ ] CAT reporting produces correct, complete, timely records for a full simulated
>       session, validated end to end.
> - [ ] Clock synchronization meets the required granularity, with continuous drift
>       monitoring and alarming.
> - [ ] The compliance-to-feature evidence matrix is complete: every obligation →
>       feature → test → register/counter.
> - [ ] The broker-dealer/sponsor has signed off on the risk limits, the kill
>       procedures, and the escalation path.
> - [ ] Written supervisory procedures exist and name real people.

- [ ] **P9.1** `L` 🔒 — Build the CAT reporting pipeline: capture every reportable
  event (order origination, route, modify, cancel, execution) with the required
  fields and timestamps, transform to the CAT format, submit, and handle rejections
  and corrections. Reconcile counts daily.
  ↳ Manual: [03.06 Risk and Compliance](manuals/03-algotrading/06-risk-and-compliance.md), [08.06 Reg NMS and Compliance](manuals/08-nasdaq/06-regnms-and-compliance.md) · Output: `host/compliance/cat/`, `docs/cat-reporting.md`

- [ ] **P9.2** `M` 🔒 — Implement clock synchronization and prove it: PTP or GPS
  discipline, a fabric timestamp counter traceable to it, continuous offset
  monitoring, and an alarm when drift exceeds the regulatory tolerance. Timestamps
  that cannot be defended make the whole audit trail worthless.
  ↳ Manual: [06.02 Deployment and Colocation](manuals/06-operations/02-deployment-and-colocation.md), [03.06 Risk and Compliance](manuals/03-algotrading/06-risk-and-compliance.md) · Output: `rtl/common/ptp_clock.sv`, `host/compliance/clock_monitor.cpp`, `docs/clock-sync.md`

- [ ] **P9.3** `M` 🔒 — Implement and validate Reg SHO handling: correct short-sale
  marking on every outbound order, locate tracking, and SSR (the short-sale price
  test) enforcement in the risk block when a symbol is restricted. Prove each with a
  directed test.
  ↳ Manual: [08.06 Reg NMS and Compliance](manuals/08-nasdaq/06-regnms-and-compliance.md), [08.09 Risk Controls and Limits](manuals/08-nasdaq/09-risk-controls-and-limits.md) · Output: `rtl/risk/reg_sho.sv`, `docs/reg-sho-evidence.md`

- [ ] **P9.4** `S` 🔒 — Validate Rule 612 (sub-penny) compliance in hardware: reject
  any order whose limit price violates the minimum pricing increment for that
  symbol's price band. This is a risk check, not a formatting concern.
  ↳ Manual: [08.06 Reg NMS and Compliance](manuals/08-nasdaq/06-regnms-and-compliance.md) · Output: `rtl/risk/tick_check.sv`

- [ ] **P9.5** `M` 🔒 — Document the Reg NMS order-protection posture: whether the
  strategy can ever trade through a protected quote, whether ISO orders are used and
  under what conditions, and what enforces it. If the answer is "our order types
  cannot trade through", say so and prove it.
  ↳ Manual: [08.06 Reg NMS and Compliance](manuals/08-nasdaq/06-regnms-and-compliance.md), [03.01 Market Microstructure](manuals/03-algotrading/01-market-microstructure.md) · Output: `docs/reg-nms-posture.md`

- [ ] **P9.6** `M` 🔒 — Build the **compliance-to-feature evidence matrix**: every
  obligation (15c3-5 controls, Reg SHO, Rule 612, CAT, clock sync, records retention)
  mapped to the feature that satisfies it, the test that proves the feature, and the
  register or log that evidences it in production. This document is what an examiner
  reads.
  ↳ Manual: [03.06 Risk and Compliance](manuals/03-algotrading/06-risk-and-compliance.md), [08.09 Risk Controls and Limits](manuals/08-nasdaq/09-risk-controls-and-limits.md) · Output: `docs/compliance-matrix.md`

- [ ] **P9.7** `L` 🔒 — Complete Nasdaq conformance testing in the test environment:
  ITCH consumption, OUCH order entry, every order type and modifier you intend to use,
  cancel and replace behaviour, session recovery, and the mass-cancel/kill procedure.
  Schedule this early — the queue is the constraint, not your readiness.
  ↳ Manual: [08.05 OUCH Reference](manuals/08-nasdaq/05-ouch-5.0-order-entry.md), [06.02 Deployment and Colocation](manuals/06-operations/02-deployment-and-colocation.md) · Output: conformance certificate, `docs/conformance-report.md`

- [ ] **P9.8** `M` 🔒 — Obtain broker-dealer / sponsor sign-off on risk limits, the
  kill-switch procedure, the escalation contacts, and the daily limit-review process.
  Get the agreed limits into `docs/risk-limits.md` as the single source of truth, and
  have the loader read from it.
  ↳ Manual: [03.06 Risk and Compliance](manuals/03-algotrading/06-risk-and-compliance.md), [08.09 Risk Controls and Limits](manuals/08-nasdaq/09-risk-controls-and-limits.md) · Output: `docs/risk-limits.md`, signed sign-off

- [ ] **P9.9** `M` 🔒 — Write the operational governance documents: written
  supervisory procedures, the incident response runbook (including "we sent a bad
  order" and "we cannot cancel"), the escalation tree with real names and phone
  numbers, and the change-control policy for limits and bitstreams.
  ↳ Manual: [07.04 Checklists](manuals/07-reference/04-checklists.md), [06.02 Deployment and Colocation](manuals/06-operations/02-deployment-and-colocation.md) · Output: `docs/runbooks/`, `docs/incident-response.md`

- [ ] **P9.10** `M` — Review Reg SCI applicability, business continuity, disaster
  recovery, and records retention (17a-4 write-once storage for the audit trail).
  Document what applies, what doesn't, and why.
  ↳ Manual: [03.06 Risk and Compliance](manuals/03-algotrading/06-risk-and-compliance.md) · Output: `docs/regulatory-applicability.md`

---

# Phase 10 — Deployment

**Goal.** Get the system into the colo, prove the physical layer, and trade **one
symbol at minimum size** with someone's hand on the kill switch. The canary is not a
formality; it is the only test that includes the real matching engine, the real
latency, and real money.

**Exit criteria**

> - [ ] Cabinet, power, cooling, and cross-connects live and tested; optics validated
>       with real link-quality metrics over 24 hours.
> - [ ] The deployed bitstream's build ID, read from a register, matches the release
>       manifest exactly; the daemon refuses to arm otherwise.
> - [ ] The full pre-deployment checklist is signed off.
> - [ ] The canary has traded one symbol at minimum size for the agreed number of
>       sessions with zero unexplained events.
> - [ ] Monitoring and alerting are live, and a real alert has been fired and
>       acknowledged end to end.
> - [ ] A kill-switch drill has been performed on a live session, with the response
>       time measured.
> - [ ] Graduation criteria are written down and were agreed *before* the canary
>       started.

- [ ] **P10.1** `L` — Secure colocation: cabinet in the Nasdaq colo facility, power,
  cooling, remote hands arrangements, and physical access procedures.
  ↳ Manual: [06.02 Deployment and Colocation](manuals/06-operations/02-deployment-and-colocation.md) · Output: `docs/colo-inventory.md`

- [ ] **P10.2** `M` — Order and commission cross-connects: market data A and B on
  diverse paths, order entry ports, and the management network. Verify each
  independently before relying on any of them.
  ↳ Manual: [06.02 Deployment and Colocation](manuals/06-operations/02-deployment-and-colocation.md), [02.04 NICs, Kernel Bypass, and Switching](manuals/02-networking/04-nics-kernel-bypass-and-switching.md) · Output: `docs/cross-connects.md`

- [ ] **P10.3** `S` ⏱ — Specify, buy, and test the optics and cabling, including
  spares. Fibre length is latency: know and record the length of every run. Log DOM
  metrics as a baseline so you can spot a degrading transceiver later.
  ↳ Manual: [06.02 Deployment and Colocation](manuals/06-operations/02-deployment-and-colocation.md), [07.02 Latency Reference Numbers](manuals/07-reference/02-latency-reference-numbers.md) · Output: `docs/optics-bom.md`

- [ ] **P10.4** `M` 🔒 — Write and rehearse the deployment runbook: how a bitstream
  gets loaded, how it is verified, how the system is armed, how it is rolled back, and
  who is allowed to do each. Rehearse the rollback specifically — a rollback you have
  never performed is not a rollback plan.
  ↳ Manual: [06.01 Build and Release](manuals/06-operations/01-build-and-release.md), [06.02 Deployment and Colocation](manuals/06-operations/02-deployment-and-colocation.md) · Output: `docs/runbooks/deploy.md`

- [ ] **P10.5** `S` 🔒 — Implement build-ID verification end to end: the bitstream
  embeds a hash of its source tree and toolchain; a register exposes it; the daemon
  reads it, compares against the signed release manifest, and refuses to arm on a
  mismatch. "Which bitstream is actually running?" must never be a question anyone has
  to investigate.
  ↳ Manual: [06.01 Build and Release](manuals/06-operations/01-build-and-release.md) · Output: `rtl/common/build_id.sv`, `scripts/release/manifest.py`

- [ ] **P10.6** `S` 🔒 — Work the pre-deployment checklist and get it signed. Not a
  formality — it is the accumulated list of the things that have gone wrong for other
  people.
  ↳ Manual: [07.04 Checklists](manuals/07-reference/04-checklists.md) · Output: signed `docs/checklists/pre-deployment-<date>.md`

- [ ] **P10.7** `M` 🔒 — Run the **canary**: one liquid symbol, minimum order size, the
  tightest risk limits the strategy can function under, a short session window, and a
  named person watching with the kill switch available. Reconcile position and PnL
  after every session.
  ↳ Manual: [06.04 Testing Strategy](manuals/06-operations/04-testing-strategy.md), [06.02 Deployment and Colocation](manuals/06-operations/02-deployment-and-colocation.md) · Output: `docs/canary-log.md`

- [ ] **P10.8** `S` 🔒 — Write the graduation criteria **before** the canary starts:
  how many clean sessions, what fill-rate and reject-rate thresholds, what
  reconciliation tolerance (zero), what latency stability, and the specific ladder for
  widening — more size, then more symbols, then looser limits, one axis at a time.
  ↳ Manual: [06.04 Testing Strategy](manuals/06-operations/04-testing-strategy.md) · Output: `docs/graduation-criteria.md`

- [ ] **P10.9** `M` — Take monitoring and alerting live: dashboards for counters,
  latency percentiles, position, PnL, feed health, session health, and kill-switch
  state; paging alerts for anything that should stop trading. Test that an alert
  actually reaches a human.
  ↳ Manual: [06.03 Monitoring and Telemetry](manuals/06-operations/03-monitoring-and-telemetry.md) · Output: dashboards, `docs/alerts.md` (live)

- [ ] **P10.10** `S` 🔒 — Run a kill-switch drill on a live session, out of hours if
  necessary: trip it, measure the time to zero outbound flow, verify the audit trail
  captured it, and verify the recovery procedure. Repeat quarterly.
  ↳ Manual: [07.04 Checklists](manuals/07-reference/04-checklists.md), [06.02 Deployment and Colocation](manuals/06-operations/02-deployment-and-colocation.md) · Output: `docs/drills/kill-switch-<date>.md`

- [ ] **P10.11** `S` ⏱ — Measure tick-to-trade **in production** against real market
  data and the real venue, and compare against the P8.8 lab number. Any divergence is
  a finding, not a footnote.
  ↳ Manual: [05.04 Measurement and Profiling](manuals/05-optimization/04-measurement-and-profiling.md) · Output: `docs/measurements/tick-to-trade-prod-v1.md`

---

# Phase 11 — Optimization ⏱

**Goal.** Make it faster, with evidence, in the order the playbook prescribes. This
phase is structured directly around
[05.05 Optimization Playbook](manuals/05-optimization/05-optimization-playbook.md) and
runs the loop from [CLAUDE.md §7](CLAUDE.md#7-optimization-loop):

```
measure → attribute → hypothesize → change one thing → re-measure → keep or revert
```

**The rule that governs this entire phase:** *do not optimize without a measurement.*
Intuition about FPGA latency is reliably wrong. Every tier below ends with a mandatory
re-measure task, and no change is "kept" until the re-measurement says so.

**Exit criteria**

> - [ ] A frozen, reproducible baseline exists with a full distribution and N stated,
>       and every subsequent measurement is comparable to it.
> - [ ] 100 % of the wire-to-wire number is attributed to a named stage — no
>       "unaccounted" bucket larger than the measurement resolution.
> - [ ] Every tier has been worked in order, and each attempted change has a ledger
>       entry recording hypothesis, delta, and kept/reverted.
> - [ ] CI fails a build that regresses p99 tick-to-trade beyond the agreed threshold.
> - [ ] The final number is reported as p50/p99/p99.9/max, measured, with the
>       methodology stated — and it is defensible to someone who wants to disbelieve
>       it.

### 11.A — Measure and attribute first

- [ ] **P11.1** `M` ⏱ — Freeze the **baseline**: a reproducible measurement run, on
  the production configuration, with the seed, bitstream build ID, corpus version, and
  N recorded. Nothing in this phase may be compared against anything else.
  ↳ Manual: [05.04 Measurement and Profiling](manuals/05-optimization/04-measurement-and-profiling.md) · Output: `docs/measurements/baseline.md`

- [ ] **P11.2** `M` ⏱ — Attribute every nanosecond: per-stage histograms from P8.6
  summed against the wire-to-wire total, with the residual explicitly named. If 40 ns
  is unaccounted for, find it before touching anything — unattributed latency is
  where the cheap wins hide.
  ↳ Manual: [05.04 Measurement and Profiling](manuals/05-optimization/04-measurement-and-profiling.md), [05.01 Latency Budgeting](manuals/05-optimization/01-latency-budgeting.md) · Output: `docs/latency-attribution.md`

- [ ] **P11.3** `S` ⏱ — Create the **latency ledger**: one row per stage with budgeted
  ns, measured ns, delta, and rank by absolute overrun. This ranking, not preference,
  determines what gets worked on. Re-generate it after every change.
  ↳ Manual: [05.01 Latency Budgeting](manuals/05-optimization/01-latency-budgeting.md), [05.05 Optimization Playbook](manuals/05-optimization/05-optimization-playbook.md) · Output: `docs/latency-ledger.md`

- [ ] **P11.4** `S` — Set up the optimization experiment log: one entry per attempted
  change with hypothesis, the single thing changed, measured delta (with N), and the
  kept/reverted decision. Reverted experiments are as valuable as kept ones and must
  be recorded, or someone will retry them in six months.
  ↳ Manual: [CLAUDE.md §7](CLAUDE.md#7-optimization-loop), [05.05 Optimization Playbook](manuals/05-optimization/05-optimization-playbook.md) · Output: `docs/optimization-log.md`

### 11.B — Tier 1: free wins

- [ ] **P11.5** `M` ⏱ — Work the free wins: verify every constraint is correct and
  none are phantom; strip pipeline stages whose only justification was "it seemed
  cleaner"; move any remaining fast-path arithmetic into precomputed table lookups;
  sweep implementation strategies and seeds; check the MAC is genuinely cut-through
  and the GT elastic buffers are in the lowest-latency mode; disable instrumentation
  that sits in the datapath rather than beside it.
  ↳ Manual: [05.05 Optimization Playbook](manuals/05-optimization/05-optimization-playbook.md), [00.05 §4 Tier 1–2](manuals/00-foundations/05-timing-closure.md), [01.02 §4](manuals/01-fpga-design/02-pipelining-and-parallelism.md) · Output: RTL/constraint changes + ledger entries

- [ ] **P11.6** `S` ⏱ — **Re-measure and record** after Tier 1. Update the ledger and
  the attribution; keep or revert each change on the evidence.
  ↳ Manual: [05.04 Measurement and Profiling](manuals/05-optimization/04-measurement-and-profiling.md) · Output: `docs/measurements/post-tier1.md`

### 11.C — Tier 2: architectural

- [ ] **P11.7** `L` ⏱ — Work the architectural changes: widen the datapath so the
  latency-critical message fits in one beat (if P0.6 didn't already); move the symbol
  lookup from BRAM into LUTRAM or registers if the universe is small enough (worth a
  full cycle); hold top-of-book for the traded universe in registers rather than
  memory; **speculatively issue the order-template read on every book update** rather
  than after the trigger resolves; speculatively encode both sides and select late;
  evaluate risk against both candidate sizes in parallel.
  ↳ Manual: [05.05 Optimization Playbook](manuals/05-optimization/05-optimization-playbook.md), [01.02 §3–§5](manuals/01-fpga-design/02-pipelining-and-parallelism.md), [01.03 Memory and Storage](manuals/01-fpga-design/03-memory-and-storage.md) · Output: RTL changes + ledger entries

- [ ] **P11.8** `S` ⏱ — **Re-measure and record** after Tier 2, including a full
  golden-model regression — architectural changes are exactly where correctness
  regressions hide.
  ↳ Manual: [05.04 Measurement and Profiling](manuals/05-optimization/04-measurement-and-profiling.md) · Output: `docs/measurements/post-tier2.md`

### 11.D — Tier 3: pipeline surgery

- [ ] **P11.9** `L` ⏱ — Pipeline surgery: merge adjacent stages whose combined logic
  still closes timing (each merged stage is a whole cycle off the wire number); enable
  retiming on the datapath and let the tool rebalance; rebalance stages by hand where
  one is at 3 logic levels and its neighbour at 12; remove the strategy→encode
  dependency entirely. Every removed stage must be re-justified against the module
  header budget, and every remaining stage must still have a written justification.
  ↳ Manual: [05.05 Optimization Playbook](manuals/05-optimization/05-optimization-playbook.md), [01.02 §7, §9](manuals/01-fpga-design/02-pipelining-and-parallelism.md), [05.02 Fmax and Timing Optimization](manuals/05-optimization/02-fmax-and-timing-optimization.md) · Output: RTL changes + ledger entries

- [ ] **P11.10** `S` ⏱ — **Re-measure and record** after Tier 3, including a jitter
  re-analysis — stage merging can convert fixed latency into variable latency, which
  is a regression even when the mean improves.
  ↳ Manual: [05.04 Measurement and Profiling](manuals/05-optimization/04-measurement-and-profiling.md), [01.02 §9](manuals/01-fpga-design/02-pipelining-and-parallelism.md) · Output: `docs/measurements/post-tier3.md`

### 11.E — Tier 4: physical

- [ ] **P11.11** `L` ⏱ — Physical optimization: floorplan the fast path into a pblock
  adjacent to the transceivers and entirely within one SLR; eliminate every SLR
  crossing on the tick-to-trade path; replicate high-fanout drivers; run
  `phys_opt_design` with multiple directives; sweep implementation strategies properly
  across seeds; evaluate a faster speed grade — 10–15 % Fmax for money is frequently
  cheaper than weeks of engineering.
  ↳ Manual: [00.05 §4 Tier 4](manuals/00-foundations/05-timing-closure.md), [05.02 Fmax and Timing Optimization](manuals/05-optimization/02-fmax-and-timing-optimization.md), [05.03 Resource and Power Optimization](manuals/05-optimization/03-resource-power-optimization.md) · Output: `constraints/floorplan.xdc`, `scripts/impl/strategies.tcl` + ledger entries

- [ ] **P11.12** `S` ⏱ — **Re-measure and record** after Tier 4, across a seed sweep.
  Report the distribution across seeds, not the best seed — a design that is fast on
  one seed is not fast.
  ↳ Manual: [00.05 §8–§9](manuals/00-foundations/05-timing-closure.md), [05.04 Measurement and Profiling](manuals/05-optimization/04-measurement-and-profiling.md) · Output: `docs/measurements/post-tier4.md`

### 11.F — Tier 5: advanced (know the rules before you do these)

- [ ] **P11.13** `XL` ⏱ 🔒 — Advanced techniques, each individually justified and
  individually reversible: bypass the MAC and parse straight off the PCS/64b-66b
  stream; shorten the fibre and evaluate DAC over optics where distance allows;
  migrate to 25G for the narrower serialization delay; and — only with **written
  venue approval** — speculative transmission with deliberate CRC abort. That last one
  is real and used, but sending deliberately-invalid frames can trip a venue's error
  thresholds and disconnect policy. Get it in writing before it goes anywhere near
  production.
  ↳ Manual: [05.05 Optimization Playbook](manuals/05-optimization/05-optimization-playbook.md), [01.02 §5](manuals/01-fpga-design/02-pipelining-and-parallelism.md), [02.01 Ethernet PHY and MAC](manuals/02-networking/01-ethernet-phy-mac.md) · Output: ADRs + ledger entries

- [ ] **P11.14** `S` ⏱ — **Re-measure and record** after Tier 5, and re-run the full
  compliance and risk test matrices — Tier 5 changes touch the wire format and the
  order path.
  ↳ Manual: [05.04 Measurement and Profiling](manuals/05-optimization/04-measurement-and-profiling.md) · Output: `docs/measurements/post-tier5.md`

### 11.G — Lock the gains in

- [ ] **P11.15** `M` ⏱ — Add **latency-regression gating to CI**: every build runs the
  standard stimulus through simulation, extracts the cycle count for the canonical
  tick-to-trade path, and fails if it increased. Do the same for post-route WNS and
  utilization. A latency regression must be as loud as a failing test, because it is
  one.
  ↳ Manual: [06.01 Build and Release](manuals/06-operations/01-build-and-release.md), [05.04 Measurement and Profiling](manuals/05-optimization/04-measurement-and-profiling.md) · Output: `scripts/ci/latency_gate.py`, `docs/latency-gate.md`

- [ ] **P11.16** `S` ⏱ — Publish the final optimization report: baseline → each tier →
  final, with the delta attributable to each change, the changes that were reverted
  and why, and the current per-stage ledger. Update `docs/latency-budget.md` so the
  budget reflects reality rather than the original guess.
  ↳ Manual: [05.01 Latency Budgeting](manuals/05-optimization/01-latency-budgeting.md), [05.05 Optimization Playbook](manuals/05-optimization/05-optimization-playbook.md) · Output: `docs/optimization-report.md`

---

# Phase 12 — Scale & Evolve

**Goal.** Turn a working single-symbol system into a business: more symbols, more
venues, more strategies, and an operational cadence that keeps it correct as the
market changes underneath it.

**Exit criteria**

> - [ ] Symbol universe expanded to target, with a capacity analysis proving headroom
>       at the worst observed message rate × 2.
> - [ ] BX and PSX feeds integrated, with per-venue books and per-venue risk.
> - [ ] A second strategy runs on the same fabric without degrading the first.
> - [ ] The operational cadence is running: daily ops, weekly latency review, monthly
>       limit review, quarterly drills.
> - [ ] The manuals have been corrected everywhere production reality diverged from
>       them.

- [ ] **P12.1** `M` — Expand the symbol universe. Capacity analysis **first**: order-map
  occupancy, level-memory usage, message rate per symbol at peak, and the effect on
  the delete-the-best bound. Then widen in steps, per the P10.8 ladder.
  ↳ Manual: [01.03 Memory and Storage](manuals/01-fpga-design/03-memory-and-storage.md), [05.03 Resource and Power Optimization](manuals/05-optimization/03-resource-power-optimization.md) · Output: `docs/capacity-analysis.md`

- [ ] **P12.2** `L` — Add Nasdaq BX and PSX: replicate the decoder and book region per
  venue rather than sharing and arbitrating — replication is the cleanest scaling axis
  and it keeps each pipeline simple. Per-venue risk accounting, aggregate risk limits.
  ↳ Manual: [01.02 §6](manuals/01-fpga-design/02-pipelining-and-parallelism.md), [08.01 Nasdaq Market Structure](manuals/08-nasdaq/01-market-structure.md) · Output: `rtl/feed/venue_replica/`

- [ ] **P12.3** `L` ⏱ — Build a cross-venue consolidated view if the strategy needs it:
  either an in-fabric NBBO across the venues you consume, or SIP consumption for the
  protected quote. Be explicit about which is authoritative for compliance purposes
  versus which is used for trading decisions.
  ↳ Manual: [08.06 Reg NMS and Compliance](manuals/08-nasdaq/06-regnms-and-compliance.md), [03.01 Market Microstructure](manuals/03-algotrading/01-market-microstructure.md) · Output: `rtl/strategy/nbbo.sv`

- [ ] **P12.4** `L` — Add a second strategy. Decide first whether it shares the book
  and gateway (cheaper, coupled, contends on the hot path) or is replicated (more
  fabric, isolated). Aggregate risk limits must apply across both — per-strategy limits
  alone are how firms discover their total exposure was never bounded.
  ↳ Manual: [04.04 Strategy Engine on FPGA](manuals/04-system-architecture/04-strategy-engine-on-fpga.md), [08.09 Risk Controls and Limits](manuals/08-nasdaq/09-risk-controls-and-limits.md) · Output: `rtl/strategy/strategy_b/`

- [ ] **P12.5** `XL` — Evaluate partial reconfiguration for swapping a strategy region
  without dropping the link or the session. Substantial complexity; justify it against
  the alternative of a maintenance-window rebuild before committing.
  ↳ Manual: [01.06 HLS and Alternative Flows](manuals/01-fpga-design/06-hls-and-alternative-flows.md), [06.01 Build and Release](manuals/06-operations/01-build-and-release.md) · Output: `docs/adr/00NN-partial-reconfig.md`

- [ ] **P12.6** `M` — Stress capacity: replay the worst message-rate day observed at
  2× real time and confirm zero drops, no counter saturation, and no latency
  degradation. Repeat after every significant change. Nasdaq message rates only go up.
  ↳ Manual: [06.04 Testing Strategy](manuals/06-operations/04-testing-strategy.md) · Output: `docs/capacity-stress.md`

- [ ] **P12.7** `M` ⏱ — Study the 25G/100G migration: what it buys in serialization
  delay, what it costs in FEC latency (100G FEC can cost more than the width saves —
  check before assuming), and what the vendor/venue support position is.
  ↳ Manual: [02.01 Ethernet PHY and MAC](manuals/02-networking/01-ethernet-phy-mac.md), [01.04 IO, Transceivers, and SerDes](manuals/01-fpga-design/04-io-transceivers-and-serdes.md) · Output: `docs/adr/00NN-line-rate-migration.md`

- [ ] **P12.8** `M` 🔒 — Establish the operational cadence and hold it: daily SOD/EOD
  and reconciliation, weekly latency-distribution review against the ledger, monthly
  risk-limit review with the sponsor, quarterly kill-switch and DR drills, and a
  standing process for reading Nasdaq technical notices and turning spec changes into
  tasks in this file.
  ↳ Manual: [06.02 Deployment and Colocation](manuals/06-operations/02-deployment-and-colocation.md), [07.04 Checklists](manuals/07-reference/04-checklists.md) · Output: `docs/operational-cadence.md`

- [ ] **P12.9** `M` — Plan hardware resilience: spare cards, a spare host, a documented
  cold-start time, and a decision on whether a warm standby is warranted. Test the
  spare by actually running on it.
  ↳ Manual: [06.02 Deployment and Colocation](manuals/06-operations/02-deployment-and-colocation.md) · Output: `docs/dr-plan.md`

- [ ] **P12.10** `S` — Correct the manuals. Everywhere production reality diverged from
  what `manuals/` claims — latency numbers, protocol behaviour, tool quirks — fix the
  manual and cite the measurement. The knowledge base is only worth what its accuracy
  is.
  ↳ Manual: [manuals/README.md](manuals/README.md) · Output: manual updates

---

# Critical path and dependencies

## The serial spine

These cannot be parallelized. Everything else exists to feed them.

```
P0 decisions
   └─> P1 golden model  ────────────────┐
                                        │  (the oracle — gates all correctness work)
                                        ▼
                          P3 feed handler ──> P4 order book ──> P5 strategy
                                                                   │
                                                                   ▼
                                                    P6 gateway + risk 🔒
                                                                   │
                                                                   ▼
                          P8 integration ──> P9 conformance ──> P10 deployment
                                                                   │
                                                                   ▼
                                                            P11 optimization ⏱
```

## The parallel lanes

```
        ┌──────────────────────────────────────────────────────────────────────┐
lane A  │ P0 ─> P1 golden model ─> (feeds P3, P4, P5, P6, P8 as the oracle)    │
        └──────────────────────────────────────────────────────────────────────┘
        ┌──────────────────────────────────────────────────────────────────────┐
lane B  │ P0 ─> P2 networking ─────────> (feeds P3; independent of P1)         │
        └──────────────────────────────────────────────────────────────────────┘
        ┌──────────────────────────────────────────────────────────────────────┐
lane C  │ P0 ─> P7 host + control plane ──────────────> (joins at P8)          │
        │      needs only P7.2 regmap agreed; otherwise fully independent      │
        └──────────────────────────────────────────────────────────────────────┘
        ┌──────────────────────────────────────────────────────────────────────┐
lane D  │ P0.10 ─> P9 compliance/conformance paperwork ─> (long lead time —    │
        │      start on day one, finishes at P10)                              │
        └──────────────────────────────────────────────────────────────────────┘
        ┌──────────────────────────────────────────────────────────────────────┐
lane E  │ P0.1 ─> P10.1–P10.3 colo, cross-connects, optics (procurement lead   │
        │      time; start early, idle until P8)                               │
        └──────────────────────────────────────────────────────────────────────┘
```

## Dependency table

| Phase | Hard prerequisites | Can start when | Runs in parallel with |
| --- | --- | --- | --- |
| **P0** | none | immediately | — |
| **P1** | P0.9 (number formats), P0.12 (strategy) | P0 decisions land | P2, P7, P9 paperwork, P10 procurement |
| **P2** | P0.1 (board), P0.6 (width/clock) | P0 decisions land | P1, P7 |
| **P3** | **P1.2 + P1.6 + P1.7** (oracle + trace + diff), P2.6 | golden decoder is trustworthy | P7 |
| **P4** | **P1.3** (golden book), P1.10 (corner corpus), P3 | golden book corroborated (P1.8) | P7 |
| **P5** | P0.12, P1.4, P4 | book is correct | P7 |
| **P6** | P1.5, P5, P2.11 | strategy fires correctly | P7 |
| **P7** | P7.2 regmap agreed | day one, in parallel with all RTL | P2–P6 entirely |
| **P8** | P3, P4, P5, P6, P7 | first full-datapath bitstream exists | P9 paperwork |
| **P9** | P6 (risk implemented), P7.9 (audit trail) | risk evidence exists; **paperwork starts at P0** | P8, P10 procurement |
| **P10** | P8, P9.7, P9.8, P10.1–P10.3 | conformance passed and colo live | — |
| **P11** | **P8.8 baseline exists** | there is a measured number to improve | P12 planning |
| **P12** | P10 graduated | canary graduated | P11 |

**The three things that most commonly become the real critical path**, in order:

1. **P1 (the golden model).** Everyone wants to skip it and write RTL. Skipping it
   means Phase 4 has no way to know it is wrong, and Phase 4 *will* be wrong.
2. **P9.7 / P9.8 (conformance and sponsor sign-off).** Scheduling-bound, not
   effort-bound. Starting these in Phase 9 rather than Phase 0 is how a finished
   system waits two months to trade.
3. **P6.14 / P4.11 (timing closure on the full datapath).** If it fails
   systemically — TNS in the hundreds of ns across hundreds of endpoints — the fix is
   architectural (P0.6 revisited), and it lands in the middle of the project.

---

# Risk register

| # | Risk | Impact | Likelihood | Mitigation |
| --- | --- | --- | --- | --- |
| R1 | **Timing closure fails systemically** on the full datapath, forcing a width/clock re-architecture mid-project | **High** — weeks to months of rework, and every downstream module's budget changes | Medium | Run full P&R from day one (P0.5) and track WNS as a CI metric; budget 12 cycles and design in 9 (P0.7); floorplan early (P0.8); make the width decision explicitly and early (P0.6). Escalation path is documented in [00.05 §4](manuals/00-foundations/05-timing-closure.md) Tier 5 — widen and slow down. |
| R2 | **ITCH spec misread** — message length table, field offsets, or replace semantics wrong | **High** — silent stream desynchronization that looks like a book bug and can persist into production | Medium-High | Independent second-person review of the length table (P3.1); bit-exact comparison against a separately-written golden decoder (P3.10); external corroboration of the golden model itself (P1.8); the venue spec always wins over the manual. |
| R3 | **Order book correctness bug** — the delete-the-best path, the RMW hazard, or a replace with lost priority | **Critical** — trading on a wrong book loses money confidently and continuously | Medium-High | Per-message exhaustive golden comparison over the full corpus (P4.9); a dedicated crafted corner-case corpus (P1.10); constrained-random flow nightly (P4.10); stale-book gating so a suspect book cannot trade (P3.6). |
| R4 | **Conformance / sponsor sign-off delays** | **High** — a finished, tested system sits idle | Medium | Start the paperwork at P0.10, not at Phase 9; book conformance slots before you are ready; keep the compliance-to-feature matrix (P9.6) current so review is a read, not an investigation. |
| R5 | **Position drift** — hardware position and reconciled position diverge | **Critical** — risk limits computed on a wrong position are not limits | Medium | Reconcile continuously against acks/fills and drop copy, not at end of day (P7.6); alarm immediately on any discrepancy; unique recoverable order tokens (P6.8); saturating counters that cannot wrap (P6.4). |
| R6 | **Runaway order incident** — the strategy fires unboundedly | **Critical** — potentially firm-ending; this is the failure mode that has actually destroyed firms | Low (by design) | Defence in depth: fabric rate throttle (P5.6), pre-trade risk with per-second and daily caps (P6.2), in-flight credit limit (P6.10), hardware kill switch with a bounded response (P6.6), hardware watchdog independent of the host daemon (P7.10), fail-closed on reset (P6.3), and a manned kill switch through the entire canary (P10.7). |
| R7 | **Vendor IP latency worse than specified** — MAC, PCIe shell, or GT wrapper costs more than the budget assumed | Medium-High — eats the budget before your own logic runs | Medium-High | Measure vendor IP in isolation on real hardware early (P2.2, P2.12); build the custom cut-through MAC far enough to compare; never enter a datasheet number into the budget as if it were measured. |
| R8 | **Golden model and RTL are both wrong in the same way** (shared misreading of the spec) | High — the comparison passes and the system is still wrong | Low-Medium | Corroborate the golden model against an independent external source (P1.8); have the spec read by a different person than the one who implemented it; conformance testing (P9.7) is a genuinely independent check. |
| R9 | **Feed gap recovery is wrong** — the book after resync doesn't match reality | High — a subtly wrong book that looks healthy | Medium | Verify the post-recovery book against the golden model (P7.8); fail-closed to stale (P3.6); require an explicit host clear before resuming trading. |
| R10 | **Strategy is not economically viable at achievable latency** | **High** — the whole project has no payoff | Medium | Build the economics model in Phase 0 (P0.13) and the latency-swept backtest in Phase 1 (P1.11); make the go/no-go decision before writing RTL, when it is still cheap. |
| R11 | **Key-person concentration** — one person understands the book or the risk block | Medium-High | High (default) | Enforce the module-header budget and the manual-link discipline; require a second reviewer on every 🔒 task; keep ADRs current; the manuals exist precisely to make the design legible to someone else. |
| R12 | **Silent counter overflow or unmonitored failure** | High — the worst failure mode in this domain per [CLAUDE.md §5](CLAUDE.md#5-hard-rules-on-the-fast-path) | Medium | Saturating counters everywhere; a test that proves every counter increments (P8.10); alerting on every counter that should stay zero (P7.11). |

---

# Definition of done, per artifact type

### RTL module

- [ ] Module header states purpose, **latency budget in ns and cycles**, **resource
      budget** (LUT/FF/BRAM/URAM/DSP), clock domain, and reset policy.
- [ ] Outputs registered, unless a comment justifies otherwise.
- [ ] No latches: every `case` has a `default`, every `if` has an `else`.
- [ ] No dynamic memory, no unbounded loops, no floating point.
- [ ] Any CDC uses a primitive from `rtl/common/cdc/` — never hand-rolled.
- [ ] Verilator `-Wall` clean, with any waiver justified inline.
- [ ] Has a testbench (mandatory on the fast path, no exceptions).
- [ ] Synthesizes **and** places-and-routes; post-route WNS/TNS/failing endpoints and
      utilization quoted verbatim from the report, not estimated.
- [ ] Actual latency in cycles matches the header budget, or the header is updated and
      the delta is explained in `docs/latency-ledger.md`.
- [ ] Every drop, error, and rejection is counted in a readable register.
- [ ] Links to the manual section that governs it.

### Testbench

- [ ] Runs in CI, non-interactively, with a deterministic exit code.
- [ ] Seeds are recorded and a failure is reproducible from the recorded seed.
- [ ] Asserts on cycle counts where latency matters, not just on values.
- [ ] Compares against the golden model where a golden model exists — never against a
      hand-written expected value that duplicates the DUT's logic.
- [ ] Runtime is bounded and stated; a nightly-only test is labelled as such.
- [ ] The failure message identifies the divergence, not just "assertion failed".
- [ ] Covers the negative cases: it must be possible to see the test fail by breaking
      the DUT deliberately (do this once, and record that you did).

### Host component

- [ ] Builds warning-clean with the pinned toolchain.
- [ ] Unit-tested, and integration-tested against either the market simulator or a
      register-map mock.
- [ ] Every register access uses the generated `regmap.hpp` — no magic addresses.
- [ ] Fails safe: on any error affecting trading, it disarms rather than continuing.
- [ ] All state-changing operations are logged to the audit trail with identity and
      timestamp.
- [ ] Never logs or persists credentials, session IDs, or production IPs.
- [ ] Has an entry in the ops runbook if a human ever has to interact with it.

### Manual document

- [ ] Opens with a "why this matters here" framing tied to this project.
- [ ] Numbers are labelled: measured (with N and method), simulated, or
      order-of-magnitude.
- [ ] `⚠️` on anything that silently produces a working-but-wrong design.
- [ ] Cross-links to the adjacent manuals and to the tasks it governs.
- [ ] Listed in [manuals/README.md](manuals/README.md).
- [ ] Corrected — not annotated — when production contradicts it.

### Bitstream release

- [ ] Built from a tagged commit with the pinned toolchain, inside the build container.
- [ ] Reproducible: a rebuild from the tag produces the same functional result, with
      the seed recorded.
- [ ] Post-route timing closes across a seed sweep, and the report is archived with the
      artifact.
- [ ] Full regression green: lint, unit, corpus, risk matrix, netlist risk-path check,
      latency gate.
- [ ] Build ID embedded and readable from a register (P10.5), matching a signed
      release manifest.
- [ ] Release notes state what changed, the measured latency delta, and the resource
      delta.
- [ ] Rollback target named and verified present.
- [ ] 🔒 Any change to risk limits, order sizing, or the kill switch is called out
      explicitly in the release notes and was reviewed separately from other changes.

---

# The first ten tasks

What to actually do first, in this order. Everything else waits.

1. **P0.1** — Pick the board and part. Nothing else can be sized until this is fixed.
2. **P0.2** — Pin the toolchain and build the container. Do it before the first line of
   code, not after the first irreproducible build.
3. **P0.3** — Scaffold the repo, including `rtl/common/cdc/` with the sanctioned
   synchronizers already in it, so nobody is ever tempted to hand-roll one.
4. **P0.5** — Get a trivial module through lint → sim → synth → **P&R** in CI, reporting
   WNS. A working P&R pipeline on day two is the cheapest insurance in the project.
5. **P0.12** — Write `docs/strategy-spec.md`. One page. Concrete enough that the trigger
   condition could be implemented from it. If this cannot be written, stop and fix that
   first — everything from Phase 4 onward is shaped by this answer.
6. **P0.13** — Build the economics model and answer "does this pay at 1 µs?" before
   committing to a sub-microsecond build.
7. **P0.10** — Open the market-access conversation with the broker-dealer/sponsor.
   Longest lead time in the project; starting it costs an email.
8. **P1.1** — Get the ITCH pcap corpus on disk, with a hashed manifest.
9. **P1.2** — Write the golden ITCH decoder. Every message type. This is the first real
   code in the project and it is software, deliberately.
10. **P1.3** — Write the golden order book, and start P1.8 (external corroboration) the
    moment it replays a day cleanly. Until this exists and is trusted, **no RTL for the
    feed handler or the book gets written.**

> The temptation in week one is to bring up a transceiver, because it feels like real
> FPGA work. Resist it for exactly as long as it takes to finish items 8–10. P2 can
> start in parallel the moment someone is free — but the golden model is the thing that
> makes every later phase verifiable, and it is the one piece of this project that no
> amount of later effort can retrofit.
