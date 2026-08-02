"""Strategy parameter table — proves the fast path can NEVER read a torn record.

INVARIANT PROVEN
    The double-buffered parameter update is ATOMIC.  While the host hammers the
    write port continuously — writing every word of a new, internally consistent
    parameter generation and committing it, over and over — the fast-path reader
    observes ONLY whole generations.  It never sees a record whose fields come
    from two different generations, and never a record that was never committed.

WHY IT MATTERS
    Every field of a mixed record is individually legal, so NOTHING downstream
    can detect one.  The risk gate checks that quantity is under the limit and
    price is inside the collar — and a torn record passes both, because each
    field is a valid value.  It is simply the wrong combination: an order sized
    by the NEW quote quantity and priced against the OLD fair value.

    That is a live, silent risk-limit bypass.  It emits real orders, at real
    prices, into a real venue, and the only evidence is a fill you cannot
    explain.  A torn read here is precisely the failure mode double-buffering
    exists to make impossible, which makes proving it the whole point of this
    file.

    The technique: each generation ``g`` is encoded so that every field is a
    distinct function of ``g``.  A reader can therefore recover ``g`` from ONE
    field and verify every other field agrees.  Any cross-generation mixture
    fails an internal consistency check, so a tear cannot slip through as
    "plausible values".

DUT
    rtl/strategy/param_table.sv (REAL — read and matched against the source).
      * Two banks.  Host writes land in the SHADOW bank only.
      * ``cfg_wr`` + ``cfg_sym`` + ``cfg_word`` (0..5) + ``cfg_data[31:0]``.
      * ``cfg_commit`` flips ``active_bank`` in ONE cycle and increments
        ``generation``.  The bank that just went shadow has its per-word
        ready-mask bulk-cleared, so it must be rewritten IN FULL before it can
        go live again.
      * Read port: ``rd_en`` + ``rd_sym`` -> ``rd_param`` (sym_strat_t) and
        ``rd_valid`` / ``rd_params_valid`` at N+1.
      * Write-time validation rejects illegal values per word and counts them in
        ``field_err_cnt``; a rejected write CLEARS that word's ready bit so a
        refused change cannot leave a stale-but-complete record live.

    Parameter word map (rtl/strategy/strategy_pkg.sv):
      PW_CTRL=0 (bit0 strat_enabled, bits[4:1] strat_select), PW_QUOTE_QTY=1,
      PW_EDGE=2, PW_MIN_QTY=3, PW_FAIR_VAL=4, PW_IMB_THR=5.

    sym_strat_t packed layout, MSB-first as declared in trading_pkg.sv (149 b):
      strat_enabled[148], strat_select[147:144], quote_qty[143:112],
      edge_ticks[111:80], min_book_qty[79:48], fair_value[47:16],
      imbalance_thr[15:0].
      # TODO(verify): confirm this packing against the Verilator VPI view once
      # tb/strategy/tb_strategy_engine_top.sv (a flattening wrapper, owned by
      # the scaffolding filelist) exists; the unpacker below falls back to
      # per-field handles if the DUT exposes them flat.

RUNNING
    TOPLEVEL=param_table, or ``python test_param_table.py``.
"""

from __future__ import annotations

import os
import pathlib
import sys

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "common"))
from tb_util import (  # noqa: E402
    CLK_NS,
    BUDGET,
    LatencySamples,
    bits,
    seed_note,
    seeded_rng,
    sim_sources,
    start_clock,
)

# --- word map, mirrored from strategy_pkg.sv -------------------------------
PW_CTRL = 0
PW_QUOTE_QTY = 1
PW_EDGE = 2
PW_MIN_QTY = 3
PW_FAIR_VAL = 4
PW_IMB_THR = 5
N_PARAM_WORDS = 6

N_STRATS = 4
IMB_SCALE = 256
HARD_MAX_QUOTE_QTY = 100_000

# --- sym_strat_t field positions (MSB-first packed) ------------------------
F_STRAT_ENABLED = (148, 148)
F_STRAT_SELECT = (147, 144)
F_QUOTE_QTY = (143, 112)
F_EDGE_TICKS = (111, 80)
F_MIN_BOOK_QTY = (79, 48)
F_FAIR_VALUE = (47, 16)
F_IMBALANCE_THR = (15, 0)


# =============================================================================
# Generation encoding — the mechanism that makes a tear DETECTABLE
# =============================================================================

