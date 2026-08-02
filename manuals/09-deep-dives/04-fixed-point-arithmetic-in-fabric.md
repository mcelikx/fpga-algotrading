# 09.04 — Fixed-Point Arithmetic in Fabric

> **Why this matters here:** every number on the tick-to-trade path is an integer with an implied scale, and
> the sub-microsecond budget in `rtl/fpga_top.sv` rests on that being true. A float on the fast path costs
> cycles you do not have; worse, it destroys the property that makes the design *verifiable* — that the
> cocotb golden model in `host/pymodel/` and the fabric produce **the same bits**. This is the arithmetic
> contract: how a scale is declared, how a product grows, where you may throw bits away, how you prove
> nothing overflows, and how every division gets deleted.
> [00.03](../00-foundations/03-hdl-and-rtl-coding.md) §7 lists the patterns that synthesize badly; this is
> the positive form of the same rules.

---

## 1. No floating point — as engineering, not as dogma

| Property | FP32/FP64 in fabric | Scaled integer |
| --- | --- | --- |
| Add / multiply latency | Multi-cycle IP core (align, add, normalize, round) | 1 cycle; an adder, or one DSP |
| Area | Hundreds of LUTs + DSPs per operator | An adder |
| Deterministic cycle count | Yes, but *long* | Yes, and short |
| **Bit-exactness vs. the golden model** | **Negotiable** | **Guaranteed** |
| Associativity | `(a+b)+c ≠ a+(b+c)` | Exact until you overflow |
| Representing `$10.01` | **Inexact** | **Exact** — `100100` |

**Prices are already integers** — ITCH carries a count of $0.0001 units, not a real number, and rendering an
exactly-representable quantity inexact is a strict loss with no compensating gain.

⚠️ **Bit-exactness is a *verification* requirement, not an aesthetic one.** The regression in
[01.05](../01-fpga-design/05-verification-and-simulation.md) §4 replays pcap through the RTL and through
`host/pymodel/trading_pkg_mirror.py` and asserts equality. With integers, "equal" means equal and a mismatch
is a bug; with floats every mismatch becomes a negotiation about tolerance, rounding mode and evaluation
order, and you have lost your only oracle. The mirror is explicit — *no floats, no `Decimal`, on the model
path* — and re-parses the SystemVerilog package at import to prove the scales have not drifted. The same
reasoning bans `real` from RTL packages: `trading_pkg` carries the clock as `CORE_CLK_PS = 6_400`, not
`6.4`, because a `real` leaks into every importing file.

---

## 2. Q-format notation and the discipline around it

`Qm.n` is **binary** fixed point: `m+n` bits with LSB `2^-n`; `sQm.n` is the signed form (`m` integer bits
*plus* a sign bit). ⚠️ **Money in this system is not `Qm.n`** — the venue scales prices by `10^4`, a decimal
scale, and calling that `Q32.0` is true and misleading. So `Dk` means an integer count of `10^-k` units, and
`Qm.n` is reserved for quantities **we** define at both ends (ratios, thresholds, weights) where the rescale
is a free shift. **Never invent a decimal scale:** if the venue gives you `D4`, carry `D4`.

Read from `rtl/pkg/trading_pkg.sv` — these are the contract, not proposals:

| Quantity | Type | Width | Format | LSB | Range |
| --- | --- | ---: | --- | --- | --- |
| Price | `price_t` | 32 u | `D4` (`PRICE_SCALE = 10000`) | $0.0001 | $0 … $429,496.7295 |
| Shares | `qty_t` | 32 u | `D0` | 1 share | 0 … 4,294,967,295 |
| Notional | `notional_t` | 64 u | `D4` | $0.0001 | 0 … ~$1.845 × 10¹⁵ |
| Position | `position_t` | 40 s | `D0` | 1 share | ±549,755,813,888 shares |
| Exchange timestamp | `ts_ns_t` | 48 u | ns since midnight ET | 1 ns | one day, comfortably |
| Cycle counter | `cycle_t` | 48 u | `CORE_CLK_PS = 6400` | 6.4 ns | ~20.8 days |
| Imbalance threshold | `sym_strat_t.imbalance_thr` | 16 u | **`Q0.16`** (proposal) | `2^-16` | `[0, 1)` |

