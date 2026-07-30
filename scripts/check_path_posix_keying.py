#!/usr/bin/env python3
"""In shared Python, a Path that becomes a string must become a POSIX string.

WHY THIS EXISTS
---------------
`str(Path)` yields `\\` separators on Windows and `/` everywhere else. Shared
tooling that keys, compares or regex-matches a stringified path is therefore
correct on macOS and Linux by accident and wrong on Windows, silently, in both
directions at once. Three sightings, all found only once a third platform
existed:

  1. `genericity_check.py`      `exclude_re.search(str(f))` against `/`-anchored
                                patterns -- every exclusion silently no-opped, so
                                every count came back high by exactly the number
                                of files it should have dropped.
  2. `check_swift_copy_sites.py` `rel = str(path.relative_to(REPO))` used as a
                                baseline key -- on Windows all 25 known sites
                                reported simultaneously as NEW debt and as
                                RETIRED debt.
  3. the panel-goldens trap      a `str(Path)` written WHILE FIXING `str(Path)`,
                                caught by the gate on its first run.

Each was fixed. Each fix carries a comment explaining the hazard. **Nothing
policed the class.** Stubb's ninth letter set a condition on this gate's claim
and his fourteenth letter established why it was never met: the gate had never
been built, and two seats each believed the other had it. A fourth sighting
could land today with CI green.

This is that gate. It is the seat's answer to its own long-carried debt.

WHAT IT ASSERTS
---------------
In `scripts/` and `workspace_interpreter/`, a Path-valued expression may not be
turned into a string by `str()` or an f-string, UNLESS

  * the stringification is a direct argument to a MESSAGE sink -- `print`,
    `sys.stderr.write`, a `logging` call, or an exception constructor -- where a
    human reads it and separators do not matter; or
  * the line carries an explicit `# path-native: <reason>` waiver, for the rare
    case where OS-native separators are the point (a subprocess argument, an
    `open()` target on a caller-supplied string).

Everything else must use `.as_posix()`.

HOW PATH-NESS IS ESTABLISHED, and its blind spot
------------------------------------------------
Syntactically (`Path(...)`, `.parent`, `.relative_to()`, `.glob()`, ...) PLUS one
level of local binding: a name assigned from a Path producer, a `for` target over
a Path iterable, a comprehension target over one. That second half is not
decoration -- sighting 1 is `str(f)` where `f` is a comprehension target over a
list bound from `repo.glob(...)`, so **a purely syntactic rule would miss it.**
Stubb doubted from his desk whether an as_posix-shaped rule reached sighting 1;
the answer is that it does, but only with the binding pass.

BLIND SPOT, STATED: Path-ness that is only knowable across a function boundary --
a parameter, a return value, an attribute -- is NOT inferred. A helper that takes
a `Path` argument and does `str(p)` inside is invisible here. Closing that needs
real type inference, and this gate does not pretend to have it.
"""

import argparse
import ast
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCOPE = ("scripts", "workspace_interpreter")

# Anti-vacuity floors. A detector that has quietly stopped recognising Paths
# would otherwise sail through on an empty finding list.
#
# MEASURED 2026-07-30: 89 shared Python files, 41 Path-bound names, 0 findings.
#
# These are LIVENESS floors, and that is deliberately a different thing from the
# COVERAGE floor in `check_native_core_tests.py`, which is exact. The lesson
# there -- "a floor with slack is a hole exactly the size of the slack" -- was
# about a floor guarding how much is VERIFIED, where slack directly admits the
# forbidden move (gate some tests off, stay green). Here the quantity is
# incidental: a refactor that removes three Path bindings has not weakened
# anything, and an exact floor would red on noise and get raised reflexively
# until it meant nothing. The failure this guards is COLLAPSE -- the scope glob
# stopping matching, or the detector ceasing to recognise Paths at all -- so the
# floors sit far below today's numbers and catch a fall off a cliff, not a step.
#
# The real liveness proof is `--self-test`, which reds on both historical
# defects from their verbatim pre-fix source on every run. That is exact, it
# does not drift, and it is what should be trusted.
MIN_FILES = 60
MIN_PATH_NAMES = 20

PATH_CALLS = {"Path", "PurePath", "PurePosixPath", "PureWindowsPath"}
PATH_ATTRS = {
    "parent", "resolve", "absolute", "expanduser", "with_suffix", "with_name",
    "relative_to", "joinpath", "glob", "rglob", "iterdir", "cwd", "home",
}
ITER_WRAP = {"sorted", "list", "reversed", "set", "tuple"}
MESSAGE_SINKS = {"print", "warn", "warning", "info", "debug", "error", "critical",
                 "exception", "write", "fail", "format"}
WAIVER = "# path-native:"


