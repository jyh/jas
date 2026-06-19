"""Tests for panel menu system."""

from workspace.workspace_layout import (
    PanelKind, DockEdge, GroupAddr, PanelAddr, WorkspaceLayout, ALL_PANEL_KINDS,
)
from panels.panel_menu import (
    panel_label, panel_menu, panel_dispatch, panel_is_checked,
    PanelMenuItemKind, menu_items_from_yaml,
    push_recent_color, add_recent_colors_listener,
    _recent_colors_listeners,
)


# ---------------------------------------------------------------------------
# Generic YAML-driven menu builder (review #15)
# ---------------------------------------------------------------------------
# These mirror the Rust reference tests in jas_dioxus panel_menu.rs: the
# builder reads each panel's `menu:` array from the compiled bundle and
# maps separator / checked->toggle / shared-action->radio / else->action,
# with the dynamic library submenu surfaced as a command-keyed action.


def test_menu_items_from_yaml_reads_boolean_panel():
    # Reads workspace/panels/boolean.yaml's menu (7 actions + 3 separators).
    items = menu_items_from_yaml("boolean_panel_content")
    cmds = [i.command for i in items if i.kind == PanelMenuItemKind.ACTION]
    assert "make_compound_shape" in cmds
    assert "close_panel" in cmds
    seps = sum(1 for i in items if i.kind == PanelMenuItemKind.SEPARATOR)
    assert seps == 3
    assert len(items) == 10


def test_color_radio_members_fold_params_into_command():
    # The Color panel's five mode rows all share action
    # `set_color_panel_mode`, so the builder treats them as a radio group
    # and folds each params.mode value into the command, keeping them
    # distinguishable for the no-params menu dispatch.
    items = menu_items_from_yaml("color_panel_content")
    radios = [(i.command, i.group) for i in items
              if i.kind == PanelMenuItemKind.RADIO]
    assert ("set_color_panel_mode:grayscale", "set_color_panel_mode") in radios
    assert ("set_color_panel_mode:rgb", "set_color_panel_mode") in radios
    assert ("set_color_panel_mode:web_safe_rgb", "set_color_panel_mode") in radios
    # Plain actions keep their action verbatim (no param folding).
    action_cmds = [i.command for i in items if i.kind == PanelMenuItemKind.ACTION]
    assert "invert_active_color" in action_cmds
    # close_panel keeps its action even though the YAML carries
    # params: { panel: color }.
    assert "close_panel" in action_cmds


def test_swatches_submenu_becomes_open_library_action():
    # The dynamic "Open Swatch Library" submenu entry carries an explicit
    # action: open_swatch_library in the YAML so the menu view's submenu
    # host (keyed on that command) still fires — no native literal.
    items = menu_items_from_yaml("swatches_panel_content")
    action_cmds = [i.command for i in items if i.kind == PanelMenuItemKind.ACTION]
    assert "open_swatch_library" in action_cmds
    # Thumbnail-size rows are a radio group with folded params.
    radio_cmds = [i.command for i in items if i.kind == PanelMenuItemKind.RADIO]
    assert "set_swatch_thumbnail_size:small" in radio_cmds
    assert "set_swatch_thumbnail_size:large" in radio_cmds


def test_standalone_checkbox_is_toggle_not_radio():
    # The Align panel has a single toggle_use_preview_bounds checkbox; its
    # action does not recur, so it is a Toggle, not a Radio.
    items = menu_items_from_yaml("align_panel_content")
    toggles = [i.command for i in items if i.kind == PanelMenuItemKind.TOGGLE]
    assert "toggle_use_preview_bounds" in toggles
    radios = [i.command for i in items if i.kind == PanelMenuItemKind.RADIO]
    assert "toggle_use_preview_bounds" not in radios


def test_character_checked_entries_are_toggles():
    # The Character panel uses the `checked:` form (not `checked_when:`);
    # each action is one-off so the builder maps them to standalone toggles.
    items = menu_items_from_yaml("character_panel_content")
    toggles = [i.command for i in items if i.kind == PanelMenuItemKind.TOGGLE]
    for cmd in ("toggle_snap_to_glyph_visible", "toggle_all_caps",
                "toggle_small_caps", "toggle_superscript", "toggle_subscript"):
        assert cmd in toggles


