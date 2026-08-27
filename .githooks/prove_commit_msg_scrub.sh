#!/bin/sh
# Prove the commit-msg scrub. RED FIRST: the phase that asserts the hook works
# is preceded by one proving the same input fails without it.
#
# Every phase that inspects a commit message FIRST asserts a commit was really
# created. Without that, a hook that aborts every commit scores green on the
# "forbidden shape absent" check -- there is no message to contain it. That is
# not a hypothetical: the first run of this script reported exactly that.
set -u
SCRATCH="$(cd "$(dirname "$0")" && pwd)"
# The gate lives in the repo, not beside this script. It used to be addressed as
# "$SCRATCH/check_commit_trailers.py", which resolved to nothing once this script
# sat in a hooks directory: `cp` failed, the lab got no gate, and the hook then
# FAILED CLOSED on every phase. Five phases red, one green for the wrong reason,
# and none of it about the hook. Resolve it from the repo root instead.
ROOT="$(git -C "$SCRATCH" rev-parse --show-toplevel)"
GATE="$ROOT/scripts/check_commit_trailers.py"
# The lab is scratch and must not be written inside a TRACKED directory, or a
# failed run leaves debris in the working tree that looks like source.
LAB="$(mktemp -d)/hooklab"
HOOK="$SCRATCH/commit_msg_scrub.py"
WRAP="$SCRATCH/commit-msg"
FAILURES=0

fail() { printf 'FAIL: %s\n' "$*"; FAILURES=$((FAILURES+1)); }
ok()   { printf 'ok  : %s\n' "$*"; }

