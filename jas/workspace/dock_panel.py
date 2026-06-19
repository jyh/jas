"""Qt widget for rendering the dock panel system."""

from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton, QSizePolicy, QMenu,
    QScrollArea, QFrame,
)
from PySide6.QtCore import Qt, QMimeData, QPoint
from PySide6.QtGui import QDrag

from workspace.workspace_layout import (
    WorkspaceLayout, DockEdge, PanelKind, GroupAddr, PanelAddr,
)
# 3d-2: the runtime layout-op dispatcher. Production dock-panel mutations build
# a resolved op via the typed op_* builders and route through layout_apply so
# they share ONE per-verb mutation body with the cross-language harness. The
# panel/dock verbs (close/reorder/move/detach_group/redock/set_active/toggle)
# bump WorkspaceLayout internally, preserving the dirty signal.
from workspace.layout_apply import (
    layout_apply, op_toggle_group_collapsed, op_set_active_panel,
    op_reorder_panel, op_move_panel_to_group, op_detach_group, op_redock,
)
from panels.panel_menu import panel_label, panel_menu, panel_dispatch, panel_is_checked, PanelMenuItemKind
from panels.yaml_menu import get_panel_spec, get_workspace_data, build_qmenu, panel_label_from_yaml
from panels.yaml_panel_view import YamlPanelView

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
    """Grip handle that starts a group drag on mouse press+move.
    When the drop lands outside any dock area, ``on_external_drop`` is
    called with the global cursor position so the caller can detach
    the group into a floating dock."""
    def __init__(self, payload: str, on_external_drop=None, parent=None):
        super().__init__("\u2801\u2801", parent)
        self._payload = payload
        self._on_external_drop = on_external_drop
        self.setStyleSheet(f"color: {THEME_TEXT_HINT}; font-size: 10px; padding: 2px 4px;")
        self.setCursor(Qt.OpenHandCursor)

    def mouseMoveEvent(self, event):
        drag = QDrag(self)
        mime = QMimeData()
        mime.setData(DOCK_DRAG_MIME, self._payload.encode())
        drag.setMimeData(mime)
        result = drag.exec(Qt.MoveAction)
        if result == Qt.IgnoreAction and self._on_external_drop is not None:
            from PySide6.QtGui import QCursor
            pt = QCursor.pos()
            self._on_external_drop(self._payload, pt.x(), pt.y())


class DraggableTabButton(QPushButton):
    """Tab button that starts a panel drag on mouse press+move.
    When the drop lands outside any dock area, ``on_external_drop`` is
    called with the global cursor position so the caller can detach
    the panel into a floating dock."""
    def __init__(self, label: str, payload: str, on_external_drop=None, parent=None):
        super().__init__(label, parent)
        self._payload = payload
        self._on_external_drop = on_external_drop
        self.setFlat(True)

    def mouseMoveEvent(self, event):
        drag = QDrag(self)
        mime = QMimeData()
        mime.setData(DOCK_DRAG_MIME, self._payload.encode())
        drag.setMimeData(mime)
        result = drag.exec(Qt.MoveAction)
        if result == Qt.IgnoreAction and self._on_external_drop is not None:
            from PySide6.QtGui import QCursor
            pt = QCursor.pos()
            self._on_external_drop(self._payload, pt.x(), pt.y())


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
                # DEFERRED (3d-2): move_group_within_dock / move_group_to_dock
                # are dock GROUP-MOVE verbs NOT in the 15-verb dispatcher
                # vocabulary; they stay direct (mirrors Rust dock group-move).
                if from_addr.dock_id == self._dock_id:
                    self._layout_data.move_group_within_dock(self._dock_id, from_addr.group_idx, self._gi)
                else:
                    self._layout_data.move_group_to_dock(from_addr, self._dock_id, self._gi)
            elif parts[0] == "panel" and len(parts) == 4:
                from_addr = PanelAddr(group=GroupAddr(dock_id=int(parts[1]), group_idx=int(parts[2])), panel_idx=int(parts[3]))
                if from_addr.group == target:
                    layout_apply(self._layout_data, op_reorder_panel(
                        target, from_addr.panel_idx, len(self._group.panels)))
                else:
                    layout_apply(self._layout_data, op_move_panel_to_group(from_addr, target))
        except (IndexError, ValueError):
            return
        event.acceptProposedAction()
        self._rebuild()


