"""Element tree to HTML renderer for normal and wireframe modes."""

import json
from markupsafe import Markup, escape

from loader import resolve_interpolation

# Module-level icon registry, set via set_icons() before rendering.
_icons: dict = {}


def set_icons(icons: dict) -> None:
    """Set the icon definitions for the renderer."""
    global _icons
    _icons = icons or {}


def render_element(el: dict, theme: dict, state: dict, mode: str = "normal") -> str:
    """Recursively render an element to HTML."""
    if not isinstance(el, dict):
        return ""
    if mode == "wireframe":
        return _render_wireframe(el, theme, state, depth=0)
    etype = el.get("type", "placeholder")
    renderer = _RENDERERS.get(etype, _render_unknown)
    return renderer(el, theme, state)


def render_menubar(menubar: list, actions: dict, theme: dict) -> str:
    """Render the menubar as a Bootstrap navbar with dropdown menus."""
    items_html = ""
    for menu in menubar:
        label = menu.get("label", "").replace("&", "")
        menu_id = menu.get("id", "menu")
        dropdown_items = _render_menu_items(menu.get("items", []), actions)
        items_html += (
            f'<li class="nav-item dropdown">'
            f'<a class="nav-link dropdown-toggle" href="#" role="button" '
            f'data-bs-toggle="dropdown" id="{menu_id}">{escape(label)}</a>'
            f'<ul class="dropdown-menu">{dropdown_items}</ul>'
            f'</li>'
        )
    return Markup(
        f'<nav class="navbar navbar-expand navbar-dark" style="background:#333;padding:0 8px;">'
        f'<ul class="navbar-nav">{items_html}</ul>'
        f'<div class="ms-auto">'
        f'<a class="nav-link text-light small" href="?mode=wireframe" id="mode-toggle">Wireframe</a>'
        f'</div>'
        f'</nav>'
    )


def render_dialogs(dialogs: dict, theme: dict, state: dict) -> str:
    """Render all dialogs as hidden Bootstrap modals."""
    html = ""
    for dialog_id, dialog in (dialogs or {}).items():
        summary = escape(dialog.get("summary", dialog_id))
        body_html = render_element(dialog.get("content", {}), theme, state, mode="normal")
        html += (
            f'<div class="modal fade" id="dialog-{dialog_id}" tabindex="-1">'
            f'<div class="modal-dialog"><div class="modal-content">'
            f'<div class="modal-header"><h5 class="modal-title">{summary}</h5>'
            f'<button type="button" class="btn-close" data-bs-dismiss="modal"></button></div>'
            f'<div class="modal-body">{body_html}</div>'
            f'</div></div></div>'
        )
    return Markup(html)


# ── Normal mode renderers ─────────────────────────────────────


def _render_children(el: dict, theme: dict, state: dict) -> str:
    html = ""
    for child in el.get("children", []):
        html += render_element(child, theme, state, mode="normal")
    content = el.get("content")
    if isinstance(content, dict):
        html += render_element(content, theme, state, mode="normal")
    return html


def _style_str(el: dict, theme: dict, state: dict, extra: str = "") -> str:
    """Build a CSS style string from element style properties."""
    style = el.get("style", {})
    if not style and not extra:
        return ""
    parts = []
    if extra:
        parts.append(extra)
    for key, val in style.items():
        if key == "background":
            parts.append(f"background:{_resolve(val, theme, state)}")
        elif key == "color":
            parts.append(f"color:{_resolve(val, theme, state)}")
        elif key == "border":
            parts.append(f"border:{_resolve(val, theme, state)}")
        elif key == "border_radius":
            parts.append(f"border-radius:{val}px")
        elif key == "padding":
            parts.append(f"padding:{_pad(val)}")
        elif key == "margin":
            parts.append(f"margin:{_pad(val)}")
        elif key == "gap":
            parts.append(f"gap:{val}px")
        elif key == "width" and val != "auto":
            parts.append(f"width:{_px(val)}")
        elif key == "height" and val != "auto":
            parts.append(f"height:{_px(val)}")
        elif key == "min_width":
            parts.append(f"min-width:{_px(val)}")
        elif key == "min_height":
            parts.append(f"min-height:{_px(val)}")
        elif key == "max_width":
            parts.append(f"max-width:{_px(val)}")
        elif key == "max_height":
            parts.append(f"max-height:{_px(val)}")
        elif key == "flex":
            parts.append(f"flex:{val}")
        elif key == "opacity":
            parts.append(f"opacity:{val}")
        elif key == "overflow":
            parts.append(f"overflow:{val}")
        elif key == "z_index":
            parts.append(f"z-index:{val}")
        elif key == "size":
            sz = _resolve(val, theme, state)
            parts.append(f"width:{sz}px;height:{sz}px")
        elif key == "alignment":
            parts.append(f"align-items:{_align(val)}")
        elif key == "justify":
            parts.append(f"justify-content:{_justify(val)}")
    return f' style="{";".join(parts)}"' if parts else ""


