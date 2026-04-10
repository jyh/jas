"""Pixel-width measurement for the in-place text editor.

In production this uses Qt's `QFontMetricsF.horizontalAdvance`, which
matches what the canvas painter actually draws. For headless tests
(no QApplication) we fall back to a deterministic 0.55 * font_size stub.
"""

from __future__ import annotations

from collections.abc import Callable


def make_measurer(family: str, weight: str, style: str, size: float) -> Callable[[str], float]:
    """Return a closure measuring text width in pixels for the given font."""
    try:
        from PySide6.QtGui import QFont, QFontMetricsF  # type: ignore
        from PySide6.QtWidgets import QApplication  # type: ignore
        if QApplication.instance() is None:
            return _stub_measurer(size)
        font = QFont(family, int(size))
        if weight == "bold":
            font.setBold(True)
        if style == "italic":
            font.setItalic(True)
        fm = QFontMetricsF(font)

        def measure(s: str) -> float:
            return float(fm.horizontalAdvance(s))

        return measure
    except (ImportError, RuntimeError):
        return _stub_measurer(size)


def _stub_measurer(size: float) -> Callable[[str], float]:
    return lambda s: len(s) * size * 0.55
