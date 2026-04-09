"""Qt widget for rendering the dock panel system."""

from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton, QSizePolicy,
)
from PySide6.QtCore import Qt, QMimeData
from PySide6.QtGui import QDrag

from workspace.dock import (
    DockLayout, DockEdge, PanelKind, GroupAddr, PanelAddr,
)

DOCK_DRAG_MIME = "application/x-jas-dock-drag"


class DraggableGrip(QLabel):
    """Grip handle that starts a group drag on mouse press+move."""
    def __init__(self, payload: str, parent=None):
        super().__init__("\u2801\u2801", parent)
        self._payload = payload
        self.setStyleSheet("color: #999; font-size: 10px; padding: 2px 4px;")
        self.setCursor(Qt.OpenHandCursor)

    def mouseMoveEvent(self, event):
        drag = QDrag(self)
        mime = QMimeData()
        mime.setData(DOCK_DRAG_MIME, self._payload.encode())
        drag.setMimeData(mime)
        drag.exec(Qt.MoveAction)


class DraggableTabButton(QPushButton):
    """Tab button that starts a panel drag on mouse press+move."""
    def __init__(self, label: str, payload: str, parent=None):
        super().__init__(label, parent)
        self._payload = payload
        self.setFlat(True)

    def mouseMoveEvent(self, event):
        drag = QDrag(self)
        mime = QMimeData()
        mime.setData(DOCK_DRAG_MIME, self._payload.encode())
        drag.setMimeData(mime)
        drag.exec(Qt.MoveAction)


class DroppablePanelGroup(QWidget):
    """Panel group widget that accepts dock DnD drops."""
    def __init__(self, dock_layout, dock_id, gi, group, rebuild_fn, parent=None):
        super().__init__(parent)
        self._layout_data = dock_layout
        self._dock_id = dock_id
        self._gi = gi
        self._group = group
        self._rebuild = rebuild_fn
        self.setAcceptDrops(True)

    def dragEnterEvent(self, event):
        if event.mimeData().hasFormat(DOCK_DRAG_MIME):
            event.acceptProposedAction()

    def dropEvent(self, event):
        data = bytes(event.mimeData().data(DOCK_DRAG_MIME)).decode()
        parts = data.split(":")
        target = GroupAddr(dock_id=self._dock_id, group_idx=self._gi)
        if parts[0] == "group" and len(parts) == 3:
            from_addr = GroupAddr(dock_id=int(parts[1]), group_idx=int(parts[2]))
            if from_addr.dock_id == self._dock_id:
                self._layout_data.move_group_within_dock(self._dock_id, from_addr.group_idx, self._gi)
            else:
                self._layout_data.move_group_to_dock(from_addr, self._dock_id, self._gi)
        elif parts[0] == "panel" and len(parts) == 4:
            from_addr = PanelAddr(group=GroupAddr(dock_id=int(parts[1]), group_idx=int(parts[2])), panel_idx=int(parts[3]))
            if from_addr.group == target:
                self._layout_data.reorder_panel(target, from_addr.panel_idx, len(self._group.panels))
            else:
                self._layout_data.move_panel_to_group(from_addr, target)
        event.acceptProposedAction()
        self._rebuild()


