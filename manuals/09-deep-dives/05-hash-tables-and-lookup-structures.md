# 09.05 — Hash Tables and Lookup Structures

> **Why this matters here:** `rtl/fpga_top.sv` spends **2 cycles / 12.8 ns — 10 % of the
> whole fabric budget** on one line: "Order-ID map lookup". That row is marked `fixed`, and
> it is the only place in the tick-to-trade path where a *data structure*, not a pipeline
> stage, owns the latency. Everything here defends two properties of that row: that it is
> 2 cycles for **every** key with no probing loop, and that a lookup which does not find its
> record says so loudly instead of quietly returning the wrong order.
> [04.03](../04-system-architecture/03-order-book-in-hardware.md) §2 is the design summary;
> this is the derivation, the mathematics, the tooling and the failure analysis.

---

## 1. The problem, stated exactly

ITCH is order-based. `Add Order` hands you a 64-bit **order reference number** plus
`(stock locate, side, shares, price)`. Every later message about that order — `E`, `C`,
`X`, `D`, `U` — carries **only the reference**. To apply a delete you must recover what the
order was, in a bounded number of cycles, at line rate, with no dynamic allocation.

> **Verify:** the order reference number width (8 bytes) and the exact payload of
> `Order Delete` / `Order Executed` from the **Nasdaq TotalView-ITCH 5.0 specification**.
> Semantics in [08.04](../08-nasdaq/04-totalview-itch-5.0.md) §3 and §7. Confirm before
> freezing the entry format — the key width sets the tag width, which sets the memory.

| # | Requirement | What it forbids |
| --- | --- | --- |
| **R1** | **Fixed latency.** Exactly 2 cycles, every key, hit or miss | Linear probing, chaining, rehash-on-miss — any structure whose worst case is a loop |
| **R2** | **Bounded storage**, statically sized at elaboration (CLAUDE.md §5.1) | Malloc, exhaustible free lists, tree rebalancing |
| **R3** | **No unnoticed miss.** Every failed lookup counted and attributable | "If not found, ignore" — the most expensive line of code available here |
| **R4** | **Read *and* written at line rate** | An unbypassed read-modify-write |

R4 is the one that gets missed. An `A` and a `D` for the same reference can arrive in
adjacent messages, and `symbol_filter` expands `U` into a delete plus an insert back to
back. The order map has the same RMW hazard as the level array, at the same cycle distance,
and needs the same write-forwarding bypass — [04.03](../04-system-architecture/03-order-book-in-hardware.md) §8,
[01.03](../01-fpga-design/03-memory-and-storage.md) §4. ⚠️ A bypass one stage too shallow
here does not corrupt a quantity; it makes an *insert vanish*, and then the delete misses.

---

## 2. Why not a CAM

A CAM answers "which entry holds this key" in one access — exactly what we want, and
unaffordable at this key width. It compares against **every** entry in parallel: `N × K`
bits of comparator plus an `N`-wide match encode. Both linear in capacity; the keys are
unsorted, so there is no logarithmic structure to exploit.

```
LUT-based CAM ≈ N·(K/2) LUT6 for the compare + O(N) for the match encode
  N = 65,536, K = 64  ⇒  ~2.1 M LUT6.   VU9P has ~1.18 M.   ⇒ ~2× the device, one table.
```

> **Verify:** LUT6 count per VU9P-class device from the **AMD UltraScale+ device datasheet
> (DS923)**. The comparator-per-bit ratio is a hand estimate; the conclusion (orders of
> magnitude, not percent) is not sensitive to it.

| Structure | Lookup | Insert | Capacity at 65 K × 64-bit keys | Determinism | Verdict |
| --- | --- | --- | --- | --- | --- |
| **LUT/register CAM** | 1–2 cyc | 1 cyc | ~10²–10³ before it dominates the device | Perfect | **Right primitive, wrong scale.** Keep it for the 64-entry overflow region (§5) |
| **BRAM-emulated CAM** (bit-sliced, one read per key bit) | **64+ cyc** | many | Large | Fixed, hopeless | 64 cycles is 3× the entire fabric budget |
| **Direct index** on `order_ref` | 1 cyc | 1 cyc | 2⁶⁴ × 128 b | Perfect | Physically impossible. ⚠️ *Slicing* the ref to make it fit is §3.4 |
| **Hash + W-way set-associative** | **2 cyc fixed** | 2 cyc | 65,536 in **32 URAM288** | Perfect, given §5 | **CHOSEN** |

A set-associative table *is* a CAM in which the hash has already narrowed the candidate set
from 65,536 to `W`. You still do an associative compare — `W` of them instead of `N`, with
the memory doing the narrowing for free. That is the whole idea.

---

## 3. Hash function choice in fabric

### 3.1 The requirement, and why it is not "a good hash"

A **fixed, combinational, stateless** function of the key that fits in the logic and routing
slack of one 6.4 ns cycle, uses zero DSPs, has no state to reset, and spreads the *actual*
observed key distribution over `2^INDEX_W` sets. Throughput is one lookup per cycle by
construction — the key arrives all at once, so there is no cost-per-byte term.

### 3.2 ⚠️ Not a cryptographic hash — and the caveat that follows

SHA-2/3 or an AES-based mixer costs hundreds of cycles serially, or a huge unrolled
pipeline, to buy collision resistance **against an adversary who chooses keys**. That
adversary does not exist here: the exchange assigns reference numbers, a competitor cannot
pick one to collide with our table, and they cannot observe the table. We are not buying
that property and must not pay for it.

⚠️ **But that is not "the keys are benign".** They are **structured** — Nasdaq assigns
references monotonically per session, so the live set is roughly a sliding window of
near-consecutive integers. Structured is a *different* hazard from adversarial, with a
different fix: you need **avalanche**, not **unpredictability**. Avalanche is an XOR tree
costing ~200 LUT. Unpredictability costs hundreds of cycles. Buy the one you need.