def _resolve(val, theme, state):
    if isinstance(val, str) and "{{" in val:
        return resolve_interpolation(val, theme, state)
    return str(val)


def _px(val):
    if isinstance(val, (int, float)):
        return f"{val}px"
    return str(val)


def _pad(val):
    if isinstance(val, (int, float)):
        return f"{val}px"
    if isinstance(val, str):
        parts = val.split()
        return " ".join(f"{p}px" if p.isdigit() else p for p in parts)
    return str(val)


def _align(val):
    return {"start": "flex-start", "end": "flex-end", "center": "center", "stretch": "stretch"}.get(val, val)


def _justify(val):
    return {"start": "flex-start", "end": "flex-end", "center": "center",
            "between": "space-between", "around": "space-around"}.get(val, val)


def _data_attrs(el: dict) -> str:
    """Build data-action, data-action-params, data-behaviors, and data-bind-* attributes."""
    parts = []
    behaviors = el.get("behavior", [])

    # Find the first click action for data-action (simple dispatch)
    click_action = None
    if not behaviors:
        click_action = el.get("action")
        click_params = el.get("params")
    else:
        for b in behaviors:
            if b.get("event") == "click" and b.get("action"):
                click_action = b["action"]
                click_params = b.get("params")
                break
        else:
            click_params = None

    if click_action:
        parts.append(f'data-action="{escape(click_action)}"')
        if click_params:
            parts.append(f"data-action-params='{escape(json.dumps(click_params))}'")

    # Emit non-click behaviors as data-behaviors JSON for the JS engine
    non_click = [b for b in behaviors if b.get("event") != "click"]
    if non_click:
        parts.append(f"data-behaviors='{escape(json.dumps(non_click))}'")

    # Emit bind attributes
    bind = el.get("bind", {})
    for prop, expr in bind.items():
        parts.append(f'data-bind-{prop}="{escape(str(expr))}"')

    if not parts:
        return ""
    return " " + " ".join(parts)


def _id_attr(el: dict) -> str:
    eid = el.get("id")
    return f' id="{escape(eid)}"' if eid else ""


# ── Individual element renderers ──────────────────────────────


def _render_pane_system(el, theme, state):
    children = _render_children(el, theme, state)
    return Markup(
        f'<div{_id_attr(el)} class="jas-pane-system"'
        f' style="position:relative;width:100%;height:100vh;overflow:hidden;'
        f'background:{_resolve(el.get("style", {}).get("background", "#2e2e2e"), theme, state)}">'
        f'{children}</div>'
    )


def _render_pane(el, theme, state):
    pos = el.get("default_position", {})
    x, y = pos.get("x", 0), pos.get("y", 0)
    w, h = pos.get("width", 200), pos.get("height", 400)
    title_bar = el.get("title_bar", {})
    label = escape(title_bar.get("label", ""))
    closeable = title_bar.get("closeable", False)

    close_btn = ""
    if closeable:
        eid = el.get("id", "")
        close_btn = (
            f'<button class="btn-close btn-close-white btn-sm ms-auto"'
            f' style="font-size:8px"'
            f' data-action="toggle_pane" data-action-params=\'{{"pane":"{eid}"}}\'>'
            f'</button>'
        )

    extra_btns = ""
    for btn in title_bar.get("buttons", []):
        extra_btns += render_element(btn, theme, state, mode="normal")

    content_html = ""
    content = el.get("content")
    if isinstance(content, dict):
        content_html = render_element(content, theme, state, mode="normal")

    bg = _resolve(el.get("style", {}).get("background", "#3c3c3c"), theme, state)
    border = _resolve(el.get("style", {}).get("border", "1px solid #555"), theme, state)

    return Markup(
        f'<div{_id_attr(el)} class="jas-pane"'
        f' style="position:absolute;left:{x}px;top:{y}px;width:{w}px;height:{h}px;'
        f'background:{bg};border:{border};display:flex;flex-direction:column;overflow:hidden">'
        f'<div class="jas-pane-title" style="height:20px;background:#383838;display:flex;'
        f'align-items:center;padding:0 6px;cursor:grab;font-size:11px;color:#d9d9d9">'
        f'{label}{extra_btns}{close_btn}</div>'
        f'<div class="jas-pane-content" style="flex:1;overflow:auto">{content_html}</div>'
        f'<div class="jas-edge-handle left"></div>'
        f'<div class="jas-edge-handle right"></div>'
        f'<div class="jas-edge-handle top"></div>'
        f'<div class="jas-edge-handle bottom"></div>'
        f'</div>'
    )


