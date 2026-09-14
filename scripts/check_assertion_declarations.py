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

⛔ (d) AN ARM-SELECTED FAMILY MUST DECLARE ITS UNSELECTED ARMS.           RED
Added 2026-09-14. Clauses (a)-(c) join on the SCENE and are sound there. A name
built from `$v = if (..) { 'A' } elseif (..) { 'B' } else { 'C' }` has a SECOND
axis under them: exactly ONE arm exists per run, so the other N-1 arms' keys are
emitted NOWHERE -- not PASS, not FAIL, not NOT RUN, which is what (a) exists to
forbid, one axis in.
  ⇒ AND (a)/(b) COULD NOT SEE IT, BY CONSTRUCTION. The union `keys_of` takes is
    applied to the emitting side AND the declaring side, so `covers()` compared a
    set against itself and passed whichever arm ran. MEASURED on this subject
    before (d) existed: 24 of 53 clause keys absent from EVERY run, gate `OK`.
    `keys_of`'s comment still calls that union "safe in both directions" -- TRUE
    of (b)'s axis, and it is the sentence that stopped anyone asking about this
    one. The comment is kept, with this clause as its qualifier.
  ⇒ THE EVIDENCE (d) ACCEPTS is a COLUMN-0 `foreach` over an array literal of
    the arms whose body calls `Add-NotRun` -- unconditional w.r.t. every scene
    chain, because those are column-0 too. Derived from the assignment the file
    already writes; there is no hand-maintained list.
  ⇒ (d) RULES ONLY ON PREFIX VARIABLES -- ones ever used with a suffix, as
    `"$v.1 ..."`. A WHOLE-NAME variable (`Add-NotRun $preName`) picks one clause
    among clauses the chain reports independently; nothing vanishes, and the
    remedy (d) prescribes is unavailable there. Those are EXCLUDED BY NAME and
    the exclusion list is PRINTED on both verdicts. Ruled in STATUS-flask.md 65.

WHAT IT DOES NOT COVER -- AND THERE IS NOTHING MISSING FROM THIS LIST
---------------------------------------------------------------------
⛔ Read this as a boundary, not as an omission. Each line is a decision.

  * NON-SCENE axes, MINUS THE ONE CLAUSE (d) TOOK. ⛔ THIS BULLET SAID "NON-SCENE
    axes" FLATLY UNTIL 2026-09-14 AND THAT IS NO LONGER TRUE: clause (d) now
    covers the ARM axis for PREFIX variables, and a block headed "there is
    nothing missing from this list" is the one place a stale boundary is read as
    a current one. Re-cut in the same commit as the clause, which is the only
    moment anyone looks.
    STILL UNCOVERED, and each line is a decision rather than an omission:
      - `O3.C2` guarded by `if ($paintOnUi)`, and `O4.C1`'s declarations by
        `if ($Hand)`. Both vanish on a run that did not ask for that control.
        Widening to every conditional would make the default path undefinable --
        there is no "the scene did not match" for `if ($Hand)`, only a decision
        about whether an unrequested control should declare. NOT MADE HERE.
      - WHOLE-NAME variables, excluded by clause (d) itself and PRINTED. See
        `name_vars()` for why (d)'s remedy does not fit them.
      - `verify_window.ps1` entirely, as below.
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
# ⛔ CLAUSE (d)'s READER. An ARM-DECLARATION LOOP names its arms in an ARRAY
# LITERAL -- parentheses, not braces -- so `_LITERAL_IN_BRACES` cannot see it
# and a second pattern is needed rather than a widened one. Both constructs
# are already in the subject 47 and 6 times (`@(2, 5, 10) | Where-Object` at
# :177 is this exact shape), which is why clause (d) can prescribe a repair
# this seat cannot run: it is the file's own idiom, not an invention.
#   ⛔ COLUMN 0 IS PART OF THE PATTERN, NOT A STYLE PREFERENCE. A scene guard
#     is column-0 (`_SCENE_GUARD`), so a column-0 `foreach` is UNCONDITIONAL
#     with respect to every scene chain. A loop nested inside an `if` would
#     declare on some runs and not others, which is the defect, not the fix.
_ARM_LOOP = re.compile(r"^foreach\s*\(\s*(\$[A-Za-z0-9_]+)\s+in\s+(.*)$")
_LITERAL_IN_ARRAY = re.compile(r"'([^']*)'")
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
        am = _ARM_LOOP.match(line)
        if am:
            keys = {clause_key(lit) for lit in _LITERAL_IN_ARRAY.findall(am.group(2))}
            keys.discard("")
            if keys:
                resolved.setdefault(am.group(1), set()).update(keys)
        if _PARAM.match(line):
            for pm in re.finditer(r"(\$[A-Za-z0-9_]+)", line):
                params.add(pm.group(1))
    return resolved, params


