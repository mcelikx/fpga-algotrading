# 04.01 — Tick-to-Trade Pipeline

> **Why this matters here:** this is the reference document for the whole system.
> Every block in `rtl/` owns exactly one row of the master budget table in §3, and
> every design decision anywhere else in these manuals is checked against it. If a
> change moves a number in §3, it changes this document first and the RTL second.

---

## 1. What "tick-to-trade" means, precisely

Nobody quotes this number the same way, so we define ours and never quote another
without saying which convention it uses.

**Our definition — `T2T`:**

> The interval from **the last bit of the triggering ITCH message crossing the RX
> optical interface** to **the first bit of the resulting Ethernet frame crossing the
> TX optical interface**, measured at the SFP+ cage on the same card.

Three consequences of picking that definition:

| Consequence | Why |
| --- | --- |
| Inbound serialization is **excluded** | You cannot act on a message before its last byte exists. Including it just measures how long the venue's message is. |
| Outbound serialization is **excluded** | The race is won at the first bit on the wire; the venue's gateway is also cut-through. |
| The number is **message-type dependent** | An `Order Delete` (19 B) and a `Trade` (44 B) have different inbound serialization, which we excluded — so our number is *stable* across types. That is the point. |

Two other conventions you will see in vendor material, and what to add to compare:

| Convention | Relationship to ours |
| --- | --- |
| First-bit-in → first-bit-out | `T2T + inbound serialization` (+15 ns for a 19 B msg, +35 ns for a 44 B msg @ 10G) |
| Last-bit-in → last-bit-out | `T2T + outbound serialization` (+~60 ns for a 74 B OUCH-over-TCP frame) |
| Switch-port to switch-port ("loopback") | `T2T + 2× cable + 2× switch hop`; adds 100–1000 ns and says nothing about your design |

> **Verify:** serialization at 10GbE is 0.8 ns/byte on the wire (10 Gb/s line rate,
> 64b/66b encoded → 10.3125 Gbaud). Confirm against the IEEE 802.3 Clause 49 PCS
> description before quoting it in a report.

**Targets.** `T2T` design target **400 ns**, hard ceiling **1000 ns**, stretch goal
**< 350 ns** once the fabric is measured. All numbers in this document are **design
targets and estimates**, not measurements. Nothing here has been run on hardware.
Replace each row with a measured value as it becomes available, and mark it.

---

## 2. The end-to-end block diagram

