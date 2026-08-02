# 06.01 — Build and Release

> **Why this matters here:** a bitstream is the trading system. If you cannot say
> exactly which RTL, which IP versions, which constraints and which tool build
> produced the file currently sitting in the FPGA on the trading floor, you cannot
> investigate a bad fill, you cannot answer a regulator, and you cannot roll back
> with confidence. Build discipline is not bureaucracy here — it is the only thing
> that makes the hardware auditable.

---

## 1. Reproducible builds: the requirement

**Rule: any commit in this repository must rebuild to a functionally identical
bitstream on any machine, at any time, given the pinned toolchain.**

FPGA implementation is a heuristic optimization run. Change the tool version, the
IP version, the number of threads, or the random seed, and placement changes,
routing changes, WNS changes, and — critically — **latency through the fast path
can change** if the tool retimes or replicates differently. That means a "harmless
rebuild" can silently alter your tick-to-trade number.

| Input that must be pinned | How | Failure if unpinned |
| --- | --- | --- |
| Vivado version + patch level | Exact string in `scripts/env.sh`, checked at build start | Different QoR, different latency, unreproducible bugs |
| IP core versions | `.xci` files **checked in**, never auto-upgraded | `upgrade_ip` silently changes MAC/PCS latency |
| Target part + speed grade | Explicit in `scripts/build.tcl`, not inferred | -2 vs -3 changes Fmax ~10–15 % |
| Constraints (XDC) | Checked in under `constraints/`, hashed into the build record | Phantom closure |
| Implementation strategy/directives | Explicit arguments, not GUI defaults | Non-reproducible placement |
| Random seed / directive set | Recorded per run | Cannot reproduce a passing run |
| Thread count | `set_param general.maxThreads N`, fixed | Multi-threaded P&R is not bit-exact across thread counts |
| Host OS / container image | Build inside a pinned container image | Library-level differences |

> **Verify:** Vivado's own statement of what is and is not run-to-run deterministic
> lives in the *Vivado Design Suite User Guide: Implementation* (**UG904**) and the
> *UltraFast Design Methodology Guide* (**UG949**). Confirm the multi-threading
> determinism caveat for your exact version before relying on bit-exactness.

> ⚠️ **Bit-exact is not the same as functionally equivalent.** Two builds from the
> same source with different seeds are both "correct" and will have *different
> latency distributions*. Never compare a measured latency number against a
> different build without saying so.

### Why bit-exactness matters for a regulated system

- A regulator, exchange, or clearing firm asking "what was running at 14:32:07 on
  this date?" needs an answer that is a **hash**, not a description.
- Post-trade analysis of a bad decision must be replayable against *the exact
  logic that made it*.
- SEC Rule 15c3-5 (Market Access Rule) obliges the broker-dealer providing market
  access to maintain risk controls under its own control; being able to prove what
  risk logic was live is part of demonstrating that.
  > **Verify:** SEC Rule 15c3-5 (17 CFR 240.15c3-5) and the SEC's adopting release;
  > exact obligations depend on whether you are the broker-dealer or a sponsored
  > customer. Confirm with compliance.

---

## 2. The build flow (`scripts/build.tcl`)

**Non-project mode only.** Vivado project mode hides state in a `.xpr` and a
`.runs/` directory that is not reviewable in a diff. Everything is a Tcl script
under `scripts/`.

