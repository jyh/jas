"""Tests for the unit-aware length parser / formatter.

Lives in workspace_interpreter so jas_flask, jas (Python), and any
future Python consumer share a single canonical implementation.
Mirrors the JS parser in jas_flask/static/js/app.js and the Rust
parser in jas_dioxus/src/interpreter/length.rs — keep all three in
lockstep when extending the supported unit set.

See UNIT_INPUTS.md for the spec these tests pin.
"""

from __future__ import annotations

import math

import pytest

from workspace_interpreter.length import (
    SUPPORTED_UNITS, format_length, parse_length, pt_per_unit,
)


# ── Conversion table ─────────────────────────────────────────────


def test_pt_per_unit_table():
    """The conversion factors are the spec's load-bearing constants."""
    assert pt_per_unit("pt") == 1.0
    assert pt_per_unit("px") == 0.75
    assert pt_per_unit("in") == 72.0
    assert math.isclose(pt_per_unit("mm"), 72.0 / 25.4)
    assert math.isclose(pt_per_unit("cm"), 720.0 / 25.4)
    assert pt_per_unit("pc") == 12.0


def test_supported_units_complete():
    """Spec §Conversion table — six units in v1."""
    assert SUPPORTED_UNITS == ("pt", "px", "in", "mm", "cm", "pc")


def test_pt_per_unit_unknown_returns_none():
    assert pt_per_unit("dpi") is None
    assert pt_per_unit("") is None


# ── parse_length: bare number, default unit ──────────────────────


def test_parse_bare_number_uses_default_unit():
    assert parse_length("12", "pt") == 12.0
    assert parse_length("12", "px") == 12.0 * 0.75
    assert parse_length("12", "in") == 12.0 * 72.0


def test_parse_bare_decimal():
    assert parse_length("12.5", "pt") == 12.5
    assert parse_length("0.5", "pt") == 0.5


def test_parse_leading_dot_decimal():
    assert parse_length(".5", "pt") == 0.5


def test_parse_trailing_dot_decimal():
    assert parse_length("5.", "pt") == 5.0


def test_parse_negative():
    assert parse_length("-3", "pt") == -3.0
    assert parse_length("-3.5", "pt") == -3.5
    assert parse_length("-.5", "pt") == -0.5


def test_parse_zero():
    assert parse_length("0", "pt") == 0.0
    assert parse_length("0.0", "pt") == 0.0
    assert parse_length("-0", "pt") == 0.0


# ── parse_length: with unit suffix ───────────────────────────────


def test_parse_with_pt_suffix():
    assert parse_length("12 pt", "pt") == 12.0
    assert parse_length("12pt", "pt") == 12.0
    assert parse_length("12  pt", "pt") == 12.0


def test_parse_with_px_suffix():
    # 12 px = 9 pt
    assert parse_length("12 px", "pt") == 9.0
    assert parse_length("12px", "pt") == 9.0


def test_parse_with_in_suffix():
    assert parse_length("1 in", "pt") == 72.0
    assert parse_length("0.5 in", "pt") == 36.0


def test_parse_with_mm_suffix():
    # 25.4 mm = 1 in = 72 pt
    assert math.isclose(parse_length("25.4 mm", "pt"), 72.0)
    assert math.isclose(parse_length("5 mm", "pt"), 5.0 * 72.0 / 25.4)


def test_parse_with_cm_suffix():
    # 2.54 cm = 1 in = 72 pt
    assert math.isclose(parse_length("2.54 cm", "pt"), 72.0)


def test_parse_with_pc_suffix():
    assert parse_length("1 pc", "pt") == 12.0
    assert parse_length("3 pc", "pt") == 36.0


def test_parse_case_insensitive_unit():
    assert parse_length("12 PT", "pt") == 12.0
    assert parse_length("12 Pt", "pt") == 12.0
    assert parse_length("12pT", "pt") == 12.0
    assert parse_length("5 MM", "pt") == parse_length("5 mm", "pt")


def test_parse_unit_overrides_default():
    """Unit suffix wins over widget default — that's the whole point."""
    assert parse_length("12 px", "pt") == 9.0
    assert parse_length("12 pt", "px") == 12.0  # 12 pt regardless of widget default


