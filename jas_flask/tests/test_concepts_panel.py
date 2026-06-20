"""Integration tests of the jas workspace Concepts panel spec.

NOTE — scope. Like the other panel tests here, these are NOT generic Flask
renderer tests; they assert fields specific to workspace/panels/concepts.yaml
(CONCEPTS.md §6). The Flask renderer is just the easiest driver to exercise the
panel spec — including the foreach over the data.concepts registry list — end to
end. Spec source: workspace/panels/concepts.yaml.
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
            "bg": "#000", "text": "#ccc", "border": "#555",
            "selection": "#3b72c6", "pane_bg_dark": "#222", "text_dim": "#666",
            "button_checked": "#505050",
        },
        "fonts": {"default": {"family": "sans-serif", "size": 12}},
        "sizes": {"tool_button": 32, "title_bar_height": 20},
    }


class TestConceptsPanel:
    @pytest.fixture(autouse=True)
    def load_ws(self):
        from loader import load_workspace
        from renderer import set_icons, set_panels, set_initial_state, set_workspace_data
        from app import _collect_workspace_data
        ws = load_workspace(WORKSPACE_PATH)
        set_icons(ws.get("icons", {}))
        set_panels(ws.get("panels", {}))
        set_initial_state(ws.get("state", {}))
        set_workspace_data(_collect_workspace_data(ws))

    @pytest.fixture
    def panel(self):
        from loader import load_workspace
        ws = load_workspace(WORKSPACE_PATH)
        return ws.get("panels", {}).get("concepts_panel_content", {})

    def test_panel_spec_present(self, panel):
        assert panel, "concepts_panel_content spec missing from workspace"
        assert panel.get("summary") == "Concepts"

    def test_state_selected_concept_nullable_string(self, panel):
        entry = panel.get("state", {}).get("selected_concept")
        assert entry is not None
        assert entry.get("type") == "string"
        assert entry.get("nullable") is True

    def test_panel_foreach_over_data_concepts(self, panel):
        # The row list iterates the registry-derived data.concepts list.
        content = panel.get("content", {})

        def find_foreach(el):
            if isinstance(el, dict):
                if "foreach" in el:
                    return el
                for c in el.get("children", []) or []:
                    f = find_foreach(c)
                    if f:
                        return f
            return None

        fe = find_foreach(content)
        assert fe is not None, "concept row list (a foreach) missing"
        assert fe["foreach"]["source"] == "data.concepts"
        assert fe["foreach"]["as"] == "concept"

    def test_data_concepts_exposed_as_sorted_list(self):
        # The app exposes the concept registry as a data.concepts list of
        # {id, name, description}, the source the panel's foreach reads. (Flask's
        # legacy server renderer can't interpolate loop-var text, so we assert the
        # data exposure — the native apps render the rows via evaluate_text.)
        import os as _os
        import sys as _sys
        _sys.path.insert(0, _os.path.join(_os.path.dirname(__file__), ".."))
        from loader import load_workspace
        from app import _collect_workspace_data
        ws = load_workspace(WORKSPACE_PATH)
        concepts = _collect_workspace_data(ws)["concepts"]
        assert [c["id"] for c in concepts] == ["gear", "regular_polygon", "spiral", "star"]
        names = {c["name"] for c in concepts}
        assert {"Gear", "Regular Polygon", "Spiral", "Star"} <= names
