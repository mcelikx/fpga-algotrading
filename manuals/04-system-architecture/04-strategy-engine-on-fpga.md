# 04.04 — Strategy Engine on FPGA

> **Why this matters here:** the strategy owns rows **S0–S1** — 2 cycles, 12.8 ns —
> which is 3 % of the tick-to-trade budget. That number is not an accident or a
> constraint we grudgingly accept. It is the entire design thesis: **the FPGA does
> not think, it reacts.** Everything that requires thinking happened milliseconds
> ago on the CPU and is sitting in a parameter table waiting to be compared against.

---

## 1. The core principle: a trigger evaluator, not a compute engine

The instinct from software is to port the strategy. Resist it completely.

```
        WRONG                                    RIGHT
   ┌──────────────────┐                  ┌──────────────────────┐
   │ book state       │                  │ book state           │
   │      ↓           │                  │      ↓               │
   │ compute signal   │  ← 40 cycles     │ compare against      │  ← 1 cycle
   │ compute fair val │  ← 30 cycles     │ precomputed          │
   │ compute size     │  ← 20 cycles     │ thresholds           │
   │      ↓           │                  │      ↓               │
   │ decision         │                  │ decision + size + px │  ← 1 cycle
   └──────────────────┘                  └──────────────────────┘
      90 cycles = 576 ns                    2 cycles = 12.8 ns
```

**The formal statement of what the FPGA computes:**

```
decision  =  f( book_state , my_state , params[slot] )
```

where `f` is a **pure, combinational, bounded-depth function** — a bank of
comparators and a small mux tree — and `params[slot]` is a per-symbol row written by
the CPU. No loops. No multiplies deeper than one DSP cascade. No memory access other
than the single parameter read at S0.

Everything expensive is pushed into `params`:

| Instead of computing on the tick | The CPU precomputes |
| --- | --- |
| fair value from a multi-factor model | `fair_px[slot]`, refreshed every few ms |
| `qty × px > notional_limit` | `max_qty[slot]` (and risk still does the exact multiply — 04.05 §4) |
| volatility-scaled edge requirement | `edge_ticks[slot]` |
| whether this symbol is worth quoting today | `enable` bit |
| spread/imbalance regime classification | `prim_id[slot]` — *which strategy runs* |

This is the "precompute is the free optimization" rule from
[../01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) §4,
taken to its logical end: **the strategy's intelligence lives in the parameter
table, and the fabric is the thing that applies it at 12.8 ns.**

---

## 2. Anatomy of a hardware strategy

```
   bbo_upd (from book, B4)          params[slot] (BRAM read, issued at R5)
   ┌──────────────────────┐         ┌────────────────────────────────────┐
   │ slot                 │         │ enable, prim_id, side_mask         │
   │ bid_lvl/qty/cnt      │         │ edge_ticks, join_qty, imb_thresh   │
   │ ask_lvl/qty/cnt      │         │ size, max_pos, px_offset, tif      │
   │ bid2/ask2            │         │ fair_px, skew                      │
   │ stale, halted        │         └──────────────┬─────────────────────┘
   └──────────┬───────────┘                        │
              │        my_state[slot]              │
              │   ┌──────────────────────┐         │
              │   │ position (signed)    │         │
              │   │ resting bid/ask      │         │
              │   │ queue_ahead estimate │         │
              │   │ open_order_count     │         │
              │   └──────────┬───────────┘         │
              │              │                     │
   ═══════════▼══════════════▼═════════════════════▼═══════════  S0
   ┌────────────────────────────────────────────────────────────┐
   │  GATING:  enable & !stale & !halted & session_open         │
   │           & !risk_blocked & !ssr_blocked & in_window       │
   │           ──────── single AND of precomputed bits ────────  │
   └────────────────────────┬───────────────────────────────────┘
   ═════════════════════════▼══════════════════════════════════  S1
   ┌────────────────────────────────────────────────────────────┐
   │  COMPARATOR BANK  (all primitives evaluate in parallel)     │
   │    prim_quote : should I be resting here? at what price?    │
   │    prim_take  : is the touch through my threshold?          │
   │    prim_fade  : should I pull?                              │
   │           ──── mux by prim_id[slot] ────                    │
   └────────────────────────┬───────────────────────────────────┘
                            ▼
              ord_req { decision ∈ {NONE, BUY, SELL, CANCEL},
                        px[31:0], qty[31:0], tif[2:0], slot }
                            │
                            ▼  to risk_gate (T0)
```

