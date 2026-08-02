# 02.03 — Multicast Feeds and Arbitration

> **Why this matters here:** A/B feed arbitration is the first stateful decision in
> the tick-to-trade path, it happens before you have parsed a single ITCH message,
> and getting it wrong costs you either latency (if you arbitrate late) or money (if
> you trade on a book with a hole in it). It is also the one place in the design
> where "drop and count" is not enough — a dropped market-data packet changes what
> you believe about the world.

---

## 1. Why market data is UDP multicast

Exchanges publish to thousands of subscribers simultaneously. The alternatives are
worse in every dimension that matters:

| Transport | Publisher cost | Fairness | Latency |
| --- | --- | --- | --- |
| TCP unicast per subscriber | N connections, N retransmit buffers, N congestion windows | Terrible — subscriber #1 gets the byte before subscriber #1000 | Serialized fan-out at the publisher |
| **UDP multicast** | One send; the network replicates | Good — replication happens in switch silicon, equidistant by design | One serialization, one path |

The trade-off the exchange accepts on your behalf: **no delivery guarantee**. You get
ordering (via a sequence number) and you get a recovery mechanism, but the wire itself
promises nothing.

The exchange's answer to that is **A/B feeds**: the same logical message stream,
sequenced identically, published twice from independent publishers over independent
network paths into your cross-connect. A packet lost on A is almost never lost on B,
because the loss events are uncorrelated (different switch queues, different optics,
different line cards).

**Your job is to consume both and behave as though you consumed one perfect feed.**

---

## 2. MoldUDP64 framing

Nasdaq TotalView-ITCH 5.0 rides inside **MoldUDP64**, which supplies the sequencing
and framing that UDP does not.

```
UDP payload (frame byte 42 onward):

offset  len  field            notes
  0     10   Session          alphanumeric, right-space-padded ("ASCII")
 10      8   Sequence Number  big-endian; sequence of the FIRST message block
 18      2   Message Count    big-endian
 20      -   Message Block[0..Count)

Message Block:
  0      2   Message Length   big-endian, length of Message Data
  2    len   Message Data     one complete ITCH 5.0 message
```

Special values of Message Count:

| Value | Meaning |
| --- | --- |
| `0` | **Heartbeat.** No message blocks. Sequence Number = the next sequence the publisher will send |
| `0xFFFF` | **End of Session.** No more messages this session |
| `1..N` | Normal data packet |

> **Verify:** field widths, endianness, and the special Message Count values against
> the Nasdaq *MoldUDP64 Protocol Specification*, and the message layouts against the
> *Nasdaq TotalView-ITCH 5.0 Specification*. Note that the ITCH *file* format
> prefixes each message with a 2-byte length; on the wire that role is played by the
> Mold message-block length, so do not double-count it.

### Where the fields land in the frame

```
byte:  0        14         34      42          52        60  62  64
       │ Eth 14 │ IPv4 20  │ UDP 8 │ session 10│ seq 8   │cnt│len│ ITCH msg …
                                    └───────── MoldUDP64 header (20 B) ────┘
```

**The sequence number occupies frame bytes 52–59 and the message count 60–61.** With
a 512-bit (64-byte) ingress bus, both are in **beat 0**, alongside the entire
Ethernet/IP/UDP header. The first ITCH message body starts at byte 64 — exactly the
first byte of beat 1.

This alignment is the single most useful fact in this document: **you can make the
complete dedupe/gap decision from beat 0, before a single ITCH byte has been
examined.**

---

## 3. IGMP: do it in software

To receive a multicast group you must join it (IGMPv2, RFC 2236 / IGMPv3, RFC 3376):
send a Membership Report, then keep answering the router's periodic General Queries
for as long as you want the traffic.

**Put this on the host, never in fabric.** It is a timer-driven protocol with
randomized response delays, group-specific queries, and version interop rules — all
of the complexity of a control protocol and none of the latency sensitivity.

⚠️ **The classic silent outage:** the join succeeds, the feed flows, and then 125
seconds later the switch sends a General Query, nothing answers, the group is pruned,
and **the feed stops with no error anywhere in your system**. Not a link fault, not a
CRC error, not a gap — just silence. Guard against it with all three of:

1. The host owns the join and keeps answering queries, on a real socket.
2. A **per-group liveness watchdog in fabric**: if no packet (including heartbeats)
   has arrived for group *g* in `T_watchdog`, raise an alarm and mark the channel
   stale. ITCH heartbeats make this reliable even in quiet periods.
3. If the FPGA has its own IP and the host cannot see the port, implement a **canned
   IGMP report transmitter** — a fixed byte template emitted on a timer. It is a
   dumb, safe, ~50-line block. It is not an IGMP implementation and must not pretend
   to be one.

> **Verify:** the query interval and prune behaviour of the specific colo switch and
> whether the venue's cross-connect expects IGMP at all — some venue hand-offs are
> statically provisioned and never query.

---

## 4. Sequence handling in hardware

State per channel (one channel = one logical A/B pair = one Mold session):

```systemverilog
logic [79:0] session_q;      // 10-byte session ID, latched at start of day
logic [63:0] expected_q;     // next sequence number we need
logic        stale_q;        // book cannot be trusted
logic [63:0] hole_start_q, hole_end_q;
```

For every arriving packet, with `pkt_seq` and `n = msg_count`:

| Condition | Meaning | Action |
| --- | --- | --- |
| `session != session_q` | Wrong session (new trading day, or cross-wired feed) | Drop, count `drop_wrong_session`. ⚠️ Never auto-adopt |
| `n == 0` | Heartbeat | If `pkt_seq > expected_q` → **gap of `pkt_seq − expected_q`**. Otherwise just kick the watchdog |
| `pkt_seq == expected_q` | In sequence | Deliver all `n` messages; `expected_q += n` |
| `pkt_seq + n <= expected_q` | Fully behind | **Duplicate** — the other feed already delivered this. Drop, count `dedupe_hits` |
| `pkt_seq < expected_q < pkt_seq + n` | Partial overlap | ⚠️ Skip the first `expected_q − pkt_seq` blocks, deliver the rest, `expected_q = pkt_seq + n` |
| `pkt_seq > expected_q` | **Gap** of `pkt_seq − expected_q` messages | Enter GAP handling (§6) |

⚠️ **The partial-overlap row is the one everyone gets wrong.** A and B never partially
overlap with each other — they packetize identically — so it never shows up in normal
traffic and never shows up in your test pcaps. It shows up when a *retransmission*
arrives from the recovery path covering a range that partially straddles what you
already have. Skipping blocks means walking the message-block length fields to find
the right starting offset, which is a multi-cycle operation. That is fine: this path
is by definition a recovery path. **Implement it as a slow, obviously-correct
sequential walker, and write the test that exercises it.**

---

## 5. A/B arbitration

### The algorithm is: there isn't one

The naive design is a real arbiter — wait for both feeds, compare, prefer A. **Do not
build this.** Waiting for B costs you the A/B skew (tens of microseconds) on *every*
packet, to protect against a loss rate of order 10⁻⁶.

The correct design is **first-arrival wins, dedupe by sequence number**, and it needs
no arbiter at all because the sequence check *is* the dedupe:

```
Both A and B feed the SAME per-channel sequencer.
The first copy to arrive has pkt_seq == expected → delivered.
The second copy arrives with pkt_seq + n <= expected → dropped as a duplicate.
```

No timers. No preference. No waiting. The loser's packet is discarded by logic that
already had to exist.

### Arbitrate *early* — the latency argument

| Where you dedupe | Cost |
| --- | --- |
| **At the Mold header, beat 0** (recommended) | 1–2 cycles = **6–13 ns**. One decode pipeline. |
| After ITCH parsing | Two full decode pipelines (2× LUT/BRAM) or a serializer that adds a packet time |
| At the book | You have already spent the entire parse budget twice, and you must make every book update idempotent — a much harder correctness property |

The dedupe decision needs **10 bytes** (sequence + count). Those bytes are in beat 0.
Spending the whole feed-handler pipeline before making a decision you could have made
in cycle 1 is the definition of wasted latency.

