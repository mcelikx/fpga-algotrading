# 04.03 — Order Book in Hardware

> **Why this matters here:** this is the hardest design problem in the system. It
> owns rows **B0–B4** — 5 cycles, 32.0 ns — and it is the only block that holds
> megabytes of mutable state that must be *exactly* right. A feed handler bug drops
> a message and you notice. A book bug corrupts a quantity by 100 shares and you
> trade against a book that does not exist, profitably, for weeks, until you don't.

---

## 1. ITCH is order-based, and that changes everything

There are two families of market data feed:

| Family | What a message says | Example | Book maintenance |
| --- | --- | --- | --- |
| **Level-based** (aggregated) | "the bid at $10.01 is now 4,500 shares" | CME MDP 3.0 incrementals, most L2 feeds | Write the level. Done. Stateless. |
| **Order-based** | "order 0x3F2A…91 was deleted" | **Nasdaq TotalView-ITCH 5.0**, ARCA XDP, BATS PITCH | You must already know what order `0x3F2A…91` *was*. |

ITCH 5.0 is order-based. `Order Executed`, `Order Cancel` and `Order Delete` carry a
**64-bit order reference number** and (for delete) *nothing else about the order* —
no price, no side, no quantity.

```
Add Order (A):     locate=42  ref=0x00000000000A3F21  side=B  shares=300  price=101.5000
   …later…
Order Delete (D):  locate=42  ref=0x00000000000A3F21
                              └── that is the entire useful payload
```

To apply that delete you must recover `(side, price, shares)` from the reference
number. **Therefore the book is not one data structure. It is two:**

```
        ┌──────────────────────────────────────────────────────────────────┐
        │  STRUCTURE 1 — ORDER MAP                                         │
        │  order_ref (64-bit, sparse)  →  {slot, side, level, qty}         │
        │  ~65,536 live entries.  Written on Add. Read on Exec/Cxl/Del.    │
        │  Purpose: recover what an order *was*.                           │
        └───────────────────────────┬──────────────────────────────────────┘
                                    │ yields (slot, side, level, delta)
                                    ▼
        ┌──────────────────────────────────────────────────────────────────┐
        │  STRUCTURE 2 — LEVEL ARRAY                                        │
        │  (slot, level)  →  {aggregate_qty, order_count, epoch}           │
        │  128 symbols × 2048 ticks.  Read-modify-write on every update.   │
        │  Purpose: answer "how much is at this price".                    │
        └───────────────────────────┬──────────────────────────────────────┘
                                    │
                                    ▼
        ┌──────────────────────────────────────────────────────────────────┐
        │  STRUCTURE 3 (derived) — TOP OF BOOK                             │
        │  slot → {bid_lvl, bid_qty, bid_cnt, ask_lvl, ask_qty, ask_cnt}   │
        │  Maintained INCREMENTALLY. Never recomputed. §6.                 │
        └──────────────────────────────────────────────────────────────────┘
```

⚠️ People coming from level-based feeds routinely under-scope this. The order map is
the larger of the two structures, it is the one with the hard sizing problem, and it
is on the critical path for *three of the five* book-affecting message types. Budget
for it first.

> **Verify:** that `Order Delete` carries only locate + tracking + timestamp + order
> reference, and that `Order Executed` carries reference + executed shares + match
> number (no price, no side), is from the Nasdaq TotalView-ITCH 5.0 spec. Confirm
> before freezing the order-map entry format; see [../08-nasdaq/](../08-nasdaq/).

---

## 2. Sizing the order map

### 2.1 The problem

- Keys are **64-bit and sparse**. Nasdaq assigns reference numbers monotonically per
  session, so the *live* set is roughly a moving window — but ⚠️ **do not design
  against that.** It is an implementation detail of the matching engine, it is not in
  the spec, and it has changed. A design that indexes by `ref[19:0]` works in
  backtest and corrupts silently in production the day the venue changes allocation.
- The live population is large. Across all of Nasdaq, millions of resting orders.
  Across **our filtered 128 symbols**, far fewer.

### 2.2 The arithmetic

| Quantity | Value | Source |
| --- | ---: | --- |
| Nasdaq-listed + traded securities on TotalView | ~9,000 | reference data |
| Our subscribed universe `N_SYMBOLS` | **128** | design choice |
| Typical live resting orders per active symbol | 200–2,000 | estimate, measure yours |
| Peak live orders per symbol (open/close, high-activity name) | ~8,000 | estimate |
| ⇒ Peak live orders in our universe | 128 × 8,000 = **1,024,000** worst case | |
| ⇒ Realistic p99 | 128 × 800 = **102,400** | |

> **Verify:** these per-symbol depth figures are estimates. Derive yours by replaying
> a full day of TotalView pcap through the Python golden model and histogramming the
> live-order count per symbol. Do this **before** sizing the memory; it is a
> one-afternoon job and it determines a URAM budget you cannot change post-tapeout
> of the bitstream without a rebuild.

