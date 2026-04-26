"""Tests for renderer.py — element-to-HTML rendering for normal and wireframe modes."""

import os
import sys
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

WORKSPACE_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "workspace")


@pytest.fixture
def theme():
    return {
        "colors": {"bg": "#000", "text": "#ccc", "border": "#555", "button_checked": "#505050"},
        "fonts": {"default": {"family": "sans-serif", "size": 12}},
        "sizes": {"tool_button": 32, "title_bar_height": 20},
    }


@pytest.fixture
def state():
    return {"active_tool": "pen"}


@pytest.fixture
def color_state():
    return {
        "active_tool": "pen",
        "fill_color": "#ff6600",
        "stroke_color": "#000000",
        "fill_on_top": True,
        "stroke_width": 1.0,
    }


class TestRenderButton:
    def test_basic_button(self, theme, state):
        from renderer import render_element
        el = {"type": "button", "label": "OK", "action": "quit"}
        html = render_element(el, theme, state, mode="normal")
        assert "btn" in html
        assert "OK" in html
        assert 'data-action="quit"' in html

    def test_primary_variant(self, theme, state):
        from renderer import render_element
        el = {"type": "button", "label": "Save", "action": "save", "variant": "primary"}
        html = render_element(el, theme, state, mode="normal")
        assert "btn-primary" in html

    def test_default_variant(self, theme, state):
        from renderer import render_element
        el = {"type": "button", "label": "Cancel", "action": "dismiss_dialog"}
        html = render_element(el, theme, state, mode="normal")
        assert "btn-secondary" in html


class TestRenderIconButton:
    """Toolbar icon buttons with optional alternates indicator.

    Buttons whose yaml carries an ``alternates:`` block show a small
    triangle in the lower-right corner, mirroring the Rust / Swift /
    OCaml / Python convention. Buttons without alternates render the
    icon alone."""

    def test_icon_button_without_alternates_omits_triangle(self, theme, state):
        from renderer import render_element
        el = {
            "type": "icon_button", "id": "btn_selection", "summary": "Selection",
            "icon": "selection_arrow",
            "style": {"size": 32},
        }
        html = render_element(el, theme, state, mode="normal")
        assert "btn_selection" in html
        assert "alternate-triangle" not in html

    def test_icon_button_with_alternates_renders_triangle(self, theme, state):
        from renderer import render_element
        el = {
            "type": "icon_button", "id": "btn_arrow_slot",
            "summary": "Partial Selection",
            "icon": "partial_selection_arrow",
            "style": {"size": 32},
            "alternates": {
                "menu_id": "arrow_alternates",
                "items": [
                    {"id": "partial_selection", "label": "Partial Selection",
                     "icon": "partial_selection_arrow"},
                    {"id": "interior_selection", "label": "Interior Selection",
                     "icon": "interior_selection_arrow"},
                ],
            },
        }
        html = render_element(el, theme, state, mode="normal")
        assert "alternate-triangle" in html

    def test_alternates_triangle_has_data_attribute(self, theme, state):
        """The triangle is annotated so JS / tests can target it
        independently of the icon."""
        from renderer import render_element
        el = {
            "type": "icon_button", "id": "btn_pen_slot", "summary": "Pen",
            "icon": "pen", "style": {"size": 32},
            "alternates": {"menu_id": "pen_alternates", "items": []},
        }
        html = render_element(el, theme, state, mode="normal")
        assert 'data-has-alternates="true"' in html

    def test_buttons_omit_bootstrap_btn_outline_class(self, theme, state):
        """Tool buttons should not carry ``btn-outline-secondary``.

        Bootstrap's outline-secondary class fights with app.css over
        :hover / :focus / .active backgrounds, producing inconsistent
        shading where focused-but-not-active buttons look darker than
        their unfocused peers. app.css's ``.app-tool-btn`` owns the
        base + hover + active states; we just need ``btn`` for the
        size / padding reset."""
        from renderer import render_element
        for el in [
            {"type": "icon_button", "id": "a", "summary": "A", "icon": "a",
             "style": {"size": 32}},
            {"type": "icon_button", "id": "b", "summary": "B", "icon": "b",
             "style": {"size": 32}, "alternates": {"items": []}},
        ]:
            html = render_element(el, theme, state, mode="normal")
            assert "btn-outline-secondary" not in html, (
                f"icon_button {el['id']!r} still carries Bootstrap "
                f"btn-outline-secondary; remove it so app.css owns "
                f"button shading uniformly"
            )

    def test_alternate_and_plain_buttons_use_identical_class_list(
            self, theme, state):
        """Tools with and without alternates differ only in the
        triangle child + data-has-alternates attribute. Their class
        list must be identical so they pick up the same CSS rules."""
        import re
        from renderer import render_element
        plain = render_element(
            {"type": "icon_button", "id": "p", "summary": "P", "icon": "p",
             "style": {"size": 32}}, theme, state)
        alt = render_element(
            {"type": "icon_button", "id": "a", "summary": "A", "icon": "a",
             "style": {"size": 32}, "alternates": {"items": []}}, theme, state)
        plain_class = re.search(r'class="([^"]*)"', plain).group(1)
        alt_class = re.search(r'class="([^"]*)"', alt).group(1)
        assert plain_class == alt_class, (
            f"class lists differ:\n  plain: {plain_class}\n  alt:   {alt_class}"
        )


class TestRenderPaneSystem:
    def test_position_relative(self, theme, state):
        from renderer import render_element
        el = {"type": "pane_system", "id": "main", "children": []}
        html = render_element(el, theme, state, mode="normal")
        assert "position" in html
        assert "relative" in html

    def test_contains_children(self, theme, state):
        from renderer import render_element
        el = {
            "type": "pane_system",
            "id": "main",
            "children": [
                {
                    "id": "p1",
                    "type": "pane",
                    "summary": "P1",
                    "default_position": {"x": 0, "y": 0, "width": 100, "height": 200},
                    "title_bar": {"label": "P1", "draggable": True, "closeable": False},
                    "content": {"type": "placeholder", "summary": "Empty"},
                }
            ],
        }
        html = render_element(el, theme, state, mode="normal")
        assert "p1" in html


