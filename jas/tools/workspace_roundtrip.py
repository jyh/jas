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

from workspace.workspace_layout import WorkspaceLayout
from workspace.workspace_test_json import workspace_to_test_json, test_json_to_workspace
# 3d-2: delegate to the SINGLE runtime layout dispatcher instead of
# reimplementing the 15 verbs here (eliminated the third hand-rolled
# dispatcher, mirroring Rust bin/workspace_roundtrip.rs::apply_op).
from workspace.layout_apply import layout_apply


def apply_op(layout, op):
    layout_apply(layout, op)


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
