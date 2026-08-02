# 03.03 — Market Data Protocols

> **Why this matters here:** decode is the *first* thing in the tick-to-trade path and
> therefore the first thing that can ruin it. A protocol whose field offsets are known
> at compile time decodes in a wire, in zero cycles. A protocol whose field offsets
> depend on the bytes you just read decodes in a state machine, serially, at maybe one
> field per cycle. **The choice of feed encoding sets the floor on our latency before
> we have written a line of strategy logic.**

The message-level ITCH reference — every message type, every field, every offset —
lives in [../08-nasdaq/04-totalview-itch-5.0.md](../08-nasdaq/04-totalview-itch-5.0.md).
This document is about the *shapes* of market data and what each costs in fabric.

---

## 1. The four encoding families

| Family | Example | Structure | Field offset known at compile time? |
| --- | --- | --- | --- |
| **Fixed-offset binary** | Nasdaq **TotalView-ITCH 5.0**, Cboe PITCH | One byte of message type, then a fixed layout per type. Big-endian integers. Fixed length per type. | **Yes** — after 1 byte |
| **Templated binary (SBE)** | CME **MDP 3.0**, iLink 3 | Fixed root block per template ID, plus repeating groups with runtime counts, plus variable-length fields | Root block: yes. Groups: **no** |
| **Tag-value ASCII** | **FIX 4.x / 5.x** | `35=D\x0155=AAPL\x0138=100\x01…` — variable order, variable length, ASCII numerics | **No** |
| **Compressed binary** | **FAST** (FIX Adapted for STreaming) | Presence bitmap + per-field operators (copy/delta/increment/default) + stop-bit variable-length integers | **No — and not even after the previous field** |

### Decode difficulty in hardware

| Encoding | Field extraction | Length determination | Typical decode latency | Resource cost | Line-rate at 10G? |
| --- | --- | --- | --- | --- | --- |
| **Fixed-offset binary** | Pure wiring from a wide register — combinational, **0 cycles of logic** | Type → ROM lookup, 1 cycle | **1–3 cycles** (≈ 6–20 ns) | Small: a mux tree | Trivially |
| **Templated SBE** | Root block is fixed; groups need a counted loop | Header carries block length; groups computed | **5–20 cycles**, data-dependent | Moderate: group iterator FSM | Yes, with effort |
| **Tag-value FIX** | Scan for `\x01`, parse `tag=`, ASCII→binary convert, dispatch on tag | Body length field, then trust it | **~1 byte/cycle** → 10s–100s of cycles | Large: comparators, ASCII converters, tag dispatch | Painful |
| **FAST** | Decode PMAP, then apply per-field operator against a *previous-message dictionary*, stop-bit VLQ | Only after decoding everything | **Serial by construction**, 100s of cycles | Large: dictionary RAM + operator ALU | ⚠️ Effectively no |

### The argument, stated plainly

**Fixed-offset binary is the only encoding that is genuinely FPGA-native.** When
message type `A` always puts the price at bytes 32–35, extracting the price is
*literally wire routing* from a shift register — no logic, no cycles, no state. You can
decode every field of every message type **in parallel, speculatively**, and discard
what the type byte says is irrelevant. Speculation is free because fabric is spatial:
unused mux inputs cost LUTs, not time.

**FAST is actively hostile to hardware, by design rather than by accident.** It was
built to save *bandwidth* when bandwidth was the binding constraint, and every one of
its techniques converts bits saved into serial dependency: field N's offset is unknown
until field N−1 is fully decoded (stop-bit VLQ); a field's *value* may come from the
previous message via a copy/delta/increment operator, requiring a **stateful dictionary
per template per instrument** — a memory read on the critical path; and the presence map
must be decoded before you know which fields exist at all. There is no parallelism to
extract. You can build a FAST decoder in an FPGA, but it is a serial byte-processing
machine that throws away the entire structural advantage of the technology.

