# 08.04 — Nasdaq TotalView-ITCH 5.0

> **Why this matters here:** this is the input to everything. Every nanosecond of the
> tick-to-trade budget starts when the first bit of an ITCH message hits the SerDes.
> ITCH 5.0 is, for our purposes, close to an ideal hardware protocol — **fixed-length
> messages, fixed field offsets, big-endian integers, and a dense integer symbol key**
> — which means the feed handler can be a fixed-offset extractor with a type-dispatch
> mux and no parsing state machine at all. This document is the decoder reference.

> ⚠️ **Verify everything numeric in this document.** Message type characters, field
> orders, field widths, byte offsets, message lengths and enumeration values are all
> defined by the **Nasdaq TotalView-ITCH 5.0 specification
> (nasdaqtrader.com/Trading/TradingSpecs)**. The specification is versioned and
> amended. **Tables in this document that give offsets or lengths are labelled
> "structure illustrative — confirm offsets against the spec PDF before implementing".**
> Structure, semantics and algorithms below are stable and can be trusted; the numbers
> must be checked once, against the PDF, and then locked into a single generated
> header shared by RTL, testbench and host.

---

## 1. The Nasdaq market data product family

| Product | Depth | Granularity | Transport | Use for us |
| --- | --- | --- | --- | --- |
| **TotalView-ITCH** | **Full depth of book** | **Order-by-order** — every add, execute, cancel, delete, replace | MoldUDP64 multicast | ✅ **This is our feed** |
| Nasdaq Level 2 | Aggregated depth by market participant | Quote-level | Various | ❌ Aggregated; loses queue detail |
| Nasdaq Basic | Top of book + last sale for Nasdaq | Quote-level | Various | ❌ Insufficient depth |
| **BX ITCH / PSX ITCH** | Full depth for those markets | Order-by-order | MoldUDP64 multicast | ✅ If we trade those markets — **separate feeds, separate locate namespaces** |
| UTP SIP (UQDF/UTDF) | Consolidated top of book + last sale, all venues | Quote-level | SIP | ⚠️ Slow path only |
| Nasdaq Options (ITTO etc.) | Options depth | | | Out of scope here |

**Why order-by-order matters.** An aggregated feed tells you *there are 500 shares at
190.85*. An order-by-order feed tells you *there are four orders totalling 500 shares,
and yours is third*. Queue position is the entire economic basis for a passive
strategy ([../03-algotrading/01-market-microstructure.md](../03-algotrading/01-market-microstructure.md) §2),
and it is only computable from an order-by-order feed.

⚠️ TotalView-ITCH shows **all displayed orders anonymously**. Attribution (MPID) is
present only on the Add Order **with MPID** variant. You cannot generally tell which
resting order is yours from ITCH alone — you know it from the OUCH acknowledgement.
Matching your own orders to ITCH order reference numbers is a *slow-path*
reconciliation exercise, not something the fast path attempts.

---

## 2. Transport: MoldUDP64 over UDP multicast

ITCH messages do not appear alone on the wire. They are carried inside **MoldUDP64**
packets over **UDP multicast**, published on **redundant A and B feeds**.

```
   Ethernet (14) │ IPv4 (20) │ UDP (8) │ ─────── MoldUDP64 downstream packet ───────
                                        ┌──────────────────────────────────────────┐
                                        │ Session          10 bytes, alphanumeric  │
                                        │ Sequence Number   8 bytes, big-endian    │  ← of the FIRST
                                        │ Message Count     2 bytes, big-endian    │    message below
                                        ├──────────────────────────────────────────┤
                                        │ Message Length    2 bytes  ┐             │
                                        │ Message Data      N bytes  ┘ block 1     │
                                        │ Message Length    2 bytes  ┐             │
                                        │ Message Data      N bytes  ┘ block 2     │
                                        │ …                                        │
                                        └──────────────────────────────────────────┘
```

> **Verify** the MoldUDP64 header field widths and the special message-count values
> against the **MoldUDP64 specification** on nasdaqtrader.com. The structure above —
> a 10-byte session, an 8-byte sequence number, a 2-byte count, then length-prefixed
> blocks — is the stable shape. Special cases to confirm: **message count 0 = a
> heartbeat**, and a sentinel count value indicating **end of session**.

Key properties for hardware:

| Property | Consequence |
| --- | --- |
| Sequence number is of the **first** message in the packet | Message *i* in the packet has sequence `pkt_seq + i`. A running counter, not a per-message field |
| Multiple messages per packet | The decoder loops over length-prefixed blocks within one packet — a **bounded** loop, since packet length bounds it |
| Length prefix is 2 bytes and **redundant** with the type | You can cross-check `length_prefix == expected_length(type)` for free. ⚠️ **Do this.** A mismatch means a corrupt or unknown-version message; count it and drop the packet rather than mis-decoding |
| Heartbeats keep the sequence alive | Do not treat a heartbeat as a gap |
| A/B are byte-identical streams | First-to-arrive wins; the second copy is discarded by sequence number |

### A/B arbitration and gaps

```
   Feed A ──►┐
             ├──► sequence-number arbiter ──► in-order message stream ──► decoder
   Feed B ──►┘         │
                       └──► gap detected ──► (slow path) request retransmission
                                             or take a Glimpse snapshot
```

The arbitration logic itself is venue-neutral and is documented in
[../02-networking/03-multicast-feeds-and-arbitration.md](../02-networking/03-multicast-feeds-and-arbitration.md).
Nasdaq-specific points:

- ⚠️ **A gap invalidates the book.** ITCH is a pure delta feed with no periodic
  snapshot on the multicast channel. If you miss an Add Order, that order is missing
  from your book forever — and worse, a later Execute/Cancel/Delete referencing it
  will hit an unknown order reference, which is your *only* symptom.
- **Project rule:** on a detected gap, the FPGA marks the affected book(s)
  **stale**, suppresses order emission, and raises an interrupt. Recovery is a slow-
  path operation. It does not attempt to "catch up" in fabric.
- Count unknown-order-reference events separately. A nonzero count with no detected
  gap means your decoder is wrong.

### Recovery services (both slow path)

| Service | What it gives you | Transport |
| --- | --- | --- |
| **Glimpse** | A point-in-time **snapshot** of the full book plus the sequence number to resume from | SoupBinTCP request/response (TCP) |
| **MoldUDP64 retransmission** ("rewinder") | Replay of a specific range of sequence numbers | MoldUDP64 request packets to a unicast request server |

> **Verify** the Glimpse and retransmission endpoint behaviour, request formats,
> and any request-rate limits in the Nasdaq specifications. The request packet is
> conventionally the same 20-byte shape as the downstream header, with the count field
> reused as a *requested message count*.

⚠️ **Neither belongs in fabric.** Both are TCP or request/response, both are rare, and
both are latency-tolerant by definition (you have already lost the race). Put them in
the host, and have the host re-arm the FPGA's book when recovery completes.

---

## 3. Common field concepts

Every ITCH 5.0 message begins with the same header. **This is the single most
important fact about the protocol for hardware.**

```
   offset  width  field
   ──────  ─────  ──────────────────────────────────────────────
     0       1    Message Type          (ASCII character)
     1       2    Stock Locate          (big-endian uint16)
     3       2    Tracking Number       (big-endian uint16, internal)
     5       6    Timestamp             (big-endian uint48, ns since midnight ET)
     11      …    Message body
```

> Structure illustrative — confirm offsets against the spec PDF before implementing.

| Concept | Detail | Why it matters in fabric |
| --- | --- | --- |
| **Stock locate** | A **dense integer** assigned per symbol per market per day, disseminated in the Stock Directory (`R`) message at start of day | ⚠️ **This is the single biggest gift the protocol gives you.** It turns symbol lookup into a **1-cycle BRAM read at a direct index** — no CAM, no hash, no string compare. Size the table to the maximum locate value, not to the number of symbols you care about |
| Tracking number | Nasdaq-internal | Ignore on the fast path; log it |
| **Timestamp** | 6 bytes, **nanoseconds since midnight, Eastern Time** | 48 bits is plenty for a day (86 400 × 10⁹ ≈ 2⁴⁶·³). Compare directly against the host-loaded session schedule ([02-sessions-auctions-and-halts.md](02-sessions-auctions-and-halts.md) §1) |
| **Order reference number** | 8 bytes, unique per day, assigned by Nasdaq | The key of the order table. 64 bits is too wide to direct-index — needs a hash ([../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) §5) |
| **Shares** | 4 bytes, big-endian uint32 | Native integer |
| **Stock symbol** | 8 bytes, ASCII, **right-padded with spaces** | ⚠️ Only appears in a few messages. **You should never need to parse it on the fast path** — use the locate |
| **Price** | 4 bytes, big-endian uint32, **4 implied decimal places** | `$12.3400` on the wire is `123400`. ⚠️ **Project rule: prices stay as scaled integers end to end** — RTL, PCIe, host, logs. Convert to a decimal string only at the display layer |
| Endianness | **Big-endian** throughout | Free in fabric — it is just wire order. ⚠️ Not free on the host; the host must byte-swap |
| Byte alignment | Messages are **not** 4- or 8-byte aligned within a packet | Fields land at arbitrary byte offsets in the packet. A wide barrel-shifter / byte-align stage is needed before extraction |