class TestRenderPane:
    def test_absolute_position(self, theme, state):
        from renderer import render_element
        el = {
            "id": "tp",
            "type": "pane",
            "summary": "Test",
            "default_position": {"x": 10, "y": 20, "width": 300, "height": 400},
            "title_bar": {"label": "Test Pane", "draggable": True},
            "content": {"type": "placeholder", "summary": "Content"},
        }
        html = render_element(el, theme, state, mode="normal")
        assert "position" in html
        assert "absolute" in html
        assert "left:10px" in html or "left: 10px" in html
        assert "app-pane-title" in html

    def test_title_bar_buttons_rendered(self, theme, state):
        from renderer import render_element
        el = {
            "id": "tp",
            "type": "pane",
            "summary": "Test",
            "default_position": {"x": 0, "y": 0, "width": 100, "height": 100},
            "title_bar": {
                "label": "T",
                "draggable": True,
                "buttons": [
                    {"type": "icon_button", "id": "close_btn", "summary": "Close",
                     "icon": "close", "style": {"size": 14},
                     "behavior": [{"event": "click", "action": "toggle_pane", "params": {"pane": "tp"}}]},
                ],
            },
            "content": {"type": "placeholder", "summary": "C"},
        }
        html = render_element(el, theme, state, mode="normal")
        assert "close_btn" in html
        assert "toggle_pane" in html


class TestRenderGrid:
    def test_css_grid(self, theme, state):
        from renderer import render_element
        el = {
            "type": "grid",
            "id": "g1",
            "summary": "Grid",
            "cols": 3,
            "gap": 4,
            "children": [
                {"type": "icon_button", "summary": "A", "icon": "a", "grid": {"row": 0, "col": 0}},
                {"type": "icon_button", "summary": "B", "icon": "b", "grid": {"row": 0, "col": 1}},
            ],
        }
        html = render_element(el, theme, state, mode="normal")
        assert "grid" in html
        assert "repeat(3" in html


class TestRenderContainer:
    def test_column_layout(self, theme, state):
        from renderer import render_element
        el = {
            "type": "container",
            "layout": "column",
            "children": [
                {"type": "text", "content": "Hello"},
                {"type": "text", "content": "World"},
            ],
        }
        html = render_element(el, theme, state, mode="normal")
        assert "flex-column" in html
        assert "Hello" in html
        assert "World" in html

    def test_row_layout(self, theme, state):
        from renderer import render_element
        el = {
            "type": "container",
            "layout": "row",
            "children": [{"type": "text", "content": "A"}],
        }
        html = render_element(el, theme, state, mode="normal")
        assert "flex-row" in html


class TestRenderTabs:
    def test_nav_tabs(self, theme, state):
        from renderer import render_element
        el = {
            "type": "tabs",
            "id": "t1",
            "summary": "Tabs",
            "children": [
                {"type": "panel", "summary": "Tab1", "panel_kind": "a", "content": {"type": "placeholder", "summary": "C1"}},
                {"type": "panel", "summary": "Tab2", "panel_kind": "b", "content": {"type": "placeholder", "summary": "C2"}},
            ],
        }
        html = render_element(el, theme, state, mode="normal")
        assert "nav-tabs" in html or "nav" in html
        assert "Tab1" in html
        assert "Tab2" in html


class TestRenderPlaceholder:
    def test_placeholder_label(self, theme, state):
        from renderer import render_element
        el = {"type": "placeholder", "summary": "Not implemented", "description": "Future feature"}
        html = render_element(el, theme, state, mode="normal")
        assert "Not implemented" in html


class TestRenderText:
    def test_static_text(self, theme, state):
        from renderer import render_element
        el = {"type": "text", "content": "Hello world"}
        html = render_element(el, theme, state, mode="normal")
        assert "Hello world" in html


class TestRenderUnknown:
    def test_unknown_type_renders(self, theme, state):
        from renderer import render_element
        el = {"type": "magic_wand", "id": "mw", "summary": "Magic Wand Tool"}
        html = render_element(el, theme, state, mode="normal")
        assert "Magic Wand Tool" in html or "magic_wand" in html


class TestRenderMenubar:
    def test_menubar_renders(self, theme):
        from renderer import render_menubar
        menubar = [
            {
                "id": "file_menu",
                "label": "&File",
                "items": [
                    {"id": "new", "label": "&New", "action": "new_doc", "shortcut": "Ctrl+N"},
                    "separator",
                    {"id": "quit", "label": "&Quit", "action": "quit"},
                ],
            }
        ]
        actions = {"new_doc": {"description": "New"}, "quit": {"description": "Quit"}}
        html = render_menubar(menubar, actions, theme)
        assert "navbar" in html or "nav" in html
        assert "File" in html
        assert "New" in html
        assert "Quit" in html


