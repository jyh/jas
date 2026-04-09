"""Tests for pane layout infrastructure."""

from workspace.pane import (
    PaneLayout, PaneKind, PaneConfig, EdgeSide, SnapConstraint,
    WindowTarget, PaneTarget,
    MIN_TOOLBAR_WIDTH, MIN_TOOLBAR_HEIGHT, MIN_CANVAS_WIDTH, MIN_CANVAS_HEIGHT,
    MIN_PANE_DOCK_WIDTH, MIN_PANE_DOCK_HEIGHT, DEFAULT_TOOLBAR_WIDTH,
    BORDER_HIT_TOLERANCE, MIN_PANE_VISIBLE,
)


# -- Initialization & lookup --

def test_default_three_pane_fills_viewport():
    pl = PaneLayout.default_three_pane(1000, 700)
    assert len(pl.panes) == 3
    t = pl.pane_by_kind(PaneKind.TOOLBAR)
    c = pl.pane_by_kind(PaneKind.CANVAS)
    d = pl.pane_by_kind(PaneKind.DOCK)
    assert t.x == 0
    assert t.width == DEFAULT_TOOLBAR_WIDTH
    assert abs(c.x - (t.x + t.width)) < 0.001
    assert abs(d.x - (c.x + c.width)) < 0.001
    assert abs(t.width + c.width + d.width - 1000) < 0.001
    assert t.height == 700
    assert c.height == 700
    assert d.height == 700

def test_default_three_pane_snap_count():
    pl = PaneLayout.default_three_pane(1000, 700)
    assert len(pl.snaps) == 10

def test_pane_lookup_by_id():
    pl = PaneLayout.default_three_pane(1000, 700)
    assert pl.find_pane(0) is not None
    assert pl.find_pane(1) is not None
    assert pl.find_pane(2) is not None

def test_pane_lookup_by_kind():
    pl = PaneLayout.default_three_pane(1000, 700)
    assert pl.pane_by_kind(PaneKind.TOOLBAR).kind == PaneKind.TOOLBAR
    assert pl.pane_by_kind(PaneKind.CANVAS).kind == PaneKind.CANVAS
    assert pl.pane_by_kind(PaneKind.DOCK).kind == PaneKind.DOCK

def test_pane_lookup_invalid_id():
    pl = PaneLayout.default_three_pane(1000, 700)
    assert pl.find_pane(99) is None

def test_pane_config_defaults():
    tc = PaneConfig.for_kind(PaneKind.TOOLBAR)
    assert tc.min_width == MIN_TOOLBAR_WIDTH
    assert tc.fixed_width
    assert tc.closable
    assert not tc.maximizable
    cc = PaneConfig.for_kind(PaneKind.CANVAS)
    assert cc.min_width == MIN_CANVAS_WIDTH
    assert not cc.fixed_width
    assert not cc.closable
    assert cc.maximizable
    dc = PaneConfig.for_kind(PaneKind.DOCK)
    assert dc.min_width == MIN_PANE_DOCK_WIDTH
    assert not dc.fixed_width
    assert dc.closable
    assert dc.collapsible
    # always_visible
    assert not tc.always_visible
    assert cc.always_visible
    assert not dc.always_visible
    # collapsed_width
    assert tc.collapsed_width is None
    assert cc.collapsed_width is None
    assert dc.collapsed_width == 36.0


# -- Position & sizing --

def test_set_pane_position_moves_pane():
    pl = PaneLayout.default_three_pane(1000, 700)
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    pl.set_pane_position(cid, 100, 50)
    p = pl.find_pane(cid)
    assert p.x == 100
    assert p.y == 50

def test_set_pane_position_clears_snaps():
    pl = PaneLayout.default_three_pane(1000, 700)
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    before = len(pl.snaps)
    assert before > 0
    pl.set_pane_position(cid, 200, 200)
    has = any(s.pane == cid or (isinstance(s.target, PaneTarget) and s.target.pane_id == cid) for s in pl.snaps)
    assert not has
    assert len(pl.snaps) < before

def test_resize_pane_clamps_min_toolbar():
    pl = PaneLayout.default_three_pane(1000, 700)
    tid = pl.pane_by_kind(PaneKind.TOOLBAR).id
    pl.resize_pane(tid, 10, 10)
    p = pl.find_pane(tid)
    assert p.width == MIN_TOOLBAR_WIDTH
    assert p.height == MIN_TOOLBAR_HEIGHT

def test_resize_pane_clamps_min_canvas():
    pl = PaneLayout.default_three_pane(1000, 700)
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    pl.resize_pane(cid, 10, 10)
    p = pl.find_pane(cid)
    assert p.width == MIN_CANVAS_WIDTH
    assert p.height == MIN_CANVAS_HEIGHT

