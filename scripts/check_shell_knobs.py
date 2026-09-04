#!/usr/bin/env python3
"""O7: every knob the WinUI shell reads is documented, and every documented knob
is read.

WHY THIS EXISTS
---------------
F-1 was closed as "working as intended" -- `SB_SCENE_FINAL` is read at
`SwapChainHost.cs:637` and an unrecognised value is refused BY NAME at `:667`,
which is the right behaviour. What was NOT right is that a reader could not find
that out: at 3c8fddce `README.md` documents NONE of `SB_FRAMES`,
`SB_SCENE_HOLD` or `SB_SCENE_FINAL` (grep -> 0 hits). The close is therefore a
DOCUMENTATION act, and a documentation act that nothing gates rots on the first
knob added after it.

Two failure directions, and both are real here:

  * A knob READ and not documented. That is F-1's own shape, three times over,
    and it is how an operator runs an experiment whose inputs they cannot
    enumerate.
  * A knob DOCUMENTED and not read. That is the mirror, and it is worse in one
    way: the table looks maintained. `SB_SKIP_PAINT` is the live example --
    `README.md:116` and `:119` describe it in the "Historical" section and no
    line of the shell has read it since the cause was found.

And one shape that is neither, found by the freeze while renaming a scene:
`SB_SCENE=hold` (a VALUE of one knob) collided by prefix with `SB_SCENE_HOLD`
(a different knob entirely, `SwapChainHost.cs:630`). Nothing was wrong in
either line; the collision lived between them, which is exactly where a
per-line reader cannot look. The scene is `stall` now, and this gate is what
stops the next one from being named `final`.

WHAT IT ASSERTS
---------------
Census: every `Environment.GetEnvironmentVariable("<NAME>")` in
`prototypes/sb_winui/*.cs`, read from CODE only -- `//` and `/* */` comments
blanked, and a name that appears only inside a string literal is NOT a read
(`scripts/csharp_source.py`). The census is NOT `SB_`-only: `JAS_CORE_DLL`
(`JasCore.cs:321`) decides WHICH cdylib loads, which is the provenance question
F-2's law is about, and a knob table that omitted it would document the
experiment's settings while hiding which binary ran.

Then, against the knob table in `prototypes/sb_winui/README.md`:

  1. Every name in the census has a table row.                         RED
  2. Every table row names a variable read somewhere in the census.    RED
  3. PREFIX COLLISION: for each scene VALUE `v` listed in the `SB_SCENE` row,
     `SB_SCENE_<V>` (case-insensitively) must not be another knob's name.  RED
  4. `SB_*` tokens in README PROSE outside the knob-table SECTION are WARNs
     with `file:line`, never a red. The "Historical" section deliberately keeps
     `SB_SKIP_PAINT` as narrative, and a gate that reds on kept history is a
     gate someone deletes history to satisfy. (SECTION, not table: prose under
     the `Knobs` heading and beside its table is not warned about, because that
     is where the table's own explanation belongs.)

THE TABLE'S SHAPE, decided here because N6 writes the table against this gate:

    ## Knobs
    | knob | meaning | default | scene | kind |
    |---|---|---|---|---|
    | `SB_FRAMES` | frames the benchmark loop runs | `60` | `benchmark` | benchmark |

  * The heading is any ATX heading whose text begins `Knobs`. The table is the
    first markdown table under it, and the table REGION ends at the next
    heading of the same or higher level.
  * The five columns are required IN ORDER and by NAME. Extra columns to the
    right are allowed; the first five are the contract.
  * `kind` is a CLOSED vocabulary: `benchmark`, `interaction` or `provenance`.
    Closed so a typo reds instead of inventing a category. `provenance` exists
    for `JAS_CORE_DLL`, which is neither of the other two.
  * NO CELL MAY BE EMPTY. A row with a blank `default` documents the knob's
    existence and not its behaviour, which is the half F-1 already had.
  * The `SB_SCENE` row's `meaning` cell MUST list its accepted values as
    `backticked` tokens -- that list is the input to the prefix-collision
    clause, and a row with none makes clause 3 vacuous, so it REDS.

WHAT IT DOES NOT COVER
----------------------
* It is a DOCUMENTATION gate. It says nothing about whether the meaning column
  is true, whether the default matches the code's fallback, or whether the named
  scene is the one that reads the knob. A row that says the wrong thing in
  correct columns passes.
* The PowerShell harness (`sitting.ps1`, `run_4k_sweep.ps1`, `verify_window.ps1`)
  SETS knobs; the census reads C# only. A knob the harness sets and the shell
  never reads is invisible here, and a knob the harness sets under a typo'd name
  reaches clause 1 only via the shell's read of the correct name.
* Prose warnings are `SB_*` only. A `JAS_*` token in prose is not warned about,
  because `JAS_` names appear throughout the document for other reasons.
* Only `prototypes/sb_winui/README.md`. Knob names in other documents are
  neither checked nor warned.

RED ON `main` BY CONSTRUCTION: at 3c8fddce there is no knob table at all, so
all 11 knobs (18 read sites) are undocumented, and three prose warnings stand
(`README.md:89` SB_FULLSCREEN, `:116` and `:119` SB_SKIP_PAINT). Its LIVE arm is
wired into CI by N5b; only `--self-test` runs today.
"""

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys

# os.path, not str(Path): check_path_keying.py forbids rendering a Path to text
# because str(Path) yields backslashes on Windows.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from csharp_source import lex  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL_GLOB = "prototypes/sb_winui/*.cs"
README = "prototypes/sb_winui/README.md"

HEADING = re.compile(r"^(#{1,6})\s+(.*\S)\s*$")
KNOB_HEADING = re.compile(r"^Knobs\b")
COLUMNS = ("knob", "meaning", "default", "scene", "kind")
KINDS = ("benchmark", "interaction", "provenance")
SCENE_KNOB = "SB_SCENE"

ENV_CALL = re.compile(r"(?<![A-Za-z0-9_])Environment\s*\.\s*GetEnvironmentVariable\s*\(")
ENV_READ = re.compile(r"(?<![A-Za-z0-9_])Environment\s*\.\s*GetEnvironmentVariable\s*\(\s*\"([A-Za-z_][A-Za-z0-9_]*)\"\s*\)")
PROSE_TOKEN = re.compile(r"(?<![A-Za-z0-9_])SB_[A-Z0-9_]+")
BACKTICKED = re.compile(r"`([^`]+)`")
SCENE_VALUE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*$")


class Refuse(Exception):
    """The source cannot be decided statically. Refuse; never guess."""


# --------------------------------------------------------------------------
# the census
# --------------------------------------------------------------------------

def census(files: dict[str, str]) -> tuple[dict[str, list[str]], list[str]]:
    """{KNOB: [file:line, ...]}, plus refusals for non-literal reads."""
    reads: dict[str, list[str]] = {}
    refusals: list[str] = []
    for name, text in sorted(files.items()):
        lx = lex(text)
        literal_at = set()
        for m in ENV_READ.finditer(lx.decommented):
            if lx.in_string(m.start()):
                continue
            literal_at.add(m.start())
            reads.setdefault(m.group(1), []).append(f"{name}:{lx.line_of(m.start())}")
        for m in ENV_CALL.finditer(lx.code):
            if m.start() in literal_at:
                continue
            refusals.append(
                f"{name}:{lx.line_of(m.start())}: REFUSING to guess -- "
                f"`GetEnvironmentVariable(` here is not called with a single string "
                f"literal, so this gate cannot say which knob is being read and "
                f"cannot tell whether it is documented")
    return reads, refusals


# --------------------------------------------------------------------------
# the table
# --------------------------------------------------------------------------

def _cells(line: str) -> list[str]:
    body = line.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|"):
        body = body[:-1]
    return [c.strip() for c in body.split("|")]


def _is_separator(line: str) -> bool:
    return bool(re.fullmatch(r"\|?[\s:|-]*-[\s:|-]*\|?", line.strip())) and "-" in line


