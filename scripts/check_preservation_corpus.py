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
      selection-only vocabulary, so it edits the document at all;
  V4  a one-to-one vector with a subject declares a non-empty `speaks_to`,
      because "only the spoken-to keys may differ" is vacuously true when the
      subject set is empty;
  V5  every `expected_violations` row names a KNOWN invariant and states both
      the site (`row`) and prose (`note`), so a pinned violation can never be
      an unexplained suppression.

The runtime half — that each declared violation still reproduces, and that
each non-declared invariant holds — lives in the two ports' gates
(`preservation_invariants` in jas_dioxus/src/cross_language_test.rs and
JasSwift/Tests/CrossLanguageTests.swift). A declared violation is asserted to
FAIL there, so fixing a site turns the gate red until the declaration is
removed.

Usage:
    python3 scripts/check_preservation_corpus.py
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
    "name", "doc", "setup_svg", "cardinality", "subject_ids", "speaks_to",
    "consumed_ids", "expected_fresh_ids", "expected_violations",
)


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

    svg_path = os.path.join(SVG_DIR, vec["setup_svg"])
    if not os.path.exists(svg_path):
        errs.append(f"{tag}: setup_svg {vec['setup_svg']} does not exist")
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
                f"{tag}: names id {eid!r}, which the setup SVG "
                f"{vec['setup_svg']} does not define (V1)"
            )

    # V2 — a container bystander must exist.
    bystander_containers = containers - set(named)
    if not bystander_containers:
        errs.append(
            f"{tag}: no CONTAINER bystander — every `<g>` id in "
            f"{vec['setup_svg']} is named by this vector, so the T4 "
            f"bystander clause is unwatchable here (V2)"
        )

    # V3 — the vector must actually edit the document.
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
    for path in files:
        with open(path, encoding="utf-8") as f:
            try:
                vecs = json.load(f)
            except json.JSONDecodeError as e:
                errs.append(f"{os.path.basename(path)}: bad JSON: {e}")
                continue
        if not isinstance(vecs, list):
            errs.append(f"{os.path.basename(path)}: top level must be a list")
            continue
        for vec in vecs:
            n += 1
            errs.extend(check_vector(path, vec, seen_names))

    for e in errs:
        print(f"FAIL {e}")
    if errs:
        print(f"preservation-corpus gate: {len(errs)} problem(s) in {n} vector(s)")
        return 1
    print(f"preservation-corpus gate: OK ({n} vectors, {len(files)} file(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