```tcl
# scripts/build.tcl — invoked as:
#   vivado -mode batch -source scripts/build.tcl -tclargs <part> <seed> <outdir>
set part    [lindex $argv 0]
set seed    [lindex $argv 1]
set outdir  [lindex $argv 2]

set_param general.maxThreads 8          ;# pinned for reproducibility

# ── 1. Read sources ────────────────────────────────────────────────
read_verilog -sv [glob rtl/**/*.sv]
read_ip      [glob ip/*/*.xci]           ;# checked-in, NOT upgraded
read_xdc     constraints/clocks.xdc
read_xdc     constraints/io.xdc
read_xdc     constraints/cdc.xdc
read_xdc     constraints/floorplan.xdc

# ── 2. Synthesis ───────────────────────────────────────────────────
synth_design -top top_trading -part $part -directive AreaOptimized_high
write_checkpoint -force $outdir/post_synth.dcp
report_utilization    -file $outdir/rpt/post_synth_util.rpt
report_timing_summary -file $outdir/rpt/post_synth_timing.rpt

# ── 3. Implementation ──────────────────────────────────────────────
opt_design       -directive Explore
place_design     -directive ExtraTimingOpt
phys_opt_design  -directive AggressiveExplore
route_design     -directive Explore
phys_opt_design  -directive AggressiveExplore    ;# post-route

write_checkpoint -force $outdir/post_route.dcp

# ── 4. Sign-off reports ────────────────────────────────────────────
report_timing_summary -warn_on_violation -file $outdir/rpt/post_route_timing.rpt
report_timing -max_paths 50 -nworst 10 -path_type full_clock_expanded \
                                       -file $outdir/rpt/post_route_paths.rpt
report_utilization     -hierarchical   -file $outdir/rpt/post_route_util.rpt
report_design_analysis -complexity -congestion -timing \
                                       -file $outdir/rpt/design_analysis.rpt
report_cdc                             -file $outdir/rpt/cdc.rpt
report_clock_interaction               -file $outdir/rpt/clock_interaction.rpt
report_methodology                     -file $outdir/rpt/methodology.rpt
report_drc                             -file $outdir/rpt/drc.rpt
report_power                           -file $outdir/rpt/power.rpt

# ── 5. Bitstream ───────────────────────────────────────────────────
write_bitstream -force $outdir/top_trading.bit
```

> **Verify:** the available `-directive` values differ by Vivado release and by
> command. Enumerate them for your pinned version from the *Vivado Design Suite Tcl
> Command Reference* (**UG835**) or `place_design -help`, and pin only directives
> that exist there. Whether `place_design` accepts a numeric `-seed` in your
> version must also be checked in UG835 — where it is unavailable, directive
> variation is the seed sweep mechanism (see §6).

### Stage → output map

| Stage | Command | Primary report | What you read it for |
| --- | --- | --- | --- |
| Elaborate/Synth | `synth_design` | `post_synth_util.rpt` | Did anything infer a latch, a DSP you didn't want, or 10× the expected LUTs? |
| Synth timing | — | `post_synth_timing.rpt` | Sanity only. **Never a closure claim.** |
| Logic opt | `opt_design` | (checkpoint) | Constant propagation, cell removal |
| Place | `place_design` | `design_analysis.rpt` | Congestion levels, SLR crossings |
| Physical opt | `phys_opt_design` | (checkpoint) | Replication, retiming near critical paths |
| Route | `route_design` | `post_route_timing.rpt` | **WNS / TNS / WHS / failing endpoints — the closure number** |
| Sign-off | `report_*` | `cdc.rpt`, `methodology.rpt`, `drc.rpt` | Structural correctness, not speed |
| Bitgen | `write_bitstream` | `.bit` + `.ltx` if ILA present | The artifact |

---

## 3. Build artifacts — what is archived, every time

Every build that is kept produces a directory named
`builds/<YYYYMMDD>-<gitsha7>-s<seed>/` containing:

| Artifact | File | Why |
| --- | --- | --- |
| Bitstream | `top_trading.bit` (+ `.mcs` for flash) | The deliverable |
| Post-route checkpoint | `post_route.dcp` | Only way to re-open and investigate later |
| Timing summary | `rpt/post_route_timing.rpt` | WNS/TNS quoted verbatim in the release note |
| Worst paths | `rpt/post_route_paths.rpt` | Post-mortem when a rebuild regresses |
| Utilization | `rpt/post_route_util.rpt` | Headroom trend |
| CDC / methodology / DRC | `rpt/cdc.rpt`, etc. | Sign-off evidence |
| **Build manifest** | `manifest.json` | Everything below |

