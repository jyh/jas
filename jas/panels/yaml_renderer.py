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
from PySide6.QtGui import QColor

from workspace_interpreter.expr import evaluate, evaluate_text
from workspace_interpreter.state_store import StateStore
from panels import widget_registry


# Scoped default icon size for size-less ``icon_button`` glyphs rendered
# inside the NON-MODAL tool-alternate flyout (modal: false). The flyout
# items declare no ``style.size``, so without this they would fall back to
# the 20px panel default. YamlDialogView sets this to 28 around its render
# and restores it to None afterward (mirrors OCaml's
# ``Yaml_panel_view.nonmodal_icon_size``), so panels — which are also
# size-less ``icon_button``s — keep their own 20px default unchanged.
NONMODAL_ICON_SIZE: int | None = None


def set_nonmodal_icon_size(size: int | None) -> None:
    """Set (or clear) the flyout-scoped default icon size used by
    ``_render_icon_button`` for size-less, non-toolbar glyphs.

    The non-modal flyout view brackets its content render with
    ``set_nonmodal_icon_size(28)`` ... ``set_nonmodal_icon_size(None)`` so
    only the flyout's icons grow to 28px while panel icons stay at 20px."""
    global NONMODAL_ICON_SIZE
    NONMODAL_ICON_SIZE = size


def _confirm_panel_delete_if_orphans(model, panel_selection_paths, parent=None) -> bool:
    """Decide whether a Layers-panel delete should proceed (REFERENCE_GRAPH.md
    warn-then-orphan), mirroring ``menu._confirm_delete_if_orphans`` but on the
    PANEL selection rather than ``doc.selection``.

    Deleting elements from the Layers panel can orphan live references
    (instances) exactly like the main Edit>Delete, but the panel delete used to
    bypass the confirm. This computes the SAME pinned predicate
    ``orphaned_references(doc, deletion_paths)`` over the panel-selected paths.
    Empty -> proceed silently (unchanged behavior, no dialog). Non-empty -> show
    the modal confirm whose default is the safe Cancel; returns True only if the
    user confirms (Ok).

    Shared by the panel context-menu "Delete Selection" item and the in-panel
    keyboard Delete/Backspace path so both warn identically. Verb is "Deleting",
    reusing the existing delete wording via ``menu._orphan_warning_body``."""
    from PySide6.QtWidgets import QApplication, QMessageBox
    from document.dependency_index import orphaned_references
    from menu.menu import _orphan_warning_body
    doc = model.document
    deletion_paths = [list(p) for p in panel_selection_paths]
    orphaned = orphaned_references(doc, deletion_paths)
    if not orphaned:
        return True
    if parent is None:
        parent = QApplication.activeWindow()
    body = _orphan_warning_body(len(orphaned), "Deleting")
    reply = QMessageBox.question(
        parent, "Delete", body,
        QMessageBox.Cancel | QMessageBox.Ok, QMessageBox.Cancel)
    return reply == QMessageBox.Ok


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

    # Templates leave a ``_template:`` marker on the expanded element
    # so the renderer can recognise the template by name. The
    # fill_stroke_widget template expands to a generic container of
    # swatches/buttons positioned via style.position.{x,y}, which the
    # default container renderer ignores — the swatches stack
    # vertically and end up hidden behind the chrome. Detect the
    # marker here and substitute the toolbar's purpose-built
    # FillStrokeWidget so the panel matches the toolbar pixel-for-
    # pixel (CLR-002 Python).
    if el.get("_template") == "fill_stroke_widget":
        return _render_fill_stroke_widget(el, store, ctx, dispatch_fn)

    # Check native widget registry first
    native = widget_registry.create(etype, el, store, ctx)
    if native is not None:
        _apply_style(native, el.get("style", {}), store, ctx)
        _apply_bindings(native, el, store, ctx)
        _apply_behaviors(native, el.get("behavior", []), store, ctx, dispatch_fn)
        return native

    # Built-in type dispatch
    renderer = _RENDERERS.get(etype, _render_placeholder)
    widget = renderer(el, store, ctx, dispatch_fn)

    if widget is None:
        return None

    _apply_style(widget, el.get("style", {}), store, ctx)
    _apply_bindings(widget, el, store, ctx)
    _apply_behaviors(widget, el.get("behavior", []), store, ctx, dispatch_fn)

    return widget


# ── Renderers ────────────────────────────────────────────────


def _render_container(el, store, ctx, dispatch_fn):
    widget = QWidget()
    layout_dir = el.get("layout", "column")
    is_row = layout_dir == "row"
    if is_row:
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

    # Bootstrap-style: when row children declare ``col: N``, give
    # each its proportional weight so labels stack at the same x
    # across rows. Without this Qt's QHBoxLayout distributes by
    # natural size and the long-content cell (e.g. a select) absorbs
    # the leftover space, pushing the input to the right edge while
    # the label sits at the left.
    children = el.get("children", []) or []
    weights = [int(c.get("col", 0) or 0) for c in children] if is_row else []
    any_weighted = any(w > 0 for w in weights)
    for i, child in enumerate(children):
        # ``type: spacer`` becomes a layout stretch rather than a
        # QWidget — the widget version renders with default chrome
        # that shows as a thin horizontal hairline in the Print
        # dialog footer between the disabled / enabled button
        # clusters. addStretch is invisible.
        if isinstance(child, dict) and child.get("type") == "spacer":
            layout.addStretch(1)
            continue
        child_widget = render_element(child, store, ctx, dispatch_fn)
        if child_widget is None:
            continue
        if is_row and any_weighted:
            weight = weights[i] if i < len(weights) else 0
            if weight > 0:
                # Wrap so the inner widget left-aligns within the
                # weighted slot rather than stretching to fill it.
                cell = QWidget()
                cell_lay = QHBoxLayout(cell)
                cell_lay.setContentsMargins(0, 0, 0, 0)
                cell_lay.setSpacing(0)
                cell_lay.addWidget(child_widget)
                cell_lay.addStretch(1)
                layout.addWidget(cell, weight)
            else:
                layout.addWidget(child_widget)
        else:
            layout.addWidget(child_widget)

    # Propagate child minimum heights up to this container's
    # minimumHeight without touching width. Qt's layouts compute
    # minimumSize from children but only update the widget's
    # minimumSize automatically if SetMinimumSize is enabled —
    # which also forces minimumWidth, blocking the scroll-area
    # viewport from shrinking the content to fit (CLR-002 Python).
    # Setting height-only avoids that.
    _set_min_height_from_children(widget, layout, is_row)
    return widget


def _set_min_height_from_children(widget, layout, is_row: bool):
    """Set widget.minimumHeight from children's minimumHeights.

    Row (QHBoxLayout): max of children's mins (height = tallest).
    Column (QVBoxLayout): sum of children's mins + spacing + margins.

    Skips children that are explicitly hidden via setVisible(False)
    — e.g. the Color panel's cp_sliders_grayscale / cp_sliders_rgb
    / cp_sliders_cmyk / cp_sliders_web_safe siblings under
    cp_sliders_col, only one of which is visible at a time. Without
    this skip the column's min would be 5× the active mode's
    height and the visible slider rows would stretch to fill the
    inflated column.
    """
    margins = layout.contentsMargins()
    margin_h = margins.top() + margins.bottom()
    spacing = layout.spacing() if layout.spacing() > 0 else 0
    child_mins = []
    for i in range(layout.count()):
        item = layout.itemAt(i)
        if item is None:
            continue
        w = item.widget()
        if w is None:
            continue
        # isVisibleTo(parent) returns False only when setVisible(False)
        # was explicitly called on the child (e.g. bind.visible
        # binding evaluated false). isHidden() / isVisible() would
        # falsely report ALL freshly-created widgets as hidden
        # since the dock hasn't been shown yet.
        if not w.isVisibleTo(widget):
            continue
        child_mins.append(w.minimumSize().height())
    if not child_mins:
        return
    if is_row:
        total = max(child_mins)
    else:
        total = sum(child_mins) + spacing * max(0, len(child_mins) - 1)
    total += margin_h
    if total > widget.minimumHeight():
        widget.setMinimumHeight(total)


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
    # Match the panel body's dark theme (THEME_TEXT in dock_panel.py).
    # Without this label text inherits the system Qt palette and
    # renders as black, which is illegible on the dark dock.
    label.setStyleSheet("color: #ccc;")
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
    # Style with the active theme's text color so dialog buttons
    # (OK / Cancel / Color Swatches) render readable text on Dark
    # Gray — without this Qt's default uses near-black system text
    # which disappears on dark backgrounds (CLR-200/231 Python).
    try:
        from workspace.dock_panel import THEME_TEXT
        btn.setStyleSheet(f"QPushButton {{ color: {THEME_TEXT}; }}")
    except Exception:
        pass
    # style.opacity < 1 — render dimmed AND insensitive. Used by
    # the color picker's "Color Swatches" button as a YAML
    # placeholder (CLR-231 Python).
    try:
        st = el.get("style", {}) if isinstance(el.get("style"), dict) else {}
        op = st.get("opacity")
        if isinstance(op, (int, float)) and op < 1.0:
            from PySide6.QtWidgets import QGraphicsOpacityEffect
            effect = QGraphicsOpacityEffect(btn)
            effect.setOpacity(float(op))
            btn.setGraphicsEffect(effect)
            btn.setEnabled(False)
    except Exception:
        pass
    # Don't claim Enter as the dialog's default — that would let
    # Enter inside a number_input dismiss the picker as if the
    # user clicked OK, before the value-box's editingFinished
    # commits the typed value to dialog state (CLR-214 Python).
    btn.setAutoDefault(False)
    btn.setDefault(False)
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
    # Generic ``action: <name>`` dispatch. Used by dialog OK/Done/
    # Print buttons whose YAML carries a direct ``action`` (not a
    # ``behavior`` block). Resolves ``params`` against the live
    # ctx so dialog.X expressions reflect typed-in values, then
    # forwards to the caller-supplied dispatch_fn.
    action_name = el.get("action")
    if isinstance(action_name, str) and action_name and dispatch_fn:
        raw_params = el.get("params", {})
        if not isinstance(raw_params, dict):
            raw_params = {}
        def _dispatch_click():
            # Strip baked-in scope keys from the captured ctx before
            # passing as ``extra`` — eval_context's update() lets
            # extra shadow the live store, which would re-substitute
            # the stale dialog snapshot taken at dialog-open time and
            # mask any typed-in writebacks.
            extra = {k: v for k, v in ctx.items()
                     if k not in ("state", "panel", "dialog", "param", "tool")}
            eval_ctx = store.eval_context(extra)
            resolved = {}
            for k, v in raw_params.items():
                if isinstance(v, str):
                    r = evaluate(v, eval_ctx)
                    resolved[k] = r.value
                else:
                    resolved[k] = v
            dispatch_fn(action_name, resolved)
        btn.clicked.connect(_dispatch_click)
    return btn


def _resolve_icon_name(el, eval_ctx):
    """Resolve an icon_button's glyph NAME. Resolution order mirrors
    Rust ``render_icon_button`` (renderer.rs) and Swift
    ``resolvedIconName`` exactly:

      1. ``bind.icon`` — a yaml expression returning a string (e.g.
         the Opacity panel link indicator flipping chain glyphs).
      2. ``alternates.items`` lookup by ``state.active_tool`` — for the
         multi-tool toolbar slots (pen / pencil / shape / arrow / text /
         hand groups). When the element carries
         ``alternates: { items: [{id, icon, ...}, ...] }``, evaluate
         ``state.active_tool`` and return the icon of the item whose
         ``id`` matches the active tool; fall back to the static icon
         when none matches. Without this the slot stays stuck on the
         default glyph after picking a different alternate from the
         long-press flyout (or pressing its keyboard shortcut).
      3. The static ``icon`` field on the element.

    Returns the glyph name string, or ``None`` when no icon resolves.
    ``eval_ctx`` is the same eval context the slot's ``bind.checked``
    expression uses, so the glyph and highlight always agree.
    """
    bind = el.get("bind", {}) if isinstance(el.get("bind"), dict) else {}
    static_icon = el.get("icon") if isinstance(el.get("icon"), str) else None
    static_icon = static_icon or None

    icon_expr = bind.get("icon") if isinstance(bind.get("icon"), str) else None
    if icon_expr:
        # ``evaluate`` returns a Value wrapper; extract .value before
        # checking the type. Without this the chain-link expression
        # always resolves to a non-str instance and falls through.
        result = evaluate(icon_expr, eval_ctx)
        result_value = getattr(result, "value", result)
        if isinstance(result_value, str):
            return result_value
        return static_icon

    alternates = el.get("alternates")
    if isinstance(alternates, dict):
        items = alternates.get("items")
        if isinstance(items, list):
            active_result = evaluate("state.active_tool", eval_ctx)
            active = getattr(active_result, "value", active_result)
            if isinstance(active, str):
                for item in items:
                    if not isinstance(item, dict):
                        continue
                    item_id = item.get("id")
                    item_icon = item.get("icon")
                    if (isinstance(item_id, str) and isinstance(item_icon, str)
                            and item_id == active):
                        return item_icon
            return static_icon

    return static_icon


