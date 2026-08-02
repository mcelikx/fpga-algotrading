# 00.04 — Clocking, Reset, and Clock Domain Crossing

> **Why this matters here:** CDC bugs are the worst class of bug in this domain.
> They pass simulation, pass timing, pass a week of soak testing, and then corrupt
> one order in ten million on a hot afternoon. Every CDC in this project uses a
> sanctioned primitive, no exceptions.

---

## 1. Project clocking policy

```
                  ┌─────────────────── FPGA ────────────────────┐
   SFP+ ──► GT ──►│ RX clk (recovered)                          │
                  │      │                                      │
                  │      └─► [async FIFO] ─► core_clk domain ───┼──► everything
                  │                            156.25 MHz       │
                  │      ┌─── TX clk (ref) ◄──[async FIFO]◄─────┤
   SFP+ ◄── GT ◄──│      │                                      │
                  │                                             │
   PCIe ─────────►│ pcie_clk (250 MHz) ─►[async FIFO / CDC]────►│ core_clk
                  └─────────────────────────────────────────────┘
```

**Rules:**
1. **One core clock for the entire datapath.** All feed handling, book, strategy,
   and order encoding run in `core_clk`.
2. CDC exists in exactly three places: MAC RX boundary, MAC TX boundary,
   PCIe/control boundary. Nowhere else.
3. Every clock is declared in the XDC with `create_clock` or
   `create_generated_clock`. An underived clock is an unconstrained clock, and an
   unconstrained clock is an unverified design.
4. Every asynchronous crossing is declared with `set_max_delay -datapath_only` or
   `set_clock_groups -asynchronous`. **Never** blanket `set_false_path` a whole
   clock pair — it hides real problems.

### Choosing the core clock frequency
For a 10GbE 64-bit datapath, the natural rate is **156.25 MHz** (10 Gbps / 64 bits).
You have three choices:

| Approach | Fmax needed | Trade-off |
| --- | --- | --- |
| 64-bit @ 156.25 MHz | 156 MHz — easy | 8 bytes/cycle; a 50-byte message takes 7 cycles to arrive |
| 256-bit @ 156.25 MHz | 156 MHz — easy | 32 bytes/cycle; wider logic, more LUTs, but far fewer cycles |
| 64-bit @ 322 MHz | hard | Only helps if you're latency-bound *inside* your logic, not on the wire |

**For tick-to-trade, go wide before you go fast.** Serialization off the wire is a
hard floor you cannot beat with clock speed; a wider datapath lets you act on a
message the same cycle it completes. See
[01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md).

---

## 2. Metastability — the actual physics

A flip-flop needs its input stable for `T_setup` before and `T_hold` after the
clock edge. If a signal from another clock domain changes inside that window, the
FF enters a **metastable** state: its output is neither 0 nor 1, but somewhere in
between, for an unbounded (but exponentially unlikely to be long) time.

You cannot prevent metastability. You can only give it time to resolve, which is
what a synchronizer does. The metric is **MTBF** (mean time between failures), and
it improves exponentially with each added synchronizer stage and with clock period.

> ⚠️ Two consequences people miss:
> - **A 2-FF synchronizer only works for a single bit.** Synchronizing a multi-bit
>   bus with parallel 2-FF chains is *broken*: different bits resolve on different
>   cycles, producing a value that never existed. This is the classic CDC bug.
> - Metastability is a *probability*, not a *possibility*. A design with an
>   inadequate synchronizer works perfectly in the lab and fails in production
>   because production runs 24/7 for months.

---

## 3. The four sanctioned CDC primitives

Put these in `rtl/common/cdc/` and use nothing else.

### 3.1 Single-bit level synchronizer (2-FF)

For a **slowly changing level** — a config enable, a status flag, a kill switch.

```systemverilog
module cdc_sync_bit #(parameter int STAGES = 2) (
    input  logic dst_clk,
    input  logic src_bit,
    output logic dst_bit
);
    (* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync_q;

    always_ff @(posedge dst_clk)
        sync_q <= {sync_q[STAGES-2:0], src_bit};

    assign dst_bit = sync_q[STAGES-1];
endmodule
```

`(* ASYNC_REG = "TRUE" *)` tells the tools to place the FFs adjacent, maximizing
the settling time between them. **Omitting it is a real bug**, not a style issue.

⚠️ This only works if the source is stable for **at least 2 destination clock
periods**. A single-cycle pulse crossing to a slower domain will be missed.

### 3.2 Pulse synchronizer (toggle)

For a **single-cycle pulse** crossing domains.

```systemverilog
// Source domain: toggle a level on each pulse
always_ff @(posedge src_clk)
    if (src_pulse) toggle_q <= ~toggle_q;

// Destination domain: sync the level, detect the edge
cdc_sync_bit u_sync (.dst_clk(dst_clk), .src_bit(toggle_q), .dst_bit(tog_sync));
always_ff @(posedge dst_clk) tog_sync_q <= tog_sync;
assign dst_pulse = tog_sync ^ tog_sync_q;
```

⚠️ Rate-limited: source pulses must be spaced by ≥2 destination clock periods, or
they merge. If the source can burst, use a FIFO instead.

### 3.3 Asynchronous FIFO (gray-coded)

**The default for any multi-bit data crossing.** Write pointer and read pointer
are gray-coded (only one bit changes per increment), so a mis-sampled pointer is
off by at most one position — conservatively, never incorrectly.

Use it for: MAC RX → core, core → MAC TX, PCIe → core, any bus crossing.

