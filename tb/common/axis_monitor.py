"""AXI-Stream monitor with runtime stream-contract assertions.

Project : FPGA Algorithmic Trading System (Nasdaq Equities)
Governs : manuals/01-fpga-design/01-rtl-design-patterns.md  (the stream contract)
          manuals/01-fpga-design/05-verification-and-simulation.md §5
          manuals/00-foundations/03-hdl-and-rtl-coding.md §9
          CLAUDE.md §5.4

The monitor does two jobs and they are deliberately separate:

1.  **Reassemble** packets from beats, so a test can compare bytes against a
    model without every test re-implementing beat handling.
2.  **Police the protocol**, continuously, as runtime assertions. Every stream
    interface in this design gets these checks
    (05-verification §5: "Every AXI-Stream port | The full valid/ready
    contract").

Why runtime assertions in Python as well as SVA in ``tb/sva/``
--------------------------------------------------------------
The SVA bind files are the primary mechanism and they run everywhere, including
under a vendor simulator. These Python checks exist because:

* they fire with a Python traceback that names the *test* and the beat index,
  which is what you actually need at 03:00 when a nightly regression breaks;
* they work when a test drives a module standalone with no bind file attached;
* Verilator's SVA support is good but not complete, and a check that silently
  does not run is worse than no check.

They are cheap. Run both.

⚠️ THE CONTRACT BEING ENFORCED

    Once ``tvalid`` is asserted it must stay asserted until the beat is accepted,
    and ``tdata``/``tkeep``/``tlast``/``tuser`` must not change while stalled.

        (tvalid && !tready) |=> (tvalid && $stable(tdata) && $stable(tlast))

    A producer that drops ``tvalid`` mid-beat, or that changes ``tdata`` while
    waiting, produces a stream that works against a consumer which never stalls
    and corrupts silently against one that does. That is a bug that appears the
    day someone adds a FIFO.

⚠️ AND THE PROJECT-SPECIFIC ONE

    On the RX path ``tready`` must be **always high**. CLAUDE.md §5.4. Set
    ``expect_no_backpressure=True`` on any monitor watching a market-data
    interface; it raises the moment the DUT stalls, rather than recording a
    stall as ordinary flow control.
"""

from __future__ import annotations

from typing import Callable

import cocotb
from cocotb.handle import SimHandleBase
from cocotb.queue import Queue
from cocotb.triggers import ReadOnly, RisingEdge


class StreamContractError(AssertionError):
    """Raised when an AXI-Stream contract rule is violated by the DUT."""


