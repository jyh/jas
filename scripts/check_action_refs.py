#!/usr/bin/env python3
"""Action referential-integrity gate (codebase-review Wave 0, finding #15).

Every `action:` referenced from the compiled bundle — menubar, panels
(menus + behaviors), and the toolbar `tool_grid` — must resolve to either a
declarative `actions:` entry or a `native_intercepts:` entry (behaviors
handled in native per-app code, per NATIVE_BOUNDARY.md).

This is the fast structural counterpart to the reference-interpreter test
`TestValidateActionRefs`. It runs in the `workspace-json-fresh` CI job so a
dangling reference (e.g. a menu item pointing at an action nobody defined)
fails the build in seconds, instead of slipping through to the full test
suite — which is exactly how `export_to_pdf` reached main once.

Run `python scripts/check_action_refs.py` to verify.
"""

import json
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]
_WORKSPACE_JSON = _ROOT / "workspace" / "workspace.json"
_BASELINE = _ROOT / "scripts" / "action_refs_baseline.json"


def _resolvable(ws: dict) -> set:
    return set(ws.get("actions", {})) | set(ws.get("native_intercepts", []))


def _collect_menubar(ws: dict) -> list:
    """(action, where) refs from the menubar tree."""
    refs = []

    def walk(items, path):
        for item in items:
            if isinstance(item, str):
                continue
            if "action" in item:
                refs.append((item["action"], f"{path} > {item.get('id', item.get('label', '?'))}"))
            if "items" in item:
                walk(item["items"], path)

    for menu in ws.get("menubar", []):
        walk(menu.get("items", []), f"menubar/{menu.get('id', menu.get('label', '?'))}")
    return refs


def _collect_panels(ws: dict) -> list:
    """(action, where) refs from every panel's menu list and behavior trees."""
    refs = []

    def walk(node, where):
        if isinstance(node, list):
            for n in node:
                walk(n, where)
            return
        if not isinstance(node, dict):
            return
        if "action" in node:
            refs.append((node["action"], where))
        for behavior in node.get("behavior", []):
            if isinstance(behavior, dict) and "action" in behavior:
                refs.append((behavior["action"], f"{where}/behavior"))
        for child in node.get("children", []):
            walk(child, where)
        for key in ("content", "do", "menu"):
            inner = node.get(key)
            if isinstance(inner, (dict, list)):
                walk(inner, f"{where}/{key}")

    for pid, panel in ws.get("panels", {}).items():
        walk(panel, f"panel/{pid}")
    return refs


def _collect_toolbar(ws: dict) -> list:
    """(action, where) refs from the toolbar tool_grid tree."""
    refs = []

    def walk(node, where):
        if isinstance(node, list):
            for n in node:
                walk(n, where)
        elif isinstance(node, dict):
            if "action" in node:
                refs.append((node["action"], where))
            for v in node.values():
                walk(v, where)

    walk(ws.get("tool_grid", []), "tool_grid")
    return refs


def main() -> int:
    if not _WORKSPACE_JSON.exists():
        print(f"FAIL: {_WORKSPACE_JSON} missing (regenerate the bundle).", file=sys.stderr)
        return 1
    ws = json.loads(_WORKSPACE_JSON.read_text())
    resolvable = _resolvable(ws)
    baseline = set(json.loads(_BASELINE.read_text()).get("unresolved_actions", []))

    refs = _collect_menubar(ws) + _collect_panels(ws) + _collect_toolbar(ws)
    dangling = {a: w for (a, w) in refs if a not in resolvable}
    dangling_names = set(dangling)

    # New debt: an unresolved ref not covered by the baseline. This is the real
    # guard — it is what would have failed on export_to_pdf.
    new_dangling = dangling_names - baseline
    # Stale baseline: a listed action is now resolved (implemented or removed).
    # Force the debt list to shrink rather than harbor no-longer-true entries.
    stale = baseline - dangling_names

    if new_dangling:
        print("FAIL: NEW unresolved action references (not in actions:, "
              "native_intercepts:, or the baseline):", file=sys.stderr)
        for action in sorted(new_dangling):
            print(f"  {action!r}  <- {dangling[action]}", file=sys.stderr)
        print("\nFix: add the action to workspace/actions.yaml, or — if handled purely\n"
              "in native code — add it to native_intercepts: with a NATIVE_BOUNDARY.md\n"
              "justification. Do NOT add it to action_refs_baseline.json unless it is a\n"
              "pre-existing forward-declared no-op you are explicitly deferring.",
              file=sys.stderr)
        return 1

    if stale:
        print("FAIL: action_refs_baseline.json lists actions that now resolve — "
              "remove them from the baseline (the debt only shrinks):", file=sys.stderr)
        for action in sorted(stale):
            print(f"  {action!r}", file=sys.stderr)
        return 1

    msg = (f"OK: all {len(refs)} action references resolve "
           f"({len(resolvable)} known actions incl. native intercepts)")
    if baseline:
        msg += f"; {len(baseline)} pre-existing forward-declared no-ops tracked in baseline"
    print(msg + ".")
    return 0


if __name__ == "__main__":
    sys.exit(main())
