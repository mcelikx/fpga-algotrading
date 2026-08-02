"""cocotb tests for ``rtl/feed/itch_decoder.sv``.

Project : FPGA Algorithmic Trading System (Nasdaq Equities)
Governs : manuals/08-nasdaq/04-totalview-itch-5.0.md
          manuals/04-system-architecture/02-feed-handler-design.md
          manuals/01-fpga-design/05-verification-and-simulation.md §2, §6

The decoder takes one whole ITCH message in a single 512-bit beat
(``trading_pkg::ITCH_MSG_W``) plus its length, and emits one
``trading_pkg::book_evt_t``. Its budget is ONE cycle (rtl/fpga_top.sv latency
table, "ITCH decode (fixed-offset extraction)"), which is only achievable
because every ITCH message type has a FIXED length and FIXED field offsets —
so the decoder is a type-indexed mux over fixed bit slices, not a parser.

What these tests establish
--------------------------
1. Every message type produces the right ``book_op_e`` and the right fields.
2. ⚠️ Order Replace ('U') emits BOTH the original and the new order reference.
3. A length that disagrees with the type's fixed length is COUNTED and DROPPED.
4. An unknown type is COUNTED and SKIPPED — never fatal.
5. Big-endian wire fields are converted correctly.

⚠️ ON THE SHARED-MISREADING RISK
   ``tb/common/itch_gen.py`` builds messages from the same offset table that
   ``rtl/pkg/itch_pkg.sv`` gives the RTL. If an offset is wrong in both, these
   tests pass and the decoder is wrong. Test 5 (endianness) partially guards
   this by using values whose byte-reversal is unmistakable, and the offset
   tests use distinct magic values per field so a swapped pair cannot alias.
   Neither is a substitute for a human reading the spec PDF, which is a release
   gate (manuals/06-operations/01-build-and-release.md §8 item 11).

TODO(verify) — PORT NAMES
   Signal names below follow ``rtl/fpga_top.sv``'s ``u_feed`` connections and
   the ``book_evt_t`` field names in ``rtl/pkg/trading_pkg.sv``. The DUT is the
   flattening wrapper ``tb/feed/tb_itch_decoder_top.sv`` (see tb/filelist.f),
   which exposes the packed struct as individual ports because poking a packed
   struct through the VPI is awkward. Confirm the wrapper's port names against
   ``rtl/feed/itch_decoder.sv`` once it is final.
"""

from __future__ import annotations

import os
import random
import sys
from pathlib import Path

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from common import itch_gen as ig                    # noqa: E402
from common.axis_driver import bringup               # noqa: E402

# trading_pkg::book_op_e
BOOK_ADD, BOOK_EXECUTE, BOOK_CANCEL = 0, 1, 2
BOOK_DELETE, BOOK_REPLACE, BOOK_CLEAR, BOOK_NOP = 3, 4, 5, 6

# trading_pkg::side_e
SIDE_BUY, SIDE_SELL = 0, 1

LOCATE = 1234
SYM = "AAPL"

#: trading_pkg::ITCH_MSG_MAX_BYTES
MSG_BYTES = 64


# =============================================================================
# Helpers
# =============================================================================
async def push(dut, msg: bytes, length: int | None = None) -> None:
    """Present one ITCH message to the decoder for exactly one cycle.

    Byte packing: message byte 0 occupies ``s_msg[7:0]``, matching the
    AXI-Stream convention used everywhere else in this design (payload byte 0
    -> LSB). ⚠️ TODO(verify) against ``rtl/net/net_rx_path.sv``, which builds
    this beat — if it packs the other way every offset in the decoder is wrong
    by exactly the message length, which is the kind of bug that produces
    plausible-looking garbage rather than obvious garbage.
    """
    padded = msg.ljust(MSG_BYTES, b"\x00")
    dut.s_msg.value = int.from_bytes(padded, "little")
    dut.s_len.value = len(msg) if length is None else length
    dut.s_valid.value = 1
    await RisingEdge(dut.clk)
    dut.s_valid.value = 0


