# 08.08 — Connectivity and Colocation (Nasdaq US Equities)

> **Why this matters here:** a sub-microsecond tick-to-trade path is worthless if the
> packet spent 400 µs crossing New Jersey before it reached your FPGA. Physical
> proximity, handoff type, cross-connect length, port allocation, and clock
> distribution are all part of the latency budget — and unlike your RTL, most of them
> are procurement decisions with lead times measured in weeks. This document is the
> part of the design that you cannot fix in a rebuild.

---

## 1. Nasdaq colocation at Carteret, NJ

Nasdaq's US equities matching engines run in its primary data center in
**Carteret, New Jersey**. Colocation means renting space in that building so your
server sits meters from the matching engine rather than kilometres.

### What you actually rent

| Item | Unit | Notes |
| --- | --- | --- |
| **Cabinet space** | Per cabinet (or partial cabinet), per month | Sized by rack units and, more often, by power |
| **Power** | Per kW committed, per month | Frequently the *binding* constraint, not space. FPGA cards and low-latency switches are power-hungry |
| **Cross-connects** | Per connection, per month | Fibre from your cabinet to the Nasdaq handoff point |
| **Handoff ports** | Per port, per month, by speed | The exchange-side interface — see §3 |
| **Remote hands** | Per incident / per hour | Someone else's hands, because they will be the only hands |

> **Verify:** cabinet sizes, power tiers, cross-connect pricing, and availability in
> the **Nasdaq colocation service description** and the connectivity sections of the
> **Nasdaq Equity Rulebook** (listingcenter.nasdaq.com / nasdaq.cchwallstreet.com).
> Colocation fees are filed with the SEC and change by rule filing.

### The fairness principle: standardized cable lengths

This surprises people who assume colocation is a race to the nearest cabinet.

> **Nasdaq equalises the physical path length from every colocation cabinet to the
> matching engine handoff**, by using standardized-length cables — cabinets that are
> physically closer get the same length of fibre, coiled, as cabinets that are further
> away.

The regulatory rationale is fair access: colocation is a service filed with the SEC,
and a service that gave a latency advantage to whoever secured a particular cabinet
would be difficult to justify as fair and non-discriminatory.

**The design consequence is large and positive:** you do not need to negotiate for a
specific cabinet, and you should be suspicious of any vendor claiming they can get
you a "closer" one. Your latency differentiators are:

1. Your own hardware (the whole point of this project).
2. Your handoff type and its FEC behaviour (§3).
3. Your internal cabling and any switch hops you insert *inside* your own cage.
4. Whether you are in Carteret at all.

> ⚠️ **Every switch you put between the Nasdaq handoff and your FPGA costs you.** A
> cut-through switch hop is tens to hundreds of nanoseconds — comparable to your
> entire logic budget. The ideal topology is **handoff → optic → FPGA**, with the
> feed replicated by a layer-1 device only if genuinely required. See
> [../02-networking/04-nics-kernel-bypass-and-switching.md](../02-networking/04-nics-kernel-bypass-and-switching.md).

> **Verify:** the current standardized-cabling policy in the Nasdaq colocation service
> description. Treat it as a policy that could change, and re-read it at renewal.

---

## 2. Connectivity options

You do not have to be in Carteret to trade Nasdaq. You do have to be in Carteret to
trade Nasdaq *competitively*.

| Option | What it is | Latency | Cost | Complexity | Fit |
| --- | --- | --- | --- | --- | --- |
| **Colo cross-connect** | Your cabinet in Carteret, fibre direct to Nasdaq handoff | **Lowest.** Metres of fibre, no intermediate hops | Highest fixed (cabinet + power + cross-connects + ports) | High: you own the hardware, the spares, the ops | **The only option for this project** |
| **Extranet / service provider** | A telecom or market-data provider aggregates connectivity and resells it | Adds provider hops + the distance from their POP; typically tens of µs to milliseconds | Moderate, mostly opex | Low: they own the plumbing | Research, mid-frequency, backup path |
| **Sponsored access via a broker** | You trade under a broker-dealer's membership and MPID, using their connectivity | Depends entirely on where the BD's infrastructure sits — can be colo-grade | Lower barrier; you pay the BD | Low technically, **high** legally (see §6) | Common for new firms; often the *legal* structure even when the connectivity is your own |
| **Remote / office connectivity** | Internet or private line from anywhere | Milliseconds | Lowest | Lowest | Development, monitoring, never trading |