**Tag-value FIX is nearly as bad** for market data: variable field order means
content-addressable dispatch per field, and ASCII numerics mean a multiply-accumulate
per digit. FIX for *market data* is a non-starter; FIX for *order entry* is survivable
only because outbound messages come from templates
([04-order-entry-protocols.md](04-order-entry-protocols.md) §6).

> **Rule for this project:** the fast path consumes **fixed-offset binary market data
> only** (Nasdaq TotalView-ITCH 5.0); CME MDP 3.0 / SBE is a supported secondary shape
> because it is the other structure worth learning. Any FAST or tag-value FIX feed, if
> ever required, is decoded on the **CPU** and reaches the FPGA only as pre-digested
> parameters — never as a fast-path input.

---

## 2. Anatomy of a fixed-offset binary message

ITCH 5.0 is carried inside **MoldUDP64** over UDP multicast:

```
 UDP payload
┌──────────────────────────────────────────────────────────────────────────┐
│ MoldUDP64 downstream packet header                                        │
│   Session      10 bytes  (ASCII, identifies the day's stream)             │
│   SeqNum        8 bytes  (sequence of the FIRST message in this packet)   │
│   MsgCount      2 bytes  (how many message blocks follow; 0 = heartbeat)  │
├──────────────────────────────────────────────────────────────────────────┤
│ Message block 1:  Len (2 bytes, big-endian) │ ITCH message (Len bytes)    │
│ Message block 2:  Len (2 bytes)             │ ITCH message                │
│ …                                                                         │
└──────────────────────────────────────────────────────────────────────────┘
```

And an ITCH message itself:

```
 offset  0        1        3        5                     11 …
        ┌────────┬────────┬────────┬──────────────────────┬─────────────────┐
        │ Type   │ Stock  │ Track  │ Timestamp            │ type-specific   │
        │ 1 B    │ Locate │ Number │ 6 B, ns since        │ fixed layout    │
        │ ASCII  │ 2 B    │ 2 B    │ midnight (Eastern)   │                 │
        └────────┴────────┴────────┴──────────────────────┴─────────────────┘
```

Everything after byte 0 is at a **constant offset for a given type** — the decode
primitive:

```systemverilog
// Message length is a pure function of the type byte → a small ROM.
// Fully combinational; the "decoder" is a lookup, not a state machine.
function automatic logic [7:0] itch_msg_len(logic [7:0] msg_type);
    case (msg_type)
        "A": return 8'd36;   // Add Order (no MPID)
        "F": return 8'd40;   // Add Order with MPID
        "E": return 8'd31;   // Order Executed
        "C": return 8'd36;   // Order Executed With Price
        "X": return 8'd23;   // Order Cancel (partial)
        "D": return 8'd19;   // Order Delete (full)
        "U": return 8'd35;   // Order Replace
        default: return 8'd0;  // unknown → SKIP using the Mold length, and COUNT it
    endcase
endfunction

// Field extraction from a message held in a wide register: wiring, not logic.
// Big-endian on the wire ⇒ byte-reverse at the register boundary, once.
assign order_ref = msg_be[36*8-1 -: 64] ;   // A: bytes 11..18
assign side      = msg_be[  ... ];          // A: byte 19  ('B' / 'S')
assign shares    = msg_be[  ... ];          // A: bytes 20..23
assign stock_id  = stock_locate;            // dense 16-bit index — use it directly
assign price_i   = msg_be[  ... ];          // A: bytes 32..35, 4 implied decimals
```

> **Verify:** the byte lengths and field offsets above are illustrative. Take them
> from the current **Nasdaq TotalView-ITCH 5.0 specification** and encode them in one
> generated header shared by RTL, testbench, and host software — never transcribed
> twice by hand. See [../08-nasdaq/04-totalview-itch-5.0.md](../08-nasdaq/04-totalview-itch-5.0.md).

⚠️ **Never derive the message length from your own type table alone.** Advance using the
MoldUDP64 per-block length; use the type table only to decode. When the venue adds or
extends a message type — they do, at version boundaries — a length-from-type parser
desynchronises and shreds the rest of the packet, while a length-from-Mold parser skips
one unknown message and continues. **Unknown types are skipped and counted, never
errored on and never guessed at.**