```
   MARKET DATA IN                                                    ORDERS OUT
   ITCH 5.0 / MoldUDP64 / UDP multicast                    OUCH 5.0 / SoupBinTCP / TCP
   ─────────────────────────────────                       ────────────────────────────

     fibre A         fibre B                                          fibre
        │               │                                               ▲
   ┌────▼───┐      ┌────▼───┐                                     ┌─────┴────┐
   │  SFP+  │      │  SFP+  │  optics / PMD                       │   SFP+   │
   └────┬───┘      └────┬───┘                                     └─────▲────┘
   ┌────▼───┐      ┌────▼───┐                                     ┌─────┴────┐
   │ GTY RX │      │ GTY RX │  SerDes / PMA, CDR                  │  GTY TX  │
   └────┬───┘      └────┬───┘                                     └─────▲────┘
   ┌────▼───┐      ┌────▼───┐                                     ┌─────┴────┐
   │ PCS RX │      │ PCS RX │  64b/66b, descramble, align         │  PCS TX  │
   └────┬───┘      └────┬───┘                                     └─────▲────┘
   ┌────▼───┐      ┌────▼───┐                                     ┌─────┴────┐
   │ MAC RX │      │ MAC RX │  cut-through, CRC in flight         │  MAC TX  │
   └────┬───┘      └────┬───┘                                     └─────▲────┘
        │ 64b AXI-S     │ 64b AXI-S                                     │ 64b AXI-S
   ┌────▼───────────────▼───┐                                     ┌─────┴──────────┐
   │  eth / ipv4 / udp rx   │  header parse, group→channel        │ eth + ipv4 tx  │
   └────────────┬───────────┘                                     │ build + cksum  │
   ┌────────────▼───────────┐                                     └─────▲──────────┘
   │  mold_deframe  ×2      │  MoldUDP64 hdr, seq, msg count      ┌─────┴──────────┐
   └────────────┬───────────┘                                     │  tcp_tx_lite   │
   ┌────────────▼───────────┐                                     │  + soupbin_tx  │
   │  ab_arbiter            │  first-wins per sequence number     └─────▲──────────┘
   │  seq_tracker           │  gap detect → STALE                 ┌─────┴──────────┐
   └────────────┬───────────┘                                     │  ouch_encode   │
   ┌────────────▼───────────┐                                     │  template RAM  │
   │  msg_realign           │  64 B window, byte barrel shift     │  + token_gen   │
   └────────────┬───────────┘                                     └─────▲──────────┘
   ┌────────────▼───────────┐                                     ┌─────┴──────────┐
   │  itch_dispatch         │  fixed-offset field extract         │ ▓▓ risk_gate ▓▓│ ◀── kill_switch
   └────────────┬───────────┘                                     │ ▓ NON-BYPASS ▓ │
   ┌────────────▼───────────┐                                     └─────▲──────────┘
   │  symbol_filter         │  locate → subscribed? → slot                │
   └────────────┬───────────┘                                     ┌──────┴─────────┐
   ┌────────────▼───────────┐        book_cmd                     │  strat_top     │
   │  book_top              │───────────────────────────────────▶ │  param_table   │
   │   order_map (URAM)     │        bbo_upd                      │  my_orders     │
   │   level_array (URAM)   │                                     └────────────────┘
   │   tob_track            │                                              ▲
   └────────────────────────┘                                              │
                                                                    ack_evt│
   ┌──────────────────────────────────────────────────────────────────┐    │
   │  ouch_ack_decode  ◀── MAC RX (order session)  ── accepted/exec ───┼────┘
   └──────────────────────────────────────────────────────────────────┘

   ══════════════════════ PCIe Gen3 x16 ══════════════════════════════════════════
        BAR0 control/status regs  │  DMA log ring (audit) │ DMA log ring (telemetry)
   ═══════════════════════════════════════════════════════════════════════════════
                 │                          │                        │
      ┌──────────▼─────────┐   ┌────────────▼───────┐   ┌────────────▼──────────┐
      │  ttd-control       │   │  ttd-risk          │   │  ttd-logger           │
      │  arm/disarm, wdog  │   │  position recon    │   │  drain ring → disk    │
      └────────────────────┘   │  PnL, kill auth    │   └───────────────────────┘
      ┌────────────────────┐   └────────────────────┘   ┌───────────────────────┐
      │  ttd-params        │                            │  gap recovery client  │
      │  slow signals →    │                            │  (MoldUDP64 rerequest │
      │  double-buf params │                            │   / Glimpse snapshot) │
      └────────────────────┘                            └───────────────────────┘
                              ── CPU SLOW PATH, ms scale ──
```

The shaded `risk_gate` is the only route from the strategy to the MAC. There is no
second path. See [05-order-gateway-and-pre-trade-risk.md](05-order-gateway-and-pre-trade-risk.md).

---

## 3. The master latency budget

Clock **156.25 MHz**, period **6.4 ns**. Datapath **64-bit** from the MAC, single
clock domain from `eth_rx_parse` through `eth_tx_build`.

Path measured: an `Order Delete` that removes the current best bid, causing the
strategy to fire and the risk gate to pass. This is the **canonical trigger path** —
every other path is either shorter or off-budget.