def unconditional_arm_declarations(lines: list[str],
                                   resolved: dict[str, set[str]]) -> list[set[str]]:
    """Arm sets declared by a COLUMN-0 `foreach` whose body calls `Add-NotRun`.

    Clause (d)'s evidence. A column-0 `foreach` is unconditional with respect to
    every scene chain (those are column-0 too), so a declaration inside one is
    reached on every run -- which is the whole property clause (d) needs and the
    reason the column is part of the pattern.

    ⛔ WHAT THIS DOES NOT PROVE, and it is a boundary rather than an omission:
    that the loop EXCLUDES the arm the run actually selected. `| Where-Object
    { $_ -ne $v }` is what does that, and asserting it here would be asserting a
    PowerShell semantic this seat cannot run. A loop that declared the selected
    arm too would emit one clause as both asserted and NOT RUN -- loud at the
    first live run, which is the right place for it to be caught.
    """
    out: list[set[str]] = []
    for i, line in enumerate(lines):
        am = _ARM_LOOP.match(line)
        if not am:
            continue
        var, arms = am.group(1), resolved.get(am.group(1), set())
        # ⛔ THERE WAS A `len(arms) < 2: continue` GUARD HERE AND IT WAS DELETED,
        # NOT KEPT AS BELT-AND-BRACES. A mutant that turned it off survived every
        # arm, because the caller's `arms <= a` already refuses a loop too small
        # to cover its family -- the guard tested the SAME predicate one frame
        # earlier. ⇒ TWO GUARDS, ONE PREDICATE: the redundant copy cannot be
        # driven, so it cannot be trusted, and it is the copy that rots. Deleting
        # it made the surviving check load-bearing and killed the mutant.
        end = chain_extent(lines, i)
        if any(_NOTRUN.search(l) and var in l for l in lines[i:end]):
            out.append(arms)
    return out


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


def name_vars(names: list[str]) -> tuple[set[str], set[str]]:
    """Return (prefix vars, whole-name vars) among the `$var`s building `names`.

    `keys_of` resolves a variable to its arm literals and then throws the
    variable away, which is correct for clause (b) and useless for clause (d) --
    (d) is a claim about the VARIABLE, not about the keys it expands to.

    ⛔ AND THE SPLIT IS CLAUSE (d)'s WHOLE SOUNDNESS, FOUND BY ITS OWN FIRST RED.
    Driven on the real subject before this split existed, (d) reported TWO
    families and only ONE was a defect:

      $o4Prefix   used as `"$o4Prefix.1 pointer"`  -> a FAMILY PREFIX. It renames
                  every clause below it, so exactly one family exists per run and
                  the other arms' families are emitted nowhere.   TRUE POSITIVE
      $preName    used only as `Add-NotRun $preName` -> a WHOLE NAME, chosen
                  locally between O3.3 and O3.C1, and BOTH of those clauses are
                  independently reported by the chain's other branches. Nothing
                  vanishes.                                      FALSE POSITIVE

    ⇒ A PREFIX VARIABLE IS A CLAIM ABOUT A FAMILY; A WHOLE-NAME VARIABLE IS A
      CHOICE BETWEEN MEMBERS. The suffix is what tells them apart, and it is the
      difference between a real hole and a loud gate nobody can satisfy -- the
      remedy (d) prescribes is UNAVAILABLE at a whole-name site: `$preName`'s
      selector is branch-local, and a column-0 loop would declare `O3.C1` NOT RUN
      on the very runs where another branch ASSERTS it.
    """
    prefix: set[str] = set()
    whole: set[str] = set()
    for name in names:
        if not name.startswith("$"):
            continue
        vm = re.match(r"^(\$[A-Za-z0-9_]+)(\S*)", name)
        if not vm:
            continue
        (prefix if vm.group(2) else whole).add(vm.group(1))
    return prefix, whole


