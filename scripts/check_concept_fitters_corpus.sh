#!/bin/bash
# Verify test_fixtures/concept_fitters/conformance.json is up-to-date with the
# concept files (workspace/concepts/*.yaml) and the corpus
# (workspace/tests/concept_fitters.yaml).
#
# Run by CI after any concept/fitter/corpus change. Fails (exit 1) if
# regenerating the JSON would differ from what's committed. The remedy, printed
# on failure:
#
#     python scripts/compile_concept_fitters_corpus.py
#     git add test_fixtures/concept_fitters/conformance.json
#
# Read-only; does not modify the tree.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

OUT=test_fixtures/concept_fitters/conformance.json

if [[ ! -f "$OUT" ]]; then
    echo "ERROR: $OUT is missing. Regenerate with:" >&2
    echo "  python scripts/compile_concept_fitters_corpus.py" >&2
    exit 1
fi

TMPFILE="$(mktemp -t concept_fitters.json.XXXXXX)"
trap 'rm -f "$TMPFILE"' EXIT

python scripts/compile_concept_fitters_corpus.py "$TMPFILE"

if ! diff -q "$OUT" "$TMPFILE" >/dev/null; then
    echo "ERROR: $OUT is out of date relative to workspace/concepts/*.yaml or workspace/tests/concept_fitters.yaml." >&2
    echo >&2
    echo "Regenerate and commit the result:" >&2
    echo "  python scripts/compile_concept_fitters_corpus.py" >&2
    echo "  git add $OUT" >&2
    echo >&2
    echo "Diff (committed vs. regenerated):" >&2
    diff "$OUT" "$TMPFILE" | head -40 >&2
    exit 1
fi

echo "$OUT is up to date."
