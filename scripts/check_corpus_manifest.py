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

# Data-reference fields the transitive pass chases, with the family the
# bare-name form resolves into ("SELF" = the referencing file's family).
# A value containing "/" is always resolved from the test_fixtures root.
DATA_REF_FIELDS = {
    "setup_svg": "test_fixtures/svg",
    "setup": "test_fixtures/expected",
    "expected_json": "SELF",
    "expected_journal_json": "SELF",
    "expected_document_json": "SELF",
    "expected_output_json": "SELF",
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

# (consumer, source file that must exist, family whose whole directory the
# consumer reads). A DIRECTORY-level claim: every current file is claimed;
# orphan detection inside the family is vacuous (see module docstring).
DIRECTORY_GLOB_RULES = [
    ("rust", RUST_TESTS, "test_fixtures/svg"),
    ("reference", "workspace_interpreter/tests/test_phase3_fixtures.py",
     "workspace/tests/phase3"),
    ("reference", "workspace_interpreter/tests/test_set_effect.py",
     "workspace/tests/set_effect"),
]


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
) -> dict[str, set[tuple[str, str]]]:
    """Direct (non-transitive, non-glob) claims per consumer as a set of
    (family_key, filename) pairs."""
    claims: dict[str, set[tuple[str, str]]] = {c: set() for c in CONSUMERS}

    for consumer, files in consumer_files.items():
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
) -> tuple[list[str], list[str]]:
    """Returns (errors, warnings)."""
    errors: list[str] = []
    warnings: list[str] = []
    rows = manifest.get("families", {})
    known_gaps = manifest.get("known_gaps", [])

    def gap_matches(family: str, file: str | None, check: str) -> dict | None:
        for gap in known_gaps:
            if gap.get("family") != family:
                continue
            if gap.get("check") != check:
                continue
            if gap.get("file") not in (None, file):
                continue
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
    errors, warnings = run_checks(
        REPO_ROOT, manifest, families, claims, DIRECTORY_GLOB_RULES)

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
          f"{len(warnings)} known-gap warning(s))")
    return 0


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

def _write(root: str, rel: str, content: str):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
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
