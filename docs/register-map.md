# Register Map — Host Software Contract

> The BAR0 control-plane contract between the host and the fabric: what the host may
> write, what it may read, what every reset value is, and in what order the writes are
> legal. This is the document a driver author, a control-daemon author, and an incident
> responder all read.
> Governing manuals:
> [`../manuals/04-system-architecture/06-cpu-fpga-partitioning.md`](../manuals/04-system-architecture/06-cpu-fpga-partitioning.md) §4
> and [`../manuals/06-operations/03-monitoring-and-telemetry.md`](../manuals/06-operations/03-monitoring-and-telemetry.md).
> Task: [`../TASKS.md`](../TASKS.md) P7.2.

---

## ⚠️ PROVISIONAL — READ THIS BEFORE USING ANY OFFSET

> **This document is PROVISIONAL and hand-maintained. It is not a generated artifact,
> and there is no CI check that it agrees with the RTL.**
>
> `docs/regmap.yaml` and `scripts/gen_regmap.py` **do not exist**. Until they do, this
> file, [`../rtl/ctrl/csr_regfile.sv`](../rtl/ctrl/csr_regfile.sv)'s header comment,
> [`../rtl/telemetry/telemetry_pkg.sv`](../rtl/telemetry/telemetry_pkg.sv)'s address map,
> and whatever the host code believes are **four hand-maintained copies of the same
> contract**, and nothing forces them to agree.
>
> [`../TASKS.md`](../TASKS.md) **P7.2** states the rule this document is waiting on:
> *"Define the control register map in **one** machine-readable source (YAML), and
> generate from it: the SystemVerilog register file, the C++ accessor header, the
> documentation table, and the CI check that RTL and host agree. Hand-maintained
> register maps drift, and the drift is discovered at 3 a.m."*
>
> ⚠️ **A drifted register map does not fail loudly.** The host writes a risk limit to
> what it believes is `RISK_DATA` and the fabric stores it as something else — or
> stores it for the wrong symbol. Every subsequent order is judged against a limit
> nobody set. The system keeps trading, the dashboard looks normal, and the first
> symptom is a fill you cannot explain. This is why P7.2 is scheduled *"day one, in
> parallel with all RTL"* and not at the end.
>
> **Two documented drifts already exist. See §10 (D2, D3). Both are live today.**

### What is real, and what is proposed

| Element | Status |
| --- | --- |
| `rtl/ctrl/csr_regfile.sv` | ✅ **Exists** (1,271 lines). Offsets, reset values, bit layouts and the arm FSM below are transcribed from it and from its header table. |
| `rtl/ctrl/pcie_wrapper.sv` | ✅ Exists. Source of the BAR geometry in §1. |
| `rtl/ctrl/dma_log_ring.sv` | ✅ Exists. Source of the ring register semantics. |
| `rtl/telemetry/telemetry_pkg.sv` | ✅ Exists. **Authoritative** for the telemetry window sub-map in §8. |
| `rtl/ctrl/host_ctrl.sv` | ❌ **Does not exist.** `fpga_top.sv` instantiates `host_ctrl`, which owns all CDC and connects the CSR to the fabric. Until it exists, no `cfg_*` signal actually reaches the core clock domain. |
| `rtl/ctrl/README.md` | ❌ Does not exist, though `csr_regfile.sv` line 18 says *"the full table … are in rtl/ctrl/README.md — that file and this header must agree."* |
| `docs/regmap.yaml`, `scripts/gen_regmap.py` | ❌ Do not exist. The reason for the PROVISIONAL banner. |
| BAR size, page allocation above `0x0600` | 🟡 **Proposed.** Reserved ranges in §2 are this document's proposal. |
| DMA ring descriptor format | 🟡 **Proposed.** Only the control registers exist; the descriptor/record layout lives in `telemetry_pkg::log_rec_t`. |

> ⚠️ A **second, different** register map exists in
> [`../manuals/04-system-architecture/06-cpu-fpga-partitioning.md`](../manuals/04-system-architecture/06-cpu-fpga-partitioning.md) §4
> (`ID` at `0x0000`, `CTRL` at `0x0020`, `KILL_SET` at `0x0040`, `SYM_SEL` at `0x0100`,
> `LAT_HIST` at `0x0600`…). It is a **manual** — a description of the shape a map of
> this kind takes — and it does **not** match the implemented `csr_regfile.sv`. Where
> they differ, **the RTL wins**, and `docs/regmap.yaml` must reconcile them so that
> only one survives. Do not code a driver against the manual's table.

---

## 1. Conventions

| Property | Value | Source |
| --- | --- | --- |
| Aperture | **BAR0**, 64 KiB, non-prefetchable | `pcie_wrapper.sv` `BAR_ADDR_W = 16` |
| Transport | PCIe Gen3 x16 hard block → AXI4-Lite master → `csr_regfile` | `pcie_wrapper.sv` |
| Outstanding transactions | **1** — the CSR never sees a second access before the first completes | `pcie_wrapper.sv`; makes side-effect ordering trivially correct |
| Register width | **32 bits**, all of them | `csr_regfile.sv` |
| **Addressing** | **BYTE addresses**, naturally aligned; `reg_addr[1:0]` is always `2'b00` | `pcie_wrapper.sv` `reg_addr` is a byte address |
| Endianness | Little-endian | |
| Clock domain | **`pcie_clk` (250 MHz)**. `csr_regfile` contains **no CDC**; every crossing to `core_clk` is done by `host_ctrl`. | `csr_regfile.sv` header |
| Unmapped read | **`0xDEAD_C0DE`** — never `0x0000_0000` | `csr_regfile.sv` `CSR_UNMAPPED` |
| Telemetry read timeout | **`0xDEAD_DEAD`** after `TELEM_TIMEOUT = 4096` pcie cycles, plus a sticky error | `csr_regfile.sv` `CSR_TELEM_TO` |
| Unmapped write | Ignored, sets `CFG_ERR[4]`, increments the reject count | `csr_regfile.sv` `E_UNMAPPED` |

> ⚠️ The unmapped sentinel is `0xDEAD_C0DE` and **not zero on purpose**. A host pointed
> at the wrong offset — wrong BAR, wrong page, stale header — reads a value that is
> obviously wrong instead of a plausible zero. A map that returns `0` for unmapped reads
> tells a driver that every limit is set to zero and every counter is quiet, which is
> exactly what a healthy idle system looks like.

### Access types

| Code | Meaning |
| --- | --- |
| `RO` | Read-only. Writes are ignored (and counted if the offset is unmapped). |
| `RW` | Read/write. |
| `WO` | Write-only. Reads return `0` or an unrelated status word — never assume a WO register reads back what you wrote. |
| `W1P` | Write-1-to-**pulse**. The bit is not stored; writing `1` emits a single-cycle event. Reads as `0`. |
| `RW1C` | Read, then write `1` to that bit position to clear it. Used for sticky error flags. |
| `RO-sticky` | Read-only, sets on first occurrence, cleared only by reset (or by an explicit `clr_sticky` where noted). |

### The reset-value rule

> **Every reset value must be the safe value.** Fail-closed, without exception.

This is the hard rule from [`../CLAUDE.md`](../CLAUDE.md) §5 rule 4, enforced in
`fpga_top.sv` by a top-level assertion (`core_rst |-> !cfg_trading_en`) and realized in
the CSR by three specific choices, each of which is a decision and not an accident:

| Register | Reset | Why that is the safe value |
| --- | --- | --- |
| `CONTROL` | **`0x0000_0002`** | Bit 0 `trading_enable` = **0**; bit 1 `kill` = **1**. The device comes out of reset **killed and disabled**. |
| `HEARTBEAT_AGE` | **`0xFFFF`** | Already past `WATCHDOG_MS`. A freshly configured or freshly reset card is **watchdog-expired** and cannot be armed until the host has established a live heartbeat. There is no window in which a rebooting host leaves an armed card behind. |
| All limits, all parameter windows | **`0`** / not-valid | `sym_risk_t` all-zero means every limit is zero, which blocks every order. `trade_state_e`'s reset value is `TRADE_DISABLED = 3'd7`. |

⚠️ The dangerous inversion to watch for in any future edit: a reset value of `0` is safe
for a *limit* and catastrophic for a *kill bit*. `CONTROL` is the one register in this
map whose safe reset is **not** all-zeros, which is exactly why it is `0x0000_0002` and
why that constant deserves a comment wherever it appears.

---

## 2. Address map overview

| Region | Byte range | Page | Purpose | Status |
| --- | --- | :-: | --- | :-: |
| Identity / version | `0x000`–`0x00F` | `0x00` | Build ID, git SHA, build timestamp, map version | RTL |
| Global control & status | `0x010`–`0x03F` | `0x00` | Arm/disarm, kill, heartbeat, arm state, config errors | RTL |
| DMA log ring | `0x040`–`0x064` | `0x00` | Audit ring base/size/head/tail/drops | RTL |
| *reserved* | `0x068`–`0x0FF` | `0x00` | — | proposed |
| Symbol filter window | `0x100`–`0x118` | `0x01` | locate → active-index table | RTL |
| Risk parameter window 🔒 | `0x200`–`0x218` | `0x02` | `sym_risk_t`, **write-protected while enabled** | RTL |
| Strategy parameter window | `0x300`–`0x318` | `0x03` | `sym_strat_t`, **not** protected | RTL |
| OUCH template window | `0x400`–`0x418` | `0x04` | per-symbol Enter/Cancel templates, protected | RTL |
| Session config window | `0x500`–`0x518` | `0x05` | TCP 5-tuple, ISN, window; protected | RTL |
| *reserved* | `0x600`–`0x7FF` | `0x06`–`0x07` | future windows | proposed |
| **Telemetry read window** | **`0x800`–`0xBFC`** | `0x08`–`0x0B` | 256-word RO counter/histogram window | RTL |
| *reserved* | `0xC00`–`0xFFFF` | | — | proposed |

Page decode is `reg_addr[15:8]`; the telemetry window is decoded as
`reg_addr[15:10] == 6'b0000_10`, i.e. exactly `0x800`–`0xBFF`.

All five config windows share **one identical 7-register layout**, so a driver needs one
routine parameterized by page base:

| Window offset | Name suffix | Access |
| --- | --- | --- |
| `+0x00` | `_ADDR` | RW |
| `+0x04` | `_DATA` | WO |
| `+0x08` | `_CTRL` | RW / W1P |
| `+0x0C` | `_GEN` | RO |
| `+0x10` | `_WR_CHK` | RO |
| `+0x14` | `_CMT_CHK` | RO |
| `+0x18` | `_STATUS` | RO |

---

## 3. Identity and version — `0x000`–`0x00F`

| Offset | Name | Access | Reset | Width | Description |
| --- | --- | :-: | --- | ---: | --- |
| `0x000` | `BUILD_ID` | RO | `BUILD_ID` parameter (`32'hDEAD_0000`) | 32 | ⚠️ **THE ARM GATE.** Hash of the source tree and toolchain, burned into the fabric. |
| `0x004` | `GIT_SHA` | RO | `GIT_SHA` parameter (`32'h0000_0000`) | 32 | First 4 bytes of the commit SHA. |
| `0x008` | `BUILD_TIMESTAMP` | RO | `BUILD_TIMESTAMP` parameter (`32'h0000_0000`) | 32 | Unix seconds at synthesis. ⚠️ See D5 in §10 — `fpga_top.sv` does not pass this parameter down, so it currently reads `0`. |
| `0x00C` | `MAP_VERSION` | RO | `{16'h4654, MAJOR, MINOR}` | 32 | `{MAGIC "FT", TELEM_MAP_MAJOR, TELEM_MAP_MINOR}`. The host **refuses to collect telemetry** if `MAJOR` does not match its expectation. Bump `MINOR` for additive changes into reserved space; bump `MAJOR` for anything that moves or redefines an existing word. |

**The build-ID gate** — [`../TASKS.md`](../TASKS.md) **P7.13** and **P10.5**:

> P10.5: *"the bitstream embeds a hash of its source tree and toolchain; a register
> exposes it; the daemon reads it, compares against the **signed release manifest**, and
> **refuses to arm** on a mismatch. 'Which bitstream is actually running?' must never be
> a question anyone has to investigate."*
>
> P7.13 pairs it with the configuration: the daemon *"reads the bitstream build ID from
> a register, hashes the loaded configuration, and refuses to arm if **either** doesn't
> match what the release manifest says should be running."*

Step 2 of the start-of-day sequence is therefore: read `BUILD_ID` / `GIT_SHA` /
`BUILD_TIMESTAMP`, compare against the signed manifest, **abort if they differ**. Not
warn — abort. `Build ID ≠ expected` is a **Tier 1 page-immediately** alert in
[`../manuals/06-operations/03-monitoring-and-telemetry.md`](../manuals/06-operations/03-monitoring-and-telemetry.md) §7.

---

## 4. Global control and status — `0x010`–`0x03F`

### 4.1 `CONTROL` — `0x010`, RW, reset **`0x0000_0002`**

| Bit | Name | Access | Reset | Description |
| ---: | --- | :-: | :-: | --- |
| 0 | `trading_enable` | RW | **0** | Master trading enable. Effective only when also `ARMED` (see `STATUS[12]`). |
| 1 | `kill` | RW | **1** | ⚠️ **Reset = KILL ASSERTED.** Writing `1` asserts the kill immediately and stops all outbound order flow within `KILL_RESP_CYCLES = 4`. Writing `0` releases the *host* kill source only — it does **not** arm anything. |
| 2 | `arm_step1` | W1P | — | First half of the two-step arm. |
| 3 | `arm_step2` | W1P | — | Second half. ⚠️ **Must be a separate bus write.** Both bits in one write is rejected as an operator error and drives `ARM_FAULT`. |
| 4 | `reset_counters` | W1P | — | Clears the telemetry counter bank. |
| 5 | `credit_return` | W1P | — | Returns in-flight order credit (`cfg_credit_return`). |
| 6 | `clr_sticky` | W1P | — | Clears the sticky error flags in `STATUS` and `CFG_ERR`. |
| 31:7 | reserved | — | 0 | Write `0`. |

> ⚠️ **ADR 0009 — ARMED-AT-RESET, and why the reset value of a kill bit is `1`.**
> The kill switch is asserted out of reset, so the *only* way to reach a trading state is
> a deliberate, verified, multi-step sequence. The alternative — kill clear at reset,
> armed by writing `1` — means every reset, every hot-reset, every configuration reload,
> and every glitched `PERST#` momentarily produces a card that is not killed. There is
> no such window here. The same reasoning drives `HEARTBEAT_AGE`'s reset of `0xFFFF`:
> a card that has just come up has, by construction, no live host supervising it, so it
> must behave exactly as it would if the host had died.
>
> Consequence, and it is a real one: **an operator who resets the card mid-session must
> re-run the whole arming sequence**, including parameter reload and read-back
> verification. That is the intended cost. See §9.