class EvtCollector:
    """Capture every ``book_evt_t`` the decoder emits."""

    def __init__(self, dut):
        self.dut = dut
        self.events: list[dict] = []
        self._task = cocotb.start_soon(self._run())

    async def _run(self):
        d = self.dut
        while True:
            await RisingEdge(d.clk)
            await ReadOnly()
            if int(d.rst.value):
                continue
            if int(d.m_evt_valid.value):
                self.events.append({
                    "op": int(d.m_evt_op.value),
                    "sym": int(d.m_evt_sym.value),
                    "locate": int(d.m_evt_locate.value),
                    "side": int(d.m_evt_side.value),
                    "price": int(d.m_evt_price.value),
                    "qty": int(d.m_evt_qty.value),
                    "order_ref": int(d.m_evt_order_ref.value),
                    "new_order_ref": int(d.m_evt_new_order_ref.value),
                    "exch_ts": int(d.m_evt_exch_ts.value),
                    "printable": int(d.m_evt_printable.value),
                })

    def clear(self):
        self.events.clear()

    def stop(self):
        self._task.kill()


async def stat(dut, name: str) -> int:
    """Read one telemetry counter by name.

    ⚠️ CLAUDE.md §5.7: "Every drop, error, and rejected order is counted in a
    readable register. Silent failure is the worst failure mode in this domain."
    Every negative test below asserts on a COUNTER, never on "the DUT did not
    crash". A design that silently discards a malformed message passes a
    didn't-crash test and violates the rule.

    TODO(verify): the wrapper is expected to expose the decoder's ``stat[]``
    array as named ports. Confirm the index-to-name mapping against
    ``rtl/feed/itch_decoder.sv``'s header comment when it is final.
    """
    await ReadOnly()
    return int(getattr(dut, f"stat_{name}").value)


async def setup(dut):
    dut.s_valid.value = 0
    dut.s_msg.value = 0
    dut.s_len.value = 0
    await bringup(dut)
    return EvtCollector(dut)


# =============================================================================
# 1. Every message type decodes to the right book_evt_t
# =============================================================================
@cocotb.test()
async def test_add_order_decode(dut):
    """'A' -> BOOK_ADD with side, shares, price and the order reference."""
    col = await setup(dut)
    ref = 0xDEAD_BEEF_0000_0001
    await push(dut, ig.add_order(LOCATE, ref, ig.SIDE_BUY, 300, SYM,
                                 ig.px("187.50"), ig.TS_MARKET_OPEN))
    await ClockCycles(dut.clk, 4)

    assert len(col.events) == 1, f"expected exactly 1 event, got {len(col.events)}"
    e = col.events[0]
    assert e["op"] == BOOK_ADD, f"op {e['op']} != BOOK_ADD"
    assert e["locate"] == LOCATE
    assert e["side"] == SIDE_BUY
    assert e["qty"] == 300
    assert e["price"] == 1_875_000, (
        f"price {e['price']} != 1875000. ⚠️ A price off by a factor of 10^k is "
        f"an implied-decimal scaling bug; a byte-swapped one is endianness "
        f"(05-verification §4 triage table)."
    )
    assert e["order_ref"] == ref, f"order_ref 0x{e['order_ref']:X} != 0x{ref:X}"


@cocotb.test()
async def test_add_order_mpid_decodes_as_add(dut):
    """'F' must decode EXACTLY like 'A'.

    ⚠️ 'F' is Add Order With MPID Attribution: identical to 'A' plus a trailing
    4-byte MPID. A decoder that handles 'A' and ignores 'F' silently loses every
    attributed quote in the book — which is a large fraction of the displayed
    liquidity, and the resulting book is wrong in a way that looks like thin
    markets rather than like a bug.
    """
    col = await setup(dut)
    ref = 0x0000_0000_0000_00F1
    await push(dut, ig.add_order(LOCATE, ref, ig.SIDE_SELL, 250, SYM, ig.px("99.99")))
    await push(dut, ig.add_order_mpid(LOCATE, ref + 1, ig.SIDE_SELL, 250, SYM,
                                      ig.px("99.99"), b"NSDQ"))
    await ClockCycles(dut.clk, 4)

    assert len(col.events) == 2, f"'F' was dropped: got {len(col.events)} events"
    a, f = col.events
    for field in ("op", "side", "qty", "price", "locate"):
        assert a[field] == f[field], (
            f"'A' and 'F' disagree on {field}: {a[field]} vs {f[field]}"
        )
    assert f["order_ref"] == ref + 1


