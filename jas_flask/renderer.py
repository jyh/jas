"""Element tree to HTML renderer for normal and wireframe modes."""

import json
import re
from markupsafe import Markup, escape

from loader import resolve_interpolation

# Module-level registries, set before rendering.
_icons: dict = {}
_initial_state: dict = {}
_brand: dict = {}
_panels: dict = {}


def set_icons(icons: dict) -> None:
    """Set the icon definitions for the renderer."""
    global _icons
    _icons = icons or {}


def set_initial_state(state_defs: dict) -> None:
    """Set initial state defaults for server-side visibility evaluation."""
    global _initial_state
    _initial_state = {name: defn.get("default") for name, defn in (state_defs or {}).items()}


def set_brand(brand: dict) -> None:
    """Set brand config (logo SVG, color) for use in empty-state renderers."""
    global _brand
    _brand = brand or {}


def set_panels(panels: dict) -> None:
    """Set the panel specs keyed by panel content id (e.g. 'color_panel_content')."""
    global _panels
    _panels = panels or {}


def render_element(el: dict, theme: dict, state: dict, mode: str = "normal") -> str:
    """Recursively render an element to HTML."""
    if not isinstance(el, dict):
        return ""
    if mode == "wireframe":
        return _render_wireframe(el, theme, state, depth=0)
    etype = el.get("type", "placeholder")
    renderer = _RENDERERS.get(etype, _render_unknown)
    return renderer(el, theme, state)


def render_menubar(menubar: list, actions: dict, theme: dict, brand: dict | None = None) -> str:
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
    logo_html = ""
    if brand:
        svg = brand.get("logo_small_svg") or brand.get("logo_svg", "")
        color = brand.get("color", "currentColor")
        if svg:
            logo_html = (
                f'<span class="navbar-brand me-2" style="color:{escape(color)};'
                f'display:inline-flex;align-items:center;height:20px;width:auto;">'
                f'<span style="display:inline-block;height:20px;width:45px;color:inherit">{svg}</span>'
                f'</span>'
            )
    return Markup(
        f'<nav class="navbar navbar-expand" style="background:var(--jas-pane-bg-dark,#333);padding:0 8px;">'
        f'{logo_html}'
        f'<ul class="navbar-nav">{items_html}</ul>'
        f'<div class="ms-auto">'
        f'<a class="nav-link small" style="color:var(--jas-text-dim,#999)" href="?mode=wireframe" id="mode-toggle">Wireframe</a>'
        f'</div>'
        f'</nav>'
    )


