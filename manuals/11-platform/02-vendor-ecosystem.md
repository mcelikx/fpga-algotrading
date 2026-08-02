# 11.02 — Vendor Ecosystem

> **Why this matters here:** picking an FPGA vendor is not picking silicon, it is
> picking a toolchain you will fight for years, a licence bill, an IP catalogue that
> either does or does not contain a low-latency MAC, and a supply chain that has to
> still exist when the card fails at 06:00 on an options-expiry Friday.
> [CLAUDE.md](../../CLAUDE.md) §2 names AMD/Xilinx primary and Intel/Altera
> secondary. This document is the argument behind that, and the honest account of
> what the alternatives buy you.

---

## 1. The ecosystems at a glance

| | **AMD (Xilinx)** | **Altera (ex-Intel)** | **Lattice** | **Achronix** | **Microchip** |
| --- | --- | --- | --- | --- | --- |
| Relevant families | UltraScale+, Versal | Agilex 7 / 5, Stratix 10 | Nexus (CertusPro-NX), ECP5 | Speedster7t, Speedcore eFPGA | PolarFire, PolarFire SoC |
| Primary tool | Vivado | Quartus Prime Pro | Radiant (+ Diamond legacy) | ACE (+ Synplify Pro) | Libero SoC (+ Synplify Pro) |
| SerDes ceiling | 112G class on top parts | 112G class on top parts | ~10–12 Gbps class | 112G class | ~12.7 Gbps class |
| Big-die / multi-die | SSI, multiple SLRs | Multi-die on large parts | Single die | Single die | Single die |
| Trading-market presence | **Dominant** | Present | Peripheral | Niche | Rare |
| Fits **this** fast path? | Yes | Yes | No (glue/L1 only) | Yes, over-specified | Marginal |

> **Verify:** every row moves. Family names, SerDes rates, tool names, and — since
> the Altera divestiture — even company ownership have changed within the last few
> years. Confirm against each vendor's current product selector and the datasheet
> for the exact part before committing. Treat the table as a map of the terrain,
> not as a spec sheet.

---

## 2. AMD / Xilinx

**Why it is the default for this project**, in order of weight:

| Reason | Detail |
| --- | --- |
| **Market gravity** | Nearly every commercial low-latency trading NIC, L1 appliance app-slot, and third-party feed-handler IP core targets a Xilinx part first. Being on the same silicon as the ecosystem means reference designs, IP, and the FAE's experience all apply to you. |
| **Transceiver documentation** | UG578 publishes GT latency **in UI per configuration block**, which is what lets you build the budget in [`rtl/fpga_top.sv`](../../rtl/fpga_top.sv) before you own hardware. This is unusually good documentation and it is directly load-bearing here. |
| **Elastic-buffer bypass is a first-class, documented mode** | The single largest available latency saving (~25–60 ns) is a supported configuration with a documented phase-alignment procedure, not a hack. |
| **Vivado's timing and floorplanning story** | `report_timing_summary`, incremental implementation, pblocks, `report_qor_suggestions`, and a Tcl interface good enough to script a seed sweep. See [07-reference/03-toolchain-reference.md](../07-reference/03-toolchain-reference.md). |
| **Hiring** | The people you would hire have used Vivado. |

**The costs you are accepting:**

| Cost | Detail |
| --- | --- |
| Tool licensing | The free Vivado tier's supported-device list historically **excludes the large Virtex/Kintex UltraScale+ parts** you would actually deploy. Budget for a paid seat per developer plus CI. |
| Tool speed | Large-device P&R is measured in hours. This directly limits seed sweeps per day, which limits WNS. It is a real engineering constraint, not an annoyance. |
| Version churn | Vivado behaviour changes between releases in ways that move WNS. **Pin the version** ([07.03](../07-reference/03-toolchain-reference.md) §1) and treat an upgrade as a change requiring re-measurement. |
| IP licensing | Some Ethernet/PCIe subsystem configurations carry their own licence terms. Read them before designing around the IP. |

> **Verify:** Vivado edition names, which devices each edition supports, and what is
> included versus separately licensed change with releases. Check AMD's current
> Vivado licensing and device-support pages — do not plan a budget from this
> paragraph.

⚠️ **Versal is a different animal, not a bigger UltraScale+.** The NoC, the hardened
Ethernet, and the AI Engines change the floorplanning model, the IP interfaces, and
the latency accounting. Hardened high-rate MACs are convenient but are not
automatically *low-latency* MACs — a hardened 400G MAC is optimized for throughput.
If Versal is on the table, the GT and MAC latency figures must be re-derived from
that family's documentation from scratch, and the budget header re-verified. Do not
port a budget across families.