> **Verify:** the price field width (4 bytes) and the 4 implied decimals against the **Nasdaq TotalView-ITCH
> 5.0 specification**. `imbalance_thr` is declared 16 bits in `trading_pkg` but its *format* is stated
> nowhere — `Q0.16` is this document's proposal and must be written into the package before use.

**The four discipline rules.** (1) **The format lives in the type or the name, never in a comment** —
comments rot. `price_t` means `D4` because the package says so; `logic [31:0] px` specifies nothing, and a
width without a Q format is not a specification. Where no typedef implies the format, put it in the
identifier: `thr_q0_16`, `wgt_q1_15`. (2) **`typedef` the format, `localparam` the scale** — ⚠️ a literal
`10000` or `100` in RTL is a bug waiting for the day the scale changes. (3) **Every module port list
documents the Q format of every numeric port.** (4) **A rescale is an explicit, named operation** — never an
implicit assignment, never a bare `>>`.

```systemverilog
// PROPOSAL — additions to rtl/pkg/trading_pkg.sv. Formats, not just widths.
localparam int unsigned IMB_FRAC_BITS = 16;                       // Q0.16
typedef logic [IMB_FRAC_BITS-1:0] frac_q0_16_t;                   // [0,1)
typedef logic signed [PRICE_W:0]  px_delta_t;                     // sD4, 33 bits
// The ONLY sanctioned way to subtract two price_t. ⚠️ `ask - bid` on two UNSIGNED
// operands is unsigned arithmetic even when the target is signed (§6.2).
function automatic px_delta_t px_sub(input price_t a, input price_t b);
    return px_delta_t'($signed({1'b0, a}) - $signed({1'b0, b}));
endfunction
// Named rescale. Right shift with round-half-up; never write `x >> n` inline.
function automatic logic [63:0] rescale(input logic [63:0] x, input int unsigned n);
    return (n == 0) ? x : ((x + (64'd1 << (n-1))) >> n);
endfunction
```

---

## 3. Scaling ITCH prices: the zero-rescale rule

ITCH carries price as a fixed-width unsigned integer with a fixed number of implied decimals: `$12.3400` on
the wire is `123400`.

> **Verify:** field width and implied decimals **per message type**, from the **Nasdaq TotalView-ITCH 5.0
> specification**. Decode detail in [08.04](../08-nasdaq/04-totalview-itch-5.0.md) §3.

**THE RULE: choose the internal scale to equal the wire scale, so decode is a zero-cost reinterpretation.**
`PRICE_SCALE = 10000` exists for exactly this. The decoder byte-swaps (free — it is wire order) and assigns:
no multiply, no divide, no rounding, and therefore no place for an error to enter. Prices stay `D4` through
RTL, PCIe, host and logs; a decimal point appears only at the display layer, via integer division.

| Case where the rule cannot hold | Why | Handling |
| --- | --- | --- |
| A message type with a **different implied scale** (e.g. MWCB Decline Level) | The venue chose it | Rescale **once, at decode, into `D4`**, in a named function; never let a second scale escape the decoder. ⚠️ Coarser→`D4` is exact; finer→`D4` truncates — say so and count it |
| Sub-$1.00 securities | Rule 612 increment is `$0.0001` below $1.00 | `D4` represents this exactly. No rescale — only the *tick check* changes |
| Half-penny tick regime | Per-symbol, time-varying | Still `D4`. `tick_i ∈ {50, 100}` becomes a table field, not a constant |

> **Verify:** minimum pricing increments and the amended tick-size regime against **SEC Regulation NMS, 17
> CFR 242.612** and current *Nasdaq Equity Trader Alerts*. Background in
> [08.06](../08-nasdaq/06-regnms-and-compliance.md) §5.

**Price → level index is a subtract and a shift, not a divide.** With `BOOK_LEVELS = 16` around a per-symbol
reference price, `lvl = mul_shift(px_sub(px, base_px[sym]), recip_tick[sym], TICK_RECIP_SHIFT)`, where `tick`
comes from the symbol table: whole penny at `D4` is 100 (not a power of two, so a reciprocal multiply, §8.4),
half-penny is 50, and sub-$1 is 1 so the shift vanishes entirely. ⚠️ Range-check the index **before** it
indexes anything — a price outside the window yields an out-of-range index, and an unchecked index into a
16-entry array is a silent read of the wrong level, not an error.

