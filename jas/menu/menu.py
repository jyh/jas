"""Menubar for Jas application."""

from PySide6.QtGui import QKeySequence
from PySide6.QtWidgets import QApplication, QFileDialog, QMainWindow

from document.model import Model
from tools.tool import PASTE_OFFSET


def create_menus(window: QMainWindow) -> None:
    """Create File, Edit, and View menus for the main window.

    Args:
        window: The QMainWindow to add menus to (must have active_model()).
    """
    def _model() -> Model | None:
        return window.active_model()

    menubar = window.menuBar()

    # File menu
    file_menu = menubar.addMenu("&File")

    new_action = file_menu.addAction("&New")
    new_action.setShortcut(QKeySequence.New)
    new_action.triggered.connect(lambda: window.add_canvas(Model()))

    open_action = file_menu.addAction("&Open...")
    open_action.setShortcut(QKeySequence.Open)
    open_action.triggered.connect(lambda: _open_file(window))

    save_action = file_menu.addAction("&Save")
    save_action.setShortcut(QKeySequence.Save)
    save_action.triggered.connect(lambda: _save(window, _model()))

    save_as_action = file_menu.addAction("Save &As...")
    save_as_action.setShortcut(QKeySequence.SaveAs)
    save_as_action.triggered.connect(lambda: _save_as(window, _model()))

    revert_action = file_menu.addAction("&Revert")
    revert_action.triggered.connect(lambda: _revert(window, _model()))
    # Dynamically enable/disable: only when model is modified and has a saved file
    file_menu.aboutToShow.connect(lambda: revert_action.setEnabled(
        _model() is not None
        and _model().is_modified
        and not _model().filename.startswith("Untitled-")
    ))

    file_menu.addSeparator()

    quit_action = file_menu.addAction("&Quit")
    quit_action.setShortcut(QKeySequence.Quit)
    quit_action.triggered.connect(window.close)

    # Edit menu
    edit_menu = menubar.addMenu("&Edit")

    def _with_model(fn):
        """Call fn(model) if a model is active, avoiding double _model() calls."""
        m = _model()
        if m:
            fn(m)

    undo_action = edit_menu.addAction("&Undo")
    undo_action.setShortcut(QKeySequence.Undo)
    undo_action.triggered.connect(lambda: _with_model(lambda m: m.undo()))

    redo_action = edit_menu.addAction("&Redo")
    redo_action.setShortcut(QKeySequence.Redo)
    redo_action.triggered.connect(lambda: _with_model(lambda m: m.redo()))

    edit_menu.addSeparator()

    cut_action = edit_menu.addAction("Cu&t")
    cut_action.setShortcut(QKeySequence.Cut)
    cut_action.triggered.connect(lambda: _with_model(lambda m: _cut_selection(m)))

    copy_action = edit_menu.addAction("&Copy")
    copy_action.setShortcut(QKeySequence.Copy)
    copy_action.triggered.connect(lambda: _with_model(lambda m: _copy_selection(m)))

    paste_action = edit_menu.addAction("&Paste")
    paste_action.setShortcut(QKeySequence.Paste)
    paste_action.triggered.connect(lambda: _with_model(lambda m: _paste_clipboard(m, PASTE_OFFSET)))

    paste_in_place_action = edit_menu.addAction("Paste in &Place")
    paste_in_place_action.setShortcut(QKeySequence("Ctrl+Shift+V"))
    paste_in_place_action.triggered.connect(
        lambda: _with_model(lambda m: _paste_clipboard(m, 0.0)))

    edit_menu.addSeparator()

    delete_action = edit_menu.addAction("&Delete")
    delete_action.setShortcut(QKeySequence.Delete)
    delete_action.triggered.connect(lambda: _with_model(lambda m: _delete_selection(m)))

    select_all_action = edit_menu.addAction("Select &All")
    select_all_action.setShortcut(QKeySequence.SelectAll)
    select_all_action.triggered.connect(lambda: _with_model(lambda m: _select_all(m)))

    # Object menu
    object_menu = menubar.addMenu("&Object")

    group_action = object_menu.addAction("&Group")
    group_action.setShortcut(QKeySequence("Ctrl+G"))
    group_action.triggered.connect(lambda: _with_model(lambda m: _group_selection(m)))

    ungroup_action = object_menu.addAction("&Ungroup")
    ungroup_action.setShortcut(QKeySequence("Ctrl+Shift+G"))
    ungroup_action.triggered.connect(lambda: _with_model(lambda m: _ungroup_selection(m)))

    ungroup_all_action = object_menu.addAction("Ungroup A&ll")
    ungroup_all_action.triggered.connect(lambda: _with_model(lambda m: _ungroup_all(m)))

    object_menu.addSeparator()

    lock_action = object_menu.addAction("&Lock")
    lock_action.setShortcut(QKeySequence("Ctrl+2"))
    lock_action.triggered.connect(lambda: _with_model(lambda m: _lock_selection(m)))

    unlock_all_action = object_menu.addAction("Unlock &All")
    unlock_all_action.setShortcut(QKeySequence("Ctrl+Alt+2"))
    unlock_all_action.triggered.connect(lambda: _with_model(lambda m: _unlock_all(m)))

    object_menu.addSeparator()

    hide_action = object_menu.addAction("&Hide")
    hide_action.setShortcut(QKeySequence("Ctrl+3"))
    hide_action.triggered.connect(lambda: _with_model(lambda m: _hide_selection(m)))

    show_all_action = object_menu.addAction("&Show All")
    show_all_action.setShortcut(QKeySequence("Ctrl+Alt+3"))
    show_all_action.triggered.connect(lambda: _with_model(lambda m: _show_all(m)))

    # View menu
    view_menu = menubar.addMenu("&View")

    zoom_in_action = view_menu.addAction("Zoom &In")
    zoom_in_action.setShortcut(QKeySequence.ZoomIn)
    zoom_in_action.triggered.connect(lambda: print("Zoom in"))

    zoom_out_action = view_menu.addAction("Zoom &Out")
    zoom_out_action.setShortcut(QKeySequence.ZoomOut)
    zoom_out_action.triggered.connect(lambda: print("Zoom out"))

    fit_action = view_menu.addAction("&Fit in Window")
    fit_action.setShortcut(QKeySequence("Ctrl+0"))
    fit_action.triggered.connect(lambda: print("Fit in window"))

    # --- Window menu ---
    window_menu = menubar.addMenu("&Window")

    # Workspace submenu
    ws_menu = window_menu.addMenu("Workspace")

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

    # Appearance submenu
    appearance_menu = window_menu.addMenu("Appearance")

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

    def _switch_appearance(window, name):
        from workspace.theme import resolve_appearance
        if not hasattr(window, 'app_config'):
            return
        window.app_config.active_appearance = name
        window.app_config.save()
        if hasattr(window, 'refresh_panes'):
            window.refresh_panes()

    appearance_menu.aboutToShow.connect(_rebuild_appearance_menu)

    window_menu.addSeparator()

    # Tile
    def _tile_panes():
        if not hasattr(window, 'workspace_layout'):
            return
        window.workspace_layout.panes_mut(lambda pl: pl.tile_panes())
        if hasattr(window, 'refresh_panes'):
            window.refresh_panes()

    tile_action = window_menu.addAction("Tile")
    tile_action.triggered.connect(_tile_panes)

    window_menu.addSeparator()

    # Pane toggles
    def _toggle_pane(kind):
        if not hasattr(window, 'workspace_layout'):
            return
        layout = window.workspace_layout
        layout.panes_mut(lambda pl: (
            pl.hide_pane(kind) if pl.is_pane_visible(kind) else pl.show_pane(kind)))
        if hasattr(window, 'refresh_panes'):
            window.refresh_panes()

    from workspace.pane import PaneKind as PK
    toolbar_action = window_menu.addAction("Toolbar")
    toolbar_action.triggered.connect(lambda: _toggle_pane(PK.TOOLBAR))
    panels_action = window_menu.addAction("Panels")
    panels_action.triggered.connect(lambda: _toggle_pane(PK.DOCK))

    window_menu.addSeparator()

    # Panel toggles
    def _toggle_panel(kind):
        if not hasattr(window, 'workspace_layout'):
            return
        from workspace.workspace_layout import WorkspaceLayout, GroupAddr, PanelAddr
        layout = window.workspace_layout
        if layout.is_panel_visible(kind):
            # Find and close
            for _, dock in layout.anchored:
                for gi, group in enumerate(dock.groups):
                    for pi, k in enumerate(group.panels):
                        if k == kind:
                            layout.close_panel(PanelAddr(group=GroupAddr(dock_id=dock.id, group_idx=gi), panel_idx=pi))
                            if hasattr(window, 'dock_panel'):
                                window.dock_panel.rebuild()
                            return
        else:
            layout.show_panel(kind)
            if hasattr(window, 'dock_panel'):
                window.dock_panel.rebuild()

    from workspace.workspace_layout import PanelKind
    for kind, label in [(PanelKind.LAYERS, "&Layers"), (PanelKind.COLOR, "&Color"),
                        (PanelKind.STROKE, "&Stroke"), (PanelKind.PROPERTIES, "&Properties")]:
        action = window_menu.addAction(label)
        action.triggered.connect(lambda checked=False, k=kind: _toggle_panel(k))


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
    window.app_config.save()
    window.workspace_layout.save_to_file()
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
        model.snapshot()
        model.document = svg_to_document(svg)
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


