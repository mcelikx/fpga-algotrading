# rtl/book — Order book

> The hardest block in the system, and the one whose defects are most expensive.
> A book that is *subtly* wrong produces plausible prices, so nothing alarms —
> and the strategy trades on them.

Governing manual: [manuals/04-system-architecture/03-order-book-in-hardware.md](../../manuals/04-system-architecture/03-order-book-in-hardware.md)

---

## 1. Why there are two structures

Nasdaq TotalView-ITCH is an **order-based** feed. `Execute` (E/C), `Cancel` (X),
`Delete` (D) and `Replace` (U) carry **only a 64-bit order reference** — no
symbol, no side, no price. So a price-level array alone cannot be maintained:
when a delete arrives, there is nothing in it that says which level to reduce.

The book therefore needs two structures kept mutually consistent:

| Structure | File | Maps |
| --- | --- | --- |
| Order map | [order_id_map.sv](order_id_map.sv) | `order_ref` → `{sym, side, price, remaining_qty}` |
| Price levels | [price_levels.sv](price_levels.sv) | `(sym, side, price)` → aggregate qty |
| Top of book | [top_of_book.sv](top_of_book.sv) | occupancy mask → best bid / best ask |

Every message resolves the first to learn what to do to the second.

**The consequence that drives the whole design:** if the order map loses an
entry, the quantity that order contributed to its level can *never* be removed,
because the delete that would remove it resolves to nothing. The book diverges
permanently and silently. That is why a failed insert sets a sticky `stale` flag
rather than being counted and ignored, and why entries are **never evicted**.

---

## 2. Files

| File | Role | Latency |
| --- | --- | --- |
| [book_pkg.sv](book_pkg.sv) | Internal types, hash, tick normalization | — |
| [order_id_map.sv](order_id_map.sv) | 4-way set-associative, full 64-bit keys | 2 cyc |
| [price_levels.sv](price_levels.sv) | Direct-indexed level array + window anchor | 2 cyc |
| [top_of_book.sv](top_of_book.sv) | Incremental best, occupancy bitmask | 1–2 cyc |
| [book_engine.sv](book_engine.sv) | Pipeline top, Replace injection, telemetry | 5–6 cyc total |

---

## 3. Latency budget lines owned

From the master table in [rtl/fpga_top.sv](../fpga_top.sv):

| Stage | Cycles | ns | Fixed? |
| --- | --- | --- | --- |
| Order-ID map lookup (BRAM + out reg) | 2 | 12.8 | fixed |
| Book level update + incremental top-of-book | 2 | 12.8 | **variable** |
| (plus input registration and Replace injection) | 1–2 | 6.4–12.8 | variable |
| **Total** | **5–6** | **32.0–38.4** | |

⚠️ **These are design targets.** Nothing here has been simulated, synthesized,
or placed and routed. Replace them with measured figures per
[manuals/05-optimization/04-measurement-and-profiling.md](../../manuals/05-optimization/04-measurement-and-profiling.md)
before anyone treats them as real.

### The one variable-latency stage
Deleting the **current best** level forces a search for the new best. This is the
only variable-latency operation in the entire tick-to-trade path. It is bounded
at **one extra cycle** (asserted in `top_of_book.sv`) and counted in
`stat[11]`, so the jitter is measured rather than assumed.

It is cheap only because of the **occupancy bitmask**: finding the new best is a
priority-encode over 16 bits, not a comparator tree over 16 quantities. Without
that mask this stage would dominate the budget.

---

## 4. Memory budget

| Structure | Arithmetic | Bits | Estimate |
| --- | --- | --- | --- |
| Order map | 4 ways × 16384 sets × ~140 b | ~9.2 Mb | ~32 URAM288 |
| Price levels | 256 sym × 2 sides × 16 lvl × 32 b | 262 kb | ~8 BRAM36 |
| Occupancy masks | 256 × 2 × 16 b | 8.2 kb | ~8192 FF |
| Best level/qty/px | 256 × 2 × (4+32+32) b | 34.8 kb | ~35 k FF |
| Window base | 256 × 2 × 32 b | 16.4 kb | LUTRAM |