def _render_icon_button(el, store, ctx, dispatch_fn):
    summary = el.get("summary", "")
    btn = QPushButton()
    btn.setFlat(True)
    # bind.icon evaluates to the glyph name (e.g. flips between
    # ``chain_linked`` / ``chain_broken`` as ``dialog.bleed_uniform``
    # toggles); ``icon`` is a static fallback. Try to render the
    # SVG glyph from workspace icons.yaml; fall back to summary text
    # when rendering fails or the icon can't be resolved.
    bind = el.get("bind", {}) if isinstance(el.get("bind"), dict) else {}
    # Resolve the glyph name through the shared resolver: bind.icon ->
    # alternates-by-active_tool -> static icon (mirrors Rust/Swift). The
    # alternates step makes a multi-tool toolbar slot display the GLYPH
    # of the currently-active alternate.
    icon_name = _resolve_icon_name(el, store.eval_context(ctx))
    style = el.get("style", {}) if isinstance(el.get("style"), dict) else {}
    raw_size = style.get("size")
    # The bundle's toolbar tool buttons carry size:
    # "{{theme.sizes.tool_button}}" (=32), which the panel renderer's
    # eval context doesn't resolve (no theme thread), so the templated
    # string falls through to the default. Toolbar buttons are
    # recognised by their checked binding below; size their button +
    # glyph to match the native toolbar (BUTTON_SIZE 32 / ICON 32), so
    # the glyph fills the slot exactly as OCaml renders the toolbar
    # pixbuf at the literal style.size (32px).
    checked_expr = bind.get("checked") if isinstance(bind.get("checked"), str) else None
    is_tool_button = isinstance(checked_expr, str) and bool(checked_expr)
    if isinstance(raw_size, (int, float)):
        icon_size = int(raw_size)
    elif is_tool_button:
        # Toolbar tool slot: render the glyph at the full 32px button
        # size (the unresolved "{{theme.sizes.tool_button}}" == 32).
        icon_size = 32
    elif NONMODAL_ICON_SIZE is not None:
        # Inside the non-modal tool-alternate flyout: the size-less
        # flyout items pick up the flyout-scoped 28px default (mirrors
        # OCaml's nonmodal_icon_size). Panels never set this, so their
        # size-less icons stay at the 20px default below.
        icon_size = NONMODAL_ICON_SIZE
    else:
        icon_size = 20
    pixmap = _workspace_icon_pixmap(icon_name, icon_size) if icon_name else None
    if pixmap is not None:
        from PySide6.QtGui import QIcon
        from PySide6.QtCore import QSize
        btn.setIcon(QIcon(pixmap))
        btn.setIconSize(QSize(icon_size, icon_size))
        btn.setToolTip(summary)
    else:
        btn.setText(summary)

    # Stash a re-resolution closure so the glyph follows the live tool.
    # When ``state.active_tool`` changes, _apply_bindings' subscription
    # fires (it already re-evaluates this slot's bind.checked highlight);
    # there it calls this closure to re-resolve the glyph through
    # _resolve_icon_name (bind.icon -> alternates-by-active_tool ->
    # static) and re-apply the QIcon, so a multi-tool slot shows the
    # GLYPH of the currently-active alternate. Only meaningful for slots
    # whose icon can change at runtime (alternates / bind.icon); for a
    # purely static icon it harmlessly re-applies the same glyph.
    def _refresh_icon(eval_ctx, _btn=btn, _size=icon_size, _summary=summary):
        from PySide6.QtGui import QIcon
        from PySide6.QtCore import QSize
        name = _resolve_icon_name(el, eval_ctx)
        pm = _workspace_icon_pixmap(name, _size) if name else None
        if pm is not None:
            _btn.setIcon(QIcon(pm))
            _btn.setIconSize(QSize(_size, _size))

    btn._jas_refresh_icon = _refresh_icon

    # bind.checked turns an icon_button into a checkable toggle — used
    # by the bundle toolbar's tool grid so the active tool's button
    # shows a highlighted background (mirrors the native toolbar's
    # _checked_bg fill and the Rust/Swift bundle-toolbar ports). The
    # actual checked state + reactive re-evaluation flow through
    # _apply_bindings (the global store subscription), so here we only
    # make the button checkable and give it a checked-state stylesheet.
    # The initial checked value is set eagerly so the highlight is
    # correct on first paint, before any state change fires.
    if is_tool_button:
        btn.setCheckable(True)
        btn.setFixedSize(32, 32)
        try:
            from workspace.dock_panel import THEME_BG_TAB, THEME_BORDER
            checked_bg = THEME_BG_TAB
            border = THEME_BORDER
        except Exception:
            checked_bg = "#4a4a4a"
            border = "#555"
        btn.setStyleSheet(
            "QPushButton { background: transparent; border: none; "
            "border-radius: 3px; }"
            f"QPushButton:hover {{ background: {checked_bg}; }}"
            f"QPushButton:checked {{ background: {checked_bg}; "
            f"border: 1px solid {border}; }}"
        )
        try:
            init = evaluate(checked_expr, store.eval_context(ctx))
            btn.setChecked(init.to_bool())
        except Exception:
            pass

        # A bare checkable QPushButton toggles its own checked state on
        # every click, so clicking the already-active tool would toggle
        # it OFF — and the select_tool dispatch is a no-op (same value),
        # so the _apply_bindings subscriber never fires to re-check it.
        # Reconcile the checked state from the binding AFTER the click's
        # dispatch has run (deferred to the next event-loop tick), so the
        # active tool's button always reflects state.active_tool.
        from PySide6.QtCore import QTimer

        def _reconcile_checked():
            try:
                from shiboken6 import isValid
                if not isValid(btn):
                    return
            except Exception:
                pass
            r = evaluate(checked_expr, store.eval_context(ctx))
            btn.setChecked(r.to_bool())

        btn.clicked.connect(
            lambda _=None: QTimer.singleShot(0, _reconcile_checked))

        # Double-click a TOOLBAR tool button -> open the ACTIVE tool's
        # options. This is scoped to is_tool_button slots only (they alone
        # carry bind.checked over state.active_tool); panels and other
        # icon_buttons never reach here, so they get no dblclick. The host
        # supplies ctx["_open_tool_options"]; we read the *active* tool
        # from the store (NOT this button's own tool) so dblclicking any
        # tool slot opens whatever tool is currently selected — exactly as
        # the old native ToolButton dblclick did. The bundle-driven lookup
        # + 3-way dispatch (panel / action / dialog) lives in the host
        # callback. With no host callback (e.g. unit tests of the grid in
        # isolation) the dblclick is a silent no-op.
        open_tool_options = ctx.get("_open_tool_options") if isinstance(ctx, dict) else None
        if callable(open_tool_options):
            def _on_tool_dblclick(event, _store=store, _cb=open_tool_options):
                active = _store.get("active_tool")
                if isinstance(active, str) and active:
                    _cb(active)
            btn.mouseDoubleClickEvent = _on_tool_dblclick

    _wire_opacity_link_indicator_click(btn, el, ctx)
    return btn


def _render_icon_select(el, store, ctx, dispatch_fn):
    """Compact icon-style chooser used for the Paragraph panel's
    Bullets / Numbered List rows. Renders as a square button showing
    the workspace [icon] glyph (e.g. ``para_bullets``); clicking opens
    a popup menu listing each option's per-option [glyph] + [label].
    Writes the chosen [value] back through [_write_back_bind] /
    [store.set_panel]. Mirrors the OCaml / Rust port behaviour."""
    from PySide6.QtWidgets import QPushButton, QMenu
    from PySide6.QtCore import QSize
    from PySide6.QtGui import QIcon
    style = el.get("style", {}) if isinstance(el.get("style"), dict) else {}
    raw_w = style.get("width") or 48
    raw_h = style.get("height") or 26
    w = int(raw_w) if isinstance(raw_w, (int, float)) else 48
    h = int(raw_h) if isinstance(raw_h, (int, float)) else 26
    icon_name = el.get("icon") if isinstance(el.get("icon"), str) else None
    options = el.get("options", []) if isinstance(el.get("options"), list) else []
    bind = el.get("bind", {}) if isinstance(el.get("bind"), dict) else {}
    value_expr = bind.get("value") if isinstance(bind.get("value"), str) else None

    btn = QPushButton()
    btn.setFixedSize(w, h)
    pixmap = _workspace_icon_pixmap(icon_name, max(min(w, h) - 6, 12)) if icon_name else None
    if pixmap is not None:
        btn.setIcon(QIcon(pixmap))
        btn.setIconSize(QSize(pixmap.width(), pixmap.height()))
    btn.setStyleSheet(
        "QPushButton { background: #3a3a3a; border: 1px solid #555; "
        "border-radius: 3px; padding: 2px; }"
        "QPushButton:hover { background: #4a4a4a; }"
    )
    summary = el.get("summary")
    if isinstance(summary, str) and summary:
        btn.setToolTip(summary)

    menu = QMenu(btn)
    for opt in options:
        if not isinstance(opt, dict):
            continue
        glyph = str(opt.get("glyph", ""))
        label = str(opt.get("label", ""))
        value = str(opt.get("value", ""))
        action = menu.addAction(f"{glyph}   {label}")

        def _make_handler(v=value):
            def _on():
                if value_expr and value_expr.startswith("panel."):
                    field = value_expr[len("panel."):]
                    panel_id = ctx.get("_panel_id")
                    if not panel_id:
                        return
                    # Paragraph panel writes go through the full
                    # set_paragraph_panel_field pipeline so mutual
                    # exclusion (bullets ↔ numbered_list) and the
                    # post-write apply_paragraph_panel_to_selection
                    # both fire — without this, picking a numbered
                    # style leaves the bullets dropdown set, and the
                    # wrapper jas_list_style stays at the bullet
                    # value.
                    if panel_id == "paragraph_panel_content":
                        from panels.paragraph_panel_state import (
                            set_paragraph_panel_field,
                        )
                        get_model = ctx.get("_get_model")
                        model = get_model() if callable(get_model) else None
                        if model is not None:
                            set_paragraph_panel_field(store, model, field, v)
                            return
                    store.set_panel(panel_id, field, v)
            return _on

        action.triggered.connect(_make_handler())

    btn.clicked.connect(lambda: menu.exec(btn.mapToGlobal(btn.rect().bottomLeft())))
    return btn


def _render_icon(el, store, ctx, dispatch_fn):
    """Plain (non-button) icon glyph from workspace icons.yaml.

    Used by the Paragraph panel rows for the indent / space leading
    glyphs (left-indent, right-indent, etc.). The OCaml / Rust /
    Swift ports already render these; the Python registry was
    missing the dispatch entry so each ``- type: icon`` element fell
    through to the placeholder and the row appeared mostly empty.
    """
    from PySide6.QtWidgets import QLabel
    name = el.get("name") if isinstance(el.get("name"), str) else None
    style = el.get("style", {}) if isinstance(el.get("style"), dict) else {}
    raw = style.get("width") or style.get("height") or style.get("size") or 20
    icon_size = int(raw) if isinstance(raw, (int, float)) else 20
    label = QLabel()
    label.setFixedSize(icon_size, icon_size)
    pixmap = _workspace_icon_pixmap(name, icon_size) if name else None
    if pixmap is not None:
        label.setPixmap(pixmap)
    return label


_ICONS_CACHE: dict | None = None
_PIXMAP_CACHE: dict[tuple[str, int], object] = {}


def _icons_dict() -> dict:
    """Cached lookup of the [icons] dict from workspace.yaml. The
    workspace loader walks ~120 YAML files and takes ~600 ms per call,
    so the previous one-load-per-icon-render path slowed startup to a
    crawl once panels with many icon glyphs mounted."""
    global _ICONS_CACHE
    if _ICONS_CACHE is not None:
        return _ICONS_CACHE
    import os as _os
    try:
        from workspace_interpreter.loader import load_workspace
        ws_path = _os.path.join(_os.path.dirname(__file__), "..", "..", "workspace")
        ws = load_workspace(ws_path)
    except Exception:
        _ICONS_CACHE = {}
        return _ICONS_CACHE
    _ICONS_CACHE = ws.get("icons", {}) if ws else {}
    return _ICONS_CACHE


def _workspace_icon_pixmap(name: str, size: int):
    """Render a named workspace icon (from icons.yaml) into a QPixmap.

    Substitutes ``currentColor`` with a hardcoded text-color hex
    (matches Dark Gray theme.text — threading the active theme is a
    follow-up). Uses QSvgRenderer to rasterize the SVG; returns None
    when the icon can't be loaded so the caller can fall back to a
    text label.
    """
    cached = _PIXMAP_CACHE.get((name, size))
    if cached is not None:
        return cached
    from PySide6.QtCore import QByteArray
    from PySide6.QtGui import QPainter, QPixmap
    from PySide6.QtSvg import QSvgRenderer
    icons = _icons_dict()
    icon_def = icons.get(name)
    if not isinstance(icon_def, dict):
        return None
    viewbox = icon_def.get("viewbox", "0 0 16 16")
    svg_inner = icon_def.get("svg", "")
    if not svg_inner:
        return None
    tinted = svg_inner.replace("currentColor", "#cccccc")
    svg_doc = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{viewbox}" '
        f'width="{size}" height="{size}">{tinted}</svg>'
    )
    renderer = QSvgRenderer(QByteArray(svg_doc.encode("utf-8")))
    if not renderer.isValid():
        return None
    pixmap = QPixmap(size, size)
    pixmap.fill(Qt.GlobalColor.transparent)
    painter = QPainter(pixmap)
    renderer.render(painter)
    painter.end()
    _PIXMAP_CACHE[(name, size)] = pixmap
    return pixmap


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
    # min / max / step may arrive as expression strings (template
    # substitution leaves them as the literal "${max}" when used
    # via slider_row template params); coerce to int with a safe
    # fallback.
    def _i(v, default):
        if isinstance(v, (int, float)):
            return int(v)
        if isinstance(v, str):
            try:
                return int(float(v))
            except ValueError:
                return default
        return default
    slider.setMinimum(_i(el.get("min", 0), 0))
    slider.setMaximum(_i(el.get("max", 100), 100))
    step = _i(el.get("step", 1), 1)
    slider.setSingleStep(step)
    if step > 1:
        slider.setPageStep(step)

    raw_bind = el.get("bind")
    if isinstance(raw_bind, dict):
        value_expr = raw_bind.get("value") if isinstance(raw_bind.get("value"), str) else None
    elif isinstance(raw_bind, str):
        value_expr = raw_bind
    else:
        value_expr = None
    bind = raw_bind if isinstance(raw_bind, dict) else {}
    if value_expr is not None:
        try:
            init_result = evaluate(value_expr, store.eval_context(ctx))
            if isinstance(init_result.value, (int, float)):
                slider.setValue(int(init_result.value))
        except Exception:
            pass

    # Writeback path: drag fires valueChanged per pixel, so push the
    # new value into panel/dialog state on every change. Without
    # this the slider is purely cosmetic — moving the H slider
    # doesn't update panel.h and the canvas color stays put
    # (CLR-022..29 Python).
    if isinstance(value_expr, str):
        if value_expr.startswith("panel."):
            panel_field = value_expr[len("panel."):]
            widget_pid = ctx.get("_panel_id")
            # Snap to step before writing — Qt's setSingleStep only
            # governs keyboard arrows, so drag / click would write
            # raw 0–255 values to the panel state. Snapping at the
            # write boundary forces the Web Safe RGB sliders to
            # commit only multiples of 51 (CLR-060 Python).
            def _on_change(v, _f=panel_field, _pid=widget_pid, _s=step):
                snapped = int(round(v / _s) * _s) if _s > 1 else int(v)
                # Bounce the slider's visible position back to the
                # snapped value so the thumb sits on a step edge.
                if _s > 1 and snapped != int(v):
                    slider.blockSignals(True)
                    slider.setValue(snapped)
                    slider.blockSignals(False)
                pid = _pid or store.get_active_panel_id()
                if pid is not None:
                    store.set_panel(pid, _f, snapped)
            slider.valueChanged.connect(_on_change)
            # Slider release on a Color-panel channel commits the
            # final color into the model's recent_colors list. Live
            # drag goes through set_active_color_live which only
            # updates the default + selection; the recent push and
            # the undo snapshot belong to the commit point
            # (CLR-022..29 Python).
            if widget_pid == "color_panel_content" and panel_field in (
                "h", "s", "b", "r", "g", "bl", "c", "m", "y", "k"):
                get_model = ctx.get("_get_model")
                def _on_release():
                    model = get_model() if callable(get_model) else None
                    if model is None:
                        return
                    from panels.panel_menu import (
                        set_active_color, _compute_helper)
                    ps = store.get_panel_state("color_panel_content") or {}
                    mode = ps.get("mode", "hsb")
                    color = _compute_helper(ps, mode)
                    if color is not None:
                        # set_active_color's Controller mutator self-brackets
                        # via edit_document (one undo step).
                        set_active_color(color, model)
                slider.sliderReleased.connect(_on_release)
        elif value_expr.startswith("dialog."):
            field = value_expr[len("dialog."):]
            def _on_change_dlg(v, _f=field):
                store.set_dialog(_f, int(v))
            slider.valueChanged.connect(_on_change_dlg)
    return slider