> ⚠️ **These are not mutually exclusive, and the common real-world arrangement is a
> hybrid**: your own FPGA in your own cabinet in Carteret, cross-connected to Nasdaq,
> but sending orders under a sponsoring broker-dealer's MPID with the BD's 15c3-5
> controls in the path. The *physical* and the *legal* architectures are separate
> questions and are frequently answered differently. Settle both explicitly.

---

## 3. Handoff types and speeds

| Handoff | Typical use | FEC | Latency character |
| --- | --- | --- | --- |
| **1G** | Legacy, low-rate order entry, admin | None | Fine for control paths; too slow for depth-of-book data |
| **10G** | The low-latency workhorse | **No FEC** in 10GBASE-R | ~50–150 ns each way through PCS/PMA. Predictable |
| **25G** | Higher bandwidth | **RS-FEC (Clause 91) by default**; "no-FEC" and Base-R FEC modes exist and must be negotiated/configured | RS-FEC adds a real, fixed latency penalty — often **~100 ns or more each way** |
| **40G** | 4 × 10G lanes | None (as 40GBASE-R) | Bandwidth without the 25G FEC penalty, at the cost of 4 lanes |
| **100G** | Aggregation, data delivery | RS-FEC | Rarely on the order-entry critical path |

> ⚠️ **A faster handoff is not automatically a lower-latency handoff.** Moving from
> 10G to 25G reduces *serialization* time (fewer nanoseconds per byte on the wire)
> but adds *RS-FEC* latency in the PCS, which is a fixed cost paid on every frame in
> both directions. For a small ITCH message or a 47-byte OUCH order, the serialization
> saving is small and the FEC penalty can dominate — **25G with RS-FEC can be slower
> end-to-end than 10G for short messages.**
>
> The decision requires: (a) knowing whether the venue and your optics support a
> no-FEC or low-latency-FEC mode, and (b) *measuring*, not assuming. See
> [../01-fpga-design/04-io-transceivers-and-serdes.md](../01-fpga-design/04-io-transceivers-and-serdes.md)
> and [../02-networking/01-ethernet-phy-mac.md](../02-networking/01-ethernet-phy-mac.md).

```
    Short-message latency ≈  serialization  +  PCS/PMA  +  FEC  +  MAC

    64-byte frame @ 10G:   ~51 ns serialization,  no FEC
    64-byte frame @ 25G:   ~20 ns serialization,  + RS-FEC (~100 ns class)

    → For SHORT messages, 10G can win. For BULK data, 25G wins easily.
```

**Practical split used by many firms:** high-bandwidth market data on the faster
handoff (where throughput matters and a fixed FEC offset is acceptable and equal for
everyone), and order entry on the lowest-latency handoff available.

> **Verify:** available handoff speeds, FEC options, and the per-port pricing in the
> *Nasdaq Price List* and the connectivity service descriptions. Then measure it on
> your own hardware with a loopback and a hardware timestamper —
> [../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md).

---

## 4. Market data delivery

### The shape of it

Nasdaq TotalView-ITCH is delivered in colocation as **UDP multicast**, framed in
**MoldUDP64**, with:

| Element | Purpose |
| --- | --- |
| **A/B feeds** | Two independent, identical multicast streams on separate multicast groups and (ideally) separate physical paths. Arbitrate between them to fill gaps |
| **Channels / groups** | The product is split across multiple multicast groups, typically by symbol range, so a subscriber can take a subset |
| **Retransmission service** | Request a specific missed sequence range (unicast, request/response) |
| **Glimpse** | TCP snapshot service to build the initial book state or recover after a large gap |

Message-level detail is in [04-totalview-itch-5.0.md](04-totalview-itch-5.0.md);
gap-detection and A/B arbitration design is in
[../02-networking/03-multicast-feeds-and-arbitration.md](../02-networking/03-multicast-feeds-and-arbitration.md).