- Cost: **~2–3 destination clock cycles of latency**. Budget it.
- Use the vendor's XPM (`xpm_fifo_async`) or a well-reviewed open implementation.
  **Do not write your own.** The pointer arithmetic and full/empty edge cases are
  subtle and the failure mode is silent corruption.

### 3.4 Handshake (req/ack) for a data bus

For **infrequent, wide** transfers where a FIFO is overkill — configuration
register writes, parameter updates.

```
src: place data on bus (held stable) → assert req
dst: sync req → capture data → assert ack
src: sync ack → deassert req → may change data
```

The data bus itself is **never synchronized** — it is guaranteed stable by the
protocol, and constrained with `set_max_delay -datapath_only` rather than being
treated as a clocked path. Only `req` and `ack` cross through synchronizers.

Latency: ~4–6 cycles round trip. Fine for the control plane, far too slow for the
datapath.

---

## 4. Reset

### The problem
An asynchronous reset asserting is fine — everything goes to a known state. An
asynchronous reset **de-asserting** near a clock edge causes exactly the same
metastability problem, and different FFs come out of reset on different cycles.
A state machine can end up in an illegal state on the first cycle after reset.

### The solution: reset synchronizer
Assert asynchronously (so it works even with no clock), de-assert synchronously.

```systemverilog
module reset_sync (
    input  logic clk,
    input  logic async_rst_in,   // active high, from anywhere
    output logic sync_rst_out    // active high, synchronous to clk
);
    (* ASYNC_REG = "TRUE" *) logic [1:0] rst_q;

    always_ff @(posedge clk or posedge async_rst_in) begin
        if (async_rst_in) rst_q <= 2'b11;
        else              rst_q <= {rst_q[0], 1'b0};
    end

    assign sync_rst_out = rst_q[1];
endmodule
```

**Every clock domain gets its own `reset_sync` instance.** Downstream of that, all
reset usage is synchronous (`if (rst)` inside `always_ff @(posedge clk)`).

### Reset policy for this project
| Register class | Reset? |
| --- | --- |
| FSM state | Yes |
| `valid` / `ready` / request flags | Yes |
| Counters and sequence numbers | Yes |
| Configuration and risk-limit registers | Yes (to a **safe** value — limits to zero, trading disabled) |
| Datapath data registers | **No** |
| Pipeline delay-line data | **No** |

⚠️ **Configuration registers must reset to the safe state, not the useful one.**
Position limits reset to 0. Trading-enabled resets to 0. A bitstream reload must
never come up armed.

---

## 5. Constraining CDC in XDC

```tcl
# Declare the domains as asynchronous to each other
set_clock_groups -asynchronous \
    -group [get_clocks core_clk] \
    -group [get_clocks pcie_clk] \
    -group [get_clocks rx_clk]

# For handshake data buses: bound the skew, don't ignore the path
set_max_delay -datapath_only \
    -from [get_cells {u_cfg/data_reg[*]}] \
    -to   [get_cells {u_cfg_dst/data_capture_reg[*]}] \
    2.000

# Bus skew: all bits must arrive within one destination period
set_bus_skew \
    -from [get_cells {u_cfg/data_reg[*]}] \
    -to   [get_cells {u_cfg_dst/data_capture_reg[*]}] \
    4.000
```

> ⚠️ `set_false_path` on a CDC bus tells the tool "I don't care how long this
> takes." The tool will then happily route one bit 8 ns and another 0.5 ns, and
> your handshake-protected data will be captured torn. **Use `set_max_delay
> -datapath_only` plus `set_bus_skew`, not `set_false_path`.**

---

## 6. CDC verification

Timing analysis does **not** check CDC correctness — by definition, those paths are
excluded from STA. You need separate checking:

1. **Structural CDC lint.** Vivado `report_cdc`, Quartus equivalent, or a dedicated
   tool. Run it on every build and treat findings as errors. It catches:
   - Missing synchronizers
   - Multi-bit buses through parallel 2-FF chains
   - Signals reconverging after separate synchronizers
   - Combinational logic before a synchronizer (glitches get sampled)
2. **Simulation with randomized clock phase.** Run your async FIFO testbench at
   several clock ratios, including nearly-equal frequencies (the hardest case).
3. **Metastability injection.** Some simulators can randomly delay CDC outputs by
   one cycle. Enable it in regression.

---

## 7. Common CDC bugs, concretely

| Bug | Symptom | Fix |
| --- | --- | --- |
| Multi-bit bus through 2-FF chains | Occasional impossible values (e.g. a price that was never quoted) | Async FIFO or handshake |
| Missing `ASYNC_REG` | Works, then fails after a placement change | Add the attribute |
| Combinational logic feeding a synchronizer | Glitches sampled as real transitions | Register before crossing |
| Reconvergence: two signals synchronized separately then combined | Momentarily inconsistent pair (valid asserted with stale data) | Cross them together through one FIFO |
| Pulse to slower domain | Events silently lost, counters drift | Toggle synchronizer or FIFO |
| `set_false_path` on a data bus | Torn data under temperature/voltage change | `set_max_delay -datapath_only` + `set_bus_skew` |
| Reset de-assertion not synchronized | FSM starts in illegal state, ~1 in 10⁶ resets | `reset_sync` per domain |

---

## Further reading

- [01-fpga-design/03-memory-and-storage.md](../01-fpga-design/03-memory-and-storage.md) — FIFO sizing and implementation
- [05-timing-closure.md](05-timing-closure.md) — constraining what STA *does* check
- [04-system-architecture/06-cpu-fpga-partitioning.md](../04-system-architecture/06-cpu-fpga-partitioning.md) — the PCIe crossing in practice
