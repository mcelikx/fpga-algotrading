# 06.03 — Monitoring and Telemetry

> **Why this matters here:** hardware does not throw exceptions. A misparsed length
> field, a dropped frame, a book that stopped updating — none of these announce
> themselves. They just quietly change what you trade on. In this domain **silent
> failure is the worst failure mode**, so the design rule is absolute: every event
> that can happen is counted, and every count is readable without touching the fast
> path.

---

## 1. The principle

`CLAUDE.md` §5 rule 7 states it: *every drop, error, and rejected order is counted
in a readable register*. This document turns that into a concrete specification.

Three consequences follow, and they drive the whole design:

1. **Counters are part of the module contract.** A block's interface includes its
   counters. A block without counters is not reviewable and not deployable.
2. **Telemetry must never be able to affect the datapath.** Reading a counter,
   scraping a register, or a slow host cannot stall, backpressure, or add a cycle
   to the fast path. Not "usually doesn't" — *cannot*, structurally.
3. **A counter that never moves is a bug you haven't found yet.** At the end of
   every soak run, list every counter that stayed at zero and justify each one.

---

## 2. Counter taxonomy

Every counter below is mandatory. Width, semantics, and the block that owns it are
part of the register map.

**Semantics vocabulary:**

| Semantic | Behaviour | Use for |
| --- | --- | --- |
| **Free-running** | Increments, wraps at 2^W. Host computes deltas. | High-rate event counts |
| **Sticky** | Sets on first occurrence, clears only on explicit write-1-to-clear | Error *flags* — "did this ever happen" |
| **Saturating** | Counts up, stops at max | Rare fatal events where wrap would be confusing |
| **High-water** | Records the maximum value ever seen; write-to-clear | FIFO occupancy, burst depth |
| **Snapshot** | A whole bank latched atomically on one host write, then read out | Any set of counters that must be mutually consistent |

### 2.1 MAC / PHY layer

| Counter | Width | Semantics | Notes |
| --- | --- | --- | --- |
| `rx_frames[port]` | 48 | Free-running | Per physical port. 48 bits so it does not wrap in a trading day at line rate. |
| `rx_bytes[port]` | 48 | Free-running | |
| `tx_frames[port]` | 48 | Free-running | |
| `tx_bytes[port]` | 48 | Free-running | |
| `rx_crc_err[port]` | 32 | Free-running | **Any non-zero is investigated.** Usually a dirty optic. |
| `rx_undersize / oversize` | 32 | Free-running | Malformed framing |
| `rx_fifo_overflow[port]` | 32 | Free-running | You dropped at the MAC boundary — a design bug, not a network event |
| `link_up[port]` | 1 | Live | |
| `link_flap_count[port]` | 16 | Free-running | Flaps are the leading indicator of an optic failing |
| `pcs_block_lock_lost[port]` | 16 | Free-running | Physical layer instability |
| `fec_corrected / fec_uncorrected` | 32 | Free-running | If FEC is enabled. Corrected errors climbing = link degrading silently |

### 2.2 Feed handler

| Counter | Width | Semantics | Notes |
| --- | --- | --- | --- |
| `mold_pkts[feed][side]` | 40 | Free-running | side ∈ {A, B} |
| `seq_expected[feed]` | 64 | Live value | Current expected sequence number |
| `seq_gap_events[feed]` | 32 | Free-running | Count of *gap events*, not missing messages |
| `seq_msgs_missed[feed]` | 32 | Free-running | Count of missing messages — different metric, both needed |
| `seq_gap_recovered[feed]` | 32 | Free-running | Filled from the other side or retransmission |
| `seq_gap_unrecovered` | 32 | Sticky + count | **Alert condition.** Book integrity is now in question. |
| `arb_wins[feed][side]` | 40 | Free-running | A/B arbitration winner counts. Ratio drifting from ~50/50 means one path degraded. |
| `msg_decoded[type]` | 32 × N | Free-running | One per ITCH message type: Add, Add-with-MPID, Executed, Executed-with-price, Cancel, Delete, Replace, Trade, Cross-trade, Broken-trade, System Event, Stock Directory, Stock Trading Action, Reg SHO, MWCB, LULD, NOII/Imbalance, IPO Quoting Period, Retail Price Improvement |
| `msg_unknown_type` | 32 | Sticky + count | ⚠️ **Non-zero means the venue changed the spec or you misparsed a length.** Page a human. |
| `msg_len_mismatch` | 32 | Sticky + count | Framing error |
| `symbol_filter_hit` | 40 | Free-running | Messages for symbols we care about |
| `symbol_filter_miss` | 40 | Free-running | Messages discarded |
| `symbol_table_collision` | 32 | Free-running | Hash collisions in the lookup — affects latency |
| `symbol_not_found` | 32 | Free-running | Symbol in feed with no table entry |

