#!/usr/bin/env python3
"""Toolbar-structure bundle snapshot gate (TESTING_STRATEGY.md §4, §7).

The toolbar is bundle-driven: every app loads the same compiled
`workspace/workspace.json` `layout`, whose `tool_grid` node is the single source
of truth for the tool button grid. So the right gate is one snapshot of the
compiled `tool_grid` against a golden — not a per-app re-derivation (which would
only test four projections of identical input). This is the toolbar analogue of
`scripts/check_menu_structure.py`.

The gate also asserts that every slot's `icon` resolves in the compiled `icons`
map (catching a slot that references a missing icon), and that the grid has the
expected slot count.

Run `check_toolbar_structure.py` to verify; `--regenerate` to rewrite the golden
after an intentional `layout.yaml` tool_grid change.
"""

import argparse
import json
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]
_WORKSPACE_JSON = _ROOT / "workspace" / "workspace.json"
_GOLDEN = _ROOT / "test_fixtures" / "expected" / "toolbar_structure.json"

# Expected number of toolbar slots (icon_button children of tool_grid).
_EXPECTED_SLOTS = 13


def _find_node(node, node_id):
    """Depth-first search for the dict with id == node_id."""
    if isinstance(node, dict):
        if node.get("id") == node_id:
            return node
        for value in node.values():
            found = _find_node(value, node_id)
            if found is not None:
                return found
    elif isinstance(node, list):
        for item in node:
            found = _find_node(item, node_id)
            if found is not None:
                return found
    return None


def _click_tool(button):
    """Primary tool = the tool param of the button's click→select_tool behavior."""
    for ev in button.get("behavior", []) or []:
        if ev.get("event") == "click" and ev.get("action") == "select_tool":
            return (ev.get("params") or {}).get("tool", "")
    return ""


def _project_slot(button):
    """Project one icon_button to the canonical slot record."""
    grid = button.get("grid", {}) or {}
    primary = _click_tool(button)
    alternates = button.get("alternates")
    has_alternates = bool(alternates)
    if has_alternates:
        tools = [it.get("id", "") for it in alternates.get("items", [])]
    else:
        tools = [primary]
    return {
        "row": grid.get("row", -1),
        "col": grid.get("col", -1),
        "primary": primary,
        "tools": tools,
        "has_alternates": has_alternates,
        "icon": button.get("icon", ""),
    }


def project_toolbar(workspace):
    """Project the compiled tool_grid to the canonical toolbar structure."""
    grid = _find_node(workspace["layout"], "tool_grid")
    if grid is None:
        raise SystemExit("FAIL: tool_grid node not found in compiled layout.")
    buttons = [c for c in grid.get("children", [])
               if c.get("type") == "icon_button"]
    slots = sorted((_project_slot(b) for b in buttons),
                   key=lambda s: (s["row"], s["col"]))
    total_tools = sum(len(s["tools"]) for s in slots)
    return {"slots": slots, "total_tools": total_tools}


def _canonical(obj) -> str:
    # Same canonical discipline as check_menu_structure: sorted keys, compact,
    # UTF-8 preserved.
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _check_icons(workspace, structure) -> list:
    """Return a list of (slot, icon) for slots whose icon is missing."""
    icons = workspace.get("icons", {}) or {}
    missing = []
    for slot in structure["slots"]:
        if slot["icon"] not in icons:
            missing.append((f'({slot["row"]},{slot["col"]})', slot["icon"]))
    return missing


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--regenerate", action="store_true",
                    help="rewrite the golden from the current workspace.json tool_grid")
    args = ap.parse_args()

    workspace = json.loads(_WORKSPACE_JSON.read_text())
    structure = project_toolbar(workspace)
    actual = _canonical(structure) + "\n"

    if args.regenerate:
        _GOLDEN.write_text(actual)
        print(f"regenerated {_GOLDEN.relative_to(_ROOT)} "
              f"({len(structure['slots'])} slots, "
              f"{structure['total_tools']} tools)")
        return 0

    ok = True

    # 1. Slot count.
    n_slots = len(structure["slots"])
    if n_slots != _EXPECTED_SLOTS:
        print(f"FAIL: expected {_EXPECTED_SLOTS} toolbar slots, found {n_slots}.",
              file=sys.stderr)
        ok = False

    # 2. Every slot icon resolves in the compiled icons map.
    missing = _check_icons(workspace, structure)
    if missing:
        print("FAIL: toolbar slots reference icons missing from the compiled "
              "icons map:", file=sys.stderr)
        for where, icon in missing:
            print(f"  slot {where}: icon {icon!r}", file=sys.stderr)
        ok = False

    # 3. Snapshot matches the golden.
    if not _GOLDEN.exists():
        print(f"FAIL: golden missing: {_GOLDEN}", file=sys.stderr)
        return 1
    expected = _GOLDEN.read_text()
    if actual != expected:
        print("FAIL: toolbar structure does not match the golden.\n"
              "  The compiled tool_grid drifted from test_fixtures/expected/"
              "toolbar_structure.json.\n"
              "  If layout.yaml's tool_grid changed intentionally, run with "
              "--regenerate.",
              file=sys.stderr)
        ok = False

    if not ok:
        return 1
    print(f"OK: toolbar structure matches the golden "
          f"({n_slots} slots, {structure['total_tools']} tools).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
