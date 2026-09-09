#!/usr/bin/env python3
"""The WinUI shell MATERIALIZES the menubar. It must never EVALUATE one.

WHY THIS EXISTS
---------------
`prototypes/sb_winui/README.md:3-4` states the law the whole Windows lane rests
on: *"a materializer shell, not a third interpreter"*. The fleet already has
three interpreters (Rust `jas_dioxus`, Swift `JasSwift`, and the Python
reference); a fourth in C# would be a fourth conformance subject, against a
prime directive of exact functional equivalence across the ACTIVE ports.

The place that law is easiest to break is the menubar, and it breaks by being
CONVENIENT rather than by being wrong. The natural C# reflex is to author the
menu in XAML and hang handlers off it -- which re-authors `workspace/menubar.yaml`
(148 lines, 239 actions in `actions.yaml`) a second time, in a language with no
conformance corpus. Nothing about that reflex looks like a violation while it is
being typed.

WHAT IT ASSERTS -- TWO CLAUSES, AND THE SECOND IS WHAT EARNS THE FIRST
----------------------------------------------------------------------
Over `prototypes/sb_winui/*.cs` with comments and string-literal CONTENTS
blanked by `scripts/csharp_source.py`, plus `MainWindow.xaml`:

(a) THE BAN -- ZERO occurrences, in CODE, of the property accesses that mean the
    shell is reading a workspace context for itself: `active_document.`,
    `state.`, and the predicate keyword `enabled_when`.

(b) THE POSITIVE -- the shell HAS a materialized menubar: a `MenuBar` element in
    `MainWindow.xaml`, and a `jas_menu_state` call in the C#.

⛔ **(b) IS NOT DECORATION, AND WITHOUT IT (a) IS GREEN FOR THE WRONG REASON.**
A shell with no menubar at all satisfies the ban perfectly. That is a gate over
an empty population, which is the single most common defect shape in this
repository's own record: the ban would pass today, pass after someone deleted
the menubar, and pass on a shell that never had one. **The two clauses together
say "there is a menubar AND it is not evaluated here"; either alone says almost
nothing.**

⛔ WHY THE BAN MUST READ LEXED CODE AND NOT RAW TEXT. Measured on the tree at the
time this was written: the three banned forms occur **9 times** across
`Canvas.cs` and `JasCore.cs` and **0 times in code** -- every one of them is in a
comment or a string, and most of them are in the prose EXPLAINING THIS RULE. A
raw-text version of this gate would red on a fully compliant shell, and it would
red hardest on its own documentation. (Positive control on the same reading:
`JasCore.` occurs 81 times in code, so the lexer is not blanking everything.)

⛔⛔ THE LIVE ARM IS **NOT WIRED INTO CI**, DELIBERATELY, AND THIS IS THE PART A
READER MUST NOT SKIM
---------------------------------------------------------------------------
CI runs `--self-test` ONLY. **Clause (b) is RED on `main` today, by construction:
`MainWindow.xaml` is 59 lines and has no `MenuBar`.** Wiring the live arm now
would land a red gate over code nobody has written yet, and a red gate facing the
author of the code it judges is a gate that gets weakened.

⚠️ **SO THIS GATE IS CURRENTLY IN THE ONE STATE `check_lane_coverage.py` WARNS
ABOUT IN ITS OWN VOICE:** *"It checks that a script is INVOKED, not that it is
invoked correctly. A step that runs the gate with arguments that neuter it
passes here."* A self-test-only wiring is exactly such a step. The lane-coverage
green says this file is watched; it does not say the tree is.

⇒ **THAT IS WHY THE DEFERRAL IS MACHINE-CHECKED AND NOT WRITTEN DOWN AS AN
INTENTION.** `transcripts/CHECKER_RESIDUAL.md` carries an `expires-when` claim
that `MainWindow.xaml` LACKS `MenuBar`. The moment the shell grows one, that
precondition LAPSES, `check_deferral_expiry.py` REDS, and the live arm has to be
wired to make it green again. **The thing that turns this gate on is a failing
build, not somebody's memory of a row in a node list.**

WHAT IT DOES NOT COVER
----------------------
* A SHELL THAT HARD-CODES A VERDICT. `Save` written as always-enabled contains
  none of the banned forms and satisfies both clauses. Only the receipt row's
  `enabled=`/`disabled=` transition across an open can see that, and that is a
  runtime observable on the box, not a text property.
* WHICH ctx THE SHELL SUPPLIES. Handing `jas_menu_state` a ctx is REQUIRED (the
  merge is the design: the engine owns `active_document.*`, the shell owns
  session chrome), so a ctx JSON literal is correct and is invisible here
  anyway -- literal contents are blanked. This gate cannot tell a well-formed
  ctx from a nonsense one.
* INTERPOLATED-STRING HOLES are opaque payload to `csharp_source.py`. An
  `enabled_when` evaluated inside `$"{...}"` would be missed. That is the safe
  direction for a ban and it is named rather than hidden.
* THE OTHER PORTS. This is the C# shell alone. `workspace/menu_bar.rs` evaluates
  the same predicates in Dioxus and is SUPPOSED to -- it is an interpreter.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# `.as_posix()`, not `str()`: check_path_keying.py bans rendering a Path to text
# with `str()`, because it yields "/" here and "\\" on Windows.
sys.path.insert(0, Path(__file__).resolve().parent.as_posix())

import csharp_source  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SHELL = ROOT / "prototypes" / "sb_winui"
XAML = SHELL / "MainWindow.xaml"

# The property accesses that mean the shell is reading a workspace context for
# itself, plus the predicate keyword. THE TRAILING DOT IS PART OF THE BAN: the
# dot is what makes it a property access. `state` and `active_document` as bare
# words are ordinary English and appear all over the shell's prose; `state.` in
# code is the interpreter's grammar.
#
# ⛔ AND ANCHORED ON A WORD BOUNDARY, AND THAT IS A MEASURED DECISION, NOT A HABIT.
# A bare `state.` substring also matches `_state.` and `myState.` -- ordinary
# C# field access that has nothing to do with the interpreter's namespace. The
# ban is on the WORKSPACE CONTEXT SPELLING, so `\b` is what makes it that ban
# and not a ban on every identifier ending in "state".
#
# Measured before choosing: the shell today carries ZERO decoy-shaped
# identifiers, so this costs nothing now and is here for W4, which is the PR
# most likely to introduce a `_state`. Both directions are driven in the
# self-test -- `ctx.state.tab_count` reds, `_state.Foo` stays green -- because
# this seat has already paid for a counting pattern whose receiver assumption
# was never checked in both directions.
BANNED = (
    (r"\bactive_document\.", "active_document."),
    (r"\bstate\.", "state."),
    (r"\benabled_when\b", "enabled_when"),
)

# ANTI-VACUITY. A ban over an empty scan is green, and so is a ban whose lexer
# blanked the whole file. Both floors are DRIVEN in the self-test rather than
# asserted. Measured when written: 5 shell .cs files, ~81 `JasCore.` in code.
MIN_FILES = 3
MIN_CODE_CHARS = 20_000


WORKFLOW = ROOT / ".github" / "workflows" / "test.yml"
SELF = Path(__file__).name


class Refuse(Exception):
    """The gate could not measure its subject. Never a pass."""


def live_arm_wired(workflow: str) -> bool:
    """Does CI invoke this gate WITHOUT `--self-test` anywhere?

    A line naming this script and not carrying `--self-test` is the live arm.
    Textual on purpose: the same reading `check_lane_coverage.py` takes of the
    same file, and a gate that parsed YAML to answer a question about a `run:`
    body would be modelling more than it needs.
    """
    return any(
        SELF in line and "--self-test" not in line
        for line in workflow.splitlines()
    )


def deferral_lapsed(xaml: str | None, workflow: str | None) -> str | None:
    """⭐ THE MACHINE-CHECKED EXPIRY -- what turns this gate on without anyone
    remembering to.

    The live arm is deliberately unwired (see the header). That deferral has a
    PRECONDITION: the shell has no menubar, so clause (b) could only ever be red.
    **The moment the shell grows one, the precondition LAPSES** -- clause (b)
    becomes satisfiable, and a gate still running `--self-test` only is a gate
    whose green says nothing about the tree.

    ⛔ THIS IS WHY IT IS NOT A NOTE IN A NODE LIST. `check_lane_coverage.py` says
    of itself: *"It checks that a script is INVOKED, not that it is invoked
    correctly. A step that runs the gate with arguments that neuter it passes
    here."* A self-test-only wiring is exactly such a step, so lane coverage
    cannot see this and nothing else was watching it. Returns the finding, or
    None when the deferral still holds.
    """
    if xaml is None or workflow is None:
        return None
    if "MenuBar" not in xaml:
        return None          # the deferral HOLDS: there is still nothing to judge
    if live_arm_wired(workflow):
        return None          # the deferral was DISCHARGED: the live arm is on
    return (
        f"DEFERRAL LAPSED: {XAML.name} now has a `MenuBar`, so clause (b) is "
        f"satisfiable and this gate's live arm must be wired into "
        f"{WORKFLOW.name} -- add a `{SELF}` step WITHOUT `--self-test`. Until "
        f"then CI runs only the fixtures, and lane coverage cannot tell the "
        f"difference (it checks a script is INVOKED, not that it is invoked "
        f"meaningfully). This is W6, and it is now DUE")


def scan_ban(files: dict[str, str]) -> list[str]:
    """Clause (a): the banned forms, in CODE only."""
    findings = []
    for rel in sorted(files):
        code = csharp_source.lex(files[rel]).code
        for pattern, form in BANNED:
            for m in re.finditer(pattern, code):
                line = code[:m.start()].count("\n") + 1
                findings.append(
                    f"{rel}:{line}: `{form}` in CODE -- the shell is evaluating a "
                    f"workspace context. It must ask the core (`jas_menu_state`) "
                    f"and materialize the answer")
    return findings


def scan_positive(files: dict[str, str], xaml: str | None) -> list[str]:
    """Clause (b): there IS a materialized menubar to be un-evaluated."""
    findings = []
    if xaml is None:
        findings.append(
            f"{XAML.name} is not readable -- clause (b) cannot be measured, and an "
            f"unmeasurable positive must never read as satisfied")
        return findings
    if "MenuBar" not in xaml:
        findings.append(
            f"{XAML.name}: no `MenuBar` -- clause (b) FAILS. The ban in clause (a) "
            f"is satisfied by a shell with no menu at all, which is a gate over an "
            f"empty population; this clause is what makes the ban mean something")
    if not any("jas_menu_state" in csharp_source.lex(t).code for t in files.values()):
        findings.append(
            "no `jas_menu_state` call in shell CODE -- a MenuBar built without "
            "asking the core is an authored menubar, which is the exact defect "
            "clause (a) bans one spelling of")
    return findings


def _load() -> tuple[dict[str, str], str | None]:
    files = {}
    for p in sorted(SHELL.glob("*.cs")):
        files[p.relative_to(ROOT).as_posix()] = p.read_text(encoding="utf-8")
    if len(files) < MIN_FILES:
        raise Refuse(
            f"only {len(files)} .cs file(s) under {SHELL.name}/ (floor {MIN_FILES}); "
            f"a scan that found nothing is not a clean shell")
    total = sum(len(csharp_source.lex(t).code.strip()) for t in files.values())
    if total < MIN_CODE_CHARS:
        raise Refuse(
            f"only {total} char(s) of CODE survived lexing across {len(files)} file(s) "
            f"(floor {MIN_CODE_CHARS}). A lexer that blanked everything makes every "
            f"ban vacuous and every reading a zero")
    xaml = XAML.read_text(encoding="utf-8") if XAML.is_file() else None
    return files, xaml


# --------------------------------------------------------------------------
# self-test -- fixtures only, GREEN ON ANY TREE
#
# ⛔ THERE IS NO LIVE-TREE ARM IN HERE, AND THAT IS A DECISION. The live mode is
#    RED on `main` by construction (clause (b): no MenuBar) and green once W4
#    lands. An arm asserting either would have to be edited by the very PR it
#    judges, which makes its verdict a statement about the editor. The live red
#    is a RECEIPT in this PR; the live arm is wired by W6.
# --------------------------------------------------------------------------

_XAML_OK = '<Window><MenuBar x:Name="Menu" /><SwapChainPanel x:Name="Canvas" /></Window>'
_XAML_NO_MENU = '<Window><SwapChainPanel x:Name="Canvas" /></Window>'

# A compliant shell: it ASKS the core and materializes the answer.
_CS_OK = """
internal sealed class Canvas {
    private void RefreshMenu() {
        var json = JasCore.TakeString(JasCore.jas_menu_state(_engine, _ctx, _len));
        foreach (var row in Parse(json)) { Materialize(row); }
    }
}
"""


def self_test() -> int:
    failures: list[str] = []

    def files(cs: str) -> dict[str, str]:
        # Three files, because MIN_FILES is three and the arms must exercise the
        # gate rather than trip its floor.
        return {"a.cs": cs, "b.cs": "internal class B { }\n", "c.cs": "internal class C { }\n"}

    def run(cs: str, xaml: str | None = _XAML_OK) -> list[str]:
        f = files(cs)
        return scan_ban(f) + scan_positive(f, xaml)

    def green(label: str, cs: str, xaml: str | None = _XAML_OK):
        got = run(cs, xaml)
        if got:
            failures.append(f"{label}: expected clean, got {got}")

    def red(label: str, cs: str, needle: str, xaml: str | None = _XAML_OK):
        got = run(cs, xaml)
        if not any(needle in g for g in got):
            failures.append(f"{label}: expected a finding containing {needle!r}, got {got}")

    # (1) THE INSTRUMENT BEFORE THE SUBJECT. If the reader does not blank a
    #     comment, every "in a comment stays green" arm below is green for the
    #     wrong reason and proves nothing about this gate.
    probe = csharp_source.lex("var x = 1; // enabled_when\nvar s = \"state.\";\n")
    if "enabled_when" in probe.code or "state." in probe.code:
        failures.append("1 the reader did not blank a comment/string -- every later arm is void")
    if "var x = 1;" not in probe.code:
        failures.append("1 the reader blanked CODE too -- the arms would be vacuously green")

    # (2) The green control, and clause (b) is satisfied in it on purpose.
    green("2 a compliant shell", _CS_OK)

    # (3) Each banned form planted in CODE, separately. Separately, because one
    #     fixture carrying all three proves only that ONE of the three fires.
    red("3a active_document. in code",
        _CS_OK.replace("Materialize(row);", "if (ctx.active_document.can_undo) { }"),
        "`active_document.` in CODE")
    red("3b state. in code",
        _CS_OK.replace("Materialize(row);", "if (ctx.state.tab_count > 0) { }"),
        "`state.` in CODE")
    red("3c enabled_when in code",
        _CS_OK.replace("Materialize(row);", "var e = Eval(row.enabled_when);"),
        "`enabled_when` in CODE")

    # (4) ...and each one in a COMMENT stays green. This is not politeness: the
    #     real shell carries nine such occurrences, most of them in the prose
    #     explaining this very rule, so a raw-text gate reds on its own docs.
    for i, (_, form) in enumerate(BANNED):
        green(f"4{'abc'[i]} {form} in a comment",
              _CS_OK.replace("Materialize(row);", f"Materialize(row); // {form} here"))
        green(f"5{'abc'[i]} {form} in a string",
              _CS_OK.replace("Materialize(row);", f'Log("{form} here");'))

    # (6) ⭐ THE DECOY, IN BOTH DIRECTIONS. `_state.` is ordinary C# field access
    #     and must NOT red; `ctx.state.` must. An anchor tested in only one
    #     direction is an anchor nobody has shown to be doing anything.
    green("6a _state. is not the namespace",
          _CS_OK.replace("Materialize(row);", "_state.Refresh(); myState.Tick();"))
    red("6b ...and the anchor still catches the real form",
        _CS_OK.replace("Materialize(row);", "_state.Refresh(); if (ctx.state.tab_count > 0) { }"),
        "`state.` in CODE")

    # (7) CLAUSE (b), AND THIS IS THE ARM THAT MAKES CLAUSE (a) WORTH HAVING.
    #     The fixture is FULLY COMPLIANT with the ban and has no menubar: a
    #     ban-only gate calls this a pass, and it is a shell with no menu.
    if scan_ban(files(_CS_OK)):
        failures.append("7 the fixture must satisfy the BAN, or this arm tests two things at once")
    red("7 no MenuBar", _CS_OK, "no `MenuBar`", _XAML_NO_MENU)

    # (8) An unreadable XAML is a REFUSAL, never a satisfied positive.
    red("8 unreadable XAML", _CS_OK, "cannot be measured", None)

    # (9) A MenuBar built without asking the core is an AUTHORED menubar -- the
    #     defect clause (a) bans one spelling of, arriving by another door.
    red("9 MenuBar with no jas_menu_state",
        "internal sealed class Canvas { private void Build() { Menu.Items.Add(new X()); } }",
        "no `jas_menu_state` call")

    # (10) ⭐ THE DEFERRAL'S LOGIC, FIXTURED IN ALL THREE STATES BEFORE IT IS
    #      EVER APPLIED TO THE REAL TREE. This is the arm that makes W6 a
    #      failing build instead of somebody's memory, so it gets driven rather
    #      than trusted -- and a conditional tested in only the state it is
    #      currently in has been tested in the easy case.
    wired = "      - run: python scripts/check_shell_no_interpreter.py\n"
    unwired = "      - run: python scripts/check_shell_no_interpreter.py --self-test\n"

    if deferral_lapsed(_XAML_NO_MENU, unwired) is not None:
        failures.append("10a no MenuBar + unwired: the deferral must still HOLD (today's state)")
    if deferral_lapsed(_XAML_OK, wired + unwired) is not None:
        failures.append("10b MenuBar + wired: the deferral is DISCHARGED and must not fire")
    lapse = deferral_lapsed(_XAML_OK, unwired)
    if lapse is None or "DEFERRAL LAPSED" not in lapse:
        failures.append(f"10c MenuBar + unwired MUST fire -- this is W6 coming due; got {lapse!r}")
    # ...and the wired/unwired reader itself, both ways, because the whole arm
    # rests on it and `--self-test` is a SUBSTRING of the neutered invocation.
    if live_arm_wired(unwired):
        failures.append("10d a `--self-test` step must not count as the live arm")
    if not live_arm_wired(wired):
        failures.append("10e a bare invocation must count as the live arm")

    # (11) THE VACUITY FLOORS, DRIVEN. A floor nobody drives is arithmetic.
    for label, patch, needle in (
        ("11a file floor", {"MIN_FILES": 10_000}, ".cs file(s) under"),
        ("11b code floor", {"MIN_CODE_CHARS": 10_000_000}, "survived lexing"),
    ):
        original = {k: globals()[k] for k in patch}
        globals().update(patch)
        try:
            _load()
        except Refuse as exc:
            if needle not in str(exc):
                failures.append(f"{label}: refusal did not name its floor: {exc}")
        else:
            failures.append(f"{label}: the floor did not fire")
        finally:
            globals().update(original)

    # (12) ⛔ AND NOW THE ONE ARM THAT READS THE REAL TREE, WHICH IS THE WHOLE
    #      POINT AND IS NAMED SO IT IS NOT MISTAKEN FOR A FIXTURE. Everything
    #      above is green on any tree. This is green on any tree TOO -- except
    #      the single state where the shell has grown a menubar and CI is still
    #      running fixtures only. That state is W6 coming due, and CI runs
    #      `--self-test`, so this is where it gets caught.
    try:
        real_xaml = XAML.read_text(encoding="utf-8") if XAML.is_file() else None
        real_wf = WORKFLOW.read_text(encoding="utf-8") if WORKFLOW.is_file() else None
    except OSError as exc:
        failures.append(f"12 could not read the tree to check the deferral: {exc}")
    else:
        lapsed = deferral_lapsed(real_xaml, real_wf)
        if lapsed is not None:
            failures.append(f"12 {lapsed}")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print(
        "check_shell_no_interpreter SELF-TEST: OK (the READER is verified first -- it "
        "blanks comments and strings without blanking code, so every later arm is "
        "non-vacuous; a compliant shell is clean; all three banned forms red "
        "SEPARATELY in code and all three stay green in a comment and in a string; "
        "the `\\b` anchor is driven BOTH ways -- `_state.`/`myState.` green, "
        "`ctx.state.` red in the same fixture; clause (b) reds on a shell that "
        "SATISFIES the ban but has no MenuBar -- the arm that stops (a) being green "
        "over an empty population -- and on a MenuBar built without asking the core, "
        "and an unreadable XAML REFUSES rather than passing; both vacuity floors are "
        "DRIVEN; and the DEFERRAL is fixtured in all three states -- holds with no "
        "MenuBar, discharged when the live arm is wired, and FIRES on MenuBar + "
        "fixtures-only -- with the wired/unwired reader driven both ways, then "
        "applied to the real tree. NO live-tree arm for the SHELL: the live mode "
        "is red on main by construction (clause (b)) and is wired by W6)")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    try:
        files, xaml = _load()
    except Refuse as exc:
        print(f"REFUSING: {exc}")
        return 1
    findings = scan_ban(files) + scan_positive(files, xaml)
    if findings:
        print("FAIL: the WinUI shell is not a materializer.")
        for f in findings:
            print(f"  {f}")
        print()
        print("The shell asks the core (`jas_menu_state`) and materializes the answer.")
        print("It never evaluates an `enabled_when`, and it never authors a menubar.")
        print("⚠️ Clause (b) is EXPECTED to fail until W4 lands the app shell; the live")
        print("arm is wired by W6, and until then CI runs --self-test only.")
        return 1
    print(f"check_shell_no_interpreter: OK ({len(files)} shell file(s); no banned form "
          f"in code; a MenuBar exists and is fed by jas_menu_state)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
