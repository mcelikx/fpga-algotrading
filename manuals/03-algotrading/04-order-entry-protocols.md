# 03.04 — Order Entry Protocols

> **Why this matters here:** market data decode can be made almost free; **order
> encode cannot**, because outbound messages sit on top of a stateful, reliable,
> connection-oriented transport. Every nanosecond in the second half of the
> tick-to-trade path is spent either building bytes or satisfying TCP. This document
> is how we get that down to a handful of cycles without lying to ourselves about the
> risk we take on to do it.

The OUCH 5.0 message-level reference is
[../08-nasdaq/05-ouch-5.0-order-entry.md](../08-nasdaq/05-ouch-5.0-order-entry.md). This document
is the concept layer and the hardware architecture.

---

## 1. Two layers, two owners

Every order entry protocol splits cleanly in two, and **that split is also our CPU/FPGA
partition**.

| | **Session layer** | **Application layer** |
| --- | --- | --- |
| Job | Establish, authenticate, sequence, keep alive, recover, tear down | Enter, replace, cancel orders; receive acks, fills, rejects |
| Examples | SoupBinTCP (under OUCH), FIX session (FIXT), iLink 3 session | OUCH messages, FIX application messages, iLink 3 business messages |
| Rate | A few messages per minute | Line rate |
| Latency sensitivity | **None** | **Total** |
| Complexity | High (state, timers, retries, credentials) | Low (fixed templates) |
| **Owner here** | **CPU** | **FPGA** |

That partition is the most important architectural decision in the gateway. Logon
negotiation, heartbeat timers, resend logic, and logout have no business in fabric —
they are timer-driven, error-path-heavy, and never on the critical path. The FPGA's job
begins after the session is established and consists of one thing: **turn a trigger into
bytes on the wire.**

```
      CPU                                     FPGA
  ┌──────────────┐                    ┌─────────────────────┐
  │ Session mgmt │  TCP connect,      │ Order encoder       │
  │ SoupBinTCP   │  logon, heartbeat, │ (templates in ROM)  │
  │ login/logout │  seq recovery      │                     │
  │              │ ───── hands off ──►│ Risk gate           │
  │              │  socket state:     │                     │
  │              │  seq nums, window, │ TCP TX (seq/ack)    │
  │              │  IP/port/MAC       │                     │
  └──────────────┘                    └─────────────────────┘
```

---

## 2. Anatomy of a session layer

SoupBinTCP, FIX, and iLink 3 all have the same six elements. Learn them once.

| Element | Purpose | Failure mode if wrong |
| --- | --- | --- |
| **Logon** | Authenticate; negotiate the starting sequence numbers | Wrong sequence ⇒ instant disconnect, or a flood of resends |
| **Heartbeat** | Prove liveness in both directions on an idle connection | Missed heartbeats ⇒ the venue disconnects you ⇒ **cancel-on-disconnect fires** (§8) |
| **Sequence numbers** | Detect loss and duplication on an otherwise reliable transport | Off-by-one at logon is the classic outage |
| **Gap fill / resend** | Recover missed *inbound* messages after a reconnect | Naive resend can re-deliver executions ⇒ double-counted position |
| **Retransmission of our own messages** | The venue may ask us to resend | Only the CPU can do this — it must have kept every byte we sent |
| **Logout / end of session** | Orderly teardown; end-of-day marker | Unclean logout looks like a disconnect |

### SoupBinTCP, concretely

OUCH runs over **SoupBinTCP**, a thin framing/session layer on top of TCP:

```
  ┌────────┬────────┬───────────────────────────────┐
  │ Length │ Type   │ Payload                       │
  │ 2 B BE │ 1 B    │ (Length − 1) bytes            │
  └────────┴────────┴───────────────────────────────┘

  Client → Server:  Login Request, Unsequenced Data (this carries OUCH orders),
                    Client Heartbeat, Logout Request
  Server → Client:  Login Accepted / Rejected, Sequenced Data (acks, fills),
                    Server Heartbeat, End of Session
```

