#!/usr/bin/env python3
"""A checker lane that inspects nothing looks exactly like a clean tree.

WHY THIS EXISTS
---------------
The checker tier's stopping value is TOTALITY. A gate that silently adjudicates
zero cases is the one failure mode that resembles success, and this repository
has been bitten by it: a container-seeding pass once seeded ZERO cases, and only
an anti-vacuity floor caught it. So the checkers arrive with their own
accounting, and this file is that accounting.

FIVE RULES, in the order they must hold.

R1  REGISTRY TOTALITY, BOTH DIRECTIONS. Every corpus family either NAMES a
    checker or carries `"checker": null` with a `checker_gap` reason; a family
    in neither state fails. And a gap row whose family now names a checker is
    STALE and must be deleted. One direction only is how `swift:dropdown`
    asserted a missing feature for months after JasSwift shipped it -- the
    defect behind check_gate_consistency.py.

R2  FLOORS ARE DECLARED IN THE FIXTURE, AND THE RUNNER ASSERTS WHAT IT RAN.
    Every registered family's fixture states min_rulable_vectors,
    min_checks_per_lane and min_discriminating about ITSELF, and every reader
    takes the number from there. A floor hardcoded in a runner is a defect in
    its own right: `test_fixtures/properties`' witness floors live as
    `discriminating >= 2` inside the Rust runner and are hand-mirrored in
    Swift, and a mirrored number drifts. A floor of zero is not a floor, and a
    floor of one is barely one.

R3  TEETH. A checker that has never been seen red is not an instrument. Each
    registered family carries EITHER a mutant with a NAMED PRIOR BUG as its
    provenance, or -- where no such bug exists -- a red self-test case. A
    mutant an author invented is a self-graded exam: they will invent one their
    checker catches, and min_discriminating reads healthy forever. Provenance
    is therefore required at registration, not encouraged.

R4  PER-FAMILY VACUITY. lane_report exits 3 when the WHOLE RUN checked nothing;
    one family going empty is below its resolution. The runner fails a
    registered family that ruled nothing, and this gate refuses a report in
    which one did.

R5  EXECUTED-COUNT RECONCILIATION. R1-R4 are total over the REGISTRY and over
    the FIXTURES. They are not total over the RUNNERS, and the runner is where
    the vacuity lives. So the runner writes down the counts it ACTUALLY
    PERFORMED, per lane, and `--reconcile` asserts they are non-zero, that
    EVERY REQUESTED LANE IS AMONG THEM, that the lanes agree, and that each
    meets the declared floor. The requested-lane clause is load-bearing and
    was missing: a lane that rules zero is not present with a zero, it is
    ABSENT, so every rule phrased over the lanes present steps around it. The
    old code demanded two lanes only at seam 2 -- leaving SEAM 1, the seam the
    doctrine says to prefer and the seam every checker rides, unguarded. One
    SKIP_LANG_ALGO line emptied the Swift arm and this printed OK.

R6  THE REPORT MUST BE EVIDENCE. `--reconcile` reads a file, and a file is not
    a run. A report is refused unless it carries a run id and digests of the
    fixtures it ruled over and of the `spec/` tier it ruled with, both
    recomputed here; and the report must not be tracked by git, because a
    committed one is present in a checkout where nothing executed. The
    success line therefore reports the lanes that RULED, never the lanes that
    were requested -- a summary that prints its inputs cannot report a
    failure, and this one printed "across lanes rust, swift" on a run where
    Swift ruled nothing.

R7  THE WITNESS SET DECLARES WHAT IT SEPARATES, not only how big it is.
    R2's floors count; counting measures POPULATION, and a corpus can meet
    every count while being COLLINEAR. gradient_remap shipped nine vectors and
    585 green sample comparisons in which all EIGHTEEN bounding boxes were
    degenerate -- one side exactly zero -- so `half_diag = hypot(w,h)/2`, the
    clause spec/geometry/linear_gradient.py singles out as "not half the
    width", was exercised by nothing, and replacing it with max(w,h)/2 left
    oracle, checker and board green. A tenth degenerate vector would have
    raised both floors and changed nothing. So a law publishes probes
    (CHECKER_WITNESS_PROBES) and its fixture declares how many vectors must
    satisfy each. This is a REGRESSION floor: it keeps a noticed clause
    exercised and cannot say which clause to notice next. See docs/CHECKERS.md
    section 8 for why the total instrument is a mutant per clause of `spec/`,
    and why that is a strictly larger job than this file does.

R8  THE GATE MODELS EXECUTION, AND ITERATES THE OBLIGATION. R5-R7 rule over a
    report some run produced; this one rules over the WORKFLOW, and it is the
    same defect as D1 one level up. D1 moved the wiring check from "the flag
    appears as text anywhere in the file" to "the flag appears in a `run:` body
    in the parse tree" -- closer to execution, still not execution, because the
    rule stayed phrased over the EVIDENCE. `check_ci_wiring` iterates
    `set(writers) | set(readers)`, so A JOB CARRYING NEITHER FLAG IS INVISIBLE:
    deleting the writer and the reconcile line from the WINDOWS job -- seven
    lines -- left this gate, its `--self-test`, and check_lane_coverage.py ALL
    GREEN while the seat that most needs the guarantee stopped adjudicating
    anything. And `executed_run_commands`, whose docstring claims "every
    command line CI ACTUALLY EXECUTES", reads only `step["run"]`: it consults
    neither `continue-on-error`, nor step- or job-level `if:`, nor `needs:`,
    nor a shell short-circuit inside the block.

    A RULE PHRASED OVER WHAT IT FINDS CANNOT NOTICE AN ABSENCE. So the lanes
    that must be adjudicated -- a lane being a (platform, language) pair -- are
    DECLARED AS DATA in scripts/checker_lane_registry.json with a reason per
    row, and this gate ITERATES THE OBLIGATION, not the evidence. For each
    declared lane it proves that CI actually adjudicates it: a job on that
    platform runs the checker for that language; the writer and reader pair
    inside it at one path (D1's rule, kept, now per lane); no
    `continue-on-error` on the job or on either step; no `if:` on the job or on
    either step unless the row declares the exact condition and argues for it;
    a `needs:` chain that is satisfiable, since a job whose dependency is
    skipped never runs; and no shell short-circuit discarding either exit
    status. Presence was a proxy for execution. Proxies are the thing this
    programme exists to delete, and this is the third guard in the phase that
    was one abstraction short of what it guarded.

A6  THE EFFECTIVE SHELL, AND IT IS THE FOURTH TIME IN ONE PHASE. Every rule
    above that reads an exit status stood on one sentence, asserted in
    status_discarded()'s own docstring as measured fact: "GitHub runs a `run:`
    body as `bash -e {0}`, so a failing simple command aborts the step." ON
    `windows-latest` THAT IS FALSE BY DEFAULT. The default shell there is
    `pwsh`, whose wrapper appends `exit $LASTEXITCODE` rather than aborting, so
    a failing `python scripts/...` on a NON-FINAL line does not stop the step
    and the step's status is the LAST line's. Every `python A` / `python B`
    pair in the Windows job would report only B.

    What made the model true was a single `defaults: run: shell: bash` block
    eight lines below `runs-on` -- WHICH NO GATE IN THIS REPOSITORY READ.
    Deleting it as an ordinary tidy would have turned the Windows lane's
    failures into passes with nothing anywhere noticing.

    So the shell is RESOLVED, in GitHub's precedence -- the step's `shell:`,
    then the job's `defaults.run.shell`, then the workflow's, then the platform
    default (`pwsh` on windows, `bash` elsewhere) -- and a shell whose failure
    semantics are not modelled is REFUSED, never assumed to be bash. Fail
    closed, exactly as the PyYAML handling does: a model that guesses its own
    floor reports adjudication nobody verified.

    THE SHAPE, FOUR TIMES, AND IT IS THE FINDING RATHER THAN THE FIX:

        original  the flag appears AS TEXT           a YAML comment satisfied it
        D1        the flag appears in a `run:` BODY  steps that never execute
        R5/R8     the step EXECUTES                  lanes with no job at all
        A6        it executes UNDER `bash -e`        the shell is set elsewhere

    Each fix was correct and each was one abstraction short. A GUARD THAT
    MODELS ITS SUBJECT INHERITS EVERY ASSUMPTION THE MODEL MAKES, and those
    assumptions are invisible precisely because they are the model's floor. The
    countermeasure is not a fifth iteration; it is the assumption DECLARED and
    machine-checked. See transcripts/CHECKER_RESIDUAL.md, whose `expires-when`
    markers red through check_deferral_expiry.py if the premise moves, and
    docs/CHECKERS.md section 8.

THE TCB SCAN. `spec/` is the analytic tier the checkers rule with. Its value
rests entirely on importing nothing from this repository -- a Python module
that reached into a port would be a fourth implementation with a nicer name. A
trusted computing base whose boundary is a comment is not one, so the boundary
is scanned here. Findings are keyed on `git ls-files` output, which is POSIX on
every platform: keying on `str(Path)` is LITERALLY the defect the jas/windows
seat found in check_swift_copy_sites.py on 2026-07-28, where 25 known sites
reported simultaneously as new debt and as retired debt.

WHAT THIS GATE DOES NOT COVER
-----------------------------
* It reads REGISTRATIONS and COUNTS, never verdicts. A law that runs on every
  vector and is too weak to reject anything passes here; that is what R3's
  mutant is for, and the mutant is measured by the runner, not by this file.
* R1's reverse direction is mechanised at ALGORITHM granularity only (see
  CHECKER_PROBES in cross_language_algorithms.py, which asks whether a gap
  family's fixture now carries the shape a registered law consumes). For the
  heterogeneous corpus families there is no generic probe for "this now has
  geometry", and inventing one would be guessing. The manifest's
  bidirectionality there is the weaker "a gap row that also names a checker".
* It cannot see a checker deleted along with its registry row and its fixture
  block, in one commit, by someone who meant it. R8's lane registry has the
  same limit by construction and says so in its own `_doc`: deleting a row and
  lowering the floor is a legal edit, and the sentence in the commit message is
  the whole mechanism.
* R8 DOES NOT INTERPRET THE SHELL. It rejects the cheap ways a matched command
  line's exit status stops mattering -- an `||` fallback, an `&&` chain that
  swallows it under `bash -e`, a leading `if`/`while`/`until`/`!` -- and it
  cannot see a status discarded three lines away by a trap, a subshell, or a
  variable. A gate that claimed to model bash would be a fourth shell with a
  nicer name; this one models the decay forms that have a name.
* A6 RESOLVES THE SHELL FROM THE WORKFLOW FILE, WHICH IS NOT THE RUNNER. It
  reads the four places GitHub takes it from and refuses anything outside
  SHELL_ABORTS_ON_FAILURE -- so it cannot be fooled by `defaults.run.shell`
  moving, and it CAN be wrong about anything the workflow does not say: a
  self-hosted runner whose labels this gate resolves to a family with a
  different default, a `pwsh`/`bash` wrapper GitHub changes underneath the
  literal, an `ACTIONS_*` runner setting, a composite action's own default. It
  models GitHub Actions semantics FROM THE FILE and sees no runner behaviour it
  does not model. That residual is DECLARED rather than iterated on: the
  `expires-when` markers in transcripts/CHECKER_RESIDUAL.md name the premise
  and check_deferral_expiry.py reds when it moves.
* R8 reads `runs-on` literally. A matrix job is UNRESOLVABLE and is refused
  rather than guessed at, the same choice check_lane_coverage.py makes for the
  same reason: a job silently classified as the wrong platform would report
  adjudication it has not verified.

Usage:
    python3 scripts/check_geometry_checkers.py
    python3 scripts/check_geometry_checkers.py --self-test
    python3 scripts/check_geometry_checkers.py --reconcile <report.json>
"""

import ast
import copy
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile

try:
    import yaml as _yaml
except ImportError:  # the workflow cannot be PARSED without it
    _yaml = None

_HERE = os.path.dirname(os.path.abspath(__file__))
REPO = pathlib.Path(_HERE).parent
# os.path, not str(Path): `str(Path)` yields backslashes on Windows, and a gate
# that keys findings on one reported 25 known sites as new debt AND as retired
# debt for its whole life (check_path_keying.py).
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.dirname(_HERE))

import cross_language_algorithms as cla  # noqa: E402

MANIFEST = REPO / "scripts" / "corpus_manifest.json"
WORKFLOW = REPO / ".github" / "workflows" / "test.yml"
LANE_REGISTRY = REPO / "scripts" / "checker_lane_registry.json"

# The tier whose whole value is importing nothing from this repository.
TCB_ROOT = "spec"

# Top-level module names anything under spec/ may import. Standard library
# only, plus spec itself. Deliberately an ALLOW list: a deny list of "the
# repo's modules" grows a hole every time a package is added.
TCB_ALLOWED_IMPORTS = {
    "spec", "math", "json", "itertools", "functools", "dataclasses", "typing",
    "collections", "fractions", "decimal", "cmath", "bisect", "copy", "enum",
    "abc", "numbers", "operator", "random", "statistics", "sys", "re",
}

# The report `--reconcile` reads. Named here because two separate rules turn
# on it: CI must pass it to both halves of the wiring, and the repository must
# IGNORE it (R6) -- a committed report reconciles as cleanly as a fresh one.
REPORT_FLAG = "--checker-report"
RECONCILE_FLAG = "--reconcile"
REPORT_FILENAME = "checker-report.json"

# The CI steps that must exist, and why each is load-bearing. check_lane_coverage
# already asserts this FILE runs on both platform families -- it globs
# `scripts/check_*.py`, which is exactly why the gate is named this way and why
# the runner is NOT a new `scripts/run_*.py` (it would be name-invisible).
REQUIRED_WIRING = {
    REPORT_FLAG: "the runner must write its executed-count account "
                 "somewhere, or R5 has nothing to reconcile",
    RECONCILE_FLAG: "the account must be READ, or the counts are printed to a "
                    "log where nothing asserts on them -- which is the state "
                    "shift_constrain's `committed` number is in today",
}