| # | Stage | Block | Cycles | ns | Cum. ns | Fixed? |
| --- | --- | --- | ---: | ---: | ---: | --- |
| P0 | Optical RX (ROSA, PMD) | SFP+ module | — | 5.0 | 5.0 | fixed |
| P1 | GT RX PMA (CDR, deserialize) | `gt_wrap` | — | 55.0 | 60.0 | fixed ±1 UI |
| P2 | PCS RX (block sync, 64b/66b, descramble) | hard PCS | — | 35.0 | 95.0 | **variable** ±2 cyc |
| P3 | MAC RX (cut-through, preamble strip) | `eth_mac_10g_wrap` | 3 | 19.2 | 114.2 | fixed |
| R0 | Ingress register + hardware timestamp | `ts_capture` | 1 | 6.4 | 120.6 | fixed |
| R1 | Eth / IPv4 / UDP parse, group → channel | `ipv4_udp_rx_parse` | 1 | 6.4 | 127.0 | fixed |
| R2 | MoldUDP64 header, seq check, A/B arbitrate | `mold_deframe`, `ab_arbiter` | 1 | 6.4 | 133.4 | fixed¹ |
| R3 | Message realign (64 B window barrel shift) | `msg_realign` | 1 | 6.4 | 139.8 | fixed |
| R4 | ITCH type dispatch + fixed-offset extract | `itch_dispatch` | 1 | 6.4 | 146.2 | fixed |
| R5 | Symbol filter (locate → subscribed, slot) | `symbol_filter` | 1 | 6.4 | 152.6 | fixed |
| B0 | Order-ID hash (CRC-32 XOR tree) | `order_map_hash` | 1 | 6.4 | 159.0 | fixed |
| B1 | Order-ID map read + way select | `order_map` | 1 | 6.4 | 165.4 | **variable**² |
| B2 | Level address + level array read | `level_array` | 1 | 6.4 | 171.8 | fixed |
| B3 | Level read-modify-write + bypass | `level_rmw` | 1 | 6.4 | 178.2 | fixed |
| B4 | Top-of-book incremental update, publish | `tob_track` | 1 | 6.4 | 184.6 | **variable**³ |
| S0 | Param read (speculative from R5) + gating | `param_table`, `gating` | 1 | 6.4 | 191.0 | fixed |
| S1 | Comparator bank → decision, size, price | `prim_*` | 1 | 6.4 | 197.4 | fixed |
| T0 | Risk stage 1 — precomputed-bit gates | `risk_gate` | 1 | 6.4 | 203.8 | fixed |
| T1 | Risk stage 2 — arithmetic gates | `risk_gate` | 1 | 6.4 | 210.2 | fixed |
| T2 | OUCH template read (speculative from S0) | `ouch_template_ram` | 1 | 6.4 | 216.6 | fixed |
| T3 | Template splice (px/qty/side/token) | `ouch_encode` | 1 | 6.4 | 223.0 | fixed |
| T4 | SoupBinTCP + TCP header, seq splice | `soupbin_tx`, `tcp_tx_lite` | 1 | 6.4 | 229.4 | fixed⁴ |
| T5 | IPv4 + Eth header, incremental checksum | `eth_tx_build`, `cksum_incr` | 1 | 6.4 | 235.8 | fixed |
| T6 | TX handoff, first beat to MAC | `tx_mux` | 1 | 6.4 | 242.2 | fixed |
| P4 | MAC TX (cut-through, preamble + FCS) | `eth_mac_10g_wrap` | 3 | 19.2 | 261.4 | fixed |
| P5 | PCS TX (scramble, 64b/66b, gearbox) | hard PCS | — | 30.0 | 291.4 | fixed |
| P6 | GT TX PMA (serialize) | `gt_wrap` | — | 50.0 | 341.4 | fixed |
| P7 | Optical TX (TOSA) | SFP+ module | — | 5.0 | 346.4 | fixed |
| — | **Unallocated contingency** | — | — | 53.6 | **400.0** | — |

**Fabric total: 20 cycles = 128.0 ns.** PHY/MAC total: 218.4 ns (RX 114.2 + TX 104.2).

¹ Fixed for the *first* message in a MoldUDP64 packet. Messages 2..N skip R1/R2 —
they are *cheaper*, not more expensive. See §5.
² +2 cycles on a hash-set overflow. See [03-order-book-in-hardware.md](03-order-book-in-hardware.md) §4.
³ +2 cycles when the delete empties the current best and a rescan is required. §5.
⁴ Fixed only while the FPGA owns the TX stream and the TCP window is open. §6.

> **Verify:** P0–P7 are vendor-datasheet estimates for a UltraScale+ GTY + hard
> 10G PCS/MAC in low-latency mode. Source them from the AMD *UltraScale
> Architecture GTY Transceivers* user guide (UG578) and the *10G/25G Ethernet
> Subsystem* product guide (PG210) latency tables for your exact configuration,
> then replace these rows with the datasheet figures and note the config
> (FEC off, elastic buffer bypassed, `TXBUF`/`RXBUF` bypass, async gearbox).
> They are also the single largest block of latency in the system, so getting the
> real number matters more than shaving a fabric cycle.

