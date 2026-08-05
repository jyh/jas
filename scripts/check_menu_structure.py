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
after an intentional `menubar.yaml` change; `--self-test` to prove the gate can
still go RED.

WHY --self-test EXISTS
----------------------
A snapshot gate is only as wide as its PROJECTION. Every field `_project_item`
declines to copy is a field in which the menubar may drift forever without this
gate noticing: the golden is regenerated from the same projection, so a dropped
field is dropped from both sides and the comparison stays green by
construction. That is the same circularity as an oracle sharing its subject's
quantizer, in a different organ.

So `--self-test` does not check that the snapshot matches. It checks that each
field the projection claims to carry is LOAD-BEARING — that changing it changes
the canonical string — and that structure (separators, submenu nesting, item
order, menu order) survives projection. A projection that returned `{}` for
everything would match its own golden perfectly, so the empty case is asserted
first.

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


def _probe_menubar():
    """A menubar exercising every shape the projection claims to handle."""
    return [
        {"id": "file", "label": "File", "items": [
            {"action": "new_document", "label": "New", "shortcut": "Ctrl+N"},
            "separator",
            {"label": "Workspace", "items": [
                {"action": "reset_workspace", "label": "Reset", "shortcut": "Ctrl+R"},
            ]},
        ]},
        {"id": "edit", "label": "Edit", "items": [
            {"action": "undo", "label": "Undo", "shortcut": "Ctrl+Z"},
        ]},
    ]


def _self_test() -> int:
    """Prove the gate can still REJECT. Reads no bundle and no golden."""
    failures = []
    base = _canonical(project_menubar(_probe_menubar()))

    # 1. THE EMPTY PROJECTION IS FATAL, asserted first. A projection that
    #    returned nothing would match a golden regenerated from itself, and
    #    every discrimination check below would compare two empty strings.
    if base == _canonical(project_menubar([])):
        print("SELF-TEST FAIL: a populated menubar projects to the same string as "
              "an EMPTY one. The projection carries no information and every "
              "assertion below would be vacuous.", file=sys.stderr)
        return 1

    # 2. Every field the projection claims to carry must actually appear. A
    #    field silently dropped here is a field that can drift forever.
    for field, value in (("action", "new_document"), ("label", "New"),
                         ("shortcut", "Ctrl+N"), ("submenu label", "Workspace"),
                         ("nested action", "reset_workspace"),
                         ("separator", "separator")):
        if value not in base:
            failures.append(f"the projection dropped the {field} ({value!r})")

    # 3. Each field is LOAD-BEARING: changing it must change the snapshot.
    #    Presence in the string is not enough — a field could be emitted from a
    #    constant. These edits are what a drifting menubar.yaml actually does.
    def mutate(fn):
        mb = _probe_menubar()
        fn(mb)
        return _canonical(project_menubar(mb))

    edits = {
        "a changed shortcut":
            lambda mb: mb[0]["items"][0].__setitem__("shortcut", "Ctrl+X"),
        "a changed label":
            lambda mb: mb[0]["items"][0].__setitem__("label", "Renamed"),
        "a changed action":
            lambda mb: mb[0]["items"][0].__setitem__("action", "other_action"),
        "a changed menu title":
            lambda mb: mb[0].__setitem__("label", "Fyle"),
        "a removed separator":
            lambda mb: mb[0]["items"].pop(1),
        "a changed action INSIDE a submenu":
            lambda mb: mb[0]["items"][2]["items"][0].__setitem__("action", "moved"),
        "a reordered pair of items":
            lambda mb: mb[0]["items"].reverse(),
        "a reordered pair of menus":
            lambda mb: mb.reverse(),
        "a dropped menu":
            lambda mb: mb.pop(),
    }
    for what, fn in edits.items():
        if mutate(fn) == base:
            failures.append(f"{what} did not change the snapshot")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}", file=sys.stderr)
    if failures:
        return 1
    print(f"check_menu_structure SELF-TEST: OK (empty projection fatal proven "
          f"FIRST; action/label/shortcut/separator/submenu all carried; "
          f"{len(edits)} distinct drifts each move the snapshot).")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--regenerate", action="store_true",
                    help="rewrite the golden from the current workspace.json menubar")
    ap.add_argument("--self-test", action="store_true",
                    help="prove the gate can still reject; reads no bundle")
    args = ap.parse_args()
    if args.self_test:
        return _self_test()

    workspace = json.loads(_WORKSPACE_JSON.read_text(encoding="utf-8"))
    actual = _canonical(project_menubar(workspace["menubar"])) + "\n"

    if args.regenerate:
        _GOLDEN.write_text(actual, encoding="utf-8", newline="")
        print(f"regenerated {_GOLDEN.relative_to(_ROOT)} "
              f"({len(workspace['menubar'])} menus)")
        return 0

    if not _GOLDEN.exists():
        print(f"FAIL: golden missing: {_GOLDEN}", file=sys.stderr)
        return 1
    expected = _GOLDEN.read_text(encoding="utf-8")
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
