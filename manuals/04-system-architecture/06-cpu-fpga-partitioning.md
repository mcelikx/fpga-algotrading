# 04.06 — CPU/FPGA Partitioning

> **Why this matters here:** the previous five documents describe what the fabric
> does. This one describes everything else, and — more importantly — *the rule* for
> deciding which side of the PCIe boundary a new piece of work lands on. Getting that
> rule wrong is how a 400 ns design becomes a 4 µs design, or how a correct design
> becomes an unmaintainable one that needs a bitstream build to change a number.

---

## 1. The decision rule

Three questions, in order. The first `no` decides it.

```
   ┌──────────────────────────────────────────────────────────────────┐
   │ Q1. Must it happen inside the tick-to-trade window (< 400 ns)?   │
   │     NO  → CPU. Stop here. Do not optimise; do not "just put it   │
   │           in fabric because we can".                             │
   │     YES → continue                                               │
   └────────────────────────────┬─────────────────────────────────────┘
   ┌────────────────────────────▼─────────────────────────────────────┐
   │ Q2. Is it bounded, branch-free, and simple enough to be provably │
   │     correct in RTL, in a fixed number of cycles?                 │
   │     NO  → redesign it until it is, or move the *decision* to the │
   │           CPU and leave a *comparison* in fabric.                │
   │     YES → continue                                               │
   └────────────────────────────┬─────────────────────────────────────┘
   ┌────────────────────────────▼─────────────────────────────────────┐
   │ Q3. Does it change more often than you are willing to rebuild a  │
   │     bitstream (2–8 h + full revalidation)?                       │
   │     YES → put the *mechanism* in fabric and the *policy* in a    │
   │           parameter table. Never hardcode a number that moves.   │
   │     NO  → fabric.                                                │
   └──────────────────────────────────────────────────────────────────┘
```

**The corollary that does most of the work in practice:** most things that *feel*
like they belong in hardware actually decompose into a slow *policy* (CPU) and a fast
*comparison* (FPGA). Fair value is a model on the CPU and a 32-bit compare in fabric.
A position limit is a risk committee's decision on the CPU and a subtraction in
fabric. Once you look for this decomposition, you find it almost everywhere, and it
is always the right answer.

**The anti-rule:** "it would be cool in hardware" is not a reason. Fabric is
expensive to write, expensive to verify, expensive to change, and impossible to
`printf`. Every gate you put there should be there because Q1 said so.

---

## 2. The full subsystem classification

