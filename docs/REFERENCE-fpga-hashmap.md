# Reference Study — adamwalker/fpga-hashmap

**Source:** https://github.com/adamwalker/fpga-hashmap — commit `e5a71ca` (local clone)
**Write-up:** https://adamwalker.github.io/Building-Better-Hashtable/
**Licence:** ⚠️ **AGPL-3.0** (GNU Affero GPL, Version 3, 19 November 2007 — verified from `LICENSE.txt`)
**Local copy:** `reference/fpga-hashmap/` — **gitignored, deliberately not committed.** See §1.
**Status:** design study. No code from it has been copied into this project.
**Scope:** every file in the repository was read. §2.2 records exactly what was executed and
what is quoted from the author.

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

1. `reference/` is in `.gitignore` (line 110, under a banner that states why). The clone stays
   local for study; it is not distributed with this repository, so no AGPL code is
   redistributed and no provenance ambiguity is created.
2. **Clean-room discipline applies.** We may adopt the *architectural ideas* described below —
   ideas are free — but [`rtl/book/order_id_map.sv`](../rtl/book/order_id_map.sv) must be
   written independently, from this description, without transcribing its expression: no
   copied module structure, port names, signal names, loop shapes, or comments.
3. If anyone decides to vendor the code directly instead, that is a **licence change for the
   whole project** and needs an explicit decision, not a commit.

⚠️ **New hazard, found while reading: the RTL files carry no per-file licence notice.**
`src/*.sv`, `formal/*.sv`, `demo/*.sv` and `synth/*.sv` have no SPDX identifier and no
copyright header — the AGPL grant lives only in the root `LICENSE.txt`. A fragment lifted out
of one of those files therefore arrives in our tree carrying **no marker at all**, and a
reviewer diffing `rtl/book/` has nothing to notice. This does not weaken the licence in the
slightest; it removes the tripwire. Treat "it had no header so I assumed it was fine" as a
foreseeable failure and do not rely on inspection to catch it.

> ⚠️ If you are a future contributor and you find yourself with both files open, stop. Write
> from this document, not from the source.

---

## 2. What it is

### 2.1 Inventory

A **`d = 4` × `b = 1` cuckoo hashtable** in SystemVerilog: four single-slot tables, one CRC
hash each, with the displacement chain implemented as a **closed systolic ring of pipeline
stages** rather than as a controller. Line counts verified with `wc -l`:

| File | Lines | Role |
| --- | ---: | --- |
| `src/hashmap.sv` | 325 | Top level: ring plumbing, insert injection, lookup result merge, modify/delete forwarding |
| `src/column.sv` | 390 | One table. RAM trio, delayed-eviction shift register, three forwarding networks, write-port sharing |
| `src/crc.sv` | 46 | Generic combinational CRC. Elaboration-time LUT, parameterised polynomial/width |
| `src/ram.sv` | 42 | 1R1W array with configurable read-pipeline depth and a `RAM_STYLE` attribute |
| `formal/formal.sv` | 180 | Shadow-model specification — the *authoritative* semantics per the header |
| `formal/hashmap.sby` | 31 | SymbiYosys: `bmc` depth 20 + `cover`, engine `smtbmc boolector` |
| `sim/src/main.rs` | 453 | Rust oracle-differential harness over Verilator |
| `sim/src/lib.{cpp,hpp}` | 70 + 21 | `cxx` FFI shim to the Verilated model |
| `sim/build.rs`, `Cargo.toml`, `src/CMakeLists.txt` | 33 + 18 + 43 | Verilate-via-CMake, link into the Rust binary |
| `synth/{top,compile,timing}.{sv,tcl}` | 77 + 42 + **1** | Standalone timing/logic-depth harness for `xcku3p-ffvb676-2-e` |
| `demo/{top.sv,compile.tcl,constraints.xdc}` | 87 + 102 + 6 | VIO/ILA interactive demo on the same part |

**803 lines of synthesisable RTL**, 180 lines of formal spec, 544 lines of harness.

Defaults: `NUM_TABLES = 4`, `NUM_ADDR_BITS = 12`, `NUM_KEY_BITS = 32`, `NUM_VAL_BITS = 32`,
`NUM_PIPES = 2`, `EN_INS_SEL = 1`, `RAM_STYLE = "ultra"` → 4 × 4096 = **16,384 entries**.

⚠️ The three build targets use **three different configurations**, and the differences matter
when quoting results:

| Target | `NUM_KEY_BITS` / `NUM_VAL_BITS` | `EN_INS_SEL` | `NUM_TABLES` / `NUM_ADDR_BITS` |
| --- | :-: | :-: | :-: |
| `sim/` (Rust harness, via `src/CMakeLists.txt` at module defaults) | 32 / 32 | 1 | 4 / 12 |
| `synth/` (**the source of the 350 MHz and "logic depth 8" figures**) | 64 / 64 | **0** | 4 / 12 |
| `demo/` (VIO/ILA) | 64 / 64 | 1 | 4 / 12 |
| `formal/` | 8 / 8 | 1 | **2 / 4** |

The published timing number is therefore for the **simple** insert-selection path, not the
one the demo and the formal proof use. See §9 and §10.

### 2.2 What was actually run for this study, and what is quoted

| Claim class | Status |
| --- | --- |
| Lint clean at defaults | **Ran.** `verilator 5.050 --lint-only -Wall --top-module hashmap` over all four `src/*.sv`: **0 errors**, 2 warnings — `UNUSEDSIGNAL` on `crc_out[31:12]` (`hashmap.sv:309`, the discarded high CRC bits) and `UNUSEDPARAM` on `ram.sv:6 RAM_STYLE` (Verilator ignores the attribute). Both benign. |
| "Maximum of 4 tables supported" | **Ran and confirmed the exact mechanism.** `-GNUM_TABLES=5` → `%Warning-SELRANGE ... hashmap.sv:313 ... index out of range: 4 outside 3:0`. The limit is literally the four-element `POLYS` array; nothing else in the design cares. `NUM_TABLES = 2` lints clean. |
| Parameter sweep lints | **Ran.** `NUM_PIPES = 1`, `NUM_PIPES = 3`, `NUM_TABLES = 2`, `EN_INS_SEL = 0` all elaborate clean. |
| GF(2) rank of both hash families | **Computed** (Python, GF(2) Gaussian elimination over the exact recurrences in `src/crc.sv` and [`rtl/book/book_pkg.sv`](../rtl/book/book_pkg.sv)). Results in §7.2. |
| Cycle-level behaviour of the ring and the forwarding networks | **Derived by reading**, then cross-checked against the formal model's timing. Marked *inferred* where I could not execute it. |
| SymbiYosys proof | ❌ **Not run.** `sby`, `yosys`, `boolector` and `bitwuzla` are all absent from this machine. §6 describes what the spec says, not that it passes. |
| Rust/Verilator harness | ❌ **Not run.** `cargo` is absent. §8 is a code reading. |
| Fmax / utilisation / load factor | ❌ **Not measured.** Every such figure below is the author's, marked with `> **Verify:**`. No Vivado on this machine, and no Vivado has ever run on this project. |

---

## 3. The systolic ring — the core idea

### 3.1 Topology

```
            insert (ins_key, ins_value)
                        │
                        ▼   [injection point selected by EN_INS_SEL]
   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
   │ column 0 │───►│ column 1 │───►│ column 2 │───►│ column 3 │──┐
   │  h = c0  │    │  h = c1  │    │  h = c2  │    │  h = c3  │  │
   └──────────┘    └──────────┘    └──────────┘    └──────────┘  │
        ▲                                                         │
        └───────────────── ev_out → ev_in ────────────────────────┘

   lookup / key / modify / del / mod_value  ──► broadcast to ALL columns
   lu_valid[i] / lu_value[i]                ◄── OR-merged at the top level
```

Each column owns one table and one hash. Its eviction output is wired straight into the next
column's eviction input, and the last column's output is wired back to the first. An item that
cannot land keeps going round.

There is **no displacement controller, no cycle detector and no arbiter** because there is
nothing for them to do — see §3.4.

### 3.2 The column as a systolic cell

A column is five things, all running every cycle:

| Element | Detail |
| --- | --- |
| Three 1R1W arrays | valid (1 bit, `RAM_STYLE="auto"` → BRAM/LUTRAM), key (`RAM_STYLE` param → URAM), value (same). Read latency = `NUM_PIPES` cycles, built as one RAM output register plus `NUM_PIPES-1` extra stages |
| Read-address mux | `lookup ? lookup_key : busy ? held_eviction_key : incoming_eviction_key` — **lookups have absolute priority on the read port** |
| Address delay line | `NUM_PIPES` deep. **The write address is the read address delayed by `NUM_PIPES`** — this is the single trick the whole design rests on |
| Delayed-eviction shift register | `NUM_PIPES` deep, carrying `{valid, key, value}` alongside the address delay line, so at the head the RAM data for that item has just arrived |
| Forwarding networks | Three of them — §4 |

The write-address trick deserves stating plainly: **the design never computes a write address.**
It re-uses the read address that was issued `NUM_PIPES` cycles earlier. That is what makes the
read and its dependent write automatically aligned for any pipeline depth, and it is why
`NUM_PIPES` is a free parameter rather than a rebuild.

An item's life inside one column:

```
 cycle T     : item arrives on ev_in. Its key is driven onto the read-address
               mux, so the RAM read for its bucket is issued this cycle.
 edge T      : item enters delayed_ev[0]; the bucket address enters addr_pipe[0].
 cycles T+1  : item and address shift down together, one stage per cycle.
   … T+NP-1
 cycle T+NP  : item is at the head. Its bucket's contents have just arrived from
               the RAM. Two outcomes, decided by ONE bit — see §3.3:
                 a) the writeback slot is free  → write the item into the bucket,
                    emit the previous occupant on ev_out (combinationally).
                 b) the writeback slot is taken by a lookup → recirculate the item
                    back to delayed_ev[0], re-issuing its read. Assert `busy`.
```

### 3.3 The one bit that runs everything, and why no arbiter is needed

Every column computes:

```
    column_busy = (head of the delayed-eviction register is valid) AND lookup_q[NUM_PIPES-1]
    evicting    = (head of the delayed-eviction register is valid) AND NOT lookup_q[NUM_PIPES-1]
```

