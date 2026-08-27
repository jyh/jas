#!/bin/sh
# check_githooks_liveness.sh — the tracked hooks are PRESENT; are they LIVE?
#
# WHY THIS EXISTS
# ---------------
# `core.hooksPath` pointing at a tracked directory is not the same as hooks that
# run, and the two ways it fails are both SILENT and both platform-asymmetric.
# Measured on a Windows seat (git 2.55.0.windows.3, 2026-08-26):
#
#   * A hook committed 100644 RUNS on Windows regardless of mode, and
#     `core.filemode` is false there, so a `chmod +x` never reaches the index.
#     The same file is expected to be INERT on macOS/Linux, where git requires
#     the executable bit. So a hook authored on Windows can look correct on the
#     box that wrote it and do nothing at all for everyone else.
#   * `python3` on that seat is a Microsoft Store app-execution-alias STUB: it is
#     on PATH, it answers `command -v`, and it fails when run (`--version` exits
#     49 with no version, while `python` reports 3.12.10). A hook that shells out
#     to it does not merely fail to fire — `git commit` exits 1 with HEAD
#     unmoved, which locks that seat out of committing entirely.
#
# Neither failure announces itself, and a hook that does nothing looks exactly
# like a hook that worked. So the shape is asserted here, in CI, on every push.
#
# WHAT IT DOES NOT DO: it cannot tell whether YOUR clone ran the fresh-clone step
# (`git config core.hooksPath .githooks`), because that setting is local and
# untracked — CI's own clone never has it. `--clone` asks for that check
# explicitly; it is for a developer's working copy, not for CI.
#
# usage:
#   check_githooks_liveness.sh              repo shape (CI-safe)
#   check_githooks_liveness.sh --clone      + this clone actually ran the step
#   check_githooks_liveness.sh --self-test  prove the gate before believing it
set -u

HOOKDIR=.githooks

# The git hook names that are ENTRY POINTS. Anything else under .githooks/ is a
# module the entry point invokes, and is deliberately NOT required to be
# executable — see commit_msg_scrub.py, kept 100644 so that nobody runs it
# directly and meets its `#!/usr/bin/env python3` line.
ENTRY_NAMES="applypatch-msg pre-applypatch post-applypatch pre-commit
pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase
post-checkout post-merge pre-push pre-receive update post-receive post-update
push-to-checkout pre-auto-gc post-rewrite sendemail-validate"

is_entry() {
  for n in $ENTRY_NAMES; do
    [ "$1" = "$n" ] && return 0
  done
  return 1
}