| Subsystem | Where | Reasoning |
| --- | --- | --- |
| **Ethernet/IP/UDP RX parse** | FPGA | Q1 yes. Fixed-offset, trivially bounded. |
| **MoldUDP64 deframe, A/B arbitration** | FPGA | Q1 yes. Line rate, no backpressure possible. |
| **ITCH decode + field extract** | FPGA | Q1 yes. Fixed-offset, 1 cycle. |
| **Symbol filter / locate → slot** | FPGA | Q1 yes. One BRAM read. Table content comes from the CPU. |
| **Symbol table *build*** | CPU | Q1 no. Start of day, from ITCH `R` messages + reference data. Milliseconds are fine. |
| **Order-ID map** | FPGA | Q1 yes — deletes carry only a reference (04.03 §1). A PCIe round trip per delete is a non-starter. |
| **Price-level array + RMW** | FPGA | Q1 yes. |
| **Top-of-book maintenance** | FPGA | Q1 yes. Incremental, 1 cycle. |
| **Book depth aggregation beyond L3** | CPU | Q1 no. Depth is a slow signal (04.03 §7). |
| **Strategy trigger evaluation** | FPGA | Q1 yes. This is the product. |
| **Strategy parameter computation** | CPU | Q1 no — ms scale. Q3 yes — changes constantly. |
| **Strategy selection (`prim_id`)** | Both | Mechanism in fabric (all primitives instantiated), policy in the parameter table. |
| **Pre-trade risk gate** | FPGA | Q1 yes, and it is legally required to be non-bypassable (04.05 §1). |
| **Risk *limit* determination** | CPU | Q1 no. Set by risk management, written to fabric, verified by readback. |
| **Kill switch mechanism** | FPGA | Q1 yes. Must work when the CPU is the thing that failed. |
| **Kill switch *triggers*** | Both | Fabric triggers (rate, saturation, watchdog) + host triggers (operator, reconciliation mismatch). |
| **OUCH encode** | FPGA | Q1 yes. Template + splice, 2 cycles. |
| **OUCH template *contents*** | CPU | Q1 no. Built from the spec + reference data at start of day. |
| **Order token generation** | FPGA | Q1 yes. Concatenation of registers, 0 cycles. |
| **TCP/SoupBin steady-state send** | FPGA | Q1 yes. |
| **TCP connect / handshake / login** | CPU | Q1 no. Once per session. Complex, stateful, latency-irrelevant. |
| **TCP retransmit, window recovery, teardown** | CPU | Q1 no. Rare, complex; fabric hands over and stops (04.05 §8). |
| **Heartbeats** | CPU | Q1 no. 1 Hz. |
| **OUCH ack/fill decode** | FPGA | Q1 *nearly* — not in `T2T`, but gates the *next* order, so must be < 1 µs. |
| **Position tracking (for the risk gate)** | FPGA | Q1 yes, it is a risk-gate input. |
| **Position *reconciliation*** | CPU | Q1 no. And it must be **independent** of the fabric's own arithmetic (04.05 §10). |
| **PnL** | CPU | Q1 no. Nothing on the fast path consumes PnL. |
| **Sequence gap *detection*** | FPGA | Q1 yes — it must stale the book within the same message. One comparator. |
| **Sequence gap *recovery*** | CPU | Q1 no. Re-request / Glimpse snapshot, milliseconds, complex protocol. |
| **Book resync injection** | Both | CPU sources the data; a fabric write port applies it while the symbol is stale (04.03 §9). |
| **Order state reconciliation** | CPU | Q1 no. Compare fabric's `my_orders` against the venue's view. |
| **Logging / audit trail** | Both | Fabric *emits* records (0 cycles, a tap); CPU persists them. |
| **Monitoring, counters, histograms** | Both | Fabric counts and bins; CPU polls, exports, alerts. |
| **Latency histogram** | FPGA | Q1 no, but the *timestamps* only exist in fabric, so binning there is far cheaper than shipping every sample. |
| **Start-of-day setup, arming sequence** | CPU | Q1 no. Sequenced, verified, human-supervised. |
| **Watchdog counter** | FPGA | Q1 yes-by-definition — it exists to detect CPU failure. |
| **Bitstream / config management** | CPU | — |

**Count:** 14 subsystems in fabric, 15 on the CPU, 6 split. That ratio is healthy. A
design where everything is in fabric is one nobody can change; a design where the
book is on the CPU is one that is not competitive.

---

## 3. PCIe is the boundary, and nothing latency-critical crosses it

### The hard rule

> **No signal on the tick-to-trade path crosses PCIe. Ever. In either direction.**

Restated operationally, because this is where it gets violated in practice:

1. **No MMIO read on the fast path.** An MMIO read is a *non-posted* transaction —
   the CPU blocks for the full round trip. It is 3–4 orders of magnitude outside the
   budget. MMIO reads belong in the `ttd-control` polling loop at 1–1000 Hz.
2. **No DMA read initiated by a fast-path event.** Same reason.
3. **No "ask the CPU" fallback**, including the tempting one — an order-map miss
   (04.03 §2.6). The fallback path's latency becomes the p99 of the whole system.
4. **Fabric never waits on the host.** The host's absence is detected by the
   watchdog and handled by the kill switch, not by blocking.

### Order-of-magnitude figures

| Operation | Estimate | vs. our 400 ns budget |
| --- | ---: | ---: |
| MMIO **posted write**, host → BAR (time to land at the device) | 150–400 ns | ~1× |
| MMIO **read**, host → BAR → host (userspace, blocking) | **1–2 µs** | 3–5× |
| DMA write, device → host memory (posted, to visibility) | 300 ns–1 µs | 1–3× |
| DMA read, device → host memory → device | **1–3 µs** | 3–8× |
| Host interrupt (MSI-X) to userspace handler | **2–10 µs** | 5–25× |
| Host poll of a DMA'd producer index in cached memory | 50–200 ns | — |

