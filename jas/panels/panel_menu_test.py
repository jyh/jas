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
    assert panel_label(PanelKind.SWATCHES) == "Swatches"
    assert panel_label(PanelKind.STROKE) == "Stroke"
    assert panel_label(PanelKind.PROPERTIES) == "Properties"


def test_all_panel_kinds_count():
    assert len(ALL_PANEL_KINDS) == 10


def test_all_panel_kinds_contains_all():
    assert PanelKind.LAYERS in ALL_PANEL_KINDS
    assert PanelKind.COLOR in ALL_PANEL_KINDS
    assert PanelKind.SWATCHES in ALL_PANEL_KINDS
    assert PanelKind.STROKE in ALL_PANEL_KINDS
    assert PanelKind.PROPERTIES in ALL_PANEL_KINDS
    assert PanelKind.CHARACTER in ALL_PANEL_KINDS
    assert PanelKind.PARAGRAPH in ALL_PANEL_KINDS
    assert PanelKind.ARTBOARDS in ALL_PANEL_KINDS
    assert PanelKind.ALIGN in ALL_PANEL_KINDS


def test_panel_label_align():
    assert panel_label(PanelKind.ALIGN) == "Align"


def test_align_menu_has_expected_entries():
    items = panel_menu(PanelKind.ALIGN)
    assert len(items) == 5
    assert items[0].kind == PanelMenuItemKind.TOGGLE
    assert items[0].command == "toggle_use_preview_bounds"
    assert items[1].kind == PanelMenuItemKind.SEPARATOR
    assert items[2].kind == PanelMenuItemKind.ACTION
    assert items[2].command == "reset_align_panel"
    assert items[3].kind == PanelMenuItemKind.SEPARATOR
    assert items[4].kind == PanelMenuItemKind.ACTION
    assert items[4].label == "Close Align"
    assert items[4].command == "close_panel"


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
    # Color is at group 0, panel index 0
    addr = PanelAddr(group=GroupAddr(dock_id=dock.id, group_idx=0), panel_idx=0)
    assert layout.is_panel_visible(PanelKind.COLOR)
    panel_dispatch(PanelKind.COLOR, "close_panel", addr, layout)
    assert not layout.is_panel_visible(PanelKind.COLOR)


def test_is_checked_defaults_false():
    layout = WorkspaceLayout.default_layout()
    for kind in ALL_PANEL_KINDS:
        assert not panel_is_checked(kind, "anything", layout)


def test_layers_menu_has_new_layer():
    items = panel_menu(PanelKind.LAYERS)
    has = any(i.kind == PanelMenuItemKind.ACTION and i.command == "new_layer" for i in items)
    assert has, "Layers menu missing new_layer"


def test_layers_menu_has_new_group():
    items = panel_menu(PanelKind.LAYERS)
    has = any(i.kind == PanelMenuItemKind.ACTION and i.command == "new_group" for i in items)
    assert has, "Layers menu missing new_group"


def test_layers_menu_has_visibility_toggles():
    items = panel_menu(PanelKind.LAYERS)
    for cmd in ("toggle_all_layers_visibility", "toggle_all_layers_outline",
                "toggle_all_layers_lock"):
        has = any(i.kind == PanelMenuItemKind.ACTION and i.command == cmd for i in items)
        assert has, f"Layers menu missing {cmd}"


def test_layers_menu_has_isolation_mode():
    items = panel_menu(PanelKind.LAYERS)
    for cmd in ("enter_isolation_mode", "exit_isolation_mode"):
        has = any(i.kind == PanelMenuItemKind.ACTION and i.command == cmd for i in items)
        assert has, f"Layers menu missing {cmd}"


def test_layers_menu_has_flatten_and_collect():
    items = panel_menu(PanelKind.LAYERS)
    for cmd in ("flatten_artwork", "collect_in_new_layer"):
        has = any(i.kind == PanelMenuItemKind.ACTION and i.command == cmd for i in items)
        assert has, f"Layers menu missing {cmd}"


def test_layers_dispatch_tier3_no_error():
    layout = WorkspaceLayout.default_layout()
    dock = layout.anchored_dock(DockEdge.RIGHT)
    addr = PanelAddr(group=GroupAddr(dock_id=dock.id, group_idx=2), panel_idx=0)
    for cmd in ("new_layer", "new_group", "toggle_all_layers_visibility",
                "toggle_all_layers_outline", "toggle_all_layers_lock",
                "enter_isolation_mode", "exit_isolation_mode",
                "flatten_artwork", "collect_in_new_layer"):
        panel_dispatch(PanelKind.LAYERS, cmd, addr, layout)