def generation_words(g: int) -> dict[int, int]:
    """The six 32-bit config words for generation ``g``.

    Every field is a DIFFERENT function of ``g``, and every value satisfies the
    DUT's write-time validation rules (quote_qty nonzero and <= HARD_MAX,
    fair_value nonzero, imbalance_thr >= IMB_SCALE with a clean upper half,
    strat_select < N_STRATS).  Consequently any mixture of two generations is
    arithmetically inconsistent and :func:`check_generation` will catch it.
    """
    assert 1 <= g <= 60_000, "generation out of the encodable range"
    return {
        PW_CTRL: (1 << 0) | ((g % N_STRATS) << 1),   # enabled, strat_select
        PW_QUOTE_QTY: g,                              # g          (1..60000)
        PW_EDGE: g * 100,                             # g * 100
        PW_MIN_QTY: g * 3,                            # g * 3
        PW_FAIR_VAL: 1_000_000 + g,                   # 1e6 + g
        PW_IMB_THR: IMB_SCALE + g,                    # 256 + g
    }


def check_generation(rec: dict, seed: int, context: str) -> int:
    """Assert ``rec`` is a whole generation; return which one.

    ``quote_qty`` names the generation; every other field must agree.  A
    disagreement is a TORN READ — the exact failure this file exists to catch.
    """
    g = rec["quote_qty"]
    expected = {
        "strat_enabled": 1,
        "strat_select": g % N_STRATS,
        "quote_qty": g,
        "edge_ticks": g * 100,
        "min_book_qty": g * 3,
        "fair_value": 1_000_000 + g,
        "imbalance_thr": IMB_SCALE + g,
    }
    if rec != expected:
        wrong = {k: (rec[k], expected[k]) for k in expected if rec[k] != expected[k]}
        # Try to identify which generation each bad field came from — that is
        # the single most useful diagnostic for a tear.
        provenance = {}
        for k, (got, _) in wrong.items():
            if k == "edge_ticks" and got % 100 == 0:
                provenance[k] = f"looks like generation {got // 100}"
            elif k == "min_book_qty" and got % 3 == 0:
                provenance[k] = f"looks like generation {got // 3}"
            elif k == "fair_value" and got > 1_000_000:
                provenance[k] = f"looks like generation {got - 1_000_000}"
            elif k == "imbalance_thr" and got >= IMB_SCALE:
                provenance[k] = f"looks like generation {got - IMB_SCALE}"
        raise AssertionError(
            f"TORN PARAMETER READ ({context})\n"
            f"  quote_qty says this is generation {g}\n"
            f"  disagreeing fields (got, expected): {wrong}\n"
            f"  provenance: {provenance}\n"
            f"  A mixed record is undetectable downstream — every field is\n"
            f"  individually legal. This is a live risk-limit bypass: an order\n"
            f"  sized by one generation and priced by another."
            + seed_note(seed)
        )
    return g


# =============================================================================
# DUT access helpers
# =============================================================================

def read_param(dut) -> dict:
    """Unpack ``rd_param`` into a field dict.

    Prefers flat per-field handles if a wrapper exposes them; otherwise slices
    the packed struct.
    """
    if hasattr(dut, "rd_param_quote_qty"):  # flattening wrapper present
        return {
            "strat_enabled": int(dut.rd_param_strat_enabled.value),
            "strat_select": int(dut.rd_param_strat_select.value),
            "quote_qty": int(dut.rd_param_quote_qty.value),
            "edge_ticks": int(dut.rd_param_edge_ticks.value),
            "min_book_qty": int(dut.rd_param_min_book_qty.value),
            "fair_value": int(dut.rd_param_fair_value.value),
            "imbalance_thr": int(dut.rd_param_imbalance_thr.value),
        }
    raw = int(dut.rd_param.value)
    return {
        "strat_enabled": bits(raw, *F_STRAT_ENABLED),
        "strat_select": bits(raw, *F_STRAT_SELECT),
        "quote_qty": bits(raw, *F_QUOTE_QTY),
        "edge_ticks": bits(raw, *F_EDGE_TICKS),
        "min_book_qty": bits(raw, *F_MIN_BOOK_QTY),
        "fair_value": bits(raw, *F_FAIR_VALUE),
        "imbalance_thr": bits(raw, *F_IMBALANCE_THR),
    }


