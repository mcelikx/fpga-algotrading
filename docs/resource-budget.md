# Resource Budget

> The living LUT / FF / BRAM / URAM / DSP budget for this design, per block, against
> the master ceiling in the header of [`../rtl/fpga_top.sv`](../rtl/fpga_top.sv).
> It exists so that the memory arithmetic is done **before** the RTL, because the
> answer decides the floorplan and the floorplan decides whether the design closes
> timing at all. Governing manual:
> [`../manuals/05-optimization/03-resource-power-optimization.md`](../manuals/05-optimization/03-resource-power-optimization.md).
> Task: [`../TASKS.md`](../TASKS.md) P0.8.

| Field | Value |
| --- | --- |
| **Status** | Living document — allocations only, no actuals |
| **Date** | 2026-08-02 |
| **Owner** | Datapath lead (fast path) / Platform lead (slow path) |
| **Master ceiling** | `LUT < 60k   FF < 90k   BRAM < 300   URAM < 64   DSP < 16` |
| **Scope of that ceiling** | **Fast path only, one SLR**, VU9P-class |
| **Enforcement point** | [`../constraints/floorplan.xdc`](../constraints/floorplan.xdc) `pblock_fastpath` |
| **Core clock** | 156.25 MHz, 6.400 ns/cycle (`trading_pkg::CORE_CLK_KHZ`, `CORE_CLK_PS`) |

---

## 1. Target vs. estimated vs. actual

Every number in this document is exactly one of three things, and the word is always
present next to the number.

| Kind | Means | Where it comes from | May be quoted as fact? |
| --- | --- | --- | --- |
| **Target** | An **allocation**. A block is permitted this much. | Decided here, by dividing the master ceiling. | No — it is a budget line, not a measurement. |
| **Estimated** | Hand arithmetic (bit counts ÷ primitive size) or a module-header pre-synthesis figure. | The `RESOURCE ESTIMATE` blocks in the existing `rtl/` module headers, and §3 below. | No. Label it *estimated* every time. |
| **Actual** | Quoted **verbatim** from the **post-route** `report_utilization` output. | `rpt/util.rpt`, `rpt/util_fp.rpt` — none of which exist yet. | Yes, and only this. |

Per [`../CLAUDE.md`](../CLAUDE.md) §4: *"Report WNS/TNS and utilization from the actual
report, quoted verbatim. Never estimate or predict these."* Nothing in this document is
an actual. Every **actual** cell in §2 is `—` because **no block has been synthesized**.

> ⚠️ **Post-synthesis utilization is not post-route utilization, and quoting the first
> as if it were the second is a standard way to discover at 80 % complete that the
> design does not fit.** Synthesis reports pre-packing LUT counts; implementation packs
> logic into CLBs, absorbs LUTs into carry chains and SRLs, replicates high-fanout
> drivers, and infers or un-infers memories. The two routinely differ by 20 % or more
> in **either** direction
> ([`../manuals/00-foundations/02-fpga-architecture.md`](../manuals/00-foundations/02-fpga-architecture.md) §8).
> A synthesis number that fits is not evidence that the routed design fits, and a
> synthesis number that does not fit is not yet evidence that it doesn't. Only
> `report_utilization` run after `route_design`, against
> `[get_pblocks pblock_fastpath]`, is admissible here.

**The denominator is the SLR, not the device.** A VU9P has three SLRs and the fast path
is confined to one (ADR 0001, [`../constraints/floorplan.xdc`](../constraints/floorplan.xdc)).
The master ceiling is therefore already a per-SLR number, and it sits far below the
SLR's physical capacity on purpose — the binding constraint on this design is
**congestion**, not capacity.

| Primitive | Master ceiling | Approx. one VU9P SLR | Ceiling as % of SLR |
| --- | ---: | ---: | ---: |
| LUT | 60,000 | ~393,000 | ~15 % |
| FF | 90,000 | ~787,000 | ~11 % |
| BRAM36 | 300 | ~720 | ~42 % |
| URAM288 | 64 | ~320 | ~20 % |
| DSP48E2 | 16 | ~2,280 | ~0.7 % |

> **Verify:** VU9P per-device and per-SLR resource counts (~1.18 M LUT, ~2.36 M FF,
> 2,160 BRAM36, 960 URAM288, 6,840 DSP48E2, 3 SLRs; 720 BRAM36 and 320 URAM per SLR)
> against the **UltraScale+ FPGA product tables / device datasheet (DS923)** for the
> exact part, or `report_property` on the part in Vivado. SLRs are assumed identical —
> confirm for your device.

---

## 2. Per-block budget

One row per module instantiated in [`../rtl/fpga_top.sv`](../rtl/fpga_top.sv), using the
actual instance names. **Fast-path** rows are the ones the master ceiling governs.

### 2.1 Fast path — `pblock_fastpath`, SLR0

| Block | Owner | LUT target | FF target | BRAM target | URAM target | DSP target | LUT act. | FF act. | BRAM act. | URAM act. | DSP act. | Fast path? | SLR | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | --- |
| `u_md_eth` (×2) | Network lead | 6,000 | 2,000 | 4 | 0 | 0 | — | — | — | — | — | Y | SLR0 | `eth_10g_wrapper`; GT is hard IP. LUT is ~90 % the CRC-32 XOR cone in `crc32_eth`. 2 BRAM36 per lane = MAC-boundary async FIFO. |
| `u_oe_eth` | Network lead | 5,000 | 1,600 | 4 | 0 | 0 | — | — | — | — | — | Y | SLR0 | RX **and** TX MAC. 2 BRAM36 each direction. |
| `u_net_rx` | Network lead | 12,000 | 7,000 | 2 | 0 | 0 | — | — | — | — | — | Y | SLR0 | ⚠️ **LUT hog.** `moldudp64_deframer` is ~5,200 LUT *each* (×2 feeds) — a 528-bit 3-level byte barrel shifter plus a 10×16:1 64-bit word mux. Highest Rent exponent in the design. |
| `u_feed` | Feed owner | 3,600 | 3,600 | 5 | 0 | 0 | — | — | — | — | — | Y | SLR0 | `itch_decoder` + `symbol_filter` (4 BRAM36) + `venue_state` (1 BRAM36). |
| `u_book` | Book owner | 5,000 | 7,000 | 20 | **32** | 0 | — | — | — | — | — | Y | SLR0 | ⚠️ **Memory hog.** Order-ID map owns 32 URAM; price levels own 20 BRAM36. **Not written yet** — `rtl/book/` does not exist. |
| `u_strategy` | Strategy owner | 8,000 | 21,000 | 3 | 0 | 2 | — | — | — | — | — | Y | SLR0 | ⚠️ **FF hog.** `position_track` alone is ~14.5 k FF and ~5.2 k LUT (a 256:1 × 56-bit read mux), bought deliberately to accept emit/fill/force on three different symbols in one cycle with no arbiter. 2 DSP in `trigger_logic`. |
| `u_risk_gate` 🔒 | Risk owner | 3,800 | 4,000 | 9 | 0 | 2 | — | — | — | — | — | Y | SLR0 | 🔒 Non-bypassable, stays in the fast path even though it is "control" ([`../manuals/05-optimization/03-resource-power-optimization.md`](../manuals/05-optimization/03-resource-power-optimization.md) §8). 9 BRAM36 = `risk_params` active + shadow. DSP = `div100`, see §3.9. |
| `u_order_gw` | Gateway owner | 4,600 | 7,800 | 10 | 0 | 0 | — | — | — | — | — | Y | SLR0 | 10 BRAM36 = the per-symbol OUCH Enter-Order template array. |
| **Fast-path sub-total (target)** | | **48,000** | **54,000** | **57** | **32** | **4** | — | — | — | — | — | | | |
| **Reserved headroom** | Datapath lead | **12,000** | **36,000** | **243** | **32** | **12** | — | — | — | — | — | | | See §2.3 |
| **MASTER CEILING** | | **60,000** | **90,000** | **300** | **64** | **16** | | | | | | | | `fpga_top.sv` header |
| **Allocated / ceiling** | | **80 %** | **60 %** | **19 %** | **50 %** | **25 %** | | | | | | | | |

