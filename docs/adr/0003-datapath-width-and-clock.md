# ADR 0003 — Datapath width and core clock

> The highest-blast-radius decision in this project. It fixes how many bytes the fabric
> sees per cycle, how long a cycle is, and therefore every latency budget, every field
> offset, every constraint file and every resource estimate downstream. Read the
> **Blast radius** section before you change a number.

| Field | Value |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-08-02 |
| **Deciders** | Datapath lead / Feed handler owner |
| **TASKS.md** | P0.6, P0.7, P11.7 |
| **Supersedes** | — |
| **Superseded by** | — |

---

## Decision

**One core clock at 156.25 MHz (6.400 ns/cycle). The MAC-facing AXI-Stream datapath is
64 bits (`AXIS_W = 64`, 8 B/cycle — exactly 10GbE line rate). The internal message bus
is widened to 512 bits (`ITCH_MSG_W = 512`, `ITCH_MSG_MAX_BYTES = 64`) so that a whole
ITCH message lands in ONE beat and the decoder needs no reassembly state machine.**

These are the values in [`rtl/pkg/trading_pkg.sv`](../../rtl/pkg/trading_pkg.sv) §1 today:

```systemverilog
parameter int unsigned CORE_CLK_KHZ      = 156_250;   // 156.25 MHz
parameter int unsigned CORE_CLK_PS       = 6_400;     // 6.400 ns
parameter int unsigned AXIS_W            = 64;
parameter int unsigned AXIS_KEEP_W       = AXIS_W / 8;
parameter int unsigned ITCH_MSG_MAX_BYTES = 64;
parameter int unsigned ITCH_MSG_W        = ITCH_MSG_MAX_BYTES * 8;   // 512
parameter int unsigned ITCH_LEN_W        = 8;
```

The clock is expressed in integer kHz and picoseconds, not `real`, deliberately:
[`CLAUDE.md §5`](../../CLAUDE.md) rule 3 bans floating point on the fast path, and a
`real` in a package leaks into every synthesizable file that imports it.

---

## ⚠️ Blast radius — read this before changing `AXIS_W`, `ITCH_MSG_W`, or the clock

Changing any of these three numbers is **not a parameter edit**. It re-architects the
system. The following all change, and most of them change silently:

| What changes | Why | Where |
| --- | --- | --- |
| Every module's cycle budget and header | `CLAUDE.md §4` requires a per-block budget in ns *and* cycles at a stated clock. A different cycle length invalidates every one of them. | every file in `rtl/` |
| Every row of the master latency budget | 22 rows of ns and cumulative ns, all derived from 6.400 ns/cycle | [`rtl/fpga_top.sv`](../../rtl/fpga_top.sv) header, [`docs/latency-budget.md`](../latency-budget.md) |
| Byte-alignment / barrel-shift logic in the network strip | Message boundaries land at arbitrary byte offsets; the shifter geometry is a function of beat width | [`rtl/net/moldudp64_deframer.sv`](../../rtl/net/moldudp64_deframer.sv), [`rtl/net/eth_ip_udp_rx.sv`](../../rtl/net/eth_ip_udp_rx.sv) |
| MoldUDP64 messages-per-beat handling | One UDP datagram carries N length-prefixed blocks; how many can start or finish in one beat is width-dependent | [`rtl/net/moldudp64_deframer.sv`](../../rtl/net/moldudp64_deframer.sv) |
| The ITCH decoder's fixed field offsets | Fixed-offset extraction is a static slice of a register of exactly `ITCH_MSG_W` bits | [`rtl/feed/itch_decoder.sv`](../../rtl/feed/itch_decoder.sv), [`rtl/pkg/itch_pkg.sv`](../../rtl/pkg/itch_pkg.sv) §4 |
| Clock constraints | `CORE_CLK_PERIOD_NS`, `GT_REFCLK_PERIOD_NS`, the MMCM 25/16 ratio, and the CDC budget derived from `min(src, dst)` period | [`constraints/clocks.xdc`](../../constraints/clocks.xdc), [`constraints/cdc.xdc`](../../constraints/cdc.xdc) |
| The resource budget | Area scales roughly **linearly** with width, and a 512-bit barrel shifter is significant on its own | [`docs/resource-budget.md`](../resource-budget.md), `fpga_top.sv` header (LUT < 60k, FF < 90k, BRAM < 300) |
| The CDC arrangement | The MAC async FIFOs are `AXIS_W + AXIS_KEEP_W + flags` wide; `eth_10g_wrapper.sv` books BRAM 4 for "two 512×74 async FIFOs" at the current width | [`rtl/eth/eth_10g_wrapper.sv`](../../rtl/eth/eth_10g_wrapper.sv), ADR [0004](0004-single-clock-domain.md) |

