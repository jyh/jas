#!/usr/bin/env python3
"""Enforce explicit text encoding and newline handling in shared Python.

THE RULE: every text-mode file open in shared Python states its encoding, and
every text-mode WRITE states its newline handling.

    open(p)                          -> open(p, encoding="utf-8")
    open(p, "w")                     -> open(p, "w", encoding="utf-8", newline="")
    Path(p).read_text()              -> Path(p).read_text(encoding="utf-8")
    Path(p).write_text(s)            -> Path(p).write_text(s, encoding="utf-8", newline="")

WHY THIS CHECK EXISTS: on 2026-07-28 this project's CI gates ran on Windows for
the first time -- every gate to date had only ever run on macOS and Linux, both
of which default to UTF-8 and LF. 11 of 24 gate invocations failed, and not one
of the failures was a real defect in repo content. Two platform defects, each
invisible by construction on the platforms that had been trusted:

  * ENCODING. Python without an explicit `encoding=` uses the LOCALE codec, which
    is cp1252 on this Windows box. `workspace_interpreter/loader.py:82` was a
    bare `with open(fpath, "r")`, and it died with UnicodeDecodeError on
    `workspace/panels/concepts.yaml` at the first em-dash. That is the MILD
    outcome. The severe one is silent: cp1252 decodes most of UTF-8's high
    bytes to *something*, so a spec file full of em-dash, section-sign and
    ellipsis -- which `workspace/*.yaml` is -- can be read as plausible garbage
    instead of raising. `workspace/*.yaml` is the executable meaning of this
    whole project. A silently mis-decoded spec is worse than a crash.

  * NEWLINE. Text-mode writes translate "\\n" to "\\r\\n" on Windows, so every
    generated corpus byte-differed from its committed golden and seven
    freshness gates went red on data that was perfectly current. Proven at the
    time: the regenerated `workspace.json`, all 40,376 lines, was byte-identical
    to the committed golden once CR was stripped.

    The newline half is GATE NOISE, not data corruption: `.gitattributes` line 5
    is `* text=auto eol=lf` under the comment "LF is law in this repository", so
    git normalises on commit and a Windows working tree cannot corrupt a shared
    golden. It is fixed so the gates pass honestly, not to protect the data.

CENSUS AT THE TIME OF THE FIX (shared Python, frozen ports excluded):
91 sites missing `encoding=`, 37 missing `newline=`. That count is itself a
lesson. Two seats independently grepped for it and got 69 and 73; the truth was
neither. Grep cannot span a call split across lines, and it cannot tell
`open(p, "rb")` -- which correctly carries no encoding -- from `open(p, "r")`.
The 73 was 69 real sites plus 4 binary-mode opens counted as defects. And BOTH
numbers missed 22 `Path.read_text`/`write_text` sites entirely, because both
seats had grepped for `open(`. This gate walks the AST for exactly that reason,
and covers pathlib from its first commit so that CI does not institutionalise
the blind spot the two humanish instruments shared.

SCOPE: git-tracked `*.py`, excluding the two ports FROZEN at tag
`five-port-parity` (`jas/`, `jas_ocaml/`) per POLICY.md. Tracking is the honest
definition of "what this project authors" -- it excludes `.venv/`, build trees
and vendored code by construction rather than by a skip list that rots. The
frozen ports carry 43 encoding and 7 newline sites of their own; they are
deliberately NOT swept, because honoring the tag outranks platform hygiene in
code that is not built here.

WHAT THIS CHECK DELIBERATELY CANNOT SEE -- stated because a gate whose blind
spots are unknown is the defect it exists to prevent, one level up. Each was
measured over the scope on 2026-07-28, not guessed:

  * SUBPROCESS TEXT PIPES -- 17 sites. `subprocess.run(..., text=True)`,
    `check_output(...)` and `.decode()` with no argument all use the locale
    codec, exactly like a bare `open()`. This is the largest thing the gate
    misses and it is a real exposure, not a theoretical one. It is out of scope
    because the fix is not uniform: some of those pipes carry bytes that are
    genuinely not UTF-8. Left for a follow-up rather than swept blind.
  * ATTRIBUTE `.open()` CALLS. `os.open` (flags, no encoding), and
    `gzip`/`bz2`/`lzma`/`zipfile`/`tarfile`/`shelve`/`dbm`.open all take an
    `open` name with different semantics; flagging them would be an overcount.
    Measured: 0 in scope today. `io.open`, `codecs.open` and `Path(...).open()`
    DO take `encoding=` and would be genuine findings -- also measured 0 today,
    so the gate would not see one if it were introduced tomorrow.
  * CSV WRITERS. `csv.writer` needs `newline=""` on its underlying handle on
    every platform, not just Windows. Measured: 0 in scope.
  * TEMPFILE HANDLES -- 1 site. `NamedTemporaryFile`/`TemporaryFile`/`mkstemp`
    in text mode take an encoding this gate does not inspect.
  * WRAPPED OPENS. A helper that opens a file on its caller's behalf is judged
    at the helper, which is correct, but a helper in an unscanned tree is
    invisible.
  * DYNAMIC MODES. `open(p, mode)` where `mode` is a variable is treated as
    text (the conservative reading: it demands an encoding). A binary open
    written that way would be a false positive; measured 0 today.

EXEMPTION: a line carrying the marker `encoding-exempt` in a comment is
skipped, and the marker must be on the line where the call STARTS. Use it only
where an explicit encoding would be wrong, and say why on the same line.
"""

