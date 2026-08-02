# 02.04 — NICs, Kernel Bypass, and Switching

> **Why this matters here:** the FPGA's < 1 µs wire-to-wire budget only means
> something relative to what everyone else is doing, and relative to the latency you
> are *still* paying outside the fabric — switch hops, cabling, and a slow path that
> has to keep up well enough to recover a feed and reconcile risk. This document is
> the map of everything in the trade path that is not your RTL.

---

## 1. Where the latency actually is

For a CPU-based trading system, the wire-to-wire path is roughly:

```
wire → optics → PHY → MAC → NIC DMA → [ driver / stack ] → app decode → book
     → strategy → app encode → [ stack ] → NIC DMA → MAC → PHY → optics → wire
                              ▲                    ▲
                     this is what kernel bypass removes
```

Kernel bypass removes the middle. It does not remove the CPU, the cache hierarchy,
the memory controller, the PCIe round trip, or the operating system's ability to
interrupt you at the worst possible moment.

| Path | Half-RTT, order of magnitude | Jitter (p99.9 / p50) | What dominates |
| --- | --- | --- | --- |
| Linux socket + interrupt-driven NIC | ~5–15 µs | 5–20× | Syscalls, copies, softirq, scheduler, wakeups |
| Linux socket + busy-poll (`SO_BUSY_POLL`) | ~3–8 µs | 3–10× | Still the full stack, just no wakeup |
| `io_uring` | ~3–8 µs | 3–10× | Removes syscall overhead, keeps the stack |
| `AF_XDP` zero-copy | ~2–5 µs | 3–8× | Kernel fast path, userspace buffers |
| **DPDK** (poll-mode, userspace driver) | ~1–3 µs | 2–5× | Cache misses, PCIe, app code |
| **ef_vi / Onload / TCPDirect** (AMD Solarflare) | **~1–2 µs**, sub-µs claimed on newest silicon | 2–5× | Same |
| RDMA / RoCE | ~1–2 µs | 2–4× | Not offered by any equity venue; internal fan-out only |
| **FPGA, tick-to-trade in fabric** | **~0.1–1 µs** | **~1.0×** | Serialization + PHY + your pipeline |

> **Verify:** every row. Kernel-stack numbers vary by an order of magnitude with
> kernel version, NIC, and tuning — measure your own box. For the bypass rows, the
> authoritative sources are the AMD/Solarflare X2/X3-series product briefs and
> Onload/ef_vi documentation, the DPDK project's own performance reports, and — for
> anything you would put in a pitch deck — **STAC-N1 audited reports**, which are the
> only vendor-neutral, methodology-published numbers in this space.

**The framing that matters:** the FPGA's advantage over a well-tuned kernel-bypass
CPU system is maybe 1–2 µs at the median. Its advantage at p99.9 is far larger,
because a CPU's tail is made of cache misses, TLB shootdowns, SMIs, C-state exits,
and page faults — and an FPGA pipeline has none of those. **You are not selling a
better mean. You are selling a distribution with no tail.** See
[../00-foundations/01-digital-logic-and-timing.md](../00-foundations/01-digital-logic-and-timing.md) §5.

⚠️ It follows that a benchmark reporting only a mean is not evidence of anything.
Every latency claim in this project reports p50/p99/p99.9/max.

---

## 2. Where to put the FPGA

Three architectures, and they are not equivalent.

### (a) Bump-in-the-wire
The FPGA sits physically inline: venue fibre → FPGA port 0, FPGA port 1 → host NIC.
Every byte crosses the fabric.

| | |
| --- | --- |
| **Pros** | Lowest possible tick-to-trade; the FPGA sees the feed before anything else does; host software is unmodified and keeps a normal socket |
| **Cons** | Reloading the bitstream breaks the link for the host too; needs a **failsafe optical/electrical bypass relay** for power loss; adds the FPGA's store-and-forward-free latency to *all* host traffic; two ports consumed per link |

⚠️ A bump-in-the-wire without a bypass relay means an FPGA power event takes your
market-data feed and your order session down simultaneously. Specify the relay.

### (b) NIC-with-fabric (SmartNIC)
One card containing hardened MAC + DMA + host driver, with user fabric alongside —
the AMD/Solarflare X-series-with-FPGA shape, Napatech, Exablaze/Cisco Nexus SmartNIC.

| | |
| --- | --- |
| **Pros** | One card, one slot, one cross-connect; vendor supplies MAC, DMA engine, driver, and a supported host stack; graceful degradation to a plain NIC if the fabric image fails |
| **Cons** | You inherit the vendor's shell, their MAC latency, and their fabric budget; less user logic than a full Alveo-class part; vendor lock-in on the tooling |

