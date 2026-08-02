# Manuals — FPGA Algorithmic Trading System

A layered knowledge base. Each tier assumes the tier above it. Read top-down the
first time; after that, jump straight to what you need.

```
00 Foundations          what an FPGA is and how time works inside it
01 FPGA Design          how to build correct, fast hardware
02 Networking           how packets get in and out
03 Algotrading          what the market is and what we are trying to do
04 System Architecture  how 00-03 combine into a trading system
05 Optimization         how to make it faster, with evidence
06 Operations           how to build, ship, and run it safely
07 Reference            lookup tables, glossary, checklists
08 Nasdaq               the venue we actually trade — rules, protocols, limits
```

**Tiers 03 and 08 are a pair.** Tier 03 teaches the venue-neutral concepts
(what a limit order book *is*, how matching works, what a market data protocol
looks like). Tier 08 is the Nasdaq-specific working reference (the actual ITCH
message codes, the actual order types, the actual regulatory limits). Read 03 to
understand, read 08 to implement.

The executable plan derived from these manuals is [../TASKS.md](../TASKS.md).

---

## 00 — Foundations

The physics and vocabulary. Nothing here is trading-specific.

| # | Document | Covers |
| --- | --- | --- |
| 01 | [Digital Logic and Timing](00-foundations/01-digital-logic-and-timing.md) | Combinational vs. sequential logic, setup/hold, propagation delay, the fundamental timing equation |
| 02 | [FPGA Architecture](00-foundations/02-fpga-architecture.md) | LUTs, flip-flops, CLBs/ALMs, BRAM/URAM, DSP slices, routing fabric, clock trees, SLRs, hard IP |
| 03 | [HDL and RTL Coding](00-foundations/03-hdl-and-rtl-coding.md) | SystemVerilog synthesizable subset, coding style that maps to hardware, common inference traps |
| 04 | [Clocking, Reset, and CDC](00-foundations/04-clocking-reset-and-cdc.md) | Clock domains, PLL/MMCM, reset strategy, metastability, synchronizers, async FIFOs |
| 05 | [Timing Closure](00-foundations/05-timing-closure.md) | STA, setup/hold slack, WNS/TNS, critical paths, constraints, what actually fixes timing |

## 01 — FPGA Design

How to turn intent into hardware that closes timing.

| # | Document | Covers |
| --- | --- | --- |
| 01 | [RTL Design Patterns](01-fpga-design/01-rtl-design-patterns.md) | FSMs, valid/ready handshakes, skid buffers, credit flow control, arbiters, CAMs |
| 02 | [Pipelining and Parallelism](01-fpga-design/02-pipelining-and-parallelism.md) | Latency vs. throughput, II, retiming, unrolling, wide datapaths, speculation |
| 03 | [Memory and Storage](01-fpga-design/03-memory-and-storage.md) | Distributed RAM, BRAM, URAM, HBM/DDR, FIFOs, hash tables, banking |
| 04 | [IO, Transceivers, and SerDes](01-fpga-design/04-io-transceivers-and-serdes.md) | GT transceivers, 64b/66b, PCS/PMA, PCIe, latency of the IO stack |
| 05 | [Verification and Simulation](01-fpga-design/05-verification-and-simulation.md) | cocotb, Verilator, pcap replay, assertions, coverage, regression discipline |
| 06 | [HLS and Alternative Flows](01-fpga-design/06-hls-and-alternative-flows.md) | Vitis HLS, Chisel/SpinalHDL, when they help and when they cost you |

## 02 — Networking

The wire, and everything between it and your logic.

| # | Document | Covers |
| --- | --- | --- |
| 01 | [Ethernet PHY and MAC](02-networking/01-ethernet-phy-mac.md) | 10/25/100G, PCS/PMA, MAC latency, cut-through vs. store-and-forward, FEC |
| 02 | [IP, UDP, TCP in Hardware](02-networking/02-ip-udp-tcp-in-hardware.md) | Header parsing, checksums, why TCP is hard in fabric, TOE design |
| 03 | [Multicast Feeds and Arbitration](02-networking/03-multicast-feeds-and-arbitration.md) | A/B feed arbitration, sequence gap detection, recovery, line handling |
| 04 | [NICs, Kernel Bypass, and Switching](02-networking/04-nics-kernel-bypass-and-switching.md) | Where FPGA sits vs. Solarflare/Exablaze, switch latency, layer-1 devices |

## 03 — Algotrading

The domain. What the market is, and what we are trying to extract from it.

| # | Document | Covers |
| --- | --- | --- |
| 01 | [Market Microstructure](03-algotrading/01-market-microstructure.md) | Limit order books, price-time priority, spread, depth, queue position, adverse selection |
| 02 | [Order Types and Matching Engines](03-algotrading/02-order-types-and-matching-engines.md) | Limit/market/IOC/FOK/post-only, matching algorithms, auctions, self-match prevention |
| 03 | [Market Data Protocols](03-algotrading/03-market-data-protocols.md) | ITCH, MDP 3.0/SBE, FIX/FAST, PITCH, incremental vs. snapshot, decode cost |
| 04 | [Order Entry Protocols](03-algotrading/04-order-entry-protocols.md) | OUCH, iLink 3, FIX, session layer, sequencing, ack handling, cancel-on-disconnect |
| 05 | [Strategy Taxonomy](03-algotrading/05-strategy-taxonomy.md) | Market making, arbitrage, latency arb, liquidity taking — and which suit hardware |
| 06 | [Risk and Compliance](03-algotrading/06-risk-and-compliance.md) | Pre-trade risk, Reg SCI/MiFID II/RTS 6, kill switches, audit trails, market access rule |

