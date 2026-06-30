"""Menubar for Jas application.

The top menu bar is rendered from the compiled bundle ``menubar``
(menubar.yaml, projected by :mod:`menu.menu_model`) so it can never drift
from the spec. :func:`create_menus` loops the projected model and binds each
entry to a bespoke native handler via the central :func:`_on_menu_action`
router — the migration changed the menu's DATA SOURCE + wiring, not the
handler behavior. Mirrors the Rust ``menu_bar.rs`` dispatch that preserves
every bespoke native handler and only sources structure from the bundle.

Native handlers are PRESERVED unchanged: file dialogs, clipboard,
reference-aware orphan-confirm modals, the Document Setup / Print YAML
dialogs, PDF export, the dynamic Workspace / Appearance submenus, the layout
pane / panel toggles + their checkmark machinery. ``enabled_when`` from the
bundle is carried but NOT evaluated — enable/disable stays native (the Revert
``aboutToShow`` gate and the checkable panel toggles), same as Rust v1.
"""

from PySide6.QtGui import QKeySequence
from PySide6.QtWidgets import QApplication, QFileDialog, QMainWindow, QMessageBox

from document.model import Model
from document.op_apply import op_apply
from tools.tool import PASTE_OFFSET


def _zoom_step() -> float:
    """Read ``preferences.viewport.zoom_step`` from the compiled bundle
    (falls back to 1.2). The View zoom family stays NATIVE because the
    generic ``doc.zoom.*`` effect path cannot resolve
    ``preferences.viewport.zoom_step`` in the menu dispatch context (it
    evaluates to NULL, collapsing the zoom factor to 0)."""
    try:
        from panels.yaml_menu import get_workspace_data
        ws = get_workspace_data() or {}
        return float(ws.get("preferences", {}).get("viewport", {})
                     .get("zoom_step", 1.2))
    except Exception:
        return 1.2


def _fit_padding() -> float:
    """Read ``preferences.viewport.fit_padding_px`` from the bundle."""
    try:
        from panels.yaml_menu import get_workspace_data
        ws = get_workspace_data() or {}
        return float(ws.get("preferences", {}).get("viewport", {})
                     .get("fit_padding_px", 20.0))
    except Exception:
        return 20.0


def _canvas_update(window: QMainWindow) -> None:
    canvas = (window.tab_widget.currentWidget()
              if hasattr(window, "tab_widget") else None)
    if canvas is not None and hasattr(canvas, "update"):
        canvas.update()


def _bump_zoom(window: QMainWindow, factor: float) -> None:
    """Zoom about the viewport center by ``factor`` (native View handler)."""
    m = window.active_model()
    if m is None:
        return
    cx = m.viewport_w / 2.0
    cy = m.viewport_h / 2.0
    z = m.zoom_level
    doc_cx = (cx - m.view_offset_x) / z if z else 0
    doc_cy = (cy - m.view_offset_y) / z if z else 0
    z2 = max(0.1, min(64.0, z * factor))
    m.zoom_level = z2
    m.view_offset_x = cx - doc_cx * z2
    m.view_offset_y = cy - doc_cy * z2
    _canvas_update(window)


def _zoom_actual_size(window: QMainWindow) -> None:
    """View > Actual Size: set zoom to 1.0 (clamped), keep center."""
    m = window.active_model()
    if m is None:
        return
    cx = m.viewport_w / 2.0
    cy = m.viewport_h / 2.0
    z = m.zoom_level
    doc_cx = (cx - m.view_offset_x) / z if z else 0
    doc_cy = (cy - m.view_offset_y) / z if z else 0
    z2 = max(0.1, min(64.0, 1.0))
    m.zoom_level = z2
    m.view_offset_x = cx - doc_cx * z2
    m.view_offset_y = cy - doc_cy * z2
    _canvas_update(window)


def _fit_rect_into_viewport(m, x: float, y: float, w: float, h: float,
                            padding: float) -> bool:
    """Write the zoom + pan that fits rect (x,y,w,h) into the viewport with
    ``padding`` px on each side. Returns False (no change) for an empty rect
    or viewport."""
    if w <= 0 or h <= 0 or m.viewport_w <= 0 or m.viewport_h <= 0:
        return False
    avail_w = m.viewport_w - 2.0 * padding
    avail_h = m.viewport_h - 2.0 * padding
    if avail_w <= 0 or avail_h <= 0:
        return False
    z = max(0.1, min(64.0, min(avail_w / w, avail_h / h)))
    rect_cx = x + w / 2.0
    rect_cy = y + h / 2.0
    m.zoom_level = z
    m.view_offset_x = m.viewport_w / 2.0 - rect_cx * z
    m.view_offset_y = m.viewport_h / 2.0 - rect_cy * z
    return True


def _fit_active_artboard(window: QMainWindow) -> None:
    """View > Fit Artboard in Window: fit the current artboard rect."""
    m = window.active_model()
    if m is None:
        return
    artboards = list(m.document.artboards)
    if not artboards:
        return
    ab = artboards[0]
    _fit_rect_into_viewport(m, float(ab.x), float(ab.y),
                            float(ab.width), float(ab.height), _fit_padding())
    _canvas_update(window)


def _fit_all_artboards(window: QMainWindow) -> None:
    """View > Fit All in Window: fit the union of all artboard rects."""
    m = window.active_model()
    if m is None:
        return
    artboards = list(m.document.artboards)
    if not artboards:
        return
    min_x = min(float(ab.x) for ab in artboards)
    min_y = min(float(ab.y) for ab in artboards)
    max_x = max(float(ab.x + ab.width) for ab in artboards)
    max_y = max(float(ab.y + ab.height) for ab in artboards)
    _fit_rect_into_viewport(m, min_x, min_y, max_x - min_x, max_y - min_y,
                            _fit_padding())
    _canvas_update(window)


def _fit_in_window(window: QMainWindow) -> None:
    """View > Fit in Window: center on the current artboard (matches the
    pre-migration native behavior of the Ctrl+0 entry)."""
    m = window.active_model()
    if m is None:
        return
    m.center_view_on_current_artboard()
    _canvas_update(window)