### 2.3 The design: 4-way set-associative hash table

```
              order_ref[63:0]
                    │
              ┌─────▼──────┐
              │  CRC-32C   │  XOR tree, 1 cycle, ~200 LUT   ← rtl/common/crc32.sv
              └─────┬──────┘
                    │ h[31:0]
        set = h[13:0]   (16,384 sets)
                    │
   ┌────────────────┼────────────────┬────────────────┐
   ▼                ▼                ▼                ▼
 way0             way1             way2             way3          ← read all 4 in parallel
 {v, key[63:0], slot[11:0], side, level[10:0], qty[31:0], epoch[3:0]}   = 128 bits
   │                │                │                │
   └────────────────┴───────┬────────┴────────────────┘
                    ┌───────▼────────┐
                    │ key compare ×4 │   full 64-bit compare — no tag truncation
                    │ → way select   │
                    └───────┬────────┘
                            ▼  hit → {slot, side, level, qty}
                     miss → overflow region (§2.5)
```

| Parameter | Value | Rationale |
| --- | --- | --- |
| Sets | 16,384 (2¹⁴) | |
| Ways | 4 | 4 parallel reads is one URAM column group; 8 ways doubles the compare width for marginal load-factor gain |
| **Capacity** | **65,536 entries** | 0.64× the realistic p99, 0.064× the absolute worst case — see §2.4 |
| Entry width | 128 bits | `{valid, key[63:0], slot[11:0], side, level[10:0], qty[31:0], epoch[3:0]}` = 125 → 128 |
| Total | 8.4 Mbit | 65,536 × 128 |
| URAM | **32** (4 ways × 2 columns × 4 rows) | URAM288 = 4096 × 72 |

⚠️ **Store the full 64-bit key.** The tempting optimisation is a 16- or 32-bit tag
from a second hash, saving 4 Mbit. Do not. A tag collision is a **silent
mis-attribution**: you apply a delete to the wrong order, at the wrong price, in the
wrong symbol, and nothing anywhere reports an error. At 32-bit tags and 10⁹ lookups
a day, false positives are a daily event. The 4 Mbit costs 16 URAMs out of 960.

### 2.4 Capacity is a policy decision, not a guess

65,536 entries will not hold the absolute worst case. That is deliberate, and the
overflow behaviour is the actual design:

| Load | Behaviour |
| --- | --- |
| < 70 % (typical) | All 4 ways rarely full; insert succeeds in 1 cycle |
| Set full on insert | Insert into the **overflow region** (§2.5); +0 cycles for the add |
| Overflow region full | ⚠️ **`book_stale` for that symbol.** Not "evict something". |

**Never evict.** An eviction policy in an order map is a correctness bug wearing an
optimisation costume: the evicted order still exists at the venue, you will receive
its delete, you will not find it, and you will now have a permanent phantom at a
price level. Every subsequent decision on that symbol is made against liquidity that
is not there. Going stale and resyncing (§9) costs you a symbol for a few hundred
milliseconds. Evicting costs you the rest of the day and you will not notice.

### 2.5 Overflow region

A small fully-associative region of 64 entries in registers/LUTRAM, searched in
parallel with the main table:

- Hit costs **+0 cycles** (compared in parallel at B1).
- Insert on a full set costs +0 cycles.
- 64 × 128 bits = 8 Kbit of LUTRAM plus 64 × 64-bit comparators (~600 LUT).
- `overflow_occupancy` is a monitored counter; sustained non-zero means the table is
  undersized and you should rebuild with more sets.

### 2.6 The software-assisted alternative, and why we reject it for the hot path

**The design:** hardware holds a small map of "orders near the touch"; a miss goes
over PCIe to the CPU, which holds the full map in DRAM.

| | Hardware map | Software-assisted |
| --- | --- | --- |
| Hit latency | 2 cycles (12.8 ns) | 2 cycles |
| Miss latency | +0 (overflow region) | **~2–4 µs** PCIe round trip |
| Miss rate | ~0 | 10–40 % (you cannot predict which orders get deleted) |
| Determinism | fixed | catastrophic bimodal distribution |
| Book correctness during a miss | exact | the book is *wrong* for 4 µs, or the pipeline stalls |

A 4 µs stall on the RX path violates §1 of [02-feed-handler-design.md](02-feed-handler-design.md)
outright. **Rejected for the hot path.**

Where software assistance *is* right: **rebuilding** the map after a gap (§9), and
**auditing** it — the CPU maintains a shadow map from the DMA-tapped message stream
and periodically compares aggregate counts with the hardware. A divergence is a
hardware bug and should stale the symbol. That is a genuinely valuable use of the
CPU's memory capacity, off the critical path.

---

## 3. Price-level aggregation: the structure decision

Given `(slot, price)`, we need `aggregate_qty` and `order_count`, updated on every
message, and we need the best price on each side.

