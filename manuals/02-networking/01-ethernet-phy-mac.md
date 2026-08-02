# 02.01 — Ethernet PHY and MAC

> **Why this matters here:** before a single bit of ITCH reaches your parser it has
> already crossed an optical module, a SerDes, a PCS, and a MAC. On a < 1 µs
> wire-to-wire budget that stack can easily be **20–40 % of the total**, in both
> directions, and most of it is decided by IP configuration choices you make once
> and live with. This document is about spending those nanoseconds deliberately.

---

## 1. The stack, layer by layer

```
      fibre / DAC
          │
   ┌──────▼───────┐  PMD   optical module (SFP+/SFP28/QSFP28): E/O and O/E conversion
   │              │
   ├──────────────┤  PMA   SerDes: CDR, deserialize, elastic buffer, lane deskew   ← GT hard IP
   │              │
   ├──────────────┤  FEC   RS-FEC (25G/100G) — optional at 25G, usually forced at 100G
   │   "the PHY"  │
   ├──────────────┤  PCS   64b/66b: block sync, descramble, gearbox, /I/ removal
   │              │
   ├──────────────┤  RS    reconciliation sublayer + xGMII (control chars, LF/RF)
   └──────┬───────┘
          │
   ┌──────▼───────┐  MAC   preamble/SFD strip, FCS check, IFG, pad strip
   │              │
   └──────┬───────┘
          │  AXI4-Stream, 64/512-bit @ 156.25 MHz
   ┌──────▼───────┐
   │  YOUR RTL    │  ← everything from here on is in manuals/02..04
   └──────────────┘
```

