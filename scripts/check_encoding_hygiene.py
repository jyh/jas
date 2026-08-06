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

  * SUBPROCESS TEXT PIPES -- NO LONGER A BLIND SPOT. This section used to say
    "17 sites ... the largest thing the gate misses ... out of scope because
    the fix is not uniform: some of those pipes carry bytes that are genuinely
    not UTF-8." The prediction came true on 2026-08-02, on the Windows lane,
    eleven days later. THE STATED REASON WAS ALSO FALSE: measured, every
    exposed pipe in this tree carries either a roundtrip CLI's JSON (UTF-8 by
    definition) or `git ls-files` paths (git quotes non-ASCII by default, and
    this repository has ZERO non-ASCII tracked paths). Not one carried bytes
    that are genuinely not UTF-8. The scan is now AST-based and covers them;
    cases (j)-(m) below pin the four shapes.

    The count was wrong too, and instructively: a line-oriented census of this
    same class missed THREE sites that the AST walk finds, because the calls
    span lines. Case (i) below had already written down why -- "precisely what
    a line-oriented grep cannot see, and why this walks the AST" -- and the
    census was run with a grep anyway.
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

# ANTI-VACUITY FLOOR. Measured 2026-07-28: 96 tracked .py files in scope.
#
# Without this, `git ls-files` failing, a checkout with no git available, or a
# run from outside the repo all produce an empty file set, and the gate prints
# "0 tracked Python files scanned, 0 violations" and EXITS 0 — a green that is
# indistinguishable from no gate at all. That is precisely the class the
# 2026-07-28 council packet found in all four preservation gates (F1): a single
# `[]` in the corpus turned every one of them green simultaneously, because none
# asserted a minimum. This gate was written the same day and shipped with the
# same hole; the floor is the fix, and it was added after reading that finding.
#
# 50 rather than 96: high enough that an empty or badly truncated scan cannot
# pass, low enough that deleting genuinely dead scripts does not red the build
# and tempt someone to lower it. Raise it if the tree grows a lot.
MIN_TRACKED_FILES = 102
#
# EXACT, NOT SLACK. This was a hand-set floor with room to spare until
# 2026-07-29, when the jas/windows seat proved the hole by mutation: it set a
# test-count floor 1.6% below reality, gated six tests off, and the gate went
# GREEN. Its sentence is the rule now --
#
#     "A floor with slack is a floor with a hole exactly the size of the slack,
#      and the hole admits precisely the move the assertion exists to forbid."
#
# The floor is the ONLY guard: violations inside files the scan never
# opened are simply not reported.
#
# Adding to the set means raising this number in the same commit. That friction
# is the feature: the number is a claim about coverage, and a claim nobody has
# to restate is a claim nobody rechecks. (The model is
# check_preservation_corpus.py, whose floor is DERIVED from per-vector `n_min`
# declarations and therefore cannot drift at all -- prefer that shape where the
# data can declare itself.)


def below_floor(n_files):
    """True when the scan is too small to be believed. See MIN_TRACKED_FILES."""
    return n_files < MIN_TRACKED_FILES

# Ports FROZEN at tag five-port-parity (POLICY.md). Not swept: honoring the tag
# outranks platform hygiene in code that is not built here.
FROZEN_PREFIXES = ("jas/", "jas_ocaml/")

# See the blind-spot section: these owners give `.open` a different meaning.
NON_FILE_OPEN_OWNERS = {
    "os", "webbrowser", "gzip", "bz2", "lzma", "zipfile", "tarfile",
    "shelve", "dbm", "sqlite3", "socket", "wave",
}

# The subprocess calls that can hand back `str`. A pipe decoded without a named
# encoding uses `locale.getpreferredencoding(False)` -- UTF-8 here, cp1252 on
# Windows -- so a lane emitting one non-ASCII byte mojibakes on exactly one
# platform. This gate's own blind-spot section called that shot in advance and
# the follow-up did not happen for eleven days; it happened on 2026-08-02 on the
# Windows lane, to three `paragraph_markers` vectors.
SUBPROCESS_TEXT_CALLS = {"run", "check_output", "Popen", "call", "check_call"}

