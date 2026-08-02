# 07.02 — Latency Reference Numbers

> **Why this matters here:** every design decision in this project is a bet about
> nanoseconds, and intuition about nanoseconds is reliably wrong. This file is the
> sanity check: before you spend three weeks pipelining a block, look up what that
> block can possibly cost relative to the SerDes, the fibre, and the switch you are
> already paying for. It is also the file most likely to go stale, so **every number
> is labelled with its confidence class and where to confirm it.**

---

## 0. How to read this file

| Class | Meaning | What you owe it |
| --- | --- | --- |
| **[EXACT]** | Arithmetic from a definition. 10 Gb/s means 0.8 ns/byte, by construction. | Nothing. It cannot be stale. |
| **[SPEC]** | Published in a standard, a vendor datasheet, or an IP product guide. | Cite the exact document and version before you use it in a budget. |
| **[OOM]** | Order of magnitude, drawn from common industry experience. **May be wrong by 2–3× for your hardware.** | **Measure your own.** Never put an [OOM] number in a customer-facing or sign-off document. |

> ⚠️ **The single most common misuse of a table like this is quoting an [OOM] number
> as if it were measured.** `CLAUDE.md` §4 is explicit: say "simulated", say
> "measured, N=…", or say "reference estimate". These are not interchangeable, and
> conflating them is how a latency budget silently becomes fiction.

**The one rule:** the only latency numbers that count for this project are
post-route-simulated (cycle-exact) or hardware-measured wire-to-wire, with the
distribution reported. Everything below is for *choosing what to build*.

---

## 1. FPGA primitive delays (UltraScale+ class)

| Element | Typical delay | Class | Notes |
| --- | --- | --- | --- |
| LUT6 (logic only) | ~0.03–0.10 ns | [OOM] | Almost never the problem |
| FF clock-to-Q (T_cq) | ~0.10–0.20 ns | [OOM] | |
| FF setup (T_setup) | ~0.05–0.10 ns | [OOM] | |
| FF hold (T_hold) | ~0.00–0.10 ns | [OOM] | Tools fix intra-domain hold automatically |
| Short routing hop (adjacent CLB) | ~0.05–0.15 ns | [OOM] | |
| Medium routing hop (across a clock region) | ~0.5–1.5 ns | [OOM] | **This is what actually kills timing** |
| Long routing hop (across the die) | 2–5 ns+ | [OOM] | Never allow on a critical path |
| Carry chain, per bit | ~0.01–0.05 ns | [OOM] | Why a 64-bit adder is cheap and a 64-way comparator tree is not |
| BRAM read, no output register | 1 cycle | [EXACT] | Cycles are exact; whether it closes timing is not |
| BRAM read, with output register | 2 cycles | [EXACT] | Required above ~350 MHz |
| URAM read | 1 cycle base, +1–2 recommended pipeline | [SPEC] | URAM needs pipelining far more than BRAM |
| DSP48E2 multiply, fully pipelined | 3–4 cycles | [SPEC] | Fewer stages = lower Fmax |
| Distributed RAM (LUTRAM) read | combinational or 1 cycle | [SPEC] | Lowest-latency memory available |
| SLR crossing | +1–2 pipeline stages, ~1–2 ns of extra path delay | [OOM] | Use Laguna registers; budget it explicitly |
| Global clock buffer insertion delay | ~1–2 ns (largely cancelled by STA) | [OOM] | Matters for IO timing, not reg-to-reg |

> **Verify:** all of the above are device-, speed-grade-, and
> temperature-dependent. Authoritative values come from the **device data sheet**
> (AC/switching characteristics) for your exact part and speed grade, and from
> `report_timing -path_type full_clock_expanded` on your own design. For SLR and
> Laguna behaviour see AMD **UG949** (UltraFast Design Methodology) and **UG906**
> (Design Analysis and Closure Techniques).

**The takeaway that matters:** on modern FPGAs **routing dominates logic**. A path
report showing 75 % route / 25 % logic is normal, and it means the fix is
placement, fanout, or floorplanning — not fewer LUT levels.

---

## 2. Clock periods and cycle counts

