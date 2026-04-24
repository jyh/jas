"""Phase 4a of the Python YAML tool-runtime migration. Covers
path_ops.py + regular_shapes.py — the shared geometry kernels."""

from __future__ import annotations

import math
import os
import sys

_JAS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _JAS_DIR not in sys.path:
    sys.path.insert(0, _JAS_DIR)
_REPO_ROOT = os.path.abspath(os.path.join(_JAS_DIR, ".."))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from geometry import path_ops, regular_shapes
from geometry.element import ClosePath, CurveTo, LineTo, MoveTo


def _close(a, b, tol=1e-9):
    return abs(a - b) < tol


# ── Basic helpers ────────────────────────────────────────


class TestBasic:
    def test_lerp_midpoint(self):
        assert path_ops.lerp(0.0, 10.0, 0.5) == 5.0
        assert path_ops.lerp(4.0, 8.0, 0.0) == 4.0
        assert path_ops.lerp(4.0, 8.0, 1.0) == 8.0

    def test_eval_cubic_endpoints(self):
        sx, sy = path_ops.eval_cubic(0, 0, 10, 0, 20, 0, 30, 0, 0)
        assert sx == 0.0 and sy == 0.0
        ex, ey = path_ops.eval_cubic(0, 0, 10, 0, 20, 0, 30, 0, 1)
        assert ex == 30.0 and ey == 0.0


# ── Endpoint / start-point ───────────────────────────────


class TestEndpoint:
    def test_cmd_endpoint_variants(self):
        assert path_ops.cmd_endpoint(MoveTo(1, 2)) == (1, 2)
        assert path_ops.cmd_endpoint(LineTo(3, 4)) == (3, 4)
        assert path_ops.cmd_endpoint(
            CurveTo(x1=0, y1=0, x2=0, y2=0, x=5, y=6)
        ) == (5, 6)

    def test_cmd_start_points_chain(self):
        cmds = [MoveTo(1, 1), LineTo(5, 1), LineTo(5, 5)]
        starts = path_ops.cmd_start_points(cmds)
        assert starts == [(0.0, 0.0), (1, 1), (5, 1)]


# ── Flattening ───────────────────────────────────────────


class TestFlatten:
    def test_flatten_line_segments(self):
        cmds = [MoveTo(0, 0), LineTo(10, 0), LineTo(10, 10)]
        pts, cmap = path_ops.flatten_with_cmd_map(cmds)
        assert len(pts) == 3
        assert cmap == [0, 1, 2]

    def test_flatten_curve_20_samples(self):
        cmds = [MoveTo(0, 0),
                CurveTo(x1=0, y1=10, x2=10, y2=10, x=10, y=0)]
        pts, cmap = path_ops.flatten_with_cmd_map(cmds)
        assert len(pts) == 21
        assert cmap.count(1) == 20


# ── Projection ───────────────────────────────────────────


class TestProjection:
    def test_closest_on_line_midpoint(self):
        d, t = path_ops.closest_on_line(0, 0, 10, 0, 5, 5)
        assert _close(d, 5.0)
        assert _close(t, 0.5)

    def test_closest_on_line_clamped(self):
        d, t = path_ops.closest_on_line(0, 0, 10, 0, -5, 0)
        assert _close(d, 5.0)
        assert t == 0.0

    def test_closest_segment_and_t_picks_correct(self):
        cmds = [MoveTo(0, 0), LineTo(10, 0), LineTo(10, 10)]
        r = path_ops.closest_segment_and_t(cmds, 10, 5)
        assert r is not None
        seg, t = r
        assert seg == 2
        assert _close(t, 0.5)


# ── Splitting ────────────────────────────────────────────


class TestSplit:
    def test_split_cubic_midpoint(self):
        first, second = path_ops.split_cubic(0, 0, 0, 10, 10, 10, 10, 0, 0.5)
        assert second[4] == 10 and second[5] == 0
        assert _close(first[4], 5.0)
        assert _close(first[5], 7.5)

    def test_split_cubic_cmd_at(self):
        a, b = path_ops.split_cubic_cmd_at((0, 0), 0, 10, 10, 10, 10, 0, 0.5)
        assert isinstance(a, CurveTo) and _close(a.x, 5.0) and _close(a.y, 7.5)
        assert isinstance(b, CurveTo) and b.x == 10 and b.y == 0


# ── Anchor deletion ──────────────────────────────────────


class TestDelete:
    def test_delete_interior_merges(self):
        cmds = [MoveTo(0, 0), LineTo(10, 0),
                LineTo(20, 0), LineTo(30, 0)]
        r = path_ops.delete_anchor_from_path(cmds, 1)
        assert r is not None
        assert len(r) == 3
        assert isinstance(r[1], LineTo) and r[1].x == 20

    def test_delete_first_promotes_second(self):
        cmds = [MoveTo(0, 0), LineTo(10, 0), LineTo(20, 0)]
        r = path_ops.delete_anchor_from_path(cmds, 0)
        assert r is not None
        assert isinstance(r[0], MoveTo) and r[0].x == 10

    def test_delete_two_anchor_returns_none(self):
        cmds = [MoveTo(0, 0), LineTo(10, 0)]
        assert path_ops.delete_anchor_from_path(cmds, 0) is None


