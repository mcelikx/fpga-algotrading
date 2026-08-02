# 00.01 — Digital Logic and Timing

> **Why this matters here:** every nanosecond in the tick-to-trade budget is either
> a gate delay, a wire delay, or a clock period you chose to spend. This document
> is where those three come from.

---

## 1. Two kinds of logic

### Combinational
Output is a pure function of the current inputs. No memory, no clock.

```systemverilog
assign sum = a + b;                 // combinational
assign sel = (price > threshold);   // combinational
```

Physically this is a network of LUTs and routing. It has a **propagation delay**:
the time from the last input settling to the output settling. It is not free and
it is not instant.

### Sequential
Output depends on inputs *and* on stored state. Requires a clock.

```systemverilog
always_ff @(posedge clk) begin
    sum_q <= a + b;                 // sequential: result appears next cycle
end
```

Physically this is a flip-flop (FF): it samples its input on the rising clock edge
and holds that value until the next edge.

**The entire craft of RTL design is deciding how much combinational logic to put
between two flip-flops.** Too much → the design won't run fast enough. Too little →
you burn clock cycles (and therefore latency) on trivial work.

---

## 2. The fundamental timing equation

Between any two flip-flops driven by the same clock:

```
T_clk  ≥  T_cq  +  T_logic  +  T_route  +  T_setup  +  T_skew(worst) + T_uncertainty
```

| Term | Meaning | Typical (UltraScale+, -2 speed grade) |
| --- | --- | --- |
| `T_clk` | Clock period. 156.25 MHz → 6.4 ns | your choice |
| `T_cq` | Clock-to-Q: FF output valid after the edge | ~0.1–0.2 ns |
| `T_logic` | Combinational delay through LUTs | ~0.1 ns per LUT level |
| `T_route` | **Wire delay between LUTs** | ~0.1–1.0+ ns per hop |
| `T_setup` | Input must be stable this long *before* the edge | ~0.05–0.1 ns |
| `T_skew` | Clock arrives at the two FFs at slightly different times | ~0.05–0.3 ns |
| `T_uncertainty` | Jitter + tool margin | ~0.05–0.1 ns |

**Slack** = `T_clk − (everything on the right)`. Positive slack: the path works.
Negative slack: it does not, at that frequency.

> ⚠️ **On modern FPGAs, `T_route` usually dominates `T_logic`.** A 6-input function
> is one LUT (~0.1 ns of logic), but getting the signal to that LUT from across the
> die can cost several nanoseconds. This is why *floorplanning* and *keeping related
> logic together* matter more than shaving LUT levels. See
> [05-timing-closure.md](05-timing-closure.md).

### Hold time
The mirror problem: input must remain stable *after* the edge for `T_hold`. A hold
violation happens when a path is too **fast** — the new value races to the next FF
before it has latched the old one.

- Setup violations are fixed by **slowing down or pipelining**.
- Hold violations are fixed by **adding delay** (the tools insert routing detours).
- Setup violations are frequency-dependent; **hold violations are not**. A hold
  violation cannot be fixed by lowering the clock. Within one clock domain the tools
  almost always fix hold automatically; across domains, hold is *your* problem.

---

## 3. Latency vs. throughput

These are independent, and confusing them is the single most common error in
low-latency design.

- **Latency**: time from an input entering the block to its result leaving. Measured
  in nanoseconds. *This is what a trading system is judged on.*
- **Throughput**: results produced per unit time. Measured in messages/sec or
  bits/sec. *This is what determines whether you keep up with the feed.*

A 20-stage pipeline at 400 MHz has:
- latency = 20 × 2.5 ns = **50 ns**
- throughput = **400 M results/sec**

A single-cycle combinational block at 50 MHz has:
- latency = **20 ns** (better!)
- throughput = **50 M results/sec** (8× worse)

For tick-to-trade, you need *both*: line rate throughput (you cannot drop packets)
and minimum latency (you are racing other participants). The reconciliation is a
**wide, shallow pipeline**: process many bits per cycle so you need few cycles.

```
10GbE at 156.25 MHz with a 64-bit datapath = 8 bytes/cycle.
A 50-byte ITCH message spans 7 cycles just to arrive off the wire.
Widening to 512-bit @ 156.25 MHz → 64 bytes/cycle → 1 cycle.
```

This trade — **width for depth** — is the core lever of the whole design.
See [01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md).

---

## 4. Where latency actually comes from

