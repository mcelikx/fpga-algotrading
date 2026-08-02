# 02.02 — IP, UDP, and TCP in Hardware

> **Why this matters here:** market data arrives as UDP and orders leave as TCP.
> Parsing 42 bytes of header in one cycle is easy and costs ~6 ns; doing it *safely*
> — so a VLAN tag or an IP option can never silently shift your ITCH parser by four
> bytes — is the part that takes discipline. And TCP, which nobody wants in fabric,
> sits directly on the order path. This document says exactly how much of each stack
> belongs in hardware.

---

## 1. The header stack, byte by byte

For an untagged Ethernet II frame carrying IPv4/UDP:

```
byte  0        6        12 14                                34         42
      ┌────────┬────────┬──┬──────────────────────────────────┬──────────┬─────────
      │ dst MAC│ src MAC│ET│          IPv4 header (20 B)      │ UDP (8B) │ payload
      └────────┴────────┴──┴──────────────────────────────────┴──────────┴─────────
                          └ 0x0800

IPv4 (base at byte 14):
 +0  ver|IHL   +1  DSCP/ECN   +2..3  total length   +4..5  identification
 +6..7  flags|fragment offset  +8  TTL   +9  protocol   +10..11  header checksum
 +12..15  source address       +16..19  destination address   [+20.. options]

UDP (base at byte 34):
 +0..1 src port   +2..3 dst port   +4..5 length (hdr+data)   +6..7 checksum
```

| Field | Byte offset | Why you care |
| --- | --- | --- |
| Destination MAC | 0–5 | Multicast MAC `01:00:5E:xx:xx:xx` maps the group; we do not filter on it |
| EtherType | 12–13 | `0x0800` IPv4, `0x0806` ARP, `0x8100` VLAN, `0x86DD` IPv6 |
| Version / IHL | 14 | ⚠️ must be `0x45`. See §2 |
| Total length | 16–17 | **The authoritative payload length** — not the frame length |
| Flags / frag offset | 20–21 | ⚠️ must be 0 or `DF` only. See §2 |
| Protocol | 23 | `17` UDP, `6` TCP |
| Header checksum | 24–25 | Cheap to verify, do it |
| Src / dst IP | 26–29 / 30–33 | Feed identity (with dst port) |
| UDP src / dst port | 34–35 / 36–37 | **This is how you identify the feed channel** |
| UDP length | 38–39 | Header + data, so payload = len − 8 |
| UDP checksum | 40–41 | Zero = "not computed", legal for IPv4 |
| Payload | 42+ | MoldUDP64 starts here |

**With a 512-bit (64-byte) datapath, all of this lands in beat 0.** So does the
MoldUDP64 header (bytes 42–61) and the first message-block length (bytes 62–63).
That is not a coincidence — it is the reason the project uses a 512-bit ingress bus.

### Extraction with fixed slices

```systemverilog
// Convention: beat[8*n +: 8] is the n-th byte received (n = 0 arrives first).
// Multi-byte header fields are big-endian ("network order") and must be swapped.
function automatic logic [15:0] be16(input logic [511:0] b, input int n);
    return {b[8*n +: 8], b[8*(n+1) +: 8]};
endfunction
function automatic logic [31:0] be32(input logic [511:0] b, input int n);
    return {b[8*n +: 8], b[8*(n+1) +: 8], b[8*(n+2) +: 8], b[8*(n+3) +: 8]};
endfunction

localparam int O_ETYPE = 12, O_IP = 14, O_UDP = 34, O_PAY = 42;

logic [15:0] ethertype  = be16(beat0, O_ETYPE);
logic [7:0]  ver_ihl    = beat0[8*(O_IP+0) +: 8];
logic [15:0] ip_totlen  = be16(beat0, O_IP + 2);
logic [15:0] ip_fragoff = be16(beat0, O_IP + 6);
logic [7:0]  ip_proto   = beat0[8*(O_IP+9) +: 8];
logic [31:0] ip_dst     = be32(beat0, O_IP + 16);
logic [15:0] udp_dport  = be16(beat0, O_UDP + 2);
logic [15:0] udp_len    = be16(beat0, O_UDP + 4);
logic [15:0] udp_csum   = be16(beat0, O_UDP + 6);
```

Zero logic. Pure wiring. This is what "parsing in hardware" means and why it costs
one cycle: the slices are free, the *decisions* built on them are the logic.

---

## 2. ⚠️ The three things that break fixed offsets

Every one of these produces a design that works perfectly on your test pcap and
mis-parses in production.

