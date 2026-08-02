#!/usr/bin/env python3
"""Corpus manifest management for the ITCH pcap regression corpus.

Project : FPGA Algorithmic Trading System (Nasdaq Equities)
Governs : manuals/06-operations/04-testing-strategy.md  §4 (required corpus),
                                                        §12 (corpus management)
          TASKS.md P1.1 (acquire and organize the corpus)

===============================================================================
⚠️  MARKET DATA IS LICENSED. RECORDED EXCHANGE DATA IS NOT FREELY SHAREABLE.
===============================================================================
Read this before you copy a single capture anywhere.

A pcap of a live exchange feed is **licensed market data**, not a test fixture
you happen to own. Depending on the agreement it was received under, moving it
can be a distribution event with contractual and regulatory consequences:

  * Copying a capture to a laptop, a cloud bucket, a CI runner outside the
    firm, a vendor's support ticket, a public bug report, or a git remote that
    anyone outside the entitled entity can read, may each count as
    redistribution.
  * Derived data can inherit the restriction. A slice is still market data. A
    file of decoded top-of-book prints is very often still market data. An
    aggregate statistic usually is not — but "usually" is not a legal opinion.
  * Non-display / non-professional / internal-use-only entitlements are common
    and are narrower than people assume.
  * Nasdaq's published *sample* TotalView-ITCH files come with their own terms.
    "It was on a public web page" is not the same as "it is unrestricted", and
    the terms attached to a sample file can differ from the terms attached to
    your production feed.

This tool therefore makes the licensing status a **required, enumerated field**
on every corpus entry (:data:`REDISTRIBUTION`), refuses to write an entry
without one, and refuses to produce a shareable export while any entry is
``unknown`` or restricted. That is a speed bump, not a compliance function.

> **Verify:** the actual rights are set by *your* Nasdaq market data agreement
> (and by the terms on the sample-file download page, which are separate).
> Confirm with the person responsible for market data compliance at your firm
> before a capture leaves the environment it was recorded in. Nothing in this
> file is legal advice and none of these enum values is a legal determination.

Synthetic captures produced by ``synth.py`` carry no exchange data and are the
only class this tool treats as freely shareable — see :data:`REDISTRIBUTION`.

===============================================================================
WHAT THE MANIFEST IS
===============================================================================
pcaps are large; a full-session TotalView-ITCH capture is many gigabytes. Git
handles that badly and CI handles it worse. So:

    the captures live in an object store; **the manifest is the versioned
    artifact**, and it lives in git.

The manifest records, per entry, what the capture is, which market condition it
covers, where to get it, how big it is, its SHA-256, what the reference parser
found in it, where it came from, and what its redistribution status is. A
regression run cites the manifest digest (``corpus.py version``); that digest
plus the RTL git SHA is enough to reproduce a result exactly.

Two rules from manuals/06-operations/04-testing-strategy.md §12 are encoded
here as behaviour rather than prose:

  * **Synthetic entries commit the generator and the seed, not the output.** An
    entry with ``origin: synthetic`` must carry ``synthetic.generator``,
    ``synthetic.version``, ``synthetic.seed`` and ``synthetic.argv``, and
    ``corpus.py verify`` re-runs nothing but tells you the entry is
    reproducible from those four fields.
  * **Keep every corpus entry that ever caught a bug, forever, with a comment
    naming the bug.** ``corpus.py remove`` refuses to delete an entry whose
    ``caught_bug`` field is set.

===============================================================================
Dependencies
===============================================================================
Standard library only, matching ``itch_parse.py``. The canonical on-disk format
is therefore **JSON**, not YAML.

⚠️ manuals/06-operations/04-testing-strategy.md §12 and TASKS.md P1.1 both name
   ``tb/corpus/manifest.yaml``. This tool writes ``manifest.json`` by default
   because a stdlib-only tool cannot parse YAML, and a hand-rolled YAML parser
   in the one file that decides which market data is authoritative is a bad
   trade. Three ways to resolve it, pick one deliberately:
     1. change the two documents to say ``manifest.json`` (recommended), or
     2. accept a PyYAML dependency for the corpus tooling only — this tool
        *will* read ``.yaml`` if PyYAML happens to be importable, or
     3. keep JSON canonical and regenerate a YAML rendering for humans with
        ``corpus.py export --format yaml`` (that direction is emit-only and
        safe).
   Until someone decides, this file does 1 and 3 and tolerates 2.

Usage
-----
    python3 tools/pcap/corpus.py init
    python3 tools/pcap/corpus.py add open_20240315.pcap.gz \\
        --tag open --market-date 2024-03-15 --origin colo-tap \\
        --redistribution restricted --scan
    python3 tools/pcap/corpus.py list --tag open
    python3 tools/pcap/corpus.py verify --all --cache ./corpus-cache
    python3 tools/pcap/corpus.py coverage
    python3 tools/pcap/corpus.py version

Exit status: 0 = OK, 1 = a check failed (missing coverage, bad checksum,
unknown licensing), 2 = usage or I/O error. Suitable as a CI gate.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

__all__ = [
    "MANIFEST_VERSION",
    "REQUIRED_TAGS",
    "TAGS",
    "REDISTRIBUTION",
    "ORIGINS",
    "Manifest",
    "sha256_file",
    "LICENSE_NOTICE",
]

VERSION = "1.0.0"

#: Bump when the entry schema changes incompatibly. Readers must refuse a
#: manifest whose version they do not understand rather than guess.
MANIFEST_VERSION = 1

DEFAULT_MANIFEST = os.path.join("tb", "corpus", "manifest.json")

LICENSE_NOTICE = """\
⚠️  MARKET DATA LICENSING — READ BEFORE MOVING ANY CAPTURE
    Recorded exchange market data is licensed and is generally NOT freely
    shareable. Copying a capture out of the environment it was recorded in —
    to a laptop, a cloud bucket, an external CI runner, a vendor support
    ticket, a public issue, or a git remote — may be redistribution under your
    market data agreement. Slices and decoded derivatives usually inherit the
    restriction. Nasdaq's public *sample* ITCH files carry their own separate
    terms.
    > Verify: your Nasdaq market data agreement and the terms on the sample
      file download page. Ask market data compliance. This tool's enum is a
      speed bump, not a legal determination."""

# =============================================================================
# 1. Controlled vocabularies
# =============================================================================
#: Market-condition tags. The first ten are the corpus required by
#: manuals/06-operations/04-testing-strategy.md §4 — a corpus missing any of
#: them has a blind spot with a known name.
REQUIRED_TAGS: Tuple[str, ...] = (
    "normal_day",         # baseline: full session, ordinary volumes
    "open",               # 09:30 ET opening cross and the burst after it
    "close",              # 16:00 ET closing cross, NOII, large volume
    "halt_resume",        # halt, quoting period, re-open auction
    "volatile_day",       # high volume, wide spreads: FIFO and depth stress
    "seq_gap",            # a genuine sequence gap and its recovery
    "luld_band",          # LULD band update and a symbol hitting a band
    "ipo_or_new_symbol",  # Stock Directory, IPO quoting, mid-session symbol
    "crossed_locked",     # legitimately crossed or locked book
    "microburst",         # highest packets-per-microsecond window available
)

#: Additional tags that are useful but not gating.
OPTIONAL_TAGS: Tuple[str, ...] = (
    "half_day",           # ⚠️ early close (13:00 ET); the close burst moves
    "ssr_trigger",        # Reg SHO Rule 201 short-sale restriction trigger
    "corner",             # crafted corner-case stream (TASKS.md P1.10)
    "fault",              # deliberately corrupted stream for fault injection
    "soak",               # long-run stability input
    "quiet",              # low-rate period; useful as a latency baseline
)

TAGS: Tuple[str, ...] = REQUIRED_TAGS + OPTIONAL_TAGS

#: Convenience aliases so the shorthand people actually type resolves to the
#: canonical tag. Ambiguity is resolved here, once, and not in ten scripts.
TAG_ALIASES: Dict[str, str] = {
    "normal": "normal_day",
    "baseline": "normal_day",
    "opening": "open",
    "closing": "close",
    "halt": "halt_resume",
    "resume": "halt_resume",
    "volatile": "volatile_day",
    "gap": "seq_gap",
    "ipo": "ipo_or_new_symbol",
    "new_symbol": "ipo_or_new_symbol",
    "luld": "luld_band",
    "locked": "crossed_locked",
    "crossed": "crossed_locked",
    "burst": "microburst",
    "halfday": "half_day",
    "ssr": "ssr_trigger",
}

#: Where the bytes came from. Drives what the licensing default should be and
#: what "reproducible" means.
ORIGINS: Dict[str, str] = {
    "nasdaq-sample": "downloaded from a Nasdaq-published sample file page",
    "colo-tap": "captured from an optical tap in our own colo rack",
    "vendor-capture": "supplied by a market data or hardware vendor",
    "internal-replay": "re-captured from our own replay of another entry",
    "synthetic": "generated by tools/pcap/synth.py — contains NO exchange data",
    "derived": "a slice or transform of another entry in this manifest",
}

#: ⚠️ Redistribution status. REQUIRED on every entry. There is deliberately no
#: default: a human decides, and the decision is recorded next to the data.
REDISTRIBUTION: Dict[str, str] = {
    "unknown": (
        "NOT YET DETERMINED — treat as restricted. Blocks a shareable export "
        "and fails `corpus.py license`. This is the value you must resolve."
    ),
    "restricted": (
        "licensed exchange data; do NOT move it outside the entitled "
        "environment without checking the market data agreement"
    ),
    "internal-only": (
        "may be used inside the firm by entitled staff; must not leave the "
        "firm, including to vendors and public issue trackers"
    ),
    "sample-terms": (
        "vendor/exchange sample file governed by the terms on its download "
        "page — read them; they are not the same as your feed agreement"
    ),
    "synthetic-unrestricted": (
        "generated locally, contains no exchange data, freely shareable"
    ),
}

#: Statuses that may appear in an export intended to leave the firm.
SHAREABLE = frozenset({"synthetic-unrestricted"})

#: Fields every entry must carry. Missing any of these is a manifest error.
REQUIRED_FIELDS: Tuple[str, ...] = (
    "name", "tag", "description", "file", "sha256", "size_bytes",
    "origin", "redistribution", "added_utc",
)


# =============================================================================
# 2. Hashing
# =============================================================================
def sha256_file(path: str, chunk: int = 4 << 20) -> Tuple[str, int]:
    """Stream a file through SHA-256. Returns (hexdigest, size_bytes).

    Chunked because corpus entries are gigabytes; this must never load a
    capture into memory.
    """
    h = hashlib.sha256()
    n = 0
    with open(path, "rb") as fh:
        while True:
            b = fh.read(chunk)
            if not b:
                break
            h.update(b)
            n += len(b)
    return h.hexdigest(), n


def _canonical_json(obj: Any) -> str:
    """Stable serialization: sorted keys, fixed separators, trailing newline.

    Stability matters twice — the manifest digest is taken over this, and a
    manifest that reorders itself on every write produces unreadable diffs.
    """
    return json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def _now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# =============================================================================
# 3. The manifest
# =============================================================================
@dataclass
class Manifest:
    """The versioned index. Entries are dicts, kept sorted by name."""

    path: str
    manifest_version: int = MANIFEST_VERSION
    store: Dict[str, Any] = None          # type: ignore[assignment]
    entries: List[Dict[str, Any]] = None  # type: ignore[assignment]
    updated_utc: str = ""

    def __post_init__(self) -> None:
        if self.store is None:
            self.store = {
                "base_url": "",
                "note": (
                    "Captures live here, NOT in git. See tools/pcap/README.md. "
                    "Access to this store is itself an entitlement question."
                ),
            }
        if self.entries is None:
            self.entries = []

    # -- load / save ----------------------------------------------------------
    @classmethod
    def load(cls, path: str) -> "Manifest":
        raw = _read_structured(path)
        ver = raw.get("manifest_version")
        if ver != MANIFEST_VERSION:
            raise ValueError(
                f"{path}: manifest_version {ver!r}, this tool understands "
                f"{MANIFEST_VERSION}. Refusing to guess — an unrecognised "
                "schema silently mis-reads corpus provenance."
            )
        m = cls(
            path=path,
            manifest_version=ver,
            store=raw.get("store") or None,
            entries=list(raw.get("entries") or []),
            updated_utc=raw.get("updated_utc", ""),
        )
        m.entries.sort(key=lambda e: e.get("name", ""))
        return m

    def save(self) -> None:
        self.entries.sort(key=lambda e: e.get("name", ""))
        self.updated_utc = _now_utc()
        os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
        body = _canonical_json(self.to_dict())
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(body)
        os.replace(tmp, self.path)   # atomic: never a half-written manifest

    def to_dict(self) -> Dict[str, Any]:
        return {
            "manifest_version": self.manifest_version,
            "generated_by": f"tools/pcap/corpus.py {VERSION}",
            "updated_utc": self.updated_utc,
            "licensing_notice": (
                "Recorded exchange market data is licensed and generally not "
                "freely shareable. Every entry carries a `redistribution` "
                "field. See tools/pcap/README.md before moving any capture."
            ),
            "store": self.store,
            "entries": self.entries,
        }

    # -- digest ---------------------------------------------------------------
    @property
    def digest(self) -> str:
        """SHA-256 over the canonical entry list. THIS is the corpus version.

        Deliberately excludes ``updated_utc`` and ``generated_by``: rewriting
        the manifest without changing the corpus must not change the version a
        regression cites.
        """
        payload = _canonical_json({"manifest_version": self.manifest_version,
                                   "entries": self.entries})
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()

    @property
    def short_digest(self) -> str:
        return self.digest[:12]

    # -- queries --------------------------------------------------------------
    def get(self, name: str) -> Optional[Dict[str, Any]]:
        for e in self.entries:
            if e.get("name") == name:
                return e
        return None

    def by_tag(self, tag: str) -> List[Dict[str, Any]]:
        return [e for e in self.entries if e.get("tag") == tag]

    def coverage(self) -> Dict[str, List[str]]:
        """Required tag -> names of entries covering it (possibly empty)."""
        return {t: [e["name"] for e in self.by_tag(t)] for t in REQUIRED_TAGS}

    # -- mutation -------------------------------------------------------------
    def upsert(self, entry: Dict[str, Any], *, replace: bool = False) -> str:
        name = entry["name"]
        existing = self.get(name)
        if existing is not None:
            if not replace:
                raise ValueError(
                    f"entry {name!r} already exists (sha256 "
                    f"{existing.get('sha256', '?')[:12]}…). Use --replace to "
                    "overwrite, or pick another name. Silently overwriting a "
                    "corpus entry invalidates every result that cited it."
                )
            entry.setdefault("added_utc", existing.get("added_utc", _now_utc()))
            entry["superseded_utc"] = _now_utc()
            self.entries.remove(existing)
        self.entries.append(entry)
        return name

    def remove(self, name: str, *, force: bool = False) -> Dict[str, Any]:
        e = self.get(name)
        if e is None:
            raise KeyError(name)
        bug = e.get("caught_bug")
        if bug and not force:
            raise ValueError(
                f"entry {name!r} is marked as having caught a bug ({bug!r}).\n"
                "manuals/06-operations/04-testing-strategy.md §12: keep every "
                "corpus entry that ever caught a bug, forever. Use --force "
                "only if you can say why the bug it covers can never recur."
            )
        self.entries.remove(e)
        return e


def _read_structured(path: str) -> Dict[str, Any]:
    """Read JSON, or YAML if the file is YAML *and* PyYAML is importable."""
    if path.endswith((".yaml", ".yml")):
        try:
            import yaml  # type: ignore
        except ImportError:
            raise ValueError(
                f"{path} is YAML but PyYAML is not installed, and this tool is "
                "stdlib-only by policy. Convert to JSON "
                "(`corpus.py export --format json`), point --manifest at a "
                ".json file, or install PyYAML. See this module's docstring "
                "for the open decision."
            ) from None
        with open(path, "r", encoding="utf-8") as fh:
            return yaml.safe_load(fh) or {}
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


# =============================================================================
# 4. Entry construction
# =============================================================================
def canonical_tag(tag: str) -> str:
    t = tag.strip().lower().replace("-", "_")
    t = TAG_ALIASES.get(t, t)
    if t not in TAGS:
        raise ValueError(
            f"unknown tag {tag!r}. Known tags: {', '.join(TAGS)}\n"
            f"(aliases: {', '.join(sorted(TAG_ALIASES))})"
        )
    return t


def scan_capture(path: str, *, ports: Optional[Sequence[int]] = None,
                 raw_itch: bool = False) -> Dict[str, Any]:
    """Run the reference parser over a capture and summarize it for the entry.

    ⚠️ This is where a bad capture gets caught, *before* it becomes a fixture.
    A corpus entry with unexplained ERROR-severity anomalies teaches the
    regression to accept them
    (manuals/06-operations/04-testing-strategy.md §4).
    """
    try:
        from itch_parse import ItchReader, ANOMALY_CATALOG, Severity
    except ImportError:  # invoked from outside tools/pcap
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from itch_parse import ItchReader, ANOMALY_CATALOG, Severity  # type: ignore

    r = ItchReader(path, ports=ports, raw_itch=raw_itch)
    first_itch: Optional[int] = None
    last_itch: Optional[int] = None
    locates = set()
    for m in r.messages():
        if m.ts_ns:
            if first_itch is None or m.ts_ns < first_itch:
                first_itch = m.ts_ns
            if last_itch is None or m.ts_ns > last_itch:
                last_itch = m.ts_ns
        locates.add(m.locate)
    s = r.summary()
    errs = {c: n for c, n in r.diag.counts.items()
            if ANOMALY_CATALOG.get(c, (Severity.ERROR, ""))[0] == Severity.ERROR}
    return {
        "packet_count": s["packets_moldudp64"],
        "message_count": s["messages_decoded"],
        "message_types": {lbl.split()[0]: n for lbl, n in s["messages_by_type"].items()},
        "distinct_locates": len(locates),
        "capture_duration_s": s["capture_duration_s"],
        "itch_first_ts_ns": first_itch,
        "itch_last_ts_ns": last_itch,
        "sessions": sorted(s["sessions"]),
        "anomaly_counts": dict(sorted(r.diag.counts.items())),
        "error_anomalies": dict(sorted(errs.items())),
        "parser_version": s["tool_version"],
    }


def build_entry(
    path: str,
    *,
    name: Optional[str],
    tag: str,
    description: str,
    origin: str,
    redistribution: str,
    market_date: str = "",
    session: str = "regular",
    venue: str = "nasdaq",
    feed: str = "totalview-itch-5.0/moldudp64",
    symbols: Optional[Sequence[str]] = None,
    window_et: str = "",
    url: str = "",
    short_set: bool = False,
    caught_bug: str = "",
    provenance: str = "",
    license_note: str = "",
    derived_from: str = "",
    synthetic: Optional[Dict[str, Any]] = None,
    expected_anomalies: Optional[Dict[str, int]] = None,
    scan: bool = False,
    ports: Optional[Sequence[int]] = None,
    raw_itch: bool = False,
) -> Dict[str, Any]:
    """Assemble one manifest entry from a local file. Hashes it, always."""
    if origin not in ORIGINS:
        raise ValueError(f"unknown origin {origin!r}; known: {', '.join(sorted(ORIGINS))}")
    if redistribution not in REDISTRIBUTION:
        raise ValueError(
            f"unknown redistribution {redistribution!r}; known: "
            f"{', '.join(sorted(REDISTRIBUTION))}"
        )
    if origin == "synthetic" and redistribution != "synthetic-unrestricted":
        # Not fatal — someone may have seeded a synthetic stream from real
        # prices, which makes it derived. Say so out loud rather than assume.
        print(
            f"note: origin=synthetic but redistribution={redistribution!r}. "
            "That is only right if the generator was seeded with real market "
            "data; if it was not, use --redistribution synthetic-unrestricted.",
            file=sys.stderr,
        )
    if origin != "synthetic" and redistribution == "synthetic-unrestricted":
        raise ValueError(
            "redistribution=synthetic-unrestricted is only valid with "
            "origin=synthetic. Marking recorded exchange data as unrestricted "
            "is the mistake this field exists to prevent."
        )
    if origin == "derived" and not derived_from:
        raise ValueError("origin=derived requires --derived-from NAME "
                         "(a slice inherits its parent's licensing)")

    digest, size = sha256_file(path)
    entry: Dict[str, Any] = {
        "name": name or os.path.basename(path).split(".")[0],
        "tag": canonical_tag(tag),
        "description": description,
        "venue": venue,
        "feed": feed,
        "market_date": market_date,
        "session": session,
        "window_et": window_et,
        "symbols": list(symbols) if symbols else ["*"],
        "file": os.path.basename(path),
        "url": url,
        "size_bytes": size,
        "sha256": digest,
        "origin": origin,
        "provenance": provenance,
        "redistribution": redistribution,
        "license_note": license_note,
        "short_set": bool(short_set),
        "added_utc": _now_utc(),
        "added_by_tool": f"corpus.py {VERSION}",
    }
    if caught_bug:
        entry["caught_bug"] = caught_bug
    if derived_from:
        entry["derived_from"] = derived_from
    if synthetic:
        entry["synthetic"] = synthetic
    if expected_anomalies:
        # ⚠️ Anomalies a corpus entry is SUPPOSED to contain (a seq_gap entry
        #    contains a SEQ_GAP by definition). Recorded so the regression can
        #    assert on them instead of waiving them.
        entry["expected_anomalies"] = dict(expected_anomalies)
    if scan:
        entry["scan"] = scan_capture(path, ports=ports, raw_itch=raw_itch)
    return entry


def validate_entry(e: Dict[str, Any]) -> List[str]:
    """Return a list of problems with one entry. Empty list = well formed."""
    problems: List[str] = []
    for f in REQUIRED_FIELDS:
        if not e.get(f) and e.get(f) != 0:
            problems.append(f"missing required field {f!r}")
    tag = e.get("tag")
    if tag and tag not in TAGS:
        problems.append(f"tag {tag!r} is not in the controlled vocabulary")
    origin = e.get("origin")
    if origin and origin not in ORIGINS:
        problems.append(f"origin {origin!r} is not in the controlled vocabulary")
    red = e.get("redistribution")
    if red and red not in REDISTRIBUTION:
        problems.append(f"redistribution {red!r} is not in the controlled vocabulary")
    if red == "unknown":
        problems.append(
            "redistribution is 'unknown' — resolve it with market data "
            "compliance; until then treat the entry as restricted"
        )
    sha = e.get("sha256", "")
    if sha and (len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha)):
        problems.append("sha256 is not 64 lowercase hex characters")
    if origin == "synthetic":
        syn = e.get("synthetic") or {}
        for f in ("generator", "version", "seed", "argv"):
            if f not in syn:
                problems.append(
                    f"origin=synthetic but synthetic.{f} is missing — §12 says "
                    "commit the generator and the seed, not the output"
                )
    if origin == "derived" and not e.get("derived_from"):
        problems.append("origin=derived but derived_from is missing")
    scan = e.get("scan") or {}
    if scan.get("error_anomalies") and not e.get("expected_anomalies"):
        problems.append(
            f"scan found ERROR anomalies {sorted(scan['error_anomalies'])} but "
            "expected_anomalies is empty — either explain them there or do not "
            "promote this capture"
        )
    return problems


# =============================================================================
# 5. Local cache / fetch
# =============================================================================
def local_path(entry: Dict[str, Any], cache: str) -> str:
    return os.path.join(cache, entry.get("file") or entry["name"])


def verify_entry(entry: Dict[str, Any], cache: str) -> Tuple[str, str]:
    """Check a cached file against the manifest. Returns (status, detail).

    Status is one of: ok, missing, size-mismatch, hash-mismatch.
    ⚠️ SHA-256 is the authority here, not the URL and not the filename. A
    corpus entry that hashes differently is a different corpus entry, and any
    result that cited the old one no longer means anything.
    """
    p = local_path(entry, cache)
    if not os.path.exists(p):
        return "missing", p
    size = os.path.getsize(p)
    if size != entry.get("size_bytes"):
        return "size-mismatch", f"{size} on disk vs {entry.get('size_bytes')} in manifest"
    digest, _ = sha256_file(p)
    if digest != entry.get("sha256"):
        return "hash-mismatch", f"{digest[:16]}… on disk vs {str(entry.get('sha256'))[:16]}… in manifest"
    return "ok", p


def fetch_entry(entry: Dict[str, Any], cache: str, *, force: bool = False) -> Tuple[str, str]:
    """Fetch one entry into the cache and verify it. Returns (status, detail)."""
    url = entry.get("url") or ""
    if not url:
        return "no-url", "entry has no url; fetch it by hand and place it in the cache"
    dest = local_path(entry, cache)
    if not force:
        st, detail = verify_entry(entry, cache)
        if st == "ok":
            return "cached", dest
    os.makedirs(cache, exist_ok=True)
    tmp = dest + ".part"
    scheme = urllib.parse.urlparse(url).scheme
    if scheme in ("", "file"):
        src = url[7:] if scheme == "file" else url
        shutil.copyfile(src, tmp)
    elif scheme in ("http", "https"):
        with urllib.request.urlopen(url) as resp, open(tmp, "wb") as out:  # noqa: S310
            shutil.copyfileobj(resp, out, 4 << 20)
    else:
        return "unsupported-scheme", (
            f"{scheme!r}: fetch by hand. s3:// and gs:// deliberately are not "
            "implemented here — credentials for the corpus store do not belong "
            "in this tool."
        )
    os.replace(tmp, dest)
    st, detail = verify_entry(entry, cache)
    if st != "ok":
        return f"fetched-but-{st}", detail
    return "fetched", dest


# =============================================================================
# 6. YAML export (emit only — parsing YAML is out of scope, see docstring)
# =============================================================================
def _yaml_scalar(v: Any) -> str:
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    s = str(v)
    # Quote unconditionally: cheap, and it removes every YAML footgun at once
    # (leading zeros, ':', '#', 'yes', '1.0', empty string, ...).
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def to_yaml(obj: Any, indent: int = 0) -> str:
    """Restricted YAML emitter for dict/list/scalar trees. Emit only."""
    pad = "  " * indent
    if isinstance(obj, dict):
        if not obj:
            return pad + "{}\n"
        out = []
        for k, v in obj.items():
            if isinstance(v, (dict, list)) and v:
                out.append(f"{pad}{k}:\n{to_yaml(v, indent + 1)}")
            else:
                out.append(f"{pad}{k}: {_yaml_scalar(v) if not isinstance(v, (dict, list)) else ('{}' if isinstance(v, dict) else '[]')}\n")
        return "".join(out)
    if isinstance(obj, list):
        if not obj:
            return pad + "[]\n"
        out = []
        for item in obj:
            if isinstance(item, (dict, list)) and item:
                body = to_yaml(item, indent + 1)
                first, _, rest = body.partition("\n")
                out.append(f"{pad}- {first.strip()}\n{rest}")
            else:
                out.append(f"{pad}- {_yaml_scalar(item)}\n")
        return "".join(out)
    return pad + _yaml_scalar(obj) + "\n"


# =============================================================================
# 7. CLI
# =============================================================================
def _fmt_bytes(n: int) -> str:
    f = float(n)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if f < 1024 or unit == "TiB":
            return f"{f:,.1f} {unit}" if unit != "B" else f"{int(f)} B"
        f /= 1024
    return f"{n} B"


def _cmd_init(args: argparse.Namespace) -> int:
    if os.path.exists(args.manifest) and not args.force:
        print(f"corpus: {args.manifest} already exists (use --force to reset)", file=sys.stderr)
        return 2
    m = Manifest(path=args.manifest)
    if args.base_url:
        m.store["base_url"] = args.base_url
    m.save()
    print(f"initialised {args.manifest} (manifest_version {MANIFEST_VERSION})")
    print(f"corpus version: {m.short_digest}  (empty corpus)")
    print()
    print(LICENSE_NOTICE)
    return 0


def _cmd_add(args: argparse.Namespace) -> int:
    m = Manifest.load(args.manifest)
    syn = None
    if args.synth_seed is not None or args.synth_argv:
        syn = {
            "generator": args.synth_generator,
            "version": args.synth_version,
            "seed": args.synth_seed,
            "argv": args.synth_argv.split() if args.synth_argv else [],
        }
    expected = {}
    for kv in args.expect or []:
        code, _, n = kv.partition("=")
        expected[code.strip()] = int(n) if n else 1
    try:
        entry = build_entry(
            args.path,
            name=args.name,
            tag=args.tag,
            description=args.description,
            origin=args.origin,
            redistribution=args.redistribution,
            market_date=args.market_date,
            session=args.session,
            venue=args.venue,
            feed=args.feed,
            symbols=args.symbols.split(",") if args.symbols else None,
            window_et=args.window_et,
            url=args.url,
            short_set=args.short_set,
            caught_bug=args.caught_bug,
            provenance=args.provenance,
            license_note=args.license_note,
            derived_from=args.derived_from,
            synthetic=syn,
            expected_anomalies=expected,
            scan=args.scan,
            ports=[int(x) for x in args.ports.split(",")] if args.ports else None,
            raw_itch=args.raw,
        )
    except (ValueError, OSError) as e:
        print(f"corpus add: {e}", file=sys.stderr)
        return 2

    problems = validate_entry(entry)
    hard = [p for p in problems if "unknown" not in p or args.strict]
    if problems:
        print(f"⚠️  entry {entry['name']!r} has {len(problems)} problem(s):", file=sys.stderr)
        for p in problems:
            print(f"    - {p}", file=sys.stderr)
        if hard and not args.allow_problems:
            print("refusing to add. Fix them, or re-run with --allow-problems "
                  "and explain in --license-note / --provenance.", file=sys.stderr)
            return 1
    try:
        m.upsert(entry, replace=args.replace)
    except ValueError as e:
        print(f"corpus add: {e}", file=sys.stderr)
        return 2
    m.save()
    print(f"added {entry['name']!r}  tag={entry['tag']}  "
          f"{_fmt_bytes(entry['size_bytes'])}  sha256={entry['sha256'][:12]}…")
    if entry.get("scan"):
        s = entry["scan"]
        print(f"  scanned: {s['message_count']:,} messages, {s['packet_count']:,} packets, "
              f"{s['distinct_locates']:,} distinct locates")
        if s["error_anomalies"]:
            print(f"  ⚠️  ERROR anomalies: {s['error_anomalies']}")
    print(f"corpus version now: {m.short_digest}")
    return 0


def _cmd_list(args: argparse.Namespace) -> int:
    m = Manifest.load(args.manifest)
    entries = m.entries
    if args.tag:
        entries = [e for e in entries if e.get("tag") == canonical_tag(args.tag)]
    if args.short_set:
        entries = [e for e in entries if e.get("short_set")]
    if args.json:
        print(json.dumps(entries, indent=2, sort_keys=True))
        return 0
    if not entries:
        print("(no matching entries)")
        return 0
    print(f"corpus version {m.short_digest}   {len(entries)} entr{'y' if len(entries) == 1 else 'ies'}")
    print(f"{'name':<28} {'tag':<18} {'date':<11} {'size':>10} {'msgs':>12}  {'redist':<22} short")
    print("-" * 116)
    total = 0
    for e in entries:
        scan = e.get("scan") or {}
        total += e.get("size_bytes", 0)
        print(f"{e.get('name', '?'):<28.28} {e.get('tag', '?'):<18.18} "
              f"{e.get('market_date', ''):<11.11} "
              f"{_fmt_bytes(e.get('size_bytes', 0)):>10} "
              f"{scan.get('message_count', 0):>12,}  "
              f"{e.get('redistribution', 'unknown'):<22.22} "
              f"{'yes' if e.get('short_set') else '-'}")
    print("-" * 116)
    print(f"{'total':<28} {'':<18} {'':<11} {_fmt_bytes(total):>10}")
    restricted = [e["name"] for e in entries if e.get("redistribution") not in SHAREABLE]
    if restricted:
        print(f"\n⚠️  {len(restricted)} of these are licensed market data and must not "
              "leave the entitled environment. `corpus.py license` lists them.")
    return 0


def _cmd_show(args: argparse.Namespace) -> int:
    m = Manifest.load(args.manifest)
    e = m.get(args.name)
    if e is None:
        print(f"corpus: no entry named {args.name!r}", file=sys.stderr)
        return 2
    print(json.dumps(e, indent=2, sort_keys=True))
    problems = validate_entry(e)
    if problems:
        print("\n⚠️  problems:", file=sys.stderr)
        for p in problems:
            print(f"    - {p}", file=sys.stderr)
        return 1
    return 0


def _cmd_verify(args: argparse.Namespace) -> int:
    m = Manifest.load(args.manifest)
    entries = [m.get(n) for n in args.name] if args.name else m.entries
    if any(e is None for e in entries):
        print("corpus verify: unknown entry name", file=sys.stderr)
        return 2
    bad = 0
    schema_bad = 0
    print(f"corpus version {m.short_digest}   cache {args.cache}")
    print(f"{'name':<28} {'schema':<8} {'bytes':<16} detail")
    print("-" * 100)
    for e in entries:                      # type: ignore[assignment]
        problems = validate_entry(e)       # type: ignore[arg-type]
        if problems:
            schema_bad += 1
        if args.schema_only:
            st, detail = "-", ""
        else:
            st, detail = verify_entry(e, args.cache)  # type: ignore[arg-type]
        if st in ("hash-mismatch", "size-mismatch"):
            bad += 1
        elif st == "missing" and args.require_present:
            bad += 1
        print(f"{e['name']:<28.28} {'FAIL' if problems else 'ok':<8} {st:<16} {detail}")  # type: ignore[index]
        for p in problems:
            print(f"    ⚠️  {p}")
    print("-" * 100)
    print(f"{len(entries)} entries, {schema_bad} with schema problems, {bad} with byte problems")
    if bad:
        print("\n⚠️  A checksum mismatch means the file on disk is NOT the file the\n"
              "    manifest describes. Every regression result that cited this\n"
              "    corpus version is now unverifiable. Re-fetch, or investigate.")
    return 1 if (bad or (schema_bad and args.strict)) else 0


def _cmd_fetch(args: argparse.Namespace) -> int:
    m = Manifest.load(args.manifest)
    entries = [m.get(n) for n in args.name] if args.name else m.entries
    if any(e is None for e in entries):
        print("corpus fetch: unknown entry name", file=sys.stderr)
        return 2
    print(LICENSE_NOTICE)
    print()
    rc = 0
    for e in entries:                      # type: ignore[assignment]
        base = m.store.get("base_url", "")
        if not e.get("url") and base:      # type: ignore[union-attr]
            e = dict(e)                    # type: ignore[arg-type]
            e["url"] = base.rstrip("/") + "/" + e["file"]
        try:
            st, detail = fetch_entry(e, args.cache, force=args.force)  # type: ignore[arg-type]
        except OSError as ex:
            st, detail = "error", str(ex)
        if st not in ("fetched", "cached"):
            rc = 1
        print(f"{e['name']:<28.28} {st:<22} {detail}")  # type: ignore[index]
    return rc


def _cmd_coverage(args: argparse.Namespace) -> int:
    m = Manifest.load(args.manifest)
    cov = m.coverage()
    missing = [t for t, names in cov.items() if not names]
    print(f"corpus version {m.short_digest}")
    print("Required corpus — manuals/06-operations/04-testing-strategy.md §4")
    print(f"{'required tag':<20} {'entries':>7}  covered by")
    print("-" * 78)
    for t in REQUIRED_TAGS:
        names = cov[t]
        mark = "  " if names else "⚠️"
        print(f"{mark}{t:<18} {len(names):>7}  {', '.join(names[:3]) or '— NOT COVERED —'}"
              + (f" (+{len(names) - 3} more)" if len(names) > 3 else ""))
    print("-" * 78)
    extra = sorted({e.get("tag", "") for e in m.entries} - set(REQUIRED_TAGS))
    if extra:
        print(f"additional tags present: {', '.join(extra)}")
    short = [e["name"] for e in m.entries if e.get("short_set")]
    print(f"short set (per-PR CI): {len(short)} entr{'y' if len(short) == 1 else 'ies'}"
          + (f" — {', '.join(short[:6])}" if short else ""))
    if not short:
        print("⚠️  No short-set entries. §12: keep a few hundred milliseconds around\n"
              "    each interesting event for per-PR CI; full-day captures run nightly.")
    if missing:
        print(f"\n⚠️  {len(missing)} required condition(s) NOT covered: {', '.join(missing)}\n"
              "    Each one is a market condition the design has never been replayed\n"
              "    against. If a capture cannot be found, synthesize it with synth.py\n"
              "    and tag the entry origin=synthetic — but say so, because a\n"
              "    synthetic microburst is not evidence about a real one.")
        return 1
    return 0


def _cmd_license(args: argparse.Namespace) -> int:
    m = Manifest.load(args.manifest)
    print(LICENSE_NOTICE)
    print()
    buckets: Dict[str, List[str]] = {}
    for e in m.entries:
        buckets.setdefault(e.get("redistribution", "unknown"), []).append(e["name"])
    for status in sorted(buckets, key=lambda s: (s != "unknown", s)):
        names = sorted(buckets[status])
        print(f"{status}  ({len(names)})")
        print(f"    {REDISTRIBUTION.get(status, 'NOT A RECOGNISED STATUS')}")
        for n in names:
            print(f"      - {n}")
        print()
    unknown = buckets.get("unknown", [])
    if unknown:
        print(f"⚠️  {len(unknown)} entr{'y' if len(unknown) == 1 else 'ies'} with "
              "redistribution=unknown. Treat as restricted until resolved.")
        return 1
    return 0


def _cmd_export(args: argparse.Namespace) -> int:
    m = Manifest.load(args.manifest)
    if args.shareable_only:
        keep = [e for e in m.entries if e.get("redistribution") in SHAREABLE]
        dropped = len(m.entries) - len(keep)
        if dropped:
            print(f"note: {dropped} restricted entr{'y' if dropped == 1 else 'ies'} "
                  "omitted from the export", file=sys.stderr)
        m.entries = keep
    doc = m.to_dict()
    text = to_yaml(doc) if args.format == "yaml" else _canonical_json(doc)
    if args.format == "yaml":
        text = ("# GENERATED by tools/pcap/corpus.py — do not hand-edit.\n"
                "# The canonical manifest is JSON; this is a rendering.\n") + text
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"wrote {args.out}")
    else:
        sys.stdout.write(text)
    return 0


def _cmd_remove(args: argparse.Namespace) -> int:
    m = Manifest.load(args.manifest)
    try:
        e = m.remove(args.name, force=args.force)
    except KeyError:
        print(f"corpus: no entry named {args.name!r}", file=sys.stderr)
        return 2
    except ValueError as ex:
        print(f"corpus remove: {ex}", file=sys.stderr)
        return 1
    m.save()
    print(f"removed {e['name']!r}; corpus version now {m.short_digest}")
    return 0


def _cmd_hash(args: argparse.Namespace) -> int:
    for p in args.path:
        digest, size = sha256_file(p)
        print(f"{digest}  {size:>14,}  {p}")
    return 0


def _cmd_version(args: argparse.Namespace) -> int:
    m = Manifest.load(args.manifest)
    if args.json:
        print(json.dumps({
            "manifest": args.manifest,
            "manifest_version": m.manifest_version,
            "corpus_version": m.digest,
            "corpus_version_short": m.short_digest,
            "entries": len(m.entries),
            "total_bytes": sum(e.get("size_bytes", 0) for e in m.entries),
            "updated_utc": m.updated_utc,
        }, indent=2))
    else:
        print(m.digest)
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    p = argparse.ArgumentParser(
        prog="corpus.py",
        description="Versioned manifest for the ITCH pcap regression corpus. "
                    "Captures live in an object store; the manifest is the "
                    "versioned artifact and lives in git.",
        epilog="⚠️ Recorded exchange market data is licensed and generally not "
               "freely shareable. Run `corpus.py license` and read "
               "tools/pcap/README.md before moving any capture.",
    )
    p.add_argument("--manifest", default=DEFAULT_MANIFEST,
                   help=f"manifest path (default {DEFAULT_MANIFEST})")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("init", help="create an empty manifest")
    s.add_argument("--base-url", default="", help="object-store prefix for corpus files")
    s.add_argument("--force", action="store_true", help="overwrite an existing manifest")
    s.set_defaults(fn=_cmd_init)

    s = sub.add_parser("add", help="add a local capture as a corpus entry")
    s.add_argument("path", help="local capture file to hash and describe")
    s.add_argument("--name", help="entry name (default: first dot-component of the filename)")
    s.add_argument("--tag", required=True, help=f"market condition; one of: {', '.join(TAGS)}")
    s.add_argument("--description", default="", help="what this capture is and why it is in the corpus")
    s.add_argument("--origin", required=True, choices=sorted(ORIGINS), help="where the bytes came from")
    s.add_argument("--redistribution", required=True, choices=sorted(REDISTRIBUTION),
                   help="⚠️ licensing status — a human decides this, there is no default")
    s.add_argument("--market-date", default="", help="YYYY-MM-DD of the trading session")
    s.add_argument("--session", default="regular", help="regular | early-close | pre | post")
    s.add_argument("--venue", default="nasdaq")
    s.add_argument("--feed", default="totalview-itch-5.0/moldudp64")
    s.add_argument("--symbols", default="", help="comma-separated, or omit for all")
    s.add_argument("--window-et", default="", help='e.g. "09:29:55.000-09:31:00.000"')
    s.add_argument("--url", default="", help="object-store URL for this file")
    s.add_argument("--short-set", action="store_true", help="include in the per-PR CI short set")
    s.add_argument("--caught-bug", default="", help="bug this entry caught — makes the entry permanent")
    s.add_argument("--provenance", default="", help="who captured it, where, at which tap point")
    s.add_argument("--license-note", default="", help="free text on the entitlement it arrived under")
    s.add_argument("--derived-from", default="", help="parent entry name, for origin=derived")
    s.add_argument("--expect", action="append",
                   help="expected anomaly, CODE or CODE=N (repeatable), e.g. --expect SEQ_GAP=1")
    s.add_argument("--synth-generator", default="tools/pcap/synth.py")
    s.add_argument("--synth-version", default="")
    s.add_argument("--synth-seed", type=int, help="RNG seed, for origin=synthetic")
    s.add_argument("--synth-argv", default="", help="exact generator arguments, for reproduction")
    s.add_argument("--scan", action="store_true",
                   help="run itch_parse.py over the file and record counts and anomalies")
    s.add_argument("--ports", default="", help="UDP dest ports for --scan")
    s.add_argument("--raw", action="store_true", help="file is a raw length-prefixed ITCH file")
    s.add_argument("--replace", action="store_true", help="overwrite an entry with the same name")
    s.add_argument("--allow-problems", action="store_true", help="add despite validation problems")
    s.add_argument("--strict", action="store_true", help="treat every problem as fatal")
    s.set_defaults(fn=_cmd_add)

    s = sub.add_parser("list", help="list entries")
    s.add_argument("--tag")
    s.add_argument("--short-set", action="store_true")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=_cmd_list)

    s = sub.add_parser("show", help="print one entry as JSON")
    s.add_argument("name")
    s.set_defaults(fn=_cmd_show)

    s = sub.add_parser("verify", help="check schema, and cached bytes against SHA-256")
    s.add_argument("name", nargs="*", help="entries to check (default: all)")
    s.add_argument("--cache", default="corpus-cache", help="local corpus cache directory")
    s.add_argument("--schema-only", action="store_true", help="do not touch the cache")
    s.add_argument("--require-present", action="store_true", help="a missing file is a failure")
    s.add_argument("--strict", action="store_true", help="schema problems fail the run")
    s.set_defaults(fn=_cmd_verify)

    s = sub.add_parser("fetch", help="download entries into the cache and verify them")
    s.add_argument("name", nargs="*")
    s.add_argument("--cache", default="corpus-cache")
    s.add_argument("--force", action="store_true", help="re-download even if cached and valid")
    s.set_defaults(fn=_cmd_fetch)

    s = sub.add_parser("coverage", help="which required market conditions are covered")
    s.set_defaults(fn=_cmd_coverage)

    s = sub.add_parser("license", help="⚠️ redistribution status of every entry")
    s.set_defaults(fn=_cmd_license)

    s = sub.add_parser("export", help="re-emit the manifest (json or a yaml rendering)")
    s.add_argument("--format", choices=("json", "yaml"), default="json")
    s.add_argument("--out", help="output file (default stdout)")
    s.add_argument("--shareable-only", action="store_true",
                   help="omit entries that are not marked freely shareable")
    s.set_defaults(fn=_cmd_export)

    s = sub.add_parser("remove", help="remove an entry (refused if it caught a bug)")
    s.add_argument("name")
    s.add_argument("--force", action="store_true")
    s.set_defaults(fn=_cmd_remove)

    s = sub.add_parser("hash", help="SHA-256 and size of files, without touching the manifest")
    s.add_argument("path", nargs="+")
    s.set_defaults(fn=_cmd_hash)

    s = sub.add_parser("version", help="print the corpus version (manifest digest)")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=_cmd_version)

    args = p.parse_args(argv)
    try:
        return int(args.fn(args))
    except FileNotFoundError as e:
        print(f"corpus: {e}", file=sys.stderr)
        return 2
    except ValueError as e:
        print(f"corpus: {e}", file=sys.stderr)
        return 2
    except BrokenPipeError:  # pragma: no cover - `| head`
        return 0


if __name__ == "__main__":
    sys.exit(main())
