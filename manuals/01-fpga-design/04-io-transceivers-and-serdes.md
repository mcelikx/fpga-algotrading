# 01.04 — IO, Transceivers, and SerDes

> **Why this matters here:** your fabric pipeline is ~60–100 ns. The IO stack around
> it is **150–400 ns round trip**, and on 25G with FEC it can be worse than your
> entire algorithm. More of the tick-to-trade budget is spent between the fibre and
> your first flip-flop than inside your design. This document is about the part of
> the latency you buy rather than write.

---

## 1. The full stack, both directions

```
        RX  (fibre in)                          TX  (fibre out)
   ┌──────────────────────────┐          ┌──────────────────────────┐
   │ SFP+/QSFP optics         │          │ SFP+/QSFP optics         │
   │   PIN + TIA (+ CDR)      │          │   laser driver + VCSEL   │
   ├──────────────────────────┤          ├──────────────────────────┤
   │ GTY/GTH PMA              │          │ GTY/GTH PMA              │
   │   CDR + deserializer     │          │   serializer + driver    │
   ├──────────────────────────┤          ├──────────────────────────┤
   │ RS-FEC decode  (25G)     │ ← skip   │ RS-FEC encode  (25G)     │ ← skip
   ├──────────────────────────┤          ├──────────────────────────┤
   │ PCS: gearbox, block sync │          │ PCS: scramble, 64b/66b   │
   │      descramble, decode  │          │      encode, gearbox     │
   ├──────────────────────────┤          ├──────────────────────────┤
   │ Elastic buffer + clock   │ ← BYPASS │  (none needed on TX)     │
   │ correction               │          │                          │
   ├──────────────────────────┤          ├──────────────────────────┤
   │ MAC RX (cut-through)     │          │ MAC TX                   │
   │   preamble strip, FCS    │          │   preamble, FCS, IFG     │
   └────────────┬─────────────┘          └────────────▲─────────────┘
                │                                     │
                └── parse → book → strategy → risk → encode  (your fabric)
```

Everything above the fabric line is either hard IP you configure, vendor soft IP you
instantiate, or a small amount of RTL you write. The nanoseconds are distributed
very unevenly across it.

---

## 2. Per-stage latency table

⚠️ **These are order-of-magnitude figures to structure a budget, not numbers to
quote in a design review.** The GT and PCS latency depends heavily on internal
datapath width, buffer bypass, and the exact IP configuration you pick.

### 10GbE (10GBASE-R, no FEC)

| Stage | RX | TX | Notes |
| --- | --- | --- | --- |
| Optical module | ~1–5 ns | ~1–5 ns | Linear (unretimed) SFP+ is lower than a retimed one |
| GT PMA (CDR + deserializer / serializer) | ~20–40 ns | ~15–30 ns | Scales with internal width; narrower = lower |
| PCS (gearbox, block sync, scramble/descramble) | ~10–30 ns | ~10–25 ns | 64b/66b is cheap; the gearbox FIFO is the cost |
| Elastic buffer / clock correction | **~30–60 ns** | n/a | **Bypassable — this is the biggest single win** |
| MAC (cut-through) | ~5–15 ns | ~5–15 ns | Your RTL; see §5 |
| **Total (buffer bypassed)** | **~40–90 ns** | **~30–75 ns** | |
| **Total (buffer enabled)** | **~70–150 ns** | **~30–75 ns** | |

### 25GbE (25GBASE-R)

| Stage | RX | TX | Notes |
| --- | --- | --- | --- |
| Optical module | ~1–5 ns | ~1–5 ns | |
| GT PMA | ~15–30 ns | ~12–25 ns | Faster line rate → fewer ns for the same UI count |
| **RS-FEC (Clause 91, RS(528,514))** | **~100 ns** | **~50–100 ns** | Fixed. Unavoidable if the link requires it. See §4 |
| PCS | ~10–25 ns | ~10–20 ns | |
| Elastic buffer | ~25–50 ns | n/a | Bypassable |
| MAC | ~4–12 ns | ~4–12 ns | |
| **Total, FEC off, buffer bypassed** | **~30–70 ns** | **~26–60 ns** | The reason people fight for no-FEC links |
| **Total, RS-FEC on** | **~130–170 ns** | **~76–160 ns** | |

