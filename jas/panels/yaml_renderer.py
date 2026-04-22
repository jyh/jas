"""YAML element tree to QWidget renderer.

Interprets workspace YAML element specs and builds corresponding Qt
widget trees. Handles style, bind, behavior, and repeat directives.
"""

from __future__ import annotations

from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QGridLayout, QLabel,
    QPushButton, QSlider, QSpinBox, QLineEdit, QCheckBox,
    QComboBox, QFrame, QSizePolicy, QSpacerItem,
)
from PySide6.QtCore import Qt

from workspace_interpreter.expr import evaluate, evaluate_text
from workspace_interpreter.state_store import StateStore
from panels import widget_registry


def render_element(el: dict, store: StateStore, ctx: dict,
                   dispatch_fn=None) -> QWidget | None:
    """Recursively render a YAML element spec into a QWidget tree.

    Args:
        el: The element spec dict from workspace YAML.
        store: Reactive state store.
        ctx: Additional evaluation context (theme, data, etc.).
        dispatch_fn: Callback(action_name, params) for behavior dispatch.

    Returns:
        A QWidget, or None if the element can't be rendered.
    """
    if not isinstance(el, dict):
        return None

    # Handle repeat directive
    if "foreach" in el and "do" in el:
        return _render_repeat(el, store, ctx, dispatch_fn)

    etype = el.get("type", "placeholder")

    # Check native widget registry first
    native = widget_registry.create(etype, el, store, ctx)
    if native is not None:
        _apply_style(native, el.get("style", {}), store, ctx)
        _apply_bindings(native, el.get("bind", {}), store, ctx)
        _apply_behaviors(native, el.get("behavior", []), store, ctx, dispatch_fn)
        return native

    # Built-in type dispatch
    renderer = _RENDERERS.get(etype, _render_placeholder)
    widget = renderer(el, store, ctx, dispatch_fn)

    if widget is None:
        return None

    _apply_style(widget, el.get("style", {}), store, ctx)
    _apply_bindings(widget, el.get("bind", {}), store, ctx)
    _apply_behaviors(widget, el.get("behavior", []), store, ctx, dispatch_fn)

    return widget


# ── Renderers ────────────────────────────────────────────────


def _render_container(el, store, ctx, dispatch_fn):
    widget = QWidget()
    layout_dir = el.get("layout", "column")
    if layout_dir == "row":
        layout = QHBoxLayout(widget)
    else:
        layout = QVBoxLayout(widget)
    layout.setContentsMargins(0, 0, 0, 0)

    style = el.get("style", {})
    if "gap" in style:
        layout.setSpacing(int(style["gap"]))
    if "padding" in style:
        p = _parse_padding(style["padding"])
        layout.setContentsMargins(*p)

    for child in el.get("children", []):
        child_widget = render_element(child, store, ctx, dispatch_fn)
        if child_widget:
            layout.addWidget(child_widget)

    return widget


