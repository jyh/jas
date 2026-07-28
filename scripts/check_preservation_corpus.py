#!/usr/bin/env python3
"""Shape + anti-vacuity validator for the PRESERVATION corpus.

`test_fixtures/preservation/*.json` is the corpus family that makes the
preservation law (transcripts/EDIT_SEMANTICS_FREEZE.md) machine-visible: each
vector applies an edit through the shared `op_apply` vocabulary and both active
ports assert the same DOCUMENT-LEVEL invariants over the canonical test JSON
before and after (§4.1: "one predicate both ports can fail identically").

This script gates the DATA half. It cannot run an edit, so it never claims a
vector is meaningful at runtime; what it does enforce is the set of structural
properties that made two earlier families vacuous — registered, green, and
gating nothing:

  V1  every id a vector names (subject / consumed) is actually present in the
      setup SVG it names, so a typo'd id cannot silently reduce a vector to
      "the document was edited and nothing was checked";
  V2  the setup SVG carries at least one CONTAINER (a `<g>`) with an id that
      the vector names neither as subject nor as consumed — without a
      container bystander, the T4 clause the family exists to watch has
      nothing to watch;
  V3  the vector's op list contains at least one op outside the
      selection-only vocabulary, so it edits the document at all -- or, for a
      GESTURE-driven vector, it names a tool and dispatches a press and a
      release, which is the least that can commit anything;
  V4  a one-to-one vector with a subject declares a non-empty `speaks_to`,
      because "only the spoken-to keys may differ" is vacuously true when the
      subject set is empty;
  V5  every `expected_violations` row names a KNOWN invariant and states both
      the site (`row`) and prose (`note`), so a pinned violation can never be
      an unexplained suppression;
  V6  every `must_change` key is also in `speaks_to` (claiming the edit
      rewrites a key the vector forbids it to touch is a contradiction), and
      the vector has a subject for the claim to range over.

A vector drives its edit through ONE of two production paths, chosen by its
shape: `events` replays pointer input through the real tool, `txns`/`ops`
dispatches through the shared op vocabulary. The gesture arm exists because
some ratified edits have NO op verb at all -- the blob brush's commit arms are
a YAML effect -- so an op-only family is structurally blind to them.

`must_change` (optional) turns `speaks_to` from a permission into a claim.
`subject_fields_only` only forbids differences OUTSIDE `speaks_to`, so listing
a key there makes the gate blind to it: an implementation that stopped writing
it would still be green. Naming it in `must_change` asserts the edit really
does rewrite it, which is what lets a vector SEPARATE a behaviour rather than
merely tolerate it.

The runtime half — that each declared violation still reproduces, and that
each non-declared invariant holds — lives in the two ports' gates
(`preservation_invariants` in jas_dioxus/src/cross_language_test.rs and
JasSwift/Tests/CrossLanguageTests.swift). A declared violation is asserted to
FAIL there, so fixing a site turns the gate red until the declaration is
removed.

THE FLOOR (added 2026-07-28, after an audit measured the hole). Every check
above is a check ON a vector, so a corpus with NO vectors satisfied all of
them vacuously: this gate printed `OK (0 vectors, 1 file(s))` and returned 0
for a file containing `[]`, and so did the other three (both ports' loops are
bare `for`s, and check_corpus_manifest.py never fires because the DIRECTORY is
still non-empty). Deleting the file was caught; EMPTYING it was not. Each
corpus file therefore declares `min_vectors` in its own header and every one
of the four gates refuses a file carrying fewer — the count is a fact the
corpus states about itself rather than a magic number in four places, and
lowering it is a visible edit instead of an invisible deletion.

Usage:
    python3 scripts/check_preservation_corpus.py
    python3 scripts/check_preservation_corpus.py --self-test
"""

import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(REPO_ROOT, "test_fixtures")
CORPUS_DIR = os.path.join(FIXTURES, "preservation")
SVG_DIR = os.path.join(FIXTURES, "svg")

# The invariant vocabulary. Both ports implement exactly these names; a
# vector may pin a known violation only against one of them.
INVARIANTS = {
    "id_uniqueness",
    "id_survival",
    "consumed_ids_die",
    "fresh_ids",
    "bystanders_unchanged",
    "subject_fields_only",
}

CARDINALITIES = {"one_to_one", "delete", "merge", "split", "wrap", "unwrap"}

# Ops that only move the selection cursor. A vector built solely from these
# cannot change the document, so every invariant over it is vacuously true.
SELECTION_ONLY_OPS = {"select_by_ids", "select_rect", "select_all", "deselect"}

