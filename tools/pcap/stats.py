#!/usr/bin/env python3
"""Message-rate and burst analysis for an ITCH capture — the FIFO sizing tool.

Project : FPGA Algorithmic Trading System (Nasdaq Equities)
Governs : manuals/06-operations/04-testing-strategy.md §4, §12
          manuals/05-optimization/04-measurement-and-profiling.md
          CLAUDE.md §5.4 (RX never backpressures), §5.8 (p50/p99/p99.9/max)

===============================================================================
THE QUESTION THIS TOOL ANSWERS
===============================================================================
CLAUDE.md §5.4: *the receive path must accept line rate unconditionally; drop
deliberately and count drops, never block.* That rule turns every buffer on the
RX path into a design decision with a number attached:

    how deep does this FIFO have to be so that the worst burst in the corpus
    does not overflow it?

The mean message rate does not answer that and is actively misleading. A feed
averaging 300 k msg/s spends most of a session near zero and delivers its day
in bursts several orders of magnitude above the mean. **A FIFO sized from the
mean overflows on the first open.**

So this tool reports the distribution — p50, p99, p99.9, p99.99, max — of the
message and byte arrival rate over *many* window sizes simultaneously (1 µs
through 1 s), and then does the thing that actually sizes the buffer: it runs
the exact leaky-bucket backlog recursion against a declared service rate and
reports the **maximum occupancy the buffer ever reached**. That number, not a
percentile, is the FIFO depth.

===============================================================================
⚠️  WHAT A PCAP CAN AND CANNOT TELL YOU ABOUT BURSTS
===============================================================================
Everything below is only as good as the capture's timestamps, and capture
timestamps are frequently much worse than people assume.

  1. **Timestamp resolution.** A capture written with microsecond timestamps
     cannot resolve a burst shorter than a microsecond. At 10 GbE a 1 µs window
     holds ~19 back-to-back minimum-size frames; a whole microburst can hide
     inside one timestamp tick and appear as a single instant. This tool infers
     the effective resolution and **refuses to report windows finer than it**
     without a warning. See :func:`infer_ts_resolution`.
  2. **Capture point.** Timestamps taken in the kernel, or by a NIC that
     coalesces interrupts, are smeared: arrivals get bunched or spread relative
     to what the wire did. Only a tap or a NIC with hardware timestamping at the
     port gives burst structure you can size a buffer from.
  3. **The capture is not the fabric ingress.** Between the tap and the FIFO
     under consideration sit switch queues and the MAC. Switch buffering can
     *create* bursts that were never on the source wire.

Therefore: a depth computed here is a **lower bound with a stated methodology**,
not a proof. manuals/06-operations/04-testing-strategy.md §7 makes the same
point about software replay — it "cannot reproduce microburst timing
accurately; fine for functional tests, useless for burst-stress". Size with
headroom, and confirm on hardware with the high-water-mark counter, which is
the only number that is a measurement.

===============================================================================
METHOD
===============================================================================
Single streaming pass, bounded memory, exact counts.

* **Sliding windows.** For each window width W, a deque of arrival timestamps
  is trimmed to the last W ns at every arrival; its length is the occupancy of
  the window ending at that arrival. Windows that end at an arrival are the only
  ones that can be maximal, so this is exact, not sampled.
* **Distributions.** Occupancies and inter-arrival deltas go into a
  :class:`LogLinearHistogram` — exact below 64, ~1.6 % relative precision above
  (64 sub-buckets per octave, the HdrHistogram structure). Min, max, count and
  sum are tracked exactly alongside, so the extremes are never approximated.
  Percentiles are reported as the *upper edge* of the containing bucket, which
  makes every reported percentile a conservative over-estimate — the right
  direction for sizing a buffer.
* **Backlog.** ``B ← max(0, B + work − service_rate · Δt)`` per arrival, the
  exact recursion for a work-conserving server that starts empty. Its running
  maximum is the required depth.

Usage
-----
    python3 tools/pcap/stats.py CAPTURE.pcap
    python3 tools/pcap/stats.py CAPTURE.pcap --json stats.json
    python3 tools/pcap/stats.py CAPTURE.pcap --ports 26477 --per-symbol 20
    python3 tools/pcap/stats.py CAPTURE.pcap --service-bytes-per-s 1.25e9
    python3 tools/pcap/stats.py CAPTURE.pcap --series 1ms --series-out rate.csv

Exit status: 0 = analysed, 1 = ERROR-severity parse anomalies present,
2 = the file could not be read.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from collections import Counter, deque
from dataclasses import dataclass, field
from typing import Any, Deque, Dict, List, Optional, Sequence, Tuple

try:
    from itch_parse import (BOOK_MSG_TYPES, ITCH_MSG_NAME, ItchReader,
                            MOLD_HDR_LEN, format_ts_ns)
except ImportError:  # invoked from outside tools/pcap
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from itch_parse import (BOOK_MSG_TYPES, ITCH_MSG_NAME, ItchReader,  # type: ignore
                            MOLD_HDR_LEN, format_ts_ns)

__all__ = [
    "LogLinearHistogram",
    "SlidingWindow",
    "RateStats",
    "analyse",
    "WINDOWS_NS",
]

VERSION = "1.0.0"

# =============================================================================
# 1. Fabric constants — mirrored from rtl/pkg/trading_pkg.sv
# =============================================================================
# Kept here so a sizing figure can be produced without a Vivado checkout. If
# trading_pkg.sv changes, these must change with it.
CORE_CLK_HZ = 156_250_000              # trading_pkg::CORE_CLK_KHZ = 156_250
AXIS_BYTES_PER_BEAT = 8                # trading_pkg::AXIS_W = 64 bits
#: Sustained datapath byte rate: one 64-bit beat per core clock.
#: 156.25 MHz x 8 B = 1.25 GB/s = 10 Gb/s, i.e. exactly line rate. That
#: equality is the whole point of the 64 b @ 156.25 MHz choice (CLAUDE.md §2).
FABRIC_BYTES_PER_S = CORE_CLK_HZ * AXIS_BYTES_PER_BEAT
LINE_RATE_BITS_PER_S = 10_000_000_000

#: Wire overhead per Ethernet frame, in bytes.
#:   14 Ethernet header + 20 IPv4 (no options) + 8 UDP = 42 carried bytes
#:   + 4 FCS = 46 bytes that occupy the MAC
#:   + 8 preamble/SFD + 12 inter-packet gap = 20 more that occupy the LINE
#: VERIFY: IEEE 802.3 clause 4 for IPG/preamble; RFC 791 / RFC 768 for headers.
#: ⚠️ A capture from a VLAN-tagged port adds 4 bytes per tag that this misses.
ETH_IP_UDP_HDR = 42
ETH_FCS = 4
ETH_PREAMBLE_IPG = 20

#: Window widths analysed, in nanoseconds. The short end exists because that is
#: where FIFOs overflow; the long end exists because that is what capacity
#: planning and host-side ring sizing care about.
WINDOWS_NS: Tuple[int, ...] = (
    1_000,          # 1 us   — ~19 min-size frames at 10 GbE; FIFO scale
    10_000,         # 10 us  — deep-FIFO / burst-absorber scale
    100_000,        # 100 us
    1_000_000,      # 1 ms   — the number people quote as "peak rate"
    10_000_000,     # 10 ms
    100_000_000,    # 100 ms
    1_000_000_000,  # 1 s    — the number people quote as "the rate"
)

PCTS: Tuple[float, ...] = (50.0, 90.0, 99.0, 99.9, 99.99)


def _fmt_window(ns: int) -> str:
    if ns >= 1_000_000_000:
        return f"{ns // 1_000_000_000}s"
    if ns >= 1_000_000:
        return f"{ns // 1_000_000}ms"
    if ns >= 1_000:
        return f"{ns // 1_000}us"
    return f"{ns}ns"


def parse_duration_ns(s: str) -> int:
    """'1ms' / '250us' / '2s' / '1500' (ns) -> nanoseconds."""
    s = s.strip().lower()
    for suffix, mult in (("ns", 1), ("us", 1_000), ("ms", 1_000_000), ("s", 1_000_000_000)):
        if s.endswith(suffix):
            head = s[: -len(suffix)].strip()
            return int(round(float(head) * mult))
    return int(round(float(s)))


# =============================================================================
# 2. Bounded-memory distribution
# =============================================================================
class LogLinearHistogram:
    """Exact below ``1<<SUB``, ~1.6 % relative precision above. Bounded memory.

    The HdrHistogram bucket structure: values are split into an octave
    (position of the highest set bit) and ``SUB`` linear sub-buckets within it.
    Memory is O(octaves x SUB) — a few thousand counters — regardless of how
    many samples or how large they get, which is what makes a full-session
    capture analysable without holding a per-message array.

    ⚠️ ``percentile()`` returns the **upper edge** of the bucket containing the
    requested rank, so every percentile is an over-estimate by at most one
    bucket width (≤1.6 %). Deliberate: for buffer sizing, erring high is safe
    and erring low is an overflow. ``max`` and ``min`` are tracked exactly and
    are never bucketed.
    """

    SUB_BITS = 6
    SUB = 1 << SUB_BITS   # 64 sub-buckets per octave

    __slots__ = ("counts", "n", "total", "vmin", "vmax")

    def __init__(self) -> None:
        self.counts: Counter = Counter()
        self.n = 0
        self.total = 0
        self.vmin: Optional[int] = None
        self.vmax: Optional[int] = None

    # -- bucketing ------------------------------------------------------------
    @classmethod
    def _bucket(cls, v: int) -> int:
        if v < cls.SUB:
            return v
        octave = v.bit_length() - 1 - cls.SUB_BITS
        return ((octave + 1) << cls.SUB_BITS) | ((v >> octave) - cls.SUB)

    @classmethod
    def _upper(cls, b: int) -> int:
        """Largest value that lands in bucket ``b``."""
        if b < cls.SUB:
            return b
        octave = (b >> cls.SUB_BITS) - 1
        sub = b & (cls.SUB - 1)
        return (((sub + cls.SUB) + 1) << octave) - 1

    # -- accumulate -----------------------------------------------------------
    def add(self, v: int, weight: int = 1) -> None:
        if v < 0:
            v = 0
        self.counts[self._bucket(v)] += weight
        self.n += weight
        self.total += v * weight
        if self.vmin is None or v < self.vmin:
            self.vmin = v
        if self.vmax is None or v > self.vmax:
            self.vmax = v

    # -- query ----------------------------------------------------------------
    def percentile(self, p: float) -> int:
        """Nearest-rank percentile, returned as the bucket's upper edge."""
        if self.n == 0:
            return 0
        # Nearest-rank: the smallest value at or below which at least p% lie.
        rank = max(1, math.ceil(p / 100.0 * self.n))
        seen = 0
        for b in sorted(self.counts):
            seen += self.counts[b]
            if seen >= rank:
                return min(self._upper(b), self.vmax if self.vmax is not None else self._upper(b))
        return self.vmax or 0

    @property
    def mean(self) -> float:
        return (self.total / self.n) if self.n else 0.0

    def summary(self) -> Dict[str, Any]:
        return {
            "n": self.n,
            "min": self.vmin if self.vmin is not None else 0,
            "mean": self.mean,
            **{f"p{p:g}".replace(".", "_"): self.percentile(p) for p in PCTS},
            "max": self.vmax if self.vmax is not None else 0,
            "precision_note": (
                "exact <64; percentiles above are the upper edge of a bucket "
                "with <=1.6% relative width (over-estimate). min/max exact."
            ),
        }