def render_dialogs(dialogs: dict, theme: dict, state: dict, brand: dict | None = None) -> str:
    """Render all dialogs as hidden Bootstrap modals."""
    logo_html = ""
    if brand:
        svg = brand.get("logo_small_svg") or brand.get("logo_svg", "")
        color = brand.get("color", "currentColor")
        if svg:
            logo_html = (
                f'<span style="display:inline-block;width:28px;height:14px;'
                f'color:{escape(color)};flex-shrink:0;margin-right:6px;">{svg}</span>'
            )
    html = ""
    for dialog_id, dialog in (dialogs or {}).items():
        summary = escape(dialog.get("summary", dialog_id))
        body_html = render_element(dialog.get("content", {}), theme, state, mode="normal")
        data_attrs = ""
        if "state" in dialog:
            data_attrs += f' data-dialog-state="{escape(json.dumps(dialog["state"]))}"'
        if "init" in dialog:
            data_attrs += f' data-dialog-init="{escape(json.dumps(dialog["init"]))}"'
        html += (
            f'<div class="modal fade" id="dialog-{dialog_id}" tabindex="-1"{data_attrs}>'
            f'<div class="modal-dialog"><div class="modal-content">'
            f'<div class="modal-header" style="display:flex;align-items:center;">'
            f'{logo_html}'
            f'<h5 class="modal-title">{summary}</h5>'
            f'<button type="button" class="btn-close ms-auto" data-bs-dismiss="modal"></button></div>'
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
        elif key == "width":
            parts.append(f"width:{_px(val)}")
        elif key == "height":
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
        elif key == "position":
            parts.append(f"position:{val}")
        elif key == "top":
            parts.append(f"top:{_px(val)}")
        elif key == "right":
            parts.append(f"right:{_px(val)}")
        elif key == "bottom":
            parts.append(f"bottom:{_px(val)}")
        elif key == "left":
            parts.append(f"left:{_px(val)}")
        elif key == "size":
            sz = _resolve(val, theme, state)
            parts.append(f"width:{sz}px;height:{sz}px")
        elif key == "alignment":
            parts.append(f"align-items:{_align(val)}")
        elif key == "justify":
            parts.append(f"justify-content:{_justify(val)}")
        elif key == "aspect_ratio":
            parts.append(f"aspect-ratio:{val}")
    return f' style="{";".join(parts)}"' if parts else ""


_THEME_CSS_RE = re.compile(r"\{\{\s*theme\.colors\.(\w+)\s*\}\}")


def _resolve(val, theme, state):
    """Resolve a value, emitting CSS var() references for theme.colors.*."""
    if isinstance(val, str) and "{{" in val:
        # Replace theme.colors.* with var(--jas-*) so appearance switching works
        css_val = _THEME_CSS_RE.sub(
            lambda m: "var(--jas-" + m.group(1).replace("_", "-") + ")",
            val,
        )
        # If there are remaining non-color interpolations, resolve them normally
        if "{{" in css_val:
            return resolve_interpolation(css_val, theme, state)
        return css_val
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

    # Find the first simple click action for data-action
    click_action = None
    click_params = None
    if not behaviors:
        click_action = el.get("action")
        click_params = el.get("params")
    else:
        for b in behaviors:
            if b.get("event") == "click" and b.get("action") and not b.get("condition"):
                click_action = b["action"]
                click_params = b.get("params")
                break

    if click_action:
        parts.append(f'data-action="{escape(click_action)}"')
        if click_params:
            parts.append(f"data-action-params='{escape(json.dumps(click_params))}'")

    # Emit all behaviors that need JS wiring
    wired = [b for b in behaviors if b.get("event") != "click"
             or b.get("condition") or (b.get("effects") and not b.get("action"))]
    if wired:
        parts.append(f"data-behaviors='{escape(json.dumps(wired))}'")

    # Emit bind attributes
    bind = el.get("bind", {})
    if not isinstance(bind, dict):
        bind = {}
    for prop, expr in bind.items():
        parts.append(f'data-bind-{prop}="{escape(str(expr))}"')
    # If bind.visible evaluates to false at render time, set initial display:none.
    # Skip server-side evaluation when the expression references panel.* (client-only).
    vis_expr = bind.get("visible")
    if vis_expr and isinstance(vis_expr, str) and "{{panel." not in vis_expr and "panel." not in vis_expr:
        from loader import resolve_interpolation as _ri
        resolved = _ri(vis_expr, {}, _initial_state or {})
        hidden = False
        if resolved in ("false", "False", "0"):
            hidden = True
        elif resolved.startswith("not "):
            inner = resolved[4:].strip()
            if inner in ("false", "False", "0", ""):
                hidden = False
            else:
                hidden = True
        elif " != " in resolved:
            left, right = resolved.split(" != ", 1)
            hidden = left.strip() == right.strip()
        elif " == " in resolved:
            left, right = resolved.split(" == ", 1)
            hidden = left.strip() != right.strip()
        if hidden:
            parts.append('data-initial-hidden="true"')

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
        f'background:{_resolve(el.get("style", {}).get("background", "{{theme.colors.window_bg}}"), theme, state)}">'
        f'{children}</div>'
    )


