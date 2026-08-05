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

Run `python scripts/check_action_refs.py` to verify, `--self-test` to prove the
gate can still go RED.

WHY --self-test EXISTS
----------------------
This gate is three collectors and a set difference. If any collector silently
returned `[]` — a renamed bundle key, a shape change in `panels`, a `behavior`
list that moved — the set difference would be empty, no reference would be
unresolved, and the gate would print OK forever while watching nothing. That is
the failure mode this whole class of instrument has: it reports success by not
looking.

So `--self-test` does not check that the gate passes. It checks that each
collector FINDS something in a bundle built to contain exactly one reference,
and that every rejection path can be triggered. An empty collection is fatal
and is asserted FIRST, per the 2026-08-05 prove-the-failure-first law.

Until 2026-08-05 this script parsed no arguments at all, so `--self-test` — and
any other flag — was silently ignored and exited 0. A sweep that ran the flag
across the gate set scored it green for implementing nothing.
"""

import argparse
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


def collect_all(ws: dict) -> list:
    """Every (action, where) reference in the bundle, from all three seams."""
    return _collect_menubar(ws) + _collect_panels(ws) + _collect_toolbar(ws)


def evaluate(ws: dict, baseline: set) -> dict:
    """The gate's whole judgement, as data, so it can be tested without files."""
    resolvable = _resolvable(ws)
    refs = collect_all(ws)
    dangling = {a: w for (a, w) in refs if a not in resolvable}
    dangling_names = set(dangling)
    return {
        "refs": refs,
        "resolvable": resolvable,
        "dangling": dangling,
        # New debt: an unresolved ref not covered by the baseline. This is the
        # real guard — it is what would have failed on export_to_pdf.
        "new_dangling": dangling_names - baseline,
        # Stale baseline: a listed action is now resolved (implemented or
        # removed). Force the debt list to shrink rather than harbor
        # no-longer-true entries.
        "stale": baseline - dangling_names,
    }


def _probe_bundle() -> dict:
    """A bundle carrying exactly one reference at each of the three seams.

    Nothing is resolvable, so every reference is dangling and countable. Each
    action name records WHICH collector must have found it, so a collector that
    stops working names itself.
    """
    return {
        "actions": {},
        "native_intercepts": [],
        "menubar": [{"id": "file", "label": "File",
                     "items": [{"action": "from_menubar", "label": "Item"}]}],
        "panels": {"p1": {"behavior": [{"event": "click", "action": "from_panel"}]}},
        "tool_grid": [{"type": "icon_button", "action": "from_toolbar"}],
    }


def _self_test() -> int:
    """Prove the gate can still REJECT. Touches no bundle and no baseline file."""
    failures = []
    seams = {"menubar": "from_menubar",
             "panels": "from_panel",
             "tool_grid": "from_toolbar"}

    # 1. AN EMPTY COLLECTION IS FATAL, and it is asserted before anything else.
    #    If the collectors returned nothing, every check below would pass
    #    vacuously and this whole self-test would be the instrument it exists
    #    to forbid.
    found = {a for (a, _) in collect_all(_probe_bundle())}
    if not found:
        print("SELF-TEST FAIL: the collectors found NOTHING in a bundle built to "
              "contain three references. Every assertion below would be vacuously "
              "true, so this is fatal rather than a failure count.", file=sys.stderr)
        return 1

    # 2. EVERY seam is walked. One dead collector still leaves the gate green on
    #    the real bundle, because an unwatched seam reports no dangling refs.
    for seam, name in seams.items():
        if name not in found:
            failures.append(f"the {seam} collector found no reference")

    # 3. An unresolved reference is reported as NEW debt.
    if evaluate(_probe_bundle(), set())["new_dangling"] != set(seams.values()):
        failures.append("an unresolved reference was not reported as new debt")

    # 4. A declared action resolves.
    ws = _probe_bundle()
    ws["actions"] = {n: {} for n in seams.values()}
    if evaluate(ws, set())["new_dangling"]:
        failures.append("a declared `actions:` entry was still reported unresolved")

    # 5. A native intercept resolves — the NATIVE_BOUNDARY.md path, which is a
    #    separate branch of `_resolvable` and would not be exercised by 4.
    ws = _probe_bundle()
    ws["native_intercepts"] = list(seams.values())
    if evaluate(ws, set())["new_dangling"]:
        failures.append("a `native_intercepts:` entry did not resolve")

    # 6. The baseline suppresses the debt it LISTS and nothing else. Both halves
    #    matter: a baseline that suppressed everything would hide export_to_pdf.
    verdict = evaluate(_probe_bundle(), {"from_menubar"})
    if "from_menubar" in verdict["new_dangling"]:
        failures.append("a baselined action was still reported as new debt")
    if "from_panel" not in verdict["new_dangling"]:
        failures.append("the baseline suppressed an action it does not list")

    # 7. A baseline entry that now resolves is STALE — the debt only shrinks.
    ws = _probe_bundle()
    ws["actions"] = {n: {} for n in seams.values()}
    if evaluate(ws, {"from_menubar"})["stale"] != {"from_menubar"}:
        failures.append("a baseline entry that now resolves was not reported stale")

    # 8. A bare "separator" string in a menu is skipped, not crashed on.
    ws = _probe_bundle()
    ws["menubar"][0]["items"].insert(0, "separator")
    if {a for (a, _) in collect_all(ws)} != found:
        failures.append("a bare 'separator' menu entry changed the reference set")

    # 9. Submenu recursion: a reference one level down is still reached.
    ws = _probe_bundle()
    ws["menubar"][0]["items"] = [{"label": "Sub", "items": [{"action": "nested"}]}]
    if "nested" not in {a for (a, _) in collect_all(ws)}:
        failures.append("a reference inside a submenu was not collected")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}", file=sys.stderr)
    if failures:
        return 1
    print("check_action_refs SELF-TEST: OK (empty collection fatal proven FIRST; "
          "all three collectors reach their seam; unresolved refs rejected; "
          "declared and native-intercepted actions both resolve; baseline "
          "suppresses only what it lists; stale baseline caught; separators and "
          "submenus handled).")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Action referential-integrity gate.")
    ap.add_argument("--self-test", action="store_true",
                    help="prove the gate can still reject; touches no bundle")
    args = ap.parse_args()
    if args.self_test:
        return _self_test()

    if not _WORKSPACE_JSON.exists():
        print(f"FAIL: {_WORKSPACE_JSON} missing (regenerate the bundle).", file=sys.stderr)
        return 1
    ws = json.loads(_WORKSPACE_JSON.read_text(encoding="utf-8"))
    baseline = set(json.loads(_BASELINE.read_text(encoding="utf-8")).get("unresolved_actions", []))

    verdict = evaluate(ws, baseline)
    refs = verdict["refs"]
    resolvable = verdict["resolvable"]
    dangling = verdict["dangling"]
    new_dangling = verdict["new_dangling"]
    stale = verdict["stale"]

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