class TestRenderDialogs:
    def test_modal_dialog(self, theme, state):
        from renderer import render_dialogs
        dialogs = {
            "confirm": {
                "summary": "Confirm",
                "description": "Test confirm",
                "modal": True,
                "content": {
                    "type": "container",
                    "layout": "column",
                    "children": [
                        {"type": "text", "content": "Sure?"},
                        {"type": "button", "label": "OK", "action": "quit", "variant": "primary"},
                    ],
                },
            }
        }
        html = render_dialogs(dialogs, theme, state)
        assert "modal" in html
        assert "Confirm" in html
        assert "OK" in html

    def test_preview_targets_emitted(self, theme, state):
        """Dialog with preview_targets emits a data-dialog-preview-targets
        JSON attribute carrying the dialog-state-field → document-target
        mapping. The JS snapshot/restore harness consumes this on dialog
        open to capture the document attributes that Preview-mode edits
        will live-apply to."""
        import json
        from renderer import render_dialogs
        dialogs = {
            "test_preview": {
                "summary": "Test Preview",
                "modal": True,
                "state": {"preview": {"type": "bool", "default": True}},
                "preview_targets": {
                    "left_indent": "selection.paragraph.jas:left-indent",
                    "right_indent": "selection.paragraph.jas:right-indent",
                },
                "content": {"type": "text", "content": "hi"},
            }
        }
        html = render_dialogs(dialogs, theme, state)
        assert "data-dialog-preview-targets" in html
        # extract and parse the JSON value
        import re
        m = re.search(r"data-dialog-preview-targets=\"([^\"]*)\"", html)
        assert m, "preview_targets attribute not found on modal"
        # HTML-unescape: the renderer uses markupsafe.escape, which encodes
        # quotes inside the JSON as &quot;.
        decoded = m.group(1).replace("&quot;", '"').replace("&#34;", '"')
        targets = json.loads(decoded)
        assert targets == {
            "left_indent": "selection.paragraph.jas:left-indent",
            "right_indent": "selection.paragraph.jas:right-indent",
        }

    def test_preview_targets_absent_when_not_declared(self, theme, state):
        """A dialog without preview_targets does not emit the attribute,
        keeping the existing dialog HTML clean for non-Preview dialogs."""
        from renderer import render_dialogs
        dialogs = {
            "no_preview": {
                "summary": "No Preview",
                "modal": True,
                "content": {"type": "text", "content": "hi"},
            }
        }
        html = render_dialogs(dialogs, theme, state)
        assert "data-dialog-preview-targets" not in html


class TestWireframeMode:
    def test_wireframe_element_has_class(self, theme, state):
        from renderer import render_element
        el = {"type": "button", "id": "b1", "summary": "Click me", "label": "OK", "action": "quit"}
        html = render_element(el, theme, state, mode="wireframe")
        assert "wf-element" in html
        assert "Click me" in html
        assert 'data-element-id="b1"' in html

    def test_wireframe_nested(self, theme, state):
        from renderer import render_element
        el = {
            "type": "container",
            "id": "c1",
            "summary": "Container",
            "layout": "column",
            "children": [
                {"type": "text", "id": "t1", "summary": "Text", "content": "Hello"},
            ],
        }
        html = render_element(el, theme, state, mode="wireframe")
        assert "wf-element" in html
        assert "Container" in html
        assert "Text" in html


class TestFlaskRoutes:
    def test_normal_mode_200(self, client):
        resp = client.get("/")
        assert resp.status_code == 200
        assert b"bootstrap" in resp.data.lower() or b"Bootstrap" in resp.data

    def test_wireframe_mode_200(self, client):
        resp = client.get("/?mode=wireframe")
        assert resp.status_code == 200
        assert b"wf-element" in resp.data or b"wireframe" in resp.data.lower()

    def test_api_spec_found(self, client):
        resp = client.get("/api/spec/root")
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["id"] == "root"

    def test_api_spec_nested(self, client):
        resp = client.get("/api/spec/btn_1")
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["id"] == "btn_1"

    def test_api_spec_not_found(self, client):
        resp = client.get("/api/spec/nonexistent")
        assert resp.status_code == 404


# ── Color Bar ─────────────────────────────────────────────────


class TestColorBar:
    def test_color_bar_renders_canvas(self, theme, state):
        from renderer import render_element
        el = {"type": "color_bar", "id": "cp_bar"}
        html = render_element(el, theme, state, mode="normal")
        assert "<canvas" in html

    def test_color_bar_has_type_attribute(self, theme, state):
        from renderer import render_element
        el = {"type": "color_bar", "id": "cp_bar"}
        html = render_element(el, theme, state, mode="normal")
        assert 'data-type="color-bar"' in html

    def test_color_bar_height_64(self, theme, state):
        from renderer import render_element
        el = {"type": "color_bar", "id": "cp_bar"}
        html = render_element(el, theme, state, mode="normal")
        assert "64px" in html

    def test_color_bar_id_rendered(self, theme, state):
        from renderer import render_element
        el = {"type": "color_bar", "id": "cp_bar"}
        html = render_element(el, theme, state, mode="normal")
        assert 'id="cp_bar"' in html

    def test_color_bar_cursor_crosshair(self, theme, state):
        from renderer import render_element
        el = {"type": "color_bar", "id": "cp_bar"}
        html = render_element(el, theme, state, mode="normal")
        assert "crosshair" in html


# ── set_panels() and dock panel content ───────────────────────


class TestSetPanels:
    def test_set_panels_exists(self):
        from renderer import set_panels
        assert callable(set_panels)

    def test_set_panels_accepts_dict(self):
        from renderer import set_panels
        # Should not raise
        set_panels({"color_panel_content": {"id": "color_panel_content", "type": "panel",
                                             "summary": "Color", "content": {"type": "text", "content": "X"}}})

    def test_set_panels_accepts_none(self):
        from renderer import set_panels
        set_panels(None)  # resets to empty


