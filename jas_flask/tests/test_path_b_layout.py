"""Path B: Flask renders panels from the shared canonical layout pass.

With JAS_PATH_B=1, _render_panel places each leaf widget in an absolutely-
positioned box at the rect computed by workspace_interpreter.panel_layout (the
same pass the four native apps byte-gate). This is the human-viewable reference
of the canonical layout (TESTING_STRATEGY.md §6 / §7.7). Default mode is unchanged
Bootstrap flex.
"""
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))        # jas_flask
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))  # repo root (workspace_interpreter)

BUNDLE = os.path.join(os.path.dirname(__file__), "..", "..", "workspace", "workspace.json")


@pytest.fixture
def theme():
    return {
        "colors": {"bg": "#000", "text": "#ccc", "border": "#555", "button_checked": "#505050"},
        "fonts": {"default": {"family": "sans-serif", "size": 12}},
        "sizes": {"tool_button": 32, "title_bar_height": 20},
    }


@pytest.fixture
def panels():
    import renderer
    b = json.load(open(BUNDLE))
    renderer.set_panels(b.get("panels", {}))
    renderer.set_icons(b.get("icons", {}))
    return b["panels"]


def test_opacity_panel_absolute_mode(theme, panels, monkeypatch):
    """Opacity renders from the pass: a relative 228px wrapper with leaves at
    the canonical golden rects."""
    monkeypatch.setenv("JAS_PATH_B", "1")
    from renderer import render_element
    html = render_element(panels["opacity_panel_content"], theme, {}, mode="normal")
    assert "position:relative;width:228px" in html
    # golden rects: op_mode select [0,0] and op_disclosure icon_button [0,3]
    assert "position:absolute;left:4px;top:6px;width:73px;height:20px" in html
    assert "position:absolute;left:205px;top:4px;width:24px;height:24px" in html


def test_composite_panel_stays_flex(theme, panels, monkeypatch):
    """color/gradient/layers are excluded from absolute mode (composite widgets
    not drawn yet), so they keep the flex path."""
    monkeypatch.setenv("JAS_PATH_B", "1")
    from renderer import render_element
    html = render_element(panels["color_panel_content"], theme, {}, mode="normal")
    assert "position:relative;width:228px" not in html


def test_default_mode_is_flex(theme, panels):
    """Without the flag, panels render via Bootstrap flex (no absolute wrapper)."""
    from renderer import render_element
    html = render_element(panels["opacity_panel_content"], theme, {}, mode="normal")
    assert "position:relative;width:228px" not in html