check_repo() {
  repo="$1"
  holes=0
  entries=0
  cd "$repo" || { echo "FAIL: no such dir: $repo" >&2; return 2; }
  files=$(git ls-files "$HOOKDIR/*" 2>/dev/null)

  for f in $files; do
    mode=$(git ls-files -s "$f" | awk '{print $1}')
    base=${f##*/}

    if is_entry "$base"; then
      entries=$((entries + 1))

      # (A) The mode is invisible on the platform most likely to create it.
      if [ "$mode" != "100755" ]; then
        echo "FAIL $f is $mode — runs on Windows, INERT on macOS/Linux."
        echo "     fix: git update-index --chmod=+x $f"
        holes=$((holes + 1))
      fi

      # (B) A bare python3 with no by-execution fallback.
      if grep -q 'python3' "$f" 2>/dev/null && ! grep -q 'for c in python3' "$f" 2>/dev/null; then
        echo "FAIL $f names python3 with no by-execution fallback."
        echo "     On Windows python3 is a Store alias stub: it resolves, fails when"
        echo "     run, and the commit is REFUSED. Choose the interpreter by EXECUTION"
        echo "     — try python3, python, py in turn and take the first that runs."
        holes=$((holes + 1))
      fi
    fi

    # (C) Any EXECUTABLE file whose shebang names python3 — the same stub, reached
    #     by running the file rather than by a line inside it.
    if [ "$mode" = "100755" ] && head -1 "$f" 2>/dev/null | grep -q '^#!.*python3'; then
      echo "FAIL $f is executable and its shebang names python3 (the Store alias stub)."
      echo "     Either drop the exec bit and let a hook invoke it by execution-chosen"
      echo "     interpreter, or select the interpreter inside the file."
      holes=$((holes + 1))
    fi
  done

  # (D) VACUITY. A gate that inspected nothing must never report success. This
  #     repo has already paid for that failure once, in a suite whose passing arm
  #     asserted an ABSENCE and passed because there was no output at all.
  if [ "$entries" -eq 0 ]; then
    echo "FAIL no hook ENTRY POINT is tracked under $HOOKDIR/ — this gate inspected nothing."
    holes=$((holes + 1))
  fi

  if [ "${WANT_CLONE:-0}" = 1 ]; then
    path=$(git config --get core.hooksPath 2>/dev/null || true)
    if [ "$path" != "$HOOKDIR" ]; then
      echo "FAIL this clone has core.hooksPath='${path:-unset}' — IT RUNS NO HOOKS."
      echo "     fix (the fresh-clone step): git config core.hooksPath $HOOKDIR"
      holes=$((holes + 1))
    fi
  fi

  if [ "$holes" -eq 0 ]; then
    echo "OK   $HOOKDIR: $entries entry point(s), all 100755, no bare python3"
    return 0
  fi
  return 1
}

# ------------------------------------------------------------------ self-test
selftest() {
  me=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
  tmp=$(mktemp -d) || { echo "self-test: mktemp failed" >&2; exit 2; }

  # GUARDED cleanup: only ever remove the directory mktemp just handed back, and
  # only if it still looks like an absolute path with a leaf. An unset or empty
  # variable here would make `rm -rf` mean something else entirely.
  cleanup() {
    case "${tmp:-}" in
      /*/*) [ -d "$tmp" ] && rm -rf -- "$tmp" ;;
      *) echo "self-test: refusing to remove '${tmp:-<empty>}'" >&2 ;;
    esac
  }
  trap cleanup EXIT

  good='#!/bin/sh
PY=
for c in python3 python py; do
  if "$c" -c "" >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -z "$PY" ] && exit 1
exit 0
'
  bare='#!/bin/sh
python3 scripts/whatever.py "$@"
'
  sheb='#!/usr/bin/env python3
import sys
sys.exit(0)
'

  mkfixture() {
    d="$tmp/$1"
    mkdir -p "$d/.githooks"
    git -C "$d" init -q
    git -C "$d" config user.email fixture@example.com
    git -C "$d" config user.name fixture
    # fixtures carry no .gitattributes, so pin eol here rather than inherit the
    # developer's core.autocrlf and have the arms report on a different file
    git -C "$d" config core.autocrlf false
    printf '%s' "$2" > "$d/.githooks/commit-msg"
    git -C "$d" add .githooks/commit-msg
    git -C "$d" update-index --chmod="$3" .githooks/commit-msg
    git -C "$d" commit -qm fixture
  }

  mkfixture good     "$good" +x
  mkfixture bad-mode "$good" -x
  mkfixture bad-bare "$bare" +x

  # an executable module whose shebang names python3, beside a correct hook
  mkfixture bad-sheb "$good" +x
  printf '%s' "$sheb" > "$tmp/bad-sheb/.githooks/scrub.py"
  git -C "$tmp/bad-sheb" add .githooks/scrub.py
  git -C "$tmp/bad-sheb" update-index --chmod=+x .githooks/scrub.py
  git -C "$tmp/bad-sheb" commit -qm "executable python3-shebang module"

  # A hooks dir with a module only and NO entry point at all.
  #
  # Built directly rather than by adding an entry point and removing it. That
  # shortcut was platform-dependent and CI caught it: `update-index --chmod=+x`
  # changes the INDEX mode while the worktree file stays 644, so on Linux `git rm`
  # sees "local modifications" and refuses — leaving the entry point in place and
  # the arm passing for the wrong reason. Windows never noticed, because
  # core.filemode is false there and the mode difference does not exist.
  d="$tmp/vacuous"
  mkdir -p "$d/.githooks"
  git -C "$d" init -q
  git -C "$d" config user.email fixture@example.com
  git -C "$d" config user.name fixture
  git -C "$d" config core.autocrlf false
  printf '%s' "$good" > "$d/.githooks/helper.sh"
  git -C "$d" add .githooks/helper.sh
  git -C "$d" commit -qm "module only, no entry point"

  fail=0
  arm() {
    sh "$me" "$tmp/$1" > "$tmp/$1.out" 2>&1
    rc=$?
    if [ "$rc" -eq "$2" ]; then
      printf '  ok   %-9s exit=%s\n' "$1" "$rc"
    else
      printf '  FAIL %-9s exit=%s expected=%s :: %s\n' "$1" "$rc" "$2" "$(head -1 "$tmp/$1.out")"
      fail=1
    fi
  }

  echo "self-test: every arm states its expected exit BEFORE it runs"
  arm good     0
  arm bad-mode 1
  arm bad-bare 1
  arm bad-sheb 1
  arm vacuous  1

  if [ "$fail" -eq 0 ]; then
    echo "self-test: PASS — a clean hooks dir passes; four distinct holes each fail"
    return 0
  fi
  echo "self-test: FAILED"
  return 1
}

WANT_CLONE=0
target=.
case "${1:-}" in
  --self-test) selftest; exit $? ;;
  --clone) WANT_CLONE=1; target="${2:-.}" ;;
  "") target=. ;;
  *) target="$1" ;;
esac
check_repo "$target"