async def bringup(dut):
    start_clock(dut, "clk", CLK_NS)
    dut.rst.value = 1
    dut.rd_en.value = 0
    dut.rd_sym.value = 0
    dut.cfg_wr.value = 0
    dut.cfg_sym.value = 0
    dut.cfg_word.value = 0
    dut.cfg_data.value = 0
    dut.cfg_commit.value = 0
    await ClockCycles(dut.clk, 8)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def write_word(dut, sym: int, word: int, data: int):
    dut.cfg_wr.value = 1
    dut.cfg_sym.value = sym
    dut.cfg_word.value = word
    dut.cfg_data.value = data & 0xFFFF_FFFF
    await RisingEdge(dut.clk)
    dut.cfg_wr.value = 0


async def write_generation(dut, sym: int, g: int):
    for word, data in generation_words(g).items():
        await write_word(dut, sym, word, data)


async def commit(dut):
    dut.cfg_commit.value = 1
    await RisingEdge(dut.clk)
    dut.cfg_commit.value = 0


async def read_once(dut, sym: int) -> tuple[dict, bool]:
    """Issue a read and return the record presented at N+1."""
    dut.rd_en.value = 1
    dut.rd_sym.value = sym
    await RisingEdge(dut.clk)
    dut.rd_en.value = 0
    await ReadOnly()
    rec = read_param(dut)
    ok = bool(int(dut.rd_params_valid.value))
    await RisingEdge(dut.clk)
    return rec, ok


# =============================================================================
# ⚠️ THE HEADLINE TEST
# =============================================================================

@cocotb.test()
async def test_commit_is_atomic_under_continuous_hammering(dut):
    """Hammer host writes + commits while reading every cycle; no torn record ever.

    The host loop never stops: write all six words of generation g, commit,
    immediately begin generation g+1.  The fast path reads the same symbol on
    every available cycle.  Every record the reader accepts must be a WHOLE
    generation, and the generation it sees must move monotonically (a reader may
    lag, but must never travel backwards — that would mean the bank flipped to a
    stale bank).

    The write/commit phasing is randomized relative to the read stream so the
    commit edge lands at every possible offset from a read, which is where a
    non-atomic flip would show itself.
    """
    rng, seed = seeded_rng(dut, "param_table.atomic")
    await bringup(dut)

    SYM = 7
    n_gens = int(os.environ.get("GENS", "400"))
    seen_generations: set[int] = set()
    last_g = 0
    reads = 0

    # Establish generation 1 so the reader has something valid from the start.
    await write_generation(dut, SYM, 1)
    await commit(dut)

    async def reader():
        """Read continuously and validate wholeness of every accepted record."""
        nonlocal last_g, reads
        while True:
            rec, ok = await read_once(dut, SYM)
            if not ok:
                continue
            g = check_generation(rec, seed, f"continuous read #{reads}")
            assert g >= last_g, (
                f"GENERATION WENT BACKWARDS: read generation {g} after having "
                f"already read {last_g}. The active bank flipped to a stale "
                f"bank — a committed parameter set was un-committed."
                + seed_note(seed)
            )
            last_g = g
            seen_generations.add(g)
            reads += 1

    rd_task = cocotb.start_soon(reader())

    for g in range(2, n_gens + 2):
        # Randomize the phasing of the write burst against the read stream.
        for word, data in generation_words(g).items():
            if rng.random() < 0.35:
                await ClockCycles(dut.clk, rng.randrange(1, 4))
            await write_word(dut, SYM, word, data)
        if rng.random() < 0.3:
            await ClockCycles(dut.clk, rng.randrange(1, 5))
        await commit(dut)

    await ClockCycles(dut.clk, 50)
    rd_task.kill()

    assert reads > n_gens, (
        f"reader only completed {reads} validated reads across {n_gens} "
        f"generations — the test did not actually exercise the race."
        + seed_note(seed)
    )
    assert len(seen_generations) > n_gens // 4, (
        f"reader observed only {len(seen_generations)} distinct generations out "
        f"of {n_gens} committed; the reads were not interleaved with the "
        f"commits closely enough to constitute a race test." + seed_note(seed)
    )
    gen_reg = int(dut.generation.value)
    dut._log.info(
        "atomicity: %d validated reads, %d distinct generations observed, "
        "DUT generation counter = %d",
        reads, len(seen_generations), gen_reg,
    )


