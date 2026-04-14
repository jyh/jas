"""Qt widget for rendering the dock panel system."""

from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton, QSizePolicy, QMenu,
)
from PySide6.QtCore import Qt, QMimeData, QPoint
from PySide6.QtGui import QDrag

from workspace.workspace_layout import (
    WorkspaceLayout, DockEdge, PanelKind, GroupAddr, PanelAddr,
)
from panels.panel_menu import panel_label, panel_menu, panel_dispatch, panel_is_checked, PanelMenuItemKind
from panels.yaml_menu import get_panel_spec, build_qmenu, panel_label_from_yaml

DOCK_DRAG_MIME = "application/x-jas-dock-drag"

# Theme colors — mutable, updated by set_theme()
THEME_BG = "#3c3c3c"
THEME_BG_DARK = "#333"
THEME_BG_TAB = "#4a4a4a"
THEME_BG_TAB_INACTIVE = "#353535"
THEME_BORDER = "#555"
THEME_TEXT = "#ccc"
THEME_TEXT_DIM = "#999"
THEME_TEXT_BODY = "#aaa"
THEME_TEXT_HINT = "#777"
THEME_TEXT_BUTTON = "#888"


def set_theme(name: str):
    """Update module-level theme colors from the named appearance."""
    global THEME_BG, THEME_BG_DARK, THEME_BG_TAB, THEME_BG_TAB_INACTIVE
    global THEME_BORDER, THEME_TEXT, THEME_TEXT_DIM, THEME_TEXT_BODY
    global THEME_TEXT_HINT, THEME_TEXT_BUTTON
    from workspace.theme import resolve_appearance
    t = resolve_appearance(name)
    THEME_BG = t.pane_bg
    THEME_BG_DARK = t.pane_bg_dark
    THEME_BG_TAB = t.tab_active
    THEME_BG_TAB_INACTIVE = t.tab_inactive
    THEME_BORDER = t.border
    THEME_TEXT = t.text
    THEME_TEXT_DIM = t.text_dim
    THEME_TEXT_BODY = t.text_body
    THEME_TEXT_HINT = t.text_hint
    THEME_TEXT_BUTTON = t.text_button


class DraggableGrip(QLabel):
    """Grip handle that starts a group drag on mouse press+move."""
    def __init__(self, payload: str, parent=None):
        super().__init__("\u2801\u2801", parent)
        self._payload = payload
        self.setStyleSheet(f"color: {THEME_TEXT_HINT}; font-size: 10px; padding: 2px 4px;")
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
    def __init__(self, workspace_layout, dock_id, gi, group, rebuild_fn, parent=None):
        super().__init__(parent)
        self._layout_data = workspace_layout
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
        try:
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
        except (IndexError, ValueError):
            return
        event.acceptProposedAction()
        self._rebuild()