---

## 3. Altera (ex-Intel)

The credible second source, and worth keeping credible.

| Strength | Detail |
| --- | --- |
| **Genuine low-latency Ethernet IP** | Altera has shipped explicitly-named low-latency 10G MAC/PHY IP for years, and the E-tile/F-tile Ethernet stacks expose latency-relevant configuration. This is a real, not nominal, alternative. |
| Transceiver tiles | E-tile / F-tile architectures are well documented and the hard IP is capable. |
| Competitive silicon | Agilex 7 is a serious part; there is no technical reason a tick-to-trade path cannot live on it. |
| Negotiating leverage | A designed-in second source is the only thing that makes a supply conversation symmetric. |

| Friction | Detail |
| --- | --- |
| **Toolchain switching cost** | Quartus Prime Pro is a competent tool with entirely different Tcl, different report formats, different timing-exception syntax, and different synthesis inference behaviour. Every script in [`scripts/`](../../scripts) is Vivado-shaped. |
| Ecosystem thinness in this niche | Fewer trading-specific cards and IP cores target Altera. You will do more yourself. |
| Corporate transition | The unit's separation from Intel is recent; roadmap, support model, and longevity commitments are the thing to ask about explicitly. |
| Licensing | Quartus Prime Pro is a paid tool for the device classes of interest; the free tier targets small devices. |

> **Verify:** current Altera ownership, support model, product roadmap, and Quartus
> licensing tiers directly with the vendor. This changed materially in 2025 and any
> summary here ages badly.

### 3.1 Keeping the second source real

A second source that has never been built is a slide, not a plan. The concrete
practice, per [CLAUDE.md](../../CLAUDE.md) §2:

1. **All vendor primitives live behind wrappers.** No `BUFG`, `MMCME4_ADV`, `URAM288`,
   `GTYE4_CHANNEL`, or `DSP48E2` instantiated anywhere except in `rtl/common/` and
   `rtl/eth/`. Everything above those layers is portable SystemVerilog.
2. **Infer memory, do not instantiate it.** A well-written inferred RAM maps to BRAM
   on one vendor and M20K on the other. A `RAMB36E2` instance maps to nothing.
3. **Lint with Verilator** ([07.03](../07-reference/03-toolchain-reference.md) §6) —
   a vendor-neutral front end catches vendor-specific assumptions early.