> **Verify:** the actual multicast group addresses, ports, channel-to-symbol mapping,
> and which products ride which groups from the **Nasdaq data feed connectivity
> specifications on nasdaqtrader.com**. These are published, they change (symbol ranges
> get rebalanced), and changes are announced via **Nasdaq Equity Trader Alerts**.

> ⚠️ **Subscribe to Nasdaq Equity Trader Alerts and route them to a human who reads
> them.** Multicast group changes, symbol-range rebalances, protocol version rollouts,
> and testing windows are announced there. A feed handler that hardcodes group
> membership and misses an alert goes deaf at 09:30 on a Monday.

### The multi-market consequence

Nasdaq, Nasdaq BX, and Nasdaq PSX are **separate markets with separate books,
separate ITCH feeds, separate multicast groups, and separate order-entry sessions.**

| Consequence | Detail |
| --- | --- |
| Feeds | Three ITCH decoders (or one parameterised decoder × three instances) |
| Multicast groups | Three sets of groups; three sets of A/B arbitration state |
| Books | Three books, or one book keyed by (venue, symbol) |
| Sequence-gap state | Per venue, per channel — never shared |
| Ports and fees | Separate market-data ports per market — see [07-fees-rebates-and-economics.md](07-fees-rebates-and-economics.md) §5 |
| Symbol locate codes | ⚠️ **`stock locate` is per-feed and is NOT the same integer across BX/PSX/Nasdaq.** Maintain a per-venue locate → internal-symbol-index translation |

> ⚠️ That last row is a classic silent bug: `stock locate` 1234 on Nasdaq and 1234 on
> BX are different symbols. A design that uses the locate code as a global index will
> corrupt books across venues in a way that looks like intermittent bad data.

### FPGA resource consequence

Three markets × (A + B) feeds is **six multicast receive streams** to arbitrate at
line rate, plus whatever other venues you consume. This drives:

- **Buffer sizing** in the feed handler (gap window depth per stream).
- **Port count** on the FPGA's transceivers.
- Whether you need one card or several, and therefore whether you need PCIe
  peer-to-peer or a fabric interconnect between cards.

Size this before choosing the card. See
[../04-system-architecture/02-feed-handler-design.md](../04-system-architecture/02-feed-handler-design.md).

---

## 5. Order entry ports and MPIDs

### Ports

An order-entry **port** is a logical session endpoint on the exchange side. For
OUCH ([05-ouch-5.0-order-entry.md](05-ouch-5.0-order-entry.md)) each port is a TCP
session with its own SoupBinTCP sequence space, its own login, and its own throttle.

| Property | Implication |
| --- | --- |
| **Per-port, per-month fee** | Port count is a real recurring cost line |
| **Per-port message-rate throttle** | The exchange rate-limits per port; exceeding it gets messages queued or the session disciplined |
| **Per-port sequencing** | Each session has independent inbound/outbound sequence numbers; recovery is per-session |
| **Cancel-on-disconnect** | Behaviour on session loss is configured per port — know your setting |

**The multi-port strategy.** You want more than one port for reasons that have
nothing to do with capacity:

| Reason | Detail |
| --- | --- |
| **Rate headroom** | Spread message flow across ports so no single port approaches its throttle. Throttle breaches are an operational incident and can look like a control failure |
| **Redundancy** | A port session drop must not stop trading. A second live port takes over |
| **Blast-radius isolation** | Strategy A's message storm should not throttle strategy B's cancels |
| **⚠️ A dedicated cancel/flatten path** | Reserve a port that carries **only** cancels and risk-reducing orders, and never carries new-order flow. When you most need to cancel, the other ports are exactly the ones that are congested |
| **Attribution** | Ports can be tied to MPIDs and strategies for reporting |

> ⚠️ **The dedicated cancel port is not optional in a serious design.** The failure
> mode it protects against — "we could not cancel because our own order flow filled
> the pipe" — is one of the classic runaway-algorithm incident narratives.

> **Verify:** current per-port fees, the published rate limits per port type, and
> cancel-on-disconnect configuration options in the *Nasdaq Price List* and the
> Nasdaq order-entry specifications on nasdaqtrader.com.

### MPIDs