class DockPanelWidget(QWidget):
    """Renders an anchored dock with panel groups, tab bars, and placeholders."""

    def __init__(self, dock_layout: DockLayout, edge: DockEdge = DockEdge.RIGHT):
        super().__init__()
        self._layout_data = dock_layout
        self._edge = edge
        self._vbox = QVBoxLayout(self)
        self._vbox.setContentsMargins(0, 0, 0, 0)
        self._vbox.setSpacing(0)
        self.rebuild()

    def rebuild(self):
        """Rebuild the dock UI from the current layout state."""
        # Clear existing widgets
        while self._vbox.count():
            item = self._vbox.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        dock = self._layout_data.anchored_dock(self._edge)
        if dock is None or not dock.groups:
            self.setFixedWidth(0)
            return

        if dock.collapsed:
            self.setFixedWidth(36)
            self._build_collapsed(dock)
        else:
            self.setFixedWidth(int(dock.width))
            self._build_expanded(dock)

    def _build_collapsed(self, dock):
        # Toggle button
        toggle = QPushButton("\u25C0")
        toggle.setFixedHeight(20)
        toggle.setFlat(True)
        toggle.clicked.connect(lambda: self._toggle_dock(dock.id))
        self._vbox.addWidget(toggle)

        # Icon buttons
        for gi, group in enumerate(dock.groups):
            for pi, kind in enumerate(group.panels):
                label = DockLayout.panel_label(kind)
                btn = QPushButton(label[0])
                btn.setFixedSize(28, 28)
                btn.setToolTip(label)
                btn.clicked.connect(lambda _, d=dock.id, g=gi, p=pi: self._expand_to(d, g, p))
                self._vbox.addWidget(btn, alignment=Qt.AlignHCenter)

        self._vbox.addStretch()

    def _build_expanded(self, dock):
        # Toggle button
        toggle = QPushButton("\u25B6")
        toggle.setFixedHeight(20)
        toggle.setFlat(True)
        toggle.clicked.connect(lambda: self._toggle_dock(dock.id))
        self._vbox.addWidget(toggle)

        # Panel groups
        for gi, group in enumerate(dock.groups):
            group_widget = self._build_panel_group(dock.id, gi, group)
            self._vbox.addWidget(group_widget)

        self._vbox.addStretch()

    def _build_panel_group(self, dock_id, gi, group):
        widget = DroppablePanelGroup(self._layout_data, dock_id, gi, group, self.rebuild)
        vbox = QVBoxLayout(widget)
        vbox.setContentsMargins(0, 0, 0, 0)
        vbox.setSpacing(0)

        # Tab bar
        tab_bar = QWidget()
        tab_bar.setStyleSheet("background: #d8d8d8;")
        hbox = QHBoxLayout(tab_bar)
        hbox.setContentsMargins(0, 0, 0, 0)
        hbox.setSpacing(0)

        # Grip (draggable — drags whole group)
        grip = DraggableGrip(f"group:{dock_id}:{gi}")
        hbox.addWidget(grip)

        # Tab buttons (draggable — drags individual panel)
        for pi, kind in enumerate(group.panels):
            label = DockLayout.panel_label(kind)
            btn = DraggableTabButton(label, f"panel:{dock_id}:{gi}:{pi}")
            is_active = pi == group.active
            weight = "bold" if is_active else "normal"
            bg = "#f0f0f0" if is_active else "#d8d8d8"
            btn.setStyleSheet(f"font-size: 11px; font-weight: {weight}; background: {bg}; padding: 3px 8px;")
            btn.clicked.connect(lambda _, d=dock_id, g=gi, p=pi: self._set_active(d, g, p))
            hbox.addWidget(btn)

        hbox.addStretch()

        # Chevron
        chevron = QPushButton("\u25BC" if group.collapsed else "\u25B2")
        chevron.setFlat(True)
        chevron.setStyleSheet("font-size: 9px; color: #888; padding: 3px 6px;")
        chevron.clicked.connect(lambda _, d=dock_id, g=gi: self._toggle_group(d, g))
        hbox.addWidget(chevron)

        vbox.addWidget(tab_bar)

        # Panel body
        if not group.collapsed:
            active = group.active_panel()
            if active is not None:
                body = QLabel(DockLayout.panel_label(active))
                body.setStyleSheet("color: #999; font-size: 12px; padding: 12px;")
                body.setMinimumHeight(60)
                body.setAlignment(Qt.AlignTop | Qt.AlignLeft)
                vbox.addWidget(body)

        # Separator
        sep = QWidget()
        sep.setFixedHeight(1)
        sep.setStyleSheet("background: #ccc;")
        vbox.addWidget(sep)

        return widget

    def _toggle_dock(self, dock_id):
        self._layout_data.toggle_dock_collapsed(dock_id)
        self.rebuild()

    def _toggle_group(self, dock_id, group_idx):
        self._layout_data.toggle_group_collapsed(GroupAddr(dock_id=dock_id, group_idx=group_idx))
        self.rebuild()

    def _set_active(self, dock_id, group_idx, panel_idx):
        self._layout_data.set_active_panel(
            PanelAddr(group=GroupAddr(dock_id=dock_id, group_idx=group_idx), panel_idx=panel_idx))
        self.rebuild()

    def _expand_to(self, dock_id, group_idx, panel_idx):
        self._layout_data.toggle_dock_collapsed(dock_id)
        self._layout_data.set_active_panel(
            PanelAddr(group=GroupAddr(dock_id=dock_id, group_idx=group_idx), panel_idx=panel_idx))
        self.rebuild()

    # -- Floating docks --

    def rebuild_floating(self):
        """Rebuild all floating dock windows."""
        # Close existing
        for w in self._floating_windows:
            w.close()
            w.deleteLater()
        self._floating_windows = []

        for fd in self._layout_data.floating:
            win = FloatingDockWindow(self._layout_data, fd, self)
            win.show()
            self._floating_windows.append(win)

    def rebuild_all(self):
        """Rebuild anchored dock and all floating docks."""
        self.rebuild()
        self.rebuild_floating()

    _floating_windows: list = []


