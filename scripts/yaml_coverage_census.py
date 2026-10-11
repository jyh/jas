#!/usr/bin/env python3
"""The YAML coverage census: each spec item -> its deciding observable and its check.

Minute ruling 4 (the three-level testing process) decides FUNCTION at the core's
STATE, LOOK-structure at the WIDGET TREE, and LOOK-pixels by screenshot against a
FROZEN baseline. This tool walks the compiled spec (`workspace/workspace.json`)
and, for every item of the classes it censuses, reports:

  * the item's DECIDING OBSERVABLE: `state`, `tree` or `pixels`;
  * the CHECK that decides it today (a corpus or golden that a port is compared
    against), or else exactly ONE of three bins:
      - NOT_INSTRUMENTABLE: a level-3 candidate, with the reason stated;
      - NOT_YET_BUILT: the check is work that has not been done;
      - UNDERSPECIFIED: the spec does not state the behaviour in a form a check
        could take its expectation from, so the statement must change first.

The bins are decided by RULES written below, never by a hand list. A rule that
cannot decide an item reports it as UNCLASSIFIED, loudly, rather than guessing.

WHAT "COVERED" MEANS HERE, AND ITS LIMITS (they ride with every verdict)
------------------------------------------------------------------------
"Covered" means a committed corpus or golden names the item AND some active port
(Rust or Swift) consumes that corpus. It does NOT mean:
  * that the corpus case asserts every clause of the item's description;
  * that the running APP (rather than the port's core) was driven: no corpus
    here drives a live window;
  * that a `tree` item's RENDERED widgets were read: the panel trees are the
    shared interpreter's PLAN.
Every report prints these limits beside its numbers.

Classes NOT censused yet are DECLARED in the report with their counts, so the
denominator is never silently narrower than the spec.

Usage:
    python3 scripts/yaml_coverage_census.py            # summary
    python3 scripts/yaml_coverage_census.py --json OUT # + the certificate
    python3 scripts/yaml_coverage_census.py --self-test
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

STATE, TREE, PIXELS = "state", "tree", "pixels"
COVERED = "COVERED"
NOT_INSTRUMENTABLE = "NOT_INSTRUMENTABLE"
NOT_YET_BUILT = "NOT_YET_BUILT"
UNDERSPECIFIED = "UNDERSPECIFIED"
UNCLASSIFIED = "UNCLASSIFIED"
BINS = (NOT_INSTRUMENTABLE, NOT_YET_BUILT, UNDERSPECIFIED)

# Classes in the compiled spec this version does not census, declared by name so
# the report can print their counts. A class added to the spec that is in
# neither list is reported as UNDECLARED, which fails the run.
CENSUSED = ("actions", "tools", "shortcuts", "state", "menubar", "panels",
            "dialogs", "icons")
NOT_CENSUSED = ("native_intercepts", "layout", "default_layouts", "elements",
                "features", "preferences", "runtime_contexts",
                "lexical_contexts", "theme", "concepts", "templates",
                "swatch_libraries", "gradient_libraries", "brush_libraries")
METADATA = ("version", "schema_version", "app")

# OS-native chrome: the irreducible residue of TESTING_STRATEGY.md section 1.
_NATIVE_CHROME = re.compile(r"native (file|save|open|print)\b.*dialog|native file dialog")


def _load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _fixture_cases(root, sub):
    """Every non-expected JSON case list under test_fixtures/<sub>/."""
    out = []
    for f in sorted(glob.glob(os.path.join(root, "test_fixtures", sub, "*.json"))):
        if f.endswith("_expected.json"):
            continue
        data = _load(f)
        out.extend(data if isinstance(data, list) else [data])
    return out


def _normalize_chord(text):
    """`Ctrl+Shift+S` -> ('S', ctrl, shift, alt, meta), the key corpus's form."""
    parts = text.split("+")
    key = parts[-1].upper()
    mods = {p.lower() for p in parts[:-1]}
    return (key, "ctrl" in mods, "shift" in mods, "alt" in mods,
            "meta" in mods or "cmd" in mods)


