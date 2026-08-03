# System Report — FPGA Algorithmic Trading System

**Scope:** Nasdaq US equities · AMD/Xilinx UltraScale+ · sub-microsecond tick-to-trade
**Status:** design and implementation complete on paper; **nothing has been compiled, simulated, or run on hardware**
**Generated from:** `scripts/validate.py` against the working tree

---

## 0. Read this first

This report describes a system that **exists as source and does not yet exist as
a running artifact**. Every latency figure is arithmetic from a budget table.
Every resource figure is a first-principles estimate. No file here has been
through Verilator, Vivado, or a simulator, because none is installed on the
machine this was built on.

That distinction matters more in this domain than in most. A trading system that
is 95% right loses money at wire speed. Treat everything below as a *design
proposition* to be verified, not as a result.

| Claim class | Status |
| --- | --- |
| Architecture, interfaces, module contracts | Written and internally consistent |
| Latency figures | **Design targets** — arithmetic only, never measured |
| Resource figures | **Estimates** — no synthesis has run |
| Protocol field offsets (ITCH/OUCH) | **Unverified** — flagged `⚠️ VERIFY` throughout |
| Order book correctness | **Unproven** — golden-model equivalence never run |
| Regulatory compliance | **Designed for**, not certified |

---

## 1. What the system does

Market data arrives on a fibre. Roughly 300 nanoseconds later, if a strategy
condition is met, an order leaves on another fibre. Everything between happens in
FPGA fabric with no software in the path.

```
                          ┌──────────── FPGA (one SLR) ────────────┐
  Nasdaq ITCH             │                                        │
  multicast  ──► SFP+ ──► │ GT/PCS ─► MAC ─► A/B arb ─► MoldUDP64  │
  (A and B feeds)         │                              deframe   │
                          │                                 │      │
                          │                                 ▼      │
                          │                          ITCH decode   │
                          │                                 │      │
                          │                                 ▼      │
                          │                          symbol filter │
                          │                                 │      │
                          │                                 ▼      │
                          │                          ORDER BOOK    │
                          │                     (order map + levels│
                          │                      + top-of-book)    │
                          │                                 │      │
                          │                                 ▼      │
                          │                        strategy trigger│
                          │                                 │      │
                          │                                 ▼      │
                          │                    🔒 PRE-TRADE RISK   │
                          │                       (non-bypassable) │
                          │                                 │      │
                          │                                 ▼      │
  Nasdaq OUCH  ◄── SFP+ ◄─│ GT/PCS ◄─ MAC ◄─ TCP ◄─ OUCH encode   │
                          │                                        │
                          │  ══════ PCIe (slow path only) ══════   │
                          └────────────────────┬───────────────────┘
                                               │
                                        Host software
                        (control, params, risk limits, reconciliation,
                         session ownership, gap recovery, audit log)
```

### The central design idea

**The FPGA is a trigger evaluator over a parameter table, not a compute engine.**

The host computes signals at millisecond cadence and writes parameters. The FPGA
compares book state against those parameters at nanosecond cadence and fires.
Anything requiring real computation lives on the host. This split is what makes
the fast path small enough to be fixed-latency and provable.

### Why an FPGA at all

Not for throughput — a CPU can decode ITCH at line rate. For **determinism**:

| | CPU (kernel bypass) | FPGA |
| --- | --- | --- |
| p50 tick-to-trade | ~1–5 µs | ~300 ns (target) |
| p99.9 | 10–50 µs | ~300 ns |
| Source of tail | cache misses, interrupts, scheduling | none — fixed pipeline |

You lose more money to the tail than to the mean. A slow quote gets picked off;
that is a realized loss, not a missed opportunity. The fixed-latency pipeline is
the product.

---

## 2. How each stage works

### 2.1 Network ingress — `rtl/eth/`, `rtl/net/`