def test_disabled_placeholder_is_action():
    # The Color panel's "Create New Swatch..." row has no action and is
    # gated off (disabled: true); the builder surfaces it as an Action with
    # an empty command (a disabled placeholder).
    items = menu_items_from_yaml("color_panel_content")
    labels = [i.label for i in items if i.kind == PanelMenuItemKind.ACTION]
    assert "Create New Swatch..." in labels


def test_push_recent_color_basic():
    class _M:
        recent_colors = []

    m = _M()
    m.recent_colors = []
    push_recent_color("#ff0000", m)
    assert m.recent_colors == ["#ff0000"]
    push_recent_color("#00ff00", m)
    assert m.recent_colors == ["#00ff00", "#ff0000"]
    push_recent_color("#ff0000", m)  # move-to-front dedup
    assert m.recent_colors == ["#ff0000", "#00ff00"]


def test_push_recent_color_caps_at_10():
    class _M:
        recent_colors = []

    m = _M()
    m.recent_colors = []
    for i in range(15):
        push_recent_color(f"#0000{i:02x}", m)
    assert len(m.recent_colors) == 10
    # Newest first
    assert m.recent_colors[0] == "#00000e"


def test_recent_colors_listener_fires():
    class _M:
        recent_colors = []

    seen = []

    def _listener(model, hex_str):
        seen.append((id(model), hex_str, list(model.recent_colors)))

    add_recent_colors_listener(_listener)
    try:
        m = _M()
        m.recent_colors = []
        push_recent_color("#abcdef", m)
        assert seen == [(id(m), "#abcdef", ["#abcdef"])]
    finally:
        _recent_colors_listeners.remove(_listener)


def test_recent_colors_listener_exception_swallowed():
    """A buggy listener must not break push_recent_color for others."""
    class _M:
        recent_colors = []

    def _bad(_model, _hex):
        raise RuntimeError("boom")

    seen = []

    def _good(_model, hex_str):
        seen.append(hex_str)

    add_recent_colors_listener(_bad)
    add_recent_colors_listener(_good)
    try:
        m = _M()
        m.recent_colors = []
        push_recent_color("#123456", m)
        assert seen == ["#123456"]
    finally:
        _recent_colors_listeners.remove(_bad)
        _recent_colors_listeners.remove(_good)


def test_panel_label_all_kinds():
    assert panel_label(PanelKind.LAYERS) == "Layers"
    assert panel_label(PanelKind.COLOR) == "Color"
    assert panel_label(PanelKind.SWATCHES) == "Swatches"
    assert panel_label(PanelKind.STROKE) == "Stroke"
    assert panel_label(PanelKind.PROPERTIES) == "Properties"


def test_all_panel_kinds_count():
    assert len(ALL_PANEL_KINDS) == 13


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
    assert PanelKind.BOOLEAN in ALL_PANEL_KINDS
    assert PanelKind.OPACITY in ALL_PANEL_KINDS
    assert PanelKind.MAGIC_WAND in ALL_PANEL_KINDS
    assert PanelKind.SYMBOLS in ALL_PANEL_KINDS


def test_panel_label_opacity():
    assert panel_label(PanelKind.OPACITY) == "Opacity"


def test_opacity_menu_has_ten_spec_items_plus_close():
    items = panel_menu(PanelKind.OPACITY)
    seps = sum(1 for it in items if it.kind == PanelMenuItemKind.SEPARATOR)
    others = len(items) - seps
    assert seps == 4
    assert others == 11


def test_opacity_menu_has_four_panel_local_toggles():
    items = panel_menu(PanelKind.OPACITY)
    toggle_cmds = [it.command for it in items if it.kind == PanelMenuItemKind.TOGGLE]
    assert "toggle_opacity_thumbnails" in toggle_cmds
    assert "toggle_opacity_options" in toggle_cmds
    assert "toggle_new_masks_clipping" in toggle_cmds
    assert "toggle_new_masks_inverted" in toggle_cmds