```json
{
  "git_sha":        "9f1c3ae4d2b6...",
  "git_dirty":      false,
  "tool":           "Vivado 2023.2 (AR patch 000000)",
  "part":           "xcvu9p-flga2104-2-i",
  "seed":           7,
  "directives":     {"place": "ExtraTimingOpt", "route": "Explore"},
  "constraint_sha": "sha256:0af2...",
  "ip_versions":    {"xxv_ethernet": "4.1", "pcie4_uscale_plus": "1.3"},
  "build_id":       "0x20260731_07_9F1C3AE4",
  "wns_ns":         0.113,
  "tns_ns":         0.0,
  "whs_ns":         0.021,
  "sim_latency_ns": {"tick_to_trade_p50": 412, "max": 419},
  "built_by":       "ci-runner-03",
  "built_at_utc":   "2026-07-31T02:14:09Z"
}
```

> ⚠️ **`git_dirty: true` is a hard fail for anything leaving CI.** A bitstream built
> from uncommitted edits cannot be reproduced and must never reach a trading host.

---

## 4. Bitstream versioning: the build-ID register

The fabric must be able to identify itself. Burn a read-only register block into
the design at synthesis time and expose it over PCIe BAR0 at a fixed offset that
**never moves between versions**.

```systemverilog
// rtl/common/build_id.sv — values injected by build.tcl via -generic
module build_id #(
    parameter logic [31:0] GIT_SHA        = 32'hDEAD_BEEF,  // first 4 bytes of SHA
    parameter logic [31:0] BUILD_UNIX_TS  = 32'd0,
    parameter logic [15:0] SEED           = 16'd0,
    parameter logic [31:0] CONSTRAINT_CRC = 32'd0,
    parameter logic [7:0]  MAJOR          = 8'd0,
    parameter logic [7:0]  MINOR          = 8'd0
)(
    input  logic        clk,
    input  logic [3:0]  addr,
    output logic [31:0] rdata
);
    always_comb unique case (addr)
        4'h0: rdata = 32'h4654_5241;          // "FTRA" magic — proves fabric is alive
        4'h1: rdata = {16'd0, MAJOR, MINOR};
        4'h2: rdata = GIT_SHA;
        4'h3: rdata = BUILD_UNIX_TS;
        4'h4: rdata = {16'd0, SEED};
        4'h5: rdata = CONSTRAINT_CRC;
        default: rdata = 32'd0;
    endcase
endmodule
```

Injected from the build script:

```tcl
synth_design -top top_trading -part $part \
    -generic GIT_SHA=32'h[string range $git_sha 0 7] \
    -generic BUILD_UNIX_TS=32'd[clock seconds] \
    -generic SEED=16'd$seed \
    -generic CONSTRAINT_CRC=32'h$xdc_crc
```

**The rule:**

> The host control process reads the build-ID block at startup, compares it against
> the expected value in its own configuration, and **refuses to arm trading** if any
> field mismatches. Arming is a positive action, gated on positive identification.
> "The card came up, probably fine" is not an acceptable state.

This closes the most embarrassing production failure mode in this domain: a stale
or partially-programmed bitstream that appears to work, decodes the feed correctly,
and applies **last quarter's risk limits**.

---

## 5. CI for hardware

Hardware CI is unusual in that the expensive stage takes hours. Split it.

| Trigger | Runs | Wall time | Gates merge? |
| --- | --- | --- | --- |
| **Every push** | Verilator lint (`-Wall`), cocotb unit sims, host-side unit tests, XDC syntax check, `manifest` schema check | < 10 min | **Yes** |
| **Every PR** | Above + full cocotb regression + pcap replay against the golden book model + latency-invariance check in simulation | 20–60 min | **Yes** |
| **Nightly** | Full `synth_design` + implementation on N seeds/directive sets + resource/timing trend upload + long soak sim | hours | No — but a red nightly blocks the next release |
| **Weekly** | Extended soak (multi-hour pcap replay), power report, congestion analysis | many hours | No |
| **Release candidate** | Everything, plus hardware-in-the-loop on the lab card | half a day | **Yes, for release** |

**Merge gate (all must be green):**