PORTS = ("rust", "swift")

REQUIRED_KEYS = (
    "name", "doc", "cardinality", "subject_ids", "speaks_to",
    "consumed_ids", "expected_fresh_ids", "expected_violations",
)

# Where a `setup_test_json` document lives, relative to test_fixtures/.
TEST_JSON_SETUP_DIR = os.path.join(FIXTURES, "expected")

# Element types that are CONTAINERS for the V2 bystander rule.
CONTAINER_TYPES = {"group", "layer"}


def load_corpus_file(path: str):
    """Read one corpus file and return `(min_vectors, vectors, errors)`.

    The shape is an OBJECT — `{"min_vectors": N, "vectors": [...]}` — and the
    bare-array form this family used until 2026-07-28 is REFUSED rather than
    tolerated, because a tolerant reader would accept `[]` again and re-open
    exactly the hole `min_vectors` exists to close.
    """
    where = os.path.basename(path)
    with open(path, encoding="utf-8") as f:
        try:
            root = json.load(f)
        except json.JSONDecodeError as e:
            return 0, [], [f"{where}: bad JSON: {e}"]
    if not isinstance(root, dict):
        return 0, [], [
            f"{where}: top level must be an OBJECT carrying 'min_vectors' and "
            f"'vectors' (a bare array cannot declare its own floor, which is "
            f"how an emptied corpus turned all four gates green)"
        ]
    errs = []
    n_min = root.get("min_vectors")
    if not isinstance(n_min, int) or isinstance(n_min, bool) or n_min < 1:
        errs.append(
            f"{where}: 'min_vectors' must be an integer >= 1, got {n_min!r} — "
            f"a floor of zero is not a floor"
        )
        n_min = 0
    vecs = root.get("vectors")
    if not isinstance(vecs, list):
        errs.append(f"{where}: 'vectors' must be a list")
        return n_min, [], errs
    if len(vecs) < n_min:
        errs.append(
            f"{where}: declares min_vectors={n_min} but carries {len(vecs)} "
            f"vector(s) — the corpus lost vectors without anyone lowering the "
            f"floor it states about itself"
        )
    return n_min, vecs, errs


def svg_ids(svg_text: str) -> set:
    return set(re.findall(r'\bid="([^"]+)"', svg_text))


def svg_container_ids(svg_text: str) -> set:
    """ids carried by a `<g ...>` element (Layer or Group after parsing)."""
    out = set()
    for tag in re.findall(r"<g\b[^>]*>", svg_text):
        m = re.search(r'\bid="([^"]+)"', tag)
        if m:
            out.add(m.group(1))
    return out


def test_json_setup_ids(doc) -> tuple:
    """`(all ids, container ids)` of a canonical-test-JSON setup document.

    The walk descends `layers` / `children` / `symbols` exactly as the two
    ports' `preservation_walk` does — deliberately NOT into `mask`, whose
    subtree is artwork belonging to its host element rather than a document
    element of its own.
    """
    ids, containers = set(), set()

    def walk(node):
        if isinstance(node, list):
            for item in node:
                walk(item)
            return
        if not isinstance(node, dict):
            return
        if "type" in node and isinstance(node.get("id"), str):
            ids.add(node["id"])
            if node["type"] in CONTAINER_TYPES:
                containers.add(node["id"])
        for key in ("layers", "children", "symbols"):
            if key in node:
                walk(node[key])

    walk(doc)
    return ids, containers


def vector_ops(vec: dict) -> list:
    ops = []
    for txn in vec.get("txns", []):
        ops.extend(txn.get("ops", []))
    ops.extend(vec.get("ops", []))
    return ops


