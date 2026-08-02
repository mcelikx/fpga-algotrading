# 01.05 — Verification and Simulation

> **Why this matters here:** a bug in a web service returns a 500. A bug in this
> system sends a wrong order to a live venue at 10 Gbps and keeps doing it until
> someone notices. There is no exception handler, no retry, and no rollback. The
> only thing standing between a mis-decoded ITCH field and a regulatory incident is
> the testbench. Verification is not a phase of this project; it is most of it.

---

## 1. The verification tiers

Each tier catches a class of bug the tier below it cannot. Run in order; a failure
at tier N means you do not proceed to N+1.

| Tier | Tool | Runtime | Catches | Runs |
| --- | --- | --- | --- | --- |
| **0. Lint** | `verilator --lint-only -Wall` | seconds | Latches, width mismatches, unused/undriven signals, blocking-in-`always_ff` | Pre-commit hook |
| **1. Unit sim** | cocotb + Verilator | seconds–minutes | Module-level functional bugs, protocol contract violations | Every commit |
| **2. Block integration** | cocotb + Verilator | minutes | Interface mismatches, pipeline depth mismatches, backpressure interactions | Every commit |
| **3. pcap replay vs. golden model** | cocotb + Verilator + Python model | minutes–hours | **Feed decode and book correctness. The tier that matters most.** | Every commit (short pcap), nightly (full session) |
| **4. Full-path sim** | vendor sim (xsim/Questa) with vendor IP | hours | MAC/GT/PCIe IP integration, reset sequencing, real framing | Nightly |
| **5. Gate-level sim** | vendor sim + post-P&R netlist + SDF | hours–days | Synthesis/optimization mismatch, X-propagation on reset, missing initialization | Per release candidate |
| **6. Hardware loopback** | Real bitstream, fibre loopback, timestamping | minutes | Link behaviour, actual latency, everything simulation cannot model | Per release candidate |
| **7. Venue conformance / UAT** | Real bitstream against the venue's test system | days | Protocol conformance, session-layer behaviour | Before any production deployment |

⚠️ **Tiers 0–3 are cheap and fast, so they get run constantly and people trust
them too much.** They run on RTL, in one clock domain, with an idealised MAC. They
cannot see CDC, timing, or link behaviour. See §9.

---

## 2. cocotb testbench structure

Python testbenches, Verilator or xsim as the simulator underneath. The reason
cocotb wins here over SystemVerilog/UVM: **the same Python code that builds ITCH
messages for the stimulus also builds them for the golden model.** One
implementation of the protocol in the testbench, not two.

### Directory layout — `tb/`

```
tb/
├── common/                     shared infrastructure, imported everywhere
│   ├── axis.py                 AxisSource / AxisSink / AxisMonitor
│   ├── itch.py                 ITCH 5.0 message builders + field decoders
│   ├── mold.py                 MoldUDP64 framing / deframing
│   ├── ouch.py                 OUCH 5.0 builders + decoders (for checking TX output)
│   ├── eth.py                  Ethernet/IP/UDP header build + parse
│   ├── pcap.py                 pcap/pcapng reader → iterator of UDP payloads
│   └── clocking.py             156.25 MHz clock + reset helpers
├── model/                      THE ORACLE — golden software reference
│   ├── book.py                 order-book model (order-based, matching ITCH semantics)
│   ├── symtab.py               stock-locate → config, mirrors the fabric table
│   ├── risk.py                 pre-trade risk model
│   ├── strategy.py             strategy model (must match the RTL exactly)
│   └── trace.py                canonical event serialization used by both sides
├── unit/                       one directory per RTL module, mirroring rtl/
│   ├── skid_buffer/
│   ├── itch_parser/
│   │   ├── test_itch_parser.py
│   │   └── Makefile
│   ├── book_ram/
│   ├── symbol_table/
│   ├── risk_gate/
│   └── ouch_encoder/
├── integration/
│   ├── feed_handler/           mold deframe + parse + symtab + book
│   ├── order_path/             strategy + risk + encode + MAC TX
│   └── tick_to_trade/          MAC RX in → MAC TX out, the whole thing
├── fixtures/
│   ├── pcap/                   small committed captures (git-lfs); large ones fetched by hash
│   ├── golden/                 expected trace HASHES (committed) — not the blobs
│   └── seeds/                  frozen seeds for every reproduced random failure
├── sva/                        bind files: <module>_props.sv, one per RTL module
├── conftest.py                 pytest fixtures, simulator selection, waveform control
├── Makefile                    top-level: make lint | unit | integration | replay | all
└── regression.yaml             CI job definitions and their pcap/seed inventories
```