# `check_output` and friends return BYTES by default. Only an explicit
# text/universal_newlines makes the pipe a decode, so those are the trigger --
# flagging every subprocess call would overcount, which is the same arithmetic
# error the binary-mode case (d) below already cost this gate once.
SUBPROCESS_TEXT_KWS = ("text", "universal_newlines")

MISSING_ENCODING = "missing encoding="
MISSING_NEWLINE = "missing newline="

# The half of a pipe this gate could not see until 2026-08-06.
#
# `encoding="utf-8"` tells the PARENT how to decode. It says nothing about how
# the CHILD encodes, and a Python child writing to a pipe encodes with the
# LOCALE codec -- cp1252 on Windows. So a call that satisfies the arm above can
# still mojibake, and the way it fails is the worst shape found this fortnight:
# the parent's decode raises inside subprocess's internal reader THREAD, the
# traceback is swallowed, `communicate()` returns None for stdout, and `run()`
# hands back returncode 0. rc says success, stderr is empty, stdout is None,
# and the crash lands several frames later as a TypeError.
#
# That took main's Windows CI job red for four consecutive runs on 2026-08-05
# while both seats reported green from machines that happened to have
# PYTHONIOENCODING set. Only a Python child is watched: `git`, `cargo` and
# `swift` do not consult PYTHONIOENCODING, and flagging them would be the same
# overcount the binary-mode case already cost this gate once.
UNFORCED_CHILD_ENCODING = "child encoding not forced (PYTHONIOENCODING)"

# What forcing looks like. Matched as TEXT rather than by interpreting the
# `env=` expression, because the shapes people actually write are
# `{**os.environ, ...}`, `dict(os.environ, ...)` and a name bound earlier --
# and an evaluator that understood only the first would pass the other two
# silently.
#
# Searched over the ENCLOSING FUNCTION, not the call. The first version of this
# arm searched the call's own source segment and immediately red-flagged both
# already-correct sites in this repo, because both build the env on a previous
# line. The comment above this one already listed "a prebuilt name" as a shape
# that occurs, and the implementation still could not see it -- an instrument
# narrower than the question it was written to ask, one paragraph after naming
# the question. Widening trades a theoretical false GREEN (a function that
# mentions the variable for an unrelated reason) for the false REDS that make a
# gate get switched off.
CHILD_ENCODING_VAR = "PYTHONIOENCODING"


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
        if owner == "subprocess" and f.attr in SUBPROCESS_TEXT_CALLS:
            return "subprocess", f.attr
        # Deliberately NOT flagged -- see the blind-spot section.
        return None, owner
    return None, None


def _spawns_python(call):
    """Does this call launch a PYTHON child (`sys.executable`)?

    Walks the whole first argument rather than checking element [0], because
    the argv list is often built by concatenation (`[sys.executable, x] + args`)
    and a positional check would miss every one of those.
    """
    if not call.args:
        return False
    for node in ast.walk(call.args[0]):
        if (isinstance(node, ast.Attribute) and node.attr == "executable"
                and isinstance(node.value, ast.Name) and node.value.id == "sys"):
            return True
    return False


