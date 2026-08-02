# 01.01 — RTL Design Patterns

> The reusable structures that make up a trading datapath. Learn these once; every
> block in the system is built from them.

---

## 1. Valid / ready handshake (AXI-Stream style)

The universal interface contract in this project.

```systemverilog
    output logic [63:0] m_tdata;
    output logic        m_tvalid;   // producer: "data is valid"
    input  logic        m_tready;   // consumer: "I can accept"
    output logic        m_tlast;    // end of packet/message
    output logic [7:0]  m_tkeep;    // byte enables on the last beat
```

**Transfer occurs when `tvalid && tready` on a rising clock edge.**

The contract — assert these:
1. Once `tvalid` is asserted it **must not de-assert** until a transfer completes.
2. `tdata`/`tkeep`/`tlast` **must remain stable** while `tvalid && !tready`.
3. `tready` **may** depend combinationally on `tvalid` (but see §2 — prefer it not to).
4. Neither side may wait for the other before asserting (no deadlock by
   construction: the producer asserts `tvalid` regardless of `tready`).

```systemverilog
`ifndef SYNTHESIS
assert property (@(posedge clk) disable iff (rst)
    (m_tvalid && !m_tready) |=> (m_tvalid && $stable(m_tdata) && $stable(m_tlast))
) else $error("stream contract violated");
`endif
```

> ⚠️ **On the RX path from the MAC, there is no backpressure.** The wire does not
> stop. `s_tready` on your feed handler input must be tied high, and any inability
> to keep up must be handled by dropping and counting — never by stalling. Design
> the RX path for guaranteed line rate. See
> [04-system-architecture/02-feed-handler-design.md](../04-system-architecture/02-feed-handler-design.md).

---

## 2. Skid buffer (register slice)

The problem: registering `tready` breaks the handshake, because by the time the
producer sees `!tready` it has already sent another beat. The skid buffer holds
that in-flight beat.

```systemverilog
module skid_buffer #(parameter int W = 64) (
    input  logic         clk, rst,
    input  logic [W-1:0] s_data,  input  logic s_valid,  output logic s_ready,
    output logic [W-1:0] m_data,  output logic m_valid,  input  logic m_ready
);
    logic [W-1:0] skid_data;
    logic         skid_valid;

    assign s_ready = !skid_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            m_valid    <= 1'b0;
            skid_valid <= 1'b0;
        end else begin
            // Fill skid when the output is stalled and new data arrives
            if (s_valid && s_ready && m_valid && !m_ready) begin
                skid_data  <= s_data;
                skid_valid <= 1'b1;
            end
            // Output register advances when it can
            if (!m_valid || m_ready) begin
                if (skid_valid) begin
                    m_data     <= skid_data;
                    m_valid    <= 1'b1;
                    skid_valid <= 1'b0;
                end else begin
                    m_data  <= s_data;
                    m_valid <= s_valid;
                end
            end
        end
    end
endmodule
```

- Costs **1 cycle of latency**, gives you fully registered `tvalid`/`tready`/`tdata`.
- Maintains **100 % throughput** (unlike a simple register, which halves it).
- Use it to break long `tready` combinational chains across many modules — a chain
  of 6 modules with combinational `tready` is a classic critical path.

**Trade-off for this project:** each skid buffer is a nanosecond you're spending.
Use them where timing demands, not reflexively. On the fast path, prefer a design
that never backpressures at all.

---

## 3. Finite state machines

```systemverilog
typedef enum logic [2:0] {
    S_IDLE     = 3'd0,
    S_HEADER   = 3'd1,
    S_PAYLOAD  = 3'd2,
    S_DISPATCH = 3'd3
} state_e;

state_e state_q, state_d;

// Next-state: combinational
always_comb begin
    state_d = state_q;                  // default: hold
    unique case (state_q)
        S_IDLE:     if (s_tvalid)          state_d = S_HEADER;
        S_HEADER:   if (hdr_complete)      state_d = S_PAYLOAD;
        S_PAYLOAD:  if (msg_complete)      state_d = S_DISPATCH;
        S_DISPATCH:                        state_d = S_IDLE;
        default:                           state_d = S_IDLE;
    endcase
end

// State register: sequential
always_ff @(posedge clk)
    if (rst) state_q <= S_IDLE;
    else     state_q <= state_d;
```