**Rules:** `tb/unit/` mirrors `rtl/` exactly, one directory per module — a module
with no directory here has no test and does not go on the fast path. `tb/model/` is
the oracle: optimized for **being obviously correct**, never for speed; no caching,
no early exits, it should read like the protocol spec. And nothing in `tb/common/`
imports from `tb/model/` or vice versa — the stimulus builder and the oracle must be
able to disagree.

### Worked example: driving an AXI-Stream ITCH beat

```python
# tb/common/itch.py
import struct

def add_order(locate, tracking, ts_ns, order_ref, side, shares, stock, price):
    """ITCH 5.0 'A' — Add Order (No MPID Attribution). 36 bytes, big-endian.
       price is in units of 1/10000 (4 implied decimals) — never a float."""
    assert side in (b"B", b"S")
    return (b"A"
            + struct.pack(">H", locate)
            + struct.pack(">H", tracking)
            + ts_ns.to_bytes(6, "big")          # nanoseconds since midnight
            + struct.pack(">Q", order_ref)
            + side
            + struct.pack(">I", shares)
            + stock.ljust(8, b" ")
            + struct.pack(">I", price))


# tb/common/mold.py
def mold64(session, seq, msgs):
    """MoldUDP64 downstream packet: 10B session, 8B seq, 2B count, then
       length-prefixed messages."""
    body = b"".join(struct.pack(">H", len(m)) + m for m in msgs)
    return session.ljust(10, b" ") + struct.pack(">Q", seq) \
         + struct.pack(">H", len(msgs)) + body
```

```python
# tb/common/axis.py
from cocotb.triggers import RisingEdge, ReadOnly

class AxisSource:
    """Minimal AXI-Stream master. One packet -> N beats, tlast on the final beat."""

    def __init__(self, dut, clk, prefix="s_axis", width_bytes=8):
        self.clk, self.wb = clk, width_bytes
        for a, s in (("d","tdata"),("v","tvalid"),("r","tready"),
                     ("k","tkeep"),("l","tlast")):
            setattr(self, a, getattr(dut, f"{prefix}_{s}"))
        self.v.value = self.l.value = 0

    async def send(self, payload: bytes, gap_cycles: int = 0):
        for off in range(0, len(payload), self.wb):
            beat = payload[off:off + self.wb]
            # AXI-Stream: payload byte 0 -> tdata[7:0], hence little-endian pack.
            self.d.value = int.from_bytes(beat.ljust(self.wb, b"\x00"), "little")
            self.k.value = (1 << len(beat)) - 1
            self.l.value = int(off + self.wb >= len(payload))
            self.v.value = 1
            while True:                          # hold the beat until tready
                await ReadOnly()                 # settled values, before the edge
                accepted = bool(self.r.value)
                await RisingEdge(self.clk)       # the edge itself
                if accepted:
                    break
        self.v.value = self.l.value = 0
        for _ in range(gap_cycles):
            await RisingEdge(self.clk)
```

