# `rtl/feed/` — ITCH Feed Handler

Nasdaq TotalView-ITCH 5.0 decode, symbol filtering, and venue-state tracking.
Instantiated by [`rtl/fpga_top.sv`](../fpga_top.sv) as `u_feed`.

Governing manuals:
- [04-system-architecture/02-feed-handler-design.md](../../manuals/04-system-architecture/02-feed-handler-design.md)
- [08-nasdaq/04-totalview-itch-5.0.md](../../manuals/08-nasdaq/04-totalview-itch-5.0.md)
- [08-nasdaq/02-sessions-auctions-and-halts.md](../../manuals/08-nasdaq/02-sessions-auctions-and-halts.md)
- [00-foundations/03-hdl-and-rtl-coding.md](../../manuals/00-foundations/03-hdl-and-rtl-coding.md)

---

## ⚠️ THIS LAYER IS NOT PRODUCTION-TRUSTWORTHY YET — OFFSET VERIFICATION REQUIRED

**Every ITCH field byte offset and message length used in this directory is
UNVERIFIED.** They come from two places, both flagged:

| Source | Status |
| --- | --- |
| [`rtl/pkg/itch_pkg.sv`](../pkg/itch_pkg.sv) `OFF_*` / `LEN_*` | Marked "verify against spec" in that file's own ⚠️ header |
| `itch_decoder.sv` §2 and `venue_state.sv` §1 localparams | Derived from published message layouts, **not read off a spec PDF**. `itch_pkg.sv` does not define them yet. |

The §2/§1 localparams cover the message types `itch_pkg.sv` has no offsets for:
`OFF_S_EVENT`, `OFF_H_STATE`, `OFF_h_ACTION`, `OFF_Y_ACTION`, `OFF_J_UPPER`,
`OFF_J_LOWER`, `OFF_K_QUAL`, `OFF_W_LEVEL`, `OFF_C_PRINTABLE`, `OFF_C_PRICE`,
`OPHALT_RESUMED`, `MWCB_LVL_1/2/3`. Each layout sums exactly to the `LEN_*`
total already in `itch_pkg.sv` — that is *evidence*, not *verification*.

### Before this RTL may be pointed at any venue session — including UAT

1. **Confirm every offset and length** against the current *Nasdaq
   TotalView-ITCH 5.0* specification PDF:
   <https://nasdaqtrader.com/Trading/TradingSpecs>.
   Nasdaq has revised message lengths across minor versions.
2. **Generate, do not transcribe.** Produce `itch_pkg.sv` from the spec tables
   with `scripts/gen_itch_pkg.py` and move the localparams above into it, so
   there is one source of truth. Hand-transcribed offsets are a
   silent-corruption bug class.
3. **Validate against an independent golden software model** — one written from
   the spec, *not* derived from this RTL — replayed field-by-field, in order,
   over a real pcap corpus **plus** the exhaustive alignment sweep in
   [feed-handler-design.md §12.3](../../manuals/04-system-architecture/02-feed-handler-design.md).

**Why this matters more than it looks.** A wrong offset does not produce a
decoder that fails. It produces one that works on some messages and silently
corrupts others: it does not stop, it does not count, it just trades on a wrong
book. That is the worst available failure mode in this domain.

---

## Files

| File | One line |
| --- | --- |
| [`feed_handler.sv`](feed_handler.sv) | Top of the layer; instantiates the three blocks below, owns the host config address map and the `stat[16]` counters. |
| [`itch_decoder.sv`](itch_decoder.sv) | One whole ITCH message in, one `book_evt_t` out — fixed-offset field extraction plus a type-indexed mux, **not** a parsing state machine. |
| [`symbol_filter.sv`](symbol_filter.sv) | Raw 16-bit stock locate → compact `sym_idx_t`, via a 1-cycle direct-index BRAM read — **not** a hash, **not** a CAM. |
| [`venue_state.sv`](venue_state.sv) | Per-symbol halt / SSR / LULD state and the global session state, from the non-book ITCH messages. Fail-closed. |

---

## Dataflow

