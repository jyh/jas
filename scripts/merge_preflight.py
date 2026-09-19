#!/usr/bin/env python3
"""Refuse a merge whose green is not a statement about the tree being merged.

WHY THIS EXISTS
---------------
This is not a CI gate. It is the check a head runs by hand in the seconds
before asking the forge to merge, and it exists because it kept being REBUILT.
The jas boot brief carried the recipe as prose -- six `gh` calls -- and said
"worth rebuilding" for several shifts, which is the evidence: a recipe that is
re-derived from prose on each use is re-derived WRONG on some of them. It has
been reconstructed at least twice in one week. Prose is not a tool.

WHAT IT REFUSES, and each condition was bought by a real merge, not imagined:

  (1) DRAFT           a draft PR's checks describe an intention, not a request.
  (2) ZERO CHECK-RUNS the anti-vacuity floor. "0 failures of 0 runs" is the
                      shape every green-looking nothing wears here: a branch
                      push runs the Scrub workflow alone, and a watch reported
                      "ALL SETTLED: 6 check-runs" on a repo that runs 30.
  (3) ANY PENDING     `gh pr checks` served a STALE `pending` on #189; the
                      check-run record for the head sha is the object.
  (4) ANY NON-PASS    see THE PASS SET below -- it is narrower than GitHub's.
  (5) A REQUIRED CONTEXT ABSENT FROM THE GREEN POPULATION.
                      ⛔ THIS IS THE CONDITION THAT IS NOT IMPLIED BY (4), AND
                      IT IS WHY A COUNT IS NOT A POPULATION. `main` requires 2
                      contexts out of ~31 that run. "0 non-pass" says every
                      run that REPORTED was green; it says nothing about a
                      required context that never reported at all. Those are
                      different claims and only this one blocks the merge.
  (6) origin/main NOT AN ANCESTOR of the head.
                      The green tree must BE the merged tree. This refused #198
                      AFTER #198 was green, because merging `main` in moved the
                      head -- the checks described a tree that no longer
                      existed.

THE PASS SET IS `{success}` AND NOTHING ELSE -- A DELIBERATE NARROWING
---------------------------------------------------------------------
GitHub treats `neutral` and `skipped` as non-blocking for required contexts.
This tool does not, and the reason is one directory away: `check_gate_cannot_skip.py`
exists in this same `scripts/` because a gate SKIPPED into silence is this
project's known failure mode -- "the gate ran but checked nothing", with the
skip reading exactly like a pass. A preflight that accepts `skipped` on a
REQUIRED context would wave through the precise shape that gate was built to
catch.

⚠️ AND THIS DECISION CANNOT BE DERIVED FROM OUR DATA, WHICH IS WHY IT IS
WRITTEN DOWN RATHER THAN INFERRED: every check-run on the last merged tree
(27 of 27 at `8b533286`) reads `completed/success`. A corpus of shipped inputs
cannot witness a case it never contains. The narrowing is a CHOICE, it is
pinned by its own arm in the self-test, and the cost of being wrong is one
human look -- against a bad merge in the other direction.

A LIMIT THAT RIDES WITH EVERY VERDICT: WE ARE STRICTER THAN THE FORGE
---------------------------------------------------------------------
One check-run NAME can carry several RECORDS on a single head sha. Branch
protection resolves LATEST-WINS PER NAME; this tool counts every record. So a
stale `cancelled` record beside a fresh `success` for the same name makes this
tool REFUSE where the forge would merge.

That is the conservative direction and it is deliberate, but it is SILENT --
it reads as a bug in this tool rather than as a policy. So the receipt names
the duplication whenever it is present, and says which way the divergence
runs. It is not an edge case here: `scrub.yml` fires on BOTH `push:` and
`pull_request:` (both required by `check_scrub_trigger.py`, for reasons
written into that gate), and their `github.ref` values differ, so the
per-ref concurrency group cannot merge them. Measured on this tool's own
pull request: 6 of 25 names carried 2 records each.


NOT A CHECK GATE, AND THE NAME SAYS SO ON PURPOSE
-------------------------------------------------
`scripts/check_*.py` files are enumerated by `check_lane_coverage.py` and must
run on every platform family we ship on. This tool is deliberately NOT named
`check_*`: it talks to the live forge about one pull request, so there is no
platform claim to make and nothing for CI to run. The pure decision function
IS testable, and `--self-test` is where it is tested. Declared here rather
than left silent, because a file that quietly sidesteps a directory's gate
looks identical to one nobody noticed.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Iterable, NamedTuple

REPO = "jyh/jas"
BASE = "main"

# The conclusion set this tool accepts. See THE PASS SET above; changing it is
# a decision, and `--self-test` pins the excluded cases by name.
PASS_CONCLUSIONS = frozenset({"success"})

# Every condition this tool evaluates. The verdict carries this denominator so
# that narrowing the logic without saying so turns the self-test red: a bare
# refusal count is 0 for a run that examined nothing.
CONDITIONS = ("draft", "population", "pending", "non-pass", "required", "ancestor")

# Everything this tool PRINTS is ASCII. The seat most likely to run it is on a
# Windows box whose console is cp1252, where one non-ASCII character raises
# UnicodeEncodeError -- and this tool exits 1 when it crashes, the same code a
# legitimate refusal returns. Rich characters stay in docstrings and comments,
# which are never printed.
PREFIX_REFUSAL = "  X "
PREFIX_NOTE = "WARNING: "


class Run(NamedTuple):
    """One check-run record, as the forge reports it."""

    name: str
    status: str
    conclusion: str | None


class State(NamedTuple):
    """Everything the decision depends on, and nothing that fetches it."""

    head_sha: str
    draft: bool
    runs: tuple[Run, ...]
    required: tuple[str, ...]
    base_is_ancestor: bool


class Verdict(NamedTuple):
    ok: bool
    refusals: tuple[str, ...]
    receipt: str


def evaluate(state: State) -> Verdict:
    """Decide, and report EVERY refusal rather than the first.

    Reporting only the first would cost a round trip to the forge per defect,
    and the six conditions are independent.
    """
    refusals: list[str] = []

    if state.draft:
        refusals.append("DRAFT: the pull request is a draft")

    if not state.runs:
        refusals.append(
            "POPULATION: 0 check-runs on the head sha -- a green over an empty "
            "set. This is the vacuity floor, not a pass"
        )

    pending = [r for r in state.runs if r.status != "completed"]
    if pending:
        refusals.append(
            f"PENDING: {len(pending)} of {len(state.runs)} check-run(s) have not "
            f"completed: {', '.join(sorted(r.name for r in pending)[:5])}"
        )

    non_pass = [
        r
        for r in state.runs
        if r.status == "completed" and r.conclusion not in PASS_CONCLUSIONS
    ]
    if non_pass:
        refusals.append(
            f"NON-PASS: {len(non_pass)} of {len(state.runs)} completed check-run(s) "
            "did not conclude `success`: "
            + ", ".join(sorted(f"{r.name}={r.conclusion}" for r in non_pass)[:5])
        )

    # (5) The set operation, and it is over the GREEN population -- not over
    #     the names that reported. A required context that reported a failure
    #     is caught by (4); a required context that never reported at all is
    #     caught ONLY here, and it is invisible to every count.
    green = {r.name for r in state.runs if r.status == "completed" and r.conclusion in PASS_CONCLUSIONS}
    missing = [c for c in state.required if c not in green]
    if missing:
        refusals.append(
            f"REQUIRED: {len(missing)} of {len(state.required)} required context(s) "
            f"are absent from the {len(green)} green check-run(s): "
            + ", ".join(sorted(missing))
        )

    if not state.base_is_ancestor:
        refusals.append(
            f"ANCESTOR: origin/{BASE} is not an ancestor of {state.head_sha[:8]} -- "
            "the green tree is not the merged tree"
        )

    # ⛔ RECORDS AND NAMES ARE DIFFERENT POPULATIONS, AND PRINTING THEM
    #   UNLABELLED BESIDE EACH OTHER READS AS FAILURES. Found by running this
    #   tool on its own pull request: `check-runs 31; green 25` on a tree where
    #   nothing failed. Six names carried two records each.
    names = {r.name for r in state.runs}
    dup_names = sorted(
        n for n in names if sum(1 for r in state.runs if r.name == n) > 1
    )
    dup_note = (
        f"; {PREFIX_NOTE}{len(dup_names)} name(s) duplicated "
        f"({', '.join(dup_names[:3])}{'...' if len(dup_names) > 3 else ''}) -- "
        "the forge resolves LATEST-WINS per name and this tool counts EVERY "
        "record, so it refuses where the forge would merge"
        if dup_names
        else ""
    )
    receipt = (
        f"conditions ran {len(CONDITIONS)} ({', '.join(CONDITIONS)}); "
        f"check-runs {len(state.runs)} record(s) over {len(names)} distinct name(s); "
        f"green {len(green)}/{len(names)} name(s); "
        f"required {len(state.required) - len(missing)}/{len(state.required)} present; "
        f"refusals {len(refusals)}{dup_note}"
    )
    return Verdict(not refusals, tuple(refusals), receipt)


# --------------------------------------------------------------------------
# The forge side. Nothing below is exercised by --self-test, and it is kept as
# thin as it can be for exactly that reason: what cannot be tested should not
# be where the thinking is.
# --------------------------------------------------------------------------


class SchemaChanged(RuntimeError):
    """A key this tool reads is not in the forge's payload any more."""


