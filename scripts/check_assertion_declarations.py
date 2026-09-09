#!/usr/bin/env python3
"""A clause that examines nothing must SAY SO. Two of them vanished instead,
and a third nobody was looking for.

WHY THIS EXISTS
---------------
`verify_assertions.ps1` states its own law in its own voice, at the definition
of the three verdicts:

    THREE VERDICTS, AND `NOT RUN` IS NOT ONE OF THE OTHER TWO. An assertion
    that could not be evaluated is not a pass (that is how a gate with no
    failure mode is born) and not a failure (that would make an absent
    precondition look like a broken app). It is recorded by name, with its
    reason, and the summary counts it separately.

Measured on kenai 2026-09-09 by the seat with the only hands on the box, on the
first two runs wave 1's harness ever completed:

  * `sitting.ps1 -Scenes abi`  ->  6 PASS, 0 FAIL, 20 NOT RUN, of 26
  * `sitting.ps1 -Scenes app`  ->  9 PASS, 0 FAIL, 18 NOT RUN, of 27

⛔ THE TWO TOTALS DIFFER AND SCENE-SCOPING IS NOT WHY. `O5.1` lives inside
`if ($Scene -eq 'stay') { ... }` with no `else`, so on every non-stay scene it
is emitted NOWHERE -- not PASS, not FAIL, not NOT RUN. `P4.3` sat inside the
`else` of a MENU-rows guard whose `if` branch declared its three siblings, so
on a run with no menubar three of the four P4-MENU clauses said so and the
fourth disappeared.

⇒ THE CLAUSE ENFORCING "ABSENT IS NOT ZERO" WAS ITSELF THE ABSENT ONE. The cost
is that `N of M` HAS NO FIXED DENOMINATOR: a reader comparing two runs cannot
distinguish a clause that vanished from one that never existed, which is the
whole reason NOT RUN was invented here.

⛔ AND THE POINT OF A GATE RATHER THAN TWO REPAIRS. The two repairs are ten
minutes. What found them was a person reading an assertion block against a
list, and that instrument has a known blind spot: it can only find clauses the
list already names. The list came from this seat's own routing section, and
`O3.4` -- emitted only inside `if ($Scene -eq 'stall')`, no `else`, invisible
on all nine other scenes -- was not on it. A STRUCTURAL census found three
where careful reading found two, and the third is the one no reading could have
reached.

WHAT IT ASSERTS
---------------
For every TOP-LEVEL `if ($Scene ...)` chain in `verify_assertions.ps1`:

  (a) the chain HAS a default path -- a branch that runs when the scene does
      not match. A bare `if ($Scene -eq 'x') { ... }` has none.       RED
  (b) every clause KEY the chain can emit is DECLARED on that default
      path by an `Add-NotRun`.                                        RED

A clause KEY is the first whitespace-delimited token of a clause name (`O5.1`,
`P4.3`, `O3.C1`). A declared key `D` covers `D` and any `D.<suffix>`, because
this file legitimately declares a FAMILY in one line -- `Add-NotRun 'O1 (all
clauses)'` stands for `O1.0` through `O1.7`, and the O4 chain declares
`"$o4Prefix gesture"` for the whole `$o4Prefix.N` family below it.

⛔ (c) A CLAUSE NAME THIS GATE CANNOT RESOLVE IS AN ERROR, NEVER A SKIP.  RED
Clause names are not all literals: three sites build them at runtime. A gate
that quietly ignored those would be a census-built instrument inheriting its
own census filter -- it would pass while blind to the family it could not read.
So `$var` names are resolved from a `$var = if (..) { 'A' } else { 'B' }`
assignment (the idiom this harness uses deliberately, and says so at line 191),
function PARAMETERS are excluded BY NAME because their call sites carry the
literals this gate already reads, and anything else refuses.

WHAT IT DOES NOT COVER -- AND THERE IS NOTHING MISSING FROM THIS LIST
---------------------------------------------------------------------
⛔ Read this as a boundary, not as an omission. Each line is a decision.

  * NON-SCENE axes. `O3.C2` is guarded by `if ($paintOnUi)` and `O4.C1`'s
    declarations by `if ($Hand)`; both vanish on a run that did not ask for
    that control. Same defect CLASS, different axis, and the axis is what this
    gate joins on. Widening to every conditional in the file would make the
    default path undefinable -- there is no "the scene did not match" for
    `if ($Hand)`, only a decision about whether an unrequested control should
    declare. That decision is not made here.
  * INDENTED scene guards, and `verify_window.ps1` entirely. Its four scene
    guards emit no clauses today (measured); its `Add-NotRun` sites sit under
    `if ($Hand)`, which is the axis above.
  * WHETHER A DECLARED CLAUSE IS THE RIGHT CLAUSE. This gate reads names, not
    meanings. A branch declaring the wrong key passes here and fails a reader.

⇒ The gate's silence is bounded by that universe, and the universe is one file
and one axis. It is stated here so the next head widens it deliberately rather
than discovering the bound from a green run.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SUBJECT = REPO / "prototypes" / "sb_winui" / "verify_assertions.ps1"

# ⛔ ANTI-VACUITY FLOORS. A check that examines nothing returns 0, and 0 looks
# exactly like a measurement. These are FLOORS, not pins: they say "this gate
# found a subject to work on", and they are deliberately far below the real
# counts so that ordinary growth never touches them. What they catch is a
# regex that stopped matching, a renamed file, or a parse that fell out of the
# file's style -- every one of which otherwise reports a clean pass.
MIN_CHAINS = 4
MIN_CLAUSE_KEYS = 20

# The three emission forms, and the wrapper. `Add-HashCompare` is local to
# verify_assertions.ps1 and takes the clause name as its first positional.
_EMIT = re.compile(
    r"""Add-(?:Assert\s+-Name|NotRun|HashCompare)\s+
        (?:'(?P<sq>[^']*)'|"(?P<dq>[^"]*)"|(?P<var>\$[A-Za-z0-9_]+))""",
    re.VERBOSE,
)
_NOTRUN = re.compile(
    r"""Add-NotRun\s+
        (?:'(?P<sq>[^']*)'|"(?P<dq>[^"]*)"|(?P<var>\$[A-Za-z0-9_]+))""",
    re.VERBOSE,
)
# `$var = if (..) { 'A' } elseif (..) { 'B' } else { 'C' }` -- the idiom the
# harness adopted on purpose: "`if` is a STATEMENT in argument position;
# assigned to a variable first, it is an expression."
_ASSIGN = re.compile(r"^\s*(\$[A-Za-z0-9_]+)\s*=\s*if\s*\(")
_LITERAL_IN_BRACES = re.compile(r"\{\s*'([^']*)'\s*\}")
_PARAM = re.compile(r"^\s*(?:function\s|\s*param\()")
_SCENE_GUARD = re.compile(r"^if \(\$Scene\s")
_BRANCH = re.compile(r"^\}\s*(?:else|elseif)\b")


