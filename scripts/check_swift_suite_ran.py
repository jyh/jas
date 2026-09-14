#!/usr/bin/env python3
"""`swift test` exits 0 having run nothing, and nothing in this workflow noticed.

WHY THIS EXISTS
---------------
Every other suite in `.github/workflows/test.yml` is followed by a check that
it actually EXECUTED. `cargo test` has `check_rust_suite_ran.py`; the wasm
canvas lane has `check_wasm_canvas_count.py`; the C# title oracle has
`check_title_oracle_ran.py`. The Swift job was one line -- `cd JasSwift &&
swift test` -- with no such check, on the larger of the two ACTIVE ports.

That is not a hypothetical hole. `swift test` reports success for a package
whose test target compiles and registers zero cases: a renamed module, a target
that stops listing `Tests/`, a `swift-testing` version whose macro stops
expanding, and the job stays green having measured nothing. The suite is 3040
tests; it could silently become 12 and this lane would still be green.

WHAT IT ASSERTS
---------------
(a) THE RUN SUMMARY EXISTS. `swift test` must have printed its own
    `Test run with N tests in M suites ...` line. A log with no summary is a
    run that did not finish, and it REFUSES rather than reporting anything.
(b) THE TOTAL IS THE SOURCE'S OWN. N above must equal the number of `@Test`
    declarations the Swift sources under `JasSwift/Tests/` carry. There is NO
    constant here and no floor to bump: both sides are derived on every run,
    which is the rule this workflow already adopted in writing for the wasm and
    title-oracle lanes.
(c) EVERY DECLARED TEST IS REPORTED, BY NAME AND BY MULTIPLICITY. Names repeat
    across suites, so a set would collapse three real executions of a shared
    name into one. The comparison is a MULTISET: a name declared three times
    must be reported three times. This is the half that says WHICH test stopped
    running instead of only that the count moved.
(d) THE XCTEST SIDE AGREES TOO. SwiftPM prints its own `Executed N tests` line
    for the XCTest bundle. This repository's Swift tests are all swift-testing
    (`import XCTest` appears in zero test files) so both sides are currently 0 --
    and that 0 is ASSERTED against the source rather than assumed, because the
    day someone adds an XCTest case is the day a swift-testing-only gate goes
    quietly blind to it.

WHAT IT DOES NOT COVER -- AND THERE IS NOTHING MISSING FROM THIS LIST
--------------------------------------------------------------------
* Whether the tests PASS. `swift test`'s own exit status is that oracle, and
  this gate reads a log it is handed; duplicating the verdict here would give
  the lane two answers that can disagree.
* The SUITE count. `Test run with ... in M suites` counts implicit suites --
  any type holding a `@Test` -- which the source does not declare, so M has no
  derived counterpart. Asserting it would need a constant, which is the defect
  this file exists to avoid.
* A test DELETED from the source. Both sides move together and the agreement is
  real. `check_rust_suite_ran.py` names the same limit in its own PASS line; a
  green here is never "the suite is as large as it was."
* PARAMETERIZED tests (`@Test(arguments:)`) and CONDITIONAL COMPILATION (`#if`)
  are not modelled -- one declaration would expand to many reported cases, and
  a `#if` would make the declared count platform-dependent. Neither is SKIPPED:
  both REFUSE, loudly, naming the file and line. The repository has zero of
  each today, and the day it gains one this gate stops rather than quietly
  reporting a mismatch as a finding about the suite.
  (This is the clause-(c) rule the sibling gate `check_assertion_declarations.py`
  earned: an unresolvable case is an ERROR, never a skip. Its first live run
  refused twelve names and the cause was the resolver, not the subject.)
"""

from __future__ import annotations

import argparse
import collections
import io
import pathlib
import re
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
TESTS = ROOT / "JasSwift" / "Tests"

