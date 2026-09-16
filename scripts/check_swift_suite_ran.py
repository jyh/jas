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

WHERE EACH FACT IS READ FROM -- AND WHY THE PER-TEST FACTS ARE NOT THE CONSOLE'S
------------------------------------------------------------------------------
The per-test facts come from the xUnit RECORD swift-testing writes itself
(`swift test --xunit-output <base>.xml` writes `<base>-swift-testing.xml`),
never from the console.

⛔ MEASURED ON THIS WORKFLOW'S OWN `main` (run 34882025346, 2026-09-14, the
merge that introduced this gate): the console carried 3040 `started` lines and
2880 verdict lines, while swift-testing's own summary said all 3040 PASSED --
and one surviving line read `actionWithNoParamBlocNamesAtEveryDepth`, two test
names spliced mid-word. The console reaches the log through SwiftPM's relay of
the test helper's output, and the relay DROPPED CHUNKS OF BYTES. The same tree
was green on its PR run and on the next push. A gate that reads that channel
line by line reds AT RANDOM on a healthy suite, with a list of NOT REPORTED
names that reads exactly like a finding about the suite. The record is a
regular file written by the test process, so nothing sits between the verdicts
and this reader.

The console is read for ONE line: XCTest's `Executed N tests`, which SwiftPM
prints before swift-testing starts. The workflow also sends the console to a
FILE rather than a pipe, so the relay has no back-pressure to drop bytes under.
(Why a pipe drops bytes is INFERRED, not measured: a relay that ignores a
failed or short write. The loss itself is measured, and it is what matters.)

WHAT IT ASSERTS
---------------
(a) THE RECORD EXISTS AND PARSES, in the one shape measured: a `testsuites`
    root holding exactly one `testsuite`. swift-testing writes it when the run
    ends, so a missing or cut-off record is a run that did not finish, and it
    REFUSES rather than reporting anything.
(b) THE TOTAL IS THE SOURCE'S OWN. The number of `testcase` records must equal
    the number of `@Test` declarations the Swift sources under
    `JasSwift/Tests/` carry. There is NO constant here and no floor to bump:
    both sides are derived on every run, which is the rule this workflow
    already adopted in writing for the wasm and title-oracle lanes.
    ⛔ The records are COUNTED; the suite's `tests` attribute is not read. It
    EXCLUDES skipped cases -- measured: `tests="3039"`, `skipped="1"`, and 3040
    records -- so reading it would put a skip on the COUNT axis.
(c) EVERY DECLARED TEST IS RECORDED, BY NAME AND BY MULTIPLICITY. Names repeat
    across suites, so a set would collapse three real executions of a shared
    name into one. The comparison is a MULTISET: a name declared three times
    must be recorded three times. This is the half that says WHICH test stopped
    running instead of only that the count moved.
    The record names a case by its FUNCTION -- `name="foo()"` -- even when
    `@Test("...")` gives it a display name (measured: all seven display-named
    cases in this tree). A record name of any other shape REFUSES, naming it.
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
* The SUITE a case belongs to. Each record carries a `classname`, but the
  census does not model enclosing types, so names are compared bare, as a
  multiset -- which is exactly as strong as the census.
* The console's per-test lines, for the reason above. A console log missing
  verdicts is NOT a finding here, and a person reading that console must not
  treat its gaps as one either: they are the relay's, not the suite's.
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
import pathlib
import re
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
TESTS = ROOT / "JasSwift" / "Tests"

# A record's case name. Only `function()` is modelled: swift-testing records a
# case by its function even when the declaration gives a display name, and the
# parenthesis list is empty because a parameterized declaration REFUSES in the
# census first. Anything else in a record REFUSES, naming what it found -- the
# rule the display-name spelling taught this gate when it still read the
# console, where `@Test("a name")` is reported by the display name ALONE.
_CASE_NAME = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\(\)")
# SwiftPM's XCTest bundle summary.
_XCTEST_TOTAL = re.compile(r"Executed (\d+) tests?,")

