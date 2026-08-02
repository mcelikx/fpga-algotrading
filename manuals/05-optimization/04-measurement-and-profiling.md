# 05.04 — Measurement and Profiling

> **Why this matters here:** this is the gate document for the entire optimization
> phase. Intuition about FPGA latency is reliably wrong — the cycle you "know" is in
> the decoder is often in a gearbox, and the 200 ns you cannot find is a cable.
> **No change ships without a before-and-after measurement.** If you cannot measure
> a stage, you cannot optimize it, and the correct first task is building the
> instrument, not writing the RTL.

---

## 1. The golden rule

> **Measure wire-to-wire, externally, with a device that is not the thing under
> test.**

Every clause matters:

| Clause | Why |
| --- | --- |
| **Wire-to-wire** | The venue sees photons, not your fabric. Fabric-only numbers hide the IO stack, which is ~18 % of the budget. |
| **Externally** | The DUT cannot be trusted to time itself. Its clock, its counters, and its notion of "arrival" are all part of what you are testing. |
| **A device that is not the DUT** | If a bug slows the design *and* slows its own timestamping, on-chip numbers look fine. |

On-chip measurement (§5) is enormously valuable — it is the only thing that gives
you *per-stage attribution* — but it is **corroborating evidence, not the headline
number**. The headline number comes from the tap.

---

## 2. The canonical hardware setup

```
                  ┌──────────────────────────────────────────┐
                  │           Market data source             │
                  │  (venue feed, or a pcap replayer at      │
                  │   line rate for controlled tests)        │
                  └──────────────────┬───────────────────────┘
                                     │ 10GbE
                             ┌───────▼────────┐
                             │  PASSIVE TAP   │  optical splitter
                             │  (or L1 switch │  ~0 ns / ~4–5 ns
                             │   with replicate)│
                             └───┬────────┬───┘
                       copy A    │        │   through path
                                 │        │
            ┌────────────────────▼──┐  ┌──▼────────────────────┐
            │  CAPTURE DEVICE       │  │        DUT            │
            │  (timestamping NIC /  │  │   FPGA trading card   │
            │   L1 appliance /      │  │                       │
            │   2nd FPGA / scope)   │  └──┬────────────────────┘
            │                       │     │ order out (OUCH)
            │  ONE CLOCK timestamps │  ┌──▼────────────────────┐
            │  BOTH directions      │◄─┤  PASSIVE TAP          │
            └───────────────────────┘  └──┬────────────────────┘
                                          │ to venue / to a sink
                                          ▼

   latency = T(first bit of outbound order frame)
           − T(first bit of the inbound frame that triggered it)
   ...both timestamped by the SAME capture device, on the SAME clock.
```

**Non-negotiable properties of this setup:**

1. **One clock timestamps both directions.** The moment two devices timestamp the
   two ends, you have added a clock-sync error term larger than the thing you are
   measuring. Prefer a single capture device with two ports over PTP-synced pairs.
2. **Matched fibre lengths from each tap to the capture device.** 1 m of fibre is
   ~4.9 ns of systematic error. Either match them physically or measure the
   difference once and subtract it, in writing, in the report.
3. **The tap is passive or layer-1.** A managed switch in the measurement path adds
   its own variable latency to your measurement.
4. **The DUT runs the production bitstream.** No ILA, no debug hub, no different
   build config. See [03-resource-power-optimization.md](03-resource-power-optimization.md) §6.

### 2.1 Correlating trigger to order

Timestamps alone give you two streams; you need to pair the *specific* inbound
message with the *specific* outbound order.

| Method | How | Notes |
| --- | --- | --- |
| **Echo the trigger identity** | Put the ITCH tracking/match number, or a fabric-generated event ID, into an unused/echo field of the outbound message (e.g. the OUCH client order token) | **Preferred.** Exact pairing, works under load, works in production. |
| Single-shot | Inject one trigger, wait, inject the next | Trivially correct, useless for distributions and useless under load |
| Nearest-preceding | Pair each order with the last inbound message before it | ⚠️ Wrong as soon as two triggers are in flight. Do not use for p99. |

> **Design requirement:** the order token must carry enough of the trigger's
> identity to pair them offline. Design this in from the start — retrofitting it
> means changing the OUCH message layout, which means venue conformance retesting.

---

## 3. Capture options

