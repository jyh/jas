import sys

from PySide6.QtCore import Qt, QRect
from PySide6.QtGui import QKeySequence, QShortcut, QMouseEvent, QPainter, QColor, QCursor
from PySide6.QtWidgets import (
    QApplication, QHBoxLayout, QLabel, QMainWindow, QMessageBox,
    QPushButton, QTabWidget, QVBoxLayout, QWidget,
)

from canvas.canvas import CanvasWidget
from canvas.pane_rendering import compute_pane_geometries, compute_shared_borders, compute_snap_lines
from document.controller import Controller
from menu.menu import create_menus
from document.model import Model
from tools.toolbar import Tool, Toolbar
from workspace.pane import PaneKind, EdgeSide


TITLE_BAR_HEIGHT = 20


class PaneTitleBar(QWidget):
    """Title bar for a pane: label + close button."""

    def __init__(self, label: str, pane_id: int = 0,
                 on_close=None, on_maximize_toggle=None,
                 on_drag_start=None, parent=None):
        super().__init__(parent)
        self.setFixedHeight(TITLE_BAR_HEIGHT)
        self._pane_id = pane_id
        self._on_maximize_toggle = on_maximize_toggle
        self._on_drag_start = on_drag_start
        layout = QHBoxLayout(self)
        layout.setContentsMargins(6, 0, 4, 0)
        layout.setSpacing(4)
        lbl = QLabel(label)
        lbl.setStyleSheet("color: #d9d9d9; font-size: 11px;")
        layout.addWidget(lbl, stretch=1)
        if on_close:
            btn = QPushButton("\u00D7")
            btn.setFixedSize(16, 16)
            btn.setStyleSheet("color: #a5a5a5; border: none; font-size: 12px;")
            btn.clicked.connect(on_close)
            layout.addWidget(btn)
        self.setStyleSheet("background: #383838;")
        self.setCursor(QCursor(Qt.OpenHandCursor))

    def mousePressEvent(self, event):
        if self._on_drag_start:
            self._on_drag_start(self._pane_id, event.globalPosition().x(), event.globalPosition().y())

    def mouseDoubleClickEvent(self, event):
        if self._on_maximize_toggle:
            self._on_maximize_toggle()


EDGE_HANDLE_SIZE = 6


class EdgeHandle(QWidget):
    """Invisible edge handle for resizing a pane."""

    def __init__(self, edge: str, pane_id: int, on_edge_drag_start=None, parent=None):
        super().__init__(parent)
        self._edge = edge
        self._pane_id = pane_id
        self._on_edge_drag_start = on_edge_drag_start
        if edge in ("left", "right"):
            self.setCursor(QCursor(Qt.SplitHCursor))
        else:
            self.setCursor(QCursor(Qt.SplitVCursor))
        self.setStyleSheet("background: transparent;")

    def mousePressEvent(self, event):
        if self._on_edge_drag_start:
            self._on_edge_drag_start(
                self._pane_id, self._edge,
                event.globalPosition().x(), event.globalPosition().y())