The output alphabet is deliberately tiny:

| `decision` | Meaning | Downstream |
| --- | --- | --- |
| `NONE` | do nothing (the overwhelming majority) | pipeline drains, nothing emitted |
| `BUY` / `SELL` | enter a new order at `px`, `qty`, `tif` | risk gate → OUCH `Enter Order` |
| `CANCEL` | pull a specific resting order | risk gate (fast-path allowed; §8) → OUCH `Cancel` |
| `REPLACE` | reprice a resting order | risk gate → OUCH `Replace` |

⚠️ **`NONE` must cost exactly the same as `BUY`.** If the "no trade" path is shorter,
you have made the latency of your trades depend on the recent history of your
decisions, and you have introduced data-dependent jitter into the only path that
matters. Every `bbo_upd` traverses S0 and S1 identically; only `ord_req.valid`
differs.

---

## 3. The per-symbol parameter table

One row per symbol. **256 bits**, two banks (§5), 128 symbols.

```
128 symbols × 2 banks × 256 bits = 65.5 Kbit → 2 × BRAM36 (SDP, port A fast path)
```

| Field | Bits | Range / units | Written by | Meaning |
| --- | ---: | --- | --- | --- |
| `enable` | 1 | | `ttd-params` | master per-symbol on/off |
| `prim_id` | 3 | 0–7 | `ttd-params` | which hardened primitive runs (§6) |
| `side_mask` | 2 | `{buy_ok, sell_ok}` | `ttd-params` | one-sided quoting, SSR compliance |
| `tif` | 3 | enum | `ttd-params` | IOC / DAY / post-only |
| `display` | 1 | | `ttd-params` | displayed vs. non-displayed |
| `fair_px` | 32 | ITCH units (4 dp) | `ttd-params` @ ~1 kHz | model fair value |
| `edge_ticks` | 12 | ticks | `ttd-params` | required edge vs. `fair_px` to act |
| `join_qty` | 24 | shares | `ttd-params` | min resting size at a level before we join it |
| `imb_thresh` | 16 | Q8.8 ratio | `ttd-params` | bid/ask qty ratio that triggers skew |
| `size` | 24 | shares | `ttd-params` | our order size |
| `max_pos` | 24 | shares, signed magnitude | `ttd-risk` | strategy-level position cap (risk has its own, 04.05) |
| `px_offset_bid` | 12 | ticks | `ttd-params` | quote placement below best bid |
| `px_offset_ask` | 12 | ticks | `ttd-params` | quote placement above best ask |
| `skew` | 12 | signed ticks | `ttd-params` @ ~1 kHz | inventory skew applied to both quotes |
| `min_spread` | 12 | ticks | `ttd-params` | do not quote inside this |
| `max_spread` | 12 | ticks | `ttd-params` | do not quote when the market is this wide |
| `cooldown` | 16 | cycles | `ttd-params` | min cycles between our orders on this symbol |
| `reserved` | 33 | | | growth |
| **Total** | **256** | | | |

**How it is written.** Not by MMIO — 128 rows × 32 bytes at ~200 ns per posted write
is 800 µs of PCIe traffic per full refresh, and `ttd-params` refreshes `fair_px` and
`skew` at 1 kHz. Instead:

1. `ttd-params` builds a batch of `(slot, 256-bit row)` updates in a pinned host
   buffer.
2. It rings a doorbell (one MMIO write, ~200 ns).
3. `param_dma_rx` DMA-reads the batch and writes it into the **shadow bank**.
4. `ttd-params` writes the commit mask (§5).

Full-table refresh cost: one DMA of 4 KB ≈ **~2–3 µs**, once per millisecond. That is
0.3 % of a PCIe Gen3 x16 link and it never touches the fast path.