`lookup_q[NUM_PIPES-1]` is the top-level `lookup` input delayed by `NUM_PIPES`. **It is
broadcast to every column and delayed identically in each**, so it has the same value in all
four columns on every cycle. That single fact is the whole arbitration story:

| `lookup_q[NP-1]` | Every column simultaneously | Consequence |
| :-: | --- | --- |
| `1` | can **not** evict, and is `busy` if it holds an item | The whole ring freezes for one cycle. Nothing is offered anywhere |
| `0` | evicts if it holds an item, and is **not** `busy` | Every column that emits has a guaranteed-free receiver |

**An eviction is therefore never offered to a column that cannot accept it.** Not by
arbitration, not by handshake, not by a credit scheme — by construction, because the gating
term is a global broadcast. This is the property that removes the FSM, and it is the thing to
carry away from this design even if nothing else is adopted.

> *Inferred by reading, not simulated.* The argument is short enough to check: `evicting`
> requires `!lookup_q[NP-1]`, `busy` requires `lookup_q[NP-1]`, and the two signals are the
> same net in every column.

One consequence that is easy to miss: because the ring only moves on cycles where no lookup
was issued `NUM_PIPES` cycles ago, **relocation in this design also needs idle cycles.** It
does not get them for free. What differs from our design is what happens when it does not get
them (§11.4).

### 3.4 Why there is no cycle detection

In a classical bounded-`K` cuckoo insert, a displacement cycle is an *error condition*: the
chain must be detected and terminated, or it spins forever inside one insert operation. Here
the chain is not inside an operation at all — it is a packet on a ring. A circulating item is
**indistinguishable from ordinary traffic**: it occupies one slot of one column's shift
register, it is searched by lookups the whole time (§4.2), and it costs one hop per idle cycle.

So the design does not detect cycles because a cycle is not a fault. What a cycle *does* cost:

| Effect of an item that never lands | Mechanism |
| --- | --- |
| Insert latency grows without bound | It just keeps going round |
| `busy` rises | Every circulating item occupies an eviction input somewhere |
| ⚠️ **No counter increments. No flag is raised. Nothing is reported.** | There is no telemetry anywhere in the design |

⚠️ **This is the reference's most serious omission for our purposes, and it is a direct
consequence of the elegance.** With a full table, items circulate forever, `busy` latches
high, and the hashtable **silently stops accepting inserts**. There is no `insert_fail`, no
occupancy gauge, no chain-length histogram — the failure is a *liveness* failure with no
observable. Our design converts the same condition into `cnt_insert_fail` + `map_stale`, which
is loud. See §11.4 and §11.8.

### 3.5 How `busy` accumulates

Two schemes, selected by `EN_INS_SEL`:

**`EN_INS_SEL = 0` (simple; used by `synth/`)**

```
busy = (an item is arriving from column NUM_TABLES-1) OR (column 0 is busy)
```

Inserts are injected only into column 0. One OR gate. The insert competes with the ring's
wrap-around for column 0's single eviction input.

**`EN_INS_SEL = 1` (default; used by `demo/` and `formal/`)**

```
masked[0]       = busy[0] OR (item arriving from column NUM_TABLES-1)
masked[i]       = busy[i] OR (item arriving from column i-1)
masked_accum[i] = masked[i] AND masked_accum[i-1]        ← serial AND chain
busy            = masked_accum[NUM_TABLES-1]
```

The insert is injected into the **first column whose eviction input is unoccupied**, and
`busy` rises only when *all* of them are occupied. Strictly better acceptance rate; the cost
is a serial AND chain of length `NUM_TABLES-1` **on top of** each column's
`eviction-output` mux, which itself depends on RAM read data and the conflict-forwarding
mux. That is a long combinational path and it is why the author's timing harness disables it.

> *Author's note, quoted:* "Performs slightly better on insertion heavy workloads at the cost
> of complexity and logic depth."

### 3.6 Reimplementation recipe

Enough to rebuild it from this description, without the source:

1. Build a 1R1W memory wrapper with a parameterised output-register count. Read latency `P`.
2. Per table, instantiate three of them: 1-bit valid, key-width, value-width, all sharing one
   read address and one write address.
3. Drive the read address from `hash(mux(lookup_key, held_key, incoming_key))` with the
   priorities of §3.2. Delay that address `P` cycles; **that delayed address is the write
   address.** Never compute a write address any other way.
4. Alongside the address delay line, shift `{valid, key, value}` for the item being placed.
5. At the head of both lines: if `lookup_delayed_by_P` is low and the head item is valid,
   write the head item into the bucket and emit the RAM's previous contents on the eviction
   output. Otherwise recirculate the head item to the front of the shift register and raise
   `busy`.
6. Wire eviction output *i* to eviction input *i+1*, and the last back to the first.
7. Broadcast `lookup`/`key`/`modify`/`del`/`mod_value` to every table; OR-merge `lu_valid`
   and mux `lu_value`.
8. Add the three forwarding networks of §4. **Without them the design is silently wrong**,
   not slow — items in flight become invisible and RAM read-before-write returns stale data.
9. Give each table a different hash of the same key.

The subtle part is step 8, not step 6.

---

## 4. The forwarding mechanism

There are **three independent forwarding networks**, and conflating them is the fastest way to
misunderstand the design. Only the second one is the "item is visible while in flight"
property; the other two are hazards created by solving it.

| # | Network | Lives in | Covers |
| :-: | --- | --- | --- |
| 1 | **RAM read/write conflict** | `column.sv`, per pipe stage | The RAM is read-before-write. A read issued in the same cycle as a write to the same address returns stale data. Only the *eviction* path needs it |
| 2 | **In-flight item visibility** | `column.sv` | An item sitting in a delayed-eviction shift register is not in any RAM. Lookups must still find it |
| 3 | **Modify/delete RMW** | `hashmap.sv` + `column.sv` | A modify lands in RAM `NUM_PIPES` cycles after its lookup, but must be visible to a lookup issued the cycle *after* that original lookup |

### 4.1 Network 1 — read/write conflict on the eviction path

The RAM does `if (write_en) values[waddr] <= wval; rdata <= values[raddr];` with non-blocking
assignments, so a same-cycle read returns the **old** value. For the eviction path that is
wrong: the value being evicted must be whatever is genuinely resident. So the column carries a
per-stage record of "was there a write to the address this read is chasing, and what was
written", and muxes it over the RAM output at the head.

⚠️ The lookup path deliberately does **not** use this network, and the reason is a genuine
invariant rather than an oversight: a bucket is only overwritten `NUM_PIPES` cycles after the
read that targeted it was issued, so a lookup's data is always sampled before any write that
could disturb it. The author states this in a comment; I checked it against the address delay
line and it holds. It is load-bearing — if `NUM_PIPES` were ever decoupled from the RAM read
latency, this silently breaks.

### 4.2 Network 2 — where an in-flight item actually lives

This is the property our design had to prove. Here is the exact answer.

Every cycle, every column compares the lookup key against **all `NUM_PIPES` entries of its
delayed-eviction shift register**, in parallel with its RAM read. A match produces the item's
value directly, delayed to align with the RAM read latency, and is muxed over the RAM result.

So the total in-flight storage is `NUM_TABLES × NUM_PIPES` = **8 slots at the defaults**, and
up to eight items can be relocating simultaneously.

**The handoff between columns — the case that decides correctness.** Column *i* is evicting at
cycle `T`:

| Cycle | Where the evicted item is | Found by a lookup issued that cycle? |
| :-: | --- | :-: |
| ≤ `T` | In column *i*'s RAM. The overwriting write does not land until edge `T` | ✅ RAM read (read-before-write returns the old occupant) |
| `T` (combinational) | Also on the wire from `ev_out[i]` to `ev_in[i+1]` | (same as above — it is still in RAM) |
| ≥ `T+1` | In column *i+1*'s delayed-eviction shift register, stage 0 | ✅ Network-2 compare |

**There is no cycle in which the item is in neither structure.** The read-before-write
behaviour of the RAM is not an incidental detail — it is what makes the handoff seamless, and
a RAM primitive configured for write-first would break this design silently.

**Comparison with ours.** [`rtl/book/order_id_map.sv`](../rtl/book/order_id_map.sv) solves the
same problem with a different shape:

| | Reference | `order_id_map.sv` |
| --- | --- | --- |
| In-flight storage | Distributed: `NUM_TABLES × NUM_PIPES` = 8 shift-register slots | Central: one `carry_q` register + 16-entry stash |
| Max concurrent relocations | **8** | **1** (enforced by the `!carry_q.valid` guard on `BG_IDLE`) |
| Where the compare happens | Per column, merged at the top | One flat 25-way comparator bank |
| Correctness argument | Per-column handoff timing, four instances, subtle | Single-holder invariant: the record is in `stash_q[bg_src_q]` **or** `carry_q`, never neither, never both. One SVA states it |
| Cost | 8 × (key + value) registers + 8 key comparators | 17 × 138-bit records + 17 comparators |
| Auditability | You must reason about read-before-write timing to believe it | You can read the invariant off one assertion |

**Verdict: a real trade-off, and ours is right for us.** Their 8-way in-flight capacity is
what lets them survive with no stash at all (§11.4); the price is that the safety argument is
a timing argument distributed across four module instances. Ours is 8× slower at relocating
and needs the stash to compensate, but the property is stated as an invariant rather than
derived from pipeline alignment — and for a module that "has never been simulated, synthesized,
or run on hardware" (its own header), an auditable invariant is worth more than throughput.

### 4.3 Network 3 — the read-modify-write forwarding

A modify or delete is presented `NUM_PIPES` cycles after its lookup and writes RAM in that
same cycle. But a *new* lookup for the same key issued in that cycle already read RAM before
the write, and a lookup issued in the intervening cycles read it earlier still. All of them
must see the modification.

The top level therefore keeps a `NUM_PIPES`-deep forwarding table recording, for each
in-flight lookup, whether a modification to *its* key has since been accepted, the new value,
and an accumulated delete flag. At the output, if the raw table lookup hit, the forwarded
value overrides it.

