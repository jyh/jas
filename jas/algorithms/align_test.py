"""Tests for the Python Align algorithm primitives. Parallels the
Rust, Swift, and OCaml ports. Stage 5d covers primitives; the
six Align ops land in 5e, six Distribute in 5f, two Distribute
Spacing in 5g."""

from absl.testing import absltest

from algorithms.align import (
    AlignReference, AlignTranslation, Axis, AxisAnchor,
    anchor_position, axis_extent, geometric_bounds, preview_bounds,
    union_bounds,
)
from geometry.element import Rect


def _rect(x, y, w, h):
    return Rect(x=x, y=y, width=w, height=h)


class AlignPrimitivesTest(absltest.TestCase):

    def test_union_bounds_empty_returns_zero(self):
        self.assertEqual(union_bounds([], geometric_bounds), (0.0, 0.0, 0.0, 0.0))

    def test_union_bounds_single(self):
        self.assertEqual(
            union_bounds([_rect(10, 20, 30, 40)], geometric_bounds),
            (10, 20, 30, 40))

    def test_union_bounds_three_elements_spans_all(self):
        self.assertEqual(
            union_bounds([_rect(0, 0, 10, 10), _rect(20, 5, 10, 10),
                          _rect(40, 40, 20, 20)], geometric_bounds),
            (0, 0, 60, 60))

    def test_axis_extent_horizontal(self):
        lo, hi, mid = axis_extent((10, 20, 40, 60), Axis.HORIZONTAL)
        self.assertEqual((lo, hi, mid), (10, 50, 30))

    def test_axis_extent_vertical(self):
        lo, hi, mid = axis_extent((10, 20, 40, 60), Axis.VERTICAL)
        self.assertEqual((lo, hi, mid), (20, 80, 50))

    def test_anchor_position_min_center_max(self):
        b = (10, 20, 40, 60)
        self.assertEqual(anchor_position(b, Axis.HORIZONTAL, AxisAnchor.MIN), 10)
        self.assertEqual(anchor_position(b, Axis.HORIZONTAL, AxisAnchor.CENTER), 30)
        self.assertEqual(anchor_position(b, Axis.HORIZONTAL, AxisAnchor.MAX), 50)
        self.assertEqual(anchor_position(b, Axis.VERTICAL, AxisAnchor.MIN), 20)
        self.assertEqual(anchor_position(b, Axis.VERTICAL, AxisAnchor.CENTER), 50)
        self.assertEqual(anchor_position(b, Axis.VERTICAL, AxisAnchor.MAX), 80)

    def test_reference_bbox_unpacks_each_variant(self):
        b = (1.0, 2.0, 3.0, 4.0)
        self.assertEqual(AlignReference.selection(b).bbox, b)
        self.assertEqual(AlignReference.artboard(b).bbox, b)
        self.assertEqual(AlignReference.key_object(b, (0,)).bbox, b)

    def test_reference_key_path_only_for_key_object(self):
        b = (0.0, 0.0, 10.0, 10.0)
        self.assertIsNone(AlignReference.selection(b).key_path)
        self.assertIsNone(AlignReference.artboard(b).key_path)
        self.assertEqual(AlignReference.key_object(b, (0, 2)).key_path, (0, 2))

    def test_preview_bounds_matches_element_bounds(self):
        r = _rect(10, 20, 30, 40)
        self.assertEqual(preview_bounds(r), r.bounds())

    def test_geometric_bounds_matches_element_geometric_bounds(self):
        r = _rect(10, 20, 30, 40)
        self.assertEqual(geometric_bounds(r), r.geometric_bounds())

    def test_translation_record_is_hashable(self):
        t = AlignTranslation(path=(0, 1), dx=10, dy=20)
        self.assertEqual(t.path, (0, 1))


if __name__ == "__main__":
    absltest.main()
