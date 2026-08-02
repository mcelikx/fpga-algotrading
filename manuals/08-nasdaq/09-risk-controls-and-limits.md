# 08.09 — Risk Controls and Limits (Nasdaq US Equities)

> **Why this matters here:** this is the file that turns everything else in this tier
> into gates in the order path. Every rule in
> [06-regnms-and-compliance.md](06-regnms-and-compliance.md), every session state in
> [02-sessions-auctions-and-halts.md](02-sessions-auctions-and-halts.md), and every
> field in [05-ouch-5.0-order-entry.md](05-ouch-5.0-order-entry.md) converges here as
> a comparator, a parameter register, and a rejection counter. The risk block is the
> last thing an order passes before it becomes real money. **It is the only block in
> the design where "it was slightly wrong but it still worked" is not a possible
> outcome.**

---

## 0. The three principles

1. **Fail closed.** Any ambiguity, any uninitialised state, any staleness, any
   overflow, any unknown → **reject**. Never "allow because we're not sure".
2. **No bypass.** The risk gate is the only path from strategy to TX. There is no
   debug path, no software path, no "temporary" path. (CLAUDE.md §5.5, SEC Rule
   15c3-5 — see [06-regnms-and-compliance.md](06-regnms-and-compliance.md) §7.)
3. **Everything is counted.** Every check has a rejection counter. A check that has
   never been observed to fire is a check you cannot trust.

---

## 1. The complete pre-trade check specification

Cycle costs assume a **250 MHz core clock (4 ns/cycle)** and a datapath where the
symbol parameter record has already been fetched (§6). Costs are the *pipeline stages
added*, not a serial sum — most of these evaluate **in parallel** and are reduced by
an AND-tree, so the whole block is a handful of cycles.

| # | Check | Prevents | Inputs | Parameters | Scope | Regulatory basis | Cycles |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | **Trading enabled (master)** | Everything, at once | `trading_enabled` reg | — | Global | 15c3-5 | 0 (AND at the end) |
| 2 | **Kill-switch latch** | Runaway algorithm | Kill sources (§5) | — | Global | 15c3-5 | 0 (same AND) |
| 3 | **Per-symbol enabled** | Trading a symbol you are not approved for | `sym_enabled[sym]` | — | Per-symbol | 15c3-5(c)(2) | 0 (in record) |
| 4 | **Session / time window** | Orders outside permitted hours | Time-of-day counter, session state | `t_open`, `t_close` per symbol class | Global + per-symbol | Venue rules | 1 |
| 5 | **Symbol halted** | Orders into a halted/paused symbol | ITCH `H`/`h` state | — | Per-symbol | Nasdaq rules, LULD Plan | 0 (in record) |
| 6 | **Stale book** | Quoting on data you no longer have | Per-symbol last-update timestamp, feed gap flags | `stale_ns` threshold | Per-symbol | 15c3-5(c)(1)(ii) | 1 |
| 7 | **Sub-penny / tick validity** | Rule 612 violation, certain rejection | `price` | `tick_class[sym]` | Per-order | **SEC Rule 612** | 1 |
| 8 | **Price collar vs reference** | Fat-finger, runaway pricing | `price`, reference price | `collar_bps` or `collar_ticks` | Per-symbol | 15c3-5(c)(1)(ii) | 2 (mult + cmp) |
| 9 | **LULD band** | Order outside the price band | `price`, `luld_lo[sym]`, `luld_hi[sym]` | — | Per-symbol | **LULD Plan** | 1 |
| 10 | **SSR (Rule 201)** | Short sale at or below the NBB while SSR active | `side`, `price`, `ssr_active[sym]`, `nbb[sym]` | — | Per-symbol | **Reg SHO Rule 201** | 1 |
| 11 | **Short-sale permission** | Naked short / no locate | `side`(short), `shortable[sym]`, `locate_qty[sym]` | — | Per-symbol | **Reg SHO 203(b)** | 1 |
| 12 | **Long-sale backing** | Mismarked long sale | `side`(sell long), `long_avail[sym]` | — | Per-symbol | **Reg SHO 200(g)** | 1 |
| 13 | **Max order shares** | Fat-finger size | `qty` | `max_order_qty[sym]` | Per-order | 15c3-5(c)(1)(ii) | 1 |
| 14 | **Max order notional** | Fat-finger value | `qty × price` | `max_order_notional[sym]` | Per-order | 15c3-5(c)(1)(i) | 2 (DSP mult) |
| 15 | **Max position long** | Accumulating a position beyond mandate | `pos[sym]`, `qty` | `max_long_qty[sym]` | Per-symbol | 15c3-5(c)(1)(i) | 2 |
| 16 | **Max position short** | Same, other side | `pos[sym]`, `qty` | `max_short_qty[sym]` | Per-symbol | 15c3-5(c)(1)(i) | 2 |
| 17 | **Max gross notional (aggregate)** | Firm-level exposure | `gross_notional`, order notional | `max_gross_notional` | Account | 15c3-5(c)(1)(i) | 2 |
| 18 | **Max net notional (aggregate)** | Directional exposure | `net_notional` (signed) | `max_net_notional` | Account | 15c3-5(c)(1)(i) | 2 |
| 19 | **Max open orders per symbol** | Order-book pollution, uncontrolled exposure | `open_orders[sym]` | `max_open_sym[sym]` | Per-symbol | 15c3-5 | 1 |
| 20 | **Max open orders total** | Session/state explosion | `open_orders_total` | `max_open_total` | Account | 15c3-5 | 1 |
| 21 | **Max message rate (windowed)** | Runaway loop, port throttle breach | Windowed message counter | `max_msgs_per_window`, `window_ns` | Per-port + global | 15c3-5, venue port limits | 1 |
| 22 | **Duplicate order detection** | Repeated identical order (loop bug) | Hash of (sym, side, price, qty) + recent-window table | `dup_window_ns` | Per-symbol | **15c3-5(c)(1)(ii)** (explicit) | 2 |
| 23 | **Self-match prevention** | Wash trades / self-trades | Own resting orders at the contra price | SMP mode | Per-symbol | **FINRA Rule 5210** | 1–2 |
| 24 | **Restricted / hard-to-borrow list** | Trading a prohibited or unborrowable name | `restricted[sym]`, `htb[sym]` | — | Per-symbol | Firm policy, Reg SHO | 0 (in record) |
| 25 | **Credit / in-flight limit** | Exposure from unacked orders | `inflight_notional` | `max_inflight_notional` | Account | 15c3-5(c)(1)(i) | 2 |
| 26 | **ISO flag must be zero** | False ISO representation | `iso` bit | Build parameter (tied 0) | Per-order | **SEC Rule 611** | 0 (tie-off) |
| 27 | **Post-only forced** | Accidental taker fees / accidental aggression | `post_only` bit | `force_post_only[sym]` | Per-symbol | Economics + policy | 0 (OR-in) |
| 28 | **Taking permitted** | Aggression during bring-up | order marketability | `allow_taking[sym]` | Per-symbol | Policy | 1 |
| 29 | **Parameter validity / init** | Evaluating against an uninitialised record | `params_valid[sym]` | — | Per-symbol | Fail-closed | 0 (in record) |