# Anchored nowhere: `struct X { @Test func y() {} }` is legal Swift on one
# line, and a head-anchored census would MISS it -- silently on the name
# axis and loudly on the count. The doc-comment mention this tree carries
# is excluded by the COMMENT STRIPPER instead, which is the mechanism that
# actually knows what a comment is.
# swift-testing colours its own result lines when it believes it is attached to
# a terminal, and CI images set enough of the environment that "piped" is not a
# guarantee. THIS SEAT HAS ALREADY PAID FOR THIS EXACT FAILURE MODE ONCE, in
# the other direction: a sibling lane's red was cargo colouring its status
# lines, and the wrong diagnosis survived because the reconstruction stripped
# the codes in the same step. The strip belongs HERE, in the production path,
# where it is armed -- not in a reconstruction, where it repairs the input and
# hides what it repaired.
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
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
            return f.relative_to(anchor).as_posix()
        except ValueError:
            continue
    return f.as_posix()


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
        # The FUNCTION name is the declared name, display name or not: it is
        # what the xUnit record carries. (When this gate read the console it
        # needed the display name as well, off the RAW line -- the stripper
        # blanks string contents -- and paid for both halves of that twice.)
        lines = _strip_comments(f.read_text(encoding="utf-8")).splitlines()
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
            found.append((rel, i + 1, name))
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


def _ascii(name: str) -> str:
    # ⛔ ASCII ON EVERY OUTPUT PATH. A name is free text and these gates run on
    # a Windows console whose encoding is cp1252; a sibling gate raised
    # UnicodeEncodeError on its SUCCESS path once, after every check had
    # passed, and the red read as a finding about the subject.
    return name.encode("ascii", "backslashreplace").decode("ascii")


def read_log(path: pathlib.Path) -> str:
    # Explicit UTF-8: the log carries swift-testing's result glyphs, and a
    # locale-dependent read would raise on them. Nothing from the log is ever
    # printed back, so this file's own output stays ASCII.
    return _ANSI.sub("", path.read_text(encoding="utf-8", errors="replace"))


def read_xunit(path: pathlib.Path) -> list[str]:
    """The function name of every case the record holds, one entry per record.

    REFUSES -- never returns a short list -- when the record is missing, cut
    off, of a shape not measured, or names a case in a form not modelled. Each
    of those is a fact about the RUN or about this reader, and a short list
    would report it as a finding about the suite.
    """
    if not path.is_file():
        raise Refusal(
            f"no xUnit record at {_ascii(path.as_posix())}. swift-testing writes "
            "it when the run ends, so its absence is a run that did not finish "
            "(or `swift test` was not given --xunit-output) -- not a run that "
            "found nothing.")
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as e:
        raise Refusal(
            f"the xUnit record does not parse ({_ascii(str(e))}). A record cut "
            "off mid-write is a run that did not finish.")
    suites = root.findall("testsuite")
    if root.tag != "testsuites" or len(suites) != 1:
        raise Refusal(
            f"the xUnit record is a <{_ascii(root.tag)}> holding {len(suites)} "
            "<testsuite>. The one shape measured is <testsuites> holding exactly "
            "one; any other is a toolchain this reader has not been shown.")
    names: list[str] = []
    for case in suites[0].iter("testcase"):
        raw = case.get("name", "")
        m = _CASE_NAME.fullmatch(raw)
        if not m:
            raise Refusal(
                f"the xUnit record names a case {_ascii(raw)!r}, which is not "
                "`function()`. This reader does not model that spelling.")
        names.append(m.group(1))
    return names


def xctest_total(log: str) -> int:
    hits = _XCTEST_TOTAL.findall(log)
    if not hits:
        raise Refusal(
            "the log carries no `Executed N tests` line. SwiftPM prints one for "
            "the XCTest bundle on every run, so its absence means the log is "
            "not a whole `swift test` run.")
    return max(int(h) for h in hits)