---

## 3. Order-based vs. level-based feeds

This distinction determines the entire book design. It deserves the space.

### Order-based (MBO — market by order)

The feed describes **individual orders**, identified by reference number.

```
A  ref=1001  buy 300 @ 1908500          add order 1001
E  ref=1001  executed 100               order 1001 now has 200
X  ref=1001  cancelled 50                order 1001 now has 150
D  ref=1001                              order 1001 gone
U  ref=1001 → 1005, 200 @ 1908400        replace (new reference!)
```

You receive **no price levels at all**. The book is something *you* construct.

| Hardware requirement | Structure | Cost |
| --- | --- | --- |
| `order_ref (64-bit) → {stock, side, price, qty}` | Set-associative hash table in BRAM/URAM | Large: millions of live refs × ~16 B. Usually the biggest memory in the design. |
| Aggregate size per price level | Incrementally maintained array indexed by price offset | One add/sub per message |
| Best bid / best ask | Registers, updated incrementally | Cheap in the common case; re-scan on best-level deletion |
| Our own queue position | Per-own-order `shares_ahead` counter | Only possible *because* the feed is order-based |

**What you get for that cost — and it is a lot:** **queue position is computable** (you
know exactly how much size was added to a level before your order and how much has
since executed or cancelled — the input to the entire economics in
[01-market-microstructure.md](01-market-microstructure.md) §2, and **a level-based feed
cannot give you this**); every order's arrival, modification, and death is visible, the
raw material for order-flow and toxicity models; and the book is exact, not sampled.

### Level-based / aggregated (MBP — market by price)

The feed describes **price levels**, usually top-N.

```
Level Update: side=BID  level=1  price=1908500  size=700  order_count=4
Level Update: side=BID  level=1  price=1908500  size=400  order_count=3
Level Delete: side=BID  level=3
```

**The hardware does far less:** a small array of N levels per side, written directly from
the message. No reference-number table, no hash; often the whole book fits in registers.

**What you lose:** **queue position becomes unknowable** — a level going from 700 to
400 could be a cancel ahead of you (good, you moved up), an execution, or a cancel
behind you (irrelevant), and you cannot tell which. For a FIFO market maker that is
close to fatal. Depth beyond level N is invisible, and some venues *conflate* level
updates, giving you a sampled book (§8).

### Side by side

| | **Order-based (ITCH)** | **Level-based (MBP)** |
| --- | --- | --- |
| Book construction | You build it | Venue built it |
| Memory in fabric | Large — ref table dominates | Small — an array |
| Decode complexity | Low (fixed offsets) | Low |
| Book update complexity | **High** — hash lookup on the critical path | Trivial |
| Message rate | **Higher** — every order event | Lower — only net level changes |
| Queue position | **Available** | Impossible |
| Hidden liquidity | Visible as untagged trade prints | Usually invisible |
| Suits | Market making, queue-aware strategies | Taking, signals from top-of-book |

**Rule for this project:** we build an **order-based book from TotalView-ITCH**. The
reference-number table is the memory-architecture centrepiece and the main consumer of
URAM; its lookup is on the critical path and must be **bounded and fixed**
(set-associative with a small overflow CAM — never a probing loop with data-dependent
latency). See
[../04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md)
and [../01-fpga-design/03-memory-and-storage.md](../01-fpga-design/03-memory-and-storage.md).

---

## 4. Channel types: incremental, snapshot, refresh

| Channel | Content | Rate | Role |
| --- | --- | --- | --- |
| **Incremental** | Every event, in sequence | Full rate, bursty | **The fast path.** Everything else is recovery. |
| **Snapshot / recovery** | Periodic full book state, or on-demand point-in-time state | Low, or on request | Cold start and gap recovery |
| **Retransmission** | Replay of a specific sequence range on request | On demand, unicast | Small-gap recovery |
| **Instrument / reference** | Symbol directory, tick sizes, trading status, corporate actions | Once at start of day + updates | Slow path only — build the symbol tables from it |

