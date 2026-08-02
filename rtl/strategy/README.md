# rtl/strategy — The Strategy Layer

> **Budget rows S0–S1.** This layer owns **2 of the 20 fabric cycles**:
> `Strategy parameter read + trigger — 2 cyc, 12.8 ns` (fpga_top.sv latency table,
> cumulative 186.0 ns of the ~321 ns wire-to-wire target).
> To add a cycle here, you must remove one somewhere else.

---

## 1. The principle this layer exists to enforce

**The FPGA is a trigger evaluator over a parameter table. It is not a general
compute engine.**

| | Host (slow path) | FPGA (this layer) |
| --- | --- | --- |
| Cadence | milliseconds – seconds | nanoseconds |
| Owns | *what* to do, and *under what conditions* | *when*, and *how fast* |
| May be wrong | yes — it is a model | no — it is a comparison |
| May be slow | yes | no |
| In the trade path | **never** | always |

The host computes fair value, imbalance thresholds, quote sizes and edges, and
writes them into `param_table`. The fabric evaluates a **fixed** comparator and
threshold expression over those numbers and emits a request if it is true.

Three rules fall straight out of that, and every file here is written to them:

1. **There is not one trading constant in this RTL.** Every number the decision
   depends on arrived through the parameter table. A threshold hardcoded in
   Verilog is a threshold that needs a bitstream rebuild to change, and a
   bitstream rebuild is hours of P&R plus a timing risk plus a deploy window.
2. **No trading decision may require a host round trip.** Not a rare one, not a
   fallback one. If the FPGA cannot decide, the correct action is to do nothing
   and go quiet — never to ask.
3. **No division, no modulo, no floating point** (CLAUDE.md §5). Where a strategy
   conceptually needs a ratio, the **host precomputes the threshold** and the
   fabric **cross-multiplies**. See `trigger_logic.sv` §5 for the worked example.

The primitive set is deliberately small and fixed. That is the feature, not a
limitation: a new trading idea should normally be a **parameter change**
(microseconds, reversible, no rebuild), not a **fabric change**.

---

## 2. File index

| File | Role | Latency | Key property |
| --- | --- | --- | --- |
| `strategy_pkg.sv` | Strategy-select enum, decision struct, gate-reason enum, fixed-point constants, saturating helpers | — | Defines the vocabulary of the fixed trigger expression |
| `strategy_engine.sv` | Layer top. Instantiated by `fpga_top.sv`. Pipeline: parameter read → gating → trigger → emit | **2 cyc / 12.8 ns**, fixed, II=1 | Propagates `s_top.rx_cycle` into `m_req.rx_cycle` **unchanged** |
| `param_table.sv` | Per-symbol `sym_strat_t` store, `N_ACTIVE` entries | 1 cyc read (row S0) | **Atomic double-buffered update.** Bank is part of the read address |
| `trade_gate.sv` | Admission check, evaluated before any trigger logic | 0 cyc (combinational) | Fail-closed conjunction; rejections counted **by reason** |
| `trigger_logic.sv` | The four hardened primitives, selected by `strat_select` | 0 cyc (combinational, row S1) | Ratio without a divide; correct `is_short` |
| `position_track.sv` | Signed position + open-order count per symbol | 1 cyc read (row S0) | Estimate, not truth — host-forcible, drift counted |

### Pipeline

```
 cycle N     (S0)   s_top_valid ──┬─→ param_table.rd_en    ──┐
                                  ├─→ position_track.rd_en ──┤   registered
                                  ├─→ sym_state_q[sym]     ──┤   reads
                                  └─→ s0_top / s0_valid    ──┘

 cycle N+1   (S1)   ┌─ trade_gate     (comb) ──┐
                    │                          ├─→ output sanity ─→ [FF] m_req
                    └─ trigger_logic  (comb) ──┘

 cycle N+2          m_req_valid to risk_gate
```

`trade_gate` and `trigger_logic` run in **parallel**, not in series — the gate
verdict is applied as a veto at the end of the decision mux. Putting them in
series would add ~2 ns to a cycle that has under 1 ns of margin.

