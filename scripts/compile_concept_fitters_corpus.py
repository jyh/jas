#!/usr/bin/env python3
"""Compile the concept-fitter conformance corpus to self-contained JSON.

Each case in ``workspace/tests/concept_fitters.yaml`` names a concept
(``workspace/concepts/<id>.yaml``), supplies input points, and pins the expected
fitter result (``null`` or the flat ``[params..., cx, cy, rotation]`` list). This
script resolves each case against its concept file — inlining the ``fitter``
expression — into a self-contained JSON corpus the native apps consume with only
their existing expression evaluator (no YAML parser, no concept registry). A CI
freshness check (``scripts/check_concept_fitters_corpus.sh``) keeps it in sync.
See CONCEPTS.md §10.

A compiled case is:

    { "concept": "regular_polygon", "fitter": "<expr>",
      "points": [[10,0],[0,10],[-10,0],[0,-10]],
      "expected": [4, 10, 0, 0, 0] }

Usage:
    python scripts/compile_concept_fitters_corpus.py [OUT_JSON]
Default OUT_JSON = test_fixtures/concept_fitters/conformance.json
"""

import json
import os
import sys

import yaml

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONCEPTS_DIR = os.path.join(REPO_ROOT, "workspace", "concepts")
CORPUS_YAML = os.path.join(
    REPO_ROOT, "workspace", "tests", "concept_fitters.yaml"
)
DEFAULT_OUT = os.path.join(
    REPO_ROOT, "test_fixtures", "concept_fitters", "conformance.json"
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
        if "fitter" not in concept:
            raise KeyError(f"concept {cid!r} has no fitter")
        out.append({
            "concept": cid,
            "fitter": concept["fitter"].strip(),
            "points": case["points"],
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