For a trading datapath, in rough descending order of magnitude:

| Source | Scale | Notes |
| --- | --- | --- |
| Serialization (bits onto/off the wire) | 0.8 ns/byte @ 10G | Unavoidable physics. 64-byte frame = ~51 ns. |
| Transceiver + PCS (SerDes, 64b/66b) | 50–150 ns each way | Hard IP; low-latency modes exist but cost features. |
| MAC | 5–50 ns | Cut-through MAC is dramatically better than store-and-forward. |
| Your logic | 20–300 ns | The part you control. |
| Cable / fibre | ~5 ns/m (fibre), ~4.3 ns/m (copper) | 100 m of fibre = 500 ns. Cabling is a real design variable. |
| Switch hop | 40–500 ns | Cut-through switch ~40–90 ns; store-and-forward far worse. |

> The lesson that surprises people: **you may spend more time in the SerDes and the
> cable than in your entire trading algorithm.** Optimize the whole path, and know
> which parts you can and cannot move. See
> [07-reference/02-latency-reference-numbers.md](../07-reference/02-latency-reference-numbers.md).

---

## 5. Determinism and jitter

CPUs give you a good average and a terrible tail: cache misses, branch
mispredictions, interrupts, TLB shootdowns, frequency scaling, NUMA effects, kernel
preemption. A CPU tick-to-trade path might be 2 µs at p50 and 50 µs at p99.9.

FPGAs give you a **fixed** number of cycles. A fixed-latency FPGA pipeline is
2 ns wide at p99.999 because the same path runs every time.

**This determinism is the actual product.** In practice you often lose more money to
the tail than to the mean:

```
Mean latency  → how often you win the race.
Tail latency  → how badly you get picked off when you lose it.
```

Design rule: **prefer a fixed-latency design to a lower-mean variable-latency one.**
If a block can complete in 3 or 7 cycles depending on input, seriously consider
making it always take 7. See
[05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md).

Sources of jitter that do creep into FPGA designs:
- Arbitration between contending sources (two feeds hitting one book port)
- FIFO occupancy when a burst arrives
- Variable-length message parsing (a message spanning a packet boundary)
- CDC synchronizers (1–2 cycles of uncertainty by construction)
- Any handshake that can stall

Each of these is a place to count and histogram, not to assume.

---

## 6. Number representation on the fast path

**No floating point in fabric.** It is large, slow, and multi-cycle. Everything is
integer or fixed-point.

- **Prices**: scaled integers. Nasdaq ITCH uses 4 implied decimals — a price of
  $123.4500 arrives as `1234500`. Keep it that way; do not convert.
- **Quantities**: unsigned integers, native.
- **Ratios / weights**: fixed-point `Q<m>.<n>`. Document `m` and `n` in the port
  comment. Multiplying `Q16.16 × Q16.16` gives `Q32.32` — you must explicitly
  choose which 32 bits to keep and whether to round or truncate.
- **Division**: avoid. Replace with multiply-by-reciprocal (precompute the
  reciprocal in software, ship it over PCIe) or restructure the comparison:
  `a/b > c` becomes `a > b*c` when `b > 0`.

> ⚠️ Silent overflow is the classic fixed-point bug and it is *catastrophic* here —
> a wrapped quantity becomes a wrong order size. Either size widths for the true
> worst case, or saturate explicitly and count saturation events.

---

## 7. Quick reference: cycles at a glance

| Clock | Period | 100 ns is… |
| --- | --- | --- |
| 100 MHz | 10.0 ns | 10 cycles |
| 156.25 MHz (10GbE, 64-bit) | 6.4 ns | ~15.6 cycles |
| 200 MHz | 5.0 ns | 20 cycles |
| 250 MHz | 4.0 ns | 25 cycles |
| 322.27 MHz (25GbE, 64-bit) | 3.1 ns | ~32 cycles |
| 400 MHz | 2.5 ns | 40 cycles |

Useful mental model: at 156.25 MHz you have roughly **6 ns per pipeline stage**, and
a realistic budget of **~10–20 logic levels** per stage before routing eats you.

---

## Further reading

- [02-fpga-architecture.md](02-fpga-architecture.md) — what those LUTs and FFs physically are
- [05-timing-closure.md](05-timing-closure.md) — making the equation in §2 come out positive
- [05-optimization/01-latency-budgeting.md](../05-optimization/01-latency-budgeting.md) — spending the nanoseconds