### 3.3 CRC-based XOR trees — the recommended primitive

A CRC is **linear over GF(2)**. An `n`-bit message through a degree-`r` CRC with the
register initialised to zero computes `R(x) = M(x)·x^r mod P(x)`, a linear map, so by
superposition `CRC(M) = ⊕_{j : M_j = 1} CRC(e_j)`. The function collapses to a **constant
GF(2) matrix**: each output bit is a fixed XOR of a subset of input bits. No shift register,
no state, no cycles — one XOR reduction tree per output bit, all `r` in parallel.

```
Fan-in per output bit F ⇒ ⌈log₆ F⌉ LUT6 levels  (a LUT6 computes any 6-input function,
                                                 so a 6-input XOR is exactly 1 LUT)
CRC-32C (0x1EDC6F41) over a 64-bit key : fan-in 20…38, mean 31.8  ⇒ 3 LUT6 levels
CRC-64/ECMA-182     over a 64-bit key : fan-in 22…37, mean 31.8  ⇒ 3 LUT6 levels
```

Fan-ins computed by the generator in §3.6, not quoted. Three LUT levels plus routing sits
inside 6.4 ns for **~200 LUT, 0 FF, 0 DSP, 0 BRAM**.

> **Verify:** the CLB wide-function structures that may collapse this further, from **UG574
> UltraScale Architecture CLB User Guide**. Take the achieved level count from the
> post-synthesis path report — [09.06](06-timing-report-forensics.md).

### 3.4 ⚠️ The trap: slicing the low bits of a monotonic reference

`set = order_ref[13:0]` is a *perfect* hash for a monotone key. Buckets fill round-robin,
the occupancy histogram is flat, it beats the CRC on every metric, and it is free. It is
also the worst decision available in this file:

| Event | What happens to `ref[13:0]` |
| --- | --- |
| Venue changes reference allocation (per-partition, sharded, hashed) | Keys concentrate on a subset of sets; capacity collapses to a fraction |
| Session or numbering restart mid-day | Old- and new-numbering keys alias |
| **Symbol filtering — which we do (§5.4)** | Kept keys are a *sparse, non-contiguous* subsequence. Contiguity was the only thing making the low bits uniform, and **we** destroyed it |
| Two feeds or partitions interleaved | Two monotone streams overlaid: correlated, not uniform |

The third row is the point: **our own design breaks the assumption, not the venue's.**

> **RULE: the set index is a CRC of the full 64-bit reference, never a bit-slice of it.**
> ~1–2 extra LUT levels and ~200 LUT out of a 60 K budget removes an entire class of future
> incident. Same rule as [01.03](../01-fpga-design/03-memory-and-storage.md) §7.2, with its
> failure modes attached.

### 3.5 The alternatives, ranked

| Function | LUT levels | Area | Avalanche | Notes |
| --- | ---: | --- | --- | --- |
| **CRC-32C / CRC-64 XOR tree** | 3 | ~200 LUT | Excellent, provable via GF(2) rank | **Chosen.** Zero DSP, zero state, one cycle |
| Multiply-shift (Dietzfelbinger): `(a·k) >> (64−m)`, `a` odd | DSP cascade | 2–4 DSP48 | Good; provably universal for random odd `a` | A 64×64 multiply is a cascade with its own pipeline latency. Pays a cycle we do not have |
| xorshift-multiply finaliser (splitmix/murmur) | 2 mult + 3 shifts | DSP + LUT | Excellent | Same DSP-latency objection, no advantage over CRC |
| XOR-fold `ref[63:32] ^ ref[31:0]` | 1 | ~64 LUT | **Poor** — the high half is near-constant, so it degenerates to §3.4 | Rejected |
| Bit-slice `ref[13:0]` | 0 | 0 | None | ⚠️ §3.4. Rejected |

> **Verify:** the universality bound for multiply-shift hashing from **Dietzfelbinger,
> Hagerup, Katajainen & Penttonen (1997)** and Thorup's hashing surveys.

### 3.6 The generator, and measuring hash quality

The XOR matrix is derived, not written. This also proves the bijection §4.2 depends on.

```python
# scripts/gen_hash.py — emits rtl/common/crc_hash.sv. Run in the build; check in the output.
def crc_columns(poly, n_in, n_reg):
    """cols[j] = CRC register after feeding unit vector e_j (MSB-first, init 0).
       GF(2) linearity: CRC(M) = XOR of cols[j] over the set bits j of M."""
    cols = []
    for j in range(n_in):
        reg = 0
        for i in range(n_in):
            fb  = ((reg >> (n_reg - 1)) & 1) ^ (1 if i == j else 0)
            reg = ((reg << 1) & ((1 << n_reg) - 1)) ^ (poly if fb else 0)
        cols.append(reg)
    return cols

def gf2_rank(cols, n):                  # rank n over an n-bit input ⇒ bijection ⇒ §4.2
    rows, r = list(cols), 0
    for b in range(n):
        p = next((i for i in range(r, len(rows)) if (rows[i] >> b) & 1), None)
        if p is None: continue
        rows[r], rows[p] = rows[p], rows[r]
        for i in range(len(rows)):
            if i != r and (rows[i] >> b) & 1: rows[i] ^= rows[r]
        r += 1
    return r

POLY, N = 0x42F0E1EBA9EA3693, 64                       # CRC-64/ECMA-182
cols = crc_columns(POLY, N, N)
assert gf2_rank(cols, N) == N, "polynomial is NOT a bijection on 64 bits"
for k in range(N):
    t = [f"key[{j}]" for j in range(N) if (cols[j] >> k) & 1]
    print(f"assign h[{k}] = {' ^ '.join(t)};   // fan-in {len(t)}")
```

