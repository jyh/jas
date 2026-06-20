#!/bin/bash
# Verify test_fixtures/expressions/conformance.json is up-to-date with
# workspace/tests/expressions.yaml.
#
# Run by CI after every corpus change. Fails (exit 1) if regenerating the
# JSON from the YAML source would produce a different file than what's
# committed. The remedy, printed on failure:
#
#     python scripts/compile_expr_corpus.py
#     git add test_fixtures/expressions/conformance.json
#
# This script does NOT modify the tree — it's a read-only check.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

OUT=test_fixtures/expressions/conformance.json

if [[ ! -f "$OUT" ]]; then
    echo "ERROR: $OUT is missing. Regenerate with:" >&2
    echo "  python scripts/compile_expr_corpus.py" >&2
    exit 1
fi

TMPFILE="$(mktemp -t conformance.json.XXXXXX)"
trap 'rm -f "$TMPFILE"' EXIT

python scripts/compile_expr_corpus.py workspace/tests/expressions.yaml "$TMPFILE"

if ! diff -q "$OUT" "$TMPFILE" >/dev/null; then
    echo "ERROR: $OUT is out of date relative to workspace/tests/expressions.yaml." >&2
    echo >&2
    echo "Regenerate and commit the result:" >&2
    echo "  python scripts/compile_expr_corpus.py" >&2
    echo "  git add $OUT" >&2
    echo >&2
    echo "Diff (committed vs. regenerated):" >&2
    diff "$OUT" "$TMPFILE" | head -40 >&2
    exit 1
fi

echo "$OUT is up to date."
