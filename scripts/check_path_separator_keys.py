#!/usr/bin/env python3
"""check_path_separator_keys — a `str(Path)` that becomes a KEY, not a message.

WHY THIS EXISTS
---------------
On Windows `str(Path)` yields `\\` separators; on macOS and Linux it is already
POSIX, so the defect is INVISIBLE on the platforms most of this repo's CI runs on.
Three sites in `scripts/` were each repaired individually, each with a comment
explaining the hazard — and nothing was ever built to police the class. Stubb's
letter 14 said so plainly: *"Three sites, three comments, no gate. Nothing in
`scripts/` polices the class. A fourth sighting can land tomorrow and CI will be
green."* That condition is the oldest item on the windows seat's board. This is it.

WHAT IT FLAGS — the dangerous flow, not the syntax
--------------------------------------------------
A census before the rule was chosen: 25 sites in `scripts/` interpolate a
path-valued name, and **every one sampled was DISPLAY** — an error message naming
a file. A gate on `str(Path)` as a *syntax* would therefore have been 25 false
positives on day one and would have been switched off within a week.

What actually broke was never display. It was a stringified path used as a KEY or
a MATCH TARGET against POSIX-shaped data:

    rel = str(path.relative_to(REPO))              # baseline JSON is POSIX-keyed
    files = [f for f in files if not exclude_re.search(str(f))]   # "/"-anchored

Both are real lines, recovered from this repo's history (09b2f2be, af7e50c7), and
both are self-test fixtures below. So the rules are:

    A. str(<path>) passed to a regex call         re.search(p, str(f)) / rx.match(str(f))
    B. str(<expr>.relative_to(...))               a repo-relative path is a key by construction
    C. str(<path>) used as a subscript key, a comparison operand, or an `in` test

`print(f"no baseline at {BASELINE}")` is untouched, deliberately, and there is a
self-test arm that fails if it ever stops being untouched.

⛔ WHAT IT CANNOT SEE, stated rather than discovered: provenance is tracked only
within a file, by binding — `Path(...)`, `X / "y"`, `.glob()`, `.parent`,
`.resolve()`. A path arriving as a bare function parameter with no annotation is
invisible to it. The net is deliberately narrow: this gate exists to hold a class
at zero, and a gate that cries wolf is a gate that gets disabled.

usage:
  check_path_separator_keys.py [paths...]   default: scripts/
  check_path_separator_keys.py --self-test  prove the gate before believing it
"""
from __future__ import annotations

import ast
import pathlib
import sys
import tempfile

PATHY_CALLS = {"Path", "PurePath", "PurePosixPath", "PureWindowsPath"}
PATHY_METHODS = {"resolve", "absolute", "expanduser", "relative_to", "with_suffix",
                 "with_name", "joinpath"}
PATHY_ITERS = {"glob", "rglob", "iterdir"}
PATHY_ATTRS = {"parent", "parents"}
CONTAINER_WRAPPERS = {"sorted", "list", "tuple", "set", "reversed", "iter"}
REGEX_FUNCS = {"search", "match", "fullmatch", "sub", "subn", "split", "findall", "finditer"}


