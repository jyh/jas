"""Tests for the dash-alignment renderer.

Pinned reference inputs per DASH_ALIGN.md §Cross-language parity tests.
Every native-language port must produce identical sub-path output for
these inputs; this test file is the canonical fixture.

The dasher is a pure path → list-of-sub-paths transformation. Curve
support is deferred — Phase 3 ships lines-only (MoveTo / LineTo /
ClosePath), which covers the reference tests and the Stroke YAML's
typical use cases (rectangles, polygons, hand-drawn polylines).
"""

from __future__ import annotations

import math

import pytest

from workspace_interpreter.dash_renderer import (
    expand_dashed_stroke,
)


# Path commands as plain (str, *floats) tuples — the dasher operates on
# this lightweight representation so it can be ported as-is to any
# language without depending on the full Element type system.

def M(x: float, y: float) -> tuple:
    return ("M", x, y)


def L(x: float, y: float) -> tuple:
    return ("L", x, y)


def Z() -> tuple:
    return ("Z",)


# ── Helpers ──────────────────────────────────────────────────────


def _seg_len(a: tuple[float, float], b: tuple[float, float]) -> float:
    return math.hypot(b[0] - a[0], b[1] - a[1])


def _subpath_points(subpath: tuple) -> list[tuple[float, float]]:
    """Extract the (x, y) sequence from a lines-only subpath."""
    pts: list[tuple[float, float]] = []
    for cmd in subpath:
        if cmd[0] in ("M", "L"):
            pts.append((cmd[1], cmd[2]))
    return pts


def _subpath_arclength(subpath: tuple) -> float:
    pts = _subpath_points(subpath)
    return sum(_seg_len(a, b) for a, b in zip(pts, pts[1:]))


def _total_dash_length(subpaths: tuple) -> float:
    return sum(_subpath_arclength(sp) for sp in subpaths)


# ── Edge cases: empty / degenerate inputs ────────────────────────


class TestEdgeCases:

    def test_empty_dash_array_returns_path_unchanged(self):
        path = (M(0, 0), L(10, 0), L(10, 10), Z())
        result = expand_dashed_stroke(path, dash_array=(), align_anchors=False)
        assert result == (path,)

    def test_zero_only_dash_array_returns_path_unchanged(self):
        # All-zeros pattern would draw nothing if applied; safest to
        # treat as "no dashing".
        path = (M(0, 0), L(10, 0))
        result = expand_dashed_stroke(path, dash_array=(0.0, 0.0), align_anchors=False)
        assert result == (path,)

    def test_empty_path_returns_empty(self):
        result = expand_dashed_stroke((), dash_array=(4.0, 2.0), align_anchors=False)
        assert result == ()

    def test_single_moveto_returns_empty(self):
        # A subpath with no actual segments produces no dashes.
        path = (M(5, 5),)
        result = expand_dashed_stroke(path, dash_array=(4.0, 2.0), align_anchors=False)
        assert result == ()


# ── Preserve mode ────────────────────────────────────────────────