class Analyzer(ast.NodeVisitor):
    """One module. `paths` is the set of names known to hold a Path."""

    def __init__(self, src: str, seed: set):
        self.src = src
        self.paths = set(seed)
        self.findings = []
        self.path_expr_count = 0
        self._safe = []          # stack: inside a message sink's arguments?

    # -- Path-ness ---------------------------------------------------------
    def is_path(self, n) -> bool:
        # See through sorted()/list()/... first: `files = sorted(repo.glob(...))`
        # is how sighting 1 binds its name, and without this the whole binding
        # pass is dead weight. The set therefore holds names that are a Path OR
        # an iterable of Paths; `for f in files` needs exactly that.
        n = self._unwrap(n)
        if isinstance(n, ast.Call):
            f = n.func
            if isinstance(f, ast.Name) and f.id in PATH_CALLS:
                return True
            if isinstance(f, ast.Attribute) and f.attr in PATH_ATTRS:
                return True
        if isinstance(n, ast.Attribute) and n.attr in PATH_ATTRS:
            return True
        if isinstance(n, ast.Name) and n.id in self.paths:
            return True
        if isinstance(n, ast.BinOp) and isinstance(n.op, ast.Div):
            return self.is_path(n.left)          # Path / "sub"
        if isinstance(n, ast.Subscript):
            return self.is_path(n.value)         # p.parents[1]
        return False

    def _unwrap(self, v):
        if (isinstance(v, ast.Call) and isinstance(v.func, ast.Name)
                and v.func.id in ITER_WRAP and v.args):
            return v.args[0]
        return v

    # -- binding -----------------------------------------------------------
    def visit_Assign(self, n):
        for t in n.targets:
            if isinstance(t, ast.Name) and self.is_path(n.value):
                self.paths.add(t.id)
        self.generic_visit(n)

    def visit_For(self, n):
        if isinstance(n.target, ast.Name) and self.is_path(self._unwrap(n.iter)):
            self.paths.add(n.target.id)
        self.generic_visit(n)

    def visit_ListComp(self, n):
        self._comp(n)

    def visit_GeneratorExp(self, n):
        self._comp(n)

    def visit_SetComp(self, n):
        self._comp(n)

    def _comp(self, n):
        for g in n.generators:
            if isinstance(g.target, ast.Name) and self.is_path(self._unwrap(g.iter)):
                self.paths.add(g.target.id)
        self.generic_visit(n)

    # -- sinks -------------------------------------------------------------
    @staticmethod
    def _is_message_sink(call: ast.Call) -> bool:
        f = call.func
        if isinstance(f, ast.Name):
            # print(...), or raise ValueError(f"...")
            return f.id in MESSAGE_SINKS or (f.id[:1].isupper() and f.id.endswith("Error"))
        if isinstance(f, ast.Attribute):
            return f.attr in MESSAGE_SINKS
        return False

    def visit_Raise(self, n):
        self._safe.append(True)
        self.generic_visit(n)
        self._safe.pop()

    def visit_Call(self, n):
        if (isinstance(n.func, ast.Name) and n.func.id == "str"
                and n.args and self.is_path(n.args[0])):
            self.path_expr_count += 1
            if not self._safe or not self._safe[-1]:
                self._record(n, "str()")
        safe = self._is_message_sink(n)
        self._safe.append(safe)
        self.generic_visit(n)
        self._safe.pop()

    def visit_JoinedStr(self, n):
        for v in n.values:
            if isinstance(v, ast.FormattedValue) and self.is_path(v.value):
                self.path_expr_count += 1
                if not self._safe or not self._safe[-1]:
                    self._record(n, "f-string")
                break
        self.generic_visit(n)

    def _record(self, node, kind):
        line = self.src.splitlines()[node.lineno - 1] if node.lineno <= len(self.src.splitlines()) else ""
        if WAIVER in line:
            return
        seg = ast.get_source_segment(self.src, node) or ""
        self.findings.append((node.lineno, kind, " ".join(seg.split())[:90]))


def analyze(path: Path):
    src = path.read_text(encoding="utf-8")
    tree = ast.parse(src)
    seed: set = set()
    a = None
    for _ in range(4):                      # fixpoint: module consts before use
        a = Analyzer(src, seed)
        a.visit(tree)
        if a.paths == seed:
            break
        seed = a.paths
    return a


def scan():
    files = 0
    findings = []
    path_exprs = 0
    for root in SCOPE:
        base = REPO / root
        if not base.exists():
            continue
        for p in sorted(base.rglob("*.py")):
            files += 1
            try:
                a = analyze(p)
            except SyntaxError:
                continue
            path_exprs += len(a.paths)
            for ln, kind, seg in a.findings:
                findings.append((p.relative_to(REPO).as_posix(), ln, kind, seg))
    return files, path_exprs, findings