⚠️ **Never hand-transcribe an XOR matrix and never let synthesis infer one from a
behavioural bit-serial loop.** Generate it, check the file in, diff it in review — a single
wrong term is invisible in simulation until one specific key collides.

Quality is then **measured on real keys**, not asserted:

```python
# host/analysis/hash_quality.py — replay a real ITCH day, histogram bucket occupancy.
def crc64(key, cols):
    h = 0
    for j in range(64):
        if (key >> j) & 1: h ^= cols[j]
    return h

INDEX_W, WAYS = 14, 4
occ, cur, live = Counter(), Counter(), {}       # occ[s] = PEAK simultaneous live in set s
for msg in itch_messages("day.pcap", locates=TRACKED_LOCATES):   # filtered — see §5.4
    if msg.type in b"AF":
        s = crc64(msg.ref, cols) & ((1 << INDEX_W) - 1)
        live[msg.ref] = s; cur[s] += 1; occ[s] = max(occ[s], cur[s])
    elif msg.ref in live and msg.retires_order:
        cur[live.pop(msg.ref)] -= 1

h = np.array([occ[s] for s in range(1 << INDEX_W)])
print("peak max load", h.max(), "| sets over W", (h > WAYS).sum(),
      "| excess records", np.maximum(h - WAYS, 0).sum(), "| mean", h.mean())
```

Report **peak max load** and **total excess records**. The mean is the load factor, which
you already knew; the tail is the design input (§7).

---

## 4. Set-associative design

```
   order_ref[63:0] ─► crc_hash (combinational, computed in the SYMBOL-FILTER stage, §4.3)
        h[63:0] ─►  set = h[13:0] (16,384 sets)    tag = h[63:14] (50 b)
                              │  ONE memory access, one 512-bit row
   ┌──────────────────────────▼───────────────────────────────────┐
   │ way0 {v,tag[49:0],payload} │ way1 │ way2 │ way3   = 4 × 128 b │
   └──────────────────────────┬───────────────────────────────────┘
       4 × 51-bit compare in PARALLEL (1 LUT level) + 4:1 payload mux
       hit → {slot, side, level, qty, ticket}   miss → overflow CAM → miss counter
```

| Parameter | Value | Why |
| --- | --- | --- |
| `INDEX_W` | 14 → 16,384 sets | Sets × ways = capacity; §7 chooses the split |
| `WAYS` | 4 | §7: 8-way buys ~15× on `P(overflow)` at α = 0.25 but doubles row width and compare fan-in. 4 is the knee |
| Row width | 4 × 128 = **512 b** | `⌈512/72⌉ = 8` URAM288 wide × `16384/4096 = 4` deep = **32 URAM288** |
| Tag | 50 b (§4.2) or the full 64-bit key | Never a truncated non-invertible tag |
| Payload | `{slot, side, level, qty, epoch, ticket}` | `ticket` is [09.01](01-queue-position-and-fill-probability.md) §4.2 riding along free |

### 4.2 The tag: why 50 bits is *exactly* as safe as 64

If `index` were an arbitrary hash, "the remaining key bits" would not be a well-defined tag
and any truncation would admit false hits. But a **CRC-64 over a 64-bit input with
`P(0) = 1` is a bijection on GF(2)⁶⁴** — the map is multiplication by `x⁶⁴ mod P(x)`,
invertible whenever `gcd(x, P) = 1`, i.e. whenever the polynomial has a non-zero constant
term. Every standard CRC polynomial does; `gen_hash.py` asserts it (rank 64 for
CRC-64/ECMA-182). Therefore `{tag[49:0], set[13:0]} = h[63:0]`, which determines the key
uniquely: two distinct references cannot share both index and tag. **Zero false positives at
50 bits of storage.**

| Tag `T` | `P(false hit) ≈ W·2⁻ᵀ` | False hits per 10⁹ lookups (W = 4) | Verdict |
| ---: | ---: | ---: | --- |
| 16 | 6.1e−5 | 61,000 | Catastrophic |
| 24 | 2.4e−7 | 238 | Catastrophic |
| 32 | 9.3e−10 | **0.93** | ⚠️ **A daily event** — the arithmetic behind [04.03](../04-system-architecture/03-order-book-in-hardware.md) §2.3 |
| 40 | 3.6e−12 | 0.0036 | ~1 per year |
| **50, bijective split** | **0** | **0** | **Exact** |
| 64, full key | 0 | 0 | Exact; costs 14 more bits/entry |

⚠️ A tag false positive is not a miss — it is a **hit on the wrong order**. You apply a
delete to a different order, at a different price, in a different symbol, and no counter
increments. At a 128-bit entry the full key already fits, so the honest recommendation is:
**store the full key; use the bijection argument for a 50-bit tag only if width forces it.**

### 4.3 Hitting 2 cycles, and the mistake that costs a third

The budget row reads *"Order-ID map lookup (BRAM + out reg) — 2 cycles, fixed"*. Two cycles
is **one memory access + one compare/select**. There is no third cycle for the hash.

```
cycle N-1 (symbol-filter row) : crc_hash combinational on order_ref → {set,tag} REGISTERED
cycle N   (map cycle 1)       : set drives the URAM address; row registered at end of cycle
cycle N+1 (map cycle 2)       : 4 × 51-bit compare, way select, payload mux, REGISTER out
                                overflow CAM compared IN PARALLEL here, not after
```

> **RULE: the hash is computed in the stage before the map and arrives pre-registered.** The
> reference is extracted at ITCH decode and the hash depends on nothing else, so folding it
> into the symbol-filter row — one cycle that does almost no work — costs **zero budget
> rows**.

⚠️ Register the hash as its own stage and the lookup is 3 cycles: 6.4 ns spent silently.
⚠️ Leave the URAM output register **on** and the read is 2 cycles, the compare makes 3 —
exactly the figure in [01.03](../01-fpga-design/03-memory-and-storage.md) §7. That table and
the `fpga_top` budget row describe different configurations, and only one of them fits.

