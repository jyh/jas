#!/bin/sh

cd JasSwift

set -e -x

# Run the built binary directly (not `swift run`) so environment variables
# like JAS_PATH_B propagate to the app process. `swift run` does not forward
# them to the launched GUI binary.
#
# Arguments are FORWARDED to the app, which is what lets a harness launch a
# drivable instance unattended (GUIEYES). The app already parses both flags
# (JasApp.swift `--title`, TestFifo.swift `--test-fifo`); before this, the
# launcher swallowed them and there was no way to start a targetable window:
#
#   ./swift.sh --title JasHarness --test-fifo /tmp/jas-harness.fifo
#
# `--title` gives the window an exact `kCGWindowName` for CGWindowList lookup
# (jas_gui_harness.py find_window / scripts/gui_probe_swift.py), and
# `--test-fifo` opens the one-way command channel (`tool <id>`,
# `action <name> [json]`). With no arguments the behavior is unchanged.
swift build
exec .build/debug/Jas "$@"