# Phase 3: Group A toggle actions via YAML dispatch

def _make_model_with_layers(layer_specs):
    """Build a Model with top-level layers given (name, visibility, locked) tuples."""
    import dataclasses
    from geometry.element import Layer, Visibility
    from document.model import Model
    from document.document import Document
    layers = tuple(
        Layer(name=name, children=(), visibility=vis, locked=locked)
        for name, vis, locked in layer_specs
    )
    doc = Document(layers=layers)
    return Model(document=doc)


def test_new_layer_via_yaml_no_existing():
    from geometry.element import Layer
    layout = WorkspaceLayout.default_layout()
    dock = layout.anchored_dock(DockEdge.RIGHT)
    addr = PanelAddr(group=GroupAddr(dock_id=dock.id, group_idx=2), panel_idx=0)
    model = _make_model_with_layers([])
    panel_dispatch(PanelKind.LAYERS, "new_layer", addr, layout, model=model)
    assert len(model.document.layers) == 1
    assert isinstance(model.document.layers[0], Layer)
    assert model.document.layers[0].name == "Layer 1"


def test_new_layer_via_yaml_skips_existing_name():
    from geometry.element import Layer, Visibility
    layout = WorkspaceLayout.default_layout()
    dock = layout.anchored_dock(DockEdge.RIGHT)
    addr = PanelAddr(group=GroupAddr(dock_id=dock.id, group_idx=2), panel_idx=0)
    model = _make_model_with_layers([("Layer 1", Visibility.PREVIEW, False)])
    panel_dispatch(PanelKind.LAYERS, "new_layer", addr, layout, model=model)
    assert len(model.document.layers) == 2
    assert model.document.layers[1].name == "Layer 2"


def test_toggle_all_layers_visibility_via_yaml():
    from geometry.element import Visibility
    layout = WorkspaceLayout.default_layout()
    dock = layout.anchored_dock(DockEdge.RIGHT)
    addr = PanelAddr(group=GroupAddr(dock_id=dock.id, group_idx=2), panel_idx=0)
    model = _make_model_with_layers([
        ("A", Visibility.PREVIEW, False),
        ("B", Visibility.INVISIBLE, False),
    ])
    panel_dispatch(PanelKind.LAYERS, "toggle_all_layers_visibility",
                   addr, layout, model=model)
    # any_visible=true → target=invisible
    assert model.document.layers[0].visibility == Visibility.INVISIBLE
    assert model.document.layers[1].visibility == Visibility.INVISIBLE


def test_toggle_all_layers_visibility_all_invisible_to_preview():
    from geometry.element import Visibility
    layout = WorkspaceLayout.default_layout()
    dock = layout.anchored_dock(DockEdge.RIGHT)
    addr = PanelAddr(group=GroupAddr(dock_id=dock.id, group_idx=2), panel_idx=0)
    model = _make_model_with_layers([
        ("A", Visibility.INVISIBLE, False),
        ("B", Visibility.INVISIBLE, False),
    ])
    panel_dispatch(PanelKind.LAYERS, "toggle_all_layers_visibility",
                   addr, layout, model=model)
    assert model.document.layers[0].visibility == Visibility.PREVIEW
    assert model.document.layers[1].visibility == Visibility.PREVIEW


def test_toggle_all_layers_outline_via_yaml():
    from geometry.element import Visibility
    layout = WorkspaceLayout.default_layout()
    dock = layout.anchored_dock(DockEdge.RIGHT)
    addr = PanelAddr(group=GroupAddr(dock_id=dock.id, group_idx=2), panel_idx=0)
    model = _make_model_with_layers([
        ("A", Visibility.PREVIEW, False),
    ])
    panel_dispatch(PanelKind.LAYERS, "toggle_all_layers_outline",
                   addr, layout, model=model)
    assert model.document.layers[0].visibility == Visibility.OUTLINE


def test_toggle_all_layers_lock_via_yaml():
    from geometry.element import Visibility
    layout = WorkspaceLayout.default_layout()
    dock = layout.anchored_dock(DockEdge.RIGHT)
    addr = PanelAddr(group=GroupAddr(dock_id=dock.id, group_idx=2), panel_idx=0)
    model = _make_model_with_layers([
        ("A", Visibility.PREVIEW, False),
    ])
    panel_dispatch(PanelKind.LAYERS, "toggle_all_layers_lock",
                   addr, layout, model=model)
    assert model.document.layers[0].locked is True


