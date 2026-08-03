"""pnl.py — P&L decomposition for the Nasdaq market-making strategy.

Project : FPGA Algorithmic Trading System (Nasdaq Equities)
Governs : manuals/08-nasdaq/07-fees-rebates-and-economics.md §5, §6, §7, §9
Mirrors : rtl/pkg/trading_pkg.sv  (PRICE_SCALE = 10000, 4 implied decimals)

===============================================================================
THE EQUATION (manual 08.07 §6)
===============================================================================

    Net P&L = Spread capture
            + Rebate income
            - Adverse selection
            - Exchange & regulatory fees
            - Market impact
            - Amortised fixed cost

Per share, with M_t the midpoint at the fill, M_{t+D} the midpoint D later,
P the execution price and s = +1 for a buy / -1 for a sell:

    effective half-spread   e   = s * (M_t     - P)
    realized  half-spread   r_D = s * (M_{t+D} - P)
    adverse selection       a_D = s * (M_t - M_{t+D}) = e - r_D

Latency's economic contribution is almost entirely in `a`. It does nothing at
all for fees, rebates, or fixed cost — which is why this tool reports those
terms separately rather than as one net number.

===============================================================================
⚠️  RULE 1: FEE RATES COME FROM A CONFIG FILE. ALWAYS. NO EXCEPTIONS.
===============================================================================

manual 08.07 §0: "This file states no current fee, rebate, tier threshold, or
cap from memory, and neither should you. Exchange pricing changes by rule
filing, sometimes monthly. A wrong rebate baked into a P&L model produces a
strategy that is confidently, quietly unprofitable."

So, structurally:

  * There is not one rate literal anywhere in this module. Not a default, not
    a fallback, not a "typical" value in a comment.
  * A rate that is `null` in the config and is NEEDED by the data is a REFUSAL,
    naming the venue and the key. It is never treated as zero. Zero is a rate,
    and it is almost always the wrong one.
  * The config must carry `as_of` and a `source` string per venue. A model
    whose inputs cannot be traced to a price list is not a model.
  * Rates are stated in the config with a SIGN: **positive = you pay,
    negative = you receive**. An inverted (taker-maker) venue is then just a
    config file with different signs — no branch, no special case. manual §2:
    "hardcoding 'rebate' anywhere is a bug waiting for BX."

===============================================================================
⚠️  RULE 2: NO BINARY FLOATS IN THE MONEY PATH
===============================================================================

All monetary arithmetic is integer, in SUB units of 1e-8 USD. Prices arrive as
ITCH-scaled integers (4 implied decimals) and are widened exactly. Config rates
are parsed through `decimal.Decimal` and quantised once, at load. Floats appear
only in the final rendering of a per-share figure for human eyes.
"""

from __future__ import annotations

import argparse
import bisect
import csv
import datetime as _dt
import json
import pathlib
import sys
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation
from typing import Iterable, Sequence

__all__ = [
    "PRICE_SCALE",
    "SUB_PER_USD",
    "ConfigError",
    "DataError",
    "FeeConfig",
    "Fill",
    "PnlResult",
    "decompose",
    "main",
]


# =============================================================================
# 1. Scales — mirrored from rtl/pkg/trading_pkg.sv
# =============================================================================
#: trading_pkg::PRICE_SCALE. ITCH prices are integers with 4 implied decimals:
#: $12.3400 is the integer 123400. NEVER a float (CLAUDE.md §5.3).
PRICE_SCALE = 10_000

#: Internal money unit: 1e-8 USD. Fine enough for a rate like $0.00295/share
#: and for a Section 31 rate quoted per $1,000,000 of covered sales.
SUB_PER_USD = 100_000_000
#: One ITCH price unit ($0.0001) expressed in SUB units.
SUB_PER_PRICE_UNIT = SUB_PER_USD // PRICE_SCALE  # 10_000

#: How stale a fee config may be before the tool complains. Nasdaq re-prices by
#: rule filing, and the manual says to diff the price list at the start of every
#: month, so anything past a month is suspect by construction.
CONFIG_STALE_DAYS = 35


class ConfigError(Exception):
    """The fee/economics configuration is missing, incomplete, or untraceable."""


class DataError(Exception):
    """The fill or midpoint data cannot be interpreted."""


# =============================================================================
# 2. Fee configuration
# =============================================================================
def _rate_to_sub(value, where: str, warnings: list[str]) -> int | None:
    """Parse a per-share (or per-unit) rate into integer SUB units.

    Returns None when the config explicitly says `null` — meaning "not
    verified yet". None propagates to a refusal at the point of use, never to
    a zero.
    """
    if value is None:
        return None
    if isinstance(value, float):
        warnings.append(
            f"{where}: rate given as a JSON number. JSON numbers are binary "
            "floats and cannot represent e.g. 0.0030 exactly. Quote it as a "
            'string ("0.0030") so the value in the file is the value used.'
        )
    try:
        d = Decimal(str(value))
    except InvalidOperation as exc:
        raise ConfigError(f"{where}: '{value}' is not a decimal rate") from exc
    scaled = d * SUB_PER_USD
    if scaled != scaled.to_integral_value():
        raise ConfigError(
            f"{where}: rate {value} has more precision than 1e-8 USD; it cannot "
            "be represented exactly. Check the price list — real rates do not "
            "have nine decimal places."
        )
    return int(scaled)


