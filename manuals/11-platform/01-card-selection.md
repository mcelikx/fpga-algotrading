# 11.01 — Card Selection

> **Why this matters here:** [CLAUDE.md](../../CLAUDE.md) §2 names an UltraScale+
> Alveo-class card as the working default, and nothing in this repository justifies
> that. The card decides the two largest line items in the
> [master budget](../../rtl/fpga_top.sv) — the ~90 ns of GT RX and the ~90 ns of GT TX
> that together are **56 % of the 321 ns wire-to-wire target** — before you write a
> line of RTL. Fabric optimization can move the 128 ns of fabric. Only the purchase
> order can move the other 180 ns. This document is how you spend that purchase order.

---

## 1. Three classes of platform

Everything on the market that could plausibly host this design falls into one of
three classes, and they differ far more in *what you own* than in what silicon is
inside them.

| Class | What it is | You own | You inherit | Typical use |
| --- | --- | --- | --- | --- |
| **General-purpose accelerator card** (Alveo-class) | An FPGA on a PCIe card with QSFP/SFP cages, designed for compute or 100G throughput | Everything above the GT pins: PCS config, MAC, all protocol logic | A board whose thermal and clocking design was optimized for bandwidth, not nanoseconds | Development, prototyping, cost-sensitive deployment |
| **Purpose-built trading NIC** | Same idea, but the vendor's business is low-latency trading | Your strategy logic, and usually the feed/order stack too | A tuned low-latency MAC/PHY, a validated clock tree, a reference tick-to-trade shell, and sometimes an IP licence you must keep paying | Production, when time-to-wire matters more than cost |
| **Bump-in-the-wire / L1 appliance** | A layer-1 switch or mux chassis with an FPGA application slot | Application logic inside the vendor's shell | Nanosecond-class L1 replication, port mux, and per-port hardware timestamping | Feed replication, inline filtering, timestamping, A/B fan-out |

A fourth category — **evaluation boards** (VCU118-class, Terasic/Intel dev kits) —
exists and is useful, but is a bench instrument. Most lack front-panel SFP+ cages,
none have production thermal design, and their clock trees are built for generality.
Develop on one; never plan to deploy one.

> **Verify:** the vendor landscape here consolidates constantly — Exablaze into
> Cisco, Solarflare into Xilinx into AMD, Metamako into Arista, Enyx into Exegy,
> Fiberblaze into Silicom. Confirm who currently owns and supports any product
> before you build a roadmap on it, and confirm that the low-latency IP that makes
> the card interesting is still licensable.

### 1.1 The build-vs-buy question hidden inside the class choice

Choosing class 1 is choosing to **write and validate a 10GbE MAC/PHY stack**. That
is not a sprint. It is block lock, gearbox alignment, local/remote fault handling,
descrambling, elastic-buffer bypass with its phase-alignment procedure, the FCS
policy of a cut-through MAC, and a BER soak that proves it. See
[02-networking/01-ethernet-phy-mac.md](../02-networking/01-ethernet-phy-mac.md) and
[01-fpga-design/04-io-transceivers-and-serdes.md](../01-fpga-design/04-io-transceivers-and-serdes.md)
for the scope of that work.

Choosing class 2 is choosing to pay for that work and inherit somebody else's
measurement of it. Both are legitimate. **What is not legitimate is choosing class 1
and budgeting as if you had chosen class 2.**

---

## 2. ⚠️ You are buying transceivers, not LUTs

The single most common platform error in this domain is to select the largest
device the budget allows and assume the fast path benefits.

**It does not, and it usually regresses.**

| Bigger device gives you | What it actually costs you |
| --- | --- |
| More LUTs than the fast path can use | Longer average routes across a larger die → worse `T_route`, which already dominates `T_logic` ([00.01](../00-foundations/01-digital-logic-and-timing.md) §2) |
| More SLRs | More opportunities for the tools to scatter your datapath across an interposer at ~1 cycle per crossing ([00.02](../00-foundations/02-fpga-architecture.md) §6) |
| More total BRAM/URAM | More static leakage power, more heat, a harder thermal problem ([04-thermals-and-power.md](04-thermals-and-power.md)) |
| Bigger headroom for the slow path | Multi-hour place-and-route runs, so you do **fewer seed sweeps per day** and converge on a worse result |