class AxisMonitor:
    """Passive AXI-Stream monitor.

    Parameters
    ----------
    dut, clk, prefix, width_bytes, index, rst:
        As :class:`tb.common.axis_driver.AxisDriver`.
        TODO(verify): signal names track rtl/fpga_top.sv (``m_axis_tdata`` etc.).
        Confirm once the block RTL is final.
    expect_no_backpressure:
        Assert that ``tready`` is high on every cycle out of reset. Use on every
        market-data RX interface.
    check_contract:
        Enable the valid/stable checks. On by default; there is no good reason
        to turn it off, and the option exists only so a test that *deliberately*
        drives an illegal stream (to prove the DUT's own SVA fires) can do so.
    on_packet:
        Optional callback invoked with each reassembled ``bytes``.
    """

    def __init__(
        self,
        dut: SimHandleBase,
        clk: SimHandleBase,
        prefix: str = "m_axis",
        width_bytes: int = 8,
        index: int | None = None,
        rst: SimHandleBase | None = None,
        expect_no_backpressure: bool = False,
        check_contract: bool = True,
        on_packet: Callable[[bytes], None] | None = None,
        name: str = "axis_mon",
    ) -> None:
        self.dut = dut
        self.clk = clk
        self.wb = width_bytes
        self.rst = rst
        self.name = name
        self.expect_no_backpressure = expect_no_backpressure
        self.check_contract = check_contract
        self.on_packet = on_packet
        self.log = dut._log

        def sig(suffix: str, required: bool = True):
            h = getattr(dut, f"{prefix}_{suffix}", None)
            if h is None:
                if required:
                    raise AttributeError(f"{name}: no DUT port {prefix}_{suffix}")
                return None
            return h[index] if index is not None else h

        self.tdata = sig("tdata")
        self.tvalid = sig("tvalid")
        self.tkeep = sig("tkeep", required=False)
        self.tlast = sig("tlast", required=False)
        self.tuser = sig("tuser", required=False)
        self.tready = sig("tready", required=False)

        #: Reassembled packets, in order.
        self.packets: Queue[bytes] = Queue()
        #: Every beat seen, as ``(tdata_int, tkeep_int, tlast, tuser)``.
        self.beats: list[tuple[int, int, int, int]] = []

        self.n_beats = 0
        self.n_packets = 0
        self.n_bytes = 0
        self.n_bad_fcs = 0          # frames whose final beat had tuser=1
        self.n_stall_cycles = 0     # cycles where tvalid && !tready

        self._acc = bytearray()
        self._prev: dict[str, int] | None = None
        self._cycle = 0

        self._task = cocotb.start_soon(self._run())

    # ------------------------------------------------------------------
    def _snapshot(self) -> dict[str, int]:
        return {
            "tvalid": int(self.tvalid.value),
            "tdata": int(self.tdata.value),
            "tkeep": int(self.tkeep.value) if self.tkeep is not None else 0,
            "tlast": int(self.tlast.value) if self.tlast is not None else 0,
            "tuser": int(self.tuser.value) if self.tuser is not None else 0,
            "tready": int(self.tready.value) if self.tready is not None else 1,
        }

    async def _run(self) -> None:
        while True:
            await RisingEdge(self.clk)
            await ReadOnly()
            self._cycle += 1

            if self.rst is not None and int(self.rst.value):
                # Reset: forget partial state. A packet straddling a reset is a
                # dropped packet, not a corrupt one.
                self._acc = bytearray()
                self._prev = None
                continue

            try:
                cur = self._snapshot()
            except ValueError:
                # X/Z on a signal. Verilator's 2-state mode never produces this;
                # xsim will, and an X on tvalid is a real finding — an un-reset
                # control register (05-verification §9, "Reset release /
                # power-up state").
                raise StreamContractError(
                    f"{self.name}: X/Z on a stream control signal at cycle "
                    f"{self._cycle}. A valid/ready signal must never be X out of "
                    f"reset — this is an un-reset control register "
                    f"(manuals/00-foundations/04-clocking-reset-and-cdc.md §4)."
                )

            self._check(cur)
            self._collect(cur)
            self._prev = cur

    # ------------------------------------------------------------------
    def _check(self, cur: dict[str, int]) -> None:
        if not self.check_contract:
            return

        # ── Project rule: the RX path never stalls ────────────────────────────
        if self.expect_no_backpressure and self.tready is not None:
            if not cur["tready"]:
                raise StreamContractError(
                    f"{self.name}: tready deasserted at cycle {self._cycle} on an "
                    f"interface declared no-backpressure.\n"
                    f"  CLAUDE.md §5.4: 'No backpressure stalls into the MAC RX. "
                    f"The receive path must accept line rate unconditionally; "
                    f"drop deliberately and count drops, never block.'\n"
                    f"  This is a DESIGN bug. Do not 'fix' it in the testbench."
                )

        prev = self._prev
        if prev is None:
            return

        # ── The stream contract: stable while stalled ────────────────────────
        # If the previous cycle had a valid beat that was NOT accepted, then this
        # cycle must still present the same beat.
        stalled = prev["tvalid"] and not prev["tready"]
        if stalled:
            self.n_stall_cycles += 1
            if not cur["tvalid"]:
                raise StreamContractError(
                    f"{self.name}: tvalid deasserted at cycle {self._cycle} while "
                    f"the previous beat was still stalled (tready was low).\n"
                    f"  AXI-Stream: once tvalid is asserted it must remain "
                    f"asserted until the beat is accepted.\n"
                    f"  Symptom in hardware: beats vanish only when a downstream "
                    f"FIFO fills — i.e. only under load."
                )
            for field in ("tdata", "tkeep", "tlast", "tuser"):
                if cur[field] != prev[field]:
                    raise StreamContractError(
                        f"{self.name}: {field} changed at cycle {self._cycle} "
                        f"while the beat was stalled "
                        f"(0x{prev[field]:X} -> 0x{cur[field]:X}).\n"
                        f"  AXI-Stream: payload must be stable from tvalid "
                        f"assertion until acceptance.\n"
                        f"  Symptom in hardware: silently corrupted data, only "
                        f"under backpressure."
                    )

        # ── tkeep sanity ─────────────────────────────────────────────────────
        # Only the final beat of a packet may have a sparse tkeep; every other
        # beat must be full. A sparse tkeep mid-packet means the producer is
        # trying to express a gap in the byte stream, which AXI-Stream in this
        # design does not support and which every downstream consumer here
        # assumes cannot happen.
        if cur["tvalid"] and self.tkeep is not None:
            full = (1 << self.wb) - 1
            if not cur["tlast"] and cur["tkeep"] != full:
                raise StreamContractError(
                    f"{self.name}: sparse tkeep 0x{cur['tkeep']:X} on a non-last "
                    f"beat at cycle {self._cycle}. Only the final beat of a "
                    f"packet may be partially populated."
                )
            if cur["tlast"] and cur["tkeep"] == 0:
                raise StreamContractError(
                    f"{self.name}: tlast with tkeep==0 at cycle {self._cycle} — "
                    f"a zero-length final beat. Length accounting downstream "
                    f"(MoldUDP64 block lengths, OUCH message lengths) will be "
                    f"off by one beat."
                )
            # tkeep must be contiguous from bit 0 (no holes).
            k = cur["tkeep"]
            if k and (k & (k + 1)) != 0:
                raise StreamContractError(
                    f"{self.name}: non-contiguous tkeep 0x{k:X} at cycle "
                    f"{self._cycle}. Bytes must be packed from lane 0 upward."
                )

    # ------------------------------------------------------------------
    def _collect(self, cur: dict[str, int]) -> None:
        accepted = cur["tvalid"] and cur["tready"]
        if not accepted:
            return

        self.n_beats += 1
        self.beats.append((cur["tdata"], cur["tkeep"], cur["tlast"], cur["tuser"]))

        # Unpack little-endian: tdata[7:0] is payload byte 0.
        raw = cur["tdata"].to_bytes(self.wb, "little")
        keep = cur["tkeep"] if self.tkeep is not None else (1 << self.wb) - 1
        n = bin(keep).count("1") if keep else self.wb
        self._acc += raw[:n]
        self.n_bytes += n

        if cur["tlast"]:
            pkt = bytes(self._acc)
            self._acc = bytearray()
            self.n_packets += 1
            if cur["tuser"]:
                # On the MAC RX interface in this design tuser means "bad FCS"
                # (rtl/fpga_top.sv: md_axis_tuser). CLAUDE.md §5.7 — this must be
                # counted, never silently dropped.
                self.n_bad_fcs += 1
            self.packets.put_nowait(pkt)
            if self.on_packet is not None:
                self.on_packet(pkt)

    # ------------------------------------------------------------------
    async def next_packet(self, timeout_cycles: int = 10_000) -> bytes:
        """Await the next reassembled packet, with a bounded wait.

        ⚠️ The timeout matters. A test that hangs waiting for a packet the DUT
        will never emit reports "timeout" in CI with no context; a bounded wait
        reports which monitor, after how many cycles, having seen how many beats.
        """
        for _ in range(timeout_cycles):
            if not self.packets.empty():
                return self.packets.get_nowait()
            await RisingEdge(self.clk)
        raise TimeoutError(
            f"{self.name}: no packet within {timeout_cycles} cycles "
            f"({timeout_cycles * 6.4:.0f} ns). Seen so far: {self.n_beats} beats, "
            f"{self.n_packets} packets, {self.n_bytes} bytes. "
            f"Partial packet in flight: {len(self._acc)} bytes."
        )

    def stop(self) -> None:
        self._task.kill()

    def summary(self) -> str:
        return (
            f"{self.name}: {self.n_packets} packets, {self.n_beats} beats, "
            f"{self.n_bytes} bytes, {self.n_bad_fcs} bad-FCS, "
            f"{self.n_stall_cycles} stall cycles"
        )