@dataclass
class VenueFees:
    name: str
    model: str
    source: str
    #: All in SUB per share. POSITIVE = you pay. NEGATIVE = you receive.
    add_displayed: int | None
    remove_displayed: int | None
    add_nondisplayed: int | None
    remove_nondisplayed: int | None
    route: int | None
    tiers: list[dict] = field(default_factory=list)

    def per_share(self, added: bool, displayed: bool) -> int:
        key = (
            ("add" if added else "remove")
            + "_"
            + ("displayed" if displayed else "nondisplayed")
        )
        val = getattr(self, key)
        if val is None:
            raise ConfigError(
                f"venue '{self.name}': rate '{key}_per_share' is null in the fee "
                "config, but the fill data contains fills that need it. Fill it "
                "in from the venue's current price list and record the source. "
                "This tool will not assume a rate, and it will not assume zero — "
                "manual 08.07 §0."
            )
        return val


@dataclass
class FeeConfig:
    as_of: _dt.date
    source: str
    venues: dict[str, VenueFees]
    sec31_per_million_usd: int | None
    finra_taf_per_share: int | None
    finra_taf_trade_cap: int | None
    cat_per_share: int | None
    clearing_per_share: int | None
    clearing_per_trade: int | None
    fixed_monthly_usd: dict[str, Decimal]
    consolidated_volume_shares_month: int | None
    warnings: list[str] = field(default_factory=list)

    # -- loading -------------------------------------------------------
    @staticmethod
    def load(path: str | pathlib.Path) -> "FeeConfig":
        p = pathlib.Path(path)
        if not p.is_file():
            raise ConfigError(
                f"fee config not found: {p}\n"
                "  This tool cannot run without one, and there is no built-in "
                "default. Exchange pricing changes by rule filing; a rate "
                "compiled into a tool is a rate nobody will ever update.\n"
                "  Start from tools/analysis/fees.example.json and fill it in "
                "from the venue's current price list."
            )
        try:
            raw = json.loads(p.read_text())
        except json.JSONDecodeError as exc:
            raise ConfigError(f"{p} is not valid JSON: {exc}") from exc

        warns: list[str] = []
        for key in ("as_of", "source", "venues"):
            if key not in raw:
                raise ConfigError(
                    f"{p}: missing required field '{key}'. Every rate in a P&L "
                    "model must be traceable to a dated source."
                )
        try:
            as_of = _dt.date.fromisoformat(str(raw["as_of"]))
        except ValueError as exc:
            raise ConfigError(f"{p}: as_of must be YYYY-MM-DD: {exc}") from exc

        venues: dict[str, VenueFees] = {}
        for vname, v in raw["venues"].items():
            src = v.get("source", "")
            if not src:
                warns.append(
                    f"venue '{vname}' has no 'source'. Record where these rates "
                    "came from — the price list name and the date you read it."
                )
            venues[vname.upper()] = VenueFees(
                name=vname.upper(),
                model=v.get("model", "unstated"),
                source=src,
                add_displayed=_rate_to_sub(
                    v.get("add_displayed_per_share"),
                    f"{vname}.add_displayed_per_share",
                    warns,
                ),
                remove_displayed=_rate_to_sub(
                    v.get("remove_displayed_per_share"),
                    f"{vname}.remove_displayed_per_share",
                    warns,
                ),
                add_nondisplayed=_rate_to_sub(
                    v.get("add_nondisplayed_per_share"),
                    f"{vname}.add_nondisplayed_per_share",
                    warns,
                ),
                remove_nondisplayed=_rate_to_sub(
                    v.get("remove_nondisplayed_per_share"),
                    f"{vname}.remove_nondisplayed_per_share",
                    warns,
                ),
                route=_rate_to_sub(
                    v.get("route_per_share"), f"{vname}.route_per_share", warns
                ),
                tiers=v.get("tiers", []) or [],
            )

        reg = raw.get("regulatory", {})
        clr = raw.get("clearing", {})
        fixed_raw = raw.get("fixed_monthly_usd", {}) or {}
        fixed: dict[str, Decimal] = {}
        for k, val in fixed_raw.items():
            if val is None:
                continue
            fixed[k] = Decimal(str(val))

        cfg = FeeConfig(
            as_of=as_of,
            source=str(raw["source"]),
            venues=venues,
            sec31_per_million_usd=_rate_to_sub(
                reg.get("sec31_per_million_usd_covered_sales"),
                "regulatory.sec31_per_million_usd_covered_sales",
                warns,
            ),
            finra_taf_per_share=_rate_to_sub(
                reg.get("finra_taf_per_share_sold"),
                "regulatory.finra_taf_per_share_sold",
                warns,
            ),
            finra_taf_trade_cap=_rate_to_sub(
                reg.get("finra_taf_per_trade_cap"),
                "regulatory.finra_taf_per_trade_cap",
                warns,
            ),
            cat_per_share=_rate_to_sub(
                reg.get("cat_per_executed_share"),
                "regulatory.cat_per_executed_share",
                warns,
            ),
            clearing_per_share=_rate_to_sub(
                clr.get("per_share"), "clearing.per_share", warns
            ),
            clearing_per_trade=_rate_to_sub(
                clr.get("per_trade"), "clearing.per_trade", warns
            ),
            fixed_monthly_usd=fixed,
            consolidated_volume_shares_month=raw.get(
                "consolidated_volume_shares_month"
            ),
            warnings=warns,
        )

        age = (_dt.date.today() - as_of).days
        if age > CONFIG_STALE_DAYS:
            cfg.warnings.append(
                f"fee config is {age} days old (as_of {as_of}). Nasdaq re-prices "
                "by rule filing, sometimes monthly. manual 08.07 §0: read the "
                "price list in full at the start of every month, and diff it. "
                "A change in the rebate schedule can turn a working strategy "
                "into a losing one overnight with no change to your code."
            )
        if age < 0:
            cfg.warnings.append(f"fee config as_of {as_of} is in the future.")
        return cfg

    def venue(self, name: str) -> VenueFees:
        v = self.venues.get(name.upper())
        if v is None:
            raise ConfigError(
                f"fill data references venue '{name}', which is not in the fee "
                f"config (known: {sorted(self.venues)}). The sign of the fee "
                "flips between maker-taker and inverted venues; a missing venue "
                "cannot be defaulted (manual 08.07 §2)."
            )
        return v

    def require(self, value: int | None, key: str, why: str) -> int:
        if value is None:
            raise ConfigError(
                f"'{key}' is null in the fee config but is required: {why}. "
                "Fill it in from the authoritative source and record that "
                "source. This tool will not substitute zero."
            )
        return value


