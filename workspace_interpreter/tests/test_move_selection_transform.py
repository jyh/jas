"""S-3, the move law: a `move_selection` delta is DOCUMENT space (reference arm).

`Controller.move_selection` is fed document-space deltas by every caller —
the Properties panel's X/Y fields, a journaled `move_selection` op, and (in
the ports) the canvas drag. Control points live in the element's LOCAL space,
so the delta is mapped through the inverse of the accumulated transform before
it is applied. Until 2026-09-17 it was not, and a 30-degree rect typed to
x=100 landed at 83.74 (the S-3 transform-blind class,
`transcripts/EDIT_SEMANTICS_FREEZE.md`).

⛔ THE TWO MOVE SPACES, which is what these arms exist to pin. `ReferenceElem`
has no geometry of its own: a whole-element move rides on its OWN `transform`,
translating its `e`/`f`. That translation already lands in the PARENT's space,
so for a reference the element's own transform must be LEFT OUT of the
conversion while every ancestor's is kept. Converting a reference by the full
chain is a real regression with no other arm in any blocking lane — it was
introduced and caught inside this repair, and these arms are why.
"""

from __future__ import annotations

import os
import sys

_JAS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "jas"))
if _JAS_DIR not in sys.path:
    sys.path.insert(0, _JAS_DIR)

import pytest

from workspace_interpreter.effects import _element_evaluated_bbox


def _origin(doc, path):
    """The element's document-space bbox origin — the point a translation moves."""
    bbox = _element_evaluated_bbox(doc, path)
    assert bbox is not None, f"path {path} did not resolve"
    return (bbox[0], bbox[1])


def _rect_model(transform=None, layer_transform=None):
    from document.document import Document, ElementSelection
    from document.model import Model
    from geometry.element import Layer, Rect
    rect = Rect(x=10.0, y=20.0, width=30.0, height=40.0, transform=transform)
    layer = Layer(children=(rect,), transform=layer_transform)
    return Model(document=Document(
        layers=(layer,), selection=frozenset({ElementSelection.all((0, 0))})))


def _reference_controller(transform=None, layer_transform=None):
    """A ReferenceElem at path (0, 0), selected, optionally under a
    transformed layer. Built through the controller because `make_symbol`
    owns the master/instance wiring."""
    from dataclasses import replace
    from document.controller import Controller
    from document.model import Model
    from geometry.element import Rect
    ctrl = Controller(model=Model())
    ctrl.add_element(Rect(x=0.0, y=0.0, width=10.0, height=10.0))
    ctrl.make_symbol((0, 0), "m1", "i1")
    doc = ctrl.document
    elem = doc.get_element((0, 0))
    doc = doc.replace_element((0, 0), replace(elem, transform=transform))
    if layer_transform is not None:
        doc = replace(doc, layers=(replace(doc.layers[0], transform=layer_transform),))
    ctrl._model.set_document_unbracketed(doc)
    ctrl.select_element((0, 0))
    return ctrl


# ── geometry-bearing elements: the delta converts by the FULL chain ──

@pytest.mark.parametrize("name,transform,layer_transform", [
    ("untransformed", None, None),
    ("rotated", "rotate30", None),
    ("scaled", "scale", None),
    ("sheared", "shear", None),
    ("under a rotated layer", None, "rotate30"),
    ("rotated under a rotated layer", "rotate30", "rotate30"),
])
def test_a_rect_moves_by_the_document_delta(name, transform, layer_transform):
    from document.controller import Controller
    from geometry.element import Transform
    mk = {"rotate30": Transform.rotate(30.0),
          "scale": Transform.scale(2.0, 3.0),
          "shear": Transform.shear(0.25, 0.0)}
    model = _rect_model(mk.get(transform), mk.get(layer_transform))
    before = _origin(model.document, (0, 0))
    Controller(model).move_selection(12.0, -7.0)
    after = _origin(model.document, (0, 0))
    assert after[0] - before[0] == pytest.approx(12.0, abs=1e-9), name
    assert after[1] - before[1] == pytest.approx(-7.0, abs=1e-9), name


# ── references: the move rides on the element's OWN transform ──

@pytest.mark.parametrize("name,transform,layer_transform", [
    ("untransformed", None, None),
    ("rotated", "rotate30", None),
    ("scaled", "scale", None),
    ("under a rotated layer", None, "rotate30"),
    ("rotated under a rotated layer", "rotate30", "rotate30"),
])
def test_a_reference_moves_by_the_document_delta(name, transform, layer_transform):
    from geometry.element import Transform
    mk = {"rotate30": Transform.rotate(30.0),
          "scale": Transform.scale(2.0, 3.0)}
    ctrl = _reference_controller(mk.get(transform), mk.get(layer_transform))
    before = _origin(ctrl.document, (0, 0))
    ctrl.move_selection(12.0, -7.0)
    after = _origin(ctrl.document, (0, 0))
    assert after[0] - before[0] == pytest.approx(12.0, abs=1e-9), name
    assert after[1] - before[1] == pytest.approx(-7.0, abs=1e-9), name


def test_an_untransformed_move_is_unchanged_by_the_conversion():
    """CONTROL. With no transform anywhere the conversion must be the
    identity, so the delta reaches `move_control_points` exactly as it was
    passed — the property that keeps every pre-existing golden valid."""
    from document.controller import Controller
    model = _rect_model()
    Controller(model).move_selection(12.0, -7.0)
    elem = model.document.get_element((0, 0))
    assert (elem.x, elem.y) == (22.0, 13.0)