---

## 4. What is actually on the critical path

Only the stages in §3 are. Everything below runs **concurrently** and must never be
allowed to insert itself into the chain.

| Off-path work | Where it runs | Why it is off-path |
| --- | --- | --- |
| Non-book ITCH messages (`R`, `H`, `Y`, `I`, `P`, …) | Same decode pipeline, diverted at R5 | Never produce a `book_cmd`; they update gating bits and reference state |
| Unsubscribed symbols | Dropped at R5 | ~9000 Nasdaq-listed + traded symbols vs. our subscribed subset |
| Gap detection and recovery | `seq_tracker` → CPU | Detection is 1 comparator inline; *recovery* is a CPU job at ms scale |
| Position, PnL, reconciliation | `ttd-risk` on the CPU | Reads the DMA audit ring; hardware keeps its own copy for the risk gate |
| Strategy parameter computation | `ttd-params` on the CPU | Writes shadow banks; the FPGA never waits on it |
| Telemetry, latency histograms, logging | `telemetry/`, DMA | Taps the pipeline; a tap has zero effect on the tapped path |
| OUCH ack/fill decode | `ouch_ack_decode` | Return path. Must be fast (< 1 µs) for risk accuracy, but is not in `T2T` |
| Order-book resynchronization | `book_resync` + CPU | Only runs when a symbol is already STALE and therefore not trading |

**The rule:** a block is on the critical path if and only if it appears in §3. Adding
a block to the chain requires adding a row and removing an equal number of
nanoseconds elsewhere. There is no "it's only one cycle."

⚠️ The most common way this rule gets violated in practice is a *shared resource*.
If the telemetry tap and the book contend for the same BRAM port, telemetry is now on
the critical path even though it has no row in the table. Every memory on the fast
path is **simple dual-port with the fast path owning port A exclusively**, and
telemetry reads port B. Never arbitrate a fast-path port.

---

## 5. Fixed vs. variable latency, and every source of jitter

Determinism is the product ([00-foundations/01-digital-logic-and-timing.md](../00-foundations/01-digital-logic-and-timing.md) §5).
This is the complete inventory of places where our design is *not* fixed-latency,
what each costs, and what we do about it.

| # | Jitter source | Cost | Rate | Mitigation / policy |
| --- | --- | ---: | --- | --- |
| J1 | PCS RX clock-compensation / gearbox slip | ±1–2 cyc (±6–13 ns) | continuous | Irreducible. Bypass elastic buffers where the GT allows it. Measure and report; do not try to remove. |
| J2 | Message *k* in an *N*-message MoldUDP64 packet | +0 to +(k−1)×1 cyc | common | Book is II=1, so each preceding book-affecting message costs 1 cycle of queueing, not 5. Preceding *filtered* messages cost 0. |
| J3 | Order-map hash set overflow | +2 cyc (12.8 ns) | rare (< 10⁻⁴) | 4-way set-associative + overflow region. Counted per occurrence. |
| J4 | Best-level delete requiring a rescan | +2 cyc (12.8 ns) | ~1 in 20 deletes | Occupancy bitmap + 256-bit priority encoder over a bounded window. Bounded, never unbounded. |
| J5 | `Order Replace` (`U`) = delete + add | +1 cyc | ~10 % of order msgs | Expands to two `book_cmd`s. The second costs one extra cycle. Documented, not hidden. |
| J6 | Level RMW same-address hazard | **0** | frequent | Write-forwarding bypass. This is *why* we bypass rather than stall — a stall here would be the largest jitter source in the system. |
| J7 | A/B arbitration | **0** | continuous | Both feeds are decoded in parallel to the point of the sequence compare; the first arrival wins. Arbitration is a mux, not a queue. |
| J8 | Risk gate | **0** | every order | All checks evaluate in parallel; the result is an AND-reduction. Fixed 2 cycles pass *or* fail. |
| J9 | TCP window closed / retransmit pending | order is **not sent** | very rare | Fail-closed: the FPGA stops emitting and hands to the CPU. This is a functional event, not a latency event. |
| J10 | Parameter commit collision | **0** | on writes | Double-buffered with a single-cycle atomic bank flip. See [04-strategy-engine-on-fpga.md](04-strategy-engine-on-fpga.md) §5. |
| J11 | Contention for the outbound MAC with the CPU path | +0 to +12 cyc | rare | Fixed-priority arbiter, fast path at priority 0. The CPU can only be *ahead* of us if it started a frame first; bound its frame size. |

