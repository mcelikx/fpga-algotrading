# 12.01 — Threat Model

> **Why this matters here:** every other manual in this repository asks "how do we
> make the right decision in 128 nanoseconds?" This one asks "what if something
> makes us send the *wrong* order, 10 million times a second?" A tick-to-trade
> engine is a machine built to convert an input signal into irrevocable financial
> commitments at line rate. That is exactly what an attacker wants. The security
> property we care about is not secrecy — it is **control over what leaves the TX
> port**.

---

## 1. Scope, and the rule that makes a threat model useful

A threat model that lists everything is a threat model nobody reads. This one is
scoped by a single question:

> **What could cause this system to send an order that we did not intend, or to
> fail to stop sending orders when we want it to?**

Everything that answers that question is in scope. Everything else — the
corporate laptop, the wiki, the office VPN — is somebody else's model. The
boundary is drawn at anything that can influence `oe_tx_p/oe_tx_n` on
[`rtl/fpga_top.sv`](../../rtl/fpga_top.sv).

Three properties, ranked. **The ranking is the whole point of this document:**

| # | Property | What it means here | Priority |
| --- | --- | --- | --- |
| 1 | **Integrity of order flow** | Only orders the strategy actually decided on, within limits, leave the card | **Existential** |
| 2 | **Availability of the stop** | The kill switch works when we reach for it | **Existential** |
| 3 | **Confidentiality** | Strategy parameters, positions, credentials stay secret | Serious, survivable |

Note that the ordering is the *inverse* of a typical IT threat model, where
confidentiality leads. Getting this ordering wrong produces a security programme
that encrypts the parameter file and leaves the BAR writable.

---

## 2. Assets

| Asset | Where it lives | Loss of confidentiality | Loss of integrity |
| --- | --- | --- | --- |
| **Ability to emit an order** | `rtl/order/` TX path, gated by `rtl/risk/risk_gate.sv` | n/a | **Catastrophic** — unbounded loss at line rate |
| **Risk limits** (`sym_risk_t`) | `rtl/risk/risk_params.sv` active bank; host `paramd` | Low — limits are dull | **Catastrophic** — a widened limit removes the only bound on §1 |
| **Kill switch state** | `rtl/risk/kill_switch.sv`, CSR `CONTROL[1]` | n/a | **Catastrophic** — a stuck-disarmed kill is a system with no brakes |
| **Strategy parameters** (`sym_strat_t`, incl. `fair_value`) | `rtl/strategy/param_table.sv`; CSR window `0x300` | High — this is the edge | **Severe** — steers the strategy without touching risk limits |
| **Live position / P&L** | `rtl/risk/position_monitor.sv`, host `reconciler` | Moderate — reveals inventory | **Severe** — a wrong position lets a real limit be exceeded |
| **Venue credentials** (SoupBinTCP user/pass, MPID, session IDs) | Host config, never the repo (`CLAUDE.md` §6) | **Severe** — impersonation at the venue | Severe — session denial |
| **Order audit log** | `rtl/ctrl/dma_log_ring.sv` → host `logd` | Moderate | **Severe** — you cannot reconstruct, defend, or report |
| **Bitstream** | Build artifact, host disk, card flash | Moderate — reveals the design | **Catastrophic** — see [02-supply-chain-and-bitstream-integrity.md](02-supply-chain-and-bitstream-integrity.md) |
| **Market data feed content** | Multicast on the MD RX lanes | Low — it is public data | **Severe** — a forged book drives a real order |
| **Colocation physical access** | The cage, the cross-connect, the card | — | Severe — everything above becomes reachable |

⚠️ **`fair_value` deserves separate attention.** The strategy parameter window at
CSR `0x300` is *deliberately not write-protected while trading is enabled*,
because the host updates `fair_value` at millisecond cadence
([`rtl/ctrl/csr_regfile.sv`](../../rtl/ctrl/csr_regfile.sv) header). That is the
correct engineering trade and it is also, precisely, the softest control-plane
surface in the system: an adversary who can write one 32-bit word at `0x300+`
can move the strategy's notion of fair value and make the machine trade against
itself *without ever touching a risk limit or the kill switch*. Every risk check
still passes. Every order is "legitimate".

