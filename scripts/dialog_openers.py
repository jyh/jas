#!/usr/bin/env python3
"""Which dialogs a level-2 run can open with no person, and by what (flask STATUS 749).

A dialog's live widget tree is read on Windows by
`rendered_tree.ps1 -Panel <dialog id> -Opener <menubar item id>`, which opens
it through SB_MENU_SYNTH, the method a person's menu choice reaches. This
script derives that opener list from the spec, so the nightly never types one:

  * an OPENER is a menubar item (workspace/menubar.yaml) whose action
    (workspace/actions.yaml) opens the dialog at the TOP LEVEL of its effects,
    unconditionally. One opener per dialog, the first in menubar order.
  * every other dialog spec (workspace/dialogs/*.yaml, each file's top-level
    dialog ids) is UNCOVERED, with its reason: an opener under a condition
    (Quit opens Save Changes only when a document is modified), or no menubar
    opener at all (a panel menu, a widget, a tool, another dialog).

Nothing is dropped: covered + uncovered is every dialog id the specs define.

Usage:  python scripts/dialog_openers.py --self-test
        python scripts/dialog_openers.py --json      (from the repo root)
"""
import glob
import json
import os
import sys


def menubar_items(menubar):
    """(item id, action) for every menubar item with both, in menubar order."""
    out = []

    def walk(n):
        if isinstance(n, dict):
            if isinstance(n.get("id"), str) and isinstance(n.get("action"), str):
                out.append((n["id"], n["action"]))
            for v in n.values():
                walk(v)
        elif isinstance(n, list):
            for v in n:
                walk(v)
    walk(menubar)
    return out


def top_level_opens(effects):
    """Dialog ids an effect list opens UNCONDITIONALLY (its top level only)."""
    out = []
    for e in effects or []:
        if isinstance(e, dict) and isinstance(e.get("open_dialog"), dict):
            d = e["open_dialog"].get("id")
            if isinstance(d, str):
                out.append(d)
    return out


def nested_opens(effects):
    """(dialog id, the nearest enclosing `if` condition) for every open BELOW the top level."""
    out = []

    def walk(n, cond):
        if isinstance(n, dict):
            if isinstance(n.get("if"), dict) and isinstance(n["if"].get("condition"), str):
                cond = n["if"]["condition"]
            od = n.get("open_dialog")
            if isinstance(od, dict) and isinstance(od.get("id"), str):
                out.append((od["id"], cond))
            for k, v in n.items():
                if k != "open_dialog":
                    walk(v, cond)
        elif isinstance(n, list):
            for v in n:
                walk(v, cond)
    for e in effects or []:
        if isinstance(e, dict):
            for k, v in e.items():
                if k != "open_dialog":
                    walk(v if k != "if" else {"if": v}, None)
    return out


def effects_of(action):
    if isinstance(action, dict):
        return action.get("effects") or []
    return action if isinstance(action, list) else []


def derive(menubar, actions, dialog_ids):
    """-> {"covered": [{dialog, opener, action}], "uncovered": [{dialog, why}]}."""
    first, conditional = {}, {}
    for item, act in menubar_items(menubar):
        eff = effects_of(actions.get(act))
        for d in top_level_opens(eff):
            first.setdefault(d, (item, act))
        for d, cond in nested_opens(eff):
            conditional.setdefault(d, (item, cond or "(a nested effect)"))
    known = set(dialog_ids)
    covered, uncovered = [], []
    for d in sorted(known):
        if d in first:
            covered.append({"dialog": d, "opener": first[d][0], "action": first[d][1]})
        elif d in conditional:
            item, cond = conditional[d]
            uncovered.append({"dialog": d, "why": f"opened only under `{cond}` by {item}"})
        else:
            uncovered.append({"dialog": d, "why": "no menubar opener (a panel menu, a widget, a tool, or another dialog)"})
    for d in sorted(set(first) - known):
        uncovered.append({"dialog": d, "why": f"UNDEFINED: {first[d][0]} opens `{d}`, which no dialog spec defines"})
    return {"covered": covered, "uncovered": uncovered}


def dialog_ids_of(specs):
    """Every dialog id the parsed dialog files define, sorted."""
    ids = []
    for spec in specs:
        if isinstance(spec, dict):
            ids.extend(k for k in spec if isinstance(k, str))
    return sorted(ids)