# R8. The two programs a lane's adjudication is made of, and the flag that says
# WHICH lanes a writer requests. Matched as substrings of a `run:` line, which
# is how every other rule here matches -- the point of R8 is not a better
# tokeniser, it is that the iteration runs over the declared lanes below.
LANG_FLAG = "--lang"
WRITER_SCRIPT = "scripts/cross_language_algorithms.py"
READER_SCRIPT = "scripts/check_geometry_checkers.py"

# Runner labels this gate can resolve to a platform. Unknown labels RAISE (see
# UnresolvableLane) rather than defaulting: check_lane_coverage.py made the same
# choice, and for the same reason -- a job classified as the wrong platform
# would report adjudication nobody verified.
RUNNER_PLATFORMS = (
    ("windows", "windows"),
    ("macos", "macos"), ("mac", "macos"),
    ("ubuntu", "linux"), ("linux", "linux"),
)
PLATFORMS = {family for _label, family in RUNNER_PLATFORMS}

# A6. THE SHELLS WHOSE FAILURE SEMANTICS THIS GATE MODELS, and the wrapper each
# claim rests on. Every rule that reads an exit status assumes "a failing simple
# command aborts the step", and THAT IS A PROPERTY OF THE SHELL, not of the
# workflow. An ALLOW list for the same reason TCB_ALLOWED_IMPORTS is one: a deny
# list of shells that misbehave grows a hole every time GitHub adds a keyword.
#
# Only the bare keywords. A custom `shell:` template -- even one beginning
# `bash`, e.g. `bash {0}` without `-e`, or `bash --noprofile {0}` -- is NOT
# here: it is the caller's own invocation line, and reading `bash` off its front
# would be assuming flags nobody wrote.
SHELL_ABORTS_ON_FAILURE = {
    "bash": "GitHub runs it as `bash --noprofile --norc -eo pipefail {0}`",
    "sh": "GitHub runs it as `sh -e {0}`",
}

# The shells MEASURED not to abort. Held apart from the merely-unknown case so
# the red can say WHICH one and WHY, rather than sending the reader to look up
# a shell this file has already looked up. `pwsh` is the one that matters: it is
# `windows-latest`'s default, and it is what this whole clause is about.
_NO_ABORT = ("its wrapper APPENDS `exit $LASTEXITCODE` rather than aborting, "
             "so a failing command on a non-final line does not stop the step "
             "and the step's status is the LAST line's -- a `python A` / "
             "`python B` pair in one body reports only B")
SHELL_DOES_NOT_ABORT = {"pwsh": _NO_ABORT, "powershell": _NO_ABORT}

# GitHub's default when NOTHING declares a shell -- the fact the gate did not
# know. Total over PLATFORMS, and the self-test proves it: adding a runner
# family without stating its default shell would silently make every step on
# that platform unresolvable, which reds, but reds for the wrong reason.
PLATFORM_DEFAULT_SHELL = {
    "windows": "pwsh",
    "macos": "bash",
    "linux": "bash",
}

# EXACT, NOT SLACK -- the tree's own rule, proved by the jas/windows seat on
# 2026-07-29 by setting a floor 1.6% below reality, gating six tests off, and
# watching the gate go green: "a floor with slack is a floor with a hole exactly
# the size of the slack, and the hole admits precisely the move the assertion
# exists to forbid."
#
# NOT DERIVED, unlike check_lane_coverage.py's MIN_CHECK_SCRIPTS. That one is a
# pure coverage count with an independent oracle (git's index). This one encodes
# a DECISION -- which platforms referee the geometry checkers -- and deriving it
# from the registry would make it agree with any deletion, which is worse than a
# stale number because it looks maintained. Dropping a lane SHOULD cost an edit
# here and a sentence in the commit message.
MIN_DECLARED_LANES = 3          # windows:rust, macos:rust, macos:swift