| Frequency | Period | Class | Where it comes from |
| --- | --- | --- | --- |
| 100 MHz | 10.000 ns | [EXACT] | Convenient control-plane clock |
| 156.25 MHz | 6.400 ns | [EXACT] | **This project's core clock.** 10 Gb/s ÷ 64 bits |
| 161.1328125 MHz | 6.206 ns | [EXACT] | 10.3125 Gb/s (line rate) ÷ 64 |
| 195.3125 MHz | 5.120 ns | [EXACT] | 25 Gb/s ÷ 128 |
| 200 MHz | 5.000 ns | [EXACT] | |
| 250 MHz | 4.000 ns | [EXACT] | |
| 300 MHz | 3.333 ns | [EXACT] | |
| 322.265625 MHz | 3.103 ns | [EXACT] | 10.3125 Gb/s ÷ 32 |
| 390.625 MHz | 2.560 ns | [EXACT] | 25 Gb/s ÷ 64 |
| 400 MHz | 2.500 ns | [EXACT] | |
| 500 MHz | 2.000 ns | [EXACT] | Beyond practical Fmax for wide trading logic |

**Derive, don't copy:** `f_clk = line_rate_bits_per_sec ÷ datapath_width_bits`.
Whether you use the data rate (10 Gb/s) or the line rate (10.3125 Gb/s) depends on
where in the stack you are. Get this wrong and your FIFOs underrun or overflow
under sustained load — and only under sustained load.

### Cycles → nanoseconds at 156.25 MHz (project default)

| Cycles | ns | | Cycles | ns |
| --- | --- | --- | --- | --- |
| 1 | 6.4 | | 20 | 128.0 |
| 2 | 12.8 | | 25 | 160.0 |
| 3 | 19.2 | | 30 | 192.0 |
| 4 | 25.6 | | 40 | 256.0 |
| 5 | 32.0 | | 50 | 320.0 |
| 8 | 51.2 | | 75 | 480.0 |
| 10 | 64.0 | | 100 | 640.0 |
| 15 | 96.0 | | 156 | 998.4 |

[EXACT]. **156 cycles is your entire 1 µs budget** — including SerDes in and out.
Roughly 60–80 of those cycles are consumed by the Ethernet stack before your logic
sees a byte and after it emits one. Plan for **~50–80 cycles of your own logic**.

---

## 3. Serialization delay

Time to clock bytes onto (or off) the wire. Pure arithmetic — nothing can reduce it
except a faster link.

| Link rate | ns per byte | ns per bit | Class |
| --- | --- | --- | --- |
| 1 GbE | 8.00 | 1.000 | [EXACT] |
| 10 GbE | 0.80 | 0.100 | [EXACT] |
| 25 GbE | 0.32 | 0.040 | [EXACT] |
| 40 GbE | 0.20 | 0.025 | [EXACT] |
| 100 GbE | 0.08 | 0.010 | [EXACT] |

### Bytes → nanoseconds at 10 GbE

| Frame content | Bytes | ns @10G | ns @25G | Class |
| --- | --- | --- | --- | --- |
| Preamble + SFD | 8 | 6.4 | 2.6 | [EXACT] |
| Inter-frame gap (minimum) | 12 | 9.6 | 3.8 | [EXACT] |
| Minimum Ethernet frame | 64 | 51.2 | 20.5 | [EXACT] |
| Minimum frame + preamble + IFG (wire slot) | 84 | 67.2 | 26.9 | [EXACT] |
| Typical single-message ITCH packet (see below) | ~104 | 83.2 | 33.3 | [EXACT] given size |
| 128 | 128 | 102.4 | 41.0 | [EXACT] |
| 256 | 256 | 204.8 | 81.9 | [EXACT] |
| 512 | 512 | 409.6 | 163.8 | [EXACT] |
| 1024 | 1024 | 819.2 | 327.7 | [EXACT] |
| 1500 (standard MTU payload) | 1500 | 1200.0 | 480.0 | [EXACT] |
| 1518 (max standard frame) | 1518 | 1214.4 | 485.8 | [EXACT] |
| 9000 (jumbo) | 9000 | 7200.0 | 2880.0 | [EXACT] |

### Worked example: one ITCH Add Order on the wire

| Layer | Bytes |
| --- | --- |
| Ethernet header | 14 |
| IPv4 header (no options) | 20 |
| UDP header | 8 |
| MoldUDP64 header (session + sequence + message count) | 20 |
| Message length prefix | 2 |
| ITCH Add Order (no MPID attribution) | 36 |
| Ethernet FCS | 4 |
| **Total frame** | **104** |
| + preamble/SFD + IFG | 124 |
| **Wire time @10G** | **99.2 ns** |

