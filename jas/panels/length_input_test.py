"""Tests for the length_input renderer in panels/yaml_renderer.py.

Mirrors the Flask, Rust, Swift, and OCaml parity tests for the
length_input widget. Verifies that the Python jas renderer:

- Recognises ``length_input`` as a widget type and produces a QLineEdit.
- Initial display value is formatted via workspace_interpreter.length.format
  with the configured unit / precision.
- Bare numbers, decimals, and unit suffixes commit through Length.parse
  back to the panel state with min/max clamping and nullable handling.
"""

from __future__ import annotations

from absl.testing import absltest
from PySide6.QtWidgets import QApplication, QLineEdit

from panels.yaml_renderer import render_element
from workspace_interpreter.state_store import StateStore


class LengthInputTest(absltest.TestCase):

    @classmethod
    def setUpClass(cls):
        if not QApplication.instance():
            cls.app = QApplication([])
        else:
            cls.app = QApplication.instance()

    # ── Render shape ─────────────────────────────────────────────

    def test_renders_qlineedit(self):
        store, ctx = self._make_store_with_weight(1.0)
        el = {
            "type": "length_input",
            "unit": "pt",
            "bind": {"value": "panel.weight"},
        }
        widget = render_element(el, store, ctx)
        self.assertIsInstance(widget, QLineEdit)

    def test_initial_display_uses_format_pt(self):
        store, ctx = self._make_store_with_weight(12.0)
        el = {
            "type": "length_input",
            "unit": "pt",
            "bind": {"value": "panel.weight"},
        }
        widget = render_element(el, store, ctx)
        self.assertEqual(widget.text(), "12 pt")

    def test_initial_display_uses_format_in(self):
        # 72 pt → 1 in.
        store, ctx = self._make_store_with_weight(72.0)
        el = {
            "type": "length_input",
            "unit": "in",
            "bind": {"value": "panel.weight"},
        }
        widget = render_element(el, store, ctx)
        self.assertEqual(widget.text(), "1 in")

    def test_initial_display_null_is_blank(self):
        # Nullable + missing value → empty string.
        store, ctx = self._make_store_with_panel(
            "stroke_panel_content", {"dash_2": None})
        el = {
            "type": "length_input",
            "unit": "pt",
            "nullable": True,
            "bind": {"value": "panel.dash_2"},
        }
        widget = render_element(el, store, ctx)
        self.assertEqual(widget.text(), "")

    def test_placeholder(self):
        store, ctx = self._make_store_with_weight(1.0)
        el = {
            "type": "length_input",
            "unit": "pt",
            "placeholder": "weight",
            "bind": {"value": "panel.weight"},
        }
        widget = render_element(el, store, ctx)
        self.assertEqual(widget.placeholderText(), "weight")

    # ── Commit path ──────────────────────────────────────────────

    def test_commit_bare_number(self):
        store, ctx = self._make_store_with_weight(1.0)
        el = {
            "type": "length_input",
            "unit": "pt",
            "bind": {"value": "panel.weight"},
        }
        widget = render_element(el, store, ctx)
        widget.setText("12")
        widget.editingFinished.emit()
        self.assertEqual(
            store.get_panel("stroke_panel_content", "weight"), 12.0)

    def test_commit_with_unit_suffix(self):
        # "12 px" → 9 pt with default-unit pt.
        store, ctx = self._make_store_with_weight(1.0)
        el = {
            "type": "length_input",
            "unit": "pt",
            "bind": {"value": "panel.weight"},
        }
        widget = render_element(el, store, ctx)
        widget.setText("12 px")
        widget.editingFinished.emit()
        self.assertEqual(
            store.get_panel("stroke_panel_content", "weight"), 9.0)

    def test_commit_clamps_min(self):
        store, ctx = self._make_store_with_weight(5.0)
        el = {
            "type": "length_input",
            "unit": "pt",
            "min": 0,
            "max": 1000,
            "bind": {"value": "panel.weight"},
        }
        widget = render_element(el, store, ctx)
        widget.setText("-10")
        widget.editingFinished.emit()
        self.assertEqual(
            store.get_panel("stroke_panel_content", "weight"), 0.0)

    def test_commit_clamps_max(self):
        store, ctx = self._make_store_with_weight(5.0)
        el = {
            "type": "length_input",
            "unit": "pt",
            "min": 0,
            "max": 1000,
            "bind": {"value": "panel.weight"},
        }
        widget = render_element(el, store, ctx)
        widget.setText("9999")
        widget.editingFinished.emit()
        self.assertEqual(
            store.get_panel("stroke_panel_content", "weight"), 1000.0)

    def test_commit_rejects_garbage_keeps_prior(self):
        store, ctx = self._make_store_with_weight(5.0)
        el = {
            "type": "length_input",
            "unit": "pt",
            "bind": {"value": "panel.weight"},
        }
        widget = render_element(el, store, ctx)
        widget.setText("not a number")
        widget.editingFinished.emit()
        # Store unchanged.
        self.assertEqual(
            store.get_panel("stroke_panel_content", "weight"), 5.0)

    def test_commit_empty_nullable_writes_none(self):
        store, ctx = self._make_store_with_panel(
            "stroke_panel_content", {"dash_2": 4.0})
        el = {
            "type": "length_input",
            "unit": "pt",
            "nullable": True,
            "bind": {"value": "panel.dash_2"},
        }
        widget = render_element(el, store, ctx)
        widget.setText("")
        widget.editingFinished.emit()
        self.assertIsNone(
            store.get_panel("stroke_panel_content", "dash_2"))

    def test_commit_empty_non_nullable_keeps_prior(self):
        store, ctx = self._make_store_with_weight(5.0)
        el = {
            "type": "length_input",
            "unit": "pt",
            "bind": {"value": "panel.weight"},
        }
        widget = render_element(el, store, ctx)
        widget.setText("")
        widget.editingFinished.emit()
        self.assertEqual(
            store.get_panel("stroke_panel_content", "weight"), 5.0)

    # ── Helpers ──────────────────────────────────────────────────

    def _make_store_with_panel(self, panel_id, defaults):
        store = StateStore()
        store.init_panel(panel_id, defaults)
        store.set_active_panel(panel_id)
        return store, {}

    def _make_store_with_weight(self, weight):
        return self._make_store_with_panel(
            "stroke_panel_content", {"weight": weight})


if __name__ == "__main__":
    absltest.main()