### 4.2 `STATUS` — `0x014`, RO

| Bit(s) | Name | Description |
| ---: | --- | --- |
| 2:0 | `link_up` | `{oe_link_up, md_link_up[1], md_link_up[0]}`, mirrored from the core telemetry `STATUS` word. |
| 3 | `kill_active` | The fabric's kill state — **authoritative**, from `risk_gate`. |
| 6:4 | `kill_src` | Live `kill_src_e`. See §7. |
| 7 | `pcie_link_up` | |
| 8 | `core_alive` | `core_clk` domain is running. ⚠️ If this is `0`, every other core-sourced bit in this word is stale. |
| 11:9 | `arm_state` | `0 = DISARMED`, `1 = STEP1`, `2 = ARMED`, `3 = FAULT`. |
| 12 | `trading_en_effective` | `CONTROL[0] AND armed`. **This**, not `CONTROL[0]`, is whether the system can trade. |
| 13 | `watchdog_expired` | ⚠️ Host heartbeat stale. |
| 14 | `params_valid` | All five windows committed **and** marked valid. |
| 15 | `cfg_wr_busy` | The config write path has not drained. |
| 16 | `risk_valid` | |
| 17 | `strat_valid` | |
| 18 | `filter_valid` | |
| 19 | `tmpl_valid` | |
| 20 | `session_valid` | |
| 21 | `log_drop_sticky` | ⚠️ **Audit records were LOST.** Alertable. |
| 22 | `telem_timeout_sticky` | The core domain did not answer a telemetry read. |
| 23 | `cfg_err_sticky` | At least one config write was rejected. |

### 4.3 Remaining core-page registers

| Offset | Name | Access | Reset | Width | Description |
| --- | --- | :-: | --- | ---: | --- |
| `0x018` | `HEARTBEAT` | **WO** | — | 32 | ⚠️ **Watchdog kick.** Writing **any** value resets `HEARTBEAT_AGE` to 0 and emits one pulse to `core_clk`, where `risk_gate` runs the authoritative watchdog. Required cadence **≥ 10 Hz**; **recommended 50 Hz** (20 ms). |
| `0x01C` | `WATCHDOG_CFG` | RO | param | 32 | `{warn_ms[15:0], timeout_ms[15:0]}` = `{50, 100}` by default. Build-time, not runtime. |
| `0x020` | `KILL_SRC` | RO-sticky | 0 | 32 | See §7 for the bit layout. Cleared only by reset. |
| `0x024` | `KILL_COUNT` | RO | 0 | 32 | Kill activations since reset. |
| `0x028` | `HEARTBEAT_AGE` | RO | **`0xFFFF`** | 32 | Milliseconds since the last kick. ⚠️ Reset value is already past the timeout — deliberate. Saturates at `0xFFFF`; it does not wrap. |
| `0x02C` | `SCRATCH` | RW | 0 | 32 | Host-owned. Proves the BAR read/write path end to end before anything dangerous is written. First thing a driver should exercise. |
| `0x030` | `PARAM_GEN` | RO | 0 | 32 | `{strat_gen[15:0], risk_gen[15:0]}` — parameter generation counters. A generation of `0` means *never committed*, and blocks arming. |
| `0x034` | `PARAM_STATUS` | RO | 0 | 32 | Per-window valid / write-protected bits. |
| `0x038` | `CFG_ERR` | RO / **RW1C** | 0 | 32 | Rejected-write reasons plus a count. See §4.4. |
| `0x03C` | `ARM_STATE` | RO | 0 | 32 | `{window_ms_left[15:0], fault[…], state[2:0]}`. `window_ms_left` counts down the `ARM_WINDOW_MS = 5000` deadline between step 1 and step 2. |

### 4.4 `CFG_ERR` bit positions — `0x038`

| Bit | Name | Meaning |
| ---: | --- | --- |
| 0 | `E_PROTECTED` | A write to a protected window was attempted **while trading is enabled**. Rejected; nothing changed. |
| 1 | `E_QUEUE` | Config write queue overflow — the host pushed faster than the CDC handshake drains. |
| 2 | `E_ARM_SEQ` | `arm_step2` without `arm_step1`, or both bits set in one write, or `arm_step1` twice. |
| 3 | `E_ARM_PRE` | Arm attempted with preconditions unmet. See §9.2 for the precondition list. |
| 4 | `E_UNMAPPED` | Write to an unmapped offset. |
| 5 | `E_RING_CFG` | Illegal DMA ring size or base. |
| 6 | `E_TELEM_TO` | A telemetry-window read timed out. |

> ⚠️ **A rejected write changes nothing and returns no error to the writing instruction.**
> PCIe MMIO writes are *posted* — the CPU's `mov` retires long before the fabric decides
> to reject it. The **only** way a host learns that a limit write was refused is by
> reading `CFG_ERR` (or `STATUS[23]`) afterwards. A driver that writes limits and does
> not then read `CFG_ERR` will silently run on stale limits. This is the same failure
> class as the read-back rule in §6.

---

## 5. DMA log ring — `0x040`–`0x064`

| Offset | Name | Access | Reset | Width | Description |
| --- | --- | :-: | --- | ---: | --- |
| `0x040` | `LOG_RING_BASE_LO` | RW | 0 | 32 | Host physical address, low. **64-byte aligned** — `[5:0]` are forced to `0` on write. |
| `0x044` | `LOG_RING_BASE_HI` | RW | 0 | 32 | High 32 bits. |
| `0x048` | `LOG_RING_SIZE` | RW | 0 | 32 | `[4:0]` = log₂(entries). **`0` = ring disabled.** Range `LOG_RING_LOG2_MIN = 8` (256 records, 16 KiB) to `LOG_RING_LOG2_MAX = 22` (4 M records, 256 MiB); default `16` (64 K records, 4 MiB). Power-of-two so the wrap is a mask, never a modulo. |
| `0x04C` | `LOG_RING_HEAD` | RO | 0 | 32 | Fabric produce pointer, **in records**. |
| `0x050` | `LOG_RING_TAIL` | RW | 0 | 32 | Host consume pointer, in records. Both are free-running 32-bit, so `occupancy = head − tail` is plain unsigned subtraction that wraps correctly. |
| `0x054` | `LOG_DROP_CNT` | RO | 0 | 32 | ⚠️ **ALERTABLE. Records LOST.** Must be `0`. Non-zero on the audit ring means the host is not keeping up with *orders*, which means the risk supervision loop is broken. |
| `0x058` | `LOG_REC_CNT` | RO | 0 | 32 | Records delivered. |
| `0x05C` | `LOG_CTRL` | RW | 0 | 32 | `[0]` `ring_en`; `[1]` W1P `clr_sticky`. |
| `0x060` | `LOG_FULL_CNT` | RO | 0 | 32 | Host-too-slow episodes. |
| `0x064` | `TELEM_ERR_CNT` | RO | 0 | 32 | Telemetry read timeouts. |

Loss is never silent: `log_rec_t.seq` increments for **every** record the fabric decides
to emit, *including* records it then had to drop, so a gap in `seq` tells the host
exactly how many records it lost and between which two. A `LOG_GAP_MARKER` record is
emitted once space returns, carrying the lost count in `aux0`.

⚠️ **The producer index must be written after the records, in a separate transaction, to
a separate cache line.** PCIe posted writes to the same address are ordered; the host's
*cache* is not your ordering domain. See
[`../manuals/04-system-architecture/06-cpu-fpga-partitioning.md`](../manuals/04-system-architecture/06-cpu-fpga-partitioning.md) §5.