⚠️ **The price scale is not uniform across all messages.** The MWCB Decline Level
(`V`) message carries prices with a *different* number of implied decimals from the
ordinary 4. Confirm the scale **per field** in the spec, and encode the scale in your
generated header rather than assuming a global constant.

---

## 4. The ITCH 5.0 message catalogue

> ⚠️ **Structure illustrative — confirm every type code and every length against the
> TotalView-ITCH 5.0 specification PDF before implementing.** Type codes are
> case-sensitive ASCII; note in particular that lower-case `h` (Operational Halt) and
> upper-case `H` (Stock Trading Action) are **different messages**.

### 4.1 Administrative and reference data

| Type | Name | Purpose | Length (verify) | FPGA action |
| --- | --- | --- | --- | --- |
| `S` | **System Event** | Session lifecycle markers | 12 | Advance session FSM (§8) |
| `R` | **Stock Directory** | One per symbol at start of day: symbol, locate, market category, round lot, LULD tier, ETP flags, IPO flag, financial status | 39 | **Build the symbol table.** Slow path may also consume it |
| `H` | **Stock Trading Action** | Trading state change + reason code | 25 | ⚠️ Update per-symbol `tradable` — see [02](02-sessions-auctions-and-halts.md) §3.3 |
| `Y` | **Reg SHO Restriction** | SSR status per symbol | 20 | ⚠️ Update `ssr_active` |
| `L` | **Market Participant Position** | Per-MPID quoting state (primary MM flag, mode, state) | 26 | Slow path; useful for MM analytics |
| `V` | **MWCB Decline Level** | The three circuit-breaker price levels | 35 | Store; note the different price scale |
| `W` | **MWCB Status** | A level has been breached | 12 | ⚠️ **Global order-emission stop** |
| `K` | **IPO Quoting Period Update** | IPO release time, qualifier, price | 28 | IPO-cross handling |
| `J` | **LULD Auction Collar** | Collar reference, upper, lower, extension | 35 | Load reopening collar |
| `h` | **Operational Halt** | Venue-specific operational halt | 21 | Gate that market only |

### 4.2 Order book messages — the fast path

| Type | Name | Body fields (order) | Length (verify) | Book effect |
| --- | --- | --- | --- | --- |
| `A` | **Add Order — no MPID** | order ref (8), buy/sell (1), shares (4), stock (8), price (4) | 36 | **Insert** an order |
| `F` | **Add Order — with MPID** | as `A`, plus attribution/MPID (4) | 40 | **Insert** an order, attributed |
| `E` | **Order Executed** | order ref (8), executed shares (4), match number (8) | 31 | **Reduce** quantity; delete at zero |
| `C` | **Order Executed with Price** | order ref (8), executed shares (4), match number (8), printable (1), execution price (4) | 36 | Same as `E`, at a **different** price |
| `X` | **Order Cancel** | order ref (8), cancelled shares (4) | 23 | **Reduce** quantity (partial cancel) |
| `D` | **Order Delete** | order ref (8) | 19 | **Remove** the order entirely |
| `U` | **Order Replace** | original order ref (8), **new order ref (8)**, shares (4), price (4) | 35 | ⚠️ **Delete old, insert new** — see §7 |

### 4.3 Trade and auction messages