### ⚠️ The silent-wrongness hazard

A width change can still **simulate correctly on a directed test** while it quietly
breaks a fixed-offset extraction for one message length, or quietly turns an II = 1
path into II = 2 under burst. The system comes up, the link is green, most messages
decode, the book looks plausible — and it is wrong on a subset. This is the exact
failure shape [`manuals/08-nasdaq/04-totalview-itch-5.0.md`](../../manuals/08-nasdaq/04-totalview-itch-5.0.md) §7
calls "a book that looks plausible and is wrong — the worst outcome in this system."

**Rule: any change to `AXIS_W`, `ITCH_MSG_W` or `CORE_CLK_KHZ` requires a full corpus
regression against the golden software model, not a directed test.** A directed test
proves the case you thought of. The message length you did not think of is the one
that breaks.

Two elaboration guards partially protect this today, and they are worth knowing about
because they fail **loudly**, which is what you want:

- `moldudp64_deframer.sv` `$fatal`s at elaboration if `AXIS_W != 64` — its window
  geometry is hand-derived for 8 B/beat.
- `net_rx_pkg.sv` records that `eth_ip_udp_rx` hand-codes the one header field that
  straddles a beat boundary at 64-bit width (the IPv4 destination address, bytes
  30..33) and carries its own guard.

Loud guards cover the network strip. They do **not** cover the decoder, the budgets, or
the constraints.

---

## Context

Three sources say three slightly different things about this decision, and a reader who
finds the disagreement deserves to know it is deliberate rather than an oversight:
[`CLAUDE.md §2`](../../CLAUDE.md) records the line-rate default as "**64-bit @ 156.25 MHz**",
[`TASKS.md P0.6`](../../TASKS.md) frames the open question as "**512-bit @ 156.25 MHz
versus 64-bit @ 322 MHz**", and the RTL implements **both halves of the first framing at
once** — `AXIS_W = 64` at the MAC and `ITCH_MSG_W = 512` on the internal message bus.
**This ADR is the reconciliation: both are partially right.** `CLAUDE.md` is describing
the MAC interface; `TASKS.md` is describing the core. They are different buses.

### Width before depth

[`manuals/01-fpga-design/02-pipelining-and-parallelism.md §3`](../../manuals/01-fpga-design/02-pipelining-and-parallelism.md)
is titled "Widen before you deepen" and calls it "the most important structural decision
in the design". §1 of the same document explains why depth is the expensive axis here:

> Pipelining doesn't make the work faster; it lets you clock faster, which improves
> *throughput*. […] **Pipelining a latency-critical path makes it slower in absolute
> time.**

Every stage adds `T_cq + T_setup +` routing (≈ 0.3–0.5 ns) on top of the logic delay.
In a general FPGA design that is free. Here every stage is on the tick-to-trade path and
costs money.

Width, by contrast, buys cycles back. For a ~36-byte ITCH `Add Order`
([`rtl/pkg/itch_pkg.sv`](../../rtl/pkg/itch_pkg.sv) `LEN_ADD_ORDER = 36`):

