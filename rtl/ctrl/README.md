# rtl/ctrl — PCIe control plane

The slow path. This is how a human arms trading, sets risk limits, and sees what
the machine is doing. **Nothing latency-critical crosses this boundary**
(`CLAUDE.md` §1) — but everything here is correctness-critical, because a
control plane that is merely *usually* right is a control plane that arms the
wrong risk limits on a Tuesday.

---

## 1. Files

| File | Purpose |
| --- | --- |
| [`host_ctrl.sv`](host_ctrl.sv) | Control-plane top. Instantiated by `rtl/fpga_top.sv`. **Contains every `pcie_clk` ↔ `core_clk` crossing in the design.** |
| [`csr_regfile.sv`](csr_regfile.sv) | BAR0 register map, arm FSM, watchdog, write protection. `pcie_clk` only, no CDC. |
| [`pcie_wrapper.sv`](pcie_wrapper.sv) | The **only** file containing vendor PCIe primitives, plus the `SIMULATION` stub. |
| [`dma_log_ring.sv`](dma_log_ring.sv) | Audit-record ring to host memory (CAT trail). |
| [`../telemetry/telemetry.sv`](../telemetry/telemetry.sv) | Counter aggregation + latency histogram, read through CSR window `0x800`. |
| [`../telemetry/latency_hist.sv`](../telemetry/latency_hist.sv) | Bucketed fabric-latency histogram. |
| [`../telemetry/telemetry_pkg.sv`](../telemetry/telemetry_pkg.sv) | Telemetry address map + DMA log record layout. **Generate host code from this.** |

Governing manuals: [`00-foundations/04-clocking-reset-and-cdc.md`](../../manuals/00-foundations/04-clocking-reset-and-cdc.md),
[`06-operations/01-build-and-release.md`](../../manuals/06-operations/01-build-and-release.md),
[`06-operations/03-monitoring-and-telemetry.md`](../../manuals/06-operations/03-monitoring-and-telemetry.md),
[`05-optimization/04-measurement-and-profiling.md`](../../manuals/05-optimization/04-measurement-and-profiling.md).

---

## 2. Register map (BAR0)

All registers are 32-bit and naturally aligned. Byte offsets. Access codes:
`RO` read-only, `RW` read-write, `WO` write-only, `W1P` write-1-to-pulse
(self-clearing), `W1C` write-1-to-clear.

Any read outside the map returns **`0xDEAD_C0DE`**, never `0`. A host pointed at
the wrong offset finds out immediately instead of believing a bank of plausible
zeros.

### 2.1 Identity — `0x000`

| Offset | Name | Acc | Reset | Contents |
| --- | --- | --- | --- | --- |
| `0x000` | `BUILD_ID` | RO | param | ⚠ **The arm gate.** |
| `0x004` | `GIT_SHA` | RO | param | First 4 bytes of the commit SHA |
| `0x008` | `BUILD_TIMESTAMP` | RO | param | Unix seconds at synthesis |
| `0x00C` | `MAP_VERSION` | RO | const | `{MAGIC=0x4654, MAJOR, MINOR}` |

> ⚠ **The host refuses to arm trading unless `BUILD_ID` matches the expected
> value**, exactly, and the same for `GIT_SHA` and `MAP_VERSION.MAJOR`. Arming is
> a positive action gated on positive identification. "The card came up, probably
> fine" is not an acceptable state. This closes the most embarrassing production
> failure mode in this domain: a stale or partially-programmed bitstream that
> appears to work, decodes the feed correctly, and applies **last quarter's risk
> limits**. See [`01-build-and-release.md`](../../manuals/06-operations/01-build-and-release.md) §4.

### 2.2 Control and status — `0x010`

