# Order Book Redesign — Architecture Plan

**Trigger:** external FPGA architecture review.
**Verdict:** the order book as built cannot function. Three independent fatal defects, plus a
capacity model that is wrong by roughly two orders of magnitude.
**Status:** plan. Nothing below is implemented yet.

---

## 1. The review, and what it meant

Three observations were made:

| Observation | What it turned out to mean |
| --- | --- |
| *"Order book looks well but the system will not work like it"* | Three fatal defects, any one of which stops it |
| *"Hashmap is not good, insufficient feature and low quality"* | The map overflows at 12.5% load and then permanently disables the book |
| *"You don't have eviction case, you can use cuckoo hashing"* | There is no handling for a full bucket. Cuckoo **relocation** fixes it without dropping orders |

The third point deserves care because it appears to contradict the manual.

[`manuals/04-system-architecture/03-order-book-in-hardware.md`](../manuals/04-system-architecture/03-order-book-in-hardware.md) §2.4 says:

> **Never evict.** An eviction policy in an order map is a correctness bug wearing an
> optimisation costume: the evicted order still exists at the venue, you will receive its
> delete, and it will resolve to nothing.

**That reasoning is correct and stays.** But it conflates two different operations:

| Operation | Effect on the order | Safe? |
| --- | --- | --- |
| **Eviction (drop)** — discard an entry to make room | Order is gone. Its delete resolves to nothing. Level quantity stranded forever. | ❌ Silent corruption |
| **Relocation (cuckoo kick)** — move an entry to its *alternate* bucket | Order still present, still findable, quantity still tracked. | ✅ Lossless |

Cuckoo hashing "evicts" in the second sense only. Every item remains in the table for its
whole lifetime. **The safety rule and the architect's suggestion are compatible** — the manual
simply had no mechanism for a full bucket other than giving up.

---

## 2. Defect inventory

### 2.1 🔴 FATAL — top-of-book price is destroyed on a best-level delete

[`rtl/book/top_of_book.sv:196`](../rtl/book/top_of_book.sv)

```systemverilog
best_lvl_q[upd_sym][side_i] <= new_best_lvl;   // correct level found
best_qty_q[upd_sym][side_i] <= '0;
best_px_q [upd_sym][side_i] <= '0;             // ← price set to ZERO
```

The priority encoder finds the correct new best *level index*, and then the price is written
as zero instead of being reconstructed from that index. After the first best-level delete —
which happens continuously in any active book — the system publishes **bid = $0.00**.

The price is recoverable: `price = window_base + level × tick_size`. The reconstruction was
simply never written.

**Why nothing caught it:** no testbench has ever run.

### 2.2 🔴 FATAL — the price window is 16 cents wide and effectively never re-anchors

[`rtl/pkg/trading_pkg.sv:58`](../rtl/pkg/trading_pkg.sv) sets `BOOK_LEVELS = 16`.

The manual specifies **2048 levels**, a $20.48 window ([§7 of the book manual](../manuals/04-system-architecture/03-order-book-in-hardware.md)).
The RTL implements 16 — a **$0.16 window**, 128× too narrow.

Worse, [`price_levels.sv`](../rtl/book/price_levels.sv) anchors on the first price seen and
re-anchors *only when that side is empty*, which for a liquid symbol never happens. Once the
price drifts more than 8 cents from the open, every subsequent order falls outside the window
and is silently discarded.

**The RTL diverged from its own specification.** The manual was right; the implementation
did not follow it.

### 2.3 🔴 FATAL — the order map overflows almost immediately

Measured, not estimated. 4-way set-associative, 16,384 sets, uniform hashing, Poisson
occupancy:

| Live orders | Load | P(a given set > 4) | Expected overflowing sets |
| ---: | ---: | ---: | ---: |
| 4,096 | 6.2% | 6.6 × 10⁻⁶ | 0.11 |
| 8,192 | 12.5% | 1.7 × 10⁻⁴ | **2.8** |
| 16,384 | 25.0% | 3.7 × 10⁻³ | **60** |
| 32,768 | 50.0% | 5.3 × 10⁻² | **863** |
| 65,536 | 100% | 3.7 × 10⁻¹ | **6,081** |

The current RTL has **no overflow region at all** — a full set sets `map_stale` permanently.
So the book dies at the first collision, within milliseconds of the open.

The manual's 64-entry overflow CAM does not rescue it either:

| Live orders | Load | Items needing overflow | 64 entries enough? |
| ---: | ---: | ---: | :--- |
| 8,192 | 12.5% | 3 | yes |
| 16,384 | 25% | 71 | **no** |
| 32,768 | 50% | 1,231 | **no** |
| 65,536 | 100% | 12,804 | **no** |

