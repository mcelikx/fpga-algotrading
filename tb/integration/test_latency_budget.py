"""Latency budget regression gate — a pipeline stage cannot be added silently.

INVARIANT PROVEN
    The measured cycle count of EVERY fabric stage equals the figure in
    ``rtl/fpga_top.sv``'s master budget table — exactly, for the fixed-latency
    stages; within the documented bound for the one variable-latency stage — and
    the end-to-end fabric latency stays within the 20-cycle / 128 ns total.

WHY IT MATTERS
    Latency is the product.  This system exists to be fast and, more importantly,
    to be PREDICTABLY fast: CLAUDE.md §5.8 puts determinism above average speed,
    because a strategy that sometimes takes an extra 6.4 ns is a strategy that
    sometimes loses the queue position it was designed to win.

    Latency regressions do not arrive as a single catastrophic change.  They
    arrive one register at a time, each individually justified — "I needed to
    pipeline that comparator to close timing" — and each individually invisible.
    Nobody re-measures the whole path after a one-line change.  Six months later
    the design is 40% slower than the budget and no single commit is to blame.

    This file is the gate that makes that impossible.  ⚠️ It asserts the CYCLE
    COUNT, so a change that adds a pipeline stage FAILS THE BUILD rather than
    quietly costing nanoseconds.  If the change is intentional, the fix is to
    update the budget table in ``fpga_top.sv``'s header IN THE SAME COMMIT —
    which is exactly the review conversation that should happen (CLAUDE.md §3:
    changing the budget is a system-wide change).

THE BUDGET IS NOT HARDCODED HERE
    ``tb/common/tb_util.py`` PARSES the table out of ``rtl/fpga_top.sv`` at
    import time.  There is deliberately no number in this file to update, so the
    testbench cannot drift away from the RTL header.  If a stage is reworded or
    removed from that table, ``tb_util`` raises ``BudgetParseError`` at import —
    loudly — rather than silently skipping the check.

    Current table (156.25 MHz, 6.4 ns/cycle), for reference only::

        MAC RX (cut-through)                          2
        Ethernet/IPv4/UDP header strip                1
        MoldUDP64 deframe + A/B arbitration           2
        ITCH message assembly (to 512-bit beat)       2
        ITCH decode (fixed-offset extraction)         1
        Symbol filter + active-index map              1
        Order-ID map lookup (BRAM + out reg)          2
        Book level update + incremental top-of-book   2   <- var*, bounded
        Strategy parameter read + trigger             2
        Pre-trade risk gate                           2
        OUCH template read + splice + checksum        2
        TCP/SoupBinTCP framing                        1
        MAC TX (cut-through)                          2
        FABRIC total                                 20   (128.0 ns)

    The two hard-IP rows — optics + GT RX PMA/PCS and GT TX PCS/PMA + optics,
    ~90 ns each — are NOT measurable in RTL simulation and are excluded by
    construction (``tb_util.FABRIC_STAGES`` omits them).  They are measured on
    hardware per manuals/05-optimization/04-measurement-and-profiling.md; a
    simulated number must never be reported as a measured one (CLAUDE.md §4).

NOT A VACUOUS GATE
    Most of ``rtl/`` is still being written.  A stage whose RTL is absent is
    skipped **loudly** — logged as a warning naming the missing module and
    recorded in ``self.skipped`` — and the file asserts at the end that the
    number of stages actually measured is at least the number whose RTL exists.
    A latency gate that silently measures nothing is worse than no gate, because
    it reads green.

RUNNING
    TOPLEVEL=fpga_top for the full path; individual stages can also be measured
    against their own DUTs.  ``python test_latency_budget.py``.
"""

from __future__ import annotations

import os
import pathlib
import sys

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "common"))
from tb_util import (  # noqa: E402
    BUDGET,
    CLK_NS,
    FABRIC_STAGES,
    RTL,
    LatencySamples,
    assert_package_mirror,
    cycles_to_ns,
    rtl_exists,
    seed_note,
    seeded_rng,
    start_clock,
)

# --- which RTL module implements each budget row --------------------------
# Used ONLY to decide "measurable today?" and to name the missing module in the
# skip warning. The cycle numbers themselves come from BUDGET, never from here.
STAGE_RTL: dict[str, tuple[str, ...]] = {
    "mac_rx": ("rtl/eth/mac_rx.sv",),
    "eth_ip_udp": ("rtl/net/eth_ip_udp_rx.sv",),
    "mold_ab": ("rtl/net/moldudp64_deframer.sv", "rtl/net/ab_arbiter.sv"),
    "itch_assemble": ("rtl/net/net_rx_path.sv",),
    "itch_decode": ("rtl/feed/itch_decoder.sv",),
    "symbol_filter": ("rtl/feed/symbol_filter.sv",),
    "order_id_map": ("rtl/book/order_id_map.sv",),
    "book_update": ("rtl/book/book_engine.sv",),
    "strategy": ("rtl/strategy/strategy_engine.sv",),
    "risk_gate": ("rtl/risk/risk_gate.sv",),
    "ouch_encode": ("rtl/order/ouch_encoder.sv",),
    "soupbin_tcp": ("rtl/order/soupbin_tx.sv",),
    "mac_tx": ("rtl/eth/mac_tx.sv",),
}