```
 s_msg / s_len / s_valid / s_rx_cycle              (from rtl/net/net_rx_path.sv)
      │
      ▼
 ┌───────────────┐  book_evt_t      ┌───────────────┐  m_evt / m_evt_valid
 │ itch_decoder  ├─────────────────►│               ├───────────────────────► book_engine
 │   1 cycle     │                  │ symbol_filter │
 │ fixed-offset  │  venue side-band │   1 cycle     │  q_sym / q_hit
 │ field extract ├──────┐      ┌───►│ 2 read ports  ├──────┐
 └───────────────┘      │      │    └───────────────┘      │
                        ▼      │ q_locate                  ▼
                  ┌──────────┐ │                    ┌─────────────┐
                  │ align reg├─┴───────────────────►│ venue_state │
                  │ 1 cycle  │                      │  2 cycles   │
                  └──────────┘        s_gap ───────►│ fail-closed │
                                                    └──────┬──────┘
                                                           ▼
                          sess_state, sym_state_wr/idx/val, sym_ssr_val,
                          sym_luld_lo/hi   →  strategy_engine + risk_gate
```

---

## Latency budget — the rows this layer owns

From the master table in [`fpga_top.sv`](../fpga_top.sv), at 156.25 MHz /
**6.4 ns per cycle** (`trading_pkg::CORE_CLK_NS`):

| Stage | Module | cyc | ns | fixed? |
| --- | --- | ---: | ---: | --- |
| ITCH decode (fixed-offset extraction) | `itch_decoder` | 1 | 6.4 | fixed |
| Symbol filter + active-index map | `symbol_filter` | 1 | 6.4 | fixed |
| **Feed handler total (book path)** | | **2** | **12.8** | **fixed** |

- **Initiation interval = 1.** A message may be presented every cycle and one
  comes out every cycle. There are **no FIFOs and no backpressure anywhere in
  this layer** — the RX path must accept line rate unconditionally; we drop
  deliberately and count, never block (CLAUDE.md §5.4).
- **Zero latency variance.** Every message type takes the same 2 cycles. That is
  the entire reason the decoder is a fixed-offset mux and not an FSM: a
  byte-serial parser would cost 3–7 cycles *and* make latency a function of
  message length, injecting jitter proportional to the message mix.

Paths that are **not** on the tick-to-trade budget:

| Path | cyc | ns | Notes |
| --- | ---: | ---: | --- |
| Venue side-channel (decode → `sym_state_wr`) | 4 | 25.6 | Control path, not latency-critical |
| Gap / resync broadcast over the active set | `N_ACTIVE`+4 = 260 | ~1,664 | One symbol per cycle, bounded, non-blocking |

Numbers above are **design targets, not measurements** (CLAUDE.md §4). No
synthesis, no place-and-route, and no simulation has been run against this code
yet — see *Status* at the bottom.

---

## `stat[16]` counter map

`stat[0..14]` are **saturating** 32-bit counters — they stop at `0xFFFF_FFFF`
rather than wrapping, because a wrapped counter turns a health check into a
no-op. `stat[15]` is a bit-packed status word, **not** a counter.

Class: **[E]** error, page on any non-zero · **[N]** normal traffic, absence may
itself be the alarm · **[V]** volume.

| idx | Name | Class | Meaning |
| ---: | --- | :---: | --- |
| 0 | `msgs_in` | V | Messages presented on `s_valid` |
| 1 | `msgs_accepted` | V | Passed length validation (any type) |
| 2 | `err_len_mismatch` | **E** | Declared length ≠ type-implied length. **Message dropped** — we never guess a length; a wrong length means the field offsets are not trustworthy. |
| 3 | `unknown_type` | N | Type code not in `itch_msg_len()`. **Not an error** — Nasdaq adds message types. Counted, emitted as `BOOK_NOP`, never forwarded to the book. |
| 4 | `filter_hit` | V | Locate mapped to an active symbol |
| 5 | `filter_miss` | N | Locate not subscribed. **Normal** — this is the >85 % of the feed we chose not to do work for. |
| 6 | `err_bad_locate` | **E** | Locate `== 0` or `>= N_SYMBOLS` on a book-affecting message |
| 7 | `evt_out` | V | Book events forwarded to `book_engine` |
| 8 | `op_add` | V | `BOOK_ADD` — ITCH `A` / `F` |
| 9 | `op_exec` | V | `BOOK_EXECUTE` — ITCH `E` / `C` |
| 10 | `op_cancel_delete` | V | `BOOK_CANCEL` + `BOOK_DELETE` — ITCH `X` / `D` |
| 11 | `op_replace` | V | `BOOK_REPLACE` — ITCH `U` |
| 12 | `venue_sysevent` | V | ITCH `S` System Event |
| 13 | `venue_halt` | V | ITCH `H` Trading Action + `h` Operational Halt |
| 14 | `venue_ssr_luld` | V | ITCH `Y` Reg SHO + `J` LULD Auction Collar |
| 15 | `STATUS` | – | Bit-packed, see below |