The asymmetry is deliberate and useful: **what we send is "unsequenced"** (TCP already
guarantees delivery and order to the venue), **what we receive is "sequenced"** (so a
gap after reconnect is detectable and recoverable). Our *transmit* path therefore needs
no application-level sequence number at all — one less thing on the critical path.

> **Verify:** heartbeat intervals, timeout thresholds, login field formats, and
> reconnection/sequence-continuation rules are in the Nasdaq **SoupBinTCP** and **OUCH
> 5.0** specs. A heartbeat timeout mis-set by a factor of ten is an outage.

---

## 3. Binary vs. FIX order entry

| | **Binary (OUCH, iLink 3 / SBE)** | **FIX 4.4 / 5.0 tag-value** |
| --- | --- | --- |
| Encoding | Fixed-offset (OUCH) or templated (SBE) binary | ASCII `tag=value` pairs, `\x01` delimited |
| New order size | ~40–60 bytes | ~150–250 bytes |
| Field placement | Constant offsets | Variable order, variable length |
| Numeric conversion | None — binary integers | **ASCII ⇄ integer on every numeric field** |
| Length field | Fixed per type, or in the header | `BodyLength` (tag 9) must be computed *before* you can emit the header |
| Checksum | None (TCP covers it) | `CheckSum` (tag 10) = sum of all bytes mod 256, computed *after* the body |
| Encode latency in fabric | **1–3 cycles** — copy template, patch fields | 10s of cycles even with templates; more without |
| Verdict | **Use this** | Slow path / back office only |

The killer for FIX on a fast path is not the ASCII conversion — it is the two
**whole-message dependencies**: `BodyLength` sits near the front but depends on the whole
body, and `CheckSum` sits at the end and depends on everything. Both force you either to
buffer the message (store-and-forward, latency) or to compute incrementally (§6). Binary
protocols have neither problem.

**Rule for this project:** the fast path speaks **OUCH 5.0 over SoupBinTCP** and nothing
else. FIX, if it appears at all, is drop copy or post-trade, on the CPU.

---

## 4. The transport problem: TCP vs. UDP

This is the structural asymmetry of the whole system, and it is worth stating baldly:

```
   MARKET DATA IN   :  UDP multicast   — stateless, no ACKs, no retransmit,
                                          no connection. Trivial in fabric.
   ORDER ENTRY OUT  :  TCP unicast     — connection state, sequence numbers,
                                          ACKs, retransmission, sliding window,
                                          congestion control, checksums.
```

TCP exists to make an unreliable network look reliable, and every mechanism it uses to
do that is **stateful and timer-driven** — the opposite of what fabric is good at.
Full TCP in hardware (a TOE) is a large, subtle, expensive block. The full treatment is
[../02-networking/02-ip-udp-tcp-in-hardware.md](../02-networking/02-ip-udp-tcp-in-hardware.md);
here is the decision framing.

| Approach | How | Latency | Risk |
| --- | --- | --- | --- |
| **Full TOE in fabric** | Complete TCP state machine in hardware | Lowest | Highest complexity; a TCP bug is an outage or worse |
| **Split / handoff** ← *our choice* | CPU (or a soft stack) establishes the connection and owns the receive side and all error handling. FPGA owns **transmit only**: it holds the current `snd_nxt`, MAC/IP/port tuple, and emits pre-checksummed segments. | Near-lowest | Bounded — the hard parts stay in software |
| **Vendor TOE IP** | Licensed hard/soft IP | Low | Latency and behaviour are the vendor's, not yours |
| **CPU sends** | FPGA signals, CPU transmits | Hopeless (µs, jittery) | None, but no product either |

### Why split works here

Our transmit side is unusually easy: **small, self-contained messages sent one at a time
on a session idle enough that we are almost never in a retransmit or window-limited
state.** The FPGA's TCP transmitter therefore needs only the 4-tuple and Ethernet header
(constant per session — bake them into the template), the current send sequence number
(a register, incremented by payload length), a correct TCP checksum (§6), and a way to
**hand back to the CPU** when anything unusual happens. Receive path, ACK processing,
retransmission, window updates, RST handling and teardown are all the CPU's.

