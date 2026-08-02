# 00.02 — FPGA Architecture

> **Why this matters here:** you cannot budget resources or predict Fmax without
> knowing what the fabric physically offers. Every RTL construct you write becomes
> one of the primitives below — or fails to, and becomes something much worse.

---

## 1. The basic building blocks

An FPGA is a sea of small configurable elements connected by programmable routing.

```
┌──────────────────────────────────────────────────────────┐
│  CLB   CLB   CLB   BRAM   CLB   CLB   DSP   CLB   CLB    │
│  CLB   CLB   CLB   BRAM   CLB   CLB   DSP   CLB   CLB    │  ← columnar layout
│  CLB   CLB   CLB   URAM   CLB   CLB   DSP   CLB   CLB    │
│ ──────────── programmable routing between all of it ─────│
│  [ GT transceivers ]  [ PCIe hard block ]  [ MAC/CMAC ]  │  ← hard IP at edges
└──────────────────────────────────────────────────────────┘
```

### LUT (Look-Up Table)
A tiny SRAM implementing an arbitrary Boolean function. UltraScale+ uses a
**6-input LUT** (LUT6): 64 configuration bits, one output. It can also be split as
two 5-input LUTs sharing inputs (LUT5×2).

- Any function of ≤6 inputs = **1 LUT, ~0.1 ns**.
- A function of 12 inputs = 3+ LUTs in series = ~0.3 ns of logic **plus routing**.
- Wide comparators, muxes, and adders are just trees of LUTs. Their delay grows
  roughly logarithmically with width — but routing grows too.

LUTs can also be configured as small memories (**LUTRAM** / distributed RAM,
64×1 or 32×2 per LUT) or as shift registers (**SRL16/SRL32**) — very cheap for
short delay lines.

### Flip-flop (FF)
1-bit register. UltraScale+ CLBs give you **2 FFs per LUT** (16 LUTs / 32 FFs per
CLB, split into two slices). FFs are essentially free — **when in doubt, register.**

Because the FF:LUT ratio is 2:1, a design that is FF-heavy and LUT-light is
comfortable. A design that is LUT-heavy is what causes congestion.

### CLB / ALM
AMD calls the group a **CLB** (Configurable Logic Block); Intel calls its
equivalent an **ALM** (Adaptive Logic Module). Same idea, different granularity.
Vendor utilization reports are not directly comparable across the two.

### Carry chain
A dedicated, very fast path for arithmetic (`CARRY8` on UltraScale+). This is why a
64-bit adder is fast and a 64-bit *arbitrary* function is not. Carry chains are
fixed-direction and column-oriented, which constrains placement — a very wide adder
forces a tall, narrow placement.

---

## 2. Memory

| Type | Size | Count (VU9P-class) | Latency | Use for |
| --- | --- | --- | --- | --- |
| **LUTRAM** (distributed) | 64×1 per LUT | thousands | ~0 (async read) or 1 cycle | Tiny tables, small FIFOs, short delay lines |
| **SRL** | 32×1 shift per LUT | thousands | 1 cycle | Pipeline delay matching — *very* cheap |
| **BRAM** (Block RAM) | 36 Kb (or 2×18 Kb) | ~2160 | 1–2 cycles | Order book levels, message buffers, FIFOs |
| **URAM** (UltraRAM) | 288 Kb | ~960 | 2+ cycles | Large symbol tables, big books |
| **HBM** | 8–16 GB stacked | on HBM parts | ~100+ ns | Bulk data — **too slow for the fast path** |
| **DDR4** | GBs | external | ~100–200 ns | Logging, historical data — slow path only |

Key properties:

- BRAM and URAM are **synchronous** — a read costs at least one cycle, and BRAM in
  its low-latency mode still costs 1 cycle plus optional output register.
- BRAM is **true dual-port** (two independent read/write ports). URAM is
  **simple dual-port** with a shared clock and more restrictions, and cascades
  well vertically but has higher latency.
- **⚠️ Adding the optional BRAM output register costs a cycle but is often required
  to hit Fmax above ~350 MHz.** Budget that cycle up front.

**Design implication for the order book:** a lookup that must complete in one cycle
must live in LUTRAM or in registers. Anything in BRAM/URAM implies a pipeline stage.
This is the single biggest structural constraint on book design — see
[04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md).

---

## 3. DSP slices

Hardened multiply-accumulate units (`DSP48E2` on UltraScale+): a 27×18 signed
multiplier, pre-adder, and 48-bit accumulator, with optional internal pipeline
registers.

- **Fully pipelined DSP: ~600+ MHz. Unpipelined: ~200 MHz or worse.**
  If you instantiate a multiply and don't pipeline it, it *will* be your critical path.
- A multiply wider than 27×18 costs multiple DSPs plus adder logic and more latency.
- For trading logic, DSPs mostly show up in: notional value (`price × qty`),
  weighted mid-price, VWAP-style accumulators, and volatility/spread statistics.
- If a multiply is by a **constant**, the tools may turn it into shift-and-add LUT
  logic, which can be faster and cheaper. Check the synthesis report rather than
  assuming.

---

## 4. Routing — the thing that actually limits you

Routing is a hierarchy of programmable switches and wires of various lengths. A
signal takes a path through several switch boxes; each hop costs delay.

Practical consequences, all of which show up in real designs:

1. **Distance costs time.** Two blocks placed far apart have long routes regardless
   of how simple the logic is. Physical proximity is a design concern.