### `stat[15]` STATUS word

| Bits | Field | Meaning |
| --- | --- | --- |
| `[2:0]` | `sess_state` | `trading_pkg::trade_state_e` |
| `[4:3]` | `mwcb_level` | 0 = none, else MWCB level 1 / 2 / 3 |
| `[5]` | `mwcb_l3` | ⚠️ Level 3 breach — the system must stop |
| `[6]` | `gap_sticky` | A sequence gap is outstanding; books are stale |
| `[7]` | `resync_pending` | A republish scan is running |
| `[15:8]` | `ipo_msg_cnt` | ITCH `K` IPO Quoting Period, saturating 8-bit |
| `[23:16]` | `mwcb_msg_cnt` | ITCH `V` + `W` MWCB messages, saturating 8-bit |
| `[31:24]` | `err_replace_ref` | ⚠️ **MUST BE ZERO.** ITCH `U` with `new_order_ref == order_ref`. Any non-zero value means the book is leaking order references, or `OFF_U_NEW_REF` is wrong. |

---

## Host config address map (`cfg_filter_addr` / `cfg_filter_data`)

`cfg_filter_addr[15]` is the region select.

### Region 0 — symbol filter table (`addr[15] == 0`)

| Field | Bits | Meaning |
| --- | --- | --- |
| `addr[14:0]` | 15 | ITCH stock locate code (must be `< N_SYMBOLS`) |
| `data[0]` | 1 | Subscribed |
| `data[8 +: ACT_IDX_W]` | 8 | Compact active-set index |

The host builds this at session start from the ITCH Stock Directory (`R`)
messages intersected with the traded-universe config file.
**Locate 0 must never be marked subscribed** — it means "not applicable" and is
used by the global messages. `symbol_filter` enforces this in hardware rather
than trusting the host, and `feed_handler` asserts it.

### Region 1 — venue control (`addr[15] == 1`)

| `addr[3:0]` | Register | Payload |
| ---: | --- | --- |
| 0 | **RESYNC COMPLETE** (the host-writable resync input) | `data[31]` = apply to **all** symbols and clear the global gap flag; `data[ACT_IDX_W-1:0]` = symbol index when `data[31] == 0` |
| 1 | **STICKY CLEAR** | `data[0]` = clear the MWCB level. ⚠️ After a Level 3 breach this is a deliberate operator decision and it should **not** be taken — a Level 3 MWCB halts the market for the day. |

⚠️ `cfg_clk` **must** be the same clock as `clk`. `fpga_top` ties both to
`core_clk`, and `host_ctrl` owns all CDC on its own side. `cfg_clk` is passed
down to `symbol_filter` (whose table is a dual-clock memory and could therefore
move to the PCIe domain later); the region-1 registers are captured on `clk`. If
the clocks are ever made different, those registers must move with the table,
behind a sanctioned synchroniser — never a hand-rolled one.

---

## Design decisions worth knowing before you edit

### The decoder is not a parser, and must never become one
Every ITCH 5.0 message type has a fixed length and fixed field offsets, and the
message arrives byte-0-aligned in one `ITCH_MSG_W`-bit beat. So every field of
every type sits at a **compile-time constant bit offset**, and decode is
`constant part-selects + one 8-bit type-indexed mux`. Adding a message type is
one `case` arm — not a new state, not a new transition, and it cannot break the
decode of any other type. The mux tree costs a few hundred LUTs; that is the
right trade against variable latency.

### The symbol lookup is a direct index because locate codes are dense
Nasdaq assigns stock locate codes sequentially over the securities in the
session. A dense integer key **is** a memory address, so `act_idx = table[locate]`
is a 1-cycle BRAM read with zero collisions. A hash needs collision handling
(variable probes = jitter, or bounded probes = spurious rejects); a CAM is N
parallel comparators whose Fmax degrades with depth; a cache has a miss path,
and the RX path cannot stall. If a future venue makes locate codes sparse this
design does **not** degrade gracefully — resize the table or replace the lookup,
but do not hash into it.

