# 06.04 — Testing Strategy

> **Why this matters here:** the cost of a bug in this system is not a crash, it is
> a trade. There is no user to notice something looks wrong and no retry — a
> misparsed price becomes an order at that price, at line rate, until someone stops
> it. Testing is the only mechanism that stands between a subtle RTL error and real
> money, and the single highest-value test in this project is **pcap replay against
> a golden software model**.

---

## 1. The test pyramid

| Level | What it tests | Tooling | When it runs | Gate |
| --- | --- | --- | --- | --- |
| **0. Lint** | Inferred latches, width mismatches, unused/undriven signals, blocking-assignment misuse | Verilator `-Wall`, `--lint-only` | Every push | **Merge blocker** |
| **1. Unit** | One RTL module against its contract | cocotb + Verilator | Every push | **Merge blocker** |
| **2. Protocol conformance** | Decoder/encoder against the venue spec, field by field | cocotb, spec-derived vectors | Every push | **Merge blocker** |
| **3. Property / randomized** | Edge cases nobody enumerated | cocotb + Hypothesis, constrained-random generators | Every PR | Merge blocker |
| **4. Integration** | Feed in → book out; book → strategy → order out | cocotb, full-path testbench | Every PR | Merge blocker |
| **5. pcap replay regression** | Whole datapath vs. golden model on real market data | cocotb + pcap corpus | Every PR (short set), nightly (full corpus) | **Merge blocker (short set)** |
| **6. Latency regression** | Cycle-exact stage and end-to-end latency | cocotb assertions | Every PR | **Merge blocker** |
| **7. Fault injection** | Behaviour under corruption, gaps, flaps, host death | cocotb + directed fault harness | Nightly | Nightly blocker |
| **8. Post-route timing/QoR** | The design actually closes | Vivado, seed sweep | Nightly | Release blocker |
| **9. Gate-level sim** | Post-synthesis/post-route netlist matches RTL behaviour | Vendor simulator | Release candidate | Release blocker |
| **10. Hardware-in-the-loop** | Real silicon, real optics, real PCIe | Lab card + market simulator | Release candidate | Release blocker |
| **11. Soak** | Long-run stability | HIL, hours to days | Weekly + release candidate | Release blocker |
| **12. Venue conformance** | Exchange certification | Exchange test facility | On protocol change | **Production blocker** |
| **13. Production canary** | Reality | Live, 1 symbol, min size | Every release | Rollout gate |

⚠️ Levels are not substitutes for one another. Passing level 5 tells you nothing
about level 8. A team that has great simulation and no HIL will ship a design that
works everywhere except on the card.

---

## 2. Unit tests (cocotb)

**Every RTL module gets a testbench. No exceptions on the fast path** (`CLAUDE.md` §4).

```
tb/
├── common/            reusable drivers, monitors, scoreboards
│   ├── axis_driver.py     valid/ready stream driver with backpressure control
│   ├── axis_monitor.py
│   ├── pcap_source.py     pcap → MoldUDP64 → AXI-Stream
│   └── scoreboard.py
├── unit/
│   ├── test_itch_decode.py
│   ├── test_symbol_lut.py
│   ├── test_book.py
│   ├── test_risk_gate.py
│   └── ...
├── integration/
│   └── test_tick_to_trade.py
├── models/            the golden software models (§4)
└── corpus/            pcap fixtures (§10)
```

Every unit testbench must cover, at minimum:

| Category | Specific cases |
| --- | --- |
| Reset | Behaviour during reset, on the release edge, and mid-transaction reset |
| Handshake | Backpressure on every output; a stalled downstream must never corrupt state |
| Boundary | Zero-length, minimum-length, maximum-length inputs |
| Arithmetic | Value 0, 1, max, max−1, overflow point for every counter and accumulator |
| Latency | Cycle-exact assertion: input at cycle N produces output at cycle N+K, always |
| Counters | Every counter the module exposes is driven to increment at least once |
| Illegal input | Malformed input does not hang the module or corrupt neighbours |
| Determinism | Same input sequence → identical output and identical timing, across runs |