| Offset | Name | Acc | Reset | Contents |
| --- | --- | --- | --- | --- |
| `0x010` | `CONTROL` | RW | `0x0000_0002` | ⚠ **reset = kill asserted, trading disabled** |
| `0x014` | `STATUS` | RO | — | see §2.3 |
| `0x018` | `HEARTBEAT` | WO | — | ⚠ watchdog kick; reads back the last value written |
| `0x01C` | `WATCHDOG_CFG` | RO | param | `{warn_ms[15:0], timeout_ms[15:0]}` |
| `0x020` | `KILL_SRC` | RO sticky | `0` | see §2.4 |
| `0x024` | `KILL_COUNT` | RO | `0` | kill activations since reset |
| `0x028` | `HEARTBEAT_AGE` | RO | `0xFFFF` | ms since the last kick |
| `0x02C` | `SCRATCH` | RW | `0` | host-owned; proves the BAR path is alive |
| `0x030` | `PARAM_GEN` | RO | `0` | `{strat_gen[15:0], risk_gen[15:0]}` |
| `0x034` | `PARAM_STATUS` | RO | `0` | per-window valid `[4:0]` / protected `[12:8]`, busy `[16]`, queue-full `[17]` |
| `0x038` | `CFG_ERR` | RO / W1C | `0` | `{err_count[15:0], err_bits[15:0]}` |
| `0x03C` | `ARM_STATE` | RO | `0` | `{window_ms_left[15:0], …, precond_ok[7], fault[6:4], state[2:0]}` |

**`CONTROL` bits**

| Bit | Name | Acc | Meaning |
| --- | --- | --- | --- |
| 0 | `trading_enable` | RW | Effective only while `arm_state == ARMED` |
| 1 | `kill` | RW | ⚠ Writing 1 disarms **immediately**, from any state, no preconditions, no confirmation |
| 2 | `arm_step1` | W1P | First half of the two-step arm |
| 3 | `arm_step2` | W1P | Second half. ⚠ **Must be a separate bus write.** Both bits in one write is rejected as an operator error. |
| 4 | `reset_counters` | W1P | Clears the CSR's own diagnostic counters (see §7) |
| 5 | `credit_return` | W1P | Returns one in-flight order credit to the gateway |
| 6 | `clr_sticky` | W1P | Clears `CFG_ERR` and the sticky telemetry-timeout flag |

**`CFG_ERR` bits** — every one of them is a write the fabric *rejected*.

| Bit | Meaning |
| --- | --- |
| 0 | `PROTECTED` — a write to a protected window while trading was enabled |
| 1 | `QUEUE` — the config write queue overflowed; the host wrote faster than the CDC handshake drains |
| 2 | `ARM_SEQ` — `arm_step2` without `arm_step1`, or both in one write |
| 3 | `ARM_PRE` — arm attempted with preconditions unmet |
| 4 | `UNMAPPED` — write to an unmapped offset |
| 5 | `RING_CFG` — illegal log-ring size |
| 6 | `TELEM_TO` — a telemetry read timed out in the core domain |

`ARM_STATE.state`: `0` DISARMED, `1` STEP1, `2` ARMED, `3` FAULT.
`ARM_STATE.fault`: `1` both arm bits / step1 twice, `2` step2 without step1,
`3` preconditions unmet. A FAULT clears only on an explicit `CONTROL.kill` write
— a fault that clears itself teaches the operator nothing.

### 2.3 `STATUS` (`0x014`)

| Bit | Meaning |
| --- | --- |
| 2:0 | `link_up` `{oe, md_b, md_a}` — mirrored from the core telemetry STATUS word |
| 3 | `kill_active` — the fabric's kill state, **authoritative** |
| 6:4 | `kill_src` (`kill_src_e`) |
| 7 | `pcie_link_up` |
| 8 | `core_alive` — the `core_clk` domain is running |
| 11:9 | `arm_state` |
| 12 | `trading_en_effective` |
| 13 | ⚠ `watchdog_expired` |
| 14 | `params_valid` — every window committed and marked valid |
| 15 | `cfg_wr_busy` — the config write path is not drained |
| 16 / 17 / 18 / 19 / 20 | `risk_valid` / `strat_valid` / `filter_valid` / `tmpl_valid` / `session_valid` |
| 21 | ⚠ `log_drop_sticky` — audit records were **lost** |
| 22 | `telem_timeout_sticky` |
| 23 | `cfg_err_sticky` |
| 24 | `watchdog_warn` |

### 2.4 `KILL_SRC` (`0x020`) — sticky, cleared only by reset

| Bit | Meaning |
| --- | --- |
| 2:0 | `last_kill_src` — provenance of the **most recent** kill |
| 3 | `kill_active` (live) |
| 10:8 | `first_kill_src` — provenance of the **first** kill since reset. ⚠ In a cascade the first cause is what you need; the last one is usually just the consequence. |
| 23:16 | `ever_mask` — bit *n* set = `kill_src_e` value *n* has fired at least once. A source that has never fired is a control you have never actually tested. |