On UltraScale+ the PMA is a **GTY/GTH hard transceiver**; the PCS, FEC and MAC are
either soft (Vivado's Ethernet Subsystem, LUT-based) or, on some devices, hardened
(CMAC / the integrated 100G block). Hard blocks are usually *not* the low-latency
choice — they are the feature-complete choice.

### Per-direction latency, order of magnitude

| Sublayer | 10GBASE-R | 25GBASE-R | 100GBASE-R | Why |
| --- | --- | --- | --- | --- |
| Optical module (PMD) | 5–20 ns | 5–20 ns | 10–30 ns | Retimer inside the module, if any, dominates |
| PMA / SerDes (GT) | 40–100 ns | 40–100 ns | 40–100 ns/lane | CDR + elastic buffer; **buffer bypass saves tens of ns** |
| RS-FEC | — | ~100 ns *(if enabled)* | ~100 ns *(usually mandatory)* | Codeword must be fully received before decode |
| PCS 64b/66b | 20–60 ns | 20–60 ns | 60–150 ns | 100G adds 20-virtual-lane deskew + alignment markers |
| MAC (cut-through) | 10–30 ns | 10–30 ns | 10–30 ns | Just header strip + CRC accumulation |
| **RX wire → fabric** | **~80–200 ns** | **~180–300 ns w/ FEC** | **~250–450 ns** | |

> **Verify:** these are planning numbers, not datasheet numbers. Get the real ones
> from the AMD *UltraScale+ GTY/GTH Transceivers User Guide* (UG578, latency tables
> per configuration), the *10G/25G Ethernet Subsystem Product Guide* (PG210) and
> *100G Ethernet Subsystem* (PG203) latency sections, and — for the module — the
> specific SFP+/SFP28 vendor datasheet. The Vivado GT wizard reports the configured
> PMA latency for your exact settings; use that, not this table.

**The design conclusion is already visible:** 10G with no FEC is the lowest-latency
Ethernet you can buy. That, not throughput, is why market-data ingress in this
project is 10GbE.

---

## 2. 64b/66b and the gearbox

10G/25G/100G Ethernet do not use 8b/10b. They use **64b/66b** (IEEE 802.3 Clause 49
for 10GBASE-R, Clause 82 for 40/100GBASE-R): every 64 bits of payload gets a 2-bit
sync header prefixed.

```
  sync   payload
  ┌──┐ ┌──────────────────────── 64 bits ─────────────────────────┐
  │01│ │  all data                                                │   data block
  └──┘ └──────────────────────────────────────────────────────────┘
  ┌──┐ ┌──────┬───────────────────────────────────────────────────┐
  │10│ │ type │  mixed control + data (SOF, EOF, idles, ordered set)│  control block
  └──┘ └──────┴───────────────────────────────────────────────────┘
```

- `01` = data block, `10` = control block. `00` and `11` are invalid and are how the
  receiver achieves **block lock** (Clause 49.2.13 block sync state machine).
- Overhead is 66/64 = 3.125 %, which is why 10GBASE-R runs at **10.3125 Gbaud** and
  25GBASE-R at **25.78125 Gbaud** on the wire.
- The payload is **scrambled** with x⁵⁸+x³⁹+1 (self-synchronous, no reset) for DC
  balance and transition density.

### The gearbox

The transceiver moves data in fixed widths (32/64 bits), but the PCS produces 66-bit
blocks. The **gearbox** absorbs the mismatch:

```
64-bit fabric bus:  66 bits × 32 blocks = 2112 bits = 64 bits × 33 cycles
                    → 1 cycle in every 33 carries no new data ("gearbox stall")
32-bit fabric bus:  66 bits × 16 blocks = 1056 bits = 32 bits × 33 cycles
                    → same 1-in-33 pause
```

Xilinx GTs offer an **internal gearbox** (in the transceiver, no fabric cost, fixed
width choices, slightly more latency) or an **external gearbox** (yours, in fabric,
more control, more LUTs).

⚠️ **The gearbox stall is a real hole in your datapath.** One cycle in 33 the PCS
presents nothing. If any downstream block assumes a beat every cycle it will work in
a directed simulation and fail on hardware under sustained load. Everything below the
MAC must be valid-qualified — never `always_ff` on an unqualified counter.

---

## 3. FEC: the biggest single latency decision

Reed–Solomon FEC RS(528,514) over GF(2¹⁰) corrects up to 7 symbol errors per
codeword. It is what makes 25G and 100G links work over cheap DACs and multimode
optics at a 10⁻¹² BER target.

**It also forces the receiver to buffer a full codeword before it can decode.**
That is a fixed, unavoidable, order-of-100-ns tax in each direction.

| Rate | FEC situation | Practical latency stance |
| --- | --- | --- |
| 10GBASE-R (SR/LR) | No FEC in the standard path | **Free. Use this.** |
| 10GBASE-KR backplane | Clause 74 "FireCode" FEC, optional | Not relevant to a colo cross-connect |
| 25GBASE-CR-S | Designed for short DAC, no RS-FEC required | Best 25G option if both ends agree |
| 25GBASE-CR / SR | RS-FEC (Clause 108) required for conformance | ~100 ns each way you cannot remove |
| 100GBASE-SR4 / CR4 | RS-FEC (Clause 91) required | Accept it, or don't use 100G on the hot path |
| 100GBASE-LR4 (Clause 88 PCS) | RS-FEC not required | The escape hatch, if the link partner cooperates |

> **Verify:** clause numbers and per-PMD FEC requirements against IEEE 802.3 (Clause
> 74 BASE-R FEC, Clause 91 RS-FEC for 100GBASE-R, Clause 108 RS-FEC for 25GBASE-R,
> Clause 107 25GBASE-CR/CR-S PMD). The exact added latency is implementation-specific
> — take it from PG210's RS-FEC latency section for the AMD core.

⚠️ **A FEC mode mismatch is a silent killer.** With Clause 73 auto-negotiation on a
DAC, both ends advertise FEC ability. If you force FEC off on one side and the switch
insists on it, you get either no link (obvious) or — worse on some silicon — a link
that comes up and delivers a low but nonzero rate of corrupted frames that your FCS
check quietly drops. **Every FEC-off deployment must be validated with a long
zero-error soak and a monitored `rx_fcs_error` counter, not a ping.**

**Project rule:** market-data RX and order-entry TX run at 10GbE, no FEC. 25G is
allowed only on non-critical links (capture, host fanout) until a 25G no-FEC path is
proven end-to-end with the venue.

---

## 4. What the MAC actually does

| Function | Clause | RX side | TX side |
| --- | --- | --- | --- |
| Preamble + SFD | 802.3 §3.2.1–3.2.2 | Strip 7×`0x55` + `0xD5` | Insert |
| Destination/source address filter | §4.2.4 | Optionally filter; **we don't** | — |
| FCS (CRC-32) | §3.2.9 | Check, flag bad frames | Compute and append |
| Padding | §3.2.8, §4.2.3.3 | Payload < 46 B was padded; you must use IP total length, not frame length | Pad to 64 B min frame |
| Inter-frame gap | §4.4.2, §46.3.1.4 | Consume idles | Enforce ≥ 96 bit times |
| MAC control (PAUSE) | Annex 31B | Decode / **or drop** | Emit / **or never** |
| Link fault | §46.3.4 | Detect LF/RF ordered sets | Emit LF/RF |

### Frame anatomy on the wire

```
 ┌────────────┬─────┬─────┬─────┬──────┬────────────────────┬─────┬─────────┐
 │  preamble  │ SFD │ DA  │ SA  │ type │      payload       │ FCS │   IFG   │
 │   7 B      │ 1 B │ 6 B │ 6 B │ 2 B  │   46 … 1500 B      │ 4 B │  12 B   │
 └────────────┴─────┴─────┴─────┴──────┴────────────────────┴─────┴─────────┘
              └──────────── covered by the FCS ─────────────┘
  minimum on-wire cost of one frame = 8 + 64 + 12 = 84 bytes
```

### Inter-frame gap and the deficit idle count

IFG is 96 bit times = 12 bytes. But at 10G the reconciliation sublayer aligns
start-of-frame to a 4-byte lane boundary, so the *instantaneous* gap varies. The
**deficit idle count** (Clause 46.3.1.4) lets it be 9–15 bytes as long as the average
is ≥ 12. Two consequences:

- Your TX rate accounting must use 12 B average, not 12 B exactly.
- ⚠️ A TX path that emits a *shortened* IFG to save 3 ns is non-conformant and some
  venue-side switches will drop the frame or count it as an error. Never do this.

### CRC-32 in fabric

Polynomial `0x04C11DB7`, initial value all-ones, bit-reflected per octet, final
complement. The useful hardware fact:

```
Run the same CRC over {frame bytes, received FCS}.
A valid frame always leaves the residue 0xC704DD7B.
→ no need to compare against a computed value; compare against a constant.
```

For a W-bit datapath the CRC update is a fixed XOR matrix (`F^W` applied to the
32-bit state) — an XOR tree of depth ~5–7 for W = 512, comfortably one cycle at
156.25 MHz. The awkward part is the **last beat**, where only some bytes are valid:
you need W/8 variants of the final-beat matrix, selected by `tkeep`. Build them as
parallel constant XOR trees and mux the result; do **not** try to shift the data.

> **Verify:** the residue constant and bit ordering against IEEE 802.3 §3.2.9. Get
> a golden pcap and check your CRC block against it in cocotb before trusting it.

---

## 5. Cut-through vs. store-and-forward — the decision

A **store-and-forward** MAC buffers the whole frame, validates the FCS, and only then
hands it to your logic. A **cut-through** MAC streams bytes out as they arrive and
tells you afterwards whether they were valid.

| Frame size | Store-and-forward penalty @10G | @25G |
| --- | --- | --- |
| 64 B (min) | 51 ns | 20 ns |
| 100 B (typical small MoldUDP64/ITCH packet) | 80 ns | 32 ns |
| 512 B | 410 ns | 164 ns |
| 1500 B (max standard MTU) | **1200 ns** | 480 ns |
| 9000 B (jumbo) | **7200 ns** | 2880 ns |

The 1500 B row alone blows the entire wire-to-wire budget. **Store-and-forward is
not an option in this project, anywhere on the fast path.** Not in the MAC, not in
the feed handler, not in the order gateway, and not in the switch in front of you.

### Serialization delay reference

At 10 Gbps: **0.8 ns/byte**. At 25 Gbps: **0.32 ns/byte**.

| Bytes | @10G | @25G | What it is |
| --- | --- | --- | --- |
| 8 | 6.4 ns | 2.6 ns | preamble+SFD, or one 64-bit beat |
| 14 | 11.2 ns | 4.5 ns | Ethernet header |
| 42 | 33.6 ns | 13.4 ns | Eth+IPv4+UDP headers |
| 62 | 49.6 ns | 19.8 ns | …+ MoldUDP64 header (sequence number known here) |
| 64 | 51.2 ns | 20.5 ns | minimum frame |
| 84 | 67.2 ns | 26.9 ns | minimum frame + preamble + IFG |
| 100 | 80 ns | 32 ns | one small ITCH message in a Mold packet |
| 256 | 205 ns | 82 ns | a batched multi-message Mold packet |
| 1500 | 1200 ns | 480 ns | max standard frame |

Memorize the top of this table. It is the floor under every latency claim you will
ever make: **you cannot react to a field before it has arrived.**

---

## 6. ⚠️ The CRC-is-at-the-end problem

Cut-through creates a genuine correctness hazard:

```
t=0                                      t=frame_end   t=frame_end+4B
│─── payload streamed to your parser ───│──── FCS ────│
                                         ▲
        you already decoded the ITCH message here      you learn it was corrupt here
```

You have already updated the book — and possibly emitted an order — based on bytes
that may be garbage. The AMD MAC hands you this exact semantic: `rx_axis_tuser` is
driven **low on `tlast`** to mark a bad frame, i.e. the error arrives *after* the
data.

> **Verify:** the `tuser`-on-`tlast` error semantics against AMD PG210 §"AXI4-Stream
> Interface". Other MACs use `tuser[0]` inverted, or a separate `rx_error` strobe;
> read your core's guide and encode the polarity in a single wrapper module.

### The two resolutions

| | (A) Speculate, then invalidate | (B) Wait for the FCS |
| --- | --- | --- |
| Mechanism | Process the frame optimistically; a `frame_commit`/`frame_abort` strobe follows | Buffer the frame, validate, then release |
| Latency cost, happy path | **~0** for all but the last message in the frame | Full frame time (see §5) |
| Latency cost, last message | ~4 B serialization + 1–2 cycles of CRC = **~10–15 ns** | Full frame time |
| Complexity | Downstream must be able to unwind | Trivial |
| Resource cost | A commit gate + rollback state | A frame buffer per port |

### Project recommendation: **(A), with a hardware commit gate at the order egress.**

The rule set:

1. The feed handler decodes speculatively and produces book updates tagged with a
   `frame_id`.
2. Book state updates are applied speculatively but **journaled** — the previous
   value of every touched field is retained for one frame.
3. The strategy may fire and the order encoder may fully build the outbound frame.
4. **The order gateway must not release the first byte of an order onto the wire
   until `frame_commit` for the `frame_id` that produced it.** This is the only
   hard interlock, and it is cheap: the FCS resolves ~4 bytes (3.2 ns) after the
   last payload byte, and for any message that is not the last in the packet, the
   commit has already happened by the time the strategy fires.
5. On `frame_abort`: roll the journal back, count `rx_fcs_error`, count
   `orders_suppressed_by_abort`, and — because a rolled-back frame means you have a
   *hole in the MoldUDP64 sequence* — hand off to the gap logic in
   [03-multicast-feeds-and-arbitration.md](03-multicast-feeds-and-arbitration.md).

⚠️ **A speculative design with no commit gate is a working-but-wrong design.** It
will pass every test you write with clean pcaps, run for months in colo, and then
send a real order derived from a corrupted frame the first time an optic degrades.
The failure is rare, silent, and expensive — exactly the shape this project is meant
to eliminate.

On a clean colo cross-connect the target BER is 10⁻¹² (IEEE 802.3 optical PMD
objective), so the speculative path is right essentially always. That is an argument
for speculating, **not** an argument for skipping the gate.

---

## 7. TX: CRC generation and deliberate frame abort

On TX you compute CRC-32 over the frame as you emit it and append 4 bytes. No
buffering needed — the FCS is at the *end*, which is exactly where a streaming
computation naturally lands. TX cut-through is free.

Sometimes you need to **kill a frame you have already started transmitting** — the
kill switch fired mid-frame, a risk check failed late, or the source data was
retracted. Ethernet has two mechanisms:

| Method | How | Receiver sees |
| --- | --- | --- |
| **FCS inversion** | XOR the computed CRC with `32'hFFFF_FFFF` before appending | A normal-looking frame that fails the FCS check → dropped, counted as an FCS error |
| **PCS error code** | Assert the MAC's error input (`tx_axis_tuser` on AMD cores) so the PCS emits `/E/` error control characters | A frame terminated with an error → dropped, counted as an errored frame |

`/E/` is cleaner (it is unambiguously "the sender aborted"), but FCS inversion works
with every MAC and needs no special core support.

**Project rule:** the order gateway implements FCS inversion as its late-abort
mechanism, and every abort increments a dedicated counter. ⚠️ An aborted order frame
is *not* a cancelled order — you do not know whether the venue's receiver had already
committed part of it downstream. Treat a mid-frame abort as an **unknown-state order**
and reconcile it on the slow path. Designing so that aborts never happen (risk checks
complete before the first byte leaves) is far better than relying on abort.

---

## 8. Jumbo frames, flow control, and link management

### Jumbo frames
Not in IEEE 802.3 — a de-facto extension, typically 9000 or 9216 byte MTU.

- Market data multicast never uses them; MoldUDP64 packets are small by design.
- ⚠️ If your MAC is configured to accept 9 kB frames, a single malformed or
  misrouted jumbo frame occupies your RX path for **7.2 µs at 10G** — seven
  tick-to-trade budgets. In a cut-through design that does not stall, this is only a
  throughput hazard, but any downstream length field sized for 1500 B will overflow.
- **Project rule:** MTU 1500 on all trading links. `max_frame_length` in the MAC is
  set to 1518 (or 1522 with VLAN) and oversize frames are dropped and counted.

### PAUSE / flow control
IEEE 802.3 Annex 31B: a MAC control frame (EtherType `0x8808`, opcode `0x0001`, sent
to `01-80-C2-00-00-01`) asking the peer to stop transmitting for N × 512 bit times.
Priority Flow Control (IEEE 802.1Qbb) is the per-class version, opcode `0x0101`.

At 10G, a maximum PAUSE of 65535 quanta = 65535 × 512 / 10⁹ ≈ **3.36 ms**. In market
data terms, that is an eternity of lost ticks.

**Disable flow control in both directions.** You must never be paused — a paused
order sits in a buffer while the market moves. You must never pause anyone — PAUSE on
a multicast feed port creates head-of-line blocking, degrading the feed for everyone
behind that port including you. And accepting PAUSE contradicts the core RX rule
(*drop and count, never stall*): if you cannot keep up you have a design bug, and a
PAUSE frame would hide it.

Configure the MAC to **drop and count** frames with EtherType `0x8808` rather than
act on them, and never enable TX pause generation. Verify with the switch counters
that no pause frames are being exchanged in either direction.

### Link fault signalling
Clause 46.3.4 defines **Local Fault** and **Remote Fault** sequence ordered sets. If
the local PCS loses block lock or alignment, the RS emits LF continuously; the far
end sees LF and responds with RF, so both sides know which direction broke.

Expose as status registers, all of them sticky-on-set with a separate clear:
`pcs_block_lock`, `pcs_hi_ber`, `local_fault`, `remote_fault`,
`rx_fcs_error_count`, `rx_undersize/oversize`, `fec_corrected/uncorrected` (if FEC),
plus **transition counters**, not just current state. A link that flaps for 40 µs at
09:31 leaves no trace in a level-only register.

### Auto-negotiation
- **10GBASE-SR/LR over fibre has no auto-negotiation.** The link is up or it is not,
  and both ends must be configured identically. This is a feature: nothing to
  mis-negotiate.
- **Clause 73 AN + Clause 72 link training** apply to backplane (KR) and direct-attach
  copper (CR). This is where FEC mode, speed, and pause capability are negotiated.
- **Clause 28 AN** is the twisted-pair mechanism — irrelevant here.

**Project rule:** all trading links are fibre, fixed speed, AN disabled, pause
disabled, FEC disabled. Every one of those is written into the deployment checklist
and verified against the switch config at turn-up, not assumed.

---

## 9. Project rules

1. **10GbE, no FEC, MTU 1500, fixed speed, no auto-negotiation, no flow control** on
   every link that carries market data or orders.
2. **Cut-through MAC only.** Store-and-forward anywhere on the fast path is a bug.
3. **The RX AXI-Stream `tready` into the feed handler is tied high.** There is no
   backpressure path from fabric to the MAC. Overload is handled by dropping and
   counting.
4. **Speculative RX processing is permitted; unguarded order emission is not.** No
   byte of an outbound order leaves the MAC before the `frame_commit` for the frame
   that caused it.
5. **Every rejected, errored, dropped, aborted, oversize and undersize frame is
   counted** in a host-readable register, per port. Sticky error bits, plus counters.
6. **Wrap the vendor MAC in a project-local shim** that normalizes `tuser` polarity,
   error semantics, and byte order. Vendor cores differ; the rest of the design must
   not know that.
7. **Record the configured GT/PCS/MAC latency from the Vivado report** in the module
   header and in `docs/`. It is part of the latency budget and it changes when
   someone re-runs the wizard with different options.
8. **Never shorten the preamble or the IFG.** The nanoseconds are not worth a
   conformance failure at the venue.

---

## Further reading

- [02-ip-udp-tcp-in-hardware.md](02-ip-udp-tcp-in-hardware.md) — what to do with the bytes the MAC hands you
- [03-multicast-feeds-and-arbitration.md](03-multicast-feeds-and-arbitration.md) — MoldUDP64 framing and the A/B path
- [04-nics-kernel-bypass-and-switching.md](04-nics-kernel-bypass-and-switching.md) — the switch and NIC latency you are competing with
- [../01-fpga-design/04-io-transceivers-and-serdes.md](../01-fpga-design/04-io-transceivers-and-serdes.md) — GT configuration, buffer bypass, and the PCS in detail
- [../00-foundations/01-digital-logic-and-timing.md](../00-foundations/01-digital-logic-and-timing.md) — where the nanoseconds come from
- [../05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md) — booking these numbers into the budget
- [../07-reference/02-latency-reference-numbers.md](../07-reference/02-latency-reference-numbers.md) — the consolidated table
