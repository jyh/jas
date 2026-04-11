"""Tests for panel menu system."""

from workspace.workspace_layout import (
    PanelKind, DockEdge, GroupAddr, PanelAddr, WorkspaceLayout, ALL_PANEL_KINDS,
)
from panels.panel_menu import (
    panel_label, panel_menu, panel_dispatch, panel_is_checked,
    PanelMenuItemKind,
)


def test_panel_label_all_kinds():
    assert panel_label(PanelKind.LAYERS) == "Layers"
    assert panel_label(PanelKind.COLOR) == "Color"
    assert panel_label(PanelKind.STROKE) == "Stroke"
    assert panel_label(PanelKind.PROPERTIES) == "Properties"


def test_all_panel_kinds_count():
    assert len(ALL_PANEL_KINDS) == 4


def test_all_panel_kinds_contains_all():
    assert PanelKind.LAYERS in ALL_PANEL_KINDS
    assert PanelKind.COLOR in ALL_PANEL_KINDS
    assert PanelKind.STROKE in ALL_PANEL_KINDS
    assert PanelKind.PROPERTIES in ALL_PANEL_KINDS


def test_panel_menu_non_empty():
    for kind in ALL_PANEL_KINDS:
        items = panel_menu(kind)
        assert len(items) > 0, f"Menu for {kind} is empty"


def test_every_panel_has_close_action():
    for kind in ALL_PANEL_KINDS:
        items = panel_menu(kind)
        has_close = any(
            i.kind == PanelMenuItemKind.ACTION and i.command == "close_panel"
            for i in items
        )
        assert has_close, f"Menu for {kind} missing close_panel action"


def test_close_label_matches_panel_name():
    for kind in ALL_PANEL_KINDS:
        items = panel_menu(kind)
        close_item = next(
            (i for i in items if i.kind == PanelMenuItemKind.ACTION and i.command == "close_panel"),
            None,
        )
        assert close_item is not None
        assert close_item.label == f"Close {panel_label(kind)}"


def test_dispatch_close_removes_panel():
    layout = WorkspaceLayout.default_layout()
    dock = layout.anchored_dock(DockEdge.RIGHT)
    assert dock is not None
    # Color is at group 1, panel index 0
    addr = PanelAddr(group=GroupAddr(dock_id=dock.id, group_idx=1), panel_idx=0)
    assert layout.is_panel_visible(PanelKind.COLOR)
    panel_dispatch(PanelKind.COLOR, "close_panel", addr, layout)
    assert not layout.is_panel_visible(PanelKind.COLOR)


def test_is_checked_defaults_false():
    layout = WorkspaceLayout.default_layout()
    for kind in ALL_PANEL_KINDS:
        assert not panel_is_checked(kind, "anything", layout)