### 2.5 DMA audit log ring — `0x040`

| Offset | Name | Acc | Reset | Contents |
| --- | --- | --- | --- | --- |
| `0x040` | `LOG_RING_BASE_LO` | RW | `0` | Host physical address, forced 64 B aligned |
| `0x044` | `LOG_RING_BASE_HI` | RW | `0` | |
| `0x048` | `LOG_RING_SIZE` | RW | `0` | `[4:0]` = log2(entries), 8…22. `0` = disabled |
| `0x04C` | `LOG_RING_HEAD` | RO | `0` | Fabric produce pointer, in **records** |
| `0x050` | `LOG_RING_TAIL` | RW | `0` | Host consume pointer, in **records** |
| `0x054` | `LOG_DROP_CNT` | RO | `0` | ⚠ **ALERTABLE.** Audit records lost. |
| `0x058` | `LOG_REC_CNT` | RO | `0` | Records delivered |
| `0x05C` | `LOG_CTRL` | RW | `0` | `[0]` `ring_en`, `[1]` W1P clear drop-sticky |
| `0x060` | `LOG_FULL_CNT` | RO | `0` | Host-too-slow episodes |
| `0x064` | `TELEM_ERR_CNT` | RO | `0` | Telemetry read timeouts |

Occupancy is `head - tail` in unsigned 32-bit arithmetic, which wraps correctly.
The ring is full when occupancy reaches `2^LOG_RING_SIZE`.

### 2.6 Config write windows — `0x100` … `0x5FF`

Five windows, identical layout. `X` = window base.

| `X+` | Name | Acc | Reset | Contents |
| --- | --- | --- | --- | --- |
| `0x00` | `ADDR` | RW | `0` | Entry address; auto-increments after each `DATA` write |
| `0x04` | `DATA` | WO | — | Pushes `{target, ADDR, wdata}` across to the fabric |
| `0x08` | `CTRL` | RW | `1` | `[0]` auto_inc, `[1]` W1P reset_chk, `[2]` W1P commit, `[3]` W1P zero_addr, `[4]` W1P mark_valid |
| `0x0C` | `GEN` | RO | `0` | `{word_count[15:0], generation[15:0]}` |
| `0x10` | `WR_CHK` | RO | seed | Running write-side checksum |
| `0x14` | `CMT_CHK` | RO | `0` | Checksum latched at the last commit |
| `0x18` | `STATUS` | RO | `0` | `{protected[17], valid[16], word_count[15:0]}` |

| Base | Window | Address stride | Protected while trading enabled? | Commit? |
| --- | --- | --- | --- | --- |
| `0x100` | Symbol filter | 1 word per locate, `0 … N_SYMBOLS-1` | ⚠ **Yes** | no |
| `0x200` | Risk parameters | `sym * RISK_WORDS_PER_SYM(12) + word` | ⚠ **Yes** | yes |
| `0x300` | Strategy parameters | `sym * STRAT_WORDS_PER_SYM(8) + word` | **No** — see below | yes |
| `0x400` | OUCH templates | 1 word per template word | ⚠ **Yes** | no |
| `0x500` | TCP / SoupBinTCP session | running word index | ⚠ **Yes** | no |

> The **strategy** window is deliberately unprotected. `sym_strat_t` carries
> `fair_value`, which the host updates at millisecond cadence *while trading*
> (see `rtl/pkg/trading_pkg.sv`). Protecting it would make the strategy
> unusable. **⚠ This asymmetry is the reason risk limits and strategy parameters
> live in separate windows with separate commits. Never move a risk limit into
> the strategy window.**

### 2.7 Telemetry read window — `0x800` … `0xBFC`

256 words, read-only, proxied to `telem_raddr` / `telem_rdata` in the core clock
domain. Word index = `(offset - 0x800) >> 2`. The map is defined in
[`../telemetry/telemetry_pkg.sv`](../telemetry/telemetry_pkg.sv) and documented
in [`../telemetry/telemetry.sv`](../telemetry/telemetry.sv).

