import os
import sys

# Add repo root to sys.path so `workspace_interpreter` (which lives at
# the repo root, not inside jas/) is importable. Must run before any
# `from panels.*` / `from workspace.*` import below, since those
# transitively import workspace_interpreter at module load time.
_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from PySide6.QtCore import Qt, QRect
from PySide6.QtGui import QIcon, QKeySequence, QPixmap, QShortcut, QMouseEvent, QPainter, QColor, QCursor
from PySide6.QtWidgets import (
    QApplication, QHBoxLayout, QLabel, QMainWindow, QMessageBox,
    QPushButton, QTabWidget, QVBoxLayout, QWidget,
)


def _brand_icon_path(size: int) -> str | None:
    """Return path to brand PNG icon of given size, or None if not found."""
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(here, "..", "assets", "brand", "icons", f"icon_{size}.png"),
        os.path.join(here, "assets", "brand", "icons", f"icon_{size}.png"),
    ]
    return next((p for p in candidates if os.path.exists(p)), None)

from canvas.canvas import CanvasWidget
from canvas.pane_rendering import compute_pane_geometries, compute_shared_borders, compute_snap_lines
from document.controller import Controller
from geometry.element import Fill, RgbColor, Stroke
from menu.menu import create_menus
from document.model import Model
from panels.yaml_dialog_view import YamlDialogView
from tools.toolbar import Tool, Toolbar
from workspace.pane import PaneKind, EdgeSide


TITLE_BAR_HEIGHT = 20


# Inverse of MainWindow._TOOL_YAML_IDS: the bundle's active_tool string
# -> native Tool enum. The bundle toolbar (workspace tool_grid) drives
# tool selection through state.active_tool (the select_tool action and
# the alternates flyout's set:{active_tool} effect both write this key);
# the state -> canvas bridge maps the string back to a Tool to drive
# canvas.set_tool. Two ids that the enum map doesn't carry are aliased
# here so the bundle's shorter names resolve: the state enum uses
# ``add_anchor`` / ``delete_anchor`` while the Tool enum maps spell them
# ``add_anchor_point`` / ``delete_anchor_point``. A test asserts this is
# the exact inverse of _TOOL_YAML_IDS (plus the two aliases).
_TOOL_YAML_ID_TO_ENUM = {
    "selection": Tool.SELECTION,
    "partial_selection": Tool.PARTIAL_SELECTION,
    "interior_selection": Tool.INTERIOR_SELECTION,
    "magic_wand": Tool.MAGIC_WAND,
    "pen": Tool.PEN,
    "add_anchor_point": Tool.ADD_ANCHOR_POINT,
    "delete_anchor_point": Tool.DELETE_ANCHOR_POINT,
    "anchor_point": Tool.ANCHOR_POINT,
    "pencil": Tool.PENCIL,
    "paintbrush": Tool.PAINTBRUSH,
    "blob_brush": Tool.BLOB_BRUSH,
    "path_eraser": Tool.PATH_ERASER,
    "smooth": Tool.SMOOTH,
    "line": Tool.LINE,
    "rect": Tool.RECT,
    "rounded_rect": Tool.ROUNDED_RECT,
    "ellipse": Tool.ELLIPSE,
    "polygon": Tool.POLYGON,
    "star": Tool.STAR,
    "lasso": Tool.LASSO,
    "scale": Tool.SCALE,
    "rotate": Tool.ROTATE,
    "shear": Tool.SHEAR,
    "hand": Tool.HAND,
    "zoom": Tool.ZOOM,
    "eyedropper": Tool.EYEDROPPER,
    "artboard": Tool.ARTBOARD,
    "type": Tool.TYPE,
    "type_on_path": Tool.TYPE_ON_PATH,
    # State-enum spellings (state.yaml active_tool values) that differ
    # from the Tool-enum yaml_id, so both resolve from the bundle.
    "add_anchor": Tool.ADD_ANCHOR_POINT,
    "delete_anchor": Tool.DELETE_ANCHOR_POINT,
}


# Priority order for resolving a tool's double-click options from the
# compiled bundle. This mirrors the old native toolbar
# (ToolButton.mouseDoubleClickEvent -> tool_options_dialog/panel/action
# lookup + 3-way dispatch). A tool yaml carries at most one of these; the
# priority only fixes the resolution order when more than one is present.
#   1. tool_options_panel  -> show that panel (Magic Wand)
#   2. tool_options_action -> dispatch that generic action (Hand/Zoom/Artboard)
#   3. tool_options_dialog -> open that dialog (Paintbrush/Blob Brush/Scale/...)
_TOOL_OPTIONS_FIELDS = (
    ("panel", "tool_options_panel"),
    ("action", "tool_options_action"),
    ("dialog", "tool_options_dialog"),
)


def tool_options_dispatch(bundle, active_tool):
    """Resolve the double-click options for ``active_tool`` from the
    compiled bundle, returning ``(kind, target)`` where ``kind`` is one
    of ``"panel"`` / ``"action"`` / ``"dialog"`` and ``target`` is the
    panel id / action name / dialog id; ``(None, None)`` when the active
    tool declares no options (the dblclick is then a no-op).

    The tool list is read entirely from ``bundle["tools"]`` — nothing is
    hardcoded — so adding a ``tool_options_*`` field to any tool yaml is
    enough to wire its dblclick.
    """
    if not isinstance(active_tool, str) or not active_tool:
        return (None, None)
    tools = bundle.get("tools") if isinstance(bundle, dict) else None
    spec = (tools or {}).get(active_tool) if isinstance(tools, dict) else None
    if not isinstance(spec, dict):
        return (None, None)
    for kind, field in _TOOL_OPTIONS_FIELDS:
        target = spec.get(field)
        if isinstance(target, str) and target:
            return (kind, target)
    return (None, None)


