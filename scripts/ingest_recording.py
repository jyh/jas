#!/usr/bin/env python3
"""Ingest a jas recorder download into the conformance corpus (Arc 1 S2).

Takes a ``*.recording.json`` produced by the wasm app's recorder
(``window.jas_record_stop`` / the ``?record=`` URL param — see
RECORDER.md), validates its shape and fidelity stamps, materializes the
embedded setup SVGs and the corpus-shaped fixture file under
``test_fixtures/``, mints the ``*_expected.json`` goldens by replaying
through the Rust ``corpus_replay`` bin (the SAME shared replay path the
corpus runners and the record-stop fidelity check use), cross-checks the
minted goldens against the recording's live-document oracles, and
finally prints — or with ``--register`` patches — the registration
lines for BOTH active ports' fixture lists (the corpus-manifest gate
polices that symmetry either way).

Refusals (the writer's laws):
  * UNFAITHFUL cases (record-stop replay mismatch) are refused unless
    ``--allow-unfaithful``.
  * Cases with precondition violations (non-empty starting selection,
    lossy SVG round-trip, opaque journal transactions) are refused
    unless ``--allow-unfaithful``.
  * EXISTING corpus files are never overwritten: an existing fixture,
    golden, or setup SVG with different bytes is an error (an identical
    setup SVG is deduplicated by content and reused).

Usage:
    python scripts/ingest_recording.py <recording.json> [--register]
        [--allow-unfaithful] [--fixtures-root DIR]
    python scripts/ingest_recording.py --self-test

Exit status 0 = ingested, 1 = refused/failed, 2 = usage error.
Requires only the Python standard library (plus cargo for minting).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUST_CRATE = os.path.join(REPO_ROOT, "jas_dioxus")
RUST_LIST_FILE = os.path.join(RUST_CRATE, "src", "cross_language_test.rs")
SWIFT_LIST_FILE = os.path.join(REPO_ROOT, "JasSwift", "Tests", "CrossLanguageTests.swift")

RECORDER_VERSION = "jas-recorder-v1"

# Per-seam corpus layout: fixture directory, the registration list
# markers in each port's source, and which corpus-case keys the final
# fixture carries (in emission order).
SEAMS = {
    "gesture": {
        "dir": "gestures",
        "rust_marker": "const GESTURE_FIXTURES: &[&str] = &[",
        "swift_marker": "private let gestureFixtures = [",
        "case_keys": ["name", "setup_svg", "tool", "app_state", "events", "expected_json"],
    },
    "action": {
        "dir": "actions",
        "rust_marker": "const ACTION_FIXTURES: &[&str] = &[",
        "swift_marker": "private let actionFixtures = [",
        "case_keys": ["name", "setup_svg", "actions", "expected_json"],
    },
    "key": {
        "dir": "keys",
        "rust_marker": "const KEY_FIXTURES: &[&str] = &[",
        "swift_marker": "private let keyFixtures = [",
        "case_keys": ["name", "cases", "expected_json"],
    },
    "journal": {
        "dir": "operations",
        # The operations corpus registers per-test helper calls, not a
        # name list; registration is print-only for this seam.
        "rust_marker": None,
        "swift_marker": None,
        "case_keys": ["name", "setup_svg", "txns", "expected_json"],
    },
}


def fail(msg: str) -> None:
    print(f"ingest: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate(env: dict, allow_unfaithful: bool) -> str:
    if env.get("recorder") != RECORDER_VERSION:
        fail(f"not a {RECORDER_VERSION} recording (recorder={env.get('recorder')!r})")
    seam = env.get("seam")
    if seam not in SEAMS:
        fail(f"unknown seam {seam!r}")
    family = env.get("family", "")
    if not re.fullmatch(r"[a-z0-9_]+", family or ""):
        fail(f"family {family!r} must be [a-z0-9_]+")
    cases = env.get("cases")
    if not isinstance(cases, list) or not cases:
        fail("recording has no cases")
    for c in cases:
        name = c.get("name", "<unnamed>")
        verdict = c.get("fidelity")
        if verdict not in ("FAITHFUL", "PURE"):
            msg = f"case {name}: fidelity={verdict!r} (record-stop replay did not reproduce the live document)"
            if allow_unfaithful:
                print(f"ingest: WARNING: {msg} — ingesting anyway (--allow-unfaithful)")
            else:
                fail(msg + "; re-record, or pass --allow-unfaithful to keep it")
        violations = c.get("precondition_violations", [])
        if violations:
            msg = f"case {name}: precondition violations {violations}"
            if allow_unfaithful:
                print(f"ingest: WARNING: {msg} — ingesting anyway (--allow-unfaithful)")
            else:
                fail(msg + "; re-record from a clean setup, or pass --allow-unfaithful")
    return seam


# ---------------------------------------------------------------------------
# Materialization
# ---------------------------------------------------------------------------

def write_new(path: str, content: str) -> None:
    """Write ``content`` to ``path``; an existing file with different
    bytes is an error (corpus bytes are never modified)."""
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            if f.read() == content:
                print(f"ingest: unchanged (identical bytes): {os.path.relpath(path, REPO_ROOT)}")
                return
        fail(f"{os.path.relpath(path, REPO_ROOT)} exists with different bytes; "
             "pick a new family name (existing corpus bytes are never modified)")
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"ingest: wrote {os.path.relpath(path, REPO_ROOT)}")


def dedupe_setup_svg(svg_dir: str, wanted_name: str, content: str) -> str:
    """Reuse an existing byte-identical setup SVG if one exists;
    otherwise write ``wanted_name``. Returns the fixture-relative name."""
    for f in sorted(os.listdir(svg_dir)) if os.path.isdir(svg_dir) else []:
        if not f.endswith(".svg"):
            continue
        p = os.path.join(svg_dir, f)
        try:
            with open(p, encoding="utf-8") as fh:
                if fh.read() == content:
                    print(f"ingest: setup dedup -> reusing existing {f}")
                    return f
        except OSError:
            continue
    write_new(os.path.join(svg_dir, wanted_name), content)
    return wanted_name


def corpus_case(seam: str, rec_case: dict, setup_name: str | None) -> dict:
    """Project a recording case down to the corpus fixture shape."""
    out = {}
    for k in SEAMS[seam]["case_keys"]:
        if k == "setup_svg":
            out[k] = setup_name
        elif k == "app_state":
            v = rec_case.get("app_state") or {}
            if v:  # omitted when empty, matching hand-authored fixtures
                out[k] = v
        else:
            out[k] = rec_case[k]
    return out


def mint_goldens(seam: str, fixture_path: str) -> dict:
    """Replay the on-disk fixture through the Rust shared replay path
    and return {case_name: golden_string}."""
    res = subprocess.run(
        ["cargo", "run", "--quiet", "--bin", "corpus_replay", "--", seam, fixture_path],
        cwd=RUST_CRATE, capture_output=True, text=True)
    if res.returncode != 0:
        fail(f"corpus_replay failed:\n{res.stderr}")
    try:
        return json.loads(res.stdout)
    except json.JSONDecodeError as e:
        fail(f"corpus_replay produced invalid JSON: {e}\n{res.stdout[:500]}")
        raise  # unreachable


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

def registration_entry(port: str, fixture_file: str) -> str:
    indent = "        " if port == "rust" else "    "
    return f'{indent}"{fixture_file}",'


def patch_list(source_path: str, marker: str, entry_line: str, close_token: str) -> bool:
    """Insert ``entry_line`` before the closing bracket of the list that
    starts at ``marker``. Handles both the multi-line lists (closing
    line is exactly ``close_token``) and the single-line key lists.
    Returns False if the entry is already present."""
    with open(source_path, encoding="utf-8") as f:
        text = f.read()
    if marker not in text:
        fail(f"marker not found in {source_path}: {marker!r}")
    entry_name = entry_line.strip()
    start = text.index(marker)
    head, tail = text[:start], text[start:]
    marker_line_end = tail.index("\n") if "\n" in tail else len(tail)
    marker_line = tail[:marker_line_end]
    if close_token.strip() in marker_line[len(marker):]:
        # Single-line list: ... = &["a.json"]; -> insert before close.
        if entry_name.rstrip(",") in marker_line:
            return False
        close_idx = marker_line.rindex(close_token.strip())
        new_line = (marker_line[:close_idx].rstrip()
                    + ", " + entry_name.rstrip(",")
                    + marker_line[close_idx:])
        text = head + new_line + tail[marker_line_end:]
    else:
        # Multi-line list: find the exact closing line after the marker.
        close_at = tail.find("\n" + close_token + "\n")
        if close_at < 0:
            fail(f"closing line {close_token!r} not found after marker in {source_path}")
        if entry_name in tail[:close_at]:
            return False
        insert_at = start + close_at + 1
        text = text[:insert_at] + entry_line + "\n" + text[insert_at:]
    with open(source_path, "w", encoding="utf-8") as f:
        f.write(text)
    return True


def register(seam: str, fixture_file: str, do_patch: bool,
             rust_file: str = RUST_LIST_FILE, swift_file: str = SWIFT_LIST_FILE) -> None:
    cfg = SEAMS[seam]
    if cfg["rust_marker"] is None:
        print("ingest: the operations corpus registers per-test helper calls; add in BOTH ports:")
        print(f'  rust  ({os.path.relpath(rust_file, REPO_ROOT)}): a #[test] calling '
              f'run_operation_fixture("operations/{fixture_file}");')
        print(f'  swift ({os.path.relpath(swift_file, REPO_ROOT)}): a @Test calling '
              f'runOperationFixture("{fixture_file}")')
        return
    rust_entry = registration_entry("rust", fixture_file)
    swift_entry = registration_entry("swift", fixture_file)
    if do_patch:
        r = patch_list(rust_file, cfg["rust_marker"], rust_entry, "    ];")
        s = patch_list(swift_file, cfg["swift_marker"], swift_entry, "]")
        print(f"ingest: registered in rust list: {'added' if r else 'already present'}")
        print(f"ingest: registered in swift list: {'added' if s else 'already present'}")
    else:
        print("ingest: add these registration lines (BOTH ports — the corpus-manifest gate "
              "polices symmetry):")
        print(f"  {os.path.relpath(rust_file, REPO_ROOT)}  ->  {cfg['rust_marker']} ...")
        print(f"    {rust_entry}")
        print(f"  {os.path.relpath(swift_file, REPO_ROOT)}  ->  {cfg['swift_marker']} ...")
        print(f"    {swift_entry}")


# ---------------------------------------------------------------------------
# Ingest
# ---------------------------------------------------------------------------

def ingest(recording_path: str, fixtures_root: str, do_register: bool,
           allow_unfaithful: bool,
           rust_file: str = RUST_LIST_FILE, swift_file: str = SWIFT_LIST_FILE) -> str:
    with open(recording_path, encoding="utf-8") as f:
        env = json.load(f)
    seam = validate(env, allow_unfaithful)
    family = env["family"]
    cfg = SEAMS[seam]
    family_dir = os.path.join(fixtures_root, cfg["dir"])
    svg_dir = os.path.join(fixtures_root, "svg")
    os.makedirs(family_dir, exist_ok=True)
    os.makedirs(svg_dir, exist_ok=True)

    # 1. Materialize setup SVGs (deduplicated by content) + fixture file.
    cases = []
    for c in env["cases"]:
        setup_name = None
        if "setup_svg" in cfg["case_keys"]:
            setup_name = dedupe_setup_svg(
                svg_dir, c["setup_svg_name"], c["setup_svg"])
        cases.append(corpus_case(seam, c, setup_name))
    fixture_file = f"{family}.json"
    fixture_path = os.path.join(family_dir, fixture_file)
    write_new(fixture_path, json.dumps(cases, indent=2) + "\n")

    # 2. Mint goldens through the shared Rust replay path.
    goldens = mint_goldens(seam, fixture_path)

    # 3. Cross-check minted goldens against the recording's live-document
    #    oracles (the ingest-time fidelity pin; the key seam is pure).
    for c in env["cases"]:
        name = c["name"]
        if name not in goldens:
            fail(f"corpus_replay produced no golden for case {name}")
        live = c.get("live_doc_json")
        if live is not None and seam != "key" and goldens[name] != live:
            msg = (f"case {name}: minted golden differs from the recording's live oracle "
                   "(replay drift between record-stop and ingest)")
            if allow_unfaithful:
                print(f"ingest: WARNING: {msg}")
            else:
                fail(msg)

    # 4. Write goldens.
    for c in env["cases"]:
        write_new(os.path.join(family_dir, c["expected_json"]), goldens[c["name"]])

    # 5. Registration (print, or patch with --register).
    register(seam, fixture_file, do_register, rust_file, swift_file)
    print(f"ingest: done — family '{family}' ({len(cases)} case(s)) in "
          f"{os.path.relpath(family_dir, REPO_ROOT)}")
    return fixture_path


# ---------------------------------------------------------------------------
# Self-test: a synthetic recording through the full pipeline (temp tree)
# ---------------------------------------------------------------------------

def self_test() -> None:
    real_svg_dir = os.path.join(REPO_ROOT, "test_fixtures", "svg")
    # Any corpus setup SVG works as synthetic setup content (chosen at
    # runtime; no fixture is named in this source).
    setup_src = sorted(f for f in os.listdir(real_svg_dir) if f.endswith(".svg"))[0]
    with open(os.path.join(real_svg_dir, setup_src), encoding="utf-8") as f:
        setup_content = f.read()

    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, "test_fixtures")
        os.makedirs(os.path.join(root, "svg"))
        os.makedirs(os.path.join(root, "gestures"))

        # Oracle: pre-replay the synthetic case via corpus_replay so the
        # envelope carries the live_doc_json a faithful recording would.
        case = {
            "name": "ingest_selftest_1",
            "setup_svg": "ingest_selftest_1_setup.svg",
            "tool": "rect",
            "events": [
                {"kind": "press", "x": 10, "y": 20},
                {"kind": "move", "x": 110, "y": 70, "dragging": True},
                {"kind": "release", "x": 110, "y": 70},
            ],
            "expected_json": "ingest_selftest_1_expected.json",
        }
        with open(os.path.join(root, "svg", case["setup_svg"]), "w", encoding="utf-8") as f:
            f.write(setup_content)
        pre_path = os.path.join(root, "gestures", "pre.json")
        with open(pre_path, "w", encoding="utf-8") as f:
            json.dump([case], f)
        oracle = mint_goldens("gesture", pre_path)[case["name"]]
        os.remove(pre_path)
        os.remove(os.path.join(root, "svg", case["setup_svg"]))

        env = {
            "recorder": RECORDER_VERSION,
            "seam": "gesture",
            "family": "ingest_selftest",
            "fidelity": "FAITHFUL",
            "cases": [{
                "name": case["name"],
                "tool": case["tool"],
                "setup_svg_name": case["setup_svg"],
                "setup_svg": setup_content,
                "precondition_violations": [],
                "app_state": {},
                "events": case["events"],
                "expected_json": case["expected_json"],
                "live_doc_json": oracle,
                "fidelity": "FAITHFUL",
            }],
        }
        rec_path = os.path.join(tmp, "ingest_selftest.recording.json")
        with open(rec_path, "w", encoding="utf-8") as f:
            json.dump(env, f)

        # Registration is patched against COPIES of both ports' lists.
        rust_copy = os.path.join(tmp, "cross_language_test.rs")
        swift_copy = os.path.join(tmp, "CrossLanguageTests.swift")
        shutil.copy(RUST_LIST_FILE, rust_copy)
        shutil.copy(SWIFT_LIST_FILE, swift_copy)

        fixture_path = ingest(rec_path, root, do_register=True,
                              allow_unfaithful=False,
                              rust_file=rust_copy, swift_file=swift_copy)

        # Assertions.
        with open(fixture_path, encoding="utf-8") as f:
            written = json.load(f)
        assert written == [case], f"fixture shape mismatch: {written}"
        golden_path = os.path.join(root, "gestures", case["expected_json"])
        with open(golden_path, encoding="utf-8") as f:
            assert f.read() == oracle, "minted golden differs from oracle"
        svg_path = os.path.join(root, "svg", case["setup_svg"])
        assert os.path.exists(svg_path), "setup svg not materialized"
        for p, entry in ((rust_copy, '"ingest_selftest.json",'),
                         (swift_copy, '"ingest_selftest.json",')):
            with open(p, encoding="utf-8") as f:
                assert entry in f.read(), f"registration missing in {p}"

        # Re-ingest is idempotent (identical bytes accepted, no dupes).
        ingest(rec_path, root, do_register=True, allow_unfaithful=False,
               rust_file=rust_copy, swift_file=swift_copy)
        with open(rust_copy, encoding="utf-8") as f:
            assert f.read().count('"ingest_selftest.json",') == 1, "duplicate rust registration"

        # An UNFAITHFUL case is refused without --allow-unfaithful.
        env["cases"][0]["fidelity"] = "UNFAITHFUL"
        bad_path = os.path.join(tmp, "bad.recording.json")
        with open(bad_path, "w", encoding="utf-8") as f:
            json.dump(env, f)
        res = subprocess.run(
            [sys.executable, os.path.abspath(__file__), bad_path,
             "--fixtures-root", root],
            capture_output=True, text=True)
        assert res.returncode == 1 and "fidelity" in res.stderr, (
            f"unfaithful recording was not refused: rc={res.returncode} {res.stderr}")

    print("ingest: SELF-TEST PASS")


# ---------------------------------------------------------------------------

def main() -> None:
    args = sys.argv[1:]
    if args == ["--self-test"]:
        self_test()
        return
    if not args or args[0].startswith("--"):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    recording = args[0]
    do_register = "--register" in args
    allow_unfaithful = "--allow-unfaithful" in args
    fixtures_root = os.path.join(REPO_ROOT, "test_fixtures")
    if "--fixtures-root" in args:
        fixtures_root = args[args.index("--fixtures-root") + 1]
    ingest(recording, fixtures_root, do_register, allow_unfaithful)


if __name__ == "__main__":
    main()
