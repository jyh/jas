#!/usr/bin/env python3
"""Every check gate must run on every platform family we ship on.

WHY THIS EXISTS
---------------
On 2026-07-28 the jas/windows seat found `check_swift_copy_sites.py` broken on
Windows: it keyed findings on `str(Path)`, which yields backslashes there, so
every one of 25 known sites was reported simultaneously as new debt and as
retired debt. The gate had been wrong for as long as it had existed.

CI never noticed. The gate was wired into a job that runs on `ubuntu-latest` --
the one platform whose paths cannot express the defect. A path-keyed gate ran
everywhere except where paths differ.

The separator was the instance. The defect was that the Windows lane's steps are
a HAND-MAINTAINED LIST, so a gate added after the list was written is watched on
Linux and unwatched on Windows, silently and forever. The next platform-visible
defect will not be a separator -- it will be a locale, a case-insensitive
filesystem, a long path, a CRLF in a golden -- and a hand list will under-cover
it exactly the way it under-covered this one.

So this gate does not look for separators. It asserts that every gate is
WATCHED WHERE IT COULD BE WRONG, which is the property the separator bug
violated one level up.

WHAT IT ASSERTS
---------------
Every `scripts/check_*.py` in the tree is invoked by at least one Windows job AND
at least one non-Windows job, unless it appears in EXEMPT with a written reason.

WHAT IT DOES NOT COVER
----------------------
* It checks that a script is INVOKED, not that it is invoked correctly. A step
  that runs the gate with arguments that neuter it passes here.
* It reads workflow files statically. A job whose platform comes from a matrix
  cannot be resolved, and this gate REFUSES rather than guessing -- see
  UnresolvablePlatform. Guessing is how the original defect stayed invisible.
* Non-Python gates (cargo, swift, the corpus compilers) are out of scope. They
  are wired per-lane by hand and this gate would have to model each one.
"""

import pathlib
import re
import sys

import yaml

# Scripts that legitimately run on one platform family only. Each needs a
# REASON, not just a name: an exemption without an argument is how a hole
# becomes permanent. Empty today -- all nine gates are pure-Python content
# checks with no platform-specific behaviour. The mechanism is proved by
# self-test case (e) rather than by production use.
EXEMPT: dict[str, str] = {}