### The one place a real arbiter is needed

A and B are on **different physical ports** and can present a beat in the same cycle.
They must merge onto one downstream 512-bit stream.

```
port A ──▶ [ingress FIFO, 2 max frames] ──┐
                                          ├──▶ fixed-priority mux ──▶ sequencer ──▶ parser
port B ──▶ [ingress FIFO, 2 max frames] ──┘
```

- **Fixed priority, A over B.** Round-robin buys fairness you do not want; the loser's
  packet is a duplicate anyway in the overwhelming majority of cases.
- The FIFOs exist to absorb *arbitration collision*, not rate mismatch: internal
  bandwidth is 512 bits × 156.25 MHz = **80 Gbps** against 2 × 10 Gbps of ingress, so
  a collision is drained within a few cycles and the FIFOs are essentially never more
  than one frame deep.
- ⚠️ **Arbitrate at packet granularity, not beat granularity.** Interleaving beats
  from two ports onto one stream corrupts both. The mux locks to a port from
  `tvalid && sop` until `tlast`.
- Count `arb_collisions` and `ingress_fifo_high_water` per port. If the high-water
  mark ever approaches the FIFO depth, your assumptions are wrong and you want to
  know before the packet is lost.

### Measuring A/B skew

Timestamp every packet at ingress, per port, from the same hardware counter. For each
sequence number seen on both feeds, record `t_B − t_A` in a fabric histogram.

| Signal | What it tells you |
| --- | --- |
| Median skew | Baseline path difference. Tens of µs is normal; it is set by the exchange's publisher and your network path |
| Skew distribution widening | A queue is building somewhere on one path |
| One feed winning ~100 % of races | The other path has extra hops or worse optics — a fixable, *paid-for* latency loss |
| Per-feed loss rate | Which cross-connect or optic is degrading, before it fails |

Expose `feed_a_wins`, `feed_b_wins`, `dedupe_hits`, and a skew histogram as readable
registers. This is one of the highest-value pieces of telemetry in the whole system:
it turns a network problem into a number.

---

## 6. Gaps

### The gap buffer

When `pkt_seq > expected_q`, the missing messages are usually in flight on the other
feed and will arrive within the A/B skew. So do not panic and do not throw the future
away:

```
enter GAP:
    hole_start = expected_q
    hole_end   = pkt_seq
    stale      = 1                       ← immediately, before anything else
    start gap_timer
    push this packet (and every subsequent one) into the gap buffer, tagged with seq

on each arrival while in GAP:
    if pkt_seq == expected_q:            ← the hole is filling
        deliver it; expected_q += n
        then drain the gap buffer head-first, applying the §4 rules to each
        (buffered packets are already in ascending order — each feed delivers
         in order, so arrival order is ascending within the buffer)
        if the buffer drains empty and expected_q >= hole_end:
            stale = 0; exit GAP
        if a new hole appears mid-drain: update hole_start/hole_end, stay in GAP
    else:
        push into the gap buffer (drop if full → count gap_buffer_overflow)

on gap_timer expiry:
    escalate: raise a gap event to the host, keep stale = 1, stop quoting
```

**Sizing the gap buffer.** It must hold everything that arrives during the gap
timeout:

```
gap_buffer_bytes  ≥  peak_channel_rate × gap_timeout × safety_factor
gap_timeout       ≈  2 × measured p99.9 A/B skew
```

Measure `peak_channel_rate` from a pcap of the market open, not from the nominal feed
bandwidth — ITCH is extremely bursty and the 09:30:00 burst is many times the daily
mean. A 200 µs timeout against a 3 Gbps burst is 75 kB; a 128 kB URAM-backed buffer
covers it with room. **Both numbers go in the module header as a documented budget.**

> **Verify:** peak burst rate for the specific channel from a captured open. Do not
> use the venue's published "peak messages/sec" figure without converting it with the
> actual message-size mix.

### ⚠️ Trading on a book you know has a gap

This is the correctness hazard that justifies the whole document.

