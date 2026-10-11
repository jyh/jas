#!/usr/bin/env python3
"""A frozen baseline changes only with the spec, never on its own.

WHY THIS EXISTS
---------------
`docs/TESTING.md` section 2 rules that a PR which changes a frozen baseline
must also change the spec item that baseline renders, "and a tool must enforce
this". This is that tool. Without it a baseline is re-frozen whenever a run
disagrees with it, and a comparison that is re-frozen on disagreement compares
nothing: the baseline becomes a record of the last build, not of the spec.

WHAT A BASELINE IS, AND WHICH SPEC IT RENDERS
---------------------------------------------
A baseline is any file under `<anything>/e2e_baselines/<item>/`. The item maps
to its spec through the INPUT SCRIPT whose `item` field names it
(`test_fixtures/input_scripts/*.json`, `docs/TESTING.md` section 6): the
script's `spec` field is the spec file. A baseline whose item no script names
is REFUSED BY NAME, never passed: an unmapped baseline is one whose spec this
gate cannot see, and a silent pass there would be the hole it exists to close.

THE VERDICTS, per item whose baseline files the range changes
-------------------------------------------------------------
* `PASS(spec)`: the script's spec file also changed in the range.
* `PASS(declared)`: a commit in the range carries, ON ITS OWN LINE, the
  trailer `Baseline-Refreeze: <item>: <reason>` with a non-empty reason.
  The spec is not the only legitimate cause of a new baseline. On 2026-10-10
  `selection.drag` was re-frozen because the app had been WRONG (the engine
  started with a brown fill the spec never asked for) and because the box's
  desktop moved the window by 8 device pixels. Neither is a spec change. The
  trailer makes such a re-freeze a named, reviewable act in the history, which
  is the difference between "changed with a reason" and "changed on its own".
* `PASS(first-freeze)`: every file of the item is NEW in the range and the item
  maps to a script. A new baseline adds a check; it does not move one.
* `FAIL`: anything else, including a baseline DELETED with no spec change or
  declaration (deleting a baseline drops a check as silently as moving it).

The range is compared by its NET diff (`git diff A B`): a spec edited and
reverted inside the range has not changed, and a baseline moved and moved back
has not moved.

FAILING CLOSED
--------------
A range of zero commits REDS. A range with commits that touches no baseline is
OK and says how many commits it read, so "nothing to check" is never printed
in the same words as "checked".

WHAT IT DOES NOT COVER
----------------------
* It does not judge whether a declared reason is TRUE. It makes the reason
  exist where a reviewer reads it; the review is the reviewer's.
* It does not compare pixels or decide a tolerance (`docs/TESTING.md` leaves
  the tolerance unruled).
* It sees only baselines under an `e2e_baselines/` directory. A baseline kept
  anywhere else is outside it, and the first such directory must be added here.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS_DIR = "test_fixtures/input_scripts"
BASELINE_SEGMENT = "e2e_baselines"
TRAILER = re.compile(r"^Baseline-Refreeze:[ \t]*([^:\s]+)[ \t]*:[ \t]*(\S.*)$", re.M)


def self_id() -> str:
    try:
        return hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()[:16]
    except OSError:
        return "unreadable"


def git(repo: pathlib.Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True,
                          encoding="utf-8", check=True).stdout


def baseline_item(path: str) -> str | None:
    """The item a path is a baseline of, or None. `a/e2e_baselines/<item>/f`."""
    parts = path.split("/")
    for i, p in enumerate(parts[:-2]):
        if p == BASELINE_SEGMENT:
            return parts[i + 1]
    return None


def script_specs(repo: pathlib.Path, rev: str) -> dict[str, str]:
    """item -> spec path, from every input script at `rev`."""
    out: dict[str, str] = {}
    try:
        names = git(repo, "ls-tree", "--name-only", f"{rev}:{SCRIPTS_DIR}").split()
    except subprocess.CalledProcessError:
        return out
    for n in names:
        if not n.endswith(".json"):
            continue
        try:
            d = json.loads(git(repo, "show", f"{rev}:{SCRIPTS_DIR}/{n}"))
        except (subprocess.CalledProcessError, json.JSONDecodeError):
            continue
        if isinstance(d, dict) and isinstance(d.get("item"), str) and isinstance(d.get("spec"), str):
            out.setdefault(d["item"], d["spec"])
    return out


def check(repo: pathlib.Path, rev_range: str) -> tuple[bool, list[str]]:
    """(ok, report lines) for `rev_range` of the form A..B."""
    head = f"check_baseline_spec_change [{self_id()}] {rev_range}:"
    if ".." not in rev_range or "..." in rev_range:
        return False, [f"{head} FAIL -- the range must be A..B"]
    a, b = rev_range.split("..", 1)
    b = b or "HEAD"
    n_commits = int(git(repo, "rev-list", "--count", rev_range).strip())
    if n_commits == 0:
        return False, [f"{head} FAIL -- the range names 0 commit(s); an empty scan is not a clean one"]

    # The NET change, A against B: what the PR lands.
    status: dict[str, str] = {}
    for row in git(repo, "diff", "--name-status", "--no-renames", a, b).splitlines():
        st, _, path = row.partition("\t")
        status[path] = st[:1]
    touched: dict[str, list[str]] = {}
    for path, st in status.items():
        item = baseline_item(path)
        if item is not None:
            touched.setdefault(item, []).append(st)

    declared: dict[str, str] = {}
    for m in TRAILER.finditer(git(repo, "log", "--format=%B", rev_range)):
        declared.setdefault(m.group(1), m.group(2).strip())

    specs = script_specs(repo, b)
    for item, spec in script_specs(repo, a).items():
        specs.setdefault(item, spec)

    lines, ok = [], True
    for item in sorted(touched):
        sts = touched[item]
        spec = specs.get(item)
        if spec is None:
            verdict = f"FAIL(no input script in {SCRIPTS_DIR} names item '{item}')"
        elif all(s == "A" for s in sts) and not _baseline_existed(repo, a, item):
            verdict = "PASS(first-freeze)"
        elif spec in status:
            verdict = "PASS(spec)"
        elif item in declared:
            verdict = f"PASS(declared: {declared[item]})"
        else:
            verdict = f"FAIL(changed with no change to {spec} and no Baseline-Refreeze)"
        ok = ok and verdict.startswith("PASS")
        lines.append(f"  BASELINE {item} {verdict} [{len(sts)} file(s)]")
    summary = (f"{head} {'OK' if ok else 'FAIL'} -- {len(touched)} baseline item(s) changed "
               f"in {n_commits} commit(s)")
    if not ok:
        lines.append("  A baseline changes only with the spec (docs/TESTING.md section 2): change the spec item it "
                     "renders, or declare why in a commit, on its own line: "
                     "Baseline-Refreeze: <item>: <reason>")
    return ok, [summary, *lines]


def _baseline_existed(repo: pathlib.Path, rev: str, item: str) -> bool:
    paths = git(repo, "ls-tree", "-r", "--name-only", rev).splitlines()
    return any(baseline_item(p) == item for p in paths)


# ---------------------------------------------------------------------------
# --self-test: every arm builds a scratch repository and drives one shape.
# ---------------------------------------------------------------------------
SPEC = "workspace/tools/selection.yaml"
SCRIPT = {"item": "selection.drag", "spec": SPEC, "steps": [{"read": "document"}]}
BASE = "prototypes/sb_winui/e2e_baselines/selection.drag/baseline.json"


def _repo(tmp: pathlib.Path) -> pathlib.Path:
    r = tmp / "r"
    r.mkdir()
    git(r, "init", "-q", "-b", "main")
    git(r, "config", "user.email", "t@example.invalid")
    git(r, "config", "user.name", "t")
    _write(r, f"{SCRIPTS_DIR}/selection.drag.json", json.dumps(SCRIPT))
    _write(r, SPEC, "spec: 1\n")
    _write(r, BASE, '{"frame_hash": "a"}\n')
    # A second mapped item, present at the base, for the two-item arm.
    _write(r, f"{SCRIPTS_DIR}/s.lasso.json", json.dumps({"item": "s.lasso", "spec": "workspace/x.yaml"}))
    _write(r, "p/e2e_baselines/s.lasso/baseline.json", "{}\n")
    _commit(r, "base")
    return r


def _write(r: pathlib.Path, rel: str, text: str) -> None:
    p = r / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8", newline="\n")


def _commit(r: pathlib.Path, msg: str) -> None:
    git(r, "add", "-A")
    git(r, "commit", "-q", "--allow-empty", "-m", msg)


def self_test() -> int:
    arms = []

    def arm(label, build, want_ok, want_text):
        arms.append((label, build, want_ok, want_text))

    arm("an empty range REDS, never an empty pass",
        lambda r: None, False, "0 commit(s)")
    arm("a range touching no baseline is OK and counts what it read",
        lambda r: (_write(r, "README.md", "x\n"), _commit(r, "doc")), True,
        "0 baseline item(s) changed in 1 commit(s)")
    arm("baseline + its spec changed: PASS(spec)",
        lambda r: (_write(r, BASE, '{"frame_hash": "b"}\n'), _write(r, SPEC, "spec: 2\n"),
                   _commit(r, "both")), True, "selection.drag PASS(spec)")
    arm("baseline changed alone: FAIL, naming the item and its spec",
        lambda r: (_write(r, BASE, '{"frame_hash": "b"}\n'), _commit(r, "refreeze")), False,
        f"selection.drag FAIL(changed with no change to {SPEC} and no Baseline-Refreeze)")
    arm("a declared refreeze with a reason: PASS(declared), reason printed",
        lambda r: (_write(r, BASE, '{"frame_hash": "b"}\n'),
                   _commit(r, "refreeze\n\nBaseline-Refreeze: selection.drag: the engine now starts white")),
        True, "selection.drag PASS(declared: the engine now starts white)")
    arm("a declaration naming ANOTHER item does not cover this one",
        lambda r: (_write(r, BASE, '{"frame_hash": "b"}\n'),
                   _commit(r, "refreeze\n\nBaseline-Refreeze: selection.marquee: x")),
        False, "selection.drag FAIL")
    arm("a declaration with an empty reason is not a declaration",
        lambda r: (_write(r, BASE, '{"frame_hash": "b"}\n'),
                   _commit(r, "refreeze\n\nBaseline-Refreeze: selection.drag:")),
        False, "selection.drag FAIL")
    arm("the trailer inside prose, not on its own line, does not count",
        lambda r: (_write(r, BASE, '{"frame_hash": "b"}\n'),
                   _commit(r, "see Baseline-Refreeze: selection.drag: x for the form")),
        False, "selection.drag FAIL")
    arm("a first freeze of a mapped item: PASS(first-freeze)",
        lambda r: (_write(r, f"{SCRIPTS_DIR}/s.marquee.json",
                          json.dumps({"item": "s.marquee", "spec": SPEC})),
                   _write(r, "p/e2e_baselines/s.marquee/baseline.json", "{}\n"),
                   _commit(r, "new")), True, "s.marquee PASS(first-freeze)")
    arm("a baseline no script maps is REFUSED BY NAME, even on a first freeze",
        lambda r: (_write(r, "p/e2e_baselines/orphan/baseline.json", "{}\n"), _commit(r, "orphan")),
        False, "orphan FAIL(no input script in test_fixtures/input_scripts names item 'orphan')")
    arm("a deleted baseline with no spec change or declaration: FAIL",
        lambda r: ((r / BASE).unlink(), _commit(r, "drop")), False, "selection.drag FAIL")
    arm("a spec changed and reverted inside the range has NOT changed",
        lambda r: (_write(r, SPEC, "spec: 2\n"), _commit(r, "s"), _write(r, SPEC, "spec: 1\n"),
                   _write(r, BASE, '{"frame_hash": "b"}\n'), _commit(r, "revert + refreeze")),
        False, "selection.drag FAIL")
    arm("two items, one declared: FAIL names only the undeclared one",
        lambda r: (_write(r, BASE, '{"frame_hash": "b"}\n'),
                   _write(r, "p/e2e_baselines/s.lasso/baseline.json", '{"a": 1}\n'),
                   _commit(r, "two\n\nBaseline-Refreeze: selection.drag: white")),
        False, "s.lasso FAIL")

    fails = 0
    ran = 0
    for label, build, want_ok, want_text in arms:
        with tempfile.TemporaryDirectory() as t:
            r = _repo(pathlib.Path(t))
            base = git(r, "rev-parse", "HEAD").strip()
            build(r)
            try:
                ok, lines = check(r, f"{base}..HEAD")
            except Exception as e:  # an arm that crashes is a failed arm, never a pass
                ok, lines = None, [f"CRASH {type(e).__name__}: {e}"]
            ran += 1
            text = "\n".join(lines)
            if ok is not want_ok or want_text not in text:
                fails += 1
                print(f"SELF-TEST FAIL: {label}\n  want ok={want_ok} containing {want_text!r}\n"
                      f"  got  ok={ok}:\n    " + text.replace("\n", "\n    "))
    print(f"check_baseline_spec_change --self-test [{self_id()}]: {ran} arm(s) executed, "
          f"{len(arms)} declared, {fails} failed")
    return 1 if fails or ran != len(arms) or ran == 0 else 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--range", help="A..B: the PR's own delta, e.g. $(git merge-base origin/main HEAD)..HEAD")
    g.add_argument("--self-test", action="store_true")
    a = ap.parse_args(argv)
    if a.self_test:
        return self_test()
    ok, lines = check(ROOT, a.range)
    for line in lines:
        print(line)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