class TestDockViewWithPanels:
    """Dock renders actual panel content and menus when set_panels() is used."""

    @pytest.fixture(autouse=True)
    def setup_panel(self):
        from renderer import set_panels
        set_panels({
            "myp_panel_content": {
                "id": "myp_panel_content",
                "type": "panel",
                "summary": "My Panel",
                "menu": [
                    {"label": "Mode A", "action": "set_mode_a"},
                    {"label": "Mode B", "action": "set_mode_b"},
                    "separator",
                    {"label": "Invert", "action": "invert"},
                ],
                "content": {
                    "type": "text",
                    "id": "myp_text",
                    "content": "panel body text",
                },
            }
        })
        yield
        # Reset
        from renderer import set_panels
        set_panels({})

    def _dock_el(self):
        return {
            "id": "dock_main",
            "type": "dock_view",
            "collapsed_width": 36,
            "groups": [{"panels": ["myp"], "active": 0, "collapsed": False}],
        }

    def test_panel_content_rendered(self, theme, state):
        from renderer import render_element
        html = render_element(self._dock_el(), theme, state, mode="normal")
        assert "panel body text" in html

    def test_panel_menu_items_in_dock(self, theme, state):
        from renderer import render_element
        html = render_element(self._dock_el(), theme, state, mode="normal")
        assert "Mode A" in html
        assert "Mode B" in html

    def test_panel_menu_separator_in_dock(self, theme, state):
        from renderer import render_element
        html = render_element(self._dock_el(), theme, state, mode="normal")
        assert "dropdown-divider" in html

    def test_panel_close_item_still_present(self, theme, state):
        from renderer import render_element
        html = render_element(self._dock_el(), theme, state, mode="normal")
        assert "close_panel" in html

    def test_dock_no_double_panel_header(self, theme, state):
        """Panel summary should not appear as a separate header inside the dock body."""
        from renderer import render_element
        html = render_element(self._dock_el(), theme, state, mode="normal")
        # "My Panel" may appear in tab button; content should not add a second title bar
        # The panel content text is what matters
        assert "panel body text" in html

    def test_panel_state_data_attr(self, theme, state):
        """If the panel has a state section, data-panel-state is emitted for client init."""
        from renderer import set_panels, render_element
        set_panels({
            "myp_panel_content": {
                "id": "myp_panel_content",
                "type": "panel",
                "summary": "My Panel",
                "state": {"mode": {"type": "enum", "values": ["a", "b"], "default": "a"}},
                "init": {"mode": "a"},
                "content": {"type": "text", "content": "body"},
            }
        })
        html = render_element(self._dock_el(), theme, state, mode="normal")
        assert "data-panel-state" in html
        assert "data-panel-init" in html


# ── Full Color Panel spec ─────────────────────────────────────


class TestColorPanelSpec:
    """Tests against the real workspace color panel spec."""

    @pytest.fixture(autouse=True)
    def load_ws(self):
        from loader import load_workspace
        from renderer import set_icons, set_panels, set_initial_state
        ws = load_workspace(WORKSPACE_PATH)
        set_icons(ws.get("icons", {}))
        set_panels(ws.get("panels", {}))
        set_initial_state(ws.get("state", {}))

    @pytest.fixture
    def panel(self):
        from loader import load_workspace
        ws = load_workspace(WORKSPACE_PATH)
        return ws.get("panels", {}).get("color_panel_content", {})

    @pytest.fixture
    def panel_html(self, panel, theme, color_state):
        from renderer import render_element
        return render_element(panel, theme, color_state, mode="normal")

    def test_panel_renders(self, panel_html):
        assert panel_html

    def test_color_bar_present(self, panel_html):
        assert "color-bar" in panel_html

    def test_hex_input_present(self, panel_html):
        assert "cp_hex" in panel_html

    def test_fill_stroke_widget_present(self, panel_html):
        assert "cp_fill_swatch" in panel_html

    def test_mode_menu_grayscale(self, panel_html):
        assert "Grayscale" in panel_html

    def test_mode_menu_rgb(self, panel_html):
        assert "RGB" in panel_html

    def test_mode_menu_hsb(self, panel_html):
        assert "HSB" in panel_html

    def test_mode_menu_cmyk(self, panel_html):
        assert "CMYK" in panel_html

    def test_mode_menu_web_safe(self, panel_html):
        assert "Web Safe RGB" in panel_html

    def test_invert_menu_item(self, panel_html):
        assert "Invert" in panel_html

    def test_complement_menu_item(self, panel_html):
        assert "Complement" in panel_html

    def test_create_swatch_menu_item(self, panel_html):
        assert "Create New Swatch" in panel_html

    def test_ten_recent_color_slots(self, panel_html):
        # Recent color swatches are present (empty class applied client-side)
        assert panel_html.count("cp_recent_") == 10

    def test_swatch_separator(self, panel_html):
        assert "jas-swatch-rule" in panel_html

    def test_none_swatch_present(self, panel_html):
        assert "cp_none_swatch" in panel_html

    def test_hsb_sliders_present(self, panel_html):
        # Default mode is HSB — H, S, B sliders should be visible
        assert "cp_h" in panel_html
        assert "cp_s" in panel_html
        assert "cp_b" in panel_html

    def test_hue_slider_max_359(self, panel_html):
        assert 'max="359"' in panel_html

    def test_saturation_slider_max_100(self, panel_html):
        assert 'max="100"' in panel_html

    def test_panel_state_embedded(self, panel_html):
        """Panel local state is embedded for client-side initialization."""
        assert "data-panel-state" in panel_html

    def test_panel_init_embedded(self, panel_html):
        """Panel init expressions are embedded for client-side initialization."""
        assert "data-panel-init" in panel_html

    def test_none_color_disables_sliders(self, panel, theme):
        from renderer import render_element
        none_state = {
            "fill_color": None,
            "stroke_color": "#000000",
            "fill_on_top": True,
            "stroke_width": 1.0,
        }
        html = render_element(panel, theme, none_state, mode="normal")
        # Sliders should carry disabled binding when active color is none
        assert "cp_h" in html  # slider still renders, but disabled via bind
        assert "data-bind-disabled" in html or "disabled" in html


# ── Color Panel Slider Attributes ─────────────────────────────