# =============================================================================
# 3. Sliding window occupancy
# =============================================================================
class SlidingWindow:
    """Occupancy of a fixed-width time window ending at each arrival.

    Bounded memory: the deque only ever holds the arrivals inside one window.
    Exact: a window's occupancy is maximised by a window whose right edge sits
    on an arrival, so evaluating at every arrival finds the true maximum.
    """

    __slots__ = ("width_ns", "ts", "wt", "sum_w", "hist_count", "hist_weight",
                 "peak_count", "peak_weight", "peak_count_at", "peak_weight_at")

    def __init__(self, width_ns: int) -> None:
        self.width_ns = width_ns
        self.ts: Deque[int] = deque()
        self.wt: Deque[int] = deque()
        self.sum_w = 0
        self.hist_count = LogLinearHistogram()
        self.hist_weight = LogLinearHistogram()
        self.peak_count = 0
        self.peak_weight = 0
        self.peak_count_at = 0
        self.peak_weight_at = 0

    def add(self, ts_ns: int, weight: int) -> None:
        self.ts.append(ts_ns)
        self.wt.append(weight)
        self.sum_w += weight
        cutoff = ts_ns - self.width_ns
        while self.ts and self.ts[0] <= cutoff:
            self.ts.popleft()
            self.sum_w -= self.wt.popleft()
        c = len(self.ts)
        self.hist_count.add(c)
        self.hist_weight.add(self.sum_w)
        if c > self.peak_count:
            self.peak_count, self.peak_count_at = c, ts_ns
        if self.sum_w > self.peak_weight:
            self.peak_weight, self.peak_weight_at = self.sum_w, ts_ns

    # -- derived rates --------------------------------------------------------
    def rate_per_s(self, count: int) -> float:
        return count * 1e9 / self.width_ns

    def summary(self) -> Dict[str, Any]:
        return {
            "window": _fmt_window(self.width_ns),
            "window_ns": self.width_ns,
            "events": self.hist_count.summary(),
            "bytes": self.hist_weight.summary(),
            "peak_events": self.peak_count,
            "peak_events_at_ns": self.peak_count_at,
            "peak_bytes": self.peak_weight,
            "peak_bytes_at_ns": self.peak_weight_at,
            "peak_events_per_s": self.rate_per_s(self.peak_count),
            "peak_bytes_per_s": self.rate_per_s(self.peak_weight),
            "p99_9_events_per_s": self.rate_per_s(self.hist_count.percentile(99.9)),
        }


