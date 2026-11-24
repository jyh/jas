#!/usr/bin/env python3
"""Name the WinUI level-2 baselines a panel-YAML change may un-certify.

WHY THIS EXISTS
---------------
A level-2 baseline (`prototypes/sb_winui/e2e_baselines/<item>/baseline.json`)
pins the PLAN of the panel its script opens (`plan_panel`, `plan_sha`): the
panel as the core resolved it on the Windows box. Edit that panel's YAML and
the plan can move, so every baseline frozen on that panel fails its TREE arm on
the next re-certify, while the read-back, the core and the pixels still pass.
CI does not run level 2, so nothing on this side says so. Found on #564: its
`gradient.yaml` change (the stop combos' behaviors) silently un-certified five
Gradient baselines, and only flask's re-certify on the box saw it (STATUS-flask
§ 449, flask's proposal).

WHAT IT DOES
------------
Given the files a change touches, it maps each `workspace/panels/<p>.yaml` to
the panel id that file declares (its top-level `id:`), and lists every
baseline whose `plan_panel` is that id. `merge_preflight.py` prints the list in
its receipt, so the merger tells flask in the same post that lands the change.

THE TAB ARM (STATUS-flask section 920): almost every baseline also pins the
canvas tab's label (`tab`, `tab_sha`), and that label is `workspace/layout.yaml`'s
`canvas_tab_bar`, not a panel. Row 115 (#916) changed it and un-certified every
document-editing baseline while this tool, seeing no panel YAML, printed "no
panel YAML changed". So when `layout.yaml` is in the change, the tool compares
the ONE `canvas_tab_bar` node at the change's base and head, its `summary` and
`description` set aside (prose, never read into the label), and lists every
baseline carrying a `tab` when the node moved. A node it cannot compare (no
base side, unparseable, absent at head, or present more than once) is listed
and the receipt says why: a comparison that could not be made never reads as
"unchanged".

THE UNDO-STEP ARM (the O97 nightly of 2026-11-23): the tab's " *" is the
document's modified mark, so a gesture that stops or starts recording an undo
step moves `tab` with no panel YAML and no `layout.yaml` in the change. Row 243
(#1083) did exactly that to two baselines, one of them through a native effect
rather than its tool YAML, so this arm reads the gesture corpus's pins: when a
change moves any existing case's `expected_can_undo` in
`test_fixtures/gestures/*.json`, it lists every baseline whose input script
drives that case's tool. A file it cannot compare lists every baseline.

WHAT IT DOES NOT DO, SAID HERE SO THE LIST IS NOT READ AS A VERDICT
------------------------------------------------------------------
* It is an OVER-approximation: a YAML edit that does not reach the resolved
  plan (a `description:` say) moves no `plan_sha`, and those baselines are
  listed anyway. Whether a plan moved is measured only on the box.
* It sees panel YAML, the tab bar and the gesture corpus's undo pins only. A
  change elsewhere that reaches a plan or the tab (the compiler, a shared
  action, the engine's plan code, the `doc.name` value the label reads, or a
  `doc.is_modified` change that no gesture pin records, such as a panel
  action's undo step) is not listed.
* It never refuses. It is advice for the merger, not a gate: level 2 is the
  box's, and a re-freeze is flask's act.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PANELS = "workspace/panels/"
BASELINES = ROOT / "prototypes" / "sb_winui" / "e2e_baselines"
_ID = re.compile(r"^id:\s*(\S+)\s*$", re.M)


def panel_id(yaml_text: str) -> str | None:
    """The panel id a panel YAML declares at top level, or None."""
    m = _ID.search(yaml_text)
    return m.group(1) if m else None


LAYOUT = "workspace/layout.yaml"
TAB_BAR = "canvas_tab_bar"
TAB_KEY = f"{TAB_BAR} ({LAYOUT})"
# Prose keys: a reader's words, never read into a label, so a change to them
# cannot move a baseline's `tab`. Everything else in the node counts.
_PROSE = ("summary", "description")


def tab_bar_node(text: str | None):
    """`(node, None)` for the ONE `canvas_tab_bar` node in a layout's text,
    with its prose keys removed; `(None, why)` when it cannot be read, is
    absent, or occurs more than once."""
    if text is None:
        return None, "no file"
    try:
        import yaml  # the CI job pip-installs it; a missing module is a reason, never a skip
        doc = yaml.safe_load(text)
    except Exception as e:
        return None, f"{type(e).__name__}: {e}".splitlines()[0]
    found = []

    def walk(v):
        if isinstance(v, dict):
            if v.get("id") == TAB_BAR:
                found.append(v)
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
    walk(doc)
    if len(found) != 1:
        return None, f"{len(found)} {TAB_BAR} node(s)"
    return {k: v for k, v in found[0].items() if k not in _PROSE}, None


def tab_bar_moved(read_text, read_base) -> tuple[bool, str | None]:
    """Whether the tab bar moved between base and head: `(moved, why)`, where
    `why` names the reason a comparison could not be made (then `moved` is
    True: listed conservatively, never skipped)."""
    if read_base is None:
        return True, "UNREADABLE: no base-side reader"
    new, why_new = tab_bar_node(read_text(LAYOUT))
    old, why_old = tab_bar_node(read_base(LAYOUT))
    if new is None:
        return True, f"UNREADABLE at head: {why_new}"
    if old is None:
        return True, None if why_old == "0 canvas_tab_bar node(s)" or why_old == "no file" \
            else f"UNREADABLE at base: {why_old}"
    return new != old, None


GESTURES = "test_fixtures/gestures/"
UNDO_KEY = f"expected_can_undo ({GESTURES})"
_ABSENT = "ABSENT"


def gesture_pins(text: str | None) -> tuple[dict[str, tuple[str, object]] | None, str | None]:
    """`({name: (tool, expected_can_undo)}, None)` for one gesture file's text
    (a pin not given reads `ABSENT`, a value of its own); `(None, why)` when
    the file cannot be read as a list of cases."""
    if text is None:
        return {}, None
    try:
        cases = json.loads(text)
    except Exception as e:
        return None, f"{type(e).__name__}: {e}".splitlines()[0]
    cases = cases if isinstance(cases, list) else [cases]
    if not all(isinstance(c, dict) for c in cases):
        return None, "a case that is not an object"
    return {c.get("name", ""): (c.get("tool", ""), c.get("expected_can_undo", _ABSENT)) for c in cases}, None


def gesture_files(changed: list[str]) -> list[str]:
    """The gesture CORPUS files in a change: its `_expected.json` goldens are
    outputs, never pins. The one predicate both callers use."""
    return [p for p in sorted(set(changed))
            if p.startswith(GESTURES) and p.endswith(".json") and not p.endswith("_expected.json")]


def undo_moved_tools(changed: list[str], read_text, read_base) -> tuple[set[str] | None, str | None]:
    """The tools whose gesture cases' `expected_can_undo` moved between base
    and head: `(tools, None)`, or `(None, why)` when a file could not be
    compared (then every tool baseline is listed). A case only ADDED or only
    REMOVED moves no existing behaviour and is not counted; a pin removed from
    a case that stays is a move."""
    files = gesture_files(changed)
    if read_base is None:
        return None, "UNREADABLE: no base-side reader"
    tools: set[str] = set()
    for p in files:
        new, why_new = gesture_pins(read_text(p))
        old, why_old = gesture_pins(read_base(p))
        if new is None or old is None:
            return None, f"UNREADABLE: {p}: {why_new or why_old}"
        for name in new.keys() & old.keys():
            if new[name][1] != old[name][1]:
                tools.update(t for t in (new[name][0], old[name][0]) if t)
    return tools, None


def at_risk(changed: list[str], read_text, baselines: list[tuple[str, str]],
            tab_items: list[str] | None = None, read_base=None,
            why: dict[str, str] | None = None,
            tool_items: dict[str, str] | None = None) -> dict[str, list[str]]:
    """`{panel_id: [item, ...]}` for the panel YAMLs in `changed`, plus
    `{TAB_KEY: [...]}` when `workspace/layout.yaml` is in `changed` and
    `tab_items` (the baselines carrying a `tab`) is given.

    `read_text(path)` returns a repo file's text, or None when it does not
    exist (a deleted panel: its baselines are listed under the file's path,
    since no id can be read). `baselines` is `[(item, plan_panel), ...]`.
    `read_base(path)` reads the BASE side of the change, for the tab bar's
    before/after; without it the tab items are listed conservatively.
    `why`, when given, receives the reason a comparison could not be made.
    """
    out: dict[str, list[str]] = {}
    if tab_items is not None and LAYOUT in changed:
        moved, reason = tab_bar_moved(read_text, read_base)
        out[TAB_KEY] = sorted(tab_items) if moved else []
        if reason and why is not None:
            why[TAB_KEY] = reason
    if tool_items is not None and gesture_files(changed):
        tools, reason = undo_moved_tools(changed, read_text, read_base)
        out[UNDO_KEY] = sorted(tool_items) if tools is None else \
            sorted(i for i, t in tool_items.items() if t in tools)
        if reason and why is not None:
            why[UNDO_KEY] = reason
    for path in sorted(set(changed)):
        if not (path.startswith(PANELS) and path.endswith(".yaml")):
            continue
        text = read_text(path)
        pid = panel_id(text) if text is not None else None
        key = pid or path
        items = sorted(i for i, p in baselines if p == pid) if pid else []
        out[key] = items
    return out


def load_baselines(root: Path = BASELINES) -> list[tuple[str, str]]:
    rows = []
    for f in sorted(root.glob("*/baseline.json")):
        d = json.loads(f.read_text(encoding="utf-8"))
        rows.append((d.get("item", f.parent.name), d.get("plan_panel", "")))
    return rows


def load_tab_items(root: Path = BASELINES) -> list[str]:
    """The baselines that pin the canvas tab (a `tab` key)."""
    rows = []
    for f in sorted(root.glob("*/baseline.json")):
        d = json.loads(f.read_text(encoding="utf-8"))
        if "tab" in d:
            rows.append(d.get("item", f.parent.name))
    return rows


SCRIPTS = ROOT / "test_fixtures" / "input_scripts"


def load_tool_items(root: Path = BASELINES, scripts: Path = SCRIPTS) -> dict[str, str]:
    """`{item: tool}` for every baseline whose item an input script names
    (the script's `tool`); the self-test holds the live map to every baseline."""
    tools = {}
    for f in sorted(scripts.glob("*.json")):
        if f.name.endswith(".expected.json"):
            continue
        d = json.loads(f.read_text(encoding="utf-8"))
        if isinstance(d, dict) and d.get("item") and d.get("tool"):
            tools[d["item"]] = d["tool"]
    return {i: tools[i] for i, _ in load_baselines(root) if i in tools}


def live_gesture_pins() -> dict[str, tuple[str, object]]:
    """Every live gesture case's `(tool, expected_can_undo)`, by case name."""
    out: dict[str, tuple[str, object]] = {}
    for f in sorted((ROOT / GESTURES).glob("*.json")):
        if f.name.endswith("_expected.json"):
            continue
        pins, _ = gesture_pins(f.read_text(encoding="utf-8"))
        out.update(pins or {})
    return out


def _read(path: str) -> str | None:
    p = ROOT / path
    return p.read_text(encoding="utf-8") if p.is_file() else None


def git_reader(rev: str):
    """A reader for `path` at `rev` (None when the file is absent there)."""
    def read(path: str) -> str | None:
        r = subprocess.run(["git", "show", f"{rev}:{path}"], cwd=ROOT, capture_output=True,
                           text=True, encoding="utf-8")
        return r.stdout if r.returncode == 0 else None
    return read


def range_ends(rng: str) -> tuple[str, str]:
    """`(base, head)` of `A..B` or `A...B` (the merge base for the latter)."""
    if "..." in rng:
        a, b = rng.split("...", 1)
        a = subprocess.run(["git", "merge-base", a, b or "HEAD"], cwd=ROOT, check=True,
                           capture_output=True, text=True, encoding="utf-8").stdout.strip()
    else:
        a, b = rng.split("..", 1)
    return a, b or "HEAD"


def report(risk: dict[str, list[str]], why: dict[str, str] | None = None) -> list[str]:
    """The receipt lines; one line saying so when no panel YAML changed, so
    the notice's silence never stands for "it did not run"."""
    if not risk:
        return ["LEVEL-2 NOTICE: no panel YAML changed"]
    lines = []
    for pid, items in risk.items():
        if pid == TAB_KEY:
            reason = (why or {}).get(TAB_KEY)
            if items:
                lines.append(f"LEVEL-2 NOTICE: {TAB_KEY} "
                             f"{'could not be compared (' + reason + '), so listed' if reason else 'changed'}; "
                             f"{len(items)} WinUI baseline(s) pin the tab and may need re-freezing "
                             f"(tell flask in the release): {', '.join(items)}")
            else:
                lines.append(f"LEVEL-2 NOTICE: {LAYOUT} changed; {TAB_BAR} unchanged (its prose aside), "
                             f"so no baseline's tab arm is at risk")
        elif pid == UNDO_KEY:
            reason = (why or {}).get(UNDO_KEY)
            if items:
                lines.append(f"LEVEL-2 NOTICE: {UNDO_KEY} "
                             f"{'could not be compared (' + reason + '), so listed' if reason else 'moved'}; "
                             f"the tab's modified mark may move for {len(items)} WinUI baseline(s) "
                             f"(tell flask in the release): {', '.join(items)}")
            else:
                lines.append(f"LEVEL-2 NOTICE: a gesture file changed; no gesture's expected_can_undo moved "
                             f"for a tool a baseline drives")
        elif items:
            lines.append(f"LEVEL-2 NOTICE: {pid} changed; {len(items)} WinUI baseline(s) may need re-freezing "
                         f"(tell flask in the release): {', '.join(items)}")
        else:
            lines.append(f"LEVEL-2 NOTICE: {pid} changed; no WinUI baseline is frozen on it")
    if lines:
        lines.append("  (an over-approximation: only the box measures whether a plan moved; "
                     "a change outside workspace/panels/, the canvas tab bar and the gesture undo pins is not seen)")
    return lines


def self_test() -> int:
    failures = []

    def check(cond, label):
        if not cond:
            failures.append(label)

    yamls = {
        "workspace/panels/gradient.yaml": "id: gradient_panel_content\ntype: panel\n",
        "workspace/panels/stroke.yaml": "id: stroke_panel_content\n",
        "workspace/panels/nobase.yaml": "id: nobase_panel_content\n",
    }
    base = [("gradient.linear", "gradient_panel_content"), ("gradient.angle", "gradient_panel_content"),
            ("stroke.weight", "stroke_panel_content"), ("color.hex", "color_panel_content")]
    r = at_risk(["workspace/panels/gradient.yaml", "README.md"], yamls.get, base)
    check(r == {"gradient_panel_content": ["gradient.angle", "gradient.linear"]},
          f"one panel changed lists exactly its baselines: {r}")
    r = at_risk(["workspace/panels/nobase.yaml"], yamls.get, base)
    check(r == {"nobase_panel_content": []}, f"a panel with no baseline is NAMED, not dropped: {r}")
    check("no WinUI baseline" in report(r)[0], "the no-baseline case prints a line")
    r = at_risk(["workspace/panels/gone.yaml"], yamls.get, base)
    check(r == {"workspace/panels/gone.yaml": []}, f"a deleted panel is listed by path: {r}")
    r = at_risk(["workspace/actions.yaml", "workspace/panels/x.json"], yamls.get, base)
    check(r == {}, f"non-panel files list nothing: {r}")
    # ...but the RECEIPT still says so: silence would read exactly like the
    # notice never running (a crashed import, a skipped call).
    check(report(r) == ["LEVEL-2 NOTICE: no panel YAML changed"], f"the empty case prints one line: {report(r)}")
    # The id must come from the file, never from its name: a mutant that
    # derived `<stem>_panel_content` agrees on every shipped file, so the arm
    # uses a file whose name and id differ.
    odd = {"workspace/panels/odd.yaml": "id: stroke_panel_content\n"}
    r = at_risk(["workspace/panels/odd.yaml"], odd.get, base)
    check(r == {"stroke_panel_content": ["stroke.weight"]}, f"the id is read from the file: {r}")
    # The live tree: every shipped panel YAML declares an id, and the live
    # baselines are a real population (a walk that found nothing would list
    # nothing for every change, which reads exactly like "no risk").
    live = load_baselines()
    check(len(live) >= 50, f"live baselines found: {len(live)}")
    panels = sorted((ROOT / "workspace" / "panels").glob("*.yaml"))
    check(len(panels) >= 10, f"live panel YAMLs found: {len(panels)}")
    missing = [p.name for p in panels if panel_id(p.read_text(encoding="utf-8")) is None]
    check(not missing, f"every panel YAML declares an id: missing {missing}")
    known = {panel_id(p.read_text(encoding="utf-8")) for p in panels}
    orphan = sorted({pp for _, pp in live if pp and pp not in known})
    check(not orphan, f"every baseline's plan_panel names a live panel id: {orphan}")

    # THE TAB ARM (STATUS-flask section 920, row 115): a baseline's `tab` /
    # `tab_sha` pin the canvas tab bar's label, which `workspace/layout.yaml`'s
    # `canvas_tab_bar` defines, so a change there un-certifies every baseline
    # that carries a tab while no panel YAML moved. Each arm below differs from
    # its neighbour in ONE place, so a mutant that collapses two cases reds.
    tabs = ["a.tab", "b.tab"]
    def lay(label, desc="Tabs.", other="x"):
        return ("root:\n  - id: other_node\n    label: " + other + "\n"
                "  - id: canvas_tab_bar\n    type: container\n    description: " + desc + "\n"
                "    label: " + label + "\n")
    old = {"workspace/layout.yaml": lay("'{{doc.name}}'")}
    w: dict[str, str] = {}
    def tab_risk(new_text, old_text=old["workspace/layout.yaml"], changed=("workspace/layout.yaml",)):
        w.clear()
        return at_risk(list(changed), {"workspace/layout.yaml": new_text}.get, base,
                       tab_items=tabs, read_base={"workspace/layout.yaml": old_text}.get, why=w)
    r = tab_risk(lay("'{{doc.name}} *'"))
    check(r == {TAB_KEY: ["a.tab", "b.tab"]}, f"a tab-bar label change lists every tab baseline: {r}")
    check(any("2 WinUI baseline(s)" in x for x in report(r)), f"and the receipt counts them: {report(r)}")
    r = tab_risk(lay("'{{doc.name}}'", desc="Other words."))
    check(r == {TAB_KEY: []}, f"a description-only change to the tab bar lists nothing: {r}")
    check(any("canvas_tab_bar unchanged" in x for x in report(r)), f"...and SAYS it read the tab bar: {report(r)}")
    r = tab_risk(lay("'{{doc.name}}'", other="y"))
    check(r == {TAB_KEY: []}, f"a change elsewhere in layout.yaml lists nothing: {r}")
    r = tab_risk(lay("'{{doc.name}}'"), old_text="root:\n  - id: other_node\n")
    check(r == {TAB_KEY: ["a.tab", "b.tab"]}, f"a tab bar absent on the base side is a change: {r}")
    r = tab_risk("root: [unclosed\n")
    check(r == {TAB_KEY: ["a.tab", "b.tab"]}, f"an unparseable layout lists conservatively: {r}")
    check(any("UNREADABLE at head" in x for x in report(r, w)), f"...and says why: {report(r, w)}")
    r = tab_risk(lay("'{{doc.name}}'") + "  - id: canvas_tab_bar\n")
    check(r == {TAB_KEY: ["a.tab", "b.tab"]}, f"two canvas_tab_bar nodes list conservatively: {r}")
    r = at_risk(["workspace/layout.yaml"], {"workspace/layout.yaml": lay("'{{doc.name}}'")}.get, base,
                tab_items=tabs)
    check(r == {TAB_KEY: ["a.tab", "b.tab"]}, f"no base-side reader lists conservatively, never skips: {r}")
    r = tab_risk(lay("'{{doc.name}} *'"), changed=("README.md",))
    check(r == {}, f"layout.yaml NOT in the change reads nothing: {r}")
    # The live tree: exactly one canvas_tab_bar, and the tab population read by
    # the loader agrees with a raw-text count (a second axis), and is real.
    live_layout = (ROOT / "workspace" / "layout.yaml").read_text(encoding="utf-8")
    node, why = tab_bar_node(live_layout)
    check(node is not None, f"the live layout.yaml has exactly one canvas_tab_bar: {why}")
    live_tabs = load_tab_items()
    raw = sum(1 for f in BASELINES.glob("*/baseline.json") if '"tab"' in f.read_text(encoding="utf-8"))
    check(len(live_tabs) == raw and raw > 0, f"tab baselines: loader {len(live_tabs)} vs raw text {raw}")
    # Every LIVE baseline carries a tab (116 of 116 on 11-18), so the live arm
    # above cannot see a loader that takes every baseline: a synthetic
    # population with one tab-less baseline can.
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        for item, d in (("with.tab", {"item": "with.tab", "tab": "t"}), ("no.tab", {"item": "no.tab"})):
            (Path(td) / item).mkdir()
            (Path(td) / item / "baseline.json").write_text(json.dumps(d), encoding="utf-8", newline="")
        got = load_tab_items(Path(td))
    check(got == ["with.tab"], f"the loader takes only baselines that carry a tab: {got}")

    # THE UNDO-STEP ARM (O97 nightly 11-23, row 243): the tab's " *" is the
    # document's modified mark, so a gesture that stops (or starts) recording
    # an undo step moves `tab` with no panel YAML and no layout.yaml in the
    # change. Row 243 did exactly that to magic_wand.click and
    # partial_selection.marquee; one of the two moved through a NATIVE effect,
    # so the arm reads the gesture corpus's pin, never the tool YAML. Each arm
    # differs from its neighbour in ONE place.
    tool_items = {"wand.click": "magic_wand", "sel.click": "selection", "rect.drag": "rect"}
    G = "test_fixtures/gestures/g.json"
    def gest(*cases):
        return json.dumps([{"name": n, "tool": t, "expected_can_undo": u} for n, t, u in cases])
    g_old = gest(("wand", "magic_wand", True), ("sel", "selection", True))
    def undo_risk(new_text, old_text=g_old, changed=(G,)):
        w.clear()
        return at_risk(list(changed), {G: new_text}.get, base, read_base={G: old_text}.get,
                       tool_items=tool_items, why=w)
    r = undo_risk(gest(("wand", "magic_wand", False), ("sel", "selection", True)))
    check(r == {UNDO_KEY: ["wand.click"]}, f"a flipped can_undo pin lists that tool's baselines only: {r}")
    check(any("1 WinUI baseline(s)" in x and "wand.click" in x for x in report(r, w)),
          f"...and the receipt names them: {report(r, w)}")
    r = undo_risk(gest(("wand", "magic_wand", True), ("sel", "selection", False)))
    check(r == {UNDO_KEY: ["sel.click"]}, f"the OTHER case flipped lists the other tool: {r}")
    r = undo_risk(g_old)
    check(r == {UNDO_KEY: []}, f"a gesture file changed with no pin moved lists nothing: {r}")
    check(any("no gesture's expected_can_undo moved" in x for x in report(r, w)),
          f"...and SAYS it read the pins: {report(r, w)}")
    r = undo_risk(json.dumps([{"name": "wand", "tool": "magic_wand"},
                              {"name": "sel", "tool": "selection", "expected_can_undo": True}]))
    check(r == {UNDO_KEY: ["wand.click"]}, f"a pin REMOVED is a move, listed: {r}")
    r = undo_risk(gest(("wand", "magic_wand", True), ("sel", "selection", True), ("r", "rect", True)))
    check(r == {UNDO_KEY: []}, f"a case ADDED moves no existing behaviour: {r}")
    r = undo_risk("[unclosed")
    check(r == {UNDO_KEY: ["rect.drag", "sel.click", "wand.click"]}, f"an unparseable corpus lists every tool baseline: {r}")
    check(any("UNREADABLE" in x for x in report(r, w)), f"...and says why: {report(r, w)}")
    r = undo_risk(gest(("wand", "magic_wand", False)), changed=("README.md",))
    check(r == {}, f"no gesture file in the change reads nothing: {r}")
    r = undo_risk(gest(("wand", "magic_wand", False)), changed=("test_fixtures/gestures/g_expected.json",))
    check(r == {}, f"an _expected.json is a golden, not the corpus: {r}")
    r = at_risk([G], {G: gest(("wand", "magic_wand", False))}.get, base, tool_items=tool_items)
    check(r == {UNDO_KEY: ["rect.drag", "sel.click", "wand.click"]}, f"no base-side reader lists conservatively: {r}")
    # The live tree: the baseline -> tool map comes from the input scripts,
    # and every baseline must map (an unmapped one would never be listed).
    live_tools = load_tool_items()
    check(len(live_tools) == len(live) and len(live) > 0,
          f"every live baseline maps to a tool: {len(live_tools)} of {len(live)}")
    check({"magic_wand.click", "partial_selection.marquee"} <= set(live_tools),
          f"the two items row 243 moved are in the map: {sorted(live_tools)[:3]}...")
    gl = live_gesture_pins()
    check(len(gl) >= 50 and all(t for t, _ in gl.values()),
          f"the live gesture corpus pins a tool per case: {len(gl)} case(s)")
    arms = 39
    for f in failures:
        print(f"  FAIL: {f}")
    print(f"l2_baselines_at_risk --self-test: {arms} arm(s), {len(failures)} failure(s), "
          f"{len(live)} live baselines over {len(panels)} panel YAMLs")
    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--range", help="a git range, e.g. origin/main..HEAD")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if not args.range:
        ap.error("--range is required (or --self-test)")
    changed = subprocess.run(["git", "diff", "--name-only", args.range], cwd=ROOT, check=True,
                             capture_output=True, text=True, encoding="utf-8").stdout.split()
    base_rev, head_rev = range_ends(args.range)
    why: dict[str, str] = {}
    risk = at_risk(changed, git_reader(head_rev), load_baselines(), tab_items=load_tab_items(),
                   read_base=git_reader(base_rev), why=why, tool_items=load_tool_items())
    print("\n".join(report(risk, why)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
