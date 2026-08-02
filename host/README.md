# host/ — Slow-path software

> The FPGA reacts in nanoseconds. This code decides *what it should react to*,
> proves it did the right thing, and stops it when it didn't.

Governing manual: [manuals/04-system-architecture/06-cpu-fpga-partitioning.md](../manuals/04-system-architecture/06-cpu-fpga-partitioning.md)

---

## 1. The partition rule

Nothing here is on the tick-to-trade path. PCIe round-trip alone is ~500 ns–1 µs,
which is longer than the entire fabric budget. If a decision has to be made in
nanoseconds, it is in `rtl/`. If it has to be made *correctly*, it is probably here.

| Belongs in `host/` | Why |
| --- | --- |
| Strategy parameter computation | Millisecond cadence, needs real math |
| Position and P&L reconciliation | Must be right, not fast |
| Symbol table construction | Built once at session start from ITCH Stock Directory |
| OUCH/SoupBinTCP session lifecycle | Login, logout, sequencing, recovery |
| TCP connection ownership | Handshake, teardown, retransmission |
| Gap recovery (Glimpse / retransmission) | Rare, complex, latency-tolerant |
| Audit logging and CAT reporting | Compliance, not latency |
| Monitoring, alerting, dashboards | Operational |
| The arm/disarm and limit-change workflow | Human-in-the-loop by design |

---

## 2. Planned components

| Component | Responsibility |
| --- | --- |
| `ctrld` | Owns the PCIe register interface. The only writer of control registers. Enforces the startup sequence and the write-protection rules in [rtl/ctrl/README.md](../rtl/ctrl/README.md). |
| `heartbeat` | Writes the watchdog register on a fixed cadence. ⚠️ If this thread stalls, the hardware kill switch fires — that is the intended behaviour, not a bug. |
| `reconciler` | Compares the FPGA's position and open-order state against drop-copy / clearing data. Forces corrections and counts them. A growing correction count means something upstream is wrong. |
| `sessiond` | Owns the OUCH/SoupBinTCP and TCP connections; hands the FPGA a validated header template and sequence number, and resynchronizes it after any loss. |
| `paramd` | Computes strategy parameters and risk limits; writes them into the inactive bank, reads back, verifies, then commits. Never writes a live bank. |
| `logd` | Drains the DMA log ring to durable storage. Every order decision, fill, and risk rejection. |
| `metricsd` | Scrapes the telemetry address space and exports metrics. ⚠️ Scrape cadence must not perturb the datapath. |
| `goldenbook` | The reference order-book implementation. Used as the verification oracle in `tb/`, and in production as an independent shadow book for divergence detection. |

---

## 3. Non-negotiables

1. **The startup sequence is fixed and ordered.** Verify `BUILD_ID` → load symbol
   filter → load risk parameters → commit → **read back and verify** → load
   strategy parameters → commit → verify → configure session and templates →
   start heartbeat → two-step arm → enable trading. Skipping the read-back step
   defeats the purpose of the double-buffered parameter design.
2. **The host never bypasses the risk gate.** There is no software path that emits
   an order. If you find yourself wanting one, that is a design discussion, not a
   patch.
3. **Risk limit changes are never bundled with other work.** Separate change,
   separate review, separate audit entry.
4. **Losing the host must be safe.** If any of these processes dies, the watchdog
   fires and trading stops. Test this deliberately and regularly.
5. **No production credentials, comp IDs, session IDs, or venue IPs in the repo.**

---

## 4. Runtime placement

The slow path still has latency requirements, just three orders of magnitude
looser. See [manuals/02-networking/04-nics-kernel-bypass-and-switching.md](../manuals/02-networking/04-nics-kernel-bypass-and-switching.md)
for the host tuning table: CPU pinning, `isolcpus`, NUMA locality to the PCIe root
port, hugepages, and disabling C-states and frequency scaling.

The reconciler and the heartbeat get dedicated isolated cores. Everything else can
share.