---

## 4. Multiplication: width growth and where to truncate

```
Qa.b × Qc.d  =  Q(a+c).(b+d),  in exactly (a+b) + (c+d) bits.
Dj  × Dk     =  D(j+k),        same width arithmetic.
```

| Product formed in this design | Operands | Exact product | Format | Notes |
| --- | --- | ---: | --- | --- |
| `price × qty` → notional | 32 u × 32 u | **64** | `D4` | Fits `notional_t` exactly. `sat_arith_pkg::sat_mul_px_qty` |
| `qty × price_delta` → P&L increment | 32 u × 33 s | **65 s** | `sD4` | ⚠️ Wider than `notional_t`; accumulate in signed 72 bits (proposal) |
| `θ × (bid_qty + ask_qty)` → imbalance | 16 u × 33 u | **49** | `Q0.16`-scaled | §8.1 |
| `px × RECIP_100` → whole-penny test | 32 u × 31 u | **63** | — | `trading_pkg::div100` |
| `edge_ticks × tick` | 32 u × 32 u | **64** | `D4` | Bounded well below 64 in practice; still declare 64 |

A product is **exact if you give it room**, so the full-width product is the cheap case and every bit you
remove costs a decision. **Rule: truncate as late as possible, to a width justified by the *use* of the
number, and prove the discarded bits cannot change the decision.** Three corollaries: **a comparison needs no
rescale** — `a/b > c/d` with `b,d > 0` becomes `a·d > c·b`, both sides at full width, and two multipliers
plus a comparator beat two rescales plus a comparator while staying *exact* rather than rounding-dependent
(the gate in §9 truncates nowhere at all); **truncate at a storage boundary, not at an arithmetic node**,
because BRAM and PCIe log records force a width and nothing else does; and **if you truncate mid-chain, prove
the bits are dead** — "the low bits are fractions of a cent and the limit is in whole cents" is a proof, "it
looked fine in the replay" is not.

⚠️ Truncating *before* a comparison changes the answer at the boundary — precisely where a risk limit is
decided. Compare first, truncate after.

---

## 5. Rounding modes and their bias

| Mode | Fabric cost on an `n`-bit right shift | Bias | Notes |
| --- | --- | --- | --- |
| **Truncate toward zero** | Free unsigned; **magnitude logic when signed** | Toward zero (positive for negatives) | ⚠️ Not the same as floor |
| **Floor** (arithmetic shift `>>>`) | **Free** | −0.5 LSB, always | What `>>>` actually does |
| **Round half up** | One add of `1<<(n−1)`, then shift | ~0 for symmetric data; **positive for signed** | Default here (§2, `rescale`) |
| **Round half to even** | Add + a LUT of tie detect | **Zero** | Required in accumulators |
| **Round half away from zero** | Add + sign-dependent constant | Zero, symmetric in magnitude | Rarely worth it |

`rescale()` in §2 is the round-half-up implementation; round-half-to-even is identical except that an exact
tie adds `q[0]` instead of 1, costing one comparator, and it is the only unbiased option.

A truncation applied to a signed quantity that **accumulates** — running P&L, position-weighted average
price, an EWMA of the mid — drifts by up to 0.5 LSB *per operation, always in the same direction*. Over 10⁷
operations in a session that is 5 × 10⁶ LSB; at `D4`, $500 of pure arithmetic bias in a number the risk gate
reads. It never crashes; it shows up as the FPGA and the host disagreeing about position by an amount that
grows monotonically through the day.

⚠️ **Floor and truncate-toward-zero differ only for negatives** — `−7 >> 1` is `−4` under floor, `−3` under
truncation. Positions and P&L are the only signed accumulators here, so this bug is invisible in every
long-only replay and appears the first time you go short.

**Rules.** The rounding mode is stated in the module header, is asserted against `host/pymodel/` in the
cocotb regression **on negative inputs**, and the regression must carry a short-side pcap fixture.
Accumulators round half-to-even or carry the residue.

---

## 6. ⚠️ Overflow analysis as a proof obligation