class PaneFrame(QWidget):
    """A pane frame with title bar wrapping content."""

    def __init__(self, title_bar: PaneTitleBar, content: QWidget,
                 pane_id: int = 0, on_edge_drag_start=None, parent=None):
        super().__init__(parent)
        self.title_bar = title_bar
        self.content = content
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        layout.addWidget(title_bar)
        layout.addWidget(content, stretch=1)
        self.setStyleSheet("border: 1px solid #555;")
        # Edge resize handles (children, positioned absolutely)
        self._edge_handles = []
        for edge in ("left", "right", "top", "bottom"):
            h = EdgeHandle(edge, pane_id, on_edge_drag_start, self)
            self._edge_handles.append((edge, h))

    def resizeEvent(self, event):
        super().resizeEvent(event)
        w, h = self.width(), self.height()
        es = EDGE_HANDLE_SIZE
        for edge, handle in self._edge_handles:
            if edge == "left":
                handle.setGeometry(0, 0, es, h)
            elif edge == "right":
                handle.setGeometry(w - es, 0, es, h)
            elif edge == "top":
                handle.setGeometry(es, 0, w - 2 * es, es)
            elif edge == "bottom":
                handle.setGeometry(es, h - es, w - 2 * es, es)
            handle.raise_()


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Jas")

        # Drag state
        self._pane_drag = None      # (pane_id, off_x, off_y)
        self._border_drag = None    # (snap_idx, start_coord, is_vertical)
        self._edge_drag = None      # (pane_id, edge, start_x, start_y, start_pw, start_ph, start_px, start_py)
        self._edge_snapped_coord = None  # snapped coordinate during edge drag
        self._snap_preview = []

        # Dock layout
        from workspace.dock import DockLayout
        from workspace.dock_panel import DockPanelWidget
        self.dock_layout = DockLayout.default_layout()
        self.dock_layout.ensure_pane_layout(1200, 900)

        # Menubar
        create_menus(self)

        # Pane container (no layout manager — absolute positioning)
        self._pane_container = QWidget()
        self._pane_container.setStyleSheet("background: #2e2e2e;")
        self._pane_container.setMouseTracking(True)
        self.setCentralWidget(self._pane_container)

        # Get pane IDs
        pl = self.dock_layout.panes()
        tid = pl.pane_by_kind(PaneKind.TOOLBAR).id if pl else 0
        cid = pl.pane_by_kind(PaneKind.CANVAS).id if pl else 1
        did = pl.pane_by_kind(PaneKind.DOCK).id if pl else 2

        # Toolbar pane
        self.toolbar = Toolbar()
        self._toolbar_title = PaneTitleBar(
            "Tools", pane_id=tid,
            on_close=lambda: self._hide_pane(PaneKind.TOOLBAR),
            on_drag_start=self._start_pane_drag)
        self._toolbar_frame = PaneFrame(self._toolbar_title, self.toolbar,
                                        pane_id=tid, on_edge_drag_start=self._start_edge_drag,
                                        parent=self._pane_container)

        # Canvas pane
        self.tab_widget = QTabWidget()
        self.tab_widget.setTabsClosable(True)
        self.tab_widget.tabCloseRequested.connect(self._close_tab)
        self._canvas_title = PaneTitleBar(
            "Canvas", pane_id=cid,
            on_close=lambda: self._hide_pane(PaneKind.CANVAS),
            on_maximize_toggle=self._toggle_canvas_maximized,
            on_drag_start=self._start_pane_drag)
        self._canvas_frame = PaneFrame(self._canvas_title, self.tab_widget,
                                        pane_id=cid, on_edge_drag_start=self._start_edge_drag,
                                        parent=self._pane_container)

        # Dock pane
        self.dock_panel = DockPanelWidget(self.dock_layout)
        self.dock_panel.setStyleSheet("background: #3c3c3c;")
        self._dock_title = PaneTitleBar(
            "Panels", pane_id=did,
            on_close=lambda: self._hide_pane(PaneKind.DOCK),
            on_drag_start=self._start_pane_drag)
        self._dock_frame = PaneFrame(self._dock_title, self.dock_panel,
                                      pane_id=did, on_edge_drag_start=self._start_edge_drag,
                                      parent=self._pane_container)

        # Border handle widgets
        self._border_widgets: list[QWidget] = []
        # Snap preview widgets
        self._snap_widgets: list[QWidget] = []

        self._refresh_pane_positions()

        # Keyboard shortcuts
        QShortcut(QKeySequence("V"), self,
                  lambda: self.toolbar.select_tool(Tool.SELECTION))
        QShortcut(QKeySequence("A"), self,
                  lambda: self.toolbar.select_tool(Tool.DIRECT_SELECTION))
        QShortcut(QKeySequence("P"), self,
                  lambda: self.toolbar.select_tool(Tool.PEN))
        QShortcut(QKeySequence("="), self,
                  lambda: self.toolbar.select_tool(Tool.ADD_ANCHOR_POINT))
        QShortcut(QKeySequence("+"), self,
                  lambda: self.toolbar.select_tool(Tool.ADD_ANCHOR_POINT))
        QShortcut(QKeySequence("-"), self,
                  lambda: self.toolbar.select_tool(Tool.DELETE_ANCHOR_POINT))
        QShortcut(QKeySequence("T"), self,
                  lambda: self.toolbar.select_tool(Tool.TYPE))
        QShortcut(QKeySequence("\\"), self,
                  lambda: self.toolbar.select_tool(Tool.LINE))
        QShortcut(QKeySequence("M"), self,
                  lambda: self.toolbar.select_tool(Tool.RECT))
        QShortcut(QKeySequence("Shift+E"), self,
                  lambda: self.toolbar.select_tool(Tool.PATH_ERASER))
        QShortcut(QKeySequence("Q"), self,
                  lambda: self.toolbar.select_tool(Tool.LASSO))
        QShortcut(QKeySequence(Qt.Key_Delete), self, self._delete_selection)
        QShortcut(QKeySequence(Qt.Key_Backspace), self, self._delete_selection)
        QShortcut(QKeySequence.StandardKey.Undo, self, self._undo)
        QShortcut(QKeySequence.StandardKey.Redo, self, self._redo)

    def _refresh_pane_positions(self):
        """Position all pane frames from PaneLayout coordinates."""
        pl = self.dock_layout.panes()
        geos = compute_pane_geometries(pl)
        borders = compute_shared_borders(pl)
        maximized = pl.canvas_maximized if pl else False

        for geo in geos:
            frame = self._frame_for_kind(geo.kind)
            if geo.visible:
                frame.setGeometry(int(geo.x), int(geo.y), int(geo.width), int(geo.height))
                frame.show()
                from workspace.pane import DoubleClickAction
                frame.title_bar.setVisible(not (geo.config.double_click_action == DoubleClickAction.MAXIMIZE and maximized))
            else:
                frame.hide()

        # Z-order
        sorted_geos = sorted(geos, key=lambda g: g.z_index)
        for geo in sorted_geos:
            self._frame_for_kind(geo.kind).raise_()

        # Remove old border handles
        for w in self._border_widgets:
            w.deleteLater()
        self._border_widgets = []

        # Add border handles
        for b in borders:
            handle = QWidget(self._pane_container)
            handle.setGeometry(int(b.x), int(b.y), int(b.width), int(b.height))
            cursor = Qt.SplitHCursor if b.is_vertical else Qt.SplitVCursor
            handle.setCursor(QCursor(cursor))
            handle.setMouseTracking(True)
            handle.setAttribute(Qt.WA_Hover, True)
            handle.setStyleSheet(
                "QWidget { background: transparent; }"
                "QWidget:hover { background: rgba(74, 144, 217, 0.5); }")
            handle._snap_idx = b.snap_idx
            handle._is_vertical = b.is_vertical
            handle.mousePressEvent = lambda ev, si=b.snap_idx, iv=b.is_vertical: self._start_border_drag(ev, si, iv)
            handle.show()
            handle.raise_()
            self._border_widgets.append(handle)

        # Remove old snap lines
        for w in self._snap_widgets:
            w.deleteLater()
        self._snap_widgets = []

        # Add snap preview lines
        if pl and self._snap_preview:
            lines = compute_snap_lines(self._snap_preview, pl)
            for line in lines:
                w = QWidget(self._pane_container)
                w.setGeometry(int(line.x), int(line.y), int(line.width), int(line.height))
                w.setStyleSheet("background: rgba(50, 120, 220, 200);")
                w.setAttribute(Qt.WA_TransparentForMouseEvents)
                w.show()
                w.raise_()
                self._snap_widgets.append(w)

        # Edge snap highlight
        if self._edge_snapped_coord is not None and self._edge_drag:
            _, edge, *_ = self._edge_drag
            coord = int(self._edge_snapped_coord)
            vh = int(pl.viewport_height) if pl else self._pane_container.height()
            vw = int(pl.viewport_width) if pl else self._pane_container.width()
            w = QWidget(self._pane_container)
            if edge in ("left", "right"):
                w.setGeometry(coord - 2, 0, 4, vh)
            else:
                w.setGeometry(0, coord - 2, vw, 4)
            w.setStyleSheet("background: rgba(50, 120, 220, 200);")
            w.setAttribute(Qt.WA_TransparentForMouseEvents)
            w.show()
            w.raise_()
            self._snap_widgets.append(w)

    def _frame_for_kind(self, kind):
        if kind == PaneKind.TOOLBAR: return self._toolbar_frame
        if kind == PaneKind.CANVAS: return self._canvas_frame
        return self._dock_frame

    def _hide_pane(self, kind):
        self.dock_layout.panes_mut(lambda pl: pl.hide_pane(kind))
        self._refresh_pane_positions()

    def _toggle_canvas_maximized(self):
        self.dock_layout.panes_mut(lambda pl: pl.toggle_canvas_maximized())
        self._refresh_pane_positions()

    def _start_pane_drag(self, pane_id, global_x, global_y):
        """Start dragging a pane from its title bar."""
        pl = self.dock_layout.panes()
        if not pl:
            return
        p = pl.find_pane(pane_id)
        if not p:
            return
        self._pane_drag = (pane_id, global_x - p.x, global_y - p.y)
        self.dock_layout.panes_mut(lambda pl: pl.bring_pane_to_front(pane_id))
        self._refresh_pane_positions()
        self.grabMouse()

    def _start_border_drag(self, event, snap_idx, is_vertical):
        coord = event.globalPosition().x() if is_vertical else event.globalPosition().y()
        self._border_drag = (snap_idx, coord, is_vertical)
        self.grabMouse()

    def _start_edge_drag(self, pane_id, edge, gx, gy):
        pl = self.dock_layout.panes()
        if not pl:
            return
        p = pl.find_pane(pane_id)
        if not p:
            return
        self._edge_drag = (pane_id, edge, gx, gy, p.width, p.height, p.x, p.y)
        self.grabMouse()

    def refresh_panes(self):
        """Refresh pane layout and dock panel after a pane mutation."""
        self._refresh_pane_positions()
        self.dock_panel.rebuild()

    def resizeEvent(self, event):
        super().resizeEvent(event)
        # Use the pane container size (central widget minus menubar)
        w = self._pane_container.width()
        h = self._pane_container.height()
        if w > 0 and h > 0:
            self.dock_layout.panes_mut(
                lambda pl: pl.on_viewport_resize(w, h))
            self._refresh_pane_positions()

    def mouseMoveEvent(self, event):
        mx = event.globalPosition().x()
        my = event.globalPosition().y()
        if self._pane_drag:
            pid, off_x, off_y = self._pane_drag
            new_x = mx - off_x
            new_y = my - off_y
            self.dock_layout.panes_mut(lambda pl: self._do_pane_drag(pl, pid, new_x, new_y))
            self._refresh_pane_positions()
        elif self._border_drag:
            snap_idx, start_coord, is_vert = self._border_drag
            current = mx if is_vert else my
            delta = current - start_coord
            self._border_drag = (snap_idx, current, is_vert)
            self.dock_layout.panes_mut(
                lambda pl: pl.drag_shared_border(snap_idx, delta))
            self._refresh_pane_positions()
        elif self._edge_drag:
            pid, edge, sx, sy, sw, sh, spx, spy = self._edge_drag
            dx = mx - sx
            dy = my - sy
            self.dock_layout.panes_mut(
                lambda pl: self._do_edge_drag(pl, pid, edge, dx, dy, sw, sh, spx, spy))
            self._refresh_pane_positions()

    def _do_pane_drag(self, pl, pid, new_x, new_y):
        from workspace.pane import PaneLayout
        pl.set_pane_position(pid, new_x, new_y)
        preview = pl.detect_snaps(pid, pl.viewport_width, pl.viewport_height)
        if preview:
            pl.align_to_snaps(pid, preview, pl.viewport_width, pl.viewport_height)
        self._snap_preview = preview

    def _do_edge_drag(self, pl, pid, edge, dx, dy, start_w, start_h, start_x, start_y):
        from workspace.pane import SNAP_DISTANCE, EdgeSide, WindowTarget, PaneTarget
        p = pl.find_pane(pid)
        if not p:
            return
        min_w = p.config.min_width
        min_h = p.config.min_height
        if edge == "right":
            raw_coord = start_x + max(start_w + dx, min_w)
            snapped = self._find_edge_snap(pl, pid, EdgeSide.RIGHT, raw_coord)
            final = snapped if snapped is not None else raw_coord
            p.width = max(final - p.x, min_w)
        elif edge == "left":
            raw_coord = start_x + dx
            snapped = self._find_edge_snap(pl, pid, EdgeSide.LEFT, raw_coord)
            final = snapped if snapped is not None else raw_coord
            new_w = max(start_x + start_w - final, min_w)
            p.x = start_x + start_w - new_w
            p.width = new_w
        elif edge == "bottom":
            raw_coord = start_y + max(start_h + dy, min_h)
            snapped = self._find_edge_snap(pl, pid, EdgeSide.BOTTOM, raw_coord)
            final = snapped if snapped is not None else raw_coord
            p.height = max(final - p.y, min_h)
        elif edge == "top":
            raw_coord = start_y + dy
            snapped = self._find_edge_snap(pl, pid, EdgeSide.TOP, raw_coord)
            final = snapped if snapped is not None else raw_coord
            new_h = max(start_y + start_h - final, min_h)
            p.y = start_y + start_h - new_h
            p.height = new_h
        self._edge_snapped_coord = snapped if snapped is not None else None

    @staticmethod
    def _find_edge_snap(pl, pane_id, edge, coord):
        from workspace.pane import SNAP_DISTANCE, EdgeSide
        dist = SNAP_DISTANCE
        vw, vh = pl.viewport_width, pl.viewport_height
        # Window edges
        window_coord = {
            EdgeSide.LEFT: 0, EdgeSide.RIGHT: vw,
            EdgeSide.TOP: 0, EdgeSide.BOTTOM: vh,
        }[edge]
        if abs(coord - window_coord) <= dist:
            return window_coord
        # Other pane edges
        best = None
        best_d = dist + 1
        for other in pl.panes:
            if other.id == pane_id:
                continue
            # Check matching edges
            for oe in [EdgeSide.LEFT, EdgeSide.RIGHT, EdgeSide.TOP, EdgeSide.BOTTOM]:
                oc = pl.pane_edge_coord(other, oe)
                d = abs(coord - oc)
                if d <= dist and d < best_d:
                    best = oc
                    best_d = d
        return best

    def mouseReleaseEvent(self, event):
        if self._pane_drag:
            self.releaseMouse()
            pid = self._pane_drag[0]
            preview = self._snap_preview
            if preview:
                self.dock_layout.panes_mut(
                    lambda pl: pl.apply_snaps(pid, preview, pl.viewport_width, pl.viewport_height))
            self._snap_preview = []
            self._pane_drag = None
            self._refresh_pane_positions()
        elif self._border_drag:
            self.releaseMouse()
            self._border_drag = None
            self._refresh_pane_positions()
        elif self._edge_drag:
            self.releaseMouse()
            self._edge_drag = None
            self._edge_snapped_coord = None
            self._refresh_pane_positions()

    def add_canvas(self, model: Model) -> None:
        """Create a new canvas tab for the given model."""
        controller = Controller(model=model)
        canvas = CanvasWidget(model=model, controller=controller)
        self.toolbar.tool_changed.connect(canvas.set_tool)

        def tab_label(_=None):
            title = model.filename
            if model.is_modified:
                title += " *"
            idx = self.tab_widget.indexOf(canvas)
            if idx >= 0:
                self.tab_widget.setTabText(idx, title)

        idx = self.tab_widget.addTab(canvas, model.filename)
        self.tab_widget.setCurrentIndex(idx)
        model.on_document_changed(tab_label)
        model.on_filename_changed(tab_label)
        tab_label()

    def active_model(self) -> Model | None:
        """Return the model of the focused canvas tab."""
        canvas = self.tab_widget.currentWidget()
        return canvas._model if isinstance(canvas, CanvasWidget) else None

    def _undo(self):
        m = self.active_model()
        if m:
            m.undo()

    def _redo(self):
        m = self.active_model()
        if m:
            m.redo()

    def _close_tab(self, index: int) -> None:
        """Close a canvas tab, prompting to save if modified.

        If the user chooses Save, we reuse the menu's _save function which
        handles both named files and the Save-As flow for untitled documents.
        After saving, we re-check is_modified: if it's still True the user
        cancelled the Save-As dialog and the tab should remain open.
        """
        canvas = self.tab_widget.widget(index)
        if not isinstance(canvas, CanvasWidget):
            self.tab_widget.removeTab(index)
            return
        model = canvas._model
        if model.is_modified:
            reply = QMessageBox.question(
                self, "Save Changes",
                f'Do you want to save changes to "{model.filename}"?',
                QMessageBox.Save | QMessageBox.Discard | QMessageBox.Cancel,
                QMessageBox.Save,
            )
            if reply == QMessageBox.Cancel:
                return
            if reply == QMessageBox.Save:
                from menu.menu import _save
                _save(self, model)
                if model.is_modified:
                    return  # Save was cancelled (e.g. Save-As dialog dismissed)
        self.tab_widget.removeTab(index)

    def closeEvent(self, event):
        """Intercept window close to prompt for unsaved changes.

        Collects all modified models across tabs. If any are modified, shows
        a dialog with Cancel / Don't Save / Save / Save All. Save saves
        only the active model; Save All saves every modified model. If any
        Save-As dialog is cancelled (model still modified), the close is
        aborted.
        """
        modified = []
        for i in range(self.tab_widget.count()):
            canvas = self.tab_widget.widget(i)
            if isinstance(canvas, CanvasWidget) and canvas._model.is_modified:
                modified.append(canvas._model)
        if not modified:
            event.accept()
            return
        names = ", ".join(f'"{m.filename}"' for m in modified)
        box = QMessageBox(self)
        box.setWindowTitle("Save Changes")
        box.setText(f"Do you want to save changes to {names}?")
        box.setStandardButtons(
            QMessageBox.Save | QMessageBox.Discard | QMessageBox.Cancel)
        save_all_btn = box.addButton("Save All", QMessageBox.AcceptRole)
        box.setDefaultButton(QMessageBox.Save)
        box.exec()
        clicked = box.clickedButton()
        if clicked == save_all_btn:
            from menu.menu import _save
            for m in modified:
                _save(self, m)
                if m.is_modified:
                    event.ignore()
                    return
            event.accept()
        elif box.standardButton(clicked) == QMessageBox.Save:
            from menu.menu import _save
            active = self.active_model()
            if active and active.is_modified:
                _save(self, active)
                if active.is_modified:
                    event.ignore()
                    return
            event.accept()
        elif box.standardButton(clicked) == QMessageBox.Discard:
            event.accept()
        else:
            event.ignore()

    def _delete_selection(self):
        m = self.active_model()
        if not m:
            return
        doc = m.document
        if doc.selection:
            m.snapshot()
            m.document = doc.delete_selection()


def main():
    app = QApplication([])
    window = MainWindow()
    window.resize(1200, 900)
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
