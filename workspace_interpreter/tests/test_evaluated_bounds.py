"""The live reference as the oracle for the `element_evaluated_bounds`
cross-language family.

`workspace_interpreter.effects._element_evaluated_bbox` is the reference
implementation of the transform-aware bounding box: geometric-bounds corners
mapped through the element's own transform and every ancestor's, innermost
first, then axis-aligned. It is duck-typed — a node supplies `children`,
`geometric_bounds()` and an optional `transform` with `apply_point` — so this
module supplies those stand-ins and drives the reference over the SAME fixture
the two ports are gated on.

What this file does and does not establish:

* The transform CHAIN (which matrices, in which order) and the AABB of the
  four mapped corners are the reference's own code, so the fixture's goldens
  are pinned against the live reference here.
* The matrix CONVENTION (x' = a*x + c*y + e) comes from the stand-in below,
  because the reference has no Transform class of its own; both ports'
  `Transform::apply_point` / `applyPoint` use exactly this form (checked by
  reading them), and the corpus family is what keeps them agreeing.
* The element GEOMETRY comes from the stand-ins below, and the reference has
  none of its own — no ellipse bounds, no cubic or arc extrema. A RECT's box is
  its own x/y/width/height, which this file may derive. Any OTHER kind must name
  its twin vector in `element_bounds.json` via `_geometric_bounds_from`, and its
  box is read from that family's golden rather than restated here, so the number
  lives in exactly one place and is already gated across both ports. Three
  structural tests keep that honest: a non-rect vector must declare its twin;
  every twin must also appear on a control vector with both matrices null (that
  control is what measures, IN THE PORTS, that the strokeless element's
  `bounds()` equals its `geometric_bounds()`); and a control's expected value
  must equal the twin's golden exactly.
"""

from __future__ import annotations

import json
import os

import pytest

from workspace_interpreter.effects import _element_evaluated_bbox

FIXTURE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "test_fixtures", "algorithms", "element_evaluated_bounds.json")


def _vectors():
    with open(FIXTURE, encoding="utf-8") as fh:
        return json.load(fh)


class _Transform:
    """SVG 1.1 matrix(a b c d e f), the convention both ports implement."""

    def __init__(self, d):
        self.a, self.b, self.c = d["a"], d["b"], d["c"]
        self.d, self.e, self.f = d["d"], d["e"], d["f"]

    def apply_point(self, x, y):
        return (self.a * x + self.c * y + self.e,
                self.b * x + self.d * y + self.f)


def _transform(d):
    return None if d is None else _Transform(d)


class _Rect:
    """A rect whose geometric bounds are its own x/y/width/height — no stroke
    inflation, which is the distinction `rect_stroked_uses_geometric_bounds`
    exists to pin."""

    def __init__(self, elem):
        self._b = (elem["x"], elem["y"], elem["width"], elem["height"])
        self.transform = _transform(elem.get("transform"))

    def geometric_bounds(self):
        return self._b


class _Layer:
    def __init__(self, child, layer_transform):
        self.children = [child]
        self.transform = _transform(layer_transform)

    def geometric_bounds(self):  # never reached for path [0, 0]
        raise AssertionError("layer bounds are not part of this family")


class _Doc:
    def __init__(self, layer):
        self.layers = [layer]


class _FromCorpus:
    """A NON-RECT element whose geometric bounds are read from the
    ``element_bounds`` family's golden for the twin vector the fixture names in
    ``_geometric_bounds_from``.

    The reference implements no element geometry at all — it duck-types
    ``elem.bounds()`` off the frozen port (``doc_primitives._child_bounds``) and
    has neither ellipse bounds nor cubic/arc extrema of its own. Hand-copying a
    number into this module would therefore introduce a SECOND, unchecked source
    of truth for the shape's box, which is exactly what the rect-only guard
    below used to prevent. Reading the twin's golden instead keeps one number in
    one place, and that number is already gated across both ports.

    Legal only where ``bounds()`` and ``geometric_bounds()`` coincide, i.e. a
    strokeless element — which is not assumed here but MEASURED in both ports by
    the paired ``*_no_transform_control`` vector, whose expected value is the
    same twin golden with no matrix applied. ``test_every_corpus_shape_has_a_control``
    is what keeps that pairing from being forgotten.
    """

    def __init__(self, elem, twin_bounds):
        self._b = tuple(twin_bounds)
        self.transform = _transform(elem.get("transform"))

    def geometric_bounds(self):
        return self._b