> **Verify:** all of the above are order-of-magnitude estimates and are **highly**
> platform-dependent — root complex, IOMMU on/off, ACS, relaxed ordering, PCIe
> ASPM, C-states, NUMA distance, and whether the BAR is mapped write-combining. They
> can vary by 3× between two servers with the same CPU. Measure yours with a
> loopback test (`host/tools/pcie_lat`) before designing against them. See
> [../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md)
> and [../07-reference/02-latency-reference-numbers.md](../07-reference/02-latency-reference-numbers.md).

### Control plane vs. data plane

| | Control plane | Data plane |
| --- | --- | --- |
| Mechanism | BAR0 MMIO registers | DMA rings in host memory |
| Direction | host → device (writes), host ← device (reads) | device → host (logs), host → device (params) |
| Bandwidth | trivial (< 1 MB/s) | ~64 MB/s at 1 M events/s |
| Latency tolerance | µs–ms | ms |
| Ordering | strict, one register at a time | ring order |
| Used for | arm/disarm, limits, kill, status, counters | audit records, telemetry, parameter batches |
| ⚠️ Never used for | anything on the fast path | anything on the fast path |

The split matters because they have different failure modes. A dropped MMIO write
silently leaves a limit wrong (hence readback verification, 04.05 §3). A stalled DMA
ring silently loses telemetry (hence the audit/telemetry split, §5).

---

## 4. The control register map

BAR0, 64 KB, 32-bit registers, little-endian. `RO` = read-only, `RW` = read/write,
`W1S` = write-1-to-set, `RC` = read-to-clear.

