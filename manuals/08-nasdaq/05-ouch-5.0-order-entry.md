# 08.05 — Nasdaq OUCH 5.0 Order Entry

> **Why this matters here:** this is the last block in the tick-to-trade path and the
> only one that can lose money by itself. Everything upstream is an opinion; the OUCH
> message is the commitment. The design goal is that when the strategy fires, **fewer
> than a hundred nanoseconds of encoding stand between the trigger and the first bit
> on the wire** — which is only achievable if the message is already built, sitting in
> BRAM, waiting for four fields to be spliced in.

Venue-neutral order-entry theory is in
[../03-algotrading/04-order-entry-protocols.md](../03-algotrading/04-order-entry-protocols.md).
This is the Nasdaq encoder reference.

> ⚠️ **Global verify note.** Every type code, field width, field order and enumeration
> value below must be confirmed against the **Nasdaq OUCH 5.0 specification** and the
> **SoupBinTCP specification** (nasdaqtrader.com/Trading/TradingSpecs). **OUCH 5.0
> differs materially from OUCH 4.2** — field sets changed, and 5.0 introduced an
> optional appendage / TagValue mechanism that 4.2 did not have. Tables below are
> labelled where they are illustrative. **Confirm before implementing.**

---

## 1. OUCH in context

| Protocol | Shape | Latency | Use |
| --- | --- | --- | --- |
| **OUCH** | Nasdaq-native, **fixed-length binary**, minimal field set | **Lowest** | ✅ **Our protocol** |
| RASH | Nasdaq-native, richer routing/order-type coverage | Higher | For strategies OUCH does not express |
| FLITE | Nasdaq-native, a lighter/derived variant | — | ⚠️ **Verify current availability and semantics** |
| FIX | Tag=value ASCII, self-describing, industry standard | Highest — variable-length text parsing | Slow path, drop-copy, back-office |

> **Verify** which of RASH / FLITE / FIX / OUCH are currently offered, and on which
> markets (Nasdaq, BX, PSX), on nasdaqtrader.com. Protocol availability changes.

**Why OUCH wins in fabric:**

| Property | Consequence |
| --- | --- |
| Fixed-length messages, fixed offsets | No length calculation, no field-position search — a splice, not a serialization |
| Small field set | Almost every field is a session or per-symbol constant → pre-buildable |
| Binary, big-endian | No ASCII formatting of numbers on the fast path |
| Symbol is an 8-byte alpha field | ⚠️ The one soft spot — it is a *string*, not a locate. Solved by per-symbol templates (§7) |

⚠️ **OUCH runs over TCP** (via SoupBinTCP), not UDP. That is the hard part. A TCP
sender in fabric is a real engineering commitment — see
[../02-networking/02-ip-udp-tcp-in-hardware.md](../02-networking/02-ip-udp-tcp-in-hardware.md).
The project pattern is a **split TCP**: the host performs the three-way handshake and
the SoupBinTCP login, then hands the established connection's parameters (sequence
numbers, window, IP/port/MAC tuple) to the FPGA, which owns the steady-state send
path. The host retains the receive path and all exception handling.

---

## 2. SoupBinTCP — the session layer

OUCH messages are payloads inside SoupBinTCP packets.

```
   ┌──────────────────────────────────────────────┐
   │ Packet Length   2 bytes, big-endian          │  ← counts the Type byte + Payload
   │ Packet Type     1 byte,  ASCII               │
   │ Payload         (Packet Length − 1) bytes    │
   └──────────────────────────────────────────────┘
```

| Type (verify) | Name | Direction | Payload |
| --- | --- | --- | --- |
| `L` | **Login Request** | client → server | Username, password, requested session, requested sequence number |
| `A` | **Login Accepted** | server → client | Session id, next sequence number |
| `J` | **Login Rejected** | server → client | Reject reason code |
| `U` | **Unsequenced Data** | **client → server** | ⚠️ An **inbound OUCH message** (Enter/Replace/Cancel/Modify) |
| `S` | **Sequenced Data** | **server → client** | ⚠️ An **outbound OUCH message** (Accepted/Executed/…) |
| `R` | **Client Heartbeat** | client → server | none |
| `H` | **Server Heartbeat** | server → client | none |
| `O` | **Logout Request** | client → server | none |
| `Z` | **End of Session** | server → client | none |
| `+` | Debug | either | free text |

