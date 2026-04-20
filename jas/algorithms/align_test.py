"""Tests for the Python Align algorithm primitives. Parallels the
Rust, Swift, and OCaml ports. Stage 5d covers primitives; the
six Align ops land in 5e, six Distribute in 5f, two Distribute
Spacing in 5g."""

from absl.testing import absltest

from algorithms.align import (
    AlignReference, AlignTranslation, Axis, AxisAnchor,
    align_bottom, align_horizontal_center, align_left, align_right,
    align_top, align_vertical_center,
    anchor_position, axis_extent,
    distribute_bottom, distribute_horizontal_center, distribute_left,
    distribute_right, distribute_top, distribute_vertical_center,
    geometric_bounds, preview_bounds,
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


class AlignOpsTest(absltest.TestCase):
    """Stage 5e — six Align operations. Parallels the Rust /
    Swift / OCaml port tests."""

    def _three_rects(self):
        return [_rect(10, 0, 10, 10), _rect(30, 0, 10, 10), _rect(60, 0, 10, 10)]

    def _ref_selection_of(self, rs):
        return AlignReference.selection(union_bounds(rs, geometric_bounds))

    def _input(self, rs):
        return [((i,), r) for i, r in enumerate(rs)]

    def test_align_left_moves_two_rects_to_left_edge(self):
        rs = self._three_rects()
        out = align_left(self._input(rs), self._ref_selection_of(rs), geometric_bounds)
        self.assertEqual(len(out), 2)
        self.assertEqual(out[0], AlignTranslation(path=(1,), dx=-20, dy=0))
        self.assertEqual(out[1], AlignTranslation(path=(2,), dx=-50, dy=0))

    def test_align_right_moves_to_right_edge(self):
        rs = self._three_rects()
        out = align_right(self._input(rs), self._ref_selection_of(rs), geometric_bounds)
        # Target = 70. rs[0] 20 → Δ+50. rs[1] 40 → Δ+30. rs[2] at 70 omitted.
        self.assertEqual(len(out), 2)
        self.assertEqual(out[0].dx, 50)
        self.assertEqual(out[1].dx, 30)

    def test_align_horizontal_center_moves_to_midpoint(self):
        rs = self._three_rects()
        out = align_horizontal_center(self._input(rs), self._ref_selection_of(rs), geometric_bounds)
        # Target = 40. Centers 15, 35, 65 → Δ+25, +5, -25.
        self.assertEqual(len(out), 3)
        self.assertEqual(out[0].dx, 25)
        self.assertEqual(out[1].dx, 5)
        self.assertEqual(out[2].dx, -25)

    def test_align_top_only_affects_y(self):
        rs = [_rect(0, 10, 10, 10), _rect(20, 30, 10, 10), _rect(40, 50, 10, 10)]
        out = align_top(self._input(rs), self._ref_selection_of(rs), geometric_bounds)
        for t in out:
            self.assertEqual(t.dx, 0)
        self.assertEqual(len(out), 2)  # first already at top

    def test_align_vertical_center_moves_to_midline(self):
        rs = [_rect(0, 0, 10, 10), _rect(20, 20, 10, 10)]
        out = align_vertical_center(self._input(rs), self._ref_selection_of(rs), geometric_bounds)
        # Target = 15. Centers 5, 25 → Δ+10, -10.
        self.assertEqual(len(out), 2)
        self.assertEqual(out[0].dy, 10)
        self.assertEqual(out[1].dy, -10)

    def test_align_bottom_moves_to_bottom_edge(self):
        rs = [_rect(0, 0, 10, 20), _rect(20, 0, 10, 10)]
        out = align_bottom(self._input(rs), self._ref_selection_of(rs), geometric_bounds)
        # Target = 20. rs[0] omitted; rs[1] bottom 10 → Δ+10.
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0].path, (1,))
        self.assertEqual(out[0].dy, 10)

    def test_align_left_with_key_object_does_not_move_key(self):
        rs = self._three_rects()
        key_path = (1,)
        r = AlignReference.key_object(rs[1].geometric_bounds(), key_path)
        out = align_left(self._input(rs), r, geometric_bounds)
        for t in out:
            self.assertNotEqual(t.path, key_path)
        # rs[0] 10 → 30 Δ+20; rs[2] 60 → 30 Δ-30.
        self.assertEqual(len(out), 2)
        self.assertEqual(out[0], AlignTranslation(path=(0,), dx=20, dy=0))
        self.assertEqual(out[1], AlignTranslation(path=(2,), dx=-30, dy=0))

    def test_align_left_empty_input_yields_empty_output(self):
        r = AlignReference.selection((0, 0, 10, 10))
        self.assertEqual(align_left([], r, geometric_bounds), [])


