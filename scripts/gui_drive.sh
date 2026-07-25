#!/bin/sh
# GUIEYES — drive the live Rust/Dioxus app and assert VISUAL facts.
#
# The conductor entry point. It brings up whatever the checks need (a wasm dev
# server, a fresh headless Chrome per check), runs them, and exits NONZERO on
# the first failing check, so it can gate a wave.
#
# USAGE
#   ./scripts/gui_drive.sh                          # all checks
#   ./scripts/gui_drive.sh --list                   # what can be checked
#   ./scripts/gui_drive.sh --check chain_visible    # one check
#   ./scripts/gui_drive.sh --shot-dir /tmp/eyes     # keep evidence PNGs
#   ./scripts/gui_drive.sh --headed                 # watch it happen
#   ./scripts/gui_drive.sh --regress dead_tile      # prove the checks bite
#
# ENVIRONMENT
#   PORT=8097      dev-server port (a private default, so a running
#                  ./dxserve.sh on :8080 is never disturbed)
#   CDP_PORT=9333  DevTools port for the driver
#   PYTHON=...     interpreter (default: the repo .venv, which has
#                  websocket-client)
#   KEEP_SERVE=1   leave the dev server running after the run
#
# REQUIREMENTS: Google Chrome, `dx`, and websocket-client. NO macOS
# Screen-Recording or Accessibility grant is needed — everything goes through
# the DevTools protocol — so this runs unattended and on an unprivileged host.
#
# WHAT IT DOES NOT DO: judge FEEL. See GUI_EYES.md §Limits.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-8097}"
CDP_PORT="${CDP_PORT:-9333}"
PYTHON="${PYTHON:-$ROOT/.venv/bin/python}"
[ -x "$PYTHON" ] || PYTHON="$(cd "$ROOT/.." && pwd)/.venv/bin/python"
[ -x "$PYTHON" ] || PYTHON=python3
URL="http://localhost:$PORT"
STARTED_SERVE=0

if ! curl -s -o /dev/null "$URL"; then
  command -v dx >/dev/null 2>&1 || {
    echo "gui_drive: 'dx' not on PATH and nothing serving $URL" >&2; exit 2; }
  echo "gui_drive: starting dx serve (web) on :$PORT ..."
  ( cd "$ROOT/jas_dioxus" \
    && nohup dx serve --platform web --port "$PORT" \
       >"/tmp/guieyes-dx-$PORT.log" 2>&1 & )
  STARTED_SERVE=1
  printf "gui_drive: waiting for %s " "$URL"
  i=0
  while [ "$i" -lt 300 ]; do
    curl -s -o /dev/null "$URL" && break
    printf "."; sleep 1; i=$((i + 1))
  done
  echo
  curl -s -o /dev/null "$URL" || {
    echo "gui_drive: dev server never came up; see /tmp/guieyes-dx-$PORT.log" >&2
    exit 2; }
fi

cleanup() {
  if [ "$STARTED_SERVE" = 1 ] && [ -z "$KEEP_SERVE" ]; then
    pkill -f "dx serve --platform web --port $PORT" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "gui_drive: $("$PYTHON" -V 2>&1) driving $URL via CDP :$CDP_PORT"
exec "$PYTHON" "$ROOT/scripts/gui_checks.py" \
  --serve-port "$PORT" --cdp-port "$CDP_PORT" "$@"