def require_key(mapping: dict, key: str, where: str):
    """Read a key that MUST be there, and refuse rather than default.

    ⛔ THE ASYMMETRY THIS EXISTS FOR, and it is the reason `.get()` is not
    uniformly safe here. `payload.get("check_runs", [])` on a missing key
    yields an empty population, which condition (2) REFUSES -- it fails
    SAFE. `meta.get("draft")` on a missing key yields None, `bool(None)` is
    False, and a DRAFT PULL REQUEST SAILS THROUGH CONDITION (1) -- it fails
    UNSAFE, silently, and looks exactly like a pull request that is not a
    draft. A null-on-miss read makes a schema change, a typo and a genuine
    False all read as False.

    Measured at the object 2026-09-19: `draft`, `head` and `check_runs` are
    all present on the live payloads. That is a fact about today, which is
    precisely why the read is not written as though it were permanent.
    """
    if key not in mapping:
        raise SchemaChanged(
            f"{where}: the forge's payload has no `{key}` key. This tool reads "
            f"it to decide a merge, so it refuses rather than defaulting -- a "
            f"default here would read as a PASS."
        )
    return mapping[key]


def _gh(*args: str) -> str:
    proc = subprocess.run(
        ("gh",) + args, capture_output=True, text=True, encoding="utf-8"
    )
    if proc.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout


def fetch(pr: int, repo: str = REPO, base: str = BASE) -> State:
    meta = json.loads(_gh("api", f"repos/{repo}/pulls/{pr}"))
    head = require_key(meta, "head", f"pulls/{pr}")["sha"]
    draft = bool(require_key(meta, "draft", f"pulls/{pr}"))

    payload = json.loads(
        _gh("api", f"repos/{repo}/commits/{head}/check-runs?per_page=100")
    )
    # `check_runs` is required for a different reason than `draft`: a missing
    # key here would fail safe (condition 2 refuses an empty population), so
    # this one is required for a clear MESSAGE rather than for safety.
    runs = tuple(
        Run(r["name"], r["status"], r.get("conclusion"))
        for r in require_key(payload, "check_runs", f"commits/{head[:8]}/check-runs")
    )

    try:
        required = tuple(
            json.loads(_gh("api", f"repos/{repo}/branches/{base}/protection"))
            .get("required_status_checks", {})
            .get("contexts", [])
        )
    except RuntimeError:
        # An unprotected base is a finding, not a pass: with no required
        # contexts the set in (5) is empty and cannot refuse anything.
        print(
            f"merge_preflight: WARNING -- could not read {base}'s protection. "
            "Condition (5) is VACUOUS for this run and is reported as such.",
            file=sys.stderr,
        )
        required = ()

    ancestor = (
        subprocess.run(
            ("git", "merge-base", "--is-ancestor", f"origin/{base}", head)
        ).returncode
        == 0
    )
    return State(head, draft, runs, required, ancestor)