| Bus width | Bytes/cycle | Beats for a 36 B `Add Order` | Beats for the longest ITCH msg (50 B) | Reassembly state machine? |
| --- | --- | --- | --- | --- |
| 64 bit | 8 | **5** (6 if misaligned) | 7 (8 if misaligned) | Yes |
| 128 bit | 16 | 3 | 4 | Yes |
| 256 bit | 32 | **2** | 2 | Yes — straddle still possible |
| **512 bit** | **64** | **1** | **1** | **No** |

The "if misaligned" column is not pedantry. ITCH messages are **not** 4- or 8-byte
aligned within a MoldUDP64 packet
([`04-totalview-itch-5.0.md`](../../manuals/08-nasdaq/04-totalview-itch-5.0.md) §3, last
row), so at 64-bit a 36-byte message routinely occupies one more beat than the division
suggests, and the number of beats is *data-dependent*. Data-dependent beat counts on the
fast path are jitter, and [`CLAUDE.md §5`](../../CLAUDE.md) rule 8 prices determinism
above mean speed.

**The payoff is not only cycles.** At one message per beat, the decoder is a static
slice of a register — the manual's phrase is "field extraction is combinational slicing
off a register holding the message bytes" — and an entire bug class disappears: messages
straddling beat boundaries. There is no partial-message register, no "am I mid-message"
flag, no wrap case at the end of a UDP datagram, and therefore no way to get any of them
wrong.

### Why 156.25 MHz specifically

This is not a preference. **10GBASE-R at a 64-bit MAC interface *is* 156.25 MHz.**
10 Gbit/s ÷ 64 bit = 156.25 MHz, which is why
[`constraints/clocks.xdc`](../../constraints/clocks.xdc) calls 156.25 MHz "the standard
10GbE GT refclk" and why the AXI4-Stream handoff in
[`manuals/02-networking/01-ethernet-phy-mac.md`](../../manuals/02-networking/01-ethernet-phy-mac.md) §1
is drawn as "64/512-bit @ 156.25 MHz". Choosing any other core frequency means inserting
a rate-changing FIFO at the MAC that we would otherwise not need.

The alternative in `TASKS.md P0.6` — 64-bit @ 322 MHz — loses on four counts:

| Axis | 512-bit core @ 156.25 MHz | 64-bit @ 322 MHz |
| --- | --- | --- |
| Cycle length | 6.400 ns | 3.106 ns — shorter |
| Cycles for a 36 B message to be *usable* | 1 beat | 5–6 beats + reassembly |
| Absolute time for the same work | fewer cycles at a longer cycle | more cycles at a shorter cycle — no net win |
| Pipeline stages to close timing | ~6–8 logic levels at 6.4 ns is comfortable | `manuals/00-foundations/05-timing-closure.md` §3: "Rule of thumb at 322 MHz (3.1 ns): budget **~6–8 logic levels** max" — every deep block needs splitting, and each split is +1 stage of *absolute* latency |
| The book update and the wide trigger compare | Fits in the budgeted 2 cycles | These are the two deepest combinational structures in the design; halving the period is where they break first |
| Reassembly state machine | Eliminated | **Still there** |

That last row is the decisive one. 322 MHz does not remove the reassembly state machine;
it makes every other block harder while leaving the thing we most wanted to delete in
place. And the escalation path in
[`manuals/00-foundations/05-timing-closure.md`](../../manuals/00-foundations/05-timing-closure.md) §4
Tier 5 — "Lower the clock and widen the datapath. 64-bit @ 322 MHz becomes 128-bit @
161 MHz" — is exactly the move we are making pre-emptively, before it becomes a rescue.

> **Verify:** the achievable Fmax of a 512-bit fabric on the target part is a
> device-and-tool fact, not a design fact. Take WNS/TNS from the actual post-route
> report per [`CLAUDE.md §4`](../../CLAUDE.md) ("After writing RTL"); never estimate it.

### ⚠️ Confronting the manual's own warning

