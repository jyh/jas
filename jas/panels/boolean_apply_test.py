"""Tests for panels.boolean_apply — compound-shape menu dispatch.

Mirrors jas_dioxus/src/document/controller.rs:
- make_compound_shape_wraps_selection_in_one_live_element
- release_compound_shape_restores_operands
- expand_compound_shape_replaces_with_polygons
"""

from absl.testing import absltest

from document.document import Document, ElementSelection
from document.model import Model
from geometry.element import (
    Color, CompoundShape, Fill, Layer, Polygon, Rect,
)
from panels.boolean_apply import (
    apply_destructive_boolean,
    apply_expand_compound_shape,
    apply_make_compound_shape,
    apply_release_compound_shape,
)


def _rect(x, y, w=10, h=10):
    return Rect(x=x, y=y, width=w, height=h)


def _model_with_rects(rects, selected_paths):
    layer = Layer(children=tuple(rects))
    selection = frozenset(
        ElementSelection.all(tuple(p)) for p in selected_paths
    )
    doc = Document(layers=(layer,), selection=selection)
    return Model(document=doc)


class MakeCompoundShapeTest(absltest.TestCase):

    def test_wraps_selection_in_one_compound(self):
        rects = [_rect(0, 0), _rect(5, 0)]
        model = _model_with_rects(rects, [(0, 0), (0, 1)])
        apply_make_compound_shape(model)
        children = model.document.layers[0].children
        self.assertEqual(len(children), 1)
        self.assertIsInstance(children[0], CompoundShape)

    def test_selection_is_new_compound(self):
        rects = [_rect(0, 0), _rect(5, 0)]
        model = _model_with_rects(rects, [(0, 0), (0, 1)])
        apply_make_compound_shape(model)
        self.assertEqual(len(model.document.selection), 1)

    def test_less_than_two_is_noop(self):
        rects = [_rect(0, 0)]
        model = _model_with_rects(rects, [(0, 0)])
        apply_make_compound_shape(model)
        children = model.document.layers[0].children
        self.assertEqual(len(children), 1)
        self.assertIsInstance(children[0], Rect)


class ReleaseCompoundShapeTest(absltest.TestCase):

    def test_restores_operands(self):
        rects = [_rect(0, 0), _rect(5, 0)]
        model = _model_with_rects(rects, [(0, 0), (0, 1)])
        apply_make_compound_shape(model)
        apply_release_compound_shape(model)
        children = model.document.layers[0].children
        self.assertEqual(len(children), 2)
        self.assertIsInstance(children[0], Rect)
        self.assertIsInstance(children[1], Rect)

    def test_selection_is_released_operands(self):
        rects = [_rect(0, 0), _rect(5, 0)]
        model = _model_with_rects(rects, [(0, 0), (0, 1)])
        apply_make_compound_shape(model)
        apply_release_compound_shape(model)
        self.assertEqual(len(model.document.selection), 2)


class ExpandCompoundShapeTest(absltest.TestCase):

    def test_replaces_with_polygons(self):
        # Two overlapping 10x10 rects; Union evaluates to one merged
        # polygon. Expand emits one Polygon element.
        rects = [_rect(0, 0), _rect(5, 0)]
        model = _model_with_rects(rects, [(0, 0), (0, 1)])
        apply_make_compound_shape(model)
        apply_expand_compound_shape(model)
        children = model.document.layers[0].children
        self.assertEqual(len(children), 1)
        self.assertIsInstance(children[0], Polygon)


class DestructiveBooleanTest(absltest.TestCase):
    """Tests for the six implemented destructive ops."""

    def _two_overlapping(self):
        rects = [_rect(0, 0), _rect(5, 0)]
        return _model_with_rects(rects, [(0, 0), (0, 1)])

    def _count(self, model):
        return len(model.document.layers[0].children)

    def test_union_produces_one_polygon(self):
        m = self._two_overlapping()
        apply_destructive_boolean(m, "union")
        self.assertEqual(self._count(m), 1)
        self.assertIsInstance(m.document.layers[0].children[0], Polygon)

    def test_intersection_produces_one_polygon(self):
        m = self._two_overlapping()
        apply_destructive_boolean(m, "intersection")
        self.assertEqual(self._count(m), 1)

    def test_exclude_produces_two_polygons(self):
        m = self._two_overlapping()
        apply_destructive_boolean(m, "exclude")
        self.assertEqual(self._count(m), 2)

    def test_subtract_front_consumes_front(self):
        m = self._two_overlapping()
        apply_destructive_boolean(m, "subtract_front")
        self.assertEqual(self._count(m), 1)

    def test_subtract_back_consumes_back(self):
        m = self._two_overlapping()
        apply_destructive_boolean(m, "subtract_back")
        self.assertEqual(self._count(m), 1)

    def test_crop_uses_frontmost_as_mask(self):
        m = self._two_overlapping()
        apply_destructive_boolean(m, "crop")
        self.assertEqual(self._count(m), 1)

    def test_unknown_op_is_noop(self):
        m = self._two_overlapping()
        before = self._count(m)
        apply_destructive_boolean(m, "nonexistent")
        self.assertEqual(self._count(m), before)