An **MPID** (Market Participant Identifier) is the 4-character identifier under which
your orders are entered and reported.

| Use | Detail |
| --- | --- |
| **Identity** | Who the exchange, the tape, and the regulator think entered the order |
| **Strategy separation** | Different MPIDs for different strategies or desks, so reporting, surveillance, and P&L attribution are clean |
| **⚠️ Self-match prevention scope** | SMP groups are configured relative to MPIDs. **Splitting strategies across MPIDs without configuring cross-MPID SMP creates a wash-trade exposure** — see [06-regnms-and-compliance.md](06-regnms-and-compliance.md) §10.2 |
| **Tier attribution** | Whether volume is aggregated across your MPIDs for fee-tier qualification is a *rule* detail with real money attached — see [07-fees-rebates-and-economics.md](07-fees-rebates-and-economics.md) §3 |
| **Market-maker registration** | Quoting obligations attach to a registered market-maker MPID in a symbol |

> ⚠️ **MPID structure is a compliance and economics decision disguised as an
> operations detail.** Decide it with compliance and with whoever owns the fee model,
> before the first session is provisioned. Changing it later means re-papering
> agreements, re-configuring SMP, and re-baselining tier history.

---

## 6. Sponsored access and the DMA arrangement

Almost every proprietary trading firm either **is** a broker-dealer or **trades
through one**.

```
   ┌────────────────────┐        ┌──────────────────────┐        ┌──────────┐
   │  Your FPGA system  │───────▶│  Broker-Dealer with  │───────▶│  Nasdaq  │
   │  (in Carteret)     │        │  Nasdaq membership   │        │          │
   └────────────────────┘        │  + MPID + 15c3-5     │        └──────────┘
                                 │    controls          │
                                 └──────────────────────┘
```

The critical point: **"market access" is a legal concept, not a network one.** The
member broker-dealer whose MPID appears on the order is the one with the SEC Rule
15c3-5 obligation, regardless of whose hardware the packet came out of.

| Arrangement | Who holds the 15c3-5 obligation | What must be true |
| --- | --- | --- |
| You are the BD, own the membership | You | Your controls, your exclusive control, your CEO certification |
| Sponsored access through a BD | **The sponsoring BD** | The BD's controls must be applied **pre-trade** and be under the **BD's direct and exclusive control** |
| Sponsored access, controls in *your* FPGA | Still the sponsoring BD | Requires a documented arrangement; the BD must genuinely control the limits and the kill switch, be able to change them without you, and be able to demonstrate it |

> ⚠️ **This is the arrangement that determines who may write your risk parameters.**
> If a sponsoring broker-dealer's 15c3-5 controls live in your FPGA, the BD must have
> its own authenticated path to set limits and to hit the kill switch, independent of
> your strategy processes. That is an architectural requirement, and it is the reason
> [09-risk-controls-and-limits.md](09-risk-controls-and-limits.md) specifies a
> separate control-plane region and an out-of-band kill trigger. Do not design the
> control plane before this arrangement is settled in writing.

Unfiltered/naked access — orders reaching the exchange without passing the BD's
pre-trade controls — is prohibited. See
[06-regnms-and-compliance.md](06-regnms-and-compliance.md) §7.

---

## 7. Testing environments and certification

### What exists

| Environment | Purpose |
| --- | --- |
| **Nasdaq Test Facility (NTF)** | A separate, always-available test environment with its own endpoints for ITCH, OUCH, RASH, and FIX. Not a market — a protocol and conformance target |
| **Weekend / Saturday testing** | Scheduled sessions against production-like systems, including industry-wide disaster-recovery and new-release tests |
| **Certification / conformance** | A scripted exercise where Nasdaq verifies your system handles the protocol correctly, including error and edge cases, before you are permitted in production |

> **Verify:** current NTF endpoints, the testing calendar, and the certification
> script/requirements for each protocol version from the **testing and certification
> pages on nasdaqtrader.com**, and watch **Nasdaq Equity Trader Alerts** for testing
> announcements.

> ⚠️ **Absolute rule for this project: conformance certification is completed, for the
> exact protocol version and the exact message set we use, before any build is pointed
> at a production endpoint.** This restates CLAUDE.md §6 and it has no exceptions. The
> production endpoint IP/port belongs in a configuration file that no development
> build can load.