@cocotb.test()
async def test_order_executed_decode(dut):
    """'E' -> BOOK_EXECUTE carrying the executed quantity."""
    col = await setup(dut)
    ref = 0x1234_5678_9ABC_DEF0
    await push(dut, ig.order_executed(LOCATE, ref, 150, 0xAA55))
    await ClockCycles(dut.clk, 4)

    assert len(col.events) == 1
    e = col.events[0]
    assert e["op"] == BOOK_EXECUTE
    assert e["order_ref"] == ref
    assert e["qty"] == 150


@cocotb.test()
async def test_order_executed_with_price_printable_flag(dut):
    """'C' -> BOOK_EXECUTE, and ``printable`` must survive to the book event.

    ⚠️ A non-printable execution does NOT update the last-sale price, but it
    DOES remove shares from the book. Conflating the two makes the book drift on
    exactly the symbols where non-printable executions happen.
    """
    col = await setup(dut)
    await push(dut, ig.order_executed_with_price(
        LOCATE, 0xAAAA, 100, 0xBB01, b"Y", ig.px("187.51")))
    await push(dut, ig.order_executed_with_price(
        LOCATE, 0xAAAB, 100, 0xBB02, b"N", ig.px("187.51")))
    await ClockCycles(dut.clk, 4)

    assert len(col.events) == 2
    assert col.events[0]["op"] == BOOK_EXECUTE
    assert col.events[0]["printable"] == 1, "printable='Y' lost"
    assert col.events[1]["printable"] == 0, (
        "printable='N' decoded as printable — the last-sale price will be "
        "updated by a trade that must not update it"
    )


@cocotb.test()
async def test_order_cancel_is_not_delete(dut):
    """'X' -> BOOK_CANCEL (partial reduce), NOT BOOK_DELETE.

    ⚠️ 'X' reduces the resting quantity; 'D' removes the order. A decoder that
    maps 'X' to a delete empties price levels that still have live size, and the
    book shows a wider spread than the market has — which a strategy will
    happily try to capture.
    """
    col = await setup(dut)
    await push(dut, ig.order_cancel(LOCATE, 0xC0FFEE, 75))
    await ClockCycles(dut.clk, 4)

    assert len(col.events) == 1
    e = col.events[0]
    assert e["op"] == BOOK_CANCEL, (
        f"'X' decoded as op {e['op']}; BOOK_CANCEL is {BOOK_CANCEL}, "
        f"BOOK_DELETE is {BOOK_DELETE}"
    )
    assert e["qty"] == 75, "the cancelled-shares field must reach the book"


@cocotb.test()
async def test_order_delete_decode(dut):
    """'D' -> BOOK_DELETE with only the order reference populated."""
    col = await setup(dut)
    ref = 0x0000_0000_DEAD_0001
    await push(dut, ig.order_delete(LOCATE, ref))
    await ClockCycles(dut.clk, 4)

    assert len(col.events) == 1
    assert col.events[0]["op"] == BOOK_DELETE
    assert col.events[0]["order_ref"] == ref