The ranking that actually predicts tick-to-trade, in priority order:

| Rank | Criterion | Why it dominates | Where it shows up |
| --- | --- | --- | --- |
| **1** | **Transceiver latency and configurability** | ~180 ns of the 321 ns budget is GT+optics, and the RX elastic buffer bypass alone is worth ~25–60 ns. A GT whose IP does not expose the bypass costs you more than any RTL change you will ever make. | [01.04](../01-fpga-design/04-io-transceivers-and-serdes.md) §2–3 |
| **2** | **Speed grade** | 10–20 % Fmax for money, applied uniformly to every path in the design. The cheapest optimization that exists. | §4 below |
| **3** | **Quad-to-SLR topology** | An RX quad and a TX quad in different SLRs forces an SLR crossing onto the critical path. Unfixable in RTL. | §5 below |
| **4** | **On-chip memory shape** | The symbol table and order-ID map must fit in BRAM/URAM. Touching DDR/HBM on the fast path is a design failure. | §6 below |
| **5** | **MAC/PHY IP quality** | Determines whether you inherit a measured 40 ns RX stack or build one. | §1.1 |
| 6 | Thermal and form factor | Determines whether the timing you closed survives the cage. | [04-thermals-and-power.md](04-thermals-and-power.md) |
| 7 | PCIe generation | **Slow path only.** Gen3 x8 is sufficient for this design. | §7 below |
| 8 | LUT / FF count | Almost never binding for a fast path. | §3 below |

---

## 3. The fast path is small — here is the arithmetic

From the resource budget in [`rtl/fpga_top.sv`](../../rtl/fpga_top.sv):

```
Fast path target:   LUT < 60k   FF < 90k   BRAM < 300   URAM < 64   DSP < 16
```

Against a VU9P-class device, per-SLR:

| Resource | Fast-path budget | Approx. one SLR of a VU9P | Occupancy |
| --- | --- | --- | --- |
| LUT | 60 000 | ~394 000 | **~15 %** |
| FF | 90 000 | ~788 000 | ~11 % |
| BRAM36 | 300 | ~720 | ~42 % |
| URAM | 64 | ~320 | ~20 % |
| DSP | 16 | ~2 280 | < 1 % |

> **Verify:** per-device and per-SLR resource counts come from **DS923**
> (*Virtex UltraScale+ Data Sheet*) and the Vivado device view for your exact part
> and package. Do not quote the numbers above in a design review; regenerate them.

The conclusion is blunt: **the entire tick-to-trade datapath fits comfortably in one
SLR of a mid-range part, with room to spare.** The BRAM row is the only one that
approaches interesting, and it is driven by the symbol universe (§6), not by logic.

What actually consumes a large device in this project is the **slow path** — DMA
rings, logging buffers, telemetry histograms, debug cores, the PCIe subsystem. Those
belong in a different SLR (or a different device entirely) and none of them are
latency-critical.

> ⚠️ **Do not size the card on the total design.** Size it on the fast path, in one
> SLR, and then confirm the rest fits somewhere. A single-die device that holds the
> fast path with 40 % headroom is a *better* trading platform than a three-die device
> at 20 % total occupancy, because it makes the SLR problem structurally impossible.

---

## 4. Speed grade, and the low-voltage trap

Speed grade is a binning of the same die. A faster grade is the same design, the same
constraints, the same RTL — running faster for money.

| Grade | Relative Fmax | When to buy it |
| --- | --- | --- |
| `-1` | baseline | Never, for a fast path |
| `-2` | ~+10–15 % over `-1` | **Project minimum.** |
| `-3` | ~+10 % over `-2` | When WNS is the binding constraint and the cost delta is less than an engineer-month |

