#!/bin/bash
# Verify workspace/workspace.json is up-to-date with workspace/*.yaml.
#
# Run by CI after every YAML change. Fails (exit 1) if regenerating
# workspace.json from the YAML sources would produce a different file
# than what's committed. The remedy, printed on failure:
#
#     python -m workspace_interpreter.compile workspace/ workspace/workspace.json
#     git add workspace/workspace.json
#
# This script does NOT modify the tree — it's a read-only check. Run
# from the repository root (or anywhere; it cds to the repo root).

set -euo pipefail

# Resolve repo root (directory containing this script's parent)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [[ ! -f workspace/workspace.json ]]; then
    echo "ERROR: workspace/workspace.json is missing. Regenerate with:" >&2
    echo "  python -m workspace_interpreter.compile workspace/ workspace/workspace.json" >&2
    exit 1
fi

# Regenerate into a temp file and compare.
TMPFILE="$(mktemp -t workspace.json.XXXXXX)"
trap 'rm -f "$TMPFILE"' EXIT

python -m workspace_interpreter.compile workspace/ "$TMPFILE"

if ! diff -q workspace/workspace.json "$TMPFILE" >/dev/null; then
    echo "ERROR: workspace/workspace.json is out of date relative to workspace/*.yaml." >&2
    echo >&2
    echo "Regenerate and commit the result:" >&2
    echo "  python -m workspace_interpreter.compile workspace/ workspace/workspace.json" >&2
    echo "  git add workspace/workspace.json" >&2
    echo >&2
    echo "Diff (committed vs. regenerated):" >&2
    diff workspace/workspace.json "$TMPFILE" | head -40 >&2
    exit 1
fi

echo "workspace/workspace.json is up to date."