### What certification does *not* cover

Certification proves your protocol handling is correct. It does not prove:

- your strategy is sane,
- your risk limits are set,
- your latency is what you think,
- your failover works,
- your books are right after a mid-session gap.

Those are yours. See
[../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md).

---

## 8. Onboarding checklist

The ordered sequence. Items are serialised where a later step genuinely depends on an
earlier one; the lead times are the reason to start early.

1. **Decide the legal structure.** Own broker-dealer, or sponsored access through one?
   This gates everything else (§6). *Longest lead time of anything in this list.*
2. **Establish the broker-dealer / clearing relationship.** Clearing agreement,
   capital, credit limits, the 15c3-5 control arrangement in writing.
3. **Obtain exchange membership or sponsorship**, and **MPID(s)** (§5).
4. **Agree the MPID / SMP / tier-attribution structure** with compliance and the
   fee owner.
5. **Execute market data agreements** — TotalView, non-display use, per-venue depth
   feeds, and any redistribution terms. Data licensing is slower than people expect.
6. **Order colocation**: cabinet, power, cross-connects. *Lead time in weeks.*
7. **Order handoff ports and market-data ports** at the chosen speeds (§3, §4).
8. **Install and commission hardware.** Servers, FPGA cards, switch (if any), optics,
   PTP grandmaster, spares.
9. **Establish time synchronisation** and verify it (§9).
10. **Connect to NTF** and bring up the protocol stacks against test endpoints.
11. **Develop and regression-test** against captured pcaps and simulated venues.
12. **Complete conformance certification** for ITCH, OUCH, and any other protocol used.
13. **Configure and independently verify risk limits** —
    [09-risk-controls-and-limits.md](09-risk-controls-and-limits.md). Every check
    proven to fire.
14. **Rehearse the kill switch and the failover** in the test environment, timed.
15. **Participate in a weekend/production-readiness test** if available.
16. **Production canary**: one symbol, minimum size, hard limits, a human watching.
    See [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md).
17. **Scale deliberately**, one axis at a time (symbols, then size, then strategies).

> ⚠️ Steps 1, 5, 6 and 7 are **procurement and legal** and dominate the calendar.
> Engineering that starts before them will finish and then wait. Start the paperwork
> on day one.

---

## 9. Time synchronisation

### What you need it for — two different requirements

| Requirement | Accuracy needed | Driver |
| --- | --- | --- |
| **CAT clock-sync obligation** | Within the CAT tolerance of NIST (historically **50 ms** for industry members) | Regulatory. Trivially met |
| **Your own latency measurement and adverse-selection analysis** | **Nanoseconds**, and stable | Engineering. Hard |
| **Cross-host / cross-venue event ordering** | Sub-microsecond | Correlating your ITCH receive with your OUCH send with an away venue's print |

> ⚠️ **Do not let the loose regulatory number set your engineering target.** 50 ms is
> the *compliance floor*. If your timestamps are only good to milliseconds, you cannot
> measure a 500 ns pipeline, you cannot compute realized-vs-effective spread by
> latency bucket, and you cannot tell whether a fill was a pickoff. The regulatory
> requirement and the useful requirement differ by six orders of magnitude.

Note also the CAT **granularity** rule: if you capture finer than milliseconds you
must *report* finer. Nanosecond hardware timestamps mean nanosecond CAT reporting —
see [06-regnms-and-compliance.md](06-regnms-and-compliance.md) §9.

### How it is built

```
    GPS antenna (roof / provider feed)
        │
        ▼
    PTP grandmaster clock  ──── 1 PPS + 10 MHz ───▶  FPGA card
        │  (IEEE 1588 PTP over Ethernet)
        ▼
    Servers / NIC hardware clocks
```

| Element | Notes |
| --- | --- |
| **GPS/GNSS source** | In a colo, roof antenna access is a service you request, not something you install. Some providers offer a distributed timing feed instead |
| **PTP grandmaster** | Disciplines to GNSS; serves PTP to the network and PPS/10 MHz to hardware |
| **PPS into the FPGA** | The clean way: a free-running fabric counter, corrected against 1 PPS, gives sub-100 ns UTC traceability with no protocol stack in fabric |
| **PTP in fabric** | Possible, more complex; needed if you have no PPS distribution |
| **Holdover** | What happens when GNSS is lost. Know your holdover spec and **alarm on it** — a silently free-running clock is worse than a known-bad one |