---

## 3. Adversaries

| Adversary | Capability assumed | Motivation | Most likely entry | Realistic? |
| --- | --- | --- | --- | --- |
| **External network attacker** | Can send packets that reach the card's RX ports; cannot get root on the host | Manipulate our behaviour, or take us down | Market-data multicast injection; order-entry link | Low probability, high impact — a colo cross-connect is a hard path to reach |
| **External host attacker** | Remote code execution on the trading host, eventually root | Steal the strategy; or trade the account | Management plane, monitoring agent, a dependency in `host/`, SSH | **The main external threat.** Root on the host ≈ root on the card |
| **Malicious insider** | Legitimate credentials, legitimate access, knows the design | Theft of strategy, or fraud | Direct — they already have it | **The most capable adversary in this model.** Assume competence |
| **Compromised vendor IP / toolchain** | Arbitrary logic inside encrypted IP or an implementation tool | Long-game, targeted | `.xci` cores, Vivado, container base image | Low probability, near-undetectable — see [02](02-supply-chain-and-bitstream-integrity.md) |
| **Careless / buggy deployment** | Full legitimate privilege, zero malice | None. It is a Tuesday | A rushed parameter change, wrong bitstream, a script with a typo | **Overwhelmingly the most likely cause of a catastrophic loss.** Treat it as an adversary |
| **A counterparty gaming us** | Observes our quotes; sends orders | Adverse selection, spoofing us into a bad print | The public market itself | Constant, ongoing, normal — a strategy problem, not a security one |

⚠️ **"Buggy deployment" belongs in the adversary list and people resist putting it
there.** Every control in this tier — four-eyes on limits, build-ID arming,
fail-closed reset, write-protected windows — is at least as effective against
mistakes as against malice, and mistakes are what will actually happen. If a
control only stops attackers and not accidents, it is a poor control for this
system.

---

## 4. ⚠️ The central observation: injection beats exfiltration

The reflex from general IT security is that the worst outcome is data theft. Here
it is not, and the difference is arithmetic.

**Exfiltration** — an adversary steals every parameter, the strategy source, and
the whole book implementation. The damage is competitive: the edge decays, and it
decays over weeks. It is a bad quarter. The firm exists on Monday.

**Injection** — an adversary (or a bug) causes the system to send orders. The
damage is realised at the speed of the machine, and the machine was purpose-built
to be the fastest thing in the building.

Work the numbers, because the intuition is useless:

```
10GbE, minimum-ish OUCH-over-SoupBin/TCP/IP/Ethernet frame ≈ 120 B on the wire
  + 20 B inter-frame gap and preamble
  → ~140 B/order → 10e9 / (140*8) ≈ 8.9 M orders/sec  (wire-rate bound)

At 100 shares × $100 = $10,000 notional per order:
  1 millisecond of unconstrained flow ≈ 8,900 orders ≈ $89 M notional
  250 ms — roughly one human blink — ≈ 2.2 M orders
```

*(Arithmetic, not a measurement. It is the wire bound; the fabric is single-issue
and slower, and `rtl/risk/rate_limiter.sv` is slower still by design. The point
is the order of magnitude of what is on the other side of that rate limiter.)*

Now the human side. A person notices an alert in ~1–3 s if they are watching,
5–60 s if they are not, and takes seconds more to act. **There is no human
response time that is fast enough.** The entire safety architecture of this
project follows from that one sentence:

| Because a human cannot react in time… | …the system has |
| --- | --- |
| The bound must be pre-set, not decided live | Per-symbol `sym_risk_t` limits, committed before arming |
| The bound must be in the same clock domain as the order | `rtl/risk/risk_gate.sv`, structurally non-bypassable |
| The stop must be automatic for known-bad conditions | `kill_src_e`: watchdog, msg-rate, position breach, link-down, seq-fault |
| The stop must be reachable without the host | External `ext_kill_n` GPIO, 3-FF CDC + 16-cycle debounce |
| The default must be "not trading" | Reset state = `KS_ARMED` (killed), limits zero, `HEARTBEAT_AGE = 0xFFFF` |

**Design consequence:** when you are choosing between a control that protects
secrets and a control that constrains order emission, and you can only build one
this quarter, build the second one.

---

## 5. Trust boundaries

```
  ┌─────────────────────── COLOCATION CAGE (physical boundary) ───────────────────────┐
  │                                                                                    │
  │   MD multicast ──▶ ⓐ ══▶ [ MAC RX │ net │ feed │ book │ strategy ]                 │
  │   (unauthenticated,      no credentials, no crypto, no backpressure                │
  │    public data)                             │                                      │
  │                                             ▼                                      │
  │                                    [ RISK GATE ] ◀── ⓒ ── risk_params (host)      │
  │                                             │                                      │
  │   OUCH/SoupBin  ◀── ⓑ ══════════════════════┴── [ order encode │ MAC TX ]          │
  │   (cleartext session login over a private cross-connect)                           │
  │                                             ▲                                      │
  │                                    ⓒ  PCIe BAR0 / DMA                              │
  │                                             │                                      │
  │                     ┌───────────────────────┴────────────────────┐                 │
  │                     │  TRADING HOST: ctrld, paramd, sessiond,     │                │
  │                     │  heartbeat, logd, reconciler, metricsd      │                │
  │                     └───────────────────────┬────────────────────┘                 │
  │                                             │ ⓓ                                    │
  └─────────────────────────────────────────────┼────────────────────────────────────--┘
                                                │
                        ⓔ build pipeline ───────┴─── management network, humans
```

| # | Boundary | What crosses it | What authenticates it today |
| --- | --- | --- | --- |
| ⓐ | Wire → fabric (market data) | ITCH/MoldUDP64 multicast | **Nothing.** Physical path only |
| ⓑ | Fabric → wire (order entry) | OUCH over SoupBinTCP/TCP | Session login at connect; per-message: nothing |
| ⓒ | Host → fabric (control plane) | BAR0 register writes, DMA rings | **Nothing in fabric.** Whoever can write the BAR *is* the operator |
| ⓓ | Network/humans → host | SSH, management agents, deploy tooling | OS-level auth — see [03-access-control-and-governance.md](03-access-control-and-governance.md) |
| ⓔ | Source → bitstream | RTL, IP, tools, constraints | Build-ID check; optionally bitstream signature — see [02](02-supply-chain-and-bitstream-integrity.md) |

⚠️ **Boundary ⓒ has no cryptographic authentication and cannot practically have
one.** The PCIe BAR is a memory window; the fabric answers whoever writes to it.
The two-step arm sequence (`arm_step1` then `arm_step2` as *separate* bus writes)
and the risk-window write protection are **anti-accident** controls, not
anti-adversary controls: an attacker with arbitrary write access performs two
writes as easily as one. Do not describe them to anyone as protection against a
compromised host. The real control at ⓒ is *who can execute code on the host*,
which is an operating-system problem, and *IOMMU configuration*, which is a
platform problem.

---

## 6. Threats by boundary

### ⓐ Market data injection / manipulation

