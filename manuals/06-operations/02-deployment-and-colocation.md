# 06.02 — Deployment and Colocation

> **Why this matters here:** you can win 200 ns in the fabric with three weeks of
> pipelining work, and lose 400 ns by accepting a longer fibre run, the wrong PCIe
> slot, or a switch hop you didn't need. The physical deployment is part of the
> latency budget, and it is the part that is hardest to change once the cage is
> built. It is also where the compliance obligations become concrete: a build that
> has not passed venue conformance does not point at a live venue.

---

## 1. Why you are in the building

Market data leaves the matching engine and propagates outward. Everything between
the exchange's matching engine and your FPGA is latency you pay on **every tick**,
and everything between your FPGA and the exchange's gateway is latency you pay on
**every order**. Both directions are pure distance and equipment.

```
matching engine ── exchange internal fabric ── colo cross-connect ── your rack
                                                      ▲
                                    this is the only segment you control,
                                    and only by choosing cable length and optics
```

At ~5 ns per metre of fibre, being 100 m further from the handoff costs ~500 ns
each way — more than the entire target tick-to-trade budget for this project. That
is why colocation is not optional for a strategy in this latency class.

| Colo concept | What it means for us |
| --- | --- |
| **Cage / cabinet** | Your locked physical space. Rack units, power feeds (usually A/B redundant), and a demarcation point for cross-connects. |
| **Power** | Provisioned in kW per cabinet. An FPGA accelerator card plus a dense server is a meaningful draw; confirm the cabinet budget before buying hardware. |
| **Cross-connect** | A physical fibre run from your cage to the exchange's distribution, ordered per port, per direction, per service. |
| **Cable length** | A **latency variable you pay for monthly**. Measure it; do not assume the ordered length is the installed length. |

> **Verify:** Nasdaq's US equities matching engine and colocation facility have been
> associated with **Carteret, New Jersey**. Facility location, colocation product
> tiers, cross-connect ordering and any announced data-centre migration must be
> confirmed against current **Nasdaq colocation documentation and trader alerts** —
> do not design a cabling plan from this manual.

---

## 2. Cross-connects and the fairness question

You typically order at least these, each redundantly:

| Connection | Direction | Notes |
| --- | --- | --- |
| Market data multicast handoff (A feed) | Exchange → you | TotalView-ITCH over MoldUDP64 multicast |
| Market data multicast handoff (B feed) | Exchange → you | Independent path; arbitrated in fabric — see [../02-networking/03-multicast-feeds-and-arbitration.md](../02-networking/03-multicast-feeds-and-arbitration.md) |
| Order entry (primary) | You ↔ exchange | OUCH over SoupBinTCP; TCP, so a real session with state |
| Order entry (backup) | You ↔ exchange | Separate port, often separate gateway |
| Drop copy | Exchange → you | Independent view of your fills for reconciliation |
| Retransmission / snapshot | You ↔ exchange | MoldUDP64 request server; GLIMPSE for a book snapshot |

> **Verify:** the exact set of ports, protocols and services (MoldUDP64
> retransmission, GLIMPSE snapshot, drop copy availability, port fee structure) is
> defined by **Nasdaq TotalView-ITCH 5.0**, **OUCH 5.0**, **SoupBinTCP** and
> **MoldUDP64** specifications plus the current Nasdaq colocation service
> description. Take the port list from your onboarding paperwork, not from here.

### Standardized cable lengths

Major exchanges normalize the physical path so that every colocated participant's
cable length to the handoff is the same regardless of where their cage sits in the
building. The intent is that rack position confers no advantage.

**Consequences for us:**

- Do not spend engineering effort trying to buy a shorter cross-connect. That
  variable has been removed.
- The latency you *can* still control is **inside your cage**: the run from the
  patch panel to your card, the presence or absence of a switch hop, and the optics.
- ⚠️ Length equalization typically applies to the exchange-provided segment.
  Your intra-cage cabling is yours to get wrong. A sloppy 15 m intra-rack run
  instead of a 2 m one is ~65 ns you gave away for free.

