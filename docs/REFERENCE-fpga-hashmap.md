# Reference Study — adamwalker/fpga-hashmap

**Source:** https://github.com/adamwalker/fpga-hashmap
**Write-up:** https://adamwalker.github.io/Building-Better-Hashtable/
**Licence:** ⚠️ **AGPL-3.0**
**Local copy:** `reference/fpga-hashmap/` — **gitignored, deliberately not committed.** See §1.
**Status:** design study. No code from it has been copied into this project.

---

## 1. ⚠️ Licence — read before using any of this

The reference repository is **AGPL-3.0**. This project is **MIT** and its GitHub repository is
**public**. Those licences are not compatible in the direction that matters:

| Action | Allowed? | Consequence |
| --- | :-: | --- |
| Read the code and learn from it | ✅ | Ideas and architecture are not copyrightable |
| Describe its architecture in our own words | ✅ | This document |
| **Copy or adapt its source into `rtl/`** | ❌ | Our RTL becomes a derivative work and **must be relicensed AGPL-3.0** |
| **Commit its source into this MIT repo** | ⚠️ | Legal as aggregation, but muddies provenance and mis-signals licence |

AGPL §13 additionally requires that anyone interacting with the software **over a network** be
offered the corresponding source. For a proprietary trading system that is normally
disqualifying — it is precisely the clause that makes AGPL unsuitable for commercial
server-side software.

**Decisions taken:**

1. `reference/` is in `.gitignore`. The clone stays local for study; it is not distributed
   with this repository, so no AGPL code is redistributed and no provenance ambiguity is
   created.
2. **Clean-room discipline applies.** We may adopt the *architectural idea* described in §3 —
   ideas are free — but `rtl/book/order_id_map.sv` must be written independently, from this
   description, without transcribing its expression: no copied module structure, port names,
   signal names, loop shapes, or comments.
3. If anyone decides to vendor the code directly instead, that is a **licence change for the
   whole project** and needs an explicit decision, not a commit.

> ⚠️ If you are a future contributor and you find yourself with both files open, stop. Write
> from this document, not from the source.

---

## 2. What it is

A 4-table cuckoo hashtable in SystemVerilog, ~980 lines, with a SymbiYosys formal proof and a
Rust/Verilator simulation harness.

```
src/hashmap.sv   325  top level: lookup path, forwarding, ring plumbing
src/column.sv    390  one cuckoo table: RAM, insert/evict logic
src/crc.sv        46  generic combinational CRC, compile-time LUT
src/ram.sv        42  RAM wrapper (RAM_STYLE = "ultra" → URAM)
formal/formal.sv 180  the authoritative specification
```

Parameters: `NUM_TABLES=4`, `NUM_ADDR_BITS=12`, `NUM_KEY_BITS=32`, `NUM_VAL_BITS=32`,
`NUM_PIPES=2`, `RAM_STYLE="ultra"`.

---

## 3. The idea that matters — cuckoo as a systolic ring

This is the part worth taking, and it directly refutes an objection recorded in our own
manuals.

Each table is a `column` module with an eviction input and an eviction output:

```
        ┌──────────┐   ev_out   ┌──────────┐   ev_out   ┌──────────┐
insert ─►│ column 0 │───────────►│ column 1 │───────────►│ column 2 │──┐
        └──────────┘            └──────────┘            └──────────┘  │
             ▲                                                         │
             └─────────────────── ev_out ◄─────────── column 3 ◄───────┘
```

An evicted key/value pair is not handled by a controller — it is simply **passed to the next
column, and circulates the ring until it lands in a free slot.** Consequences:

| Property | Why it follows |
| --- | --- |
| No displacement FSM | The ring *is* the algorithm |
| No cycle detection | A circulating item is not an error state, it is normal traffic |
| No central arbiter | Each column decides locally |
| Lookups unaffected | A lookup asserts for one cycle and suspends inserts, not the reverse |
| Backpressure is dataflow | `busy` accumulates along the ring; inserts stall, lookups never do |

### 3.1 The forwarding property

From the module header:

> *"Under the hood, the insert operation takes a variable amount of time, but values are
> forwarded so that the key/value pair appears to be immediately available for lookups,
> modifications and deletes."*

An item may be mid-circulation and a lookup for it still hits, because in-flight entries are
forwarded from the pipeline registers rather than only from RAM.

⚠️ **This is exactly the property I told the R1 agent it had to prove** before a decoupled
cuckoo insert could be considered safe. It is provable, and here it is proven — `formal/`
asserts key presence and value correctness against a shadow model.