def check_vector(path: str, vec, seen_names: set) -> list:
    errs = []
    where = os.path.basename(path)
    if not isinstance(vec, dict):
        return [f"{where}: vector is not an object"]
    name = vec.get("name", "<unnamed>")
    tag = f"{where}:{name}"

    for key in REQUIRED_KEYS:
        if key not in vec:
            errs.append(f"{tag}: missing required key '{key}'")
    if errs:
        return errs

    if name in seen_names:
        errs.append(f"{tag}: duplicate vector name")
    seen_names.add(name)

    if vec["cardinality"] not in CARDINALITIES:
        errs.append(f"{tag}: unknown cardinality {vec['cardinality']!r}")

    # A vector declares EXACTLY ONE setup door. `setup_test_json` exists
    # because the SVG codec has no counterpart for a mask, a blend mode or a
    # stroke alignment, so a corpus whose only door is SVG cannot place those
    # on a bystander — the very class T4 exists to watch.
    doors = [k for k in ("setup_svg", "setup_test_json") if k in vec]
    if len(doors) != 1:
        errs.append(
            f"{tag}: must declare exactly ONE of setup_svg / setup_test_json, "
            f"declares {doors}"
        )
        return errs
    if "setup_test_json" in vec:
        setup_name = vec["setup_test_json"]
        setup_path = os.path.join(TEST_JSON_SETUP_DIR, setup_name)
        if not os.path.exists(setup_path):
            errs.append(f"{tag}: setup_test_json {setup_name} does not exist")
            return errs
        if "events" in vec:
            errs.append(
                f"{tag}: declares BOTH `events` and `setup_test_json` — the "
                f"gesture runner takes SVG text, so this pairing would silently "
                f"run against the wrong document (V3)"
            )
            return errs
        with open(setup_path, encoding="utf-8") as f:
            try:
                doc = json.load(f)
            except json.JSONDecodeError as e:
                errs.append(f"{tag}: setup_test_json {setup_name} is bad JSON: {e}")
                return errs
        present, containers = test_json_setup_ids(doc)
    else:
        setup_name = vec["setup_svg"]
        svg_path = os.path.join(SVG_DIR, setup_name)
        if not os.path.exists(svg_path):
            errs.append(f"{tag}: setup_svg {setup_name} does not exist")
            return errs
        with open(svg_path, encoding="utf-8") as f:
            svg = f.read()
        present = svg_ids(svg)
        containers = svg_container_ids(svg)

    named = list(vec["subject_ids"]) + list(vec["consumed_ids"])

    # V1 — every named id exists in the setup.
    for eid in named:
        if eid not in present:
            errs.append(
                f"{tag}: names id {eid!r}, which the setup "
                f"{setup_name} does not define (V1)"
            )

    # V2 — a container bystander must exist.
    bystander_containers = containers - set(named)
    if not bystander_containers:
        errs.append(
            f"{tag}: no CONTAINER bystander — every container id in "
            f"{setup_name} is named by this vector, so the T4 "
            f"bystander clause is unwatchable here (V2)"
        )

    # V7 — `bystander_fields_present` must be well-formed and must range over
    # BYSTANDERS. The runtime half (that the loaded setup really carries each
    # field) lives in the two ports' gates; this half stops a typo'd id from
    # turning the claim into a no-op.
    for bid, keys in (vec.get("bystander_fields_present") or {}).items():
        if bid in named:
            errs.append(
                f"{tag}: bystander_fields_present names {bid!r}, which the "
                f"vector also names as a subject or consumed id — a subject is "
                f"not a bystander (V7)"
            )
        if bid not in present:
            errs.append(
                f"{tag}: bystander_fields_present names {bid!r}, which the "
                f"setup {setup_name} does not define (V7)"
            )
        if not isinstance(keys, list) or not keys:
            errs.append(
                f"{tag}: bystander_fields_present[{bid!r}] must be a non-empty "
                f"list of field names (V7)"
            )

    # V3 — the vector must actually edit the document, through whichever of
    # the two drivers it declares.
    if "events" in vec:
        if not str(vec.get("tool", "")).strip():
            errs.append(
                f"{tag}: gesture-driven (has `events`) but names no `tool` — "
                f"the runner has nothing to dispatch through (V3)"
            )
        kinds = [e.get("kind") for e in vec["events"]]
        if "press" not in kinds or "release" not in kinds:
            errs.append(
                f"{tag}: gesture events {kinds} lack a press and/or a release "
                f"— no tool commits without both (V3)"
            )
        if vector_ops(vec):
            errs.append(
                f"{tag}: declares BOTH `events` and ops — the two drivers are "
                f"exclusive, and only one of them would run (V3)"
            )
    else:
        ops = vector_ops(vec)
        if not ops:
            errs.append(f"{tag}: no ops (V3)")
        else:
            verbs = [o.get("op") for o in ops]
            if all(v in SELECTION_ONLY_OPS for v in verbs):
                errs.append(
                    f"{tag}: every op is selection-only ({verbs}) — this vector "
                    f"cannot change the document (V3)"
                )

    # V4 — a subject without a subject set is not an assertion.
    if vec["cardinality"] == "one_to_one" and vec["subject_ids"]:
        if not vec["speaks_to"]:
            errs.append(
                f"{tag}: one_to_one with subject_ids but empty speaks_to — "
                f"`subject_fields_only` would be vacuously true (V4)"
            )

    # V6 — a `must_change` claim must be well-formed.
    if "must_change" in vec:
        if not vec["subject_ids"]:
            errs.append(
                f"{tag}: declares must_change but has no subject_ids — the "
                f"claim ranges over the subjects, so it asserts nothing (V6)"
            )
        stray = [k for k in vec["must_change"] if k not in vec["speaks_to"]]
        if stray:
            errs.append(
                f"{tag}: must_change names {stray}, which `speaks_to` does not "
                f"allow the edit to touch — a self-contradicting vector (V6)"
            )

    # V5 — pinned violations must be legible.
    ev = vec["expected_violations"]
    if not isinstance(ev, dict) or set(ev) != set(PORTS):
        errs.append(
            f"{tag}: expected_violations must be an object keyed by exactly "
            f"{sorted(PORTS)}"
        )
    else:
        for port, rows in ev.items():
            for row in rows:
                if not isinstance(row, dict):
                    errs.append(f"{tag}: {port} violation row is not an object")
                    continue
                inv = row.get("invariant")
                if inv not in INVARIANTS:
                    errs.append(
                        f"{tag}: {port} violation names unknown invariant "
                        f"{inv!r} (known: {sorted(INVARIANTS)}) (V5)"
                    )
                for field in ("row", "note"):
                    if not str(row.get(field, "")).strip():
                        errs.append(
                            f"{tag}: {port} violation of {inv!r} has empty "
                            f"'{field}' — a pinned violation must state its "
                            f"site and why (V5)"
                        )
    return errs


