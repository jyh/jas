#!/usr/bin/env python3
"""Verify-then-commit is blind to exactly the files the commit adds.

WHY THIS EXISTS
---------------
Eight of this repository's gates derive their subject list from `git ls-files`
-- deliberately, and for a good reason each time: the index is an independent
oracle from a filesystem walk, it is separator-clean on every platform, and its
absence can be made an ERROR rather than an empty list. `check_geometry_checkers`
says so in as many words.

But `git ls-files` lists the INDEX. A file that exists on disk and has not been
staged is not in it. So a gate reading the index **cannot see a file that is
about to be committed**, and the standing protocol is:

    verify everything  ->  then commit

which runs every index-reading gate at the one moment the new files are still
invisible to it.

MEASURED, on 2026-08-04, by planting a `spec/` module importing `numpy`:

    untracked on disk  ->  check_geometry_checkers exit 0   (BLIND)
    the same file, staged  ->  exit 1                       (sees it)

This is not hypothetical and it has already cost something. `9806398a`
(SPECUNTESTED) added `spec/geometry/tests/test_region.py`, which imports
`pytest`, violating the analytic tier's stdlib-only rule. The pre-commit sweep
reported every gate green, because the file was untracked when the sweep ran.
The commit message says "24 gates BOTH arms". It was false the moment it was
written, and the gate has been red on main ever since.

THE GATES ARE NOT WRONG. They answer "is the tracked tree clean?" correctly. The
PROTOCOL asked them "is my working tree clean?", which is a different and larger
question -- an instrument answering a narrower question than the one asked, the
class this repository has spent a fortnight cataloguing. CI is unaffected: it
checks out a committed tree, where the two questions coincide. The blindness
exists only in the local sweep, which is precisely where it is trusted most.

WHAT THIS DOES
--------------
Reds while any untracked, non-ignored file exists, and names the gates that
cannot see it. Staging is the whole fix: `git ls-files` lists staged files, so
`git add` makes the file visible to all eight without committing anything.

THE LIST OF AFFECTED GATES IS DERIVED, NOT TYPED. A hand-maintained list is what
`check_lane_coverage.py` exists to kill -- a gate added after the list was
written would be missing from it, silently and forever. This scans `scripts/`
for the call itself.

WHAT IT DELIBERATELY DOES NOT DO
--------------------------------
* It does not stage anything. A gate that mutates the index to make itself pass
  would be deciding what belongs in a commit, which is not a gate's job.
* It says nothing about MODIFIED tracked files. Those are already in the index
  under their old content, and every gate reads the working tree for content --
  only the SUBJECT LIST comes from the index. Untracked is the whole gap.
* It cannot see a file inside `.gitignore`. That is correct: an ignored file is
  not going into the commit either.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

# Any gate whose subject list comes from the index shares the blind spot. Found
# by looking for the call, not by listing the gates.
LS_FILES = re.compile(r"ls-files")

# Below this, the scan has plainly failed rather than found a clean repository:
# the population was 8 when this gate was written and does not shrink by
# accident. Fail closed -- a derivation that silently empties reports no
# findings, which is the vacuity this file exists to refuse.
MIN_INDEX_GATES = 4


def index_reading_gates() -> list[str]:
    """Gate scripts whose subject list is derived from `git ls-files`."""
    found = []
    for path in sorted((REPO / "scripts").glob("check_*.py")):
        # Exclude self. This file necessarily contains the pattern it searches
        # for, and counting itself would overstate the population by one -- a
        # measurement that includes the measuring instrument.
        if path.name == pathlib.Path(__file__).name:
            continue
        try:
            if LS_FILES.search(path.read_text(encoding="utf-8", errors="replace")):
                found.append(path.name)
        except OSError:
            continue
    return found


def untracked_files() -> list[str]:
    """Untracked, non-ignored paths. `--porcelain` already applies .gitignore."""
    out = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=REPO, capture_output=True, text=True, encoding="utf-8", check=True,
    ).stdout
    return [line[3:].strip() for line in out.splitlines() if line.startswith("?? ")]


def self_test() -> int:
    """Prove the two failures FIRST, then the pass. The ordering is the content:
    both this repository's recent vacuity defects were guards written after the
    instrument already worked."""
    failures = []

    # 1. THE EMPTY DERIVATION IS FATAL. If the scan finds no index-reading
    #    gates, it has broken -- it must not read as "nothing to worry about".
    if not _derivation_is_fatal([]):
        failures.append("an empty gate derivation must be FATAL")
    if not _derivation_is_fatal(["a.py"] * (MIN_INDEX_GATES - 1)):
        failures.append(f"fewer than {MIN_INDEX_GATES} gates must be FATAL")
    if _derivation_is_fatal(["a.py"] * MIN_INDEX_GATES):
        failures.append(f"exactly {MIN_INDEX_GATES} gates must be accepted")

    # 2. THE LIVE DERIVATION must actually find the known population, or the
    #    regex has drifted away from the call it is looking for.
    live = index_reading_gates()
    if len(live) < MIN_INDEX_GATES:
        failures.append(f"live scan found only {len(live)} index-reading gates")
    if "check_geometry_checkers.py" not in live:
        failures.append("the gate whose blindness was MEASURED is not in the "
                        "derived list -- the scan is not finding what it claims")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print(f"check_index_blindspot SELF-TEST: OK (empty and under-floor "
          f"derivations proven FATAL first; live scan finds {len(live)} "
          f"index-reading gates including the measured one)")
    return 0


def _derivation_is_fatal(gates) -> bool:
    """The fail-closed rule, as a function so the self-test can prove it."""
    return len(gates) < MIN_INDEX_GATES


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()

    gates = index_reading_gates()
    if _derivation_is_fatal(gates):
        print(f"FAIL: derived only {len(gates)} index-reading gate(s), floor is "
              f"{MIN_INDEX_GATES}. The scan has broken; it is not reporting a "
              f"clean repository.")
        return 1

    untracked = untracked_files()
    if untracked:
        print(f"FAIL: {len(untracked)} untracked file(s) are INVISIBLE to "
              f"{len(gates)} gate(s) that read the index.\n")
        print("A gate whose subject list comes from `git ls-files` cannot see a")
        print("file until it is staged. Verifying now and committing after would")
        print("run those gates at the one moment these files do not exist to")
        print("them — which is how a red gate shipped inside a commit whose")
        print("message said every gate was green.\n")
        for p in untracked[:20]:
            print(f"  ?? {p}")
        if len(untracked) > 20:
            print(f"  ... and {len(untracked) - 20} more")
        print("\nBlind to them:")
        for g in gates:
            print(f"  {g}")
        print("\nFIX: `git add` them (staging alone is enough — `git ls-files`")
        print("lists the index, so nothing needs committing), then re-run.")
        print("If a file should NOT be committed, .gitignore it; this gate")
        print("deliberately will not decide that for you.")
        return 1

    print(f"check_index_blindspot: OK (no untracked files; the {len(gates)} "
          f"index-reading gates can see the whole tree they are about to judge)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
