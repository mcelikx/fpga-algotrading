"""pcap / pcapng replay into the AXI-Stream driver.

Project : FPGA Algorithmic Trading System (Nasdaq Equities)
Governs : manuals/01-fpga-design/05-verification-and-simulation.md §4
          manuals/06-operations/04-testing-strategy.md

Reads a capture of real market data, extracts the frames, and feeds them to
:class:`tb.common.axis_driver.AxisDriver` at a configurable rate — including
full line rate — with optional replay of a slice selected by capture timestamp.

Why this is the most important stimulus in the repo
---------------------------------------------------
05-verification §4: "A feed handler plus an order book is a large, stateful,
order-dependent transform. You cannot unit-test your way to confidence in it:
the bugs live in *sequences* of messages that only appear in real market data —
an execution against an order added 40 million messages earlier, a cross that
empties one side of the book, a symbol that halts and reopens."

⚠️ REPLAY THE CAPTURE BYTE-FOR-BYTE
    Do not filter, de-duplicate, reorder, or "clean" it. Retransmissions,
    duplicate packets from the A/B feeds, gaps, and malformed frames are
    EXACTLY the inputs that need testing. If the pcap has a truncated packet at
    the end, feed it in and check you handle it.

    This module therefore defaults to no filtering at all. The port/IP filters
    exist for the case where a capture contains several feeds and the test is
    about one of them — never to make a failing test pass.

⚠️ EXCHANGE MARKET DATA IS LICENSED
    Do not commit real venue captures to this repository, public or private,
    without checking the redistribution terms. Store them in an
    access-controlled artifact store and commit only their hashes.
    ``tb/pcap/`` holds manifests, not blobs.

Implementation note
-------------------
The parsers below are hand-written rather than using scapy or dpkt. Reasons, in
order of weight:

1. No dependency to pin, in a project where 05-verification §7 rule 5 says "pin
   everything ... A suite whose results change on a tool upgrade is not a
   regression suite."
2. scapy *interprets* packets. This module must hand the DUT the exact bytes
   from the wire, including malformed ones that a library would normalize or
   refuse. A library that "helpfully" fixes a truncated frame deletes the test.
3. It is ~150 lines of struct unpacking.
"""

from __future__ import annotations

import gzip
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator

from cocotb.triggers import RisingEdge

# Link-layer types we understand. TODO(verify) against the actual capture:
# a colo capture from a tap is usually LINKTYPE_ETHERNET (1); some NIC capture
# stacks emit LINKTYPE_LINUX_SLL (113), which prepends 16 bytes.
LINKTYPE_ETHERNET = 1
LINKTYPE_RAW = 101
LINKTYPE_LINUX_SLL = 113

#: 10GbE, 64-bit bus at 156.25 MHz = 8 bytes/cycle = 6.4 ns/cycle.
CLK_PERIOD_NS = 6.400
BYTES_PER_CYCLE = 8
BITS_PER_NS_10G = 10.0          # 10 Gbps = 10 bits/ns


@dataclass
class CapturedFrame:
    """One frame from the capture, with its capture timestamp."""

    ts_ns: int              #: capture timestamp, nanoseconds since epoch
    data: bytes             #: the frame exactly as captured (link layer down)
    orig_len: int           #: original on-wire length; > len(data) if snapped
    index: int              #: 0-based position in the file

    @property
    def truncated(self) -> bool:
        """True if the capture snaplen cut this frame short.

        ⚠️ Not an error to be skipped. A truncated frame is a real input and the
        DUT must drop-and-count it (CLAUDE.md §5.7). Feed it in.
        """
        return self.orig_len > len(self.data)


# =============================================================================
# 1. Capture file readers
# =============================================================================
def _open_maybe_gz(path: str | Path):
    p = Path(path)
    if p.suffix == ".gz":
        return gzip.open(p, "rb")
    return open(p, "rb")


