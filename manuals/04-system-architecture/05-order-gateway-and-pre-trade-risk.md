# 04.05 — Order Gateway and Pre-Trade Risk

> **Why this matters here:** every other document in this tier is about being fast.
> This one is about being *unable to do the wrong thing*. It owns rows **T0–T6** —
> 7 cycles, 44.8 ns — and it contains the only logic in the system whose failure mode
> is measured in dollars per second rather than nanoseconds. Read
> [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md)
> alongside it; that document says what the regulator requires, this one says how the
> fabric enforces it.

---

## 1. Structural non-bypassability

The risk gate is not a function that the order path calls. It is a **wire the order
path is made of.**

```
   ┌──────────────┐                                          ┌──────────────┐
   │  strat_top   │──ord_req──┐                              │   host CPU   │
   └──────────────┘           │                              │ (manual/hedge│
                              │                              │  /cancel)    │
                              │                              └──────┬───────┘
                              │                                     │
                              │       ┌─────────────────────┐       │ host_ord_req
                              └──────▶│  fixed-prio arbiter │◀──────┘  (via DMA)
                                      │  prio0 = fast path  │
                                      └──────────┬──────────┘
                                                 │
                    ╔════════════════════════════▼════════════════════════════╗
                    ║                                                         ║
   kill_switch ────▶║                    r i s k _ g a t e                    ║
                    ║          T0: precomputed gates                          ║
                    ║          T1: arithmetic gates                           ║
                    ║                                                         ║
                    ╚════════════════════════════╤════════════════════════════╝
                                                 │ ord_ok  (the ONLY producer)
                                      ┌──────────▼──────────┐
                                      │    ouch_encode      │
                                      └──────────┬──────────┘
                                      ┌──────────▼──────────┐
                                      │  soupbin_tx / tcp   │
                                      └──────────┬──────────┘
                                      ┌──────────▼──────────┐
                                      │  tx_mux  →  MAC     │
                                      └─────────────────────┘
```

The enforcement is *structural*, at three levels:

1. **RTL:** `ouch_encode` has exactly **one** input port, `ord_ok`, and its only
   driver is `risk_gate`. There is no `bypass` parameter, no debug mux, no
   `ifdef`. The connection is made in `tt_top.sv` and it is a single wire.
2. **The host cannot bypass it either.** The CPU's own order path (manual hedges,
   mass cancel, end-of-day flattening) enters at the *same* arbiter and passes the
   *same* gate. There is no privileged path. ⚠️ A "the host is trusted" exemption is
   how a fat-finger becomes a regulatory incident.
3. **CI enforces it.** `scripts/check_riskpath.py` parses the elaborated netlist and
   fails the build if any net reaching `ouch_encode.ord_ok` originates anywhere other
   than `risk_gate`, or if `risk_gate` has any output enable that can be tied off.

```systemverilog
// tt_top.sv — this is the whole enforcement mechanism, and it is deliberately dumb.
risk_gate  u_risk  (.ord_req(arb_ord_req), .ord_ok(risk_ord_ok), ...);
ouch_encode u_enc  (.ord_ok  (risk_ord_ok), ...);       // ← no other driver exists
```

> **Verify:** SEC Rule 15c3-5 (the Market Access Rule) requires risk controls that
> are applied on an automated, pre-trade basis and that cannot be circumvented,
> including by the broker's own personnel. Confirm the exact obligations that apply
> to your entity and venue arrangement with compliance; the design above is
> engineering, not legal advice. See
> [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md)
> and [../08-nasdaq/](../08-nasdaq/).

---

## 2. The check list

All checks evaluate **in parallel**. The gate is not a sequence of tests; it is a
combinational evaluation of every condition followed by an AND-reduction. The
"ordering" below is the ordering of *reporting* (which reason is attributed when
several fail), not of evaluation.

### T0 — precomputed-bit gates (1 cycle)

Every one of these is a bit maintained off the fast path, so the whole stage is a
single AND of a ~16-bit vector. Logic depth: 3 levels.

| # | Check | Bit source | Fails when |
| ---: | --- | --- | --- |
| 1 | **Kill switch disarmed** | `kill_switch` (§5) | anything in §5 tripped |
| 2 | **Master trading enable** | BAR0 `CTRL.trade_en` | host has not armed, or reset |
| 3 | **Symbol enabled for trading** | `risk_limits[slot].enable` | slot not provisioned, or disabled by `ttd-risk` |
| 4 | **Session open** | `ttd-control` window + ITCH `S` | outside 09:30–16:00, or venue signalled close |
| 5 | **Not halted** | ITCH `H` / `h` | trading halt, LULD pause, operational halt |
| 6 | **Book not stale** | `book_stale[slot]` (04.03 §10) | gap, overflow, sub-penny, underflow |
| 7 | **Short-sale marking valid** | ITCH `Y` Reg SHO + `position` sign | a sell that would be short while SSR is active and the price is not permitted |
| 8 | **Symbol not risk-blocked** | `risk_blocked[slot]`, sticky | this symbol previously breached a limit |
| 9 | **Parameters fresh** | parameter watchdog (04.04 §7) | `ttd-params` stopped committing |
| 10 | **In-flight credit available** | `inflight_credit` (§9) | CPU has not accounted for enough prior orders |
| 11 | **TX ownership held by FPGA** | `tcp_tx_lite` ownership bit (§8) | CPU owns the stream, or the session is not established |

