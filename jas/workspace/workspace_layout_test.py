"""Tests for dock/panel infrastructure."""

from workspace.workspace_layout import (
    WorkspaceLayout, DockEdge, PanelKind, PanelGroup, GroupAddr, PanelAddr,
    AppConfig, MIN_DOCK_WIDTH, MAX_DOCK_WIDTH, MIN_GROUP_HEIGHT,
    DEFAULT_DOCK_WIDTH, DEFAULT_LAYOUT_NAME,
)


def _rid(l):
    return l.anchored_dock(DockEdge.RIGHT).id

def _ga(did, gi):
    return GroupAddr(dock_id=did, group_idx=gi)

def _pa(did, gi, pi):
    return PanelAddr(group=_ga(did, gi), panel_idx=pi)


# -- Layout & lookup --

def test_default_layout_one_anchored_right():
    l = WorkspaceLayout.default_layout()
    assert len(l.anchored) == 1
    assert l.anchored[0][0] == DockEdge.RIGHT
    assert l.floating == []

def test_default_layout_two_groups():
    l = WorkspaceLayout.default_layout()
    d = l.anchored_dock(DockEdge.RIGHT)
    assert len(d.groups) == 2
    assert d.groups[0].panels == [PanelKind.LAYERS]
    assert d.groups[1].panels == [PanelKind.COLOR, PanelKind.STROKE, PanelKind.PROPERTIES]

def test_default_not_collapsed():
    l = WorkspaceLayout.default_layout()
    d = l.anchored_dock(DockEdge.RIGHT)
    assert not d.collapsed
    for g in d.groups:
        assert not g.collapsed

def test_default_dock_width():
    l = WorkspaceLayout.default_layout()
    assert l.anchored_dock(DockEdge.RIGHT).width == DEFAULT_DOCK_WIDTH

def test_dock_lookup_anchored():
    l = WorkspaceLayout.default_layout()
    assert l.dock(_rid(l)) is not None

def test_dock_lookup_floating():
    l = WorkspaceLayout.default_layout()
    fid = l.detach_group(_ga(_rid(l), 0), 100, 100)
    assert l.dock(fid) is not None
    assert l.floating_dock(fid) is not None

def test_dock_lookup_invalid():
    l = WorkspaceLayout.default_layout()
    assert l.dock(99) is None

def test_anchored_dock_by_edge():
    l = WorkspaceLayout.default_layout()
    assert l.anchored_dock(DockEdge.RIGHT) is not None
    assert l.anchored_dock(DockEdge.LEFT) is None
    assert l.anchored_dock(DockEdge.BOTTOM) is None

# -- Toggle / active --

def test_toggle_dock_collapsed():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    assert not l.dock(id).collapsed
    l.toggle_dock_collapsed(id)
    assert l.dock(id).collapsed
    l.toggle_dock_collapsed(id)
    assert not l.dock(id).collapsed

def test_toggle_group_collapsed():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.toggle_group_collapsed(_ga(id, 0))
    assert l.dock(id).groups[0].collapsed
    assert not l.dock(id).groups[1].collapsed
    l.toggle_group_collapsed(_ga(id, 0))
    assert not l.dock(id).groups[0].collapsed

def test_toggle_group_out_of_bounds():
    l = WorkspaceLayout.default_layout()
    l.toggle_group_collapsed(_ga(0, 99))
    l.toggle_group_collapsed(_ga(99, 0))

def test_set_active_panel():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.set_active_panel(_pa(id, 1, 2))
    assert l.dock(id).groups[1].active == 2

def test_set_active_panel_out_of_bounds():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.set_active_panel(_pa(id, 1, 99))
    assert l.dock(id).groups[1].active == 0
    l.set_active_panel(_pa(id, 99, 0))
    l.set_active_panel(_pa(99, 0, 0))

# -- Move group within dock --