class DivideTrimMergeTest(absltest.TestCase):
    """Tests for DIVIDE / TRIM / MERGE — phase 9e.

    DIVIDE splits the union into region pieces labeled by the
    frontmost covering operand. TRIM subtracts each operand's later
    operands from itself. MERGE runs TRIM then unions same-fill
    survivors (per BOOLEAN.md §Operand and paint rules)."""

    def _rect(self, x, y, w=10, h=10, fill=None):
        return Rect(x=x, y=y, width=w, height=h, fill=fill)

    def _fill(self, r, g, b):
        return Fill(color=Color.rgb(r, g, b))

    def _model(self, rects, selected):
        layer = Layer(children=tuple(rects))
        sel = frozenset(
            ElementSelection.all(tuple(p)) for p in selected
        )
        doc = Document(layers=(layer,), selection=sel)
        return Model(document=doc)

    def test_divide_two_overlapping_produces_three_fragments(self):
        # Back (0,0,10,10) and front (5,0,10,10): regions back-only,
        # overlap, front-only = 3 fragments.
        rects = [self._rect(0, 0), self._rect(5, 0)]
        m = self._model(rects, [(0, 0), (0, 1)])
        apply_destructive_boolean(m, "divide")
        self.assertEqual(len(m.document.layers[0].children), 3)
        for c in m.document.layers[0].children:
            self.assertIsInstance(c, Polygon)

    def test_divide_disjoint_keeps_two(self):
        rects = [self._rect(0, 0), self._rect(20, 0)]
        m = self._model(rects, [(0, 0), (0, 1)])
        apply_destructive_boolean(m, "divide")
        self.assertEqual(len(m.document.layers[0].children), 2)

    def test_trim_two_overlapping_keeps_two(self):
        # TRIM: back gets back-only region; front is untouched.
        rects = [self._rect(0, 0), self._rect(5, 0)]
        m = self._model(rects, [(0, 0), (0, 1)])
        apply_destructive_boolean(m, "trim")
        self.assertEqual(len(m.document.layers[0].children), 2)

    def test_trim_fully_covered_operand_vanishes(self):
        # Front fully covers back — back's trimmed region is empty.
        rects = [self._rect(0, 0), self._rect(0, 0, 20, 20)]
        m = self._model(rects, [(0, 0), (0, 1)])
        apply_destructive_boolean(m, "trim")
        # Only the front survives.
        self.assertEqual(len(m.document.layers[0].children), 1)

    def test_merge_matching_fills_combine(self):
        red = self._fill(1.0, 0.0, 0.0)
        # TRIM would produce back-only + front, both red → MERGE unions.
        rects = [self._rect(0, 0, fill=red), self._rect(5, 0, fill=red)]
        m = self._model(rects, [(0, 0), (0, 1)])
        apply_destructive_boolean(m, "merge")
        self.assertEqual(len(m.document.layers[0].children), 1)

    def test_merge_mismatched_fills_stay_separate(self):
        red = self._fill(1.0, 0.0, 0.0)
        blue = self._fill(0.0, 0.0, 1.0)
        rects = [self._rect(0, 0, fill=red), self._rect(5, 0, fill=blue)]
        m = self._model(rects, [(0, 0), (0, 1)])
        apply_destructive_boolean(m, "merge")
        self.assertEqual(len(m.document.layers[0].children), 2)

    def test_merge_none_fill_never_matches(self):
        # Both None → MERGE does not combine them.
        rects = [self._rect(0, 0), self._rect(5, 0)]
        m = self._model(rects, [(0, 0), (0, 1)])
        apply_destructive_boolean(m, "merge")
        self.assertEqual(len(m.document.layers[0].children), 2)


if __name__ == "__main__":
    absltest.main()