> **Verify:** every row. Sources, in order of authority:
> 1. UG578 *UltraScale Architecture GTY/GTH Transceivers* — the "Latency" sections
>    give per-block latency in **UI** for each configuration; multiply by the UI
>    period (97.0 ps at 10.3125 Gbps, 38.8 ps at 25.78125 Gbps).
> 2. PG210 *10G/25G Ethernet Subsystem* — the product guide publishes MAC+PCS
>    latency tables per configuration, including the low-latency variants.
> 3. IEEE 802.3 Clause 91 for the RS-FEC codeword structure, and your FEC IP's
>    datasheet for the implemented latency.
> 4. **Your own loopback measurement.** Nothing above substitutes for a hardware
>    timestamp at the pin. See
>    [05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md).

---

## 3. "Low-latency mode": what you are actually trading away

Vendor low-latency Ethernet configurations are a bundle of specific bypasses. Know
which one you enabled and what it cost you in features.

| Technique | Saves | Gives up |
| --- | --- | --- |
| **RX elastic buffer bypass** | ~25–60 ns | The fabric must run on the **recovered clock** (`RXOUTCLK`), or you must do clock correction elsewhere. Adds a phase-alignment procedure to bring-up and a reset-sequencing requirement. |
| **Narrower GT internal datapath** (e.g. 32-bit instead of 64-bit) | ~5–15 ns | A higher fabric clock for the same line rate; more timing pressure |
| **Raw / bypassed PCS** — do 64b/66b block sync, gearbox, and descramble in your own fabric | ~10–30 ns | You own block lock, hi-BER monitoring, local/remote fault handling, and the descrambler. This is real work and a real bug surface. |
| **No FEC on 25G** | ~150–200 ns round trip | Link margin. Only valid where the medium and the peer allow it. |
| **Cut-through MAC** | up to the full frame serialization time | You forward bytes before the FCS is checked (see §5) |
| **Reduced/disabled auto-negotiation and link training** | Bring-up time only, not steady-state ns | Interop robustness; the peer must be configured to match |

**Project position:** RX elastic buffer bypass — **yes**, it is the single largest
available saving, and it forces a clocking decision (§7) that you make once, at the
top of the design. Cut-through MAC — **yes**, with the FCS policy in §5 written down
and counted. Raw PCS — **not initially**; take the vendor PCS, measure it, and only
hand-roll 64b/66b if it lands in your top three line items (it usually doesn't; the
elastic buffer does). No FEC — **venue-dependent**, see §4.

⚠️ **Enabling "low latency mode" in a wizard and not re-verifying link stability is
how you get a design that works on the bench and takes bit errors in production.**
Every latency bypass is followed by a PRBS31 BER soak and a real-traffic run checked
against the venue's own sequence numbers for gaps.

---

## 4. RS-FEC on 25G, and why it drives venue and media choice

25GBASE-R was standardised with three flavours, and they differ by roughly
**200 ns of round-trip latency**:

| Link type | FEC | Round-trip FEC cost |
| --- | --- | --- |
| 25GBASE-CR-S / 25GBASE-KR-S (short copper) | None, or BASE-R FEC (Clause 74) optional | 0, or ~50–80 ns for the lighter Clause 74 FEC |
| 25GBASE-CR / 25GBASE-SR | RS-FEC (Clause 91) typically required | **~150–200 ns** |
| 25GBASE-LR / longer reach | RS-FEC required | ~150–200 ns |

The RS(528,514) code operates on a **528-symbol codeword**. The decoder cannot emit
the first byte of a codeword until it has received enough of the codeword to
correct it — that buffering *is* the latency, and it is a property of the code, not
of the implementation. No vendor can optimize it away.

> **Verify:** IEEE 802.3 Clause 91 (RS-FEC) and Clause 74 (BASE-R FEC) for codeword
> structure; PG210 and the AMD 25G FEC documentation for the implemented latency of
> each mode.

### Consequences for this project

- **Ask the venue and your colo provider what FEC mode the cross-connect runs**
  before choosing 25G. For small messages a 25G link with RS-FEC is *slower
  end-to-end* than a 10G link without. Higher line rate does not automatically mean
  lower latency.