| Structure | Update | Find best | Memory | Verdict |
| --- | --- | --- | --- | --- |
| **Direct-indexed array on tick-normalized price** | **O(1), 1 cycle** | O(1) incremental (§6), bounded rescan on best-delete | `N_SYM × N_LVL` | **CHOSEN** |
| Sorted linked list of levels | O(n) traverse to insert | O(1) (head) | compact | pointer chasing in BRAM: 1 cycle *per hop*. Unbounded. Rejected. |
| Binary heap | O(log n) = 11 cycles at 2048 levels | O(1) | compact | 11 cycles ≫ our 5-cycle budget. Rejected. |
| Skip list / balanced tree | O(log n) with worse constants | O(1) | compact | rejected for the same reason, plus rebalancing is variable-latency |
| Sorted top-N registers only | O(N) compare | O(1) | tiny | ⚠️ cannot answer "what is the new best" after the top N are all deleted. Rejected as the *primary* structure; used as the published view (§7). |

**Direct index wins for equities and it is not close.** The reason is structural: a
price level array turns "find the level for this price" from a search into an
address computation. Every alternative is a search, and a search in BRAM costs one
cycle per probe.

The reason it works *for equities specifically*: the tick is fixed and coarse
relative to the price, so the number of *possible* prices within any credible
intraday range is small. This is not true for all asset classes — a futures curve or
a crypto pair with 8 decimals needs a different answer. See §5.

---

## 4. Tick normalization: price → level index

Reg NMS Rule 612 forbids sub-penny quoting for NMS stocks priced ≥ $1.00. ITCH
carries prices as integers with **4 implied decimals**. So for our universe:

```
$101.5000  arrives as  1015000
tick       = $0.01     =     100 ITCH units
level      = (price − base[slot]) / 100
```

Division by 100 is not a shift. Options:

| Approach | Cost | Verdict |
| --- | --- | --- |
| Index by raw ITCH price | 100× the memory (1.26 Gbit) | absurd |
| DSP divide | multi-cycle, huge | no |
| **Multiply by reciprocal** | 1 DSP-cascade multiply, folded into R4 | **chosen** |

```systemverilog
// rtl/feed/itch_dispatch.sv — computed in R4, in parallel with field extraction,
// so the book at B2 receives a level index, never a price. Costs 0 budget rows.
// x / 100  for x < 2^31 :  (x * 32'h51EB851F) >> 37
logic [63:0] prod;
assign prod       = px_q * 64'h51EB851F;
assign px_cents   = prod[63:37];                       // exact for the full range
assign px_exact   = (px_cents * 27'd100 == px_q);      // sub-penny detector, free
assign level      = px_cents - base_cents_q;           // per-symbol reference
assign level_ok   = px_exact && (level < N_LVL);
```

⚠️ **`px_exact` is not optional.** If a sub-penny price appears (a venue change, a
sub-dollar symbol that slipped into the universe, a corrupt field), truncating
silently maps two distinct prices onto one level and the aggregate quantity there
becomes permanently wrong. On `!px_exact`: count `subpenny_seen`, do not apply the
update, and **stale the symbol**. This costs you one symbol and saves you a book.

### The window and its base

A full price range per symbol is unnecessary — a stock does not trade at $0.01 and
$400 on the same day. We keep a **bounded window**:

| Parameter | Value | Meaning |
| --- | ---: | --- |
| `N_LVL` | **2048** | levels per symbol, both sides in one array |
| Window span | **$20.48** | 2048 × $0.01 |
| `base_cents[slot]` | per-symbol | set at start of day from the previous close, re-centred by the CPU |
| Out-of-window update | counted, `level_out_of_window++` | see below |

**Out-of-window policy.** A price outside `[base, base + 2048)` means the stock has
moved more than $20.48 from the base, or the message is garbage. Policy:

1. Count it. Do **not** wrap the index (⚠️ wrapping aliases a $30 price onto a $10
   level — silent corruption, the worst kind).
2. If `level_out_of_window` for a symbol exceeds a small threshold, **stale the
   symbol** and signal the CPU to re-centre `base_cents` and resync (§9).
3. Re-centring is a slow-path operation. It takes milliseconds. It happens a handful
   of times a day for a volatile name. That is acceptable; hardware re-centring
   would require a full array shift and is not.

⚠️ For a name that gaps at the open, the window will be wrong until re-centred.
Start-of-day `base_cents` should be set from the prior close *minus* half the window,
and the CPU should re-centre off the opening auction print before enabling trading.

---

## 5. Memory budget

### Level array

| Field | Bits |
| --- | ---: |
| `aggregate_qty` | 32 |
| `order_count` | 16 |
| `epoch` (§9) | 4 |
| padding | 12 |
| **entry** | **64** |

```
128 symbols × 2048 levels × 64 bits = 16.78 Mbit
                                    = 16.78e6 / 288e3 = 59 URAM288
```

### Occupancy bitmap (for the best-delete rescan, §6.3)

```
128 symbols × 2048 levels × 1 bit = 262 Kbit
organised as 128 × 8 words of 256 bits → 1 URAM or 8 BRAM36
```