| Realisation | Cycles | Memory | Risk |
| --- | ---: | --- | --- |
| URAM, output reg **off**, hash folded upstream | **2** | 32 URAM288 | Fmax: raw clock-to-out + routing + compare. **This is the design; prove it in the timing report** |
| URAM, output reg **on** | 3 | 32 URAM288 | ⚠️ Busts the budget row by 6.4 ns |
| BRAM36, read latency 1 | 2 | `⌈512/72⌉ × (16384/512)` = **256 BRAM36** | Fits `BRAM < 300` with nothing left for FIFOs. Fallback only |

> **Verify:** URAM288 read latency with and without the optional output register, and
> whether built-in SECDED forces it on, from **UG573 UltraScale Architecture Memory
> Resources**. If ECC forces the output register, ECC and the 2-cycle row are in conflict —
> resolve that in the design doc, not in RTL.

```systemverilog
// rtl/book/order_map.sv — budget row: 2 cycles, FIXED. No stall, no probe, no exception.
// Ports elided: clk/rst, {set_q,tag_q} registered from the symbol-filter stage,
// lookup/insert/erase valids, ins_payload_q, and {rd_payload, rd_hit, rd_miss}.
typedef struct packed { logic v; logic [TAG_W-1:0] tag; omap_payload_t p; } way_t;
way_t row_q [WAYS];                     // ONE 512-bit URAM row: all ways in one access

// cycle N — write-forwarding bypass is MANDATORY (R4): an insert at N-1 into this set must
// be visible to a lookup at N, or a back-to-back Add/Delete pair silently loses the record.
// BYPASS_DEPTH == RAM_RD_LAT, derived from one parameter, never two constants (04.03 §8).
always_comb for (int w = 0; w < WAYS; w++)
    row_eff[w] = (wr_en_d && wr_set_d == set_q && wr_way_d == w) ? wr_way_data_d : row_q[w];

// cycle N+1 — WAYS compares in PARALLEL. Not WAYS reads. That is the whole point.
always_comb for (int w = 0; w < WAYS; w++)
    way_hit[w] = row_eff[w].v && (row_eff[w].tag == tag_q);

order_map_overflow u_ovf (.set_q, .tag_q, .hit(ovf_hit), .payload(ovf_payload));  // §5.3

always_ff @(posedge clk) begin
    rd_hit     <= lookup_v_q &&  (|way_hit || ovf_hit);
    rd_miss    <= lookup_v_q && !(|way_hit || ovf_hit);   // R3: counted + attributed, §5.2
    rd_payload <= |way_hit ? row_eff[onehot_idx(way_hit)].p : ovf_payload;
end
// ⚠️ NO loop over ways that can iterate. NO probe of a second set on a miss. A miss is a
// RESULT, not a retry — one probe makes this stage variable-latency and every `fixed` row
// downstream in fpga_top.sv becomes a lie.
```

---

## 5. Collision and eviction policy — and the correctness consequence

### 5.1 ⚠️ An eviction is not a performance event. It is a correctness event.

Evict the record for order X to make room and the order **still exists at the venue**.
Minutes later its `Order Delete` arrives. You look up X, you miss, and you cannot apply the
delete — you do not know its price, side or remaining quantity, so there is nothing to
subtract. Those shares stay on that price level **for the rest of the session**. The book
now shows liquidity that is not there, and every quote, imbalance and trigger derived from
that level is computed against a fiction.

And **nothing tells you.** A delete for an unknown reference is *indistinguishable* from a
delete for an order you filtered out by symbol — both are "reference not in the table". The
benign case happens millions of times a day. The catastrophic case is one event hiding
inside it. Unless the counters are separated, the alarm is buried in its own noise.

> **RULE: never evict a record for a tracked symbol.** Spill to the overflow region; if that
> is full, set `book_stale` for the symbol **deliberately and loudly** and force a resync,
> exactly as for a sequence gap. Going stale costs one symbol for a few hundred
> milliseconds. Evicting costs the rest of the day, and you will not know.

That is [04.03](../04-system-architecture/03-order-book-in-hardware.md) §2.4 with the
mechanism spelled out, and why [08.04](../08-nasdaq/04-totalview-itch-5.0.md) §7 calls an
unknown reference "a symptom, not an anomaly to swallow".

### 5.2 The counters that make R3 real

| Counter | Increments when | Expected | Meaning if unexpected |
| --- | --- | --- | --- |
| `omap_miss_untracked` | Miss, locate **not** in the enabled bitmap | Millions/day | Benign — the filter working. Ideally never reached: filter *before* the lookup |
| `omap_miss_tracked` | Miss, locate **is** tracked | **Zero**, except decaying after a snapshot resync | **Correctness alarm.** Sustained non-zero ⇒ that symbol's book is wrong |
| `omap_evict` | Any eviction of a tracked record | **Zero, forever** | The design is broken. Not a tuning knob |
| `omap_overflow_occ` / `_hwm` | Overflow CAM occupancy / high-water | < 50 % of capacity | Approaching capacity ⇒ table undersized; rebuild with more sets (§7) |
| `omap_insert_fail` | Set full **and** overflow full | Zero | Symbol staled; each one is a resync |
| `omap_bypass_hit` | Write-forwarding bypass fired (R4) | Thousands/s | **Zero is the alarm** — the bypass is not wired, not that the hazard is absent |

⚠️ `omap_miss_tracked` and `omap_miss_untracked` must be **separate registers**. Merging
them is a one-line "simplification" that destroys the only signal distinguishing normal
operation from a silently diverged book. Semantics per
[06.03](../06-operations/03-monitoring-and-telemetry.md).

### 5.3 The policy table

