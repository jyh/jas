#!/usr/bin/env python3
"""Corpus-completeness gate (Arc 1 S4).

Verifies that every conformance-corpus family (the ``test_fixtures/``
subdirectories plus the ``workspace/tests/`` entries) is consumed by the
consumers ``scripts/corpus_manifest.json`` requires, that the two ACTIVE
ports (Rust and Swift — POLICY.md #1) claim the SAME fixtures wherever the
manifest declares port symmetry, that no fixture family exists without a
manifest row, and that no fixture file is an orphan nobody consumes.

Claim extraction is per-consumer and CONVENTION-AWARE — the corpus is
consumed through several distinct registration styles and a naive
code-literal grep both misses real consumers and invents false ones:

  * PATH-SHAPED literals: ``"operations/tspan_ops.json"``,
    ``"svg/eye.svg"``, ``"test_fixtures/algorithms/align.json"`` — matched
    anywhere in a consumer's sources. Interpolated forms
    (``"gestures/{}"``, ``"actions/\\(fixture)"``) never match, by design.
  * NAME-LIST arrays whose family prefix is added by a helper:
    Rust ``GESTURE_FIXTURES``/``ACTION_FIXTURES``/``KEY_FIXTURES`` and the
    ``let names = [...]`` arrays of the svg/json/binary round-trip tests;
    Swift ``gestureFixtures``/``actionFixtures``/``keyFixtures`` and the
    round-trip name arrays; the driver scripts' ``FIXTURE_NAMES`` /
    ``ALGORITHMS`` tables.
  * HELPER CALLS carrying a bare name the helper expands:
    ``assert_svg_parse("x")`` / ``assertSvgParse("x")``,
    ``runOperationFixture("x.json")``, ``_golden("x")``, ….
  * PYTHON PATH SEGMENTS: ``os.path.join(…, "test_fixtures", "artboards",
    "default_seeded.json")`` and the pathlib ``/`` chain equivalents.
  * DIRECTORY GLOBS: consumers that read a whole directory
    (Rust's ``json_roundtrip_all_fixtures`` over ``svg/``; the reference's
    ``test_phase3_fixtures.py`` / ``test_set_effect.py`` over their
    ``workspace/tests`` dirs). A glob is a DIRECTORY-level claim: every
    current file counts as consumed, so orphan detection inside such a
    family is VACUOUS (the manifest notes say so honestly). Because
    ``test_phase3_fixtures.py`` silently passes when its directory is
    missing, the gate independently asserts every glob directory exists
    and is non-empty.
  * TRANSITIVE DATA REFERENCES: driver fixtures name their setups and
    goldens in DATA, not code (``setup_svg`` / ``setup`` /
    ``expected_json`` / ``expected_journal_json`` /
    ``expected_document_json`` / ``expected_output_json``). 60+ operations
    files exist ONLY that way (e.g. ``move_first_rect.json``,
    ``tspan_set_attribute_mid_word.json``); the transitive pass parses
    every claimed ``.json`` fixture and chases those fields to a fixpoint.
    A code-literal-only grep would false-red them all.

Claims are always resolved to full ``family/name`` paths — never counted
as bare stems — so ``foo.json`` being claimed can never mask an
unreferenced ``foo_expected.json`` (the self-test pins exactly that trap).

Comment-text references DO count as claims (the extraction does not parse
the host languages), so a fixture referenced only in prose could in
principle hide as a false non-orphan; the corpus's comments name only
fixtures their own file registers, which keeps this honest in practice.

WHAT THIS GATE DOES NOT CHECK, and how it says so. Everything above is
about whether fixtures are CONSUMED; nothing here can tell whether a
consumed fixture reaches the interesting branch. That is why the manifest
carries two gap lists, of opposite shapes:

  * ``known_gaps`` SUPPRESSES: each row names one check on one
    family/file and downgrades its failure to a warning. A row that
    suppresses nothing on a run is reported as ``stale-known-gap`` — it
    has outlived its defect and is quietly narrowing the gate.
  * ``coverage_gaps`` DECLARES: rows describing what the corpus cannot
    currently reach at all. They suppress nothing and are printed on
    every run, green or not, so a passing gate stops implying a
    completeness it never checked. Each row must carry a non-empty id,
    title, evidence, blocks and unblock; an unknown key or a duplicate id
    is an error, and an ABSENT ``coverage_gaps`` key is an error too
    (silence and an explicit ``[]`` are different claims).

Usage:
    python scripts/check_corpus_manifest.py              # the real gate
    python scripts/check_corpus_manifest.py --self-test  # checker self-test

Exit status 0 = green, 1 = violations, 2 = usage/manifest error.
Requires only the Python standard library.
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "corpus_manifest.json")

CONSUMERS = ("rust", "swift", "reference", "scripts")

# ---------------------------------------------------------------------------
# Declared coverage gaps
# ---------------------------------------------------------------------------
#
# The manifest has always had `known_gaps`, but that list is a SUPPRESSOR:
# each row names one mechanical check on one family/file and downgrades its
# failure to a warning. It can only ever speak about a check this script
# already runs. The gaps that matter most are the opposite shape — a family
# whose fixtures never reach the interesting branch, a field no fixture
# sets, a divergence no port-vs-port comparison can see. Nothing here could
# express those, so `known_gaps` sat at `[]` while the census documented
# eight of them, and the gate's summary line read "0 known-gap warning(s)":
# vacuously true, and read by everyone as "no gaps".
#
# `coverage_gaps` is that second list. It suppresses nothing; every row is
# PRINTED on every run, green or not, so the gate stops implying a
# completeness it never checked. Rows are validated for shape (below) and
# each must state its own evidence, because a gap you cannot state
# precisely is not ready to record.
COVERAGE_GAP_REQUIRED_KEYS = ("id", "title", "evidence", "blocks", "unblock")
COVERAGE_GAP_ALLOWED_KEYS = COVERAGE_GAP_REQUIRED_KEYS + ("census",)


def check_coverage_gaps(manifest: dict) -> tuple[list[str], list[str]]:
    """Validate the shape of `coverage_gaps`. Returns (errors, lines)."""
    errors: list[str] = []
    lines: list[str] = []
    gaps = manifest.get("coverage_gaps")
    if gaps is None:
        errors.append("coverage-gaps: manifest has no `coverage_gaps` key — "
                      "an absent list is not the same claim as an empty one; "
                      "add the key (`[]` only if you mean it)")
        return errors, lines
    if not isinstance(gaps, list):
        errors.append("coverage-gaps: `coverage_gaps` must be a list, "
                      f"got {type(gaps).__name__}")
        return errors, lines
    seen: set[str] = set()
    for i, gap in enumerate(gaps):
        where = f"coverage_gaps[{i}]"
        if not isinstance(gap, dict):
            errors.append(f"coverage-gaps: {where} must be an object")
            continue
        gid = gap.get("id")
        if isinstance(gid, str) and gid:
            where = f"coverage_gaps[{gid}]"
            if gid in seen:
                errors.append(f"coverage-gaps: duplicate id {gid!r}")
            seen.add(gid)
        for key in COVERAGE_GAP_REQUIRED_KEYS:
            val = gap.get(key)
            if not isinstance(val, str) or not val.strip():
                errors.append(f"coverage-gaps: {where} is missing a "
                              f"non-empty {key!r}")
        for key in gap:
            if key not in COVERAGE_GAP_ALLOWED_KEYS:
                errors.append(f"coverage-gaps: {where} has unknown key "
                              f"{key!r} (allowed: "
                              f"{', '.join(COVERAGE_GAP_ALLOWED_KEYS)})")
        if isinstance(gid, str) and gid:
            lines.append(f"COVERAGE GAP {gid}: {gap.get('title', '?')}")
            for key in ("evidence", "blocks", "unblock"):
                val = gap.get(key)
                if isinstance(val, str) and val.strip():
                    lines.append(f"    {key}: {val}")
    return errors, lines

# Data-reference fields the transitive pass chases, with the family the
# bare-name form resolves into ("SELF" = the referencing file's family).
# A value containing "/" is always resolved from the test_fixtures root.
DATA_REF_FIELDS = {
    "setup_svg": "test_fixtures/svg",
    "setup": "test_fixtures/expected",
    # A preservation vector's second setup door: a canonical-test-JSON
    # document, used where the SVG codec has no counterpart for the attribute
    # the vector needs on a bystander (mask, blend mode, stroke alignment,
    # gradients, stroke brush, width profile).
    "setup_test_json": "test_fixtures/expected",
    "expected_json": "SELF",
    "expected_journal_json": "SELF",
    "expected_document_json": "SELF",
    "expected_output_json": "SELF",
    # The copy-payload corpus's goldens (test_fixtures/clipboard).
    "expected_svg": "SELF",
}


# ---------------------------------------------------------------------------
# Source-file discovery per consumer (the real corpus)
# ---------------------------------------------------------------------------

def _walk_files(root: str, exts: tuple[str, ...]) -> list[str]:
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        # Never descend into build artifacts.
        dirnames[:] = [d for d in dirnames
                       if d not in (".git", "target", ".build", "node_modules",
                                    "__pycache__", ".venv")]
        for f in filenames:
            if f.endswith(exts):
                out.append(os.path.join(dirpath, f))
    return sorted(out)


def real_consumer_files(repo_root: str) -> dict[str, list[str]]:
    j = os.path.join
    return {
        "rust": (_walk_files(j(repo_root, "jas_dioxus", "src"), (".rs",))
                 + _walk_files(j(repo_root, "jas_dioxus", "tests"), (".rs",))),
        "swift": (_walk_files(j(repo_root, "JasSwift", "Sources"), (".swift",))
                  + _walk_files(j(repo_root, "JasSwift", "Tests"), (".swift",))),
        "reference": _walk_files(j(repo_root, "workspace_interpreter"), (".py",)),
        "scripts": _walk_files(j(repo_root, "scripts"), (".py", ".sh")),
    }


def _skip_literal(text: str, i: int, swift: bool) -> int:
    """If a string or char literal starts at ``text[i]``, the index just past
    it; else ``i``. Covers Rust `"..."`, `r#"..."#` and `'{'`, and Swift
    `"..."`, `#"..."#` and `\"\"\"...\"\"\"`, so a brace inside one cannot unbalance
    a body scan."""
    n = len(text)
    if swift and text.startswith('"""', i):
        j = text.find('"""', i + 3)
        return n if j < 0 else j + 3
    hashes = 0
    j = i
    if (not swift) and text[j] == "r" and (j == 0 or not (text[j - 1].isalnum() or text[j - 1] == "_")):
        j += 1
    k = j
    while k < n and text[k] == "#":
        k += 1
    hashes = k - j
    if k < n and text[k] == '"' and (hashes or j > i):
        end = '"' + "#" * hashes
        e = text.find(end, k + 1)
        return n if e < 0 else e + len(end)
    if text[i] == '"':
        k = i + 1
        while k < n and text[k] != '"':
            k += 2 if text[k] == "\\" else 1
        return min(n, k + 1)
    if (not swift) and text[i] == "'":
        m = re.match(r"'(?:\\.|[^\\'])'", text[i:])
        if m:
            return i + m.end()
    return i


