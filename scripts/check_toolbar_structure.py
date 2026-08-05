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
after an intentional `layout.yaml` tool_grid change; `--self-test` to prove the
gate can still go RED.

WHY --self-test EXISTS
----------------------
Same circularity as `check_menu_structure`: the golden is regenerated from the
same projection it is compared against, so any field `_project_slot` declines
to carry is a field that can drift forever with the gate green. `_click_tool`
is the sharpest case — it returns `""` for anything that is not a
click→`select_tool` behavior, so a behavior-shape change would silently blank
every `primary` and the regenerated golden would agree.

`--self-test` therefore asserts that each projected field is LOAD-BEARING, that
`_click_tool` discriminates on both `event` and `action` rather than taking the
first behavior it sees, that alternates expand into `tools` while a plain
button does not, that slot ORDER is normalised by (row, col) while the row and
col values themselves still matter, and that `_check_icons` can actually find a
missing icon. The empty projection is fatal and asserted first.

`_EXPECTED_SLOTS` is the anti-vacuity pin for the whole snapshot: without it a
golden regenerated from a broken projection could record zero slots and match
itself. The self-test asserts the pin is non-zero for that reason.
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


def _probe_workspace():
    """A layout exercising every shape the projection claims to handle.

    tool_grid is deliberately NESTED two levels down, because `_find_node` is a
    recursive search and a version that only looked at the top level would
    still pass a self-test that handed it a flat layout.
    """
    return {
        "layout": {"type": "root", "children": [
            {"type": "panel", "children": [
                {"id": "tool_grid", "type": "grid", "children": [
                    {"type": "icon_button", "icon": "icon_select",
                     "grid": {"row": 0, "col": 0},
                     "behavior": [{"event": "click", "action": "select_tool",
                                   "params": {"tool": "select"}}]},
                    {"type": "icon_button", "icon": "icon_shape",
                     "grid": {"row": 1, "col": 0},
                     "behavior": [{"event": "click", "action": "select_tool",
                                   "params": {"tool": "rect"}}],
                     "alternates": {"items": [{"id": "rect"}, {"id": "ellipse"}]}},
                    # Not an icon_button: must not become a slot.
                    {"type": "label", "id": "hint"},
                ]},
            ]},
        ]},
        "icons": {"icon_select": "M0", "icon_shape": "M1"},
    }