def _render_grid(el, store, ctx, dispatch_fn):
    widget = QWidget()
    layout = QGridLayout(widget)
    layout.setContentsMargins(0, 0, 0, 0)
    cols = el.get("cols", 2)
    gap = el.get("gap", 0)
    layout.setSpacing(gap)

    for i, child in enumerate(el.get("children", [])):
        child_widget = render_element(child, store, ctx, dispatch_fn)
        if child_widget:
            grid_pos = child.get("grid", {})
            row = grid_pos.get("row", i // cols)
            col = grid_pos.get("col", i % cols)
            layout.addWidget(child_widget, row, col)

    return widget


def _render_text(el, store, ctx, dispatch_fn):
    content = el.get("content", "")
    if isinstance(content, str) and "{{" in content:
        content = evaluate_text(content, store.eval_context(ctx))
    label = QLabel(str(content))
    label.setWordWrap(True)
    return label


def _render_button(el, store, ctx, dispatch_fn):
    static_label = el.get("label", "")
    bind = el.get("bind", {}) if isinstance(el.get("bind"), dict) else {}
    # bind.label: expression whose evaluated string replaces the
    # static label. op_make_mask uses this to flip between
    # "Make Mask" and "Release" based on selection_has_mask per
    # OPACITY.md §States.
    label_expr = bind.get("label") if isinstance(bind.get("label"), str) else None
    if label_expr:
        eval_ctx = store.eval_context(ctx)
        result = evaluate(label_expr, eval_ctx)
        label = result.value if isinstance(result.value, str) else static_label
    else:
        label = static_label
    btn = QPushButton(label)
    # Opacity panel: op_make_mask dispatches Controller make or
    # release based on selection_has_mask. The button has no
    # `action` in yaml — routing is resolved here against the
    # panel id and the element id. Mirrors the Rust and Swift
    # special-cases.
    if ctx.get("_panel_id") == "opacity_panel_content" and el.get("id") == "op_make_mask":
        get_model = ctx.get("_get_model")
        def _on_click():
            model = get_model() if callable(get_model) else None
            if model is None:
                return
            from document.controller import Controller, selection_has_mask
            ctrl = Controller(model=model)
            if selection_has_mask(model.document):
                ctrl.release_mask_on_selection()
            else:
                # clip / invert come from the panel state store's
                # new_masks_clipping / new_masks_inverted keys.
                panel_state = store.get_panel_state("opacity_panel_content") or {}
                clip = bool(panel_state.get("new_masks_clipping", True))
                invert = bool(panel_state.get("new_masks_inverted", False))
                ctrl.make_mask_on_selection(clip=clip, invert=invert)
        btn.clicked.connect(_on_click)
    return btn


def _render_icon_button(el, store, ctx, dispatch_fn):
    summary = el.get("summary", "")
    btn = QPushButton(summary)
    btn.setFlat(True)
    # bind.icon: expression whose evaluated string names the icon
    # glyph. Python's icon_button currently shows the summary as
    # its label rather than the glyph; the resolved icon name is
    # evaluated here so a future glyph-rendering pass can pick it
    # up without another YAML change. Used by op_link_indicator to
    # flip between ``link_linked`` / ``link_unlinked`` as
    # mask.linked changes.
    bind = el.get("bind", {}) if isinstance(el.get("bind"), dict) else {}
    icon_expr = bind.get("icon") if isinstance(bind.get("icon"), str) else None
    if icon_expr:
        evaluate(icon_expr, store.eval_context(ctx))
    _wire_opacity_link_indicator_click(btn, el, ctx)
    return btn


def _wire_opacity_link_indicator_click(btn: QPushButton, el: dict, ctx: dict):
    """Opacity panel: op_link_indicator click toggles mask.linked
    on every selected mask via Controller. OPACITY.md §Document
    model. Mirrors the Rust / Swift / OCaml special-cases.
    """
    if ctx.get("_panel_id") != "opacity_panel_content":
        return
    if el.get("id") != "op_link_indicator":
        return
    get_model = ctx.get("_get_model")
    def _on_click():
        model = get_model() if callable(get_model) else None
        if model is None:
            return
        from document.controller import Controller
        Controller(model=model).toggle_mask_linked_on_selection()
    btn.clicked.connect(lambda _=None: _on_click())


def _render_slider(el, store, ctx, dispatch_fn):
    slider = QSlider(Qt.Horizontal)
    slider.setMinimum(el.get("min", 0))
    slider.setMaximum(el.get("max", 100))
    slider.setSingleStep(el.get("step", 1))
    return slider


def _render_number_input(el, store, ctx, dispatch_fn):
    spin = QSpinBox()
    spin.setMinimum(el.get("min", 0))
    spin.setMaximum(el.get("max", 100))
    return spin


def _render_text_input(el, store, ctx, dispatch_fn):
    edit = QLineEdit()
    placeholder = el.get("placeholder", "")
    if placeholder:
        edit.setPlaceholderText(str(placeholder))
    max_len = el.get("max_length")
    if max_len:
        edit.setMaxLength(int(max_len))
    return edit


def _render_toggle(el, store, ctx, dispatch_fn):
    label = el.get("label", "")
    cb = QCheckBox(label)
    _wire_opacity_mask_checkbox(cb, el, store, ctx)
    return cb


def _render_checkbox(el, store, ctx, dispatch_fn):
    label = el.get("label", "")
    cb = QCheckBox(label)
    _wire_opacity_mask_checkbox(cb, el, store, ctx)
    return cb


def _wire_opacity_mask_checkbox(cb: QCheckBox, el: dict, store: StateStore, ctx: dict):
    """Opacity panel selection-mask bindings route write-backs to
    the document controller (the flag lives on the selected
    element's mask, not on a panel-state key). See OPACITY.md
    §States. Mirrors the Rust and Swift special-cases.
    """
    if ctx.get("_panel_id") != "opacity_panel_content":
        return
    bind = el.get("bind", {}) if isinstance(el.get("bind"), dict) else {}
    checked_expr = bind.get("checked") if isinstance(bind.get("checked"), str) else None
    if checked_expr not in ("selection_mask_clip", "selection_mask_invert"):
        return
    get_model = ctx.get("_get_model")
    route = "clip" if checked_expr == "selection_mask_clip" else "invert"
    def _on_toggled(state):
        model = get_model() if callable(get_model) else None
        if model is None:
            return
        from document.controller import Controller
        ctrl = Controller(model=model)
        new_val = bool(state)
        if route == "clip":
            ctrl.set_mask_clip_on_selection(new_val)
        else:
            ctrl.set_mask_invert_on_selection(new_val)
    cb.toggled.connect(_on_toggled)


def _render_select(el, store, ctx, dispatch_fn):
    combo = QComboBox()
    for opt in el.get("options", []):
        if isinstance(opt, dict):
            combo.addItem(opt.get("label", ""), opt.get("value", ""))
        else:
            combo.addItem(str(opt), str(opt))
    return combo


def _render_combo_box(el, store, ctx, dispatch_fn):
    combo = QComboBox()
    combo.setEditable(True)
    for opt in el.get("options", []):
        if isinstance(opt, dict):
            combo.addItem(opt.get("label", ""), opt.get("value", ""))
        else:
            combo.addItem(str(opt), str(opt))
    return combo


def _render_color_swatch(el, store, ctx, dispatch_fn):
    btn = QPushButton()
    size = el.get("style", {}).get("size", 16)
    btn.setFixedSize(int(size), int(size))
    btn.setFlat(True)
    # Color is set by binding
    return btn


def _render_separator(el, store, ctx, dispatch_fn):
    frame = QFrame()
    orientation = el.get("orientation", "horizontal")
    if orientation == "vertical":
        frame.setFrameShape(QFrame.VLine)
        frame.setFixedWidth(1)
    else:
        frame.setFrameShape(QFrame.HLine)
        frame.setFixedHeight(1)
    return frame


def _render_spacer(el, store, ctx, dispatch_fn):
    widget = QWidget()
    policy = QSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
    widget.setSizePolicy(policy)
    return widget


def _render_disclosure(el, store, ctx, dispatch_fn):
    """Collapsible section with a label and content."""
    widget = QWidget()
    layout = QVBoxLayout(widget)
    layout.setContentsMargins(0, 0, 0, 0)
    layout.setSpacing(0)

    label_text = el.get("label", "")
    if isinstance(label_text, str) and "{{" in label_text:
        label_text = evaluate_text(label_text, store.eval_context(ctx))

    header = QPushButton(f"\u25BC {label_text}")
    header.setFlat(True)
    header.setStyleSheet("text-align: left; padding: 2px 4px; font-weight: bold; font-size: 11px;")
    layout.addWidget(header)

    content_widget = QWidget()
    content_layout = QVBoxLayout(content_widget)
    content_layout.setContentsMargins(0, 0, 0, 0)
    for child in el.get("children", []):
        child_widget = render_element(child, store, ctx, dispatch_fn)
        if child_widget:
            content_layout.addWidget(child_widget)
    layout.addWidget(content_widget)

    # Toggle collapse
    def toggle():
        visible = not content_widget.isVisible()
        content_widget.setVisible(visible)
        header.setText(f"{'▼' if visible else '▶'} {label_text}")

    header.clicked.connect(toggle)

    return widget


def _render_panel(el, store, ctx, dispatch_fn):
    """Panel wrapper — renders the content element."""
    content = el.get("content")
    if isinstance(content, dict):
        return render_element(content, store, ctx, dispatch_fn)
    return _render_placeholder(el, store, ctx, dispatch_fn)


def _make_element_preview(elem, size: int):
    """Render a fitted-viewBox SVG thumbnail for an element as a Qt widget.

    Uses QSvgWidget if available (PySide6.QtSvgWidgets); otherwise falls
    back to a white square.
    """
    try:
        from PySide6.QtSvgWidgets import QSvgWidget
        from PySide6.QtCore import QByteArray
        from geometry.svg import element_svg
        bx, by, bw, bh = elem.bounds()
        if not (bw > 0 and bh > 0):
            frame = QFrame()
            frame.setFixedSize(size, size)
            frame.setFrameStyle(QFrame.Box)
            frame.setStyleSheet("background: white;")
            return frame
        pad = max(max(bw, bh) * 0.02, 0.5)
        vb = f"{bx - pad} {by - pad} {bw + 2*pad} {bh + 2*pad}"
        inner = element_svg(elem, "")
        svg = (
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" '
            f'preserveAspectRatio="xMidYMid meet">{inner}</svg>'
        )
        w = QSvgWidget()
        w.renderer().load(QByteArray(svg.encode("utf-8")))
        w.setFixedSize(size, size)
        w.setStyleSheet("background: white; border: 1px solid #555;")
        return w
    except Exception:
        frame = QFrame()
        frame.setFixedSize(size, size)
        frame.setFrameStyle(QFrame.Box)
        frame.setStyleSheet("background: white;")
        return frame


_LAYER_COLORS = [
    "#4a90d9", "#d94a4a", "#4ad94a", "#4a4ad9", "#d9d94a",
    "#d94ad9", "#4ad9d9", "#b0b0b0", "#2a7a2a",
]

_TYPE_LABELS = {
    "Line": "Line", "Rect": "Rectangle", "Circle": "Circle",
    "Ellipse": "Ellipse", "Polyline": "Polyline", "Polygon": "Polygon",
    "Path": "Path", "Text": "Text", "TextPath": "Text Path",
    "Group": "Group", "Layer": "Layer",
}

def _element_type_label(elem):
    return _TYPE_LABELS.get(type(elem).__name__, type(elem).__name__)

def _element_display_name(elem):
    from geometry.element import Layer
    if isinstance(elem, Layer) and elem.name:
        return elem.name, True
    return f"<{_element_type_label(elem)}>", False

def _vis_icon(vis):
    from geometry.element import Visibility
    if vis == Visibility.OUTLINE: return "\u25d0"
    if vis == Visibility.INVISIBLE: return "\u25cb"
    return "\u25c9"

def _cycle_visibility(vis):
    from geometry.element import Visibility
    if vis == Visibility.PREVIEW: return Visibility.OUTLINE
    if vis == Visibility.OUTLINE: return Visibility.INVISIBLE
    return Visibility.PREVIEW

def _render_tree_view(el, store, ctx, dispatch_fn):
    """Render a tree_view widget from the live document model."""
    from dataclasses import replace as dc_replace
    from geometry.element import Group, Layer, Visibility
    from document.document import ElementSelection

    widget = QWidget()
    layout = QVBoxLayout(widget)
    layout.setContentsMargins(0, 0, 0, 0)
    layout.setSpacing(0)
    widget.setFocusPolicy(Qt.StrongFocus)

    get_model = ctx.get("_get_model")
    if not get_model:
        layout.addStretch()
        return widget

    model = get_model()
    if model is None:
        layout.addStretch()
        return widget

    doc = model.document
    selected_paths = doc.selected_paths()

    # Track collapsed paths, panel-selected paths, renaming path, drag
    # state, and advanced UI state as closure state (persists across rebuilds).
    collapsed = set()
    panel_selection = set()
    panel_selection_order = []  # for shift-range selection anchor
    renaming_path = [None]
    drag_source = [None]
    drag_target = [None]
    search_query = [""]
    isolation_stack = []  # list of container paths
    solo_state = [None]  # (soloed_path, {sibling_path: saved_visibility}) or None
    saved_lock_states = {}  # container_path -> list of child bool
    hidden_types = set()  # element type names currently hidden

    def _flatten(elements, depth, path_prefix, layer_color, rows):
        for i in reversed(range(len(elements))):
            elem = elements[i]
            path = path_prefix + (i,)
            is_container = isinstance(elem, Group)
            is_selected = path in selected_paths
            is_collapsed = path in collapsed
            is_panel_sel = path in panel_selection
            cur_color = _LAYER_COLORS[i % len(_LAYER_COLORS)] if isinstance(elem, Layer) and len(path) == 1 else layer_color
            name, is_named = _element_display_name(elem)
            rows.append((depth, path, elem, name, is_named, is_selected, is_panel_sel, is_container, is_collapsed, cur_color))
            if is_container and not is_collapsed and hasattr(elem, 'children'):
                _flatten(elem.children, depth + 1, path, cur_color, rows)

    def _apply_search_filter(rows):
        """Keep rows whose name contains the search query (case-insensitive),
        plus their ancestor rows for context."""
        q = search_query[0].lower()
        if not q:
            return rows
        matching = [r for r in rows if q in r[3].lower()]
        matching_paths = {r[1] for r in matching}
        keep = set(matching_paths)
        for p in matching_paths:
            for j in range(1, len(p)):
                keep.add(p[:j])
        return [r for r in rows if r[1] in keep]

    def _type_value_from_elem(elem):
        return type(elem).__name__.lower().replace("rect", "rectangle").replace("textpath", "text_path")

    def _apply_type_filter(rows):
        """Hide rows whose type is in hidden_types; keep ancestors for context."""
        if not hidden_types:
            return rows
        # Index: path -> elem
        path_to_elem = {r[1]: r[2] for r in rows}
        visible = {r[1] for r in rows if _type_value_from_elem(r[2]) not in hidden_types}
        keep = set(visible)
        for p in visible:
            for j in range(1, len(p)):
                keep.add(p[:j])
        return [r for r in rows if r[1] in keep]

    def _apply_isolation_filter(rows):
        """Keep only rows that are strict descendants of the deepest isolated
        container, and reduce their depths so the subtree starts at 0."""
        if not isolation_stack:
            return rows
        root = isolation_stack[-1]
        out = []
        for depth, path, elem, name, is_named, is_sel, is_psel, is_cont, is_coll, lcolor in rows:
            if len(path) > len(root) and path[:len(root)] == root:
                new_depth = depth - len(root)
                out.append((new_depth, path, elem, name, is_named, is_sel, is_psel, is_cont, is_coll, lcolor))
        return out

    def _auto_expand_selected():
        """Remove ancestors of selected paths from the collapsed set so the
        selected element is visible."""
        for p in selected_paths:
            for j in range(1, len(p)):
                collapsed.discard(p[:j])

    _row_widgets = {}  # path -> QWidget for scroll-to
    _current_visible_rows = [[]]  # captured rows list for shift-range selection

    def _scroll_to_selected(rows):
        """Scroll the first selected row into view."""
        if not selected_paths:
            return
        first = sorted(selected_paths)[0]
        w = _row_widgets.get(first)
        if w is not None:
            try:
                # Ensure parent scroll area scrolls to this widget
                parent = widget.parentWidget()
                while parent is not None:
                    from PySide6.QtWidgets import QScrollArea
                    if isinstance(parent, QScrollArea):
                        parent.ensureWidgetVisible(w)
                        break
                    parent = parent.parentWidget()
            except Exception:
                pass

    def _add_breadcrumb_bar(parent_layout):
        """Render breadcrumb path when in isolation mode."""
        bar = QWidget()
        bl = QHBoxLayout(bar)
        bl.setContentsMargins(6, 2, 6, 2)
        bl.setSpacing(4)
        bar.setStyleSheet("background:#2a2a2a; border-bottom:1px solid #555;")

        # Home button
        home = QPushButton("⌂")
        home.setFlat(True)
        home.setStyleSheet("color:#ccc; font-size:10px; padding:0 4px;")
        def _on_home():
            isolation_stack.clear()
            _rebuild()
        home.clicked.connect(_on_home)
        bl.addWidget(home)

        m = get_model()
        if m is not None:
            for idx, p in enumerate(isolation_stack):
                sep = QLabel(">")
                sep.setStyleSheet("color:#999; font-size:10px;")
                bl.addWidget(sep)
                e = m.document.get_element(p)
                if isinstance(e, Layer) and e.name:
                    lbl_text = e.name
                else:
                    lbl_text = f"<{type(e).__name__}>"
                btn = QPushButton(lbl_text)
                btn.setFlat(True)
                btn.setStyleSheet("color:#ccc; font-size:10px; padding:0 4px;")
                target_idx = idx + 1
                def _on_seg(checked=False, ti=target_idx):
                    del isolation_stack[ti:]
                    _rebuild()
                btn.clicked.connect(_on_seg)
                bl.addWidget(btn)
        bl.addStretch()
        parent_layout.addWidget(bar)

    # Read search query and hidden types from panel state
    try:
        panel_state = store.get_active_panel_state()
        search_query[0] = str(panel_state.get("search_query", "") or "")
        ht = panel_state.get("_hidden_types", None)
        if ht is not None:
            hidden_types.clear()
            hidden_types.update(ht)
    except Exception:
        pass

    # Context menu action helpers
    def _enter_isolation(p):
        isolation_stack.append(p)
        _rebuild()

    def _exit_isolation():
        if isolation_stack:
            isolation_stack.pop()
        _rebuild()

    def _dispatch_with_selection(action_name, clear_selection=True):
        """Route a layers action through the YAML dispatch with the
        current panel selection, then refresh the tree."""
        m = get_model()
        if m is None or not panel_selection:
            return
        from jas.panels.panel_menu import _dispatch_yaml_layers_action
        _dispatch_yaml_layers_action(
            action_name, m,
            panel_selection=list(panel_selection),
        )
        if clear_selection:
            panel_selection.clear()
            panel_selection_order.clear()
        _rebuild()

    def _do_delete():
        m = get_model()
        if m is None or not panel_selection:
            return
        # Guard: refuse to delete every top-level layer.
        top_deletes = sum(1 for pp in panel_selection if len(pp) == 1)
        if top_deletes >= len(m.document.layers):
            return
        _dispatch_with_selection("delete_layer_selection")

    def _do_duplicate():
        # duplicate_layer_selection keeps the caller's selection intact
        # so the user can continue operating on the original paths.
        _dispatch_with_selection("duplicate_layer_selection",
                                  clear_selection=False)

    def _do_flatten():
        _dispatch_with_selection("flatten_artwork")

    def _do_collect():
        _dispatch_with_selection("collect_in_new_layer")

    def _open_layer_options(p):
        # Minimal dialog: edit name + lock + visibility
        from PySide6.QtWidgets import (QDialog, QVBoxLayout, QHBoxLayout,
                                        QLineEdit, QCheckBox, QLabel,
                                        QDialogButtonBox)
        m = get_model()
        if m is None:
            return
        e = m.document.get_element(p)
        if not isinstance(e, Layer):
            return
        dlg = QDialog(widget)
        dlg.setWindowTitle("Layer Options")
        dv = QVBoxLayout(dlg)
        # Name
        name_row = QHBoxLayout()
        name_row.addWidget(QLabel("Name:"))
        name_edit = QLineEdit(e.name)
        name_row.addWidget(name_edit)
        dv.addLayout(name_row)
        # Lock
        lock_cb = QCheckBox("Lock")
        lock_cb.setChecked(e.locked)
        dv.addWidget(lock_cb)
        # Show
        show_cb = QCheckBox("Show")
        show_cb.setChecked(e.visibility != Visibility.INVISIBLE)
        dv.addWidget(show_cb)
        # Preview
        preview_cb = QCheckBox("Preview")
        preview_cb.setChecked(e.visibility == Visibility.PREVIEW)
        preview_cb.setEnabled(show_cb.isChecked())
        show_cb.toggled.connect(preview_cb.setEnabled)
        dv.addWidget(preview_cb)
        # OK / Cancel
        bb = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        bb.accepted.connect(dlg.accept)
        bb.rejected.connect(dlg.reject)
        dv.addWidget(bb)
        if dlg.exec_() == QDialog.Accepted:
            # Route through the YAML layer_options_confirm action so
            # jas Python shares the commit logic with the spec. The
            # dialog's state is packed as params; close_dialog is the
            # no-op terminator since the dialog already dismissed.
            from jas.panels.panel_menu import _dispatch_yaml_layers_action
            layer_id = ".".join(str(i) for i in p)
            _dispatch_yaml_layers_action(
                "layer_options_confirm", m,
                params={
                    "layer_id": layer_id,
                    "name": name_edit.text(),
                    "lock": lock_cb.isChecked(),
                    "show": show_cb.isChecked(),
                    "preview": preview_cb.isChecked(),
                },
                on_close_dialog=_rebuild,
            )

    _auto_expand_selected()
    rows = []
    _flatten(doc.layers, 0, (), "#4a90d9", rows)
    rows = _apply_type_filter(rows)
    rows = _apply_isolation_filter(rows)
    rows = _apply_search_filter(rows)
    _current_visible_rows[0] = rows
    if isolation_stack:
        _add_breadcrumb_bar(layout)

    # Subscribe to panel state changes (e.g. search query typing) so the
    # tree rebuilds when the user types in the search input.
    try:
        panel_id = store.get_active_panel_id()
        if panel_id:
            def _on_panel_change(key, value):
                if key in ("search_query", "_hidden_types"):
                    _rebuild()
            store.subscribe_panel(panel_id, _on_panel_change)
    except Exception:
        pass

    # Keyboard shortcuts
    def _on_key(event):
        key = event.key()
        meta = (event.modifiers() & (Qt.ControlModifier | Qt.MetaModifier)) != Qt.NoModifier
        if key in (Qt.Key_Delete, Qt.Key_Backspace):
            # Delete panel-selected elements (prevent last layer)
            m = get_model()
            if m is not None and panel_selection:
                doc = m.document
                paths = list(panel_selection)
                # Prevent deleting the last layer
                top_deletes = sum(1 for p in paths if len(p) == 1)
                if top_deletes < len(doc.layers):
                    m.snapshot()
                    paths.sort(reverse=True)
                    new_doc = doc
                    for p in paths:
                        new_doc = new_doc.delete_element(p)
                    m.document = new_doc
                    panel_selection.clear()
                    _rebuild()
        elif key == Qt.Key_A and meta:
            # Select all visible rows in panel selection
            panel_selection.clear()
            m = get_model()
            if m is not None:
                def collect(elements, prefix):
                    for i, e in enumerate(elements):
                        p = prefix + (i,)
                        panel_selection.add(p)
                        if isinstance(e, Group) and hasattr(e, 'children'):
                            collect(e.children, p)
                collect(m.document.layers, ())
            _rebuild()
    widget.keyPressEvent = _on_key

    def _rebuild():
        """Rebuild the tree view after a document or UI state change."""
        # Clear existing widgets
        while layout.count():
            item = layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        # Re-render
        new_model = get_model()
        if new_model is None:
            return
        new_doc = new_model.document
        nonlocal selected_paths
        selected_paths = new_doc.selected_paths()
        # Refresh search query and hidden types from panel state
        try:
            panel_state = store.get_active_panel_state()
            search_query[0] = str(panel_state.get("search_query", "") or "")
            ht = panel_state.get("_hidden_types", None)
            if ht is not None:
                hidden_types.clear()
                hidden_types.update(ht)
        except Exception:
            pass
        _auto_expand_selected()
        new_rows = []
        _flatten(new_doc.layers, 0, (), "#4a90d9", new_rows)
        new_rows = _apply_type_filter(new_rows)
        new_rows = _apply_isolation_filter(new_rows)
        new_rows = _apply_search_filter(new_rows)
        _current_visible_rows[0] = new_rows
        if isolation_stack:
            _add_breadcrumb_bar(layout)
        for r in new_rows:
            _add_row(layout, *r)
        layout.addStretch()
        _scroll_to_selected(new_rows)

    def _add_row(parent_layout, depth, path, elem, name, is_named, is_selected, is_panel_sel, is_container, is_collapsed, layer_color):
        row = QWidget()
        _row_widgets[path] = row
        row_layout = QHBoxLayout(row)
        row_layout.setContentsMargins(4, 0, 4, 0)
        row_layout.setSpacing(2)
        row.setFixedHeight(24)
        is_drop_target = drag_target[0] == path and drag_source[0] is not None and drag_source[0] != path
        style_parts = []
        if is_panel_sel:
            style_parts.append("background: rgba(58, 123, 213, 0.4);")
        if is_drop_target:
            style_parts.append("border-top: 2px solid #3a7bd5;")
        if style_parts:
            row.setStyleSheet(" ".join(style_parts))
        # Row click for panel selection + drag start
        def _on_row_press(event, p=path):
            from PySide6.QtCore import Qt as QtMod
            meta = bool(event.modifiers() & (QtMod.MetaModifier | QtMod.ControlModifier))
            shift = bool(event.modifiers() & QtMod.ShiftModifier)
            # All visible row paths (for shift-range)
            visible_paths = [r[1] for r in _current_visible_rows[0]]
            if shift and panel_selection_order:
                anchor = panel_selection_order[-1]
                try:
                    a_idx = visible_paths.index(anchor)
                    c_idx = visible_paths.index(p)
                    lo, hi = (a_idx, c_idx) if a_idx <= c_idx else (c_idx, a_idx)
                    panel_selection.clear()
                    for pp in visible_paths[lo:hi+1]:
                        panel_selection.add(pp)
                except ValueError:
                    panel_selection.clear()
                    panel_selection.add(p)
            elif meta:
                if p in panel_selection:
                    panel_selection.discard(p)
                    if p in panel_selection_order:
                        panel_selection_order.remove(p)
                else:
                    panel_selection.add(p)
                    panel_selection_order.append(p)
            else:
                panel_selection.clear()
                panel_selection.add(p)
                panel_selection_order.clear()
                panel_selection_order.append(p)
            drag_source[0] = p
            drag_target[0] = None
            _rebuild()
        row.mousePressEvent = _on_row_press
        # Track drag over this row; schedule auto-expand on hover during drag
        def _on_row_enter(event, p=path, is_cont=is_container, is_coll=is_collapsed):
            from PySide6.QtCore import QTimer
            if drag_source[0] is not None and drag_source[0] != p:
                if drag_target[0] != p:
                    drag_target[0] = p
                    _rebuild()
                # Auto-expand collapsed containers after 500ms during drag
                if is_cont and is_coll:
                    def _expand_if_still_target(pp=p):
                        if drag_source[0] is not None and drag_target[0] == pp:
                            collapsed.discard(pp)
                            _rebuild()
                    QTimer.singleShot(500, _expand_if_still_target)
        row.enterEvent = _on_row_enter

        # Right-click context menu
        def _on_row_context(event, p=path):
            from PySide6.QtWidgets import QMenu
            if p not in panel_selection:
                panel_selection.clear()
                panel_selection.add(p)
                panel_selection_order.clear()
                panel_selection_order.append(p)
                _rebuild()
            menu = QMenu(widget)
            m = get_model()
            e = m.document.get_element(p) if m else None
            is_layer_elem = isinstance(e, Layer)
            is_cont_elem = isinstance(e, Group)
            # Options for Layer...
            act_opts = menu.addAction("Options for Layer...")
            act_opts.setEnabled(is_layer_elem)
            act_opts.triggered.connect(lambda: _open_layer_options(p))
            # Duplicate
            act_dup = menu.addAction("Duplicate")
            act_dup.triggered.connect(lambda: _do_duplicate())
            # Delete Selection
            act_del = menu.addAction("Delete Selection")
            act_del.triggered.connect(lambda: _do_delete())
            menu.addSeparator()
            # Enter/Exit Isolation Mode
            if isolation_stack:
                act_iso = menu.addAction("Exit Isolation Mode")
                act_iso.triggered.connect(lambda: _exit_isolation())
            else:
                act_iso = menu.addAction("Enter Isolation Mode")
                act_iso.setEnabled(is_cont_elem)
                act_iso.triggered.connect(lambda: _enter_isolation(p))
            menu.addSeparator()
            # Flatten Artwork
            act_flat = menu.addAction("Flatten Artwork")
            act_flat.triggered.connect(lambda: _do_flatten())
            # Collect in New Layer
            act_col = menu.addAction("Collect in New Layer")
            act_col.triggered.connect(lambda: _do_collect())
            menu.exec_(event.globalPos() if hasattr(event, 'globalPos') else event.globalPosition().toPoint())
        row.contextMenuEvent = _on_row_context
        # Drop on mouseup: move src to before the target row
        def _on_row_release(event, p=path):
            src = drag_source[0]
            if src is not None and src != p:
                m = get_model()
                if m is not None:
                    d = m.document
                    # Drag constraints: no drop into self/descendant, no drop into locked parent
                    target_parent = p[:-1]
                    is_cycle = len(p) >= len(src) and p[:len(src)] == src
                    parent_locked = False
                    if target_parent:
                        parent_elem = d.get_element(target_parent)
                        if parent_elem is not None:
                            parent_locked = getattr(parent_elem, 'locked', False)
                    if is_cycle or parent_locked:
                        drag_source[0] = None
                        drag_target[0] = None
                        _rebuild()
                        return
                    moved_elem = d.get_element(src)
                    m.snapshot()
                    new_doc = d.delete_element(src)
                    # Adjust target path if src was before it at the same level
                    target = list(p)
                    if len(src) == len(target) and src[:-1] == target[:-1] and src[-1] < target[-1]:
                        target[-1] -= 1
                    # Insert before target: use insert_after at target-1 or prepend
                    if target[-1] == 0:
                        # Insert as first child: insert_after at (target-1[:-1], -1) doesn't work
                        # Instead, insert after the previous, or handle root
                        # Simpler: insert at end of parent's children via delete+reconstruct
                        # Use insert_element_after with a sentinel by inserting after target then swap
                        # For simplicity: insert after the target (becomes after) — close enough
                        new_doc = new_doc.insert_element_after(tuple(target), moved_elem)
                    else:
                        target[-1] -= 1
                        new_doc = new_doc.insert_element_after(tuple(target), moved_elem)
                    m.document = new_doc
            drag_source[0] = None
            drag_target[0] = None
            _rebuild()
        row.mouseReleaseEvent = _on_row_release

        if depth > 0:
            spacer = QLabel("")
            spacer.setFixedWidth(depth * 16)
            row_layout.addWidget(spacer)

        # Eye button
        vis = getattr(elem, 'visibility', Visibility.PREVIEW)
        eye_btn = QPushButton(_vis_icon(vis))
        eye_btn.setFixedSize(16, 16)
        eye_btn.setFlat(True)
        eye_btn.setStyleSheet("font-size: 10px; padding: 0;")
        def _on_eye_mouse(event, p=path):
            from PySide6.QtCore import Qt as QtMod
            alt = bool(event.modifiers() & QtMod.AltModifier)
            m = get_model()
            if m is None:
                return
            if alt:
                # Option-click: solo/unsolo among siblings
                d = m.document
                parent_prefix = p[:-1]
                # Gather sibling paths
                if not parent_prefix:
                    siblings = [(i,) for i in range(len(d.layers))]
                else:
                    parent = d.get_element(parent_prefix)
                    if not (isinstance(parent, Group) and hasattr(parent, 'children')):
                        return
                    siblings = [parent_prefix + (i,) for i in range(len(parent.children))]
                if solo_state[0] and solo_state[0][0] == p:
                    # Restore saved
                    saved = solo_state[0][1]
                    m.snapshot()
                    new_doc = d
                    for sp, sv in saved.items():
                        e = new_doc.get_element(sp)
                        if e is not None:
                            new_doc = new_doc.replace_element(sp, dc_replace(e, visibility=sv))
                    m.document = new_doc
                    solo_state[0] = None
                else:
                    saved = {}
                    for sp in siblings:
                        if sp != p:
                            e = d.get_element(sp)
                            if e is not None:
                                saved[sp] = e.visibility
                    m.snapshot()
                    new_doc = d
                    e0 = new_doc.get_element(p)
                    if e0 is not None and e0.visibility == Visibility.INVISIBLE:
                        new_doc = new_doc.replace_element(p, dc_replace(e0, visibility=Visibility.PREVIEW))
                    for sp in siblings:
                        if sp != p:
                            e = new_doc.get_element(sp)
                            if e is not None:
                                new_doc = new_doc.replace_element(sp, dc_replace(e, visibility=Visibility.INVISIBLE))
                    m.document = new_doc
                    solo_state[0] = (p, saved)
            else:
                solo_state[0] = None
                d = m.document
                e = d.get_element(p)
                if e is None:
                    return
                new_vis = _cycle_visibility(getattr(e, 'visibility', Visibility.PREVIEW))
                new_e = dc_replace(e, visibility=new_vis)
                m.snapshot()
                new_doc = d.replace_element(p, new_e)
                if new_vis == Visibility.INVISIBLE:
                    new_doc = dc_replace(new_doc, selection=frozenset(
                        es for es in new_doc.selection if not (es.path == p or es.path[:len(p)] == p)
                    ))
                m.document = new_doc
            _rebuild()
        eye_btn.mousePressEvent = _on_eye_mouse
        row_layout.addWidget(eye_btn)

        # Lock button
        locked = getattr(elem, 'locked', False)
        lock_btn = QPushButton("\U0001F512" if locked else "\U0001F513")
        lock_btn.setFixedSize(16, 16)
        lock_btn.setFlat(True)
        lock_btn.setStyleSheet("font-size: 10px; padding: 0;")
        def _on_lock(checked, p=path):
            m = get_model()
            if m is None: return
            d = m.document
            e = d.get_element(p)
            if e is None: return
            was_locked = getattr(e, 'locked', False)
            new_locked = not was_locked
            is_cont = isinstance(e, Group)
            m.snapshot()
            # Save/restore for containers
            if is_cont and not was_locked and hasattr(e, 'children'):
                # Save children's lock states before locking
                saved_lock_states[p] = [getattr(c, 'locked', False) for c in e.children]
            new_e = dc_replace(e, locked=new_locked)
            new_doc = d.replace_element(p, new_e)
            if is_cont and new_locked and hasattr(e, 'children'):
                # Lock all direct children
                for i, child in enumerate(e.children):
                    cp = p + (i,)
                    new_doc = new_doc.replace_element(cp, dc_replace(child, locked=True))
            if is_cont and not new_locked and p in saved_lock_states:
                # Restore saved child lock states
                saved = saved_lock_states.pop(p)
                new_e2 = new_doc.get_element(p)
                if hasattr(new_e2, 'children'):
                    for i, child in enumerate(new_e2.children):
                        if i < len(saved):
                            cp = p + (i,)
                            new_doc = new_doc.replace_element(cp, dc_replace(child, locked=saved[i]))
            if new_locked:
                new_doc = dc_replace(new_doc, selection=frozenset(
                    es for es in new_doc.selection if not (es.path == p or es.path[:len(p)] == p)
                ))
            m.document = new_doc
            _rebuild()
        lock_btn.clicked.connect(_on_lock)
        row_layout.addWidget(lock_btn)

        # Twirl or gap
        if is_container:
            twirl_btn = QPushButton("\u25b6" if is_collapsed else "\u25bc")
            twirl_btn.setFixedSize(16, 16)
            twirl_btn.setFlat(True)
            twirl_btn.setStyleSheet("font-size: 10px; padding: 0;")
            def _on_twirl(checked, p=path):
                if p in collapsed:
                    collapsed.discard(p)
                else:
                    collapsed.add(p)
                _rebuild()
            twirl_btn.clicked.connect(_on_twirl)
            row_layout.addWidget(twirl_btn)
        else:
            gap = QLabel("")
            gap.setFixedWidth(16)
            row_layout.addWidget(gap)

        # Preview thumbnail — SVG of the element fitted into 24x24
        preview = _make_element_preview(elem, 24)
        row_layout.addWidget(preview)

        # Name — inline QLineEdit when renaming, QLabel otherwise
        if renaming_path[0] == path:
            from geometry.element import Layer as LayerCls
            initial = elem.name if isinstance(elem, LayerCls) else ""
            name_edit = QLineEdit(initial)
            name_edit.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)
            def _on_commit(p=path, edit=name_edit):
                m = get_model()
                if m is not None:
                    d = m.document
                    e = d.get_element(p)
                    if isinstance(e, LayerCls):
                        new_e = dc_replace(e, name=edit.text())
                        m.snapshot()
                        m.document = d.replace_element(p, new_e)
                renaming_path[0] = None
                _rebuild()
            name_edit.returnPressed.connect(_on_commit)
            def _on_escape(event, edit=name_edit):
                if event.key() == Qt.Key_Escape:
                    renaming_path[0] = None
                    _rebuild()
                else:
                    QLineEdit.keyPressEvent(edit, event)
            name_edit.keyPressEvent = _on_escape
            name_edit.setFocus()
            row_layout.addWidget(name_edit)
        else:
            from geometry.element import Layer as LayerCls
            name_lbl = QLabel(name)
            name_lbl.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)
            if not is_named:
                name_lbl.setStyleSheet("color: #999;")
            if isinstance(elem, LayerCls):
                def _on_dbl(event, p=path):
                    renaming_path[0] = p
                    _rebuild()
                name_lbl.mouseDoubleClickEvent = _on_dbl
            row_layout.addWidget(name_lbl)

        # Select square
        sq = QFrame()
        sq.setFixedSize(12, 12)
        sq.setFrameStyle(QFrame.Box)
        if is_selected:
            sq.setStyleSheet(f"background: {layer_color};")
        def _on_select(event, p=path):
            m = get_model()
            if m is None: return
            d = m.document
            new_sel = frozenset([ElementSelection.all(p)])
            m.document = dc_replace(d, selection=new_sel)
            _rebuild()
        sq.mousePressEvent = _on_select
        row_layout.addWidget(sq)

        parent_layout.addWidget(row)

    for r in rows:
        _add_row(layout, *r)

    layout.addStretch()
    return widget