2. **High fanout is expensive.** A signal driving 500 loads needs a distribution
   tree; the tool inserts buffers, adding delay. Fix by **replicating the driver
   register** (`max_fanout` attribute, or manual duplication with
   `DONT_TOUCH`/`KEEP`).
3. **Congestion is real.** If too many signals need to cross the same region, the
   router detours them and delay explodes non-linearly. Congestion, not logic
   depth, is the usual cause of late-stage timing failures in big designs.
4. **Broadcast structures are anti-patterns.** A single "current best bid" register
   read by 200 places is a fanout problem. Pipeline the broadcast into a tree.

---

## 5. Clocking resources

- **MMCM / PLL**: synthesize clocks from a reference. MMCMs are more flexible
  (phase shift, fractional divide); PLLs are lower jitter and cheaper.
- **Global clock buffers (`BUFG`)**: low-skew distribution across the whole device.
  There is a limited number per device — running out is a real failure mode.
- **Regional buffers (`BUFGCE`, `BUFR`)**: cheaper, limited to a clock region.
- **Clock regions**: the die is divided into a grid of clock regions. Crossing many
  of them with the same clock is fine; crossing them with *combinational logic* is
  what hurts.

Design rule for this project: **one datapath clock**, derived from the transceiver
recovered/reference clock. CDC only where physically forced (MAC boundary if the
MAC runs at a different rate, PCIe at 250 MHz, control/JTAG). See
[04-clocking-reset-and-cdc.md](04-clocking-reset-and-cdc.md).

---

## 6. SLRs and stacked silicon

Large devices (VU9P, VU13P, Agilex M-series) are built from multiple dies —
**SLRs** (Super Logic Regions) — connected by an interposer.

- Crossing an SLR boundary costs roughly **a full clock cycle**. The tools will
  insert (and you should explicitly place) a register at every crossing.
- **⚠️ An unplanned SLR crossing on the critical path is one of the most common
  causes of a design that "suddenly" won't close timing** after a resource bump.
- Design rule: **keep the entire fast path inside one SLR.** Put the slow path,
  PCIe, and logging in the others. Declare this in a floorplan constraint early;
  discovering it after P&R is expensive.

Check your device: a VU9P has 3 SLRs. Its "2.5M LUTs" is not one flat pool.

---

## 7. Hard IP

Blocks that are ASIC-hardened on the die — always faster and smaller than fabric
equivalents, but fixed in behaviour and location.

| Hard block | Notes |
| --- | --- |
| **GT transceivers** (GTY/GTH/GTM) | SerDes for 10/25/56/112 Gbps. Latency 50–150 ns each way; low-latency modes trade off features. Physically at die edges. |
| **PCIe** | Gen3/4/5 hard controller. ~500 ns–1 µs round trip to host — **slow path only**. |
| **100G MAC (CMAC) / 25G MAC** | Hardened MACs. Convenient, but a hand-written low-latency MAC in fabric can beat the hard one for cut-through. |
| **Memory controllers** | DDR4/HBM. Fast for bandwidth, not for latency. |
| **System monitor** | Temperature, voltage. Needed for [06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md). |

Hard IP is at fixed physical locations, which anchors your floorplan: your MAC is
near the transceivers at the die edge, so your feed handler should be too.

---

## 8. Reading a utilization report

What each number is telling you:

| Metric | Comfortable | Watch | Trouble |
| --- | --- | --- | --- |
| LUT | < 60 % | 60–75 % | > 80 % — routing gets hard, Fmax drops |
| FF | < 60 % | 60–80 % | > 85 % |
| BRAM | < 70 % | 70–85 % | > 90 % — placement constrained |
| URAM | < 70 % | 70–85 % | > 90 % |
| DSP | any | — | rarely the binding constraint here |

> ⚠️ **Utilization percentages lie about difficulty.** A design at 45 % LUT that is
> concentrated in one clock region can fail routing while a 75 % design spread
> evenly closes easily. Look at the *congestion* report, not just the totals. See
> [05-optimization/03-resource-power-optimization.md](../05-optimization/03-resource-power-optimization.md).

Also: LUT utilization is reported *after* the tool packs logic. Synthesis estimates
and post-implementation numbers routinely differ by 20 %+. Only the
post-implementation number is real.

---

## 9. Choosing a device for this project

Criteria, in priority order for tick-to-trade:

1. **Transceiver latency and count** — you need at least 2 (feed in, orders out),
   realistically 4+ (A/B feeds, multiple venues, host loopback).
2. **Speed grade** — a -2 or -3 part buys you 10–20 % Fmax for real money. On a
   latency-critical design this is often the cheapest optimization available.
3. **Single-SLR capacity sufficient for the fast path** — see §6.
4. **On-chip memory** — enough URAM/BRAM to hold your symbol universe and book
   depth without touching external memory.
5. LUT count — usually the *least* binding constraint for a fast path. Trading
   fast paths are small; it's the slow path and logging that bloat.

Commercial low-latency trading cards (Exablaze/Cisco Nexus SmartNIC, Solarflare
X2/X3 with FPGA, NovaSom/Enyx/LDA platforms) bundle a tuned MAC+PHY that is hard to
beat from scratch. Building your own MAC is a real project — budget for it or buy it.

---

## Further reading

- [01-digital-logic-and-timing.md](01-digital-logic-and-timing.md) — what the delays mean
- [03-hdl-and-rtl-coding.md](03-hdl-and-rtl-coding.md) — writing RTL that maps onto these primitives
- [01-fpga-design/03-memory-and-storage.md](../01-fpga-design/03-memory-and-storage.md) — choosing between LUTRAM/BRAM/URAM in practice