> ⚠️ **Monitor and log time-sync health as a first-class metric**, with an alarm on
> loss of lock, on offset exceeding a threshold, and on holdover entry. A timestamp
> you cannot vouch for is useless for both regulation and engineering — and you will
> only discover it when someone asks about a specific trade from three months ago.

Related: [../06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md),
[../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md).

---

## 10. Disaster recovery and failover

### The venue's side

Nasdaq operates a geographically separate disaster-recovery facility and periodically
runs industry-wide DR tests. If you are a designated participant in such a test,
participation is mandatory and dated.

> **Verify:** the current DR site, the DR connectivity options, and the testing
> calendar via **Nasdaq Equity Trader Alerts** and the Nasdaq connectivity service
> descriptions. Do not assume a location.

### Your side — what your failover story must actually answer

| Failure | Required answer |
| --- | --- |
| One market-data feed line (A or B) dies | Arbitration continues on the survivor; count and alarm. **No trading impact** |
| Both lines of one channel die | Book for those symbols goes stale → **stop quoting those symbols**, do not guess |
| An order-entry session drops | Cancel-on-disconnect behaviour is known and configured; a second port takes over; **positions are reconciled before resuming** |
| The FPGA card fails | Kill switch is asserted by the failure itself (link loss / watchdog); flatten via the backup path |
| The host process dies | **Host watchdog timeout must independently disable trading in fabric** — see [09-risk-controls-and-limits.md](09-risk-controls-and-limits.md) §5 |
| The whole cabinet loses power | Standing orders: what does the venue do with your resting orders? Cancel-on-disconnect is the safety net — **verify it is on** |
| Nasdaq fails over to DR | Do you have connectivity there? Can you reach it in time? If not, the honest answer is "we are flat and out for the day" — **which is an acceptable answer, if it is decided in advance** |

> ⚠️ **The most dangerous failover is a partial one.** A system that keeps quoting on
> a stale book, or that reconnects and resumes without reconciling positions, does far
> more damage than a system that stops. **Design every degraded mode to stop trading,
> not to continue on partial information.** This is the fail-closed principle, applied
> to connectivity.

**Cancel-on-disconnect is your single most valuable safety feature** and it lives at
the venue, not in your code. Know its exact semantics for every port, verify them in
the test environment, and re-verify after any port reconfiguration. See
[05-ouch-5.0-order-entry.md](05-ouch-5.0-order-entry.md).

---

## 11. Physical operations

The unglamorous part that determines your actual uptime.

| Reality | Consequence |
| --- | --- |
| **You cannot casually walk into a colo cage.** Access requires pre-registration, escort or badge provisioning, and often 24-hour notice. Carteret is not near anything | A 5-minute fix becomes a 6-hour trip, or a phone call to someone else's hands |
| **Remote hands is a per-incident service performed by a technician who does not know your system** | Every procedure must be written down, unambiguous, and executable by a stranger. "Reseat the card" needs a photo and a cabinet/RU/slot reference |
| **Optics fail, and they fail intermittently first** | Keep spares of **every** optic type on site, in a labelled box, in your own cabinet. Track transceiver DOM (temperature, TX/RX power) and alarm on drift |
| **Cables get bumped** | Label everything at both ends. Photograph the cabinet after every change |
| **Spares** | An entire spare server and FPGA card on site is cheaper than a day of downtime, and vastly cheaper than shipping one to New Jersey |
| **Firmware/bitstream recovery** | ⚠️ You must be able to recover a bricked card **without physical access**. Golden-image fallback and out-of-band management (IPMI/BMC on a separate network) are mandatory, not nice-to-have |
| **Out-of-band management network** | Separate from the trading path, separately powered, always reachable. This is how you get in when the trading network is the thing that is broken |
| **Change windows** | Physical work happens outside market hours. Plan for weekends |