| Hazard | What shifts | Detection |
| --- | --- | --- |
| **IPv4 options** (IHL > 5) | UDP header moves to `14 + IHL*4`, everything after it shifts by 4–40 bytes | `ver_ihl != 8'h45` |
| **VLAN tag** (802.1Q, EtherType `0x8100`) | Everything from byte 14 shifts by **4**. QinQ (`0x88A8`) shifts by **8** | `ethertype == 16'h8100 \|\| 16'h88A8` |
| **IP fragmentation** | Fragment 2..N has *no UDP header at all* — byte 34 is payload | `ip_fragoff[12:0] != 0 \|\| ip_fragoff[13]` (MF set) |

The fragmentation case is the nastiest: a fragment's byte 42 is arbitrary payload,
which your Mold parser will happily read as a session ID and sequence number, and
your sequence logic will then see a wild sequence jump and declare a catastrophic
gap — or, worse, a plausible one.

### The rule: fast path is fixed-slice, guarded by a validity predicate

```systemverilog
// Computed entirely from beat 0. One cycle. No shifting, no variable offsets.
logic pkt_ok;
assign pkt_ok = (ethertype   == 16'h0800)   // IPv4, untagged
             && (ver_ihl     == 8'h45)      // v4, no options
             && (ip_fragoff[13] == 1'b0)    // MF clear
             && (ip_fragoff[12:0] == 13'd0) // fragment offset zero
             && (ip_proto    == 8'd17)      // UDP
             && (ip_hdr_csum_ok)
             && (udp_len     >= 16'd28);    // 8 UDP + 20 Mold header minimum

// Anything else: drop, and count it in a *distinct* counter per reason.
```

**Never build a variable-offset shifter on the fast path.** A barrel shifter across
a 512-bit bus is expensive, slow, and — because it is exercised only by traffic you
should not be seeing — under-tested. Drop, count, and let the CPU look at the
counters. If a venue genuinely starts VLAN-tagging your cross-connect, that is a
change-control event, not something the hardware should silently absorb.

⚠️ **A counter that is always zero in testing is not a dead counter.** Each of these
reasons gets its own counter (`drop_vlan`, `drop_ip_options`, `drop_frag`,
`drop_proto`, `drop_ip_csum`) because "packets dropped" with no reason code is
useless at 09:31 on a bad morning.

---

## 3. Checksums

### IPv4 header checksum
16-bit ones'-complement sum of the ten 16-bit words of the header, complemented.
Verification is trivial: sum all ten words *including* the checksum field; a valid
header gives `0xFFFF`.

In fabric: a 10-input adder tree with a carry fold. ~2 levels, well under a cycle at
156.25 MHz. **Always check it.** It is free and it catches the class of corruption
that a cut-through switch can introduce after the FCS was last recomputed.

### UDP checksum on RX
Covers a **pseudo-header** (src IP, dst IP, zero byte, protocol = 17, UDP length)
plus the UDP header plus the payload.

- **A UDP checksum of zero means "not computed"** and is legal for IPv4 (RFC 768).
  Many market-data publishers send zero. You must handle it.
- Over IPv6 it is mandatory and zero is illegal (RFC 8200 §8.1). Not relevant here.

> **Verify:** whether your venue's feed populates the UDP checksum at all — capture
> a pcap of the live feed and look. Do not assume.

The checksum covers the payload, so — exactly like the Ethernet FCS — you cannot
validate it until the packet has fully arrived. It has the same resolution:

**Project decision:** compute the UDP checksum in a streaming accumulator and fold
its result into the **same `frame_commit` gate** as the Ethernet FCS (see
[01-ethernet-phy-mac.md](01-ethernet-phy-mac.md) §6). It never adds latency, it
increments a *separate* counter (`rx_udp_csum_error`), and — because CRC-32 is a far
stronger code than a 16-bit ones' complement sum over the same bytes — a UDP
checksum failure with a passing FCS almost always means a device *between* the
publisher and you recomputed the FCS over corrupted data. That is an operational
signal worth having, not just a drop reason.

### UDP/TCP checksum on TX — and why it's harder
The checksum sits in the header, which goes out **before** the payload it covers.
Three ways out:

| Approach | Cost | Use |
| --- | --- | --- |
| Store-and-forward the outbound frame | One frame time (≈ 50 ns for a 64 B OUCH order at 10G) | Acceptable fallback |
| **Incremental / partial-sum from a template** | ~0 | **This project** |
| Set UDP checksum = 0 | Free, but illegal for TCP and rude for UDP | Never for order entry |

---

## 4. The incremental checksum — the key order-path optimization