def clause_key(name: str) -> str:
    """The KEY is the first whitespace-delimited token of a clause name."""
    return name.strip().split()[0] if name.strip() else ""


def covers(declared: set[str], key: str) -> bool:
    """A declared key covers itself and its dotted family below it."""
    return any(key == d or key.startswith(d + ".") for d in declared)


def resolve_vars(lines: list[str]) -> tuple[dict[str, set[str]], set[str]]:
    """Return (var -> literal clause keys, names that are function parameters).

    Parameters are collected so clause (c) can EXCLUDE them by name rather than
    by failing to match them: `Add-HashCompare`'s body emits `$name`, and its
    call sites carry the literals this gate already reads.
    """
    resolved: dict[str, set[str]] = {}
    params: set[str] = set()
    for i, line in enumerate(lines):
        m = _ASSIGN.match(line)
        if m:
            keys = {clause_key(lit) for lit in _LITERAL_IN_BRACES.findall(line)}
            keys.discard("")
            if keys:
                resolved.setdefault(m.group(1), set()).update(keys)
        if _PARAM.match(line):
            for pm in re.finditer(r"(\$[A-Za-z0-9_]+)", line):
                params.add(pm.group(1))
    return resolved, params


def names_in(lines: list[str], lo: int, hi: int, rx: re.Pattern[str]) -> list[str]:
    """Every clause name emitted by `rx` in the half-open span [lo, hi)."""
    out: list[str] = []
    for line in lines[lo:hi]:
        for m in rx.finditer(line):
            out.append(m.group("sq") or m.group("dq") or m.group("var") or "")
    return [n for n in out if n.strip()]