def _new_doc(window: QMainWindow) -> None:
    # Document() defaults artboards=(); seed the at-least-one-artboard
    # invariant so a fresh canvas opens with a visible white artboard
    # rather than a featureless gray pasteboard.
    from document.document import Document
    from document.artboard import ensure_artboards_invariant
    abs_, _ = ensure_artboards_invariant(())
    doc = Document(artboards=abs_)
    window.add_canvas(Model(document=doc))


# Bundle action -> bespoke native handler. Each handler takes
# (window, model_or_none, params) and routes to the SAME private
# function the hand-built menu used; behavior is unchanged. Actions that
# need an active model resolve it inside the handler (no-op when absent),
# preserving the old `_with_model` guard.
def _on_menu_action(window: QMainWindow, action: str, params: dict) -> bool:
    """Central menu-action router. Every menubar action is backed by a
    bespoke native handler (the actions.yaml entries are ``log`` / ``if``
    stubs whose real behavior lives natively, so routing them through the
    generic dispatcher would no-op them). ``params`` carries the bundle's
    ``params`` (e.g. ``{"panel": "color"}``).

    Returns ``True`` when ``action`` matched a native arm, ``False``
    otherwise — so a name-driven caller (e.g. the test-only FIFO ``action``
    channel) can fall back to the generic panel dispatcher for genuine
    panel actions instead of silently dropping unknown names."""
    m = window.active_model()

    # --- File ---
    if action == "new_document":
        _new_doc(window)
    elif action == "open_file":
        _open_file(window)
    elif action == "save":
        _save(window, m)
    elif action == "save_as":
        _save_as(window, m)
    elif action == "revert":
        _revert(window, m)
    elif action == "open_document_setup":
        _open_yaml_dialog(window, "document_setup")
    elif action == "open_print_dialog":
        _open_yaml_dialog(window, "print")
    elif action == "export_to_pdf":
        # The only menubar action with no actions.yaml entry — bespoke.
        _export_to_pdf(window, m)
    elif action == "quit":
        window.close()

    # --- Edit ---
    elif action == "undo":
        if m:
            m.undo()
    elif action == "redo":
        if m:
            m.redo()
    elif action == "cut":
        if m:
            _cut_selection(m, window)
    elif action == "copy":
        if m:
            _copy_selection(m)
    elif action == "paste":
        if m:
            _paste_clipboard(m, PASTE_OFFSET)
    elif action == "paste_in_place":
        if m:
            _paste_clipboard(m, 0.0)
    elif action == "select_all":
        if m:
            _select_all(m)

    # --- Object ---
    elif action == "group":
        if m:
            _group_selection(m)
    elif action == "ungroup":
        if m:
            _ungroup_selection(m)
    elif action == "ungroup_all":
        if m:
            _ungroup_all(m)
    elif action == "lock":
        if m:
            _lock_selection(m)
    elif action == "unlock_all":
        if m:
            _unlock_all(m)
    elif action == "hide_selection":
        if m:
            _hide_selection(m)
    elif action == "show_all":
        if m:
            _show_all(m)
    elif action == "make_instance":
        if m:
            _link_to_selection(m)
    elif action == "promote_to_concept":
        if m:
            _promote_to_concept(m)

    # --- View (native; generic doc.zoom.* path cannot resolve prefs here) ---
    elif action == "zoom_in":
        _bump_zoom(window, _zoom_step())
    elif action == "zoom_out":
        _bump_zoom(window, 1.0 / _zoom_step())
    elif action == "zoom_to_actual_size":
        _zoom_actual_size(window)
    elif action == "fit_active_artboard":
        _fit_active_artboard(window)
    elif action == "fit_all_artboards":
        _fit_all_artboards(window)
    elif action == "fit_in_window":
        _fit_in_window(window)

    # --- Window: layout (native pane/panel/tile machinery) ---
    elif action == "tile_panes":
        _tile_panes(window)
    elif action == "toggle_pane":
        _toggle_pane_by_name(window, params.get("pane", ""))
    elif action == "toggle_panel":
        _toggle_panel_by_name(window, params.get("panel", ""))
    else:
        return False
    return True