**Resulting distribution (design estimate, unmeasured):**

| Statistic | Estimate | Composition |
| --- | ---: | --- |
| p50 | ~350 ns | clean single-message packet, book hit, no rescan |
| p99 | ~365 ns | + J4 rescan |
| p99.9 | ~390 ns | + J2 queueing behind 2–3 book messages |
| max (bounded) | ~450 ns | J1 + J2(worst credible burst) + J3 + J4 + J5 + J11 |

⚠️ There is no unbounded case in this table, and that is deliberate. **Any design
change that introduces an unbounded wait on the fast path is rejected on sight**, no
matter what it does to the mean. If a block cannot complete in a bounded number of
cycles it does not belong on the fast path; it belongs behind a drop-and-count.

---

## 6. Module hierarchy and the `rtl/` tree

```
rtl/
├── top/
│   ├── tt_top.sv                 top level: clocking, resets, block instantiation
│   ├── tt_pkg.sv                 stream structs, opcodes, shared typedefs
│   └── tt_params_pkg.sv          N_SYMBOLS, N_LEVELS, N_ORDERS, budget constants
├── common/
│   ├── cdc/{sync_2ff,async_fifo_gray,handshake_cdc}.sv
│   ├── skid_buffer.sv  delay_line.sv  prio_enc.sv  crc32.sv
│   ├── sat_add.sv  sat_counter.sv  token_bucket.sv
│   └── mem/{bram_sdp,uram_sdp,lutram_sdp}.sv     vendor-wrapped, latency-parameterised
├── net/
│   ├── gt_wrap.sv  eth_mac_10g_wrap.sv           vendor IP behind our interface
│   ├── eth_rx_parse.sv  ipv4_udp_rx_parse.sv
│   ├── eth_tx_build.sv  ipv4_udp_tx_build.sv  cksum_incr.sv
│   └── tcp/{tcp_tx_lite,tcp_rx_lite,soupbin_tx,soupbin_rx}.sv
├── feed/                                          ← 04.02
│   ├── mold_deframe.sv  ab_arbiter.sv  seq_tracker.sv
│   ├── msg_realign.sv   itch_dispatch.sv  itch_pkg.sv
│   ├── symbol_filter.sv symbol_table.sv
│   └── feed_stats.sv
├── book/                                          ← 04.03
│   ├── book_top.sv
│   ├── order_map.sv  order_map_hash.sv
│   ├── level_array.sv  level_rmw.sv  occupancy_bmap.sv
│   ├── tob_track.sv  book_resync.sv  book_epoch.sv
├── strategy/                                      ← 04.04
│   ├── strat_top.sv  param_table.sv  param_commit.sv
│   ├── gating.sv  my_orders.sv
│   └── prim/{prim_quote,prim_take,prim_fade,prim_null}.sv
├── risk/                                          ← 04.05
│   ├── risk_gate.sv  risk_limits.sv  risk_counters.sv
│   ├── kill_switch.sv  rate_limiter.sv  position_track.sv
├── gateway/                                       ← 04.05
│   ├── ouch_encode.sv  ouch_template_ram.sv  token_gen.sv
│   ├── ouch_ack_decode.sv  inflight_credit.sv  tx_mux.sv
├── host/                                          ← 04.06
│   ├── pcie_wrap.sv  reg_file.sv  reg_map_pkg.sv
│   ├── dma_log_ring.sv  param_dma_rx.sv  watchdog.sv
└── telemetry/
    ├── ts_capture.sv  latency_hist.sv  event_log.sv
```

