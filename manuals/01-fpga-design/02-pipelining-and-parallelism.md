# 01.02 — Pipelining and Parallelism

> **The central tension of this project:** pipelining raises Fmax and throughput but
> *adds latency*. In most FPGA applications you pipeline freely. Here, every stage
> costs you money. This document is about spending stages deliberately.

---

## 1. The trade-off, stated plainly

```
Unpipelined:  [───────── 12 ns of logic ─────────]      Fmax = 83 MHz,  latency = 12 ns
2 stages:     [── 6 ns ──][── 6 ns ──]                  Fmax = 166 MHz, latency = 12 ns
4 stages:     [3][3][3][3]                              Fmax = 333 MHz, latency = 12 ns
```

Note what does *not* change: **the total logic delay**. Pipelining doesn't make the
work faster; it lets you clock faster, which improves *throughput*.

But real pipelining adds overhead per stage (`T_cq` + `T_setup` + routing to the
new FF ≈ 0.3–0.5 ns), so:

```
4 stages: 4 × (3 + 0.4) = 13.6 ns actual latency at 333 MHz
```

**Pipelining a latency-critical path makes it slower in absolute time.**

### When pipelining *is* the right answer here
1. **You're throughput-limited.** If you can't keep up with line rate, you must
   pipeline — dropping packets is worse than 2 ns.
2. **The stage is off the critical latency path.** Logging, statistics, slow-path
   handoff: pipeline freely.
3. **You need a higher clock for an unrelated reason** (e.g. the datapath width is
   fixed by the MAC).
4. **Timing won't close otherwise.** A design that doesn't build has infinite latency.

### When to resist
1. The path is directly in the tick-to-trade chain and timing already closes.
2. You could go **wider** instead (§3) — usually strictly better.
3. You could **precompute** instead (§4) — strictly better, costs no latency.

---

## 2. Initiation interval (II)

**II** = cycles between accepting successive inputs.

| II | Meaning |
| --- | --- |
| 1 | Fully pipelined: a new input every cycle. **Required on the RX path.** |
| 2 | Half rate — you can only accept every other cycle |
| N | Serialized loop; almost never acceptable on the fast path |

**Hard requirement:** the feed handler's RX path must have **II = 1** at the MAC
data width. The wire delivers a beat every cycle and will not wait. Any II > 1
means you need a buffer, and a buffer means you can overflow, and overflow means
dropped market data.

Things that break II = 1:
- A resource shared between pipeline stages (one BRAM port, one DSP)
- A feedback loop (this cycle's result feeds next cycle's input)
- A variable-latency operation

The feedback-loop case is the hard one and shows up in book updates: "read level,
modify, write back". If two updates to the same price level arrive back-to-back,
the second reads stale data. Fixes:
- **Forwarding/bypass**: detect the same-address case and forward the in-flight
  value combinationally (costs logic depth).
- **Bank by price level** so consecutive updates rarely collide, and handle
  collisions with a 1-cycle stall (costs jitter — count it).

---

## 3. Widen before you deepen

The most important structural decision in the design.

```
10 Gbps line rate:
  64-bit  @ 156.25 MHz → 8 bytes/cycle  → a 48-byte ITCH msg spans 6 cycles
  256-bit @ 156.25 MHz → 32 bytes/cycle → spans 2 cycles
  512-bit @ 156.25 MHz → 64 bytes/cycle → spans 1 cycle
```

If your message fits in one beat, you can decode it, look up the symbol, update the
book, and evaluate the strategy in a short fixed pipeline with **no message
reassembly state machine at all**. That eliminates cycles *and* eliminates an entire
class of bug (messages straddling beat boundaries).

Costs of going wide:
- Logic area scales roughly linearly with width
- Wide muxes and shifters (byte-alignment) get expensive — a 512-bit barrel shifter
  is significant
- Routing congestion increases
- More LUTs → possibly lower Fmax

**Rule of thumb for this project:** choose the width so that your *most
latency-critical message type* (typically a Nasdaq `Add Order` or `Execute` at
~30–40 bytes, or a CME MDP incremental refresh entry) fits in one or two beats.
Then keep the clock at whatever closes comfortably.

> ⚠️ Don't width-convert twice. A 64-bit MAC → 512-bit core → 64-bit MAC design
> pays gearbox latency at both ends. If the MAC is 64-bit, consider whether the
> *parser* can be 64-bit with a wide *dispatch*, rather than widening everything.

---

## 4. Precompute: the free optimization

Anything that does not depend on this cycle's input can be computed *before* it
arrives and held in a register. This removes logic from the critical path at zero
latency cost.

Examples that matter here:

| Instead of | Precompute |
| --- | --- |
| On each tick: `qty * price > notional_limit` | Precompute `notional_limit / price` per symbol in software; compare `qty > limit_qty` (1 comparison) |
| On each tick: recompute the strategy threshold from parameters | Compute thresholds when parameters change (slow path), store per-symbol |
| On order emit: build the whole OUCH message | Pre-build the template with all static fields; on trigger, only splice in price/qty/side/token |
| On each tick: check 8 risk conditions | Fold static conditions into a precomputed per-symbol "tradeable" bit |

**The pre-built order template is the single highest-leverage precompute in a
trading FPGA.** The outbound message is mostly constant (session, account,
instrument, order type, most flags). Keep a per-symbol template in BRAM; on trigger,
read it and overwrite ~10 bytes. This turns "encode an order" from a multi-cycle
serialization into a 1–2 cycle memory read plus a mux.

