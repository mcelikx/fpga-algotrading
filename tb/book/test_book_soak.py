"""Order-book soak — RTL vs golden model, top-of-book compared after EVERY message.

INVARIANT PROVEN
    For millions of randomized-but-legal ITCH sequences — including a deliberately
    adversarial mix of the cases that break order books — the hardware book's
    top-of-book is IDENTICAL to the golden software model's after every single
    message: bid/ask price, bid/ask quantity, validity, crossed, and stale.

WHY IT MATTERS
    This is the single highest-value test in the project, and both manuals say so
    outright (manuals/01-fpga-design/05-verification-and-simulation.md §4: "This is
    the core verification technique for this project. Everything else is supporting
    infrastructure."; manuals/06-operations/04-testing-strategy.md).

    A feed handler plus an order book is a large, stateful, order-dependent
    transform.  You cannot unit-test your way to confidence in it, because the bugs
    do not live in single messages — they live in SEQUENCES.  An execution against
    an order added forty million messages earlier.  A cross that empties one side.
    A replace of the current best.  A symbol that halts and reopens.

    And the failure is silent.  A book that drifts does not crash; it keeps
    producing plausible prices that are simply wrong, and the strategy keeps
    trading against them at line rate until a human notices the P&L.  Every order
    this system will ever send is priced off this block.  If it diverges by one
    share on one level, every downstream risk check still passes — they are all
    checking the wrong number.

    Top-of-book is compared after EVERY message, not every N and not at the end,
    because the whole diagnostic value is in knowing WHICH message broke it.

THE FIVE RULES (05-verification §4), and how this file implements them
    1. The oracle implements exactly the same simplifications as the RTL —
       BOOK_LEVELS=2048, N_ACTIVE=256, the same active-locate filter — via the
       shared ``BookConfig``.  Divergence caused by an intentional simplification
       is indistinguishable from a bug.
    2. Canonical, integer-only, one-record-per-line serialization
       (``TopOfBook.canonical()``), so comparison is a byte compare.  The trace
       HASH is what gets committed, never the multi-GB trace.
    3. Stop at the FIRST divergence and print context — the last 8 messages for
       that locate (``GoldenBook.divergence_report``).
    4. Replay byte-for-byte; do not clean the stream.
    5. The oracle is reviewed like production code and written from the spec.
       This file does NOT reimplement it — it imports ``tb/common/golden_book.py``.

DUT
    rtl/book/book_engine.sv — NOT PRESENT at the time of writing (rtl/book/ does
    not exist; it is listed in rtl/filelist.f but unwritten).  Interface taken from
    fpga_top.sv's ``u_book`` instantiation: clk, rst, s_evt (book_evt_t),
    s_evt_valid, m_top (book_top_t), m_top_valid, stat[16].

    # TODO(verify): tb/filelist.f plans a flattening wrapper
    # tb/book/tb_book_engine_top.sv exposing flat port names (packed structs are
    # awkward through the Verilator VPI). That wrapper is NOT written here (it is
    # a .sv file owned by the scaffolding filelist). This file assumes flat names
    # dut.s_evt_<field> / dut.m_top_<field> and falls back to packed-struct
    # slicing if the wrapper is absent. Confirm both against the wrapper when it
    # and book_engine.sv exist.

STIMULUS/ORACLE INDEPENDENCE
    The generator emits, for each event, BOTH the raw ITCH bytes and the decoded
    ``book_evt_t`` field set.  The oracle parses the bytes; the DUT is driven from
    the fields.  Neither is derived from the other, so a mistake in one does not
    cancel a mistake in the other (05-verification §2: "the stimulus builder and
    the oracle must be able to disagree").

RUNNING
    Per-push:   MSGS=200000 python test_book_soak.py
    Nightly:    MSGS=5000000 SEED=random   (the `random-soak` CI job,
                manuals/01-fpga-design/05-verification-and-simulation.md §7)
    Reproduce:  SEED=<n> from the failure's first line.

    ``python test_book_soak.py --selftest`` runs the generator and oracle WITHOUT
    a simulator and asserts the adversarial mix really is adversarial.  That check
    is meaningful today, before book_engine.sv exists.
"""

from __future__ import annotations

