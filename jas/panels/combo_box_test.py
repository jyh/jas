"""Tests for the combo_box renderer in panels/yaml_renderer.py.

Mirrors the Rust reference (render_combo_box): the editable field shows the
RAW VALUE (e.g. "100"), the dropdown list carries the option LABELS (e.g.
"100%") as the item text with the value as item data, picking an option
writes the raw value back to panel state, and typing a bare number commits
it (parsed) to panel state. Used by the Stroke panel arrowhead-scale fields.
"""

from __future__ import annotations

from absl.testing import absltest
from PySide6.QtWidgets import QApplication, QComboBox

from panels.yaml_renderer import render_element
from workspace_interpreter.state_store import StateStore


_SCALE_OPTS = [
    {"value": 50, "label": "50%"},
    {"value": 100, "label": "100%"},
    {"value": 200, "label": "200%"},
]


class ComboBoxTest(absltest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def _store(self, value):
        store = StateStore()
        store.init_panel("stroke_panel_content", {"start_arrowhead_scale": value})
        store.set_active_panel("stroke_panel_content")
        return store, {"_panel_id": "stroke_panel_content"}

    def _el(self):
        return {
            "type": "combo_box",
            "options": _SCALE_OPTS,
            "bind": {"value": "panel.start_arrowhead_scale"},
        }

    def test_renders_editable_combo(self):
        store, ctx = self._store(100)
        w = render_element(self._el(), store, ctx)
        self.assertIsInstance(w, QComboBox)
        self.assertTrue(w.isEditable())

    def test_initial_display_is_raw_value(self):
        # Field shows "100", NOT the label "100%".
        store, ctx = self._store(100)
        w = render_element(self._el(), store, ctx)
        self.assertEqual(w.currentText(), "100")

    def test_dropdown_items_carry_labels(self):
        store, ctx = self._store(100)
        w = render_element(self._el(), store, ctx)
        labels = [w.itemText(i) for i in range(w.count())]
        self.assertIn("100%", labels)
        # Item data is the raw value.
        idx = labels.index("100%")
        self.assertEqual(w.itemData(idx), 100)

    def test_pick_writes_raw_value(self):
        store, ctx = self._store(100)
        w = render_element(self._el(), store, ctx)
        # Select the "200%" item (index 2) as the user would.
        w.setCurrentIndex(2)
        w.activated.emit(2)
        self.assertEqual(
            store.get_panel("stroke_panel_content", "start_arrowhead_scale"), 200)
        # And the field reflects the raw value, not the label.
        self.assertEqual(w.currentText(), "200")

    def test_type_custom_value_commits(self):
        store, ctx = self._store(100)
        w = render_element(self._el(), store, ctx)
        w.setEditText("175")
        w.lineEdit().editingFinished.emit()
        self.assertEqual(
            store.get_panel("stroke_panel_content", "start_arrowhead_scale"), 175)


if __name__ == "__main__":
    absltest.main()