Mirrored one-for-one in `tb/` (`tb/feed/`, `tb/book/`, …) and `constraints/`
(`constraints/tt_top_timing.xdc`, `constraints/tt_top_pins.xdc`,
`constraints/floorplan.xdc`).

**Single-SLR rule.** Everything from `eth_rx_parse` to `eth_tx_build` — the whole of
§3 rows R0..T6 — is floorplanned into **one SLR** with a `pblock`. `host/` and
`telemetry/` may cross SLRs freely. An SLR crossing costs a mandatory register stage
(~1 cycle) and, worse, a routing delay you cannot predict from RTL. See
[00-foundations/02-fpga-architecture.md](../00-foundations/02-fpga-architecture.md).

---

## 7. Interface contracts between the major blocks

### 7.1 The fast-path event contract

Between R0 and T6, blocks do **not** use valid/ready. They use a **single-cycle valid
pulse with no backpressure**:

```systemverilog
typedef struct packed {
    logic        valid;      // 1-cycle pulse, no ready
    logic [63:0] tstamp;     // ingress timestamp, carried end-to-end
    // ... payload
} fastpath_evt_t;
```

The contract:

1. The producer asserts `valid` for exactly one cycle and holds payload valid on
   that cycle only.
2. The consumer **must** accept it. Every fast-path block is II = 1 by construction.
3. A consumer that *cannot* accept **drops and counts**. It never stalls its producer.
4. `tstamp` is captured once at R0 and propagates unchanged to T6, where
   `latency_hist` subtracts it from the current time.

⚠️ This is the opposite of the AXI-Stream contract used at the MAC boundary
([../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) §1).
Do not mix them. `s_tready` into `eth_rx_parse` is **tied high** and there is an
assertion that fires if anything downstream ever asserts a ready that is not
constant-1.

### 7.2 Named streams

| Stream | Producer → Consumer | Payload | Width | Contract |
| --- | --- | --- | ---: | --- |
| `s_mac_rx` | MAC → `eth_rx_parse` | `tdata`,`tkeep`,`tlast`,`tuser` | 64 + 8 + 2 | AXI-S, `tready` tied 1 |
| `mold_msg` | `mold_deframe` → `itch_dispatch` | one ITCH message, byte 0 aligned | 512 + 6 (len) | event pulse |
| `itch_evt` | `itch_dispatch` → `symbol_filter` | `{type, locate, tracking, ts, oid, px, qty, side, flags}` | 224 | event pulse |
| `book_cmd` | `symbol_filter` → `book_top` | `{op[3], slot[11], oid[63:0], lvl[10:0], qty[31:0], side}` | 128 | event pulse |
| `bbo_upd` | `book_top` → `strat_top` | `{slot, bid_lvl, bid_qty, bid_cnt, ask_lvl, ask_qty, ask_cnt, stale, halted}` | 160 | event pulse |
| `ord_req` | `strat_top` → `risk_gate` | `{slot, side, px[31:0], qty[31:0], tif[2], prim_id[3], strat_seq}` | 96 | event pulse |
| `ord_ok` | `risk_gate` → `ouch_encode` | `ord_req` + `{token[31:0], risk_stamp}` | 144 | event pulse |
| `tx_frame` | `eth_tx_build` → MAC | AXI-S | 64 + 8 | AXI-S, `tready` honoured (skid) |
| `ack_evt` | `ouch_ack_decode` → `risk_gate`, `strat_top` | `{token, state[3], fill_qty, fill_px, reason[7]}` | 96 | event pulse |
| `log_evt` | any → `dma_log_ring` | 64-byte audit/telemetry record | 512 | credit-based, droppable (telemetry) / kill-on-full (audit) |
| `reg_bus` | `reg_file` → all | address/data/we | 16 + 32 | not on the fast path; CDC'd |

Every one of these is declared once in `rtl/top/tt_pkg.sv`. **No block defines its own
copy of a shared struct.**

---

## 8. Budget ownership

Every synthesizable module on the fast path declares its budget as a parameter and
its header carries the row number from §3:

```systemverilog
// ─────────────────────────────────────────────────────────────────────────────
// book/level_rmw.sv
// Budget row : B3  (04-system-architecture/01-tick-to-trade-pipeline.md §3)
// Latency    : 1 cycle  = 6.4 ns @ 156.25 MHz   (fixed, no stall path)
// Resources  : ~340 LUT, ~510 FF, 0 BRAM, 12 URAM (shared with level_array)
// Jitter     : none. Same-address hazard is bypassed, not stalled (J6).
// ─────────────────────────────────────────────────────────────────────────────
module level_rmw #(
    parameter int unsigned LATENCY_CYCLES = 1   // MUST match budget row B3
) ( ... );
```

and proves it in simulation:

```systemverilog
`ifndef SYNTHESIS
    // Fires if the block ever takes more (or fewer) cycles than it declared.
    int unsigned in_cnt, out_cnt;
    always_ff @(posedge clk) begin
        if (rst) begin in_cnt <= 0; out_cnt <= 0; end
        else begin
            if (cmd_valid) in_cnt  <= in_cnt  + 1;
            if (rsp_valid) out_cnt <= out_cnt + 1;
        end
    end
    property p_fixed_latency;
        @(posedge clk) disable iff (rst)
        cmd_valid |-> ##LATENCY_CYCLES rsp_valid;
    endproperty
    assert property (p_fixed_latency)
        else $error("%m: declared LATENCY_CYCLES=%0d violated", LATENCY_CYCLES);
`endif
```

**The rules:**

1. **Every fast-path block owns exactly one row of §3.** If it does not have a row,
   it is not on the fast path, and it must be structurally incapable of stalling
   anything that is.
2. **A block may not exceed its row.** Exceeding it is a build-breaking regression,
   not a discussion. `scripts/check_budget.py` parses the module headers, sums them,
   and fails CI if the total exceeds 20 cycles.
3. **To add a cycle, remove a cycle.** The fabric total is a fixed 20-cycle envelope
   until someone measures the PHY and re-derives the budget from real numbers.
4. **Contingency is not a bank you can withdraw from.** The 53.6 ns in §3 exists
   because P0–P7 are estimates. It is released only when the PHY numbers are
   measured, and then it is re-budgeted deliberately.
5. **Measured beats estimated, always.** When a row is measured on hardware, replace
   it and annotate `(measured, N=…)`. Estimated and measured numbers are never summed
   without labelling the result as estimated.

---

## 9. What this budget assumes, and what breaks it

| Assumption | If it is false |
| --- | --- |
| The MAC is cut-through, not store-and-forward | +~60 ns each way for a 74-byte frame. Renegotiate the whole budget. |
| A single ITCH channel (one A/B pair) drives the book | Two channels need arbitration into `book_top`: +1 cycle and J-row for contention |
| The subscribed universe fits `N_SYMBOLS = 128` | Memory budgets in 04.03 scale linearly; the *latency* does not change |
| The strategy is one comparator bank deep | Any strategy needing a multiply-accumulate chain adds cycles at S1 |
| OUCH orders are a single TCP segment with no options | Segmentation, or a TCP option that changes header length, breaks the template splice at T4 |
| Prices are ≥ $1.00 so the tick is $0.01 | Sub-dollar names need a different tick normalization; see 04.03 §5 |
| Everything R0..T6 lands in one SLR | Each crossing is +1 cycle and unpredictable routing |

---

## Further reading

- [02-feed-handler-design.md](02-feed-handler-design.md) — rows R0–R5 in detail
- [03-order-book-in-hardware.md](03-order-book-in-hardware.md) — rows B0–B4 in detail
- [04-strategy-engine-on-fpga.md](04-strategy-engine-on-fpga.md) — rows S0–S1 in detail
- [05-order-gateway-and-pre-trade-risk.md](05-order-gateway-and-pre-trade-risk.md) — rows T0–T6 in detail
- [06-cpu-fpga-partitioning.md](06-cpu-fpga-partitioning.md) — the slow path and the PCIe boundary
- [../01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) — why the budget has the shape it has
- [../00-foundations/01-digital-logic-and-timing.md](../00-foundations/01-digital-logic-and-timing.md) — where nanoseconds come from
- [../08-nasdaq/](../08-nasdaq/) — ITCH/OUCH message references, session times, venue-specific rules