# GUARDED: an unset or empty LAB would make this `rm -rf` mean something else
# entirely. Require an absolute path with a leaf before removing anything.
case "$LAB" in
  /*/*) [ -d "$LAB" ] && rm -rf -- "$LAB" ;;
  *) echo "refusing to remove LAB='$LAB'" >&2; exit 2 ;;
esac
mkdir -p "$LAB/scripts"
cd "$LAB" || exit 1
git init -q . 2>/dev/null
git config user.email "test@example.com"
git config user.name "Test"
git config commit.gpgsign false
git config core.autocrlf false
cp "$GATE" scripts/check_commit_trailers.py
echo seed > seed.txt; git add -A 2>/dev/null; git commit -q -m "seed" 2>/dev/null
BASE=$(git rev-parse HEAD)

MSG_DIRTY="Subject line

Body of the commit.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_EXAMPLEnotArealSession
"
MSG_CLEAN="Subject line

Body with no trailer at all.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
"

# committed <phase> : make a commit and assert it actually happened
committed() {
  _tag="$1"; _msg="$2"; shift 2
  echo "$_tag" >> seed.txt; git add -A 2>/dev/null
  # Always through a real `git commit`. Invoking the hook directly cannot see
  # anything git does around it -- cleanup mode, truncation, exit plumbing --
  # which is exactly how the mac seat's 13-phase proof stayed green over a leak.
  printf '%s' "$_msg" | git commit -q -F - "$@" 2>/dev/null
  if [ "$(git rev-parse HEAD)" = "$BASE" ]; then
    return 1
  fi
  return 0
}

# ---- PHASE 1 (RED): without the hook, the trailer survives and the gate reds
if ! committed a "$MSG_DIRTY"; then
  fail "PHASE 1: no commit was created even without a hook -- lab is broken"
elif python "$GATE" --range "$BASE..HEAD" >/dev/null 2>&1; then
  fail "PHASE 1: gate PASSED on an unscrubbed commit -- this test proves nothing"
else
  ok "PHASE 1 (RED): no hook -> trailer survives, gate reds"
fi
git reset -q --hard "$BASE"

# ---- install the hook
mkdir -p .git/hooks
cp "$HOOK" .git/hooks/commit_msg_scrub.py
cp "$WRAP" .git/hooks/commit-msg
chmod +x .git/hooks/commit-msg

# ---- PHASE 2 (GREEN): same input, hook present -> stripped, gate passes
if ! committed a "$MSG_DIRTY"; then
  fail "PHASE 2: the hook ABORTED the commit -- it must scrub, not refuse"
else
  if python "$GATE" --range "$BASE..HEAD" >/dev/null 2>&1; then
    ok "PHASE 2 (GREEN): hook present -> gate passes on the same input"
  else
    fail "PHASE 2: gate still reds with the hook installed"
  fi

  # ---- PHASE 3: Co-Authored-By preserved
  if git log -1 --format='%B' | grep -q '^Co-Authored-By: Claude Opus 5'; then
    ok "PHASE 3: Co-Authored-By preserved verbatim"
  else
    fail "PHASE 3: Co-Authored-By was destroyed"
  fi

  # ---- PHASE 4: both forbidden shapes really gone
  if git log -1 --format='%B' | grep -qi 'claude\.ai\|Claude-Session'; then
    fail "PHASE 4: forbidden shape still present in the stored message"
  else
    ok "PHASE 4: both forbidden shapes absent from a message that EXISTS"
  fi

  # ---- PHASE 5: the surviving body is otherwise untouched
  if git log -1 --format='%B' | grep -q '^Body of the commit\.$' \
     && [ "$(git log -1 --format='%s')" = "Subject line" ]; then
    ok "PHASE 5: subject and body survived the strip intact"
  else
    fail "PHASE 5: the hook damaged the surrounding message"
  fi
fi
git reset -q --hard "$BASE"

# ---- PHASE 6: a clean message passes through unharmed
if ! committed b "$MSG_CLEAN"; then
  fail "PHASE 6: the hook rejected a message that has nothing wrong with it"
elif git log -1 --format='%B' | grep -q '^Co-Authored-By: Claude Opus 5' \
     && git log -1 --format='%B' | grep -q '^Body with no trailer at all\.$'; then
  ok "PHASE 6: a message with no trailer is passed through unchanged"
else
  fail "PHASE 6: clean message was altered"
fi
git reset -q --hard "$BASE"

# ---- PHASE 7 (FAIL CLOSED): gate nowhere -- not in the tree, not in a ref
mv scripts/check_commit_trailers.py scripts/_hidden.py
if committed c "$MSG_DIRTY"; then
  fail "PHASE 7: commit ACCEPTED with no gate to derive patterns from"
else
  ok "PHASE 7 (FAIL CLOSED): gate nowhere -> commit refused, not passed through"
fi
mv scripts/_hidden.py scripts/check_commit_trailers.py
git reset -q --hard "$BASE"

# ---- PHASE 8: gate absent from the WORKTREE but reachable in a ref.
# This is the live case on the windows branch today: it was cut before the
# gate landed on main. The hook must scrub, not refuse.
git branch -f main "$BASE" 2>/dev/null
git rm -q --cached scripts/check_commit_trailers.py 2>/dev/null
rm -f scripts/check_commit_trailers.py
if ! committed d "$MSG_DIRTY"; then
  fail "PHASE 8: hook refused although the gate was reachable in refs/heads/main"
elif git log -1 --format='%B' | grep -qi 'claude\.ai\|Claude-Session'; then
  fail "PHASE 8: hook ran off the ref but did not scrub"
elif git log -1 --format='%B' | grep -q '^Co-Authored-By: Claude Opus 5'; then
  ok "PHASE 8: gate read from a ref -> scrubbed correctly, attribution kept"
else
  fail "PHASE 8: scrubbed via ref but attribution was lost"
fi
git reset -q --hard "$BASE"

# ---- PHASE 9 (STUBB'S LEAK): a message quoting git's scissors banner with the
# forbidden trailer BELOW it. His hook carved out everything under the scissors
# line, on the assumption git discards it -- true only under `-v` or
# cleanup=scissors, and false for -F, -m and the default editor cleanup. His
# leaked a live trailer into history, silently, exit 0.
MSG_SCISSORS="Subject line

Body that QUOTES the banner, which is what the hook-installing commit does:

# ------------------------ >8 ------------------------
Everything below here would be discarded under -v, and KEPT under -F.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_EXAMPLEnotArealSession
"
if ! committed e "$MSG_SCISSORS"; then
  fail "PHASE 9: the hook refused a message quoting the scissors banner"
elif git log -1 --format='%B' | grep -qi 'claude\.ai\|Claude-Session'; then
  fail "PHASE 9 LEAK: a trailer below a quoted scissors line reached history"
elif git log -1 --format='%B' | grep -q '^Co-Authored-By: Claude Opus 5'; then
  ok "PHASE 9: a trailer below a quoted scissors banner is still scrubbed"
else
  fail "PHASE 9: scrubbed, but attribution was lost"
fi
git reset -q --hard "$BASE"

# ---- PHASE 10: the same message under cleanup=scissors, where git DOES
# truncate. Both cleanup modes are separate cases, per Stubb's finding.
if ! committed f "$MSG_SCISSORS" --cleanup=scissors; then
  fail "PHASE 10: the hook refused under cleanup=scissors"
elif git log -1 --format='%B' | grep -qi 'claude\.ai\|Claude-Session'; then
  fail "PHASE 10 LEAK: trailer survived under cleanup=scissors"
else
  ok "PHASE 10: no leak under cleanup=scissors either"
fi
git reset -q --hard "$BASE"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PROOF COMPLETE: 10/10 phases, red proven before green, every message check"
  echo "gated on a real commit, both git cleanup modes exercised through git itself."
  exit 0
fi
echo "PROOF FAILED: $FAILURES phase(s)."
exit 1