import ast
import os
import subprocess
import sys

MARKER = "encoding-exempt"

# Ports FROZEN at tag five-port-parity (POLICY.md). Not swept: honoring the tag
# outranks platform hygiene in code that is not built here.
FROZEN_PREFIXES = ("jas/", "jas_ocaml/")

# See the blind-spot section: these owners give `.open` a different meaning.
NON_FILE_OPEN_OWNERS = {
    "os", "webbrowser", "gzip", "bz2", "lzma", "zipfile", "tarfile",
    "shelve", "dbm", "sqlite3", "socket", "wave",
}

MISSING_ENCODING = "missing encoding="
MISSING_NEWLINE = "missing newline="


class Violation:
    def __init__(self, path, line, kind, what):
        self.path = path
        self.line = line
        self.kind = kind
        self.what = what

    def __repr__(self):
        return f"{self.path}:{self.line}  {self.kind}  ({self.what})"

    def key(self):
        return (self.path, self.line, self.kind)


def _mode_of(call):
    """The mode string of an open() call; 'r' when absent (Python's default).

    A non-constant mode returns None, which the caller treats as TEXT -- the
    conservative reading, since a text open is the one that needs an encoding.
    """
    if len(call.args) >= 2:
        arg = call.args[1]
        if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
            return arg.value
        return None
    for kw in call.keywords:
        if kw.arg == "mode":
            if isinstance(kw.value, ast.Constant) and isinstance(kw.value.value, str):
                return kw.value.value
            return None
    return "r"


def _kwnames(call):
    return {kw.arg for kw in call.keywords if kw.arg}


def _classify(call):
    """('open' | 'read_text' | 'write_text' | None, owner_name_or_None)."""
    f = call.func
    if isinstance(f, ast.Name):
        return ("open", None) if f.id == "open" else (None, None)
    if isinstance(f, ast.Attribute):
        owner = f.value.id if isinstance(f.value, ast.Name) else None
        if f.attr in ("read_text", "write_text"):
            return f.attr, owner
        # Deliberately NOT flagged -- see the blind-spot section.
        return None, owner
    return None, None


def scan(sources):
    """Find violations in {path: source_text}. Injectable so the self-test can
    drive a fake corpus rather than the real tree."""
    out = []
    for path in sorted(sources):
        if path.replace(os.sep, "/").startswith(FROZEN_PREFIXES):
            continue
        src = sources[path]
        try:
            tree = ast.parse(src)
        except SyntaxError:
            continue
        lines = src.splitlines()

        def exempt(lineno):
            return 1 <= lineno <= len(lines) and MARKER in lines[lineno - 1]

        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            kind, owner = _classify(node)
            if kind is None:
                continue
            if kind == "open":
                if owner in NON_FILE_OPEN_OWNERS:
                    continue
                mode = _mode_of(node)
                if mode is not None and "b" in mode:
                    continue  # binary: encoding/newline correctly absent
                kws = _kwnames(node)
                writing = mode is None or any(c in mode for c in ("w", "a", "x", "+"))
                if exempt(node.lineno):
                    continue
                if "encoding" not in kws:
                    out.append(Violation(path, node.lineno, MISSING_ENCODING, "open()"))
                if writing and mode is not None and "newline" not in kws:
                    out.append(Violation(path, node.lineno, MISSING_NEWLINE, "open()"))
            else:
                if exempt(node.lineno):
                    continue
                kws = _kwnames(node)
                if "encoding" not in kws:
                    out.append(Violation(path, node.lineno, MISSING_ENCODING, f"Path.{kind}()"))
                if kind == "write_text" and "newline" not in kws:
                    out.append(Violation(path, node.lineno, MISSING_NEWLINE, f"Path.{kind}()"))
    return out


def tracked_python(repo_root):
    """git-tracked *.py -- the honest definition of what this project authors."""
    try:
        out = subprocess.run(
            ["git", "-C", repo_root, "ls-files", "*.py"],
            capture_output=True, check=True,
        ).stdout.decode("utf-8")
    except (subprocess.CalledProcessError, FileNotFoundError):
        return {}
    sources = {}
    for rel in out.splitlines():
        rel = rel.strip()
        if not rel:
            continue
        if rel.startswith(FROZEN_PREFIXES):
            continue
        full = os.path.join(repo_root, rel)
        try:
            with open(full, "r", encoding="utf-8") as fh:  # encoding-exempt: this gate reads UTF-8 by definition
                sources[rel] = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
    return sources