1. Verilator lint clean — zero warnings, no waivers except in `waivers/verilator.vlt` with a comment and an owner.
2. All cocotb unit tests pass.
3. pcap replay regression: hardware book output **bit-identical** to the golden software model over the whole corpus.
4. Simulated tick-to-trade latency within the budget declared in the module header, and **unchanged** unless the PR explicitly says it changes.
5. No new CDC violations in `report_cdc` from the last nightly.

⚠️ Do **not** gate merges on full P&R timing closure — the feedback loop is too
long and engineers will start batching changes, which is worse. Gate on lint,
sim, and latency; catch timing in the nightly and treat a nightly WNS regression
as a P1 with a named owner.

### Metrics tracked over time

Push one row per nightly build into a time-series store and plot it. These are the
health signals of the whole project:

| Metric | Source | Alert condition |
| --- | --- | --- |
| WNS (ns), post-route | `post_route_timing.rpt` | Any negative; or drop > 0.1 ns vs 7-day median |
| TNS (ns), failing endpoints | same | Any non-zero |
| WHS (ns) | same | Any negative |
| LUT / FF / BRAM / URAM / DSP % | `post_route_util.rpt` | > 70 % of any resource; congestion level ≥ 5 |
| Simulated tick-to-trade p50 / max (ns) | cocotb regression | Any increase without a PR note |
| Cycle count per pipeline stage | cocotb assertions | Any change |
| Build wall time | CI | 2× baseline (usually means congestion) |
| Seed-sweep pass rate | seed sweep job | < 80 % |

---

## 6. Multi-seed sweeps as the closure criterion

**A design that closes on one seed does not close.** Implementation is a heuristic
search; a single passing run may be luck, and luck does not survive the next RTL
change.

```bash
# scripts/seed_sweep.sh
for s in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
  vivado -mode batch -source scripts/build.tcl \
         -tclargs xcvu9p-flga2104-2-i "$s" "builds/sweep/s$s" &
done
wait
python3 scripts/parse_timing.py builds/sweep/s*/rpt/post_route_timing.rpt \
        --csv builds/sweep/summary.csv
```

**Project closure criterion:**

| Sweep result | Verdict |
| --- | --- |
| 16/16 seeds meet timing, WNS spread < 0.15 ns | Closed. Comfortable. |
| ≥ 14/16 meet timing | Closed, but margin is thin — do not add logic without re-sweeping. |
| 8–13/16 | **Not closed.** You have a marginal design. Fix the architecture, not the seed. |
| < 8/16 | Not closed. Re-architect the failing path. |

Pick the seed for the release build **from the sweep**, record it in the manifest,
and never change it silently. When you do change it, that is a new release, with a
new build ID, and a new latency measurement.

> ⚠️ Reporting the best seed of a sweep as "the" timing result is the most common
> form of dishonest FPGA reporting. Report the distribution. See
> [../00-foundations/05-timing-closure.md](../00-foundations/05-timing-closure.md) §9.

---

## 7. Partial reconfiguration — a future option, not a default

Dynamic Function eXchange (DFX) lets you swap a region of the fabric — e.g. a
strategy block — without reprogramming the whole device or dropping the exchange
sessions.

| Pro | Con |
| --- | --- |
| Swap a strategy without dropping TCP order-entry sessions or resyncing the feed | Reconfigurable partitions are fixed rectangles; the floorplan is now a hard constraint on every future design |
| Much shorter change cycle for strategy logic | Partition pins add latency and routing pressure on the boundary |
| Feed handler / risk / MAC stay untouched and re-verified-by-construction | Full flow complexity: static + N reconfigurable modules, each needing its own timing closure against the same static shell |
| Reduces blast radius of a strategy change | Verification matrix multiplies; a DFX partial bitstream still needs its own sign-off |

**Position for this project:** do not use DFX for v1. Achieve the same operational
flexibility with **parameter tables in BRAM, loaded over PCIe** — thresholds,
enabled symbols, sizes, and risk limits are data, not logic. See
[../04-system-architecture/04-strategy-engine-on-fpga.md](../04-system-architecture/04-strategy-engine-on-fpga.md).
Revisit DFX only when a genuinely new strategy *structure* (not new parameters)
needs to be deployed intraday.