> **Verify:** ITCH message lengths (Add Order 36 B, Add Order with MPID 40 B, Order
> Executed 31 B, Order Cancel 23 B, Order Delete 19 B, Trade 44 B) and the
> MoldUDP64 header layout must be confirmed against the **Nasdaq TotalView-ITCH
> 5.0** and **MoldUDP64** specifications. Nasdaq batches multiple messages per
> MoldUDP64 packet, so the real distribution of packet sizes is something you
> measure from a capture, not something you assume.

⚠️ **~100 ns of wire time for a single tick means store-and-forward anywhere in
your path adds ~100 ns per hop.** This is the arithmetic that makes cut-through
non-negotiable.

---

## 4. Ethernet stack latency, per layer

One direction, from the pins to the fabric (RX) or fabric to pins (TX).

| Layer | 10 GbE | 25 GbE | Class | Notes |
| --- | --- | --- | --- | --- |
| PMA / SerDes (per direction) | ~50–120 ns | ~50–120 ns | [OOM] | Highly dependent on transceiver configuration; low-latency modes exist |
| PCS 64b/66b (encode/decode, gearbox, block lock) | ~30–100 ns | ~30–100 ns | [OOM] | Fixed cost of the line code |
| RS-FEC | n/a (typically not used at 10G) | ~100–250 ns | [OOM] | ⚠️ Where FEC is optional, disabling it is one of the largest single latency wins available — at the cost of error resilience |
| MAC, cut-through | ~10–50 ns | ~10–50 ns | [OOM] | |
| MAC, store-and-forward | cut-through + full frame serialization | same | [EXACT] delta | Never use on the fast path |
| **Total RX, 10G, cut-through, no FEC** | **~100–250 ns** | — | [OOM] | Both directions ≈ 200–500 ns of your 1 µs |

> **Verify:** these are the numbers most worth confirming from primary sources,
> because they are large and vendor-specific. For AMD parts see the **10G/25G High
> Speed Ethernet Subsystem** product guide (PG210 family) and the **UltraScale
> Architecture GTY/GTH Transceivers User Guide** (UG578) — both publish latency
> tables for specific configurations. Confirm the exact numbers for **your**
> configuration (FEC on/off, buffer bypass, gearbox mode) and record them in the
> latency budget with the document number.

**Design consequence:** the Ethernet stack is likely 20–50 % of your entire
tick-to-trade budget and you cannot pipeline it away. Choose the low-latency IP
configuration deliberately, and know exactly what each feature costs before
enabling it. See [../02-networking/01-ethernet-phy-mac.md](../02-networking/01-ethernet-phy-mac.md).

---

## 5. Media propagation

| Medium | Refractive index / velocity factor | ns per metre | Class |
| --- | --- | --- | --- |
| Vacuum / free space | n = 1 | 3.336 | [EXACT] (c = 299,792,458 m/s) |
| Microwave through air | n ≈ 1.0003 | ~3.34 | [EXACT-ish] |
| Hollow-core fibre | n ≈ 1.05 (varies) | ~3.5 | [SPEC] — vendor-specific |
| Single-mode fibre (SMF-28 class) | n ≈ 1.4675 at 1310 nm | ~4.90 | [SPEC] — fibre datasheet |
| Multimode fibre (OM3/OM4) | n ≈ 1.48 | ~4.94 | [SPEC] |
| Copper twinax DAC | VF ≈ 0.70–0.80 | ~4.2–4.8 | [SPEC] — cable datasheet |
| Cat6/6a twisted pair | VF ≈ 0.65–0.70 | ~4.8–5.1 | [SPEC] |

**Working rule for this project: fibre = 5 ns/m, copper DAC = 4.3 ns/m.** Both are
rounded up, which is the correct direction for a budget.

### Metres → nanoseconds (fibre @ 5 ns/m, one way)

| m | ns | | m | ns |
| --- | --- | --- | --- | --- |
| 1 | 5 | | 50 | 250 |
| 2 | 10 | | 100 | 500 |
| 3 | 15 | | 200 | 1,000 |
| 5 | 25 | | 300 | 1,500 |
| 10 | 50 | | 500 | 2,500 |
| 20 | 100 | | 1,000 | 5,000 |
| 30 | 150 | | 10,000 (10 km) | 50,000 |

[EXACT] given the 5 ns/m assumption; the assumption itself is [SPEC].