> **Verify:** PCIe MMIO posted-write and DMA-read latencies are platform-specific
> (root complex, IOMMU on/off, ACS, relaxed ordering). Measure yours with a loopback
> before quoting them. See [06-cpu-fpga-partitioning.md](06-cpu-fpga-partitioning.md) §4.

---

## 4. Where the parameter read hides

Notice that S0 in the master budget is **1 cycle**, and it does both the parameter
read *and* the gating evaluation. That works because the read is issued
**speculatively at R5**, the moment the `slot` is known, five cycles before the
strategy needs it:

```
R5  symbol_filter produces slot ──┬──▶ book_cmd ──▶ B0 B1 B2 B3 B4 ──▶ bbo_upd
                                  │                                       │
                                  └──▶ param_table read (5-cycle SRL      │
                                       delay line to align) ──────────────┴──▶ S0
```

- The read is issued for **every** book-affecting message, including ones that turn
  out not to move the top of book. Wasted reads cost nothing — BRAM port A is
  otherwise idle and the read has no side effect.
- The result is delayed through an unreset SRL line of depth 5
  ([../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) §7)
  so it arrives exactly with `bbo_upd`.
- `PIPE_DEPTH` is a single parameter shared by the book and the delay line. If the
  book's depth changes, the delay changes with it automatically.

This is why the strategy costs 2 cycles instead of 3. The same trick is used again
at T2 for the OUCH template read (04.05 §6).

---

## 5. ⚠️ Atomic parameter updates — the money-losing bug class

### The failure

`ttd-params` writes a 256-bit row as eight 32-bit words. The FPGA evaluates a book
update between word 3 and word 4. It now reads **the new `fair_px` with the old
`edge_ticks` and the old `size`.** That combination was never a strategy anyone
designed, tested, or approved. It is not a crash. It is not a counter. It is an
order, on the wire, at a price nobody chose.

This is not hypothetical. It is one of the most common serious defects in
hybrid CPU/FPGA trading systems, because everything works in simulation (where the
testbench writes parameters while the pipeline is idle) and in low-rate testing
(where the collision probability is small). It surfaces at high message rates, on
volatile days, when `ttd-params` is updating fastest — precisely the worst moment.

### The fix: double buffer + single-cycle commit

```
   param_ram : 256 entries × 256 bits, addressed by {bank, slot}
               bank 0 = slots 0..127,  bank 1 = slots 128..255

   active_bank_q : 128-bit register array, one bit per symbol
                   ← THIS is the atomic object. One bit. One cycle.
```

```systemverilog
// rtl/strategy/param_commit.sv
// ─────────────────────────────────────────────────────────────────────────────
// Budget row: none (control plane). Fast-path cost: ZERO.
// ─────────────────────────────────────────────────────────────────────────────
module param_commit (
    input  logic         clk, rst,
    // ── CPU side (CDC'd from the PCIe domain, slow) ──────────────────────────
    input  logic         wr_en,          // DMA writes into the SHADOW bank only
    input  logic [6:0]   wr_slot,
    input  logic [255:0] wr_data,
    input  logic         commit_en,      // one register write from the host
    input  logic [127:0] commit_mask,    // which symbols to flip, atomically
    // ── Fast path (S0) ───────────────────────────────────────────────────────
    input  logic         rd_en,
    input  logic [6:0]   rd_slot,
    output logic [255:0] rd_data,
    output logic         rd_valid
);
    logic [127:0] active_bank_q;

    // ── Writes ALWAYS target the inactive (shadow) bank. Never the live one. ──
    wire wr_bank = ~active_bank_q[wr_slot];

    // ── Commit: a single-cycle flip of an arbitrary subset of symbols. ────────
    always_ff @(posedge clk) begin
        if (rst)            active_bank_q <= '0;
        else if (commit_en) active_bank_q <= active_bank_q ^ commit_mask;
    end

    // ── Read: bank select and row read MUST be sampled in the SAME cycle. ─────
    //    This is the whole point. See the warning below.
    wire rd_bank = active_bank_q[rd_slot];

    bram_sdp #(.W(256), .D(256), .RD_LAT(1)) u_param_ram (
        .clk    (clk),
        .wen    (wr_en),   .waddr({wr_bank, wr_slot}), .wdata(wr_data),
        .ren    (rd_en),   .raddr({rd_bank, rd_slot}), .rdata(rd_data)
    );

    always_ff @(posedge clk) rd_valid <= rd_en;
endmodule
```

