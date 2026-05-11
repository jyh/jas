#!/bin/sh

cd jas_ocaml

set -e -x

# dune clean
dune build
dune exec bin/main.exe