import hashlib
import os
import pathlib
import sys
from dataclasses import dataclass, field

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "common"))

from tb_util import (  # noqa: E402
    BOOK_LEVELS,
    BUDGET,
    CLK_NS,
    BookOp,
    CoverageDB,
    LatencySamples,
    Scoreboard,
    Side,
    rtl_exists,
    seed_note,
    seeded_rng,
    REPO_ROOT,
    sim_sources,
)
import itch_gen as ig  # noqa: E402
from golden_book import BookConfig, GoldenBook  # noqa: E402

# The active universe. Small enough that hard cases collide constantly, large
# enough that cross-symbol interference would show up.
N_LOCATES = int(os.environ.get("LOCATES", "8"))
LOCATES = list(range(1, N_LOCATES + 1))
STOCKS = {loc: f"SYM{loc:04d}"[:8] for loc in LOCATES}

# Price grid, in ITCH scaled integers (4 implied decimals). NEVER a float.
TICK = 100                    # $0.01
BASE_PX = 1_000_000           # $100.0000

MAX_REF = (1 << 64) - 1


# =============================================================================
# The event the generator produces: raw bytes for the oracle, fields for the DUT
# =============================================================================

@dataclass
class Stim:
    """One stimulus item.

    ``msg`` feeds the ORACLE.  ``evt`` feeds the DUT.  They are produced from the
    same intent but by independent code paths on purpose.
    """

    msg: bytes                       # raw ITCH message (oracle input)
    evt: dict                        # book_evt_t field values (DUT input)
    locate: int
    tag: str                         # which adversarial case produced this


def _evt(op: int, locate: int, *, side: int = 0, price: int = 0, qty: int = 0,
         ref: int = 0, new_ref: int = 0, printable: int = 1) -> dict:
    """Assemble a ``book_evt_t`` field set."""
    return {
        "op": int(op),
        "sym": locate % 256,          # active-set index; see TODO below
        "locate": locate,
        "side": int(side),
        "price": int(price),
        "qty": int(qty),
        "order_ref": int(ref),
        "new_order_ref": int(new_ref),
        "exch_ts": 0,
        "printable": int(printable),
    }
    # TODO(verify): the locate -> active-index map is owned by symbol_filter.sv
    # (rtl/feed/symbol_filter.sv, cfg-loaded). `locate % 256` is a stand-in that
    # is injective over LOCATES; when the integration harness loads a real filter
    # table this must use the same mapping or the DUT and oracle will key their
    # books differently.


# =============================================================================
# Generator: randomized but LEGAL, with an adversarial mode
# =============================================================================

@dataclass
class LiveOrder:
    ref: int
    locate: int
    side: int          # Side.BUY / Side.SELL
    price: int
    shares: int