A read that the core domain does not answer within `TELEM_TIMEOUT` cycles
returns **`0xDEAD_DEAD`**, increments `TELEM_ERR_CNT`, and sets `STATUS[22]`.
The PCIe read is always answered — a hung read would wedge the host.

⚠ Two addresses in that window have **read side effects**:
`0x0004 SNAP` latches the whole counter bank, and `0x0005 HIST_CLEAR` zeroes the
latency histogram. Read protocol:

1. read `SNAP`, note the returned sequence number
2. read the words you want, in any order
3. read `SNAP_SEQ` and confirm it still equals step 1's value

Counters read without snapshotting describe a set of values that never
coexisted.

---

## 3. Startup sequence — **order matters**

Run by the host control process at start of day, or after any bitstream load.
**Every step is a gate: if it fails, stop. Do not proceed and do not retry past
a mismatch.**

1. **Wait for PCIe link.** `STATUS[7] == 1`. Then confirm `STATUS[8] core_alive
   == 1` — the `core_clk` domain is running.
2. **⚠ Verify `BUILD_ID`.** Read `0x000`, `0x004`, `0x00C`. Compare against the
   expected build record (`manifest.json`, see
   [`01-build-and-release.md`](../../manuals/06-operations/01-build-and-release.md) §3).
   **Any mismatch aborts start of day.** Nothing below this line runs against an
   unidentified bitstream.
3. **Confirm the safe state.** `CONTROL` reads `0x0000_0002`, `STATUS[3]
   kill_active == 1`, `STATUS[12] trading_en == 0`, `PARAM_GEN == 0`. A card that
   comes up in any other state has been touched by something else — investigate,
   do not adopt it.
4. **Configure the audit ring.** Write `LOG_RING_BASE_LO/HI`, `LOG_RING_SIZE`,
   then `LOG_CTRL.ring_en = 1`. Do this *before* loading parameters so the
   parameter commits themselves are captured in the audit trail.
5. **Load the symbol filter table.** `FILTER_CTRL.zero_addr`, then
   `FILTER_CTRL.reset_chk`, then stream `FILTER_DATA` writes. Finish with
   `FILTER_CTRL.mark_valid`.
6. **Load risk parameters.** `RISK_CTRL.zero_addr`, `RISK_CTRL.reset_chk`, then
   stream `RISK_DATA`. Poll `STATUS[15] cfg_wr_busy` if you are writing faster
   than ~1 word per 30 ns; a `CFG_ERR[1]` means you overran the queue and **the
   table is incomplete**.
7. **Commit risk.** `RISK_CTRL.commit`.
8. **⚠ Read back and verify.** Read `RISK_GEN` (must have incremented) and
   `RISK_CMT_CHK`. Compare `RISK_CMT_CHK` against the checksum the host computed
   over the words it intended to send (§6). **A mismatch means the fabric does
   not hold what you think it holds — abort.**
9. **Load strategy parameters**, then `STRAT_CTRL.commit`.
10. **Verify strategy**: `STRAT_GEN` incremented, `STRAT_CMT_CHK` matches.
11. **Configure the OUCH templates** (`0x400`) and the **session** (`0x500`);
    `mark_valid` each. Confirm `STATUS[19]` and `STATUS[20]`.
12. **Confirm `params_valid`.** `STATUS[14] == 1`. If it is 0, some window was
    never marked valid — find out which via `PARAM_STATUS[4:0]`.
13. **Start the heartbeat.** Write `HEARTBEAT` at ≥ 10 Hz, recommended 50 Hz, and
    keep writing it for as long as the card is powered. Confirm
    `HEARTBEAT_AGE` drops and `STATUS[13]` clears.
14. **Confirm the order-entry session is up.** `STATUS[2] == 1` (and the venue
    session state via the telemetry window).
15. **⚠ Two-step arm.** Write `CONTROL.arm_step1`. Read `ARM_STATE`; confirm
    `state == 1 (STEP1)` and `precond_ok == 1`. Then, **as a separate bus
    write**, write `CONTROL.arm_step2`. Read `ARM_STATE` and confirm
    `state == 2 (ARMED)` and `STATUS[3] kill_active == 0`.
    The step1 → step2 window is `ARM_WINDOW_MS` (default 5 s); after that it
    reverts to DISARMED and you start again.
