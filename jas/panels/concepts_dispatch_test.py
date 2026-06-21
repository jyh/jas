"""CONCEPTS.md §6/§10 — the Concepts native verbs fire via the REAL dispatch.

A regression guard for the dispatch-gate class of bug (the one the Rust lead
found, 489a884b): a native concept verb must actually REACH its handler when it
is dispatched through the real panel/menu action-dispatch entry point, not only
when the controller is called directly. Here we drive
``DockPanelWidget._dispatch_concepts_action`` — the SAME method the dock panel's
``dispatch_action`` early-intercept routes ``place_concept_instance`` /
``set_concept_param`` / ``apply_concept_operation`` / ``promote_to_concept`` to —
and assert the document actually changes:

  (a) select a concept + dispatch ``place_concept_instance`` => a Generated is
      appended; and
  (b) add a regular hexagon Polygon, select it, dispatch ``promote_to_concept``
      => it becomes a Generated{regular_polygon, sides:6, radius:50} at ~identity
      placement.

The widget is constructed via ``__new__`` (no Qt event loop), with ``rebuild``
stubbed and a minimal fake state store, so the test exercises the real dispatch
arm without a running QApplication.
"""

import math
import unittest

from document.model import Model
from document.document import Document
from document.controller import Controller
from geometry.element import Layer, Polygon, GeneratedElem
from workspace.dock_panel import DockPanelWidget


class _FakeStore:
    """Just enough of the state store for the concepts dispatch arms: a flat
    panel-content key/value map (``place_concept_instance`` reads the
    panel-selected concept from ``concepts_panel_content/selected_concept``)."""

    def __init__(self):
        self._panels: dict = {}

    def get_panel(self, content_id: str, key: str):
        return self._panels.get((content_id, key))

    def set_panel(self, content_id: str, key: str, value) -> None:
        self._panels[(content_id, key)] = value


def _make_panel(model: Model, store: _FakeStore) -> DockPanelWidget:
    # Build the real widget WITHOUT Qt: bypass __init__ and wire only what the
    # concepts dispatch arm touches. rebuild() is a no-op (it would rebuild Qt
    # children we never created).
    panel = DockPanelWidget.__new__(DockPanelWidget)
    panel._get_model = lambda: model
    panel._state_store = store
    panel.rebuild = lambda: None
    return panel


def _hexagon_points(radius=50.0):
    # A canonical regular hexagon (first vertex on +x, centred at origin) —
    # exactly what regular_polygon{sides:6, radius:50} generates.
    return tuple(
        (radius * math.cos(math.radians(60.0 * i)),
         radius * math.sin(math.radians(60.0 * i)))
        for i in range(6)
    )


class ConceptsDispatchTests(unittest.TestCase):

    def test_place_concept_instance_via_dispatch_creates_generated(self):
        # CONCEPTS.md §6 — the full place flow through the real dispatch arm:
        # select a concept, then dispatch place_concept_instance, and a Generated
        # is appended. The regression guard for the dispatch-gate bug.
        model = Model(document=Document(layers=(Layer(name="L0", children=()),)))
        store = _FakeStore()
        store.set_panel("concepts_panel_content", "selected_concept",
                        "regular_polygon")
        panel = _make_panel(model, store)

        handled = panel._dispatch_concepts_action("place_concept_instance", {})
        self.assertTrue(handled)

        el = model.document.get_element((0, 0))
        self.assertIsInstance(el, GeneratedElem)
        self.assertEqual(el.concept_id, "regular_polygon")

    def test_promote_to_concept_via_dispatch_detects_and_replaces(self):
        # CONCEPTS.md §10 — the full promote flow through the real dispatch arm:
        # a selected regular hexagon is detected by the regular_polygon fitter and
        # replaced with a Generated{sides:6, radius:50} at ~identity placement.
        model = Model(document=Document(
            layers=(Layer(name="L0",
                          children=(Polygon(points=_hexagon_points()),)),)))
        ctrl = Controller(model=model)
        ctrl.set_selection(
            frozenset({_sel_all((0, 0))}))
        store = _FakeStore()
        panel = _make_panel(model, store)

        handled = panel._dispatch_concepts_action("promote_to_concept", {})
        self.assertTrue(handled)

        el = model.document.get_element((0, 0))
        self.assertIsInstance(el, GeneratedElem)
        self.assertEqual(el.concept_id, "regular_polygon")
        self.assertAlmostEqual(el.params["sides"], 6.0, places=9)
        self.assertAlmostEqual(el.params["radius"], 50.0, places=9)
        # Canonical placement (cx=cy=rotation~0) => ~identity transform.
        self.assertAlmostEqual(el.transform.e, 0.0, places=6)
        self.assertAlmostEqual(el.transform.f, 0.0, places=6)


def _sel_all(path):
    from document.document import ElementSelection
    return ElementSelection.all(path)


if __name__ == "__main__":
    unittest.main()
