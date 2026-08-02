"""The mirror must not be allowed to drift from the RTL packages.

These tests are the Python equivalent of the ``static_assert``s in the C++ half
of ``host/``.  If ``rtl/pkg/itch_pkg.sv`` or ``rtl/pkg/trading_pkg.sv`` changes
and the model does not, THESE are the tests that fail — before anyone spends a
day debugging an RTL "bug" that is really a stale oracle.
"""

from __future__ import annotations

from host.pymodel import itch_decode
from host.pymodel import itch_pkg_mirror as itch
from host.pymodel import trading_pkg_mirror as tp
from host.pymodel._svparse import load_package


def test_rtl_crosscheck_actually_ran() -> None:
    """⚠️ THE MOST IMPORTANT TEST IN THIS FILE.

    The mirrors skip their cross-check when ``rtl/`` is absent, which is
    legitimate for a host-only deployment but must NEVER be the case in CI.
    A green suite with the check skipped proves nothing at all.
    """
    assert itch.ITCH_PKG_SV.is_file(), f"{itch.ITCH_PKG_SV} not found"
    assert tp.TRADING_PKG_SV.is_file(), f"{tp.TRADING_PKG_SV} not found"
    assert itch.RTL_CROSSCHECK_DONE, "itch_pkg.sv cross-check did not run"
    assert tp.RTL_CROSSCHECK_DONE, "trading_pkg.sv cross-check did not run"


def test_itch_pkg_mirror_matches_rtl() -> None:
    assert itch.crosscheck_against_rtl() == []


def test_trading_pkg_mirror_matches_rtl() -> None:
    assert tp.crosscheck_against_rtl() == []


def test_every_itch_message_length_agrees_with_its_field_layout() -> None:
    """sum(field widths) == the length declared in itch_pkg.sv, for all 22 types.

    Two independently-sourced numbers (a per-message length from the spec, and
    a list of field widths from the spec) can only agree if both are right.
    This is the strongest check available without the spec PDF.
    """
    for type_code, declared in sorted(itch.MSG_LEN.items()):
        derived = itch_decode.layout_length(type_code)
        assert derived == declared, (
            f"ITCH '{type_code}' ({itch.MSG_NAME[type_code]}): field table sums "
            f"to {derived} bytes but itch_pkg.sv declares {declared}"
        )


def test_declared_offsets_match_derived_offsets() -> None:
    """The five layouts itch_pkg.sv gives offsets for must agree field by field."""
    checks = (
        ("A", "order_reference_number", itch.OFF_A_ORDER_REF),
        ("A", "buy_sell_indicator", itch.OFF_A_SIDE),
        ("A", "shares", itch.OFF_A_SHARES),
        ("A", "stock", itch.OFF_A_STOCK),
        ("A", "price", itch.OFF_A_PRICE),
        ("E", "order_reference_number", itch.OFF_E_ORDER_REF),
        ("E", "executed_shares", itch.OFF_E_SHARES),
        ("E", "match_number", itch.OFF_E_MATCH),
        ("X", "order_reference_number", itch.OFF_X_ORDER_REF),
        ("X", "cancelled_shares", itch.OFF_X_SHARES),
        ("D", "order_reference_number", itch.OFF_D_ORDER_REF),
        ("U", "original_order_reference_number", itch.OFF_U_ORIG_REF),
        ("U", "new_order_reference_number", itch.OFF_U_NEW_REF),
        ("U", "shares", itch.OFF_U_SHARES),
        ("U", "price", itch.OFF_U_PRICE),
    )
    for type_code, field_name, declared in checks:
        assert itch_decode.field_offset(type_code, field_name) == declared, (
            f"'{type_code}'.{field_name}"
        )


def test_common_prefix_is_invariant_across_all_types() -> None:
    for type_code in itch.MSG_LEN:
        for field_name, expected in (
            ("msg_type", itch.OFF_MSG_TYPE),
            ("stock_locate", itch.OFF_LOCATE),
            ("tracking_number", itch.OFF_TRACKING),
            ("timestamp", itch.OFF_TIMESTAMP),
        ):
            assert itch_decode.field_offset(type_code, field_name) == expected


def test_struct_widths_match_shared_contract() -> None:
    """SHARED_CONTRACT.md's packed-record numbers, pinned against the RTL."""
    pkg = load_package(tp.TRADING_PKG_SV)
    assert pkg.struct("sym_strat_t").width == 149
    assert pkg.struct("sym_risk_t").width == 324
    assert pkg.struct("order_token_t").width == 112 == tp.TOKEN_W
    assert tp.SYM_STRAT_WORDS == 5
    assert (324 + 31) // 32 == 11, "SYM_RISK_WORDS in SHARED_CONTRACT.md"


def test_sym_strat_pack_round_trip() -> None:
    original = tp.SymStrat(
        strat_enabled=True,
        strat_select=5,
        quote_qty=1_000,
        edge_ticks=3,
        min_book_qty=250,
        fair_value=1_908_500,
        imbalance_thr=512,
    )
    words = tp.pack_sym_strat(original)
    assert len(words) == tp.SYM_STRAT_WORDS
    assert all(0 <= w <= 0xFFFF_FFFF for w in words)
    assert tp.unpack_sym_strat(words) == original


def test_sym_strat_pack_rejects_overwide_field() -> None:
    """A parameter that does not fit must raise, not silently truncate.

    A truncated ``quote_qty`` is an order size nobody chose.
    """
    import pytest

    with pytest.raises(ValueError):
        tp.pack_sym_strat(tp.SymStrat(strat_select=16))  # 4-bit field


def test_order_token_round_trip_and_width() -> None:
    token = tp.OrderToken(magic=0xC0DE, strat_id=2, sym=17, counter=1234, rsvd=0)
    packed = tp.pack_order_token(token)
    assert packed.bit_length() <= tp.TOKEN_W
    assert tp.unpack_order_token(packed) == token
    assert len(tp.order_token_bytes_be(token)) == tp.TOKEN_W // 8 == 14


def test_price_formatting_never_uses_a_float() -> None:
    """``format_price`` is integer-only; check the exact decimal rendering."""
    assert tp.format_price(123400) == "12.3400"
    assert tp.format_price(1) == "0.0001"
    assert tp.format_price(0) == "0.0000"
    assert tp.format_price(4294967295) == "429496.7295"  # full ITCH price range


def test_div100_and_whole_penny_match_the_rtl_reciprocal() -> None:
    """``div100`` is a reciprocal multiply; it must be EXACT over the range."""
    for px in (0, 1, 99, 100, 101, 1_908_500, 1_908_501, 4_294_967_200):
        assert tp.div100(px) == px // 100, px
    assert tp.is_whole_penny(1_908_500)
    assert not tp.is_whole_penny(1_908_501)