def chain_extent(lines: list[str], start: int) -> int:
    """Index just past the chain opened at `start`, by column-0 brace."""
    j = start + 1
    while j < len(lines):
        if lines[j].startswith("}"):
            if _BRANCH.match(lines[j]):
                j += 1
                continue
            return j + 1
        j += 1
    return len(lines)


def branch_spans(lines: list[str], start: int, end: int) -> list[tuple[int, int]]:
    heads = [start]
    heads += [j for j in range(start + 1, end) if _BRANCH.match(lines[j])]
    heads.append(end)
    return [(heads[k], heads[k + 1]) for k in range(len(heads) - 1)]


def keys_of(names: list[str], resolved: dict[str, set[str]], params: set[str],
            where: str, errors: list[str]) -> set[str]:
    """Clause keys for `names`, refusing BY NAME on anything unresolvable."""
    out: set[str] = set()
    for name in names:
        if name.startswith("$"):
            # ⛔ THE VARIABLE ENDS WHERE THE IDENTIFIER ENDS, NOT AT THE SPACE.
            # `"$o4Prefix.1 pointer=..."` splits at whitespace to `$o4Prefix.1`,
            # which matches no assignment and refused a name the gate could
            # read perfectly well. Caught by clause (c) on the real file -- the
            # refusal arm reporting a defect in the resolver behind it, which
            # is the argument for making an unresolvable name RED rather than
            # skipped: a skip would have hidden this.
            vm = re.match(r"^(\$[A-Za-z0-9_]+)(\S*)", name)
            var, suffix = (vm.group(1), vm.group(2)) if vm else (name.split()[0], "")
            if var in params:
                continue  # a wrapper parameter; its call sites carry the literals
            if var in resolved:
                # `"$o4Prefix.4 move == k"` -> the family below EVERY literal the
                # assignment can take. The union is deliberate and it is safe in
                # both directions: the same union is taken for the declarations,
                # so a family declared under one arm covers the clauses emitted
                # under it, and a prefix with no declaration at all still reds.
                for lit in resolved[var]:
                    out.add(clause_key(lit + suffix))
                continue
            errors.append(
                f"{where}: clause name {name!r} is built at runtime and this gate "
                f"cannot resolve it. Clause (c): an unresolvable name is an ERROR, "
                f"never a skip -- a gate blind to a family passes while that family "
                f"vanishes. Give it the `$v = if (..) {{ 'A' }} else {{ 'B' }}` form, "
                f"or teach this gate the new one."
            )
            continue
        key = clause_key(name)
        if key:
            out.add(key)
    return out