# =============================================================================
# 3. Fills
# =============================================================================
@dataclass(frozen=True)
class Fill:
    ts_ns: int
    symbol: str
    side: str  # "B" or "S"
    price: int  # ITCH-scaled
    qty: int
    added: bool  # venue liquidity flag: True = we ADDED (maker)
    venue: str
    mid_at_fill: int  # ITCH-scaled, snapshotted in fabric at fill time
    displayed: bool = True
    mid_at_decision: int | None = None  # for the impact term
    trade_id: str = ""

    @property
    def sign(self) -> int:
        return 1 if self.side == "B" else -1


def read_fills_csv(path: str | pathlib.Path) -> tuple[list[Fill], dict[str, int]]:
    p = pathlib.Path(path)
    if not p.is_file():
        raise DataError(f"fills file not found: {p}")

    required = ["ts_ns", "symbol", "side", "price", "qty", "liquidity", "venue",
                "mid_at_fill"]
    fills: list[Fill] = []
    rejected: dict[str, int] = {}

    def reject(reason: str) -> None:
        rejected[reason] = rejected.get(reason, 0) + 1

    with p.open(newline="") as fh:
        reader = csv.DictReader(fh)
        cols = reader.fieldnames or []
        missing = [c for c in required if c not in cols]
        if missing:
            raise DataError(
                f"{p}: missing required column(s) {missing}. Columns present: "
                f"{cols}.\n  'liquidity' must come from the VENUE's execution "
                "message flag (A = added, R = removed). manual 08.07 'Hardware "
                "implications' §1: do not infer it from order type — post-only "
                "slides and partial routing make inference wrong."
            )
        for row in reader:
            try:
                side = (row["side"] or "").strip().upper()[:1]
                if side not in ("B", "S"):
                    reject("side not B or S")
                    continue
                liq = (row["liquidity"] or "").strip().upper()[:1]
                if liq not in ("A", "R"):
                    reject("liquidity flag not A or R (venue flag required)")
                    continue
                qty = int(row["qty"])
                if qty <= 0:
                    reject("non-positive qty")
                    continue
                fills.append(
                    Fill(
                        ts_ns=int(row["ts_ns"]),
                        symbol=row["symbol"].strip(),
                        side=side,
                        price=int(row["price"]),
                        qty=qty,
                        added=(liq == "A"),
                        venue=row["venue"].strip(),
                        mid_at_fill=int(row["mid_at_fill"]),
                        displayed=str(row.get("displayed", "1")).strip() in ("1", "true", "True", "Y", "y", ""),
                        mid_at_decision=(
                            int(row["mid_at_decision"])
                            if (row.get("mid_at_decision") or "").strip()
                            else None
                        ),
                        trade_id=(row.get("trade_id") or "").strip(),
                    )
                )
            except (ValueError, KeyError):
                reject("unparseable row")
    if not fills:
        raise DataError(f"{p}: no usable fills")
    return fills, rejected