def test_resize_pane_clamps_min_dock():
    pl = PaneLayout.default_three_pane(1000, 700)
    did = pl.pane_by_kind(PaneKind.DOCK).id
    pl.resize_pane(did, 10, 10)
    p = pl.find_pane(did)
    assert p.width == MIN_PANE_DOCK_WIDTH
    assert p.height == MIN_PANE_DOCK_HEIGHT

def test_resize_pane_accepts_large_values():
    pl = PaneLayout.default_three_pane(1000, 700)
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    pl.resize_pane(cid, 800, 600)
    p = pl.find_pane(cid)
    assert p.width == 800
    assert p.height == 600


# -- Snap detection --

def test_detect_snaps_near_window_edge():
    pl = PaneLayout.default_three_pane(1000, 700)
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    pl.set_pane_position(cid, 5, 0)
    snaps = pl.detect_snaps(cid, 1000, 700)
    assert any(s.pane == cid and s.edge == EdgeSide.LEFT and s.target == WindowTarget(EdgeSide.LEFT) for s in snaps)

def test_detect_snaps_near_other_pane():
    pl = PaneLayout.default_three_pane(1000, 700)
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    t = pl.pane_by_kind(PaneKind.TOOLBAR)
    tr = t.x + t.width
    tid = t.id
    pl.set_pane_position(cid, tr + 5, 0)
    snaps = pl.detect_snaps(cid, 1000, 700)
    assert any(s.pane == tid and s.edge == EdgeSide.RIGHT and s.target == PaneTarget(cid, EdgeSide.LEFT) for s in snaps)

def test_detect_snaps_no_match():
    pl = PaneLayout.default_three_pane(1000, 700)
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    pl.set_pane_position(cid, 400, 300)
    pl.resize_pane(cid, 200, 200)
    snaps = pl.detect_snaps(cid, 1000, 700)
    assert snaps == []


# -- Snap application --

def test_apply_snaps_aligns_position():
    pl = PaneLayout.default_three_pane(1000, 700)
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    pl.set_pane_position(cid, 5, 3)
    ns = [SnapConstraint(cid, EdgeSide.LEFT, WindowTarget(EdgeSide.LEFT)),
          SnapConstraint(cid, EdgeSide.TOP, WindowTarget(EdgeSide.TOP))]
    pl.apply_snaps(cid, ns, 1000, 700)
    p = pl.find_pane(cid)
    assert p.x == 0
    assert p.y == 0

def test_apply_snaps_aligns_via_normalized_pane_snap():
    pl = PaneLayout.default_three_pane(1000, 700)
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    tid = pl.pane_by_kind(PaneKind.TOOLBAR).id
    pl.set_pane_position(cid, 80, 0)
    ns = [SnapConstraint(tid, EdgeSide.RIGHT, PaneTarget(cid, EdgeSide.LEFT))]
    pl.apply_snaps(cid, ns, 1000, 700)
    assert abs(pl.find_pane(cid).x - 72) < 0.001

def test_drag_canvas_snap_to_toolbar_full_workflow():
    pl = PaneLayout.default_three_pane(1000, 700)
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    pl.set_pane_position(cid, 300, 100)
    assert all(s.pane != cid and not (isinstance(s.target, PaneTarget) and s.target.pane_id == cid) for s in pl.snaps)
    pl.set_pane_position(cid, 77, 0)
    snaps = pl.detect_snaps(cid, 1000, 700)
    assert any(s.edge == EdgeSide.RIGHT and isinstance(s.target, PaneTarget) and s.target.pane_id == cid and s.target.edge == EdgeSide.LEFT for s in snaps)
    pl.apply_snaps(cid, snaps, 1000, 700)
    assert abs(pl.find_pane(cid).x - 72) < 0.001
    assert pl.shared_border_at(72, 350, BORDER_HIT_TOLERANCE) is not None

def test_apply_snaps_replaces_old():
    pl = PaneLayout.default_three_pane(1000, 700)
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    old = len(pl.snaps)
    ns = [SnapConstraint(cid, EdgeSide.LEFT, WindowTarget(EdgeSide.LEFT))]
    pl.apply_snaps(cid, ns, 1000, 700)
    assert len(pl.snaps) < old
    assert any(s.pane == cid and s.edge == EdgeSide.LEFT for s in pl.snaps)

def test_align_to_snaps_does_not_modify_snap_list():
    pl = PaneLayout.default_three_pane(1000, 700)
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    tid = pl.pane_by_kind(PaneKind.TOOLBAR).id
    pl.set_pane_position(cid, 80, 5)
    before = len(pl.snaps)
    ns = [SnapConstraint(tid, EdgeSide.RIGHT, PaneTarget(cid, EdgeSide.LEFT)),
          SnapConstraint(cid, EdgeSide.TOP, WindowTarget(EdgeSide.TOP))]
    pl.align_to_snaps(cid, ns, 1000, 700)
    assert len(pl.snaps) == before
    p = pl.find_pane(cid)
    assert abs(p.x - 72) < 0.001
    assert p.y == 0