class DistributeOpsTest(absltest.TestCase):
    """Stage 5f — six Distribute operations. Parallels the Rust /
    Swift / OCaml port tests."""

    def _ref_selection_of(self, rs):
        return AlignReference.selection(union_bounds(rs, geometric_bounds))

    def _input(self, rs):
        return [((i,), r) for i, r in enumerate(rs)]

    def test_distribute_requires_at_least_three_elements(self):
        rs = [_rect(0, 0, 10, 10), _rect(50, 0, 10, 10)]
        out = distribute_left(self._input(rs), self._ref_selection_of(rs), geometric_bounds)
        self.assertEqual(out, [])

    def test_distribute_left_already_even_emits_no_translations(self):
        rs = [_rect(0, 0, 10, 10), _rect(50, 0, 10, 10), _rect(100, 0, 10, 10)]
        out = distribute_left(self._input(rs), self._ref_selection_of(rs), geometric_bounds)
        self.assertEqual(out, [])

    def test_distribute_left_uneven_moves_middle_to_center(self):
        rs = [_rect(0, 0, 10, 10), _rect(30, 0, 10, 10), _rect(100, 0, 10, 10)]
        out = distribute_left(self._input(rs), self._ref_selection_of(rs), geometric_bounds)
        # Span [0, 100]; middle target left = 50; Δ = +20.
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0], AlignTranslation(path=(1,), dx=20, dy=0))

    def test_distribute_horizontal_center_evenly_spaces_centers(self):
        rs = [_rect(0, 0, 10, 10), _rect(20, 0, 10, 10), _rect(100, 0, 10, 10)]
        out = distribute_horizontal_center(self._input(rs), self._ref_selection_of(rs), geometric_bounds)
        # Center span [5, 105]; middle target = 55; Δ = +30.
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0].path, (1,))
        self.assertEqual(out[0].dx, 30)

    def test_distribute_right_distributes_right_edges(self):
        rs = [_rect(0, 0, 10, 10), _rect(20, 0, 10, 10), _rect(100, 0, 10, 10)]
        out = distribute_right(self._input(rs), self._ref_selection_of(rs), geometric_bounds)
        # Right-edge span [10, 110]; middle target = 60; Δ = +30.
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0].path, (1,))
        self.assertEqual(out[0].dx, 30)

    def test_distribute_top_moves_only_y(self):
        rs = [_rect(0, 0, 10, 10), _rect(5, 30, 10, 10), _rect(10, 100, 10, 10)]
        out = distribute_top(self._input(rs), self._ref_selection_of(rs), geometric_bounds)
        # Top-edge span [0, 100]; middle target = 50; Δ = +20.
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0].path, (1,))
        self.assertEqual(out[0].dx, 0)
        self.assertEqual(out[0].dy, 20)

    def test_distribute_bottom_moves_only_y(self):
        rs = [_rect(0, 0, 10, 10), _rect(5, 30, 10, 10), _rect(10, 100, 10, 10)]
        out = distribute_bottom(self._input(rs), self._ref_selection_of(rs), geometric_bounds)
        # Bottom-edge span [10, 110]; middle target = 60; Δ = +20.
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0].path, (1,))
        self.assertEqual(out[0].dy, 20)

    def test_distribute_vertical_center_with_key_skips_key(self):
        rs = [_rect(0, 0, 10, 10), _rect(0, 30, 10, 10), _rect(0, 100, 10, 10)]
        key_path = (1,)
        r = AlignReference.key_object(rs[1].geometric_bounds(), key_path)
        out = distribute_vertical_center(self._input(rs), r, geometric_bounds)
        for t in out:
            self.assertNotEqual(t.path, key_path)

    def test_distribute_handles_unsorted_input(self):
        # Input in reverse order — algorithm sorts internally.
        rs = [_rect(100, 0, 10, 10), _rect(30, 0, 10, 10), _rect(0, 0, 10, 10)]
        out = distribute_left(self._input(rs), self._ref_selection_of(rs), geometric_bounds)
        # Span [0, 100]; middle element (rs[1], x=30) → target 50; Δ = +20.
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0].path, (1,))
        self.assertEqual(out[0].dx, 20)

    def test_distribute_artboard_reference_uses_artboard_extent(self):
        rs = [_rect(20, 0, 10, 10), _rect(40, 0, 10, 10), _rect(60, 0, 10, 10)]
        r = AlignReference.artboard((0, 0, 200, 100))
        out = distribute_left(self._input(rs), r, geometric_bounds)
        # Span = artboard [0, 200]. Targets 0, 100, 200; deltas -20, +60, +140.
        self.assertEqual(len(out), 3)
        self.assertEqual(out[0].dx, -20)
        self.assertEqual(out[1].dx, 60)
        self.assertEqual(out[2].dx, 140)


if __name__ == "__main__":
    absltest.main()