def read_pcap(path: str | Path) -> Iterator[CapturedFrame]:
    """Classic libpcap format. Handles both endiannesses and ns-resolution."""
    with _open_maybe_gz(path) as fh:
        magic = fh.read(4)
        if len(magic) < 4:
            raise ValueError(f"{path}: not a pcap file (too short)")

        if magic == b"\xd4\xc3\xb2\xa1":
            endian, ts_mult = "<", 1_000            # us -> ns
        elif magic == b"\xa1\xb2\xc3\xd4":
            endian, ts_mult = ">", 1_000
        elif magic == b"\x4d\x3c\xb2\xa1":
            endian, ts_mult = "<", 1                # ns resolution
        elif magic == b"\xa1\xb2\x3c\x4d":
            endian, ts_mult = ">", 1
        else:
            raise ValueError(f"{path}: unrecognised pcap magic {magic!r}")

        hdr = fh.read(20)
        _, _, _, _, _, linktype = struct.unpack(endian + "HHiIII", hdr)
        if linktype not in (LINKTYPE_ETHERNET, LINKTYPE_RAW, LINKTYPE_LINUX_SLL):
            raise ValueError(
                f"{path}: linktype {linktype} not supported. "
                f"TODO(verify): add a stripper for it rather than working around "
                f"it in a test."
            )

        idx = 0
        while True:
            rec = fh.read(16)
            if len(rec) < 16:
                break
            ts_sec, ts_frac, incl_len, orig_len = struct.unpack(endian + "IIII", rec)
            data = fh.read(incl_len)
            if len(data) < incl_len:
                # A capture cut off mid-record. Yield what there is; the caller
                # decides. Silently dropping it would hide a real, testable case.
                yield CapturedFrame(ts_sec * 1_000_000_000 + ts_frac * ts_mult,
                                    _strip_linktype(data, linktype),
                                    orig_len, idx)
                break
            yield CapturedFrame(ts_sec * 1_000_000_000 + ts_frac * ts_mult,
                                _strip_linktype(data, linktype), orig_len, idx)
            idx += 1


def read_pcapng(path: str | Path) -> Iterator[CapturedFrame]:
    """pcapng (the modern default for tcpdump/Wireshark).

    Only the blocks that matter are handled: Section Header, Interface
    Description (for the timestamp resolution and linktype), and Enhanced Packet
    Block. Everything else is skipped by its declared length.
    """
    with _open_maybe_gz(path) as fh:
        endian = "<"
        if_tsresol: list[int] = []
        if_linktype: list[int] = []
        idx = 0
        while True:
            head = fh.read(8)
            if len(head) < 8:
                break
            btype, blen = struct.unpack(endian + "II", head)

            if btype == 0x0A0D0D0A:               # Section Header Block
                bom = fh.read(4)
                if bom == b"\x4d\x3c\x2b\x1a":
                    endian = "<"
                elif bom == b"\x1a\x2b\x3c\x4d":
                    endian = ">"
                else:
                    raise ValueError(f"{path}: bad pcapng byte-order magic")
                # Re-read the length with the now-known endianness.
                blen = struct.unpack(endian + "I", head[4:8])[0]
                fh.read(blen - 12)
                if_tsresol.clear()
                if_linktype.clear()
                continue

            body = fh.read(blen - 12)
            fh.read(4)                            # trailing block length

            if btype == 0x00000001:               # Interface Description Block
                linktype = struct.unpack(endian + "H", body[0:2])[0]
                if_linktype.append(linktype)
                resol = 6                          # default: microseconds
                off = 8
                while off + 4 <= len(body):
                    ocode, olen = struct.unpack(endian + "HH", body[off:off + 4])
                    oval = body[off + 4:off + 4 + olen]
                    if ocode == 0:
                        break
                    if ocode == 9 and olen >= 1:   # if_tsresol
                        resol = oval[0]
                    off += 4 + ((olen + 3) & ~3)
                if_tsresol.append(resol)

            elif btype == 0x00000006:             # Enhanced Packet Block
                iface, ts_hi, ts_lo, cap_len, orig_len = struct.unpack(
                    endian + "IIIII", body[0:20])
                data = body[20:20 + cap_len]
                resol = if_tsresol[iface] if iface < len(if_tsresol) else 6
                ticks = (ts_hi << 32) | ts_lo
                if resol & 0x80:                   # power-of-two resolution
                    ts_ns = ticks * (10 ** 9) >> (resol & 0x7F)
                else:
                    ts_ns = ticks * (10 ** (9 - resol))
                lt = if_linktype[iface] if iface < len(if_linktype) else LINKTYPE_ETHERNET
                yield CapturedFrame(ts_ns, _strip_linktype(data, lt), orig_len, idx)
                idx += 1