> **Verify** the packet type characters, the login field widths, the heartbeat
> interval and the inactivity timeout against the **SoupBinTCP specification**. The
> commonly cited pattern is a heartbeat roughly every second with a timeout of some
> seconds — confirm it, because **missing heartbeats terminates your session.**

### ⚠️ The asymmetry that defines the recovery model

```
   CLIENT ──► SERVER      UNSEQUENCED     "I am telling you something."
                                          No sequence number. If the connection
                                          dies mid-flight, YOU DO NOT KNOW
                                          whether the server got it.

   SERVER ──► CLIENT      SEQUENCED       "This is fact number N."
                                          Replayable from any N on reconnect.
                                          The server's stream is the source of truth.
```

Consequences:

1. **The outbound (server→client) stream is the authoritative record of your orders.**
   On reconnect you log in requesting a sequence number and the server replays
   everything from there. Your order state is rebuilt from the replay, not from your
   own send log.
2. ⚠️ **An unacknowledged Enter Order is genuinely ambiguous** after a disconnect.
   It may have been accepted, executed, or never received. **You must not resend it
   blindly** — that risks a duplicate order. The correct action is: reconnect, replay
   the sequenced stream, and see whether the token appears. This is precisely why
   §6's token scheme must make every order identifiable.
3. **Recovery is a host responsibility.** It involves TCP reconnection, replay, and
   reconciliation of potentially thousands of messages. None of that is fast-path work
   and none of it belongs in fabric.

### Division of labour

| Responsibility | Owner |
| --- | --- |
| TCP handshake, SoupBinTCP login, session negotiation | **Host** |
| Sequenced-stream receive, parse, replay, reconciliation | **Host** |
| Heartbeat generation and timeout monitoring | **Host** (⚠️ see below) |
| Steady-state Enter Order / Cancel transmission | **FPGA** |
| TCP sequence numbers and checksums for FPGA-sent bytes | **FPGA** |
| Retransmission of lost TCP segments | ⚠️ **Design decision** — see §9 |
| Logout, end of session, teardown | **Host** |

⚠️ **Heartbeats and the split-TCP design interact badly if not thought through.** If
the host and the FPGA both write to the same TCP connection, they must share the TCP
sequence-number space atomically. The clean patterns are (a) the FPGA owns the send
side entirely and the host asks it to emit heartbeats, or (b) heartbeats are emitted
by the FPGA on a timer with no host involvement. **Two independent writers to one TCP
stream will corrupt it.** Pick one owner, in writing, in the design document.

---

## 3. Inbound messages (client → server)

Carried in SoupBinTCP **Unsequenced Data** packets.

| Message | Purpose | FPGA emits? |
| --- | --- | --- |
| **Enter Order** | Submit a new order | ✅ Yes — the fast path |
| **Replace Order** | Modify price/quantity of a resting order, creating a **new** order token | ⚠️ Rarely — see below |
| **Cancel Order** | Reduce a resting order's quantity (to zero = full cancel) | ✅ **Yes — and this is often the more important path** |
| **Modify Order** | Change side/quantity in a limited way | Slow path |

> **Verify** the message type characters and the complete field lists for OUCH 5.0.
> (In 4.2 the inbound types were `O`/`U`/`X`/`M`; **do not assume 5.0 is identical.**)

### 3.1 Enter Order field table

> ⚠️ **Structure illustrative — field order and widths must be confirmed against the
> OUCH 5.0 specification before implementing.** What is reliable here is the
> *classification*, which is the entire basis of the template design in §7.