**For every arithmetic node on the fast path you must state the proven range of the result and show it fits
the declared width — using the *contractual* bounds on the inputs, not the realistic ones.** "AAPL never
trades above $500" is not a bound. `collar_hi ≤ 2^32−1` is.

| # | Expression | Input bounds (contractual) | Proven range | Declared | Fits? |
| --- | --- | --- | --- | --- | --- |
| 1 | `px` from decoder | ITCH 4-byte price | `[0, 2^32−1]` | `price_t` 32 | ✔ by construction |
| 2 | `qty` from strategy | `≤ max_order_qty` (`qty_t`) | `[0, 2^32−1]` | `qty_t` 32 | ✔ |
| 3 | `notional = px × qty` | 1, 2 | `≤ (2^32−1)² < 2^64` | `notional_t` 64 | ✔ **width alone proves it** |
| 4 | `day_used' = day_used + notional` | 3, ≤ `N_ord` orders/session | `≤ N_ord × max_order_notional` | `notional_t` 64 | ⚠️ **rests on a host parameter** |
| 5 | `pos' = pos ± qty` | `qty_t` 32 u into 40 s | **not provable from widths** | `position_t` 40 | ⚠️ needs saturation |

Node 3 is the good case — structural, assumption-free, and the reason `NOTIONAL_W` is 64 and not 48. Nodes 4
and 5 are the interesting ones: their bounds come from *parameters*.

### 6.1 ⚠️ The trap: a host-loaded bound is not a bound

Node 4's proof reads *at most `N_ord` orders per session, each of notional at most `max_order_notional`.*
With the outbound rate limit over a 6.5-hour session `N_ord ≈ 2.3 × 10⁷`; against a 48-bit-ceilinged
`max_order_notional` that leaves ample headroom, and against an unclamped 64-bit one the proof is **vacuous**.

> **Verify:** the CSR field width of `max_order_notional` in
> [08.09](../08-nasdaq/09-risk-controls-and-limits.md) §10 against the `sym_risk_t` member width in
> `rtl/pkg/trading_pkg.sv`. If the register map and the packed struct disagree, **the narrower one silently
> governs** and the wider declaration is a lie.

**RULE: a parameter is a bound only if the hardware clamps it on load** — so the parameter write path is part
of the overflow proof.

```systemverilog
// ctrl/csr_regfile.sv — clamp on the WRITE, not on the read. Count the clamp.
localparam notional_t MAX_ORDER_NOTIONAL_CEIL = 64'd1_000_000_000;   // $100k at D4
always_ff @(posedge clk) if (wr_max_notional) begin
    param_clamped  <= (wr_data > MAX_ORDER_NOTIONAL_CEIL);
    p_max_notional <= (wr_data > MAX_ORDER_NOTIONAL_CEIL) ? MAX_ORDER_NOTIONAL_CEIL : wr_data;
end
```

⚠️ The failure mode is exact and silent: the proof assumes `max_order_qty ≤ X`, the host writes `X+1`,
nothing rejects it, and the proof is false with no symptom until an accumulator wraps mid-session. Every
ceiling used in a range proof is a synthesis-time `localparam`, is clamped at the CSR write, and the clamp
increments a readable counter.

### 6.2 ⚠️ SystemVerilog truncates for you, silently

**The assignment target's width participates in the expression context.** That mostly saves you — and then it
does not:

```systemverilog
logic [31:0] a, b;  logic [63:0] n;   price_t bid, ask;   logic signed [32:0] spread;
n = a * b;                             // OK: 64-bit context -> 64-bit multiply
assign narrow = a * b;                 // ⚠️ narrow is 32b -> 32-bit multiply, top half GONE
automatic logic [31:0] tmp = a * b;    // ⚠️ self-determined 32-bit. The classic. Widening
n = tmp;                               //    AFTER the loss is worthless; ditto a narrow
function automatic logic [31:0] f();   //    function return type.
spread = ask - bid;                    // ⚠️ BOTH operands unsigned -> UNSIGNED arithmetic;
spread = px_sub(ask, bid);             //    ask<bid gives a huge POSITIVE. This is correct.
```

Full trap list in [00.03](../00-foundations/03-hdl-and-rtl-coding.md) §7. Verilator `WIDTH`/`WIDTHTRUNC`
catches most of these — **treat them as errors on the fast path**.

