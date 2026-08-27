#!/usr/bin/env python3
"""No virtualenv may enter the index of a PUBLIC repository.

WHY THIS EXISTS
---------------
`.gitignore` carried the single line `.venv`. That matches ONE directory. On
2026-08-26 `.venv.old` sat beside it -- UNIGNORED, 1.2 GB across 7,215 files --
and `git add -A` would have staged every one into a public repo. The ignore rule
was widened to the class the same hour, and THAT FIX IS REMEMBERING: it holds
until the next sibling is named something the pattern does not cover, or until
someone reaches for `git add -f`.

This gate catches the OUTCOME instead of the local state, which is the only half
CI can see. A developer's untracked debris never exists in CI's checkout --
`check_index_blindspot.py` explains that blindness at length -- so "is there an
unignored venv on somebody's disk?" is structurally unanswerable here. "Is one in
the INDEX?" is answerable, and it is the question that actually costs something:
a virtualenv in public history is not removable without a history purge, and this
fleet has already paid for one.

WHAT IS A VIRTUALENV, MECHANICALLY
----------------------------------
Not "a directory called venv" -- that is the same naming-rule mistake one layer
down. The markers below are what a virtualenv HAS, whatever it is called:
`pyvenv.cfg` at its root, an activate script under `bin/` or `Scripts/`, and a
`site-packages/` component. Any one of them in the index is the finding.
"""
from __future__ import annotations

import re
import subprocess
import sys

# Each marker is a property of the ARTIFACT, never of its name.
MARKERS = [
    (re.compile(r"(^|/)pyvenv\.cfg$"), "a virtualenv's pyvenv.cfg"),
    (re.compile(r"(^|/)(bin|Scripts)/activate(\.[A-Za-z0-9]+)?$"), "a virtualenv activate script"),
    (re.compile(r"(^|/)site-packages/"), "an installed-package tree (site-packages)"),
    (re.compile(r"(^|/)(bin|Scripts)/pip[0-9.]*$"), "a virtualenv's bundled pip"),
]


def tracked() -> list[str]:
    out = subprocess.run(["git", "ls-files"], capture_output=True, text=True,
                         encoding="utf-8", check=True)
    return [l for l in out.stdout.splitlines() if l]


def scan(paths: list[str]) -> list[tuple[str, str]]:
    hits = []
    for p in paths:
        for rx, what in MARKERS:
            if rx.search(p):
                hits.append((p, what))
                break
    return hits


def self_test() -> int:
    failures = []
    # Planted shapes -- every one must be caught, and none is matched by NAME.
    planted = [
        ("weirdname/pyvenv.cfg", "root marker"),
        (".venv.old/bin/activate", "posix activate"),
        ("tools/env/Scripts/activate.bat", "windows activate"),
        ("x/lib/python3.12/site-packages/foo/__init__.py", "installed tree"),
        ("build/bin/pip3.12", "bundled pip"),
    ]
    for path, label in planted:
        if not scan([path]):
            failures.append(f"planted {label} ({path}) must be CAUGHT")
    # Compliant shapes -- ordinary repo files that must NOT trip it.
    clean = [
        "scripts/activate_tool.py",          # 'activate' but not under bin/
        "docs/site-packages.md",             # the word, not the path component
        "jas_dioxus/src/bin/algorithm_roundtrip.rs",   # a real bin/ that is not a venv
        "workspace/pyvenv.cfg.md",           # near-miss on the root marker
        "spec/bin/pipeline.py",              # starts with 'pip', is not pip
    ]
    for path in clean:
        got = scan([path])
        if got:
            failures.append(f"compliant {path} must PASS, flagged as {got[0][1]}")
    # ⛔ ANTI-VACUITY: a gate that examines nothing returns [] and looks clean.
    if len(tracked()) < 100:
        failures.append(f"only {len(tracked())} tracked files -- refusing to "
                        f"call an empty index a clean one")
    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print(f"check_no_vendored_env SELF-TEST: OK ({len(planted)} planted shapes "
          f"caught, {len(clean)} compliant paths passed, {len(tracked())} tracked "
          f"files present so the scan is not vacuous)")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    paths = tracked()
    if len(paths) < 100:
        print(f"FAIL: `git ls-files` returned {len(paths)} paths. An empty or "
              f"truncated index is not a clean one.")
        return 1
    hits = scan(paths)
    if hits:
        print(f"FAIL: {len(hits)} virtualenv artefact(s) are TRACKED in a public repo.\n")
        for p, what in hits[:20]:
            print(f"  {p}\n      {what}")
        print("\nA virtualenv in public history cannot be removed without a history")
        print("purge. Remove it from the index and widen .gitignore to the CLASS,")
        print("not to the one name you just hit.")
        return 1
    print(f"check_no_vendored_env: OK ({len(paths)} tracked paths, no virtualenv "
          f"artefacts). Markers are properties of the artefact (pyvenv.cfg, "
          f"bin|Scripts/activate, site-packages/, bundled pip), never a directory name.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