def _render_dropdown(el, store, ctx, dispatch_fn):
    """Render a dropdown widget. Currently only handles the layers panel
    type filter dropdown (id == 'lp_filter_button'); other dropdowns fall
    through to placeholder."""
    widget_id = el.get("id", "")
    if widget_id != "lp_filter_button":
        return _render_placeholder(el, store, ctx, dispatch_fn)
    from PySide6.QtWidgets import QToolButton, QMenu
    from PySide6.QtGui import QAction
    btn = QToolButton()
    btn.setText("🔽")
    btn.setPopupMode(QToolButton.InstantPopup)
    btn.setFixedSize(20, 20)
    btn.setStyleSheet("background:transparent;border:none;color:#ccc;")

    items = el.get("items", [])

    def _open_menu():
        menu = QMenu(btn)
        panel_id = store.get_active_panel_id()
        hidden = set()
        if panel_id:
            ps = store.get_panel_state(panel_id)
            hidden = set(ps.get("_hidden_types", ()) or ())
        for item in items:
            label = item.get("label", "")
            value = item.get("value", "")
            action = QAction(label, menu)
            action.setCheckable(True)
            action.setChecked(value not in hidden)
            def _toggle(checked, v=value, pid=panel_id):
                if pid is None:
                    return
                ps = store.get_panel_state(pid)
                current = set(ps.get("_hidden_types", ()) or ())
                if checked:
                    current.discard(v)
                else:
                    current.add(v)
                store.set_panel(pid, "_hidden_types", tuple(sorted(current)))
            action.toggled.connect(_toggle)
            menu.addAction(action)
        menu.exec_(btn.mapToGlobal(btn.rect().bottomLeft()))
    btn.clicked.connect(_open_menu)
    return btn