def _strip_linktype(data: bytes, linktype: int) -> bytes:
    """Normalise to an Ethernet frame."""
    if linktype == LINKTYPE_LINUX_SLL:
        # 16-byte cooked header; rebuild a minimal Ethernet header so downstream
        # offset arithmetic is uniform. The MACs are synthetic and unused.
        ethertype = data[14:16]
        return b"\x01\x00\x5e\x00\x00\x00" + b"\x02\x00\x00\x00\x00\x01" \
               + ethertype + data[16:]
    return data


def read_capture(path: str | Path) -> Iterator[CapturedFrame]:
    """Dispatch on the file magic. Accepts .pcap, .pcapng, and .gz of either."""
    with _open_maybe_gz(path) as fh:
        magic = fh.read(4)
    if magic == b"\x0a\x0d\x0d\x0a":
        return read_pcapng(path)
    return read_pcap(path)


# =============================================================================
# 2. Payload extraction
# =============================================================================
def udp_payload(frame: bytes) -> tuple[bytes, int, int] | None:
    """Return ``(payload, src_port, dst_port)`` for an IPv4/UDP frame, else None.

    Handles a single 802.1Q VLAN tag. ⚠️ Returns None — rather than raising —
    for anything that is not IPv4/UDP, because a real capture contains ARP,
    LLDP, IGMP, and the occasional cosmic ray. The caller counts what it skips.
    """
    if len(frame) < 14:
        return None
    off = 12
    ethertype = struct.unpack(">H", frame[off:off + 2])[0]
    if ethertype == 0x8100:                        # VLAN tag
        off += 4
        if len(frame) < off + 2:
            return None
        ethertype = struct.unpack(">H", frame[off:off + 2])[0]
    off += 2
    if ethertype != 0x0800:                        # not IPv4
        return None
    if len(frame) < off + 20:
        return None
    ihl = (frame[off] & 0x0F) * 4
    proto = frame[off + 9]
    if proto != 17:                                # not UDP
        return None
    total_len = struct.unpack(">H", frame[off + 2:off + 4])[0]
    udp_off = off + ihl
    if len(frame) < udp_off + 8:
        return None
    src_port, dst_port, udp_len = struct.unpack(">HHH", frame[udp_off:udp_off + 6])
    payload_end = min(off + total_len, udp_off + udp_len, len(frame))
    return frame[udp_off + 8:payload_end], src_port, dst_port


# =============================================================================
# 3. Replay
# =============================================================================
@dataclass
class ReplayStats:
    frames_read: int = 0
    frames_sent: int = 0
    frames_skipped_nonudp: int = 0
    frames_skipped_filter: int = 0
    frames_truncated: int = 0
    bytes_sent: int = 0
    cycles_elapsed: int = 0

    def __str__(self) -> str:
        return (
            f"replay: read={self.frames_read} sent={self.frames_sent} "
            f"skipped(non-UDP)={self.frames_skipped_nonudp} "
            f"skipped(filter)={self.frames_skipped_filter} "
            f"truncated={self.frames_truncated} "
            f"bytes={self.bytes_sent} cycles={self.cycles_elapsed}"
        )


