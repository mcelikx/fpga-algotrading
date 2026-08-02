# 01.03 — Memory and Storage

> **Why this matters here:** the tick-to-trade path is a chain of table lookups —
> symbol → book slot, book slot → price level, order ref → order state, symbol →
> order template. Each lookup is 1–3 cycles (6.4–19.2 ns). Choosing the wrong
> memory primitive for a hot table costs more nanoseconds than any amount of logic
> optimization will win back. Choosing external memory for a hot table ends the
> project.

---

## 1. The storage hierarchy, ranked by latency

All figures assume UltraScale+ at a 156.25 MHz core clock (6.4 ns/cycle).

| Resource | Physical unit | Read latency | Practical capacity | Ports | Fmax posture |
| --- | --- | --- | --- | --- | --- |
| **Flip-flops** | 1 FF/bit | **0 cycles** (already a wire) | 100s of bits per structure | unlimited reads, 1 write | Free; wide fanout hurts routing |
| **LUTRAM** (distributed RAM, SLICEM) | LUT6 as 64×1 / 32×2 | **0 cycles async**, 1 registered | ≲ a few Kb before it costs more than a BRAM | 1 write + 1–4 async reads | Async read path is combinational — it lands *inside* your logic cone |
| **SRL16/SRL32** | LUT6 as a shift register | Addressable, 0-cycle out | 32 stages/LUT | 1 write (shift), 1 addressable read | Cheapest delay line by ~32× vs FFs |
| **BRAM36** | 36 Kb block (splittable into 2×18 Kb) | **1 cycle** raw, **2** with output reg | 36 Kb each; thousands per device | **True dual port** | 1-cycle mode limits Fmax; 2-cycle hits the block's rated max |
| **URAM288** | 288 Kb block (UltraScale+ only) | **1 cycle** raw, **2+** realistically | 288 Kb each; hundreds per device | 2 ports, **one shared clock** | Effectively needs the output register; cascade adds a cycle per hop |
| **DDR4** | External DIMM/component | **~100–300+ ns, variable** | GB | Controller-arbitrated | Refresh, bank conflicts, and read/write turnaround make it non-deterministic |
| **HBM2/2E** | In-package stack (VU3xP / Alveo U280-class) | **~100–200 ns, variable** | GB, with enormous bandwidth | 32 pseudo-channels | Bandwidth monster, latency mediocre |

> **Verify:** per-device BRAM/URAM counts and the maximum block frequency come from
> the device datasheet (DS923 for Virtex UltraScale+, DS922 for Kintex UltraScale+)
> and from `report_property` on the part in Vivado. DDR/HBM idle latency must be
> measured on *your* board with a traffic generator — vendor "typical" numbers assume
> an idle controller you will not have.

A VU9P-class part gives on the order of tens of Mb of BRAM and a few hundred Mb of
URAM — call it **single-digit MB + tens of MB of single-cycle-ish memory**. That is
the entire working set you get. Design the data structures to fit it; do not plan to
spill.

> **Verify:** exact BRAM36/URAM288 counts per part — DS923 device-resources table,
> or Vivado's Device view after opening the part.

---

## 2. Decision table — which primitive for which table

| Structure | Size | Access rate | Verdict | Why |
| --- | --- | --- | --- | --- |
| Pipeline stage registers, valid flags, FSM state | bits | every cycle | **FF** | Anything else adds latency |
| Top-of-book (best bid/ask price+qty) for ≤ ~32 hot symbols | ~2 Kb | every cycle, multi-read | **FF or LUTRAM** | Async read means the compare happens in the *same* cycle as the update |
| Pipeline-matching delay line | W × D bits | every cycle | **SRL** (unreset) | See [01-rtl-design-patterns.md](01-rtl-design-patterns.md) §7 |
| Symbol/reference table (per stock locate: book base, tick size, risk limits, enable bit) | ~8 K entries × ~128 b = 1 Mb | 1 read/message | **BRAM**, direct-indexed | Dense integer key, needs 1-cycle read, needs a second port for host writes |
| Pre-built order templates (per symbol) | ~8 K × ~512 b = 4 Mb | 1 read/trigger | **BRAM** | Latency-critical, fits comfortably |
| Price-level book arrays | 1–20 Mb depending on depth × symbols | 1 RMW/message | **BRAM**, banked | Needs true dual port for read-while-write |
| Order-reference table (ITCH `Order Reference Number` → locate/side/price/qty) | 10s of Mb | 1 lookup + 1 write/message | **URAM**, hashed, set-associative | Only URAM is big enough; accept the extra cycle |
| Packet capture / journal / replay buffer | GB | streaming | **DDR or HBM** | Slow path only |
| Historical bars, calibration data, model coefficients | MB–GB | rare | **Host RAM**, pushed over PCIe when they change | Not fabric's problem |

