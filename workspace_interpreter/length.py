"""Unit-aware length parser / formatter.

The single source of truth for the length-conversion table used by the
`length_input` widget. Flask, Python (jas), and any other Python
consumer share this; the JS port in jas_flask/static/js/app.js and the
Rust port in jas_dioxus/src/interpreter/length.rs follow the same
contract.

See UNIT_INPUTS.md for the spec these helpers implement.
"""

from __future__ import annotations

import re
from typing import Optional


SUPPORTED_UNITS = ("pt", "px", "in", "mm", "cm", "pc")
"""Units accepted by `parse_length` / produced by `format_length`."""


# Conversion: how many points are in one of the named unit. The
# canonical storage unit is pt — everywhere a length is committed to
# state or written to SVG, it's a pt number. Flask / Rust / Swift /
# OCaml / Python all keep their copies in sync with this table.
_PT_PER_UNIT = {
    "pt": 1.0,
    # CSS reference dpi convention: 1 px = 1/96 in, 1 pt = 1/72 in
    # ⇒ 1 px = 72/96 pt = 0.75 pt.
    "px": 0.75,
    "in": 72.0,
    # 1 in = 25.4 mm.
    "mm": 72.0 / 25.4,
    "cm": 720.0 / 25.4,
    # 1 pica = 12 pt.
    "pc": 12.0,
}


# Grammar (case-insensitive on the unit; case doesn't apply to the
# number): optional sign, then either `digits[.digits?]` or `.digits`,
# then optional whitespace, then optional unit, then trailing space.
# The regex is anchored so anything left over after the unit is a
# parse failure (rejecting "12pt5" / "12 mm 5" / etc.).
_LENGTH_RE = re.compile(
    r"""
    ^
    \s*
    (?P<num>-? (?: \d+ \.? \d* | \. \d+ ))    # number
    \s*
    (?P<unit>[A-Za-z]+)?                       # optional unit
    \s*
    $
    """,
    re.VERBOSE,
)


def pt_per_unit(unit: str) -> Optional[float]:
    """Return the pt-equivalent of one of the named unit, or None for
    unsupported names."""
    if not isinstance(unit, str):
        return None
    return _PT_PER_UNIT.get(unit.lower())


def parse_length(s: str, default_unit: str) -> Optional[float]:
    """Parse a user-typed length string into a value in points.

    Bare numbers are interpreted in `default_unit`. Unit suffixes
    override the default. Whitespace is tolerated around / between the
    number and the unit. Returns `None` when the input is empty,
    syntactically malformed, or carries an unsupported unit.

    Per UNIT_INPUTS.md §Edge cases — callers decide whether `None`
    means "commit null on a nullable field" or "revert".
    """
    if not isinstance(s, str):
        return None
    if not s.strip():
        return None

    m = _LENGTH_RE.match(s)
    if m is None:
        return None

    num_str = m.group("num")
    unit_str = m.group("unit")

    # The regex's number alternation accepts a lone `-` or `.`; reject
    # those explicitly — Python's float() would also fail, but the
    # explicit check is clearer at the call site.
    try:
        value = float(num_str)
    except ValueError:
        return None

    unit = (unit_str or default_unit).lower()
    factor = _PT_PER_UNIT.get(unit)
    if factor is None:
        return None
    return value * factor


def format_length(pt: Optional[float], unit: str, precision: int = 2) -> str:
    """Render a pt value as a display string in the named unit.

    `None` formats as an empty string (used by nullable dash / gap
    fields when no value is set). Trailing zeros and a trailing decimal
    point are trimmed. Unknown / unsupported `unit` falls back to pt
    rather than producing a malformed output.
    """
    if pt is None:
        return ""

    factor = _PT_PER_UNIT.get(unit.lower()) if isinstance(unit, str) else None
    if factor is None:
        unit = "pt"
        factor = 1.0

    value = pt / factor
    rounded = round(value, precision)
    # `round` may yield -0.0 on negative-near-zero inputs; normalise.
    if rounded == 0.0:
        rounded = 0.0
    text = f"{rounded:.{precision}f}"
    # Trim trailing zeros in the decimal part, then a stranded
    # trailing decimal point.
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return f"{text} {unit.lower()}"