# =============================================================================
# 2. ⚠️ THE ORDER REPLACE CASE
# =============================================================================
@cocotb.test()
async def test_order_replace_emits_both_references(dut):
    """⚠️ 'U' must emit BOTH the ORIGINAL and the NEW order reference.

    This is the single most commonly mis-implemented ITCH message, and
    ``rtl/pkg/itch_pkg.sv`` carries a warning about it at ``OFF_U_ORIG_REF``:

        "'U' both removes the original reference and creates a new one. A book
         that treats it as an in-place modify will leak order references and
         drift from the true book."

    Why it must be the DECODER that surfaces both, rather than the book
    inferring them: the 'U' message does NOT carry the side or the stock. The
    replacement order inherits them from the original, so the book must look the
    original reference up — which it can only do if the decoder hands it the
    original reference alongside the new one. A decoder that emits only
    ``new_order_ref`` makes the replace unprocessable; one that emits only
    ``order_ref`` makes it look like a modify.

    ``book_evt_t`` has both fields (``order_ref`` and ``new_order_ref``) for
    exactly this message. On every other message type ``new_order_ref`` is
    don't-care.
    """
    col = await setup(dut)
    orig, new = 0x1111_2222_3333_4444, 0x5555_6666_7777_8888
    await push(dut, ig.order_replace(LOCATE, orig, new, 500, ig.px("187.55")))
    await ClockCycles(dut.clk, 4)

    assert len(col.events) == 1, (
        f"'U' produced {len(col.events)} events. It must produce exactly ONE "
        f"book_evt_t carrying both references — not two events, and not one "
        f"with only half the information."
    )
    e = col.events[0]
    assert e["op"] == BOOK_REPLACE, f"op {e['op']} != BOOK_REPLACE"
    assert e["order_ref"] == orig, (
        f"ORIGINAL reference wrong: got 0x{e['order_ref']:016X}, "
        f"want 0x{orig:016X}. Without it the book cannot find the order to "
        f"remove — it will leak, and quantity will accumulate that the real "
        f"book does not have."
    )
    assert e["new_order_ref"] == new, (
        f"NEW reference wrong: got 0x{e['new_order_ref']:016X}, "
        f"want 0x{new:016X}. Without it the replacement order is never created "
        f"and the book loses liquidity that is really there."
    )
    assert e["order_ref"] != e["new_order_ref"], (
        "the two references are equal — the decoder is extracting the same "
        "8 bytes twice. Check OFF_U_ORIG_REF (11) vs OFF_U_NEW_REF (19)."
    )
    assert e["qty"] == 500
    assert e["price"] == 1_875_500


@cocotb.test()
async def test_order_replace_field_offsets_are_distinct(dut):
    """Every 'U' field gets a distinct magic value, so no two can alias.

    ⚠️ Guards against the specific failure where two adjacent fields are read
    from overlapping or swapped offsets. With distinct, non-repeating values a
    swap is impossible to miss; with realistic values (both references looking
    like plausible order IDs) a swap is easy to miss.
    """
    col = await setup(dut)
    orig = 0xA0A1_A2A3_A4A5_A6A7
    new = 0xB0B1_B2B3_B4B5_B6B7
    shares = 0xC0C1C2C3 & 0x7FFF_FFFF
    price = 0xD0D1D2D3 & 0x7FFF_FFFF
    await push(dut, ig.order_replace(LOCATE, orig, new, shares, price))
    await ClockCycles(dut.clk, 4)

    e = col.events[0]
    assert e["order_ref"] == orig, f"orig_ref 0x{e['order_ref']:016X}"
    assert e["new_order_ref"] == new, f"new_ref 0x{e['new_order_ref']:016X}"
    assert e["qty"] == shares, f"shares 0x{e['qty']:08X} != 0x{shares:08X}"
    assert e["price"] == price, f"price 0x{e['price']:08X} != 0x{price:08X}"