| Policy on a full set | Lookup | Correctness consequence | Verdict |
| --- | --- | --- | --- |
| Evict LRU / random | 2 cyc | ⚠️ Permanent silent phantom size on a level (§5.1) | **Forbidden** |
| Drop the insert silently | 2 cyc | Identical to eviction, reached by inaction | **Forbidden** |
| Rehash / probe the next set | **variable** | Correct, but R1 is gone and every downstream `fixed` row is a lie | Rejected |
| Widen to 8 ways | 2 cyc | Correct; ~15× lower `P(overflow)` at α = 0.25 for 2× row width | Fallback if §8 demands it |
| **Spill to a small fully-associative overflow CAM** | 2 cyc (compared **in parallel**, +0) | Correct, bounded, and occupancy is an early warning | **CHOSEN** |
| Overflow full → `book_stale` + resync | 2 cyc | Correct, loud, self-healing | **CHOSEN** terminal case |

64 entries × 64-bit compare is ~600 LUT: §2's rejected primitive, deployed at the scale
where it wins.

### 5.4 The symbol filter is what makes this fit

TotalView carries on the order of 9,000 securities; we track `N_SYMBOLS = 128`. **Insert
only if the message's `stock locate` is in the enabled bitmap** — a 1-cycle BRAM read
already in the pipeline ([04.02](../04-system-architecture/02-feed-handler-design.md)).

⚠️ The reduction is **not** 9000/128 = 70×. Order counts are wildly non-uniform and we
deliberately select the *most* active names, so our 128 symbols hold far more than 128/9000
of all live orders. The honest form:

```
reduction = (live orders across ALL symbols) / (live orders across OUR 128)
          = a MEASURED ratio, from §8, on a real day, for the actual universe.
```

It is still the largest single lever in the design — [08.04](../08-nasdaq/04-totalview-itch-5.0.md) §7
is right to call it the most effective resource optimisation in the feed handler — but it is
a measurement. Quoting 70× will undersize the table.

---

## 6. Cuckoo and d-left hashing in hardware

At α = 0.25 with 4 ways, ~60 sets of 16,384 already overflow (§7) while the table is
three-quarters empty. Two schemes recover that capacity.

**Cuckoo.** `d` independent hash functions, `d` parallel table reads, compare all. **Lookup
is O(1) worst case** — the property R1 demands. *Insertion* is the problem: if all `d`
candidates are full you evict an incumbent and re-insert it at *its* alternate location,
recursively, with no useful worst-case bound and the possibility of a cycle. ⚠️ Here the
insert path is **also** critical — `Add Order` arrives at line rate — so an unbounded
displacement chain violates CLAUDE.md §5.2 outright. The bounded form: cap the chain at `K`,
and on exhaustion spill to the overflow CAM; if that is full, `book_stale`. §5.1 applies
unchanged — a cuckoo displacement that *drops* an incumbent is an eviction by another name.

> **Verify:** achievable load factors before insertion failure — **Pagh & Rodler, "Cuckoo
> Hashing" (2001)** for `d = 2`, single-slot buckets; **Fotakis, Pagh, Sanders & Spirakis
> (2003)** for `d`-ary cuckoo; **Erlingsson, Manasse & McSherry (2006)** and
> **Dietzfelbinger & Weidling** for bucketed cuckoo. Take the figures from the papers.

**d-left.** Split into `d` subtables, each with its own hash; on insert read all `d`
candidate buckets, place into the **least loaded**, ties to the left. One attempt, no
displacement, no chain, no retry. Lookup reads all `d` and compares — again fixed. The
"power of `d` choices" is why it works: with one random choice the maximum load over `n`
bins grows like `log n / log log n`; with `d ≥ 2` it collapses to `log log n / log d + O(1)`,
and left tie-breaking improves the constant. An exponential tail improvement for one extra
memory port.

> **Verify:** maximum-load bounds from **Azar, Broder, Karlin & Upfal, "Balanced
> Allocations" (1994)**, the d-left refinement from **Vöcking, "How Asymmetry Helps Load
> Balancing" (1999)**, and the hardware treatment in **Broder & Mitzenmacher (2001)**.

| Scheme | Lookup, **worst case** | Insert, worst case | Load factor before failure | Ports | Complexity | Verdict here |
| --- | ---: | --- | ---: | --- | --- | --- |
| **4-way set-assoc + overflow CAM** | **2 cyc** | 2 cyc, always | ~0.25 at `P(any overflow)` ≈ 10⁻² (§7) | 1 wide row | Trivial | **CHOSEN** |
| 8-way set-assoc + overflow | 2 cyc | 2 cyc | ~0.35 at similar `P` | 1 double-width row | Trivial | Fallback if §8 measures higher peaks |
| Cuckoo, `d = 2`, bucket 4, bounded `K` | 2 cyc (`d` parallel reads) | **bounded `K`, but `K` RMWs ≫ 1 cycle** | highest of the four | `d` memories | High: displacement FSM, cycle detection, cross-table RMW hazard | **Rejected — the insert path is real-time** |
| **d-left, `d = 2`, bucket 4** | 2 cyc (`d` parallel reads) | **2 cyc, always** | high | `d` memories | Moderate: a popcount and a min-select | **Strong second.** Adopt if capacity binds |

**The call: stay with 4-way set-associative plus the overflow CAM.** Cuckoo is rejected on
its *insert* path, not its lookup path. d-left is genuinely better engineering and would win
if URAM were scarce — it is not (32 of ~960), so we buy occupancy with memory rather than
with a second hash, two more memory instances and a min-select on the insert path. **Memory
is cheap here; the 2-cycle row and design simplicity are not.** Revisit if §8 measures a
peak that 65,536 entries cannot hold at α ≤ 0.25.

---

## 7. Occupancy vs collision rate — the mathematics