### 2.2 Outside the fast-path ceiling

These blocks are **not** governed by `LUT < 60k …`. The master ceiling is
**fast-path-only, one-SLR** — say so whenever the number is quoted, because a total
that silently folds the PCIe shell into the fast-path budget is both wrong and
alarming.

| Block | Owner | LUT target | FF target | BRAM target | URAM | DSP | Actual | Fast path? | SLR | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | :-: | :-: | :-: | --- |
| `u_clk_rst` | Platform lead | 300 | 400 | 0 | 0 | 0 | — | N | **unassigned** | MMCM/PLL + reset synchronizers. Deliberately given **no pblock**: the MMCM must sit in a clock region that can drive `core_clk` into both SLR0 and SLR1; pinning it to one SLR forces a worse clock route. |
| `u_telemetry` | Ops owner | 1,600 | 7,000 | 0 | 0 | 0 | — | N | SLR1 | Counter shadow bank + latency histogram, **all flip-flops, zero BRAM** — deliberately, so a host read can never contend for a datapath memory port ([`../manuals/06-operations/03-monitoring-and-telemetry.md`](../manuals/06-operations/03-monitoring-and-telemetry.md) §5). |
| `u_host_ctrl` | Platform lead | 8,000 | 8,000 | 8 | 0 | 0 | — | N | SLR1 | PCIe **hard block** (PCIE4C) + `pcie_wrapper` + `csr_regfile` + `dma_log_ring` + all CDC. The vendor IP's own utilization is reported by its `.xci` and is **on top of** this soft-logic figure. |
| **Slow-path sub-total (target)** | | **9,900** | **15,400** | **8** | **0** | **0** | — | | | Budgeted against SLR1, **not** against the master ceiling |

Block-to-SLR assignment above is not aspirational — it is what
[`../constraints/floorplan.xdc`](../constraints/floorplan.xdc) actually constrains:
`pblock_fastpath` (`EXCLUDE_PLACEMENT TRUE`, `-add {SLR0}`) names
`u_md_eth`, `u_net_rx`, `u_feed`, `u_book`, `u_strategy`, `u_risk_gate`, `u_order_gw`,
`u_oe_eth`; `pblock_slowpath` (`-add {SLR1}`) names `u_host_ctrl` and `u_telemetry`.

### 2.3 How the ceilings were divided, and why

1. **The book and the order map dominate memory.** 87 % of the entire on-chip working
   set is one structure — the order-ID map (§3.3). It gets **all** of the URAM
   allocation and a third of the BRAM. Nothing else on the fast path competes.
