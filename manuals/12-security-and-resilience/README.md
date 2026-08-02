# 12 — Security and Resilience

> **Why this matters here:** every other tier makes the system faster, more
> correct, or more measurable. This one is about what happens when something —
> an attacker, a compromised dependency, a failing component, or an ordinary
> human on an ordinary Tuesday — makes it do the wrong thing. A tick-to-trade
> engine is a machine for converting a signal into irrevocable financial
> commitments in 128 nanoseconds. That is a large blast radius attached to a
> high-value target, and no other tier covers it.

---

## The thesis of this tier, in four sentences

1. **The worst outcome is not theft, it is order injection.** Anyone who can make
   this system send orders can lose money faster than any human can react.
2. **Most of the damage will come from mistakes, not malice** — so every control
   here is judged on whether it stops an accident as well as an attack.
3. **Permission to trade must be an affirmative conjunction of healthy
   conditions, never the absence of a fault**, because reset, partial
   initialisation, and half-finished configuration must all mean "no".
4. **When in doubt, stop.** Stopping costs a fraction of a session's edge and is
   fully reversible; continuing through a degraded state is unbounded and is not.

---

## Documents

| # | Document | Covers |
| --- | --- | --- |
| 01 | [Threat Model](01-threat-model.md) | Assets, adversaries, trust boundaries, threats per boundary, the attack tree for "send an unintended order", and why injection outranks exfiltration |
| 02 | [Supply Chain and Bitstream Integrity](02-supply-chain-and-bitstream-integrity.md) | What you actually trust, reproducible builds as a security property, bitstream authentication vs encryption, the build-ID arm gate, vendor IP provenance, the hardware SBOM |
| 03 | [Access Control and Governance](03-access-control-and-governance.md) | Roles and separation of duties, change classes, four-eyes on risk limits, the enforcement points that really exist, credential handling, audit trails, the regulatory backdrop |
| 04 | [Resilience and Failure Isolation](04-resilience-and-failure-isolation.md) | Fail-closed system-wide, blast radius per component, failure of {host, FPGA, link, venue, clock}, degradation vs hard stop, bounded response times, fault injection |
| 05 | [Incident Preparedness](05-incident-preparedness.md) | Stop first, kill authority at 3am, the runbook, evidence preservation, game day, post-incident review, notification obligations, re-entry |

**Reading order:** 01 → 04 → 05 for an operator; 01 → 02 → 03 for anyone who
builds, signs, or deploys; all five, in order, once, for everyone.

---

## How this tier relates to the others

| Tier | Relationship |
| --- | --- |
| **03 Algotrading** §06 | Gives the regulatory *requirements* (15c3-5, Reg SCI, CAT, RTS 6). This tier gives the *security posture* that satisfies them and the threats they do not cover |
| **04 System Architecture** §05 | Specifies the risk gate and kill switch. This tier explains what they defend against, what they do **not** defend against, and what happens when they fail |
| **06 Operations** §01–04 | Build, deploy, monitor, test. This tier reframes those as controls: reproducibility is tamper evidence, telemetry is detection, testing is proof of a resilience claim |
| **07 Reference** §04 | Holds the authoritative incident and post-incident **checklists**. This tier holds the reasoning; the checklist holds the steps. Where they differ on ordering, the checklist wins |
| **08 Nasdaq** §09 | The implementable limit specification. This tier is why those limits are the last line and must not be reachable by the wrong person |

⚠️ **This tier does not restate limits, checks, or checklists.** If you find a
risk-check specification here, it is a bug — send it to
[../08-nasdaq/09-risk-controls-and-limits.md](../08-nasdaq/09-risk-controls-and-limits.md).
If you find a tickable step list here, it belongs in
[../07-reference/04-checklists.md](../07-reference/04-checklists.md).

---

## Control inventory

The controls this tier asserts, where each is enforced, and what it actually
covers. This table is the short answer to "what protects us?" — and, more
usefully, to "what does *not*?"

