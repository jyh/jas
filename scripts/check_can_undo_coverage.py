#!/usr/bin/env python3
"""Every action, dialog-action and gesture case pins `expected_can_undo`.

WHY THIS EXISTS
---------------
A document golden cannot see the undo stack, so an action that changes nothing
but records an undo step, or a selection that lands in history, passes every
other check. Rows 227-243 (2026-11-23) pinned `expected_can_undo` on every case
of the three corpora that write the document, each value derived from the
document trace and never from `can_undo`, and that sweep found a real defect
(four selection tools recording an undo step). Nothing kept the NEXT case from
omitting the key, and an omitted key reads as green. This gate refuses it.

WHAT IT DOES
------------
* Reads every case of `test_fixtures/actions/`, `test_fixtures/dialog_actions/`
  and `test_fixtures/gestures/` (a case is a JSON object with a `name`).
* Refuses a case without `expected_can_undo`, unless EXEMPT names it with its
  reason.
* Refuses an EXEMPT entry that no longer exists, or whose case now carries the
  key: a stale exemption is an exemption nobody re-read.
* Requires a non-bool value to be refused too: `1` is not a pin.

WHAT IT DOES NOT DO
-------------------
* It does not check that a pinned VALUE is right; the runners do that, in both
  ports. It checks only that a value is there.
* It does not cover corpora that write no document (widget_events: row 244).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORPORA = ("actions", "dialog_actions", "gestures")
KEY = "expected_can_undo"

# A case left unpinned on purpose, with the reason. Keep it short and re-read it.
EXEMPT = {
    "delete_symbol_action_on_a_used_master_asks_first":
        "dialog_actions: its setup changes the document before the dialog opens, so "
        "can_undo there reads the setup, not the case (row 240)",
}


def cases(root: Path) -> list[tuple[str, dict]]:
    """Every case of the three corpora as (`<corpus>/<file>`, case). A case file
    is a top-level JSON LIST of objects with a `name`; the goldens beside them
    are documents (objects) and are skipped."""
    out: list[tuple[str, dict]] = []
    for corpus in CORPORA:
        for f in sorted((root / corpus).glob("*.json")):
            try:
                data = json.loads(f.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if isinstance(data, list):
                rel = f"{corpus}/{f.name}"
                out.extend((rel, c) for c in data if isinstance(c, dict) and "name" in c)
    return out


def findings(found: list[tuple[str, dict]], exempt: dict[str, str]) -> list[str]:
    """What is wrong: an unpinned case, a non-bool pin, a stale exemption."""
    out: list[str] = []
    names = {}
    for rel, c in found:
        names[c["name"]] = c
        if c["name"] in exempt:
            continue
        if KEY not in c:
            out.append(f"{rel}: case {c['name']!r} does not pin {KEY}")
        elif not isinstance(c[KEY], bool):
            out.append(f"{rel}: case {c['name']!r} pins {KEY} = {c[KEY]!r}, which is not a bool")
    for name in sorted(exempt):
        if name not in names:
            out.append(f"EXEMPT names {name!r}: no such case (a stale exemption)")
        elif KEY in names[name]:
            out.append(f"EXEMPT names {name!r}: the case now pins {KEY}, so the exemption is stale")
    return out


def self_test() -> int:
    failures: list[str] = []
    ran: list[str] = []

    def check(cond, label):
        ran.append(label)
        if not cond:
            failures.append(label)

    good = [("a.json", {"name": "x", KEY: True}), ("a.json", {"name": "y", KEY: False})]
    check(findings(good, {}) == [], "every case pinned: no finding")
    f = findings(good + [("b.json", {"name": "z"})], {})
    check(len(f) == 1 and "z" in f[0] and "b.json" in f[0], f"an unpinned case is named with its file: {f}")
    f = findings(good + [("b.json", {"name": "z", KEY: 1})], {})
    check(len(f) == 1 and "z" in f[0] and "not a bool" in f[0], f"a number is not a pin: {f}")
    check(findings(good + [("b.json", {"name": "z"})], {"z": "why"}) == [], "an exempt case passes")
    f = findings(good, {"gone": "why"})
    check(len(f) == 1 and "gone" in f[0] and "no such case" in f[0], f"an exemption naming no case is stale: {f}")
    f = findings(good, {"x": "why"})
    check(len(f) == 1 and "x" in f[0] and "now pins" in f[0], f"an exemption whose case is pinned is stale: {f}")
    live = cases(ROOT / "test_fixtures")
    per = {c: sum(1 for p, _ in live if p.startswith(c + "/")) for c in CORPORA}
    check(all(per[c] > 0 for c in CORPORA), f"control: every corpus yields cases: {per}")
    check(len(live) >= 400, f"live cases found: {len(live)} (a floor, never a target)")
    check(findings(live, EXEMPT) == [], f"the live corpora pass: {findings(live, EXEMPT)[:3]}")
    arms = len(ran)
    for x in failures:
        print(f"  FAIL: {x}")
    print(f"check_can_undo_coverage --self-test: {arms} arm(s), {len(failures)} failure(s), {len(live)} live cases {per}")
    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true")
    if ap.parse_args().self_test:
        return self_test()
    live = cases(ROOT / "test_fixtures")
    if not live:
        print("check_can_undo_coverage: REFUSED: read no cases", file=sys.stderr)
        return 2
    bad = findings(live, EXEMPT)
    for b in bad:
        print(f"  {b}")
    per = {c: sum(1 for p, _ in live if p.startswith(c + "/")) for c in CORPORA}
    if bad:
        print(f"check_can_undo_coverage: FAIL -- {len(bad)} finding(s) over {len(live)} cases {per}")
        return 1
    print(f"check_can_undo_coverage: OK -- {len(live)} cases {per} pin {KEY}, {len(EXEMPT)} exempt with a reason. "
          "NOT COVERED: whether a pinned value is right (the runners check that).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