---

## 3. Where the layer sits

```
book_engine ──(book_top_t)──► STRATEGY LAYER ──(order_req_t)──► risk_gate ──► order_gateway
                                    ▲                              │
                                    └──────── fill_* feedback ──────┘
```

**Nothing in this directory is a risk control.** The non-bypassable pre-trade
risk controls required by SEC Rule 15c3-5 — price collars, LULD bands, SSR
enforcement, position and notional limits, the kill switch — live in
`rtl/risk/risk_gate.sv`, which every order passes through afterwards and which
has no bypass.

`trade_gate` exists so the strategy stops wasting risk-gate bandwidth and
order-to-trade ratio on quotes that were never going to be sensible. It is not a
compliance boundary and must never be relied on as one.

---

## 4. Parameter-update protocol — the sequence the host MUST follow

> ⚠️ **This is the money-losing bug class this layer is built around.** A
> strategy trading on a *mix* of old and new parameters — the new fair value
> with the old quote size, or a fair value that landed one cycle before its
> edge — puts an order in the market that no risk model ever approved. That is
> not a rounding error.

The defence is a double buffer plus a one-bit commit. The host never names a
bank: hardware routes every write to the inactive one (`wr_bank = ~active_bank`),
so the live bank is unaddressable by construction.

### The sequence

1. **Compute the whole table on the host.** Every symbol you want live in the
   next generation, not just the ones that changed. See step 3.

2. **Write each record, one field per 32-bit word**, to region `3'b000`:

   ```
   addr[15:13] = 3'b000            (PARAM region)
   addr[10:3]  = symbol index      (active-set index, 0..N_ACTIVE-1)
   addr[2:0]   = word index        (0..5)
   ```

   | word | field | hardware check applied at write time |
   | --- | --- | --- |
   | 0 | `ctrl` — `[0]`=`strat_enabled`, `[4:1]`=`strat_select` | `strat_select` must name a primitive that exists |
   | 1 | `quote_qty` | `!= 0` **and** `<= HARD_MAX_QTY` |
   | 2 | `edge_ticks` | none (zero is legal — join the touch) |
   | 3 | `min_book_qty` | none (zero means no minimum) |
   | 4 | `fair_value` | `!= 0` — **required field**, see below |
   | 5 | `imbalance_thr` (in `[15:0]`) | `[31:16] == 0` **and** `>= IMB_SCALE` (256) |

   A word that fails its check **clears** that word's validity bit, which
   invalidates the whole record. The symbol simply does not become tradeable —
   it does not half-land.

   `fair_value` is required even for primitives that ignore it. A zero fair
   value would make `fair_value + edge` a live sell trigger against essentially
   every bid in the book — the classic uninitialised-parameter blowup. Write the
   current mid.

   `edge_ticks` must be **pre-scaled into ITCH price units** by the host: a
   $0.01 tick is 100 units, a $0.0001 tick is 1. The fabric never multiplies by
   a tick size, because the tick regime is per-symbol and a variable multiply
   does not fit in S1.

3. ⚠️ **Write EVERY symbol you want live. The shadow bank is not a copy of the
   active bank.** On commit, the newly-shadow bank's validity mask is cleared in
   a single cycle, so a symbol you skip has `params_valid = 0` and stops
   trading. This is deliberate. Without it, committing after writing one symbol
   would silently revert every *other* symbol to its two-generations-ago values —
   a partial write that quietly resurrects stale parameters is exactly the
   failure this module exists to prevent. A forgotten symbol going *quiet* is a
   visible failure; a forgotten symbol trading on last week's fair value is not.

   Cost: 256 symbols × 6 words = 1536 posted PCIe writes, ~150 µs. Irrelevant at
   a millisecond parameter cadence.

4. **Verify.** Read back `stat[13][15:0]` (`generation`) and `stat[14][15:0]`
   (bad-address writes) and confirm nothing unexpected moved. If
   `stat[13][31:16]` (commit errors) is nonzero, a previous commit was refused
   and the parameters you believe are live are **not** live.