See [04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md).

---

## 5. Speculation

Compute all possible outcomes in parallel; select the right one when the condition
resolves. Trades area (cheap) for depth (expensive).

```systemverilog
// Serial: 2 dependent stages
result = compute(select_input(sel));

// Speculative: 1 stage, 2× area
result_a = compute(input_a);
result_b = compute(input_b);
result   = sel ? result_a : result_b;
```

Applied to trading:
- **Speculative order encoding.** Start building *both* a buy and a sell order the
  moment a book update begins; discard the wrong one when the strategy resolves.
  Removes the strategy→encode dependency from the critical path.
- **Speculative risk check.** Evaluate risk against both candidate sizes in
  parallel.
- **Speculative transmission (aggressive — know the rules).** Some designs begin
  streaming an order's leading bytes onto the wire before the decision is final,
  because the first N bytes are identical regardless. This is real and used, but:
  > ⚠️ You must be able to **abort** the frame (corrupt the CRC deliberately so the
  > venue drops it) if the decision goes the other way. Verify with the venue that
  > deliberately-invalid frames are acceptable and won't trip their error-rate
  > thresholds or a disconnection policy. Get this in writing before deploying it.

---

## 6. Parallelism strategies

| Strategy | Description | Fits |
| --- | --- | --- |
| **Spatial (replication)** | N copies of a block, each on a different symbol/feed | Multiple feeds, multiple venues |
| **Datapath width** | Process more bytes per cycle | Feed parsing (§3) |
| **Pipeline** | Overlap stages of different messages | Throughput, not latency |
| **Tree reduction** | log-depth combining | Only off the critical path |

**Replication for multiple feeds** is the cleanest scaling axis here. Each feed
gets its own decoder and its own book region; they only converge at the strategy
layer. This keeps each pipeline simple, avoids arbitration on the hot path, and
scales linearly with fabric.

The convergence point (strategy sees updates from N feeds) is where you pay: either
arbitrate (jitter) or replicate the strategy per feed (area, plus a cross-feed
consistency problem). For a latency-arb strategy you replicate; for a book-based
strategy on a single instrument you arbitrate.

---

## 7. Retiming

Synthesis can automatically move logic across register boundaries to balance stage
delays.

```systemverilog
(* SHREG_EXTRACT = "NO" *)          // keep FFs available for retiming
logic [W-1:0] pipe_q [DEPTH];
```

Vivado: `synth_design -retiming on`, or the `-directive PerformanceOptimized`
strategies. Quartus: "Perform register retiming" in Fitter settings.

- **Works well** when you've put N registers in a row and let the tool distribute
  the logic among them. A common idiom: place all the logic in one stage plus 3
  empty pipeline registers, and let retiming balance it.
- **Doesn't work** across memory blocks, across module boundaries with
  `DONT_TOUCH`, or on paths with `KEEP` attributes.
- **⚠️ Retiming changes which register holds what.** ILA probes and timing
  constraints that reference specific registers will break. Retime the datapath;
  don't retime blocks you're debugging.

---

## 8. Worked example: budgeting a decode pipeline

Target: Nasdaq ITCH `Add Order` (36 bytes) → book update, at 156.25 MHz (6.4 ns/cycle).

```
Stage 0  Frame arrival, 512-bit beat                      1 cycle   6.4 ns
Stage 1  UDP/MoldUDP64 header strip, message framing      1 cycle   6.4 ns
Stage 2  Message type decode + field extraction (mux)     1 cycle   6.4 ns
Stage 3  Symbol (stock locate) → book slot, BRAM read     1 cycle   6.4 ns
Stage 4  BRAM output register                             1 cycle   6.4 ns
Stage 5  Book level update + top-of-book compare          1 cycle   6.4 ns
Stage 6  Strategy trigger evaluation                      1 cycle   6.4 ns
Stage 7  Order template read (BRAM)                       1 cycle   6.4 ns
Stage 8  Template splice + risk check                     1 cycle   6.4 ns
Stage 9  TX handoff                                       1 cycle   6.4 ns
                                                        ─────────────────
                                                         10 cycles  64 ns
```

64 ns of *fabric* latency. Add MAC + PCS + SerDes both ways (~150–300 ns) and you
are in the 250–400 ns wire-to-wire range — competitive.

**How to read this table:** every row is a line item you can attack. Stages 3+4
(symbol lookup through BRAM) are 12.8 ns for a table read — if your symbol universe
is small enough to hold in registers or LUTRAM, you save a full cycle. Stage 7 could
merge with stage 5 if the template read is issued speculatively on *every* book
update rather than after the trigger.

That is the shape of the optimization work in
[05-optimization/05-optimization-playbook.md](../05-optimization/05-optimization-playbook.md).

---

## 9. Rules for this project

1. **Every pipeline stage on the fast path needs a justification** in the module
   header. "Timing required it" is a valid justification; "it seemed cleaner" is not.
2. **Prefer width over depth.** Then prefer precompute over both.
3. **II = 1 on the RX path is non-negotiable.**
4. **Fixed latency over variable.** If a block takes 3–7 cycles, make it always 7
   unless the mean saving is large and you can defend the jitter.
5. **Count every stall.** A stall you don't count is jitter you can't explain.

---

## Further reading

- [00-foundations/05-timing-closure.md](../00-foundations/05-timing-closure.md)
- [05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md)
- [04-system-architecture/01-tick-to-trade-pipeline.md](../04-system-architecture/01-tick-to-trade-pipeline.md)