- 25G's genuine win is **serialization** (§6): 0.32 vs 0.8 ns/byte, saving ~53 ns
  each way on a ~110-byte order frame. RS-FEC costs ~150–200 ns round trip.
  **The arithmetic favours 10G-without-FEC for small frames.**
- 25G wins decisively when *throughput*-constrained — a full-depth feed that
  saturates 10G during the open — because dropping packets beats 200 ns every time.
- **Decision rule:** 10GbE, no FEC, elastic buffer bypassed, for both market data RX
  and order TX. Move to 25G only when a capture proves the feed exceeds 10G, and
  only after confirming the FEC mode.

---

## 5. The MAC, cut-through, and the FCS problem

A store-and-forward MAC buffers the entire frame, verifies the FCS, and only then
presents it to your logic. For a 1518-byte frame at 10G that is **~1.2 µs** of
added latency. Your whole budget, spent on a buffer.

A cut-through MAC streams beats into your parser as they arrive and signals an
error on the *last* beat if the FCS turns out to be bad.

```
Store-and-forward:  [────── frame arrives ──────][check FCS][── forward ──]
Cut-through:        [── forward as it arrives ──][FCS result on tlast]
```

**This means you will act on data from frames that later prove corrupt.** That is
the trade. The rules:

1. **Market data RX: cut-through, always.** A corrupt frame that updated the book
   is recoverable — the venue's sequence numbers will show a gap, or the A/B feed
   will disagree, and you resynchronize. Count `rx_fcs_err` and alarm on any
   non-zero rate; a healthy 10G link should show zero for days.
2. **⚠️ Never emit an order derived from a frame whose FCS you have not yet
   validated**, unless you have explicitly modelled and accepted that risk. In
   practice the ordering works out: the FCS arrives on the last beat, and an ITCH
   message that triggers a decision is rarely the last message in the datagram.
   Make this a checked property in simulation, not an assumption.
3. On the TX side, a hand-written MAC lets you do two things vendor MACs generally
   won't: begin transmitting a frame before the payload is finalized (speculative
   TX, [02-pipelining-and-parallelism.md](02-pipelining-and-parallelism.md) §5), and
   **deliberately corrupt the outgoing FCS to abort a frame in flight**. Both are
   real techniques. Both require venue agreement in writing.

> **Verify:** whether the AMD 10G/25G Ethernet Subsystem MAC already streams with a
> late error flag on `rx_axis_tuser` in your configuration — modern vendor MACs
> often do, which makes the case for hand-writing one weaker than folklore suggests.
> Simulate the vendor core against a raw-PCS reference and measure before you commit
> to writing your own. See
> [06-hls-and-alternative-flows.md](06-hls-and-alternative-flows.md) §5.

---

## 6. Serialization delay: the floor you cannot optimize

Bits go onto the wire one at a time. You cannot transmit byte N before byte 0.

| Line rate | Per byte | 64-byte frame | 110-byte frame | 1518-byte frame |
| --- | --- | --- | --- | --- |
| 1 GbE | 8 ns | 512 ns | 880 ns | 12.1 µs |
| **10 GbE** | **0.8 ns** | **51 ns** | **88 ns** | **1.21 µs** |
| 25 GbE | 0.32 ns | 20 ns | 35 ns | 486 ns |
| 100 GbE | 0.08 ns | 5 ns | 9 ns | 121 ns |

*(10G line rate is 10.3125 Gbaud with 64b/66b, giving exactly 10 Gbps of payload —
hence 0.8 ns/byte. Same arithmetic at 25.78125 Gbaud gives 0.32 ns/byte.)*

### Why this dominates your design decisions

- **Make outbound order frames as small as the protocol allows.** An OUCH
  `Enter Order` inside SoupBinTCP inside TCP/IP/Ethernet lands around 100–115 bytes
  on the wire. Every byte you add costs 0.8 ns at 10G. Do not pad, do not batch two
  orders into one frame if latency matters, do not use jumbo framing on the order
  path.
  > **Verify:** the exact OUCH 5.0 `Enter Order` message length against the Nasdaq
  > OUCH 5.0 specification, and your framing overhead against a real capture of your
  > own session.