```python
# tb/unit/test_risk_gate.py (shape)
@cocotb.test()
async def test_max_order_qty_reject(dut):
    tb = RiskGateTB(dut)
    await tb.reset()
    await tb.load_limits(max_order_qty=100, max_notional=1_000_000)
    await tb.arm()

    resp = await tb.submit_order(symbol=1, side=BUY, qty=101, price=1234500)
    assert resp.rejected
    assert resp.reason == RejectReason.MAX_ORDER_QTY
    assert await tb.read_counter("risk_rejects_max_order_qty") == 1
    assert await tb.read_counter("orders_emitted") == 0
```

**Rule: a risk-gate test asserts on the reason code and the counter, not just on
"rejected".** A gate that rejects everything for the wrong reason passes a lazy test.

---

## 3. Protocol conformance tests

Driven **from the spec**, not from the implementation.

| Target | Test content |
| --- | --- |
| **ITCH 5.0 decoder** | One vector per message type, at correct length, with every field at min/max/typical. Messages split across every possible frame-boundary offset. Multiple messages per MoldUDP64 packet. A message spanning two packets. Unknown message type. Declared length ≠ actual length. Trailing bytes. |
| **MoldUDP64 / SoupBinTCP framing** | Sequence continuity, gap, duplicate, out-of-order, heartbeat, end-of-session. |
| **OUCH 5.0 encoder** | Byte-exact comparison against reference encodings for every outbound message type. Field padding, ASCII space-fill vs null-fill, big-endian integer placement, token/client-order-ID format. |

```python
# Golden-vector style: bytes come from the spec, not from our encoder.
GOLDEN = [
    # (description, decoded_fields, expected_bytes_hex)
    ("enter order, buy 100 @ 123.45", dict(side='B', qty=100, price=1234500), "4f..."),
]
```

> **Verify:** every golden vector's byte layout must be traceable to a numbered
> section of the **Nasdaq TotalView-ITCH 5.0** or **OUCH 5.0** specification. Put
> the section reference in a comment next to each vector. When the venue publishes
> a spec revision, the vectors are the first thing that gets re-checked.

⚠️ The single most dangerous decoder bug class is **field offset off by one** on a
rarely-used message type. It will decode 99.9 % of the feed correctly and produce a
catastrophically wrong price on the 0.1 %. Enumerate *every* message type, including
the ones you think you will never see.

---

## 4. pcap replay regression — the most valuable test in the project

Record real market data. Replay it into the design. Compare the resulting book,
message-by-message, against a golden software model built independently from the
same spec.

```
corpus/*.pcap ──► pcap_source ──► [ RTL under test ] ──► book state / order intents
                       │                                          │
                       └─────► golden Python/C++ model ──► book state / order intents
                                                                  │
                                                          bit-exact comparison
```

**Required corpus** — each entry is a full capture of a *specific market condition*:

| Corpus entry | Why it is in the corpus |
| --- | --- |
| `normal_day` | The baseline. Full session, ordinary volumes. |
| `open` | 09:30 ET opening cross and the burst that follows. Highest message rate of most days. |
| `close` | 16:00 ET closing cross, imbalance (NOII) messages, large volume. |
| `halt_resume` | A symbol halted and resumed: trading-action messages, the quoting period, the re-open auction. |
| `volatile_day` | A high-volume, wide-spread session. Stresses FIFO depths and book depth. |
| `seq_gap` | A capture containing a genuine sequence gap and its recovery. If you cannot find one, synthesize it by deleting packets — and keep both. |
| `luld_band` | Limit Up-Limit Down band updates and a symbol hitting a band. |
| `ipo_or_new_symbol` | Stock Directory messages, IPO quoting period, a symbol appearing mid-session. |
| `crossed_locked` | Periods where the book is legitimately crossed or locked. |
| `microburst` | The highest packets-per-microsecond window you can find. Stresses backpressure and drop behaviour. |

**Pass criteria — all must hold:**

1. Fabric book state == golden model book state after **every** message, for every
   symbol in the filter set.
2. Zero unknown message types, zero length mismatches.
3. Order intents produced by the fabric strategy == intents produced by the golden
   strategy model, in the same order, at the same triggering message.
4. Counter totals reconcile: `msgs_decoded` sums to the corpus message count;
   `symbol_filter_hit + symbol_filter_miss == total messages`.
5. No FIFO overflow, no drops (or drops exactly where the design documents them).
6. Latency histogram within the declared budget for every sample.

> **Verify:** the golden model must be written from the **spec**, ideally by a
> different person than the RTL author, and must not share parsing code with the
> RTL testbench helpers. A golden model that inherits the RTL's misunderstanding
> tests nothing.