def test_move_group_forward():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.move_group_within_dock(id, 0, 1)
    assert l.dock(id).groups[0].panels == [PanelKind.COLOR, PanelKind.STROKE, PanelKind.PROPERTIES]
    assert l.dock(id).groups[1].panels == [PanelKind.LAYERS]

def test_move_group_backward():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.move_group_within_dock(id, 1, 0)
    assert l.dock(id).groups[0].panels == [PanelKind.COLOR, PanelKind.STROKE, PanelKind.PROPERTIES]

def test_move_group_same_position():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.move_group_within_dock(id, 0, 0)
    assert l.dock(id).groups[0].panels == [PanelKind.LAYERS]

def test_move_group_clamped():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.move_group_within_dock(id, 0, 99)
    assert l.dock(id).groups[1].panels == [PanelKind.LAYERS]

def test_move_group_out_of_bounds():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.move_group_within_dock(id, 99, 0)
    assert len(l.dock(id).groups) == 2

def test_move_group_preserves_state():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.dock(id).groups[1].active = 2
    l.dock(id).groups[1].collapsed = True
    l.move_group_within_dock(id, 1, 0)
    assert l.dock(id).groups[0].active == 2
    assert l.dock(id).groups[0].collapsed

# -- Move group between docks --

def test_move_group_between_docks():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    fid = l.detach_group(_ga(id, 0), 50, 50)
    l.move_group_to_dock(_ga(id, 0), fid, 1)
    assert len(l.dock(id).groups) == 0
    assert len(l.dock(fid).groups) == 2

def test_move_group_inserts_at_position():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    f1 = l.detach_group(_ga(id, 0), 10, 10)
    f2 = l.detach_group(_ga(id, 0), 20, 20)
    l.move_group_to_dock(_ga(f1, 0), f2, 0)
    assert l.dock(f2).groups[0].panels == [PanelKind.LAYERS]
    assert l.dock(f1) is None

def test_move_group_same_dock_is_reorder():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.move_group_to_dock(_ga(id, 0), id, 1)
    assert l.dock(id).groups[0].panels == [PanelKind.COLOR, PanelKind.STROKE, PanelKind.PROPERTIES]
    assert l.dock(id).groups[1].panels == [PanelKind.LAYERS]

def test_move_group_invalid_source():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.move_group_to_dock(_ga(id, 99), id, 0)
    assert len(l.dock(id).groups) == 2

def test_move_group_invalid_target():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.move_group_to_dock(_ga(id, 0), 99, 0)
    assert len(l.dock(id).groups) == 2

# -- Detach group --

def test_detach_group_creates_floating():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    fid = l.detach_group(_ga(id, 0), 100, 200)
    assert fid is not None
    assert l.dock(fid).groups[0].panels == [PanelKind.LAYERS]
    assert len(l.dock(id).groups) == 1

def test_detach_group_position():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    fid = l.detach_group(_ga(id, 0), 100, 200)
    fd = l.floating_dock(fid)
    assert fd.x == 100
    assert fd.y == 200

def test_detach_group_unique_ids():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    f1 = l.detach_group(_ga(id, 0), 10, 10)
    f2 = l.detach_group(_ga(id, 0), 20, 20)
    assert f1 != f2

def test_detach_last_group_floating_removes_dock():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    f1 = l.detach_group(_ga(id, 0), 10, 10)
    l.detach_group(_ga(f1, 0), 20, 20)
    assert l.dock(f1) is None

def test_detach_last_group_anchored_keeps_dock():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.detach_group(_ga(id, 0), 10, 10)
    l.detach_group(_ga(id, 0), 20, 20)
    assert l.dock(id) is not None
    assert len(l.dock(id).groups) == 0

# -- Move panel --

def test_move_panel_same_dock():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.move_panel_to_group(_pa(id, 1, 1), _ga(id, 0))
    assert l.dock(id).groups[0].panels == [PanelKind.LAYERS, PanelKind.STROKE]
    assert l.dock(id).groups[1].panels == [PanelKind.COLOR, PanelKind.PROPERTIES]