> **Verify:** the exact ITCH message-type set and their identifiers come from the
> **Nasdaq TotalView-ITCH 5.0 specification**. Generate the counter enum from the
> spec, do not hand-write it from this table.

### 2.3 Book

| Counter | Width | Semantics | Notes |
| --- | --- | --- | --- |
| `book_updates` | 40 | Free-running | |
| `top_of_book_changes` | 40 | Free-running | The events the strategy actually reacts to |
| `book_crossed_events` | 32 | Sticky + count | Bid ≥ ask. Legitimate momentarily; persistent means a decode bug |
| `book_level_overflow` | 32 | Sticky + count | Depth exceeded the allocated levels |
| `book_underflow` | 32 | Sticky + count | Delete/execute against a level that wasn't there — **decode or state bug** |
| `stale_book_events[symbol_class]` | 32 | Free-running | No update for > T; strategy must not act on stale state |
| `book_stale_now` | 1 | Live | |

### 2.4 Strategy

| Counter | Width | Semantics | Notes |
| --- | --- | --- | --- |
| `strategy_evaluations` | 40 | Free-running | |
| `strategy_triggers` | 32 | Free-running | Fires that produced an order intent |
| `strategy_suppressed[reason]` | 32 × R | Free-running | Why we *didn't* fire: stale book, symbol disabled, already at max position, cooldown |
| `param_reload_count` | 16 | Free-running | Parameter table updates applied |
| `param_crc` | 32 | Live value | Fabric-computed CRC of the live parameter table — host compares |

### 2.5 Risk gate and order path

| Counter | Width | Semantics | Notes |
| --- | --- | --- | --- |
| `orders_intended` | 32 | Free-running | Into the risk gate |
| `orders_emitted` | 32 | Free-running | Out of the risk gate |
| **`risk_rejects[reason]`** | 32 × R | Free-running | **One counter per reason, never one aggregate.** Reasons: max order qty, max notional, max position long, max position short, price collar, symbol not enabled, rate limit, duplicate client order ID, self-match prevention, kill switch active, session not logged in, not armed |
| `risk_reject_total` | 32 | Free-running | Must equal the sum of the per-reason counters — a built-in consistency check |
| `kill_switch_activations` | 16 | Free-running | |
| `kill_switch_active` | 1 | Live | |
| `kill_switch_latency_max_cyc` | 16 | High-water | Cycles from assert to last order suppressed. Proves the documented bound. |
| `armed` | 1 | Live | |
| `time_armed_seconds` | 32 | Free-running | |

### 2.6 Order entry session

| Counter | Width | Semantics | Notes |
| --- | --- | --- | --- |
| `ouch_msgs_tx[type]` | 32 × N | Free-running | Enter, Replace, Cancel |
| `ouch_msgs_rx[type]` | 32 × N | Free-running | Accepted, Replaced, Canceled, Executed, Rejected, Broken Trade |
| `acks` | 32 | Free-running | |
| `fills` / `filled_shares` | 32 / 48 | Free-running | |
| `venue_rejects[reason]` | 32 × R | Free-running | **Venue** rejects, distinct from our own risk rejects |
| `ack_latency_hist` | histogram | See §3 | Order-out to ack-in, measured in fabric |
| `session_logins / logouts` | 16 | Free-running | |
| `session_drops` | 16 | Sticky + count | |
| `soup_seq_tx / soup_seq_rx` | 32 | Live value | Session sequence numbers |
| `tcp_retransmits` | 32 | Free-running | ⚠️ A retransmit on the order path is latency you cannot see any other way |
| `tcp_zero_window_events` | 16 | Sticky + count | Venue is not draining; you are about to be blocked |
| `heartbeat_missed` | 16 | Free-running | |

> **Verify:** OUCH message types, reject reason codes, and SoupBinTCP session
> semantics come from the **Nasdaq OUCH 5.0** and **SoupBinTCP** specifications.
> Enumerate reject reasons from the spec so the counter array is complete.