# =============================================================================
# 3. Length mismatches are counted and dropped
# =============================================================================
@cocotb.test()
async def test_length_mismatch_counted_and_dropped(dut):
    """⚠️ A declared length that disagrees with the type's fixed length.

    ``itch_pkg::itch_msg_len()`` exists so the decoder can cross-check the
    MoldUDP64 block length against the type's fixed length, and the package says
    so explicitly:

        "The decoder MUST cross-check the MoldUDP64 block length against this
         table and count a mismatch as a decode error rather than proceeding."

    Proceeding anyway is the worst option: the fields land at the right offsets
    for a message that is not this length, so the decode SUCCEEDS and produces
    a plausible order that never existed.

    The test asserts on the COUNTER, not on absence of a crash
    (05-verification §6, CLAUDE.md §5.7).
    """
    col = await setup(dut)
    before = await stat(dut, "len_err")

    good = ig.add_order(LOCATE, 0x1, ig.SIDE_BUY, 100, SYM, ig.px("100.00"))
    for delta in (+1, -1, +8, -8):
        col.clear()
        await push(dut, good, length=len(good) + delta)
        await ClockCycles(dut.clk, 4)
        assert len(col.events) == 0, (
            f"a message with length {len(good)+delta} (type 'A' is "
            f"{ig.MSG_LEN[ig.MSG_ADD_ORDER]}) produced a book event. It must be "
            f"dropped: the fields cannot be trusted."
        )

    after = await stat(dut, "len_err")
    assert after - before == 4, (
        f"len_err counter went {before} -> {after}; expected +4. "
        f"A dropped message that is not counted is a silent failure — "
        f"CLAUDE.md §5.7."
    )


@cocotb.test()
async def test_length_mismatch_does_not_wedge_the_decoder(dut):
    """A bad length must not corrupt state for the NEXT message.

    ⚠️ The decoder is a one-cycle combinational extraction with registered
    outputs; it has no parsing state to corrupt, and that is the design's whole
    defence here. This test proves the property rather than assuming it, because
    the day someone adds a state machine for a new message type is the day it
    stops being true.
    """
    col = await setup(dut)
    good = ig.add_order(LOCATE, 0x99, ig.SIDE_BUY, 100, SYM, ig.px("100.00"))

    await push(dut, good, length=len(good) + 3)     # bad
    await push(dut, good)                            # good, immediately after
    await ClockCycles(dut.clk, 4)

    assert len(col.events) == 1, (
        f"expected the good message to decode after a bad one; got "
        f"{len(col.events)} events"
    )
    assert col.events[0]["order_ref"] == 0x99


# =============================================================================
# 4. Unknown types are counted, not fatal
# =============================================================================
@cocotb.test()
async def test_unknown_type_counted_not_fatal(dut):
    """⚠️ An unknown message type is NOT an error.

    ``itch_pkg.sv``, on ``itch_msg_len()``:

        "An unknown type is NOT an error — Nasdaq adds message types — but it
         must be counted and skipped by its declared length, never by a guess."

    A decoder that treats an unknown type as fatal stops working on the day the
    venue ships a new message. One that guesses at the length desynchronises the
    whole packet. The correct behaviour is: emit no book event, increment a
    counter, continue.
    """
    col = await setup(dut)
    before = await stat(dut, "unknown_type")

    for code in (b"z", b"\x00", b"\xff", b"G", b"T"):
        await push(dut, code + b"\x00" * 19, length=20)
    await ClockCycles(dut.clk, 4)

    assert len(col.events) == 0, (
        f"an unknown type produced {len(col.events)} book event(s). An unknown "
        f"type must produce NONE — the fields are meaningless."
    )
    after = await stat(dut, "unknown_type")
    assert after - before == 5, (
        f"unknown_type counter went {before} -> {after}; expected +5"
    )