### ⚠️ The subtle version of the same bug

Splitting the read across two cycles — sample `active_bank_q` in cycle *N*, use it
to address the RAM in cycle *N+1* — **reintroduces the tear**, because the commit can
land in between. You would read the row from the bank that *was* active.

**The rule: `rd_bank` and `raddr` are formed in the same combinational cone, from
the same clock edge, always.** The bank select is part of the address, not a
pipeline stage before it.

```systemverilog
`ifndef SYNTHESIS
// The commit flip and any in-flight read must not overlap ambiguously.
assert property (@(posedge clk) disable iff (rst)
    (commit_en && rd_en) |-> (rd_bank == $past(active_bank_q[rd_slot], 0)))
    else $error("param torn read: bank select sampled off-cycle");
`endif
```

### The protocol the host must follow

```
1. DMA-write all changed rows          →  lands in shadow banks
2. Read back a checksum register        →  verifies the DMA completed  ⚠️ MANDATORY
3. Write commit_mask                    →  ONE cycle, all symbols flip together
4. Read active_bank_q back              →  confirm
```

⚠️ **Step 2 is not optional.** PCIe writes are posted: the host's `write()` returning
means nothing about whether the data reached the FPGA. Committing to a shadow bank
that has not been fully written is exactly the bug you were preventing, one level up.
`param_dma_rx` maintains a running XOR checksum per shadow bank; the host compares it
against its own before committing.

### Multi-symbol atomicity

`commit_mask` is 128 bits so that a set of related symbols (a pair trade, a basket)
flips **together**. Half a pair updated is a strategy nobody designed, same as half a
row. If your strategy has cross-symbol dependencies, they must be in the same commit.

---

## 6. Reconfigurability without a bitstream rebuild

### The economics

| Change | Turnaround | Revalidation |
| --- | --- | --- |
| Parameter value | **~1 ms** (DMA + commit) | none — the logic is unchanged |
| Enable/disable a symbol | **~1 ms** | none |
| Switch a symbol to a different primitive | **~1 ms** | primitive already validated |
| **New primitive → bitstream rebuild** | **2–8 hours** synth+P&R, plus timing closure risk | full regression, replay, soak, conformance |

The ratio is seven orders of magnitude. **Therefore: the design goal is that a normal
day's strategy work requires zero bitstream builds.**

### Hardened primitives selected by parameter

Instead of "one bitstream per strategy idea", the fabric holds a **small set of
general primitives**, all instantiated simultaneously, all evaluating in parallel on
every book update, with `prim_id[slot]` muxing the winner:

| `prim_id` | Primitive | Behaviour | Params it reads |
| ---: | --- | --- | --- |
| 0 | `prim_null` | never fires | — |
| 1 | `prim_quote` | maintain a two-sided resting quote at `best ± px_offset`, skewed by inventory | `px_offset_*`, `skew`, `size`, `min/max_spread`, `join_qty` |
| 2 | `prim_take` | cross the spread when the touch is through `fair_px ± edge_ticks` | `fair_px`, `edge_ticks`, `size` |
| 3 | `prim_fade` | cancel resting orders when the book moves against them by `edge_ticks` | `edge_ticks` |
| 4 | `prim_join` | rest at the touch only when `bid_qty ≥ join_qty` (queue-position aware) | `join_qty`, `size` |
| 5 | `prim_imbal` | act on `bid_qty/ask_qty` crossing `imb_thresh` | `imb_thresh`, `size`, `edge_ticks` |
| 6–7 | reserved | | |

**Cost of instantiating all of them:** they share the S1 cycle. Each is a handful of
comparators; six of them in parallel is perhaps 3,000 LUTs and *zero* extra latency,
because the mux by `prim_id` happens in the same cycle as the comparisons
(speculation — [../01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) §5).
Area is the cheapest resource we have. Latency and turnaround are the expensive ones.