def _body_end(text: str, start: int, swift: bool) -> int:
    """The index just past the brace that closes the body opened by the first
    `{` at or after ``start`` (literals skipped); len(text) if unbalanced."""
    n = len(text)
    i = start
    depth = 0
    while i < n:
        j = _skip_literal(text, i, swift)
        if j != i:
            i = j
            continue
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


_RUST_IGNORE = re.compile(r"#\[ignore\b[^\]]*\]")
_SWIFT_TEST = re.compile(r"@Test\s*\(")


def strip_unrun(text: str, path: str) -> str:
    """``text`` with comments and the bodies of tests that never run removed
    (row 299): every `//` comment, then each Rust fn carrying `#[ignore]` and
    each Swift func whose `@Test(...)` carries `.disabled`, from its attribute
    to its closing brace. Other files are returned with comments stripped."""
    markers = _comment_markers_for(path)
    text = "\n".join(_strip_line_comment(ln, markers) for ln in text.splitlines())
    swift = path.endswith(".swift")
    if not (swift or path.endswith(".rs")):
        return text
    out = []
    pos = 0
    pat = _SWIFT_TEST if swift else _RUST_IGNORE
    while True:
        m = pat.search(text, pos)
        if not m:
            break
        if swift:
            close = _paren_end(text, m.end() - 1)
            if ".disabled" not in text[m.end():close]:
                out.append(text[pos:close])
                pos = close
                continue
            fn = re.compile(r"\bfunc\b").search(text, close)
        else:
            fn = re.compile(r"\bfn\b").search(text, m.end())
        if not fn:
            break
        end = _body_end(text, fn.end(), swift)
        out.append(text[pos:m.start()])
        pos = end
    out.append(text[pos:])
    return "".join(out)


def _paren_end(text: str, open_idx: int) -> int:
    """The index just past the `)` matching the `(` at ``open_idx``."""
    depth = 0
    i = open_idx
    n = len(text)
    while i < n:
        j = _skip_literal(text, i, True)
        if j != i:
            i = j
            continue
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


# ---------------------------------------------------------------------------
# Extraction rule tables (the real corpus's registration conventions)
# ---------------------------------------------------------------------------

RUST_SRC = "jas_dioxus/src/cross_language_test.rs"
RUST_TESTS = "jas_dioxus/tests/cross_language_test.rs"
SWIFT_CLT = "JasSwift/Tests/CrossLanguageTests.swift"

# (consumer, file, marker substring, [(family, template), ...]).
# The scanner collects quoted names from the array literal opened at (or
# after) the marker line, comment-stripped, until the closing bracket.
NAME_LIST_RULES = [
    ("rust", RUST_SRC, "const GESTURE_FIXTURES",
     [("test_fixtures/gestures", "{}")]),
    ("rust", RUST_SRC, "const ACTION_FIXTURES",
     [("test_fixtures/actions", "{}")]),
    ("rust", RUST_SRC, "const KEY_FIXTURES",
     [("test_fixtures/keys", "{}")]),
    ("rust", RUST_SRC, "const SCRIPT_FIXTURES",
     [("test_fixtures/input_scripts", "{}")]),
    ("rust", RUST_SRC, "fn json_roundtrip_all_expected",
     [("test_fixtures/expected", "{}.json")]),
    ("rust", RUST_SRC, "fn binary_roundtrip_all_expected",
     [("test_fixtures/expected", "{}.json")]),
    ("rust", RUST_SRC, "fn binary_read_python_fixtures",
     [("test_fixtures/expected", "{}.bin"),
      ("test_fixtures/expected", "{}.json")]),
    ("rust", RUST_SRC, "fn svg_roundtrip_all_fixtures",
     [("test_fixtures/svg", "{}.svg")]),
    ("rust", RUST_SRC, "fn regenerate_parse_expected",
     [("test_fixtures/svg", "{}.svg"),
      ("test_fixtures/expected", "{}.json")]),
    ("swift", SWIFT_CLT, "private let gestureFixtures",
     [("test_fixtures/gestures", "{}")]),
    ("swift", SWIFT_CLT, "private let actionFixtures",
     [("test_fixtures/actions", "{}")]),
    ("swift", SWIFT_CLT, "private let keyFixtures",
     [("test_fixtures/keys", "{}")]),
    ("swift", SWIFT_CLT, "private let scriptFixtures",
     [("test_fixtures/input_scripts", "{}")]),
    ("swift", SWIFT_CLT, "func svgRoundtripAllFixtures",
     [("test_fixtures/svg", "{}.svg")]),
    ("swift", SWIFT_CLT, "func jsonRoundtripAllExpected",
     [("test_fixtures/expected", "{}.json")]),
    ("swift", SWIFT_CLT, "func binaryRoundtripAllExpected",
     [("test_fixtures/expected", "{}.json")]),
    ("swift", SWIFT_CLT, "func binaryReadPythonFixtures",
     [("test_fixtures/expected", "{}.bin"),
      ("test_fixtures/expected", "{}.json")]),
    ("scripts", "scripts/cross_language_commutativity.py", "FIXTURE_NAMES = [",
     [("test_fixtures/svg", "{}.svg"),
      ("test_fixtures/expected", "{}.json")]),
    ("scripts", "scripts/cross_language_workspace.py", "for fixture_name in [",
     [("test_fixtures/expected", "{}.json")]),
]