def test_move_panel_becomes_active():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.move_panel_to_group(_pa(id, 1, 1), _ga(id, 0))
    assert l.dock(id).groups[0].active == 1

def test_move_panel_cross_dock():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    fid = l.detach_group(_ga(id, 0), 50, 50)
    l.move_panel_to_group(_pa(id, 0, 0), _ga(fid, 0))
    assert l.dock(fid).groups[0].panels == [PanelKind.LAYERS, PanelKind.COLOR]
    assert l.dock(id).groups[0].panels == [PanelKind.STROKE, PanelKind.PROPERTIES]

def test_move_last_panel_removes_group():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.move_panel_to_group(_pa(id, 0, 0), _ga(id, 1))
    assert len(l.dock(id).groups) == 1
    assert PanelKind.LAYERS in l.dock(id).groups[0].panels

def test_move_last_panel_removes_floating():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    fid = l.detach_group(_ga(id, 0), 50, 50)
    l.move_panel_to_group(_pa(fid, 0, 0), _ga(id, 0))
    assert l.dock(fid) is None

def test_move_panel_clamps_active():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.dock(id).groups[1].active = 2
    l.move_panel_to_group(_pa(id, 1, 2), _ga(id, 0))
    assert l.dock(id).groups[1].active < len(l.dock(id).groups[1].panels)

def test_move_panel_invalid_source():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.move_panel_to_group(_pa(id, 1, 99), _ga(id, 0))
    l.move_panel_to_group(_pa(99, 0, 0), _ga(id, 0))

def test_move_panel_invalid_target():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.move_panel_to_group(_pa(id, 1, 0), _ga(99, 0))
    assert len(l.dock(id).groups[1].panels) == 3

# -- Insert panel as group --

def test_insert_panel_creates_group():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.insert_panel_as_new_group(_pa(id, 1, 1), id, 0)
    assert len(l.dock(id).groups) == 3
    assert l.dock(id).groups[0].panels == [PanelKind.STROKE]

def test_insert_panel_cleans_source():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.insert_panel_as_new_group(_pa(id, 0, 0), id, 99)
    assert len(l.dock(id).groups) == 2
    assert l.dock(id).groups[1].panels == [PanelKind.LAYERS]

def test_insert_panel_invalid():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.insert_panel_as_new_group(_pa(id, 1, 99), id, 0)
    l.insert_panel_as_new_group(_pa(99, 0, 0), id, 0)
    assert len(l.dock(id).groups) == 2

# -- Detach panel --

def test_detach_panel_creates_floating():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    fid = l.detach_panel(_pa(id, 1, 1), 300, 150)
    assert fid is not None
    assert l.dock(fid).groups[0].panels == [PanelKind.STROKE]
    assert l.dock(id).groups[1].panels == [PanelKind.COLOR, PanelKind.PROPERTIES]

def test_detach_panel_position():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    fid = l.detach_panel(_pa(id, 1, 0), 300, 150)
    assert l.floating_dock(fid).x == 300
    assert l.floating_dock(fid).y == 150

def test_detach_panel_last_removes_group():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.detach_panel(_pa(id, 0, 0), 50, 50)
    assert len(l.dock(id).groups) == 1

def test_detach_panel_last_removes_floating():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    f1 = l.detach_group(_ga(id, 0), 50, 50)
    l.detach_panel(_pa(f1, 0, 0), 100, 100)
    assert l.dock(f1) is None

# -- Floating position --

def test_set_floating_position():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    fid = l.detach_group(_ga(id, 0), 10, 10)
    l.set_floating_position(fid, 200, 300)
    assert l.floating_dock(fid).x == 200
    assert l.floating_dock(fid).y == 300

def test_set_position_anchored_ignored():
    l = WorkspaceLayout.default_layout()
    l.set_floating_position(_rid(l), 999, 999)

def test_set_position_invalid_id():
    l = WorkspaceLayout.default_layout()
    l.set_floating_position(99, 0, 0)

# -- Resize --