class DockPanelWidget(QWidget):
    """Renders an anchored dock with panel groups, tab bars, and placeholders."""

    def __init__(self, workspace_layout: WorkspaceLayout, edge: DockEdge = DockEdge.RIGHT,
                 get_model=None, state_store=None):
        super().__init__()
        self._layout_data = workspace_layout
        self._edge = edge
        self._get_model = get_model
        self._state_store = state_store
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
            self._notify_window_dock_changed()
            return

        if dock.collapsed:
            self.setFixedWidth(36)
            self._build_collapsed(dock)
        else:
            self.setFixedWidth(int(dock.width))
            self._build_expanded(dock)
        self._notify_window_dock_changed()

    def _notify_window_dock_changed(self) -> None:
        # Fire the window's Window-menu checkmark resync if it has one
        # — drag-out to floating, header X close, and layout-restore
        # all change panel visibility without going through the menu's
        # _toggle_panel path, so without this the checkmarks would
        # stay stuck on stale state. Mirrors the OCaml dock_refresh →
        # sync_panel_checks wiring.
        win = self.window()
        if win is None:
            return
        syncer = getattr(win, 'sync_panel_menu_checks', None)
        if callable(syncer):
            try:
                syncer()
            except Exception:
                pass

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
        # Toggle button (stays outside the scroll area so it's always
        # visible at the top of the dock).
        toggle = QPushButton("\u25B6")
        toggle.setFixedHeight(20)
        toggle.setFlat(True)
        toggle.clicked.connect(lambda: self._toggle_dock(dock.id))
        self._vbox.addWidget(toggle)

        # Wrap panel groups in a QScrollArea so the combined min-
        # height of all expanded panels can exceed the dock's
        # allocated height \u2014 the user scrolls instead of having
        # panels squeezed below their content's required size.
        # widgetResizable=True lets the inner widget grow with the
        # scroll area's width (we still want full panel width).
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        scroll.setVerticalScrollBarPolicy(Qt.ScrollBarAlwaysOn)
        scroll.setFrameShape(QFrame.NoFrame)
        # macOS uses overlay scrollbars by default — they paint on
        # top of the viewport rather than taking width from it,
        # which clips right-anchored panel content like the slider
        # value boxes. Force a styled non-overlay scrollbar via QSS
        # AND reserve its width by setting an explicit viewport
        # right margin so the inner widget stops before the bar.
        scroll.setStyleSheet(
            "QScrollBar:vertical { background: transparent; "
            "width: 12px; margin: 0; }"
            "QScrollBar::handle:vertical { background: #5a5a5a; "
            "border-radius: 4px; min-height: 24px; }"
            "QScrollBar::handle:vertical:hover { background: #6a6a6a; }"
            "QScrollBar::add-line:vertical, "
            "QScrollBar::sub-line:vertical { height: 0; border: 0; }"
            "QScrollBar::add-page:vertical, "
            "QScrollBar::sub-page:vertical { background: transparent; }"
        )
        inner = QWidget()
        # Lock the inner widget to dock.width - scrollbar width so
        # panel groups (and their slider value boxes) don't extend
        # under the scrollbar. On macOS the native QScrollArea
        # viewport doesn't always reserve room for a styled QSS
        # scrollbar; fixing the inner width sidesteps that.
        inner.setFixedWidth(max(0, int(dock.width) - 12))
        inner_vbox = QVBoxLayout(inner)
        inner_vbox.setContentsMargins(0, 0, 0, 0)
        inner_vbox.setSpacing(0)
        for gi, group in enumerate(dock.groups):
            group_widget = self._build_panel_group(dock.id, gi, group)
            inner_vbox.addWidget(group_widget)
        inner_vbox.addStretch()
        scroll.setWidget(inner)
        self._vbox.addWidget(scroll)

    def _build_panel_group(self, dock_id, gi, group):
        widget = DroppablePanelGroup(self._layout_data, dock_id, gi, group, self.rebuild_all)
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
        grip = DraggableGrip(f"group:{dock_id}:{gi}",
                             on_external_drop=self._on_external_drop)
        hbox.addWidget(grip)

        # Tab buttons (draggable — drags individual panel)
        for pi, kind in enumerate(group.panels):
            lbl = panel_label(kind)
            btn = DraggableTabButton(lbl, f"panel:{dock_id}:{gi}:{pi}",
                                     on_external_drop=self._on_external_drop)
            is_active = pi == group.active
            weight = "bold" if is_active else "normal"
            bg = THEME_BG_TAB if is_active else THEME_BG_TAB_INACTIVE
            btn.setStyleSheet(f"font-size: 11px; font-weight: {weight}; color: {THEME_TEXT}; background: {bg}; border: none; padding: 3px 8px;")
            btn.clicked.connect(lambda _, d=dock_id, g=gi, p=pi: self._set_active(d, g, p))
            hbox.addWidget(btn)

        hbox.addStretch()

        # Chevron \u2014 when expanded points \u00BB (click to collapse toward
        # the right edge); when collapsed points \u00AB (click to expand
        # back). Mirrors OCaml dock_panel.ml.
        chevron = QPushButton("\u00AB" if group.collapsed else "\u00BB")
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
                body = self._create_panel_body(active)
                vbox.addWidget(body)

        # Separator
        sep = QWidget()
        sep.setFixedHeight(1)
        sep.setStyleSheet(f"background: {THEME_BORDER};")
        vbox.addWidget(sep)

        # Propagate the body's min-height (which the renderer set
        # from the panel content's required height) up to the
        # group, plus the tab bar + separator overhead. This lets
        # the dock's outer scroll area allocate enough vertical
        # room for each group without forcing width constraints
        # (which would clip the scrollbar over panel content).
        total_h = 0
        for i in range(vbox.count()):
            item = vbox.itemAt(i)
            if item is None or item.widget() is None:
                continue
            total_h += item.widget().minimumHeight() or item.widget().sizeHint().height()
        if total_h > 0:
            widget.setMinimumHeight(total_h)

        return widget

    def _create_panel_body(self, kind: PanelKind) -> QWidget:
        """Create a panel body widget, using YAML interpreter when available."""
        panel_spec = get_panel_spec(kind)
        if panel_spec and panel_spec.get("content") and self._state_store is not None:
            # Build context with workspace data so repeat sources like
            # data.swatch_libraries[lib.id] can resolve at render time
            ctx: dict = {}
            ws = get_workspace_data()
            if ws:
                data: dict = {}
                if "swatch_libraries" in ws:
                    data["swatch_libraries"] = ws["swatch_libraries"]
                if "brush_libraries" in ws:
                    data["brush_libraries"] = ws["brush_libraries"]
                if data:
                    ctx["data"] = data
            # Pass model accessor so panels (e.g. layers) can read/write the document
            if self._get_model:
                ctx["_get_model"] = self._get_model
                # active_document: exposes has_selection / selection_count /
                # element_selection (plus layers rollups) to bind.disabled /
                # bind.visible predicates during render. Built fresh per
                # body creation; live panels re-render via store
                # subscriptions when state changes.
                from panels.active_document_view import (
                    build_active_document_view, build_selection_predicates,
                )
                model = self._get_model() if self._get_model else None
                ctx["active_document"] = build_active_document_view(model)
                # OPACITY.md §States: surface the three predicates at
                # the top level so yaml expressions like
                # `bind.checked: "selection_mask_clip"` and
                # `bind.disabled: "!selection_has_mask"` resolve
                # uniformly. Mirrors `build_selection_predicates` in
                # jas_dioxus.
                ctx.update(build_selection_predicates(model))
                # document namespace — exposes per-document fields the
                # YAML reads but the StateStore has no native source
                # for. Currently just recent_colors, used by panel
                # init expressions (color, swatches) so the recent
                # strip seeds with the model's actual recent colors
                # rather than the YAML default of [].
                if model is not None:
                    ctx["document"] = {
                        "recent_colors": list(getattr(model, "recent_colors", [])),
                    }
            # Wrap dispatch_fn so each widget click in this panel
            # first re-points the store's active panel id to this
            # panel's content id. Without this, list_push effects
            # (panel.recent_colors) write to whichever panel was
            # last initialized — typically a sibling — and the
            # Color panel's Black / White / Recent swatches never
            # add to recent_colors (CLR-012 Python).
            panel_id = panel_spec.get("id", "")
            def _dispatch_with_active(action_name, params, _pid=panel_id):
                if _pid and self._state_store is not None:
                    self._state_store.set_active_panel(_pid)
                return self._dispatch_yaml_action(action_name, params)
            return YamlPanelView(
                panel_spec=panel_spec,
                store=self._state_store,
                dispatch_fn=_dispatch_with_active,
                ctx=ctx,
            )
        # Fallback: simple label placeholder
        body = QLabel(panel_label(kind))
        body.setStyleSheet(f"color: {THEME_TEXT_BODY}; font-size: 12px; padding: 12px;")
        body.setMinimumHeight(60)
        body.setAlignment(Qt.AlignTop | Qt.AlignLeft)
        return body

    def _dispatch_yaml_action(self, action_name: str, params: dict):
        """Dispatch an action from a YAML panel behavior."""
        from panels.yaml_menu import PANEL_KIND_TO_CONTENT_ID
        from workspace_interpreter.effects import run_effects

        # Native intercept: Symbols panel operations (SYMBOLS.md §7, §8).
        # These mint ids by the value-in-op rule and call the shared
        # symbol Controller ops, so the YAML actions are `log` stubs (like
        # the make_instance arm in menu.py). The panel-selected master id
        # lives in the store under the panel CONTENT id
        # (symbols_panel_content), key selected_symbol, so the YAML body's
        # `panel.selected_symbol` row-highlight + footer-disabled binds
        # resolve at render. Handled before the generic effect path.
        if action_name in ("symbols_panel_select", "new_symbol",
                            "place_instance", "delete_symbol_action",
                            "delete_symbol_orphan_confirm_ok"):
            if self._dispatch_symbols_action(action_name, params):
                return

        # Look up the action in the workspace
        ws = get_workspace_data()
        if ws and action_name in ws.get("actions", {}):
            action_def = ws["actions"][action_name]
            # Build active_document from model so artboard / layer
            # expressions resolve against the jas dataclass document.
            # The state store's view operates on its internal dict
            # representation (empty for native jas) so we must supply
            # our own.
            model = self._get_model() if self._get_model else None
            ctx: dict = {}
            if model is not None:
                from panels.active_document_view import (
                    build_active_document_view, sync_document_to_store,
                )
                ab_panel = self._state_store.get_panel_state("artboards") if self._state_store else {}
                ab_sel_raw = ab_panel.get("artboards_panel_selection", []) if isinstance(ab_panel, dict) else []
                ab_sel = [s for s in ab_sel_raw if isinstance(s, str)] if isinstance(ab_sel_raw, list) else []
                ctx["active_document"] = build_active_document_view(
                    model, artboards_panel_selection=ab_sel,
                )
                # Mirror model → store so dialog get/set cross-scope
                # bindings (evaluated in store.get_dialog /
                # store.set_dialog) see the jas document, not the
                # empty store default. Required for ARTBOARDS
                # reference-point transforms (panel.reference_point
                # picks anchor_offset_x / y relative to the current
                # artboard's width / height).
                sync_document_to_store(model, self._state_store)
            if params:
                ctx["param"] = params

            # Check if a dialog was open before running effects
            dialog_before = self._state_store.get_dialog_id() if self._state_store else None

            # Platform effects for timers
            def handle_start_timer(data, ctx, store):
                from panels.timer_manager import TimerManager
                timer_id = data.get("id", "") if isinstance(data, dict) else ""
                delay_ms = data.get("delay_ms", 250) if isinstance(data, dict) else 250
                nested = data.get("effects", []) if isinstance(data, dict) else []
                TimerManager.shared().start_timer(timer_id, delay_ms, lambda: (
                    run_effects(nested, ctx, store,
                               actions=ws.get("actions"),
                               dialogs=ws.get("dialogs")),
                    self._check_dialog_opened(store),
                ))

            def handle_cancel_timer(data, ctx, store):
                from panels.timer_manager import TimerManager
                timer_id = data if isinstance(data, str) else ""
                TimerManager.shared().cancel_timer(timer_id)

            # Boolean panel destructive ops. See BOOLEAN.md §Panel actions.
            # Each effect key (e.g. `boolean_union: true`) calls the shared
            # apply_destructive_boolean routine with the matching op name.
            # DIVIDE / TRIM / MERGE ship in phase 9e.
            def _make_boolean_handler(op_name):
                def handle(data, ctx, store):
                    from panels.boolean_apply import apply_destructive_boolean
                    model = self._get_model() if self._get_model else None
                    if model is not None:
                        opts = _boolean_options_from_store(store)
                        apply_destructive_boolean(model, op_name, opts)
                return handle

            def _make_compound_creation_handler(op_name):
                def handle(data, ctx, store):
                    from panels.boolean_apply import apply_compound_creation
                    model = self._get_model() if self._get_model else None
                    if model is not None:
                        apply_compound_creation(model, op_name)
                return handle

            def _boolean_options_from_store(store):
                """Build BooleanOptions from document state. Defaults
                come from BooleanOptions() when keys are absent."""
                from panels.boolean_apply import BooleanOptions
                defaults = BooleanOptions()
                if store is None:
                    return defaults
                precision = store.get("boolean_precision")
                rrp = store.get("boolean_remove_redundant_points")
                drup = store.get("boolean_divide_remove_unpainted")
                return BooleanOptions(
                    precision=float(precision) if isinstance(precision, (int, float))
                        else defaults.precision,
                    remove_redundant_points=bool(rrp) if isinstance(rrp, bool)
                        else defaults.remove_redundant_points,
                    divide_remove_unpainted=bool(drup) if isinstance(drup, bool)
                        else defaults.divide_remove_unpainted,
                )

            def handle_repeat_boolean_operation(data, ctx, store):
                from panels.boolean_apply import apply_repeat_boolean_operation
                model = self._get_model() if self._get_model else None
                if model is None or store is None:
                    return
                last = store.get("last_boolean_op")
                if not isinstance(last, str) or not last:
                    return
                opts = _boolean_options_from_store(store)
                apply_repeat_boolean_operation(model, last, opts)

            def handle_reset_boolean_panel(data, ctx, store):
                # Per BOOLEAN.md: only clears last_boolean_op (handled
                # by the yaml `set` effect in the same action). No
                # extra state to tear down in Python.
                return

            def handle_make_compound_shape(data, ctx, store):
                from panels.boolean_apply import apply_make_compound_shape
                model = self._get_model() if self._get_model else None
                if model is not None:
                    apply_make_compound_shape(model)

            def handle_release_compound_shape(data, ctx, store):
                from panels.boolean_apply import apply_release_compound_shape
                model = self._get_model() if self._get_model else None
                if model is not None:
                    apply_release_compound_shape(model)

            def handle_expand_compound_shape(data, ctx, store):
                from panels.boolean_apply import apply_expand_compound_shape
                model = self._get_model() if self._get_model else None
                if model is not None:
                    apply_expand_compound_shape(model)

            # snapshot: OPEN the undo transaction on the jas Model (replaces
            # the effects.py default which only touches store state — native jas
            # owns undo on the Model). OP_LOG.md Increment 1: begin_txn opens the
            # bracket so the subsequent doc.* writes (enforced set_document
            # chokepoint) are legal; run_effects (passed `model` below) OWNS the
            # commit, making the whole action one undo step. Mirrors the
            # yaml_tool / Rust doc.snapshot => begin_txn path.
            def handle_snapshot(_data, _ctx, _store):
                m = self._get_model() if self._get_model else None
                if m is not None:
                    m.begin_txn()

            # Paragraph panel menu items (PARAGRAPH.md §Menu): each
            # action's effects use one of these platform handlers to
            # mutate panel state + the wrapper tspans of the current
            # selection. Mirrors the Rust paragraph_panel.rs dispatch
            # branch and the Swift PanelMenu paragraph cases.
            def handle_toggle_paragraph_field(data, _ctx, store):
                # data is the field name (e.g. "hanging_punctuation").
                # Flip the panel-state bool, push to wrappers via the
                # standard apply pipeline.
                m = self._get_model() if self._get_model else None
                if not isinstance(data, str) or m is None or store is None:
                    return
                from panels.paragraph_panel_state import (
                    set_paragraph_panel_field,
                )
                cur = store.get_panel("paragraph_panel_content", data)
                set_paragraph_panel_field(store, m, data, not bool(cur))

            def handle_reset_paragraph_panel(_data, _ctx, store):
                m = self._get_model() if self._get_model else None
                if m is None or store is None:
                    return
                from panels.paragraph_panel_state import (
                    reset_paragraph_panel,
                )
                reset_paragraph_panel(store, m)

            platform_effects = {
                "start_timer": handle_start_timer,
                "cancel_timer": handle_cancel_timer,
                "boolean_union": _make_boolean_handler("union"),
                "boolean_intersection": _make_boolean_handler("intersection"),
                "boolean_exclude": _make_boolean_handler("exclude"),
                "boolean_subtract_front": _make_boolean_handler("subtract_front"),
                "boolean_subtract_back": _make_boolean_handler("subtract_back"),
                "boolean_crop": _make_boolean_handler("crop"),
                "boolean_divide": _make_boolean_handler("divide"),
                "boolean_trim": _make_boolean_handler("trim"),
                "boolean_merge": _make_boolean_handler("merge"),
                "boolean_union_compound": _make_compound_creation_handler("union"),
                "boolean_subtract_front_compound": _make_compound_creation_handler("subtract_front"),
                "boolean_intersection_compound": _make_compound_creation_handler("intersection"),
                "boolean_exclude_compound": _make_compound_creation_handler("exclude"),
                "make_compound_shape": handle_make_compound_shape,
                "release_compound_shape": handle_release_compound_shape,
                "expand_compound_shape": handle_expand_compound_shape,
                "repeat_boolean_operation": handle_repeat_boolean_operation,
                "reset_boolean_panel": handle_reset_boolean_panel,
                "snapshot": handle_snapshot,
                "toggle_paragraph_field": handle_toggle_paragraph_field,
                "reset_paragraph_panel": handle_reset_paragraph_panel,
            }
            # Artboard doc effects — ARTBOARDS.md §Menu, §Reordering,
            # §Artboard Options Dialogue. Seven handlers that mutate
            # model.document.artboards via dataclasses.replace.
            if model is not None:
                from panels.artboard_effects import build_artboard_handlers
                platform_effects.update(build_artboard_handlers(model))

            # Pass `model` (+ action_name) so run_effects OWNS the transaction
            # the snapshot effect opened and commits it once (one undo step).
            run_effects(action_def.get("effects", []), ctx, self._state_store,
                       actions=ws.get("actions"),
                       dialogs=ws.get("dialogs"),
                       platform_effects=platform_effects,
                       model=model, action_name=action_name)

            # If a dialog was opened by the effect, show it
            self._check_dialog_opened(self._state_store, dialog_before)

            self.rebuild()
            return

        # Fallback: route through legacy dispatch for known actions
        active_panel = self._state_store.get_active_panel_id() if self._state_store else None
        if active_panel:
            # Find the PanelKind for the active panel
            for kind, cid in PANEL_KIND_TO_CONTENT_ID.items():
                if cid == active_panel:
                    addr = PanelAddr(group=GroupAddr(dock_id=0, group_idx=0), panel_idx=0)
                    self._dispatch_yaml_cmd(kind, action_name, params, addr)
                    return

    def _dispatch_symbols_action(self, action_name: str, params: dict) -> bool:
        """Native arms for the Symbols panel (SYMBOLS.md §7, §8), modeled
        on menu._link_to_selection (Make Instance) + the layers-panel
        reference-aware delete confirm. Returns True when handled (the
        caller then skips the generic YAML effect path).

        The panel-selected master id is stored under the panel content id
        ``symbols_panel_content`` (key ``selected_symbol``) so the YAML
        body's ``panel.selected_symbol`` binds resolve at render. Mirrors
        the Rust dispatch_action symbols intercept (value-in-op minting;
        one snapshot per op; reference-aware delete warns when the master
        still has live instances)."""
        store = self._state_store
        if store is None:
            return True
        pid = "symbols_panel_content"
        # Ensure the panel scope exists so the selection write lands even
        # when the panel has not been mounted yet (set_panel is a no-op on
        # an uninitialised scope). The selection is app-level state, like
        # the Rust AppState.symbols_selected, not gated on panel mount.
        if not store.get_panel_state(pid):
            store.init_panel(pid, {"selected_symbol": None})

        # Panel-select: replace the single-master selection with this id.
        if action_name == "symbols_panel_select":
            symbol_id = params.get("symbol_id") if params else None
            store.set_panel(pid, "selected_symbol", symbol_id)
            self.rebuild()
            return True

        from panels.symbols_apply import (
            apply_new_symbol, apply_place_instance, apply_delete_symbol,
            symbol_usage_count,
        )
        model = self._get_model() if self._get_model else None
        if model is None:
            return True

        if action_name == "new_symbol":
            # Promote the single canvas selection; keep the new master
            # panel-selected so Place/Delete target it immediately.
            new_id = apply_new_symbol(model)
            if new_id is not None:
                store.set_panel(pid, "selected_symbol", new_id)
            self.rebuild()
            return True

        if action_name == "place_instance":
            master_id = store.get_panel(pid, "selected_symbol")
            apply_place_instance(model, master_id if isinstance(master_id, str) else None)
            self.rebuild()
            return True

        if action_name == "delete_symbol_action":
            master_id = store.get_panel(pid, "selected_symbol")
            master_id = master_id if isinstance(master_id, str) else None
            if master_id is None:
                return True
            usage = symbol_usage_count(model, master_id)
            if usage > 0:
                # Reference-aware confirm: this app's native modal, the
                # same idiom as the layers-panel orphan confirm. The body
                # wording matches the shared delete_symbol_orphan_confirm
                # dialog ("Deleting will leave N live instance(s) empty.").
                if not self._confirm_delete_symbol(usage):
                    return True
            apply_delete_symbol(model, master_id)
            store.set_panel(pid, "selected_symbol", None)
            self.rebuild()
            return True

        if action_name == "delete_symbol_orphan_confirm_ok":
            # Confirmed delete from the warn path (kept for parity with
            # the shared action id; the native modal above already gates
            # the deletion, so this commits unconditionally).
            master_id = store.get_panel(pid, "selected_symbol")
            master_id = master_id if isinstance(master_id, str) else None
            if master_id is not None:
                apply_delete_symbol(model, master_id)
                store.set_panel(pid, "selected_symbol", None)
            self.rebuild()
            return True

        return True

    def _confirm_delete_symbol(self, count: int) -> bool:
        """Reference-aware delete confirm for the Symbols panel. Native
        modal whose default is the safe Cancel; returns True only on OK.
        Body wording mirrors the shared delete_symbol_orphan_confirm
        dialog, with singular / plural agreement."""
        from PySide6.QtWidgets import QMessageBox
        noun = "instance" if count == 1 else "instances"
        body = f"Deleting will leave {count} live {noun} empty."
        reply = QMessageBox.question(
            self, "Delete Symbol", body,
            QMessageBox.Cancel | QMessageBox.Ok, QMessageBox.Cancel)
        return reply == QMessageBox.Ok

    def _check_dialog_opened(self, store, dialog_before=None):
        """Show a YAML dialog if one was opened by effects."""
        dialog_after = store.get_dialog_id() if store else None
        if dialog_after and dialog_after != dialog_before:
            self._show_yaml_dialog(dialog_after)
            self.rebuild()

    def _show_yaml_dialog(self, dialog_id: str):
        """Show a YAML-interpreted dialog."""
        from panels.yaml_dialog_view import YamlDialogView
        # Build active_document ctx from jas model + current artboards
        # panel selection so dialog bind.* expressions referencing
        # active_document resolve against live document state (Phase F
        # cross-scope wiring).
        dialog_ctx: dict = {}
        model = self._get_model() if self._get_model else None
        if model is not None:
            from panels.active_document_view import (
                build_active_document_view, sync_document_to_store,
            )
            ab_panel = self._state_store.get_panel_state("artboards") if self._state_store else {}
            ab_sel_raw = ab_panel.get("artboards_panel_selection", []) if isinstance(ab_panel, dict) else []
            ab_sel = [s for s in ab_sel_raw if isinstance(s, str)] if isinstance(ab_sel_raw, list) else []
            dialog_ctx["active_document"] = build_active_document_view(
                model, artboards_panel_selection=ab_sel,
            )
            sync_document_to_store(model, self._state_store)
        dlg = YamlDialogView(dialog_id, self._state_store,
                             dispatch_fn=self._dispatch_yaml_action,
                             ctx=dialog_ctx,
                             parent=self)
        dlg.exec()
        # Clean up dialog state if still open
        if self._state_store and self._state_store.get_dialog_id():
            self._state_store.close_dialog()

    def _toggle_dock(self, dock_id):
        self._layout_data.toggle_dock_collapsed(dock_id)
        self.rebuild()

    def _toggle_group(self, dock_id, group_idx):
        layout_apply(self._layout_data, op_toggle_group_collapsed(
            GroupAddr(dock_id=dock_id, group_idx=group_idx)))
        self.rebuild()

    def _set_active(self, dock_id, group_idx, panel_idx):
        layout_apply(self._layout_data, op_set_active_panel(
            PanelAddr(group=GroupAddr(dock_id=dock_id, group_idx=group_idx), panel_idx=panel_idx)))
        self.rebuild()

    def _on_external_drop(self, payload: str, x: int, y: int):
        """Drop landed outside any dock area — detach the dragged
        panel or group into a floating dock at the cursor."""
        parts = payload.split(":")
        try:
            if parts[0] == "panel" and len(parts) == 4:
                from_addr = PanelAddr(
                    group=GroupAddr(dock_id=int(parts[1]), group_idx=int(parts[2])),
                    panel_idx=int(parts[3]))
                # DEFERRED (3d-2): detach_panel is NOT in the 15-verb dispatcher
                # vocabulary (only detach_group is); stays direct.
                self._layout_data.detach_panel(from_addr, float(x), float(y))
            elif parts[0] == "group" and len(parts) == 3:
                from_addr = GroupAddr(dock_id=int(parts[1]), group_idx=int(parts[2]))
                layout_apply(self._layout_data, op_detach_group(
                    from_addr, float(x), float(y)))
        except (IndexError, ValueError):
            return
        self.rebuild_all()

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

        # Apply the active theme to the menu so item text matches
        # the dock chrome's text color — without this Qt picks the
        # default system menu colors which can render dark on dark
        # in the Dark Gray appearance.
        menu.setStyleSheet(
            f"QMenu {{ background: {THEME_BG_DARK}; color: {THEME_TEXT}; "
            f"border: 1px solid {THEME_BORDER}; }}"
            f"QMenu::item {{ padding: 4px 18px; }}"
            f"QMenu::item:selected {{ background: {THEME_BG_TAB}; }}"
            f"QMenu::item:disabled {{ color: {THEME_TEXT_HINT}; }}"
            f"QMenu::separator {{ height: 1px; background: {THEME_BORDER}; "
            f"margin: 4px 6px; }}"
        )
        menu.exec(self.cursor().pos())

    def _get_panel_state(self, kind: PanelKind) -> dict:
        """Get current panel-local state for expression evaluation."""
        if kind == PanelKind.COLOR:
            return {"mode": self._layout_data.color_panel_mode}
        if kind == PanelKind.SYMBOLS and self._state_store is not None:
            # Surface the panel-selected master id so the Symbols menu's
            # enabled_when ("panel.selected_symbol != null") on Place
            # Instance / Delete Symbol resolves to the live selection.
            sel = self._state_store.get_panel(
                "symbols_panel_content", "selected_symbol")
            return {"selected_symbol": sel}
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
            # Also push the mode into the YAML panel state so the
            # color panel's `visible: panel.mode == "<mode>"`
            # bindings on the per-mode slider columns re-evaluate
            # and only the selected mode's sliders show. Without
            # this the layout's color_panel_mode is updated but the
            # panel state's `mode` key stays at its init value, so
            # the visible sliders don't change (CLR-022 Python).
            if self._state_store is not None:
                self._state_store.set_panel("color_panel_content", "mode", mode)
                # Switching to Web Safe RGB snaps the current
                # color to the nearest web-safe step (multiples of
                # 51). Other modes don't snap. Mirrors the OCaml
                # set_color_panel_mode → web-safe-snap branch.
                if mode == "web_safe_rgb":
                    ps = self._state_store.get_panel_state(
                        "color_panel_content") or {}
                    def _snap(name):
                        v = ps.get(name)
                        if isinstance(v, (int, float)):
                            n = int(round(v / 51.0) * 51)
                            n = max(0, min(255, n))
                            self._state_store.set_panel(
                                "color_panel_content", name, n)
                    _snap("r"); _snap("g"); _snap("bl")
        elif action_name == "invert_active_color":
            panel_dispatch(kind, "invert_color", addr, self._layout_data,
                          model=self._get_model() if self._get_model else None)
        elif action_name == "complement_active_color":
            panel_dispatch(kind, "complement_color", addr, self._layout_data,
                          model=self._get_model() if self._get_model else None)
        elif action_name == "close_panel":
            panel_dispatch(kind, "close_panel", addr, self._layout_data)
        else:
            # YAML-defined actions (artboards, etc.) run through the
            # full effects dispatcher — panel_dispatch only handles
            # hardcoded commands.
            ws = get_workspace_data()
            if ws and action_name in ws.get("actions", {}):
                self._dispatch_yaml_action(action_name, params)
                return
            # Generic fallback — try as direct command
            panel_dispatch(kind, action_name, addr, self._layout_data,
                          model=self._get_model() if self._get_model else None)
        self.rebuild()

    def _dispatch_panel_cmd(self, kind, cmd, addr):
        model = self._get_model() if self._get_model else None
        panel_dispatch(kind, cmd, addr, self._layout_data, model=model)
        self.rebuild()

    def _expand_to(self, dock_id, group_idx, panel_idx):
        # toggle_dock_collapsed is NOT a 15-verb dispatcher op (only
        # toggle_group_collapsed is) — DEFERRED, stays direct. The
        # set_active_panel half routes through the dispatcher.
        self._layout_data.toggle_dock_collapsed(dock_id)
        layout_apply(self._layout_data, op_set_active_panel(
            PanelAddr(group=GroupAddr(dock_id=dock_id, group_idx=group_idx), panel_idx=panel_idx)))
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

        grip = DraggableGrip(f"group:{dock_id}:{gi}",
                             on_external_drop=self._on_external_drop)
        hbox.addWidget(grip)

        for pi, kind in enumerate(group.panels):
            label = panel_label(kind)
            btn = DraggableTabButton(label, f"panel:{dock_id}:{gi}:{pi}",
                                     on_external_drop=self._on_external_drop)
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
                body = self._parent_panel._create_panel_body(active)
                vbox.addWidget(body)

        return widget

    def _set_active(self, dock_id, group_idx, panel_idx):
        layout_apply(self._layout_data, op_set_active_panel(
            PanelAddr(group=GroupAddr(dock_id=dock_id, group_idx=group_idx), panel_idx=panel_idx)))
        self._parent_panel.rebuild_floating()

    def _on_external_drop(self, payload: str, x: int, y: int):
        """Drop landed outside any dock — for a floating panel that
        means the user dropped onto empty desktop. Re-anchor the
        floating dock at the cursor; no detach needed since it's
        already floating."""
        self._layout_data.set_floating_position(
            self._fd.dock.id, float(x), float(y))
        self._parent_panel.rebuild_all()

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
            layout_apply(self._layout_data, op_redock(self._fd.dock.id))
            self._parent_panel.rebuild_all()
        super().mouseDoubleClickEvent(event)