def check(log_text: str,
          recorded: list[str],
          decl: list[tuple[str, int, str]],
          xc: list[tuple[str, int, str]]) -> list[str]:
    """Every failure found, as printable ASCII lines. Empty means clean.

    `recorded` is `read_xunit`'s answer; `log_text` is read for the XCTest line
    ALONE, and nothing else in it can move the verdict.
    """
    bad: list[str] = []

    if not decl:
        bad.append("ANTI-VACUITY: the sources declare zero @Test cases. A gate "
                   "comparing 0 to 0 is not a gate.")
    if len(recorded) != len(decl):
        bad.append(f"COUNT: the sources declare {len(decl)} @Test cases; the "
                   f"xUnit record holds {len(recorded)}. "
                   f"{abs(len(recorded) - len(decl))} case(s) differ.")

    seen = collections.Counter(recorded)
    want = collections.Counter(name for _, _, name in decl)
    where = {}
    for rel, line, name in decl:
        where.setdefault(name, f"{rel}:{line}")
    for name in sorted(want):
        if seen[name] < want[name]:
            bad.append(f"NOT RECORDED: {_ascii(name)} is declared {want[name]} "
                       f"time(s) (first at {where[name]}) and recorded "
                       f"{seen[name]} time(s) in the xUnit record.")
    for name in sorted(seen):
        if name not in want:
            bad.append(f"UNDECLARED: the xUnit record names {_ascii(name)}, which "
                       "no @Test declaration in the sources names.")

    xc_ran = xctest_total(log_text)
    if xc_ran != len(xc):
        bad.append(f"XCTEST: the sources declare {len(xc)} XCTest case(s); the "
                   f"bundle reports {xc_ran}.")
    return bad


# --------------------------------------------------------------------------
# SELF-TEST
# --------------------------------------------------------------------------

# The console fixture carries NO per-test line at all. That is deliberate and
# it is the point: nothing in the console but the XCTest line may move the
# verdict, so the clean pairing below is only clean if the per-test lines are
# ignored. The summary line stays so the fixture still looks like a run.
_LOG_OK = (
    "Building for debugging...\n"
    "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.002) seconds\n"
    "━ Test run with 4 tests in 2 suites passed after 1.0 seconds.\n")

# THE RECORD, each line copied from the shape the real one carries -- a
# classname qualified by its suite, a skipped case with NO `time` attribute, a
# space before its `>`, and its reason as element text -- and the `tests`
# attribute EXCLUDING the skip, as the real one does (3 here, beside 4 records).
_XU_HEAD = ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<testsuites>\n'
            '  <testsuite name="TestResults" errors="0" tests="3" failures="0" '
            'skipped="1" time="1.0">\n')
_XU_ALPHA = '    <testcase classname="Mod.A" name="alpha()" time="0.1" />\n'
_XU_BETA_A = '    <testcase classname="Mod.A" name="beta()" time="0.1" />\n'
_XU_BETA_B = '    <testcase classname="Mod.B" name="beta()" time="0.1" />\n'
_XU_GAMMA = ('    <testcase classname="Mod.B" name="gamma()" >\n'
             '      <skipped>not yet</skipped>\n'
             '    </testcase>\n')
_XU_TAIL = '  </testsuite>\n</testsuites>\n'
_XU_OK = _XU_HEAD + _XU_ALPHA + _XU_BETA_A + _XU_BETA_B + _XU_GAMMA + _XU_TAIL

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

_XU_NAMED = (_XU_HEAD
             + '    <testcase classname="Mod.C" name="namedCase()" time="0.1" />\n'
             + '    <testcase classname="Mod.C" name="traitOnly()" >\n'
             + '      <skipped>a trait comment, not a display name</skipped>\n'
             + '    </testcase>\n'
             + _XU_TAIL)

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
    p.write_text(text, encoding="utf-8", newline="\n")
    return p