> **Verify:** speed-grade deltas are approximate and vary by path type and device
> family. The authoritative source is the **speed files in the tool install** for
> your part — build the same design at two grades and diff the WNS. Availability of
> `-3` in a given package/temperature combination is a distributor question, and
> `-3` parts are frequently the long-lead item.

> ⚠️ **The `-2L` / `-1L` low-voltage variants are not the same part.** They run at a
> reduced `VCCINT` for lower power and have **lower** Fmax than the equivalent
> non-`L` grade at nominal voltage. A BOM that says "-2" and a card that ships "-2L"
> is a silent 10 %+ Fmax loss that will be blamed on your RTL for weeks. Confirm the
> exact ordering part number on the card, in writing, before purchase — and read it
> back off the device IDCODE during [bring-up](03-bringup-procedure.md) §3.

---

## 5. Transceiver topology — the question to ask before the PO

This is the criterion that cannot be recovered from later, and it is not on any
datasheet. It is a property of *the card's* PCB routing.

**Ask the vendor, in writing:**

1. Which GT quad and which channel does each front-panel cage map to?
2. Which SLR does each of those quads belong to on this part?
3. Is the GT reference clock for those quads a dedicated low-jitter oscillator, or
   is it derived/fanned out from a shared source?
4. Are the RX and TX of a given port on the same quad?