def _render_element_preview(el, store, ctx, dispatch_fn):
    """Render an element_preview widget as a placeholder thumbnail."""
    style = el.get("style", {})
    sz = style.get("size", 32)
    frame = QFrame()
    frame.setFixedSize(sz, sz)
    frame.setFrameStyle(QFrame.Box)
    frame.setStyleSheet("background: white;")
    return frame


def _render_placeholder(el, store, ctx, dispatch_fn):
    summary = el.get("summary", el.get("type", "?"))
    # Opacity panel previews (OPACITY.md §Preview interactions):
    # op_preview / op_mask_preview handle click to switch the
    # editing target and render a persistent highlight on the
    # active target. Mirrors the Rust / Swift / OCaml special-cases.
    panel_id = ctx.get("_panel_id")
    el_id = el.get("id", "")
    is_opacity_preview = (
        panel_id == "opacity_panel_content"
        and el_id in ("op_preview", "op_mask_preview")
    )
    if is_opacity_preview:
        eval_ctx = store.eval_context(ctx)
        editing_mask = evaluate("editing_target_is_mask", eval_ctx).to_bool()
        has_mask = evaluate("selection_has_mask", eval_ctx).to_bool()
        is_mask_preview = el_id == "op_mask_preview"
        # Highlight whichever preview matches the current editing
        # target: op_preview in content-mode, op_mask_preview in
        # mask-mode.
        highlight = editing_mask == is_mask_preview
        label = QLabel(f"[{summary}]")
        label.setAlignment(Qt.AlignCenter)
        label.setMinimumHeight(30)
        if highlight:
            label.setStyleSheet(
                "QLabel { border: 2px solid #4a90d9; }"
            )
        else:
            label.setStyleSheet(
                "QLabel { border: 2px solid transparent; }"
            )
        # MASK_PREVIEW click requires the selection to have a mask;
        # otherwise the click is a no-op.
        click_enabled = (not is_mask_preview) or has_mask
        get_model = ctx.get("_get_model")
        def _on_click(_evt):
            if not click_enabled:
                return
            model = get_model() if callable(get_model) else None
            if model is None:
                return
            from document.model import EditingTarget
            if is_mask_preview:
                first = next(iter(sorted(
                    (es.path for es in model.document.selection),
                    key=lambda p: p,
                )), None)
                if first is None:
                    return
                model.editing_target = EditingTarget.mask(first)
            else:
                model.editing_target = EditingTarget.content()
            # Bump the panel-state version so the panel re-renders
            # with the new highlight.
            model.panel_state_version = getattr(
                model, "panel_state_version", 0) + 1
        label.mousePressEvent = _on_click
        return label
    label = QLabel(f"[{summary}]")
    label.setAlignment(Qt.AlignCenter)
    label.setMinimumHeight(30)
    return label