| Option | Timestamp resolution (est.) | Accuracy concern | Effort | Runs in production? |
| --- | --- | --- | --- | --- |
| **Timestamping NIC** (hardware-timestamped capture card) | ~1–10 ns | Timestamp point is usually after the PHY — a fixed offset you must characterise | Low | Yes |
| **L1 switch / capture appliance** with per-packet timestamping | ~0.5–2.5 ns | Best-in-class; also adds a known ~4–5 ns to the through path | Low (if you own one) | Yes |
| **Second FPGA as an instrument** | 1 core cycle (6.4 ns) natively; ~1 UI (≈97 ps at 10.3125 Gbaud) if you timestamp in the GT | You build and validate it yourself; it is now a thing that can be wrong | High | Yes |
| **Oscilloscope on the SFP electrical lanes** | sub-ns to ps | Highest resolution, hardest to use; you are decoding 64b/66b by eye or with a serial-decode option | Very high | No |
| **Software pcap on a normal NIC** | µs, and unstable | ⚠️ **Useless here.** Kernel timestamping jitter exceeds the entire budget. | Low | No |
| Simulation | exact, and fictional | See §7 | — | No |

> **Verify:** every figure above is an **estimate of a product class**, not a spec.
> Take resolution, timestamp accuracy, and the *timestamping reference point* from
> the vendor's datasheet for your exact device, then **characterise it on your
> hardware** with a known-length loopback (§4).

**Recommended starting point for this project:** an L1 device or timestamping
capture card with two ports, one clock, matched fibres. A second FPGA is worth
building only once you need per-message correlation at line rate for long soaks —
and it is a real project, not an afternoon.

---

## 4. Calibrate the instrument before you trust it

Do this once, then after every change to the measurement rig.

| Step | Procedure | Expected result |
| --- | --- | --- |
| 1. Zero the rig | Loop the capture device's two ports to each other with the same fibres used in the real setup | Measured delta = the known fibre + device latency. Record it as the rig offset. |
| 2. Known-length check | Insert a precisely known extra fibre length (e.g. 10 m) | Delta increases by ~49 ns. If not, your fibre length or index assumption is wrong. |
| 3. Fibre asymmetry | Swap the two tap-to-capture fibres | Delta should change by 2× the length mismatch. Should be ~0. |
| 4. Loopback DUT | Configure the DUT to reflect frames at the MAC with a known internal cycle count | Measured ≈ rig offset + IO stack + known cycles. This isolates the IO stack latency. |
| 5. Repeatability | Repeat step 4, N ≥ 10⁵ | Spread tells you the instrument's own noise floor. **Any effect smaller than this floor is not measurable.** |

> ⚠️ **Report the noise floor with every A/B result.** A claimed 3 ns improvement
> from a rig with a 12 ns noise floor is not a result.

---

## 5. On-chip measurement — the highest-value instrumentation in the system

The tap tells you the total. It cannot tell you *which stage* grew. On-chip
timestamping gives you per-stage attribution at full line rate, in production,
forever, for a few hundred LUTs and a couple of BRAMs. **Build this before you
optimize anything.**

### 5.1 Architecture

```
                free-running cycle counter (core_clk, 32b, never reset)
                        │
   MAC RX SOF ──────────┼──► capture ts_in ──┐
                        │                     │  ts_in travels WITH the message
   ┌────────────────────┴─────────────────────┼───────────────────────────┐
   │  deframe → decode → lookup → book → strategy → risk → encode         │
   │      │        │        │        │        │       │       │           │
   │      └────────┴────────┴────────┴────────┴───────┴───────┘           │
   │        each stage exit pulses {stage_id, now - ts_in}                │
   └──────────────────────────────┬───────────────────────────────────────┘
                                  │
   MAC TX SOF ────────────────────┴──► ts_out = now;  delta = ts_out - ts_in
                                  │
                    ┌─────────────▼──────────────┐
                    │  lat_hist × (1 per stage   │  bucketed counters
                    │   + 1 end-to-end)          │  + min/max/sum/N
                    └─────────────┬──────────────┘
                                  │  BAR-mapped, snapshot-coherent
                                  ▼   read by the host, no fast-path impact
```

Key properties:

- **The timestamp travels with the message**, in the pipeline payload, not in a
  side FIFO. A side FIFO reorders under any variable-latency stage and silently
  mis-attributes.
- **The counter is free-running and never reset.** 32 bits at 156.25 MHz wraps
  every ~27.5 s; deltas are correct across wrap because unsigned subtraction wraps
  the same way. Never compare absolute values, only deltas.