⚠️ **Do not commit multi-gigabyte pcaps to git.** See §10.

---

## 5. Property-based and randomized testing

Directed tests find the bugs you thought of. Randomized tests find the others.

| Technique | Applied to | Property asserted |
| --- | --- | --- |
| Random message-stream generation | ITCH decoder | Never hangs; every well-formed message decodes; every malformed one is counted, not silently accepted |
| Random split points | Framing | Decoding is invariant to how messages are split across packets/beats |
| Random backpressure | Every AXI-Stream interface | Output byte sequence is identical regardless of downstream stall pattern |
| Constrained-random order books | Book | Bid < ask except during documented crossed states; sum of level quantities equals tracked total; delete/execute never underflows |
| Random risk parameters + random orders | Risk gate | **No order is ever emitted that violates any active limit** — the core safety property |
| Random reset injection | All modules | Post-reset state is the declared initial state, always |

```python
@given(messages=st.lists(itch_message(), min_size=1, max_size=5000),
       split_at=st.lists(st.integers(min_value=1, max_value=1500)))
@settings(max_examples=500)
def test_decode_invariant_to_framing(messages, split_at):
    """Decoded output must not depend on how the byte stream was packetized."""
```

**The one property that is never allowed to fail:** for all inputs, for all
parameter values, for all timing, the risk gate emits no order violating an active
limit. If this property fails once in a million randomized runs, it is a P1.

---

## 6. Full-path simulation with a simulated venue

The integration testbench closes the loop:

```
pcap ──► MoldUDP64 gen ──► [ MAC ─ decode ─ book ─ strategy ─ risk ─ OUCH ─ MAC ] ──► venue model
                                                        ▲                                   │
                                                        └────── acks / fills / rejects ◄────┘
```

The **simulated venue** must model, at minimum:

| Behaviour | Why |
| --- | --- |
| SoupBinTCP login/logout/heartbeat/sequencing | Session logic is where hardware TCP gets subtle |
| Ack with realistic, *variable* delay | Your order-state machine must not assume constant RTT |
| Partial fills, multiple fills per order | Position accounting |
| Rejects with each documented reason code | You must handle every one |
| Cancel/replace race: fill arriving after your cancel | The classic order-state bug |
| Out-of-order and duplicate responses | Session resilience |
| Mid-session disconnect and reconnect with replay | Recovery path |

⚠️ A venue model that always acks in a fixed number of cycles will hide your
timing-dependent order-state bugs completely. Randomize the response delay across
the plausible range and run the corpus repeatedly.

---

## 7. Hardware-in-the-loop (HIL)

Simulation cannot test the transceiver, the optic, the PCIe link, the die
temperature, or the real clock. HIL can.

**Lab topology:**

```
[ DUT card ] ──optic── [ market simulator ] ──► replays corpus pcaps at line rate
      │                  (second FPGA card, or a hardware traffic generator)
      │                          │
      └──optic──► [ venue simulator ] ── acks/fills, also timestamping arrivals
      │
      └──PCIe──► [ host: control process + collector ]
```

| Option for the market simulator | Pros | Cons |
| --- | --- | --- |
| **Second FPGA card** running a pcap replayer | Exact inter-packet timing, line rate, cheap once built, can inject faults precisely | You must build and verify it — and it needs its own tests |
| Commercial traffic generator | Precise, supported, good reporting | Expensive; may not replay pcap with original microsecond timing |
| Software replay (tcpreplay from a kernel-bypass NIC) | Cheapest to start | ⚠️ Cannot reproduce microburst timing accurately; fine for functional tests, useless for burst-stress or latency measurement |

**What HIL must establish before any release:**

1. Measured (not simulated) wire-to-wire latency distribution, with N stated, using
   external timestamping or a loopback methodology — see
   [../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md).
2. Line-rate sustained with zero unexpected drops.
3. Microburst survival: the worst burst in the corpus, replayed at original timing.
4. Every counter observed to increment when its condition is forced.
5. Kill-switch latency measured, matching the documented cycle bound.
6. Risk limits enforced on real hardware, one deliberate violation per limit.
7. Build-ID readback verified through the real PCIe path.

---

## 8. Soak testing

Run the full HIL setup for hours to days. Soak catches what short tests
structurally cannot:

| Bug class | How soak exposes it |
| --- | --- |
| **CDC bugs** | Metastability-induced failures are probabilistic. A 1-in-10^9 event needs 10^9 opportunities. |
| **Counter wrap** | A 32-bit counter at high rate wraps in minutes-to-hours; the host's delta arithmetic gets tested for real |
| **FIFO high-water creep** | Slow leak in a credit or occupancy scheme only shows after millions of transactions |
| **Host-side memory/FD leaks** | Collector or control process growing over a session |
| **Thermal drift** | Die temperature rises for the first 30–60 minutes; timing-marginal paths fail *later*, not at start |
| **Timestamp counter rollover** | A 48-bit cycle counter rolls over eventually; latency computation must handle it |
| **Session-layer state rot** | Sequence numbers, heartbeat drift, reconnect counters |
| **Rare message types** | A message type that appears twice a day only appears in a long run |

**Soak pass criteria:** zero unexplained counter movements, zero sticky error bits
set, latency distribution stable from hour 1 to hour N (compare the histograms
directly), host RSS flat, die temp stable.

---

## 9. Exchange conformance and the production canary

### Conformance

Covered operationally in [02-deployment-and-colocation.md](02-deployment-and-colocation.md) §7.
The testing-side obligation: **build a conformance rehearsal harness** that runs
the venue's published test script against your design in the lab *before* you book
time on the exchange test facility. Failing certification because of something you
could have caught locally is expensive in calendar time.

### Production canary

The last test, and the only one on real money.

| Dimension | Canary setting |
| --- | --- |
| Symbols | Exactly 1, liquid, well-understood, not the one your strategy loves most |
| Size | Minimum tradeable |
| Risk limits | Tightest values the system supports |
| Duration | ≥ 1 full session, ideally including an open and a close |
| Supervision | A named human watching the dashboard live |
| Blast radius | A pre-agreed maximum loss, written down before starting |

**Graduation criteria — all must hold for the full session:**

1. Every order emitted reconciles exactly with drop copy and with clearing.
2. Zero venue rejects with an unexpected reason code.
3. Zero risk rejects that the strategy did not intend.
4. Fabric position == host position == drop-copy position, at every reconciliation
   point and at EOD.
5. Measured wire-to-wire latency distribution matches the HIL distribution.
6. Zero sticky error bits set.
7. Fabric book matched the independent software book for the canary symbol all
   session.

⚠️ **One unexplained event resets the canary.** Not "we think it was probably the
network". Explained, or restart.

---

## 10. Latency regression as a first-class test

Latency is a *correctness* property in this project, and it is tested like one.

| Test | Mechanism | Failure |
| --- | --- | --- |
| Per-stage cycle count | cocotb assertion: `assert stage_latency == EXPECTED_CYCLES` for every stage, every run | Any change fails the build |
| End-to-end simulated | Full-path testbench measures ingress-to-egress cycles over the corpus | p50 or max moves at all |
| Determinism | Same input replayed twice must produce **identical** cycle counts | Any variation is a bug, not noise |
| Post-route Fmax | Nightly seed sweep | WNS regression |
| Measured HIL | Release candidate | Distribution shift vs. previous release |

The CI report for every PR includes a latency diff table. **A PR that changes
latency without saying so in its description is rejected on sight**, even if the
change is an improvement — because it means the author didn't know.

---

## 11. Fault injection

For each fault, the required behaviour is specified *before* the test is written.