def test_resize_group_sets_height():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.resize_group(_ga(id, 0), 150)
    assert l.dock(id).groups[0].height == 150

def test_resize_group_clamps_min():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.resize_group(_ga(id, 0), 5)
    assert l.dock(id).groups[0].height == MIN_GROUP_HEIGHT

def test_resize_group_invalid_addr():
    l = WorkspaceLayout.default_layout()
    l.resize_group(_ga(99, 0), 100)
    l.resize_group(_ga(0, 99), 100)

def test_default_group_height_is_none():
    l = WorkspaceLayout.default_layout()
    for g in l.anchored_dock(DockEdge.RIGHT).groups:
        assert g.height is None

def test_set_dock_width_clamped():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.set_dock_width(id, 50)
    assert l.dock(id).width == MIN_DOCK_WIDTH
    l.set_dock_width(id, 9999)
    assert l.dock(id).width == MAX_DOCK_WIDTH
    l.set_dock_width(id, 300)
    assert l.dock(id).width == 300

# -- Cleanup --

def test_cleanup_clamps_active():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.dock(id).groups[1].active = 2
    l.move_panel_to_group(_pa(id, 1, 2), _ga(id, 0))
    assert l.dock(id).groups[1].active < len(l.dock(id).groups[1].panels)

def test_cleanup_multiple_empty_groups():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.dock(id).groups[0].panels = []
    l.dock(id).groups[1].panels = []
    l._cleanup(id)
    assert len(l.dock(id).groups) == 0

# -- Labels --

def test_panel_label_values():
    assert WorkspaceLayout.panel_label(PanelKind.LAYERS) == "Layers"
    assert WorkspaceLayout.panel_label(PanelKind.COLOR) == "Color"
    assert WorkspaceLayout.panel_label(PanelKind.STROKE) == "Stroke"
    assert WorkspaceLayout.panel_label(PanelKind.PROPERTIES) == "Properties"

def test_panel_group_active_panel():
    g = PanelGroup(panels=[PanelKind.COLOR, PanelKind.STROKE])
    assert g.active_panel() == PanelKind.COLOR

def test_panel_group_active_panel_empty():
    g = PanelGroup(panels=[])
    assert g.active_panel() is None

# -- Close / show --

def test_close_panel_hides_it():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.close_panel(_pa(id, 1, 1))
    assert PanelKind.STROKE in l.hidden_panels
    assert not l.is_panel_visible(PanelKind.STROKE)

def test_close_panel_removes_from_group():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.close_panel(_pa(id, 1, 1))
    assert l.dock(id).groups[1].panels == [PanelKind.COLOR, PanelKind.PROPERTIES]

def test_close_last_panel_removes_group():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.close_panel(_pa(id, 0, 0))
    assert len(l.dock(id).groups) == 1
    assert PanelKind.LAYERS in l.hidden_panels

def test_show_panel_adds_to_default_group():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.close_panel(_pa(id, 1, 1))
    l.show_panel(PanelKind.STROKE)
    assert PanelKind.STROKE not in l.hidden_panels
    assert PanelKind.STROKE in l.dock(id).groups[0].panels

def test_show_panel_removes_from_hidden():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.close_panel(_pa(id, 1, 0))
    assert len(l.hidden_panels) == 1
    l.show_panel(PanelKind.COLOR)
    assert l.hidden_panels == []

def test_hidden_panels_default_empty():
    assert WorkspaceLayout.default_layout().hidden_panels == []

def test_panel_menu_items_all_visible():
    l = WorkspaceLayout.default_layout()
    items = l.panel_menu_items()
    assert len(items) == 4
    for _, v in items:
        assert v

def test_panel_menu_items_with_hidden():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.close_panel(_pa(id, 1, 1))
    items = l.panel_menu_items()
    assert not dict(items)[PanelKind.STROKE]
    assert dict(items)[PanelKind.LAYERS]

# -- Z-index --