Every outbound order in this system is the *same bytes* except for a handful of
fields: sequence number, symbol, price, quantity, side, order token. The Ethernet,
IP, and TCP headers are constant for the whole session. So do not recompute the
checksum — **precompute the constant part in software and add only what changes.**

### Setup (host, once per session)

```
S_const = ones_complement_sum( every 16-bit word that will not change )
          including the pseudo-header words (src IP, dst IP, proto, and any
          constant part of the length), and EXCLUDING:
            - the checksum field itself
            - every 16-bit word the FPGA will patch per-order
Push S_const to the FPGA with the rest of the frame template.
```

### Per-order (fabric, combinational + 1 register stage)

```systemverilog
// Wide accumulator: no iterative folding, one fold at the end.
// 16 bits of value + log2(#words) of carry headroom.
logic [23:0] acc;

always_comb begin
    acc = {8'd0, s_const};              // from the host template
    acc += seq_num[31:16];  acc += seq_num[15:0];
    acc += ack_num[31:16];  acc += ack_num[15:0];
    acc += pseudo_len;                   // TCP length varies with payload size
    for (int i = 0; i < N_VAR_WORDS; i++)
        acc += var_word[i];              // price, qty, token, symbol, ...
end

// Fold carries into the low 16 bits. Two folds always suffice for a 24-bit acc.
logic [16:0] f0; logic [15:0] f1, csum;
assign f0   = acc[15:0] + acc[23:16];
assign f1   = f0[15:0]  + {15'd0, f0[16]};
assign csum = ~f1;
// UDP only: a transmitted 0x0000 means "no checksum", so send 0xFFFF instead.
// TCP: 0x0000 is a legal checksum value — do NOT substitute.
```

The adder tree is ~`log2(N)` levels deep over a handful of words. At 156.25 MHz this
is comfortably one cycle, often zero if merged into the encoder stage.

### The RFC 1624 form, for when you patch a live header
If you have a valid header and change one 16-bit word `m → m'`:

```
HC' = ~( ~HC + ~m + m' )        (RFC 1624, eqn. 3)
```

⚠️ Use eqn. 3, not the older RFC 1141 form `HC' = ~(~HC + ~m + m')` written as
`HC' = HC - m + m'` — the naive subtraction form produces `0xFFFF` where it should
produce `0x0000` in a corner case, and for UDP those two values mean opposite things
("no checksum" vs. a valid checksum). The partial-sum approach in the block above
sidesteps this entirely because it never subtracts; **prefer it.**

---

## 5. Why TCP in hardware is genuinely hard

UDP is a length field and a checksum. TCP is a distributed algorithm with a decade of
accumulated corrections. What it actually demands:

| Requirement | Why fabric hates it | Reference |
| --- | --- | --- |
| **Retransmission buffer** | Every unacked byte must be stored and randomly re-readable by sequence number, for an unbounded (bandwidth × RTT × RTO) window | RFC 9293 |
| **RTO / RTT estimation** | SRTT/RTTVAR arithmetic, exponential backoff, per-connection timers with millisecond granularity | RFC 6298 |
| **Congestion control** | cwnd, ssthresh, slow start, fast retransmit/recovery — a state machine that is exercised only when things go wrong, i.e. never in your tests | RFC 5681 |
| **Reassembly** | Out-of-order segments need a reorder buffer keyed by sequence, with overlap resolution | RFC 9293 |
| **Connection state machine** | 11 states, TIME_WAIT, simultaneous close, half-close | RFC 9293 §3.3.2 |
| **Options** | MSS, window scale, SACK, timestamps → **variable-length header**, which destroys fixed-slice parsing | RFC 7323, RFC 2018 |
| **Window management** | Zero-window probes, silly-window-syndrome avoidance | RFC 9293 §3.8.6 |
| **Delayed ACK / Nagle** | Timers that directly add latency; must be off | RFC 1122 §4.2.3 |
| **PMTU discovery** | ICMP parsing | RFC 8899 |

None of it is on the critical path. All of it is required for correctness. That
asymmetry is the whole design insight.

### Three viable strategies

| | (a) Full TOE in fabric | (b) **Hybrid split** | (c) Buy a TOE IP core |
| --- | --- | --- | --- |
| Steady-state send latency | Lowest | **Same as (a)** | Vendor-dependent, usually higher |
| Engineering effort | Very high; months, and the bugs are in the rare paths | Moderate | Low, but integration is not free |
| Resource cost | Large (buffers dominate) | Small — a template, a counter, an adder | Large, and opaque |
| Correctness risk | You are re-implementing RFC 9293 under a latency budget | Confined to a narrow, auditable interlock | You inherit someone else's, unverifiable |
| Debuggability | Poor — no tcpdump inside fabric | Good — the CPU has a real socket | Poor |
| Cost | Engineering time | Engineering time | Licence + royalties |