---

## 6. Config write windows — `0x100` / `0x200` / `0x300` / `0x400` / `0x500`

All five windows share one layout. Substitute the page base for `BASE`.

| Offset | Name | Access | Reset | Width | Description |
| --- | --- | :-: | --- | ---: | --- |
| `BASE+0x00` | `*_ADDR` | RW | 0 | 32 | Entry/word index (16 bits used, matching `cfg_*_addr[15:0]`). **Auto-increments** on every `_DATA` write when `_CTRL[0]` is set. |
| `BASE+0x04` | `*_DATA` | **WO** | — | 32 | Pushes `{target, ADDR, wdata}` into the pcie→core config handshake. **This is the write.** |
| `BASE+0x08` | `*_CTRL` | RW | **1** | 32 | `[0]` `auto_inc` (**default 1**); `[1]` W1P `reset_chk`; `[2]` W1P **`commit`** (risk and strategy only); `[3]` W1P `zero_addr`; `[4]` `mark_valid`. |
| `BASE+0x0C` | `*_GEN` | RO | 0 | 32 | `{pending[15:0], generation[15:0]}`. `generation` increments on each successful commit; `pending` counts writes not yet drained. |
| `BASE+0x10` | `*_WR_CHK` | RO | seed | 32 | **Running write-side checksum** over everything pushed since the last `reset_chk`. |
| `BASE+0x14` | `*_CMT_CHK` | RO | 0 | 32 | The checksum **latched at the last commit**. |
| `BASE+0x18` | `*_STATUS` | RO | 0 | 32 | `{protected, valid, word_count[15:0]}`. |

| Page | Base | Target | Commit? | Write-protected while trading enabled? |
| :-: | --- | --- | :-: | :-: |
| `0x01` | `0x100` | `FILTER` — locate → active index | no | no |
| `0x02` | `0x200` | `RISK` 🔒 — `sym_risk_t` | **yes** | ⚠️ **YES** |
| `0x03` | `0x300` | `STRAT` — `sym_strat_t` | **yes** | **no** — deliberate |
| `0x04` | `0x400` | `TMPL` — OUCH templates | no | ⚠️ **YES** |
| `0x05` | `0x500` | `SESSION` — TCP 5-tuple, ISN, window | no | ⚠️ **YES** |

### 6.1 The mandatory sequence — write shadow → read back → verify → commit

ADR 0011 (double-buffered parameter update) exists to make a multi-word per-symbol
update atomic. The fabric provides shadow banking and a commit bit; **it cannot provide
verification** — that is the host's half of the contract, and it is not optional.

```
1.  *_CTRL[1]  = 1                 reset the running checksum
2.  *_ADDR     = first index        (or *_CTRL[3] = 1 to zero it)
3.  for each word:  *_DATA = w      auto-increment carries the address
4.  read *_GEN                      confirm pending == 0 (writes drained)
5.  read *_WR_CHK                   compare against the host's own computation
    ── if it differs, STOP. Do not commit. ──
6.  *_CTRL[2]  = 1                 COMMIT (atomic bank flip)
7.  read *_CMT_CHK                  must equal the value verified at step 5
8.  read *_GEN                      generation must have incremented
9.  *_CTRL[4]  = 1                 mark_valid
10. read CFG_ERR                    must be 0
```

> ⚠️ **A commit written without a verified read-back is the money-losing bug ADR 0011
> exists to prevent.** MMIO writes are posted: the CPU's store instruction retires with
> no acknowledgement from the device. A dropped write, a stuck bit, a truncated burst, or
> a wrong-stride address calculation all produce the *same* observable outcome as a
> perfect write — nothing. Commit anyway and the fabric atomically swaps in a bank
> containing a limit nobody set. The atomicity is real and it does not help: you have
> atomically installed the wrong numbers. The read-back is the only thing standing
> between a posted-write failure and an order judged against a limit that does not exist.
>
> [`../TASKS.md`](../TASKS.md) **P7.5**: *"write shadow, read back, compare, then commit.
> Never trust a write you didn't verify."*

### 6.2 Write protection, and the asymmetry between risk and strategy

Writes to the **RISK** window are **rejected** while `trading_enable` is set. Rejection
sets `CFG_ERR[0]`, increments the count, and changes nothing. **There is no override bit
and no force flag.** The operator is forced through:

```
disable trading → change limits → commit → read back and verify → re-enable trading
```

This creates an unambiguous audit boundary — every risk-limit change is bracketed by a
`LOG_TRADING_DIS` / `LOG_PARAM_COMMIT` / `LOG_TRADING_EN` triple in the DMA audit ring,
with the write-side checksum in the commit record — and removes the worst failure mode:
limits mutating underneath live order flow, so that a rejected order and an accepted one
were judged by different rules with no record of the transition.

> ⚠️ **This is not four-eyes approval.** Two humans approving a change is a *host-side*
> control. What the fabric provides is the enforcement point that makes the host-side
> control meaningful: the sequence cannot be bypassed by writing directly to the BAR,
> because the fabric refuses.

The **STRAT** window is deliberately **not** protected: `sym_strat_t` carries
`fair_value`, which the host updates at millisecond cadence while trading. Protecting it
would make the strategy unusable.

> ⚠️ **Never move a risk limit into the strategy window.** The asymmetry is the entire
> reason risk and strategy live in separate windows with separate commits. A limit that
> migrates into the unprotected window becomes writable mid-trade by any process holding
> the BAR, and the audit bracket disappears with it.

### 6.3 Session config — `0x500` (ADR 0006)

`cfg_session_wr` / `cfg_session_data[31:0]` carry the TCP 5-tuple, the initial sequence
number, and the window handed from host to fabric. The host performs TCP connect,
SoupBinTCP login and sequence negotiation (Q1 "no" —
[`../manuals/04-system-architecture/06-cpu-fpga-partitioning.md`](../manuals/04-system-architecture/06-cpu-fpga-partitioning.md) §2),
then hands the established session's state to the fabric for steady-state send.
`SESSION_ADDR` is a running word index only; `SESSION_WORDS_MAX = 32`.

> ⚠️ **These registers must never be written while the fabric holds the send path.**
> Rewriting the 5-tuple, the ISN, or the window under a live session desynchronizes the
> fabric's sequence numbers from the venue's. The venue does not reject the resulting
> segments loudly — it silently discards them, or worse, accepts a segment at a
> plausible-but-wrong sequence. Orders stop arriving, or arrive corrupted, and the
> fabric has no way to know: it has no retransmit logic and no window recovery (both are
> host-side by design). The window is write-protected while `trading_enable` is set for
> exactly this reason, and the correct handover order is: kill → confirm no in-flight →
> hand TX ownership back to the host → rewrite session → hand ownership forward → re-arm.

---

## 7. Kill switch

### 7.1 `KILL_SRC` — `0x020`, RO-sticky, reset `0`

| Bit(s) | Name | Description |
| ---: | --- | --- |
| 2:0 | `last_kill_src` | `kill_src_e` of the **most recent** kill. |
| 3 | `kill_active` | Live. |
| 10:8 | `first_kill_src` | `kill_src_e` of the **first** kill since reset. ⚠️ In a cascade the first cause is the one you need; the last one is usually just the consequence. |
| 23:16 | `ever_mask` | Bit *n* set = `kill_src_e` value *n* has fired at least once. **A source that has never fired is a control you have never actually tested** — this is the register that turns that from an opinion into a number. |