### Order map (§2)

```
65,536 × 128 bits = 8.39 Mbit = 32 URAM288 (4 ways × 2 wide × 4 deep)
```

### Top of book

```
128 × 160 bits = 20.5 Kbit → LUTRAM / 1 BRAM36 (dual-ported: fast path A, telemetry B)
```

### Totals

| Structure | Mbit | URAM288 | BRAM36 |
| --- | ---: | ---: | ---: |
| Order map (4-way, 64K) | 8.39 | 32 | — |
| Order map overflow (64 entries) | 0.008 | — | LUTRAM |
| Level array | 16.78 | 59 | — |
| Occupancy bitmap | 0.26 | 1 | — |
| Top of book | 0.02 | — | 1 |
| Symbol tables (from 04.02) | 0.83 | 3 | 2 |
| **Total** | **26.3** | **95** | **3** |

On a VU9P (960 URAM288, 2160 BRAM36) that is **~10 % of URAM**. There is room to
grow `N_SYMBOLS` to 512 or `N_LVL` to 4096 if measurement justifies it — but note
that **all of it must fit in one SLR** (04.01 §6), and a VU9P SLR has 320 URAMs. At
95 we are comfortable; at 400 we would not be.

### Scaling table

| `N_SYMBOLS` | `N_LVL` | Level array | + order map | URAM total | Fits one SLR? |
| ---: | ---: | ---: | ---: | ---: | --- |
| 128 | 1024 | 8.4 Mbit | 8.4 Mbit | 62 | yes |
| **128** | **2048** | **16.8 Mbit** | **8.4 Mbit** | **95** | **yes — chosen** |
| 256 | 2048 | 33.6 Mbit | 16.8 Mbit | 180 | yes |
| 512 | 2048 | 67.1 Mbit | 33.6 Mbit | 355 | **no** — exceeds 320 |
| 512 | 1024 | 33.6 Mbit | 33.6 Mbit | 234 | yes |

---

## 6. Top of book, maintained incrementally

### 6.1 Why incremental

Recomputing the best bid over 2048 levels is a 2048-wide priority encode. Even as a
pipelined tree that is `⌈log₂ 2048⌉ = 11` cycles = 70.4 ns —
[../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) §6 —
which is more than double our entire book budget. So the best is a **register that we
maintain**, and the only question is what each message type does to it.

### 6.2 The update rules

State per symbol: `bid_lvl`, `bid_qty`, `bid_cnt`, `ask_lvl`, `ask_qty`, `ask_cnt`.
(`bid_lvl` higher = better bid; `ask_lvl` lower = better ask.)

| ITCH | Order map | Level array | Top of book | Cost |
| --- | --- | --- | --- | ---: |
| `A` / `F` Add | **insert** `ref → {slot, side, lvl, qty}` | `qty[lvl] += shares`; `cnt[lvl] += 1`; `bmap[lvl] = 1` | bid: `lvl > bid_lvl` → **new best** (`bid_lvl=lvl`, `bid_qty=shares`, `bid_cnt=1`); `lvl == bid_lvl` → `bid_qty += shares`, `bid_cnt += 1`; else no change | 5 cyc |
| `E` Executed | **read**, `qty -= exec`; if 0 → **delete** | `qty[lvl] -= exec`; if 0 → `cnt -= 1`, and if `cnt==0` → `bmap[lvl]=0` | if `lvl == best` → `best_qty -= exec`; if `best_qty == 0` → **RESCAN** | 5 cyc (+2) |
| `C` Executed w/ price | identical to `E` | identical | identical | 5 cyc (+2) |
| `X` Cancel (partial) | **read**, `qty -= cancelled` | `qty[lvl] -= cancelled` | as `E` | 5 cyc (+2) |
| `D` Delete (full) | **read + delete** | `qty[lvl] -= qty`; `cnt -= 1`; if `cnt==0` → `bmap[lvl]=0` | as `E` | 5 cyc (+2) |
| `U` Replace | **delete** old ref, **insert** *new* ref | two RMWs: decrement old level, increment new level | apply the delete rule, then the add rule | **6 cyc** |

⚠️ **`Order Replace` issues a new order reference number.** The old reference is
dead. If you implement replace as "look up the ref and modify it in place", you leak
the old key (it will never be deleted, and the map fills) *and* every subsequent
message for that order arrives with the new reference, misses, and is dropped. It
must be `delete(old_ref)` + `insert(new_ref)`. `symbol_filter` expands `OP_REPL`
into two `book_cmd`s back-to-back; the book pipeline handles them at II = 1, so the
cost is +1 cycle, not +5. This is jitter row J5 in the master budget.

⚠️ `C` (Order Executed With Price) has a `printable` flag. That flag affects the
**trade tape**, not the book — the shares leave the book either way. Treating
`printable = N` as "no book effect" is a classic and expensive error.