def test_opacity_menu_mask_lifecycle_actions_in_order():
    # Menu data is now read from workspace/panels/opacity.yaml (the source
    # of truth). The YAML carries two page-level rows
    # (toggle_page_isolated_blending / toggle_page_knockout_group) that the
    # old hand-written native copy dropped; they have no checked_when, so
    # the builder maps them to plain actions. They sit between the four
    # mask-lifecycle actions and the closing Close Opacity action.
    items = panel_menu(PanelKind.OPACITY)
    action_cmds = [it.command for it in items if it.kind == PanelMenuItemKind.ACTION]
    assert action_cmds == [
        "make_opacity_mask",
        "release_opacity_mask",
        "disable_opacity_mask",
        "unlink_opacity_mask",
        "toggle_page_isolated_blending",
        "toggle_page_knockout_group",
        "close_panel",
    ]


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
    # Close labels now come from each panel YAML's menu (the source of
    # truth). Most read "Close <PanelName>", but the labels are owned by
    # the YAML — e.g. the Properties panel's summary is "Object properties"
    # so its close row reads "Close Object properties". Assert the generic
    # invariant the menu actually guarantees: every panel exposes a
    # close_panel action whose label starts with "Close".
    for kind in ALL_PANEL_KINDS:
        items = panel_menu(kind)
        close_item = next(
            (i for i in items if i.kind == PanelMenuItemKind.ACTION and i.command == "close_panel"),
            None,
        )
        assert close_item is not None
        assert close_item.label.startswith("Close "), (
            f"{kind} close label {close_item.label!r} should start with 'Close '"
        )


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


# ---------------------------------------------------------------------------
# Phase B: Artboard effect handlers — ARTBOARDS.md §Menu
# ---------------------------------------------------------------------------


def _make_model_with_artboards(artboards):
    """Build a Model whose document has the given artboards tuple."""
    from document.document import Document
    from document.model import Model
    doc = Document(artboards=tuple(artboards))
    return Model(document=doc)


def test_new_artboard_creates_and_appends():
    from document.artboard import Artboard
    from jas.panels.panel_menu import _dispatch_yaml_layers_action
    model = _make_model_with_artboards([Artboard.default_with_id("aaaaaaaa")])
    _dispatch_yaml_layers_action("new_artboard", model,
                                  artboards_panel_selection=[])
    assert len(model.document.artboards) == 2
    new_ab = model.document.artboards[1]
    assert new_ab.id != "aaaaaaaa"
    assert new_ab.name == "Artboard 2"
    # Empty selection → offset (0,0) — spec says position (0,0)
    assert new_ab.x == 0.0 and new_ab.y == 0.0


def test_new_artboard_offsets_from_current():
    import dataclasses
    from document.artboard import Artboard
    from jas.panels.panel_menu import _dispatch_yaml_layers_action
    src = dataclasses.replace(
        Artboard.default_with_id("src00000"),
        name="Artboard 1", x=100.0, y=50.0, width=200.0, height=300.0,
    )
    model = _make_model_with_artboards([src])
    _dispatch_yaml_layers_action("new_artboard", model,
                                  artboards_panel_selection=["src00000"])
    assert len(model.document.artboards) == 2
    new_ab = model.document.artboards[1]
    # Inherits size from current, offsets (20,20) from its top-left
    assert new_ab.x == 120.0
    assert new_ab.y == 70.0
    assert new_ab.width == 200.0
    assert new_ab.height == 300.0


def test_delete_artboards_removes_by_id():
    import dataclasses
    from document.artboard import Artboard
    from jas.panels.panel_menu import _dispatch_yaml_layers_action
    a = dataclasses.replace(Artboard.default_with_id("aaaaaaaa"), name="Artboard 1")
    b = dataclasses.replace(Artboard.default_with_id("bbbbbbbb"), name="Artboard 2")
    c = dataclasses.replace(Artboard.default_with_id("cccccccc"), name="Artboard 3")
    model = _make_model_with_artboards([a, b, c])
    _dispatch_yaml_layers_action("delete_artboards", model,
                                  artboards_panel_selection=["bbbbbbbb"])
    assert len(model.document.artboards) == 2
    assert [a.id for a in model.document.artboards] == ["aaaaaaaa", "cccccccc"]