class Finder(ast.NodeVisitor):
    """Collect path-valued names, then report str() of them in KEY positions."""

    def __init__(self, rel: str) -> None:
        self.rel = rel
        self.pathy: set[str] = set()
        self.hits: list[tuple[int, str, str]] = []
        self._key_ctx: list[str] = []

    # ---------------------------------------------------------------- provenance
    def _pathy(self, node: ast.AST) -> bool:
        if isinstance(node, ast.Call):
            fn = node.func
            if isinstance(fn, ast.Name) and fn.id in PATHY_CALLS:
                return True
            # Container wrappers are TRANSPARENT: `sorted(repo.glob("*.py"))` is a
            # list of Paths, and the real af7e50c7 defect was one comprehension
            # away from exactly that. The self-test caught this gap -- the rule
            # missed a REAL historical line until wrappers were seen through.
            if isinstance(fn, ast.Name) and fn.id in CONTAINER_WRAPPERS and node.args:
                return self._pathy(node.args[0])
            if isinstance(fn, ast.Attribute):
                if fn.attr in PATHY_METHODS or fn.attr in PATHY_ITERS:
                    return True
                return self._pathy(fn.value)
            return False
        if isinstance(node, ast.Attribute):
            return node.attr in PATHY_ATTRS or self._pathy(node.value)
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            return self._pathy(node.left)
        if isinstance(node, ast.Name):
            return node.id in self.pathy
        if isinstance(node, ast.Subscript):
            return self._pathy(node.value)
        return False

    def visit_Assign(self, node: ast.Assign) -> None:
        if self._pathy(node.value):
            for t in node.targets:
                if isinstance(t, ast.Name):
                    self.pathy.add(t.id)
        self.generic_visit(node)

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        if node.value is not None and self._pathy(node.value):
            if isinstance(node.target, ast.Name):
                self.pathy.add(node.target.id)
        self.generic_visit(node)

    def visit_For(self, node: ast.For) -> None:
        if self._pathy(node.iter) and isinstance(node.target, ast.Name):
            self.pathy.add(node.target.id)
        self.generic_visit(node)

    def visit_ListComp(self, node):  # noqa: N802 - ast API
        self._comp(node)

    def visit_SetComp(self, node):  # noqa: N802
        self._comp(node)

    def visit_GeneratorExp(self, node):  # noqa: N802
        self._comp(node)

    def visit_DictComp(self, node):  # noqa: N802
        self._comp(node)

    def _comp(self, node) -> None:
        for gen in node.generators:
            if self._pathy(gen.iter) and isinstance(gen.target, ast.Name):
                self.pathy.add(gen.target.id)
        self.generic_visit(node)

    # ------------------------------------------------------------------- the rules
    @staticmethod
    def _is_str_call(node: ast.AST) -> ast.AST | None:
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) \
                and node.func.id == "str" and len(node.args) == 1:
            return node.args[0]
        return None

    def _report(self, node: ast.AST, rule: str, detail: str) -> None:
        self.hits.append((getattr(node, "lineno", 0), rule, detail))

    def visit_Call(self, node: ast.Call) -> None:
        # RULE B: str(x.relative_to(...)) -- a repo-relative path is a key by
        # construction, whatever it is handed to next.
        inner = self._is_str_call(node)
        if inner is not None and isinstance(inner, ast.Call) \
                and isinstance(inner.func, ast.Attribute) and inner.func.attr == "relative_to":
            self._report(node, "B", "str(<path>.relative_to(...)) — a POSIX-shaped key")

        # RULE A: str(<path>) handed to a regex function or compiled-pattern method.
        fn = node.func
        is_regex = (
            (isinstance(fn, ast.Attribute) and fn.attr in REGEX_FUNCS)
            or (isinstance(fn, ast.Name) and fn.id in REGEX_FUNCS)
        )
        if is_regex:
            for arg in node.args:
                target = self._is_str_call(arg)
                if target is not None and self._pathy(target):
                    self._report(node, "A", f"str(<path>) matched by .{getattr(fn, 'attr', getattr(fn, 'id', '?'))}()")
        self.generic_visit(node)

    def visit_Subscript(self, node: ast.Subscript) -> None:
        # RULE C(i): d[str(<path>)]
        target = self._is_str_call(node.slice)
        if target is not None and self._pathy(target):
            self._report(node, "C", "str(<path>) used as a subscript key")
        self.generic_visit(node)

    def visit_Compare(self, node: ast.Compare) -> None:
        # RULE C(ii): str(<path>) == "..."  /  str(<path>) in <collection>
        for side in [node.left, *node.comparators]:
            target = self._is_str_call(side)
            if target is not None and self._pathy(target):
                self._report(node, "C", "str(<path>) compared or membership-tested")
        self.generic_visit(node)


def scan_file(path: pathlib.Path, root: pathlib.Path) -> list[tuple[str, int, str, str]]:
    try:
        src = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return []
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return []
    rel = path.relative_to(root).as_posix() if path.is_relative_to(root) else path.as_posix()
    f = Finder(rel)
    # Two passes: a name can be bound after the use that reads it (module-level
    # constants are the common case), and one pass would miss those bindings.
    f.visit(tree)
    f.hits = []
    f.visit(tree)
    return [(rel, ln, rule, detail) for ln, rule, detail in f.hits]