def audit(text: str, label: str) -> tuple[list[str], int, int, list[str]]:
    """Return (failures, chains, distinct clause keys, clause-(d) exclusions)."""
    lines = text.split("\n")
    resolved, params = resolve_vars(lines)
    armed = unconditional_arm_declarations(lines, resolved)
    excluded: set[str] = set()   # clause (d)'s whole-name vars, PRINTED not hidden
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

        # ⛔ CLAUSE (d) -- THE ARM AXIS. Clauses (a) and (b) join on the SCENE,
        # and they are sound there. A clause name built from `$v = if (..)
        # { 'A' } elseif (..) { 'B' } else { 'C' }` has a SECOND axis under
        # them: exactly ONE arm exists per run, so the other N-1 arms' keys are
        # emitted NOWHERE -- not PASS, not FAIL, not NOT RUN, which is the
        # condition clause (a) exists to forbid, one axis in.
        #   ⇒ AND (a)/(b) CANNOT SEE IT, BY CONSTRUCTION: `keys_of` takes the
        #     union of every arm on the emitting side AND on the declaring
        #     side, so `covers()` compares a set against itself and passes
        #     whichever arm ran. `keys_of`'s own comment calls that union "safe
        #     in both directions" -- TRUE of clause (b)'s axis, and it is the
        #     sentence that stopped anyone asking about this one.
        #   ⇒ MEASURED on the real subject before this clause existed: the
        #     gate printed OK while 24 of its 53 clause keys were structurally
        #     absent from every single run. Ruled in STATUS-flask.md 65 (jas)
        #     from desk row LZ, which is flask's ask 1.
        pfx, whole = name_vars(names_in(lines, i, end, _EMIT))
        # ⛔ `whole - pfx`, NOT `whole`. `Add-NotRun "$o4Prefix gesture"` has a
        # SPACE after the identifier, so the same variable lands in BOTH sets --
        # and its first run put $o4Prefix on the EXCLUSION list it is the whole
        # subject of. EVER USED AS A PREFIX ⇒ A FAMILY VARIABLE: one prefixed use
        # renames a family whatever else the variable also does, so the
        # classification is a MAX over uses, never a per-use verdict.
        excluded.update(w for w in (whole - pfx)
                        if len(resolved.get(w, set())) > 1)
        for var in sorted(pfx):
            arms = resolved.get(var, set())
            if len(arms) < 2:
                continue
            if any(arms <= a for a in armed):
                continue
            failures.append(
                f"{where}: `{cond}` builds clause names from {var}, which takes "
                f"ONE of {', '.join(sorted(arms))} per run, so the other "
                f"{len(arms) - 1} arm(s) are emitted NOWHERE -- not PASS, not "
                f"FAIL, not NOT RUN. Clause (d). Declare them once and "
                f"unconditionally, at column 0, in the idiom this file already "
                f"uses: `foreach ($a in @({', '.join(repr(str(x)) for x in sorted(arms))}) "
                f"| Where-Object {{ $_ -ne {var} }}) {{ Add-NotRun \"$a <clause>\" "
                f"'...' }}`."
            )

    return failures, chains, len(all_keys), sorted(excluded)


def run_live() -> int:
    if not SUBJECT.exists():
        print(f"REFUSED: {SUBJECT} does not exist", file=sys.stderr)
        return 2
    text = SUBJECT.read_text(encoding="utf-8-sig")
    failures, chains, keys, excluded = audit(text, SUBJECT.name)

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

    # ⛔ CLAUSE (d)'s EXCLUSIONS ARE PRINTED ON BOTH VERDICTS, NEVER ONLY ON THE
    # RED. A quiet exclusion is the same shape as the defect this gate exists
    # for: a clause examined by nothing, with nothing saying so. The line is
    # ASCII because the Windows console is cp1252 and this gate has died on the
    # success path once already, after every check had passed.
    note = ("" if not excluded else
            f"\n  clause (d) EXCLUDED {len(excluded)} whole-name variable(s) "
            f"({', '.join(excluded)}): each picks ONE clause name rather than "
            f"renaming a family, and every name it can take is reported by "
            f"another branch. This is a BOUNDARY, printed so it is auditable; "
            f"see name_vars() for why the remedy (d) prescribes does not fit them.")

    if failures:
        print("FAIL: a clause that examines nothing must SAY SO\n", file=sys.stderr)
        for f in dict.fromkeys(failures):  # one line per distinct finding
            print(f"  * {f}\n", file=sys.stderr)
        if note:
            print(note.strip(), file=sys.stderr)
        return 1

    print(f"OK: {chains} scene chain(s), {keys} clause key(s); every clause a "
          f"chain can emit is declared on the path taken when its scene does not "
          f"match, and every arm-selected family declares its unselected arms"
          f"{note}")
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