def test_duplicate_artboards_offsets_and_renames():
    import dataclasses
    from document.artboard import Artboard
    from jas.panels.panel_menu import _dispatch_yaml_layers_action
    a = dataclasses.replace(
        Artboard.default_with_id("aaaaaaaa"),
        name="Artboard 1", x=50.0, y=30.0, width=100.0, height=200.0,
    )
    model = _make_model_with_artboards([a])
    _dispatch_yaml_layers_action("duplicate_artboards", model,
                                  artboards_panel_selection=["aaaaaaaa"])
    assert len(model.document.artboards) == 2
    dup = model.document.artboards[1]
    assert dup.id != "aaaaaaaa"
    assert dup.name == "Artboard 2"
    assert dup.x == 70.0  # 50 + 20
    assert dup.y == 50.0  # 30 + 20
    assert dup.width == 100.0
    assert dup.height == 200.0


def test_confirm_artboard_rename_sets_name():
    import dataclasses
    from document.artboard import Artboard
    from jas.panels.panel_menu import _dispatch_yaml_layers_action
    a = dataclasses.replace(Artboard.default_with_id("aaaaaaaa"), name="Old")
    model = _make_model_with_artboards([a])
    _dispatch_yaml_layers_action(
        "confirm_artboard_rename", model,
        params={"artboard_id": "aaaaaaaa", "new_name": "Cover"},
    )
    assert model.document.artboards[0].name == "Cover"


def test_move_artboards_up_canonical_skip_selected():
    """{1,3,5} → [1,3,2,5,4] — ARTBOARDS.md §Reordering."""
    import dataclasses
    from document.artboard import Artboard
    from jas.panels.panel_menu import _dispatch_yaml_layers_action
    ids = ["a", "b", "c", "d", "e"]
    abs_ = [
        dataclasses.replace(Artboard.default_with_id(id_), name=f"A{i}")
        for i, id_ in enumerate(ids)
    ]
    model = _make_model_with_artboards(abs_)
    # Selection {1,3,5} means indices 0, 2, 4 (ids a, c, e)
    _dispatch_yaml_layers_action("move_artboard_up", model,
                                  artboards_panel_selection=["a", "c", "e"])
    # a was at 0 (no swap), c was at 2 → swap with b → order a,c,b,d,e;
    # e was at 4 → swap with d → a,c,b,e,d
    assert [a.id for a in model.document.artboards] == ["a", "c", "b", "e", "d"]


def test_move_artboards_down_canonical():
    """Symmetric: {0,2,4} → [1,0,3,2,4] (canonical from Rust tests)."""
    import dataclasses
    from document.artboard import Artboard
    from jas.panels.panel_menu import _dispatch_yaml_layers_action
    ids = ["a", "b", "c", "d", "e"]
    abs_ = [
        dataclasses.replace(Artboard.default_with_id(id_), name=f"A{i}")
        for i, id_ in enumerate(ids)
    ]
    model = _make_model_with_artboards(abs_)
    # Selection on a (0), c (2), e (4). Move Down: iterate bottom-up:
    #   i=4 (e): already at end → skip
    #   i=2 (c): swap with d → a,b,d,c,e
    #   i=0 (a): swap with b → b,a,d,c,e
    _dispatch_yaml_layers_action("move_artboard_down", model,
                                  artboards_panel_selection=["a", "c", "e"])
    assert [a.id for a in model.document.artboards] == ["b", "a", "d", "c", "e"]


def test_artboards_menu_has_expected_entries():
    """Hardcoded Artboards menu mirrors workspace/panels/artboards.yaml."""
    items = panel_menu(PanelKind.ARTBOARDS)
    labels = [i.label for i in items if i.kind == PanelMenuItemKind.ACTION]
    assert "New Artboard" in labels
    assert "Duplicate Artboards" in labels
    assert "Delete Artboards" in labels
    assert "Rename" in labels
    assert "Delete Empty Artboards" in labels
    assert "Convert to Artboards" in labels
    assert "Artboard Options..." in labels
    assert "Rearrange..." in labels
    assert "Reset Panel" in labels
    assert "Close Artboards" in labels


