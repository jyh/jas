#!/bin/sh

export WORKSPACE_YAML=../workspace

. .venv/bin/activate
cd jas_flask

set -e -x

python app.py