def test_bring_to_front_moves_to_end():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    f1 = l.detach_group(_ga(id, 0), 10, 10)
    f2 = l.detach_group(_ga(id, 0), 20, 20)
    l.bring_to_front(f1)
    assert l.z_order[-1] == f1

def test_bring_to_front_already_front():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    f1 = l.detach_group(_ga(id, 0), 10, 10)
    f2 = l.detach_group(_ga(id, 0), 20, 20)
    l.bring_to_front(f2)
    assert l.z_order[-1] == f2
    assert len(l.z_order) == 2

def test_z_index_for_ordering():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    f1 = l.detach_group(_ga(id, 0), 10, 10)
    f2 = l.detach_group(_ga(id, 0), 20, 20)
    assert l.z_index_for(f1) == 0
    assert l.z_index_for(f2) == 1
    l.bring_to_front(f1)
    assert l.z_index_for(f1) == 1
    assert l.z_index_for(f2) == 0

# -- Snap & re-dock --

def test_snap_to_right_edge():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    fid = l.detach_group(_ga(id, 0), 50, 50)
    before = len(l.anchored_dock(DockEdge.RIGHT).groups)
    l.snap_to_edge(fid, DockEdge.RIGHT)
    assert l.floating_dock(fid) is None
    assert len(l.anchored_dock(DockEdge.RIGHT).groups) > before

def test_snap_to_left_edge():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    fid = l.detach_group(_ga(id, 0), 50, 50)
    l.snap_to_edge(fid, DockEdge.LEFT)
    assert l.anchored_dock(DockEdge.LEFT) is not None
    assert l.floating_dock(fid) is None

def test_snap_creates_anchored_dock():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    assert l.anchored_dock(DockEdge.BOTTOM) is None
    fid = l.detach_group(_ga(id, 0), 50, 50)
    l.snap_to_edge(fid, DockEdge.BOTTOM)
    assert l.anchored_dock(DockEdge.BOTTOM) is not None
    assert l.anchored_dock(DockEdge.BOTTOM).groups[0].panels == [PanelKind.LAYERS]

def test_redock_merges_into_right():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    fid = l.detach_group(_ga(id, 0), 50, 50)
    l.redock(fid)
    assert l.floating == []
    assert any(PanelKind.LAYERS in g.panels for g in l.anchored_dock(DockEdge.RIGHT).groups)

def test_redock_invalid_id():
    l = WorkspaceLayout.default_layout()
    l.redock(99)
    assert len(l.anchored) == 1

def test_is_near_edge_detection():
    assert WorkspaceLayout.is_near_edge(5, 500, 1000, 800) == DockEdge.LEFT
    assert WorkspaceLayout.is_near_edge(990, 500, 1000, 800) == DockEdge.RIGHT
    assert WorkspaceLayout.is_near_edge(500, 790, 1000, 800) == DockEdge.BOTTOM

def test_is_near_edge_not_near():
    assert WorkspaceLayout.is_near_edge(500, 400, 1000, 800) is None

# -- Multi-edge --

def test_add_anchored_left():
    l = WorkspaceLayout.default_layout()
    id = l.add_anchored_dock(DockEdge.LEFT)
    assert l.anchored_dock(DockEdge.LEFT) is not None
    assert l.anchored_dock(DockEdge.LEFT).id == id

def test_add_anchored_existing_returns_id():
    l = WorkspaceLayout.default_layout()
    id1 = l.add_anchored_dock(DockEdge.LEFT)
    id2 = l.add_anchored_dock(DockEdge.LEFT)
    assert id1 == id2
    assert len(l.anchored) == 2

def test_add_anchored_bottom():
    l = WorkspaceLayout.default_layout()
    l.add_anchored_dock(DockEdge.BOTTOM)
    assert l.anchored_dock(DockEdge.BOTTOM) is not None
    assert len(l.anchored) == 2