@cocotb.test()
async def test_known_non_book_types_are_not_unknown(dut):
    """'S', 'H', 'Y' are known but do not mutate the book.

    They must NOT be counted as unknown, and they must NOT produce a
    ``BOOK_ADD``-family event. They drive the venue-state side channel instead
    (``rtl/feed/venue_state.sv``), which feeds the risk gate's
    ``RISK_SYM_HALTED`` / ``RISK_SSR`` / ``RISK_SESSION_CLOSED`` checks.

    ⚠️ Counting them as unknown would bury a real unknown-type event in noise —
    ``itch_pkg::is_book_msg()`` is the distinction being tested.
    """
    col = await setup(dut)
    before_unknown = await stat(dut, "unknown_type")

    await push(dut, ig.system_event(ig.SYSEV_START_MARKET))
    await push(dut, ig.trading_action(LOCATE, SYM, ig.TRADE_ACT_HALTED))
    await push(dut, ig.reg_sho(LOCATE, SYM, ig.SHO_RESTRICTED))
    await ClockCycles(dut.clk, 4)

    after_unknown = await stat(dut, "unknown_type")
    assert after_unknown == before_unknown, (
        "a KNOWN non-book message type was counted as unknown. "
        "itch_pkg::is_book_msg() distinguishes them."
    )
    book_ops = [e for e in col.events
                if e["op"] in (BOOK_ADD, BOOK_EXECUTE, BOOK_CANCEL,
                               BOOK_DELETE, BOOK_REPLACE)]
    assert not book_ops, (
        f"a non-book message produced {len(book_ops)} book-mutating event(s): "
        f"{book_ops}"
    )


# =============================================================================
# 5. Big-endian conversion
# =============================================================================
@cocotb.test()
async def test_big_endian_conversion(dut):
    """⚠️ ITCH is big-endian on the wire; the fabric is little-endian.

    ``trading_pkg`` provides ``bswap16/32/64`` and the rule is: convert ONCE, at
    the boundary. The boundary is this decoder.

    Every value below is chosen so a byte-swap produces an obviously different
    number. A test using 0x00000064 (100) would pass with the bytes reversed on
    a 4-byte field read as 0x64000000 only by accident of magnitude — these
    cannot.

    From the divergence triage table (05-verification §4): "Values are
    byte-swapped or absurdly large -> endianness."
    """
    col = await setup(dut)

    ref = 0x0102_0304_0506_0708      # reversed: 0x0807060504030201
    shares = 0x0001_0002              # reversed: 0x02000100
    price = 0x0003_0004               # reversed: 0x04000300
    locate = 0x0102                   # reversed: 0x0201
    ts = 0x0102_0304_0506             # 6 bytes

    await push(dut, ig.add_order(locate, ref, ig.SIDE_BUY, shares, SYM, price, ts))
    await ClockCycles(dut.clk, 4)

    e = col.events[0]

    def swapped(v: int, nbytes: int) -> int:
        return int.from_bytes(v.to_bytes(nbytes, "big"), "little")

    assert e["order_ref"] == ref, (
        f"order_ref 0x{e['order_ref']:016X} != 0x{ref:016X}"
        + ("  <-- BYTE-SWAPPED (bswap64 missing or applied twice)"
           if e["order_ref"] == swapped(ref, 8) else "")
    )
    assert e["qty"] == shares, (
        f"shares 0x{e['qty']:08X} != 0x{shares:08X}"
        + ("  <-- BYTE-SWAPPED (bswap32)"
           if e["qty"] == swapped(shares, 4) else "")
    )
    assert e["price"] == price, (
        f"price 0x{e['price']:08X} != 0x{price:08X}"
        + ("  <-- BYTE-SWAPPED (bswap32)"
           if e["price"] == swapped(price, 4) else "")
    )
    assert e["locate"] == locate, (
        f"locate 0x{e['locate']:04X} != 0x{locate:04X}"
        + ("  <-- BYTE-SWAPPED (bswap16)"
           if e["locate"] == swapped(locate, 2) else "")
    )
    assert e["exch_ts"] == ts, (
        f"timestamp 0x{e['exch_ts']:012X} != 0x{ts:012X}. The 6-byte timestamp "
        f"has no bswap helper in trading_pkg — check it is assembled MSB-first "
        f"by hand and not run through bswap64 with two junk bytes."
    )