⚠️ **Two things people get wrong:**
1. **Optical path length ≠ cable length.** A 10 m patch cable with a slack loop is
   not 10 m of glass. Measure with an OTDR or the optic's own diagnostics.
2. **Round trip is 2×.** A 20 m intra-cage run costs 100 ns each way. If it is on
   both the market data path *and* the order path, you pay it twice.

**Perspective:** 200 m of fibre = 1 µs = your entire tick-to-trade budget. This is
why colocation exists and why intra-cage cabling is an engineering decision, not a
facilities one. See [../06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md).

---

## 6. Switch and network device latency

| Device class | Port-to-port latency | Class | Notes |
| --- | --- | --- | --- |
| Layer-1 device (physical replicator / patch / tap) | ~3–5 ns | [OOM] | Effectively free; used for fan-out and monitoring |
| FPGA-based ultra-low-latency L2/L3 switch | ~40–150 ns | [OOM] | The trading-specific product category |
| Standard data-centre cut-through ASIC switch (10/25G) | ~300–900 ns | [OOM] | Fine for control plane, not for the fast path |
| Store-and-forward switch | cut-through + full frame serialization | [EXACT] delta | +1.2 µs for a 1500 B frame at 10G |
| Software bridge / virtual switch | microseconds | [OOM] | Never on a trading path |
| Optical tap (passive) | ~0 ns, with insertion loss | [SPEC] | The right way to monitor without adding latency |

> **Verify:** every one of these is a **vendor datasheet** number and varies by
> model, port speed, frame size, and whether the measurement is FIFO-to-FIFO or
> port-to-port. Get the number from the datasheet for the exact model you deploy,
> and confirm it with your own two-port loopback measurement.

**Design rule:** count your switch hops. Each avoidable hop on the market data or
order path is worth removing before any RTL micro-optimization. A single
unnecessary standard-switch hop can cost more than your entire book update logic.

---

## 7. PCIe and host interface

| Operation | Typical | Class | Notes |
| --- | --- | --- | --- |
| MMIO write from CPU to device BAR (posted) | ~100–300 ns to retire | [OOM] | No completion; you do not know when it landed |
| MMIO **read** from CPU of device BAR | ~1–2 µs | [OOM] | ⚠️ Blocking and enormously expensive. Never in a hot loop. |
| DMA write, device → host memory (visible to CPU) | ~0.5–1.5 µs | [OOM] | |
| Descriptor + doorbell round trip | ~1–3 µs | [OOM] | |
| Additional latency through a PCIe switch/PLX | +100–500 ns per hop | [OOM] | Another reason to use a CPU-direct slot |
| PCIe Gen3 x16 theoretical throughput | ~15.75 GB/s | [EXACT] | 8 GT/s × 16 lanes × 128b/130b encoding |
| PCIe Gen3 x16 practical throughput | ~12–14 GB/s | [OOM] | |
| PCIe Gen4 x16 theoretical throughput | ~31.5 GB/s | [EXACT] | 16 GT/s × 16 lanes × 128b/130b |

> **Verify:** PCIe protocol overheads and encoding are defined by the **PCI Express
> Base Specification**; achieved latency is a property of your CPU, root complex,
> IOMMU settings, and the FPGA's PCIe IP configuration. Measure it on your own
> machine with a loopback register-read benchmark before designing a control
> protocol around it.

⚠️ **The key architectural consequence:** a PCIe round trip is roughly the same
order as your *entire* tick-to-trade budget. **Nothing on the fast path may involve
the host.** The host loads parameters and reads telemetry; it never participates in
a decision. See [../04-system-architecture/06-cpu-fpga-partitioning.md](../04-system-architecture/06-cpu-fpga-partitioning.md).

---

## 8. Memory access

| Memory | Latency | Bandwidth | Class |
| --- | --- | --- | --- |
| FPGA distributed RAM (LUTRAM) | comb. or 1 cycle (≤ 6.4 ns) | per-instance | [EXACT] cycles |
| FPGA BRAM | 1–2 cycles (6.4–12.8 ns) | very high, massively parallel | [EXACT] cycles |
| FPGA URAM | 1–3 cycles (6.4–19.2 ns) | high | [EXACT] cycles |
| DDR4 via FPGA memory controller | ~100–200 ns | ~15–19 GB/s per channel | [OOM] |
| HBM2 on an FPGA package | ~100–150 ns | hundreds of GB/s aggregate | [OOM] |
| CPU local DRAM | ~70–100 ns | tens of GB/s | [OOM] |