class BookStimGenerator:
    """Emits ITCH sequences Nasdaq could actually send.

    LEGALITY IS ENFORCED BY CONSTRUCTION: the generator tracks every live order
    reference, so it can only execute/cancel/delete/replace references that
    exist, and never for more shares than are resting.  An illegal stimulus would
    make a divergence meaningless — the DUT and the oracle would be entitled to
    disagree about undefined behaviour.

    ⚠️ The ADVERSARIAL weighting is what makes this more than a smoke test.  The
    hard cases (best-level delete, execute-to-zero, replace-of-best, depth
    overflow, hash collisions, gaps, back-to-back same-level updates) are the
    ones that break real order books, and a uniform random mix produces them too
    rarely to matter.  Every one is tracked in a CoverageDB and asserted to have
    actually fired — an adversarial generator that never generated the
    adversarial case is the most dangerous kind of green test.
    """

    def __init__(self, rng, adversarial: bool = True):
        self.rng = rng
        self.adversarial = adversarial
        self.live: dict[int, LiveOrder] = {}
        self.by_locate: dict[int, set[int]] = {loc: set() for loc in LOCATES}
        self.next_ref = 1
        self.seq = 1
        self.cov = CoverageDB("book_soak.adversarial")
        self.mid: dict[int, int] = {loc: BASE_PX for loc in LOCATES}
        #: (locate, side) currently being drained to empty, or None. See the
        #: DRAIN MODE comment in next().
        self.drain: tuple[int, int] | None = None
        # Refs deliberately crafted to land in the same 4-way hash set.
        # ORDER_MAP_ENTRIES=65536, ORDER_MAP_WAYS=4 -> 16384 sets if the index is
        # the low bits of the reference. Stepping by 16384 collides by
        # construction under that (documented, likely) indexing.
        self.collision_stride = 1 << 14

    # -- helpers ---------------------------------------------------------
    def _new_ref(self, collide: bool = False) -> int:
        if collide and self.live:
            base = self.rng.choice(list(self.live))
            r = (base + self.collision_stride) & MAX_REF
            while r in self.live or r == 0:
                r = (r + self.collision_stride) & MAX_REF
            return r
        self.next_ref += self.rng.randrange(1, 4)
        return self.next_ref

    def _pick_live(self, locate: int | None = None, best_only: bool = False):
        pool = (self.by_locate[locate] if locate is not None
                else set().union(*self.by_locate.values()) if self.live else set())
        if not pool:
            return None
        if best_only:
            loc = locate if locate is not None else self.rng.choice(LOCATES)
            best = self._best_orders(loc)
            if best:
                return self.rng.choice(best)
        return self.live[self.rng.choice(list(pool))]

    def _best_orders(self, locate: int) -> list[LiveOrder]:
        """Every order resting at the current best bid or best ask."""
        orders = [self.live[r] for r in self.by_locate[locate]]
        out = []
        for side in (Side.BUY, Side.SELL):
            same = [o for o in orders if o.side == side]
            if not same:
                continue
            best_px = max(o.price for o in same) if side == Side.BUY \
                else min(o.price for o in same)
            out.extend([o for o in same if o.price == best_px])
        return out

    def _price_for(self, locate: int, side: int, offset_ticks: int = 0) -> int:
        mid = self.mid[locate]
        sign = -1 if side == Side.BUY else 1
        px = mid + sign * (1 + self.rng.randrange(0, 6) + offset_ticks) * TICK
        return max(TICK, px)

    # -- message constructors (raw bytes + decoded fields) ----------------
    def _add(self, locate: int, side: int, price: int, shares: int,
             tag: str, ref: int | None = None) -> Stim:
        ref = self._new_ref() if ref is None else ref
        o = LiveOrder(ref, locate, side, price, shares)
        self.live[ref] = o
        self.by_locate[locate].add(ref)
        msg = ig.add_order(
            locate=locate, order_ref=ref,
            side=ig.SIDE_BUY if side == Side.BUY else ig.SIDE_SELL,
            shares=shares, sym=STOCKS[locate], price=price,
        )
        return Stim(msg, _evt(BookOp.ADD, locate, side=side, price=price,
                              qty=shares, ref=ref), locate, tag)

    def _delete(self, o: LiveOrder, tag: str) -> Stim:
        self.live.pop(o.ref, None)
        self.by_locate[o.locate].discard(o.ref)
        msg = ig.order_delete(locate=o.locate, order_ref=o.ref)
        return Stim(msg, _evt(BookOp.DELETE, o.locate, side=o.side,
                              price=o.price, qty=o.shares, ref=o.ref),
                    o.locate, tag)

    def _execute(self, o: LiveOrder, shares: int, tag: str) -> Stim:
        shares = max(1, min(shares, o.shares))
        o.shares -= shares
        if o.shares == 0:
            self.live.pop(o.ref, None)
            self.by_locate[o.locate].discard(o.ref)
        msg = ig.order_executed(locate=o.locate, order_ref=o.ref,
                                shares=shares, match_no=self.seq)
        return Stim(msg, _evt(BookOp.EXECUTE, o.locate, side=o.side,
                              price=o.price, qty=shares, ref=o.ref),
                    o.locate, tag)

    def _cancel(self, o: LiveOrder, shares: int, tag: str) -> Stim:
        shares = max(1, min(shares, o.shares))
        o.shares -= shares
        if o.shares == 0:
            self.live.pop(o.ref, None)
            self.by_locate[o.locate].discard(o.ref)
        msg = ig.order_cancel(locate=o.locate, order_ref=o.ref, shares=shares)
        return Stim(msg, _evt(BookOp.CANCEL, o.locate, side=o.side,
                              price=o.price, qty=shares, ref=o.ref),
                    o.locate, tag)

    def _replace(self, o: LiveOrder, new_px: int, new_qty: int, tag: str) -> Stim:
        """ITCH 'U': removes the ORIGINAL reference and creates a NEW one.

        ⚠️ itch_pkg.sv warns that a book treating this as an in-place modify
        leaks order references and drifts from the true book. The generator
        models it correctly so the DUT has no excuse.
        """
        new_ref = self._new_ref()
        self.live.pop(o.ref, None)
        self.by_locate[o.locate].discard(o.ref)
        self.live[new_ref] = LiveOrder(new_ref, o.locate, o.side, new_px, new_qty)
        self.by_locate[o.locate].add(new_ref)
        msg = ig.order_replace(locate=o.locate, orig_ref=o.ref, new_ref=new_ref,
                               shares=new_qty, price=new_px)
        return Stim(msg, _evt(BookOp.REPLACE, o.locate, side=o.side,
                              price=new_px, qty=new_qty, ref=o.ref,
                              new_ref=new_ref), o.locate, tag)

    # -- the mix ---------------------------------------------------------
    def next(self) -> Stim:
        """Produce the next stimulus, weighted toward the hard cases."""
        rng = self.rng
        self.seq += 1
        locate = rng.choice(LOCATES)
        n_live = len(self.by_locate[locate])

        # Keep every book populated enough that the hard cases are reachable.
        if n_live < 4:
            side = rng.choice([Side.BUY, Side.SELL])
            st = self._add(locate, side, self._price_for(locate, side),
                           rng.randrange(100, 1000), "seed_add")
            self.cov.hit(case="add")
            return st

        r = rng.random() if self.adversarial else 1.0

        # ---- adversarial cases, in descending order of value --------------
        if r < 0.14:                                   # best-level delete
            best = self._best_orders(locate)
            if best:
                o = rng.choice(best)
                self.cov.hit(case="best_level_delete")
                return self._delete(o, "best_level_delete")

        if r < 0.22:                                   # execute to EXACTLY zero
            o = self._pick_live(locate)
            if o:
                self.cov.hit(case="execute_to_zero")
                return self._execute(o, o.shares, "execute_to_zero")

        if r < 0.28:                                   # replace the current best
            best = self._best_orders(locate)
            if best:
                o = rng.choice(best)
                self.cov.hit(case="replace_of_best")
                return self._replace(o, self._price_for(locate, o.side),
                                     rng.randrange(100, 900), "replace_of_best")

        if r < 0.32:                                   # replace to the SAME price
            o = self._pick_live(locate)
            if o:
                self.cov.hit(case="replace_same_price")
                return self._replace(o, o.price, rng.randrange(100, 900),
                                     "replace_same_price")

        if r < 0.36:                                   # replace ACROSS the spread
            o = self._pick_live(locate)
            if o:
                opposite = self._price_for(
                    locate, Side.SELL if o.side == Side.BUY else Side.BUY)
                self.cov.hit(case="replace_across_spread")
                return self._replace(o, opposite, rng.randrange(100, 900),
                                     "replace_across_spread")

        if r < 0.42:                    # back-to-back updates to ONE level (RMW)
            o = self._pick_live(locate)
            if o:
                self.cov.hit(case="back_to_back_same_level")
                return self._execute(o, 1, "back_to_back_same_level")

        # ---- DRAIN MODE: deliberately empty one whole side, then refill ------
        # Emptying a side is a distinct hardware path (best goes invalid, the
        # opposite side becomes the only quote) and it is far too rare under any
        # per-message probability — the side has to be drained order by order.
        # So it is driven as an explicit mode rather than hoped for. The
        # generator's own coverage assertion caught this: with a per-message
        # probability the case fired < 50 times in 30k messages.
        if self.drain is not None:
            d_loc, d_side = self.drain
            same = [self.live[r_] for r_ in self.by_locate[d_loc]
                    if self.live[r_].side == d_side]
            if same:
                self.cov.hit(case="empty_a_side")
                return self._delete(rng.choice(same), "empty_a_side")
            self.drain = None          # side is now empty; resume normal traffic

        if r < 0.46:                                   # enter drain mode
            side = rng.choice([Side.BUY, Side.SELL])
            same = [self.live[r_] for r_ in self.by_locate[locate]
                    if self.live[r_].side == side]
            if same:
                self.drain = (locate, side)
                self.cov.hit(case="empty_a_side")
                return self._delete(rng.choice(same), "empty_a_side")

        if r < 0.50:                                   # DEPTH OVERFLOW
            side = rng.choice([Side.BUY, Side.SELL])
            deep = self._price_for(locate, side,
                                   offset_ticks=rng.randrange(BOOK_LEVELS,
                                                              BOOK_LEVELS * 3))
            self.cov.hit(case="depth_overflow")
            return self._add(locate, side, deep, rng.randrange(100, 900),
                             "depth_overflow")

        if r < 0.54:                                   # hash-colliding reference
            ref = self._new_ref(collide=True)
            side = rng.choice([Side.BUY, Side.SELL])
            self.cov.hit(case="hash_collision")
            return self._add(locate, side, self._price_for(locate, side),
                             rng.randrange(100, 900), "hash_collision", ref=ref)

        if r < 0.58:                                   # deliberate PRICE CROSSING
            # Add a bid above the current best ask (a real, if brief, state).
            asks = [self.live[r_] for r_ in self.by_locate[locate]
                    if self.live[r_].side == Side.SELL]
            if asks:
                cross_px = min(o.price for o in asks) + TICK
                self.cov.hit(case="price_crossing")
                return self._add(locate, Side.BUY, cross_px,
                                 rng.randrange(100, 900), "price_crossing")

        if r < 0.62:                                   # partial down to 1 share
            o = self._pick_live(locate)
            if o and o.shares > 1:
                self.cov.hit(case="partial_to_one")
                return self._execute(o, o.shares - 1, "partial_to_one")

        # ---- ordinary traffic --------------------------------------------
        pick = rng.random()
        if pick < 0.45:
            side = rng.choice([Side.BUY, Side.SELL])
            self.mid[locate] += rng.choice([-TICK, 0, TICK])
            self.cov.hit(case="add")
            return self._add(locate, side, self._price_for(locate, side),
                             rng.randrange(100, 2000), "add")
        o = self._pick_live(locate)
        if o is None:
            self.cov.hit(case="add")
            side = rng.choice([Side.BUY, Side.SELL])
            return self._add(locate, side, self._price_for(locate, side),
                             rng.randrange(100, 900), "add")
        if pick < 0.65:
            self.cov.hit(case="execute_partial")
            return self._execute(o, rng.randrange(1, max(2, o.shares)),
                                 "execute_partial")
        if pick < 0.82:
            self.cov.hit(case="cancel_partial")
            return self._cancel(o, rng.randrange(1, max(2, o.shares)),
                                "cancel_partial")
        self.cov.hit(case="delete")
        return self._delete(o, "delete")