def run() -> int:
    files, path_exprs, findings = scan()

    if files < MIN_FILES:
        print(f"path/posix keying: FAIL -- only {files} shared Python files found, "
              f"floor is {MIN_FILES}. The scan is not reaching the tree.", file=sys.stderr)
        return 1
    if path_exprs < MIN_PATH_NAMES:
        print(f"path/posix keying: FAIL -- only {path_exprs} Path-bound name(s) seen, "
              f"floor is {MIN_PATH_NAMES}. The DETECTOR has probably stopped recognising "
              f"Path expressions, which would make an empty finding list meaningless.",
              file=sys.stderr)
        return 1

    if not findings:
        print(f"path/posix keying: OK -- {files} shared Python files, {path_exprs} Path-bound name(s), 0 stringified outside a message sink.")
        return 0

    print(f"path/posix keying: FAIL -- {len(findings)} Path stringification(s) outside a "
          f"message sink:", file=sys.stderr)
    for f, ln, kind, seg in findings:
        print(f"  {f}:{ln}  [{kind}]  {seg}", file=sys.stderr)
    print(
        "\nstr(Path) yields backslashes on Windows. If this value is keyed, compared or\n"
        "regex-matched, use .as_posix(). If OS-native separators are genuinely wanted,\n"
        "add `# path-native: <reason>` on the line and say why.",
        file=sys.stderr)
    return 1


# ---------------------------------------------------------------------------
# Self-test: the gate is trusted for its RED, and the RED cases here are the
# ACTUAL historical defects, taken verbatim from the commits that fixed them.
# ---------------------------------------------------------------------------

SIGHTING_1 = '''
import re
from pathlib import Path
repo = Path(".")
def go(spec, exclude_re):
    files = sorted(repo.glob(spec["glob"]))
    files = [f for f in files if not exclude_re.search(str(f))]
    return files
'''

SIGHTING_2 = '''
from pathlib import Path
REPO = Path(".")
SOURCES = REPO / "src"
def scan_all():
    for path in sorted(SOURCES.rglob("*.swift")):
        rel = str(path.relative_to(REPO))
        yield rel
'''

BENIGN_PRINT = '''
from pathlib import Path
BASELINE = Path("a/b.json")
def go():
    print(f"no baseline at {BASELINE}")
    print("wrote " + str(BASELINE))
'''

BENIGN_AS_POSIX = '''
from pathlib import Path
REPO = Path(".")
def go(p):
    rel = (REPO / "x").as_posix()
    return rel
'''

BENIGN_RAISE = '''
from pathlib import Path
P = Path("x")
def go():
    raise ValueError(f"bad path {P}")
'''

WAIVED = '''
from pathlib import Path
P = Path("x")
def go(run):
    return run([str(P)])  # path-native: subprocess needs the OS-native form
'''

NOT_A_PATH = '''
def go(n):
    d = {}
    d[str(n)] = 1
    return f"{n}"
'''


def _findings_for(src: str):
    tree = ast.parse(src)
    seed: set = set()
    a = None
    for _ in range(4):
        a = Analyzer(src, seed)
        a.visit(tree)
        if a.paths == seed:
            break
        seed = a.paths
    return a.findings


def self_test() -> int:
    cases = [
        ("sighting 1 - genericity_check: str(f) into a regex, f from a comprehension "
         "over repo.glob()  [NEEDS THE BINDING PASS]", SIGHTING_1, True),
        ("sighting 2 - check_swift_copy_sites: str(path.relative_to(REPO)) as a "
         "baseline key", SIGHTING_2, True),
        ("benign - print(f'{PATH}') and print(str(PATH))", BENIGN_PRINT, False),
        ("benign - .as_posix() is the fix and must stay silent", BENIGN_AS_POSIX, False),
        ("benign - raise ValueError(f'{P}')", BENIGN_RAISE, False),
        ("waived - explicit # path-native: reason", WAIVED, False),
        ("not a Path - str(n) on a plain name must not fire", NOT_A_PATH, False),
    ]
    failures = []
    for label, src, expect_red in cases:
        got = _findings_for(src)
        red = bool(got)
        if red != expect_red:
            failures.append(
                f"  {label}\n     expected {'RED' if expect_red else 'silent'}, "
                f"got {'RED' if red else 'silent'} ({got})")

    # The floors must themselves be provable.
    if MIN_PATH_NAMES < 1 or MIN_FILES < 1:
        failures.append("  anti-vacuity floors must be positive")

    if failures:
        print("self-test FAILED:", file=sys.stderr)
        for f in failures:
            print(f, file=sys.stderr)
        return 1

    reds = sum(1 for _, _, r in cases if r)
    print(f"self-test: {len(cases)} cases ({reds} RED, {len(cases) - reds} silent) -- "
          f"BOTH historical sightings reproduce RED from their verbatim pre-fix source, "
          f"including the one that needs the binding pass; message sinks, waivers, "
          f"as_posix() and non-Paths all stay silent. Anti-vacuity floors: "
          f"{MIN_FILES} files / {MIN_PATH_NAMES} Path-bound names.")
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true",
                    help="prove the gate's RED against the historical defects and exit")
    args = ap.parse_args()
    sys.exit(self_test() if args.self_test else run())