Nasdaq provides the incremental TotalView-ITCH stream over MoldUDP64 multicast on
redundant **A and B lines**, a **retransmission (re-request) service**, and a
point-in-time snapshot service.

> **Verify:** recovery service addresses, request formats, request rate limits, and
> entitlements are in the Nasdaq MoldUDP64 / TotalView-ITCH specs and the connectivity
> documentation —
> [../08-nasdaq/08-connectivity-and-colocation.md](../08-nasdaq/08-connectivity-and-colocation.md).

### The partitioning rule

```
FPGA  ──►  incremental channel only. Line rate. No requests, no state machines
                                     that talk back to the venue.
CPU   ──►  snapshot, retransmission, reference data, and the decision to declare
           a symbol or the whole feed UNUSABLE.
```

⚠️ **The FPGA must never initiate a recovery request.** Recovery is slow,
request/response, retry-with-backoff logic that does not belong in a fixed-latency
datapath. The FPGA detects the gap in one cycle, raises a flag, **stops trading the
affected scope**, and lets the CPU sort it out.

---

## 5. Sequence numbers, gaps, and A/B arbitration

MoldUDP64 carries a **per-session sequence number counting messages, not packets**.
A packet header says "this packet starts at message N and contains M messages", so the
next expected sequence is `N + M`.

```
expected_seq == pkt.seq              →  in order. Process. expected_seq += pkt.count
pkt.seq  <  expected_seq             →  duplicate/late (normal on the B line). DROP.
pkt.seq  >  expected_seq             →  GAP of (pkt.seq − expected_seq) messages.
```

### A/B line arbitration

The venue sends two identical streams on separate multicast groups over separate network
paths; the receiver takes whichever copy arrives first.

```
        A line ──►┐
                  ├──► sequence-keyed de-dup / first-wins arbiter ──► decode
        B line ──►┘
```

**First-wins, not merge**: a small latency gain (whichever path won this packet) and,
far more importantly, single-path loss tolerance. It is a stateless comparison against
`expected_seq` plus a small reordering window — cheap in fabric. Detail in
[../02-networking/03-multicast-feeds-and-arbitration.md](../02-networking/03-multicast-feeds-and-arbitration.md).

### Gap policy

| Gap size / duration | Response |
| --- | --- |
| Filled from the other line within the reorder window | Nothing. Count it. |
| Small, recoverable by retransmission (CPU) | **Halt trading in all affected symbols immediately.** Resume only after the CPU confirms the book is whole. |
| Large, or snapshot required | Halt trading globally, rebuild from snapshot, resume on explicit operator or CPU release |
| Session ID change / sequence reset | Treat as a new session. Full rebuild. |

⚠️ **A gap means your book is wrong, and a wrong book quotes confidently at the wrong
price.** No "trade through a small gap" policy is safe. On gap detection the FPGA
**pulls all quotes for the affected scope within a bounded number of cycles** — the same
fail-closed reflex as the kill switch, sharing the same mechanism.
See [06-risk-and-compliance.md](06-risk-and-compliance.md) §8.

---

## 6. Timestamps in feeds, and how much to trust them

| Timestamp | Set by | Trust for |
| --- | --- | --- |
| ITCH message timestamp (ns since midnight, ET) | The **venue**, somewhere in *its* pipeline | Ordering, audit, cross-day analysis. **Not** our latency. |
| MoldUDP64 sequence number | Venue sequencer | Ordering — authoritative, better than any timestamp |
| **Our hardware RX timestamp** | Our MAC/PHY, at frame boundary | **Everything latency-related.** The only clock we control. |
| Our hardware TX timestamp | Our MAC, on transmit | The far end of the tick-to-trade measurement |