ELEMENT_BOUNDS_FIXTURE = os.path.join(
    os.path.dirname(FIXTURE), "element_bounds.json")


def _element_bounds_goldens():
    with open(ELEMENT_BOUNDS_FIXTURE, encoding="utf-8") as fh:
        return {v["name"]: v["expected"] for v in json.load(fh)}


def _stand_in(vector):
    """The stand-in element for one vector: a rect derives its own box, any
    other kind must name its twin in the element_bounds family."""
    elem = vector["element"]
    twin = vector.get("_geometric_bounds_from")
    if twin is None:
        assert elem["type"] == "rect", (
            f"{vector['name']}: a non-rect vector must declare "
            "_geometric_bounds_from")
        return _Rect(elem)
    goldens = _element_bounds_goldens()
    assert twin in goldens, (
        f"{vector['name']}: _geometric_bounds_from names '{twin}', which is not "
        "a vector of element_bounds.json")
    return _FromCorpus(elem, goldens[twin])


def test_non_rect_vectors_declare_their_twin():
    """The stand-in knows exactly one shape by itself. A vector of another kind
    must name the element_bounds vector its geometric box comes from, so it
    fails here rather than being silently mis-derived."""
    undeclared = [v["name"] for v in _vectors()
                  if v["element"]["type"] != "rect"
                  and "_geometric_bounds_from" not in v]
    assert undeclared == [], (
        f"element_evaluated_bounds.json vectors {undeclared} are not rects and "
        "do not declare _geometric_bounds_from; add the twin element_bounds "
        "vector and name it before adding them here")


def test_every_corpus_shape_has_a_control():
    """Every twin used must also appear on a vector with BOTH matrices null.
    That control is what measures — in the two ports, not here — that the
    element's `bounds()` equals its `geometric_bounds()`, which is the premise
    that lets `_FromCorpus` read the element_bounds golden at all."""
    controls = {v["_geometric_bounds_from"] for v in _vectors()
                if v.get("_geometric_bounds_from")
                and v["element"].get("transform") is None
                and v.get("layer_transform") is None}
    used = {v["_geometric_bounds_from"] for v in _vectors()
            if v.get("_geometric_bounds_from")}
    assert used - controls == set(), (
        f"twins {sorted(used - controls)} are used by a transform-bearing "
        "vector with no null-transform control vector alongside")


def test_control_vectors_equal_their_twin_golden():
    """A control's expected value must BE the twin's element_bounds golden --
    otherwise the two families disagree about the same geometry and
    `_FromCorpus` is reading the wrong number."""
    goldens = _element_bounds_goldens()
    for v in _vectors():
        twin = v.get("_geometric_bounds_from")
        if (twin is None or v["element"].get("transform") is not None
                or v.get("layer_transform") is not None):
            continue
        assert v["expected"] == goldens[twin], (
            f"{v['name']}: control expects {v['expected']} but "
            f"element_bounds/{twin} pins {goldens[twin]}")


@pytest.mark.parametrize("vector", _vectors(), ids=lambda v: v["name"])
def test_reference_reproduces_golden(vector):
    doc = _Doc(_Layer(_stand_in(vector), vector.get("layer_transform")))
    got = _element_evaluated_bbox(doc, [0, 0])
    assert got is not None
    for g, w in zip(got, vector["expected"]):
        assert abs(g - w) < 1e-9, f"{vector['name']}: {got} != {vector['expected']}"