def create_menus(window: QMainWindow) -> None:
    """Build the top menu bar from the compiled bundle ``menubar``.

    Loops the projected :func:`menu.menu_model.build_menu_model` model: each
    top-level menu becomes ``menuBar().addMenu(label)``; each action becomes
    ``addAction(label)`` (the ``&`` mnemonic markers are kept VERBATIM — Qt
    consumes ``&`` as its native accelerator marker); shortcuts pass straight
    to ``QKeySequence`` (Qt parses ``"Ctrl+Shift+S"`` / ``"Ctrl+="`` /
    ``"Ctrl+Alt+0"`` directly); ``triggered`` routes through
    :func:`_on_menu_action`. The dynamic Workspace / Appearance submenus and
    the checkable panel toggles are rebuilt by the bespoke code below.

    Args:
        window: The QMainWindow to add menus to (must have active_model()).
    """
    from menu.menu_model import (
        build_menu_model, MenuAction, MenuSeparator, MenuSubmenu, SubmenuKind,
    )

    menubar = window.menuBar()
    model = build_menu_model()

    # Map a bundle panel-toggle param -> PanelKind so the checkable panel
    # toggles can be tracked + re-synced (the bespoke checkmark machinery).
    from workspace.workspace_layout import PanelKind
    panel_param_to_kind = {
        "artboards": PanelKind.ARTBOARDS,
        "layers": PanelKind.LAYERS,
        "color": PanelKind.COLOR,
        "swatches": PanelKind.SWATCHES,
        "stroke": PanelKind.STROKE,
        "properties": PanelKind.PROPERTIES,
        "character": PanelKind.CHARACTER,
        "paragraph": PanelKind.PARAGRAPH,
        "align": PanelKind.ALIGN,
        "boolean": PanelKind.BOOLEAN,
        "magic_wand": PanelKind.MAGIC_WAND,
        "opacity": PanelKind.OPACITY,
        "symbols": PanelKind.SYMBOLS,
    }
    # PanelKind has no CONCEPTS member in some builds; resolve defensively
    # so the Concepts toggle still tracks its checkmark when present.
    concepts_kind = getattr(PanelKind, "CONCEPTS", None)
    if concepts_kind is not None:
        panel_param_to_kind["concepts"] = concepts_kind

    panel_menu_actions: dict = {}

    # Hold Python references to the created QMenu objects on the window so
    # PySide does not garbage-collect (and delete the underlying C++ object
    # of) the top-level dropdowns. Without this, the menus still render but
    # the QMenu wrappers can become stale "already deleted" handles.
    menu_objects: list = []
    window._menu_objects = menu_objects

    for top in model:
        qmenu = menubar.addMenu(top.label)
        menu_objects.append(qmenu)
        for entry in top.entries:
            if isinstance(entry, MenuSeparator):
                qmenu.addSeparator()
            elif isinstance(entry, MenuSubmenu):
                if entry.kind == SubmenuKind.WORKSPACE:
                    menu_objects.append(
                        _build_workspace_submenu(window, qmenu, entry.label))
                else:
                    menu_objects.append(
                        _build_appearance_submenu(window, qmenu, entry.label))
            elif isinstance(entry, MenuAction):
                act = qmenu.addAction(entry.label)
                if entry.shortcut:
                    act.setShortcut(QKeySequence(entry.shortcut))
                a_name = entry.action
                a_params = dict(entry.params)
                # Stamp the bundle action name on the QAction so the live-widget
                # reflection gate (menu_test.LiveMenuReflectionTest) can recover
                # which action each rendered item is wired to. Inert at runtime
                # (nothing else reads QAction.data); the trigger uses the closure.
                act.setData(a_name)
                act.triggered.connect(
                    lambda checked=False, n=a_name, p=a_params:
                    _on_menu_action(window, n, p))
                # Revert stays natively enable-gated (enabled_when carried in
                # the bundle but not evaluated — same as Rust v1).
                if a_name == "revert":
                    qmenu.aboutToShow.connect(
                        lambda mb=qmenu, ac=act: ac.setEnabled(
                            window.active_model() is not None
                            and window.active_model().is_modified
                            and not window.active_model().filename.startswith(
                                "Untitled-")))
                # Checkable panel toggles: track each by PanelKind so the
                # checkmark can be re-synced from layout state after any
                # change (close from header X, drag-out, layout restore).
                if a_name == "toggle_panel":
                    kind = panel_param_to_kind.get(a_params.get("panel"))
                    if kind is not None:
                        act.setCheckable(True)
                        panel_menu_actions[kind] = act

    def _sync_panel_menu_checks() -> None:
        if not hasattr(window, 'workspace_layout'):
            return
        layout = window.workspace_layout
        for k, a in panel_menu_actions.items():
            try:
                a.setChecked(layout.is_panel_visible(k))
            except Exception:
                pass

    # Stash the syncer on the window so dock_panel.rebuild can fire it after
    # a rebuild and external paths (drag-out, layout restore) flip the checks.
    window.sync_panel_menu_checks = _sync_panel_menu_checks
    _sync_panel_menu_checks()


def _tile_panes(window: QMainWindow) -> None:
    if not hasattr(window, 'workspace_layout'):
        return
    # 3d-2: route through the runtime layout dispatcher. panes_mut still owns
    # the dirty signal (the pane mutators do not bump themselves); layout_apply
    # mutates the same pane_layout the lambda would have.
    from workspace.layout_apply import layout_apply, op_tile_panes
    layout = window.workspace_layout
    layout.panes_mut(lambda pl: layout_apply(layout, op_tile_panes()))
    if hasattr(window, 'refresh_panes'):
        window.refresh_panes()


def _toggle_pane_by_name(window: QMainWindow, pane: str) -> None:
    from workspace.pane import PaneKind as PK
    kind = {"toolbar": PK.TOOLBAR, "dock": PK.DOCK}.get(pane)
    if kind is None:
        return
    _toggle_pane(window, kind)


def _toggle_pane(window: QMainWindow, kind) -> None:
    if not hasattr(window, 'workspace_layout'):
        return
    # 3d-2: route the resolved hide/show verb through the runtime dispatcher;
    # panes_mut owns the dirty signal (one bump).
    from workspace.layout_apply import layout_apply, op_hide_pane, op_show_pane
    layout = window.workspace_layout
    layout.panes_mut(lambda pl: layout_apply(
        layout,
        op_hide_pane(kind) if pl.is_pane_visible(kind) else op_show_pane(kind)))
    if hasattr(window, 'refresh_panes'):
        window.refresh_panes()


def _toggle_panel_by_name(window: QMainWindow, panel: str) -> None:
    from workspace.workspace_layout import PanelKind
    kind_map = {
        "artboards": PanelKind.ARTBOARDS, "layers": PanelKind.LAYERS,
        "color": PanelKind.COLOR, "swatches": PanelKind.SWATCHES,
        "stroke": PanelKind.STROKE, "properties": PanelKind.PROPERTIES,
        "character": PanelKind.CHARACTER, "paragraph": PanelKind.PARAGRAPH,
        "align": PanelKind.ALIGN, "boolean": PanelKind.BOOLEAN,
        "magic_wand": PanelKind.MAGIC_WAND, "opacity": PanelKind.OPACITY,
        "symbols": PanelKind.SYMBOLS,
    }
    concepts_kind = getattr(PanelKind, "CONCEPTS", None)
    if concepts_kind is not None:
        kind_map["concepts"] = concepts_kind
    kind = kind_map.get(panel)
    if kind is None:
        return
    _toggle_panel(window, kind)


