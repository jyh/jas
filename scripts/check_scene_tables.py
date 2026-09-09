#!/usr/bin/env python3
"""The shell's scenes and the harness's completion rows are ONE list, and until
this gate nothing joined them.

WHY THIS EXISTS
---------------
Wave 1 added two scenes to the WinUI shell -- `abi` (W3's consumer) and `app`
(W4's entry). Both landed green: the shell compiles, `check_shell_abi_bindings`
passes, `check_shell_no_interpreter` passes, CI is 31/31. Neither was added to
`verify_window.ps1`'s completion-row table, and NOTHING ANYWHERE COULD SEE THAT.

Measured on kenai 2026-09-09 by the seat with the only hands on the box:

  * `sitting.ps1 -Scene abi` ran the DEFAULT NINE-RUN SITTING -- `-Scene` binds
    only under `-Stay` -- so the operator got ~15 minutes of the wrong sitting
    and a log with no `ABI` row in it, which reads as "the abi scene printed
    nothing".
  * `sitting.ps1 -Scenes abi` reached the scene and was REFUSED BY THE HARNESS:
    "scene 'abi' is not one this harness knows how to wait for."
  * `sitting.ps1 -Stay -Scene app` waits for `RUSTOK STAY pid=`; the app scene
    writes `RUSTOK APP pid=`. 90 s timeout on a HEALTHY app, window left alive.

⇒ THREE COMMANDS, THREE WAYS TO READ A WORKING APP AS BROKEN. The rows had to
be produced by a scratchpad script calling the harness's own primitives instead.

⛔ AND THE POINT OF A GATE HERE RATHER THAN THREE REPAIRS: the repairs are one
afternoon and they close THESE two scenes. The MECHANISM is that a scene's name
is written down in three independent places -- the shell's dispatch, the
harness's wait table, and the shell's own help string -- and adding an arm to
one of them is a complete, reviewable, green change. Every future scene has the
same hole, and the failure is silent in the direction that costs a sitting on a
box nobody else can reach.

WHAT IT ASSERTS
---------------
Three lists, joined:

  DISPATCH  `Canvas.ApplySceneInner`'s `string.Equals(scene, "<name>", ...)`
            arms that RUN a scene (the arm assigns `ok`), read from CODE via
            `csharp_source` so a name inside a comment or a diagnostic string
            is not a scene. Arms that do NOT assign `ok` are named REFUSALS
            (`selection`, kept deliberately after the rename) and are excluded.
  TABLE     the `$sceneSpec` hashtable's keys -- the scenes the harness knows a
            completion row for.
  HELP      the names the shell's own "is not recognised" message lists.

  (a) every DISPATCH scene has a TABLE entry.                            RED
  (b) every TABLE entry names a DISPATCH scene.                          RED
  (c) HELP names exactly the DISPATCH set.                               RED
  (d) `$sceneSpec` is defined EXACTLY ONCE across the harness.           RED

Clause (a) is flask's two findings. Clause (b) is their mirror and it is the
one that would have caught the `selection` -> `selection-marquee` rename from
the other side. Clause (c) is the cheapest of the four and the likeliest to
rot: it is a hand-typed list of ten names inside the function whose job is to
tell an operator what they may type.

⛔ CLAUSE (a) HAS NO EXEMPTION LIST, ON PURPOSE. A scene the harness should not
drive is still a decision, and the place to record it is a TABLE ENTRY saying
so -- not an absence, which is what every one of these defects looked like. A
holding scene (`stay`, `app`) belongs in the table with the row it holds on and
is kept out of the DEFAULT scene list instead; that is `stay`'s shape already
and `app` now mirrors it.

WHAT IT DOES NOT COVER
----------------------
* `sitting.ps1`'s `$svgScenes` -- the list of scenes that open a document -- is
  NOT joined here. It is keyed by what the CALLER TYPED, not by what the shell
  dispatches (`o6` is a pseudo-scene expanding to two `retained` runs), so the
  two lists are not the same population and a join would be wrong. `sitting.ps1`
  has its own runtime guard that refuses at the cause when a planned run needs a
  document and none was resolved. Named so the absence reads as a decision.
* WHETHER A `Done` PATTERN MATCHES THE ROW THE SCENE ACTUALLY WRITES. This gate
  asserts an entry EXISTS, never that it is correct -- an entry whose pattern is
  a typo passes here and times out on the box. That is the harness self-test's
  and the run's job; it is stated because "the scene is in the table" and "the
  harness can wait for it" are different claims and only the first is checked.
* Scenes reached by any route other than `ApplySceneInner`'s dispatch. There is
  no such route today; the floors below are what turn a parser miss into a RED.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, Path(__file__).resolve().parent.as_posix())

import csharp_source as cs  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SHELL = ROOT / "prototypes" / "sb_winui"
CANVAS = SHELL / "Canvas.cs"

# The dispatch method. Named rather than searched for, because "the scenes are
# dispatched somewhere in this file" is exactly the claim a parser miss makes
# true by accident.
DISPATCH_METHOD = "ApplySceneInner"

# ⛔ ANTI-VACUITY FLOORS. Clauses (a) and (b) are set comparisons, and two empty
# sets agree. A regex that stopped matching -- a renamed parameter, a rewritten
# dispatch, a `$sceneSpec` that became a function -- would make this gate print
# OK over nothing at all, which is the failure mode it exists to catch one level
# up. These are the counts at the time of writing MINUS a margin: they are a
# floor on the PARSER, not a pin on the tree, so a scene added or retired does
# not touch them.
#
# ⛔ AND THEY ARE NOT DERIVED FROM EACH OTHER. Flooring the table at "as many as
# the dispatch" would be satisfied by a parser that returned zero for both.
MIN_DISPATCH = 8
MIN_TABLE = 8
MIN_HELP = 8

_SCENE_ARM = re.compile(r'string\.Equals\(\s*scene\s*,\s*"([^"]+)"')
_ASSIGNS_OK = re.compile(r"\bok\s*=")
_HELP = re.compile(r"is not recognised; use (.*?)\"\s*;", re.S)
_HELP_NAME = re.compile(r"'([a-z][a-z0-9-]*)'")
_TABLE_DECL = re.compile(r"^\s*\$sceneSpec\s*=\s*@\{", re.M)
_TABLE_KEY = re.compile(r"^\s*'([^']+)'\s*=\s*@\{", re.M)


class Refuse(Exception):
    """The gate could not read its subject. Never a pass."""


def _brace_region(text: str, open_at: int) -> str:
    """The `@{ ... }` starting at the brace `open_at`, balanced.

    ⛔ NOT A LINE RANGE AND NOT A NON-GREEDY MATCH. The table's values are
    themselves hashtables, so the first `}` closes an entry, not the table.
    """
    depth = 0
    for j in range(open_at, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[open_at : j + 1]
    raise Refuse(
        f"the $sceneSpec hashtable opened at offset {open_at} is never closed -- "
        "the table could not be read, so its keys are unknown"
    )


def read_dispatch(lexed: cs.Lexed) -> tuple[dict[str, int], dict[str, int]]:
    """`({scene: line}, {refused-scene: line})` from the shell's dispatch.

    ⛔ THE HEAD IS READ FROM `decommented` AND THE BODY FROM `code`, and the two
    views share one index space so this is not a seam. The head needs the string
    LITERAL (the scene's name is the payload); the body must not, or a scene
    name printed inside a diagnostic would read as an assignment to `ok`.
    """
    blocks = cs.blocks(lexed.code)
    run: dict[str, int] = {}
    refused: dict[str, int] = {}
    for b in blocks:
        enclosing = cs.enclosing_method(blocks, b.head_start)
        if enclosing is None or enclosing.method != DISPATCH_METHOD:
            continue
        m = _SCENE_ARM.search(lexed.decommented[b.head_start : b.body_start])
        if not m:
            continue
        name = m.group(1)
        line = lexed.line_of(b.head_start)
        body = lexed.code[b.body_start : b.body_end]
        if _ASSIGNS_OK.search(body):
            run[name] = line
        else:
            refused[name] = line
    return run, refused


def read_help(lexed: cs.Lexed) -> tuple[list[str], int]:
    """The names the shell's own 'not recognised' message lists, and its line."""
    m = _HELP.search(lexed.decommented)
    if m is None:
        raise Refuse(
            "the shell's 'is not recognised; use ...' message was not found in "
            f"{CANVAS.name} -- clause (c) has no subject and would pass over "
            "nothing. If the message was reworded, reword this pattern with it"
        )
    return _HELP_NAME.findall(m.group(1)), lexed.line_of(m.start())


def read_table() -> tuple[dict[str, int], Path]:
    """`({scene: line}, file)` from the ONE `$sceneSpec` in the harness.

    Clause (d) lives here: the table is searched for across every harness
    script rather than read from a fixed file, so MOVING it is allowed and
    DUPLICATING it is not. Two tables is the defect this gate is about, one
    level up -- the shell and the harness disagreeing because each has its own
    copy of the list.
    """
    found: list[tuple[Path, int, str]] = []
    for path in sorted(SHELL.glob("*.ps1")):
        text = path.read_text(encoding="utf-8-sig")
        for m in _TABLE_DECL.finditer(text):
            line = text.count("\n", 0, m.start()) + 1
            found.append((path, line, _brace_region(text, m.end() - 1)))
    if not found:
        raise Refuse(
            f"no `$sceneSpec = @{{` in any of {SHELL}/*.ps1 -- the harness's "
            "completion-row table could not be found, so clauses (a) and (b) "
            "would compare the shell against an empty set and pass"
        )
    if len(found) > 1:
        where = ", ".join(f"{p.name}:{ln}" for p, ln, _ in found)
        raise Refuse(
            f"$sceneSpec is defined {len(found)} times ({where}). Clause (d): a "
            "second copy of the scene table is the defect this gate exists to "
            "catch, arriving inside the harness itself -- the two would drift "
            "and each would look complete"
        )
    path, _line, region = found[0]
    keys: dict[str, int] = {}
    for m in _TABLE_KEY.finditer(region):
        offset = region.count("\n", 0, m.start())
        keys[m.group(1)] = _line + offset
    return keys, path


def check() -> list[str]:
    """Every finding, as `file:line` prose. Empty means the three lists agree."""
    lexed = cs.lex(CANVAS.read_text(encoding="utf-8"))
    run, refused = read_dispatch(lexed)
    help_names, help_line = read_help(lexed)
    table, table_path = read_table()

    if len(run) < MIN_DISPATCH:
        raise Refuse(
            f"only {len(run)} runnable scene(s) parsed out of "
            f"{CANVAS.name}::{DISPATCH_METHOD} (floor {MIN_DISPATCH}). The "
            "dispatch reader has stopped matching; every clause below would be "
            "vacuous. Refused loudly rather than passing over nothing"
        )
    if len(table) < MIN_TABLE:
        raise Refuse(
            f"only {len(table)} scene(s) parsed out of $sceneSpec in "
            f"{table_path.name} (floor {MIN_TABLE}). The table reader has "
            "stopped matching"
        )
    if len(help_names) < MIN_HELP:
        raise Refuse(
            f"only {len(help_names)} scene name(s) parsed out of the shell's "
            f"help message at {CANVAS.name}:{help_line} (floor {MIN_HELP})"
        )

    findings: list[str] = []

    for name in sorted(set(run) - set(table)):
        findings.append(
            f"(a) {CANVAS.name}:{run[name]}: the shell dispatches scene "
            f"'{name}' and {table_path.name}'s $sceneSpec has no entry for it. "
            "The harness cannot wait for it: `-Scenes " + name + "` is REFUSED "
            "by name, and a `-Stay -Scene " + name + "` waits for another "
            "scene's row until it times out on a healthy app"
        )
    for name in sorted(set(table) - set(run)):
        findings.append(
            f"(b) {table_path.name}:{table[name]}: $sceneSpec has an entry for "
            f"scene '{name}' and the shell does not dispatch it"
            + (
                f" -- it is a NAMED REFUSAL at {CANVAS.name}:{refused[name]}, so "
                "the harness would wait for a completion row that arm is written "
                "never to write"
                if name in refused
                else f" at all ({CANVAS.name}::{DISPATCH_METHOD} has no arm for "
                "it). A completion row for a scene that does not exist reads as "
                "coverage"
            )
        )

    missing_help = sorted(set(run) - set(help_names))
    stale_help = sorted(set(help_names) - set(run))
    if missing_help:
        findings.append(
            f"(c) {CANVAS.name}:{help_line}: the shell's own 'not recognised' "
            f"message does not name {', '.join(missing_help)}, which it "
            "dispatches. An operator refused by that message cannot discover "
            "the scene from it"
        )
    if stale_help:
        findings.append(
            f"(c) {CANVAS.name}:{help_line}: the shell's own 'not recognised' "
            f"message names {', '.join(stale_help)}, which it does not "
            "dispatch. The message would send an operator to a scene that "
            "refuses them with the same message"
        )
    return findings


def _summary() -> str:
    lexed = cs.lex(CANVAS.read_text(encoding="utf-8"))
    run, refused = read_dispatch(lexed)
    table, table_path = read_table()
    help_names, _ = read_help(lexed)
    return (
        f"{len(run)} dispatched scene(s), {len(refused)} named refusal(s), "
        f"{len(table)} completion-row entr(ies) in {table_path.name}, "
        f"{len(help_names)} name(s) in the shell's help message"
    )


# ---------------------------------------------------------------------------
# SELF-TEST
# ---------------------------------------------------------------------------
#
# ⛔ THE READER IS DRIVEN BEFORE ANY CLAUSE IS. A set comparison between two
# readers is only as good as the readers, and both of these can fail toward
# EMPTY, which is the direction that prints OK.

_FIXTURE_CS = '''
class Canvas
{
    private void ApplySceneInner(string scene)
    {
        bool ok;
        if (string.Equals(scene, "benchmark", StringComparison.OrdinalIgnoreCase))
        {
            ok = Benchmark();
        }
        else if (string.Equals(scene, "abi", StringComparison.OrdinalIgnoreCase))
        {
            ok = RenderAbiProbe();
        }
        else if (string.Equals(scene, "selection", StringComparison.OrdinalIgnoreCase))
        {
            // A named refusal: it assigns no `ok` and writes its own row.
            LastStatus = "renamed";
            _report($"RUSTFAIL {LastStatus}");
            return;
        }
        else
        {
            LastStatus = $"SB_SCENE='{scene}' is not recognised; use 'benchmark', "
                       + "'abi'";
            _report($"RUSTFAIL {LastStatus}");
            return;
        }
        _report(ok ? $"RUSTOK {LastStatus}" : $"RUSTFAIL {LastStatus}");
    }

    private void Decoy()
    {
        // ⛔ THE DECOY IS THE ARM THAT MATTERS. Both of these read as dispatch
        // arms to a reader that does not scope to the method or does not blank
        // strings: one is in ANOTHER method, one is a scene name inside a
        // diagnostic STRING. Neither is a scene.
        if (string.Equals(scene, "goldens", StringComparison.OrdinalIgnoreCase))
        {
            ok = NotADispatch();
        }
        _report("string.Equals(scene, \\"phantom\\", StringComparison.OrdinalIgnoreCase) ok = 1");
    }
}
'''

_FIXTURE_PS1 = """
$sceneSpec = @{
    'benchmark' = @{
        Done    = @("RUSTOK BENCHMARK frames=")
        Label   = "the BENCHMARK row"
        Timeout = 150
    }
    'abi' = @{
        Done    = @("RUSTOK ABI menu-items=")
        Label   = "the ABI row"
        Timeout = 120
    }
}
"""


def _fixture_findings(cs_text: str, ps_text: str, tmp: Path) -> list[str]:
    """Run every clause over a fixture pair, with the floors lowered to fit."""
    global CANVAS, SHELL, MIN_DISPATCH, MIN_TABLE, MIN_HELP
    keep = (CANVAS, SHELL, MIN_DISPATCH, MIN_TABLE, MIN_HELP)
    try:
        CANVAS = tmp / "Canvas.cs"
        SHELL = tmp
        MIN_DISPATCH = MIN_TABLE = MIN_HELP = 1
        CANVAS.write_text(cs_text, encoding="utf-8")
        (tmp / "harness.ps1").write_text(ps_text, encoding="utf-8")
        return check()
    finally:
        CANVAS, SHELL, MIN_DISPATCH, MIN_TABLE, MIN_HELP = keep


def self_test() -> int:
    import tempfile

    failures: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)

        # (1) THE READER, FIRST. The compliant fixture must parse to exactly the
        #     two runnable scenes, one refusal, and NEITHER decoy.
        lexed = cs.lex(_FIXTURE_CS)
        run, refused = read_dispatch(lexed)
        if set(run) != {"benchmark", "abi"}:
            failures.append(f"1a dispatch reader returned {sorted(run)}, want benchmark+abi")
        if set(refused) != {"selection"}:
            failures.append(f"1b refusal reader returned {sorted(refused)}, want selection")
        if "goldens" in run or "phantom" in run:
            failures.append("1c a decoy was read as a dispatched scene")

        # (2) A COMPLIANT PAIR IS CLEAN. Without this every red below could be
        #     the gate refusing everything.
        clean = _fixture_findings(_FIXTURE_CS, _FIXTURE_PS1, tmp)
        if clean:
            failures.append(f"2 the compliant fixture was not clean: {clean}")

        # (3) CLAUSE (a): a dispatched scene with no table entry.
        f = _fixture_findings(_FIXTURE_CS, _FIXTURE_PS1.replace(
            """    'abi' = @{
        Done    = @("RUSTOK ABI menu-items=")
        Label   = "the ABI row"
        Timeout = 120
    }
""", ""), tmp)
        if not any(x.startswith("(a)") and "'abi'" in x for x in f):
            failures.append(f"3 clause (a) did not fire on a missing table entry: {f}")

        # (4) CLAUSE (b): a table entry for a scene the shell does not dispatch.
        f = _fixture_findings(_FIXTURE_CS, _FIXTURE_PS1.replace(
            "    'abi' = @{", "    'ghost' = @{\n        Done = @('x')\n    }\n    'abi' = @{", 1), tmp)
        if not any(x.startswith("(b)") and "'ghost'" in x for x in f):
            failures.append(f"4 clause (b) did not fire on a table entry with no scene: {f}")

        # (5) ⭐ CLAUSE (b) ON A NAMED REFUSAL, AND IT IS THE ARM THAT SEPARATES
        #     THE TWO HALVES OF (b). A table entry for `selection` is not merely
        #     "a scene that does not exist" -- the arm EXISTS and is written
        #     never to complete, so the harness would wait out its full timeout.
        #     The finding must say which of the two it is.
        f = _fixture_findings(_FIXTURE_CS, _FIXTURE_PS1.replace(
            "    'abi' = @{", "    'selection' = @{\n        Done = @('x')\n    }\n    'abi' = @{", 1), tmp)
        hit = [x for x in f if x.startswith("(b)") and "'selection'" in x]
        if not hit:
            failures.append(f"5a clause (b) did not fire on a refused scene: {f}")
        elif "NAMED REFUSAL" not in hit[0]:
            failures.append(f"5b clause (b) fired but did not name the refusal: {hit[0]}")

        # (6) CLAUSE (c), BOTH DIRECTIONS. A help message missing a real scene,
        #     and one naming a scene that is gone.
        f = _fixture_findings(_FIXTURE_CS.replace("""use 'benchmark', "
                       + "'abi'""", "use 'benchmark'"), _FIXTURE_PS1, tmp)
        if not any(x.startswith("(c)") and "does not name abi" in x for x in f):
            failures.append(f"6a clause (c) did not fire on a help message missing a scene: {f}")
        f = _fixture_findings(_FIXTURE_CS.replace("""'abi'""" + '"', """'abi', 'ghost'""" + '"'),
                              _FIXTURE_PS1, tmp)
        if not any(x.startswith("(c)") and "names ghost" in x for x in f):
            failures.append(f"6b clause (c) did not fire on a stale help name: {f}")

        # (7) CLAUSE (d): two tables REFUSE, they do not merge. A gate that
        #     unioned them would be green on the exact state it exists to ban.
        try:
            two = tmp / "two"
            two.mkdir(exist_ok=True)
            (two / "a.ps1").write_text(_FIXTURE_PS1, encoding="utf-8")
            (two / "b.ps1").write_text(_FIXTURE_PS1, encoding="utf-8")
            keep_shell = SHELL
            globals()["SHELL"] = two
            try:
                read_table()
            finally:
                globals()["SHELL"] = keep_shell
        except Refuse as exc:
            if "defined 2 times" not in str(exc):
                failures.append(f"7 the two-table refusal did not name the count: {exc}")
        else:
            failures.append("7 two $sceneSpec definitions did not refuse")

        # (8) THE FLOORS, DRIVEN. Each must refuse rather than pass over an
        #     empty population -- the direction this whole gate is about.
        for label, cs_text, ps_text, needle in (
            ("8a dispatch floor", _FIXTURE_CS.replace("scene, ", "sceneX, "),
             _FIXTURE_PS1, "runnable scene(s) parsed"),
            ("8b table floor", _FIXTURE_CS,
             _FIXTURE_PS1.replace("$sceneSpec", "$otherSpec"), "could not be found"),
            ("8c help floor", _FIXTURE_CS.replace("is not recognised; use", "is unknown; use"),
             _FIXTURE_PS1, "message was not found"),
        ):
            try:
                _fixture_findings(cs_text, ps_text, tmp)
            except Refuse as exc:
                if needle not in str(exc):
                    failures.append(f"{label}: refusal did not name its cause: {exc}")
            else:
                failures.append(f"{label}: the floor did not fire")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print(
        "check_scene_tables SELF-TEST: OK (the dispatch READER is driven first and "
        "rejects both decoys -- an arm in another method and a scene name inside a "
        "diagnostic string -- so every clause below is non-vacuous; a compliant "
        "shell/harness pair is clean; clause (a) reds on a dispatched scene with no "
        "completion row; clause (b) reds BOTH on a table entry for a scene that does "
        "not exist and on one for a NAMED REFUSAL, and says which; clause (c) reds in "
        "BOTH directions; clause (d) REFUSES on two $sceneSpec definitions instead of "
        "unioning them; and all three parser floors are driven and refuse by cause)")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    try:
        findings = check()
    except Refuse as exc:
        print(f"REFUSING: {exc}")
        return 1
    if findings:
        print("FAIL: the shell's scenes and the harness's completion rows disagree.")
        for f in findings:
            print(f"  {f}")
        print()
        print("A scene lives in three lists -- the shell's dispatch, the harness's")
        print("$sceneSpec, and the shell's own help message -- and adding an arm to")
        print("one of them is a complete, green, reviewable change. This gate is the")
        print("join. Add the completion row the scene finishes on; do not exempt it.")
        return 1
    print(f"check_scene_tables: OK ({_summary()})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