### 2.7 Fabric health and infrastructure

| Counter | Width | Semantics | Notes |
| --- | --- | --- | --- |
| `fifo_high_water[id]` | 16 × F | High-water | **Every FIFO in the design.** Non-obvious and enormously valuable. |
| `fifo_full_events[id]` | 32 × F | Free-running | |
| `drop_count[stage]` | 32 × S | Free-running | Deliberate drops, per stage. Rule 4 in CLAUDE.md says drop and count, never block. |
| `backpressure_cycles[stage]` | 32 × S | Free-running | Cycles a stage was stalled |
| `cdc_fifo_overflow[id]` | 32 | Sticky + count | Should be structurally impossible; count it anyway |
| `pcie_dma_completions` | 32 | Free-running | |
| `pcie_errors` | 32 | Sticky + count | |
| `host_heartbeat_age_ms` | 16 | Live value | Fabric's view of host liveness — feeds the watchdog |
| `die_temp_c` | 16 | Live value | From SYSMON/XADC |
| `die_temp_max_c` | 16 | High-water | |
| `uptime_cycles` | 48 | Free-running | Detects an unnoticed reconfiguration |
| `build_id_*` | — | Static | See [01-build-and-release.md](01-build-and-release.md) §4 |

---

## 3. Latency histograms in fabric

**This is the primary performance telemetry of the system.** Averages are useless
here; the tail is the product. Compute the distribution in hardware and read the
buckets out slowly.

Timestamp at two points using a free-running fabric counter clocked by the core
clock, and bucket the difference.

```systemverilog
// rtl/telemetry/latency_hist.sv
// Bucketed latency histogram. Log2 bucketing keeps the decoder to a
// priority encoder; linear bucketing gives better resolution where it matters.
module latency_hist #(
    parameter int N_BUCKETS  = 32,
    parameter int CNT_W      = 32,
    parameter int DELTA_W    = 20,          // cycles; 20b @6.4ns ≈ 6.7 ms max
    parameter int LIN_STEP_W = 3            // linear region granularity: 8 cycles
)(
    input  logic                clk,
    input  logic                rst,
    input  logic                sample_valid,
    input  logic [DELTA_W-1:0]  sample_cycles,   // t_out - t_in, already computed
    // ── slow control-plane read port (different clock domain, handshaked) ──
    input  logic [$clog2(N_BUCKETS)-1:0] rd_idx,
    output logic [CNT_W-1:0]             rd_count,
    input  logic                         clear,
    output logic [DELTA_W-1:0]           max_cycles,
    output logic [CNT_W+DELTA_W-1:0]     sum_cycles      // for a true mean
);
    logic [CNT_W-1:0] bucket [N_BUCKETS];
    logic [$clog2(N_BUCKETS)-1:0] idx;

    // Linear for the first region (where the design should live), log2 above it.
    always_comb begin
        if (sample_cycles < (N_BUCKETS/2) * (1 << LIN_STEP_W))
            idx = sample_cycles[LIN_STEP_W +: $clog2(N_BUCKETS)-1];
        else begin
            idx = N_BUCKETS-1;                                  // saturating top bucket
            for (int b = N_BUCKETS/2; b < N_BUCKETS-1; b++)
                if (sample_cycles < (1 << (b - N_BUCKETS/2 + LIN_STEP_W + 4)))
                    begin idx = b[$clog2(N_BUCKETS)-1:0]; break; end
        end
    end

    always_ff @(posedge clk) begin
        if (clear) begin
            for (int b = 0; b < N_BUCKETS; b++) bucket[b] <= '0;
            max_cycles <= '0; sum_cycles <= '0;
        end else if (sample_valid) begin
            bucket[idx] <= bucket[idx] + 1'b1;                   // 1 write/cycle max
            sum_cycles  <= sum_cycles + sample_cycles;
            if (sample_cycles > max_cycles) max_cycles <= sample_cycles;
        end
        rd_count <= bucket[rd_idx];                              // registered read
    end
endmodule
```

**Histograms this project must instrument:**

