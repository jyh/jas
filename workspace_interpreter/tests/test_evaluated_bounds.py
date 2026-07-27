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
* The element GEOMETRY (a rect's own bbox) comes from the stand-in too. The
  fixture is therefore restricted to rects, and `test_fixture_is_rect_only`
  fails if a later vector adds a shape whose bounds this file would have to
  guess at.
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


def test_fixture_is_rect_only():
    """The stand-in above knows one shape. A new vector of another kind must
    fail here rather than be silently mis-derived."""
    kinds = {v["element"]["type"] for v in _vectors()}
    assert kinds == {"rect"}, (
        f"element_evaluated_bounds.json now contains {sorted(kinds)}; teach "
        "this module that shape's geometric bounds before adding it")


@pytest.mark.parametrize("vector", _vectors(), ids=lambda v: v["name"])
def test_reference_reproduces_golden(vector):
    doc = _Doc(_Layer(_Rect(vector["element"]), vector.get("layer_transform")))
    got = _element_evaluated_bbox(doc, [0, 0])
    assert got is not None
    for g, w in zip(got, vector["expected"]):
        assert abs(g - w) < 1e-9, f"{vector['name']}: {got} != {vector['expected']}"