> **Verify:** DFX flow, partition-pin rules and per-family support are documented in
> the *Vivado Design Suite User Guide: Dynamic Function eXchange* (**UG909**). Read
> it before committing to a floorplan.

---

## 8. Release process and sign-off

A bitstream becomes a *release* only after this, and each item has a named signer
recorded in `docs/releases/<version>.md`.

| # | Gate | Evidence |
| --- | --- | --- |
| 1 | Clean tree, tagged commit | `git_dirty: false`, annotated tag |
| 2 | Full regression green | CI run URL |
| 3 | Seed sweep meets §6 criterion | `summary.csv` |
| 4 | Post-route WNS/TNS/WHS quoted verbatim | `post_route_timing.rpt` |
| 5 | `report_cdc` clean or every waiver justified in writing | `cdc.rpt` |
| 6 | `report_drc` and `report_methodology` clean | reports |
| 7 | Utilization headroom documented | `post_route_util.rpt` |
| 8 | Measured (not simulated) tick-to-trade on lab hardware, with distribution | measurement report, N stated |
| 9 | Risk limits and kill-switch verified **on hardware** for this bitstream | test log — see [04-testing-strategy.md](04-testing-strategy.md) |
| 10 | Build ID matches what the host config expects | host startup log |
| 11 | Exchange conformance still valid for any protocol change | cert letter / venue confirmation |
| 12 | Rollback bitstream identified and staged on the host | file path + SHA256 |
| 13 | Change described in terms of *market behaviour*, not just RTL | release note |

⚠️ Items 9 and 12 are the ones people skip under time pressure. They are the two
that determine whether a bad release is an incident or a catastrophe.

---

## 9. Rollback

Rollback must be faster and better rehearsed than deployment.

```
1. Kill switch ON.  Stop new order flow. (Do this first — always.)
2. Confirm flat or acceptably hedged position via the host position view
   AND the clearing/drop-copy view. Reconcile before proceeding.
3. Cancel resting orders explicitly; do not rely on cancel-on-disconnect
   as the primary mechanism. Verify cancels are acked.
4. Log out of order-entry sessions cleanly.
5. Reprogram the FPGA with the previous known-good bitstream (staged locally,
   SHA256 verified before load).
6. Read back the build ID. It MUST equal the previous release's build ID.
7. Reload symbol table, parameters, and risk limits — do not assume the
   previous values survived reconfiguration.
8. Re-verify risk limits by attempting a deliberately over-limit test order
   in the loopback/UAT path and confirming rejection with the expected reason code.
9. Reconnect sessions, resync the feed, verify sequence numbers advance.
10. Arm with a single-symbol canary, minimum size, before full re-enable.
```

**Standing rules:**
- The previous known-good bitstream is on the trading host's local disk at all
  times. Never depend on a network fetch during an incident.
- Rollback is rehearsed in UAT at least once per quarter and after any change to
  the programming path. An untested rollback is not a rollback.
- Rolling back the bitstream without rolling back the host software (or vice
  versa) is a distinct, tested configuration — the compatibility matrix of
  `build_id` × host version lives in the release note.

---

## Further reading

- [02-deployment-and-colocation.md](02-deployment-and-colocation.md) — getting the release onto a machine in Carteret
- [03-monitoring-and-telemetry.md](03-monitoring-and-telemetry.md) — proving the release is behaving once it is live
- [04-testing-strategy.md](04-testing-strategy.md) — what must pass before §8 can be signed
- [../00-foundations/05-timing-closure.md](../00-foundations/05-timing-closure.md) — the WNS/TNS numbers this flow produces
- [../07-reference/03-toolchain-reference.md](../07-reference/03-toolchain-reference.md) — full command and report reference
- [../07-reference/04-checklists.md](../07-reference/04-checklists.md) — the go-live checklist in task-list form