⚠️ **The forward is qualified by a raw table hit** — the author's comment: *"Only forward if
the (possibly stale) key was actually found in a table. This prevents the case where we forward
a modification present in the forwarding tables above, but it was never actually inserted."*
This is subtle and correct: without the qualifier, a modification recorded for a key that was
concurrently deleted would resurrect it.

⚠️ **The key RAM is not written on a modify or a delete.** Only the value and the valid bit
change. A delete therefore leaves the key resident with `valid = 0`. Functionally fine; worth
knowing if you ever scrub or dump the table.

### 4.4 ⚠️ A specification contradiction in the reference, resolved

`src/hashmap.sv` header:

> *"If a lookup and an insert to the same key take place in the same cycle, then the insert is
> considered to have happened first."*

`formal/formal.sv`:

> *"if a lookup and insert take place in the same cycle, with the same key, the lookup is
> considered to have taken place before the insert, ie the lookup is a miss."*

These say opposite things. The header itself defers to `formal.sv` for "the ultimate
unambiguous specification", so I traced the shadow model's pipeline arithmetic:

```
 insert at cycle T   →  f_valid[NUM_PIPES] set at T+1  →  reaches f_valid[0] at T+1+NUM_PIPES
 lookup at cycle T   →  checked against f_valid[0] at  T+NUM_PIPES
 T+NUM_PIPES < T+1+NUM_PIPES   ⇒   the lookup does not see the insert
```

**The formal model makes a same-cycle lookup a MISS. The header prose is wrong.** The header's
own preceding sentence — *"Once inserted, the key/value pair is considered to be in the
hashtable on the next cycle"* — agrees with the formal model, so the offending sentence appears
to be an editing slip.

This matters to us because it is exactly the class of ambiguity that produces a
working-but-wrong integration: a consumer that issues `lookup(K)` and `insert(K)` in the same
cycle expecting a hit gets a miss, and the resulting book divergence looks like a hash bug.
Our own contract must state this case explicitly rather than inherit the ambiguity — see
§12.6.

---

## 5. The lookup / modify / delete protocol

### 5.1 The contract

| Signal | Cycle | Meaning |
| --- | --- | --- |
| `lookup`, `key` | `T` | Initiate. **Suspends any eviction that would have used the writeback slot at `T+NUM_PIPES`** — it does not stall the lookup |
| `valid`, `value` | `T + NUM_PIPES` | Result, reflecting hashtable state **as of cycle `T`** |
| `modify`, `del`, `mod_value` | `T + NUM_PIPES` | Act on the entry the lookup located. **Must be preceded by the lookup** — the lookup is what found the address |
| `insert`, `ins_key`, `ins_value` | any cycle with `!busy` | Visible to lookups from `T+1` |
| `busy` | — | ⚠️ Blocks **inserts only.** Lookups, modifies and deletes are never blocked |

The lookup is what carries the address forward; the modify simply reuses the address delay
line. That is why `modify` cannot be issued standalone, and it is a genuinely economical
design: **a modify costs no extra memory port and no address computation.**

### 5.2 Back-to-back same-key read-modify-write

```
 cyc 0 : lookup(K)
 cyc 1 : lookup(K)                        ← reads RAM before cyc-2's write lands
 cyc 2 : valid/value for cyc-0 lookup;  modify(K, V1)   → writes RAM, and records
                                          "K became V1" against the cyc-1 lookup
 cyc 3 : valid/value for cyc-1 lookup   ← RAM said the OLD value; network 3 patches
                                          it to V1.  modify(K, V2) may issue here.
```

The semantics the author chose: *"modifications and deletes … are forwarded to subsequent
lookups so that they appear to have taken effect by the cycle after the initial lookup took
place"*, i.e. modifications are **mapped backwards in time** to the cycle after their lookup.

⚠️ The author flags this himself in `formal.sv`: *"This is a bit trippy and complicates the
formal model as well as the forwarding logic in the hashtable. Is it actually a good idea?"*
It is a fair question, and for us the answer is **no** — we do not need it (§5.3).

### 5.3 Mapping onto ITCH, honestly

| ITCH | Reference protocol | `order_id_map` today | Fit |
| --- | --- | --- | --- |
| `A` / `F` Add Order | `insert` — but only when `!busy`, and **illegal if the key is already present** | `BOOK_ADD`, fixed 2 cycles, never blocked; duplicate detected and staled | ⚠️ `busy` is unusable for us (§11.4); duplicate handling is ours (§11.6) |
| `E` / `C` Executed | `lookup` → `modify` with reduced quantity | `BOOK_EXECUTE`, single request, engine computes the reduction internally | Ours is one message; theirs is two bus cycles the caller must schedule |
| `X` Cancel | `lookup` → `modify` | `BOOK_CANCEL` | Same |
| `D` Delete | `lookup` → `modify` with `del` | `BOOK_DELETE`, direct | Same |
| `U` Replace | `lookup` → `modify+del`, then a separate `insert` for the new reference | `BOOK_REPLACE` is a **pure delete**; `book_engine` injects a synthetic `BOOK_ADD` on the next cycle | Structurally identical. Ours moved the split up into the engine; theirs leaves it to the caller |

**The important structural difference is not the message mapping — it is who owns the
read-modify-write.** The reference exposes a *raw* RMW: the caller must issue the lookup,
wait `NUM_PIPES`, decide, and drive `modify`/`del`/`mod_value`. Our map swallows the whole RMW
inside one request: `book_engine` sends `BOOK_EXECUTE` with a delta and gets back
`res_delta` / `res_remove` two cycles later, with the saturating-reduce and
full-consume-implies-delete decisions made in the map.

| | Reference (caller-owned RMW) | Ours (map-owned RMW) |
| --- | --- | --- |
| Bus cycles per `E`/`C`/`X`/`D` | 2 (lookup, then modify) | 1 |
| Who knows "execution ≥ resting qty means delete" | The caller | The map |
| Generality | A general hashtable — any value semantics | ITCH-specific |
| Forwarding burden | Network 3 must map modifications backwards in time | ⚠️ **None.** Our one-deep `fwd_*_q` covers it because a mutation is driven combinationally in the same stage that reads |

**Verdict: ours is better *for this application*, and the reason is worth stating.** Because
our request carries the operation *and* its operand, the mutation is decided in the same
pipeline stage as the compare, so the write and the result register at the same edge and the
bypass is exactly one deep. The reference's protocol forces a modification to arrive
`NUM_PIPES` cycles late, which is precisely why it needs the "trippy" backwards-in-time
forwarding table its own author questions. **Their complexity is a consequence of their
generality.** We are not writing a general hashtable and should not import the cost of being
one.

⚠️ The counter-argument, stated so it is not lost: the reference's split protocol means a
caller can *decide* between modify and delete after seeing the value. Ours cannot — the
decision rule is baked into the map. If a future ITCH semantic needs a decision our map does
not implement, that is an RTL change, not a caller change.

---

## 6. The formal specification

`formal/formal.sv` is 180 lines and is, per the design's own header, the authoritative
definition of its behaviour. It is the single most transferable artefact in the repository.

### 6.1 The shadow-model technique

It uses the ZipCPU one-key trick (cited in the file: `zipcpu.com/zipcpu/2018/07/13/memories.html`):

```
    (* anyconst *) logic [NUM_KEY_BITS-1:0] f_key;
```

The solver picks **one arbitrary but constant key** and the proof tracks only that key. Since
the key is unconstrained, proving correctness for it proves it for all of them — but the model
state is a couple of registers instead of a shadow copy of a 16,384-entry table. This is the
technique that makes the proof tractable at all, and it is directly reusable by us.

The shadow model is two shift registers:

| Model state | Represents |
| --- | --- |
| `f_valid[NUM_PIPES+1]`, `f_value[NUM_PIPES+1]` | Whether `f_key` is present and its value, pipelined so index 0 is the state as of the lookup that is completing now. One entry longer than the lookup pipe — that extra stage is what encodes "same-cycle lookup misses" (§4.4) |
| `f_past_lookup[NUM_PIPES]` | Which completing results correspond to a lookup of `f_key`, i.e. when to check |

Modifications are written back into **every** stage of the model pipeline at once, which is
the model-side expression of "the modify is deemed to have happened the cycle after its lookup".

### 6.2 What it proves

| # | Property | Form |
| :-: | --- | --- |
| 1 | Key presence is correct | `f_past_lookup[0] ⇒ (f_valid[0] == valid)` |
| 2 | Key value is correct | `f_past_lookup[0] && f_valid[0] ⇒ (f_value[0] == value)` |
| 3 | At most one table reports a hit for `f_key` | Inside `hashmap.sv`, under `` `ifdef FORMAL `` |
| 4 | A RAM match and a bypass match are never both asserted for `f_key` | Inside `column.sv`, under `` `ifdef FORMAL `` |
| C1 | Lookups actually happen | `cover(f_past_lookup[0])` |
| C2 | The design is not permanently busy | `cover(!busy)` |

The two covers are there for a specific reason the author names: *"The hashtable could satisfy
some assertions if, for example, it constantly asserted busy and nothing was ever inserted."*
That is exactly the right instinct — an assertion suite with no covers proves that a dead
design is correct.

### 6.3 The single `assume`

```
    if (ins_key == f_key && !busy && insert)
        assume(!f_valid[NUM_PIPES]);        // "it is illegal to insert a key already present"
```