| Type | Name | Purpose | Length (verify) | Book effect |
| --- | --- | --- | --- | --- |
| `P` | **Trade — non-cross** | A **non-displayed** execution: order ref, side, shares, stock, price, match number | 44 | ⚠️ **None** — this reports a trade against hidden liquidity that was never in the displayed book |
| `Q` | **Cross Trade** | Auction print: shares (8), stock, cross price, match number, cross type | 40 | None directly; marks the auction |
| `B` | **Broken Trade** | A previously reported trade has been broken | 19 | ⚠️ Slow path: adjust P&L and volume statistics |
| `I` | **NOII** | Auction imbalance indicator | 50 | Slow path signal — see [02](02-sessions-auctions-and-halts.md) §2.3 |
| `N` | **RPII** | Retail price improvement interest present per symbol | 20 | Slow path / strategy hint |

⚠️ **`P` (Trade — non-cross) does not modify the book.** It exists so the tape is
complete: it reports executions against non-displayed interest, which by definition
never appeared as an Add Order. If you apply `P` to your book you will corrupt it. If
you *ignore* `P` for volume statistics, your volume will be too low. It is a
**statistics-only** message on the fast path.

⚠️ **`C` (Order Executed with Price) exists because the execution price can differ
from the order's resting price** — price sliding, pegs, and hidden price levels all
produce this. It also carries a *printable* flag: some executions are not printed to
the tape (they are reported elsewhere), so a non-printable `C` must **not** be counted
in volume, but **must** still be applied to the book. Getting this backwards produces
a book that is right and a volume series that is wrong, or vice versa — silently.

---

## 5. Message lengths are fixed per type — and why that is everything

In ITCH 5.0 **the message length is a pure function of the message type**. There are
no repeating groups, no optional fields, no varints, no templates to look up.

This means the decoder is **not a parser**. It is:

```
   1. Read the type byte.
   2. Look up (or hardwire) the length for that type.
   3. Extract a fixed set of fields from fixed offsets — all in parallel.
   4. Dispatch to the handler for that type.
```

Contrast with CME MDP 3.0 / SBE, where a template ID selects a variable layout with
repeating groups, forcing a genuine parsing state machine and variable latency.
See [../03-algotrading/03-market-data-protocols.md](../03-algotrading/03-market-data-protocols.md).

| Consequence | Detail |
| --- | --- |
| **Fixed latency** | Every message costs the same number of cycles. No data-dependent branching |
| **No state machine** | Field extraction is combinational slicing off a register holding the message bytes |
| **Speculative extraction is free** | Extract *all* candidate fields at *all* the offsets any message uses, in parallel, then select by type. LUTs are cheap; cycles are not |
| **Length cross-check** | The MoldUDP64 block length prefix must equal the type's fixed length. Free integrity check |
| **Unknown types are safe** | A type you do not recognise still has a length prefix — skip exactly that many bytes and continue. ⚠️ Count it |

---

## 6. Decoder design sketch

```
   64-bit AXI-Stream from MAC/UDP
            │
   ┌────────▼─────────┐
   │ MoldUDP64 framer │  strip 20-byte header, capture session + seq
   │                  │  emit (length, message_bytes) blocks
   └────────┬─────────┘
            │  block boundaries at arbitrary byte offsets
   ┌────────▼─────────┐
   │  Byte aligner    │  barrel shift so the message starts at byte 0
   │  (barrel shift)  │  of a wide register
   └────────┬─────────┘
            │  up to 64 bytes of message in one register
   ┌────────▼─────────────────────────────────────────────────┐
   │  Speculative field extraction — ALL offsets, in parallel  │
   │    locate   = bytes[1:2]      (every message)             │
   │    ts       = bytes[5:10]     (every message)             │
   │    ord_ref  = bytes[11:18]    (A,F,E,C,X,D,U,P)           │
   │    price_a  = bytes[32:35]    (A)                         │
   │    price_u  = bytes[31:34]    (U)                         │
   │    shares_a = bytes[20:23]    (A)                         │
   │    …                                                      │
   └────────┬─────────────────────────────────────────────────┘
            │
   ┌────────▼─────────┐        ┌──────────────────────────┐
   │  Type dispatch   │───────►│ book update command       │
   │  mux (1-hot on   │        │  {op, locate, ord_ref,    │
   │   type byte)     │        │   side, price, qty}       │
   └────────┬─────────┘        └──────────────────────────┘
            │
            └──────────────────► state-table writes (H, Y, W, h, J)
            └──────────────────► slow-path FIFO (R, L, I, N, B, P, Q)
```