- **Deltas are in cycles.** Convert to ns on the host. Fabric does no division.
- **Everything is off the critical path.** The histogram consumes a valid+delta
  pulse; it never backpressures and never gates the datapath.

### 5.2 RTL sketch — bucketed latency histogram

```systemverilog
// ─────────────────────────────────────────────────────────────────────
//  lat_hist — fabric latency histogram
//  Owner   : instrumentation
//  Latency : 0 cycles on the datapath (observer only, never backpressures)
//  Area    : ~N_BUCKET*CNT_W FFs + adders. 64x32 => ~2k FF, ~0.2 % of an SLR.
//  Notes   : deltas are in core-clock cycles; host converts to ns.
// ─────────────────────────────────────────────────────────────────────
module lat_hist #(
  parameter int unsigned N_BUCKET = 64,     // power of two
  parameter int unsigned DELTA_W  = 24,     // 24b @156.25MHz = 107 ms span
  parameter int unsigned CNT_W    = 32,
  parameter bit          LOG_MODE = 1'b0    // 0 = linear buckets, 1 = log2
)(
  input  logic                          clk,
  input  logic                          rst,

  // ── observer input: one sample per completed transaction ──────────
  input  logic                          s_valid,
  input  logic [DELTA_W-1:0]            s_delta,   // cycles

  // ── linear-mode configuration (ignored when LOG_MODE) ────────────
  input  logic [DELTA_W-1:0]            cfg_base,  // lower edge of bucket 0
  input  logic [4:0]                    cfg_shift, // cycles/bucket = 2**shift

  // ── readout (BAR-mapped; cross to the slow domain outside) ───────
  input  logic                          rd_snap,   // pulse: freeze shadow
  input  logic [$clog2(N_BUCKET)-1:0]   rd_addr,
  output logic [CNT_W-1:0]              rd_count,
  output logic [DELTA_W-1:0]            rd_min,
  output logic [DELTA_W-1:0]            rd_max,
  output logic [CNT_W+DELTA_W-1:0]      rd_sum,    // exact mean = sum / n
  output logic [CNT_W-1:0]              rd_n,
  output logic [CNT_W-1:0]              rd_over    // samples above the top bucket
);
  localparam int IDX_W = $clog2(N_BUCKET);

  // ── bucket index ──────────────────────────────────────────────────
  logic [DELTA_W-1:0] rel;
  logic [DELTA_W-1:0] lin_idx;
  logic [IDX_W-1:0]   log_idx;
  logic [IDX_W-1:0]   idx_d;
  logic               over_d;

  always_comb begin
    rel     = (s_delta > cfg_base) ? (s_delta - cfg_base) : '0;
    lin_idx = rel >> cfg_shift;

    // priority encoder: position of the most significant set bit
    log_idx = '0;
    for (int i = 0; i < DELTA_W; i++)
      if (s_delta[i]) log_idx = (i >= N_BUCKET) ? IDX_W'(N_BUCKET-1) : IDX_W'(i);

    if (LOG_MODE) begin
      idx_d  = log_idx;
      over_d = 1'b0;                                   // log mode cannot overflow
    end else if (lin_idx >= DELTA_W'(N_BUCKET)) begin
      idx_d  = IDX_W'(N_BUCKET-1);                     // saturate into the top bucket
      over_d = 1'b1;                                   // ...and count it separately
    end else begin
      idx_d  = lin_idx[IDX_W-1:0];
      over_d = 1'b0;
    end
  end

  // ── one pipeline stage so the encoder is not in the count path ────
  logic                   v_q, over_q;
  logic [IDX_W-1:0]       idx_q;
  logic [DELTA_W-1:0]     dly_q;
  always_ff @(posedge clk) begin
    v_q    <= s_valid;
    idx_q  <= idx_d;
    over_q <= over_d;
    dly_q  <= s_delta;
  end

  // ── counters. Registers, not RAM: II=1 with no read-modify-write
  //    hazard on back-to-back samples in the same bucket. ────────────
  logic [CNT_W-1:0]              bucket_q [N_BUCKET];
  logic [DELTA_W-1:0]            min_q, max_q;
  logic [CNT_W+DELTA_W-1:0]      sum_q;
  logic [CNT_W-1:0]              n_q, over_cnt_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < N_BUCKET; i++) bucket_q[i] <= '0;
      min_q <= '1;  max_q <= '0;  sum_q <= '0;  n_q <= '0;  over_cnt_q <= '0;
    end else if (v_q) begin
      bucket_q[idx_q] <= bucket_q[idx_q] + 1'b1;       // saturating in production
      if (dly_q < min_q) min_q <= dly_q;
      if (dly_q > max_q) max_q <= dly_q;
      sum_q      <= sum_q + dly_q;
      n_q        <= n_q + 1'b1;
      over_cnt_q <= over_cnt_q + CNT_W'(over_q);
    end
  end

  // ── snapshot shadow so the host reads a coherent set ──────────────
  logic [CNT_W-1:0]         shadow_q [N_BUCKET];
  logic [DELTA_W-1:0]       s_min_q, s_max_q;
  logic [CNT_W+DELTA_W-1:0] s_sum_q;
  logic [CNT_W-1:0]         s_n_q, s_over_q;

  always_ff @(posedge clk) if (rd_snap) begin
    for (int i = 0; i < N_BUCKET; i++) shadow_q[i] <= bucket_q[i];
    s_min_q <= min_q; s_max_q <= max_q; s_sum_q <= sum_q;
    s_n_q   <= n_q;   s_over_q <= over_cnt_q;
  end

  assign {rd_count, rd_min, rd_max, rd_sum, rd_n, rd_over} =
         {shadow_q[rd_addr], s_min_q, s_max_q, s_sum_q, s_n_q, s_over_q};
endmodule
```