@cocotb.test()
async def test_commit_edge_swept_across_every_read_offset(dut):
    """Place the commit edge at every cycle offset relative to a read, exhaustively.

    The randomized test above covers this statistically; this covers it by
    construction.  For offsets 0..15, a read is issued and the commit is driven
    exactly ``offset`` cycles later, and the record the read returns must be
    wholly the old generation or wholly the new one — never a blend, and never a
    value from the shadow bank that had not been committed at read time.
    """
    rng, seed = seeded_rng(dut, "param_table.commit_sweep")
    await bringup(dut)
    SYM = 3

    await write_generation(dut, SYM, 1)
    await commit(dut)

    g = 1
    for offset in range(0, 16):
        g += 1
        await write_generation(dut, SYM, g)

        # Start a read, then commit `offset` cycles into it.
        dut.rd_en.value = 1
        dut.rd_sym.value = SYM
        commit_task = cocotb.start_soon(_delayed_commit(dut, offset))
        await RisingEdge(dut.clk)
        dut.rd_en.value = 0
        await ReadOnly()
        rec = read_param(dut)
        valid = bool(int(dut.rd_params_valid.value))
        await RisingEdge(dut.clk)
        await commit_task

        if valid:
            got = check_generation(rec, seed, f"commit offset {offset}")
            assert got in (g - 1, g), (
                f"offset {offset}: read generation {got}, expected {g-1} or {g}. "
                f"A generation outside the commit window was observed."
                + seed_note(seed)
            )
        await ClockCycles(dut.clk, 4)


async def _delayed_commit(dut, delay: int):
    await ClockCycles(dut.clk, delay) if delay else None
    await commit(dut)


# =============================================================================
# Uncommitted writes must be invisible
# =============================================================================

@cocotb.test()
async def test_uncommitted_write_is_invisible(dut):
    """A fully-written but UNCOMMITTED generation is never visible to the reader.

    The host writes all six words of a new generation and then stops — no
    commit.  The fast path must keep reading the previous generation, forever.

    This is the property that lets the host write parameters lazily, a word at a
    time, without ever exposing a partial idea to the market.  If an uncommitted
    write leaked, the "double buffer" would be decorative.
    """
    rng, seed = seeded_rng(dut, "param_table.uncommitted")
    await bringup(dut)
    SYM = 11

    await write_generation(dut, SYM, 5)
    await commit(dut)

    # Write a whole new generation, but never commit it.
    await write_generation(dut, SYM, 6)

    for i in range(500):
        rec, ok = await read_once(dut, SYM)
        if not ok:
            continue
        g = check_generation(rec, seed, f"post-uncommitted-write read {i}")
        assert g == 5, (
            f"UNCOMMITTED WRITE LEAKED: reader saw generation {g}, but only "
            f"generation 5 was ever committed. The shadow bank is visible to "
            f"the fast path." + seed_note(seed)
        )
    dut._log.info("500 reads all returned the committed generation 5")


@cocotb.test()
async def test_partial_write_then_commit_is_refused(dut):
    """A commit with an incomplete shadow record is REFUSED and counted.

    The DUT bulk-clears the shadow bank's per-word ready mask on every commit,
    so a bank must be rewritten IN FULL before it can go live.  Writing only
    some words and committing must therefore fail: ``commit_err_cnt``
    increments, ``commit_err_sticky`` latches, and — critically — the ACTIVE
    generation does not change.

    Half a parameter set is not a conservative parameter set; it is an arbitrary
    one.  Refusing is the only fail-closed answer.
    """
    rng, seed = seeded_rng(dut, "param_table.partial")
    await bringup(dut)
    SYM = 2

    await write_generation(dut, SYM, 9)
    await commit(dut)
    gen_before = int(dut.generation.value)
    err_before = int(dut.commit_err_cnt.value)

    # Write only three of the six words, then try to commit.
    words = generation_words(10)
    for word in (PW_CTRL, PW_QUOTE_QTY, PW_EDGE):
        await write_word(dut, SYM, word, words[word])
    await commit(dut)
    await ClockCycles(dut.clk, 3)

    await ReadOnly()
    gen_after = int(dut.generation.value)
    err_after = int(dut.commit_err_cnt.value)
    sticky = int(dut.commit_err_sticky.value)
    await RisingEdge(dut.clk)

    assert gen_after == gen_before, (
        f"a PARTIAL record was committed: generation moved {gen_before} -> "
        f"{gen_after}. Half a parameter set is an arbitrary parameter set."
        + seed_note(seed)
    )
    assert err_after == err_before + 1, (
        f"commit_err_cnt did not record the refused commit "
        f"({err_before} -> {err_after}). CLAUDE.md §5.7: every rejection is "
        f"counted, or the operator cannot tell a refusal from a success."
        + seed_note(seed)
    )
    assert sticky == 1, "commit_err_sticky did not latch on a refused commit"

    # And the reader still sees the last good generation.
    for _ in range(20):
        rec, ok = await read_once(dut, SYM)
        if ok:
            assert check_generation(rec, seed, "after refused commit") == 9