> **Verify:** whether and how cable-length equalization applies at your specific
> facility and product tier is a **venue policy** question — confirm in writing
> with Nasdaq colocation before making design assumptions about it.

---

## 3. Server, card, and slot

| Choice | Guidance | Why |
| --- | --- | --- |
| Chassis | Short-depth, high-airflow, single-socket preferred | Simpler NUMA story; less thermal recirculation |
| CPU | High single-thread clock over core count | The slow path is latency-sensitive, not parallel |
| FPGA card | UltraScale+ class with front-panel SFP28/QSFP cages | Network must terminate **on the card**, not on a separate NIC |
| PCIe slot | Directly attached to the CPU that runs the host process — **not** behind a PLX/PCIe switch | A switch adds hundreds of ns to MMIO reads and DMA completion |
| Lanes | Full x16 electrical, not an x16 slot wired x4 | Silent bandwidth cliff; verify with `lspci -vv` |
| NUMA | Host control process pinned to the same node as the card's root port | Cross-socket DMA and MMIO cost real time |
| BIOS | C-states off, P-states pinned, turbo behaviour fixed, hyper-threading off on the critical core | Determinism in the slow path |

```bash
# Confirm the card's actual link width/speed and NUMA node
lspci -vvv -s <bdf> | grep -E 'LnkCap|LnkSta|NUMA'
cat /sys/bus/pci/devices/<bdf>/numa_node
# Pin the control process
numactl --cpunodebind=0 --membind=0 ./host/trading_ctl
```

⚠️ `LnkSta` showing `Width x8` on an x16 card is the single most common silent
deployment fault. It will not break anything — it will just quietly halve your DMA
bandwidth and change your telemetry cadence.

---

## 4. Optics and transceivers

| Type | Reach | Typical use here | Notes |
| --- | --- | --- | --- |
| Direct-attach copper (DAC) | ~1–7 m | Intra-rack, host ↔ your own switch | Lowest cost, no optical conversion, ~4.3 ns/m |
| SR (short reach, multimode) | ~ up to 300 m at 10G on OM3-class fibre | Standard in-building cross-connect | Cheap, ubiquitous |
| LR (long reach, single-mode) | ~ up to 10 km | Cross-building, some venue handoffs | Required if the venue hands off single-mode |
| Active optical cable (AOC) | ~ up to 30 m | Occasionally used intra-cage | Fixed length, no field termination |

> **Verify:** reach figures come from the relevant **IEEE 802.3** clauses
> (10GBASE-SR/LR, 25GBASE-SR/LR) and the specific transceiver datasheet. Optic
> latency is a **vendor datasheet** number, not a standard, and is usually only a
> few nanoseconds.

> ⚠️ **Optic choice affects latency slightly and reliability enormously.** The
> latency delta between two compliant 10G optics is small — single-digit
> nanoseconds. But a marginal, mismatched, or dirty optic produces intermittent CRC
> errors, link flaps mid-session, and FEC-corrected errors that hide themselves
> until they don't. Buy venue-compatible optics, keep spares of the exact same
> part number in the cage, monitor RX power and CRC error counters continuously
> (see [03-monitoring-and-telemetry.md](03-monitoring-and-telemetry.md)), and clean
> every connector before insertion. Most "mysterious latency spikes" are a dirty
> LC connector.

### Cable management and measuring your real lengths

- Label both ends of every fibre with source, destination, and **measured** length.
- Use an OTDR or the switch/optic's own diagnostics to measure the installed
  length. Ordered length ≠ installed length ≠ optical path length.
- Record the measured lengths in `docs/` and convert them into the latency budget
  spreadsheet. Fibre delay belongs in the budget explicitly, not as a rounding
  error. See [../05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md).
- Slack loops matter: 10 m of "tidy" coiled slack is ~50 ns each way.
- Do not route the fast-path fibre through a patch panel you don't need.

---

## 5. Time: PTP, GPS, and why grandmaster quality matters

You need accurate time for three distinct reasons, with different tolerances:

| Purpose | Needed accuracy | Consequence of being wrong |
| --- | --- | --- |
| **Your own latency measurement** | Sub-100 ns, and above all *stable* | You cannot attribute a 300 ns regression if your clock wanders by 1 µs |
| **Regulatory event timestamping (CAT)** | Regulator-defined tolerance to NIST | Reportable-event timestamps out of tolerance; a compliance finding |
| **Cross-venue / cross-host correlation** | Sub-µs | Post-trade analysis becomes guesswork |

**Architecture for this project:**

```
GNSS antenna (roof/riser) ──► GPS-disciplined PTP grandmaster (in cage)
                                     │  IEEE 1588 PTP over dedicated Ethernet
                                     ▼
                    ┌────────────────┴────────────────┐
             FPGA card PTP servo               host NIC / kernel PHC
             (drives the fabric                (drives host software
              timestamp counter)                 timestamps + logs)
```

- **The FPGA holds the authoritative timestamp for the fast path.** Timestamp on
  ingress at the MAC boundary and on egress at the MAC boundary; the difference is
  your wire-to-wire number and it does not depend on the host clock at all.
- Discipline the fabric counter to PTP so those hardware timestamps are also
  meaningful in absolute terms for logs and CAT.
- Grandmaster quality (holdover oscillator: TCXO vs OCXO vs Rb) determines what
  happens when GNSS drops. A cheap grandmaster in holdover drifts fast enough to
  break both your measurements and your reporting tolerance.
- Monitor the servo: offset-from-master, path delay, and **time since last GNSS
  lock**, as first-class alerting metrics.

> **Verify:** PTP behaviour and profiles are defined by **IEEE 1588-2008 / 1588-2019**.
> US equities clock-synchronization obligations for CAT reportable events derive
> from the **CAT NMS Plan (SEC Rule 613)** and **FINRA Rule 4590**; the commonly
> cited tolerance for Industry Members has been within **50 ms of NIST**, with
> tighter requirements proposed/applied for certain automated systems. The EU
> analogue (**MiFID II RTS 25**) is far tighter (100 µs class) but does not apply
> to US-only trading. **Confirm current applicable tolerances with compliance —
> do not take the number from this manual.**

---

## 6. Environment: heat is a timing variable

Silicon gets slower as it gets hotter. The tools sign off timing at a specified
temperature corner; run the die above it and your closed design is no longer
closed — it becomes an intermittent, temperature-correlated data corruption bug.

| Control | Target | Monitoring |
| --- | --- | --- |
| Cage inlet air temperature | Per facility SLA; hot-aisle/cold-aisle containment respected | Rack sensor → alert |
| FPGA die temperature | Well inside the part's operating range for the sign-off corner | On-die sensor (SYSMON/XADC) polled by the host → alert with two thresholds: warn and kill |
| Airflow | Blanking panels fitted, no recirculation, card fan/heatsink orientation matches chassis flow | Fan-speed telemetry |
| Power draw | Within cabinet budget with headroom for both feeds | PDU telemetry |

> **Verify:** operating temperature ranges and the temperature corners used for
> timing sign-off are part-specific — check the device data sheet and the
> `report_power` / SYSMON documentation for your exact device. Thermal derating
> behaviour is discussed in
> [../05-optimization/03-resource-power-optimization.md](../05-optimization/03-resource-power-optimization.md).

⚠️ A design at WNS = +0.02 ns in the report has essentially no thermal margin.
Treat thin WNS as a *deployment* risk, not only a build risk.

---

## 7. Venue onboarding and conformance testing

**Hard rule for this project: no build points at a live venue session until
conformance for that protocol version is complete and documented.** This is
restated from `CLAUDE.md` §6 because this is the document where it gets violated.

Typical onboarding path for Nasdaq US equities:

| Stage | What happens |
| --- | --- |
| 1. Commercial / membership | Membership or sponsored access through a broker-dealer; MPID assignment; market data agreements and reporting |
| 2. Connectivity | Colocation space, cross-connect orders, port provisioning (order entry, market data, drop copy) |
| 3. Test environment access | Credentials for the exchange test facility; separate IPs, ports, and session credentials from production |
| 4. **Conformance / certification** | Exchange-driven test script exercising your order-entry implementation |
| 5. Sign-off | Venue issues confirmation; you record it in `docs/` alongside the bitstream version tested |
| 6. Production enablement | Production credentials issued; canary rollout begins (§9) |