#: Every adversarial case that MUST appear. Asserted, not hoped for.
REQUIRED_CASES = [
    "best_level_delete", "execute_to_zero", "replace_of_best",
    "replace_same_price", "replace_across_spread", "back_to_back_same_level",
    "empty_a_side", "depth_overflow", "hash_collision", "price_crossing",
    "partial_to_one", "add", "delete", "execute_partial", "cancel_partial",
]


# =============================================================================
# DUT driving (guarded — book_engine.sv does not exist yet)
# =============================================================================

BOOK_RTL = "rtl/book/book_engine.sv"
HAVE_BOOK_RTL = rtl_exists(BOOK_RTL)

EVT_FIELDS = ("op", "sym", "locate", "side", "price", "qty", "order_ref",
              "new_order_ref", "exch_ts", "printable")
TOP_FIELDS = ("sym", "bid_px", "bid_qty", "ask_px", "ask_qty", "last_px",
              "bid_valid", "ask_valid", "crossed", "stale", "top_changed")


def drive_evt(dut, evt: dict) -> None:
    """Present one ``book_evt_t`` on the DUT's slave port (flat wrapper names)."""
    for f in EVT_FIELDS:
        h = getattr(dut, f"s_evt_{f}", None)
        if h is not None:
            h.value = evt[f]
    dut.s_evt_valid.value = 1