| Injected fault | Required behaviour |
| --- | --- |
| Frame with bad CRC | Dropped at MAC, `rx_crc_err` increments, no downstream state change, no drop of the *next* good frame |
| Truncated / oversized frame | Counted, discarded, decoder resynchronizes on the next packet |
| ITCH message with a bad length field | `msg_len_mismatch` increments, sticky bit set, decoder resynchronizes at the next MoldUDP64 packet boundary — **never** silently reinterprets the remaining bytes |
| Unknown ITCH message type | Counted, skipped using the length field, sticky set, alert raised |
| Sequence gap on A only | B covers it seamlessly; `arb_wins[B]` climbs; no book impact; gap counted |
| Sequence gap on both | `seq_gap_unrecovered` set; book marked stale; **strategy stops firing for affected symbols**; alert |
| Duplicate packets | Deduplicated by sequence; no double-apply to the book |
| Out-of-order packets | Handled or explicitly counted and dropped; documented either way |
| Link flap on a feed port | Counted; recovery without a reset of the whole design; book re-synced via snapshot |
| Venue session drop mid-order | Order state machine resolves; on reconnect, resting order state is explicitly re-verified, never assumed |
| Venue sends a reject we don't recognize | Counted, order marked terminal-unknown, alert — **never** treated as an ack |
| Fill arriving after our cancel | Position accounting correct; no double-count |
| Host process killed (SIGKILL) | Watchdog blocks new orders within the documented threshold; existing orders handled per policy |
| PCIe link error / surprise removal | Fabric fails safe: no orders emitted; sticky error set |
| Over-temperature | Warn threshold alerts; critical threshold triggers kill switch |
| Kill switch during in-flight order | Documented, bounded: orders already past the gate may complete; nothing new passes. The bound is measured and asserted. |
| Parameter table corrupted mid-write | CRC mismatch detected; old parameters retained; strategy does **not** run on a half-written table |

⚠️ The last one is a real and easy mistake: a multi-word parameter update that the
strategy can observe mid-write. Parameter updates must be **double-buffered with an
atomic commit** — write to the shadow bank, verify CRC, then flip one bit.

---

## 12. Test corpus management

pcaps are large — a full Nasdaq TotalView-ITCH session is many gigabytes — and git
handles them badly.

| Concern | Approach |
| --- | --- |
| Storage | Object store (S3-compatible) or a shared NFS path. **Not in git.** |
| Versioning | `tb/corpus/manifest.yaml` in git: for each entry, a name, description, market date, symbol set, SHA256, byte size, and URL. The manifest is the versioned artifact. |
| Fetch | `scripts/fetch_corpus.py` downloads by manifest, verifies SHA256, caches locally. CI caches the volume. |
| Slicing | Keep a **short set** — a few hundred milliseconds around each interesting event, a few MB each — for per-PR CI. Full-day captures run nightly. |
| Provenance | Record where each capture came from and its market data licensing status. ⚠️ Market data is licensed; redistributing captures may violate the agreement. Check before sharing a corpus outside the firm. |
| Synthetic entries | Generated corpora (fuzzed, gap-injected, burst-amplified) are produced by a **seeded** generator; commit the generator and the seed, not the output. |
| Retention | Keep every corpus entry that ever caught a bug, forever, with a comment naming the bug. |

> **Verify:** market data redistribution rights are governed by your **Nasdaq market
> data agreement**. Confirm with compliance before moving captures between
> environments or vendors.

---

## 13. Coverage and the definition of "done"

Coverage is a floor, not a goal. A block is **done** when all of the following are
true:

- [ ] Verilator lint clean, zero warnings, zero unjustified waivers.
- [ ] Every port and parameter documented in the module header, with the declared
      latency and resource budget (`CLAUDE.md` §4).
- [ ] Unit testbench covers every row of the §2 table.
- [ ] Statement/branch/toggle coverage ≥ 95 % on the module; every uncovered item
      has a written justification.
- [ ] FSM state and arc coverage 100 %. An unreachable state is either removed or
      documented as a defensive default.
- [ ] Every counter the module exposes has been observed to increment in a test.
- [ ] Every error path has a directed test.
- [ ] Cycle-exact latency assertion in place and passing.
- [ ] Module participates in the full-path integration test.
- [ ] Contribution to the pcap replay regression passes bit-exact against the
      golden model.
- [ ] Post-route timing closes on a seed sweep with the module included.
- [ ] SVA assertions for the module's key invariants are written and enabled in
      simulation.

⚠️ "It works in the testbench" is not done. "It closed timing" is not done. Done is
the whole list.

---

## Further reading

- [01-build-and-release.md](01-build-and-release.md) — CI wiring and merge gates
- [02-deployment-and-colocation.md](02-deployment-and-colocation.md) — conformance and canary in their operational context
- [03-monitoring-and-telemetry.md](03-monitoring-and-telemetry.md) — the counters these tests assert on
- [../01-fpga-design/05-verification-and-simulation.md](../01-fpga-design/05-verification-and-simulation.md) — cocotb/Verilator mechanics
- [../05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md) — how measured latency is obtained
- [../07-reference/04-checklists.md](../07-reference/04-checklists.md) — the testbench-completeness checklist in task-list form