# ── parse_length: whitespace ─────────────────────────────────────


def test_parse_strips_leading_whitespace():
    assert parse_length("  12", "pt") == 12.0
    assert parse_length("\t12 pt", "pt") == 12.0


def test_parse_strips_trailing_whitespace():
    assert parse_length("12  ", "pt") == 12.0
    assert parse_length("12 pt  ", "pt") == 12.0


# ── parse_length: rejection paths ────────────────────────────────


def test_parse_empty_returns_none():
    assert parse_length("", "pt") is None
    assert parse_length("   ", "pt") is None


def test_parse_unit_only_returns_none():
    assert parse_length("pt", "pt") is None
    assert parse_length(" mm ", "pt") is None


def test_parse_unknown_unit_returns_none():
    assert parse_length("12 dpi", "pt") is None
    assert parse_length("12 ft", "pt") is None
    assert parse_length("12 foo", "pt") is None


def test_parse_extra_tokens_returns_none():
    assert parse_length("12 mm pt", "pt") is None
    assert parse_length("5 mm 3", "pt") is None
    assert parse_length("12pt5", "pt") is None


def test_parse_garbage_returns_none():
    assert parse_length("abc", "pt") is None
    assert parse_length("12.5.5", "pt") is None
    assert parse_length(".", "pt") is None
    assert parse_length("-", "pt") is None


# ── format_length ────────────────────────────────────────────────


def test_format_integer_strips_decimal():
    assert format_length(12.0, "pt", 2) == "12 pt"
    assert format_length(0.0, "pt", 2) == "0 pt"
    assert format_length(72.0, "in", 2) == "1 in"


def test_format_decimal():
    assert format_length(12.5, "pt", 2) == "12.5 pt"
    assert format_length(12.34, "pt", 2) == "12.34 pt"


def test_format_trims_trailing_zeros():
    assert format_length(12.50, "pt", 2) == "12.5 pt"
    assert format_length(12.500, "pt", 3) == "12.5 pt"
    assert format_length(12.0, "pt", 4) == "12 pt"


def test_format_rounds_to_precision():
    assert format_length(12.345, "pt", 2) == "12.35 pt"
    assert format_length(12.344, "pt", 2) == "12.34 pt"


def test_format_converts_to_target_unit():
    # 72 pt = 1 in
    assert format_length(72.0, "in", 2) == "1 in"
    # 1 pt = 1.333... px ≈ 1.33 px
    assert format_length(1.0, "px", 2) == "1.33 px"


def test_format_mm():
    # 72 pt = 25.4 mm
    out = format_length(72.0, "mm", 2)
    assert out == "25.4 mm"


def test_format_negative():
    assert format_length(-3.0, "pt", 2) == "-3 pt"
    assert format_length(-3.5, "pt", 2) == "-3.5 pt"


def test_format_null_returns_empty():
    assert format_length(None, "pt", 2) == ""


def test_format_default_precision_is_two():
    assert format_length(12.345, "pt") == "12.35 pt"


# ── round-trip ───────────────────────────────────────────────────


@pytest.mark.parametrize("pt", [0.0, 1.0, 12.0, 12.5, 72.0, 100.0, 0.75])
@pytest.mark.parametrize("unit", list(SUPPORTED_UNITS))
def test_round_trip_format_then_parse(pt, unit):
    """format(pt, unit) → parse(_, unit) round-trips at high precision.

    Very small pt values displayed in large units (0.75 pt → ~0.026 cm)
    lose info at the default 2-decimal display precision; pin
    precision=6 so the round-trip's tolerance is dominated by the
    pt→unit→pt arithmetic and not the display rounding.
    """
    formatted = format_length(pt, unit, 6)
    back = parse_length(formatted, unit)
    assert back is not None
    assert math.isclose(back, pt, rel_tol=1e-3, abs_tol=1e-3)


def test_format_unknown_unit_falls_back_to_pt():
    # Defensive: if the YAML supplies an unsupported unit string, format
    # in pt rather than producing a malformed output.
    assert format_length(12.0, "dpi", 2) == "12 pt"
