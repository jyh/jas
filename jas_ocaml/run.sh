#!/bin/bash
# Run the Jas OCaml application
cd "$(dirname "$0")"
dune exec bin/main.exe "$@"