> **Verify:** the `U`-issues-a-new-reference semantics, and the `C` printable-flag
> semantics, from the Nasdaq TotalView-ITCH 5.0 spec. Both are in
> [../08-nasdaq/](../08-nasdaq/) and both are the kind of detail that a plausible
> mental model gets wrong.

### 6.3 ⚠️ The one operation that is not O(1)

**Deleting the last order at the current best price.** The new best is the
next-highest occupied bid level, and finding it is a search.

Three mitigations, used together:

**(a) Occupancy bitmap + bounded priority encode.** `bmap[slot]` is 2048 bits stored
as 8 words of 256 bits. On a best-emptying delete:

```systemverilog
// rtl/book/occupancy_bmap.sv — the rescan path. +2 cycles (J4).
// Cycle 1: read the 256-bit word containing the old best, mask off levels
//          at-or-above it, priority-encode down.
// Cycle 2: if that word is now empty, read the adjacent word and encode.
//          Bounded at TWO words = 512 ticks = $5.12 below the old best.
logic [255:0] w0, w1, masked;
assign masked  = w0 & ((256'd1 << old_best[7:0]) - 1);      // strictly below
assign hit0    = |masked;
assign new_lvl = hit0 ? {old_best[10:8], prio_enc_msb(masked)}
                      : {old_best[10:8] - 3'd1, prio_enc_msb(w1)};
```

- Cost: **+2 cycles = 12.8 ns**. Bounded. Counted (`rescan_cnt`).
- If both words are empty: the side is empty within $5.12 of the old touch. Publish
  `bid_valid = 0` and let the strategy gate on it. Do **not** search further — an
  unbounded search on the fast path is forbidden (04.01 §5).

**(b) Cached second best.** Maintain `bid2_lvl`/`bid2_qty` alongside the best,
updated by the same incremental rules. When the best empties and the cached second
is still occupied, promotion is **0 extra cycles** — no rescan at all.

```
Hit rate estimate: the second-best level survives the best-level delete in the
large majority of cases, because deletes cluster at the touch. Estimated ~80–90 %
of best-emptying deletes are covered by the cache, reducing the J4 rate to
~1 in 20 deletes overall.
```

⚠️ The cache itself must be maintained correctly, which is the subtle part: an `A`
at a level between `bid2` and `bid` must *become* the new `bid2`. Get this wrong and
you promote a stale level and publish a best bid that does not exist. This is the
single highest-value unit test in the book (§10).

**(c) Bounded depth.** We do not need to know the book below the window in (a). The
strategy consumes top-3 (§7). If the top 3 all evaporate within one cycle, we are in
a market state where not quoting is the correct answer anyway.

### 6.4 Estimated rescan frequency

| Event | Estimated share of book messages | Rescan? |
| --- | ---: | --- |
| Add | ~35 % | never |
| Execute / partial cancel not emptying a level | ~40 % | never |
| Delete not at the best | ~15 % | never |
| Delete at the best, level not emptied | ~5 % | never |
| Delete emptying the best, second-best cached and valid | ~4 % | **0 cycles** |
| Delete emptying the best, cache miss | **~1 %** | **+2 cycles** |

> **Verify:** these proportions are estimates for a liquid Nasdaq name. Measure the
> real distribution from a pcap replay through the golden model before relying on the
> p99 estimate in 04.01 §5.

---

## 7. Depth: how many levels does the strategy actually need?

Two separate questions, routinely conflated:

| Question | Answer |
| --- | --- |
| How many levels must the book **maintain**? | All of them in the window. You cannot know the next best without them. |
| How many levels must the book **publish**? | For most hardware strategies: **1 to 3.** |

So the design decouples the two: the level array holds 2048, `tob_track` publishes
`bbo_upd` with **top-3 per side** (level index, aggregate qty, order count), 160 bits.

**The argument for top-of-book only.** Hardware strategies that win on latency are
reactive: something crossed a threshold at the touch, act now. Depth is a *slow*
signal — it changes the shape of your quoting, not the trigger. Concretely:

| Strategy class | Depth needed | Where it lives |
| --- | --- | --- |
| Latency arb / take on cross | L1 only | FPGA |
| Passive quoting with join/improve logic | L1 + own queue position | FPGA |
| Quote skewing on book imbalance | L1–L3 | FPGA (top-3 is published) |
| Imbalance/pressure signals over 10 levels | L1–L10 | **CPU**, at ms scale, written into the parameter table (04.04 §6) |
| Order-flow-toxicity / VPIN-style | full book + history | CPU, minutes |

Publishing 3 levels costs 160 bits of `bbo_upd` and nothing in latency. Publishing 10
costs ~480 bits of routing across the SLR for a signal the trigger logic does not
consume in the same cycle. **Publish 3.** If a strategy needs more, it is a slow
signal and it belongs in the parameter table.

---

## 8. ⚠️ The read-modify-write hazard

This is the bug that will happen, it will not throw an error, and it will make you
money right up until it doesn't.

### The hazard