- **A store-and-forward device anywhere in the path adds one full serialization
  time per hop.** A store-and-forward switch on a 1518-byte frame costs 1.2 µs.
  This is why colo networks use cut-through switches and why layer-1 devices
  (~5 ns) exist at all.
- **Cable length is a real design variable.** ~5 ns/m in fibre, ~4.3 ns/m in copper
  DAC. A 30 m cross-connect is 150 ns — comparable to your entire fabric pipeline.
  Argue about cabinet placement; it is cheaper than RTL optimization.

---

## 7. Reference clocks, jitter, and TX clocking

### The reference clock
The GT quad's reference clock arrives on a dedicated differential pin pair
(`GTREFCLK`) and must be **low-phase-noise** — typically 156.25 MHz for 10G/25G,
with a random-jitter budget on the order of a picosecond RMS. A refclk can be shared
across a limited number of adjacent quads through dedicated north/south routing;
beyond that range you need another refclk input.

⚠️ **Never drive a GT reference clock from an MMCM/PLL output or from fabric
routing.** It will link up on the bench, look fine, and then take bit errors under
temperature or against a marginal peer. The refclk comes from a dedicated oscillator
or jitter cleaner (Si534x-class) through the dedicated pins, full stop.

> **Verify:** reference-clock jitter and frequency-accuracy requirements, and the
> exact quad-sharing distance, in UG578 "Reference Clock Requirements" — the sharing
> distance differs between UltraScale and UltraScale+. Plus your board's oscillator /
> jitter-cleaner datasheet.

### Local-clock TX vs recovered-clock TX

| | Standard (local refclk TX) | Loop-timed (recovered clock TX) |
| --- | --- | --- |
| TX clock source | Local oscillator | Clock recovered from the RX link |
| Frequency offset vs peer | Up to ±200 ppm (±100 each side) | Zero, by construction |
| Clock correction needed | **Yes** — the RX elastic buffer inserts/deletes idles in the IFG | **No** |
| Elastic buffer bypass | Requires care: fabric runs on `RXOUTCLK`, or you correct elsewhere | Natural |
| Standards conformance as an endpoint | Normal | Non-standard for a host endpoint |
| Used by | Everything | Layer-1 switches, some ultra-low-latency appliances |

The elastic buffer exists to absorb the ±200 ppm frequency difference between your
oscillator and the venue's. Over a 1518-byte frame that drift is well under one
byte, so the buffer only needs to be a few words deep — but the vendor default is
far deeper, and that depth *is* latency.

**Project position:** bypass the RX elastic buffer, run the RX datapath on the
recovered clock, and cross into the core clock through the async FIFO at the MAC
boundary ([03-memory-and-storage.md](03-memory-and-storage.md) §5). Keep TX on the
local reference clock — the standard arrangement — unless you have written
confirmation that the peer switch accepts a loop-timed endpoint.

⚠️ This means the RX datapath *upstream of the async FIFO* has no guaranteed
relationship to the core clock and **does not clock at all during link-down**. Reset
sequencing must survive "link up, down, up again" without wedging. Test it by
pulling the fibre, repeatedly, in hardware.

---

## 8. PCIe: slow path only

PCIe is a packet-switched, credit-based, retry-capable interconnect with a deep
pipeline. It is excellent at bandwidth and mediocre at latency, and its latency is
not deterministic.

| Operation | Rough round trip | Nature |
| --- | --- | --- |
| Host MMIO **read** of a BAR register | **~300 ns – 2 µs** | Non-posted TLP; the CPU core **blocks** |
| Host MMIO **write** to a BAR register | ~100–300 ns to land | Posted — fire and forget, no completion |
| FPGA DMA write → host memory → host polls the flag | **~500 ns – 1.5 µs** | The best case for FPGA→host notification |
| Host writes a descriptor + doorbell → FPGA acts | **~1–3 µs** | Two crossings |
| Gen3 x16 sustained bandwidth | ~15.75 GB/s theoretical, ~12–13 GB/s real | 8 GT/s × 16 lanes × 128b/130b |

> **Verify:** measure MMIO read latency yourself with `rdtsc` bracketing a
> `volatile` read on your actual host and root complex. Platform variation is
> large — a different CPU generation, IOMMU setting, or PCIe switch in the path can
> change it by 2×. Never take a vendor figure for this.

### Rules