### `E` vs `C`, and why neither carries a book price
- **`E` Order Executed** carries executed shares and **no price**. The fill price
  is the resting order's price, which lives in the book — the book engine looks
  it up via `order_ref`. `book_evt_t.price` is left at zero deliberately.
- **`C` Order Executed With Price** has the *same book effect*, but also carries
  the price the trade actually executed at (which may differ from the display
  price) plus a printable flag. ⚠️ That price is **trade-print information, not a
  book key** — the book must still remove the shares at the resting order's own
  price level. Using `evt.price` as the level key for a `C` corrupts the book.

### `U` is not an in-place modify
Order Replace removes the **original** reference entirely and creates a **new**
one. Both are populated: `order_ref` = the original (remove it from the map),
`new_order_ref` = the replacement (add it). A book that mutates in place leaks
the original reference forever — all future messages name the new reference, so
the old one is never deleted — and drifts from the true book. Asserted in both
`itch_decoder.sv` and `feed_handler.sv`, and counted in `stat[15][31:24]`.

### Fail-closed everywhere in `venue_state`
- Reset value for **every** symbol is `TRADE_DISABLED`.
- `ssr_active` resets to **1** — assume the Rule 201 short-sale price test is in
  force until told otherwise.
- LULD bands reset to `0 / 0`, a band nothing can be inside, so the risk gate
  rejects until real bands are loaded.
- Unknown Trading Action code → `TRADE_DISABLED`. Unknown Operational Halt code
  → halted. Unknown Reg SHO code → restricted. Unknown System Event → closed.
- Memory arrays (`symbol_filter`'s table, the LULD band store) are cleared by an
  `initial` block, because a synchronous `rst` cannot clear a memory. Empty table
  = everything filtered = nothing reaches the book until the host loads it.

### A gap stales *everything*
`s_gap` tells you exactly one thing: **you do not know what you missed.** So
every active symbol goes to `TRADE_STALE`, not a heuristic subset, and stays
there until the host resynchronises and says so. `TRADE_STALE` is an independent
overlay bit, so the venue-derived state underneath keeps being updated by
`S`/`H`/`h`/`Y`/`J` during the outage and is *restored*, not guessed, on resync.
Decoding never stalls during a gap.

### ⚠️ ITCH `J` is not the continuous LULD band feed
`J` carries **auction collars**, published around auctions and LULD pauses. The
continuous LULD price bands come from the SIP (CTA/UTP LULD), which this FPGA
does not consume. **The host must write the continuous bands into `risk_gate`'s
own `cfg_risk_*` parameter window.** Treat the `sym_luld_*` side-channel as the
auction overlay, never as the sole source of truth. Getting the band wrong sends
rejectable orders to the venue.

### The MWCB stop path
`W` MWCB Status sets a sticky level. Level 1/2 force `sess_state` to
`TRADE_HALTED`; **Level 3 forces `TRADE_CLOSED`**. Every strategy and the risk
gate read `sess_state`, so that is the mechanism by which a Level 3 breaker
stops the system. Clearing it requires a deliberate host write to region 1
register 1.

---

## Status

**Written, not yet proven.** Per CLAUDE.md §4 ("do not report done until
place-and-route timing closes") this layer is at the *first* of five steps:

- [x] RTL written against the coding standard
- [ ] Verilator `-Wall` lint — **not run** (no Verilator on this machine)
- [ ] cocotb / pcap simulation against an independent golden model — **not written**
- [ ] Synthesis — **not run**; every LUT/FF/BRAM figure in the module headers is
      an *estimate*, and must be replaced with quoted tool output
- [ ] Place-and-route, WNS/TNS quoted verbatim — **not run**

Required testbench work, from
[feed-handler-design.md §12](../../manuals/04-system-architecture/02-feed-handler-design.md):
`tb/feed/` with a pure-Python oracle written from the spec (not from this RTL),
a pcap driver, the exhaustive alignment sweep, a line-rate soak, every gap
shape, length-mismatch and unknown-type injection, and a fuzz run proving no
input sequence can wedge the pipeline.
