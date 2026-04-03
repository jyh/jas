"""Units of measurement for element coordinates.

Element coordinates can use any unit. The canvas bounding box is in px.
A Measure pairs a numeric value with a Unit.
"""

from dataclasses import dataclass
from enum import Enum


class Unit(Enum):
    """SVG/CSS length units."""
    PX = "px"    # Pixels (default, relative to viewing device)
    PT = "pt"    # Points (1/72 inch)
    PC = "pc"    # Picas (12 points)
    IN = "in"    # Inches
    CM = "cm"    # Centimeters
    MM = "mm"    # Millimeters
    EM = "em"    # Relative to font size
    REM = "rem"  # Relative to root font size


# Pixels per unit at 96 DPI.
_PX_PER_UNIT = {
    Unit.PX: 1.0,
    Unit.PT: 96.0 / 72.0,      # 1 pt = 4/3 px
    Unit.PC: 96.0 / 72.0 * 12,  # 1 pc = 12 pt = 16 px
    Unit.IN: 96.0,
    Unit.CM: 96.0 / 2.54,
    Unit.MM: 96.0 / 25.4,
}


@dataclass(frozen=True)
class Measure:
    """A numeric value paired with a unit of measurement."""
    value: float
    unit: Unit = Unit.PX

    def to_px(self, font_size: float = 16.0) -> float:
        """Convert to pixels.

        Args:
            font_size: The reference font size in px, used for em/rem.
        """
        if self.unit in (Unit.EM, Unit.REM):
            return self.value * font_size
        return self.value * _PX_PER_UNIT[self.unit]


def px(value: float) -> Measure:
    """Shorthand for Measure(value, Unit.PX)."""
    return Measure(value, Unit.PX)


def pt(value: float) -> Measure:
    """Shorthand for Measure(value, Unit.PT)."""
    return Measure(value, Unit.PT)
