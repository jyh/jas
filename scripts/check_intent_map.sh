#!/bin/bash
# Verify intent_map.json + INTENT_MAP.md are up-to-date with
# workspace/workspace.json (and with the generator's authored verb table).
#
# Run by CI (the workspace-json-fresh job) after every workspace/action
# change. First runs the generator's --self-test (structural assertions:
# action count, native-intercept / tool-lifecycle / journaling-vs-preview
# classifications), then fails (exit 1) if regenerating the artifacts would
# produce different files than what's committed. The remedy, printed on
# failure:
#
#     python scripts/gen_intent_map.py
#     git add intent_map.json INTENT_MAP.md
#
# This script does NOT modify the tree — it's a read-only check.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

JSON_OUT=intent_map.json
MD_OUT=INTENT_MAP.md

python scripts/gen_intent_map.py --self-test

for f in "$JSON_OUT" "$MD_OUT"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: $f is missing. Regenerate with:" >&2
        echo "  python scripts/gen_intent_map.py" >&2
        exit 1
    fi
done

TMPDIR_MAP="$(mktemp -d -t intent_map.XXXXXX)"
trap 'rm -rf "$TMPDIR_MAP"' EXIT

python scripts/gen_intent_map.py \
    --json "$TMPDIR_MAP/intent_map.json" \
    --md "$TMPDIR_MAP/INTENT_MAP.md" >/dev/null

STALE=0
for f in "$JSON_OUT" "$MD_OUT"; do
    if ! diff -q "$f" "$TMPDIR_MAP/$(basename "$f")" >/dev/null; then
        STALE=1
        echo "ERROR: $f is out of date relative to workspace/workspace.json" >&2
        echo "(or the generator's authored verb table)." >&2
        echo >&2
        echo "Diff (committed vs. regenerated):" >&2
        diff "$f" "$TMPDIR_MAP/$(basename "$f")" | head -40 >&2
        echo >&2
    fi
done

if [[ "$STALE" -ne 0 ]]; then
    echo "Regenerate and commit the result:" >&2
    echo "  python scripts/gen_intent_map.py" >&2
    echo "  git add $JSON_OUT $MD_OUT" >&2
    exit 1
fi

echo "$JSON_OUT and $MD_OUT are up to date."