1. **No decision on the tick-to-trade path waits on PCIe.** Not for a parameter, not
   for a position check, not for a "just this once" software confirmation. If the
   fabric needs a value to make a trading decision, that value already lives in
   fabric memory.
2. PCIe carries: control-register writes, table loads (with the shadow-bank atomic
   swap), telemetry/counter reads, latency histograms, captured packets, order
   acknowledgements for reconciliation, and the kill-switch *arm/disarm* command.
3. ⚠️ **The kill switch must not depend on PCIe to be effective.** A software write
   over PCIe *arms* it, but the enforcement — blocking outbound orders — happens in
   fabric, in a bounded number of core-clock cycles, and continues to work if the
   host hangs, the driver crashes, or the PCIe link goes down. Link-down should
   itself trip the switch. See
   [04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md).
4. Use the vendor PCIe hard block and vendor DMA IP (XDMA/QDMA). There is no latency
   argument for hand-rolling it and enormous risk in doing so. See
   [06-hls-and-alternative-flows.md](06-hls-and-alternative-flows.md) §5.

---

## 9. Bring-up, eye scan, and link debug

**Build an IBERT design before you build your MAC.** A transceiver that will not
link is a board/optics problem, and debugging it through a half-finished Ethernet
stack wastes days.

| Step | Check | How |
| --- | --- | --- |
| 1 | Reference clock present, correct frequency | Route the GT refclk to a fabric counter and read it over PCIe. Do not assume. |
| 2 | GT reset sequence completed | `TXRESETDONE` / `RXRESETDONE` high and stable |
| 3 | TX is actually driving | Loop the fibre back to yourself; check optics DDMI TX power over I2C |
| 4 | CDR locked | `RXCDRLOCK` (advisory — it can assert on noise) |
| 5 | PRBS clean | GT built-in PRBS7/PRBS31 generator + checker, both ends. **Zero errors over minutes**, not seconds. |
| 6 | Eye opened | RX margin analysis / eye scan via DRP |
| 7 | Block lock / gearbox aligned | 64b/66b block lock status from the PCS |
| 8 | FEC aligned (25G) | FEC lock + corrected/uncorrected codeword counters |
| 9 | MAC sees valid frames | FCS error counter at zero, frame counter incrementing |

### Causes of "no link", in the order they actually occur

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| No CDR lock, no light | Optics disabled | `TX_DISABLE` pin / I2C module control |
| CDR locks, no block lock | **P/N pair swapped** on the PCB | `RXPOLARITY` / `TXPOLARITY` in the GT — free, no respin |
| Block lock flaps | Marginal eye, wrong equalization | Tune TX pre/post-cursor and RX equalizer; re-run eye scan |
| Link up, high FCS error rate | FEC mismatch, or a low-latency bypass enabled without margin | Compare FEC config with the peer; re-enable what you removed |
| Nothing at all after a config change | Wrong line rate / refclk frequency in the wizard | Re-check the GT wizard settings against the actual oscillator |
| 25G won't come up with a specific peer | Auto-negotiation / link-training mismatch | Match AN+LT settings with the peer; many venue switches expect specific behaviour |

**Eye scan is not optional for a production link.** Run it after every change that
touches the transceiver configuration, and record the eye area alongside the
bitstream in your build artifacts. A shrinking eye across builds is an early warning
you will otherwise only see as intermittent FCS errors during the open.

> **Verify:** eye-scan / RX margin analysis procedure and the DRP register map in
> UG578, and the IBERT product guide for your device family.

---

## 10. Pin planning and floorplan anchoring

**GT quads are at fixed physical locations on the die and belong to specific SLRs.
You cannot move them. Therefore they anchor your entire floorplan.**

```
   ┌─────────────────────── SLR2 ───────────────────────┐
   │ GT quads     [                                   ] │
   ├─────────────────────── SLR1 ───────────────────────┤   ← Laguna crossing here
   │ GT quads     [                                   ] │      costs a register stage
   ├─────────────────────── SLR0 ───────────────────────┤   ← and here
   │ GT quads     [  PCIe hard block                   ] │
   └────────────────────────────────────────────────────┘
```

### Rules for this project