# --------------------------------------------------------------------------


def _state(**kw) -> State:
    """A green state, overridden per arm. The DEFAULT must pass, or every
    refusal arm below is satisfiable by a function that refuses everything."""
    base = {
        "head_sha": "8b533286deadbeef",
        "draft": False,
        "runs": (
            Run("required A", "completed", "success"),
            Run("required B", "completed", "success"),
            Run("some other job", "completed", "success"),
        ),
        "required": ("required A", "required B"),
        "base_is_ancestor": True,
    }
    base.update(kw)
    return State(**base)


def self_test(fixture: Path | None = None) -> int:
    """Prove this tool REFUSES before trusting any green it reports."""
    failures: list[str] = []
    declared = 0

    def arm(label: str, state: State, want_ok: bool, want_word: str | None = None):
        nonlocal declared
        declared += 1
        v = evaluate(state)
        if v.ok != want_ok:
            failures.append(
                f"{label}: expected ok={want_ok}, got ok={v.ok} ({v.refusals})"
            )
            return
        if want_word and not any(want_word in r for r in v.refusals):
            failures.append(
                f"{label}: refused, but no refusal names {want_word!r}: {v.refusals}"
            )

    # (a) THE POSITIVE CONTROL FIRST. Without it every arm below is satisfied
    #     by `return Verdict(False, ...)`, and the suite would be green for a
    #     tool that refuses every merge forever.
    arm("a green state must PASS", _state(), True)

    # (b) One arm per condition. These are six DIFFERENT SHAPES -- a flag, an
    #     empty population, a status field, a conclusion field, a set
    #     membership, an ancestry bool -- not one shape run six times.
    arm("draft", _state(draft=True), False, "DRAFT")
    arm("zero check-runs", _state(runs=()), False, "POPULATION")
    arm(
        "a pending run",
        _state(runs=(Run("required A", "queued", None), Run("required B", "completed", "success"))),
        False,
        "PENDING",
    )
    arm(
        "a failing run",
        _state(runs=(Run("required A", "completed", "failure"), Run("required B", "completed", "success"))),
        False,
        "NON-PASS",
    )
    arm(
        "a required context that never reported",
        _state(runs=(Run("some other job", "completed", "success"),)),
        False,
        "REQUIRED",
    )
    arm("base not an ancestor", _state(base_is_ancestor=False), False, "ANCESTOR")

    # (c) ⛔ THE ARM THAT SEPARATES (4) FROM (5), AND IT IS THE REASON THIS
    #     TOOL IS NOT `if failures == 0`. Every run that reported is GREEN and
    #     the count of non-passes is 0 -- and a required context is missing.
    #     A tool that checked only counts passes this state.
    silent = _state(
        runs=(Run("some other job", "completed", "success"),),
        required=("required A",),
    )
    v = evaluate(silent)
    declared += 1
    if v.ok:
        failures.append(
            "0 non-pass with a required context ABSENT must still refuse -- "
            "this is the count-is-not-a-population case"
        )
    elif not any("REQUIRED" in r for r in v.refusals):
        failures.append(f"the absent required context must be named: {v.refusals}")

    # (c2) ⛔ THE SHAPE THAT MADE THE VACUITY FLOOR LOAD-BEARING, AND A MUTANT
    #      IS WHAT FOUND IT. Deleting condition (2) left every other arm green,
    #      because with required contexts present condition (5) refuses an
    #      empty population too -- by a different name. It is only when the
    #      base is UNPROTECTED (`required` empty, which `fetch` warns about and
    #      does not treat as a pass) that (5) cannot fire at all, and (2) is
    #      the last thing between an empty green and a merge.
    arm(
        "an unprotected base with 0 check-runs must still refuse",
        _state(runs=(), required=()),
        False,
        "POPULATION",
    )

    # (d) THE EXCLUDED CASES, PINNED BY NAME because they are a DECISION this
    #     tool makes and our data cannot witness (27/27 are `success`). If a
    #     later head widens PASS_CONCLUSIONS, these red and make them say why.
    for excluded in ("skipped", "neutral", "cancelled", "timed_out", "action_required", "stale"):
        arm(
            f"a required context concluding `{excluded}` must REFUSE",
            _state(runs=(Run("required A", "completed", excluded), Run("required B", "completed", "success"))),
            False,
            "NON-PASS",
        )

    # (d2) THE GLUE. Every arm above constructs a State directly, so until
    #      here NOTHING witnessed the step that builds one from forge JSON --
    #      an extraction leaves its glue unwitnessed. These pin the read that
    #      fails UNSAFE: a missing `draft` key must RAISE, never default to
    #      False, because False is the value that merges.
    declared += 1
    try:
        require_key({"draft": True}, "draft", "t")
    except SchemaChanged:
        failures.append("require_key must return a key that is present")
    declared += 1
    try:
        require_key({"other": 1}, "draft", "t")
        failures.append("a MISSING `draft` key must raise, not default to False")
    except SchemaChanged as e:
        if "draft" not in str(e):
            failures.append(f"the refusal must name the missing key: {e}")
    declared += 1
    if require_key({"draft": False}, "draft", "t") is not False:
        failures.append("a present-and-False key must come back as False, not as missing")

    # (d3) ⛔ DUPLICATE RECORDS FOR ONE NAME. Found by running this tool on its
    #      OWN pull request: the receipt read `check-runs 31; green 25` on a
    #      FULLY GREEN tree, because 31 counts RECORDS and 25 counts DISTINCT
    #      NAMES. Both numbers were right and the pair reads as six failures.
    #      This repo produces duplicates BY DESIGN -- `scrub.yml` fires on both
    #      `push:` and `pull_request:` and `check_scrub_trigger.py` requires
    #      both -- so they never go away and must be reported, not survived.
    declared += 1
    dup = _state(
        runs=(
            Run("required A", "completed", "success"),
            Run("required A", "queued", None),
            Run("required B", "completed", "success"),
        ),
    )
    v = evaluate(dup)
    if v.ok:
        failures.append("a name with a still-queued duplicate must REFUSE")
    if "duplicated" not in v.receipt:
        failures.append(
            f"the receipt must SAY a name carries several records, or `31 records` "
            f"beside `25 green` reads as 6 failures: {v.receipt!r}"
        )

    # (d4) THE DIVERGENCE FROM THE FORGE, PINNED IN THE SAFE DIRECTION. Branch
    #      protection resolves LATEST-WINS PER NAME; this tool counts every
    #      record. A cancelled duplicate beside a success therefore REFUSES
    #      here and would MERGE at the forge. That is deliberate and it is the
    #      conservative side -- but it is silent, so the receipt must expose it
    #      or the refusal reads as a bug in this tool.
    declared += 1
    stale = _state(
        runs=(
            Run("required A", "completed", "cancelled"),
            Run("required A", "completed", "success"),
            Run("required B", "completed", "success"),
        ),
    )
    v = evaluate(stale)
    if v.ok:
        failures.append("a cancelled duplicate must REFUSE (we are stricter than the forge)")
    elif "duplicated" not in v.receipt:
        failures.append(f"a refusal caused by a duplicate must say so: {v.receipt!r}")

    # (d5) AND THE CONTROL: with no duplicates the receipt must NOT cry wolf.
    declared += 1
    if "duplicated" in evaluate(_state()).receipt:
        failures.append("the duplication note must be absent when there are none")

    # (d6) ⛔⛔ EVERY PRINTED BYTE MUST SURVIVE A cp1252 CONSOLE, BECAUSE THE
    #      SEAT MOST LIKELY TO RUN THIS IS ON WINDOWS. Driven, not imagined:
    #      with PYTHONIOENCODING=cp1252 this tool raised UnicodeEncodeError on
    #      its own receipt line -- and it exits 1 when it crashes, which is the
    #      SAME code a legitimate refusal returns, so a crash and a refusal are
    #      indistinguishable to the caller. The self-test did not see it because
    #      the non-ASCII lived on paths the happy path never prints.
    declared += 1
    probes = [PREFIX_REFUSAL, PREFIX_NOTE]
    for st in (
        _state(),
        _state(draft=True, base_is_ancestor=False),
        _state(runs=(Run("required A", "completed", "success"),
                     Run("required A", "queued", None),
                     Run("required B", "completed", "success"))),
        _state(runs=()),
    ):
        v = evaluate(st)
        probes.append(v.receipt)
        probes.extend(v.refusals)
    for text in probes:
        try:
            text.encode("cp1252")
        except UnicodeEncodeError as e:
            failures.append(
                f"printed text is not cp1252-safe ({e.reason} at {e.start}): {text[:70]!r}"
            )
            break

    # (e) THE RECEIPT CARRIES ITS OWN DENOMINATOR. A bare refusal count is 0
    #     for a run that examined nothing, so the verdict states how many
    #     conditions it ran -- and this arm reds if the logic is narrowed
    #     without the receipt following it.
    declared += 1
    r = evaluate(_state()).receipt
    if f"conditions ran {len(CONDITIONS)}" not in r:
        failures.append(f"the receipt must state its own denominator: {r!r}")
    declared += 1
    if "check-runs 3" not in r or "required 2/2 present" not in r:
        failures.append(f"the receipt must state the populations it read: {r!r}")

    # (f) THE REAL PAYLOAD, when one is offered: the forge's own bytes parsed
    #     by the same reader the live path uses. A fixture I typed proves the
    #     shape I imagined; this proves the shape the forge sends.
    if not fixture:
        # A tolerance is an off switch: an arm that quietly does not run when
        # its input is absent turns a missing file into a green suite. REPORT
        # and VALUE are separated -- this says NOT RUN out loud.
        print(
            "merge_preflight --self-test: " + PREFIX_NOTE + "real-payload arm NOT RUN (no fixture); "
            "the parser is unwitnessed by forge bytes in this invocation"
        )
    if fixture and not Path(fixture).exists():
        print("merge_preflight --self-test: " + PREFIX_NOTE + "fixture " + fixture.as_posix() + " is ABSENT")
        fixture = None
    if fixture:
        declared += 1
        records = json.loads(Path(fixture).read_text(encoding="utf-8"))
        runs = tuple(Run(x["name"], x["status"], x.get("conclusion")) for x in records)
        if not runs:
            failures.append(
                f"{fixture.as_posix()}: parsed 0 records -- the fixture is vacuous"
            )
        else:
            v = evaluate(_state(runs=runs, required=(runs[0].name,)))
            if not v.ok:
                failures.append(f"the real payload must pass a green state: {v.refusals}")
            else:
                # THE LIMIT RIDES WITH THE VERDICT. This arm pins the PARSER
                # against real forge bytes; the snapshot is frozen, so it
                # cannot see the forge changing its schema under us.
                print(
                    f"merge_preflight --self-test: real-payload arm OK "
                    f"({len(runs)} records parsed from a FROZEN snapshot -- "
                    "pins this parser, cannot see forge schema drift)"
                )

    print(f"merge_preflight --self-test: {declared} arm(s) executed, {declared} declared")
    if failures:
        print(f"FAIL: {len(failures)} arm(s) did not hold")
        for f in failures:
            print(f"  {f}")
        return 1
    print("merge_preflight --self-test: OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("pr", nargs="?", type=int, help="pull request number")
    ap.add_argument("--repo", default=REPO)
    ap.add_argument("--base", default=BASE)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument(
        "--fixture",
        type=Path,
        default=Path(__file__).resolve().parent / "merge_preflight_fixture.json",
        help="a real check-runs payload for the self-test (defaults to the tracked snapshot)",
    )
    args = ap.parse_args()

    if args.self_test:
        return self_test(args.fixture)

    if args.pr is None:
        ap.error("a pull request number is required (or --self-test)")

    state = fetch(args.pr, args.repo, args.base)
    verdict = evaluate(state)
    print(f"merge_preflight: {args.repo}#{args.pr} head {state.head_sha[:8]}")
    print(f"  {verdict.receipt}")
    if verdict.ok:
        print("merge_preflight: OK -- every condition holds; the green tree IS the merged tree")
        return 0
    print(f"merge_preflight: REFUSED on {len(verdict.refusals)} condition(s)")
    for r in verdict.refusals:
        print(f"{PREFIX_REFUSAL}{r}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
