#!/bin/bash
# dx serve in release mode. Slower first build (~60s), but the
# resulting WASM is ~10-100x faster on hot paths than the default
# debug profile — use this for perf-sensitive manual testing.

cd jas_dioxus

set -x

dx serve --release --addr 0.0.0.0 --port 8080