16. **Enable trading.** Write `CONTROL.trading_enable = 1` (with `kill = 0`).
    Confirm `STATUS[12] == 1`.
17. **Verify the audit trail is flowing.** `LOG_REC_CNT` is advancing,
    `LOG_DROP_CNT == 0`, `STATUS[21] == 0`. You should already see the
    `LOG_ARM`, `LOG_PARAM_COMMIT` and `LOG_TRADING_EN` records from steps 7–16.

Why the order is what it is: **the fabric refuses to arm until every window is
committed and valid and the heartbeat is live** (`arm_precond_ok`). Attempting
step 15 early does not fail quietly — it drives the arm FSM to FAULT and sets
`CFG_ERR[3]`, which is a louder and more useful failure than a silent no-op.

### 3.1 Changing a risk limit while the desk is live

1. `CONTROL.trading_enable = 0` — confirm `STATUS[12] == 0`
2. `RISK_CTRL.reset_chk`, `RISK_CTRL.zero_addr`, stream the new values
3. `RISK_CTRL.commit`
4. read back `RISK_GEN` and `RISK_CMT_CHK` and **verify**
5. `CONTROL.trading_enable = 1`

Writing risk parameters without step 1 changes nothing and sets `CFG_ERR[0]`.

> ⚠ **This is the mechanism that supports four-eyes approval; it is not
> four-eyes approval.** The fabric guarantees the sequence cannot be bypassed by
> writing directly to the BAR. Requiring a *second authenticated human* before
> the host tool performs the sequence is a **host-side control** and must be
> implemented there. What the hardware provides is the enforcement point that
> makes that control meaningful, plus an unambiguous audit boundary: every limit
> change appears in the ring as a `LOG_TRADING_DIS` → `LOG_PARAM_COMMIT`
> (carrying the checksum and the new generation) → `LOG_TRADING_EN` triple.

---

## 4. Shutdown sequence

1. `CONTROL.trading_enable = 0`. Confirm `STATUS[12] == 0`.
2. Wait for in-flight orders to resolve: watch `order_stat` in the telemetry
   window until outstanding count reaches zero, or cancel them explicitly.
3. `CONTROL.kill = 1`. Confirm `STATUS[3] kill_active == 1` and
   `ARM_STATE.state == 0`.
4. **Drain the audit ring**: keep advancing `LOG_RING_TAIL` until
   `LOG_RING_HEAD == LOG_RING_TAIL`. Record `LOG_DROP_CNT` and `LOG_FULL_CNT` in
   the end-of-day report **before** clearing anything.
5. Take a final telemetry snapshot (`SNAP`, then read the whole bank) and archive
   it with the day's records. **Read `LAT_OVER` and `LAT_MAX` alongside the
   buckets** — a non-zero `LAT_OVER` means the day's p99.9 is a lower bound.
6. Log every sticky bit and every counter value, then optionally clear
   `LOG_CTRL[1]` and `CONTROL.clr_sticky`. ⚠ Log first, clear second — always.
7. `LOG_CTRL.ring_en = 0`.
8. **Stop the heartbeat last.** Stopping it earlier fires the watchdog and
   produces a `LOG_WATCHDOG` record that will read as an incident in tomorrow's
   review.
9. Run the **zero-counter report**: list every counter that stayed at zero all
   day and justify each one. A counter that never moves is a bug you have not
   found yet.

---

## 5. The watchdog contract

| Parameter | Default | Meaning |
| --- | --- | --- |
| host write cadence | ≥ 10 Hz, **recommended 50 Hz** | Any value written to `HEARTBEAT` (`0x018`) |
| `WATCHDOG_WARN_MS` | 50 ms | `STATUS[24]` sets. Tier-1 alert. |
| `WATCHDOG_MS` | 100 ms | ⚠ **Forced disarm.** `arm_state → DISARMED`, kill asserted, `LOG_WATCHDOG` record emitted. |

**⚠ Reset state is KILLED.** `HEARTBEAT_AGE` resets to `0xFFFF` — already past
the timeout — so a freshly reset or freshly configured card is watchdog-expired
and **cannot be armed** until the host has established a live heartbeat. There is
no window in which a rebooting host leaves an armed card behind.

**The watchdog blocks; it does not merely warn.** A dead host process means no
position accounting, no reconciliation, and no human able to act. Three
independent mechanisms enforce this, and none of them depends on the other two:

1. `csr_regfile` disarms and asserts `kill` in the `pcie_clk` domain.
2. `host_ctrl` stops forwarding heartbeat pulses, so `risk_gate`'s own watchdog
   in the `core_clk` domain fires — that one is authoritative and is what
   actually blocks order flow within `KILL_RESP_CYCLES`.
3. **⚠ The frozen-clock guard.** If `pcie_clk` itself stops — host power loss,
   `PERST#`, surprise link down — the 2-FF synchronizers carrying
   `cfg_trading_en` and `cfg_kill` would faithfully *hold their last values*,
   leaving the card armed with nobody home. `host_ctrl` therefore runs a
   liveness toggle from the PCIe domain into the core domain; if it stops for
   `2^PCIE_DEAD_LOG2` core cycles (~52 µs), the **core domain** forces
   `cfg_kill = 1`, `cfg_trading_en = 0` and suppresses the heartbeat, entirely
   on its own. This is the failure mode that correct synchronizer design does
   *not* protect against, and it is asserted in `host_ctrl.sv`.

`pcie_rst` (link down / host reboot) also resets the whole CSR block, which
returns it to `CONTROL = 0x0000_0002` — killed and disarmed.

---

## 6. The write-side checksum

Both the fabric and the host compute, over every word pushed through a window
since the last `reset_chk`:

```
chk = 0xA5A5_5A5A                            # LOG_CHK_SEED
for each (addr, data) written, in order:
    chk = rotl32(chk, 1) ^ data ^ (addr & 0xFFFF)
```

`WR_CHK` is the running value; `CMT_CHK` is the value latched at the moment the
commit pulse fired. Comparing the host's own computation against `CMT_CHK`
verifies the **transport**: it catches a corrupted, dropped, duplicated or
reordered BAR write, which are the failure modes the PCIe path actually has.

> **Open item (level-2 verification).** To also verify **storage** — that the
> risk gate holds what the CSR forwarded — `risk_gate` and `strategy_engine`
> should compute a parameter checksum over their *live* tables using the same
> `telemetry_pkg::log_chk32` fold and expose it in `risk_stat[]` / `strat_stat[]`
> (`param_crc`, per [`03-monitoring-and-telemetry.md`](../../manuals/06-operations/03-monitoring-and-telemetry.md) §2.4).
> The host then compares three values: its own, `CMT_CHK`, and the fabric's.
> Until those blocks implement it, step 8 of the startup sequence verifies the
> transport only — which is worth doing, and is not the same as verifying the
> tables.

---

## 7. Counters, clearing, and what `reset_counters` does *not* do

`CONTROL[4] reset_counters` clears **only the CSR's own diagnostic counters**
(`CFG_ERR` count, `TELEM_ERR_CNT`, `KILL_COUNT`, per-window word counts).

It does **not** clear the fabric counters in `telemetry`, and there is no port in
the `fpga_top` contract by which it could. That is deliberate and correct:
fabric counters are free-running and the host computes deltas between snapshots.
Clear-on-read and host-triggered clears lose every event between the read and the
clear, and two collectors each see part of the truth
([`03-monitoring-and-telemetry.md`](../../manuals/06-operations/03-monitoring-and-telemetry.md) §9).

The latency histogram is the one exception, cleared at start of day only via the
telemetry window's `HIST_CLEAR` address. ⚠ Clearing it discards in-flight
samples; prefer host-side differencing.

---

## 8. Simulation

`pcie_wrapper.sv` replaces the vendor IP under `` `ifdef SIMULATION ``, so the
**entire design simulates in Verilator with no vendor IP present**. The
testbench drives the register port by hierarchical name:

```python
# cocotb
p = dut.u_host_ctrl.u_pcie
p.sim_reg_addr.value  = 0x010
p.sim_reg_wdata.value = 0x0000_0002
p.sim_reg_we.value    = 1          # one cycle
...
p.sim_dma_ready.value = 0          # model a slow host and force the ring to
                                   # drop, so the gap-marker path is TESTED
