#!/usr/bin/env python3
"""The history scrub was a one-time act. Nothing has watched it since.

WHY THIS EXISTS
---------------
On 2026-07-22 this repository's public history was rewritten to strip a
per-commit trailer that embedded a private chat-session URL. That was a
deliberate, expensive, irreversible act: every SHA before it died, and commits
from that era must now be cited by subject line because their hashes no longer
resolve.

The rule that followed it lives in prose, in a project instruction file. Prose
is read by people who read that file, and this repository has spent a fortnight
cataloguing what happens to a rule that no machine enforces. This is that
pattern's sharpest instance yet, because the cost of a lapse is not a red test:
**it is a second history rewrite, or a permanent leak.** A commit message cannot
be edited after it is pushed and fetched without breaking every clone.

Measured at the time this gate was written: `origin/main` carried **zero**
occurrences across 3067 commits — the scrub held. And **five unmerged commits on
a live feature branch each carried one**, queued to merge. The rule had already
lapsed; only the merge had not happened yet. A guard that arrives the week the
first violation appears is a guard that arrived late, which is the argument for
writing it now rather than after the next scrub.

WHAT IT CHECKS
--------------
Every commit message reachable from HEAD (or a supplied range) against a small
set of forbidden patterns. Not file contents — a URL in a source comment is a
different question with a different answer, and conflating them would make this
gate mean two things.

FAILING CLOSED
--------------
A scan that resolves to zero commits REDS rather than reporting success. An
empty scan and a clean scan produce the same green otherwise, and this
repository has shipped that exact fault twice in one fortnight: a corpus
generator that wrote nothing and reported success, and a resolver that answered
`{}` for a kind it did not recognise. The rule adopted from that, and applied
here in this order: **a gate must be shown to fail on an empty input set before
it is allowed to pass on a full one** (`--self-test` proves both).

WHAT THIS DELIBERATELY DOES NOT DO
----------------------------------
* It does not scan working-tree files. A chat URL pasted into a doc is a
  content question; this is a HISTORY question, and history is the one that
  cannot be fixed with an ordinary commit.
* It cannot see a commit that has not been written yet, which is the whole
  reason it belongs in CI on every push rather than in a local hook only.
* It says nothing about `Co-Authored-By`, which is CORRECT and stays. The scrub
  removed session URLs; it deliberately kept authorship attribution, and a gate
  that swept both would quietly undo a decision it was never asked about.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import os
import re
import pathlib
import subprocess
import sys
import tempfile

# The forbidden shapes. Assembled from parts so that this file's own source can
# be grepped for the literal without matching, and so a commit message
# DESCRIBING the rule (like the one that adds this gate) does not trip it.
_SESSION_KEY = "Claude" + "-Session"
_HOST = r"claude\.ai"

FORBIDDEN = [
    (re.compile(rf"^\s*{re.escape(_SESSION_KEY)}\s*:", re.I | re.M),
     f"a {_SESSION_KEY} trailer"),
    (re.compile(rf"https?://(?:[\w.-]+\.)?{_HOST}/\S+", re.I),
     "a chat-service session URL"),
]

# Attribution the scrub deliberately KEPT. Named here so a future reader does
# not "tidy" it into the forbidden list.
PRESERVED = "Co-Authored-By"

ROOT = pathlib.Path(__file__).resolve().parent.parent


def commit_messages(rev_range: str) -> list[tuple[str, str]]:
    """(sha, message) for every commit in `rev_range`, newest first."""
    # Sentinels are passed through git's own %x-escapes rather than as literal
    # argv bytes: a NUL in argv raises ValueError before git is ever reached.
    sep = "@@JASCOMMIT@@"
    out = subprocess.run(
        ["git", "log", f"--format=%H%x1f%B{sep}", rev_range], cwd=ROOT,
        capture_output=True, text=True, encoding="utf-8", check=True,
    ).stdout
    rows = []
    for chunk in out.split(sep):
        chunk = chunk.strip("\n")
        if not chunk:
            continue
        sha, _, body = chunk.partition("\x1f")
        rows.append((sha.strip(), body))
    return rows


def tracked_files() -> list[tuple[str, str]]:
    """Every tracked TEXT file, as (path, contents).

    WHY THIS EXISTS. The trailer gate scanned commit MESSAGES only, and said so
    proudly — it is a history gate. But on 2026-08-05 the windows seat found a
    real session URL sitting in his hook's proof script AS TEST DATA, caught it
    by eye, and sanitised it before sending. **Nothing in this repository would
    have caught it.** A forbidden string in a FILE ships to a public repo just
    as surely as one in a commit message, and the message gate is structurally
    blind to it — it is not scanning the wrong thing, it is scanning a
    different thing.

    Same FORBIDDEN list, deliberately: the patterns have exactly one definition
    in this tree and both scans read it.

    This file needs no exemption. Its patterns are assembled from parts
    (`_SESSION_KEY`, `_HOST`) precisely so its own source never matches them —
    verified by the self-test, which would otherwise pass vacuously by
    excluding the only interesting file.
    """
    out = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT,
                         capture_output=True, text=True, encoding="utf-8",
                         check=True)
    rows: list[tuple[str, str]] = []
    missing: list[str] = []
    for rel in out.stdout.split("\0"):
        if not rel:
            continue
        path = ROOT / rel
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, IsADirectoryError):
            continue  # binary, or a submodule directory
        except FileNotFoundError:
            if path.is_symlink():
                continue  # a symlink pointing nowhere is tracked but unreadable
            missing.append(rel)  # a tracked file absent under ROOT: list and tree disagree
            continue
        rows.append((rel, text))
    if missing:
        print(f"FAIL: {len(missing)} tracked file(s) listed by git but absent under "
              f"{ROOT}: {missing[:3]}{' ...' if len(missing) > 3 else ''}. The file list "
              "and the tree being scanned are not the same repository.")
        raise SystemExit(1)
    return rows


def scan(rows: list[tuple[str, str]]) -> list[tuple[str, str, str]]:
    """(sha, what, line) for every violation found."""
    bad = []
    for sha, body in rows:
        for pattern, what in FORBIDDEN:
            m = pattern.search(body)
            if m:
                line = next((l for l in body.splitlines() if m.group(0)[:40] in l),
                            m.group(0))
                bad.append((sha, what, line.strip()))
    return bad


def self_test() -> int:
    """Prove the gate FAILS on an empty scan and on a planted violation, in
    that order, before trusting any green it reports."""
    global ROOT  # arm 6 rebinds it over a scratch repo and restores it
    failures = []

    # 1. THE EMPTY SET, FIRST. A scan with nothing in it must not read as clean.
    if scan([]) != []:
        failures.append("scan([]) should find nothing to report")
    #    ...and the caller must refuse it. That is the fail-closed contract.
    if not _is_empty_scan_fatal([]):
        failures.append("an empty commit set must be FATAL, not green")

    # 2. A planted violation of each shape must be caught.
    # One shape each, so the count is unambiguous. (The first draft planted a
    # message carrying BOTH and asserted 2; it found 3, because a trailer whose
    # value is a URL is legitimately two findings. The self-test caught the
    # ASSERTION, not the gate -- kept as written because a reader will
    # otherwise make the same arithmetic slip.)
    planted_trailer = [("aaa1", f"Subject\n\n{_SESSION_KEY}: session_x\n")]
    # ASSEMBLED, not written literally — the same trick FORBIDDEN itself uses,
    # and for a sharper reason since 2026-08-05: this gate now scans FILE
    # CONTENTS, and its first run caught THIS LINE, which used to carry the URL
    # verbatim. A detector's test data contains the thing it detects, so a
    # detector that also scans files must never spell its own fixture out.
    planted_url = [("aaa2", "Subject\n\nSee https://" + _HOST.replace(chr(92), "")
                    + "/code/session_abc\n")]
    if len(scan(planted_trailer)) != 1:
        failures.append(f"trailer shape must be caught, got {len(scan(planted_trailer))}")
    if len(scan(planted_url)) != 1:
        failures.append(f"URL shape must be caught, got {len(scan(planted_url))}")
    if len(scan(planted_trailer + planted_url)) != 2:
        failures.append("both shapes together must yield two findings")

    # 3. A clean message, INCLUDING the attribution the scrub kept, must pass.
    clean = [("bbb1", f"Subject\n\nBody.\n\n{PRESERVED}: Claude <noreply@anthropic.com>\n")]
    if scan(clean):
        failures.append(f"{PRESERVED} must not be treated as forbidden")

    # 4. The gate must not fire on a message that merely NAMES the rule, or the
    #    commit adding this gate could not describe what it does.
    meta = [("ccc1", "Subject\n\nThis gate forbids session-URL trailers.\n")]
    if scan(meta):
        failures.append("a message describing the rule must not trip it")

    # 5. THE SCAN MUST NOT DEPEND ON THE CALLER'S CWD. Hand-run from another
    #    repository, `git ls-files` and `git log` used to answer about THAT
    #    repo. Measured here on 2026-09-14 before the repair, in a throwaway
    #    repo holding one file and one commit: `tracked_files()` returned
    #    **0 rows** (the foreign name does not exist under ROOT, so the read
    #    raised FileNotFoundError and was swallowed as "binary"), and
    #    `commit_messages("HEAD")` returned the FOREIGN commit -- 1 row where
    #    ROOT has 3615. A vacuous scan and a scan of the wrong repository, both
    #    silent. The empty-scan rule catches the first only when the caller
    #    happens to route it through `_is_empty_scan_fatal`; nothing at all
    #    caught the second. Ported from salt's copy, which fixed all three call
    #    sites and armed one of them; both readers are armed here because both
    #    were measured to move.
    #    ⛔ THE FOREIGN REPO HOLDS A NAME ROOT ALSO HAS, AND THAT CHOICE IS THE
    #    ARM. A foreign file ROOT lacks is caught one frame earlier by arm 6's
    #    refusal, so the cwd assertion below would never be reached and would be
    #    a guard no mutant can kill (`two-guards-one-predicate`). Sharing the
    #    name puts the refusal out of the way and leaves the count -- 1 file
    #    from the foreign list against ROOT's whole tree -- as the only thing
    #    that can fire. Driven: with `cwd=ROOT` removed from `git ls-files`,
    #    this is the assertion that reds.
    here = os.getcwd()
    shared = "README.md"
    if not (ROOT / shared).is_file():
        failures.append(f"the cwd arm's fixture needs a file ROOT has; {shared} is not one")
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["git", "init", "-q"], cwd=tmp, check=True)
        pathlib.Path(tmp, shared).write_text("a foreign README\n", encoding="utf-8", newline="\n")
        subprocess.run(["git", "add", shared], cwd=tmp, check=True)
        subprocess.run(["git", "-c", "user.email=self@test", "-c", "user.name=self",
                        "commit", "-q", "-m", "a foreign commit"], cwd=tmp, check=True)
        try:
            os.chdir(tmp)
            from_foreign = tracked_files()
            msgs_foreign = commit_messages("HEAD")
        finally:
            os.chdir(here)
    from_root = tracked_files()
    msgs_root = commit_messages("HEAD")
    if len(from_root) < 2:
        failures.append("the cwd arm is vacuous: ROOT itself lists fewer than two "
                        f"tracked files ({len(from_root)})")
    if len(from_foreign) != len(from_root):
        failures.append("tracked_files() must not depend on cwd: "
                        f"{len(from_foreign)} from a foreign repo vs {len(from_root)} from ROOT")
    if len(msgs_root) < 2:
        failures.append("the cwd arm is vacuous: ROOT itself has fewer than two commits "
                        f"({len(msgs_root)})")
    if len(msgs_foreign) != len(msgs_root):
        failures.append("commit_messages() must not depend on cwd: "
                        f"{len(msgs_foreign)} from a foreign repo vs {len(msgs_root)} from ROOT")

    #    ...and the third git call is armed too, because a repair with no arm
    #    is what this port exists to correct. `--is-shallow-repository` answers
    #    `true` exactly when `.git/shallow` exists, so a scratch repo with that
    #    file planted is a foreign SHALLOW repo: run from inside it, is_shallow()
    #    must still answer about ROOT, which is not shallow.
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["git", "init", "-q"], cwd=tmp, check=True)
        pathlib.Path(tmp, ".git", "shallow").write_text("", encoding="utf-8", newline="\n")
        try:
            os.chdir(tmp)
            shallow_says = is_shallow()
        finally:
            os.chdir(here)
    if shallow_says:
        failures.append("is_shallow() must not depend on cwd: it reported the FOREIGN "
                        "repo's shallowness while ROOT is not shallow")

    # 6. A TRACKED FILE THE TREE DOES NOT HAVE MUST REFUSE, NOT BE SKIPPED.
    #    This is the arm salt's copy does not carry, and it is the half that
    #    makes arm 5's defect SILENT: every "absent under ROOT" name used to
    #    leave by the same door as a binary. Driven against a scratch repo by
    #    rebinding ROOT, because the only honest subject is a real disagreement
    #    between `git ls-files` and the tree.
    saved_root = ROOT
    try:
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(["git", "init", "-q"], cwd=tmp, check=True)
            victim = pathlib.Path(tmp, "TRACKED-THEN-DELETED.txt")
            victim.write_text("present at add time\n", encoding="utf-8", newline="\n")
            subprocess.run(["git", "add", victim.name], cwd=tmp, check=True)
            ROOT = pathlib.Path(tmp)
            # ⛔ THE CONTROL CATCHES SystemExit, AND THAT IS NOT DEFENSIVENESS.
            # An uncaught refusal here leaves the function before the
            # `SELF-TEST FAIL` lines are printed, so EVERY earlier arm's
            # finding is swallowed and only this arm's refusal text survives.
            # Measured: with `cwd=ROOT` dropped from `git ls-files`, arm 5
            # recorded its failure correctly and the run printed nothing but
            # arm 6's refusal -- a correct red carrying the wrong diagnosis.
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    present = tracked_files()
                if len(present) != 1:
                    failures.append("the missing-file arm's own control failed: a present "
                                    f"tracked file must be read, got {len(present)} rows")
            except SystemExit:
                failures.append("the missing-file arm's own control failed: a present "
                                "tracked file must be read, not refused")
            victim.unlink()
            # The refusal PRINTS, and its print belongs to the arm, not to the
            # self-test's own report: a bare `FAIL:` line inside a run that
            # ends `OK` is exactly the reading a hurried eye gets wrong.
            said = io.StringIO()
            try:
                with contextlib.redirect_stdout(said):
                    tracked_files()
                failures.append("a tracked file absent under ROOT must REFUSE, not be "
                                "skipped as if it were binary")
            except SystemExit as e:
                if e.code != 1:
                    failures.append(f"the missing-file refusal must exit 1, got {e.code}")
                if victim.name not in said.getvalue():
                    failures.append("the missing-file refusal must NAME the absent file; "
                                    f"it said {said.getvalue()!r}")
    finally:
        ROOT = saved_root
    #    ...and the restore is ASSERTED, not merely written. Arm 6 is the last
    #    arm, so a `finally` that stopped running would leave ROOT pointing at
    #    a deleted temporary directory with every arm still green -- and this
    #    module is IMPORTED by the pre-push hook, which then scans nothing.
    if ROOT != saved_root:
        failures.append("arm 6 left ROOT at "
                        f"{ROOT.as_posix()}, not {saved_root.as_posix()}")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print("check_commit_trailers SELF-TEST: OK "
          "(empty scan fatal proven FIRST, both forbidden shapes caught, "
          f"{PRESERVED} preserved, self-describing message safe, cwd-independent, absent tracked file refused)")
    return 0


def _is_empty_scan_fatal(rows) -> bool:
    """The fail-closed rule, as a function so the self-test can prove it."""
    return len(rows) == 0


def is_shallow() -> bool:
    """A shallow clone would let this gate scan ONE commit and call it clean.

    `actions/checkout@v4` defaults to `fetch-depth: 1`. A history gate run
    against a one-commit clone is the decorative instrument this repository
    keeps finding: green, cheap, and measuring almost nothing. The CI step
    therefore sets `fetch-depth: 0`, and this refuses to run without it rather
    than trusting the workflow to stay correct.
    """
    out = subprocess.run(["git", "rev-parse", "--is-shallow-repository"], cwd=ROOT,
                         capture_output=True, text=True, encoding="utf-8")
    return out.stdout.strip() == "true"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--range", default="HEAD",
                    help="git revision range to scan (default: all of HEAD)")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    if is_shallow():
        print("FAIL: this is a SHALLOW clone, so history is not all here and a "
              "clean result would be meaningless.\n"
              "      A history gate on a one-commit checkout scans one commit "
              "and reports success.\n"
              "      CI must check out with `fetch-depth: 0` for this job.")
        return 1

    try:
        rows = commit_messages(args.range)
    except subprocess.CalledProcessError as e:
        print(f"FAIL: could not read history for '{args.range}': {e}")
        return 1

    # FAIL CLOSED: nothing scanned is not the same as nothing wrong.
    if _is_empty_scan_fatal(rows):
        print(f"FAIL: scanned ZERO commits for '{args.range}'. An empty scan is "
              f"not a clean scan — this gate refuses to report success on it.")
        return 1

    bad = scan(rows)
    if bad:
        print(f"FAIL: {len(bad)} commit message(s) carry a forbidden trailer.\n")
        print("This repository's public history was rewritten on 2026-07-22 to")
        print("remove exactly this. A commit that reaches a published branch")
        print("cannot be edited without breaking every clone, so this must be")
        print("fixed BEFORE the merge, by rewriting the offending messages.\n")
        for sha, what, line in bad:
            print(f"  {sha[:12]}  {what}")
            print(f"      {line[:100]}")
        print(f"\nTo repair an unpushed range:  git rebase -i --exec "
              f"'git commit --amend --no-edit' <base>")
        print("For a pushed feature branch, rewrite and force-push THAT branch "
              "before merging — never after.")
        return 1

    # SECOND SUBJECT, added 2026-08-05: the FILE CONTENTS. A forbidden string
    # in a tracked file ships to a public repo exactly as surely as one in a
    # commit message, and the message scan above is structurally blind to it.
    # The windows seat found a real session URL in his hook's proof script, as
    # test data, and caught it BY EYE.
    files = tracked_files()
    if not files:
        print("FAIL: scanned ZERO tracked files. An empty scan is a failure, "
              "not a pass — the ls-files call or the decode filter has drifted.")
        return 1
    bad_files = scan(files)
    if bad_files:
        print(f"FAIL: {len(bad_files)} tracked file(s) carry a forbidden string.\n")
        print("Unlike a commit message this is trivially fixable — edit the file")
        print("— but only BEFORE it is pushed. This repository is public.\n")
        for path, what, line in bad_files:
            print(f"  {path}  {what}")
            print(f"      {line[:100]}")
        return 1

    print(f"check_commit_trailers: OK ({len(rows)} commit messages and "
          f"{len(files)} tracked files scanned, 0 forbidden strings; "
          f"{PRESERVED} attribution untouched)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