def _input_css():
    """Build the QSpinBox / QLineEdit stylesheet from the active
    appearance's theme tokens so value boxes re-skin alongside the
    rest of the panel (CLR-261/262 Python — was hardcoded dark on
    every appearance).
    """
    try:
        from workspace.dock_panel import (
            THEME_TEXT, THEME_BG_DARK, THEME_BORDER,
        )
        return (
            f"QSpinBox, QLineEdit {{ color: {THEME_TEXT}; "
            f"background: {THEME_BG_DARK}; "
            f"border: 1px solid {THEME_BORDER}; "
            f"border-radius: 2px; padding: 2px 4px; }}"
        )
    except Exception:
        return (
            "QSpinBox, QLineEdit { color: #ccc; background: #2a2a2a; "
            "border: 1px solid #555; border-radius: 2px; padding: 2px 4px; }"
        )


_INPUT_DARK_CSS = _input_css()
_INPUT_MIN_HEIGHT = 26


def _render_number_input(el, store, ctx, dispatch_fn):
    spin = QSpinBox()
    spin.setStyleSheet(_input_css())
    spin.setMinimumHeight(_INPUT_MIN_HEIGHT)
    spin.setMinimum(el.get("min", 0))
    spin.setMaximum(el.get("max", 999999))
    # Accept both the dict form (bind: { value: "panel.X" }) and
    # the bare-string form (bind: "dialog.X") — the color picker
    # uses the bare-string form via the radio_field_row template,
    # so without this the picker's H/S/B/etc. value boxes never
    # commit (CLR-214 Python).
    raw_bind = el.get("bind")
    if isinstance(raw_bind, dict):
        value_expr = raw_bind.get("value") if isinstance(raw_bind.get("value"), str) else None
    elif isinstance(raw_bind, str):
        value_expr = raw_bind
    else:
        value_expr = None
    bind = raw_bind if isinstance(raw_bind, dict) else {}
    # Initial value from bind.value (panel.X or dialog.X).
    if value_expr is not None:
        try:
            init_result = evaluate(value_expr, store.eval_context(ctx))
            if isinstance(init_result.value, (int, float)):
                spin.setValue(int(init_result.value))
        except Exception:
            pass
    # Writeback path. Without this, typing into a spin box bound to
    # dialog.bleed_top is purely cosmetic — the dialog state stays at
    # its default so OK / canvas-bleed-guide both see zero.
    if isinstance(value_expr, str):
        if value_expr.startswith("dialog."):
            field = value_expr[len("dialog."):]
            # Only commit when the user has actually edited the box
            # (typed or clicked the spinner) since the last commit.
            # editingFinished otherwise re-fires on focus loss with
            # the stale value, and the YAML setter cascades — e.g.
            # clicking OK after editing the hex field triggers the H
            # box's editingFinished with H=180, which runs the H
            # setter and rewrites color back from #ff0000 to cyan
            # (CLR-218 Python).
            user_edited = [False]
            le = spin.lineEdit()
            if le is not None:
                le.textEdited.connect(lambda _t: user_edited.__setitem__(0, True))
            def _on_change(v):
                # textEdited didn't fire — must be spin arrows
                # (those change value without textEdited), so this
                # IS a user edit. valueChanged also fires for
                # programmatic setValue, which we want to skip —
                # those happen during binding refresh AFTER a
                # sibling setter (H box gets refreshed when hex set
                # changes color → dialog.h getter recomputes). Use
                # the dedup check to distinguish: if the value
                # matches current dialog state, the change was a
                # binding sync, not a user edit.
                cur = store.get_dialog(field)
                if isinstance(cur, (int, float)) and int(cur) == int(v):
                    return
                user_edited[0] = True
                store.set_dialog(field, v)
            spin.valueChanged.connect(_on_change)
            def _on_finished():
                if not user_edited[0]:
                    return
                user_edited[0] = False
                spin.interpretText()
                v = spin.value()
                cur = store.get_dialog(field)
                if isinstance(cur, (int, float)) and int(cur) == int(v):
                    return
                store.set_dialog(field, v)
            spin.editingFinished.connect(_on_finished)
        elif value_expr.startswith("panel."):
            panel_field = value_expr[len("panel."):]
            # Capture the per-widget panel id so writes always land in
            # the panel that owns this control (matches the
            # icon_select / icon_toggle path); store.get_active_panel_id
            # races with whichever panel happens to be focus-active.
            widget_pid = ctx.get("_panel_id")
            def _write(v):
                pid = widget_pid or store.get_active_panel_id()
                if pid is None:
                    return
                if pid == "paragraph_panel_content":
                    from panels.paragraph_panel_state import (
                        set_paragraph_panel_field,
                    )
                    get_model = ctx.get("_get_model")
                    model = get_model() if callable(get_model) else None
                    if model is not None:
                        set_paragraph_panel_field(store, model, panel_field, v)
                        return
                store.set_panel(pid, panel_field, v)
            # Commit only on Enter / focus-loss (not valueChanged)
            # so the canvas reflows once per edit, not per keystroke.
            # Spin-button arrow clicks also count as editingFinished
            # in Qt, so the user still gets immediate feedback there.
            def _on_finished_panel():
                spin.interpretText()
                _write(spin.value())
            spin.editingFinished.connect(_on_finished_panel)
    return spin


def _render_text_input(el, store, ctx, dispatch_fn):
    edit = QLineEdit()
    edit.setStyleSheet(_input_css())
    edit.setMinimumHeight(_INPUT_MIN_HEIGHT)
    placeholder = el.get("placeholder", "")
    if placeholder:
        edit.setPlaceholderText(str(placeholder))
    max_len = el.get("max_length")
    if max_len:
        edit.setMaxLength(int(max_len))
    raw_bind = el.get("bind")
    if isinstance(raw_bind, dict):
        value_expr = raw_bind.get("value") if isinstance(raw_bind.get("value"), str) else None
    elif isinstance(raw_bind, str):
        value_expr = raw_bind
    else:
        value_expr = None
    bind = raw_bind if isinstance(raw_bind, dict) else {}
    if value_expr is not None:
        try:
            init = evaluate(value_expr, store.eval_context(ctx))
            v = getattr(init, "value", None)
            if isinstance(v, str):
                edit.setText(v)
        except Exception:
            pass
    if isinstance(value_expr, str) and value_expr.startswith("dialog."):
        field = value_expr[len("dialog."):]
        def _on_finished():
            v = edit.text()
            cur = store.get_dialog(field)
            if isinstance(cur, str) and cur == v:
                return
            store.set_dialog(field, v)
        edit.editingFinished.connect(_on_finished)
    elif isinstance(value_expr, str) and value_expr.startswith("panel."):
        panel_field = value_expr[len("panel."):]
        widget_pid = ctx.get("_panel_id")
        def _on_finished_panel():
            pid = widget_pid or store.get_active_panel_id()
            if pid is not None:
                store.set_panel(pid, panel_field, edit.text())
        edit.editingFinished.connect(_on_finished_panel)
    return edit


def _render_length_input(el, store, ctx, dispatch_fn):
    """Unit-aware text input for length-valued fields. Mirrors the
    Flask + Rust + Swift + OCaml implementation — see UNIT_INPUTS.md.

    Display goes through ``Length.format``; commit on Enter / focus
    loss goes through ``Length.parse`` and honors ``min``/``max``
    clamps and the ``nullable`` flag. The bound state and committed
    value are pt-valued; conversion happens at the widget edge.
    """
    from workspace_interpreter.length import format_length, parse_length

    edit = QLineEdit()
    edit.setStyleSheet(_input_css())
    placeholder = el.get("placeholder", "")
    if placeholder:
        edit.setPlaceholderText(str(placeholder))
    unit = el.get("unit", "pt")
    precision = int(el.get("precision", 2))
    nullable = bool(el.get("nullable", False))
    min_clamp = el.get("min")
    max_clamp = el.get("max")
    # Stash format params on the widget so _set_widget_value can route
    # the reactive bind.value updates through length_format rather
    # than the default str() conversion.
    edit._jas_length_unit = unit
    edit._jas_length_precision = precision

    bind = el.get("bind", {}) if isinstance(el.get("bind"), dict) else {}
    value_expr = bind.get("value")
    if not isinstance(value_expr, str):
        return edit

    # Resolve the panel-scoped write target from a `panel.<key>`
    # binding. Computed expressions (anything else) commit nowhere —
    # the field is read-only in that case.
    write_key = None
    if value_expr.startswith("panel."):
        rest = value_expr[len("panel."):]
        if rest and rest.replace("_", "").isalnum():
            write_key = rest

    def _commit():
        if write_key is None:
            return
        panel_id = store.get_active_panel_id()
        if panel_id is None:
            return
        entered = edit.text()
        trimmed = entered.strip()
        prior = store.get_panel(panel_id, write_key)
        if not trimmed:
            if nullable:
                # Character panel ``leading`` is Auto when the
                # element's line_height is empty; clearing the field
                # re-derives the Auto-tracked value (font_size × 1.2)
                # and the apply pipeline writes it back out as the
                # empty element attribute. No other Character field is
                # nullable yet. Mirrors Rust ``render_length_input``.
                if (panel_id == "character_panel_content"
                        and write_key == "leading"):
                    fs = store.get_panel(panel_id, "font_size") or 0.0
                    store.set_panel(panel_id, write_key,
                                    float(fs) * 1.2)
                else:
                    store.set_panel(panel_id, write_key, None)
            else:
                # Revert to prior display.
                edit.setText(format_length(prior, unit, precision))
            return
        new_val = parse_length(entered, unit)
        if new_val is None:
            edit.setText(format_length(prior, unit, precision))
            return
        if min_clamp is not None and new_val < float(min_clamp):
            new_val = float(min_clamp)
        if max_clamp is not None and new_val > float(max_clamp):
            new_val = float(max_clamp)
        store.set_panel(panel_id, write_key, new_val)
        # Reflect the clamped / re-formatted value back.
        edit.setText(format_length(new_val, unit, precision))

    edit.editingFinished.connect(_commit)
    return edit


def _render_toggle(el, store, ctx, dispatch_fn):
    icon_btn = _maybe_icon_toggle(el, store, ctx)
    if icon_btn is not None:
        return icon_btn
    label = el.get("label", "")
    cb = QCheckBox(label)
    _apply_checkbox_theme(cb)
    _wire_opacity_mask_checkbox(cb, el, store, ctx)
    _wire_dialog_checkbox(cb, el, store, ctx)
    return cb


def _render_checkbox(el, store, ctx, dispatch_fn):
    icon_btn = _maybe_icon_toggle(el, store, ctx)
    if icon_btn is not None:
        return icon_btn
    label = el.get("label", "")
    cb = QCheckBox(label)
    _apply_checkbox_theme(cb)
    _wire_opacity_mask_checkbox(cb, el, store, ctx)
    _wire_dialog_checkbox(cb, el, store, ctx)
    return cb


def _apply_checkbox_theme(cb: QCheckBox) -> None:
    """Match the panel body's dark theme so the label is legible.
    Without this the QCheckBox label inherits the system palette and
    renders as black on the dark dock background."""
    cb.setStyleSheet(
        "QCheckBox { color: #ccc; }"
        "QCheckBox::indicator { width: 14px; height: 14px; }"
    )