### 7.2 `kill_src_e` — from [`../rtl/pkg/trading_pkg.sv`](../rtl/pkg/trading_pkg.sv)

| Value | Name | Trigger |
| ---: | --- | --- |
| 0 | `KILL_NONE` | — |
| 1 | `KILL_HOST` | Host wrote `CONTROL[1]`. |
| 2 | `KILL_WATCHDOG` | Host heartbeat stopped. |
| 3 | `KILL_MSG_RATE` | Outbound rate limit breached. |
| 4 | `KILL_POS_BREACH` | Aggregate position limit breached. |
| 5 | `KILL_GPIO` | External hardware input (`ext_kill_n`, front panel / BMC). |
| 6 | `KILL_LINK_DOWN` | Order-entry link lost. |
| 7 | `KILL_SEQ_FAULT` | Unrecoverable session sequence fault. |

The kill is bounded at `KILL_RESP_CYCLES = 4` cycles (**25.6 ns** at 156.25 MHz),
asserted in `fpga_top.sv` by SVA. ⚠️ That assertion verifies the *logic*; the SLR
crossing that `cfg_kill` takes from SLR1 to SLR0 is **one of those four cycles** and is
not modelled in simulation (simulation is untimed). The real number is a **hardware**
measurement, not a simulation result.

---

## 8. Telemetry read window — `0x800`–`0xBFC`

`telem_raddr[15:0]` → `telem_rdata[31:0]`, proxied across the CDC by `host_ctrl`.

```
word index = (bar_byte_offset − 0x800) >> 2          window size = 256 words = 1 KiB
```

Sub-map transcribed from [`../rtl/telemetry/telemetry_pkg.sv`](../rtl/telemetry/telemetry_pkg.sv),
which is the **single source of truth** for it:

| Word | Byte offset | Count | Contents |
| --- | --- | ---: | --- |
| `0x000` | `0x800` | 1 | `STATUS` — **LIVE, not snapshotted**; single word, therefore atomic |
| `0x001` | `0x804` | 1 | `UPTIME_LO` — `cycle_cnt[31:0]` |
| `0x002` | `0x808` | 1 | `UPTIME_HI` — `{16'b0, cycle_cnt[47:32]}` |
| `0x003` | `0x80C` | 1 | `VERSION` — `{MAGIC, MAJOR, MINOR}` |
| `0x004` | `0x810` | 1 | `SNAP` — ⚠️ **READ HAS A SIDE EFFECT**: latches the whole shadow bank, returns the new sequence |
| `0x005` | `0x814` | 1 | `HIST_CLEAR` — ⚠️ **READ HAS A SIDE EFFECT**: zeroes the latency histogram. **Start of day only.** |
| `0x006` | `0x818` | 1 | `SNAP_SEQ` — snapshot sequence number, no side effect |
| `0x007` | `0x81C` | 1 | `LAT_CFG` — `{LOG_MODE, DELTA_W, N_BUCKETS}` |
| `0x008`–`0x00F` | | 8 | reserved |
| `0x010`–`0x017` | `0x840` | **8** | `md_mac_stat[feed][idx]`, index = `feed*4 + idx` |
| `0x018`–`0x01B` | `0x860` | **4** | `oe_mac_stat[idx]` |
| `0x01C`–`0x01F` | | 4 | reserved |
| `0x020`–`0x027` | `0x880` | **8** | `net_stat[idx]` |
| `0x028`–`0x02F` | | 8 | reserved |
| `0x030`–`0x03F` | `0x8C0` | **16** | `feed_stat[idx]` |
| `0x040`–`0x04F` | `0x900` | **16** | `book_stat[idx]` |
| `0x050`–`0x05F` | `0x940` | **16** | `strat_stat[idx]` |
| `0x060`–`0x067` | `0x980` | **8** | `risk_stat[idx]` |
| `0x068`–`0x06F` | | 8 | reserved |
| `0x070`–`0x087` | `0x9C0` | **24** | `risk_reject_cnt[reason]` — **index == `risk_reason_e`**, see §8.1 |
| `0x088`–`0x08F` | | 8 | reserved |
| `0x090`–`0x09F` | `0xA40` | **16** | `order_stat[idx]` |
| `0x0A0`–`0x0BF` | | 32 | reserved |
| `0x0C0`–`0x0DF` | `0xB00` | **32** | latency histogram `bucket[idx]` (`N_BUCKETS = 32`) |
| `0x0E0` | `0xB80` | 1 | `LAT_MIN` — cycles, exact |
| `0x0E1` | `0xB84` | 1 | `LAT_MAX` — cycles, exact |
| `0x0E2` | `0xB88` | 1 | `LAT_SUM_LO` |
| `0x0E3` | `0xB8C` | 1 | `LAT_SUM_HI` |
| `0x0E4` | `0xB90` | 1 | `LAT_N` — sample count |
| `0x0E5` | `0xB94` | 1 | `LAT_OVER` — ⚠️ samples above the top bucket |
| `0x0E6` | `0xB98` | 1 | `LAT_LAST` — most recent sample, cycles |
| `0x0E7`–`0x0FF` | | 25 | reserved |
| **Total** | | **256** | **1,024 bytes** |

`0xFFFF` is `TELEM_A_IDLE`, the address the CSR parks on between reads.

Counter word budget: `8 + 4 + 8 + 16 + 16 + 16 + 8 + 24 + 16 = 116` snapshotted words.
⚠️ Note `order_stat[16]` — it is wired in `fpga_top.sv` (`.order_stat(order_stat)`) and
mapped here, and is easy to omit when enumerating the stat arrays from the port list.

### The snapshot contract

> ⚠️ **Every word except `STATUS`, `VERSION` and `LAT_CFG` is read from a shadow bank,
> and reading counters without snapshotting first gives a set of values that never
> coexisted.** `orders_emitted` read before a snapshot and `acks` read after do not
> describe the same instant, and the difference between them is a number your
> reconciliation will believe. Required order: **read `SNAP` → read the words you want →
> read `SNAP_SEQ` and confirm it is unchanged.** If `SNAP_SEQ` moved, another collector
> snapshotted mid-scrape and the whole read is void — discard and retry.

⚠️ **`SNAP` and `HIST_CLEAR` are reads with side effects.** A generic register-dump tool
that walks `0x800`–`0xBFC` linearly will trip both: it will re-snapshot mid-dump and it
will **erase the latency histogram**. Any such tool must skip words `0x004` and `0x005`
explicitly. This is the one place in the map where a harmless-looking read destroys data.

### Counter semantics — saturating, not wrapping

Per [`../CLAUDE.md`](../CLAUDE.md) §5 rule 7 (*every drop, error and rejected order is
counted*) and `trading_pkg::sat_add64`, project counters **saturate**; they do not wrap.
`telemetry.sv` states the companion rule: **no clear-on-read anywhere** — every counter
is free-running or saturating, and the host computes deltas.

> ⚠️ **A wrapping counter makes a rate check meaningless while still returning a
> plausible number.** A 32-bit counter at 10 M events/s wraps in ~430 s. A 1 Hz scraper
> differencing two samples across a wrap computes a small positive delta that looks
> exactly like a quiet period. The alert never fires, the dashboard shows a dip instead
> of a spike, and the "rate" you are trading on is fiction. This is the reason for
> saturation, and the reason
> [`../manuals/06-operations/03-monitoring-and-telemetry.md`](../manuals/06-operations/03-monitoring-and-telemetry.md) §9
> requires 40–48-bit widths on high-rate counters.
>
> ⚠️ **The corollary bites too: a saturated counter is also a lie, just a different
> one.** All the stat arrays reaching telemetry are **32 bits** (`logic [31:0]
> md_mac_stat[2][4]`, `net_stat[8]`, `feed_stat[16]`, …). A saturating 32-bit counter
> at line rate pins to `0xFFFF_FFFF` inside a session, after which every delta is **0**
> and every rate reads as *zero traffic* on a link running at capacity. Saturation moves
> the failure from "implausible number" to "plausible zero", which is worse. **Open item
> O3 in §11: widen the high-rate counters to 48 bits, or expose them as
> `{LO, HI}` pairs behind the snapshot bank.**

