#!/bin/bash
# Build the Jas OCaml application
cd "$(dirname "$0")"
dune build
echo "Build complete. Run with: dune exec bin/main.exe"
