#!/bin/sh

. .venv/bin/activate
cd jas

set -e -x

python -m jas_app 