**The design discipline this imposes:** when someone proposes a new strategy, the
first question is *"which existing primitive plus which parameter values expresses
this?"* A genuinely new primitive is a quarterly event, planned, batched with other
RTL work, and put through the full regression. It is not a Tuesday.

### The boundary — what a parameter cannot do

Parameters change *thresholds and selections*. They cannot change *structure*:

| Expressible as a parameter | Requires a rebuild |
| --- | --- |
| a different threshold, size, offset, skew | a different arithmetic form (e.g. adding a multiply) |
| which primitive runs on which symbol | a primitive that reads state the fabric doesn't hold |
| one-sided vs. two-sided | using book depth beyond the published top-3 |
| enable/disable, cooldown | a new order type or TIF the OUCH template doesn't cover |

⚠️ Do not smuggle structure into parameters via a general expression evaluator in
fabric. A parameterised ALU with a micro-program is a CPU, it is slow, it is hard to
verify, and it defeats the entire reason for being in hardware. If you find yourself
designing a bytecode, stop: that work belongs on the CPU, at millisecond scale,
writing thresholds.

---

## 7. The hybrid CPU/FPGA signal model

```
        TIME SCALE          WHO           WHAT
   ═══════════════════════════════════════════════════════════════════════════

     minutes ──────▶  ttd-params    fit models, recalibrate, choose prim_id
                      (CPU)         per symbol, set enables for the session
                          │
                          ▼
     1–10 ms ──────▶  ttd-params    read book snapshots + trades from the DMA
                      (CPU)         ring, recompute fair_px, skew, edge_ticks
                          │
                          │  DMA batch + commit_mask  (~2–3 µs, off fast path)
                          ▼
                    ┌───────────────────────────────────────────┐
                    │      param_table  (double-buffered)       │
                    └────────────────────┬──────────────────────┘
                                         │
     12.8 ns ─────▶     FPGA             │   compare bbo_upd against params,
                                         ▼   fire or don't
                    ┌───────────────────────────────────────────┐
                    │   S0 gating  →  S1 comparator bank        │
                    └────────────────────┬──────────────────────┘
                                         ▼
                                      ord_req
```

**The division is by time scale, not by complexity.** The CPU is allowed to be
arbitrarily sophisticated because it has milliseconds. The FPGA is allowed to be
arbitrarily fast because it only has to compare.

The contract between them:

| Property | Guarantee |
| --- | --- |
| Staleness | `fair_px` is up to ~1 ms old. The strategy design must be robust to that — `edge_ticks` exists partly to absorb it. |
| Failure | If `ttd-params` dies, parameters **freeze** at their last committed values. The FPGA keeps trading on stale parameters. |
| ⚠️ **Therefore** | `ttd-params` must also kick a **parameter watchdog**: if no commit is seen for `T_param_max` (e.g. 500 ms), the FPGA clears `enable` for all symbols. Frozen parameters are only safe for a bounded time. |
| Direction | Parameters flow **CPU → FPGA** only. The FPGA never asks the CPU a question on the fast path. |

---

## 8. State the strategy owns