# -- Shared border --

def test_shared_border_at_vertical():
    pl = PaneLayout.default_three_pane(1000, 700)
    t = pl.pane_by_kind(PaneKind.TOOLBAR)
    bx = t.x + t.width
    result = pl.shared_border_at(bx, 350, BORDER_HIT_TOLERANCE)
    assert result is not None
    assert result[1] == EdgeSide.LEFT

def test_shared_border_at_miss():
    pl = PaneLayout.default_three_pane(1000, 700)
    assert pl.shared_border_at(500, 350, BORDER_HIT_TOLERANCE) is None

def test_drag_shared_border_widens_left_narrows_right():
    pl = PaneLayout.default_three_pane(1000, 700)
    c = pl.pane_by_kind(PaneKind.CANVAS)
    bx = c.x + c.width
    si, _ = pl.shared_border_at(bx, 350, BORDER_HIT_TOLERANCE)
    cw0 = pl.pane_by_kind(PaneKind.CANVAS).width
    dw0 = pl.pane_by_kind(PaneKind.DOCK).width
    dx0 = pl.pane_by_kind(PaneKind.DOCK).x
    pl.drag_shared_border(si, 30)
    assert abs(pl.pane_by_kind(PaneKind.CANVAS).width - (cw0 + 30)) < 0.001
    assert abs(pl.pane_by_kind(PaneKind.DOCK).width - (dw0 - 30)) < 0.001
    assert abs(pl.pane_by_kind(PaneKind.DOCK).x - (dx0 + 30)) < 0.001

def test_drag_shared_border_toolbar_is_fixed():
    pl = PaneLayout.default_three_pane(1000, 700)
    t = pl.pane_by_kind(PaneKind.TOOLBAR)
    bx = t.x + t.width
    result = pl.shared_border_at(bx, 350, BORDER_HIT_TOLERANCE)
    assert result is not None
    si, _ = result
    tw0 = pl.pane_by_kind(PaneKind.TOOLBAR).width
    pl.drag_shared_border(si, 30)
    assert abs(pl.pane_by_kind(PaneKind.TOOLBAR).width - tw0) < 0.001

def test_drag_shared_border_respects_min_size():
    pl = PaneLayout.default_three_pane(1000, 700)
    t = pl.pane_by_kind(PaneKind.TOOLBAR)
    bx = t.x + t.width
    si, _ = pl.shared_border_at(bx, 350, BORDER_HIT_TOLERANCE)
    pl.drag_shared_border(si, -5000)
    assert pl.pane_by_kind(PaneKind.TOOLBAR).width >= MIN_TOOLBAR_WIDTH

def test_drag_shared_border_propagates_to_chained_pane():
    pl = PaneLayout.default_three_pane(1000, 700)
    t = pl.pane_by_kind(PaneKind.TOOLBAR)
    bx = t.x + t.width
    si, _ = pl.shared_border_at(bx, 350, BORDER_HIT_TOLERANCE)
    pl.drag_shared_border(si, 30)
    c = pl.pane_by_kind(PaneKind.CANVAS)
    d = pl.pane_by_kind(PaneKind.DOCK)
    assert abs(c.x + c.width - d.x) < 0.001


# -- Z-order & visibility --

def test_bring_pane_to_front():
    pl = PaneLayout.default_three_pane(1000, 700)
    tid = pl.pane_by_kind(PaneKind.TOOLBAR).id
    did = pl.pane_by_kind(PaneKind.DOCK).id
    assert pl.z_order[-1] == did
    pl.bring_pane_to_front(tid)
    assert pl.z_order[-1] == tid

def test_pane_z_index_ordering():
    pl = PaneLayout.default_three_pane(1000, 700)
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    tid = pl.pane_by_kind(PaneKind.TOOLBAR).id
    did = pl.pane_by_kind(PaneKind.DOCK).id
    assert pl.pane_z_index(cid) < pl.pane_z_index(tid)
    assert pl.pane_z_index(tid) < pl.pane_z_index(did)

def test_hide_show_pane_round_trip():
    pl = PaneLayout.default_three_pane(1000, 700)
    assert pl.is_pane_visible(PaneKind.TOOLBAR)
    pl.hide_pane(PaneKind.TOOLBAR)
    assert not pl.is_pane_visible(PaneKind.TOOLBAR)
    pl.show_pane(PaneKind.TOOLBAR)
    assert pl.is_pane_visible(PaneKind.TOOLBAR)