### 8.1 `risk_reason_e` — the reject-counter index table

`risk_reject_cnt[reason]` at telemetry word `0x070 + reason`, byte offset
`0x9C0 + 4×reason`. The host needs this table to **name** a rejection; a rejection
reported as "reason 9" in an incident is a rejection nobody acts on.

| Index | `risk_reason_e` | Telemetry word | Byte offset | Meaning |
| ---: | --- | --- | --- | --- |
| 0 | `RISK_OK` | `0x070` | `0x9C0` | Passed. Not a rejection. |
| 1 | `RISK_MASTER_DISABLED` | `0x071` | `0x9C4` | `trading_enable` is clear. |
| 2 | `RISK_KILL_SWITCH` | `0x072` | `0x9C8` | Kill active. |
| 3 | `RISK_SYM_DISABLED` | `0x073` | `0x9CC` | `sym_risk_t.enabled` = 0. |
| 4 | `RISK_SESSION_CLOSED` | `0x074` | `0x9D0` | Global session state forbids quoting. |
| 5 | `RISK_SYM_HALTED` | `0x075` | `0x9D4` | Regulatory or operational halt. |
| 6 | `RISK_BOOK_STALE` | `0x076` | `0x9D8` | Sequence gap; book not trustworthy. |
| 7 | `RISK_SUB_PENNY` | `0x077` | `0x9DC` | **SEC Rule 612** — price is not a whole cent. |
| 8 | `RISK_PRICE_COLLAR` | `0x078` | `0x9E0` | Outside `collar_lo`/`collar_hi`. |
| 9 | `RISK_LULD_BAND` | `0x079` | `0x9E4` | Outside the LULD band. |
| 10 | `RISK_SSR` | `0x07A` | `0x9E8` | **Reg SHO Rule 201** short-sale price test. |
| 11 | `RISK_MAX_SHARES` | `0x07B` | `0x9EC` | Above `max_order_qty`. |
| 12 | `RISK_MAX_NOTIONAL` | `0x07C` | `0x9F0` | Above `max_order_notional`. |
| 13 | `RISK_POS_LIMIT` | `0x07D` | `0x9F4` | Would breach `max_long_pos` / `max_short_pos`. |
| 14 | `RISK_GROSS_LIMIT` | `0x07E` | `0x9F8` | Aggregate gross exposure limit. |
| 15 | `RISK_OPEN_ORDERS` | `0x07F` | `0x9FC` | Above `max_open_orders`. |
| 16 | `RISK_MSG_RATE` | `0x080` | `0xA00` | Outbound rate limit. |
| 17 | `RISK_DUPLICATE` | `0x081` | `0xA04` | Duplicate client order token. |
| 18 | `RISK_SELF_MATCH` | `0x082` | `0xA08` | Self-match prevention. |
| 19 | `RISK_RESTRICTED` | `0x083` | `0xA0C` | Restricted / hard-to-borrow list. |
| 20 | `RISK_NO_CREDIT` | `0x084` | `0xA10` | In-flight credit exhausted (`MAX_IN_FLIGHT = 64`). |
| 21 | `RISK_ZERO_QTY` | `0x085` | `0xA14` | |
| 22 | `RISK_ZERO_PRICE` | `0x086` | `0xA18` | |
| 23 | `RISK_PARAM_INVALID` | `0x087` | `0xA1C` | The parameter record failed its field check. |

`N_RISK_REASONS = 24`. **One counter per reason, never one aggregate** — a check that
never fires is a check you cannot trust, and the `ever_mask` logic of §7.1 applies here
too. Alerting rules from
[`../manuals/06-operations/03-monitoring-and-telemetry.md`](../manuals/06-operations/03-monitoring-and-telemetry.md) §7:
any `risk_rejects` **rate** above threshold is Tier 1, and **any reason that has never
fired before, firing** is Tier 1 — a new failure mode.

---

## 9. Access rules and ordering

### 9.1 What may be written while trading is armed

| Region | Writable while `trading_enable = 1`? | Enforcement |
| --- | :-: | --- |
| `CONTROL[1]` kill | ✅ **always** | Making it *easy* to stop is the correct asymmetry. |
| `HEARTBEAT` | ✅ required | Must be kicked at ≥ 10 Hz or the watchdog disarms. |
| `LOG_RING_TAIL`, `LOG_CTRL` | ✅ | Ring drain is continuous. |
| `SCRATCH` | ✅ | Harmless. |
| **STRAT window** | ✅ **deliberately** | `fair_value` moves at ms cadence. |
| **RISK window** 🔒 | ❌ **rejected** | `CFG_ERR[0]`, hardware-enforced, no override. |
| **TMPL window** | ❌ rejected | Same. |
| **SESSION window** | ❌ rejected | Same. See §6.3. |
| FILTER window | ✅ permitted | But a mid-session symbol-set change is an operational decision, not a routine one. |

**Registers that require the kill switch asserted first:** none are *hardware*-gated on
kill specifically — the gate is `trading_enable`. Operationally, however, the risk,
template and session windows can only be reached by disabling trading, and project
practice is to **assert kill first, then disable trading**, never the reverse: disabling
trading alone leaves in-flight orders unaccounted, whereas kill stops emission within a
bounded 4 cycles.

### 9.2 The two-step re-arm sequence (ADR 0009)

Arming is a **positive action gated on positive identification**. *"The card came up,
probably fine"* is not a state.

```
 precondition check (all must hold, checked at BOTH steps):
     risk_valid   && risk_gen   != 0
     strat_valid  && strat_gen  != 0
     filter_valid && tmpl_valid && session_valid
     !watchdog_expired      (host heartbeat is live)
     core_alive             (core_clk domain is running)
     pcie_link_up
     cfg_path_idle          (no config write still draining)

 1.  write CONTROL with bit 1 (kill) = 0        release the host kill source
 2.  write CONTROL with bit 2 (arm_step1) = 1   ── one bus write, alone
         → arm_state = STEP1, a 5,000 ms window opens
 3.  read STATUS / ARM_STATE                    confirm STEP1 and window_ms_left > 0
 4.  write CONTROL with bit 3 (arm_step2) = 1   ── a SEPARATE bus write
         → arm_state = ARMED
 5.  write CONTROL with bit 0 (trading_enable) = 1
 6.  read STATUS[12] trading_en_effective       must be 1. Trading is now live.
```

Every way this can go wrong is a **fault**, not a retry:

| Operator error | Result |
| --- | --- |
| `arm_step1` and `arm_step2` in **one** bus write | `ARM_FAULT`, `arm_fault = 1`, `CFG_ERR[2]` |
| `arm_step2` without `arm_step1` | `ARM_FAULT`, `arm_fault = 2`, `CFG_ERR[2]` |
| `arm_step1` twice | `ARM_FAULT`, `arm_fault = 1` |
| Either step with preconditions unmet | `ARM_FAULT`, `arm_fault = 3`, `CFG_ERR[3]` |
| More than `ARM_WINDOW_MS = 5000` ms between steps | silently returns to `DISARMED` — **not** a fault, just a timeout |