| Offset | Name | Acc | Reset | Description |
| --- | --- | --- | --- | --- |
| `0x0000` | `ID` | RO | `0x54544430` | `"TTD0"` magic — probe check |
| `0x0004` | `VERSION` | RO | build | `{major[7:0], minor[7:0], patch[15:0]}` |
| `0x0008` | `GIT_SHA_LO` | RO | build | low 32 bits of the source hash |
| `0x000C` | `GIT_SHA_HI` | RO | build | high 32 bits |
| `0x0010` | `BUILD_TIME` | RO | build | Unix epoch of synthesis |
| `0x0014` | `CAPS` | RO | build | `N_SYMBOLS`, `N_LVL`, `N_PRIM`, feature bits |
| `0x0020` | `CTRL` | RW | `0` | `[0] trade_en, [1] feed_en, [2] tx_own_fpga, [3] scrub_en` |
| `0x0024` | `STATUS` | RO | — | `[0] link_up, [1] pcs_sync, [2] feed_sync, [3] sess_up, [4] any_stale, [5] param_fresh` |
| `0x0028` | `RESET` | W1S | — | `[0] soft_reset, [1] ctr_clear, [2] book_clear_all` (⚠️ `book_clear_all` requires `trade_en=0`) |
| **Kill switch** | | | | |
| `0x0040` | `KILL_SET` | W1S | — | write 1 to bit 0 → arm the kill switch immediately |
| `0x0044` | `KILL_CLEAR` | W1S | — | write the magic `0xC1EA2CLR` to disarm; any other value is ignored and counted |
| `0x0048` | `KILL_STATUS` | RO | `0x1` | `[0] armed, [11:4] first_trigger_source, [31:16] arm_count` |
| `0x004C` | `KILL_TS_LO/HI` | RO | — | fabric timestamp of the first arm |
| `0x0050` | `WDOG_RELOAD` | RW | `0` | watchdog reload in ms (0 = expired = killed) |
| `0x0054` | `WDOG_KICK` | W1S | — | host heartbeat; reloads the counter |
| `0x0058` | `WDOG_VALUE` | RO | `0` | current countdown, for observability |
| **Global risk** | | | | |
| `0x0080` | `RISK_RATE_SYM` | RW | `0` | per-symbol token bucket rate and depth |
| `0x0084` | `RISK_RATE_GLOBAL` | RW | `0` | global token bucket rate and depth |
| `0x0088` | `CREDIT_INIT` | RW | `0` | in-flight credit depth `K` (04.05 §9) |
| `0x008C` | `CREDIT_RETURN` | W1S | — | host returns `n` credits |
| `0x0090` | `CREDIT_VALUE` | RO | `0` | current credit, for leak detection |
| **Per-symbol window** (indexed access; avoids a 128× register file in the map) | | | | |
| `0x0100` | `SYM_SEL` | RW | `0` | slot index 0..127 |
| `0x0104` | `SYM_LIMITS_0` | RW | `0` | `max_qty` |
| `0x0108` | `SYM_LIMITS_1` | RW | `0` | `max_notional` |
| `0x010C` | `SYM_LIMITS_2` | RW | `0` | `max_pos` |
| `0x0110` | `SYM_LIMITS_3` | RW | `0` | `max_gross`, `max_open` |
| `0x0114` | `SYM_COLLAR` | RW | `0` | `{collar_lo[15:0], collar_hi[15:0]}` in ticks from `base` |
| `0x0118` | `SYM_FLAGS` | RW | `0` | `[0] enable, [1] risk_blocked (W1C), [2] book_stale (W1C), [3] halted (RO)` |
| `0x011C` | `SYM_POSITION` | RO | `0` | fabric's position, for reconciliation |
| `0x0120` | `SYM_OPEN_CNT` | RO | `0` | fabric's open order count |
| `0x0124` | `SYM_BASE_PX` | RW | `0` | price window base in cents (04.03 §4) |
| **Parameter DMA** | | | | |
| `0x0180` | `PARAM_DMA_ADDR_LO/HI` | RW | `0` | host buffer physical address |
| `0x0188` | `PARAM_DMA_LEN` | RW | `0` | bytes |
| `0x018C` | `PARAM_DMA_GO` | W1S | — | doorbell: fetch into shadow banks |
| `0x0190` | `PARAM_SHADOW_CKSUM` | RO | `0` | ⚠️ read and verify **before** committing |
| `0x0194` | `PARAM_COMMIT_LO/HI` | RW | `0` | 128-bit commit mask (write HI last; HI triggers) |
| `0x019C` | `PARAM_ACTIVE_LO/HI` | RO | `0` | current `active_bank` vector, for confirmation |
| **DMA log rings** | | | | |
| `0x0200` | `AUDIT_BASE_LO/HI` | RW | `0` | audit ring base (host physical) |
| `0x0208` | `AUDIT_SIZE` | RW | `0` | ring size, power of two |
| `0x020C` | `AUDIT_CONS_IDX` | RW | `0` | host writes what it has consumed |
| `0x0210` | `AUDIT_PROD_IDX` | RO | `0` | device's producer index (also mirrored into host memory) |
| `0x0214` | `AUDIT_DROPS` | RO | `0` | ⚠️ **must be 0.** Non-zero → kill switch (§5) |
| `0x0220`–`0x0234` | `TELEM_*` | | | same layout for the telemetry ring; drops are permitted |
| **Counters** (windowed, to keep the map small) | | | | |
| `0x0400` | `CTR_SEL` | RW | `0` | counter index |
| `0x0404` | `CTR_VALUE_LO/HI` | RO | `0` | 48-bit saturating value |
| `0x040C` | `CTR_NAME_*` | RO | — | 16-byte ASCII name, so tooling is self-describing |
| `0x0500` | `REJECT_CTR[0..23]` | RO | `0` | per-check rejection counters (04.05 §11) |
| `0x0580` | `REJECT_FIRST_*` | RO | `0` | sticky first-rejection record |
| `0x0600` | `LAT_HIST[0..63]` | RO | `0` | fabric latency histogram bins |

Design notes:

- ⚠️ **`SYM_SEL` is an indexed window, so it is not thread-safe.** Exactly one host
  thread (`ttd-control`) touches the per-symbol window, holding a lock. Two threads
  interleaving `SYM_SEL` writes will write a limit to the wrong symbol. This is worth
  a comment in the driver and an assertion in the test suite.
