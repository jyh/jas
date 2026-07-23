#!/bin/sh

. .venv/bin/activate

export CLAUDE_CONFIG_DIR="${HOME}/.claude-jas"

set -e -x

claude --dangerously-skip-permissions "$@"