## 04 — System Architecture

Where the previous four tiers meet.

| # | Document | Covers |
| --- | --- | --- |
| 01 | [Tick-to-Trade Pipeline](04-system-architecture/01-tick-to-trade-pipeline.md) | The end-to-end block diagram and its per-stage latency budget |
| 02 | [Feed Handler Design](04-system-architecture/02-feed-handler-design.md) | Line-rate parsing, message framing, symbol filtering, decode pipelines |
| 03 | [Order Book in Hardware](04-system-architecture/03-order-book-in-hardware.md) | Book data structures in fabric, price-level arrays, top-of-book fast path |
| 04 | [Strategy Engine on FPGA](04-system-architecture/04-strategy-engine-on-fpga.md) | Trigger logic, parameter tables, state machines, reconfigurability without rebuild |
| 05 | [Order Gateway and Pre-Trade Risk](04-system-architecture/05-order-gateway-and-pre-trade-risk.md) | Order encode, risk gate, session management, the kill switch |
| 06 | [CPU/FPGA Partitioning](04-system-architecture/06-cpu-fpga-partitioning.md) | What belongs where, PCIe/DMA design, control plane, hybrid strategies |

## 05 — Optimization

The core of the next phase of this project.

| # | Document | Covers |
| --- | --- | --- |
| 01 | [Latency Budgeting](05-optimization/01-latency-budgeting.md) | How to build and defend a nanosecond budget, stage by stage |
| 02 | [Fmax and Timing Optimization](05-optimization/02-fmax-and-timing-optimization.md) | Reading timing reports, breaking critical paths, floorplanning, tool strategies |
| 03 | [Resource and Power Optimization](05-optimization/03-resource-power-optimization.md) | LUT/FF/BRAM/DSP reduction, congestion, SLR crossing, power and thermals |
| 04 | [Measurement and Profiling](05-optimization/04-measurement-and-profiling.md) | Hardware timestamping, loopback tests, ILA, distribution statistics, methodology |
| 05 | [Optimization Playbook](05-optimization/05-optimization-playbook.md) | Ordered, cheapest-first list of techniques with expected gains |

## 06 — Operations

| # | Document | Covers |
| --- | --- | --- |
| 01 | [Build and Release](06-operations/01-build-and-release.md) | Reproducible builds, seeds, bitstream versioning, CI for hardware |
| 02 | [Deployment and Colocation](06-operations/02-deployment-and-colocation.md) | Colo, cross-connects, cabling, clock sync/PTP, conformance testing |
| 03 | [Monitoring and Telemetry](06-operations/03-monitoring-and-telemetry.md) | Counters, health registers, latency histograms in fabric, alerting |
| 04 | [Testing Strategy](06-operations/04-testing-strategy.md) | Unit → integration → replay → soak → conformance → production canary |

## 07 — Reference

| # | Document | Covers |
| --- | --- | --- |
| 01 | [Glossary](07-reference/01-glossary.md) | FPGA and trading terminology, side by side |
| 02 | [Latency Reference Numbers](07-reference/02-latency-reference-numbers.md) | Order-of-magnitude numbers every design decision should be checked against |
| 03 | [Toolchain Reference](07-reference/03-toolchain-reference.md) | Vivado/Quartus/Verilator/cocotb commands and report locations |
| 04 | [Checklists](07-reference/04-checklists.md) | Module review, timing closure, pre-deployment, incident response |

## 08 — Nasdaq

The venue-specific working reference. Where a general manual and this tier
disagree, **this tier wins** — and where this tier and the current Nasdaq
specification disagree, **the specification wins** and this tier gets corrected.

| # | Document | Covers |
| --- | --- | --- |
| 01 | [Market Structure](08-nasdaq/01-market-structure.md) | The US equity landscape, Nasdaq/BX/PSX, tapes, SIP vs. direct feeds, participants |
| 02 | [Sessions, Auctions, and Halts](08-nasdaq/02-sessions-auctions-and-halts.md) | The trading day, opening/closing/halt crosses, LULD, MWCB, SSR |
| 03 | [Order Types and Routing](08-nasdaq/03-order-types-and-routing.md) | The full order type catalogue, price sliding, post-only, SMP, routing strategies |
| 04 | [TotalView-ITCH 5.0](08-nasdaq/04-totalview-itch-5.0.md) | The decoder reference — MoldUDP64, every message type, book reconstruction |
| 05 | [OUCH 5.0 Order Entry](08-nasdaq/05-ouch-5.0-order-entry.md) | The encoder reference — SoupBinTCP, message catalogue, order tokens, templates |
| 06 | [Reg NMS and Compliance](08-nasdaq/06-regnms-and-compliance.md) | Rules 610/611/612, NBBO, ISO, 15c3-5, Reg SHO, CAT, manipulation risk |
| 07 | [Fees, Rebates, and Economics](08-nasdaq/07-fees-rebates-and-economics.md) | Maker-taker, inverted venues, the full cost stack, P&L decomposition |
| 08 | [Connectivity and Colocation](08-nasdaq/08-connectivity-and-colocation.md) | Carteret, cross-connects, ports, MPIDs, onboarding, conformance |
| 09 | [Risk Controls and Limits](08-nasdaq/09-risk-controls-and-limits.md) | The implementable pre-trade risk specification and the kill switch |

---

## Conventions used in these manuals

- **Latency** is always in nanoseconds unless stated. Cycle counts are given
  alongside, with the assumed clock.
- `⚠️` marks something that will silently produce a working-but-wrong design.
- **Numbers are order-of-magnitude** unless a source is cited. Measure your own
  hardware before trusting any figure here.
- Code is SystemVerilog unless labelled otherwise.