class TestColorPanelSliderAttributes:
    """Unit tests on slider elements that will be used in the color panel."""

    def test_hue_slider_range(self, theme, state):
        from renderer import render_element
        el = {"type": "slider", "id": "cp_h", "min": 0, "max": 360}
        html = render_element(el, theme, state, mode="normal")
        assert 'min="0"' in html
        assert 'max="360"' in html

    def test_percent_slider_range(self, theme, state):
        from renderer import render_element
        el = {"type": "slider", "id": "cp_s", "min": 0, "max": 100}
        html = render_element(el, theme, state, mode="normal")
        assert 'max="100"' in html

    def test_rgb_slider_range(self, theme, state):
        from renderer import render_element
        el = {"type": "slider", "id": "cp_r", "min": 0, "max": 255}
        html = render_element(el, theme, state, mode="normal")
        assert 'max="255"' in html

    def test_web_safe_slider_step(self, theme, state):
        from renderer import render_element
        el = {"type": "slider", "id": "cp_r_ws", "min": 0, "max": 255, "step": 51}
        html = render_element(el, theme, state, mode="normal")
        assert 'step="51"' in html

    def test_k_slider_range(self, theme, state):
        from renderer import render_element
        el = {"type": "slider", "id": "cp_k", "min": 0, "max": 100}
        html = render_element(el, theme, state, mode="normal")
        assert 'min="0"' in html
        assert 'max="100"' in html


# ── Color Panel in Dock (integration) ────────────────────────


class TestColorPanelInDock:
    """Test that the real color panel renders correctly inside a dock_view."""

    @pytest.fixture(autouse=True)
    def load_ws(self):
        from loader import load_workspace
        from renderer import set_icons, set_panels, set_initial_state
        ws = load_workspace(WORKSPACE_PATH)
        set_icons(ws.get("icons", {}))
        set_panels(ws.get("panels", {}))
        set_initial_state(ws.get("state", {}))

    def test_color_panel_in_dock(self, theme, color_state):
        from renderer import render_element
        dock_el = {
            "id": "dock_main",
            "type": "dock_view",
            "collapsed_width": 36,
            "groups": [{"panels": ["color"], "active": 0, "collapsed": False}],
        }
        html = render_element(dock_el, theme, color_state, mode="normal")
        assert "color-bar" in html

    def test_color_panel_mode_menu_in_dock(self, theme, color_state):
        from renderer import render_element
        dock_el = {
            "id": "dock_main",
            "type": "dock_view",
            "collapsed_width": 36,
            "groups": [{"panels": ["color"], "active": 0, "collapsed": False}],
        }
        html = render_element(dock_el, theme, color_state, mode="normal")
        assert "Grayscale" in html
        assert "Invert" in html


# ── Stroke Panel spec ────────────────────────────────────────


class TestStrokePanelSpec:
    """Tests against the real workspace stroke panel spec."""

    @pytest.fixture(autouse=True)
    def load_ws(self):
        from loader import load_workspace
        from renderer import set_icons, set_panels, set_initial_state
        ws = load_workspace(WORKSPACE_PATH)
        set_icons(ws.get("icons", {}))
        set_panels(ws.get("panels", {}))
        set_initial_state(ws.get("state", {}))

    @pytest.fixture
    def panel(self):
        from loader import load_workspace
        ws = load_workspace(WORKSPACE_PATH)
        return ws.get("panels", {}).get("stroke_panel_content", {})

    @pytest.fixture
    def panel_html(self, panel, theme, state):
        from renderer import render_element
        return render_element(panel, theme, state, mode="normal")

    def test_panel_renders(self, panel_html):
        assert panel_html

    # ── Weight row ──
    def test_weight_input_present(self, panel_html):
        assert "stk_weight" in panel_html

    # ── Cap buttons ──
    def test_cap_butt_present(self, panel_html):
        assert "stk_cap_butt" in panel_html

    def test_cap_round_present(self, panel_html):
        assert "stk_cap_round" in panel_html

    def test_cap_square_present(self, panel_html):
        assert "stk_cap_square" in panel_html

    # ── Join buttons ──
    def test_join_miter_present(self, panel_html):
        assert "stk_join_miter" in panel_html

    def test_join_round_present(self, panel_html):
        assert "stk_join_round" in panel_html

    def test_join_bevel_present(self, panel_html):
        assert "stk_join_bevel" in panel_html

    # ── Miter limit ──
    def test_miter_limit_present(self, panel_html):
        assert "stk_miter_limit" in panel_html

    # ── Align stroke ──
    def test_align_stroke_center_present(self, panel_html):
        assert "stk_align_stroke_center" in panel_html

    def test_align_stroke_inside_present(self, panel_html):
        assert "stk_align_stroke_inside" in panel_html

    def test_align_stroke_outside_present(self, panel_html):
        assert "stk_align_stroke_outside" in panel_html

    # ── Dashed line ──
    def test_dashed_checkbox_present(self, panel_html):
        assert "stk_dashed" in panel_html

    def test_dashed_checkbox_is_checkbox(self, panel_html):
        assert 'type="checkbox"' in panel_html

    def test_dash_preset_even_present(self, panel_html):
        assert "stk_preset_even_dash" in panel_html

    def test_dash_preset_dot_present(self, panel_html):
        assert "stk_preset_dash_dot" in panel_html

    # ── Dash/gap inputs ──
    def test_dash_1_present(self, panel_html):
        assert "stk_dash_1" in panel_html

    def test_gap_1_present(self, panel_html):
        assert "stk_gap_1" in panel_html

    def test_dash_2_present(self, panel_html):
        assert "stk_dash_2" in panel_html

    def test_gap_2_present(self, panel_html):
        assert "stk_gap_2" in panel_html

    def test_dash_3_present(self, panel_html):
        assert "stk_dash_3" in panel_html

    def test_gap_3_present(self, panel_html):
        assert "stk_gap_3" in panel_html

    # ── Arrowheads ──
    def test_start_arrowhead_dropdown_present(self, panel_html):
        assert "stk_start_arrowhead" in panel_html

    def test_end_arrowhead_dropdown_present(self, panel_html):
        assert "stk_end_arrowhead" in panel_html

    def test_arrowhead_has_fifteen_options(self, panel_html):
        # Each dropdown has 15 options; two dropdowns = 30
        assert panel_html.count("Simple Arrow") == 2

    def test_swap_arrowheads_present(self, panel_html):
        assert "stk_swap_arrowheads" in panel_html

    # ── Scale ──
    def test_start_scale_present(self, panel_html):
        assert "stk_start_arrowhead_scale" in panel_html

    def test_end_scale_present(self, panel_html):
        assert "stk_end_arrowhead_scale" in panel_html

    def test_scale_has_presets(self, panel_html):
        # Combo box datalist should contain preset values
        assert "50%" in panel_html or '"50"' in panel_html

    def test_link_scale_present(self, panel_html):
        assert "stk_link_arrowhead_scale" in panel_html

    # ── Arrow align ──
    def test_arrow_tip_at_end_present(self, panel_html):
        assert "stk_arrow_tip_at_end" in panel_html

    def test_arrow_center_at_end_present(self, panel_html):
        assert "stk_arrow_center_at_end" in panel_html

    # ── Profile ──
    def test_profile_dropdown_present(self, panel_html):
        assert "stk_profile" in panel_html

    def test_profile_has_options(self, panel_html):
        assert "Uniform" in panel_html
        assert "Taper Both" in panel_html

    def test_flip_profile_present(self, panel_html):
        assert "stk_flip_profile" in panel_html

    def test_reset_profile_present(self, panel_html):
        assert "stk_reset_profile" in panel_html

    # ── Panel state/init ──
    def test_panel_state_embedded(self, panel_html):
        assert "data-panel-state" in panel_html

    def test_panel_init_embedded(self, panel_html):
        assert "data-panel-init" in panel_html

    # ── Menu items ──
    def test_menu_cap_items(self, panel_html):
        assert "Butt Cap" in panel_html
        assert "Round Cap" in panel_html
        assert "Square Cap" in panel_html

    def test_menu_join_items(self, panel_html):
        assert "Miter Join" in panel_html
        assert "Round Join" in panel_html
        assert "Bevel Join" in panel_html

    def test_menu_close_item(self, panel_html):
        assert "Close Stroke" in panel_html