class PaneTitleBar(QWidget):
    """Title bar for a pane: label + close button."""

    def __init__(self, label: str, pane_id: int = 0,
                 on_close=None, on_maximize_toggle=None,
                 on_drag_start=None, theme=None, parent=None):
        super().__init__(parent)
        self.setFixedHeight(TITLE_BAR_HEIGHT)
        self._pane_id = pane_id
        self._on_maximize_toggle = on_maximize_toggle
        self._on_drag_start = on_drag_start
        self._theme = theme
        layout = QHBoxLayout(self)
        layout.setContentsMargins(6, 0, 4, 0)
        layout.setSpacing(4)
        self._label = QLabel(label)
        layout.addWidget(self._label, stretch=1)
        if on_close:
            self._close_btn = QPushButton("\u00D7")
            self._close_btn.setFixedSize(16, 16)
            self._close_btn.clicked.connect(on_close)
            layout.addWidget(self._close_btn)
        else:
            self._close_btn = None
        self.apply_theme(theme)
        self.setCursor(QCursor(Qt.OpenHandCursor))

    def apply_theme(self, theme=None):
        if theme is None:
            theme = self._theme
        if theme is None:
            return
        self._theme = theme
        self._label.setStyleSheet(f"color: {theme.title_bar_text}; font-size: 11px;")
        if self._close_btn:
            self._close_btn.setStyleSheet(f"color: {theme.text_button}; border: none; font-size: 12px;")
        self.setStyleSheet(f"background: {theme.title_bar_bg};")

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
                 pane_id: int = 0, on_edge_drag_start=None, theme=None, parent=None):
        super().__init__(parent)
        self.title_bar = title_bar
        self.content = content
        self._theme = theme
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        layout.addWidget(title_bar)
        layout.addWidget(content, stretch=1)
        self.setObjectName("pane_frame")
        self.apply_theme(theme)
        # Edge resize handles (children, positioned absolutely)
        self._edge_handles = []
        for edge in ("left", "right", "top", "bottom"):
            h = EdgeHandle(edge, pane_id, on_edge_drag_start, self)
            self._edge_handles.append((edge, h))

    def apply_theme(self, theme=None):
        if theme is None:
            theme = self._theme
        if theme:
            self._theme = theme
        border = theme.border if theme else "#555"
        self.setStyleSheet(f"#pane_frame {{ border: 1px solid {border}; }}")

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

        # App window icon
        icon_path = _brand_icon_path(256)
        if icon_path:
            self.setWindowIcon(QIcon(icon_path))

        self._canvas_logo_lbl: QLabel | None = None

        # Drag state
        self._pane_drag = None      # (pane_id, off_x, off_y)
        self._border_drag = None    # (snap_idx, start_coord, is_vertical)
        self._edge_drag = None      # (pane_id, edge, start_x, start_y, start_pw, start_ph, start_px, start_py)
        self._edge_snapped_coord = None  # snapped coordinate during edge drag
        self._snap_preview = []

        # Dock layout
        from workspace.workspace_layout import WorkspaceLayout, AppConfig
        from workspace.dock_panel import DockPanelWidget
        from workspace.theme import resolve_appearance
        self.app_config = AppConfig.load()
        self.workspace_layout = WorkspaceLayout.load_or_migrate_workspace(self.app_config)
        self.workspace_layout.ensure_pane_layout(1200, 900)
        self.theme = resolve_appearance(self.app_config.active_appearance)
        from workspace.dock_panel import set_theme as set_dock_theme
        set_dock_theme(self.app_config.active_appearance)

        # Menubar
        create_menus(self)
        # Logo to the left of the menu items
        logo_path = _brand_icon_path(32)
        if logo_path:
            logo_pm = QPixmap(logo_path).scaled(
                45, 20, Qt.KeepAspectRatio, Qt.SmoothTransformation)
            logo_lbl = QLabel()
            logo_lbl.setPixmap(logo_pm)
            logo_lbl.setContentsMargins(4, 0, 4, 0)
            self.menuBar().setCornerWidget(logo_lbl, Qt.TopLeftCorner)

        # Pane container (no layout manager — absolute positioning)
        self._pane_container = QWidget()
        self._pane_container.setStyleSheet(f"background: {self.theme.window_bg};")
        self._pane_container.setMouseTracking(True)
        self.setCentralWidget(self._pane_container)

        # Get pane IDs
        pl = self.workspace_layout.panes()
        tid = pl.pane_by_kind(PaneKind.TOOLBAR).id if pl else 0
        cid = pl.pane_by_kind(PaneKind.CANVAS).id if pl else 1
        did = pl.pane_by_kind(PaneKind.DOCK).id if pl else 2

        # Toolbar pane.
        #
        # STEP A of the bundle-toolbar migration (mirrors Rust
        # YamlToolbarContent / the Swift port): the visible pane renders
        # the workspace ``toolbar_pane -> content -> tool_grid`` through
        # the generic yaml_renderer rather than the native QPainter
        # ``Toolbar`` widget. The native ``Toolbar`` is still constructed
        # but NOT mounted — it lives on as a headless tool-state
        # controller so the existing keyboard shortcuts, spacebar
        # pass-through (canvas.on_request_tool_change) and the
        # fill/stroke widget keep working unchanged. Its tool_changed
        # signal still drives the canvas, and a state<->toolbar bridge
        # (wired in _build_yaml_toolbar) keeps state.active_tool and the
        # native current_tool in lockstep so the YAML grid highlight and
        # the canvas tool agree regardless of which path initiated the
        # switch. STEP B will delete tools/toolbar.py once the fill/stroke
        # + keyboard paths move onto the bundle too.
        self.toolbar = Toolbar()
        self.toolbar.tool_options_requested.connect(self._open_tool_options_dialog)
        # Pane body container — populated by _build_yaml_toolbar once the
        # YAML state store exists (the store is created further below).
        self._toolbar_body = QWidget()
        _tb_lay = QVBoxLayout(self._toolbar_body)
        _tb_lay.setContentsMargins(2, 4, 2, 4)
        _tb_lay.setSpacing(0)
        self._toolbar_title = PaneTitleBar(
            "", pane_id=tid,
            on_close=lambda: self._hide_pane(PaneKind.TOOLBAR),
            on_drag_start=self._start_pane_drag,
            theme=self.theme)
        self._toolbar_frame = PaneFrame(self._toolbar_title, self._toolbar_body,
                                        pane_id=tid, on_edge_drag_start=self._start_edge_drag,
                                        theme=self.theme, parent=self._pane_container)

        # Canvas pane
        self.tab_widget = QTabWidget()
        self.tab_widget.setTabsClosable(True)
        self.tab_widget.tabBar().setExpanding(False)
        self.tab_widget.tabCloseRequested.connect(self._close_tab)
        self._canvas_title = PaneTitleBar(
            "", pane_id=cid,
            on_close=lambda: self._hide_pane(PaneKind.CANVAS),
            on_maximize_toggle=self._toggle_canvas_maximized,
            on_drag_start=self._start_pane_drag,
            theme=self.theme)
        self._canvas_frame = PaneFrame(self._canvas_title, self.tab_widget,
                                        pane_id=cid, on_edge_drag_start=self._start_edge_drag,
                                        theme=self.theme, parent=self._pane_container)
        # Empty-state logo overlay on the tab widget (top-right, 25% opacity)
        logo_path = _brand_icon_path(256)
        if logo_path:
            src = QPixmap(logo_path).scaled(
                270, 120, Qt.KeepAspectRatio, Qt.SmoothTransformation)
            # Render at 25% opacity into a new pixmap
            faded = QPixmap(src.size())
            faded.fill(Qt.transparent)
            p = QPainter(faded)
            p.setOpacity(0.25)
            p.drawPixmap(0, 0, src)
            p.end()
            lbl = QLabel(self.tab_widget)
            lbl.setPixmap(faded)
            lbl.setAttribute(Qt.WA_TransparentForMouseEvents)
            lbl.setStyleSheet("background: transparent;")
            lbl.setFixedSize(faded.width(), faded.height())
            self._canvas_logo_lbl = lbl
            self._update_canvas_logo()
            self.tab_widget.currentChanged.connect(lambda _: self._update_canvas_logo())

        # YAML interpreter state store
        from workspace_interpreter.state_store import StateStore
        from workspace_interpreter.loader import load_workspace, state_defaults
        from panels.color_bar_widget import register_color_bar
        try:
            import os
            ws_path = os.path.join(os.path.dirname(__file__), "..", "workspace")
            ws = load_workspace(ws_path)
            self._yaml_state = StateStore(state_defaults(ws.get("state", {})))
            # Install the brush library registry consulted by the
            # canvas Path renderer when a path carries a stroke_brush
            # slug. See BRUSHES.md §Stroke styling interaction.
            from canvas.canvas import set_canvas_brush_libraries
            set_canvas_brush_libraries(ws.get("brush_libraries", {}))
        except (OSError, ValueError) as e:
            import logging
            logging.warning(
                "Failed to load workspace from %s; using empty state. Error: %s",
                ws_path, e,
            )
            self._yaml_state = StateStore()
        register_color_bar()

        # Character panel → selection apply pipeline. Subscribes once
        # per lifetime; the panel-scope callback invokes
        # ``apply_character_panel_to_selection`` on every write,
        # flowing panel changes through to the selected element
        # (mirrors the Rust Character-panel wiring).
        from panels.character_panel_state import subscribe as _subscribe_character_panel
        _subscribe_character_panel(self._yaml_state, self.active_model)

        # Paragraph panel → selection apply pipeline (Phase 4). Same
        # subscribe pattern as character — every write into the
        # paragraph_panel_content scope triggers
        # ``apply_paragraph_panel_to_selection`` so widget changes
        # flow through to every paragraph wrapper tspan in the
        # selected text element.
        from panels.paragraph_panel_state import subscribe as _subscribe_paragraph_panel
        _subscribe_paragraph_panel(self._yaml_state, self.active_model)

        # Stroke panel → selection apply pipeline. Subscribes to
        # global writes on stroke render-keys (set: { stroke_X: ... }
        # YAML effect path); mirrors the OCaml subscribe_stroke_panel
        # wiring. The Controller is constructed per-call so it always
        # references the live model.
        from workspace_interpreter.effects import subscribe_stroke_panel as _subscribe_stroke_panel
        from workspace_interpreter.effects import subscribe_active_color as _subscribe_active_color
        from document.controller import Controller as _Controller
        _subscribe_stroke_panel(self._yaml_state,
                                lambda: _Controller(self.active_model()))
        # Active-color writes via the YAML set_active_color action
        # (Swatches Panel swatch click, etc.) propagate to the canvas
        # selection here. The Color Panel's direct set_active_color
        # path already does the apply itself; this catches the YAML
        # route which only updates global state.
        _subscribe_active_color(self._yaml_state,
                                lambda: _Controller(self.active_model()))

        # recent_colors bridge — keep model.recent_colors and the
        # YAML-driven panel.recent_colors of the Color and Swatches
        # panels in sync. Mirrors the Rust strategy of treating
        # model.recent_colors as the single source of truth, but on
        # this side panel state is real (Python jas's panel-state
        # subscriptions need real values). The bridge has two
        # directions, both guarded by an _RC_MIRRORING flag to
        # prevent loops:
        #   1. Native push  (push_recent_color) → mirror into
        #      every panel that defines recent_colors.
        #   2. YAML push    (list_push panel.recent_colors) →
        #      update model.recent_colors and mirror to siblings.
        self._setup_recent_colors_bridge()
        self._setup_color_panel_channel_bridge()
        self._setup_fill_on_top_bridge()

        # Dock pane
        self.dock_panel = DockPanelWidget(self.workspace_layout, get_model=self.active_model,
                                          state_store=self._yaml_state)
        self.dock_panel.setStyleSheet(f"background: {self.theme.pane_bg};")
        self._dock_title = PaneTitleBar(
            "", pane_id=did,
            on_close=lambda: self._hide_pane(PaneKind.DOCK),
            on_drag_start=self._start_pane_drag,
            theme=self.theme)
        self._dock_frame = PaneFrame(self._dock_title, self.dock_panel,
                                      pane_id=did, on_edge_drag_start=self._start_edge_drag,
                                      theme=self.theme,
                                      parent=self._pane_container)

        # Bundle toolbar (STEP A): render the workspace tool_grid into
        # the toolbar pane body and wire the state<->canvas bridge. Done
        # here because it needs both _yaml_state (above) and dock_panel
        # (for _dispatch_yaml_action, which routes the select_tool
        # action).
        self._build_yaml_toolbar()

        # Border handle widgets
        self._border_widgets: list[QWidget] = []
        # Snap preview widgets
        self._snap_widgets: list[QWidget] = []

        self._refresh_pane_positions()

        # Keyboard shortcuts. Single-letter tool / view shortcuts have
        # to defer to the active tool when it captures keyboard (text
        # editing, etc.) — otherwise typing 'V' switches to Selection
        # tool instead of inserting the character. Mirrors the OCaml
        # focus guard in main.ml.
        def _guarded(fn):
            def _wrapper():
                canvas = self.tab_widget.currentWidget()
                if (isinstance(canvas, CanvasWidget)
                        and canvas._active_tool.captures_keyboard()):
                    return
                fn()
            return _wrapper

        # Tool-selection shortcuts are driven by the shared bundle
        # ``shortcuts`` table (TESTING_STRATEGY.md §5 rec 3, Phase 2b) — the
        # SAME table the cross-language key corpus pins and the SAME
        # ``select_tool`` action the bundle toolbar fires. The hardcoded
        # per-tool QShortcut block was replaced by this loop so a single
        # authoritative source (workspace/shortcuts.yaml) now drives both
        # the toolbar and the keyboard. For every entry whose action is
        # ``select_tool`` we register one QShortcut on the entry's key
        # string (Qt's QKeySequence parses "Shift+E", "\\", "=" natively,
        # so the chord match is Qt's; resolve_key need not run live — the
        # SOURCE is the bundle, not hardcoded constants). The bound lambda
        # dispatches ``select_tool`` through the dock panel's YAML action
        # runner (-> run_effects -> set:{active_tool}), which the
        # state->canvas bridge maps back to the native Tool enum; this is
        # byte-for-byte the toolbar click path. The _guarded wrapper still
        # defers to an active keyboard-capturing tool (Type session).
        #
        # Non-select_tool bundle entries (menu/edit/view verbs, the
        # fill/stroke D / X / Shift+X) are NOT registered here — they keep
        # their dedicated native handlers below. Tool keys' framework
        # binding (BINDING step) stays on the manual floor; only the key
        # SOURCE moved to the bundle.
        def _make_tool_shortcut(tool_id):
            def _select():
                self.dock_panel._dispatch_yaml_action(
                    "select_tool", {"tool": tool_id})
            return _guarded(_select)

        for _entry in self._tool_select_shortcuts():
            _key = _entry.get("key")
            _tool_id = (_entry.get("params") or {}).get("tool")
            if not isinstance(_key, str) or not isinstance(_tool_id, str):
                continue
            QShortcut(QKeySequence(_key), self, _make_tool_shortcut(_tool_id))

        # View shortcuts (per ZOOM_TOOL.md §Keyboard shortcuts).
        QShortcut(QKeySequence("Ctrl+0"), self,
                  self._fit_active_artboard)
        QShortcut(QKeySequence("Ctrl+Alt+0"), self,
                  self._fit_all_artboards)
        QShortcut(QKeySequence("Ctrl+1"), self,
                  self._zoom_to_actual_size)
        QShortcut(QKeySequence("Ctrl+="), self, self._zoom_in)
        QShortcut(QKeySequence("Ctrl++"), self, self._zoom_in)
        QShortcut(QKeySequence("Ctrl+-"), self, self._zoom_out)
        QShortcut(QKeySequence(Qt.Key_Delete), self,
                  _guarded(self._delete_selection))
        QShortcut(QKeySequence(Qt.Key_Backspace), self,
                  _guarded(self._delete_selection))
        QShortcut(QKeySequence.StandardKey.Undo, self, self._undo)
        QShortcut(QKeySequence.StandardKey.Redo, self, self._redo)
        QShortcut(QKeySequence("D"), self,
                  _guarded(self._reset_fill_stroke_defaults))
        QShortcut(QKeySequence("X"), self,
                  _guarded(self._toggle_fill_on_top))
        QShortcut(QKeySequence("Shift+X"), self,
                  _guarded(self._swap_fill_stroke))

        # Wire fill/stroke widget signals
        fs = self.toolbar.fill_stroke_widget
        fs.default_clicked.connect(self._reset_fill_stroke_defaults)
        fs.swap_clicked.connect(self._swap_fill_stroke)
        fs.fill_double_clicked.connect(lambda: self._open_color_picker(for_fill=True))
        fs.stroke_double_clicked.connect(lambda: self._open_color_picker(for_fill=False))
        fs.fill_none_clicked.connect(self._set_fill_none)
        fs.stroke_none_clicked.connect(self._set_stroke_none)

        # Restore the previous session's tabs (mirrors jas_dioxus /
        # JasSwift / jas_ocaml). Each restored canvas re-enters via
        # add_canvas so it's wired into the tab widget the same way
        # as freshly opened tabs. Push the [Untitled-N] counter past
        # restored slots so File→New picks an unused number.
        from workspace.session import (
            load_session, advance_next_untitled_past)
        restored = load_session()
        if restored is not None:
            active_idx, tabs = restored
            advance_next_untitled_past([fn for fn, _ in tabs])
            for filename, doc in tabs:
                m = Model(document=doc, filename=filename)
                # Model initializes saved_doc = document so is_modified
                # starts false — restored content is considered
                # saved-state (matches the other apps).
                self.add_canvas(m)
            if active_idx is not None and 0 <= active_idx < self.tab_widget.count():
                self.tab_widget.setCurrentIndex(active_idx)

    def _refresh_pane_positions(self):
        """Position all pane frames from PaneLayout coordinates."""
        pl = self.workspace_layout.panes()
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

        self._update_canvas_logo()

    def _frame_for_kind(self, kind):
        if kind == PaneKind.TOOLBAR: return self._toolbar_frame
        if kind == PaneKind.CANVAS: return self._canvas_frame
        return self._dock_frame

    def _hide_pane(self, kind):
        # 3d-2: route through the runtime layout dispatcher; panes_mut owns the
        # dirty signal (the pane mutators do not bump). layout_apply mutates the
        # same pane_layout the lambda would have.
        from workspace.layout_apply import layout_apply, op_hide_pane
        layout = self.workspace_layout
        layout.panes_mut(lambda pl: layout_apply(layout, op_hide_pane(kind)))
        self._refresh_pane_positions()

    def _toggle_canvas_maximized(self):
        from workspace.layout_apply import layout_apply, op_toggle_canvas_maximized
        layout = self.workspace_layout
        layout.panes_mut(lambda pl: layout_apply(layout, op_toggle_canvas_maximized()))
        self._refresh_pane_positions()

    def _start_pane_drag(self, pane_id, global_x, global_y):
        """Start dragging a pane from its title bar."""
        pl = self.workspace_layout.panes()
        if not pl:
            return
        p = pl.find_pane(pane_id)
        if not p:
            return
        self._pane_drag = (pane_id, global_x - p.x, global_y - p.y)
        # 3d-2: route the front-raise through the runtime dispatcher; panes_mut
        # owns the dirty signal. (This is the drag START click, not the live
        # mid-gesture move below — that stays direct, see _do_pane_drag.)
        from workspace.layout_apply import layout_apply, op_bring_pane_to_front
        layout = self.workspace_layout
        layout.panes_mut(lambda pl: layout_apply(layout, op_bring_pane_to_front(pane_id)))
        self._refresh_pane_positions()
        self.grabMouse()

    def _start_border_drag(self, event, snap_idx, is_vertical):
        coord = event.globalPosition().x() if is_vertical else event.globalPosition().y()
        self._border_drag = (snap_idx, coord, is_vertical)
        self.grabMouse()

    def _start_edge_drag(self, pane_id, edge, gx, gy):
        pl = self.workspace_layout.panes()
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

    def refresh_theme(self):
        """Re-apply theme colors to all themed widgets."""
        from workspace.theme import resolve_appearance
        from workspace.dock_panel import set_theme as set_dock_theme
        self.theme = resolve_appearance(self.app_config.active_appearance)
        set_dock_theme(self.app_config.active_appearance)
        t = self.theme
        self._pane_container.setStyleSheet(f"background: {t.window_bg};")
        self._toolbar_title.apply_theme(t)
        self._canvas_title.apply_theme(t)
        self._dock_title.apply_theme(t)
        self._toolbar_frame.apply_theme(t)
        self._canvas_frame.apply_theme(t)
        self._dock_frame.apply_theme(t)
        self.dock_panel.setStyleSheet(f"background: {t.pane_bg};")
        self.dock_panel.rebuild()

    def resizeEvent(self, event):
        super().resizeEvent(event)
        # Use the pane container size (central widget minus menubar)
        w = self._pane_container.width()
        h = self._pane_container.height()
        if w > 0 and h > 0:
            self.workspace_layout.panes_mut(
                lambda pl: pl.on_viewport_resize(w, h))
            self._refresh_pane_positions()

    def mouseMoveEvent(self, event):
        mx = event.globalPosition().x()
        my = event.globalPosition().y()
        if self._pane_drag:
            pid, off_x, off_y = self._pane_drag
            new_x = mx - off_x
            new_y = my - off_y
            self.workspace_layout.panes_mut(lambda pl: self._do_pane_drag(pl, pid, new_x, new_y))
            self._refresh_pane_positions()
        elif self._border_drag:
            snap_idx, start_coord, is_vert = self._border_drag
            current = mx if is_vert else my
            delta = current - start_coord
            self._border_drag = (snap_idx, current, is_vert)
            self.workspace_layout.panes_mut(
                lambda pl: pl.drag_shared_border(snap_idx, delta))
            self._refresh_pane_positions()
        elif self._edge_drag:
            pid, edge, sx, sy, sw, sh, spx, spy = self._edge_drag
            dx = mx - sx
            dy = my - sy
            self.workspace_layout.panes_mut(
                lambda pl: self._do_edge_drag(pl, pid, edge, dx, dy, sw, sh, spx, spy))
            self._refresh_pane_positions()

    def _do_pane_drag(self, pl, pid, new_x, new_y):
        # DEFERRED (3d-2): live pane-DRAG mid-gesture. set_pane_position is
        # interleaved with snap detection/alignment on the live PaneLayout;
        # re-borrowing the layout through the dispatcher mid-gesture would risk
        # behavior change, so this stays direct (mirrors the Rust app.rs
        # set_pane_position/resize_pane drag deferral).
        from workspace.pane import PaneLayout
        pl.set_pane_position(pid, new_x, new_y)
        preview = pl.detect_snaps(pid, pl.viewport_width, pl.viewport_height)
        if preview:
            pl.align_to_snaps(pid, preview, pl.viewport_width, pl.viewport_height)
        self._snap_preview = preview

    def _do_edge_drag(self, pl, pid, edge, dx, dy, start_w, start_h, start_x, start_y):
        # DEFERRED (3d-2): live pane RESIZE mid-gesture (the resize_pane
        # analogue). Width/height are computed against live snap targets and
        # assigned directly; routing through the dispatcher mid-gesture would
        # risk behavior change, so this stays direct (mirrors Rust resize_pane
        # drag deferral).
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
                self.workspace_layout.panes_mut(
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

    def _abort_active_drag(self) -> None:
        # Defensive: if the window loses focus mid-drag (e.g. cmd-tab
        # while a pane is being moved) Qt may not deliver the matching
        # mouseReleaseEvent, leaving drag state stuck. Drop pending
        # operations and clear all drag bookkeeping. The mouse grab is
        # released here too in case it survived the focus loss.
        if not (self._pane_drag or self._border_drag or self._edge_drag):
            return
        self.releaseMouse()
        self._pane_drag = None
        self._border_drag = None
        self._edge_drag = None
        self._edge_snapped_coord = None
        self._snap_preview = []
        self._refresh_pane_positions()

    def focusOutEvent(self, event):
        self._abort_active_drag()
        super().focusOutEvent(event)

    def hideEvent(self, event):
        self._abort_active_drag()
        super().hideEvent(event)

    def _update_canvas_logo(self) -> None:
        """Show/hide the empty-state logo based on whether any tabs are open."""
        if self._canvas_logo_lbl is None:
            return
        visible = self.tab_widget.count() == 0
        self._canvas_logo_lbl.setVisible(visible)
        if visible:
            tw = self.tab_widget.width()
            lw = self._canvas_logo_lbl.width()
            self._canvas_logo_lbl.move(tw - lw - 10, 10)

    @staticmethod
    def _tool_select_shortcuts() -> list:
        """Return the bundle ``shortcuts`` entries whose action is
        ``select_tool`` (TESTING_STRATEGY.md §5 rec 3, Phase 2b).

        Loaded through the SAME accessor the menu / key_resolver use
        (``key_resolver._load_shortcuts`` -> ``get_workspace_data``), so the
        live keyboard's tool keys and the cross-language key corpus read one
        authoritative table. Entries without a ``select_tool`` action (menu /
        edit / view verbs, the fill/stroke D / X / Shift+X) are filtered out
        — those keep their dedicated native handlers. Returns an empty list
        if the bundle is missing/corrupt (no tool keys, fail-soft).
        """
        from workspace.key_resolver import _load_shortcuts

        out = []
        for entry in _load_shortcuts():
            if isinstance(entry, dict) and entry.get("action") == "select_tool":
                out.append(entry)
        return out

    def _build_yaml_toolbar(self) -> None:
        """Render the bundle toolbar grid into the toolbar pane (STEP A).

        Finds the compiled ``layout -> toolbar_pane -> content ->
        tool_grid`` and renders it through the generic yaml_renderer
        (mirrors Rust YamlToolbarContent). Tool clicks dispatch the
        ``select_tool`` action through the dock panel's YAML dispatcher,
        which writes ``state.active_tool``; a state subscription then
        drives the canvas tool (via the headless native toolbar). The
        native fill/stroke widget is kept below the grid — its actions
        aren't part of the tool_grid node and its app-specific sync
        (_resync_toolbar_fs) is preserved.

        Double-click a tool icon opens its tool-options. The renderer
        installs a dblclick on each is_tool_button slot that reads
        state.active_tool and calls ctx["_open_tool_options"]
        (= self._open_tool_options), which resolves the tool's
        tool_options_panel / _action / _dialog from the bundle and
        dispatches it. This mirrors the old native ToolButton dblclick
        (tool_options_requested -> _open_tool_options_dialog).
        """
        from panels.yaml_renderer import render_element
        from workspace_interpreter.loader import load_workspace

        body_layout = self._toolbar_body.layout()

        grid_el = None
        try:
            ws = load_workspace(os.path.join(_REPO_ROOT, "workspace"))
            layout = ws.get("layout") if ws else None
            pane = self._find_layout_node(layout, "toolbar_pane")
            content = pane.get("content") if isinstance(pane, dict) else None
            for child in (content or {}).get("children", []):
                if isinstance(child, dict) and child.get("id") == "tool_grid":
                    grid_el = child
                    break
        except (OSError, ValueError, AttributeError):
            grid_el = None

        if grid_el is not None:
            ctx = {"_panel_id": "toolbar_pane", "_get_model": self.active_model}
            # Route the slot buttons' mouse_down/mouse_up behavior effects
            # through the dock's runner so the long-press start_timer /
            # cancel_timer fire AND the nested open_dialog actually shows
            # the <slot>_alternates flyout (the plain renderer effect path
            # can only set dialog state, it pops no window). Scoped to the
            # toolbar ctx so other dialogs are unaffected.
            if hasattr(self, "dock_panel") and hasattr(
                    self.dock_panel, "run_behavior_effects"):
                ctx["_run_behavior_effects"] = self.dock_panel.run_behavior_effects
            # Double-click a TOOLBAR tool button -> open the ACTIVE tool's
            # options. The renderer (only for is_tool_button slots) reads
            # state.active_tool and calls this callback, which resolves the
            # tool's tool_options_panel / _action / _dialog from the bundle
            # and dispatches it (mirrors the old native ToolButton dblclick).
            ctx["_open_tool_options"] = self._open_tool_options
            dispatch = (self.dock_panel._dispatch_yaml_action
                        if hasattr(self, "dock_panel") else None)
            grid_widget = render_element(grid_el, self._yaml_state, ctx,
                                         dispatch_fn=dispatch)
            if grid_widget is not None:
                body_layout.addWidget(grid_widget,
                                      alignment=Qt.AlignmentFlag.AlignHCenter)

        # Keep the native fill/stroke widget below the grid (its actions
        # live outside the tool_grid node and its sync is app-native).
        body_layout.addSpacing(8)
        body_layout.addWidget(self.toolbar.fill_stroke_widget,
                              alignment=Qt.AlignmentFlag.AlignHCenter)
        body_layout.addStretch()

        # State -> canvas bridge. Both write paths into the tool grid
        # land in state.active_tool: the select_tool ACTION (single
        # click) and the alternates flyout's set:{active_tool} EFFECT
        # (long-press menu). Subscribing here maps the string back to the
        # native Tool enum and drives the headless toolbar's select_tool,
        # which emits tool_changed -> canvas.set_tool AND keeps the
        # native current_tool / slot state coherent for the spacebar
        # pass-through + keyboard shortcuts. The _bridging guard prevents
        # the reverse bridge (below) from echoing back into a loop.
        self._tool_bridging = False

        def _state_to_canvas(_key, value):
            if self._tool_bridging:
                return
            tool = _TOOL_YAML_ID_TO_ENUM.get(value) if isinstance(value, str) else None
            if tool is None:
                return
            if self.toolbar.current_tool == tool:
                return
            self._tool_bridging = True
            try:
                self.toolbar.select_tool(tool)
            finally:
                self._tool_bridging = False

        self._yaml_state.subscribe(["active_tool"], _state_to_canvas)

        # Reverse bridge: native tool changes (keyboard shortcuts,
        # spacebar pass-through, the headless toolbar's own select_tool)
        # mirror the string back into state.active_tool so the YAML grid
        # highlight tracks. Guarded so the state->canvas bridge above
        # doesn't re-enter.
        def _canvas_to_state(tool):
            if self._tool_bridging:
                return
            yaml_id = self._TOOL_YAML_IDS.get(tool)
            if yaml_id is None:
                return
            self._tool_bridging = True
            try:
                self._yaml_state.set("active_tool", yaml_id)
            finally:
                self._tool_bridging = False

        self.toolbar.tool_changed.connect(_canvas_to_state)

    @staticmethod
    def _find_layout_node(node, node_id):
        """Depth-first search for a layout node with the given id."""
        stack = [node]
        while stack:
            cur = stack.pop()
            if isinstance(cur, dict):
                if cur.get("id") == node_id:
                    return cur
                stack.extend(cur.values())
            elif isinstance(cur, list):
                stack.extend(cur)
        return None

    def add_canvas(self, model: Model) -> None:
        """Create a new canvas tab for the given model."""
        controller = Controller(model=model)
        canvas = CanvasWidget(model=model, controller=controller)
        self.toolbar.tool_changed.connect(canvas.set_tool)
        # Spacebar pass-through routes through the toolbar so its UI
        # stays in sync. Per HAND_TOOL.md §Spacebar pass-through.
        canvas.on_request_tool_change = self.toolbar.select_tool

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

        # Re-sync the Paragraph panel from the active selection on
        # every document change so selecting / deselecting text
        # updates [text_selected] / [area_text_selected] (which gate
        # bind.disabled on the alignment + indent rows). Without this
        # the panel state is frozen at the last set_paragraph_panel_field
        # call and the buttons stick disabled once a stale sync wrote
        # text_selected=false. Mirrors jas_ocaml main.ml.
        # Re-entrancy guard: paragraph_panel_state.subscribe wires
        # apply_paragraph_panel_to_selection to fire on every panel
        # write. Without the guard, apply → model.document= → this
        # listener → sync → set_panel → subscriber → apply → ...
        # recurses until the stack overflows.
        _resync_busy = {"flag": False}

        def _resync_paragraph_panel(_doc=None):
            if _resync_busy["flag"]:
                print("[para_resync] skipped (busy)", flush=True)
                return
            from panels import panel_menu
            store = panel_menu._paragraph_store
            if store is None:
                print("[para_resync] no store", flush=True)
                return
            from panels.paragraph_panel_state import (
                sync_paragraph_panel_from_selection,
            )
            sel_count = len(model.document.selection) if model and model.document else 0
            print(f"[para_resync] firing sel_count={sel_count}", flush=True)
            _resync_busy["flag"] = True
            try:
                sync_paragraph_panel_from_selection(store, model)
            finally:
                _resync_busy["flag"] = False
            ts = store.get_panel("paragraph_panel_content", "text_selected")
            print(f"[para_resync] post-sync text_selected={ts}", flush=True)
        model.on_document_changed(_resync_paragraph_panel)

        # Re-sync the Color panel from the selection's fill/stroke
        # (or the model defaults when nothing is selected) on every
        # document change. Without this, selecting an element with
        # a different fill leaves the Color panel showing the
        # previously-active color and its sliders / hex are out of
        # sync (CLR-022..29 Python).
        color_busy = {"flag": False}

        def _resync_color_panel(_doc=None):
            if color_busy["flag"]:
                return
            if getattr(self, "_color_channel_in_flight", False):
                return  # live drag is owning the writes
            ps = self._yaml_state.get_panel_state("color_panel_content")
            if ps is None:
                return
            fill_color, stroke_color = _selection_fill_and_stroke(model)
            if fill_color is not None:
                self._yaml_state.set("fill_color", "#" + fill_color.to_hex())
            else:
                self._yaml_state.set("fill_color", None)
            if stroke_color is not None:
                self._yaml_state.set("stroke_color", "#" + stroke_color.to_hex())
            else:
                self._yaml_state.set("stroke_color", None)
            active = (fill_color if getattr(model, "fill_on_top", True)
                      else stroke_color)
            if active is None:
                return
            color_busy["flag"] = True
            # Also set _color_channel_in_flight so the channel
            # bridge skips the cascading set_panel writes —
            # otherwise each panel.X write fires the bridge, which
            # mutates the model via set_active_color_live, which
            # fires on_document_changed, which triggers another
            # _resync_color_panel and the cascade can race the
            # selection's actual fill (CLR-218 Python — selection
            # has red, panel ends up showing cyan from a stale
            # cascade step).
            prev_in_flight = getattr(self, "_color_channel_in_flight", False)
            self._color_channel_in_flight = True
            try:
                _sync_panel_channels_from_color(
                    self._yaml_state, active, prior=ps)
            finally:
                self._color_channel_in_flight = prev_in_flight
                color_busy["flag"] = False

        model.on_document_changed(_resync_color_panel)
        # Keep the toolbar's fill/stroke widget in sync with the
        # current selection too — _resync_color_panel mirrors the
        # YAML state, this catches the toolbar widget. Skip while
        # a slider drag owns the writes (the channel bridge
        # already pushed the live color to both widgets).
        def _resync_toolbar_fs(_doc=None):
            if getattr(self, "_color_channel_in_flight", False):
                return
            self._sync_fill_stroke_widget()
        model.on_document_changed(_resync_toolbar_fs)

        # Initial sync — on_document_changed only fires on later
        # mutations, so without these the Color panel and toolbar
        # widget show their YAML defaults until the user moves the
        # selection or edits a color (CLR-022..29 Python). Run
        # synchronously now and again on the next event-loop tick
        # so the resync catches widgets that get constructed
        # after add_canvas finishes (the Color panel's body isn't
        # rendered until the dock rebuilds — its subscribers
        # aren't wired in time to see the synchronous set).
        _resync_color_panel()
        _resync_toolbar_fs()
        from PySide6.QtCore import QTimer
        QTimer.singleShot(0, _resync_color_panel)
        QTimer.singleShot(0, _resync_toolbar_fs)

        tab_label()
        self._update_canvas_logo()

    def active_model(self) -> Model | None:
        """Return the model of the focused canvas tab."""
        canvas = self.tab_widget.currentWidget()
        return canvas._model if isinstance(canvas, CanvasWidget) else None

    def yaml_state(self):
        """Return the app's global YAML StateStore. Used by menu-driven
        dialog open paths so the dialog framework runs against the same
        store as the panels (otherwise dialog state writes wouldn't be
        observable to subscribers, and the Print/Doc Setup dialogs
        couldn't share active-document context with the rest of the
        app)."""
        return self._yaml_state

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
        self._update_canvas_logo()

    def _persist_session(self):
        """Snapshot every open tab to the session directory so the
        next launch re-opens them. Mirrors the other ports."""
        from workspace.session import save_session
        tabs = []
        for i in range(self.tab_widget.count()):
            canvas = self.tab_widget.widget(i)
            if isinstance(canvas, CanvasWidget):
                tabs.append((canvas._model.filename, canvas._model.document))
        active = self.tab_widget.currentIndex()
        save_session(tabs, active if active >= 0 else None)

    def closeEvent(self, event):
        """Intercept window close to prompt for unsaved changes.

        Collects all modified models across tabs. If any are modified, shows
        a dialog with Cancel / Don't Save / Save / Save All. Save saves
        only the active model; Save All saves every modified model. If any
        Save-As dialog is cancelled (model still modified), the close is
        aborted.
        """
        # SIGINT / SIGTERM short-circuit: persist the binary session
        # and bail out without prompting. The session blob captures
        # every tab's full document, so a relaunch restores work in
        # progress without the user having to pick Save vs Discard
        # under signal pressure.
        if getattr(self, "_suppress_unsaved_prompt", False):
            self._persist_session()
            event.accept()
            return
        modified = []
        for i in range(self.tab_widget.count()):
            canvas = self.tab_widget.widget(i)
            if isinstance(canvas, CanvasWidget) and canvas._model.is_modified:
                modified.append(canvas._model)
        if not modified:
            self._persist_session()
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
            self._persist_session()
            event.accept()
        elif box.standardButton(clicked) == QMessageBox.Save:
            from menu.menu import _save
            active = self.active_model()
            if active and active.is_modified:
                _save(self, active)
                if active.is_modified:
                    event.ignore()
                    return
            self._persist_session()
            event.accept()
        elif box.standardButton(clicked) == QMessageBox.Discard:
            self._persist_session()
            event.accept()
        else:
            event.ignore()

    def _active_tool_captures_keyboard(self) -> bool:
        """Return True if the active canvas tool is capturing keyboard input."""
        canvas = self.tab_widget.currentWidget()
        if isinstance(canvas, CanvasWidget) and canvas._active_tool.captures_keyboard():
            return True
        return False

    def _delete_selection(self):
        m = self.active_model()
        if not m:
            return
        doc = m.document
        if not doc.selection:
            return
        # Reference-aware delete: a delete that would orphan a live
        # reference asks for confirmation first (shared with Edit>Delete
        # so both entry points warn identically). Cancel aborts.
        from menu.menu import _confirm_delete_if_orphans, _route_delete_selection
        if not _confirm_delete_if_orphans(m, self):
            return
        # OP_LOG.md §9 — route the keyboard Delete through the SHARED op_apply
        # dispatcher (one named delete_selection op / one undo step), matching the
        # Edit > Delete menu path.
        _route_delete_selection(m, "delete_selection")

    def _zoom_in(self):
        """Zoom in by zoom_step centered at viewport center.
        Per ZOOM_TOOL.md §Keyboard shortcuts and actions."""
        m = self.active_model()
        if not m:
            return
        self._apply_zoom_anchored(m, 1.2,
                                   m.viewport_w / 2.0, m.viewport_h / 2.0)

    def _zoom_out(self):
        m = self.active_model()
        if not m:
            return
        self._apply_zoom_anchored(m, 1.0 / 1.2,
                                   m.viewport_w / 2.0, m.viewport_h / 2.0)

    def _zoom_to_actual_size(self):
        m = self.active_model()
        if not m:
            return
        m.zoom_level = 1.0
        self.canvas.update()

    def _fit_active_artboard(self):
        m = self.active_model()
        if not m:
            return
        artboards = list(m.document.artboards)
        if not artboards:
            return
        ab = artboards[0]
        self._fit_rect(m, float(ab.x), float(ab.y),
                        float(ab.width), float(ab.height), 20.0)

    def _fit_all_artboards(self):
        m = self.active_model()
        if not m:
            return
        artboards = list(m.document.artboards)
        if not artboards:
            return
        min_x = min(float(ab.x) for ab in artboards)
        min_y = min(float(ab.y) for ab in artboards)
        max_x = max(float(ab.x + ab.width) for ab in artboards)
        max_y = max(float(ab.y + ab.height) for ab in artboards)
        self._fit_rect(m, min_x, min_y,
                        max_x - min_x, max_y - min_y, 20.0)

    def _apply_zoom_anchored(self, m, factor: float,
                              ax: float, ay: float) -> None:
        z = m.zoom_level
        px, py = m.view_offset_x, m.view_offset_y
        doc_ax = (ax - px) / z
        doc_ay = (ay - py) / z
        z_new = max(0.1, min(64.0, z * factor))
        m.zoom_level = z_new
        m.view_offset_x = ax - doc_ax * z_new
        m.view_offset_y = ay - doc_ay * z_new
        self.canvas.update()

    def _fit_rect(self, m, x: float, y: float, w: float, h: float,
                  padding: float) -> None:
        if w <= 0 or h <= 0:
            return
        vw, vh = m.viewport_w, m.viewport_h
        if vw <= 0 or vh <= 0:
            return
        avail_w = vw - 2.0 * padding
        avail_h = vh - 2.0 * padding
        if avail_w <= 0 or avail_h <= 0:
            return
        z = max(0.1, min(64.0, min(avail_w / w, avail_h / h)))
        rect_cx = x + w / 2.0
        rect_cy = y + h / 2.0
        m.zoom_level = z
        m.view_offset_x = vw / 2.0 - rect_cx * z
        m.view_offset_y = vh / 2.0 - rect_cy * z
        self.canvas.update()

    def _reset_fill_stroke_defaults(self):
        """Reset fill/stroke to defaults (white fill, 1pt black stroke)."""
        if self._active_tool_captures_keyboard():
            return
        m = self.active_model()
        if m:
            m.default_fill = Fill(color=RgbColor(1.0, 1.0, 1.0))
            m.default_stroke = Stroke(color=RgbColor(0, 0, 0))
            m.fill_on_top = True
            canvas = self.tab_widget.currentWidget()
            if isinstance(canvas, CanvasWidget) and m.document.selection:
                # Fill + stroke as ONE undo step: with_txn opens the bracket,
                # each Controller mutator's edit_document JOINS it.
                m.with_txn(lambda: (
                    canvas._controller.set_selection_fill(m.default_fill),
                    canvas._controller.set_selection_stroke(m.default_stroke)))
        self._sync_fill_stroke_widget()

    def _toggle_fill_on_top(self):
        """Toggle which color (fill or stroke) is in front."""
        if self._active_tool_captures_keyboard():
            return
        m = self.active_model()
        if m:
            m.fill_on_top = not m.fill_on_top
        self._sync_fill_stroke_widget()

    def _swap_fill_stroke(self):
        """Swap the fill and stroke colors."""
        if self._active_tool_captures_keyboard():
            return
        m = self.active_model()
        if m:
            old_fill = m.default_fill
            old_stroke = m.default_stroke
            # Swap: fill color becomes stroke color and vice versa
            if old_stroke is not None:
                m.default_fill = Fill(color=old_stroke.color)
            else:
                m.default_fill = None
            if old_fill is not None:
                m.default_stroke = Stroke(color=old_fill.color)
            else:
                m.default_stroke = None
            canvas = self.tab_widget.currentWidget()
            if isinstance(canvas, CanvasWidget) and m.document.selection:
                # Fill + stroke as ONE undo step: with_txn opens the bracket,
                # each Controller mutator's edit_document JOINS it.
                m.with_txn(lambda: (
                    canvas._controller.set_selection_fill(m.default_fill),
                    canvas._controller.set_selection_stroke(m.default_stroke)))
        self._sync_fill_stroke_widget()

    def _set_fill_none(self):
        """Set fill to none."""
        m = self.active_model()
        if m:
            m.default_fill = None
            canvas = self.tab_widget.currentWidget()
            if isinstance(canvas, CanvasWidget) and m.document.selection:
                # The Controller mutator self-brackets via edit_document.
                canvas._controller.set_selection_fill(None)
        self._sync_fill_stroke_widget()

    def _set_stroke_none(self):
        """Set stroke to none."""
        m = self.active_model()
        if m:
            m.default_stroke = None
            canvas = self.tab_widget.currentWidget()
            if isinstance(canvas, CanvasWidget) and m.document.selection:
                # The Controller mutator self-brackets via edit_document.
                canvas._controller.set_selection_stroke(None)
        self._sync_fill_stroke_widget()

    # Map Tool enum to the workspace/tools/*.yaml filename stem.
    _TOOL_YAML_IDS = {
        Tool.SELECTION: "selection",
        Tool.PARTIAL_SELECTION: "partial_selection",
        Tool.INTERIOR_SELECTION: "interior_selection",
        Tool.MAGIC_WAND: "magic_wand",
        Tool.PEN: "pen",
        Tool.ADD_ANCHOR_POINT: "add_anchor_point",
        Tool.DELETE_ANCHOR_POINT: "delete_anchor_point",
        Tool.ANCHOR_POINT: "anchor_point",
        Tool.PENCIL: "pencil",
        Tool.PAINTBRUSH: "paintbrush",
        Tool.BLOB_BRUSH: "blob_brush",
        Tool.PATH_ERASER: "path_eraser",
        Tool.SMOOTH: "smooth",
        Tool.LINE: "line",
        Tool.RECT: "rect",
        Tool.ROUNDED_RECT: "rounded_rect",
        Tool.ELLIPSE: "ellipse",
        Tool.POLYGON: "polygon",
        Tool.STAR: "star",
        Tool.LASSO: "lasso",
        Tool.SCALE: "scale",
        Tool.ROTATE: "rotate",
        Tool.SHEAR: "shear",
        Tool.EYEDROPPER: "eyedropper",
        Tool.ARTBOARD: "artboard",
    }

    # Map a tool yaml's tool_options_panel id to a PanelKind. The panel
    # id is the bundle's panel content id (e.g. "magic_wand"); the lookup
    # tolerates a trailing "_panel" suffix so either spelling resolves.
    @staticmethod
    def _panel_id_to_kind(panel_id: str):
        from workspace.workspace_layout import PanelKind
        table = {
            "magic_wand": PanelKind.MAGIC_WAND,
        }
        if panel_id in table:
            return table[panel_id]
        if isinstance(panel_id, str) and panel_id.endswith("_panel"):
            return table.get(panel_id[: -len("_panel")])
        return None

    def _open_tool_options_dialog(self, tool):
        """Handler for the old native Toolbar.tool_options_requested
        signal (Tool enum). Maps the enum to its bundle yaml-id and
        delegates to the bundle-driven dispatcher so the native and
        bundle toolbars share one code path."""
        yaml_id = self._TOOL_YAML_IDS.get(tool)
        if yaml_id:
            self._open_tool_options(yaml_id)

    def _open_tool_options(self, active_tool):
        """Open the double-click options for the bundle tool id
        ``active_tool`` (the ``state.active_tool`` string written by the
        bundle toolbar's select_tool action / alternates flyout).

        Resolves the tool's ``tool_options_panel`` / ``_action`` /
        ``_dialog`` from the compiled bundle in priority order (see
        ``tool_options_dispatch``) and dispatches the matching path:

          panel  -> map the panel id to a PanelKind and show/dock it
          action -> dispatch the generic action through the dock runner
          dialog -> open_dialog + show the YamlDialogView

        A tool that declares none is a no-op. This mirrors the old native
        toolbar's tool_options dispatch (Magic Wand panel, Hand/Zoom view
        actions, Paintbrush/Blob Brush/Scale/Rotate/Shear/Eyedropper
        dialogs). See MAGIC_WAND_TOOL.md §Panel, ZOOM_TOOL.md /
        HAND_TOOL.md §Tool options, PAINTBRUSH_TOOL.md §Tool options."""
        from workspace_interpreter.effects import run_effects
        from workspace_interpreter.loader import load_workspace

        ws = load_workspace(os.path.join(_REPO_ROOT, "workspace"))
        if not ws:
            return
        kind_str, target = tool_options_dispatch(ws, active_tool)
        if kind_str is None:
            return

        if kind_str == "panel":
            kind = self._panel_id_to_kind(target)
            if kind is not None:
                # 3d-2: route through the runtime dispatcher (show_panel
                # bumps internally — dirty signal preserved).
                from workspace.layout_apply import layout_apply, op_show_panel
                layout_apply(self.workspace_layout, op_show_panel(kind))
                if hasattr(self, "dock_panel"):
                    self.dock_panel.rebuild_all()
            return

        if kind_str == "action":
            # Generic action/effect dispatcher — the same path single
            # clicks and menu items use (e.g. fit_active_artboard,
            # zoom_to_actual_size, fit_all_artboards).
            if hasattr(self, "dock_panel"):
                self.dock_panel._dispatch_yaml_action(target, {})
            return

        # kind_str == "dialog"
        if not hasattr(self, "_yaml_state") or not self._yaml_state:
            return
        run_effects(
            [{"open_dialog": {"id": target}}],
            {}, self._yaml_state,
            dialogs=ws.get("dialogs"),
        )
        dlg = YamlDialogView(
            target, self._yaml_state,
            dispatch_fn=self.dock_panel._dispatch_yaml_action
                if hasattr(self, "dock_panel") else None,
            parent=self,
        )
        dlg.exec()
        if self._yaml_state.get_dialog_id():
            self._yaml_state.close_dialog()

    def _open_color_picker(self, for_fill: bool):
        """Open the YAML color picker dialog for fill or stroke."""
        from workspace_interpreter.effects import run_effects
        from workspace_interpreter.loader import load_workspace

        m = self.active_model()
        if not m:
            return

        # Build live state with current fill/stroke colors
        def color_hex(c):
            return "#{:02x}{:02x}{:02x}".format(
                int(c.r * 255), int(c.g * 255), int(c.b * 255))

        if not hasattr(self, '_yaml_state') or not self._yaml_state:
            return

        if m.default_fill:
            self._yaml_state.set("fill_color", color_hex(m.default_fill.color))
        if m.default_stroke:
            self._yaml_state.set("stroke_color", color_hex(m.default_stroke.color))

        # Open dialog via effects (initializes dialog state)
        ws = load_workspace("workspace")
        target = "fill" if for_fill else "stroke"
        run_effects(
            [{"open_dialog": {"id": "color_picker", "params": {"target": f'"{target}"'}}}],
            {}, self._yaml_state,
            dialogs=ws.get("dialogs") if ws else None,
        )

        # Show YAML dialog
        dlg = YamlDialogView(
            "color_picker", self._yaml_state,
            dispatch_fn=self.dock_panel._dispatch_yaml_action if hasattr(self, 'dock_panel') else None,
            parent=self,
        )
        dlg.exec()

        # Clean up dialog state
        if self._yaml_state.get_dialog_id():
            self._yaml_state.close_dialog()

    def _sync_fill_stroke_widget(self):
        """Update the toolbar fill/stroke indicator from the current
        selection (or the model defaults when nothing is
        selected). Mirrors the Color panel's swatch — both widgets
        should always show the same colors and z-order.
        """
        m = self.active_model()
        fs = self.toolbar.fill_stroke_widget
        if m is None:
            return
        fill_color, stroke_color = _selection_fill_and_stroke(m)

        def _to_q(c):
            if c is None:
                return None
            r, g, b, _ = c.to_rgba()
            return QColor(round(r * 255), round(g * 255), round(b * 255))

        fs.set_fill_color(_to_q(fill_color))
        fs.set_stroke_color(_to_q(stroke_color))
        fs.set_fill_on_top(m.fill_on_top)

    _RECENT_COLORS_PANELS = ("color_panel_content", "swatches_panel_content")

    def _setup_recent_colors_bridge(self):
        """Two-way sync between model.recent_colors and the YAML
        panel.recent_colors of the Color and Swatches panels.

        Direction 1 (native → YAML): registers a listener on
        push_recent_color so any native-code push (Color Panel
        slider/hex/swatch click) mirrors into every panel-state
        bucket that holds recent_colors.

        Direction 2 (YAML → native): subscribes to the panel state
        of each panel that holds recent_colors so a list_push from a
        YAML behavior (Swatches Panel swatch click → list_push
        panel.recent_colors via the set_active_color action) flows
        back into model.recent_colors and across to the sibling
        panel.

        Both directions go through the shared _RC_MIRRORING flag to
        prevent the writes from echoing into infinite mirror loops.
        """
        from panels.panel_menu import add_recent_colors_listener

        self._rc_mirroring = False

        def _on_native_push(model, _hex):
            if self._rc_mirroring:
                return
            self._rc_mirroring = True
            try:
                for pid in self._RECENT_COLORS_PANELS:
                    ps = self._yaml_state.get_panel_state(pid)
                    if ps is not None:
                        self._yaml_state.set_panel(
                            pid, "recent_colors", list(model.recent_colors))
            finally:
                self._rc_mirroring = False

        add_recent_colors_listener(_on_native_push)

        def _make_panel_listener(panel_id: str):
            def _on_panel_change(key, value):
                if self._rc_mirroring or key != "recent_colors":
                    return
                if not isinstance(value, list):
                    return
                model = self.active_model()
                if model is None or list(model.recent_colors) == list(value):
                    return
                self._rc_mirroring = True
                try:
                    model.recent_colors = list(value)[:10]
                    for pid in self._RECENT_COLORS_PANELS:
                        if pid == panel_id:
                            continue
                        if self._yaml_state.get_panel(pid, "recent_colors") is not None:
                            self._yaml_state.set_panel(
                                pid, "recent_colors", list(model.recent_colors))
                finally:
                    self._rc_mirroring = False
            return _on_panel_change

        # Subscribe each panel's listener lazily — panel state may not
        # be initialized yet at app startup. Wrap the StateStore's
        # subscribe_panel call so we only register once a panel
        # actually becomes visible (init_panel runs at panel mount).
        self._rc_subscribed = set()

        def _ensure_panel_subscribed(panel_id: str):
            if panel_id in self._rc_subscribed:
                return
            if self._yaml_state.get_panel(panel_id, "recent_colors") is None:
                return
            self._yaml_state.subscribe_panel(panel_id, _make_panel_listener(panel_id))
            self._rc_subscribed.add(panel_id)

        # Hook the StateStore's init_panel to subscribe right after a
        # panel boots, so the bridge wires up the moment each panel
        # appears for the first time.
        original_init_panel = self._yaml_state.init_panel

        def _init_panel_hook(panel_id, defaults):
            original_init_panel(panel_id, defaults)
            if panel_id in self._RECENT_COLORS_PANELS:
                _ensure_panel_subscribed(panel_id)

        self._yaml_state.init_panel = _init_panel_hook

        # Catch panels already initialized before this point.
        for pid in self._RECENT_COLORS_PANELS:
            _ensure_panel_subscribed(pid)

    def _setup_fill_on_top_bridge(self):
        """Mirror state.fill_on_top → model.fill_on_top and refresh
        the toolbar's FillStrokeWidget. Without this, clicking the
        Color panel's fill/stroke swatch updates the panel's
        widget but the toolbar's widget stays at the old z-order,
        and the color-channel bridge writes to the wrong side.
        """
        def _on_change(key, value):
            if key != "fill_on_top":
                return
            m = self.active_model()
            if m is None:
                return
            new = bool(value)
            if m.fill_on_top != new:
                m.fill_on_top = new
            self._sync_fill_stroke_widget()
        self._yaml_state.subscribe(["fill_on_top"], _on_change)

    _COLOR_CHANNEL_KEYS = ("h", "s", "b", "r", "g", "bl",
                           "c", "m", "y", "k", "hex")

    def _setup_color_panel_channel_bridge(self):
        """Subscribe to color_panel_content's channel keys (h/s/b/r/
        g/bl/c/m/y/k) so a slider drag or value-box commit
        recomputes the active color from the panel's current mode
        and pushes it onto the model. Mirrors the OCaml
        [_write_back_bind] color-channel branch.
        """
        from panels.panel_menu import set_active_color_live

        self._color_channel_in_flight = False

        def _on_color_panel_change(key, _value):
            if key not in self._COLOR_CHANNEL_KEYS:
                return
            if self._color_channel_in_flight:
                return
            model = self.active_model()
            if model is None:
                return
            ps = self._yaml_state.get_panel_state("color_panel_content") or {}
            mode = ps.get("mode", "hsb")
            # When the user commits the hex field, compute from the
            # typed hex string directly — the per-mode channel
            # values are stale until the bridge round-trips. For
            # all other channels, compute from the mode's tuple.
            if key == "hex":
                from geometry.element import Color
                hex_str = _value if isinstance(_value, str) else ""
                color = Color.from_hex(hex_str)
                # In Web Safe RGB mode, snap each channel to the
                # nearest multiple of 51 on commit so the hex
                # follows the same rule the sliders enforce.
                if color is not None and mode == "web_safe_rgb":
                    r, g, bl, _a = color.to_rgba()
                    def _snap_f(v):
                        return round(v * 255 / 51) * 51 / 255.0
                    color = Color.rgb(_snap_f(r), _snap_f(g), _snap_f(bl))
            else:
                color = _compute_color_from_panel(ps, mode)
            if color is None:
                return
            self._color_channel_in_flight = True
            try:
                if key == "hex":
                    from panels.panel_menu import set_active_color
                    # set_active_color's Controller mutator self-brackets
                    # via edit_document (one undo step).
                    set_active_color(color, model)
                else:
                    set_active_color_live(color, model)
                # Refresh the toolbar widget immediately — the
                # on_document_changed listener for the toolbar
                # bails out when _color_channel_in_flight is set
                # (so live slider drag doesn't fight the bridge),
                # which means hex Enter / channel commits leave
                # the toolbar widget at the pre-edit color until
                # the next doc change. Sync explicitly here.
                self._sync_fill_stroke_widget()
                # Mirror the new color into state.fill_color /
                # stroke_color so the FillStrokeWidget preview
                # swatch (bound to state.fill_color / state.stroke
                # _color) repaints to follow the live drag.
                hex_str = "#" + color.to_hex()
                if getattr(model, "fill_on_top", True):
                    self._yaml_state.set("fill_color", hex_str)
                else:
                    self._yaml_state.set("stroke_color", hex_str)
                # Recompute ALL the sibling channels in panel state
                # so the hex field, the OTHER mode's slider values,
                # and any value box NOT currently driving the edit
                # stay in sync with the new color (e.g. dragging
                # the H slider updates panel.hex / panel.r / .g /
                # .bl etc.). The _color_channel_in_flight guard
                # prevents the recursive set_panel calls from
                # re-entering this bridge.
                # Pass the live panel state so the sync can
                # preserve the user's H value when S/B drag to 0
                # — RGB→HSB collapses H to 0 at zero saturation /
                # brightness (gray / black have no defined hue),
                # and without the preserve the H slider snaps to
                # 0 whenever S or B touches 0.
                # When key="hex" in web_safe mode, the typed hex
                # has been snapped above — overwrite the user's
                # typed text with the snapped form by clearing
                # exclude (the hex field's binding repaints from
                # panel.hex). Otherwise skip the channel being
                # actively edited to avoid fighting the user's
                # input.
                snap_exclude = "" if (key == "hex" and mode == "web_safe_rgb") else key
                _sync_panel_channels_from_color(
                    self._yaml_state, color, exclude=snap_exclude,
                    prior=ps)
            finally:
                self._color_channel_in_flight = False

        def _subscribe():
            self._yaml_state.subscribe_panel(
                "color_panel_content", _on_color_panel_change)

        # Color panel may already be initialized (init_panel ran for
        # the first mount). Subscribe immediately; the state store
        # silently drops the subscription if the panel doesn't yet
        # exist, and the recent-colors bridge's init_panel hook
        # re-registers on remount.
        _subscribe()


def _selection_fill_and_stroke(model):
    """Return (fill_color, stroke_color) for the current selection,
    or the model defaults when nothing is selected. Either / both
    may be None when the element has no fill / stroke.
    """
    if model is None:
        return None, None
    doc = getattr(model, "document", None)
    sel = getattr(doc, "selection", None) if doc is not None else None
    fill_color = None
    stroke_color = None
    if sel:
        first_es = next(iter(sel), None)
        path_tuple = getattr(first_es, "path", first_es)
        if path_tuple is not None:
            elem = _resolve_path(doc, path_tuple)
            if elem is not None:
                fill = getattr(elem, "fill", None)
                if fill is not None:
                    fill_color = fill.color
                stroke = getattr(elem, "stroke", None)
                if stroke is not None:
                    stroke_color = stroke.color
                return fill_color, stroke_color
    # Selection-less: model defaults
    df = getattr(model, "default_fill", None)
    if df is not None:
        fill_color = df.color
    ds = getattr(model, "default_stroke", None)
    if ds is not None:
        stroke_color = ds.color
    return fill_color, stroke_color


def _resolve_path(doc, path):
    """Walk the document tree to the element at the given path tuple.

    Top level is doc.layers (tuple of Layer); each Layer / Group has
    .children (tuple of Element). Walks indices through nested
    children until exhausted, returns the final element.
    """
    if doc is None or path is None:
        return None
    layers = getattr(doc, "layers", None)
    if not layers:
        return None
    cur = None
    items = layers
    try:
        for idx in path:
            cur = items[idx]
            items = getattr(cur, "children", None) or ()
        return cur
    except (IndexError, TypeError):
        return None


def _sync_panel_channels_from_color(store, color, exclude: str = "",
                                     prior: dict | None = None):
    """Recompute every Color panel channel value (h/s/b/r/g/bl/c/m/
    y/k/hex) from [color] and write them back into the
    color_panel_content state. Skips the [exclude] key so the
    widget the user is currently driving (slider being dragged,
    value box being typed in) doesn't fight the user's input.

    [prior] is the panel state from BEFORE the user's edit; used
    to preserve H when S or B drag to 0 (gray and black have no
    defined hue in RGB→HSB conversion, so the recompute would
    snap H to 0 and lose the user's choice).
    """
    import colorsys
    r, g, bl, _ = color.to_rgba()
    ri = int(round(r * 255))
    gi = int(round(g * 255))
    bli = int(round(bl * 255))
    h, s, b = colorsys.rgb_to_hsv(r, g, bl)
    h_deg = int(round(h * 360)) % 360
    s_pct = int(round(s * 100))
    b_pct = int(round(b * 100))
    # Preserve prior H when this RGB has no defined hue (s=0 or
    # b=0). Keeps the H slider sticky while the user drags S/B
    # through zero. Only applies when the user wasn't editing H.
    if prior is not None and exclude != "h" and (s_pct == 0 or b_pct == 0):
        prior_h = prior.get("h")
        if isinstance(prior_h, (int, float)):
            h_deg = int(prior_h)
    # Preserve prior C/M/Y when K=100 (pure black) — CMYK
    # decomposition divides by (1-K) and the c=m=y=0 fallback
    # would silently wipe the user's earlier CMYK values when
    # the user drags grayscale K to 100 or CMYK K to 100.
    # CMYK from RGB
    k = 1.0 - max(r, g, bl)
    if k >= 1.0 - 1e-6:
        c = m = y_c = 0.0
    else:
        c = (1.0 - r - k) / (1.0 - k)
        m = (1.0 - g - k) / (1.0 - k)
        y_c = (1.0 - bl - k) / (1.0 - k)
    c_pct = int(round(c * 100))
    m_pct = int(round(m * 100))
    y_pct = int(round(y_c * 100))
    k_pct = int(round(k * 100))
    # When K=100 the CMYK decomposition is undefined and c/m/y
    # collapse to 0 — preserve the user's prior values so dragging
    # Grayscale K to 100 (or CMYK K to 100) doesn't silently wipe
    # what they had set earlier.
    if prior is not None and k_pct >= 100:
        for src, dst in (("c", "c_pct"), ("m", "m_pct"), ("y", "y_pct")):
            prior_v = prior.get(src)
            if isinstance(prior_v, (int, float)) and exclude != src:
                if dst == "c_pct":
                    c_pct = int(prior_v)
                elif dst == "m_pct":
                    m_pct = int(prior_v)
                elif dst == "y_pct":
                    y_pct = int(prior_v)
    hex_str = color.to_hex()
    writes = {
        "h": h_deg, "s": s_pct, "b": b_pct,
        "r": ri, "g": gi, "bl": bli,
        "c": c_pct, "m": m_pct, "y": y_pct, "k": k_pct,
        "hex": hex_str,
    }
    for key, val in writes.items():
        if key == exclude:
            continue
        store.set_panel("color_panel_content", key, val)


def _compute_color_from_panel(ps, mode):
    """Recompute the active color from a color panel's channel
    values + mode. Returns None when channel values are missing or
    the mode is unrecognised. Mirrors the OCaml
    [_write_back_bind]'s color-channel switch.
    """
    from geometry.element import Color
    import colorsys

    def _f(name):
        v = ps.get(name)
        if isinstance(v, (int, float)):
            return float(v)
        return 0.0

    if mode == "hsb":
        h = _f("h") / 360.0
        s = _f("s") / 100.0
        b = _f("b") / 100.0
        r, g, bl = colorsys.hsv_to_rgb(h, s, b)
        return Color.rgb(r, g, bl)
    if mode in ("rgb", "web_safe_rgb"):
        return Color.rgb(_f("r") / 255.0, _f("g") / 255.0, _f("bl") / 255.0)
    if mode == "grayscale":
        v = 1.0 - _f("k") / 100.0
        return Color.rgb(v, v, v)
    if mode == "cmyk":
        c = _f("c") / 100.0
        m = _f("m") / 100.0
        y = _f("y") / 100.0
        k = _f("k") / 100.0
        r = (1.0 - c) * (1.0 - k)
        g = (1.0 - m) * (1.0 - k)
        bl = (1.0 - y) * (1.0 - k)
        return Color.rgb(r, g, bl)
    return None


def main():
    import logging
    import signal
    from PySide6.QtCore import QTimer

    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
    )
    app = QApplication([])
    window = MainWindow()
    window.resize(1200, 900)
    window.show()

    # Quit gracefully on Ctrl+C / SIGTERM. Closing via signal skips
    # the unsaved-changes prompt — the session persist already
    # snapshots every tab's binary document, so a relaunch picks up
    # exactly where the user left off. The prompt is reserved for
    # explicit window closes where the user is choosing to discard /
    # save / cancel. The second signal falls through to the default
    # handler so a runaway app can still be killed.
    def _shutdown(signum, _frame):
        signal.signal(signum, signal.SIG_DFL)
        window._suppress_unsaved_prompt = True
        window.close()
    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    # Qt's C++ event loop swallows Python signals. A periodic no-op
    # timer hands control back to the interpreter often enough that
    # the SIGINT handler runs in real time instead of waiting for
    # the next mouse / key event.
    _signal_pump = QTimer()
    _signal_pump.start(200)
    _signal_pump.timeout.connect(lambda: None)

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
