#!/bin/sh

. .venv/bin/activate

set -e -x

python capture_app.py "$@"