Two 10GbE lanes carry Nasdaq's redundant A and B multicast feeds. Both run
through a **cut-through MAC**: bytes are forwarded as they arrive rather than
buffered until the frame completes. Store-and-forward would cost a full frame
time — about 1.2 µs for a 1500-byte frame, four times the entire budget.

⚠️ **The consequence of cut-through:** the Ethernet FCS sits at the *end* of the
frame, so the payload has already been forwarded downstream before the CRC result
is known. `mac_rx.sv` forwards speculatively and raises `tuser` on the last beat
when the FCS is bad; downstream must invalidate. The alternative — waiting — is
what cut-through exists to avoid.

**The RX path never backpressures.** The wire does not stop. `tready` is tied
high; if a FIFO fills, the frame is dropped and counted. Stalling is not an
available behaviour.

**A/B arbitration** deduplicates by MoldUDP64 sequence number — first arrival
wins, the slower copy is discarded. The sequence number lands inside the first
beat, so dedup costs a few nanoseconds before any ITCH parsing.

⚠️ A sequence gap marks the book **stale for the whole channel**, not one symbol,
and the strategy is hard-gated off. Trading a book you know has a hole in it is
the failure mode that ends firms.

### 2.2 Feed handler — `rtl/feed/`

Every ITCH 5.0 message has a **fixed length and fixed field offsets**. That single
property is why this is a fixed-offset field extraction plus a type-indexed mux —
not a parsing state machine. One cycle, every message type.

The 11-byte common prefix (type, stock locate, tracking number, 48-bit timestamp)
is invariant across all types, so it is extracted *in parallel with* type dispatch
rather than after it.

**Symbol lookup is a 1-cycle direct BRAM index.** Nasdaq stock locate codes are
dense integers, so no hash and no CAM is needed. This is the single largest
structural saving in the design.

`venue_state.sv` tracks per-symbol trading state from the non-book messages —
System Event (`S`), Trading Action (`H`), Operational Halt (`h`), Reg SHO (`Y`),
LULD collar (`J`), MWCB (`V`/`W`). Every symbol resets to `TRADE_DISABLED`.

### 2.3 Order book — `rtl/book/`

The hardest block, and the one whose defects are most expensive.

ITCH is **order-based**: Execute, Cancel, Delete and Replace carry *only* a 64-bit
order reference — no symbol, no side, no price. So the book cannot be a price
array alone. It needs two structures kept mutually consistent:

| Structure | Implementation |
| --- | --- |
| `order_ref → {sym, side, price, qty}` | 4-way set-associative, **full 64-bit keys**, CRC-folded hash |
| `(sym, side, price) → aggregate qty` | Direct-indexed on tick-normalized price, 16 levels/side |
| occupancy → best bid/ask | Bitmask + priority encoder, maintained **incrementally** |

Three decisions worth understanding:

**Full keys, never truncated tags.** A truncated tag aliases two order references
onto one entry, and the book then applies an execution to the wrong resting order.
That is silent mis-attribution — the book stays *plausible* and is wrong.

**Entries are never evicted.** If the map cannot hold an order, its eventual
delete resolves to nothing and its quantity is stranded in the level forever. So
a failed insert sets a sticky `stale` flag rather than being counted and ignored.

**Top-of-book is incremental.** A comparator tree over the levels would be ~8 LUT
levels plus routing on *every message*. Instead the updated level is compared
against the current best — one comparison. The one hard case, deleting the current
best, uses the occupancy bitmask and a priority encode: **bounded at one extra
cycle, and counted**, because it is the only variable-latency operation in the
entire fast path.

⚠️ ITCH `Order Replace` (`U`) is **not** an in-place edit. It retires the original
reference and creates a new one, losing queue priority. `book_engine.sv` models it
as delete-then-add by injecting a synthetic add on the following cycle.

### 2.4 Strategy — `rtl/strategy/`

A gate, a parameter read, and a comparator. `trade_gate.sv` refuses unless
*everything* holds: session open, symbol open, params loaded, book not stale, book
not crossed, both sides valid, depth sufficient. Any unknown state rejects.

