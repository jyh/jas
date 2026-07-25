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
#   ./scripts/gui_drive.sh --regress dead_sweep     # prove the sweep bites
#
# ENVIRONMENT
#   PORT=8097      dev-server port (a private default, so a running
#                  ./dxserve.sh on :8080 is never disturbed)
#   CDP_PORT=9333  DevTools port for the driver
#   PYTHON=...     interpreter override; otherwise the first of this tree's
#                  .venv, the MAIN worktree's .venv, or python3 that actually
#                  imports websocket-client is used (preflighted; exit 3 if none)
#   JAS_CHROME=... Chrome/Chromium binary (default: /Applications/Google
#                  Chrome.app/...); preflighted, exit 2 if not executable
#   KEEP_SERVE=1   leave the dev server running after the run
#
# REQUIREMENTS: Google Chrome, `dx`, and websocket-client. NO macOS
# Screen-Recording or Accessibility grant is needed — everything goes through
# the DevTools protocol — so this runs unattended and on an unprivileged host.
# It is CI-READY (gates on exit code, no display or grant needed) but no CI
# lane is wired yet.
#
# WHAT IT DOES NOT DO: judge FEEL. See GUI_EYES.md §Limits.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-8097}"
CDP_PORT="${CDP_PORT:-9333}"
URL="http://localhost:$PORT"
STARTED_SERVE=0

# Resolve a Python that actually has `websocket-client`, rather than silently
# falling through to a bare `python3` that may lack it (the old chain did, and
# a missing dep then surfaced as an opaque ImportError mid-check). Candidates,
# in order: an explicit $PYTHON; this tree's .venv; the MAIN worktree's .venv
# (so a `git worktree` checkout, whose $ROOT/.venv does not exist, still finds
# the shared venv); then python3. The MAIN root is derived from the common git
# dir so it is correct whether ROOT is the primary checkout or a linked worktree.
GITCOMMON="$(cd "$ROOT" && git rev-parse --git-common-dir 2>/dev/null || true)"
case "$GITCOMMON" in
  "") MAIN_ROOT="$ROOT" ;;
  /*) MAIN_ROOT="$(cd "$(dirname "$GITCOMMON")" && pwd)" ;;
  *)  MAIN_ROOT="$(cd "$ROOT/$(dirname "$GITCOMMON")" && pwd)" ;;
esac
PYTHON_ENV="${PYTHON:-}"   # honour an explicit override first (documented above)
PYTHON=""
for cand in "$PYTHON_ENV" "$ROOT/.venv/bin/python" \
            "$MAIN_ROOT/.venv/bin/python" python3; do
  [ -n "$cand" ] || continue
  if command -v "$cand" >/dev/null 2>&1 \
     && "$cand" -c 'import websocket' >/dev/null 2>&1; then
    PYTHON="$cand"; break
  fi
done
if [ -z "$PYTHON" ]; then
  echo "gui_drive: no Python with 'websocket-client' found. Tried:" >&2
  echo "  \$PYTHON, $ROOT/.venv/bin/python, $MAIN_ROOT/.venv/bin/python, python3" >&2
  echo "  Install it (pip install websocket-client) or point \$PYTHON at a venv"
  echo "  that has it." >&2
  exit 3
fi

# Fail fast and legibly if the browser the probe drives is missing, instead of
# a bare FileNotFoundError deep inside the first check.
CHROME_BIN="${JAS_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [ ! -x "$CHROME_BIN" ]; then
  echo "gui_drive: Chrome not executable at '$CHROME_BIN'." >&2
  echo "  Set \$JAS_CHROME to your Chrome/Chromium binary." >&2
  exit 2
fi

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