- **`KILL_CLEAR` requires a magic value** so that a wild pointer or a memset over the
  BAR cannot disarm the kill switch. `KILL_SET` accepts any write, because making it
  *easy* to stop is the correct asymmetry.
- **Every register is in `reg_map_pkg.sv`**, and the host header
  (`host/include/tt_regs.h`) is **generated** from it by `scripts/gen_regmap.py`.
  Hand-maintaining two copies of a register map is a guaranteed eventual mismatch,
  and a mismatch here writes a risk limit to the wrong offset.

---

## 5. The DMA log rings

### Two rings, deliberately

| | **Audit ring** | **Telemetry ring** |
| --- | --- | --- |
| Contents | every order, every reject (with the 24-bit check vector), every ack/fill, every kill event, every stale transition | latency samples, book snapshots, counter deltas, decision traces including `NONE` |
| Rate | ~10³–10⁵ records/s | up to ~10⁶ records/s |
| On ring full | ⚠️ **arm the kill switch** | **drop and count** |
| Why | these records are the regulatory audit trail and the reconciliation input; losing one means the CPU's position is wrong and cannot be corrected | losing a latency sample costs a data point |

⚠️ **This split is the whole design.** A single ring forces an impossible choice: if
it drops, you lose audit records; if it blocks, telemetry can stall the fast path.
Separating them lets each have the correct policy. If the audit ring is filling, the
host is not keeping up with *orders*, which means the risk supervision loop is broken
— stopping is the right answer.

### Record format (64 bytes, one cache line)

```
 byte  0        8       12      16      20      24      32      40      48      64
      ┌────────┬───────┬───────┬───────┬───────┬───────┬───────┬───────┬────────┐
      │tstamp  │ type  │ slot  │ token │ px    │ qty   │ chk   │ state │ payload│
      │ 64-bit │ 32    │ 16    │ 32    │ 32    │ 32    │ 64    │ 64    │ 16 B   │
      └────────┴───────┴───────┴───────┴───────┴───────┴───────┴───────┴────────┘
```

- **64 bytes = exactly one cache line.** The DMA engine writes whole lines, so the
  host never observes a torn record and never triggers a read-for-ownership.
- `tstamp` is the same free-running fabric counter used everywhere else (04.02 §9),
  so hardware histograms and host-side reconstruction share a clock.
- `chk` carries the full 24-bit risk vector, so *why* an order was rejected is in
  the record, not inferred.

### Producer index

The device writes records, then updates a producer index. ⚠️ The index must be
written **after** the records, in a separate transaction, to a separate cache line —
otherwise the host can observe an advanced index pointing at bytes not yet written.
PCIe posted writes to the same address are ordered, but the host's *cache* is not
your ordering domain.

```
Device: write records (N cache lines) → memory fence → write prod_idx (own cache line)
Host:   poll prod_idx (cached read, 50–200 ns) → consume up to prod_idx
        → write AUDIT_CONS_IDX (MMIO, 1/batch not 1/record)
```

Batch the consumer-index writeback: one MMIO write per batch of records, not per
record. Otherwise the host spends its time doing PCIe writes.

### Bandwidth

```
1 M records/s × 64 B = 64 MB/s
PCIe Gen3 x16 usable ≈ 12–13 GB/s
⇒ ~0.5 % of the link.
```

Telemetry bandwidth is a non-issue. **Telemetry *interference* is the issue**, and it
is handled structurally: the DMA engine reads from the telemetry FIFO on the fabric's
spare BRAM ports, never from a port the fast path uses (04.01 §4).

---

## 6. Host software architecture

Four processes. Separate processes, not threads, so that one crashing does not take
the others with it — and specifically so that `ttd-risk` survives a crash in
`ttd-params`.