def _toggle_panel(window: QMainWindow, kind) -> None:
    if not hasattr(window, 'workspace_layout'):
        return
    from workspace.workspace_layout import GroupAddr, PanelAddr
    # 3d-2: route the resolved panel verbs through the runtime dispatcher
    # (close_panel / show_panel bump internally — dirty signal preserved).
    from workspace.layout_apply import layout_apply, op_close_panel, op_show_panel
    layout = window.workspace_layout
    if layout.is_panel_visible(kind):
        # Find and close
        for _, dock in layout.anchored:
            for gi, group in enumerate(dock.groups):
                for pi, k in enumerate(group.panels):
                    if k == kind:
                        layout_apply(layout, op_close_panel(
                            PanelAddr(group=GroupAddr(dock_id=dock.id, group_idx=gi), panel_idx=pi)))
                        if hasattr(window, 'dock_panel'):
                            window.dock_panel.rebuild()
                        if hasattr(window, 'sync_panel_menu_checks'):
                            window.sync_panel_menu_checks()
                        return
    else:
        layout_apply(layout, op_show_panel(kind))
        if hasattr(window, 'dock_panel'):
            window.dock_panel.rebuild()
    if hasattr(window, 'sync_panel_menu_checks'):
        window.sync_panel_menu_checks()


def _build_workspace_submenu(window: QMainWindow, parent_menu, label: str):
    ws_menu = parent_menu.addMenu(label)

    def _rebuild_workspace_menu():
        from workspace.workspace_layout import WORKSPACE_LAYOUT_NAME
        ws_menu.clear()
        if not hasattr(window, 'workspace_layout') or not hasattr(window, 'app_config'):
            return
        config = window.app_config
        active_name = config.active_layout
        has_saved = active_name != WORKSPACE_LAYOUT_NAME
        # Saved layout entries (filter out "Workspace")
        visible = [n for n in config.saved_layouts if n != WORKSPACE_LAYOUT_NAME]
        for name in visible:
            prefix = "\u2713 " if name == active_name else "    "
            action = ws_menu.addAction(prefix + name)
            action.triggered.connect(lambda checked=False, n=name: _switch_layout(window, n))
        ws_menu.addSeparator()
        save_as_action = ws_menu.addAction("Save As\u2026")
        save_as_action.triggered.connect(lambda: _save_as(window))
        ws_menu.addSeparator()
        reset_action = ws_menu.addAction("Reset to Default")
        reset_action.triggered.connect(lambda: _reset_to_default(window))
        revert_action = ws_menu.addAction("Revert to Saved")
        revert_action.triggered.connect(lambda: _revert_to_saved(window))
        revert_action.setEnabled(has_saved)

    ws_menu.aboutToShow.connect(_rebuild_workspace_menu)
    return ws_menu


def _switch_appearance(window, name):
    if not hasattr(window, 'app_config'):
        return
    window.app_config.active_appearance = name
    window.app_config.save()
    if hasattr(window, 'refresh_theme'):
        window.refresh_theme()


def _build_appearance_submenu(window, parent_menu, label):
    appearance_menu = parent_menu.addMenu(label)

    def _rebuild_appearance_menu():
        from workspace.theme import PREDEFINED_APPEARANCES, resolve_appearance
        appearance_menu.clear()
        if not hasattr(window, 'app_config'):
            return
        config = window.app_config
        for entry in PREDEFINED_APPEARANCES:
            prefix = "\u2713 " if entry.name == config.active_appearance else "    "
            action = appearance_menu.addAction(prefix + entry.label)
            action.triggered.connect(
                lambda checked=False, n=entry.name: _switch_appearance(window, n))

    appearance_menu.aboutToShow.connect(_rebuild_appearance_menu)
    return appearance_menu


def _refresh(window):
    if hasattr(window, 'refresh_panes'):
        window.refresh_panes()
    elif hasattr(window, 'dock_panel'):
        window.dock_panel.rebuild()


def _switch_layout(window, name: str):
    from workspace.workspace_layout import WORKSPACE_LAYOUT_NAME, WorkspaceLayout
    if not hasattr(window, 'workspace_layout') or not hasattr(window, 'app_config'):
        return
    window.workspace_layout.save_to_file()
    loaded = WorkspaceLayout.load_from_file(name)
    loaded.name = WORKSPACE_LAYOUT_NAME
    window.workspace_layout = loaded
    window.app_config.active_layout = name
    window.app_config.active_appearance = loaded.appearance
    window.app_config.save()
    window.workspace_layout.save_to_file()
    if hasattr(window, 'refresh_theme'):
        window.refresh_theme(loaded.appearance)
    _refresh(window)


def _save_as(window):
    from PySide6.QtWidgets import QInputDialog, QMessageBox
    from workspace.workspace_layout import WORKSPACE_LAYOUT_NAME
    if not hasattr(window, 'workspace_layout') or not hasattr(window, 'app_config'):
        return
    config = window.app_config
    prefill = config.active_layout if config.active_layout != WORKSPACE_LAYOUT_NAME else ""
    name, ok = QInputDialog.getText(window, "Save Workspace As", "Workspace name:", text=prefill)
    if not ok or not name.strip():
        return
    name = name.strip()
    if name.lower() == WORKSPACE_LAYOUT_NAME.lower():
        QMessageBox.information(window, "Save Workspace",
            "\u201CWorkspace\u201D is a system workspace that is saved automatically.")
        return
    if name in config.saved_layouts:
        reply = QMessageBox.question(window, "Save Workspace",
            f"Layout \u201C{name}\u201D already exists. Overwrite?",
            QMessageBox.Yes | QMessageBox.No, QMessageBox.No)
        if reply != QMessageBox.Yes:
            return
    window.workspace_layout.appearance = config.active_appearance
    window.workspace_layout.save_as(name)
    config.register_layout(name)
    config.active_layout = name
    config.save()


def _reset_to_default(window):
    from workspace.workspace_layout import WORKSPACE_LAYOUT_NAME
    if not hasattr(window, 'workspace_layout') or not hasattr(window, 'app_config'):
        return
    window.workspace_layout.reset_to_default()
    window.workspace_layout.name = WORKSPACE_LAYOUT_NAME
    window.app_config.active_layout = WORKSPACE_LAYOUT_NAME
    window.app_config.save()
    window.workspace_layout.save_to_file()
    _refresh(window)


def _revert_to_saved(window):
    from workspace.workspace_layout import WORKSPACE_LAYOUT_NAME, WorkspaceLayout
    if not hasattr(window, 'workspace_layout') or not hasattr(window, 'app_config'):
        return
    config = window.app_config
    if config.active_layout == WORKSPACE_LAYOUT_NAME:
        return
    loaded = WorkspaceLayout.load_from_file(config.active_layout)
    loaded.name = WORKSPACE_LAYOUT_NAME
    window.workspace_layout = loaded
    window.workspace_layout.save_to_file()
    _refresh(window)