### T1 — arithmetic gates (1 cycle)

All comparators and one DSP multiply, in parallel. Logic depth: ~8 levels.

| # | Check | Computation | Fails when |
| ---: | --- | --- | --- |
| 12 | **Price collar (upper)** | `px <= collar_hi[slot]` | price above the band |
| 13 | **Price collar (lower)** | `px >= collar_lo[slot]` | price below the band |
| 14 | **Price sanity** | `px != 0 && px_is_tick_aligned` | zero or sub-penny price |
| 15 | **Max order size** | `qty <= max_qty[slot]` | oversized single order |
| 16 | **Min order size** | `qty != 0` | zero-quantity order |
| 17 | **Max order notional** | `qty * px <= max_notional[slot]` | one DSP multiply — see below |
| 18 | **Projected position limit** | `\|pos + open_buy + qty\| <= max_pos[slot]` (buy) | would breach net position |
| 19 | **Gross position limit** | `open_buy + open_sell + qty <= max_gross[slot]` | too much exposure regardless of direction |
| 20 | **Open order count** | `open_cnt[slot] < max_open[slot]` | too many resting orders |
| 21 | **Message rate (symbol)** | `bucket[slot] > 0` | per-symbol token bucket empty |
| 22 | **Message rate (global)** | `bucket_global > 0` | global token bucket empty |
| 23 | **Self-match / duplicate** | `!(is_buy && px >= my_ask_px)` and dual | would cross our own resting order |
| 24 | **Daily notional budget** | `notional_today + qty*px <= max_daily[slot]` | day's traded value cap |

**On check 17 — do the real multiply.** The tempting precompute is
`max_qty = max_notional / px`, computed by the CPU. It is *approximate* (which price?
the last one?), it is *stale*, and if the market has moved it is approximate in the
wrong direction. A 32×32 unsigned multiply is 4 DSP48E2 slices and closes in one
cycle at 156.25 MHz with room to spare.

> **Precompute is free everywhere else in this system. It is not free here.** A risk
> limit that is approximately enforced is not enforced. Spend the DSPs.

⚠️ Check 23 (self-match) as written catches the common case — crossing our own
resting order at the touch — using `my_orders` state we already have. It does **not**
substitute for the venue's own self-match prevention, which sees all of our accounts
and all of our sessions. Enable the venue's SMP as well and treat this check as
defence in depth. See [../08-nasdaq/](../08-nasdaq/) for Nasdaq's SMP semantics.

### The reduction

```systemverilog
// rtl/risk/risk_gate.sv — budget rows T0, T1. Two cycles, fixed, pass or fail.
logic [23:0] chk;        // one bit per check, 1 = PASS

// T0 registered into chk[10:0], T1 into chk[23:11], both in the same cycle domain.
wire pass = &chk;

// Reason attribution: lowest-numbered failing check, for the counter and the log.
wire [4:0] first_fail = prio_enc_lsb(~chk);

always_ff @(posedge clk) begin
    ord_ok.valid  <= ord_req_q.valid &  pass;
    reject_valid  <= ord_req_q.valid & ~pass;
    reject_reason <= first_fail;
end
```

**Both outcomes take exactly 2 cycles.** A reject is not faster than a pass and a
pass is not faster than a reject. ⚠️ If rejects were cheaper, the latency of your
order path would leak information about your risk state into your own timing
measurements — and, more practically, it would introduce data-dependent jitter into
the one path where you measure everything.

---

## 3. Fail-closed

**The principle:** every ambiguity resolves toward *not trading*. The system's
resting state is "disabled", and trading is a condition that must be actively and
repeatedly established.

### Reset state

```systemverilog
always_ff @(posedge clk) if (rst) begin
    kill_armed_q      <= 1'b1;      // ⚠️ ARMED on reset, not disarmed
    trade_en_q        <= 1'b0;
    for (int i = 0; i < N_SYMBOLS; i++) begin
        limits_q[i].enable       <= 1'b0;
        limits_q[i].max_qty      <= '0;     // ⚠️ ZERO, not all-ones
        limits_q[i].max_notional <= '0;
        limits_q[i].max_pos      <= '0;
        limits_q[i].collar_hi    <= '0;     // hi = 0 → every price fails check 12
        limits_q[i].collar_lo    <= '1;     // lo = max → every price fails check 13
        book_stale_q[i]          <= 1'b1;
        risk_blocked_q[i]        <= 1'b1;
    end
end
```