| Process | Priority | Pinning | Period | Responsibility |
| --- | --- | --- | --- | --- |
| **`ttd-control`** | `SCHED_FIFO` 80 | isolated core, NUMA-local to the PCIe root port | 100 Hz | Arm/disarm, watchdog kick, limit readback verification, register plumbing, health, operator interface |
| **`ttd-risk`** | `SCHED_FIFO` 90 | isolated core, NUMA-local | drains audit ring continuously | Independent position/PnL from raw audit bytes, reconciliation vs. fabric (1 Hz) and vs. drop copy (1 min), **kill authority** |
| **`ttd-params`** | `SCHED_FIFO` 50 | isolated core | 1 kHz | Slow signals → parameter rows → DMA + checksum verify + commit; parameter watchdog kick |
| **`ttd-logger`** | `SCHED_OTHER` (nice) | shared cores, NUMA-local to the ring | continuous | Drain telemetry ring → disk/kafka. **Must not be able to slow anything down.** |
| **`ttd-recovery`** | `SCHED_OTHER` | shared | on demand | MoldUDP64 re-request / Glimpse snapshot, book resync injection |

`ttd-risk` has the highest priority of the four, above `ttd-control`. That is
deliberate: the process that can stop trading must never be starved by the process
that manages trading.

### Required system configuration

| Setting | Value | Why |
| --- | --- | --- |
| `isolcpus` / `nohz_full` / `rcu_nocbs` | the trading cores | no scheduler ticks, no RCU callbacks on the hot cores |
| IRQ affinity | **away** from trading cores | an unrelated NIC interrupt is a 10 µs stall |
| Hugepages | 1 GB, pre-allocated for the DMA rings | TLB misses on a ring walk are avoidable jitter |
| `mlockall(MCL_CURRENT\|MCL_FUTURE)` | all four processes | ⚠️ a page fault in `ttd-risk` during a reconciliation is a multi-ms stall in the process that holds the kill authority |
| NUMA | all rings and all processes on the node owning the PCIe root port | a cross-socket DMA is 2–3× the latency and adds jitter |
| CPU C-states | disabled (`intel_idle.max_cstate=0`) | C-state exit is microseconds |
| Turbo / frequency scaling | fixed frequency | ⚠️ variable frequency makes every host-side latency measurement meaningless |
| Transparent hugepages | disabled | compaction stalls |

⚠️ **None of this is on the tick-to-trade path** — that is the point of the whole
architecture. It matters because the *supervision* loop must be reliable. A
`ttd-risk` that stalls for 50 ms is 50 ms in which nobody is checking that the
fabric's position is right.

---

## 7. Startup and shutdown sequencing

### ⚠️ The order matters, and every step is verified before the next

```
 1. Load bitstream
 2. Read ID / VERSION / GIT_SHA          → must match the expected build. Abort if not.
 3. Assert soft reset; read back:
       KILL_STATUS.armed == 1            ⚠️ if it is 0 after reset, STOP — fail-closed
       CTRL == 0, all limits == 0, all counters == 0
 4. Load the symbol table (locate → slot, subscribed bits, SYM_BASE_PX)
       → read back and verify every entry
 5. Load risk limits, per symbol
       → read back and verify every field   ⚠️ MANDATORY, posted writes are unreliable
 6. Load OUCH templates (per symbol, per side)
       → read back a checksum and verify
 7. Load strategy parameters into shadow banks (DMA)
       → read PARAM_SHADOW_CKSUM and verify → write PARAM_COMMIT
       → read PARAM_ACTIVE and confirm
 8. Set up the DMA rings; verify by injecting a synthetic record and reading it back
 9. Enable the feed (CTRL.feed_en); wait for feed_sync
       → require N seconds of unbroken sequence continuity  ⚠️ do not skip
10. Build the books: consume the start-of-day feed, or take a Glimpse snapshot
       → verify hardware L1 against the software shadow book for every symbol
       → clear book_stale PER SYMBOL, individually, after each verifies
11. Establish the OUCH session (CPU): TCP connect, SoupBin login, sequence negotiate
       → verify sess_up
12. Hand TX ownership to the fabric (CTRL.tx_own_fpga); verify
13. Start the watchdog: WDOG_RELOAD, then begin kicking at 100 Hz
       → verify WDOG_VALUE is decrementing and being reloaded
14. Set CTRL.trade_en
15. KILL_CLEAR (magic value)                ← ⚠️ THE LAST STEP. Trading is now live.
```