# =============================================================================
# 4. Leaky-bucket backlog — this is the FIFO depth
# =============================================================================
@dataclass
class Backlog:
    """Exact worst-case occupancy of a buffer drained at a constant rate.

    ``B <- max(0, B + work - rate * dt)`` evaluated at every arrival is the
    exact recursion for a work-conserving server that starts empty; between
    arrivals the buffer only drains, so the maximum always occurs immediately
    after an arrival.

    ⚠️ The service rate is an *assumption about the design*, not a property of
    the capture. Feed it the real sustained throughput of the stage downstream
    of the FIFO. If that stage can itself stall, this model understates the
    depth — chain the stages or model the stall.
    """

    name: str
    service_per_s: float
    unit: str = "bytes"
    level: float = 0.0
    peak: float = 0.0
    peak_at_ns: int = 0
    _last_ts: Optional[int] = None
    hist: LogLinearHistogram = field(default_factory=LogLinearHistogram)

    def add(self, ts_ns: int, work: float) -> None:
        if self._last_ts is not None:
            dt = ts_ns - self._last_ts
            if dt > 0:
                self.level = max(0.0, self.level - self.service_per_s * dt / 1e9)
        self._last_ts = ts_ns
        self.level += work
        if self.level > self.peak:
            self.peak, self.peak_at_ns = self.level, ts_ns
        self.hist.add(int(self.level))

    def summary(self) -> Dict[str, Any]:
        depth = int(math.ceil(self.peak))
        return {
            "name": self.name,
            "service_per_s": self.service_per_s,
            "unit": self.unit,
            "peak_occupancy": depth,
            "peak_at_ns": self.peak_at_ns,
            "occupancy": self.hist.summary(),
            "recommended_depth_pow2": 1 << max(1, depth - 1).bit_length() if depth else 0,
            "recommended_depth_2x_pow2": (1 << max(1, 2 * depth - 1).bit_length()) if depth else 0,
        }