def _open_file(window: QMainWindow) -> None:
    """Show Open dialog and load an SVG file into a new canvas.

    If the file is already open in an existing tab, focus that tab
    instead of reading the file again.
    """
    from geometry.svg import svg_to_document

    path, _ = QFileDialog.getOpenFileName(
        window, "Open", "", "SVG Files (*.svg)")
    if not path:
        return
    # Check if a canvas for this file already exists
    from canvas.canvas import CanvasWidget
    for i in range(window.tab_widget.count()):
        canvas = window.tab_widget.widget(i)
        if isinstance(canvas, CanvasWidget) and canvas._model.filename == path:
            window.tab_widget.setCurrentIndex(i)
            return
    import os
    file_size = os.path.getsize(path)
    if file_size > 100 * 1024 * 1024:
        from PySide6.QtWidgets import QMessageBox
        QMessageBox.critical(window, "Error", "File too large (over 100 MB).")
        return
    with open(path, "r", encoding="utf-8") as f:
        svg = f.read()
    new_model = Model(document=svg_to_document(svg), filename=path)
    window.add_canvas(new_model)


def _revert(window: QMainWindow, model: Model | None) -> None:
    """Revert the document to the last saved version on disk."""
    if not model or not model.is_modified or model.filename.startswith("Untitled-"):
        return
    from PySide6.QtWidgets import QMessageBox
    reply = QMessageBox.warning(
        window,
        "Revert",
        f'Revert to the saved version of "{model.filename}"?\n\n'
        "All current modifications will be lost.",
        QMessageBox.Ok | QMessageBox.Cancel,
        QMessageBox.Cancel,
    )
    if reply != QMessageBox.Ok:
        return
    from geometry.svg import svg_to_document
    try:
        import os
        file_size = os.path.getsize(model.filename)
        if file_size > 100 * 1024 * 1024:
            QMessageBox.critical(window, "Error", "File too large (over 100 MB).")
            return
        with open(model.filename, "r", encoding="utf-8") as f:
            svg = f.read()
        # Reverting is an undoable edit (one self-bracketed undo step).
        model.edit_document(svg_to_document(svg))
        model.mark_saved()
    except Exception as e:
        QMessageBox.critical(window, "Error", str(e))


def _save(window: QMainWindow, model: Model | None) -> None:
    """Save the document. If no path yet, fall back to Save As."""
    if not model:
        return
    if model.filename.startswith("Untitled-"):
        _save_as(window, model)
        return
    from geometry.svg import document_to_svg
    svg = document_to_svg(model.document)
    with open(model.filename, "w", encoding="utf-8") as f:
        f.write(svg)
    model.mark_saved()


def _save_as(window: QMainWindow, model: Model) -> None:
    """Show Save As dialog and save the document as SVG."""
    from geometry.svg import document_to_svg

    path, _ = QFileDialog.getSaveFileName(
        window, "Save As", model.filename, "SVG Files (*.svg)")
    if not path:
        return
    svg = document_to_svg(model.document)
    with open(path, "w", encoding="utf-8") as f:
        f.write(svg)
    model.mark_saved()
    model.filename = path


def _pdf_filename_for(model: Model | None) -> str:
    """Strip the model's filename extension and append .pdf. Falls back
    to "Untitled.pdf" for empty / Untitled-N filenames."""
    if model is None:
        return "Untitled.pdf"
    name = (model.filename or "").strip()
    if not name or name.startswith("Untitled-"):
        return "Untitled.pdf"
    if "." in name:
        name = name.rsplit(".", 1)[0]
    return f"{name}.pdf"


def _export_to_pdf(window: QMainWindow, model: Model | None) -> None:
    """PRINT.md §1B File menu Export to PDF... entry. Generates a PDF
    via geometry.pdf.document_to_pdf and writes it to a user-chosen
    path."""
    if model is None:
        return
    from geometry.pdf import document_to_pdf
    bytes_ = document_to_pdf(model.document)
    path, _ = QFileDialog.getSaveFileName(
        window, "Export to PDF", _pdf_filename_for(model),
        "PDF Files (*.pdf)")
    if not path:
        return
    with open(path, "wb") as f:
        f.write(bytes_)


def _open_yaml_dialog(window: QMainWindow, dialog_id: str) -> None:
    """PRINT.md §1: open a YAML dialog (Document Setup, Print) from the
    File menu. Routes through ``show_yaml_dialog`` with the app's
    global state store, an ``active_document`` ctx so init
    expressions like ``active_document.print_preferences.copies``
    resolve to persisted document values, and a ``dispatch_fn`` that
    runs the YAML action's effects (snapshot, doc.set_*_field,
    close_dialog) — without it the OK button is a no-op."""
    model = window.active_model() if hasattr(window, "active_model") else None
    if model is None:
        return
    state_store = window.yaml_state() if hasattr(window, "yaml_state") else None
    if state_store is None:
        return
    from panels.yaml_dialog_view import show_yaml_dialog
    from panels.active_document_view import (
        build_active_document_view, sync_document_to_store,
    )
    from workspace_interpreter.loader import load_workspace
    from workspace_interpreter.effects import run_effects
    sync_document_to_store(model, state_store)
    ctx = {"active_document": build_active_document_view(model)}
    import os as _os
    ws_path = _os.path.join(_os.path.dirname(__file__), "..", "..", "workspace")
    ws = load_workspace(ws_path)
    actions_catalog = ws.get("actions", {}) if ws else {}
    dialogs_catalog = ws.get("dialogs", {}) if ws else {}
    platform_effects = _build_dialog_platform_effects(model)
    def _dispatch(action_name: str, params: dict) -> None:
        action_def = actions_catalog.get(action_name)
        if not isinstance(action_def, dict):
            return
        effects = action_def.get("effects", [])
        run_ctx = dict(ctx)
        run_ctx["param"] = params
        # Pass `model` (+ action_name) so run_effects OWNS the transaction the
        # dialog action's `snapshot` effect opens and commits it (one undo step).
        run_effects(effects, run_ctx, state_store,
                    actions=actions_catalog, dialogs=dialogs_catalog,
                    platform_effects=platform_effects,
                    model=model, action_name=action_name)
    show_yaml_dialog(dialog_id, params={}, store=state_store,
                     ctx=ctx, dispatch_fn=_dispatch, parent=window)