```
cycle:      0        1        2        3
cmd A  →  [B2 read lvl=17]  [B3 write lvl=17 = 500]
cmd B  →           [B2 read lvl=17]  [B3 write lvl=17 = ???]
                        ▲
                        └── reads 300 (the OLD value) because A's write
                            has not happened yet. B computes 300−100=200
                            and writes 200, destroying A's +200.
```

Back-to-back updates to the same `(slot, level)` are **common**, not rare: an
execution and the follow-on delete of the same order, a cancel/replace pair, several
orders leaving the touch in the same microsecond. In a pcap replay of an active
symbol you will hit this thousands of times a second.

The book does not error. It just drifts, quietly, in the direction of the traffic.

### The fix: write forwarding

```systemverilog
// rtl/book/level_rmw.sv — budget row B3, 1 cycle, fixed. No stall path.
logic [10:0] wr_lvl_q;  logic [11:0] wr_slot_q;  logic wr_en_q;
logic [47:0] wr_data_q;                              // {qty[31:0], cnt[15:0]}

// The value B2 *should* have read: bypass the in-flight write.
wire same_addr = wr_en_q && (wr_slot_q == rd_slot_q) && (wr_lvl_q == rd_lvl_q);
wire [47:0] lvl_eff = same_addr ? wr_data_q : lvl_from_ram;

// Apply the delta and write back.
wire [31:0] new_qty = cmd_is_add ? (lvl_eff[47:16] + cmd_qty)
                                 : (lvl_eff[47:16] - cmd_qty);
wire [15:0] new_cnt = cmd_is_add ? (lvl_eff[15:0] + 16'd1)
                    : (new_qty == 0) ? (lvl_eff[15:0] - 16'd1) : lvl_eff[15:0];

always_ff @(posedge clk) begin
    wr_en_q   <= cmd_valid;
    wr_slot_q <= rd_slot_q;  wr_lvl_q <= rd_lvl_q;
    wr_data_q <= {new_qty, new_cnt};
end
```

**Bypass, do not stall.** A stall here would be the largest jitter source in the
system and it would fire on the most common traffic pattern. The bypass costs a
2-input mux and a 23-bit comparator — well inside a 6.4 ns cycle.

### Depth of the bypass

Our RAM read latency is 1 cycle (B2 → B3), so exactly **one** in-flight write must
be forwarded. If a future retiming pushes the level array to a 2-cycle read
(registered output for Fmax), the bypass becomes **two-deep** and the comparator
becomes two comparators with priority to the *most recent*. That coupling must be
parameterised, not hand-edited:

```systemverilog
parameter int RAM_RD_LAT = 1;
parameter int BYPASS_DEPTH = RAM_RD_LAT;      // they are the same number, always
```

⚠️ A bypass that is one stage too shallow produces *exactly* the drift in the diagram
above, just less often — which makes it harder to find, not easier.

### The same hazard exists in the order map

Two messages touching the same order reference back-to-back (execute-then-delete)
hit the same set. `order_map` needs the identical bypass on its write port. It is
the same code with a different key width.

### Underflow

```systemverilog
assert property (@(posedge clk) disable iff (rst)
    (cmd_valid && !cmd_is_add) |-> (lvl_eff[47:16] >= cmd_qty))
    else $error("level qty underflow — book has drifted");
```

⚠️ In synthesis, saturate at zero **and count it** (`level_underflow`). A level
quantity going negative means the book was already wrong; the counter is how you
find out. A wrapped 32-bit quantity of 4.29 billion shares at the touch is how a
strategy decides to do something very expensive.

---

## 9. Resynchronization after a gap

### 9.1 The O(1) clear trick

Naively, staling a symbol means zeroing 2048 level entries. At one write per cycle
that is 2048 cycles = **13.1 µs** per symbol, during which the write port is
unavailable to the fast path. For all 128 symbols, 1.7 ms. Unacceptable.

**Epoch tagging.** Each level entry carries a 4-bit `epoch`. Each symbol has a
current `epoch[slot]`. An entry whose epoch does not match reads as **zero**:

```systemverilog
wire stale_entry = (lvl_epoch != epoch_q[rd_slot_q]);
wire [47:0] lvl_eff2 = stale_entry ? 48'd0 : lvl_eff;
// Any write refreshes the entry's epoch to the current one.
```

Clearing a symbol's entire book is now `epoch_q[slot] <= epoch_q[slot] + 1` — **one
cycle**, no port contention, no fast-path impact. The same trick clears the order
map and the occupancy bitmap.

⚠️ **4 bits wraps after 16 resyncs.** On wrap, an entry left over from 16 epochs ago
aliases as live, and you have resurrected a phantom book. Mitigation: a background
scrubber walks the arrays at 1 entry/cycle on the *unused* RAM port, zeroing entries
whose epoch is more than 8 behind. A full sweep of 128 × 2048 = 262,144 entries takes
1.7 ms, which is 4 orders of magnitude faster than the wrap can occur. Also count
`epoch_wrap` and alarm on it.

