#!/bin/sh
# Run the Rust/Dioxus app as a CHROMELESS DESKTOP WINDOW for GUI-harness testing
# (jas_gui_harness.py). The app is web/wasm-only (its canvas is web_sys), so a
# true native port is impractical — instead we serve the wasm build and open it
# in a chromeless Chrome app window (no tabs / URL bar; the app fills the
# window just like the native apps), which the harness can find and drive.
#
# Usage:
#   ./run_dioxus_desktop.sh
# then, once the window is up, drive it with the harness:
#   export JAS_TITLE=Jas JAS_PROC="Google Chrome"
#   python3 jas_gui_harness.py click 0.5 0.5    # FOCUS-CLICK first (raises this
#                                               # window over any other Chrome),
#   python3 jas_gui_harness.py key m            # then drive normally.
#
# NOTES:
#   - The web app uses Ctrl (not Cmd) for menu shortcuts (Ctrl+N New, etc.).
#   - A dedicated --user-data-dir gives its own Chrome instance + window titled
#     "Jas — Vector Drawing" (so JAS_TITLE=Jas matches via substring).
#   - With another Chrome already running, AppleScript `activate` is ambiguous
#     across instances — prefer a focus-click on the window content to raise it.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
PORT="${PORT:-8080}"
URL="http://localhost:$PORT"
PROFILE="/tmp/jas-dioxus-chrome"

if ! curl -s -o /dev/null "$URL"; then
  echo "Starting dx serve (web) on :$PORT ..."
  ( cd "$ROOT/jas_dioxus" && nohup dx serve --platform web >/tmp/jas-dx-serve.log 2>&1 & )
  printf "waiting for :%s " "$PORT"
  for _ in $(seq 1 180); do
    curl -s -o /dev/null "$URL" && break
    printf "."; sleep 1
  done
  echo
fi

echo "Opening chromeless Chrome window at $URL ..."
open -na "Google Chrome" --args \
  --app="$URL" \
  --user-data-dir="$PROFILE" \
  --window-size=1400,950 \
  --no-first-run --no-default-browser-check

echo "Window title: 'Jas — Vector Drawing'."
echo "Harness:  export JAS_TITLE=Jas JAS_PROC=\"Google Chrome\"  (focus-click first)"