**A MoldUDP64 gap does not tell you which symbols you missed.** Nasdaq TotalView-ITCH
is a single sequenced channel covering every symbol. The missing messages could be an
Order Delete on your best bid, a Trade that moved the price, or a Stock Trading Action
halting the name you are quoting. You cannot know.

Therefore:

> **A gap on the channel invalidates the entire book, not one symbol.**

Required policy, enforced in hardware:

1. `stale` is asserted **on the cycle the gap is detected**, before any recovery
   attempt, before the host is told.
2. `stale` is an **input to the strategy trigger's enable term**. It is not advisory.
   No new quotes, no new aggressive orders, for any symbol on that channel.
3. Resting orders are cancelled — or you rely on the venue's cancel-on-disconnect,
   which you must have configured and tested. Decide which, write it down, and test
   it in UAT.
4. The event is counted (`gap_events`), the gap size is recorded, and both are
   readable and alerted on.
5. `stale` clears **only** when the sequence is contiguous again from `hole_start`
   through the present. There is no manual override register. If you want one, you
   want a bug.

⚠️ The tempting failure mode is "the gap was only 3 messages, keep going". Three
messages is enough to leave a phantom order in your book that you will quote against
and be filled on — and you will be filled precisely because someone else knows it is
not there. **A stale book does not degrade gracefully; it degrades adversarially.**

### Recovery belongs on the CPU

The FPGA detects the gap and stops. The host fixes it:

| Mechanism | What it is | Where it runs |
| --- | --- | --- |
| **MoldUDP64 retransmission request** | Unicast request to the venue's request server for `(session, seq, count)`; the messages come back unicast | Host, on a socket |
| **Glimpse snapshot** | A SoupBinTCP connection that delivers a point-in-time book image plus the sequence number to resume from | Host |
| **Wait for the other feed** | Already handled by the gap buffer | Fabric |

The recovered messages are DMA'd back to the FPGA and injected into a **third input
port on the same sequencer** — not into the parser directly. They pass through the
identical `expected_q` logic, so ordering and dedupe are enforced by construction and
there is exactly one place in the design that decides what the book sees.

```
port A ─────┐
port B ─────┼──▶ ingress FIFOs ──▶ mux ──▶ SEQUENCER ──▶ parser ──▶ book
host replay ┘                              (expected_q, gap buffer, stale)
```

> **Verify:** the exact retransmission request format, the request server's rate
> limits, and the maximum retransmittable range against the Nasdaq MoldUDP64
> specification. Request servers throttle; a naive recovery loop can get you blocked.

### Start of day

For Nasdaq equities you usually do not need a snapshot at all: **join before the
System Event "Start of Messages" and the book builds itself from an empty state.**
That is the primary strategy for this project — it is simpler, has no snapshot/live
race, and is exactly the path you exercise every morning.

Glimpse is the *fallback*, for a mid-day restart or an unrecoverable gap:

1. Host connects to Glimpse, receives the snapshot and the resume sequence number.
2. Host buffers live multicast throughout.
3. Host builds the book image and DMAs it into FPGA URAM.
4. Host sets `expected_q` = resume sequence, replays the buffered live messages
   through the sequencer, then clears `stale`.

⚠️ The FPGA must be **disarmed** (no order emission) for the whole of this procedure,
and re-arming must be an explicit host action, not a side effect of `stale` clearing.

---

## 7. Multiple ports and multiple channels

| Topology | Ports | Sequencers | Notes |
| --- | --- | --- | --- |
| One channel, A/B | 2 | 1 | The baseline for this project |
| One channel, A/B, + host replay | 2 + PCIe | 1 | Recovery injection, as above |
| Two channels (e.g. ITCH + a second venue), A/B each | 4 | 2 | Classify by `(dst IP, dst UDP port)` on beat 0 → channel index |
| A/B arriving multiplexed on one port | 1 | 1 | Possible if a layer-1 device merges them upstream; the sequencer is unchanged |

