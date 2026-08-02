"""AXI-Stream driver for cocotb testbenches.

Project : FPGA Algorithmic Trading System (Nasdaq Equities)
Governs : manuals/01-fpga-design/05-verification-and-simulation.md §2
          manuals/01-fpga-design/01-rtl-design-patterns.md  (the stream contract)
          CLAUDE.md §5.4 — "No backpressure stalls into the MAC RX."

Drives 64-bit AXI-Stream beats (``trading_pkg::AXIS_W`` = 64, 8 bytes/cycle at
156.25 MHz = 10 Gbps) with ``tkeep``/``tlast``/``tuser``, configurable inter-beat
and inter-packet gaps, and two distinct backpressure modes.

Byte ordering
-------------
AXI-Stream carries payload byte 0 in ``tdata[7:0]``. Packing a Python
``bytes`` object into an integer therefore uses ``"little"`` byte order, even
though ITCH and OUCH are big-endian **on the wire**. Those are two different
statements about two different things and conflating them is the single most
common testbench bug in this domain:

* wire order   — the order bytes arrive in time. ITCH big-endian fields.
* bus packing  — which lane a given byte lands in. AXI-Stream byte 0 -> LSB.

``itch_gen.py`` produces wire-order ``bytes``. This driver packs those bytes
into beats. Neither one swaps anything.

⚠️ THE NO-BACKPRESSURE CONTRACT
    CLAUDE.md §5.4 and rtl/fpga_top.sv hard rule 1: the receive path must accept
    line rate unconditionally. ``s_axis_rx_tready`` is tied high, always. It
    drops deliberately and counts drops; it never blocks.

    ``mode=NO_BACKPRESSURE`` (the default for anything downstream of a MAC RX)
    therefore does **not** wait for ``tready`` at all. If the DUT ever asserts
    backpressure, that is a *design bug* and the driver raises immediately
    rather than politely stalling and hiding it. A driver that waits for
    ``tready`` on the RX path would make the forbidden behaviour invisible.

    ``mode=HANDSHAKE`` is for genuinely-flow-controlled interfaces — the order
    entry TX path into the MAC, where ``tready`` is real.
"""

from __future__ import annotations

import enum
import random
from typing import Iterable, Sequence

import cocotb
from cocotb.handle import SimHandleBase
from cocotb.triggers import ReadOnly, RisingEdge

# 156.25 MHz core clock, 6.400 ns period. trading_pkg::CORE_CLK_NS.
CLK_PERIOD_NS = 6.400
AXIS_WIDTH_BITS = 64
AXIS_WIDTH_BYTES = AXIS_WIDTH_BITS // 8


class BackpressureMode(enum.Enum):
    """How the driver treats ``tready``."""

    #: RX contract: tready is assumed tied high. Never waits. Raises if the DUT
    #: deasserts tready, because that is forbidden by CLAUDE.md §5.4.
    NO_BACKPRESSURE = "no_backpressure"

    #: Normal AXI-Stream: hold the beat until tready is sampled high.
    HANDSHAKE = "handshake"

    #: Like HANDSHAKE, but tolerates a missing tready port entirely (some DUTs
    #: simply do not have one, which is itself the RX contract expressed in RTL).
    AUTO = "auto"


