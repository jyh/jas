"""Smoke tests for the /api/workspace endpoint used by the thick-client
JS engine. The endpoint is consumed by canvas_bootstrap.mjs to seed the
engine's tool registry.
"""

import pytest


@pytest.fixture
def client(workspace_path):
    """Create a Flask test client. workspace_path comes from conftest."""
    from app import create_app
    app = create_app(workspace_path=workspace_path)
    app.config["TESTING"] = True
    return app.test_client()


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