**What conformance typically covers** (order-entry side is the strict part):

- Session layer: login, sequence numbering, heartbeat behaviour, logout, reconnect
  and replay after disconnect.
- Message construction: every field, correct types, correct padding, correct
  lengths, correct ASCII/binary encoding.
- Order lifecycle: new, replace, cancel, and the ack/reject/fill responses for each.
- Error handling: how you respond to a reject, an out-of-sequence message, an
  unknown message type, a session drop mid-order.
- Behaviour under mandated conditions: halts, LULD bands, self-match prevention if
  used, cancel-on-disconnect settings.

> **Verify:** the conformance/certification requirement, its scope, the test
> facility name and hours, and whether re-certification is required after a
> protocol-affecting change are all defined by **Nasdaq**, not by us. Get the
> current certification guide from Nasdaq and treat it as authoritative over
> anything in these manuals.

**Our rule on re-certification:** any change to the OUCH encoder, the SoupBinTCP
session logic, or the risk gate's reject behaviour triggers a re-certification
question to the venue *before* the release is scheduled — not after.

### Environment separation

| Environment | Feed | Order entry | Risk limits | Purpose |
| --- | --- | --- | --- | --- |
| **Lab** | Recorded pcap replay from a traffic generator or second FPGA | Loopback / simulated venue | Deliberately tiny | Development, HIL, fault injection |
| **UAT / venue test** | Exchange test feed | Exchange test gateway | Small but realistic | Conformance, integration, rehearsals |
| **Production** | Live TotalView-ITCH | Live OUCH | Real, approved limits | Trading |

⚠️ The credentials, IPs, and multicast groups for these three must live in
**separate config files with separate loaders**, and the production file must be
the only one that requires an explicit, logged, two-person action to load. Never
put a production endpoint in a default, a fallback, or a test fixture.

---

## 8. Deployment runbook

Run in order. Every step has a verification. A step whose verification fails stops
the deployment; it does not get "carried forward".

```
 1. PRE-FLIGHT
    - Confirm the release passed §8 of 01-build-and-release.md.
    - Confirm the rollback bitstream is on local disk; verify its SHA256.
    - Confirm market is closed or the symbol set is not trading.
    - Announce the change in the ops channel; name the operator on point.

 2. LOAD BITSTREAM
    - Program the device from the release .bit (SHA256 verified before load).
    - Reset/re-enumerate PCIe as required by the card; confirm the device
      re-appears with the expected BDF and link width.

 3. VERIFY BUILD ID
    - Read BAR0 build-ID block. Magic == "FTRA", git SHA, build timestamp,
      seed, constraint CRC.
    - MUST equal the expected values in host config. Mismatch → abort, roll back.

 4. LOAD SYMBOL TABLE
    - Push the day's symbol universe (locates, tick sizes, reference prices).
    - Read back and compare a checksum computed in fabric against the host's.

 5. LOAD PARAMETERS
    - Strategy thresholds, sizes, enable bits — all disabled at this point.
    - Read back and verify every word. Do not trust a write.

 6. VERIFY RISK LIMITS
    - Load limits (max order qty, max notional, max position, max messages/sec,
      price collar, symbol whitelist).
    - Read back and verify.
    - Inject deliberately over-limit test orders into the loopback path and
      confirm each is REJECTED with the correct reason code, and that the
      per-reason rejection counter incremented. One test per limit.
    - This step is not optional and is not "we tested it in UAT".

 7. VERIFY KILL SWITCH
    - Arm the loopback path, generate order flow, assert the kill switch,
      confirm outbound flow stops within the documented cycle bound and that
      the kill-switch counter incremented.
    - Confirm the kill switch is reachable from BOTH the host process and the
      out-of-band path (see §10).

 8. CONNECT SESSIONS
    - Join market data multicast groups (A and B). Confirm frames arriving on
      both, sequence numbers advancing, zero gaps for a settling period.
    - Log in to OUCH/SoupBinTCP. Confirm login accepted and sequence state
      matches expectation.
    - Confirm drop-copy session is up.

 9. VERIFY BOOK
    - Compare the fabric's top-of-book for a set of reference symbols against
      an independent software book built from the same feed. They must agree.

10. ARM
    - Enable the risk gate's ARM bit. Log who armed it and when.

11. CANARY
    - Enable exactly one symbol, minimum size, tightest limits. See §9.
```