def _render_container(el, theme, state):
    layout = el.get("layout", "column")
    direction = "flex-column" if layout == "column" else "flex-row"
    children = _render_children(el, theme, state)
    return Markup(
        f'<div{_id_attr(el)} class="d-flex {direction}"{_style_str(el, theme, state)}>'
        f'{children}</div>'
    )


def _render_row(el, theme, state):
    children = _render_children(el, theme, state)
    return Markup(
        f'<div{_id_attr(el)} class="d-flex flex-row"{_style_str(el, theme, state)}>'
        f'{children}</div>'
    )


def _render_col(el, theme, state):
    col = el.get("col", "auto")
    cls = f"col-{col}" if col != "auto" else "col"
    children = _render_children(el, theme, state)
    return Markup(f'<div{_id_attr(el)} class="{cls}"{_style_str(el, theme, state)}>{children}</div>')


def _render_grid(el, theme, state):
    cols = el.get("cols", 2)
    gap = el.get("gap", 2)
    children = _render_children(el, theme, state)
    return Markup(
        f'<div{_id_attr(el)} class="jas-grid"'
        f' style="display:grid;grid-template-columns:repeat({cols},1fr);gap:{gap}px">'
        f'{children}</div>'
    )


def _render_tabs(el, theme, state):
    children = el.get("children", [])
    tab_id = el.get("id", "tabs")
    # Tab headers
    nav_html = f'<ul class="nav nav-tabs" style="font-size:11px">'
    for i, child in enumerate(children):
        active = "active" if i == 0 else ""
        label = escape(child.get("summary", f"Tab {i}"))
        nav_html += (
            f'<li class="nav-item">'
            f'<a class="nav-link {active}" data-bs-toggle="tab"'
            f' href="#{tab_id}-{i}">{label}</a></li>'
        )
    nav_html += '</ul>'
    # Tab content
    content_html = '<div class="tab-content">'
    for i, child in enumerate(children):
        active = "show active" if i == 0 else ""
        body = render_element(child.get("content", child), theme, state, mode="normal")
        content_html += f'<div class="tab-pane {active}" id="{tab_id}-{i}">{body}</div>'
    content_html += '</div>'
    return Markup(f'<div{_id_attr(el)}>{nav_html}{content_html}</div>')


def _render_panel(el, theme, state):
    summary = escape(el.get("summary", "Panel"))
    menu = el.get("menu", [])
    content = el.get("content")
    content_html = render_element(content, theme, state, mode="normal") if isinstance(content, dict) else ""

    menu_html = ""
    if menu:
        menu_items = ""
        for item in menu:
            label = escape(item.get("label", ""))
            action = item.get("action", "")
            menu_items += (
                f'<li><a class="dropdown-item" href="#"'
                f' data-action="{escape(action)}">{label}</a></li>'
            )
        menu_html = (
            f'<div class="dropdown float-end">'
            f'<button class="btn btn-sm p-0" data-bs-toggle="dropdown"'
            f' style="color:#888;font-size:14px">&#8942;</button>'
            f'<ul class="dropdown-menu">{menu_items}</ul></div>'
        )

    return Markup(
        f'<div{_id_attr(el)} class="jas-panel">'
        f'<div class="d-flex align-items-center p-1" style="background:#383838;font-size:11px;color:#ccc">'
        f'{summary}{menu_html}</div>'
        f'<div class="p-2">{content_html}</div>'
        f'</div>'
    )


def _render_button(el, theme, state):
    label = escape(el.get("label", ""))
    variant = el.get("variant", "secondary")
    return Markup(
        f'<button{_id_attr(el)} class="btn btn-sm btn-{variant}"{_data_attrs(el)}>'
        f'{label}</button>'
    )