# The run summary swift-testing prints last. The glyph in front of it varies
# with the terminal and with the presence of known issues, so it is not part of
# the pattern.
_RUN_SUMMARY = re.compile(r"Test run with (\d+) tests? in (\d+) suites?")
# A per-test line that carries a TERMINAL verdict. `... started.` lines are
# deliberately not matched: a test that starts and never ends must not count as
# reported, which is the whole failure mode a hung case produces.
# ⛔ TWO SPELLINGS, BECAUSE SWIFT-TESTING REPORTS THE DISPLAY NAME WHEN THE
# DECLARATION GIVES ONE. `@Test("the shared field-scoped apply corpus")` is
# reported as `Test "the shared field-scoped apply corpus" passed`, with the
# function name appearing NOWHERE. This gate's first run against the real log
# named six such cases as NOT REPORTED -- every one of them a defect in the
# gate, not in the suite, and all six of them green in the run. A new gate's
# first red is a claim about the gate.
_TEST_RESULT = re.compile(
    r"\bTest\s+(?:([A-Za-z_][A-Za-z0-9_]*)\([^)]*\)|\"((?:[^\"\\\\]|\\\\.)*)\")"
    r"\s+(?:passed|failed|skipped)\b")
# The display name a declaration supplies, which is a STRING LITERAL as the
# first argument. `@Test(.disabled("..."))` supplies none: its first argument is
# a trait, and the quoted text inside it is the trait's comment.
_DISPLAY = re.compile(r'@Test\(\s*"((?:[^"\\]|\\.)*)"')
# SwiftPM's XCTest bundle summary.
_XCTEST_TOTAL = re.compile(r"Executed (\d+) tests?,")