class AxisDriver:
    """AXI-Stream master.

    Parameters
    ----------
    dut:
        The cocotb DUT handle.
    clk:
        Clock handle to synchronise to.
    prefix:
        Signal-name prefix, e.g. ``"s_axis"`` gives ``s_axis_tdata`` etc.
        TODO(verify): port names follow rtl/fpga_top.sv, where MAC outputs are
        ``m_axis_*`` and block inputs are ``s_axis_*``. Confirm per-block once
        rtl/net/net_rx_path.sv and rtl/eth/mac_rx.sv are final; ``net_rx_path``
        takes *arrays* of these signals (one per feed), so a per-lane driver
        needs ``index=`` to select ``s_axis_tdata[0]`` vs ``[1]``.
    width_bytes:
        Bus width. 8 for the 10GbE 64-bit datapath.
    mode:
        See :class:`BackpressureMode`. Defaults to ``NO_BACKPRESSURE`` because
        the market-data RX path is the overwhelmingly common case in this repo.
    index:
        Optional array index, for the multi-feed ports on ``net_rx_path``.
    rst:
        Optional reset handle; when given, the driver idles while reset is high.
    """

    def __init__(
        self,
        dut: SimHandleBase,
        clk: SimHandleBase,
        prefix: str = "s_axis",
        width_bytes: int = AXIS_WIDTH_BYTES,
        mode: BackpressureMode = BackpressureMode.NO_BACKPRESSURE,
        index: int | None = None,
        rst: SimHandleBase | None = None,
        name: str = "axis_drv",
    ) -> None:
        self.dut = dut
        self.clk = clk
        self.wb = width_bytes
        self.mode = mode
        self.index = index
        self.rst = rst
        self.name = name
        self.log = dut._log

        def sig(suffix: str, required: bool = True):
            handle = getattr(dut, f"{prefix}_{suffix}", None)
            if handle is None:
                if required:
                    raise AttributeError(
                        f"{name}: DUT has no port {prefix}_{suffix}. "
                        f"Check the prefix, or the port names in rtl/."
                    )
                return None
            if index is not None:
                handle = handle[index]
            return handle

        self.tdata = sig("tdata")
        self.tvalid = sig("tvalid")
        self.tkeep = sig("tkeep", required=False)
        self.tlast = sig("tlast", required=False)
        self.tuser = sig("tuser", required=False)
        self.tready = sig("tready", required=False)

        if self.tready is None and mode is BackpressureMode.HANDSHAKE:
            raise AttributeError(
                f"{name}: mode=HANDSHAKE but the DUT has no {prefix}_tready. "
                f"An interface with no tready IS the no-backpressure contract; "
                f"use mode=NO_BACKPRESSURE."
            )

        # Statistics, so a test can assert on what was actually driven rather
        # than on what it thinks it asked for.
        self.beats_sent = 0
        self.packets_sent = 0
        self.bytes_sent = 0

        self._idle()

    # ------------------------------------------------------------------
    def _idle(self) -> None:
        self.tvalid.value = 0
        if self.tlast is not None:
            self.tlast.value = 0
        if self.tuser is not None:
            self.tuser.value = 0
        if self.tkeep is not None:
            self.tkeep.value = 0

    async def _wait_out_of_reset(self) -> None:
        if self.rst is None:
            return
        while True:
            await ReadOnly()
            if not int(self.rst.value):
                break
            await RisingEdge(self.clk)

    # ------------------------------------------------------------------
    async def send(
        self,
        payload: bytes,
        gap_cycles: int = 0,
        tuser_last: int = 0,
        tuser_per_beat: Sequence[int] | None = None,
        rng: random.Random | None = None,
        gap_range: tuple[int, int] | None = None,
    ) -> None:
        """Send one packet as ``ceil(len/width)`` beats, ``tlast`` on the final one.

        Parameters
        ----------
        payload:
            Wire-order bytes. For a market-data frame this is the whole Ethernet
            frame as produced by ``itch_gen.eth_udp_frame``.
        gap_cycles:
            Idle cycles inserted *between* beats. 0 = back-to-back, which is
            line rate for a 64-bit bus at 156.25 MHz.
        tuser_last:
            Value driven on ``tuser`` during the final beat. On the MAC RX
            interface in this design ``tuser`` means **"this frame had a bad
            FCS"** (see rtl/fpga_top.sv: ``md_axis_tuser``), so pass 1 to inject
            a corrupt frame and check the drop counter increments.
        tuser_per_beat:
            Explicit per-beat ``tuser`` values, overriding ``tuser_last``.
        rng / gap_range:
            If both are given, the inter-beat gap is drawn uniformly from
            ``gap_range`` for each beat. ⚠️ The caller must have logged the
            seed — 05-verification §6: "A random failure you cannot reproduce is
            not a finding, it is a rumour."
        """
        await self._wait_out_of_reset()

        n_beats = max(1, (len(payload) + self.wb - 1) // self.wb)
        for i in range(n_beats):
            chunk = payload[i * self.wb : (i + 1) * self.wb]
            is_last = i == n_beats - 1

            # Byte 0 of the payload goes to tdata[7:0] -> pack little-endian.
            self.tdata.value = int.from_bytes(chunk.ljust(self.wb, b"\x00"), "little")
            if self.tkeep is not None:
                self.tkeep.value = (1 << len(chunk)) - 1
            if self.tlast is not None:
                self.tlast.value = 1 if is_last else 0
            if self.tuser is not None:
                if tuser_per_beat is not None:
                    self.tuser.value = int(tuser_per_beat[i])
                else:
                    self.tuser.value = int(tuser_last) if is_last else 0
            self.tvalid.value = 1

            await self._drive_one_beat()

            self.beats_sent += 1
            self.bytes_sent += len(chunk)

            gap = gap_cycles
            if rng is not None and gap_range is not None:
                gap = rng.randint(gap_range[0], gap_range[1])
            if gap and not is_last:
                self._idle()
                for _ in range(gap):
                    await RisingEdge(self.clk)

        self._idle()
        self.packets_sent += 1

    async def _drive_one_beat(self) -> None:
        """Hold the current beat until it is accepted, per the configured mode."""
        if self.mode is BackpressureMode.NO_BACKPRESSURE or self.tready is None:
            # ⚠️ Do NOT wait for tready. The RX contract says it is tied high.
            #    Check it, then advance unconditionally: if the DUT stalls, the
            #    *test* must fail loudly rather than the driver absorbing it.
            if self.tready is not None:
                await ReadOnly()
                if not int(self.tready.value):
                    raise AssertionError(
                        f"{self.name}: DUT asserted backpressure (tready=0) on a "
                        f"no-backpressure interface. CLAUDE.md §5.4: the receive "
                        f"path must accept line rate unconditionally — it drops "
                        f"deliberately and counts drops, it never blocks. "
                        f"This is a DESIGN bug, not a stimulus problem."
                    )
            await RisingEdge(self.clk)
            return

        # Normal AXI-Stream handshake: sample tready in the settled region of the
        # cycle, then advance on the edge. Keeping the beat asserted until it is
        # accepted is itself part of the contract the monitor checks.
        while True:
            await ReadOnly()
            accepted = bool(int(self.tready.value))
            await RisingEdge(self.clk)
            if accepted:
                return

    # ------------------------------------------------------------------
    async def send_many(
        self,
        payloads: Iterable[bytes],
        gap_cycles: int = 0,
        inter_packet_gap: int = 0,
        **kwargs,
    ) -> None:
        """Send a sequence of packets.

        ``inter_packet_gap`` idle cycles are inserted between packets. Gap 0 is
        legal and is worth testing: it exposes state left over between packets,
        which is a documented random axis in 05-verification §6.
        """
        for pkt in payloads:
            await self.send(pkt, gap_cycles=gap_cycles, **kwargs)
            for _ in range(inter_packet_gap):
                await RisingEdge(self.clk)

    async def send_at_line_rate(self, payloads: Iterable[bytes]) -> None:
        """Back-to-back beats, zero gaps — the worst case the design must survive.

        ⚠️ This is the stimulus that matters for CLAUDE.md §5.4. A design that
        only works with gaps has not been tested; replay the worst historical
        minute like this and assert every drop counter is zero
        (06-operations/01-build-and-release.md §8 item 8).
        """
        await self.send_many(payloads, gap_cycles=0, inter_packet_gap=0)

    async def idle_cycles(self, n: int) -> None:
        """Drive nothing for ``n`` cycles."""
        self._idle()
        for _ in range(n):
            await RisingEdge(self.clk)


# ---------------------------------------------------------------------------
# Convenience helpers used by nearly every test in this repo
# ---------------------------------------------------------------------------
async def bringup(dut, clk_name: str = "clk", rst_name: str = "rst",
                  rst_cycles: int = 8):
    """Start the 156.25 MHz core clock and release synchronous, active-high reset.

    Reset policy (manuals/00-foundations/04-clocking-reset-and-cdc.md §4):
    synchronous, active high, project-wide. Configuration and risk registers
    must come out of reset in the SAFE state — limits zero, trading disabled —
    never the useful one. ``tb/risk/test_risk_gate.py`` asserts exactly that.
    """
    from cocotb.clock import Clock
    from cocotb.triggers import ClockCycles

    clk = getattr(dut, clk_name)
    rst = getattr(dut, rst_name)
    cocotb.start_soon(Clock(clk, CLK_PERIOD_NS, units="ns").start())
    rst.value = 1
    await ClockCycles(clk, rst_cycles)
    rst.value = 0
    await RisingEdge(clk)
    return clk, rst