**Effective capacity of the specified 65,536-entry table is roughly 8,000 orders.** For 128
symbols that is 62 live orders per symbol. A single liquid name carries far more than that.

### 2.4 🟠 Write-back skew in the order map

`wb_en` / `wb_set` / `wb_way` / `wb_rec` are assigned non-blocking in the stage-2 block, then
consumed by a separate `always_ff` that performs the memory write. That block sees the
*previous* cycle's values, so the write lands one cycle later than the forwarding comparison
assumes. The read-modify-write bypass is off by one and needs re-derivation with a cycle-accurate
timing diagram.

### 2.4b 🔴 FATAL — ITCH Replace double-counted quantity (found by R1)

A fourth fatal defect, missed in the original review of this document.

`order_id_map` emitted `res_add = qty` **at the old record's price** on a `BOOK_REPLACE`, while
`book_engine` *also* injected a synthetic `BOOK_ADD` for the new order reference. So **every
ITCH `U` message added the replaced quantity twice — once at the correct new level, once at the
wrong old one.**

Replace is a common message. The book would have inflated steadily all session, and because the
inflation lands at plausible prices it would have looked like ordinary depth.

Fixed: replace is now a pure delete in the map, with an SVA enforcing `res_add == 0`.

### 2.4c ⚠️ Test-methodology trap — the obvious stress test *passes* the broken design

The single most important finding of the redesign, and it is about testing rather than RTL.

With **dense sequential** order references (`ref`, `ref+1`, `ref+2`, …) the *original, broken*
4-way table shows **zero overflows at every load up to 90%** — the legacy hash maps a contiguous
range near-bijectively, so nothing ever collides.

With realistically thinned keys, the same design strands 4 orders at 12.5% load and 9,227 at
90%, exactly matching the Poisson prediction in §2.3.

⚠️ **A stress test written the obvious way would have validated the defect.** R7 must generate
order references with realistic sparsity, never a dense range. This is now called out in the
module header.

### 2.5 🟡 Dead signals

`s1_valid_d` and `s1_clear_d` in [`price_levels.sv:151`](../rtl/book/price_levels.sv) are
declared and never assigned. Verilator lint would have caught this; lint has never run.

### 2.6 🟡 Tick size is not parameter-linked

`book_pkg::TICK_RECIP` is hardcoded to the ÷100 reciprocal while `TICK_UNITS` is a parameter.
Changing `TICK_UNITS` to 50 for a half-penny regime silently produces wrong level indices.

---

## 3. Target design

### 3.1 Order map — cuckoo, d=2 hashes × b=4 slots

```
key ──┬─► h0(key) ─► bucket A (4 slots) ──┐
      │                                    ├─► 8 full-key compares ─► hit / miss
      └─► h1(key) ─► bucket B (4 slots) ──┘        (1 cycle, worst case)
                                    │
                     stash (16-entry CAM, parallel) ─┘
```

**Lookup is O(1) worst case** — exactly two parallel bucket reads and eight comparators, every
time, for every key. That is what a fixed-latency pipeline requires; linear probing or chaining
would introduce variable latency and is disqualified regardless of its average performance.

**Insert:** if either bucket has a free slot, place it. Otherwise pick a victim, move it to its
alternate bucket, and repeat. Bounded at `MAX_KICKS` (16). If the chain does not terminate, the
item goes to the stash. If the stash is full, *then* the book goes stale.

**Delete:** locate and invalidate. No relocation needed.

Published load thresholds:

| Configuration | Max load |
| --- | ---: |
| d=2, b=1 | 0.50 |
| d=2, b=2 | 0.897 |
| **d=2, b=4** | **0.976** |
| d=2, b=8 | 0.996 |

At 90% load with a 16-entry stash, insertion failure is negligible. Compare against the
current design, which fails at 12.5%: **a ~7× improvement in usable capacity for identical
memory.**

> ⚠️ **Full keys are stored, never tags.** Partial-key cuckoo (storing a tag and deriving the
> alternate bucket from it) halves the memory and is standard in cuckoo *filters* — but a tag
> collision returns the wrong order, and updating the wrong resting order is silent book
> corruption. The manual is right to insist on full keys; this does not change.

#### ⚠️ Correction — the 0.976 threshold is not reachable, and this section originally said it was

The first version of this document sized the table at 90% load on the strength of the published
0.976 threshold. **That was wrong, and R1 measured it.** A Python model of the exact algorithm,
65,536 slots, realistic (non-sequential) keys:

| Load | Insert failures |
| ---: | ---: |
| 50 / 70 / 80 / 85 % | **0** |
| 90 % | **322** |

The 0.976 figure is asymptotic for an *unbounded* random-walk insert. A bounded 16-kick chain
does not reach it. **Size for ≤ 80% of slots.**