def scan(targets: list[pathlib.Path], root: pathlib.Path):
    files, hits = 0, []
    for t in targets:
        paths = sorted(t.rglob("*.py")) if t.is_dir() else [t]
        for p in paths:
            if "__pycache__" in p.parts or ".venv" in p.parts:
                continue
            files += 1
            hits.extend(scan_file(p, root))
    return files, hits


FIXTURES: dict[str, tuple[str, bool]] = {
    # (source, must_fail) -- the first two are REAL lines from this repo's history.
    "historical-relative_to (09b2f2be)": ("""
from pathlib import Path
REPO = Path(".")
def scan():
    for path in REPO.rglob("*.swift"):
        rel = str(path.relative_to(REPO))
        yield rel
""", True),
    "historical-regex (af7e50c7)": ("""
import re
from pathlib import Path
repo = Path(".")
exclude_re = re.compile("x")
files = sorted(repo.glob("*.py"))
files = [f for f in files if not exclude_re.search(str(f))]
""", True),
    "key-position (the shape letter 14 warned about)": ("""
from pathlib import Path
ROOT = Path(".")
seen = {}
def key(site):
    p = ROOT / site
    return seen[str(p)]
""", True),
    "membership": ("""
from pathlib import Path
ROOT = Path(".")
baseline = set()
p = ROOT / "a.py"
if str(p) in baseline:
    pass
""", True),
    "FIXED form - as_posix()": ("""
import re
from pathlib import Path
REPO = Path(".")
exclude_re = re.compile("x")
for path in REPO.rglob("*.swift"):
    rel = path.relative_to(REPO).as_posix()
    if not exclude_re.search(path.as_posix()):
        pass
""", False),
    "DISPLAY - must never fire (the false-positive guard)": ("""
from pathlib import Path
BASELINE = Path("b.json")
p = BASELINE.parent / "x"
print(f"no baseline at {BASELINE}")
print("path is " + str(p))
""", False),
}


def self_test() -> int:
    failures = 0
    print("self-test: each arm states its expectation BEFORE it runs")
    with tempfile.TemporaryDirectory() as td:
        root = pathlib.Path(td)
        for name, (src, must_fail) in FIXTURES.items():
            f = root / (f"fx_{abs(hash(name)) % 10**8}.py")
            f.write_text(src, encoding="utf-8")
            _, hits = scan([f], root)
            fired = bool(hits)
            ok = fired == must_fail
            failures += 0 if ok else 1
            want = "MUST FLAG" if must_fail else "must stay silent"
            got = f"{len(hits)} hit(s)" + (f" [{hits[0][2]}]" if hits else "")
            print(f"  {'ok  ' if ok else 'FAIL'} {want:<16} {got:<16} {name}")

        # VACUITY: a scan that inspects nothing must not be reported as clean.
        empty = root / "empty_dir"
        empty.mkdir()
        files, hits = scan([empty], root)
        ok = files == 0
        print(f"  {'ok  ' if ok else 'FAIL'} vacuity          scanned {files} file(s) -- "
              f"a run over nothing must be REFUSED by main(), not called clean")
        failures += 0 if ok else 1

    if failures:
        print(f"self-test: FAILED ({failures})")
        return 1
    print("self-test: PASS - both historical defects flagged, both fixed forms silent, "
          "display untouched")
    return 0


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return self_test()
    root = pathlib.Path(__file__).resolve().parent.parent
    targets = [pathlib.Path(a) for a in argv[1:]] or [root / "scripts"]
    files, hits = scan(targets, root)

    # A gate that inspected nothing must never report success.
    if files == 0:
        print("check_path_separator_keys: FAIL — scanned 0 files. Refusing to "
              "report a clean result from an empty scan.")
        return 2

    if hits:
        print("check_path_separator_keys: a stringified Path is being used as a KEY "
              "or MATCH TARGET.")
        print("On Windows str(Path) yields '\\' separators and the comparison misses "
              "BOTH ways at once.\n")
        for rel, line, rule, detail in hits:
            print(f"  {rel}:{line}  [rule {rule}]  {detail}")
        print("\n  fix: use .as_posix() — never str() — wherever the value is compared, "
              "matched or keyed.")
        return 1

    print(f"check_path_separator_keys: OK ({files} file(s) scanned, no stringified "
          f"Path in a key or match position)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