def _maybe_icon_toggle(el, store, ctx):
    """If this checkbox / toggle declares ``icon: <name>``, render it
    as a square checkable button that draws the workspace icon glyph
    instead of a plain text-label QCheckBox. Used by the Paragraph
    panel's alignment / justification row and the Bullets / Numbered
    chooser; the Rust / Swift / OCaml ports take the same branch.

    Wires the toggled signal to ``set_paragraph_panel_field`` so the
    alignment row's mutual-exclusion + apply pipeline runs on every
    click (the Rust/Swift/OCaml ports do the same). Subscribes to the
    panel store so the visual checked-state stays in sync when sibling
    buttons in the same radio group write [false] back here.

    Returns ``None`` when there is no icon — callers fall through to
    the plain QCheckBox path.
    """
    icon_name = el.get("icon") if isinstance(el.get("icon"), str) else None
    if not icon_name:
        return None
    style = el.get("style", {}) if isinstance(el.get("style"), dict) else {}
    raw = style.get("width") or style.get("height") or style.get("size") or 24
    size = int(raw) if isinstance(raw, (int, float)) else 24
    btn = QPushButton()
    btn.setCheckable(True)
    btn.setFlat(True)
    btn.setFixedSize(size, size)
    pixmap = _workspace_icon_pixmap(icon_name, max(size - 4, 12))
    if pixmap is not None:
        from PySide6.QtGui import QIcon
        from PySide6.QtCore import QSize
        btn.setIcon(QIcon(pixmap))
        btn.setIconSize(QSize(max(size - 4, 12), max(size - 4, 12)))
    summary = el.get("summary")
    if isinstance(summary, str) and summary:
        btn.setToolTip(summary)
    btn.setStyleSheet(
        "QPushButton { border: 1px solid #555; border-radius: 3px; "
        "background: #3a3a3a; padding: 0; }"
        "QPushButton:checked { background: #5a5a5a; border-color: #888; }"
    )

    bind = el.get("bind", {}) if isinstance(el.get("bind"), dict) else {}
    value_expr = bind.get("value") if isinstance(bind.get("value"), str) else None
    panel_id = ctx.get("_panel_id")
    field = None
    if isinstance(value_expr, str) and value_expr.startswith("panel."):
        field = value_expr[len("panel."):]
    if field and panel_id:
        # Initialize from the live panel state.
        try:
            cur = store.get_panel(panel_id, field)
            btn.setChecked(bool(cur))
        except Exception:
            pass

        suppress = {"flag": False}

        def _on_toggled(checked: bool):
            if suppress["flag"]:
                return
            get_model = ctx.get("_get_model")
            model = get_model() if callable(get_model) else None
            if model is not None and panel_id == "paragraph_panel_content":
                from panels.paragraph_panel_state import set_paragraph_panel_field
                set_paragraph_panel_field(store, model, field, bool(checked))
            else:
                store.set_panel(panel_id, field, bool(checked))

        btn.toggled.connect(_on_toggled)

        def _on_panel_change(key, value):
            from shiboken6 import isValid
            if not isValid(btn):
                return
            if key != field:
                return
            want = bool(value)
            if btn.isChecked() != want:
                suppress["flag"] = True
                btn.setChecked(want)
                suppress["flag"] = False

        store.subscribe_panel(panel_id, _on_panel_change)
    return btn


def _wire_dialog_checkbox(cb: QCheckBox, el: dict, store: StateStore, ctx: dict):
    """Initialise + wire writeback for ``bind.checked: dialog.X``
    OR the bare-string ``bind: dialog.X`` form (used by the color
    picker's Only-Web-Colors toggle) on a checkbox / toggle. No-op
    for non-dialog binds (those flow through _apply_bindings +
    the panel-level subscriber)."""
    raw_bind = el.get("bind")
    if isinstance(raw_bind, dict):
        checked_expr = raw_bind.get("checked") if isinstance(raw_bind.get("checked"), str) else None
        if checked_expr is None:
            checked_expr = raw_bind.get("value") if isinstance(raw_bind.get("value"), str) else None
    elif isinstance(raw_bind, str):
        checked_expr = raw_bind
    else:
        checked_expr = None
    if not isinstance(checked_expr, str):
        return
    try:
        init = evaluate(checked_expr, store.eval_context(ctx))
        v = getattr(init, "value", None)
        if isinstance(v, bool):
            cb.setChecked(v)
    except Exception:
        pass
    if checked_expr.startswith("dialog."):
        field = checked_expr[len("dialog."):]
        def _on_toggled(state: int):
            from PySide6.QtCore import Qt as _Qt
            new_val = state == _Qt.CheckState.Checked.value or bool(state)
            store.set_dialog(field, new_val)
            # Color picker "Only Web Colors": when toggled ON, snap
            # each RGB channel of the current color to multiples of
            # 51 by writing through the r/g/bl setters (which rebuild
            # canonical color via the rgb() lambda).
            if field == "web_only" and new_val:
                for ch in ("r", "g", "bl"):
                    try:
                        cur = store.get_dialog(ch)
                        if isinstance(cur, (int, float)):
                            snapped = round(cur / 51.0) * 51
                            snapped = max(0, min(255, int(snapped)))
                            store.set_dialog(ch, snapped)
                    except Exception:
                        pass
        cb.stateChanged.connect(_on_toggled)


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
    bind = el.get("bind", {}) if isinstance(el.get("bind"), dict) else {}
    value_expr = bind.get("value") if isinstance(bind.get("value"), str) else None
    if value_expr is not None:
        try:
            init = evaluate(value_expr, store.eval_context(ctx))
            v = getattr(init, "value", None)
            if v is not None:
                # Find the option whose data matches and select it.
                for i in range(combo.count()):
                    if combo.itemData(i) == v:
                        combo.setCurrentIndex(i)
                        break
        except Exception:
            pass
    if isinstance(value_expr, str) and value_expr.startswith("dialog."):
        field = value_expr[len("dialog."):]
        def _on_select(idx: int):
            data = combo.itemData(idx)
            store.set_dialog(field, data)
        combo.currentIndexChanged.connect(_on_select)
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