@cocotb.test()
async def test_price_scaling_is_itch_native(dut):
    """Prices pass through as ITCH-native scaled integers — no conversion.

    ``trading_pkg`` says it plainly: "Prices are ITCH-native scaled integers
    (4 implied decimals). Never convert." A decoder that rescales introduces a
    divide (forbidden — CLAUDE.md §5.3) and a rounding error, and the risk
    gate's sub-penny check (``is_whole_penny``) assumes the native scale.
    """
    col = await setup(dut)
    cases = [("0.0001", 1), ("1.00", 10_000), ("187.50", 1_875_000),
             ("429496.7295", 4_294_967_295)]
    for dollars, want in cases:
        assert ig.px(dollars) == want, f"the GENERATOR is wrong for {dollars}"
        await push(dut, ig.add_order(LOCATE, 0x7, ig.SIDE_BUY, 1, SYM, want))
    await ClockCycles(dut.clk, 4)

    got = [e["price"] for e in col.events]
    want_all = [w for _, w in cases]
    assert got == want_all, (
        f"prices {got} != {want_all}. A uniform factor of 10^k is an "
        f"implied-decimal scaling bug."
    )


# =============================================================================
# 6. Randomized sweep
# =============================================================================
@cocotb.test()
async def test_random_message_mix(dut):
    """Randomized mix of every supported type, cross-checked field by field.

    ⚠️ The seed is logged on the first line. 05-verification §6: "A random
    failure you cannot reproduce is not a finding, it is a rumour." Reproduce
    with ``make -C scripts sim-feed SEED=<n>``; freeze any failing seed into a
    directed test so the suite grows monotonically.
    """
    seed = int(os.environ.get("SEED", random.randrange(2**32)))
    dut._log.info(f"SEED={seed}")
    rng = random.Random(seed)

    col = await setup(dut)
    expected: list[tuple[int, dict]] = []

    for _ in range(200):
        kind = rng.choice(["A", "F", "E", "C", "X", "D", "U"])
        ref = rng.getrandbits(64)
        qty = rng.randrange(1, 1_000_000)
        price = rng.randrange(1, 4_294_967_295)
        side = rng.choice([ig.SIDE_BUY, ig.SIDE_SELL])

        if kind == "A":
            msg, exp = ig.add_order(LOCATE, ref, side, qty, SYM, price), \
                (BOOK_ADD, {"order_ref": ref, "qty": qty, "price": price})
        elif kind == "F":
            msg, exp = ig.add_order_mpid(LOCATE, ref, side, qty, SYM, price), \
                (BOOK_ADD, {"order_ref": ref, "qty": qty, "price": price})
        elif kind == "E":
            msg, exp = ig.order_executed(LOCATE, ref, qty, rng.getrandbits(64)), \
                (BOOK_EXECUTE, {"order_ref": ref, "qty": qty})
        elif kind == "C":
            msg, exp = ig.order_executed_with_price(
                LOCATE, ref, qty, rng.getrandbits(64), b"Y", price), \
                (BOOK_EXECUTE, {"order_ref": ref, "qty": qty})
        elif kind == "X":
            msg, exp = ig.order_cancel(LOCATE, ref, qty), \
                (BOOK_CANCEL, {"order_ref": ref, "qty": qty})
        elif kind == "D":
            msg, exp = ig.order_delete(LOCATE, ref), \
                (BOOK_DELETE, {"order_ref": ref})
        else:
            new_ref = rng.getrandbits(64)
            msg, exp = ig.order_replace(LOCATE, ref, new_ref, qty, price), \
                (BOOK_REPLACE, {"order_ref": ref, "new_order_ref": new_ref,
                                "qty": qty, "price": price})

        await push(dut, msg)
        expected.append(exp)

    await ClockCycles(dut.clk, 8)

    assert len(col.events) == len(expected), (
        f"SEED={seed}: emitted {len(col.events)} events for {len(expected)} "
        f"messages"
    )
    for i, (got, (want_op, want_fields)) in enumerate(zip(col.events, expected)):
        assert got["op"] == want_op, (
            f"SEED={seed} msg[{i}]: op {got['op']} != {want_op}"
        )
        for k, v in want_fields.items():
            assert got[k] == v, (
                f"SEED={seed} msg[{i}] op={want_op}: {k} = 0x{got[k]:X}, "
                f"want 0x{v:X}"
            )
