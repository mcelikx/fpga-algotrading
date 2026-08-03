"""⚠️ Gray-coded async FIFO — every CDC in this design crosses through this module.

INVARIANT PROVEN
    ``async_fifo`` is a lossless, duplication-free, order-preserving channel
    between two unrelated clocks:

      * **No loss, no duplication, no reordering** at write:read frequency
        ratios from 1:10 to 10:1, **including nearly-equal frequencies**
        (6400 ps vs 6402 ps, and 100 MHz vs 100.1 MHz), with the clock PHASE
        randomized per run, not just the ratio.
      * ``wr_full`` is never wrong in the direction that loses data: no write is
        ever accepted into a FIFO that already holds ``DEPTH`` entries.
      * ``rd_empty`` is never wrong in the direction that invents data: no read
        ever returns a word that was not written, or a word twice.
      * ``wr_almost_full`` asserts at exactly ``ALMOST_FULL_LEVEL`` and leaves
        exactly the documented headroom before ``wr_full``.
      * ``wr_high_water`` equals the true maximum occupancy — exact when the
        pointers are quiescent, and bounded-pessimistic (never optimistic) when
        they are not.
      * Reset from both domains, released at arbitrary and STAGGERED phase
        (which is what one ``reset_sync`` per domain actually produces), leaves
        an empty FIFO with no survivor from before the reset.
      * Burst-then-drain and drain-faster-than-fill both hold all of the above.

WHY IT MATTERS
    Manual 00.04 §1 rule 2: CDC exists in exactly three places in this design —
    MAC RX -> core, core -> MAC TX, PCIe -> core.  All three are this module.
    Market data in, orders out.  There is no other crossing.

    The RTL header (rtl/common/async_fifo.sv:35) is unusually blunt about why
    this file has to exist: the manual's own instruction is **"do not write your
    own"** async FIFO, because "the pointer arithmetic and the full/empty edge
    cases are subtle and the failure mode is SILENT CORRUPTION."  This project
    wrote one anyway, for vendor neutrality and for the high-water telemetry, and
    accepted an explicit obligation in exchange (line 43):

        "It MUST be simulated at several clock ratios INCLUDING nearly-equal
         frequencies (the hardest case) with randomized phase, per manual §6.2.
         ... If any of that is not done, use xpm_fifo_async instead."

    This file is that obligation.  Until it has been RUN, the module is being
    used outside the terms under which it was permitted to exist.

    Why nearly-equal frequencies are the hard case: at 10:1 the pointer
    synchronizers see a stable value for many destination cycles and any
    reasonable implementation works.  At 1.0002:1 the two clocks slide slowly
    through every phase relationship, so a pointer comparison that is only
    correct for most alignments will be wrong for a few microseconds out of
    every few milliseconds — which is the exact shape of "corrupts one order in
    ten million on a hot afternoon".

    ⚠️ WHAT THIS FILE CANNOT PROVE.  RTL simulation samples cleanly on every
    edge, forever; it has no notion of setup/hold across domains, so it cannot
    see metastability at all (tb/README.md §5, manual 00.04 §6).  The safety
    argument for this construction is that the pointers are GRAY CODED, so a
    mis-sampled pointer is the old value or the new one and never a third.
    Simulation can check that the code really is gray (``test_pointers_are_gray``)
    but not that the sampling is safe.  ``report_cdc`` (merge gate 5) and the
    ASYNC_REG placement are the other half, and they are not optional.

DUT
    rtl/common/async_fifo.sv (instantiates cdc_sync_bit).  Parameters ``W``,
    ``DEPTH`` (power of two, >= 4), ``SYNC_STAGES`` (>= 2),
    ``ALMOST_FULL_LEVEL`` (default ``DEPTH-2``).

TESTBENCH TIMING DISCIPLINE
    Both domains are driven on the FALLING edge of their own clock.  Every
    status flag this testbench conditions on (``wr_full``, ``rd_empty``,
    ``rd_valid``) is a registered output, so it is constant for the whole period
    between two rising edges; sampling and driving at the midpoint is therefore
    race-free and, critically, means the testbench NEVER presents ``wr_en``
    while ``wr_full`` — which would trip the RTL's own assertion at
    rtl/common/async_fifo.sv:317 and mask a real failure behind a testbench bug.

RUNNING
    TOPLEVEL=async_fifo, or ``python test_async_fifo.py``.
    Knobs: ``WORDS`` (per-ratio word count), ``SEED``, ``PROBE_ILLEGAL=1``.
"""

from __future__ import annotations

import os
import pathlib
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tb_util import seed_note, seeded_rng, sim_sources  # noqa: E402

BASE_PS = 6400          # core_clk 156.25 MHz
MAC_PS = 6400           # 10GbE 64-bit datapath is the same rate
PCIE_PS = 4000          # 250 MHz

WORDS = int(os.environ.get("WORDS", "300"))

# (label, wr_period_ps, rd_period_ps).  The ratio in the label is
# f_write : f_read, so "1:10" means the reader is ten times faster.
#
# The three near-equal entries are the ones manual 00.04 §6.2 singles out.
# 6400/6402 slides two picoseconds of phase per cycle, so 3200 write cycles
# walk the two clocks through one complete revolution of phase.
# (cocotb 2.0 requires an EVEN clock period in the simulator's time unit, so
#  6401 is not expressible; 6402 is the closest near-equal pair that is.)
RATIOS: list[tuple[str, int, int]] = [
    ("1:10 read fast", BASE_PS * 10, BASE_PS),
    ("1:8  read fast", BASE_PS * 8, BASE_PS),
    ("1:5  read fast", BASE_PS * 5, BASE_PS),
    ("1:4  read fast", BASE_PS * 4, BASE_PS),
    ("1:3  read fast", BASE_PS * 3, BASE_PS),
    ("1:2  read fast", BASE_PS * 2, BASE_PS),
    ("1:1  identical", BASE_PS, BASE_PS),
    ("1:1  +2ps  ⚠️ near-equal", BASE_PS, BASE_PS + 2),
    ("1:1  -2ps  ⚠️ near-equal", BASE_PS, BASE_PS - 2),
    ("1:1  +4ps  ⚠️ near-equal", BASE_PS, BASE_PS + 4),
    ("100.0/100.1MHz ⚠️ near-equal", 10_000, 9_990),
    ("mac->core (real)", MAC_PS, BASE_PS),
    ("pcie->core (real)", PCIE_PS, BASE_PS),
    ("core->pcie (real)", BASE_PS, PCIE_PS),
    ("2:1  write fast", BASE_PS, BASE_PS * 2),
    ("3:1  write fast", BASE_PS, BASE_PS * 3),
    ("4:1  write fast", BASE_PS, BASE_PS * 4),
    ("5:1  write fast", BASE_PS, BASE_PS * 5),
    ("8:1  write fast", BASE_PS, BASE_PS * 8),
    ("10:1 write fast", BASE_PS, BASE_PS * 10),
]


