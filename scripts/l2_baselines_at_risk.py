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

WHAT IT DOES NOT DO, SAID HERE SO THE LIST IS NOT READ AS A VERDICT
------------------------------------------------------------------
* It is an OVER-approximation: a YAML edit that does not reach the resolved
  plan (a `description:` say) moves no `plan_sha`, and those baselines are
  listed anyway. Whether a plan moved is measured only on the box.
* It sees panel YAML and the tab bar only. A change elsewhere that reaches a
  plan or the tab (the compiler, a shared action, the engine's plan code, the
  `doc.name` / `doc.is_modified` values the label reads) is not listed.
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


def at_risk(changed: list[str], read_text, baselines: list[tuple[str, str]],
            tab_items: list[str] | None = None, read_base=None,
            why: dict[str, str] | None = None) -> dict[str, list[str]]:
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
        elif items:
            lines.append(f"LEVEL-2 NOTICE: {pid} changed; {len(items)} WinUI baseline(s) may need re-freezing "
                         f"(tell flask in the release): {', '.join(items)}")
        else:
            lines.append(f"LEVEL-2 NOTICE: {pid} changed; no WinUI baseline is frozen on it")
    if lines:
        lines.append("  (an over-approximation: only the box measures whether a plan moved; "
                     "a change outside workspace/panels/ and the canvas tab bar is not seen)")
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
    arms = 25
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
                   read_base=git_reader(base_rev), why=why)
    print("\n".join(report(risk, why)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