---

## 9. Staged rollout: the single-symbol canary

Never enable a new bitstream across the full universe at once.

| Stage | Scope | Duration | Graduation criteria |
| --- | --- | --- | --- |
| **Canary** | 1 liquid, well-understood symbol; minimum order size; tightest risk limits | ≥ 1 full trading session | Zero unexpected rejects; fills reconcile exactly with drop copy; measured latency within budget; zero sequence gaps attributable to us; book matches software model all session |
| **Cohort** | 5–20 symbols spanning liquidity profiles | 2–3 sessions | As above, plus no counter anomalies, no thermal drift, position reconciliation clean at EOD |
| **Full** | Production universe | — | Sign-off from trading + engineering |

**Canary rules:**
- The canary's risk limits are sized so that a *complete* logic failure costs an
  acceptable, pre-agreed amount. Write that number down before you start.
- Someone watches it live. A canary nobody is watching is just production.
- Any single unexplained event — one reject with an unexpected reason, one
  mismatch against the software book — resets the clock. "Probably fine" is not a
  graduation criterion.

---

## 10. Disaster recovery and failover

| Failure | Detection | Response |
| --- | --- | --- |
| Market data A feed down | Per-feed frame counter stops; gap counter climbs | Fabric arbitration already runs on B alone; alert, do not stop trading |
| **Both** feeds down / gap unrecoverable | Both counters stall or gaps exceed threshold | **Auto-flatten policy applies**: stop quoting, cancel resting orders. A stale book is more dangerous than no book. |
| Order-entry session drop | TCP state change, heartbeat miss | Rely on venue **cancel-on-disconnect** *and* reconnect and explicitly verify resting order state. Never assume. |
| FPGA card fault (link down, temp, CRC storm) | Health register / SYSMON | Kill switch, flatten, roll to standby host |
| Host process death | Watchdog in fabric stops seeing the host heartbeat | **Fabric must fail safe on its own**: after N missed heartbeats, the risk gate blocks new orders. This behaviour is designed in, not bolted on. |
| Power feed loss (one of A/B) | PDU telemetry | Alert; confirm the other feed carries the load |
| Whole-site event | Exchange notices, connectivity loss | Documented business-continuity procedure; know how you cancel orders when your primary path is gone |

> **Verify:** business-continuity and emergency-cancel expectations for
> broker-dealers are shaped by rules such as **FINRA Rule 4370** (business
> continuity plans) and the venue's own emergency procedures (e.g. a phone-based
> "cancel all my orders" desk). Confirm the exact escalation path and phone number
> with the venue and your clearing firm, and keep it printed in the cage.

**Standing rules:**
- The out-of-band kill path (a separate, low-tech way to stop order flow that does
  not depend on the main host process being healthy) is tested quarterly.
- Failover to a standby host is a rehearsed procedure with a written runbook, not
  an improvisation.
- Losing money safely is always preferable to trading on state you cannot trust.

---

## Further reading

- [01-build-and-release.md](01-build-and-release.md) — what must be true before a bitstream reaches step 2 of the runbook
- [03-monitoring-and-telemetry.md](03-monitoring-and-telemetry.md) — the counters and alerts referenced throughout
- [04-testing-strategy.md](04-testing-strategy.md) — conformance, HIL, and canary testing in detail
- [../02-networking/03-multicast-feeds-and-arbitration.md](../02-networking/03-multicast-feeds-and-arbitration.md) — A/B feed handling
- [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md) — the regulatory frame
- [../05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md) — where cable and optic delay enter the budget
- [../07-reference/02-latency-reference-numbers.md](../07-reference/02-latency-reference-numbers.md) — metres-to-nanoseconds tables