**Total added latency target: ≤ 6 cycles (≈ 24 ns @ 250 MHz).** These are all
comparisons against pre-fetched registers; the expensive ones are the two DSP
multiplies (notional) and the duplicate-hash lookup, and both pipeline cleanly.

### Notes on the harder checks

**#7 Tick validity.** `tick_class[sym]` is a 2–3 bit field selecting {$0.0001,
$0.005, $0.01}. Do not implement modulo. With prices as ITCH-scaled integers
(4 implied decimals):

```
    tick_class = TICK_PENNY (100)      → valid ⇔ price[6:0] representable as ×100
    tick_class = TICK_HALF_PENNY (50)  → valid ⇔ price mod 50 == 0
    tick_class = TICK_SUBDOLLAR (1)    → always valid
```
Since 100 and 50 are compile-time constants, "divisible by 100" and "divisible by 50"
are each a small fixed comparator network on the low bits, generated per constant —
one LUT level each, selected by a mux. See
[06-regnms-and-compliance.md](06-regnms-and-compliance.md) §5.

**#10 SSR.** `price > nbb[sym]` — **strictly greater**, and against the *national*
best bid, conservatively sourced. If the NBB is stale or your feed set is incomplete,
`nbb_valid` is false and the check **rejects**. See
[06-regnms-and-compliance.md](06-regnms-and-compliance.md) §6, §8.

**#22 Duplicate detection.** A small direct-mapped table indexed by a CRC hash of
(symbol, side, price, qty), storing a timestamp. Match within `dup_window_ns` → reject.
False positives (hash collisions) cause a spurious reject, which is the *safe*
direction. This is one of the very few checks the SEC names explicitly in 15c3-5.

**#23 SMP.** Venue-side SMP (an OUCH field) is the primary mechanism. The fabric check
is a cheap secondary: if you have a resting order on the opposite side at a crossing
price, reject. It cannot be complete — it does not see other MPIDs' books — so it
supplements the venue's SMP, never replaces it.

**#25 In-flight.** Notional of orders sent but not yet acked. Without this, a burst
can exceed a notional limit before a single ack returns. Increment on send, decrement
on ack/reject/cancel-confirm. ⚠️ A leak here silently throttles you to zero; alarm on
`inflight` failing to drain to zero at end of day.

---

## 2. Fail-closed and reset state

```systemverilog
// Reset values. Every one of these is the SAFE value.
// The system comes up UNABLE TO TRADE and must be explicitly enabled.
localparam logic        RST_TRADING_ENABLED   = 1'b0;   // disabled
localparam logic        RST_KILL_LATCHED      = 1'b1;   // killed
localparam logic        RST_SYM_ENABLED       = 1'b0;   // no symbol enabled
localparam logic        RST_PARAMS_VALID      = 1'b0;   // record invalid
localparam logic [31:0] RST_MAX_ORDER_QTY     = 32'd0;  // zero size
localparam logic [63:0] RST_MAX_NOTIONAL      = 64'd0;  // zero notional
localparam logic        RST_ALLOW_TAKING      = 1'b0;   // passive only
localparam logic        RST_FORCE_POST_ONLY   = 1'b1;   // post-only forced
localparam logic        RST_SHORTABLE         = 1'b0;   // no shorting
```