Three cautions: **(1)** venue timestamps have unknown and variable offset from the wire
— they are assigned inside the matching engine or feed publisher, so `venue_ts −
our_rx_ts` is network latency *plus* an unknown publisher delay *plus* clock offset,
not network latency; **(2)** timestamp *resolution* is not timestamp *accuracy* —
nanosecond granularity does not imply nanosecond clock discipline; **(3)** timestamps
can be non-monotonic across message types or channels, so never sort by timestamp —
sort by sequence number.

**Rule for this project:** all latency measurement uses **our own hardware timestamps at
the PHY/MAC boundary**, taken at a single documented reference point (first bit of frame
after preamble, consistently). Venue timestamps are recorded for the audit trail and
never used in a control decision. Clock discipline (PTP/GPS) is in
[../06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md).

> **Verify:** business-clock synchronisation obligations for order-event recording (CAT
> / FINRA Rule 4590 and the CAT NMS Plan) specify tolerances relative to NIST and differ
> by system type — [06-risk-and-compliance.md](06-risk-and-compliance.md) §7.

---

## 7. Message rates, bursts, and how to size

Average message rate is a useless design input. **The design input is peak burst at
line rate.**

```
10GbE, minimum-size 64-byte Ethernet frames (+20 B IFG/preamble)
    →  ~14.88 million frames/sec

One 1500-byte MoldUDP64 packet can carry ~40 ITCH messages of ~35 bytes
    →  ~820 000 packets/sec × 40  ≈  33 million ITCH messages/sec at line rate
```

That is the number the RX path must survive. Not the venue's published peak, not last
year's high-water mark — **the wire's capacity**.

**Rule for this project:** the RX and decode path sustains **wire line rate with the
smallest legal message**, with no backpressure, forever. If it can do that, no market
event can overrun it — which removes an entire category of capacity planning and an
entire category of production incidents.

| Burst source | Character |
| --- | --- |
| Opening cross and the minutes after | Highest sustained rate of the day; every symbol at once |
| Closing cross | Comparable; concentrated in the last minutes |
| Scheduled macro releases | Sharp, correlated, all symbols, sub-second |
| Single-name news / halt resumption | Extreme rate in *one* symbol — a per-symbol structure can be overrun while the aggregate is fine |
| LULD band updates, MWCB events | Status bursts that also change trading semantics |

⚠️ **Bursts correlate with the moments your quotes are most exposed.** A design that
degrades under load degrades exactly when being slow is most expensive. That is why the
answer is "size for line rate", not "size for p99.9 and add margin".

> **Verify:** cite Nasdaq's published TotalView message-rate statistics for capacity
> documentation rather than a remembered figure. Feed rates grow year over year.

---

## 8. Conflation — and why it is forbidden on the fast path

**Conflation** is collapsing multiple updates into one: instead of every book change,
you receive the *latest state* at some interval. Vendor feeds, GUI feeds, and many
"low bandwidth" feed options do this.

It is fatal for three separate reasons: **(1)** it destroys the trigger — our edge is
reacting to a specific event (a level created, a quote consumed), and a conflated feed
gives you the outcome, late; **(2)** it destroys queue-position tracking, because
`shares_ahead` is computed by applying *every* execution and cancellation ahead of us in
order, and collapsing two messages leaves the counter permanently wrong (§3); **(3)** it
adds latency by definition — the conflation interval *is* the delay you accept.

⚠️ Conflation also appears **inside your own design** as an emergent bug: a FIFO that
drops on overflow, an "update the book, notify the strategy only if top-of-book changed"
optimisation, or a strategy that samples the book on a timer. The last is the sneakiest
— it looks like a clean design and it is a conflated feed with extra steps.

**Rule for this project:** every book-mutating message produces a strategy evaluation
opportunity. If the strategy engine cannot keep up with line rate, that is a design
defect to be fixed, not a case for sampling.

---

## 9. Decode pipeline sketch