def test_remove_anchored_moves_to_floating():
    l = WorkspaceLayout.default_layout()
    lid = l.add_anchored_dock(DockEdge.LEFT)
    l.dock(lid).groups.append(PanelGroup(panels=[PanelKind.LAYERS]))
    fid = l.remove_anchored_dock(DockEdge.LEFT)
    assert fid is not None
    assert l.anchored_dock(DockEdge.LEFT) is None
    assert l.floating_dock(fid) is not None

def test_remove_anchored_empty_returns_none():
    l = WorkspaceLayout.default_layout()
    l.add_anchored_dock(DockEdge.LEFT)
    fid = l.remove_anchored_dock(DockEdge.LEFT)
    assert fid is None

# -- Persistence --

def test_reset_to_default():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.detach_group(_ga(id, 0), 50, 50)
    l.close_panel(_pa(id, 0, 0))
    assert l.floating != []
    assert l.hidden_panels != []
    l.reset_to_default()
    assert l.floating == []
    assert l.hidden_panels == []
    assert len(l.anchored_dock(DockEdge.RIGHT).groups) == 2

# -- Focus --

def test_set_focused_panel():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    addr = _pa(id, 1, 2)
    l.set_focused_panel(addr)
    assert l.focused_panel == addr
    l.set_focused_panel(None)
    assert l.focused_panel is None

def test_focus_next_wraps():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.set_focused_panel(None)
    l.focus_next_panel()
    assert l.focused_panel == _pa(id, 0, 0)
    l.focus_next_panel()
    l.focus_next_panel()
    l.focus_next_panel()
    assert l.focused_panel == _pa(id, 1, 2)
    l.focus_next_panel()
    assert l.focused_panel == _pa(id, 0, 0)

def test_focus_prev_wraps():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.set_focused_panel(None)
    l.focus_prev_panel()
    assert l.focused_panel == _pa(id, 1, 2)
    l.focus_prev_panel()
    l.focus_prev_panel()
    l.focus_prev_panel()
    assert l.focused_panel == _pa(id, 0, 0)
    l.focus_prev_panel()
    assert l.focused_panel == _pa(id, 1, 2)

# -- Safety --

def test_clamp_floating_within_viewport():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    fid = l.detach_group(_ga(id, 0), 2000, 1500)
    l.clamp_floating_docks(1000, 800)
    assert l.floating_dock(fid).x <= 950
    assert l.floating_dock(fid).y <= 750

def test_clamp_floating_partially_offscreen():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    fid = l.detach_group(_ga(id, 0), -500, -100)
    l.clamp_floating_docks(1000, 800)
    fd = l.floating_dock(fid)
    assert fd.x >= -fd.dock.width + 50
    assert fd.y >= 0

def test_set_auto_hide():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    assert not l.dock(id).auto_hide
    l.set_auto_hide(id, True)
    assert l.dock(id).auto_hide
    l.set_auto_hide(id, False)
    assert not l.dock(id).auto_hide

# -- Reorder panels --

def test_reorder_panel_forward():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.reorder_panel(_ga(id, 1), 0, 2)
    assert l.dock(id).groups[1].panels == [PanelKind.STROKE, PanelKind.PROPERTIES, PanelKind.COLOR]
    assert l.dock(id).groups[1].active == 2

def test_reorder_panel_backward():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.reorder_panel(_ga(id, 1), 2, 0)
    assert l.dock(id).groups[1].panels == [PanelKind.PROPERTIES, PanelKind.COLOR, PanelKind.STROKE]
    assert l.dock(id).groups[1].active == 0

def test_reorder_panel_same_position():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.reorder_panel(_ga(id, 1), 1, 1)
    assert l.dock(id).groups[1].panels == [PanelKind.COLOR, PanelKind.STROKE, PanelKind.PROPERTIES]

def test_reorder_panel_clamped():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.reorder_panel(_ga(id, 1), 0, 99)
    assert l.dock(id).groups[1].panels[2] == PanelKind.COLOR

def test_reorder_panel_out_of_bounds():
    l = WorkspaceLayout.default_layout()
    id = _rid(l)
    l.reorder_panel(_ga(id, 1), 99, 0)
    l.reorder_panel(_ga(99, 0), 0, 1)