### (c) Standalone FPGA card + separate kernel-bypass NIC
The FPGA owns dedicated cross-connects for market data in and orders out. A separate
NIC carries the slow path: Glimpse, retransmission requests, risk reconciliation,
telemetry, control.

| | |
| --- | --- |
| **Pros** | The whole fabric is yours; slow path runs on a proven, debuggable, supported stack with `tcpdump`; failure domains are separate; the FPGA can be reprogrammed without touching the host's network |
| **Cons** | Two slots, two (or more) cross-connect ports, more cabling and more to get wrong at turn-up |

### Recommendation for this project: **(c)**, with (b) as an acceptable substitute.

The deciding argument is not latency — the difference between (a), (b), and (c) on
the hot path is small. It is **failure isolation and debuggability**. Recovery,
Glimpse, risk reconciliation and the kill-switch control plane must keep working when
the fast path is being reprogrammed, and they must be inspectable with ordinary
tools. Choose (a) only if the venue port budget forces it, and then only with a
bypass relay and a documented reload procedure.

> **Verify:** available slot count, PCIe lane budget, and — critically — which PCIe
> root complex / NUMA node each slot is on, before buying anything. See §7.

---

## 3. Switches

### Cut-through vs. store-and-forward

A **store-and-forward** switch buffers the whole frame before forwarding: latency =
frame serialization time + switching. At 10G a 1500 B frame is **1.2 µs of pure
buffering** — see [01-ethernet-phy-mac.md](01-ethernet-phy-mac.md) §5.

A **cut-through** switch begins forwarding once it has the destination address, so
latency is roughly constant regardless of frame size.

| Device class | Typical port-to-port latency | Notes |
| --- | --- | --- |
| General-purpose store-and-forward switch | 1–5 µs (frame-size dependent) | Never on a trading path |
| Datacentre cut-through switch | ~300–800 ns | Fine for management, not for feeds |
| Low-latency trading switch (cut-through) | **~40–350 ns** | Arista 7150/7050X-class, Cisco Nexus 3548 with Algo Boost |
| **Layer-1 replicator / mux** | **~4–5 ns** | Arista 7130/MetaConnect, Exablaze ExaLINK — see §4 |
| Passive optical tap (splitter) | ~0 ns | Costs optical budget (≈3 dB), not time |

> **Verify:** every figure against the specific vendor datasheet for the specific
> model and port configuration — these numbers move by 3× between models in the same
> family, and vendors quote them under different conditions (same-speed, same-ASIC,
> unloaded).

⚠️ **Cut-through silently becomes store-and-forward** when:
- The ingress and egress port speeds differ (10G → 25G, or 25G → 10G). Any speed
  change forces buffering of the whole frame.
- The egress port is busy — the frame queues, and now you have a *variable* latency.
- The switch is doing anything that needs the whole frame: some ACL modes, some
  encapsulation, and any path that recomputes the FCS.

**Project rule: one speed end to end on the market-data and order paths, and no
oversubscribed link anywhere on them.** A 25G uplink feeding a 10G FPGA port is a
store-and-forward hop wearing a cut-through label.

---

## 4. Layer-1 devices

A layer-1 replicator operates **below the PCS**: it regenerates the electrical or
optical signal and fans it out without ever achieving block lock, parsing a frame, or
knowing what Ethernet is. There is no MAC, no buffer, and therefore no queue.

```
                 ┌──▶ your FPGA
venue fibre ─────┤──▶ capture / timestamping appliance          ~4–5 ns, fixed
   (one)         ├──▶ CPU-based backup system
                 └──▶ a second FPGA (dev/UAT shadow)
```

Compared with a 350 ns switch hop, this removes ~345 ns from **every packet on the
feed, all day.** It is one of the highest-value-per-dollar latency purchases
available, because it requires no engineering.

| Use | Verdict |
| --- | --- |
| Fan out one venue cross-connect to N consumers | **Yes.** This is the canonical use |
| Aggregate multiple TX sources onto one venue uplink | ⚠️ Careful. A pure L1 mux cannot resolve contention — two sources transmitting at once produce garbage. Devices that do this safely are doing L2 aggregation with a buffer, and are no longer 5 ns |
| Patching / remote cross-connect management | **Yes.** Software-defined patch panel; huge operational win |
| Tapping for capture | **Yes** (or a passive splitter) |

⚠️ **Layer-1 devices replicate errors perfectly.** A corrupted frame arrives corrupted
at every consumer, and the device has no counters to tell you it happened — it does
not know. Your FCS/gap counters become the *only* evidence. This is a good reason to
keep an L2 switch and a capture appliance somewhere in the topology even if they are
off the hot path.