# ⛔⛔ THIS FIXTURE WAS `_GOOD_VAR`, AND IT WAS THE ONE THAT CERTIFIED THE
# DEFECT. It stood in this list as "a runtime prefix resolved from its
# assignment", expecting CLEAN, from the day the variable resolver was written
# until 2026-09-14 -- and its name is why: it is ACCURATE about the thing it
# tests (resolution) and silent about the thing it blesses (a family whose
# unselected arms are emitted nowhere). Every run of the self-test since then
# has asserted that this shape is fine.
#   ⇒ A FIXTURE'S NAME IS ITS SCOPE, AND A FIXTURE NAMED FOR WHAT IT TESTS
#     CANNOT WARN YOU ABOUT WHAT IT ACCEPTS. Renamed, moved to the RED arms, and
#     kept byte-identical so the record is legible.
_BAD_ARMS_UNDECLARED = """$o4Prefix = if ($HandEmpty) { 'O4.C1' } else { 'O4' }
if ($Scene -ne 'pointer') {
    Add-NotRun "$o4Prefix gesture" "this run is scene '$Scene'"
} else {
    Add-Assert -Name "$o4Prefix.1 pointer" -Verdict 'PASS' -Detail 'x'
}
"""

# The same subject WITH the arm-declaration loop -- the shape clause (d) asks
# for, in the subject's own idiom (column-0 `foreach`, array literal piped to
# `Where-Object`, both already in the file 6 and 24 times).
_GOOD_ARMS_DECLARED = """$o4Prefix = if ($HandEmpty) { 'O4.C1' } else { 'O4' }
foreach ($otherArm in @('O4', 'O4.C1') | Where-Object { $_ -ne $o4Prefix }) {
    Add-NotRun "$otherArm gesture" "this run's arm is '$o4Prefix'"
}
if ($Scene -ne 'pointer') {
    Add-NotRun "$o4Prefix gesture" "this run is scene '$Scene'"
} else {
    Add-Assert -Name "$o4Prefix.1 pointer" -Verdict 'PASS' -Detail 'x'
}
"""

