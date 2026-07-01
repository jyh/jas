"""Value types for the expression language."""

from __future__ import annotations
import math
from enum import Enum, auto
from dataclasses import dataclass
from typing import Any


def _sci_to_positional(s: str) -> str:
    """Expand a scientific-notation float string (e.g. '1e-05', '-1.23e+20')
    to positional decimal — Rust's f64 Display never uses scientific notation."""
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    mant, _, exp_s = s.partition("e")
    exp = int(exp_s)
    int_part, _, frac_part = mant.partition(".")
    digits = int_part + frac_part
    point = len(int_part) + exp  # decimal-point offset from start of `digits`
    if point <= 0:
        out = "0." + "0" * (-point) + digits
    elif point >= len(digits):
        out = digits + "0" * (point - len(digits))
    else:
        out = digits[:point] + "." + digits[point:]
    if "." in out:
        out = out.rstrip("0").rstrip(".")
    if out in ("", "-"):
        out = "0"
    return ("-" + out) if (neg and out != "0") else out


def number_to_canonical_string(n: Any) -> str:
    """Coerce a number to a string, matching the Rust reference
    (Value::to_string_coerce): integer-valued floats print as integers (any
    magnitude, no overflow); other values use the shortest round-trip decimal
    in positional — never scientific — notation. Keeps {{ }} interpolation and
    string concatenation byte-identical across all apps."""
    if isinstance(n, int):
        return str(n)
    if not math.isfinite(n):
        return "inf" if n > 0 else ("-inf" if n < 0 else "NaN")
    if n == int(n):
        return str(int(n))  # integer-valued (also normalizes -0.0 -> "0")
    s = repr(n)  # shortest round-trip digits
    return s if ("e" not in s and "E" not in s) else _sci_to_positional(s)


class ValueType(Enum):
    BOOL = auto()
    NUMBER = auto()
    STRING = auto()
    COLOR = auto()
    NULL = auto()
    LIST = auto()
    CLOSURE = auto()
    PATH = auto()


@dataclass(slots=True)
class Value:
    type: ValueType
    value: Any

    @staticmethod
    def null() -> Value:
        return Value(ValueType.NULL, None)

    @staticmethod
    def bool_(v: bool) -> Value:
        return Value(ValueType.BOOL, v)

    @staticmethod
    def number(v: float | int) -> Value:
        n = float(v) if isinstance(v, int) else v
        # Keep ints as ints for clean display
        if isinstance(v, float) and v == int(v):
            n = int(v)
        elif isinstance(v, int):
            n = v
        else:
            n = v
        return Value(ValueType.NUMBER, n)

    @staticmethod
    def string(v: str) -> Value:
        return Value(ValueType.STRING, v)

    @staticmethod
    def color(v: str) -> Value:
        """Create a color value. Normalizes 3-digit hex to 6-digit, lowercases."""
        v = v.lower()
        if len(v) == 4:  # #rgb -> #rrggbb
            v = "#" + v[1]*2 + v[2]*2 + v[3]*2
        return Value(ValueType.COLOR, v)

    @staticmethod
    def list_(v: list) -> Value:
        return Value(ValueType.LIST, v)

    @staticmethod
    def path(indices: tuple) -> Value:
        """Create a path value from a tuple of non-negative integers."""
        return Value(ValueType.PATH, tuple(int(i) for i in indices))

    @staticmethod
    def from_python(v: Any) -> Value:
        """Convert a Python value to a typed Value.

        Dicts are wrapped as STRING type but retain the dict reference
        so that property access can drill into them.
        """
        # Already a typed Value (e.g., PATH from a foreach source, or a
        # CLOSURE returned by a helper) — pass through.
        if isinstance(v, Value):
            return v
        if v is None:
            return Value.null()
        if isinstance(v, bool):
            return Value.bool_(v)
        if isinstance(v, (int, float)):
            return Value.number(v)
        if isinstance(v, str):
            if v.startswith("#") and len(v) in (4, 7):
                hex_part = v[1:]
                if all(c in "0123456789abcdefABCDEF" for c in hex_part):
                    return Value.color(v)
            return Value.string(v)
        if isinstance(v, list):
            return Value.list_(v)
        if isinstance(v, dict):
            # Path round-trip: {"__path__": [i, j, ...]} marker restores
            # Value.PATH from its JSON encoding (Phase 3 §6.2).
            if len(v) == 1 and "__path__" in v:
                indices = v["__path__"]
                if isinstance(indices, (list, tuple)) and all(
                    isinstance(i, int) and i >= 0 for i in indices
                ):
                    return Value.path(tuple(indices))
            # Keep as a special "dict" value — stored as STRING type
            # but with the dict reference so DotAccess can drill in.
            return Value(ValueType.STRING, v)
        return Value.string(str(v))

    def to_bool(self) -> bool:
        """Bool coercion per spec section 4.8."""
        if self.type == ValueType.NULL:
            return False
        if self.type == ValueType.BOOL:
            return self.value
        if self.type == ValueType.NUMBER:
            return self.value != 0
        if self.type == ValueType.STRING:
            return len(self.value) > 0
        if self.type == ValueType.LIST:
            return len(self.value) > 0
        return True  # COLOR is always truthy

    def to_string(self) -> str:
        """String coercion for text interpolation."""
        if self.type == ValueType.NULL:
            return ""
        if self.type == ValueType.BOOL:
            return "true" if self.value else "false"
        if self.type == ValueType.NUMBER:
            return number_to_canonical_string(self.value)
        if self.type == ValueType.STRING:
            return self.value
        if self.type == ValueType.COLOR:
            return self.value
        if self.type == ValueType.LIST:
            return "[list]"
        if self.type == ValueType.PATH:
            return ".".join(str(i) for i in self.value)
        return str(self.value)