| Field | Type | Meaning | Mutability class |
| --- | --- | --- | --- |
| Message Type | 1 byte ASCII | Enter Order | **Session constant** |
| **Order Token** | alphanumeric, fixed width | Your unique identifier for this order | ⚠️ **Per-order variable** |
| Buy/Sell Indicator | 1 byte ASCII | Buy / Sell / Sell Short / Sell Short Exempt | ⚠️ **Per-order variable** |
| **Shares** | big-endian uint32 | Quantity | ⚠️ **Per-order variable** |
| **Stock** | 8 bytes ASCII, space-padded | Symbol | **Per-symbol constant** |
| **Price** | big-endian uint32, 4 implied decimals | Limit price | ⚠️ **Per-order variable** |
| Time in Force | (⚠️ changed between versions) | Day / IOC / extended | Per-strategy constant |
| Display | 1 byte | Displayed / non-displayed / post-only / attributable etc. | Per-strategy constant |
| Firm / MPID | 4 bytes ASCII | Attribution | **Session constant** |
| Capacity | 1 byte | Agency / principal / riskless principal / other | **Session constant** |
| Intermarket Sweep Eligibility | 1 byte | ⚠️ ISO — see [03-order-types-and-routing.md](03-order-types-and-routing.md) §2.7 | **Session constant (off)** |
| Minimum Quantity | big-endian uint32 | MQTY | Per-strategy constant |
| Cross Type | 1 byte | Continuous / opening / closing / halt | **Session constant (continuous)** |
| Customer Type | 1 byte | Retail designation etc. | **Session constant** |
| **Optional appendage / TagValue block** | variable | OUCH 5.0 mechanism for additional attributes (routing, SMP, discretion, …) | ⚠️ **Verify** — a variable-length tail defeats fixed-offset splicing; see §7 |

⚠️ **The optional appendage section in OUCH 5.0 is the one feature that threatens the
whole template design.** If a strategy needs an appendage, that appendage becomes part
of the *static* template (fixed content, fixed length, baked in at session start) — it
must never be assembled dynamically on the fast path. If you cannot express what you
need as a static appendage, that order shape goes to the CPU path.

**Note the four variable fields: token, side, shares, price.** That is the entire
mutable surface. Everything else is a constant. This is §7.

### 3.2 Cancel and Replace

| Message | Fields (illustrative) | Note |
| --- | --- | --- |
| **Cancel Order** | Order Token, Shares | ⚠️ Shares = the quantity to *leave*; zero means cancel entirely. **Verify the semantics** — "cancel down to N" vs "cancel N" is exactly the kind of inversion that produces a working-but-wrong design |
| **Replace Order** | Existing Token, **Replacement Token**, Shares, Price, and repeated attributes | ⚠️ Creates a **new** order and a **new** token; the old token dies |

⚠️ **Replace loses queue priority** in the same way an ITCH `U` does (see
[04-totalview-itch-5.0.md](04-totalview-itch-5.0.md) §7). If your reason for replacing
is "improve my price", you were going to lose priority anyway. If your reason is
"reduce size", **use Cancel with a residual quantity instead — a size *reduction* does
not have to cost priority**, whereas a Replace does. ⚠️ Verify this against Rule 4703;
it is a meaningful economic difference.

---

## 4. Outbound messages (server → client)

Carried in SoupBinTCP **Sequenced Data** packets. This is the authoritative record.

| Message | Meaning | FPGA action | Host action |
| --- | --- | --- | --- |
| **Accepted** | Order is live. ⚠️ Contains the **actual resting price** (may differ from sent — price sliding) and the exchange order reference | Update in-flight table: `state=RESTING`, write `resting_price`, **release one credit** | Record; reconcile token |
| **Replaced** | Replace succeeded; new token live | Update table | Reconcile both tokens |
| **Canceled** | Order removed, with a **reason** (user, IOC expiry, halt, SSR, self-match, timeout, …) | `state=DEAD`; release credit | ⚠️ **Log the reason** — the reason distribution is your best health signal |
| **Executed** | A fill: token, executed shares, execution price, match number, liquidity flag (added/removed) | Reduce `leaves_qty`; update position **immediately** | P&L, fee attribution via the liquidity flag |
| **Executed with Reference Price** | A fill priced relative to a reference (peg/midpoint contexts) | As above | ⚠️ Fee treatment differs |
| **Broken Trade** | A prior execution has been busted | ⚠️ **Reverse the position change** | Adjust P&L, alarm |
| **Rejected** | Order refused, with a reason code | `state=DEAD`; release credit; ⚠️ **increment the reject counter for this strategy** | Diagnose; a reject storm must trip a circuit breaker |
| **Cancel Pending** | Cancel received, not yet effective (e.g. order is out on a route) | Keep `state=CANCEL_SENT`; **do not** free the order slot | Track |
| **Cancel Reject** | The cancel could not be applied | ⚠️ Order is **still live** — do not mark it dead | Alarm |
| **AIQ Canceled** | Cancelled by self-match prevention | `state=DEAD` | ⚠️ **Alarm.** SMP firing means your own hardware self-match check ([03](03-order-types-and-routing.md) §4) failed |
| **Trade Correction** | A prior execution's terms were corrected | Adjust position | P&L |
| **Priority Update** | Your resting order's price/display/priority changed without your action (price sliding back, peg re-price) | ⚠️ **Update `resting_price`** | Track |
| **Order Modified** | Modify applied | Update | Track |
| **Restated** | The order's terms were restated by the exchange (e.g. reserve replenishment, re-price) | ⚠️ **Update `resting_price` and `leaves_qty`** | Track |
| **System Event** | Session-level event | Session FSM | Track |