def sample_top(dut) -> dict:
    """Read ``book_top_t`` from the DUT's master port."""
    out = {}
    for f in TOP_FIELDS:
        h = getattr(dut, f"m_top_{f}", None)
        out[f] = int(h.value) if h is not None else 0
    return out


def top_key(d: dict, locate: int) -> tuple:
    """Comparison key matching ``golden_book.TopOfBook.as_tuple()``."""
    return (
        locate,
        d["bid_px"] if d["bid_valid"] else 0,
        d["bid_qty"] if d["bid_valid"] else 0,
        d["ask_px"] if d["ask_valid"] else 0,
        d["ask_qty"] if d["ask_valid"] else 0,
        d["bid_valid"], d["ask_valid"], d["crossed"], d["stale"],
    )


# =============================================================================
# The cocotb soak
# =============================================================================

try:
    import cocotb
    from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge
    from tb_util import start_clock

    @cocotb.test(skip=not HAVE_BOOK_RTL)
    async def test_book_matches_golden_after_every_message(dut):
        """RTL top-of-book == golden top-of-book after EVERY message.

        Skipped LOUDLY (not vacuously passed) while rtl/book/book_engine.sv is
        unwritten — see ``test_generator_is_actually_adversarial`` below, which
        validates the stimulus half of this test today.
        """
        rng, seed = seeded_rng(dut, "book_soak")
        n_msgs = int(os.environ.get("MSGS", "200000"))
        dut._log.info(
            "book soak: MSGS=%d LOCATES=%d (nightly: MSGS=5000000 SEED=random)",
            n_msgs, N_LOCATES,
        )

        start_clock(dut, "clk", CLK_NS)
        dut.rst.value = 1
        dut.s_evt_valid.value = 0
        await ClockCycles(dut.clk, 8)
        dut.rst.value = 0
        await RisingEdge(dut.clk)

        # ── Host anchor: REQUIRED SETUP, not a convenience ────────────────────
        # price_levels is host-anchored and fails closed: "A symbol is DEAD
        # (every update rejected, stale asserted, re-anchor requested) until the
        # host writes its reference price through cfg_*" (price_levels.sv §"THE
        # WINDOW IS HOST-ANCHORED").  Without this loop the very first Add Order
        # is rejected and no top-of-book is ever produced -- which is the DUT
        # behaving exactly as specified, not a book defect.
        #
        # This test predates the host-anchored window; its own docstring says
        # rtl/book/ did not exist when it was written.
        #
        # ⚠️ The anchor is written at the price the generator centres on. If
        #    BASE_PX and this value ever drift apart, every symbol silently
        #    reports out-of-window instead of failing loudly -- check
        #    stat7 (cnt_oow_*) and stat10 (cnt_reanchor) before believing a
        #    clean run.
        dut.cfg_ref_valid.value = 0
        await RisingEdge(dut.clk)
        for _sym in range(N_LOCATES + 1):
            # Wait for READY FIRST, then pulse valid for exactly one cycle.
            # Asserting valid while a write is in flight makes book_engine drop
            # it -- and it asserts loudly rather than dropping quietly, which is
            # how this loop's first version was caught (book_engine.sv:1054).
            _guard = 0
            while True:
                await ReadOnly()
                if int(dut.cfg_ref_ready.value):
                    break
                await RisingEdge(dut.clk)
                _guard += 1
                assert _guard <= 64, (
                    f"cfg_ref_ready never asserted for sym={_sym} — the host "
                    f"anchor port is not accepting writes." + seed_note(seed)
                )
            await RisingEdge(dut.clk)
            dut.cfg_ref_sym.value = _sym
            dut.cfg_ref_px.value = BASE_PX
            dut.cfg_ref_valid.value = 1
            await RisingEdge(dut.clk)
            dut.cfg_ref_valid.value = 0
        await ClockCycles(dut.clk, 8)

        oracle = GoldenBook(BookConfig(active_locates=set(LOCATES)))
        gen = BookStimGenerator(rng, adversarial=True)
        board = Scoreboard("book_soak", history=8, seed=seed)
        lat = LatencySamples("book_update")

        seq = 0
        for i in range(n_msgs):
            stim = gen.next()
            seq += 1

            # --- oracle: parses the RAW BYTES, independently of the DUT input --
            oracle.apply(stim.msg, seq=seq)
            board.note(f"seq={seq} loc={stim.locate} {stim.tag} "
                       f"{stim.msg[:1]!r} ref={stim.evt['order_ref']}")

            # --- DUT: driven from the DECODED FIELDS ---------------------------
            drive_evt(dut, stim.evt)
            await RisingEdge(dut.clk)
            dut.s_evt_valid.value = 0

            cycles = 0
            while True:
                cycles += 1
                await ReadOnly()
                if int(dut.m_top_valid.value):
                    got = sample_top(dut)
                    break
                await RisingEdge(dut.clk)
                assert cycles <= 64, (
                    f"book_engine produced no top-of-book within 64 cycles for "
                    f"seq={seq} ({stim.tag}) — the new-best search did not "
                    f"terminate." + seed_note(seed)
                )
            lat.add(cycles)
            await RisingEdge(dut.clk)

            expected = oracle.top_of_book(stim.locate)
            actual = top_key(got, stim.locate)
            if actual != expected.as_tuple():
                # Rebuild a TopOfBook-shaped view of the DUT for the report.
                from golden_book import TopOfBook
                dut_top = TopOfBook(
                    locate=stim.locate, bid_px=got["bid_px"],
                    bid_qty=got["bid_qty"], ask_px=got["ask_px"],
                    ask_qty=got["ask_qty"], last_px=got["last_px"],
                    bid_valid=bool(got["bid_valid"]),
                    ask_valid=bool(got["ask_valid"]),
                    crossed=bool(got["crossed"]), stale=bool(got["stale"]),
                )
                raise AssertionError(
                    oracle.divergence_report(stim.locate, expected, dut_top, seq)
                    + f"\n  message {i}/{n_msgs}, adversarial case: {stim.tag}"
                    + seed_note(seed)
                )
            board.n_checked += 1

            # Continuous invariants -------------------------------------------
            assert got["bid_qty"] >= 0 and got["ask_qty"] >= 0, (
                f"NEGATIVE QUANTITY at seq={seq}: bid_qty={got['bid_qty']} "
                f"ask_qty={got['ask_qty']}. Level quantity must saturate at "
                f"zero and count, never wrap." + seed_note(seed)
            )
            if got["crossed"]:
                assert not (got["bid_valid"] and got["ask_valid"]
                            and got["bid_px"] < got["ask_px"]), (
                    f"crossed flag set on an uncrossed book at seq={seq}"
                    + seed_note(seed)
                )

            if (i + 1) % 20000 == 0:
                dut._log.info("  %d/%d messages, %s", i + 1, n_msgs, lat.summary())

        # --- adversarial coverage: the generator really did the hard things ---
        gen.cov.assert_all_hit([{"case": c} for c in REQUIRED_CASES], min_hits=50)
        dut._log.info("adversarial coverage: %s", gen.cov.summary())
        for case in REQUIRED_CASES:
            dut._log.info("    %-26s %d", case, gen.cov.count(case=case))

        # --- latency: the one documented variable-latency stage ---------------
        dut._log.info("book update latency: %s", lat.summary())
        BUDGET.assert_bounded(lat.max, "book_update", seed)

        board.assert_checked(n_msgs)
        dut._log.info("oracle stats: %s", oracle.stats())
        oracle.verify_consistency()

    @cocotb.test(skip=not HAVE_BOOK_RTL)
    async def test_trace_hash_is_stable_for_a_fixed_seed(dut):
        """A fixed seed produces a byte-identical canonical trace, run to run.

        05-verification §4 rule 2 and §7.5: commit the HASH of the golden trace,
        not the trace.  A suite whose results change between runs is not a
        regression suite.  This also gives a cheap way to bisect a divergence:
        the hash changes at exactly the commit that changed book behaviour.
        """
        rng, seed = seeded_rng(dut, "book_soak.trace")
        n = int(os.environ.get("TRACE_MSGS", "20000"))
        oracle = GoldenBook(BookConfig(active_locates=set(LOCATES)))
        gen = BookStimGenerator(rng, adversarial=True)
        h = hashlib.sha256()
        for i in range(n):
            stim = gen.next()
            oracle.apply(stim.msg, seq=i + 1)
            h.update(oracle.top_of_book(stim.locate).canonical().encode())
        digest = h.hexdigest()
        dut._log.info("canonical trace SHA-256 (%d msgs, seed %d): %s",
                      n, seed, digest)
        # TODO(verify): freeze this digest into tb/fixtures/golden/ once
        # book_engine.sv exists and the DUT and oracle agree, then assert it here
        # so a change in book semantics cannot land unnoticed.

