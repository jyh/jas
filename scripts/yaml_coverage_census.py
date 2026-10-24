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
import shutil
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

# Level-2 certificates: a LIVE app drove an item and read it back (§203 (a);
# the shape is flask's, STATUS-flask §225). One committed file per census row
# and platform; the reader keys each by the `row` INSIDE it, never by its
# filename, because a shortcut's id carries spaces and an arrow.
L2_DIR = os.path.join("prototypes", "sb_winui", "l2_certs")
L2_SCHEMA = "jas-l2-cert/1"
L2_EVIDENCE = ("e2e", "tree", "pixels")
L2_ARM_OK = ("PASS", "NOT APPLICABLE")
L2_CERTIFIED, L2_STALE = "CERTIFIED", "STALE"

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
    # The dialog-action corpus (test_fixtures/dialog_actions/), which Rust (the
    # engine's jas_dialog_event) and Swift (the overlay's store route) replay:
    # its plain action steps, and the action a CLICKED widget names by its
    # address. A widget addressed only by id or label is not resolved here, so
    # its action is not counted (a known under-count, never an over-count).
    for case in _fixture_cases(root, "dialog_actions"):
        for a in case.get("actions", []):
            if not isinstance(a, dict):
                continue
            if "action" in a:
                ev["actions_dispatched"].add(a["action"])
            de = a.get("dialog_event")
            if isinstance(de, dict) and de.get("event") == "click":
                pressed = (de.get("address") or {}).get("action")
                if isinstance(pressed, str):
                    ev["actions_dispatched"].add(pressed)
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
    # A DYNAMIC submenu's own observable is the entry list it generates (saved
    # layouts, appearances), not a row: algorithms/submenu_entries.json, which
    # the reference generates and Rust AND Swift replay, names each by `submenu`.
    sme = os.path.join(root, "test_fixtures", "algorithms", "submenu_entries.json")
    ev["dynamic_submenus"] = ({c.get("submenu") for c in _load(sme)}
                              if os.path.exists(sme) else set())
    # The map each app STARTS from, which Rust (web app and engine) and Swift
    # compare with the reference's spec defaults over every state variable.
    ism = os.path.join(root, "test_fixtures", "algorithms", "initial_state_map.json")
    ev["initial_state"] = (set(_load(ism)[0].get("expected", {}))
                           if os.path.exists(ism) else set())
    wt = os.path.join(root, "test_fixtures", "algorithms", "panel_widget_tree.json")
    ev["tree_panels"] = {c["name"] for c in _load(wt)} if os.path.exists(wt) else set()
    dt = os.path.join(root, "test_fixtures", "algorithms", "dialog_widget_tree.json")
    ev["dialog_trees"] = {c["name"] for c in _load(dt)} if os.path.exists(dt) else set()
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
        elif "items" in it and it["id"] in ev["dynamic_submenus"]:
            rows.append(_row("menu_items", it["id"], TREE, COVERED,
                             "test_fixtures/algorithms/submenu_entries.json (its "
                             "generated entries: reference + Rust + Swift)"))
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
            rows.append(_row("dialogs", did, TREE, COVERED,
                             "test_fixtures/algorithms/dialog_widget_tree.json (the PLAN)"))
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