⚠️ **Six of these messages change your resting price or quantity without you asking:**
Accepted (slid), Priority Update, Restated, Executed, Broken Trade, Trade Correction.
**A design that assumes "my order is where I put it" is wrong on Nasdaq.** The
in-flight order table's `resting_price` and `leaves_qty` fields are written *only*
from inbound OUCH messages.

### What the FPGA must parse vs. what the host handles

| Class | Handled in fabric | Rationale |
| --- | --- | --- |
| **Executed** | ✅ Yes | Position must update before the next trigger, or you over-trade |
| **Accepted / Canceled / Rejected** | ✅ Yes (minimally) | Credit release and order-state transition are fast-path invariants |
| **Priority Update / Restated** | ✅ Price field only | Needed for correct quoting |
| Everything else | ❌ Host | Rare, complex, latency-tolerant |

⚠️ Parsing inbound TCP in fabric is easier than sending it (no retransmission logic
needed on receive if the host owns the ACK path), but it is not free. **A common and
defensible simplification: the FPGA parses only `Executed`, `Accepted`, `Canceled` and
`Rejected` by token, and forwards the raw bytes of everything — including those four —
to the host.** The host remains the complete, authoritative record.

---

## 5. Position update: the tightest loop in the system

```
   Executed message arrives
        │
        ├──► FPGA: position[locate] ± executed_shares      (1–2 cycles)
        │           leaves_qty[token] -= executed_shares
        │           credit++
        │
        └──► Host FIFO: full message for P&L and reconciliation
```

⚠️ **The FPGA's position must update from the execution, not from the order.** An
order sent is not a position; only a fill is. But ⚠️ **risk must be checked against
sent-but-unfilled orders too** — otherwise you can send ten orders in the time it
takes the first to be acknowledged and take ten times the intended risk. The standard
answer is that the pre-trade risk block checks against
`position + in_flight_exposure`, where `in_flight_exposure` is incremented at send and
decremented on any terminal outbound message. See
[../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md).

---

## 6. The order token

The order token is **your** identifier for the order. Nasdaq echoes it in every
outbound message about that order. It is the join key between the FPGA's in-flight
table, the host's order database, and the exchange's records.

| Requirement | Detail |
| --- | --- |
| Uniqueness | ⚠️ Must be unique — **verify the exact scope** (per session? per firm per day?) in the OUCH 5.0 spec. Assume the strictest interpretation: **unique per firm per day** |
| Character set | ⚠️ **Alphanumeric / printable**, left-justified and space-padded. You **cannot** stuff raw binary into it |
| Width | Fixed — **verify** (14 bytes in OUCH 4.2; confirm for 5.0) |
| Reuse | ⚠️ Never reuse a token within its uniqueness scope, even for a rejected order |

### A concrete hardware generation scheme

Encode structured information in the token so that the CPU can reconcile any
FPGA-originated order **without a lookup**, and so that a token appearing in a replay
is self-describing.

