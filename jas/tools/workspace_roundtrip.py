#!/usr/bin/env python3
"""CLI tool for cross-language workspace layout testing.

Usage:
    python workspace_roundtrip.py default                       -- canonical JSON for default_layout()
    python workspace_roundtrip.py default_with_panes <w> <h>    -- with pane layout at viewport size
    python workspace_roundtrip.py parse <workspace.json>        -- parse, output canonical test JSON
    python workspace_roundtrip.py apply <workspace.json>        -- parse, apply ops from stdin, output canonical test JSON
"""

import json
import sys
import os

# Add project root to path so imports work.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from workspace.workspace_layout import (
    WorkspaceLayout, DockEdge, PanelKind, PanelGroup, Dock, FloatingDock,
    GroupAddr, PanelAddr,
)
from workspace.pane import PaneLayout, PaneKind as PK
from workspace.workspace_test_json import workspace_to_test_json, test_json_to_workspace


def apply_op(layout, op):
    name = op["op"]
    if name == "toggle_group_collapsed":
        layout.toggle_group_collapsed(GroupAddr(op["dock_id"], op["group_idx"]))
    elif name == "set_active_panel":
        layout.set_active_panel(PanelAddr(GroupAddr(op["dock_id"], op["group_idx"]), op["panel_idx"]))
    elif name == "close_panel":
        layout.close_panel(PanelAddr(GroupAddr(op["dock_id"], op["group_idx"]), op["panel_idx"]))
    elif name == "show_panel":
        kind_map = {"layers": PanelKind.LAYERS, "color": PanelKind.COLOR,
                     "stroke": PanelKind.STROKE, "properties": PanelKind.PROPERTIES}
        layout.show_panel(kind_map[op["kind"]])
    elif name == "reorder_panel":
        layout.reorder_panel(GroupAddr(op["dock_id"], op["group_idx"]), op["from"], op["to"])
    elif name == "move_panel_to_group":
        layout.move_panel_to_group(
            PanelAddr(GroupAddr(op["from_dock_id"], op["from_group_idx"]), op["from_panel_idx"]),
            GroupAddr(op["to_dock_id"], op["to_group_idx"]))
    elif name == "detach_group":
        layout.detach_group(GroupAddr(op["dock_id"], op["group_idx"]), op["x"], op["y"])
    elif name == "redock":
        layout.redock(op["dock_id"])
    elif name == "set_pane_position":
        layout.pane_layout.set_pane_position(op["pane_id"], op["x"], op["y"])
    elif name == "tile_panes":
        layout.pane_layout.tile_panes()
    elif name == "toggle_canvas_maximized":
        layout.pane_layout.toggle_canvas_maximized()
    elif name == "resize_pane":
        layout.pane_layout.resize_pane(op["pane_id"], op["width"], op["height"])
    elif name == "hide_pane":
        kind_map = {"toolbar": PK.TOOLBAR, "canvas": PK.CANVAS, "dock": PK.DOCK}
        layout.pane_layout.hide_pane(kind_map[op["kind"]])
    elif name == "show_pane":
        kind_map = {"toolbar": PK.TOOLBAR, "canvas": PK.CANVAS, "dock": PK.DOCK}
        layout.pane_layout.show_pane(kind_map[op["kind"]])
    elif name == "bring_pane_to_front":
        layout.pane_layout.bring_pane_to_front(op["pane_id"])
    else:
        print(f"Unknown workspace op: {name}", file=sys.stderr)
        sys.exit(1)


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} default|default_with_panes|parse|apply ...", file=sys.stderr)
        sys.exit(1)

    mode = sys.argv[1]

    if mode == "default":
        layout = WorkspaceLayout.default_layout()
        print(workspace_to_test_json(layout), end="")
    elif mode == "default_with_panes":
        if len(sys.argv) < 4:
            print(f"Usage: {sys.argv[0]} default_with_panes <width> <height>", file=sys.stderr)
            sys.exit(1)
        w, h = float(sys.argv[2]), float(sys.argv[3])
        layout = WorkspaceLayout.default_layout()
        layout.ensure_pane_layout(w, h)
        print(workspace_to_test_json(layout), end="")
    elif mode == "parse":
        if len(sys.argv) < 3:
            print(f"Usage: {sys.argv[0]} parse <workspace.json>", file=sys.stderr)
            sys.exit(1)
        with open(sys.argv[2]) as f:
            json_str = f.read().strip()
        layout = test_json_to_workspace(json_str)
        print(workspace_to_test_json(layout), end="")
    elif mode == "apply":
        if len(sys.argv) < 3:
            print(f"Usage: {sys.argv[0]} apply <workspace.json>  (ops from stdin)", file=sys.stderr)
            sys.exit(1)
        with open(sys.argv[2]) as f:
            json_str = f.read().strip()
        layout = test_json_to_workspace(json_str)
        ops = json.loads(sys.stdin.read())
        for op in ops:
            apply_op(layout, op)
        print(workspace_to_test_json(layout), end="")
    else:
        print(f"Unknown mode: {mode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