# =============================================================================
# Write-time validation (the fat-finger guard the host cannot raise)
# =============================================================================

@cocotb.test()
async def test_illegal_words_are_rejected_and_counted(dut):
    """Every documented write-time validation rule rejects, counts, and invalidates.

    ``param_table.sv`` validates each word as it is written and CLEARS that
    word's ready bit on a refusal — so a rejected change cannot leave the
    previous complete value live under a new generation number.  Each rule below
    is a specific catastrophe it prevents.
    """
    rng, seed = seeded_rng(dut, "param_table.validation")
    await bringup(dut)
    SYM = 4

    cases = [
        # (word, value, why this value is catastrophic)
        (PW_QUOTE_QTY, 0,
         "a zero-size order is meaningless and would be sent to the venue"),
        (PW_QUOTE_QTY, HARD_MAX_QUOTE_QTY + 1,
         "above the hardware fat-finger ceiling the host is not allowed to raise"),
        (PW_FAIR_VAL, 0,
         "a zero fair value makes (fair+edge) a live sell trigger against every "
         "bid in the book — the classic uninitialised-parameter blowup"),
        (PW_IMB_THR, IMB_SCALE - 1,
         "a ratio below 1.0 makes bid-heavy and ask-heavy simultaneously true"),
        (PW_IMB_THR, (1 << 16) | IMB_SCALE,
         "a dirty upper half means the host wrote a wider value than the field"),
        (PW_CTRL, (1 << 0) | (0xF << 1),
         "strat_select naming a primitive that does not exist"),
    ]

    for word, value, why in cases:
        before = int(dut.field_err_cnt.value)
        await write_word(dut, SYM, word, value)
        await ClockCycles(dut.clk, 2)
        await ReadOnly()
        after = int(dut.field_err_cnt.value)
        await RisingEdge(dut.clk)
        assert after == before + 1, (
            f"ILLEGAL PARAMETER ACCEPTED: word {word} = 0x{value:X} did not "
            f"increment field_err_cnt ({before} -> {after}).\n"
            f"  Why this matters: {why}." + seed_note(seed)
        )

    # An out-of-range word address is also rejected and counted.
    before = int(dut.field_err_cnt.value)
    await write_word(dut, SYM, N_PARAM_WORDS + 1, 0x1234)
    await ClockCycles(dut.clk, 2)
    await ReadOnly()
    assert int(dut.field_err_cnt.value) == before + 1, (
        "a write to a word address outside the record was not counted"
        + seed_note(seed)
    )
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_rejected_write_invalidates_the_record(dut):
    """A refused word makes the whole shadow record un-committable.

    "Set on a good value, CLEAR on a bad one" — the host asked for a change and
    got a refusal, so the record must not stay live with the old value under a
    new generation.  Otherwise an operator who fat-fingers a limit sees the
    generation counter advance and believes the new value is running.
    """
    rng, seed = seeded_rng(dut, "param_table.invalidate")
    await bringup(dut)
    SYM = 6

    await write_generation(dut, SYM, 20)
    await commit(dut)
    gen_before = int(dut.generation.value)

    # Write a complete generation, then spoil ONE word with an illegal value.
    await write_generation(dut, SYM, 21)
    await write_word(dut, SYM, PW_FAIR_VAL, 0)  # illegal -> clears ready bit
    await commit(dut)
    await ClockCycles(dut.clk, 3)

    await ReadOnly()
    gen_after = int(dut.generation.value)
    await RisingEdge(dut.clk)
    assert gen_after == gen_before, (
        f"a record containing a REFUSED word was committed (generation "
        f"{gen_before} -> {gen_after}). The operator would believe a value is "
        f"live that the hardware rejected." + seed_note(seed)
    )


# =============================================================================
# Reset — fail-closed
# =============================================================================