# =============================================================================
# 4. Mark-out midpoints
# =============================================================================
class MidSeries:
    """Per-symbol midpoint time series with as-of lookup.

    ⚠ A mark-out horizon that runs past the end of the series is UNDEFINED. It
    is excluded and counted, never treated as "no move". Silently substituting
    the last known mid biases adverse selection toward zero, i.e. it flatters
    exactly the term latency is supposed to be attacking.
    """

    def __init__(self) -> None:
        self._ts: dict[str, list[int]] = {}
        self._mid: dict[str, list[int]] = {}

    @staticmethod
    def load(path: str | pathlib.Path) -> "MidSeries":
        p = pathlib.Path(path)
        if not p.is_file():
            raise DataError(f"mid series not found: {p}")
        s = MidSeries()
        with p.open(newline="") as fh:
            reader = csv.DictReader(fh)
            for c in ("symbol", "ts_ns", "mid"):
                if c not in (reader.fieldnames or []):
                    raise DataError(
                        f"{p}: mid series needs columns symbol, ts_ns, mid "
                        f"(got {reader.fieldnames})"
                    )
            for row in reader:
                try:
                    sym = row["symbol"].strip()
                    s._ts.setdefault(sym, []).append(int(row["ts_ns"]))
                    s._mid.setdefault(sym, []).append(int(row["mid"]))
                except (ValueError, KeyError):
                    continue
        for sym in s._ts:
            pairs = sorted(zip(s._ts[sym], s._mid[sym]))
            s._ts[sym] = [t for t, _ in pairs]
            s._mid[sym] = [m for _, m in pairs]
        return s

    def at(self, symbol: str, ts_ns: int) -> int | None:
        ts = self._ts.get(symbol)
        if not ts:
            return None
        if ts_ns > ts[-1]:
            return None  # past the end of the data: UNDEFINED, not "unchanged"
        i = bisect.bisect_right(ts, ts_ns)
        if i == 0:
            return None
        return self._mid[symbol][i - 1]


def parse_horizons(spec: str) -> list[tuple[str, int]]:
    """'1s,5s,30s' -> [('1s', 1_000_000_000), ...]. Integer ns only."""
    units = {"ns": 1, "us": 1_000, "ms": 1_000_000, "s": 1_000_000_000}
    out: list[tuple[str, int]] = []
    for tok in spec.split(","):
        tok = tok.strip()
        if not tok:
            continue
        for suffix in ("ns", "us", "ms", "s"):
            if tok.endswith(suffix):
                try:
                    n = Decimal(tok[: -len(suffix)])
                except InvalidOperation as exc:
                    raise DataError(f"bad horizon '{tok}'") from exc
                ns = n * units[suffix]
                if ns != ns.to_integral_value():
                    raise DataError(f"horizon '{tok}' is not a whole nanosecond")
                out.append((tok, int(ns)))
                break
        else:
            raise DataError(f"horizon '{tok}' needs a unit: ns, us, ms or s")
    if not out:
        raise DataError("no horizons parsed")
    return out


# =============================================================================
# 5. The decomposition
# =============================================================================
@dataclass
class HorizonResult:
    label: str
    n_fills: int
    shares: int
    adverse_sub: int  # total, SUB
    realized_sub: int
    excluded_fills: int
    excluded_shares: int


@dataclass
class PnlResult:
    shares: int
    n_fills: int
    notional_sub: int
    spread_capture_sub: int  # sum over fills of e * qty
    exchange_fee_sub: int  # +ve = paid; -ve = rebate received
    sec31_sub: int
    taf_sub: int
    cat_sub: int
    clearing_sub: int
    impact_sub: int | None  # None = NOT MEASURED (not zero)
    horizons: list[HorizonResult]
    maker_shares: int
    taker_shares: int
    maker_fills: int
    taker_fills: int
    by_venue: dict[str, dict[str, int]]
    rejected: dict[str, int]
    warnings: list[str]

    @property
    def rebate_income_sub(self) -> int:
        """The credit half of the exchange fee line, shown separately because
        for a passive strategy it is frequently the entire edge (manual §1)."""
        return -min(0, self.exchange_fee_sub)

    def total_fees_sub(self) -> int:
        return (
            self.exchange_fee_sub
            + self.sec31_sub
            + self.taf_sub
            + self.cat_sub
            + self.clearing_sub
        )

    def net_sub(self, horizon: HorizonResult) -> int:
        impact = self.impact_sub or 0
        return (
            self.spread_capture_sub
            - horizon.adverse_sub
            - self.total_fees_sub()
            - impact
        )