The answers determine whether the floorplan in
[01.04 §10](../01-fpga-design/04-io-transceivers-and-serdes.md#10-pin-planning-and-floorplan-anchoring)
is achievable at all.

| Topology | Consequence |
| --- | --- |
| Market-data RX quad and order-entry TX quad **in the same SLR** | The target. Whole fast path pins into one pblock. |
| RX and TX quads **in different SLRs** | ⚠️ A forced SLR crossing on the critical path: ≥ 1 cycle (6.4 ns), often more once the tool pipelines the long route. Permanent, unfixable in RTL. |
| Refclk shared/fanned out through a buffer with unspecified jitter | Marginal eye, retrain risk. Ask for the jitter spec, not the part number. |
| Cages wired to quads at opposite die edges | Long routes from MAC to parser on every beat. |

**Rule for this project:** market-data RX and order-entry TX must land on quads in
the same SLR. If a candidate card cannot guarantee that, it is disqualified
regardless of every other merit.

### 5.1 Port count

Minimum viable is 4 SFP+ ports:

| Port | Purpose |
| --- | --- |
| 1 | ITCH multicast, A feed |
| 2 | ITCH multicast, B feed |
| 3 | OUCH / SoupBinTCP order entry |
| 4 | Spare: loopback measurement, second venue, or a hot standby session |

A QSFP28 cage broken out to 4× SFP+ counts, provided the breakout is supported and
the quad mapping in §5 still holds. Two ports is not enough — you lose either the
B feed or the ability to measure yourself.

---

## 6. On-chip memory: size it against the symbol universe

The fast path must never touch external memory. DDR4 is hundreds of nanoseconds and
variable; HBM is a bandwidth device, not a latency device
([07.02](../07-reference/02-latency-reference-numbers.md) §8). Everything the
datapath reads lives in BRAM, URAM, or LUTRAM.

The sizing drivers:

| Structure | Scales with | Memory class |
| --- | --- | --- |
| Symbol table (stock locate → active index) | ITCH stock-locate space | BRAM |
| Order-ID map (order reference number → price/qty/side/symbol) | **Live resting orders across the tracked universe** — the dominant term | URAM |
| Price-level arrays | tracked symbols × depth | BRAM |
| Hot top-of-book tier | tracked symbols | LUTRAM |
| OUCH template table | order templates | BRAM |

> ⚠️ **The order-ID map is the term that decides your device.** It is the only
> structure that scales with market activity rather than with your configuration,
> and it is the one most likely to be under-sized from a bench estimate. Size it
> from a **capture of a real trading day** at the busiest minute — the open — not
> from an average. Then add the overflow policy: what happens on a miss must be
> defined, bounded, and counted ([CLAUDE.md](../../CLAUDE.md) §5.7). See
> [04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md)
> and [05-optimization/03-resource-power-optimization.md](../05-optimization/03-resource-power-optimization.md) §9.

Practical consequence: a device with generous **URAM** matters more than one with a
high LUT count. URAM availability differs sharply across families and is a real
selection criterion.

---

## 7. PCIe generation: a slow-path decision

PCIe is not on the fast path and will never be. A round trip to the host is
~500 ns–1 µs — larger than the entire wire-to-wire budget
([00.02](../00-foundations/02-fpga-architecture.md) §7).

| Requirement | Driven by | Sufficient |
| --- | --- | --- |
| Control-plane MMIO | CSR reads/writes, parameter updates | Any generation |
| Telemetry / log DMA | Message-rate × log-record size at the open | Gen3 x8 comfortably |
| Bitstream reload cadence | Operations, not trading | Any |

**Gen3 x16 as stated in CLAUDE.md §2 is over-specified but harmless.** Gen4/Gen5
support is not a reason to pay more, and is not a reason to prefer a device family.
What *does* matter, and is a deployment fault rather than a purchase one, is the
slot actually negotiating its full width — see
[06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md) §3
and [03-bringup-procedure.md](03-bringup-procedure.md) §6.

---

## 8. Form factor, slot power, and thermals

| Attribute | What to check | Why |
| --- | --- | --- |
| Height / length | HHHL vs FHFL vs full-length; does it fit the colo chassis with cable bend radius? | A card that fits the bench and not the 1U in Carteret is a lost week |
| Slot power | PCIe CEM x16 slots supply a limited budget; anything beyond it needs an aux connector the chassis must have | An aux-powered card in a chassis without the cable does not boot |
| Cooling | **Passive** (needs chassis airflow, specified in LFM) vs **active** (onboard fan) | Passive cards in a low-airflow chassis run hot and quietly lose you timing margin |
| Airflow direction | Front-to-back vs reversed; must match chassis | Reversed airflow in a hot aisle is a thermal incident waiting for a busy day |
| Front-panel cage type | SFP+ / SFP28 / QSFP28 + breakout | Must terminate the network **on the card** — not on a separate NIC |

> **Verify:** slot and auxiliary power limits are defined by the **PCI Express Card
> Electromechanical (CEM) Specification** for the relevant generation; the card's
> own maximum draw and its required airflow in **LFM** come from the card vendor's
> datasheet. Both are hard numbers — get them from the documents, not from a
> reseller.

Thermals are not a footnote here. See [04-thermals-and-power.md](04-thermals-and-power.md)
for why a card that closes timing on your desk can fail in the cage.

---

## 9. The decision matrix

Score each candidate 0–5 per row, multiply by the weight, sum. The weights encode
this project's priorities; change them only with a written reason.

| # | Criterion | Weight | 0 = | 5 = |
| --- | --- | --- | --- | --- |
| 1 | GT latency & elastic-buffer bypass exposed | **25** | Fixed vendor stack, no bypass, no published latency | Full GT control, bypass supported, vendor publishes per-config latency |
| 2 | Speed grade available | **12** | `-1` or `-2L` only | `-3` in the package you need, in stock |
| 3 | RX/TX quad in one SLR (or single-die part) | **15** | Split across SLRs | Single-die, or both quads in one SLR, confirmed in writing |
| 4 | On-chip memory (URAM/BRAM) vs sized order-ID map | **10** | Requires external memory | 2× headroom on a real-open capture |
| 5 | Low-latency MAC/PHY IP included and measured | **13** | None; build it yourself | Shipped, measured, with a latency spec you can hold them to |
| 6 | Ports (≥ 4 SFP+ equivalent) | 5 | 2 | ≥ 4 plus a spare cage |
| 7 | Thermal design & airflow fit for target chassis | 8 | Unknown LFM, reversed airflow | Specified LFM met by chassis with margin, active option available |
| 8 | Vendor support: schematics, pinout, direct FAE access | 7 | Web forum | NDA schematic + named FAE + reference design |
| 9 | Supply: lead time, lifecycle, second source | 5 | 40+ weeks, EOL announced | In stock, longevity commitment, alternate part |
| 10 | PCIe generation & host interface | 3 | Gen2 x4 | Gen3 x8 or better, direct to CPU root port |
| 11 | Cost (card + IP licences + tool licences) | 5 | — | — |
| 12 | LUT/FF capacity beyond fast-path budget | **2** | Cannot hold the fast path | Any device that holds §3 in one SLR |

Note rows 1–5 carry 75 of the 110 points, and row 12 — the number most people shop
on — carries 2.

⚠️ **A candidate that scores 0 on row 1 or row 3 is disqualified, not down-weighted.**
Those two are unrecoverable in RTL.

---

## 10. Questions that must be answered before a purchase order

Copy this into the procurement thread. An unanswered row is a risk you are buying.

| # | Question | Acceptable answer looks like |
| --- | --- | --- |
| 1 | Exact ordering part number of the FPGA on the card, including speed grade and voltage variant? | A full OPN string, not "UltraScale+ -2" |
| 2 | Quad and channel mapping for every front-panel cage, and the SLR of each quad? | A table or schematic excerpt |
| 3 | GT reference clock source, part number, and jitter spec? | A datasheet, not "a low-jitter oscillator" |
| 4 | Is the RX elastic buffer bypass supported in the shipped IP/reference design? | Yes, with a config example |
| 5 | Published MAC+PHY latency, per direction, per configuration — and was it measured or estimated? | Measured, with the method stated |
| 6 | Maximum card power and required airflow in LFM at the target inlet temperature? | Two numbers from the thermal datasheet |
| 7 | Is a full schematic / pinout available under NDA? | Yes |
| 8 | What IP on this card requires an ongoing licence, and what happens at non-renewal? | An explicit list |
| 9 | Lead time today, and lifecycle/longevity commitment? | Weeks + a date |
| 10 | Can we get an evaluation unit before committing? | Yes |

**Do not accept a latency number that was not measured.** Ask how, with what
instrument, on what timebase — the standard in
[05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md)
applies to vendor claims exactly as it applies to your own.

---

## 11. Project position

1. **Default stands, with the reasoning now written down:** an UltraScale+ class
   part, `-2` speed grade minimum, on a card whose market-data RX and order-entry TX
   quads are in the same SLR.
2. **Prefer the smallest device that holds the fast path in one SLR with ≥ 40 %
   headroom**, plus whatever the slow path needs. Bigger is not better.
3. **A single-die part is strictly preferable** to a multi-SLR part of the same
   speed grade if it holds the design, because it makes the SLR-crossing class of
   bug impossible rather than merely avoidable.
4. **Class 2 (purpose-built trading NIC) is the correct production choice** unless
   the MAC/PHY effort is explicitly funded and scheduled as a project in
   [TASKS.md](../../TASKS.md). Class 1 is the correct development choice.
5. **Evaluate on hardware before committing.** Run the loopback measurement from
   [03-bringup-procedure.md](03-bringup-procedure.md) §14 on an evaluation unit and
   compare it against the vendor's published number. That single measurement is
   worth more than every row of §9.
6. **Any change to the card changes [CLAUDE.md](../../CLAUDE.md) §2 and the budget
   header in [`rtl/fpga_top.sv`](../../rtl/fpga_top.sv), in the same commit.**

---

## Further reading

- [02-vendor-ecosystem.md](02-vendor-ecosystem.md) — which vendor's silicon and toolchain you are buying into
- [03-bringup-procedure.md](03-bringup-procedure.md) — proving the card before you trust it
- [04-thermals-and-power.md](04-thermals-and-power.md) — why the card's cooling is a timing constraint
- [00-foundations/02-fpga-architecture.md](../00-foundations/02-fpga-architecture.md) — SLRs, hard IP, and reading a utilization report
- [01-fpga-design/04-io-transceivers-and-serdes.md](../01-fpga-design/04-io-transceivers-and-serdes.md) — the transceiver latency you are buying
- [05-optimization/03-resource-power-optimization.md](../05-optimization/03-resource-power-optimization.md) — budgeting against one SLR
- [06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md) — the chassis and slot the card has to live in