def _render_pane(el, theme, state):
    pos = el.get("default_position", {})
    x, y = pos.get("x", 0), pos.get("y", 0)
    w, h = pos.get("width", 200), pos.get("height", 400)
    title_bar = el.get("title_bar", {})

    title_btns = ""
    for btn in title_bar.get("buttons", []):
        title_btns += render_element(btn, theme, state, mode="normal")

    content_html = ""
    content = el.get("content")
    if isinstance(content, dict):
        content_html = render_element(content, theme, state, mode="normal")

    bg = _resolve(el.get("style", {}).get("background", "{{theme.colors.pane_bg}}"), theme, state)
    border = _resolve(el.get("style", {}).get("border", "1px solid {{theme.colors.border}}"), theme, state)

    # Extra data attributes for generic bindings
    extra_data = _data_attrs(el)
    collapsed_width = el.get("collapsed_width")
    if collapsed_width is not None:
        extra_data += f' data-collapsed-width="{collapsed_width}"'

    return Markup(
        f'<div{_id_attr(el)} class="jas-pane"'
        f' style="position:absolute;left:{x}px;top:{y}px;width:{w}px;height:{h}px;'
        f'background:{bg};border:{border};display:flex;flex-direction:column;overflow:hidden"'
        f'{extra_data}>'
        f'<div{_id_attr(title_bar)} class="jas-pane-title" style="height:var(--jas-size-title-bar-height,20px);background:var(--jas-title-bar-bg,#2a2a2a);display:flex;'
        f'align-items:center;padding:0 6px;cursor:grab;font-size:11px;color:var(--jas-title-bar-text,#d9d9d9)"'
        f'{_data_attrs(title_bar)}>'
        f'<span class="ms-auto d-flex gap-1">{title_btns}</span></div>'
        f'<div class="jas-pane-content" style="flex:1;overflow:auto;display:flex;flex-direction:column">{content_html}</div>'
        f'<div class="jas-edge-handle left"></div>'
        f'<div class="jas-edge-handle right"></div>'
        f'<div class="jas-edge-handle top"></div>'
        f'<div class="jas-edge-handle bottom"></div>'
        f'</div>'
    )


def _render_container(el, theme, state):
    layout = el.get("layout", "column")
    direction = "flex-column" if layout == "column" else "flex-row"
    # If any child uses absolute positioning, this container needs position:relative
    has_abs_children = any(
        c.get("style", {}).get("position") for c in el.get("children", []) if isinstance(c, dict)
    )
    extra = "position:relative" if has_abs_children else ""
    children = _render_children(el, theme, state)
    return Markup(
        f'<div{_id_attr(el)} class="d-flex {direction}"{_style_str(el, theme, state, extra)}{_data_attrs(el)}>'
        f'{children}</div>'
    )