# ── Repeat ───────────────────────────────────────────────────


def _render_repeat(el, store, ctx, dispatch_fn):
    """Expand a repeat directive and render each instance.

    Uses context extension: for each item, the loop variable is added
    as a top-level key in the eval context so the expression evaluator
    resolves ``var.field`` naturally. The original template is rendered
    directly without deep-copy or string substitution.
    """
    repeat = el["foreach"]
    template = el["do"]
    source_expr = repeat.get("source", "")
    var_name = repeat.get("as", "item")

    eval_ctx = store.eval_context(ctx)
    source_result = evaluate(source_expr, eval_ctx)
    items = source_result.value if isinstance(source_result.value, list) else []

    # Build a container for the repeated elements
    container = QWidget()
    layout_dir = el.get("layout", "column")
    if layout_dir == "row":
        layout = QHBoxLayout(container)
    else:
        layout = QVBoxLayout(container)
    layout.setContentsMargins(0, 0, 0, 0)
    style = el.get("style", {})
    if "gap" in style:
        layout.setSpacing(int(style["gap"]))

    from workspace_interpreter.scope import Scope
    scope = Scope(ctx)

    for i, item in enumerate(items):
        if isinstance(item, dict):
            item_data = dict(item)
            item_data["_index"] = i
        else:
            item_data = {"_value": item, "_index": i}

        # Push a child scope with the loop variable — parent unchanged
        child_scope = scope.extend(**{var_name: item_data})

        child_widget = render_element(template, store, child_scope.to_dict(), dispatch_fn)
        if child_widget:
            layout.addWidget(child_widget)

    return container