⚠️ **The FPGA and the CPU must never both believe they own `snd_nxt`.** Ownership is an
explicitly handed-over token: the CPU establishes and quiesces the connection, writes the
state to the FPGA, sets `FPGA_OWNS_TX`, and does not touch the socket again until it
clears that bit and the FPGA acknowledges the handback. Two writers to a TCP sequence
number is a corrupted stream, and a corrupted order stream mid-session is a very bad
afternoon.

⚠️ **A retransmission means the FPGA's `snd_nxt` may no longer describe what the venue
has.** Any retransmit, zero-window, or RST condition **immediately halts FPGA order
emission** and hands control back. Fail closed.

---

## 5. Pre-built message templates

The core latency technique, and it is embarrassingly simple: **the message is already
built before the trigger fires.** Only the variable fields are patched in.

```
Enter Order template, resident in ROM/registers, per (session × strategy × side):

  ┌──────────────────────────────────────────────────────────────────────┐
  │ Ethernet hdr │ IP hdr │ TCP hdr │ Soup hdr │ OUCH Enter Order        │
  │  CONSTANT    │ mostly │ seq/ck  │ CONSTANT │ token │ sym │ px │ qty  │
  │              │ CONST  │ patched │          │ patch │ pat │ pt │ pat  │
  └──────────────────────────────────────────────────────────────────────┘
        ↑              ↑        ↑                    ↑
     never changes  length,  incremented        the only genuinely
                    checksum  per message       per-trigger data
```

Everything constant per session (MAC/IP/ports, Soup type byte, OUCH message type, and
the order-book/display/TIF/capacity/firm fields for a given strategy) is **elaborated
into the bitstream or written once at session start**. Only a handful of fields change
per order. Consequences:

- A "new order" is a **mux, not a computation**: select a template, overlay 4–5 fields.
  1–2 cycles.
- Templates live in distributed RAM or a small BRAM indexed by `{strategy_slot,
  msg_shape}`. There are three shapes total
  ([02-order-types-and-matching-engines.md](02-order-types-and-matching-engines.md) §3):
  post-only limit, IOC limit, cancel.
- **The cancel template is the smallest and should be the fastest path in the design** —
  it patches one field, the token. Per §8 of the previous document, that is exactly the
  right thing to have optimised.
- Template contents are **write-protected while orders are in flight**, updated only via
  the same atomic double-buffer/commit-bit mechanism as strategy parameters
  ([05-strategy-taxonomy.md](05-strategy-taxonomy.md) §6).

---

## 6. Incremental checksums

The IP and TCP checksums are 16-bit one's-complement sums over the header (and, for
TCP, the payload plus a pseudo-header). Recomputing that over a whole message is a wide
adder tree and a store-and-forward stall you cannot afford.

The trick: **a one's-complement sum is incrementally updatable.** If you know the
checksum of the template and you change one 16-bit word from `m` to `m'`:

```
    HC'  =  ~( ~HC  +  ~m  +  m' )        (16-bit one's complement arithmetic)
```

