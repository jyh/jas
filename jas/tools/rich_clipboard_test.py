"""Tests for the rich clipboard wrapper around Qt's QClipboard.

Needs a QApplication instance — constructed at import time so
write/read actually hit the Qt pasteboard. Each test clears the
clipboard first so results are independent.
"""

from __future__ import annotations

import pytest

# Construct a single QApplication for every test in this file.
try:
    from PySide6.QtWidgets import QApplication
    if QApplication.instance() is None:
        _qapp = QApplication([])
except ImportError:
    pytest.skip("PySide6 not available", allow_module_level=True)

from geometry.tspan import Tspan
from tools.rich_clipboard import (
    JAS_TSPANS_MIME, SVG_XML_MIME,
    rich_clipboard_read_tspans, rich_clipboard_write,
)


def _clear_clipboard():
    QApplication.clipboard().clear()


def test_write_populates_three_formats():
    _clear_clipboard()
    tspans = [
        Tspan(id=0, content="foo"),
        Tspan(id=1, content="bar", font_weight="bold"),
    ]
    rich_clipboard_write("foobar", tspans)
    mime = QApplication.clipboard().mimeData()
    assert mime.hasText()
    assert mime.text() == "foobar"
    assert mime.hasFormat(JAS_TSPANS_MIME)
    json_payload = bytes(mime.data(JAS_TSPANS_MIME)).decode()
    assert '"content":"foo"' in json_payload or '"content": "foo"' in json_payload
    assert '"font_weight":"bold"' in json_payload or '"font_weight": "bold"' in json_payload
    assert mime.hasFormat(SVG_XML_MIME)
    svg = bytes(mime.data(SVG_XML_MIME)).decode()
    assert "<tspan>foo</tspan>" in svg
    assert '<tspan font-weight="bold">bar</tspan>' in svg


def test_read_prefers_json_over_svg():
    _clear_clipboard()
    rich_clipboard_write("X", [Tspan(id=0, content="X", font_weight="bold")])
    back = rich_clipboard_read_tspans()
    assert back is not None
    assert len(back) == 1
    assert back[0].content == "X"
    assert back[0].font_weight == "bold"


def test_read_returns_none_when_formats_missing():
    _clear_clipboard()
    QApplication.clipboard().setText("just plain text")
    assert rich_clipboard_read_tspans() is None


def test_read_svg_fallback_when_json_absent():
    # Simulate another SVG-aware app: only the SVG fragment format.
    from PySide6.QtCore import QByteArray, QMimeData
    _clear_clipboard()
    mime = QMimeData()
    mime.setText("X")
    mime.setData(SVG_XML_MIME, QByteArray(
        b'<text xmlns="http://www.w3.org/2000/svg">'
        b'<tspan font-weight="bold">X</tspan></text>'))
    QApplication.clipboard().setMimeData(mime)
    back = rich_clipboard_read_tspans()
    assert back is not None
    assert len(back) == 1
    assert back[0].content == "X"
    assert back[0].font_weight == "bold"
