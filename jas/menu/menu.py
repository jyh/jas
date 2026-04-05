"""Menubar for Jas application."""

from PySide6.QtGui import QKeySequence
from PySide6.QtWidgets import QApplication, QFileDialog, QMainWindow

from document.model import Model


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

    file_menu.addSeparator()

    quit_action = file_menu.addAction("&Quit")
    quit_action.setShortcut(QKeySequence.Quit)
    quit_action.triggered.connect(window.close)

    # Edit menu
    edit_menu = menubar.addMenu("&Edit")

    undo_action = edit_menu.addAction("&Undo")
    undo_action.setShortcut(QKeySequence.Undo)
    undo_action.triggered.connect(lambda: _model() and _model().undo())

    redo_action = edit_menu.addAction("&Redo")
    redo_action.setShortcut(QKeySequence.Redo)
    redo_action.triggered.connect(lambda: _model() and _model().redo())

    edit_menu.addSeparator()

    cut_action = edit_menu.addAction("Cu&t")
    cut_action.setShortcut(QKeySequence.Cut)
    cut_action.triggered.connect(lambda: _model() and _cut_selection(_model()))

    copy_action = edit_menu.addAction("&Copy")
    copy_action.setShortcut(QKeySequence.Copy)
    copy_action.triggered.connect(lambda: _model() and _copy_selection(_model()))

    paste_action = edit_menu.addAction("&Paste")
    paste_action.setShortcut(QKeySequence.Paste)
    paste_action.triggered.connect(lambda: _model() and _paste_clipboard(_model(), 24.0))

    paste_in_place_action = edit_menu.addAction("Paste in &Place")
    paste_in_place_action.setShortcut(QKeySequence("Ctrl+Shift+V"))
    paste_in_place_action.triggered.connect(
        lambda: _model() and _paste_clipboard(_model(), 0.0))

    edit_menu.addSeparator()

    select_all_action = edit_menu.addAction("Select &All")
    select_all_action.setShortcut(QKeySequence.SelectAll)
    select_all_action.triggered.connect(lambda: print("Select all"))

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


def _open_file(window: QMainWindow) -> None:
    """Show Open dialog and load an SVG file into a new canvas."""
    from geometry.svg import svg_to_document

    path, _ = QFileDialog.getOpenFileName(
        window, "Open", "", "SVG Files (*.svg)")
    if not path:
        return
    with open(path, "r", encoding="utf-8") as f:
        svg = f.read()
    new_model = Model(document=svg_to_document(svg), filename=path)
    window.add_canvas(new_model)


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
    """Translate an element by (dx, dy) using move_control_points with all CPs."""
    from geometry.element import control_point_count, move_control_points
    if dx == 0.0 and dy == 0.0:
        return elem
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
    from geometry.element import Group, Layer, Text, control_point_count
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
                n = control_point_count(child)
                new_selection.add(ElementSelection(
                    path=path, control_points=frozenset(range(n))))
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
        n = control_point_count(elem)
        new_selection.add(ElementSelection(
            path=path, control_points=frozenset(range(n))))
        new_layer = dreplace(layer, children=layer.children + (elem,))
        new_layers = doc.layers[:idx] + (new_layer,) + doc.layers[idx + 1:]
        model.document = dreplace(doc, layers=tuple(new_layers),
                                  selection=frozenset(new_selection))