> ⚠️ **Never make the FPGA the only path to the kill switch.** If your only way to
> stop trading is through the machine that has failed, you have no kill switch. The
> out-of-band management path, and the venue's own cancel-on-disconnect, are the
> layers underneath. See [09-risk-controls-and-limits.md](09-risk-controls-and-limits.md) §5.

---

## Hardware implications

1. **Transceiver count is set by (venues × A/B feeds) + order-entry + management.**
   Three Nasdaq markets alone is six market-data streams. Count them before choosing
   the card; adding a port later means new hardware, not a rebuild.
2. **Support both 10G and 25G in the PHY configuration, and make FEC mode a
   build-time (or at minimum documented) choice.** Then *measure* both. The right
   answer is workload-dependent and is not knowable from the datasheet.
3. **Minimise hops between the handoff and the fabric.** Handoff → optic → FPGA.
   Every switch is tens to hundreds of nanoseconds spent on someone else's silicon.
4. **Per-venue symbol translation is mandatory.** `stock locate` is per-feed. Maintain
   a (venue, locate) → internal index map; never use a locate code as a global index.
5. **Per-stream gap and staleness state.** Every multicast channel of every venue gets
   its own sequence tracker, gap counter, and staleness timer. Staleness must be able
   to disable quoting for the affected symbols independently.
6. **Multiple OUCH sessions in fabric**, with per-session sequence state, and a
   **dedicated cancel/risk-reducing session** that new-order flow structurally cannot
   use. Enforce that separation in the order router, not by convention.
7. **Per-port message-rate counters, windowed**, with a configurable ceiling below the
   venue's throttle, so you throttle yourself before the venue does.
8. **A PPS-disciplined nanosecond counter** feeding every timestamp in the design,
   with a lock/holdover status bit that is exported, logged, and alarmed. Timestamps
   taken while unlocked must be flagged as such in the record.
9. **Link-loss on any critical interface is a kill-switch trigger**, wired into the
   risk block, not handled by host software. See
   [09-risk-controls-and-limits.md](09-risk-controls-and-limits.md) §5.
10. **Out-of-band recoverability**: golden bitstream fallback, BMC/IPMI on a separate
    network, and a documented remote procedure to return the card to a safe,
    non-trading state without anyone entering the building.
11. **Endpoint configuration is data, not RTL.** Multicast groups, ports, and session
    endpoints come from a loadable configuration, with production values in a file
    that development builds cannot load. Multicast group assignments change; a rebuild
    must never be the response to a Trader Alert.
12. **Transceiver DOM telemetry exported as counters** (temperature, TX/RX optical
    power, FEC corrected/uncorrected counts). Optics degrade before they fail, and
    rising FEC uncorrected-error counts are the earliest warning you will get.

---

## Further reading

- [01-market-structure.md](01-market-structure.md) — the three Nasdaq markets you must connect to
- [04-totalview-itch-5.0.md](04-totalview-itch-5.0.md) — the feed these multicast groups carry
- [05-ouch-5.0-order-entry.md](05-ouch-5.0-order-entry.md) — sessions, sequencing, cancel-on-disconnect
- [06-regnms-and-compliance.md](06-regnms-and-compliance.md) — 15c3-5, CAT clock sync, DR testing obligations
- [07-fees-rebates-and-economics.md](07-fees-rebates-and-economics.md) — ports and cabinets as cost lines
- [09-risk-controls-and-limits.md](09-risk-controls-and-limits.md) — kill-switch triggers including link loss
- [../01-fpga-design/04-io-transceivers-and-serdes.md](../01-fpga-design/04-io-transceivers-and-serdes.md) — what FEC costs you in the PCS
- [../02-networking/01-ethernet-phy-mac.md](../02-networking/01-ethernet-phy-mac.md) — 10G vs 25G, FEC, MAC latency
- [../02-networking/03-multicast-feeds-and-arbitration.md](../02-networking/03-multicast-feeds-and-arbitration.md) — A/B arbitration and gap recovery
- [../02-networking/04-nics-kernel-bypass-and-switching.md](../02-networking/04-nics-kernel-bypass-and-switching.md) — the cost of a switch hop
- [../06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md) — the general colocation playbook
