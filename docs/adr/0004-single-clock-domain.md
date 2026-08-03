# ADR 0004 — Single core clock domain for the datapath

> Why the entire tick-to-trade path runs on one clock, where the two crossings that
> remain live, and why every one of them uses a primitive from `rtl/common/` rather than
> four lines of hand-written SystemVerilog. CDC bugs pass simulation, pass timing, pass a
> week of soak, and then corrupt one order in ten million on a hot afternoon.

| Field | Value |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-08-02 |
| **Deciders** | Datapath lead / Risk owner |
| **TASKS.md** | P0.6, P2.10 |
| **Supersedes** | — |
| **Superseded by** | — |

---

## Decision

**The entire tick-to-trade datapath runs on one clock — `core_clk`, 156.25 MHz
(6.400 ns/cycle, `trading_pkg::CORE_CLK_KHZ = 156_250`). Clock-domain crossings exist at
exactly two boundaries — the Ethernet MAC and PCIe — and nowhere else. Every crossing
uses only the sanctioned primitives in [`rtl/common/`](../../rtl/common/README.md);
hand-rolled synchronizers are forbidden.**

Enumerated:

1. **One `core_clk` for feed → book → strategy → risk → gateway.** `u_net_rx`,
   `u_feed`, `u_book`, `u_strategy`, `u_risk_gate`, `u_order_gw`, `u_telemetry` and the
   free-running `cycle_cnt` are all clocked by `core_clk` in
   [`rtl/fpga_top.sv`](../../rtl/fpga_top.sv). This is hard rule 5 of that file's header:
   "One clock domain (core_clk) for the whole datapath. CDC only at the MAC and PCIe
   boundaries."
2. **CDC at the MAC boundary only**, inside
   [`rtl/eth/eth_10g_wrapper.sv`](../../rtl/eth/eth_10g_wrapper.sv), in its `async_fifo`
   instances. The RX side is **explicitly no-backpressure**: there is no `tready`
   anywhere on the RX path — not on `mac_rx`, not on `m_axis` — and the FIFO's `rd_en` is
   unconditional. `fpga_top.sv` hard rule 1 states it: `s_axis_rx_tready` is tied high,
   always. This is [`CLAUDE.md §5`](../../CLAUDE.md) rule 4 realized in structure rather
   than in policy.
3. **CDC at the PCIe boundary only**, inside
   [`rtl/ctrl/host_ctrl.sv`](../../rtl/ctrl/host_ctrl.sv), so that **no `cfg_*` crossing
   is visible at top level**.
4. **One exception, visible in `fpga_top.sv` and named deliberately**: the asynchronous
   external kill input `ext_kill_n`, crossing via `cdc_sync_bit #(.STAGES(3))`.

### Verified against the RTL as it stands today

The brief asked whether claim 3 survives contact with the now-existing `host_ctrl.sv`.
**It does, and more strongly than expected.**

| Claim | Finding |
| --- | --- |
| All CDC lives inside `host_ctrl` | **Confirmed.** `host_ctrl.sv`'s header carries a 16-row **CDC inventory** — "EVERY `pcie_clk` ↔ `core_clk` CROSSING IN THE DESIGN" — with the primitive and bit width for each. Its port comment reads "core-clock side. ALL CDC LIVES INSIDE THIS MODULE." |
| No `cfg_*` crossing visible at top level | **Confirmed.** Every `cfg_*` signal in `fpga_top.sv` is a plain `core_clk` wire declared in the top-level `logic` block and driven by `u_host_ctrl`. There is no synchronizer, FIFO or handshake on any of them at top level. |
| Primitive choice per signal shape | **Confirmed and well-reasoned.** Levels (`cfg_trading_en`, `cfg_kill`) → `cdc_sync_bit(2)`. Single-cycle pulses (`cfg_heartbeat`, `cfg_credit_return`, `cfg_risk_commit`, `cfg_strat_commit`) → `cdc_pulse`, with `csr_regfile` pacing each one with an 8-cycle hold-off because `cdc_pulse` merges pulses closer than ~2 destination periods. Wide infrequent buses → `cdc_handshake`. High-rate audit payload → `async_fifo`. |
| `kill_active` and `kill_src` cross **together** | **Confirmed.** CDC #11 crosses `{kill_active, kill_src}` as one 4-bit payload through **one** `cdc_handshake`. Crossing them separately would be reconvergence: you would momentarily latch "killed" with a stale provenance, and the sticky register you read after an incident would name the wrong cause. [`constraints/cdc.xdc`](../../constraints/cdc.xdc) §3 demands exactly this; the RTL delivers it. |

**One additional crossing exists that neither `CLAUDE.md` nor the brief mentions**, and
it is legitimate: `link_up` crosses from each GT's clock domain into `core_clk` through
`cdc_sync_bit #(.STAGES(3))` inside `eth_10g_wrapper.sv`. It is a single-bit status
level, it uses a sanctioned primitive, and `cdc.xdc` §3's comment block already names
`link_up[*]` in its crossing list. It is part of the MAC boundary, not a fourth domain.