# (consumer, file-or-None(=any of the consumer's files), regex,
#  [(family, template), ...]). The regex's group(1) is the bare name.
HELPER_CALL_RULES = [
    ("rust", None, r'assert_svg_parse\("(\w+)"\)',
     [("test_fixtures/svg", "{}.svg"),
      ("test_fixtures/expected", "{}.json")]),
    ("rust", None, r'assert_svg_roundtrip\("(\w+)"\)',
     [("test_fixtures/svg", "{}.svg")]),
    ("rust", None, r'assert_workspace_fixture\("(\w+)"',
     [("test_fixtures/expected", "{}.json")]),
    ("swift", None, r'assertSvgParse\("(\w+)"\)',
     [("test_fixtures/svg", "{}.svg"),
      ("test_fixtures/expected", "{}.json")]),
    ("swift", None, r'assertSvgRoundtrip\("(\w+)"\)',
     [("test_fixtures/svg", "{}.svg")]),
    ("swift", None, r'assertJsonRoundtrip\("(\w+)"\)',
     [("test_fixtures/expected", "{}.json")]),
    ("swift", None, r'assertWorkspaceFixture\("(\w+)"',
     [("test_fixtures/expected", "{}.json")]),
    # Rust's two operation runners take a path-shaped argument, which (b)
    # already counts as a mention; these rules make the same calls RUNNER
    # claims for (b2), as Swift's helpers below are.
    ("rust", None, r'run_operation_fixture\("operations/([\w.]+)"\)',
     [("test_fixtures/operations", "{}")]),
    ("rust", None,
     r'run_workspace_operation_fixture\("workspace_operations/([\w.]+)"\)',
     [("test_fixtures/workspace_operations", "{}")]),
    ("swift", None, r'runOperationFixture\("([\w.]+)"\)',
     [("test_fixtures/operations", "{}")]),
    ("swift", None, r'runWorkspaceOperationFixture\("([\w.]+)"\)',
     [("test_fixtures/workspace_operations", "{}")]),
    ("scripts", "scripts/cross_language_algorithms.py",
     r'^\s*"([a-z_0-9]+)":\s*\(',
     [("test_fixtures/algorithms", "{}.json")]),
    ("scripts", "scripts/cross_language_workspace.py", r'_golden\("(\w+)"\)',
     [("test_fixtures/expected", "{}.json")]),
]

# Row 299: (consumer, regex). A READ CALL whose literal argument is
# `<family>/<file>`: group(1) is the family directory's basename, group(2)
# the file. Unlike a path-shaped mention, a read call is what a runner DOES,
# so it is a runner claim for (b2), but only in code that runs: comments and
# the bodies of tests that never run (Rust `#[ignore]`, Swift
# `@Test(.disabled ...)`, where the corpus GENERATORS live) are dropped first
# (`strip_unrun`). A fixture name held in a constant or passed through a
# helper's default argument is NOT seen, and its family stays NOT COVERED.
FAMILY_READ_RULES = [
    ("rust", r'\bread_fixture\(\s*"([a-z0-9_]+)/([\w.\-]+)"\s*\)'),
    ("swift", r'\breadFixture\(\s*"([a-z0-9_]+)/([\w.\-]+)"\s*\)'),
    ("swift", r'\.appendingPathComponent\(\s*"([a-z0-9_]+)/([\w.\-]+)"\s*\)'),
]

# (consumer, source file that must exist, family whose whole directory the
# consumer reads). A DIRECTORY-level claim: every current file is claimed;
# orphan detection inside the family is vacuous (see module docstring).
DIRECTORY_GLOB_RULES = [
    ("rust", RUST_TESTS, "test_fixtures/svg"),
    # The engine replay derives its scripts from the directory: every script,
    # including a panel script the web runner cannot list.
    ("rust", "jas_dioxus/src/ffi_script_replay.rs", "test_fixtures/input_scripts"),
    ("scripts", "scripts/check_preservation_corpus.py", "test_fixtures/preservation"),
    ("reference", "workspace_interpreter/tests/test_phase3_fixtures.py",
     "workspace/tests/phase3"),
    ("reference", "workspace_interpreter/tests/test_set_effect.py",
     "workspace/tests/set_effect"),
]

# Families whose every .json file must DECLARE ITS OWN FLOOR and meet it.
#
# WHY, measured 2026-07-28. This gate asserts a glob directory exists and is
# non-empty — but a family whose whole payload lives in ONE file is not
# emptied by deleting the file, it is emptied by rewriting the file's contents
# to `[]`. That left the preservation family with four gates over it and no
# gate that could see it: this one saw a non-empty directory, the family's own
# checker printed `OK (0 vectors, 1 file(s))`, and both ports' gates are `for`
# loops with no minimum. So each such file states `min_vectors` about itself
# and every reader — this gate, scripts/check_preservation_corpus.py, and both
# ports — refuses a file that carries fewer. Adding a family here costs one
# row; it does NOT need a fifth place to keep the count in step.
VECTOR_FLOOR_FAMILIES = ["test_fixtures/preservation"]


def check_vector_floors(repo_root: str, families: dict) -> list[str]:
    """Every .json in a VECTOR_FLOOR_FAMILIES family declares `min_vectors`
    and carries at least that many entries under `vectors`."""
    errors: list[str] = []
    for family in VECTOR_FLOOR_FAMILIES:
        names = [n for n in families.get(family, []) if n.endswith(".json")]
        if not names:
            errors.append(
                f"vector-floor: {family} holds no .json file — the family it "
                f"declares a floor for has vanished")
            continue
        for name in sorted(names):
            path = os.path.join(repo_root, family, name)
            try:
                with open(path, encoding="utf-8") as f:
                    root = json.load(f)
            except (OSError, ValueError) as e:
                errors.append(f"vector-floor: {family}/{name} unreadable: {e}")
                continue
            if not isinstance(root, dict):
                errors.append(
                    f"vector-floor: {family}/{name} top level is "
                    f"{type(root).__name__}, not an object declaring "
                    f"'min_vectors' — a bare array cannot state its own floor, "
                    f"which is how emptying it to `[]` stayed green")
                continue
            n_min = root.get("min_vectors")
            vectors = root.get("vectors")
            if not isinstance(n_min, int) or isinstance(n_min, bool) or n_min < 1:
                errors.append(
                    f"vector-floor: {family}/{name} declares min_vectors="
                    f"{n_min!r}; it must be an integer >= 1 (a floor of zero "
                    f"is not a floor)")
                continue
            if not isinstance(vectors, list):
                errors.append(
                    f"vector-floor: {family}/{name} has no 'vectors' list")
                continue
            if len(vectors) < n_min:
                errors.append(
                    f"vector-floor: {family}/{name} declares min_vectors="
                    f"{n_min} but carries {len(vectors)} — vectors were "
                    f"removed without lowering the floor the file states "
                    f"about itself")
    return errors


# ---------------------------------------------------------------------------
# Extraction machinery
# ---------------------------------------------------------------------------

def _strip_line_comment(line: str, markers: tuple[str, ...]) -> str:
    """Drop everything from the first comment marker that is outside a
    double-quoted string."""
    in_str = False
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if c == '"' and (i == 0 or line[i - 1] != "\\"):
            in_str = not in_str
        elif not in_str:
            for m in markers:
                if line.startswith(m, i):
                    return line[:i]
        i += 1
    return line


_COMMENT_MARKERS = {
    ".rs": ("//",),
    ".swift": ("//",),
    ".py": ("#",),
    ".sh": ("#",),
}


def _comment_markers_for(path: str) -> tuple[str, ...]:
    for ext, markers in _COMMENT_MARKERS.items():
        if path.endswith(ext):
            return markers
    return ()


_NAME_RE = re.compile(r'"([A-Za-z0-9][A-Za-z0-9_.\-]*)"')


