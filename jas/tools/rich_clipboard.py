"""Rich clipboard — multi-format write/read via Qt's QClipboard.

Mirrors Rust d76b09f / Swift db12cad / OCaml d06fd98. Qt supports
multi-format cleanly through ``QMimeData``, so on cut/copy the
type tool publishes all three formats (``text/plain``,
``application/x-jas-tspans``, ``image/svg+xml``) simultaneously.
Paste prefers the JSON format, falls back to SVG, then to plain
text. Cross-app rich paste works natively on desktop Qt.
"""

from __future__ import annotations

from typing import Optional

from geometry.tspan import (
    Tspan, tspans_from_json_clipboard, tspans_from_svg_fragment,
    tspans_to_json_clipboard, tspans_to_svg_fragment,
)

JAS_TSPANS_MIME = "application/x-jas-tspans"
SVG_XML_MIME = "image/svg+xml"


def rich_clipboard_write(flat: str, tspans: list[Tspan]) -> None:
    """Publish ``tspans`` to the system clipboard in three formats.
    Silent no-op when Qt isn't available (e.g. headless tests that
    never constructed a QApplication)."""
    try:
        from PySide6.QtCore import QMimeData, QByteArray
        from PySide6.QtWidgets import QApplication
    except ImportError:
        return
    app = QApplication.instance()
    if app is None:
        return
    mime = QMimeData()
    mime.setText(flat)
    mime.setData(JAS_TSPANS_MIME,
                  QByteArray(tspans_to_json_clipboard(tspans).encode("utf-8")))
    mime.setData(SVG_XML_MIME,
                  QByteArray(tspans_to_svg_fragment(tspans).encode("utf-8")))
    QApplication.clipboard().setMimeData(mime)


def rich_clipboard_read_tspans() -> Optional[tuple[Tspan, ...]]:
    """Read the best rich-clipboard format available from the system
    clipboard and return the tspan tuple, or ``None`` when no rich
    format is present or parseable. Callers fall back to flat
    ``clipboard.text()`` in that case."""
    try:
        from PySide6.QtWidgets import QApplication
    except ImportError:
        return None
    app = QApplication.instance()
    if app is None:
        return None
    mime = QApplication.clipboard().mimeData()
    if mime is None:
        return None
    if mime.hasFormat(JAS_TSPANS_MIME):
        data = bytes(mime.data(JAS_TSPANS_MIME)).decode("utf-8", errors="replace")
        parsed = tspans_from_json_clipboard(data)
        if parsed is not None:
            return parsed
    if mime.hasFormat(SVG_XML_MIME):
        data = bytes(mime.data(SVG_XML_MIME)).decode("utf-8", errors="replace")
        parsed = tspans_from_svg_fragment(data)
        if parsed is not None:
            return parsed
    return None