def test_artboard_options_toggle_fade():
    import dataclasses
    from document.artboard import Artboard
    from jas.panels.panel_menu import _dispatch_yaml_layers_action
    a = dataclasses.replace(Artboard.default_with_id("aaaaaaaa"), name="A")
    model = _make_model_with_artboards([a])
    assert model.document.artboard_options.fade_region_outside_artboard is True
    # artboard_options_confirm sets both fields from params — simulate by
    # directly invoking the set_artboard_options_field effect via the
    # handler registration. Use a thin YAML-action we know exists:
    # artboard_options_confirm reads params.fade_region_outside_artboard.
    _dispatch_yaml_layers_action(
        "artboard_options_confirm", model,
        params={
            "artboard_id": "aaaaaaaa",
            "name": "A",
            "x_stored": 0.0,
            "y_stored": 0.0,
            "width": 612.0,
            "height": 792.0,
            "fill": "transparent",
            "show_center_mark": False,
            "show_cross_hairs": False,
            "show_video_safe_areas": False,
            "video_ruler_pixel_aspect_ratio": 1.0,
            "fade_region_outside_artboard": False,
            "update_while_dragging": True,
        },
    )
    assert model.document.artboard_options.fade_region_outside_artboard is False
    assert model.document.artboard_options.update_while_dragging is True


# ---------------------------------------------------------------------------
# Opacity panel — new_masks_* State_store plumbing (Track A)
# ---------------------------------------------------------------------------


def _opacity_test_addr(layout):
    """Return a PanelAddr pointing at the first panel in the first
    group of the right dock — sufficient for close_panel dispatch; the
    Opacity toggle / make-mask dispatches don't consult ``addr``."""
    dock = layout.anchored_dock(DockEdge.RIGHT)
    return PanelAddr(group=GroupAddr(dock_id=dock.id, group_idx=0), panel_idx=0)


def test_opacity_toggle_new_masks_clipping_flips_store():
    from workspace_interpreter.state_store import StateStore
    from panels.panel_menu import set_opacity_store
    layout = WorkspaceLayout.default_layout()
    addr = _opacity_test_addr(layout)
    store = StateStore()
    store.init_panel("opacity_panel_content", {
        "new_masks_clipping": True,
        "new_masks_inverted": False,
        "thumbnails_hidden": False,
        "options_shown": False,
    })
    set_opacity_store(store)
    try:
        # Defaults (before any toggle): checked reflects stored True.
        assert panel_is_checked(PanelKind.OPACITY, "toggle_new_masks_clipping", layout) is True
        panel_dispatch(PanelKind.OPACITY, "toggle_new_masks_clipping", addr, layout)
        assert panel_is_checked(PanelKind.OPACITY, "toggle_new_masks_clipping", layout) is False
        panel_dispatch(PanelKind.OPACITY, "toggle_new_masks_clipping", addr, layout)
        assert panel_is_checked(PanelKind.OPACITY, "toggle_new_masks_clipping", layout) is True
    finally:
        set_opacity_store(None)


def test_opacity_make_mask_reads_live_new_masks_flags():
    from dataclasses import replace
    from document.model import Model
    from document.document import ElementSelection
    from geometry.element import Rect, Layer
    from workspace_interpreter.state_store import StateStore
    from panels.panel_menu import set_opacity_store

    layout = WorkspaceLayout.default_layout()
    addr = _opacity_test_addr(layout)

    # Seed the store with non-default flags so the dispatch can be
    # shown to read the live values, not hardcoded spec defaults.
    store = StateStore()
    store.init_panel("opacity_panel_content", {
        "new_masks_clipping": False,
        "new_masks_inverted": True,
    })
    set_opacity_store(store)
    try:
        model = Model()
        rect = Rect(x=0.0, y=0.0, width=10.0, height=10.0)
        layer = Layer(name="L", children=(rect,))
        model.set_document_unbracketed(replace(
            model.document,
            layers=(layer,),
            selection=frozenset({ElementSelection.all((0, 0))}),
        ))
        panel_dispatch(PanelKind.OPACITY, "make_opacity_mask", addr, layout, model=model)
        mask = model.document.get_element((0, 0)).mask
        assert mask is not None, "make_opacity_mask did not create a mask"
        assert mask.clip is False
        assert mask.invert is True
    finally:
        set_opacity_store(None)


# ── Character panel hamburger toggles ────────────────────────────────

