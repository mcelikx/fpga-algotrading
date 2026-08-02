# 09.10 — Partial Reconfiguration and Field Updates

> **Why this matters here:** the sub-microsecond path in `rtl/fpga_top.sv` is expensive to
> build and fragile to touch — twenty fabric cycles, one SLR, a floorplan that took a seed
> sweep to close. Every mechanism that changes the deployed system trades against that
> asset. A parameter write costs nothing and risks nothing structural; a reconfiguration
> costs the floorplan, the boundary timing, and — if you get it wrong — your knowledge of
> what you own at the venue. This document is the decision procedure for *how* to change a
> trading FPGA that is in production, and the mechanics and governance behind the position
> [06.01](../06-operations/01-build-and-release.md) §7 already took: **DFX is not the
> default; parameterization is.** This is the deep justification for that, not a restatement.

---
## 1. The update taxonomy — every way this system's behaviour can change

Ordered by blast radius. Each rung down is roughly an order of magnitude more expensive to
apply and to unwind. Mechanism names are the `cfg_*` interfaces on `u_host_ctrl` in
`rtl/fpga_top.sv`.

| # | Mechanism | What it can change | Time to apply | Trading stops? | Rollback path | Approval |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | **CSR write** — `cfg_kill`, `cfg_trading_en`, `cfg_heartbeat`, `cfg_credit_return` | One live scalar. Arm/disarm, kill, credit return | µs (one PCIe write + CDC) | Only if that is the intent | Write the prior value | Kill: **none, anyone, always**. Arm: operator, logged |
| 1 | **Double-buffered parameter commit** — `cfg_strat_*`/`cfg_risk_*` + `cfg_*_commit` | Any or all rows of the strategy or risk parameter window, **atomically** ([04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §5) | ~1 ms (DMA + checksum readback + one commit cycle) | **No** | Re-commit the previous set — it is still sitting in the shadow bank | Strategy owner; **risk owner** for `cfg_risk_*` |
| 2 | **Table reload** — `cfg_filter_*` (symbol universe), `cfg_tmpl_*` (OUCH templates), host-precomputed constants | Which symbols decode; the byte layout the encoder splices; reciprocals and scale factors | 1–100 ms | Templates: quiesce the affected symbols. Filter: no | Reload the previous table image | Strategy + ops; a template change is a **protocol** change → conformance |
| 3 | **Session write** — `cfg_session_*` | TCP 5-tuple, OUCH session id, sequence state | ms, but the session is down across it | **Yes**, for that session | Reconnect on the prior session config | Ops |
| 4 | **Host slow-path deploy** (`ttd-params`, reconciler, logger) | What values get computed and written — not what the fabric *can* do | Seconds; process restart | No, if the fabric watchdog tolerance is respected | Previous host version | Engineering; compatibility matrix in the release note |
| 5 | **PR region swap (DFX)** | The logic inside one floorplanned partition, and nothing else | §2.3 — a function of partial-bitstream size and config-port bandwidth, **not instantaneous** | That partition's function is dead throughout; §5 still applies | Load the previous partial bitstream | Full release sign-off + an ADR |
| 6 | **Full bitstream reload** | Everything in the fabric | Seconds to minutes, including PCIe re-enumeration and reloading *every* table and parameter window | **Yes, everything** | Program the prior `.bit` from local disk (§6) | Full release sign-off ([06.01](../06-operations/01-build-and-release.md) §8) |
| 7 | **Card / host replacement** | Everything, plus IO, optics, cross-connect, MAC address | Tens of minutes to hours | **Yes** | The standby machine | Ops + venue notification if the port or MPID changes |

> **RULE: always use the lowest-numbered mechanism that expresses the change.** Reaching for
> rung 6 when rung 1 would do is not conservatism — it is trading a zero-risk atomic commit
> for a full loss of fabric state (§5), a re-arm, and a canary. The ladder is not a
> preference ordering; it is a risk ordering.

⚠️ **Rungs 0–2 change behaviour without changing the build ID.** The device's *identity* is
unchanged while its *configuration* is not. That is why §4 requires a separate, readable
**generation counter** — a build ID alone cannot answer "what was this card doing at 14:32?"

---
## 2. Partial reconfiguration: what it is, and what it actually costs

### 2.1 The mechanics on UltraScale+

Dynamic Function eXchange (DFX) partitions the device into a **static region** and one or
more **reconfigurable partitions** (RPs). At any moment an RP holds one **reconfigurable
module** (RM); loading a *partial* bitstream rewrites only the configuration frames covered
by that RP's floorplan, leaving the static region running.

| Element | What it is | The constraint it creates |
| --- | --- | --- |
| **Static region** | Everything that must survive the swap: PCIe/`u_host_ctrl`, MACs, `u_net_rx`, `u_feed`, `u_risk_gate`, `u_order_gw` | Implemented **once**; then locked. Every RM is routed against that locked result |
| **Reconfigurable partition** | A floorplanned `pblock` — one or more rectangles of columns | Fenced. Resources inside are reserved whether the RM uses them or not |
| **Partition pins** | The physical anchor points where RP signals cross into static | **Fixed at static-design implementation time.** Adding a port to the RP is a full static rebuild |
| **Decoupling** | Logic holding RP outputs at a safe constant while the RP is being written | Costs fabric on or adjacent to the fast path, and must be *proven* safe-by-construction |
| **Configuration port** | ICAP (internal), MCAP (via PCIe), JTAG, or an external flash controller | Determines §2.3's bandwidth term |

```tcl
# Shape only — DFX command set, property names and flow steps are release-specific.
create_pblock pblk_strategy
add_cells_to_pblock pblk_strategy [get_cells u_strategy]
resize_pblock pblk_strategy -add {SLICE_X.. CLOCKREGION_X..}   ;# inside the fast-path SLR
set_property HD.RECONFIGURABLE 1 [get_cells u_strategy]
# 1. implement the static design with RM #1 in place, then freeze it:
lock_design -level routing
# 2. for every other RM: open the locked static checkpoint, implement the RM against it
# 3. pr_verify every (static, RM) pair before any bitgen
```

> **Verify:** the DFX flow steps, partition-pin and floorplan rules, `pr_verify` usage, per-family
> support, and every property name above against the **AMD Vivado Design Suite User Guide:
> Dynamic Function eXchange (UG909)** for the exact pinned Vivado version. This flow changes
> between releases more than any other part of the toolchain.

### 2.2 The costs, honestly

| Cost | Detail | What it does to *this* design |
| --- | --- | --- |
| **Floorplan on the whole design** | The RP is a fenced rectangle; static logic may not be placed inside it | ⚠️ **The fast path is already pinned to one SLR** (`rtl/fpga_top.sv` header). The RP must live in that same SLR, competing for the same columns as the book's URAM and the risk gate. Two hard placement constraints fighting over the one piece of silicon that has to close timing |
| **Boundary timing** | Every RP crossing is anchored at a fixed partition pin and should be registered on both sides | If `u_strategy` is the RP: +1 cycle in, +1 cycle out ≈ **+12.8 ns at 156.25 MHz** — two rows of the budget table, spent on an operational capability rather than on the signal |
| **Decoupling logic** | A mux or AND on every RP output, driven by a "reconfiguring" flag | More logic in the `u_strategy → u_risk_gate` path, i.e. exactly where slack is scarcest ([05.02](../05-optimization/02-fmax-and-timing-optimization.md)) |
| **Build flow complexity** | static impl → lock → N × RM impl → N × `pr_verify` → N × bitgen | An RM that misses timing against the *locked* static cannot be fixed by moving the static. You either shrink the RM or unfreeze everything |
| **Build time** | Multiplies with RM count, on top of the seed sweep ([06.01](../06-operations/01-build-and-release.md) §6) | The nightly gets longer; the seed sweep now has to sweep static *and* RMs |
| **Tool version sensitivity** | The locked static checkpoint binds you to one Vivado version | A tool upgrade invalidates every partial bitstream simultaneously |
| **Verification matrix** | Every (static, RM) pair is its own sign-off article — *plus the transition itself* | The release matrix goes from linear to quadratic. A partial bitstream is not "pre-verified because the static is" |

⚠️ **The belief that DFX means "no downtime" is the expensive misunderstanding.** It means
the *static region* keeps running: the link stays up, the TCP session survives, the feed is
not resynced. If the RP is your strategy, you have **no strategy** for the duration, the
decoupler is feeding the risk gate a safe constant, and every hazard in §5 that concerns
resting orders and strategy-owned state applies unchanged.

### 2.3 Reconfiguration time is a computation, not a constant

```
t_reconfig  ≈  partial_bitstream_bytes / (port_width_bytes × f_config × efficiency)
               +  fixed setup/teardown (decouple, assert, poll DONE, re-couple)

partial_bitstream_bytes  ∝  number of configuration frames covered by the RP pblock
                         ∝  RP AREA (columns × rows) — NOT the logic the RM actually uses
```

Two consequences that decide the floorplan:

1. **A generously-sized RP is permanently slow to swap**, even when the RM inside it is tiny.
   Size the RP to the largest RM you will ever load, and no larger.
2. **The host is often the bottleneck, not the port.** A partial bitstream dribbled over
   BAR writes will not reach the configuration port's rate; it must be DMA'd.

> **Verify:** ICAP/MCAP data width and maximum configuration clock frequency, whether
> bitstream compression or encryption changes the frame count and load time, and how to
> compute partial-bitstream size from a `pblock`, against the **UltraScale Architecture
> Configuration User Guide (UG570)** and **UG909**. ⚠️ **Never quote a millisecond figure for
> reconfiguration from memory — including any figure that appears elsewhere in this
> repository.** Measure it on the actual card, with the actual partial bitstream, and record
> the number in the release note.

### 2.4 The verdict for this project

> **RULE: DFX is not used in this design.** It earns a place only when a change is
> **logic, not parameters**, **must** happen intraday, and can be made while we hold no
> position and no resting orders. Those three answers are interrogated in an ADR under
> `docs/`, and the second one is interrogated hardest.

The interrogation, in order — the first "no" ends it:

| Question | If the answer is "no" | Why it ends the argument |
| --- | --- | --- |
| Is the change **logic** rather than data? | Use rung 1 or 2 | §3. A parameter is seven orders of magnitude cheaper and carries no floorplan debt |
| Must it happen **intraday**? | Full reload at the close, rehearsed runbook | Rung 6 out of hours is cheaper, safer, and already tested. "It would be nice not to wait" is not a requirement |
| Can we be **flat and orderless** across the swap? | §5 forbids it regardless | And if we can be flat, we have already conceded the "no downtime" benefit that motivated DFX |

Consistent with [06.01](../06-operations/01-build-and-release.md) §7: revisit when a genuinely
new strategy *structure* must be deployed intraday. Not before.

---
## 3. Parameterize instead of rebuild — the central argument

**The thesis: a well-parameterized design rarely needs a rebuild, and effort spent making
the design parameterizable pays back far more than the same effort spent making it
reconfigurable.** DFX makes a rebuild cheaper to *deploy*; parameterization makes the
rebuild unnecessary. Only the second one removes the build, the sweep, the regression, the
conformance question, and the loss of fabric state.

### 3.1 What a desk actually asks for, in a real week

| Request | Mechanism | Rung | Note |
| --- | --- | :---: | --- |
| "Add these three symbols today" | `cfg_filter_*` table + parameter rows, loaded disabled, then enabled | 2→1 | Reference data, not logic |
| "Stop quoting XYZ" | Enable bit in the strategy parameter row | 1 | Fail-closed direction; can be expedited |
| "Quote a tick wider on the open" | `px_offset_*` parameter, per time-of-day bucket | 1 | See [08-market-open-and-close-dynamics.md](08-market-open-and-close-dynamics.md) |
| "Halve the quote size in ABC" | `size` parameter | 1 | |
| "Tighten max order qty / max position" | `cfg_risk_*` commit | 1 | **Risk owner**, never bundled |
| "Skew harder on inventory" | `skew` parameter | 1 | |
| "Don't quote when the spread is wider than N ticks" | `min/max_spread` parameter | 1 | A threshold on an existing comparison |
| "Only quote in Continuous state" | Venue-state gate mask parameter | 1 | The condition already exists in fabric |
| "Move the imbalance threshold" | `imb_thresh` parameter | 1 | |
| "Use the join primitive on ABC instead of the quote primitive" | `prim_id` parameter | 1 | [04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §6 |
| "Refit fair value and edge from the model" | Parameter, written automatically every few ms | 1 | The normal operating mode, not a change at all |
| "Set a different TIF the template already carries as a field" | `cfg_tmpl_*` reload | 2 | Wire change ⇒ conformance |
| "Send an order type the OUCH template cannot express" | **Rebuild** | 6 | New encoder structure |
| "Trigger on the 4th book level" | **Rebuild** | 6 | State the fabric does not hold |
| "Multiply two book quantities in the trigger" | **Rebuild** | 6 | New arithmetic form, new DSP, new timing |
| "Widen prices to support a new instrument class" | **Rebuild** | 6 | Type change in `trading_pkg.sv`; system-wide |

Twelve of sixteen are rung 1, two are rung 2, four are rebuilds — and the four rebuilds are
all *structural*, none of them urgent, and all of them batchable into a quarterly release.
**That distribution is the entire argument.** DFX would have accelerated the deployment of
four changes a quarter, at the cost of the floorplan for all of them.

### 3.2 The techniques that move the boundary

| Technique | What it converts from logic into data | Cross-reference |
| --- | --- | --- |
| **Hardened primitives selected by parameter** | "Which algorithm runs on this symbol" — all primitives are instantiated and evaluate in parallel; `prim_id` muxes the winner in the same cycle | [04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §6 |
| **Predicate as a mask over precomputed conditions** | A trigger's *shape*: evaluate a fixed set of K boolean conditions every tick, and let the parameter be an enable mask + polarity + a small fixed sum-of-products. Configuration space is finite and enumerable | §3.3 — and note the anti-pattern boundary |
| **Host-precomputed constants** | Division, scaling, band edges, `1/Q`, tick-size reciprocals. The fabric multiplies by a number the host computed at leisure | [04-fixed-point-arithmetic-in-fabric.md](04-fixed-point-arithmetic-in-fabric.md) |
| **Comparison *thresholds*, never comparison *structures*** | `x > param` is data. Selecting between `>`, `≥`, `∈ band` at runtime is only data if all three comparators are instantiated — which is the primitive mux again | [01.02](../01-fpga-design/02-pipelining-and-parallelism.md) §5 |
| **Table-driven field maps** | The OUCH byte layout: the encoder splices a host-supplied template, so field *values* and some field *choices* are data | [08.05](../08-nasdaq/05-ouch-5.0-order-entry.md) |

### 3.3 ⚠️ The boundary, and the anti-pattern on the other side of it

A parameter cannot change the **shape** of the datapath. Extending
[04.04](../04-system-architecture/04-strategy-engine-on-fpga.md) §6's list with the axes that
matter operationally:

| A parameter can never change | Because |
| --- | --- |
| Pipeline depth, and therefore latency | Every row of the budget table in `rtl/fpga_top.sv` is fixed at elaboration |
| A signal width or a type in `trading_pkg.sv` | It is the cross-block contract; widths are structural |
| The set of message types decoded or encoded | Fixed-offset extraction is the reason decode is one cycle |
| The arithmetic form (adding a multiply, a divide, a second stage) | New cells, new critical path, new closure risk |
| Anything that alters what the risk gate *checks* (as opposed to the values it checks against) | 15c3-5 control surface — §8 |

⚠️ **The anti-pattern is a "fully general" configurable engine.** A parameterized ALU with a
micro-program is a slow CPU in a fast fabric: it costs latency, it cannot be verified because
its configuration space is combinatorial, and nobody has tested the combination that is live
on a volatile Tuesday. The failure is not a crash — it is an order at a price nobody chose,
generated by a configuration nobody reviewed.

> **RULE: parameterize the axes the desk actually moves; rebuild for the rest. Every
> reachable parameter combination is either covered by the regression corpus, or made
> unreachable in hardware.** "Unreachable" means a range and consistency check inside
> `u_host_ctrl` that **refuses the write and increments a counter** — not a validation in the
> host tool, which is one bad script away from being bypassed.

---
## 4. Build identity and the arm check

[06.01](../06-operations/01-build-and-release.md) §4 establishes the build-ID register. This is
what that block must actually contain and how arming consumes it.

### 4.1 What identity must be burned in

| Field | Words | Source | Why it is a *separate* field |
| --- | ---: | --- | --- |
| `MAGIC` = "FTRA" | 1 | Constant | Proves the fabric is alive and BAR0 is mapped where the host thinks |
| `BUILD_ID` | 1 | `build.tcl` | The release handle; matches `rtl/fpga_top.sv`'s parameter |
| `GIT_SHA` (full) | 5 | Full 160-bit SHA | ⚠️ A 32-bit SHA prefix is a *label*, not an identity. Store all of it |
| `BUILD_UNIX_TS` | 1 | `clock seconds` | Orders two builds of the same tree |
| `TOOL_HASH` | 1 | Hash of tool version + patch level | A different Vivado is a different design ([06.01](../06-operations/01-build-and-release.md) §1) |
| `CONSTRAINT_HASH` | 1 | SHA over sorted `constraints/*.xdc` | ⚠️ **Identical RTL with different constraints is a different design** — different placement, different latency distribution. It also catches a build made from an overridden XDC passed on the command line rather than from the tree |
| `SEED_DIRECTIVE` | 1 | Seed + directive-set hash | Different placement ⇒ different measured latency; the measurement is only valid for this value |
| `CAP_FLAGS` | 1 | Synthesis-time parameters | Bit 0: loopback/debug order path present — **must read 0 in production**. Bit 1: DFX static. Bit 2: sim shortcut. This is the lab-bitstream detector |
| `PARAM_GEN` | 1 | **Runtime** counter, +1 on every `cfg_*_commit` | Not build identity — *configuration* identity. §8's audit record is derived from this |
| `RISK_CRC` | 1 | **Runtime** CRC over the **active** risk parameter bank | Proves which limits are live, cheaply and continuously pollable ([08.09](../08-nasdaq/09-risk-controls-and-limits.md) §9) |

```systemverilog
// rtl/ctrl/identity.sv — read-only window inside u_host_ctrl, at a BAR0 offset that
// NEVER moves between releases. Slow path only; zero rows in the latency budget.
module identity #(
    parameter logic [31:0]  BUILD_ID        = 32'hDEAD_0000,
    parameter logic [159:0] GIT_SHA_FULL    = 160'd0,
    parameter logic [31:0]  BUILD_UNIX_TS   = 32'd0,
    parameter logic [31:0]  TOOL_HASH       = 32'd0,
    parameter logic [31:0]  CONSTRAINT_HASH = 32'd0,
    parameter logic [31:0]  SEED_DIRECTIVE  = 32'd0,
    parameter logic [31:0]  CAP_FLAGS       = 32'd0   // bit0 MUST be 0 in production
)(
    input  var logic        clk,
    input  var logic        rst,
    input  var logic        commit_pulse,   // OR of cfg_risk_commit / cfg_strat_commit / table loads
    input  var logic [31:0] risk_bank_crc,  // live CRC of the ACTIVE risk bank
    input  var logic [4:0]  addr,
    output var logic [31:0] rdata
);
    logic [31:0] param_gen_q;
    always_ff @(posedge clk)
        if (rst)               param_gen_q <= 32'd0;   // reload ⇒ generation 0 ⇒ nothing is loaded
        else if (commit_pulse) param_gen_q <= param_gen_q + 32'd1;

    always_comb unique case (addr)
        5'h00: rdata = 32'h4654_5241;                  // "FTRA"
        5'h01: rdata = BUILD_ID;
        5'h02, 5'h03, 5'h04, 5'h05, 5'h06:
               rdata = GIT_SHA_FULL[32*(addr - 5'h02) +: 32];
        5'h07: rdata = BUILD_UNIX_TS;
        5'h08: rdata = TOOL_HASH;
        5'h09: rdata = CONSTRAINT_HASH;
        5'h0A: rdata = SEED_DIRECTIVE;
        5'h0B: rdata = CAP_FLAGS;
        5'h0C: rdata = param_gen_q;                    // runtime: configuration generation
        5'h0D: rdata = risk_bank_crc;                  // runtime: which limits are LIVE
        default: rdata = 32'd0;
    endcase
endmodule : identity
```

### 4.2 The arm protocol

> **RULE: arming is the LAST step, and it is gated on readback of everything.** Identity,
> then tables, then parameters, then risk limits — each read back and compared — and only then
> `cfg_trading_en`. **A mismatch anywhere is a hard refusal, not a warning.** There is no
> `--force`, and the fabric's reset state (trading disabled, limits zero — `rtl/fpga_top.sv`
> hard rule 4) means a refusal is always safe.

```python
# host/ctrl/arm.py — slow path. Every step raises; none of them warn.
def arm(dev, manifest, params, limits):
    ident = dev.read_identity()                       # §4.1 register window
    if ident.magic != b"FTRA":              raise Abort("fabric not responding / BAR unmapped")
    for f in ("build_id","git_sha","tool_hash","constraint_hash","seed_directive"):
        if getattr(ident, f) != manifest[f]:
            raise Abort(f"identity mismatch on {f}: device={getattr(ident,f)!r} "
                        f"approved={manifest[f]!r} — REFUSING TO ARM")
    if ident.cap_flags & CAP_DEBUG_ORDER_PATH:        # a lab bitstream in a production slot
        raise Abort("debug order path present in CAP_FLAGS — unfiltered access risk")

    gen0 = ident.param_gen
    dev.load_symbol_filter(params.filter);  dev.load_templates(params.templates)
    dev.load_strategy(params.strategy);     dev.commit_strategy()
    dev.load_risk(limits);                  dev.commit_risk()

    for addr, expect in params.every_word() :         # ⚠️ EVERY word, not a sample
        if dev.read_param(addr) != expect: raise Abort(f"param readback differs at {addr:#x}")
    if dev.read_risk_crc() != limits.crc():  raise Abort("risk bank CRC differs — limits NOT live")
    for lim in limits.each():                         # 06.02 §8 step 6, executed here
        if not dev.loopback_rejects(lim.over_limit_probe()):
            raise Abort(f"risk limit {lim.name} did not reject an over-limit probe")
    if dev.read_identity().param_gen <= gen0: raise Abort("no commit landed; generation unchanged")

    dev.write_trading_en(1)                           # the ONLY place this is ever written
    audit.record(kind="ARM", identity=ident, param_gen=dev.read_identity().param_gen,
                 risk_crc=dev.read_risk_crc(), operator=whoami(), t=utc_now())
```

⚠️ **The failure this prevents** is not exotic. A card power-cycles and comes back holding
the *previous* bitstream from flash; a lab image with a debug order path sits in a production
slot after a bench session; a reload succeeds but the parameter DMA silently did not, and the
fabric is running last quarter's limits — or, worse, the fail-closed zeros, rejecting
everything for reasons nobody diagnoses for an hour. All three are invisible without an
identity readback, and all three look like a working system.
See [09-failure-modes-and-postmortems.md](09-failure-modes-and-postmortems.md).

---
## 5. ⚠️ The hazard of reconfiguring while positions are open

**This is the section that matters most.** Reconfiguration reinitialises fabric state. The
venue's state is not reinitialised. Every divergence between those two facts is a loss.

### 5.1 What is lost

| State | Lives in | Lost on full reload | Lost on a strategy-RP swap | If you forget it |
| --- | --- | :---: | :---: | --- |
| Order-ID map (65 k entries) | `u_book` | **Yes** | No (static) | Book is unusable until rebuilt from the feed; requires a resync, not a restart |
| Price-level arrays, top-of-book | `u_book` | **Yes** | No | Quoting off an empty book reads as "no liquidity" |
| Own resting-order tracking, tokens | `u_strategy` + `u_order_gw` | **Yes** | **Yes** | ⚠️ **The orders still exist at the venue and you have just forgotten their tokens.** You can no longer cancel what you own |
| Position and notional accumulators | `u_risk_gate` | **Yes** | No | ⚠️ **Accumulator reads zero while the real position is not zero.** Every position and notional limit is now measured from the wrong origin, in the loose direction |
| In-flight credit | `u_order_gw` | **Yes** | No | Credit double-counted (over-send) or permanently stalled (no send) |
| OUCH/SoupBinTCP session + sequence numbers | `u_order_gw` (`cfg_session_*`) | **Yes** | No | ⚠️ **Our sequence resets; the venue's does not.** Login rejected — or accepted into a sequence gap |
| Queue-position estimates (tickets, `qrec`) | `u_strategy` | **Yes** | **Yes** | Silently mis-sized quotes ([01-queue-position-and-fill-probability.md](01-queue-position-and-fill-probability.md) §3.6) |
| Latency histogram and every counter | `u_telemetry` | **Yes** | No | The measurement baseline and the release's evidence are gone. **Snapshot before, always** |
| Symbol filter, templates, parameters | all `cfg_*` windows | **Yes** | RP's own | Fail-closed zeros — safe, but only until an operator reloads from a file and arms without reconciling |

The reset state saves you from the *silent* version of most of these: after a reload trading
is disabled and limits are zero. It does not save you from an operator who reloads
yesterday's parameter file and arms.

### 5.2 The mandatory sequence

```
1. DISABLE new quoting   (strategy enable bits → 0, commit)      ← stop making it worse
2. FLATTEN or explicitly HAND OVER resting orders
      — cancel every resting order and confirm each cancel is ACKED, one by one; or
      — hand the token set to a documented alternate path (second session / manual desk),
        with the handover written down and timestamped
3. CONFIRM ZERO IN-FLIGHT   — no unacked new orders, no unacked cancels; credit fully returned
4. RECONCILE POSITION       — fabric accumulators == host position == drop copy. All three.
                              A break here stops the change; it does not get carried forward
5. DISARM                   — cfg_trading_en → 0, then kill switch ON as belt and braces
6. SNAPSHOT                 — counters, latency histogram, identity, PARAM_GEN, RISK_CRC
7. RECONFIGURE              — partial or full
8. RE-ESTABLISH SESSION     — new/continued OUCH login, sequence state verified against the
                              venue, feed resynced, book rebuilt and compared to software
9. RE-ARM through §4.2 in full — identity, tables, params, risk readback, over-limit probes
10. CANARY                  — §7 rung 5. Never straight back to the full universe
```

> **RULE: no reconfiguration of any kind — partial or full — while any order is resting or in
> flight, without an explicit, logged, human-approved handover.** "The static region keeps
> running so the session survives" is not an exemption; the session surviving is precisely
> what leaves the orders alive while the logic that tracked them is being overwritten.

**Cancel-on-disconnect is a backstop, not a plan.** It is a property of the venue's port
configuration, it fires on *disconnect* — which a DFX swap deliberately avoids — and it says
nothing about the window between the last cancel and the venue acting.

> **Verify:** whether cancel-on-disconnect is enabled on **our** OUCH ports, whether it
> distinguishes a clean logout from an abrupt TCP reset, which order types it covers, and its
> timing, against **Nasdaq's OUCH specification and port configuration documentation**, in
> writing, re-verified after any port change ([03.04](../03-algotrading/04-order-entry-protocols.md) §8,
> [08.05](../08-nasdaq/05-ouch-5.0-order-entry.md)).

---
## 6. A/B slots, the golden image, and rollback

### 6.1 Two flash slots

| Slot | Contents | Loaded when | Trading capable? |
| --- | --- | --- | --- |
| **Golden** | A minimal known-good **non-trading** image | Fallback fires, or explicitly selected | **No — by design** |
| **Application** | The current release bitstream | Normal power-on / warm boot | Yes, after §4.2 |

Fallback is triggered by the configuration logic detecting a problem loading the application
image — a bad CRC/ID, a bad warm-boot address, a watchdog expiry — and reverting to the golden
address.

> **Verify:** the exact multiboot / fallback trigger conditions, the warm-boot start-address
> registers, the configuration watchdog, and how the golden image address is selected, against
> the **UltraScale Architecture Configuration User Guide (UG570)**. It is device- and
> flash-mode-specific, and the failure mode of getting it wrong is a card that will not boot at all.

### 6.2 The golden image must not be able to trade

The tempting choice is "last quarter's trading build". Reject it:

1. **Fallback fires exactly when something is wrong and nobody chose it.** An older *trading*
   image comes up able to emit orders, with an identity the host was not expecting, at the
   moment of maximum operational confusion. The §4.2 arm check will refuse it — but only if
   the host is healthy enough to run.
2. **It is the image-level statement of the fail-closed rule** already in `rtl/fpga_top.sv`
   (reset ⇒ trading disabled, limits zero). Fail-closed at the register level and fail-open at
   the image level is not a coherent safety story.
3. **A golden image ages into a compliance liability.** It is the one image nobody re-verifies:
   last quarter's risk block, last year's protocol, an expired conformance certificate. If it can
   trade, that staleness is a live 15c3-5 exposure.

What the golden image *must* do: bring up PCIe so the host can enumerate and read identity;
report `CAP_FLAGS.GOLDEN`; hold both TX paths quiet; accept a programming command for the
application slot. That is the entire specification, which is also why it is easy to keep verified.

### 6.3 The artifact set that makes rollback possible

| Artifact | Where it lives | Rollback fails without it because |
| --- | --- | --- |
| Previous release `.bit` / `.mcs` | **Trading host local disk**, SHA256 in the manifest | A network fetch during an incident is not a plan |
| Previous `manifest.json` | Same directory | The arm check has nothing to compare identity against; you cannot arm |
| **The parameter set that was live with that bitstream** — all four windows (`filter`, `strat`, `risk`, `tmpl`) | Versioned *with* the manifest | ⚠️ The old bitstream's parameter layout may not be the new one's. Loading the new set into the old fabric writes correct-looking words into the wrong fields |
| Release note: `build_id` × host-version compatibility matrix | `docs/releases/` | Rolling the bitstream back may require rolling the host back too |
| `post_route.dcp` | Build archive | Forensics — not needed for rollback, needed for the postmortem |

> **RULE: a bitstream and its parameter set are ONE versioned artifact.** They are archived
> together, rolled back together, and the arm check verifies both (`build_id` **and**
> `RISK_CRC` + `PARAM_GEN`). Rolling back logic while leaving the newer parameter set live is
> a configuration that has never been tested and never been approved.

### 6.4 The rollback runbook

Trading-state steps 1–4 are [06.01](../06-operations/01-build-and-release.md) §9 and
[06.02](../06-operations/02-deployment-and-colocation.md) §8; this is the slot-and-artifact layer.

```
 1. Kill switch ON. Always first, before diagnosis.        (target: seconds)
 2. Execute §5.2 steps 2–6 in full: flatten, confirm zero in-flight, reconcile
    against drop copy, disarm, snapshot.                    (target: minutes; NOT time-boxed —
                                                             a reconciliation break stops here)
 3. Decide: the on-call engineer declares rollback. A risk-limit change in the
    rollback direction additionally needs the risk owner. Nobody needs authority
    to press the kill switch.
 4. Verify the SHA256 of the staged previous .bit against its manifest BEFORE loading.
 5. Program the application slot. Do not touch the golden slot during an incident.
 6. Re-enumerate PCIe; confirm the expected BDF and link width.
 7. Read identity. It MUST equal the PREVIOUS release's manifest — every field,
    including CONSTRAINT_HASH and CAP_FLAGS. Mismatch ⇒ you have rolled back to
    something you did not intend; stop.
 8. Load the PAIRED parameter set (§6.3), not today's.
 9. Re-arm through §4.2 in full, including the over-limit probes.
10. Re-enter at §7 rung 5 (single-symbol canary), never at full universe.
11. Write the change log entry (§8) with the readback that proves what is now live.
```

Rehearse it quarterly in UAT and after any change to the programming path. **An untested
rollback is not a rollback.**

---
## 7. The staging ladder

[06.02](../06-operations/02-deployment-and-colocation.md) §9 gives the canary. The canary is one
rung of six, and it is not the cheapest place to discover most problems.

| Rung | Stage | What it tests that the rung above **cannot** | Exit criteria | Minimum dwell |
| :---: | --- | --- | --- | --- |
| 1 | **Simulation replay** (cocotb + pcap corpus) | Logic against recorded reality, deterministically and repeatably | Whole corpus bit-identical to the golden software book; simulated latency unchanged unless declared | Every commit |
| 2 | **HIL on the lab card** | Real fabric, real clocks, real MAC/PCIe, the actual configuration load, the arm sequence, the kill switch **on hardware** | [06.01](../06-operations/01-build-and-release.md) §8 items 8–9; measured (not simulated) tick-to-trade with a distribution | One full RC cycle |
| 3 | **Venue test environment / conformance** | The venue's actual protocol validation, port configuration, reject codes, cancel-on-disconnect behaviour | Conformance confirmation for any protocol change | As the venue schedules |
| 4 | **Production, disarmed, observing only** | The real feed at real rates: gap behaviour, full symbol coverage, book agreement against the software model, thermals, PTP, counter behaviour under the open and the close | ≥ 1 full session with **zero** book mismatches and zero unexplained counters | **≥ 1 full session, including an open and a close** |
| 5 | **Production, one symbol, minimum size** | The venue's response to *our* orders: acks, price sliding, real fills, real queue position, drop-copy reconciliation | [06.02](../06-operations/02-deployment-and-colocation.md) §9 canary criteria, plus exact EOD reconciliation | ≥ 1 full session |
| 6 | **Cohort → full universe** | Cross-symbol effects, aggregate message rate, venue throttles, aggregate risk utilisation | No counter anomalies; clean reconciliation across the cohort | 2–3 sessions |

⚠️ **A canary that trades one symbol at minimum size for one hour has tested one hour of
continuous trading in one liquidity regime.** It has not tested the opening cross, the closing
cross, a halt or LULD pause, an SSR trigger, a message-rate burst, or an end-of-day
reconciliation — and those are where the interesting failures live
([08-market-open-and-close-dynamics.md](08-market-open-and-close-dynamics.md),
[08.02](../08-nasdaq/02-sessions-auctions-and-halts.md)). **Rung 4 buys all of them for the price
of one session at zero risk**, because `cfg_trading_en` is 0 and the risk gate is fail-closed.
Skipping rung 4 to "save a day" moves those discoveries to rung 5, where they cost money.

> **RULE: dwell is measured in *sessions*, never in hours, and rung 4 must span at least one
> open and one close.** Any single unexplained event resets the clock at the current rung.

**Promotion criteria — every row must hold before the next rung:**

| Criterion | Evidence | Blocks promotion if |
| --- | --- | --- |
| Book agreement vs. independent software model | Replay diff over the session | **Any** mismatch |
| Risk rejects | `risk_reject_cnt` by reason | Any reject with an unexpected reason code |
| Latency p99.9 / max | On-chip histogram ([06.03](../06-operations/03-monitoring-and-telemetry.md)) | Outside the budget in `rtl/fpga_top.sv` |
| Feed gaps attributable to us | `net_stat` | Any |
| Position reconciliation | Fabric vs. host vs. drop copy at EOD | Any break, of any size |
| New non-zero counters (drops, CRC, credit stalls) | Telemetry diff vs. prior release | Any, until explained |
| Identity and `PARAM_GEN` unchanged during the dwell | Periodic readback | Any unexplained change |
| A named human watching | Roster | Absent — "a canary nobody is watching is just production" |

---
## 8. Change management as a compliance matter, not just engineering

The market access rule requires a broker-dealer to maintain risk-management controls under
its **direct and exclusive control**, applied automatically and pre-trade
([08.06](../08-nasdaq/06-regnms-and-compliance.md) §7). Two consequences follow that are easy to
miss:

1. **A parameter write to `cfg_risk_*` is a change to a regulatory control.** It does not
   become less of one for being a DMA write rather than a bitstream. It needs an approval and
   an audit record on the same footing as an RTL change to `u_risk_gate`.
2. **The bitstream is part of the control**, so "which logic was live" must be answerable as a
   *fact read from the device*, not as a description in a wiki.

Reg SCI's structure — capacity and integrity testing, change management, BC/DR, incident
classification, annual review — is the template examiners carry, whether or not you are an SCI
entity.

> **Verify:** the specific obligations against **17 CFR §240.15c3-5** and **17 CFR
> §242.1000–1007**, plus SEC staff FAQs and any FINRA supervisory rules that apply. ⚠️
> **Applicability depends on the firm's status** — a proprietary trading firm is generally not
> an SCI entity, and a sponsored customer's obligations differ from the sponsoring
> broker-dealer's ([08.06](../08-nasdaq/06-regnms-and-compliance.md) §10,
> [03.06](../03-algotrading/06-risk-and-compliance.md) §1). None of this is legal advice;
> confirm the mapping with compliance before treating any row below as sufficient.

| Change class | Approval | Testing evidence required | Record | Rollback plan required? |
| --- | --- | --- | --- | --- |
| **Kill switch activation** | None — anyone, always | — | Automatic: who, when, `kill_src` | n/a |
| **Risk limit — tighten** | Risk owner (expedited) | Readback diff + `RISK_CRC` | Change log entry with readback | No — but note that *reverting* a tighten is a loosen |
| **Risk limit — loosen** | Risk owner + four-eyes, pre-approved | Over-limit rejection probe **per limit, on this bitstream** | Full entry: old, new, reason, approver, `RISK_CRC` | **Yes** |
| **Strategy parameter within the approved envelope** | Strategy owner (automatic within envelope) | Regression covering the value range; envelope enforced in `u_host_ctrl` (§3.3) | Automatic log + `PARAM_GEN` | Re-commit prior set |
| **`prim_id` change for a symbol** | Strategy owner + risk acknowledgement | Primitive already validated; rung 5 canary | Change log | Re-commit |
| **Symbol universe add/remove** | Strategy + ops | Reference-data check; rung 5 for adds | Change log + filter table CRC | Table reload |
| **OUCH template change** | Protocol owner + venue conformance | Conformance re-validation (rung 3) | Confirmation letter + template CRC | Prior template image |
| **Bitstream, no risk-block diff** | Full [06.01](../06-operations/01-build-and-release.md) §8 sign-off | Full regression + ladder rungs 1–6 | Release note + `manifest.json` + arm-check readback | **Yes** — staged prior bitstream **and** its parameter set |
| **Bitstream, risk-block diff** | As above **+ risk owner + compliance** | As above + the full risk test matrix on hardware ([08.09](../08-nasdaq/09-risk-controls-and-limits.md) §8) | As above + a control-change record | **Yes** |
| **DFX partial bitstream** | As bitstream + the §2.4 ADR | As above + a swap test with the static running + the §5.2 sequence rehearsed | As above + the RP configuration id | **Yes** — prior partial |
| **Host slow-path software** | Engineering | Host regression; compatibility matrix | Deploy log | Prior version |

**The three rules that make the table enforceable:**

> **RULE: a risk-limit change is never bundled with a functional change.** One change, one
> deploy, one rollback story — CLAUDE.md §6, restated as an operational control in
> [08.09](../08-nasdaq/09-risk-controls-and-limits.md) §9.

> **RULE: the change log is immutable and append-only**, and every entry carries: what changed
> (field-level old → new), who proposed, who approved, when applied, **the device readback
> proving it applied** (`PARAM_GEN`, `RISK_CRC`, identity), and when it was reverted, if it was.

> **RULE: the audit record is derived from the device, not from the ticket.** A ticket records
> intent; only a readback records outcome. That is the entire reason `PARAM_GEN` and
> `RISK_CRC` exist in §4.1, and why they are polled several times a day and diffed against the
> risk system's record — the read-back diff is the control that catches every other control's
> failure.

---
## 9. Decision table: "I need to change X"

| I need to… | Mechanism (rung) | Approval | Trading stops? | Rollback |
| --- | --- | --- | --- | --- |
| Stop everything, right now | Kill switch CSR / `ext_kill_n` (0) | None. Anyone. Always | Yes — that is the point | Clear after review, then re-arm via §4.2 |
| Tighten max order qty on one symbol | `cfg_risk_*` commit (1) | Risk owner, expedited | No | Re-commit prior — which is a *loosen*: full process |
| Halve quote size across the universe | `cfg_strat_*` commit (1) | Strategy owner | No | Re-commit prior set |
| Stop quoting one symbol | Enable bit, commit (1) | Strategy owner | No | Re-commit |
| Add three symbols to today's universe | `cfg_filter_*` reload, disabled → enable (2→1) | Strategy + ops | No | Reload prior table |
| Switch a symbol to a different primitive | `prim_id` parameter (1) | Strategy owner + risk ack | No | Re-commit |
| Refit fair value / edge from the model | Parameter, automatic every few ms (1) | Pre-approved envelope | No | The next commit |
| Set a TIF the template already carries | `cfg_tmpl_*` reload (2) | Protocol owner; conformance if the wire changes | Quiesce affected symbols | Prior template image |
| Send an order type the template cannot express | **Rebuild** (6) | Full §8 sign-off | Yes — reload + full §5.2 | Prior bitstream **+ its params** |
| Trigger on a book level the fabric does not hold | **Rebuild** (6) | Full §8 sign-off | Yes | As above |
| Fix a bug in the risk gate | **Rebuild, unbundled** (6) | Full §8 + risk owner + compliance | Yes | As above |
| Change the strategy's *logic* intraday without dropping the session | **DFX** (5) — only if all three §2.4 questions pass; otherwise wait for the close | Full release + ADR | RP function stops; §5.2 applies unchanged | Prior partial + full re-arm |
| Replace a failed card | Card swap (7) | Ops + venue if the port/MPID/MAC changes | Yes | The standby host |

---
## 10. Rules for this project

1. **Use the lowest rung of §1 that expresses the change.** The ladder is a risk ordering, not a preference.
2. **DFX is not used.** It enters only via an ADR that answers §2.4's three questions with logic / intraday / flat-and-orderless — all three.
3. **Never quote a reconfiguration time from memory.** It is `size / bandwidth + overhead`; measure it on the card and record it in the release note.
4. **Parameterize the axes the desk moves; rebuild for the rest.** No general expression evaluator in fabric — that is a slow CPU with an untested configuration space.
5. **Every reachable parameter combination is regression-covered or refused in hardware.** The refusal lives in `u_host_ctrl` and increments a counter.
6. **Identity is burned in and includes the constraint hash, the tool hash and `CAP_FLAGS`.** Identical RTL with different constraints is a different design.
7. **Arming is the last step and is gated on readback of everything.** A mismatch is a hard refusal. There is no `--force`.
8. **No reconfiguration — partial or full — with any order resting or in flight**, absent an explicit, logged, human-approved handover.
9. **Follow §5.2 in order, every time.** Flatten → zero in-flight → reconcile → disarm → snapshot → reconfigure → re-establish → re-arm → canary.
10. **Cancel-on-disconnect is a backstop, never a plan**, and its behaviour on *our* ports is verified in writing.
11. **The golden image cannot trade.** Fail-closed at the image level, exactly as at the register level.
12. **A bitstream and its parameter set are one versioned artifact** — archived, rolled back and verified together.
13. **Dwell is counted in sessions, and rung 4 spans an open and a close.** A one-hour canary has tested one hour.
14. **A risk-limit change is never bundled with a functional change** (CLAUDE.md §6).
15. **The audit record is derived from the device.** `PARAM_GEN` and `RISK_CRC` are polled, diffed against the risk system, and alarmed on any difference.

---
## Further reading

- [../04-system-architecture/04-strategy-engine-on-fpga.md](../04-system-architecture/04-strategy-engine-on-fpga.md) — atomic parameter commits and the primitive-by-parameter design this file's thesis rests on
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — the risk gate whose parameters are a regulated control surface
- [../04-system-architecture/06-cpu-fpga-partitioning.md](../04-system-architecture/06-cpu-fpga-partitioning.md) — why the control plane is slow-path by construction
- [../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md) — reproducible builds, the build-ID register, sign-off, and the trading-state rollback runbook
- [../06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md) — the deployment runbook and the canary this file extends
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) — the counters that supply the promotion evidence in §7
- [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md) — what each rung of the ladder actually runs
- [../05-optimization/02-fmax-and-timing-optimization.md](../05-optimization/02-fmax-and-timing-optimization.md) — the floorplan an RP would have to share
- [../03-algotrading/04-order-entry-protocols.md](../03-algotrading/04-order-entry-protocols.md) — session state, sequence numbers, cancel-on-disconnect
- [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md) — the market access rule and audit-trail obligations
- [../08-nasdaq/06-regnms-and-compliance.md](../08-nasdaq/06-regnms-and-compliance.md) — 15c3-5 §7, Reg SCI §10
- [../08-nasdaq/09-risk-controls-and-limits.md](../08-nasdaq/09-risk-controls-and-limits.md) — operational governance of limits, and the read-back diff
- [../08-nasdaq/05-ouch-5.0-order-entry.md](../08-nasdaq/05-ouch-5.0-order-entry.md) — the templates that make a wire change a table reload
- [../07-reference/04-checklists.md](../07-reference/04-checklists.md) — the deployment and incident checklists in task form
- [09-failure-modes-and-postmortems.md](09-failure-modes-and-postmortems.md) — the stale-bitstream and forgotten-order failures §4 and §5 exist to prevent
- [08-market-open-and-close-dynamics.md](08-market-open-and-close-dynamics.md) — the regimes a one-hour canary never sees
- [01-queue-position-and-fill-probability.md](01-queue-position-and-fill-probability.md) — estimator state lost on reconfiguration
- [04-fixed-point-arithmetic-in-fabric.md](04-fixed-point-arithmetic-in-fabric.md) — host-precomputed constants as a parameterization technique