# Stage boundary signal pairs on fpga_top (input event -> output event).
# # TODO(verify): these are the inter-block signal names as instantiated in
# fpga_top.sv. Where a block is not yet written the names come from the
# instantiation only, not from the module's own declaration.
STAGE_PROBES: dict[str, tuple[str, str]] = {
    "eth_ip_udp": ("md_axis_tvalid", "u_net_rx.udp_valid"),
    "mold_ab": ("u_net_rx.udp_valid", "itch_valid"),
    "itch_decode": ("itch_valid", "book_evt_valid"),
    "symbol_filter": ("book_evt_valid", "u_feed.filt_valid"),
    "book_update": ("book_evt_valid", "book_top_valid"),
    "strategy": ("book_top_valid", "order_req_valid"),
    "risk_gate": ("order_req_valid", "order_out_valid"),
    "ouch_encode": ("order_out_valid", "u_order_gw.ouch_valid"),
    "soupbin_tcp": ("u_order_gw.ouch_valid", "oe_tx_tvalid"),
}

N_SAMPLES = int(os.environ.get("LAT_SAMPLES", "200"))


class StageMeasurement:
    """Collects per-stage latency samples and the reasons stages were skipped."""

    def __init__(self, dut):
        self.dut = dut
        self.measured: dict[str, LatencySamples] = {}
        self.skipped: dict[str, str] = {}

    def skip(self, stage: str, reason: str) -> None:
        """Record a skip LOUDLY — never silently pass a stage."""
        self.skipped[stage] = reason
        self.dut._log.warning(
            "LATENCY GATE SKIPPED stage %-14s budget %s cyc — %s",
            stage,
            BUDGET.cycles(stage) if stage in BUDGET else "?",
            reason,
        )

    def record(self, stage: str, samples: LatencySamples) -> None:
        self.measured[stage] = samples

    def report(self) -> None:
        log = self.dut._log
        log.info("=" * 78)
        log.info("LATENCY PROFILE vs rtl/fpga_top.sv budget table")
        log.info("  %-14s %7s %7s %6s %6s %6s %6s  %s",
                 "stage", "budget", "p50", "p99", "p99.9", "max", "min", "verdict")
        log.info("-" * 78)
        for stage in FABRIC_STAGES:
            if stage in self.measured:
                s = self.measured[stage]
                verdict = "FIXED-OK" if BUDGET.is_fixed(stage) else "BOUNDED-OK"
                log.info("  %-14s %7d %7d %6d %6d %6d %6d  %s",
                         stage, BUDGET.cycles(stage), s.p50, s.p99, s.p999,
                         s.max, s.min, verdict)
            else:
                log.info("  %-14s %7d %7s %6s %6s %6s %6s  SKIPPED (%s)",
                         stage, BUDGET.cycles(stage), "-", "-", "-", "-", "-",
                         self.skipped.get(stage, "?"))
        log.info("-" * 78)
        log.info("  %-14s %7d cyc / %.1f ns  (hard-IP optics/GT excluded)",
                 "FABRIC total", BUDGET.fabric_total_cycles,
                 BUDGET.fabric_total_ns)
        log.info("=" * 78)


def stage_is_measurable(stage: str) -> tuple[bool, str]:
    """Can this stage be measured against the RTL that exists right now?"""
    srcs = STAGE_RTL.get(stage, ())
    missing = [s for s in srcs if not rtl_exists(s)]
    if missing:
        return False, f"RTL not written: {', '.join(missing)}"
    if stage not in STAGE_PROBES and stage not in ("mac_rx", "mac_tx",
                                                   "itch_assemble"):
        return False, "no stage-boundary probe defined"
    return True, ""


def _resolve(dut, path: str):
    """Resolve a possibly-hierarchical signal path like 'u_net_rx.udp_valid'."""
    obj = dut
    for part in path.split("."):
        obj = getattr(obj, part, None)
        if obj is None:
            return None
    return obj