**Hard project rule:** *nothing on the tick-to-trade path reads DDR, HBM, or PCIe.*
Not once, not for a rare case, not "just the cold table". A single DDR read is
15–45 cycles of jitter-laden latency — more than the entire fabric budget in
[02-pipelining-and-parallelism.md](02-pipelining-and-parallelism.md) §8.

---

## 3. BRAM vs URAM: the differences that bite

| | BRAM36 | URAM288 |
| --- | --- | --- |
| Capacity | 36 Kb | 288 Kb (8×) |
| Port model | **True dual port**: two fully independent R/W ports, each with its own clock | Two ports sharing **one clock**; effectively simple-dual-port in practice |
| Independent clocks | Yes — port B can run on the PCIe/control clock | **No** — control writes must be arbitrated into the core clock domain |
| Read-during-write modes | `WRITE_FIRST` / `READ_FIRST` / `NO_CHANGE`, per port | No equivalent — build your own bypass |
| Byte-write enables | Yes | Yes (per 8-bit lane) |
| Hard ECC | Only in specific 512×64 SDP geometry | Built-in SECDED option |
| Cascading | Limited | Designed for it — **each cascade hop adds a pipeline stage** |
| Realistic read latency here | **1 cycle** | **2 cycles** (3+ if cascaded) |

> **Verify:** all of the above against UG573 *UltraScale Architecture Memory
> Resources*. The cascade-latency and collision-behaviour sections are the ones
> people skip and then get wrong.

**Consequence for this design:** BRAM is the fast-path memory. URAM is the
*capacity* memory. Put anything that is read once per message and feeds the
strategy in BRAM. Put the order-reference table — which is huge, and whose result
is needed one stage later anyway — in URAM.

### The optional output register

Every BRAM and URAM has a bypassable register on the data output.

```
Without DOUT reg:  addr ──[BRAM array]──> data   (1 cycle, but clock-to-out is LONG)
With DOUT reg:     addr ──[BRAM array]──[FF]──> data   (2 cycles, full block Fmax)
```

The array's clock-to-out consumes a large fraction of the period, so a latency-1
read leaves little time for the logic consuming it — Vivado will routinely report
the BRAM as the start point of your worst path.

**Project rule:** at 156.25 MHz, 6.4 ns is a generous period. **Start every fast-path
memory at read-latency 1 (output register OFF) and turn it on only when the timing
report says that specific path fails.** There are 3–4 memory reads on the
tick-to-trade path; leaving the output registers off saves ~20–25 ns of pure latency
for free. Highest value per unit of effort in the whole design.

```systemverilog
xpm_memory_tdpram #(
    .MEMORY_PRIMITIVE   ("block"),   // "block" | "ultra" | "distributed" | "auto"
    .MEMORY_SIZE        (8192*128),
    .READ_LATENCY_A     (1),         // <-- 1, not 2. Justify any change in the header.
    .READ_LATENCY_B     (1),
    .WRITE_MODE_A       ("read_first"),
    .WRITE_MODE_B       ("read_first"),
    .CLOCKING_MODE      ("independent_clock")
) u_symtab (...);
```

> ⚠️ Never write `MEMORY_PRIMITIVE("auto")` on the fast path. "Auto" lets the tool
> silently move a hot table into URAM on a rebuild, and URAM's extra cycle appears
> as an unexplained latency regression that nothing in your RTL diff accounts for.
> Pin the primitive explicitly, every time.

---

## 4. Read-during-write hazards — the silent killer

This is the single most dangerous section in this document, because the failure
mode is *simulation passes, hardware is wrong*.

### Same port, same address
Governed by the write mode you selected:

| Mode | Output on a write cycle |
| --- | --- |
| `WRITE_FIRST` (transparent) | The **new** data |
| `READ_FIRST` | The **old** data being overwritten |
| `NO_CHANGE` | The **previous** output, held |

### Different ports, same address — this is the trap