5. **Commit** — a single write to `cfg_commit`, in a **separate, later**
   transaction. It must not be in the same cycle as a parameter write, nor the
   immediately following cycle (`shadow_any_ready` is registered). PCIe posted
   writes are hundreds of cycles apart, so this is free in practice and asserted
   in simulation.

   On commit the hardware either:
   - **flips the bank in one cycle**, increments `generation`, and clears the
     new shadow bank's validity mask — or —
   - **refuses**, if the shadow bank contains no complete record (always a host
     bug: usually a forgotten word or a double commit). **No flip.** The old
     parameters stay live, which is the safe outcome. A sticky error bit is set
     and counted in `stat[13][31:16]`.

6. **Confirm.** Re-read `stat[13][15:0]`. `generation` has incremented and now
   identifies which parameter set is live. **"I sent it" is not "it is
   running."** This readback is the audit trail: every emitted order can be tied
   to a generation and every generation to a host-side parameter blob.

   Invariant you can check from the host: `generation[0] == active_bank`, and
   `generation` equals the accepted-commit count. Both are asserted in RTL.

### Other host writes (same window, different regions)

| region | address | data | effect |
| --- | --- | --- | --- |
| `3'b001` SYMSTATE | `addr[7:0]` = symbol | `data[2:0]` = `trade_state_e` | Mirror the per-symbol venue state. Reset value is `TRADE_DISABLED` for every symbol — nothing trades until the host says so. **Advisory**: the authoritative halt/LULD/SSR side-channel goes to `risk_gate`, not here. |
| `3'b010` POSFORCE | `addr[7:0]` = symbol, `addr[8]` = word | word 0: `position[31:0]` (held)<br>word 1: `data[7:0]`=`position[39:32]`, `data[31:16]`=`open_orders` | Host reconciliation. Writing **word 1 applies** the correction atomically, so the fabric never sees a half-written position. Counted in `stat[15]`. |

Any other region is ignored and counted in `stat[14][15:0]`. An unnoticed typo in
the host's address arithmetic means the parameters the desk believes are live are
not — the same failure mode as trading on stale parameters, reached by a
different route. It is never silent.

---

## 5. Counter map — `stat[16]`

Read by `u_telemetry` as `strat_stat`. **All counters saturate at
`32'hFFFF_FFFF` rather than wrapping**, so a host polling at 1 Hz can never
mistake a wrap for "the problem stopped".

| idx | contents | what a nonzero/growing value means |
| --- | --- | --- |
| 0 | book updates presented (`s_top_valid` pulses) | the feed is alive |
| 1 | gate **passes** | the layer is admitting quotes |
| 2 | gate **rejects**, total | `stat[0] == stat[1] + stat[2]` must reconcile |
| 3 | triggers **fired** | a primitive returned an action |
| 4 | order requests **emitted** | what actually reached the risk gate |
| 5 | emits **suppressed** by the output sanity check | ⚠️ a primitive produced something degenerate — investigate, do not tune |
| 6 | gate reject: session not `TRADE_OPEN` | normal outside RTH; suspicious during |
| 7 | gate reject: symbol not `TRADE_OPEN` | halt / pause / auction / closed / never enabled |
| 8 | gate reject: `params_valid == 0` | ⚠️ the host never loaded this symbol in the live generation |
| 9 | gate reject: `strat_enabled == 0` | deliberate |
| 10 | gate reject: book stale (sequence gap) | ⚠️ the feed is gapping |
| 11 | gate reject: book crossed **or** one-sided/zero-priced | ⚠️ crossed books are a book-engine or feed problem |
| 12 | gate reject: thin book (below `min_book_qty`) | usually a parameter that is too tight |
| 13 | `{commit_err_cnt[15:0], generation[15:0]}` | ⚠️ upper half nonzero = a commit was **refused**; the old parameters are still live |
| 14 | `{GATE_UNKNOWN[31:20], last_reject_reason[19:16], bad_addr_writes[15:0]}` | ⚠️ **`[31:20]` and `[15:0]` must be zero** — either means something reached this layer in a state it does not recognise. `[19:16]` is the most recent `gate_reason_e`: "why is this symbol quiet right now" in one poll instead of two |
| 15 | position **force-corrections** applied | ⚠️ nonzero **and growing** = fill feedback is being lost upstream |