def _forcing_scope(src, tree, call):
    """Source text in which forcing the child's encoding counts as done.

    The innermost enclosing function, or the whole module when the call sits at
    module level. See CHILD_ENCODING_VAR for why this is not the call itself.
    """
    best = None
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        end = getattr(node, "end_lineno", None)
        if end is None or not (node.lineno <= call.lineno <= end):
            continue
        # Innermost wins: a nested helper is a tighter scope than its parent.
        if best is None or node.lineno > best.lineno:
            best = node
    if best is None:
        return src
    return ast.get_source_segment(src, best) or src


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
            if kind == "subprocess":
                if exempt(node.lineno):
                    continue
                kws = _kwnames(node)
                # A pipe is only a DECODE when something asks for str.
                if not any(k in kws for k in SUBPROCESS_TEXT_KWS):
                    continue
                if "encoding" not in kws:
                    out.append(Violation(path, node.lineno, MISSING_ENCODING,
                                         f"subprocess.{owner}()"))
                elif _spawns_python(node):
                    # The parent decodes correctly; does the CHILD encode that
                    # way? Only asked when `encoding=` is already present,
                    # because otherwise the call is reported once above and two
                    # findings for one line would double-count the class.
                    seg = _forcing_scope(src, tree, node)
                    if CHILD_ENCODING_VAR not in seg:
                        out.append(Violation(path, node.lineno,
                                             UNFORCED_CHILD_ENCODING,
                                             f"subprocess.{owner}([sys.executable, ...])"))
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
        # (j) SUBPROCESS TEXT PIPES -- the class this gate named in its own
        #     blind-spot section as "the largest thing the gate misses", left
        #     for a follow-up that did not happen for eleven days. It happened
        #     on the Windows lane instead, to three paragraph_markers vectors.
        "sub_text.py": "subprocess.run(cmd, capture_output=True, text=True)\n",
        # (k) universal_newlines is text=True's older spelling and decodes the
        #     same way. A gate watching only `text=` would miss every legacy
        #     call site, which is how a rename hides a class.
        "sub_univ.py": "subprocess.check_output(cmd, universal_newlines=True)\n",
        # (l) A PIPE THAT NAMES ITS ENCODING IS CLEAN.
        "sub_named.py": 'subprocess.run(cmd, text=True, encoding="utf-8")\n',
        # (m) A PYTHON CHILD WHOSE OWN ENCODING IS NOT FORCED. The parent
        #     decodes as utf-8 and the child encodes with the locale codec, so
        #     this passes the arm above and still mojibakes. It is the shape
        #     that took main's Windows CI red for four runs.
        "spawn_unforced.py":
            'subprocess.run([sys.executable, "x.py"], capture_output=True,\n'
            '               text=True, encoding="utf-8")\n',
        # (n) FORCED IS CLEAN. Asserted so the rule cannot be "always red on a
        #     python child", which would be unfixable and therefore ignored.
        "spawn_forced.py":
            'subprocess.run([sys.executable, "x.py"], capture_output=True,\n'
            '               text=True, encoding="utf-8",\n'
            '               env={**os.environ, "PYTHONIOENCODING": "utf-8"})\n',
        # (o) THE ARGV IS OFTEN BUILT BY CONCATENATION. A check that looked at
        #     element [0] of the list would miss every call of this shape --
        #     cross_language_workspace.py is written exactly like this.
        "spawn_concat.py":
            'subprocess.run([sys.executable, "x.py"] + args, capture_output=True,\n'
            '               text=True, encoding="utf-8")\n',
        # (p) A NON-PYTHON CHILD IS NOT A VIOLATION. git, cargo and swift do
        #     not consult PYTHONIOENCODING; flagging them would be the same
        #     overcount case (d) already cost this gate once.
        "spawn_git.py":
            'subprocess.run(["git", "status"], capture_output=True,\n'
            '               text=True, encoding="utf-8")\n',
        # (q) THE ENV BUILT ON AN EARLIER LINE. This is the shape BOTH correct
        #     sites in this repo use, and the first version of this arm flagged
        #     both of them because it searched only the call's own source. The
        #     case exists so that narrowing it again reds here.
        "spawn_prebuilt.py":
            'def go():\n'
            '    env = dict(os.environ, PYTHONIOENCODING="utf-8")\n'
            '    return subprocess.run([sys.executable, "x.py"],\n'
            '                          capture_output=True, text=True,\n'
            '                          encoding="utf-8", env=env)\n',
        # (r) THE SCOPE IS THE FUNCTION, NOT THE FILE. One forced call and one
        #     unforced call in the same module must produce EXACTLY ONE
        #     violation -- if the scope widened to the whole file, the forced
        #     function would vouch for the unforced one and this case would go
        #     silent.
        "spawn_two_fns.py":
            'def forced():\n'
            '    env = dict(os.environ, PYTHONIOENCODING="utf-8")\n'
            '    return subprocess.run([sys.executable, "a.py"],\n'
            '                          capture_output=True, text=True,\n'
            '                          encoding="utf-8", env=env)\n'
            'def unforced():\n'
            '    return subprocess.run([sys.executable, "b.py"],\n'
            '                          capture_output=True, text=True,\n'
            '                          encoding="utf-8")\n',
        # (m) BYTES ARE NOT A VIOLATION -- `check_output` returns bytes unless
        #     something asks for str. Flagging every subprocess call would
        #     overcount by exactly the arithmetic error case (d) already cost
        #     this gate once, in the other direction.
        "sub_bytes.py": "subprocess.run(cmd, capture_output=True)\n"
                        "subprocess.check_output(cmd)\n",
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
        # The child-encoding arm. Only the two unforced python spawns fire:
        # spawn_forced.py names the variable and spawn_git.py is not a python
        # child. Neither carries a newline= duty, because a pipe is not a file.
        "spawn_unforced.py": [UNFORCED_CHILD_ENCODING],
        "spawn_concat.py": [UNFORCED_CHILD_ENCODING],
        "spawn_two_fns.py": [UNFORCED_CHILD_ENCODING],
        # The subprocess arm. Both decoding spellings must fire; neither
        # carries a newline= duty, because a pipe is not a file.
        "sub_text.py": [MISSING_ENCODING],
        "sub_univ.py": [MISSING_ENCODING],
    }
    silent = ["d.py", "h.py", "j.py", "k.py", "jas/x.py", "jas_ocaml/y.py",
              # A pipe that names its encoding, and pipes that stay BYTES.
              "sub_named.py", "sub_bytes.py"]

    failures = []
    for path, kinds in expected.items():
        if sorted(got.get(path, [])) != sorted(kinds):
            failures.append(f"  {path}: expected {sorted(kinds)}, got {sorted(got.get(path, []))}")
    for path in silent:
        if got.get(path):
            failures.append(f"  {path}: expected NO violation, got {got[path]}")

    # THE ANTI-VACUITY FLOOR is itself a class this gate has to get right: a run
    # that scanned nothing must not read as a run that found nothing.
    for n, want_rejected in [
        (0, True),                        # git failed / not a checkout
        (1, True),                        # a badly truncated scan
        (MIN_TRACKED_FILES - 1, True),    # just under the line
        (MIN_TRACKED_FILES, False),       # exactly at it
        (102, False),                     # the real tree, measured 2026-07-29
    ]:
        if below_floor(n) != want_rejected:
            verb = "reject" if want_rejected else "accept"
            failures.append(f"  floor: a {n}-file scan should {verb}")

    if failures:
        print("SELF-TEST FAILED -- the gate does not detect what it claims:")
        print("\n".join(failures))
        return 1
    print(f"self-test: {len(expected)} fail-classes detected, "
          f"{len(silent)} silent-classes clean, anti-vacuity floor holds "
          f"at {MIN_TRACKED_FILES} -- gate proven RED where it must be.")
    return 0


def main():
    if "--self-test" in sys.argv:
        return self_test()

    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    sources = tracked_python(repo_root)

    # Assert the scan happened at all, BEFORE trusting its silence.
    if below_floor(len(sources)):
        print(f"ERROR: scanned only {len(sources)} tracked Python files, below the "
              f"anti-vacuity floor of {MIN_TRACKED_FILES}.", file=sys.stderr)
        print(file=sys.stderr)
        print("This is not a pass. A gate that finds no files reports no violations,", file=sys.stderr)
        print("which is indistinguishable from a gate that is working. Likely causes:", file=sys.stderr)
        print("  * git is unavailable, or this is not a git checkout", file=sys.stderr)
        print("  * run from outside the repository", file=sys.stderr)
        print("  * a shallow or partial checkout", file=sys.stderr)
        print(f"If the tree legitimately shrank below {MIN_TRACKED_FILES} files, lower", file=sys.stderr)
        print("MIN_TRACKED_FILES deliberately and say why.", file=sys.stderr)
        return 1

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