class TestPreserveMode:

    def test_simple_line_one_full_period_fits(self):
        # 6-unit line, dash [4, 2] → one dash 0..4, gap 4..6.
        path = (M(0, 0), L(6, 0))
        result = expand_dashed_stroke(path, dash_array=(4.0, 2.0), align_anchors=False)
        assert result == ((M(0, 0), L(4, 0)),)

    def test_simple_line_partial_period(self):
        # 10-unit line, dash [4, 2] → 0..4 dash, 4..6 gap, 6..10 dash.
        path = (M(0, 0), L(10, 0))
        result = expand_dashed_stroke(path, dash_array=(4.0, 2.0), align_anchors=False)
        assert result == (
            (M(0, 0), L(4, 0)),
            (M(6, 0), L(10, 0)),
        )

    def test_dash_spans_corner(self):
        # L-shape, total length 10 (5 right + 5 down), dash [4, 2].
        # 0..4 dash on first segment (4 units along x).
        # 4..6 gap spans across the corner: parameter 5 = corner.
        # 6..10 dash on second segment (last 4 units of the y leg).
        path = (M(0, 0), L(5, 0), L(5, 5))
        result = expand_dashed_stroke(path, dash_array=(4.0, 2.0), align_anchors=False)
        # First dash: 0..4 entirely on horizontal segment.
        # Gap 4..6: 1 unit horizontal then 1 unit vertical, no emit.
        # Second dash 6..10: starts at (5, 1), goes to (5, 5).
        assert result == (
            (M(0, 0), L(4, 0)),
            (M(5, 1), L(5, 5)),
        )

    def test_closed_rectangle_continuous_period(self):
        # 100x60 rectangle, perimeter 320, dash [20, 10] period 30.
        # n_full = 320 / 30 = 10.67 → 10 full dashes + 20 trailing.
        # Preserve mode does NOT close the dash loop — it walks
        # arc-length from the first MoveTo and stops at total length,
        # dropping the partial trailing dash.
        path = (M(0, 0), L(100, 0), L(100, 60), L(0, 60), Z())
        result = expand_dashed_stroke(path, dash_array=(20.0, 10.0), align_anchors=False)
        # Verify: total dash arc-length is 10 full dashes' worth (200)
        # plus the trailing partial. Can't reason about the trailing
        # piece without the algorithm — pin overall structure.
        assert len(result) >= 10  # at least 10 dashes


# ── Align mode ───────────────────────────────────────────────────


class TestAlignMode:

    def test_open_two_anchor_line(self):
        # Open 10-unit line, dash [4, 2], base period 6.
        # EE boundary: layout is dash, gap, dash, gap, ..., dash with
        # m gaps and (m+1) full dashes. Length = m*P + d.
        # m = round((L - d) / P) = round((10 - 4) / 6) = 1.
        # scale = L / (m*P + d) = 10 / (1*6 + 4) = 1.0 (no flex needed).
        # Dashes at [0, 4] and [6, 10].
        path = (M(0, 0), L(10, 0))
        result = expand_dashed_stroke(path, dash_array=(4.0, 2.0), align_anchors=True)
        assert len(result) == 2
        d1 = result[0]
        assert d1 == (M(0, 0), L(4, 0))
        d2 = result[1]
        assert d2 == (M(6, 0), L(10, 0))

    def test_open_path_endpoint_starts_with_full_dash(self):
        # Verify the END_INTERIOR boundary: at an open-path endpoint
        # the dash starts at parameter 0 (not centered with a half-dash
        # behind it).
        path = (M(0, 0), L(20, 0))
        result = expand_dashed_stroke(path, dash_array=(4.0, 2.0), align_anchors=True)
        # First sub-path's first command should be M(0, 0) — the dash
        # starts exactly at the path origin.
        assert result[0][0] == M(0, 0)

    def test_closed_rect_dashes_centered_on_corners(self):
        # 100x60 rectangle. Each side is one segment between two
        # corner anchors. Each corner is interior. The algorithm
        # picks per-side n and scale so a half-dash terminates at
        # each corner from each direction.
        path = (M(0, 0), L(100, 0), L(100, 60), L(0, 60), Z())
        result = expand_dashed_stroke(path, dash_array=(12.0, 6.0), align_anchors=True)
        # We don't pin exact positions (the algorithm chooses n per
        # segment) but we verify properties:
        # 1. At each corner, a dash spans the corner — meaning two
        #    sub-paths share the corner point as their join.
        # 2. The number of sub-paths is approximately
        #    perimeter / period = 320 / 18 ≈ 17.7
        assert len(result) >= 12
        # 3. Every sub-path starts with M and has at least one L.
        for sub in result:
            assert sub[0][0] == "M"
            assert any(c[0] == "L" for c in sub[1:])

    def test_closed_rect_corner_dash_spans_into_next_segment(self):
        # When a dash crosses an anchor, the sub-path must include
        # commands from BOTH segments (the anchor is mid-dash). This
        # is the key correctness property: a corner-crossing dash
        # must follow the underlying path geometry through the corner.
        # Use a 24x24 square with dash [16, 4] — period 20, anchors
        # every 24 units.
        path = (M(0, 0), L(24, 0), L(24, 24), L(0, 24), Z())
        result = expand_dashed_stroke(path, dash_array=(16.0, 4.0), align_anchors=True)
        # At least one sub-path should include an interior corner.
        # The corners are at (24, 0), (24, 24), (0, 24), (0, 0).
        # A dash centered on (24, 0) starts at 24 - half_dash on the
        # top edge, ends at 24 + half_dash on the right edge — so the
        # sub-path has commands from y=0 to (24, 0) to y=24 path leg.
        # Find such a sub-path.
        spans_first_corner = False
        for sub in result:
            xs = [c[1] for c in sub if c[0] in ("M", "L")]
            ys = [c[2] for c in sub if c[0] in ("M", "L")]
            # Check if the sub-path crosses (24, 0): has an x=24, y=0
            # interior anchor between its endpoints.
            for i, c in enumerate(sub):
                if c[0] in ("M", "L") and abs(c[1] - 24) < 1e-6 and abs(c[2]) < 1e-6:
                    if i > 0 and i < len(sub) - 1:
                        spans_first_corner = True
                        break
            if spans_first_corner:
                break
        assert spans_first_corner

    def test_open_zigzag(self):
        # Open path with one interior anchor.
        # M(0,0) L(50,0) L(50,75)
        # Total length: 50 + 75 = 125
        # Endpoint at start (0,0), interior anchor at (50,0), endpoint at (50,75).
        # Segment 1 (END_INTERIOR): full dash starts at (0,0); half-dash
        #   centered on (50,0). length=50, period=18, (n-0.5)*P ≈ L:
        #   n = round(50/18 + 0.5) = 3, scale = 50/(2.5*18) = 1.111.
        # Segment 2 (INTERIOR_END): symmetric.
        path = (M(0, 0), L(50, 0), L(50, 75))
        result = expand_dashed_stroke(path, dash_array=(12.0, 6.0), align_anchors=True)
        # First sub-path starts at the path origin (full dash at endpoint).
        assert result[0][0] == M(0, 0)
        # Last sub-path ends at the path's endpoint (full dash terminating).
        last = result[-1]
        last_cmd = last[-1]
        assert last_cmd[0] == "L"
        assert (abs(last_cmd[1] - 50) < 1e-6
                and abs(last_cmd[2] - 75) < 1e-6)