⚠️ `ARM_FAULT` is **cleared only by an explicit kill write**. A fault that clears itself
teaches the operator nothing.

Once `ARMED`, **anything that invalidates the preconditions disarms**: `watchdog_expired`,
`!core_alive`, or `!pcie_link_up` drop the state to `DISARMED` and clear
`trading_enable` in the same cycle. Arming is not a latch you set and forget; it is a
condition that must remain continuously true.

> ⚠️ **Why two steps at all.** A single "arm" register is one stray `memset` over the
> BAR, one wild pointer, or one mis-scoped test script away from a live trading system.
> Requiring two *separate bus transactions*, in order, within a bounded window, with all
> preconditions verified at both, means no single accidental write can arm the device —
> and the rejection of both-bits-in-one-write closes the obvious shortcut. Compare
> `CONTROL[1]`, which stops trading on **any** write of `1`: stopping must be trivial,
> starting must be deliberate.

### 9.3 Full start-of-day order

Condensed from
[`../manuals/04-system-architecture/06-cpu-fpga-partitioning.md`](../manuals/04-system-architecture/06-cpu-fpga-partitioning.md) §7
and adapted to the implemented map. ⚠️ **If any step fails, you stop at that step.**
There is no "continue and fix it during the session".

```
 1. Load bitstream
 2. SCRATCH write/read                          prove the BAR path
 3. BUILD_ID / GIT_SHA / BUILD_TIMESTAMP        must match the signed manifest — abort if not (P10.5)
 4. MAP_VERSION                                 MAJOR must match the host's expectation
 5. STATUS: kill_active == 1, arm_state == DISARMED   ⚠️ if kill_active is 0 after reset, STOP
 6. Begin kicking HEARTBEAT at 50 Hz            watchdog must go live BEFORE anything else
 7. FILTER window   → §6.1 sequence → mark_valid
 8. RISK window 🔒  → §6.1 sequence → commit → mark_valid
 9. TMPL window     → §6.1 sequence → mark_valid
10. SESSION window  → §6.1 sequence → mark_valid    (after the host's TCP/SoupBin login)
11. STRAT window    → §6.1 sequence → commit → mark_valid
12. STATUS[14] params_valid == 1, CFG_ERR == 0
13. Configure the DMA log ring; verify with a synthetic record
14. Wait for link_up on all three ports; require N seconds of unbroken feed sequence
15. Build the books; verify hardware L1 against the software shadow book per symbol
16. Two-step arm (§9.2)
17. CONTROL[0] trading_enable = 1
18. STATUS[12] trading_en_effective == 1        ← trading is live
```

Kill is released and arming happens **last**, after every other precondition is verified.
The watchdog starts **before** trading, so there is never a live-trading moment without
host supervision.

### 9.4 Ordering rules

1. **One writer per window.** The config windows are indexed (`*_ADDR` + `*_DATA`), so
   ⚠️ **they are not thread-safe.** Two threads interleaving `*_ADDR` writes will write
   a limit to the wrong symbol, with no error. Exactly one host thread touches a given
   window, holding a lock. Worth an assertion in the driver test suite.
2. **`*_DATA` is the write; `*_ADDR` is state.** With `auto_inc` on, a burst is
   `ADDR` once then `DATA` × N. Any read or write to `*_ADDR` in between resets that.
3. **Read `CFG_ERR` after every write batch.** Posted writes give no completion. §4.4.
4. **Snapshot before scraping telemetry.** §8.
5. **Do not poll in a tight loop.** A 1 kHz register scrape is thousands of PCIe
   transactions per second competing with the order-path DMA. Scrape slow counters at
   1 Hz, health at 10 Hz.
6. **`0x008` `BUILD_TIMESTAMP` and `0x00C` `MAP_VERSION` are read once at start-up**, not
   polled.

---

## 10. Discrepancies found in the sources

Recorded, **not fixed** — these live in `rtl/` and `manuals/`, which this document does
not edit. Each is a candidate for the CI check that P7.2 will add.

| # | Discrepancy | Where | Impact |
| --- | --- | --- | --- |
| **D1** | The task premise stated *"there is no `rtl/ctrl/csr_regfile.sv`; `rtl/ctrl/` is empty."* **`rtl/ctrl/` contains `csr_regfile.sv` (1,271 lines), `dma_log_ring.sv` and `pcie_wrapper.sv`.** `csr_regfile.sv` and `dma_log_ring.sv` were created during this document's authoring. | [`../rtl/ctrl/`](../rtl/ctrl/) | This map is therefore **derived from real RTL**, not invented. It remains PROVISIONAL because `docs/regmap.yaml` and the CI check still do not exist. |
| **D2** | ⚠️ **`risk_params.sv` decodes a 16-word-per-symbol shadow stride** (`SHADOW_D = N_SYM * 16`; `wr_addr = {wr_sym[7:0], wr_word[3:0]}`), while `telemetry_pkg.sv` — self-declared *"SINGLE SOURCE OF TRUTH for host-software contracts"* — publishes **`RISK_WORDS_PER_SYM = 12`**. | `rtl/risk/risk_params.sv` vs `rtl/telemetry/telemetry_pkg.sv` | **Live silent-corruption bug.** A host computing `addr = sym × 12 + word` writes symbol 1's limits into symbol 0's unused words 12–15 and symbol 1's words 0–7. Symbols above 0 receive partial or no limits; the fail-closed default then blocks them, or a partial record passes its field check and installs limits nobody set. **Highest-priority item in this document.** |
| **D3** | `telemetry_pkg.sv` sets `TMPL_WORDS_MAX = 2048`, but `ouch_encoder.sv` decodes `cfg_tmpl_addr` as `{sel, sym[7:0], word[4:0]}` — a **32-word stride × 256 symbols = 8,192 words**. | `rtl/telemetry/telemetry_pkg.sv` vs `rtl/order/ouch_encoder.sv` | A host bounds-checking against 2048 cannot write templates for symbols ≥ 64. Those symbols then have `enter_ok = 0` and never trade — a fail-closed outcome, but for the wrong reason and with no diagnostic. |
| **D4** | `telemetry_pkg.sv` says `sym_strat_t` occupies **5** words; `strategy_pkg.sv` defines `N_PARAM_WORDS = 6`; the published stride `STRAT_WORDS_PER_SYM` is **8**. Three numbers for one thing. | `rtl/telemetry/telemetry_pkg.sv` vs `rtl/strategy/strategy_pkg.sv` | Benign *today* — the CSR splits at stride 8 and `param_table` rejects `word ≥ 6`. Still three hand-maintained numbers that must become one. |
| **D5** | `csr_regfile.sv` takes a `BUILD_TIMESTAMP` parameter and exposes it at `0x008`, but [`../rtl/fpga_top.sv`](../rtl/fpga_top.sv) declares only `BUILD_ID` and `GIT_SHA` and passes only those to `host_ctrl`. | [`../rtl/fpga_top.sv`](../rtl/fpga_top.sv) | `BUILD_TIMESTAMP` reads its default `0x0000_0000`. A daemon implementing P10.5 against all three identity registers will compare `0` to a manifest timestamp and **refuse to arm every time** — or, if it ignores a zero, silently drop one third of the build-identity check. |
| **D6** | `csr_regfile.sv` produces `counters_rst_pulse`, but `fpga_top.sv` has no corresponding `cfg_*` port on `host_ctrl`. Likewise nothing at top level carries the DMA ring signals. | [`../rtl/fpga_top.sv`](../rtl/fpga_top.sv) vs [`../rtl/ctrl/csr_regfile.sv`](../rtl/ctrl/csr_regfile.sv) | `CONTROL[4] reset_counters` and the whole `0x040`–`0x064` ring page have no path to the fabric until `host_ctrl.sv` is written. Writes succeed and do nothing. |
| **D7** | `csr_regfile.sv` line 18 requires `rtl/ctrl/README.md` to exist and to agree with its header. **That file does not exist.** | [`../rtl/ctrl/`](../rtl/ctrl/) | The "full table with bit-level detail, the startup sequence and the shutdown sequence" it points at is missing. This document currently fills that role. |
| **D8** | [`../manuals/04-system-architecture/06-cpu-fpga-partitioning.md`](../manuals/04-system-architecture/06-cpu-fpga-partitioning.md) §4 contains a **complete, different** register map (`ID`/`CTRL`/`KILL_SET`/`SYM_SEL`/`LAT_HIST`, `reg_map_pkg.sv`, `host/include/tt_regs.h`, `scripts/gen_regmap.py`) that does not match `csr_regfile.sv` in offsets, names, or mechanism. | manual vs RTL | A driver written from the manual will not work. The manual is a *pattern*, the RTL is the contract. `docs/regmap.yaml` must reconcile them. |
| **D9** | `csr_regfile.sv`'s `CONTROL` bit table annotates `[1] kill` as *"writing 1 disarms IMMEDIATELY"*. "Disarm" is the correct effect but reads as the opposite of "arm the kill switch", which is how the same action is described in the manuals. | [`../rtl/ctrl/csr_regfile.sv`](../rtl/ctrl/csr_regfile.sv) | Wording only, but on the one register where a reversed reading is catastrophic. `regmap.yaml` should fix the vocabulary: **kill is *asserted*; trading is *disarmed*.** |
| **D10** | All telemetry stat arrays are 32-bit (`logic [31:0] … [N]`), against the governing manual's requirement of 40–48 bits for high-rate counters. | [`../rtl/fpga_top.sv`](../rtl/fpga_top.sv) vs [`../manuals/06-operations/03-monitoring-and-telemetry.md`](../manuals/06-operations/03-monitoring-and-telemetry.md) §9 | See the ⚠️ in §8. Saturation turns an overflowed counter into a plausible zero rate. |