except ImportError:  # pragma: no cover - running outside cocotb (selftest mode)
    cocotb = None


# =============================================================================
# Simulator-free self-test of the stimulus half
# =============================================================================

def selftest(msgs: int = 50_000, seed_val: int | None = None) -> None:
    """Prove the generator is legal AND genuinely adversarial, with no simulator.

    This runs today, before rtl/book/book_engine.sv exists.  It is not a
    substitute for the DUT comparison — it is insurance that when the DUT
    arrives, the stimulus driving it is already known to hit the hard cases.
    """
    import random

    seed_val = seed_val if seed_val is not None else 0xC0FFEE
    print(f"SEED={seed_val}  (reproduce with SEED={seed_val})")
    rng = random.Random(seed_val)
    oracle = GoldenBook(BookConfig(active_locates=set(LOCATES)))
    gen = BookStimGenerator(rng, adversarial=True)

    for i in range(msgs):
        stim = gen.next()
        oracle.apply(stim.msg, seq=i + 1)
        top = oracle.top_of_book(stim.locate)
        assert top.bid_qty >= 0 and top.ask_qty >= 0, (
            f"oracle produced a negative quantity at message {i}"
        )
    oracle.verify_consistency()

    missing = [c for c in REQUIRED_CASES if gen.cov.count(case=c) < 50]
    assert not missing, (
        f"GENERATOR IS NOT ADVERSARIAL: these cases fired fewer than 50 times "
        f"in {msgs} messages: {missing}. An adversarial generator that never "
        f"generates the adversarial case is the most dangerous kind of green "
        f"test."
    )
    print(f"generator selftest OK over {msgs} messages")
    for case in REQUIRED_CASES:
        print(f"  {case:26s} {gen.cov.count(case=case):8d}")
    print(f"oracle stats: {oracle.stats()}")