| Control | Enforced in | Stops accidents | Stops an attacker | Document |
| --- | --- | --- | --- | --- |
| Structurally non-bypassable risk gate | Fabric (`rtl/risk/risk_gate.sv`) | ✔ | ✔ (unless the bitstream is compromised) | 01, 04 |
| Latching kill switch, 2-cycle bound | Fabric (`rtl/risk/kill_switch.sv`) | ✔ | ✔ | 04, 05 |
| External `ext_kill_n` GPIO | Fabric + physical | ✔ | ✔ | 05 |
| Fail-closed reset state | Fabric (kill armed, limits zero, watchdog expired) | ✔ | ✔ | 04 |
| Host heartbeat watchdog (50 / 100 ms) | Fabric (`risk_gate`, `csr_regfile`) | ✔ | Partially — an attacker can keep it alive | 04 |
| Risk-window write protection while enabled | Fabric (`csr_regfile.sv` `0x200`) | ✔ | ✖ — root on the host defeats four-eyes | 03 |
| Two-step arm (separate bus writes) | Fabric (`CONTROL[2]`, `CONTROL[3]`) | ✔ | ✖ — two writes are as easy as one | 01, 03 |
| CRC-gated, atomic parameter commit | Fabric (`rtl/risk/risk_params.sv`) | ✔ | Partially | 03, 04 |
| Build-ID arm gate | Fabric + host `ctrld` | ✔ | ✖ — identity, not authenticity | 02 |
| Bitstream signature verification | Device configuration logic | ✔ | ✔ | 02 |
| Reproducible builds + hashed manifest | CI, `scripts/` | ✔ | ✔ (between source and artifact) | 02 |
| Four-eyes on class A/B changes | Host `ctrld` / `paramd` + process | ✔ | ✖ | 03 |
| Separation of strategy author from risk owner | Process | ✔ | ✔ (insider) | 03 |
| DMA audit ring with gap markers | Fabric (`rtl/ctrl/dma_log_ring.sv`) → `logd` | Detection | Detection | 03, 05 |
| Drop-copy / position reconciliation | Host `reconciler` | ✔ | Detection | 04 |
| Price collars and per-symbol limits | Fabric (`sym_risk_t`) | ✔ | ✔ (bounds a forged feed) | 01, 04 |
| A/B feed divergence + gap detection | Fabric (`rtl/net/`) | ✔ | Detection | 01, 04 |
| Host OS hardening + IOMMU | Platform | ✔ | ✔ — **the highest-leverage control** | 01, 03 |
| Physical / cross-connect integrity | Facility | ✔ | ✔ — the *only* control on the feed path | 01 |
| Game day, kill drills, fault injection | Process + `tb/` | ✔ | ✔ | 04, 05 |

⚠️ **Read the ✖ column.** Four of the controls people most often cite as
protection — the two-step arm, the risk-window write protection, the build-ID
gate, four-eyes — do **not** stop an adversary with code execution on the trading
host. They stop mistakes, which is most of the real risk, and they are worth
having for that reason alone. Claiming more than that in a compliance
conversation is how a control inventory becomes fiction.

---

## The numbers this tier commits to

| Property | Value | Source |
| --- | --- | --- |
| Kill trigger → `kill_active` | 1 cycle = 6.4 ns | `rtl/risk/kill_switch.sv` |
| Kill trigger → no order emitted | 2 cycles = 12.8 ns, ≤ `KILL_RESP_CYCLES` (4) | `rtl/fpga_top.sv` |
| External kill added latency | 3-FF CDC + 16-cycle debounce ≈ 102.4 ns | `kill_switch.sv` |
| Host heartbeat stale → warn / act | 50 ms / 100 ms | `rtl/ctrl/csr_regfile.sv` |
| Orders still possible after a kill | ⚠️ At most one frame, already accepted by the MAC | `kill_switch.sv` |
| Fabric tick-to-trade (context) | 20 cycles = 128.0 ns @ 156.25 MHz | `rtl/fpga_top.sv` |

---

## Conventions

Same as the rest of the manuals:

- `⚠️` marks something that silently produces a working-but-wrong — or
  working-but-unsafe — system.
- Rule numbers, statute citations, venue procedures, fee schedules, and device
  security features are **real-world facts that change**. The mechanism is stated
  confidently; every specific number or citation carries a
  `> **Verify:** <named source>`. Take none of them from this manual.
- Where this tier and a venue specification or your compliance function disagree,
  **they win**, and the manual gets corrected.
- Latency is in nanoseconds with cycle counts alongside, at 156.25 MHz.

---

## Further reading

- [../README.md](../README.md) — the full manual index and reading order
- [../../CLAUDE.md](../../CLAUDE.md) §5, §6 — the hard rules and the risk/safety scope this tier operationalises
- [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md) — the regulatory framing
- [../08-nasdaq/09-risk-controls-and-limits.md](../08-nasdaq/09-risk-controls-and-limits.md) — the implementable limit specification
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — the gate and the kill switch as designed
- [../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md) — build discipline as the foundation of provenance
- [../07-reference/04-checklists.md](../07-reference/04-checklists.md) — the authoritative operational checklists