class FloatingDockWindow(QWidget):
    """A floating dock rendered as a tool window."""

    def __init__(self, dock_layout: DockLayout, fd, parent_panel):
        super().__init__(None, Qt.Tool | Qt.FramelessWindowHint)
        self._layout_data = dock_layout
        self._fd = fd
        self._parent_panel = parent_panel
        self._drag_start = None

        self.setGeometry(int(fd.x), int(fd.y), int(fd.dock.width), 200)
        self.setStyleSheet("background: #f0f0f0; border: 1px solid #aaa;")

        vbox = QVBoxLayout(self)
        vbox.setContentsMargins(0, 0, 0, 0)
        vbox.setSpacing(0)

        # Title bar
        title = QWidget()
        title.setFixedHeight(20)
        title.setStyleSheet("background: #d0d0d0;")
        title.setCursor(Qt.OpenHandCursor)
        vbox.addWidget(title)

        # Panel groups
        fid = fd.dock.id
        for gi, group in enumerate(fd.dock.groups):
            group_widget = self._build_group(fid, gi, group)
            vbox.addWidget(group_widget)

        vbox.addStretch()

    def _build_group(self, dock_id, gi, group):
        widget = QWidget()
        vbox = QVBoxLayout(widget)
        vbox.setContentsMargins(0, 0, 0, 0)
        vbox.setSpacing(0)

        tab_bar = QWidget()
        tab_bar.setStyleSheet("background: #d8d8d8;")
        hbox = QHBoxLayout(tab_bar)
        hbox.setContentsMargins(0, 0, 0, 0)
        hbox.setSpacing(0)

        grip = QLabel("\u2801\u2801")
        grip.setStyleSheet("color: #999; font-size: 10px; padding: 2px 4px;")
        hbox.addWidget(grip)

        for pi, kind in enumerate(group.panels):
            label = DockLayout.panel_label(kind)
            btn = QPushButton(label)
            btn.setFlat(True)
            is_active = pi == group.active
            weight = "bold" if is_active else "normal"
            bg = "#f0f0f0" if is_active else "#d8d8d8"
            btn.setStyleSheet(f"font-size: 11px; font-weight: {weight}; background: {bg}; padding: 3px 8px;")
            btn.clicked.connect(lambda _, d=dock_id, g=gi, p=pi: self._set_active(d, g, p))
            hbox.addWidget(btn)

        hbox.addStretch()
        vbox.addWidget(tab_bar)

        if not group.collapsed:
            active = group.active_panel()
            if active is not None:
                body = QLabel(DockLayout.panel_label(active))
                body.setStyleSheet("color: #999; font-size: 12px; padding: 12px;")
                body.setMinimumHeight(60)
                body.setAlignment(Qt.AlignTop | Qt.AlignLeft)
                vbox.addWidget(body)

        return widget

    def _set_active(self, dock_id, group_idx, panel_idx):
        self._layout_data.set_active_panel(
            PanelAddr(group=GroupAddr(dock_id=dock_id, group_idx=group_idx), panel_idx=panel_idx))
        self._parent_panel.rebuild_floating()

    def mousePressEvent(self, event):
        if event.y() < 20:  # Title bar area
            self._drag_start = event.globalPosition().toPoint() - self.pos()
            self._layout_data.bring_to_front(self._fd.dock.id)
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event):
        if self._drag_start is not None:
            new_pos = event.globalPosition().toPoint() - self._drag_start
            self.move(new_pos)
            self._layout_data.set_floating_position(
                self._fd.dock.id, float(new_pos.x()), float(new_pos.y()))
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event):
        self._drag_start = None
        super().mouseReleaseEvent(event)

    def mouseDoubleClickEvent(self, event):
        if event.y() < 20:  # Double-click title bar to redock
            self._layout_data.redock(self._fd.dock.id)
            self._parent_panel.rebuild_all()
        super().mouseDoubleClickEvent(event)