### 5.3 How to configure the buckets

| Mode | Use for | Configuration |
| --- | --- | --- |
| **Linear**, 1 cycle/bucket (`cfg_shift = 0`) | Per-stage histograms, where the whole distribution is 1–8 cycles | `cfg_base = 0`, 64 buckets covers 0–63 cycles |
| **Linear**, 1 cycle/bucket, offset base | End-to-end fabric latency, tight around the expected value | `cfg_base = expected − 8`, so resolution lands where the distribution is |
| **Log2** | Anything with a long tail you don't want to lose: TX-occupancy waits, A/B skew, gap-recovery | Coarse at the top, fine at the bottom, cannot overflow |

Run **both**: a linear histogram sized to the body of the distribution *and* a log2
histogram to catch the tail. The `rd_over` counter exists so that a linear histogram
can never lie about its tail — if `rd_over` is non-zero, your p99.9 is off the top
of the chart and the number you computed is a lower bound.

> ⚠️ **A histogram that saturates its top bucket silently reports a max that isn't
> the max.** Always read and report `rd_over` and `rd_max` alongside the buckets.

### 5.4 Percentiles from buckets

The host computes p50/p99/p99.9 by cumulative summation over buckets. Two honesty
rules:

- **A percentile from a bucketed histogram has bucket-width uncertainty.** With
  1-cycle buckets that's ±6.4 ns; say so.
