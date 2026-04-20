"""Tests against the real workspace Artboards panel spec.

Flask's phase-1 scope for Artboards is yaml wiring only — the document
model and canvas don't exist server-side (same posture as Boolean /
Align). These tests verify that the panel spec loads, has the required
state and menu entries, and that its panel body + footer structure is
present in the rendered HTML.

Spec source: workspace/panels/artboards.yaml.
Design doc: transcripts/ARTBOARDS.md.
"""

import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

WORKSPACE_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "workspace")


@pytest.fixture
def theme():
    return {
        "colors": {
            "bg": "#000",
            "text": "#ccc",
            "border": "#555",
            "selection": "#3b72c6",
            "pane_bg_dark": "#222",
            "text_dim": "#666",
            "button_checked": "#505050",
        },
        "fonts": {"default": {"family": "sans-serif", "size": 12}},
        "sizes": {"tool_button": 32, "title_bar_height": 20},
    }


@pytest.fixture
def state():
    return {"active_tool": "pen"}


class TestArtboardsPanel:
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
        return ws.get("panels", {}).get("artboards_panel_content", {})

    @pytest.fixture
    def panel_html(self, panel, theme, state):
        from renderer import render_element
        return render_element(panel, theme, state, mode="normal")

    # ── Panel spec loads ───────────────────────────────────────

    def test_panel_spec_present(self, panel):
        assert panel, "artboards_panel_content spec missing from workspace"
        assert panel.get("summary") == "Artboards"

    def test_panel_renders(self, panel_html):
        assert panel_html

    # ── State block carries phase-1 fields ─────────────────────

    def test_state_artboards_panel_selection(self, panel):
        state_defs = panel.get("state", {})
        entry = state_defs.get("artboards_panel_selection")
        assert entry is not None
        assert entry.get("type") == "list"
        assert entry.get("item_type") == "string"

    def test_state_renaming_artboard_nullable_string(self, panel):
        state_defs = panel.get("state", {})
        entry = state_defs.get("renaming_artboard")
        assert entry is not None
        assert entry.get("type") == "string"
        assert entry.get("nullable") is True

    def test_state_reference_point_enum_center_default(self, panel):
        state_defs = panel.get("state", {})
        entry = state_defs.get("reference_point")
        assert entry is not None
        assert entry.get("type") == "enum"
        assert entry.get("default") == "center"
        assert entry.get("persist") is True
        anchors = entry.get("values", [])
        assert "center" in anchors
        assert "top_left" in anchors
        assert "bottom_right" in anchors
        assert len(anchors) == 9

    def test_state_rearrange_dirty_bool(self, panel):
        state_defs = panel.get("state", {})
        entry = state_defs.get("rearrange_dirty")
        assert entry is not None
        assert entry.get("type") == "bool"
        assert entry.get("default") is False

    # ── Menu entries per spec ──────────────────────────────────

    def test_menu_contains_all_entries(self, panel):
        menu = panel.get("menu", [])
        labels = [m.get("label") for m in menu if isinstance(m, dict)]
        assert "New Artboard" in labels
        assert "Duplicate Artboards" in labels
        assert "Delete Artboards" in labels
        assert "Rename" in labels
        assert "Delete Empty Artboards" in labels
        assert "Convert to Artboards" in labels
        assert "Artboard Options..." in labels
        assert "Rearrange..." in labels
        assert "Reset Panel" in labels

    def test_menu_convert_to_artboards_deferred(self, panel):
        """Convert to Artboards is phase-1 deferred: enabled_when: 'false'."""
        menu = panel.get("menu", [])
        entry = next((m for m in menu if isinstance(m, dict) and m.get("label") == "Convert to Artboards"), None)
        assert entry is not None
        assert entry.get("enabled_when") == "false"

    def test_menu_rearrange_deferred(self, panel):
        menu = panel.get("menu", [])
        entry = next((m for m in menu if isinstance(m, dict) and m.get("label") == "Rearrange..."), None)
        assert entry is not None
        assert entry.get("enabled_when") == "false"

    def test_menu_delete_artboards_respects_invariant(self, panel):
        menu = panel.get("menu", [])
        entry = next((m for m in menu if isinstance(m, dict) and m.get("label") == "Delete Artboards"), None)
        assert entry is not None
        expr = entry.get("enabled_when", "")
        # Must reference both non-empty selection AND room-for-one-remaining
        assert "artboards_panel_selection_ids" in expr
        assert "artboards_count" in expr

    # ── Row rendering — foreach pattern ────────────────────────

    def test_content_has_foreach_row_list(self, panel):
        """The panel body's row-list container uses foreach over
        active_document.artboards."""
        content = panel.get("content", {})
        children = content.get("children", [])
        list_container = next(
            (c for c in children if isinstance(c, dict) and c.get("id") == "ap_list"),
            None,
        )
        assert list_container is not None
        assert list_container.get("foreach", {}).get("source") == "active_document.artboards"
        assert list_container.get("foreach", {}).get("as") == "ab"

    def test_row_template_has_three_cells(self, panel):
        content = panel.get("content", {})
        children = content.get("children", [])
        list_container = next(c for c in children if isinstance(c, dict) and c.get("id") == "ap_list")
        row = list_container.get("do", {})
        cell_ids = [ch.get("id") for ch in row.get("children", []) if isinstance(ch, dict)]
        assert "ap_number" in cell_ids
        assert "ap_name" in cell_ids
        assert "ap_options" in cell_ids

    def test_row_selection_background_bound(self, panel):
        content = panel.get("content", {})
        children = content.get("children", [])
        list_container = next(c for c in children if isinstance(c, dict) and c.get("id") == "ap_list")
        row = list_container.get("do", {})
        bg_expr = row.get("bind", {}).get("background", "")
        assert "mem(ab.id" in bg_expr
        assert "artboards_panel_selection_ids" in bg_expr

    # ── Footer has the five required buttons in order ──────────

    def test_footer_has_five_buttons(self, panel):
        content = panel.get("content", {})
        children = content.get("children", [])
        footer = next(
            (c for c in children if isinstance(c, dict) and c.get("id") == "ap_footer"),
            None,
        )
        assert footer is not None
        btn_ids = [ch.get("id") for ch in footer.get("children", []) if isinstance(ch, dict) and ch.get("type") == "icon_button"]
        assert btn_ids == [
            "ap_rearrange",
            "ap_move_up",
            "ap_move_down",
            "ap_new",
            "ap_delete",
        ]

    def test_footer_rearrange_deferred_grayed(self, panel):
        content = panel.get("content", {})
        footer = next(c for c in content.get("children", []) if isinstance(c, dict) and c.get("id") == "ap_footer")
        rearrange = next(ch for ch in footer.get("children", []) if isinstance(ch, dict) and ch.get("id") == "ap_rearrange")
        assert rearrange.get("bind", {}).get("disabled") == "true"

    def test_footer_delete_respects_invariant(self, panel):
        content = panel.get("content", {})
        footer = next(c for c in content.get("children", []) if isinstance(c, dict) and c.get("id") == "ap_footer")
        delete = next(ch for ch in footer.get("children", []) if isinstance(ch, dict) and ch.get("id") == "ap_delete")
        expr = delete.get("bind", {}).get("disabled", "")
        assert "artboards_panel_selection_ids" in expr
        assert "artboards_count" in expr

    def test_footer_new_artboard_always_enabled(self, panel):
        content = panel.get("content", {})
        footer = next(c for c in content.get("children", []) if isinstance(c, dict) and c.get("id") == "ap_footer")
        new_btn = next(ch for ch in footer.get("children", []) if isinstance(ch, dict) and ch.get("id") == "ap_new")
        # No disabled bind means always enabled
        assert "disabled" not in new_btn.get("bind", {})

    # ── Keyboard shortcuts ─────────────────────────────────────

    def test_keyboard_map_has_expected_shortcuts(self, panel):
        keys = {kb.get("key"): kb.get("action") for kb in panel.get("keyboard", []) if isinstance(kb, dict)}
        assert keys.get("Delete") == "delete_artboards"
        assert keys.get("Backspace") == "delete_artboards"
        assert keys.get("F2") == "rename_artboard"
        assert keys.get("Enter") == "rename_artboard"
        assert keys.get("Meta+A") == "artboards_select_all"
        assert keys.get("Alt+ArrowUp") == "move_artboard_up"
        assert keys.get("Alt+ArrowDown") == "move_artboard_down"

    # ── Full dock integration: panel renders inside a dock ─────

    def test_artboards_panel_in_dock(self, theme, state):
        from renderer import render_element
        dock_el = {
            "id": "dock_main",
            "type": "dock_view",
            "collapsed_width": 36,
            "groups": [{"panels": ["artboards"], "active": 0, "collapsed": False}],
        }
        html = render_element(dock_el, theme, state, mode="normal")
        assert "ap_list" in html or "Artboards" in html
