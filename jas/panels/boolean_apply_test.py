"""Tests for panels.boolean_apply — compound-shape menu dispatch.

Mirrors jas_dioxus/src/document/controller.rs:
- make_compound_shape_wraps_selection_in_one_live_element
- release_compound_shape_restores_operands
- expand_compound_shape_replaces_with_polygons
"""

from absl.testing import absltest

from document.document import Document, ElementSelection
from document.model import Model
from geometry.element import CompoundShape, Layer, Polygon, Rect
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


if __name__ == "__main__":
    absltest.main()