```python
# tb/unit/itch_parser/test_itch_parser.py
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
from tb.common.axis import AxisSource
from tb.common.itch import add_order
from tb.common.mold import mold64

CLK_NS = 6.4          # 156.25 MHz — the project core clock

async def bringup(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rst.value, dut.s_axis_tvalid.value = 1, 0
    await ClockCycles(dut.clk, 8)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

async def collect(dut, out, n_cycles):
    """Monitor the parser's decoded-message output port."""
    for _ in range(n_cycles):
        await RisingEdge(dut.clk)
        if dut.m_msg_valid.value:
            out.append(dict(locate    = int(dut.m_msg_locate.value),
                            order_ref = int(dut.m_msg_order_ref.value),
                            side      = int(dut.m_msg_side.value),
                            shares    = int(dut.m_msg_shares.value),
                            price     = int(dut.m_msg_price.value)))

@cocotb.test()
async def test_add_order_every_beat_offset(dut):
    """THE test for a feed handler. The same message must decode identically no
       matter where in the 8-byte beat it starts. Off-by-one reassembly bugs are
       the #1 defect class in ITCH parsers and only appear at some offsets."""
    await bringup(dut)
    src = AxisSource(dut, dut.clk)
    REF = 0xDEADBEEF00000001
    msg = add_order(locate=1234, tracking=0, ts_ns=34_200_000_000_000,
                    order_ref=REF, side=b"B", shares=100,
                    stock=b"AAPL", price=1_875_000)          # $187.5000

    for pad in range(8):
        got = []
        mon = cocotb.start_soon(collect(dut, got, 200))
        # `pad` short leading messages shift the Add Order's byte offset in the beat.
        filler = [b"H" + b"\x00" * 10] * pad                 # Trading Action, 11B
        await src.send(mold64(b"TESTSESS01", 1 + pad, filler + [msg]))
        await mon

        adds = [m for m in got if m["order_ref"] == REF]
        assert len(adds) == 1, f"pad={pad}: expected 1 Add Order, got {len(adds)}"
        assert adds[0] == dict(locate=1234, order_ref=REF, side=0,
                               shares=100, price=1_875_000), \
               f"pad={pad}: field mismatch {adds[0]}"
```

> **Verify:** ITCH 5.0 message layouts, lengths, and the MoldUDP64 header format
> against the current **Nasdaq TotalView-ITCH 5.0** and **MoldUDP64** specifications
> from Nasdaq Trader. Message lengths change between protocol versions and the
> `Stock Trading Action` length above is illustrative.

---

## 3. Verilator vs. a commercial simulator

| | Verilator | xsim / Questa / VCS |
| --- | --- | --- |
| Speed | **10–100× faster** — it compiles to C++ | Interpreted/compiled event-driven |
| Cost | Free | Licensed (xsim ships with Vivado) |
| 4-state (X/Z) | 2-state by default; `--x-assign`/`--x-initial` approximate it | Full 4-state |
| SVA | Growing support; concurrent assertions largely work, complex sequences and `local` variables are patchy | Full |
| Covergroups / functional coverage | **Not supported** | Full |
| Delays / `#` timing | Verilator 5 added timing support; still not the target use case | Full |
| Encrypted vendor IP | **Cannot simulate it** | Yes |
| Vendor primitives (GTY, PCIe, MMCM) | Only the simple ones, with effort | Yes |
| Gate-level + SDF | **No** | Yes |
| UVM | No | Yes |

> **Verify:** Verilator's SVA, timing, and coverage support moves fast — check the
> "Language Limitations" section of the Verilator manual for the exact version you
> pin, rather than trusting this table. Vendor-simulator SVA/coverage support is in
> UG900 (Vivado Logic Simulation) or your simulator's user guide.

**Project policy:** Verilator + cocotb for tiers 0–3 — speed is the whole point, and
a full-session replay of tens of millions of ITCH messages is only feasible at
Verilator speeds. A regression that takes an hour is a regression nobody runs. Use
xsim (or Questa) for tiers 4–5, where the encrypted MAC/GT/PCIe models and
gate-level netlists live. Write RTL that simulates identically in both: explicit
reset rather than `initial` values on the fast path, simple assertion forms, and no
dependence on X-propagation semantics for correctness.

⚠️ **Verilator's 2-state default hides reset bugs.** A register you forgot to reset
reads as 0 in Verilator, X in xsim, and whatever the FPGA powered up with in
hardware. Run one nightly pass with `--x-assign unique --x-initial unique` and one
with a 4-state simulator, specifically to catch this.

---

## 4. pcap replay against a golden book model

**This is the core verification technique for this project.** Everything else is
supporting infrastructure.

A feed handler plus an order book is a large, stateful, order-dependent transform.
You cannot unit-test your way to confidence in it: the bugs live in *sequences* of
messages that only occur in real market data — an execution against an order added
40 million messages earlier, a cross that empties one side, a symbol that halts and
reopens.

### The structure