def _lock_selection(model: Model) -> None:
    """Lock all selected elements and clear the selection."""
    from document.controller import Controller
    controller = Controller(model=model)
    model.snapshot()
    controller.lock_selection()


def _unlock_all(model: Model) -> None:
    """Unlock all locked elements in the document."""
    from document.controller import Controller
    controller = Controller(model=model)
    model.snapshot()
    controller.unlock_all()


def _hide_selection(model: Model) -> None:
    """Hide every element in the current selection."""
    from document.controller import Controller
    controller = Controller(model=model)
    model.snapshot()
    controller.hide_selection()


def _show_all(model: Model) -> None:
    """Reset every hidden element in the document back to Preview."""
    from document.controller import Controller
    controller = Controller(model=model)
    model.snapshot()
    controller.show_all()


def _delete_selection(model: Model) -> None:
    """Delete all selected elements."""
    doc = model.document
    if not doc.selection:
        return
    from document.document import Document
    model.snapshot()
    model.document = doc.delete_selection()


def _select_all(model: Model) -> None:
    """Select all unlocked, visible elements."""
    from document.controller import Controller
    controller = Controller(model=model)
    controller.select_all()


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
    model.snapshot()
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
    model.document = dreplace(new_doc, layers=tuple(new_layers), selection=new_selection)


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
    model.snapshot()
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
    model.document = dreplace(new_doc, selection=frozenset(new_selection))


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
    model.snapshot()
    model.document = dreplace(doc, layers=new_layers, selection=frozenset())


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


def _cut_selection(model: Model) -> None:
    """Copy selected elements to clipboard, then delete them."""
    model.snapshot()
    _copy_selection(model)
    model.document = model.document.delete_selection()


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
    model.snapshot()
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
        model.document = dreplace(doc, layers=tuple(new_layers),
                                  selection=frozenset(new_selection))
    else:
        # Plain text: create a Text element
        elem = Text(x=offset, y=offset + 16.0, content=text)
        idx = doc.selected_layer
        layer = doc.layers[idx]
        path = (idx, len(layer.children))
        new_selection.add(ElementSelection.all(path))
        new_layer = dreplace(layer, children=layer.children + (elem,))
        new_layers = doc.layers[:idx] + (new_layer,) + doc.layers[idx + 1:]
        model.document = dreplace(doc, layers=tuple(new_layers),
                                  selection=frozenset(new_selection))