`n` records hashed uniformly into `S` sets of `W` ways. Per-set occupancy is
`Binomial(n, 1/S)`, well approximated by `Poisson(λ)` with `λ = n/S = α·W`, where
`α = n/(S·W)` is the load factor.

```
P(set overflows)          = P(X > W) = 1 − Σ_{k=0}^{W} e^(−λ) λ^k / k!
E[excess records per set] = Σ_{k>W} (k − W) · e^(−λ) λ^k / k!
E[total excess]           = S × E[excess per set]      ← THIS sizes the overflow region
P(any set overflows)      = 1 − (1 − P(set overflows))^S
```

**`P(set overflow)`, computed from the formula above:**

| α | W = 2 | **W = 4** | W = 8 | W = 16 |
| ---: | ---: | ---: | ---: | ---: |
| 0.0625 | 2.96e−4 | **6.6e−6** | 3.4e−9 | 8.9e−16 |
| 0.125 | 2.2e−3 | **1.7e−4** | 1.1e−6 | 5.6e−11 |
| 0.25 | 1.4e−2 | **3.7e−3** | 2.4e−4 | 1.1e−6 |
| 0.50 | 8.0e−2 | **5.3e−2** | 2.1e−2 | 3.7e−3 |
| 0.75 | 1.9e−1 | **1.8e−1** | 1.5e−1 | 1.0e−1 |

Associativity buys orders of magnitude at low load and almost nothing at high load — at
α = 0.75 all four columns are within 2×, because the *table* is full, not the sets. And at
α = 0.5 a 4-way table overflows 5 % of its sets: hash tables are not "fine until 80 % full".
That intuition comes from software tables that probe, and we cannot probe.

**Overflow-region sizing — `S = 16,384`, `W = 4`, capacity 65,536:**

| α | `n` live | E[excess]/set | **E[total excess]** | Overflowing sets |
| ---: | ---: | ---: | ---: | ---: |
| 0.0625 | 4,096 | 6.9e−6 | **0.1** | 0.1 |
| 0.125 | 8,192 | 1.9e−4 | **3.1** | 2.8 |
| 0.25 | 16,384 | 4.3e−3 | **71.3** | 60.0 |
| 0.375 | 24,576 | 2.4e−2 | **396** | 304 |
| 0.50 | 32,768 | 7.5e−2 | **1,231** | 863 |

⚠️ **The 64-entry overflow region of
[04.03](../04-system-architecture/03-order-book-in-hardware.md) §2.5 is exhausted in
expectation at α ≈ 0.244 — about 16,000 live records, one quarter of the nominal 65,536
capacity.** The overflow region, not the set array, is the binding constraint, and that is
the number §8's measured peak must be checked against. At a measured peak near 30,000 the
overflow must grow to ~1,300 entries (no longer a register CAM — it becomes a second hashed
table) or `WAYS` must go to 8.

**You do not size for the average.** State the criterion as policy:

> **RULE: size so that the expected number of `omap_insert_fail` events across a full
> trading day is below 0.01 — one deliberate stale per 100 sessions — evaluated at the
> measured *peak* live-order count from §8 times a stated safety factor, never at the mean.**

```
Worked, at the design point (every input from §8, none assumed):
  n_peak (measured, §8)                    N          safety factor (policy)  × 2
  ⇒ design n = 2N,  α = 2N/65,536,  λ = 4α
  ⇒ E[total excess] = 16,384 · Σ_{k>4}(k−4)e^−λ λ^k/k!   must be ≤ 0.5 × 64 = 32
  ⇒ from the table above that bounds α ≲ 0.21   ⇒   N ≲ 6,900 live records
  If N exceeds that: raise S (more URAM), raise W (wider row), or cut N_SYMBOLS — in that
  order. The last is a P&L decision, not an engineering one.
```

⚠️ The Poisson model assumes a uniform hash. It is only valid if §3.6's measured histogram
matches it; a measured max load above the prediction means the **hash** is wrong, not the
sizing.

---

## 8. Table sizing from real ITCH statistics

The sizing input is **the peak count of simultaneously live order references for our
filtered symbol set** — not total adds per day (larger by orders of magnitude, and
irrelevant), not average depth. The intraday high-water mark of the live set.

```python
# host/analysis/live_orders.py — slow path, offline. Run over several real ITCH days.
live_by_sym, ref_to_sym, hwm_sym, hwm_total, series = Counter(), {}, Counter(), 0, []
for msg in itch_messages("S050125-v50.pcap"):
    if msg.locate not in TRACKED_LOCATES:      # THE filter. Omit it and the answer is for a
        continue                               # universe you do not trade.
    if msg.type in b"AF":
        ref_to_sym[msg.ref] = msg.locate; live_by_sym[msg.locate] += 1
    elif msg.ref in ref_to_sym and (msg.type in b"DU" or msg.remaining == 0):
        live_by_sym[ref_to_sym.pop(msg.ref)] -= 1    # E/C/X retire at zero; D and U always
    if msg.type == b"U":                             # U retires one ref and creates another
        ref_to_sym[msg.new_ref] = msg.locate; live_by_sym[msg.locate] += 1
    tot = sum(live_by_sym.values())
    hwm_total = max(hwm_total, tot)
    hwm_sym[msg.locate] = max(hwm_sym[msg.locate], live_by_sym[msg.locate])
    series.append((msg.ts_ns, tot))            # keep the TIME SERIES, not just the maximum
print("aggregate HWM", hwm_total, "| worst symbols", hwm_sym.most_common(5))
```

⚠️ `E`/`C`/`X` can drive an order to zero and retire it; handling removal only on `D`
overcounts the live set and oversizes the table. ⚠️ `U` retires one reference and creates
another; treating it as an in-place edit leaks references and the count grows monotonically
all day ([08.04](../08-nasdaq/04-totalview-itch-5.0.md) §7).