def self_test() -> int:
    failures: list[str] = []

    def arm(label: str, cond: bool) -> None:
        if not cond:
            failures.append(label)

    with tempfile.TemporaryDirectory() as td:
        tmp = pathlib.Path(td)

        def record(text: str) -> list[str]:
            # Every record goes through read_xunit from a FILE, which is the
            # path production takes; no arm hands check() a hand-built list.
            return read_xunit(_write(tmp, "record.xml", text))

        # 1. THE CLEAN CASE, FIRST -- and it is not a formality. Every red arm
        #    below is only meaningful if this exact pairing is green.
        _write(tmp, "AB.swift", _SRC_OK)
        decl = declared_tests(tmp)
        arm("the clean source must declare four cases", len(decl) == 4)
        ok = record(_XU_OK)
        arm("the clean record must hold four cases in order",
            ok == ["alpha", "beta", "beta", "gamma"])
        arm("the clean pairing must be clean", check(_LOG_OK, ok, decl, []) == [])

        # 2. THE MULTISET, WHICH A SET WOULD COLLAPSE. `beta` is declared twice
        #    in two suites. A record holding it ONCE has the right NAMES and the
        #    wrong suite -- the exact shape a-set-collapses-colliding-executions
        #    describes, and the reason the comparison is not `set(...)`.
        found = check(_LOG_OK, record(_XU_OK.replace(_XU_BETA_B, "", 1)), decl, [])
        arm("one beta short must be caught", any("NOT RECORDED: beta" in f for f in found))
        arm("...and named with its multiplicity",
            any("declared 2 time(s)" in f and "recorded 1 time(s)" in f for f in found))

        # 3. A SUITE THAT STOPS REGISTERING. The record agrees with itself and
        #    disagrees with the SOURCE -- which is the whole reason both sides
        #    are derived rather than one read back from the other.
        gone = _XU_HEAD + _XU_ALPHA + _XU_BETA_A + _XU_TAIL
        found = check(_LOG_OK, record(gone), decl, [])
        arm("a vanished suite must be caught by COUNT",
            any(f.startswith("COUNT:") and "declare 4" in f and "holds 2" in f
                for f in found))
        arm("...and by name, for gamma", any("NOT RECORDED: gamma" in f for f in found))

        # 4. ZERO TESTS, THE FAILURE THIS FILE EXISTS FOR. `swift test` exits 0.
        arm("a zero-test run must be caught",
            any(f.startswith("COUNT:")
                for f in check(_LOG_OK, record(_XU_HEAD + _XU_TAIL), decl, [])))

        # 5. ⭐ THE LOSSY CONSOLE -- THE ARM THIS READER EXISTS FOR. `main` went
        #    red on a healthy suite because the console lost verdict lines in
        #    CHUNKS, one of them splicing two names into a third. A console
        #    carrying every per-test line, one carrying none, and one carrying
        #    only a spliced ghost must all read the SAME as the clean pairing.
        #    ⛔ Each variant asserts it mutated before its verdict is trusted.
        full = (_LOG_OK
                + "✔ Test alpha() passed after 0.001 seconds.\n"
                + "✔ Test beta() passed after 0.002 seconds.\n")
        spliced = _LOG_OK + "✔ Test alphBetaGhost() passed after 1.9 seconds.\n"
        arm("the full-console fixture must carry per-test lines",
            "Test alpha()" in full and "Test alpha()" not in _LOG_OK)
        arm("the spliced-console fixture must carry the ghost",
            "alphBetaGhost" in spliced)
        for label, text in (("a console with every verdict", full),
                            ("a console with none", _LOG_OK),
                            ("a console with a spliced ghost", spliced)):
            arm(f"{label} must not move the verdict",
                check(text, ok, decl, []) == [])

        # 6. THE RECORD REFUSES WHAT IT CANNOT READ, and says why. Each of these
        #    is a fact about the RUN or the reader; a short list would report it
        #    as a finding about the suite.
        for label, text, needle in (
                ("a record cut off mid-write",
                 _XU_OK[:len(_XU_OK) // 2], "does not parse"),
                ("a bare <testsuite> root",
                 _XU_OK.replace("<testsuites>\n", "").replace("</testsuites>\n", ""),
                 "one shape measured"),
                # A renamed root still holding ONE suite: only the TAG test can
                # refuse it. The bare root above is refused by the suite count
                # as well, so it could not show the tag test is load-bearing.
                ("a renamed root",
                 _XU_OK.replace("<testsuites>", "<results>")
                 .replace("</testsuites>", "</results>"), "<results>"),
                ("two <testsuite> elements",
                 _XU_OK.replace(_XU_TAIL, "  </testsuite>\n" + _XU_HEAD.split("\n", 2)[2]
                                + _XU_TAIL), "holding 2"),
                # A display name that MENTIONS a function: a reader that
                # searched for `name()` instead of matching the whole name would
                # take `alpha` out of it and never refuse.
                ("a display-name spelling",
                 _XU_OK.replace('name="alpha()"', 'name="checks alpha() twice"'),
                 "checks alpha() twice"),
                ("an argument list",
                 _XU_OK.replace('name="alpha()"', 'name="alpha(n:)"'), "alpha(n:)")):
            try:
                record(text)
                failures.append(f"{label} must REFUSE")
            except Refusal as e:
                arm(f"the refusal for {label} must say why", needle in str(e))
        try:
            read_xunit(tmp / "no-such-record.xml")
            failures.append("a missing record must REFUSE")
        except Refusal as e:
            arm("the missing-record refusal must name the path",
                "no-such-record.xml" in str(e))

        # 7. THE SUITE'S TOTALS ARE NOT THE COUNT. The clean record says
        #    tests="3" beside four records, exactly as the real one excludes its
        #    skip, so arm 1 is green only because a reader of `tests` is not the
        #    reader here. The subtler reader -- `tests` + `skipped` -- agrees
        #    with arm 1, so it is killed HERE: a record one case short whose
        #    header totals still add up to the declared four.
        short = _XU_OK.replace(_XU_BETA_B, "", 1)
        arm("the short-record fixture must hold three records under totals of four",
            short.count("<testcase ") == 3
            and 'tests="3"' in short and 'skipped="1"' in short)
        arm("a record short of a case must be caught by COUNT whatever the totals say",
            any(f.startswith("COUNT:") for f in check(_LOG_OK, record(short), decl, [])))

        # 8. NO XCTEST LINE -- REFUSE. SwiftPM prints one on every run.
        try:
            check(_LOG_OK.replace("\t Executed 0 tests, with 0 failures "
                                  "(0 unexpected) in 0.000 (0.002) seconds\n", ""),
                  ok, decl, [])
            failures.append("a log with no `Executed N tests` line must REFUSE")
        except Refusal:
            pass

        # 9. THE XCTEST AXIS MOVES. Currently 0/0, and a 0 asserted against the
        #    source is a different thing from a 0 nobody looks at.
        xc_log = _LOG_OK.replace("Executed 0 tests", "Executed 2 tests")
        arm("an XCTest bundle running cases the source does not declare must be caught",
            any(f.startswith("XCTEST:") for f in check(xc_log, ok, decl, [])))

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

        # 12b. A DISPLAY-NAMED CASE IS DECLARED BY ITS FUNCTION, AND A TRAIT'S
        #      COMMENT IS NEITHER. The record names `namedCase()`, never "a
        #      named case" -- measured on all seven such cases in this tree.
        #      (The console spelling was the opposite, and this gate paid for
        #      reading it twice: function names the console never prints, then
        #      a display name read off the comment-stripped line as spaces.)
        _write(tmp, "AB.swift", _SRC_NAMED)
        named = declared_tests(tmp)
        arm("a display-named case must be declared by its function name",
            sorted(n for _, _, n in named) == ["namedCase", "traitOnly"])
        arm("a display-named record must pair clean",
            check(_LOG_OK, record(_XU_NAMED), named, []) == [])

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
        #      compute, and armed here through the door a caller would use --
        #      with an EMPTY record too, so COUNT agrees and only the floor fires.
        arm("check() must refuse to compare zero declarations to anything",
            any(f.startswith("ANTI-VACUITY:")
                for f in check(_LOG_OK, record(_XU_HEAD + _XU_TAIL), [], [])))

        # 12e. AN INLINE DECLARATION IS A DECLARATION. Legal Swift, and a
        #      head-anchored census would miss it -- display name or not.
        _write(tmp, "AB.swift", _SRC_INLINE)
        arm("a @Test declared mid-line must be counted, by its function name",
            sorted(n for _, _, n in declared_tests(tmp))
            == ["inlineNamed", "inlinePlain"])

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

        # 12g. A NAME THE RECORD HOLDS AND THE SOURCE DOES NOT DECLARE. The
        #      mirror of NOT RECORDED, and the direction that catches a stale
        #      record handed to a fresh tree.
        _write(tmp, "AB.swift", _SRC_OK)
        decl = declared_tests(tmp)
        stranger = _XU_OK.replace(
            _XU_TAIL,
            '    <testcase classname="Mod.B" name="ghost()" time="0.1" />\n' + _XU_TAIL)
        arm("a recorded name the source does not declare must be caught",
            any(f.startswith("UNDECLARED:") and "ghost" in f
                for f in check(_LOG_OK, record(stranger), decl, [])))

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

        # 12i. COLOURED OUTPUT MUST READ THE SAME AS PLAIN. Every byte of the
        #      clean log wrapped in SGR codes, including inside the XCTest line
        #      -- the one line this reader still takes from the console, and
        #      whose pattern a colour code would break.
        coloured = "".join(
            "\x1b[32m" + c + "\x1b[0m" if c not in "\n" else c for c in _LOG_OK)
        arm("the ANSI fixture must actually carry escape codes", "\x1b[" in coloured)
        #      Driven through read_log(), which is the ONLY stripper and the path
        #      production takes. An arm that stripped inside check() instead
        #      would have left read_log's strip unkillable -- measured: that
        #      mutant survived, and the honest fix was to delete the second
        #      strip rather than keep a guard no arm could reach.
        lit = tmp / "coloured.log"
        lit.write_text(coloured, encoding="utf-8", newline="\n")
        arm("a colourised log must read exactly as the plain one",
            check(read_log(lit), ok, decl, []) == check(_LOG_OK, ok, decl, []) == [])

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
        arm("every live declaration must resolve to a function name",
            all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", n) for _, _, n in live))
        live_xc = declared_xctest(TESTS)
        arm("the live XCTest census must not crash", isinstance(live_xc, list))
    except Refusal as e:
        failures.append(f"the live tree refused: {e}")
    except FileNotFoundError:
        failures.append(f"the live tree {TESTS.as_posix()} is not there")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print("check_swift_suite_ran SELF-TEST: OK (clean pairing proven first; "
          "multiset collision, vanished suite, zero-test run, a short record "
          "behind agreeing header totals and XCTest drift all caught; "
          "three console variants, a spliced ghost among them, move nothing; "
          "a cut-off, bare, renamed, two-suite, display-named, argument-listed "
          "or missing "
          "record, a missing XCTest line, parameterized, #if, unresolvable "
          "@Test and an empty tree all REFUSED; parser driven against the "
          "live tree)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Prove `swift test` ran the suite "
                                             "the sources declare.")
    ap.add_argument("--log", help="the captured `swift test` console output "
                                  "(read for the XCTest line alone)")
    ap.add_argument("--xunit", help="the xUnit record swift-testing wrote "
                                    "(`<base>-swift-testing.xml`)")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not args.log or not args.xunit:
        print("FAIL: --log and --xunit are both required (or --self-test).")
        return 2

    path = pathlib.Path(args.log)
    if not path.is_file():
        print(f"FAIL: no such log: {_ascii(path.as_posix())}. A missing log is "
              "not an empty one.")
        return 2

    try:
        decl = declared_tests(TESTS)
        xc = declared_xctest(TESTS)
        recorded = read_xunit(pathlib.Path(args.xunit))
        # ONE read, ONE strip, and everything below judges the same bytes.
        text = read_log(path)
        bad = check(text, recorded, decl, xc)
    except Refusal as e:
        print(f"REFUSED: {e}")
        return 2

    if bad:
        print(f"FAIL: check_swift_suite_ran found {len(bad)} problem(s):")
        for b in bad:
            print(f"  - {b}")
        return 1

    print(f"check_swift_suite_ran: OK ({len(decl)} @Test cases declared by the "
          f"sources, {len(recorded)} in the xUnit record, every name matched by "
          f"multiplicity; XCTest {len(xc)} declared / {xctest_total(text)} "
          "executed). The console's per-test lines are NOT read -- its relay "
          "drops bytes. A test DELETED from the source moves both sides "
          "together and reads as agreement: this is not a claim that the suite "
          "is as large as it was.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