class ValidOnlyMonitor:
    """Monitor for a plain ``valid`` + payload interface (no ready, no last).

    Most internal interfaces in this design are of this shape rather than full
    AXI-Stream — ``book_evt_t``/``book_evt_valid``, ``book_top_t``/
    ``book_top_valid``, ``order_req_t``/``order_req_valid``. They are
    fixed-latency, non-stallable, one struct per cycle. That is deliberate:
    CLAUDE.md §4 prefers fixed latency over variable latency, and a ready signal
    on the fast path would introduce exactly the variable latency the design is
    trying to avoid.

    ``fields`` maps a friendly name to a DUT handle; each accepted cycle is
    recorded as a dict of ints.
    """

    def __init__(
        self,
        dut: SimHandleBase,
        clk: SimHandleBase,
        valid: SimHandleBase,
        fields: dict[str, SimHandleBase],
        rst: SimHandleBase | None = None,
        name: str = "valid_mon",
    ) -> None:
        self.clk = clk
        self.valid = valid
        self.fields = fields
        self.rst = rst
        self.name = name
        self.samples: list[dict[str, int]] = []
        self._task = cocotb.start_soon(self._run())

    async def _run(self) -> None:
        while True:
            await RisingEdge(self.clk)
            await ReadOnly()
            if self.rst is not None and int(self.rst.value):
                continue
            if int(self.valid.value):
                self.samples.append(
                    {k: int(h.value) for k, h in self.fields.items()}
                )

    def clear(self) -> None:
        self.samples.clear()

    def stop(self) -> None:
        self._task.kill()