**Keep the time series.** The aggregate peak is almost certainly in the first minutes after
09:30 or the last before 16:00, and those are the two windows where an overflowing table is
most expensive — [09.08](08-market-open-and-close-dynamics.md).

> **RULE: `ORDER_MAP_ENTRIES` is derived from a measured high-water mark over a stated set
> of dates, recorded in `docs/` with the date range and pcap identifiers, re-measured at
> least quarterly and after any change to `N_SYMBOLS`. Never a guess, never carried forward
> from a previous universe.** Choose the days deliberately — a quiet day, a high-volume day,
> a triple-witching day, an FOMC day, and the most volatile day of the last year. Size on
> the worst, not the median.

> **Verify:** that Nasdaq publishes historical TotalView-ITCH sample files (a full day of
> raw ITCH per sample, by date) for exactly this purpose, and the current access terms, from
> the **Nasdaq Trader / Nasdaq Data Link market data sample archives**. Confirm the sample is
> the same product version (5.0) you decode.

---

## 9. The software-assisted map, and why it is rejected for the hot path

**Fairly stated:** keep a small hot table in fabric for orders near the touch and push the
long tail over PCIe to host DRAM. Capacity becomes gigabytes, the URAM problem disappears,
the universe can grow to hundreds of symbols.

```
Fabric budget for the ENTIRE tick-to-trade path (fpga_top.sv)   128 ns
Order-map lookup row                                             12.8 ns
PCIe round trip + host DRAM read + DMA completion                µs-scale
                                                                 ↑ two to three orders of
                                        magnitude over the whole budget, not just the row
```

> **Verify:** PCIe Gen3 round-trip and host DRAM latency from
> [07.02](../07-reference/02-latency-reference-numbers.md), measured on *your* board —
> vendor typicals assume an idle root complex you will not have.

Latency is the second objection. The first is **variance**: a structure that is 2 cycles at
a 60–90 % hit rate and microseconds otherwise is not "mostly fast", it is a bimodal
distribution feeding a `fixed`-latency pipeline. That means either a stall path into the RX
(forbidden, CLAUDE.md §5.4) or a book that is wrong for the duration
([09.07](07-jitter-sources-and-determinism.md)). You cannot predict which orders get deleted,
so you cannot make the hot set the right set.

**Where host assistance is genuinely right, and should be built:** the shadow map for
reconciliation (the host builds its own from the DMA-tapped stream and compares aggregates
periodically; a divergence stales the symbol); rebuilding after a gap, already a slow-path
operation ([04.03](../04-system-architecture/03-order-book-in-hardware.md) §9); the §3.6 and
§8 analysis; and the regulatory audit trail
([03.06](../03-algotrading/06-risk-and-compliance.md)). Same conclusion as
[04.03](../04-system-architecture/03-order-book-in-hardware.md) §2.6, reached from the jitter
side rather than the mean-latency side.

---

## 10. The other lookup structures in this design

The order map gets the attention because it is the hard one. The others are instructive
precisely because **none of them needs a hash**.

| Structure | Key | Mechanism | Size | Latency | Notes |
| --- | --- | --- | --- | ---: | --- |
| **`stock locate` → active index** | 16-bit dense | **Direct-indexed BRAM**, `enabled` bit + `slot[6:0]` | ~9 K × 16 b | 1 cyc | ⚠️ Size to the **maximum locate value**, not to `N_SYMBOLS` ([08.04](../08-nasdaq/04-totalview-itch-5.0.md) §3) |
| **symbol string → locate** | 8-byte ASCII | **Host-built perfect hash**, resolved at start of day from the Stock Directory (`R`) messages and DMA'd in | host-side | n/a | The symbol set is known **before the open**, so a *minimal perfect* hash with zero collisions is constructible offline. Never parse a symbol string on the fast path |
| **price → level index** | 32-bit scaled price | **Subtract + reciprocal multiply**, not a hash | 0 | 0 cyc (folded into R4) | An address computation, not a search ([04.03](../04-system-architecture/03-order-book-in-hardware.md) §4, [09.04](04-fixed-point-arithmetic-in-fabric.md)) |
| **level → aggregate** | `{slot, level}` | **Direct-indexed**, RMW with bypass | 128 × 2048 × 64 b | 1 cyc | The structure the order map exists to feed |
| **slot → cancel template** | 7-bit slot | **Direct-indexed BRAM**, shadow-banked | 128 × 512 b | 1 cyc | Pre-built OUCH bytes; the trigger splices token + qty ([09.03](03-cancel-latency-and-pickoff.md)) |
| **slot → strategy parameters** | 7-bit slot | **Direct-indexed BRAM**, shadow-banked, atomic flip | 128 × ~256 b | 1 cyc | [04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) |
| **order token → order state** | our own token | **We choose the key** — allocate tokens as a dense index into a static array | 1024 × ~128 b | 1 cyc | ⚠️ When you control the key space, *make it dense*. Never hash a key you assigned yourself |

> **RULE: hash only when the key space is both sparse and not yours.** In this entire system
> that is true exactly once — the ITCH order reference number. Any design introducing a
> second hash table is challenged on exactly this point.

---

## 11. Verification: what must be proven