**Why this order specifically:**

- Kill is disarmed **last**, after every other precondition is verified. There is
  never a window where the system could trade but has not been fully checked.
- The watchdog starts **before** trading, so there is never a live-trading moment
  without host supervision.
- Books are verified **per symbol**, and `book_stale` is cleared per symbol. A global
  clear (04.03 §9) would enable trading on a symbol that failed verification.
- Feed sync precedes book build, which precedes the session, which precedes trading.
  Each is a precondition of the next; none can be reordered.

⚠️ **If any step fails, you stop at that step.** There is no "continue and fix it
during the session". The cost of not trading for an hour is bounded and known. The
cost of trading with an unverified risk limit is not.

### Shutdown (normal)

```
 1. KILL_SET                                 ← stop new orders first, always
 2. Wait for CREDIT_VALUE == CREDIT_INIT     ← all in-flight orders accounted
 3. ttd-risk issues mass cancel over OUCH; wait for open_order_cnt == 0 on all slots
 4. Verify final position vs. drop copy
 5. CTRL.trade_en = 0
 6. SoupBin logout, TCP close
 7. CTRL.feed_en = 0
 8. Drain both DMA rings to completion; verify AUDIT_DROPS == 0
 9. Snapshot all counters and histograms to the day's report
10. Stop the watchdog last
```

### Shutdown (emergency)

`KILL_SET`, then drop the TCP session to invoke cancel-on-disconnect. Everything
else is cleanup. ⚠️ Do not attempt an orderly shutdown during an incident — orderly
shutdown has more steps and more ways to fail. Stop first; be tidy afterwards.

---

## 8. When the host dies

This is the failure the architecture is most specifically designed around, because
the fabric keeps running perfectly whether or not anyone is supervising it, and an
unsupervised algorithmic trading system is the industry's canonical disaster.

| Failure | Detection | Response | Bound |
| --- | --- | --- | ---: |
| `ttd-control` crashes or stalls | watchdog stops being kicked | kill switch arms | ≤ `WDOG_RELOAD` (default 500 ms) |
| `ttd-risk` crashes | audit ring stops being drained → fills | ring-full → kill switch | ring depth ÷ order rate |
| `ttd-risk` stalls without crashing | credits stop being returned | `credit_starved` → no new orders after `K` | ≤ `K` orders |
| `ttd-params` crashes | no parameter commits | parameter watchdog → `param_fresh` clears → all symbols gated off | ≤ `T_param_max` (500 ms) |
| Whole host hangs (kernel panic, NMI) | watchdog | kill switch | ≤ 500 ms |
| Host reboots | PCIe link down | kill switch, same cycle | ~0 |
| Driver unloaded / process killed with the FPGA armed | watchdog | kill switch | ≤ 500 ms |
| ⚠️ Host is alive but *wrong* (bad params, bad limits) | reconciliation mismatch, limit readback mismatch | kill switch | ≤ 1 s |

**Three independent supervision mechanisms**, with different failure modes:

1. **Watchdog** — catches "host stopped".
2. **Credit exhaustion** — catches "host stopped *accounting*" even if it is still
   kicking the watchdog.
3. **Reconciliation** — catches "host is running and accounting but the numbers
   disagree", which is the only one that catches a *logic* fault rather than a
   liveness fault.

⚠️ Mechanism 2 exists because a watchdog kick is trivially easy for a broken process
to keep doing. A heartbeat proves a thread is scheduled; it proves nothing about
whether that thread is doing its job. Credit return is *work-coupled* — it can only
happen if the host actually consumed and processed audit records.

---

## 9. Evolving the partition

Do not build the final partition on day one. Build the version you can verify, then
migrate downward with evidence.