def _render_icon_button(el, theme, state):
    summary = escape(el.get("summary", el.get("icon", "?")))
    icon_name = el.get("icon", "")
    sz = el.get("style", {}).get("size", 32)
    if isinstance(sz, str) and "{{" in sz:
        sz = _resolve(sz, theme, state)
    icon_html = ""
    icon_def = _icons.get(icon_name)
    if icon_def:
        viewbox = icon_def.get("viewbox", "0 0 256 256")
        svg_content = icon_def.get("svg", "")
        icon_sz = int(float(sz) * 0.75)
        icon_html = (
            f'<svg viewBox="{viewbox}" width="{icon_sz}" height="{icon_sz}"'
            f' fill="currentColor" style="color:#cccccc">{svg_content}</svg>'
        )
    else:
        icon_html = escape(icon_name)
    return Markup(
        f'<button{_id_attr(el)} class="btn btn-sm btn-outline-secondary jas-tool-btn p-0"'
        f' style="width:{sz}px;height:{sz}px;display:flex;align-items:center;justify-content:center"'
        f' title="{summary}"{_data_attrs(el)}>'
        f'{icon_html}</button>'
    )


def _render_toggle(el, theme, state):
    label = escape(el.get("label", ""))
    return Markup(
        f'<div{_id_attr(el)} class="form-check">'
        f'<input class="form-check-input" type="checkbox">'
        f'<label class="form-check-label">{label}</label></div>'
    )


def _render_text(el, theme, state):
    content = el.get("content", "")
    if isinstance(content, str) and "{{" in content:
        content = resolve_interpolation(content, theme, state)
    return Markup(f'<span{_id_attr(el)}>{escape(content)}</span>')


def _render_text_input(el, theme, state):
    placeholder = escape(el.get("placeholder", ""))
    return Markup(
        f'<input{_id_attr(el)} type="text" class="form-control form-control-sm"'
        f' placeholder="{placeholder}">'
    )


def _render_number_input(el, theme, state):
    attrs = ""
    for key in ("min", "max", "step"):
        if key in el:
            attrs += f' {key}="{el[key]}"'
    return Markup(
        f'<input{_id_attr(el)} type="number" class="form-control form-control-sm"{attrs}>'
    )


def _render_color_swatch(el, theme, state):
    bind = el.get("bind", {})
    color_ref = bind.get("color", "#888")
    color = _resolve(color_ref, theme, state) if isinstance(color_ref, str) else "#888"
    sz = el.get("style", {}).get("size", 28)
    hollow = el.get("hollow", False)
    if hollow:
        return Markup(
            f'<div{_id_attr(el)} class="jas-color-swatch"'
            f' style="width:{sz}px;height:{sz}px;border:6px solid {color};background:#fff"'
            f'{_data_attrs(el)}></div>'
        )
    return Markup(
        f'<div{_id_attr(el)} class="jas-color-swatch"'
        f' style="width:{sz}px;height:{sz}px;background:{color};border:1px solid #666"'
        f'{_data_attrs(el)}></div>'
    )


def _render_slider(el, theme, state):
    attrs = ""
    for key in ("min", "max", "step"):
        if key in el:
            attrs += f' {key}="{el[key]}"'
    return Markup(f'<input{_id_attr(el)} type="range" class="form-range"{attrs}>')


def _render_select(el, theme, state):
    options_html = ""
    for opt in el.get("options", []):
        if isinstance(opt, dict):
            options_html += f'<option value="{escape(opt["id"])}">{escape(opt["label"])}</option>'
        else:
            options_html += f'<option value="{escape(str(opt))}">{escape(str(opt))}</option>'
    return Markup(
        f'<select{_id_attr(el)} class="form-select form-select-sm">{options_html}</select>'
    )


def _render_canvas(el, theme, state):
    summary = escape(el.get("summary", "Canvas"))
    return Markup(
        f'<div{_id_attr(el)} class="jas-canvas" '
        f'style="flex:1;background:#fff;display:flex;align-items:center;justify-content:center;'
        f'color:#999;font-size:14px;min-height:200px">'
        f'{summary} (tier 3)</div>'
    )


def _render_placeholder(el, theme, state):
    summary = escape(el.get("summary", "Placeholder"))
    desc = escape(el.get("description", ""))
    return Markup(
        f'<div{_id_attr(el)} class="jas-placeholder"'
        f' style="border:1px dashed #666;padding:12px;color:#888;text-align:center;'
        f'font-size:11px;min-height:40px"'
        f' title="{desc}">{summary}</div>'
    )