class PcapReplayer:
    """Drive a capture into an :class:`AxisDriver`.

    Parameters
    ----------
    driver:
        The AXI-Stream driver to feed. For a market-data test this should be in
        ``NO_BACKPRESSURE`` mode (CLAUDE.md §5.4).
    clk:
        Clock handle, for inter-frame idling.
    dst_ports / dst_ips:
        Optional filters. ⚠️ Default is no filter. Use these only to select one
        feed out of a multi-feed capture, never to skip frames a test is failing
        on.
    strip_to_udp:
        If True, only the UDP payload (the MoldUDP64 packet) is driven. Use for
        a DUT that starts at the MoldUDP64 deframer. Default False: the whole
        Ethernet frame is driven, which is what ``rtl/net/net_rx_path.sv``
        expects and which exercises the header-strip logic too.
    """

    def __init__(self, driver, clk, dst_ports: set[int] | None = None,
                 dst_ips: set[str] | None = None, strip_to_udp: bool = False,
                 log=None) -> None:
        self.driver = driver
        self.clk = clk
        self.dst_ports = dst_ports
        self.dst_ips = dst_ips
        self.strip_to_udp = strip_to_udp
        self.log = log
        self.stats = ReplayStats()

    # ------------------------------------------------------------------
    def select(self, path: str | Path,
               start_ts_ns: int | None = None,
               end_ts_ns: int | None = None,
               start_index: int | None = None,
               max_frames: int | None = None) -> Iterator[CapturedFrame]:
        """Iterate the capture, optionally sliced by timestamp or index.

        Slicing by TIMESTAMP is the operationally useful one: "replay the worst
        historical minute at full line rate; check every drop counter is zero"
        (05-verification §8) means selecting a wall-clock window out of a
        multi-hour session capture.

        ⚠️ A time slice that starts mid-session starts with an INCOMPLETE BOOK.
        The order references for orders added before the slice do not exist, so
        the DUT and the oracle will both report unknown-reference counts — which
        must MATCH. A test that slices must drive the oracle with the identical
        slice; anything else compares a warm book against a cold one.
        """
        n = 0
        for fr in read_capture(path):
            self.stats.frames_read += 1
            if start_index is not None and fr.index < start_index:
                continue
            if start_ts_ns is not None and fr.ts_ns < start_ts_ns:
                continue
            if end_ts_ns is not None and fr.ts_ns > end_ts_ns:
                break
            yield fr
            n += 1
            if max_frames is not None and n >= max_frames:
                break

    # ------------------------------------------------------------------
    def _accept(self, fr: CapturedFrame) -> bytes | None:
        parsed = udp_payload(fr.data)
        if parsed is None:
            self.stats.frames_skipped_nonudp += 1
            # ⚠️ A non-UDP frame is still a frame the MAC will see. If the test
            #    is exercising the header-strip block, drive it anyway by
            #    setting strip_to_udp=False and dst_ports=None — the block must
            #    drop and count it, not choke.
            return None
        payload, _src, dst = parsed
        if self.dst_ports is not None and dst not in self.dst_ports:
            self.stats.frames_skipped_filter += 1
            return None
        if self.dst_ips is not None:
            off = 14
            if struct.unpack(">H", fr.data[12:14])[0] == 0x8100:
                off += 4
            ip = ".".join(str(b) for b in fr.data[off + 16:off + 20])
            if ip not in self.dst_ips:
                self.stats.frames_skipped_filter += 1
                return None
        if fr.truncated:
            self.stats.frames_truncated += 1
        return payload if self.strip_to_udp else fr.data

    # ------------------------------------------------------------------
    async def replay(self, path: str | Path, rate: str | float = "line",
                     **slice_kw) -> ReplayStats:
        """Replay a capture.

        Parameters
        ----------
        rate:
            ``"line"``   — back-to-back beats, zero gaps. 10 Gbps. **The one
                           that matters**: a design that only works with gaps
                           has not been tested.
            ``"capture"``— reproduce the capture's own inter-frame gaps, scaled
                           to core-clock cycles. Realistic pacing; much slower
                           in simulation because idle cycles still cost
                           simulator time.
            ``"burst"``  — line rate with a small fixed inter-packet gap, the
                           common middle ground for a regression run.
            float        — a fraction of line rate (0.5 = half). Gaps are
                           inserted to achieve it.

        ⚠️ At ``"line"`` a 64-bit bus at 156.25 MHz consumes 8 bytes/cycle. A
           1500-byte frame is 188 beats; a 60-byte frame is 8. Simulation time
           is roughly linear in beats, so a full session replay is a nightly
           job, not a per-push one (05-verification §7).
        """
        prev_ts: int | None = None

        for fr in self.select(path, **slice_kw):
            payload = self._accept(fr)
            if payload is None:
                continue

            gap_cycles = 0
            if rate == "capture" and prev_ts is not None:
                delta_ns = max(0, fr.ts_ns - prev_ts)
                frame_ns = (len(payload) * 8) / BITS_PER_NS_10G
                idle_ns = max(0.0, delta_ns - frame_ns)
                gap_cycles = int(idle_ns / CLK_PERIOD_NS)
                # Cap the idle. A capture with a 200 ms quiet period would
                # otherwise cost 31 million simulated cycles for no coverage.
                gap_cycles = min(gap_cycles, 1000)
            elif rate == "burst":
                gap_cycles = 4
            elif isinstance(rate, (int, float)) and rate > 0:
                beats = max(1, (len(payload) + BYTES_PER_CYCLE - 1) // BYTES_PER_CYCLE)
                gap_cycles = max(0, int(beats * (1.0 / float(rate) - 1.0)))

            await self.driver.send(payload)
            self.stats.frames_sent += 1
            self.stats.bytes_sent += len(payload)

            for _ in range(gap_cycles):
                await RisingEdge(self.clk)
                self.stats.cycles_elapsed += 1

            prev_ts = fr.ts_ns

        if self.log:
            self.log.info(str(self.stats))
        return self.stats

    # ------------------------------------------------------------------
    def payloads(self, path: str | Path, **slice_kw) -> Iterator[bytes]:
        """Yield MoldUDP64 payloads without driving anything.

        This is how the ORACLE is fed: the same capture, the same slice, the
        same order, parsed independently. 05-verification §4 rule 4 — replay
        byte-for-byte, and give the oracle exactly what the DUT got.
        """
        for fr in self.select(path, **slice_kw):
            parsed = udp_payload(fr.data)
            if parsed is None:
                continue
            payload, _src, dst = parsed
            if self.dst_ports is not None and dst not in self.dst_ports:
                continue
            yield payload


# =============================================================================
# 4. Fixture management
# =============================================================================
def resolve_fixture(name: str, search: Iterable[str | Path] | None = None
                    ) -> Path | None:
    """Locate a pcap fixture, returning None if it is not present.

    ⚠️ Captures are NOT committed to this repository — exchange market data is
    licensed (05-verification §4, "Where pcaps come from"). ``tb/pcap/`` holds
    manifests and hashes; the blobs are fetched from an access-controlled
    artifact store into ``tb/pcap/local/`` (gitignored) or pointed at by
    ``$FPGA_PCAP_DIR``.

    Tests must treat a missing fixture as SKIP, never as failure — otherwise the
    suite is red for everyone who has not been granted the data, and a
    permanently-red suite stops being read.
    """
    import os

    candidates: list[Path] = []
    if search:
        candidates += [Path(s) / name for s in search]
    env = os.environ.get("FPGA_PCAP_DIR")
    if env:
        candidates.append(Path(env) / name)
    here = Path(__file__).resolve().parent.parent      # tb/
    candidates += [here / "pcap" / "local" / name, here / "pcap" / name]

    for c in candidates:
        if c.exists():
            return c
    return None


def sha256_of(path: str | Path) -> str:
    """Hash a fixture, for the manifest.

    The hash is what gets committed. 05-verification §7 rule 6: "Store the
    golden trace hash, not the trace. Multi-GB blobs in git will end the
    project's ability to clone."
    """
    import hashlib

    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
