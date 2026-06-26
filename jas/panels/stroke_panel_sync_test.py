"""Stroke panel WEIGHT sync from selection (decision-5).

The Stroke panel's weight field must show the SELECTED element's
``stroke.width`` (its effective/baked weight after the scale counter-scale
work), not the YAML default. ``sync_stroke_panel_from_selection`` writes the
selected element's stroke width into the ``stroke_width`` global key that the
weight widget reads (stroke.yaml ``init: weight: state.stroke_width``).
"""
from absl.testing import absltest

from workspace_interpreter.effects import sync_stroke_panel_from_selection
from workspace_interpreter.state_store import StateStore
from document.document import Document, ElementSelection
from document.model import Model
from geometry.element import Rect, Stroke, RgbColor, Layer


class StrokePanelSyncTest(absltest.TestCase):

    def _store(self):
        # Register the Stroke panel state so the sync (which no-ops when the
        # panel is absent) writes panel.weight.
        store = StateStore()
        store.init_panel("stroke_panel_content", {"weight": 1.0})
        return store

    def _model(self, *, width=None, selected=True):
        stroke = (Stroke(color=RgbColor(0, 0, 0), width=width)
                  if width is not None else None)
        rect = Rect(x=0, y=0, width=10, height=10, stroke=stroke)
        layer = Layer(children=(rect,), name="L0")
        sel = (frozenset({ElementSelection.all((0, 0))})
               if selected else frozenset())
        return Model(document=Document(layers=(layer,), selection=sel))

    def _weight(self, store):
        return store.get_panel("stroke_panel_content", "weight")

    def test_weight_from_selected_element(self):
        store = self._store()
        # A scaled element baked its stroke to 2.5pt — the panel must show it.
        sync_stroke_panel_from_selection(store, self._model(width=2.5))
        self.assertEqual(self._weight(store), 2.5)

    def test_no_selection_uses_model_default(self):
        store = self._store()
        m = self._model(width=2.5, selected=False)
        sync_stroke_panel_from_selection(store, m)
        self.assertEqual(self._weight(store), m.default_stroke.width)

    def test_selected_element_without_stroke_uses_default(self):
        store = self._store()
        m = self._model(width=None, selected=True)  # rect has no stroke
        sync_stroke_panel_from_selection(store, m)
        self.assertEqual(self._weight(store), m.default_stroke.width)

    def test_noop_when_panel_absent(self):
        store = StateStore()  # no stroke panel registered
        sync_stroke_panel_from_selection(store, self._model(width=2.5))
        self.assertIsNone(store.get_panel("stroke_panel_content", "weight"))

    def test_none_model_does_not_raise(self):
        store = self._store()
        sync_stroke_panel_from_selection(store, None)  # must not raise


if __name__ == "__main__":
    absltest.main()