> **Verify:** every figure above is an estimate from first principles. Only the
> post-synthesis utilization report is authoritative.

The order map dominates, and its size is set by `ORDER_MAP_ENTRIES` in
[trading_pkg.sv](../pkg/trading_pkg.sv). Size it from **real ITCH order-count
statistics** for your symbol set (`tools/pcap/stats.py`), not from a guess —
undersizing it does not degrade gracefully, it corrupts the book.

---

## 5. Telemetry — `stat[16]`

| Idx | Counter | Meaning |
| --- | --- | --- |
| 0 | events in | book events received |
| 1 | inserts | orders added to the map |
| 2 | deletes | orders removed |
| 3 | ⚠️ insert failures | set full — **book is now stale** |
| 4 | ⚠️ reference misses | unknown order ref — **book is now stale** |
| 5 | map forwards | RMW bypasses taken |
| 6 | ways high-water | order-map occupancy, for capacity sizing |
| 7 | ⚠️ out-of-window | price outside the maintained level window |
| 8 | ⚠️ underflow | level quantity saturated at zero |
| 9 | level forwards | RMW bypasses taken |
| 10 | re-anchors | window base re-established |
| 11 | best rescans | the jitter source — histogram this |
| 12 | ⚠️ crossed | crossed book observations |
| 13 | ⚠️ replay collisions | Replace injection collided with a new event |
| 14 | top changes | genuine top-of-book moves |
| 15 | replays | ITCH `U` injections |

Counters marked ⚠️ are **alertable in production**. A nonzero value in 3, 4, 7 or
8 means the book is not trustworthy.

---

## 6. Known limitations — read before deploying

1. **The window base is auto-anchored.** `price_levels.sv` anchors the level
   window to the first price seen on a side after a clear, and re-anchors only
   when that side is empty. A symbol that gaps hard intraday will push the true
   top of book outside the window while the side is still occupied, and
   top-of-book will report a stale best. **The correct design is a host-written
   per-symbol reference price**, refreshed from the last trade or previous close.
   `book_engine` has no cfg port in the current `fpga_top` contract, so adding
   one is a deliberate two-file change. Blocking item for Phase 4 in
   [TASKS.md](../../TASKS.md). Observable via `stat[7]` and `stat[10]`.

2. **Best quantity is cleared on a rescan.** When a best-level delete forces a
   new best, `top_of_book` sets the quantity to zero until the next update to
   that level refreshes it. The price is correct; the size is briefly understated.
   Fixing this needs a second read port on `price_levels` — a real cost, deferred
   deliberately rather than overlooked.

3. **Replace consumes two cycles.** ITCH `U` is injected as delete-then-add. The
   feed handler does not backpressure, so a sustained burst of Replace messages
   at line rate would overrun. Real Replace rates are far below that, but the
   collision is counted in `stat[13]` rather than assumed away.

4. **Bounded depth is deliberate.** 16 levels per side. Prices outside the window
   are counted and excluded from top-of-book. A hardware strategy acts on the top
   of book, not on depth 40 — but if yours needs more, `BOOK_LEVELS` is the knob
   and the memory arithmetic in §4 is the cost.

---

## 7. ⚠️ This block is not trustworthy until it is proven against the golden model

An order book cannot be validated by inspection or by unit tests over
hand-written cases. The only adequate test is **bit-exact equivalence against an
independent software implementation, over a real market-data corpus, asserted
after every single message**:

- Oracle: [tb/common/golden_book.py](../../tb/common/golden_book.py)
- Equivalence test: [tb/book/test_book_soak.py](../../tb/book/test_book_soak.py)
- Corpus: [tools/pcap/corpus.py](../../tools/pcap/corpus.py)

The corpus must include a normal day, a market open, a close, a halt, a volatile
session, and a session containing a real sequence gap. See
[manuals/06-operations/04-testing-strategy.md](../../manuals/06-operations/04-testing-strategy.md).

Until that passes over the full corpus, treat every number this block produces as
unverified.
