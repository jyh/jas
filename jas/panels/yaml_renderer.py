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
    label = el.get("label", "")
    btn = QPushButton(label)
    return btn


def _render_icon_button(el, store, ctx, dispatch_fn):
    summary = el.get("summary", "")
    btn = QPushButton(summary)
    btn.setFlat(True)
    return btn


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
    return cb


def _render_checkbox(el, store, ctx, dispatch_fn):
    label = el.get("label", "")
    cb = QCheckBox(label)
    return cb


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

    # Track collapsed paths as a widget attribute (persists across rebuilds
    # as long as the widget instance lives).
    collapsed = set()

    def _flatten(elements, depth, path_prefix, layer_color, rows):
        for i in reversed(range(len(elements))):
            elem = elements[i]
            path = path_prefix + (i,)
            is_container = isinstance(elem, Group)
            is_selected = path in selected_paths
            is_collapsed = path in collapsed
            cur_color = _LAYER_COLORS[i % len(_LAYER_COLORS)] if isinstance(elem, Layer) and len(path) == 1 else layer_color
            name, is_named = _element_display_name(elem)
            rows.append((depth, path, elem, name, is_named, is_selected, is_container, is_collapsed, cur_color))
            if is_container and not is_collapsed and hasattr(elem, 'children'):
                _flatten(elem.children, depth + 1, path, cur_color, rows)

    rows = []
    _flatten(doc.layers, 0, (), "#4a90d9", rows)

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
        new_rows = []
        _flatten(new_doc.layers, 0, (), "#4a90d9", new_rows)
        for r in new_rows:
            _add_row(layout, *r)
        layout.addStretch()

    def _add_row(parent_layout, depth, path, elem, name, is_named, is_selected, is_container, is_collapsed, layer_color):
        row = QWidget()
        row_layout = QHBoxLayout(row)
        row_layout.setContentsMargins(4, 0, 4, 0)
        row_layout.setSpacing(2)
        row.setFixedHeight(24)

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
        def _on_eye(checked, p=path):
            m = get_model()
            if m is None: return
            d = m.document
            e = d.get_element(p)
            if e is None: return
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
        eye_btn.clicked.connect(_on_eye)
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
            new_locked = not getattr(e, 'locked', False)
            new_e = dc_replace(e, locked=new_locked)
            m.snapshot()
            new_doc = d.replace_element(p, new_e)
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

        # Preview
        preview = QFrame()
        preview.setFixedSize(24, 24)
        preview.setFrameStyle(QFrame.Box)
        preview.setStyleSheet("background: white;")
        row_layout.addWidget(preview)

        # Name
        name_lbl = QLabel(name)
        name_lbl.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)
        if not is_named:
            name_lbl.setStyleSheet("color: #999;")
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
            widget.setFixedWidth(int(val))
            continue
        if key == "height":
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
    "placeholder": _render_placeholder,
}
