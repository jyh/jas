"""Value types for the expression language."""

from __future__ import annotations
from enum import Enum, auto
from dataclasses import dataclass
from typing import Any


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
            if isinstance(self.value, float) and self.value == int(self.value):
                return str(int(self.value))
            return str(self.value)
        if self.type == ValueType.STRING:
            return self.value
        if self.type == ValueType.COLOR:
            return self.value
        if self.type == ValueType.LIST:
            return "[list]"
        if self.type == ValueType.PATH:
            return ".".join(str(i) for i in self.value)
        return str(self.value)