# =============================================================================
# Infrastructure
# =============================================================================

#: cocotb runs every test in this file inside ONE simulation, and this file
#: restarts both clocks at ~20 different ratios and phases. Without this
#: registry the previous driver task keeps toggling the net alongside the new
#: one: the DUT then sees a clock that is neither period, every ratio test
#: silently becomes the same test, and a real pointer bug would be masked by a
#: testbench bug. Kill the old driver, then start the new one.
_CLOCKS: dict[str, object] = {}


def start_clock_ps(dut, name: str, period_ps: int, phase_ps: int = 0):
    old = _CLOCKS.pop(name, None)
    if old is not None:
        old.kill()
    handle = getattr(dut, name)

    async def _run():
        if phase_ps:
            await Timer(phase_ps, units="ps")
        await Clock(handle, period_ps, units="ps").start()

    task = cocotb.start_soon(_run())
    _CLOCKS[name] = task
    return task


def dut_depth(dut) -> int:
    """DEPTH from the width of ``wr_high_water`` (``[$clog2(DEPTH):0]``)."""
    return 1 << (len(dut.wr_high_water) - 1)


def dut_width(dut) -> int:
    return len(dut.wr_data)


def almost_full_level(dut) -> int:
    return int(os.environ.get("ALMOST_FULL_LEVEL", dut_depth(dut) - 2))


