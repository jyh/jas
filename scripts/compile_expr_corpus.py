#!/usr/bin/env python3
"""Compile the expression conformance corpus (YAML) to JSON.

``workspace/tests/expressions.yaml`` is the human-authored source of truth and
is read directly by the Python conformance test
(``workspace_interpreter/tests/test_expr.py``). The native apps (Rust, Swift,
OCaml) consume the compiled JSON emitted here, so they need no YAML parser. A
CI freshness check (``scripts/check_expr_corpus.sh``) keeps the two in sync.

The compile is a faithful passthrough: each YAML case becomes one JSON object
with the fields the interpreters need — ``expr``, optional ``state``/``data``,
``expected``, ``type`` — in a fixed key order so the output is deterministic.
The human-only ``note`` field is dropped.

Usage:
    python scripts/compile_expr_corpus.py [SRC_YAML] [OUT_JSON]

Defaults:
    SRC_YAML = workspace/tests/expressions.yaml
    OUT_JSON = test_fixtures/expressions/conformance.json
"""

import json
import os
import sys

import yaml

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SRC = os.path.join(REPO_ROOT, "workspace", "tests", "expressions.yaml")
DEFAULT_OUT = os.path.join(
    REPO_ROOT, "test_fixtures", "expressions", "conformance.json"
)


def compile_corpus(src_path):
    with open(src_path) as f:
        data = yaml.safe_load(f)
    cases = []
    for case in data["tests"]:
        out = {"expr": case["expr"]}
        if "state" in case:
            out["state"] = case["state"]
        if "data" in case:
            out["data"] = case["data"]
        out["expected"] = case["expected"]
        out["type"] = case["type"]
        cases.append(out)
    return cases


def main():
    args = sys.argv[1:]
    src = args[0] if len(args) > 0 else DEFAULT_SRC
    out = args[1] if len(args) > 1 else DEFAULT_OUT
    cases = compile_corpus(src)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(cases, f, indent=2, ensure_ascii=False)
        f.write("\n")


if __name__ == "__main__":
    main()