> **Verify:** FPGA memory-primitive cycle latencies are [EXACT] from the
> architecture documentation (**UG573** for UltraScale memory resources); the
> *achievable clock* is your design's problem. DDR/HBM latency is controller-,
> refresh-, and access-pattern-dependent — measure with the vendor's memory
> benchmark IP.

**Design consequence:** external memory is ~15–30× the latency of BRAM. **The order
book lives in BRAM/URAM, never in DDR.** If it does not fit, reduce the symbol
universe or the depth — do not move it off-chip. See
[../01-fpga-design/03-memory-and-storage.md](../01-fpga-design/03-memory-and-storage.md).

---

## 9. CPU reference numbers (for comparison only)

Included so you can reason about what belongs on the host and what does not. All
[OOM] and heavily dependent on microarchitecture, frequency, and mitigations.

| Operation | Typical | Class |
| --- | --- | --- |
| L1 data cache hit | ~4–5 cycles ≈ 1.0–1.5 ns | [OOM] |
| L2 cache hit | ~12–15 cycles ≈ 3–5 ns | [OOM] |
| L3 cache hit | ~40–70 cycles ≈ 12–25 ns | [OOM] |
| Local DRAM access | ~70–100 ns | [OOM] |
| Remote (cross-socket NUMA) DRAM access | ~120–200 ns | [OOM] |
| Branch mispredict penalty | ~15–20 cycles ≈ 5 ns | [OOM] |
| Atomic/lock on contended cacheline | ~50–200 ns | [OOM] |
| Null syscall | ~100–500 ns | [OOM] — ⚠️ speculative-execution mitigations moved this substantially; measure your own kernel |
| Context switch (including cache disruption) | ~1–10 µs | [OOM] |
| Interrupt to userspace handler | ~2–10 µs | [OOM] |
| Kernel network stack, wire → userspace | ~5–15 µs | [OOM] |
| Kernel-bypass NIC, wire → userspace | ~1–2 µs | [OOM] |
| Software order encode + send (kernel bypass, tuned) | ~0.5–2 µs | [OOM] |

> **Verify:** run `lmbench`, `perf`, or your own rdtsc-based microbenchmarks on the
> exact trading host, with the exact BIOS and kernel settings. Published CPU
> latency tables age badly and vary by generation.

⚠️ **The comparison that motivates the whole project:** a *single L3 cache miss* on
the CPU (~100 ns) is comparable to your entire in-fabric book update. A CPU cannot
lose the race by being badly written; it loses by being a CPU.

---

## 10. Tick-to-trade by implementation class

Published and commonly cited figures. **All [OOM], all vendor- and
strategy-dependent, all measured differently by different people.**

| Implementation | Wire-to-wire tick-to-trade | Jitter (p99.9 − p50) | Class |
| --- | --- | --- | --- |
| Software, standard kernel network stack | ~20–100 µs | 10s–100s of µs | [OOM] |
| Software, kernel bypass, ordinary tuning | ~5–20 µs | 10s of µs | [OOM] |
| Software, kernel bypass, heavily tuned (busy-poll, isolated cores, huge pages, no syscalls in the loop) | ~1–5 µs | µs | [OOM] |
| Hybrid: FPGA feed decode + book, CPU decision | ~1–3 µs | ~µs (CPU dominates the tail) | [OOM] |
| Full FPGA, non-trivial strategy | ~250 ns – 1 µs | tens of ns | [OOM] |
| Full FPGA, simple threshold trigger, low-latency MAC, FEC off | ~30–150 ns | single-digit ns | [OOM] |

> ⚠️ **Treat every published tick-to-trade figure as marketing until you know the
> measurement definition.** The number changes by an order of magnitude depending
> on whether it includes: the PHY/PCS in both directions, the fibre, the risk
> gate, a real (rather than degenerate) strategy, and whether it is a mean or a
> maximum. Ask three questions of any quoted figure: *measured where to where?*
> *what percentile?* *what was the strategy actually doing?*

> **Verify:** if you need a competitive benchmark, take it from a vendor's own
> published test methodology document or an independent measurement you performed,
> and record the methodology alongside the number.

**This project's position in the table:** target **< 1 µs** wire-to-wire with the
full pipeline including hardware pre-trade risk; stretch **< 500 ns** for the
trigger path (`CLAUDE.md` §2). That places us in the "full FPGA, non-trivial
strategy" row — which the arithmetic in §2–§5 says is achievable but not
comfortable.