# -- Named layouts & AppConfig --

def test_default_layout_name():
    assert WorkspaceLayout.default_layout().name == "Default"

def test_named_layout():
    l = WorkspaceLayout.named("My Workspace")
    assert l.name == "My Workspace"
    assert len(l.anchored) == 1

def test_storage_key_includes_name():
    l = WorkspaceLayout.named("Editing")
    assert l.storage_key() == "jas_layout:Editing"

def test_storage_key_for_static():
    assert WorkspaceLayout.storage_key_for("Drawing") == "jas_layout:Drawing"

def test_reset_preserves_name():
    l = WorkspaceLayout.named("Custom")
    id = _rid(l)
    l.detach_group(_ga(id, 0), 50, 50)
    assert l.floating != []
    l.reset_to_default()
    assert l.name == "Custom"
    assert l.floating == []

def test_app_config_default():
    c = AppConfig()
    assert c.active_layout == "Default"
    assert c.saved_layouts == ["Default"]

def test_app_config_round_trip():
    c = AppConfig(active_layout="My Layout", saved_layouts=["My Layout"])
    j = c.to_json()
    c2 = AppConfig.from_json(j)
    assert c2.active_layout == "My Layout"

def test_app_config_invalid_json():
    c = AppConfig.from_json("garbage{{{")
    assert c.active_layout == "Default"


# -- Pane layout integration --

def test_workspace_layout_default_has_no_pane_layout():
    l = WorkspaceLayout.default_layout()
    assert l.panes() is None

def test_ensure_pane_layout_creates_if_none():
    l = WorkspaceLayout.default_layout()
    l.ensure_pane_layout(1000, 700)
    assert l.panes() is not None
    assert len(l.panes().panes) == 3

def test_ensure_pane_layout_noop_if_present():
    l = WorkspaceLayout.default_layout()
    l.ensure_pane_layout(1000, 700)
    l.mark_saved()
    l.ensure_pane_layout(1000, 700)
    assert not l.needs_save()

def test_reset_to_default_clears_pane_layout():
    l = WorkspaceLayout.default_layout()
    l.ensure_pane_layout(1000, 700)
    assert l.panes() is not None
    l.reset_to_default()
    assert l.panes() is None

def test_panes_accessors():
    l = WorkspaceLayout.default_layout()
    assert l.panes() is None
    l.ensure_pane_layout(1000, 700)
    assert l.panes() is not None
    from workspace.pane import PaneKind as PK
    l.panes_mut(lambda pl: pl.hide_pane(PK.TOOLBAR))
    assert not l.panes().is_pane_visible(PK.TOOLBAR)

def test_serde_backward_compat_no_pane_layout():
    l = WorkspaceLayout.default_layout()
    d = l.to_dict()
    l2 = WorkspaceLayout.from_dict(d)
    assert l2.panes() is None
    assert len(l2.anchored) == 1

def test_serde_round_trip_with_pane_layout():
    l = WorkspaceLayout.default_layout()
    l.ensure_pane_layout(1000, 700)
    d = l.to_dict()
    l2 = WorkspaceLayout.from_dict(d)
    assert l2.panes() is not None
    assert len(l2.panes().panes) == 3
    assert len(l2.panes().snaps) == 10

def test_clamp_floating_docks_also_clamps_panes():
    l = WorkspaceLayout.default_layout()
    l.ensure_pane_layout(1000, 700)
    from workspace.pane import PaneKind as PK, MIN_PANE_VISIBLE
    cid = l.panes().pane_by_kind(PK.CANVAS).id
    l.panes_mut(lambda pl: pl.set_pane_position(cid, 5000, 5000))
    l.clamp_floating_docks(1000, 700)
    canvas = l.panes().pane_by_kind(PK.CANVAS)
    assert canvas.x <= 1000 - MIN_PANE_VISIBLE
    assert canvas.y <= 700 - MIN_PANE_VISIBLE