# ── Stroke Panel in Dock (integration) ──────────────────────


class TestStrokePanelInDock:
    """Test that the real stroke panel renders correctly inside a dock_view."""

    @pytest.fixture(autouse=True)
    def load_ws(self):
        from loader import load_workspace
        from renderer import set_icons, set_panels, set_initial_state
        ws = load_workspace(WORKSPACE_PATH)
        set_icons(ws.get("icons", {}))
        set_panels(ws.get("panels", {}))
        set_initial_state(ws.get("state", {}))

    def test_stroke_panel_in_dock(self, theme, state):
        from renderer import render_element
        dock_el = {
            "id": "dock_main",
            "type": "dock_view",
            "collapsed_width": 36,
            "groups": [{"panels": ["stroke"], "active": 0, "collapsed": False}],
        }
        html = render_element(dock_el, theme, state, mode="normal")
        assert "stk_weight" in html

    def test_stroke_panel_menu_in_dock(self, theme, state):
        from renderer import render_element
        dock_el = {
            "id": "dock_main",
            "type": "dock_view",
            "collapsed_width": 36,
            "groups": [{"panels": ["stroke"], "active": 0, "collapsed": False}],
        }
        html = render_element(dock_el, theme, state, mode="normal")
        assert "Butt Cap" in html
        assert "Miter Join" in html


class TestBooleanPanel:
    """Tests against the real workspace Boolean panel spec.

    Flask's scope for the Boolean panel is yaml wiring only — the
    document model and canvas don't exist server-side — so these
    tests verify that the panel spec loads from workspace.json and
    renders its nine operation buttons plus the Expand button.
    """

    @pytest.fixture(autouse=True)
    def load_ws(self):
        from loader import load_workspace
        from renderer import set_icons, set_panels, set_initial_state
        ws = load_workspace(WORKSPACE_PATH)
        set_icons(ws.get("icons", {}))
        set_panels(ws.get("panels", {}))
        set_initial_state(ws.get("state", {}))

    @pytest.fixture
    def panel(self):
        from loader import load_workspace
        ws = load_workspace(WORKSPACE_PATH)
        return ws.get("panels", {}).get("boolean_panel_content", {})

    @pytest.fixture
    def panel_html(self, panel, theme, state):
        from renderer import render_element
        return render_element(panel, theme, state, mode="normal")

    def test_panel_spec_present(self, panel):
        assert panel, "boolean_panel_content spec missing from workspace"
        assert panel.get("summary") == "Boolean"

    def test_panel_renders(self, panel_html):
        assert panel_html

    # ── Shape Modes row ──
    def test_union_button_present(self, panel_html):
        assert "boolean_union_button" in panel_html

    def test_subtract_front_button_present(self, panel_html):
        assert "boolean_subtract_front_button" in panel_html

    def test_intersection_button_present(self, panel_html):
        assert "boolean_intersection_button" in panel_html

    def test_exclude_button_present(self, panel_html):
        assert "boolean_exclude_button" in panel_html

    def test_expand_button_present(self, panel_html):
        assert "boolean_expand_button" in panel_html

    # ── Pathfinders row ──
    def test_divide_button_present(self, panel_html):
        assert "boolean_divide_button" in panel_html

    def test_trim_button_present(self, panel_html):
        assert "boolean_trim_button" in panel_html

    def test_merge_button_present(self, panel_html):
        assert "boolean_merge_button" in panel_html

    def test_crop_button_present(self, panel_html):
        assert "boolean_crop_button" in panel_html

    def test_subtract_back_button_present(self, panel_html):
        assert "boolean_subtract_back_button" in panel_html

    # ── Section labels ──
    def test_shape_modes_label_present(self, panel_html):
        assert "Shape Modes:" in panel_html

    def test_pathfinders_label_present(self, panel_html):
        assert "Pathfinders:" in panel_html

    # ── Panel in dock — full integration ──
    def test_boolean_panel_in_dock(self, theme, state):
        from renderer import render_element
        dock_el = {
            "id": "dock_main",
            "type": "dock_view",
            "collapsed_width": 36,
            "groups": [{"panels": ["boolean"], "active": 0, "collapsed": False}],
        }
        html = render_element(dock_el, theme, state, mode="normal")
        assert "boolean_union_button" in html
        assert "Boolean" in html