# Anchored nowhere: `struct X { @Test func y() {} }` is legal Swift on one
# line, and a head-anchored census would MISS it -- silently on the name
# axis and loudly on the count. The doc-comment mention this tree carries
# is excluded by the COMMENT STRIPPER instead, which is the mechanism that
# actually knows what a comment is.
_ATTR = re.compile(r"@Test\b")
_FUNC = re.compile(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")


class Refusal(Exception):
    """An unmodelled construct. Never a finding about the suite."""


def _cite(f: pathlib.Path, base: pathlib.Path) -> str:
    """A path to put in a message: repo-relative where that is meaningful.

    The self-test points this at scratch directories outside ROOT, so the
    repo-relative form cannot be assumed -- falling back to the census's own
    base keeps every refusal citable from wherever it was driven.
    """
    for anchor in (ROOT, base):
        try:
            return str(f.relative_to(anchor))
        except ValueError:
            continue
    return str(f)


def _strip_comments(text: str) -> str:
    """Blank out comments, preserving line structure and non-comment bytes.

    ⛔ THE FIRST CUT OF THIS FUNCTION HANDLED BLOCK COMMENTS ONLY, AND THE LIVE
    TREE REFUSED IT IMMEDIATELY: `// The shared test_fixtures/operations/*
    fixtures ...` opens a block comment that never closes, and three files in
    `JasSwift/Tests/` carry that shape today. The arm that caught it is the one
    pointed at the REAL sources rather than at a fixture -- which is the arm
    the sibling gate's header says to write, for exactly this reason.

    Line count survives so a refusal can cite a real line number. Handled, in
    the order Swift itself resolves them: line comments, NESTED block comments
    (legal Swift, so depth is tracked rather than a non-greedy match used), raw
    string delimiters (`#"` ... `"#`, with any number of hashes), multi-line
    string literals, and ordinary string literals with backslash escapes. A
    `/*` inside any of those is text, not a comment.
    """
    out: list[str] = []
    i, n = 0, len(text)
    depth = 0

    def blank(ch: str) -> str:
        return "\n" if ch == "\n" else " "

    while i < n:
        ch = text[i]
        if depth:
            if text.startswith("/*", i):
                depth += 1; out.append("  "); i += 2; continue
            if text.startswith("*/", i):
                depth -= 1; out.append("  "); i += 2; continue
            out.append(blank(ch)); i += 1; continue
        if text.startswith("//", i):
            while i < n and text[i] != "\n":
                out.append(" "); i += 1
            continue
        if text.startswith("/*", i):
            depth = 1; out.append("  "); i += 2; continue
        if ch == "#":
            j = i
            while j < n and text[j] == "#":
                j += 1
            if j < n and text[j] == '"':
                hashes = text[i:j]
                closer = '"' + hashes
                out.append(text[i:j + 1]); i = j + 1
                while i < n and not text.startswith(closer, i):
                    out.append(blank(text[i])); i += 1
                out.append(closer[:min(len(closer), n - i)]); i += len(closer)
                continue
            out.append(ch); i += 1; continue
        if text.startswith('"""', i):
            out.append('"""'); i += 3
            while i < n and not text.startswith('"""', i):
                out.append(blank(text[i])); i += 1
            out.append('"""'); i += 3
            continue
        if ch == '"':
            out.append('"'); i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    out.append("  "); i += 2; continue
                if text[i] == "\n":       # an unterminated literal: do not eat the file
                    break
                out.append(" "); i += 1
            if i < n and text[i] == '"':
                out.append('"'); i += 1
            continue
        out.append(ch); i += 1

    if depth:
        raise Refusal("an unterminated /* block comment")
    return "".join(out)


def declared_tests(tests_dir: pathlib.Path) -> list[tuple[str, int, str]]:
    """(relative path, line number, function name) for every `@Test` declared.

    A declaration is a line whose FIRST non-space token is `@Test`, so the
    attribute named inside a doc comment does not count -- there is exactly one
    such mention in this tree today (`BinaryMalformedBlobTests.swift`, prose
    about how swift-testing schedules each `@Test`), and a substring census
    would have counted it and put the derived total one over the truth.
    """
    found: list[tuple[str, int, str]] = []
    files = sorted(tests_dir.rglob("*.swift"))
    if not files:
        raise Refusal(f"no Swift sources under {tests_dir}")
    for f in files:
        rel = _cite(f, tests_dir)
        raw = f.read_text(encoding="utf-8")
        # ⛔ TWO VIEWS OF THE SAME FILE, AND THE DISPLAY NAME COMES FROM THE RAW
        # ONE. The stripper blanks string CONTENTS, so reading the display name
        # off the stripped line yields a run of spaces -- which is what the
        # second live run reported, as six blank names and six UNDECLARED
        # partners. The stripped view decides WHETHER a line is a declaration;
        # the raw view supplies what it SAYS. Line numbers are preserved by the
        # stripper precisely so the two can be indexed together.
        lines = _strip_comments(raw).splitlines()
        raw_lines = raw.splitlines()
        for i, line in enumerate(lines):
            stripped = line.lstrip()
            if stripped.startswith("#if") or stripped.startswith("#elseif"):
                raise Refusal(
                    f"{rel}:{i + 1} uses conditional compilation. The declared "
                    "count would depend on the platform, which this gate does "
                    "not model.")
            if not _ATTR.search(line):
                continue
            if "arguments" in line:
                raise Refusal(
                    f"{rel}:{i + 1} is a parameterized @Test. One declaration "
                    "expands to many reported cases, which this gate does not "
                    "model.")
            name = None
            for ahead in lines[i:i + 8]:
                m = _FUNC.search(ahead)
                if m:
                    name = m.group(1)
                    break
            if name is None:
                raise Refusal(
                    f"{rel}:{i + 1} carries @Test with no `func` within eight "
                    "lines. The declaration cannot be resolved to a name.")
            shown = _DISPLAY.search(raw_lines[i] if i < len(raw_lines) else "")
            found.append((rel, i + 1, shown.group(1) if shown else name))
    return found


def declared_xctest(tests_dir: pathlib.Path) -> list[tuple[str, int, str]]:
    """XCTest cases: `func test...` methods in files that import XCTest.

    The import is part of the test, not decoration. A `func testFoo` in a
    swift-testing file is an ordinary swift-testing case reached by its `@Test`
    attribute, and counting it here would double it.
    """
    found: list[tuple[str, int, str]] = []
    for f in sorted(tests_dir.rglob("*.swift")):
        text = _strip_comments(f.read_text(encoding="utf-8"))
        if not re.search(r"^\s*import\s+XCTest\b", text, re.M):
            continue
        rel = _cite(f, tests_dir)
        for i, line in enumerate(text.splitlines()):
            m = re.match(r"\s*(?:@\w+\s+)*(?:override\s+)?func\s+(test[A-Za-z0-9_]*)\s*\(",
                         line)
            if m:
                found.append((rel, i + 1, m.group(1)))
    return found


def read_log(path: pathlib.Path) -> str:
    # Explicit UTF-8: the log carries swift-testing's result glyphs, and a
    # locale-dependent read would raise on them. Nothing from the log is ever
    # printed back, so this file's own output stays ASCII.
    return path.read_text(encoding="utf-8", errors="replace")


def reported(log: str) -> collections.Counter:
    return collections.Counter(m.group(1) or m.group(2)
                               for m in _TEST_RESULT.finditer(log))


def run_summary(log: str) -> tuple[int, int]:
    hits = _RUN_SUMMARY.findall(log)
    if not hits:
        raise Refusal(
            "the log carries no `Test run with N tests in M suites` summary. "
            "swift-testing prints that line last, so a log without it is a run "
            "that did not finish -- not a run that found nothing.")
    if len(hits) > 1:
        raise Refusal(
            f"the log carries {len(hits)} run summaries. This gate reads one "
            "run; two mean two invocations, whose counts cannot be attributed.")
    return int(hits[0][0]), int(hits[0][1])


def xctest_total(log: str) -> int:
    hits = _XCTEST_TOTAL.findall(log)
    if not hits:
        raise Refusal(
            "the log carries no `Executed N tests` line. SwiftPM prints one for "
            "the XCTest bundle on every run, so its absence means the log is "
            "not a whole `swift test` run.")
    return max(int(h) for h in hits)


def check(log_text: str,
          decl: list[tuple[str, int, str]],
          xc: list[tuple[str, int, str]]) -> list[str]:
    """Every failure found, as printable ASCII lines. Empty means clean."""
    bad: list[str] = []
    total, suites = run_summary(log_text)

    if not decl:
        bad.append("ANTI-VACUITY: the sources declare zero @Test cases. A gate "
                   "comparing 0 to 0 is not a gate.")
    if total != len(decl):
        bad.append(f"COUNT: the sources declare {len(decl)} @Test cases; the run "
                   f"reports {total}. {abs(total - len(decl))} case(s) differ.")

    seen = reported(log_text)
    want = collections.Counter(name for _, _, name in decl)
    def show(name: str) -> str:
        # ⛔ ASCII ON EVERY OUTPUT PATH. A test's display name is free text and
        # these gates are run on a Windows console whose encoding is cp1252; a
        # sibling gate raised UnicodeEncodeError on its SUCCESS path once, after
        # every check had passed, and the red read as a finding about the
        # subject. Escaping here keeps the diagnosis printable everywhere.
        return name.encode("ascii", "backslashreplace").decode("ascii")

    where = {}
    for rel, line, name in decl:
        where.setdefault(name, f"{rel}:{line}")
    for name in sorted(want):
        if seen[name] < want[name]:
            bad.append(f"NOT REPORTED: {show(name)} is declared {want[name]} time(s) "
                       f"(first at {where[name]}) and reported {seen[name]} "
                       "time(s) with a terminal verdict.")
    for name in sorted(seen):
        if name not in want:
            bad.append(f"UNDECLARED: the run reports {show(name)}, which no @Test "
                       "declaration in the sources names.")

    xc_ran = xctest_total(log_text)
    if xc_ran != len(xc):
        bad.append(f"XCTEST: the sources declare {len(xc)} XCTest case(s); the "
                   f"bundle reports {xc_ran}.")
    return bad


# --------------------------------------------------------------------------
# SELF-TEST
# --------------------------------------------------------------------------

_LOG_OK = (
    "Building for debugging...\n"
    "\u25c7 Test alpha() started.\n"
    "\u2714 Test alpha() passed after 0.001 seconds.\n"
    "\u2714 Test beta() passed after 0.002 seconds.\n"
    "\u2714 Test beta() passed after 0.002 seconds.\n"
    "\u279c Test gamma() skipped: \"not yet\"\n"
    "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.002) seconds\n"
    "\u2501 Test run with 4 tests in 2 suites passed after 1.0 seconds.\n")

_SRC_OK = '''import Testing

struct A {
    @Test
    func alpha() {}
    @Test
    func beta() {}
}
struct B {
    @Test
    func beta() {}
    @Test(.disabled("not yet"))
    func gamma() {}
}
'''


_SRC_NAMED = '''import Testing

struct C {
    @Test("a named case")
    func namedCase() {}
    @Test(.disabled("a trait comment, not a display name"))
    func traitOnly() {}
}
'''

_LOG_NAMED = (
    "\u2714 Test \"a named case\" passed after 0.1 seconds.\n"
    "\u279c Test traitOnly() skipped: \"a trait comment, not a display name\"\n"
    "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds\n"
    "\u2501 Test run with 2 tests in 1 suites passed after 0.2 seconds.\n")

_SRC_SLASHSTAR = '''import Testing
// The shared test_fixtures/operations/* fixtures are replayed here.
let pattern = "a /* b"
let raw = #"workspace/concepts/*.yaml and /* inside a raw string"#
let block = """
/* not a comment either
"""
struct D {
    @Test
    func survives() {}
}
'''

_SRC_INLINE = '''import Testing
struct E { @Test func inlinePlain() {} }
struct F { @Test("an inline named case") func inlineNamed() {} }
'''

_SRC_RAWQUOTE = '''import Testing
let raw = #"an odd " count then /* which is text"#
struct G {
    @Test
    func afterRaw() {}
}
'''

_SRC_XCTEST_NO_IMPORT = '''import Testing
struct H {
    func testShapedButNotXCTest() {}
}
'''

_SRC_XCTEST_WITH_IMPORT = '''import XCTest
final class I: XCTestCase {
    func helperThatIsNotACase() {}
    func testReal() {}
}
'''

def _write(tmp: pathlib.Path, name: str, text: str) -> pathlib.Path:
    p = tmp / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")
    return p


def self_test() -> int:
    failures: list[str] = []

    def arm(label: str, cond: bool) -> None:
        if not cond:
            failures.append(label)

    with tempfile.TemporaryDirectory() as td:
        tmp = pathlib.Path(td)

        # 1. THE CLEAN CASE, FIRST -- and it is not a formality. Every red arm
        #    below is only meaningful if this exact pairing is green.
        _write(tmp, "AB.swift", _SRC_OK)
        decl = declared_tests(tmp)
        arm("the clean source must declare four cases", len(decl) == 4)
        arm("the clean pairing must be clean", check(_LOG_OK, decl, []) == [])

        # 2. THE MULTISET, WHICH A SET WOULD COLLAPSE. `beta` is declared twice
        #    in two suites. A log reporting it ONCE has the right NAMES and the
        #    wrong suite -- the exact shape a-set-collapses-colliding-executions
        #    describes, and the reason the comparison is not `set(...)`.
        one_beta = _LOG_OK.replace("\u2714 Test beta() passed after 0.002 seconds.\n", "", 1)
        one_beta = one_beta.replace("with 4 tests", "with 3 tests")
        found = check(one_beta, decl, [])
        arm("one beta short must be caught", any("NOT REPORTED: beta" in f for f in found))
        arm("...and named with its multiplicity",
            any("declared 2 time(s)" in f and "reported 1 time(s)" in f for f in found))

        # 3. A SUITE THAT STOPS REGISTERING. The run line and the reports agree
        #    with each other and disagree with the SOURCE -- which is the whole
        #    reason both sides are derived rather than one read back from the
        #    other.
        gone = ("Building for debugging...\n"
                "\u2714 Test alpha() passed after 0.001 seconds.\n"
                "\u2714 Test beta() passed after 0.002 seconds.\n"
                "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds\n"
                "\u2501 Test run with 2 tests in 1 suites passed after 1.0 seconds.\n")
        found = check(gone, decl, [])
        arm("a vanished suite must be caught by COUNT",
            any(f.startswith("COUNT:") and "declare 4" in f and "reports 2" in f
                for f in found))
        arm("...and by name, for gamma", any("NOT REPORTED: gamma" in f for f in found))

        # 4. ZERO TESTS, THE FAILURE THIS FILE EXISTS FOR. `swift test` exits 0.
        empty = ("Building for debugging...\n"
                 "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds\n"
                 "\u2501 Test run with 0 tests in 0 suites passed after 0.1 seconds.\n")
        arm("a zero-test run must be caught",
            any(f.startswith("COUNT:") for f in check(empty, decl, [])))

        # 5. A STARTED TEST THAT NEVER ENDS IS NOT A REPORTED TEST.
        hung = _LOG_OK.replace("\u2714 Test alpha() passed after 0.001 seconds.\n", "")
        hung = hung.replace("with 4 tests", "with 3 tests")
        arm("a started-but-never-finished test must not count as reported",
            any("NOT REPORTED: alpha" in f for f in check(hung, decl, [])))

        # 6. NO RUN SUMMARY AT ALL -- REFUSE, never report a finding about the
        #    suite. A truncated log is a fact about the log.
        #    ⛔ ONE VARIABLE. The first cut of this arm passed a log with no
        #    XCTest line either, so a mutant that made the missing summary
        #    return zeros still "refused" -- from the OTHER check. The fixture
        #    below is the clean log with its summary line removed and nothing
        #    else changed.
        no_summary = "".join(l + "\n" for l in _LOG_OK.splitlines()
                             if "Test run with" not in l)
        arm("the no-summary fixture must still carry its XCTest line",
            "Executed 0 tests" in no_summary)
        try:
            check(no_summary, decl, [])
            failures.append("a log with no run summary must REFUSE")
        except Refusal:
            pass

        # 7. TWO RUNS IN ONE LOG -- REFUSE. Two invocations' counts cannot be
        #    attributed to one source census.
        try:
            check(_LOG_OK + _LOG_OK, decl, [])
            failures.append("two run summaries must REFUSE")
        except Refusal:
            pass

        # 8. NO XCTEST LINE -- REFUSE. SwiftPM prints one on every run.
        try:
            check(_LOG_OK.replace("\t Executed 0 tests, with 0 failures "
                                  "(0 unexpected) in 0.000 (0.002) seconds\n", ""),
                  decl, [])
            failures.append("a log with no `Executed N tests` line must REFUSE")
        except Refusal:
            pass

        # 9. THE XCTEST AXIS MOVES. Currently 0/0, and a 0 asserted against the
        #    source is a different thing from a 0 nobody looks at.
        xc_log = _LOG_OK.replace("Executed 0 tests", "Executed 2 tests")
        arm("an XCTest bundle running cases the source does not declare must be caught",
            any(f.startswith("XCTEST:") for f in check(xc_log, decl, [])))

        # 10. A DOC-COMMENT MENTION OF @Test IS NOT A DECLARATION. This tree has
        #     exactly one, and counting it would put the derived side one over.
        _write(tmp, "AB.swift", _SRC_OK + '\n/// Swift Testing runs each `@Test` on a task.\n')
        arm("a doc-comment mention must not be counted",
            len(declared_tests(tmp)) == 4)

        # 11. A BLOCK-COMMENTED-OUT TEST IS NOT A DECLARATION, and the blanking
        #     must preserve line numbers so a refusal can cite a real line.
        _write(tmp, "AB.swift", _SRC_OK + '\n/*\n@Test\nfunc delta() {}\n*/\n')
        arm("a block-commented test must not be counted",
            len(declared_tests(tmp)) == 4)

        # 12. THE UNMODELLED CONSTRUCTS REFUSE, and each names its own file and
        #     line. A skip here would be a gate silently blind to a family.
        for label, extra, needle in (
                ("parameterized", '\n@Test(arguments: [1, 2])\nfunc eps(_ n: Int) {}\n',
                 "parameterized"),
                ("conditional compilation", '\n#if os(macOS)\n@Test\nfunc zeta() {}\n#endif\n',
                 "conditional compilation"),
                ("an unresolvable attribute", '\n@Test\n\n\n\n\n\n\n\n\nfunc eta() {}\n',
                 "no `func`")):
            _write(tmp, "AB.swift", _SRC_OK + extra)
            try:
                declared_tests(tmp)
                failures.append(f"{label} must REFUSE, not be skipped")
            except Refusal as e:
                arm(f"the {label} refusal must say why", needle in str(e))
                arm(f"the {label} refusal must cite a file and line",
                    "AB.swift:" in str(e))

        # 12b. THE DISPLAY NAME IS WHAT THE RUN REPORTS, AND THE TRAIT'S
        #      COMMENT IS NOT ONE. Both halves were live defects in this gate:
        #      the first live run read function names the log never prints, and
        #      the second read the display name off the COMMENT-STRIPPED line
        #      and got a run of spaces. Six real, passing tests were reported as
        #      NOT REPORTED each time, and the count axis was green throughout.
        _write(tmp, "AB.swift", _SRC_NAMED)
        named = declared_tests(tmp)
        arm("a display name must be the declared name, and a trait's comment "
            "must not be mistaken for one",
            sorted(n for _, _, n in named) == ["a named case", "traitOnly"])
        arm("a display-named run must be clean", check(_LOG_NAMED, named, []) == [])

        # 12c. A `/*` THAT IS NOT A COMMENT. Three files in the LIVE tree open a
        #      block comment inside a LINE comment (`test_fixtures/operations/*`)
        #      and never close it; the first cut of the stripper refused the
        #      whole tree on them, and only the arm pointed at production found
        #      it. Raw and multi-line string literals carry the same shape.
        _write(tmp, "AB.swift", _SRC_SLASHSTAR)
        arm("a /* inside a line comment, a string, a raw string or a multi-line "
            "literal must not open a block comment",
            [n for _, _, n in declared_tests(tmp)] == ["survives"])

        # 12d. THE ANTI-VACUITY FLOOR, DRIVEN AT `check` DIRECTLY. Arm 13 below
        #      proves the CENSUS refuses an empty tree, so the floor inside
        #      `check` is unreachable through that door and would be a guard no
        #      mutant can kill (`two-guards-one-predicate`). It is kept rather
        #      than deleted because `check` is called with a census it does not
        #      compute, and armed here through the door a caller would use.
        arm("check() must refuse to compare zero declarations to anything",
            any(f.startswith("ANTI-VACUITY:") for f in check(_LOG_OK, [], [])))

        # 12e. AN INLINE DECLARATION IS A DECLARATION. Legal Swift, and a
        #      head-anchored census would miss it.
        _write(tmp, "AB.swift", _SRC_INLINE)
        arm("a @Test declared mid-line must be counted, display name and all",
            sorted(n for _, _, n in declared_tests(tmp))
            == ["an inline named case", "inlinePlain"])

        # 12f. A RAW STRING MAY CARRY AN UNESCAPED QUOTE -- THAT IS WHAT IT IS
        #      FOR -- AND THE PLAIN-STRING BRANCH CLOSES ON IT. Without the raw
        #      delimiter branch the scanner ends the literal at the interior
        #      quote and reads the rest as code, so a `/*` after it opens a
        #      block comment that eats the file. The earlier fixture could not
        #      show this: its raw string held no interior quote, so the plain
        #      branch happened to give the same answer and the raw branch was a
        #      guard no mutant could kill.
        _write(tmp, "AB.swift", _SRC_RAWQUOTE)
        arm("a raw string's interior quote must not end the literal",
            [n for _, _, n in declared_tests(tmp)] == ["afterRaw"])

        # 12g. A NAME THE RUN REPORTS AND THE SOURCE DOES NOT DECLARE. The
        #      mirror of NOT REPORTED, and the direction that catches a stale
        #      log handed to a fresh tree.
        _write(tmp, "AB.swift", _SRC_OK)
        decl = declared_tests(tmp)
        stranger = _LOG_OK.replace(
            "\u2501 Test run with 4 tests in 2 suites",
            "\u2714 Test ghost() passed after 0.1 seconds.\n"
            "\u2501 Test run with 5 tests in 2 suites")
        arm("a reported name the source does not declare must be caught",
            any(f.startswith("UNDECLARED:") and "ghost" in f
                for f in check(stranger, decl, [])))

        # 12h. THE XCTEST CENSUS IS GUARDED BY THE IMPORT, and that guard is the
        #      whole census. `func testFoo` in a swift-testing file is reached by
        #      its @Test attribute; counting it here would double it, and this
        #      tree has 23 such names against zero XCTest imports.
        _write(tmp, "XC.swift", _SRC_XCTEST_NO_IMPORT)
        arm("a test-shaped func with no XCTest import is not an XCTest case",
            declared_xctest(tmp) == [])
        _write(tmp, "XC.swift", _SRC_XCTEST_WITH_IMPORT)
        arm("a test-shaped func in a file importing XCTest is an XCTest case",
            [n for _, _, n in declared_xctest(tmp)] == ["testReal"])

        # 13. AN EMPTY TREE REFUSES. A census over no files returns a
        #     well-formed zero, which is a number indistinguishable from a
        #     measurement (`a-count-has-no-failure-mode`).
        try:
            declared_tests(tmp / "nothing-here")
            failures.append("an empty source tree must REFUSE")
        except Refusal:
            pass

    # 14. THE PARSER AGAINST PRODUCTION, NOT ONLY FIXTURES. A parser tuned on a
    #     fixture and never pointed at the real tree is a defect this repository
    #     has already paid for (check_title_oracle_ran.py's header says so in
    #     its own voice). This arm reads the REAL Swift sources.
    try:
        live = declared_tests(TESTS)
        arm("the live tree must declare at least two @Test cases", len(live) >= 2)
        arm("every live declaration must resolve to a name",
            all(n for _, _, n in live))
        live_xc = declared_xctest(TESTS)
        arm("the live XCTest census must not crash", isinstance(live_xc, list))
    except Refusal as e:
        failures.append(f"the live tree refused: {e}")
    except FileNotFoundError:
        failures.append(f"the live tree {TESTS} is not there")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print("check_swift_suite_ran SELF-TEST: OK (clean pairing proven first; "
          "multiset collision, vanished suite, zero-test run, hung test and "
          "XCTest drift all caught; missing/double summary, missing XCTest "
          "line, parameterized, #if, unresolvable @Test and an empty tree all "
          "REFUSED; parser driven against the live tree)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Prove `swift test` ran the suite "
                                             "the sources declare.")
    ap.add_argument("--log", help="the captured `swift test` output")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not args.log:
        print("FAIL: --log is required (or --self-test).")
        return 2

    path = pathlib.Path(args.log)
    if not path.is_file():
        print(f"FAIL: no such log: {path}. A missing log is not an empty one.")
        return 2

    try:
        decl = declared_tests(TESTS)
        xc = declared_xctest(TESTS)
        bad = check(read_log(path), decl, xc)
    except Refusal as e:
        print(f"REFUSED: {e}")
        return 2

    if bad:
        print(f"FAIL: check_swift_suite_ran found {len(bad)} problem(s):")
        for b in bad:
            print(f"  - {b}")
        return 1

    total, suites = run_summary(read_log(path))
    print(f"check_swift_suite_ran: OK ({len(decl)} @Test cases declared by the "
          f"sources, {total} reported by the run across {suites} suites, every "
          f"name matched by multiplicity; XCTest {len(xc)} declared / "
          f"{xctest_total(read_log(path))} executed). "
          "A test DELETED from the source moves both sides together and reads "
          "as agreement: this is not a claim that the suite is as large as it was.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