⚠️ **Parameters are double-buffered with a commit bit.** The host writes the
inactive bank, verifies it, then flips. The fast path must never evaluate against a
half-written parameter record — a strategy trading on a mix of old and new
parameters is a real money-losing bug class, not a theoretical one.

### 2.5 Pre-trade risk — `rtl/risk/` 🔒

The regulatory control required by **SEC Rule 15c3-5**. Structurally
non-bypassable: there is no path from strategy to wire that does not pass through
it.

All checks evaluate **in parallel** and the reason is priority-encoded — chaining
them would blow the 2-cycle budget. Pass and fail take the same time.

| Category | Checks |
| --- | --- |
| Authorization | master enable, kill switch, symbol enable, session open |
| Venue state | halted, LULD band, stale book |
| Price legality | sub-penny (Rule 612), price collar, SSR (Reg SHO Rule 201) |
| Size | max shares, max notional, position limit, gross exposure |
| Rate | messages/sec window, duplicate detection, in-flight credit |
| Integrity | self-match prevention, restricted list, params valid |

**Fail-closed everywhere.** Reset state is: trading disabled, all limits zero,
kill switch *armed*. A bitstream reload never comes up trading.

**All arithmetic saturates.** A wrapped position counter turns a risk check into a
no-op — the difference between a bug and a regulatory incident.

**Every rejection increments its own counter.** A check that has never been
observed to fire is a check you cannot trust.

### 2.6 Order egress — `rtl/order/`

An OUCH Enter Order is mostly constant per symbol — session, account, symbol,
capacity, TIF, display. Only price, shares, side and token vary. So a per-symbol
**template lives in BRAM** and the fast path splices ~13 bytes and fixes the TCP
checksum incrementally (RFC 1624). Encoding an order becomes a memory read and a
mux instead of a serialization.

The **cancel path gets its own template and its own budget line**, because for a
passive strategy cancel latency matters more than entry latency — it is the
difference between pulling a quote and getting picked off.

**TCP is split.** The host owns the connection: handshake, teardown,
retransmission, recovery. The FPGA owns only the steady-state send, using a
pre-computed header template and a sequence counter. It does not retransmit. If
the host detects loss it resynchronizes the FPGA.

⚠️ **Credit-bounded in-flight orders.** The FPGA can emit orders far faster than
the host can account for them. The credit counter bounds how far the two can
diverge before the machine stops.

### 2.7 Host and control plane — `rtl/ctrl/`, `host/`

PCIe is **slow path only** — its round trip alone exceeds the entire fabric
budget. It carries control registers and DMA telemetry, never a trading decision.

The arming sequence is ordered and every step verifies:

```
verify BUILD_ID → load symbol table → load risk params → commit → READ BACK
→ load strategy params → commit → READ BACK → configure session/templates
→ start heartbeat → two-step arm → enable trading
```

⚠️ If the host heartbeat stops, the hardware watchdog fires the kill switch. That
is the design working, not failing.

---

## 3. Coverage

### 3.1 What exists

**243 files · 109,740 lines · 55 RTL modules**

| Area | Files | Lines |
| --- | --- | --- |
| Host software (C++20 / Python) | 58 | 20,347 |
| Verification (`tb/`) | 18 | 10,615 |
| Manuals (13 tiers) | 70 | 32,083 |
| RTL (12 directories) | 64 | ~28,900 |
| Build, constraints, tools | 19 | ~11,400 |

### 3.2 Structural verification

| Check | Result |
| --- | --- |
| Top-level contract — every module `fpga_top.sv` instantiates exists | **11/11 · 100%** |
| RTL discipline (no bare `always`, no `reg`, no float, no latches) | **0 errors** |
| Cross-reference integrity | 1,966 / 2,008 resolve |
| Testbench coverage | 31/55 modules · **56.4%** |

### 3.3 ⚠️ What is *not* covered

**24 RTL modules have no testbench:**