def _git_tracked(pathspec):
    """git-tracked paths matching `pathspec`, as POSIX strings.

    An independent oracle from the filesystem walk, and separator-clean on
    every platform. Its absence is an ERROR, never an empty list: a scan whose
    subject list silently empties reports no findings, which is the vacuity
    this whole file exists to refuse.
    """
    try:
        out = subprocess.run(["git", "ls-files", pathspec], cwd=REPO,
                             capture_output=True, text=True,
                             check=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        raise RuntimeError(
            f"cannot enumerate `{pathspec}`: git ls-files is unavailable "
            f"({e}). Refusing to scan nothing and call it clean.") from e
    return [line.strip() for line in out.splitlines() if line.strip()]


def _git_tracks(path):
    """True if `path` is under version control. False for a path git cannot
    even name (outside the repo), which is the ordinary case for a report
    written to a temp directory."""
    try:
        rel = os.path.relpath(os.path.abspath(path), REPO)
    except ValueError:
        return False  # a different drive on Windows
    if rel.startswith(os.pardir):
        return False
    try:
        out = subprocess.run(["git", "ls-files", "--", rel], cwd=REPO,
                             capture_output=True, text=True,
                             check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return False
    return bool(out.strip())


# ---------------------------------------------------------------------------
# The rules
# ---------------------------------------------------------------------------

def import_leaks(rel, src):
    """Non-stdlib imports in one `spec/` module. Pure, so the self-test can
    prove the red on synthetic source rather than by writing into the tree."""
    errors = []
    for node in ast.walk(ast.parse(src, filename=rel)):
        if isinstance(node, ast.Import):
            names = [a.name.split(".")[0] for a in node.names]
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                continue  # a relative import stays inside spec/
            names = [(node.module or "").split(".")[0]]
        else:
            continue
        for name in names:
            if name not in TCB_ALLOWED_IMPORTS:
                errors.append(
                    f"tcb: {rel} imports `{name}`, which is not standard "
                    f"library. The analytic tier must import nothing from "
                    f"this repository -- an instrument that reaches into an "
                    f"implementation cannot adjudicate it. If `{name}` really "
                    f"is stdlib, add it to TCB_ALLOWED_IMPORTS with that "
                    f"argument.")
    return errors


def check_tcb_isolation(tracked=None):
    """`spec/` imports the standard library and nothing else."""
    errors = []
    files = _git_tracked(f"{TCB_ROOT}/*.py") if tracked is None else tracked
    if not files:
        errors.append(
            f"tcb: git tracks no {TCB_ROOT}/*.py -- the analytic tier the "
            f"checkers rule with has vanished, or was never committed")
        return errors
    for rel in files:
        path = os.path.join(os.path.dirname(_HERE), *rel.split("/"))
        try:
            with open(path, encoding="utf-8") as fh:
                src = fh.read()
        except OSError as e:
            errors.append(f"tcb: {rel} unreadable: {e}")
            continue
        errors.extend(import_leaks(rel, src))
    return errors


def check_manifest_registry(manifest):
    """R1: every family classified, and no stale gap row."""
    errors = []
    families = manifest.get("families", {})
    if not families:
        errors.append("registry: the manifest lists no families at all")
    for name in sorted(families):
        row = families[name]
        if "checker" not in row:
            errors.append(
                f"registry: {name} carries no `checker` key. Name a checker, "
                f"or set it to null with a `checker_gap` reason. Silence is "
                f"how a family goes unwatched by being forgotten rather than "
                f"by being excused.")
            continue
        checker, gap = row["checker"], row.get("checker_gap")
        if checker is None:
            if not (isinstance(gap, str) and gap.strip()):
                errors.append(
                    f"registry: {name} has no checker and no `checker_gap` "
                    f"reason -- an exemption without an argument is how a "
                    f"hole becomes permanent")
            continue
        if not (isinstance(checker, str) and checker.strip()):
            errors.append(f"registry: {name}'s `checker` is {checker!r}")
        if gap is not None:
            # The reverse direction. A row that both names a checker and
            # excuses itself is STALE: the hole it claims has closed.
            errors.append(
                f"registry: {name} names a checker AND carries a stale "
                f"`checker_gap` ('{str(gap)[:60]}...'): delete the gap row, "
                f"the hole it asserts has closed")
    return errors


def check_algorithm_registry():
    """R1 at algorithm granularity, over the runner's own registry."""
    errors = []
    named = set(cla.GEOMETRY_CHECKERS)
    excused = set(cla.GEOMETRY_CHECKER_GAPS)
    algos = set(cla.ALGORITHMS)
    for algo in sorted(algos - named - excused):
        errors.append(
            f"registry: algorithm `{algo}` is neither registered in "
            f"GEOMETRY_CHECKERS nor excused in GEOMETRY_CHECKER_GAPS")
    for algo in sorted(named & excused):
        errors.append(
            f"registry: algorithm `{algo}` is both registered and excused")
    for algo in sorted((named | excused) - algos):
        errors.append(
            f"registry: `{algo}` is classified but is not a registered "
            f"algorithm -- a stale row naming a family that no longer exists")
    for algo, law in sorted(cla.GEOMETRY_CHECKERS.items()):
        if law not in cla.CHECKER_FUNCS:
            errors.append(f"registry: {algo} names checker `{law}`, which "
                          f"does not exist")
        if law not in cla.CHECKER_PROBES:
            errors.append(
                f"registry: checker `{law}` declares no probe in "
                f"CHECKER_PROBES, so no gap row can ever be found stale "
                f"against it -- the reverse direction would be dead")
    for reason in cla.GEOMETRY_CHECKER_GAPS.values():
        if not reason.strip():
            errors.append("registry: an empty GEOMETRY_CHECKER_GAPS reason")
    return errors


def check_declared_floors():
    """R2/R3: the fixture declares its own floors, and its mutant its bug."""
    errors = []
    for algo, law in sorted(cla.GEOMETRY_CHECKERS.items()):
        path = REPO / "test_fixtures" / "algorithms" / f"{algo}.json"
        if not path.exists():
            errors.append(f"floors: {algo}.json is missing entirely")
            continue
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        cfg, why = cla._checker_config(algo, doc if isinstance(doc, dict)
                                       else {})
        if cfg is None:
            errors.append(f"floors: {why}")
            continue
        if cfg["name"] != law:
            errors.append(f"floors: {algo}.json names checker "
                          f"'{cfg['name']}', the registry names '{law}'")
        if cfg["seam"] not in (1, 2):
            errors.append(
                f"floors: {algo}.json declares seam={cfg['seam']!r}; classify "
                f"it 1 (an out-of-process wire, one predicate for both ports) "
                f"or 2 (in-process, mirrored per port and ~6.7x the cost)")
        n = len([v for v in doc.get("vectors", [])
                 if isinstance(v, dict) and not v.get("_skip")])
        if cfg["min_rulable_vectors"] > n:
            errors.append(
                f"floors: {algo}.json declares min_rulable_vectors="
                f"{cfg['min_rulable_vectors']} but holds only {n} vector(s)")
    return errors


def workflow_doc(workflow_text):
    """The parsed workflow, or a raise. Never a silent empty.

    Shared by D1's wiring rule and R8's lane rule so both fail the same way,
    and CLOSED: without PyYAML there is no parse tree, and the substring scan
    that would stand in for one is the exact defect D1 replaced.
    """
    if _yaml is None:
        raise RuntimeError(
            "PyYAML is unavailable, so the workflow cannot be PARSED, and a "
            "substring scan of its text is precisely the defect this function "
            "replaced. Install PyYAML in this lane (it is already in "
            "requirements.txt) rather than degrading to a text scan")
    try:
        return _yaml.safe_load(workflow_text)
    except _yaml.YAMLError as e:
        raise RuntimeError(f"the workflow is not parsable YAML ({e})") from e


def executed_run_commands(workflow_text):
    """Every command line CI ACTUALLY EXECUTES, as (job, step, line) triples.

    A SUBSTRING SCAN OVER THE WORKFLOW TEXT CANNOT TELL AN INVOCATION FROM A
    COMMENT ABOUT AN INVOCATION, and this file was written with exactly that
    defect. The reconcile flags could be deleted from every executed step and
    the wiring rule stayed green, because one occurrence survived: the YAML
    comment -- written by this gate's own author -- warning that without those
    steps the checker lane goes vacuous. The comment warning about the failure
    mode was what made the failure mode invisible. It is the same shape as the
    vacuity this whole file exists to refuse, one level up: prose ABOUT a check
    reading as the check.

    So the workflow is PARSED, and only `run:` bodies are considered. Two kinds
    of comment are dropped: YAML comments, by the parser, and shell comments
    inside a `run: |` block, by the line filter here -- the second matters
    because commenting out a line inside a block is the cheapest way to
    de-wire a step while leaving its text in the file.

    Raises rather than returning empty when the workflow cannot be parsed: a
    subject list that silently empties reports no findings.
    """
    doc = workflow_doc(workflow_text)
    if not isinstance(doc, dict):
        return []
    commands = []
    jobs = doc.get("jobs")
    for job_name in sorted(jobs) if isinstance(jobs, dict) else []:
        job = jobs[job_name]
        if not isinstance(job, dict):
            continue
        steps = job.get("steps")
        for i, step in enumerate(steps if isinstance(steps, list) else []):
            if not isinstance(step, dict):
                continue
            body = step.get("run")
            if not isinstance(body, str):
                continue
            label = step.get("name") or f"step #{i + 1}"
            for line in body.splitlines():
                if not line.strip() or line.lstrip().startswith("#"):
                    continue  # a SHELL comment inside a `run: |` block
                commands.append((job_name, label, line.strip()))
    return commands


def _flag_argument(line, flag):
    """The token a flag takes on a command line, or None."""
    try:
        tokens = shlex.split(line, comments=True)
    except ValueError:
        tokens = line.split()
    for i, tok in enumerate(tokens):
        if tok == flag:
            return tokens[i + 1] if i + 1 < len(tokens) else None
        if tok.startswith(flag + "="):
            return tok[len(flag) + 1:]
    return None


def check_ci_wiring(workflow_text):
    """The gate and the reconciliation must both be INVOKED by CI.

    check_lane_coverage.py already asserts this FILE runs on both platform
    families; what it cannot see is whether the RECONCILE arm runs at all,
    because it checks that a script is invoked, not how.

    Three things are asserted, and the second and third exist because the
    first alone can be satisfied by one surviving job:

      1. each flag appears in at least one EXECUTED command;
      2. the flags PAIR inside a job -- a job that writes an account but never
         reads it has done the expensive half and skipped the assertion, and a
         job that reconciles an account it did not write is reading whatever
         happens to be on disk;
      3. the path reconciled is a path that job WROTE.
    """
    try:
        commands = executed_run_commands(workflow_text)
    except RuntimeError as e:
        return [f"wiring: {e}"]

    errors = []
    if not commands:
        errors.append(
            "wiring: the workflow parses to NO executed `run:` command at "
            "all. Refusing to scan nothing and call it wired")

    seen = {flag: [] for flag in REQUIRED_WIRING}
    for job, step, line in commands:
        for flag in REQUIRED_WIRING:
            if flag in line:
                seen[flag].append((job, step, line))

    for flag, why in sorted(REQUIRED_WIRING.items()):
        if not seen[flag]:
            errors.append(
                f"wiring: no EXECUTED CI step passes `{flag}` -- {why}. "
                f"({len(commands)} run-command line(s) scanned; YAML comments "
                f"and shell comments are NOT executed steps, and a comment "
                f"that mentions this flag while warning about this exact "
                f"failure mode is what used to keep it green.)")

    writers, readers = {}, {}
    for job, _step, line in seen[REPORT_FLAG]:
        writers.setdefault(job, set()).add(_flag_argument(line, REPORT_FLAG))
    for job, _step, line in seen[RECONCILE_FLAG]:
        readers.setdefault(job, set()).add(_flag_argument(line, RECONCILE_FLAG))
    for job in sorted(set(writers) | set(readers)):
        if job not in readers:
            errors.append(
                f"wiring: job `{job}` passes `{REPORT_FLAG}` but no step in it "
                f"passes `{RECONCILE_FLAG}`: it pays for the account and never "
                f"asserts on it, which leaves the counts in a log")
        elif job not in writers:
            errors.append(
                f"wiring: job `{job}` passes `{RECONCILE_FLAG}` but no step in "
                f"it WROTE a report: it is reconciling whatever file happens "
                f"to be on disk, which is not evidence about this run")
        else:
            orphans = sorted(p for p in readers[job] if p not in writers[job])
            if orphans:
                errors.append(
                    f"wiring: job `{job}` reconciles {', '.join(map(str, orphans))} "
                    f"but wrote {', '.join(map(str, sorted(writers[job])))} -- "
                    f"the account being read is not the account this job "
                    f"produced")
    return errors


# ---------------------------------------------------------------------------
# R8: the declared lanes, and whether CI actually adjudicates each one
# ---------------------------------------------------------------------------

class UnresolvableLane(Exception):
    """A job's platform cannot be determined from the workflow statically.

    Raised, never defaulted. A job classified as the wrong platform would let
    this rule report adjudication it has not verified -- which is the failure
    mode the whole rule exists to catch, wearing the gate's own badge.
    """


def platform_of(runs_on):
    """`runs-on` -> a platform family in PLATFORMS, or a raise."""
    if isinstance(runs_on, list):
        families = {platform_of(r) for r in runs_on}
        if len(families) != 1:
            raise UnresolvableLane(f"label list spans platforms: {runs_on!r}")
        return families.pop()
    if not isinstance(runs_on, str):
        raise UnresolvableLane(f"non-string runs-on: {runs_on!r}")
    if "${{" in runs_on:
        raise UnresolvableLane(
            f"runs-on is an expression, not a literal ({runs_on!r}); a matrix "
            f"lane cannot be resolved here and will not be guessed at")
    low = runs_on.lower()
    for label, family in RUNNER_PLATFORMS:
        if label in low:
            return family
    raise UnresolvableLane(f"unrecognised runner label: {runs_on!r}")


def defaults_run_shell(node):
    """`defaults: run: shell:` on a workflow or a job node, or None.

    The same shape at both levels, which is why one function reads both -- and
    reading BOTH is the point: the Windows job's block is what made this gate's
    execution model true, and nothing here read it.
    """
    if not isinstance(node, dict):
        return None
    defaults = node.get("defaults")
    if not isinstance(defaults, dict):
        return None
    run = defaults.get("run")
    if not isinstance(run, dict):
        return None
    shell = run.get("shell")
    return shell.strip() if isinstance(shell, str) and shell.strip() else None


def effective_shell(step, job, doc, platform):
    """(shell, where it came from) for one `run:` step, in GitHub's precedence.

    Most specific first: the step's own `shell:`, the job's
    `defaults.run.shell`, the workflow's `defaults.run.shell`, then the runner's
    platform default. Returns (None, why) when the platform itself could not be
    resolved -- a shell inferred from a platform this gate refused to guess at
    would be a guess wearing two hats.
    """
    step_shell = step.get("shell") if isinstance(step, dict) else None
    if isinstance(step_shell, str) and step_shell.strip():
        return step_shell.strip(), "the step's own `shell:`"
    job_shell = defaults_run_shell(job)
    if job_shell:
        return job_shell, "the job's `defaults.run.shell`"
    wf_shell = defaults_run_shell(doc)
    if wf_shell:
        return wf_shell, "the workflow's `defaults.run.shell`"
    if platform is None:
        return None, ("no `shell:` anywhere and the runner platform could not "
                      "be resolved, so the default cannot be either")
    default = PLATFORM_DEFAULT_SHELL.get(platform)
    if default is None:
        return None, (f"no `shell:` anywhere and PLATFORM_DEFAULT_SHELL states "
                      f"none for `{platform}`")
    return default, (f"the DEFAULT shell on `{platform}`; no `shell:` on the "
                     f"step and none in the job's or the workflow's "
                     f"`defaults.run`")


def shell_model_refusal(shell, source):
    """Why this gate cannot judge an exit status under `shell`, or None.

    FAIL CLOSED. The alternative -- assume `bash` -- is the defect this clause
    repairs, and assuming it in the function that repairs it would be the fifth
    iteration of the same shape rather than the end of it.
    """
    if not shell:
        return (f"{source}. This gate's every exit-status rule stands on `a "
                f"failing simple command aborts the step`, which is a property "
                f"of the SHELL; it will not assume one")
    key = shell.strip().lower()
    if key in SHELL_ABORTS_ON_FAILURE:
        return None
    if key in SHELL_DOES_NOT_ABORT:
        return (f"it runs under `{shell}` -- {source} -- and "
                f"{SHELL_DOES_NOT_ABORT[key]}. Set `shell: bash` on the step, "
                f"or `defaults: run: shell: bash` on the job, which is what "
                f"the Windows job carries eight lines below `runs-on` and "
                f"which no gate in this repository read until A6")
    return (f"it runs under `{shell}` -- {source} -- whose failure semantics "
            f"this gate does not model. REFUSED rather than assumed to be "
            f"bash: every rule here that reads an exit status is a claim about "
            f"the shell, and a gate that guessed its own floor would report "
            f"adjudication nobody verified. Add `{shell}` to "
            f"SHELL_ABORTS_ON_FAILURE with the measurement showing a non-final "
            f"failure aborts, or set `shell: bash` on this step. Modelled "
            f"today: " + "; ".join(
                f"`{k}` -- {v}"
                for k, v in sorted(SHELL_ABORTS_ON_FAILURE.items())))


_AND_OR = re.compile(r"\|\||&&")


def status_discarded(line, marker, is_last_line, shell, shell_source):
    """Why the failure of `marker`'s command on this line would NOT fail the
    step, or None. `marker` is the script whose invocation is being judged.

    `shell` IS REQUIRED AND HAS NO DEFAULT. It was a hardcoded assumption in
    this docstring for the whole of A6's life -- see the module header -- and a
    parameter with a default is a hardcoded assumption with a nicer spelling.
    Making it required is the same move the Swift copy-site class needed: force
    every call site to be enumerated rather than audited.

    Under a shell this gate models, GitHub runs a `run:` body so that a failing
    simple command aborts the step -- but `-e` is IGNORED for every element of
    an AND-OR list except the last, and that is measured, not folklore:

        bash -e -c 'false && echo hi; echo after'   ->  prints `after`, exits 0
        bash -e -c 'false && echo hi'               ->  exits 1

    So a checker invocation written as the left half of an `&&` is silent on any
    line but the last, where the script's status becomes the status of the last
    command executed -- the one that failed. That distinction is worth keeping:
    `runner --self-test && runner` as a step's only line is a correct idiom, and
    a gate that reddened it would be teaching the wrong lesson.

    `||` is worse in both directions: on the left the failure is swallowed by
    the fallback, on the right the command runs only when something else already
    broke. A pipe hands the status to the last stage. `&` never waits at all.

    THIS IS NOT A SHELL. It names the decay forms that have a name and cannot
    see a status discarded by a trap, a subshell, `set +e` three lines up, or a
    variable. A gate claiming to model bash would be a fourth shell with a nicer
    name; see WHAT THIS GATE DOES NOT COVER.
    """
    # A6, AND IT COMES FIRST. Everything below reasons about `bash -e`; under
    # any other shell that reasoning is not conservative, it is simply about a
    # different program. So the shell is settled before a single `&&` is read.
    refusal = shell_model_refusal(shell, shell_source)
    if refusal:
        return refusal
    stripped = line.strip()
    words = stripped.split()
    if not words:
        return None
    if words[0] in ("if", "while", "until", "!"):
        return (f"it is the condition of a shell `{words[0]}`, which CONSUMES "
                f"the exit status instead of letting it fail the step")
    if stripped.endswith("&") and not stripped.endswith("&&"):
        return "it is backgrounded with `&`, so the step never waits for it"
    segments = _AND_OR.split(stripped)
    mine = next((i for i, seg in enumerate(segments) if marker in seg), None)
    if mine is None:                       # not this line's business
        return None
    if "||" in stripped:
        return ("its exit status is absorbed by an `||` -- either the failure "
                "is swallowed by the fallback, or the command runs only when "
                "something else has already broken")
    if mine < len(segments) - 1 and not is_last_line:
        return ("it is a non-final element of an `&&` chain on a non-final "
                "line, and `bash -e` does not abort for those: the failure is "
                "swallowed and the step's status comes from a later line. Put "
                "the invocation on its own line")
    if "|" in segments[mine]:
        return ("its exit status is handed to the last stage of a pipe, which "
                "is what reports to the shell")
    return None


def _requested_langs(line):
    """The lane set a writer command requests, or None if it left it implicit.

    Returning None is deliberate and the caller treats it as an ERROR rather
    than filling in the runner's default. Modelling the default would mean this
    gate hardcoding a value that lives in another file's argparse call, and the
    day those two disagree the gate reports adjudication of a lane nobody ran.
    An explicit `--lang` costs one flag and cannot drift.
    """
    arg = _flag_argument(line, LANG_FLAG)
    if arg is None:
        return None
    return frozenset(part.strip() for part in arg.split(",") if part.strip())


def checker_invocations(job, doc, platform):
    """(writers, readers) for one job, as records carrying their own defeaters.

    A writer runs the runner with `--checker-report`; a reader runs this gate
    with `--reconcile`. Each record carries the step's `if:` and
    `continue-on-error` and any shell short-circuit on its line, because those
    are the three ways a step that is PRESENT does not CHECK -- and none of them
    is visible to `executed_run_commands`, whose docstring nonetheless claims to
    return every command CI actually executes.

    `doc` and `platform` are here for A6 and are REQUIRED: the fourth way a
    present step does not check is that its shell never aborts, and the shell is
    declared in three places OUTSIDE the step -- the job's `defaults.run.shell`,
    the workflow's, and the platform default. A per-step function that read only
    the step could never see the block that made this gate's model true.
    """
    writers, readers = [], []
    for i, step in enumerate(job.get("steps") or []):
        if not isinstance(step, dict):
            continue
        body = step.get("run")
        if not isinstance(body, str):
            continue
        lines = [l.strip() for l in body.splitlines()
                 if l.strip() and not l.lstrip().startswith("#")]
        last = lines[-1] if lines else None
        label = step.get("name") or f"step #{i + 1}"
        shell, shell_source = effective_shell(step, job, doc, platform)
        for line in lines:
            base = {
                "step": label,
                "line": line,
                "if": step.get("if"),
                "continue_on_error": step.get("continue-on-error"),
                "shell": shell,
                "shell_source": shell_source,
            }
            if WRITER_SCRIPT in line and REPORT_FLAG in line:
                rec = dict(base)
                rec["path"] = _flag_argument(line, REPORT_FLAG)
                rec["langs"] = _requested_langs(line)
                rec["discarded"] = status_discarded(
                    line, WRITER_SCRIPT, line is last, shell, shell_source)
                writers.append(rec)
            if READER_SCRIPT in line and RECONCILE_FLAG in line:
                rec = dict(base)
                rec["path"] = _flag_argument(line, RECONCILE_FLAG)
                rec["discarded"] = status_discarded(
                    line, READER_SCRIPT, line is last, shell, shell_source)
                readers.append(rec)
    return writers, readers


def _failure_ignored(value):
    """A `continue-on-error` value that leaves the failure ignored, rendered.

    Absent or literal `false` is the only shape that keeps a step blocking.
    An EXPRESSION is treated as ignoring the failure: it might evaluate either
    way, and a gate that assumed the favourable branch would be asserting a
    property of a value it cannot read.
    """
    if value is None or value is False:
        return None
    return repr(value)


def needs_problems(job_name, jobs):
    """Reasons this job's `needs:` chain might never run. Transitive.

    A job whose dependency is SKIPPED never runs, and the dependency does not
    have to be adjacent: an `if:` three jobs upstream un-adjudicates this lane
    just as thoroughly, and reads as an unrelated edit to an unrelated job.

    `continue-on-error` on a DEPENDENCY is deliberately not a problem here: it
    makes that job's failure non-blocking, but the job still completes and
    dependents still run.
    """
    problems, seen, frontier = [], set(), [job_name]
    while frontier:
        cur = frontier.pop()
        job = jobs.get(cur)
        needs = job.get("needs") if isinstance(job, dict) else None
        if isinstance(needs, str):
            needs = [needs]
        for dep in needs if isinstance(needs, list) else []:
            if not isinstance(dep, str):
                problems.append(f"`{cur}` needs a non-string job {dep!r}")
                continue
            if dep == job_name:
                problems.append(
                    f"the `needs:` chain is CYCLIC (`{cur}` needs "
                    f"`{dep}`), so nothing in it ever runs")
                continue
            if dep not in jobs:
                problems.append(
                    f"`{cur}` needs `{dep}`, which is not a job in this "
                    f"workflow -- the dependency can never succeed")
                continue
            dep_job = jobs[dep] if isinstance(jobs[dep], dict) else {}
            if dep_job.get("if") is not None:
                problems.append(
                    f"`{cur}` needs `{dep}`, and `{dep}` is gated behind "
                    f"`if: {dep_job['if']}` -- when that is false `{dep}` is "
                    f"SKIPPED, and a job whose dependency was skipped never "
                    f"runs at all")
            if dep not in seen:
                seen.add(dep)
                frontier.append(dep)
    return problems


def _permitted_condition(row):
    pif = row.get("permitted_if")
    if not isinstance(pif, dict):
        return None
    cond = pif.get("condition")
    return cond.strip() if isinstance(cond, str) else None


def _if_defeats(where, cond, row):
    """An `if:` that is not the one this lane's row declares, rendered."""
    permitted = _permitted_condition(row)
    if permitted is not None and str(cond).strip() == permitted:
        return None
    extra = (f" The row permits `{permitted}`, which is not this one."
             if permitted is not None else
             " If it must be conditional, declare the exact condition in the "
             "row's `permitted_if` with an argument for why a lane that "
             "sometimes does not run still counts as adjudicated.")
    return (f"{where} is gated behind `if: {cond}`, so on the runs where that "
            f"is false NOTHING adjudicates this lane and the build is green "
            f"anyway.{extra}")


def registry_shape_errors(registry):
    """The registry must be usable before it can be iterated.

    Every clause here is anti-vacuity: an unusable registry must be an ERROR,
    never an empty iteration, because an empty iteration over the OBLIGATION
    reproduces exactly the hole this rule closed -- zero lanes checked, gate
    green.
    """
    if not isinstance(registry, dict):
        return [f"lanes: {LANE_REGISTRY.name} is not a JSON object"]
    lanes = registry.get("lanes")
    if not isinstance(lanes, dict) or not lanes:
        return [f"lanes: {LANE_REGISTRY.name} declares NO lane ({lanes!r}). "
                f"The rule iterates the DECLARED lanes, so an empty registry "
                f"checks nothing and prints OK -- which is the vacuity this "
                f"whole file refuses, reintroduced through its own data file"]
    errors = []
    if len(lanes) < MIN_DECLARED_LANES:
        errors.append(
            f"lanes: {len(lanes)} lane(s) declared, floor "
            f"{MIN_DECLARED_LANES}. A lane was dropped without lowering the "
            f"floor. If a platform really has stopped refereeing the geometry "
            f"checkers, say so in the commit message and lower the number in "
            f"the same edit")
    known_langs = set(cla.LANGUAGES)
    for key in sorted(lanes):
        row = lanes[key]
        if not isinstance(key, str) or key.count(":") != 1:
            errors.append(
                f"lanes: `{key}` is not a `platform:language` pair")
            continue
        platform, _, language = key.partition(":")
        if platform not in PLATFORMS:
            errors.append(
                f"lanes: `{key}` names platform `{platform}`, which this gate "
                f"cannot resolve any runner to. Known: "
                f"{', '.join(sorted(PLATFORMS))}")
        if language not in known_langs:
            errors.append(
                f"lanes: `{key}` names language `{language}`, which is not a "
                f"lane the runner has ({', '.join(sorted(known_langs))}). A "
                f"typo here would declare an obligation nothing can ever "
                f"satisfy, which is a red for the wrong reason")
        if not isinstance(row, dict):
            errors.append(f"lanes: `{key}` is {row!r}, not a row object")
            continue
        reason = row.get("reason")
        if not (isinstance(reason, str) and reason.strip()):
            errors.append(
                f"lanes: `{key}` carries no `reason`. A declared obligation "
                f"without an argument is a row nobody can evaluate when the "
                f"time comes to drop it")
        pif = row.get("permitted_if")
        if pif is None:
            continue
        if not isinstance(pif, dict):
            errors.append(f"lanes: `{key}`'s `permitted_if` is {pif!r}, "
                          f"not an object")
            continue
        for field in ("condition", "why"):
            value = pif.get(field)
            if not (isinstance(value, str) and value.strip()):
                errors.append(
                    f"lanes: `{key}`'s `permitted_if` has no `{field}`. "
                    f"Excusing a conditional lane takes both the EXACT "
                    f"condition and the argument for why a lane that "
                    f"sometimes does not run still counts as adjudicated")
    return errors


def check_lane_adjudication(workflow_text, registry):
    """R8: every DECLARED lane is actually adjudicated by CI.

    THE ITERATION IS THE FIX. `check_ci_wiring` iterates `set(writers) |
    set(readers)` -- the jobs it happens to find -- so a job carrying neither
    flag is invisible and deleting the pair from the Windows job was green.
    This loop runs over the declared lanes, so a lane nothing adjudicates is
    a lane that fails, and no CI edit can make it disappear instead.

    The rest -- `continue-on-error`, `if:`, `needs:`, the shell -- are the
    supporting details: they are how a job that IS found still fails to check.
    """
    errors = registry_shape_errors(registry)
    if errors:
        return errors
    lanes = registry["lanes"]

    try:
        doc = workflow_doc(workflow_text)
    except RuntimeError as e:
        return [f"lanes: {e}"]
    jobs = doc.get("jobs") if isinstance(doc, dict) else None
    if not isinstance(jobs, dict) or not jobs:
        return ["lanes: the workflow declares no job at all. Refusing to "
                "iterate the obligation against nothing and call it met"]
    jobs = {name: job for name, job in jobs.items() if isinstance(job, dict)}

    # Per-job facts, computed once. A job with no checker invocation is not
    # REPORTED on for platform: refusing to classify an unrelated matrix job
    # would be a red about a lane nobody claimed. (The platform is nonetheless
    # RESOLVED first, because A6's shell default is derived from it -- resolving
    # is silent, reporting is what is conditional.)
    found = {}
    for name in sorted(jobs):
        try:
            platform, unresolvable = platform_of(jobs[name].get("runs-on")), None
        except UnresolvableLane as exc:
            platform, unresolvable = None, exc
        writers, readers = checker_invocations(jobs[name], doc, platform)
        if not writers and not readers:
            continue
        if unresolvable is not None:
            errors.append(
                f"lanes: job `{name}` invokes the geometry checkers but its "
                f"platform cannot be resolved ({unresolvable}). Guessing is how "
                f"the original lane-coverage defect stayed invisible")
        found[name] = (platform, writers, readers)

    for name in sorted(found):
        _platform, writers, _readers = found[name]
        for writer in writers:
            if writer["langs"] is None:
                errors.append(
                    f"lanes: job `{name}` step `{writer['step']}` writes a "
                    f"{REPORT_FLAG} without stating `{LANG_FLAG}`, so which "
                    f"lanes it adjudicates is whatever another file's argparse "
                    f"default happens to say. State the lane set on the "
                    f"command line; a default this gate mirrors is a default "
                    f"that can drift out from under it")

    # ---- the obligation, iterated -----------------------------------------
    for key in sorted(lanes):
        row = lanes[key]
        platform, _, language = key.partition(":")
        candidates, defeats, saw_permitted_if = [], [], False

        for name in sorted(found):
            job_platform, writers, readers = found[name]
            if job_platform != platform:
                continue
            for writer in writers:
                if not writer["langs"] or language not in writer["langs"]:
                    continue
                why = []

                job_if = jobs[name].get("if")
                if job_if is not None:
                    defeat = _if_defeats(f"job `{name}`", job_if, row)
                    if defeat:
                        why.append(defeat)
                    else:
                        saw_permitted_if = True
                ignored = _failure_ignored(jobs[name].get("continue-on-error"))
                if ignored:
                    why.append(
                        f"job `{name}` carries `continue-on-error: {ignored}`, "
                        f"so the whole lane can fail and the build stays "
                        f"green. A job whose failure is ignored is not a check")

                pairs = [r for r in readers if r["path"] == writer["path"]]
                if not pairs:
                    why.append(
                        f"step `{writer['step']}` writes {writer['path']} but "
                        f"no step in `{name}` reconciles that path, so the "
                        f"counts land in a log where nothing asserts on them")
                steps_to_judge = [("writer", writer)]
                steps_to_judge += [("reader", r) for r in pairs[:1]]
                for role, rec in steps_to_judge:
                    if rec["if"] is not None:
                        defeat = _if_defeats(
                            f"the {role} step `{rec['step']}` in `{name}`",
                            rec["if"], row)
                        if defeat:
                            why.append(defeat)
                        else:
                            saw_permitted_if = True
                    ignored = _failure_ignored(rec["continue_on_error"])
                    if ignored:
                        why.append(
                            f"the {role} step `{rec['step']}` in `{name}` "
                            f"carries `continue-on-error: {ignored}` -- it "
                            f"runs, it can fail, and nothing notices")
                    if rec["discarded"]:
                        why.append(
                            f"the {role} command in `{name}` step "
                            f"`{rec['step']}` cannot fail the step: "
                            f"{rec['discarded']}")

                for problem in needs_problems(name, jobs):
                    why.append(f"`{name}` may never run -- {problem}")

                if why:
                    defeats.append((name, why))
                else:
                    candidates.append(name)

        if candidates:
            if _permitted_condition(row) is not None and not saw_permitted_if:
                errors.append(
                    f"lane `{key}`: the row declares `permitted_if` "
                    f"({_permitted_condition(row)!r}) but the job adjudicating "
                    f"it carries no such condition. The excuse has outlived "
                    f"the thing it excused -- delete it. `swift:dropdown` "
                    f"asserted a hole that had closed for months, and a seat "
                    f"read the row, believed it, and set out to rebuild what "
                    f"already shipped")
            continue

        if not defeats:
            errors.append(
                f"lane `{key}`: NO JOB ADJUDICATES IT. No job running on "
                f"`{platform}` invokes {WRITER_SCRIPT} with `{language}` in "
                f"{LANG_FLAG} and reconciles the report it wrote. The registry "
                f"declares this lane because: {row['reason'][:160]}... "
                f"Wire it, or delete the row and lower MIN_DECLARED_LANES in a "
                f"commit that says which platform stops being refereed. "
                f"(Deleting the seven lines that wire a lane is the edit this "
                f"rule exists for: it used to leave this gate, its --self-test "
                f"and check_lane_coverage.py all green.)")
            continue

        detail = "; ".join(f"`{job}`: " + " ".join(why)
                           for job, why in defeats)
        errors.append(
            f"lane `{key}`: every job that could adjudicate it is neutered. "
            f"{detail}")

    # ---- the reverse direction --------------------------------------------
    # A lane CI adjudicates that nobody declared means this registry has gone
    # stale, and a registry that under-declares is the same hole one level in.
    for name in sorted(found):
        platform, writers, _readers = found[name]
        if platform is None:
            continue
        for writer in writers:
            for language in sorted(writer["langs"] or ()):
                key = f"{platform}:{language}"
                if key in lanes:
                    continue
                errors.append(
                    f"lanes: job `{name}` adjudicates the UNDECLARED lane "
                    f"`{key}` (step `{writer['step']}`). Adding a lane must be "
                    f"as deliberate as dropping one: declare it in "
                    f"{LANE_REGISTRY.name} with a reason and raise "
                    f"MIN_DECLARED_LANES, or stop running it. A registry that "
                    f"silently under-declares is the iteration hole again, "
                    f"wearing the registry's badge")
    return errors


def check_report_is_ignored():
    """R6: the report must not be committable.

    A tracked `checker-report.json` would let `--reconcile` pass with the
    writing step deleted, because the file it reads would already be in the
    checkout. `--reconcile` refuses a tracked report at read time; this rule
    is the other half, refusing the state that makes the mistake easy.
    """
    errors = []
    if _git_tracks(REPORT_FILENAME):
        errors.append(
            f"report: {REPORT_FILENAME} is TRACKED BY GIT. It is a per-run "
            f"artefact: committed, it is a file `--reconcile` can read on a "
            f"run in which nothing was executed. `git rm --cached "
            f"{REPORT_FILENAME}`")
    try:
        rc = subprocess.run(["git", "check-ignore", "-q", REPORT_FILENAME],
                            cwd=REPO, capture_output=True).returncode
    except OSError as e:
        return errors + [f"report: cannot ask git about {REPORT_FILENAME} "
                         f"({e}); refusing to assume it is ignored"]
    if rc != 0:
        errors.append(
            f"report: {REPORT_FILENAME} is not gitignored, so `git add -A` "
            f"after a local run commits one run's counts as though they were "
            f"a fact about the tree. Add it to .gitignore")
    return errors


def reconcile(report):
    """R5: the counts the runner ACTUALLY performed, read back and asserted.

    THE MISSING LANE IS THE POINT. A lane that ruled zero does not appear in
    the account at all -- `check_geometry_laws` only writes a `lanes` entry for
    a lane it ran -- so an absent lane is invisible to any rule phrased over
    the lanes PRESENT. The old code demanded two lanes only at seam 2, which
    left SEAM 1 UNGUARDED: the seam the doctrine tells you to prefer, and the
    seam every checker written so far rides. One line -- an entry in
    SKIP_LANG_ALGO, the tree's own sanctioned mechanism for a flaking lane --
    took Swift out of the checker pass entirely and this printed OK.

    So the report states which lanes were REQUESTED, and every requested lane
    must appear having ruled something, at EVERY seam. The Windows lane, which
    legitimately runs `--lang rust` alone, requests one lane and is held to
    one; it is not the lane count that is the law, it is the gap between what
    was asked for and what happened.
    """
    errors = []
    requested = report.get("lanes_requested")
    if not (isinstance(requested, list) and requested
            and all(isinstance(l, str) and l.strip() for l in requested)):
        return [f"reconcile: the report declares no usable `lanes_requested` "
                f"({requested!r}). Without it nothing records which lanes were "
                f"SUPPOSED to rule, and a lane that ruled zero is absent from "
                f"the account rather than present with a zero -- invisible to "
                f"every rule below."]
    requested = sorted(set(requested))
    algos = report.get("algorithms")
    if not isinstance(algos, dict) or not algos:
        return ["reconcile: the report accounts for NO family. Either the "
                "runner ruled nothing or it wrote the file before the checker "
                "pass -- both mean this run established nothing."]
    for algo in sorted(algos):
        acct = algos[algo]
        lanes = acct.get("lanes") or {}
        if not lanes:
            errors.append(f"reconcile: {algo} reports no lane at all")
            continue
        absent = [l for l in requested if l not in lanes]
        if absent:
            errors.append(
                f"reconcile: {algo} was requested on lane(s) "
                f"{', '.join(requested)} but the account holds only "
                f"{', '.join(sorted(lanes))}: {', '.join(absent)} ruled "
                f"NOTHING and is missing from the report entirely. A lane that "
                f"adjudicated zero is a failure at EVERY seam -- seam 1 most "
                f"of all, because it is the seam every checker rides. Look for "
                f"a SKIP_LANG_ALGO entry, a toolchain that failed to launch, "
                f"or a `--lang` edited down after the fact.")
        # The DECLARED floors, carried in the account alongside the counts.
        # Without them "non-zero" is the only thing assertable here, and a
        # two-thirds-empty lane reads the same as a full one.
        sample_floor = acct.get("min_checks_per_lane")
        vector_floor = acct.get("min_rulable_vectors")
        rulable = acct.get("rulable_vectors")
        # A sampled law's per-probe-lane floors. `null` means the law does not
        # sample in lanes (gradient_remap); a MALFORMED value is refused
        # rather than skipped, because "unreadable" and "no floors" would
        # otherwise be the same thing to every rule below.
        probe_floors = acct.get("min_checks_per_probe_lane")
        if probe_floors is not None and not (
                isinstance(probe_floors, dict) and probe_floors
                and all(isinstance(v, int) and v >= 1
                        for v in probe_floors.values())):
            errors.append(
                f"reconcile: {algo} carries "
                f"min_checks_per_probe_lane={probe_floors!r}; it must be "
                f"absent/null (a law that does not sample in lanes) or a map "
                f"of lane to a floor >= 1. An unreadable floor block and no "
                f"floor block must not mean the same thing")
            probe_floors = None
        if not isinstance(sample_floor, int) or sample_floor < 1:
            errors.append(
                f"reconcile: {algo} carries no `min_checks_per_lane` "
                f"({sample_floor!r}); the fixture declares one and the runner "
                f"must copy it into the account, or the only assertable "
                f"property here is `more than zero`")
            sample_floor = None
        if isinstance(vector_floor, int) and isinstance(rulable, int) \
                and rulable < vector_floor:
            errors.append(
                f"reconcile: {algo} ruled over {rulable} vector(s), floor "
                f"{vector_floor}: vectors were removed without lowering the "
                f"floor the fixture states about itself")
        counts = set()
        for lane in sorted(lanes):
            ruled = lanes[lane].get("ruled", 0)
            samples = lanes[lane].get("samples", 0)
            counts.add(ruled)
            if ruled < 1 or samples < 1:
                errors.append(
                    f"reconcile: {algo} lane `{lane}` performed "
                    f"{ruled} ruling(s) / {samples} sample check(s) -- a lane "
                    f"that adjudicated nothing is indistinguishable from a "
                    f"clean tree")
            elif sample_floor is not None and samples < sample_floor:
                errors.append(
                    f"reconcile: {algo} lane `{lane}` performed {samples} "
                    f"sample check(s), floor {sample_floor}: the lane did not "
                    f"go empty, it went THIN -- which a non-zero test cannot "
                    f"see")
            # THE PROBE LANES INSIDE THAT TOTAL. `samples` is the SUM over a
            # sampled law's probe lanes, and a sum is paid by whichever half
            # has it: an anchor lane that halved reconciles green behind a
            # generative lane that did not. The sum above cannot see it, so
            # the split is carried in the account and asserted here, iterated
            # over the DECLARED lanes -- a probe lane that contributed nothing
            # is missing from the breakdown, not present with a zero.
            for pl in sorted(probe_floors or {}):
                by_pl = lanes[lane].get("samples_by_probe_lane")
                if not isinstance(by_pl, dict):
                    errors.append(
                        f"reconcile: {algo} lane `{lane}` declares "
                        f"`min_checks_per_probe_lane` but carries no "
                        f"`samples_by_probe_lane` breakdown, so the floor is "
                        f"asserted against nothing and only the sum -- the "
                        f"quantity one lane can pay for the other -- survives")
                    break
                got = by_pl.get(pl, 0)
                if got < probe_floors[pl]:
                    errors.append(
                        f"reconcile: {algo} lane `{lane}` performed {got} "
                        f"sample check(s) in the `{pl}` probe lane, floor "
                        f"{probe_floors[pl]}: one probe lane went THIN while "
                        f"the total stayed healthy, which is exactly what a "
                        f"union floor cannot see")
        if len(counts) > 1:
            errors.append(
                f"reconcile: {algo}'s lanes disagree about how much was "
                f"checked ({ {l: lanes[l].get('ruled') for l in lanes} }) -- "
                f"one port has quietly stopped being adjudicated")
        # WITNESS SHAPE. Size floors measure population; this measures span.
        # A corpus can meet every count above and still be collinear -- and
        # was, for this family's whole life.
        wit, wfloors = acct.get("witnesses"), acct.get("min_witnesses")
        if not isinstance(wit, dict) or not isinstance(wfloors, dict):
            errors.append(
                f"reconcile: {algo} carries no witness-shape account "
                f"(`witnesses` / `min_witnesses`), so nothing here can tell a "
                f"corpus that spans the denotation from one that is collinear "
                f"in it")
        else:
            for wname in sorted(wfloors):
                got, floor = wit.get(wname, 0), wfloors[wname]
                if got < floor:
                    errors.append(
                        f"reconcile: {algo} has {got} witness(es) satisfying "
                        f"'{wname}', floor {floor}: the corpus went COLLINEAR "
                        f"without going empty, which no count of vectors or "
                        f"samples can see")
        disc = acct.get("discriminating", 0)
        floor = acct.get("min_discriminating", 0)
        if floor < 1:
            errors.append(f"reconcile: {algo} declares min_discriminating="
                          f"{floor}; a mutant nothing rejects measures nothing")
        elif disc < floor:
            errors.append(
                f"reconcile: {algo}'s mutant is rejected on {disc} vector(s), "
                f"floor {floor} -- the law has lost its teeth, or the mutant "
                f"has gone stale and is measuring arithmetic nobody ships")
        if acct.get("seam") == 2 and len(lanes) < 2:
            errors.append(
                f"reconcile: {algo} is a SEAM-2 family reconciled from one "
                f"lane; a mirrored law needs both arms or it is half-watched")
    return errors


def report_freshness(report, path):
    """R6: refuse a report that cannot prove it is THIS run's.

    `--reconcile` reads a file, and a file is not a run. Three ways a stale
    one gets read: it is COMMITTED and therefore present in a fresh checkout
    even when nothing ran; it is left over in a workspace from an earlier run;
    or it was produced before the corpus or the law changed underneath it. The
    first is refused by provenance, the other two by digest -- the report
    records what it was produced FROM, and this recomputes it from disk.

    The `spec` half is the interlock the half_diag audit asked for: edit the
    denotation and a report computed under the old one stops counting as
    evidence about the new one.
    """
    errors = []
    run_id = report.get("run_id")
    if not (isinstance(run_id, str) and len(run_id) >= 8):
        errors.append(
            f"reconcile: the report carries no `run_id` ({run_id!r}), so "
            f"nothing distinguishes it from a hand-written file asserting "
            f"that everything ran")
    if _git_tracks(path):
        errors.append(
            f"reconcile: {path} is TRACKED BY GIT. A committed report is "
            f"present in every checkout, so it would reconcile green on a run "
            f"where the writing step had been deleted -- which is the exact "
            f"hole this rule closes. Untrack it and gitignore it")
    digest = report.get("inputs_digest")
    if not isinstance(digest, dict):
        return errors + [
            "reconcile: the report carries no `inputs_digest`, so nothing "
            "ties its counts to the fixtures they were performed over or to "
            "the analytic tier they were computed with"]
    for key, want in (("fixtures", cla.fixture_digest(
                          list(report.get("algorithms") or {}))),
                      ("spec", cla.spec_digest())):
        got = digest.get(key)
        if got == want:
            continue
        if not isinstance(got, dict):
            errors.append(f"reconcile: `inputs_digest.{key}` is {got!r}, not a "
                          f"digest map")
            continue
        changed = sorted(set(got) ^ set(want)) + sorted(
            k for k in set(got) & set(want) if got[k] != want[k])
        errors.append(
            f"reconcile: the report was produced from DIFFERENT {key} than "
            f"the ones on disk now ({', '.join(changed)}). Its counts describe "
            f"a tree that no longer exists; re-run the runner rather than "
            f"reconciling a stale account")
    return errors


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

def self_test():
    """Prove each rule FAILS when broken. A gate is trusted for its red."""
    bad = []

    def check(cond, msg):
        if not cond:
            bad.append(msg)

    # (a) an unclassified family must be refused
    errs = check_manifest_registry({"families": {"f": {"kind": "fixtures"}}})
    check(any("carries no `checker` key" in e for e in errs),
          "(a) a family with no checker key must be refused")

    # (b) a null checker with no reason must be refused
    errs = check_manifest_registry({"families": {"f": {"checker": None}}})
    check(any("no `checker_gap` reason" in e for e in errs),
          "(b) an exemption without an argument must be refused")
    errs = check_manifest_registry(
        {"families": {"f": {"checker": None, "checker_gap": "   "}}})
    check(any("no `checker_gap` reason" in e for e in errs),
          "(b) a blank reason is not a reason")

    # (c) a STALE gap row -- the family names a checker AND excuses itself
    errs = check_manifest_registry(
        {"families": {"f": {"checker": "law", "checker_gap": "no geometry"}}})
    check(any("stale" in e for e in errs),
          "(c) a gap row whose hole has closed must be reported stale -- "
          "policing one direction is how swift:dropdown survived for months")

    # (d) a TCB module that reaches into the repo must be refused. Proven on
    # synthetic source: a self-test that wrote a leak into the real tree would
    # be a gate mutating the thing it grades.
    rel = "spec/geometry/leak.py"
    check(any("imports `jas_dioxus`" in e
              for e in import_leaks(rel, "from jas_dioxus import thing\n")),
          "(d) a spec/ module importing a port must be refused -- the "
          "no-repo-imports property IS what makes it the TCB")
    check(any("imports `workspace_interpreter`" in e for e in import_leaks(
              rel, "import workspace_interpreter.expr_eval\n")),
          "(d) reaching into the live REFERENCE is the same defect: a checker "
          "inside the reference cannot adjudicate the reference")
    check(import_leaks(rel, "import math\nfrom . import other\n") == [],
          "(d) stdlib and relative imports must pass, or the rule is noise")
    check(check_tcb_isolation([]) and "vanished" in check_tcb_isolation([])[0],
          "(d) an EMPTY subject list must be an error, not a clean scan -- a "
          "floor that vanishes with its oracle still reads as a floor")

    # (e) a report whose lane adjudicated nothing must be refused, in each of
    # the shapes the vacuity can take
    def rpt(algos, lanes=("rust", "swift")):
        """A report shell. Families get the declared floors unless the case
        under test is about their absence."""
        for acct in algos.values():
            acct.setdefault("min_checks_per_lane", 1)
            acct.setdefault("min_rulable_vectors", 1)
            acct.setdefault("rulable_vectors", 8)
            acct.setdefault("witnesses", {"shape": 4})
            acct.setdefault("min_witnesses", {"shape": 4})
        return {"lanes_requested": list(lanes), "algorithms": algos}

    check(any("accounts for NO family" in e for e in reconcile(rpt({}))),
          "(e) an empty report is not a pass")
    check(any("lanes_requested" in e for e in reconcile(
        {"algorithms": {"a": {"lanes": {"rust": {"ruled": 8, "samples": 9}},
                              "discriminating": 9,
                              "min_discriminating": 7}}})),
          "(e) a report that does not say which lanes were REQUESTED must be "
          "refused -- an absent lane is invisible without it")
    check(any("performed 0 ruling" in e for e in reconcile(rpt(
        {"a": {"lanes": {"rust": {"ruled": 0, "samples": 0},
                         "swift": {"ruled": 0, "samples": 0}},
               "discriminating": 9, "min_discriminating": 7}}))),
          "(e) a lane that ruled nothing must be refused")
    check(any("disagree" in e for e in reconcile(rpt(
        {"a": {"lanes": {"rust": {"ruled": 8, "samples": 9},
                         "swift": {"ruled": 3, "samples": 9}},
               "discriminating": 9, "min_discriminating": 7}}))),
          "(e) lanes disagreeing about how much was checked must be refused")
    check(any("lost its teeth" in e for e in reconcile(rpt(
        {"a": {"lanes": {"rust": {"ruled": 8, "samples": 9},
                         "swift": {"ruled": 8, "samples": 9}},
               "discriminating": 1, "min_discriminating": 7}}))),
          "(e) a mutant that stopped being rejected must be refused")

    # (e2) THE MISSING LANE, at SEAM 1. The shape a one-line SKIP_LANG_ALGO
    # entry produces: the lane is not present with a zero, it is ABSENT, and
    # the old seam-2-only rule let it through while printing OK.
    missing_lane = rpt({"a": {"lanes": {"rust": {"ruled": 8, "samples": 520}},
                              "seam": 1, "discriminating": 7,
                              "min_discriminating": 7}})
    check(any("ruled NOTHING" in e for e in reconcile(missing_lane)),
          "(e2) a REQUESTED lane absent from the account must be refused AT "
          "SEAM 1 -- the seam the doctrine says to prefer was the unguarded "
          "one, and one SKIP_LANG_ALGO line was enough to empty it")
    check(reconcile(rpt(
        {"a": {"lanes": {"rust": {"ruled": 8, "samples": 520}},
               "seam": 1, "discriminating": 7,
               "min_discriminating": 7}}, lanes=("rust",))) == [],
          "(e2) a genuinely single-lane run (the Windows box, which has no "
          "Swift toolchain) must still pass: the law is the GAP between what "
          "was requested and what ruled, not the lane count")
    check(reconcile(rpt(
        {"a": {"lanes": {"rust": {"ruled": 8, "samples": 520},
                         "swift": {"ruled": 8, "samples": 520}},
               "seam": 1, "discriminating": 7,
               "min_discriminating": 7}})) == [],
          "(e) a healthy report must pass, or the gate is noise")

    # (e3) THIN, not empty. The lane ran; it ran two thirds of the corpus.
    # `> 0` cannot see that, and the declared floor is the only thing that can.
    check(any("went THIN" in e for e in reconcile(rpt(
        {"a": {"lanes": {"rust": {"ruled": 12, "samples": 520},
                         "swift": {"ruled": 12, "samples": 520}},
               "seam": 1, "discriminating": 11, "min_discriminating": 11,
               "min_checks_per_lane": 750, "min_rulable_vectors": 12,
               "rulable_vectors": 12}}))),
          "(e3) a lane that performed FEWER samples than the fixture's "
          "declared floor must be refused -- this is the shape the half_diag "
          "mutation produced, and reconcile could not see it")
    check(any("min_checks_per_lane" in e for e in reconcile(
        {"lanes_requested": ["rust"],
         "algorithms": {"a": {"lanes": {"rust": {"ruled": 8, "samples": 9}},
                              "discriminating": 9,
                              "min_discriminating": 7}}})),
          "(e3) an account that omits the declared sample floor must be "
          "refused: without it the only assertable property is `> 0`")
    check(any("floor 12" in e for e in reconcile(rpt(
        {"a": {"lanes": {"rust": {"ruled": 4, "samples": 900},
                         "swift": {"ruled": 4, "samples": 900}},
               "seam": 1, "discriminating": 11, "min_discriminating": 11,
               "min_checks_per_lane": 750, "min_rulable_vectors": 12,
               "rulable_vectors": 4}}))),
          "(e3) vectors deleted without lowering the fixture's own floor must "
          "be refused at reconcile time too, not only inside the runner")

    # (e4) R7: COLLINEAR, not empty. Every count above is met; the corpus
    # separates nothing. This is the shape nine degenerate vectors had.
    check(any("COLLINEAR" in e for e in reconcile(rpt(
        {"a": {"lanes": {"rust": {"ruled": 12, "samples": 900},
                         "swift": {"ruled": 12, "samples": 900}},
               "seam": 1, "discriminating": 11, "min_discriminating": 11,
               "min_checks_per_lane": 750, "min_rulable_vectors": 12,
               "rulable_vectors": 12,
               "witnesses": {"two_dimensional_boxes": 0},
               "min_witnesses": {"two_dimensional_boxes": 4}}}))),
          "(e4) a corpus that meets every COUNT while separating nothing must "
          "be refused -- population is not span, and 585 green comparisons "
          "over 18 degenerate boxes is what that looks like")
    check(any("witness-shape account" in e for e in reconcile(
        {"lanes_requested": ["rust"],
         "algorithms": {"a": {"lanes": {"rust": {"ruled": 8, "samples": 9}},
                              "min_checks_per_lane": 1, "discriminating": 9,
                              "min_discriminating": 7}}})),
          "(e4) an account with no witness-shape block must be refused: "
          "without it nothing here can tell span from population")

    # (e5) THE PROBE LANES INSIDE A SAMPLED LAW'S TOTAL. `samples` is the SUM
    # over `anchor` + `generative`, so an anchor lane that halved reconciles
    # green behind a generative lane that did not -- which is the same defect
    # as (e3), one axis down, and invisible to every rule phrased over the
    # sum. Both directions: the split must be ASSERTED when floors are
    # declared, and a floor block the reader cannot parse must be refused
    # rather than skipped.
    def sampled(anchor, generative, floors=None, breakdown=True):
        lane = {"ruled": 19, "samples": anchor + generative}
        if breakdown:
            lane["samples_by_probe_lane"] = {"anchor": anchor,
                                             "generative": generative}
        return rpt({"a": {"lanes": {"rust": dict(lane), "swift": dict(lane)},
                          "seam": 1, "discriminating": 8,
                          "min_discriminating": 8,
                          "min_checks_per_lane": 1558,
                          "min_checks_per_probe_lane":
                              {"anchor": 1216, "generative": 342}
                              if floors is None else floors,
                          "min_rulable_vectors": 19, "rulable_vectors": 19}})
    check(reconcile(sampled(1216, 456)) == [],
          "(e5) a run whose probe lanes each meet their floor must reconcile "
          "clean")
    check(any("`anchor` probe lane" in e for e in
              reconcile(sampled(600, 1072))),
          "(e5) an ANCHOR lane at half strength must be refused even though "
          "the SUM (1672) clears min_checks_per_lane: a union total is paid "
          "by whichever lane has it, and the anchor lane is the reproducible "
          "one")
    check(any("`generative` probe lane" in e for e in
              reconcile(sampled(1558, 0))),
          "(e5) a generative lane that drew NOTHING must be refused: the sum "
          "is met entirely by the deterministic lane, so the run grew no "
          "confidence at all and nothing said so")
    check(any("no `samples_by_probe_lane`" in e for e in
              reconcile(sampled(1216, 456, breakdown=False))),
          "(e5) declaring per-probe-lane floors and reporting no breakdown "
          "must be refused -- otherwise the floors are asserted against "
          "nothing and only the payable sum survives")
    check(any("min_checks_per_probe_lane" in e for e in
              reconcile(sampled(1216, 456, floors={"anchor": 0}))),
          "(e5) a malformed probe-lane floor block must be refused, not "
          "skipped: `unreadable` and `no floors` must not mean the same thing")

    # (e6) THE FIXTURE SIDE OF THE SAME RULE, over `cla._checker_config`, and
    # it is proven by MUTATING THE LIVE FIXTURE'S OWN checker block rather
    # than a synthetic one -- a synthetic block drifts away from the shape
    # the tree actually declares, and then the self-test grades a fixture
    # nobody ships.
    with open(REPO / "test_fixtures" / "algorithms" / "boolean.json",
              encoding="utf-8") as fh:
        live_boolean = json.load(fh)

    def cfg_refuses(mutate, fragment, why):
        doc = copy.deepcopy(live_boolean)
        mutate(doc["checker"])
        got, msg = cla._checker_config("boolean", doc)
        check(got is None and fragment in (msg or ""),
              f"(e6) {why} -- got {msg!r}")

    check(cla._checker_config("boolean", copy.deepcopy(live_boolean))[0]
          is not None,
          "(e6) the live boolean.json checker block must be accepted")
    cfg_refuses(lambda c: c.update(min_accepted_per_vector=64),
                "PER PROBE LANE",
                "the OLD scalar floor -- one number over the union of two "
                "lanes -- must be refused now that the lanes are separate")
    cfg_refuses(lambda c: c["min_accepted_per_vector"].pop("generative"),
                "declares no `min_accepted_per_vector` for probe lane "
                "'generative'",
                "a lane with no floor and no excuse must be refused: silence "
                "is how a lane goes unfloored")
    cfg_refuses(lambda c: c["no_information_floor"].update(anchor="tidier"),
                "both floors probe lane 'anchor'",
                "a lane cannot be floored and excused at once")
    cfg_refuses(lambda c: c["no_information_floor"].update(generative="  "),
                "with no reason",
                "an excuse nobody had to justify is how a floor is emptied "
                "one lane at a time")
    cfg_refuses(lambda c: c["min_inside_probes_per_vector"].update(prng=3),
                "does not draw",
                "a floor for a lane no generator produces is a number that "
                "reads as a guarantee and evaluates to nothing")
    cfg_refuses(lambda c: c["min_checks_per_probe_lane"].update(anchor=900),
                "the only derivable value",
                "a per-probe-lane total that is not `per-vector floor x "
                "vectors` must be refused: an observed total goes flaky with "
                "the seed and a hand-typed one drifts")
    cfg_refuses(lambda c: c.update(min_checks_per_lane=1216),
                "per-probe-lane floors sum to",
                "the scalar total and the probe-lane split must agree, or one "
                "of the two numbers is not being read")

    # (f) CI WIRING, asserted over EXECUTED STEPS. The three cases below are
    # the defect and its two disguises; the last is the one that shipped.
    check(any("no EXECUTED CI step passes" in e
              for e in check_ci_wiring("nothing here")),
          "(f) an unwired reconcile arm must be refused: a count written to a "
          "log nothing reads is the state this rule exists to leave")
    wired = ("jobs:\n"
             "  j:\n"
             "    steps:\n"
             "      - run: |\n"
             "          runner --checker-report r.json\n"
             "          gate --reconcile r.json\n")
    check(check_ci_wiring(wired) == [],
          "(f) a genuinely wired workflow must pass, or the rule is noise")
    check(len(check_ci_wiring(
        "# runner --checker-report r.json\n"
        "# gate --reconcile r.json\n"
        "jobs:\n  j:\n    steps:\n      - run: echo hi\n")) >= 2,
          "(f) THE DEFECT: flags occurring only in a YAML COMMENT are not "
          "wiring. The comment that kept this green was the one warning that "
          "without these steps the lane goes vacuous -- prose about a check "
          "reading as the check")
    check(len(check_ci_wiring(
        "jobs:\n  j:\n    steps:\n      - run: |\n"
        "          # runner --checker-report r.json\n"
        "          # gate --reconcile r.json\n"
        "          echo hi\n")) >= 2,
          "(f) the same defect one level in: a SHELL comment inside a "
          "`run: |` block is not an executed step either")
    check(any("no step in it passes" in e for e in check_ci_wiring(
        "jobs:\n  j:\n    steps:\n"
        "      - run: runner --checker-report r.json\n")),
          "(f) a job that writes an account and never reads it must be "
          "refused -- deleting only the reconcile STEP is a smaller edit than "
          "deleting both, and the global flag scan cannot see it")
    check(any("not the account this job" in e for e in check_ci_wiring(
        "jobs:\n  j:\n    steps:\n      - run: |\n"
        "          runner --checker-report fresh.json\n"
        "          gate --reconcile stale.json\n")),
          "(f) reconciling a path this job did not write must be refused")

    # (f2) freshness: a report that cannot prove it is THIS run's
    check(any("run_id" in e for e in report_freshness(
        {"algorithms": {}, "inputs_digest": {"fixtures": {}, "spec": {}}},
        "/nonexistent/r.json")),
          "(f2) a report with no run id must be refused")
    check(any("inputs_digest" in e for e in report_freshness(
        {"run_id": "0" * 32, "algorithms": {}}, "/nonexistent/r.json")),
          "(f2) a report tying its counts to no corpus must be refused")
    check(any("DIFFERENT spec" in e for e in report_freshness(
        {"run_id": "0" * 32, "algorithms": {},
         "inputs_digest": {"fixtures": {},
                           "spec": {"spec/geometry/linear_gradient.py": "0" * 64}}},
        "/nonexistent/r.json")),
          "(f2) a report computed under a DIFFERENT analytic tier must be "
          "refused -- otherwise editing the denotation leaves the old "
          "account vouching for the new one")
    check(report_freshness(
        {"run_id": "0" * 32, "algorithms": {},
         "inputs_digest": {"fixtures": {}, "spec": cla.spec_digest()}},
        "/nonexistent/r.json") == [],
          "(f2) a fresh report at an untracked path must pass")
    check(_git_tracks("scripts/check_geometry_checkers.py")
          and not _git_tracks("/nonexistent/r.json"),
          "(f2) the tracked-file probe must answer both ways, or the "
          "committed-report rule is decoration")

    # (h) R8, THE REGISTRY ITSELF. Every case here is a way the DECLARATION can
    # stop being an obligation. They come first because an unusable registry
    # makes every case in (i) vacuous -- zero lanes iterated, gate green, which
    # is the hole R8 closed reappearing inside R8.
    check(any("declares NO lane" in e for e in
              check_lane_adjudication("", {"lanes": {}})),
          "(h) an EMPTY registry must be refused: the rule iterates the "
          "declared lanes, so zero declarations is zero checks and a green "
          "print -- the iteration hole, back through its own data file")
    thin = {"lanes": {"macos:rust": {"reason": "r"}}}
    check(any("floor" in e for e in check_lane_adjudication("", thin)),
          "(h) a lane dropped without lowering MIN_DECLARED_LANES must be "
          "refused -- a floor with slack is a hole exactly its own size")

    def reg(**rows):
        """A three-lane registry, meeting the floor, with rows overridable."""
        lanes = {"windows:rust": {"reason": "the single-lane Windows box"},
                 "macos:rust": {"reason": "the blocking reference arm"},
                 "macos:swift": {"reason": "the only Swift adjudication"}}
        lanes.update(rows)
        return {"lanes": lanes}

    check(any("carries no `reason`" in e for e in check_lane_adjudication(
        "", reg(**{"macos:swift": {}}))),
          "(h) a declared lane with no argument must be refused: a row nobody "
          "can evaluate is a row nobody can responsibly delete")
    check(any("not a lane the runner has" in e for e in check_lane_adjudication(
        "", {"lanes": {"windows:rust": {"reason": "r"},
                       "macos:rust": {"reason": "r"},
                       "macos:rustt": {"reason": "typo"}}})),
          "(h) a language the runner does not have must be refused at "
          "declaration time -- otherwise the typo reds as an unadjudicated "
          "lane and the message sends the reader to CI instead of to the row")
    check(any("cannot resolve any runner" in e for e in check_lane_adjudication(
        "", {"lanes": {"windows:rust": {"reason": "r"},
                       "macos:rust": {"reason": "r"},
                       "solaris:rust": {"reason": "r"}}})),
          "(h) an unknown platform must be refused the same way")
    check(any("no `why`" in e for e in check_lane_adjudication(
        "", reg(**{"macos:swift": {"reason": "r",
                                   "permitted_if": {"condition": "x"}}}))),
          "(h) excusing a conditional lane takes the exact condition AND the "
          "argument; a condition alone is an exemption without a reason")

    # (i) R8, THE OBLIGATION ITERATED. The builder below writes the real
    # workflow's shape: a single-lane Windows job and a two-lane macOS job,
    # each writing an account and reconciling it.
    WRITE = "python scripts/cross_language_algorithms.py --lang {} " \
            "--checker-report {}"
    READ = "python scripts/check_geometry_checkers.py --reconcile {}"

    def job(name, runs_on, steps, job_if=None, coe=None, needs=None,
            shell=None):
        out = [f"  {name}:", f"    runs-on: {runs_on}"]
        if job_if:
            out.append(f"    if: {job_if}")
        if coe is not None:
            out.append(f"    continue-on-error: {coe}")
        if needs:
            out.append(f"    needs: [{', '.join(needs)}]")
        if shell:
            out.extend(["    defaults:", "      run:", f"        shell: {shell}"])
        out.append("    steps:")
        for i, spec in enumerate(steps):
            out.append(f"      - name: step{i}")
            if spec.get("if"):
                out.append(f"        if: {spec['if']}")
            if spec.get("coe") is not None:
                out.append(f"        continue-on-error: {spec['coe']}")
            if spec.get("shell"):
                out.append(f"        shell: {spec['shell']}")
            out.append("        run: |")
            out.extend(f"          {line}" for line in spec["lines"])
        return "\n".join(out) + "\n"

    def wf(*jobs, shell=None):
        head = (f"defaults:\n  run:\n    shell: {shell}\n" if shell else "")
        return head + "jobs:\n" + "".join(jobs)

    # THE WINDOWS BUILDER CARRIES `shell: bash` BECAUSE THE REAL JOB DOES --
    # eight lines below `runs-on`, and until A6 no gate in this repository read
    # it. Omitting it here would have made every case below assert the pwsh
    # semantics by accident instead of the bash ones on purpose; the A6 cases
    # pass `shell=None` deliberately, which is what the real file would mean if
    # somebody deleted that block as a tidy.
    def win(**kw):
        kw.setdefault("shell", "bash")
        steps = kw.pop("steps", [{"lines": [WRITE.format("rust", "r.json"),
                                            READ.format("r.json")]}])
        return job("windows", "windows-latest", steps, **kw)

    def mac(**kw):
        langs = kw.pop("langs", "rust,swift")
        steps = kw.pop("steps", [{"lines": [WRITE.format(langs, "r.json"),
                                            READ.format("r.json")]}])
        return job("cross-language", "macos-latest", steps, **kw)

    healthy = wf(win(), mac())
    check(check_lane_adjudication(healthy, reg()) == [],
          "(i) a genuinely wired workflow must pass, or the whole rule is "
          "noise and every red below is unreadable")

    # (i1) THE ITERATION HOLE ITSELF, and it is the reason R8 exists. The
    # Windows job is still there, still runs its other gates -- it simply
    # carries NEITHER flag. check_ci_wiring iterates `set(writers) |
    # set(readers)`, so this job is invisible to it and the gate printed OK.
    neither = wf(job("windows", "windows-latest",
                     [{"lines": ["python scripts/check_naming_rule.py"]}]),
                 mac())
    errs = check_lane_adjudication(neither, reg())
    check(any("lane `windows:rust`" in e and "NO JOB ADJUDICATES" in e
              for e in errs),
          "(i1) A JOB CARRYING NEITHER FLAG MUST STILL FAIL ITS LANE. This is "
          "the whole inversion: iterate the obligation, not the evidence. "
          "Deleting these seven lines from the real Windows job left this "
          "gate, its --self-test and check_lane_coverage.py all green")
    check(all("macos" not in e for e in errs),
          "(i1) and only the de-wired lane may red -- a rule that reds "
          "everything on one edit cannot be read")

    # (i2) a job-level `if:` -- the job is wired and simply does not run
    check(any("gated behind `if:" in e for e in check_lane_adjudication(
        wf(win(job_if="github.event_name == 'push'"), mac()), reg())),
          "(i2) a job behind an `if:` must be refused: on every run where the "
          "condition is false NOTHING adjudicates the lane, and the build is "
          "green anyway")
    # (i3) a step-level `if:`, on the writer and on the reader separately
    check(any("writer step" in e and "gated behind" in e
              for e in check_lane_adjudication(
                  wf(win(steps=[{"if": "runner.os == 'Linux'",
                                 "lines": [WRITE.format("rust", "r.json")]},
                                {"lines": [READ.format("r.json")]}]), mac()),
                  reg())),
          "(i3) a conditional WRITER step must be refused")
    check(any("reader step" in e and "gated behind" in e
              for e in check_lane_adjudication(
                  wf(win(steps=[{"lines": [WRITE.format("rust", "r.json")]},
                                {"if": "failure()",
                                 "lines": [READ.format("r.json")]}]), mac()),
                  reg())),
          "(i3) a conditional RECONCILE step must be refused -- the expensive "
          "half runs, the assertion is what gets skipped")
    # (i3b) the declared exception, both directions
    permitted = reg(**{"windows:rust": {
        "reason": "r",
        "permitted_if": {"condition": "github.event_name == 'push'",
                         "why": "self-test"}}})
    check(check_lane_adjudication(
        wf(win(job_if="github.event_name == 'push'"), mac()),
        permitted) == [],
          "(i3b) a condition DECLARED and argued for in the row must pass, or "
          "the mechanism is a wall rather than a ledger")
    check(any("outlived" in e for e in check_lane_adjudication(
        healthy, permitted)),
          "(i3b) and a `permitted_if` for a job that carries no such condition "
          "is STALE and must red -- one direction only is how `swift:dropdown` "
          "asserted a closed hole for months")

    # (i4) continue-on-error, at both levels
    check(any("continue-on-error: True" in e for e in check_lane_adjudication(
        wf(win(coe="true"), mac()), reg())),
          "(i4) a job whose failure is ignored is not a check")
    check(any("reader step" in e and "continue-on-error" in e
              for e in check_lane_adjudication(
                  wf(win(steps=[{"lines": [WRITE.format("rust", "r.json")]},
                                {"coe": "true",
                                 "lines": [READ.format("r.json")]}]), mac()),
                  reg())),
          "(i4) nor is a reconcile step whose failure is ignored -- it runs, "
          "it can fail, and nothing notices")
    check(check_lane_adjudication(wf(win(coe="false"), mac()), reg()) == [],
          "(i4) `continue-on-error: false` is the blocking shape and must pass")

    # (i5) the `needs:` chain -- a dependency that can be skipped, one that
    # does not exist, and a cycle. A skipped dependency skips this job, and the
    # edit that does it is an `if:` on a job that looks unrelated.
    check(any("SKIPPED" in e for e in check_lane_adjudication(
        wf(win(), mac(needs=["swift"]),
           job("swift", "macos-latest",
               [{"lines": ["swift test"]}], job_if="github.ref == 'main'")),
        reg())),
          "(i5) a dependency behind an `if:` must be refused: the adjudicating "
          "job never runs, and the edit is three lines away in another job")
    check(any("not a job in this workflow" in e
              for e in check_lane_adjudication(
                  wf(win(), mac(needs=["ghost"])), reg())),
          "(i5) a `needs:` naming no job must be refused")
    check(any("CYCLIC" in e for e in check_lane_adjudication(
        wf(win(), mac(needs=["helper"]),
           job("helper", "macos-latest", [{"lines": ["true"]}],
               needs=["cross-language"])), reg())),
          "(i5) a cyclic `needs:` chain must be refused, and must terminate")
    check(check_lane_adjudication(
        wf(win(), mac(needs=["swift"]),
           job("swift", "macos-latest", [{"lines": ["swift test"]}])),
        reg()) == [],
          "(i5) an ordinary unconditional dependency must pass")

    # (i6) the shell. `bash -e` is not the whole story, and the difference is
    # measurable: `bash -e -c 'false && echo hi; echo after'` exits 0.
    check(any("absorbed by an `||`" in e for e in check_lane_adjudication(
        wf(win(steps=[{"lines": [WRITE.format("rust", "r.json"),
                                 READ.format("r.json") + " || true"]}]),
           mac()), reg())),
          "(i6) `|| true` on the reconcile line must be refused -- it is "
          "`continue-on-error` spelled in shell, and no gate here read it")
    check(any("swallowed" in e for e in check_lane_adjudication(
        wf(win(steps=[{"lines": [
            WRITE.format("rust", "r.json") + " && echo wrote",
            READ.format("r.json")]}]), mac()), reg())),
          "(i6) a non-final `&&` element on a non-final line must be refused: "
          "`bash -e` does not abort for those")
    check(check_lane_adjudication(
        wf(win(steps=[{"lines": [WRITE.format("rust", "r.json")]},
                      {"lines": [READ.format("r.json") + " && echo done"]}]),
           mac()), reg()) == [],
          "(i6) the same `&&` as the LAST line is sound -- the script's status "
          "is the failing command's -- and reddening the idiom would teach the "
          "wrong lesson")
    check(any("pipe" in e for e in check_lane_adjudication(
        wf(win(steps=[{"lines": [WRITE.format("rust", "r.json"),
                                 READ.format("r.json") + " | tee log.txt"]}]),
           mac()), reg())),
          "(i6) a piped invocation hands its status to `tee` and must be "
          "refused")

    # (a6) THE EFFECTIVE SHELL. Every case in (i6) above -- and every rule in
    # this file that reads an exit status -- rests on "a failing simple command
    # aborts the step", which is a property of the SHELL and was hardcoded in
    # status_discarded's docstring as though it were a property of GitHub. On
    # `windows-latest` it is FALSE by default. What made it true was one
    # `defaults: run: shell: bash` block that no gate in this repository read.

    # (a6-0) the resolver itself, in GitHub's precedence, before any lane rule
    # leans on it. Four sources, most specific first.
    STEP_B = {"shell": "bash"}
    JOB_P = {"defaults": {"run": {"shell": "pwsh"}}}
    WF_S = {"defaults": {"run": {"shell": "sh"}}}
    check(effective_shell(STEP_B, JOB_P, WF_S, "windows")[0] == "bash",
          "(a6-0) a step-level `shell:` must beat the job default, the "
          "workflow default and the platform default")
    check(effective_shell({}, JOB_P, WF_S, "windows")[0] == "pwsh",
          "(a6-0) the job's `defaults.run.shell` must beat the workflow's")
    check(effective_shell({}, {}, WF_S, "windows")[0] == "sh",
          "(a6-0) the workflow's `defaults.run.shell` must beat the platform "
          "default")
    check(effective_shell({}, {}, {}, "windows")[0] == "pwsh"
          and effective_shell({}, {}, {}, "macos")[0] == "bash"
          and effective_shell({}, {}, {}, "linux")[0] == "bash",
          "(a6-0) THE FACT THE GATE DID NOT KNOW: with nothing declared the "
          "shell is `pwsh` on windows and `bash` elsewhere")
    check(effective_shell({}, {}, {}, None)[0] is None,
          "(a6-0) an unresolved platform must not yield a guessed shell -- a "
          "default inferred from a platform this gate refused to guess at "
          "would be a guess wearing two hats")
    check(set(PLATFORMS) <= set(PLATFORM_DEFAULT_SHELL),
          "(a6-0) every platform family this gate can resolve a runner to must "
          "state its default shell, or a new RUNNER_PLATFORMS row silently "
          "makes every step on it unresolvable -- a red for the wrong reason")

    # (a6-1) BASH BY DEFAULT ELSEWHERE. The macOS builder declares no shell
    # anywhere, so the platform default is what carries these cases -- and the
    # bash-specific reasoning must still APPLY there, not merely not-refuse.
    check(check_lane_adjudication(wf(mac(), win()), reg()) == [],
          "(a6-1) a macOS job with no `shell:` anywhere runs under bash and "
          "must pass")
    check(any("lane `macos:rust`" in e and "absorbed by an `||`" in e
              for e in check_lane_adjudication(
                  wf(win(), mac(steps=[{"lines": [
                      WRITE.format("rust,swift", "r.json"),
                      READ.format("r.json") + " || true"]}])), reg())),
          "(a6-1) and the BASH decay forms must still FIRE on that job: a "
          "platform default is a resolved shell, not an unexamined one")

    # (a6-2) PWSH BY DEFAULT ON WINDOWS -- the live defect. This workflow is
    # the real file with the `defaults` block deleted as an ordinary tidy, and
    # before A6 it was green.
    pwsh_errs = check_lane_adjudication(wf(win(shell=None), mac()), reg())
    check(any("windows:rust" in e and "pwsh" in e for e in pwsh_errs),
          "(a6-2) THE DEFECT: with no `defaults: run: shell: bash`, the "
          "Windows job runs under `pwsh`, a failing non-final `python ...` "
          "does not abort the step, and every gate in that job below the "
          "first failure reports nothing. Deleting those three lines must red "
          "this lane by name")
    check(all("macos" not in e for e in pwsh_errs),
          "(a6-2) and only the Windows lane may red -- macOS defaults to bash "
          "and is unaffected, or the message cannot be read")

    # (a6-3) the step-level override, both ways round: it rescues a pwsh job
    # and it breaks a bash one. A precedence rule proven in one direction is a
    # coincidence.
    check(check_lane_adjudication(
        wf(win(shell="pwsh",
               steps=[{"shell": "bash",
                       "lines": [WRITE.format("rust", "r.json"),
                                 READ.format("r.json")]}]), mac()), reg()) == [],
          "(a6-3) an explicit step-level `shell: bash` must override a pwsh "
          "job default and pass")
    check(any("windows:rust" in e and "pwsh" in e
              for e in check_lane_adjudication(
                  wf(win(steps=[{"shell": "pwsh",
                                 "lines": [WRITE.format("rust", "r.json"),
                                           READ.format("r.json")]}]), mac()),
                  reg())),
          "(a6-3) and a step-level `shell: pwsh` must override the job's bash "
          "default and red")

    # (a6-4) the JOB default against the WORKFLOW default. The workflow-level
    # block is the one a reader is least likely to scroll up to.
    check(check_lane_adjudication(
        wf(win(shell="bash"), mac(shell="bash"), shell="pwsh"), reg()) == [],
          "(a6-4) a job `defaults.run.shell: bash` must override a "
          "workflow-level `pwsh` and pass")
    wf_errs = check_lane_adjudication(
        wf(win(shell="pwsh"), mac(), shell="bash"), reg())
    check(any("windows:rust" in e and "pwsh" in e for e in wf_errs),
          "(a6-4) and a job default of `pwsh` must override a workflow default "
          "of `bash` and red")
    check(all("macos" not in e for e in wf_errs),
          "(a6-4) while the macOS job, which inherits the workflow's bash, "
          "stays green -- the two levels must not be conflated")

    # (a6-5) AN UNMODELLED SHELL IS REFUSED, NOT ASSUMED TO BE BASH. This is
    # the whole posture: the gate fails closed on a shell it has not measured,
    # the same choice the PyYAML handling makes, because the alternative is the
    # fifth iteration of the shape rather than the end of it.
    check(any("does not model" in e for e in check_lane_adjudication(
        wf(win(steps=[{"shell": "python",
                       "lines": [WRITE.format("rust", "r.json"),
                                 READ.format("r.json")]}]), mac()), reg())),
          "(a6-5) a shell whose failure semantics are not modelled must be "
          "REFUSED. Assuming bash is what put A6 in the tree")
    check(any("does not model" in e for e in check_lane_adjudication(
        wf(win(shell="bash {0}"), mac()), reg())),
          "(a6-5) a CUSTOM `shell:` template must be refused even when it "
          "begins with the word bash -- `bash {0}` has no `-e`, and reading "
          "the keyword off the front of an invocation line would be assuming "
          "flags nobody wrote")
    check(shell_model_refusal("bash", "x") is None
          and shell_model_refusal("sh", "x") is None
          and shell_model_refusal("BASH", "x") is None,
          "(a6-5) and the modelled shells must pass, case-insensitively, or "
          "the rule is a wall")

    # (i7) the lane set itself: narrowed, and left implicit
    errs = check_lane_adjudication(wf(win(), mac(langs="rust")), reg())
    check(any("lane `macos:swift`" in e and "NO JOB ADJUDICATES" in e
              for e in errs),
          "(i7) `--lang rust,swift` edited down to `rust` must red the SWIFT "
          "lane by name -- R5 catches that from inside a run, this catches the "
          "CI edit that stops the run from ever requesting it")
    check(all("macos:rust" not in e for e in errs),
          "(i7) and the rust lane, which still runs, must stay green")
    check(any("without stating" in e for e in check_lane_adjudication(
        wf(win(steps=[{"lines": [
            "python scripts/cross_language_algorithms.py "
            "--checker-report r.json", READ.format("r.json")]}]), mac()),
        reg())),
          "(i7) a writer that leaves `--lang` implicit must be refused: this "
          "gate would otherwise have to mirror another file's argparse "
          "default, and a mirrored value drifts (R2's own lesson)")

    # (i8) D1's pairing rule, kept, now per lane rather than per discovered job
    check(any("no step in `windows` reconciles" in e
              for e in check_lane_adjudication(
                  wf(win(steps=[{"lines": [WRITE.format("rust", "r.json")]}]),
                     mac()), reg())),
          "(i8) writing an account and never reading it must still be refused, "
          "and now it is refused AS A LANE rather than as a job that happened "
          "to be found")
    check(any("no step in `windows` reconciles" in e
              for e in check_lane_adjudication(
                  wf(win(steps=[{"lines": [WRITE.format("rust", "fresh.json"),
                                           READ.format("stale.json")]}]),
                     mac()), reg())),
          "(i8) reconciling a path this job did not write is the same defect "
          "with a file in the way")

    # (i9) the reverse direction: a lane CI adjudicates that nobody declared
    check(any("UNDECLARED lane `linux:rust`" in e
              for e in check_lane_adjudication(
                  wf(win(), mac(),
                     job("linux", "ubuntu-latest",
                         [{"lines": [WRITE.format("rust", "r.json"),
                                     READ.format("r.json")]}])), reg())),
          "(i9) adding a lane must be as deliberate as dropping one, or the "
          "registry silently under-declares and the iteration is over a subset "
          "again")

    # (i10) an unresolvable platform is refused, not guessed
    check(any("cannot be resolved" in e for e in check_lane_adjudication(
        wf(win(), mac(),
           job("matrix", "${{ matrix.os }}",
               [{"lines": [WRITE.format("rust", "r.json"),
                           READ.format("r.json")]}])), reg())),
          "(i10) a job whose runner is an expression must be REFUSED, not "
          "classified: guessing is how the original lane-coverage defect "
          "stayed invisible")

    # (i11) THE RULE MUST BE REACHED FROM THE ENTRY POINT, and every case above
    # calls check_lane_adjudication DIRECTLY. So all of them stay green if the
    # rule is written, tested, and simply never added to live_errors() -- a
    # check that exists and does not run, which is this rule's own subject one
    # level up. These two go through the front door: mutate the REAL workflow
    # the way the decay does, point the module at it, and call live_errors().
    if _yaml is not None:
        def real_workflow():
            return _yaml.safe_load(WORKFLOW.read_text(encoding="utf-8")) or {}

        def windows_jobs(doc):
            for j in (doc.get("jobs") or {}).values():
                if not isinstance(j, dict):
                    continue
                try:
                    if platform_of(j.get("runs-on")) != "windows":
                        continue
                except UnresolvableLane:
                    continue
                yield j

        def through_the_front_door(doc, tmp, stem):
            """live_errors() against a MUTATED copy of the real workflow."""
            path = pathlib.Path(tmp) / f"{stem}.yml"
            path.write_text(_yaml.safe_dump(doc, sort_keys=False),
                            encoding="utf-8", newline="")
            saved = WORKFLOW
            globals()["WORKFLOW"] = path
            try:
                return live_errors()
            finally:
                globals()["WORKFLOW"] = saved

        real = real_workflow()
        for j in windows_jobs(real):
            for step in j.get("steps") or []:
                if isinstance(step, dict) and isinstance(step.get("run"), str):
                    step["run"] = "\n".join(
                        l for l in step["run"].splitlines()
                        if REPORT_FLAG not in l and RECONCILE_FLAG not in l)

        # A6's front door: the REAL file with nothing removed but the three-line
        # `defaults` block -- the ordinary tidy, the whole edit.
        untidied = real_workflow()
        blocks_removed = sum(1 for j in windows_jobs(untidied)
                             if j.pop("defaults", None) is not None)

        with tempfile.TemporaryDirectory() as tmp:
            front_door = through_the_front_door(real, tmp, "dewired")
            no_shell = through_the_front_door(untidied, tmp, "untidied")
            saved_reg = LANE_REGISTRY
            globals()["LANE_REGISTRY"] = pathlib.Path(tmp) / "absent.json"
            try:
                no_registry = live_errors()
            finally:
                globals()["LANE_REGISTRY"] = saved_reg
        check(any("windows:rust" in e for e in front_door),
              "(i11) live_errors() -- the ENTRY POINT -- must red when the "
              "Windows pair is stripped from the REAL workflow. Without this "
              "arm the rule can be defined, self-tested, and never wired in")
        check(not any(e.startswith("wiring:") for e in front_door),
              "(i11) and D1's rule must stay GREEN on that same tree, which is "
              "the whole point: it iterates the jobs it finds, and a job "
              "carrying neither flag is not one of them")
        check(any("cannot read" in e for e in no_registry),
              "(i11) an unreadable registry must red THROUGH THE ENTRY POINT "
              "too -- a loader that fails closed in a function nobody calls "
              "fails open")
        # (a6-6) THE LIVE PROOF, MADE PERMANENT. The manual version of this was
        # run once by hand: delete the block, watch the gate red, restore
        # byte-identical. A proof performed once is a sentence in a transcript;
        # this arm is the same proof performed every run.
        check(blocks_removed >= 1,
              "(a6-6) the REAL Windows job must carry the `defaults: run: "
              "shell: bash` block this arm deletes. If it carries none, the "
              "mutation is a no-op and the case below proves nothing -- which "
              "is the vacuity this whole file refuses, wearing a self-test's "
              "badge")
        check(any("windows:rust" in e and "pwsh" in e for e in no_shell),
              "(a6-6) and deleting ONLY that block from the real workflow must "
              "red `windows:rust` through the ENTRY POINT, naming pwsh. Before "
              "A6 this edit was invisible to every gate in the repository, and "
              "it silently converted the Windows lane's failures into passes")

    # (g) THE LIVE TREE MUST BE CLEAN. Without this arm the synthetic cases
    # above prove the mechanism and production is the first anyone hears.
    live = live_errors()
    check(not live, "(g) the live tree must be clean, but: "
                    + "; ".join(live[:3]))

    if bad:
        print("geometry-checker SELF-TEST: FAILED")
        for msg in bad:
            print(f"  {msg}")
        return 1
    print("geometry-checker SELF-TEST: OK (registry totality both "
          "directions, blank and stale reasons, TCB import leak, empty "
          "subject list, five report-vacuity shapes including a MISSING LANE "
          "at seam 1, CI wiring over EXECUTED steps only (YAML comment, shell "
          "comment, unpaired job, mismatched path), report freshness (run id, "
          "fixture and spec digests, tracked file), THIN and COLLINEAR "
          "corpora, THE PROBE LANES INSIDE A SAMPLED TOTAL (a halved anchor "
          "lane and a silent generative lane, each behind a healthy sum; a "
          "missing breakdown; a malformed floor block; and, over the LIVE "
          "fixture's own checker block, the old scalar floor, an unfloored "
          "lane, a lane both floored and excused, a reasonless excuse, a "
          "floor for a lane nothing draws, an underived total and a total "
          "that disagrees with its parts), LANE ADJUDICATION over the "
          "DECLARED lanes (empty registry, "
          "floor, missing reason, unknown platform and language, undeclared "
          "condition; a job carrying NEITHER flag, job- and step-level `if:` "
          "and its declared-and-stale exception, job- and step-level "
          "continue-on-error, a skipped/absent/cyclic `needs:` dependency, "
          "`|| true`, a swallowing `&&` and the sound one, a pipe, a narrowed "
          "`--lang`, an implicit `--lang`, an unpaired and a mismatched path, "
          "an UNDECLARED lane, an unresolvable runner), THE EFFECTIVE SHELL "
          "(all four precedence levels, bash by default off windows and pwsh "
          "on it, a step `shell:` overriding a job default and a job default "
          "overriding the workflow's -- both directions, an unmodelled shell "
          "and a custom template REFUSED rather than assumed to be bash, and "
          "the real Windows job's `defaults` block deleted through the entry "
          "door), and the live tree)")
    return 0


def load_lane_registry():
    """The declared lanes, or an ERROR. Never a silent empty.

    A registry this gate cannot read must not become an empty iteration: R8
    iterates the OBLIGATION, so zero obligations is zero checks and a green
    print -- the hole, back through its own data file.
    """
    try:
        with open(LANE_REGISTRY, encoding="utf-8") as fh:
            return json.load(fh), []
    except OSError as e:
        return None, [f"lanes: cannot read {LANE_REGISTRY.name} ({e}). The "
                      f"declared lanes are what this rule iterates; without "
                      f"them it would check nothing and print OK"]
    except json.JSONDecodeError as e:
        return None, [f"lanes: {LANE_REGISTRY.name} is not valid JSON ({e})"]


def live_errors():
    with open(MANIFEST, encoding="utf-8") as fh:
        manifest = json.load(fh)
    text = WORKFLOW.read_text(encoding="utf-8") if WORKFLOW.exists() else ""
    registry, registry_errors = load_lane_registry()
    lane_errors = registry_errors or check_lane_adjudication(text, registry)
    return (check_tcb_isolation() + check_manifest_registry(manifest)
            + check_algorithm_registry() + check_declared_floors()
            + check_ci_wiring(text) + lane_errors + check_report_is_ignored())


def main():
    argv = sys.argv[1:]
    if "--self-test" in argv:
        return self_test()
    if "--reconcile" in argv:
        path = argv[argv.index("--reconcile") + 1]
        if not os.path.exists(path):
            print(f"geometry-checker reconcile: FAILED\n  no report at "
                  f"{path}: the runner did not write one, so nothing "
                  f"establishes that either lane adjudicated anything")
            return 1
        with open(path, encoding="utf-8") as fh:
            report = json.load(fh)
        errors = report_freshness(report, path) + reconcile(report)
        if errors:
            print("geometry-checker reconcile: FAILED")
            for e in errors:
                print(f"  {e}")
            return 1
        n = len(report.get("algorithms", {}))
        total = sum(l.get("ruled", 0)
                    for a in report["algorithms"].values()
                    for l in (a.get("lanes") or {}).values())
        # The lanes that ACTUALLY RULED, taken from the account -- not
        # `lanes_requested`, which is what was ASKED FOR. Printing the request
        # is how this line said "across lanes rust, swift" on a run where
        # Swift ruled nothing and did not appear in the report at all. A
        # success line that reports its inputs cannot report a failure.
        observed = sorted({lane for a in report["algorithms"].values()
                           for lane in (a.get("lanes") or {})})
        print(f"geometry-checker reconcile: OK ({n} registered famil"
              f"{'y' if n == 1 else 'ies'}, {total} ruling(s) actually "
              f"performed by lane(s) {', '.join(observed)}; fixtures and "
              f"spec/ digests match the tree)")
        return 0

    errors = live_errors()
    if errors:
        print("geometry-checker gate: FAILED")
        for e in errors:
            print(f"  {e}")
        return 1
    named = sorted(cla.GEOMETRY_CHECKERS)
    # The lanes are reported from the REGISTRY, which is the obligation, and
    # the gate has just proven each one is adjudicated. Reporting the jobs it
    # discovered instead would be printing the evidence -- the same mistake
    # `--reconcile`'s success line made when it named `lanes_requested`.
    registry, _ = load_lane_registry()
    declared = sorted((registry or {}).get("lanes") or {})
    print(f"geometry-checker gate: OK ({len(cla.ALGORITHMS)} algorithms "
          f"classified, {len(named)} with a law ({', '.join(named)}), "
          f"{len(cla.GEOMETRY_CHECKER_GAPS)} excused with a reason; "
          f"{len(_git_tracked(TCB_ROOT + '/*.py'))} TCB module(s) import "
          f"nothing from this repository; {len(declared)} declared lane(s) "
          f"({', '.join(declared)}) each adjudicated by a job that runs, "
          f"cannot be skipped, and cannot ignore its own failure)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
