"""BRUSHAPPLY (2026-07-24): the brush-tile click-to-apply flow.

Pins the value-form law for ``doc.*`` effect VALUES (the BRUSHAPPLY
stone): a ``doc.set_attr_on_selection`` ``value:`` is a PURE EXPRESSION
in the purpose-built language — evaluated with ``evaluate`` exactly like
every sibling ``doc.*`` value, and NOT ``{{}}``-text-interpolated. A
brush id is therefore composed by string concatenation:
``param.library + "/" + param.brush_slug``.

Before this wave the reference had NO ``doc.set_attr_on_selection`` verb
at all (the referee was blind), and the ``actions.yaml`` value was a
string LITERAL carrying literal moustaches (``"{{param.library}}/..."``)
that resolved to the un-expanded template. Both are fixed here.
"""

from __future__ import annotations

import os

from workspace_interpreter.effects import run_effects
from workspace_interpreter.loader import load_workspace
from workspace_interpreter.state_store import StateStore
from workspace_interpreter.tests.store_docs import (
    Color, Fill, Layer, Line, LineTo, MoveTo, Path, Polyline, Stroke, store_doc)


def _doc_with_selected_path(brush: str | None = None) -> dict:
    """A one-layer document holding a single stroked Path, selected."""
    return store_doc(Layer(name="L", children=(
        Path(d=(MoveTo(10.0, 10.0), LineTo(100.0, 60.0)),
             stroke=Stroke(color=Color.from_hex("#000000"), width=2.0),
             stroke_brush=brush),
    )), selected=[[0, 0]])


class TestBrushApplyValueForm:
    def test_set_attr_on_selection_composes_brush_id_by_concatenation(self):
        # The reference-shaped repro from the BRUSHAPPLY stone: a selected
        # path + the FIXED value EXPRESSION (concatenation), asserting the
        # composed brush id lands on the element. RED before the verb
        # existed (the effect was a silent no-op and stroke_brush stayed
        # None).
        store = StateStore(document=_doc_with_selected_path())
        run_effects(
            [{"doc.set_attr_on_selection": {
                "attr": "stroke_brush",
                "value": 'param.library + "/" + param.brush_slug',
            }}],
            {"param": {"library": "default_brushes", "brush_slug": "flat_10"}},
            store,
        )
        assert store.get_element((0, 0))["stroke_brush"] == "default_brushes/flat_10"

    def test_set_attr_on_selection_null_result_clears(self):
        # A null/empty resolved value CLEARS the attribute (writes None),
        # mirroring the active ports' empty-string => clear rule.
        store = StateStore(document=_doc_with_selected_path("default_brushes/flat_10"))
        run_effects(
            [{"doc.set_attr_on_selection": {"attr": "stroke_brush", "value": "null"}}],
            {}, store,
        )
        assert store.get_element((0, 0))["stroke_brush"] is None

    def test_unknown_attr_is_a_hard_skip(self):
        store = StateStore(document=_doc_with_selected_path())
        run_effects(
            [{"doc.set_attr_on_selection": {"attr": "fill_color", "value": "'#ff0000'"}}],
            {}, store,
        )
        # Untouched: an unknown attr records nothing.
        assert "fill_color" not in store.get_element((0, 0))


def _doc_with_selected_line() -> dict:
    """A one-layer document holding a single stroked Line, selected."""
    return store_doc(Layer(name="L", children=(
        Line(x1=10.0, y1=10.0, x2=100.0, y2=60.0,
             stroke=Stroke(color=Color.from_hex("#000000"), width=2.0),
             name="my line", id="line-7"),
    )), selected=[[0, 0]])


def _doc_with_selected_polyline() -> dict:
    """A one-layer document holding a single filled+stroked Polyline, selected."""
    return store_doc(Layer(name="L", children=(
        Polyline(points=((0.0, 0.0), (10.0, 5.0), (20.0, 0.0)),
                 fill=Fill(color=Color.from_hex("#ff0000")),
                 stroke=Stroke(color=Color.from_hex("#000000"), width=2.0),
                 id="poly-1"),
    )), selected=[[0, 0]])