# ── Style ────────────────────────────────────────────────────


def _apply_style(widget: QWidget, style: dict, store: StateStore, ctx: dict):
    """Apply style properties to a widget via setStyleSheet."""
    if not style:
        return

    parts = []
    eval_ctx = store.eval_context(ctx)

    for key, val in style.items():
        if key in ("gap", "padding", "alignment", "justify"):
            continue  # handled by layout
        if key == "size":
            sz = int(val)
            widget.setFixedSize(sz, sz)
            continue
        if key == "width":
            if isinstance(val, str) and val.endswith("%"):
                from PySide6.QtWidgets import QSizePolicy
                widget.setSizePolicy(QSizePolicy.Expanding,
                                     widget.sizePolicy().verticalPolicy())
            else:
                widget.setFixedWidth(int(val))
            continue
        if key == "height":
            if isinstance(val, str) and val.endswith("%"):
                from PySide6.QtWidgets import QSizePolicy
                widget.setSizePolicy(widget.sizePolicy().horizontalPolicy(),
                                     QSizePolicy.Expanding)
            else:
                widget.setFixedHeight(int(val))
            continue
        if key == "min_width":
            widget.setMinimumWidth(int(val))
            continue
        if key == "min_height":
            widget.setMinimumHeight(int(val))
            continue

        resolved = str(val)
        if isinstance(val, str) and "{{" in val:
            resolved = evaluate_text(val, eval_ctx)

        css_key = key.replace("_", "-")
        if css_key == "font-size":
            parts.append(f"font-size: {resolved}px")
        elif css_key == "border-radius":
            parts.append(f"border-radius: {resolved}px")
        else:
            parts.append(f"{css_key}: {resolved}")

    if parts:
        existing = widget.styleSheet()
        new_style = "; ".join(parts)
        widget.setStyleSheet(f"{existing}; {new_style}" if existing else new_style)