### 6.3 Assertions: the proof, mechanized

```systemverilog
`ifndef SYNTHESIS   // one per arithmetic node; always on in sim, free in fabric
a_notional_fits : assert property (@(posedge clk) disable iff (rst)
    req_valid |-> (notional_s1 == (64'(px_s1) * 64'(qty_s1))));
a_qty_bounded   : assert property (@(posedge clk) disable iff (rst)
    req_valid |-> (qty <= p_max_order_qty));
a_day_monotone  : assert property (@(posedge clk) disable iff (rst)
    (!day_reset) |-> (day_used >= $past(day_used)));   // catches a wrap in one cycle
a_no_saturate   : assert property (@(posedge clk) disable iff (rst) !pos_sat);
`endif
```

The pcap regression re-runs these against real venue data on every commit, so the range proof is checked
continuously instead of living in a design document. `a_day_monotone` is the highest-value line: a wrapping
accumulator is the catastrophe of [08.09](../08-nasdaq/09-risk-controls-and-limits.md) §3, and monotonicity
detects it in one cycle. See [01.05](../01-fpga-design/05-verification-and-simulation.md) §5 and
[09-failure-modes-and-postmortems.md](09-failure-modes-and-postmortems.md).

---

## 7. Saturating vs. wrapping — and when each is *correct*

| Quantity class | Behaviour | Why |
| --- | --- | --- |
| **Position accumulator** (`position_t`) | **Saturate**, flag, fail closed | Feeds a limit compare. A wrapped long reads as a short and the limit inverts |
| **Notional / exposure accumulator** | **Saturate**, flag, fail closed | Feeds a limit compare |
| **Open-order count, credits** | **Saturate** | Wraps to zero → the cap is deleted |
| **Price arithmetic** | **Neither — prove it cannot overflow** | A saturated price is a *wrong price*; there is no safe direction to clamp in |
| **Index arithmetic** (level, symbol) | **Range-check and reject** | Clamping to level 15 quietly reads the wrong level |
| **Sequence numbers** (MoldUDP64) | **Wrap** | Modular by definition; gap detection is a modular compare |
| **Free-running cycle counter** | **Wrap** | Modular by definition — and correct for deltas (§7.2) |
| **Telemetry counters** | **Wrap** (48 b, host handles) | Statistics; a lost count is not a risk event |

**The principle:** *saturate where the value feeds a comparison against a limit*, because saturation fails
safe — a saturated position looks maximal and therefore blocks trading. *Wrap where the value is modular by
definition.* **Never allow a silent wrap on anything that feeds a risk decision**; that is the worst failure
mode in the design ([08.09](../08-nasdaq/09-risk-controls-and-limits.md) §3,
[04.05](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) §4). `rtl/pkg/sat_arith_pkg.sv` is
the sanctioned implementation, and every function there returns a `saturated` flag — a saturation nobody
counts is a wrap with extra steps.

```systemverilog
function automatic logic signed [W-1:0]
    sat_add_s(input logic signed [W-1:0] a, b, output logic sat);
    logic signed [W:0] s;
    s   = $signed({a[W-1], a}) + $signed({b[W-1], b});    // one guard bit
    sat = (s[W] != s[W-1]);                               // signed overflow
    return sat ? (s[W] ? {1'b1, {(W-1){1'b0}}} : {1'b0, {(W-1){1'b1}}}) : s[W-1:0];
endfunction
```

⚠️ Do not build signed saturating subtract as `sat_add_s(a, -b)`: negating the most negative value overflows
and reintroduces the exact bug. ⚠️ **Never test a value you had to clamp** — ask "would this breach?"
*before* committing the arithmetic (`sat_arith_pkg::pos_would_breach_long`).

### 7.2 A wrapping cycle counter is *correct* for latency deltas

`cycle_t` is free-running, 48-bit, unsigned, and the latency measurement is one bare subtract with no wrap
handling: `delta = now_cycle - evt.rx_cycle;`. Unsigned subtraction in `W` bits *is* arithmetic modulo `2^W`:
if the true elapsed count is `Δ` and the counter wrapped `k` times, the two register values are `t₀ mod 2^W`
and `(t₀+Δ) mod 2^W`, whose difference mod `2^W` is `Δ mod 2^W`. Exact, **provided `Δ < 2^W`** — 2⁴⁸ cycles
at 6.4 ns is ~20.8 days. The wrap saves the comparator, the branch and the pipeline stage a "corrected"
version would need. Two design rules keep it true: the counter is never reset between samples, and both
samples come from the same counter in the same clock domain
([05.04](../05-optimization/04-measurement-and-profiling.md)).