The **full** per-reason gate histogram (all `N_GATE_REASONS` entries, including
`GATE_IN_RESET`) exists on `u_gate.reject_cnt`. Only the seven operationally
interesting reasons fit in `stat[16]`; wire the rest in when the register map
grows.

`position_track` additionally exposes `fill_cnt`, `emit_cnt`, `sat_cnt` and
`open_underflow_cnt`; `param_table` exposes `word_wr_cnt`, `field_err_cnt`,
`commit_ok_cnt` and `commit_err_sticky`. These are consumed by the assertions in
`strategy_engine.sv` §7 and are the first place to look when `stat[13]`–`stat[15]`
move.

### Why rejections are counted by reason

"The strategy stopped quoting at 09:47" is not a diagnosis. "12,431 rejects on
`GATE_THIN_BOOK` starting at 09:47" is. A gate whose rejections are not
attributable cannot be debugged in production, and the first question after any
outage — *did the strategy stop firing, or did the gate stop letting it?* — has
completely different causes and completely different fixes depending on the
answer.

---

## 6. The two things most likely to hurt you

### 6.1 Position drift (`position_track.sv`)

**The position in this layer is an estimate.** It is not the position. It drifts
for four reasons, and only the first is unavoidable:

1. **In-flight fills** — a fill that happened at the venue but whose message has
   not crossed the wire. Speed of light. Bounded by `MAX_IN_FLIGHT`.
2. **Missed feedback** — a lost or dropped fill message makes the estimate wrong
   *forever*; a delta accumulator has no self-correcting mechanism. This is the
   dangerous one: permanent and silent.
3. **No ack/cancel visibility** — the port contract from `fpga_top.sv` gives this
   layer `fill_*` and nothing else. `open_orders` is therefore incremented on
   emit and decremented only on a **fill**, which makes it an *upper bound* that
   ratchets upward on every cancel or reject. Conservative in the right
   direction, but it must be re-synced or the symbol eventually goes quiet.
4. **Out-of-band activity** — anything the desk does in the same name through
   another channel is invisible by construction.

Mitigations, all present: the estimate is exposed for host comparison; a
host-writable **force position** input accepts the reconciled truth; and forced
corrections are **counted** in `stat[15]`. One correction at session start is
housekeeping. Ten an hour is an incident — it means the FPGA and the host
disagree repeatedly, which means feedback is being lost upstream.

Backstop: `risk_gate.sv` maintains its own position from the same feed and owns
the real limits.

### 6.2 `is_short` is a Reg SHO matter (`trigger_logic.sv` §6)

`is_short` drives the SSR (Rule 201) price test downstream. Marking a short sale
as long is a **regulatory breach**. Marking a long sale as short costs a fill.
The asymmetry is total, so the implementation errs hard toward "short":

- **Position arithmetic**: `position < qty`, not `position <= 0`. Selling 200
  while long 100 is a 100-share short sale even though the position is positive.
  This is strictly stronger than the literal rule and subsumes it.
- **Open-order uncertainty** (`CONSERVATIVE_SHORT`, default `1`): while any order
  is working in the symbol our estimate is uncertain by at least one clip, so the
  sale is treated as short. Because the open-order count is an *upper* bound
  (§6.1 cause 3), this term is conservative in the correct direction.

`CONSERVATIVE_SHORT = 0` is a **compliance-relevant** parameter change. Do not
flip it without desk sign-off.

Residual gap, stated plainly: a fill that has occurred at the venue but whose
message has not reached us is invisible to both terms. Nothing in fabric can
close that. `risk_gate.sv` owns the authoritative SSR check.

---

## 7. Scope limits (deliberate, not oversights)