R1 also measured that the background relocation engine is not an optimisation but a
requirement. At 85% load, same memory and same lookup:

| Relocation engine | Insert failures |
| --- | ---: |
| **Off** (a static overflow CAM — i.e. the d-left arrangement) | **1,112** |
| **On** | **0** |

Enlarging the stash instead does nothing — 15, 31, 63 and 127 entries all give identical
results. **Draining the stash is what matters, not buffering more.** That is the empirical case
for cuckoo over d-left here, and it is measurement rather than argument.

#### Sizing

Slots must be a power of two, which absorbs much of the 90%→80% difference in practice.
Record width 138 bits.

| Live orders | Slots | Load | Memory | URAM288 | Fits one SLR? |
| ---: | ---: | ---: | ---: | ---: | :--- |
| 102,400 (manual p99) | 131,072 | 78% | 18.1 Mbit | **64** | ✅ with 128 URAM of levels = 192 of ~320 |
| 250,000 | 524,288 | 48% | 72.4 Mbit | **252** | ⚠️ leaves ~68 for everything else |
| 500,000 | 1,048,576 | 48% | 144.7 Mbit | **503** | ❌ **exceeds the SLR entirely** |

⚠️ A VU9P SLR holds ~320 URAM288 and the whole fast path must fit in one. **500k tracked orders
is not achievable on this device** — that configuration forces either fewer symbols, a narrower
price window, or a different part. Capacity is a measurement, not a preference; take the live
order count from `tools/pcap/stats.py` against a real capture before choosing.

### 3.2 Population control — track only what is in the window

An order is in the map **if and only if** its quantity is in the level array.

This makes a delete for an untracked order a correct no-op rather than an error, and bounds
the map population to `symbols × window levels × orders per level` instead of the venue's
entire live book. It also makes out-of-window handling coherent: an order outside the window
was never added to a level, so it must never enter the map.

⚠️ This invariant is the whole correctness argument. It must be asserted in RTL and proven in
the golden-model equivalence test, not assumed.

### 3.3 Price levels — 2048 per side, host-anchored

Implement what the manual already specifies. Add:

- **Host-written per-symbol reference price**, refreshed from last trade or previous close.
  This requires a config port on `book_engine`, which the current `fpga_top` contract lacks —
  a deliberate two-file change.
- **Out-of-window ⇒ per-symbol stale + host re-anchor + resync**, not silent discard.
- Occupancy bitmap over 2048 levels ⇒ hierarchical priority encoder (64 groups × 32) to keep
  the new-best search inside its cycle budget.

### 3.4 Top of book — correct price reconstruction

- Reconstruct price from level index and window base on every best change.
- Read the true quantity from the level array rather than zeroing it.
- Cache second-best so the common delete case avoids a rescan entirely.

---

## 4. What this does not fix

Being explicit, because the request was for a system that "runs in production without issue":

- Nothing here has been compiled, simulated, synthesized, or run on hardware.
- ITCH/OUCH field offsets remain unverified against the specification PDFs.
- The LULD band source defect and the Rule 612 tick-size assumption are separate items.
- Exchange conformance certification, broker-dealer market access, and compliance review are
  organisational prerequisites that no amount of code satisfies.

Correct RTL is necessary for production. It is nowhere near sufficient.

---

## 5. Task breakdown

| ID | Task | Blocking? | Where |
| --- | --- | :-: | --- |
| **R1** | Cuckoo order map: d=2×b=4, relocation FSM, 16-entry stash, full keys | 🔴 | `rtl/book/order_id_map.sv` |
| **R2** | Price levels: 2048/side, host anchor, out-of-window ⇒ stale | 🔴 | `rtl/book/price_levels.sv` |
| **R3** | Top-of-book: price reconstruction, true qty, second-best cache | 🔴 | `rtl/book/top_of_book.sv` |
| **R4** | Hierarchical priority encoder for 2048-bit occupancy | 🔴 | `rtl/common/prio_encoder.sv` |
| **R5** | Book engine rewire; fix write-back skew; remove dead signals | 🔴 | `rtl/book/book_engine.sv` |
| **R6** | Package sizing, tick-size/reciprocal linkage, book config port | 🔴 | `rtl/pkg/`, `rtl/fpga_top.sv` |
| **R7** | Golden-model equivalence + cuckoo stress (load to 95%, kick chains, stash overflow) | 🔴 | `tb/book/` |
| **R8** | CDC primitive testbenches — the untested half of coverage | 🟠 | `tb/common/` |
| **R9** | LULD band source fix + Rule 612 tick-size parameterisation | 🔴 | `rtl/risk/`, `rtl/pkg/` |
| **R10** | Update the book manual to match: cuckoo, sizing math, invariant | 🟠 | `manuals/04-*/03-*` |

`R1`–`R6` are the ones that make the system function at all.