```
                    ┌──────────────────────────────────────────┐
    real pcap ──┬──>│ tb/model/book.py  (the oracle)           │──> golden trace
    (unmodified)│   │ dumb, obvious, spec-shaped Python        │
                │   └──────────────────────────────────────────┘
                │                                                      ┌────────┐
                │   ┌──────────────────────────────────────────┐       │  diff  │
                └──>│ cocotb replay → RTL feed handler + book  │──────>│  first │
                    │ AxisSource driving MAC-side beats        │  DUT  │ mismatch│
                    └──────────────────────────────────────────┘ trace └────────┘
```

### What the DUT emits

Add a **book-event trace port** to the design: on every message that changes the
book, emit a fixed-format record.

```systemverilog
// rtl/book/book_trace.sv — a real port, not a simulation hack.
// In production this feeds the telemetry DMA ring; in simulation it is the oracle
// comparison point. Same logic, same semantics, always exercised.
output logic        trace_valid,
output logic [63:0] trace_seq,        // ITCH/MoldUDP sequence number of the message
output logic [15:0] trace_locate,
output logic [31:0] trace_bid_px,     // top of book AFTER applying the message
output logic [31:0] trace_bid_qty,
output logic [31:0] trace_ask_px,
output logic [31:0] trace_ask_qty
```

Making the trace a **first-class output that ships in the production bitstream** —
rather than a `` `ifdef SIMULATION `` debug hack — is the single best structural
decision in the verification plan: the thing you verified is the thing you deployed,
you can run the same comparison against a live capture from production hardware, and
the telemetry path gets exercised by every regression run.

### The five rules that make this actually work

1. **The oracle must implement exactly the same simplifications as the RTL.**
   If the fabric tracks 10 price levels, the model tracks 10 price levels. If the
   fabric only tracks 500 symbols, the model filters to the same 500.
   ⚠️ **Divergence caused by an intentional simplification is indistinguishable
   from a bug**, and chasing one is how a week disappears. Put every simplification
   in one shared config file that both the RTL parameters and the model read.

2. **Canonical, integer-only, one-record-per-line serialization.**
   ```
   seq=00000000000123457 loc=01234 bid=0001875000@0000000300 ask=0001875100@0000000100
   ```
   Fixed widths, no floats, no timestamps, no dict ordering. Then the comparison is
   `cmp`, not a fuzzy comparator you have to trust. Commit the **hash** of the
   golden trace, not the multi-gigabyte trace itself.

3. **Stop at the first divergence and print context.** "12,481 differences" is
   unactionable. The report you want is:
   ```
   FIRST DIVERGENCE at ITCH seq 40,118,993 (locate 1234 = "AAPL")
     expected  bid=0001875000@0000000300  ask=0001875100@0000000100
     actual    bid=0001875000@0000000400  ask=0001875100@0000000100
   Last 8 messages for this locate:
     40118986  A  ref=0x0000A1B2  B  300 @ 1875000
     40118991  E  ref=0x0000A1B2     100
     40118993  D  ref=0x0000A1B2
   ```
   The last-N-messages-for-this-symbol window is what turns a failure into a fix.
   Build it into the harness on day one.

4. **Replay the capture byte-for-byte.** Do not filter, de-duplicate, reorder, or
   "clean" it. Retransmissions, A/B duplicates, gaps, and malformed frames are
   exactly the inputs you need. If the pcap ends in a truncated packet, feed it in.

5. **The oracle is reviewed like production code.** It is the definition of correct.
   A bug in the oracle that happens to match a bug in the RTL is the worst available
   outcome — which is why the oracle is written from the *spec*, by someone reading
   the spec, and never derived from the RTL.

### Where pcaps come from

| Source | Fidelity | Notes |
| --- | --- | --- |
| Nasdaq test/UAT feed capture | High | The correct primary source. Coordinate with the venue. |
| Vendor / venue sample data files | Medium-high | Nasdaq publishes historical ITCH sample files; check the licence |
| Your own colo capture (tap or mirror port) | Highest | Requires a capture NIC with hardware timestamping |
| Synthetic generation from `tb/common/itch.py` | Low realism, high control | For directed edge cases only |

⚠️ **Exchange market data is licensed.** Do not commit real venue captures to any
repository, public or private, without checking the redistribution terms. Store them
in an access-controlled artifact store and commit only their hashes.

### Divergence triage table

When the diff fires, the shape of the failure tells you where to look:

| Symptom | Almost always |
| --- | --- |
| One field wrong on **every** message of one type | Field offset / length error in the parser |
| Wrong **only** when the message crosses a beat boundary | Reassembly / straddle bug (§6) |
| Wrong **only** on back-to-back updates to one price level | Missing write-forwarding on the book RMW ([03-memory-and-storage.md](03-memory-and-storage.md) §4) |
| Values are byte-swapped or absurdly large | Endianness — ITCH is big-endian, AXI-Stream is little-endian-by-byte |
| Price off by a factor of 10^k | Implied-decimal scaling |
| Random symbols wrong, only under high load | Order-reference hash table full, overflow silently dropped |
| Diverges after a specific timestamp every run | A `Trading Action` / halt / cross message type you didn't implement |
| Diverges at a different point on every run | You have a race, and it is probably CDC — simulation is lying to you (§9) |

---

## 5. SVA assertions: what to assert and where to put it

**Put assertions in separate `bind` files, not inline in the RTL.** The
synthesizable source stays clean, the assertions can use non-synthesizable
constructs freely, and there is no `` `ifdef `` clutter.