def _build_dialog_platform_effects(model: Model) -> dict:
    """Platform handlers for YAML dialog action effects.
    ``build_artboard_handlers`` already provides the canonical
    ``doc.set_document_setup_field`` / ``doc.set_print_preferences_field``
    / ``geometry.export_pdf`` handlers used by the artboards panel
    menu — reuse them so the dialog action runs through the same
    paths. ``snapshot`` and ``close_dialog`` are handled here:
    snapshot pushes an undo entry, close_dialog clears the store's
    dialog id (YamlDialogView watches that and dismisses)."""
    from panels.artboard_effects import build_artboard_handlers
    handlers = dict(build_artboard_handlers(model))
    def snapshot_h(_value, _ctx, _store):
        # OP_LOG.md Increment 1: the dialog action's `snapshot` effect OPENS the
        # undo transaction (begin_txn) so the subsequent doc.* field setters
        # (enforced set_document chokepoint) are legal; run_effects owns the
        # commit. Mirrors the yaml_tool / Rust doc.snapshot => begin_txn path.
        model.begin_txn()
        return None
    handlers["snapshot"] = snapshot_h
    return handlers


def _lock_selection(model: Model) -> None:
    """Lock all selected elements and clear the selection."""
    from document.controller import Controller
    controller = Controller(model=model)
    # The Controller mutator self-brackets via edit_document (one undo step).
    controller.lock_selection()


def _unlock_all(model: Model) -> None:
    """Unlock all locked elements in the document."""
    from document.controller import Controller
    controller = Controller(model=model)
    # The Controller mutator self-brackets via edit_document (one undo step).
    controller.unlock_all()


def _hide_selection(model: Model) -> None:
    """Hide every element in the current selection."""
    from document.controller import Controller
    controller = Controller(model=model)
    # The Controller mutator self-brackets via edit_document (one undo step).
    controller.hide_selection()


def _show_all(model: Model) -> None:
    """Reset every hidden element in the document back to Preview."""
    from document.controller import Controller
    controller = Controller(model=model)
    # The Controller mutator self-brackets via edit_document (one undo step).
    controller.show_all()


def _orphan_warning_body(n: int, verb: str) -> str:
    """Verbatim body for the reference-aware orphan confirm (identical
    across all apps). ``n`` is the number of live references (instances)
    that would be left pointing at a removed target; ``verb`` is the
    capitalized gerund for the action ("Deleting", "Cutting")."""
    instance = "instance" if n == 1 else "instances"
    return f"{verb} will leave {n} live {instance} empty."


def _confirm_delete_if_orphans(model: Model, parent=None) -> bool:
    """Decide whether the current delete should proceed (REFERENCE_GRAPH.md
    warn-then-orphan).

    Computes ``orphaned_references`` over the selection paths
    (``delete_selection`` would remove exactly these). Empty -> proceed
    silently (unchanged behavior, no dialog). Non-empty -> show a modal
    confirm whose default is the safe Cancel; returns True only if the
    user confirms (Ok).

    Shared by Edit>Delete and the keyboard Delete/Backspace path so both
    warn identically. (Cut has its own mirrored guard.)"""
    from document.dependency_index import orphaned_references
    doc = model.document
    selection_paths = [es.path for es in doc.selection]
    orphaned = orphaned_references(doc, selection_paths)
    if not orphaned:
        return True
    if parent is None:
        parent = QApplication.activeWindow()
    body = _orphan_warning_body(len(orphaned), "Deleting")
    reply = QMessageBox.question(
        parent, "Delete", body,
        QMessageBox.Cancel | QMessageBox.Ok, QMessageBox.Cancel)
    return reply == QMessageBox.Ok


def _route_delete_selection(model: Model, txn_name: str) -> None:
    """OP_LOG.md §9 Phase P4 — route a native menu/keyboard Delete (or the
    delete-half of Cut) through the SHARED op_apply dispatcher
    (apply_delete_selection, the SAME Document.delete_selection body) so the
    gesture JOURNALS a real delete_selection op in ONE named undo step (targets
    carry the pre-deletion selection ids). The synchronous orphan QMessageBox IS
    Python's confirm path (handled by the caller); only the mutation routes here.
    Owns its own transaction (no surrounding snapshot effect), but only if none
    is already open (the same ownership rule edit_document used), so a reentrant
    caller's bracket is preserved. Mirrors the Swift JasCommands
    delete_orphan_confirm_ok / cut_orphan_confirm_ok."""
    owns = not model.in_txn
    if owns:
        model.begin_txn()
        model.name_txn(txn_name)
    op_apply(model, {"op": "delete_selection"})
    if owns:
        model.commit_txn()


def _delete_selection(model: Model, window=None) -> None:
    """Delete all selected elements (reference-aware).

    No-orphan deletes proceed as before (snapshot + delete). When the
    delete would orphan a live reference, a modal confirm is shown first;
    Cancel aborts entirely (no snapshot, no delete)."""
    doc = model.document
    if not doc.selection:
        return
    if not _confirm_delete_if_orphans(model, window):
        return
    _route_delete_selection(model, "delete_selection")


def _select_all(model: Model) -> None:
    """Select all unlocked, visible elements."""
    from document.controller import Controller
    controller = Controller(model=model)
    controller.select_all()