# ⭐ THE FALSE POSITIVE CLAUSE (d) FOUND ON ITS OWN FIRST RED, kept as a GREEN
# arm so the discriminator can never be quietly widened back. `$preName` is a
# WHOLE clause name chosen between two clauses the chain reports independently;
# nothing vanishes, and the remedy (d) prescribes is unavailable here because
# the selector is branch-local. Built from the real file's lines 202-211.
_GOOD_WHOLE_NAME = """if ($Scene -ne 'stall') {
    Add-NotRun 'O3.3 Responding' "this run is scene '$Scene'"
    Add-NotRun 'O3.C1 oracle-liveness control' "this run is scene '$Scene'"
} else {
    $preName = if ($uiStallMs -gt 0) { 'O3.C1 oracle-liveness control' } else { 'O3.3 Responding' }
    Add-NotRun $preName 'no window handle in session 1'
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


# ⛔⛔ THE FOUR NEAR-MISSES OF THE EVIDENCE READER, AND ALL FOUR ARE HERE
# BECAUSE A MUTATION PASS FOUND THEM MISSING. `unconditional_arm_declarations`
# tests FOUR things -- column 0, at least two arms, an `Add-NotRun` inside, and
# the arms COVERING the family -- and the first fixture set exercised only the
# case where all four hold. Four mutants survived, one per condition.
#   ⇒ 🔑 A FIRST WITNESS DOES NOT WITNESS PARAMETERS. The loop had an arm the
#     moment `_GOOD_ARMS_DECLARED` existed, and every knob inside it was still
#     free. When a construct's hole closes, put its PARAMETERS on the census
#     list rather than off it.
_BAD_ARMS_INDENTED = """$o4Prefix = if ($HandEmpty) { 'O4.C1' } else { 'O4' }
if ($Hand) {
  foreach ($otherArm in @('O4', 'O4.C1') | Where-Object { $_ -ne $o4Prefix }) {
      Add-NotRun "$otherArm gesture" "this run's arm is '$o4Prefix'"
  }
}
if ($Scene -ne 'pointer') {
    Add-NotRun "$o4Prefix gesture" "this run is scene '$Scene'"
} else {
    Add-Assert -Name "$o4Prefix.1 pointer" -Verdict 'PASS' -Detail 'x'
}
"""

_BAD_ARMS_NO_NOTRUN = """$o4Prefix = if ($HandEmpty) { 'O4.C1' } else { 'O4' }
foreach ($otherArm in @('O4', 'O4.C1') | Where-Object { $_ -ne $o4Prefix }) {
    Write-Host "the other arm is $otherArm"
}
if ($Scene -ne 'pointer') {
    Add-NotRun "$o4Prefix gesture" "this run is scene '$Scene'"
} else {
    Add-Assert -Name "$o4Prefix.1 pointer" -Verdict 'PASS' -Detail 'x'
}
"""

_BAD_ARMS_PARTIAL = """$o4Prefix = if ($HandEmpty) { 'O4.C1' } elseif ($synth) { 'O4.C2' } else { 'O4' }
foreach ($otherArm in @('O4', 'O4.C1') | Where-Object { $_ -ne $o4Prefix }) {
    Add-NotRun "$otherArm gesture" "this run's arm is '$o4Prefix'"
}
if ($Scene -ne 'pointer') {
    Add-NotRun "$o4Prefix gesture" "this run is scene '$Scene'"
} else {
    Add-Assert -Name "$o4Prefix.1 pointer" -Verdict 'PASS' -Detail 'x'
}
"""

_BAD_ARMS_ONE_LITERAL = """$o4Prefix = if ($HandEmpty) { 'O4.C1' } else { 'O4' }
foreach ($otherArm in @('O4') | Where-Object { $_ -ne $o4Prefix }) {
    Add-NotRun "$otherArm gesture" "this run's arm is '$o4Prefix'"
}
if ($Scene -ne 'pointer') {
    Add-NotRun "$o4Prefix gesture" "this run is scene '$Scene'"
} else {
    Add-Assert -Name "$o4Prefix.1 pointer" -Verdict 'PASS' -Detail 'x'
}
"""


def self_test() -> int:
    # ⛔ THE FIFTH FIELD IS THE EXPECTED EXCLUSION LIST, AND IT EXISTS BECAUSE A
    # MUTANT SURVIVED WITHOUT IT. `excluded` reaches the reader only through a
    # printed note, so a mutant that put the SUBJECT of clause (d) onto the
    # exclusion list changed no verdict and survived every arm. A clean/dirty
    # assertion cannot see a list's CONTENTS -- assert the list.
    arms: list[tuple[str, str, bool, str, list[str]]] = [
        ("a negated guard whose first branch declares", _GOOD_NE, True, "", []),
        ("a family declaration covering its dotted children", _GOOD_FAMILY, True, "", []),
        ("a positive guard with no else at all", _BAD_NO_DEFAULT, False, "NO default path", []),
        ("a chain whose default path misses one clause", _BAD_UNDECLARED, False, "Clause (b)", []),
        ("an arm-selected family with its arms declared", _GOOD_ARMS_DECLARED, True, "", []),
        ("an arm-selected family whose arms vanish", _BAD_ARMS_UNDECLARED, False, "Clause (d)", []),
        ("an arm loop nested inside an if is not evidence", _BAD_ARMS_INDENTED, False, "Clause (d)", []),
        ("an arm loop that declares nothing is not evidence", _BAD_ARMS_NO_NOTRUN, False, "Clause (d)", []),
        ("an arm loop covering SOME arms is not evidence", _BAD_ARMS_PARTIAL, False, "Clause (d)", []),
        ("a one-literal arm loop is not evidence", _BAD_ARMS_ONE_LITERAL, False, "Clause (d)", []),
        ("a whole-name variable is EXCLUDED, not red", _GOOD_WHOLE_NAME, True, "", ["$preName"]),
        ("a runtime name with no assignment refuses", _BAD_UNRESOLVABLE, False, "cannot resolve", []),
        ("a wrapper parameter is excluded, not refused", _GOOD_PARAM, True, "", []),
    ]

    passed = 0
    for name, src, want_clean, want_text, want_excluded in arms:
        failures, chains, _, excluded = audit(src, "fixture")
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
        if excluded != want_excluded:
            print(f"  SELF-TEST FAIL [{name}]: clause (d) excluded "
                  f"{excluded}, expected {want_excluded}. A variable on the "
                  f"exclusion list is one clause (d) will never rule on, so "
                  f"this list is an assertion and not a diagnostic.",
                  file=sys.stderr)
            return 1
        passed += 1

    # ⭐ THE ARM THAT IS ABOUT THE REAL FILE, NOT ABOUT A FIXTURE. Six synthetic
    # subjects prove the ARITHMETIC of the comparison; only this one proves the
    # gate can still find its subject. A floor's arm tests its arithmetic and
    # the number itself has no test at all -- so this drives the number.
    if SUBJECT.exists():
        real = SUBJECT.read_text(encoding="utf-8-sig")
        _, chains, keys, _ = audit(real, SUBJECT.name)
        if chains < MIN_CHAINS or keys < MIN_CLAUSE_KEYS:
            print(f"  SELF-TEST FAIL [floors are reachable on the real subject]: "
                  f"{chains} chain(s), {keys} key(s) against floors "
                  f"{MIN_CHAINS}/{MIN_CLAUSE_KEYS}", file=sys.stderr)
            return 1
        passed += 1

        # ⭐ CLAUSE (d) IS ANTI-VACUOUS ON THE REAL SUBJECT, AND THIS IS THE ONLY
        # ARM THAT CAN SAY SO. Nine synthetic subjects prove (d)'s ARITHMETIC;
        # none of them can notice that (d) has stopped finding a subject in the
        # file it exists for -- a renamed prefix, a reworked assignment, or a
        # regex that fell out of the file's style all report a clean pass.
        #   ⛔ THE FLOOR IS 1 AND IT IS NOT A TUNABLE COUNT. It asserts "(d) has
        #     a subject", which is the minimum meaningful value, so it cannot go
        #     stale upward the way a hand-typed 18 or 60 can. The COUNT of
        #     families is deliberately not pinned: this file gains and loses
        #     controls, and pinning it would red on ordinary growth.
        lines = real.split("\n")
        resolved, params = resolve_vars(lines)
        fams = set()
        for i, line in enumerate(lines):
            if not _SCENE_GUARD.match(line):
                continue
            pfx, _ = name_vars(names_in(lines, i, chain_extent(lines, i), _EMIT))
            fams |= {v for v in pfx if len(resolved.get(v, set())) > 1}
        armed = unconditional_arm_declarations(lines, resolved)
        # ⭐ DECLARED SURVIVING MUTANT, recorded rather than given a fake fixture.
        # Turning this `if` off survives the whole 15-arm suite, and that is the
        # DEFINITION of an anti-vacuity floor rather than a hole in the arms: it
        # guards a FUTURE state (the subject losing its arm-selected families),
        # and the only thing that can kill it is that state arriving. A synthetic
        # subject cannot drive it, because the branch reads the REAL file -- and
        # a fixture that made it die would be driving the check against itself.
        # The same is true of MIN_CHAINS and MIN_CLAUSE_KEYS above, which is why
        # it is recorded here in the same voice rather than quietly.
        if not fams:
            print("  SELF-TEST FAIL [clause (d) has a subject]: no arm-selected "
                  "clause family found in the real subject, so clause (d) "
                  "examined nothing and its silence means nothing",
                  file=sys.stderr)
            return 1
        if not armed:
            print("  SELF-TEST FAIL [clause (d)'s evidence is readable]: "
                  f"{len(fams)} arm-selected family(ies) but ZERO unconditional "
                  f"arm-declaration loops were parsed, so a green from clause (d) "
                  f"could only mean the evidence reader stopped matching",
                  file=sys.stderr)
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