class _PanelFillStrokeWidget(QWidget):
    """Color-panel variant of the toolbar's FillStrokeWidget that
    scales proportionally to its allocated size so it fits in the
    panel's YAML-declared height (~60 px) without clipping.

    The toolbar's widget is hardcoded to 64x80, which forces the
    color panel row to grow and overlaps the next row downstream.
    This widget mirrors the toolbar's paint exactly (overlapping
    fill + stroke squares with hollow stroke ring, swap-arrow
    glyph, default-reset icon, and 3 mode buttons across the
    bottom) but every position and size is derived from the
    requested overall size. Mode buttons live at y = size * 0.78,
    matching the YAML template's [mode_y: size * 94/100] ratio
    minus a few px so they fit within the panel's row height.

    Signals match FillStrokeWidget so the panel renderer's signal
    wiring stays consistent across widgets.
    """

    from PySide6.QtCore import Signal as _Signal
    fill_clicked = _Signal()
    stroke_clicked = _Signal()
    fill_double_clicked = _Signal()
    stroke_double_clicked = _Signal()
    swap_clicked = _Signal()
    default_clicked = _Signal()
    fill_none_clicked = _Signal()
    stroke_none_clicked = _Signal()

    def __init__(self, width=48, height=60, parent=None):
        super().__init__(parent)
        self._fill_color = QColor(255, 255, 255)
        self._stroke_color = QColor(0, 0, 0)
        self._fill_on_top = True
        self.setFixedSize(int(width), int(height))

    def set_fill_color(self, color):
        self._fill_color = color
        self.update()

    def set_stroke_color(self, color):
        self._stroke_color = color
        self.update()

    def set_fill_on_top(self, on_top):
        self._fill_on_top = bool(on_top)
        self.update()

    def _swatch_rect(self, which):
        from PySide6.QtCore import QRect
        w = self.width()
        h = self.height()
        # Proportions match the YAML template:
        #   swatch_size = size * 55/100
        #   fill_x, fill_y = size * 9/100
        #   stroke_x, stroke_y = size * 33/100
        # Use the smaller of w/h as the base so the widget stays
        # square-ish in tall cells.
        base = min(w, int(h * 64.0 / 80.0))
        sq = max(8, int(base * 0.55))
        if which == "fill":
            return QRect(int(base * 0.09), int(base * 0.09), sq, sq)
        else:
            return QRect(int(base * 0.33), int(base * 0.33), sq, sq)

    def _swap_rect(self):
        from PySide6.QtCore import QRect
        w = self.width()
        h = self.height()
        base = min(w, int(h * 64.0 / 80.0))
        sz = int(base * 0.30)
        x = int(base * 0.64)
        y = int(base * 0.03)
        return QRect(x, y, sz, sz)

    def _reset_rect(self):
        from PySide6.QtCore import QRect
        w = self.width()
        h = self.height()
        base = min(w, int(h * 64.0 / 80.0))
        # Slightly smaller than the YAML's 30% so the mode-button
        # row below has breathing room — at h=60 a 30% reset
        # touches a 24% mode button, looking cramped.
        sz = int(base * 0.22)
        x = int(base * 0.03)
        y = int(base * 0.68)
        return QRect(x, y, sz, sz)

    def _mode_button_rects(self):
        from PySide6.QtCore import QRect
        w = self.width()
        h = self.height()
        base = min(w, int(h * 64.0 / 80.0))
        sz = max(8, int(base * 0.22))
        # Bottom-pin with a 2-px margin so the reset icon (which
        # ends around 68%+22%=90% of base) gets a few extra pixels
        # of vertical gap before the mode-button row.
        y = max(0, h - sz - 2)
        gap = max(2, int(base * 0.03))
        x0 = int(base * 0.06)
        return [
            QRect(x0,                       y, sz, sz),
            QRect(x0 + (sz + gap) * 1,      y, sz, sz),
            QRect(x0 + (sz + gap) * 2,      y, sz, sz),
        ]

    def paintEvent(self, event):
        from PySide6.QtGui import QPainter, QPen
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        fr = self._swatch_rect("fill")
        sr = self._swatch_rect("stroke")

        def draw_fill(r):
            if self._fill_color is not None:
                painter.setPen(QPen(QColor("#666"), 1))
                painter.setBrush(self._fill_color)
            else:
                painter.setPen(QPen(QColor("#666"), 1))
                painter.setBrush(QColor(255, 255, 255))
            painter.drawRect(r)
            if self._fill_color is None:
                painter.setPen(QPen(QColor(255, 0, 0), 1.5))
                painter.drawLine(r.left() + 1, r.bottom() - 1,
                                 r.right() - 1, r.top() + 1)

        def draw_stroke(r):
            if self._stroke_color is None:
                painter.setPen(QPen(QColor(128, 128, 128), 1))
                painter.setBrush(QColor(255, 255, 255))
                painter.drawRect(r)
                painter.setPen(QPen(QColor(255, 0, 0), 1.5))
                painter.drawLine(r.left() + 1, r.bottom() - 1,
                                 r.right() - 1, r.top() + 1)
            else:
                bw = max(3, r.width() // 5)  # border width scaled
                # outline
                painter.setPen(QPen(QColor(128, 128, 128), 1))
                painter.setBrush(Qt.BrushStyle.NoBrush)
                painter.drawRect(r)
                # colored ring
                painter.setPen(Qt.PenStyle.NoPen)
                painter.setBrush(self._stroke_color)
                painter.drawRect(r.left() + 1, r.top() + 1,
                                 r.width() - 1, bw)
                painter.drawRect(r.left() + 1, r.bottom() - bw,
                                 r.width() - 1, bw)
                painter.drawRect(r.left() + 1, r.top() + bw,
                                 bw, r.height() - 2 * bw)
                painter.drawRect(r.right() - bw, r.top() + bw,
                                 bw, r.height() - 2 * bw)
                # white center
                painter.setBrush(QColor(255, 255, 255))
                painter.drawRect(r.left() + bw + 1, r.top() + bw + 1,
                                 r.width() - 2 * bw - 1,
                                 r.height() - 2 * bw - 1)

        if self._fill_on_top:
            draw_stroke(sr); draw_fill(fr)
        else:
            draw_fill(fr); draw_stroke(sr)

        # Swap arrow
        wr = self._swap_rect()
        painter.setPen(QPen(_icon_color_or_ccc(), 1))
        # 4-line arrow glyph
        painter.drawLine(wr.left(), wr.top(),
                         wr.left() + wr.width(), wr.top())
        painter.drawLine(wr.left() + wr.width(), wr.top(),
                         wr.left() + wr.width(),
                         wr.top() + wr.height())
        painter.drawLine(wr.left() + wr.width(),
                         wr.top() + wr.height(),
                         wr.left() + wr.width() - 3,
                         wr.top() + wr.height() - 3)
        painter.drawLine(wr.left() + wr.width(),
                         wr.top() + wr.height(),
                         wr.left() + wr.width() + 3,
                         wr.top() + wr.height() - 3)

        # Reset icon — small fill + stroke pair
        rr = self._reset_rect()
        painter.setPen(QPen(QColor("#999"), 1))
        painter.setBrush(QColor(255, 255, 255))
        painter.drawRect(rr.left() + 3, rr.top() + 3,
                         rr.width() - 4, rr.height() - 4)
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.setPen(QPen(QColor(0, 0, 0), 2))
        painter.drawRect(rr.left(), rr.top(),
                         rr.width() - 4, rr.height() - 4)

        # Mode buttons
        rects = self._mode_button_rects()
        # Color (filled square)
        painter.setPen(QPen(QColor("#999"), 1))
        painter.setBrush(QColor("#666"))
        painter.drawRect(rects[0])
        # Gradient placeholder (dim)
        painter.setPen(QPen(QColor("#555"), 1))
        painter.setBrush(QColor("#444"))
        painter.drawRect(rects[1])
        # None (white box with red diagonal)
        painter.setPen(QPen(QColor("#555"), 1))
        painter.setBrush(QColor("#fff"))
        painter.drawRect(rects[2])
        painter.setPen(QPen(QColor(255, 0, 0), 1.5))
        painter.drawLine(rects[2].left() + 1,
                         rects[2].bottom() - 1,
                         rects[2].right() - 1,
                         rects[2].top() + 1)

    def _hit(self, x, y):
        fr = self._swatch_rect("fill")
        sr = self._swatch_rect("stroke")
        if self._swap_rect().contains(x, y):
            return "swap"
        if self._reset_rect().contains(x, y):
            return "reset"
        rects = self._mode_button_rects()
        if rects[2].contains(x, y):
            return "none"
        if self._fill_on_top:
            if fr.contains(x, y): return "fill"
            if sr.contains(x, y): return "stroke"
        else:
            if sr.contains(x, y): return "stroke"
            if fr.contains(x, y): return "fill"
        return None

    def mousePressEvent(self, event):
        x, y = int(event.position().x()), int(event.position().y())
        what = self._hit(x, y)
        if what == "swap":
            self.swap_clicked.emit()
        elif what == "reset":
            self.default_clicked.emit()
        elif what == "none":
            if self._fill_on_top:
                self.fill_none_clicked.emit()
            else:
                self.stroke_none_clicked.emit()
        elif what == "fill":
            self._fill_on_top = True
            self.fill_clicked.emit()
            self.update()
        elif what == "stroke":
            self._fill_on_top = False
            self.stroke_clicked.emit()
            self.update()

    def mouseDoubleClickEvent(self, event):
        x, y = int(event.position().x()), int(event.position().y())
        what = self._hit(x, y)
        if what == "fill":
            self._fill_on_top = True
            self.update()
            self.fill_double_clicked.emit()
        elif what == "stroke":
            self._fill_on_top = False
            self.update()
            self.stroke_double_clicked.emit()


def _icon_color_or_ccc():
    """Return the active theme's icon color, or a sane #ccc fallback
    when the theme module isn't importable from this context."""
    try:
        from tools.toolbar import _icon_color
        return _icon_color()
    except Exception:
        return QColor("#cccccc")


def _render_fill_stroke_widget(el, store, ctx, dispatch_fn):
    """Substitute the YAML fill_stroke_widget template's expanded
    container with the panel's scalable [_PanelFillStrokeWidget].

    Reads the YAML's style.width / style.height (set by the
    template's [width: size] + [height: size * 124/100] defaults
    via params overrides in color.yaml) so the widget shrinks to
    fit the panel row's allocated height — avoids the
    layout-overflow that an unscalable toolbar-sized 64x80 widget
    would create.

    Live colors come from a global-store subscription on
    [fill_color] / [stroke_color] / [fill_on_top]; signals forward
    to the YAML's declared action names through [dispatch_fn].
    """
    style = el.get("style", {}) or {}
    try:
        width = int(float(style.get("width", 48)))
    except (TypeError, ValueError):
        width = 48
    try:
        height = int(float(style.get("height", 60)))
    except (TypeError, ValueError):
        height = 60
    # min_height is honoured if larger than computed height (color
    # panel passes {min_height: 60} alongside its 48-wide widget).
    try:
        min_h = int(float(style.get("min_height", 0)))
    except (TypeError, ValueError):
        min_h = 0
    if min_h > height:
        height = min_h

    fs = _PanelFillStrokeWidget(width=width, height=height)

    def _qcolor(hex_str):
        if not isinstance(hex_str, str) or not hex_str:
            return None
        s = hex_str
        if s.startswith("#"):
            s = s[1:]
        if len(s) == 3:
            s = "".join(c * 2 for c in s)
        if len(s) != 6:
            return None
        try:
            r = int(s[0:2], 16)
            g = int(s[2:4], 16)
            b = int(s[4:6], 16)
        except ValueError:
            return None
        return QColor(r, g, b)

    # Wrap in RuntimeError guards so when the dock rebuilds (which
    # deletes this widget) but the global store still holds the
    # subscription, the next state.fill_color write doesn't crash
    # with "Internal C++ object already deleted" (CLR-012 Python).
    # A safe-to-call lambda that probes the C++ object lifetime up
    # front avoids invoking set_* on a dead widget.
    def _sync():
        try:
            fs.isVisible()  # probes the underlying Qt object's lifetime
        except RuntimeError:
            return
        ec = store.eval_context(ctx)
        try:
            fc = evaluate("state.fill_color", ec)
            fc_val = fc.value if hasattr(fc, "value") else fc
        except Exception:
            fc_val = None
        try:
            sc = evaluate("state.stroke_color", ec)
            sc_val = sc.value if hasattr(sc, "value") else sc
        except Exception:
            sc_val = None
        try:
            ft = evaluate("state.fill_on_top", ec)
            ft_val = ft.value if hasattr(ft, "value") else ft
        except Exception:
            ft_val = True
        try:
            fs.set_fill_color(_qcolor(fc_val) if fc_val else None)
            fs.set_stroke_color(_qcolor(sc_val) if sc_val else None)
            fs.set_fill_on_top(bool(ft_val) if ft_val is not None else True)
        except RuntimeError:
            return

    _sync()
    store.subscribe(None, lambda *_: _sync())

    if dispatch_fn:
        fs.swap_clicked.connect(lambda: dispatch_fn("swap_fill_stroke", {}))
        fs.default_clicked.connect(lambda: dispatch_fn("reset_fill_stroke", {}))
        fs.fill_double_clicked.connect(
            lambda: dispatch_fn("open_color_picker", {"target": "fill"}))
        fs.stroke_double_clicked.connect(
            lambda: dispatch_fn("open_color_picker", {"target": "stroke"}))
        fs.fill_none_clicked.connect(lambda: dispatch_fn("set_fill_none", {}))
        fs.stroke_none_clicked.connect(lambda: dispatch_fn("set_stroke_none", {}))

    # Click on fill / stroke swatch flips both the YAML state key
    # (so other widgets bound to state.fill_on_top — e.g. slider
    # disabled bindings, the channel write-back bridge — pick up
    # the change) AND the model attribute (so set_active_color_live
    # / set_active_color route to the right side; the bridge reads
    # model.fill_on_top directly).
    get_model = ctx.get("_get_model")
    def _set_active_side(top: bool):
        store.set("fill_on_top", top)
        m = get_model() if callable(get_model) else None
        if m is not None:
            m.fill_on_top = top
    fs.fill_clicked.connect(lambda: _set_active_side(True))
    fs.stroke_clicked.connect(lambda: _set_active_side(False))

    return fs


def _render_color_swatch(el, store, ctx, dispatch_fn):
    btn = QPushButton()
    size = el.get("style", {}).get("size", 16)
    btn.setFixedSize(int(size), int(size))
    btn.setFlat(True)
    # Color and selected_in highlight are applied via _apply_bindings
    # (bind.color sets the background; bind.selected_in sets the
    # accent border, with a panel-state subscription to track
    # selection changes).
    return btn


def _selected_in_target_expr(el):
    """Find the per-item identity expression on a tile widget by looking
    at its click behavior list and returning the first select.target.
    Used by the bind.selected_in path so authors don't restate the
    target. Returns None if no select.target is declared."""
    for b in (el.get("behavior") or []):
        if not isinstance(b, dict):
            continue
        for e in (b.get("effects") or []):
            if isinstance(e, dict):
                sel = e.get("select")
                if isinstance(sel, dict):
                    t = sel.get("target")
                    if isinstance(t, str) and t:
                        return t
    return None


def _selected_in_loose_eq(a, b):
    """Loose equality used for selected_in membership tests."""
    if a is None and b is None:
        return True
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    return a == b


_GRADIENT_TILE_SIZES = {"small": 16, "medium": 32, "large": 64}


def _eval_bind_object(expr, store, ctx):
    """Evaluate a bind expression that resolves to an object/list.

    The expression language serializes objects to JSON strings;
    parses them back here so the renderer can read fields.
    """
    if not isinstance(expr, str) or not expr:
        return None
    try:
        result = evaluate(expr, store.eval_context(ctx))
    except Exception:
        return None
    val = result.value if hasattr(result, "value") else result
    if isinstance(val, str):
        import json
        try:
            return json.loads(val)
        except Exception:
            return None
    if isinstance(val, list):
        return val
    return None


def _gradient_qss_background(gradient):
    """Build a Qt stylesheet background value from a gradient dict.

    Qt stylesheet supports qlineargradient / qradialgradient syntax.
    Returns None if the gradient cannot be represented.
    """
    if not isinstance(gradient, dict):
        return None
    stops = gradient.get("stops")
    if not isinstance(stops, list) or len(stops) < 2:
        return None
    stop_specs = []
    for s in stops:
        if not isinstance(s, dict):
            continue
        color = s.get("color", "#000000")
        loc = s.get("location", 0) / 100.0
        opacity = s.get("opacity", 100)
        if opacity != 100 and isinstance(color, str) and color.startswith("#") and len(color) == 7:
            r = int(color[1:3], 16)
            g = int(color[3:5], 16)
            b = int(color[5:7], 16)
            color = f"rgba({r},{g},{b},{opacity / 100.0:.3f})"
        stop_specs.append(f"stop:{loc:.3f} {color}")
    if len(stop_specs) < 2:
        return None
    gtype = gradient.get("type", "linear")
    if gtype == "radial":
        return (
            "qradialgradient(cx:0.5, cy:0.5, radius:0.5, fx:0.5, fy:0.5, "
            + ", ".join(stop_specs) + ")"
        )
    # Linear. Angle convention: 0 = left-to-right. Compute endpoints on
    # the unit square accordingly.
    import math
    angle = gradient.get("angle", 0)
    rad = math.radians(angle)
    x1 = 0.5 - 0.5 * math.cos(rad)
    y1 = 0.5 + 0.5 * math.sin(rad)
    x2 = 0.5 + 0.5 * math.cos(rad)
    y2 = 0.5 - 0.5 * math.sin(rad)
    return (
        f"qlineargradient(x1:{x1:.3f}, y1:{y1:.3f}, x2:{x2:.3f}, y2:{y2:.3f}, "
        + ", ".join(stop_specs) + ")"
    )


def _render_gradient_tile(el, store, ctx, dispatch_fn):
    """Click-to-apply gradient preview tile."""
    size_key = el.get("size", "large")
    sz = _GRADIENT_TILE_SIZES.get(size_key, _GRADIENT_TILE_SIZES["large"])
    bind = el.get("bind") or {}
    gradient_expr = bind.get("gradient") if isinstance(bind, dict) else None
    gradient = _eval_bind_object(gradient_expr, store, ctx) if gradient_expr else None
    bg = _gradient_qss_background(gradient) or "#888"

    btn = QPushButton()
    btn.setFixedSize(sz, sz)
    btn.setFlat(True)
    btn.setStyleSheet(
        f"QPushButton {{ background: {bg}; border: 1px solid #666; }}"
    )
    # Click fires the behavior list (Phase 5 wires the action pipeline).
    if dispatch_fn:
        behaviors = el.get("behavior") or []
        def on_click():
            for b in behaviors:
                if isinstance(b, dict) and b.get("event") == "click":
                    action = b.get("action")
                    params = b.get("params") or {}
                    if action:
                        dispatch_fn(action, params)
        btn.clicked.connect(on_click)
    return btn


def _render_gradient_slider(el, store, ctx, dispatch_fn):
    """1-D color-stops editor.

    Phase 0 scope: visual tree + click-to-select gestures on stop and
    midpoint markers (emits gradient_slider_stop_click /
    gradient_slider_stop_dblclick / gradient_slider_midpoint_click
    actions). Full pointer drag state and keyboard handling are
    deferred to Phase 5.
    """
    bind = el.get("bind") or {}
    stops_expr = bind.get("stops") if isinstance(bind, dict) else None
    sel_stop_expr = bind.get("selected_stop_index") if isinstance(bind, dict) else None
    sel_mid_expr = bind.get("selected_midpoint_index") if isinstance(bind, dict) else None

    stops = _eval_bind_object(stops_expr, store, ctx) if stops_expr else None
    stops = stops if isinstance(stops, list) else []

    sel_stop = -1
    if sel_stop_expr:
        try:
            result = evaluate(sel_stop_expr, store.eval_context(ctx))
            val = result.value if hasattr(result, "value") else result
            if isinstance(val, (int, float)):
                sel_stop = int(val)
        except Exception:
            pass
    sel_mid = -1
    if sel_mid_expr:
        try:
            result = evaluate(sel_mid_expr, store.eval_context(ctx))
            val = result.value if hasattr(result, "value") else result
            if isinstance(val, (int, float)):
                sel_mid = int(val)
        except Exception:
            pass

    container_width = 240
    container = QWidget()
    container.setFixedSize(container_width, 44)

    # Bar
    if len(stops) >= 2:
        preview = {"type": "linear", "angle": 0, "stops": stops}
        bar_bg = _gradient_qss_background(preview) or "#888"
    else:
        bar_bg = "#888"
    bar = QPushButton(container)
    bar.setFixedSize(container_width, 16)
    bar.move(0, 14)
    bar.setFlat(True)
    bar.setStyleSheet(
        f"QPushButton {{ background: {bar_bg}; border: 1px solid #666; }}"
    )

    # Midpoint markers (diamonds approximated via square + stylesheet)
    num_pairs = max(len(stops) - 1, 0)
    for i in range(num_pairs):
        left = stops[i].get("location", 0) if isinstance(stops[i], dict) else 0
        right = stops[i + 1].get("location", 100) if isinstance(stops[i + 1], dict) else 100
        pct = stops[i].get("midpoint_to_next", 50) if isinstance(stops[i], dict) else 50
        mid_loc = left + (right - left) * (pct / 100.0)
        x = int(mid_loc / 100.0 * container_width) - 5
        m = QPushButton(container)
        m.setFixedSize(10, 10)
        m.move(x, 2)
        m.setFlat(True)
        sel_border = "2px solid #0af" if i == sel_mid else "1px solid #333"
        m.setStyleSheet(
            f"QPushButton {{ background: #888; border: {sel_border}; }}"
        )
        if dispatch_fn:
            idx = i
            m.clicked.connect(lambda _=False, j=idx: dispatch_fn(
                "gradient_slider_midpoint_click", {"midpoint_index": j}
            ))

    # Stop markers (circles via border-radius)
    for i, s in enumerate(stops):
        if not isinstance(s, dict):
            continue
        loc = s.get("location", 0)
        color = s.get("color", "#000000")
        x = int(loc / 100.0 * container_width) - 7
        sb = QPushButton(container)
        sb.setFixedSize(14, 14)
        sb.move(x, 30)
        sb.setFlat(True)
        sel_border = "2px solid #0af" if i == sel_stop else "1px solid #333"
        sb.setStyleSheet(
            f"QPushButton {{ background: {color}; border: {sel_border}; "
            f"border-radius: 7px; }}"
        )
        if dispatch_fn:
            idx = i
            sb.clicked.connect(lambda _=False, j=idx: dispatch_fn(
                "gradient_slider_stop_click", {"stop_index": j}
            ))

    return container


class _ColorGradientWidget(QWidget):
    """2D HSB gradient for the color picker dialog. Horizontal =
    saturation, vertical = brightness, colored by the current hue.
    Click / drag writes dialog.s + dialog.b.
    """
    def __init__(self, store, hue_expr, sat_expr, br_expr, parent=None):
        super().__init__(parent)
        from PySide6.QtCore import Qt as _Qt
        self._store = store
        self._hue_expr = hue_expr
        self._sat_expr = sat_expr
        self._br_expr = br_expr
        self.setMinimumSize(180, 180)
        self.setCursor(_Qt.CrossCursor)
        self._dragging = False
        store.subscribe(None, lambda *_: self._on_state_change())

    def _on_state_change(self):
        try:
            self.update()
        except RuntimeError:
            pass

    def _read_n(self, expr):
        if not expr:
            return 0.0
        try:
            r = evaluate(expr, self._store.eval_context({}))
            return float(r.value) if r.value is not None else 0.0
        except Exception:
            return 0.0

    def paintEvent(self, event):
        from PySide6.QtGui import QPainter, QImage, QColor, QPen
        from workspace_interpreter.color_util import hsb_to_rgb
        painter = QPainter(self)
        w, h = self.width(), self.height()
        if w <= 0 or h <= 0:
            return
        hue = self._read_n(self._hue_expr)
        img = QImage(w, h, QImage.Format_RGB32)
        for y in range(h):
            br = 100.0 * (1.0 - y / max(h - 1, 1))
            for x in range(w):
                sat = 100.0 * x / max(w - 1, 1)
                r, g, b = hsb_to_rgb(hue, sat, br)
                img.setPixelColor(x, y, QColor(r, g, b))
        painter.drawImage(0, 0, img)
        # Indicator circle at current (sat, br)
        sat = self._read_n(self._sat_expr)
        br = self._read_n(self._br_expr)
        cx = int(w * sat / 100.0)
        cy = int(h * (1.0 - br / 100.0))
        painter.setPen(QPen(QColor(255, 255, 255), 2))
        painter.drawEllipse(cx - 6, cy - 6, 12, 12)
        painter.setPen(QPen(QColor(0, 0, 0), 1))
        painter.drawEllipse(cx - 7, cy - 7, 14, 14)

    def _pick(self, x, y):
        w, h = max(self.width(), 1), max(self.height(), 1)
        x = max(0.0, min(float(x), w - 1))
        y = max(0.0, min(float(y), h - 1))
        sat = 100.0 * x / (w - 1) if w > 1 else 0
        br = 100.0 * (1.0 - y / (h - 1)) if h > 1 else 0
        if self._sat_expr.startswith("dialog."):
            self._store.set_dialog(self._sat_expr[len("dialog."):], sat)
        if self._br_expr.startswith("dialog."):
            self._store.set_dialog(self._br_expr[len("dialog."):], br)

    def mousePressEvent(self, event):
        from PySide6.QtCore import Qt as _Qt
        if event.button() == _Qt.LeftButton:
            self._dragging = True
            self._pick(event.position().x(), event.position().y())

    def mouseMoveEvent(self, event):
        if self._dragging:
            self._pick(event.position().x(), event.position().y())

    def mouseReleaseEvent(self, event):
        self._dragging = False


def _render_color_gradient(el, store, ctx, dispatch_fn):
    bind = el.get("bind", {}) if isinstance(el.get("bind"), dict) else {}
    hue_expr = bind.get("hue", "dialog.h")
    sat_expr = bind.get("saturation", "dialog.s")
    br_expr = bind.get("brightness", "dialog.b")
    style = el.get("style", {}) or {}
    w = style.get("min_width", 180)
    h = style.get("min_height", 180)
    widget = _ColorGradientWidget(store, hue_expr, sat_expr, br_expr)
    try:
        widget.setMinimumSize(int(w), int(h))
    except (TypeError, ValueError):
        pass
    return widget


class _ColorHueBarWidget(QWidget):
    """Vertical channel ramp for the color picker. Re-tints per the
    active radio channel (H = rainbow, S = grey→hue, B = black→hue,
    R/G/B = black→primary). Click/drag writes the matching channel.
    """
    def __init__(self, store, parent=None):
        super().__init__(parent)
        from PySide6.QtCore import Qt as _Qt
        self._store = store
        self.setMinimumSize(28, 100)
        self.setCursor(_Qt.CrossCursor)
        self._dragging = False
        store.subscribe(None, lambda *_: self._on_state_change())

    def _on_state_change(self):
        try:
            self.update()
        except RuntimeError:
            pass

    def _read(self, expr):
        try:
            r = evaluate(expr, self._store.eval_context({}))
            return r.value
        except Exception:
            return None

    def _read_n(self, name):
        v = self._read(f"dialog.{name}")
        return float(v) if isinstance(v, (int, float)) else 0.0

    def _channel_spec(self):
        from workspace_interpreter.color_util import hsb_to_rgb
        ch = self._read("dialog.radio_channel")
        if not isinstance(ch, str):
            ch = "h"
        if ch == "s":
            h = self._read_n("h"); b = self._read_n("b")
            return ("s", 100.0, lambda t: hsb_to_rgb(h, t * 100.0, b))
        if ch == "b":
            h = self._read_n("h"); s = self._read_n("s")
            return ("b", 100.0, lambda t: hsb_to_rgb(h, s, t * 100.0))
        if ch == "r":
            g = int(self._read_n("g")); bl = int(self._read_n("bl"))
            return ("r", 255.0, lambda t: (int(round(t * 255)), g, bl))
        if ch == "g":
            r = int(self._read_n("r")); bl = int(self._read_n("bl"))
            return ("g", 255.0, lambda t: (r, int(round(t * 255)), bl))
        if ch == "bl":
            r = int(self._read_n("r")); g = int(self._read_n("g"))
            return ("bl", 255.0, lambda t: (r, g, int(round(t * 255))))
        return ("h", 360.0, lambda t: hsb_to_rgb(t * 360.0, 100.0, 100.0))

    def paintEvent(self, event):
        from PySide6.QtGui import QPainter, QColor, QPen
        painter = QPainter(self)
        w, h = self.width(), self.height()
        if w <= 0 or h <= 0:
            return
        field, max_v, ramp = self._channel_spec()
        # Map t=0 to the BOTTOM of the bar and t=1 to the TOP so
        # the high-value end (full red / 100% brightness / etc.)
        # appears at the top. Matches the 2D gradient's convention
        # of brightness increasing upward.
        for y in range(h):
            t = 1.0 - (y + 0.5) / h
            r, g, b = ramp(t)
            painter.fillRect(0, y, w, 1, QColor(r, g, b))
        # Indicator at current value of the active channel
        v = self._read_n(field)
        # Invert position to match the painted ramp direction.
        y = int(h - h * v / max_v) if max_v > 0 else 0
        painter.setPen(QPen(QColor(0, 0, 0), 1))
        painter.drawLine(0, y, w, y)
        painter.setPen(QPen(QColor(255, 255, 255), 1))
        painter.drawLine(0, y - 1, w, y - 1)

    def _pick(self, y):
        h = max(self.height(), 1)
        y = max(0.0, min(float(y), h - 1))
        field, max_v, _ = self._channel_spec()
        # Invert: high values toward the top of the widget.
        v = max_v * (1.0 - y / (h - 1)) if h > 1 else 0
        self._store.set_dialog(field, v)

    def mousePressEvent(self, event):
        from PySide6.QtCore import Qt as _Qt
        if event.button() == _Qt.LeftButton:
            self._dragging = True
            self._pick(event.position().y())

    def mouseMoveEvent(self, event):
        if self._dragging:
            self._pick(event.position().y())

    def mouseReleaseEvent(self, event):
        self._dragging = False


def _render_color_hue_bar(el, store, ctx, dispatch_fn):
    widget = _ColorHueBarWidget(store)
    style = el.get("style", {}) or {}
    w = style.get("width", 28)
    min_h = style.get("min_height", 100)
    try:
        widget.setFixedWidth(int(w))
        widget.setMinimumHeight(int(min_h))
    except (TypeError, ValueError):
        pass
    return widget


class _RadioOptionWidget(QWidget):
    """Single circular radio indicator. Filled when the bound state
    equals the option's id."""
    def __init__(self, store, bind_expr, option_id, parent=None):
        super().__init__(parent)
        self._store = store
        self._bind_expr = bind_expr
        self._option_id = option_id
        self.setFixedSize(14, 14)
        from PySide6.QtCore import Qt as _Qt
        self.setCursor(_Qt.PointingHandCursor)
        store.subscribe(None, lambda *_: self._on_state_change())

    def _on_state_change(self):
        try:
            self.update()
        except RuntimeError:
            pass

    def _is_selected(self):
        try:
            r = evaluate(self._bind_expr, self._store.eval_context({}))
            return r.value == self._option_id
        except Exception:
            return False

    def paintEvent(self, event):
        from PySide6.QtGui import QPainter, QColor, QPen, QBrush
        from PySide6.QtCore import Qt as _Qt
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(QPen(QColor("#999"), 1))
        painter.setBrush(QBrush(_Qt.NoBrush))
        painter.drawEllipse(2, 2, 10, 10)
        if self._is_selected():
            painter.setPen(QPen(QColor("#ccc"), 1))
            painter.setBrush(QBrush(QColor("#ccc")))
            painter.drawEllipse(4, 4, 6, 6)

    def mousePressEvent(self, event):
        from PySide6.QtCore import Qt as _Qt
        if event.button() == _Qt.LeftButton:
            if self._bind_expr.startswith("dialog."):
                key = self._bind_expr[len("dialog."):]
                self._store.set_dialog(key, self._option_id)


def _render_radio_group(el, store, ctx, dispatch_fn):
    bind = el.get("bind")
    bind_expr = bind if isinstance(bind, str) else (
        bind.get("value") if isinstance(bind, dict) else None
    )
    options = el.get("options", []) or []
    container = QWidget()
    layout = QHBoxLayout(container)
    layout.setContentsMargins(0, 0, 0, 0)
    layout.setSpacing(4)
    for opt in options:
        if not isinstance(opt, dict):
            continue
        opt_id = opt.get("id", "")
        opt_label = opt.get("label", "")
        if not opt_id:
            continue
        if bind_expr:
            indicator = _RadioOptionWidget(store, bind_expr, opt_id)
            layout.addWidget(indicator)
        if opt_label:
            lbl = QLabel(opt_label)
            layout.addWidget(lbl)
    return container


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
    "CompoundShape": "Compound Shape", "ReferenceElem": "Reference",
    "RecordedElem": "Recorded",
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
        # Reference-aware confirm (mirrors the main delete): warn before
        # orphaning live instances; Cancel aborts (no dialog when nothing
        # would orphan).
        if not _confirm_panel_delete_if_orphans(m, panel_selection, widget):
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
            # Delete panel-selected elements. Route through the already-journaled
            # _do_delete() helper (same path as the context-menu Delete) so the
            # gesture records a delete_at op per element through op_apply and
            # names a single undo step, matching Rust/Swift. _do_delete applies
            # the same last-layer guard and reference-aware orphan confirm.
            _do_delete()
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
                    m.edit_document(new_doc)
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
                    new_doc = d
                    for sp, sv in saved.items():
                        e = new_doc.get_element(sp)
                        if e is not None:
                            new_doc = new_doc.replace_element(sp, dc_replace(e, visibility=sv))
                    m.edit_document(new_doc)
                    solo_state[0] = None
                else:
                    saved = {}
                    for sp in siblings:
                        if sp != p:
                            e = d.get_element(sp)
                            if e is not None:
                                saved[sp] = e.visibility
                    new_doc = d
                    e0 = new_doc.get_element(p)
                    if e0 is not None and e0.visibility == Visibility.INVISIBLE:
                        new_doc = new_doc.replace_element(p, dc_replace(e0, visibility=Visibility.PREVIEW))
                    for sp in siblings:
                        if sp != p:
                            e = new_doc.get_element(sp)
                            if e is not None:
                                new_doc = new_doc.replace_element(sp, dc_replace(e, visibility=Visibility.INVISIBLE))
                    m.edit_document(new_doc)
                    solo_state[0] = (p, saved)
            else:
                solo_state[0] = None
                d = m.document
                e = d.get_element(p)
                if e is None:
                    return
                new_vis = _cycle_visibility(getattr(e, 'visibility', Visibility.PREVIEW))
                new_e = dc_replace(e, visibility=new_vis)
                new_doc = d.replace_element(p, new_e)
                if new_vis == Visibility.INVISIBLE:
                    new_doc = dc_replace(new_doc, selection=frozenset(
                        es for es in new_doc.selection if not (es.path == p or es.path[:len(p)] == p)
                    ))
                m.edit_document(new_doc)
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
            m.edit_document(new_doc)
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
                        # Undoable edit (one self-bracketed undo step).
                        m.edit_document(d.replace_element(p, new_e))
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
            # Selection-only: non-undoable (OP_LOG.md §7/§8).
            m.set_document_unbracketed(dc_replace(d, selection=new_sel))
            _rebuild()
        sq.mousePressEvent = _on_select
        row_layout.addWidget(sq)

        parent_layout.addWidget(row)

    for r in rows:
        _add_row(layout, *r)

    layout.addStretch()
    # Test accessors (no production effect): expose the closure-local panel
    # selection set and the keyboard handler so production-route tests can
    # drive the real in-panel keyboard Delete path (_on_key -> _do_delete ->
    # op_apply) without re-implementing it.
    widget._jas_panel_selection = panel_selection
    widget._jas_on_key = _on_key
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
        def _on_click(evt):
            if not click_enabled:
                return
            model = get_model() if callable(get_model) else None
            if model is None:
                return
            from document.model import EditingTarget
            from document.controller import Controller
            # MASK_PREVIEW supports modifier-clicks per OPACITY.md
            # §Preview interactions. Query the QMouseEvent's
            # modifiers at click time.
            mods = evt.modifiers()
            shift = bool(mods & Qt.KeyboardModifier.ShiftModifier)
            alt = bool(mods & Qt.KeyboardModifier.AltModifier)
            if is_mask_preview and shift:
                # Shift-click: toggle mask.disabled on every
                # selected mask via Controller.
                Controller(model=model).toggle_mask_disabled_on_selection()
            elif is_mask_preview and alt:
                # Alt-click: toggle mask isolation on the first
                # selected element's mask.
                if model.mask_isolation_path is not None:
                    model.mask_isolation_path = None
                else:
                    first = next(iter(sorted(
                        (es.path for es in model.document.selection),
                        key=lambda p: p,
                    )), None)
                    if first is not None:
                        model.mask_isolation_path = first
            elif is_mask_preview:
                # Plain click: enter mask-editing mode.
                first = next(iter(sorted(
                    (es.path for es in model.document.selection),
                    key=lambda p: p,
                )), None)
                if first is None:
                    return
                model.editing_target = EditingTarget.mask(first)
            else:
                # op_preview click: exit mask-editing mode.
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


def _style_px(val) -> int | None:
    """Coerce a style size value to an int pixel count, or None.

    Returns None for values that can't be a fixed pixel size — most
    importantly unresolved ``{{theme.sizes.X}}`` template strings, which
    appear on the bundle toolbar's icon_buttons because the panel
    renderer doesn't thread the theme into the eval context. Returning
    None lets _apply_style skip the setFixed* call (the widget keeps its
    natural / renderer-set size) instead of raising on int("{{...}}").
    """
    if isinstance(val, bool):
        return None
    if isinstance(val, (int, float)):
        return int(val)
    if isinstance(val, str):
        try:
            return int(float(val))
        except ValueError:
            return None
    return None


def _apply_style(widget: QWidget, style: dict, store: StateStore, ctx: dict):
    """Apply style properties to a widget via setStyleSheet."""
    if not style:
        return

    parts = []
    eval_ctx = store.eval_context(ctx)

    for key, val in style.items():
        if key in ("gap", "padding", "alignment", "justify"):
            continue  # handled by layout
        if isinstance(val, dict):
            # Nested style sub-maps (e.g. an icon_button's
            # ``hover: { background: ... }``) describe pseudo-state
            # styling that the flat setStyleSheet pass below can't
            # express. The tool-grid icon_buttons consume their own
            # hover / checked_bg in _render_icon_button; skip the dict
            # here so it doesn't stringify into invalid CSS.
            continue
        if key == "checked_bg":
            # Button-checked highlight color. Consumed by
            # _render_icon_button (toolbar tool buttons); not a Qt CSS
            # property, so skip it here to avoid "Unknown property".
            continue
        if key == "flex":
            # flex: N means "stretch in the parent layout". Map to a
            # horizontally-expanding size policy so spacers / footer
            # gap widgets actually push neighbours apart. Qt CSS has
            # no [flex] property; without this branch the value
            # leaked into setStyleSheet and Qt logged "Unknown
            # property flex" for every styled child.
            from PySide6.QtWidgets import QSizePolicy
            widget.setSizePolicy(QSizePolicy.Expanding,
                                 widget.sizePolicy().verticalPolicy())
            continue
        if key == "size":
            sz = _style_px(val)
            if sz is not None:
                widget.setFixedSize(sz, sz)
            continue
        if key == "width":
            if isinstance(val, str) and val.endswith("%"):
                from PySide6.QtWidgets import QSizePolicy
                widget.setSizePolicy(QSizePolicy.Expanding,
                                     widget.sizePolicy().verticalPolicy())
            else:
                px = _style_px(val)
                if px is not None:
                    widget.setFixedWidth(px)
            continue
        if key == "height":
            if isinstance(val, str) and val.endswith("%"):
                from PySide6.QtWidgets import QSizePolicy
                widget.setSizePolicy(widget.sizePolicy().horizontalPolicy(),
                                     QSizePolicy.Expanding)
            else:
                px = _style_px(val)
                if px is not None:
                    widget.setFixedHeight(px)
            continue
        if key == "min_width":
            widget.setMinimumWidth(int(val))
            continue
        if key == "min_height":
            widget.setMinimumHeight(int(val))
            continue
        if key in ("overflow", "text_overflow", "white_space"):
            # HTML/CSS text-truncation properties Qt doesn't support.
            # Truncation in Qt is done via QFontMetrics.elidedText on
            # the widget itself, not via stylesheet. Silently skip.
            continue
        if key in ("flex_shrink", "flex_grow", "flex_basis", "aspect_ratio"):
            # Flex-box / aspect-ratio CSS properties Qt's stylesheet
            # engine doesn't understand. ``flex`` is already special-
            # cased above; flex_shrink / flex_grow / flex_basis came
            # along on the same widgets (swatches.yaml, layer_options
            # dialog) and were leaking into setStyleSheet, producing
            # "Unknown property flex-shrink" log spam. Silently skip.
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


def _apply_bindings(widget: QWidget, el: dict, store: StateStore, ctx: dict):
    """Apply reactive bindings to a widget.

    Sets initial values and subscribes to state changes. Reads
    [el.bind] for the binding map, plus [el.behavior] for the
    selected_in path (which needs the click select.target to
    determine per-item identity).
    """
    bindings = el.get("bind") or {}
    # Some YAML widgets use the bare-string `bind:` form (e.g.
    # toggles, text_input fields bound to a single value). Wrap
    # those so _apply_bindings can iterate uniformly — without
    # this, .items() on a bare string raises AttributeError.
    if isinstance(bindings, str):
        bindings = {"value": bindings}
    if not bindings:
        return

    selected_target_expr = _selected_in_target_expr(el)

    def _is_selected_in(eval_ctx) -> bool:
        list_expr = bindings.get("selected_in")
        if not isinstance(list_expr, str) or not list_expr or not selected_target_expr:
            return False
        list_result = evaluate(list_expr, eval_ctx)
        items = list_result.value if isinstance(list_result.value, list) else None
        if items is None:
            return False
        id_result = evaluate(selected_target_expr, eval_ctx)
        target = id_result.value
        return any(_selected_in_loose_eq(it, target) for it in items)

    def _color_stylesheet(color, selected: bool) -> str:
        if selected:
            border = "border: 2px solid #4a90d9"
        else:
            border = "border: 1px solid #666"
        # Accept both "#rrggbb" and bare "rrggbb" — model.recent_colors
        # stores values from Color.to_hex() which is hash-less, while
        # state.fill_color uses the hash-prefixed form.
        if isinstance(color, str) and color:
            s = color if color.startswith("#") else "#" + color
            if len(s) in (4, 7):
                return f"background: {s}; {border}"
        return f"background: transparent; {border.replace('solid', 'dashed').replace('#666', '#555')}"

    eval_ctx = store.eval_context(ctx)

    for prop, expr in bindings.items():
        if not isinstance(expr, str):
            continue

        if prop == "selected_in":
            continue  # handled jointly with color below

        result = evaluate(expr, eval_ctx)

        if prop == "visible":
            widget.setVisible(result.to_bool())
        elif prop == "disabled":
            widget.setEnabled(not result.to_bool())
        elif prop == "value":
            _set_widget_value(widget, result.value)
        elif prop == "color":
            selected = _is_selected_in(eval_ctx)
            widget.setStyleSheet(
                widget.styleSheet() + "; " + _color_stylesheet(result.value, selected))
        elif prop == "checked":
            if hasattr(widget, "setChecked"):
                widget.setChecked(result.to_bool())

    # Subscribe to state changes for reactive updates. Strip the
    # baked-in scope keys from ctx — eval_context.update(extra)
    # would otherwise re-substitute the dialog/state snapshot
    # captured at render time, snapping widgets back to their
    # initial values whenever dialog state changes.
    extra_ctx = {k: v for k, v in ctx.items()
                 if k not in ("state", "panel", "dialog", "param", "tool")}

    # The widget belongs to a specific panel; capture that id so the
    # binding always evaluates against that panel's state regardless
    # of which panel is currently active. Without this, opening a
    # second panel (which calls set_active_panel) would silently
    # break disabled / visible / value bindings on every other
    # panel's widgets — eval_context would return the wrong panel's
    # state and bindings like ``not panel.text_selected`` would
    # evaluate against ``None``, leaving widgets stuck disabled.
    widget_panel_id = ctx.get("_panel_id")

    def _update_bindings(key, value):
        try:
            from shiboken6 import isValid
            if not isValid(widget):
                return
        except Exception:
            pass
        new_ctx = store.eval_context(extra_ctx)
        if widget_panel_id:
            new_ctx["panel"] = store.get_panel_state(widget_panel_id)
        for prop, expr in bindings.items():
            if not isinstance(expr, str):
                continue
            if prop == "selected_in":
                continue
            r = evaluate(expr, new_ctx)
            if prop == "visible":
                widget.setVisible(r.to_bool())
            elif prop == "disabled":
                widget.setEnabled(not r.to_bool())
            elif prop == "value":
                _set_widget_value(widget, r.value)
            elif prop == "checked":
                # Reactive checked highlight — the bundle toolbar's tool
                # buttons re-evaluate ``state.active_tool == "..."`` /
                # ``mem(state.active_tool, [...])`` here when active_tool
                # changes, so the active tool's button stays lit. Without
                # this the initial-only setChecked in the renderer never
                # tracks later tool switches.
                if hasattr(widget, "setChecked"):
                    widget.setChecked(r.to_bool())
            elif prop == "color":
                selected = _is_selected_in(new_ctx)
                widget.setStyleSheet(_color_stylesheet(r.value, selected))

        # Re-resolve the icon glyph when state changes. The multi-tool
        # toolbar slots resolve their glyph through alternates-by-
        # active_tool (not through `bind`), so the loop above never
        # touches the icon; this closure (stashed by _render_icon_button)
        # re-runs the bind.icon -> alternates -> static resolution so the
        # slot's GLYPH follows the live tool, matching the checked
        # highlight that the loop already keeps in sync.
        refresh_icon = getattr(widget, "_jas_refresh_icon", None)
        if callable(refresh_icon):
            refresh_icon(new_ctx)

    store.subscribe(None, _update_bindings)

    # Panel-state changes don't go through the global subscribe above
    # (set_panel only fires panel subscribers). When any binding
    # references panel.* — color, selected_in, visible, disabled,
    # checked, value — also subscribe to the active panel's state so
    # those bindings re-evaluate when panel state changes (e.g.
    # panel.recent_colors getting a new entry, or
    # panel.selected_swatches toggling).
    has_panel_binding = any(
        isinstance(e, str) and "panel." in e
        for e in bindings.values()
    )
    if has_panel_binding:
        # Subscribe to the panel this widget BELONGS to (captured
        # from ctx._panel_id), not the store's current active panel
        # — those can diverge during multi-panel render (the
        # active panel id is global and reflects whichever panel
        # most recently called set_active_panel). Without this,
        # cp_sliders_grayscale's `visible: panel.mode == "grayscale"`
        # binding subscribes to an unrelated panel and never fires
        # when the Color panel's mode changes (CLR-022 Python).
        panel_id = widget_panel_id or store.get_active_panel_id()
        if panel_id:
            store.subscribe_panel(panel_id, _update_bindings)


def _set_widget_value(widget: QWidget, value):
    """Set the value of a widget based on its type.

    Block signals during setValue so propagating bindings (e.g. a
    hidden Web Safe RGB slider tracking panel.r changes) don't
    fire their own valueChanged handlers and write back snapped
    values that fight the user's input in the visible mode's
    sibling slider (CLR-060 Python — RGB drag snapped to 51 after
    Web Safe use because the hidden web_safe slider snapped panel
    .r back on every echo).
    """
    if isinstance(widget, QSlider):
        try:
            widget.blockSignals(True)
            widget.setValue(int(float(value)) if value is not None else 0)
        except (TypeError, ValueError):
            pass
        finally:
            widget.blockSignals(False)
    elif isinstance(widget, QSpinBox):
        try:
            widget.blockSignals(True)
            widget.setValue(int(float(value)) if value is not None else 0)
        except (TypeError, ValueError):
            pass
        finally:
            widget.blockSignals(False)
    elif isinstance(widget, QLineEdit):
        # length_input stashes unit / precision so the displayed text
        # routes through Length.format instead of plain str().
        unit = getattr(widget, "_jas_length_unit", None)
        if unit is not None:
            from workspace_interpreter.length import format_length
            precision = getattr(widget, "_jas_length_precision", 2)
            widget.setText(format_length(
                value if isinstance(value, (int, float)) else None,
                unit, precision))
        else:
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
        elif event == "mouse_down":
            _wire_mouse_down(widget, effects, store, ctx)
        elif event == "mouse_up":
            _wire_mouse_up(widget, effects, store, ctx)


def _run_behavior_effects(effects, eval_ctx, store, ctx, anchor=None):
    """Run a behavior's effect list.

    Prefers a host-supplied runner under ``ctx["_run_behavior_effects"]``
    when present — the dock supplies one that registers the
    ``start_timer`` / ``cancel_timer`` platform effects and, after the
    batch (and after each timer fires), calls ``_check_dialog_opened`` so
    a long-press ``open_dialog`` actually SHOWS the Qt flyout. The plain
    ``run_effects`` path can only SET ``store._dialog_id`` — it pops no
    window — so without the host runner the toolbar's long-press
    alternates never appear (mirrors the Rust renderer's timer_ctx +
    dialog_signal wiring). When no runner is supplied (ordinary panel
    buttons), this falls back to plain ``run_effects`` so their behavior
    is byte-unchanged.

    ``anchor`` is the global-screen ``(x, y)`` captured at the slot
    button's mouse_down (see ``_wire_mouse_down``). It is threaded into
    the host runner so a non-modal flyout (tool-alternates) can be placed
    NEXT TO the cursor instead of centered — mirrors Rust threading the
    mouse_down page coords through the long-press timer into
    ``DialogState.anchor`` (renderer.rs build_mousedown_handler ->
    start_timer -> open_dialog_at). The runner accepts ``anchor`` as a
    keyword arg; we pass it only when set so the call stays compatible
    with runners that don't take it.
    """
    runner = ctx.get("_run_behavior_effects") if isinstance(ctx, dict) else None
    if callable(runner):
        if anchor is not None:
            runner(effects, eval_ctx, anchor=anchor)
        else:
            runner(effects, eval_ctx)
        return
    from workspace_interpreter.effects import run_effects
    run_effects(effects, eval_ctx, store)


def _behavior_eval_ctx(store, ctx):
    """Build the effect eval-context for a behavior, stripping the
    scope namespaces from the wire-time ctx (mirrors _wire_click's
    _build_eval_ctx) so a stale dialog / panel snapshot can't shadow
    the live store. Re-exposes the widget's own panel scope under
    ``panel`` when ``_panel_id`` is known."""
    widget_pid = ctx.get("_panel_id") if isinstance(ctx, dict) else None
    extra = {k: v for k, v in ctx.items()
             if k not in ("state", "panel", "dialog", "param", "tool",
                          "active_document",
                          "_run_behavior_effects")} if isinstance(ctx, dict) else {}
    ec = store.eval_context(extra)
    if widget_pid:
        ec["panel"] = store.get_panel_state(widget_pid)
    return ec


def _wire_mouse_down(widget, effects, store, ctx):
    """Wire a ``mouse_down`` behavior to the button's press.

    Used by the bundle toolbar's multi-tool slots: mouse_down carries
    ``start_timer`` (with a nested ``open_dialog <slot>_alternates``)
    so a long press opens the tool-alternates flyout. ``QPushButton``
    fires ``pressed`` on mouse-down; a quick click then fires
    ``released`` (cancel_timer) well within the delay, so no stray
    timer is left and the flyout does not appear. Only attaches when
    the element declares a ``mouse_down`` behavior, so ordinary panel
    buttons (which declare none) are unaffected. Mirrors the Rust
    build_mousedown_handler."""
    if not effects or not hasattr(widget, "pressed"):
        return

    def _on_pressed():
        # Capture the cursor's GLOBAL screen position at press time, the
        # Qt analogue of the Rust mouse-event page coordinates read in
        # build_mousedown_handler (renderer.rs evt.data().page_coordinates()).
        # QPushButton.pressed carries no QMouseEvent, so QCursor.pos() is
        # the natural source; it is the position to place a non-modal
        # long-press flyout NEXT TO the cursor. Threaded through the
        # behavior runner -> long-press timer -> dialog show, mirroring
        # Rust's anchor plumbing. The anchor is harmless for ordinary
        # (modal / non-flyout) effects, which ignore it.
        from PySide6.QtGui import QCursor
        pt = QCursor.pos()
        anchor = (pt.x(), pt.y())
        _run_behavior_effects(effects, _behavior_eval_ctx(store, ctx), store,
                              ctx, anchor=anchor)

    widget.pressed.connect(_on_pressed)


def _wire_mouse_up(widget, effects, store, ctx):
    """Wire a ``mouse_up`` behavior to the button's release.

    Carries ``cancel_timer`` for the slot long-press; ``QPushButton``
    fires ``released`` on mouse-up (whether or not the cursor is still
    over the button), so a quick click cancels the pending long-press
    timer before it can open the flyout. Mirrors the Rust
    build_mouseup_handler."""
    if not effects or not hasattr(widget, "released"):
        return

    def _on_released():
        _run_behavior_effects(effects, _behavior_eval_ctx(store, ctx), store, ctx)

    widget.released.connect(_on_released)


def _resolve_param_value(v, eval_ctx):
    """Resolve a behavior ``params`` value against the eval context.

    String values are expressions. A bare identifier that evaluates to
    null (no state binding) is treated as a literal string, so YAML
    ``params: { tool: selection }`` passes the string ``"selection"``
    rather than null — this is how the tool-grid select_tool buttons
    encode their target. Mirrors the Rust renderer's bare-identifier
    fallback (jas_dioxus build_mouse_event_handler). Non-string values
    pass through unchanged.
    """
    if not isinstance(v, str):
        return v
    result = evaluate(v, eval_ctx)
    value = getattr(result, "value", result)
    if value is None and v and all(c.isalnum() or c == "_" for c in v):
        return v
    return value


def _wire_click(widget, action, params, condition, effects, store, ctx, dispatch_fn):
    if not hasattr(widget, "clicked"):
        return
    # Capture the widget's panel id at wire time so condition /
    # param evaluation uses THIS widget's panel state, not the
    # global active panel (which can drift between widget renders
    # and clicks). Without this, the recent-swatch condition
    # `panel.recent_colors.0 != null` evaluates against an
    # unrelated panel's empty state and the click silently no-ops.
    widget_pid = ctx.get("_panel_id")

    def _build_eval_ctx():
        # Strip the scope namespaces from ctx so they don't shadow
        # the freshly-evaluated values from store.eval_context.
        # ctx was captured at wire time (which for dialogs is at
        # render time, before any user edits) and contains a stale
        # "dialog" snapshot — eval_context.update(extra) would
        # otherwise overwrite the live dialog state with the
        # initial one and OK reads the original color
        # (CLR-218 Python).
        extra = {k: v for k, v in ctx.items()
                 if k not in ("state", "panel", "dialog", "param", "tool", "active_document")}
        ec = store.eval_context(extra)
        if widget_pid:
            ec["panel"] = store.get_panel_state(widget_pid)
        return ec

    def on_click():
        if condition:
            eval_ctx = _build_eval_ctx()
            cond_result = evaluate(condition, eval_ctx)
            if not cond_result.to_bool():
                return
        if action:
            resolved_params = {}
            eval_ctx = _build_eval_ctx()
            for k, v in params.items():
                resolved_params[k] = _resolve_param_value(v, eval_ctx)
            if dispatch_fn:
                dispatch_fn(action, resolved_params)
        if effects:
            from workspace_interpreter.effects import run_effects
            ec_for_effects = _build_eval_ctx()
            # Picker OK: capture the dialog's color + target so we
            # can apply directly to the model. The effects.set
            # fill_color short-circuits when state.fill_color is
            # already at that value (from the live-preview bridge
            # updates during drag), which means subscribe_active_color
            # doesn't fire and the model isn't refreshed.
            picker_color = None
            picker_target = None
            try:
                if store.get_dialog_id() == "color_picker":
                    dlg = ec_for_effects.get("dialog") or {}
                    raw = dlg.get("color")
                    if isinstance(raw, str) and raw:
                        picker_color = raw
                    p = ec_for_effects.get("param") or {}
                    picker_target = p.get("target")
            except Exception:
                pass
            run_effects(effects, ec_for_effects, store)
            if picker_color:
                try:
                    from geometry.element import Color
                    from panels.panel_menu import set_active_color
                    col = Color.from_hex(picker_color)
                    m = None
                    try:
                        from PySide6.QtWidgets import QApplication
                        for w in QApplication.topLevelWidgets():
                            am = getattr(w, "active_model", None)
                            if callable(am):
                                m = am()
                                if m is not None:
                                    break
                    except Exception:
                        pass
                    if m is not None and col is not None:
                        if picker_target == "fill":
                            m.fill_on_top = True
                        elif picker_target == "stroke":
                            m.fill_on_top = False
                        set_active_color(col, m)
                except Exception:
                    pass

    widget.clicked.connect(lambda _=None: on_click())


def _wire_change(widget, action, params, condition, effects, store, ctx, dispatch_fn):
    """Wire value change events (sliders, inputs).

    The committed value is injected as ``event.value`` so effects and action
    params that read it resolve. ``action`` params are evaluated against the
    per-widget eval context (like ``_wire_click``) with ``event.value``
    available — so a Concepts-panel foreach ``p.name`` resolves to the row's
    parameter name and ``value: "event.value"`` to the committed number. A
    QSpinBox commits once on ``editingFinished`` (Enter / focus loss / arrow),
    matching the panel/dialog writeback path and avoiding a dispatch on every
    programmatic binding refresh (which would loop edit → rebuild → refresh);
    sliders fire live on drag."""
    widget_pid = ctx.get("_panel_id")

    def _action_ctx(value):
        # Strip scope namespaces from the wire-time ctx so they don't shadow
        # freshly-evaluated store state (mirrors _wire_click), then expose the
        # committed value under event.value.
        extra = {k: v for k, v in ctx.items()
                 if k not in ("state", "panel", "dialog", "param", "tool", "active_document")}
        ec = store.eval_context(extra)
        if widget_pid:
            ec["panel"] = store.get_panel_state(widget_pid)
        ec["event"] = {"value": value}
        return ec

    def on_change(value):
        if effects:
            from workspace_interpreter.effects import run_effects
            change_ctx = dict(ctx)
            change_ctx["event"] = {"value": value}
            run_effects(effects, change_ctx, store)
        if action and dispatch_fn:
            ec = _action_ctx(value)
            resolved_params = {k: evaluate(str(v), ec).value for k, v in params.items()}
            dispatch_fn(action, resolved_params)

    if isinstance(widget, QSlider):
        widget.valueChanged.connect(on_change)
    elif isinstance(widget, QSpinBox):
        def _on_spin_finished():
            widget.interpretText()
            on_change(widget.value())
        widget.editingFinished.connect(_on_spin_finished)
    elif isinstance(widget, QLineEdit):
        widget.textChanged.connect(on_change)


# ── Type dispatch table ──────────────────────────────────────

def _render_tabs(el, store, ctx, dispatch_fn):
    """PRINT.md §1B: tabs widget. Left rail of clickable labels +
    content area showing the active tab. Active tab read from
    bind.value (typically dialog.<field>); falls back to the first
    tab when no bind or empty value. Click writes back the tab id
    via dispatch_fn (no-op for non-panel binds today, same as the
    Swift / OCaml renderers — full dialog-write hookup is a separate
    framework piece)."""
    from PySide6.QtWidgets import QPushButton
    tabs = el.get("tabs") or []
    bind = el.get("bind") or {}
    value_expr = bind.get("value")
    first_id = tabs[0].get("id", "") if tabs else ""
    active_id = first_id
    if isinstance(value_expr, str) and value_expr:
        from workspace_interpreter.expr import evaluate
        result = evaluate(value_expr, ctx)
        v = getattr(result, "value", None)
        if isinstance(v, str) and v:
            active_id = v

    widget = QWidget()
    outer = QHBoxLayout(widget)
    outer.setContentsMargins(0, 0, 0, 0)
    outer.setSpacing(0)

    # Left rail.
    rail = QWidget()
    rail.setFixedWidth(140)
    rail_layout = QVBoxLayout(rail)
    rail_layout.setContentsMargins(0, 4, 0, 4)
    rail_layout.setSpacing(0)
    rail_buttons = []
    for tab in tabs:
        tab_id = tab.get("id", "")
        label = tab.get("label", "")
        btn = QPushButton(label)
        btn.setFlat(True)
        rail_layout.addWidget(btn)
        rail_buttons.append((tab_id, btn))
    rail_layout.addStretch(1)
    outer.addWidget(rail)

    # Content area — held in a container we can clear + re-fill on
    # tab switch. Active-tab visual state lives on the rail buttons,
    # restyled on each switch so the user sees which tab is current.
    content_widget = QWidget()
    content_layout = QVBoxLayout(content_widget)
    content_layout.setContentsMargins(12, 12, 12, 12)
    state_holder = {"active": active_id}

    def _restyle_rail():
        for tid, b in rail_buttons:
            b.setText(("▸ " if tid == state_holder["active"] else "   ") + b.text().lstrip("▸ "))
            b.setStyleSheet(
                "text-align: left; padding: 4px 12px; "
                + ("font-weight: 600;" if tid == state_holder["active"] else ""))

    def _populate_content():
        # Clear previous content, then render the now-active tab.
        while content_layout.count():
            item = content_layout.takeAt(0)
            w = item.widget()
            if w is not None:
                w.setParent(None)
        active_tab = next(
            (t for t in tabs if t.get("id") == state_holder["active"]), None)
        if active_tab is not None:
            content = active_tab.get("content")
            if isinstance(content, dict):
                child = render_element(content, store, ctx, dispatch_fn)
                if child:
                    content_layout.addWidget(child)
        content_layout.addStretch(1)

    def _switch_to(target_id: str):
        if target_id == state_holder["active"]:
            return
        state_holder["active"] = target_id
        # Persist into dialog state so OK / Done / Print see the tab
        # the user actually left on (and so init expressions on
        # reopen restore the same tab).
        if isinstance(value_expr, str) and value_expr.startswith("dialog."):
            field = value_expr[len("dialog."):]
            store.set_dialog(field, target_id)
        _restyle_rail()
        _populate_content()

    for tab_id, btn in rail_buttons:
        btn.clicked.connect(lambda _checked=False, tid=tab_id: _switch_to(tid))

    _restyle_rail()
    _populate_content()
    outer.addWidget(content_widget, 1)

    return widget


_RENDERERS = {
    "container": _render_container,
    "row": lambda el, s, c, d: _render_container({**el, "layout": "row"}, s, c, d),
    "col": lambda el, s, c, d: _render_container({**el, "layout": "column"}, s, c, d),
    "grid": _render_grid,
    "text": _render_text,
    "button": _render_button,
    "icon": _render_icon,
    "icon_button": _render_icon_button,
    "icon_select": _render_icon_select,
    "slider": _render_slider,
    "number_input": _render_number_input,
    "text_input": _render_text_input,
    "length_input": _render_length_input,
    "toggle": _render_toggle,
    "checkbox": _render_checkbox,
    "select": _render_select,
    "combo_box": _render_combo_box,
    "color_swatch": _render_color_swatch,
    "color_gradient": _render_color_gradient,
    "color_hue_bar": _render_color_hue_bar,
    "radio_group": _render_radio_group,
    "gradient_tile": _render_gradient_tile,
    "gradient_slider": _render_gradient_slider,
    "separator": _render_separator,
    "spacer": _render_spacer,
    "disclosure": _render_disclosure,
    "panel": _render_panel,
    "fill_stroke_widget": lambda el, s, c, d: _render_fill_stroke_widget(el, s, c, d),
    "tree_view": _render_tree_view,
    "element_preview": _render_element_preview,
    "dropdown": _render_dropdown,
    "tabs": _render_tabs,
    "placeholder": _render_placeholder,
}