### **Recommendation for OUCH 5.0 over SoupBinTCP: (b), the hybrid split.**

The CPU owns the connection. The FPGA owns exactly one thing: emitting a
pre-validated segment on an already-established connection, fast.

---

## 6. Hybrid TCP: the design

```
        ┌──────────────────────── HOST (slow path) ─────────────────────────┐
        │  real socket / kernel-bypass stack                                │
        │  · SYN, options, SoupBinTCP Login → LoginAccepted                 │
        │  · owns retransmission buffer, RTO, congestion control, teardown  │
        │  · owns the authoritative rcv/snd state                           │
        └───────┬──────────────────────────────────▲────────────────────────┘
       template │ arm                         DMA  │ tx_record{seq,len,bytes,ts}
                │                                  │ rx_copy (every inbound segment)
        ┌───────▼──────────────────────────────────┴────────────────────────┐
        │  FPGA                                                             │
        │   TX: [ frame template ] + patch{seq, ack, len, csum} + OUCH body │
        │       snd_nxt += payload_len                                      │
        │   RX: snoop inbound → shadow{rcv_nxt, snd_una, snd_wnd}; forward  │
        │       every byte to the host ring unmodified                      │
        └───────────────────────────────────────────────────────────────────┘
```

### The template
The host writes, into FPGA registers/BRAM, a complete byte image of the outbound
frame with every constant field filled in:

| Region | Contents | Patched per order? |
| --- | --- | --- |
| Ethernet | dst MAC (venue gateway, from static ARP), src MAC, EtherType | no |
| IPv4 | ver/IHL, TTL, proto=6, src/dst IP, **total length**, header checksum | length + checksum only |
| TCP | src/dst port, data offset, flags = `ACK\|PSH`, window | no |
| TCP | **sequence number**, **acknowledgement number**, **checksum** | **yes** |
| SoupBinTCP | packet length, packet type `U` (Unsequenced Data) | length only |
| OUCH | message type, order token, symbol, side, qty, price, TIF, firm | **yes** |
| — | `S_const` (partial checksum of all constant words + pseudo-header) | no |

Because the OUCH message length is fixed for a given message type, the IP total
length, TCP length, and SoupBinTCP length are all **constants per message type** —
which means they can live in `S_const` too, and the per-order patch reduces to
`{seq, ack, order fields}`.

### The FPGA's TX rule

```
on strategy_fire && risk_pass && frame_commit:
    seq   = snd_nxt                       // hardware-owned register
    ack   = max(rcv_nxt_shadow, ack_hwm)  // never regress — see hazard 2
    csum  = fold(S_const + seq + ack + patched_words)
    emit(template with patches)
    snd_nxt  += payload_len
    ack_hwm   = ack
    DMA to host: { seq, payload_len, exact bytes, hw timestamp }
```

### The FPGA's RX rule
Snoop, do not own. For every inbound TCP segment on the session 4-tuple:
`rcv_nxt_shadow = seg.seq + seg.len` (only if `seg.seq == rcv_nxt_shadow`),
`snd_una = max(snd_una, seg.ack)`, `snd_wnd = seg.window << wscale`. Then forward
the segment to the host verbatim. **The host is the authority on RX**; the shadow
exists only to fill the ACK field and to enforce the send window.

### The CPU's reconciliation
The host consumes the TX record ring, matches it against what its own stack believes,
and maintains the retransmission buffer from the exact bytes the FPGA sent. If the
venue's ACKs stop advancing, the *host* retransmits — from software, slowly. That is
correct: a retransmission means the fast path already failed, and shaving nanoseconds
off a recovery path is pointless.

### ⚠️ The five hazards

1. **Dual writers on `snd_nxt`.** If the CPU and the FPGA both transmit, they consume
   overlapping sequence space and the connection is corrupted beyond recovery.
   *Mitigation:* an explicit `arm`/`disarm` register with a hardware acknowledgement.
   `snd_nxt` is writable by the host **only while disarmed**. The host stack must not
   write to that socket while armed — enforce it in the host code and assert on it.
2. **Regressing ACK numbers.** Emitting an ACK lower than one you already sent looks
   like a duplicate ACK; three of them trigger fast retransmit at the venue.
   *Mitigation:* the `ack_hwm` high-water register above. Never emit below it.