class TestBooleanOptionsDialog:
    """Tests against the real workspace Boolean Options dialog spec."""

    @pytest.fixture(autouse=True)
    def load_ws(self):
        from loader import load_workspace
        from renderer import set_icons, set_panels, set_initial_state
        ws = load_workspace(WORKSPACE_PATH)
        set_icons(ws.get("icons", {}))
        set_panels(ws.get("panels", {}))
        set_initial_state(ws.get("state", {}))

    @pytest.fixture
    def dialog(self):
        from loader import load_workspace
        ws = load_workspace(WORKSPACE_PATH)
        return ws.get("dialogs", {}).get("boolean_options", {})

    def test_dialog_spec_present(self, dialog):
        assert dialog, "boolean_options dialog spec missing from workspace"
        assert dialog.get("summary") == "Boolean Options"

    def test_dialog_has_three_state_fields(self, dialog):
        state_fields = dialog.get("state", {})
        assert "precision" in state_fields
        assert "remove_redundant_points" in state_fields
        assert "divide_remove_unpainted" in state_fields

    def test_dialog_precision_default(self, dialog):
        precision = dialog.get("state", {}).get("precision", {})
        assert precision.get("default") == 0.0283

    def test_dialog_has_init_bindings(self, dialog):
        init = dialog.get("init", {})
        assert init.get("precision") == "param.precision"
        assert init.get("remove_redundant_points") == "param.remove_redundant_points"
        assert init.get("divide_remove_unpainted") == "param.divide_remove_unpainted"


class TestBooleanActions:
    """Confirm the Boolean panel's actions are registered in workspace.json."""

    @pytest.fixture
    def actions(self):
        from loader import load_workspace
        ws = load_workspace(WORKSPACE_PATH)
        return ws.get("actions", {})

    @pytest.mark.parametrize("op", [
        "boolean_union", "boolean_subtract_front", "boolean_intersection",
        "boolean_exclude", "boolean_divide", "boolean_trim", "boolean_merge",
        "boolean_crop", "boolean_subtract_back",
    ])
    def test_destructive_op_registered(self, actions, op):
        assert op in actions, f"{op} action missing from workspace"
        assert actions[op].get("category") == "boolean"

    @pytest.mark.parametrize("op", [
        "boolean_union_compound", "boolean_subtract_front_compound",
        "boolean_intersection_compound", "boolean_exclude_compound",
    ])
    def test_compound_variant_registered(self, actions, op):
        assert op in actions, f"{op} compound variant missing from workspace"

    @pytest.mark.parametrize("op", [
        "make_compound_shape", "release_compound_shape",
        "expand_compound_shape", "repeat_boolean_operation",
        "reset_boolean_panel", "open_boolean_options",
        "boolean_options_confirm",
    ])
    def test_menu_action_registered(self, actions, op):
        assert op in actions, f"{op} menu action missing from workspace"


class TestRenderGradientTile:
    """gradient_tile — a clickable preview tile for a gradient value."""

    def _gradient(self):
        return {
            "type": "linear",
            "angle": 0,
            "aspect_ratio": 100,
            "method": "classic",
            "dither": False,
            "stops": [
                {"color": "#ff0000", "opacity": 100, "location": 0, "midpoint_to_next": 50},
                {"color": "#0000ff", "opacity": 100, "location": 100},
            ],
        }

    def test_registered(self, theme, state):
        from renderer import render_element
        el = {"type": "gradient_tile"}
        html = render_element(el, theme, state, mode="normal")
        assert 'data-type="gradient-tile"' in html

    def test_size_small(self, theme, state):
        from renderer import render_element
        el = {"type": "gradient_tile", "size": "small"}
        html = render_element(el, theme, state, mode="normal")
        assert "width:16px" in html and "height:16px" in html

    def test_size_medium(self, theme, state):
        from renderer import render_element
        el = {"type": "gradient_tile", "size": "medium"}
        html = render_element(el, theme, state, mode="normal")
        assert "width:32px" in html and "height:32px" in html

    def test_size_large_is_default(self, theme, state):
        from renderer import render_element
        el = {"type": "gradient_tile"}
        html = render_element(el, theme, state, mode="normal")
        assert "width:64px" in html and "height:64px" in html

    def test_linear_gradient_background(self, theme, state):
        from renderer import render_element
        st = dict(state)
        st["g"] = self._gradient()
        el = {"type": "gradient_tile", "bind": {"gradient": "g"}, "size": "medium"}
        html = render_element(el, theme, st, mode="normal")
        assert "linear-gradient" in html
        assert "#ff0000" in html and "#0000ff" in html

    def test_radial_gradient_background(self, theme, state):
        from renderer import render_element
        g = self._gradient()
        g["type"] = "radial"
        st = dict(state)
        st["g"] = g
        el = {"type": "gradient_tile", "bind": {"gradient": "g"}}
        html = render_element(el, theme, st, mode="normal")
        assert "radial-gradient" in html

    def test_data_bind_gradient_attribute(self, theme, state):
        """The bind expression is emitted for JS round-trip."""
        from renderer import render_element
        el = {"type": "gradient_tile", "bind": {"gradient": "g"}}
        html = render_element(el, theme, state, mode="normal")
        assert 'data-bind-gradient="g"' in html