| Phase | FPGA does | CPU does | Expected `T2T` | Exit criterion |
| ---: | --- | --- | ---: | --- |
| **0** — Bring-up | PHY/MAC loopback, timestamping, counters | everything | n/a | Loopback latency measured; PHY rows in 04.01 §3 replaced with real numbers |
| **1** — Smart NIC | Feed decode → DMA of decoded events | Book, strategy, risk, order entry | ~5–15 µs | Golden model agrees with the fabric decoder byte-for-byte over a full day of pcap |
| **2** — Book in fabric | + order book, top-of-book publish | Strategy, risk, order entry | ~3–10 µs | Fabric book matches the software book after **every message**, all day (04.03 §12) |
| **3** — Full fast path | + strategy trigger, risk gate, OUCH encode | Params, reconciliation, session, recovery | **~400 ns** | Conformance passed; kill switch bound verified; reconciliation clean for N days |
| **4** — Tuning | as phase 3, optimised | as phase 3 | **< 350 ns** | Measured p99.9, attributed per stage |

**Why this order.** Each phase makes the *previous* phase's software the oracle for
the next phase's hardware. The software book written in phase 1 is what validates the
fabric book in phase 2. The software strategy from phase 2 is what validates the
fabric strategy in phase 3. You never have to trust a hardware block against a
specification alone — you always have a working, tested, independent implementation
to diff against. **Do not delete the software implementations when you migrate down;
they become the permanent verification oracle** and the disaster-recovery path.

### Migration rules

1. **Never migrate two blocks in the same change.** One block, one bitstream, one
   validation cycle, one measurement.
2. **Keep the software path runnable.** A per-symbol `prim_id = 0` plus the CPU order
   path is a degraded but functional mode. It is also how you trade while a hardware
   bug is being fixed.
3. **Measure before and after, on the same pcap.** "It should be faster" is not a
   result. See [../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md).
4. **Migrate down; do not migrate up.** Moving a block back to software after it has
   been in fabric is a signal that Q2 in §1 was answered wrong — record why, in
   `docs/adr/`.
5. ⚠️ **The risk gate goes into fabric in phase 3 and never leaves.** It is the one
   block that cannot live in software in the final design, and it should be the block
   that is most heavily tested before phase 3 ships.

---

## 10. Partitioning smells

Signs the boundary has been drawn wrong:

| Smell | What it means | Fix |
| --- | --- | --- |
| A fabric block reads a status register the host writes on every tick | PCIe is on the fast path | precompute into a parameter |
| A parameter changes more than ~1 kHz | it is a signal, not a parameter — or the strategy is mis-specified | move the derivation into fabric, or slow the signal |
| Any fabric block can stall waiting on the host | the fast path has an unbounded case | drop-and-count instead |
| Bitstream rebuilds happen more than monthly for strategy reasons | Q3 was answered wrong | more parameterisation, more primitives |
| Host code duplicates fabric arithmetic to "check" it | that is *good* for reconciliation, *bad* if it is derived from the RTL | ensure the host implementation is independent (04.05 §10) |
| A counter exists in fabric that nothing reads | dead telemetry | delete it or wire it to an alarm |
| A fabric feature is guarded by a host-writable enable that is always on | untested configuration space | remove the enable |

---

## Further reading

- [01-tick-to-trade-pipeline.md](01-tick-to-trade-pipeline.md) — the budget this partition exists to protect
- [02-feed-handler-design.md](02-feed-handler-design.md) — gap detection (fabric) vs. gap recovery (host)
- [03-order-book-in-hardware.md](03-order-book-in-hardware.md) — book resync, the one place the host writes the book
- [04-strategy-engine-on-fpga.md](04-strategy-engine-on-fpga.md) — the parameter table, the CPU/FPGA signal model
- [05-order-gateway-and-pre-trade-risk.md](05-order-gateway-and-pre-trade-risk.md) — kill switch, credits, reconciliation
- [../01-fpga-design/04-io-transceivers-and-serdes.md](../01-fpga-design/04-io-transceivers-and-serdes.md) — PCIe hard IP and its latency
- [../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md) — measuring the PCIe boundary properly
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) — what the rings feed
- [../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md) — bitstream versioning, the `VERSION` register
- [../08-nasdaq/](../08-nasdaq/) — session times, Glimpse recovery, drop copy, venue-side risk controls