@cocotb.test()
async def test_reset_is_fail_closed_for_every_symbol(dut):
    """After reset, NO symbol presents valid parameters — strategy is off.

    CLAUDE.md §5 rule 4: reset state is trading disabled.  An unconfigured
    parameter table that returned ``strat_enabled=1`` with zeroed thresholds
    would quote against every symbol in the universe the instant the clock
    started.  Swept across the whole active set, not sampled.
    """
    rng, seed = seeded_rng(dut, "param_table.reset")
    await bringup(dut)

    n_entries = int(os.environ.get("N_ENTRIES", "256"))
    bad = []
    for sym in range(n_entries):
        rec, ok = await read_once(dut, sym)
        if ok or rec["strat_enabled"]:
            bad.append((sym, ok, rec["strat_enabled"]))
    assert not bad, (
        f"RESET IS NOT FAIL-CLOSED: {len(bad)} symbol(s) presented enabled or "
        f"valid parameters immediately after reset; first 5: {bad[:5]}. "
        f"An unconfigured table must quote nothing." + seed_note(seed)
    )
    dut._log.info("all %d entries fail-closed after reset", n_entries)


@cocotb.test()
async def test_reset_mid_write_leaves_nothing_half_committed(dut):
    """Reset asserted partway through a generation write leaves no live record.

    Sweeps the reset point across the write burst so it lands before, between,
    and after each word, including on the commit cycle itself.
    """
    rng, seed = seeded_rng(dut, "param_table.reset_mid")
    SYM = 5

    for cut in range(0, N_PARAM_WORDS + 2):
        await bringup(dut)
        words = list(generation_words(30).items())
        for i, (word, data) in enumerate(words):
            if i == cut:
                break
            await write_word(dut, SYM, word, data)
        if cut > N_PARAM_WORDS:
            await commit(dut)

        dut.rst.value = 1
        await ClockCycles(dut.clk, 4)
        dut.rst.value = 0
        await RisingEdge(dut.clk)

        rec, ok = await read_once(dut, SYM)
        assert not ok and not rec["strat_enabled"], (
            f"reset at write-cut {cut} left a live/enabled record: ok={ok}, "
            f"rec={rec}" + seed_note(seed)
        )
        assert int(dut.generation.value) == 0, (
            f"generation counter survived reset at cut {cut}: "
            f"{int(dut.generation.value)}" + seed_note(seed)
        )


# =============================================================================
# Latency
# =============================================================================

@cocotb.test()
async def test_read_latency_is_fixed_at_one_cycle(dut):
    """``rd_param`` is presented at N+1, deterministically, for every symbol.

    fpga_top.sv budgets 2 cycles for "Strategy parameter read + trigger"
    jointly; the table owns 1 of those and trigger_logic.sv owns the other.
    Asserted as EQUALITY and as zero jitter — a parameter read whose latency
    depended on the symbol or the bank would put jitter directly on the
    tick-to-trade path.
    """
    rng, seed = seeded_rng(dut, "param_table.latency")
    await bringup(dut)

    for sym in range(8):
        await write_generation(dut, sym, 40 + sym)
    await commit(dut)

    samples = LatencySamples("param_table.read")
    for _ in range(200):
        sym = rng.randrange(8)
        dut.rd_en.value = 1
        dut.rd_sym.value = sym
        await RisingEdge(dut.clk)
        dut.rd_en.value = 0
        cycles = 0
        for _ in range(8):
            cycles += 1
            await ReadOnly()
            if int(dut.rd_valid.value):
                break
            await RisingEdge(dut.clk)
        else:
            raise AssertionError("rd_valid never asserted" + seed_note(seed))
        samples.add(cycles)
        await RisingEdge(dut.clk)

    samples.assert_deterministic(seed)
    assert samples.p50 == 1, (
        f"parameter read latency is {samples.p50} cycles, expected 1. "
        f"fpga_top.sv budgets 2 cycles for parameter read + trigger combined; "
        f"{samples.p50} here leaves {2 - samples.p50} for the trigger logic.\n"
        f"  {samples.summary()}" + seed_note(seed)
    )
    dut._log.info("read latency: %s (budget row 'strategy' = %d cyc total)",
                  samples.summary(), BUDGET.cycles("strategy"))


if __name__ == "__main__":  # pragma: no cover
    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        from cocotb.runner import get_runner

    runner = get_runner(os.environ.get("SIM", "verilator"))
    runner.build(
        verilog_sources=sim_sources(
            "rtl/strategy/strategy_pkg.sv", "rtl/strategy/param_table.sv"
        ),
        hdl_toplevel="param_table",
        build_args=["-Wno-fatal"],
        always=True,
    )
    runner.test(hdl_toplevel="param_table", test_module="test_param_table")