> **Verify:** RFC 1624 ("Computation of the Internet Checksum via Incremental
> Update"), which corrects the earlier formulation in RFC 1141; base definition in
> RFC 1071. Implement from the RFC — the `~0` / `0` end-around-carry edge case is real
> and a naive implementation gets it wrong on exactly the inputs that occur rarely.

The encoder precomputes the *template's* checksum offline and applies one small
correction per patched field at emit time. Each correction is a 16-bit add with
end-around carry — one LUT level; four patched fields is a 4-input carry-save tree.
**Constant time, no buffering, no dependence on message length.**

The same technique covers a FIX `CheckSum` (a plain byte-sum mod 256, even easier) and
`BodyLength` if the template fixes field widths so the length is constant per shape —
another reason to pad numeric fields rather than emit minimal digits.

⚠️ **Verify the incremental checksum against a full recomputation in simulation, on every
message, across the whole regression suite.** A wrong TCP checksum produces no obvious
failure: the venue's stack silently drops the segment, TCP retransmits, and you observe
"occasional latency spikes" instead of "broken checksum logic". Add a from-scratch
recomputation assertion under `ifndef SYNTHESIS`.

---

## 7. Order tokens: generating ClOrdIDs in hardware

Every order needs a client-assigned identifier — `Order Token` in OUCH, `ClOrdID` in
FIX. It has hard requirements that pull in opposite directions:

| Requirement | Why |
| --- | --- |
| **Unique** within the venue's scope (typically per firm per day) | Duplicate tokens are rejected, or worse, ambiguous |
| **Generated at line rate, in fabric** | It is on the critical path |
| **Reconcilable by the CPU** | The CPU must attribute every fill, including fills for orders whose emit-record it has not yet processed |
| **Cheap to encode** | The venue field is often fixed-width alphanumeric |

> **Verify:** the OUCH order token's width, permitted character set, and uniqueness
> scope are specified in the OUCH 5.0 document (and are commonly a fixed-width
> alphanumeric field). Confirm before fixing the width in RTL —
> [../08-nasdaq/05-ouch-5.0-order-entry.md](../08-nasdaq/05-ouch-5.0-order-entry.md).

### The scheme

Build the token as a **56-bit integer rendered as 14 ASCII hex characters**. Hex is
deliberate: 4 bits → one character is a *combinational nibble-to-ASCII LUT*, whereas
base-36 or base-10 rendering requires division — the difference between zero cycles and
several.

```
 bit  55        48 47                  32 31                              0
     ┌────────────┬──────────────────────┬─────────────────────────────────┐
     │ strategy_id│  symbol_id           │  monotonic counter              │
     │   8 bits   │  16 bits             │  32 bits                        │
     │            │ (= ITCH stock_locate)│ (per session, never reset)      │
     └────────────┴──────────────────────┴─────────────────────────────────┘
              ↓ nibble → ASCII hex, purely combinational ↓
        "0" .. "9", "A" .. "F"        →   14-character token
```

Why each field:

- **`monotonic counter` alone guarantees uniqueness** within the session; 32 bits will
  not wrap in a trading day at any plausible rate.
- **`strategy_id` and `symbol_id` make the token self-describing.** The CPU can attribute
  a fill to a strategy and symbol **without a lookup and without having seen the emit
  record** — which matters exactly when you need it most: a fill arriving before the DMA
  record, after a CPU restart, or during a partial outage. An opaque counter forces a
  table lookup that may not yet be populated, and an unattributable fill is a position
  you cannot reconcile.
- `symbol_id` being the **ITCH stock locate** joins the token directly against the market
  data path with no translation.

⚠️ **Counter wrap must be impossible, and enforced.** A hardware comparator refuses
further orders and alarms when the counter passes a high-water threshold. A wrapped token
duplicates a live order's identifier and produces ambiguous fills — an unrecoverable
accounting state.

⚠️ **`strategy_id` and `symbol_id` in the token are a convenience, not the source of
truth.** The authoritative record is the DMA emit record; the token fields are a
fast-attribution hint that must be *checked against* it, and a mismatch is an incident.

---

## 8. Inbound: acks, rejects, fills — and cancel-on-disconnect

Everything the venue sends us arrives on the same TCP session, as SoupBinTCP
**Sequenced Data**.

| Inbound | FPGA action | CPU action |
| --- | --- | --- |
| Order Accepted | Mark own-order entry LIVE; **record the venue's actual price and quantity** | Record; start the audit trail entry |
| Order Rejected | Free the slot; return credits; count by reason code | Classify; alert if the reason is not benign (post-only reject is benign) |
| Executed | Update position (saturating), update `shares_ahead` models, free slot if complete | Authoritative position/PnL, clearing record, CAT record |
| Canceled | Free the slot; return credits | Record |
| Replaced | Old token dead, new token live | Record both |
| Broken / Cancel Pending / other | **Hand to CPU; do not attempt to interpret in fabric** | Full handling |

**Where the state lives** is in
[02-order-types-and-matching-engines.md](02-order-types-and-matching-engines.md) §9. The
rule bears repeating: the FPGA keeps the **minimum state needed to cancel and to enforce
risk**; the CPU keeps everything else and is authoritative.

### Cancel-on-disconnect

Most venues offer (and often default to) **cancel-on-disconnect**: when your order entry
session drops, the venue cancels your resting orders. Whether it is on by default,
whether it covers all order types, whether it distinguishes clean logout from an abrupt
TCP reset, and how long it takes all vary.

> **Verify:** Nasdaq's cancel-on-disconnect behaviour is a port/session configuration
> described in the OUCH and port setup documentation. Confirm the configuration on **our**
> ports, in writing, before going live —
> [../08-nasdaq/05-ouch-5.0-order-entry.md](../08-nasdaq/05-ouch-5.0-order-entry.md).

⚠️ **You must know your venue's policy, because both answers are dangerous.**
With it **ON**, a brief network blip silently flattens all your resting quotes; you
reconnect into a market where you have no orders, and software that assumes otherwise
will double-quote. *Always resynchronise state from the venue after a reconnect, never
from local memory.* With it **OFF**, a disconnect leaves you with **live orders you can
no longer cancel** — the nightmare scenario, which demands a documented, rehearsed,
out-of-band cancellation procedure (venue trade desk, a second session, a purge port).

**Rule for this project:** cancel-on-disconnect is **ON**, verified in writing and
re-verified after any port change. We additionally run our own watchdog: no inbound
session traffic for a configured interval ⇒ the FPGA stops emitting new orders, without
needing the CPU's permission.

---

## 9. Throttles, rate limits, and drop copies

### Venue throttles

Venues impose message-rate limits per session/port. Exceeding them gets messages
rejected, the session throttled, or the port disconnected — and those rejects arrive when
you least want them. Separately, **SEC Rule 15c3-5 requires our own rate controls**
regardless of what the venue enforces —
[06-risk-and-compliance.md](06-risk-and-compliance.md).

> **Verify:** Nasdaq's order entry rate limits and their enforcement (per port, per firm,
> and any weighting of message types) are in Nasdaq's port and rulebook documentation.
> Obtain the actual limits for our ports; do not design to a guess.