def _render_separator(el, theme, state):
    orientation = el.get("orientation", "horizontal")
    if orientation == "vertical":
        return Markup(f'<div{_id_attr(el)} style="width:1px;background:#555;margin:0 4px"></div>')
    return Markup(f'<hr{_id_attr(el)} style="border-color:#555;margin:4px 0">')


def _render_spacer(el, theme, state):
    size = el.get("style", {}).get("height") or el.get("size")
    if size:
        return Markup(f'<div{_id_attr(el)} style="height:{size}px"></div>')
    return Markup(f'<div{_id_attr(el)} style="flex:1"></div>')


def _render_image(el, theme, state):
    src = escape(el.get("src", ""))
    return Markup(f'<img{_id_attr(el)} src="{src}" class="img-fluid">')


def _render_unknown(el, theme, state):
    etype = escape(el.get("type", "unknown"))
    summary = escape(el.get("summary", etype))
    children = _render_children(el, theme, state)
    return Markup(
        f'<div{_id_attr(el)} class="jas-unknown"'
        f' style="border:1px solid #cc8800;padding:4px;color:#cc8800;font-size:10px">'
        f'[{etype}] {summary}{children}</div>'
    )


# ── Wireframe renderer ────────────────────────────────────────


def _render_wireframe(el: dict, theme: dict, state: dict, depth: int = 0) -> str:
    eid = el.get("id", "")
    etype = el.get("type", "?")
    summary = escape(el.get("summary", etype))
    tier = el.get("tier")
    tier_badge = f' <span class="badge bg-secondary">T{tier}</span>' if tier else ""

    children_html = ""
    for child in el.get("children", []):
        children_html += _render_wireframe(child, theme, state, depth + 1)
    content = el.get("content")
    if isinstance(content, dict):
        children_html += _render_wireframe(content, theme, state, depth + 1)

    depth_class = f"wf-depth-{min(depth, 5)}"
    return Markup(
        f'<div class="wf-element {depth_class}"'
        f' data-element-id="{escape(eid)}"'
        f' data-element-type="{escape(etype)}">'
        f'<div class="wf-label">{summary}{tier_badge}</div>'
        f'{children_html}</div>'
    )


# ── Menu items renderer ──────────────────────────────────────


def _render_menu_items(items: list, actions: dict) -> str:
    html = ""
    for item in items:
        if isinstance(item, str) and item == "separator":
            html += '<li><hr class="dropdown-divider"></li>'
            continue
        if not isinstance(item, dict):
            continue
        if item.get("type") == "submenu":
            label = escape(item.get("label", "").replace("&", ""))
            sub_items = _render_menu_items(item.get("items", []), actions)
            html += (
                f'<li class="dropdown-submenu">'
                f'<a class="dropdown-item dropdown-toggle" href="#">{label}</a>'
                f'<ul class="dropdown-menu">{sub_items}</ul></li>'
            )
        else:
            label = escape(item.get("label", "").replace("&", ""))
            shortcut = item.get("shortcut", "")
            action = item.get("action", "")
            params = item.get("params")
            data = f' data-action="{escape(action)}"'
            if params:
                data += f" data-action-params='{escape(json.dumps(params))}'"
            shortcut_html = f'<span class="text-muted float-end ms-3" style="font-size:11px">{escape(shortcut)}</span>' if shortcut else ""
            html += f'<li><a class="dropdown-item" href="#"{data}>{label}{shortcut_html}</a></li>'
    return html


# ── Dispatch table ────────────────────────────────────────────

_RENDERERS = {
    "pane_system": _render_pane_system,
    "pane": _render_pane,
    "container": _render_container,
    "row": _render_row,
    "col": _render_col,
    "grid": _render_grid,
    "tabs": _render_tabs,
    "panel": _render_panel,
    "button": _render_button,
    "icon_button": _render_icon_button,
    "toggle": _render_toggle,
    "text": _render_text,
    "text_input": _render_text_input,
    "number_input": _render_number_input,
    "color_swatch": _render_color_swatch,
    "slider": _render_slider,
    "select": _render_select,
    "canvas": _render_canvas,
    "placeholder": _render_placeholder,
    "separator": _render_separator,
    "spacer": _render_spacer,
    "image": _render_image,
}