| Histogram | From → To | Why |
| --- | --- | --- |
| `hist_wire_to_wire` | MAC RX SOF → MAC TX SOF | The headline number |
| `hist_decode` | MAC RX → decoded message valid | Feed handler cost |
| `hist_book` | decoded → book updated | Book update cost |
| `hist_trigger` | top-of-book change → order intent | Strategy cost |
| `hist_risk_encode` | order intent → TX SOF | Gateway + risk cost |
| `hist_ack_rtt` | order TX → venue ack RX | Venue + network round trip; not ours, but tells you when the venue slows |
| `hist_interarrival` | tick → tick | Feed burst characterization |

Design notes:
- One histogram instance per measurement point; they are cheap (one BRAM or a few
  distributed RAMs each).
- **`max_cycles` and `sum_cycles` alongside the buckets** give you exact max and
  exact mean without inferring them from bucket midpoints.
- ⚠️ Clearing the histogram loses in-flight samples. Prefer read-without-clear plus
  host-side differencing; clear only at a defined boundary such as start of day.

---

## 4. Health registers and the watchdog

A single 32-bit `health` register that a human or a script can read in one access
and immediately know whether to panic:

| Bit | Meaning | Set by |
| --- | --- | --- |
| 0 | `ALL_OK` — AND of everything below being clear | fabric |
| 1 | Link down on any port | MAC |
| 2 | Sequence gap unrecovered | feed handler |
| 3 | Unknown message type seen | decoder |
| 4 | Book integrity error (underflow/overflow/persistent cross) | book |
| 5 | FIFO overflow anywhere | infrastructure |
| 6 | CDC error | infrastructure |
| 7 | Kill switch active | risk gate |
| 8 | Not armed | risk gate |
| 9 | Host heartbeat stale | watchdog |
| 10 | Over temperature (warn) | SYSMON |
| 11 | Over temperature (critical) | SYSMON |
| 12 | Parameter CRC mismatch | strategy |
| 13 | PCIe error | PCIe |
| 14 | Venue session down | gateway |
| 15 | Rate limiter engaged | risk gate |

**The watchdog:** the host writes a monotonically increasing value to a
`host_heartbeat` register on a fixed cadence. Fabric counts cycles since the last
change.

```
host_heartbeat_age > WARN_THRESHOLD   → set health bit 9, alert
host_heartbeat_age > BLOCK_THRESHOLD  → risk gate blocks all new orders
```

⚠️ The watchdog must **block** and not merely warn. A dead host process means no
position accounting, no reconciliation, and no human able to act — the fabric must
fail safe by itself. This is the same reasoning as the kill switch and belongs to
the same block; see
[../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md).

---

## 5. Getting telemetry across PCIe without touching the fast path

Two mechanisms, chosen by data rate:

| Mechanism | Used for | Cadence | Fast-path impact |
| --- | --- | --- | --- |
| **BAR-mapped register scrape** | Counters, health, histogram buckets, live values | 1–10 Hz | Reads a shadow register bank; **zero** datapath interaction |
| **DMA ring (fabric → host)** | Per-event records: every order decision, every reject, every fill, timestamped | Streaming | Writes to a dedicated FIFO that **drops and counts** when full; never backpressures |

**The structural rules that make "zero impact" true:**

1. Counters live in a **shadow bank**. The datapath increments the primary
   registers; a snapshot pulse copies the whole bank into shadow registers in one
   cycle; the host reads only shadow. No arbitration on the datapath side.
2. The snapshot pulse is generated in the slow control domain and crossed with a
   pulse synchronizer. Cost on the datapath: one register write enable.
3. The telemetry DMA FIFO's `full` signal is **not connected to anything upstream**.
   It increments `telemetry_dropped` and discards. Losing telemetry is acceptable;
   stalling the datapath is not.
4. Histogram read ports are separate from write ports (true dual-port BRAM),
   registered, and in the slow domain.

> ⚠️ **The collection cadence must not perturb the datapath — and "perturb" includes
> PCIe.** A 1 kHz register scrape generates thousands of MMIO reads per second,
> each of which is a PCIe transaction competing with your order-path DMA and your
> event ring. Scrape at 1 Hz for slow-moving counters, 10 Hz for latency-critical
> health, and never poll a register in a tight loop from the host. Measure the
> effect: run the wire-to-wire histogram with the collector on and off and compare
> the tails.

---

## 6. Host-side collection and export