def _per_share(total_sub: int, shares: int) -> Decimal:
    if shares == 0:
        return Decimal(0)
    return (Decimal(total_sub) / Decimal(shares) / Decimal(SUB_PER_USD)).quantize(
        Decimal("0.00000001")
    )


def decompose(
    fills: Sequence[Fill],
    cfg: FeeConfig,
    horizons: Sequence[tuple[str, int]],
    mids: MidSeries | None,
    markout_columns: dict[str, dict[str, int]] | None = None,
    rejected: dict[str, int] | None = None,
) -> PnlResult:
    """Compute the §6 decomposition. All money in integer SUB (1e-8 USD)."""
    warnings: list[str] = list(cfg.warnings)

    shares = 0
    notional_sub = 0
    spread_sub = 0
    exch_sub = 0
    sec31_sub = 0
    taf_sub = 0
    cat_sub = 0
    clearing_sub = 0
    impact_sub = 0
    impact_measured = 0
    maker_shares = taker_shares = 0
    maker_fills = taker_fills = 0
    by_venue: dict[str, dict[str, int]] = {}

    h_acc = {
        label: {"adv": 0, "real": 0, "n": 0, "sh": 0, "ex_n": 0, "ex_sh": 0}
        for label, _ in horizons
    }

    for f in fills:
        v = cfg.venue(f.venue)
        shares += f.qty
        # notional in SUB: price(1e-4 USD) * qty * SUB_PER_PRICE_UNIT
        notional = f.price * f.qty * SUB_PER_PRICE_UNIT
        notional_sub += notional

        # -- spread capture -------------------------------------------------
        e_per_share_price_units = f.sign * (f.mid_at_fill - f.price)
        spread_sub += e_per_share_price_units * f.qty * SUB_PER_PRICE_UNIT

        # -- exchange fee / rebate (SIGNED, from config; inverted venues just
        #    have the opposite signs — no branch here on venue identity) -----
        rate = v.per_share(added=f.added, displayed=f.displayed)
        exch_sub += rate * f.qty

        vslot = by_venue.setdefault(
            v.name,
            {"shares": 0, "fills": 0, "added": 0, "removed": 0, "exchange_sub": 0},
        )
        vslot["shares"] += f.qty
        vslot["fills"] += 1
        vslot["added" if f.added else "removed"] += f.qty
        vslot["exchange_sub"] += rate * f.qty

        if f.added:
            maker_shares += f.qty
            maker_fills += 1
        else:
            taker_shares += f.qty
            taker_fills += 1

        # -- regulatory: SELLS ONLY (manual §5) ------------------------------
        if f.side == "S":
            r31 = cfg.require(
                cfg.sec31_per_million_usd,
                "regulatory.sec31_per_million_usd_covered_sales",
                "the fill data contains sales, and Section 31 applies to covered "
                "sales",
            )
            # rate is per $1,000,000 of covered sales
            sec31_sub += (notional * r31) // (1_000_000 * SUB_PER_USD)

            taf_rate = cfg.require(
                cfg.finra_taf_per_share,
                "regulatory.finra_taf_per_share_sold",
                "the fill data contains sales, and the FINRA TAF applies to "
                "covered sales",
            )
            this_taf = taf_rate * f.qty
            if cfg.finra_taf_trade_cap is not None:
                this_taf = min(this_taf, cfg.finra_taf_trade_cap)
            else:
                warnings.append(
                    "regulatory.finra_taf_per_trade_cap is null: the TAF has a "
                    "per-trade cap and it has not been applied. The TAF line "
                    "below is an UPPER bound. Verify the cap in FINRA By-Laws "
                    "Schedule A."
                )
            taf_sub += this_taf

        if cfg.cat_per_share is not None:
            cat_sub += cfg.cat_per_share * f.qty
        if cfg.clearing_per_share is not None:
            clearing_sub += cfg.clearing_per_share * f.qty
        if cfg.clearing_per_trade is not None:
            clearing_sub += cfg.clearing_per_trade

        # -- impact ----------------------------------------------------------
        if f.mid_at_decision is not None:
            impact_sub += f.sign * (f.mid_at_fill - f.mid_at_decision) * f.qty * SUB_PER_PRICE_UNIT
            impact_measured += 1

        # -- mark-outs -------------------------------------------------------
        for label, dt_ns in horizons:
            mid_after: int | None = None
            if markout_columns is not None:
                mid_after = markout_columns.get(f.trade_id or str(f.ts_ns), {}).get(label)
            if mid_after is None and mids is not None:
                mid_after = mids.at(f.symbol, f.ts_ns + dt_ns)
            acc = h_acc[label]
            if mid_after is None:
                acc["ex_n"] += 1
                acc["ex_sh"] += f.qty
                continue
            a_units = f.sign * (f.mid_at_fill - mid_after)
            r_units = f.sign * (mid_after - f.price)
            acc["adv"] += a_units * f.qty * SUB_PER_PRICE_UNIT
            acc["real"] += r_units * f.qty * SUB_PER_PRICE_UNIT
            acc["n"] += 1
            acc["sh"] += f.qty

    if cfg.cat_per_share is None:
        warnings.append(
            "regulatory.cat_per_executed_share is null: CAT funding is NOT in "
            "the numbers below. It is an executed-share-based cost billed "
            "through the SROs; leaving it out overstates net margin."
        )
    if cfg.clearing_per_share is None and cfg.clearing_per_trade is None:
        warnings.append(
            "clearing rates are null: clearing and settlement are NOT in the "
            "numbers below. For a high-volume operation this is not a rounding "
            "error (manual 08.07 §5)."
        )
    if impact_measured == 0:
        warnings.append(
            "MARKET IMPACT NOT MEASURED: no fill carried 'mid_at_decision', so "
            "the impact term is absent from the decomposition — it is reported "
            "as NOT MEASURED, not as zero. Reporting it as zero would flatter "
            "the P&L (manual 08.07 §6)."
        )
    elif impact_measured < len(fills):
        warnings.append(
            f"impact measured on {impact_measured:,} of {len(fills):,} fills; "
            "the term below covers only those."
        )

    horizon_results = [
        HorizonResult(
            label=label,
            n_fills=h_acc[label]["n"],
            shares=h_acc[label]["sh"],
            adverse_sub=h_acc[label]["adv"],
            realized_sub=h_acc[label]["real"],
            excluded_fills=h_acc[label]["ex_n"],
            excluded_shares=h_acc[label]["ex_sh"],
        )
        for label, _ in horizons
    ]
    for h in horizon_results:
        if h.excluded_fills:
            frac = h.excluded_fills / max(1, len(fills))
            warnings.append(
                f"mark-out {h.label}: {h.excluded_fills:,} fill(s) "
                f"({frac * 100:.2f}%) had no midpoint at t+{h.label} and were "
                "EXCLUDED from that horizon (the series ends before the horizon, "
                "or the symbol is absent). They are not counted as zero move."
            )

    return PnlResult(
        shares=shares,
        n_fills=len(fills),
        notional_sub=notional_sub,
        spread_capture_sub=spread_sub,
        exchange_fee_sub=exch_sub,
        sec31_sub=sec31_sub,
        taf_sub=taf_sub,
        cat_sub=cat_sub,
        clearing_sub=clearing_sub,
        impact_sub=impact_sub if impact_measured else None,
        horizons=horizon_results,
        maker_shares=maker_shares,
        taker_shares=taker_shares,
        maker_fills=maker_fills,
        taker_fills=taker_fills,
        by_venue=by_venue,
        rejected=rejected or {},
        warnings=warnings,
    )