```
   14 printable characters, hex-encoded  →  56 bits of payload

   ┌────────────┬──────────────────┬──────────────────────────────────┐
   │ strategy   │ symbol locate    │ monotonic counter                │
   │  8 bits    │    16 bits       │            32 bits               │
   │  2 hex ch  │    4 hex ch      │            8 hex ch              │
   └────────────┴──────────────────┴──────────────────────────────────┘
        ▲              ▲                          ▲
        │              │                          └── free-running, reset at start of day
        │              └── ITCH stock locate: reconciles directly against the feed
        └── which strategy block emitted this — attribution with zero lookup

   Example: strategy 3, locate 0x01A4, counter 0x0000BEEF
            →  "0301A40000BEEF"
```

Properties:

| Property | Value |
| --- | --- |
| Encoding cost in fabric | A 4-bit → 8-bit ASCII hex LUT, ×14. **Combinational, ~1 cycle** |
| Uniqueness within a day | Guaranteed by the 32-bit monotonic counter (per strategy+symbol, or global — choose and document) |
| Uniqueness across days | ⚠️ **Not** guaranteed. If the scope requires it, spend bits on a day/session id, or have the host seed the counter's high bits at start of day |
| Reconciliation | ⚠️ **The host can decode any token with pure arithmetic** — no shared table, no race between the FPGA emitting and the host learning about it |
| Debuggability | A token in a log immediately tells you which strategy and which symbol |

⚠️ **The counter must be monotonic across resets within a day.** If the FPGA is
reloaded mid-day and the counter restarts at zero, you will emit duplicate tokens.
**The host must seed the counter on every arm**, and the arm sequence must refuse to
proceed if the seed is not greater than the highest token previously observed.

---

## 7. The pre-built template design

**This is the core latency optimization of the order path.** The observation from §3
is that an Enter Order message is almost entirely constant. So build it once, in
advance, and change only what must change.

### Structure

```
   Per-symbol template BRAM, indexed by ITCH stock locate:

   row[locate] = [ Ethernet hdr │ IPv4 hdr │ TCP hdr │ Soup hdr │ OUCH Enter Order ]
                  ▲              ▲          ▲         ▲          ▲
                  │              │          │         │          │ symbol pre-filled
                  │              │          │         │          │ firm/capacity/TIF/
                  │              │          │         │          │ display/cross/ISO
                  │              │          │         │          │ all pre-filled
                  │              │          │         └── length pre-filled
                  │              │          └── ports, flags pre-filled;
                  │              │              seq/ack/checksum patched at emit
                  │              └── addresses, length, checksum pre-filled
                  └── MACs pre-filled

   Splice at emit time — FOUR fields:
        price   (4 bytes)   ← from the strategy
        shares  (4 bytes)   ← from the strategy
        side    (1 byte)    ← from the strategy
        token   (14 bytes)  ← from the token generator
   Plus, at the TCP layer:
        TCP sequence number (4 bytes)  ← from the send-side sequence register
        TCP checksum        (2 bytes)  ← incrementally updated (§7.2)
```

### 7.1 Why per-symbol rows

The 8-byte stock symbol is the one OUCH field that is a *string*. Building it on the
fly means an ASCII lookup and a space-pad on the critical path. Storing one complete
pre-built frame per tradable symbol makes it a **BRAM read at `locate`** — the same
1-cycle direct index that
[04-totalview-itch-5.0.md](04-totalview-itch-5.0.md) §3 gives you for free.

| Sizing | Value |
| --- | --- |
| Frame length | ~110–130 bytes (Ethernet + IP + TCP + Soup + OUCH). **Verify against the 5.0 field list** |
| Per symbol per order shape | 1 row |
| 200 symbols × 3 order shapes × 128 bytes | ~77 KB → a handful of BRAMs. **Cheap** |
| 8000 symbols × 3 shapes | ~3 MB → URAM territory. ⚠️ Filter your symbol universe |

⚠️ Templates are written by the **host** at session start (and on any change to firm,
capacity, MPID, or session parameters). The fast path has **read-only** access. This
is what makes §8.3's invariants physically unbypassable: the routing byte, the ISO
byte and the cross-type byte are in a region the splice mux cannot address.

### 7.2 Incremental TCP checksum

The TCP checksum is a 16-bit one's-complement sum over a pseudo-header and the
segment. Recomputing it over ~130 bytes is a wide adder tree — avoidable.