| Threat | Mechanism | Consequence | Defence in this design |
| --- | --- | --- | --- |
| Forged ITCH messages | Attacker injects into the multicast group upstream of our port | Fabricated book → genuine order at a fabricated price | Price collars in `sym_risk_t`; A/B divergence detection; physical path integrity |
| Selective drop / delay of one feed | Attacker suppresses A, we run on B | Stale book, adverse selection | A/B gap counters and arbitration in `rtl/net/ab_arbiter.sv`; gap → degraded state |
| Replay of a real capture | Re-send yesterday's messages | Book diverges from reality | MoldUDP64 sequence continuity; `seq` regression counted, not accepted |
| Volume flood | Line-rate garbage | Drops — **not stalls** (`CLAUDE.md` §5.4) | RX never backpressures; drops counted and alertable |

⚠️ **We cannot authenticate the feed and neither can anyone else.** Exchange
market data multicast is not signed; the integrity control is that the path from
the exchange to your port is a physical cross-connect inside a controlled
facility. That makes physical and cross-connect integrity a *security* control,
not just a networking one. It also means the correct defensive posture is
**disbelief in the data**: price collars, sanity bands, and cross-feed divergence
detection are security controls as much as they are trading controls.
> **Verify:** whether your specific feed and any recovery/retransmission service
> offers integrity protection — check the current Nasdaq TotalView-ITCH and
> MoldUDP64/Glimpse specifications.

### ⓑ Order entry session

| Threat | Consequence | Defence |
| --- | --- | --- |
| Credential theft → attacker logs in as us | Orders under our MPID, our clearing, our liability | Credential handling in [03](03-access-control-and-governance.md); venue-side IP allow-listing |
| Session hijack / injection on the link | Same | Physical path; TCP sequence state owned by `sessiond` |
| Passive capture of the session | Sees our orders in real time | Physical path only |

> **Verify:** SoupBinTCP's login carries a username and password and the classic
> specification defines no transport encryption; confirm against the current
> Nasdaq SoupBinTCP and OUCH specifications and ask the venue what protections
> (TLS, IP restriction, port-level controls) are available on your ports.

### ⓒ Control plane

| Threat | Consequence | Detectable by |
| --- | --- | --- |
| Widen risk limits | Removes the bound on everything | `PARAM_GEN` generation counter; commit checksum; `LOG_PARAM_COMMIT` audit record |
| Write `fair_value` (unprotected window) | Steers strategy; all risk checks still pass | ⚠️ Only by host-side reconciliation of what `paramd` *believes* it wrote vs `FILTER_CMT_CHK`-style readback — build this |
| Clear the kill / re-arm | Restarts a system that was stopped for a reason | `KILL_COUNT`, `ARM_STATE`, audit ring |
| Suppress the audit ring (`LOG_CTRL.ring_en = 0`) | Blinds the investigation afterwards | `LOG_REC_CNT` stops advancing — alert on it |
| Stop the heartbeat | Trading halts (safe) | Watchdog → `KILL_WATCHDOG` |

Note the asymmetry: an attacker's *easiest* control-plane action (stop the
heartbeat) produces the *safest* outcome. That is not luck — it is what
fail-closed design buys you. See
[04-resilience-and-failure-isolation.md](04-resilience-and-failure-isolation.md).

### ⓓ / ⓔ Host and build

Covered in [03](03-access-control-and-governance.md) and
[02](02-supply-chain-and-bitstream-integrity.md) respectively.

---

## 7. Attack tree for the top threat

**Goal: cause the system to send orders we did not intend.**

```
Send unintended orders
├── (A) Corrupt the decision
│   ├── A1 forge market data on ⓐ ................ needs upstream network position
│   ├── A2 write strategy params at 0x300 ........ needs host code execution   ⚠️ soft
│   └── A3 corrupt the book (feed-handler bug) ... needs a latent RTL defect
├── (B) Bypass or widen the bound
│   ├── B1 widen risk limits at 0x200 ............ needs host code exec + trading disabled
│   ├── B2 corrupt the position counter .......... needs host code exec (position_loaded)
│   └── B3 ship a bitstream with a weakened gate . needs build-pipeline access   ⚠️ hardest to detect
├── (C) Prevent the stop
│   ├── C1 keep the heartbeat alive while doing A/B  needs host code exec
│   ├── C2 hold the card armed across an operator kill  ⚠️ not possible: kill is sticky in fabric
│   └── C3 make the operator not notice ......... suppress the audit ring / metrics
└── (D) Do it legitimately
    └── D1 an authorised human makes a mistake ... needs a Tuesday             ⚠️ most likely
```