# =============================================================================
# 6. Rendering
# =============================================================================
def render(res: PnlResult, cfg: FeeConfig) -> str:
    sh = res.shares
    L: list[str] = []
    L.append("=" * 78)
    L.append("  P&L DECOMPOSITION  (manual 08.07 §6)")
    L.append("=" * 78)
    L.append(f"  fee config   : {cfg.source}")
    L.append(f"  rates as of  : {cfg.as_of.isoformat()}")
    L.append(f"  fills        : {res.n_fills:,}   shares: {sh:,}")
    L.append(
        f"  notional     : ${Decimal(res.notional_sub) / SUB_PER_USD:,.2f}"
    )
    L.append("")
    L.append("  PER SHARE (USD). Positive = income, negative = cost.")
    L.append("  " + "-" * 74)
    L.append(
        f"    spread capture (effective half-spread e)   "
        f"{_per_share(res.spread_capture_sub, sh):>+14}"
    )
    L.append(
        f"    exchange fee / rebate (signed)             "
        f"{_per_share(-res.exchange_fee_sub, sh):>+14}"
    )
    if res.rebate_income_sub:
        L.append(
            f"      of which rebate income                   "
            f"{_per_share(res.rebate_income_sub, sh):>+14}"
        )
    L.append(
        f"    SEC Section 31 (covered sales only)        "
        f"{_per_share(-res.sec31_sub, sh):>+14}"
    )
    L.append(
        f"    FINRA TAF (covered sales only)             "
        f"{_per_share(-res.taf_sub, sh):>+14}"
    )
    L.append(
        f"    CAT                                        "
        f"{_per_share(-res.cat_sub, sh):>+14}"
    )
    L.append(
        f"    clearing / settlement                      "
        f"{_per_share(-res.clearing_sub, sh):>+14}"
    )
    if res.impact_sub is None:
        L.append("    market impact                                NOT MEASURED")
    else:
        L.append(
            f"    market impact                              "
            f"{_per_share(-res.impact_sub, sh):>+14}"
        )
    L.append("")
    L.append("  ADVERSE SELECTION AND NET, BY MARK-OUT HORIZON")
    L.append("  (the term latency actually attacks — manual 08.07 §6)")
    L.append("  " + "-" * 74)
    L.append(
        "    horizon    fills      adverse sel/sh   realized r/sh      net/sh"
    )
    for h in res.horizons:
        if h.shares == 0:
            L.append(f"    {h.label:<9}  {h.n_fills:>8,}   (no usable mark-outs)")
            continue
        net = res.net_sub(h)
        L.append(
            f"    {h.label:<9}  {h.n_fills:>8,}   "
            f"{_per_share(h.adverse_sub, h.shares):>+14}  "
            f"{_per_share(h.realized_sub, h.shares):>+14}  "
            f"{_per_share(net, sh):>+12}"
        )
    L.append("")
    L.append("  MIX AND ATTRIBUTION (manual 08.07 §9)")
    L.append("  " + "-" * 74)
    tot_f = max(1, res.maker_fills + res.taker_fills)
    L.append(
        f"    maker fills {res.maker_fills:,} / taker fills {res.taker_fills:,}   "
        f"rebate capture rate {res.maker_fills / tot_f * 100:.2f}%"
    )
    L.append(
        f"    shares added {res.maker_shares:,} / removed {res.taker_shares:,}"
    )
    for vname, v in sorted(res.by_venue.items()):
        vc = cfg.venues[vname]
        L.append(
            f"    {vname:<8} model={vc.model:<14} shares={v['shares']:,} "
            f"(add {v['added']:,} / remove {v['removed']:,})  "
            f"exchange/sh {_per_share(-v['exchange_sub'], max(1, v['shares']))}"
        )
    if len(res.by_venue) > 1:
        L.append(
            "    ! multi-venue: measure realized spread on inverted-venue fills "
            "SEPARATELY.\n      Queue position on an inverted venue is a "
            "concentrated adverse-selection bet\n      (manual 08.07 §2)."
        )

    # -- break-even (manual §7) ------------------------------------------
    if cfg.fixed_monthly_usd and res.horizons:
        h = res.horizons[-1]
        if h.shares:
            net_ps = Decimal(res.net_sub(h)) / Decimal(sh) / Decimal(SUB_PER_USD)
            fixed_total = sum(cfg.fixed_monthly_usd.values())
            L.append("")
            L.append("  BREAK-EVEN (manual 08.07 §7)")
            L.append("  " + "-" * 74)
            L.append(f"    fixed cost / month : ${fixed_total:,.2f}")
            for k, v in sorted(cfg.fixed_monthly_usd.items()):
                L.append(f"      {k:<22} ${v:,.2f}")
            L.append(
                f"    net margin / share : {net_ps:+.8f}  (at the {h.label} mark-out)"
            )
            if net_ps > 0:
                need = (fixed_total / net_ps).quantize(Decimal("1"))
                L.append(f"    shares/month to break even : {need:,}")
                L.append(
                    "    ! sensitivity to the margin estimate is HYPERBOLIC, not "
                    "linear: a margin\n      a tenth the size needs ten times the "
                    "volume. Run pessimistic / base /\n      optimistic, and model "
                    "the tier feedback."
                )
            else:
                L.append(
                    "    net margin is <= 0: there is no break-even volume. More "
                    "volume loses more\n      money. This is the normal state of "
                    "an under-scaled equities market-making\n      operation "
                    "(manual 08.07 §6) — the gross edge is real and the cost "
                    "stack eats it."
                )

    # -- tier tracker (manual §3) ----------------------------------------
    tier_lines = _render_tiers(res, cfg)
    if tier_lines:
        L.append("")
        L.extend(tier_lines)

    if res.rejected:
        L.append("")
        L.append("  REJECTED INPUT ROWS (counted, never silently dropped):")
        for reason, n in sorted(res.rejected.items()):
            if n:
                L.append(f"    {n:>10,}  {reason}")

    if res.warnings:
        L.append("")
        L.append("  CAVEATS — these belong with any quote of the numbers above:")
        for w in res.warnings:
            for i, chunk in enumerate(_wrap(w, 68)):
                L.append(("    ! " if i == 0 else "      ") + chunk)
    L.append("")
    L.append(
        "  A backtest that models only spread capture and ignores fees, rebates,\n"
        "  tier effects and queue position will always look profitable\n"
        "  (manual 08.07 §6)."
    )
    return "\n".join(L)