- **One request per book event.** `order_req_t` carries a single order.
  `STRAT_PASSIVE_QUOTE` therefore quotes **one side** per event, choosing the
  side that reduces inventory (`position > 0` → offer, else bid); the other side
  is quoted on the next event in the symbol. A true two-sided quoter needs a
  2-beat emit or a wider request struct.
- **`ACT_CANCEL` is never produced.** Cancel-on-book-move needs an own-order
  table keyed by token (`my_orders.sv` in the manual's file plan) so the engine
  knows *which* order to pull. `cancel_token` is held at zero so a stray cancel
  cannot be synthesised from uninitialised bits.
- **Four primitives.** Adding a fifth widens the decision mux from 4:1 to 8:1
  (+1 LUT level, ~0.6 ns) on a path with roughly one LUT level of headroom.
  Budget it before writing it — see `trigger_logic.sv` §7.
- **No cooldown / no order-rate limiter in this layer.** Message-rate control is
  a risk function and lives in `risk_gate.sv` (`RISK_MSG_RATE`).

### If S1 misses timing

`trigger_logic.sv` §7 has the full analysis. In preference order:

1. **Free** — constrain `imbalance_thr` to a power of two. The host writes
   `log2`, both multiplies become constant shifts, the DSP leaves the path
   (~3 ns recovered). Parameter-table change plus one field check. No latency
   change, no rebuild of anything else.
2. **One cycle** — enable the DSP48E2 `MREG`, splitting S1 into S1a (products)
   and S1b (compares + mux). The insertion point is the two `assign bid_x_thr /
   ask_x_thr` statements; nothing else moves. **Cost: the layer becomes 3 cycles
   and breaks the 20-cycle envelope.** To add a cycle you must remove one. Do
   not take this silently.
3. **Last resort** — narrow `IMB_QTY_W` from 24 to 18 bits. Raises the rate at
   which the overflow guard fires (the primitive silently stops firing on deep
   books), so it must be paired with a counter on that condition.

---

## 8. Known inconsistencies with the rest of the tree

Recorded here rather than silently worked around.

1. **`rtl/pkg/sat_arith_pkg.sv` does not exist.** `trading_pkg.sv` provides
   `sat_add64` / `sat_sub64` (unsigned, 64-bit) only, and position arithmetic is
   *signed* and 40-bit. `strategy_pkg.sv` §6 therefore defines `sat_add_pos`,
   `qty_to_pos`, `sat_add_px`, `sat_sub_px`, `sat_inc_open`, `sat_dec_open` and
   `cnt_inc` locally. **When `sat_arith_pkg.sv` lands, move them there verbatim
   and delete the copies here** — do not leave two.

2. **`fpga_top.sv`'s crossed/stale assertions are one cycle too tight to be
   meaningful.** They use `|=>` (`book_top_valid && crossed |=> !order_req_valid`),
   but this layer is *two* cycles deep, so `order_req_valid` at N+1 is always low
   and the property passes vacuously. The versions that actually bite are
   `a_no_order_on_crossed` / `a_no_order_on_stale` in `strategy_engine.sv` §7,
   which use `##2`. **`fpga_top.sv` should be tightened to `##2`.**

3. **`sym_strat_t` (trading_pkg) is narrower than the parameter set sketched in
   `manuals/03-algotrading/05-strategy-taxonomy.md` §5.** The manual lists
   `clip_size`, `max_long`/`max_short`, `px_offset_ticks`, `max_spread_ticks`,
   `min_depth`, `imb_num`/`imb_den`, `cooldown_cycles`, `generation`;
   `sym_strat_t` has `strat_enabled`, `strat_select`, `quote_qty`, `edge_ticks`,
   `min_book_qty`, `fair_value`, `imbalance_thr`. **`trading_pkg.sv` is the
   interface contract and wins** — this layer implements `sym_strat_t` exactly.
   The differences that matter:
   - the manual's `imb_num`/`imb_den` pair becomes a single `imbalance_thr`
     against a *power-of-two* implied denominator (`IMB_SCALE = 256`), which is
     strictly cheaper: it removes one multiply from S1 entirely;
   - position limits (`max_long`/`max_short`) are enforced by `risk_gate.sv`,
     not here, so their absence from `sym_strat_t` is correct;
   - `max_spread_ticks` and `cooldown_cycles` have no home in `sym_strat_t`. If
     they are wanted, **extend `sym_strat_t` in `trading_pkg.sv` first**, then
     add words 6/7 to the record layout in `strategy_pkg.sv` §4.

4. **`manuals/04-system-architecture/04-strategy-engine-on-fpga.md` does not
   exist yet.** Every header in this directory cites it. The commit mechanism
   documented in §4 above is the one `01-tick-to-trade-pipeline.md` jitter row
   J10 forward-references as "§5" of that document; keep the section numbering
   consistent when it is written.

5. **Per-symbol venue state is host-mirrored here, not venue-sourced.**
   `fpga_top.sv` wires `feed_handler`'s `sym_state_*` side-channel to
   `risk_gate` only; `strategy_engine`'s port list has no equivalent input. The
   per-symbol state this layer gates on is written by the host over the config
   window (region `3'b001`) at millisecond cadence, so it can lag a halt.
   `s_top.stale` covers the real-time case and the risk gate is authoritative —
   defence in depth. If a real-time halt gate is wanted *in this layer*, the
   `sym_state_*` side-channel must be added to `strategy_engine`'s port list in
   `fpga_top.sv` first.

---

## 9. Verification status

**Linted only. Not simulated, not synthesised, not placed and routed.** No
WNS/TNS or utilisation numbers exist for this layer, and none are quoted
anywhere in it — every latency and resource figure in these headers is a
**design target** derived from the budget table, not a measurement
(CLAUDE.md §4).

Per CLAUDE.md, before this is reportable as done:

- [x] **Verilator 5.050 `--lint-only -Wall --timing --assert` clean.** Zero
      warnings for every module in this directory, both as part of the
      `strategy_engine` hierarchy and individually as top. Command:

      verilator --lint-only -Wall --timing --assert -sv -Wno-UNUSEDPARAM \
        -y rtl/pkg -y rtl/strategy \
        rtl/pkg/trading_pkg.sv rtl/strategy/strategy_pkg.sv \
        rtl/strategy/param_table.sv rtl/strategy/trade_gate.sv \
        rtl/strategy/trigger_logic.sv rtl/strategy/position_track.sv \
        rtl/strategy/strategy_engine.sv --top-module strategy_engine

      `-Wno-UNUSEDPARAM` is required only because `rtl/pkg/trading_pkg.sv`
      raises 12 of them (`PRICE_SCALE`, `SYM_IDX_W`, `CREDIT_W`, …) — package
      constants a single module will never all reference. Nothing in
      `rtl/strategy/` contributes to that list. The project lint invocation
      should carry the flag for package files rather than have packages
      sprinkle waivers.
- [ ] cocotb testbench per module — **no exceptions on the fast path**
- [ ] Synthesis, then P&R, then quote WNS/TNS and utilisation **verbatim**

Testbenches this layer specifically needs:

| Target | Must prove |
| --- | --- |
| `param_table` | A read straddling a commit **never** returns a mixed record; an incomplete record never sets `params_valid`; a refused commit leaves the old bank live; `generation` tracks accepted commits |
| `trade_gate` | Every reason is individually reachable; the counters reconcile against the evaluation count; `GATE_UNKNOWN` is unreachable with legal inputs |
| `trigger_logic` | Each primitive against a directed book sequence; post-only never crosses; the imbalance cross-multiply matches a Python reference across the full operand range including the overflow guard boundary; `is_short` against a Reg SHO truth table |
| `position_track` | Concurrent emit + fill + force on three different symbols in one cycle; same-symbol emit + fill nets to zero; saturation and underflow counters fire when provoked |
| `strategy_engine` | Fixed 2-cycle latency under back-to-back updates (II=1); `rx_cycle` bit-identical end to end; fail-closed from reset |