---

## 11. Open items

Everything that cannot be pinned until `docs/regmap.yaml` and `rtl/ctrl/host_ctrl.sv`
exist. **The offsets in this document are transcribed from `csr_regfile.sv` and are
therefore real for that block — but the map as a whole is not verified end to end,
because nothing connects the CSR to the fabric yet.**

| # | Item | Blocks | Owner |
| --- | --- | --- | --- |
| **O1** | ⚠️ Resolve **D2** — the risk shadow stride, 12 vs 16. Silent-corruption class; highest priority. | `docs/regmap.yaml`, `risk_params.sv`, `telemetry_pkg.sv` | Risk owner |
| **O2** | Create `docs/regmap.yaml` + `scripts/gen_regmap.py`, generate `rtl/host/regfile.sv`, `host/include/regmap.hpp` and **this document's tables**, and add the CI check that RTL and host agree (P7.2). Retires the PROVISIONAL banner. | P7.2 | Platform lead |
| **O3** | Widen high-rate telemetry counters to 48 bits, or expose `{LO, HI}` pairs behind the snapshot bank (**D10**). | `fpga_top.sv`, `telemetry.sv` | Ops owner |
| **O4** | Write `rtl/ctrl/host_ctrl.sv`. Until it exists, **no `cfg_*` write reaches the core clock domain** and the whole map is untestable against hardware. | P7.1 | Platform lead |
| **O5** | Resolve **D3** — `TMPL_WORDS_MAX = 2048` vs the encoder's 8,192-word address space. | `docs/regmap.yaml` | Gateway owner |
| **O6** | Pass `BUILD_TIMESTAMP` through `fpga_top.sv` → `host_ctrl` → `csr_regfile` (**D5**), or remove the register. A build-identity register that always reads `0` is worse than no register. | P10.5, P7.13 | Platform lead |
| **O7** | **BAR size** — is 64 KiB final? The used range ends at `0xBFC`; `0x0C00`–`0xFFFF` is reserved by proposal only. If DMA descriptor rings are memory-mapped rather than host-resident, the BAR grows. | P7.1 | Platform lead |
| **O8** | **Windowed vs. fully mapped tables** — all five config regions are currently `ADDR`+`DATA` windows, which are compact but ⚠️ **not thread-safe** (§9.4 rule 1). Decide whether the risk table in particular should be fully mapped (256 symbols × 12 words × 4 B = 12 KiB) to remove the shared-cursor hazard entirely. | P7.2 | Risk owner |
| **O9** | **DMA ring descriptors** — only the control registers (`0x040`–`0x064`) are specified. The record layout is `telemetry_pkg::log_rec_t` (512 bits, one cache line); the *descriptor* format, the separate audit-vs-telemetry ring split, and the ring-full-arms-kill policy are not yet in RTL. | P7.1 | Platform lead |
| **O10** | Reconcile **D8** — the manual's §4 map vs the implemented map. One of them must stop being a specification. | P7.2 | Platform lead |
| **O11** | Reset-value audit: enumerate **every** register and confirm the reset is the safe value, mechanically, from `regmap.yaml`. The three called out in §1 are the ones known to matter; the audit is what proves there is no fourth. | P7.2 | Risk owner 🔒 |

---

## Further reading

- [`resource-budget.md`](resource-budget.md) — sizing of the parameter, template and telemetry memories these windows write into
- [`latency-budget.md`](latency-budget.md) — why nothing in this document is on the fast path
- [`adr/README.md`](adr/README.md) — the ADR index; ADR 0006 (session handoff), 0008/0009 (fail-closed reset, ARMED-at-reset, two-step re-arm) and 0011 (double-buffered parameter update) govern §6, §7 and §9
- [`../manuals/04-system-architecture/06-cpu-fpga-partitioning.md`](../manuals/04-system-architecture/06-cpu-fpga-partitioning.md) — the control-plane/data-plane split, PCIe latency figures, host process architecture, start-of-day and shutdown sequencing
- [`../manuals/06-operations/03-monitoring-and-telemetry.md`](../manuals/06-operations/03-monitoring-and-telemetry.md) — counter taxonomy, the snapshot bank, counter hazards, alerting tiers
- [`../manuals/06-operations/01-build-and-release.md`](../manuals/06-operations/01-build-and-release.md) — the build-ID gate behind `0x000`
- [`../rtl/ctrl/csr_regfile.sv`](../rtl/ctrl/csr_regfile.sv) — the implementation this document transcribes
- [`../rtl/telemetry/telemetry_pkg.sv`](../rtl/telemetry/telemetry_pkg.sv) — authoritative telemetry sub-map and DMA record layout
- [`../rtl/pkg/trading_pkg.sv`](../rtl/pkg/trading_pkg.sv) — `risk_reason_e`, `kill_src_e`, `sym_risk_t`, `sym_strat_t`
- [`../rtl/fpga_top.sv`](../rtl/fpga_top.sv) — the `cfg_*` and telemetry port surface
- [`../CLAUDE.md`](../CLAUDE.md) — §5 (fail-closed, kill switch bounded, every event counted), §6 (limit and kill changes are high blast radius)