```
FPGA BAR0 ──scrape 1 Hz──┐
FPGA DMA ring ───────────┤──► collector (C++/Rust, pinned, non-critical core)
                         │        │
                         │        ├──► /metrics endpoint (Prometheus-style text)
                         │        ├──► append-only binary audit log (§8)
                         │        └──► alert evaluator (§7)
                         │
                    (never on the trading-critical thread)
```

- The collector is a **separate process** from the trading control process, pinned
  to a different core, on the same NUMA node as the card. A slow or crashed
  collector must not affect trading.
- Export counters as **monotonic counters**, not gauges, wherever the underlying
  register is free-running. Let the metrics system compute rates — it handles
  resets and gaps better than you will.
- Name metrics with the owning block: `ft_feed_seq_gap_events_total`,
  `ft_risk_rejects_total{reason="max_notional"}`,
  `ft_latency_wire_to_wire_cycles_bucket{le="64"}`.
- Retain raw scrapes at full resolution for the trading day, downsample after.
- Export the histogram as a proper histogram type so quantiles are computed
  correctly rather than averaged across buckets.

> **Verify:** metric naming and histogram-bucket conventions are exporter-specific.
> Follow the conventions of whichever system you actually deploy; the point here is
> the *shape*, not the exact syntax.

---

## 7. Alerting: what pages a human

Two tiers only. Do not create a third tier that nobody reads.

**Tier 1 — PAGE IMMEDIATELY, day or night if the market is open:**

| Condition | Rationale |
| --- | --- |
| Kill switch fired (by anything, including automatically) | Trading has stopped; find out why |
| `risk_rejects` rate > N/sec, any reason | Either the strategy has gone wrong or a limit is misconfigured |
| Any `risk_rejects[reason]` that has never fired before, firing | A new failure mode |
| `seq_gap_unrecovered` non-zero | The book may be wrong; you may be trading on fiction |
| Position mismatch: fabric ↔ host ↔ drop copy | **The most dangerous alert in the system.** Stop trading and reconcile. |
| Link down on any fast-path port | |
| Order-entry session down while armed | |
| Die temperature above critical threshold | Timing margin is gone |
| `msg_unknown_type` non-zero | The venue changed something or you are misparsing |
| Book integrity error (underflow / persistent cross) | Decode or state bug, live |
| Host heartbeat stale (watchdog engaged) | |
| p99 wire-to-wire latency > budget × 1.25 sustained for > 30 s | Something structural changed |
| Build ID ≠ expected | Wrong bitstream is running |

**Tier 2 — ticket, review same day:**

| Condition |
| --- |
| CRC errors non-zero but low; FEC corrected errors trending up |
| Link flap count incremented |
| `arb_wins` A/B ratio drifted > 60/40 |
| FIFO high-water above 70 % of depth |
| `telemetry_dropped` non-zero |
| TCP retransmits above baseline |
| Symbol table collision rate up |
| p50 latency drifted > 5 % vs the 7-day baseline |
| Any counter that has never moved, moving for the first time |

**Alerting rules:**
- Every Tier 1 alert has a written runbook entry naming the first action. For most
  of them the first action is **hit the kill switch**; see
  [../07-reference/04-checklists.md](../07-reference/04-checklists.md).
- Alert on *rates and deltas*, not absolute counter values — free-running counters
  wrap.
- Test the alerting path itself, on a schedule. An untested pager is a decoration.

---

## 8. Dashboards: the trading-day view

One screen, readable in three seconds from across the room:

| Zone | Content |
| --- | --- |
| **Top banner** | ARMED / DISARMED, kill-switch state, build ID, session up/down, health register decoded to words |
| **Latency** | Wire-to-wire p50/p99/p99.9/max as a live sparkline, plus the full histogram as a bar chart. Budget line drawn on it. |
| **Feed** | Messages/sec, gap count today, A/B win ratio, time since last gap, book staleness |
| **Trading** | Orders sent, acks, fills, filled shares, current position per symbol, PnL (host-computed), open order count |
| **Risk** | Rejects by reason as a stacked bar for the day; utilization of each limit as a percentage bar (e.g. "position 34 % of max") |
| **Errors** | Every sticky bit, red if set, with the time it was first set |
| **Infrastructure** | Die temp, link status, CRC/FEC, PCIe errors, FIFO high-water marks, collector lag |

Also keep a **day-over-day comparison** view: today's message rate, latency
distribution, and reject profile overlaid on the trailing 5-day median. Most
regressions are visible as a shape change long before they trip a threshold.

---