### 3.2 The read-modify-write protocol

`lookup` → *NUM_PIPES cycles* → `modify` / `del`. Modifications are forwarded to subsequent
lookups so back-to-back operations on the same key behave correctly.

This maps directly onto our ITCH problem, which is the same shape:

| ITCH message | Operation |
| --- | --- |
| Add Order (A/F) | `insert` |
| Order Executed (E/C), Cancel (X) | `lookup` → `modify` |
| Delete (D) | `lookup` → `del` |
| Replace (U) | `lookup` → `del`, then `insert` |

And the forwarding solves the back-to-back same-order-reference hazard we identified
independently in `docs/ORDER-BOOK-REDESIGN.md` §2.4.

⚠️ One constraint to note: *"It is illegal to insert a key that is already inserted."* ITCH
should never re-add a live order reference, but a feed gap can make it appear to. Our design
must either guarantee this or check it — silently double-inserting corrupts the table.

---

## 4. What this settles

Our own deep-dive manual rejects cuckoo:

> `manuals/09-deep-dives/05-hash-tables-and-lookup-structures.md` §6:
> *"Cuckoo, d=2, bucket 4, bounded K — insert: bounded K, but K RMWs ≫ 1 cycle …
> **Rejected — the insert path is real-time**"*

**That objection is valid against the design it assumed, and not against this one.** It
evaluated cuckoo-with-a-displacement-FSM: a controller performing K sequential
read-modify-writes while the pipeline waits. The ring is a different machine — the relocation
is dataflow that runs *alongside* the lookup path rather than blocking it, and forwarding makes
the variable insert latency invisible to readers.

So the conflict between the manual and the external architecture review dissolves:

- The **manual** was right that a blocking cuckoo insert is unacceptable here.
- The **review** was right that cuckoo is the correct structure.
- The missing piece in both was the *ring plus forwarding* topology.

`manuals/09-deep-dives/05-*.md` §6 and §12 rule 11 need revising to say this, rather than
rejecting cuckoo outright.

---

## 5. Other techniques worth adopting

| Technique | Where it helps us |
| --- | --- |
| **Generic combinational CRC with a compile-time LUT** (`crc.sv`) — polynomial and width parameterised, LUT built by a `function` at elaboration | Gives genuinely independent hash functions per table by varying `POLY`. Directly answers our concern that `h1` must not be a trivial transform of `h0`. |
| **Formal spec as the authoritative definition** — the header defers to `formal.sv` for unambiguous semantics | We have `rtl/formal/` with one file. This is the model: the properties *are* the spec, and prose defers to them. |
| **`RAM_STYLE = "ultra"` as a parameter** | Matches our URAM budgeting; lets a small instance drop to BRAM without an edit. |
| **Rust + Verilator simulation harness** | An alternative to our cocotb approach for high-throughput randomised soak. |

---

## 6. What does *not* transfer

| Their design | Our requirement |
| --- | --- |
| `NUM_KEY_BITS = 32` | We need **64-bit** ITCH order references |
| `NUM_VAL_BITS = 32` | We need `{sym, side, price, qty}` ≈ 74 bits |
| `NUM_ADDR_BITS = 12` → 4 × 4096 = 16k entries | We need 100k–500k entries. Sizing must come from measured ITCH statistics. |
| 4 tables × 1 slot | Consider 2 tables × 4 slots, or 4 × 4 — different load-factor and read-width trade-off |
| Insert may stall (`busy`) | ⚠️ **Our RX path cannot backpressure.** A stalled insert must not stall the feed. This is the one place their contract does not fit ours and it needs its own design decision — probably an insert FIFO sized against measured Add Order burst rates. |

⚠️ That last row is the real open question. Their `busy` is legitimate for a general hashtable;
for us, market data does not stop. We need to bound the insert queue against a measured burst
profile and decide what happens if it fills — which, per our fail-closed rule, means staling the
book rather than dropping an order.

---

## Further reading

- [docs/ORDER-BOOK-REDESIGN.md](ORDER-BOOK-REDESIGN.md) — the redesign this informs
- [manuals/04-system-architecture/03-order-book-in-hardware.md](../manuals/04-system-architecture/03-order-book-in-hardware.md)
- [manuals/09-deep-dives/05-hash-tables-and-lookup-structures.md](../manuals/09-deep-dives/05-hash-tables-and-lookup-structures.md) — ⚠️ §6 needs revising per §4 above
- [manuals/01-fpga-design/05-verification-and-simulation.md](../manuals/01-fpga-design/05-verification-and-simulation.md)