def load(root):
    import yaml
    with open(os.path.join(root, "workspace", "menubar.yaml"), encoding="utf-8") as f:
        menubar = yaml.safe_load(f)
    with open(os.path.join(root, "workspace", "actions.yaml"), encoding="utf-8") as f:
        actions = yaml.safe_load(f)
    actions = actions.get("actions", actions)
    specs = []
    for p in sorted(glob.glob(os.path.join(root, "workspace", "dialogs", "*.yaml"))):
        with open(p, encoding="utf-8") as f:
            specs.append(yaml.safe_load(f))
    ids = dialog_ids_of(specs)
    return menubar, actions, ids


def self_test():
    fails = []
    ran = [0]

    def check(name, cond):
        ran[0] += 1
        if not cond:
            fails.append(name)

    mb = {"menubar": [
        {"id": "file_menu", "items": [
            {"id": "menu_setup", "action": "open_setup"},
            {"id": "menu_setup_again", "action": "open_setup"},
            {"id": "menu_quit", "action": "quit"},
            {"id": "menu_plain", "action": "plain"},
            {"id": "sub", "items": [{"id": "menu_print", "action": "open_print"}]}]}]}
    acts = {
        "open_setup": {"effects": [{"open_dialog": {"id": "setup"}}]},
        "open_print": {"effects": [{"set": {"x": 1}}, {"open_dialog": {"id": "print"}}]},
        "quit": {"effects": [{"if": {"condition": "doc.modified",
                                     "then": [{"open_dialog": {"id": "save_changes"}}],
                                     "else": [{"dispatch": "close_window"}]}}]},
        "plain": {"effects": [{"dispatch": "x"}]},
    }
    ids = ["print", "save_changes", "setup", "swatch_options"]
    try:
        got = derive(mb, acts, ids)
    except NotImplementedError:
        got = {"covered": [], "uncovered": []}
    cov = {c["dialog"]: c["opener"] for c in got["covered"]}
    unc = {u["dialog"]: u["why"] for u in got["uncovered"]}
    check("an unconditional top-level open is covered by its menubar item", cov.get("setup") == "menu_setup")
    check("one opener per dialog: the FIRST in menubar order", cov.get("setup") == "menu_setup")
    check("a submenu's item is an opener, and an open after another effect counts", cov.get("print") == "menu_print")
    check("an open under a condition is NOT an opener (Quit on a clean document quits)", "save_changes" not in cov)
    check("...it is UNCOVERED, and the reason names the condition and the item",
          "doc.modified" in unc.get("save_changes", "") and "menu_quit" in unc.get("save_changes", ""))
    check("a dialog no menubar item opens is uncovered by name", "no menubar" in unc.get("swatch_options", ""))
    check("nothing is dropped: covered + uncovered is every dialog id",
          sorted(list(cov) + list(unc)) == sorted(ids))
    check("covered is in dialog-id order, so the nightly's order is the spec's",
          [c["dialog"] for c in got["covered"]] == sorted(cov))
    check("a dialog id an action opens that no spec defines is uncovered as UNDEFINED, never run",
          "UNDEFINED" in derive(mb, {**acts, "open_setup": {"effects": [{"open_dialog": {"id": "ghost"}}]}},
                                ids)["uncovered"][-1]["why"] if got["covered"] else False)
    # Each top-level key of a dialog file IS a dialog id (save_changes.yaml holds
    # two, tool_alternates.yaml four); the file's name is not one (measured 11-09:
    # reading the name made Quit's `save_changes_window` vanish from the census).
    check("every top-level key of a dialog file is a dialog id, the file name none",
          dialog_ids_of([{"save_changes_tab": {"summary": "a"}, "save_changes_window": {"summary": "b"}},
                         {"print": {"summary": "c"}}]) == ["print", "save_changes_tab", "save_changes_window"])
    check("an empty or non-mapping file contributes no id, never its name",
          dialog_ids_of([None, [], {"print": {}}]) == ["print"])
    print(f"dialog_openers self-test: {ran[0] - len(fails)}/{ran[0]} passed")
    for f in fails:
        print("  FAIL:", f)
    return 1 if fails else 0


def main(argv):
    if argv[1:] == ["--self-test"]:
        return self_test()
    if argv[1:] == ["--json"]:
        print(json.dumps(derive(*load(".")), indent=1))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
