"""Tests for renderer.py — element-to-HTML rendering for normal and wireframe modes."""

import os
import sys
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


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
        assert "P1" in html


class TestRenderPane:
    def test_absolute_position(self, theme, state):
        from renderer import render_element
        el = {
            "id": "tp",
            "type": "pane",
            "summary": "Test",
            "default_position": {"x": 10, "y": 20, "width": 300, "height": 400},
            "title_bar": {"label": "Test Pane", "draggable": True, "closeable": True},
            "content": {"type": "placeholder", "summary": "Content"},
        }
        html = render_element(el, theme, state, mode="normal")
        assert "position" in html
        assert "absolute" in html
        assert "left:10px" in html or "left: 10px" in html
        assert "Test Pane" in html

    def test_close_button_when_closeable(self, theme, state):
        from renderer import render_element
        el = {
            "id": "tp",
            "type": "pane",
            "summary": "Test",
            "default_position": {"x": 0, "y": 0, "width": 100, "height": 100},
            "title_bar": {"label": "T", "draggable": True, "closeable": True},
            "content": {"type": "placeholder", "summary": "C"},
        }
        html = render_element(el, theme, state, mode="normal")
        assert "btn-close" in html


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
