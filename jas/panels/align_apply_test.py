"""End-to-end tests for the Python Align apply pipeline — parallels
the Rust / Swift / OCaml ports (e.g.
jas_ocaml/test/interpreter/align_apply_test.ml)."""

from absl.testing import absltest

from document.controller import Controller
from document.document import Document, ElementSelection
from document.model import Model
from geometry.element import Layer, Rect, Transform
from panels.align_apply import (
    apply_align_operation, reset_align_panel,
    sync_align_key_object_from_selection, try_designate_align_key_object,
)
from workspace_interpreter.state_store import StateStore


PANEL_ID = "align_panel_content"


def _rect(x, y, w, h):
    return Rect(x=x, y=y, width=w, height=h)


def _path_marker(path):
    return {"__path__": list(path)}


def _model_with_rects(rects, selected_paths):
    layer = Layer(children=tuple(rects))
    selection = frozenset(ElementSelection.all(tuple(p)) for p in selected_paths)
    doc = Document(layers=(layer,), selection=selection)
    return Model(document=doc)


def _transform_at(model, path):
    elem = model.document.get_element(tuple(path))
    return elem.transform or Transform()


class ApplyAlignTest(absltest.TestCase):

    def test_apply_align_left_translates_non_extremal_rects(self):
        rects = [_rect(10, 0, 10, 10), _rect(30, 0, 10, 10), _rect(60, 0, 10, 10)]
        model = _model_with_rects(rects, [(0, 0), (0, 1), (0, 2)])
        ctrl = Controller(model)
        store = StateStore()
        apply_align_operation(store, ctrl, "align_left")
        # First rect at x=10 — no translation applied (identity).
        self.assertEqual(_transform_at(model, (0, 0)), Transform())
        # Second rect translated by -20.
        t1 = _transform_at(model, (0, 1))
        self.assertAlmostEqual(t1.e, -20.0)
        self.assertAlmostEqual(t1.f, 0.0)
        # Third rect translated by -50.
        t2 = _transform_at(model, (0, 2))
        self.assertAlmostEqual(t2.e, -50.0)
        self.assertAlmostEqual(t2.f, 0.0)

    def test_apply_align_operation_noop_when_fewer_than_two(self):
        rects = [_rect(0, 0, 10, 10), _rect(100, 0, 10, 10)]
        model = _model_with_rects(rects, [(0, 0)])
        ctrl = Controller(model)
        store = StateStore()
        apply_align_operation(store, ctrl, "align_left")
        self.assertEqual(_transform_at(model, (0, 0)), Transform())
        self.assertEqual(_transform_at(model, (0, 1)), Transform())

    def test_apply_align_operation_unknown_op_is_noop(self):
        rects = [_rect(10, 0, 10, 10), _rect(30, 0, 10, 10), _rect(60, 0, 10, 10)]
        model = _model_with_rects(rects, [(0, 0), (0, 1), (0, 2)])
        ctrl = Controller(model)
        store = StateStore()
        apply_align_operation(store, ctrl, "bogus_op")
        for p in [(0, 0), (0, 1), (0, 2)]:
            self.assertEqual(_transform_at(model, p), Transform())

    def test_align_key_object_holds_while_others_move(self):
        rects = [_rect(10, 0, 10, 10), _rect(30, 0, 10, 10), _rect(60, 0, 10, 10)]
        model = _model_with_rects(rects, [(0, 0), (0, 1), (0, 2)])
        ctrl = Controller(model)
        store = StateStore()
        store.set("align_to", "key_object")
        store.set("align_key_object_path", _path_marker((0, 1)))
        apply_align_operation(store, ctrl, "align_left")
        # Key never moves.
        self.assertEqual(_transform_at(model, (0, 1)), Transform())
        # Others align to key's left edge (x=30): rs[0] +20; rs[2] -30.
        self.assertAlmostEqual(_transform_at(model, (0, 0)).e, 20.0)
        self.assertAlmostEqual(_transform_at(model, (0, 2)).e, -30.0)