> Offsets in the sketch are illustrative — confirm against the spec PDF.

```systemverilog
// Fixed-offset extraction. Note there is NO state machine here:
// every field is a static slice of the aligned message register.

localparam int HDR_LEN = 11;

logic [8*64-1:0] msg;         // byte-aligned message, byte 0 in msg[7:0]

// Helper: ITCH is big-endian, so byte 0 is the MOST significant.
function automatic logic [15:0] be16(input int off);
    return {msg[8*off +: 8], msg[8*(off+1) +: 8]};
endfunction
function automatic logic [31:0] be32(input int off);
    return {msg[8*off +: 8], msg[8*(off+1) +: 8],
            msg[8*(off+2) +: 8], msg[8*(off+3) +: 8]};
endfunction

wire [7:0]  msg_type = msg[7:0];
wire [15:0] locate   = be16(1);           // ← the 1-cycle symbol index
wire [47:0] ts       = {be32(5), be16(9)};

// Speculative: computed for every message, selected by type.
wire [63:0] ord_ref  = {be32(11), be32(15)};
wire [31:0] add_shrs = be32(20);
wire [31:0] add_px   = be32(32);
wire        add_side = (msg[8*19 +: 8] == "B");

typedef enum logic [2:0] {
    BOOK_NOP, BOOK_ADD, BOOK_REDUCE, BOOK_DELETE, BOOK_REPLACE
} book_op_e;

book_op_e op;
always_comb begin
    unique case (msg_type)
        "A", "F": op = BOOK_ADD;
        "E", "C": op = BOOK_REDUCE;    // execution reduces
        "X":      op = BOOK_REDUCE;    // partial cancel reduces
        "D":      op = BOOK_DELETE;
        "U":      op = BOOK_REPLACE;
        default:  op = BOOK_NOP;       // P, Q, I, N, B, S, R, H, Y, … 
    endcase
end
```

### Illustrative latency budget

| Stage | Cycles @ 156.25 MHz | ns | Notes |
| --- | --- | --- | --- |
| MAC + UDP header strip | 2–4 | 13–26 | See [../02-networking/02-ip-udp-tcp-in-hardware.md](../02-networking/02-ip-udp-tcp-in-hardware.md) |
| MoldUDP64 framing | 1–2 | 6–13 | |
| Byte alignment (barrel shift) | 1 | 6 | Can be a critical path — pipeline it |
| Field extraction + type dispatch | 1 | 6 | Pure combinational slicing |
| Order-table lookup (hash on order ref) | 2–3 | 13–19 | The real cost — see §7 |
| Book update | 1–2 | 6–13 | [../04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md) |

⚠️ **Design targets, to be measured, not measurements.** The point of the table is the
shape: **the order-reference lookup dominates the decode**, because it is the only
step that is not a fixed slice of wire bytes.

---

## 7. Order-based book reconstruction

The core algorithm. Maintain two structures:

```
   ORDER TABLE      order_ref (64-bit) → { locate, side, price, qty }
                    → hashed, since 64-bit refs cannot be direct-indexed

   BOOK             per (locate, side, price) → aggregated qty (+ order count)
                    → price-level array or similar; see 04-system-architecture/03
```

### Step by step

| Message | Order table | Book |
| --- | --- | --- |
| **`A` / `F`** Add Order | Insert `ord_ref → {locate, side, price, shares}` | `book[locate][side][price] += shares`; order count +1 |
| **`E`** Order Executed | Look up `ord_ref`; `qty -= executed_shares`; **if `qty == 0`, delete the entry** | `book[…] -= executed_shares`; order count −1 if removed |
| **`C`** Order Executed with Price | Identical book/order-table effect to `E`. The **execution price field is not the resting price** — do **not** use it to locate the level | Use the *stored* price from the order table, never the message's execution price |
| **`X`** Order Cancel | `qty -= cancelled_shares`; delete if zero | `book[…] -= cancelled_shares` |
| **`D`** Order Delete | Look up, then **delete the entry** | `book[…] -= remaining_qty`; order count −1 |
| **`U`** Order Replace | ⚠️ **Delete `original_ref`, then insert `new_ref`** with the message's shares and price | Subtract the old order's full remaining qty at its old price; add the new qty at the new price |
| **`P`** Trade — non-cross | ⚠️ **No effect.** Statistics only | No effect |
| **`Q`** Cross Trade | No effect on the continuous book | Auction volume statistics |
| **`B`** Broken Trade | No effect | Slow path: adjust statistics and P&L |

