"""Consumes test_fixtures/algorithms/align.json entirely inside
`pytest` and asserts the Python Align output matches the Rust /
Swift / OCaml reference for every vector."""

import json
import os

from absl.testing import absltest

from algorithms import align as align_algo
from algorithms.align import (
    AlignReference, geometric_bounds, preview_bounds, union_bounds,
)
from geometry.element import Rect


_FIXTURE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "test_fixtures", "algorithms", "align.json",
)
_EPS = 1e-4


_OPS = {
    "align_left": align_algo.align_left,
    "align_horizontal_center": align_algo.align_horizontal_center,
    "align_right": align_algo.align_right,
    "align_top": align_algo.align_top,
    "align_vertical_center": align_algo.align_vertical_center,
    "align_bottom": align_algo.align_bottom,
    "distribute_left": align_algo.distribute_left,
    "distribute_horizontal_center": align_algo.distribute_horizontal_center,
    "distribute_right": align_algo.distribute_right,
    "distribute_top": align_algo.distribute_top,
    "distribute_vertical_center": align_algo.distribute_vertical_center,
    "distribute_bottom": align_algo.distribute_bottom,
}
_SPACING_OPS = {
    "distribute_vertical_spacing": align_algo.distribute_vertical_spacing,
    "distribute_horizontal_spacing": align_algo.distribute_horizontal_spacing,
}


def _run_vector(v):
    rects = [Rect(x=r[0], y=r[1], width=r[2], height=r[3]) for r in v["rects"]]
    pairs = [((i,), r) for i, r in enumerate(rects)]
    use_preview = v.get("use_preview_bounds", False)
    bounds_fn = preview_bounds if use_preview else geometric_bounds

    ref = v.get("reference") or {}
    kind = ref.get("kind", "selection")
    if kind == "artboard":
        bbox = ref.get("bbox", [0, 0, 0, 0])
        reference = AlignReference.artboard(tuple(bbox))
    elif kind == "key_object":
        idx = ref["index"]
        reference = AlignReference.key_object(bounds_fn(rects[idx]), (idx,))
    else:
        reference = AlignReference.selection(union_bounds(rects, bounds_fn))

    explicit_gap = v.get("explicit_gap")
    op = v["op"]
    if op in _OPS:
        return _OPS[op](pairs, reference, bounds_fn)
    if op in _SPACING_OPS:
        return _SPACING_OPS[op](pairs, reference, explicit_gap, bounds_fn)
    raise ValueError(f"unknown op: {op}")


class AlignFixtureTest(absltest.TestCase):
    pass


def _load_vectors():
    with open(_FIXTURE) as f:
        return json.load(f)["vectors"]


def _make_test(vector):
    def test(self):
        actual = _run_vector(vector)
        expected = vector["translations"]
        self.assertEqual(len(actual), len(expected),
                         f"translation count mismatch in {vector['name']}")
        for a, e in zip(actual, expected):
            self.assertEqual(list(a.path), e["path"],
                             f"path mismatch in {vector['name']}")
            self.assertAlmostEqual(a.dx, e["dx"], delta=_EPS,
                                   msg=f"dx mismatch in {vector['name']}")
            self.assertAlmostEqual(a.dy, e["dy"], delta=_EPS,
                                   msg=f"dy mismatch in {vector['name']}")
    return test


for _vec in _load_vectors():
    _name = "test_" + _vec["name"]
    setattr(AlignFixtureTest, _name, _make_test(_vec))


if __name__ == "__main__":
    absltest.main()