### ⚠️ The frozen-clock hazard, and the mitigation that already exists

`cfg_trading_en` and `cfg_kill` are **levels** crossed by 2-FF synchronizers. If
`pcie_clk` stops — host power loss, `PERST#`, surprise link down, a crashed refclk — the
synchronizers do exactly what they are supposed to do: **hold their last value.** The
card would sit there armed, trading, with no host on the other end.

No amount of correct synchronizer design prevents this. A 2-FF synchronizer faithfully
holds a value whose source has died. `host_ctrl.sv` mitigates it with a free-running
liveness toggle in each direction (CDC #13/#14): if the PCIe-side toggle stops for
`2^PCIE_DEAD_LOG2` core clocks, the **core domain independently** forces `cfg_kill = 1`,
`cfg_trading_en = 0` and stops `cfg_heartbeat`, so `risk_gate`'s own watchdog fires too:

```systemverilog
assign cfg_trading_en = trading_en_q && !core_rst && !pcie_dead_q;
assign cfg_kill       = kill_q       ||  core_rst ||  pcie_dead_q;
```

This is recorded here because it is a *consequence of the CDC decision*: choosing a level
synchronizer for the arm/kill controls is correct, and it creates a failure mode that
only a liveness check outside the crossing can close.

---

## Context

### Why multiple clock domains are the default elsewhere, and wrong here

In most FPGA designs, clock domains are how you buy things: a slow control domain saves
power, a fast domain squeezes throughput out of a narrow block, an IP core comes with its
own clock and you cross into it. The cost — a few cycles of synchronizer latency, some
FIFO BRAM — is invisible against a millisecond-scale requirement.

Here it is not invisible. A CDC on the fast path costs **two things**, and the second is
worse than the first:

1. **Latency.** [`manuals/00-foundations/04-clocking-reset-and-cdc.md`](../../manuals/00-foundations/04-clocking-reset-and-cdc.md)
   §3.3 prices an async FIFO at "**~2–3 destination clock cycles of latency. Budget it.**"
   `rtl/common/README.md` prices the local implementation at ~3 cycles crossing + 1 cycle
   read. At 6.400 ns that is 19.2–25.6 ns per crossing.
2. **Jitter.** The arrival cycle becomes **non-deterministic**. Two plesiochronous clocks
   drift; the same input can land one destination cycle earlier or later depending on
   where the edges happen to be. **A CDC converts fixed latency into a distribution.**

[`CLAUDE.md §5`](../../CLAUDE.md) rule 8 — "Determinism over average speed. Report
p50/p99/p99.9/max, never just the mean" — makes the second cost the decisive one.
`CLAUDE.md §4` says the same thing prescriptively: "Fixed-latency preferred over
variable-latency. Determinism (low jitter) is worth more than a lower mean." A CDC in the
middle of the tick-to-trade path spends the one currency the design is trying to
accumulate.

So the crossings that remain are the ones **physics forces**, not the ones convenience
suggests:

- The **MAC RX clock is recovered from the incoming serial stream** by the GT's CDR. It
  is plesiochronous with our reference — same nominal frequency, up to ±100 ppm different
  actual frequency, per `clocks.xdc` §2. It is not our clock and never will be.
- The **PCIe user clock is 250 MHz**, derived from the host's reference through the hard
  block. Also not ours.

`eth_10g_wrapper.sv` states the consequence bluntly, and it is worth quoting because it
forecloses the obvious "optimization":

> ⚠️ The two async FIFOs are 5 of the ~20 fabric cycles in the whole tick-to-trade
> budget. They are NOT optional: `rx_clk` is the recovered clock and has no defined
> relationship to `core_clk`. The only way to remove them is to run the entire fast path
> on the recovered clock, which breaks the moment the link drops. **Do not.**

### Two boundaries or three?

`CLAUDE.md §2` says "CDC only at MAC/PCIe boundaries" (two). The CDC manual §1 rule 2
says "CDC exists in exactly three places: MAC RX boundary, MAC TX boundary,
PCIe/control boundary" (three). **Both are right at different granularities:** two
boundary *classes*, three crossing *points*, because the MAC boundary is crossed
separately in each direction with an independent clock on each side. This document uses
"two boundaries" and enumerates the crossings explicitly so the count is never the thing
in dispute.

---

## The sanctioned primitive table

[`rtl/common/`](../../rtl/common/README.md) now holds far more than CDC. Enumerated from
disk, thirteen modules plus a README:

### The CDC set — the only primitives permitted to cross a clock boundary

| Signal shape | Primitive | File | Latency (target) | ⚠️ Caveat |
| --- | --- | --- | --- | --- |
| Single bit, slowly-changing **level** (enable, kill, status, `link_up`) | `cdc_sync_bit` | [`rtl/common/cdc_sync_bit.sv`](../../rtl/common/cdc_sync_bit.sv) | `STAGES` dst cycles + up to 1 more: 2 → 12.8 ns, 3 → 19.2 ns @ 156.25 MHz | **One bit only.** Source must be stable ≥ 2 destination periods. Elaboration `$error` if `STAGES < 2` — "a 1-FF chain is not a synchronizer". |
| Single-cycle **pulse / event** | `cdc_pulse` | [`rtl/common/cdc_pulse.sv`](../../rtl/common/cdc_pulse.sv) | ~3 dst cycles | ⚠️ Rate-limited. Pulses closer than ~2 destination periods **merge**. Respect `src_busy`. For `cfg_credit_return`, a merged pulse permanently leaks an in-flight order slot. |
| Wide bus, **infrequent** (config, risk limits, telemetry read-back) | `cdc_handshake` | [`rtl/common/cdc_handshake.sv`](../../rtl/common/cdc_handshake.sv) | ~5 dst cycles, ~10 round trip | Data is held stable by the protocol and **never synchronized**; only `req`/`ack` cross through synchronizers. The data bus is constrained instead. |
| Any **multi-bit data** crossing, especially high-rate | `async_fifo` | [`rtl/common/async_fifo.sv`](../../rtl/common/async_fifo.sv) | ~3 cycles crossing + 1 cycle read | The default. See the note below on gray coding. |
| **Reset** release into a domain | `reset_sync` | [`rtl/common/reset_sync.sv`](../../rtl/common/reset_sync.sv) | 0 to assert, 2+ cycles to release | ⚠️ The **only** asynchronous `always_ff` sensitivity list in the entire project. One instance per clock domain. |
| Clock and reset generation | `clk_rst_gen` | [`rtl/common/clk_rst_gen.sv`](../../rtl/common/clk_rst_gen.sv) | n/a | Top level only, once. MMCM 100 MHz → `core_clk` 156.25 MHz + `pcie_clk` 250 MHz, with a `reset_sync` per domain. |

### The general set — flow control and datapath, **not** CDC

These live in the same directory and are the only sanctioned primitives for their own
jobs, but **none of them may be used to cross a clock boundary**:

| File | What it is | Use for |
| --- | --- | --- |
| [`sync_fifo.sv`](../../rtl/common/sync_fifo.sv) | Single-clock FIFO, high-water + sticky overflow/underflow | Elastic buffering **inside** `core_clk`. ⚠️ Not a CDC — the name is one character away from the one that is. |
| [`skid_buffer.sv`](../../rtl/common/skid_buffer.sv) | Valid/ready register slice, 100 % throughput | Breaking a long `ready` chain. **Never on MAC RX** — there is no `ready` there to break. |
| [`delay_line.sv`](../../rtl/common/delay_line.sv) | SRL-inferring delay; data unreset (maps to SRL32), valid path reset | Matching pipeline depths |
| [`prio_encoder.sv`](../../rtl/common/prio_encoder.sv) | Two-level priority encoder, optional pipeline, scales to N = 1024 | Book "find the new best level"; arbiter cores |
| [`fixed_arbiter.sv`](../../rtl/common/fixed_arbiter.sv) | Fixed-priority with per-requester `starve_cnt` | **The fast path** — determinism over fairness |
| [`rr_arbiter.sv`](../../rtl/common/rr_arbiter.sv) | Round-robin, bounded wait | Fair sharing **off** the fast path |
| [`counter_bank.sv`](../../rtl/common/counter_bank.sv) | N × 48-bit saturating event counters | All telemetry (`CLAUDE.md §5` rule 7) |

**The rule: CDC uses only the CDC set.** A hand-rolled synchronizer, a private FIFO, a
local `always_ff @(posedge clk or posedge rst)`, or a `sync_fifo` pressed into service
across a boundary is a **review failure**, not a style preference.
`rtl/common/README.md` says so, `CLAUDE.md §4` says so ("Never hand-roll a
synchronizer"), and `TASKS.md P2.10` says so ("using **only** the sanctioned primitives
… No hand-rolled synchronizers, ever").

> Note on directory layout: `CLAUDE.md §4` refers to `rtl/common/cdc/`. The library
> realizes those primitives as the `cdc_*.sv` files directly in `rtl/common/`. Same rule,
> flatter tree — `rtl/common/README.md` records the deviation.

### Is `async_fifo.sv` the gray-coded bus-crossing primitive the manual requires?

**Yes — it is genuinely gray-coded**, and it is worth being precise about the one place it
diverges from the manual.

`async_fifo.sv` implements `bin2gray`/`gray2bin` as pure XOR networks and crosses
`wr_ptr_gray_q` / `rd_ptr_gray_q` rather than binary pointers, so a mis-sampled pointer is
off by at most one position — conservatively, never incorrectly. Full detection uses the
gray-domain equivalent of "pointer + depth" (top two gray bits inverted). This is exactly
the structure the CDC manual §3.3 describes.

⚠️ **But the manual §3.3 also says: "Use the vendor's XPM (`xpm_fifo_async`) or a
well-reviewed open implementation. **Do not write your own.** The pointer arithmetic and
full/empty edge cases are subtle and the failure mode is silent corruption."**
`async_fifo.sv` **is** written in-house. Its header acknowledges this directly, states
that it is therefore held to a higher review bar, gives the reason it exists at all (the
`wr_high_water` telemetry the XPM does not provide), and instructs the reader to fall back
to `xpm_fifo_async` if that bar is not met. **This is a knowing, documented deviation from
the manual, not an accident.** It has a constraint consequence — see the `cdc.xdc` finding
below.

---

## ⚠️ Silent-wrongness hazards

This is the section that matters. Everything here produces a system that **works** and is
**wrong**.

### ⚠️ 1. A hand-rolled synchronizer

Two flip-flops in a row is four lines of SystemVerilog. It is also, without
`(* ASYNC_REG = "TRUE" *)`, a placement suggestion the tool is free to ignore — it may put
the two FFs in different slices with 2 ns of routing between them, which eats the settling
time that is the synchronizer's entire purpose. The CDC manual §3.1 is unambiguous:
"**Omitting it is a real bug**, not a style issue."

The failure mode: it works in simulation, works on the bench, works for months, and then
produces one metastable sample under temperature and a corrupted risk limit. **Zero-state
simulation cannot find it** — a simulator has no notion of setup-window violation and will
resolve every sample cleanly, forever. `manuals/00-foundations/04-clocking-reset-and-cdc.md`
§2 states the principle: "Metastability is a *probability*, not a *possibility*. A design
with an inadequate synchronizer works perfectly in the lab and fails in production because
production runs 24/7 for months."

> **Verify:** any specific MTBF figure, metastability-resolution-time constant, or
> setup/hold aperture for the target device. These are silicon characteristics, not design
> parameters. Source them from the AMD UltraScale Architecture documentation and the
> device datasheet for the exact speed grade — and note that MTBF improves *exponentially*
> with each synchronizer stage and with clock period, which is why `STAGES` is a parameter
> and not a constant.

> **Verify:** the behaviour of `(* ASYNC_REG = "TRUE" *)` — that it forces adjacent
> placement and disables register optimization/retiming across the chain — against the
> current Vivado Synthesis Guide (UG901). Vendor attribute semantics change between tool
> versions.

### ⚠️ 2. Crossing a multi-bit bus through per-bit 2-FF synchronizers

**The canonical CDC bug.** Each bit's synchronizer resolves independently. Under a
concurrent source-side change, some bits land on the new value and some on the old, so the
receiver latches a value that **never existed on the source side**.

For a `price_t` or a `qty_t` that is not noise — it is a **valid-looking, entirely
fictional number**, in range, correctly typed, and indistinguishable from a real one. The
CDC manual §7's table row calls the symptom "Occasional impossible values (e.g. a price
that was never quoted)". `constraints/cdc.xdc` makes the risk concrete for this design: the
buses in question carry **risk limits**, and "a torn `max_order_qty` is a `max_order_qty`
that was never configured by anybody."

**Rule: a bus crosses through `async_fifo` or `cdc_handshake`. Never through parallel
`cdc_sync_bit` instances.** `host_ctrl.sv` follows this — every multi-bit crossing in its
inventory (#7, #8, #9, #10, #11, #12, #15, #16) uses a handshake or a FIFO, and the one
that could most plausibly have been fudged, the 3-bit `kill_src` alongside `kill_active`,
crosses as a single 4-bit handshake payload.

### ⚠️ 3. An unconstrained crossing, analyzed as a synchronous path

A crossing that is not named in [`constraints/cdc.xdc`](../../constraints/cdc.xdc) — or is
named by a pattern that matches nothing — gets analyzed against whatever synchronous
requirement the tool derives from the two clock periods. **The tool reports timing met.
Nobody knows the crossing is unconstrained.** `cdc.xdc` states the general form of this in
its own words: "A CDC constraint that matches nothing is worse than no constraint, because
it looks like protection."

**Rule: every crossing has a constraint, and CI checks that it is not analyzed
synchronously.** This is `TASKS.md P2.10`'s exit condition — "Constrain the crossings in
`constraints/cdc.xdc` and verify they are not being analyzed as synchronous paths" — and
`cdc.xdc` §5 names the three checks `scripts/build.tcl` gates on:

| Check | What it catches | Failure condition |
| --- | --- | --- |
| `report_cdc -details` | Missing synchronizers, multi-bit buses through parallel 2-FF chains, reconvergence, combinational logic before a synchronizer | ⚠️ Any CRITICAL severity is a **build failure** |
| `report_clock_interaction` | A crossing that escaped both `cdc.xdc` and `clocks.xdc` | ⚠️ "Timed (unsafe)" or "Partial False Path" |
| `report_exceptions -ignored` | Constraints matching nothing, or overridden by a broader one | An ignored CDC constraint is an unprotected crossing wearing a costume |

STA does **not** check CDC correctness — by definition those paths are excluded from the
synchronous analysis, so a clean timing report says nothing about whether the crossings
are safe. Simulation does not substitute for any of it.

### ⚠️ 4. `set_false_path` on a CDC data bus

`cdc.xdc` devotes a 40-line banner to this and the summary is: `set_false_path` tells the
router "I do not care how long this takes", the router believes you, one bit gets routed
0.5 ns and another 8 ns, and the destination captures some bits from the new value and
some from the old. **Torn data.** It passes RTL simulation (no per-bit route delay model),
it passes STA (you excluded the path yourself), and it appears after a placement change, a
tool upgrade, or a temperature swing.

**The correct construct is always `set_max_delay -datapath_only` *plus* `set_bus_skew`.**
Both, not one: `-datapath_only` bounds each bit individually; `set_bus_skew` bounds them
relative to each other, which is the property that actually prevents tearing.

Note that `set_clock_groups -asynchronous` in `clocks.xdc` §3 **is** a false path at the
clock level. That is correct and safe there — every crossing goes through a sanctioned
primitive and is protocol-safe by construction — but it is emphatically **not** a licence
to skip the per-bus constraints. `cdc.xdc`'s own framing: "Grouping the clocks without
constraining the buses is the same mistake as `set_false_path`, spelled differently."

---

## ⚠️ Do the crossings named in `constraints/cdc.xdc` match the ones in `fpga_top.sv`?

**Partly — and the mismatches are exactly the "looks like protection" failure the file
warns about.** `cdc.xdc` carries its own `TODO(verify)` acknowledging that its cell paths
are assumptions pending final RTL. The RTL is now on disk. Here is the comparison.

### What matches

| `cdc.xdc` requirement | RTL |
| --- | --- |
| §3 ⚠️ "`kill_src[2:0]` MUST cross through a handshake or an async FIFO **alongside** `kill_active`, so the pair stays coherent" | ✅ `host_ctrl.sv` CDC #11: one `cdc_handshake`, 4 bits, both signals in one payload |
| §1 "The data bus is deliberately NOT synchronized … held stable by the protocol" | ✅ `cdc_handshake.sv` implements 4-phase req/ack with the payload held, not synchronized |
| §4 "a gray-coded async FIFO is self-constraining by construction" | ✅ `async_fifo.sv` crosses gray-coded pointers |
| `clocks.xdc` §3 groups `core_clk` / `pcie_clk` / recovered RX / GT refclks asynchronously | ✅ matches the domains actually present in `fpga_top.sv` |

### ⚠️ What does not match

| # | Finding | Consequence |
| --- | --- | --- |
| 1 | **Every `-from`/`-to` filter in `cdc.xdc` §1–§3 is scoped to `*u_host_ctrl/*u_cdc_*` or `*u_host_ctrl/*u_cdc_bit_*`.** The actual `cdc_handshake` instances in `host_ctrl.sv` are named `u_cfg_cdc`, `u_telem_req_cdc`, `u_telem_ret_cdc`, `u_mirror_cdc`, `u_killpair_cdc` (plus `u_drop_cdc` inside `dma_log_ring`). **None of them contains the substring `u_cdc_`.** | The wildcard matches nothing. `report_exceptions -ignored` should catch it; until it is fixed, **no handshake data bus in the design has a `set_max_delay` or a `set_bus_skew`.** |
| 2 | **`u_host_ctrl/u_cdc_risk` does not exist.** Risk-parameter writes do not have their own crossing — they ride the single shared `u_cfg_cdc` handshake (CDC #7, `{target, addr, data}`, 51 bits) along with filter, strategy, template and session writes. | The deliberately tighter 2.0 ns named constraint on "the bus that carries `sym_risk_t`" protects nothing, and there is no separate risk bus to protect. The intent — a named constraint that survives a broken wildcard — is right; the target is wrong. |
| 3 | **§3's single-bit constraint targets `*/u_cdc_bit_*/src_q_reg`.** The actual `cdc_sync_bit` instances are `u_trading_sync`, `u_kill_sync`, `u_pcie_hb_sync`, `u_core_hb_sync`. Worse, **`cdc_sync_bit.sv` has no `src_q_reg` at all** — `src_bit` is an input port feeding `sync_q` directly. | The `-from` object cannot exist by construction. The constraint is unmatchable regardless of the instance names. |
| 4 | **`u_ext_kill_cdc` is instanced at top level in `fpga_top.sv`, outside `u_host_ctrl`.** `cdc.xdc` §3's comment block *names* `ext_kill_sync` in its crossing list, but the constraint's hierarchy filter cannot reach a top-level instance. | The external hardware kill input — a **safety** path — has no flight-time bound. |
| 5 | **`u_md_eth/u_link_up_cdc` and `u_oe_eth/u_link_up_cdc`** (`cdc_sync_bit #(.STAGES(3))`, GT domain → `core_clk`) are likewise outside `u_host_ctrl`. `cdc.xdc` §3 names `link_up[*]` in its comment list but does not reach it. | Unconstrained. `link_up` feeding `~oe_link_up` into `risk_gate.link_down` is a kill-switch source (`KILL_LINK_DOWN`). |
| 6 | **`cdc.xdc` §4 leaves the async FIFOs unconstrained on the grounds that "the vendor XPM ships its own XDC", with a `TODO(verify)`: "If `rtl/common/async_fifo.sv` is a hand-written (non-XPM) implementation, its gray-pointer crossings need `set_max_delay -datapath_only`."** It **is** hand-written. Those pointer constraints are **not** present. | The condition in the TODO is now known to be met; the constraint it calls for is missing. |
| 7 | `cdc.xdc`'s header says `host_ctrl.sv` is "the only handshake CDC in the design". `dma_log_ring.sv` instances `u_drop_cdc`, a `cdc_handshake`. | Harmless in effect — `dma_log_ring` is instanced *inside* `host_ctrl`, so the statement is true hierarchically — but the wildcard in finding 1 does not match `u_drop_cdc` either. |

**None of this is a functional RTL defect.** The primitives are correct, the pairing is
correct, `set_clock_groups` prevents the phantom-violation flood, and the crossings are
protocol-safe. What is missing is the **per-bus skew bound**, which is the thing that
prevents tearing under a placement change months from now — precisely the failure `cdc.xdc`
was written to prevent. **`TASKS.md P2.10` cannot be signed off until
`report_exceptions -ignored` comes back clean on this file.**

---

## Reset policy

Per [`CLAUDE.md §4`](../../CLAUDE.md) and the CDC manual §4:

| Property | Value |
| --- | --- |
| Polarity and timing | **Synchronous, active-high** (`core_rst`). Used as `if (rst)` inside `always_ff @(posedge clk)` and nowhere else. |
| How it is released | Through [`rtl/common/reset_sync.sv`](../../rtl/common/reset_sync.sv) — **assert asynchronously** (works with no clock), **de-assert synchronously**. One instance per clock domain. |
| Where it is applied | **Only where needed.** Datapath registers generally do not need reset; control/state registers do. |

The reason de-assertion is the hard part: an asynchronous reset *releasing* near a clock
edge is the same metastability problem as any other crossing, and different FFs come out of
reset on different cycles — a state machine can start in an illegal state, roughly one
reset in 10⁶.

`reset_sync.sv` is the **only** module in the project with an asynchronous `always_ff`
sensitivity list, and its header says so in capitals. `clk_rst_gen.sv` gives `core_clk`
and `pcie_clk` one instance each; `eth_10g_wrapper.sv` instances
`reset_sync #(.STAGES(3))` for each GT domain and then registers the OR with the GT's own
reset in that domain, rather than feeding a two-term OR into a synchronizer.

### Which registers reset

| Register class | Reset? |
| --- | --- |
| FSM state | Yes |
| `valid` / `ready` / request flags | Yes |
| Counters and sequence numbers | Yes |
| Configuration and risk-limit registers | Yes — to a **safe** value |
| Datapath data registers | **No** |
| Pipeline delay-line data | **No** (`delay_line.sv` leaves data unreset deliberately, so it maps to SRL32) |

### ⚠️ The fail-closed corollary

**Any register whose reset value determines whether we can trade *must* be reset, and must
reset to the state that does not trade.** Configuration registers reset to the *safe*
state, not the useful one. A bitstream reload must never come up armed.

This is already load-bearing in the RTL:

- `trading_pkg::trade_state_e` has `TRADE_DISABLED = 3'd7` and the comment **"RESET
  VALUE"**.
- `sym_risk_t`'s reset value is all-zero — "trading disabled, all limits zero
  (fail-closed)".
- `fpga_top.sv` hard rule 4 is "Reset state = trading disabled, all limits zero", enforced
  by a top-level assertion: `core_rst |-> !cfg_trading_en`.
- `host_ctrl.sv` folds reset directly into the outputs: `cfg_kill` is forced high while
  `core_rst` is asserted, `cfg_trading_en` forced low.

Note the asymmetry that makes this work: the *permissive* signal is ANDed with `!core_rst`
and the *restrictive* signal is ORed with `core_rst`. Reversing either turns a
fail-closed design into a fail-open one, and it would still pass every functional test.

→ Forward link: ADR 0008 / ADR 0009 carry the kill-switch and fail-closed arming policy in
full. This ADR owns only the reset *mechanism*.

---

## Consequences

### Positive

- **Latency is deterministic across the whole fast path.** No synchronizer sits between
  ingress and egress, so p99.9 − p50 is a property of the book update, not of clock phase.
- **The CDC surface is small enough to enumerate and audit.** `host_ctrl.sv`'s 16-row
  inventory *is* the PCIe boundary in full; the MAC boundary is two `async_fifo`s per link
  plus a `link_up` bit. A reviewer can hold the entire crossing set in their head.
- **`report_cdc` findings are actionable rather than a wall of noise.** With few
  crossings, any CRITICAL is a real regression, so gating the build on it is practical.
- Timing analysis is mostly a single-clock problem, which makes WNS/TNS interpretable.
- No cross-domain FIFO can overflow on the fast path, because there is no cross-domain
  FIFO on the fast path.

### Negative

- **The whole datapath is hostage to one Fmax.** Every block must close at 156.25 MHz;
  there is no "put the slow block in a slow domain" escape hatch. The escalation path is
  physical (`05-timing-closure.md` §4 Tier 4), not architectural.
- **The MAC async FIFOs are unavoidable and expensive.** ~5 of the ~20 fabric cycles.
  They cannot be optimized away, only measured.
- **The control plane is slow by construction.** A config write costs ~8 `pcie_clk` + ~6
  `core_clk` cycles; a telemetry read round trip ~25 `pcie_clk` cycles. Fine for the slow
  path, and a reason nothing latency-critical may ever be moved across it.
- **A stopped `pcie_clk` is invisible to a level synchronizer**, which is why the liveness
  toggle and `pcie_dead` logic exist. That is real complexity bought by this decision.
- Single-clock discipline is a **review burden forever**. The cost of a violation is not
  paid at review time; it is paid months later, once, at random.

### Neutral

- The three GT-recovered clocks and the two GT reference clocks exist and are constrained;
  they are simply not *datapath* domains.
- `sync_fifo.sv` and `async_fifo.sv` differ by four characters and by a correctness
  property. Naming, not architecture — but worth a lint rule.

---

## Alternatives considered

| Option | Why rejected | What would make it win |
| --- | --- | --- |
| **Separate RX / core / TX clock domains** | Puts a synchronizer inside the tick-to-trade path. 2–3 cycles each way *and* a non-deterministic arrival cycle — fixed latency converted into jitter, against `CLAUDE.md §5` rule 8. Also triples the CDC surface, and every crossing added is a place for the multi-bit-bus bug to appear. | Never on the fast path. Only if the design were throughput-bound rather than latency-bound. |
| **Faster core clock with a rate-changing FIFO at the MAC** | The FIFO is a CDC with all its costs, and buys nothing: ADR [0003](0003-datapath-width-and-clock.md) shows a shorter cycle does not reduce absolute latency for the same work. It also adds a *second* elastic buffer on top of the one the recovered clock already forces. | Only if we became latency-bound inside our own logic — see ADR 0003's alternatives table. |
| **Asynchronous / GALS partition** (locally synchronous islands, async handshakes between) | Every island boundary is a handshake at ~5 destination cycles, and the total latency becomes a function of how many boundaries a message crosses. Determinism collapses; the design becomes unbudgetable in the sense `CLAUDE.md §4` requires (a per-block budget in ns and cycles). | A fundamentally different problem — very large designs where global clock distribution is the binding constraint. Not this one. |
| **Run the core at the PCIe clock (250 MHz)** | Ties the trading datapath's clock to the *host* — a domain that can stop (PERST#, host power loss, surprise link down) while the market data link is still up and the book still needs maintaining. It would also break the 10GbE-natural 156.25 MHz relationship at the MAC and force a rate-changing FIFO there. It makes the frozen-clock hazard fatal instead of merely serious. | Nothing. The failure mode is a trading system whose datapath stops when the host reboots. |
| **Run the fast path on the recovered RX clock** (deletes the RX async FIFO — 3 cycles / 19.2 ns) | The recovered clock exists only while the link is up. On link loss, CDR unlock, or a fibre pull, the entire datapath — including the **risk gate and the kill switch** — loses its clock. `eth_10g_wrapper.sv` forecloses it in its own header: "breaks the moment the link drops. **Do not.**" And with two market-data links (A and B feeds) there are two recovered clocks and no principled way to pick one. | Nothing. This is the one alternative that is cheaper *and* categorically unsafe. |

---

## Revisit triggers

- **A second Ethernet port whose traffic joins the fast path**, or a venue requiring more
  than the current two market-data lanes plus one order-entry link. Each new link adds a
  recovered clock and an async FIFO; past some count the "enumerate every crossing"
  property that makes this decision auditable stops holding.
- **`report_cdc` reports a CRITICAL that cannot be resolved with the existing primitive
  set.** That means a signal shape exists which the CDC set does not cover, and the right
  response is to extend `rtl/common/` and re-review it — never to fork a private
  synchronizer into a block.
- **`report_clock_interaction` shows a "Timed (unsafe)" pair**, or
  `report_exceptions -ignored` shows a CDC constraint matching nothing. Both mean a
  crossing has escaped the boundary set. **This trigger is live right now** — see the
  `cdc.xdc` findings above.
- **A move to 25GbE / 100GbE.** The MAC interface width and clock change (`CLAUDE.md §2`
  anticipates 32-bit @ 322 MHz for 25G), which changes both the async FIFO geometry and
  the `min(src_period, dst_period)` basis for every CDC budget in `cdc.xdc`.
- **The fast path fails to close at 156.25 MHz after Tier-4 physical work.** A
  single-clock design has no domain-splitting escape hatch, so this trigger resolves into
  ADR [0003](0003-datapath-width-and-clock.md)'s width decision rather than into a second
  clock.
- **The 512-bit audit path or a future DMA path needs to be on the fast path.** Anything
  that pushes a *latency-critical* signal across the PCIe boundary invalidates the
  premise that "nothing latency-critical crosses this boundary".

---

## Links

- **Governing manuals**
  - [`manuals/00-foundations/04-clocking-reset-and-cdc.md`](../../manuals/00-foundations/04-clocking-reset-and-cdc.md) — §1 project clocking policy, §2 metastability, §3 the four sanctioned primitives, §4 reset, §5 constraining CDC in XDC, §6 CDC verification, §7 the common-bugs table
  - [`manuals/00-foundations/05-timing-closure.md`](../../manuals/00-foundations/05-timing-closure.md) — §4 Tier 1 ("check for unintended CDC paths being analyzed as synchronous"), §5 constraints you must write
  - [`manuals/02-networking/01-ethernet-phy-mac.md`](../../manuals/02-networking/01-ethernet-phy-mac.md) — §1 the PHY/MAC stack, §2 the gearbox stall (why everything below the MAC must be valid-qualified)
  - [`manuals/04-system-architecture/06-cpu-fpga-partitioning.md`](../../manuals/04-system-architecture/06-cpu-fpga-partitioning.md) — the PCIe crossing in practice
- **Implementing RTL**
  - [`rtl/fpga_top.sv`](../../rtl/fpga_top.sv) — hard rule 5, `u_ext_kill_cdc`
  - [`rtl/ctrl/host_ctrl.sv`](../../rtl/ctrl/host_ctrl.sv) — the 16-row CDC inventory; every PCIe crossing
  - [`rtl/eth/eth_10g_wrapper.sv`](../../rtl/eth/eth_10g_wrapper.sv) — the MAC boundary async FIFOs, the no-`tready` RX path, per-domain `reset_sync`
  - [`rtl/common/README.md`](../../rtl/common/README.md) — the primitive index and "the three rules that get people"
  - [`rtl/common/cdc_sync_bit.sv`](../../rtl/common/cdc_sync_bit.sv) · [`cdc_pulse.sv`](../../rtl/common/cdc_pulse.sv) · [`cdc_handshake.sv`](../../rtl/common/cdc_handshake.sv) · [`async_fifo.sv`](../../rtl/common/async_fifo.sv) · [`reset_sync.sv`](../../rtl/common/reset_sync.sv) · [`clk_rst_gen.sv`](../../rtl/common/clk_rst_gen.sv)
- **Constraints**
  - [`constraints/clocks.xdc`](../../constraints/clocks.xdc) — primary and generated clocks, asynchronous clock groups
  - [`constraints/cdc.xdc`](../../constraints/cdc.xdc) — the per-bus constraints, and the "never `set_false_path` a CDC bus" banner
- **Related decisions**
  - ADR [0003 — Datapath width and core clock](0003-datapath-width-and-clock.md)
  - ADR index and the `TASKS.md` numbering map: [`README.md`](README.md)
- **Tasks** — [`TASKS.md`](../../TASKS.md) P0.6 (width and clock), P2.10 (MAC/core CDC with sanctioned primitives, constrained and verified non-synchronous)

## Further reading

- [`CLAUDE.md`](../../CLAUDE.md) — §2 clocking default, §4 "One clock domain for the datapath", §5 rules 4 and 8
- [`manuals/01-fpga-design/05-verification-and-simulation.md`](../../manuals/01-fpga-design/05-verification-and-simulation.md) — what simulation cannot catch
- [`manuals/01-fpga-design/03-memory-and-storage.md`](../../manuals/01-fpga-design/03-memory-and-storage.md) — FIFO sizing and implementation
- [`docs/latency-budget.md`](../latency-budget.md) — where the CDC cycles are booked