def parse_table(readme: str) -> tuple[dict, list[str]]:
    """({rows, header, region}, findings). `rows`: [(knob, cells, line)]."""
    findings: list[str] = []
    lines = readme.splitlines()

    start = level = None
    for i, line in enumerate(lines):
        m = HEADING.match(line)
        if m and KNOB_HEADING.match(m.group(2)):
            start, level = i, len(m.group(1))
            break
    if start is None:
        findings.append(
            f"{README}: NO knob-table heading. This gate looks for an ATX heading "
            f"whose text begins `Knobs`, followed by a markdown table with the "
            f"columns {' | '.join(COLUMNS)}. Without it every knob the shell reads "
            f"is undocumented (F-1) and clause 2 has no population at all")
        return {"rows": [], "header": [], "region": (0, 0)}, findings

    end = len(lines)
    for j in range(start + 1, len(lines)):
        m = HEADING.match(lines[j])
        if m and len(m.group(1)) <= level:
            end = j
            break

    header_at = None
    for j in range(start + 1, end - 1):
        if lines[j].lstrip().startswith("|") and _is_separator(lines[j + 1]):
            header_at = j
            break
    if header_at is None:
        findings.append(
            f"{README}:{start + 1}: the `Knobs` section has no markdown table "
            f"(a header row starting with `|`, then a `|---|` separator)")
        return {"rows": [], "header": [], "region": (start, end)}, findings

    header = [h.strip("` ").lower() for h in _cells(lines[header_at])]
    if tuple(header[:len(COLUMNS)]) != COLUMNS:
        findings.append(
            f"{README}:{header_at + 1}: the knob table's first {len(COLUMNS)} columns "
            f"are {header[:len(COLUMNS)]!r}, want {list(COLUMNS)!r}. The columns are "
            f"the contract N6 writes the table against; a renamed column silently "
            f"moves which cell this gate reads as the knob name")

    rows = []
    seen: dict[str, int] = {}
    for j in range(header_at + 2, end):
        line = lines[j]
        if not line.lstrip().startswith("|"):
            if line.strip():
                break                      # the table ended
            continue
        cells = _cells(line)
        if len(cells) < len(COLUMNS):
            findings.append(
                f"{README}:{j + 1}: knob row has {len(cells)} cell(s), want at least "
                f"{len(COLUMNS)}")
            continue
        knob = cells[0].strip("` ")
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", knob):
            findings.append(
                f"{README}:{j + 1}: knob cell {cells[0]!r} is not an environment "
                f"variable name")
            continue
        if knob in seen:
            findings.append(
                f"{README}:{j + 1}: knob `{knob}` is already documented at line "
                f"{seen[knob]}. Two rows for one knob can disagree, and nothing "
                f"here says which one is the contract")
            continue
        seen[knob] = j + 1
        for col, cell in zip(COLUMNS, cells):
            if not cell.strip(" `"):
                findings.append(
                    f"{README}:{j + 1}: knob `{knob}` has an EMPTY `{col}` cell. A "
                    f"row that documents a knob's existence and not its behaviour "
                    f"is the half F-1 already had")
        kind = cells[4].strip("` ").lower()
        if kind and kind not in KINDS:
            findings.append(
                f"{README}:{j + 1}: knob `{knob}` has kind {cells[4]!r}; the "
                f"vocabulary is closed: {', '.join(KINDS)}")
        rows.append((knob, cells, j + 1))

    if not rows:
        findings.append(
            f"{README}:{header_at + 1}: the knob table has a header and NO ROWS. An "
            f"empty table satisfies clause 2 vacuously while documenting nothing")
    return {"rows": rows, "header": header, "region": (start, end)}, findings


def prose_warnings(readme: str, region: tuple[int, int]) -> list[str]:
    """`SB_*` tokens outside the knob-table region. WARN, never RED."""
    out = []
    lo, hi = region
    for i, line in enumerate(readme.splitlines()):
        if lo <= i < hi:
            continue
        for m in PROSE_TOKEN.finditer(line):
            out.append(f"{README}:{i + 1}: `{m.group(0)}` appears in prose outside "
                       f"the knob table")
    return out


# --------------------------------------------------------------------------
# the whole judgement
# --------------------------------------------------------------------------