```
 ┌──────────┐   ┌────────────┐   ┌───────────────┐   ┌──────────────┐
 │ PHY/MAC  │──►│ Eth/IP/UDP │──►│  MoldUDP64    │──►│  Message     │
 │ RX       │   │ header     │   │  header strip │   │  splitter    │
 │ + RX ts  │   │ strip +    │   │  + seq check  │   │ (len-prefix) │
 │          │   │ filter     │   │  + A/B arb    │   │              │
 └──────────┘   └────────────┘   └───────┬───────┘   └──────┬───────┘
   ~0 cyc          1–2 cyc          1–2 cyc  │gap flag      │ 1 msg/cyc
                                             ▼              ▼
                                    ┌─────────────┐  ┌──────────────────┐
                                    │ GAP HANDLER │  │  TYPE DISPATCH   │
                                    │ → quote pull│  │  + PARALLEL      │
                                    │ → CPU intr  │  │    FIELD EXTRACT │
                                    └─────────────┘  │  (combinational) │
                                                     └────────┬─────────┘
                                                              │ 0–1 cyc
                                    ┌─────────────────────────▼─────────┐
                                    │ SYMBOL FILTER (stock_locate →     │
                                    │ dense slot; not-of-interest = drop)│
                                    └─────────────────────────┬─────────┘
                                                              │ 1 cyc (BRAM)
                                    ┌─────────────────────────▼─────────┐
                                    │ ORDER-REF TABLE  (hash, set-assoc)│
                                    │ bounded, fixed latency            │
                                    └─────────────────────────┬─────────┘
                                                              │ 2–3 cyc
                                    ┌─────────────────────────▼─────────┐
                                    │ BOOK UPDATE (level aggregate,     │
                                    │ best-price maintenance)           │
                                    └─────────────────────────┬─────────┘
                                                              ▼
                                                        STRATEGY TRIGGER
```

Design notes:

- **Extract all candidate fields in parallel, before dispatch.** The type byte selects
  which extraction is *meaningful*; it must not gate *when* extraction happens. Parallel
  extraction costs LUTs, serial extraction costs nanoseconds — we buy nanoseconds with
  LUTs throughout this project.
- **Filter early.** Dropping untraded symbols right after the symbol lookup removes them
  from every downstream structure's bandwidth requirement.
- **The order-ref table is the only variable-cost stage.** Make it fixed-cost by
  construction (§3) so the pipeline has one quotable latency.
- **Carry the RX timestamp through the pipe** to the order encoder. That plus the TX
  timestamp is the tick-to-trade measurement.

Per-stage budgets are in
[../05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md);
the implementation is
[../04-system-architecture/02-feed-handler-design.md](../04-system-architecture/02-feed-handler-design.md).

---

## 10. Rules for this project

1. Fast path consumes **fixed-offset binary only** (TotalView-ITCH 5.0 over MoldUDP64).
2. Message boundaries come from the **MoldUDP64 length prefix**; the type table is used
   only for decode.
3. **Unknown message types are skipped and counted.** Never fatal, never guessed.
4. Field offsets come from **one generated header** shared by RTL, testbench, and host.
5. RX path sustains **wire line rate with minimum-size messages**, with no backpressure.
6. Any sequence gap ⇒ **immediate quote pull for the affected scope**, plus a CPU
   interrupt. The FPGA never requests recovery.
7. **No conflation anywhere**, including emergent conflation from timers or
   drop-on-overflow FIFOs.
8. Latency is measured with **our own PHY-boundary timestamps**; venue timestamps are
   audit data only.
9. The order-reference table has **bounded, fixed lookup latency**. No probing loops.

---

## Further reading

- [01-market-microstructure.md](01-market-microstructure.md) — what the decoded messages mean
- [04-order-entry-protocols.md](04-order-entry-protocols.md) — the same problem in the outbound direction
- [../02-networking/03-multicast-feeds-and-arbitration.md](../02-networking/03-multicast-feeds-and-arbitration.md) — A/B arbitration and gap detection in detail
- [../04-system-architecture/02-feed-handler-design.md](../04-system-architecture/02-feed-handler-design.md) — the implementation of §9
- [../04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md) — the structures §3 demands
- [../08-nasdaq/04-totalview-itch-5.0.md](../08-nasdaq/04-totalview-itch-5.0.md) — every ITCH message, field by field