**One assume, and it is the design's stated precondition.** Everything else — `insert`,
`lookup`, `key`, `modify`, `del`, `mod_value`, and their timing relationships — is left free
for the solver. That is unusually disciplined. Our own
[`rtl/formal/fv_axis_props.sv`](../rtl/formal/fv_axis_props.sv) header states the same rule
("Every assume … carries a one-line justification comment. An assume without one is a
review-blocking defect") and the reference is a working demonstration of it.

### 6.4 The SymbiYosys setup

```
    tasks   : bmc, cover
    bmc     : mode bmc, depth 20
    engine  : smtbmc --nopresat boolector -- --noincr
    script  : read -formal {ram,column,hashmap,formal}.sv ; prep -top formal
```

The blog says a **12-cycle** bounded model check was used; the checked-in `.sby` says
**depth 20**. Both are shallow by construction — the point is fast counterexamples, and the
author reports that this caught every bug before simulation, with *"traces less than 10 cycles
long"* instead of thousand-cycle simulation traces.

> **Verify:** the proof was **not run for this study** — `sby`, `yosys` and `boolector` are
> absent from this machine. Everything in §6.2–§6.4 is read from the source, not observed to
> pass.

### 6.5 ⚠️ What the proof does NOT cover

This is the most important subsection in §6, because the proof is easy to over-trust.

| Gap | Detail | Severity for us |
| --- | --- | --- |
| ⚠️ **The hash is not the real hash** | Under `` `ifdef FORMAL ``, `hashmap.sv` replaces every CRC with a 4-bit slice of the key: `assign hash = hash_key[i*4 +: 4]`. The author is explicit that Yosys's open-source SystemVerilog front end cannot parse `crc.sv`, and that *"the bounded model check isn't really valid otherwise"* because uninterpreted functions are unavailable | **Medium.** The proof is about the *plumbing*, not the hashing. It is still the right thing to prove — the plumbing is where the bugs are — but it says nothing about collision behaviour |
| ⚠️ **Bounded, not inductive** | `mode bmc` at depth 20. No `mode prove`, no induction, no `k`-induction step | **High if quoted as "proven".** A bug that needs 21 cycles of table state to expose is outside the proof. Table-filling behaviour is unreachable at this depth |
| ⚠️ **Tiny configuration** | `NUM_KEY_BITS=8`, `NUM_VAL_BITS=8`, `NUM_TABLES=2`, `NUM_ADDR_BITS=4` → 32 entries | **Medium.** Correct for tractability; means nothing about the 4-table ring the design ships |
| **No liveness** | Nothing asserts that an inserted item ever settles into a RAM, or that `busy` ever falls after rising. `cover(!busy)` shows it *can* fall, not that it *must* | **High for us.** Our failure mode of interest is precisely "the stash stops draining" |
| **No resource/occupancy properties** | No bound on how many items are in flight, no conservation-of-population property | **High for us.** Ours asserts population conservation across a kick, which is the property that distinguishes relocation from eviction |
| **The precondition is assumed, not checked** | Duplicate insert is `assume`d away. Nothing proves what happens if a caller violates it | **High for us.** ITCH after a gap can present a duplicate add — see §11.6 |

### 6.6 ⚠️ Concretely, what we should adopt

Our formal collateral today is **one file**,
[`rtl/formal/fv_axis_props.sv`](../rtl/formal/fv_axis_props.sv) (444 lines) — reusable
AXI-Stream contract properties. Reading it against the reference exposes three gaps:

1. ⚠️ **It is never bound to anything.** Its own header repeatedly refers to `fv_bind.sv`
   (§5, and the assume-justification rule). **`rtl/formal/fv_bind.sv` does not exist.**
   `ls rtl/formal/` returns exactly one file. The properties are written and unused.
2. ⚠️ **There is no runner.** `find . -name '*.sby'` outside `reference/` returns nothing.
   There is no formal target in any script.
3. **It is a *protocol* property module, not a *functional* specification.** Its own header
   says so: *"It checks the handshake, not the payload."* `order_id_map` has no handshake —
   it has `req_valid` in and `res_valid` out at a fixed 2-cycle offset — so `fv_axis_props`
   cannot say anything about it at all.

The concrete adoption, in order:

| Do this | Modelled on | Why |
| --- | --- | --- |
| Write `rtl/formal/fv_order_id_map.sv` — a shadow model of **one `(* anyconst *)` order reference** through `order_id_map` | `formal/formal.sv` | It is the only tractable way to specify a 65,536-slot table. Our 32 `assert property` statements are all *internal consistency*; not one of them says "a lookup returns the record that was inserted" |
| Add `rtl/formal/order_id_map.sby` with `bmc` and `cover` tasks | `formal/hashmap.sby` | 31 lines. Without a runner the properties are documentation |
| Prove at a **shrunken** geometry: `N_BUCK = 8`, `N_STASH = 2`, `MAX_KICKS = 2`, narrow key/qty | The reference's 32-entry proof config | Our defaults are unprovable. ⚠️ `N_TABLE` must stay 2 — the module `$error`s at elaboration otherwise |
| Include `cover` for: stash insert taken, a kick performed, a chain exhausted, `map_stale` never set | `cover(!busy)`, `cover(f_past_lookup[0])` | Our terminal paths are the ones no test will reach by accident. A suite with no covers proves a dead design correct |
| ⚠️ **Do not** assume away the duplicate add | Their single `assume` | It is legal for them and a real ITCH event for us. Ours must *prove* the duplicate is detected, not assume it away |
| ⚠️ Replace the CRC with an uninterpreted-ish stand-in under `` `ifdef FORMAL ``, and **say so in the file** | Their honest `hash_key[i*4 +: 4]` note | The reference documents its own proof's biggest limitation in a comment. Copy that discipline, not the code |
| Add the one property they do not have: **liveness of the drain** | — | `bg_fail_now` bounded, stash occupancy non-increasing under an idle request stream. This is our failure mode, and they have no analogue because they backpressure instead |

---

## 7. The CRC hash

### 7.1 How theirs works

`src/crc.sv` is 46 lines and is the cleanest idea in the repository after the ring.

An elaboration-time `function` builds a lookup table whose entry *i* is the CRC register's
response to a single `1` at input bit *i*:

```
    lut[0]   = POLY
    lut[i+1] = (lut[i] << 1) XOR (POLY if lut[i] MSB set else 0)
```

The combinational output is then

```
    crc_out = XOR over i of ( lut[i] AND replicate(data_in[i]) )
```

which is exactly a GF(2) matrix-vector product: each output bit is the parity of a fixed
subset of input bits, and synthesis flattens it into a 2–3 level XOR tree. The author's own
header states the cost precisely: *"each output bit is an XOR tree function of half of the
input bits on average."*

Independent hashes per table come from **four different generator polynomials**:
`0x04C11DB7` (CRC-32/IEEE 802.3), `0x1EDC6F41` (CRC-32C/Castagnoli), `0x741B8CD7` (CRC-32K),
`0x32583499`. The bucket index is the low `NUM_ADDR_BITS` bits of the 32-bit result.

⚠️ The polynomials are a `localparam` array **inside a generate loop**, not module parameters.
The author says why: *"limitations of the open source YOSYS SystemVerilog parser prevent this."*
That array is the entire reason for "Maximum of 4 tables supported" — confirmed by lint (§2.2).

⚠️ **There is no seed and no final XOR.** `crc(0) = 0`, so the all-zero key maps to bucket 0
in every table simultaneously. Harmless for a general table (it is one key); worth knowing.

### 7.2 Measured GF(2) rank — ours and theirs

Both hash families are GF(2)-linear, so "are the hashes independent?" has an exact answer:
stack the selected output bits as rows of a matrix over GF(2) and take the rank. Full rank
means no linear relation ties one table's bucket index to another's.

**Computed for this study** (Python, exact Gaussian elimination over GF(2), reproducing the
recurrences in `book_pkg::map_crc32` and `src/crc.sv` bit-for-bit):

**Ours — `book_pkg`, 64-bit key, `h0` = CRC-32C low bits, `h1` = CRC-32 high bits:**

| Quantity | Rank | Verdict |
| --- | ---: | --- |
| `h0` alone (32 outputs) | **32** / 32 | full |
| `h1` alone (32 outputs) | **32** / 32 | full |
| `[h0 ; h1]` stacked (64 outputs) | **64** / 64 | ✅ jointly independent — no linear relation whatsoever |
| Selected bucket bits at `BUCK_W = 12` | **24** / 24 | ✅ |
| Selected bucket bits at `BUCK_W = 13` (**current default**) | **26** / 26 | ✅ |
| Selected bucket bits at `BUCK_W = 14` | **28** / 28 | ✅ |
| Selected bucket bits at `BUCK_W = 16` | **32** / 32 | ✅ |

**Our hash pair is provably independent, at every capacity we might choose.** This is a
stronger statement than the 1024-key agreement smoke test in `order_id_map.sv`, and it is
cheap to compute.

**Theirs — 4 polynomials, low 12 bits each:**

| Key width | All 4 × 12 = 48 selected bits | Every pair (24 bits) |
| :-: | ---: | ---: |
| 32 (`sim/` and module default) | rank **32** / 48 ⚠️ | 24 / 24 ✅ (all six pairs) |
| 64 (`synth/` and `demo/`) | rank **48** / 48 ✅ | 24 / 24 ✅ (all six pairs) |

⚠️ At the **32-bit key default**, the four bucket indices are **linearly dependent** — 48
GF(2) functionals of a 32-dimensional input cannot be independent, so there are 16 relations
among them. Every *pair* is still full rank, so no two tables degenerate, which is why the
author's 91.5 % load result stands. But it is a real property: knowing two tables' indices
constrains the other two. **This is forced by information theory, not by a bad choice of
polynomials**, and it is a general caution about linear (CRC) hash families whenever
`d × log2(buckets) > key_bits`. At 64-bit keys — the configuration the author actually
synthesised — the deficiency disappears.

For us: `2 × 13 = 26 ≪ 64`, so we are nowhere near this regime. Noted so nobody proposes
`d = 4` with a truncated key and reintroduces it.

### 7.3 ⚠️ Two findings about our own hash, from this comparison

**(a) Our stated reason #2 for hash independence is false.**
[`rtl/book/book_pkg.sv`](../rtl/book/book_pkg.sv) §5 says independence is "bought three ways
at once", listing "2. Two different non-zero seeds."

A CRC seed is an **additive constant in GF(2)**: `h_seed(k) = B·k ⊕ A·seed`. The seed shifts
every output by the same fixed vector and **cannot change which keys collide**, nor
decorrelate `h0` from `h1`. Verified empirically as well as algebraically: over 2000 random
keys, `h_{seed=0xFFFFFFFF}(k) XOR h_{seed=0}(k)` is the constant `0xAEB2EBCE` for every one.

Reasons 1 (different polynomials) and 3 (disjoint bit selections) are correct and are doing
all the work — and §7.2 confirms they are sufficient. **The seeds are harmless but they are
not evidence.** The comment should be corrected, because a future reviewer who trusts it might
"simplify" to one polynomial with two seeds and collapse the load factor exactly as that same
comment warns.

**(b) Our CRC is a behavioural loop, which our own manual forbids.**
[`manuals/09-deep-dives/05-hash-tables-and-lookup-structures.md`](../manuals/09-deep-dives/05-hash-tables-and-lookup-structures.md)
§12 rule 4: *"The XOR matrix is generated, checked in, and diffed in review, never
hand-written or inferred from a behavioural loop."* `book_pkg::map_crc32` is a 64-iteration
`for` loop over a shift-register recurrence — exactly the shape rule 4 names.

`src/crc.sv` demonstrates a third option that satisfies the *intent* of rule 4 without a code
generator: **build the matrix in an elaboration-time function and apply it as an explicit
XOR-reduce.** The matrix is then inspectable, the structure is manifestly two levels deep, and
there is no generated file to keep in sync. That is a genuinely better pattern than either the
loop we have or the generator the manual demands, and it is an *idea*, freely adoptable.

⚠️ While checking this: rule 4 also asserts `gf2_rank == 64`. **For a 64→32 hash that is
impossible** — the rank of a 32×64 matrix is at most 32. The meaningful and checkable version
is the one measured in §7.2: `rank([h0 ; h1]) == 64` for the *pair*. Rule 4 should be
restated that way, and the check is worth adding to `tb/book/` since it is ~30 lines of Python
and catches a correlated pair instantly.

---

## 8. Verification harness — Rust/Verilator vs our cocotb

### 8.1 What theirs does

```
   src/*.sv ──► CMake + verilate ──► libVhashmap.a ──► cxx bridge ──► Rust binary
                                                        (sim/src/lib.{hpp,cpp})
```

`sim/src/main.rs` is a differential test against an `IndexMap<u32,u32>` oracle, in two modes:

| Mode | Shape |
| --- | --- |
| `deterministic_fill_readback` | Insert 15,000 keys (`state²`), then read all 15,000 back and assert value equality |
| `randomized_operations` (the one `main` runs) | Prefill to 15,000, then **50,000 random operations** |

The randomised mode is the interesting one, and three of its ideas are worth stealing:

1. **A deferred-expectation queue.** A `VecDeque` of length ≤ 2 holds the expected result of
   each in-flight lookup and is popped `NUM_PIPES` cycles later. This is exactly how you test
   a fixed-latency pipeline: the expectation is enqueued at issue and checked at retire, so a
   latency bug and a value bug produce different failures.
2. ⚠️ **A `recents` ring of the last 100 touched keys**, with a dedicated `LookupRecent`
   operation. This is a *hazard generator*: it deliberately biases lookups toward keys that
   were just modified, which is precisely the read-modify-write forwarding path. Uniform random
   keys almost never hit it. This is the same lesson as our own §2.4c trap — a stress test
   written the obvious way exercises none of the interesting logic.
3. **Modify/delete are chosen at lookup-issue time and applied at retire**, so the oracle and
   the DUT stay aligned through the pipeline delay without the test needing to model it.

Roughly the same statistical shape as our planned `tb/book/test_book_soak.py`, reached by a
different route.

⚠️ **Its own known defect, quoted:** *"TODO: this is incorrect because things can be inserted
before being fully removed by a delete operation."* The oracle removes a key at lookup-issue
time while the DUT removes it `NUM_PIPES` cycles later, so a reinsert in that window is
modelled wrong. It is a **test bug in the direction that hides DUT bugs** — the exact hazard
window the harness exists to probe is the one it models incorrectly. Worth remembering that a
differential harness needs its own timing model reviewed as carefully as the DUT.

### 8.2 Rust/Verilator vs cocotb, for us

| Dimension | Rust + Verilator + `cxx` | cocotb (what we have) |
| --- | --- | --- |
| Raw throughput | Very high — compiled oracle, no Python GIL, no per-cycle coroutine scheduling | Much lower; the bottleneck is the Python/simulator boundary |
| Build complexity | ⚠️ High: `cargo` → `build.rs` → CMake → Ninja → Verilator → `cxx` codegen → static link. **Four toolchains.** Adding one port means editing `lib.hpp`, `lib.cpp` *and* the `#[cxx::bridge]` block | Low: one Python file, `cocotb-config` already on this machine |
| Signal access | ⚠️ Hand-written accessor per port, `u32`-typed. A 64-bit key would need every accessor changed | `dut.<signal>` reflectively; width changes are free |
| Oracle expressiveness | Strong types, `IndexMap` gives O(1) random selection from live keys | Python `dict` + `random.sample`; our golden model is already written this way |
| Fits our existing suite | ❌ Would be an eleventh, incompatible runner beside the ten in [`docs/TEST-RESULTS.md`](TEST-RESULTS.md) | ✅ Already the house pattern |
| Assertion/coverage integration | None — Verilator lint-level only | SVA in `order_id_map.sv` fires natively under Verilator |

**Verdict: do not port the harness. Port three ideas.** Our cocotb infrastructure works
(432 tests across 40 runs recorded in [`docs/TEST-RESULTS.md`](TEST-RESULTS.md)), and the
build complexity of the Rust path buys throughput we do not currently need — we have not yet
run `test_book_soak.py` even once. Rebuild that on top of a four-toolchain stack and it will
be even less likely to run.

The three ideas to port into `tb/book/test_book_soak.py`:

| Idea | Why it matters to us |
| --- | --- |
| **Deferred-expectation queue** keyed to the 2-cycle latency | Separates "wrong value" from "wrong cycle". Our fixed-latency SVA covers the second; nothing currently covers the first |
| ⚠️ **`recents` bias** — reserve a fraction of operations for keys touched in the last N | Our RMW forwarding (`cnt_forward`) is otherwise almost never exercised. `order_id_map.sv` already says so: *"zero over a session means the hazard test never fired"* |
| **Prefill-then-operate** with a load-factor knob | The knee is at 85 %. A test that runs at 12 % load proves nothing about the structure we chose it for |

⚠️ And one anti-pattern to avoid, learned from their TODO: **the oracle must model the
pipeline delay of deletes**, or the reinsert-after-delete window is untested. Ours has the same
window (`bg_abort_now` exists precisely for it).

---

## 9. Synthesis and timing

### 9.1 What the flow actually does

`synth/timing.tcl` is **one line**:

```tcl
create_clock -add -name sys_clk_pin -period 2.8 [get_ports { clk }];
```

A 2.8 ns constraint = **357.1 MHz**. That is the entire timing setup — there are no
false paths, no multicycles, no floorplan constraints. Everything is a single-cycle path in
one clock domain, which is itself a claim about the design worth noticing.

`synth/compile.tcl` runs a **complete implementation**, not just synthesis:

| Step | Setting |
| --- | --- |
| Part | `xcku3p-ffvb676-2-e` (Kintex UltraScale+, speed grade **-2**) |
| Synthesis | `synth_design -top top -flatten_hierarchy rebuilt` |
| Place | `-directive Explore` |
| Phys-opt | `-directive AggressiveExplore`, then `-directive Explore` after routing |
| Route | `-directive Explore -tns_cleanup` |
| Reports | `report_clocks`, `report_timing_summary`, `report_utilization` |

⚠️ `synth/top.sv` **serialises every wide port through a shift register** — a 64-bit key is
shifted in one bit per cycle from a single pin — because the package has nowhere near enough
pins. `DONT_TOUCH` is applied to the internal signals so the hashtable is not optimised away.
This is the right harness for measuring *logic depth and internal Fmax*, and it is
deliberately **not** a system-level number: no real I/O, no other logic competing for
placement, no SLR crossings.

### 9.2 Reported results

> **Verify:** every figure in this table is the author's, from the blog. **Nothing here was
> measured for this study** — no Vivado exists on this machine, and none has ever run against
> this project either.

| Metric | Reported |
| --- | --- |
| Configuration | 64-bit keys, 64-bit values, 4 columns, 16,384 entries |
| Fmax | *"meets timing comfortably at 350 MHz"* |
| Maximum logic depth | **8** levels (down from **12** in the author's previous design) |
| UltraRAM | **8** (2 per column: one key, one value) |
| Block RAM | used for the valid bits |
| Logic | *"primarily consumed by the forwarding network and pipeline registers"* |
| Achieved load | 15,000 of 16,384 = **91.5 %** in simulation |
| Stated ceiling | *"a cuckoo hashtable with four RAMs should be able to achieve a load factor in excess of 90 %"* |
| Stated limitation | *"Matching and bypass logic not pipelined, limiting operation above 350 MHz or in congested FPGA regions"* |

⚠️ The Fmax figure is for `EN_INS_SEL = 0` (§2.1). The default `EN_INS_SEL = 1` adds a serial
AND chain across all tables on top of the eviction-output mux; the author does not report a
number for it, and it would be optimistic to assume 350 MHz holds.

### 9.3 Geometry compared with ours

| | Reference (`synth/`) | `order_id_map.sv` (defaults) |
| --- | --- | --- |
| Part | `xcku3p-ffvb676-2-e` | VU9P (per `book_pkg` §5 SLR arithmetic) |
| Clock target | 2.8 ns / **357 MHz** | 6.4 ns / **156.25 MHz** — **2.3× more slack per stage** |
| Geometry | `d = 4` × `b = 1` × 4096 buckets | `d = 2` × `b = 4` × 8192 buckets |
| Capacity | **16,384** entries | **65,536** slots |
| Entry width | 64 + 64 + 1 = 129 bit | **138 bit** (`{valid, key[63:0], sym[7:0], side, price[31:0], qty[31:0]}`) |
| Total memory | ~2.1 Mbit | **9.04 Mbit** |
| Memory instances | 4 columns × 3 arrays = 12 (8 URAM + BRAM) | 8 arrays × (2 URAM deep × 2 wide) = **32 URAM288** |
| Read width per lookup | 4 × 129 = **516 bit** | 8 × 138 = **1104 bit** — 2.1× wider |
| Key comparators (full width) | ~22: per column ~5 (RAM match, 2 in-flight, 2 modify-forward) × 4, plus 2 at the top | **25**: 8 bucket + 16 stash + 1 in-flight |
| Pipeline depth | `NUM_PIPES = 2` | 2 stages, fixed |
| Reset | ⚠️ **None.** `initial` blocks only (relies on FPGA GSR) | `rst` on all control state; `BOOK_CLEAR` walks and wipes the memory |
| Telemetry | ⚠️ **None** | 14 saturating counters + a kick-depth histogram |

⚠️ **The "4 comparators versus 25" reading is wrong and it is the trap in this comparison.**
Counting only the RAM-match comparators makes the reference look four times leaner. Counting
the forwarding networks — which is where the author himself says the logic goes — the two
designs are within ~15 % of each other on full-width comparators. **The reference is not
cheaper in comparison logic; it is cheaper in *stored bits* (129 vs 138 per entry, and a
quarter of the entries).** Our extra area is capacity and payload, not inefficiency.

Where we are genuinely at more risk than they are: **read width.** 1104 bits arriving at a
25-way comparator bank, at 6.4 ns, in the same cycle as a 64-bit CRC XOR tree — our own module
header flags this and names the fix (register `s0_buck`, go to 3 cycles). Their 516 bits into
~22 comparators closes at 2.8 ns. That is genuine evidence the *style* of path can be fast; it
is not evidence that ours will close, because ours is twice as wide.

---

## 10. The parameter space

| Parameter | Default | What it costs | Limit | Status |
| --- | :-: | --- | --- | --- |
| `NUM_TABLES` | 4 | One column each: 3 RAMs, ~5 full-width comparators, one ring stage. Raises load factor; lengthens the ring, so relocation latency grows | ⚠️ **Hard max 4** — the `POLYS` array has four entries and indexing past it is a `SELRANGE` error | **Verified by lint** at 5 and 8 (§2.2) |
| `NUM_ADDR_BITS` | 12 | Capacity is `NUM_TABLES × 2^NUM_ADDR_BITS`. Memory scales linearly | Must not exceed the CRC output width (32) — the index is `crc_out[NUM_ADDR_BITS-1:0]` | Inferred from source |
| `NUM_KEY_BITS` | 32 | Key RAM width, every comparator, and the CRC input width | ⚠️ Interacts with `NUM_TABLES × NUM_ADDR_BITS` — see §7.2. At 32 bits and 4 × 12, the bucket indices are linearly dependent | **Measured** (§7.2) |
| `NUM_VAL_BITS` | 32 | Value RAM width and the modify datapath. No effect on comparators | — | Inferred |
| `NUM_PIPES` | 2 | RAM read latency **and** the lookup→modify distance **and** the depth of all three forwarding networks. Higher = more registers, more forwarding comparators, more in-flight slots per column | ⚠️ **"Must be at least 1."** At `NUM_PIPES=1` the RAMs get `NUM_PIPES-1 = 0` extra stages, i.e. bare RAM output register | Lints clean at 1 and 3 (§2.2) |
| `EN_INS_SEL` | 1 | `1` = inject into any non-busy column: better insert acceptance, serial AND chain across all tables. `0` = column 0 only: one OR gate | — | Both lint clean. ⚠️ The published 350 MHz is for `0` |
| `RAM_STYLE` | `"ultra"` | Passed as a synthesis attribute to the key and value RAMs. The valid-bit RAM is hardwired `"auto"` | Vivado-specific string; Verilator reports it `UNUSEDPARAM` | Lint-observed |

⚠️ The most instructive parameter is `NUM_PIPES`, and it is instructive because of what our
own manual says. [`manuals/09-deep-dives/05-hash-tables-and-lookup-structures.md`](../manuals/09-deep-dives/05-hash-tables-and-lookup-structures.md)
§12 rule 8 requires *"`BYPASS_DEPTH` derived from `RAM_RD_LAT` by parameter, never as an
independent constant."* **This design is a working implementation of that rule** — read
latency, write-address delay, forwarding depth and the lookup→modify distance are all the
single parameter `NUM_PIPES`, and there is no way to set them inconsistently.

Ours hardcodes read latency 1 and a one-deep `fwd_*_q`. That is *currently* self-consistent
(the write is driven combinationally from stage 1, so exactly one write is ever in flight —
the module header derives this cycle by cycle). But it is consistent by argument rather than
by construction. See §12.4.

---

## 11. Direct comparison against `rtl/book/order_id_map.sv`

### 11.1 The table

| Dimension | Reference | `order_id_map.sv` | Verdict |
| --- | --- | --- | --- |
| Geometry | `d=4` × `b=1` | `d=2` × `b=4` | §11.2 — trade-off |
| Relocation mechanism | Systolic ring, no controller | Background FSM (`BG_IDLE/RD/EVAL/WIPE`) + 16-entry stash | §11.3 — theirs is more elegant, ours is more auditable |
| Concurrent relocations | **8** (`NUM_TABLES × NUM_PIPES`) | **1** | Theirs, decisively |
| Relocation bandwidth | ~4 hops per idle cycle | ~0.5 hops per idle cycle (2 granted cycles per hop) | ⚠️ **~8× theirs** |
| Chain bound | ⚠️ **None.** An item circulates until it lands | `MAX_KICKS = 16`, then pinned in the stash | Ours — CLAUDE.md §5.2 forbids unbounded loops on this path |
| Overflow structure | ⚠️ **None.** The ring *is* the overflow | 16-entry fully-associative stash, searched in parallel | Ours — required by §11.4 |
| Producer contract | ⚠️ **`busy` may stall an insert** | ⚠️ **No `ready`. No stall path exists** | §11.4 — the one place their contract cannot be adopted |
| Duplicate insert | ⚠️ Illegal, `assume`d away in the proof, undefined in RTL | Detected → `cnt_dup_add` + `map_stale` | §11.6 — ours, decisively |
| Delete | `lookup` → wait `NUM_PIPES` → `modify+del` (2 bus cycles) | `BOOK_DELETE`, one request, 2 cycles | §11.7 — ours for this application |
| Insert latency | ⚠️ Variable and unbounded (hidden by forwarding, but real) | **Fixed 2 cycles, every case** | Ours — a pipeline stage has one duration |
| Lookup latency | Fixed `NUM_PIPES` | Fixed 2 | Equal |
| Key / value | 32 / 32 default (64 / 64 in `synth/`) | 64-bit ITCH reference / 138-bit record | §11.8 |
| Failure mode when full | ⚠️ Silent liveness stall: `busy` latches high, nothing reports it | `cnt_insert_fail` + sticky `map_stale` | **Ours, decisively.** Loud beats silent |
| Telemetry | ⚠️ None | 14 saturating counters + kick histogram + high-water gauges | Ours |
| Reset / resync | ⚠️ `initial` only. No runtime clear | `rst` + `BOOK_CLEAR` wipe with `wipe_pending_q` gating | Ours — a gap-resync is mandatory for ITCH |
| Formal | ✅ Shadow-model BMC that runs | ⚠️ 32 internal SVAs, no functional spec, no runner | **Theirs, decisively.** §6.6 |
| Simulation | ✅ 50,000-op differential harness | ⚠️ `tb/book/test_book_soak.py` **has never been executed** | **Theirs, decisively** |
| Synthesis evidence | ✅ Placed, routed, 350 MHz reported | ⚠️ Nothing compiled, simulated or synthesised | **Theirs, decisively** |

### 11.2 `d=4 × b=1` versus `d=2 × b=4`

| | Theirs `d=4, b=1` | Ours `d=2, b=4` |
| --- | --- | --- |
| Published load ceiling | >0.90 (author), ~0.97 for 4-ary cuckoo | 0.976 asymptotic for bucketed `d=2, b=4` |
| **Achieved** load | **91.5 %** in their simulation | ⚠️ **85 %** knee in our Python model of the algorithm; 322 insert failures at 90 % |
| Memory instances | 4 tables × (key + value + valid) | 2 tables × 4 slots = 8 record arrays |
| Read width per lookup | 4 entries | **8 entries** (2.1× wider at our entry width) |
| Full-width comparators | ~22 including forwarding | 25 |
| Alternate-location function | ⚠️ **Not needed.** Relocation target is "the next column", not "the alternate" | Required, and it is an **involution** — which is why `d=2` is structural in our design |
| Effect of raising `d` | Free — the ring just gets longer | ⚠️ A redesign. With `d>2` the kick target becomes a choice and the involution dies |

⚠️ **This is the deepest architectural difference in the whole comparison, and it is not the
one that looks biggest.** The ring *replaces* the alternate-location function. Because an
evicted item is simply handed to the next stage, "where does a kicked item go?" has a
structural answer that does not depend on `d`. Our design answers the same question with
`alt(t,k) = (¬t, h_¬t(k))` and an involution proof, which works beautifully at `d = 2` and
does not generalise.

So the honest reading of the load-factor numbers is: **their 91.5 % achieved beats our
modelled 85 % knee, and the reason is not the geometry — it is that their relocation engine is
~8× faster, so chains complete instead of resting in an overflow.** Our own measurement says
the same thing from the other side: engine off → 1,112 insert failures at 85 % load, engine on
→ 0. The engine's *throughput* is the load-factor lever, not `d` versus `b`.

**Verdict: a real trade-off, and ours is defensible.** `b=4` gives us four candidate slots per
probe, which absorbs collisions without any relocation at all, and keeps `d=2` so the
involution holds and the correctness argument stays one page. Their `d=4` is only free because
the ring made it free. Do not change our geometry; change our relocation bandwidth (§12.2).

### 11.3 Their ring versus our background engine + stash

| | Ring | Background engine + stash |
| --- | --- | --- |
| Controller | None | 4-state FSM + LFSR victim selector |
| Arbitration | None — the global `lookup_q[NP-1]` gates every column identically | `bg_grant = !req_act && !s1_valid` |
| Cycle handling | None needed — a cycle is normal traffic | `MAX_KICKS` exhaustion → pin in the stash, retried when space frees |
| Where a stalled item waits | Recirculating in a column's shift register | In the stash, pinned |
| Progress guarantee | ⚠️ None stated or proven | Bounded chain + pinning; asserted — an exhausted chain must return to `BG_IDLE` |
| Lines of RTL for relocation | ~60 (spread across the column) | ~200 including the wipe |
| Cost of understanding it | ⚠️ High — the argument is a distributed timing argument | Moderate — a state machine with an invariant |

**Verdict: theirs is genuinely more elegant and ours is more defensible, and both statements
are true at once.** The ring is a better *machine*. The FSM is a better *artefact for a
trading system that has never been simulated*, because its safety properties are stated rather
than emergent. The right move is not to replace ours with theirs — it is to steal the ring's
throughput characteristic without its distributed argument. That is §12.2.

### 11.4 ⚠️ `busy` versus a receive path that cannot stop

**This is the one place the reference's contract genuinely does not fit ours, and it is worth
being precise about why.**

CLAUDE.md §5 rule 4:

> **No backpressure stalls into the MAC RX.** The receive path must accept line rate
> unconditionally; drop deliberately and count drops, never block.

And `order_id_map`'s port list has no `ready` at all: `req_valid` in, `res_valid` out, exactly
2 cycles later, with an SVA (`req_act |-> ##2 res_valid`) enforcing it. **There is no stall
path to add.** `book_engine` confirms it from the other side: its own Replace-injection comment
says *"The feed handler does not backpressure"* and treats a collision as a structural
impossibility it counts rather than prevents.

So `busy` is not merely inconvenient — it is **unimplementable** in our datapath. What would
we have to do instead?

| Option | What it costs | Verdict |
| --- | --- | --- |
| **A. Insert FIFO in front of the map** | ⚠️ **Breaks the forwarding property.** A queued add is not findable, so a delete arriving behind it in the FIFO misses, `cnt_miss_tracked` fires and the book stales — for a *correct* sequence. To fix that the FIFO must be content-searchable in parallel with the buckets… at which point **it is our stash, with a worse name** | ❌ Rejected — and the reasoning is the point |
| **B. Drop the add and count it** | Violates the population invariant: the order exists at the venue, its delete resolves to nothing, its quantity is stranded. This is eviction (§2.4 of the book manual) | ❌ Forbidden |
| **C. Searchable overflow + background drain** (what we built) | A 16-entry stash + a relocation FSM. ⚠️ Costs: stash comparators (16 × 64-bit), the FSM, and — the honest one — **the engine needs idle cycles** | ✅ **Correct, and the only one that is** |

**Conclusion: our stash is not a workaround for lacking their ring. It is the correct
structural response to a producer that cannot be stopped, and an insert FIFO is the same
structure with the forwarding property deleted.** That reframing is worth putting in the
module header, because "why not just a FIFO?" is the obvious reviewer question and the answer
is not obvious.

**What it costs us, quantified from what we know:**

| Quantity | Value | Source |
| --- | ---: | --- |
| Stash high-water at 85 % load | 1 | Python model, `order_id_map.sv` header |
| Stash high-water at 90 % load | 15 of 16 | same |
| Insert failures at 90 % load | 322 | same |
| Insert failures at 85 % with the engine **off** | 1,112 | same |
| Minimum idle-cycle fraction from the ITCH datapath | ≥ 1 in 3 | 19-byte Order Delete = 3 beats at 64 bit / 156.25 MHz |

> **Verify:** all five are modelled or argued, none is measured on RTL. The 19-byte figure is
> already flagged twice in our own source as needing a check against the TotalView-ITCH 5.0
> specification, and it is the load-bearing constant in the duty-cycle argument.

⚠️ **The residual risk, stated plainly.** Our engine advances only when *both* pipeline stages
are idle. Under a sustained 100 %-duty request stream it gets **zero** cycles, the stash stops
draining, and `order_id_map.sv`'s own header admits the design then "degrades to exactly the
rejected d-left arrangement". The reference does not have this failure mode because it stalls
the producer instead — which we cannot. **The fix is not to adopt `busy`; it is to make the
engine need fewer idle cycles.** §12.2.

### 11.5 Deletion

| | Reference | Ours |
| --- | --- | --- |
| Protocol | `lookup` → wait `NUM_PIPES` → `modify` + `del` | `BOOK_DELETE` in one request |
| Bus cycles | 2 | 1 |
| What is written | Valid bit cleared; ⚠️ **key left resident** | Whole record zeroed |
| Relocation needed | No | No |
| Frees a slot for pinned stash entries | Implicitly (the ring will find it) | Explicitly — `if (fp_mem_wr && !wr_rec.valid) stash_pin_q <= '0` |

**Verdict: ours, for this application.** One bus cycle, and the un-pinning hook is a genuine
piece of engineering the reference has no need for — because it has no stash. Their protocol is
more general and costs a cycle for generality we do not use.

### 11.6 ⚠️ Duplicate insert

The reference states *"It is illegal to insert a key that is already inserted"* and its formal
proof `assume`s the precondition away. **The RTL behaviour on violation is undefined and
untested.** Structurally it would place a second copy of the key in a different table; both
would then be found; `lu_valid` would be asserted by two columns, which is exactly what the
`` `ifdef FORMAL `` assertion `assert(!valid)` catches — but only for the anyconst key, only
under the proof, and never in hardware.

Ours treats it as a first-class event:

```
    BOOK_ADD with s1_hit  →  cnt_dup_add++  →  map_stale
```

with the reasoning recorded in the header: overwriting strands the old quantity in its level;
refusing strands the new one; neither is recoverable, so declare it. The 25-way
`$countones(s1_match) <= 1` SVA is the machine-checkable form.

**Verdict: ours, decisively.** ITCH reference reuse after a feed gap is not hypothetical, and
their precondition is exactly the kind of contract that holds until the morning it does not.
⚠️ The lesson to import is the *opposite* of the code: where they `assume`, we must `assert`.

### 11.7 Key and value widths

| | Reference | Ours |
| --- | --- | --- |
| Key | 32 bit default / 64 bit in `synth/` | **64 bit** ITCH order reference — mandatory |
| Value | 32 / 64 bit | **73 bit** payload (`sym[7:0]`, `side`, `price[31:0]`, `qty[31:0]`), 138 bit record with key and valid |
| Capacity | 16,384 | 65,536 slots default; sizing table runs to 555,556 |

The 64-bit configuration is proven to synthesise (`synth/top.sv`), so key width is not a
barrier. **Record width is where the divergence matters**: 138 bits does not fit a URAM's
native 72-bit width, so every slot is 2 URAMs wide, and with `b = 4` and `d = 2` that is
8 arrays × 4 URAM = 32 URAM288 against the ~320 available in one VU9P SLR. Their 129-bit
entries at `b = 1` need 2 URAMs per column and nothing else.

⚠️ A design note that follows and is easy to miss: **our record has 6 bits of headroom before
it crosses 144** (2 × 72). Adding a field — an arrival ticket for queue-position estimation,
say, which [`manuals/09-deep-dives/05-*.md`](../manuals/09-deep-dives/05-hash-tables-and-lookup-structures.md)
suggests "rides free in the map entry" — costs **zero URAM up to 144 bits and 50 % more URAM
at 145.** That is a cliff, not a slope, and it should be stated in `book_pkg`.

---

## 12. What we should actually change — prioritised

Ordered by (risk retired) ÷ (cost). Each states what it costs, because a recommendation
without a cost is a wish.

### 12.1 🔴 Write a shadow-model formal spec for `order_id_map`, with a runner

**Do:** `rtl/formal/fv_order_id_map.sv` + `rtl/formal/order_id_map.sby`, per §6.6.

**Why it is first:** our 32 SVAs are all *internal consistency* — involution holds, at most one
copy exists, population is conserved, the engine does not race the fast path. **Not one of them
says "a lookup returns the record that was inserted."** The reference proves exactly that
property, in 180 lines, with one `anyconst` key. It is the property the whole module exists to
provide and the only one nothing currently checks.

**Cost:** ~200 lines of properties, ~30 lines of `.sby`, plus installing `yosys` +
`symbiyosys` + an SMT solver (none are on this machine). Proof runs need a shrunken geometry;
`N_TABLE` must stay 2 or the module `$error`s. Expect the first run to fail on something real.

⚠️ Also fix, at the same time: `rtl/formal/fv_axis_props.sv` refers throughout to
`rtl/formal/fv_bind.sv`, **which does not exist**. Either write it or correct the references —
a header that documents a file that was never written is worse than no header.

### 12.2 🔴 Relax the background engine's grant rule to per-port, and add read/write forwarding to the engine's snapshot

**Do:** today `bg_grant = !req_act && !s1_valid` — the engine needs *both* stages idle. But
the fast path uses the **read port in stage 0** and the **write port in stage 1**. Grant the
engine's `BG_RD` on any cycle where the fast path is not reading, and its `BG_EVAL` write on
any cycle where the fast path is not writing.

**Why:** this is the single change that most directly attacks the weakness our own header
admits — "under a hypothetical 100 % duty request stream forever, the stash would stop
draining". At 50 % request duty the engine roughly doubles its throughput; at 100 % duty it
goes from **zero** hops to a nonzero rate, because a stream of back-to-back requests still
leaves the write port free on the cycle a new request is being read. The reference gets the
same effect by sharing ports at slot granularity rather than cycle granularity, and its ~8×
relocation bandwidth (§11.1) is where its 91.5 % achieved load comes from.

**Cost, and it is real:**

| | |
| --- | --- |
| ⚠️ The snapshot-safety argument breaks | Today the engine reads at `X` and writes at `X+1` knowing no fast-path write can intervene. Under the relaxed rule one can |
| The fix, which the reference already demonstrates | Forward the fast path's write over the engine's snapshotted bucket data — the same read/write conflict network as §4.1. ~1 address comparator + 1 record-wide mux per table |
| The `at most one write per cycle` property | **Survives.** The write-port priority mux already enforces it; only the *source* changes |
| The one-deep `fwd_*_q` | **Survives**, for the same reason |
| Verification burden | ⚠️ New. The engine can now be mid-relocation while the fast path mutates the same record. `bg_abort_now` handles retirement; a *quantity reduction* mid-relocation is a new case and needs its own SVA and its own test |

⚠️ **Do not do 12.2 before 12.1.** This change makes the hardest part of the module harder, and
"we tightened the concurrency and had no functional proof" is how a plausible, wrong book gets
built.

### 12.3 🟠 Fix the two hash claims in `book_pkg.sv`, and add a rank check to the testbench

**Do:**
1. Delete "two different non-zero seeds" from the independence argument — a CRC seed is an
   additive constant in GF(2) and cannot decorrelate two hashes (§7.3a, verified two ways).
   Keep the seeds if you like them; stop citing them as evidence.
2. Add the measured result to the comment: `rank([h0 ; h1]) = 64` over GF(2), and
   `rank(selected bucket bits) = 2 × BUCK_W` at `BUCK_W` ∈ {12, 13, 14, 16}.
3. Add a GF(2) rank check to `tb/book/`, replacing the 1024-key agreement smoke test as the
   *primary* independence criterion (keep the smoke test — it is cheap and it runs in RTL).
4. Restate `manuals/09-deep-dives/05-*.md` §12 rule 4: `gf2_rank == 64` is impossible for a
   single 64→32 hash. The checkable property is rank 64 for the *pair*.

**Cost:** a comment edit, ~40 lines of Python, one manual line. Nothing in RTL changes.

**Why it matters despite being cheap:** the false claim is load-bearing in the wrong direction.
A reader who believes seeds provide independence may "simplify" to one polynomial with two
seeds — and that collapses the load factor to single-hash behaviour, silently, exactly as the
comment right above it warns.

### 12.4 🟠 Make the forwarding depth derive from the read latency

**Do:** introduce `localparam MEM_RD_LAT = 1;` and derive the forwarding structure from it,
rather than hardcoding one `fwd_*_q` stage.

**Why:** [`manuals/09-deep-dives/05-*.md`](../manuals/09-deep-dives/05-hash-tables-and-lookup-structures.md)
§12 rule 8 already requires this and our RTL does not do it. The reference is a working
demonstration that it is not hard — one parameter drives read latency, write-address delay,
forwarding depth and the lookup→modify distance, and they cannot be set inconsistently.

⚠️ **The specific hazard.** Our `mem` infers a 1-cycle read. URAM at high frequency generally
needs its optional output register, making it 2 cycles — and the reference, targeting 350 MHz
on URAM, chose `NUM_PIPES = 2` for exactly that reason. We target 156.25 MHz, so 1 may well
close. But if post-route ever forces the output register, a 1-deep bypass against a 2-cycle
read is **off by one and silently wrong** — which is defect §2.4 of
[`docs/ORDER-BOOK-REDESIGN.md`](ORDER-BOOK-REDESIGN.md) recurring in a new place.

> **Verify:** whether the target URAM configuration closes at 6.4 ns without the output
> register. Nothing in this project has been synthesised.

**Cost:** a parameterised forwarding chain instead of one register — perhaps 40 lines, and the
SVAs that reference `fwd_*_q` need updating. Purely defensive today.

### 12.5 🟠 Port three ideas from the Rust harness into `tb/book/test_book_soak.py`

Per §8.2: the deferred-expectation queue, the `recents` bias, and the prefill-to-a-load-factor
knob. ⚠️ And model the delete pipeline delay in the oracle, which their harness admits it does
not.

**Cost:** ~100 lines of Python in a file that already exists.

**Why:** `cnt_forward` is documented in our own RTL as the tell that the hazard test never
fired, and a uniform-random key stream will not fire it. And per
[`docs/TEST-RESULTS.md`](TEST-RESULTS.md), `test_book_soak.py` — *"the golden-model equivalence
check that decides whether the order book is actually correct"* — **has still never been
executed.** Do that first; then bias it.

### 12.6 🟡 State the same-cycle ordering rule explicitly in our contract

The reference's header and its formal model disagree about what happens when a lookup and an
insert for the same key occur in the same cycle (§4.4). Our map cannot have that exact
ambiguity — one request per cycle, one operation — but the adjacent question is live and
unstated: **an `ADD` at cycle `T` and a `DELETE` for the same reference at `T+1`.** Our RMW
derivation covers it (`fwd_*_q` makes the delete see the add), `cnt_forward` counts it, and
nothing in the port documentation *says* it.

**Cost:** a paragraph in the module header and one directed test. **Why:** an unstated ordering
rule is the defect class that produces a plausible, wrong book, and the reference just
demonstrated how easily the prose and the specification drift apart.

### 12.7 🟡 Reconcile the two manuals, and reconcile them *correctly*

[`manuals/09-deep-dives/05-*.md`](../manuals/09-deep-dives/05-hash-tables-and-lookup-structures.md)
§6 and §12 rule 11 reject cuckoo; §2 of
[`manuals/04-system-architecture/03-*.md`](../manuals/04-system-architecture/03-order-book-in-hardware.md)
specifies it. Both files say in terms that they contradict each other, and
`order_id_map.sv`'s header defers the fix to task R10.

The previous edition of this document argued the ring dissolves the contradiction. **That was
too generous, and this study corrects it.** What the reference actually shows:

| §6's objection | Verdict after reading the reference |
| --- | --- |
| *"K RMWs ≫ 1 cycle"* on the insert path | **Correct, and it applies to the reference too.** Its insert latency is variable and unbounded; it hides that behind forwarding and `busy`, not by making it fast. We hide it behind forwarding and a stash. Neither design makes the chain cheap — both make it *invisible to the requester* |
| *"cycle detection"* | **Dissolved.** Neither design needs it. Theirs treats a cycle as traffic; ours lets it exhaust `MAX_KICKS` and pins the record |
| *"displacement FSM"* | **Dissolved for them, real for us.** The ring genuinely has no FSM. Our engine has one, and its header says so |
| *"cross-table RMW hazard"* | **Real in both, solved differently.** Theirs by pervasive forwarding networks; ours by a grant rule that makes the hazard structurally impossible. ⚠️ §12.2 would move us toward their solution and reintroduce the hazard deliberately |
| *"Rejected — the insert path is real-time"* | **The conclusion was right for the design it evaluated and wrong for the design we built** — but the reason is *decoupling*, which is available to d-left as well |
| §12 rule 11: *"d-left is the sanctioned upgrade; adopt it before adopting cuckoo"* | ⚠️ **Still the weakest point of our case, and the reference does not help.** Our own measurement is what settles it: at 85 % load, engine off (≡ d-left with a static overflow) → 1,112 failures; engine on → 0. That is a measurement of *our* model, not a published result, and R7 must reproduce it in RTL |

**Do:** rewrite §6's verdict row and §12 rule 11 to say *"cuckoo is rejected on a **blocking**
insert path; a decoupled insert with a searchable overflow is admissible, and the sanctioned
form is the one in [04.03 §2](../manuals/04-system-architecture/03-order-book-in-hardware.md).
d-left remains preferred wherever the overflow does not need to drain."* — and cite the
1,112-versus-0 measurement as the reason the choice went the other way here.

⚠️ Do **not** write "the ring settles it." It does not. The ring is a different answer to the
same question, and it is one we cannot adopt wholesale because it backpressures.

### 12.8 🟡 Adopt the elaboration-time CRC matrix pattern

`crc.sv`'s idea — build the GF(2) matrix in a function at elaboration, apply it as an explicit
XOR-reduce — is a better pattern than either our behavioural loop or the checked-in generator
our manual demands. It is inspectable, obviously two levels deep, and has no generated file to
drift.

**Cost:** ~30 lines in `book_pkg`, and a bit-exactness test against the current
`map_crc32` before switching (the two constructions differ; ours has a seed and a different
bit order, so this is a *replacement*, not a refactor). **Priority is low** because our current
form is almost certainly synthesised into the same XOR tree — this buys reviewability, not
gates.

### 12.9 What we should explicitly **not** adopt

| Do not adopt | Why |
| --- | --- |
| ⚠️ **`busy` / any insert backpressure** | CLAUDE.md §5 rule 4. There is no stall path in our datapath and adding one would propagate into the feed handler |
| ⚠️ **The unbounded circulation contract** | CLAUDE.md §5 rule 2. An item that circulates until it lands is an unbounded loop with a nicer name |
| ⚠️ **The `d = 4` geometry** | Only free because the ring removed the alternate-location function. At `d = 4` our involution dies, and the module `$error`s at elaboration for exactly that reason |
| ⚠️ **The "illegal to insert an existing key" precondition** | ITCH after a gap violates it. Ours must detect, not assume |
| **The Rust/Verilator harness** | Four toolchains for throughput we do not need, replacing a cocotb suite that works |
| **The caller-owned RMW protocol** | Costs a bus cycle per message and forces the backwards-in-time forwarding table its own author questions. Our one-request RMW is why our bypass is one deep |
| **Having no telemetry and no reset** | Not a design choice we can copy. Our counters and `BOOK_CLEAR` are requirements, not decoration |

---

## Further reading

- [ORDER-BOOK-REDESIGN.md](ORDER-BOOK-REDESIGN.md) — the redesign this informs; §2.3 the Poisson capacity failure, §2.4c the dense-key test trap
- [TEST-RESULTS.md](TEST-RESULTS.md) — how this project reports measured versus claimed; `test_book_soak.py` has still never run
- [../rtl/book/order_id_map.sv](../rtl/book/order_id_map.sv) — the subject of §11 and §12
- [../rtl/book/book_pkg.sv](../rtl/book/book_pkg.sv) — §5, the hash pair corrected in §12.3
- [../rtl/book/book_engine.sv](../rtl/book/book_engine.sv) — the non-backpressuring producer of §11.4
- [../rtl/formal/fv_axis_props.sv](../rtl/formal/fv_axis_props.sv) — ⚠️ our entire formal collateral, unbound and with no runner
- [../manuals/04-system-architecture/03-order-book-in-hardware.md](../manuals/04-system-architecture/03-order-book-in-hardware.md) — §2 the authoritative design, §11 the latency budget
- [../manuals/09-deep-dives/05-hash-tables-and-lookup-structures.md](../manuals/09-deep-dives/05-hash-tables-and-lookup-structures.md) — ⚠️ §6 and §12 rules 4 and 11 all need revision per §12.3 and §12.7
- [../manuals/01-fpga-design/05-verification-and-simulation.md](../manuals/01-fpga-design/05-verification-and-simulation.md) — where the formal tier of §12.1 belongs
- [../CLAUDE.md](../CLAUDE.md) — §5 rule 2 (no unbounded loops) and rule 4 (no RX backpressure), the two constraints that decide §11.4 and §12.9