> **Verify:** per-hop latency and supported optics/speeds against the specific vendor
> datasheet. Also confirm the device's behaviour on link loss on the source side —
> some pass through LOS, some hold the last state.

---

## 5. The fan-out problem

One feed, many consumers: the production FPGA, a UAT shadow, a capture box, a CPU
fallback, a research feed recorder.

| Method | Latency added | Filtering? | When |
| --- | --- | --- | --- |
| **Fabric fan-out** (one AXI-Stream driving N consumers on the same die) | **0 ns** | Yes | Always, for in-FPGA consumers. It is a wire |
| **Layer-1 replicator** | ~4–5 ns | No | Default for out-of-FPGA consumers |
| **Switch multicast replication** | one switch hop (~40–350 ns) | Yes (IGMP snooping, ACLs) | Only off the hot path |
| **FPGA re-transmits a normalized copy** | your MAC TX (~100 ns) + a hop | Yes — parse once, publish normalized | Good pattern for feeding many CPU consumers a decoded feed |

**Rule: replicate in fabric for anything on the die; layer-1 for anything off it;
never put a switch on the critical path purely to fan out.**

The re-transmit pattern (d) is worth calling out: the FPGA parses ITCH once, arbitrates
A/B once, and republishes a normalized, deduplicated, gap-checked internal multicast
feed. Every downstream CPU consumer then gets a simpler, cheaper, already-correct
stream and none of them repeat the work. It costs one MAC TX and one hop, which is
irrelevant for consumers that were never going to be sub-microsecond anyway.

---

## 6. Loopback and tap points

You cannot optimize what you cannot measure, and you cannot measure a trading system
from inside itself.

| Point | What it isolates | Mechanism |
| --- | --- | --- |
| GT **near-end PMA loopback** | Transceiver only | GT `loopback` port, Vivado GT wizard |
| GT **far-end PMA loopback** | The link plus the far transceiver | GT `loopback` port |
| **PCS loopback** | PCS + PMA | GT config |
| **Fabric loopback** (RX stream wired straight to TX) | MAC + PCS + PMA, both directions — the **floor** of your wire-to-wire latency | A build-time or register-selectable mux in your own RTL |
| **External optical loopback plug** | Everything up to and including the optics | A plug |
| **Passive tap + timestamping capture** | **The whole real system, honestly** | Optical splitter + capture appliance |

The last row is the only measurement that is not self-reported. An external device
that timestamps the inbound feed packet and the outbound order **at the same physical
point in the network** is the definition of tick-to-trade for this project. Anything
measured with the FPGA's own clock at the FPGA's own pins is a component measurement
and must be labelled as such.

**Build the fabric loopback path in from day one**, register-selectable, with a
counter that makes it impossible to forget it is enabled. It gives you the floor of
your budget, and any wire-to-wire measurement is meaningless without knowing that
floor.

Full methodology — histogram construction, correlating captures, what to do about
clock offsets — is in
[../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md).

---

## 7. Time distribution

To correlate a capture at the tap with a timestamp inside the FPGA, and to compare
your latency against a peer's, you need a common clock.

| Mechanism | Achievable accuracy | Notes |
| --- | --- | --- |
| NTP | ~1 ms | Useless for latency work |
| **PTP / IEEE 1588** with hardware timestamping and boundary clocks | ~tens to hundreds of ns | The colo standard |
| **White Rabbit** (IEEE 1588-2019 High Accuracy profile) | sub-nanosecond | Where it is available and worth it |
| GPS / GNSS receiver + PPS into the FPGA | ~tens of ns | Common, and it is what the PTP grandmaster is doing anyway |

> **Verify:** the regulatory floor is much lower than the engineering need — MiFID II
> RTS 25 requires 100 µs divergence from UTC for HFT, which PTP clears trivially.
> Check your venue's and regulator's current requirements directly; do not rely on
> this sentence.

Detail, including how the PPS is disciplined into fabric and how to timestamp on the
RX pin rather than after the MAC, is in
[../06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md) and
[../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md).

---

## 8. Host tuning for the slow path

The slow path is not the fast path, but it is not allowed to be slow *enough to
matter*. Gap recovery, Glimpse rebuilds, risk reconciliation, and the kill-switch
control plane all live here, and a 200 ms scheduler stall during a feed gap is a real
trading loss.