def scan(files: dict[str, str], readme: str) -> tuple[list[str], list[str]]:
    """(findings, warnings). Empty findings == green."""
    findings: list[str] = []

    # ---- ANTI-VACUITY, FIRST -------------------------------------------------
    if not files:
        findings.append(
            "NO C# source was scanned, so the knob census is empty and clause 1 "
            "('every knob read is documented') is satisfied by having read none. "
            "This is not a pass.")
        return findings, []

    reads, refusals = census(files)
    findings.extend(refusals)
    if not reads:
        findings.append(
            f"{len(files)} shell file(s) scanned and NOT ONE "
            f"`GetEnvironmentVariable(\"...\")` was found. The shell reads knobs; "
            f"a census that found none means the reader or the glob is broken, "
            f"not that the shell is clean. This is not a pass.")

    table, table_findings = parse_table(readme)
    findings.extend(table_findings)
    rows = table["rows"]
    documented = {knob for knob, _, _ in rows}

    # ---- 1. every knob read is documented -----------------------------------
    for knob in sorted(set(reads) - documented):
        findings.append(
            f"UNDOCUMENTED knob `{knob}`, read at {', '.join(reads[knob])} -- it has "
            f"no row in the knob table. F-1's own shape: an input an operator "
            f"cannot enumerate is an experiment nobody can reproduce")

    # ---- 2. every documented knob is read -----------------------------------
    for knob, _cells_, line in rows:
        if knob not in reads:
            findings.append(
                f"{README}:{line}: knob `{knob}` has a table row and NO READ in "
                f"{SHELL_GLOB}. A row for a knob nothing reads is the worse "
                f"direction of the same rot -- the table looks maintained")

    # ---- 3. the prefix collision --------------------------------------------
    all_names = {n.upper() for n in set(reads) | documented}
    scene_rows = [r for r in rows if r[0] == SCENE_KNOB]
    for knob, cells, line in scene_rows:
        values = [v for v in BACKTICKED.findall(cells[1]) if SCENE_VALUE.fullmatch(v)]
        if not values:
            findings.append(
                f"{README}:{line}: the `{SCENE_KNOB}` row's `meaning` cell lists no "
                f"`backticked` scene values. Those values are the input to the "
                f"prefix-collision clause, so a row without them makes that clause "
                f"vacuous -- and the collision it exists for (`SB_SCENE=hold` vs the "
                f"knob `SB_SCENE_HOLD`) lived between two correct lines")
            continue
        for v in values:
            collision = f"{SCENE_KNOB}_{v}".upper()
            if collision in all_names:
                findings.append(
                    f"{README}:{line}: PREFIX COLLISION -- the scene value "
                    f"`{SCENE_KNOB}={v}` spells the knob name `{collision}`, which "
                    f"is a DIFFERENT knob. Rename the scene (the freeze renamed "
                    f"`hold` to `stall` for exactly this); a reader who sets one "
                    f"meaning to reach the other gets a silent wrong run")

    return findings, prose_warnings(readme, table["region"])


# --------------------------------------------------------------------------
# live mode
# --------------------------------------------------------------------------