> ⚠️ **A limit that resets to a large value is worse than no limit at all**, because
> it creates the appearance of a control. Every limit resets to **zero**, every enable
> resets to **disabled**, and the kill latch resets **set**. A freshly configured FPGA
> can do exactly nothing until a deliberate, authenticated sequence of writes enables
> it — and each of those writes is a logged event.

**Rules that follow from this:**

- A symbol whose parameter record has never been written has `params_valid = 0` and is
  untradeable. There is no default record.
- After any reconfiguration (partial or full), the design returns to the reset state.
  Re-enabling is a deliberate operational step, never automatic on link-up.
- Any check whose *inputs* are invalid (stale book, invalid NBB, unlocked clock,
  overflowed counter) rejects. "Input invalid" and "check failed" produce the same
  outcome and **different reject codes**.

---

## 3. Saturating arithmetic

Every position, notional, and exposure counter saturates. None wrap.

```systemverilog
// Signed saturating accumulate for a position counter.
function automatic logic signed [W-1:0]
    sat_add_s(input logic signed [W-1:0] a, input logic signed [W-1:0] b,
              output logic saturated);
    logic signed [W:0] s;
    begin
        s = W'(a) + W'(b);                      // one guard bit
        saturated = (s[W] != s[W-1]);           // signed overflow
        if (saturated) sat_add_s = s[W] ? {1'b1, {(W-1){1'b0}}}   // −max
                                        : {1'b0, {(W-1){1'b1}}};  // +max
        else           sat_add_s = s[W-1:0];
    end
endfunction
```

> ⚠️ **The catastrophe.** A 32-bit unsigned gross-notional counter holding
> $4,294,967,295-worth of exposure wraps to near zero on the next fill. The next
> `gross_notional + order_notional ≤ max_gross_notional` check **passes**. The limit
> has not been breached loudly — it has been *silently deleted*, and the system will
> keep trading through it at full speed. This is the single worst failure mode in the
> whole design, and it is caused by a width decision, not by a logic error.

Rules:

- **Size for the true worst case, then saturate anyway.** Notionals in scaled integer
  cents: `qty (32b) × price (32b, 4 implied decimals)` needs a **64-bit** product;
  aggregate notional gets **64 bits signed**, minimum.
- **Every saturation increments a counter and sets a sticky flag.** A single
  saturation event is a design error; it must be visible forever, not until the next
  poll.
- ⚠️ **Saturation of a risk counter is itself a kill trigger.** If a position counter
  saturates you no longer know your position, and continuing to trade is indefensible.
- Statistics counters (messages, drops, rejects) are 48 bits and effectively never
  wrap in a trading day.
- See [../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) §9.

---

## 4. Rejection counters and attribution

```systemverilog
// One counter per check, per... how much granularity?
logic [47:0] reject_cnt_global [N_CHECKS];   // always
logic [31:0] reject_cnt_symbol [N_SYM][N_CHECKS];  // expensive — see below
```

| Granularity | Cost | Verdict |
| --- | --- | --- |
| Global, per check | `N_CHECKS × 48b` ≈ trivial | **Mandatory** |
| Per symbol, per check | `N_SYM × N_CHECKS × 32b` — BRAM-hungry | Usually too expensive |
| **Per symbol, first-reject latch** | `N_SYM × ⌈log2(N_CHECKS)⌉ + valid` | **Do this.** Cheap, and answers "why did this symbol stop working?" |
| Last-N reject log (circular) | Small BRAM, full order record + reason | **Do this too.** Answers "what exactly was rejected?" |

Every rejected order also produces a **DMA'd reject record** to the host containing
the full order, the reason code, and a nanosecond timestamp. Rejections are:
- **Debugging** — the fastest way to find a broken strategy.
- **Compliance evidence** — proof the 15c3-5 controls operate.
- **Economics** — post-only slides and rate-limit rejects are measurable opportunity
  cost ([07-fees-rebates-and-economics.md](07-fees-rebates-and-economics.md) §9).

