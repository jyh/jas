"""Pytest fixtures for python_flask tests."""

import os
import pytest


WORKSPACE_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..", "workspace"
)


@pytest.fixture
def workspace_path():
    """Path to the real WORKSPACE.yaml."""
    return WORKSPACE_PATH


@pytest.fixture
def sample_workspace():
    """Minimal valid workspace dict for unit tests."""
    return {
        "version": 1,
        "app": {
            "name": "Test",
            "description": "Test app",
            "window": {"width": 800, "height": 600},
        },
        "theme": {
            "active": "dark_gray",
            "base": {
                "colors": {"bg": "#000000", "text": "#ffffff", "pane_shadow": "rgba(0,0,0,0.3)"},
                "fonts": {"default": {"family": "sans-serif", "size": 12}},
                "sizes": {"button": 32},
            },
            "metrics": {
                "snap_distance": 6,
            },
            "appearances": {
                "dark_gray": {"label": "Dark Gray"},
            },
        },
        "state": {
            "active_tool": {
                "type": "enum",
                "values": ["pen", "rect"],
                "default": "pen",
                "description": "Current tool",
            }
        },
        "actions": {
            "select_tool": {
                "description": "Switch tool",
                "category": "tool",
                "params": {"tool": {"type": "state_ref", "ref": "active_tool"}},
            },
            "quit": {
                "description": "Exit",
                "category": "file",
            },
        },
        "shortcuts": [
            {"key": "P", "action": "select_tool", "params": {"tool": "pen"}},
            {"key": "Ctrl+Q", "action": "quit"},
        ],
        "menubar": [
            {
                "id": "file_menu",
                "label": "&File",
                "items": [
                    {"id": "quit", "label": "&Quit", "action": "quit", "shortcut": "Ctrl+Q"},
                ],
            }
        ],
        "layout": {
            "id": "root",
            "type": "pane_system",
            "summary": "Main",
            "description": "Root pane system",
            "children": [
                {
                    "id": "pane_a",
                    "type": "pane",
                    "summary": "Pane A",
                    "description": "First pane",
                    "default_position": {"x": 0, "y": 0, "width": 200, "height": 400},
                    "title_bar": {"label": "A", "draggable": True, "closeable": True},
                    "content": {
                        "id": "grid_a",
                        "type": "grid",
                        "summary": "Grid",
                        "cols": 2,
                        "gap": 4,
                        "children": [
                            {
                                "id": "btn_1",
                                "type": "icon_button",
                                "summary": "Pen",
                                "icon": "pen",
                                "grid": {"row": 0, "col": 0},
                                "behavior": [
                                    {"event": "click", "action": "select_tool", "params": {"tool": "pen"}}
                                ],
                            },
                            {
                                "id": "btn_2",
                                "type": "icon_button",
                                "summary": "Rect",
                                "icon": "rect",
                                "grid": {"row": 0, "col": 1},
                            },
                        ],
                    },
                },
                {
                    "id": "pane_b",
                    "type": "pane",
                    "summary": "Pane B",
                    "description": "Second pane with placeholder",
                    "default_position": {"x": 200, "y": 0, "width": 600, "height": 400},
                    "title_bar": {"label": "B", "draggable": True, "closeable": False},
                    "content": {
                        "id": "placeholder_b",
                        "type": "placeholder",
                        "summary": "Canvas area",
                        "description": "Drawing surface placeholder",
                    },
                },
            ],
        },
        "dialogs": {
            "confirm": {
                "summary": "Confirm",
                "description": "Confirmation dialog",
                "modal": True,
                "content": {
                    "type": "container",
                    "layout": "column",
                    "children": [
                        {"type": "text", "content": "Are you sure?"},
                        {
                            "type": "row",
                            "style": {"justify": "end", "gap": 8},
                            "children": [
                                {"type": "button", "label": "Cancel", "action": "dismiss_dialog"},
                                {"type": "button", "label": "OK", "action": "quit", "variant": "primary"},
                            ],
                        },
                    ],
                },
            }
        },
    }


@pytest.fixture
def flask_app(sample_workspace):
    """Flask test app with sample workspace."""
    import sys
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
    from app import create_app
    app = create_app(workspace=sample_workspace)
    app.config["TESTING"] = True
    return app


@pytest.fixture
def client(flask_app):
    """Flask test client."""
    return flask_app.test_client()