def _link_to_selection(model: Model) -> None:
    """Make Instance: create a live by-id reference to the single
    selected element, offset by (PASTE_OFFSET, PASTE_OFFSET) and
    selected (REFERENCE_GRAPH.md §4).

    Native UI glue (not a Controller op): enabled only when exactly one
    whole element is selected (kind=all; not a control-point sub-
    selection). It mints ``target_id`` / ``ref_id`` via
    ``generate_element_id`` with a collision-retry loop over the existing
    element ids — never minting inside a Controller — then composes two
    already-pinned ops under ONE snapshot: ``create_reference`` (which
    stamps the target and appends the reference, selecting it) followed
    by a ``move_selection`` by the paste offset (the offset rides on the
    new reference's ``transform``, the field render applies). One
    snapshot => one undo. Mirrors the Rust make_instance handler.
    """
    from document.controller import Controller
    from document.artboard import generate_element_id
    from document.document import _SelectionAll

    doc = model.document
    # Enabled only for a single whole-element selection.
    if len(doc.selection) != 1:
        return
    es = next(iter(doc.selection))
    if not isinstance(es.kind, _SelectionAll):
        return
    target_path = es.path

    # Gather every existing element id so the freshly minted ids avoid
    # collisions.
    existing: set[str] = set()

    def _gather_ids(elem) -> None:
        eid = getattr(elem, "id", None)
        if eid is not None:
            existing.add(eid)
        children = getattr(elem, "children", None)
        if children is not None:
            for c in children:
                _gather_ids(c)

    for layer in doc.layers:
        _gather_ids(layer)

    # Mint two distinct, collision-free ids (mirrors the artboard mint
    # loop): generate_element_id is a UI-layer minter, never a Controller.
    def _mint() -> str | None:
        for _ in range(100):
            candidate = generate_element_id()
            if candidate not in existing:
                return candidate
        return None

    target_id = _mint()
    if target_id is None:
        return
    existing.add(target_id)
    ref_id = _mint()
    if ref_id is None:
        return

    # create_reference + offset-move under ONE transaction = a single undo
    # step (the offset rides on the new reference's transform via
    # move_selection). with_txn opens the bracket; each Controller mutator's
    # edit_document JOINS it (one undo step). Mirrors the Rust with_txn pattern.
    controller = Controller(model=model)

    def _gesture() -> None:
        controller.create_reference(target_path, target_id, ref_id)
        controller.move_selection(PASTE_OFFSET, PASTE_OFFSET)

    model.with_txn(_gesture)


def _promote_to_concept(model: Model) -> None:
    """Promote to Concept (CONCEPTS.md §10 — the fitter / promote): detect the
    single selected raw shape with a registered concept's fitter and replace it
    with a live Generated instance, journaling one undo step. The detection +
    op-routing live in ``concepts_apply.apply_promote_to_concept`` (the SAME
    native arm the Concepts panel dispatch reaches), so the menu and the panel
    promote identically. Mirrors the Rust Object-menu Promote to Concept."""
    from panels.concepts_apply import apply_promote_to_concept
    apply_promote_to_concept(model)


def _group_selection(model: Model) -> None:
    """Group the selected elements into a single Group element."""
    from dataclasses import replace as dreplace
    from document.document import ElementSelection
    from geometry.element import Group

    doc = model.document
    if not doc.selection:
        return
    # Collect selected paths sorted by position
    paths = sorted(es.path for es in doc.selection)
    if len(paths) < 2:
        return
    # All selected elements must be siblings (same parent path prefix)
    parent = paths[0][:-1]
    if not all(p[:-1] == parent for p in paths):
        return
    # Gather elements in order
    elements = []
    for p in paths:
        try:
            elements.append(doc.get_element(p))
        except (IndexError, ValueError):
            return
    # Remove selected elements in reverse order to preserve indices
    new_doc = doc
    for p in reversed(paths):
        new_doc = new_doc.delete_element(p)
    # Create the group
    group = Group(children=tuple(elements))
    # Insert at the position of the first selected element
    insert_path = paths[0]
    layer_idx = insert_path[0]
    child_idx = insert_path[1] if len(insert_path) > 1 else 0
    # Insert into the layer
    layer = new_doc.layers[layer_idx]
    new_children = layer.children[:child_idx] + (group,) + layer.children[child_idx:]
    new_layer = dreplace(layer, children=new_children)
    new_layers = new_doc.layers[:layer_idx] + (new_layer,) + new_doc.layers[layer_idx + 1:]
    # Select the new group
    group_path = insert_path
    new_selection = frozenset([ElementSelection.all(group_path)])
    # Undoable edit (one self-bracketed undo step).
    model.edit_document(
        dreplace(new_doc, layers=tuple(new_layers), selection=new_selection))


def _ungroup_selection(model: Model) -> None:
    """Ungroup all selected Group elements, replacing each with its children."""
    from dataclasses import replace as dreplace
    from document.document import ElementSelection
    from geometry.element import Group

    doc = model.document
    if not doc.selection:
        return
    # Collect selected paths that are Groups, sorted by position
    group_paths = []
    for es in doc.selection:
        try:
            elem = doc.get_element(es.path)
            if isinstance(elem, Group):
                group_paths.append(es.path)
        except (IndexError, ValueError):
            pass
    if not group_paths:
        return
    group_paths.sort()
    new_doc = doc
    new_selection: set[ElementSelection] = set()
    # Process in reverse order to preserve indices
    for gpath in reversed(group_paths):
        group_elem = new_doc.get_element(gpath)
        children = group_elem.children
        # Delete the group
        new_doc = new_doc.delete_element(gpath)
        # Insert children at the group's position
        layer_idx = gpath[0]
        child_idx = gpath[1] if len(gpath) > 1 else 0
        layer = new_doc.layers[layer_idx]
        new_children = (layer.children[:child_idx]
                        + children
                        + layer.children[child_idx:])
        new_layer = dreplace(layer, children=new_children)
        new_layers = (new_doc.layers[:layer_idx]
                      + (new_layer,)
                      + new_doc.layers[layer_idx + 1:])
        new_doc = dreplace(new_doc, layers=tuple(new_layers))
    # Build selection for all unpacked children (forward pass)
    # Recompute paths after all modifications
    offset = 0
    for gpath in group_paths:
        orig_group = doc.get_element(gpath)
        n_children = len(orig_group.children)
        layer_idx = gpath[0]
        child_idx = (gpath[1] if len(gpath) > 1 else 0) + offset
        for j in range(n_children):
            path = (layer_idx, child_idx + j)
            elem = new_doc.get_element(path)
            new_selection.add(ElementSelection.all(path))
        # Each ungroup replaces 1 element with n_children, shifting by n_children - 1
        offset += n_children - 1
    # Undoable edit (one self-bracketed undo step).
    model.edit_document(dreplace(new_doc, selection=frozenset(new_selection)))