def _parse_padding(val) -> tuple[int, int, int, int]:
    """Parse padding value to (left, top, right, bottom)."""
    if isinstance(val, (int, float)):
        p = int(val)
        return (p, p, p, p)
    if isinstance(val, str):
        nums = val.split()
        if len(nums) == 1:
            p = int(nums[0])
            return (p, p, p, p)
        if len(nums) == 2:
            v, h = int(nums[0]), int(nums[1])
            return (h, v, h, v)
        if len(nums) == 4:
            return (int(nums[3]), int(nums[0]), int(nums[1]), int(nums[2]))
    return (0, 0, 0, 0)


# ── Bindings ─────────────────────────────────────────────────


def _apply_bindings(widget: QWidget, bindings: dict, store: StateStore, ctx: dict):
    """Apply reactive bindings to a widget.

    Sets initial values and subscribes to state changes.
    """
    if not bindings:
        return

    eval_ctx = store.eval_context(ctx)

    for prop, expr in bindings.items():
        if not isinstance(expr, str):
            continue

        result = evaluate(expr, eval_ctx)

        if prop == "visible":
            widget.setVisible(result.to_bool())
        elif prop == "disabled":
            widget.setEnabled(not result.to_bool())
        elif prop == "value":
            _set_widget_value(widget, result.value)
        elif prop == "color":
            color = result.value
            if color and isinstance(color, str) and color.startswith("#"):
                widget.setStyleSheet(
                    widget.styleSheet() + f"; background: {color}; border: 1px solid #666")
            else:
                widget.setStyleSheet(
                    widget.styleSheet() + "; background: transparent; border: 1px dashed #555")
        elif prop == "checked":
            if hasattr(widget, "setChecked"):
                widget.setChecked(result.to_bool())

    # Subscribe to state changes for reactive updates
    def _update_bindings(key, value):
        new_ctx = store.eval_context(ctx)
        for prop, expr in bindings.items():
            if not isinstance(expr, str):
                continue
            r = evaluate(expr, new_ctx)
            if prop == "visible":
                widget.setVisible(r.to_bool())
            elif prop == "disabled":
                widget.setEnabled(not r.to_bool())
            elif prop == "value":
                _set_widget_value(widget, r.value)
            elif prop == "color":
                c = r.value
                if c and isinstance(c, str) and c.startswith("#"):
                    widget.setStyleSheet(f"background: {c}; border: 1px solid #666")
                else:
                    widget.setStyleSheet("background: transparent; border: 1px dashed #555")

    store.subscribe(None, _update_bindings)