def extract_name_list(path: str, marker: str) -> list[str]:
    """Collect the quoted simple names of the array literal opened at (or
    after) the line containing ``marker``. Comment text is stripped first,
    so bracket characters and names inside comments cannot corrupt the
    scan. Returns [] when the marker is absent."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    markers = _comment_markers_for(path)
    names: list[str] = []
    state = "seek-marker"  # -> "seek-open" -> "collect"
    for raw in lines:
        line = _strip_line_comment(raw, markers)
        if state == "seek-marker":
            if marker in line:
                # The array may open on the marker line itself; the LAST
                # '[' wins (skips type annotations like `&[&str]`).
                idx = line.rfind("[")
                if idx >= 0:
                    tail = line[idx + 1:]
                    names.extend(_NAME_RE.findall(tail))
                    if "]" in tail:
                        return names
                    state = "collect"
                else:
                    state = "seek-open"
        elif state == "seek-open":
            idx = line.find("[")
            if idx >= 0:
                tail = line[idx + 1:]
                names.extend(_NAME_RE.findall(tail))
                if "]" in tail:
                    return names
                state = "collect"
        elif state == "collect":
            close = line.find("]")
            segment = line if close < 0 else line[:close]
            names.extend(_NAME_RE.findall(segment))
            if close >= 0:
                return names
    return names


def _read(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def path_shaped_claims(text: str, family_dirs: list[str]) -> set[tuple[str, str]]:
    """Full ``family/name.ext`` references for the test_fixtures families
    plus ``workspace/tests/<entry>`` references."""
    claims: set[tuple[str, str]] = set()
    if family_dirs:
        alt = "|".join(re.escape(d) for d in family_dirs)
        pat = re.compile(
            r'(?<![\w/])(' + alt + r')/'
            r'([A-Za-z0-9][A-Za-z0-9_\-.]*\.(?:json|svg|bin|yaml))')
        for fam, name in pat.findall(text):
            claims.add(("test_fixtures/" + fam, name))
    for m in re.finditer(r'workspace/tests/([A-Za-z0-9_.]+)', text):
        entry = m.group(1)
        if entry.endswith(".yaml"):
            claims.add(("workspace/tests/" + entry, entry))
    return claims


def python_segment_claims(text: str) -> set[tuple[str, str]]:
    """``os.path.join`` / pathlib segment chains naming fixtures."""
    claims: set[tuple[str, str]] = set()
    for pat in (
        r'"test_fixtures",\s*"([A-Za-z0-9_]+)",\s*"([A-Za-z0-9_.\-]+)"',
        r'"test_fixtures"\s*/\s*"([A-Za-z0-9_]+)"\s*/\s*"([A-Za-z0-9_.\-]+)"',
    ):
        for fam, name in re.findall(pat, text):
            claims.add(("test_fixtures/" + fam, name))
    for pat in (
        r'"workspace",\s*"tests",\s*"([A-Za-z0-9_.]+)"',
        r'"workspace"\s*/\s*"tests"\s*/\s*"([A-Za-z0-9_.]+)"',
    ):
        for entry in re.findall(pat, text):
            if entry.endswith(".yaml"):
                claims.add(("workspace/tests/" + entry, entry))
    return claims


def extract_claims(
    repo_root: str,
    consumer_files: dict[str, list[str]],
    name_list_rules: list,
    helper_rules: list,
    family_dirs: list[str],
    mentions: bool = True,
    read_rules: list | None = None,
) -> dict[str, set[tuple[str, str]]]:
    """Direct (non-transitive, non-glob) claims per consumer as a set of
    (family_key, filename) pairs.

    ``mentions=False`` keeps only the RUNNER claims: name lists and helper
    calls, the forms that are the list a runner iterates or the call that
    runs one fixture. A path-shaped literal or a Python path segment can be
    a runner's argument, a comment or another test's array, and this
    extraction cannot tell which, so check (b2) does not count it."""
    claims: dict[str, set[tuple[str, str]]] = {c: set() for c in CONSUMERS}

    for consumer, files in (consumer_files.items() if mentions else ()):
        for path in files:
            text = _read(path)
            if not text:
                continue
            claims[consumer] |= path_shaped_claims(text, family_dirs)
            if path.endswith(".py"):
                claims[consumer] |= python_segment_claims(text)

    for consumer, rel, marker, targets in name_list_rules:
        path = os.path.join(repo_root, rel)
        for name in extract_name_list(path, marker):
            for family, template in targets:
                claims[consumer].add((family, template.format(name)))

    for consumer, rel, regex, targets in helper_rules:
        paths = ([os.path.join(repo_root, rel)] if rel
                 else consumer_files.get(consumer, []))
        pat = re.compile(regex, re.MULTILINE)
        for path in paths:
            text = _read(path)
            for m in pat.finditer(text):
                for family, template in targets:
                    claims[consumer].add((family, template.format(m.group(1))))

    # Row 299: read calls in code that runs (see FAMILY_READ_RULES).
    known = set(family_dirs)
    for consumer, regex in (read_rules or ()):
        pat = re.compile(regex)
        for path in consumer_files.get(consumer, []):
            text = _read(path)
            if not text:
                continue
            for m in pat.finditer(strip_unrun(text, path)):
                if m.group(1) in known:
                    claims[consumer].add((f"test_fixtures/{m.group(1)}", m.group(2)))

    return claims


# ---------------------------------------------------------------------------
# Transitive data-reference pass
# ---------------------------------------------------------------------------

def _walk_json_refs(node, out: list[tuple[str, str]]):
    """Collect (field, value) pairs for every DATA_REF_FIELDS key anywhere
    in the JSON value."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k in DATA_REF_FIELDS and isinstance(v, str):
                out.append((k, v))
            _walk_json_refs(v, out)
    elif isinstance(node, list):
        for v in node:
            _walk_json_refs(v, out)


def transitive_close(
    repo_root: str, seed: set[tuple[str, str]]
) -> set[tuple[str, str]]:
    """Expand a claim set with the data references of every claimed .json
    fixture, to a fixpoint. Non-JSON and unparsable files are skipped."""
    closed = set(seed)
    frontier = list(seed)
    while frontier:
        family, name = frontier.pop()
        if not name.endswith(".json") or not family.startswith("test_fixtures/"):
            continue
        path = os.path.join(repo_root, family, name)
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        refs: list[tuple[str, str]] = []
        _walk_json_refs(data, refs)
        for field, value in refs:
            if "/" in value:
                fam2, _, name2 = value.rpartition("/")
                fam2 = "test_fixtures/" + fam2 if not fam2.startswith(
                    "test_fixtures/") else fam2
            else:
                target = DATA_REF_FIELDS[field]
                fam2 = family if target == "SELF" else target
                name2 = value
            claim = (fam2, name2)
            if claim not in closed:
                closed.add(claim)
                frontier.append(claim)
    return closed


# ---------------------------------------------------------------------------
# Family discovery + the checks
# ---------------------------------------------------------------------------

def discover_families(repo_root: str) -> dict[str, list[str]]:
    """On-disk corpus families -> their files. test_fixtures subdirs are
    dir families; workspace/tests yaml files are single-file families and
    its subdirs are dir families."""
    families: dict[str, list[str]] = {}
    tf = os.path.join(repo_root, "test_fixtures")
    if os.path.isdir(tf):
        for entry in sorted(os.listdir(tf)):
            full = os.path.join(tf, entry)
            if os.path.isdir(full):
                families["test_fixtures/" + entry] = sorted(
                    f for f in os.listdir(full)
                    if os.path.isfile(os.path.join(full, f)))
    wt = os.path.join(repo_root, "workspace", "tests")
    if os.path.isdir(wt):
        for entry in sorted(os.listdir(wt)):
            full = os.path.join(wt, entry)
            key = "workspace/tests/" + entry
            if os.path.isdir(full):
                families[key] = sorted(
                    f for f in os.listdir(full)
                    if os.path.isfile(os.path.join(full, f)))
            elif entry.endswith(".yaml"):
                families[key] = [entry]
    return families


