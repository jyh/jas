"""Tests for pane rendering helpers."""

from workspace.pane import (
    PaneLayout, PaneKind, EdgeSide, SnapConstraint, WindowTarget,
    DEFAULT_TOOLBAR_WIDTH,
)
from canvas.pane_rendering import (
    compute_pane_geometries, compute_shared_borders, compute_snap_lines,
)


def test_geometries_from_default_layout():
    pl = PaneLayout.default_three_pane(1000, 700)
    geos = compute_pane_geometries(pl)
    assert len(geos) == 3
    assert all(g.visible for g in geos)


def test_geometries_pane_positions():
    pl = PaneLayout.default_three_pane(1000, 700)
    geos = compute_pane_geometries(pl)
    toolbar = next(g for g in geos if g.kind == PaneKind.TOOLBAR)
    canvas = next(g for g in geos if g.kind == PaneKind.CANVAS)
    dock = next(g for g in geos if g.kind == PaneKind.DOCK)
    assert toolbar.x == 0
    assert toolbar.width == DEFAULT_TOOLBAR_WIDTH
    assert abs(canvas.x - (toolbar.x + toolbar.width)) < 0.001
    assert abs(dock.x - (canvas.x + canvas.width)) < 0.001
    assert toolbar.height == 700
    assert canvas.height == 700
    assert dock.height == 700


def test_geometries_canvas_maximized():
    pl = PaneLayout.default_three_pane(1000, 700)
    pl.toggle_canvas_maximized()
    geos = compute_pane_geometries(pl)
    canvas = next(g for g in geos if g.kind == PaneKind.CANVAS)
    assert canvas.x == 0 and canvas.y == 0
    assert canvas.width == 1000 and canvas.height == 700
    assert canvas.z_index == 0


def test_geometries_hidden_pane():
    pl = PaneLayout.default_three_pane(1000, 700)
    pl.hide_pane(PaneKind.TOOLBAR)
    geos = compute_pane_geometries(pl)
    toolbar = next(g for g in geos if g.kind == PaneKind.TOOLBAR)
    assert not toolbar.visible
    canvas = next(g for g in geos if g.kind == PaneKind.CANVAS)
    assert canvas.visible


def test_geometries_z_order():
    pl = PaneLayout.default_three_pane(1000, 700)
    geos = compute_pane_geometries(pl)
    canvas = next(g for g in geos if g.kind == PaneKind.CANVAS)
    toolbar = next(g for g in geos if g.kind == PaneKind.TOOLBAR)
    dock = next(g for g in geos if g.kind == PaneKind.DOCK)
    assert canvas.z_index < toolbar.z_index < dock.z_index


def test_shared_borders_default():
    pl = PaneLayout.default_three_pane(1000, 700)
    borders = compute_shared_borders(pl)
    # toolbar-canvas and canvas-dock borders
    assert len(borders) == 2
    for b in borders:
        assert b.is_vertical
        assert b.height == 700


def test_no_borders_when_maximized():
    pl = PaneLayout.default_three_pane(1000, 700)
    pl.toggle_canvas_maximized()
    assert compute_shared_borders(pl) == []


def test_snap_lines_computation():
    pl = PaneLayout.default_three_pane(1000, 700)
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    preview = [
        SnapConstraint(cid, EdgeSide.LEFT, WindowTarget(EdgeSide.LEFT)),
        SnapConstraint(cid, EdgeSide.TOP, WindowTarget(EdgeSide.TOP)),
    ]
    lines = compute_snap_lines(preview, pl)
    assert len(lines) == 2
    assert any(l.width == 4 and l.height > 4 for l in lines)


def test_geometries_from_none():
    assert compute_pane_geometries(None) == []