def _menu_items(menus):
    """Every menu item that has an id, recursively (submenus included), with
    its PATH: [menu index, item index, ...], where every list position counts,
    separators included (the scheme menu_state.json's rows use)."""
    out = []

    def walk(items, path):
        for i, it in enumerate(items or []):
            if isinstance(it, dict):
                if it.get("id"):
                    out.append((path + [i], it))
                walk(it.get("items"), path + [i])
    for mi, m in enumerate(menus):
        walk(m.get("items"), [mi])
    return out


def _effects_flat(effects):
    return [e for e in (effects or []) if isinstance(e, dict)]


# ---------------------------------------------------------------------------
# evidence: what the committed corpora and goldens name
# ---------------------------------------------------------------------------

def gather_evidence(root):
    ev = {}
    ev["actions_dispatched"] = {
        a["action"] for case in _fixture_cases(root, "actions")
        for a in case.get("actions", []) if isinstance(a, dict) and "action" in a}
    # Ops tested at the op layer whose NAME is also an action's. They exercise
    # the layer beneath the action, not the action's spec effects, so they do
    # not cover it; the report counts them so the gap is visible, not silent.
    ev["same_named_ops"] = set()
    for sub, key in (("operations", "name"), ("preservation", "op"),
                     ("workspace_operations", "op")):
        def walk_ops(v, key=key):
            if isinstance(v, dict):
                for k, x in v.items():
                    if k == key and isinstance(x, str):
                        ev["same_named_ops"].add(x)
                    walk_ops(x)
            elif isinstance(v, list):
                for x in v:
                    walk_ops(x)
        for f in glob.glob(os.path.join(root, "test_fixtures", sub, "*.json")):
            walk_ops(_load(f))
    ev["gesture_tools"] = {c["tool"] for c in _fixture_cases(root, "gestures") if "tool" in c}
    # A shortcut is covered when its chord is a case AND the case's expected
    # resolution (`expected_json`, by case name) is the shortcut's action.
    chords = set()
    for doc in _fixture_cases(root, "keys"):
        exp_path = os.path.join(root, "test_fixtures", "keys", doc.get("expected_json", ""))
        resolved = {}
        if doc.get("expected_json") and os.path.exists(exp_path):
            resolved = {e["name"]: (e.get("result") or {}).get("action")
                        for e in _load(exp_path)}
        for c in doc.get("cases", []):
            ch = c.get("chord") or {}
            chords.add(((str(ch.get("key", "")).upper(), bool(ch.get("ctrl")),
                         bool(ch.get("shift")), bool(ch.get("alt")), bool(ch.get("meta"))),
                        resolved.get(c.get("name"))))
    ev["key_chords"] = chords
    # Menu items: algorithms/menu_state.json, which Rust AND Swift replay, has a
    # row per actionable item: {path, action, enabled, checked}.
    # expected/menu_structure.json is NOT evidence: only a script compares it,
    # bundle against golden (scripts/check_menu_structure.py), and no port reads it.
    ev["menu_paths"] = set()
    mst = os.path.join(root, "test_fixtures", "algorithms", "menu_state.json")
    if os.path.exists(mst):
        for case in _load(mst):
            for r in case.get("expected", []):
                ev["menu_paths"].add(tuple(r.get("path", [])))
    # The map each app STARTS from, which Rust (web app and engine) and Swift
    # compare with the reference's spec defaults over every state variable.
    ism = os.path.join(root, "test_fixtures", "algorithms", "initial_state_map.json")
    ev["initial_state"] = (set(_load(ism)[0].get("expected", {}))
                           if os.path.exists(ism) else set())
    wt = os.path.join(root, "test_fixtures", "algorithms", "panel_widget_tree.json")
    ev["tree_panels"] = {c["name"] for c in _load(wt)} if os.path.exists(wt) else set()
    ev["dialog_trees"] = set()  # no dialog widget-tree golden exists (2026-10-10)
    ev["icon_baselines"] = set()  # the rsvg references are NOT committed
    return ev


# ---------------------------------------------------------------------------
# the census
# ---------------------------------------------------------------------------

def _row(cls, item_id, observable, status, check_or_reason):
    return {"class": cls, "id": item_id, "observable": observable,
            "status": status, "detail": check_or_reason}