def test_hide_pane_idempotent():
    pl = PaneLayout.default_three_pane(1000, 700)
    pl.hide_pane(PaneKind.DOCK)
    pl.hide_pane(PaneKind.DOCK)
    assert len(pl.hidden_panes) == 1

def test_show_pane_not_hidden_is_noop():
    pl = PaneLayout.default_three_pane(1000, 700)
    before = len(pl.hidden_panes)
    pl.show_pane(PaneKind.CANVAS)
    assert len(pl.hidden_panes) == before


# -- Viewport resize --

def test_on_viewport_resize_proportional():
    pl = PaneLayout.default_three_pane(1000, 700)
    cw0 = pl.pane_by_kind(PaneKind.CANVAS).width
    pl.on_viewport_resize(2000, 700)
    assert abs(pl.pane_by_kind(PaneKind.CANVAS).width - cw0 * 2) < 1

def test_on_viewport_resize_clamps_min():
    pl = PaneLayout.default_three_pane(1000, 700)
    pl.on_viewport_resize(100, 100)
    for p in pl.panes:
        assert p.width >= p.config.min_width
        assert p.height >= p.config.min_height


# -- Utilities --

def test_clamp_panes_offscreen():
    pl = PaneLayout.default_three_pane(1000, 700)
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    pl.set_pane_position(cid, 5000, 5000)
    pl.clamp_panes(1000, 700)
    p = pl.find_pane(cid)
    assert p.x <= 1000 - MIN_PANE_VISIBLE
    assert p.y <= 700 - MIN_PANE_VISIBLE

def test_toggle_canvas_maximized():
    pl = PaneLayout.default_three_pane(1000, 700)
    assert not pl.canvas_maximized
    pl.toggle_canvas_maximized()
    assert pl.canvas_maximized
    pl.toggle_canvas_maximized()
    assert not pl.canvas_maximized

def test_repair_snaps_adds_missing():
    pl = PaneLayout.default_three_pane(1000, 700)
    pl.snaps = []
    pl.repair_snaps(1000, 700)
    tid = pl.pane_by_kind(PaneKind.TOOLBAR).id
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    assert any(s.pane == tid and s.edge == EdgeSide.RIGHT and s.target == PaneTarget(cid, EdgeSide.LEFT) for s in pl.snaps)

def test_repair_snaps_no_duplicates():
    pl = PaneLayout.default_three_pane(1000, 700)
    before = len(pl.snaps)
    pl.repair_snaps(1000, 700)
    assert len(pl.snaps) == before


# -- Tiling --

def test_tile_panes_fills_viewport():
    pl = PaneLayout.default_three_pane(1000, 700)
    pl.tile_panes()
    t = pl.pane_by_kind(PaneKind.TOOLBAR)
    c = pl.pane_by_kind(PaneKind.CANVAS)
    d = pl.pane_by_kind(PaneKind.DOCK)
    assert t.x == 0
    assert abs(c.x - (t.x + t.width)) < 0.001
    assert abs(d.x - (c.x + c.width)) < 0.001
    assert abs(t.width + c.width + d.width - 1000) < 0.001
    assert t.height == 700 and c.height == 700 and d.height == 700
    assert t.width == DEFAULT_TOOLBAR_WIDTH

def test_tile_panes_collapsed_dock():
    pl = PaneLayout.default_three_pane(1000, 700)
    did = pl.pane_by_kind(PaneKind.DOCK).id
    pl.tile_panes((did, 36))
    d = pl.pane_by_kind(PaneKind.DOCK)
    c = pl.pane_by_kind(PaneKind.CANVAS)
    assert d.width == 36
    assert abs(c.width - (1000 - DEFAULT_TOOLBAR_WIDTH - 36)) < 0.001
    assert abs(d.x + d.width - 1000) < 0.001

def test_tile_panes_clears_hidden():
    pl = PaneLayout.default_three_pane(1000, 700)
    pl.hide_pane(PaneKind.TOOLBAR)
    pl.hide_pane(PaneKind.DOCK)
    assert len(pl.hidden_panes) == 2
    pl.tile_panes()
    assert pl.hidden_panes == []

def test_tile_panes_rebuilds_snaps():
    pl = PaneLayout.default_three_pane(1000, 700)
    pl.snaps = []
    pl.tile_panes()
    assert pl.snaps != []
    tid = pl.pane_by_kind(PaneKind.TOOLBAR).id
    cid = pl.pane_by_kind(PaneKind.CANVAS).id
    assert any(s.pane == tid and s.edge == EdgeSide.RIGHT and s.target == PaneTarget(cid, EdgeSide.LEFT) for s in pl.snaps)