```
   The checksum is a sum. Changing a 16-bit word from OLD to NEW changes
   the sum by (NEW − OLD), so:

       csum' = ~( ~csum  −  OLD  +  NEW )        [one's-complement arithmetic,
                                                  with end-around carry]

   Precompute in the template: the checksum of the frame with the mutable
   fields set to ZERO.  At emit, fold in only the words that changed:
       price (2 words), shares (2 words), side+token (8 words),
       TCP sequence number (2 words).
   → ~14 one's-complement additions, a small adder tree, 1 cycle.
```

⚠️ **End-around carry is where this goes wrong.** One's-complement addition folds the
carry back into the low bit. A straight two's-complement adder produces a checksum
that is off by one in a fraction of cases — and a bad TCP checksum means the segment
is silently discarded by the exchange's stack. **You will see no reject, no error, and
no fill: the order simply never happened.** Test this exhaustively in simulation
against a reference implementation; it is one of the highest-value testbenches in the
project. See [../02-networking/02-ip-udp-tcp-in-hardware.md](../02-networking/02-ip-udp-tcp-in-hardware.md).

### 7.3 Illustrative latency budget

| Stage | Cycles @ 156.25 MHz | ns |
| --- | --- | --- |
| Strategy fires → order request valid | — | (strategy budget) |
| Template BRAM read | 2 | ~13 |
| Token generation (counter + hex encode) | 1 | ~6 |
| Field splice (price/shares/side/token) | 1 | ~6 |
| TCP seq + incremental checksum | 1 | ~6 |
| Risk + state gate (**parallel** with the above) | 2 | ~13 |
| Handoff to MAC TX | 1 | ~6 |
| **Encode total** | **~6** | **~40 ns** |
| MAC + PCS + SerDes + serialization (~130 B) | — | ~150–250 ns |

⚠️ **Design targets to be measured, not measurements.** Note the shape: **the
encoder is a small fraction of the wire-side cost.** Once the encode is ~40 ns,
further encoder optimization is wasted effort — the next win is in the MAC, the PHY
and the cable. This is the discipline demanded by
[../05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md).

---

## 8. The cancel path

⚠️ **Cancel latency frequently matters more than entry latency**, and it is the path
most often neglected.

Why:

| Situation | Consequence of slow cancel |
| --- | --- |
| The market moves against your resting quote | You are **picked off** — adverse selection is *exactly* the latency of your cancel |
| A halt or LULD limit state begins | Your quote is exposed at a stale price |
| Risk limit breached | You cannot stop the bleeding |
| Kill switch pulled | ⚠️ Regulatory: the kill switch must stop flow within a **bounded, documented** time (CLAUDE.md hard rule 6) |

You can be beaten to a new price by a faster firm and lose nothing but opportunity.
You can be beaten on a cancel and lose real money on every resting order you own.

### Pre-built cancel templates

A Cancel Order message is even more constant than an Enter Order — typically just a
token and a quantity:

```
   Cancel template (one, or one per symbol if the frame carries no symbol):

     [ Ethernet │ IPv4 │ TCP │ Soup hdr │ Cancel Order: type, TOKEN, SHARES ]
                                                        ▲       ▲
                                                        │       └── 0 = full cancel
                                                        └── from the in-flight table

   Splice = token (14 B) + shares (4 B) + TCP seq + checksum.
   → the same ~6 cycles, and it can be a SEPARATE, higher-priority path
     into the TX arbiter.
```

**Project rule: the cancel path gets priority 0 in the TX arbiter**, ahead of new
orders. A fixed-priority arbiter with cancels at the top is the right structure
([../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) §4)
— starving new orders during a mass cancel is exactly the behaviour you want.

### Mass cancel

⚠️ Cancelling every resting order one message at a time is slow and consumes the
entire message-rate allowance at the worst possible moment.

| Mechanism | Notes |
| --- | --- |
| Iterate the in-flight table, emit one cancel per live token | Always available; bounded by table size × message rate. **Measure the worst case and document it** |
| Venue-provided mass-cancel / purge facility | ⚠️ **Verify** whether Nasdaq offers one on the OUCH port and what its scope and semantics are |
| **Cancel-on-disconnect** | ⚠️ See §10 |
| Kill switch → stop *new* orders instantly, then drain cancels | The hardware kill switch must do the first part in a bounded number of cycles regardless of the second |