⚠️ **The single most dangerous line of code you can write in this system is
`max_qty <= '1;` in a reset block.** All-ones on a reset value is the correct
defensive default for a *mask*; it is the catastrophic inversion for a *limit*.
Reviewers should treat every `'1` in `risk_limits.sv` as a finding until proven
otherwise. Note the collars above are reset *inverted* (`hi=0`, `lo=max`) precisely
so that the "no valid price" state is unmistakable.

### The ambiguity rules

| Situation | Resolution |
| --- | --- |
| Unknown / unprovisioned symbol slot | reject |
| Any check's inputs are not yet valid | reject |
| Limit table entry has an ECC/parity error | reject **and** set `risk_blocked[slot]` permanently, alarm |
| A counter has saturated | reject (§4) |
| Book stale | reject |
| Session state unknown (no `S` message seen yet today) | reject |
| PCIe link down | reject (host cannot supervise) |
| Watchdog expired | reject **and** arm the kill switch |
| A check's result is `X` in simulation | assertion failure — this is a design bug, not a runtime case |

```systemverilog
`ifndef SYNTHESIS
assert property (@(posedge clk) disable iff (rst) ord_req.valid |-> !$isunknown(chk))
    else $fatal(1, "risk check evaluated to X — fail-closed cannot be verified");
`endif
```

### Every limit is verified by readback

The host writes limits, then **reads them back and compares**, before arming. A
posted PCIe write that silently did not land, applied to a limit register, produces
a system whose limits are whatever was there before. `ttd-control` refuses to arm
until readback matches byte for byte, and re-verifies every limit on a slow loop
(e.g. 1 Hz) for the whole session. A mismatch mid-session arms the kill switch.

---

## 4. Saturating arithmetic

Every accumulator that feeds a risk check saturates and counts:

```systemverilog
// rtl/common/sat_add.sv — used for position, notional, open counts, everything.
function automatic logic [W-1:0] sat_add_u(input logic [W-1:0] a, b, output logic sat);
    logic [W:0] s = a + b;
    sat = s[W];
    return s[W] ? '1 : s[W-1:0];
endfunction
```

⚠️ **Why wrapping is catastrophic and not merely wrong.** Consider a 32-bit unsigned
`notional_today` at 4,294,967,000 and an order adding 1,000:

- **Saturating:** value becomes 4,294,967,295, check 24 fails, order rejected,
  `sat_notional` counter increments, alarm fires. You stop trading with a known,
  bounded, *reported* problem.
- **Wrapping:** value becomes 704. Check 24 now passes for the next **four billion
  dollars** of notional. The risk system is not merely failing — it is actively
  reporting that everything is fine.

The same applies to `position` (a wrapped position flips sign, so a limit that blocks
further buying now blocks selling instead), to `open_order_cnt` (wraps to zero,
removing the open-order cap), and to the token buckets.

**Widths are chosen so saturation is unreachable in a trading day, *and* saturation
is still handled**, because "unreachable" is an assumption and the counter is the
thing that tells you the assumption was wrong:

| Accumulator | Width | Headroom | On saturation |
| --- | ---: | --- | --- |
| `position[slot]` | 32 signed | ±2.1 B shares | reject, block symbol, alarm |
| `notional_today[slot]` | 48 unsigned | $2.8 e10 at 4 dp | reject, block symbol, alarm |
| `open_order_cnt[slot]` | 8 | 255 | reject, alarm |
| `open_buy/open_sell[slot]` | 32 | | reject, alarm |
| Statistics counters | 48 | never wraps in a day | wrap allowed, host handles |
| Token buckets | 16 | bounded by design | clamp at bucket depth |

⚠️ Statistics counters may wrap; **risk accumulators may not.** They are different
kinds of number and they get different code. Do not share a counter module between
them.

---

## 5. The kill switch

### Trigger sources

| # | Source | Detection | Response |
| ---: | --- | --- | --- |
| 1 | Host register write `KILL.set` | BAR0 posted write | ≤ 3 cycles from the write landing |
| 2 | **Host watchdog timeout** | down-counter, reloaded by a host heartbeat write | at expiry, same cycle |
| 3 | Global message-rate breach | token bucket exhausted N times in a window | same cycle |
| 4 | Reject-rate breach | `reject_cnt` rate over threshold | same cycle |
| 5 | Position/notional saturation anywhere | `sat` flag from any `sat_add` | same cycle |
| 6 | External GPIO (physical switch / rack panel) | debounced input pin, 2-FF sync | +2 cycles (CDC) |
| 7 | PCIe link down | hard-IP link status | same cycle |
| 8 | Order-session link down or TCP reset | `tcp_rx_lite` | same cycle |
| 9 | ECC uncorrectable in a limit or parameter memory | memory ECC status | same cycle |
| 10 | Fabric invariant violated (`window_overrun`, `level_underflow` beyond threshold) | counter | same cycle |
| 11 | Venue-side event (OUCH reject storm, session logout) | `ouch_ack_decode` | same cycle |

⚠️ **Source 2's implementation matters.** The watchdog must be a **down-counter that
the host reloads**, not a flag the host sets:

```systemverilog
// rtl/host/watchdog.sv
always_ff @(posedge clk) begin
    if (rst)                    wdog_q <= '0;                  // expired → kill armed
    else if (wdog_kick)         wdog_q <= wdog_reload_q;       // host heartbeat write
    else if (wdog_q != 0)       wdog_q <= wdog_q - 1;
end
assign wdog_expired = (wdog_q == 0);
```

A "host alive" flag that the host sets to 1 never becomes 0 when the host dies —
which is precisely the failure it was supposed to detect. A stuck-at-1 signal must
not be interpretable as health. Reload value: 500 ms at a 100 ms host heartbeat, so
five missed heartbeats.

### The hardware path and its bound

```
   trigger (any of 11) ──▶ kill_armed_q (sticky set, 1 cycle)
                                │
                                ├──▶ T0 check #1        (blocks at the gate)
                                ├──▶ tx_mux enable      (blocks at the MAC handoff)
                                ├──▶ strategy gating    (blocks at S0)
                                └──▶ IRQ / status reg   (tells the host)
```

Three independent blocking points, because a single gate is a single point of
failure. All three are combinational AND terms on a registered `kill_armed_q`, so all
three cost **zero** latency in the normal case.

| Path | Bound |
| --- | ---: |
| Host `KILL.set` write lands → `kill_armed_q` set | ≤ 3 cycles (**19.2 ns**) incl. CDC from the PCIe domain |
| `kill_armed_q` set → no new `ord_ok` | **0 cycles** (same-cycle AND at T0) |
| `kill_armed_q` set → no new frame accepted by `tx_mux` | **0 cycles** |
| GPIO assert → `kill_armed_q` | ≤ 5 cycles (**32 ns**) incl. debounce + 2-FF sync |
| Total, host write to full stop | **≤ 3 cycles = 19.2 ns** |

⚠️ **Kill is sticky and clears only by an explicit, distinct register write** to
`KILL.clear`, which additionally requires `CTRL.trade_en` to be re-established. It is
deliberately not a toggle. Nothing in hardware ever decides that the situation has
improved.

### ⚠️ In-flight orders

**An order already handed to the MAC cannot be recalled.** There is no mechanism.
This is a physical fact and the design must state its consequences rather than
pretend otherwise.

| Where the order is when kill fires | Outcome |
| --- | --- |
| Not yet at T0 | blocked, never encoded |
| Between T0 and T6 (≤ 5 cycles in flight) | **squashed** — `tx_mux` refuses the frame, the encoder's output is dropped, the TCP sequence number is *not* advanced |
| First beat already accepted by the MAC | **it will be sent.** Worst case one frame, ~74 bytes, ~60 ns of serialization. |
| Already on the wire / at the venue | only a cancel can retract it — see below |

So the **hard bound on escape** is: at most **one** order frame, because the fast
path is single-issue and the risk gate stops the next one in the same cycle. That
number — one — is the design's guarantee, and it is only true because there is no
queue between the encoder and the MAC.

Backstops for what is already at the venue:

1. `ttd-risk` issues a **mass cancel** over the OUCH session (CPU path, still through
   the risk gate, which permits cancels while killed — see §8).
2. If the CPU is the problem, dropping the TCP session invokes the venue's
   **cancel-on-disconnect**. `kill_switch` can be configured to drop the session
   after a programmable delay (default: 250 ms, giving the mass cancel a chance
   first).

> **Verify:** Nasdaq's cancel-on-disconnect behaviour for OUCH/SoupBinTCP — whether
> it is automatic, per-port-configurable, and what its latency is — must be confirmed
> with the venue and tested in UAT. Do not rely on it without a written confirmation
> and an observed test. See [../08-nasdaq/](../08-nasdaq/).

---

## 6. The order encode fast path

### Pre-built templates

The outbound frame is almost entirely constant. Only a handful of bytes depend on the
decision:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Ethernet (14 B)  │ IPv4 (20 B) │ TCP (20 B) │ SoupBinTCP (3 B) │ OUCH Enter … │
├──────────────────┼─────────────┼────────────┼──────────────────┼──────────────┤
│ CONSTANT         │ const except│ seq/ack/   │ const (len,type) │ const except:│
│                  │ ID, cksum   │ cksum      │                  │ token, side, │
│                  │             │            │                  │ qty, price   │
└──────────────────────────────────────────────────────────────────────────────┘
   ▲                                                                     ▲
   └──────────── read from ouch_template_ram[slot] ──────────────────────┘
                 one BRAM read, issued speculatively at S0
