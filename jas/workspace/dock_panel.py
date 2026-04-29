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
                body = self._create_panel_body(active)
                vbox.addWidget(body)

        # Separator
        sep = QWidget()
        sep.setFixedHeight(1)
        sep.setStyleSheet(f"background: {THEME_BORDER};")
        vbox.addWidget(sep)

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
            return YamlPanelView(
                panel_spec=panel_spec,
                store=self._state_store,
                dispatch_fn=self._dispatch_yaml_action,
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

            # snapshot: push undo checkpoint on jas Model (replaces
            # the effects.py default which only touches store state —
            # native jas owns undo on the Model).
            def handle_snapshot(_data, _ctx, _store):
                m = self._get_model() if self._get_model else None
                if m is not None:
                    m.snapshot()

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
            }
            # Artboard doc effects — ARTBOARDS.md §Menu, §Reordering,
            # §Artboard Options Dialogue. Seven handlers that mutate
            # model.document.artboards via dataclasses.replace.
            if model is not None:
                from panels.artboard_effects import build_artboard_handlers
                platform_effects.update(build_artboard_handlers(model))

            run_effects(action_def.get("effects", []), ctx, self._state_store,
                       actions=ws.get("actions"),
                       dialogs=ws.get("dialogs"),
                       platform_effects=platform_effects)

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
                body = self._parent_panel._create_panel_body(active)
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