Distinct from the book (which is the *market's* state), this is *our* state, and it
must be in fabric because the trigger depends on it.

```
   my_state[slot] : 128 entries × 192 bits → 1 BRAM36
```

| Field | Bits | Updated by | Notes |
| --- | ---: | --- | --- |
| `position` | 32 signed | `ack_evt` fills (04.05 §10) | **saturating**. shares, signed. |
| `bid_token` | 32 | on send / on ack | our resting bid's OUCH token, 0 = none |
| `bid_px`, `bid_qty` | 32 + 24 | on send / on partial fill | |
| `ask_token`, `ask_px`, `ask_qty` | 32 + 32 + 24 | ditto | |
| `open_order_cnt` | 8 | on send / on terminal ack | **saturating** |
| `queue_ahead` | 24 | see below | estimate |
| `last_action_cycle` | 32 | on send | for `cooldown` |
| `pending` | 1 | on send, cleared on ack | ⚠️ see below |

### Queue position estimate

Because ITCH is order-based (04.03 §1), we see *every* add, cancel and execution
ahead of us. So the estimate is better than on a level-based feed:

```
On our Add being accepted:   queue_ahead ← bid_qty at that level, at that instant
On an execution at our level: queue_ahead ← max(0, queue_ahead − exec_shares)
On a cancel/delete at our level of an order we believe is ahead of us:
                              queue_ahead ← max(0, queue_ahead − cancelled_shares)
```

⚠️ It remains an **estimate**, for three reasons: (1) we cannot always tell whether a
cancelled order was ahead of or behind us without tracking every order reference at
that level and its arrival order; (2) our own add's exact position depends on when
the matching engine sequenced it relative to concurrent adds; (3) hidden and reserve
liquidity is invisible in the displayed book. Treat `queue_ahead` as a **soft input
to sizing and fading**, never as a hard condition for an aggressive action, and never
report it as a fact.

### ⚠️ The `pending` bit and duplicate orders

Between sending an order and receiving its ack there is a window of ~5–50 µs. During
that window, tens of thousands of book updates can arrive. If the trigger condition
is still true, the strategy will fire **again**, and again, and again — one order per
book update — until the ack lands.

This is a runaway. It is the classic algo failure and it is how firms lose their
capital in ninety seconds.

**Three independent defences, all required:**

1. **`pending`** — set on send, cleared on terminal ack. The strategy will not fire
   for a symbol with `pending` set. (Strategy layer.)
2. **`cooldown`** — a minimum cycle count between orders per symbol, enforced against
   `last_action_cycle`. Survives a `pending` bug. (Strategy layer.)
3. **Hardware rate limiter** in the risk gate — token bucket, per symbol and global,
   in a block the strategy cannot influence. (Risk layer, 04.05 §5.)

Defence 3 is the one that must not be removed, because 1 and 2 live in the block that
might be the thing that is broken.

---

## 9. Multi-symbol scheduling — and why there is nothing to schedule

**The invariant:** one ITCH message affects exactly one symbol, so one `bbo_upd`
carries exactly one `slot`, so **at most one symbol is evaluated per cycle**.

Consequences, all of them good:

| | |
| --- | --- |
| No cross-symbol contention | there is only ever one live evaluation |
| No arbitration | nothing to arbitrate; no arbiter, no jitter, no round-robin |
| No per-symbol replication of logic | one comparator bank, time-multiplexed by construction |
| Scaling `N_SYMBOLS` costs **memory only** | 128 → 512 symbols is 4× the BRAM and 0 extra LUTs and 0 extra ns |
| No scheduler to verify | the hardest thing to verify is the thing that doesn't exist |

⚠️ This invariant is load-bearing, and exactly one thing breaks it: **a strategy that
reacts to symbol A by quoting symbol B** (pairs, ETF-vs-basket, index arb). That
turns one input event into N output evaluations and reintroduces everything in the
table above.

If you need it, the correct structure is **not** a scheduler. It is:

- a small fixed **fan-out table**: `slot → up-to-K related slots` (K = 2 or 4,
  compile-time constant), and
- **K replicated comparator banks** evaluating in the same cycle, and
- **K parallel `ord_req` ports** into a fixed-priority arbiter at the risk gate.

Bounded, fixed-latency, no queue. Cost: K× the S1 logic and +1 cycle for the
arbiter. That is the price of cross-symbol strategies and it should be paid
explicitly, not discovered.

---

## 10. Gating: "should I quote at all"

Every one of these is a **precomputed bit**, maintained off the fast path, so the
whole gate is one AND-reduction in the S0 cycle:

| Gate | Source | Updated by |
| --- | --- | --- |
| `enable[slot]` | parameter table | `ttd-params` commit |
| `!book_stale[slot]` | book (04.03 §10) | gap, overflow, sub-penny, underflow |
| `!halted[slot]` | ITCH `H` Stock Trading Action, `h` Operational Halt | feed handler, at R4 |
| `session_open` | ITCH `S` System Event + a CPU-written session window | feed handler + `ttd-control` |
| `!risk_blocked[slot]` | risk gate's own per-symbol block bit | `risk_gate` |
| `!kill_armed` | kill switch | many sources (04.05 §5) |
| `ssr_ok` | ITCH `Y` Reg SHO Short Sale Price Test | feed handler, at R4 |
| `!auction_period` | ITCH `S` codes + `Q`/`I` cross messages | feed handler + `ttd-control` |
| `!luld_paused[slot]` | LULD state | feed handler + `ttd-control` |
| `param_fresh` | parameter watchdog (§7) | `watchdog` |
| `!pending[slot]`, `cooldown_ok` | `my_orders` | strategy itself |

```systemverilog
wire tradeable = enable & ~book_stale & ~halted & session_open & ~risk_blocked
               & ~kill_armed & ssr_ok & ~auction_period & ~luld_paused & param_fresh;
wire may_fire  = tradeable & ~pending & cooldown_ok;
```

> **Verify:** the mapping from ITCH `H` trading-action codes, `S` system-event codes,
> and `Y` Reg SHO states onto these bits is venue semantics, not design choice. Take
> it from the Nasdaq spec and the Reg SHO / LULD rules; see [../08-nasdaq/](../08-nasdaq/).
> Getting a halt code inverted is a compliance event, not a bug.

⚠️ **Every gate defaults to blocking on reset.** `enable = 0`, `book_stale = 1`,
`session_open = 0`, `kill_armed = 1`. A reset must produce a system that does not
trade, and it must require deliberate action to make it trade. See
[05-order-gateway-and-pre-trade-risk.md](05-order-gateway-and-pre-trade-risk.md) §3.

---

## 11. Strategy latency budget (rows S0–S1)

| Row | Stage | Module | Cycles | ns | Cum. ns | Notes |
| --- | --- | --- | ---: | ---: | ---: | --- |
| — | *param read issued* | `param_table` | *0* | *0* | — | speculative at R5, delayed to S0 (§4) |
| S0 | Bank select + param row present; `my_state` read; gating AND-reduction | `param_commit`, `my_orders`, `gating` | 1 | 6.4 | 6.4 | fixed |
| S1 | 6 primitives evaluate in parallel; mux by `prim_id`; form px/qty/tif | `prim_*`, `strat_top` | 1 | 6.4 | 12.8 | fixed |
| | **Strategy total** | | **2** | **12.8** | | |

**Logic depth check for S1.** In 6.4 ns at UltraScale+ speed we can afford roughly
10–20 LUT levels ([../00-foundations/01-digital-logic-and-timing.md](../00-foundations/01-digital-logic-and-timing.md) §7).
S1 contains: 32-bit compares (2 levels), a 12-bit add for the price offset (2 levels),
a signed skew add (2 levels), the primitive mux (2 levels for 8:1), output formation
(2 levels). ~10 levels plus routing. It fits, with margin — but ⚠️ this is the stage
most likely to become the critical path as primitives are added, and it is where the
first timing failure will appear. Watch its WNS in every build.

**Resource estimate (unmeasured, pre-synthesis):**

| Module | LUT | FF | BRAM36 |
| --- | ---: | ---: | ---: |
| `param_table` + `param_commit` | ~400 | ~450 | 2 |
| `my_orders` | ~350 | ~250 | 1 |
| `gating` | ~120 | ~180 | 0 |
| `prim_*` (6 primitives) | ~3,000 | ~700 | 0 |
| `strat_top` (mux, formation) | ~600 | ~400 | 0 |

---

## 12. Unit testing a strategy block deterministically

The strategy is the easiest block in the system to test properly, because it is a
**pure function**. Exploit that.

### 12.1 The structure

```
tb/strategy/
├── test_strategy.py           cocotb
├── golden/strategy_model.py   pure-Python f(book, my_state, params) → decision
├── vectors/
│   ├── directed.yaml          hand-written cases, one per rule, with expected output
│   ├── boundary.yaml          generated: every threshold at −1, ==, +1
│   └── replay_derived.json    (book, my_state) tuples harvested from a pcap replay
└── props/                     SVA properties bound to the DUT
```

```python
@cocotb.test()
async def test_pure_function(dut):
    """The DUT is a pure function. Prove it agrees with the model on every vector,
       and prove it is stateless with respect to evaluation order."""
    ref = StrategyModel()
    for vec in load_vectors():
        await drive(dut, vec.bbo, vec.my_state, vec.params)
        await ClockCycles(dut.clk, LATENCY_CYCLES)
        assert sample(dut) == ref.eval(vec), f"mismatch at {vec.id}"

    # Order independence: the same vector evaluated after any prefix of other
    # vectors must give the same answer. This is what "pure" means.
    for vec in random.sample(load_vectors(), 200):
        await drive_many(dut, random_prefix())
        await drive(dut, vec.bbo, vec.my_state, vec.params)
        assert sample(dut) == ref.eval(vec), f"order dependence at {vec.id}"
```

### 12.2 The required properties (SVA, bound, always on)

```systemverilog
// Safety properties — these must hold on EVERY test, including the replay soak.
assert property (@(posedge clk) !tradeable |-> !ord_req.valid);
assert property (@(posedge clk) ord_req.valid |-> ord_req.qty <= params.size);
assert property (@(posedge clk) ord_req.valid |-> ord_req.qty != 0);
assert property (@(posedge clk) ord_req.valid && ord_req.is_buy |-> params.side_mask[0]);
assert property (@(posedge clk) ord_req.valid |-> !pending[ord_req.slot]);
assert property (@(posedge clk) bbo_valid |=> ##(LATENCY_CYCLES-1) decision_valid);
assert property (@(posedge clk) commit_en |-> !$isunknown(rd_data));
```

### 12.3 Boundary generation

Every threshold comparison gets three vectors automatically: one tick below, exactly
at, one tick above. `edge_ticks`, `join_qty`, `imb_thresh`, `min_spread`,
`max_spread`, `max_pos`, `cooldown` — that is 7 thresholds × 3 × 6 primitives = 126
generated vectors, and off-by-one in a comparator is the most common strategy bug
there is. `>` versus `>=` on `edge_ticks` is the difference between two different
strategies, and only one of them was approved.

### 12.4 Replay-derived vectors

Harvest `(bbo_upd, my_state)` pairs from a full pcap replay of the book, then run the
strategy against them offline. This gives realistic distributions rather than
hand-picked cases, and — critically — it lets you diff the *decision stream* between
two RTL revisions on identical inputs. A strategy change that was supposed to affect
only symbol X and turns out to change 4,000 decisions on symbol Y is caught here, in
seconds, before it is caught by the PnL.

### 12.5 What must be deterministic

| Property | Test |
| --- | --- |
| Same inputs → same output, always | replay the same vector 1000 times |
| Same latency regardless of decision | assert `LATENCY_CYCLES` on `NONE` and on `BUY` alike |
| No dependence on evaluation history | §12.1 order-independence test |
| No dependence on reset timing | reset mid-stream at every cycle offset; outputs must resume identically |
| Parameter commit is invisible mid-evaluation | commit on every cycle offset relative to a `bbo_upd`; the decision must correspond to exactly one bank, never a mixture |

The last one is the test for §5, and it is the most important test in this document.

---

## Further reading

- [01-tick-to-trade-pipeline.md](01-tick-to-trade-pipeline.md) — rows S0–S1 in the master budget
- [03-order-book-in-hardware.md](03-order-book-in-hardware.md) — the producer of `bbo_upd`, and `book_stale`
- [05-order-gateway-and-pre-trade-risk.md](05-order-gateway-and-pre-trade-risk.md) — the gate `ord_req` must pass, and the rate limiter
- [06-cpu-fpga-partitioning.md](06-cpu-fpga-partitioning.md) — `ttd-params`, the DMA path, the watchdog
- [../01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) — precompute and speculation
- [../03-algotrading/05-strategy-taxonomy.md](../03-algotrading/05-strategy-taxonomy.md) — which strategies suit hardware at all
- [../03-algotrading/01-market-microstructure.md](../03-algotrading/01-market-microstructure.md) — queue position, adverse selection
- [../08-nasdaq/](../08-nasdaq/) — halt codes, system events, Reg SHO, LULD, auction periods