---

## 8. Division elimination

There is no divider on the fast path, and no `%`.

```
a / b > c            ⇒   a > c·b            ⚠️ ONLY IF b > 0
bid/(bid+ask) > θ    ⇒   bid·2^F > θ_q0F·(bid+ask)
```

⚠️ The sign caveat is load-bearing: if `b` can be negative the inequality flips, and if `b` can be zero the
original is undefined while the transform silently answers `a > 0`. Assert `b > 0` at the call site; for the
imbalance test, `bid+ask == 0` on an empty book must be rejected *before* the comparison, not decided by it.

```systemverilog
logic [QTY_W:0] tot;  logic [QTY_W+IMB_FRAC_BITS:0] lhs, rhs;   // 33b, 49b: exact
tot = {1'b0, bid_qty} + {1'b0, ask_qty};
lhs = ({1'b0, bid_qty} << IMB_FRAC_BITS);   rhs = tot * {33'd0, p_imbalance_thr};
imbalanced = (tot != 0) && (lhs > rhs);
```

### 8.1 Host-precomputed constants — the highest-leverage rule in this file

**Anything constant for the trading day belongs in a table, not in fabric arithmetic.** Per-symbol tick
reciprocals, notional limits already multiplied out, collar bounds, round-lot sizes, fair value, LULD bands:
the host computes them at millisecond cadence and writes scaled integers; the fabric does a BRAM read and a
compare. This deletes more logic than every other technique here combined, and it is what
[05.03](../05-optimization/03-resource-power-optimization.md) §10 means by "precompute". Geometry:
`N_ACTIVE = 256` entries, one BRAM per field, double-buffered with a commit bit so the fast path never reads
a half-written record — and it is *not* a timing path:

```tcl
# Parameter-table writes come from PCIe at ms cadence, not per tick.
set_multicycle_path -setup 4 -from [get_pins u_csr/p_*_reg*/C] -to [get_pins u_risk_gate/param_*_reg*/D]
set_multicycle_path -hold  3 -from [get_pins u_csr/p_*_reg*/C] -to [get_pins u_risk_gate/param_*_reg*/D]
```

### 8.2 Reciprocal multiply, and its error

For a divisor that is per-symbol but constant intraday, the host writes `R = floor(2^k / x)` and the fabric
computes `(a·R) >> k`. Since `2^k/x − 1 < R ≤ 2^k/x`, the computed `q̂ = floor(a·R / 2^k)` satisfies
`q − ⌊a/2^k⌋ − 1 < q̂ ≤ q` where `q = ⌊a/x⌋` — a **one-sided under-estimate**. Pick `k ≥ ⌈log₂(a_max)⌉` and
the error is at most 1 LSB; ⚠️ that off-by-one is still on the wrong side of a risk limit, so either fold
1 LSB into the limit or use the exact form below.

### 8.3 Divide by a small constant: magic-number multiply-shift, *proved*

`trading_pkg::div100` already does this for the Rule 612 whole-penny test: `q = (px × 1_374_389_535) >> 37`,
where the constant is `ceil(2^37/100)`.

```python
#!/usr/bin/env python3
"""scripts/gen_magic.py — an exact multiply-shift reciprocal, with its proof.
Granlund-Montgomery: with m = ceil(2**k/d), (x*m)>>k == x//d for every x < 2**n
iff  2**k <= m*d <= 2**k + 2**(k-n).  Integer arithmetic only — no floats."""
def magic(d: int, n: int) -> tuple[int, int]:
    for k in range(n, 2 * n + 2):                          # smallest exact shift
        m = -(-(1 << k) // d)                              # ceil(2**k / d)
        if (1 << k) <= m * d <= (1 << k) + (1 << (k - n)):
            return m, k
    raise ValueError(f"no exact magic for d={d}, n={n}")

for d, n in ((100, 32), (50, 32), (10_000, 32)):           # penny, half-penny, dollar
    m, k = magic(d, n); e = m * d - (1 << k)               # interval proof:
    assert 0 <= e <= (1 << (k - n)), f"PROOF FAILED e={e}"
    assert n > 24 or all((x * m) >> k == x // d for x in range(1 << n))   # exhaustive
    print(f"parameter logic [{m.bit_length()-1}:0] RECIP_{d} = {m};  // >> {k}, err {e}")
```