- Port A writes address X while port B reads address X on the same edge:
  **the read data is undefined.** Not old, not new — undefined.
- Both ports write address X on the same edge: **the stored data is corrupted.**

> ⚠️ A behavioural RTL memory model (`logic [W-1:0] mem [DEPTH]` with two
> `always_ff` blocks) will happily return a clean, deterministic value for both of
> these. Verilator will agree. Your testbench will pass. The hardware will not
> behave that way. **Assert against cross-port address collisions in simulation
> rather than relying on the model to reproduce them.**

```systemverilog
// Bind this to every dual-port memory on the fast path.
assert property (@(posedge clk) disable iff (rst)
    !(wr_en_a && (rd_en_b || wr_en_b) && (addr_a == addr_b))
) else $error("BRAM cross-port address collision at %0h — hardware result is undefined", addr_a);
```

### The order-book read-modify-write loop

The book update is `read level → add/subtract qty → write level`. With a 1-cycle
read plus a modify stage, the write lands 2 cycles after the read is issued. Two
messages touching the *same price level* within 2 cycles means the second read
returns stale data and one update is silently lost.

This is not a corner case: ITCH delivers `Order Executed` immediately followed by
`Order Delete` for the same order constantly, and iceberg replenishment produces
back-to-back same-level traffic all day.

**The fix is write-forwarding (bypass), not stalling.** Stalling adds jitter and can
back-pressure the RX path, which is forbidden.

```systemverilog
// ---- Stage 1: address issued, BRAM read in flight
// ---- Stage 2: BRAM data out, modify
// ---- Stage 3: write back
// A read at stage 1 whose address matches an in-flight write at stage 2 or 3 must
// take the in-flight value instead of the memory value.

logic [ADDR_W-1:0] addr_s1, addr_s2, addr_s3;
logic [DATA_W-1:0] wdata_s2, wdata_s3;
logic              wen_s2,  wen_s3;

logic [DATA_W-1:0] mem_dout;      // BRAM output, valid in stage 2
logic [DATA_W-1:0] level_s2;      // what stage 2 should actually operate on

always_comb begin
    // Priority: youngest in-flight write wins.
    if      (wen_s2 && (addr_s2 == addr_s1)) level_s2 = wdata_s2;  // 1-deep bypass
    else if (wen_s3 && (addr_s3 == addr_s1)) level_s2 = wdata_s3;  // 2-deep bypass
    else                                     level_s2 = mem_dout;
end
```

Rules for bypass logic:
1. **The bypass depth must equal the read-to-write distance, exactly.** If you turn
   on the BRAM output register (read latency 1 → 2), you must add a third bypass
   stage. ⚠️ Forgetting this is the classic regression when someone "fixes timing"
   by enabling the output register.
2. Derive the depth from the same parameter that sets the pipeline depth. Never two
   independent constants.
3. The comparator chain is combinational and sits on the critical path. Keep the
   address narrow (compare the *book slot index*, not a full price).
4. Write a directed test that fires N back-to-back updates to one price level for
   every N from 1 to `BYPASS_DEPTH + 2`. See
   [05-verification-and-simulation.md](05-verification-and-simulation.md).

---

## 5. FIFOs

| | Synchronous (`xpm_fifo_sync`) | Asynchronous (`xpm_fifo_async`) |
| --- | --- | --- |
| Clocks | 1 | 2, gray-coded pointers + 2-FF syncs |
| Empty-to-valid latency | **0 cycles** in first-word-fall-through (FWFT) mode | **~3–5 destination cycles** (pointer sync) |
| Where in this design | Anywhere in the core domain | **Exactly two places**: the MAC/transceiver boundary and the PCIe boundary |
| Hand-roll it? | Not worth it | **Never** — a rare pointer mis-sample at one phase relationship is essentially undebuggable |

- Always select **FWFT**: `dout` is valid as soon as `empty` de-asserts. Standard
  mode costs a read-latency cycle for nothing.
- Depth ≤ 32 at 64 bits maps to LUTRAM; larger goes to BRAM. A 16-deep skid FIFO is
  nearly free.
- The async FIFO's 3–5 cycles is 19–32 ns at 156.25 MHz — a real line item, and one
  more reason the datapath is a single clock domain. See
  [00-foundations/04-clocking-reset-and-cdc.md](../00-foundations/04-clocking-reset-and-cdc.md).