---

## 9. Message rate limits and TCP retransmission

### Rate limits

Nasdaq applies limits to order-entry message rates and publishes fee structures that
penalise excessive messaging relative to executions.

> **Verify** the current order-entry rate thresholds, any burst allowances, and the
> messaging/order-to-trade fee provisions in **the Nasdaq Price List
> (nasdaqtrader.com)** and the relevant rulebook sections. **These are real limits
> with real costs; do not design a strategy that assumes unlimited messaging.**

Enforce in fabric, because the fast path can outrun any software limiter:

```systemverilog
// Token-bucket rate limiter, per OUCH session.
// Refill and burst are host-writable registers.
logic [31:0] bucket_q;
always_ff @(posedge clk) begin
    if (refill_tick && bucket_q < BURST_MAX) bucket_q <= bucket_q + REFILL;
    else if (msg_sent)                       bucket_q <= bucket_q - 32'd1;
end
wire rate_ok = (bucket_q != 0);
// ⚠️ Cancels should be allowed to bypass (or use a separate bucket).
// Being rate-limited out of cancelling is the worst possible failure mode.
```

⚠️ **Count every message suppressed by the rate limiter.** A strategy that is silently
throttled looks like a strategy that is not finding opportunities.

### TCP retransmission

⚠️ **A design decision that must be made explicitly and written down.** Options:

| Option | Trade-off |
| --- | --- |
| FPGA sends; **host** owns retransmission (host snoops the TX stream, buffers, and retransmits on missing ACK) | Simplest fabric; retransmission is slow but retransmission is already a lost race |
| FPGA implements a minimal retransmit buffer | More fabric, bounded complexity, faster recovery |
| Full TOE in fabric | ⚠️ Large, and its benefit is on the *receive* side, which is not our critical path |

⚠️ **Whatever you choose, an unretransmitted lost segment is an order whose fate you
do not know.** Do not treat "sent to the MAC" as "delivered". The in-flight table's
`SENT` state must have a timeout, and a timeout must alarm — not silently expire.

---

## 10. Cancel-on-disconnect

Nasdaq order-entry ports can be configured so that resting orders are cancelled
automatically when the session disconnects.

> ⚠️ **Verify** whether cancel-on-disconnect is available on your OUCH port, whether
> it is opt-in, its scope (which order types are cancelled — day orders? all?), and
> the timing, with **Nasdaq** directly and in the OUCH documentation.