Reading the tree:

- **Every branch except A1 and D1 requires code execution on the trading host.**
  Host hardening is therefore the single highest-leverage security investment,
  ahead of anything done in fabric.
- **B3 is the branch with no fabric-side detection.** If the risk gate itself is
  compromised at build time, no runtime register can tell you. That is why
  bitstream provenance is a separate document and why the build-ID check exists.
- **C2 is genuinely closed by the hardware.** `kill_active` latches and never
  self-clears — not on timeout, not on link-up, not when the trigger goes away
  ([`rtl/risk/kill_switch.sv`](../../rtl/risk/kill_switch.sv)). Re-arming needs a
  deliberate two-step sequence with all triggers clear and a reconciled position
  loaded. This is one of the few places where fabric beats an attacker outright.
- **D1 dominates the probability mass.** Design accordingly.

---

## 8. Explicitly out of scope

Saying what you are *not* defending against is what makes the rest credible.

| Not defended | Why | Compensating control |
| --- | --- | --- |
| A nation-state with physical access to the card | Undefendable at our scale | Facility access control, tamper-evident seals |
| A malicious FPGA vendor | Undefendable | Vendor selection; multi-family portability keeps the option open |
| A compromised exchange matching engine | Not our trust boundary | Drop-copy reconciliation catches divergence |
| Confidentiality of order flow on the cross-connect | Physically constrained path; no venue-supported alternative | Accept and document |
| Side-channel extraction of parameters from the card | Cost/benefit | Physical access control |
| Denial of service by the market itself (a fast market) | It is the market | Rate limits, position limits |

---

## 9. RULES FOR THIS PROJECT

1. **Rank integrity of order flow above confidentiality, always.** If a proposed
   control trades one for the other, order-flow integrity wins.
2. **Any change that could increase the number, size, or price aggressiveness of
   emitted orders is a security change** and is reviewed as one — including
   "just a parameter".
3. **Treat host code execution as equivalent to full control of the card.** Do not
   claim fabric-side controls defend against it. Write the host-hardening
   requirement down instead.
4. **The strategy parameter window is a security surface.** `paramd` must read
   back and verify every committed strategy window, and telemetry must alarm on
   any generation counter that advanced without a corresponding `paramd` intent
   record.
5. **Physical and cross-connect integrity are security controls.** Record them in
   the control inventory alongside the software ones.
6. **Every new external input gets a row in §6 before it gets RTL.** A new feed, a
   new drop copy, a new management interface — model it, then build it.
7. **Re-review this model when any trust boundary moves**: a new venue, a second
   card, a remote management path, a cloud build runner, DFX, or any host process
   gaining write access to a control window it did not previously have.
8. **The model is reviewed at least annually and after every incident**, and the
   review is recorded. An un-reviewed threat model describes a system that no
   longer exists.

---

## Further reading

- [02-supply-chain-and-bitstream-integrity.md](02-supply-chain-and-bitstream-integrity.md) — branch B3 of the attack tree
- [03-access-control-and-governance.md](03-access-control-and-governance.md) — branches B1, D1, and boundary ⓓ
- [04-resilience-and-failure-isolation.md](04-resilience-and-failure-isolation.md) — what happens when a component fails rather than is attacked
- [05-incident-preparedness.md](05-incident-preparedness.md) — what you do when this document turns out to have been right
- [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md) — the regulatory framing of the same controls
- [../08-nasdaq/09-risk-controls-and-limits.md](../08-nasdaq/09-risk-controls-and-limits.md) — the implementable limit specification
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — structural non-bypassability of the risk gate
