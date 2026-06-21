#!/usr/bin/env python3
"""Compile the concept-constraint conformance corpus to self-contained JSON.

Each case in ``workspace/tests/concept_constraints.yaml`` names a concept
(``workspace/concepts/<id>.yaml``), supplies parameters, and pins the expected
list of violated constraint ids. This script resolves each case against its
concept file — inlining the constraints' ``id``/``check`` (in declared order) and
merging the concept's declared parameter defaults with the case overrides — into
a self-contained JSON corpus the native apps consume with only their existing
expression evaluator (no YAML parser, no concept registry). A CI freshness check
(``scripts/check_concept_constraints_corpus.sh``) keeps it in sync. See
CONCEPTS.md §11.

A compiled case is:

    { "concept": "gear",
      "constraints": [ { "id": "min_teeth", "check": "param.teeth >= 3" }, ... ],
      "params": { "teeth": 2, "outer": 50, "root": 38 },
      "expected": [ "min_teeth" ] }

Usage:
    python scripts/compile_concept_constraints_corpus.py [OUT_JSON]
Default OUT_JSON = test_fixtures/concept_constraints/conformance.json
"""

import json
import os
import sys

import yaml

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONCEPTS_DIR = os.path.join(REPO_ROOT, "workspace", "concepts")
CORPUS_YAML = os.path.join(
    REPO_ROOT, "workspace", "tests", "concept_constraints.yaml"
)
DEFAULT_OUT = os.path.join(
    REPO_ROOT, "test_fixtures", "concept_constraints", "conformance.json"
)


def load_concepts():
    concepts = {}
    for fn in sorted(os.listdir(CONCEPTS_DIR)):
        if not fn.endswith(".yaml"):
            continue
        with open(os.path.join(CONCEPTS_DIR, fn)) as f:
            c = yaml.safe_load(f)
        concepts[c["id"]] = c
    return concepts


def compile_corpus():
    concepts = load_concepts()
    with open(CORPUS_YAML) as f:
        cases = yaml.safe_load(f)["tests"]
    out = []
    for case in cases:
        cid = case["concept"]
        concept = concepts[cid]
        if "constraints" not in concept:
            raise KeyError(f"concept {cid!r} has no constraints")
        defaults = {p["name"]: p["default"] for p in concept.get("params", [])}
        params = dict(defaults)
        params.update(case.get("params", {}))
        # Carry id + check (in declared order); message is for display, not the
        # checker logic the gate pins.
        constraints = [
            {"id": c["id"], "check": c["check"].strip()
             if isinstance(c["check"], str) else c["check"]}
            for c in concept["constraints"]
        ]
        out.append({
            "concept": cid,
            "constraints": constraints,
            "params": params,
            "expected": case["expected"],
        })
    return out


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUT
    cases = compile_corpus()
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(cases, f, indent=2, ensure_ascii=False)
        f.write("\n")


if __name__ == "__main__":
    main()