> ⚠️ **Alarm on rejection-rate anomalies, not just on rejections.** Zero rejections
> from a check is not reassuring — it usually means the check is unreachable. A sudden
> *change* in the mix (check #9 LULD suddenly firing on 40 symbols) is a market event
> or a parameter-load bug, and you want to know within seconds.

---

## 5. Kill switch specification

### Requirements

| Requirement | Specification |
| --- | --- |
| **Effect** | No new order, replace, or aggressive message leaves the design. Cancels and risk-reducing messages **may** be permitted (configurable, default: cancels allowed) |
| **Response time** | Bounded and documented: **≤ 8 core cycles (32 ns @ 250 MHz)** from trigger to the gate closing |
| **In-flight orders** | ⚠️ The kill must also **block orders already inside the pipeline** — anything between the strategy and the TX FIFO that has not yet been serialised must be squashed, not allowed to drain |
| **Latching** | Once triggered, it **latches**. Clearing requires an explicit, authenticated host write to a distinct clear register — never a timeout, never an auto-recover |
| **Independence** | Must not depend on host software being alive, on the strategy being sane, or on the PCIe link being up (for at least one trigger source) |
| **Observability** | A status register shows *which* source fired, with a nanosecond timestamp |

### Trigger sources

| Source | Mechanism | Latency to effect | Survives host death? |
| --- | --- | --- | --- |
| **Host register write** | Single write to the kill BAR register | ≤ PCIe write latency + 2 cycles | No |
| **Host watchdog timeout** | Host must write a heartbeat register every `T_hb`; fabric counts down and kills on expiry | ≤ 1 cycle after expiry | **Yes** — this is the point |
| **Message-rate breach** | Windowed counter exceeds `kill_msg_rate` | ≤ 2 cycles | Yes |
| **Position / notional limit breach** | Any aggregate limit exceeded *after* a fill (not just at order time) | ≤ 2 cycles | Yes |
| **Counter saturation** | Any risk counter saturates (§3) | ≤ 1 cycle | Yes |
| **External GPIO** | A physical input — a button, a relay from an external supervisor, or a signal from a second card | ≤ 2 cycles (+ debounce) | **Yes**, and survives PCIe death too |
| **Market-data link loss** | Any critical RX link down or PCS not locked | ≤ 2 cycles | Yes |
| **Order-entry link loss** | TCP session down / MAC link down | ≤ 2 cycles | Yes |
| **Clock unlock** | PTP/PPS loss of lock beyond holdover threshold | ≤ 2 cycles | Yes |
| **Bitstream/parameter integrity** | Parameter-region CRC mismatch on load | At load time | Yes |

> ⚠️ **The host watchdog is the most important trigger, and it is the one most often
> implemented wrong.** If the host process crashes, the FPGA has no idea — it happily
> keeps executing the last-loaded strategy against live market data, forever. A
> fabric-side countdown that the host must keep refreshing is the only thing standing
> between a segfault and an unsupervised algorithm. Default `T_hb` should be **tens of
> milliseconds**, not seconds.

> ⚠️ **The GPIO trigger is the one that works when everything else has failed** —
> including PCIe, including the host, including your ability to log in. In a sponsored
> arrangement it is also a clean answer to "can the broker-dealer stop you
> independently?" ([08-connectivity-and-colocation.md](08-connectivity-and-colocation.md) §6).

### Testing the kill switch

| Test | Method | Pass criterion |
| --- | --- | --- |
| Each trigger fires | Simulation: assert each source in isolation | Gate closes; correct source bit set |
| **Response time** | Simulation with an order mid-pipeline; count cycles trigger → last TX byte | ≤ documented bound, every time |
| **In-flight squash** | Inject N orders at every pipeline stage, then kill | **Zero** orders reach TX |
| Latch behaviour | Trigger, de-assert source | Stays killed |
| Clear path | Authenticated clear write | Trading resumes only after clear |
| Under load | Kill at full line rate with maximum message pressure | Bound still met |
| **On hardware** | Loopback with a hardware timestamper; measure trigger→silence | Matches simulation |
| **In the test environment** | Full stack against NTF, timed, with a human executing the runbook | Documented, rehearsed, repeatable |

> The kill switch is re-tested on **every** bitstream, in CI, as a gating test. It is
> the one test that may never be skipped for a build going anywhere near production.

---

## 6. The per-symbol risk parameter record

### Layout

A single BRAM/URAM-backed record fetched by symbol index in one cycle. Widths are a
starting point; size to your actual universe and adjust.

| Field | Bits | Type | Meaning |
| --- | --- | --- | --- |
| `params_valid` | 1 | flag | Record has been written by the risk owner |
| `sym_enabled` | 1 | flag | Trading permitted in this symbol |
| `allow_taking` | 1 | flag | May remove liquidity |
| `force_post_only` | 1 | flag | OR post-only into every order |
| `shortable` | 1 | flag | Short sales permitted |
| `restricted` | 1 | flag | Hard block (restricted list) |
| `htb` | 1 | flag | Hard-to-borrow |
| `tick_class` | 3 | enum | {$0.0001, $0.005, $0.01, reserved} |
| `max_order_qty` | 32 | uint | Shares |
| `max_order_notional` | 48 | uint | Scaled integer (4 implied decimals) |
| `max_long_qty` | 32 | int | Max long position, shares |
| `max_short_qty` | 32 | int | Max short position, shares (magnitude) |
| `max_open_sym` | 16 | uint | Max resting orders in this symbol |
| `collar_ticks` | 16 | uint | Price collar half-width, in ticks |
| `stale_ns` | 24 | uint | Book staleness threshold, ns |
| `locate_qty` | 32 | uint | Shares located for shorting (slow path) |
| `long_avail_qty` | 32 | int | Shares available to sell long (slow path) |
| — *live state, not parameters* — | | | |
| `pos_qty` | 40 | int | Current position, saturating |
| `open_orders` | 16 | uint | Resting order count |
| `luld_lo`, `luld_hi` | 32 + 32 | uint | LULD band, from the feed |
| `nbb`, `nbo` | 32 + 32 | uint | Conservative national best bid/offer |
| `nbb_valid` | 1 | flag | NBBO usable |
| `ssr_active` | 1 | flag | Rule 201 in force |
| `halted` | 1 | flag | From ITCH `H`/`h` |
| `last_update_ts` | 48 | uint | For staleness |

> ⚠️ **Keep parameters and live state in physically separate memories**, even though
> they are logically one record. Parameters are written by the host (rarely, atomically,
> under governance); live state is written by the fast path (constantly). Mixing them in
> one dual-port RAM creates a write-port conflict *and* makes the atomic-update scheme
> below impossible.

### Atomic double-buffered parameter update

The hazard: a host writes a multi-word parameter record while an order is being
evaluated. The order sees the new `max_order_qty` and the old `tick_class`. **A
half-written record is not a smaller limit — it is an undefined limit.**

```
                       ┌──────────────────────────────┐
    Host writes ──────▶│  Parameter bank  [ active^1 ]│  (shadow: safe to write)
                       ├──────────────────────────────┤
    Risk gate reads ◀──│  Parameter bank  [ active   ]│  (live: never written)
                       └──────────────────────────────┘
                                    ▲
                       one register: active_bank (flips atomically)
```

```systemverilog
// Two banks. The gate always reads `active_bank`; the host always writes `~active_bank`.
logic active_bank_q;

// Host protocol:
//   1. write full shadow record(s)          (any number of cycles, any order)
//   2. write shadow CRC
//   3. write COMMIT register
// Fabric on COMMIT:
//   4. verify shadow CRC; if bad -> reject commit, set error, DO NOT flip
//   5. flip active_bank_q on a single clock edge   <-- the atomic point
//   6. copy new active -> shadow so the next edit starts from current values

always_ff @(posedge clk) begin
    if (rst)                         active_bank_q <= 1'b0;
    else if (commit_pulse && crc_ok) active_bank_q <= ~active_bank_q;
end

// Read is always from the active bank, one cycle, no arbitration with the host.
assign params = param_ram[active_bank_q][sym_idx];
```

Properties this buys you:

| Property | How |
| --- | --- |
| **Atomicity** | The switch is one flip-flop toggling on one edge. There is no intermediate state |
| **No fast-path stall** | The host writes a bank nobody is reading. Zero contention |
| **Integrity** | CRC over the shadow bank; a corrupt or partial write cannot commit |
| **Rollback** | The previous bank is still intact — a "revert" is another flip |
| **Auditability** | The commit is a single, timestamped, loggable event |

> ⚠️ **A commit that fails CRC must not fall back to "keep trading with old
> parameters and log a warning" silently.** Old parameters are usually safe, but the
> *intent* of the operator was not achieved and they must know immediately. Fail the
> commit loudly, set a sticky error, and alarm.

---

## 7. Daily loss limits and position reconciliation

### Why the FPGA cannot compute P&L

| Reason | Detail |
| --- | --- |
| **Mark-to-market needs a mark** | Unrealised P&L requires a current fair price per symbol and a multiply-accumulate across the whole portfolio |
| **Fees are not per-share constants** | Tiered rebates, per-venue signs, Section 31, TAF — see [07-fees-rebates-and-economics.md](07-fees-rebates-and-economics.md) |
| **Corporate actions, allocations, borrow costs** | Not visible to fabric at all |
| **Busted trades** | A clearly-erroneous bust retroactively changes the fill set — [06-regnms-and-compliance.md](06-regnms-and-compliance.md) §10.4 |

So the division of labour is:

```
    FPGA owns:   position (shares), gross/net notional, in-flight exposure,
                 order counts, message rates.
                 → Fast, hard, unbypassable, but APPROXIMATE.

    Host owns:   true P&L, realised + unrealised, net of fees.
                 → Accurate, but LAGGED.

    Host enforces the daily loss limit by ASSERTING THE KILL SWITCH.
```

### The bounded-lag contract

The host-side loss limit is only as good as its lag. Make the lag an explicit,
monitored parameter:

| Quantity | Requirement |
| --- | --- |
| P&L recompute interval | Documented (e.g. every fill, or every `T_pnl` ms) |
| **Worst-case loss during the lag** | `max_position_notional × max_adverse_move_over_T_pnl` — compute it and check it is tolerable |
| Consequence | If the worst-case lag loss is too large, **tighten the FPGA position limit**, not the host interval. The hard control is the one in fabric |

> ⚠️ **Position drift.** The FPGA's position counter and the firm's true position
> *will* diverge: unacked orders, busted trades, out-of-band manual trades, fills on
> another system, corporate actions, and simple restart. Therefore:
>
> - The host **reconciles** FPGA position against the drop copy / clearing position on
>   a defined cadence, and at minimum at open and at close.
> - A divergence beyond `recon_tolerance` is a **kill trigger**, not a log line.
> - Reconciliation **overwrites** the FPGA position (via the atomic parameter path);
>   it never "adjusts" it incrementally.
> - ⚠️ **Never restart the FPGA with a zeroed position while a real position exists.**
>   A zeroed counter means the position limit permits a full new position on top of
>   the one you already have. Restart procedure: load the reconciled position *before*
>   clearing the kill latch. Make this ordering structural — the kill-clear register
>   write should be rejected if `position_loaded` is not set.

---

## 8. Testing the risk block

### The required matrix — every check proven to reject

> **A check that has never been observed to fire is a check you cannot trust.**
> There is no exception to this. Not "it's obviously correct". Not "it's one
> comparator". Not "we tested a similar one."

For **every** check in §1, the regression suite must contain, as a minimum:

| Case | Requirement |
| --- | --- |
| **Reject case** | An order that violates *only* this check, all others passing → rejected, with **this check's reject code**, and this check's counter incremented by exactly 1 |
| **Accept case** | The same order adjusted minimally to pass → accepted |
| **Boundary, reject side** | The exact worst passing-adjacent value → rejected (e.g. SSR `price == nbb`) |
| **Boundary, accept side** | The exact best value → accepted (e.g. `qty == max_order_qty`) |
| **Invalid-input case** | The check's inputs made stale/invalid → rejected, with the *input-invalid* reject code |
| **Counter attribution** | No other check's counter moved |

That is **six directed tests per check × 29 checks = 174 tests**, and they are cheap
to write and run. Automate the sweep: a table-driven cocotb test that iterates the
check list and generates all six cases from a per-check descriptor.

### Beyond directed tests

| Technique | What it finds |
| --- | --- |
| **Randomised order fuzzing** | Unexpected accept paths; the acceptance predicate should be independently re-derivable in the Python model |
| **Reference model cross-check** | A Python model of all 29 checks; every random order compared. Any disagreement is a bug in one of them |
| **Overflow / saturation injection** | Drive counters to their limits; prove saturation, the sticky flag, and the kill trigger |
| **Parameter-corruption injection** | Half-written banks, bad CRC, mid-flight commit under load → prove no order ever sees a torn record |
| **Fault injection: feed** | Sequence gaps, silence, out-of-order → staleness rejects fire |
| **Fault injection: session** | Link drop, TCP reset, ack storm → in-flight accounting drains correctly, no leak |
| **Fault injection: clock** | Loss of PPS lock → clock-unlock kill fires |
| **Soak** | Full-day pcap replay at line rate; **all counters must reconcile exactly** at the end |
| **Formal (where it fits)** | Prove the invariant "`tx_valid` implies `all_checks_passed_q`" holds unconditionally. This is a small, tractable formal property and it is the single most valuable one in the design |

See [../01-fpga-design/05-verification-and-simulation.md](../01-fpga-design/05-verification-and-simulation.md)
and [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md).

---

## 9. Operational governance of limits

Limits are not configuration. They are controls.

| Rule | Detail |
| --- | --- |
| **Ownership** | A named **risk owner** sets limits. Not the strategy developer, not the person on the desk. Under a sponsored arrangement this is the broker-dealer ([08-connectivity-and-colocation.md](08-connectivity-and-colocation.md) §6) |
| **Four-eyes approval** | Every limit change is proposed by one person and approved by a second, before it is applied. Enforced by the tool, not by habit |
| **Authenticated path** | Limit writes go through the risk control plane (separate BAR region, separate permissions), not through the strategy process |
| **Audit trail** | Every change logged: who, when, old value, new value, reason, approver, and the resulting parameter-bank CRC. Immutable, retained |
| **⚠️ Never bundled** | A limit change is **never** combined with a strategy change, a bitstream change, or any other work in the same deploy. One change, one deploy, one rollback story. (CLAUDE.md §6) |
| **Direction matters** | *Tightening* a limit is low-risk and may be expedited. *Loosening* always requires the full process. Encode the asymmetry in the tooling |
| **Emergency loosening** | If it must happen intra-day, it is an incident: recorded, time-boxed, reverted at the close, reviewed the next day |
| **Periodic review** | Limits are reviewed on a schedule against actual utilisation. A limit never approached in six months is probably too loose to be a control |
| **Reconciliation** | Limits in the FPGA are periodically read back and diffed against the risk system's record of what they should be. A mismatch is an incident |

> ⚠️ **The read-back diff is the control that catches everything else.** It catches a
> failed commit, an unlogged manual write, a bank-flip bug, and a corrupted record. Run
> it automatically, several times a day, and alarm on any difference.

---

## 10. Worked example: a conservative single-symbol canary

> **These are illustrative starting points to show the *shape* and *relative
> magnitude* of a conservative first deployment. They are not recommendations. Actual
> limits are set by the risk owner, for the specific strategy, symbol, capital base,
> and regulatory arrangement — see §9.**

Scenario: first production canary. One liquid, high-priced Nasdaq-listed name.
Passive-only. One strategy, one MPID, one symbol.

| Parameter | Illustrative value | Reasoning |
| --- | --- | --- |
| `sym_enabled` | 1, for exactly one symbol | Everything else `params_valid = 0` |
| `allow_taking` | **0** | Passive only. Removes an entire failure class |
| `force_post_only` | **1** | Cannot accidentally pay a taker fee or cross |
| `shortable` | **0** | No Reg SHO surface area on day one |
| `max_order_qty` | 100 shares | One round lot. Deliberately small |
| `max_order_notional` | ~$25k | Consistent with 100 shares of a high-priced name |
| `max_long_qty` | 300 shares | Three round lots |
| `max_short_qty` | 0 | Long-only canary |
| `max_open_sym` | 2 | One bid, one offer. Nothing else should exist |
| `max_open_total` | 2 | Same |
| `collar_ticks` | ~20 ticks from reference | Tight; a canary should never price far away |
| `stale_ns` | ~1 ms | Aggressive. Stop quoting the instant the book is doubtful |
| `max_msgs_per_window` | Well below the port throttle, e.g. a few hundred/sec | Canary should be quiet; a rate breach means a bug |
| `max_gross_notional` | ~$25k | Equal to one max position |
| `max_inflight_notional` | ~$25k | One order's worth |
| Host daily loss limit | A number the risk owner is entirely comfortable losing, in full, today | The canary's purpose is to find bugs, not P&L |
| Host watchdog `T_hb` | ~50 ms | Fast enough that a crash stops trading before it matters |
| Human supervision | **A named person watching, with the kill switch reachable** | Non-negotiable for a first production run |

**Scaling rules for what comes after:**

1. Change **one axis at a time**: symbols, *or* size, *or* strategy behaviour, *or*
   short enablement. Never two.
2. Run at least a full trading day at each step before the next.
3. Every step is a governed limit change under §9.
4. Any unexplained reject, any counter that does not reconcile, any saturation event
   → **stop and understand it before proceeding.** The canary exists precisely to
   surface these.

---

## Hardware implications

1. **The risk gate is a fixed-latency pipeline, not a state machine.** Every check
   evaluates in parallel on a pre-fetched parameter record; the results are reduced by
   an AND-tree. Target **≤ 6 cycles**, constant, every order, every time. Variable
   risk latency is a jitter source on the single most important path.
2. **`tx_valid` is driven only by the registered output of the AND-tree.** There is no
   other assignment to it anywhere in the design. Prove this formally (§8).
3. **Parameters and live state live in separate memories**, so the host never contends
   with the fast path and the double-buffer flip is possible.
4. **Double-buffered parameter banks with a CRC-gated single-flip commit.** No order
   ever sees a torn record.
5. **All position/notional arithmetic saturates**, sets a sticky flag, increments a
   counter, and **triggers the kill switch**.
6. **One 48-bit rejection counter per check**, plus a per-symbol first-reject latch and
   a circular log of the last N rejected orders with full detail.
7. **The kill switch squashes in-flight orders**, not just new ones — a `kill_q` signal
   distributed to every pipeline stage's valid bit, with a documented, tested,
   bounded response in cycles.
8. **At least one kill trigger is independent of PCIe and the host** (GPIO + fabric
   watchdog), because the failures that most need a kill switch are the ones that took
   the host with them.
9. **The risk control plane is a distinct BAR region** from the strategy control plane,
   with separate host-side write permissions — this is how "direct and exclusive
   control" under 15c3-5 becomes enforceable in software rather than in policy.
10. **Position load must precede kill-clear.** Make the ordering structural: reject the
    clear write unless `position_loaded` is set.
11. **Every reject and every accepted order is DMA'd to the host losslessly**, with a
    PTP-disciplined nanosecond timestamp. Count DMA drops; any nonzero value is an
    incident.
12. **The ISO bit is tied to zero by a synthesis parameter** that the production build
    script asserts and CI verifies.

### RTL sketch — the risk gate

```systemverilog
// -----------------------------------------------------------------------------
// risk_gate — the sole path from strategy to TX.
//   Latency  : RISK_STAGES cycles, FIXED (target 6 @ 250 MHz = 24 ns)
//   Resources: ~2 DSP (notional multiplies), 1 BRAM (params), 1 BRAM (dup table)
//   Invariant: o_valid |-> (all checks passed for the order in o_order)
// -----------------------------------------------------------------------------
module risk_gate #(
    parameter int N_CHECKS   = 29,
    parameter int RISK_STAGES = 6,
    parameter bit ENABLE_ISO = 1'b0        // MUST be 0 in production builds
) (
    input  logic        clk, rst,

    // From the strategy engine
    input  order_t      i_order,
    input  logic        i_valid,

    // Pre-fetched per-symbol record (parameters + live state), 1-cycle BRAM read
    input  sym_params_t i_params,          // from the ACTIVE bank
    input  sym_state_t  i_state,

    // Global controls
    input  logic        i_trading_enabled,
    input  logic        i_kill,            // latched kill, any source
    input  acct_state_t i_acct,            // aggregate notionals, open orders, in-flight

    // To the OUCH encoder / TX
    output order_t      o_order,
    output logic        o_valid,

    // Telemetry
    output logic [N_CHECKS-1:0] o_reject_vec,   // one-hot-ish: which checks failed
    output logic                o_reject_valid
);

    // ---- Stage 0: cheap flags and derived quantities -------------------------
    logic [N_CHECKS-1:0] chk;   // chk[i] == 1 means "check i PASSED"

    always_comb begin
        chk = '0;

        // Enables and state (all pre-fetched — 0 extra logic levels)
        chk[0]  = i_trading_enabled;
        chk[1]  = ~i_kill;
        chk[2]  = i_params.sym_enabled;
        chk[3]  = i_params.params_valid;
        chk[4]  = ~i_state.halted;
        chk[5]  = ~i_params.restricted;

        // Tick validity (Rule 612) — constant-divisor comparator, muxed by class
        chk[6]  = tick_valid(i_order.price, i_params.tick_class);

        // LULD band
        chk[7]  = (i_order.price >= i_state.luld_lo) &&
                  (i_order.price <= i_state.luld_hi);

        // SSR (Reg SHO 201): STRICTLY above the national best bid.
        //   Fails closed when the NBB is not usable.
        chk[8]  = !(i_order.side == SELL_SHORT && i_state.ssr_active)
                  || (i_state.nbb_valid && (i_order.price > i_state.nbb));

        // Short permission / long backing (Reg SHO 200(g), 203(b))
        chk[9]  = (i_order.side != SELL_SHORT)
                  || (i_params.shortable && (i_order.qty <= i_params.locate_qty));
        chk[10] = (i_order.side != SELL_LONG)
                  || (i_order.qty <= i_params.long_avail_qty);

        // Size
        chk[11] = (i_order.qty <= i_params.max_order_qty);

        // Staleness — fails closed
        chk[12] = (now_ns - i_state.last_update_ts) < i_params.stale_ns;

        // ISO must be zero unless a real sweep engine exists (Rule 611)
        chk[13] = ENABLE_ISO ? 1'b1 : ~i_order.iso;

        // ... checks 14..28: notional, position, open orders, rate, duplicate,
        //     SMP, in-flight, collar, session window, allow_taking.
        //     Each is a registered comparator against a pre-fetched value.
    end

    // ---- Stages 1..RISK_STAGES-1: pipeline + AND-reduce ---------------------
    // Registered at every stage; the order travels alongside in a matched delay
    // line so there is no possibility of the decision and the order desynchronising.
    logic [N_CHECKS-1:0] chk_q  [RISK_STAGES];
    order_t              ord_q  [RISK_STAGES];
    logic                vld_q  [RISK_STAGES];

    always_ff @(posedge clk) begin
        chk_q[0] <= chk;
        ord_q[0] <= apply_forced_flags(i_order, i_params);  // force post_only, clear iso
        vld_q[0] <= i_valid && !i_kill;                     // kill squashes at ENTRY...
        for (int s = 1; s < RISK_STAGES; s++) begin
            chk_q[s] <= chk_q[s-1];
            ord_q[s] <= ord_q[s-1];
            vld_q[s] <= vld_q[s-1] && !i_kill;              // ...AND at EVERY stage
        end
    end

    // ---- Output: the ONLY assignment to o_valid in the design ---------------
    localparam int L = RISK_STAGES-1;
    assign o_order       = ord_q[L];
    assign o_valid       = vld_q[L] &&  (&chk_q[L]);
    assign o_reject_valid = vld_q[L] && ~(&chk_q[L]);
    assign o_reject_vec   = ~chk_q[L];

    // Formal / simulation invariant — the single most valuable property here.
    `ifndef SYNTHESIS
    assert property (@(posedge clk) disable iff (rst)
        o_valid |-> (&chk_q[L]) && !i_kill
    ) else $fatal(1, "RISK GATE BREACH: order emitted without full check pass");
    `endif

endmodule
```

> ⚠️ Note the kill is ANDed into **every** pipeline stage's valid bit, not just the
> entry. That is what makes the in-flight squash requirement in §5 true rather than
> aspirational — and it is the line most likely to be "simplified" by someone
> optimising for Fmax. It is not optional.

---

## Further reading

- [02-sessions-auctions-and-halts.md](02-sessions-auctions-and-halts.md) — halts, LULD bands, session windows
- [03-order-types-and-routing.md](03-order-types-and-routing.md) — post-only, book-only, price sliding
- [05-ouch-5.0-order-entry.md](05-ouch-5.0-order-entry.md) — the fields these checks constrain
- [06-regnms-and-compliance.md](06-regnms-and-compliance.md) — the regulatory basis for every check
- [07-fees-rebates-and-economics.md](07-fees-rebates-and-economics.md) — why post-only and taking gates matter economically
- [08-connectivity-and-colocation.md](08-connectivity-and-colocation.md) — port throttles, link loss, sponsored-access control ownership
- [../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) — saturating arithmetic, delay lines
- [../01-fpga-design/05-verification-and-simulation.md](../01-fpga-design/05-verification-and-simulation.md) — the test infrastructure §8 assumes
- [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md) — the general risk framework
- [../04-system-architecture/05-order-gateway-and-pre-trade-risk.md](../04-system-architecture/05-order-gateway-and-pre-trade-risk.md) — where this block sits in the pipeline
- [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md) — canary deployment discipline