def _set_widget_value(widget: QWidget, value):
    """Set the value of a widget based on its type."""
    if isinstance(widget, QSlider):
        try:
            widget.setValue(int(float(value)) if value is not None else 0)
        except (TypeError, ValueError):
            pass
    elif isinstance(widget, QSpinBox):
        try:
            widget.setValue(int(float(value)) if value is not None else 0)
        except (TypeError, ValueError):
            pass
    elif isinstance(widget, QLineEdit):
        widget.setText(str(value) if value is not None else "")
    elif isinstance(widget, QLabel):
        widget.setText(str(value) if value is not None else "")


# ── Behaviors ────────────────────────────────────────────────


def _apply_behaviors(widget: QWidget, behaviors: list, store: StateStore,
                     ctx: dict, dispatch_fn):
    """Wire event behaviors to Qt signals."""
    if not behaviors or not dispatch_fn:
        return

    for b in behaviors:
        if not isinstance(b, dict):
            continue
        event = b.get("event", "click")
        action = b.get("action")
        params = b.get("params", {})
        condition = b.get("condition")
        effects = b.get("effects", [])

        if event == "click":
            _wire_click(widget, action, params, condition, effects, store, ctx, dispatch_fn)
        elif event == "change":
            _wire_change(widget, action, params, condition, effects, store, ctx, dispatch_fn)


def _wire_click(widget, action, params, condition, effects, store, ctx, dispatch_fn):
    if not hasattr(widget, "clicked"):
        return

    def on_click():
        if condition:
            eval_ctx = store.eval_context(ctx)
            cond_result = evaluate(condition, eval_ctx)
            if not cond_result.to_bool():
                return
        if action:
            resolved_params = {}
            eval_ctx = store.eval_context(ctx)
            for k, v in params.items():
                r = evaluate(str(v), eval_ctx)
                resolved_params[k] = r.value
            dispatch_fn(action, resolved_params)
        if effects:
            from workspace_interpreter.effects import run_effects
            run_effects(effects, ctx, store)

    widget.clicked.connect(lambda _=None: on_click())


def _wire_change(widget, action, params, condition, effects, store, ctx, dispatch_fn):
    """Wire value change events (sliders, inputs)."""
    def on_change(value):
        if effects:
            from workspace_interpreter.effects import run_effects
            change_ctx = dict(ctx)
            change_ctx["event"] = {"value": value}
            run_effects(effects, change_ctx, store)
        if action:
            resolved_params = dict(params)
            resolved_params["value"] = value
            dispatch_fn(action, resolved_params)

    if isinstance(widget, QSlider):
        widget.valueChanged.connect(on_change)
    elif isinstance(widget, QSpinBox):
        widget.valueChanged.connect(on_change)
    elif isinstance(widget, QLineEdit):
        widget.textChanged.connect(on_change)


# ── Type dispatch table ──────────────────────────────────────

_RENDERERS = {
    "container": _render_container,
    "row": lambda el, s, c, d: _render_container({**el, "layout": "row"}, s, c, d),
    "col": lambda el, s, c, d: _render_container({**el, "layout": "column"}, s, c, d),
    "grid": _render_grid,
    "text": _render_text,
    "button": _render_button,
    "icon_button": _render_icon_button,
    "slider": _render_slider,
    "number_input": _render_number_input,
    "text_input": _render_text_input,
    "toggle": _render_toggle,
    "checkbox": _render_checkbox,
    "select": _render_select,
    "combo_box": _render_combo_box,
    "color_swatch": _render_color_swatch,
    "separator": _render_separator,
    "spacer": _render_spacer,
    "disclosure": _render_disclosure,
    "panel": _render_panel,
    "fill_stroke_widget": _render_container,
    "tree_view": _render_tree_view,
    "element_preview": _render_element_preview,
    "dropdown": _render_dropdown,
    "placeholder": _render_placeholder,
}