def _ungroup_all(model: Model) -> None:
    """Ungroup all unlocked Group elements in the document."""
    from dataclasses import replace as dreplace
    from geometry.element import Group, Layer

    doc = model.document
    changed = False

    def _flatten(children: tuple) -> tuple:
        """Replace unlocked Groups with their children, recursively."""
        nonlocal changed
        result = []
        for child in children:
            if isinstance(child, Group) and not isinstance(child, Layer) and not child.locked:
                changed = True
                # Recursively flatten the group's children too
                result.extend(_flatten(child.children))
            elif isinstance(child, Group) and not isinstance(child, Layer):
                # Locked group: recurse into children but keep the group
                new_children = _flatten(child.children)
                result.append(dreplace(child, children=new_children))
            else:
                result.append(child)
        return tuple(result)

    new_layers = tuple(
        dreplace(layer, children=_flatten(layer.children))
        for layer in doc.layers
    )
    if not changed:
        return
    # Undoable edit (one self-bracketed undo step).
    model.edit_document(
        dreplace(doc, layers=new_layers, selection=frozenset()))


def _copy_selection(model: Model) -> None:
    """Copy selected elements to the system clipboard as SVG."""
    from document.document import Document
    from geometry.element import Layer
    from geometry.svg import document_to_svg

    doc = model.document
    if not doc.selection:
        return
    # Gather selected elements
    elements = []
    for es in doc.selection:
        try:
            elem = doc.get_element(es.path)
            elements.append(elem)
        except (IndexError, ValueError):
            pass
    if not elements:
        return
    # Wrap in a minimal document and export as SVG
    temp_doc = Document(layers=(Layer(children=tuple(elements)),))
    svg = document_to_svg(temp_doc)
    clipboard = QApplication.clipboard()
    clipboard.setText(svg)


def _cut_selection(model: Model, parent=None) -> None:
    """Copy selected elements to clipboard, then delete them
    (reference-aware).

    Cut removes exactly the current selection, so it can orphan live
    references just like delete. No-orphan cuts proceed silently
    (unchanged behavior: copy + snapshot + delete). When the cut would
    orphan a live reference, a modal confirm is shown first; Cancel
    aborts entirely (no clipboard change, no snapshot, no delete)."""
    from document.dependency_index import orphaned_references
    doc = model.document
    selection_paths = [es.path for es in doc.selection]
    orphaned = orphaned_references(doc, selection_paths)
    if orphaned:
        if parent is None:
            parent = QApplication.activeWindow()
        body = _orphan_warning_body(len(orphaned), "Cutting")
        reply = QMessageBox.question(
            parent, "Cut", body,
            QMessageBox.Cancel | QMessageBox.Ok, QMessageBox.Cancel)
        if reply != QMessageBox.Ok:
            return
    _copy_selection(model)
    # The clipboard copy is a non-document side effect (no op). The delete-half
    # routes through op_apply, journaling a real delete_selection op in one named
    # undo step. Mirrors the Swift cut_orphan_confirm_ok.
    _route_delete_selection(model, "cut_selection")


def _translate_element(elem, dx: float, dy: float):
    """Translate an element by (dx, dy), recursing into Groups."""
    from dataclasses import replace as _replace
    from geometry.element import Group, control_point_count, move_control_points
    if dx == 0.0 and dy == 0.0:
        return elem
    if isinstance(elem, Group):
        return _replace(elem, children=tuple(
            _translate_element(c, dx, dy) for c in elem.children))
    n = control_point_count(elem)
    return move_control_points(elem, frozenset(range(n)), dx, dy)


def _is_svg(text: str) -> bool:
    """Check if text looks like SVG."""
    s = text.strip()
    return s.startswith("<?xml") or s.startswith("<svg")


def _paste_clipboard(model: Model, offset: float) -> None:
    """Paste from clipboard into the document.

    If the clipboard contains SVG, parse it and merge layers.
    If it contains plain text, add a Text element.
    offset: translation in pt (24 for Paste, 0 for Paste in Place).
    """
    from dataclasses import replace as dreplace

    from document.document import Document, ElementSelection
    from geometry.element import Group, Layer, Text
    from geometry.svg import svg_to_document

    clipboard = QApplication.clipboard()
    text = clipboard.text()
    if not text:
        return

    doc = model.document
    new_selection: set[ElementSelection] = set()

    if _is_svg(text):
        pasted_doc = svg_to_document(text)
        # Merge each pasted layer into the current document
        new_layers = list(doc.layers)
        for pasted_layer in pasted_doc.layers:
            children = tuple(
                _translate_element(c, offset, offset)
                for c in pasted_layer.children
            )
            if not children:
                continue
            # Find matching layer by name
            target_idx = None
            if pasted_layer.name:
                for i, existing in enumerate(new_layers):
                    if existing.name == pasted_layer.name:
                        target_idx = i
                        break
            if target_idx is None:
                target_idx = doc.selected_layer
            # Record paths for pasted elements (appended at end)
            base = len(new_layers[target_idx].children)
            for j, child in enumerate(children):
                path = (target_idx, base + j)
                new_selection.add(ElementSelection.all(path))
            new_layers[target_idx] = dreplace(
                new_layers[target_idx],
                children=new_layers[target_idx].children + children)
        # Undoable edit (one self-bracketed undo step).
        model.edit_document(dreplace(doc, layers=tuple(new_layers),
                                     selection=frozenset(new_selection)))
    else:
        # Plain text: create a Text element
        elem = Text(x=offset, y=offset + 16.0, content=text)
        idx = doc.selected_layer
        layer = doc.layers[idx]
        path = (idx, len(layer.children))
        new_selection.add(ElementSelection.all(path))
        new_layer = dreplace(layer, children=layer.children + (elem,))
        new_layers = doc.layers[:idx] + (new_layer,) + doc.layers[idx + 1:]
        # Undoable edit (one self-bracketed undo step).
        model.edit_document(dreplace(doc, layers=tuple(new_layers),
                                     selection=frozenset(new_selection)))