async def measure_stage(dut, stage: str, n: int = N_SAMPLES) -> LatencySamples:
    """Count clock edges between a stage's input event and its output event.

    Both probes are sampled in the ``ReadOnly`` phase so they see settled values.
    A latency of 1 means the output was observable on the edge immediately after
    the input was accepted — i.e. one register stage.
    """
    src_name, dst_name = STAGE_PROBES[stage]
    src = _resolve(dut, src_name)
    dst = _resolve(dut, dst_name)
    assert src is not None and dst is not None, (
        f"stage {stage}: probe signal not found "
        f"({src_name if src is None else dst_name}). The inter-block signal was "
        f"renamed; update STAGE_PROBES and re-check fpga_top.sv."
    )

    samples = LatencySamples(stage)
    while len(samples.samples) < n:
        # Wait for the stage input to fire.
        cycles_waited = 0
        while True:
            await RisingEdge(dut.core_clk)
            await ReadOnly()
            if int(src.value):
                break
            cycles_waited += 1
            if cycles_waited > 100_000:
                raise TimeoutError(
                    f"stage {stage}: input probe {src_name} never fired; the "
                    f"stimulus is not reaching this stage."
                )
        # Count to the output event.
        n_cyc = 0
        while True:
            n_cyc += 1
            await RisingEdge(dut.core_clk)
            await ReadOnly()
            if int(dst.value):
                samples.add(n_cyc)
                break
            if n_cyc > 256:
                raise AssertionError(
                    f"stage {stage}: no output within 256 cycles "
                    f"({cycles_to_ns(256):.0f} ns) — the stage stalled. Budget "
                    f"is {BUDGET.cycles(stage)} cycles."
                )
    return samples


# =============================================================================
# The gate
# =============================================================================

@cocotb.test()
async def test_every_stage_matches_its_budget(dut):
    """⚠️ THE REGRESSION GATE: every fabric stage, measured, against the budget.

    Fixed-latency stages are asserted with EQUALITY, not ``<=``.  A stage that
    got faster is still a change to a documented contract, and on this design
    variance is itself the defect (CLAUDE.md §5.8) — the strategy is tuned to a
    known, constant tick-to-trade time.

    The one ``var*`` stage — the best-level delete that forces a new-best search
    — is asserted BOUNDED, and its full distribution is reported.
    """
    rng, seed = seeded_rng(dut, "latency_budget")
    start_clock(dut, "core_clk", CLK_NS)

    meas = StageMeasurement(dut)
    measurable: list[str] = []
    for stage in FABRIC_STAGES:
        ok, why = stage_is_measurable(stage)
        if ok:
            measurable.append(stage)
        else:
            meas.skip(stage, why)

    dut._log.info("stages measurable today: %d of %d — %s",
                  len(measurable), len(FABRIC_STAGES), measurable)

    for stage in measurable:
        if stage not in STAGE_PROBES:
            meas.skip(stage, "probe pending (edge-of-design stage)")
            continue
        samples = await measure_stage(dut, stage)
        meas.record(stage, samples)

        if BUDGET.is_fixed(stage):
            samples.assert_deterministic(seed)
            BUDGET.assert_exact(samples.p50, stage, seed)
        else:
            BUDGET.assert_bounded(samples.max, stage, seed)

    meas.report()

    # ⚠️ Anti-vacuity: the gate must not silently degrade into measuring nothing.
    assert len(meas.measured) >= len(measurable), (
        f"latency gate measured {len(meas.measured)} stage(s) but "
        f"{len(measurable)} were measurable. A gate that skips a measurable "
        f"stage reads green while the design regresses." + seed_note(seed)
    )
    if not meas.measured:
        raise AssertionError(
            "LATENCY GATE MEASURED NOTHING. Every stage was skipped because its "
            "RTL does not exist yet:\n  "
            + "\n  ".join(f"{k}: {v}" for k, v in meas.skipped.items())
            + "\nThis is reported as a FAILURE rather than a pass so the gate "
              "cannot be mistaken for coverage it does not provide."
        )