# =============================================================================
# 5. Timestamp resolution inference
# =============================================================================
def infer_ts_resolution(sample: Sequence[int]) -> Tuple[int, str]:
    """Infer the effective timestamp granularity from a sample of timestamps.

    Returns (granularity_ns, explanation). A capture whose timestamps are all
    multiples of 1000 has microsecond resolution however many digits the file
    format allows, and any window narrower than that is fiction.
    """
    if len(sample) < 8:
        return 1, "too few timestamps to infer resolution"
    for g, label in ((1_000_000_000, "1 s"), (1_000_000, "1 ms"),
                     (1_000, "1 us"), (100, "100 ns"), (10, "10 ns")):
        if all(t % g == 0 for t in sample):
            return g, (
                f"every sampled timestamp is a multiple of {g} ns ({label}); "
                f"bursts shorter than {label} are NOT resolvable in this capture"
            )
    return 1, "timestamps show sub-10 ns granularity (hardware timestamping likely)"


# =============================================================================
# 6. The analysis
# =============================================================================
@dataclass
class RateStats:
    """Everything one pass over a capture produces."""

    path: str
    windows: Dict[int, SlidingWindow]
    inter_arrival_msg: LogLinearHistogram
    inter_arrival_pkt: LogLinearHistogram
    msgs_per_packet: LogLinearHistogram
    bytes_per_packet: LogLinearHistogram
    by_type: Counter
    bytes_by_type: Counter
    by_locate: Counter
    backlogs: List[Backlog]
    series: Dict[int, Tuple[int, int, int]]   # bin -> (msgs, packets, bytes)
    series_bin_ns: int
    n_msgs: int = 0
    n_packets: int = 0
    n_book_msgs: int = 0
    udp_bytes: int = 0
    wire_bytes: int = 0
    first_ts: Optional[int] = None
    last_ts: Optional[int] = None
    ts_sample: List[int] = field(default_factory=list)
    reader_summary: Dict[str, Any] = field(default_factory=dict)


