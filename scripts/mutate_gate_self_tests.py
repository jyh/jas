#!/usr/bin/env python3
"""Mutation-prove a gate's --self-test.

For each mutant: copy the gate to a sibling file in scripts/ (so its
`Path(__file__).parents[1]` still resolves to the repo root), apply one textual
change that BREAKS the gate's discriminating logic, and require --self-test to
exit non-zero. A mutant that survives is a self-test that does not test.

The copy is a sibling rather than a temp dir on purpose: several gates compute
repo paths from __file__ at import time, and a self-test that only passes
because those paths broke would be its own false green.
"""
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(REPO, "scripts")

# (gate filename, mutant label, find, replace)
MUTANTS = [
    # ---- check_action_refs.py
    ("check_action_refs.py", "panels collector removed",
     "return _collect_menubar(ws) + _collect_panels(ws) + _collect_toolbar(ws)",
     "return _collect_menubar(ws) + _collect_toolbar(ws)"),
    ("check_action_refs.py", "nothing is ever dangling",
     'dangling = {a: w for (a, w) in refs if a not in resolvable}',
     'dangling = {}'),
    ("check_action_refs.py", "stale baseline never reported",
     '"stale": baseline - dangling_names,',
     '"stale": set(),'),
    ("check_action_refs.py", "baseline stops suppressing",
     '"new_dangling": dangling_names - baseline,',
     '"new_dangling": dangling_names,'),
    ("check_action_refs.py", "native_intercepts no longer resolve",
     'return set(ws.get("actions", {})) | set(ws.get("native_intercepts", []))',
     'return set(ws.get("actions", {}))'),
    ("check_action_refs.py", "submenu recursion removed",
     '            if "items" in item:\n                walk(item["items"], path)',
     '            if False:\n                walk(item["items"], path)'),

    # ---- check_menu_structure.py
    ("check_menu_structure.py", "shortcut dropped from the projection",
     '"shortcut": item.get("shortcut", ""),',
     '"shortcut": "",'),
    ("check_menu_structure.py", "item label dropped from the projection",
     '        "action": item.get("action", ""),\n        "label": item.get("label", ""),',
     '        "action": item.get("action", ""),\n        "label": "",'),
    ("check_menu_structure.py", "menu title dropped from the projection",
     '"label": menu.get("label", ""),',
     '"label": "",'),
    ("check_menu_structure.py", "separators collapse to nothing",
     'return {"separator": True}',
     'return {}'),
    ("check_menu_structure.py", "submenu contents dropped",
     '"submenu": [_project_item(child) for child in item["items"]],',
     '"submenu": [],'),
    ("check_menu_structure.py", "item order normalised away",
     '[_project_item(it) for it in menu.get("items", [])]',
     '[_project_item(it) for it in sorted(menu.get("items", []), key=str)]'),

    # ---- check_path_b_exclusions.py
    ("check_path_b_exclusions.py", "missing marker returns empty instead of raising",
     '    if not m:\n        raise SystemExit(f"FAIL: exclusion-set marker not found in {where} "\n'
     '                         f"(pattern {start_re!r}) \u2014 did the declaration move?")',
     '    if not m:\n        return frozenset()'),
    ("check_path_b_exclusions.py", "block bound stops bounding",
     'block = rest if end < 0 else rest[:end]',
     'block = rest'),
    ("check_path_b_exclusions.py", "swift marker no longer matches swift",
     r'r"pathBExcluded\s*:\s*Set<String>\s*=\s*\["',
     r'r"pathBExcludedRENAMED\s*:\s*Set<String>\s*=\s*\["'),
    ("check_path_b_exclusions.py", "ocaml marker no longer matches ocaml",
     r'r"let path_b_excluded\s*="',
     r'r"let path_b_excluded_RENAMED\s*="'),
    ("check_path_b_exclusions.py", "id regex matches nothing",
     "_ID = re.compile(r'\"([a-z_]+_panel_content)\"')",
     "_ID = re.compile(r'\"([a-z_]+_panel_NOTHING)\"')"),

    # ---- check_toolbar_structure.py
    ("check_toolbar_structure.py", "_click_tool ignores the event kind",
     'if ev.get("event") == "click" and ev.get("action") == "select_tool":',
     'if ev.get("action") == "select_tool":'),
    ("check_toolbar_structure.py", "_click_tool ignores the action",
     'if ev.get("event") == "click" and ev.get("action") == "select_tool":',
     'if ev.get("event") == "click":'),
    ("check_toolbar_structure.py", "icon dropped from the projection",
     '"icon": button.get("icon", ""),',
     '"icon": "",'),
    ("check_toolbar_structure.py", "row dropped from the projection",
     '"row": grid.get("row", -1),',
     '"row": 0,'),
    ("check_toolbar_structure.py", "alternates never detected",
     'has_alternates = bool(alternates)',
     'has_alternates = False'),
    ("check_toolbar_structure.py", "_find_node stops recursing",
     '        for value in node.values():\n            found = _find_node(value, node_id)',
     '        for value in []:\n            found = _find_node(value, node_id)'),
    ("check_toolbar_structure.py", "missing icons never reported",
     'missing.append((f\'({slot["row"]},{slot["col"]})\', slot["icon"]))',
     'pass'),
    ("check_toolbar_structure.py", "non-icon_button children become slots",
     'buttons = [c for c in grid.get("children", [])\n               if c.get("type") == "icon_button"]',
     'buttons = list(grid.get("children", []))'),
    ("check_toolbar_structure.py", "slot sorting removed",
     'slots = sorted((_project_slot(b) for b in buttons),\n                   key=lambda s: (s["row"], s["col"]))',
     'slots = [_project_slot(b) for b in buttons]'),
]


def run(gate: str, label: str, find: str, replace: str) -> bool:
    src = os.path.join(SCRIPTS, gate)
    with open(src, encoding="utf-8") as fh:
        text = fh.read()
    if find not in text:
        print(f"  SKIP  [{gate}] {label}: anchor not found -- mutant is stale")
        return False
    mutant_name = "_mutant_" + gate
    mutant_path = os.path.join(SCRIPTS, mutant_name)
    with open(mutant_path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text.replace(find, replace, 1))
    try:
        env = dict(os.environ, PYTHONIOENCODING="utf-8")
        # encoding="utf-8" explicitly: `text=True` alone decodes with the
        # locale codec, which on Windows is cp1252 and mangles the non-ASCII
        # characters these gates print in their failure messages.
        out = subprocess.run([sys.executable, mutant_path, "--self-test"],
                             capture_output=True, text=True, encoding="utf-8",
                             env=env, timeout=120)
        killed = out.returncode != 0
    finally:
        os.remove(mutant_path)
    if killed:
        print(f"  killed [{gate}] {label}")
    else:
        print(f"  SURVIVED [{gate}] {label}  <-- the self-test does not test this")
    return killed


def main() -> int:
    only = sys.argv[1] if len(sys.argv) > 1 else None
    total = killed = 0
    for gate, label, find, replace in MUTANTS:
        if only and gate != only:
            continue
        total += 1
        if run(gate, label, find, replace):
            killed += 1
    print(f"\nMUTANTS: {killed}/{total} killed")
    leftover = [f for f in os.listdir(SCRIPTS) if f.startswith("_mutant_")]
    if leftover:
        print(f"ERROR: leftover mutant files: {leftover}")
        return 1
    return 0 if killed == total else 1


if __name__ == "__main__":
    sys.exit(main())