def _self_test() -> int:
    """Prove the gate can still REJECT. Reads no bundle and no golden."""
    failures = []
    ws = _probe_workspace()
    structure = project_toolbar(ws)
    base = _canonical(structure)

    # 1. AN EMPTY PROJECTION IS FATAL, asserted first: a projection that found
    #    no slots would match a golden regenerated from itself, and every
    #    discrimination check below would compare two empty snapshots.
    if not structure["slots"]:
        print("SELF-TEST FAIL: the projection found NO slots in a layout built to "
              "contain two. _find_node or the icon_button filter is broken, and "
              "every assertion below would be vacuous.", file=sys.stderr)
        return 1

    # 2. Shape: two icon_buttons become slots, the label does not, and
    #    alternates expand into `tools` while a plain button contributes one.
    if len(structure["slots"]) != 2:
        failures.append(f"expected 2 slots from the probe, got "
                        f"{len(structure['slots'])} (a non-icon_button leaked in?)")
    if structure["total_tools"] != 3:
        failures.append(f"expected 3 tools (1 plain + 2 alternates), got "
                        f"{structure['total_tools']}")
    plain, alt = structure["slots"][0], structure["slots"][1]
    if plain["has_alternates"] or plain["tools"] != ["select"]:
        failures.append("a plain button did not project as a single-tool slot")
    if not alt["has_alternates"] or alt["tools"] != ["rect", "ellipse"]:
        failures.append("alternates did not expand into the tools list")

    # 3. `_click_tool` must discriminate on BOTH event and action, not take the
    #    first behavior it finds. Either half alone would blank every primary
    #    on a behavior-shape change while the golden regenerated to agree.
    if _click_tool({"behavior": [{"event": "hover", "action": "select_tool",
                                  "params": {"tool": "x"}}]}) != "":
        failures.append("_click_tool accepted a non-click event")
    if _click_tool({"behavior": [{"event": "click", "action": "open_panel",
                                  "params": {"tool": "x"}}]}) != "":
        failures.append("_click_tool accepted an action other than select_tool")
    if _click_tool({"behavior": [{"event": "click", "action": "select_tool",
                                  "params": {"tool": "pen"}}]}) != "pen":
        failures.append("_click_tool did not read the tool from a real click")

    # 4. Each projected field is LOAD-BEARING: changing it moves the snapshot.
    def mutate(fn):
        w = _probe_workspace()
        fn(_find_node(w["layout"], "tool_grid")["children"])
        return _canonical(project_toolbar(w))

    edits = {
        "a changed row":
            lambda kids: kids[0]["grid"].__setitem__("row", 5),
        "a changed col":
            lambda kids: kids[0]["grid"].__setitem__("col", 5),
        "a changed icon":
            lambda kids: kids[0].__setitem__("icon", "icon_other"),
        "a changed tool param":
            lambda kids: kids[0]["behavior"][0]["params"].__setitem__("tool", "moved"),
        "a removed alternates block":
            lambda kids: kids[1].pop("alternates"),
        "a reordered alternates list":
            lambda kids: kids[1]["alternates"]["items"].reverse(),
        "a dropped button":
            lambda kids: kids.pop(0),
    }
    for what, fn in edits.items():
        if mutate(fn) == base:
            failures.append(f"{what} did not change the snapshot")

    # 5. Slot ORDER is normalised by (row, col), so source order must NOT
    #    matter. This is the one thing that has to stay INVARIANT, and it is
    #    asserted alongside the mutations so the two cannot be confused.
    if mutate(lambda kids: kids.reverse()) != base:
        failures.append("reordering the buttons in the source changed the "
                        "snapshot; slots are meant to be sorted by (row, col)")

    # 6. `_check_icons` can actually find a missing icon, and is quiet when
    #    every icon resolves.
    if _check_icons(ws, structure):
        failures.append("_check_icons reported a missing icon when all resolve")
    stripped = _probe_workspace()
    stripped["icons"].pop("icon_shape")
    if not _check_icons(stripped, project_toolbar(stripped)):
        failures.append("_check_icons did not notice an icon missing from the map")

    # 7. A layout with no tool_grid at all must RAISE, not project emptily.
    try:
        project_toolbar({"layout": {"type": "root", "children": []}})
        failures.append("a layout with no tool_grid projected quietly instead "
                        "of raising")
    except SystemExit:
        pass

    # 8. The anti-vacuity pin must be a real bound.
    if _EXPECTED_SLOTS <= 0:
        failures.append("_EXPECTED_SLOTS is not a positive bound, so a golden "
                        "recording zero slots could match itself")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}", file=sys.stderr)
    if failures:
        return 1
    print(f"check_toolbar_structure SELF-TEST: OK (empty projection fatal proven "
          f"FIRST; nested tool_grid found; non-buttons excluded; alternates "
          f"expand; _click_tool discriminates on event AND action; "
          f"{len(edits)} drifts each move the snapshot while source order does "
          f"not; a missing icon is caught; an absent tool_grid raises).")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--regenerate", action="store_true",
                    help="rewrite the golden from the current workspace.json tool_grid")
    ap.add_argument("--self-test", action="store_true",
                    help="prove the gate can still reject; reads no bundle")
    args = ap.parse_args()
    if args.self_test:
        return _self_test()

    workspace = json.loads(_WORKSPACE_JSON.read_text(encoding="utf-8"))
    structure = project_toolbar(workspace)
    actual = _canonical(structure) + "\n"

    if args.regenerate:
        _GOLDEN.write_text(actual, encoding="utf-8", newline="")
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
    expected = _GOLDEN.read_text(encoding="utf-8")
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