**Encoding choices:**
- **One-hot** (default for FPGA): 1 FF per state, decode is a single-bit test.
  Fastest, uses more FFs (which are cheap). Let synthesis choose, or force with
  `(* fsm_encoding = "one_hot" *)`.
- **Binary**: fewer FFs, more decode logic. Only for very large state counts.
- **Gray**: for states that cross clock domains (rare — prefer not to).

⚠️ **`unique case` is a promise to the tools**, and if it's violated in simulation
you get a runtime error, but in synthesis the tool assumes it and may build
something that misbehaves on an unreachable-but-reached state. Always include
`default` anyway.

**For the fast path, prefer flat, shallow FSMs.** A deeply nested FSM with many
transitions creates a wide combinational next-state function that becomes the
critical path. If a message parser needs 12 states, consider a counter-driven
pipeline instead — a fixed schedule beats a state machine when the schedule is
actually fixed.

---

## 4. Arbiters

Needed whenever multiple sources contend for one resource (two feeds writing one
book, several strategies emitting orders).

### Round-robin (fair)
```systemverilog
// Rotating priority: grant to the requester after the last grantee
logic [N-1:0] req, grant;
logic [$clog2(N)-1:0] last_grant_q;
// Mask requests at/below last grant, priority-encode; fall back to unmasked.
```

- **Fair**, bounded worst-case wait of N−1 cycles.
- Adds jitter — worst case latency is N−1 cycles worse than best case.

### Fixed priority
```systemverilog
always_comb begin
    grant = '0;
    for (int i = 0; i < N; i++)
        if (req[i] && grant == '0) grant[i] = 1'b1;   // priority encoder
end
```

- **Deterministic** for the highest-priority requester — 0 extra cycles, always.
- Starves low-priority requesters under sustained load.

**For a trading fast path, prefer fixed priority with the latency-critical path at
priority 0.** Determinism on the path that matters beats fairness across paths that
don't. Count starvation events so you know if the low-priority path is being
neglected.

⚠️ A wide priority encoder (N > 32) is a deep LUT chain. Build it hierarchically:
8 groups of 8, arbitrate within groups in parallel, then arbitrate between groups.

---

## 5. Content-addressable lookup (symbol → index)

The core operation of a feed handler: given an 8-byte symbol or a 32-bit
instrument ID, find its slot. Options:

| Approach | Latency | Cost | When |
| --- | --- | --- | --- |
| **Direct index** | 1 cycle (BRAM) | Memory ∝ ID space | Venue gives a dense numeric ID (CME security ID, ITCH stock locate) — **use this** |
| **Register comparator array** | 1 cycle combinational | N × width LUTs | Tiny universe (< 32 symbols) |
| **Hash + small bucket** | 2–3 cycles | Modest BRAM | Sparse keys, moderate universe |
| **Full CAM (TCAM)** | 1–2 cycles | Very expensive in fabric | Rarely justified |
| **Binary search tree in BRAM** | log₂(N) cycles | Compact | Too slow for the fast path |

**Design guidance:** almost every modern venue provides a dense integer key
(ITCH's `stock locate` field, CME's `SecurityID`). *Use it.* Direct-index into
BRAM is one cycle and needs no comparison. If a venue only gives you a symbol
string, do the string→ID mapping in **software** at session start and push the
table to the FPGA over PCIe — the symbol universe is known before the open.

For hashing when you must: a **CRC-based hash** is nearly free in fabric (XOR tree,
1 cycle), and a 2-way or 4-way set-associative table with a small overflow CAM
handles collisions with bounded latency.

---

## 6. Pipelined comparison / reduction trees

Finding a max, min, or sum over N items.

```systemverilog
// Stage 1: N/2 comparisons in parallel   (registered)
// Stage 2: N/4 comparisons in parallel   (registered)
// ...
// Stage log2(N): result
```

