#!/usr/bin/env python3
"""Compile the concept-generator conformance corpus to self-contained JSON.

Each case in ``workspace/tests/concepts.yaml`` names a concept
(``workspace/concepts/<id>.yaml``) and overrides parameters. This script
resolves each case against its concept file — inlining the generator expression,
merging the concept's declared parameter defaults with the case overrides, and
carrying the ``closed`` flag — into a self-contained JSON corpus that the native
apps consume with only their existing expression evaluator (no YAML parser, no
concept registry). A CI freshness check (``scripts/check_concept_corpus.sh``)
keeps it in sync. See CONCEPTS.md.

Usage:
    python scripts/compile_concept_corpus.py [OUT_JSON]
Default OUT_JSON = test_fixtures/concepts/conformance.json
"""

import json
import os
import sys

import yaml

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONCEPTS_DIR = os.path.join(REPO_ROOT, "workspace", "concepts")
CORPUS_YAML = os.path.join(REPO_ROOT, "workspace", "tests", "concepts.yaml")
DEFAULT_OUT = os.path.join(
    REPO_ROOT, "test_fixtures", "concepts", "conformance.json"
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
        defaults = {p["name"]: p["default"] for p in concept.get("params", [])}
        params = dict(defaults)
        params.update(case.get("params", {}))
        out.append({
            "concept": cid,
            "generator": concept["generator"].strip(),
            "params": params,
            "closed": bool(concept.get("closed", True)),
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