> **Verify:** the empty-to-valid latency of `xpm_fifo_async` in your configuration —
> PG311 *XPM FIFO*, confirmed with a cycle counter in simulation.

### Depth sizing for burst absorption

```
depth_beats  ≥  B_in × (1 − R_out / R_in)  +  L_react
```

- `B_in` — burst length in beats at the input rate
- `R_out / R_in` — sustained drain rate as a fraction of fill rate
- `L_react` — cycles before backpressure/flow control takes effect (for an async
  FIFO, the pointer sync round trip; ~6–10 beats)

**Worked example — 10GbE microburst at the Nasdaq open**

```
Datapath      : 64-bit @ 156.25 MHz = 8 B/cycle = 1.25 GB/s = 10 Gbps  (line rate)
Burst         : 100 µs sustained at 100 % line rate (opening auction cross)
                100 µs / 6.4 ns = 15,625 beats  →  B_in = 15,625
Consumer      : the book RMW pipeline stalls 1 cycle in 8 on same-level collisions
                that the bypass cannot cover  →  R_out/R_in = 7/8
L_react       : 8 beats

depth ≥ 15,625 × (1 − 0.875) + 8
      = 1,953 + 8
      = 1,961 beats  →  round up to 2,048

2,048 × 64 bits = 131,072 bits = 3.55 × BRAM36  →  4 BRAM36
```

Four BRAMs to survive a 100 µs full-rate burst — cheap. **Size generously:** an
overflow costs a dropped packet, a sequence gap, and a book resynchronization.

Now check the other direction: 2,048 beats of backlog is **13 µs of queueing
delay**. A deep FIFO means you are already trading on stale data. Hence:

> **Project rule:** every fast-path FIFO exposes a **high-water-mark register** and
> an occupancy histogram. A FIFO regularly more than ~10 % full means the downstream
> pipeline cannot keep up; fix the pipeline, do not grow the FIFO.

⚠️ Do not size FIFOs from the *average* message rate. The open, the close, and news
events are 10–100× the median. **Size from a real capture of your worst historical
minute.**

---

## 6. Banking and port contention

A BRAM gives you two ports. If a pipeline stage needs three accesses per cycle,
one of them will stall — and a stall on the RX path is forbidden.

| Requirement | Technique | Cost |
| --- | --- | --- |
| N reads, 1 writer | **Replicate**: N copies, all written identically, one read port each | N× memory |
| 1 read + 1 write, different addresses | True dual port (BRAM) | Free |
| 1 read + 1 write, same address | Dual port **+ bypass logic** (§4) | Combinational depth |
| N writes/cycle | **Bank** by address bits; only collisions stall | Collision jitter — count it |
| Host writes while datapath reads | Dual port with port B on the control clock (BRAM only) | Free for BRAM; needs arbitration for URAM |

**Banking the book:** split the price-level array across 2 or 4 BRAM banks by
low-order bits of the level index; two updates collide only within a bank. The
collision rate is low but neither zero nor uniform — real order flow clusters at the
touch, so bank on a *hashed* index if you observe hot-banking.

⚠️ **A banked memory with an arbiter has variable latency.** Either make it fixed
(always take the worst-case cycle count) or count every collision. An uncounted
collision is jitter you cannot explain later — see
[00-foundations/01-digital-logic-and-timing.md](../00-foundations/01-digital-logic-and-timing.md) §5.

**Replication for the top-of-book** is almost always right: strategy, risk, and
telemetry all want to read best bid/ask. Three copies of a small register file is
trivially cheap and removes an arbiter from the hot path.

---

## 7. Hash tables and set-associative lookup

The ITCH order-reference table is the one structure that genuinely needs hashing:
Nasdaq order reference numbers are 64-bit and sparse, and there can be millions
live at once.

### Structure

```
order_ref[63:0]
   │
   ├─ CRC-32 XOR tree (combinational, 1 LUT level deep per output bit)
   │
   └─> index[13:0]  ──> URAM set  ┌──────────────────────────────────────────┐
                                  │ way0: valid tag[49:0] payload            │
                                  │ way1: valid tag[49:0] payload            │
                                  │ way2: valid tag[49:0] payload            │
                                  │ way3: valid tag[49:0] payload            │
                                  └──────────────────────────────────────────┘
                                        │ 4 parallel tag comparators
                                        └──> hit / way_sel  (1 cycle)
```