### Enforcing rate limits in hardware

A **token bucket** is the right primitive: cheap, exact, no division.

```systemverilog
// Token bucket: refill R tokens every REFILL_PERIOD cycles, cap at BURST.
// Every outbound message consumes one token. No tokens ⇒ no send.
always_ff @(posedge clk) begin
    if (refill_tick)
        tokens_q <= (tokens_q + R > BURST) ? BURST : tokens_q + R;
    if (msg_sent_ok)
        tokens_q <= tokens_q - 1;          // (combine the two branches properly)
end
assign may_send = (tokens_q != 0);
```

Three non-obvious rules:

1. **Set our bucket strictly below the venue's limit.** Throttling ourselves is a delay
   we control and count; being throttled by the venue is a reject or a disconnect.
2. ⚠️ **Cancels get their own bucket, sized generously.** A shared bucket means that in
   the exact burst where you most need to pull quotes, you cannot.
3. **Every throttled message is counted, by reason and by strategy.** A rising throttle
   counter is a leading indicator of a runaway strategy (§10), well before position
   limits trip.

### Drop copies

A **drop copy** is a separate, independent session carrying a copy of every order event
and execution — typically FIX, typically consumed by a different process on a different
machine. Its value is that it is *out of band*: it answers "what does the venue think our
position is?" without trusting any part of our fast path. Use it for independent
near-real-time position reconciliation, for detecting divergence between what we think we
sent and what the venue received, and as a surviving record when the primary session is
the thing that failed.

**Rule for this project:** the drop copy is consumed by a **separate process** sharing no
memory, code, or network path with the trading process, computing position independently.
Divergence beyond a small tolerance triggers the kill switch. A reconciliation system
that shares its inputs with the system it reconciles is decoration.

---

## 10. ⚠️ The hazard: an FPGA that outruns its own accounting

**This is the defining safety problem of an FPGA order gateway, and it deserves to be
stated as starkly as possible.**

