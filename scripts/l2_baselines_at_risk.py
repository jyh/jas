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

WHAT IT DOES NOT DO, SAID HERE SO THE LIST IS NOT READ AS A VERDICT
------------------------------------------------------------------
* It is an OVER-approximation: a YAML edit that does not reach the resolved
  plan (a `description:` say) moves no `plan_sha`, and those baselines are
  listed anyway. Whether a plan moved is measured only on the box.
* It sees panel YAML only. A change elsewhere that reaches a plan (the
  compiler, a shared action, the engine's plan code) is not listed.
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


def at_risk(changed: list[str], read_text, baselines: list[tuple[str, str]]) -> dict[str, list[str]]:
    """`{panel_id: [item, ...]}` for the panel YAMLs in `changed`.

    `read_text(path)` returns a repo file's text, or None when it does not
    exist (a deleted panel: its baselines are listed under the file's path,
    since no id can be read). `baselines` is `[(item, plan_panel), ...]`.
    """
    out: dict[str, list[str]] = {}
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


def _read(path: str) -> str | None:
    p = ROOT / path
    return p.read_text(encoding="utf-8") if p.is_file() else None


def report(risk: dict[str, list[str]]) -> list[str]:
    """The receipt lines. Empty when no panel YAML changed."""
    lines = []
    for pid, items in risk.items():
        if items:
            lines.append(f"LEVEL-2 NOTICE: {pid} changed; {len(items)} WinUI baseline(s) may need re-freezing "
                         f"(tell flask in the release): {', '.join(items)}")
        else:
            lines.append(f"LEVEL-2 NOTICE: {pid} changed; no WinUI baseline is frozen on it")
    if lines:
        lines.append("  (an over-approximation: only the box measures whether a plan moved; "
                     "a change outside workspace/panels/ is not seen)")
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
    check(report(r) and "no WinUI baseline" in report(r)[0], "the no-baseline case prints a line")
    r = at_risk(["workspace/panels/gone.yaml"], yamls.get, base)
    check(r == {"workspace/panels/gone.yaml": []}, f"a deleted panel is listed by path: {r}")
    r = at_risk(["workspace/actions.yaml", "workspace/panels/x.json"], yamls.get, base)
    check(r == {} and report(r) == [], f"non-panel files list nothing: {r}")
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
    arms = 10
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
    lines = report(at_risk(changed, _read, load_baselines()))
    print("\n".join(lines) if lines else f"l2_baselines_at_risk {args.range}: no panel YAML changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