def run_checks(
    repo_root: str,
    manifest: dict,
    families: dict[str, list[str]],
    direct_claims: dict[str, set[tuple[str, str]]],
    glob_rules: list,
    runner_claims: dict[str, set[tuple[str, str]]] | None = None,
    limits: list[str] | None = None,
) -> tuple[list[str], list[str]]:
    """Returns (errors, warnings). With ``runner_claims`` (from
    ``extract_claims(..., mentions=False)``) it also runs check (b2) and
    appends to ``limits`` the lines naming which symmetric families (b2)
    covers and which it does not."""
    errors: list[str] = []
    warnings: list[str] = []
    rows = manifest.get("families", {})
    known_gaps = manifest.get("known_gaps", [])
    # A suppression row is only honest while the failure it suppresses is
    # still happening. One that never fires has outlived the defect and is
    # silently narrowing the gate, so record which rows fired and error on
    # the rest — the same self-policing the `_known_gap` holdout in
    # cross_language_algorithms.py applies to a closed oracle gap.
    fired_gaps: set[int] = set()

    def gap_matches(family: str, file: str | None, check: str) -> dict | None:
        for gap in known_gaps:
            if gap.get("family") != family:
                continue
            if gap.get("check") != check:
                continue
            if gap.get("file") not in (None, file):
                continue
            fired_gaps.add(id(gap))
            return gap
        return None

    def report(family: str, file: str | None, check: str, msg: str):
        gap = gap_matches(family, file, check)
        if gap:
            warnings.append(
                f"KNOWN GAP ({check}) {msg} — {gap.get('reason', 'no reason')}")
        else:
            errors.append(f"{check}: {msg}")

    # (c) unknown family / stale manifest row.
    for family in families:
        if family not in rows:
            report(family, None, "unknown-family",
                   f"{family} exists on disk but has no manifest row")
    for family in rows:
        if family not in families:
            report(family, None, "stale-row",
                   f"manifest row {family} has no on-disk backing")

    # Glob claims: directory must exist and be non-empty (closes the
    # silent-pass hole of glob-based consumers), then every current file
    # is claimed by the glob's consumer.
    glob_claimed: dict[str, set[str]] = {}
    for consumer, src_rel, family in glob_rules:
        src = os.path.join(repo_root, src_rel)
        if not os.path.isfile(src):
            report(family, None, "glob-source-missing",
                   f"{family}: glob consumer source {src_rel} is missing")
            continue
        files = families.get(family)
        if not files:
            report(family, None, "glob-dir-empty",
                   f"{family}: directory-glob claim but the directory is "
                   f"missing or empty (glob consumers silently pass!)")
            continue
        glob_claimed.setdefault(family, set()).add(consumer)
        direct_claims.setdefault(consumer, set()).update(
            (family, f) for f in files)
        if runner_claims is not None:
            # A glob is a runner: it iterates the whole directory.
            runner_claims.setdefault(consumer, set()).update(
                (family, f) for f in files)

    # Transitive closure per consumer (port-symmetry needs per-port
    # closures), then the global union.
    closed: dict[str, set[tuple[str, str]]] = {
        c: transitive_close(repo_root, s) for c, s in direct_claims.items()
    }
    union: set[tuple[str, str]] = set()
    for s in closed.values():
        union |= s

    # (a) family missing a required consumer.
    for family, row in rows.items():
        if family not in families:
            continue
        for consumer in row.get("required_consumers", []):
            if consumer not in CONSUMERS:
                errors.append(
                    f"manifest: {family} names unknown consumer {consumer!r}")
                continue
            has = any(fam == family for fam, _ in closed.get(consumer, set()))
            if not has:
                report(family, None, "missing-consumer",
                       f"{family}: required consumer '{consumer}' claims no "
                       f"fixtures in it")

    # (b) port symmetry between the ACTIVE ports.
    for family, row in rows.items():
        if not row.get("port_symmetry") or family not in families:
            continue
        rust = {n for fam, n in closed.get("rust", set()) if fam == family}
        swift = {n for fam, n in closed.get("swift", set()) if fam == family}
        for name in sorted(rust - swift):
            report(family, name, "port-symmetry",
                   f"{family}/{name} is claimed by rust but not swift")
        for name in sorted(swift - rust):
            report(family, name, "port-symmetry",
                   f"{family}/{name} is claimed by swift but not rust")

    # (b2) RUNNER symmetry (row 295). (b) counts a mention as a claim, so a
    # fixture one port's runner skips passes (b) whenever that port names it
    # anywhere else (row 293: Swift ran 116 of 118 scripts while a second
    # test's `admitted` array named the other two). Here each port's claim
    # is what its RUNNER reaches: its name lists, helper calls and globs,
    # closed over their data references. A family in which either port has
    # no runner rule cannot be judged, and is NAMED, never passed.
    if runner_claims is not None:
        run_closed = {c: transitive_close(repo_root, s)
                      for c, s in runner_claims.items()}
        covered: list[str] = []
        uncovered: list[str] = []
        for family, row in sorted(rows.items()):
            # Row 299's ratchet: `runner_symmetry: true` declares a family
            # (b2) MUST judge, so a port losing its runner reds by name
            # instead of moving the family quietly to NOT COVERED. It needs
            # port_symmetry, which is what (b2) judges.
            if row.get("runner_symmetry") and not row.get("port_symmetry"):
                errors.append(
                    f"manifest: {family} declares runner_symmetry without "
                    f"port_symmetry, which is what (b2) judges")
                continue
            if not row.get("port_symmetry") or family not in families:
                continue
            rust = {n for fam, n in run_closed.get("rust", set())
                    if fam == family}
            swift = {n for fam, n in run_closed.get("swift", set())
                     if fam == family}
            if not rust or not swift:
                uncovered.append(family)
                if row.get("runner_symmetry"):
                    lacking = " and ".join(
                        c for c, got in (("rust", rust), ("swift", swift))
                        if not got)
                    report(family, None, "runner-uncovered",
                           f"{family}: the manifest declares it runner-judged "
                           f"(runner_symmetry), but {lacking} has no runner "
                           f"claim there (a read call, name list, helper call "
                           f"or glob)")
                continue
            covered.append(family)
            for name in sorted(rust - swift):
                report(family, name, "runner-symmetry",
                       f"{family}/{name} is run by rust's runner but not "
                       f"swift's (a mention elsewhere is not a run)")
            for name in sorted(swift - rust):
                report(family, name, "runner-symmetry",
                       f"{family}/{name} is run by swift's runner but not "
                       f"rust's (a mention elsewhere is not a run)")
        if limits is not None:
            limits.append(
                f"runner-symmetry (b2) COVERED {len(covered)}: "
                f"{', '.join(covered) or 'none'}")
            limits.append(
                f"runner-symmetry (b2) NOT COVERED {len(uncovered)} (a port "
                f"has no name-list, helper-call, read-call or glob rule "
                f"there, so only (b), which counts mentions, judges them): "
                f"{', '.join(uncovered) or 'none'}")
            limits.append(
                "runner-symmetry (b2) read calls (row 299) are credited "
                "outside comments and #[ignore] / .disabled test bodies; a "
                "fixture name held in a constant or a helper's default "
                "argument is not seen")

    # (d) orphans — skipped for glob-claimed families (vacuous by
    # construction; the manifest notes say so).
    for family, files in families.items():
        if family in glob_claimed:
            continue
        for name in files:
            if (family, name) not in union:
                report(family, name, "orphan",
                       f"{family}/{name} is claimed by no consumer "
                       f"(transitively)")

    # (e) stale suppression rows — see `fired_gaps` above.
    for gap in known_gaps:
        if id(gap) not in fired_gaps:
            errors.append(
                "stale-known-gap: known_gaps row "
                f"{gap.get('family')!r}/{gap.get('file')!r} "
                f"check={gap.get('check')!r} suppressed nothing on this run — "
                "the failure it excuses no longer happens, so delete the row "
                "rather than leave the gate quietly narrowed")

    return errors, warnings


def run_real() -> int:
    try:
        with open(MANIFEST_PATH, encoding="utf-8") as f:
            manifest = json.load(f)
    except (OSError, ValueError) as e:
        print(f"cannot load {MANIFEST_PATH}: {e}", file=sys.stderr)
        return 2

    families = discover_families(REPO_ROOT)
    family_dirs = [k.split("/", 1)[1] for k in families
                   if k.startswith("test_fixtures/")]
    consumer_files = real_consumer_files(REPO_ROOT)
    claims = extract_claims(
        REPO_ROOT, consumer_files, NAME_LIST_RULES, HELPER_CALL_RULES,
        family_dirs)
    runners = extract_claims(
        REPO_ROOT, consumer_files, NAME_LIST_RULES, HELPER_CALL_RULES,
        family_dirs, mentions=False, read_rules=FAMILY_READ_RULES)
    limits: list[str] = []
    errors, warnings = run_checks(
        REPO_ROOT, manifest, families, claims, DIRECTORY_GLOB_RULES,
        runner_claims=runners, limits=limits)
    gap_errors, gap_lines = check_coverage_gaps(manifest)
    errors = errors + gap_errors + check_vector_floors(REPO_ROOT, families)

    # Printed unconditionally, and BEFORE the verdict: these are the things
    # the gate does not check, and a green run that hid them would be the
    # blind spot this list exists to remove.
    n_gaps = len(manifest.get("coverage_gaps") or [])
    for line in gap_lines:
        print(line)
    for line in limits:
        print(line)

    for w in warnings:
        print(f"WARN: {w}")
    if errors:
        print(f"corpus-completeness gate: {len(errors)} violation(s)")
        for e in errors:
            print(f"  {e}")
        return 1
    n_files = sum(len(v) for v in families.values())
    print(f"corpus-completeness gate: OK "
          f"({len(families)} families, {n_files} files, "
          f"{len(warnings)} known-gap warning(s), "
          f"{n_gaps} declared coverage gap(s) printed above)")
    return 0


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

def _write(root: str, rel: str, content: str):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(content)