def census(spec, ev):
    rows = []

    for name, a in spec.get("actions", {}).items():
        effs = _effects_flat(a.get("effects"))
        logs = [e["log"] for e in effs if list(e) == ["log"]]
        log_only = bool(effs) and len(logs) == len(effs)
        text = " ".join(logs).lower()
        if name in ev["actions_dispatched"]:
            rows.append(_row("actions", name, STATE, COVERED, "test_fixtures/actions"))
        elif log_only and _NATIVE_CHROME.search(text):
            rows.append(_row("actions", name, STATE, NOT_INSTRUMENTABLE,
                             "OS-native chrome (a native file/print dialog)"))
        elif log_only and "deferred" in text:
            rows.append(_row("actions", name, STATE, NOT_YET_BUILT,
                             "the feature itself is deferred in the spec"))
        elif log_only:
            rows.append(_row("actions", name, STATE, UNDERSPECIFIED,
                             "log-only: the behaviour exists only as prose, so a "
                             "check could take its expectation only from a port"))
        elif not effs:
            rows.append(_row("actions", name, STATE, UNDERSPECIFIED, "no effects"))
        else:
            rows.append(_row("actions", name, STATE, NOT_YET_BUILT,
                             "executable effects, no corpus case dispatches it"))

    for tid, t in spec.get("tools", {}).items():
        if tid in ev["gesture_tools"]:
            rows.append(_row("tools", tid, STATE, COVERED, "test_fixtures/gestures"))
        elif not t.get("handlers"):
            rows.append(_row("tools", tid, STATE, UNDERSPECIFIED,
                             "no handlers: the tool is native, its behaviour is prose"))
        else:
            rows.append(_row("tools", tid, STATE, NOT_YET_BUILT,
                             "handlers declared, no gesture case uses the tool"))

    for s in spec.get("shortcuts", []):
        sid = f'{s.get("key")} -> {s.get("action")}'
        if (_normalize_chord(str(s.get("key", ""))), s.get("action")) in ev["key_chords"]:
            rows.append(_row("shortcuts", sid, STATE, COVERED, "test_fixtures/keys"))
        else:
            rows.append(_row("shortcuts", sid, STATE, NOT_YET_BUILT,
                             "no key-resolution case for this chord"))

    # test_fixtures/expected/state_defaults.json is NOT evidence: both ports
    # emit it from a HAND-TYPED literal of 12 variables (state_defaults_json in
    # jas_dioxus/src/workspace/test_json.rs, stateDefaultsJson in
    # WorkspaceTestJson.swift), so it compares a typed list with a typed list
    # and reads no port's store. The observable is each app's initial LIVE
    # state map (defaults overlaid by live values), which nothing compares yet.
    for k, v in spec.get("state", {}).items():
        if k in ev["initial_state"]:
            rows.append(_row("state", k, STATE, COVERED,
                             "test_fixtures/algorithms/initial_state_map.json (the "
                             "starting value: Rust web app, Rust engine, Swift)"))
        elif isinstance(v, dict) and not v.get("description"):
            rows.append(_row("state", k, STATE, UNDERSPECIFIED, "no description"))
        else:
            rows.append(_row("state", k, STATE, NOT_YET_BUILT,
                             "no check reads a port's live initial state map (the "
                             "state_defaults golden is a typed literal in both ports)"))

    for path, it in _menu_items(spec.get("menubar", [])):
        if tuple(path) in ev["menu_paths"]:
            rows.append(_row("menu_items", it["id"], TREE, COVERED,
                             "test_fixtures/algorithms/menu_state.json (Rust + Swift)"))
        elif "items" in it:
            rows.append(_row("menu_items", it["id"], TREE, NOT_YET_BUILT,
                             "a submenu parent has no state row; only a bundle "
                             "snapshot script checks it"))
        else:
            rows.append(_row("menu_items", it["id"], TREE, NOT_YET_BUILT,
                             "no menu_state row at this path"))

    for pid, p in spec.get("panels", {}).items():
        if pid in ev["tree_panels"]:
            rows.append(_row("panels", pid, TREE, COVERED,
                             "test_fixtures/algorithms/panel_widget_tree.json (the PLAN)"))
        else:
            rows.append(_row("panels", pid, TREE, NOT_YET_BUILT, "no widget-tree golden"))
        rows.append(_row("panel_pixels", pid, PIXELS, NOT_YET_BUILT,
                         "no frozen screenshot baseline exists"))

    for did, d in spec.get("dialogs", {}).items():
        if did in ev["dialog_trees"]:
            rows.append(_row("dialogs", did, TREE, COVERED, "dialog widget-tree golden"))
        elif not d.get("content"):
            rows.append(_row("dialogs", did, TREE, UNDERSPECIFIED, "no content"))
        else:
            rows.append(_row("dialogs", did, TREE, NOT_YET_BUILT,
                             "no dialog widget-tree golden exists"))
        rows.append(_row("dialog_pixels", did, PIXELS, NOT_YET_BUILT,
                         "no frozen screenshot baseline exists"))

    for iid in spec.get("icons", {}):
        if iid in ev["icon_baselines"]:
            rows.append(_row("icons", iid, PIXELS, COVERED, "committed baseline"))
        else:
            rows.append(_row("icons", iid, PIXELS, NOT_YET_BUILT,
                             "no committed baseline (the rsvg references the Swift "
                             "icon test reads are not committed, so it skips)"))
    return rows


