#!/usr/bin/env python3
"""Menu-structure bundle snapshot gate (TESTING_STRATEGY.md §4, §7).

The menu bar is bundle-driven: every app loads the same compiled
`workspace/workspace.json` `menubar` (from `workspace/menubar.yaml`). So the
right gate is a single snapshot of the compiled menubar against a golden — not a
per-app re-derivation (which would only test four projections of identical input).

This replaces the previous per-app `menu_structure_json()` literals, which had
drifted badly from the real menubar (they were frozen at File/Edit/Object/Window
with no View menu, stale items, and flat submenus).

Run `check_menu_structure.py` to verify; `--regenerate` to rewrite the golden
after an intentional `menubar.yaml` change.

(A complementary per-app check — that each native app's *live* menu widgets match
this bundle snapshot — is the deferred live-widget-reflection work.)
"""

import argparse
import json
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]
_WORKSPACE_JSON = _ROOT / "workspace" / "workspace.json"
_GOLDEN = _ROOT / "test_fixtures" / "expected" / "menu_structure.json"


def _project_item(item):
    """Project one menubar item to the canonical snapshot shape."""
    if isinstance(item, str):  # a bare "separator"
        return {"separator": True}
    if "items" in item:  # a submenu (Workspace / Appearance)
        return {
            "label": item.get("label", ""),
            "submenu": [_project_item(child) for child in item["items"]],
        }
    return {
        "action": item.get("action", ""),
        "label": item.get("label", ""),
        "shortcut": item.get("shortcut", ""),
    }


def project_menubar(menubar):
    """Project the compiled `menubar` list to the canonical menu structure."""
    return {
        "menus": [
            {
                "label": menu.get("label", ""),
                "items": [_project_item(it) for it in menu.get("items", [])],
            }
            for menu in menubar
        ]
    }


def _canonical(obj) -> str:
    # Same canonical discipline as document_to_test_json: sorted keys, compact,
    # UTF-8 preserved (labels carry & mnemonics and ... ellipses).
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--regenerate", action="store_true",
                    help="rewrite the golden from the current workspace.json menubar")
    args = ap.parse_args()

    workspace = json.loads(_WORKSPACE_JSON.read_text())
    actual = _canonical(project_menubar(workspace["menubar"])) + "\n"

    if args.regenerate:
        _GOLDEN.write_text(actual)
        print(f"regenerated {_GOLDEN.relative_to(_ROOT)} "
              f"({len(workspace['menubar'])} menus)")
        return 0

    if not _GOLDEN.exists():
        print(f"FAIL: golden missing: {_GOLDEN}", file=sys.stderr)
        return 1
    expected = _GOLDEN.read_text()
    if actual != expected:
        print("FAIL: menu structure does not match the golden.\n"
              "  The compiled menubar drifted from test_fixtures/expected/"
              "menu_structure.json.\n"
              "  If menubar.yaml changed intentionally, run with --regenerate.",
              file=sys.stderr)
        return 1
    print("OK: menu structure matches the golden.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