For `d = 100, n = 32` this reproduces `m = 1_374_389_535, k = 37` with error `28 ≤ 32` — so `div100` is exact
across the **entire** 32-bit price range, one bit better than the `px < 2^31` claim in the package comment.
⚠️ That gap is the point: the constant was right, the *stated* range was narrower than the proof, and nobody
could tell without re-deriving it. **Generate these constants; never hand-carry them.**

| Division form | Replacement | Cost | Error |
| --- | --- | --- | --- |
| `a / 2^n` | `a >> n` (`>>>` if signed) | free | exact (floor) |
| `a / b > c` | `a > c·b`, `b > 0` | 1 multiply | **exact** |
| `a / b > c / d` | `a·d > c·b`, `b,d > 0` | 2 multiplies | **exact** |
| `a / K`, `K` a small compile-time constant | `(a·m) >> k` (§8.3) | 1 DSP + shift | **exact, proved** |
| `a / x`, `x` per-symbol, intraday-constant | `(a·R) >> k`, host writes `R` | 1 BRAM + 1 DSP | ≤ 1 LSB, one-sided |
| `a % K` | `a − K·(a/K)` via the above | +1 multiply | exact |
| Anything else | **Move it to the host** | 0 in fabric | n/a |

---

## 9. Worked example: the order-notional gate, end to end

**Task.** An ITCH price and our quote size arrive. Compute the prospective order's notional, check it against
the per-symbol per-order notional limit *and* the remaining daily notional budget, and produce the
accept/reject bit within the 2-cycle (12.8 ns) budget `rtl/fpga_top.sv` gives the risk stage.

| # | Node | Expression | Format | Width | Truncation |
| --- | --- | --- | --- | ---: | --- |
| 1 | `px` | `order_req_t.price` | `D4` | 32 u | none |
| 2 | `qty` | `order_req_t.qty` | `D0` | 32 u | none |
| 3 | `notional` | `px × qty` | `D4` | **64 u** | **none — full product** |
| 4 | `lim_ord` | `sym_risk_t.max_order_notional` | `D4` | 64 u | clamped at CSR write (§6.1) |
| 5 | `day_left` | `day_budget − day_used`, saturating | `D4` | 64 u | none |
| 6 | `accept` | `(3 ≤ 4) && (3 ≤ 5)` | bit | 1 | — |

**The truncation decision: there is none, and that is the design.** Both limits are `D4`, so the comparison
is `D4` against `D4` at 64 bits. Rescaling to whole cents would save one comparator slice and introduce a
rounding-mode question at the exact boundary where the limit is decided.

```systemverilog
// rtl/risk/notional_gate.sv  (PROPOSAL)
// LATENCY  : 2 cycles = 12.8 ns @156.25 MHz, fixed, no stalls.
// RESOURCE : ~2 DSP48E2 (32x32 -> 64), ~200 LUT, ~200 FF.
// FORMATS  : i_px D4 (price_t) | i_qty D0 (qty_t) | all notionals D4 (notional_t)
// ROUNDING : none. No value is rescaled anywhere in this module.
module notional_gate import trading_pkg::*, sat_arith_pkg::*;
(   input  logic clk, rst, i_valid,
    input  price_t    i_px,  input  qty_t      i_qty,        // D4, D0
    input  notional_t i_lim_ord,                             // D4, CSR-clamped (§6.1)
    input  notional_t i_day_left,                            // D4, saturating (§7)
    output logic o_valid, o_accept );
    sat_notional_t n_c;  notional_t n_q, lim_q, day_q;  logic v_q;
    // Stage 1: the exact 64-bit product. 32x32 cannot exceed 64 bits (§6).
    always_comb n_c = sat_mul_px_qty(i_px, i_qty);           // .saturated is always 0
    always_ff @(posedge clk) begin
        v_q <= rst ? 1'b0 : i_valid;
        n_q <= n_c.value;  lim_q <= i_lim_ord;  day_q <= i_day_left;
    end
    // Stage 2: two 64-bit unsigned compares. Reset = reject (fail closed).
    always_ff @(posedge clk) begin
        o_valid  <= rst ? 1'b0 : v_q;
        o_accept <= rst ? 1'b0 : (v_q && (n_q <= lim_q) && (n_q <= day_q));
    end
`ifndef SYNTHESIS
    a_exact : assert property (@(posedge clk) disable iff (rst)
        v_q |-> (n_q == 64'($past(i_px)) * 64'($past(i_qty))));