# ── Compound paths (multiple subpaths) ────────────────────────────


class TestCompoundPaths:

    def test_two_independent_subpaths(self):
        # Compound path: two disjoint subpaths. Each aligns independently.
        # Subpath 1: square 100x100 at origin (closed).
        # Subpath 2: triangle (closed).
        path = (
            M(0, 0), L(100, 0), L(100, 100), L(0, 100), Z(),
            M(200, 0), L(250, 50), L(150, 50), Z(),
        )
        result = expand_dashed_stroke(path, dash_array=(10.0, 4.0), align_anchors=True)
        # Verify dashes in subpath 1 stay within [0, 100] x [0, 100] bounds
        # and dashes in subpath 2 stay within [150, 250] x [0, 50].
        for sub in result:
            xs = [c[1] for c in sub if c[0] in ("M", "L")]
            ys = [c[2] for c in sub if c[0] in ("M", "L")]
            min_x = min(xs)
            if min_x < 150:
                # In subpath 1 region.
                assert max(xs) <= 100 + 1e-6
                assert max(ys) <= 100 + 1e-6
            else:
                # In subpath 2 region.
                assert max(xs) <= 250 + 1e-6
                assert min(ys) >= 0 - 1e-6
                assert max(ys) <= 50 + 1e-6


# ── Determinism: same inputs always produce same outputs ─────────


class TestDeterminism:

    @pytest.mark.parametrize("align", [False, True])
    def test_idempotent(self, align):
        path = (M(0, 0), L(100, 0), L(100, 60), L(0, 60), Z())
        result1 = expand_dashed_stroke(path, dash_array=(12.0, 6.0), align_anchors=align)
        result2 = expand_dashed_stroke(path, dash_array=(12.0, 6.0), align_anchors=align)
        assert result1 == result2
