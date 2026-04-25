"""Canvas tool implementations."""

from __future__ import annotations

import json
import os

from tools.tool import CanvasTool
from tools.toolbar import Tool
from tools.yaml_tool import YamlTool
from tools.type_tool import TypeTool
from tools.type_on_path_tool import TypeOnPathTool


_WS: dict | None = None


def _load_workspace() -> dict:
    """Load the compiled workspace.json once per import."""
    here = os.path.abspath(os.path.dirname(__file__))
    # jas/tools/__init__.py is inside the `jas/` package — repo root
    # is two directories up.
    repo_root = os.path.abspath(os.path.join(here, "..", "..", ".."))
    ws_path = os.path.join(repo_root, "workspace", "workspace.json")
    # Fallback when the tool is imported from a different CWD.
    if not os.path.exists(ws_path):
        alt = os.path.abspath(
            os.path.join(here, "..", "..", "workspace", "workspace.json")
        )
        if os.path.exists(alt):
            ws_path = alt
    with open(ws_path, "r") as f:
        return json.load(f)


def _yaml_tool(tool_id: str) -> YamlTool:
    """Load a YamlTool by id from the compiled workspace.json.
    Raises if the workspace or spec is missing — a non-functional
    app is better than a partially-wired one."""
    global _WS
    if _WS is None:
        _WS = _load_workspace()
    tools = _WS.get("tools") or {}
    spec = tools.get(tool_id)
    if spec is None:
        raise RuntimeError(
            f"workspace.json is missing tools.{tool_id} — "
            f"cannot load YAML tool"
        )
    tool = YamlTool.from_workspace_tool(spec)
    if tool is None:
        raise RuntimeError(
            f"workspace.json tools.{tool_id} is malformed — cannot parse"
        )
    return tool


def create_tools() -> dict[Tool, CanvasTool]:
    """Create one instance of each tool, keyed by Tool enum.

    14 tools are YAML-driven per PYTHON_TOOL_RUNTIME.md Phase 7.
    Type + TypeOnPath stay native per NATIVE_BOUNDARY.md §6.
    """
    return {
        Tool.SELECTION: _yaml_tool("selection"),
        Tool.PARTIAL_SELECTION: _yaml_tool("partial_selection"),
        Tool.INTERIOR_SELECTION: _yaml_tool("interior_selection"),
        Tool.MAGIC_WAND: _yaml_tool("magic_wand"),
        Tool.PEN: _yaml_tool("pen"),
        Tool.ADD_ANCHOR_POINT: _yaml_tool("add_anchor_point"),
        Tool.DELETE_ANCHOR_POINT: _yaml_tool("delete_anchor_point"),
        Tool.ANCHOR_POINT: _yaml_tool("anchor_point"),
        Tool.PENCIL: _yaml_tool("pencil"),
        Tool.PAINTBRUSH: _yaml_tool("paintbrush"),
        Tool.BLOB_BRUSH: _yaml_tool("blob_brush"),
        Tool.PATH_ERASER: _yaml_tool("path_eraser"),
        Tool.SMOOTH: _yaml_tool("smooth"),
        Tool.TYPE: TypeTool(),
        Tool.TYPE_ON_PATH: TypeOnPathTool(),
        Tool.LINE: _yaml_tool("line"),
        Tool.RECT: _yaml_tool("rect"),
        Tool.ROUNDED_RECT: _yaml_tool("rounded_rect"),
        Tool.POLYGON: _yaml_tool("polygon"),
        Tool.STAR: _yaml_tool("star"),
        Tool.LASSO: _yaml_tool("lasso"),
        Tool.SCALE: _yaml_tool("scale"),
        Tool.ROTATE: _yaml_tool("rotate"),
        Tool.SHEAR: _yaml_tool("shear"),
    }