def audit(text: str, label: str) -> tuple[list[str], int, int]:
    """Return (failures, chains examined, distinct clause keys seen)."""
    lines = text.split("\n")
    resolved, params = resolve_vars(lines)
    failures: list[str] = []
    all_keys: set[str] = set()
    chains = 0

    for i, line in enumerate(lines):
        if not _SCENE_GUARD.match(line):
            continue
        chains += 1
        end = chain_extent(lines, i)
        spans = branch_spans(lines, i, end)
        cond = line.strip()
        where = f"{label}:{i + 1}"

        emitted = keys_of(names_in(lines, i, end, _EMIT), resolved, params,
                          where, failures)
        all_keys |= emitted

        # The DEFAULT PATH: the branch that runs when the scene does not match.
        # A negated guard (`-ne`) puts it FIRST; a positive guard (`-eq`) needs
        # a terminal `else`, and a bare `if` has none at all.
        if "-ne" in cond:
            default = spans[0]
        elif re.match(r"^\}\s*else\s*\{", lines[spans[-1][0]]):
            default = spans[-1]
        else:
            default = None

        if default is None:
            failures.append(
                f"{where}: `{cond}` has NO default path, so every clause it "
                f"emits ({', '.join(sorted(emitted)) or 'none'}) is emitted "
                f"NOWHERE on any other scene -- not PASS, not FAIL, not NOT RUN. "
                f"Clause (a). Give the chain an `else` that declares them."
            )
            continue

        declared = keys_of(names_in(lines, default[0], default[1], _NOTRUN),
                           resolved, params, where, failures)
        missing = sorted(k for k in emitted if not covers(declared, k))
        if missing:
            failures.append(
                f"{where}: `{cond}` emits {', '.join(missing)} but its default "
                f"path declares only {', '.join(sorted(declared)) or 'nothing'}. "
                f"Clause (b). On a scene this chain does not match those clauses "
                f"vanish instead of declaring, and the run's denominator moves."
            )

    return failures, chains, len(all_keys)


def run_live() -> int:
    if not SUBJECT.exists():
        print(f"REFUSED: {SUBJECT} does not exist", file=sys.stderr)
        return 2
    text = SUBJECT.read_text(encoding="utf-8-sig")
    failures, chains, keys = audit(text, SUBJECT.name)

    if chains < MIN_CHAINS or keys < MIN_CLAUSE_KEYS:
        print(
            f"REFUSED: this gate examined {chains} scene chain(s) and {keys} "
            f"clause key(s), below its floors of {MIN_CHAINS}/{MIN_CLAUSE_KEYS}. "
            f"A check that examines nothing returns 0, and 0 reads exactly like "
            f"a clean pass. Either the subject moved or the parse fell out of "
            f"the file's style.",
            file=sys.stderr,
        )
        return 2

    if failures:
        print("FAIL: a clause that examines nothing must SAY SO\n", file=sys.stderr)
        for f in dict.fromkeys(failures):  # one line per distinct finding
            print(f"  * {f}\n", file=sys.stderr)
        return 1

    print(f"OK: {chains} scene chain(s), {keys} clause key(s); every clause a "
          f"chain can emit is declared on the path taken when its scene does not match")
    return 0


# ---------------------------------------------------------------------------
# SELF-TEST -- the gate is trusted for its RED, so drive the red arms
# ---------------------------------------------------------------------------
#
# ⛔ EVERY ARM IS A WHOLE SYNTHETIC SUBJECT, not a call into a helper, because
# the defect this gate exists for is STRUCTURAL: it lives in the relationship
# between two branches, and a fixture that is not a real chain cannot carry one.
# The arms are written in the subject's own idiom -- column-0 guards, backtick
# continuations, the `$v = if (..) {..}` name -- for the reason last sitting's
# P4 pattern was wrong: A FIXTURE COPIED FROM ITS NEIGHBOUR INHERITS THE
# NEIGHBOUR'S SHAPE, so each one here is built from the real file's own lines.

_GOOD_NE = """if ($Scene -ne 'stall') {
    Add-NotRun 'O3.3 liveness' "this run is scene '$Scene'"
} else {
    Add-Assert -Name 'O3.3 liveness' -Verdict 'PASS' -Detail 'x'
}
"""

_GOOD_FAMILY = """if ($Scene -ne 'retained') {
    Add-NotRun 'O1 (all clauses)' "this run is scene '$Scene'"
} else {
    Add-HashCompare 'O1.4 A-MUT == A-prime' $a $b 'A' 'B' $true
    Add-Assert -Name 'O1.7 tail' -Verdict 'PASS' -Detail 'x'
}
"""

_BAD_NO_DEFAULT = """if ($Scene -eq 'stay') {
    Add-Assert -Name 'O5.1 the STAY pid row' -Verdict 'PASS' -Detail 'x'
}
"""