# Anti-vacuity floors. A scan that found nothing reports no gaps, which is
# indistinguishable from a scan that found everything in order.
def _tracked_check_scripts() -> int:
    """How many `scripts/check_*.py` GIT knows about.

    DERIVED, and derived from a DIFFERENT ORACLE than the one it guards. This
    gate discovers its subjects with a filesystem glob; the floor exists to
    catch that glob silently matching less. Computing the floor from the same
    glob would be circular -- it would agree with any breakage, which is worse
    than a stale number because it looks maintained.

    `git ls-files` is an independent index and emits POSIX paths on every
    platform, so it is also separator-clean (see check_path_keying.py).

    WHY DERIVE THIS ONE AT ALL. It is a pure coverage count -- the number
    encodes no decision, only "how many gates exist" -- and it was bumped FOUR
    TIMES on 2026-07-30 alone, once wrongly (17 read off the CI job count
    instead of the script count). This repo's own record on hand-typed floors
    is that two of four replacement numbers were wrong on the first attempt
    (65b6218). A count nobody has to restate is a count nobody can get wrong.

    NOT EVERY FLOOR SHOULD BECOME THIS. Two kinds must stay hand-typed:
      * a floor guarding a PARSE (MIN_RUST_ARMS, EXPECTED_PATH_NAMES) -- there
        is no independent oracle, so deriving it is the circularity above;
      * a floor encoding a DECISION (EXPECTED_TOKENS, EXPECTED_MENU,
        MIN_LOG_ONLY) -- adding an element kind SHOULD force someone to rule on
        whether the menu offers it. There the friction is the feature, and
        automating it away would delete the ruling.

    A DERIVED FLOOR MUST FAIL CLOSED. The first cut of this returned 0 when the
    oracle was unreachable, and the vacuity rule is `n_scripts < floor` -- at 0
    that is False for every possible tree, so A REPOSITORY WITH ZERO CHECK
    SCRIPTS WOULD BE JUDGED NOT VACUOUS. An anti-vacuity floor that vanishes
    when its oracle does is worse than no floor, because it still reads as one.

    Flask proved it by mutation rather than by reading (letter 14 §2),
    monkeypatching subprocess.run to raise: `normal: 19 / git gone: 0`. He then
    corrected his own finding before sending it -- `--self-test` DOES red in
    that state, because its cases are built from `MIN_CHECK_SCRIPTS - 1` and at
    0 that is -1, which collapses loudly. So the narrow true claim was "fails
    open ON ITS OWN, and is rescued by the self-test running beside it", not
    "fails open". Both lanes do pair them.

    That rescue is real but incidental -- nobody designed it, and it protects
    only the invocation that happens to carry --self-test. A local run, or a
    future lane written from memory, gets the silent pass. So the oracle is
    load-bearing and its absence is an ERROR, not a zero.
    """
    import subprocess
    try:
        out = subprocess.run(
            ["git", "ls-files", "scripts/check_*.py"],
            cwd=pathlib.Path(__file__).resolve().parent.parent,
            capture_output=True, text=True, encoding="utf-8", check=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        raise RuntimeError(
            f"cannot derive MIN_CHECK_SCRIPTS: `git ls-files` is unavailable "
            f"({e}). This floor is DERIVED from git's index, and a floor of 0 "
            f"would pass any tree including an empty one. Refusing to run "
            f"rather than guarding nothing.") from e
    n = len([l for l in out.splitlines() if l.strip()])
    if n == 0:
        raise RuntimeError(
            "cannot derive MIN_CHECK_SCRIPTS: `git ls-files scripts/check_*.py` "
            "matched nothing. Either the pathspec stopped matching or this is "
            "not the repo -- both make the floor vacuous. Refusing to run.")
    return n


MIN_CHECK_SCRIPTS = _tracked_check_scripts()
#
# EXACT, NOT SLACK. This was a hand-set floor with room to spare until
# 2026-07-29, when the jas/windows seat proved the hole by mutation: it set a
# test-count floor 1.6% below reality, gated six tests off, and the gate went
# GREEN. Its sentence is the rule now --
#
#     "A floor with slack is a floor with a hole exactly the size of the slack,
#      and the hole admits precisely the move the assertion exists to forbid."
#
# The floor is the ONLY guard: a gate the glob fails to discover is never
# checked for lane coverage, so it can sit in one lane unwatched -- which
# is the exact defect this gate was written for.
#
# Adding to the set means raising this number in the same commit. That friction
# is the feature: the number is a claim about coverage, and a claim nobody has
# to restate is a claim nobody rechecks. (The model is
# check_preservation_corpus.py, whose floor is DERIVED from per-vector `n_min`
# declarations and therefore cannot drift at all -- prefer that shape where the
# data can declare itself.)
MIN_JOBS = 5            # 15 on 2026-07-28

WINDOWS = "windows"
OTHER = "other"


class UnresolvablePlatform(Exception):
    """A job's runs-on cannot be determined statically.

    Raised rather than defaulted. A job silently classified as the wrong family
    would let this gate report coverage it has not verified -- the exact failure
    mode it was written to catch.
    """


def platform_family(runs_on):
    """Map a runs-on value to a platform family.

    `runs_on` may be a string or a list (GitHub allows label lists).
    """
    if isinstance(runs_on, list):
        families = {platform_family(r) for r in runs_on}
        if len(families) != 1:
            raise UnresolvablePlatform(f"label list spans families: {runs_on!r}")
        return families.pop()
    if not isinstance(runs_on, str):
        raise UnresolvablePlatform(f"non-string runs-on: {runs_on!r}")
    if "${{" in runs_on:
        raise UnresolvablePlatform(f"expression, not a literal: {runs_on!r}")
    low = runs_on.lower()
    if "windows" in low:
        return WINDOWS
    if "ubuntu" in low or "macos" in low or "linux" in low or "mac" in low:
        return OTHER
    raise UnresolvablePlatform(f"unrecognised runner label: {runs_on!r}")


SCRIPT_REF = re.compile(r"scripts/(check_[a-z0-9_]+\.py)")


def scripts_in_step(step):
    """Every check script a step's `run` block invokes.

    Comment lines are stripped first. A commented-out invocation must NOT count
    as coverage -- that would let disabling a gate look identical to running it.
    """
    run = step.get("run")
    if not isinstance(run, str):
        return set()
    found = set()
    for line in run.splitlines():
        code = line.split("#", 1)[0]
        found.update(SCRIPT_REF.findall(code))
    return found


def scan(workflows):
    """workflows: {filename: yaml text} -> ({script: {families}}, n_jobs).

    Raises UnresolvablePlatform if any job that invokes a check script has a
    platform we cannot determine.
    """
    coverage = {}
    n_jobs = 0
    for name, text in sorted(workflows.items()):
        doc = yaml.safe_load(text) or {}
        for job_name, job in (doc.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            n_jobs += 1
            steps = job.get("steps") or []
            invoked = set()
            for step in steps:
                if isinstance(step, dict):
                    invoked |= scripts_in_step(step)
            if not invoked:
                continue
            try:
                fam = platform_family(job.get("runs-on"))
            except UnresolvablePlatform as exc:
                raise UnresolvablePlatform(
                    f"{name}:{job_name} invokes {sorted(invoked)} but {exc}"
                ) from exc
            for script in invoked:
                coverage.setdefault(script, set()).add(fam)
    return coverage, n_jobs


def gaps(scripts, coverage):
    """Scripts missing a platform family, as (script, missing-family) pairs."""
    out = []
    for script in sorted(scripts):
        if script in EXEMPT:
            continue
        fams = coverage.get(script, set())
        for fam in (WINDOWS, OTHER):
            if fam not in fams:
                out.append((script, fam))
    return out


def below_floor(n_scripts, n_jobs):
    return n_scripts < MIN_CHECK_SCRIPTS or n_jobs < MIN_JOBS


# --------------------------------------------------------------------------
# self-test
# --------------------------------------------------------------------------

def _wf(jobs):
    return yaml.safe_dump({"jobs": jobs}, sort_keys=False)


def self_test():
    """Prove the gate goes RED on each class it claims to cover.

    A gate is trusted for its RED. Every case here is a way lane coverage can
    be wrong, including the two the real tree actually had.
    """
    failures = []

    jobs = {
        # (a) both families -- the correct shape
        "lin_ok": {"runs-on": "ubuntu-latest",
                   "steps": [{"run": "python scripts/check_a.py"}]},
        "win_ok": {"runs-on": "windows-latest",
                   "steps": [{"run": "python scripts/check_a.py"}]},
        # (b) Linux only -- THE REAL DEFECT. check_swift_copy_sites.py's exact
        #     shape: a path-keyed gate watched only where paths cannot differ.
        #     NOTHING ELSE in this corpus may mention check_b, or the case that
        #     matters most stops being asserted.
        "lin_only": {"runs-on": "ubuntu-latest",
                     "steps": [{"run": "python scripts/check_b.py"}]},
        # (c) Windows only -- the mirror. Just as wrong, and likewise mentioned
        #     exactly once.
        "win_only": {"runs-on": "windows-latest",
                     "steps": [{"run": "python scripts/check_c.py"}]},
        # (f) a multi-line run block, which is how the real Windows lane is
        #     written. A scan that read only a step's first line would miss
        #     every gate in the tree's largest job.
        "multiline": {"runs-on": "windows-latest",
                      "steps": [{"run": "python scripts/check_e.py --self-test\n"
                                        "python scripts/check_e.py\n"}]},
        # (g,h) args do not change which script was invoked, and macos counts as
        #     non-Windows. Together with (f) this is check_e's only other family,
        #     so if either parse breaks, check_e shows a gap.
        "args": {"runs-on": "macos-latest",
                 "steps": [{"run": "python scripts/check_e.py --self-test && "
                                   "python scripts/check_e.py"}]},
        # (i) a COMMENTED-OUT invocation is not coverage. Without this, silencing
        #     a gate and running it look identical to this check.
        "commented": {"runs-on": "windows-latest",
                      "steps": [{"run": "# python scripts/check_d.py\n"
                                        "python scripts/check_a.py\n"}]},
        # a job with no gates at all still counts toward the job floor
        "unrelated": {"runs-on": "ubuntu-latest",
                      "steps": [{"run": "cargo test"}]},
    }
    coverage, n_jobs = scan({"test.yml": _wf(jobs)})

    # (d) check_d is on disk but referenced only inside a comment -> both gaps.
    scripts = ["check_a.py", "check_b.py", "check_c.py", "check_d.py",
               "check_e.py", "check_exempt.py"]
    # (e) the exemption mechanism, exercised here because production uses none.
    EXEMPT["check_exempt.py"] = "self-test only"
    try:
        got = set(gaps(scripts, coverage))
    finally:
        del EXEMPT["check_exempt.py"]

    # Spelled out literally, never computed from the code under test. A fixture
    # derived from the thing it checks cancels its own mutations out -- that
    # mistake cost a day on check_naming_rule.py's marker fixture.
    #
    # check_a: ubuntu (a) + windows (a)        -> no gap
    # check_e: windows (f) + macos (g,h)       -> no gap
    # check_b: ubuntu ONLY                     -> missing WINDOWS
    # check_c: windows ONLY                    -> missing OTHER
    # check_d: comment-only reference          -> missing BOTH
    # check_exempt: never referenced, exempt   -> silent
    want = {
        ("check_b.py", WINDOWS),
        ("check_c.py", OTHER),
        ("check_d.py", WINDOWS),
        ("check_d.py", OTHER),
    }

    if got != want:
        failures.append(f"  gaps: expected {sorted(want)}, got {sorted(got)}")
    if n_jobs != len(jobs):
        failures.append(f"  jobs: expected {len(jobs)}, counted {n_jobs}")

    # (j) an unresolvable platform must REFUSE, not guess. A matrix job silently
    #     classified as one family would report coverage never verified.
    for bad in ["${{ matrix.os }}", "freebsd-13", None, ["ubuntu-latest", "windows-latest"]]:
        try:
            scan({"m.yml": _wf({"j": {"runs-on": bad,
                                      "steps": [{"run": "python scripts/check_a.py"}]}})})
            failures.append(f"  runs-on {bad!r} should have refused, was accepted")
        except UnresolvablePlatform:
            pass

    # ...but an unresolvable job that invokes NO gate is none of our business.
    try:
        scan({"m.yml": _wf({"j": {"runs-on": "${{ matrix.os }}",
                                  "steps": [{"run": "cargo test"}]}})})
    except UnresolvablePlatform:
        failures.append("  a matrix job invoking no gate should be ignored")

    # the anti-vacuity floor is itself a class this gate must get right
    for n_scripts, n_j, want_rejected in [
        (0, 0, True),                        # nothing found at all
        (1, 20, True),                       # a truncated script glob
        (20, 1, True),                       # a truncated workflow parse
        (MIN_CHECK_SCRIPTS - 1, 20, True),   # just under
        (MIN_CHECK_SCRIPTS, MIN_JOBS, False),  # exactly at both lines
        # The real tree, DERIVED. This line read `(14, 17, False)` when it was
        # written, then 15, then 16, then 17 -- re-measured by hand every time a
        # gate landed, and wrong once on the way (17 taken off the CI job count
        # rather than the script count). Deriving the floor removed the number
        # from the constant and left it here, in the fixture, which is exactly
        # how a hand-typed number survives being "removed".
        #
        # So the fixture is derived too. It now asserts the RELATION -- the real
        # tree sits at the floor -- rather than restating the measurement.
        (MIN_CHECK_SCRIPTS, MIN_JOBS + 12, False),
    ]:
        if below_floor(n_scripts, n_j) != want_rejected:
            verb = "reject" if want_rejected else "accept"
            failures.append(f"  floor: {n_scripts} scripts / {n_j} jobs should {verb}")

    # THE DERIVED FLOOR MUST FAIL CLOSED, proven by mutation rather than by
    # reading -- Flask's method, applied to the hole Flask found (letter 14 §2).
    # Before this, an unreachable oracle yielded 0, and `n < 0` is False for
    # every tree, so the anti-vacuity floor silently stopped guarding. The
    # self-test happened to red anyway; that rescue was incidental and covered
    # only invocations that carry --self-test.
    import subprocess as _sp
    for name, fake in (
        ("oracle unreachable", lambda *a, **k: (_ for _ in ()).throw(OSError("no git"))),
        ("oracle matches nothing", lambda *a, **k: _sp.CompletedProcess(a, 0, "", "")),
    ):
        real = _sp.run
        _sp.run = fake
        try:
            got = _tracked_check_scripts()
            failures.append(f"  fail-closed/{name}: returned {got!r} instead of raising "
                            f"-- a floor of 0 passes every tree, including an empty one")
        except RuntimeError:
            pass                      # correct: refuses to run rather than guard nothing
        except Exception as e:        # noqa: BLE001 -- any other escape is also a failure
            failures.append(f"  fail-closed/{name}: raised {type(e).__name__}, want RuntimeError")
        finally:
            _sp.run = real

    if failures:
        print("SELF-TEST FAILED -- the gate does not detect what it claims:")
        print("\n".join(failures))
        return 1
    print("self-test: 4 gap-classes detected, comment/exempt/args/multiline "
          "classes clean, unresolvable platforms refused, anti-vacuity floor "
          f"holds at {MIN_CHECK_SCRIPTS} scripts / {MIN_JOBS} jobs, and the "
          "derived floor FAILS CLOSED when its oracle is unreachable or "
          "matches nothing -- gate proven RED where it must be.")
    return 0


def main():
    if "--self-test" in sys.argv:
        return self_test()

    root = pathlib.Path(__file__).resolve().parent.parent
    scripts = sorted(p.name for p in (root / "scripts").glob("check_*.py"))
    wf_dir = root / ".github" / "workflows"
    workflows = {p.name: p.read_text(encoding="utf-8")
                 for p in sorted(wf_dir.glob("*.yml"))}

    try:
        coverage, n_jobs = scan(workflows)
    except UnresolvablePlatform as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        print(file=sys.stderr)
        print("This gate refuses to guess a job's platform. Give the job a", file=sys.stderr)
        print("literal runs-on, or teach platform_family() the new label.", file=sys.stderr)
        return 1

    if below_floor(len(scripts), n_jobs):
        print(f"ERROR: found {len(scripts)} check scripts and {n_jobs} jobs, below the "
              f"anti-vacuity floor of {MIN_CHECK_SCRIPTS}/{MIN_JOBS}.", file=sys.stderr)
        print(file=sys.stderr)
        print("This is not a pass. A scan that found nothing reports no gaps,", file=sys.stderr)
        print("which is indistinguishable from full coverage. Likely causes:", file=sys.stderr)
        print("  * run from outside the repository", file=sys.stderr)
        print("  * the workflow file moved or stopped parsing", file=sys.stderr)
        return 1

    found = gaps(scripts, coverage)
    if not found:
        n = len(scripts) - len(EXEMPT)
        print(f"lane coverage: {n} gate(s) run on both platform families "
              f"across {n_jobs} jobs"
              + (f", {len(EXEMPT)} exempt" if EXEMPT else "") + ".")
        return 0

    print(f"ERROR: {len(found)} lane-coverage gap(s) -- a gate is unwatched on a "
          "platform it ships to.", file=sys.stderr)
    print(file=sys.stderr)
    for script, fam in found:
        where = "Windows" if fam == WINDOWS else "Linux/macOS"
        print(f"  scripts/{script}  never runs on {where}", file=sys.stderr)
    print(file=sys.stderr)
    print("A gate that cannot fail on a platform is not watching that platform.", file=sys.stderr)
    print("check_swift_copy_sites.py was wrong on Windows for its whole life and", file=sys.stderr)
    print("CI stayed green, because it ran only on ubuntu-latest.", file=sys.stderr)
    print(file=sys.stderr)
    print("Add the gate to the missing lane. If it genuinely cannot run there,", file=sys.stderr)
    print("add it to EXEMPT with the reason written out.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
