"""Properties panel X/Y/W/H sync from selection (decision-5 Part B).

The Properties panel shows the selection's EVALUATED bounding box — its
geometric bbox mapped through each element's full document-space transform,
then axis-aligned. ``selection_evaluated_bounds`` computes it and
``sync_properties_panel_from_selection`` mirrors it into the panel x/y/w/h
fields the widgets bind.
"""
from absl.testing import absltest

from workspace_interpreter.effects import (
    selection_evaluated_bounds,
    sync_properties_panel_from_selection,
)
from workspace_interpreter.state_store import StateStore
from document.document import Document, ElementSelection
from document.model import Model
from geometry.element import Rect, Transform, Layer


def _model(elements, selected):
    layer = Layer(children=tuple(elements))
    sel = frozenset(ElementSelection.all((0, i)) for i in selected)
    return Model(document=Document(layers=(layer,), selection=sel))


class SelectionEvaluatedBoundsTest(absltest.TestCase):

    def test_untransformed_rect(self):
        m = _model([Rect(x=10, y=20, width=30, height=40)], [0])
        self.assertEqual(selection_evaluated_bounds(m.document),
                         (10.0, 20.0, 30.0, 40.0))

    def test_scaled_rect_grows_bbox(self):
        # Local (10,20,30,40) scaled 2x -> corners (20,40)..(80,120).
        m = _model([Rect(x=10, y=20, width=30, height=40,
                         transform=Transform.scale(2))], [0])
        self.assertEqual(selection_evaluated_bounds(m.document),
                         (20.0, 40.0, 60.0, 80.0))

    def test_translated_rect_shifts_bbox(self):
        m = _model([Rect(x=10, y=20, width=30, height=40,
                         transform=Transform.translate(5, 7))], [0])
        self.assertEqual(selection_evaluated_bounds(m.document),
                         (15.0, 27.0, 30.0, 40.0))

    def test_rotate_90_swaps_extents(self):
        # 10x20 rect rotated 90deg -> 20x10 bbox (apply_point: (x,y)->(-y,x)).
        m = _model([Rect(x=0, y=0, width=10, height=20,
                         transform=Transform.rotate(90))], [0])
        x, y, w, h = selection_evaluated_bounds(m.document)
        self.assertAlmostEqual(w, 20.0, places=6)
        self.assertAlmostEqual(h, 10.0, places=6)

    def test_union_of_two_selected(self):
        m = _model([Rect(x=0, y=0, width=10, height=10),
                    Rect(x=100, y=0, width=10, height=10)], [0, 1])
        self.assertEqual(selection_evaluated_bounds(m.document),
                         (0.0, 0.0, 110.0, 10.0))

    def test_empty_selection_is_zero(self):
        m = _model([Rect(x=10, y=20, width=30, height=40)], [])
        self.assertEqual(selection_evaluated_bounds(m.document),
                         (0.0, 0.0, 0.0, 0.0))


class PropertiesPanelSyncTest(absltest.TestCase):

    def _store(self):
        store = StateStore()
        store.init_panel("properties_panel_content",
                         {"prop_x": 0, "prop_y": 0, "prop_w": 0, "prop_h": 0})
        return store

    def _panel(self, store, key):
        return store.get_panel("properties_panel_content", key)

    def test_sync_writes_evaluated_bbox(self):
        store = self._store()
        m = _model([Rect(x=10, y=20, width=30, height=40,
                         transform=Transform.scale(2))], [0])
        sync_properties_panel_from_selection(store, m)
        self.assertEqual(self._panel(store, "prop_x"), 20.0)
        self.assertEqual(self._panel(store, "prop_y"), 40.0)
        self.assertEqual(self._panel(store, "prop_w"), 60.0)
        self.assertEqual(self._panel(store, "prop_h"), 80.0)

    def test_sync_empty_selection_is_zero(self):
        store = self._store()
        m = _model([Rect(x=10, y=20, width=30, height=40)], [])
        sync_properties_panel_from_selection(store, m)
        self.assertEqual(self._panel(store, "prop_w"), 0.0)
        self.assertEqual(self._panel(store, "prop_h"), 0.0)

    def test_none_model_does_not_raise(self):
        store = self._store()
        sync_properties_panel_from_selection(store, None)


if __name__ == "__main__":
    absltest.main()