4. **Keep the constraint intent in comments.** XDC does not translate to SDC
   mechanically, but *intent* ("this is a false path because the two domains are
   asynchronous and the data is gray-coded") does.
5. **⚠️ Budget the port at "months", not "a rebuild".** The RTL ports. The MAC/PHY
   configuration, the clocking, the floorplan, the timing closure, and the
   measurement campaign do not. Anyone who claims otherwise has not done it.

---

## 4. Lattice

**Verdict for this workload: not the datapath. Occasionally the glue.**

| Attribute | Reality |
| --- | --- |
| Device size | Nexus-class parts are far too small for a full feed handler + book + strategy |
| SerDes | ~10–12 Gbps class ceiling; 10GbE is reachable, 25G is not |
| Toolchain | Radiant is free-tier friendly; ECP5 (and increasingly Nexus) has a genuine open-source flow via Yosys/nextpnr, which is a real advantage for CI and reproducibility |
| Power | Very low static power; genuinely useful where thermals are the constraint |
| Cost | Low, in both silicon and tools |

**Where it legitimately fits in a trading operation:**

- Layer-1 fan-out / port replication boxes
- A timestamping tap built in-house
- Board management, sequencing, and a hardware watchdog independent of the main FPGA
- A cheap always-on kill-switch relay whose failure modes are independent of the
  trading device — a defensible architecture given [CLAUDE.md](../../CLAUDE.md) §5.6

It is not a candidate for `fpga_top`. Do not let the attractive toolchain story pull
the datapath toward it.

---

## 5. Achronix

**Verdict: technically capable, ecosystem-thin, over-specified for this design.**

| Attribute | Reality |
| --- | --- |
| Speedster7t | High-end SerDes, a 2D network-on-chip, and a fabric aimed at 400G-class packet processing |
| Real strength | Very high aggregate bandwidth with an on-chip NoC that removes the hand-routing problem for wide buses |
| Real weakness **here** | Our binding constraint is *latency on a small datapath*, not aggregate bandwidth. A NoC is a throughput structure; putting a fast path on it adds arbitration and buffering — exactly the jitter sources [00.01](../00-foundations/01-digital-logic-and-timing.md) §5 tells us to avoid |
| Toolchain | ACE, with Synplify Pro for synthesis. Smaller user base; fewer trading-specific references |
| eFPGA (Speedcore) | Interesting only if you are taping out an ASIC, which is a different project |

If the design ever became throughput-bound at 100G+ across many venues
simultaneously, this vendor becomes worth re-evaluating. Today it is not.

---

## 6. Microchip PolarFire — honourable mention

Low static power, single-die, non-volatile configuration (fast power-on, no
external config flash dance), and a reputation for determinism. The transceiver
ceiling (~12.7 Gbps class) makes 10GbE workable and 25G not, and the parts are small
relative to a book engine.

Realistic role: the same "independent glue" niche as Lattice, with the added
attraction of instant-on configuration for a supervisory or kill-switch device.

> **Verify:** PolarFire transceiver rates, device capacities, and the Libero
> licensing model from Microchip's current datasheets.

---

## 7. Toolchain maturity, compared on what matters here

| Capability | Vivado | Quartus Prime Pro | Radiant | ACE |
| --- | --- | --- | --- | --- |
| Static timing analysis depth | Excellent; per-path detail, skew/jitter breakdown | Very good | Adequate | Good |
| Scripted non-project flow | Mature Tcl, fully scriptable | Mature Tcl, different dialect | Workable | Tcl-based |
| Incremental implementation | Yes, mature | Yes | Limited | Limited |
| Floorplanning / pblock control | Excellent, needed for the one-SLR rule | Good (Logic Lock) | Basic | Good |
| Seed / directive exploration | Built-in strategies + scriptable sweeps | Yes | Limited | Limited |
| Timing-closure advisories | `report_qor_suggestions` | Advisors | — | — |
| Transceiver debug (eye scan / IBERT-class) | Excellent | Good | Limited | Good |
| Published per-block hard-IP latency | **Yes, in UI** | Partial | — | Partial |
| Free tier covers deployable parts | ⚠️ No | ⚠️ No | Yes | No |
| Open-source flow | No | No | **Partial (ECP5/Nexus)** | No |
| Runtime on a large part | Hours | Hours | Minutes | Hours |

The rows that decide this project are *published per-block hard-IP latency*,
*floorplanning control*, and *transceiver debug*. Those are the three things you
cannot work around with effort.

---

## 8. Licence cost model

Budget four separate lines. They are routinely conflated and the total surprises
people.

| Line | Scales with | Notes |
| --- | --- | --- |
| **Implementation tool seats** | Developers, plus CI machines | Node-locked vs floating changes the CI story completely — a floating seat consumed by a nightly build is a developer blocked at 10:00 |
| **Device support tier** | The largest device you target | The expensive tier exists precisely for the parts you want |
| **Vendor IP** | Per-core, sometimes per-project, sometimes per-device shipped | ⚠️ A per-device royalty is a *production* cost that arrives after the design is locked |
| **Third-party IP** | Per-core + annual maintenance | Low-latency MAC/PHY, TOE, and feed-handler cores from specialist vendors are priced on the value of the latency, not the size of the netlist |

⚠️ **The dangerous licence is the one on the critical path.** If a purchased
low-latency MAC core is what makes the budget work, then non-renewal, an audit
failure, or a vendor acquisition is a **trading outage**, not a procurement issue.
Know, in writing: what happens to a deployed bitstream at licence expiry, whether
the licence permits the hardware you deploy on, and whether you have source or only
an encrypted netlist. An encrypted netlist you cannot debug at 06:00 is a risk to
price in.

---

## 9. The low-latency MAC/PHY situation, per vendor

This is the single most consequential IP question, because it is ~2 stages of the
budget and the hardest block to write.

| Source | What you get | Trade |
| --- | --- | --- |
| **AMD 10G/25G Ethernet Subsystem** | Configurable MAC+PCS with low-latency variants; latency tables published per configuration | Vendor-supported, well-trodden; not the absolute minimum achievable |
| **Altera Low Latency Ethernet 10G MAC** | Explicitly latency-targeted MAC IP | Good; smaller ecosystem around it |
| **Trading-NIC vendor's shipped MAC** | Tuned, measured, sometimes with the elastic-buffer bypass and cut-through already done | Locks you to their card and possibly their shell |
| **Specialist third-party IP** (low-latency MAC/PHY, TOE, feed handlers) | The lowest published numbers on the market | Highest cost; often encrypted; you are trusting their measurement |
| **Open-source cores** (e.g. the widely used `verilog-ethernet` / Corundum lineage) | Readable, hackable, vendor-neutral, free | You own correctness and BER validation; not tuned for minimum latency out of the box |
| **Hand-written in-house** | Exactly the FCS and cut-through policy you want, fully understood | Weeks-to-months, plus a BER soak. See [01.06](../01-fpga-design/06-hls-and-alternative-flows.md) §6 |

**Project position** (consistent with [01.06](../01-fpga-design/06-hls-and-alternative-flows.md) §8):
start on the vendor subsystem in a low-latency configuration, **measure it in
hardware loopback** ([03-bringup-procedure.md](03-bringup-procedure.md) §14), and only
then decide whether the delta to a hand-written or purchased MAC justifies its cost.
Do not pay for latency you have not measured yourself.

> **Verify:** every latency claim for every option above, including the open-source
> and vendor ones, against **your own loopback measurement** on **your own card**.
> Published MAC latency figures are configuration-specific and frequently quoted
> without stating whether they include the PCS, the gearbox, or the elastic buffer.

---

## 10. Supply, lifecycle, and the 06:00 failure

Trading hardware is a spares problem, not just a design problem.

| Question | Why it matters | Target answer |
| --- | --- | --- |
| Lead time for the exact OPN, today? | A `-3` in an uncommon package can be the long pole | Weeks, and known |
| Is the part in a longevity/extended-life programme, with a stated horizon? | A 3-year build against an EOL part is a rewrite | Yes, with a date |
| Are there PCN/EOL notices on the card, the FPGA, the optics, or the oscillator? | The oscillator and the optics EOL more often than the FPGA | None outstanding |
| Cold spare on site, pre-flashed with the current golden image? | Remote hands cannot debug a bare card | **Yes — this is mandatory** |
| Same speed grade and same OPN as production? | A `-2` spare for a `-3` production card is a spare that misses timing | Yes, verified by IDCODE |
| Second card, second slot, ready to take over? | See [06-operations/02](../06-operations/02-deployment-and-colocation.md) §10 | Yes |

⚠️ **A spare card that has never been powered on is not a spare.** Bring it up
([03-bringup-procedure.md](03-bringup-procedure.md)), run the loopback latency
measurement, confirm it matches production within the rig's noise floor, and record
the result. A spare with a different measured latency is a *different system*, and
finding that out during an incident is the worst possible time.

---

## 11. Rules for this project

1. **AMD/Xilinx UltraScale+ primary, Altera secondary.** The reason is ecosystem
   gravity and published GT latency, not silicon superiority.
2. **Vendor primitives only inside `rtl/common/` and `rtl/eth/`.** Everything above
   is portable SystemVerilog. This is what makes rule 1's "secondary" honest.
3. **Pin the tool version** and treat an upgrade as a change that requires
   re-running timing and re-measuring latency.
4. **No vendor IP on the fast path without a hardware-measured latency number** that
   we produced.
5. **No encrypted-netlist IP on the fast path** unless there is a written answer to
   "how do we debug this during a production incident?"
6. **Every purchased core's licence terms are recorded in `docs/`** alongside the
   answer to what happens to a deployed bitstream at expiry.
7. **A cold spare, same OPN, pre-flashed, measured, on site.** Non-negotiable.
8. **Versal, Agilex, or any family change invalidates the budget header in
   [`rtl/fpga_top.sv`](../../rtl/fpga_top.sv).** Re-derive it from that family's
   documentation; do not port the numbers.

---

## Further reading

- [01-card-selection.md](01-card-selection.md) — the card the vendor choice constrains
- [03-bringup-procedure.md](03-bringup-procedure.md) — proving whatever you bought
- [01-fpga-design/06-hls-and-alternative-flows.md](../01-fpga-design/06-hls-and-alternative-flows.md) — vendor IP vs hand-written, and the project policy
- [01-fpga-design/04-io-transceivers-and-serdes.md](../01-fpga-design/04-io-transceivers-and-serdes.md) — what the GT and MAC IP actually costs in nanoseconds
- [07-reference/03-toolchain-reference.md](../07-reference/03-toolchain-reference.md) — the Vivado and Quartus command surfaces side by side
- [06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md) — version pinning and reproducible builds
