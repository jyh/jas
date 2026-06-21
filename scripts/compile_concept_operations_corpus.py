#!/usr/bin/env python3
"""Compile the concept-operation conformance corpus to self-contained JSON.

Each case in ``workspace/tests/concept_operations.yaml`` names a concept
(``workspace/concepts/<id>.yaml``) and one of its operations, supplies the
current parameters, and pins the expected resolved changes. This script
resolves each case against its concept file — looking the operation up by id,
inlining its ``set:`` map of param-name -> expression, and merging the concept's
declared parameter defaults with the case's param overrides — into a
self-contained JSON corpus the native apps consume with only their existing
expression evaluator (no YAML parser, no concept registry). A CI freshness check
(``scripts/check_concept_operations_corpus.sh``) keeps it in sync. See
CONCEPTS.md §9.

A compiled case is:

    { "concept": "gear", "op": "add_tooth",
      "params": { "teeth": 12, "outer": 50, "root": 38 },
      "set": { "teeth": "param.teeth + 1" },
      "expected": { "teeth": 13 } }

Usage:
    python scripts/compile_concept_operations_corpus.py [OUT_JSON]
Default OUT_JSON = test_fixtures/concept_operations/conformance.json
"""

import json
import os
import sys

import yaml

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONCEPTS_DIR = os.path.join(REPO_ROOT, "workspace", "concepts")
CORPUS_YAML = os.path.join(
    REPO_ROOT, "workspace", "tests", "concept_operations.yaml"
)
DEFAULT_OUT = os.path.join(
    REPO_ROOT, "test_fixtures", "concept_operations", "conformance.json"
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


def find_operation(concept, op_id):
    for op in concept.get("operations", []):
        if op["id"] == op_id:
            return op
    raise KeyError(
        f"concept {concept['id']!r} has no operation {op_id!r}"
    )


def compile_corpus():
    concepts = load_concepts()
    with open(CORPUS_YAML) as f:
        cases = yaml.safe_load(f)["tests"]
    out = []
    for case in cases:
        cid = case["concept"]
        concept = concepts[cid]
        operation = find_operation(concept, case["op"])
        defaults = {p["name"]: p["default"] for p in concept.get("params", [])}
        params = dict(defaults)
        params.update(case.get("params", {}))
        # The set map is {param-name: expression-string}; carry it verbatim so
        # each app evaluates the very same expression the pack declares.
        set_map = {
            name: expr.strip() if isinstance(expr, str) else expr
            for name, expr in operation["set"].items()
        }
        out.append({
            "concept": cid,
            "op": case["op"],
            "params": params,
            "set": set_map,
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
