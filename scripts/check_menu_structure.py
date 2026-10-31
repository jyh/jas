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


def _access_key(label):
    """The letter after a lone `&` in a label, lower-cased, or None."""
    i = 0
    while i < len(label) - 1:
        if label[i] == "&":
            if label[i + 1] != "&":
                return label[i + 1].lower()
            i += 2
            continue
        i += 1
    return None


def _plain(label):
    return label.replace("&&", "\0").replace("&", "").replace("\0", "&")


def menu_law_findings(menubar):
    """The two laws the snapshot cannot state, as (findings, items_read).

    1. ACCESS KEYS ARE UNIQUE within one item list (a menu or a submenu),
       compared case-insensitively: Windows cycles between two items that
       share a letter instead of running either.
    2. THE WINDOW MENU'S PANEL TOGGLES ARE IN ALPHABETICAL ORDER of their
       plain label (the Captain's ruling at the 10-30 feel sitting). The run
       of `toggle_panel` items is checked; the panes and submenus above it
       keep their declared order.

    `items_read` is the anti-vacuity count: a menubar this function walked
    without reading a single item must not read as compliant.
    """
    findings = []
    read = 0

    def walk(where, items):
        nonlocal read
        seen = {}
        for it in items:
            if not isinstance(it, dict):
                continue
            read += 1
            label = it.get("label", "")
            key = _access_key(label)
            if key is not None:
                if key in seen:
                    findings.append(f"{where}: {label!r} and {seen[key]!r} "
                                    f"share the access key {key!r}")
                else:
                    seen[key] = label
            if "items" in it:
                walk(f"{where} > {_plain(label)}", it["items"])

    for menu in menubar:
        walk(_plain(menu.get("label", "")), menu.get("items", []))

    window = [m for m in menubar if m.get("id") == "window_menu"]
    if len(window) != 1:
        findings.append(f"expected exactly one window_menu, found {len(window)}")
    else:
        panels = [_plain(it.get("label", "")) for it in window[0].get("items", [])
                  if isinstance(it, dict) and it.get("action") == "toggle_panel"]
        if not panels:
            findings.append("the Window menu has no toggle_panel items")
        want = sorted(panels, key=str.casefold)
        if panels != want:
            first = next(i for i, (a, b) in enumerate(zip(panels, want)) if a != b)
            findings.append(f"Window menu panels are not alphabetical: item "
                            f"{first + 1} is {panels[first]!r}, expected "
                            f"{want[first]!r}")
    return findings, read


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

    # 4. The menu laws. Each arm names the finding it must produce, so an arm
    #    that fires for a DIFFERENT reason does not pass.
    def law_menubar():
        return [
            {"id": "file", "label": "&File", "items": [
                {"action": "a", "label": "&New"},
                {"label": "&Workspace", "items": [{"action": "b", "label": "&Reset"}]},
            ]},
            {"id": "window_menu", "label": "&Window", "items": [
                {"action": "toggle_pane", "label": "Toolbar"},
                {"action": "toggle_panel", "label": "&Align"},
                {"action": "toggle_panel", "label": "&Brushes"},
                {"action": "toggle_panel", "label": "&Color"},
            ]},
        ]
    clean, read = menu_law_findings(law_menubar())
    if clean:
        failures.append(f"a clean menubar produced law findings: {clean}")
    if read != 7:
        failures.append(f"the law walk read {read} items of a menubar holding 7")
    if menu_law_findings([])[1] != 0 or not menu_law_findings([])[0]:
        failures.append("an EMPTY menubar did not produce a finding")
    law_arms = {
        "share the access key 'n'":
            lambda mb: mb[0]["items"].append({"action": "c", "label": "Ope&n"}),
        "share the access key 'r'":  # inside a submenu, other case
            lambda mb: mb[0]["items"][1]["items"].append({"action": "c", "label": "&revert"}),
        "not alphabetical":
            lambda mb: mb[1]["items"].reverse(),
        "has no toggle_panel items":
            lambda mb: mb[1].__setitem__("items", mb[1]["items"][:1]),
        "expected exactly one window_menu":
            lambda mb: mb.pop(),
    }
    for want, fn in law_arms.items():
        mb = law_menubar()
        fn(mb)
        got = menu_law_findings(mb)[0]
        if not any(want in f for f in got):
            failures.append(f"the law arm {want!r} did not fire (got {got})")
    if menu_law_findings(law_menubar())[0]:
        failures.append("a law arm mutated the shared probe")
    if _access_key("Fish && &Chips") != "c" or _access_key("A && B") is not None:
        failures.append("_access_key does not skip an escaped && ")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}", file=sys.stderr)
    if failures:
        return 1
    print(f"check_menu_structure SELF-TEST: OK (empty projection fatal proven "
          f"FIRST; action/label/shortcut/separator/submenu all carried; "
          f"{len(edits)} distinct drifts each move the snapshot; "
          f"{len(law_arms)} menu-law arms each fire their own finding).")
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

    findings, read = menu_law_findings(workspace["menubar"])
    for f in findings:
        print(f"FAIL: {f}", file=sys.stderr)
    if findings:
        return 1
    print(f"OK: menu laws hold over {read} items (access keys unique per "
          f"list; Window menu panels alphabetical).")

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