## 9. Counter hazards ⚠️

These are the ways counter-based monitoring lies to you.

| Hazard | What goes wrong | Rule for this project |
| --- | --- | --- |
| **Wrap** | A 32-bit counter at 10 M events/sec wraps in ~430 s. Your 1 Hz scrape sees a delta go negative and your dashboard shows a dip, or your alert never fires. | Size high-rate counters at **40–48 bits**. Where you cannot, have the host detect wrap explicitly by unsigned-difference arithmetic on the counter width — never by comparing magnitudes. |
| **Clear-on-read** | Events occurring between the read and the clear are lost. Two collectors reading the same counter each see part of the truth. | **Do not use clear-on-read.** Free-running plus host differencing, or explicit write-1-to-clear on sticky bits only. |
| **Non-atomic multi-word reads** | A 48-bit counter read as two 32-bit words can tear across an increment, producing a wildly wrong value. | Use the **snapshot bank**: one write latches all counters, then read at leisure. Every multi-word counter goes through it. |
| **Inconsistent bank** | `orders_emitted` read before a snapshot and `acks` read after do not describe the same instant. | Same fix: snapshot the whole bank, always. |
| **Missed transient errors** | A single-cycle error pulse between two 1 Hz scrapes is invisible in a free-running counter if it also increments something noisy. | **Sticky-error pattern**: every error condition sets a sticky bit *and* increments a counter. The sticky bit answers "did it ever happen"; the counter answers "how often". Clear sticky bits only at start of day, and log the values first. |
| **Counters that don't exist** | The block you forgot to instrument is exactly the one that will fail. | Counter coverage is a review checklist item; see [../07-reference/04-checklists.md](../07-reference/04-checklists.md). |
| **Counters that never move** | Dead code, wrong condition, or an event you have never actually exercised. | Post-soak zero-counter report, with a justification per entry. |

The sticky-error pattern in RTL:

```systemverilog
always_ff @(posedge clk) begin
    if (clr_sticky) err_sticky <= '0;
    else if (err_pulse) err_sticky <= 1'b1;     // sticky wins over clear? NO —
                                                // clear has priority, and the host
                                                // logs the count before clearing.
    if (err_pulse) err_count <= err_count + 1'b1;
end
```

---

## 10. Audit logging of order decisions

Separate from metrics, and non-negotiable: **every order decision is logged as a
record**, whether or not an order was emitted.

| Field | Source | Notes |
| --- | --- | --- |
| Fabric timestamp (ingress of the triggering tick) | fabric counter, PTP-disciplined | Nanosecond resolution |
| Fabric timestamp (order TX) | fabric counter | Gives wire-to-wire per decision |
| Triggering message: feed, sequence number, type, symbol | feed handler | Lets you replay the exact input |
| Book state snapshot at decision (top N levels) | book | Small, fixed size |
| Strategy ID and parameter-set CRC | strategy | Proves *which* logic decided |
| Decision: emitted / suppressed, and the reason code | strategy + risk | Suppressions matter as much as emissions |
| Risk gate result and reason code | risk gate | |
| Order fields as encoded (client order ID, side, qty, price, TIF) | gateway | Byte-exact |
| Venue response and its timestamp | gateway | Ack / reject / fill |
| Build ID | static | Ties the record to a bitstream |

- Written through the telemetry DMA ring, appended to an immutable, timestamped
  file per trading day, checksummed and archived.
- Retained per your compliance retention policy.
- Reconciled end-of-day against drop copy and clearing.

> **Verify:** record retention periods and audit-trail obligations for US equities
> derive from the **CAT NMS Plan (SEC Rule 613)**, **SEC Rule 17a-4** record
> retention, and **SEC Rule 15c3-5** for market-access controls. The applicable set
> depends on your registration status. Confirm with compliance and treat their
> answer as authoritative over this table. See
> [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md).

---

## Further reading

- [01-build-and-release.md](01-build-and-release.md) — the build-ID register the dashboard displays
- [02-deployment-and-colocation.md](02-deployment-and-colocation.md) — PTP, the clock these timestamps depend on
- [04-testing-strategy.md](04-testing-strategy.md) — how counters get verified before deployment
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — the risk gate that owns most of §2.5
- [../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md) — measurement methodology behind the histograms
- [../07-reference/04-checklists.md](../07-reference/04-checklists.md) — start-of-day and incident checklists