def _character_test_addr(layout):
    """Locate the right dock for character-toggle test fixtures."""
    dock = layout.anchored_dock(DockEdge.RIGHT)
    return PanelAddr(group=GroupAddr(dock_id=dock.id, group_idx=0), panel_idx=0)


def _seed_character_store():
    """Build a StateStore with a fully-initialised character panel
    scope so apply_character_panel_to_selection has every key it
    reads. Mirrors the YAML defaults from workspace/panels/
    character.yaml's state block."""
    from workspace_interpreter.state_store import StateStore
    store = StateStore()
    store.init_panel("character_panel_content", {
        "font_family": "sans-serif", "font_size": 16.0,
        "style_name": "Regular", "leading": 19.2, "tracking": 0.0,
        "kerning": "Auto",
        "vertical_scale": 100.0, "horizontal_scale": 100.0,
        "baseline_shift": 0.0, "character_rotation": 0.0,
        "all_caps": False, "small_caps": False,
        "superscript": False, "subscript": False,
        "underline": False, "strikethrough": False,
        "language": "", "anti_aliasing": "Sharp",
        "snap_to_glyph_visible": True,
    })
    return store


def _model_with_selected_text():
    """Model whose document has a single Text element selected at
    (0, 0)."""
    from dataclasses import replace
    from document.model import Model
    from document.document import ElementSelection
    from geometry.element import Text, Layer
    model = Model()
    text = Text(x=0.0, y=0.0, content="hi")
    layer = Layer(name="L", children=(text,))
    model.set_document_unbracketed(replace(
        model.document,
        layers=(layer,),
        selection=frozenset({ElementSelection.all((0, 0))}),
    ))
    return model


def test_character_toggle_all_caps_flips_and_applies():
    from panels.panel_menu import set_character_store
    layout = WorkspaceLayout.default_layout()
    addr = _character_test_addr(layout)
    store = _seed_character_store()
    set_character_store(store)
    try:
        model = _model_with_selected_text()
        panel_dispatch(PanelKind.CHARACTER, "toggle_all_caps", addr, layout, model=model)
        assert panel_is_checked(PanelKind.CHARACTER, "toggle_all_caps", layout)
        elem = model.document.get_element((0, 0))
        assert elem.text_transform == "uppercase"
    finally:
        set_character_store(None)


def test_character_toggle_all_caps_clears_small_caps():
    from panels.panel_menu import set_character_store
    layout = WorkspaceLayout.default_layout()
    addr = _character_test_addr(layout)
    store = _seed_character_store()
    store.set_panel("character_panel_content", "small_caps", True)
    set_character_store(store)
    try:
        model = _model_with_selected_text()
        panel_dispatch(PanelKind.CHARACTER, "toggle_all_caps", addr, layout, model=model)
        assert panel_is_checked(PanelKind.CHARACTER, "toggle_all_caps", layout)
        assert not panel_is_checked(PanelKind.CHARACTER, "toggle_small_caps", layout)
    finally:
        set_character_store(None)


def test_character_toggle_super_clears_sub():
    from panels.panel_menu import set_character_store
    layout = WorkspaceLayout.default_layout()
    addr = _character_test_addr(layout)
    store = _seed_character_store()
    store.set_panel("character_panel_content", "subscript", True)
    set_character_store(store)
    try:
        model = _model_with_selected_text()
        panel_dispatch(PanelKind.CHARACTER, "toggle_superscript", addr, layout, model=model)
        assert panel_is_checked(PanelKind.CHARACTER, "toggle_superscript", layout)
        assert not panel_is_checked(PanelKind.CHARACTER, "toggle_subscript", layout)
    finally:
        set_character_store(None)


def test_character_toggle_snap_visibility_does_not_apply_to_selection():
    # Show Snap to Glyph Options is purely panel-local UI state;
    # flipping it must not push attribute writes onto the selected
    # text element.
    from panels.panel_menu import set_character_store
    layout = WorkspaceLayout.default_layout()
    addr = _character_test_addr(layout)
    store = _seed_character_store()
    set_character_store(store)
    try:
        model = _model_with_selected_text()
        before = model.document
        panel_dispatch(PanelKind.CHARACTER, "toggle_snap_to_glyph_visible",
                       addr, layout, model=model)
        assert not panel_is_checked(
            PanelKind.CHARACTER, "toggle_snap_to_glyph_visible", layout)
        assert model.document is before
    finally:
        set_character_store(None)