def analyse(
    path: str,
    *,
    ports: Optional[Sequence[int]] = None,
    groups: Optional[Sequence[str]] = None,
    raw_itch: bool = False,
    merge_ab: bool = False,
    windows: Sequence[int] = WINDOWS_NS,
    series_bin_ns: int = 1_000_000,
    service_bytes_per_s: float = FABRIC_BYTES_PER_S,
    service_msgs_per_s: Optional[float] = None,
    max_messages: int = 0,
) -> RateStats:
    """One streaming pass. Bounded memory; safe on a full-session capture."""
    reader = ItchReader(path, ports=ports, groups=groups, raw_itch=raw_itch,
                        merge_ab=merge_ab)

    if service_msgs_per_s is None:
        # ⚠️ ASSUMPTION, not a measurement. The smallest ITCH message is 19
        #    bytes; at 8 B/cycle that is 3 beats, so the feed path cannot
        #    present messages faster than ~1 per 3 cycles. Replace this with
        #    the decoder's measured sustained rate once it exists (TASKS P3).
        service_msgs_per_s = CORE_CLK_HZ / 3.0

    st = RateStats(
        path=path,
        windows={w: SlidingWindow(w) for w in windows},
        inter_arrival_msg=LogLinearHistogram(),
        inter_arrival_pkt=LogLinearHistogram(),
        msgs_per_packet=LogLinearHistogram(),
        bytes_per_packet=LogLinearHistogram(),
        by_type=Counter(),
        bytes_by_type=Counter(),
        by_locate=Counter(),
        backlogs=[
            Backlog("rx_byte_fifo", service_bytes_per_s, "bytes"),
            Backlog("msg_fifo", float(service_msgs_per_s), "messages"),
        ],
        series={},
        series_bin_ns=series_bin_ns,
    )

    prev_msg_ts: Optional[int] = None
    prev_pkt_ts: Optional[int] = None
    cur_pkt_index = -1
    cur_pkt_msgs = 0
    cur_pkt_bytes = 0

    def close_packet() -> None:
        """Account for one finished MoldUDP64 packet."""
        if cur_pkt_index < 0:
            return
        st.n_packets += 1
        st.msgs_per_packet.add(cur_pkt_msgs)
        udp = MOLD_HDR_LEN + cur_pkt_bytes
        st.udp_bytes += udp
        wire = udp + ETH_IP_UDP_HDR + ETH_FCS + ETH_PREAMBLE_IPG
        st.wire_bytes += wire
        st.bytes_per_packet.add(udp)

    for msg in reader.messages():
        ts = msg.pkt_ts_ns or msg.ts_ns   # raw-ITCH mode has no capture clock
        if msg.pkt_index != cur_pkt_index:
            close_packet()
            cur_pkt_index = msg.pkt_index
            cur_pkt_msgs = 0
            cur_pkt_bytes = 0
            if prev_pkt_ts is not None and ts >= prev_pkt_ts:
                st.inter_arrival_pkt.add(ts - prev_pkt_ts)
            prev_pkt_ts = ts
        cur_pkt_msgs += 1
        cur_pkt_bytes += 2 + msg.declared_len   # 2-byte MoldUDP64 length prefix

        st.n_msgs += 1
        st.by_type[msg.msg_type] += 1
        st.bytes_by_type[msg.msg_type] += msg.declared_len
        st.by_locate[msg.locate] += 1
        if msg.is_book_msg:
            st.n_book_msgs += 1

        if st.first_ts is None:
            st.first_ts = ts
        st.last_ts = ts
        if len(st.ts_sample) < 4096:
            st.ts_sample.append(ts)

        if prev_msg_ts is not None and ts >= prev_msg_ts:
            st.inter_arrival_msg.add(ts - prev_msg_ts)
        prev_msg_ts = ts

        work_bytes = 2 + msg.declared_len
        for w in st.windows.values():
            w.add(ts, work_bytes)
        st.backlogs[0].add(ts, float(work_bytes))
        st.backlogs[1].add(ts, 1.0)

        if series_bin_ns > 0 and st.first_ts is not None:
            b = (ts - st.first_ts) // series_bin_ns
            m, p, by = st.series.get(b, (0, 0, 0))
            st.series[b] = (m + 1, p, by + work_bytes)

        if max_messages and st.n_msgs >= max_messages:
            break

    close_packet()
    st.reader_summary = reader.summary()
    return st


# =============================================================================
# 7. Report assembly
# =============================================================================
def to_json(st: RateStats) -> Dict[str, Any]:
    dur_ns = (st.last_ts - st.first_ts) if (st.first_ts is not None and st.last_ts is not None) else 0
    dur_s = dur_ns / 1e9 if dur_ns else 0.0
    gran, gran_note = infer_ts_resolution(st.ts_sample)
    unresolvable = [_fmt_window(w) for w in st.windows if w < gran]
    total = max(1, st.n_msgs)
    return {
        "tool": "stats.py",
        "tool_version": VERSION,
        "path": st.path,
        "capture": {
            "messages": st.n_msgs,
            "book_messages": st.n_book_msgs,
            "packets": st.n_packets,
            "udp_payload_bytes": st.udp_bytes,
            "wire_bytes_est": st.wire_bytes,
            "first_ts_ns": st.first_ts,
            "last_ts_ns": st.last_ts,
            "duration_s": dur_s,
            "mean_msgs_per_s": (st.n_msgs / dur_s) if dur_s else 0.0,
            "mean_line_utilisation_pct": (
                (st.wire_bytes * 8 / dur_s) / LINE_RATE_BITS_PER_S * 100.0 if dur_s else 0.0
            ),
            "distinct_locates": len(st.by_locate),
        },
        "timestamp_quality": {
            "inferred_granularity_ns": gran,
            "note": gran_note,
            "unresolvable_windows": unresolvable,
            "warning": (
                "⚠️ Windows narrower than the inferred granularity are not "
                "measurements. A buffer sized from them is sized from an "
                "artefact of the capture clock." if unresolvable else ""
            ),
        },
        "windows": [st.windows[w].summary() for w in sorted(st.windows)],
        "inter_arrival_ns": {
            "message": st.inter_arrival_msg.summary(),
            "packet": st.inter_arrival_pkt.summary(),
        },
        "per_packet": {
            "messages": st.msgs_per_packet.summary(),
            "udp_bytes": st.bytes_per_packet.summary(),
        },
        "message_types": [
            {
                "type": t,
                "name": ITCH_MSG_NAME.get(t, "UNKNOWN"),
                "count": n,
                "pct": 100.0 * n / total,
                "bytes": st.bytes_by_type[t],
                "book": t in BOOK_MSG_TYPES,
            }
            for t, n in st.by_type.most_common()
        ],
        "fifo_sizing": {
            "note": (
                "peak_occupancy is the exact worst-case backlog of a buffer "
                "drained at service_per_s, over THIS capture. It is a lower "
                "bound on the real requirement: see the module docstring on "
                "capture timestamp fidelity. Confirm against the hardware "
                "high-water-mark counter before trusting a depth."
            ),
            "fabric_bytes_per_s": FABRIC_BYTES_PER_S,
            "buffers": [b.summary() for b in st.backlogs],
        },
        "top_locates": [
            {"locate": loc, "messages": n, "pct": 100.0 * n / total}
            for loc, n in st.by_locate.most_common(50)
        ],
        "parse_diagnostics": st.reader_summary.get("diagnostics", {}),
    }