| Test | Method | Must assert |
| --- | --- | --- |
| **Differential vs golden `dict`** | Full replayed ITCH day into RTL and a Python model holding `{ref: (locate, side, price, qty)}`; compare on **every** `E`/`C`/`X`/`D`/`U` | Identical payload, or matching miss, on every message. ⚠️ Compare per-message, not at the end — two errors cancel |
| **No false hit** | Constrained-random: insert `n` keys, look up `n` keys **known absent**, chosen to collide in the index bits | `rd_hit` never asserts — the §4.2 property under test |
| **No lost record** | Insert `n` keys, look up all `n` shuffled | Every one hits. Any loss ⇒ eviction or bypass bug |
| **RMW hazard (R4)** | Directed: Add then Delete for the same ref at cycle distance 1, 2, 3; Add/Add into one set; `U` expansion | Delete hits; `omap_bypass_hit` increments. ⚠️ A distance-3-only test passes with no bypass at all |
| **Overflow path** | Fill a set to `WAYS`, insert a 5th key into it, look it up | Hits via the overflow CAM at the **same 2-cycle latency**; `omap_overflow_occ` = 1 |
| **Overflow exhaustion** | Fill the overflow CAM, insert once more | `omap_insert_fail` + `book_stale`. **No eviction.** No wrong-order delete |
| **Counter attribution** | Deletes for (a) an untracked locate, (b) a tracked locate with no record | (a) increments `omap_miss_untracked` **only**; (b) `omap_miss_tracked` **only** |
| **Fixed latency** | Assertion bound to every lookup | Result valid at **exactly** 2 cycles, for every key — hit, miss, overflow hit, bypass hit. No exceptions |
| **Hash matrix** | Generated `crc_hash.sv` vs a bit-serial CRC reference over 10⁶ random keys | Bit-exact, plus `gf2_rank == 64` (§3.6) |
| **Hash quality on real keys** | §3.6 over a full replayed day | Measured max load ≤ the §7 Poisson prediction; exceeding it indicts the hash, not the sizing |
| **Epoch clear** | Bump the epoch; then 17 resyncs to force wrap | All entries read invalid; the scrubber prevents aliasing ([04.03](../04-system-architecture/03-order-book-in-hardware.md) §9.1) |

Methodology in [01.05](../01-fpga-design/05-verification-and-simulation.md); regression and
pcap-fixture discipline in [06.04](../06-operations/04-testing-strategy.md).

---

## 12. Rules for this project

1. **2 cycles, fixed, every key.** No probing, no rehash, no retry, no data-dependent loop. A miss is a result, not a reason to look again.
2. **The hash is computed one stage early**, in the symbol-filter row, arriving pre-registered. Registering it as its own stage costs a third cycle and breaks the budget.
3. **The set index is a CRC XOR tree over the full 64-bit reference** — never a bit-slice. Our own symbol filtering destroys the contiguity that makes slicing look safe.
4. **The XOR matrix is generated, checked in, and diffed in review**, never hand-written or inferred from a behavioural loop; the generator asserts `gf2_rank == 64`.
5. **Store the full key, or a 50-bit tag justified by the bijection argument.** Never a truncated non-invertible tag: 32 bits is a silent wrong-order delete about once a day.
6. **Never evict a tracked record.** Spill to the overflow CAM; if that is full, `book_stale` and resync. `omap_evict` reads zero forever.
7. **`omap_miss_tracked` and `omap_miss_untracked` are separate counters.** Merging them hides the only correctness alarm this structure produces inside millions of benign events.
8. **The write-forwarding bypass is mandatory**, with `BYPASS_DEPTH` derived from `RAM_RD_LAT` by parameter, never as an independent constant.
9. **Size from a measured peak of simultaneously-live references**, over a stated date range including the worst day of the year, times a stated safety factor, recorded in `docs/`, re-measured quarterly and on any `N_SYMBOLS` change.
10. **Size the overflow region from `E[total excess]`, not intuition** — at 4 ways and 16,384 sets, 64 entries is exhausted around α ≈ 0.24, which is the real capacity limit of the design.
11. **Cuckoo is rejected on the insert path, not the lookup path.** d-left is the sanctioned upgrade if capacity binds; adopt it before adopting cuckoo.
12. **No PCIe, DDR or HBM in the lookup path**, for any key, ever — not for a cold tail, not for a rare case.
13. **Hash only the ITCH order reference.** Every other key here is dense, or is one we assigned ourselves, and is direct-indexed.
14. **Every figure in §7 is a formula, not a table lookup.** Recompute it for your `S`, `W` and measured `n` before quoting it in a design review.

---

## Further reading

- [../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) — CAMs, content-addressable lookup, why reduction trees stay off the fast path
- [../01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) — II=1 and the RMW feedback loop
- [../01-fpga-design/03-memory-and-storage.md](../01-fpga-design/03-memory-and-storage.md) — §7 the summary of this structure, §4 read-during-write, §6 banking, §9 ECC
- [../01-fpga-design/05-verification-and-simulation.md](../01-fpga-design/05-verification-and-simulation.md) — the differential-vs-golden-model method of §11
- [../04-system-architecture/02-feed-handler-design.md](../04-system-architecture/02-feed-handler-design.md) — the symbol filter that makes §5.4 work
- [../04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md) — §2 the design summary, §8 the RMW hazard, §9 epoch clear and resync
- [../05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md) — the 2-cycle row this document defends
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) — counter semantics for §5.2
- [../07-reference/02-latency-reference-numbers.md](../07-reference/02-latency-reference-numbers.md) — the PCIe and DRAM figures behind §9
- [../08-nasdaq/04-totalview-itch-5.0.md](../08-nasdaq/04-totalview-itch-5.0.md) — §3 the order reference number, §7 order-based reconstruction and the unknown-reference symptom
- [01-queue-position-and-fill-probability.md](01-queue-position-and-fill-probability.md) — the arrival ticket that rides free in the map entry
- [04-fixed-point-arithmetic-in-fabric.md](04-fixed-point-arithmetic-in-fabric.md) — the reciprocal multiply behind price → level
- [06-timing-report-forensics.md](06-timing-report-forensics.md) — proving the URAM-plus-compare path closes at 2 cycles
- [07-jitter-sources-and-determinism.md](07-jitter-sources-and-determinism.md) — why a variable-latency lookup is worse than a slower fixed one
- [08-market-open-and-close-dynamics.md](08-market-open-and-close-dynamics.md) — where the §8 high-water mark lives