def undeclared_classes(spec):
    known = set(CENSUSED) | set(NOT_CENSUSED) | set(METADATA)
    return sorted(k for k in spec if k not in known)


def summarize(rows):
    by = {}
    for r in rows:
        c = by.setdefault(r["class"], {"total": 0, COVERED: 0, **{b: 0 for b in BINS},
                                       UNCLASSIFIED: 0, "observable": r["observable"]})
        c["total"] += 1
        c[r["status"]] += 1
    return by


def _count(v):
    return len(v) if isinstance(v, (list, dict)) else 1


def render(spec, rows, provenance, ev=None):
    by = summarize(rows)
    total = len(rows)
    cov = sum(1 for r in rows if r["status"] == COVERED)
    lines = [f"yaml_coverage_census: spec sha256/16={provenance['spec_sha256_16']} "
             f"build={provenance['build']} platform={provenance['platform']}"]
    lines.append(f"{'class':<14} {'obs':<7} {'total':>5} {'COVERED':>8} "
                 f"{'NOT_INSTR':>9} {'NOT_BUILT':>9} {'UNDERSPEC':>9}")
    for cls, c in by.items():
        lines.append(f"{cls:<14} {c['observable']:<7} {c['total']:>5} {c[COVERED]:>8} "
                     f"{c[NOT_INSTRUMENTABLE]:>9} {c[NOT_YET_BUILT]:>9} {c[UNDERSPECIFIED]:>9}")
    for obs in (STATE, TREE, PIXELS):
        n = sum(1 for r in rows if r["observable"] == obs)
        k = sum(1 for r in rows if r["observable"] == obs and r["status"] == COVERED)
        lines.append(f"  {obs:<7} covered {k} of {n}")
    lines.append(f"TOTAL covered {cov} of {total} censused item-observables")
    if ev is not None:
        shadow = sorted(r["id"] for r in rows if r["class"] == "actions"
                        and r["status"] != COVERED and r["id"] in ev["same_named_ops"])
        lines.append(f"NOTE: {len(shadow)} uncovered action(s) share a name with an op "
                     f"tested at the op layer beneath them (not counted as covered): "
                     + ", ".join(shadow))
    lines.append("NOT CENSUSED (declared, counted): " + ", ".join(
        f"{k}={_count(spec[k])}" for k in NOT_CENSUSED if k in spec))
    lines.append("LIMITS: covered = a committed corpus/golden names the item and an "
                 "active port consumes it; it does NOT mean every clause of the "
                 "description is asserted, nor that a live app window was driven; "
                 "`tree` coverage is the shared interpreter's PLAN, not the "
                 "rendered widgets; widgets are censused at their panel's or "
                 "dialog's granularity, not one by one; a submenu parent "
                 "is checked only by a bundle-snapshot script; goldens that only "
                 "a script compares with the bundle, or that a port emits from a "
                 "typed literal, are not counted.")
    return "\n".join(lines)


