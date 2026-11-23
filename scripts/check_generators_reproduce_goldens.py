#!/usr/bin/env python3
"""Every golden generator must reproduce the committed bytes: running them all changes no file.

WHY THIS EXISTS
---------------
The corpus runners TRIM what they read, so a golden whose bytes differ from what
its generator writes still passes every test. Nothing saw the drift until a
regeneration rewrote the file as noise: row 222 fixed one action golden, and
row 234 fixed seventeen operation goldens, on the same day (2026-11-23). This
gate reds the drift at the commit that causes it.

WHAT IT DOES
------------
* Derives the generators from the source: every `#[ignore]` test in
  `jas_dioxus/src` whose name contains `generate` (the `generate_*` and
  `regenerate_*` helpers). Never a hand-typed list.
* Runs them all (`cargo test --lib generate -- --ignored`, in `jas_dioxus/`,
  CARGO_TARGET_DIR honoured), and requires every derived generator to report
  `ok`: a generator that did not run reproduces nothing, so it is named, not
  passed (the anti-vacuity floor is the derived set itself).
* Compares the repo's dirty files, with their content hashes, before and after.
  ANY file a generator changed is a finding, wherever it lives, so a generator
  that writes somewhere new is still watched.

WHAT IT DOES NOT DO, SAID HERE SO A GREEN IS NOT READ AS MORE
-------------------------------------------------------------
* It cannot see a golden no generator writes (hand-authored fixtures, such as
  `operations/recorded_eye.json`).
* It runs the generators in the `web` default feature set only.
* It leaves the regenerated files in place, so the author can read the diff;
  on a local tree, `git checkout -- <files>` restores them.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CRATE = ROOT / "jas_dioxus"


# An `#[ignore]` attribute, then (within the next few lines, past any other
# attribute or comment) the `fn` it guards.
_IGNORED_FN = re.compile(r"#\[ignore\b[^\n]*\n(?:[ \t]*(?://[^\n]*|#\[[^\n]*)\n){0,3}[ \t]*(?:pub(?:\([^)]*\))? )?fn (\w+)")


def generator_names(sources: dict[str, str]) -> set[str]:
    """Every `#[ignore]` test whose name contains `generate`, across `sources`."""
    out: set[str] = set()
    for text in sources.values():
        for m in _IGNORED_FN.finditer(text):
            if "generate" in m.group(1):
                out.add(m.group(1))
    return out


_OK_LINE = re.compile(r"^test (?:\S+::)?(\w+) \.\.\. ok$", re.M)


def ran_ok(log: str) -> set[str]:
    """The test names cargo reported `ok` (the last path segment)."""
    return set(_OK_LINE.findall(log))


def changed(before: dict[str, str], after: dict[str, str]) -> list[str]:
    """Paths whose dirty-state hash differs between the snapshots: newly dirty,
    rewritten, or no longer dirty (restored or removed)."""
    return sorted(p for p in set(before) | set(after) if before.get(p) != after.get(p))


def dirty_hashes() -> dict[str, str]:
    """Every dirty or untracked path in the repo, with the sha256 of its bytes
    (or '-' when it is gone)."""
    out = subprocess.run(["git", "status", "--porcelain", "-z", "--untracked-files=all"],
                         cwd=ROOT, capture_output=True, check=True).stdout.decode("utf-8", "replace")
    paths = []
    for entry in out.split("\0"):
        if len(entry) > 3:
            paths.append(entry[3:])
    res = {}
    for p in paths:
        f = ROOT / p
        res[p] = hashlib.sha256(f.read_bytes()).hexdigest() if f.is_file() else "-"
    return res


def self_test() -> int:
    failures: list[str] = []
    ran: list[str] = []

    def check(cond, label):
        ran.append(label)
        if not cond:
            failures.append(label)

    src = {
        "a.rs": (
            "    #[test]\n    #[ignore]\n    fn generate_operation_expected() {\n"
            "    #[test]\n    #[ignore] // reason\n    fn regenerate_proof_golden() {\n"
            "    #[test]\n    fn generate_but_not_ignored() {\n"
            "    #[test]\n    #[ignore]\n    fn heavy_bench() {\n"
        ),
    }
    got = generator_names(src)
    check(got == {"generate_operation_expected", "regenerate_proof_golden"},
          f"an ignored test named for generating is a generator; a plain test or another ignored one is not: {sorted(got)}")
    log = (
        "test cross_language_test::tests::generate_operation_expected ... ok\n"
        "test painter::tests::regenerate_proof_golden ... FAILED\n"
        "test x::generate_other ... ignored\n"
    )
    check(ran_ok(log) == {"generate_operation_expected"}, f"only an `ok` line counts as run: {sorted(ran_ok(log))}")
    b = {"x.json": "h1", "y.json": "h2"}
    check(changed(b, dict(b)) == [], "no change, no finding")
    check(changed(b, {**b, "z.json": "h3"}) == ["z.json"], "a newly dirty file is a finding")
    check(changed(b, {"x.json": "h9", "y.json": "h2"}) == ["x.json"],
          "a file dirty before AND rewritten by a generator is a finding (its hash moved)")
    check(changed(b, {"x.json": "h1"}) == ["y.json"], "a file a generator restored or removed is a finding too")
    # The live source: the population is real, and holds the two generators rows 222/234 were about.
    live = generator_names({p.as_posix(): p.read_text(encoding="utf-8", errors="replace")
                            for p in (CRATE / "src").rglob("*.rs")})
    check(len(live) >= 15, f"live generators found: {len(live)} (a floor, never a target)")
    check({"generate_operation_expected", "generate_action_expected"} <= live,
          f"control: the live set holds the two generators rows 222 and 234 were about: {sorted(live)[:6]}...")
    arms = len(ran)
    for f in failures:
        print(f"  FAIL: {f}")
    print(f"check_generators_reproduce_goldens --self-test: {arms} arm(s), {len(failures)} failure(s), "
          f"{len(live)} live generators")
    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    names = generator_names({p.as_posix(): p.read_text(encoding="utf-8", errors="replace")
                             for p in (CRATE / "src").rglob("*.rs")})
    if not names:
        print("check_generators_reproduce_goldens: REFUSED: derived no generators from jas_dioxus/src", file=sys.stderr)
        return 2
    before = dirty_hashes()
    proc = subprocess.run(["cargo", "test", "--lib", "generate", "--", "--ignored"],
                          cwd=CRATE, capture_output=True, text=True, encoding="utf-8", errors="replace",
                          env=dict(os.environ))
    log = proc.stdout + proc.stderr
    after = dirty_hashes()
    ok = ran_ok(log)
    missing = sorted(names - ok)
    moved = changed(before, after)
    print(f"check_generators_reproduce_goldens: {len(names)} generator(s) derived from jas_dioxus/src; "
          f"{len(ok & names)} ran ok; cargo rc {proc.returncode}; {len(moved)} file(s) changed")
    for n in missing:
        print(f"  NOT RUN: {n} (a generator that did not run reproduces nothing)")
    for p in moved:
        print(f"  CHANGED: {p} -- its generator writes different bytes; regenerate, read the diff, commit")
    if proc.returncode != 0 or missing or moved:
        if proc.returncode != 0:
            print("\n".join(log.splitlines()[-20:]))
        print("check_generators_reproduce_goldens: FAIL")
        return 1
    print("check_generators_reproduce_goldens: OK -- every generator reproduces the committed bytes. "
          "NOT COVERED: goldens no generator writes; non-default feature sets.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