class DockPanelWidget(QWidget):
    """Renders an anchored dock with panel groups, tab bars, and placeholders."""

    def __init__(self, workspace_layout: WorkspaceLayout, edge: DockEdge = DockEdge.RIGHT,
                 get_model=None):
        super().__init__()
        self._layout_data = workspace_layout
        self._edge = edge
        self._get_model = get_model
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
                label = panel_label(kind)
                btn = QPushButton(label[0] if label else "?")
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
        tab_bar.setStyleSheet(f"background: {THEME_BG_DARK}; border-bottom: 1px solid {THEME_BORDER};")
        hbox = QHBoxLayout(tab_bar)
        hbox.setContentsMargins(0, 0, 0, 0)
        hbox.setSpacing(0)

        # Grip (draggable — drags whole group)
        grip = DraggableGrip(f"group:{dock_id}:{gi}")
        hbox.addWidget(grip)

        # Tab buttons (draggable — drags individual panel)
        for pi, kind in enumerate(group.panels):
            lbl = panel_label(kind)
            btn = DraggableTabButton(lbl, f"panel:{dock_id}:{gi}:{pi}")
            is_active = pi == group.active
            weight = "bold" if is_active else "normal"
            bg = THEME_BG_TAB if is_active else THEME_BG_TAB_INACTIVE
            btn.setStyleSheet(f"font-size: 11px; font-weight: {weight}; color: {THEME_TEXT}; background: {bg}; border: none; padding: 3px 8px;")
            btn.clicked.connect(lambda _, d=dock_id, g=gi, p=pi: self._set_active(d, g, p))
            hbox.addWidget(btn)

        hbox.addStretch()

        # Chevron
        chevron = QPushButton("\u00BB" if group.collapsed else "\u00AB")
        chevron.setFlat(True)
        chevron.setStyleSheet(f"font-size: 18px; color: {THEME_TEXT_BUTTON}; border: none; padding: 3px 6px;")
        chevron.clicked.connect(lambda _, d=dock_id, g=gi: self._toggle_group(d, g))
        hbox.addWidget(chevron)

        # Hamburger menu button — hidden when collapsed
        if not group.collapsed:
            active_kind = group.active_panel()
            if active_kind is not None:
                hamburger = QPushButton("\u2261")
                hamburger.setFlat(True)
                hamburger.setStyleSheet(f"font-size: 18px; color: {THEME_TEXT_BUTTON}; border: none; padding: 3px 6px;")
                hamburger.clicked.connect(
                    lambda _, d=dock_id, g=gi, k=active_kind, a=group.active:
                        self._show_panel_menu(d, g, k, a)
                )
                hbox.addWidget(hamburger)

        vbox.addWidget(tab_bar)

        # Panel body
        if not group.collapsed:
            active = group.active_panel()
            if active is not None:
                if active == PanelKind.COLOR and self._get_model is not None:
                    from panels.color_panel_view import ColorPanelView
                    body = ColorPanelView(
                        layout=self._layout_data,
                        get_model=self._get_model,
                        rebuild_fn=self.rebuild,
                    )
                    vbox.addWidget(body)
                else:
                    body = QLabel(panel_label(active))
                    body.setStyleSheet(f"color: {THEME_TEXT_BODY}; font-size: 12px; padding: 12px;")
                    body.setMinimumHeight(60)
                    body.setAlignment(Qt.AlignTop | Qt.AlignLeft)
                    vbox.addWidget(body)

        # Separator
        sep = QWidget()
        sep.setFixedHeight(1)
        sep.setStyleSheet(f"background: {THEME_BORDER};")
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

    def _show_panel_menu(self, dock_id, group_idx, kind, panel_idx):
        addr = PanelAddr(group=GroupAddr(dock_id=dock_id, group_idx=group_idx), panel_idx=panel_idx)
        panel_spec = get_panel_spec(kind)

        if panel_spec and panel_spec.get("menu"):
            # YAML-driven menu
            panel_state = self._get_panel_state(kind)
            global_state = self._get_global_state()
            menu = build_qmenu(
                panel_spec, panel_state, global_state,
                dispatch_fn=lambda action, params: self._dispatch_yaml_cmd(kind, action, params, addr),
                parent=self,
            )
        else:
            # Fallback to hardcoded menu
            menu = QMenu(self)
            items = panel_menu(kind)
            for item in items:
                if item.kind == PanelMenuItemKind.ACTION:
                    action = menu.addAction(item.label)
                    cmd = item.command
                    action.triggered.connect(
                        lambda _, c=cmd: self._dispatch_panel_cmd(kind, c, addr))
                elif item.kind in (PanelMenuItemKind.TOGGLE, PanelMenuItemKind.RADIO):
                    action = menu.addAction(item.label)
                    action.setCheckable(True)
                    action.setChecked(panel_is_checked(kind, item.command, self._layout_data))
                    cmd = item.command
                    action.triggered.connect(
                        lambda _, c=cmd: self._dispatch_panel_cmd(kind, c, addr))
                elif item.kind == PanelMenuItemKind.SEPARATOR:
                    menu.addSeparator()

        menu.exec(self.cursor().pos())

    def _get_panel_state(self, kind: PanelKind) -> dict:
        """Get current panel-local state for expression evaluation."""
        if kind == PanelKind.COLOR:
            return {"mode": self._layout_data.color_panel_mode}
        return {}

    def _get_global_state(self) -> dict:
        """Get current global state for expression evaluation."""
        model = self._get_model() if self._get_model else None
        if model is None:
            return {}
        fill_color = model.default_fill.color.to_hex() if model.default_fill and model.default_fill.color else None
        stroke_color = model.default_stroke.color.to_hex() if model.default_stroke and model.default_stroke.color else None
        if fill_color:
            fill_color = "#" + fill_color
        if stroke_color:
            stroke_color = "#" + stroke_color
        return {
            "fill_on_top": model.fill_on_top,
            "fill_color": fill_color,
            "stroke_color": stroke_color,
        }

    def _dispatch_yaml_cmd(self, kind, action_name, params, addr):
        """Dispatch a YAML menu action."""
        # Map YAML actions to existing panel_dispatch commands
        if action_name == "set_color_panel_mode" and "mode" in params:
            mode = params["mode"]
            cmd = f"mode_{mode}"
            panel_dispatch(kind, cmd, addr, self._layout_data)
        elif action_name == "invert_active_color":
            panel_dispatch(kind, "invert_color", addr, self._layout_data,
                          model=self._get_model() if self._get_model else None)
        elif action_name == "complement_active_color":
            panel_dispatch(kind, "complement_color", addr, self._layout_data,
                          model=self._get_model() if self._get_model else None)
        elif action_name == "close_panel":
            panel_dispatch(kind, "close_panel", addr, self._layout_data)
        else:
            # Generic fallback — try as direct command
            panel_dispatch(kind, action_name, addr, self._layout_data,
                          model=self._get_model() if self._get_model else None)
        self.rebuild()

    def _dispatch_panel_cmd(self, kind, cmd, addr):
        model = self._get_model() if self._get_model else None
        panel_dispatch(kind, cmd, addr, self._layout_data, model=model)
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

    def __init__(self, workspace_layout: WorkspaceLayout, fd, parent_panel):
        super().__init__(None, Qt.Tool | Qt.FramelessWindowHint)
        self._layout_data = workspace_layout
        self._fd = fd
        self._parent_panel = parent_panel
        self._drag_start = None

        self.setGeometry(int(fd.x), int(fd.y), int(fd.dock.width), 200)
        self.setStyleSheet(f"background: {THEME_BG}; border: 1px solid {THEME_BORDER};")

        vbox = QVBoxLayout(self)
        vbox.setContentsMargins(0, 0, 0, 0)
        vbox.setSpacing(0)

        # Title bar
        title = QWidget()
        title.setFixedHeight(20)
        title.setStyleSheet(f"background: {THEME_BG_DARK}; color: {THEME_TEXT_DIM};")
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
        tab_bar.setStyleSheet(f"background: {THEME_BG_DARK}; border-bottom: 1px solid {THEME_BORDER};")
        hbox = QHBoxLayout(tab_bar)
        hbox.setContentsMargins(0, 0, 0, 0)
        hbox.setSpacing(0)

        grip = QLabel("\u2801\u2801")
        grip.setStyleSheet(f"color: {THEME_TEXT_HINT}; font-size: 10px; padding: 2px 4px;")
        hbox.addWidget(grip)

        for pi, kind in enumerate(group.panels):
            label = panel_label(kind)
            btn = QPushButton(label)
            btn.setFlat(True)
            is_active = pi == group.active
            weight = "bold" if is_active else "normal"
            bg = THEME_BG_TAB if is_active else THEME_BG_TAB_INACTIVE
            btn.setStyleSheet(f"font-size: 11px; font-weight: {weight}; color: {THEME_TEXT}; background: {bg}; border: none; padding: 3px 8px;")
            btn.clicked.connect(lambda _, d=dock_id, g=gi, p=pi: self._set_active(d, g, p))
            hbox.addWidget(btn)

        hbox.addStretch()
        vbox.addWidget(tab_bar)

        if not group.collapsed:
            active = group.active_panel()
            if active is not None:
                if active == PanelKind.COLOR and self._parent_panel._get_model is not None:
                    from panels.color_panel_view import ColorPanelView
                    body = ColorPanelView(
                        layout=self._layout_data,
                        get_model=self._parent_panel._get_model,
                        rebuild_fn=self._parent_panel.rebuild_all,
                    )
                    vbox.addWidget(body)
                else:
                    body = QLabel(panel_label(active))
                    body.setStyleSheet(f"color: {THEME_TEXT_BODY}; font-size: 12px; padding: 12px;")
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