_BAD_UNDECLARED = """if ($Scene -ne 'stall') {
    Add-NotRun 'O3.3 liveness' "this run is scene '$Scene'"
} elseif ($live.Count -lt 3) {
    Add-NotRun 'O3.C1 oracle-liveness control' 'x'
} else {
    Add-Assert -Name 'O3.C1 oracle-liveness control' -Verdict 'PASS' -Detail 'x'
}
"""

_GOOD_VAR = """$o4Prefix = if ($HandEmpty) { 'O4.C1' } else { 'O4' }
if ($Scene -ne 'pointer') {
    Add-NotRun "$o4Prefix gesture" "this run is scene '$Scene'"
} else {
    Add-Assert -Name "$o4Prefix.1 pointer" -Verdict 'PASS' -Detail 'x'
}
"""

_BAD_UNRESOLVABLE = """if ($Scene -ne 'pointer') {
    Add-NotRun "$mystery gesture" "this run is scene '$Scene'"
} else {
    Add-Assert -Name "$mystery.1 pointer" -Verdict 'PASS' -Detail 'x'
}
"""

_GOOD_PARAM = """function Add-HashCompare([string]$name, $left, $right) {
    Add-NotRun $name 'the row was not written'
}
if ($Scene -ne 'retained') {
    Add-NotRun 'O1 (all clauses)' "this run is scene '$Scene'"
} else {
    Add-HashCompare 'O1.4 retention' $a $b
}
"""


def self_test() -> int:
    arms: list[tuple[str, str, bool, str]] = [
        ("a negated guard whose first branch declares", _GOOD_NE, True, ""),
        ("a family declaration covering its dotted children", _GOOD_FAMILY, True, ""),
        ("a positive guard with no else at all", _BAD_NO_DEFAULT, False, "NO default path"),
        ("a chain whose default path misses one clause", _BAD_UNDECLARED, False, "Clause (b)"),
        ("a runtime prefix resolved from its assignment", _GOOD_VAR, True, ""),
        ("a runtime name with no assignment refuses", _BAD_UNRESOLVABLE, False, "cannot resolve"),
        ("a wrapper parameter is excluded, not refused", _GOOD_PARAM, True, ""),
    ]

    passed = 0
    for name, src, want_clean, want_text in arms:
        failures, chains, _ = audit(src, "fixture")
        if chains < 1:
            print(f"  SELF-TEST FAIL [{name}]: the fixture parsed to ZERO chains, "
                  f"so this arm asserted nothing", file=sys.stderr)
            return 1
        clean = not failures
        if clean != want_clean:
            print(f"  SELF-TEST FAIL [{name}]: expected "
                  f"{'clean' if want_clean else 'a failure'}, got "
                  f"{failures or 'clean'}", file=sys.stderr)
            return 1
        if want_text and not any(want_text in f for f in failures):
            print(f"  SELF-TEST FAIL [{name}]: the failure did not name "
                  f"{want_text!r}: {failures}", file=sys.stderr)
            return 1
        passed += 1

    # ⭐ THE ARM THAT IS ABOUT THE REAL FILE, NOT ABOUT A FIXTURE. Six synthetic
    # subjects prove the ARITHMETIC of the comparison; only this one proves the
    # gate can still find its subject. A floor's arm tests its arithmetic and
    # the number itself has no test at all -- so this drives the number.
    if SUBJECT.exists():
        _, chains, keys = audit(SUBJECT.read_text(encoding="utf-8-sig"), SUBJECT.name)
        if chains < MIN_CHAINS or keys < MIN_CLAUSE_KEYS:
            print(f"  SELF-TEST FAIL [floors are reachable on the real subject]: "
                  f"{chains} chain(s), {keys} key(s) against floors "
                  f"{MIN_CHAINS}/{MIN_CLAUSE_KEYS}", file=sys.stderr)
            return 1
        passed += 1

    print(f"  self-test OK: {passed} arm(s), {len(arms)} of them synthetic subjects")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true",
                    help="drive the gate's own red and green arms and exit")
    args = ap.parse_args()
    return self_test() if args.self_test else run_live()


if __name__ == "__main__":
    sys.exit(main())