```systemverilog
// tb/sva/itch_parser_props.sv
module itch_parser_props #(parameter int N_SYMBOLS = 8192) (
    input logic clk, rst, s_tvalid, s_tready, s_tlast, m_msg_valid,
    input logic [63:0] s_tdata,
    input logic [15:0] m_msg_locate
);
    // The stream contract from 01.01 §1
    a_stable: assert property (@(posedge clk) disable iff (rst)
        (s_tvalid && !s_tready) |=> (s_tvalid && $stable(s_tdata) && $stable(s_tlast)))
        else $error("AXIS contract violated: data changed while stalled");

    // Project rule: the RX path never back-pressures. Must hold, always.
    a_never_stall: assert property (@(posedge clk) disable iff (rst) s_tready)
        else $error("RX path asserted backpressure — forbidden (CLAUDE.md §5.4)");

    // A decoded locate must be within the configured universe
    a_locate_range: assert property (@(posedge clk) disable iff (rst)
        m_msg_valid |-> (m_msg_locate < N_SYMBOLS))
        else $error("decoded locate %0d out of range", m_msg_locate);
endmodule

bind itch_parser itch_parser_props u_props (.*);
```

### Assertion inventory for this project

| Where | Property |
| --- | --- |
| Every AXI-Stream port | The full valid/ready contract (stable while stalled, no valid de-assert) |
| RX path | `tready` is always high — never stalls |
| Every FIFO | Never write when full; never read when empty; occupancy ≤ depth |
| Every dual-port memory | No cross-port address collision ([03-memory-and-storage.md](03-memory-and-storage.md) §4) |
| Every FSM | State is always a legal encoding; no unreachable state entered |
| Book | `best_bid < best_ask` whenever both sides are populated (crossed book = alarm) |
| Book | Level quantity never goes negative (it should saturate and count, not wrap) |
| **Risk gate** | **`order_out_valid |-> risk_ok` — an order can never leave without a passing risk check.** This is the most important assertion in the codebase. |
| **Kill switch** | **`kill_armed |-> ##[0:KILL_LATENCY] !order_out_valid`** — bounded, provable |
| Order encoder | Emitted frame length matches the OUCH message length field |
| Pipeline | `valid` and its matched delay-line depth agree (no data/valid skew) |

The risk-gate and kill-switch properties are also **proven formally** (Vivado's
formal flow / SymbiYosys), not merely simulated. They are small, bounded, and
exactly the shape formal handles well — and they are the two properties whose
failure is a regulatory event rather than a bug.

---

## 6. Constrained-random and protocol edge cases

Directed tests find the bugs you thought of. Randomization finds the rest. For a
feed handler, the high-value random axes are:

| Axis | Why it matters | How to randomize |
| --- | --- | --- |
| **Byte offset of a message within a beat** | The #1 defect class. A 36-byte message at offset 0 and at offset 5 exercise completely different reassembly paths. | Vary the number and length of preceding messages in the packet |
| **Message straddling the end of a packet** | MoldUDP64 delivers complete messages per packet, but your *bus beats* still split them, and a beat can be the last of a packet | Vary packet composition and total length |
| Inter-packet gap | Exposes state left over between packets | 0 to 100 idle cycles, geometric distribution |
| Message type mix | Rare types are where the parser is weakest | Weight by real capture frequency, plus a uniform "rare types" mode |
| Sequence gaps | Gap detection and recovery | Drop 1, 2, N consecutive packets |
| Duplicates / out-of-order | A/B feed arbitration | Replay a packet, replay it late |
| Malformed input | Truncated packet, message length field longer than the packet, message count field wrong, unknown message type | Corrupt one field at a time, systematically |
| Same-symbol / same-price-level bursts | The book RMW hazard | Force N back-to-back updates to one level, for N = 1..bypass_depth+2 |
| Order-reference collisions | Hash table behaviour under stress | Craft refs that hash to the same set |

```python
seed = int(os.environ.get("SEED", random.randrange(2**32)))
dut._log.info(f"SEED={seed}")              # ALWAYS log the seed. Always.
rng = random.Random(seed)
```

**Rules:**
- **Every random test logs its seed on the first line of output.** A random failure
  you cannot reproduce is not a finding, it is a rumour.
- **Every reproduced failure gets its seed frozen** into `tb/fixtures/seeds/` as a
  permanent directed test. The suite grows monotonically.
- ⚠️ **Malformed-input tests assert on the counter, not on "didn't crash".** The
  correct behaviour for a truncated packet is *drop it and increment
  `rx_malformed_count`*. A design that silently discards it passes a "didn't crash"
  test and violates CLAUDE.md §5.7.

### Functional coverage

Verilator has no covergroups, so collect coverage in Python —
`COVER[(msg_type, beat_offset, is_last_beat_of_packet)] += 1`. Cross the axes that
actually interact. Minimum goals before a release candidate:

- Every ITCH message type the design claims to handle: **seen ≥ 100 times**
- Cross (message type × starting byte offset 0–7): **every bin hit**
- Cross (message type × is-last-in-packet): **every bin hit**
- Every FSM state and every legal transition: **hit**
- Book: empty side, single level, full depth, crossed (rejected), level deleted at
  top of book: **all hit**
- Risk gate: **every rejection reason fired at least once**

Report coverage per run and **fail CI on a decrease**, not on an absolute threshold.

---

## 7. Regression discipline and CI

| Job | Trigger | Content | Budget |
| --- | --- | --- | --- |
| `lint` | pre-commit hook + every push | `verilator --lint-only -Wall` on all of `rtl/` | < 10 s |
| `unit` | every push | All of `tb/unit/`, Verilator | < 3 min |
| `integration` | every push | `tb/integration/`, Verilator | < 10 min |
| `replay-short` | every push | 60 s of real pcap vs. oracle | < 10 min |
| `synth-check` | every push to `main` | `synth_design` only; **fail on any new critical warning**, latch inference, or Fmax estimate below target | < 30 min |
| `replay-full` | nightly | A full trading session vs. oracle | hours |
| `random-soak` | nightly | Random tests, fresh seeds, N iterations | hours |
| `vendor-sim` | nightly | Tier 4 with real MAC/GT/PCIe models under xsim | hours |
| `implement` | nightly on `main` | Full P&R; **record WNS/TNS and utilization as build artifacts** | hours |
| `gate-level` | release candidate | Post-P&R netlist + SDF | hours |

**Discipline rules:**
1. **`main` is always green.** A red `main` means nobody can tell whether their own
   change broke something, and the apparatus stops being useful within a day.
2. **A bug fix without a test that fails before the fix is not a fix.**
3. **Never disable a test to get a build through.** Mark it `xfail` with an issue
   number and an owner, or fix it. A commented-out test is a lie in the coverage
   report.
4. **Track WNS/TNS and LUT/FF/BRAM/URAM/DSP per commit**, plotted over time. Timing
   and resources degrade gradually and then suddenly; the graph gives weeks of
   warning. Quote the actual report — never estimate.
5. **Pin everything**: simulator version, Vivado version, Python packages, pcap
   fixture hashes, seeds for the "deterministic" tests. A suite whose results change
   on a tool upgrade is not a regression suite.
