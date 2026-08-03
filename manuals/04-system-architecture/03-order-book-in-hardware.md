# 04.03 — Order Book in Hardware

> **Why this matters here:** this is the hardest design problem in the system. It
> owns rows **B0–B4** — 5 cycles, 32.0 ns — and it is the only block that holds
> megabytes of mutable state that must be *exactly* right. A feed handler bug drops
> a message and you notice. A book bug corrupts a quantity by 100 shares and you
> trade against a book that does not exist, profitably, for weeks, until you don't.

> **Second edition.** An external FPGA architecture review found that the order map
> specified by the first edition of this document **overflows at 12.5 % load** and that
> its overflow region was undersized by two orders of magnitude. The map design in §2
> has been replaced with bucketed cuckoo hashing. §2.3 keeps the failed arithmetic
> visible rather than deleting it, because the failure is the reason for the redesign.
> The full analysis is [`docs/ORDER-BOOK-REDESIGN.md`](../../docs/ORDER-BOOK-REDESIGN.md);
> the change log is the [Revision history](#revision-history) at the end of this document.

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
        │  order_ref (64-bit, sparse)  →  {sym, side, price, qty}          │
        │  Bucketed cuckoo, d=2 hashes × b=4 slots, + 16-entry stash. §2   │
        │  Written on Add. Read on Exec/Cxl/Del.                           │
        │  Purpose: recover what an order *was*.                           │
        └───────────────────────────┬──────────────────────────────────────┘
                                    │ yields (slot, side, level, delta)
                                    ▼
        ┌──────────────────────────────────────────────────────────────────┐
        │  STRUCTURE 2 — LEVEL ARRAY                                        │
        │  (slot, level)  →  {aggregate_qty, order_count, epoch}           │
        │  N_SYMBOLS × 2048 ticks.  Read-modify-write on every update.     │
        │  Purpose: answer "how much is at this price".                    │
        └───────────────────────────┬──────────────────────────────────────┘
                                    │
                                    ▼
        ┌──────────────────────────────────────────────────────────────────┐
        │  STRUCTURE 3 (derived) — TOP OF BOOK                             │
        │  slot → {bid_lvl, bid_px, bid_qty, ask_lvl, ask_px, ask_qty}     │
        │  Maintained INCREMENTALLY. Never recomputed. §6.                 │
        └──────────────────────────────────────────────────────────────────┘
```

The two structures are bound by one invariant, and every correctness argument in this
document rests on it:

> **Population invariant.** An order is present in the order map **if and only if** its
> quantity is present in the level array. Neither structure may hold an order the other
> does not. §2.7.

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
  Across our filtered universe, fewer — but **how many fewer is a measurement, not an
  estimate**, and the first edition of this document guessed. See §2.8.

### 2.2 The arithmetic

| Quantity | Value | Source |
| --- | ---: | --- |
| Nasdaq-listed + traded securities on TotalView | ~9,000 | reference data |
| Our subscribed universe `N_ACTIVE` | **128–256** | design choice, may shrink — §2.8 |
| Typical live resting orders per active symbol | 200–2,000 | estimate, measure yours |
| Peak live orders per symbol (open/close, high-activity name) | ~8,000 | estimate |
| ⇒ Peak live orders in our universe | 128 × 8,000 = **1,024,000** worst case | |
| ⇒ Realistic p99 | 128 × 800 = **102,400** | |

> **Verify:** these per-symbol depth figures are estimates. Derive yours by replaying
> a full day of TotalView pcap through the Python golden model and histogramming the
> live-order count per symbol ([`tools/pcap/stats.py`](../../tools/pcap/stats.py)). Do
> this **before** sizing the memory; it is a one-afternoon job and it determines a URAM
> budget you cannot change without a rebuild.

⚠️ Note the ratio between the last two rows. A 10× spread between the p99 and the
worst case is not a rounding error — it is the difference between a table that fits in
one SLR and one that does not. §2.8 is where this is resolved, and it is resolved by
measurement.

### 2.3 The design: bucketed cuckoo, `d = 2` hashes × `b = 4` slots

#### 2.3.1 What the first edition specified, and why it fails

The first edition specified a **4-way set-associative table, 16,384 sets, 65,536
entries**, with a 64-entry overflow region. That design does not survive contact with
the load it was sized for. Records hash uniformly into `S` sets of `W` ways; per-set
occupancy is `Binomial(n, 1/S)`, well approximated by `Poisson(λ)` with `λ = n/S`:

```
P(set overflows)          = P(X > W) = 1 − Σ_{k=0}^{W} e^(−λ) λ^k / k!
E[excess records per set] = Σ_{k>W} (k − W) · e^(−λ) λ^k / k!
E[total excess]           = S × E[excess per set]      ← this sizes the overflow region
```

For `S = 16,384`, `W = 4`:

| Live orders | Load | P(a given set > 4) | Expected overflowing sets |
| ---: | ---: | ---: | ---: |
| 4,096 | 6.2 % | 6.6 × 10⁻⁶ | 0.11 |
| 8,192 | 12.5 % | 1.7 × 10⁻⁴ | **2.8** |
| 16,384 | 25.0 % | 3.7 × 10⁻³ | **60** |
| 32,768 | 50.0 % | 5.3 × 10⁻² | **863** |
| 65,536 | 100 % | 3.7 × 10⁻¹ | **6,081** |

**Read the 12.5 % row.** At one-eighth of nominal capacity — 8,192 live orders across
the whole universe, which a single active name can carry on its own — roughly three
sets are already over capacity. The table is not "getting full". It is *failing*, while
seven-eighths empty.

The measured 65,536-entry table therefore has an **effective capacity of roughly 8,000
orders**. At 128 symbols that is **62 live orders per symbol**. One liquid name carries
far more than that before the opening auction has finished printing.

⚠️ This is the general shape of the mistake, and it is worth naming: *a set-associative
table's capacity is not `sets × ways`.* It is the load at which the tail of the
occupancy distribution stops fitting, and for `W = 4` that load is about **0.25**, not
1.0. Sizing a hash table by its slot count is the hash-table equivalent of sizing a
FIFO by its depth and ignoring the arrival process.

The corresponding overflow-region arithmetic is in §2.5. Both tables are reproduced
here rather than deleted because a reviewer who has read the first edition needs to see
*why* it changed, and because the same arithmetic is what will size the replacement.

#### 2.3.2 The replacement

```
key ──┬─► h0(key) ─► bucket A (4 slots) ──┐
      │                                    ├─► 8 full-key compares ─► hit / miss
      └─► h1(key) ─► bucket B (4 slots) ──┘        (1 cycle, worst case)
                                    │
                     stash (16-entry CAM, parallel) ─┘
```

Every key has exactly **two** candidate buckets, each holding **four** slots. A lookup
reads both buckets in parallel and compares all eight resident keys at once.

| Parameter | Value | Rationale |
| --- | --- | --- |
| `d` (hash functions) | **2** | Two independent memory instances; two parallel reads |
| `b` (slots per bucket) | **4** | 4 × 140 bits is one URAM row group; 8 slots doubles the compare width for +2 % load factor |
| `MAX_KICKS` | **16** | Bounds the relocation chain — §2.3.4 |
| Stash | **16 entries** | Fully associative, LUTRAM + comparators — §2.5 |
| Entry width | **~140 bits** | `{valid, key[63:0], sym, side, price[31:0], qty[31:0]}` |
| Design load target | **≤ 0.90** | Well inside the 0.976 threshold; the margin is the stash's safety factor |

Published load thresholds for bucketed cuckoo — the load factor at which insertion
begins to fail:

| Configuration | Max load |
| --- | ---: |
| `d = 2`, `b = 1` | 0.50 |
| `d = 2`, `b = 2` | 0.897 |
| **`d = 2`, `b = 4`** | **0.976** |
| `d = 2`, `b = 8` | 0.996 |

> **Verify:** these thresholds are published results, not measurements of this design.
> `d = 2, b = 1` is **Pagh & Rodler, "Cuckoo Hashing" (2001)**; the bucketed figures are
> from **Erlingsson, Manasse & McSherry (2006)** and **Dietzfelbinger & Weidling**. Take
> the numbers from the papers before you commit URAM to them, and re-measure the
> achieved load in the R7 stress test rather than assuming the asymptotic figure holds
> at our table size.

Compare against the design it replaces, which fails at 0.125: **roughly a 7×
improvement in usable capacity for identical memory.** Nothing was bought with area.
It was bought with a second hash function.

#### 2.3.3 Lookup: O(1) *worst case*, and why the "worst" matters more than the "O(1)"

A cuckoo lookup is exactly two bucket reads and eight comparators. Not on average —
**every time, for every key, hit or miss.** There is no probe sequence, no chain to
walk, no data-dependent second access.

That property, and not the average lookup cost, is what qualifies the structure:

| Structure | Average lookup | Worst-case lookup | Admissible on a fixed-latency pipeline? |
| --- | --- | --- | --- |
| Linear probing | ~1.5 probes at α = 0.5 | unbounded (whole table) | **No** |
| Chaining | ~1.2 hops | unbounded (chain length) | **No** |
| 4-way set-assoc + overflow CAM | 1 read | 1 read | Yes — but capacity fails first (§2.3.1) |
| **Cuckoo `d=2`, `b=4`** | **2 parallel reads** | **2 parallel reads** | **Yes — chosen** |

⚠️ **A pipeline stage has one duration, and it is the worst one.** A pipeline is not a
queue: stage B1 is allotted 6.4 ns of wall clock, and a structure whose lookup
*sometimes* needs a second dependent access does not "average out" — it either stalls
the pipeline (which propagates backwards into the feed handler and creates the largest
jitter source in the system, [../09-deep-dives/07-jitter-sources-and-determinism.md](../09-deep-dives/07-jitter-sources-and-determinism.md))
or it forces every message to be budgeted at the worst case anyway, in which case the
good average bought nothing. Average-case data structures are for systems that can
absorb variance in a queue. This one publishes a quote.

Linear probing and chaining are therefore **disqualified on their latency distribution,
irrespective of how good their average is**. That is the whole argument, and it is not
a close call.

#### 2.3.4 Insert: bounded relocation, then stash, then — and only then — stale

```
insert(key, rec):
    if h0(key) bucket has a free slot   → place it.          done, 1 cycle
    if h1(key) bucket has a free slot   → place it.          done, 1 cycle
    otherwise:
        victim ← pick a resident of one bucket
        move victim to ITS alternate bucket                  ← relocation, not eviction
        repeat with the displaced record, up to MAX_KICKS = 16
    if the chain did not terminate      → put the record in the STASH (§2.5)
    if the stash is full                → book_stale for that symbol (§10)
```

**Delete:** locate the entry in one of the two buckets or the stash, invalidate it. No
relocation is ever needed on a delete.

⚠️ **The relocation chain is real work and it is the honest cost of this structure.** A
chain of length `k` is `k` read-modify-writes on the map memories. At our design load
the overwhelming majority of inserts find a free slot immediately and cost one cycle —
but "overwhelming majority" is an average, and §2.3.3 has just finished arguing that
averages do not size a pipeline stage. The reconciliation is that **relocation is
off the lookup path**: kicks are drained on the map's write port while lookups continue
against the read ports, and a lookup issued while a record is in flight must also
compare against the in-flight victim register and the stash. This is the single most
intricate part of the block and R7 must measure the kick-chain length distribution
rather than assume it.

> **Verify:** [../09-deep-dives/05-hash-tables-and-lookup-structures.md](../09-deep-dives/05-hash-tables-and-lookup-structures.md)
> §6 **rejects** cuckoo for exactly this reason and recommends d-left instead. That
> analysis predates the architecture review and is superseded *for the order map* by
> this section, on the ground that the capacity failure in §2.3.1 is fatal and the
> insert-path cost is bounded. The deep-dive has not yet been revised and its §6 verdict
> row and §12 rule 11 currently contradict this document. Read both before changing
> either.

#### 2.3.5 The two hash functions must actually be two

`h0` and `h1` must be **independent**. This is not a stylistic preference:

```systemverilog
// rtl/book/order_id_map.sv — the hash pair.
// CRC-32C over the 64-bit reference, two different generator seeds / polynomials.
// XOR tree, 1 cycle, ~200 LUT each.
wire [MAP_BKT_W-1:0] h0 = crc32c_a(req_key)[MAP_BKT_W-1:0];
wire [MAP_BKT_W-1:0] h1 = crc32c_b(req_key)[MAP_BKT_W-1:0];
```

⚠️ **`h1` must not be a trivial transform of `h0`.** The tempting shortcuts —
`h1 = ~h0`, `h1 = h0 ^ constant`, `h1 = h0 + 1`, `h1 = bit_reverse(h0)` — all produce a
fixed permutation of buckets. Under such a scheme the buckets partition into disjoint
pairs, every key that lands in bucket `A` has the *same* alternate bucket as every other
key in `A`, and the table degenerates: a pair of full buckets can never be relieved by
relocation because there is nowhere else for anything to go. The achievable load factor
collapses from 0.976 back toward single-hash behaviour, and it does so silently — the
table simply starts stashing early, which looks like "we undersized it" rather than
"the hashes are correlated".

The correct construction is two genuinely different reductions of the key: two CRC
polynomials, or one CRC of the key and one of a keyed permutation of it. **Test for it:**
the R7 stress test should assert that the measured achieved load at first insertion
failure is within a stated tolerance of the published threshold. A correlated pair fails
that assertion immediately; nothing else will catch it.

#### 2.3.6 ⚠️ Store the full 64-bit key. Never a tag.

The tempting optimisation is a 16- or 32-bit tag from a second hash, saving roughly half
the map memory. **Do not.** In *cuckoo filters* this is standard and correct, because a
filter is allowed to answer "probably present" — a false positive costs a wasted lookup
elsewhere and nothing else.

Here a tag collision is a **silent mis-attribution**: you apply a delete, or an
execution, to the wrong resting order, at the wrong price, in the wrong symbol, and
nothing anywhere reports an error. The book stays plausible and is wrong. At 32-bit tags
and 10⁹ lookups a day, false positives are a **daily event**
([../09-deep-dives/05-hash-tables-and-lookup-structures.md](../09-deep-dives/05-hash-tables-and-lookup-structures.md) §3).

The partial-key variant has a second, subtler consequence that matters specifically to
cuckoo: partial-key cuckoo derives the *alternate bucket* from the tag
(`h1 = h0 ^ hash(tag)`) precisely so that a record can be relocated without re-reading
its full key. That is what makes it cheap — and it is also §2.3.5's failure mode by
construction, since the alternate bucket is now a function of a short tag rather than of
the key. **Full keys are not an option here; they are the reason the structure is safe.**

The extra memory costs URAMs out of a budget of ~960 on a VU9P. The alternative costs a
book.

### 2.4 Eviction versus relocation — the distinction the first edition missed

The first edition stated the following rule, and **the rule is correct and stays**:

> **Never evict.** An eviction policy in an order map is a correctness bug wearing an
> optimisation costume: the evicted order still exists at the venue, you will receive
> its delete, you will not find it, and you will now have a permanent phantom at a
> price level.

What the first edition got wrong was to conclude from this that cuckoo hashing was
disqualified. It conflated two operations that share a word:

| Operation | Effect on the order | Safe? |
| --- | --- | --- |
| **Eviction (drop)** — discard an entry to make room | The order is **gone**. Its delete resolves to nothing. Its quantity is stranded in the level array forever. Every subsequent decision on that symbol is made against liquidity that is not there. | ❌ **Silent corruption. Still forbidden.** |
| **Relocation (cuckoo kick)** — move an entry to its **alternate** bucket | The order is **still present**, still findable by both of its hashes, quantity still tracked. Only its address changed. | ✅ **Lossless. This is what cuckoo does.** |

**Cuckoo hashing performs only the second.** Every item remains in the table for its
entire lifetime; the structure never discards a record to make room. The colloquial name
for the operation ("the new item *evicts* the incumbent") is where the confusion comes
from, and it is the reason a reviewer who has read the first edition of §2.4 will object
to §2.3 on first reading. The safety rule and the redesign are compatible. The first
edition simply had **no mechanism for a full bucket other than giving up**, and giving up
is what `map_stale` at 12.5 % load amounts to.

The rule, restated so that it cannot be misread again:

> **An order may be moved. An order may never be dropped.** A structure that relocates
> is admissible. A structure that discards is not, at any load, for any performance
> argument. When the structure genuinely cannot hold the record — chain exhausted, stash
> full — the correct response is `book_stale` for that symbol (§10), which is a
> *declared* loss of knowledge. Dropping a record is an *undeclared* one.

The overflow ladder, in full:

| Condition | Behaviour | Cost |
| --- | --- | --- |
| Free slot in either bucket (the common case) | Place it | 1 cycle |
| Both buckets full, chain terminates within `MAX_KICKS` | Relocate incumbents; place it | bounded, counted (`kick_chain_len`) |
| Chain exhausts `MAX_KICKS` | Place in the **stash** (§2.5) | +0 cycles on lookup |
| **Stash full** | ⚠️ **`book_stale` for that symbol.** Not "evict something". | resync (§9) |

Going stale and resyncing costs you a symbol for a few hundred milliseconds. Evicting
costs you the rest of the day and you will not notice.

### 2.5 The stash — and why 64 entries was never going to be enough

The first edition specified a 64-entry fully-associative overflow region. The
arithmetic from §2.3.1, evaluated for expected *records* rather than sets, shows the
scale of the miss:

| Live orders | Load | Expected items needing overflow | 64 entries enough? |
| ---: | ---: | ---: | :--- |
| 8,192 | 12.5 % | 3 | yes |
| 16,384 | 25 % | **71** | **no** |
| 32,768 | 50 % | **1,231** | **no** |
| 65,536 | 100 % | **12,804** | **no** |

Sixty-four entries covers the table up to somewhere around 24 % load and nowhere beyond.
⚠️ Undersizing an overflow region by two orders of magnitude is not a capacity problem,
because the region was never the capacity mechanism — it was a **safety valve sized as
if it were one**. That is the actual error, and it is worth stating plainly: the first
edition used the overflow CAM to paper over a table whose real capacity was 0.25 of its
slot count, then sized the CAM from intuition rather than from `E[total excess]`.

Under cuckoo the role changes completely. The stash is **not** the overflow capacity —
the second hash is. The stash exists only to absorb the rare insert whose relocation
chain fails to terminate within `MAX_KICKS`, which at a design load of 0.90 against a
0.976 threshold is a genuinely rare event.

| Property | Value |
| --- | --- |
| Entries | **16**, fully associative |
| Storage | 16 × 140 bits ≈ 2.2 Kbit of LUTRAM + 16 × 64-bit comparators |
| Lookup cost | **+0 cycles** — searched in parallel with both buckets at B1 |
| Insert cost | +0 cycles |
| `stash_occupancy` | monitored high-water counter |
| Full | ⚠️ `book_stale` for the symbol — §10 |

⚠️ `stash_occupancy` sustained above a low single-digit figure does **not** mean "make
the stash bigger". It means either the table is over its design load (fix: more buckets)
or `h0` and `h1` are correlated (fix: §2.3.5). Growing the stash to hide the symptom
reintroduces exactly the first edition's mistake in a new costume.

### 2.6 The software-assisted alternative, and why we reject it for the hot path

**The design:** hardware holds a small map of "orders near the touch"; a miss goes
over PCIe to the CPU, which holds the full map in DRAM.

| | Hardware map | Software-assisted |
| --- | --- | --- |
| Hit latency | 2 cycles (12.8 ns) | 2 cycles |
| Miss latency | +0 (stash, in parallel) | **~2–4 µs** PCIe round trip |
| Miss rate | ~0 | 10–40 % (you cannot predict which orders get deleted) |
| Determinism | fixed | catastrophic bimodal distribution |
| Book correctness during a miss | exact | the book is *wrong* for 4 µs, or the pipeline stalls |

A 4 µs stall on the RX path violates §1 of [02-feed-handler-design.md](02-feed-handler-design.md)
outright. **Rejected for the hot path.**

Where software assistance *is* right: **rebuilding** the map after a gap (§9),
**re-anchoring** the price window (§4), and **auditing** — the CPU maintains a shadow map
from the DMA-tapped message stream and periodically compares aggregate counts with the
hardware. A divergence is a hardware bug and should stale the symbol. That is a
genuinely valuable use of the CPU's memory capacity, off the critical path. See
[06-cpu-fpga-partitioning.md](06-cpu-fpga-partitioning.md).

### 2.7 The population invariant — what actually bounds the table

> **An order is in the order map if and only if its quantity is in the level array.**

This single sentence does three things, and it is the reason the map is sizeable at all.

**1. It bounds the population to the window, not to the venue.** The map does not have
to hold Nasdaq's live book. It holds only orders whose price fell inside the maintained
price window (§4) at the time they were added. The bound is:

```
map population  ≤  symbols × window levels × orders per level
```

not `venue live orders`. An order 400 ticks outside the window was never added to a
level, and therefore — by the invariant — must never enter the map either.

**2. It makes a delete for an untracked order a correct no-op.** If a `D`/`E`/`X`
arrives for a reference that is not in the map, the invariant guarantees its quantity is
not in the level array either, so there is nothing to subtract and doing nothing is
*exactly right*. Without the invariant, a map miss is ambiguous — it might mean "we
dropped this order and the level array is now wrong" — and the only safe response to an
ambiguous miss is to stale the symbol. The invariant converts a class of unavoidable
misses (post-snapshot orders, §9.3) from an error into an expected, countable event.

**3. It makes out-of-window handling coherent.** The out-of-window policy (§4) and the
map insert policy are the same policy, applied at two places. They cannot drift apart
because the invariant forbids it.

⚠️ **This invariant is the whole correctness argument, and it is exactly the kind of
property that holds in review and fails in silicon.** It must be *asserted in RTL* on
both paths — no map insert without a level update, no level update without a map
insert — and *proven* in the golden-model equivalence test by comparing populations after
every message, not assumed because the code looks right. §12.

### 2.8 Sizing from measured statistics, and the SLR ceiling

Capacity follows from the measured live-order population, at a design load of 0.90
against the 0.976 threshold, with a ~140-bit record:

| Live orders | Slots @ 90 % | Memory | URAM288 |
| ---: | ---: | ---: | ---: |
| 100,000 | 111,112 | 15.6 Mbit | 55 |
| 250,000 | 277,778 | 38.9 Mbit | 136 |
| 500,000 | 555,556 | 77.8 Mbit | 271 |

⚠️ **A VU9P SLR holds ~320 URAM288, and the entire fast path must fit in one SLR**
(04.01 §6 — an SLR crossing costs a pipeline register and, worse, a routing detour that
lands on the critical path). The 500,000-order configuration consumes 271 of those 320
by itself, leaving nothing for the level array's 59, the occupancy bitmap, the symbol
tables, or the strategy engine. **It does not fit.**

The consequence must be stated without hedging: **capacity is a measurement, not a
preference.** If the measured peak live-order count for the intended universe needs more
URAM than one SLR provides, the correct response is to **reduce the tracked symbol
count** until it fits — not to lower the design load, not to shrink the record, and
certainly not to hope the peak does not arrive.

> **Verify:** run [`tools/pcap/stats.py`](../../tools/pcap/stats.py) over a full-day
> TotalView capture for the intended universe and histogram the live-order count. The
> peak, not the mean, sizes the table. Take the measurement on an expiry or a
> high-volatility day; a quiet Tuesday will undersize you.

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

⚠️ **The reciprocal must be derived from `TICK_UNITS`, not written beside it.**
`TICK_RECIP = ceil(2^TICK_SHIFT / TICK_UNITS)` is an elaboration-time computation. A
hardcoded reciprocal next to a parameterised tick is a defect waiting for the day
someone sets `TICK_UNITS = 50` for a half-penny regime: the parameter changes, the
reciprocal does not, and every level index in the system is silently wrong by a factor
of two. Nothing errors.

### The window and its base

A full price range per symbol is unnecessary — a stock does not trade at $0.01 and
$400 on the same day. We keep a **bounded window**:

| Parameter | Value | Meaning |
| --- | ---: | --- |
| `N_LVL` | **2048** | levels per symbol, per side |
| Window span | **$20.48** | 2048 × $0.01 |
| `base_cents[slot]` | per-symbol, **host-written** | see below |
| Out-of-window update | counted, then **stale + re-anchor** | see below |

⚠️ **The window base is HOST-ANCHORED. It is never inferred from the feed.** At
start of day the host writes `base_cents[slot]` from the previous close (or the last
trade on restart), positioned so the reference price sits at the window centre. It is
refreshed by the host on re-anchor.

⚠️ **One base per symbol, not one per side.** The two sides of a book quote the same
instrument at the same time and are separated by a spread, not by dollars; giving bid
and ask independent bases means a level index no longer determines a price on its own,
and the top-of-book reconstruction in §6.2 becomes ambiguous about which base to use.
Levels are per side (an occupancy bitmap each, `N_LVL` each); the *base* is per symbol.

**Why auto-anchoring fails, concretely.** The tempting alternative is to anchor on the
first price observed for a side and re-anchor when that side goes empty. It has a fatal
interaction with liquidity:

1. The first price of the session anchors the window — possibly a wide pre-open quote,
   possibly a stub.
2. Re-anchoring is gated on the side being *empty*. For a liquid symbol the bid side is
   never empty during the session.
3. Therefore the window **never re-anchors**, and as the price trends away from the
   open, first the best levels and then everything falls outside it.
4. Every out-of-window update is discarded. The book stops updating. Top of book freezes
   at a stale value and nothing reports an error.

The window drifts out from under the market, and the mechanism that was supposed to
correct it is gated on a condition that a liquid symbol never satisfies. ⚠️ This is a
worked example of a fallback path that is *unreachable exactly when it is needed*: it
tests fine on a thin symbol and fails on the only symbols worth trading. Anchoring is a
**slow-path decision made from information the hardware does not have** — last trade,
previous close, auction print — and it belongs to the host.

**Out-of-window policy.** A price outside `[base, base + 2048)` means the stock has
moved more than $20.48 from the base, or the message is garbage. Policy:

1. Count it (`level_out_of_window`). Do **not** wrap the index (⚠️ wrapping aliases a
   $30 price onto a $10 level — silent corruption, the worst kind).
2. Do **not** silently discard it either. A discarded update breaks the population
   invariant (§2.7) the moment the same order's delete arrives.
3. On exceeding a small threshold: **stale the symbol** (§10), signal the host to
   re-anchor `base_cents`, and resync (§9). Per symbol, never globally.
4. Re-anchoring is a slow-path operation. It takes milliseconds. It happens a handful
   of times a day for a volatile name. That is acceptable; hardware re-centring
   would require a full array shift and is not.

⚠️ For a name that gaps at the open, the window will be wrong until re-anchored. The
host should re-anchor off the opening auction print **before** enabling trading in that
symbol, not after the first out-of-window counter trips.

⚠️ **A window narrower than 2048 levels is not a tuning choice, it is a different
design.** At 16 levels the window is **$0.16** wide. A symbol that moves eight cents
from its anchor has left it entirely. See §13 for what this looked like in practice.

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

The record is ~140 bits, not 128: the map stores the **full price**, not a level index.

⚠️ That choice is deliberate and it is a consequence of §4. A stored level index is only
meaningful relative to a particular `base_cents`, so a host re-anchor would invalidate
every level index in the map at once. Storing the price makes the record independent of
the window base, and the level is recomputed from `(price − base)` on lookup with the
same reciprocal multiply the feed handler already uses. Twelve bits per entry is a
cheap price for removing an entire class of re-anchor bug.

```
sized from measurement (§2.8) — at 100,000 live orders:
111,112 slots × 140 bits = 15.6 Mbit = 55 URAM288  (2 memories × 4 slots wide)
```

### Top of book

```
128 × 160 bits = 20.5 Kbit → LUTRAM / 1 BRAM36 (dual-ported: fast path A, telemetry B)
```

### Totals

At the 100,000-live-order map sizing:

| Structure | Mbit | URAM288 | BRAM36 |
| --- | ---: | ---: | ---: |
| Order map (cuckoo, 111k slots @ 90 %) | 15.6 | 55 | — |
| Order map stash (16 entries) | 0.002 | — | LUTRAM |
| Level array | 16.78 | 59 | — |
| Occupancy bitmap | 0.26 | 1 | — |
| Top of book | 0.02 | — | 1 |
| Symbol tables (from 04.02) | 0.83 | 3 | 2 |
| **Total** | **33.5** | **118** | **3** |

On a VU9P (960 URAM288, 2160 BRAM36) that is ~12 % of URAM. ⚠️ But the binding
constraint is not the device, it is the **SLR: 320 URAM288**, and the whole fast path
must sit in one (04.01 §6). At 118 there is headroom. The table below is where it runs
out.

### Scaling table

| `N_SYMBOLS` | `N_LVL` | Level array | Map (live orders) | URAM total | Fits one SLR? |
| ---: | ---: | ---: | ---: | ---: | --- |
| 128 | 1024 | 8.4 Mbit | 15.6 Mbit (100k) | 88 | yes |
| **128** | **2048** | **16.8 Mbit** | **15.6 Mbit (100k)** | **118** | **yes — chosen** |
| 128 | 2048 | 16.8 Mbit | 38.9 Mbit (250k) | 199 | yes |
| 256 | 2048 | 33.6 Mbit | 38.9 Mbit (250k) | 258 | yes, tight |
| 256 | 2048 | 33.6 Mbit | 77.8 Mbit (500k) | 393 | **no** — exceeds 320 |
| 512 | 2048 | 67.1 Mbit | 38.9 Mbit (250k) | 376 | **no** — exceeds 320 |

⚠️ Read this table as the **budget for the trade-off in §2.8**, not as a menu. The map
column is a measured quantity; the symbol column is the free variable. If the
measurement lands in the 500k row, symbols come down.

---

## 6. Top of book, maintained incrementally

### 6.1 Why incremental

Recomputing the best bid over 2048 levels is a 2048-wide priority encode. Even as a
pipelined tree that is `⌈log₂ 2048⌉ = 11` cycles = 70.4 ns —
[../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) §6 —
which is more than double our entire book budget. So the best is a **register that we
maintain**, and the only question is what each message type does to it.

⚠️ When a rescan *is* required (§6.3), the encode over a 2048-bit occupancy vector must
be **hierarchical**, not flat. A flat 2048-input priority encoder is a single enormous
combinational cone: it will either fail timing at 156.25 MHz or be retimed by the tools
into a depth you did not choose. The sanctioned structure is
[`rtl/common/prio_encoder.sv`](../../rtl/common/prio_encoder.sv) with `GROUP ≈ √N`:

```
N = 2048, GROUP = 32:
  Level 1 : 64 independent 32-wide encoders, in parallel      → 64 group-hit bits + 64 sub-indices
  Level 2 : one 64-wide encoder over the group-hit vector     → group index
  Result  : {group_index[5:0], sub_index[4:0]}                → 11-bit level index
```

Two levels of ~32-wide logic instead of one level of 2048-wide. `GROUP = √N` balances
the two levels; a much smaller `GROUP` (say 8) yields 256 groups and pushes the whole
problem into level 2, which defeats the purpose.

### 6.2 The update rules

State per symbol: `bid_lvl`, `bid_px`, `bid_qty`, `bid_cnt`, `ask_lvl`, `ask_px`,
`ask_qty`, `ask_cnt`. (`bid_lvl` higher = better bid; `ask_lvl` lower = better ask.)

⚠️ **`bid_px` is not stored state that can be assigned independently — it is a
reconstruction, and it must be recomputed from the level index on every best change:**

```systemverilog
// rtl/book/top_of_book.sv — on ANY change to best_lvl, the price follows it.
// There is exactly one correct value and it is a function of the level index.
best_lvl_q[sym][side] <= new_best_lvl;
best_px_q [sym][side] <= base_cents_q[sym] + (new_best_lvl * TICK_UNITS);
best_qty_q[sym][side] <= lvl_qty_from_array;      // the TRUE quantity, read back
```

Assigning `'0` to the price or the quantity on a best change is not a placeholder that
someone will fill in later. It publishes a **bid of $0.00** to the strategy engine and
the risk gate, on the most common event in an active book. §13.

| ITCH | Order map | Level array | Top of book | Cost |
| --- | --- | --- | --- | ---: |
| `A` / `F` Add | **insert** `ref → {sym, side, price, qty}` | `qty[lvl] += shares`; `cnt[lvl] += 1`; `bmap[lvl] = 1` | bid: `lvl > bid_lvl` → **new best** (`bid_lvl=lvl`, `bid_px=base+lvl×tick`, `bid_qty=shares`, `bid_cnt=1`); `lvl == bid_lvl` → `bid_qty += shares`, `bid_cnt += 1`; else no change | 5 cyc |
| `E` Executed | **read**, `qty -= exec`; if 0 → **delete** | `qty[lvl] -= exec`; if 0 → `cnt -= 1`, and if `cnt==0` → `bmap[lvl]=0` | if `lvl == best` → `best_qty -= exec`; if `best_qty == 0` → **RESCAN**, then reconstruct `best_px` | 5 cyc (+2) |
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
> [../08-nasdaq/04-totalview-itch-5.0.md](../08-nasdaq/04-totalview-itch-5.0.md) and both
> are the kind of detail that a plausible mental model gets wrong.

### 6.3 ⚠️ The one operation that is not O(1)

**Deleting the last order at the current best price.** The new best is the
next-highest occupied bid level, and finding it is a search.

Three mitigations, used together:

**(a) Occupancy bitmap + bounded hierarchical priority encode.** `bmap[slot]` is 2048
bits stored as 8 words of 256 bits. On a best-emptying delete:

```systemverilog
// rtl/book/occupancy_bmap.sv — the rescan path. +2 cycles (J4).
// Cycle 1: read the 256-bit word containing the old best, mask off levels
//          at-or-above it, priority-encode down (hierarchical, §6.1).
// Cycle 2: if that word is now empty, read the adjacent word and encode.
//          Bounded at TWO words = 512 ticks = $5.12 below the old best.
logic [255:0] w0, w1, masked;
assign masked  = w0 & ((256'd1 << old_best[7:0]) - 1);      // strictly below
assign hit0    = |masked;
assign new_lvl = hit0 ? {old_best[10:8], prio_enc_msb(masked)}
                      : {old_best[10:8] - 3'd1, prio_enc_msb(w1)};
// ⚠️ and then, unconditionally:
//    new_px = window_base + new_lvl * TICK_UNITS;   new_qty = lvl_array[new_lvl].qty;
```

- Cost: **+2 cycles = 12.8 ns**. Bounded. Counted (`rescan_cnt`).
- If both words are empty: the side is empty within $5.12 of the old touch. Publish
  `bid_valid = 0` and let the strategy gate on it. Do **not** search further — an
  unbounded search on the fast path is forbidden (04.01 §5).

**(b) Cached second best.** Maintain `bid2_lvl`/`bid2_px`/`bid2_qty` alongside the best,
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
single highest-value unit test in the book (§12).

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

So the design decouples the two: the level array holds **2048 per side**, `tob_track`
publishes `bbo_upd` with **top-3 per side** (level index, price, aggregate qty, order
count).

⚠️ **These are independent numbers and cutting the first to match the second is a
category error.** The published depth is a bandwidth decision. The maintained depth is
the price range over which the book remains correct at all. A 16-level array does not
publish less; it stops working once the symbol moves sixteen cents. §4, §13.

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

Publishing 3 levels costs ~200 bits of `bbo_upd` and nothing in latency. Publishing 10
costs ~600 bits of routing across the SLR for a signal the trigger logic does not
consume in the same cycle. **Publish 3, maintain 2048.** If a strategy needs more depth,
it is a slow signal and it belongs in the parameter table.

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
hit the same bucket pair. The map needs the identical bypass on its write ports — now
on **both** memories, and additionally against the in-flight relocation victim (§2.3.4).

⚠️ **Write-back skew is the way this bypass is actually got wrong.** If the write-enable
and write-address signals are assigned with **non-blocking** assignments inside the
compare stage's `always_ff`, and then consumed by a *separate* `always_ff` that performs
the memory write, that second block sees the **previous** cycle's values. The write
lands one cycle later than the forwarding comparison assumes, and the bypass silently
covers the wrong cycle. The comparison logic looks correct in isolation; the defect is
in the handoff between two blocks. **Derive the bypass from a cycle-accurate timing
diagram, not from reading the two blocks separately**, and assert it in simulation with
a directed back-to-back-same-key test.

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
map (both buckets and the stash) and the occupancy bitmap.

⚠️ The epoch clear is what keeps the population invariant (§2.7) true across a resync:
it must bump **both** structures, in the same cycle, from the same signal. An epoch that
clears the level array but not the map leaves orphaned map entries whose deletes will
later subtract from a level that no longer knows about them.

⚠️ **4 bits wraps after 16 resyncs.** On wrap, an entry left over from 16 epochs ago
aliases as live, and you have resurrected a phantom book. Mitigation: a background
scrubber walks the arrays at 1 entry/cycle on the *unused* RAM port, zeroing entries
whose epoch is more than 8 behind. A full sweep of 128 × 2048 = 262,144 entries takes
1.7 ms, which is 4 orders of magnitude faster than the wrap can occur. Also count
`epoch_wrap` and alarm on it.

### 9.2 The resync sequence

| Step | Owner | Action |
| --- | --- | --- |
| 1 | HW | Gap detected (04.02 §8), stash full, out-of-window threshold, or sub-penny → `book_stale[slot] = 1` |
| 2 | HW | Strategy and risk gate both see `book_stale` → **no orders**, immediately, 0 cycles |
| 3 | HW | Bump `epoch[slot]` for affected symbols → books read as empty |
| 4 | SW | Alarm. Decide: MoldUDP64 re-request (small gap) or Glimpse snapshot (large gap). **If the cause was out-of-window, also compute a new `base_cents`** (§4) |
| 5 | SW | Write the new window base if re-anchoring, then feed recovery data into the FPGA as synthetic `book_cmd`s over the parameter DMA path (**not** through the RX pipeline — see below) |
| 6 | SW | Verify: hardware aggregate qty at L1 matches the software shadow book, **and** hardware map population matches shadow map population (§2.7) |
| 7 | SW | Clear `book_stale[slot]` — one symbol at a time, verified individually |
| 8 | HW | Trading resumes for that symbol |

⚠️ **Step 5 must not inject recovery messages into the live RX pipeline.** Recovery
data is historical; the live feed is current; interleaving them applies old deltas on
top of new state. Recovery goes through a **separate write port** on the book with
the live path held off for that symbol (it is stale, so nothing is trading on it),
and the CPU replays the gap range *then* the buffered live range in order. This is
the one place where the book has a second writer, and it is only ever active for
symbols that are already disabled.

⚠️ **The window base must be written before the replay begins**, not during it. A
re-anchor mid-replay maps the first half of the recovery stream to one set of level
indices and the second half to another.

⚠️ **Never clear `book_stale` globally.** Per symbol, after per-symbol verification.
A "clear all stale" register write is a foot-gun that will eventually be used at 3
a.m. by someone trying to get trading back up.

### 9.3 Orders resting from before the gap

After a Glimpse snapshot you have aggregate levels but *not* individual order
references. The order map cannot be reconstructed from an aggregate snapshot.
Consequence: after a snapshot resync, deletes for pre-snapshot orders will **miss**
in the order map.

Policy: a miss on `E`/`X`/`D` is counted (`omap_miss`) and the update is **not
applied** — because you do not know what to subtract. By the population invariant
(§2.7) this is not merely the safe choice, it is the *correct* one: an order absent from
the map is, by the invariant, absent from the level array, so a no-op leaves both
structures consistent. If `omap_miss` for a symbol exceeds a threshold within a window,
re-stale and resync again. The rate should decay to zero within seconds as pre-snapshot
orders age out.

⚠️ Applying a delete with a *guessed* quantity is never acceptable. A miss is
information; a guess is corruption.

---

## 10. `book_stale` and its propagation

`book_stale` is a per-symbol bit, and it is an input to **three** independent
consumers, deliberately:

```
                          ┌──────────────────────────────────┐
   gap detect ────┐       │                                  │
   stash full ────┤       │   book_stale[slot]  (sticky)     │
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

⚠️ Note what is **not** in the trigger list: "map full". Under the first edition, a
single full 4-way set raised a permanent, *global* map-stale — which at 12.5 % load meant
the book died within milliseconds of the open and never recovered. Staleness is
**per symbol** and it is a declared, recoverable state, not a terminal one.

---

## 11. Book latency budget (rows B0–B4)

| Row | Stage | Module | Cycles | ns | Cum. ns | Notes |
| --- | --- | --- | ---: | ---: | ---: | --- |
| B0 | `h0`/`h1` CRC-32C of `order_ref` → two bucket indices | `order_map_hash` | 1 | 6.4 | 6.4 | both hashes in parallel; skipped for non-order messages |
| B1 | Map: 2 parallel bucket reads, 8 full-key compares, stash compare, select | `order_id_map` | 1 | 6.4 | 12.8 | **fixed, worst case** — §2.3.3. Relocation is off this path |
| B2 | Level address form + level array read + occupancy read | `price_levels` | 1 | 6.4 | 19.2 | fixed; level index already computed at R4 |
| B3 | Level RMW + write-forwarding bypass + writeback | `level_rmw` | 1 | 6.4 | 25.6 | fixed; **never stalls** (§8) |
| B4 | Top-of-book incremental update, **price reconstruction**, second-best maintenance, `bbo_upd` publish | `top_of_book` | 1 | 6.4 | 32.0 | +2 on best-emptying delete with cache miss (J4) |
| | **Book total** | | **5** | **32.0** | | |
| | *worst case (`U` + rescan)* | | *8* | *51.2* | | bounded, counted |

**Per-message-type cycle cost:**

| ITCH | B0 | B1 | B2 | B3 | B4 | Total | Notes |
| --- | :-: | :-: | :-: | :-: | :-: | ---: | --- |
| `A`/`F` Add | ✓ | insert | ✓ | ✓ | ✓ | 5 | no rescan possible; relocation, if any, drains behind |
| `E`/`C` Executed | ✓ | read | ✓ | ✓ | ✓ | 5 (+2) | rescan if best empties |
| `X` Cancel | ✓ | read+upd | ✓ | ✓ | ✓ | 5 (+2) | |
| `D` Delete | ✓ | read+del | ✓ | ✓ | ✓ | 5 (+2) | most common rescan trigger |
| `U` Replace | ✓ | del + ins | ✓✓ | ✓✓ | ✓ | 6 (+2) | two `book_cmd`s at II=1 |
| `H`/`S`/`Y` | — | — | — | — | gating only | 1 | off the book path entirely |

⚠️ The lookup budget is unchanged from the first edition — cuckoo costs **nothing** on
the read path relative to 4-way set-associative, because both are "read in parallel,
compare in parallel". What changed is that the table now works. The cost is a second
memory instance, a second hash, and the relocation FSM.

**Resource estimate (unmeasured, pre-synthesis):**

| Module | LUT | FF | BRAM36 | URAM |
| --- | ---: | ---: | ---: | ---: |
| `order_map_hash` (2 × CRC-32C, 64→32) | ~440 | ~80 | 0 | 0 |
| `order_id_map` (cuckoo + stash + relocation FSM) | ~4,200 | ~2,600 | 0 | 55 |
| `price_levels` + `level_rmw` | ~900 | ~600 | 0 | 59 |
| `occupancy_bmap` + hierarchical prio enc (2048 = 64 × 32) | ~1,400 | ~500 | 0 | 1 |
| `top_of_book` (incl. second-best cache, price reconstruction) | ~1,700 | ~1,000 | 1 | 0 |
| `book_epoch` + scrubber | ~300 | ~250 | 0 | 0 |

---

## 12. Verification: what must be proven

The book cannot be validated by inspection. It is validated against an oracle.

| Test | Method | Asserts |
| --- | --- | --- |
| **Full-day replay vs. golden model** | Python order-book model fed the same pcap; compare L1/L2/L3 after **every single message** | exact match on `{bid_lvl, bid_px, bid_qty, bid_cnt, ask_*}`, every message, all day |
| **Population invariant (§2.7)** | After every message, compare map population against the count of orders reflected in the level array | equal, always, in both directions |
| **Top-of-book price reconstruction** | Build a book, delete the best level repeatedly down through several levels | `bid_px == window_base + bid_lvl × TICK_UNITS` after **every** best change; ⚠️ **never zero while `bid_valid`** |
| **Cuckoo stress** | Insert to 95 % load with random keys; measure kick-chain length distribution and stash occupancy | no lost records; achieved load within tolerance of the published threshold (catches correlated hashes, §2.3.5) |
| **Relocation is lossless** | Force a long kick chain, then look up every key inserted so far | every key still found — **no eviction**, ever (§2.4) |
| **Stash exhaustion** | Drive inserts until the stash fills | `book_stale` for the symbol; no eviction; no wrong-order delete |
| **RMW hazard** | Directed: N back-to-back updates to one level, N = 1..8, every op pairing | aggregate qty exactly correct; no drift |
| **Map write-back skew** | Directed: back-to-back messages on the same key at every pipeline offset | the second message sees the first's write; no off-by-one-cycle bypass (§8) |
| **Second-best cache** | Directed: build a 5-level book, delete the best, add between best and second, delete again, in every ordering | published best always equals the golden model's best |
| **Rescan boundary** | Best at level 0, 255, 256, 2047 of the bitmap word; empty word; two empty words | correct new best or correct `bid_valid=0`; never out of bounds |
| **Hierarchical prio encoder** | Exhaustive over 2048-bit one-hot and random multi-hot vectors | index identical to a behavioural flat encoder, all inputs |
| **Host re-anchor** | Write a new `base_cents` mid-session, replay across it | no level aliasing; map entries survive (they store price, §5) |
| **Out-of-window** | Price beyond the window, on an *occupied* side | counted, not wrapped, **not silently discarded**, symbol staled at threshold |
| **Window width** | Assert `N_LVL` at elaboration | ⚠️ build fails if `N_LVL < 2048` — §13 |
| **Epoch** | Resync 17 times to force wrap | scrubber prevents aliasing; `epoch_wrap` counted; map and level array clear together |
| **`U` semantics** | Replace, then delete by *old* ref and by *new* ref | old ref misses (counted), new ref hits and applies |
| **Sub-penny injection** | Inject a price with non-zero cents remainder | `subpenny_seen`, symbol staled, **update not applied** |
| **Tick-size reparameterisation** | Elaborate with `TICK_UNITS = 50` | level indices correct; ⚠️ catches a hardcoded reciprocal (§4) |
| **Underflow** | Delete more than is resting | saturates at 0, `level_underflow` counted, assertion fires in sim |
| **Latency assertion** | every `book_cmd` | `bbo_upd` at exactly `LATENCY_CYCLES` after, or `LATENCY_CYCLES+2` with `rescan` flagged — never anything else |

⚠️ "Compare at the end of the run" is not sufficient. Two errors can cancel. Compare
**after every message**, and stop on the first divergence with the message index —
that index is the whole debugging session.

---

## 13. Failure modes from the first implementation

Every row below was in shipped RTL. None of them produced an error message, a lint
warning, or a failing build. All of them were found by an architecture review reading
the source — which is to say, by luck and diligence rather than by process.

| Failure | What the code did | What it published | Why nothing caught it | Where the correct behaviour is specified |
| --- | --- | --- | --- | --- |
| **Top-of-book price zeroed** | Priority encoder found the correct new best *level*; the price was then assigned `'0` instead of being reconstructed | ⚠️ **bid = $0.00** after every best-level delete | No testbench had ever run. Worked example below | §6.2 |
| **16-level window** | `BOOK_LEVELS = 16` in the package; the manual specified 2048 | A **$0.16** window. Every order more than 8 ¢ from the anchor discarded | The parameter is plausible in isolation. Nothing cross-checks RTL against the manual | §4, §7 |
| **Auto-anchored window** | Anchored on the first price seen; re-anchored only when the side is empty | Window never re-anchors on a liquid name; drifts out from under the market | The fallback path is unreachable precisely on the symbols that matter | §4 |
| **Out-of-window silent discard** | Counted and dropped the update | Level array and map diverge at the next delete | Counter was non-zero but nothing gated on it | §4, §2.7 |
| **Map overflow ⇒ permanent stale** | A full 4-way set set `map_stale` sticky, with no overflow region at all | Book dies at the first collision, ~12.5 % load, milliseconds after the open | Correct-looking code; the defect is in the *sizing*, which lives in a spreadsheet nobody ran | §2.3, §2.4 |
| **Flat priority encoder** | Flat encode over the occupancy vector | Fails timing, or is retimed to an unplanned depth | Timing was never run | §6.1 |
| **Write-back skew** | `wb_*` assigned non-blocking in one `always_ff`, consumed by another | Bypass covers the wrong cycle; RMW drift under back-to-back traffic | Each block is correct read on its own | §8 |
| **Hardcoded tick reciprocal** | `TICK_RECIP` a literal beside a parameterised `TICK_UNITS` | Wrong level indices the day the tick regime changes | Correct today, wrong later, silently | §4 |
| **Dead signals** | Declared, never assigned | Nothing — but they mark logic that was planned and not written | Lint had never been run | — |

### ⚠️ Worked example: the $0.00 bid

This one deserves its full walk-through, because it is the cleanest illustration in the
project of a defect that **no amount of code review catches and one testbench catches
instantly**.

```systemverilog
// rtl/book/top_of_book.sv — as shipped.
best_lvl_q[upd_sym][side_i] <= new_best_lvl;   // ← correct: the encoder found it
best_qty_q[upd_sym][side_i] <= '0;             // ← wrong
best_px_q [upd_sym][side_i] <= '0;             // ← the bid is now $0.00
```

Trace it:

1. A book is built on AAPL. Best bid is level 1,024, `window_base = $180.00`, so
   `bid_px = $190.24`, 500 shares.
2. The last order at level 1,024 is deleted — **the single most common event in an
   active book.**
3. The rescan runs. The hierarchical encoder correctly returns `new_best_lvl = 1023`.
4. `best_lvl_q` is updated correctly. `best_px_q` is assigned zero.
5. `bbo_upd` publishes `bid_lvl = 1023`, **`bid_px = $0.00`**, `bid_qty = 0`, with
   `stale = 0` and `valid = 1`.
6. The strategy engine, correctly, sees a bid of zero against an ask of $190.25 and
   computes a spread of $190.25.

**Why review does not catch it.** Read the three lines above. They are syntactically
correct, consistently formatted, and the *hard* part — the priority encode — is right.
The eye reads "assign the new best" and moves on. The zeros look like initialisation.
There is no wrong operator, no reversed condition, no off-by-one. Nothing about the
text is suspicious.

**Why one testbench catches it in the first millisecond.** The assertion is a single
line, and it does not even need a golden model:

```systemverilog
assert property (@(posedge clk) disable iff (rst)
    (bbo_valid && bid_valid) |-> (bid_px == base_cents_q[sym] + bid_lvl * TICK_UNITS))
    else $error("top-of-book price is not a reconstruction of its level");
```

The general lesson, and the reason this section exists: **a derived value must be
derived at every assignment site, not at most of them.** `bid_px` is not state. It is a
pure function of `bid_lvl` and `window_base`. Anywhere the code assigns it something
that is not that function, the code is wrong — and the way to enforce that is an
assertion on the relationship, not vigilance at each site.

> **Verify:** every figure in this section is a reading of the RTL at the time of the
> architecture review, recorded in
> [`docs/ORDER-BOOK-REDESIGN.md`](../../docs/ORDER-BOOK-REDESIGN.md) §2. Confirm against
> the current source before citing it as present-tense fact — the R1–R6 tasks are
> rewriting exactly these files.

---

## Further reading

- [01-tick-to-trade-pipeline.md](01-tick-to-trade-pipeline.md) — rows B0–B4 in the master budget
- [02-feed-handler-design.md](02-feed-handler-design.md) — the producer of `book_cmd`
- [04-strategy-engine-on-fpga.md](04-strategy-engine-on-fpga.md) — the consumer of `bbo_upd`
- [05-order-gateway-and-pre-trade-risk.md](05-order-gateway-and-pre-trade-risk.md) — the second `book_stale` gate
- [06-cpu-fpga-partitioning.md](06-cpu-fpga-partitioning.md) — who owns the window anchor and the resync
- [../01-fpga-design/03-memory-and-storage.md](../01-fpga-design/03-memory-and-storage.md) — BRAM/URAM, hash tables, banking
- [../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) — why reduction trees are off the fast path
- [../03-algotrading/01-market-microstructure.md](../03-algotrading/01-market-microstructure.md) — what a limit order book *is*
- [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md) — how §12 gets run
- [../08-nasdaq/04-totalview-itch-5.0.md](../08-nasdaq/04-totalview-itch-5.0.md) — ITCH 5.0 order-message semantics, Glimpse recovery
- [../09-deep-dives/05-hash-tables-and-lookup-structures.md](../09-deep-dives/05-hash-tables-and-lookup-structures.md) — the occupancy mathematics; ⚠️ its §6 cuckoo verdict is superseded for the order map by §2.3.4 above
- [../09-deep-dives/07-jitter-sources-and-determinism.md](../09-deep-dives/07-jitter-sources-and-determinism.md) — why worst-case latency is the binding constraint
- [../09-deep-dives/09-failure-modes-and-postmortems.md](../09-deep-dives/09-failure-modes-and-postmortems.md) — the general form of §13
- [`docs/ORDER-BOOK-REDESIGN.md`](../../docs/ORDER-BOOK-REDESIGN.md) — the architecture review, the defect inventory, and the R1–R10 task breakdown

---

## Revision history

| Edition | Change | Reason |
| --- | --- | --- |
| **2nd** | §2.3 order map replaced: 4-way set-associative → **bucketed cuckoo, `d=2` × `b=4`**, `MAX_KICKS = 16`, 16-entry stash. The failed Poisson occupancy table is retained in §2.3.1 rather than deleted. | External FPGA architecture review. The specified table overflows at **12.5 % load** (≈2.8 sets of 16,384 at 8,192 live orders) and its effective capacity is ~8,000 orders — about 62 per symbol at 128 symbols. |
| **2nd** | §2.4 rewritten to separate **eviction (drop)** from **relocation (kick)**. The never-evict rule is **unchanged and still binding**. | The first edition's never-evict rule was correct but was read as disqualifying cuckoo. Cuckoo only relocates; no record is ever discarded. This was the crux of the review's third observation. |
| **2nd** | §2.5 overflow region → **stash**, and re-scoped. The 64-entry sizing table is retained to show the miss (71 items needed at 25 % load, 1,231 at 50 %, 12,804 at 100 %). | The 64-entry region was undersized by two orders of magnitude, and — more importantly — was being used as a capacity mechanism rather than a safety valve. |
| **2nd** | §2.7 added: the **population invariant** (an order is in the map iff its quantity is in the level array). | Bounds the map to `symbols × window levels × orders per level` rather than the venue's live book, and makes a delete for an untracked order a correct no-op. |
| **2nd** | §2.8 added: sizing from measured ITCH statistics, with the **one-SLR / ~320 URAM288** ceiling. | Capacity is a measurement, not a preference, and it may force a reduction in tracked symbols. |
| **2nd** | §2.3.3 added: lookup is **O(1) worst case**, with the argument for why worst case rather than average is the binding requirement. | Disqualifies linear probing and chaining on their latency distribution, independent of average performance. |
| **2nd** | §2.3.5 added: the two hash functions must be **independent**; `h1` must not be a trivial transform of `h0`. | A correlated pair collapses the achievable load factor toward single-hash behaviour, and does so silently. |
| **2nd** | §2.3.6 strengthened: **full keys, never tags** — including why partial-key cuckoo is standard in cuckoo *filters* and inadmissible here. | Unchanged position from the first edition, extended to cover the cuckoo-specific variant. |
| **2nd** | §4 window section rewritten: the base is **host-anchored** from last trade / previous close; out-of-window ⇒ per-symbol stale + host re-anchor, never silent discard. §7 restates 2048 levels / $20.48. | ⚠️ **The manual was right and the RTL diverged from it.** The RTL shipped `BOOK_LEVELS = 16` (a $0.16 window) and auto-anchored on the first price with re-anchor gated on an empty side — a condition a liquid symbol never reaches. |
| **2nd** | §6.1 added: the new-best search over 2048 levels requires a **hierarchical** priority encoder (64 groups × 32), not a flat one. | A flat 2048-input encoder does not close timing at 156.25 MHz. |
| **2nd** | §6.2 added the price-reconstruction rule: `bid_px = window_base + level × tick_size` on every best change, and the true quantity read back from the level array. | ⚠️ The RTL assigned `'0` to both, publishing **bid = $0.00** after every best-level delete. |
| **2nd** | §8 extended with the **write-back skew** failure mode in the order map's bypass. | `wb_*` assigned non-blocking in one `always_ff` and consumed by another lands the write a cycle late; the bypass then covers the wrong cycle. |
| **2nd** | §10 trigger list updated (stash full, out-of-window); §9.2 resync sequence extended with the host re-anchor step and the population-invariant check. | Consequences of §2.7 and §4. |
| **2nd** | §11 budget rows and §12 test list updated for cuckoo, price reconstruction, host re-anchor, the hierarchical encoder, and `TICK_UNITS` reparameterisation. | The lookup budget is unchanged; the tests are not. |
| **2nd** | §13 added: failure modes from the first implementation, with the **$0.00 bid** worked in full. | "The implementation diverged from the spec" is the actual lesson, and it is worth more than a corrected spec with no record of the correction. |

⚠️ **What has *not* changed:** never evict; full keys, never tags; direct-indexed level
array; bypass rather than stall; per-symbol sticky staleness with three independent
consumers; compare against the golden model after every message. The first edition was
right about all of these, and the redesign does not touch them.

⚠️ **Status.** Nothing in the second edition has been compiled, simulated, synthesized,
or run on hardware. This document specifies the target; tasks R1–R7 implement and prove
it. A manual is not evidence.