1. **The entire tick-to-trade path lives in ONE SLR** — the one containing the RX
   quad. Parser, symbol table, book, strategy, risk gate, encoder, TX MAC. Create a
   `pblock` for it and check the placement in the Device view, every build.
2. **Put the RX and TX quads in the same SLR.** If the card's fibre ports map to
   quads in different SLRs, an SLR crossing is forced onto the critical path — a
   Laguna register, at minimum one extra cycle (6.4 ns), often more once the tool
   pipelines the long route. ⚠️ Check the quad-to-SLR mapping **before you buy the
   card**, not after.
3. **The PCIe hard block is usually in a different SLR.** Fine — PCIe is slow path.
   Let the tool place it and put the async FIFO at the boundary.
4. Constrain transceiver locations explicitly rather than letting the tool pick:

```tcl
# constraints/gt_placement.xdc
# GT quad and channel locations are FIXED by the board. Pin them, don't hope.
set_property PACKAGE_PIN AA38 [get_ports {qsfp0_rx_p[0]}]
set_property PACKAGE_PIN AA39 [get_ports {qsfp0_rx_n[0]}]
set_property PACKAGE_PIN Y33  [get_ports {qsfp0_refclk_p}]
set_property PACKAGE_PIN Y34  [get_ports {qsfp0_refclk_n}]

# Anchor the fast path into the SLR that owns the RX quad.
create_pblock pblock_fastpath
add_cells_to_pblock [get_pblocks pblock_fastpath] [get_cells -hier -filter {NAME =~ *u_tick_to_trade*}]
resize_pblock [get_pblocks pblock_fastpath] -add {SLR0}

# The GT reference clock is asynchronous to everything else in the design.
create_clock -period 6.400 -name gt_refclk [get_ports qsfp0_refclk_p]
set_clock_groups -asynchronous -group [get_clocks gt_refclk] -group [get_clocks core_clk]
```

> **Verify:** package pin assignments come from the **board vendor's schematic and
> the AMD package pinout file** for your exact part/package — never from an example
> design. The quad-to-SLR mapping is visible in Vivado's Device view and in the
> device's package files. SSI/SLR crossing guidance is in UG949.

5. **Reserve the routing corridor.** A 512-bit datapath from the GT quad to the
   parser crosses a lot of die; if the parser is placed far away that is a
   multi-nanosecond route on every beat. Keep the first parse stage physically
   adjacent to the MAC.

---

## 11. Rules for this project

1. **10GbE, no FEC, RX elastic buffer bypassed** is the default. 25G only with a
   capture proving throughput need *and* a confirmed FEC mode.
2. **Cut-through MAC on RX**, with the FCS policy written down, counted, and
   asserted in simulation.
3. **GT reference clock from a dedicated low-jitter source through dedicated pins.**
   Never from an MMCM.
4. **Every latency bypass is followed by a PRBS31 BER soak and an eye scan**, recorded
   with the build.
5. **PCIe is slow path only.** No trading decision waits on it; the kill switch works
   without it.
6. **The whole fast path is in one SLR, in a pinned pblock**, anchored by the RX quad.
7. **Measure the IO stack in hardware loopback before optimizing fabric.** If the IO
   stack is 250 ns and your pipeline is 64 ns, you know where to spend the week. See
   [05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md).

---

## Further reading

- [03-memory-and-storage.md](03-memory-and-storage.md) — the async FIFO at the MAC boundary and how deep it needs to be
- [05-verification-and-simulation.md](05-verification-and-simulation.md) — what simulation cannot tell you about a real link
- [06-hls-and-alternative-flows.md](06-hls-and-alternative-flows.md) — vendor IP vs hand-written for MAC and PCIe
- [00-foundations/04-clocking-reset-and-cdc.md](../00-foundations/04-clocking-reset-and-cdc.md) — recovered clock, core clock, and the crossings between them
- [02-networking/01-ethernet-phy-mac.md](../02-networking/01-ethernet-phy-mac.md) — the protocol side of the same stack
- [04-system-architecture/06-cpu-fpga-partitioning.md](../04-system-architecture/06-cpu-fpga-partitioning.md) — what actually crosses PCIe
- [07-reference/02-latency-reference-numbers.md](../07-reference/02-latency-reference-numbers.md) — the numbers in §2 and §6, consolidated