[`manuals/01-fpga-design/02-pipelining-and-parallelism.md §3`](../../manuals/01-fpga-design/02-pipelining-and-parallelism.md)
carries a warning against precisely the shape we have built:

> ⚠️ Don't width-convert twice. A 64-bit MAC → 512-bit core → 64-bit MAC design pays
> gearbox latency at both ends. If the MAC is 64-bit, consider whether the *parser* can
> be 64-bit with a wide *dispatch*, rather than widening everything.

**Our design is a 64-bit MAC feeding a 512-bit core. We are doing the thing the manual
warns about, and we are doing it knowingly.** The honest accounting:

| Question | Answer |
| --- | --- |
| Where is the RX gearbox cost? | It is a **named, priced line item**: the `ITCH message assembly (to 512-bit beat)` row of the master budget in [`rtl/fpga_top.sv`](../../rtl/fpga_top.sv) — **2 cycles / 12.8 ns** (target). It is not hidden and it is not free. |
| Where is the TX gearbox cost? | **There isn't one.** There is no corresponding widen-then-narrow on TX. |
| Why not? | The OUCH order is built by **template splice into a narrow stream**, not by narrowing a 512-bit beat. `02-pipelining-and-parallelism.md` §4 calls the pre-built order template "the single highest-leverage precompute in a trading FPGA": the per-symbol template lives in BRAM, the trigger overwrites ~10 bytes, and the result goes straight out at MAC width. The master budget's TX rows — `OUCH template read + splice + checksum` (2 cyc) and `TCP/SoupBinTCP framing` (1 cyc) — are the whole cost. |
| So what does the warning actually catch? | Paying **at both ends**. We pay at one end. |
| What do we get for the 12.8 ns? | The reassembly state machine and the straddle bug class, both deleted, plus a decode that is a static slice with no data-dependent beat count. |

**The revisit trigger is measurement, not opinion.** If a wire-to-wire measurement (per
[`manuals/05-optimization/04-measurement-and-profiling.md`](../../manuals/05-optimization/04-measurement-and-profiling.md))
shows the 2-cycle assembly stage costing more than the reassembly logic it avoids, this
decision is re-opened, and the leading replacement candidate is named by the manual
itself: **a 64-bit parser with a wide dispatch**. That variant keeps the narrow ingress,
accepts the reassembly state machine, and widens only at the point where the decoded
fields fan out — trading the assembly cycles back for the bug class we deliberately
bought off.

---

## Consequences

### Positive

- A whole ITCH message is available in one beat. Decode is fixed-offset combinational
  slicing with **no parsing state machine** — the property that
  [`04-totalview-itch-5.0.md`](../../manuals/08-nasdaq/04-totalview-itch-5.0.md) §5 calls
  the reason "the decoder is **not a parser**".
- Beat-straddle bugs are structurally impossible on the message bus, not merely tested
  against.
- Decode latency is **data-independent**: every message type costs the same cycles.
  Determinism, which `CLAUDE.md §5` rule 8 values above mean speed.
- 156.25 MHz is a comfortable Fmax target on UltraScale+, leaving headroom for the two
  deep blocks (book update, wide trigger compare) without extra pipeline stages.
- No rate-changing FIFO at the MAC beyond the CDC FIFO that the recovered clock forces
  anyway (see ADR [0004](0004-single-clock-domain.md)).

### Negative

- **A gearbox we would rather not have.** 2 cycles / 12.8 ns of the fabric budget is
  width conversion and nothing else — pure overhead against the ideal design where the
  MAC was already 512 bits wide.
- **Area scales roughly linearly with width.** `02-pipelining-and-parallelism.md` §3
  lists the costs plainly: wide muxes and shifters get expensive, "a 512-bit barrel
  shifter is significant", routing congestion increases, and more LUTs can mean lower
  Fmax. `moldudp64_deframer.sv` books ~1,600 LUT for its barrel shifter alone.