def self_test():
    """Prove the gate goes RED on each class it claims to cover.

    A gate is trusted for its red, not its green: one that can only pass is
    indistinguishable from no gate at all. Every case here is a class this
    check has to get right, including the two that made the hand-counts wrong.
    """
    corpus = {
        # (a) the default-mode bare open -- loader.py:82's exact shape
        "a.py": "with open(p) as f:\n    pass\n",
        # (b) explicit text read
        "b.py": 'open(p, "r")\n',
        # (c) a text write is TWO violations, encoding and newline
        "c.py": 'open(p, "w")\n',
        # (d) BINARY IS NOT A VIOLATION. This is the case that made a grep
        #     census overcount by 4 and report 73 where the truth was 69.
        "d.py": 'open(p, "rb")\nopen(p, "wb")\n',
        # (e) encoding present, newline missing -- the write half alone
        "e.py": 'open(p, "w", encoding="utf-8")\n',
        # (f) pathlib read -- invisible to a grep for "open("
        "f.py": "Path(p).read_text()\n",
        # (g) pathlib write -- two violations, same as (c)
        "g.py": "Path(p).write_text(s)\n",
        # (h) attribute opens with other semantics are NOT violations
        "h.py": "os.open(p, flags)\ngzip.open(p)\n",
        # (i) a call SPLIT ACROSS LINES is still caught. This is precisely
        #     what a line-oriented grep cannot see, and why this walks the AST.
        "i.py": "open(\n    p,\n    'w',\n)\n",
        # (j) fully correct code is silent
        "j.py": 'open(p, "w", encoding="utf-8", newline="")\n'
                'Path(p).read_text(encoding="utf-8")\n',
        # (k) the line marker suppresses just that line
        "k.py": "open(p)  # encoding-exempt: reason\n",
        # (l) FROZEN ports are out of scope even though they carry the defect
        "jas/x.py": "open(p)\n",
        "jas_ocaml/y.py": "open(p)\n",
    }
    v = scan(corpus)
    got = {}
    for viol in v:
        got.setdefault(viol.path, []).append(viol.kind)

    expected = {
        "a.py": [MISSING_ENCODING],
        "b.py": [MISSING_ENCODING],
        "c.py": [MISSING_ENCODING, MISSING_NEWLINE],
        "e.py": [MISSING_NEWLINE],
        "f.py": [MISSING_ENCODING],
        "g.py": [MISSING_ENCODING, MISSING_NEWLINE],
        "i.py": [MISSING_ENCODING, MISSING_NEWLINE],
    }
    silent = ["d.py", "h.py", "j.py", "k.py", "jas/x.py", "jas_ocaml/y.py"]

    failures = []
    for path, kinds in expected.items():
        if sorted(got.get(path, [])) != sorted(kinds):
            failures.append(f"  {path}: expected {sorted(kinds)}, got {sorted(got.get(path, []))}")
    for path in silent:
        if got.get(path):
            failures.append(f"  {path}: expected NO violation, got {got[path]}")

    if failures:
        print("SELF-TEST FAILED -- the gate does not detect what it claims:")
        print("\n".join(failures))
        return 1
    print(f"self-test: {len(expected)} fail-classes detected, "
          f"{len(silent)} silent-classes clean -- gate proven RED where it must be.")
    return 0


def main():
    if "--self-test" in sys.argv:
        return self_test()

    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    sources = tracked_python(repo_root)
    violations = scan(sources)

    if not violations:
        print(f"encoding hygiene: {len(sources)} tracked Python files scanned, "
              f"0 violations (frozen ports excluded by policy).")
        return 0

    enc = [v for v in violations if v.kind == MISSING_ENCODING]
    nl = [v for v in violations if v.kind == MISSING_NEWLINE]
    print(f"ERROR: {len(violations)} encoding-hygiene violations "
          f"({len(enc)} missing encoding=, {len(nl)} missing newline=) "
          f"across {len(sources)} tracked Python files.", file=sys.stderr)
    print(file=sys.stderr)
    for v in violations:
        print(f"  {v.path}:{v.line}  {v.kind}  ({v.what})", file=sys.stderr)
    print(file=sys.stderr)
    print("A bare open() uses the LOCALE codec, which is cp1252 on Windows and", file=sys.stderr)
    print("mis-decodes the spec's em-dash / section-sign / ellipsis. A text-mode", file=sys.stderr)
    print("write without newline=\"\" emits CRLF into byte-compared goldens.", file=sys.stderr)
    print("Add encoding=\"utf-8\", and newline=\"\" on writes. If an explicit", file=sys.stderr)
    print(f"encoding is genuinely wrong, mark the line `{MARKER}: <why>`.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