| Property | Value |
| --- | --- |
| Latency | URAM read (2 cycles) + tag compare (1 cycle) = **3 cycles / 19.2 ns** |
| Throughput | 1 lookup/cycle if the ways are read as one wide row |
| Failure mode | Set full → the new order cannot be tracked |

### Design rules

1. **Read all ways in one wide access.** Store the four (valid, tag, payload)
   tuples as one URAM row — one read, then a 4-way parallel equality compare (one
   LUT level). Not four reads.
2. **CRC-based hashing is nearly free** (an XOR tree) and distributes far better
   than low-order bits. Nasdaq order refs are near-sequential so low bits happen to
   work today — and would concentrate catastrophically if the venue changed its
   allocation scheme. Use the CRC.
3. **Handle the full-set case explicitly**, in order of preference: a small
   fully-associative **victim CAM** in registers (8–16 entries); or 8-way
   associativity; or drop, count, and **mark that symbol untradeable** until the
   next session snapshot.
   ⚠️ Never silently drop an insert. An untracked order means a later
   `Order Executed` is applied to garbage, and the book is wrong in a way that will
   not self-heal.
4. **Deletion is just clearing the valid bit** — `Order Delete`, or `Order Executed`
   with zero remaining shares. No free list needed.
5. **Size from the real peak:** count concurrently-live order references over a full
   day's capture for your symbol universe, then double it. If it does not fit in
   URAM, **shrink the symbol universe.** That is the lever — not a spill to DDR.

For dense keys (ITCH `Stock Locate`, CME `SecurityID`) do **not** hash. Direct-index
into BRAM: one cycle, no comparators, no collisions. See
[01-rtl-design-patterns.md](01-rtl-design-patterns.md) §5.

---

## 8. Memory initialization and runtime table updates

Three mechanisms, in increasing order of runtime flexibility:

| Mechanism | When applied | Use for |
| --- | --- | --- |
| `INIT_xx` attributes / `$readmemh` in an `initial` block | Baked into the bitstream | True constants: CRC tables, protocol lookup ROMs, message-length tables |
| Host write via port B of a TDP BRAM | Any time | Daily symbol tables, risk limits, order templates, strategy parameters |
| Host write arbitrated into the core clock (URAM) | Any time, with a datapath write slot | The order-reference table's configuration, rarely |

### The atomic-swap rule

> ⚠️ **Never modify a live fast-path table in place.** A multi-word update to a
> per-symbol entry is not atomic. The datapath can read a half-updated entry — old
> price limit with a new size limit — and pass a risk check it should have failed.

Use **shadow banking**:

```systemverilog
// One extra address bit selects the bank. The datapath reads {active_bank, index};
// the host writes {~active_bank, index}. Flipping one register is atomic.
logic active_bank_q;

always_ff @(posedge clk)
    if (host_bank_flip_pulse) active_bank_q <= ~active_bank_q;

assign dp_addr   = {active_bank_q,  dp_index};
assign host_addr = {~active_bank_q, host_index};
```

Costs 2× the memory for the tables that need it (symbol table, risk limits, order
templates — all small). Buys a one-register-write, single-cycle, provably atomic
table swap mid-session. Worth it every time.

Rules:
- Every host-writable table has a **shadow bank and a flip register**. The flip
  register lives in the core clock domain, written through the standard slow-control
  CDC handshake.
- Every flip is **counted and timestamped**, and the active bank is readable, so a
  post-incident investigation can say which table was live at a given moment.
- URAM has no independent-clock second port, so its host writes steal a datapath
  cycle. Schedule them only when `!s_axis_tvalid`, and measure how long a full table
  load takes so you know it completes before the open.

---

## 9. ECC and soft errors

Two distinct phenomena:

| | Configuration memory upset | Block memory upset |
| --- | --- | --- |
| What flips | An SRAM cell holding LUT contents / routing | A data bit in BRAM/URAM |
| Effect | The *circuit itself* changes — arbitrary, persistent | One wrong data value |
| Detection | Vendor SEM IP (continuous CRC scan of config frames) | ECC on the block, or parity you add |
| Correction | SEM can correct single-bit frame errors; otherwise reconfigure | SECDED corrects single-bit |

> **Verify:** upset rates are device-, altitude-, and process-specific. Use the
> vendor's device reliability report (AMD publishes FIT/Mb figures per family) and
> the SEM IP documentation (PG036 / PG187) rather than any number quoted here.
> In a colocation facility at sea level the rate is low but non-zero, and you will
> run 24×5.