def self_test() -> int:
    """Exercises the same extraction + check machinery the real gate uses
    over a synthetic corpus, pinning the two refuter counterexamples:

      1. ``move_first_rect.json`` — a golden that exists ONLY as a data
         reference (``expected_json`` inside a claimed driver) must NOT be
         flagged orphaned (the transitive pass must find it).
      2. the ``_expected``-suffix trap — an on-disk ``foo_expected.json``
         with NO references anywhere MUST be flagged orphaned even though
         its stem contains the claimed ``foo.json``'s stem (claims are
         path-shaped, never bare stems).

    Plus: port-symmetry detection, unknown-family detection, required-
    consumer detection, name-list extraction (incl. single-line arrays and
    comment noise), and the glob-directory existence assertion."""
    failures: list[str] = []

    def check(cond: bool, label: str):
        if cond:
            print(f"  ok: {label}")
        else:
            failures.append(label)
            print(f"  FAIL: {label}")

    with tempfile.TemporaryDirectory(prefix="corpus_selftest_") as root:
        # --- synthetic corpus ---------------------------------------
        _write(root, "test_fixtures/operations/driver.json", json.dumps([{
            "name": "move_first_rect",
            "setup_svg": "two_rects.svg",
            "ops": [{"op": "select_rect"}],
            "expected_json": "move_first_rect.json",
        }]))
        _write(root, "test_fixtures/operations/move_first_rect.json",
               '{"layers": []}')
        # The trap pair: foo.json is claimed by BOTH ports; foo_expected
        # .json exists but nothing references it (not even data).
        _write(root, "test_fixtures/operations/foo.json", "[]")
        _write(root, "test_fixtures/operations/foo_expected.json",
               '{"layers": []}')
        # rust_only.json: claimed by rust alone -> port-symmetry red.
        _write(root, "test_fixtures/operations/rust_only.json", "[]")
        _write(root, "test_fixtures/svg/two_rects.svg", "<svg/>")
        # A family with no manifest row -> unknown-family red.
        _write(root, "test_fixtures/mystery/lost.json", "[]")
        # A glob-claimed workspace/tests directory.
        _write(root, "workspace/tests/phase3/case_a.yaml", "action: x\n")

        # --- synthetic consumers ------------------------------------
        _write(root, "consumers/rust.rs", "\n".join([
            '    // comment noise: paths like [0,0] and the bare stem',
            '    // "ghost.json" (no family prefix -> never a claim).',
            '    const OP_FIXTURES: &[&str] = &[',
            '        "driver.json",',
            '        // trailing comment with a bracket ] inside',
            '        "foo.json",',
            '        "rust_only.json",',
            '    ];',
        ]))
        _write(root, "consumers/swift.swift", "\n".join([
            'private let opFixtures = ["driver.json", "foo.json"]',
        ]))
        _write(root, "consumers/reference.py", "\n".join([
            'import os',
            'P = os.path.join("workspace", "tests", "phase3")',
        ]))

        families = discover_families(root)
        check(set(families) == {
            "test_fixtures/operations", "test_fixtures/svg",
            "test_fixtures/mystery", "workspace/tests/phase3",
        }, "family discovery finds dirs + workspace/tests entries")

        consumer_files = {
            "rust": [os.path.join(root, "consumers/rust.rs")],
            "swift": [os.path.join(root, "consumers/swift.swift")],
            "reference": [os.path.join(root, "consumers/reference.py")],
            "scripts": [],
        }
        name_rules = [
            ("rust", "consumers/rust.rs", "const OP_FIXTURES",
             [("test_fixtures/operations", "{}")]),
            ("swift", "consumers/swift.swift", "private let opFixtures",
             [("test_fixtures/operations", "{}")]),
        ]
        glob_rules = [
            ("reference", "consumers/reference.py", "workspace/tests/phase3"),
        ]
        family_dirs = ["operations", "svg", "mystery"]
        claims = extract_claims(
            root, consumer_files, name_rules, [], family_dirs)

        # Name-list extraction sanity (multi-line with comment noise AND
        # the single-line Swift array).
        check(("test_fixtures/operations", "driver.json") in claims["rust"]
              and ("test_fixtures/operations", "foo.json") in claims["rust"]
              and ("test_fixtures/operations", "rust_only.json") in claims["rust"],
              "rust name-list extraction (comment noise tolerated)")
        check(("test_fixtures/operations", "ghost.json") not in claims["rust"],
              "comment-only bracket noise does not corrupt the scan")
        check(claims["swift"] == {
            ("test_fixtures/operations", "driver.json"),
            ("test_fixtures/operations", "foo.json"),
        }, "swift single-line name-list extraction")

        manifest = {
            "families": {
                "test_fixtures/operations": {
                    "kind": "fixtures",
                    "required_consumers": ["rust", "swift"],
                    "port_symmetry": True,
                },
                "test_fixtures/svg": {
                    "kind": "source",
                    "required_consumers": ["rust"],
                },
                "workspace/tests/phase3": {
                    "kind": "source",
                    "required_consumers": ["reference"],
                },
                # NOTE: test_fixtures/mystery deliberately has NO row.
            },
        }
        errors, _ = run_checks(root, manifest, families, claims, glob_rules)

        def has(check_name: str, needle: str) -> bool:
            return any(e.startswith(check_name + ":") and needle in e
                       for e in errors)

        # 1. The data-reference counterexample.
        check(not has("orphan", "move_first_rect.json"),
              "move_first_rect.json is claimed transitively (expected_json)")
        check(not has("orphan", "two_rects.svg"),
              "two_rects.svg is claimed transitively (setup_svg)")
        # 2. The _expected-suffix trap.
        check(has("orphan", "foo_expected.json"),
              "_expected-suffix trap: unreferenced foo_expected.json is "
              "flagged orphaned despite the claimed foo.json stem")
        # 3. Port symmetry.
        check(has("port-symmetry", "rust_only.json"),
              "port-symmetry: rust-only fixture is flagged")
        check(not has("port-symmetry", "driver.json")
              and not has("port-symmetry", "move_first_rect.json"),
              "port-symmetry: matched fixtures (incl. transitive goldens) "
              "are clean")
        # 4. Unknown family.
        check(has("unknown-family", "test_fixtures/mystery"),
              "unknown family on disk is flagged")
        # 5. Glob family: no orphan noise, no missing-consumer noise.
        check(not has("orphan", "case_a.yaml"),
              "glob-claimed family has vacuous (skipped) orphan detection")
        check(not has("missing-consumer", "workspace/tests/phase3"),
              "glob claim satisfies the required consumer")

        # 6. Required-consumer red: drop the swift consumer entirely.
        claims_no_swift = {c: (set() if c == "swift" else set(s))
                           for c, s in claims.items()}
        errors2, _ = run_checks(
            root, manifest, families, claims_no_swift, glob_rules)
        check(any(e.startswith("missing-consumer:")
                  and "test_fixtures/operations" in e and "'swift'" in e
                  for e in errors2),
              "missing required consumer is flagged")

        # 7. Glob directory removed -> the silent-pass hole is closed.
        import shutil
        shutil.rmtree(os.path.join(root, "workspace/tests/phase3"))
        families2 = discover_families(root)
        errors3, _ = run_checks(
            root, manifest, families2, claims, glob_rules)
        check(any(e.startswith("glob-dir-empty:") for e in errors3)
              or any("directory-glob claim but the directory" in e
                     for e in errors3),
              "missing glob directory is flagged (silent-pass hole closed)")

        # 8. known_gaps downgrade a specific failure to a warning.
        manifest_gap = dict(manifest)
        manifest_gap["known_gaps"] = [{
            "family": "test_fixtures/operations",
            "file": "rust_only.json",
            "check": "port-symmetry",
            "reason": "self-test synthetic gap",
        }]
        errors4, warnings4 = run_checks(
            root, manifest, families2, claims, glob_rules)
        errors5, warnings5 = run_checks(
            root, manifest_gap, families2, claims, glob_rules)
        check(any("rust_only.json" in e for e in errors4)
              and not any("rust_only.json" in e for e in errors5)
              and any("rust_only.json" in w for w in warnings5),
              "known_gaps downgrades the named failure to a warning")

        # 9. A known_gaps row that suppresses nothing is STALE, not silent.
        # `errors4` above shows the port-symmetry failure exists only while
        # rust_only.json is unbalanced, so a row naming a DIFFERENT family
        # cannot fire.
        manifest_stale = dict(manifest)
        manifest_stale["known_gaps"] = [{
            "family": "test_fixtures/svg",
            "file": "circle.svg",
            "check": "orphan",
            "reason": "self-test synthetic row that cannot fire",
        }]
        errors6, _ = run_checks(
            root, manifest_stale, families2, claims, glob_rules)
        check(any(e.startswith("stale-known-gap:") and "circle.svg" in e
                  for e in errors6),
              "a known_gaps row that suppressed nothing is flagged stale")
        # And the row that DID fire is not called stale.
        check(not any(e.startswith("stale-known-gap:") for e in errors5),
              "a known_gaps row that fired is not flagged stale")

        # 10. coverage_gaps: shape is enforced, and every row is printed.
        errs, lines = check_coverage_gaps({"coverage_gaps": [{
            "id": "demo", "title": "t", "evidence": "e",
            "blocks": "b", "unblock": "u"}]})
        check(errs == [] and any("COVERAGE GAP demo" in l for l in lines)
              and any("evidence: e" in l for l in lines),
              "a well-formed coverage_gaps row validates and is printed")
        errs, _ = check_coverage_gaps({"coverage_gaps": [
            {"id": "no_evidence", "title": "t", "blocks": "b",
             "unblock": "u"}]})
        check(any("missing a non-empty 'evidence'" in e for e in errs),
              "a coverage_gaps row without evidence is flagged")
        errs, _ = check_coverage_gaps({"coverage_gaps": [
            {"id": "x", "title": "t", "evidence": "e", "blocks": "b",
             "unblock": "u", "notes": "typo'd key"}]})
        check(any("unknown key 'notes'" in e for e in errs),
              "an unknown coverage_gaps key is flagged (no silent typos)")
        errs, _ = check_coverage_gaps({"coverage_gaps": [
            {"id": "dup", "title": "t", "evidence": "e", "blocks": "b",
             "unblock": "u"},
            {"id": "dup", "title": "t2", "evidence": "e2", "blocks": "b2",
             "unblock": "u2"}]})
        check(any("duplicate id 'dup'" in e for e in errs),
              "a duplicate coverage_gaps id is flagged")
        errs, _ = check_coverage_gaps({})
        check(any(e.startswith("coverage-gaps: manifest has no") for e in errs),
              "an absent coverage_gaps key is flagged (not treated as empty)")
        # The real manifest must itself satisfy the shape rules.
        with open(MANIFEST_PATH, encoding="utf-8") as fh:
            real_errs, real_lines = check_coverage_gaps(json.load(fh))
        check(real_errs == [],
              f"the shipped manifest's coverage_gaps validate ({real_errs})")
        check(len(real_lines) > 0,
              "the shipped manifest declares at least one coverage gap")

        # 11. RECORDED IS NOT THE SAME AS SURFACED. Checks 10's assertions
        # all call check_coverage_gaps directly, so deleting the print loop
        # in run_real would leave them green while the gate went silent
        # again — the exact hole ("0 known-gap warning(s)", vacuously true)
        # this list exists to close, reproduced one level up. So run the
        # real gate as a subprocess and require every declared id in its
        # stdout.
        with open(MANIFEST_PATH, encoding="utf-8") as fh:
            declared_ids = [g["id"] for g in json.load(fh)["coverage_gaps"]]
        import subprocess
        # THE CHILD'S ENCODING MUST BE FORCED, NOT ONLY THE PARENT'S DECODE.
        # This is the canonical explanation for every `sys.executable` spawn in
        # scripts/; the others point here.
        #
        # `encoding="utf-8"` tells the PARENT how to decode. It says nothing
        # about how the CHILD encodes, and a Python child writing to a PIPE
        # encodes with the locale codec -- cp1252 on Windows. This gate prints
        # an em-dash, which is 0x97 in cp1252 and an invalid UTF-8 start byte.
        #
        # The failure that follows is the worst shape we have found this
        # fortnight, because it reports SUCCESS:
        #
        #   the parent's decode raises UnicodeDecodeError inside subprocess's
        #   internal reader THREAD -> the traceback goes to stderr and the
        #   thread dies -> communicate() returns None for stdout -> run()
        #   hands back CompletedProcess(returncode=0, stdout=None, stderr='')
        #
        # rc is 0. stderr is empty. stdout is None. Every later line then
        # crashes with `TypeError: argument of type 'NoneType' is not
        # iterable`, four stack frames from the cause. That is exactly how
        # main's Windows CI job went red for four consecutive runs on
        # 2026-08-05 while both seats reported green from their own machines
        # (where PYTHONIOENCODING happened to be set).
        #
        # So: force the child to emit UTF-8, and then CHECK the capture
        # happened rather than trusting a returncode that cannot see a dead
        # reader thread.
        child_env = {**os.environ, "PYTHONIOENCODING": "utf-8"}
        proc = subprocess.run(
            [sys.executable, os.path.abspath(__file__)],
            capture_output=True, text=True, encoding="utf-8", cwd=REPO_ROOT,
            env=child_env)
        check(proc.stdout is not None,
              "the child's stdout was CAPTURED at all -- None here means the "
              "reader thread died decoding it, and rc says nothing about that "
              f"(rc={proc.returncode}, stderr={(proc.stderr or '')[:200]!r})")
        unsurfaced = [i for i in declared_ids if i not in (proc.stdout or "")]
        check(proc.returncode == 0 and declared_ids and not unsurfaced,
              f"the real gate SURFACES every declared coverage gap "
              f"(rc={proc.returncode}, unsurfaced={unsurfaced})")

        # 12. THE VECTOR FLOOR. Every case below returned rc=0 from all four
        # of the preservation family's gates before 2026-07-28, which is the
        # whole reason the floor exists; none of them can be exercised by the
        # shipped corpus, so they are pinned here.
        fam = "test_fixtures/preservation"
        floor_cases = [
            ("[]", "an emptied bare array is flagged",
             "top level is list"),
            ('{"min_vectors": 12, "vectors": []}',
             "a corpus below its declared floor is flagged",
             "declares min_vectors=12 but carries 0"),
            ('{"min_vectors": 0, "vectors": []}',
             "a declared floor of zero is flagged", "is not a floor"),
            ('{"vectors": []}', "a corpus declaring no floor is flagged",
             "must be an integer >= 1"),
            ('{"min_vectors": 2, "vectors": [{"name": "a"}, {"name": "b"}]}',
             "a corpus meeting its declared floor is accepted", None),
        ]
        for body, label, needle in floor_cases:
            _write(root, f"{fam}/vectors.json", body)
            errs = check_vector_floors(root, {fam: ["vectors.json"]})
            if needle is None:
                check(errs == [], f"{label} ({errs})")
            else:
                check(any(needle in e for e in errs), label)
        # And the family vanishing entirely is flagged, not silently skipped.
        check(any("has vanished" in e
                  for e in check_vector_floors(root, {fam: []})),
              "a vector-floor family with no .json file is flagged")
        # The SHIPPED corpus satisfies its own floor through this gate too —
        # proving the red without proving the green would let the checker
        # ship a rule the real corpus violates.
        real_families = discover_families(REPO_ROOT)
        check(check_vector_floors(REPO_ROOT, real_families) == [],
              "the shipped preservation corpus meets its declared floor")

    # --- (b2) RUNNER symmetry (row 295) -------------------------------
    # Row 293's shape, rebuilt: Swift's runner list named 116 scripts while
    # Rust globbed the directory, and a SECOND Swift test named the two
    # missing scripts in an `admitted` array. Port symmetry (b) counts any
    # path-shaped mention as a claim, so it passed while Swift ran neither.
    # (b2) compares what each port's RUNNER claims (name lists, helper calls
    # and directory globs, closed over their data references), never a
    # mention, and names every symmetric family it cannot see.
    with tempfile.TemporaryDirectory(prefix="corpus_selftest_b2_") as r2:
        for n in ("a", "b"):
            _write(r2, f"test_fixtures/gestures/{n}.json", json.dumps(
                [{"name": n, "expected_json": f"{n}.expected.json"}]))
            _write(r2, f"test_fixtures/gestures/{n}.expected.json", "{}")
            _write(r2, f"test_fixtures/scripts/{n}.json", json.dumps(
                {"expected_json": f"{n}.expected.json"}))
            _write(r2, f"test_fixtures/scripts/{n}.expected.json", "{}")
        for t in ("t", "u", "v", "c", "gen"):
            _write(r2, f"test_fixtures/tables/{t}.json", "[]")
        _write(r2, "test_fixtures/notes/n.json", "[]")
        _write(r2, "test_fixtures/decl/d.json", "[]")
        _write(r2, "test_fixtures/loose/l.json", "[]")
        # Row 299: a READ CALL in a test that runs is a runner claim. Rust
        # runs t, u and v; Swift runs t (readFixture) and v
        # (appendingPathComponent), and reads u only inside a DISABLED test.
        # A read in a comment (c) and a read in an IGNORED generator (gen)
        # are not runs, even with braces in strings around them. `notes` is
        # only ever an array literal in both ports: a mention, not judged.
        _write(r2, "consumers/rust.rs", "\n".join([
            'const GESTURES: &[&str] = &["a.json", "b.json"];',
            '#[test]',
            'fn reads_tables() {',
            '    let t = read_fixture("tables/t.json");',
            '    let u = read_fixture( "tables/u.json" );',
            '    let v = read_fixture("tables/v.json");',
            '    // let c = read_fixture("tables/c.json");',
            '    let notes = ["notes/n.json"];',
            '    let d = read_fixture("decl/d.json");',
            '    let l = read_fixture("loose/l.json");',
            '}',
            '#[test]',
            '#[ignore] // a generator, run by hand',
            'fn generate_tables() {',
            '    let open = \'{\'; let raw = r#"{"x": "}"}"#;',
            '    let g = read_fixture("tables/gen.json");',
            '    let c = read_fixture("tables/c.json");',
            '}',
        ]))
        _write(r2, "consumers/glob.rs", "// reads test_fixtures/scripts\n")
        _write(r2, "consumers/swift.swift", "\n".join([
            'private let gestures = ["a.json"]',
            '// a second test names the one the runner skips:',
            'let admitted = ["gestures/b.json"]',
            'private let scripts = ["a.json"]',
            'let other = ["scripts/b.json"]',
            '@Test func readsTables() {',
            '    let t = readFixture("tables/t.json")',
            '    let v = root.appendingPathComponent("tables/v.json")',
            '    let notes = ["notes/n.json"]',
            '    let decl = ["decl/d.json"]',
            '}',
            '@Test(.disabled("a generator")) func generateTables() {',
            '    let s = "}"; let m = """',
            '    { "y": "}" }',
            '    """',
            '    let u = readFixture("tables/u.json")',
            '    let g = readFixture("tables/gen.json")',
            '}',
        ]))
        fams2 = discover_families(r2)
        files2 = {
            "rust": [os.path.join(r2, "consumers/rust.rs")],
            "swift": [os.path.join(r2, "consumers/swift.swift")],
            "reference": [], "scripts": [],
        }
        rules2 = [
            ("rust", "consumers/rust.rs", "const GESTURES",
             [("test_fixtures/gestures", "{}")]),
            ("swift", "consumers/swift.swift", "private let gestures",
             [("test_fixtures/gestures", "{}")]),
            ("swift", "consumers/swift.swift", "private let scripts",
             [("test_fixtures/scripts", "{}")]),
        ]
        globs2 = [("rust", "consumers/glob.rs", "test_fixtures/scripts")]
        sym = {"kind": "fixtures", "required_consumers": ["rust", "swift"],
               "port_symmetry": True}
        # Row 299's ratchet: `decl` is DECLARED runner-judged, and Swift only
        # names its fixture in an array, so (b2) cannot judge it: a red, by
        # name. `loose` declares runner_symmetry without port_symmetry.
        manifest2 = {"families": {"test_fixtures/gestures": dict(sym),
                                  "test_fixtures/scripts": dict(sym),
                                  "test_fixtures/tables": dict(sym, runner_symmetry=True),
                                  "test_fixtures/notes": dict(sym),
                                  "test_fixtures/decl": dict(sym, runner_symmetry=True),
                                  "test_fixtures/loose": {"kind": "fixtures",
                                                          "required_consumers": ["rust"],
                                                          "runner_symmetry": True}}}
        dirs2 = ["gestures", "scripts", "tables", "notes", "decl", "loose"]
        mentions2 = extract_claims(r2, files2, rules2, [], dirs2,
                                   read_rules=FAMILY_READ_RULES)
        runners2 = extract_claims(r2, files2, rules2, [], dirs2,
                                  mentions=False, read_rules=FAMILY_READ_RULES)
        check(("test_fixtures/gestures", "b.json") in mentions2["swift"]
              and ("test_fixtures/gestures", "b.json") not in runners2["swift"],
              "b2: a mention credits swift with b.json; its runner does not")
        rt = {n for f, n in runners2["rust"] if f == "test_fixtures/tables"}
        st = {n for f, n in runners2["swift"] if f == "test_fixtures/tables"}
        check(rt == {"t.json", "u.json", "v.json"},
              f"b2 (row 299): rust's read calls in a running test are runs, "
              f"and neither a comment nor an #[ignore] generator is ({rt})")
        check(st == {"t.json", "v.json"},
              f"b2 (row 299): swift's readFixture and appendingPathComponent "
              f"reads run, a .disabled test's do not ({st})")
        check(not any(f == "test_fixtures/notes"
                      for c in ("rust", "swift") for f, _ in runners2[c]),
              "b2 (row 299): an array literal naming a fixture is still a "
              "mention, never a run")
        limits2: list[str] = []
        errs2, _ = run_checks(r2, manifest2, fams2, mentions2, globs2,
                              runner_claims=runners2, limits=limits2)

        def has2(check_name: str, needle: str) -> bool:
            return any(e.startswith(check_name + ":") and needle in e
                       for e in errs2)

        check(not has2("port-symmetry", "gestures/b.json"),
              "b2: the old check (b) is satisfied by the mention (the hole)")
        check(has2("runner-symmetry", "test_fixtures/gestures/b.json"),
              "b2: rust's runner runs gestures/b.json and swift's does not")
        check(not has2("runner-symmetry", "gestures/a.json")
              and not has2("runner-symmetry", "a.expected.json"),
              "b2: a fixture both runners run, and its golden, are clean")
        check(has2("runner-symmetry", "test_fixtures/scripts/b.json"),
              "b2: a glob runs scripts/b.json and the list skips it")
        check(not has2("runner-symmetry", "scripts/a.json"),
              "b2: glob against list agrees on the script the list names")
        check(has2("runner-symmetry", "test_fixtures/tables/u.json")
              and not has2("runner-symmetry", "tables/t.json")
              and not has2("runner-symmetry", "tables/v.json")
              and not has2("runner-symmetry", "tables/c.json")
              and not has2("runner-symmetry", "tables/gen.json"),
              f"b2 (row 299): tables is judged by its read calls, and only "
              f"u.json (read in a disabled Swift test) is asymmetric ({errs2})")
        check(not has2("runner-symmetry", "notes")
              and not has2("runner-uncovered", "notes"),
              "b2: a family no runner rule covers is not judged by (b2)")
        check(has2("runner-uncovered", "test_fixtures/decl")
              and any("swift" in e for e in errs2 if e.startswith("runner-uncovered:")),
              f"b2 (row 299): a family the manifest declares runner-judged "
              f"that a port has no runner for reds BY NAME, naming the port ({errs2})")
        check(not has2("runner-uncovered", "tables"),
              "b2 (row 299): a declared family both runners reach is not "
              "runner-uncovered")
        check(any("loose" in e and "port_symmetry" in e for e in errs2),
              f"b2 (row 299): runner_symmetry without port_symmetry is "
              f"refused, never silently ignored ({errs2})")
        check(any("test_fixtures/notes" in ln and "NOT COVERED" in ln
                  for ln in limits2),
              f"b2: the uncovered symmetric family is NAMED ({limits2})")
        check(any("read calls" in ln and "constant" in ln for ln in limits2),
              f"b2 (row 299): what a read-call rule cannot see is printed "
              f"beside the verdict ({limits2})")
        check(any("COVERED" in ln and "test_fixtures/gestures" in ln
                  and "NOT COVERED" not in ln for ln in limits2),
              "b2: the covered families are named beside the verdict")
        # Matched runners: swift's list grows to the directory -> clean.
        _write(r2, "consumers/swift.swift", "\n".join([
            'private let gestures = ["a.json", "b.json"]',
            'private let scripts = ["a.json", "b.json"]',
            '@Test func readsTables() {',
            '    let t = readFixture("tables/t.json")',
            '    let u = readFixture("tables/u.json")',
            '    let v = root.appendingPathComponent("tables/v.json")',
            '}',
        ]))
        runners3 = extract_claims(r2, files2, rules2, [], dirs2,
                                  mentions=False, read_rules=FAMILY_READ_RULES)
        mentions3 = extract_claims(r2, files2, rules2, [], dirs2,
                                   read_rules=FAMILY_READ_RULES)
        errs3, _ = run_checks(r2, manifest2, fams2, mentions3, globs2,
                              runner_claims=runners3, limits=[])
        check(not any(e.startswith("runner-symmetry:") for e in errs3),
              f"b2: matched runners are clean ({errs3})")

    if failures:
        print(f"self-test: {len(failures)} FAILURE(S)")
        return 1
    print("self-test: OK")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    if sys.argv[1:]:
        print(__doc__)
        return 2
    return run_real()


if __name__ == "__main__":
    sys.exit(main())