### Budget sketch against the 1 µs target

| Segment | Reference cost | Cycles @156.25 MHz |
| --- | --- | --- |
| Intra-cage fibre in (assume 5 m) | ~25 ns | ~4 |
| RX PMA + PCS + MAC (cut-through, no FEC) | ~100–250 ns | ~16–39 |
| Feed decode (MoldUDP64 + ITCH) | ~20–50 ns | ~3–8 |
| Symbol lookup + book update | ~20–60 ns | ~3–9 |
| Strategy trigger | ~10–40 ns | ~2–6 |
| Risk gate | ~10–30 ns | ~2–5 |
| OUCH encode + TCP TX | ~20–60 ns | ~3–9 |
| TX MAC + PCS + PMA | ~100–250 ns | ~16–39 |
| Intra-cage fibre out (assume 5 m) | ~25 ns | ~4 |
| **Total** | **~330–790 ns** | **~52–123** |

All [OOM]. The point of the table is the **shape**: the Ethernet stack is the
largest single item and it is not yours to optimize by writing better RTL. See
[../05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md)
for how to build and defend the real budget.

---

## 11. Market data rates and bursts

| Quantity | Reference | Class |
| --- | --- | --- |
| Nasdaq TotalView-ITCH total messages per trading day | Hundreds of millions to billions | [OOM] |
| Sustained average rate during continuous trading | 10s of thousands to low millions of msgs/sec | [OOM] |
| Peak 1-second rate | Millions of msgs/sec | [OOM] |
| Peak-to-average ratio within a session | ~10–100× | [OOM] |
| Microburst: peak per-millisecond rate vs. 1-second average | Can exceed 10× again | [OOM] |
| Highest-rate windows of the day | 09:30 ET open, 16:00 ET close, macro releases, halt resumptions | [SPEC] — market structure |
| Message size distribution | Dominated by small messages (19–44 B); batched several per MoldUDP64 packet | [SPEC] — ITCH 5.0 |

> **Verify:** Nasdaq publishes market data capacity and message-rate statistics,
> and the numbers grow year over year. **Do not size a FIFO from this table.**
> Derive your own worst case from a real capture of your worst expected day
> (see [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md) §4),
> then apply a margin.

**Design consequences:**

1. Size for the **microburst**, not the average. A design that handles the daily
   average and drops during the open is a design that fails exactly when it matters.
2. The RX path must accept line rate unconditionally (`CLAUDE.md` §5 rule 4). At
   10G with minimum-size frames, that is one frame every 67.2 ns — **one frame
   every ~10.5 cycles at 156.25 MHz.** That is the real throughput requirement.
3. Peak rate, not average rate, sets your FIFO depths, your symbol-lookup
   throughput, and your drop policy.

---

## 12. Quick conversions

| From | To | Multiply by | Class |
| --- | --- | --- | --- |
| ns @156.25 MHz | cycles | ÷ 6.4 | [EXACT] |
| cycles @156.25 MHz | ns | × 6.4 | [EXACT] |
| bytes @10 GbE | ns | × 0.8 | [EXACT] |
| bytes @25 GbE | ns | × 0.32 | [EXACT] |
| metres of fibre | ns | × 5 (rounded up from 4.90) | [SPEC] |
| metres of copper DAC | ns | × 4.3 | [SPEC] |
| µs | cycles @156.25 MHz | × 156.25 | [EXACT] |
| Gb/s ÷ datapath bits | required clock (Hz) | — | [EXACT] |

**Three numbers to memorize:**
- **6.4 ns** — one cycle at the project core clock.
- **0.8 ns** — one byte on a 10G wire.
- **5 ns** — one metre of fibre.

Everything else you can look up.

---

## Further reading

- [01-glossary.md](01-glossary.md) — what these terms mean
- [03-toolchain-reference.md](03-toolchain-reference.md) — the reports that produce your real numbers
- [../00-foundations/01-digital-logic-and-timing.md](../00-foundations/01-digital-logic-and-timing.md) — where gate and routing delay come from
- [../02-networking/01-ethernet-phy-mac.md](../02-networking/01-ethernet-phy-mac.md) — the stack in §4, in depth
- [../05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md) — turning §10 into a defensible budget
- [../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md) — replacing every [OOM] above with a measurement
- [../06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md) — the physical numbers in §5 and §6