`async_fifo`, `cdc_handshake`, `cdc_pulse`, `cdc_sync_bit`, `clk_rst_gen`,
`counter_bank`, `csr_regfile`, `delay_line`, `dma_log_ring`, `eth_10g_wrapper`,
`fixed_arbiter`, `fv_axis_props`, `gt_wrapper_stub`, `host_ctrl`, `latency_hist`,
`ouch_rx`, `pcie_wrapper`, `position_track`, `prio_encoder`, `reset_sync`,
`rr_arbiter`, `sync_fifo`, `tcp_tx_lite`, `trade_gate`

Two of these are alarming and should be fixed first:

- **`async_fifo`, `cdc_sync_bit`, `cdc_handshake`, `reset_sync`** — the CDC
  primitives. CDC bugs pass simulation, pass timing, pass a week of soak, then
  corrupt one order in ten million. These need multi-ratio testing *and*
  structural CDC lint, neither of which has run.
- **`trade_gate`, `ouch_rx`, `position_track`** — sit directly in the
  trading-decision and position-accounting path.

**Beyond module coverage, none of this has run:**

| Gate | Status |
| --- | --- |
| Verilator lint | never executed |
| Any simulation | never executed |
| Golden-model book equivalence | **never executed** |
| Synthesis | never executed |
| Place & route / timing closure | never executed |
| Hardware bring-up | never executed |
| Venue conformance certification | never executed |

The testbenches exist and are written against the real interfaces. They have not
been run.

---

## 4. Known defects and open decisions

These are tracked rather than hidden. Each is a real gap, not a nicety.

| # | Issue | Impact | Where |
| --- | --- | --- | --- |
| 1 | **LULD bands sourced from ITCH `J`** — which carries *auction collars*, not live LULD bands. Live bands come from the SIP, which this design does not consume. | Bands sit at `0/0`; risk gate is fail-closed; **every order rejected all day**. | `trading_pkg.sv`, `rtl/risk/` |
| 2 | **Tick size hardcoded to whole pennies.** The 2024 SEC Rule 612 amendments may mandate half-penny increments. | Wrong price validation and wrong level spacing. Nasdaq tier already specifies `tick_size` as a per-symbol register — the package has not been reconciled. | `trading_pkg.sv:is_whole_penny` |
| 3 | **Book window auto-anchors.** Level window anchors to the first price after a clear, re-anchors only when the side empties. A symbol that gaps intraday pushes the true top outside the window. | Stale best reported. Needs a host-written reference price. | `price_levels.sv` |
| 4 | **Best quantity cleared on rescan.** After a best-level delete, size reads zero until the next update to that level. Price is correct; size briefly understated. | Needs a second read port. | `top_of_book.sv` |
| 5 | **`gt_wrapper.sv` does not exist.** It is a Vivado-wizard artifact; non-`SIMULATION` builds will fail until generated. | Blocks synthesis. | `rtl/eth/` |
| 6 | **`mac_tx.abort` tied off.** The frame-kill path for speculative transmission is deliberately disconnected pending written venue approval. | Optimization unavailable — by design. | `eth_10g_wrapper.sv` |
| 7 | **All ITCH/OUCH offsets unverified.** Structurally cross-checked (field widths sum to declared lengths) but never confirmed against the spec PDFs. | A wrong offset produces a decoder that works on *some* messages and silently corrupts others. | `itch_pkg.sv`, `ouch_pkg.sv` |
| 8 | Manual tiers 10 (quant) and 11 (platform) incomplete — 2 of 5 files each. | 42 broken forward links. | `manuals/10-*`, `manuals/11-*` |

⚠️ **Issue 7 is the one that should worry you most.** It is the defect class that
testing least reliably catches, because a decoder with one wrong offset produces
a book that is *mostly* right.

---

## 5. Future development

### 5.1 Immediate — before anything else is built

1. **Install a toolchain and run lint.** `scripts/lint.sh`. Nothing below is
   meaningful until the tree compiles.
