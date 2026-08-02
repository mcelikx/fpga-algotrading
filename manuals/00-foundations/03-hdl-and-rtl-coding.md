# 00.03 — HDL and RTL Coding

> **Project standard:** synthesizable **SystemVerilog** (IEEE 1800-2017). No VHDL in
> new code. Testbenches are Python (cocotb) — see
> [01-fpga-design/05-verification-and-simulation.md](../01-fpga-design/05-verification-and-simulation.md).

---

## 1. The mental model

**You are not writing a program. You are describing hardware that exists all at
once.** Every `always_ff` block is a physical bank of flip-flops that clocks on
every edge, forever. Every `assign` is a permanent wire-and-LUT network.

The three things that trip people up coming from software:

1. **Everything runs in parallel.** Ten `always_ff` blocks are ten pieces of
   hardware operating simultaneously, not ten statements in sequence.
2. **Loops unroll.** `for (int i = 0; i < 8; i++)` in synthesizable code creates
   8 copies of the hardware. It is not a loop at runtime. An unbounded loop is not
   synthesizable at all.
3. **Cost is spatial, not temporal.** A wider comparison costs *area* and
   *propagation delay*, not "more instructions".

---

## 2. The three block types — use exactly these

```systemverilog
// Sequential logic. Creates flip-flops.
always_ff @(posedge clk) begin
    q <= d;
end

// Combinational logic. Creates LUTs. Must assign every output on every path.
always_comb begin
    next_state = state;          // default assignment ← prevents latches
    unique case (state)
        IDLE: if (start) next_state = RUN;
        RUN:  if (done)  next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

// Continuous assignment. Also combinational, for simple expressions.
assign is_crossed = (best_bid >= best_ask);
```

**Never use bare `always`.** `always_ff` and `always_comb` let the tools check your
intent, and they will error on the classic mistakes instead of silently building
something else.

### Blocking vs. non-blocking — the one rule
- `<=` (non-blocking) **inside `always_ff`**. Always.
- `=` (blocking) **inside `always_comb`**. Always.

Mixing them produces designs where simulation and synthesis disagree. That class of
bug is expensive to find and there is no upside to risking it.

---

## 3. Latches — the number one inference trap

A latch is level-sensitive storage that synthesis infers when a combinational block
does not assign an output on every possible path.

```systemverilog
// ⚠️ BROKEN — infers a latch on `y` when sel == 2'b11
always_comb begin
    case (sel)
        2'b00: y = a;
        2'b01: y = b;
        2'b10: y = c;
    endcase
end

// CORRECT — default assignment first
always_comb begin
    y = '0;
    case (sel)
        2'b00: y = a;
        2'b01: y = b;
        2'b10: y = c;
        default: y = '0;
    endcase
end
```

Latches in an FPGA are **catastrophic**: they are not properly timed by STA, they
create combinational feedback paths, and they will produce a design that works in
simulation and fails intermittently in hardware.

**Rules:**
- Every `always_comb` starts with default assignments to all its outputs.
- Every `case` has a `default`.
- Every `if` has an `else`, or a default assignment above it.
- **Treat any latch warning from synthesis as a build failure**, not a warning.

---

## 4. Naming and style conventions for this project

```systemverilog
module feed_decoder #(
    parameter int unsigned DATA_W    = 64,
    parameter int unsigned N_SYMBOLS = 1024
) (
    input  logic                 clk,
    input  logic                 rst,        // synchronous, active high

    // AXI-Stream-like input
    input  logic [DATA_W-1:0]    s_tdata,
    input  logic [DATA_W/8-1:0]  s_tkeep,
    input  logic                 s_tvalid,
    input  logic                 s_tlast,
    output logic                 s_tready,

    // Decoded output
    output logic [63:0]          m_price,
    output logic [31:0]          m_qty,
    output logic                 m_valid
);
```

| Convention | Rule |
| --- | --- |
| Types | `logic` everywhere. Never `reg`/`wire` in new code. |
| Signedness | Explicit `logic signed` when signed. Never rely on defaults. |
| Suffix `_q` | Registered value (output of a FF) |
| Suffix `_d` | Next value (input to a FF) |
| Suffix `_n` | Active low — use sparingly, prefer active high |
| Prefix `s_` / `m_` | Slave (input) / master (output) stream port |
| Parameters | `UPPER_SNAKE`, typed (`int unsigned`, not bare `parameter`) |
| Signals, modules, files | `lower_snake_case`; one module per file, filename = module name |
| Constants | `localparam`, never `` `define `` for module-scoped values |
| Reset | `rst`, synchronous, active high, project-wide |

Widths: **always size your literals.** `8'd5`, not `5`. Unsized literals are a
frequent source of truncation and sign-extension bugs that simulate fine at narrow
widths and break when you parameterize.

---

## 5. Registered outputs by default

```systemverilog
// Preferred: output is a flip-flop. The consumer sees a clean, fast signal.
always_ff @(posedge clk) begin
    m_valid <= s_valid && match;
    m_price <= price_calc;
end
```

Combinational module outputs chain across module boundaries and create critical
paths that are hard to attribute — the timing report shows a path through six
modules and no single owner. Registering outputs makes every module's timing
locally analyzable.

**Exception:** the `tready` backpressure signal in a valid/ready handshake is
conventionally combinational. If you need it registered, use a **skid buffer** —
see [01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md).