def _fmt_rate(v: float) -> str:
    if v >= 1e9:
        return f"{v / 1e9:,.2f}G"
    if v >= 1e6:
        return f"{v / 1e6:,.2f}M"
    if v >= 1e3:
        return f"{v / 1e3:,.1f}k"
    return f"{v:,.0f}"


def _fmt_ns(v: float) -> str:
    if v >= 1e9:
        return f"{v / 1e9:,.3f} s"
    if v >= 1e6:
        return f"{v / 1e6:,.3f} ms"
    if v >= 1e3:
        return f"{v / 1e3:,.3f} us"
    return f"{v:,.0f} ns"


def print_report(st: RateStats, out=sys.stdout) -> None:
    j = to_json(st)
    cap = j["capture"]
    W = 92
    print("=" * W, file=out)
    print(f"ITCH rate & burst analysis — {os.path.basename(st.path)}", file=out)
    print("=" * W, file=out)
    print(f"  messages            {cap['messages']:>16,}   "
          f"({cap['book_messages']:,} book-affecting, "
          f"{100.0 * cap['book_messages'] / max(1, cap['messages']):.1f}%)", file=out)
    print(f"  MoldUDP64 packets   {cap['packets']:>16,}", file=out)
    print(f"  UDP payload bytes   {cap['udp_payload_bytes']:>16,}", file=out)
    print(f"  wire bytes (est)    {cap['wire_bytes_est']:>16,}   "
          f"(+{ETH_IP_UDP_HDR + ETH_FCS + ETH_PREAMBLE_IPG} B/frame L1+L2+L3+L4)", file=out)
    print(f"  duration            {cap['duration_s']:>16,.6f} s", file=out)
    print(f"  distinct locates    {cap['distinct_locates']:>16,}", file=out)
    print(f"  MEAN rate           {_fmt_rate(cap['mean_msgs_per_s']):>16} msg/s   "
          f"⚠️ the mean is the one number that never sizes a buffer", file=out)
    print(f"  mean line use       {cap['mean_line_utilisation_pct']:>16.3f} %   of 10GbE", file=out)

    # -- timestamp quality ----------------------------------------------------
    tq = j["timestamp_quality"]
    print(f"\n  timestamp granularity: {tq['inferred_granularity_ns']} ns — {tq['note']}", file=out)
    if tq["warning"]:
        print(f"  {tq['warning']}", file=out)
        print(f"  affected windows: {', '.join(tq['unresolvable_windows'])}", file=out)

    # -- burst table ----------------------------------------------------------
    print("\n" + "-" * W, file=out)
    print("  MESSAGE RATE BY WINDOW  (msg/s, extrapolated from the window's message count)", file=out)
    print("-" * W, file=out)
    print(f"  {'window':>7} {'p50':>10} {'p99':>10} {'p99.9':>10} {'p99.99':>10} "
          f"{'MAX':>12} {'max msgs':>10}", file=out)
    for wsum in j["windows"]:
        w_ns = wsum["window_ns"]
        ev = wsum["events"]
        flag = "  ⚠️unresolvable" if _fmt_window(w_ns) in tq["unresolvable_windows"] else ""
        def r(v: int) -> str:
            return _fmt_rate(v * 1e9 / w_ns)
        print(f"  {wsum['window']:>7} {r(ev['p50']):>10} {r(ev['p99']):>10} "
              f"{r(ev['p99_9']):>10} {r(ev['p99_99']):>10} {r(ev['max']):>12} "
              f"{ev['max']:>10,}{flag}", file=out)

    print("\n  BYTE RATE BY WINDOW  (UDP payload bytes; x8 for bits)", file=out)
    print(f"  {'window':>7} {'p50 B/s':>12} {'p99 B/s':>12} {'p99.9 B/s':>12} "
          f"{'MAX B/s':>14} {'% of 10GbE':>11}", file=out)
    for wsum in j["windows"]:
        w_ns = wsum["window_ns"]
        by = wsum["bytes"]
        def r(v: int) -> str:
            return _fmt_rate(v * 1e9 / w_ns)
        peak_bps = by["max"] * 8 * 1e9 / w_ns
        print(f"  {wsum['window']:>7} {r(by['p50']):>12} {r(by['p99']):>12} "
              f"{r(by['p99_9']):>12} {r(by['max']):>14} "
              f"{100.0 * peak_bps / LINE_RATE_BITS_PER_S:>10.2f}%", file=out)

    # -- inter-arrival --------------------------------------------------------
    print("\n" + "-" * W, file=out)
    print("  INTER-ARRIVAL DISTRIBUTION", file=out)
    print("-" * W, file=out)
    print(f"  {'':>10} {'min':>12} {'p50':>12} {'p99':>12} {'p99.9':>12} {'max':>14}", file=out)
    for label, key in (("message", "message"), ("packet", "packet")):
        d = j["inter_arrival_ns"][key]
        print(f"  {label:>10} {_fmt_ns(d['min']):>12} {_fmt_ns(d['p50']):>12} "
              f"{_fmt_ns(d['p99']):>12} {_fmt_ns(d['p99_9']):>12} {_fmt_ns(d['max']):>14}",
              file=out)
    pp = j["per_packet"]["messages"]
    pb = j["per_packet"]["udp_bytes"]
    print(f"\n  messages per packet   p50={pp['p50']}  p99={pp['p99']}  max={pp['max']}  "
          f"mean={pp['mean']:.2f}", file=out)
    print(f"  UDP bytes per packet  p50={pb['p50']}  p99={pb['p99']}  max={pb['max']}  "
          f"mean={pb['mean']:.1f}", file=out)

    # -- type histogram -------------------------------------------------------
    print("\n" + "-" * W, file=out)
    print("  MESSAGE TYPE HISTOGRAM", file=out)
    print("-" * W, file=out)
    print(f"  {'':1} {'type':<28} {'count':>14} {'pct':>7} {'bytes':>14}  bar", file=out)
    top = j["message_types"][0]["count"] if j["message_types"] else 1
    for row in j["message_types"]:
        bar = "#" * int(28 * row["count"] / max(1, top))
        mark = "*" if row["book"] else " "
        print(f"  {mark} {row['type']} {row['name']:<26.26} {row['count']:>14,} "
              f"{row['pct']:>6.2f}% {row['bytes']:>14,}  {bar}", file=out)
    print("  * = mutates the order book (itch_pkg::is_book_msg)", file=out)

    # -- FIFO sizing ----------------------------------------------------------
    print("\n" + "=" * W, file=out)
    print("  FIFO SIZING — worst-case backlog against a constant drain rate", file=out)
    print("=" * W, file=out)
    for b in j["fifo_sizing"]["buffers"]:
        occ = b["occupancy"]
        print(f"  {b['name']}  (drained at {_fmt_rate(b['service_per_s'])} {b['unit']}/s)", file=out)
        print(f"      peak occupancy      {b['peak_occupancy']:>12,} {b['unit']}   "
              f"at t={format_ts_ns(b['peak_at_ns'] % (86400 * 10**9))}", file=out)
        print(f"      occupancy p50/p99/p99.9  {occ['p50']:,} / {occ['p99']:,} / "
              f"{occ['p99_9']:,} {b['unit']}", file=out)
        print(f"      depth, next power of 2   {b['recommended_depth_pow2']:>12,} {b['unit']}", file=out)
        print(f"      with 2x headroom         {b['recommended_depth_2x_pow2']:>12,} {b['unit']}",
              file=out)
    print(f"\n  {j['fifo_sizing']['note']}", file=out)
    print("\n  ⚠️ CLAUDE.md §5.4: the RX path must never backpressure. If the depth\n"
          "     above is not affordable, the design DROPS and COUNTS — it does not\n"
          "     stall. Decide which, and make the counter visible (§5.7).", file=out)

    # -- parse health ---------------------------------------------------------
    d = j.get("parse_diagnostics") or {}
    sev = d.get("by_severity", {})
    if sev:
        print(f"\n  parse diagnostics  ERROR={sev.get('ERROR', 0)}  "
              f"WARN={sev.get('WARN', 0)}  INFO={sev.get('INFO', 0)}", file=out)
        for code, n in sorted((d.get("counts") or {}).items(), key=lambda kv: -kv[1])[:10]:
            print(f"      {code:<26} {n:>10,}", file=out)
        if sev.get("ERROR"):
            print("  ⚠️ ERROR-severity anomalies: these statistics describe a capture\n"
                  "     that is not clean. Run itch_parse.py --anomalies-only first.", file=out)
    print("", file=out)