3. **Send-window exhaustion.** If `snd_nxt − snd_una ≥ snd_wnd` you must not send.
   OUCH messages are tiny and Nasdaq's window is large, so this should never fire —
   which is exactly why it needs a counter and an alert, not silence.
4. **Sending after FIN/RST.** If the venue closes or resets, the FPGA must stop
   *immediately*, not on the next host poll. *Mitigation:* the RX snoop watches for
   `FIN`/`RST` on the 4-tuple and disarms the TX path in hardware, in the same cycle
   it forwards the segment to the host.
5. **Stale template after a re-login.** A new SoupBinTCP session means new sequence
   space and possibly a new source port. *Mitigation:* the template carries a
   `session_epoch`; the TX path refuses to fire if the epoch register does not match
   the armed value.

This is a small, enumerable set of interlocks. That is the point of choosing (b): the
correctness surface is a page of rules, not RFC 9293.

---

## 7. ARP: keep it out of fabric

ARP is a request/response protocol with a cache, timers, and retries. It is needed
exactly twice per day and never on the critical path.

**Project rule: the FPGA never originates ARP.** The venue gateway's MAC address is
resolved by the host at startup — or configured statically — and written into the TX
template. On Linux:

```
ip neigh replace <venue-gw-ip> lladdr <venue-gw-mac> dev <if> nud permanent
```

But you cannot ignore ARP entirely:

- ⚠️ **You must still *answer* ARP.** If the venue gateway's own cache expires and it
  ARPs for your IP with nobody responding, your session dies mid-day. The FPGA
  classifies EtherType `0x0806` to the host slow-path RX ring; the host answers.
  Verify this works by flushing the peer's cache in a UAT session — do not assume it.
- Send a **gratuitous ARP** at startup so the gateway learns you without asking.
- If the FPGA is a bump-in-the-wire and the host NIC owns the IP, ARP is entirely the
  host's problem and the FPGA just passes it through. Prefer this when you can.

The same logic applies to ICMP: classify to the host, never handle in fabric. And to
IGMP — see [03-multicast-feeds-and-arbitration.md](03-multicast-feeds-and-arbitration.md) §3.

---

## 8. Project rules

1. **Fixed slices only on the fast path.** No variable-offset shifter, no barrel
   shifter over the header region.
2. **Every packet passes a validity predicate computed from beat 0.** IPv4, IHL = 5,
   unfragmented, expected protocol, valid IP header checksum. Failures drop and
   count, **with a distinct counter per reason**.
3. **VLAN tags, IP options, and fragments are dropped, not handled.** If production
   traffic ever contains them, that is a change-control event.
4. **Feed identity is `(dst IP, dst UDP port)`**, resolved to a channel index in one
   cycle from a small comparator array. Never filter on MAC address.
5. **UDP checksum is verified into the same commit gate as the FCS**, with its own
   counter. A zero checksum is accepted and counted separately.
6. **TX checksums are always incremental from a host-supplied `S_const`.** No
   store-and-forward on the order path.
7. **TCP is hybrid-split.** The FPGA emits segments; it does not own the connection.
   The five interlocks in §6 are implemented in hardware, each with a counter, and
   each has a directed cocotb test.
8. **The FPGA DMAs the exact bytes of every segment it sends.** The host cannot
   reconstruct what it did not see, and reconciliation is a regulatory obligation as
   much as an engineering one.
9. **No ARP, ICMP, IGMP, or DHCP state machines in fabric.** Classify to the host.
10. **Nagle and delayed ACK are off** on the host socket (`TCP_NODELAY`,
    `TCP_QUICKACK`), and the FPGA's `PSH` flag is always set. A 40 ms delayed-ACK
    timer on an order session is a catastrophe hiding in a default.

---

## Further reading

- [01-ethernet-phy-mac.md](01-ethernet-phy-mac.md) — the MAC below this layer and the `frame_commit` contract
- [03-multicast-feeds-and-arbitration.md](03-multicast-feeds-and-arbitration.md) — what sits in the UDP payload
- [04-nics-kernel-bypass-and-switching.md](04-nics-kernel-bypass-and-switching.md) — the host-side stack that owns the connection
- [../03-algotrading/04-order-entry-protocols.md](../03-algotrading/04-order-entry-protocols.md) — OUCH and SoupBinTCP semantics above TCP
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — where the TX template and the risk gate live
- [../04-system-architecture/06-cpu-fpga-partitioning.md](../04-system-architecture/06-cpu-fpga-partitioning.md) — the arm/disarm handshake and the DMA rings
- [../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) — the stream and lookup patterns used above