def index_mask(w: int) -> int:
    """Largest index ``payload()`` can carry losslessly at this data width.

    ⚠️ Marker constants MUST be masked with this. At W=32 the index field is
    only 16 bits, and an unmasked 0xC0DE00 marker silently truncates — which
    then reads as the FIFO having returned the wrong word.
    """
    return (1 << max(1, w // 2)) - 1


def payload(i: int, w: int) -> int:
    """Self-describing word: low half is the index, high half its complement.

    A torn capture (some bits from word N, some from word N+1) breaks the
    complement relationship even when the low half still looks plausible, so a
    tear is reported as a tear rather than as a reordering.
    """
    half = max(1, w // 2)
    m = (1 << half) - 1
    return (((~i) & m) << half) | (i & m)


def decode(v: int, w: int) -> tuple[int, bool]:
    half = max(1, w // 2)
    m = (1 << half) - 1
    lo = v & m
    hi = (v >> half) & m
    return lo, hi == ((~lo) & m)


async def apply_reset(dut, wr_ps: int, rd_ps: int, rng=None,
                      stagger: bool = True) -> None:
    """Assert both resets, release them at independent (staggered) phases.

    This models what the design actually does: ONE asynchronous root reset, one
    ``reset_sync`` per domain (rtl/common/clk_rst_gen.sv:240).  The two domains
    therefore leave reset on DIFFERENT edges, at a phase relationship nobody
    controls.  A test that pulses both resets on the same simulation timestep is
    testing a reset tree the design does not have.
    """
    dut.wr_en.value = 0
    dut.rd_en.value = 0
    dut.wr_data.value = 0
    dut.wr_rst.value = 1
    dut.rd_rst.value = 1
    await Timer(12 * max(wr_ps, rd_ps), units="ps")
    if stagger and rng is not None:
        a, b = rng.randrange(0, 6 * wr_ps), rng.randrange(0, 6 * rd_ps)
    else:
        a = b = 0
    order = sorted(((a, "wr_rst"), (b, "rd_rst")))
    t = 0
    for when, sig in order:
        await Timer(max(1, when - t), units="ps")
        t = when
        getattr(dut, sig).value = 0
    dut.wr_rst.value = 0
    dut.rd_rst.value = 0
    await Timer(8 * max(wr_ps, rd_ps), units="ps")


class Writer:
    """Write-domain agent.  Drives on the falling edge; never writes when full."""

    def __init__(self, dut, rng, n_words: int, p_offer: float = 1.0,
                 advance_on_backpressure: bool = False):
        self.dut = dut
        self.rng = rng
        self.n = n_words
        self.p = p_offer
        self.advance = advance_on_backpressure
        self.w = dut_width(dut)
        self.sent: list[int] = []
        self.dropped: list[int] = []
        self.full_cycles = 0
        self.done = False
        self._task = None

    def start(self):
        async def _run():
            word = 0
            while word < self.n:
                await FallingEdge(self.dut.wr_clk)
                if int(self.dut.wr_rst.value):
                    self.dut.wr_en.value = 0
                    continue
                full = int(self.dut.wr_full.value)
                if full:
                    self.full_cycles += 1
                offer = self.rng.random() < self.p
                if offer and not full:
                    self.dut.wr_en.value = 1
                    self.dut.wr_data.value = payload(word, self.w)
                    self.sent.append(word)
                    word += 1
                else:
                    self.dut.wr_en.value = 0
                    if offer and full and self.advance:
                        # Drop-and-count: the RX path never back-pressures
                        # (CLAUDE.md §5.4), so the producer moves on.
                        self.dropped.append(word)
                        word += 1
            await FallingEdge(self.dut.wr_clk)
            self.dut.wr_en.value = 0
            self.done = True

        self._task = cocotb.start_soon(_run())
        return self._task

    def stop(self):
        if self._task:
            self._task.kill()
            self._task = None


class Reader:
    """Read-domain agent.  Drives on the falling edge; never reads when empty.

    ``rd_valid``/``rd_data`` sampled at the falling edge of cycle N describe the
    pop issued at the rising edge that started cycle N — the module presents
    data one read cycle after the pop (rtl/common/async_fifo.sv:224).
    """

    def __init__(self, dut, rng, p_pop: float = 1.0):
        self.dut = dut
        self.rng = rng
        self.p_pop = p_pop
        self.w = dut_width(dut)
        self.recvd: list[int] = []
        self.torn: list[tuple[int, int]] = []
        self.empty_cycles = 0
        self._task = None

    def start(self):
        async def _run():
            while True:
                await FallingEdge(self.dut.rd_clk)
                if int(self.dut.rd_rst.value):
                    self.dut.rd_en.value = 0
                    continue
                if int(self.dut.rd_valid.value):
                    raw = int(self.dut.rd_data.value)
                    idx, ok = decode(raw, self.w)
                    self.recvd.append(idx)
                    if not ok:
                        self.torn.append((len(self.recvd) - 1, raw))
                empty = int(self.dut.rd_empty.value)
                if empty:
                    self.empty_cycles += 1
                self.dut.rd_en.value = int(
                    (not empty) and self.rng.random() < self.p_pop)

        self._task = cocotb.start_soon(_run())
        return self._task

    def stop(self):
        if self._task:
            self._task.kill()
            self._task = None
        self.dut.rd_en.value = 0


def _reader(dut, rng, p_pop: float = 1.0) -> Reader:
    return Reader(dut, rng, p_pop)


def check_stream(sent: list[int], recvd: list[int], torn: list, label: str,
                 seed: int) -> None:
    """The one assertion that matters: same words, same order, once each."""
    assert not torn, (
        f"[{label}] TORN WORD at receive index {torn[0][0]}: raw 0x{torn[0][1]:x} "
        f"failed its own complement check.\n"
        f"  Half the bits came from one word and half from another. In this "
        f"module that can only mean the memory was read at an address the "
        f"pointers had not agreed on — i.e. rd_empty was low with nothing "
        f"behind it. {len(torn)} torn word(s) total." + seed_note(seed)
    )
    if recvd == sent:
        return
    n = min(len(sent), len(recvd))
    first = next((i for i in range(n) if sent[i] != recvd[i]), n)
    lost = set(sent) - set(recvd)
    dup = len(recvd) - len(set(recvd))
    raise AssertionError(
        f"[{label}] DATA CORRUPTION ACROSS THE CLOCK BOUNDARY\n"
        f"  written  : {len(sent)} words\n"
        f"  read back: {len(recvd)} words\n"
        f"  first divergence at index {first}: "
        f"expected {sent[first] if first < len(sent) else '<end>'}, "
        f"got {recvd[first] if first < len(recvd) else '<end>'}\n"
        f"  context expected {sent[max(0, first - 3):first + 4]}\n"
        f"  context actual   {recvd[max(0, first - 3):first + 4]}\n"
        f"  words never read : {sorted(lost)[:12]}{' ...' if len(lost) > 12 else ''}\n"
        f"  duplicated reads : {dup}\n"
        f"  This is the failure mode rtl/common/async_fifo.sv:38 calls SILENT "
        f"CORRUPTION. On the MAC RX crossing it is a market-data message that "
        f"never reached the book; on the TX crossing it is a mangled order on "
        f"the wire." + seed_note(seed)
    )


# =============================================================================
# 1. ⚠️ THE headline: no loss, no duplication, across every ratio
# =============================================================================

@cocotb.test()
async def test_no_loss_no_duplication_across_ratios(dut):
    """Write:read ratios 1:10 through 10:1, plus near-equal, randomized phase.

    Producer and consumer each stall randomly, so the FIFO spends time full,
    time empty, and time in between at every ratio.  The check is exact
    sequence equality: any loss, duplication, reordering or tear fails with a
    first-divergence report.

    ⚠️ ``rtl/common/async_fifo.sv:43`` makes this run a precondition for using
    the module at all, rather than the vendor macro.
    """
    rng, seed = seeded_rng(dut, "async_fifo.ratios")
    depth = dut_depth(dut)
    dut._log.info("DEPTH=%d W=%d ALMOST_FULL_LEVEL=%d",
                  depth, dut_width(dut), almost_full_level(dut))

    for label, wr_ps, rd_ps in RATIOS:
        # Fresh clocks per ratio, at a randomized phase offset. Randomizing the
        # PHASE and not only the ratio is the explicit instruction in manual
        # 00.04 §6.2 — a pointer bug that only bites at one alignment is still
        # a bug, and it is the kind that survives soak testing.
        start_clock_ps(dut, "wr_clk", wr_ps, rng.randrange(0, wr_ps))
        start_clock_ps(dut, "rd_clk", rd_ps, rng.randrange(0, rd_ps))
        await apply_reset(dut, wr_ps, rd_ps, rng)

        wr = Writer(dut, rng, WORDS, p_offer=rng.uniform(0.4, 1.0))
        rd = _reader(dut, rng, p_pop=rng.uniform(0.4, 1.0))
        wr.start()
        rd.start()

        guard_ps = (WORDS + 64) * 40 * max(wr_ps, rd_ps)
        elapsed = 0
        step = 50 * max(wr_ps, rd_ps)
        while elapsed < guard_ps:
            await Timer(step, units="ps")
            elapsed += step
            if wr.done and len(rd.recvd) >= len(wr.sent):
                break
        # Let the tail drain.
        await Timer(60 * max(wr_ps, rd_ps), units="ps")
        wr.stop()
        rd.stop()

        assert wr.done, (
            f"[{label}] the writer never placed all {WORDS} words "
            f"({len(wr.sent)} written, {wr.full_cycles} cycles blocked by "
            f"wr_full) — the FIFO stopped draining." + seed_note(seed)
        )
        check_stream(wr.sent, rd.recvd, rd.torn, label, seed)
        dut._log.info(
            "%s: %d words, %d wr-full cycles, %d rd-empty cycles",
            label, len(wr.sent), wr.full_cycles, rd.empty_cycles,
        )


@cocotb.test()
async def test_near_equal_frequency_long_soak(dut):
    """⚠️ THE hardest case: 6400 ps vs 6402 ps, long enough to sweep all phases.

    ``tb/COVERAGE.md §3.1`` names this specifically: "The nearly-equal-clock-
    frequency case (6.4 ns vs 6.402 ns) is the one that finds gray-pointer
    comparison bugs, and it is exactly the case nobody writes by hand."

    One picosecond of period difference is one picosecond of phase slip per
    cycle, so 6400 cycles is one complete revolution of the phase relationship.
    This soak runs several revolutions with the FIFO deliberately parked near
    both extremes — full and empty — because the pointer comparisons that are
    hard to get right are the full and empty edge cases
    (rtl/common/async_fifo.sv:161: "THIS IS THE EDGE CASE THAT GETS WRITTEN
    WRONG").
    """
    rng, seed = seeded_rng(dut, "async_fifo.nearequal")
    words = int(os.environ.get("SOAK_WORDS", "4000"))
    wr_ps, rd_ps = BASE_PS, BASE_PS + 2

    start_clock_ps(dut, "wr_clk", wr_ps, rng.randrange(0, wr_ps))
    start_clock_ps(dut, "rd_clk", rd_ps, rng.randrange(0, rd_ps))
    await apply_reset(dut, wr_ps, rd_ps, rng)

    # p_offer > p_pop keeps the FIFO pressed against full for most of the run,
    # with the reader occasionally sprinting so it also visits empty.
    wr = Writer(dut, rng, words, p_offer=0.95)
    rd = _reader(dut, rng, p_pop=0.85)
    wr.start()
    rd.start()

    elapsed = 0
    step = 200 * wr_ps
    while elapsed < words * 40 * wr_ps:
        await Timer(step, units="ps")
        elapsed += step
        if wr.done and len(rd.recvd) >= len(wr.sent):
            break
    await Timer(80 * wr_ps, units="ps")
    wr.stop()
    rd.stop()

    assert wr.done, f"writer stalled at {len(wr.sent)}/{words}" + seed_note(seed)
    check_stream(wr.sent, rd.recvd, rd.torn, "6400ps vs 6402ps soak", seed)
    assert wr.full_cycles > 0, (
        "the FIFO never reached full during the near-equal soak — the run did "
        "not exercise the full/empty edge cases it exists to exercise"
    )
    assert rd.empty_cycles > 0, "the FIFO never reached empty during the soak"
    # Two picoseconds of period difference => 2 ps of phase slip per cycle, so
    # wr_ps/2 write cycles is one complete revolution of the phase relationship.
    revolutions = (elapsed / wr_ps) / (wr_ps / 2)
    dut._log.info(
        "near-equal soak: %d words over ~%.1f complete phase revolutions, "
        "%d wr-full cycles, %d rd-empty cycles",
        len(wr.sent), revolutions, wr.full_cycles, rd.empty_cycles,
    )


# =============================================================================
# 2. Flags: never wrong in the direction that costs data
# =============================================================================

@cocotb.test()
async def test_full_asserts_at_exactly_depth_and_not_before(dut):
    """Exactly ``DEPTH`` words fit.  Not DEPTH-1, not DEPTH+1.

    An off-by-one in the full comparison is the classic async-FIFO defect: one
    entry too many silently overwrites unread data, one entry too few costs
    throughput on the RX crossing where there is nowhere to push back to.

    Filled with the reader idle, so the write-domain occupancy view is exact
    rather than conservative.
    """
    rng, seed = seeded_rng(dut, "async_fifo.full")
    depth = dut_depth(dut)
    w = dut_width(dut)
    wr_ps = rd_ps = BASE_PS

    start_clock_ps(dut, "wr_clk", wr_ps)
    start_clock_ps(dut, "rd_clk", rd_ps, 1700)
    await apply_reset(dut, wr_ps, rd_ps, rng)

    accepted = 0
    early_full = None
    for i in range(depth + 4):
        await FallingEdge(dut.wr_clk)
        full = int(dut.wr_full.value)
        if full:
            if accepted < depth and early_full is None:
                early_full = accepted
            dut.wr_en.value = 0
            continue
        dut.wr_en.value = 1
        dut.wr_data.value = payload(i, w)
        accepted += 1
    await FallingEdge(dut.wr_clk)
    dut.wr_en.value = 0

    assert early_full is None, (
        f"wr_full asserted after only {early_full} writes into a DEPTH={depth} "
        f"FIFO with no reader.\n"
        f"  A FIFO that is full early wastes buffering on the MAC RX crossing, "
        f"where wr_full is a DROP event and not a stall (CLAUDE.md §5.4)."
        + seed_note(seed)
    )
    assert accepted == depth, (
        f"{accepted} writes were accepted into a DEPTH={depth} FIFO with the "
        f"reader idle.\n"
        f"  MORE than DEPTH means wr_full let a write overwrite an unread entry "
        f"— silent corruption. FEWER means capacity is being wasted."
        + seed_note(seed)
    )
    await FallingEdge(dut.wr_clk)
    assert int(dut.wr_full.value) == 1, (
        f"after {depth} writes wr_full is still low — the next write would "
        f"overwrite the oldest unread word"
    )
    assert int(dut.wr_almost_full.value) == 1, (
        "wr_full asserted without wr_almost_full "
        "(rtl/common/async_fifo.sv:331)"
    )
    dut._log.info("exactly %d words fit; wr_full asserted on the %dth", depth, depth)


@cocotb.test()
async def test_empty_is_never_low_with_nothing_behind_it(dut):
    """``rd_empty`` falls only after a real word has crossed, and rises again
    exactly when the last one is taken.

    The dangerous direction for ``rd_empty`` is LOW-when-empty: the reader pops,
    the pointers disagree, and stale memory contents leave the FIFO as if they
    were market data.  The self-describing payload makes that detectable
    (``decode()`` complement check) even when the stale word happens to look
    like a plausible index.

    Also pins the documented crossing latency: ``rd_empty`` falls
    ``SYNC_STAGES + 1`` read cycles after the write (rtl/common/async_fifo.sv:21).
    """
    rng, seed = seeded_rng(dut, "async_fifo.empty")
    w = dut_width(dut)
    wr_ps = rd_ps = BASE_PS

    start_clock_ps(dut, "wr_clk", wr_ps)
    start_clock_ps(dut, "rd_clk", rd_ps, 3100)
    await apply_reset(dut, wr_ps, rd_ps, rng)

    await FallingEdge(dut.rd_clk)
    assert int(dut.rd_empty.value) == 1, (
        "rd_empty is low straight out of reset — the reader would immediately "
        "pop stale memory (rtl/common/async_fifo.sv:220 sets empty out of reset "
        "precisely to fail closed)"
    )

    # Nothing written: rd_empty must stay high indefinitely.
    for _ in range(200):
        await FallingEdge(dut.rd_clk)
        assert int(dut.rd_empty.value) == 1, (
            "rd_empty fell with nothing ever written" + seed_note(seed))

    # One write. Measure how many read cycles until rd_empty falls.
    await FallingEdge(dut.wr_clk)
    dut.wr_en.value = 1
    dut.wr_data.value = payload(0xABC & index_mask(w), w)
    await FallingEdge(dut.wr_clk)
    dut.wr_en.value = 0

    latency = None
    for n in range(1, 32):
        await FallingEdge(dut.rd_clk)
        if not int(dut.rd_empty.value):
            latency = n
            break
    assert latency is not None, "rd_empty never fell after a write"
    assert 2 <= latency <= 5, (
        f"write-to-readable latency is {latency} read cycles; "
        f"rtl/common/async_fifo.sv:21 budgets SYNC_STAGES+1 (= 3 by default) "
        f"and manual 00.04 §3.3 budgets 2-3 destination cycles for the "
        f"crossing.\n  Every cycle here is on the tick-to-trade path twice — "
        f"once inbound, once outbound."
    )

    # Take the single word; rd_empty must come straight back.
    # rd_en driven now is sampled by the NEXT rising edge; the module presents
    # rd_data + rd_valid on that same edge, so they are readable at the falling
    # edge immediately after (rtl/common/async_fifo.sv:224).
    dut.rd_en.value = 1
    await FallingEdge(dut.rd_clk)
    dut.rd_en.value = 0
    assert int(dut.rd_valid.value) == 1, (
        "pop did not produce rd_valid on the following cycle "
        "(rtl/common/async_fifo.sv:344)")
    raw = int(dut.rd_data.value)
    idx, ok = decode(raw, w)
    want = 0xABC & index_mask(w)
    assert ok and idx == want, (
        f"single-word read returned 0x{raw:x} (index {idx}, complement "
        f"{'ok' if ok else 'BROKEN'}), expected index {want:#x}"
    )
    for _ in range(4):
        await FallingEdge(dut.rd_clk)
    assert int(dut.rd_empty.value) == 1, (
        "rd_empty did not return after the only word was read — the reader "
        "would pop the same word again"
    )
    dut._log.info("write-to-readable latency: %d read cycles", latency)


@cocotb.test()
async def test_almost_full_threshold_and_headroom(dut):
    """``wr_almost_full`` asserts at ``ALMOST_FULL_LEVEL`` and leaves headroom.

    ``rtl/common/async_fifo.sv:58`` — on the MAC RX crossing there is no
    back-pressure, so ``wr_almost_full`` is the signal that lets the caller start
    dropping DELIBERATELY, at a chosen boundary: "whole messages, not half
    messages".  Two properties matter operationally:

      * it asserts at the documented occupancy, not one early and not one late;
      * once it has asserted, there is still room for ``DEPTH - LEVEL`` more
        beats — the in-flight beats the producer cannot retract.  If that
        headroom shrinks, a maximum-length ITCH message can no longer be
        completed and the caller's drop boundary stops being a message boundary.
    """
    rng, seed = seeded_rng(dut, "async_fifo.almostfull")
    depth = dut_depth(dut)
    level = almost_full_level(dut)
    w = dut_width(dut)
    wr_ps = rd_ps = BASE_PS

    start_clock_ps(dut, "wr_clk", wr_ps)
    start_clock_ps(dut, "rd_clk", rd_ps, 900)
    await apply_reset(dut, wr_ps, rd_ps, rng)

    first_af = None
    accepted = 0
    for i in range(depth + 2):
        await FallingEdge(dut.wr_clk)
        if int(dut.wr_almost_full.value) and first_af is None:
            first_af = accepted
        if int(dut.wr_full.value):
            dut.wr_en.value = 0
            continue
        dut.wr_en.value = 1
        dut.wr_data.value = payload(i, w)
        accepted += 1
    await FallingEdge(dut.wr_clk)
    dut.wr_en.value = 0

    assert first_af is not None, (
        f"wr_almost_full never asserted while filling a DEPTH={depth} FIFO"
        + seed_note(seed)
    )
    assert first_af == level, (
        f"wr_almost_full first observed at occupancy {first_af}; "
        f"ALMOST_FULL_LEVEL is {level} (rtl/common/async_fifo.sv:78).\n"
        f"  On the RX crossing this threshold is where the caller starts "
        f"dropping whole messages. Moving it silently changes where a burst "
        f"starts being truncated."
    )
    headroom = accepted - first_af
    assert headroom == depth - level, (
        f"headroom between wr_almost_full and wr_full is {headroom} beats, "
        f"expected {depth - level}.\n"
        f"  That headroom is what lets an in-flight message finish. If it "
        f"shrinks, half-messages reach the decoder."
    )
    dut._log.info("almost_full at %d of %d, headroom %d beats",
                  first_af, depth, headroom)


# =============================================================================
# 3. Telemetry: wr_high_water
# =============================================================================

@cocotb.test()
async def test_high_water_tracks_the_true_maximum(dut):
    """``wr_high_water`` equals the true peak occupancy, and never decreases.

    ``rtl/common/async_fifo.sv:87`` — this is telemetry per CLAUDE.md §5.7:
    "a FIFO that quietly runs at 15/16 in production is a drop waiting for a
    busy morning."  The number has to be trustworthy in the direction that
    matters: it may never UNDER-report, because an under-reported high water
    mark is exactly the reassuring lie that stops anyone resizing the FIFO.

    Two regimes, because the module documents different accuracy in each
    (line 63): with the pointers quiescent the occupancy view is EXACT; with
    reads in flight the synchronized read pointer lags and the mark is
    conservative — "may read one or two entries pessimistic", which is the
    right direction for a high-water mark.
    """
    rng, seed = seeded_rng(dut, "async_fifo.highwater")
    depth = dut_depth(dut)
    w = dut_width(dut)
    wr_ps, rd_ps = BASE_PS, BASE_PS + 2

    start_clock_ps(dut, "wr_clk", wr_ps)
    start_clock_ps(dut, "rd_clk", rd_ps, 2300)
    await apply_reset(dut, wr_ps, rd_ps, rng)

    await FallingEdge(dut.wr_clk)
    assert int(dut.wr_high_water.value) == 0, "high water non-zero out of reset"

    # --- Regime A: quiesced bursts. The mark must be EXACT.
    peak = 0
    prev_hw = 0
    for k in sorted({1, 2, depth // 2, depth - 1, depth, 3, depth // 4 or 1}):
        # Fill k, then drain fully, then let both pointer synchronizers settle
        # before the next burst so the occupancy view is exact.
        for i in range(k):
            await FallingEdge(dut.wr_clk)
            assert not int(dut.wr_full.value), (
                f"full at {i} while filling {k} into DEPTH={depth}")
            dut.wr_en.value = 1
            dut.wr_data.value = payload(i, w)
        await FallingEdge(dut.wr_clk)
        dut.wr_en.value = 0
        peak = max(peak, k)

        await FallingEdge(dut.wr_clk)
        hw = int(dut.wr_high_water.value)
        assert hw == peak, (
            f"wr_high_water is {hw} after a quiesced burst of {k} "
            f"(running peak {peak}).\n"
            f"  With no concurrent reads the write-domain occupancy view is "
            f"exact (rtl/common/async_fifo.sv:63), so this must be an equality. "
            f"An under-report is a FIFO that looks roomier than it is."
            + seed_note(seed)
        )
        assert hw >= prev_hw, f"wr_high_water decreased: {prev_hw} -> {hw}"
        prev_hw = hw

        # Drain.
        drained = 0
        for _ in range(k * 8 + 64):
            await FallingEdge(dut.rd_clk)
            if int(dut.rd_valid.value):
                drained += 1
            dut.rd_en.value = int(not int(dut.rd_empty.value))
            if drained >= k and int(dut.rd_empty.value):
                break
        dut.rd_en.value = 0
        assert drained == k, f"drained {drained} of {k}"
        await Timer(20 * max(wr_ps, rd_ps), units="ps")

        await FallingEdge(dut.wr_clk)
        assert int(dut.wr_high_water.value) == peak, (
            "wr_high_water moved during a drain — it is sticky until wr_rst"
        )

    # --- Regime B: concurrent traffic. Conservative, never optimistic.
    wr = Writer(dut, rng, 600, p_offer=0.9)
    rd = _reader(dut, rng, p_pop=0.55)
    wr.start()
    rd.start()
    elapsed = 0
    while elapsed < 600 * 40 * wr_ps:
        await Timer(200 * wr_ps, units="ps")
        elapsed += 200 * wr_ps
        if wr.done and len(rd.recvd) >= len(wr.sent):
            break
    await Timer(60 * wr_ps, units="ps")
    wr.stop()
    rd.stop()
    check_stream(wr.sent, rd.recvd, rd.torn, "high-water regime B", seed)

    await FallingEdge(dut.wr_clk)
    hw = int(dut.wr_high_water.value)
    assert peak <= hw <= depth, (
        f"wr_high_water {hw} is outside [{peak}, {depth}] after a mixed run"
        + seed_note(seed)
    )
    assert wr.full_cycles == 0 or hw == depth, (
        f"the FIFO hit wr_full ({wr.full_cycles} cycles) but wr_high_water is "
        f"{hw}, not {depth}.\n"
        f"  The high-water mark MISSED a full condition. This is the telemetry "
        f"the operations dashboard uses to decide whether the FIFO is sized "
        f"correctly; an under-report is worse than no number at all."
        + seed_note(seed)
    )

    # Reset clears it.
    await apply_reset(dut, wr_ps, rd_ps, rng)
    await FallingEdge(dut.wr_clk)
    assert int(dut.wr_high_water.value) == 0, (
        "wr_high_water survived wr_rst — the header says sticky UNTIL wr_rst"
    )
    dut._log.info("high water: exact under quiescence, %d after mixed traffic", hw)


# =============================================================================
# 4. Reset
# =============================================================================

@cocotb.test()
async def test_reset_from_both_domains_at_arbitrary_phase(dut):
    """Reset at arbitrary, STAGGERED phase leaves an empty FIFO with no survivor.

    One ``reset_sync`` per domain off one asynchronous root means the two
    domains genuinely leave reset on different edges, at a phase relationship
    nobody controls (rtl/common/clk_rst_gen.sv:240, manual 00.04 §4).  This test
    resets mid-traffic, with data in flight, at many different stagger offsets.

    After release the FIFO must be EMPTY — not "empty soon", and above all not
    holding a pre-reset word.  A survivor here is a market-data message from
    before a link flap being delivered into a freshly re-armed book, which is
    how a book comes up already wrong.
    """
    rng, seed = seeded_rng(dut, "async_fifo.reset")
    w = dut_width(dut)
    depth = dut_depth(dut)
    wr_ps, rd_ps = BASE_PS, BASE_PS + 2

    start_clock_ps(dut, "wr_clk", wr_ps)
    start_clock_ps(dut, "rd_clk", rd_ps, 4100)

    for trial in range(12):
        await apply_reset(dut, wr_ps, rd_ps, rng)

        # Put data in flight: partially fill, start a read, then reset.
        n_pre = rng.randrange(1, depth + 1)
        for i in range(n_pre):
            await FallingEdge(dut.wr_clk)
            if int(dut.wr_full.value):
                break
            dut.wr_en.value = 1
            dut.wr_data.value = payload((0xF00000 + i) & index_mask(w), w)
        await FallingEdge(dut.wr_clk)
        dut.wr_en.value = 0
        await Timer(rng.randrange(1, 6 * rd_ps), units="ps")
        dut.rd_en.value = int(rng.random() < 0.5)

        await apply_reset(dut, wr_ps, rd_ps, rng)

        await FallingEdge(dut.rd_clk)
        assert int(dut.rd_empty.value) == 1, (
            f"trial {trial}: rd_empty low after a both-domain reset — a "
            f"pre-reset word survived" + seed_note(seed))
        assert int(dut.wr_full.value) == 0, (
            f"trial {trial}: wr_full high after reset" + seed_note(seed))
        assert int(dut.wr_almost_full.value) == 0, (
            f"trial {trial}: wr_almost_full high after reset" + seed_note(seed))
        assert int(dut.wr_high_water.value) == 0, (
            f"trial {trial}: wr_high_water not cleared by wr_rst" + seed_note(seed))
        assert int(dut.rd_valid.value) == 0, (
            f"trial {trial}: rd_valid high after reset" + seed_note(seed))

        # The first word through after reset must be the NEW word.
        marker = (0xC0DE00 + trial) & index_mask(w)
        await FallingEdge(dut.wr_clk)
        dut.wr_en.value = 1
        dut.wr_data.value = payload(marker, w)
        await FallingEdge(dut.wr_clk)
        dut.wr_en.value = 0

        got = None
        for _ in range(64):
            await FallingEdge(dut.rd_clk)
            if int(dut.rd_valid.value):
                got = int(dut.rd_data.value)
                break
            dut.rd_en.value = int(not int(dut.rd_empty.value))
        dut.rd_en.value = 0
        assert got is not None, f"trial {trial}: no data after reset"
        idx, ok = decode(got, w)
        assert ok and idx == marker, (
            f"trial {trial}: first post-reset word was index {idx} "
            f"(complement {'ok' if ok else 'BROKEN'}), expected {marker}.\n"
            f"  A survivor from before the reset was delivered into the "
            f"freshly re-armed pipeline." + seed_note(seed)
        )
    dut._log.info("12 staggered-phase reset trials clean")


# =============================================================================
# 5. Burst / drain shapes
# =============================================================================

@cocotb.test()
async def test_burst_write_then_drain(dut):
    """Fill to full in one burst, then drain to empty, repeatedly.

    This is the MAC RX shape: a packet arrives at line rate, the consumer takes
    it afterwards.  It parks the pointers at both extremes on every iteration,
    which is where the gray comparison is hardest, and it does so at four
    ratios including near-equal.
    """
    rng, seed = seeded_rng(dut, "async_fifo.burst")
    depth = dut_depth(dut)
    w = dut_width(dut)

    for label, wr_ps, rd_ps in (
        ("1:1  identical", BASE_PS, BASE_PS),
        ("1:1  +2ps near-equal", BASE_PS, BASE_PS + 2),
        ("4:1  write fast", BASE_PS, BASE_PS * 4),
        ("1:4  read fast", BASE_PS * 4, BASE_PS),
    ):
        start_clock_ps(dut, "wr_clk", wr_ps, rng.randrange(0, wr_ps))
        start_clock_ps(dut, "rd_clk", rd_ps, rng.randrange(0, rd_ps))
        await apply_reset(dut, wr_ps, rd_ps, rng)

        sent: list[int] = []
        recvd: list[int] = []
        torn: list = []
        idx = 0
        for burst in range(24):
            # Fill until full.
            filled = 0
            for _ in range(depth * 4 + 32):
                await FallingEdge(dut.wr_clk)
                if int(dut.wr_full.value):
                    dut.wr_en.value = 0
                    break
                dut.wr_en.value = 1
                dut.wr_data.value = payload(idx, w)
                sent.append(idx)
                idx += 1
                filled += 1
            await FallingEdge(dut.wr_clk)
            dut.wr_en.value = 0
            assert filled == depth, (
                f"[{label}] burst {burst}: filled {filled}, expected {depth}"
                + seed_note(seed))

            # Drain until empty.
            drained = 0
            for _ in range(depth * 8 + 96):
                await FallingEdge(dut.rd_clk)
                if int(dut.rd_valid.value):
                    v, ok = decode(int(dut.rd_data.value), w)
                    recvd.append(v)
                    if not ok:
                        torn.append((len(recvd) - 1, v))
                    drained += 1
                empty = int(dut.rd_empty.value)
                dut.rd_en.value = int(not empty)
                if drained >= filled and empty:
                    break
            dut.rd_en.value = 0
            assert drained == filled, (
                f"[{label}] burst {burst}: drained {drained} of {filled}"
                + seed_note(seed))
        check_stream(sent, recvd, torn, f"{label} burst/drain", seed)
        dut._log.info("%s: 24 full bursts of %d, all intact", label, depth)


@cocotb.test()
async def test_drain_faster_than_fill(dut):
    """A reader far faster than the writer must never read ahead of the data.

    The FIFO spends almost the whole run empty, so ``rd_empty`` is being
    re-evaluated against a write pointer that has just moved, on nearly every
    read cycle.  This is where an empty comparison that is off by the
    synchronizer latency produces a read of stale memory — and the complement
    check in the payload catches exactly that.
    """
    rng, seed = seeded_rng(dut, "async_fifo.drainfast")
    for label, wr_ps, rd_ps in (
        ("1:10 read fast", BASE_PS * 10, BASE_PS),
        ("1:5  read fast", BASE_PS * 5, BASE_PS),
        ("1:1  +2ps", BASE_PS, BASE_PS + 2),
    ):
        start_clock_ps(dut, "wr_clk", wr_ps, rng.randrange(0, wr_ps))
        start_clock_ps(dut, "rd_clk", rd_ps, rng.randrange(0, rd_ps))
        await apply_reset(dut, wr_ps, rd_ps, rng)

        wr = Writer(dut, rng, 400, p_offer=0.6)
        rd = _reader(dut, rng, p_pop=1.0)   # reader never pauses
        wr.start()
        rd.start()
        elapsed = 0
        while elapsed < 400 * 60 * wr_ps:
            await Timer(200 * wr_ps, units="ps")
            elapsed += 200 * wr_ps
            if wr.done and len(rd.recvd) >= len(wr.sent):
                break
        await Timer(60 * max(wr_ps, rd_ps), units="ps")
        wr.stop()
        rd.stop()
        check_stream(wr.sent, rd.recvd, rd.torn, label, seed)
        assert rd.empty_cycles > 0, f"[{label}] the FIFO never went empty"
        dut._log.info("%s: %d words, %d rd-empty cycles",
                      label, len(wr.sent), rd.empty_cycles)


@cocotb.test()
async def test_producer_drops_at_full_without_corrupting(dut):
    """CLAUDE.md §5.4: on the RX crossing ``wr_full`` is a DROP, not a stall.

    The producer here does what the MAC RX path must do — it advances to the
    next beat whether or not the FIFO took the previous one, because the wire
    does not wait.  The property is that the words the FIFO DID accept come out
    perfectly, in order: dropping must never disturb what is already inside.

    (The caller counts the drops.  This module deliberately counts nothing;
    ``wr_high_water`` is its only telemetry.)
    """
    rng, seed = seeded_rng(dut, "async_fifo.drop")
    wr_ps, rd_ps = BASE_PS, BASE_PS * 4     # writer 4x faster: guaranteed drops

    start_clock_ps(dut, "wr_clk", wr_ps, rng.randrange(0, wr_ps))
    start_clock_ps(dut, "rd_clk", rd_ps, rng.randrange(0, rd_ps))
    await apply_reset(dut, wr_ps, rd_ps, rng)

    wr = Writer(dut, rng, 800, p_offer=1.0, advance_on_backpressure=True)
    rd = _reader(dut, rng, p_pop=1.0)
    wr.start()
    rd.start()
    elapsed = 0
    while elapsed < 800 * 40 * wr_ps:
        await Timer(200 * wr_ps, units="ps")
        elapsed += 200 * wr_ps
        if wr.done and len(rd.recvd) >= len(wr.sent):
            break
    await Timer(80 * rd_ps, units="ps")
    wr.stop()
    rd.stop()

    assert wr.dropped, (
        "no beats were dropped even with the writer 4x faster than the reader "
        "— this test did not reach the condition it exists to test"
        + seed_note(seed)
    )
    check_stream(wr.sent, rd.recvd, rd.torn, "drop-at-full", seed)
    assert sorted(wr.sent) == wr.sent, "internal: sent list not monotonic"
    dut._log.info(
        "drop-and-count: %d beats accepted, %d dropped at full, 0 corrupted",
        len(wr.sent), len(wr.dropped),
    )


# =============================================================================
# 6. The safety argument itself
# =============================================================================

@cocotb.test()
async def test_pointers_are_gray_coded(dut):
    """Exactly one pointer bit changes per increment — the whole safety argument.

    ``rtl/common/async_fifo.sv:14`` — the pointers, and only the pointers, are
    allowed to cross through parallel 2-FF chains, and that permission rests
    entirely on the gray property: a pointer sampled mid-transition is the old
    value or the new one, never a third value that never existed.  If two bits
    ever change together, this module becomes exactly the multi-bit CDC bug in
    manual 00.04 §2 and every crossing in the design is unsafe.

    ⚠️ Best-effort: reads internal registers, which some simulator/optimizer
    combinations flatten away.  It logs and returns rather than failing when the
    signals are not reachable — a structural check that cannot see the design is
    not evidence of anything, and pretending otherwise is worse than skipping.
    The RTL carries the same property as an assertion
    (rtl/common/async_fifo.sv:297).
    """
    rng, seed = seeded_rng(dut, "async_fifo.gray")
    wr_ps, rd_ps = BASE_PS, BASE_PS + 2
    try:
        wr_g = dut.wr_ptr_gray_q
        rd_g = dut.rd_ptr_gray_q
        int(wr_g.value)
        int(rd_g.value)
    except Exception as exc:  # pragma: no cover - depends on the simulator
        dut._log.warning(
            "gray-pointer check SKIPPED: internal pointers not reachable (%s). "
            "The RTL assertion at async_fifo.sv:297 covers this when the "
            "simulator is built with assertions enabled.", exc)
        return

    start_clock_ps(dut, "wr_clk", wr_ps)
    start_clock_ps(dut, "rd_clk", rd_ps, 1234)
    await apply_reset(dut, wr_ps, rd_ps, rng)

    wr = Writer(dut, rng, 1200, p_offer=0.8)
    rd = _reader(dut, rng, p_pop=0.7)
    wr.start()
    rd.start()

    violations: list[str] = []

    async def _watch(handle, clk, name):
        prev = None
        while True:
            await RisingEdge(clk)
            await ReadOnly()
            cur = int(handle.value)
            if prev is not None:
                d = bin(cur ^ prev).count("1")
                if d > 1:
                    violations.append(
                        f"{name}: 0x{prev:x} -> 0x{cur:x} ({d} bits at once)")
            prev = cur

    t1 = cocotb.start_soon(_watch(wr_g, dut.wr_clk, "wr_ptr_gray_q"))
    t2 = cocotb.start_soon(_watch(rd_g, dut.rd_clk, "rd_ptr_gray_q"))

    elapsed = 0
    while elapsed < 1200 * 40 * wr_ps:
        await Timer(200 * wr_ps, units="ps")
        elapsed += 200 * wr_ps
        if wr.done and len(rd.recvd) >= len(wr.sent):
            break
    t1.kill()
    t2.kill()
    wr.stop()
    rd.stop()

    assert not violations, (
        f"POINTER IS NOT GRAY CODED — {len(violations)} multi-bit transition(s); "
        f"first 5:\n  " + "\n  ".join(violations[:5]) + "\n"
        f"  This voids the entire safety argument for crossing the pointers "
        f"through parallel 2-FF chains (rtl/common/async_fifo.sv:14, manual "
        f"00.04 §2). Every FIFO in the design becomes unsafe."
        + seed_note(seed)
    )
    check_stream(wr.sent, rd.recvd, rd.torn, "gray-pointer soak", seed)
    dut._log.info("gray property held on both pointers for the whole soak")


@cocotb.test(skip=not os.environ.get("PROBE_ILLEGAL"))
async def test_illegal_write_while_full_does_not_corrupt(dut):
    """⚠️ CONTRACT-VIOLATION PROBE. Off by default; set ``PROBE_ILLEGAL=1``.

    Deliberately asserts ``wr_en`` while ``wr_full`` is high, which the RTL's own
    assertion at rtl/common/async_fifo.sv:317 reports as an error.  That is the
    point: a producer that ignores ``wr_full`` is a design bug, and this proves
    what it costs — the offered word is DROPPED, and everything already inside
    the FIFO survives untouched and in order.

    It is opt-in because a run with assertions enabled will (correctly) report
    the violation, and a suite that prints an expected error on every run trains
    people to ignore errors.
    """
    rng, seed = seeded_rng(dut, "async_fifo.illegal")
    depth = dut_depth(dut)
    w = dut_width(dut)
    wr_ps = rd_ps = BASE_PS

    start_clock_ps(dut, "wr_clk", wr_ps)
    start_clock_ps(dut, "rd_clk", rd_ps, 2100)
    await apply_reset(dut, wr_ps, rd_ps, rng)

    good: list[int] = []
    for i in range(depth):
        await FallingEdge(dut.wr_clk)
        dut.wr_en.value = 1
        dut.wr_data.value = payload(i, w)
        good.append(i)
    # Now hammer it while full with garbage.
    for k in range(40):
        await FallingEdge(dut.wr_clk)
        dut.wr_en.value = 1
        dut.wr_data.value = payload(0xBADBAD00 + k, w)
    await FallingEdge(dut.wr_clk)
    dut.wr_en.value = 0

    recvd: list[int] = []
    torn: list = []
    for _ in range(depth * 8 + 64):
        await FallingEdge(dut.rd_clk)
        if int(dut.rd_valid.value):
            v, ok = decode(int(dut.rd_data.value), w)
            recvd.append(v)
            if not ok:
                torn.append((len(recvd) - 1, v))
        empty = int(dut.rd_empty.value)
        dut.rd_en.value = int(not empty)
        if len(recvd) >= depth and empty:
            break
    dut.rd_en.value = 0
    check_stream(good, recvd, torn, "illegal write-while-full", seed)
    dut._log.info("%d over-writes dropped, %d resident words intact", 40, depth)


if __name__ == "__main__":  # pragma: no cover
    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        from cocotb.runner import get_runner

    runner = get_runner(os.environ.get("SIM", "verilator"))
    # DEPTH=4 is the minimum the module allows and has the shortest pointers,
    # which is where an off-by-one in the full comparison shows up soonest.
    for w, depth, stages in ((64, 16, 2), (64, 4, 2), (32, 8, 3), (64, 32, 2)):
        runner.build(
            verilog_sources=sim_sources(
                "rtl/common/cdc_sync_bit.sv", "rtl/common/async_fifo.sv"),
            hdl_toplevel="async_fifo",
            parameters={"W": w, "DEPTH": depth, "SYNC_STAGES": stages},
            build_args=["-Wno-fatal", "--timescale-override", "1ns/1ps"],
            always=True,
        )
        runner.test(hdl_toplevel="async_fifo", test_module="test_async_fifo")
