#!/bin/sh

. .venv/bin/activate

set -e -x

claude --dangerously-skip-permissions "$@"