- Latency: `⌈log₂(N)⌉` cycles
- Throughput: 1 result/cycle (fully pipelined)
- N=256 → 8 cycles. At 156.25 MHz that is **51 ns** — a large chunk of a
  tick-to-trade budget.

**Therefore: don't do this on the fast path.** Maintain the result incrementally
instead. When a book level updates, compare the new value against the *current*
best in 1 cycle rather than recomputing over all levels. The only time you need the
full tree is on a level deletion that removes the current best — handle that as a
slower path and accept the jitter, or keep a small sorted top-N.

See [04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md).

---

## 7. Delay lines (pipeline matching)

When one branch of a datapath takes more cycles than another, delay the fast one.

```systemverilog
// Cheap: SRL-based shift register, no reset (so it maps to SRL32, not FFs)
logic [W-1:0] delay_line [DEPTH];
always_ff @(posedge clk) begin
    delay_line[0] <= data_in;
    for (int i = 1; i < DEPTH; i++)
        delay_line[i] <= delay_line[i-1];
end
assign data_out = delay_line[DEPTH-1];
```

- ⚠️ **Do not reset a delay line.** Resetting forces FF implementation instead of
  SRL, costing ~32× the resources for a deep line. The valid flag (which *is*
  reset) tells you when the data is meaningful.
- SRL32 gives you 32 stages per LUT. A 64-bit × 16-stage delay is ~32 LUTs, not
  1024 FFs.

Use a **single, explicit `PIPE_DEPTH` parameter** shared between the branch that
sets the depth and the delay line, so a change to one automatically matches the
other. Manually keeping two constants in sync is a bug waiting to happen.

---

## 8. Credit-based flow control

For crossing to a consumer with a finite buffer, when you cannot afford the
round-trip latency of a `tready` backpressure signal.

```
Producer holds a credit counter = consumer's free buffer slots.
Send  → credit--    (immediately, no round trip)
Consumer frees a slot → sends a credit return → credit++
Send only while credit > 0.
```

- **Zero added latency** in the common case (credits available).
- The round-trip latency is hidden as long as the buffer is ≥ `2 × RTT × rate`.
- Standard on PCIe and used in the order gateway to bound outstanding orders.

Initialize credits carefully on reset and after error recovery — a credit leak
silently throttles the path to zero and looks like a performance problem, not a bug.

---

## 9. Counter and saturating-arithmetic patterns

```systemverilog
// Saturating add — never wrap a position or a risk counter
function automatic logic [W-1:0] sat_add(logic [W-1:0] a, logic [W-1:0] b);
    logic [W:0] sum = a + b;                 // one extra bit
    return sum[W] ? '1 : sum[W-1:0];         // saturate on carry
endfunction
```

**All risk and position arithmetic saturates and counts saturation events.**
A wrapped position counter means a risk check passes when it should have failed.
This is the difference between a bug and a regulatory incident. See
[03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md).

Statistics counters (packets, drops, errors) should be wide enough not to wrap in a
trading day (a 48-bit counter at 10 Gbps packet rate is effectively never), and
should be **sticky-on-first-error** for error flags so a transient is not missed
between polls.

---

## 10. Pattern selection cheat sheet

| Need | Pattern |
| --- | --- |
| Move data between blocks | valid/ready stream |
| Break a long `tready` path | skid buffer |
| Sequence a multi-cycle operation | FSM (flat) or fixed-schedule counter |
| Share one resource | fixed-priority arbiter (fast path) / round-robin (fair) |
| Symbol → slot | direct index from venue ID; else hash + set-associative |
| Max/min over many | incremental maintenance, not a tree |
| Match pipeline depths | SRL delay line (unreset) |
| Remote consumer with a buffer | credit flow control |
| Cross clock domains | see [00-foundations/04-clocking-reset-and-cdc.md](../00-foundations/04-clocking-reset-and-cdc.md) |
| Risk / position arithmetic | saturating, with event counters |

---

## Further reading

- [02-pipelining-and-parallelism.md](02-pipelining-and-parallelism.md)
- [03-memory-and-storage.md](03-memory-and-storage.md)
- [00-foundations/03-hdl-and-rtl-coding.md](../00-foundations/03-hdl-and-rtl-coding.md)