| If enabled | If not enabled |
| --- | --- |
| A dropped session is *relatively* safe — orders are pulled | ⚠️ A dropped session leaves **live orders in the market you cannot cancel** |
| ⚠️ A transient network blip **cancels your whole book**, destroying every queue position you own | You must have an out-of-band cancel capability (a second session, a phone number, the exchange's help desk) |

**Neither is a substitute for a working cancel path.** Cancel-on-disconnect is a
backstop with a latency measured in seconds. Assume it exists, verify it works during
conformance testing, and design as though it does not.

---

## 11. ⚠️ The reconciliation requirement

**The FPGA can emit orders faster than the host can account for them.** At a 40 ns
encode and a PCIe/DMA notification path measured in microseconds, a runaway strategy
can put hundreds of orders into the market before the host observes the first one.
This is the classic hardware-trading failure mode and it must be structurally
prevented, not monitored.

### Credit-bounded in-flight orders

```
   Host grants CREDITS = maximum number of orders that may be
                         outstanding-and-unaccounted at any instant.

   FPGA:  emit order  →  credit--        (blocking: no credit ⇒ no send)
          terminal outbound OUCH
          (Accepted-then-Canceled / Executed-fully / Rejected)
                     →  credit++

   Host:  may raise or lower the credit ceiling at any time.
          Lowering it to zero is a soft kill switch.
```

| Property | Value |
| --- | --- |
| Latency cost in the common case | **Zero** — a single register compare, in parallel with the template read |
| Worst case | Emission blocks. ⚠️ **That is the intent.** Count every blocked order |
| Failure mode it prevents | Unbounded order emission from a strategy bug, a feed glitch, or a decode error |
| Related pattern | [../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) §8 |

⚠️ **Credit leaks are silent.** If a terminal message is missed, the credit is never
returned and the path slowly throttles to zero — which looks like a market with no
opportunities, not like a bug. Mitigations: a host-readable credit register, a
`credit_min_observed` watermark, an alarm on credits below a threshold, and a
host-initiated periodic full re-sync that recomputes credits from the authoritative
sequenced stream.

---

## 12. Hardware implications

### 12.1 Block inventory

| Block | Function |
| --- | --- |
| Template BRAM | Per-symbol, per-order-shape pre-built frames. Host-written, fabric read-only |
| Token generator | Counter + hex encode. Host-seeded at arm |
| Field splice | 4-field byte-lane mux into the template stream |
| TCP send state | Sequence number register, incremental checksum, retransmit hook |
| Risk + state gate | Halt / LULD / SSR / size / notional / self-match / credit — [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) |
| Rate limiter | Token bucket, separate bucket for cancels |
| TX arbiter | ⚠️ Fixed priority: **cancel > kill-switch cancels > new orders > heartbeats** |
| In-flight order table | `token → {locate, side, sent_price, resting_price, leaves_qty, state, strategy}` |
| Inbound OUCH decoder | Executed / Accepted / Canceled / Rejected by token |
| Host FIFO | Every inbound and outbound message, raw, for the authoritative record |

### 12.2 Invariants enforced in hardware

| Invariant | How |
| --- | --- |
| No routing, no ISO, no auction cross type from fabric | Those bytes live in the read-only template region |
| No market orders | Price field mandatory and non-zero |
| Bounded in-flight orders | Credit counter (§11) |
| Bounded message rate | Token bucket (§9) |
| Cancels are never starved | TX arbiter priority + separate rate bucket |
| Kill switch stops new orders in bounded cycles | Gate at the TX arbiter input, not inside the strategy |
| Token uniqueness | Host-seeded monotonic counter; arm refuses a non-increasing seed |
| Resting price is never assumed | `resting_price` writable only from inbound OUCH |

### 12.3 Mandatory counters

`orders_sent`, `cancels_sent`, `orders_accepted`, `orders_rejected[reason]`,
`orders_canceled[reason]`, `executions`, `aiq_cancels`, `cancel_rejects`,
`credit_blocked`, `credit_min_observed`, `rate_limited`, `risk_blocked[check]`,
`token_collisions`, `unknown_token_inbound`, `tcp_retransmits`,
`send_timeouts`, `heartbeat_misses`.

⚠️ `unknown_token_inbound` is the direct analogue of ITCH's `unknown_order_ref`: an
outbound message referencing a token the FPGA does not have means the in-flight table
and the exchange disagree. **Nonzero means stop and reconcile.**

### 12.4 Testing this path

- ⚠️ **Never point a build at a live venue** (CLAUDE.md §6). Conformance and UAT
  endpoints only.
- Byte-exact golden-vector tests: given a strategy trigger, the emitted frame must
  match a reference encoder byte for byte, **including checksums**.
- Exhaustive incremental-checksum tests against a reference implementation.
- Replay tests: feed a recorded ITCH day, capture emitted OUCH, replay a recorded
  outbound OUCH stream, and confirm the in-flight table converges to the host's.
- Fault injection: dropped ACKs, mid-message disconnects, out-of-order outbound
  replay, credit exhaustion, rate-limit saturation, kill switch during a burst.
- Nasdaq requires **certification/conformance testing** before enabling a port.
  ⚠️ **Verify the current certification requirements and test-script contents with
  Nasdaq.** See [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md).

---

## Further reading

- [03-order-types-and-routing.md](03-order-types-and-routing.md) — what the fields mean semantically
- [04-totalview-itch-5.0.md](04-totalview-itch-5.0.md) — the input side of the pair
- [02-sessions-auctions-and-halts.md](02-sessions-auctions-and-halts.md) — the state gates every order passes
- [../03-algotrading/04-order-entry-protocols.md](../03-algotrading/04-order-entry-protocols.md) — venue-neutral theory
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — the gate and the kill switch
- [../02-networking/02-ip-udp-tcp-in-hardware.md](../02-networking/02-ip-udp-tcp-in-hardware.md) — TCP in fabric and checksums
- [../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) — credit flow control, arbiters