6. **Store the golden trace hash, not the trace.** Multi-GB blobs in git will end
   the project's ability to clone.

---

## 8. Gate-level and hardware loopback

**Gate-level simulation (tier 5)** runs the post-P&R netlist with SDF
back-annotation. Slow and painful, and still mandatory before every release: it is
the only thing that catches synthesis/simulation mismatch, X-propagation through
un-reset registers at power-up, reset-release ordering problems, and optimizations
that removed logic you thought was there. Run it on a few hundred messages of
targeted stimulus, not a full session.

**Hardware loopback (tier 6)** is the first time you see the truth. Fibre from your
TX to your RX, timestamp at the pin, replay pcap from a second machine.

| Measurement | How |
| --- | --- |
| True wire-to-wire latency | Hardware timestamp on RX SOF and TX SOF, differenced in fabric, histogrammed |
| Latency distribution | p50 / p99 / p99.9 / max, in a fabric histogram read over PCIe. **Never report only the mean.** |
| Link integrity | PRBS31 BER, FCS error counters, eye scan |
| Behaviour under burst | Replay the worst historical minute at full line rate; check every drop counter is zero |
| Reset/link-flap robustness | Physically pull and reinsert the fibre, repeatedly, under traffic |

See [05-optimization/04-measurement-and-profiling.md](../05-optimization/04-measurement-and-profiling.md)
for the instrumentation and
[04-io-transceivers-and-serdes.md](04-io-transceivers-and-serdes.md) §9 for link
bring-up.

---

## 9. What simulation cannot catch

Keep this list visible. Every item here has ended somebody's trading day.

| Not catchable in RTL simulation | Why | What catches it instead |
| --- | --- | --- |
| **CDC / metastability** | RTL simulation has no notion of setup/hold across domains; it samples cleanly every time | Vivado `report_cdc`, structural CDC lint, gate-level sim with SDF, and *only using sanctioned CDC primitives* |
| **Timing failure** | Simulation is untimed | Static timing analysis. WNS/TNS from the actual implementation report. |
| **Reset release / power-up state** | Simulation starts from a defined reset | Gate-level sim with X-propagation; explicit reset of every control register |
| **Real link behaviour** | No bit errors, no FEC, no link flap, no auto-negotiation | Hardware, PRBS soak, eye scan, physically pulling cables |
| **Actual latency in nanoseconds** | Simulation gives cycles, not the IO stack's ns | Hardware loopback with pin timestamps |
| **Congestion / routing delay** | Not modelled | Implementation reports; the Device view |
| **Vendor IP quirks** | Encrypted models are approximations; some behaviours only appear in silicon | Tier 4/6, and the vendor's answer records |
| **Thermal, power, SEU** | Not modelled at all | Hardware soak, SEM IP, monitoring |
| **Venue protocol quirks** | Your model of the venue is your model, not the venue | Venue UAT / conformance testing (tier 7) |
| **The spec being wrong in your head** | The oracle and the RTL can share a misreading | An independent reader checking the oracle against the spec |

⚠️ The last row is the dangerous one. A perfectly green regression suite proves
your RTL matches your model. It proves nothing about whether your model matches
Nasdaq. **The only defence is venue conformance testing and reading the spec with
someone else.** Budget time for it.

---

## Further reading

- [01-rtl-design-patterns.md](01-rtl-design-patterns.md) — the stream contract the assertions in §5 enforce
- [03-memory-and-storage.md](03-memory-and-storage.md) — the RMW hazard that §4's divergence table points at
- [04-io-transceivers-and-serdes.md](04-io-transceivers-and-serdes.md) — hardware loopback and link bring-up
- [06-hls-and-alternative-flows.md](06-hls-and-alternative-flows.md) — verifying generated and HLS-produced RTL
- [00-foundations/04-clocking-reset-and-cdc.md](../00-foundations/04-clocking-reset-and-cdc.md) — the class of bug §9 says simulation will not find
- [04-system-architecture/02-feed-handler-design.md](../04-system-architecture/02-feed-handler-design.md) — the DUT this whole document exists to verify
- [06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md) — tiers 6 and 7, soak, conformance, and production canary
- [07-reference/04-checklists.md](../07-reference/04-checklists.md) — the module review checklist
