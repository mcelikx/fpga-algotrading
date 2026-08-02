# 07.01 — Glossary

> **Why this matters here:** this project sits on the seam between two fields that
> share almost no vocabulary and — worse — reuse the same words for different
> things. A "book" is a data structure to one half of the team and a market
> construct to the other; "latency" means microseconds to a trader and picoseconds
> to a timing engineer; "arbitration" is a bus concept and a feed concept. Every
> definition below is written **for someone who knows the other domain**.

Sections: [FPGA & digital design](#1-fpga--digital-design) ·
[Networking](#2-networking) ·
[Trading & market structure](#3-trading--market-structure) ·
[Nasdaq & US equities](#4-nasdaq--us-equities-specific) ·
[Regulatory](#5-regulatory)

---

## 1. FPGA & digital design

| Term | Expansion | Definition |
| --- | --- | --- |
| **ALM** | Adaptive Logic Module | Intel/Altera's basic logic unit, roughly analogous to half an AMD CLB. Contains LUTs, adders, and registers. See [00.02](../00-foundations/02-fpga-architecture.md). |
| **ASIC** | Application-Specific Integrated Circuit | A chip fabricated for one purpose. Faster and lower power than an FPGA but with a multi-million-dollar, multi-year tape-out; you cannot iterate on it. |
| **AXI-Stream** | Advanced eXtensible Interface, streaming profile | The standard point-to-point streaming interface in AMD designs: `tdata`, `tvalid`, `tready`, `tlast`, `tkeep`. The valid/ready handshake is the backpressure mechanism. |
| **Bitstream** | — | The binary configuration file loaded into an FPGA that defines every LUT truth table, every routing switch, and every block's settings. In this project it *is* the trading system; see [06.01](../06-operations/01-build-and-release.md). |
| **BRAM** | Block RAM | Dedicated on-die SRAM blocks (e.g. 18 Kb/36 Kb on AMD parts). True dual-port, ~1–2 cycle read latency. The workhorse for order-book storage. See [01.03](../01-fpga-design/03-memory-and-storage.md). |
| **Carry chain** | — | A dedicated fast path between adjacent logic cells for arithmetic carry propagation. Much faster than routing carries through general LUTs; why an adder is cheap and a comparator tree is not. |
| **CDC** | Clock Domain Crossing | Any signal passing between two clock domains. Requires a synchronizer or async FIFO; getting it wrong produces rare, non-reproducible corruption. See [00.04](../00-foundations/04-clocking-reset-and-cdc.md). |
| **Checkpoint / DCP** | Design CheckPoint | A Vivado snapshot of the design at a stage (post-synth, post-route) that can be reopened for analysis. Archive it per build — it is the only way to investigate a shipped bitstream later. |
| **CLB** | Configurable Logic Block | AMD's basic logic tile: a cluster of LUTs, flip-flops, carry logic, and muxes. |
| **cocotb** | coroutine cosimulation testbench | A Python framework for writing HDL testbenches. Lets you drive a simulator from Python, which makes pcap-driven market data testing practical. See [01.05](../01-fpga-design/05-verification-and-simulation.md). |
| **Combinational logic** | — | Logic whose output is a pure function of its current inputs, with no memory and no clock. It has propagation delay but no cycle cost. |
| **Congestion** | — | Too many nets needing to route through one region of the die. Causes long detours, bad timing, and long build times even when utilization looks low. |
| **Constraint** | — | A declaration to the tools about timing or placement (clock period, IO delay, false paths, floorplan). Written in **XDC** (AMD) or **SDC** (Intel). An unconstrained path is simply not checked. See [00.05](../00-foundations/05-timing-closure.md). |
| **Critical path** | — | The register-to-register path with the least timing slack. It sets your maximum clock frequency. |
| **DFX / partial reconfiguration** | Dynamic Function eXchange | Reprogramming a defined region of the fabric while the rest keeps running. Lets you swap a strategy without dropping exchange sessions — at the cost of a permanently fixed floorplan. |
| **Distributed RAM / LUTRAM** | — | Small memories built from LUTs rather than BRAM. Very low latency, expensive per bit; good for tiny tables and FIFOs. |
| **DSP slice** | Digital Signal Processing slice | A hardened multiply-accumulate block (e.g. DSP48E2 on UltraScale+). Use it for multiplies; a LUT-built multiplier is large and slow. |
| **Elaboration** | — | The step where parameterized HDL is expanded into a concrete hierarchy before synthesis. All sizes in this project are fixed at elaboration — no dynamic allocation exists in hardware. |
| **Fabric** | — | The programmable part of the FPGA (LUTs, FFs, routing), as opposed to hard IP blocks. "In fabric" means "implemented in programmable logic". |
| **Fanout** | — | The number of loads a signal drives. High fanout means the signal must physically reach many places, which costs routing delay — a leading cause of timing failure. |
| **FIFO** | First-In First-Out buffer | A queue in hardware. **Synchronous** (one clock) or **asynchronous** (two clocks, gray-coded pointers) — the latter is the sanctioned way to cross clock domains with a bus. |
| **Flip-flop / FF** | — | A one-bit storage element that samples its input on a clock edge. The unit of "state" in synchronous design. |
| **Floorplanning** | — | Constraining logic to physical regions of the die (see **pblock**). Standard practice for a trading fast path: keep it near the transceivers and inside one SLR. |
| **Fmax** | Maximum frequency | The highest clock frequency at which a design meets timing. Determined by the critical path. |
| **Gray code** | — | A binary encoding where consecutive values differ in exactly one bit. Used for FIFO pointers crossing clock domains so a mid-transition sample is always either the old or the new value, never garbage. |
| **Hard IP** | — | Fixed-function silicon on the die (PCIe controller, Ethernet MAC, memory controller, transceivers). Faster and smaller than a fabric implementation, but not modifiable. |
| **HDL** | Hardware Description Language | The language you describe hardware in. This project uses **SystemVerilog** (IEEE 1800-2017), synthesizable subset only. See [00.03](../00-foundations/03-hdl-and-rtl-coding.md). |
| **HLS** | High-Level Synthesis | Compiling C/C++ into RTL. Productive for datapath-heavy DSP work, generally a poor fit for latency-critical protocol parsing where you need cycle-level control. See [01.06](../01-fpga-design/06-hls-and-alternative-flows.md). |
| **Hold time** | — | The minimum time a flip-flop's input must remain stable *after* the clock edge. A hold violation means a path is too **fast**, and cannot be fixed by lowering the clock. |
| **ILA** | Integrated Logic Analyzer | An AMD debug core instantiated in the fabric that captures signals into BRAM and streams them to the host over JTAG. Invaluable, but it consumes resources and can perturb timing. |
| **II** | Initiation Interval | How often a pipelined block can accept a new input. II=1 means every cycle. Distinct from latency. |
| **Laguna register** | — | Dedicated flip-flops at the boundary between super logic regions on AMD SSI devices, used to pipeline SLR crossings. |
| **Latch (inferred)** | — | Unintended storage created when a combinational `always` block doesn't assign a signal on every path. **Always a bug in this project** — it creates untimeable, unreliable logic. |
| **LUT** | Look-Up Table | The basic combinational element: a small SRAM (6-input on UltraScale+) that implements any Boolean function of its inputs. Logic delay is ~0.1 ns; routing between LUTs usually costs more. |
| **Metastability** | — | The state a flip-flop enters when its input changes too close to the clock edge: the output is neither 0 nor 1 for an unbounded time. Mitigated, never eliminated, by synchronizer chains. |
| **MMCM / PLL** | Mixed-Mode Clock Manager / Phase-Locked Loop | Hard blocks that synthesize, divide, multiply, and phase-shift clocks. |
| **Netlist** | — | The gate/primitive-level representation of the design after synthesis: cells and the nets connecting them. |
| **Non-project mode** | — | Driving Vivado entirely from Tcl scripts with no `.xpr` project file. **Mandatory in this project** — a project file hides build state from code review. See [07.03](03-toolchain-reference.md). |
| **Pblock** | Placement block | A rectangular region constraint that forces specified cells to be placed inside it. The floorplanning primitive. |
| **Pipeline stage** | — | A register inserted into a combinational path, splitting it in two. Costs one clock cycle of latency, buys frequency. The central trade-off of the entire design. See [01.02](../01-fpga-design/02-pipelining-and-parallelism.md). |
| **Place and route (P&R)** | — | Assigning netlist cells to physical sites (place) and connecting them through the routing fabric (route). Heuristic and seed-dependent, which is why we sweep seeds. |
| **QoR** | Quality of Results | The umbrella term for timing, area, and power outcomes of an implementation run. |
| **Retiming** | — | The tool moving registers across combinational logic to balance path delays, without changing observable behaviour. Helpful, but it can change where your latency sits — verify cycle counts after enabling it. |
| **RTL** | Register Transfer Level | The abstraction at which you describe hardware: what registers hold and what combinational logic sits between them. |
| **Seed** | — | The random-number seed (or directive set) that drives placement/routing heuristics. Different seeds give different WNS from identical source; a design must close across a sweep, not on one lucky seed. |
| **SerDes / GT** | Serializer-Deserializer / Gigabit Transceiver | The hard block that converts parallel fabric data to a serial bit stream on the wire and back. A large, fixed part of your latency budget. See [01.04](../01-fpga-design/04-io-transceivers-and-serdes.md). |
| **Setup time** | — | The minimum time a flip-flop's input must be stable *before* the clock edge. Setup violations are fixed by pipelining or slowing the clock. |
| **Skid buffer** | — | A two-deep register stage that lets you register both `tvalid`/`tdata` and `tready` on a stream interface without losing throughput. The standard fix for a combinational `tready` path. |
| **Slack** | — | `required time − arrival time` on a timing path. Positive = the path meets timing. |
| **SLR** | Super Logic Region | One die in a multi-die (stacked silicon) FPGA. Crossing between SLRs costs significant delay and requires pipelining. Keep the fast path in one SLR. |
| **Speed grade** | — | A binned performance rating of a specific part (e.g. -1, -2, -3). A -3 is roughly 10–15 % faster than a -2 — often cheaper than weeks of timing work. |
| **STA** | Static Timing Analysis | Exhaustive mathematical checking of every timing path against the constraints, independent of stimulus. Unlike simulation, it cannot miss a case. |
| **SVA** | SystemVerilog Assertions | Declarative properties checked during simulation (and optionally formally). The right way to encode invariants like "the risk gate never emits an over-limit order". |
| **Synthesis** | — | Translating RTL into a netlist of FPGA primitives. Its timing estimates are optimistic by 20–40 % because it has no placement information. |
| **TNS** | Total Negative Slack | The sum of negative slack across all failing endpoints. Tells you whether you have one bad path or a systemic problem. |
| **Toggle coverage** | — | A verification metric: did each signal bit take both a 0→1 and 1→0 transition during the test? A cheap way to find untested logic. |
| **URAM** | UltraRAM | Large (288 Kb) hardened memory blocks on UltraScale+. Higher capacity than BRAM, more restrictive (single clock, no true dual-port), needs output pipelining. |
| **Utilization** | — | Percentage of each resource type consumed (LUT/FF/BRAM/URAM/DSP). Above ~70 % on any one type, routing gets hard and timing degrades. |
| **Valid/ready handshake** | — | The universal streaming contract: data transfers on any cycle where both `valid` and `ready` are high. Neither side may withdraw `valid` before a transfer completes. |
| **Verilator** | — | An open-source SystemVerilog compiler/simulator that converts RTL to C++. Very fast for cycle-accurate 2-state simulation and an excellent linter. Used here with cocotb. |
| **WNS** | Worst Negative Slack | The slack of the single worst timing path. The headline number of any implementation run; negative means the design does not close. |
| **XDC** | Xilinx Design Constraints | AMD's Tcl-based constraint format (Intel's equivalent is SDC). Lives in `constraints/`, checked in, and hashed into the build manifest. |

---

## 2. Networking

| Term | Expansion | Definition |
| --- | --- | --- |
| **64b/66b** | — | The line encoding used by 10G/25G Ethernet: 64 data bits become a 66-bit block with a 2-bit sync header. Adds ~3 % overhead and a fixed latency in the PCS. |
| **ARP** | Address Resolution Protocol | Maps an IP address to a MAC address. In a colo deployment with fixed peers, ARP entries are usually static — one less variable. |
| **Cross-connect** | — | A physical fibre or copper run between two cages in a data centre, ordered from the facility operator. How you reach the exchange handoff. See [06.02](../06-operations/02-deployment-and-colocation.md). |
| **CRC / FCS** | Cyclic Redundancy Check / Frame Check Sequence | The 32-bit error check at the end of every Ethernet frame. A non-zero CRC error counter means a physical layer problem — usually a dirty or failing optic. |
| **Cut-through** | — | Forwarding a frame as soon as the header is read, before the whole frame arrives. Dramatically lower latency than **store-and-forward**, at the cost of possibly forwarding a corrupt frame. |
| **DAC** | Direct Attach Copper | A short twinax cable with fixed transceivers on both ends. Cheapest and slightly faster per metre than fibre; limited to a few metres. |
| **FEC** | Forward Error Correction | Redundancy added at the physical layer to correct bit errors (Reed-Solomon at 25G+). Adds meaningful fixed latency; whether it is mandatory depends on the link type. |
| **Grandmaster** | — | The authoritative clock source in a PTP network, usually GNSS-disciplined. Its holdover quality determines what happens to your timestamps when GPS drops. |
| **IFG** | Inter-Frame Gap | The mandatory idle period between Ethernet frames (12 bytes at minimum). Counts toward the real time cost of a frame on the wire. |
| **IGMP** | Internet Group Management Protocol | How a host tells the network it wants to receive a multicast group. Your feed handler must join the right groups or it silently receives nothing. |
| **Jumbo frame** | — | An Ethernet frame larger than the standard 1500-byte MTU. Market data feeds generally do not use them; order entry does not need them. |
| **Kernel bypass** | — | Delivering packets to userspace without going through the OS network stack (DPDK, ef_vi, VMA, OpenOnload). Cuts software latency by an order of magnitude — and is still an order of magnitude slower than doing it in fabric. See [02.04](../02-networking/04-nics-kernel-bypass-and-switching.md). |
| **Layer-1 switch** | — | A device that replicates or patches signals at the physical layer with no packet processing. Latency of a few nanoseconds. Used for fan-out and taps in trading networks. |
| **MAC** | Media Access Control | The Ethernet layer that frames, checks CRC, and handles the interface to the PCS. A cut-through MAC is a major latency choice. See [02.01](../02-networking/01-ethernet-phy-mac.md). |
| **MoldUDP64** | — | Nasdaq's lightweight sequenced-datagram protocol that carries ITCH messages over UDP multicast: a session ID, a 64-bit sequence number, a message count, then the messages. Sequence numbers are what let you detect gaps. |
| **MTU** | Maximum Transmission Unit | Largest payload a link will carry in one frame (typically 1500 bytes). |
| **Multicast** | — | One-to-many delivery: the sender transmits once and the network replicates. All exchange market data feeds use it — which is why every recipient gets the data at essentially the same time and why sequence-gap handling is your problem, not TCP's. See [02.03](../02-networking/03-multicast-feeds-and-arbitration.md). |
| **Optic / SFP+ / QSFP** | Small Form-factor Pluggable | The pluggable transceiver module that converts electrical signals to light. SR = short reach/multimode, LR = long reach/single-mode. |
| **PCS** | Physical Coding Sublayer | The layer between the MAC and the physical medium: encoding (64b/66b), scrambling, block lock, and (optionally) FEC. A fixed, non-trivial contributor to latency. |
| **PHY** | Physical layer | Everything below the MAC: PCS + PMA + the medium interface. |
| **PMA** | Physical Medium Attachment | The analogue serializer/deserializer and clock recovery in the transceiver. |
| **Preamble / SFD** | Start of Frame Delimiter | The 7+1 bytes that precede every Ethernet frame, used for receiver synchronization. Part of the wire time you pay for. |
| **PTP** | Precision Time Protocol (IEEE 1588) | A protocol for distributing time over Ethernet to sub-microsecond (with hardware timestamping, sub-100 ns) accuracy. How your FPGA's timestamp counter learns absolute time. |
| **Serialization delay** | — | The time to clock a frame's bits onto the wire: 0.8 ns/byte at 10G. Pure physics; the only way to reduce it is a faster link. |
| **SoupBinTCP** | — | Nasdaq's simple session layer over TCP: login, sequenced data, heartbeats, logout, and replay from a sequence number. Carries OUCH. |
| **Store-and-forward** | — | Receiving an entire frame before forwarding it. Adds one full serialization delay per hop. Avoid in the fast path. |
| **TOE** | TCP Offload Engine | A TCP implementation in hardware. Needed for OUCH (which is TCP) but genuinely hard: retransmission, windowing, and state make it far more complex than UDP. See [02.02](../02-networking/02-ip-udp-tcp-in-hardware.md). |
| **UDP** | User Datagram Protocol | Connectionless, unacknowledged datagrams. Market data multicast rides on it, which is why gap detection and recovery are application-layer concerns. |
| **VLAN** | Virtual LAN | An 802.1Q tag adding 4 bytes to a frame and segmenting the network. Exchange handoffs may or may not be tagged — confirm, because a 4-byte offset error breaks every parser. |

---

## 3. Trading & market structure

| Term | Expansion | Definition |
| --- | --- | --- |
| **Adverse selection** | — | The cost of your resting order being filled precisely when the market is about to move against you. The core risk of passive market making; being slow to cancel makes it worse. |
| **Aggressive order** | — | An order that crosses the spread and takes liquidity immediately. Opposite of **passive**. |
| **Arbitrage** | — | Exploiting a price difference for the same or equivalent instrument across venues or products. Almost always a latency race. |
| **Ask / Offer** | — | The lowest price at which someone is willing to sell. |
| **Auction** | — | A discrete, non-continuous matching event where orders accumulate and cross at a single price (e.g. the open and close). Different rules and message types from continuous trading. |
| **Bid** | — | The highest price at which someone is willing to buy. |
| **Book / Limit order book** | — | The set of all resting limit orders for an instrument, organized by price level and, within a level, by arrival time. Reconstructing it in fabric is the core data-structure problem of this project. See [04.03](../04-system-architecture/03-order-book-in-hardware.md). |
| **Broken trade** | — | A trade cancelled after the fact by the exchange (e.g. clearly erroneous). Your position accounting must handle a fill being *removed*. |
| **Cancel-on-disconnect** | — | A venue feature that cancels your resting orders if your session drops. A safety net, **not** a design assumption — verify resting state explicitly on reconnect. |
| **Clearing** | — | Post-trade settlement of obligations, done by a clearing firm. Their record of your positions is an independent source of truth for reconciliation. |
| **Crossed market** | — | Bid > ask. Momentarily possible across venues; persistently crossed in *your* book means a decode or state bug. |
| **Dark pool** | — | A venue that does not display quotes pre-trade. Out of scope for this project's lit-market focus. |
| **Depth of book** | — | Visibility into resting orders beyond the best bid and offer. TotalView provides full depth; how many levels you keep in fabric is a resource decision. |
| **Drop copy** | — | A separate, read-only feed from the venue reporting your own executions. The independent view you reconcile against. |
| **Fill / Execution** | — | A trade against your order, in whole or in part. |
| **FIX** | Financial Information eXchange | A verbose, tag-value text protocol widely used for order entry. Far heavier to parse than binary protocols like OUCH — which is why we don't use it on the fast path. See [03.04](../03-algotrading/04-order-entry-protocols.md). |
| **Flatten** | — | To close all open positions, typically urgently. The standard response to losing confidence in your own state. |
| **FOK** | Fill Or Kill | Execute the entire order immediately or cancel it entirely. |
| **Hidden / non-displayed order** | — | A resting order not shown in the public book. It affects executions you observe but never appears as an add — your book model must tolerate trades at prices with no visible liquidity. |
| **Hit / Lift** | — | To "hit the bid" is to sell aggressively into the best bid; to "lift the offer" is to buy aggressively from the best ask. |
| **Iceberg / reserve order** | — | An order showing only part of its size, replenishing the displayed portion as it fills. |
| **Inside market** | — | The best bid and best ask. Synonym for **top of book**. |
| **IOC** | Immediate Or Cancel | Execute whatever is immediately available; cancel the rest. The default for a latency-taking strategy — it never leaves a resting order behind. |
| **Latency arbitrage** | — | Acting on information (a price change on one venue or product) before slower participants can update their quotes elsewhere. A pure speed strategy and the classic FPGA use case. |
| **Level 1 / 2 / 3 data** | — | L1 = top of book only; L2 = aggregated depth by price level; L3 = individual orders with IDs (what ITCH provides, and what lets you model queue position). |
| **Liquidity** | — | The ability to trade size without moving the price. "Taking liquidity" = executing against resting orders; "providing" = resting orders others execute against. |
| **Lit market** | — | A venue that publicly displays its order book. Nasdaq's continuous book is lit. |
| **Locked market** | — | Bid == ask. Legal in some contexts, prohibited in others; either way your book model must represent it without crashing. |
| **Maker / taker** | — | A fee model: the resting side (maker) is often rebated, the aggressing side (taker) pays. Fees can dominate the economics of a high-frequency strategy — model them. |
| **Market impact** | — | The adverse price movement your own trading causes. Grows with size. |
| **Market maker** | — | A participant quoting both sides continuously, earning the spread and rebates, and bearing inventory and adverse-selection risk. |
| **Market order** | — | An order to trade immediately at whatever price is available. ⚠️ Dangerous in an automated system without a price collar. |
| **Matching engine** | — | The exchange system that maintains the book and pairs orders according to its matching algorithm. See [03.02](../03-algotrading/02-order-types-and-matching-engines.md). |
| **Midpoint** | — | The average of the best bid and best ask. |
| **NBBO** | National Best Bid and Offer | The best bid and best offer across all US lit venues, computed and published by the SIPs. The reference against which trade-throughs and price improvement are judged. |
| **Notional** | — | Price × quantity: the cash value of an order or position. Risk limits are usually expressed in notional as well as shares. |
| **Odd lot / round lot / mixed lot** | — | Round lot = 100 shares in US equities (with exceptions); odd lot = fewer; mixed = both. Historically odd lots were not quoted in the NBBO — a real source of book-model subtlety. |
| **Order book imbalance** | — | The asymmetry between resting bid and ask quantity. A common, cheap-to-compute predictive signal — and cheap in fabric. |
| **Passive order** | — | An order that rests in the book adding liquidity rather than executing immediately. |
| **Pegged order** | — | An order whose price automatically tracks a reference (e.g. midpoint or NBBO). Handled by the venue, not by you. |
| **PnL** | Profit and Loss | Realized (from closed trades) and unrealized (mark-to-market on open positions). Computed on the host, never in fabric. |
| **Position** | — | Your net long or short quantity in an instrument. Must agree between fabric, host, and drop copy at all times — a mismatch is a Tier-1 alert. |
| **Post-only** | — | An order that must add liquidity; if it would execute immediately it is rejected or repriced. Used to guarantee maker fees. |
| **Price-time priority** | FIFO priority | The standard matching rule: better prices execute first; at the same price, earlier arrivals execute first. This is why **queue position** and therefore latency have direct economic value. |
| **Queue position** | — | Where your resting order sits within its price level. Early = more likely to be filled and less likely to be adversely selected. |
| **Quote** | — | A displayed bid and/or offer with size. |
| **Reject** | — | A venue or risk-gate refusal to accept an order, with a reason code. Every reason gets its own counter here — see [06.03](../06-operations/03-monitoring-and-telemetry.md). |
| **Self-match prevention** | SMP | Venue functionality that stops your own orders from trading against each other. Required by many venues and by good sense. |
| **Short sale** | — | Selling shares you do not own, having borrowed them (or arranged a **locate**). Subject to specific rules — see §5. |
| **Slippage** | — | The difference between the price you expected and the price you got. |
| **Spread** | Bid-ask spread | Ask minus bid. The market maker's gross revenue per round trip and the taker's immediate cost. |
| **Sweep** | — | An aggressive order that consumes multiple price levels at once. |
| **Tick / tick size** | — | A market data update (colloquially "a tick"), and separately the minimum price increment for an instrument. Both meanings appear in these manuals; context disambiguates. |
| **Tick-to-trade** | — | The elapsed time from a market data packet arriving on your wire to your order leaving on your wire. **The headline metric of this project.** Target: < 1 µs. |
| **TIF** | Time In Force | How long an order remains active: DAY, IOC, FOK, GTC, and venue-specific variants. |
| **Top of book** | TOB | The best bid and best ask with their sizes. The state most strategies actually trigger on, and the state worth maintaining incrementally in fabric. |
| **Trade-through** | — | Executing at a price worse than the NBBO on another venue. Restricted under Reg NMS — see §5. |
| **VWAP / TWAP** | Volume/Time Weighted Average Price | Execution benchmarks and the algorithms that target them. Schedule-driven, not latency-driven — the opposite end of the spectrum from this project. |
| **Wire-to-wire** | — | Latency measured at the physical interface on both ends, including MAC/PHY. The only honest way to quote tick-to-trade; "core-to-core" numbers hide the expensive parts. |

---

## 4. Nasdaq & US-equities specific

> **Verify:** every entry in this section describes a **venue-defined** artefact.
> Confirm each against the current **Nasdaq TotalView-ITCH 5.0**, **OUCH 5.0**,
> **SoupBinTCP**, **MoldUDP64**, and Nasdaq rule/market-operations documentation.
> Message names, codes, and behaviours change with spec revisions.

| Term | Expansion | Definition |
| --- | --- | --- |
| **Add Order message** | — | The ITCH message announcing a new displayed order joining the book, with a unique order reference number, side, shares, stock, and price. There is also a variant carrying the attribution (MPID). |
| **Broken Trade message** | — | ITCH notification that a previously reported execution has been cancelled. Your position and PnL must be able to unwind a fill. |
| **Carteret** | — | The New Jersey location long associated with Nasdaq's US matching engine and colocation facility. Physical distance to this building is the reason colocation exists. |
| **Closing Cross** | — | Nasdaq's end-of-day auction that determines the official closing price. Preceded by imbalance dissemination (NOII). A very high-message-rate event and a required corpus entry. |
| **Cross Trade message** | — | ITCH message reporting a trade resulting from an auction/cross rather than continuous trading. |
| **CTA / CQS** | Consolidated Tape Association / Consolidated Quotation System | The SIP plans covering NYSE/NYSE-American-listed securities (Tapes A and B). |
| **Delete Order message** | — | ITCH message removing an order entirely from the book by order reference number. |
| **Executed Order message** | — | ITCH message reporting that part or all of a resting order executed. A variant carries an explicit price for executions at a price other than the display price. |
| **GLIMPSE** | — | Nasdaq's snapshot service: a point-in-time image of the book so a late joiner can start from a known state rather than replaying the whole day. |
| **IPO Quoting Period** | — | The pre-launch quoting phase for a new listing, signalled by dedicated ITCH messages. A distinct state your book model must handle. |
| **ITCH** | — | Nasdaq's binary, fixed-field market data protocol. Fixed field offsets make it fast to parse in hardware — no tag-value scanning. See [03.03](../03-algotrading/03-market-data-protocols.md). |
| **LULD** | Limit Up-Limit Down | The NMS plan that constrains trading to a price band around a reference price, with pauses when the band is touched. Bands are disseminated and must be respected by your price collar. |
| **MoldUDP64** | — | See §2. The transport carrying ITCH. |
| **MPID** | Market Participant Identifier | The four-character code identifying a market participant. Yours identifies your orders on attributed messages. |
| **MWCB** | Market-Wide Circuit Breaker | Market-wide trading halts triggered by large index declines. ITCH carries a message for the level breached. Your system must stop cleanly, not thrash. |
| **Nasdaq BX / PSX** | — | Nasdaq's additional US equity exchanges, with different fee models and matching characteristics. Separate feeds and separate ports. |
| **NOII** | Net Order Imbalance Indicator | The imbalance information disseminated before the opening and closing crosses: paired shares, imbalance side and size, and indicative prices. |
| **Opening Cross** | — | Nasdaq's 09:30 ET auction establishing the official opening price. The highest-message-rate window of most trading days. |
| **OUCH** | — | Nasdaq's binary, low-latency order-entry protocol. Compact fixed-field messages over SoupBinTCP: enter, replace, cancel; accepted, executed, canceled, rejected. Chosen here precisely because it is trivially encodable in fabric. |
| **RASH** | — | An alternative Nasdaq order-entry protocol with richer routing/strategy features than OUCH. Not used on this project's fast path. |
| **Reg SHO short sale price test** | — | A restriction that activates for a security after a large intraday decline, limiting short sales to above the national best bid. Signalled in ITCH; must be enforced in your order logic. |
| **Retail Price Improvement (RPI)** | — | A program providing hidden price improvement to retail orders, with its own ITCH indicator messages. |
| **Replace Order message** | — | ITCH message replacing a resting order with a new order reference number — ⚠️ the old reference is retired; treating it as still live corrupts the book. |
| **SIP** | Securities Information Processor | The consolidated feeds that publish the NBBO and last-sale data across all venues. Slower than direct feeds — which is the entire economic basis of direct-feed trading. |
| **SoupBinTCP** | — | See §2. The session layer under OUCH. |
| **Stock Directory message** | — | ITCH message describing a security: symbol, market category, financial status, round lot size, whether it is an ETP, and more. Sent at start of day and when a symbol is added. This is where your symbol table comes from. |
| **Stock Trading Action message** | — | ITCH message signalling a halt, pause, quotation-only period, or resumption for a symbol, with a reason code. Must gate your strategy. |
| **System Event message** | — | ITCH message marking session milestones: start of messages, start/end of system hours, end of messages. Your day boundary. |
| **TotalView** | — | Nasdaq's full-depth data product; TotalView-ITCH is the direct binary feed delivering every displayed order and execution. |
| **TRF** | Trade Reporting Facility | Where off-exchange (OTC) trades are reported. Relevant to consolidated volume, not to the fast path. |
| **UTP Plan** | Unlisted Trading Privileges Plan | The SIP plan covering Nasdaq-listed securities (Tape C). |

---

## 5. Regulatory

> **Verify:** this section is a **navigation aid, not legal advice**. Every rule
> below must be confirmed with your compliance function against the current text
> from the SEC, FINRA, or the relevant SRO. Applicability depends on your
> registration status (broker-dealer, sponsored access customer, proprietary firm)
> and can change.

| Term | Expansion | Definition |
| --- | --- | --- |
| **Best execution** | — | The obligation (FINRA Rule 5310) to seek the most favourable terms reasonably available for customer orders. Primarily a concern when handling customer flow rather than proprietary trading. |
| **CAT** | Consolidated Audit Trail | The SEC-mandated (Rule 613) system requiring reporting of order and trade events across US equities and options, with synchronized timestamps. Drives both your clock-sync requirements and your audit logging. |
| **Clock synchronization requirement** | — | The obligation to synchronize business clocks used for reportable events to a reference (NIST) within a defined tolerance — see **FINRA Rule 4590** and the CAT NMS Plan. The exact tolerance must be confirmed; it has been tightened for automated systems. |
| **FINRA** | Financial Industry Regulatory Authority | The US self-regulatory organization for broker-dealers. Source of many operational rules that bind an automated trading firm. |
| **FINRA Rule 3110** | Supervision | Requires supervisory systems and written procedures — including, in practice, supervision of algorithmic trading systems and their changes. |
| **FINRA Rule 4370** | Business Continuity Plans | Requires a written BCP addressing, among other things, how you continue or wind down operations during a disruption. Your DR plan sits under this. |
| **Layering / spoofing** | — | Entering orders without intent to execute in order to create a misleading impression of supply or demand. **Prohibited.** An automated strategy must be designed and reviewed so it cannot produce this pattern accidentally. |
| **Market Access Rule** | SEC Rule 15c3-5 | Requires broker-dealers with market access to maintain risk management controls — including pre-trade limits on order size, price, and aggregate exposure — that are **under their direct and exclusive control**. This rule is the regulatory reason our risk gate is in hardware and non-bypassable. |
| **MiFID II / RTS 6 / RTS 25** | Markets in Financial Instruments Directive II | The EU framework. RTS 6 covers algorithmic trading organizational requirements (testing, kill functionality); RTS 25 covers clock synchronization at microsecond tolerances. **Not applicable to US-only trading**, but a useful benchmark for what "good" looks like. |
| **NMS** | National Market System | The regulatory framework linking US equity venues, established by Regulation NMS. |
| **Reg NMS Rule 610** | Access Rule | Governs fair and non-discriminatory access to quotations and caps access fees. |
| **Reg NMS Rule 611** | Order Protection Rule | Prohibits executing trades at prices inferior to protected quotations displayed on other venues (trade-throughs), subject to exceptions. |
| **Reg NMS Rule 612** | Sub-Penny Rule | Restricts quoting in increments finer than a penny for most securities above $1.00. Constrains your price representation and tick logic. |
| **Reg SCI** | Regulation Systems Compliance and Integrity | Imposes systems capacity, integrity, testing and business-continuity obligations on "SCI entities" — exchanges, certain ATSs, clearing agencies. A proprietary trading firm is generally not an SCI entity, but its standards are a good template. |
| **Reg SHO** | Regulation SHO | Governs short selling: locate requirements, close-out obligations, and (Rule 201) the short sale price test that activates after a 10 % intraday decline. |
| **SEC** | Securities and Exchange Commission | The US federal securities regulator. |
| **SEC Rule 17a-4** | — | Books-and-records retention requirements for broker-dealers, including formats and retention periods. Your audit log retention policy derives from it. |
| **Sponsored access** | — | Trading using a broker-dealer's market participant identifier. ⚠️ "Naked" or unfiltered sponsored access — where orders reach the venue without the broker-dealer's own pre-trade controls — is prohibited under Rule 15c3-5. |
| **SRO** | Self-Regulatory Organization | Exchanges and FINRA, which write and enforce their own rules under SEC oversight. |
| **Kill switch (regulatory sense)** | — | A mandated or expected capability to immediately halt order flow, both at the firm and at the venue. Ours is hardware-enforced and bounded in cycles — see [04.05](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md). |

---

## Further reading

- [02-latency-reference-numbers.md](02-latency-reference-numbers.md) — the numbers behind the terms
- [03-toolchain-reference.md](03-toolchain-reference.md) — the commands that produce the FPGA artefacts named above
- [04-checklists.md](04-checklists.md) — the operational procedures these terms appear in
- [../00-foundations/01-digital-logic-and-timing.md](../00-foundations/01-digital-logic-and-timing.md) — the physics under §1
- [../03-algotrading/01-market-microstructure.md](../03-algotrading/01-market-microstructure.md) — §3 in depth
- [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md) — §5 in depth