- **Two widths in the design means two sets of assumptions.** Network-strip modules are
  written against 8 B/beat; feed modules against 64 B/beat. Anyone moving logic across
  that boundary has to know which side they are on.
- **A 512-bit fabric is harder to floorplan.** 512-bit buses crossing an SLR boundary
  are a timing problem; `fpga_top.sv` constrains the fast path to one SLR partly for
  this reason.
- The decision is **10GbE-scoped**. It does not generalize to 25G or 100G (see Revisit
  triggers).

### Neutral

- Big-endian ITCH costs nothing in fabric at either width — wire order is numeric order.
  The host pays the byte swap.
- `AXIS_KEEP_W` is derived, not independent: `AXIS_W / 8 = 8`. There is no separate
  decision here.
- The message bus is 512 bits **wide**, not 512 bits **fast**. It carries at most one
  message per beat, so its sustained bandwidth requirement is unchanged; the width buys
  latency and structure, not throughput.

---

## Derived contracts

Other blocks depend on these. They are consequences of this ADR, not independent choices.

| Contract | Value | Owner / enforcement |
| --- | --- | --- |
| **II = 1 on the RX path** | Non-negotiable | [`CLAUDE.md §5`](../../CLAUDE.md) rule 4 ("no backpressure stalls into the MAC RX") and `02-pipelining-and-parallelism.md` §2 and §9 rule 3. `fpga_top.sv` ties `s_axis_rx_tready` high permanently; `eth_10g_wrapper.sv` has no `tready` on the RX path *at all*, by construction. Any II > 1 means a buffer, a buffer means overflow, and overflow means dropped market data. |
| `AXIS_KEEP_W` | `AXIS_W / 8` = 8 | `trading_pkg.sv`. Never write `8`. |
| `ITCH_MSG_MAX_BYTES` | 64 | Bounds the largest ITCH message accepted in one beat. |
| `ITCH_LEN_W` | 8 bits | The length field can represent up to 255 — see the hazard below. |
| Core clock period | 6.400 ns | `CORE_CLK_PS`; mirrored in `clocks.xdc` as `CORE_CLK_PERIOD_NS`. |

### Does 64 bytes actually cover every ITCH 5.0 message type?

**Yes, with 14 bytes of headroom.** Checked against both sources:

| Longest types | Length (bytes) | Source |
| --- | --- | --- |
| `I` NOII | **50** | `itch_pkg::LEN_NOII`; `04-totalview-itch-5.0.md` §4.3 |
| `P` Trade (non-cross) | 44 | `itch_pkg::LEN_TRADE`; §4.3 |
| `F` Add Order w/ MPID | 40 | `itch_pkg::LEN_ADD_ORDER_MPID`; §4.2 |
| `Q` Cross Trade | 40 | `itch_pkg::LEN_CROSS_TRADE`; §4.3 |
| `R` Stock Directory | 39 | `itch_pkg::LEN_STOCK_DIRECTORY`; §4.1 |

`itch_pkg.sv` states it directly: `parameter int unsigned LEN_MAX = 50;`. The two
sources agree on every one of the 22 lengths. **No ITCH 5.0 message type exceeds 64
bytes.**

> **Verify:** every message length above is a venue fact that changes when the venue
> changes it. Confirm against the **Nasdaq TotalView-ITCH 5.0 specification**
> (nasdaqtrader.com/Trading/TradingSpecs), per-message "Length" field. Both
> `itch_pkg.sv` and the manual carry their own ⚠️ saying the same thing.

### ⚠️ What happens to a message longer than 64 bytes

A message whose declared MoldUDP64 block length exceeds `ITCH_MSG_MAX_BYTES` **must be
counted and handled explicitly. It must never be silently truncated into the 512-bit
beat.** A truncated message decodes: the type byte, the locate and the timestamp are all
in the first 11 bytes and survive any truncation, so the decoder produces a
*structurally valid* book event carrying fields sliced from bytes that were never
received. That is a fictional order in a real book, and nothing in the pipeline flags it.