---

## 6. Reset strategy

```systemverilog
always_ff @(posedge clk) begin
    if (rst) begin
        state   <= IDLE;      // control state: MUST reset
        valid_q <= 1'b0;      // valid flags: MUST reset
    end else begin
        state   <= next_state;
        valid_q <= valid_d;
        data_q  <= data_d;    // datapath: NO reset needed
    end
end
```

- **Synchronous, active high.** Asynchronous reset costs a dedicated routing
  resource, complicates timing, and risks reset-removal recovery violations.
- **Reset only what needs it:** state machines, valid/ready flags, counters,
  configuration registers.
- **Do not reset the datapath.** Data registers get valid data before their `valid`
  flag asserts, so their reset value is irrelevant. Resetting them wastes a routing
  resource on every FF and can *cost you Fmax* by loading the reset net with
  thousands of sinks.
- Reset must be **synchronized and de-asserted synchronously** in each clock domain
  (a reset synchronizer). See [04-clocking-reset-and-cdc.md](04-clocking-reset-and-cdc.md).

---

## 7. Patterns that synthesize badly

| Anti-pattern | Why it hurts | Do this instead |
| --- | --- | --- |
| Division `a / b` | Huge, slow, multi-cycle | Multiply by precomputed reciprocal, or restructure: `a/b > c` → `a > b*c` |
| Modulo `a % b` | Same | Power-of-two masks, or a counter with wrap-compare |
| Variable shift `a << n` | Barrel shifter — large LUT tree | Fixed shifts, or pipeline the barrel shifter |
| Floating point | Not available in fabric without huge IP | Fixed-point |
| Wide priority encoder over 1024 entries | Deep LUT chain, terrible Fmax | Hierarchical/tree encoder, pipelined |
| Big combinational mux (`N:1`, N large) | Deep LUT tree + routing | Pipelined mux tree, or restructure to a memory read |
| Combinational feedback loop | Unroutable / oscillates | Insert a register |
| Reading a BRAM and using it same cycle | Impossible — BRAM read is ≥1 cycle | Pipeline the consumer |
| `for` over a large range with dependencies | Serial LUT chain, no parallelism | Tree reduction |

### The wide-comparison problem, concretely
Finding the max of 256 price levels combinationally is an 8-deep comparator tree:
~8 LUT levels + 8 routing hops ≈ 3–5 ns. At 156.25 MHz (6.4 ns) that's tight; at
322 MHz (3.1 ns) it fails. Pipeline it into 2–3 stages, or maintain the max
incrementally so you never recompute it. See
[04-system-architecture/03-order-book-in-hardware.md](../04-system-architecture/03-order-book-in-hardware.md).

---

## 8. Parameterization and generate

```systemverilog
generate
    for (genvar i = 0; i < N_LANES; i++) begin : g_lane
        lane_decoder #(.LANE_ID(i)) u_lane (
            .clk    (clk),
            .rst    (rst),
            .data   (data[i]),
            .result (result[i])
        );
    end
endgenerate
```

- **Always name generate blocks** (`: g_lane`). Unnamed blocks produce
  tool-generated hierarchy names that break your timing constraints and ILA probes
  when anything shifts.
- Use `generate`/`genvar` for structural replication, `for` inside `always_comb`
  for combinational unrolling.
- Parameters over `` `define ``: parameters are scoped, `` `define `` is global and
  order-dependent across the whole compile.

---

## 9. Assertions

Put them in the RTL, guarded so they don't synthesize.

```systemverilog
`ifndef SYNTHESIS
    // Once tvalid is asserted, tdata must not change until tready
    assert property (@(posedge clk) disable iff (rst)
        (s_tvalid && !s_tready) |=> (s_tvalid && $stable(s_tdata))
    ) else $error("AXIS stream contract violated");

    // Price must never be zero on a valid book update
    assert property (@(posedge clk) disable iff (rst)
        m_valid |-> (m_price != 0)
    ) else $error("Zero price on valid update");
`endif
```

Assertions are the cheapest bug-finding tool available in hardware design. Assert:
- Protocol contracts on every stream interface
- FIFO never overflows or underflows
- One-hot state encodings really are one-hot
- Counters never wrap unexpectedly
- Domain invariants (bid < ask on a non-crossed book; qty > 0 on a live order)

---

## 10. Checklist before submitting a module

- [ ] Header comment states purpose, latency (cycles + ns), and resource budget
- [ ] `always_ff` / `always_comb` only; no bare `always`
- [ ] No latch warnings in synthesis
- [ ] Every `case` has `default`; every `always_comb` has default assignments
- [ ] Outputs registered (or exception justified in a comment)
- [ ] All literals sized; all parameters typed
- [ ] Reset applied only to control state
- [ ] No division, modulo, or floating point
- [ ] Assertions on every stream interface
- [ ] Testbench exists and passes
- [ ] Verilator `-Wall` clean

Full review checklist: [07-reference/04-checklists.md](../07-reference/04-checklists.md).

---

## Further reading

- [01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) — the reusable structures
- [04-clocking-reset-and-cdc.md](04-clocking-reset-and-cdc.md) — reset and clock domain rules
- [01-fpga-design/05-verification-and-simulation.md](../01-fpga-design/05-verification-and-simulation.md) — proving it works