def _tracked_shell_files() -> int:
    """How many shell `.cs` files GIT knows about.

    DERIVED from a DIFFERENT ORACLE than the pathlib glob this gate scans with,
    and it FAILS CLOSED: an unreachable oracle is an error, never a zero, because
    a floor of zero passes every possible tree. (check_lane_coverage.py's shape.)
    """
    try:
        out = subprocess.run(["git", "ls-files", SHELL_GLOB], cwd=ROOT,
                             capture_output=True, text=True, encoding="utf-8",
                             check=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        raise Refuse(
            f"cannot derive the file floor: `git ls-files {SHELL_GLOB}` is "
            f"unavailable ({e}). Refusing to scan rather than guarding nothing."
        ) from e
    return len([l for l in out.splitlines() if l.strip()])


def _load() -> tuple[dict[str, str], str]:
    found = {}
    for p in sorted(ROOT.glob(SHELL_GLOB)):
        found[p.relative_to(ROOT).as_posix()] = p.read_text(encoding="utf-8")
    tracked = _tracked_shell_files()
    if tracked == 0:
        raise Refuse(
            f"`git ls-files {SHELL_GLOB}` matched nothing. Either the shell moved "
            f"or this is not the repo -- both make the census vacuous.")
    if len(found) != tracked:
        raise Refuse(
            f"the filesystem glob found {len(found)} shell file(s) and git tracks "
            f"{tracked}. The two oracles disagree; refusing to census a population "
            f"this gate cannot pin down.")
    path = ROOT / README
    if not path.is_file():
        raise Refuse(f"{README} does not exist; there is nothing to check the "
                     f"census against.")
    return found, path.read_text(encoding="utf-8")


# --------------------------------------------------------------------------
# self-test
# --------------------------------------------------------------------------

CLEAN_CS = {
    "Canvas.cs": '''
using System;

internal sealed class Canvas
{
    public bool Benchmark()
    {
        var frames = int.TryParse(Environment.GetEnvironmentVariable("SB_FRAMES"), out var f) ? f : 60;
        return frames > 0;
    }
}
''',
    "MainWindow.xaml.cs": '''
using System;

internal sealed class MainWindow
{
    private void Dispatch()
    {
        // SB_SKIP_PAINT was read here once; the read is gone and this line is
        // narrative. A census that counted comments would resurrect it:
        // Environment.GetEnvironmentVariable("SB_SKIP_PAINT")
        var scene = Environment.GetEnvironmentVariable("SB_SCENE");
        var stall = Environment.GetEnvironmentVariable("SB_RENDER_STALL_MS");
        Log("the string Environment.GetEnvironmentVariable(\\"SB_GHOST\\") is payload, not a read");
        Run(scene, stall);
    }
}
''',
    "JasCore.cs": '''
using System;

internal static class JasCore
{
    private static string Path()
    {
        return Environment.GetEnvironmentVariable("JAS_CORE_DLL") ?? "jas_core.dll";
    }
}
''',
}

CLEAN_README = """# S-B -- the shell

Prose before the table.

## Knobs -- every environment variable this shell reads

| knob | meaning | default | scene | kind |
|---|---|---|---|---|
| `SB_FRAMES` | frames the benchmark loop runs | `60` | `benchmark` | benchmark |
| `SB_SCENE` | which scene runs; one of `benchmark`, `document`, `stall` | `benchmark` | all | interaction |
| `SB_RENDER_STALL_MS` | milliseconds the `stall` scene holds the render thread | `12` | `stall` | interaction |
| `JAS_CORE_DLL` | absolute path to the cdylib to load | (probe order) | all | provenance |

## Historical: the defect as it stood before the cause was found

The reproduction is exact. SB_SKIP_PAINT=1 acquired the back buffer and
presented without painting. Removed; retained as narrative.
"""


def _cs(where: str, old: str, new: str) -> dict[str, str]:
    files = dict(CLEAN_CS)
    assert files[where].count(old) == 1, f"ambiguous anchor {old!r} in {where}"
    files[where] = files[where].replace(old, new)
    return files


def _md(old: str, new: str) -> str:
    assert CLEAN_README.count(old) == 1, f"ambiguous anchor {old!r}"
    return CLEAN_README.replace(old, new)


def self_test() -> int:
    failures: list[str] = []

    def red(label, files, readme, needle=None):
        found, _warn = scan(files, readme)
        if not found:
            failures.append(f"{label}: must RED, got green")
        elif needle and not any(needle in f for f in found):
            failures.append(f"{label}: red, but no finding mentions {needle!r}: {found}")

    def green(label, files, readme):
        found, _warn = scan(files, readme)
        if found:
            failures.append(f"{label}: must be GREEN, got {found}")

    # (0) THE EMPTY SET, FIRST. An empty census satisfies clause 1 by having
    #     read nothing, which is exactly the shape this floor exists for.
    if not scan({}, CLEAN_README)[0]:
        failures.append("0: an empty file set must be FATAL, not green")
    if not any("not a pass" in f for f in scan({"a.cs": "class A {}\n"}, CLEAN_README)[0]):
        failures.append("0b: a shell that reads NO knob must hit the anti-vacuity floor")

    # (1) The clean pair passes...
    green("1 clean fixture", CLEAN_CS, CLEAN_README)
    # ...and the kept history is a WARN with file:line, never a red.
    warns = scan(CLEAN_CS, CLEAN_README)[1]
    if not any("SB_SKIP_PAINT" in w for w in warns):
        failures.append(f"1b: kept history must WARN, got {warns}")
    if not all(re.search(r"README\.md:\d+:", w) for w in warns):
        failures.append(f"1c: every warning must carry file:line, got {warns}")

    # (2) A knob READ and not documented -- F-1's own shape.
    red("2 undocumented knob",
        _cs("Canvas.cs", "return frames > 0;",
            'return frames > 0 && Environment.GetEnvironmentVariable("SB_MODE") != "direct";'),
        CLEAN_README, "UNDOCUMENTED knob `SB_MODE`")

    # (3) A knob DOCUMENTED and not read -- the mirror, and the one that looks
    #     maintained.
    red("3 documented-but-unread knob", CLEAN_CS,
        _md("| `JAS_CORE_DLL` |",
            "| `SB_TOPMOST` | keep the window above every other | `0` | all | interaction |\n"
            "| `JAS_CORE_DLL` |"),
        "and NO READ")

    # (4) THE PREFIX COLLISION, in the exact shape the freeze renamed away from:
    #     the scene value `hold` spells the unrelated knob `SB_SCENE_HOLD`.
    collided_cs = _cs("MainWindow.xaml.cs",
                      'Environment.GetEnvironmentVariable("SB_RENDER_STALL_MS")',
                      'Environment.GetEnvironmentVariable("SB_SCENE_HOLD")')
    collided_md = _md(
        "| `SB_SCENE` | which scene runs; one of `benchmark`, `document`, `stall` | `benchmark` | all | interaction |\n"
        "| `SB_RENDER_STALL_MS` | milliseconds the `stall` scene holds the render thread | `12` | `stall` | interaction |",
        "| `SB_SCENE` | which scene runs; one of `benchmark`, `document`, `hold` | `benchmark` | all | interaction |\n"
        "| `SB_SCENE_HOLD` | milliseconds the `hold` scene holds the render thread | `12` | `hold` | interaction |")
    red("4 prefix collision", collided_cs, collided_md, "PREFIX COLLISION")
    # ...and the RENAME is the repair: the same tree with `stall` is green. Without
    # this the arm above would pass on a gate that reds on every SB_SCENE row.
    green("4b the rename repairs it", CLEAN_CS, CLEAN_README)

    # (5) A SB_SCENE row that lists no values makes clause 3 vacuous.
    red("5 SB_SCENE row with no backticked values", CLEAN_CS,
        _md("| `SB_SCENE` | which scene runs; one of `benchmark`, `document`, `stall` |",
            "| `SB_SCENE` | which scene runs | "),
        "lists no `backticked` scene values")

    # (6) No table at all -- `main` today.
    red("6 no knob table", CLEAN_CS, "# S-B\n\nNo table here.\n", "NO knob-table heading")

    # (7) A heading with no table under it.
    red("7 heading without a table", CLEAN_CS,
        "# S-B\n\n## Knobs\n\nComing soon.\n\n## Next\n", "has no markdown table")

    # (8) Renamed columns: the contract is by name and in order.
    red("8 renamed column", CLEAN_CS, _md("| knob | meaning | default | scene | kind |",
                                          "| name | meaning | default | scene | kind |"),
        "want ['knob', 'meaning', 'default', 'scene', 'kind']")

    # (9) An empty cell documents existence, not behaviour.
    red("9 empty cell", CLEAN_CS,
        _md("| `SB_FRAMES` | frames the benchmark loop runs | `60` | `benchmark` | benchmark |",
            "| `SB_FRAMES` | frames the benchmark loop runs |  | `benchmark` | benchmark |"),
        "EMPTY `default` cell")

    # (10) The kind vocabulary is closed, so a typo reds instead of inventing a
    #      category.
    red("10 unknown kind", CLEAN_CS,
        _md("| `SB_FRAMES` | frames the benchmark loop runs | `60` | `benchmark` | benchmark |",
            "| `SB_FRAMES` | frames the benchmark loop runs | `60` | `benchmark` | timing |"),
        "the vocabulary is closed")

    # (11) Two rows for one knob can disagree.
    red("11 duplicate row", CLEAN_CS,
        _md("| `JAS_CORE_DLL` |",
            "| `SB_FRAMES` | frames again | `60` | `benchmark` | benchmark |\n| `JAS_CORE_DLL` |"),
        "already documented")

    # (12) An empty table is not a documented shell.
    red("12 header with no rows", CLEAN_CS,
        "# S-B\n\n## Knobs\n\n| knob | meaning | default | scene | kind |\n|---|---|---|---|---|\n\n## Next\n",
        "header and NO ROWS")

    # (13) COMMENT AND STRING BLANKING, asserted in the direction that matters:
    #      the clean fixture carries a commented-out read of `SB_SKIP_PAINT` and
    #      a string quoting `SB_GHOST`. Case (1) is green, so neither counted.
    #      Prove the arms are load-bearing by making each REAL.
    red("13 the commented read, uncommented", _cs(
        "MainWindow.xaml.cs",
        '        // Environment.GetEnvironmentVariable("SB_SKIP_PAINT")\n',
        '        var skip = Environment.GetEnvironmentVariable("SB_SKIP_PAINT");\n'),
        CLEAN_README, "UNDOCUMENTED knob `SB_SKIP_PAINT`")
    red("13b the payload string, as code", _cs(
        "MainWindow.xaml.cs",
        '        Log("the string Environment.GetEnvironmentVariable(\\"SB_GHOST\\") is payload, not a read");\n',
        '        var ghost = Environment.GetEnvironmentVariable("SB_GHOST");\n'),
        CLEAN_README, "UNDOCUMENTED knob `SB_GHOST`")

    # (14) A NON-LITERAL read is a REFUSAL, not a pass. A gate that shrugged at
    #      `GetEnvironmentVariable(name)` would report a complete census over a
    #      shell whose knobs it cannot see.
    red("14 non-literal read", _cs("Canvas.cs",
                                   'Environment.GetEnvironmentVariable("SB_FRAMES")',
                                   "Environment.GetEnvironmentVariable(KnobName)"),
        CLEAN_README, "REFUSING to guess")

    # (15) A knob named ONLY in prose is still undocumented -- prose is a WARN,
    #      never a substitute for a row.
    red("15 prose is not documentation",
        _cs("Canvas.cs", "return frames > 0;",
            'return frames > 0 && Environment.GetEnvironmentVariable("SB_SKIP_PAINT") == null;'),
        CLEAN_README, "UNDOCUMENTED knob `SB_SKIP_PAINT`")

    # ⛔ NO LIVE-TREE ARM, for the same reason as its sibling gate: this gate's
    #    live mode is RED on `main` (no table) and GREEN once N6 writes one, so
    #    an arm asserting either would have to be edited by the PR it judges.
    #    The freeze (§3, N5a) says these self-tests are green on ANY tree.

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print(
        "check_shell_knobs SELF-TEST: OK (empty scan and zero-knob census both "
        "fatal, proven FIRST; an undocumented knob and a documented-but-unread "
        "knob red in both directions; the PREFIX COLLISION `SB_SCENE=hold` vs "
        "`SB_SCENE_HOLD` reds and the `stall` rename repairs it; an SB_SCENE row "
        "with no listed values reds rather than making that clause vacuous; a "
        "missing table, a heading with no table, a renamed column, an empty cell, "
        "an unknown kind, a duplicate row and a header with no rows all red; a "
        "read inside a comment and a knob name inside a string are NOT reads, "
        "proven by making each real; a non-literal read REFUSES; and kept history "
        "(SB_SKIP_PAINT) is a WARN with file:line, never a red)")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    try:
        files, readme = _load()
    except Refuse as exc:
        print(f"REFUSING: {exc}")
        return 1
    findings, warnings = scan(files, readme)
    for w in warnings:
        print(f"WARN: {w}")
    if findings:
        print("FAIL: the shell's knob table and the shell's knob reads disagree.")
        for f in findings:
            print(f"  {f}")
        print()
        print("O7 (FREEZE §2). Every environment variable the shell reads has a row")
        print(f"in {README}'s knob table, and every row names a variable something")
        print("reads. A knob nobody can enumerate is an experiment nobody can repeat.")
        return 1
    print(f"check_shell_knobs: OK ({len(files)} shell file(s); "
          f"{len(census(files)[0])} knob(s) read, all documented; "
          f"{len(parse_table(readme)[0]['rows'])} table row(s), all read; "
          f"no SB_SCENE prefix collision; {len(warnings)} prose warning(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