def _render_tiers(res: PnlResult, cfg: FeeConfig) -> list[str]:
    out: list[str] = []
    any_tiers = any(v.tiers for v in cfg.venues.values())
    if not any_tiers:
        return [
            "  TIER TRACKER: no tiers configured. manual 08.07 §3 says to build",
            "  this on day one — month-to-date qualifying volume, current tier,",
            "  distance to the next, and the modelled value of closing it. The",
            "  marginal value of the share that crosses a boundary is not a",
            "  per-share number at all; it is a cliff of (r_high - r_low) * V_month.",
        ]
    out.append("  TIER TRACKER (manual 08.07 §3)")
    out.append("  " + "-" * 74)
    for vname, v in sorted(res.by_venue.items()):
        vc = cfg.venues[vname]
        if not vc.tiers:
            continue
        added = v["added"]
        out.append(f"    {vname}: month-to-date shares added = {added:,}")
        prev_rate: int | None = None
        for t in sorted(vc.tiers, key=lambda x: x.get("threshold_shares_month") or 0):
            thr = t.get("threshold_shares_month")
            if thr is None:
                out.append(
                    f"      tier '{t.get('name', '?')}' has no "
                    "threshold_shares_month; percentage-of-consolidated-volume "
                    "tiers need consolidated_volume_shares_month in the config."
                )
                continue
            rate = _rate_to_sub(t.get("add_displayed_per_share"), "tier", [])
            mark = "REACHED" if added >= thr else f"{thr - added:,} shares away"
            out.append(f"      {t.get('name', '?'):<12} >= {thr:>14,}   {mark}")
            if rate is not None and prev_rate is not None and added < thr:
                cliff = (prev_rate - rate) * added
                out.append(
                    f"        cliff value of crossing now: "
                    f"${Decimal(cliff) / SUB_PER_USD:,.2f} "
                    "(re-prices the WHOLE month's volume)"
                )
            if rate is not None:
                prev_rate = rate
    out.append(
        "    ! crossing a tier on the 28th re-prices everything since the 1st.\n"
        "      Trading unprofitably to reach a tier can be correct, but it must be\n"
        "      an explicit modelled decision by a human, not an emergent property\n"
        "      of the algorithm."
    )
    return out