The protocol gives two free checks and both must be wired to counters
(`CLAUDE.md §5` rule 7):

1. **Length cross-check.** `itch_pkg::itch_msg_len(type)` returns the fixed length for
   the type; the MoldUDP64 block length prefix is redundant with it. A mismatch means a
   corrupt or unknown-version message — count it and drop, never mis-decode.
2. **Over-length guard.** `block_length > ITCH_MSG_MAX_BYTES` → count
   (`length_mismatch` / an over-length counter), drop the message, and mark the affected
   book stale. Unknown types are safe *only* because they carry a length prefix that can
   be skipped exactly.

> ⚠️ **Finding — no elaboration binding between the two constants.**
> `itch_pkg::LEN_MAX = 50` and `trading_pkg::ITCH_MSG_MAX_BYTES = 64` are independent
> literals in two packages, with no assertion binding `LEN_MAX <= ITCH_MSG_MAX_BYTES`.
> Nasdaq adds message types; `itch_pkg.sv` says so itself ("An unknown type is NOT an
> error — Nasdaq adds message types"). If a future type is 72 bytes and someone updates
> `LEN_MAX` without touching `ITCH_MSG_MAX_BYTES`, **nothing fails at elaboration** — the
> new type is silently truncated into the beat. Compounding it, `ITCH_LEN_W = 8` can
> represent lengths up to 255, so `itch_len` will faithfully report 72 alongside a
> 64-byte payload. A `$fatal` guard of the shape `moldudp64_deframer.sv` already uses for
> `AXIS_W` would close this. Recorded here, not fixed here.

---

## Alternatives considered

| Option | Why rejected | What would make it win |
| --- | --- | --- |
| **64-bit @ 322 MHz** (`TASKS.md P0.6`'s alternative) | Shorter cycle (3.106 ns) but more cycles for the same work — no net latency win. Forces ~6–8 logic levels max per stage (`05-timing-closure.md` §3), so the book update and the wide trigger compare each need splitting, and every split adds *absolute* latency. **Does not remove the reassembly state machine.** | We become latency-bound *inside* our own logic rather than on the wire, with short combinational paths everywhere and no wide compares — i.e. a fundamentally different strategy engine. |
| **256-bit @ 156.25 MHz** | 32 B/cycle → 2 beats for a 36 B `Add Order`, so a reassembly register and a straddle case still exist. Saves area over 512-bit but keeps the bug class we are paying to delete. Halfway houses cost the complexity of both ends. | The resource budget is blown by 512-bit muxing and the straddle logic proves cheap and well-tested in the golden-model regression. Also the natural first step if a future venue's messages fit in 32 B. |
| **512-bit end-to-end, including the MAC interface** | The 10GbE MAC's natural interface at 156.25 MHz is 64-bit; a 512-bit MAC-facing bus means running the MAC at 19.53 MHz or inserting a gearbox at the GT — trading a fabric gearbox for a PCS-adjacent one, in the highest-jitter part of the design, and diverging from every vendor 10G/25G subsystem's stock interface. | The line rate moves to 100G, where a 512-bit fabric interface *is* the vendor default and the gearbox is inside the hard MAC. |
| **64-bit narrow parser with wide dispatch** (the manual's own suggestion) | Keeps the reassembly state machine and the straddle bug class — the two things this decision buys off — in exchange for saving the 2-cycle assembly stage. The bug class is worth more than 12.8 ns *until measured otherwise*. | Measurement shows the assembly stage costs more than the reassembly logic it avoids. **This is the named leading replacement candidate**, not a fallback. |
| **Two clocks: fast narrow ingress + slow wide core** | Introduces a CDC in the middle of the tick-to-trade path. A CDC costs 2–3 cycles of synchronizer latency *and* makes the arrival cycle non-deterministic — it converts fixed latency into jitter, which `CLAUDE.md §5` rule 8 explicitly prices as worse than a higher mean. Fully rejected in ADR [0004](0004-single-clock-domain.md). | Never, on the fast path. The MAC and PCIe boundaries are the only crossings we accept, and only because physics forces them. |
| **128-bit @ 156.25 MHz** | 3 beats for a 36 B message. Strictly dominated: it has 256-bit's straddle problem with less of 256-bit's area saving. | Nothing plausible. Listed so the next reader does not have to re-derive it. |

---

## Revisit triggers

- **A move to 25GbE or 100GbE.** [`CLAUDE.md §2`](../../CLAUDE.md) already anticipates
  "32-bit @ 322 MHz for 25G", which is a different point in this trade space entirely.
  **This ADR is explicitly 10GbE-scoped.** A rate change re-opens it from scratch, and
  at 25G the FEC decision (`01-ethernet-phy-mac.md` §3, ~100 ns per direction) dominates
  anything decided here.
- **Measured assembly cost exceeds the reassembly it avoids.** A wire-to-wire
  measurement showing the `ITCH message assembly` stage above its 2-cycle target, or
  attribution showing it on the critical path, promotes the 64-bit-parser/wide-dispatch
  alternative to the leading candidate.
- **The 512-bit fabric fails to close timing at 156.25 MHz after Tier-4 physical work.**
  Floorplanning, implementation-strategy sweeps, `phys_opt_design` and a faster speed
  grade are all cheaper than a re-architecture
  (`05-timing-closure.md` §4). If all of Tier 4 is exhausted and WNS is still negative on
  the wide paths, the width comes down before the clock goes up.
- **A venue whose messages do not fit in 64 bytes.** CME MDP 3.0 (SBE) is already a
  reference protocol in `CLAUDE.md §2` and has repeating groups and variable layouts —
  it does not have ITCH's fixed-length property at all. Adding it re-opens both the width
  and the "one message per beat" premise.
- **The resource budget is blown by wide-mux area.** `fpga_top.sv` targets LUT < 60k on
  the fast path. If the 512-bit shifters and muxes push past it, 256-bit is the first
  fallback.
- **`ITCH_MSG_MAX_BYTES` needs to grow.** If any accepted message type exceeds 64 bytes,
  the "one message per beat" property requires a 1024-bit bus, and the area argument
  changes shape entirely.

---

## Flagged discrepancies found while writing this ADR

Recorded, not fixed — per the scope rule, `rtl/` and `manuals/` are not edited from here.

1. **⚠️ The master latency budget's fabric cycle total is internally inconsistent.**
   The per-stage `cyc` column in [`rtl/fpga_top.sv`](../../rtl/fpga_top.sv) sums to
   **22 cycles / 140.8 ns**, and the `cum ns` column agrees with 22
   (230.8 − 90.0 = 140.8). The summary line claims **20 cycles / 128.0 ns**. It is short
   by 2 cycles / 12.8 ns. The per-stage rows are the master.
2. **⚠️ The MAC async FIFOs are not booked in any row of the master budget.**
   [`rtl/eth/eth_10g_wrapper.sv`](../../rtl/eth/eth_10g_wrapper.sv)'s own header books
   `async_fifo rx_clk -> core_clk` at **3 cyc / 19.2 ns** on RX and
   `s_axis -> async_fifo -> skid` at **4 cyc / 25.6 ns** on TX, and states that "the two
   async FIFOs are 5 of the ~20 fabric cycles in the whole tick-to-trade budget". The
   master budget's `MAC RX (cut-through)` and `MAC TX (cut-through)` rows are 2 cycles
   each and cover the cut-through MAC only. **44.8 ns of CDC latency appears in no row of
   the master table.** This is the single largest unbooked item found; see ADR
   [0004](0004-single-clock-domain.md).
3. **Manual/RTL beat-width disagreement, already reconciled in the RTL.**
   `net_rx_pkg.sv` notes that `manuals/02-networking/02` and `/03` describe the header
   parse against a **512-bit ingress bus** ("all of this lands in beat 0"), while the port
   contract in `fpga_top.sv` is **64-bit**. The RTL states that the contract wins. This
   ADR agrees: ingress is 64-bit, and 512 bits begins at the message bus.
4. **`TASKS.md P0.6` names its output as `docs/adr/0002-datapath-width.md`.** Our
   numbering is authoritative; the mapping lives in [the ADR index](README.md).

---

## Links

- **Governing manuals**
  - [`manuals/01-fpga-design/02-pipelining-and-parallelism.md`](../../manuals/01-fpga-design/02-pipelining-and-parallelism.md) — §1 the pipelining trade-off, §2 initiation interval, §3 widen before you deepen (and its ⚠️), §4 precompute / the order template, §8 the worked decode budget, §9 the project rules
  - [`manuals/00-foundations/04-clocking-reset-and-cdc.md`](../../manuals/00-foundations/04-clocking-reset-and-cdc.md) — §1 "Choosing the core clock frequency"
  - [`manuals/00-foundations/05-timing-closure.md`](../../manuals/00-foundations/05-timing-closure.md) — §3 logic levels at 322 MHz, §4 the fix hierarchy (Tier 4 physical, Tier 5 widen-and-slow), §6 the over-constraining trap
  - [`manuals/02-networking/01-ethernet-phy-mac.md`](../../manuals/02-networking/01-ethernet-phy-mac.md) — §1 the stack and the 64/512-bit @ 156.25 MHz handoff, §2 the 64b/66b gearbox stall, §5 serialization delay reference
  - [`manuals/08-nasdaq/04-totalview-itch-5.0.md`](../../manuals/08-nasdaq/04-totalview-itch-5.0.md) — §3 common fields and byte alignment, §4 the message catalogue, §5 "message lengths are fixed per type", §6 the decoder sketch
- **Implementing RTL**
  - [`rtl/pkg/trading_pkg.sv`](../../rtl/pkg/trading_pkg.sv) — the parameters themselves
  - [`rtl/pkg/itch_pkg.sv`](../../rtl/pkg/itch_pkg.sv) — `LEN_MAX`, the per-type lengths, `itch_msg_len()`
  - [`rtl/fpga_top.sv`](../../rtl/fpga_top.sv) — the master latency and resource budgets
  - [`rtl/net/net_rx_pkg.sv`](../../rtl/net/net_rx_pkg.sv), [`rtl/net/moldudp64_deframer.sv`](../../rtl/net/moldudp64_deframer.sv) — the 64-bit beat-width assumption and its elaboration guard
  - [`rtl/eth/eth_10g_wrapper.sv`](../../rtl/eth/eth_10g_wrapper.sv) — the MAC boundary and its own latency ledger
- **Constraints**
  - [`constraints/clocks.xdc`](../../constraints/clocks.xdc) — `CORE_CLK_PERIOD_NS`, the MMCM 25/16 derivation
- **Related decisions**
  - ADR [0004 — Single core clock domain for the datapath](0004-single-clock-domain.md)
  - [`docs/latency-budget.md`](../latency-budget.md) · [`docs/resource-budget.md`](../resource-budget.md)
- **Tasks** — [`TASKS.md`](../../TASKS.md) P0.6 (width and clock), P0.7 (master budget), P11.7 (Tier-2 architectural optimization)

## Further reading

- [`CLAUDE.md`](../../CLAUDE.md) — §2 working defaults, §5 hard rules on the fast path
- [`manuals/05-optimization/01-latency-budgeting.md`](../../manuals/05-optimization/01-latency-budgeting.md)
- [`manuals/05-optimization/05-optimization-playbook.md`](../../manuals/05-optimization/05-optimization-playbook.md)
- [`manuals/04-system-architecture/01-tick-to-trade-pipeline.md`](../../manuals/04-system-architecture/01-tick-to-trade-pipeline.md)
