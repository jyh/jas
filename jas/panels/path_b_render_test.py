"""Tests for the Path B panel render in panels/yaml_renderer.py.

Path B renders a panel from the shared canonical layout pass
(``workspace_interpreter.panel_layout.layout_panel``) — one absolutely
positioned box per leaf widget — instead of delegating intra-panel layout
to Qt's layout managers. It is opt-in via ``JAS_PATH_B=1`` and is the
human-viewable Qt reference of the cross-app byte-gated layout (the same
pass the byte-gate in cross_language_test.py asserts against the golden
``test_fixtures/algorithms/panel_layout.json``). See PATH_B_DESIGN.md §5
Phase 2.

These tests build the *opacity* panel through the renderer and assert that
a leaf widget lands at its canonical golden rect — Qt geometry is queryable
headlessly under ``QT_QPA_PLATFORM=offscreen``, so this is a real geometry
check, not just a smoke test.
"""
from __future__ import annotations

import json
import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from absl.testing import absltest
from PySide6.QtWidgets import QApplication, QComboBox

from panels.yaml_renderer import (
    render_panel_absolute,
    _node_at_path,
    _path_b_enabled,
    _PATH_B_UNSUPPORTED,
)
from workspace_interpreter.state_store import StateStore

# The byte-gate loads panels from the compiled bundle (workspace.json),
# keyed by content id — match that so the rects line up with the golden.
_BUNDLE = os.path.join(
    os.path.dirname(__file__), "..", "..", "workspace", "workspace.json")


def _opacity_panel() -> dict:
    with open(_BUNDLE) as f:
        return json.load(f)["panels"]["opacity_panel_content"]


class PathBHelpersTest(absltest.TestCase):
    """The flag, the excluded set, and the path walker."""

    def test_flag_off_by_default(self):
        prior = os.environ.pop("JAS_PATH_B", None)
        try:
            self.assertFalse(_path_b_enabled())
        finally:
            if prior is not None:
                os.environ["JAS_PATH_B"] = prior

    def test_flag_on_with_env(self):
        prior = os.environ.get("JAS_PATH_B")
        os.environ["JAS_PATH_B"] = "1"
        try:
            self.assertTrue(_path_b_enabled())
        finally:
            if prior is None:
                os.environ.pop("JAS_PATH_B", None)
            else:
                os.environ["JAS_PATH_B"] = prior

    def test_excluded_set(self):
        self.assertEqual(
            _PATH_B_UNSUPPORTED,
            {"color_panel_content", "gradient_panel_content",
             "layers_panel_content"})

    def test_node_at_path_walks_children(self):
        content = _opacity_panel()["content"]
        node = _node_at_path(content, [0, 0])
        self.assertIsInstance(node, dict)
        self.assertEqual(node.get("type"), "select")
        self.assertEqual(node.get("id"), "op_mode")

    def test_node_at_path_out_of_range(self):
        content = _opacity_panel()["content"]
        self.assertIsNone(_node_at_path(content, [0, 99]))


class PathBOpacityGeometryTest(absltest.TestCase):
    """The opacity panel's op_mode select lands at the canonical golden rect.

    Golden (test_fixtures/algorithms/panel_layout.json, opacity@228):
      root [] -> {x:0, y:0, w:228, h:106}
      op_mode [0,0] -> {x:4, y:6, w:73, h:20}
    """

    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def _build(self):
        panel = _opacity_panel()
        store = StateStore()
        store.init_panel("opacity_panel_content", {})
        store.set_active_panel("opacity_panel_content")
        return render_panel_absolute(
            panel, store, {"_panel_id": "opacity_panel_content"})

    def test_container_is_canonical_size(self):
        container = self._build()
        # layout-less container fixed to (228, panel_h) — panel_h is the
        # root rect height from the shared pass.
        self.assertEqual(container.width(), 228)
        self.assertEqual(container.height(), 106)

    def test_op_mode_select_lands_at_golden_rect(self):
        container = self._build()
        combos = [c for c in container.children() if isinstance(c, QComboBox)]
        self.assertEqual(len(combos), 1, "expected exactly one select (op_mode)")
        g = combos[0].geometry()
        self.assertEqual((g.x(), g.y(), g.width(), g.height()), (4, 6, 73, 20))

    def test_foreach_rows_render_with_real_data(self):
        """The render plan expands foreach with per-row child scopes, so the
        symbols list renders its master rows (each {{sym.name}} resolved)."""
        from PySide6.QtWidgets import QLabel
        with open(_BUNDLE) as f:
            sym = json.load(f)["panels"]["symbols_panel_content"]
        store = StateStore()
        store.init_panel("symbols_panel_content", {})
        store.set_active_panel("symbols_panel_content")
        ctx = {"active_document": {"symbols": [
            {"id": "a", "name": "Star", "usage_count": 1},
            {"id": "b", "name": "Gear", "usage_count": 2}]}}
        container = render_panel_absolute(sym, store, ctx)
        texts = " ".join(c.text() for c in container.findChildren(QLabel))
        self.assertIn("Star", texts)
        self.assertIn("Gear", texts)


if __name__ == "__main__":
    absltest.main()
