#!/bin/bash
# Run OCaml tests for Jas
cd "$(dirname "$0")"
dune runtest