### ⚠️ The three subtleties that produce working-but-wrong books

**1. Order Replace creates a NEW order reference.**

```
   Before:   ord_ref = 0x1234, 500 shares @ 190.85
   Message:  U  original=0x1234  new=0x9ABC  shares=300  price=190.86

   After:    0x1234 does NOT exist.
             0x9ABC exists with 300 shares @ 190.86.

   Book:     190.85 -= (remaining qty of 0x1234, NOT necessarily 500)
             190.86 += 300
```

The order being replaced may have been **partially executed** since it was added, so
you must subtract its **current remaining quantity from the order table**, not the
quantity it was originally added with. A decoder that subtracts the original quantity
will drift the book negative over the day.

⚠️ **Replace loses time priority.** The new order reference is a new order at the back
of the queue. If you are tracking queue position, a replace on an order ahead of you
*helps* you; a replace on your own order *destroys* your position.

**2. Executions delete at zero, but cancels can too.**

`E`, `C` and `X` all reduce. Any of them can drive the quantity to zero, which must
remove the order and decrement the level's order count. Handling removal only in `D`
is a classic bug: the book keeps phantom zero-quantity orders and the order count
becomes meaningless.

**3. An unknown order reference is a symptom, not an anomaly to swallow.**

```
   E / C / X / D / U referencing an order_ref not in the table
       ⇒ you missed the Add, or your hash evicted it, or you have a gap.
```

⚠️ **Count these, and if the count is nonzero, the book is not trustworthy.** The
correct fast-path response is to mark the symbol's book **stale** and suppress order
emission for it until the host reconciles. Silently ignoring the message produces a
book that looks plausible and is wrong — the worst outcome in this system.

### Sizing the order table

| Question | Guidance |
| --- | --- |
| How many live orders? | Hundreds of thousands to millions across all symbols, intraday. **Measure from a pcap replay of a real day, including a volatile one** |
| Direct index on `order_ref`? | ❌ 64-bit key — impossible |
| Hash? | ✅ CRC-based hash into a set-associative table in BRAM/URAM. See [../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) §5 and [../01-fpga-design/03-memory-and-storage.md](../01-fpga-design/03-memory-and-storage.md) |
| Only tracking a few symbols? | ✅ **Filter by locate first.** If you trade 50 symbols, discard every message whose locate is not in your enabled bitmap *before* the order-table lookup. This collapses the table size by orders of magnitude and is the single most effective resource optimization in the feed handler |
| Eviction on overflow? | ⚠️ Never silently. An evicted order becomes an unknown-reference event later. Count evictions and treat overflow as a stale-book condition |

---

## 8. System Event messages and the session FSM

The `S` message carries a single event code marking a session boundary.

| Event (conceptual) | Meaning | FPGA action |
| --- | --- | --- |
| **Start of messages** | The feed is up for the day; the first message | Reset sequence tracking; clear books |
| **Start of system hours** | Pre-market order acceptance begins | Symbol tables should already be loaded |
| **Start of market hours** | 09:30 — regular session | ⚠️ **Arm the fast path.** Only now may fast-path orders be emitted |
| **End of market hours** | 16:00 — regular session over | ⚠️ **Disarm the fast path.** Suppress new fast-path orders |
| **End of system hours** | Post-market over | Snapshot counters |
| **End of messages** | No further messages today | Expect no more data; alarm if any arrives |

> **Verify** the single-character event codes in the **TotalView-ITCH 5.0
> specification**. (ITCH 5.0 removed some emergency-market-condition codes that
> existed in earlier versions — another reason not to work from memory.)

⚠️ **Require agreement between `S` and the wall clock.** The FPGA holds a host-loaded
schedule ([02-sessions-auctions-and-halts.md](02-sessions-auctions-and-halts.md) §1).
If the `S` message says "market hours" and the schedule says otherwise, that is either
a spec change, a config error, or a replayed feed pointed at production. **Alarm, and
fail closed.** This check has caught replay-into-production incidents at real firms.