# ── Anchor insertion ─────────────────────────────────────


class TestInsert:
    def test_insert_line_half(self):
        cmds = [MoveTo(0, 0), LineTo(10, 0)]
        r = path_ops.insert_point_in_path(cmds, 1, 0.5)
        assert len(r.commands) == 3
        assert r.anchor_x == 5 and r.anchor_y == 0
        assert r.first_new_idx == 1

    def test_insert_curve_split(self):
        cmds = [MoveTo(0, 0),
                CurveTo(x1=0, y1=10, x2=10, y2=10, x=10, y=0)]
        r = path_ops.insert_point_in_path(cmds, 1, 0.5)
        assert len(r.commands) == 3
        assert all(isinstance(r.commands[i], CurveTo) for i in (1, 2))
        assert _close(r.anchor_x, 5.0)
        assert _close(r.anchor_y, 7.5)


# ── Liang-Barsky ─────────────────────────────────────────


class TestLiangBarsky:
    def test_line_intersects_rect(self):
        assert path_ops.line_segment_intersects_rect(-1, 5, 20, 5, 0, 0, 10, 10)
        assert not path_ops.line_segment_intersects_rect(
            -5, -5, -1, -1, 0, 0, 10, 10)
        assert path_ops.line_segment_intersects_rect(5, 5, 20, 20, 0, 0, 10, 10)

    def test_entry_exit_parameters(self):
        t_min = path_ops.liang_barsky_t_min(-5, 5, 15, 5, 0, 0, 10, 10)
        t_max = path_ops.liang_barsky_t_max(-5, 5, 15, 5, 0, 0, 10, 10)
        assert _close(t_min, 0.25)
        assert _close(t_max, 0.75)


# ── Regular shapes ───────────────────────────────────────


class TestRegularShapes:
    def test_regular_polygon_triangle(self):
        pts = regular_shapes.regular_polygon_points(0, 0, 10, 0, 3)
        assert len(pts) == 3
        p2y = pts[2][1]
        assert _close(pts[0][0], 0) and _close(pts[0][1], 0)
        assert _close(pts[1][0], 10) and _close(pts[1][1], 0)
        assert abs(p2y - (10 * math.sqrt(3) / 2)) < 1e-6

    def test_regular_polygon_degenerate(self):
        pts = regular_shapes.regular_polygon_points(3, 4, 3, 4, 5)
        assert len(pts) == 5
        assert all((x, y) == (3, 4) for x, y in pts)

    def test_star_first_outer_at_top(self):
        pts = regular_shapes.star_points(0, 0, 100, 100, 5)
        assert len(pts) == 10
        assert _close(pts[0][0], 50.0)
        assert _close(pts[0][1], 0.0)

    def test_star_inner_ratio(self):
        assert regular_shapes.STAR_INNER_RATIO == 0.4


# Path to PolygonSet adapters — Blob Brush Phase 1.1.


class TestPolygonSetAdapters:
    def test_path_to_polygon_set_single_square(self):
        cmds = [
            MoveTo(0, 0),
            LineTo(10, 0),
            LineTo(10, 10),
            LineTo(0, 10),
            ClosePath(),
        ]
        ps = path_ops.path_to_polygon_set(cmds)
        assert len(ps) == 1
        assert len(ps[0]) == 4
        assert ps[0][0] == (0, 0)
        assert ps[0][2] == (10, 10)

    def test_path_to_polygon_set_multiple_subpaths(self):
        cmds = [
            MoveTo(0, 0), LineTo(10, 0), LineTo(5, 10), ClosePath(),
            MoveTo(20, 0), LineTo(30, 0), LineTo(25, 10), ClosePath(),
        ]
        ps = path_ops.path_to_polygon_set(cmds)
        assert len(ps) == 2
        assert len(ps[0]) == 3
        assert len(ps[1]) == 3
        assert ps[0][0] == (0, 0)
        assert ps[1][0] == (20, 0)

    def test_polygon_set_to_path_single_ring(self):
        ps = [[(0, 0), (10, 0), (10, 10), (0, 10)]]
        cmds = path_ops.polygon_set_to_path(ps)
        # 4-vertex ring -> MoveTo + 3 LineTo + ClosePath = 5 commands.
        assert len(cmds) == 5
        assert isinstance(cmds[0], MoveTo)
        assert cmds[0].x == 0 and cmds[0].y == 0
        assert isinstance(cmds[4], ClosePath)

    def test_polygon_set_to_path_drops_degenerate_rings(self):
        ps = [
            [(0, 0), (10, 0), (5, 10)],
            [(20, 0), (30, 0)],
        ]
        cmds = path_ops.polygon_set_to_path(ps)
        # Only the valid ring emits commands: MoveTo + 2 LineTo + Close.
        assert len(cmds) == 4

    def test_polygon_set_roundtrip_through_path(self):
        cmds = [
            MoveTo(0, 0),
            LineTo(10, 0),
            LineTo(10, 10),
            LineTo(0, 10),
            ClosePath(),
        ]
        ps1 = path_ops.path_to_polygon_set(cmds)
        cmds2 = path_ops.polygon_set_to_path(ps1)
        ps2 = path_ops.path_to_polygon_set(cmds2)
        assert ps1 == ps2