class TestBrushApplyPromotesLine:
    """LINEPROMOTE (JYH 2026-07-25): applying a brush to a Line promotes it to
    a geometry-identical Path that carries the brush — the "upgrade naturally"
    convention, mirroring the Rect→Polygon corner-drag promotion."""

    def test_line_promotes_to_path_and_carries_brush(self):
        store = StateStore(document=_doc_with_selected_line())
        before = dict(store.get_element((0, 0)))
        run_effects(
            [{"doc.set_attr_on_selection": {
                "attr": "stroke_brush",
                "value": 'param.library + "/" + param.brush_slug',
            }}],
            {"param": {"library": "default_brushes", "brush_slug": "flat_10"}},
            store,
        )
        elem = store.get_element((0, 0))
        # Type upgraded Line -> Path, geometry identical (MoveTo + LineTo).
        assert elem["type"] == "path"
        assert elem["d"] == [
            {"cmd": "M", "x": 10.0, "y": 10.0},
            {"cmd": "L", "x": 100.0, "y": 60.0},
        ]
        # The brush landed; the line-only endpoint fields are gone.
        assert elem["stroke_brush"] == "default_brushes/flat_10"
        assert "x1" not in elem and "y2" not in elem
        # Stroke + identity carried WHOLE.
        assert before["stroke"] is not None
        assert elem["stroke"] == before["stroke"]
        assert (elem["name"], elem["id"]) == ("my line", "line-7")

    def test_polyline_promotes_carrying_fill(self):
        store = StateStore(document=_doc_with_selected_polyline())
        before = dict(store.get_element((0, 0)))
        run_effects(
            [{"doc.set_attr_on_selection": {
                "attr": "stroke_brush", "value": "'default_brushes/flat_10'"}}],
            {}, store,
        )
        elem = store.get_element((0, 0))
        assert elem["type"] == "path"
        assert elem["d"] == [
            {"cmd": "M", "x": 0.0, "y": 0.0},
            {"cmd": "L", "x": 10.0, "y": 5.0},
            {"cmd": "L", "x": 20.0, "y": 0.0},
        ]
        assert elem["stroke_brush"] == "default_brushes/flat_10"
        # A Polyline's fill carries across (unlike a Line, which has none).
        assert before["fill"] is not None
        assert elem["fill"] == before["fill"]
        assert elem["id"] == "poly-1"

    def test_clearing_a_brush_never_promotes_a_line(self):
        # A null/empty resolved value is NOT a brush application — a Line stays
        # a Line (no surprise upgrade on a clear).
        store = StateStore(document=_doc_with_selected_line())
        run_effects(
            [{"doc.set_attr_on_selection": {"attr": "stroke_brush", "value": "null"}}],
            {}, store,
        )
        elem = store.get_element((0, 0))
        assert elem["type"] == "line"
        assert elem["stroke_brush"] is None
        assert elem["x1"] == 10.0


_BUNDLE = os.path.join(
    os.path.dirname(__file__), "..", "..", "workspace", "workspace.json"
)


class TestBrushApplyEndToEnd:
    def test_apply_brush_to_selection_action_lands_composed_id(self):
        # End-to-end through the COMPILED bundle: dispatch the real
        # apply_brush_to_selection action. Its params are EXPRESSIONS, so
        # the caller passes quoted string literals (mirroring the panel's
        # `library: "lib.id"` binding). Guards the actions.yaml value
        # expression + the snapshot step together.
        ws = load_workspace(_BUNDLE)
        actions = ws["actions"]
        store = StateStore(document=_doc_with_selected_path())
        run_effects(
            [{"dispatch": {
                "action": "apply_brush_to_selection",
                "params": {"library": "'default_brushes'", "brush_slug": "'flat_10'"},
            }}],
            {}, store, actions=actions,
        )
        elem = store.get_element((0, 0))
        assert elem["stroke_brush"] == "default_brushes/flat_10"
        # apply_brush_to_selection also clears overrides. (doc.snapshot is a
        # native-transaction effect, a no-op on the semantic-oracle path, so
        # undo mechanics are pinned in the Rust/Swift suites, not here.)
        assert elem["stroke_brush_overrides"] is None