def provenance_of(root, spec_path):
    with open(spec_path, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()[:16]
    try:
        sha = subprocess.run(["git", "-C", root, "rev-parse", "--short=8", "HEAD"],
                             capture_output=True, text=True, encoding="utf-8", check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        sha = "UNKNOWN"
    return {"spec_sha256_16": digest, "build": sha,
            "platform": "corpus (no live app; platform-independent)"}


# ---------------------------------------------------------------------------
# self-test: a synthetic spec and fixture tree, one arm per rule
# ---------------------------------------------------------------------------

def self_test():
    failures = []
    arms = 0
    with tempfile.TemporaryDirectory() as d:
        def put(rel, obj):
            p = os.path.join(d, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8", newline="") as f:
                json.dump(obj, f)
        put("test_fixtures/actions/a.json",
            [{"name": "x", "actions": [{"action": "covered_act"}]}])
        put("test_fixtures/actions/a_expected.json", {"actions": [{"action": "decoy"}]})
        put("test_fixtures/gestures/g.json", [{"name": "g", "tool": "rect"}])
        put("test_fixtures/keys/k.json",
            [{"name": "k", "expected_json": "k_expected.json",
              "cases": [{"name": "c1", "chord": {"key": "N", "ctrl": True}},
                        {"name": "c2", "chord": {"key": "W", "ctrl": True}}]}])
        put("test_fixtures/keys/k_expected.json",
            [{"name": "c1", "result": {"action": "new", "params": {}}},
             {"name": "c2", "result": {"action": "close", "params": {}}}])
        # Both shapes copied from the real files' own lines, never invented.
        # A DECOY: the state golden is present and must NOT count (see census()).
        put("test_fixtures/expected/state_defaults.json",
            {"count": 1, "variables": [{"default": 1, "name": "fill", "type": "number"}]})
        # A DECOY: a script-only golden naming `golden_only` must NOT count.
        put("test_fixtures/expected/menu_structure.json",
            {"menus": [{"label": "&File", "items": [
                {"action": "golden_only", "label": "G", "shortcut": ""}]}]})
        put("test_fixtures/algorithms/menu_state.json",
            [{"name": "x", "function": "menu_state", "args": {}, "expected": [
                {"path": [0, 0], "action": "new_document", "enabled": True, "checked": None},
                {"path": [0, 4, 0], "action": "in_sub", "enabled": True, "checked": None}]}])
        put("test_fixtures/algorithms/panel_widget_tree.json", [{"name": "p1"}])
        put("test_fixtures/algorithms/initial_state_map.json",
            [{"name": "no_document", "function": "initial_state_map", "args": {},
              "expected": {"started": 1}}])
        spec = {
            "actions": {
                "covered_act": {"effects": [{"log": "x"}]},
                "decoy": {"effects": [{"set": {"a": 1}}]},
                "open_file": {"effects": [{"log": "open_file: show native file dialog"}]},
                "later": {"effects": [{"log": "later (deferred)"}]},
                "undo": {"effects": [{"log": "undo"}]},
                "empty": {"effects": []},
            },
            "tools": {"rect": {"handlers": {"a": 1}}, "type": {"handlers": {}},
                      "pen": {"handlers": {"a": 1}}},
            "shortcuts": [{"key": "Ctrl+N", "action": "new"}, {"key": "Ctrl+Shift+N", "action": "x"},
                          {"key": "Ctrl+W", "action": "not_close"}],
            "state": {"started": {"description": "d"}, "fill": {"description": "d"}, "bare": {"default": 1},
                      "described": {"description": "d"}},
            "menubar": [{"id": "file", "items": [
                {"id": "m_new", "action": "new_document", "label": "&New"},
                {"id": "m_relabel", "action": "new_document", "label": "&Other"},
                "separator",
                {"id": "sub", "items": [{"id": "m_deep", "action": "deep", "label": "D"}]},
                {"id": "sub2", "label": "Sub", "items": [
                    {"id": "m_in_sub", "action": "in_sub", "label": "In"}]},
                {"id": "m_golden_only", "action": "golden_only", "label": "G"}]}],
            "panels": {"p1": {}, "p2": {}},
            "dialogs": {"d1": {"content": {"type": "col"}}, "d2": {}},
            "icons": {"i1": {}},
            "elements": {"e": 1},
        }
        rows = census(spec, gather_evidence(d))
        st = {(r["class"], r["id"]): r["status"] for r in rows}

        def expect(key, want):
            nonlocal arms
            arms += 1
            got = st.get(key)
            if got != want:
                failures.append(f"{key}: want {want}, got {got}")
        expect(("actions", "covered_act"), COVERED)
        expect(("actions", "decoy"), NOT_YET_BUILT)  # an _expected file is not a dispatch
        expect(("actions", "open_file"), NOT_INSTRUMENTABLE)
        expect(("actions", "later"), NOT_YET_BUILT)
        expect(("actions", "undo"), UNDERSPECIFIED)
        expect(("actions", "empty"), UNDERSPECIFIED)
        expect(("tools", "rect"), COVERED)
        expect(("tools", "type"), UNDERSPECIFIED)
        expect(("tools", "pen"), NOT_YET_BUILT)
        expect(("shortcuts", "Ctrl+N -> new"), COVERED)
        expect(("shortcuts", "Ctrl+Shift+N -> x"), NOT_YET_BUILT)  # a modifier distinguishes
        expect(("shortcuts", "Ctrl+W -> not_close"), NOT_YET_BUILT)  # the chord resolves elsewhere
        expect(("state", "fill"), NOT_YET_BUILT)  # a typed-literal golden is not evidence
        expect(("state", "started"), COVERED)  # the initial state map names it
        expect(("state", "bare"), UNDERSPECIFIED)
        expect(("state", "described"), NOT_YET_BUILT)
        expect(("menu_items", "m_new"), COVERED)
        expect(("menu_items", "m_deep"), NOT_YET_BUILT)  # a submenu item is censused
        expect(("menu_items", "m_relabel"), NOT_YET_BUILT)  # no row at its path
        expect(("menu_items", "sub2"), NOT_YET_BUILT)  # a submenu parent has no state row
        expect(("menu_items", "m_in_sub"), COVERED)  # [0,4,0]: the separator counts
        expect(("menu_items", "m_golden_only"), NOT_YET_BUILT)  # a script-only golden
        expect(("menu_items", "file"), None)  # a top-level menu is not an item
        expect(("panels", "p1"), COVERED)
        expect(("panels", "p2"), NOT_YET_BUILT)
        expect(("panel_pixels", "p1"), NOT_YET_BUILT)
        expect(("dialogs", "d1"), NOT_YET_BUILT)
        expect(("dialogs", "d2"), UNDERSPECIFIED)
        expect(("icons", "i1"), NOT_YET_BUILT)
        arms += 1
        if any(r["status"] == UNCLASSIFIED for r in rows):
            failures.append("a row is UNCLASSIFIED")
        arms += 1
        if undeclared_classes(dict(spec, brand_new={})) != ["brand_new"]:
            failures.append("an undeclared spec class must be reported")
        arms += 1
        text = render(spec, rows, {"spec_sha256_16": "0", "build": "0", "platform": "t"})
        if "LIMITS:" not in text or "NOT CENSUSED" not in text or "elements=1" not in text:
            failures.append("the report must carry its limits and the uncensused classes")
    for f in failures:
        print("FAIL:", f)
    print(f"yaml_coverage_census --self-test: {arms} arm(s), {len(failures)} failure(s)")
    return 1 if failures else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--json", help="write the certificate (every row) to this path")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)
    if args.self_test:
        return self_test()
    spec_path = os.path.join(args.root, "workspace", "workspace.json")
    spec = _load(spec_path)
    bad = undeclared_classes(spec)
    if bad:
        print(f"yaml_coverage_census: REFUSED: undeclared spec class(es) {bad}; "
              "add each to CENSUSED or NOT_CENSUSED")
        return 2
    ev = gather_evidence(args.root)
    rows = census(spec, ev)
    prov = provenance_of(args.root, spec_path)
    print(render(spec, rows, prov, ev))
    if args.json:
        with open(args.json, "w", encoding="utf-8", newline="") as f:
            json.dump({"provenance": prov, "summary": summarize(rows), "rows": rows},
                      f, indent=1, sort_keys=True)
            f.write("\n")
    if any(r["status"] == UNCLASSIFIED for r in rows):
        print("yaml_coverage_census: UNCLASSIFIED rows present")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
