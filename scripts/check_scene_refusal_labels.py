#!/usr/bin/env python3
"""Every refusal a scene can return must NAME ITS SCENE, because a wait now ends
on one.

WHY THIS EXISTS
---------------
Until PR #145 the shell's refusal text had no machine reader at all: three
`git grep`s over every `.ps1` and `.py` returned prose comments and nothing
else. Relabelling was tidying, so it never got done.

#145 changed what those strings are. `harness_common.ps1`'s `$sceneSpec` gained
a `Refused` key, and two waits INSIDE a run -- the hand's `sb-doc-before.json`
dump wait and the stall's `STALL ARMED` wait -- now end on it. Measured on kenai
2026-09-10, one bad-document run per scene:

    hand dump wait      burned 90.2s   in `retained`, and in each of `pointer`'s
                                       three planned runs
    stall ARMED wait    burned 90.2s   the entire residual of a 98.2s run

⇒ AN UNLABELLED REFUSAL IS NOW A MEASURED 90 s, PER WAIT, PER RUN. That is what
makes this a gate rather than a style note.

⛔ AND THE DEFECT IT ACTUALLY CLOSES IS NOT THE LABELS -- IT IS THE JOIN. #145
populated `Refused` on the three scenes its author had measured, with the exact
literals those runs printed. That is correct and it is also a per-INSTANCE list:
`retained` can refuse six ways and two of its literals were listed, so the same
90 s came back on the other four with the table looking populated. A per-scene
CLASS pattern (`RUSTFAIL RETAINED `) covers all six -- but only if every one of
those six paths actually starts with `RETAINED `, which is a fact about the C#
that no PowerShell file can see. This gate is that fact.

WHAT IT ASSERTS
---------------
    (a) every scene the dispatcher RUNS has a declared prefix, and every
        declared prefix names a scene the dispatcher runs.                  RED
    (b) every `return false` in a scene method is governed by a resolvable
        `LastStatus` assignment.  ⛔ UNRESOLVABLE IS AN ERROR, NEVER A SKIP.  RED
    (c) every governing status begins with `<PREFIX> ` or `<PREFIX>'`.      RED
    (d) every `$sceneSpec` entry declares `Refused`, and every pattern in it
        is the scene's CLASS pattern `RUSTFAIL <PREFIX> `.                  RED
    (e) NO report site anywhere in the shell writes a LITERAL
        `RUSTFAIL <PREFIX> ` row. Only the dispatcher's terminal report may
        write that shape, and it does so as `RUSTFAIL {LastStatus}`.        RED

⛔ CLAUSE (e) IS THE INVARIANT THE COMPLETION CLASSIFIER RESTS ON, AND IT IS
HERE BECAUSE A DERIVATION IS ONLY AS SOUND AS THE INVARIANT IT ASSUMES.
`Get-SbSceneVerdict` reads REFUSED when `RUSTFAIL <PREFIX> ` appears ANYWHERE in
a run's region -- deliberately, so arrival order stops being an input. That is
sound only while the sole writer of that shape is the scene's own terminal
verdict. Measured once, by hand, before the classifier was written: of the ~40
report sites in the shell, none writes a literal scene prefix -- hash rows are
`RUSTFAIL A'`, op rows are `RUSTFAIL UNDO`/`REDO`, repaint rows are
`RUSTFAIL REPAINT-FAILED`, and the window's own rows are `RUSTFAIL SB_*`. ⇒ A
hand measurement of an invariant is a fact about one afternoon; this clause is
the fact about every afternoon after it, and the shell's OWN idiom is to prefix
a row with a name, so the next mid-run diagnostic is one edit away.

⛔ CLAUSE (b) IS THE ONE THAT PROTECTS THE OTHER THREE, AND IT IS WRITTEN FROM A
DEFECT IN THIS GATE'S OWN DRAFTS. Two earlier censuses of the same question --
one in `STATUS-flask.md` §39, one written the morning this gate landed -- both
resolved a bare `return false` by walking back to the NEAREST preceding
`LastStatus`. A backward walk always finds one, so it has no failure mode: it
silently attributed `if (!SyntheticDrag(...)) { return false; }` to the SUCCESS
status three lines above it and counted the path as labelled. The §39 census
reported 42 paths in 9 methods with 7 unlabelled; this reader finds 44 paths in
10 (`Benchmark` is dispatched and is not named `Render*`) and 20 unlabelled.
⇒ A CENSUS WHOSE RESOLVER CANNOT FAIL REPORTS THE ANSWER ITS FILTER ALLOWS.
Here the resolver refuses by name, and the refusal is a finding.

⛔ THE PREFIX TABLE IS DECLARED, NOT DERIVED, AND THAT IS A DECISION. Nine of
the ten prefixes are the scene name uppercased; `selection-marquee` writes
`SELECTION`, in six places, from before the rename. Deriving would force
`SELECTION-MARQUEE FAILED:` on six correct rows to satisfy a rule nobody reads,
and a derivation that needs one exception is a table with the exception hidden
inside it. So the table is written out, and clause (a) is what keeps it honest:
a scene added to the dispatcher with no prefix REDS.

WHAT IT DOES NOT COVER
----------------------
* Refusals reported by `_report` DIRECTLY rather than through a `return false`
  that reaches the dispatcher's terminal `_report(ok ? ...)`. The dispatcher's
  own two arms (`selection` renamed, and an unrecognised name) are of that
  shape. They are refusals of the SCENE NAME, before any scene runs, so no
  scene's wait can be waiting on them -- there is nothing for a per-scene
  pattern to cover. Said out loud so the next head widens deliberately.
* Whether a labelled refusal is REACHED. That is a run on the box, not a text
  gate, and `harness_selftest.ps1` arms the reader that consumes these labels.
* Clause (e) reads LITERALS ONLY. `_report($"RUSTFAIL {expr} ...")` -- the
  prefix arriving from an interpolation hole -- is invisible to it, and today
  every such hole resolves to something that is not a scene name (`LastStatus`,
  an exception type, a `REPAINT` row, an `undo`/`redo` label uppercased). That
  bound is stated rather than hidden: a hole is where the next violation would
  come from, and no text gate can see through one. What the clause DOES cover is
  the shape a person writes by hand, which is the shape the shell already uses
  everywhere else.
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

DISPATCH_METHOD = "ApplySceneInner"

# scene -> the prefix its every refusal must carry. Declared, not derived; see
# the module docstring for why, and clause (a) for what keeps it current.
PREFIX = {
    "benchmark": "BENCHMARK",
    "goldens": "GOLDENS",
    "document": "DOCUMENT",
    "selection-marquee": "SELECTION",
    "retained": "RETAINED",
    "stall": "STALL",
    "pointer": "POINTER",
    "stay": "STAY",
    "abi": "ABI",
    "app": "APP",
}

# ⛔ ANTI-VACUITY FLOORS, ON THE PARSER AND NOT ON THE TREE. Every clause here
# is "for each X, assert Y", and an empty X passes all of them. These are the
# counts at the time of writing minus a margin: they catch a regex that stopped
# matching or a method recogniser that stopped recognising, which is how a gate
# of this shape goes silently blind. They are NOT derived from each other -- a
# floor of "as many paths as methods" is met by a parser returning zero twice.
MIN_ARMS = 8
MIN_PATHS = 34
MIN_TABLE_ENTRIES = 8

_SCENE_ARM = re.compile(r'string\.Equals\(\s*scene\s*,\s*"([^"]+)"')
_ARM_RUNS = re.compile(r"\bok\s*=\s*(\w+)\s*\(\s*\)\s*;")
_RETURN_FALSE = re.compile(r"\breturn\s+false\s*;")
_LAST_STATUS = re.compile(r"^\s*LastStatus\s*=")
_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')

_TABLE_DECL = re.compile(r"^\s*\$sceneSpec\s*=\s*@\{", re.M)
_TABLE_KEY = re.compile(r"^(\s*)'([^']+)'\s*=\s*@\{", re.M)
_REFUSED_KEY = re.compile(r"^\s*Refused\s*=\s*@\((.*?)\)\s*$", re.M | re.S)
_PS_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')


class Refuse(Exception):
    """The gate could not read its subject. Never a pass."""


def read_dispatch(lexed: cs.Lexed) -> dict[str, str]:
    """`{scene: method}` for the arms that RUN a scene.

    The scene NAME is read from `decommented` (it is string payload) and the
    method from `code` (an arm that merely mentions a method in prose is not a
    dispatch). The two views share one index space, so this is not a seam.
    """
    bs = cs.blocks(lexed.code)
    out: dict[str, str] = {}
    for b in bs:
        enclosing = cs.enclosing_method(bs, b.head_start)
        if enclosing is None or enclosing.method != DISPATCH_METHOD:
            continue
        m = _SCENE_ARM.search(lexed.decommented[b.head_start : b.body_start])
        if not m:
            continue
        runs = _ARM_RUNS.search(lexed.code[b.body_start : b.body_end])
        if runs:
            out[m.group(1)] = runs.group(1)
    if len(out) < MIN_ARMS:
        raise Refuse(
            f"the dispatcher yielded {len(out)} scene arms, below the floor of "
            f"{MIN_ARMS}. `{DISPATCH_METHOD}` was found, so this is a reader "
            "failure, not an empty shell -- every clause below would pass over "
            "nothing"
        )
    return out


def governing_status(lexed: cs.Lexed, bs: list[cs.Block], at: int) -> str | None:
    """The `LastStatus = ...` statement governing the `return false` at `at`.

    ⛔ THE INNERMOST ENCLOSING BLOCK IS THE WHOLE OF THE SEARCH, AND THE
    STATEMENT MUST BE THE LAST ONE BEFORE THE RETURN. Anything looser is the
    backward walk this gate's docstring is about: it cannot fail, so it reports
    a label for a path that has none. `None` here is a FINDING.
    """
    inner = cs.enclosing_blocks(bs, at)
    if not inner:
        return None
    block = inner[0]
    region = lexed.code[block.body_start + 1 : at]
    end = region.rfind(";")
    if end < 0:
        return None                      # nothing precedes it in its block
    start = max(region.rfind(";", 0, end), region.rfind("{", 0, end),
                region.rfind("}", 0, end)) + 1
    stmt_lo = block.body_start + 1 + start
    stmt_hi = block.body_start + 1 + end + 1
    if not _LAST_STATUS.match(lexed.code[stmt_lo:stmt_hi]):
        return None
    return lexed.decommented[stmt_lo:stmt_hi]


def read_paths(lexed: cs.Lexed, dispatch: dict[str, str]) -> tuple[list, list]:
    """`(resolved, unresolved)` refusal paths across every dispatched scene.

    `resolved` rows are `(scene, line, first-literal)`; `unresolved` rows are
    `(scene, method, line)`.
    """
    bs = cs.blocks(lexed.code)
    bodies = {}
    for b in bs:
        if b.method and b.method in set(dispatch.values()):
            # the OUTERMOST block for a method name is its body
            if b.method not in bodies or b.body_start < bodies[b.method].body_start:
                bodies[b.method] = b
    missing = sorted(set(dispatch.values()) - set(bodies))
    if missing:
        raise Refuse(
            "the dispatcher runs " + ", ".join(missing) + " and no method body "
            "of that name was recognised. A scene whose body cannot be found "
            "contributes zero refusal paths, which reads exactly like a scene "
            "that cannot refuse"
        )
    resolved, unresolved = [], []
    for scene, method in sorted(dispatch.items()):
        body = bodies[method]
        for m in _RETURN_FALSE.finditer(lexed.code[body.body_start : body.body_end]):
            at = body.body_start + m.start()
            line = lexed.line_of(at)
            stmt = governing_status(lexed, bs, at)
            if stmt is None:
                unresolved.append((scene, method, line))
                continue
            lit = _LITERAL.search(stmt)
            resolved.append((scene, line, lit.group(1) if lit else ""))
    total = len(resolved) + len(unresolved)
    if total < MIN_PATHS:
        raise Refuse(
            f"{total} `return false` paths across {len(dispatch)} scene methods, "
            f"below the floor of {MIN_PATHS}. The scenes did not lose their "
            "refusals; the reader lost them"
        )
    return resolved, unresolved


MIN_REPORT_SITES = 25

_REPORT_CALL = re.compile(r"\b_?[Rr]eport\s*\(")


def read_report_sites(lexed: cs.Lexed) -> list[tuple[int, str]]:
    """`(line, first string literal)` for every report call in the file.

    The call is found in `code` (so a `Report(` inside a comment or a diagnostic
    string is not a call) and the literal is read from `decommented` (so the
    payload survives). One index space, so this is not a seam.
    """
    out: list[tuple[int, str]] = []
    for m in _REPORT_CALL.finditer(lexed.code):
        depth, end = 0, None
        for j in range(m.end() - 1, len(lexed.code)):
            if lexed.code[j] == "(":
                depth += 1
            elif lexed.code[j] == ")":
                depth -= 1
                if depth == 0:
                    end = j
                    break
        if end is None:
            continue
        lit = _LITERAL.search(lexed.decommented[m.end() : end])
        out.append((lexed.line_of(m.start()), lit.group(1) if lit else ""))
    if len(out) < MIN_REPORT_SITES:
        raise Refuse(
            f"{len(out)} report site(s) found, below the floor of "
            f"{MIN_REPORT_SITES}. Clause (e) would pass over almost nothing -- "
            "the call pattern stopped matching, it is not that the shell "
            "stopped reporting"
        )
    return out


def read_table() -> tuple[dict[str, list[str]], Path, dict[str, int]]:
    """`({scene: Refused patterns}, file, {scene: line})` from the ONE table.

    A scene with no `Refused` key maps to `[]`, which clause (d) reds. That is
    deliberate: an ABSENT key is what every defect in this family has looked
    like, and an absence is not a decision anyone can review.
    """
    found = []
    for path in sorted(SHELL.glob("*.ps1")):
        text = path.read_text(encoding="utf-8-sig")
        for m in _TABLE_DECL.finditer(text):
            found.append((path, text.count("\n", 0, m.start()) + 1, text, m.end() - 1))
    if len(found) != 1:
        raise Refuse(
            f"$sceneSpec is defined {len(found)} times across {SHELL}/*.ps1; "
            "exactly one is readable. `check_scene_tables.py` clause (d) owns "
            "that finding -- this gate cannot proceed on an ambiguous table"
        )
    path, line0, text, open_at = found[0]
    depth = 0
    for j in range(open_at, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                region = text[open_at : j + 1]
                break
    else:
        raise Refuse(f"the $sceneSpec at {path.name}:{line0} is never closed")

    keys = list(_TABLE_KEY.finditer(region))
    if len(keys) < MIN_TABLE_ENTRIES:
        raise Refuse(
            f"{len(keys)} entries read from $sceneSpec, below the floor of "
            f"{MIN_TABLE_ENTRIES} -- the key pattern stopped matching"
        )
    out, lines = {}, {}
    for i, m in enumerate(keys):
        scene = m.group(2)
        stop = keys[i + 1].start() if i + 1 < len(keys) else len(region)
        entry = region[m.start() : stop]
        lines[scene] = line0 + region.count("\n", 0, m.start())
        rm = _REFUSED_KEY.search(entry)
        out[scene] = _PS_LITERAL.findall(rm.group(1)) if rm else []
    return out, path, lines


def _rel(path: Path) -> str:
    """Repo-relative when it is in the repo, and the bare path when it is not.

    The self-test points `CANVAS`/`SHELL` at a scratch directory, and a
    `relative_to` that throws there would make every clause unreachable from the
    arms that exist to drive them.
    """
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def check() -> list[str]:
    """Every finding, as `file:line` prose. Empty means the four clauses hold."""
    lexed = cs.lex(CANVAS.read_text(encoding="utf-8"))
    dispatch = read_dispatch(lexed)
    resolved, unresolved = read_paths(lexed, dispatch)
    table, table_path, table_lines = read_table()
    sites = read_report_sites(lexed)
    rel = _rel(CANVAS)
    trel = _rel(table_path)
    out: list[str] = []

    # (a) the prefix table and the dispatcher name the same scenes.
    for scene in sorted(set(dispatch) - set(PREFIX)):
        out.append(
            f"{rel}: the dispatcher runs scene '{scene}' and PREFIX declares no "
            "prefix for it, so clause (c) would pass over every one of its "
            "refusals. Add it to PREFIX in this gate"
        )
    for scene in sorted(set(PREFIX) - set(dispatch)):
        out.append(
            f"scripts/{Path(__file__).name}: PREFIX declares '{scene}' and the "
            "dispatcher runs no such scene -- a prefix for a retired scene is a "
            "rule with no subject"
        )

    # (b) every refusal path resolves. UNRESOLVABLE IS AN ERROR, NEVER A SKIP.
    for scene, method, line in unresolved:
        out.append(
            f"{rel}:{line}: this `return false` in {method} (scene '{scene}') is "
            "not governed by a `LastStatus` assignment in its own block, so the "
            "status it refuses with is set somewhere this gate cannot read -- "
            "most often by a callee. Set it at the call site the way the file "
            f"already does (`LastStatus = $\"{PREFIX.get(scene, '<PREFIX>')} "
            'FAILED: {LastStatus}"`), so the row names the scene that stopped'
        )

    # (c) every governing status carries its scene's prefix.
    for scene, line, text in sorted(resolved, key=lambda r: r[1]):
        want = PREFIX.get(scene)
        if want is None:
            continue                      # already reported by clause (a)
        if text.startswith(want + " ") or text.startswith(want + "'"):
            continue
        shown = text[:56] + ("..." if len(text) > 56 else "")
        out.append(
            f"{rel}:{line}: scene '{scene}' refuses with \"{shown}\", which does "
            f"not begin with '{want} '. A wait inside a run ends on "
            f"`RUSTFAIL {want} `, so this path is invisible to it and burns the "
            "full 90 s with its own diagnosis already in the log"
        )

    # (d) the shell's Refused patterns are the CLASS pattern, for every scene.
    for scene in sorted(table):
        want = PREFIX.get(scene)
        if want is None:
            continue                      # clause (a) owns an unknown scene
        klass = f"RUSTFAIL {want} "
        line = table_lines[scene]
        if not table[scene]:
            out.append(
                f"{trel}:{line}: scene '{scene}' declares no `Refused` key. Every "
                "entry needs one: an absent key is what this family of defects "
                f"has looked like every time. Write `Refused = @(\"{klass}\")`"
            )
            continue
        for pat in table[scene]:
            if pat != klass:
                out.append(
                    f"{trel}:{line}: scene '{scene}' declares the refusal pattern "
                    f"\"{pat}\", which is not its class pattern \"{klass}\". A "
                    "per-instance pattern covers the refusals someone measured "
                    "and silently misses the rest; clause (c) is what makes the "
                    "class pattern cover all of them"
                )

    # (e) no report site writes a LITERAL scene-prefixed RUSTFAIL row.
    for line, lit in sites:
        for scene, want in sorted(PREFIX.items()):
            if lit.startswith(f"RUSTFAIL {want} "):
                out.append(
                    f"{rel}:{line}: this report writes a literal "
                    f"\"RUSTFAIL {want} \" row, and only scene '{scene}'s own "
                    "terminal verdict may write that shape. The completion "
                    "classifier reads it as the scene REFUSING, anywhere in the "
                    "run's region and regardless of ordering -- so a mid-run "
                    "diagnostic in this shape turns a healthy run's verdict "
                    "FAIL. Name the row for what it reports, not for the scene"
                )
    return out


def _summary() -> str:
    lexed = cs.lex(CANVAS.read_text(encoding="utf-8"))
    dispatch = read_dispatch(lexed)
    resolved, unresolved = read_paths(lexed, dispatch)
    table, _p, _l = read_table()
    declared = sum(1 for s in table if table[s])
    return (f"{len(dispatch)} scenes · {len(resolved) + len(unresolved)} refusal "
            f"paths ({len(unresolved)} unresolved) · {declared}/{len(table)} table "
            f"entries declare Refused · {len(read_report_sites(lexed))} report sites")


# --------------------------------------------------------------------------
# SELF-TEST
# --------------------------------------------------------------------------

def _run_on(cs_text: str, ps_text: str, tmp: Path) -> list[str]:
    global CANVAS, SHELL
    keep_c, keep_s = CANVAS, SHELL
    # ⛔ `newline=""` IS NOT GATE APPEASEMENT HERE. This gate's Windows lane
    # writes these fixtures and then reads them back through the same readers
    # that read the real tree; a text-mode write would put CRLF into them on
    # that platform only, and the arms would be driving a different subject
    # from the one they drive here.
    (tmp / "Canvas.cs").write_text(cs_text, encoding="utf-8", newline="")
    (tmp / "harness_common.ps1").write_text(ps_text, encoding="utf-8", newline="")
    CANVAS, SHELL = tmp / "Canvas.cs", tmp
    try:
        return check()
    finally:
        CANVAS, SHELL = keep_c, keep_s


def self_test() -> int:
    import tempfile

    def canvas(body_extra: str = "", swap: str = '"RETAINED FAILED: nope"') -> str:
        arms = "\n".join(
            f'            else if (string.Equals(scene, "{s}", StringComparison.Ordinal))\n'
            f"            {{\n                ok = Render_{s.replace('-', '_')}();\n            }}"
            for s in PREFIX
        )
        # ⛔ THREE REPORT CALLS PER METHOD, SO THE FIXTURE CLEARS CLAUSE (e)'s
        # OWN FLOOR. A fixture that refuses the floor would make every arm
        # below unreachable, and the arms would report that as a pass.
        methods = "\n".join(
            f"    private bool Render_{s.replace('-', '_')}()\n    {{\n"
            f'        if (x) {{ LastStatus = "{PREFIX[s]} FAILED: a"; return false; }}\n'
            f'        if (y) {{ LastStatus = "{PREFIX[s]} FAILED: b"; return false; }}\n'
            f'        if (z) {{ LastStatus = "{PREFIX[s]} FAILED: c"; return false; }}\n'
            f'        if (w) {{ LastStatus = "{PREFIX[s]} FAILED: d"; return false; }}\n'
            f'        _report("REPAINT {s} one");\n'
            f'        _report($"RUSTOK {PREFIX[s]} row=1");\n'
            f'        _report("RUSTFAIL A\' surface=1");\n'
            "        return true;\n    }"
            for s in PREFIX
        )
        methods = methods.replace('LastStatus = "RETAINED FAILED: a"', f"LastStatus = {swap}")
        return ("class C\n{\n    private void ApplySceneInner(string scene)\n    {\n"
                "        bool ok;\n        if (false) { }\n" + arms + "\n    }\n"
                + methods + body_extra + "\n}\n")

    def table(refused_of=lambda s: f'@("RUSTFAIL {PREFIX[s]} ")') -> str:
        rows = "\n".join(
            f"    '{s}' = @{{\n        Done    = @('x')\n"
            f"        Refused = {refused_of(s)}\n        Label   = 'l'\n    }}"
            for s in PREFIX
        )
        return "$sceneSpec = @{\n" + rows + "\n}\n"

    arms_run = 0
    fails = 0
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)

        def arm(name: str, findings: list[str], want: int, needle: str | None = None):
            nonlocal arms_run, fails
            arms_run += 1
            ok = len(findings) == want and (needle is None or
                                            any(needle in f for f in findings))
            if not ok:
                print(f"  FAIL {name}: {len(findings)} findings, wanted {want}"
                      + (f" containing {needle!r}" if needle else ""))
                for f in findings:
                    print(f"        {f}")
                fails += 1
            else:
                print(f"  ok   {name}")

        # 1. NEGATIVE CONTROL -- a well-formed pair is silent. Without this the
        #    gate is indistinguishable from one that accuses everything.
        arm("clean tree is silent", _run_on(canvas(), table(), tmp), 0)

        # 2. clause (c): an unprefixed status.
        arm("(c) unprefixed status reds",
            _run_on(canvas(swap='"no swapchain"'), table(), tmp), 1, "does not begin with")

        # 3. clause (c): the RIGHT prefix on the WRONG scene stays red -- the
        #    mutant that a substring test would let through.
        arm("(c) another scene's prefix reds",
            _run_on(canvas(swap='"POINTER FAILED: a"'), table(), tmp), 1, "'RETAINED '")

        # 4. clause (b): a bare `return false` is a FINDING, never a skip. This
        #    is the arm the two earlier hand censuses would both have failed.
        arm("(b) callee-owned refusal reds",
            _run_on(canvas().replace('if (x) { LastStatus = "STALL FAILED: a"; return false; }',
                                     "if (!Callee()) { return false; }"), table(), tmp),
            1, "not governed by a `LastStatus`")

        # 5. clause (b): a bare `return false` after ANOTHER statement is not
        #    rescued by the assignment further up its own block.
        arm("(b) a non-adjacent assignment does not resolve it",
            _run_on(canvas().replace('if (x) { LastStatus = "APP FAILED: a"; return false; }',
                                     '{ LastStatus = "APP FAILED: a"; Foo(); return false; }'),
                    table(), tmp), 1, "not governed by a `LastStatus`")

        # 6. clause (d): an absent Refused key.
        ps_missing = table().replace(
            f"        Refused = @(\"RUSTFAIL {PREFIX['stay']} \")\n", "", 1)
        arm("(d) absent Refused key reds", _run_on(canvas(), ps_missing, tmp), 1,
            "declares no `Refused` key")

        # 7. clause (d): a per-INSTANCE pattern reds -- the #145 shape, and the
        #    reason this gate exists rather than a one-off relabel.
        ps_inst = table().replace(
            f"@(\"RUSTFAIL {PREFIX['retained']} \")",
            '@("RUSTFAIL NOT RUN: uncalibrated SVG ")', 1)
        arm("(d) per-instance pattern reds", _run_on(canvas(), ps_inst, tmp), 1,
            "is not its class pattern")

        # 8. clause (a): a scene with no declared prefix.
        cs_new = canvas().replace(
            '        if (false) { }\n',
            '        if (false) { }\n'
            '            else if (string.Equals(scene, "novel", StringComparison.Ordinal))\n'
            "            {\n                ok = Render_novel();\n            }\n")
        cs_new = cs_new.replace("\n}\n", "\n    private bool Render_novel()\n    {\n"
                                '        if (x) { LastStatus = "NOVEL FAILED"; return false; }\n'
                                "        return true;\n    }\n}\n")
        arm("(a) an undeclared scene reds", _run_on(cs_new, table(), tmp), 1,
            "declares no prefix for it")

        # 9. clause (e): a report site writing a LITERAL scene-prefixed RUSTFAIL
        #    row. This is the invariant the completion classifier rests on, and
        #    the mutant is the shape the shell's own idiom invites.
        arm("(e) a literal RUSTFAIL <SCENE> report reds",
            _run_on(canvas().replace('_report("REPAINT stall one");',
                                     '_report("RUSTFAIL STALL mid-run diagnostic");'),
                    table(), tmp), 1, "only scene 'stall's own")

        # 10. clause (e) NEGATIVE CONTROL, and it is the one that stops the
        #     clause becoming "no row may mention a scene". A SUCCESS row with
        #     the same prefix is legitimate and must stay silent.
        arm("(e) CONTROL -- a RUSTOK row with the same prefix is silent",
            _run_on(canvas(), table(), tmp), 0)

        # 11. clause (e) SECOND CONTROL: a RUSTFAIL row that is not a scene
        #     prefix -- the hash rows the shell really writes.
        arm("(e) CONTROL -- RUSTFAIL on a non-scene label is silent",
            _run_on(canvas().replace('_report("REPAINT goldens one");',
                                     '_report("RUSTFAIL A-MUT surface=2");'),
                    table(), tmp), 0)

        # 12. ANTI-VACUITY: a reader that finds nothing REFUSES, it does not pass.
        arms_run += 1
        try:
            _run_on("class C { private void ApplySceneInner(string s) { } }", table(), tmp)
            print("  FAIL vacuous subject: the gate passed over an empty dispatcher")
            fails += 1
        except Refuse:
            print("  ok   vacuous subject refuses rather than passing")

        # 13. THE FLOORS DRIVEN AGAINST THE REAL FILE, not a fixture -- the arm
        #     that a floor's arithmetic self-test does not give you.
        arms_run += 1
        lexed = cs.lex((keep := ROOT / "prototypes/sb_winui/Canvas.cs")
                       .read_text(encoding="utf-8"))
        real_arms = len(read_dispatch(lexed))
        real_sites = len(read_report_sites(lexed))
        if real_arms >= MIN_ARMS and real_sites >= MIN_REPORT_SITES:
            print(f"  ok   floors hold against the real tree ({real_arms} arms >= "
                  f"{MIN_ARMS}, {real_sites} report sites >= {MIN_REPORT_SITES})")
        else:
            print(f"  FAIL floors: real tree has {real_arms} arms (floor {MIN_ARMS}) "
                  f"and {real_sites} report sites (floor {MIN_REPORT_SITES})")
            fails += 1

    print(f"\n{arms_run} arms driven, {fails} failed")
    return 1 if fails else 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    try:
        findings = check()
    except Refuse as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 2
    if findings:
        print(f"⛔ {len(findings)} finding(s) -- {_summary()}", file=sys.stderr)
        for f in findings:
            print(f"   {f}", file=sys.stderr)
        return 1
    print(f"OK — {_summary()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