def write_series_csv(st: RateStats, path: str) -> None:
    """Rate time series, one row per bin. Small enough to plot, big enough to see."""
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("# bin_start_ns_rel,bin_ns,messages,bytes,msgs_per_s,bytes_per_s\n")
        scale = 1e9 / st.series_bin_ns
        for b in sorted(st.series):
            m, _p, by = st.series[b]
            fh.write(f"{b * st.series_bin_ns},{st.series_bin_ns},{m},{by},"
                     f"{m * scale:.1f},{by * scale:.1f}\n")


# =============================================================================
# 8. CLI
# =============================================================================
def main(argv: Optional[Sequence[str]] = None) -> int:
    p = argparse.ArgumentParser(
        prog="stats.py",
        description="Message-rate and burst analysis for an ITCH capture. "
                    "Reports p50/p99/p99.9/p99.99/max over many window sizes "
                    "and the worst-case FIFO backlog. Never just the mean.",
        epilog="⚠️ Recorded exchange market data is licensed — see "
               "tools/pcap/README.md before moving a capture.",
    )
    p.add_argument("capture", help="pcap / pcapng (.gz ok), or a raw ITCH file with --raw")
    p.add_argument("--raw", action="store_true", help="input is a raw length-prefixed ITCH file")
    p.add_argument("--ports", help="comma-separated UDP destination ports to keep")
    p.add_argument("--groups", help="comma-separated destination IPs to keep")
    p.add_argument("--merge-ab", action="store_true", help="one sequence space across all groups")
    p.add_argument("--windows", default="",
                   help="comma-separated window widths (e.g. 1us,1ms,1s); default "
                        + ",".join(_fmt_window(w) for w in WINDOWS_NS))
    p.add_argument("--service-bytes-per-s", type=float, default=float(FABRIC_BYTES_PER_S),
                   help=f"drain rate for the byte FIFO model (default {FABRIC_BYTES_PER_S:.3g} "
                        "= 64b @ 156.25 MHz = 10 Gb/s)")
    p.add_argument("--service-msgs-per-s", type=float, default=None,
                   help="drain rate for the message FIFO model (default: core clock / 3, "
                        "an ASSUMPTION — replace with the measured decoder rate)")
    p.add_argument("--per-symbol", type=int, default=0, metavar="N",
                   help="also print the top N stock locates by message count")
    p.add_argument("--series", default="1ms", help="time-series bin width (default 1ms; 0 to disable)")
    p.add_argument("--series-out", help="write the rate time series to this CSV")
    p.add_argument("--max-messages", type=int, default=0, help="stop after N messages (0 = all)")
    p.add_argument("--json", nargs="?", const="-", metavar="FILE",
                   help="emit JSON (to FILE, or stdout if given no argument)")
    p.add_argument("--quiet", action="store_true", help="suppress the readable table")
    args = p.parse_args(argv)

    windows = tuple(parse_duration_ns(w) for w in args.windows.split(",")) if args.windows else WINDOWS_NS
    series_ns = parse_duration_ns(args.series) if args.series and args.series != "0" else 0

    try:
        st = analyse(
            args.capture,
            ports=[int(x) for x in args.ports.split(",")] if args.ports else None,
            groups=[x.strip() for x in args.groups.split(",")] if args.groups else None,
            raw_itch=args.raw,
            merge_ab=args.merge_ab,
            windows=windows,
            series_bin_ns=series_ns,
            service_bytes_per_s=args.service_bytes_per_s,
            service_msgs_per_s=args.service_msgs_per_s,
            max_messages=args.max_messages,
        )
    except (OSError, ValueError) as e:
        print(f"stats: cannot analyse {args.capture}: {e}", file=sys.stderr)
        return 2

    if st.n_msgs == 0:
        print(f"stats: no ITCH messages decoded from {args.capture}. "
              "Wrong port filter, wrong file, or an empty capture — check with "
              "`itch_parse.py --anomalies-only` before believing this.", file=sys.stderr)
        return 2

    if not args.quiet:
        print_report(st, sys.stdout)
        if args.per_symbol:
            j = to_json(st)
            print(f"  TOP {args.per_symbol} STOCK LOCATES BY MESSAGE COUNT", file=sys.stdout)
            print(f"  {'locate':>8} {'messages':>14} {'pct':>7}", file=sys.stdout)
            for row in j["top_locates"][: args.per_symbol]:
                print(f"  {row['locate']:>8} {row['messages']:>14,} {row['pct']:>6.2f}%")
            print("  (locate -> ticker needs the Stock Directory 'R' messages; "
                  "itch_parse.py --types R prints them)\n")

    if args.series_out and st.series:
        write_series_csv(st, args.series_out)
        if not args.quiet:
            print(f"  wrote time series: {args.series_out} "
                  f"({len(st.series):,} bins of {_fmt_window(st.series_bin_ns)})\n")

    if args.json:
        payload = json.dumps(to_json(st), indent=2, default=str)
        if args.json == "-":
            print(payload)
        else:
            with open(args.json, "w", encoding="utf-8") as fh:
                fh.write(payload + "\n")
            if not args.quiet:
                print(f"  wrote JSON: {args.json}\n")

    errs = (st.reader_summary.get("diagnostics", {})
            .get("by_severity", {}).get("ERROR", 0))
    return 1 if errs else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:  # pragma: no cover - `| head`
        sys.exit(0)