def main() -> int:
    if not os.path.isdir(CORPUS_DIR):
        print(f"preservation corpus: MISSING directory {CORPUS_DIR}")
        return 1
    files = sorted(
        os.path.join(CORPUS_DIR, f)
        for f in os.listdir(CORPUS_DIR)
        if f.endswith(".json")
    )
    if not files:
        print("preservation corpus: no vectors found")
        return 1

    errs = []
    seen_names = set()
    n = 0
    floor = 0
    for path in files:
        n_min, vecs, file_errs = load_corpus_file(path)
        errs.extend(file_errs)
        floor += n_min
        for vec in vecs:
            n += 1
            errs.extend(check_vector(path, vec, seen_names))

    for e in errs:
        print(f"FAIL {e}")
    if errs:
        print(f"preservation-corpus gate: {len(errs)} problem(s) in {n} vector(s)")
        return 1
    print(f"preservation-corpus gate: OK ({n} vectors, {len(files)} file(s), "
          f"declared floor {floor})")
    return 0


def self_test() -> int:
    """Pin the FLOOR's own red, because the floor is the one check here that
    fires on the ABSENCE of data and so can never be exercised by the shipped
    corpus. Four shapes, each of which was green before 2026-07-28."""
    import tempfile

    failures = []

    def check(cond, label):
        if cond:
            print(f"  ok: {label}")
        else:
            failures.append(label)
            print(f"  FAIL: {label}")

    cases = [
        ("[]", "an emptied bare array is refused (the shipped hole)",
         "top level must be an OBJECT"),
        ('{"min_vectors": 12, "vectors": []}',
         "a corpus below its own declared floor is refused",
         "declares min_vectors=12 but carries 0"),
        ('{"min_vectors": 0, "vectors": []}',
         "a floor of zero is refused", "not a floor"),
        ('{"vectors": []}', "a corpus that declares no floor is refused",
         "must be an integer >= 1"),
    ]
    with tempfile.TemporaryDirectory(prefix="preservation_selftest_") as root:
        for body, label, needle in cases:
            path = os.path.join(root, "case.json")
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(body)
            _, _, errs = load_corpus_file(path)
            check(any(needle in e for e in errs), label)

        # And the shipped corpus itself passes the floor it declares — a
        # self-test that only proved the red could pass over a corpus the
        # real gate rejects.
        for path in sorted(
            os.path.join(CORPUS_DIR, f)
            for f in os.listdir(CORPUS_DIR) if f.endswith(".json")
        ):
            n_min, vecs, errs = load_corpus_file(path)
            check(errs == [] and n_min >= 1 and len(vecs) >= n_min,
                  f"{os.path.basename(path)} declares a floor of {n_min} and "
                  f"carries {len(vecs)}")

    if failures:
        print(f"self-test: {len(failures)} FAILURE(S)")
        return 1
    print("self-test: OK")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv[1:]:
        sys.exit(self_test())
    sys.exit(main())