The FPGA can emit an order every few hundred nanoseconds. The CPU processes a DMA
completion in microseconds and updates its books in tens of microseconds. Under a
pathological trigger — a strategy bug, a corrupted book, a parameter set that makes every
book event a signal — the FPGA emits **thousands of orders before the CPU processes the
first one**. Every classic algo-trading disaster has this shape: the fast component kept
acting while the slow component had not yet noticed. Software-side risk checks are
useless against it by construction, and hardware position limits bound only the
*resulting position*, not the *message flood* — and they depend on fills, which lag.

### The mechanism: bounded in-flight credits

Bound the divergence structurally, with credits
([../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) §8).
Three independent pools, all of which must be non-zero to emit a new order:

| Pool | Decrement on | Increment on | Bounds |
| --- | --- | --- | --- |
| **`live_orders`** | Order emitted | Terminal venue message (fill/cancel/reject) | Concurrent resting exposure |
| **`unacked_by_venue`** | Order emitted | Any venue ack for that token | How far ahead of the *venue* we can get — catches a dead/slow session |
| **`unaccounted_by_cpu`** | Order emitted | CPU explicitly returns a credit after durably recording the order | **How far ahead of our own books we can get** |

The third pool is the one people leave out, and the one that matters here. It makes the
invariant explicit and enforced in silicon:

> **The FPGA may never be more than `N` orders ahead of the CPU's record of reality.**

Pick `N` small — tens, not thousands. It bounds a runaway to `N` orders regardless of the
bug, at zero cost in normal operation because the CPU returns credits far faster than the
strategy consumes them. On exhaustion the encoder refuses, counts, and interrupts; that
refusal counter going non-zero is a **P1 alert**, not a tuning signal. Rules that go with
it:

1. **Credits are consumed by new orders only.** Cancels draw from a separate, generously
   sized pool — a risk mechanism must never prevent risk reduction.
2. **Credits are zero at reset and after any error**, granted only by an explicit CPU
   write. ⚠️ A counter initialising to its maximum is a risk check that passes on reset —
   [06-risk-and-compliance.md](06-risk-and-compliance.md) §10.
3. **Credit accounting saturates.** Returning more credits than were consumed trips the
   kill switch: it means the CPU and FPGA disagree about reality.
4. **Credit exhaustion is visible in telemetry** with per-strategy attribution.

---

## 11. Rules for this project

1. **Session layer on the CPU, application layer on the FPGA.** No exceptions.
2. **OUCH 5.0 over SoupBinTCP** on the fast path. No FIX in fabric.
3. **Split TCP**: CPU owns connect/receive/error, FPGA owns transmit-only with an
   explicit ownership handover bit. Any retransmit/RST/zero-window ⇒ halt emission.
4. **Three message templates only**, in ROM, patched at emit. The cancel template is
   the fastest path in the design.
5. **Incremental checksums per RFC 1624**, asserted against full recomputation in
   simulation.
6. **56-bit tokens rendered as 14 ASCII hex chars**: `strategy_id | symbol_id |
   monotonic counter`. Self-describing. Wrap is impossible and enforced.
7. **Own-order state is updated from the ack**, never from what we sent.
8. **Cancel-on-disconnect ON**, confirmed in writing, plus our own inbound-silence
   watchdog that stops emission without CPU involvement.
9. **Self-throttle below the venue limit**, with a **separate, generous cancel bucket**.
   Count everything.
10. **Three credit pools**, including `unaccounted_by_cpu`. Zero at reset. Exhaustion is
    a P1 alert.
11. **Drop copy reconciled by an independent process**; divergence trips the kill switch.

---

## Further reading

- [02-order-types-and-matching-engines.md](02-order-types-and-matching-engines.md) — the order lifecycle these messages implement
- [03-market-data-protocols.md](03-market-data-protocols.md) — the inbound mirror of this problem
- [06-risk-and-compliance.md](06-risk-and-compliance.md) — the risk gate that sits between the strategy and this encoder
- [../02-networking/02-ip-udp-tcp-in-hardware.md](../02-networking/02-ip-udp-tcp-in-hardware.md) — TCP in fabric, in full
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — the gateway implementation
- [../08-nasdaq/05-ouch-5.0-order-entry.md](../08-nasdaq/05-ouch-5.0-order-entry.md) — every OUCH message, field by field