| Knob | What it fixes | How |
| --- | --- | --- |
| **CPU isolation** | Scheduler and timer interference | `isolcpus=`, `nohz_full=`, `rcu_nocbs=` on the trading cores; nothing else runs there |
| **Thread pinning** | Migration, cold caches | `pthread_setaffinity_np` / `taskset`; one thread per isolated core, no oversubscription |
| **NUMA locality** | Cross-socket DMA and memory latency | Pin the thread to the node owning the **PCIe root port** the FPGA/NIC is on. Check `/sys/bus/pci/devices/*/numa_node` and `lstopo` |
| **Hugepages** | TLB misses on DMA rings and book memory | Explicit 2 MB or 1 GB pages, allocated at boot, not THP |
| **Transparent hugepages** | Unpredictable compaction stalls | Set to `never` for latency-sensitive processes |
| **C-states** | 10s–100s of µs exit latency on a wakeup | `intel_idle.max_cstate=0 processor.max_cstate=0`, or hold `/dev/cpu_dma_latency` open at 0 |
| **Frequency scaling / turbo** | Variable clock → variable latency | `performance` governor; consider disabling turbo for *determinism* rather than speed |
| **SMT / hyperthreading** | A sibling thread stealing execution resources | Disable, or leave the sibling of each trading core idle and unallocated |
| **IRQ affinity** | Interrupts landing on trading cores | Pin all IRQs away from isolated cores; disable `irqbalance` |
| **NIC interrupt moderation** | Added latency in the driver | Off, and use busy-poll / poll-mode |
| **SMIs** | Firmware stealing the core for 100s of µs, invisibly | Disable BIOS power monitoring / USB legacy emulation; **monitor the SMI counter (MSR `0x34`)** — an unexplained latency spike is often an SMI |
| **PCIe MPS / MRRS** | DMA efficiency for the ring transfers | Set MaxPayloadSize and MaxReadRequest to the largest both ends support |
| **Speculative-execution mitigations** | Syscall and context-switch cost | `mitigations=off` measurably helps — ⚠️ only on a physically isolated, single-purpose trading host, and only as a documented, signed-off decision |

⚠️ **Tune one knob at a time and measure.** Host tuning is where cargo-culted
`sysctl` lists come from. Anything you cannot demonstrate with a before/after
histogram does not belong in the deployment recipe. The same discipline the RTL is
held to applies here — see
[../05-optimization/05-optimization-playbook.md](../05-optimization/05-optimization-playbook.md).

⚠️ **Never let host tuning become load-bearing for correctness.** If the risk
reconciliation is only correct when the CPU is fast enough, it is not correct. Bound
it explicitly, and make the FPGA's behaviour on a slow or absent host deterministic
and safe — which, for this project, means: stop sending orders.

---

## 9. Project rules

1. **Architecture: standalone FPGA card for the fast path, separate kernel-bypass NIC
   for the slow path.** Bump-in-the-wire only under port-budget pressure, and then
   only with a failsafe bypass relay.
2. **No switch on the market-data or order-entry critical path** unless it is a
   measured, documented cut-through hop. Layer-1 replication where fan-out is needed.
3. **One link speed end to end** on both hot paths. A speed change is a hidden
   store-and-forward hop.
4. **No oversubscription anywhere on the hot path.** Contention converts a fixed
   latency into a distribution.
5. **Fan out in fabric for on-die consumers, layer-1 for off-die.** The normalized
   re-publish pattern serves CPU consumers.
6. **A register-selectable fabric loopback exists in every build**, with a counter,
   and the wire-to-wire floor it measures is recorded in `docs/` per bitstream.
7. **The only tick-to-trade number this project quotes externally is measured at an
   external tap**, with p50/p99/p99.9/max and a stated N. Everything else is labelled
   "simulated" or "component".
8. **PTP with hardware timestamping is a deployment prerequisite**, not a nice-to-have,
   because latency attribution is impossible without a common clock.
9. **Slow-path host tuning is a written, version-controlled recipe** with a
   before/after measurement for every entry, applied by automation, and verified at
   boot. No undocumented `sysctl`.
10. **The system must be safe when the host is slow or gone.** Host stalls are a
    normal operating condition, not an exception; the FPGA's response is bounded and
    tested.

---

## Further reading

- [01-ethernet-phy-mac.md](01-ethernet-phy-mac.md) — the PHY/MAC latency you are adding on top of everything here
- [02-ip-udp-tcp-in-hardware.md](02-ip-udp-tcp-in-hardware.md) — the host stack that owns the TCP connection
- [03-multicast-feeds-and-arbitration.md](03-multicast-feeds-and-arbitration.md) — the A/B paths this topology carries
- [../04-system-architecture/06-cpu-fpga-partitioning.md](../04-system-architecture/06-cpu-fpga-partitioning.md) — what runs on the tuned host and how it talks to fabric
- [../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md) — the measurement methodology referenced in §6 and §7
- [../06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md) — cross-connects, cabling, and PTP in the cage
- [../07-reference/02-latency-reference-numbers.md](../07-reference/02-latency-reference-numbers.md) — the consolidated latency table