The classifier is a small comparator array on beat 0 producing a channel index, and
the sequencer state is a register file indexed by that channel. **Never key channel
state on the Mold session string** — comparing 10 bytes is fine at start of day for
validation, but the per-packet index must be a small integer resolved in one cycle.

⚠️ **Each channel gets its own `stale` bit and its own strategy-enable term.** A gap
on venue X must not stop you quoting a symbol whose book is built from venue Y. But
within a channel, `stale` is global — see §6.

---

## 8. Buffering at the open

The RX path runs at guaranteed line rate with no backpressure, so buffers in this
design exist for exactly two reasons:

| Buffer | Purpose | Sizing |
| --- | --- | --- |
| Per-port ingress FIFO | Absorb arbitration collision between A and B | 2 × max frame (≈ 3 kB). Internal bandwidth is 8× ingress; it drains in cycles |
| Gap buffer | Hold ahead-of-gap packets for the gap timeout | `peak_rate × gap_timeout × safety` (§6) |
| Host event ring (PCIe) | Gap events, telemetry, TX records | Sized in software, and the FPGA **drops and counts** if it fills |

**If you ever find yourself sizing a fabric buffer to absorb a sustained rate
mismatch, the design is wrong.** A buffer that hides a rate mismatch converts a
throughput bug into a latency bug that only appears at the open, which is the worst
possible time to discover it. The downstream datapath must be at least as wide as the
aggregate ingress, all the way to the book.

⚠️ Microbursts at 09:30:00.000 are real and are much larger than the daily mean.
Validate with a pcap-driven cocotb replay of a real open, at wire rate, with zero
inserted idle cycles — not with a synthetic uniform stream. See
[../01-fpga-design/05-verification-and-simulation.md](../01-fpga-design/05-verification-and-simulation.md).

---

## 9. Project rules

1. **Dedupe on beat 0**, from the MoldUDP64 sequence number and message count, before
   any ITCH parsing. One decode pipeline, not two.
2. **First arrival wins.** No feed preference, no waiting for the second copy, no
   timers in the steady-state path.
3. **One sequencer per channel** is the single authority on what the book sees. A, B,
   and host replay all enter through it.
4. **A gap marks the whole channel stale, immediately, in hardware**, and `stale`
   gates the strategy trigger. There is no override register.
5. **`stale` clears only on verified sequence contiguity**, never by host write alone.
6. **The partial-overlap case is implemented and tested**, as a deliberately slow
   sequential walker.
7. **Recovery (retransmission requests, Glimpse) is host-side.** The FPGA signals and
   waits.
8. **Primary start-of-day strategy is "join early, build from empty."** Glimpse is
   the documented fallback, and the FPGA is disarmed throughout a Glimpse rebuild.
9. **IGMP is host-side**, backed by a fabric per-group liveness watchdog. A silent
   feed is an alarm, not a quiet afternoon.
10. **Telemetry is mandatory**, per channel and per feed: `feed_a_wins`,
    `feed_b_wins`, `dedupe_hits`, `gap_events`, `gap_max_size`,
    `gap_buffer_overflow`, `arb_collisions`, `ingress_fifo_high_water`,
    `drop_wrong_session`, A/B skew histogram, and last-packet-age per group.
11. **Never auto-adopt a new Mold session ID.** A session change is a start-of-day
    event driven by the host, not something hardware infers from a packet.

---

## Further reading

- [01-ethernet-phy-mac.md](01-ethernet-phy-mac.md) — the `frame_commit` gate a bad FCS drives into the gap logic
- [02-ip-udp-tcp-in-hardware.md](02-ip-udp-tcp-in-hardware.md) — the header parse that produces the channel index
- [04-nics-kernel-bypass-and-switching.md](04-nics-kernel-bypass-and-switching.md) — how the A and B paths physically reach you
- [../03-algotrading/03-market-data-protocols.md](../03-algotrading/03-market-data-protocols.md) — ITCH 5.0 message semantics above Mold
- [../04-system-architecture/02-feed-handler-design.md](../04-system-architecture/02-feed-handler-design.md) — the parser this sequencer feeds
- [../04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md) — what `stale` protects
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) — surfacing the counters in §9