2. **The feed decoder and the strategy trigger dominate LUTs.** `u_net_rx` (barrel
   shifter + word mux) and `u_strategy` (`position_track`'s 256:1 read mux) are
   together 42 % of the LUT allocation. Both are *wide mux* structures, which is also
   the shape that congests worst — they are the two blocks to watch in
   `report_design_analysis -complexity`.
3. **DSP is near-zero because there is no floating point** ([`../CLAUDE.md`](../CLAUDE.md)
   §5 rule 3) and prices are ITCH-native scaled integers. The only fast-path multiplies
   are the `RECIP_100` reciprocal-multiply divide-by-100 for the SEC Rule 612
   whole-penny test (`trading_pkg::div100`) and the two imbalance multiplies in
   `trigger_logic`. Checksums and CRCs — Ethernet FCS, IP/UDP/TCP one's-complement,
   OUCH/SoupBin — are XOR and carry-save adder trees in **LUTs**, not DSPs. See §3.9
   for why the DSP count is 4 and not 1.
4. **FF headroom is deliberately large (40 %).** UltraScale+ carries ~2 FF per LUT;
   the manual's rule is *"Never reduce FF count"*
   ([`../manuals/05-optimization/03-resource-power-optimization.md`](../manuals/05-optimization/03-resource-power-optimization.md) §7).
   Register files that would otherwise be BRAM (position, venue state, top-of-book,
   telemetry) are bought in FF/LUTRAM on purpose, to buy back a cycle and to remove
   arbiters. That trade is what the FF headroom is for.
5. **BRAM headroom is very large (81 %) and that is a finding, not slack to spend.**
   The 300-BRAM ceiling was sized for a design that might hold books for the whole
   8192-locate space; we hold `N_ACTIVE = 256`. Concretely, the BRAM-resident
   structures scale linearly with `N_ACTIVE`, so the ceiling supports growing the
   active set to roughly **2048 symbols** before BRAM binds — at which point LUT and
   congestion will have bound first.
6. **LUT is at 80 % of ceiling and is the tightest column.** That is the honest state:
   see the verdict in §3.11.

---

## 3. The memory arithmetic

This is the substantive section. Every structure is worked from field widths to
primitive count. The primitive sizes:

| Primitive | Bits | Native geometry | Read latency (project rule) |
| --- | ---: | --- | --- |
| **BRAM36** | 36 Kbit = **36,864** | 32K×1 / 16K×2 / 8K×4 / 4K×9 / 2K×18 / 1K×36; SDP 512×72 | **1 cycle** (output register OFF by default) |
| **BRAM18** | 18 Kbit = **18,432** | half a BRAM36; 512×36 | 1 cycle |
| **URAM288** | 288 Kbit = **294,912** | **4096 × 72**, fixed | **2 cycles**, +1 per cascade hop |
| **LUTRAM** | 64×1 or 32×2 per LUT6 | SLICEM only | **0 cycles** (async read) |
| **FF** | 1 | — | 0 cycles |

> **Verify:** BRAM36 = 36,864 bits, URAM288 = 294,912 bits, the supported aspect
> ratios, the SDP 512×72 geometry, and URAM cascade behaviour against **UG573**
> (*UltraScale Architecture Memory Resources*) and the device datasheet. These are the
> figures used throughout §3 and every count below is wrong if they are wrong.
> Cross-check against
> [`../manuals/00-foundations/02-fpga-architecture.md`](../manuals/00-foundations/02-fpga-architecture.md) §2
> and [`../manuals/05-optimization/03-resource-power-optimization.md`](../manuals/05-optimization/03-resource-power-optimization.md) §9.

### 3.1 Symbol table / active-index filter — `u_feed` / `symbol_filter.sv`

Direct-indexed on the ITCH stock locate. **No hash**: Nasdaq locate codes are dense
integers, so the lookup is a 1-cycle direct index with no comparators and no collisions
([`../manuals/01-fpga-design/03-memory-and-storage.md`](../manuals/01-fpga-design/03-memory-and-storage.md) §7).

| Field | Width | Justification |
| --- | ---: | --- |
| `subscribed` — "we trade this locate" | 1 | Fail-closed: reset/unwritten = 0 = not traded. |
| `act_idx` — active-set index | `ACT_IDX_W` = **8** | Maps 8192 locates → 256 active slots. |
| **Entry width** | **9** | |

```
entry width         =                                9 bits
entries             = N_SYMBOLS                    8,192
bits per copy       = 8,192 × 9              =    73,728 bits
copies              = 2                                     (see below)
TOTAL               = 2 × 73,728             =   147,456 bits
```

**Primitive: BRAM36, direct-indexed, dual-port.** Configuration **4K × 9, two deep per
copy** — 4,096 × 9 = 36,864 bits, an exact BRAM36 fill. Two tiles give 8K × 9; the depth
extension is an address-MSB decode, not a cascade, so it costs no cycle.

```
BRAM36 per copy     = 8,192 / 4,096          =         2 tiles
BRAM36 total        = 2 copies × 2           =         4 tiles
bit efficiency      = 147,456 / (4 × 36,864) =      100 %
```

**Why two physical copies and not one dual-port memory.** The fast path (book event
stream) and the venue-state path (ITCH `H`/`h`/`Y`/`J` handling) each need an
independent single-cycle read *in the same cycle*, and the host needs a write port.
That is three simultaneous accesses; a true-dual-port BRAM offers two. Replicating a
73,728-bit table costs 2 extra tiles out of 300 and removes an arbiter from the hot
path — see §5, hazard 1. This matches `symbol_filter.sv`'s own header estimate of
`BRAM36 ~4`.

### 3.2 Per-symbol venue / trading state — `u_feed` / `venue_state.sv`

For the active set only: `N_ACTIVE = 256`.

| Field | Width | Home |
| --- | ---: | --- |
| `trade_state_e` | 3 | **FF** |
| SSR (Reg SHO Rule 201) bit | 1 | **FF** |
| stale bit | 1 | **FF** |
| capacity-overflow bit | 1 | **FF** |
| LULD lower band (`PRICE_W`) | 32 | small RAM |
| LULD upper band (`PRICE_W`) | 32 | small RAM |
| **Entry width** | **70** | |

```
FF-resident bits    = 256 × (3+1+1+1)        =     1,536 bits  ->  1,536 FF
RAM-resident bits   = 256 × (32+32)          =    16,384 bits  ->  1 BRAM36 (or LUTRAM)
TOTAL               = 256 × 70               =    17,920 bits
```

**Verdict: flip-flops for the state/flag bits; LUTRAM or one BRAM36 for the LULD band
store.** Three reasons, in order of force:

1. **Reset value.** `trade_state_e`'s reset value is `TRADE_DISABLED = 3'd7`, which is
   fail-closed and **non-zero**. A BRAM's contents are set by `INIT_xx` at *device
   configuration*, not by a runtime synchronous reset. A soft reset mid-session would
   leave a BRAM-resident state table holding whatever it held before — which is
   `TRADE_OPEN` for every symbol we were trading. Flip-flops can be synchronously
   reset to `3'd7`. This is not a performance argument; it is a safety argument.
2. **Port count.** The strategy, the risk gate, and telemetry all want this state in
   the same cycle. Registers give unlimited reads.
3. **Latency.** [`../TASKS.md`](../TASKS.md) **P11.7** names *"move the symbol lookup
   from BRAM into LUTRAM or registers if the universe is small enough"* as **worth a
   full cycle** — 6.4 ns off the tick-to-trade path. At 256 entries the universe is
   small enough. 1,536 FF is 1.7 % of the FF ceiling for a cycle. Take it.

Matches `venue_state.sv`'s header: `FF ~1,600, BRAM36 ~1`.

### 3.3 Order-ID map — `rtl/book/order_map.sv` **(not written)**

The one structure that genuinely needs hashing: ITCH order reference numbers are 64-bit
and sparse. `ORDER_MAP_ENTRIES = 65536`, `ORDER_MAP_WAYS = 4`.

```
sets                = 65,536 / 4              =    16,384 sets
set index width     = log2(16,384)            =        14 bits
```

⚠️ **Assumption A4 (§4):** that `ORDER_MAP_ENTRIES` counts *entries*, not *sets*. If it
counts sets, every figure below multiplies by 4 and the map needs **128 URAM**, which
**exceeds the 64-URAM ceiling by 2×**. `trading_pkg.sv` does not say. This must be
pinned in ADR 0007 before `order_map.sv` is written.

**Payload per way** (everything a later `E`/`C`/`X`/`D`/`U` needs to apply the event):

| Field | Type | Bits |
| --- | --- | ---: |
| `sym_idx` | `sym_idx_t` | 8 |
| `side` | `side_e` | 1 |
| `price` | `price_t` | 32 |
| `qty` | `qty_t` | 32 |
| `valid` | | 1 |
| **Payload** | | **74** |

**The tag decision.** The index is a CRC-32 fold of the 64-bit reference, so the index
bits do **not** reconstruct any part of the key. The tag is the only thing that
distinguishes two references that hash to the same set.

| Option | Tag bits | Way width | Set width | Total bits | URAM (ideal) | URAM (realized) | False-match probability per lookup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| **A — full reference** | 64 | 138 | 552 | **9,043,968** | 30.67 → 31 | **32** | **0 — structurally impossible** |
| **B — truncated tag** | 50 | 124 | 496 | 8,126,464 | 27.56 → 28 | **28** | ≈ 4 × 2⁻⁵⁰ ≈ 3.6 × 10⁻¹⁵ |
| C — short tag | 32 | 106 | 424 | 6,946,816 | 23.55 → 24 | 24 | ≈ 4 × 2⁻³² ≈ 9.3 × 10⁻¹⁰ |

*Realized* counts account for the URAM's fixed 72-bit port width: a whole set must be
read in one access, so the array is `ceil(set_width / 72)` URAMs **wide**, and
`16,384 / 4,096 = 4` URAMs **deep**.

```
Option A:  ceil(552 / 72) = 8 wide   ×   4 deep   =  32 URAM
           width efficiency = 552 / (8 × 72)      =  95.8 %
Option B:  ceil(496 / 72) = 7 wide   ×   4 deep   =  28 URAM
```

What "negligible" means numerically. Take an order-of-magnitude 10⁸ book messages per
session for a 256-symbol active set. The exposure is only lookups of references we
never inserted (a reference whose `Add` we dropped or missed in a gap) — the symbol
filter runs *before* the map, so we never look up references outside the active set.

| Option | False matches per session (10⁸ lookups, worst case) | Mean time between false matches |
| --- | ---: | --- |
| A | **0** | never |
| B (50-bit) | 3.6 × 10⁻⁷ | ~10⁷ sessions |
| C (32-bit) | 9.3 × 10⁻² | ~11 sessions |

> ⚠️ **A false tag match returns the *wrong order's* attributes.** The book then applies
> an execute or a delete to the wrong symbol, at the wrong price, for the wrong
> quantity — and **nothing signals an error**. The book is silently wrong, does not
> self-heal, and the strategy trades on it. Option C's "once every eleven sessions" is
> not a rare corner case; it is a recurring, undiagnosable, money-losing event.

**Decision: Option A — store the full 64-bit `order_ref_t`.** The cost is 4 URAM over
Option B: **32 of the 64 ceiling, 6 % of the ceiling spent to make an entire class of
silent corruption structurally impossible.** That is the cheapest correctness anyone
will buy on this project.

**Check against the ceiling: 32 ≤ 64 → PASS, at exactly 50 %.** But see the revisit
trigger: doubling `ORDER_MAP_ENTRIES` to 128 K consumes the whole URAM ceiling.

**Organization — 4 parallel banks, never a cascade.** The 4-deep dimension is selected
by `index[13:12]` as **parallel banks with a decoded enable**, not as a URAM cascade.
See §5, hazard 2.

**Overflow handling.** A 16-entry fully-associative victim CAM in registers, per
[`../manuals/01-fpga-design/03-memory-and-storage.md`](../manuals/01-fpga-design/03-memory-and-storage.md) §7
rule 3: `16 × 138 = 2,208 bits` (2,208 FF) plus a 16-way 64-bit equality tree and
priority encoder, ~400 LUT. ⚠️ An insert that is silently dropped means a later
`Order Executed` is applied to garbage — the CAM exists so that the drop, when it
happens, is counted and the symbol marked untradeable rather than ignored.

**ECC.** Enable the URAM built-in SECDED — it is in the block, costs no fabric, and
this is by far the largest and most exposed memory in the design.
> **Verify:** whether URAM ECC forces the output register on (and therefore costs a
> cycle) — **UG573**. If it does, that cycle is a latency-budget line item, not a free
> lunch; record it in [`latency-budget.md`](latency-budget.md).

### 3.4 Price-level memory — `rtl/book/level_mem.sv` **(not written)**

```
slots               = N_ACTIVE × 2 sides × BOOK_LEVELS
                    = 256 × 2 × 16                =     8,192 slots
```

| Field | Type | Bits |
| --- | --- | ---: |
| Price | `price_t` | 32 |
| Aggregate quantity | `qty_t` | 32 |
| Order count | | 16 |
| **Entry** | | **80** (pad to 90 for the 2K×18 aspect) |

```
TOTAL               = 8,192 × 80              =   655,360 bits
ideal BRAM36        = 655,360 / 36,864        =     17.78  ->  18 tiles
```

**Banked, per [`../TASKS.md`](../TASKS.md) P4.3** — *"banked so that consecutive updates
to different levels don't contend for a port"*. Bank on the low 2 bits of the level
index → **4 banks**:

```
per bank            = 8,192 / 4               =     2,048 slots
per bank geometry   = 2,048 deep × 90 wide (80 used, padded)
BRAM36 per bank     = ceil(90 / 18) at 2K×18  =         5 tiles
BRAM36 total        = 4 banks × 5             =        20 tiles
bit efficiency      = 655,360 / (20 × 36,864) =      88.9 %
```

The 2 tiles over the ideal 18 are the banking-plus-aspect-ratio tax, paid to remove a
port collision. (The 1K×36 aspect is worse: `ceil(80/36) = 3` wide × 2 deep × 4 banks =
24 tiles.)

**Level-occupancy bitmap** — the structure ADR 0007 uses for the bounded new-best search
([`../TASKS.md`](../TASKS.md) P4.5: *"maintain a level-occupancy bitmap and use a
priority encoder — prefer the bitmap"*):

```
bits                = 256 sym × 2 sides × 16 levels  =  8,192 bits
geometry            = 512 words × 16 bits
```

**Primitive: LUTRAM, 0 BRAM.** It must be read, priority-encoded, **and** updated in the
same cycle as the level write, so the read has to be asynchronous — a BRAM read is
synchronous by construction and would add a cycle to the *variable-latency* stage, the
one stage in the master budget that is already the jitter source.

```
LUTRAM cost         = 16 bits × ceil(512/64)  =       128 LUT6 as RAM
priority encoder    = 16-bit                   =    ~40 LUT6
update / write path                            =   ~200 LUT6
```

**Banking implication.** Per book event the pipeline needs, in one cycle: (a) the level
read for the read-modify-write, (b) the write-back of the previous event's level,
(c) the occupancy word, (d) top-of-book. A true-dual-port BRAM provides exactly two
ports; (a) and (b) consume both. **This is why (c) is LUTRAM and (d) is registers — not
capacity, ports.** See §5, hazard 1.

The RMW loop additionally needs **write-forwarding bypass** matched to the read-to-write
distance, per
[`../manuals/01-fpga-design/03-memory-and-storage.md`](../manuals/01-fpga-design/03-memory-and-storage.md) §4.
⚠️ If the BRAM output register is ever enabled to fix timing, the bypass must gain a
third stage in the same commit, or back-to-back updates to one price level silently
lose one.

**Top-of-book** — held for the whole active set, replicated per consumer:

```
entry               = 32+32+32+32+32 + 4 flags        =      164 bits
TOTAL               = 256 × 164                       =   41,984 bits
LUTRAM per copy     = 164 × ceil(256/64)              =      656 LUT6
copies (strategy / risk / telemetry)                  =        3
LUT cost            = 3 × 656                         =   ~1,968 LUT6
```

Replication rather than arbitration, per
[`../manuals/01-fpga-design/03-memory-and-storage.md`](../manuals/01-fpga-design/03-memory-and-storage.md) §6:
*"Replication for the top-of-book is almost always right."*

### 3.5 Risk parameter table — `u_risk_gate` / `risk_params.sv` (**×2 for ADR 0011**)

`sym_risk_t` field widths, summed explicitly from
[`../rtl/pkg/trading_pkg.sv`](../rtl/pkg/trading_pkg.sv):

| Field | Type | Bits |
| --- | --- | ---: |
| `enabled` | `logic` | 1 |
| `shortable` | `logic` | 1 |
| `max_order_qty` | `qty_t` | 32 |
| `max_order_notional` | `notional_t` | 64 |
| `max_long_pos` | `position_t` | 40 |
| `max_short_pos` | `position_t` | 40 |
| `collar_lo` | `price_t` | 32 |
| `collar_hi` | `price_t` | 32 |
| `luld_lo` | `price_t` | 32 |
| `luld_hi` | `price_t` | 32 |
| `ssr_active` | `logic` | 1 |
| `max_open_orders` | `logic [15:0]` | 16 |
| `tick_penny` | `logic` | 1 |
| **`$bits(sym_risk_t)`** | | **324** |

(Confirmed against `telemetry_pkg.sv`: *"sym_risk_t is 324 bits → 11 words used, 12
allocated"*.)

```
ACTIVE bank  (fast-path read, record-addressed, written only by the commit engine)
  bits              = 256 × 324                 =    82,944 bits
  geometry          = 256 deep × 324 wide
  BRAM36 (SDP 512×72) = ceil(324/72) = 5 wide × 1 deep  =   5 tiles
  bit efficiency    = 82,944 / (5 × 36,864)     =      45 %   <- wide-shallow tax

SHADOW bank  (host-written, word-addressed {sym[7:0], word[3:0]})
  bits              = 4,096 words × 32          =   131,072 bits
  BRAM36 (1K×36)    = ceil(4096/1024) = 4 deep  =   4 tiles

  RISK TOTAL                                    =   9 BRAM36
```

**The ×2 is not 2×.** The conceptual double-buffer cost is `82,944 × 2 = 165,888` bits.
As built it is `82,944 + 131,072 = 214,016` bits — **2.58× the single-bank record
store**. The extra 48 k bits are the shadow bank's 16-word address stride, of which only
11 words per symbol are used (31 % waste), bought deliberately so the write address is
a pure concatenation `{sym, word}` with **no multiplier on an address path**. That is a
real, quantified cost of the parameter-update decision and it belongs in ADR 0011's
consequences, not hidden in a rounding.

The 45 % bit efficiency on the active bank is the price of a 324-bit-wide, 256-deep
record: five BRAM36 tiles are needed to deliver 324 bits in one access, and each is only
half-depth-utilized. Widening `N_ACTIVE` to 512 would cost **zero extra tiles**.

### 3.6 Strategy parameter table — `u_strategy` / `param_table.sv` (**×2 for ADR 0011**)

`sym_strat_t` field widths, summed explicitly:

| Field | Type | Bits |
| --- | --- | ---: |
| `strat_enabled` | `logic` | 1 |
| `strat_select` | `logic [3:0]` | 4 |
| `quote_qty` | `qty_t` | 32 |
| `edge_ticks` | `price_t` | 32 |
| `min_book_qty` | `qty_t` | 32 |
| `fair_value` | `price_t` | 32 |
| `imbalance_thr` | `logic [15:0]` | 16 |
| **`$bits(sym_strat_t)`** | | **149** |

(Confirmed against `telemetry_pkg.sv`: *"sym_strat_t is 149 bits → 5 words used, 8
allocated"*. `param_table.sv` stores **6** words — see the discrepancy in §6.)

```
words per entry     = N_PARAM_WORDS                   =         6
entries × banks     = 256 × 2                         =       512
bits                = 512 × 6 × 32                    =    98,304 bits
geometry            = 6 memories, each 512 deep × 32 wide
BRAM18 per memory   = 16,384 bits into a 512×36 RAMB18 =        1
BRAM18 total        = 6      ->  BRAM36 equivalent     =         3 tiles
```

**Here the ×2 is free.** The bank select is the **address MSB**, so both banks share one
memory. A single-bank 256×32 array would occupy the same 6 RAMB18 tiles it does at 512
deep, because a RAMB18's minimum useful depth in this aspect is 512. **Double-buffering
the strategy table costs zero additional primitives** — the doubling disappears into
depth the primitive was giving away anyway. Worth recording precisely because the risk
table (§3.5) shows the opposite result: the same ADR costs 2.58× there and 1.0× here.

Completeness bits (`word_ok`, so a record is readable only when all its words have
landed and passed their field check):

```
FF                  = 2 banks × 256 × 6               =     3,072 FF
```

### 3.7 OUCH order templates — `u_order_gw` / `ouch_encoder.sv` ([`../TASKS.md`](../TASKS.md) P6.7)

Per-symbol pre-built templates in BRAM; on trigger, read the template and splice in
price, size, side and token. Geometry taken from the RTL, **not assumed**:

```
OUCH_IN_MAX_LEN     = 64 bytes                (ouch_pkg.sv; OUCH_ENTER_LEN = 49, padded)
TMPL_MSG_WORDS      = 64 / 4                          =        16 words
TMPL_META_WORDS     = 4                                          (length, partial
                                                                  checksum, valid,
                                                                  splice offsets)
TMPL_WORDS          = 16 + 4                          =        20 words
row width           = 20 × 32                         =       640 bits
entries             = N_ACTIVE                        =       256
TOTAL               = 256 × 640                       =   163,840 bits
```

> **Verify:** `OUCH_ENTER_LEN = 49` and the Enter Order field layout against the
> **Nasdaq OUCH 5.0 specification**. `ouch_pkg.sv` itself notes that the venue may
> extend the message, in which case 49 is a minimum, not a fixed length.

**Primitive: 20 parallel BRAM18 banks, each 256 × 32.**

```
BRAM18              = 20 banks                        =        20
BRAM36 equivalent   = 20 / 2                          =        10 tiles
bit efficiency      = 163,840 / (10 × 36,864)         =      44.4 %
```

Why 20 narrow banks rather than one 640-bit-wide SDP array (which would be
`ceil(640/72) = 9` BRAM36, marginally fewer tiles): the **host write port is 32 bits
wide**. A single wide array would force a read-modify-write on every template word the
host pushes. Banking gives a decoded per-bank write enable and a one-cycle 640-bit read.
The 44 % bit efficiency is the cost of that, and it is **not** a bit-count problem — it
is the port-shape problem of §5, hazard 1, showing up as tiles.

Cancel templates: `4 shapes × 12 words × 32 = 1,536 bits` → LUTRAM/FF, 0 BRAM.

### 3.8 Telemetry — `u_telemetry` (outside the fast-path ceiling)

The shadow bank, from `telemetry_pkg.sv`'s address map:

| Region | Words |
| --- | ---: |
| `md_mac_stat[2][4]` | 8 |
| `oe_mac_stat[4]` | 4 |
| `net_stat[8]` | 8 |
| `feed_stat[16]` | 16 |
| `book_stat[16]` | 16 |
| `strat_stat[16]` | 16 |
| `risk_stat[8]` | 8 |
| `risk_reject_cnt[N_RISK_REASONS]` | 24 |
| `order_stat[16]` | 16 |
| **Total snapshotted words** | **116** |

```
shadow bank         = 116 × 32                        =     3,712 bits  ->  3,712 FF
latency histogram   = N_BUCKETS(32) × CNT_W(32) live
                      + 32 × 32 shadow                =     2,048 bits
  + LAT_MIN/MAX (24 each), LAT_SUM (56), LAT_N (32),
    LAT_OVER (32), LAT_LAST (24)                      =      ~250 bits
histogram FF (incl. control)                                ~2,300 FF
TELEMETRY TOTAL                                       =   0 BRAM, 0 URAM, ~6.5 k FF
```

All flip-flops, zero BRAM — structurally, so that a host counter scrape can never
contend for a datapath memory port
([`../manuals/06-operations/03-monitoring-and-telemetry.md`](../manuals/06-operations/03-monitoring-and-telemetry.md) §5).

### 3.9 DSP accounting

| Site | Operation | DSP (est.) | Note |
| --- | --- | ---: | --- |
| `trading_pkg::div100` in `u_risk_gate` | `px[31:0] × RECIP_100[31:0] >> 37`, Rule 612 whole-penny test | **2** | See below |
| `trigger_logic` in `u_strategy` | two 24×16 imbalance multiplies, one per direction | **2** | Module header, verbatim |
| Ethernet FCS, IP/UDP/TCP one's-complement, SoupBin/OUCH checksum | XOR / carry-save trees | **0** | LUT-based by construction |
| Everything else | — | **0** | No floating point ([`../CLAUDE.md`](../CLAUDE.md) §5 rule 3) |
| **Total** | | **4** of 16 | |

⚠️ **Two discrepancies in the DSP story, both flagged rather than fixed:**

1. `trading_pkg.sv` states of `div100`: *"The multiply maps to one DSP48."* A DSP48E2 is
   a **27 × 18** multiplier. A 32 × 32 product does not fit one of them; the naive
   mapping is 4, a decomposed one is 2–3. **Budgeted 2.**
2. `RECIP_100` is a **compile-time constant**, and
   [`../manuals/05-optimization/03-resource-power-optimization.md`](../manuals/05-optimization/03-resource-power-optimization.md) §10
   says a constant multiply should be *"shift/add in LUTs"*, not a DSP. Vivado will very
   likely infer a constant-coefficient multiplier in LUTs and carry chains, making the
   actual DSP count for `div100` **0** and adding ~300–500 LUT instead. Either outcome
   fits. **Do not resolve this by argument — read `report_utilization` and record which
   happened.**

### 3.10 Structure inventory and grand total

| # | Structure | Entry bits | Entries | Total bits | Primitive | Count |
| --- | --- | ---: | ---: | ---: | --- | ---: |
| M1 | Symbol filter table (2 copies) | 9 | 8,192 × 2 | 147,456 | BRAM36 | 4 |
| M2a | Venue state / flags | 6 | 256 | 1,536 | FF | — |
| M2b | LULD band store | 64 | 256 | 16,384 | BRAM36 | 1 |
| M3a | **Order-ID map** (full 64-bit tag) | 552/set | 16,384 sets | **9,043,968** | **URAM288** | **32** |
| M3b | Victim CAM | 138 | 16 | 2,208 | FF | — |
| M4a | Price-level array (4 banks) | 80 | 8,192 | 655,360 | BRAM36 | 20 |
| M4b | Level-occupancy bitmap | 16 | 512 | 8,192 | LUTRAM | ~128 LUT6 |
| M4c | Top-of-book (×3 replicas) | 164 | 256 | 41,984 | LUTRAM | ~1,968 LUT6 |
| M5a | Risk params — active bank | 324 | 256 | 82,944 | BRAM36 | 5 |
| M5b | Risk params — shadow bank | 32 | 4,096 | 131,072 | BRAM36 | 4 |
| M5c | Strategy params — both banks | 192 | 512 | 98,304 | BRAM18 | 6 (= 3 BRAM36) |
| M5d | Strategy `word_ok` | 6 | 512 | 3,072 | FF | — |
| M6a | OUCH Enter templates | 640 | 256 | 163,840 | BRAM18 | 20 (= 10 BRAM36) |
| M6b | OUCH Cancel templates | 384 | 4 | 1,536 | LUTRAM/FF | — |
| M7a | Telemetry shadow bank | 32 | 116 | 3,712 | FF | — |
| M7b | Latency histogram (live + shadow) | 32 | 64 | 2,048 | FF | — |
| | **Structure total** | | | **10,403,616 bits** | | |
| — | MAC-boundary async FIFOs (2 × md, 2 × oe) | — | — | — | BRAM36 | 8 |
| — | `u_net_rx` dedup / skid | — | — | — | BRAM36 | 2 |

```
GRAND TOTAL BITS      = 10,403,616 bits  =  10.40 Mbit  =  ~1.30 MB
  of which order-ID map = 9,043,968       =  86.9 %      <- one structure

BRAM-resident bits    =  1,295,360 bits in 47 BRAM36 tiles  ->  74.8 % bit efficiency
URAM-resident bits    =  9,043,968 bits in 32 URAM tiles    ->  95.8 % bit efficiency
LUTRAM/FF-resident    =     64,288 bits
                        -----------
                        10,403,616  ✓

BRAM36 TOTAL          = 47 (structures) + 10 (FIFOs)  =  57
URAM288 TOTAL         =                                  32
```

### 3.11 Verdict against the ceiling

| Primitive | Allocated | Ceiling | Utilization | Verdict | Reason |
| --- | ---: | ---: | ---: | :-: | --- |
| **LUT** | 48,000 | 60,000 | 80 % | ⚠️ **AT RISK** | Two of the three largest contributors — `moldudp64_deframer`'s 528-bit barrel shifter and `position_track`'s 256:1 × 56-bit read mux — are **pre-synthesis module-header estimates that have never been synthesized**, and both are the wide-mux shape that synthesis inflates. A 25 % miss on either eats the entire 12 k headroom. This is the column to watch. |
| **FF** | 54,000 | 90,000 | 60 % | ✅ **PASS** | Comfortable, and deliberately so — FF is bought to avoid arbiters and BRAM cycles. |
| **BRAM36** | 57 | 300 | 19 % | ✅ **PASS** | Large margin. Supports growing `N_ACTIVE` to ~2048 before it binds. |
| **URAM288** | 32 | 64 | 50 % | ✅ **PASS**, with a trigger | Owned entirely by the order-ID map. Doubling `ORDER_MAP_ENTRIES`, or resolving assumption A4 the other way, **exceeds the ceiling**. |
| **DSP48E2** | 4 | 16 | 25 % | ✅ **PASS** | May be as low as 2 if `div100` infers as LUT logic. |

**Nothing here exceeds a ceiling.** The two things that would are named, not buried:
assumption A4 on `ORDER_MAP_ENTRIES` (URAM → 128, **2× over**), and a synthesis miss on
the two wide-mux blocks (LUT → over 60 k).

---

## 4. Assumptions

Every one of these must be either confirmed or replaced by a measurement before this
budget is treated as sound.

| # | Assumption | If wrong |
| --- | --- | --- |
| **A1** | BRAM36 = 36,864 bits; BRAM18 = 18,432; URAM288 = 294,912. > **Verify:** UG573 / DS923. | Every tile count in §3 is wrong. |
| **A2** | BRAM aspect ratios 32K×1 … 1K×36 and SDP 512×72; URAM native 4096×72. > **Verify:** UG573. | Realized tile counts change even though bit counts don't. |
| **A3** | VU9P per-SLR capacity: 720 BRAM36, 320 URAM, ~393 k LUT, ~787 k FF. > **Verify:** DS923 / `report_property`. | The §1 context table is wrong; ceilings unaffected. |
| **A4** | ⚠️ `ORDER_MAP_ENTRIES = 65536` counts **entries**, giving 16,384 sets of 4 ways. | If it counts **sets**, the map needs **128 URAM** — **2× over the ceiling**. Highest-impact open assumption in this document. |
| **A5** | Order-map payload is 74 bits (sym, side, price, qty, valid). No exchange timestamp, MPID, or display/hidden flag is stored. | Each added field costs `16,384 × 4 × w` bits; +8 bits/way = +2 URAM. |
| **A6** | Price-level entry carries a 16-bit order count (manual §9 default). | Dropping it saves ~2 BRAM36; widening it costs the 90-bit pad. |
| **A7** | Level-occupancy bitmap is exactly 1 bit per (symbol, side, level) = 8,192 bits. | Rechecked when ADR 0007's new-best search bound is fixed. |
| **A8** | MAC-boundary async FIFO = 2 BRAM36 per direction. ⚠️ **Not sized from a capture.** [`../manuals/01-fpga-design/03-memory-and-storage.md`](../manuals/01-fpga-design/03-memory-and-storage.md) §5 requires sizing from *"a real capture of your worst historical minute"*, not from an average. | Undersized → drops at the MAC boundary, which is a design bug. Oversized → queueing delay, i.e. trading on stale data. |
| **A9** | Victim CAM = 16 entries (manual §7 says 8–16). | Linear in LUT and FF; not a tile-count risk. |
| **A10** | Top-of-book replicated ×3 (strategy, risk, telemetry). | Each extra consumer is ~656 LUT6. |
| **A11** | `div100` costs 2 DSP. May be 0 (LUT constant-coefficient) or 4 (naive 32×32). | ±4 DSP against a ceiling of 16; ±500 LUT. |
| **A12** | `clk_rst_gen`, `eth_10g_wrapper`, `net_rx_path`, `book_engine`, `strategy_engine`, `risk_gate`, `order_gateway`, `host_ctrl` **do not exist as RTL**. Their rows are allocations assembled from the leaf modules that *do* exist, plus glue. `rtl/book/` does not exist at all, so **every number in §3.3 and §3.4 is unbacked by any code**. | The two largest memory consumers in the design are the two with no implementation. |
| **A13** | `u_host_ctrl`'s figure excludes the PCIe hard-block IP's own fabric utilization, which is reported by its `.xci`. | Slow-path SLR1 budget only; does not touch the master ceiling. |

---

## 5. ⚠️ Hazards

### Hazard 1 — memory that fits by bit count but not by port count

**A structure needing three simultaneous accesses cannot live in one true-dual-port
BRAM regardless of capacity.** The failure mode is not an error message:

```
you write it as one array  →  the tool cannot give you 3 ports
                           →  it silently REPLICATES the memory (utilization jumps,
                              maybe past the ceiling, with no RTL diff to explain it)
                           →  or it infers registers instead (LUT/FF explode)
                           →  or it inserts an arbiter (variable latency — jitter,
                              on a path you budgeted as fixed)
```

All three synthesize. All three pass simulation. Two of them are latency regressions
and one is a resource regression, and none announces itself.

This is the single reason for four decisions in §3, and it is worth stating that they
are **port decisions, not capacity decisions**:

| Structure | Bits | Would fit in | Actually costs | Because |
| --- | ---: | --- | --- | --- |
| Symbol filter table (§3.1) | 147,456 | 2 BRAM36 | **4 BRAM36** | fast path + venue path + host write = 3 ports |
| Top-of-book (§3.4) | 41,984 | 2 BRAM36 | **~2,000 LUT6** | strategy + risk + telemetry read in the same cycle |
| Occupancy bitmap (§3.4) | 8,192 | 1 BRAM36 | **~370 LUT6** | must be read *asynchronously* alongside the level RMW |
| OUCH templates (§3.7) | 163,840 | ~5 BRAM36 | **10 BRAM36** | 32-bit host writes vs. 640-bit fast-path reads |

The check to run, every time, before writing a memory: **count the accesses per cycle,
not the bits.**

### Hazard 2 — URAM cascade latency is invisible in RTL

Each URAM cascade hop adds a pipeline stage
([`../manuals/01-fpga-design/03-memory-and-storage.md`](../manuals/01-fpga-design/03-memory-and-storage.md) §3;
[`../manuals/05-optimization/03-resource-power-optimization.md`](../manuals/05-optimization/03-resource-power-optimization.md) §9).

> ⚠️ **A memory that fits but is deeply cascaded costs latency you did not budget, and
> nothing in the RTL shows it.** The order-ID map is 4 URAMs deep. Built as a cascade
> that is **+3 cycles = +19.2 ns** on the tick-to-trade path — against a master budget
> whose *entire* order-map stage is 2 cycles / 12.8 ns. The design would be 15 % slower
> than its budget with no line in the budget accounting for it.

**Mitigation, mandatory:** the 4-deep dimension is **parallel banks selected by
`index[13:12]` with a decoded enable**, never a `CASCADE_ORDER` chain. Assert it in the
build: any URAM in `u_book` with a non-`NONE` cascade property is a build failure. If
the map ever must grow deeper, it grows **wider in banks**, not longer in cascade.

Every cycle attributed to a memory primitive — URAM's baseline 2, any cascade hop, any
BRAM output register turned on to fix timing — is a line item in
[`latency-budget.md`](latency-budget.md), not a local decision.

### Hazard 3 — congestion arrives as latency, not as a utilization failure

The causal chain
([`../manuals/05-optimization/03-resource-power-optimization.md`](../manuals/05-optimization/03-resource-power-optimization.md) §1):

```
more logic → denser placement → routing demand exceeds local capacity
           → router detours around the congested region
           → net delay rises on paths that did not change
           → WNS drops → you add a pipeline stage → +6.4 ns
```

> ⚠️ **Nothing in that chain mentions running out of LUTs.** A design at 22 % device
> utilization that fails timing because 90 % of its logic is in two clock regions is
> the normal case. Utilization percentages lie about difficulty; the congestion report
> does not. Passing every column in §3.11 is therefore **necessary and not sufficient**.

Three companion metrics, tracked with the same seriousness as the utilization columns:

| Metric | Target | Source |
| --- | --- | --- |
| Fast-path pblock CLB LUT occupancy | **≤ 60 %** | `report_utilization -pblocks [get_pblocks pblock_fastpath]` |
| Worst congestion level in `pblock_fastpath` | **≤ 4** | `report_design_analysis -congestion` |
| SLR crossings on the fast path | **0** | `report_design_analysis -of_timing_paths` |
| Debug cores in a production bitstream | **0** | `get_debug_cores` |

Level 5 congestion is a real problem even when timing passes: it means the *next* RTL
change will not route. ⚠️ And an unbudgeted SLR crossing appears **without any RTL
change** — grow the fast path past what fits comfortably in SLR0 and the placer spills
it, costing a full 6.4 ns hop on a path that was fine yesterday. That is what the
`≤ 60 %` rule and `EXCLUDE_PLACEMENT TRUE` exist to prevent.

### Hazard 4 — a latency measured on a debug bitstream is not the production latency

An ILA consumes BRAM, adds hundreds of probe nets that route across the design, and
changes placement — which changes routing, which changes latency. ⚠️ **Re-measure after
stripping debug, every time.** Production builds carry zero ILA, zero VIO, zero debug
hub; the always-on latency histogram and counters are part of the design, not debug.

---

## 6. Discrepancies found in the sources

Recorded here, **not fixed** — these live in `rtl/`, `constraints/` and `TASKS.md`,
which this document does not edit.

| # | Discrepancy | Where | Impact |
| --- | --- | --- | --- |
| D1 | `trading_pkg.sv` says `div100`'s multiply *"maps to one DSP48"*. A DSP48E2 is 27×18; a 32×32 product needs 2–4, or 0 if inferred as constant-coefficient LUT logic. | [`../rtl/pkg/trading_pkg.sv`](../rtl/pkg/trading_pkg.sv) §6 | DSP budget ±4. Cosmetic against a ceiling of 16. |
| D2 | ⚠️ **`risk_params.sv` decodes a 16-word-per-symbol shadow stride** (`SHADOW_D = N_SYM * 16`, `wr_addr = {wr_sym, wr_word}` with `wr_word[3:0]`), while `telemetry_pkg.sv` — which declares itself *"the SINGLE SOURCE OF TRUTH for host-software contracts"* — publishes `RISK_WORDS_PER_SYM = 12`. | `rtl/risk/risk_params.sv` vs `rtl/telemetry/telemetry_pkg.sv` | **Silent corruption.** A host computing `addr = sym × 12 + word` writes symbol 1's limits into symbol 0's unused words. Every symbol above 0 gets **no risk limits at all**, and the fabric's fail-closed default then blocks all trading in them — or, worse, a partially-matching stride passes some fields through. Documented again in [`register-map.md`](register-map.md). |
| D3 | `telemetry_pkg.sv` sets `TMPL_WORDS_MAX = 2048`, but `ouch_encoder.sv` decodes `cfg_tmpl_addr` as `{sym[7:0], word[4:0]}` — a **32-word stride × 256 symbols = 8,192 words** of address space. | `rtl/telemetry/telemetry_pkg.sv` vs `rtl/order/ouch_encoder.sv` | A host bounds-checking against 2048 cannot write templates for symbols ≥ 64. |
| D4 | `telemetry_pkg.sv` says `sym_strat_t` uses **5 words**; `strategy_pkg.sv` defines `N_PARAM_WORDS = 6`; `STRAT_WORDS_PER_SYM = 8` is the address stride. Three numbers. | `rtl/telemetry/telemetry_pkg.sv` vs `rtl/strategy/strategy_pkg.sv` | Benign *if* the CSR splits at stride 8, which it does. Still three numbers where there should be one. |
| D5 | The brief's enumeration of telemetry stat arrays omits `order_stat[16]`, which `fpga_top.sv` does wire (`.order_stat(order_stat)`) and `telemetry_pkg.sv` does map (`0x0090`, 16 words). | task brief vs [`../rtl/fpga_top.sv`](../rtl/fpga_top.sv) | Snapshot bank is 116 words, not 100. Corrected in §3.8 and in [`register-map.md`](register-map.md). |
| D6 | The task premise stated that `constraints/floorplan.xdc` *"does not exist yet"*. It **does exist** and is substantive (~14.5 kB, `pblock_fastpath`/`pblock_slowpath` fully specified). | [`../constraints/floorplan.xdc`](../constraints/floorplan.xdc) | Corrected throughout §4 of this document. |
| D7 | `floorplan.xdc` quotes the fast-path budget as *"20 fabric cycles / 128 ns"*, mirroring `fpga_top.sv`'s summary line. The per-stage rows in that same header sum to **22 cycles / 140.8 ns**. | [`../constraints/floorplan.xdc`](../constraints/floorplan.xdc) vs [`../rtl/fpga_top.sv`](../rtl/fpga_top.sv) | Latency, not resources — tracked in [`latency-budget.md`](latency-budget.md). Noted here because a floorplan justified by the wrong number is a floorplan sized wrong. |

---

## 7. Floorplan intent ([`../TASKS.md`](../TASKS.md) P0.8, P11.11)

**The enforcement point is [`../constraints/floorplan.xdc`](../constraints/floorplan.xdc),
and it exists.** (It was believed not to; see D6.) Its content matches this budget:

| Constraint | Value | Rationale |
| --- | --- | --- |
| `pblock_fastpath` | `-add {SLR0}`, `EXCLUDE_PLACEMENT TRUE` | Hard, not soft. A soft pblock's failure mode is a placer that quietly spills the strategy engine into SLR1 and hands you −5 ns WNS with no cause. A hard one fails **loudly** at `place_design`. |
| Cells in `pblock_fastpath` | `u_md_eth`, `u_net_rx`, `u_feed`, `u_book`, `u_strategy`, `u_risk_gate`, `u_order_gw`, `u_oe_eth` | Exactly the eight fast-path rows in §2.1. |
| `CONTAIN_ROUTING` on fast path | **not set** | Containing routing as well as placement over-constrains the router in the most congested region and typically costs more in detour delay than the SLR discipline saves. |
| `pblock_slowpath` | `-add {SLR1}`, `EXCLUDE_PLACEMENT FALSE` | Soft on purpose: the invariant that matters is *"not in SLR0"*. |
| Cells in `pblock_slowpath` | `u_host_ctrl`, `u_telemetry` | §2.2. Evicting them is *"the biggest single congestion win"* per the governing manual §8. |
| `u_clk_rst` | **no pblock** | The MMCM must be able to drive `core_clk` into both SLR0 and SLR1. |
| `pblock_book` (nested) | **off by default** | A Tier-4 measure applied against a measurement, never speculatively. |

**Which blocks must be adjacent to the transceivers.** Hard IP is at fixed physical
locations, so the transceiver quad anchors the whole floorplan
([`../manuals/00-foundations/02-fpga-architecture.md`](../manuals/00-foundations/02-fpga-architecture.md) §7).
In transceiver-proximity order: `u_md_eth` (×2) and `u_oe_eth` are pinned by the GT
quads themselves; `u_net_rx` must be next to `u_md_eth` because it consumes the raw
64-bit AXI-Stream at line rate; `u_order_gw` must be next to `u_oe_eth` because it feeds
MAC TX; `u_feed` → `u_book` → `u_strategy` → `u_risk_gate` form the chain between them
and should be placed in that order, not scattered.

> ⚠️ SLR0 is named as the transceiver-adjacent SLR. **If the optics route to a quad in
> SLR1 on the chosen board, `floorplan.xdc` is wrong and must move** — the file says so
> itself. Confirm the GT quad's SLR with `report_property` on the site before trusting
> any of this.

**The fast path crosses no SLR boundary** (ADR 0001). An SLR crossing is roughly a full
clock cycle — at 156.25 MHz, **6.4 ns of the 6.4 ns you have**. It does not degrade
timing; it deletes it. There is no line item for an SLR crossing in the master latency
budget because there is no SLR crossing in the fast path; if one appears, the budget is
wrong by 6.4 ns per crossing.

The **only** sanctioned crossings, all off the fast path:

| Crossing | Direction | Acceptable because |
| --- | --- | --- |
| `cfg_*` config / limit writes | SLR1 → SLR0 | Handshake CDC, multicycle-pathed |
| `cfg_kill` / `cfg_trading_en` | SLR1 → SLR0 | ⚠️ Single-bit, synchronized, and the hop is **one of the four cycles** in `KILL_RESP_CYCLES = 4`. Verified in simulation for the logic and on **hardware** for the real number — simulation is untimed and does not model the crossing. |
| Telemetry counter reads | SLR0 → SLR1 | Read-only, latency-insensitive |
| `kill_active` / `kill_src` | SLR0 → SLR1 | Status, handshake-crossed |
| `core_clk` distribution | SLR0 ↔ SLR1 | Clock network, not a data path |

Any crossing not on that list is a bug.

---

## 8. Update rule

This is a **living document**. It changes when a measurement lands or an allocation is
renegotiated — never silently.

1. **Actuals are filled from post-route reports only.** When a block lands, run
   `report_utilization -pblocks [get_pblocks pblock_fastpath]` after `route_design` and
   paste the numbers **verbatim** into the actual columns of §2.1. Post-synthesis
   numbers do not go in those columns, ever, not even as a placeholder — a placeholder
   that looks like a measurement is worse than an empty cell.
2. **A block that exceeds its allocation opens a debt entry**, in the same form as
   [`latency-budget.md`](latency-budget.md): what overran, by how much, whether the
   overrun is being paid for out of the reserved headroom or out of another block's
   allocation, who agreed, and what would retire it. **Never edit the target to match
   the actual.** A target quietly raised to match reality is a budget that has stopped
   being a constraint.
3. **The reserved headroom row is a shared pool, not free space.** Drawing on it
   requires the datapath lead's agreement and a note here saying which block took it and
   why.
4. **The congestion, pblock-occupancy and SLR-crossing metrics in §5 hazard 3 are
   recorded at the same time as the utilization actuals.** A build that passes §3.11 and
   fails those is not a passing build.
5. **A change to `N_SYMBOLS`, `N_ACTIVE`, `BOOK_LEVELS`, `ORDER_MAP_ENTRIES` or
   `ORDER_MAP_WAYS` in [`../rtl/pkg/trading_pkg.sv`](../rtl/pkg/trading_pkg.sv) invalidates
   §3 and must re-run the arithmetic in the same commit.** These are elaboration
   parameters precisely because they size memory
   ([`../manuals/05-optimization/03-resource-power-optimization.md`](../manuals/05-optimization/03-resource-power-optimization.md) §11).

### Open items

| # | Item | Blocks | Owner |
| --- | --- | --- | --- |
| O1 | ⚠️ Resolve assumption **A4** — does `ORDER_MAP_ENTRIES` count entries or sets? At 4× it is **128 URAM, 2× over the ceiling**. | ADR 0007, `rtl/book/order_map.sv` | Book owner |
| O2 | Resolve discrepancy **D2** — the risk-parameter shadow stride, 12 vs 16. Silent-corruption class. | [`register-map.md`](register-map.md), `docs/regmap.yaml` | Risk owner |
| O3 | Resolve **D3** — `TMPL_WORDS_MAX = 2048` vs the encoder's 8,192-word address space. | `docs/regmap.yaml` | Gateway owner |
| O4 | Size the MAC-boundary FIFOs (**A8**) from a real capture of the worst historical minute, not from a default. | `rtl/eth/`, P2.x | Network lead |
| O5 | Confirm the GT quad's SLR on the chosen board; if it is SLR1, `floorplan.xdc` moves. | `constraints/floorplan.xdc` | Platform lead |
| O6 | Confirm whether URAM SECDED forces the output register on, and if so book the cycle in [`latency-budget.md`](latency-budget.md). | ADR 0007 | Book owner |
| O7 | First synthesis of `u_net_rx` and `u_strategy` — the two LUT estimates the ⚠️ AT RISK verdict rests on. | P3.x, P5.x | Network / Strategy leads |
| O8 | `rtl/book/` does not exist. **Every number in §3.3 and §3.4 — 32 URAM and 20 BRAM36, the two largest memory allocations — is unbacked by code.** | P4.x | Book owner |

---

## Further reading

- [`latency-budget.md`](latency-budget.md) — where a URAM cascade or an enabled BRAM output register shows up as budget debt
- [`adr/README.md`](adr/README.md) — the ADR index, including the mapping from `TASKS.md`'s older ADR numbering
- [`register-map.md`](register-map.md) — the host contract for the parameter windows sized in §3.5–§3.7
- [`../manuals/05-optimization/03-resource-power-optimization.md`](../manuals/05-optimization/03-resource-power-optimization.md) — the governing manual: area → congestion → latency, the budget template, the worked memory example
- [`../manuals/01-fpga-design/03-memory-and-storage.md`](../manuals/01-fpga-design/03-memory-and-storage.md) — primitive selection, banking, read-during-write hazards, set-associative lookup
- [`../manuals/00-foundations/02-fpga-architecture.md`](../manuals/00-foundations/02-fpga-architecture.md) — what a BRAM/URAM/DSP physically is, and how to read a utilization report
- [`../manuals/04-system-architecture/06-cpu-fpga-partitioning.md`](../manuals/04-system-architecture/06-cpu-fpga-partitioning.md) — why the slow path is not in this budget
- [`../manuals/06-operations/03-monitoring-and-telemetry.md`](../manuals/06-operations/03-monitoring-and-telemetry.md) — the counter bank sized in §3.8
- [`../constraints/floorplan.xdc`](../constraints/floorplan.xdc) — the enforcement point for §7
- [`../rtl/fpga_top.sv`](../rtl/fpga_top.sv) — the master ceiling this document divides
- [`../CLAUDE.md`](../CLAUDE.md) — §4 (quote utilization verbatim), §5 (fast-path hard rules)