- **`rd_max` is exact** (it's a register, not a bucket). Report it as exact.

---

## 6. ILA / ChipScope — a debugger, not a stopwatch

| ILA is good for | ILA is not for |
| --- | --- |
| "Is this state machine reaching state X?" | Latency measurement |
| Capturing the handshake around a rare stall | Anything in a production bitstream |
| Correlating a counter increment with a bus transaction | Distributions (buffers are tiny relative to N) |
| Finding the message that caused a wedge | Anything you intend to trust to ±6.4 ns |

Why it is not a measurement tool:

1. **It perturbs the design.** Probe nets route across the fabric, consume BRAM,
   change placement, and change routing — which changes the thing you're measuring.
2. **Its capture depth is a rounding error.** A 4096-sample buffer at 156.25 MHz is
   26 µs. Your p99.9 needs 10⁶+ samples.
3. **It is absent from the bitstream you ship**, so anything it told you was about
   a different design.

> ⚠️ **Never quote a latency figure obtained from an ILA capture.** Use the ILA to
> understand *why* the histogram has a bump; use the histogram for the number.

---

## 7. Measurement errors that produce confident wrong answers

| ⚠️ Error | Why it's wrong | Fix |
| --- | --- | --- |
| **Reporting only the mean** | The mean hides the tail entirely. Two designs with identical means can differ by 400 ns at p99.9. | Always p50/p99/p99.9/max |
| **Calling a simulation "measured"** | Simulation has no PMA, no gearbox, no elastic buffer, no routing delay, no thermal, no contention with real traffic. It is an *architectural* cycle count. | Label every number `simulated` or `measured`. They are not comparable. |
| **Measuring with an idle feed** | Latency under load is the only latency that matters. An idle system has no arbitration, no packet packing, no TX occupancy, no book contention. | Replay a real market-open pcap at line rate (§8) |
| **Test packets take a different code path** | A hand-crafted trigger packet may be message 1 of 1 in the datagram, hit an uncontended bank, and find the TX idle. Real ones don't. | Trigger from real captured traffic; verify the code path with per-stage counters |
| **Clock-domain skew between the two timestamps** | Two capture devices, or a fabric timestamp compared against an external one, mixes two clocks. Error can exceed the measured quantity. | One device, one clock. If impossible, characterise and report the sync error. |
| **Unmatched tap fibres** | 1 m = 4.9 ns of pure systematic bias | Match physically, or measure and subtract (§4 step 3) |
| **Measuring the debug bitstream** | Different placement, different routing, different latency | Measure the production bitstream |
| **Nearest-preceding pairing under load** | Mis-pairs whenever two triggers overlap; corrupts exactly the tail you care about | Echo the trigger ID in the order (§2.1) |
| **Discarding outliers** | The outliers *are* the risk | Report max. If you truncate, state what and why. |
| **Comparing across tool versions / builds** | Placement noise alone moves latency-relevant routing | Same tool version, and compare across a directive sweep, not one build |
| **Reading the histogram without snapshotting** | Buckets read at different times don't sum to N | Use `rd_snap`; check the bucket sum equals `rd_n` |

---

## 8. Load testing: replay a real market open

An optimization validated on synthetic traffic is not validated.

| Property of the replay | Requirement |
| --- | --- |
| Source | Real captured pcap from the venue, ideally **09:29:30–09:31:00 ET** on a volatile day |
| Rate | **Line rate, original inter-packet gaps preserved**, and a second run with gaps compressed to worst case |
| Duration | Long enough for N ≥ 10⁶ trigger events at p99.9 resolution |
| Both feeds | A and B replayed with realistic skew, including a deliberate gap/recovery scenario |
| Determinism | Byte-identical replay every run, so A/B comparisons are paired |

Run at least these load profiles and report each separately:

| Profile | What it exposes |
| --- | --- |
| **Idle** (single trigger, quiet wire) | The floor. The best number you will ever quote. |
| **Market open replay, original timing** | The realistic distribution |
| **Market open replay, gaps compressed** | Packet packing (message N-of-M), book contention |
| **Sustained line rate, minimum-size frames** | RX path II=1 discipline, drop counters |
| **Burst: max-size frames interleaved with triggers** | TX occupancy jitter (the T1 budget row) |
| **A/B gap + recovery during the burst** | The worst tail in the system |

> ⚠️ **A design that meets its budget on the idle profile and blows it on the
> compressed-open profile has not met its budget.** The published number is the
> loaded one.

---

## 9. Reporting standard for this project

Every latency claim, in every PR, report, and message, carries all of:

```
  metric      : wire-to-wire, first-bit-in → first-bit-out
  p50         : 612 ns
  p99         : 631 ns
  p99.9       : 678 ns
  max         : 741 ns
  N           : 4,132,880 trigger events
  load        : market-open replay, 2026-06-02, original inter-packet timing
  source      : MEASURED  (tap + L1 timestamping appliance, rig offset 118 ns subtracted)
  noise floor : 2.1 ns (rig repeatability, N=1e5)
  build       : bitstream a91f3c7, Vivado 2023.2, impl directive Explore/AggressiveExplore
  conditions  : Tj 62 °C, production bitstream, no debug cores
```

Rules:

1. **Never a bare number.** "We're at 600 ns" is not a report.
2. **`MEASURED` or `SIMULATED`**, in capitals, always.
3. **State N and load.** A percentile without N is decoration.
4. **State the build.** Latency is a property of a bitstream, not a repo.
5. **State the rig offset and noise floor** for measured numbers.

---

## 10. A/B comparison methodology

Changing one thing and re-measuring is the whole optimization loop. Doing it
rigorously:

| Step | Requirement |
| --- | --- |
| 1 | **Change exactly one thing.** Two changes give you one uninterpretable result. |
| 2 | **Same replay file, byte-identical, same order.** Paired samples, not independent ones. |
| 3 | **Build both variants across the same directive sweep** (≥ 8 runs each). Implementation noise moves latency-relevant routing; a single build of each is comparing two random samples. |
| 4 | **Compare distributions, not means.** Plot both histograms. |
| 5 | **Use a nonparametric test** on the paired per-event deltas (Wilcoxon signed-rank for paired, Mann-Whitney U otherwise). Latency distributions are heavily right-skewed; t-tests assume otherwise. |
| 6 | **Require an effect-size threshold, not just a p-value.** |
| 7 | **Check the tail separately.** A change can improve p50 and worsen p99.9 — which is a regression here. Bootstrap a confidence interval on p99.9 (percentiles have no simple parametric CI). |

> ⚠️ **With N = 10⁶, everything is statistically significant.** A 0.3 ns
> improvement will have p < 10⁻¹⁵ and mean nothing. **Project rule: an accepted
> improvement must be ≥ 1 core cycle (6.4 ns) at p50 *and* not worse at p99.9, and
> must exceed the rig noise floor, and must hold across the directive sweep.**
> Report the effect size in ns first and the p-value second, if at all.

Decision table:

| p50 change | p99.9 change | Verdict |
| --- | --- | --- |
| −6.4 ns or better | ≤ 0 (no worse) | **Accept** |
| −6.4 ns or better | worse by > 6.4 ns | **Reject** unless explicitly argued and signed off — determinism outranks mean |
| within noise | −6.4 ns or better | **Accept** — tail improvements are wins |
| within noise | within noise | **Revert.** Complexity with no measured benefit is a defect. |
| worse | any | Reject |

---

## 11. Time synchronisation, when you cannot avoid two clocks

Prefer one clock. When cross-device timestamps are unavoidable (e.g. comparing your
egress to a venue-side capture, or two colo sites):

| Mechanism | Typical accuracy (est.) | Notes |
| --- | --- | --- |
| **GPS + PPS into the capture device** | ~10–100 ns to UTC | The usual colo baseline |
| **IEEE 1588 PTP (hardware timestamping, boundary/transparent clocks end-to-end)** | ~10–100 ns | Degrades badly through any non-PTP-aware switch |
| PTP over a path with an ordinary switch | µs, and asymmetric | ⚠️ Worse than your entire budget |
| **White Rabbit** | sub-ns | Specialist; used where cross-site timing genuinely matters |
| NTP | ms | ⚠️ Not a latency tool. Not even close. |

Rules:

- **Never derive a tick-to-trade number from two independently-synced clocks.** The
  sync error is comparable to or larger than the measurement.
- If you must, **report the sync uncertainty as an explicit error bar**, and never
  claim a difference smaller than it.
- **Path asymmetry is the dominant PTP error**, not jitter. Different fibre lengths
  in the two directions bias PTP by half the difference. Measure it.
- Regulatory clock-sync obligations (MiFID II RTS 25 and equivalents) are a
  *separate* concern from measurement accuracy — meeting them does not make your
  latency measurement valid. See
  [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md).

> **Verify:** accuracy figures for PTP, GPS/PPS and White Rabbit vary enormously
> with topology and equipment. Take them from your device datasheets and
> **characterise on your own network** using the known-length method in §4.

---

## 12. The measurement checklist

Before any optimization result is believed:

```
[ ] Production bitstream (no debug cores), hash recorded
[ ] Tap-based, one capture device, one clock
[ ] Tap fibres matched or offset measured and subtracted
[ ] Rig offset and noise floor measured this week
[ ] Trigger↔order pairing via echoed ID, not nearest-preceding
[ ] Load profile is a real market-open replay, not synthetic
[ ] N >= 1e6 trigger events
[ ] p50 / p99 / p99.9 / max reported, plus histogram overflow count
[ ] On-chip per-stage histograms captured for the same run (attribution)
[ ] Both variants built across the same >=8-run directive sweep
[ ] Effect size >= 6.4 ns and > noise floor
[ ] p99.9 not worse
[ ] Junction temperature recorded
[ ] Labelled MEASURED, with build, tool version, and date
```

---

## Further reading

- [01-latency-budgeting.md](01-latency-budgeting.md) — the per-stage rows these measurements fill in
- [02-fmax-and-timing-optimization.md](02-fmax-and-timing-optimization.md) — the directive sweep referenced in §10
- [03-resource-power-optimization.md](03-resource-power-optimization.md) — why the debug strip changes the number
- [05-optimization-playbook.md](05-optimization-playbook.md) — what to do with the attribution once you have it
- [../01-fpga-design/05-verification-and-simulation.md](../01-fpga-design/05-verification-and-simulation.md) — pcap replay harness and cocotb regression
- [../02-networking/04-nics-kernel-bypass-and-switching.md](../02-networking/04-nics-kernel-bypass-and-switching.md) — taps, L1 devices, and switch latency classes
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) — running the histograms in production
- [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md) — where load replay sits in the test pyramid
