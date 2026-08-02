# 04.02 — Feed Handler Design

> **Why this matters here:** the feed handler owns rows **R0–R5** of the master
> budget — 6 cycles, 38.4 ns — and it is the only block in the system that cannot
> ever say "wait". The wire does not stop. Everything downstream is allowed to be
> clever; this block is only allowed to be *unconditional*.

---

## 1. The one non-negotiable property: no backpressure

```systemverilog
// rtl/net/eth_rx_parse.sv
assign s_mac_rx_tready = 1'b1;      // tied. permanently. by contract.
```

The MAC delivers a 64-bit beat every 6.4 ns whenever a frame is on the wire. There
is no mechanism to slow it down that does not involve dropping frames somewhere
worse (the switch, the venue's link). So:

> **The RX path is designed for guaranteed line rate at the worst-case message mix,
> and any inability to keep up is expressed as a counted drop, never as a stall.**

This has a specific structural consequence: **there are no FIFOs on the RX fast
path.** A FIFO is a place where you can fall behind, and falling behind on market
data is not recoverable — you cannot ask the wire to resend. Instead the pipeline is
sized so it *cannot* fall behind, and the arithmetic that proves it is §2.

⚠️ The failure mode this prevents is subtle and vicious: a design with a small FIFO
works perfectly in every test, then during a market-open burst the FIFO fills, the
handler stalls, the MAC's own buffer overruns, and you drop a **frame** — which is
20+ ITCH messages, which is a sequence gap, which stales every book in that packet.
You lose far more than the one message you were slow on. Drop deliberately at
message granularity, or do not drop at all.

### What we drop, and where

| Drop point | Reason | Counter |
| --- | --- | --- |
| `eth_rx_parse` | wrong EtherType / not IPv4 / not UDP / not our multicast group | `drop_not_ours` |
| `eth_rx_parse` | MAC flagged bad FCS (`tuser[0]`) | `drop_fcs` |
| `mold_deframe` | MoldUDP64 session mismatch | `drop_session` |
| `mold_deframe` | length field inconsistent with the packet | `drop_malformed` |
| `ab_arbiter` | duplicate — this sequence already seen on the other feed | `dup_a` / `dup_b` (not an error) |
| `itch_dispatch` | unknown message type byte | `drop_unknown_type` |
| `itch_dispatch` | MoldUDP64 block length ≠ type-implied ITCH length | `drop_len_mismatch` |
| `symbol_filter` | stock locate not subscribed | `filtered` (not an error) |
| `symbol_filter` | stock locate ≥ `LOCATE_MAX` | `drop_bad_locate` |

Two of these are *normal* (`dup_*`, `filtered`) and the rest are *errors*. They are
different counters and different alarm thresholds. Conflating "I chose not to look at
this" with "I could not look at this" makes the telemetry useless.

---

## 2. Throughput arithmetic: proving we keep up

The relevant worst case is not the average message rate. It is the **shortest
book-affecting message, arriving back-to-back inside a maximally packed MoldUDP64
packet.**

| Quantity | Value | Derivation |
| --- | --- | --- |
| Line rate | 10 Gb/s | 0.8 ns per byte |
| Datapath | 64-bit @ 156.25 MHz | 8 bytes/cycle |
| Shortest book-affecting ITCH message | `Order Delete` (`D`), 19 bytes | see 08-nasdaq |
| MoldUDP64 per-message overhead | 2 bytes (length prefix) | see 08-nasdaq |
| Bytes on the wire per message | 21 | 19 + 2 |
| Cycles of arrival per message | 21 / 8 = **2.625** | |
| ⇒ Minimum inter-message spacing | **3 cycles** (2 in the worst alignment case) | |
| Book pipeline initiation interval | **1 cycle** | designed for it |
| Headroom | **≥ 2×** | |

So the pipeline is over-provisioned by at least 2×, which is what pays for
`Order Replace` expanding to two commands (J5) and for the occasional rescan (J4).

> **Verify:** ITCH 5.0 message lengths (`D` = 19 bytes, `A` = 36, `E` = 31, `X` = 23,
> `U` = 35, `C` = 36, `F` = 40) and the MoldUDP64 message-block framing (2-byte
> big-endian length prefix per message, 20-byte packet header) come from the Nasdaq
> *TotalView-ITCH 5.0* and *MoldUDP64* specifications. Confirm against the current
> published spec before freezing `itch_pkg.sv`; Nasdaq has revised message lengths
> across minor versions. The venue-specific tables live in [../08-nasdaq/](../08-nasdaq/).

**Sustained-rate sanity check.** 10 Gb/s ÷ 21 bytes/message ≈ **59.5 M messages/s**
theoretical ceiling. Real Nasdaq TotalView peaks are two orders of magnitude below
that, but *we do not design to the real peak* — we design to line rate, because that
is the only bound the wire enforces and it is the only one we can guarantee.

---

## 3. Beat width, and the decision not to gearbox

The tempting design is: gearbox the 64-bit MAC stream up to 512-bit so that any ITCH
message lands in one beat, decode combinationally, done. It is wrong here, and the
reason is worth internalising.

```
64-bit @ 156.25 MHz  →  512-bit @ 19.53 MHz    (real gearbox: slower clock)
64-bit @ 156.25 MHz  →  512-bit @ 156.25 MHz   (accumulate 8 beats, emit 1 with valid)
```

The second form is what people mean. Its cost: **you wait for the beat to fill.** A
19-byte `Order Delete` that completes at byte 3 of a 64-byte beat sits in the
accumulator for another 61 bytes — up to **7 cycles = 44.8 ns** of pure waiting — or
you add "flush on `tlast`" logic that only helps at packet end, not between messages
inside a packet.

**Our design: a wide *window* with a narrow *fill*.**

- Keep a **128-byte circular byte buffer** written 8 bytes/cycle.
- Extract a **64-byte message-aligned view** combinationally, at *byte* granularity.
- Fire the decoder on the cycle the message's **last byte becomes available**, not
  when a beat fills.

The result is that the latency of R3 is a fixed 1 cycle regardless of where in the
beat a message starts or ends. We pay in a barrel shifter (§4) instead of in time.
This is the "widen before you deepen" trade from
[../01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) §3,
applied to the *storage* rather than the *stream*.

| Design | Extra latency | Extra logic | Verdict |
| --- | ---: | --- | --- |
| 64-bit byte-serial FSM parser | +3–6 cyc/msg | tiny | too slow, and message-length dependent |
| Gearbox to 512-bit beats | +0–7 cyc/msg | 512-bit accumulator | **jitter as a function of byte alignment** — unacceptable |
| **128 B window + byte barrel shift** | **+1 cyc, fixed** | 16:1 word mux + 3-bit byte shifter on 576 bits | **chosen** |

---

## 4. Message realignment — the hard part

This is where feed handlers are won and lost. An ITCH message can start at **any
byte offset** within a beat, and can straddle **any number** of beat boundaries.

### 4.1 Structure

```
      write side (8 bytes/cycle from MAC)          read side (byte granular)
                   │                                       │
                   ▼                                       ▼
   ┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
   │w0 │w1 │w2 │w3 │w4 │w5 │w6 │w7 │w8 │w9 │w10│w11│w12│w13│w14│w15│  16 × 64-bit
   └───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘  = 128 bytes
        ▲                              ▲
      rd_ptr (7 bits, byte)          wr_ptr (4 bits, word)

   extract: 9 consecutive words from rd_ptr[6:3]  →  576 bits
            barrel-shift right by rd_ptr[2:0] × 8 →  512 bits, byte 0 aligned
```

Nine words, not eight, because a 64-byte view starting mid-word spills into the next.

```systemverilog
// rtl/feed/msg_realign.sv   — budget row R3, 1 cycle, fixed
logic [63:0] buf_q [16];
logic [3:0]  wr_ptr_q;      // word granularity
logic [6:0]  rd_ptr_q;      // BYTE granularity, wraps mod 128
logic [7:0]  fill_q;        // bytes currently valid ahead of rd_ptr (saturating)

always_ff @(posedge clk) begin
    if (beat_valid) begin
        buf_q[wr_ptr_q] <= beat_data;
        wr_ptr_q        <= wr_ptr_q + 4'd1;
        fill_q          <= fill_q + beat_bytes - consumed_bytes;   // beat_bytes from tkeep
    end else begin
        fill_q          <= fill_q - consumed_bytes;
    end
    rd_ptr_q <= rd_ptr_q + consumed_bytes;
end

// Combinational extraction: 9 words, wrapping
logic [575:0] raw;
always_comb begin
    for (int i = 0; i < 9; i++)
        raw[64*i +: 64] = buf_q[(rd_ptr_q[6:3] + i[3:0])];   // 4-bit adder wraps for free
end

// Byte barrel shift: 3 stages of 2:1 mux (shift 1, 2, 4 bytes)
logic [511:0] msg_view;
assign msg_view = raw[ {rd_ptr_q[2:0], 3'b000} +: 512 ];        // synthesises to a
                                                                // 3-level byte shifter
```

### 4.2 Deciding when a message is complete

Chicken-and-egg: you need the length to know if the message has fully arrived, and
the length is inside the message. MoldUDP64 solves this for us — the **first two
bytes of every message block are its length**, so:

```systemverilog
logic [15:0] blk_len;
assign blk_len = {msg_view[7:0], msg_view[15:8]};        // big-endian on the wire

logic len_avail, msg_avail;
assign len_avail = (fill_q >= 8'd2);
assign msg_avail = len_avail && (fill_q >= (blk_len + 16'd2));

assign msg_valid    = msg_avail && msgs_remaining_q != 0;
assign msg_data     = msg_view[ 16 +: 512 ];             // skip the 2-byte length
assign consumed_bytes = msg_valid ? (blk_len[7:0] + 8'd2) : 8'd0;
```

**No state machine.** `rd_ptr` advances by `2 + blk_len`, `msgs_remaining` decrements,
and the next message is presented on the very next cycle if its bytes are already in
the buffer. Two messages that are both already buffered emit on consecutive cycles —
which is exactly the II = 1 the book needs.

### 4.3 Sizing the buffer

128 bytes because it must hold: the largest ITCH message (`NOII`, 50 bytes) plus a
full 8-byte beat of over-read plus enough slack that the write pointer cannot lap the
read pointer while a message is being assembled. The write side advances at most 8
bytes/cycle and the read side consumes ≥ 21 bytes per message at ≥ 1 message/cycle,
so the read side can always outpace the write side. `fill_q` overflow is impossible
by construction and is asserted:

```systemverilog
assert property (@(posedge clk) disable iff (rst) fill_q <= 8'd128)
    else $error("msg_realign: window overrun — buffer sizing invariant broken");
```

⚠️ **The single most common bug in this block** is treating `rd_ptr` wrap and
`wr_ptr` wrap as independent. They are the same 128-byte modulus expressed at
different granularities (`rd_ptr[6:3]` *is* the word index). Deriving one from the
other, rather than maintaining two counters, removes the entire bug class.

---

## 5. MoldUDP64 deframing and multi-message packets

A MoldUDP64 packet is a 20-byte header followed by `MessageCount` message blocks,
each `[2-byte length][ITCH payload]`, packed with **no padding and no alignment**.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Session (10 B)  │ SequenceNumber (8 B) │ MessageCount (2 B) │            │
├──────────────────────────────────────────────────────────────────────────┤
│ len₀ │ ITCH msg 0 … │ len₁ │ ITCH msg 1 … │ len₂ │ ITCH msg 2 … │  …     │
└──────────────────────────────────────────────────────────────────────────┘
   2 B      len₀ B      2 B      len₁ B      2 B      len₂ B
```

Critically: `SequenceNumber` is the sequence of the **first message** in the packet,
and it counts **messages, not packets**. So:

```
next_expected = SequenceNumber + MessageCount
```

> **Verify:** the 20-byte header layout (10-byte session, 8-byte big-endian sequence,
> 2-byte big-endian count) and the message-count semantics are from the Nasdaq
> *MoldUDP64* specification. Special values — `MessageCount = 0` for a heartbeat and
> `0xFFFF` for end-of-session — must be handled explicitly. Confirm both against the
> current spec; see [../08-nasdaq/](../08-nasdaq/).

### 5.1 Why "at rate" is the whole requirement

A single 1500-byte MoldUDP64 packet can carry **~70** `Order Delete` messages. It
arrives in 188 cycles. If the extractor takes 3 cycles per message it needs 210
cycles and it is already behind before the next packet arrives. The extractor must
be able to emit **one message per cycle**, sustained, for the length of the packet.

The §4.2 design does this: `msg_valid` can be high on consecutive cycles because the
completion test is a pure comparator over `fill_q`, not a state machine handshake.
The rate is then limited only by byte arrival (§2), with 2× headroom.

### 5.2 Header vs. body cost

```
cycle:  0    1    2    3    4    5    6   ...
        │    │    │    │    │    │    │
     [R1 eth/ip/udp]
          [R2 mold hdr, seq, A/B]
               [R3 msg0][R3 msg1][R3 msg2] ...      ← messages 1..N-1 skip R1/R2
```

R1 and R2 are paid **once per packet**, not once per message. Message *k* > 0 enters
the pipeline at R3 directly. This is why J2 in the master budget is a *queueing*
cost of 1 cycle per preceding book-affecting message, not a full 6-cycle re-traverse.

### 5.3 A/B arbitration

Two identical multicast feeds, A and B, with independent network paths. Both are
deframed in parallel by two `mold_deframe` instances. `ab_arbiter` is a **comparator
against `next_expected`, not a queue**:

```systemverilog
// First arrival with seq == next_expected wins. The other is counted as a dup.
wire take_a = a_valid && (a_seq == next_expected_q);
wire take_b = b_valid && (b_seq == next_expected_q) && !take_a;
```

- Cost: **0 cycles.** It is a mux in the R2 stage, not a stage of its own.
- Out-of-order or ahead-of-expected packets on either feed set `gap_detected`.
- Behind-expected packets are silently counted as duplicates.
- ⚠️ Do **not** buffer an ahead-of-sequence packet hoping the missing one arrives.
  That is a reordering buffer, it is unbounded, and it puts a queue on the fast path.
  Detect the gap, stale the books, and let the CPU recover (§8).

More on multi-feed handling in [../02-networking/03-multicast-feeds-and-arbitration.md](../02-networking/03-multicast-feeds-and-arbitration.md).

---

## 6. ITCH dispatch as a fixed-offset decode

ITCH 5.0 is **fixed-length per message type** and — this is the load-bearing
property — every message begins with the same prefix:

```
byte  0        1  2          3  4              5 … 10
    ┌────────┬─────────────┬────────────────┬──────────────────────────┐
    │  Type  │ StockLocate │ TrackingNumber │ Timestamp (6 B, ns)      │  …type-specific…
    └────────┴─────────────┴────────────────┴──────────────────────────┘
```

Because `msg_view` is byte-0 aligned after R3, **every field of every message type
is at a compile-time constant bit offset**. Decode is therefore not a parser. It is
one 8-bit `case` selecting among constant slices:

```systemverilog
// rtl/feed/itch_dispatch.sv   — budget row R4, 1 cycle, fixed
localparam int OFF_LOCATE = 8, OFF_TRACK = 24, OFF_TS = 40;   // bit offsets

// Type-independent, extracted unconditionally — no case needed:
assign ev.locate = {msg[OFF_LOCATE +: 8], msg[OFF_LOCATE+8 +: 8]};   // BE→LE swap
assign ev.ts     = bswap48(msg[OFF_TS +: 48]);

always_comb begin
    ev = '0; ev.op = OP_NONE;
    unique case (msg[7:0])
      "A": begin ev.op=OP_ADD;  ev.oid=bswap64(msg[ 88+:64]); ev.side=(msg[152+:8]=="B");
                 ev.qty=bswap32(msg[160+:32]); /* sym 8B */    ev.px =bswap32(msg[256+:32]); end
      "F": begin ev.op=OP_ADD;  /* same offsets as A; trailing 4-byte MPID ignored */ end
      "E": begin ev.op=OP_EXEC; ev.oid=bswap64(msg[ 88+:64]); ev.qty=bswap32(msg[152+:32]); end
      "C": begin ev.op=OP_EXEC; /* + price + printable; book effect identical to E */ end
      "X": begin ev.op=OP_CXL;  ev.oid=bswap64(msg[ 88+:64]); ev.qty=bswap32(msg[152+:32]); end
      "D": begin ev.op=OP_DEL;  ev.oid=bswap64(msg[ 88+:64]); end
      "U": begin ev.op=OP_REPL; ev.oid=bswap64(msg[ 88+:64]); ev.new_oid=bswap64(msg[152+:64]);
                 ev.qty=bswap32(msg[216+:32]); ev.px=bswap32(msg[248+:32]); end
      "H": begin ev.op=OP_HALT; ev.halt_state=msg[88+:8]; end
      "S": begin ev.op=OP_SYSEVT; ev.sys_code=msg[88+:8]; end
      "Y": begin ev.op=OP_SSR;  ev.ssr_state=msg[88+:8]; end
      default: begin ev.op=OP_NONE; unknown_type_r <= 1'b1; end
    endcase
end
```

> **Verify:** the byte offsets above are illustrative of the *shape* of the decode,
> not authoritative. Take the exact offsets from the Nasdaq TotalView-ITCH 5.0
> specification and generate `itch_pkg.sv` from it with `scripts/gen_itch_pkg.py`
> rather than hand-transcribing. Hand-transcribed offsets are a silent-corruption
> bug class. The message-field reference lives in [../08-nasdaq/](../08-nasdaq/).

### 6.1 Why not a state machine

| | Byte-serial FSM | Fixed-offset decode |
| --- | --- | --- |
| Latency | 1 cycle per beat of the message (3–7) | **1 cycle, any type** |
| Latency variance | proportional to message length | **zero** |
| Logic | small | one wide mux tree per field |
| Adding a message type | new states, new transitions, re-verify the FSM | one `case` arm |
| Failure mode | wrong state → silently mis-parses the *next* message too | wrong slice → mis-parses one message |

The FSM is smaller. It is also variable-latency, which we have already established
costs more than area. The mux tree at 64 bytes wide is a few hundred LUTs.

### 6.2 "Variable-length" in a fixed-length protocol

ITCH 5.0 has no variable-length messages, but the **framing** carries a length and
the **payload type** implies a length, and the two can disagree. That disagreement
means a corrupt packet or a spec-version mismatch:

```systemverilog
assign len_ok = (blk_len == itch_len_lut[msg[7:0]]);   // 256-entry ROM, 0 = unknown
```

⚠️ **A length mismatch must drop the entire remaining packet, not just the message.**
Once the length is wrong, `rd_ptr` advances by the wrong amount and every subsequent
message in that packet is garbage read from the wrong offset — and it will *decode*,
because arbitrary bytes are a valid message type roughly 1 time in 10. That is a
silently corrupted book. Abandon the packet, count `drop_len_mismatch`, stale the
affected channel, and let the sequence tracker force recovery.

---

## 7. Symbol filtering, as early as physically possible

We trade a subset — call it 128 symbols — out of a universe of ~9,000 Nasdaq-listed
plus regional securities. **87 % or more of every packet is work we should never do.**

The enabling fact from §6: `StockLocate` is at bytes 1–2 of **every** ITCH message,
including `Order Executed`, `Order Cancel` and `Order Delete`, which carry no symbol
string. So we can filter every message type on a fixed 16-bit field with no decode
dependency at all.

### 7.1 The design

```systemverilog
// rtl/feed/symbol_filter.sv   — budget row R5, 1 cycle, fixed
// Two tables, both read in the same cycle, both indexed by the raw locate.
//   subscribed : 65536 × 1 bit   =  64 Kbit  =  2 × BRAM36
//   slot_map   : 65536 × 12 bit  = 768 Kbit  = 22 × BRAM36  (or 3 URAM)
logic        subscribed;
logic [11:0] slot;

assign cmd_valid = ev.valid && subscribed && (ev.op inside {OP_ADD, OP_EXEC,
                                                            OP_CXL, OP_DEL, OP_REPL});
assign cmd.slot  = slot;
```

- `subscribed[locate]` — 1 bit. Written by the CPU at start of day from the ITCH
  `Stock Directory` (`R`) messages plus our traded-universe list.
- `slot_map[locate]` — compact index into the book arrays, so the book is sized by
  `N_SYMBOLS = 128`, not by 65536. This is the difference between 12.6 Mbit of level
  memory and 6.4 Gbit of level memory.

### 7.2 Where the filter must sit

| Position | Downstream work saved | Verdict |
| --- | --- | --- |
| After the book update | none | absurd, but it is what a naive port of software does |
| After ITCH decode (**R5, chosen**) | order-map lookup, level RMW, TOB, strategy — rows B0–S1, i.e. **7 of 20 fabric cycles** of pipeline occupancy per filtered message | **chosen** |
| Before ITCH decode | also saves R4 | tempting — but R4 is where `op` is determined, and we need `op` to know whether the message is book-affecting at all. Saving one cycle of *occupancy* (not latency) is not worth the coupling. |
| In the switch / NIC by multicast group | everything | do this **too**, where the venue's channel partitioning allows it. Nasdaq splits ITCH across multiple multicast groups by symbol range; subscribe only to the groups you need. This is free and it is the biggest single reduction available. |

Note carefully: **filtering does not reduce latency for a symbol we do trade.** It
reduces *pipeline occupancy*, which is what protects us from J2 queueing jitter, and
it reduces book memory, which is what makes the direct-index design in 04.03
affordable. Those are the reasons, and they are enough.

⚠️ Filtering at R5 means the order-ID map never contains orders for unsubscribed
symbols — which is correct and self-consistent only because *every* order message
carries the locate. If a future venue or protocol version omits the symbol from
delete messages, this entire design collapses and the filter must move behind the
order map. Assert the property; do not assume it.

---

## 8. Sequence gaps and the stale-book policy

```systemverilog
// rtl/feed/seq_tracker.sv
wire [63:0] pkt_next = pkt_seq + pkt_msg_count;

always_ff @(posedge clk) begin
    if (pkt_valid) begin
        if (pkt_seq == next_expected_q)      next_expected_q <= pkt_next;   // in order
        else if (pkt_seq <  next_expected_q) dup_cnt_q <= dup_cnt_q + 1;    // already have
        else begin                                                          // GAP
            gap_cnt_q     <= gap_cnt_q + 1;
            gap_size_q    <= pkt_seq - next_expected_q;
            channel_stale <= 1'b1;                    // sticky until CPU clears
            next_expected_q <= pkt_next;              // resync forward, do NOT stall
        end
    end
end
```

### The policy

| Event | Hardware action | Software action |
| --- | --- | --- |
| Gap detected | Set `channel_stale`. Set `book_stale` for **every symbol on that channel**. Strategy gating drops those symbols immediately (0 extra cycles — it is a precomputed bit). Keep decoding forward. | Raise an alarm. Start MoldUDP64 re-request for the missing range, or a Glimpse snapshot if the gap is large. |
| Recovery data arrives | CPU rebuilds the book via `book_resync` (04.03 §9) | Verify continuity, then clear `book_stale` per symbol |
| Gap on A only | Feed B covers it; **no stale**, count `gap_a` | Alarm on the link, not on trading |
| Gap on both A and B | Stale | Recovery |

**Non-negotiables:**

1. ⚠️ **We do not trade a stale book.** Ever. Not "with reduced size", not "for
   symbols we think are unaffected". The gap tells you exactly one thing: you do not
   know what you missed. `book_stale` is an input to the risk gate as well as the
   strategy, so a stale book cannot produce an order even if the strategy is buggy.
2. **We never stall the RX path waiting for recovery.** `next_expected` jumps
   forward and decoding continues; the *book* is invalid, the *feed handler* is not.
3. **We never infer.** No "the book probably still looks like this". A missed
   `Order Delete` leaves a phantom order at the touch forever, and phantom liquidity
   at the touch is precisely the state in which a strategy loses money fastest.

---

## 9. Ingress timestamping

```systemverilog
// rtl/telemetry/ts_capture.sv   — budget row R0, 1 cycle (shared with the ingress reg)
logic [63:0] free_run_q;                     // 156.25 MHz, 6.4 ns tick, ~118 yr rollover
always_ff @(posedge clk) free_run_q <= free_run_q + 1;
always_ff @(posedge clk) if (sof) pkt_ts_q <= free_run_q;
```

- Captured on **start of frame at the MAC boundary**, before any parsing.
- Carried unchanged in `tstamp` through every fast-path struct (§7.1 of 04.01) to
  T6, where `latency_hist` computes `now - tstamp` and bins it.
- This measures **fabric latency only** (R0→T6). It does not include the PHY, which
  is why the PHY rows must be characterised separately with an external loopback.
- The counter is also snapshotted into every DMA audit record, so a host-side
  reconstruction of any decision has the same clock as the hardware histogram.

> **Verify:** for cross-host or venue-relative timestamps you need PTP/PPS
> discipline, not a free-running counter. That is a separate mechanism —
> see [../06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md).
> The free-running counter is for *interval* measurement inside one FPGA only.

---

## 10. Counters and error registers

Every one of these is a saturating counter readable over BAR0, and every one is
exported to the DMA telemetry ring once per second.

| Counter | Width | Class | Alarm |
| --- | ---: | --- | --- |
| `rx_frames`, `rx_bytes` | 48 | volume | rate deviation |
| `rx_msgs`, `msgs_filtered`, `msgs_to_book` | 48 | volume | — |
| `drop_fcs`, `drop_not_ours`, `drop_session` | 32 | error | any non-zero |
| `drop_malformed`, `drop_len_mismatch`, `drop_unknown_type` | 32 | error | **any non-zero → page** |
| `drop_bad_locate` | 32 | error | any non-zero |
| `gap_a`, `gap_b`, `gap_both` | 32 | error | `gap_both` → page |
| `gap_max_size` | 32 | error | — |
| `dup_a`, `dup_b` | 48 | normal | absence is the alarm (means a feed is down) |
| `a_wins`, `b_wins` | 48 | normal | strong asymmetry → path problem |
| `window_overrun` | 32 | **must be 0** | design invariant violated → kill switch |
| `first_error_type`, `first_error_ts` | 8 / 64 | sticky | first-fault latch, cleared only by the CPU |

⚠️ **Sticky-on-first-error.** A transient that self-clears between two 1 Hz polls is
invisible in a plain counter delta. Every error class latches its first occurrence
with a timestamp and does not clear itself.

---

## 11. Feed handler latency budget (rows R0–R5)

| Row | Stage | Module | Cycles | ns | Cum. ns | Notes |
| --- | --- | --- | ---: | ---: | ---: | --- |
| R0 | Ingress register + timestamp capture | `ts_capture` | 1 | 6.4 | 6.4 | fixed |
| R1 | Eth / IPv4 / UDP parse, group → channel | `ipv4_udp_rx_parse` | 1 | 6.4 | 12.8 | **once per packet** |
| R2 | MoldUDP64 header, seq compare, A/B mux | `mold_deframe`, `ab_arbiter`, `seq_tracker` | 1 | 6.4 | 19.2 | **once per packet** |
| R3 | Window realign + message-complete test | `msg_realign` | 1 | 6.4 | 25.6 | per message, II = 1 |
| R4 | Type dispatch + fixed-offset field extract | `itch_dispatch` | 1 | 6.4 | 32.0 | per message, II = 1 |
| R5 | Locate filter + slot map | `symbol_filter` | 1 | 6.4 | 38.4 | per message, II = 1 |
| | **Feed handler total** | | **6** | **38.4** | | |
| | *message k > 0 in a packet* | | *4* | *25.6* | | R1/R2 already paid |

**Resource estimate (unmeasured, pre-synthesis):**

| Module | LUT | FF | BRAM36 | URAM |
| --- | ---: | ---: | ---: | ---: |
| `msg_realign` | ~2,400 | ~1,200 | 0 | 0 |
| `itch_dispatch` | ~1,800 | ~400 | 1 (len LUT) | 0 |
| `symbol_filter` | ~150 | ~60 | 2 | 3 |
| `mold_deframe` ×2 + `ab_arbiter` + `seq_tracker` | ~900 | ~700 | 0 | 0 |
| `ipv4_udp_rx_parse` | ~600 | ~350 | 0 | 0 |

---

## 12. Testability: how this block is driven from pcap

The feed handler is the one block that can be tested against **real production
traffic** without a venue connection, and it must be.

### 12.1 The harness

```
tb/feed/
├── test_feed.py              cocotb testbench
├── golden/itch_model.py      pure-Python reference decoder (the oracle)
├── drv/axis_pcap_driver.py   pcap → 64-bit AXI-S beats, with tkeep and IFG
├── fixtures/
│   ├── nasdaq_open_1s.pcap        real capture: 09:29:30–09:30:30
│   ├── nasdaq_quiet_1s.pcap       real capture: midday
│   ├── synth_align_sweep.pcap     GENERATED — see 12.3
│   ├── synth_maxrate.pcap         GENERATED — minimum-size msgs at line rate
│   └── synth_gaps.pcap            GENERATED — every gap shape
└── scripts/mk_fixtures.py
```

```python
@cocotb.test()
async def test_pcap_replay(dut):
    drv = AxisPcapDriver(dut, "s_mac_rx", width=64)
    mon = BookCmdMonitor(dut, "book_cmd")
    ref = ItchGoldenModel(subscribed=SUBS, slot_map=SLOTS)

    for pkt in read_pcap("fixtures/nasdaq_open_1s.pcap"):
        ref.feed(pkt)                       # oracle
        await drv.send(pkt, ifg=random_ifg())   # DUT, with randomised inter-frame gap
    await ClockCycles(dut.clk, 32)

    assert mon.captured == ref.expected_cmds     # exact, ordered, field-by-field
    assert dut.window_overrun.value == 0
    assert dut.drop_malformed.value == 0
```

### 12.2 What the golden model must be

A **byte-exact independent implementation** in Python, written from the spec, not
from the RTL. If it is derived from the RTL it validates nothing. It emits the
expected `book_cmd` sequence; the testbench compares field by field, in order.

### 12.3 The alignment sweep — the test that matters

The realignment logic in §4 is the block's highest-risk code, and its bugs are
alignment-dependent, which means production traffic will hit them at 3 a.m. and never
in a unit test. So generate the sweep exhaustively:

```python
# scripts/mk_fixtures.py
def alignment_sweep():
    """Every ITCH type, at every byte offset 0..7 within a beat,
       straddling 0..N beat boundaries, in packets of 1..8 messages."""
    for mtype, mlen in ITCH_LENGTHS.items():
        for pad in range(8):                    # start offset within the beat
            for nmsgs in (1, 2, 3, 8):
                yield mold_packet(pad_prefix=pad, msgs=[msg(mtype)] * nmsgs)
```

That is a few thousand packets, runs in seconds under Verilator, and it covers the
entire straddle state space. **This test is mandatory in CI.**

### 12.4 The rest of the required suite

| Test | Asserts |
| --- | --- |
| Line-rate soak (`synth_maxrate`, back-to-back `D` messages, zero IFG for 10⁶ frames) | `window_overrun == 0`, no dropped message, `msgs_to_book` matches the oracle exactly |
| Randomised IFG | results are independent of inter-frame gap (they must be) |
| Gap shapes (`synth_gaps`: 1, 2, 1000-message gaps; gap on A only; on B only; on both; out-of-order) | `channel_stale` asserted iff both feeds gapped; `next_expected` resyncs; no stall |
| Truncated / oversized packet | `drop_malformed`, packet abandoned, next packet decodes cleanly |
| Length-mismatch injection | entire remaining packet abandoned (§6.2), not just the bad message |
| Unknown type byte injection | counted, message skipped by its framing length, next message decodes |
| Latency assertion | `cmd_valid` occurs exactly `LATENCY_CYCLES` after `msg_valid`, every time |
| Fuzz | 10⁶ random byte strings framed as MoldUDP64 — must never assert `window_overrun`, never hang, never emit a `book_cmd` with `slot >= N_SYMBOLS` |

The fuzz test's job is not to find decode bugs. It is to prove that **no input
sequence can wedge the pipeline**, because the RX path has no way to recover from
being wedged other than a reset, and a reset costs you the whole book.

---

## Further reading

- [01-tick-to-trade-pipeline.md](01-tick-to-trade-pipeline.md) — where rows R0–R5 sit in the whole budget
- [03-order-book-in-hardware.md](03-order-book-in-hardware.md) — the consumer of `book_cmd`
- [../01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) — II = 1, width vs. depth
- [../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) — the stream contract, direct-index lookup
- [../01-fpga-design/05-verification-and-simulation.md](../01-fpga-design/05-verification-and-simulation.md) — cocotb and pcap replay mechanics
- [../02-networking/03-multicast-feeds-and-arbitration.md](../02-networking/03-multicast-feeds-and-arbitration.md) — A/B feeds, gap recovery in depth
- [../08-nasdaq/](../08-nasdaq/) — ITCH 5.0 and MoldUDP64 message and field references