# ── Paragraph panel hamburger menu ──────────────────────────


def _seed_paragraph_store():
    """StateStore with a fully-initialised paragraph_panel_content
    scope so set_paragraph_panel_field has every key it reads.
    Mirrors the YAML defaults in workspace/panels/paragraph.yaml."""
    from workspace_interpreter.state_store import StateStore
    store = StateStore()
    store.init_panel("paragraph_panel_content", {
        "text_selected": True, "area_text_selected": True,
        "align_left": True, "align_center": False,
        "align_right": False, "justify_left": False,
        "justify_center": False, "justify_right": False,
        "justify_all": False,
        "left_indent": 0, "right_indent": 0,
        "first_line_indent": 0,
        "space_before": 0, "space_after": 0,
        "hyphenate": False, "hanging_punctuation": False,
        "bullets": "", "numbered_list": "",
    })
    return store


def _model_with_area_text_wrapper():
    from dataclasses import replace
    from document.model import Model
    from document.document import ElementSelection
    from geometry.element import Text, Layer
    from geometry.tspan import Tspan
    wrapper = Tspan(id=0, content="", jas_role="paragraph")
    body = Tspan(id=1, content="hello")
    text = Text(x=0, y=0, content="hello", tspans=(wrapper, body),
                font_family="sans-serif", font_size=12,
                width=200, height=100)
    model = Model()
    layer = Layer(name="L", children=(text,))
    model.set_document_unbracketed(replace(
        model.document,
        layers=(layer,),
        selection=frozenset({ElementSelection.all((0, 0))}),
    ))
    return model


def test_paragraph_menu_has_hamburger_items():
    items = panel_menu(PanelKind.PARAGRAPH)
    labels = [i.label for i in items
              if i.kind != PanelMenuItemKind.SEPARATOR]
    assert "Hanging Punctuation" in labels
    assert "Justification…" in labels
    assert "Hyphenation…" in labels
    assert "Reset Panel" in labels
    assert "Close Paragraph" in labels


def test_paragraph_toggle_hanging_punctuation_flips_panel_state():
    from panels.panel_menu import set_paragraph_store
    layout = WorkspaceLayout.default_layout()
    addr = _character_test_addr(layout)  # any addr works for dispatch
    store = _seed_paragraph_store()
    set_paragraph_store(store)
    try:
        model = _model_with_area_text_wrapper()
        panel_dispatch(PanelKind.PARAGRAPH, "toggle_hanging_punctuation",
                       addr, layout, model=model)
        assert panel_is_checked(
            PanelKind.PARAGRAPH, "toggle_hanging_punctuation", layout)
        # And applies the panel state to the wrapper.
        elem = model.document.get_element((0, 0))
        assert elem.tspans[0].jas_hanging_punctuation is True
    finally:
        set_paragraph_store(None)


def test_paragraph_reset_panel_clears_wrapper_attrs():
    from panels.panel_menu import set_paragraph_store
    layout = WorkspaceLayout.default_layout()
    addr = _character_test_addr(layout)
    store = _seed_paragraph_store()
    store.set_panel("paragraph_panel_content", "left_indent", 24.0)
    store.set_panel("paragraph_panel_content", "hyphenate", True)
    set_paragraph_store(store)
    try:
        model = _model_with_area_text_wrapper()
        # Push the panel state to the wrapper first.
        from panels.paragraph_panel_state import (
            apply_paragraph_panel_to_selection,
        )
        apply_paragraph_panel_to_selection(store, model)
        # Now reset.
        panel_dispatch(PanelKind.PARAGRAPH, "reset_paragraph_panel",
                       addr, layout, model=model)
        elem = model.document.get_element((0, 0))
        w = elem.tspans[0]
        assert w.jas_left_indent is None
        assert w.jas_hyphenate is None
        # Panel-state values reset to defaults.
        assert store.get_panel("paragraph_panel_content", "left_indent") == 0
        assert store.get_panel("paragraph_panel_content", "hyphenate") is False
    finally:
        set_paragraph_store(None)