if __name__ == "__main__":  # pragma: no cover
    if "--selftest" in sys.argv or not HAVE_BOOK_RTL:
        if not HAVE_BOOK_RTL:
            print(f"NOTE: {BOOK_RTL} does not exist yet — running generator "
                  f"selftest only. The DUT comparison is the point of this file "
                  f"and will run as soon as book_engine.sv lands.")
        selftest(int(os.environ.get("MSGS", "50000")),
                 int(os.environ["SEED"], 0) if os.environ.get("SEED") else None)
        sys.exit(0)

    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        from cocotb.runner import get_runner

    runner = get_runner(os.environ.get("SIM", "verilator"))
    runner.build(
        verilog_sources=sim_sources(
            "rtl/book/book_pkg.sv", "rtl/book/order_id_map.sv",
            "rtl/book/price_levels.sv", "rtl/book/top_of_book.sv",
            "rtl/book/book_engine.sv", "tb/book/tb_book_engine_top.sv",
        ),
        hdl_toplevel="tb_book_engine_top",
        # --timing: the RTL uses timing controls (SVA, clocking); without it
        #   Verilator refuses with NEEDTIMINGOPT.
        # --assert: the point of this test is that the DUT's own assertions fire
        #   on a divergence, not just that the Python comparison notices.
        # -y rtl/common: top_of_book instantiates prio_encoder, which is not in
        #   the source list above. Resolve it by name rather than by growing the
        #   list, so a new submodule does not silently break the build.
        build_args=[
            "-Wno-fatal", "--timing", "--assert",
            "-y", str(REPO_ROOT / "rtl" / "common"),
            "-y", str(REPO_ROOT / "rtl" / "pkg"),
            "+libext+.sv",
        ],
        always=True,
    )
    runner.test(hdl_toplevel="tb_book_engine_top", test_module="test_book_soak")