```

`ouch_template_ram`: 128 symbols × 2 (buy/sell pre-built) × 1024 bits = 256 Kbit →
8 BRAM36. Each entry is the complete frame with the symbol, account, firm, TIF,
display, capacity, ISO eligibility and all other static OUCH fields already in place,
in wire byte order.

**On trigger, we overwrite ~13 bytes:**

| Field | Bytes | Source |
| --- | ---: | --- |
| OUCH order token / user reference | 4 | `token_gen` (§7) |
| Buy/sell indicator | 1 | already baked into the buy/sell template — 0 bytes spliced |
| Shares | 4 | `ord_ok.qty` |
| Price | 4 | `ord_ok.px` |
| TCP sequence + ack | 8 | `tcp_tx_lite` (T4) |
| IP identification | 2 | incrementing counter (T5) |
| TCP checksum | 2 | incremental (below) |
| IP header checksum | 2 | incremental (below) |

> **Verify:** the OUCH 5.0 `Enter Order` field set, ordering, widths, and the price
> scaling (4 implied decimals) must be taken from the Nasdaq OUCH 5.0 specification —
> including whether your configuration uses optional appendage (TLV) fields, which
> change the message length and therefore the TCP/IP length fields and the template
> size. Generate `ouch_template_ram` contents from the spec on the host, not by hand.
> Field reference: [../08-nasdaq/](../08-nasdaq/).

### The latency argument

| Approach | Cycles | ns |
| --- | ---: | ---: |
| Serialize the OUCH message field by field into a byte stream | 8–12 | 51–77 |
| Build the message in a register, then prepend headers | 4–6 | 26–38 |
| **Template read (speculative) + splice** | **2** | **12.8** |

The template read costs **0 budget rows** because it is issued at S0, speculatively,
on every strategy evaluation — including the ~99.9 % that will decide `NONE`. The
read has no side effect and the BRAM port is otherwise idle. By the time `ord_ok`
arrives at T2, the template is already in a register.

This is the highest-leverage precompute in the system, exactly as
[../01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) §4
predicts.

### Incremental checksums

Recomputing a TCP checksum over a ~60-byte payload is a 30-term adder tree. Instead,
store the template's checksum with the template and patch it, using RFC 1624
equation 3 (which avoids the `~0` / `-0` ambiguity that equation 2 has):

```systemverilog
// rtl/net/cksum_incr.sv  — 1 cycle, ~120 LUT
// HC' = ~(~HC + ~m + m')   for each 16-bit word that changed
function automatic logic [15:0] cksum_patch
    (input logic [15:0] hc, input logic [15:0] m_old, m_new);
    logic [16:0] s = {1'b0, ~hc} + {1'b0, ~m_old} + {1'b0, m_new};
    s = s[15:0] + s[16];                       // end-around carry
    return ~s[15:0];
endfunction
```

Seven changed 16-bit words (token ×2, qty ×2, price ×2, seq/ack handled by
`tcp_tx_lite`) is a 7-term carry-save adder tree — 3 logic levels, comfortably inside
one cycle.

⚠️ **The Ethernet FCS is computed by the MAC, not by us.** Do not compute it in
fabric and do not include it in the template; a stale FCS produces a frame the venue
silently drops and a counter you are not watching.

⚠️ If the OUCH message length can vary (optional appendages), the IP total length,
TCP payload length and SoupBin length all change and the checksum patch must include
them. Prefer a **fixed-length** OUCH configuration for the fast path; variable-length
orders go through the CPU path.

---

## 7. Order token generation

```
  token[31:0] = { epoch[7:0] , slot[10:0] , seq[12:0] }
                     │             │            │
                     │             │            └── per-symbol counter, wraps at 8192
                     │             └── which symbol (self-describing)
                     └── bumped by the host on every session establishment
```

Properties this buys:

| Property | Why it matters |
| --- | --- |
| **Self-describing** | An ack or fill can be attributed to a symbol with zero lookups — `slot` is decodable from the token in the T-path's return direction, at 0 cycles |
| **Unique within a session** | `epoch` changes on reconnect, so a late ack for a pre-reconnect order cannot alias onto a live order |
| **Monotonic per symbol** | out-of-order acks are detectable |
| **Generated in 0 cycles** | it is a concatenation of registers, spliced at T3 |

⚠️ **`seq` wrapping at 8192 is only safe because `open_order_cnt` is capped far
below that.** The invariant is: `max_open[slot] << 8192`, so a wrapped `seq` can
never collide with a still-live token. Assert it:

```systemverilog
assert property (@(posedge clk) open_order_cnt[slot] < (1 << 13) / 4)
    else $error("token seq wrap could alias a live order");
```

⚠️ Tokens must not repeat within a trading day even across a reconnect, because the
venue may reject a duplicate, or worse, accept it and you now have two orders you
think are one. `epoch` is 8 bits — 256 reconnects. `ttd-control` refuses to establish
a session on `epoch` wrap without a manual acknowledgement.

---

## 8. SoupBinTCP / TCP: the hybrid ownership model

TCP in fabric is expensive and mostly unnecessary. TCP in software is too slow for
the send. So the connection is **split by responsibility**, not by layer.

| Function | Owner | Why |
| --- | --- | --- |
| ARP, connect, 3-way handshake | **CPU** | happens once, latency irrelevant |
| SoupBinTCP login, session/sequence negotiation | **CPU** | once per session |
| Heartbeats (both directions) | **CPU** | 1 Hz |
| **Steady-state send of `Enter Order` / `Cancel`** | **FPGA** | this is the fast path |
| `snd_nxt` maintenance for FPGA-sent bytes | **FPGA** | must be exact and immediate |
| Receive path: ACK processing, window tracking | **FPGA** (parse) + **CPU** (policy) | window state gates the FPGA |
| Retransmission | **CPU** | rare, complex, latency-tolerant |
| Any out-of-nominal condition | **CPU** | FPGA hands over and stops |
| Teardown, logout | **CPU** | |

### The ownership bit

⚠️ **Two writers to one TCP stream is a data-corruption bug, not a race you can
tune.** If the CPU injects bytes at `snd_nxt` while the FPGA also does, the stream is
garbage, the venue sees a malformed SoupBin packet, and the session drops mid-day.

```systemverilog
// rtl/net/tcp/tcp_tx_lite.sv
// Exactly one writer at a time. Handover is explicit and requires quiescence.
typedef enum logic [1:0] {OWN_NONE, OWN_CPU, OWN_FPGA} own_e;
own_e own_q;

// FPGA→CPU handover only when nothing is in flight in the fabric pipeline.
wire may_handover = (inflight_frames_q == 0);

always_ff @(posedge clk) begin
    if (rst)                                   own_q <= OWN_NONE;
    else if (cpu_req_own  && may_handover)     own_q <= OWN_CPU;
    else if (cpu_grant_fpga && sess_ok)        own_q <= OWN_FPGA;
    else if (abnormal)                         own_q <= OWN_CPU;   // fail toward CPU
end

assign tx_permitted = (own_q == OWN_FPGA) && window_open && !kill_armed_q;
```

`tx_permitted` is T0 check #11. The FPGA cannot emit a byte without it.

### When the FPGA stops emitting (fail-closed, not fail-slow)

| Condition | FPGA action |
| --- | --- |
| TCP receive window closes | stop. Do not queue orders. |
| Duplicate ACKs / retransmit needed | stop, hand ownership to CPU |
| Out-of-order ACK | stop, hand to CPU, alarm |
| SoupBin sequence mismatch | stop, hand to CPU, **arm kill** |
| No ACK within `T_ack_max` | stop, arm kill |

⚠️ **"Stop" means the order is not sent, not that it is queued.** A queued order is a
stale order: by the time the window reopens, the market has moved and the price that
justified the order is gone. Sending it is worse than not sending it. Count
`tx_blocked` and let the strategy re-decide on the next book update — which will be
within microseconds anyway.

---

## 9. In-flight accounting and the credit mechanism

The FPGA updates `position` and `open_order_cnt` itself, from acks it decodes. But
the CPU is the system of record, and there is a window in which the FPGA has emitted
orders the CPU has not yet seen. That window must be **bounded**, because it is the
amount of risk the CPU cannot supervise.

```
   credit_q  initialised to K by the host at arm time
      │
      ├── ord_ok fires        →  credit_q--            (immediate, 0 cycles)
      ├── credit_q == 0       →  T0 check #10 fails    (no more orders)
      └── ttd-risk has read and accounted an order from the DMA audit ring
                              →  host writes CREDIT.return → credit_q++
```

| Parameter | Value | Meaning |
| --- | ---: | --- |
| `K` (credit depth) | 8 | max orders the FPGA can emit ahead of host accounting |
| Worst-case unsupervised exposure | `K × max_notional[slot]` | this is the number to put in front of risk management |
| Typical credit return latency | ~10–50 µs | DMA ring write + host poll |
| Credit exhaustion | counted (`credit_starved`) | sustained non-zero → the host is too slow, alarm |

⚠️ **Credit is not flow control, it is a risk bound.** Tuning `K` up to "improve
throughput" is trading supervised risk for order rate, and it must be a documented,
approved decision, not a performance tweak. At `K=8` and a $100k per-order notional
cap, the unsupervised window is $800k — state it that way in the risk documentation.

⚠️ **Credit leaks silently throttle to zero.** If a return is dropped, the FPGA
gradually stops trading and looks like a performance problem. `ttd-control` compares
`credit_q` against `K − (sent − accounted)` on its 1 Hz loop and re-synchronises,
alarming on any discrepancy.

---

## 10. The return path: acks, fills, and position

```
   MAC RX (order session) ─▶ tcp_rx_lite ─▶ soupbin_rx ─▶ ouch_ack_decode
                                                                 │
                        ┌────────────────────────────────────────┼─────────────┐
                        ▼                                        ▼             ▼
                   position_track                            my_orders    dma_log_ring
                   open_order_cnt                            (04.04 §8)   (audit, every
                   notional_today                                          message)
```

| OUCH inbound | Effect |
| --- | --- |
| `Accepted` | `pending` cleared, `open_order_cnt++`, token → resting order recorded |
| `Executed` | `position ±= exec_shares` (saturating), `notional_today += exec_shares × exec_px`, resting qty reduced; if zero, `open_order_cnt--` |
| `Canceled` | resting order removed, `open_order_cnt--` |
| `Rejected` | `pending` cleared, counter by reason, **`risk_blocked[slot]` if the reject is a risk/compliance reason** |
| `Replaced` | old token retired, new token recorded |
| `Broken Trade` / bust | ⚠️ position adjustment — see below |

**Latency requirement:** this path is *not* in `T2T`, but it must complete in **< 1
µs** end to end, because `position` and `open_order_cnt` gate the *next* order. A
slow return path means the risk gate makes decisions on stale state. Decode is
fixed-offset, same technique as ITCH (04.02 §6): ~4 cycles from MAC to state update.

### ⚠️ Position drift

Hardware position is a *replica*. It drifts if:

- an `Executed` message is missed (SoupBin gap, decode bug, a message type the
  decoder does not handle),
- a fill arrives on a channel the FPGA does not see (drop copy, a second session, a
  manual trade by a human, a bust/correction applied out of band),
- an order is cancelled by the venue (cancel-on-disconnect, self-match prevention,
  a risk action at the broker) without an ack we process,
- an assumption about OUCH semantics is wrong.

**Drift is silent, monotonic and unbounded.** A position that reads 0 when it is
actually −50,000 shares means the position limit is not enforcing anything.

**The mandatory reconciliation:**

| Layer | Mechanism | Period |
| --- | --- | --- |
| 1 | `ttd-risk` maintains an independent position from the **DMA audit ring** (which contains the raw ack bytes, not the FPGA's interpretation) | continuous |
| 2 | Hardware `position[slot]` snapshotted and compared against layer 1 | **1 s** |
| 3 | Both compared against the venue's **drop copy** / OUCH session replay | ~1 min |
| 4 | Both compared against the venue's end-of-day position file | daily |

**Any mismatch at layer 2 or 3 arms the kill switch immediately.** Not "logs a
warning". Not "retries". A position mismatch means one of the two systems has an
unknown bug, and neither can be trusted to size the next order.

⚠️ Layer 1 must derive position from the **raw bytes**, not from the FPGA's decoded
`ack_evt`. If it consumes the FPGA's interpretation, it will reproduce the FPGA's
decode bug exactly and reconcile perfectly against a wrong answer. Independence is
the entire value of the check.

---

## 11. Rejection counters and attribution

```
   reject_cnt[24]     one saturating 32-bit counter per check (§2)
   reject_first       {check_id, slot, px, qty, timestamp} — sticky, first only
   reject_ring[16]    circular, last 16 rejected orders in full, readable over BAR0
```

Per-check counters are not a nicety. "Orders rejected: 4,182" is unactionable.
"Check 18 (projected position) rejected 4,182 on slot 37" is a five-minute
investigation. Every rejected order also produces a DMA audit record with the full
`ord_req`, the 24-bit `chk` vector, and the timestamp — so the exact reason for every
non-trade is reconstructable after the fact.

| Alarm | Threshold |
| --- | --- |
| Any check with reject rate > 1 % of orders | investigate |
| Checks 14, 16 (price/qty sanity) non-zero | **page** — the strategy is emitting nonsense |
| Check 1 (kill) non-zero while nominally trading | **page** |
| Checks 21/22 (rate) non-zero | **page** — a runaway is being contained by the last line of defence |
| Check 23 (self-match) sustained | strategy logic error |

---

## 12. TX path latency budget (rows T0–T6)

| Row | Stage | Module | Cycles | ns | Cum. ns | Notes |
| --- | --- | --- | ---: | ---: | ---: | --- |
| — | *template read issued* | `ouch_template_ram` | *0* | *0* | — | speculative at S0 |
| T0 | Risk stage 1 — 11 precomputed-bit gates, AND-reduce | `risk_gate` | 1 | 6.4 | 6.4 | fixed, pass or fail |
| T1 | Risk stage 2 — 13 arithmetic gates incl. 1 DSP multiply | `risk_gate`, `risk_limits` | 1 | 6.4 | 12.8 | fixed, pass or fail |
| T2 | Template present in register; token generated | `ouch_encode`, `token_gen` | 1 | 6.4 | 19.2 | fixed |
| T3 | Splice price / qty / token; OUCH checksum patch | `ouch_encode`, `cksum_incr` | 1 | 6.4 | 25.6 | fixed |
| T4 | SoupBinTCP header + TCP header, seq/ack splice, TCP cksum patch | `soupbin_tx`, `tcp_tx_lite` | 1 | 6.4 | 32.0 | fixed while FPGA owns TX |
| T5 | IPv4 + Ethernet headers, IP ID, IP cksum patch | `eth_tx_build`, `ipv4_udp_tx_build` | 1 | 6.4 | 38.4 | fixed |
| T6 | `tx_mux` arbitration + first beat to MAC | `tx_mux` | 1 | 6.4 | 44.8 | +0–12 cyc if CPU holds the mux (J11) |
| | **TX path total** | | **7** | **44.8** | | |
| | *+ MAC/PCS/GT/optics TX (04.01 P4–P7)* | | | *104.2* | *149.0* | |

**Risk gate cost as a fraction: 2 of 20 fabric cycles = 12.8 ns = 3.2 % of the
400 ns budget.** That is what a complete, non-bypassable, 24-check pre-trade risk
system costs in hardware. There is no version of this design where removing risk
checks is a meaningful optimisation, and any proposal to do so should be answered
with this row.

**Resource estimate (unmeasured, pre-synthesis):**

| Module | LUT | FF | BRAM36 | DSP48 |
| --- | ---: | ---: | ---: | ---: |
| `risk_gate` + `risk_limits` | ~2,800 | ~1,900 | 4 | 8 |
| `risk_counters` | ~900 | ~1,600 | 1 | 0 |
| `kill_switch` + `watchdog` | ~250 | ~200 | 0 | 0 |
| `rate_limiter` (per-symbol + global buckets) | ~700 | ~900 | 1 | 0 |
| `position_track` | ~600 | ~500 | 2 | 2 |
| `ouch_encode` + `ouch_template_ram` + `token_gen` | ~1,400 | ~1,300 | 8 | 0 |
| `soupbin_tx` + `tcp_tx_lite` + `cksum_incr` | ~1,800 | ~1,500 | 2 | 0 |
| `ouch_ack_decode` | ~900 | ~600 | 0 | 0 |

---

## 13. What must be proven before this block goes near a venue

| Test | Asserts |
| --- | --- |
| **Every check, individually** | for each of the 24 checks: construct an order that fails only that check; assert rejected, correct `reject_reason`, correct counter incremented, `ord_ok.valid == 0` |
| **Every check, at the boundary** | limit−1 passes, limit passes, limit+1 rejects (or the reverse, per the check's definition) — off-by-one in a risk limit is the defining bug of this block |
| **Fail-closed on reset** | assert from cycle 0 after reset: no input sequence whatsoever produces `ord_ok` until limits are loaded, verified, and `trade_en` is set |
| **Bypass impossibility** | formal or netlist check: no path to `ouch_encode` except through `risk_gate` |
| **Kill switch bound** | assert `KILL.set` → `ord_ok` never asserts again, within ≤ 3 cycles, from every pipeline state (drive kill on every cycle offset relative to an in-flight order) |
| **Kill squash** | an order in flight at T2..T5 when kill fires produces no frame at the MAC **and** does not advance `snd_nxt` |
| **Saturation** | drive each accumulator to its max; assert saturation, rejection, alarm — and assert it never wraps |
| **Rate limiter** | sustained trigger storm; assert the emitted order rate is bounded by the bucket, exactly |
| **Token uniqueness** | 10⁷ orders across reconnects; assert no token repeats |
| **Checksum correctness** | every spliced frame's TCP and IP checksums recomputed from scratch in the testbench and compared |
| **Ownership** | CPU and FPGA both attempt to send; assert `snd_nxt` is never advanced by two writers, and no interleaved bytes ever reach the MAC |
| **Position reconciliation** | inject a missing `Executed`; assert layer-2 reconciliation detects it within 1 s and arms the kill switch |
| **Conformance** | full venue conformance suite against UAT, with the risk gate live and limits set to production values |

⚠️ **The kill-switch test must be run from every pipeline state, not from idle.**
"Kill works when nothing is happening" is not the property you need.

---

## Further reading

- [01-tick-to-trade-pipeline.md](01-tick-to-trade-pipeline.md) — rows T0–T6 in the master budget
- [04-strategy-engine-on-fpga.md](04-strategy-engine-on-fpga.md) — the producer of `ord_req`, `pending`, `cooldown`
- [03-order-book-in-hardware.md](03-order-book-in-hardware.md) — `book_stale`, the first of two gates
- [06-cpu-fpga-partitioning.md](06-cpu-fpga-partitioning.md) — `ttd-risk`, the audit ring, arming sequence, watchdog
- [../01-fpga-design/01-rtl-design-patterns.md](../01-fpga-design/01-rtl-design-patterns.md) — saturating arithmetic, credit flow control, fixed-priority arbitration
- [../01-fpga-design/02-pipelining-and-parallelism.md](../01-fpga-design/02-pipelining-and-parallelism.md) — pre-built templates as the highest-leverage precompute
- [../02-networking/02-ip-udp-tcp-in-hardware.md](../02-networking/02-ip-udp-tcp-in-hardware.md) — why TCP in fabric is hard, incremental checksums
- [../03-algotrading/06-risk-and-compliance.md](../03-algotrading/06-risk-and-compliance.md) — the regulatory requirements this implements
- [../03-algotrading/04-order-entry-protocols.md](../03-algotrading/04-order-entry-protocols.md) — OUCH, SoupBinTCP, session semantics
- [../08-nasdaq/](../08-nasdaq/) — OUCH 5.0 message reference, cancel-on-disconnect, SMP, risk limit specifics