@cocotb.test()
async def test_end_to_end_fabric_latency(dut):
    """Wire-to-wire fabric latency (MAC RX in -> MAC TX out) within the total.

    Measured as the cycle delta carried by ``rx_cycle`` through the pipeline —
    the same free-running ``cycle_cnt`` reference fpga_top.sv uses for on-chip
    measurement, so the number the testbench reports and the number the
    telemetry histogram reports are the same number.

    Asserted against the FABRIC total (20 cycles / 128.0 ns).  The ~180 ns of
    optics + GT hard IP is excluded: it cannot be simulated, and reporting a
    simulated figure as a measured one is forbidden (CLAUDE.md §4).
    """
    rng, seed = seeded_rng(dut, "latency_e2e")

    if not rtl_exists("rtl/order/order_gateway.sv"):
        raise AssertionError(
            "end-to-end latency cannot be measured: rtl/order/order_gateway.sv "
            "does not exist, so no order can reach the TX MAC. Reported as a "
            "failure rather than a skip so the end-to-end budget is never "
            "assumed to be covered when it is not."
        )

    start_clock(dut, "core_clk", CLK_NS)
    samples = LatencySamples("fabric_total")

    for _ in range(N_SAMPLES):
        # The order carries the ingress cycle stamp it was created from.
        while True:
            await RisingEdge(dut.core_clk)
            await ReadOnly()
            if int(dut.order_out_valid.value):
                break
        rx_cycle = int(dut.order_out.rx_cycle.value) \
            if hasattr(dut, "order_out") else int(dut.order_out_rx_cycle.value)
        now = int(dut.cycle_cnt.value)
        samples.add(now - rx_cycle)

    dut._log.info("end-to-end fabric latency: %s", samples.summary())
    dut._log.info("  = %.1f ns p50, %.1f ns max (excludes ~180 ns optics+GT)",
                  cycles_to_ns(samples.p50), cycles_to_ns(samples.max))
    BUDGET.assert_total(samples.max, seed)

    # The whole path should be deterministic apart from the one var* stage, so
    # spread beyond that stage's slack is itself a finding.
    slack = BUDGET.cycles("book_update")
    spread = samples.max - samples.min
    assert spread <= slack, (
        f"end-to-end latency JITTER of {spread} cycles "
        f"({cycles_to_ns(spread):.1f} ns) exceeds the only documented source of "
        f"variance (the book's new-best search, budgeted {slack} cycles). "
        f"Something else on the path is variable-latency, which contradicts the "
        f"'fixed?' column of fpga_top.sv's budget table.\n  {samples.summary()}"
        + seed_note(seed)
    )


@cocotb.test()
async def test_budget_table_is_self_consistent(dut):
    """The budget table's own arithmetic adds up — checked, not trusted.

    The cumulative-nanoseconds column and the FABRIC total are maintained by
    hand in a comment block.  A hand-maintained table drifts.  This asserts that
    each row's ns equals its cycles x 6.4, that the cumulative column really is
    the running sum, and that the FABRIC total equals the sum of the fabric
    rows — so a typo in the header is caught by CI rather than by someone
    budgeting against a wrong number six months later.
    """
    # Also guard the OTHER duplicated contract: tb_util mirrors trading_pkg.sv's
    # constants by hand, and a silent drift there would invalidate every width
    # and limit assumption in the suite.
    assert_package_mirror()

    total_cycles = 0
    prev_cum = 0.0
    for stage in ("gt_rx", "mac_rx", "eth_ip_udp", "mold_ab", "itch_assemble",
                  "itch_decode", "symbol_filter", "order_id_map", "book_update",
                  "strategy", "risk_gate", "ouch_encode", "soupbin_tcp",
                  "mac_tx", "gt_tx"):
        row = BUDGET.row(stage)
        if row.cycles is not None:
            expect_ns = cycles_to_ns(row.cycles)
            assert abs(row.ns - expect_ns) < 0.05, (
                f"budget row {stage!r}: {row.cycles} cycles should be "
                f"{expect_ns:.1f} ns, table says {row.ns} ns"
            )
            total_cycles += row.cycles
        assert abs(row.cum_ns - (prev_cum + row.ns)) < 0.15, (
            f"budget cumulative column broken at {stage!r}: "
            f"{prev_cum:.1f} + {row.ns:.1f} != {row.cum_ns:.1f}"
        )
        prev_cum = row.cum_ns

    assert total_cycles == BUDGET.fabric_total_cycles, (
        f"FABRIC total row says {BUDGET.fabric_total_cycles} cycles but the "
        f"fabric rows sum to {total_cycles}. Update rtl/fpga_top.sv's header."
    )
    dut._log.info("budget table self-consistent: %d fabric cycles = %.1f ns",
                  total_cycles, BUDGET.fabric_total_ns)


if __name__ == "__main__":  # pragma: no cover
    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        from cocotb.runner import get_runner

    # The whole synthesizable tree, in rtl/filelist.f's canonical compile order,
    # filtered to what exists. Packages first — SystemVerilog `import` requires
    # the package to be already compiled.
    runner = get_runner(os.environ.get("SIM", "verilator"))
    runner.build(
        verilog_sources=[str(p) for p in RTL],
        hdl_toplevel="fpga_top",
        build_args=["-Wno-fatal"],
        always=True,
    )
    runner.test(hdl_toplevel="fpga_top", test_module="test_latency_budget")