def test_layer_options_confirm_edit_mode():
    from geometry.element import Visibility
    from jas.panels.panel_menu import _dispatch_yaml_layers_action
    model = _make_model_with_layers([
        ("Old", Visibility.PREVIEW, False),
    ])
    closed = [False]
    _dispatch_yaml_layers_action(
        "layer_options_confirm", model,
        params={
            "layer_id": "0",
            "name": "Renamed",
            "lock": True,
            "show": True,
            "preview": False,     # show=true, preview=false → outline
        },
        on_close_dialog=lambda: closed.__setitem__(0, True),
    )
    assert closed[0]
    layer = model.document.layers[0]
    assert layer.name == "Renamed"
    assert layer.locked is True
    assert layer.visibility == Visibility.OUTLINE


def test_layer_options_confirm_create_mode():
    from geometry.element import Visibility
    from jas.panels.panel_menu import _dispatch_yaml_layers_action
    model = _make_model_with_layers([
        ("Existing", Visibility.PREVIEW, False),
    ])
    _dispatch_yaml_layers_action(
        "layer_options_confirm", model,
        params={
            "layer_id": None,
            "name": "Brand New",
            "lock": False,
            "show": True,
            "preview": True,
        },
    )
    assert len(model.document.layers) == 2
    new_layer = model.document.layers[1]
    assert new_layer.name == "Brand New"
    assert new_layer.visibility == Visibility.PREVIEW


def test_delete_layer_selection_via_yaml_dispatch():
    from geometry.element import Visibility
    from jas.panels.panel_menu import _dispatch_yaml_layers_action
    model = _make_model_with_layers([
        ("A", Visibility.PREVIEW, False),
        ("B", Visibility.PREVIEW, False),
        ("C", Visibility.PREVIEW, False),
    ])
    _dispatch_yaml_layers_action(
        "delete_layer_selection", model,
        panel_selection=[(0,), (2,)],
    )
    assert len(model.document.layers) == 1
    assert model.document.layers[0].name == "B"


def test_duplicate_layer_selection_via_yaml_dispatch():
    from geometry.element import Visibility
    from jas.panels.panel_menu import _dispatch_yaml_layers_action
    model = _make_model_with_layers([
        ("A", Visibility.PREVIEW, False),
        ("B", Visibility.PREVIEW, False),
    ])
    _dispatch_yaml_layers_action(
        "duplicate_layer_selection", model,
        panel_selection=[(1,)],
    )
    assert len(model.document.layers) == 3
    names = [l.name for l in model.document.layers]
    assert names == ["A", "B", "B"]


def test_collect_in_new_layer_via_yaml_dispatch():
    from geometry.element import Visibility
    from jas.panels.panel_menu import _dispatch_yaml_layers_action
    model = _make_model_with_layers([
        ("Layer 1", Visibility.PREVIEW, False),
        ("Layer 2", Visibility.PREVIEW, False),
        ("Layer 3", Visibility.PREVIEW, False),
    ])
    _dispatch_yaml_layers_action(
        "collect_in_new_layer", model,
        panel_selection=[(0,), (2,)],
    )
    assert len(model.document.layers) == 2
    assert model.document.layers[0].name == "Layer 2"
    # Next unused name after Layer 1/2/3 is Layer 4, with two children.
    new_layer = model.document.layers[1]
    assert new_layer.name == "Layer 4"
    assert len(new_layer.children) == 2


def test_enter_isolation_mode_via_yaml_pushes_selection():
    from geometry.element import Visibility
    from jas.panels import layers_panel_state as lps
    from jas.panels.panel_menu import _dispatch_yaml_layers_action
    lps.clear_isolation_stack()
    model = _make_model_with_layers([
        ("A", Visibility.PREVIEW, False),
        ("B", Visibility.PREVIEW, False),
    ])
    _dispatch_yaml_layers_action("enter_isolation_mode", model,
                                  panel_selection=[(1,)])
    assert lps.get_isolation_stack() == [(1,)]


def test_exit_isolation_mode_via_yaml_pops():
    from geometry.element import Visibility
    from jas.panels import layers_panel_state as lps
    layout = WorkspaceLayout.default_layout()
    dock = layout.anchored_dock(DockEdge.RIGHT)
    addr = PanelAddr(group=GroupAddr(dock_id=dock.id, group_idx=2), panel_idx=0)
    lps.clear_isolation_stack()
    lps.push_isolation_level((0,))
    model = _make_model_with_layers([
        ("A", Visibility.PREVIEW, False),
    ])
    panel_dispatch(PanelKind.LAYERS, "exit_isolation_mode", addr, layout,
                   model=model)
    assert lps.get_isolation_stack() == []