def _canonical_sha16(node):
    """sha256 of `node` as canonical JSON (sorted keys, `,`/`:` separators,
    UTF-8 NOT ascii-escaped), first 16 hex."""
    blob = json.dumps(node, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()[:16]


# A row's class -> the spec key its node lives under, for the six classes whose
# id IS that key's member name. `shortcuts` and `menu_items` are found the way
# census() names them.
_SPEC_KEY_OF = {"actions": "actions", "tools": "tools", "state": "state",
                "panels": "panels", "panel_pixels": "panels",
                "dialogs": "dialogs", "dialog_pixels": "dialogs", "icons": "icons"}


def spec_node(spec, cls, item_id):
    """The compiled node a census row is ABOUT, or None when the census has no
    such row. The same mapping census() uses to name its rows."""
    if cls in _SPEC_KEY_OF:
        return spec.get(_SPEC_KEY_OF[cls], {}).get(item_id)
    if cls == "shortcuts":
        return next((s for s in spec.get("shortcuts", [])
                     if f'{s.get("key")} -> {s.get("action")}' == item_id), None)
    if cls == "menu_items":
        return next((it for _p, it in _menu_items(spec.get("menubar", []))
                     if it.get("id") == item_id), None)
    return None


def item_spec_sha(spec, cls, item_id):
    """The PER-ITEM spec hash a level-2 certificate pins (§203 (a)): only the
    item that moved goes stale, where a whole-spec hash would stale every
    certificate at every spec edit. None for a row the census does not have.
    Importable: flask's certificate writer uses this same function."""
    node = spec_node(spec, cls, item_id)
    return None if node is None else _canonical_sha16(node)


def _l2_refusal(root, spec, known, c):
    """Why certificate `c` is refused, or None. STALE is not a refusal."""
    if not isinstance(c, dict):
        return "not a JSON object"
    if c.get("schema") != L2_SCHEMA:
        return f"schema {c.get('schema')!r} is not {L2_SCHEMA}"
    if not isinstance(c.get("platform"), str) or not c["platform"]:
        return "no platform"
    row = c.get("row")
    key = (row.get("class"), row.get("id"), row.get("observable")) if isinstance(row, dict) else None
    if key not in known:
        return f"row {row!r} is not a census row"
    if not (isinstance(c.get("spec_sha"), str) and re.fullmatch(r"[0-9a-f]{16}", c["spec_sha"])):
        return "spec_sha is not 16 hex"
    if c.get("verdict") != L2_CERTIFIED:
        return f"verdict {c.get('verdict')!r} is not {L2_CERTIFIED}"
    arms = c.get("arms")
    if not isinstance(arms, dict) or not arms:
        return "no arms: a certificate must say what was checked"
    bad = {k: v for k, v in arms.items() if v not in L2_ARM_OK}
    if bad:
        return f"arm(s) neither PASS nor NOT APPLICABLE: {bad}"
    if c.get("evidence") not in L2_EVIDENCE:
        return f"evidence {c.get('evidence')!r} is not one of {L2_EVIDENCE}"
    base = c.get("baseline")
    if base is not None and not os.path.exists(os.path.join(root, base)):
        return f"baseline {base!r} does not exist"
    return None


def read_l2_certs(root, spec, rows):
    """Every committed level-2 certificate under L2_DIR, read and checked.
    Returns ({(platform, (class, id, observable)): (CERTIFIED|STALE, path)},
    [(path, why refused)]). A stale certificate is reported, never counted."""
    known = {(r["class"], r["id"], r["observable"]) for r in rows}
    out, refused = {}, []
    base = os.path.join(root, L2_DIR)
    for dirpath, _dirs, files in sorted(os.walk(base)):
        for fn in sorted(f for f in files if f.endswith(".json")):
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            try:
                c = _load(path)
            except (OSError, ValueError) as e:
                refused.append((rel, f"does not parse: {e}"))
                continue
            why = _l2_refusal(root, spec, known, c)
            if why:
                refused.append((rel, why))
                continue
            row = c["row"]
            key = (row["class"], row["id"], row["observable"])
            if (c["platform"], key) in out:
                refused.append((rel, f"a second certificate for {c['platform']} {key}"))
                continue
            now = item_spec_sha(spec, key[0], key[1])
            out[(c["platform"], key)] = (L2_CERTIFIED if c["spec_sha"] == now else L2_STALE, rel)
    return out, refused


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


def render(spec, rows, provenance, ev=None, l2=None):
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
    if l2 is not None:
        certs, refused = l2
        plats = sorted({p for p, _k in certs}) or ["windows"]
        for plat in plats:
            mine = [v for (p, _k), v in certs.items() if p == plat]
            n_ok = sum(1 for s, _r in mine if s == L2_CERTIFIED)
            n_st = sum(1 for s, _r in mine if s == L2_STALE)
            lines.append(f"LEVEL-2 ({plat}, a live app driven; {L2_DIR.replace(os.sep, '/')}): "
                         f"CERTIFIED {n_ok} · STALE {n_st} · REFUSED {len(refused)} "
                         f"of {len(rows)} rows")
        for (plat, key), (st, rel) in sorted(certs.items()):
            if st == L2_STALE:
                lines.append(f"  STALE {plat} {key[0]}/{key[1]}.{key[2]}: the item's spec moved since {rel}")
        for rel, why in refused:
            lines.append(f"  REFUSED {rel}: {why}")
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
        put("test_fixtures/dialog_actions/b.json",
            [{"name": "y", "actions": [
                {"action": "dlg_setup"},
                {"open_dialog": {"id": "d0"}},
                {"dialog_event": {"address": {"action": "dlg_committed"}, "event": "commit", "value": "1"}},
                {"dialog_event": {"address": {"action": "dlg_pressed", "label": "OK"}, "event": "click"}}]}])
        put("test_fixtures/dialog_actions/b_expected.json",
            {"actions": [{"dialog_event": {"address": {"action": "dlg_decoy"}, "event": "click"}}]})
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
        put("test_fixtures/algorithms/submenu_entries.json",
            [{"name": "x", "submenu": "sub", "function": "workspace_entries", "args": {}, "expected": []}])
        put("test_fixtures/algorithms/panel_widget_tree.json", [{"name": "p1"}])
        put("test_fixtures/algorithms/initial_state_map.json",
            [{"name": "no_document", "function": "initial_state_map", "args": {},
              "expected": {"started": 1}}])
        put("test_fixtures/algorithms/dialog_widget_tree.json", [{"name": "d0"}])
        spec = {
            "actions": {
                "covered_act": {"effects": [{"log": "x"}]},
                "decoy": {"effects": [{"set": {"a": 1}}]},
                "open_file": {"effects": [{"log": "open_file: show native file dialog"}]},
                "later": {"effects": [{"log": "later (deferred)"}]},
                "undo": {"effects": [{"log": "undo"}]},
                "empty": {"effects": []},
                "dlg_setup": {"effects": [{"set": {"a": 1}}]},
                "dlg_pressed": {"effects": [{"set": {"a": 1}}]},
                "dlg_committed": {"effects": [{"set": {"a": 1}}]},
                "dlg_decoy": {"effects": [{"set": {"a": 1}}]},
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
            "dialogs": {"d0": {"content": {"type": "col"}}, "d1": {"content": {"type": "col"}}, "d2": {}},
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
        expect(("actions", "dlg_setup"), COVERED)  # a dialog case's plain action step
        expect(("actions", "dlg_pressed"), COVERED)  # the action a clicked widget names
        expect(("actions", "dlg_committed"), NOT_YET_BUILT)  # a commit is not a press
        expect(("actions", "dlg_decoy"), NOT_YET_BUILT)  # an _expected file is not a case
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
        expect(("menu_items", "sub"), COVERED)  # a dynamic submenu's entries are in the corpus
        expect(("menu_items", "m_in_sub"), COVERED)  # [0,4,0]: the separator counts
        expect(("menu_items", "m_golden_only"), NOT_YET_BUILT)  # a script-only golden
        expect(("menu_items", "file"), None)  # a top-level menu is not an item
        expect(("panels", "p1"), COVERED)
        expect(("panels", "p2"), NOT_YET_BUILT)
        expect(("panel_pixels", "p1"), NOT_YET_BUILT)
        expect(("dialogs", "d0"), COVERED)
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
        # ── Level-2 certificates (§203 (a), flask's shape in STATUS-flask §225) ──
        def check(cond, why):
            nonlocal arms
            arms += 1
            if not cond:
                failures.append(why)
        # item_spec_sha: canonical JSON, sorted keys, compact, UTF-8 (NOT
        # ascii-escaped), first 16 hex. A non-ASCII node is what tells the
        # last two apart; an ASCII one hashes the same either way.
        uni = {"b": "\u2026", "a": 1}
        want = hashlib.sha256('{"a":1,"b":"\u2026"}'.encode("utf-8")).hexdigest()[:16]
        check(_canonical_sha16(uni) == want, "canonical sha: sorted, compact, UTF-8 un-escaped")
        check(_canonical_sha16(uni) != hashlib.sha256(
            json.dumps(uni, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16],
            "CONTROL: the ascii-escaped form hashes differently, so the arm above can fail")
        # The census's own mapping, one class at a time.
        for cls, iid, node in [
                ("actions", "decoy", spec["actions"]["decoy"]),
                ("tools", "pen", spec["tools"]["pen"]),
                ("state", "fill", spec["state"]["fill"]),
                ("panels", "p2", spec["panels"]["p2"]),
                ("panel_pixels", "p2", spec["panels"]["p2"]),
                ("dialogs", "d1", spec["dialogs"]["d1"]),
                ("dialog_pixels", "d1", spec["dialogs"]["d1"]),
                ("icons", "i1", spec["icons"]["i1"]),
                ("shortcuts", "Ctrl+W -> not_close", spec["shortcuts"][2]),
                ("menu_items", "m_in_sub", spec["menubar"][0]["items"][4]["items"][0])]:
            check(item_spec_sha(spec, cls, iid) == _canonical_sha16(node),
                  f"item_spec_sha({cls}, {iid}) hashes the node the row is about")
        check(item_spec_sha(spec, "tools", "no_such_tool") is None, "an unknown id has no sha")
        check(item_spec_sha(spec, "elements", "e") is None, "an uncensused class has no sha")
        moved = json.loads(json.dumps(spec))
        moved["tools"]["pen"]["handlers"]["a"] = 2
        check(item_spec_sha(moved, "tools", "pen") != item_spec_sha(spec, "tools", "pen"),
              "an edit to the item moves its sha")
        check(item_spec_sha(moved, "tools", "rect") == item_spec_sha(spec, "tools", "rect"),
              "an edit to ANOTHER item leaves this one's sha (per-item, not whole-spec)")

        good = {"schema": L2_SCHEMA, "platform": "windows",
                "row": {"class": "tools", "id": "pen", "observable": "state"},
                "spec_sha": item_spec_sha(spec, "tools", "pen"), "evidence": "tree",
                "arms": {"tree": "PASS", "pixels": "NOT APPLICABLE"},
                "verdict": "CERTIFIED", "build": "0", "date": "2026-10-12"}

        def certs(*named):
            base = os.path.join(d, L2_DIR)
            if os.path.isdir(base):
                shutil.rmtree(base)
            for rel, obj in named:
                put(os.path.join(L2_DIR, rel), obj)
            return read_l2_certs(d, spec, rows)
        got, refused = certs()
        check(got == {} and refused == [], "no certificates: nothing certified, nothing refused")
        got, refused = certs(("tools/pen.state.json", good))
        check(got.get(("windows", ("tools", "pen", "state")), ("",))[0] == L2_CERTIFIED and not refused,
              f"a good certificate reads CERTIFIED: {got} {refused}")
        stale = dict(good, spec_sha="0" * 16)
        got, refused = certs(("tools/pen.state.json", stale))
        check(got.get(("windows", ("tools", "pen", "state")), ("",))[0] == L2_STALE and not refused,
              "a certificate whose spec_sha is not the item's NOW reads STALE")
        for label, bad, why in [
                ("schema", dict(good, schema="jas-l2-cert/0"), "schema"),
                ("row", dict(good, row={"class": "tools", "id": "nope", "observable": "state"}), "row"),
                ("observable", dict(good, row={"class": "tools", "id": "pen", "observable": "tree"}), "row"),
                ("verdict", dict(good, verdict="FAILED"), "verdict"),
                ("arm", dict(good, arms={"tree": "PASS", "pixels": "NOT RUN"}), "arm"),
                ("no arms", dict(good, arms={}), "arm"),
                ("evidence", dict(good, evidence="vibes"), "evidence"),
                ("baseline", dict(good, baseline="prototypes/no/such/dir"), "baseline")]:
            got, refused = certs(("tools/pen.state.json", bad))
            check(got == {} and len(refused) == 1 and why in refused[0][1],
                  f"a certificate with a bad {label} is REFUSED naming it: {refused}")
        put("prototypes/real_baseline/x.png", {"x": 1})
        got, refused = certs(("tools/pen.state.json", dict(good, baseline="prototypes/real_baseline")))
        check(not refused, f"CONTROL: a baseline that exists is accepted: {refused}")
        got, refused = certs(("a.json", good), ("b.json", good))
        check(len(refused) == 1 and "second" in refused[0][1],
              "two certificates for one row and platform: the second is refused")
        os.makedirs(os.path.join(d, L2_DIR), exist_ok=True)
        with open(os.path.join(d, L2_DIR, "broken.json"), "w", encoding="utf-8", newline="") as f:
            f.write("{not json")
        got, refused = read_l2_certs(d, spec, rows)
        check(any("parse" in r for _p, r in refused), "a file that does not parse is refused")
        text = render(spec, rows, {"spec_sha256_16": "0", "build": "0", "platform": "t"},
                      l2=({("windows", ("tools", "pen", "state")): (L2_STALE, "x")}, [("y", "why")]))
        check("LEVEL-2" in text and "STALE 1" in text and "REFUSED 1" in text,
              "the report prints the level-2 block with its counts")
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
    l2 = read_l2_certs(args.root, spec, rows)
    print(render(spec, rows, prov, ev, l2))
    for (plat, key), (st, _rel) in l2[0].items():
        for r in rows:
            if (r["class"], r["id"], r["observable"]) == key:
                r.setdefault("l2", {})[plat] = st
    if args.json:
        with open(args.json, "w", encoding="utf-8", newline="") as f:
            json.dump({"provenance": prov, "summary": summarize(rows), "rows": rows},
                      f, indent=1, sort_keys=True)
            f.write("\n")
    if any(r["status"] == UNCLASSIFIED for r in rows):
        print("yaml_coverage_census: UNCLASSIFIED rows present")
        return 1
    if l2[1]:
        print(f"yaml_coverage_census: {len(l2[1])} level-2 certificate(s) REFUSED")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