`endif
endmodule
```

**The overflow proof, in full.** Node 3: `px ≤ 2^32−1` and `qty ≤ 2^32−1` by type, so
`notional ≤ (2^32−1)² = 2^64 − 2^33 + 1 < 2^64`. It fits `notional_t` **with no assumption about market
prices or order sizes** — structural, and the reason `NOTIONAL_W` is 64. Node 5 needs a contract instead:
`day_used` accumulates, therefore saturates; `day_left` is a saturating subtract floored at zero; a
saturation on either is a reject *and* a kill trigger, never a clamp-and-continue. `sat_mul_px_qty` returns
`saturated = 0` always, by that proof — the flag exists only so call sites look identical to the ones that
can saturate. **Cycle cost:** 2, fixed, no backpressure; the 32×32 multiply is the only DSP-shaped operation,
so pipeline stage 1 if it lands on the critical path.

> **Verify:** DSP48E2 pipeline depth and achievable Fmax against **UG579** (*UltraScale Architecture DSP
> Slice*) before assuming one cycle.

---

## 10. Rules for this project

1. **No floating point, no `real`, on the fast path or in a package** — it breaks bit-exactness against
   `host/pymodel/`, the only oracle we have.
2. **Every scaled signal declares its format in its type or its name.** A width is not a specification.
3. **The internal price scale equals the wire scale (`D4`).** Decode is a reinterpretation; rescale only
   where the venue forces it, once, at the boundary, in a named function.
4. **Carry the full product; truncate only at storage boundaries**, with a written proof that the discarded
   bits cannot change the decision.
5. **Rounding mode is part of the module header** and is asserted against the golden model on negative
   inputs. Accumulators round half-to-even.
6. **Every fast-path arithmetic node has a stated range proof and a matching `assert property`**, citing
   contractual bounds only.
7. **A host-loaded bound is a bound only if the CSR write path clamps it** and counts the clamp.
8. **Saturate what feeds a limit; wrap only what is modular by definition; range-check and reject indices.**
   All saturation goes through `sat_arith_pkg` and sets a flag.
9. **No divider, no `%`.** Restructure, precompute on the host, or generate a proved magic constant.
10. **Verilator `WIDTH`/`WIDTHTRUNC` warnings are errors** on the fast path.

---

## Further reading

- [../00-foundations/03-hdl-and-rtl-coding.md](../00-foundations/03-hdl-and-rtl-coding.md) — the synthesizable subset and the width/signedness traps §6.2 depends on
- [../01-fpga-design/05-verification-and-simulation.md](../01-fpga-design/05-verification-and-simulation.md) — where §6.3's assertions run, and the pcap regression
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) §4 — the risk-gate specifics of saturation
- [../05-optimization/03-resource-power-optimization.md](../05-optimization/03-resource-power-optimization.md) §10 — why DSPs are usually the wrong answer, and precomputation instead
- [../08-nasdaq/04-totalview-itch-5.0.md](../08-nasdaq/04-totalview-itch-5.0.md) §3 — the ITCH price representation §3 builds on
- [../08-nasdaq/06-regnms-and-compliance.md](../08-nasdaq/06-regnms-and-compliance.md) §5 — Rule 612, the reason price is a scaled integer at all
- [../08-nasdaq/09-risk-controls-and-limits.md](../08-nasdaq/09-risk-controls-and-limits.md) §3 — the wrapping-accumulator catastrophe in operational form
- [09-failure-modes-and-postmortems.md](09-failure-modes-and-postmortems.md) — what a silent overflow looks like from the outside