2. **Verify every ITCH and OUCH offset against the spec PDFs.** Manual, tedious,
   and the highest-value hours available. Issue 7.
3. **Run the golden-model book equivalence soak** over a real pcap corpus,
   asserting top-of-book after *every* message. `tb/book/test_book_soak.py`.
   Until this passes, the book is unverified.
4. **Fix issues 1 and 2** — both are live-fire correctness bugs.
5. **Testbenches for the four CDC primitives**, plus structural CDC lint.
6. **First synthesis and place-and-route.** Learn the real Fmax and the real
   resource cost. Every number in this report changes at that moment.

### 5.2 Near term — proving it works

- Full-path simulation: ITCH frame in → OUCH order out, against `rtl/sim/`
- The **risk test matrix**: every check individually proven to reject
- Kill-switch response-time verification against `KILL_RESP_CYCLES`
- Fault injection: bad FCS, sequence gap, malformed message, link flap, host death
- Hardware bring-up: PCIe enumeration → transceiver link → loopback → first frame
- **First external wire-to-wire measurement.** Until then no latency claim here is
  a measurement.

### 5.3 Medium term — making it real

- Formal proof of the risk-gate properties (`rtl/formal/fv_risk_props.sv` — one of
  four planned files exists)
- Nasdaq conformance certification against the test facility
- Colocation, cross-connects, PTP grandmaster
- Single-symbol minimum-size canary with graduation criteria
- CAT reporting and clock-sync compliance

### 5.4 Longer term — capability

| Direction | Notes |
| --- | --- |
| **Multi-venue** (BX, PSX) | `rtl/venue/` was scoped but not written. ⚠️ Stock locate codes are *per venue* — a shared table silently trades the wrong instrument. |
| **25G/100G** | ⚠️ Not automatically faster: RS-FEC adds large fixed latency. 10G-no-FEC can beat 25G-with-FEC for small frames. |
| **Deeper book** | `BOOK_LEVELS` is the knob; memory arithmetic in `rtl/book/README.md` §4 is the cost. |
| **More strategy primitives** | The parameter-selected primitive set means most new ideas need a parameter change, not a rebuild. |
| **Partial reconfiguration** | Update the strategy without dropping the link. ⚠️ Reconfiguring with open positions is hazardous. |
| **Options / futures** | Different protocols (MDP 3.0/SBE), different book semantics. Larger change than it looks. |

### 5.5 Optimization — only after measurement

`manuals/05-optimization/05-optimization-playbook.md` orders techniques
cheapest-first. **Do not start it until §5.1 item 6 has produced a real
per-stage breakdown.** Intuition about FPGA latency is reliably wrong.

The likely order: faster speed grade and low-latency transceiver modes (free
wins) → widening the datapath so a message lands in one beat → precomputed
per-symbol limits → floorplanning the fast path into one SLR → and only then
pipeline surgery.

⚠️ **What must never be optimized away:** the risk gate, the kill switch, gap
detection, and the error counters. Removing a check to save a cycle converts a
latency problem into a solvency problem.

---

## 6. Honest assessment

**What is genuinely good here:** the architecture is coherent, the interface
contract is centralized and enforced, the safety properties are designed in rather
than bolted on, and the failure modes are counted rather than assumed. The
knowledge base is unusually complete, and where a real-world fact was uncertain it
was flagged rather than invented.

**What should temper that:** none of it has run. The gap between "architecturally
sound SystemVerilog" and "a bitstream that closes timing and decodes a real feed
correctly" is large, and it is usually where projects like this actually fail. The
order book in particular is the kind of block that looks right and is subtly wrong,
and the only test that settles it has not been run.

**The single highest-value next action** is not writing more code. It is
installing Verilator, running the book against a real ITCH capture with the golden
model as oracle, and finding out how wrong it is.

---

*Regenerate the machine-checked portions with `python3 scripts/validate.py --html docs/validation-report.html`.*