def _render_row(el, theme, state):
    children = _render_children(el, theme, state)
    # Use Bootstrap grid "row" if any child uses col; otherwise plain flex-row
    has_col_children = any(
        c.get("col") is not None or c.get("type") == "col"
        for c in el.get("children", []) if isinstance(c, dict)
    )
    cls = "row g-0" if has_col_children else "d-flex flex-row"
    return Markup(
        f'<div{_id_attr(el)} class="{cls}"{_style_str(el, theme, state)}{_data_attrs(el)}>'
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
    # Embed panel-local state/init as data attributes for client-side initialization.
    # data-panel-state emits only default values (not full specs) so JS can use directly.
    panel_data = ""
    if el.get("state"):
        defaults = {k: v.get("default") if isinstance(v, dict) else v
                    for k, v in el["state"].items()}
        panel_data += f' data-panel-state="{escape(json.dumps(defaults))}"'
    if el.get("init"):
        panel_data += f' data-panel-init="{escape(json.dumps(el["init"]))}"'

    menu_html = ""
    if menu:
        menu_items = ""
        for item in menu:
            if isinstance(item, str) and item == "separator":
                menu_items += '<li><hr class="dropdown-divider"></li>'
                continue
            if not isinstance(item, dict):
                continue
            label = escape(item.get("label", ""))
            action = item.get("action", "")
            ip = item.get("params")
            disabled = item.get("disabled", False)
            data = f' data-action="{escape(action)}"' if action and not disabled else ""
            if ip and not disabled:
                data += f" data-action-params='{escape(json.dumps(ip))}'"
            dis_attr = ' aria-disabled="true" style="opacity:0.5;pointer-events:none"' if disabled else ""
            menu_items += (
                f'<li><a class="dropdown-item" href="#"{data}{dis_attr}>{label}</a></li>'
            )
        menu_html = (
            f'<div class="dropdown float-end">'
            f'<button class="btn btn-sm p-0" data-bs-toggle="dropdown"'
            f' style="color:var(--jas-text-button,#888);font-size:16px;display:inline-flex;align-items:center">&#8942;</button>'
            f'<ul class="dropdown-menu">{menu_items}</ul></div>'
        )

    return Markup(
        f'<div{_id_attr(el)} class="jas-panel"{panel_data}>'
        f'<div class="d-flex align-items-center p-1" style="background:var(--jas-title-bar-bg,#2a2a2a);font-size:11px;color:var(--jas-text,#ccc)">'
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
    style = el.get("style", {})
    sz = style.get("size", 32)
    if isinstance(sz, str) and "{{" in sz:
        sz = _resolve(sz, theme, state)
    pos = style.get("position", {})
    pos_css = f"position:absolute;left:{pos['x']}px;top:{pos['y']}px;" if pos else ""
    icon_html = ""
    icon_def = _icons.get(icon_name)
    if icon_def:
        viewbox = icon_def.get("viewbox", "0 0 256 256")
        svg_content = icon_def.get("svg", "")
        icon_sz = int(float(sz) * 0.75)
        icon_html = (
            f'<svg viewBox="{viewbox}" width="{icon_sz}" height="{icon_sz}"'
            f' style="color:var(--jas-text,#cccccc);fill:currentColor;stroke:currentColor">{svg_content}</svg>'
        )
    else:
        # Fallback: show first letter of summary or icon name
        fallback = summary[0] if summary else (icon_name[0] if icon_name else "?")
        icon_html = f'<span style="font-size:{int(float(sz)*0.5)}px;font-weight:bold;color:var(--jas-text,#ccc)">{escape(str(fallback))}</span>'
    return Markup(
        f'<button{_id_attr(el)} class="btn btn-sm btn-outline-secondary jas-tool-btn p-0"'
        f' style="{pos_css}width:{sz}px;height:{sz}px;display:flex;align-items:center;justify-content:center"'
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


def _render_radio_group(el, theme, state):
    """Render a group of radio buttons or a single radio in a named group."""
    options = el.get("options", [])
    group_name = escape(el.get("bind", el.get("group", el.get("id", "radio"))))
    html = ""
    for opt in options:
        if isinstance(opt, dict):
            opt_id = escape(opt.get("id", ""))
            opt_label = escape(opt.get("label", ""))
        else:
            opt_id = escape(str(opt))
            opt_label = escape(str(opt))
        checked = ""
        input_id = f"{el.get('id', 'rg')}_{opt_id}"
        html += (
            f'<div class="form-check form-check-inline" style="min-height:auto;padding-left:20px;margin:0">'
            f'<input class="form-check-input" type="radio" name="{group_name}"'
            f' id="{input_id}" value="{opt_id}"{checked}>'
            f'<label class="form-check-label" for="{input_id}">{opt_label}</label></div>'
        )
    return Markup(f'<span{_id_attr(el)}>{html}</span>')


def _render_text(el, theme, state):
    content = el.get("content", "")
    if isinstance(content, str) and "{{" in content:
        content = resolve_interpolation(content, theme, state)
    return Markup(f'<span{_id_attr(el)}>{escape(content)}</span>')


def _render_text_input(el, theme, state):
    placeholder = escape(el.get("placeholder", ""))
    return Markup(
        f'<input{_id_attr(el)} type="text" class="form-control form-control-sm"'
        f' placeholder="{placeholder}"{_data_attrs(el)}>'
    )


def _render_number_input(el, theme, state):
    attrs = ""
    for key in ("min", "max", "step"):
        if key in el:
            attrs += f' {key}="{el[key]}"'
    return Markup(
        f'<input{_id_attr(el)} type="number" class="form-control form-control-sm"{attrs}'
        f'{_style_str(el, theme, state)}{_data_attrs(el)}>'
    )


def _render_color_swatch(el, theme, state):
    bind = el.get("bind", {})
    color_ref = bind.get("color", "#888")
    # Resolve bare state.* references against initial state
    if isinstance(color_ref, str) and color_ref.startswith("state."):
        key = color_ref.split(".", 1)[1]
        color = state.get(key, "#888") or "#888"
    elif isinstance(color_ref, str):
        color = _resolve(color_ref, theme, state)
    else:
        color = "#888"
    style = el.get("style", {})
    sz = style.get("size", 28)
    hollow = el.get("hollow", False)
    pos = style.get("position", {})
    pos_css = f"position:absolute;left:{pos['x']}px;top:{pos['y']}px;" if pos else ""
    # Empty swatch: color is unresolvable (panel namespace) or explicitly empty
    is_empty = not color or color.startswith("{{") or color in ("none", "null", "")
    if is_empty:
        return Markup(
            f'<div{_id_attr(el)} class="jas-color-swatch jas-color-swatch-empty"'
            f' style="{pos_css}width:{sz}px;height:{sz}px;box-sizing:border-box"'
            f'{_data_attrs(el)}></div>'
        )
    if hollow:
        return Markup(
            f'<div{_id_attr(el)} class="jas-color-swatch" data-hollow="true"'
            f' style="{pos_css}width:{sz}px;height:{sz}px;border:6px solid {color};background:transparent;box-sizing:border-box"'
            f'{_data_attrs(el)}></div>'
        )
    return Markup(
        f'<div{_id_attr(el)} class="jas-color-swatch"'
        f' style="{pos_css}width:{sz}px;height:{sz}px;background:{color};border:1px solid #666"'
        f'{_data_attrs(el)}></div>'
    )


def _render_slider(el, theme, state):
    attrs = ""
    for key in ("min", "max", "step"):
        if key in el:
            attrs += f' {key}="{el[key]}"'
    return Markup(f'<input{_id_attr(el)} type="range" class="form-range"{attrs}{_data_attrs(el)}>')


def _render_select(el, theme, state):
    options_html = ""
    for opt in el.get("options", []):
        if isinstance(opt, dict):
            val = opt.get("value", opt.get("id", ""))
            label = opt.get("label", str(val))
            options_html += f'<option value="{escape(str(val))}">{escape(str(label))}</option>'
        else:
            options_html += f'<option value="{escape(str(opt))}">{escape(str(opt))}</option>'
    return Markup(
        f'<select{_id_attr(el)} class="form-select form-select-sm">{options_html}</select>'
    )


def _render_canvas(el, theme, state):
    summary = escape(el.get("summary", "Canvas"))
    logo_html = ""
    if _brand:
        svg = _brand.get("logo_small_svg") or _brand.get("logo_svg", "")
        color = _brand.get("color", "#C9900A")
        if svg:
            logo_html = (
                f'<span style="position:absolute;top:10px;right:12px;'
                f'width:54px;height:24px;color:{escape(color)};opacity:0.35;">{svg}</span>'
            )
    return Markup(
        f'<div{_id_attr(el)} class="jas-canvas" '
        f'style="flex:1;background:#fff;display:flex;align-items:center;justify-content:center;'
        f'color:#999;font-size:14px;min-height:200px;position:relative;"'
        f'{_data_attrs(el)}>'
        f'{logo_html}'
        f'{summary} (tier 3)</div>'
    )


def _render_placeholder(el, theme, state):
    summary = escape(el.get("summary", "Placeholder"))
    desc = escape(el.get("description", ""))
    base = "border:1px dashed var(--jas-border,#666);padding:12px;color:var(--jas-text-button,#888);text-align:center;font-size:11px;min-height:40px"
    return Markup(
        f'<div{_id_attr(el)} class="jas-placeholder"'
        f'{_style_str(el, theme, state, base)}'
        f' title="{desc}"{_data_attrs(el)}>{summary}</div>'
    )


def _render_separator(el, theme, state):
    orientation = el.get("orientation", "horizontal")
    extra_class = f' {escape(el["class"])}' if el.get("class") else ""
    if orientation == "vertical":
        return Markup(f'<div{_id_attr(el)} class="jas-separator-v{extra_class}" style="width:1px;background:var(--jas-border,#555);margin:0 4px;align-self:stretch"{_data_attrs(el)}></div>')
    return Markup(f'<hr{_id_attr(el)} class="jas-separator{extra_class}" style="border-color:var(--jas-border,#555);margin:4px 0"{_data_attrs(el)}>')


def _render_spacer(el, theme, state):
    size = el.get("style", {}).get("height") or el.get("size")
    if size:
        return Markup(f'<div{_id_attr(el)} style="height:{size}px"></div>')
    return Markup(f'<div{_id_attr(el)} style="flex:1"></div>')


def _render_image(el, theme, state):
    src = escape(el.get("src", ""))
    return Markup(f'<img{_id_attr(el)} src="{src}" class="img-fluid">')


def _render_color_bar(el, theme, state):
    """Render the 2D color gradient bar: hue × saturation at current brightness."""
    bind_attrs = _data_attrs(el)
    brightness = el.get("bind", {}).get("brightness", "100")
    return Markup(
        f'<canvas{_id_attr(el)} class="jas-color-bar"'
        f' data-type="color-bar"'
        f' data-brightness="{escape(str(brightness))}"'
        f' style="width:100%;height:64px;display:block;cursor:crosshair"'
        f'{bind_attrs}></canvas>'
    )


def _render_dropdown(el, theme, state):
    """Render a dropdown button with a menu of items."""
    icon_name = el.get("icon", "")
    label_text = el.get("label", "")
    items = el.get("items", [])
    sz = el.get("style", {}).get("size", 16)

    # Button content: icon or label
    btn_content = ""
    icon_def = _icons.get(icon_name)
    if icon_def:
        viewbox = icon_def.get("viewbox", "0 0 16 16")
        svg_content = icon_def.get("svg", "")
        icon_sz = int(float(sz) * 0.75)
        btn_content = (
            f'<svg viewBox="{viewbox}" width="{icon_sz}" height="{icon_sz}"'
            f' fill="currentColor" style="color:var(--jas-text,#cccccc)">{svg_content}</svg>'
        )
    elif label_text:
        btn_content = escape(label_text)
    else:
        btn_content = "&#8942;"

    # Menu items
    menu_html = ""
    for item in items:
        if isinstance(item, str) and item == "separator":
            menu_html += '<li><hr class="dropdown-divider"></li>'
            continue
        if not isinstance(item, dict):
            continue
        il = escape(item.get("label", ""))
        ia = item.get("action", "")
        ip = item.get("params")
        data = f' data-action="{escape(ia)}"' if ia else ""
        if ip:
            data += f" data-action-params='{escape(json.dumps(ip))}'"
        menu_html += f'<li><a class="dropdown-item" href="#"{data}>{il}</a></li>'

    return Markup(
        f'<div{_id_attr(el)} class="dropdown" style="display:inline-block"{_data_attrs(el)}>'
        f'<button class="btn btn-sm p-0" data-bs-toggle="dropdown"'
        f' style="width:{sz}px;height:{sz}px;display:flex;align-items:center;'
        f'justify-content:center;color:var(--jas-text-dim,#999);border:none;background:transparent">'
        f'{btn_content}</button>'
        f'<ul class="dropdown-menu">{menu_html}</ul></div>'
    )


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
                f'<li class="dropdown-submenu" style="position:relative">'
                f'<a class="dropdown-item" href="#" id="{escape(item.get("id", ""))}">{label} &#9656;</a>'
                f'<ul class="dropdown-menu" style="display:none;position:absolute;left:100%;top:0">{sub_items}</ul></li>'
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


# ── dock_view renderer ────────────────────────────────────────

# Panel name -> display label
_PANEL_LABELS = {
    "layers": "Layers", "color": "Color",
    "stroke": "Stroke", "properties": "Properties",
}


def _render_dock_view(el, theme, state):
    """Render a dock_view element: panel groups with tab bars, bodies, and collapsed strip."""
    eid = el.get("id", "")
    groups = el.get("groups", [])
    collapsed_width = el.get("collapsed_width", 36)
    dock_collapsed = state.get("dock_collapsed", False)

    html = f'<div id="{escape(eid)}" class="jas-dock-view" data-element-type="dock_view"'
    html += f' data-collapsed-width="{collapsed_width}"'
    html += f' data-groups=\'{escape(json.dumps(groups))}\''
    html += ' style="display:flex;flex-direction:column;flex:1">'

    if dock_collapsed:
        # Collapsed icon strip
        html += '<div class="jas-dock-collapsed-strip" style="display:flex;flex-direction:column;align-items:center;gap:2px;padding:4px 0">'
        for gi, group in enumerate(groups):
            for pi, panel_name in enumerate(group.get("panels", [])):
                icon_name = f"panel_{panel_name}"
                icon_def = _icons.get(icon_name, {})
                viewbox = icon_def.get("viewbox", "0 0 28 28")
                svg = icon_def.get("svg", "")
                html += (
                    f'<button class="btn btn-sm jas-dock-icon p-0" style="width:28px;height:28px;display:flex;align-items:center;justify-content:center;background:var(--jas-button-checked,#505050);border:none;color:var(--jas-text-dim,#999)"'
                    f' data-dock="{escape(eid)}" data-group="{gi}" data-panel="{pi}"'
                    f' title="{escape(_PANEL_LABELS.get(panel_name, panel_name))}">'
                    f'<svg viewBox="{viewbox}" width="20" height="20" fill="currentColor">{svg}</svg></button>'
                )
            if gi < len(groups) - 1:
                html += '<hr style="width:80%;border-color:var(--jas-border,#555);margin:2px 0">'
        html += '</div>'
    else:
        # Expanded: render each group
        for gi, group in enumerate(groups):
            panels = group.get("panels", [])
            active = group.get("active", 0)
            collapsed = group.get("collapsed", False)

            html += f'<div class="jas-dock-group" data-dock="{escape(eid)}" data-group-index="{gi}">'

            # Group header: grip + tab buttons + spacer + chevron + hamburger
            html += '<div class="jas-dock-group-header" style="display:flex;align-items:center;background:var(--jas-pane-bg-dark,#333);padding:2px 4px;gap:2px;height:22px">'

            # Grip handle for group drag
            html += f'<span class="jas-dock-grip" draggable="true" style="cursor:grab;color:var(--jas-text-hint,#777);font-size:10px;padding:0 2px" data-dock="{escape(eid)}" data-group="{gi}">⠁⠁</span>'

            # Tab buttons
            for pi, panel_name in enumerate(panels):
                label = _PANEL_LABELS.get(panel_name, panel_name.title())
                active_cls = " active" if pi == active else ""
                tab_bg = "var(--jas-tab-active,#4a4a4a)" if pi == active else "var(--jas-tab-inactive,#353535)"
                html += (
                    f'<button class="btn btn-sm jas-dock-tab{active_cls}" style="padding:1px 6px;font-size:11px;color:var(--jas-text,#ccc);background:{tab_bg};border:none"'
                    f' draggable="true" data-dock="{escape(eid)}" data-group="{gi}" data-panel-index="{pi}" data-panel-name="{escape(panel_name)}">'
                    f'{escape(label)}</button>'
                )

            # Spacer
            html += '<span style="flex:1"></span>'

            # Collapse chevron
            chevron = "\u00bb" if collapsed else "\u00ab"
            html += (
                f'<button class="btn btn-sm jas-dock-chevron p-0" style="color:var(--jas-text-button,#888);background:transparent;border:none;font-size:16px;line-height:1;display:inline-flex;align-items:center"'
                f' data-dock="{escape(eid)}" data-group="{gi}">{chevron}</button>'
            )

            # Hamburger menu (hidden when collapsed)
            # Merges active panel's own menu items (above) with Close items (below).
            if not collapsed:
                active_panel_spec = None
                if 0 <= active < len(panels):
                    active_key = f"{panels[active]}_panel_content"
                    active_panel_spec = _panels.get(active_key)

                html += '<div class="dropdown d-inline-block">'
                html += '<button class="btn btn-sm p-0" data-bs-toggle="dropdown" style="color:var(--jas-text-button,#888);background:transparent;border:none;font-size:16px;display:inline-flex;align-items:center">≡</button>'
                html += '<ul class="dropdown-menu">'
                # Panel-specific menu items first
                if active_panel_spec and active_panel_spec.get("menu"):
                    for item in active_panel_spec["menu"]:
                        if isinstance(item, str) and item == "separator":
                            html += '<li><hr class="dropdown-divider"></li>'
                            continue
                        if not isinstance(item, dict):
                            continue
                        il = escape(item.get("label", ""))
                        ia = item.get("action", "")
                        ip = item.get("params")
                        disabled = item.get("disabled", False)
                        data = f' data-action="{escape(ia)}"' if ia and not disabled else ""
                        if ip and not disabled:
                            data += f" data-action-params='{escape(json.dumps(ip))}'"
                        dis_attr = ' aria-disabled="true" style="opacity:0.5;pointer-events:none"' if disabled else ""
                        html += f'<li><a class="dropdown-item" href="#"{data}{dis_attr}>{il}</a></li>'
                    html += '<li><hr class="dropdown-divider"></li>'
                # Close panel items
                for panel_name in panels:
                    label = _PANEL_LABELS.get(panel_name, panel_name.title())
                    html += f'<li><a class="dropdown-item" href="#" data-action="close_panel" data-action-params=\'{{"panel":"{escape(panel_name)}"}}\'>{escape("Close " + label)}</a></li>'
                html += '</ul></div>'

                # Close button (×) for active panel
                if 0 <= active < len(panels):
                    active_panel_close = panels[active]
                    close_params = escape(json.dumps({"panel": active_panel_close}))
                    html += (
                        f'<button class="btn btn-sm jas-dock-close p-0"'
                        f' style="color:var(--jas-text-button,#888);background:transparent;border:none;font-size:12px;line-height:1;display:inline-flex;align-items:center;width:20px"'
                        f' data-action="close_panel" data-action-params=\'{close_params}\''
                        f' title="Close">&#x2715;</button>'
                    )

            html += '</div>'  # header

            # Group body (hidden when collapsed) — render ALL panels, hide inactive
            if not collapsed:
                html += '<div class="jas-dock-group-body" style="flex:1;overflow:auto">'
                for pi, panel_name in enumerate(panels):
                    is_active = (pi == active)
                    panel_key = f"{panel_name}_panel_content"
                    panel_spec = _panels.get(panel_key)
                    hidden_cls = "" if is_active else " d-none"
                    if panel_spec is not None:
                        body_attrs = f' data-panel-name="{escape(panel_name)}"'
                        if panel_spec.get("state"):
                            defaults = {k: v.get("default") if isinstance(v, dict) else v
                                        for k, v in panel_spec["state"].items()}
                            body_attrs += f' data-panel-state="{escape(json.dumps(defaults))}"'
                        if panel_spec.get("init"):
                            body_attrs += f' data-panel-init="{escape(json.dumps(panel_spec["init"]))}"'
                        content_el = panel_spec.get("content")
                        content_html = render_element(content_el, theme, state, mode="normal") if isinstance(content_el, dict) else ""
                        html += f'<div class="jas-dock-panel-body{hidden_cls}"{body_attrs}>{content_html}</div>'
                    else:
                        label = _PANEL_LABELS.get(panel_name, panel_name.title())
                        html += f'<div class="jas-dock-panel-body{hidden_cls}" style="padding:12px;color:var(--jas-text-body,#aaa);font-size:18px" data-panel-name="{escape(panel_name)}">{escape(label)}</div>'
                html += '</div>'

            html += '</div>'  # group

            # Separator between groups
            if gi < len(groups) - 1:
                html += '<hr style="border-color:var(--jas-border,#555);margin:0">'

    html += '</div>'  # dock_view
    return Markup(html)


# ── Dispatch table ────────────────────────────────────────────

def _render_brand_logo(el, theme, state):
    """Render the brand logo SVG inline. Position/size come from style attributes."""
    if not _brand:
        return Markup("")
    svg = _brand.get("logo_small_svg") or _brand.get("logo_svg", "")
    color = _brand.get("color", "#C9900A")
    if not svg:
        return Markup("")
    # Inject width/height="100%" so the SVG fills its container span rather than
    # expanding to its natural (viewport-filling) size.
    svg = svg.replace("<svg ", '<svg width="100%" height="100%" ', 1)
    base = f"display:block;overflow:hidden;color:{escape(color)};line-height:0"
    return Markup(
        f'<span{_id_attr(el)}{_style_str(el, theme, state, base)}{_data_attrs(el)}>{svg}</span>'
    )


_RENDERERS = {
    "pane_system": _render_pane_system,
    "pane": _render_pane,
    "container": _render_container,
    "row": _render_row,
    "col": _render_col,
    "grid": _render_grid,
    "tabs": _render_tabs,
    "dock_view": _render_dock_view,
    "panel": _render_panel,
    "button": _render_button,
    "icon_button": _render_icon_button,
    "dropdown": _render_dropdown,
    "toggle": _render_toggle,
    "radio_group": _render_radio_group,
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
    "color_bar": _render_color_bar,
    "brand_logo": _render_brand_logo,
    "fill_stroke_widget": _render_col,
}
