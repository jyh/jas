"""Smoke tests for the /canvas demo route and the /api/workspace endpoint
used by the thick-client JS engine.

These tests only verify server-side wiring (route registration, HTML
shape, JSON shape) — the actual JS engine is tested under
jas_flask/tests/js/ via Node.
"""

import pytest


@pytest.fixture
def client(workspace_path):
    """Create a Flask test client. workspace_path comes from conftest."""
    from app import create_app
    app = create_app(workspace_path=workspace_path)
    app.config["TESTING"] = True
    return app.test_client()


class TestCanvasRoute:
    def test_canvas_page_serves(self, client):
        r = client.get("/canvas")
        assert r.status_code == 200
        body = r.data.decode("utf-8")
        assert "<svg id=\"doc-layer\"" in body
        assert "<svg id=\"selection-layer\"" in body
        assert "<svg id=\"overlay-layer\"" in body

    def test_canvas_page_imports_engine(self, client):
        body = client.get("/canvas").data.decode("utf-8")
        # The page loads the engine modules via static URLs.
        for mod in (
            "model.mjs", "store.mjs", "tools.mjs",
            "document.mjs", "canvas.mjs", "scope.mjs",
        ):
            assert mod in body, f"canvas page should import engine/{mod}"

    def test_canvas_page_wires_mouse_events(self, client):
        body = client.get("/canvas").data.decode("utf-8")
        for evt in ("mousedown", "mousemove", "mouseup", "keydown"):
            assert evt in body, f"canvas page should wire {evt}"


class TestWorkspaceApi:
    def test_api_workspace_returns_json(self, client):
        r = client.get("/api/workspace")
        assert r.status_code == 200
        assert r.is_json
        data = r.get_json()
        # Must include the sections the JS engine needs.
        assert "tools" in data
        assert "selection" in data["tools"]
        assert data["schema_version"] == "2.0"

    def test_api_workspace_tool_shape(self, client):
        r = client.get("/api/workspace")
        tool = r.get_json()["tools"]["selection"]
        assert tool["id"] == "selection"
        assert "handlers" in tool
        assert "on_mousedown" in tool["handlers"]
        assert "overlay" in tool