class AlignToArtboardTest(absltest.TestCase):
    """Phase G — Align To = artboard references the current artboard's
    bounds (topmost panel-selected, else artboard[0])."""

    def _model_with_rects_and_artboards(self, rects, selected_paths, artboards):
        layer = Layer(children=tuple(rects))
        selection = frozenset(
            ElementSelection.all(tuple(p)) for p in selected_paths
        )
        doc = Document(
            layers=(layer,),
            selection=selection,
            artboards=tuple(artboards),
        )
        return Model(document=doc)

    def test_align_left_to_artboard_bounds(self):
        import dataclasses
        from document.artboard import Artboard
        # Artboard at x=100, width=200 → left edge at 100.
        ab = dataclasses.replace(
            Artboard.default_with_id("aaaa0001"),
            x=100.0, y=0.0, width=200.0, height=100.0,
        )
        rects = [_rect(10, 0, 10, 10), _rect(60, 0, 10, 10)]
        model = self._model_with_rects_and_artboards(
            rects, [(0, 0), (0, 1)], [ab]
        )
        ctrl = Controller(model)
        store = StateStore()
        store.set("align_to", "artboard")
        apply_align_operation(store, ctrl, "align_left")
        # Both should translate right so their left edges hit x=100.
        t0 = _transform_at(model, (0, 0))
        self.assertAlmostEqual(t0.e, 90.0)  # 100 - 10
        t1 = _transform_at(model, (0, 1))
        self.assertAlmostEqual(t1.e, 40.0)  # 100 - 60

    def test_align_to_artboard_uses_panel_selected(self):
        import dataclasses
        from document.artboard import Artboard
        # Two artboards. Panel-select the second, so it becomes current.
        ab1 = dataclasses.replace(
            Artboard.default_with_id("aaaa0001"),
            x=0.0, y=0.0, width=100.0, height=100.0,
        )
        ab2 = dataclasses.replace(
            Artboard.default_with_id("bbbb0002"),
            x=500.0, y=0.0, width=200.0, height=100.0,
        )
        rects = [_rect(10, 0, 10, 10), _rect(60, 0, 10, 10)]
        model = self._model_with_rects_and_artboards(
            rects, [(0, 0), (0, 1)], [ab1, ab2]
        )
        ctrl = Controller(model)
        store = StateStore()
        store.init_panel("artboards", {"artboards_panel_selection": ["bbbb0002"]})
        store.set("align_to", "artboard")
        apply_align_operation(store, ctrl, "align_left")
        # Align to ab2's left edge (x=500).
        t0 = _transform_at(model, (0, 0))
        self.assertAlmostEqual(t0.e, 490.0)  # 500 - 10
        t1 = _transform_at(model, (0, 1))
        self.assertAlmostEqual(t1.e, 440.0)  # 500 - 60

    def test_align_to_artboard_fallback_when_no_artboards(self):
        """When the document has no artboards, fall back to selection
        bounds (legacy doc support)."""
        rects = [_rect(10, 0, 10, 10), _rect(30, 0, 10, 10)]
        model = _model_with_rects(rects, [(0, 0), (0, 1)])
        ctrl = Controller(model)
        store = StateStore()
        store.set("align_to", "artboard")
        apply_align_operation(store, ctrl, "align_left")
        # Selection-bounds fallback: left edge = min(10, 30) = 10.
        self.assertEqual(_transform_at(model, (0, 0)), Transform())
        t1 = _transform_at(model, (0, 1))
        self.assertAlmostEqual(t1.e, -20.0)


class ResetAlignPanelTest(absltest.TestCase):

    def test_reset_align_panel_resets_all_fields(self):
        store = StateStore()
        store.set("align_to", "key_object")
        store.set("align_key_object_path", _path_marker((0, 1)))
        store.set("align_distribute_spacing", 12)
        store.set("align_use_preview_bounds", True)
        store.init_panel(PANEL_ID, {})
        reset_align_panel(store)
        self.assertEqual(store.get("align_to"), "selection")
        self.assertIsNone(store.get("align_key_object_path"))
        self.assertEqual(store.get("align_distribute_spacing"), 0)
        self.assertFalse(store.get("align_use_preview_bounds"))
        self.assertEqual(store.get_panel(PANEL_ID, "align_to"), "selection")
        self.assertIsNone(store.get_panel(PANEL_ID, "key_object_path"))


class DesignateKeyObjectTest(absltest.TestCase):

    def _setup(self):
        rects = [_rect(0, 0, 50, 50), _rect(100, 0, 50, 50)]
        model = _model_with_rects(rects, [(0, 0), (0, 1)])
        ctrl = Controller(model)
        store = StateStore()
        store.init_panel(PANEL_ID, {})
        return store, ctrl

    def test_returns_false_when_not_key_mode(self):
        store, ctrl = self._setup()
        self.assertFalse(try_designate_align_key_object(store, ctrl, 25, 25))

    def test_sets_key_on_hit_in_key_mode(self):
        store, ctrl = self._setup()
        store.set("align_to", "key_object")
        self.assertTrue(try_designate_align_key_object(store, ctrl, 25, 25))
        self.assertEqual(store.get("align_key_object_path"), _path_marker((0, 0)))

    def test_second_click_on_same_clears_key(self):
        store, ctrl = self._setup()
        store.set("align_to", "key_object")
        try_designate_align_key_object(store, ctrl, 25, 25)
        try_designate_align_key_object(store, ctrl, 25, 25)
        self.assertIsNone(store.get("align_key_object_path"))

    def test_outside_selection_clears_key(self):
        store, ctrl = self._setup()
        store.set("align_to", "key_object")
        store.set("align_key_object_path", _path_marker((0, 0)))
        try_designate_align_key_object(store, ctrl, 500, 500)
        self.assertIsNone(store.get("align_key_object_path"))


class SyncKeyObjectTest(absltest.TestCase):

    def test_preserves_still_selected(self):
        rects = [_rect(0, 0, 50, 50), _rect(100, 0, 50, 50)]
        model = _model_with_rects(rects, [(0, 0), (0, 1)])
        ctrl = Controller(model)
        store = StateStore()
        store.init_panel(PANEL_ID, {})
        store.set("align_key_object_path", _path_marker((0, 1)))
        sync_align_key_object_from_selection(store, ctrl)
        self.assertEqual(store.get("align_key_object_path"), _path_marker((0, 1)))

    def test_clears_dangling(self):
        rects = [_rect(0, 0, 50, 50), _rect(100, 0, 50, 50)]
        model = _model_with_rects(rects, [(0, 0)])
        ctrl = Controller(model)
        store = StateStore()
        store.init_panel(PANEL_ID, {})
        store.set("align_key_object_path", _path_marker((0, 1)))
        sync_align_key_object_from_selection(store, ctrl)
        self.assertIsNone(store.get("align_key_object_path"))


if __name__ == "__main__":
    absltest.main()