### 9.2 The resync sequence

| Step | Owner | Action |
| --- | --- | --- |
| 1 | HW | Gap detected (04.02 §8) → `channel_stale`, `book_stale[slot] = 1` for all symbols on the channel |
| 2 | HW | Strategy and risk gate both see `book_stale` → **no orders**, immediately, 0 cycles |
| 3 | HW | Bump `epoch[slot]` for affected symbols → books read as empty |
| 4 | SW | Alarm. Decide: MoldUDP64 re-request (small gap) or Glimpse snapshot (large gap) |
| 5 | SW | Fetch recovery data, feed it into the FPGA as synthetic `book_cmd`s over the parameter DMA path (**not** through the RX pipeline — see below) |
| 6 | SW | Verify: hardware aggregate qty at L1 matches the software shadow book |
| 7 | SW | Clear `book_stale[slot]` — one symbol at a time, verified individually |
| 8 | HW | Trading resumes for that symbol |

⚠️ **Step 5 must not inject recovery messages into the live RX pipeline.** Recovery
data is historical; the live feed is current; interleaving them applies old deltas on
top of new state. Recovery goes through a **separate write port** on the book with
the live path held off for that symbol (it is stale, so nothing is trading on it),
and the CPU replays the gap range *then* the buffered live range in order. This is
the one place where the book has a second writer, and it is only ever active for
symbols that are already disabled.

⚠️ **Never clear `book_stale` globally.** Per symbol, after per-symbol verification.
A "clear all stale" register write is a foot-gun that will eventually be used at 3
a.m. by someone trying to get trading back up.

### 9.3 Orders resting from before the gap

After a Glimpse snapshot you have aggregate levels but *not* individual order
references. The order map cannot be reconstructed from an aggregate snapshot.
Consequence: after a snapshot resync, deletes for pre-snapshot orders will **miss**
in the order map.

Policy: a miss on `E`/`X`/`D` is counted (`omap_miss`) and the update is **not
applied** — because you do not know what to subtract. If `omap_miss` for a symbol
exceeds a threshold within a window, re-stale and resync again. The rate should decay
to zero within seconds as pre-snapshot orders age out.

⚠️ Applying a delete with a *guessed* quantity is never acceptable. A miss is
information; a guess is corruption.

---

## 10. `book_stale` and its propagation

`book_stale` is a per-symbol bit, and it is an input to **three** independent
consumers, deliberately:

```
                          ┌──────────────────────────────────┐
   gap detect ────┐       │                                  │
   omap overflow ─┤       │   book_stale[slot]  (sticky)     │
   subpenny ──────┼──────▶│   cleared only by explicit,      │
   out-of-window ─┤       │   per-symbol CPU register write  │
   epoch wrap ────┤       │                                  │
   level underflow┘       └───┬─────────────┬─────────────┬──┘
                              │             │             │
                     ┌────────▼───┐  ┌──────▼──────┐  ┌───▼────────┐
                     │ bbo_upd    │  │ strategy    │  │ risk_gate  │
                     │ .stale bit │  │ gating (S0) │  │ T0 gate    │
                     └────────────┘  └─────────────┘  └────────────┘
```

Why three consumers and not one:

1. **`bbo_upd.stale`** — the published book carries its own validity. Anything that
   consumes the book downstream (including telemetry and the host) sees it.
2. **Strategy gating (S0)** — the strategy does not fire. This is the normal path.
3. **Risk gate (T0)** — the risk gate *independently* refuses to pass an order for a
   stale symbol. This is defence in depth: if the strategy has a bug and fires
   anyway, the order still does not reach the wire.

⚠️ Consumer 3 is not redundant, it is the point. A single gate is a single point of
failure, and the failure mode is "traded on a book we knew was wrong". Both gates
are single-cycle AND terms against precomputed bits, so the duplication costs
**zero** latency. See [05-order-gateway-and-pre-trade-risk.md](05-order-gateway-and-pre-trade-risk.md) §3.

`book_stale` is **sticky**. It sets in hardware and clears only via a per-symbol
register write from the CPU. Hardware never decides on its own that things look fine
again.

---

## 11. Book latency budget (rows B0–B4)

| Row | Stage | Module | Cycles | ns | Cum. ns | Notes |
| --- | --- | --- | ---: | ---: | ---: | --- |
| B0 | CRC-32C hash of `order_ref` → set index | `order_map_hash` | 1 | 6.4 | 6.4 | fixed; skipped for non-order messages |
| B1 | Order map: 4-way read, full key compare, way select, overflow compare | `order_map` | 1 | 6.4 | 12.8 | +2 on overflow-region insert path (J3) |
| B2 | Level address form + level array read + occupancy read | `level_array` | 1 | 6.4 | 19.2 | fixed; level index already computed at R4 |
| B3 | Level RMW + write-forwarding bypass + writeback | `level_rmw` | 1 | 6.4 | 25.6 | fixed; **never stalls** (§8) |
| B4 | Top-of-book incremental update, second-best maintenance, `bbo_upd` publish | `tob_track` | 1 | 6.4 | 32.0 | +2 on best-emptying delete with cache miss (J4) |
| | **Book total** | | **5** | **32.0** | | |
| | *worst case (`U` + overflow + rescan)* | | *10* | *64.0* | | bounded, counted |