```

Lint and simulate with `verilator -Wall +define+SIMULATION`. Without the define
the vendor instance is elaborated and the build requires the checked-in `.xci`;
that is the synthesis path only.

The stub models PCIe enumeration delay (`link_up` asserts 64 cycles after reset)
so a startup-sequence test that assumes an instantly-up link fails, as it should.

---

## 9. CDC

Every `pcie_clk` ↔ `core_clk` crossing in the design lives in `host_ctrl.sv` and
uses one of the four sanctioned primitives from `rtl/common/`. The complete
16-entry inventory, with the reasoning for each primitive choice, is the table in
that file's header. Summary:

| Class | Primitive | Used for |
| --- | --- | --- |
| Slowly-changing level | `cdc_sync_bit(2)` | `cfg_trading_en`, `cfg_kill`, both liveness toggles |
| Single-cycle pulse | `cdc_pulse` | heartbeat, credit return, both commits |
| Wide + infrequent | `cdc_handshake` | config writes, telemetry read/return, STATUS mirror, `{kill_active, kill_src}`, audit events, drop count |
| High-rate bus | `async_fifo` | audit record payload |

Two choices worth understanding rather than copying:

* `kill_active` and `kill_src` cross **together, as one 4-bit handshake payload**.
  Crossing them separately and recombining them at the destination is
  reconvergence: the PCIe side would momentarily latch "killed" alongside a stale
  source, and `KILL_SRC` — the register you read after an incident to find out
  *why* — would name the wrong cause.
* All five config-write targets share **one** handshake, serialized. Five
  parallel crossings would be five reconvergence opportunities, and serializing
  makes the ordering between a parameter write and its commit pulse structural
  rather than a host-timing assumption. The commit pulse is additionally held
  until the write path has provably drained.

⚠ Constrain these in `constraints/cdc.xdc` with `set_max_delay -datapath_only`
plus `set_bus_skew` on every handshake data bus. **Never `set_false_path` a CDC
bus** — the router will then place one bit 8 ns away and another 0.5 ns away, and
handshake-protected data gets captured torn.

---

## 10. Open items

These are real gaps, stated rather than papered over.

1. **⚠ Fast-path audit records are not yet wired.** `dma_log_ring` currently
   carries **control-plane records only** (arm, disarm, kill with provenance,
   parameter commit with checksum, watchdog, trading enable/disable). The
   order-decision, fill and risk-rejection records originate at `u_risk_gate` and
   `u_order_gw` and the `host_ctrl` port list in the present `fpga_top.sv`
   carries no path for them. Closing it needs one additive change to `fpga_top`:
   pass `{log_valid, log_rec, cycle_cnt}` into `host_ctrl` from an arbiter over
   the risk gate and the order gateway. **Until then the CAT trail is
   incomplete**, and a partial audit trail that looks complete is worse than
   none. Details and the exact port list are in `host_ctrl.sv`'s header.
2. **`rtl/common/` primitives are assumed, not yet present.** `cdc_sync_bit`'s
   port list is fixed by `fpga_top.sv` and the CDC manual. `cdc_pulse`,
   `cdc_handshake` and `async_fifo` are instantiated here against the port lists
   documented in `host_ctrl.sv` and `dma_log_ring.sv`; reconcile before the first
   build. In particular: `cdc_handshake` is assumed to use a standard
   valid/ready handshake (`src_ready` high = idle, transfer on
   `src_valid && src_ready`, payload registered by the primitive), and
   `async_fifo` is assumed **non-FWFT** (`FIFO_FWFT` parameter selects the other
   behaviour).
3. **`pcie_wrapper`'s vendor instance is a template.** The module name and port
   list must come from the checked-in `.xci`, not from this file. The clocking
   contract — `clk_rst_gen` owning `pcie_clk` rather than the PCIe core emitting
   `user_clk` — must be verified against the IP configuration before bring-up.
4. **Parameter-table `param_crc` in `risk_gate` / `strategy_engine`** — see §6.
5. **`pcie_err_cnt`, link speed and link width** are produced by `pcie_wrapper`
   but not yet surfaced in the CSR map; they should land in the reserved space at
   `0x068`.
6. **No testbench yet.** `CLAUDE.md` §4: every module gets one. Minimum coverage
   before this is deployable: the startup sequence end-to-end, the arm FSM's
   reject paths, the write-protection reject path, the watchdog timeout, the
   frozen-`pcie_clk` guard, and the ring drop / gap-marker path with
   `sim_dma_ready` held low.