---

## 9. Hardware implications

### 9.1 What ITCH 5.0 lets you do that other protocols do not

| Property | Exploit it by |
| --- | --- |
| Fixed length per type | Hardwiring lengths; no length parsing; validating against the Mold length prefix |
| Fixed field offsets | Combinational slicing with zero state; speculative extraction of all fields at once |
| Dense integer locate | **1-cycle direct-index BRAM** symbol lookup — no CAM, no hash, no string compare |
| Big-endian | Zero-cost in fabric (wire order == numeric order) |
| Scaled-integer prices | No floating point anywhere; no conversion on the fast path |
| Delta-only feed | Small messages, high rate — optimize for *message* throughput, not byte throughput |

### 9.2 Required blocks

| Block | Function | Notes |
| --- | --- | --- |
| MoldUDP64 framer | Header strip, block iteration, sequence tracking | Bounded loop over blocks |
| A/B arbiter | First-to-arrive by sequence number, duplicate discard, gap detect | [../02-networking/03-multicast-feeds-and-arbitration.md](../02-networking/03-multicast-feeds-and-arbitration.md) |
| Byte aligner | Barrel shift message to offset 0 | Often the Fmax-critical block |
| Locate filter | Drop messages for symbols we do not trade | **Do this first** — biggest resource win |
| Field extractor | Fixed-offset speculative slicing | Combinational |
| Type dispatch | One-hot mux on the type byte | Include a `default` that counts unknowns |
| Order table | `order_ref → {locate, side, price, qty}` | Hashed, set-associative, in URAM |
| Book engine | Price-level aggregation and top-of-book | [../04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md) |
| State table writer | `H`, `Y`, `W`, `h`, `J` → per-symbol trading state | [02-sessions-auctions-and-halts.md](02-sessions-auctions-and-halts.md) §8.1 |
| Slow-path FIFO | `R`, `L`, `I`, `N`, `B`, `P`, `Q`, unknowns | DMA to host |

### 9.3 Mandatory counters

Per CLAUDE.md hard rule 7, each of these is a readable register:

`packets_rx`, `packets_dropped`, `seq_gaps`, `duplicate_packets`,
`messages_by_type[N]`, `unknown_message_type`, `length_mismatch`,
`unknown_order_ref`, `order_table_evictions`, `order_table_occupancy_max`,
`book_stale_events`, `locate_out_of_range`, `negative_book_qty_attempts`,
`state_change_races`.

⚠️ `negative_book_qty_attempts` deserves special mention: a book level going negative
is arithmetically impossible if the decode is correct. A nonzero count is proof of a
decode bug, and it is the cheapest possible self-test. **Saturate at zero, count, and
mark the book stale — never wrap.**

### 9.4 Single source of truth for offsets

⚠️ **Do not write offsets by hand in three places.** Generate a single header from a
machine-readable description of the spec, and emit from it:

- a SystemVerilog package of `localparam` offsets and lengths,
- a C/C++ header for the host,
- a Python module for the cocotb testbench.

Then the verification step "confirm offsets against the spec PDF" happens **once**,
in one file, reviewably — and a spec revision is a single-file change.
See [../01-fpga-design/05-verification-and-simulation.md](../01-fpga-design/05-verification-and-simulation.md)
for the pcap-replay regression that must accompany it.

---

## Further reading

- [05-ouch-5.0-order-entry.md](05-ouch-5.0-order-entry.md) — the other half of the protocol pair
- [02-sessions-auctions-and-halts.md](02-sessions-auctions-and-halts.md) — the state messages `S`/`H`/`Y`/`V`/`W`/`J`/`K`/`h`
- [03-order-types-and-routing.md](03-order-types-and-routing.md) — why hidden liquidity produces `P` and `C`
- [../04-system-architecture/02-feed-handler-design.md](../04-system-architecture/02-feed-handler-design.md) — the block-level design
- [../04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md) — the book structure this feeds
- [../02-networking/03-multicast-feeds-and-arbitration.md](../02-networking/03-multicast-feeds-and-arbitration.md) — A/B feeds and gap handling
- [../03-algotrading/03-market-data-protocols.md](../03-algotrading/03-market-data-protocols.md) — ITCH vs. SBE vs. FAST