**Per-message-type cycle cost:**

| ITCH | B0 | B1 | B2 | B3 | B4 | Total | Notes |
| --- | :-: | :-: | :-: | :-: | :-: | ---: | --- |
| `A`/`F` Add | ✓ | insert | ✓ | ✓ | ✓ | 5 | no rescan possible |
| `E`/`C` Executed | ✓ | read | ✓ | ✓ | ✓ | 5 (+2) | rescan if best empties |
| `X` Cancel | ✓ | read+upd | ✓ | ✓ | ✓ | 5 (+2) | |
| `D` Delete | ✓ | read+del | ✓ | ✓ | ✓ | 5 (+2) | most common rescan trigger |
| `U` Replace | ✓ | del + ins | ✓✓ | ✓✓ | ✓ | 6 (+2) | two `book_cmd`s at II=1 |
| `H`/`S`/`Y` | — | — | — | — | gating only | 1 | off the book path entirely |

**Resource estimate (unmeasured, pre-synthesis):**

| Module | LUT | FF | BRAM36 | URAM |
| --- | ---: | ---: | ---: | ---: |
| `order_map_hash` (CRC-32C, 64→32) | ~220 | ~40 | 0 | 0 |
| `order_map` (4-way + overflow CAM) | ~2,600 | ~1,400 | 0 | 32 |
| `level_array` + `level_rmw` | ~900 | ~600 | 0 | 59 |
| `occupancy_bmap` + 256-bit prio enc | ~800 | ~350 | 0 | 1 |
| `tob_track` (incl. second-best cache) | ~1,500 | ~900 | 1 | 0 |
| `book_epoch` + scrubber | ~300 | ~250 | 0 | 0 |

---

## 12. Verification: what must be proven

The book cannot be validated by inspection. It is validated against an oracle.

| Test | Method | Asserts |
| --- | --- | --- |
| **Full-day replay vs. golden model** | Python order-book model fed the same pcap; compare L1/L2/L3 after **every single message** | exact match on `{bid_lvl, bid_qty, bid_cnt, ask_*}`, every message, all day |
| **RMW hazard** | Directed: N back-to-back updates to one level, N = 1..8, every op pairing | aggregate qty exactly correct; no drift |
| **Second-best cache** | Directed: build a 5-level book, delete the best, add between best and second, delete again, in every ordering | published best always equals the golden model's best |
| **Rescan boundary** | Best at level 0, 255, 256, 2047 of the bitmap word; empty word; two empty words | correct new best or correct `bid_valid=0`; never out of bounds |
| **Order map saturation** | Fill a set to 4 ways + overflow, then one more | `book_stale` set; **no eviction**; no wrong-order delete |
| **Epoch** | Resync 17 times to force wrap | scrubber prevents aliasing; `epoch_wrap` counted |
| **`U` semantics** | Replace, then delete by *old* ref and by *new* ref | old ref misses (counted), new ref hits and applies |
| **Sub-penny injection** | Inject a price with non-zero cents remainder | `subpenny_seen`, symbol staled, **update not applied** |
| **Out-of-window** | Price beyond `base ± window` | counted, not wrapped, symbol staled at threshold |
| **Underflow** | Delete more than is resting | saturates at 0, `level_underflow` counted, assertion fires in sim |
| **Latency assertion** | every `book_cmd` | `bbo_upd` at exactly `LATENCY_CYCLES` after, or `LATENCY_CYCLES+2` with `rescan` flagged — never anything else |

⚠️ "Compare at the end of the run" is not sufficient. Two errors can cancel. Compare
**after every message**, and stop on the first divergence with the message index —
that index is the whole debugging session.

---

## Further reading

- [01-tick-to-trade-pipeline.md](01-tick-to-trade-pipeline.md) — rows B0–B4 in the master budget
- [02-feed-handler-design.md](02-feed-handler-design.md) — the producer of `book_cmd`
- [04-strategy-engine-on-fpga.md](04-strategy-engine-on-fpga.md) — the consumer of `bbo_upd`
- [05-order-gateway-and-pre-trade-risk.md](05-order-gateway-and-pre-trade-risk.md) — the second `book_stale` gate
- [../01-fpga-design/03-memory-and-storage.md](../01-fpga-design/03-memory-and-storage.md) — BRAM/URAM, hash tables, banking
- [../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) — why reduction trees are off the fast path
- [../03-algotrading/01-market-microstructure.md](../03-algotrading/01-market-microstructure.md) — what a limit order book *is*
- [../08-nasdaq/](../08-nasdaq/) — ITCH 5.0 order-message semantics, Glimpse recovery