def _wrap(text: str, width: int) -> list[str]:
    words, out, line = text.split(), [], ""
    for w in words:
        if line and len(line) + 1 + len(w) > width:
            out.append(line)
            line = w
        else:
            line = f"{line} {w}".strip()
    if line:
        out.append(line)
    return out or [""]


# =============================================================================
# 7. CLI
# =============================================================================
def _build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="pnl.py",
        description=(
            "Decompose realized P&L into spread capture + rebate - adverse "
            "selection - fees - impact, with mark-out adverse selection at "
            "several horizons. Fee rates are loaded from a config file and are "
            "never defaulted."
        ),
    )
    ap.add_argument("--fills", required=True, help="fill records CSV")
    ap.add_argument(
        "--fees",
        required=True,
        help="fee/economics config JSON. REQUIRED — there is no built-in rate "
        "table and no default. See tools/analysis/fees.example.json.",
    )
    ap.add_argument(
        "--mids",
        help="midpoint time series CSV (symbol, ts_ns, mid) for mark-outs",
    )
    ap.add_argument(
        "--horizons",
        default="1s,5s,30s",
        help="mark-out horizons, comma separated (default: 1s,5s,30s)",
    )
    ap.add_argument("--json", action="store_true")
    return ap


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        cfg = FeeConfig.load(args.fees)
        fills, rejected = read_fills_csv(args.fills)
        horizons = parse_horizons(args.horizons)
        mids = MidSeries.load(args.mids) if args.mids else None
        if mids is None:
            print(
                "NOTE: no --mids given; mark-outs can only come from the fill "
                "file's own columns.\n      Without mark-outs the adverse "
                "selection term cannot be computed, and\n      adverse selection "
                "is the term latency actually buys.",
                file=sys.stderr,
            )
        res = decompose(fills, cfg, horizons, mids, rejected=rejected)
    except (ConfigError, DataError) as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 2

    if args.json:
        payload = {
            "shares": res.shares,
            "fills": res.n_fills,
            "per_share_usd": {
                "spread_capture": str(_per_share(res.spread_capture_sub, res.shares)),
                "exchange_net": str(_per_share(-res.exchange_fee_sub, res.shares)),
                "sec31": str(_per_share(-res.sec31_sub, res.shares)),
                "taf": str(_per_share(-res.taf_sub, res.shares)),
                "cat": str(_per_share(-res.cat_sub, res.shares)),
                "clearing": str(_per_share(-res.clearing_sub, res.shares)),
                "impact": (
                    None
                    if res.impact_sub is None
                    else str(_per_share(-res.impact_sub, res.shares))
                ),
            },
            "horizons": [
                {
                    "label": h.label,
                    "fills": h.n_fills,
                    "excluded_fills": h.excluded_fills,
                    "adverse_selection_per_share": str(
                        _per_share(h.adverse_sub, h.shares)
                    ),
                    "net_per_share": str(_per_share(res.net_sub(h), res.shares)),
                }
                for h in res.horizons
            ],
            "fee_config_as_of": cfg.as_of.isoformat(),
            "fee_config_source": cfg.source,
            "warnings": res.warnings,
        }
        print(json.dumps(payload, indent=2))
    else:
        print(render(res, cfg))
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