### When it matters for this project

| Data | Protect? | Rationale |
| --- | --- | --- |
| Risk limits, position limits, per-symbol enable bits | **Yes — always** | A flipped bit here lets through an order that should have been blocked. This is the regulatory-incident case. |
| Kill-switch state | **Yes** | Encode the "armed" state with a multi-bit pattern, not a single bit, so a single upset cannot disarm it. |
| Order templates (session ID, account, instrument) | **Yes** | A flipped byte sends a valid order with wrong attribution. |
| Order-reference table (URAM) | **Enable URAM's built-in SECDED** | It is nearly free and the table is large, so it has the highest exposure. |
| Price-level book | No | Self-heals on the next update for that level; count corrections if you have them, but don't pay latency. |
| FIFO data in flight | No | Covered by the Ethernet FCS end-to-end for received data. |

### Practical policy

1. Enable **URAM built-in ECC** on the order-reference table — it is in the block, so
   it costs no fabric logic, but check whether it forces the output register on.
   > **Verify:** URAM ECC latency and geometry constraints — UG573.
2. BRAM hard ECC exists only in one geometry (512×64 SDP). If your table does not
   naturally fit that shape, **do not distort the table to get it** — add a parity
   bit per entry and check it in fabric.
3. **Host-side scrub** for every config table: periodically read back the shadow
   bank, compare against the host's own copy, alarm on mismatch. This also catches
   upsets that corrupted a *write path*, which ECC alone does not.
4. Run the **SEM IP** and expose its counters. An uncorrectable configuration error
   means **trip the kill switch and reconfigure the device** — not keep trading.
5. Every ECC correction, parity error, and SEM event increments a sticky counter.
   See [06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md).

---

## 10. Project rules — where everything lives

| Data | Home | Read latency | Notes |
| --- | --- | --- | --- |
| Pipeline registers, valid flags, FSM state | **FF** | 0 | — |
| Delay lines for pipeline matching | **SRL** (no reset) | 0 | |
| Best bid/ask for the actively-traded set | **FF / LUTRAM**, replicated per consumer | 0 | Async read keeps compare in the same cycle |
| Symbol table (locate → book base, tick, limits, enable) | **BRAM**, direct-indexed, dual-port, **shadow-banked**, parity-protected | 1 | Port B on the PCIe clock |
| Order templates | **BRAM**, direct-indexed, shadow-banked | 1 | |
| Price-level book | **BRAM**, banked, with write-forwarding bypass | 1 | |
| Order-reference → order state | **URAM**, CRC-hashed 4-way set-associative, **ECC on** | 2 + 1 compare | Victim CAM for overflow |
| RX/TX packet FIFOs | **BRAM** (`xpm_fifo_sync`), FWFT | 0 (FWFT) | High-water-mark register mandatory |
| MAC / PCIe clock crossings | **`xpm_fifo_async`** | 3–5 | Only two of these exist in the design |
| Capture buffers, journals, logs | **DDR / HBM** | irrelevant | Slow path only |
| Historical data, model coefficients, symbol master | **Host RAM** | irrelevant | Pushed over PCIe on change |

**Never on the tick-to-trade path:** DDR, HBM, PCIe, AXI interconnect, any
variable-latency memory, `MEMORY_PRIMITIVE("auto")`, or an unbypassed
read-modify-write loop.

---

## Further reading

- [01-rtl-design-patterns.md](01-rtl-design-patterns.md) — CAMs, arbiters, delay lines, credit flow control
- [02-pipelining-and-parallelism.md](02-pipelining-and-parallelism.md) — II=1, the RMW feedback loop, width vs depth
- [04-io-transceivers-and-serdes.md](04-io-transceivers-and-serdes.md) — where the MAC-boundary async FIFO sits
- [00-foundations/02-fpga-architecture.md](../00-foundations/02-fpga-architecture.md) — what a BRAM/URAM physically is
- [00-foundations/04-clocking-reset-and-cdc.md](../00-foundations/04-clocking-reset-and-cdc.md) — the sanctioned CDC primitives
- [04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md) — the book structure these tables serve
- [05-optimization/03-resource-power-optimization.md](../05-optimization/03-resource-power-optimization.md) — when memory becomes the binding constraint
