#!/bin/sh

cd jas_ocaml

set -e -x

dune exec bin/main.exe