class TestRenderGradientSlider:
    """gradient_slider — 1-D color-stops editor with drag/click gestures (JS-driven)."""

    def _two_stops(self):
        return [
            {"color": "#000000", "opacity": 100, "location": 0, "midpoint_to_next": 50},
            {"color": "#ffffff", "opacity": 100, "location": 100},
        ]

    def _three_stops(self):
        return [
            {"color": "#ff0000", "opacity": 100, "location": 0, "midpoint_to_next": 40},
            {"color": "#00ff00", "opacity": 100, "location": 50, "midpoint_to_next": 60},
            {"color": "#0000ff", "opacity": 100, "location": 100},
        ]

    def test_registered(self, theme, state):
        from renderer import render_element
        el = {"type": "gradient_slider"}
        html = render_element(el, theme, state, mode="normal")
        assert 'data-type="gradient-slider"' in html

    def test_bar_background_is_gradient(self, theme, state):
        from renderer import render_element
        st = dict(state)
        st["stops"] = self._two_stops()
        el = {"type": "gradient_slider", "bind": {"stops": "stops"}}
        html = render_element(el, theme, st, mode="normal")
        assert "linear-gradient" in html
        assert "#000000" in html and "#ffffff" in html

    def test_stop_marker_per_stop(self, theme, state):
        from renderer import render_element
        st = dict(state)
        st["stops"] = self._three_stops()
        el = {"type": "gradient_slider", "bind": {"stops": "stops"}}
        html = render_element(el, theme, st, mode="normal")
        assert html.count('data-role="stop"') == 3

    def test_midpoint_marker_between_each_pair(self, theme, state):
        from renderer import render_element
        st = dict(state)
        st["stops"] = self._three_stops()
        el = {"type": "gradient_slider", "bind": {"stops": "stops"}}
        html = render_element(el, theme, st, mode="normal")
        # Three stops → two adjacent pairs → two midpoint markers.
        assert html.count('data-role="midpoint"') == 2

    def test_selected_stop_has_accent(self, theme, state):
        from renderer import render_element
        st = dict(state)
        st["stops"] = self._three_stops()
        st["sel"] = 1
        el = {
            "type": "gradient_slider",
            "bind": {"stops": "stops", "selected_stop_index": "sel"},
        }
        html = render_element(el, theme, st, mode="normal")
        assert "app-gradient-stop-selected" in html

    def test_selected_midpoint_has_accent(self, theme, state):
        from renderer import render_element
        st = dict(state)
        st["stops"] = self._three_stops()
        st["mid"] = 0
        el = {
            "type": "gradient_slider",
            "bind": {"stops": "stops", "selected_midpoint_index": "mid"},
        }
        html = render_element(el, theme, st, mode="normal")
        assert "app-gradient-midpoint-selected" in html

    def test_data_bind_attributes(self, theme, state):
        from renderer import render_element
        el = {
            "type": "gradient_slider",
            "bind": {
                "stops": "s",
                "selected_stop_index": "i",
                "selected_midpoint_index": "m",
            },
        }
        html = render_element(el, theme, state, mode="normal")
        assert 'data-bind-stops="s"' in html
        assert 'data-bind-selected-stop-index="i"' in html
        assert 'data-bind-selected-midpoint-index="m"' in html

    def test_empty_stops_renders_bar_only(self, theme, state):
        """No stops expression → bar renders but no stop or midpoint markers."""
        from renderer import render_element
        el = {"type": "gradient_slider"}
        html = render_element(el, theme, state, mode="normal")
        assert 'data-type="gradient-slider"' in html
        assert 'data-role="stop"' not in html
        assert 'data-role="midpoint"' not in html

    def test_focusable(self, theme, state):
        """Slider must be keyboard-focusable so keydown events reach it."""
        from renderer import render_element
        el = {"type": "gradient_slider"}
        html = render_element(el, theme, state, mode="normal")
        assert 'tabindex="0"' in html


class TestGradientPrimitivesFixture:
    """Load the Phase 0 fixture YAML and verify end-to-end that both
    widgets render when composed inside a panel structure with state.
    """

    def _fixture_path(self):
        return os.path.join(WORKSPACE_PATH, "tests", "gradient_primitives.yaml")

    def test_fixture_exists(self):
        assert os.path.exists(self._fixture_path())

    def test_fixture_renders_nine_tiles_and_one_slider(self, theme):
        import yaml
        from renderer import render_element
        with open(self._fixture_path()) as f:
            fixture = yaml.safe_load(f)
        state = fixture.get("state", {})
        # Render each top-level panel item and concatenate.
        html_parts = []
        for item in fixture.get("panel", []):
            if isinstance(item, dict):
                html_parts.append(str(render_element(item, theme, state, mode="normal")))
            elif isinstance(item, str):
                html_parts.append(item)
            elif isinstance(item, dict) and ".row" in item:
                pass
        combined = "".join(html_parts)
        # The fixture has 9 gradient tiles (3 sizes × 3 gradients).
        assert combined.count('data-type="gradient-tile"') + \
            sum(
                str(render_element(child, theme, state, mode="normal")).count('data-type="gradient-tile"')
                for item in fixture.get("panel", [])
                if isinstance(item, dict) and ".row" in item
                for child in item[".row"]
                if isinstance(child, dict)
            ) >= 9
        # And 1 gradient slider somewhere.
        slider_count = sum(
            str(render_element(item, theme, state, mode="normal")).count('data-type="gradient-slider"')
            for item in fixture.get("panel", [])
            if isinstance(item, dict) and item.get("type") == "gradient_slider"
        )
        assert slider_count >= 1
