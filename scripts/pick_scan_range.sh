#!/bin/sh
# PICK THE DELTA RANGE for the firewall and trailer gates. Prints the range on
# stdout; every diagnostic goes to stderr so `RANGE=$(pick_scan_range.sh)` is safe.
#
# ⛔ WHY THIS IS A FILE AND NOT TWO YAML BLOCKS. It was two, and they had
# DIVERGED: the 2026-08-25 hardening (a reachable before-sha, the merge-base
# degeneracy) landed in scrub.yml and NOT in test.yml's Windows lane, which
# still asked only "is BEFORE non-empty" and would die with git exit 128 on the
# rewritten-history case its sibling had already been taught. A fix that lands
# in one of two copies looks landed in review and is absent where it is needed.
#
# ⛔⛔ AND BOTH COPIES ASKED THE WRONG QUESTION. `git cat-file -e BEFORE` tests
# whether the object EXISTS. The question is whether BEFORE IS AN ANCESTOR OF
# HEAD -- "what is new since BEFORE" has no answer otherwise. They are different
# questions, and the gap between them is not exotic: split a stacked PR, force-
# push the lower branch, and the removed commits STILL EXIST because the upper
# branch holds them. cat-file says yes, the range resolves, and it is EMPTY --
# so the gate fail-closes and reds on clean content. Measured on jas 08/26 by
# doing exactly that; the previous arm's own comment ("commits that no longer
# exist") describes only the orphaning force-push, and the code implemented only
# that one. It fails CLOSED, which is the safe direction and still wrong: a
# guaranteed red on a routine branch split teaches its reader to wave past it,
# and that is how the real one gets waved past too.
#
# usage:  BEFORE=<sha-or-empty> pick_scan_range.sh
#         pick_scan_range.sh --self-test
set -u

pick() {
  # $1 = BEFORE (may be empty). Prints RANGE, or exits 1 having said why.
  _b="${1:-}"
  # ⛔ THE GUARD IS `--is-ancestor` ALONE, AND THAT IS A MUTATION-DRIVEN
  # CORRECTION TO MY OWN FIRST CUT. I wrote `cat-file -e && --is-ancestor`, and
  # the mutant that DELETES the cat-file half SURVIVED: --is-ancestor already
  # fails on a sha this checkout does not have, so cat-file gated nothing. A
  # condition that reads as a guard and changes no verdict is the shape this
  # whole lane exists to kill, and writing one into the fix took twenty minutes.
  # cat-file survives BELOW, where it does real work: telling the two force-push
  # shapes apart in the message. That use is driven by the message arms.
  if [ -n "$_b" ] \
     && [ "$_b" != "0000000000000000000000000000000000000000" ] \
     && git merge-base --is-ancestor "$_b" HEAD 2>/dev/null; then
    printf '%s..HEAD\n' "$_b"
    return 0
  fi
  if [ -n "$_b" ] && [ "$_b" != "0000000000000000000000000000000000000000" ]; then
    if git cat-file -e "$_b^{commit}" 2>/dev/null; then
      echo "BEFORE is not an ancestor of HEAD (history was rewritten under this" >&2
      echo "  branch; the removed commits survive elsewhere). Its range would be" >&2
      echo "  EMPTY, which this gate treats as fatal. Falling back." >&2
    else
      echo "BEFORE names commits not in this checkout (history rewritten)." >&2
    fi
  fi
  if git rev-parse --verify origin/main >/dev/null 2>&1; then
    _mb=$(git merge-base origin/main HEAD 2>/dev/null || true)
    if [ -n "$_mb" ] && [ "$_mb" != "$(git rev-parse HEAD)" ]; then
      echo "scanning this branch's own delta against origin/main" >&2
      printf '%s..HEAD\n' "$_mb"
      return 0
    fi
    echo "merge-base(origin/main, HEAD) IS HEAD -- the default branch was" >&2
    echo "  rewritten, so the branch-delta arm degenerates to empty." >&2
  fi
  if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    echo "DECLARED PARTIAL COVERAGE: tip commit ONLY -- a stated limit, not a" >&2
    echo "  clean scan." >&2
    printf 'HEAD~1..HEAD\n'
    return 0
  fi
  echo "FAIL: cannot determine a delta range. Refusing to guess." >&2
  return 1
}

self_test() {
  fails=0
  tmp=$(mktemp -d) || return 1
  here=$(pwd)
  # ⚠️ EVERY ARM ALSO ASSERTS ITS RANGE NAMES >= N COMMITS -- AND THIS CHECK IS
  # NOT INDEPENDENTLY DRIVEN, WHICH IS SAID HERE RATHER THAN LEFT TO LOOK LIKE
  # COVERAGE. Given that each arm already pins the exact range STRING, the count
  # is redundant: a mutant deleting it SURVIVES. It is kept for the one class the
  # string check cannot see -- an EXPECTATION that is itself wrong and empty --
  # and a two-point mutant (pick emits HEAD..HEAD, the expectation edited to
  # agree) is caught by it. But that mutant is also caught by a neighbouring arm,
  # so the isolated kill was NOT demonstrated. Belt-and-braces, declared as such.
  arm() { # $1 label  $2 BEFORE  $3 expected-range-expr  $4 min-commits
    got=$(pick "$2" 2>/dev/null) || got="<FAIL>"
    want="$3"
    if [ "$got" != "$want" ]; then
      echo "SELF-TEST FAIL: $1 -- want '$want', got '$got'" >&2
      fails=$((fails + 1))
      return
    fi
    if [ "$4" -gt 0 ]; then
      n=$(git rev-list --count "$got" 2>/dev/null || echo 0)
      if [ "$n" -lt "$4" ]; then
        echo "SELF-TEST FAIL: $1 -- range '$got' names $n commits, want >= $4" >&2
        fails=$((fails + 1))
      fi
    fi
  }

  # A repo with origin/main, a feature branch, and a rewritten lower branch.
  r="$tmp/r"
  git init -q -b main "$r"
  cd "$r" || return 1
  git config user.email s@t; git config user.name selftest; git config commit.gpgsign false
  echo a > f; git add -A; git commit -qm c1
  BASE=$(git rev-parse HEAD)
  git update-ref refs/remotes/origin/main "$BASE"
  echo b > f; git add -A; git commit -qm c2
  ONE=$(git rev-parse HEAD)
  echo c > f; git add -A; git commit -qm c3
  TWO=$(git rev-parse HEAD)

  arm "a normal push: BEFORE is an ancestor"        "$ONE"  "$ONE..HEAD"  1
  arm "empty BEFORE falls to the branch delta"      ""      "$BASE..HEAD" 2
  arm "all-zero BEFORE (new branch)"                "0000000000000000000000000000000000000000" "$BASE..HEAD" 2
  arm "unreachable BEFORE (orphaning rewrite)"      "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$BASE..HEAD" 2

  # ⛔ THE ARM THIS FILE WAS WRITTEN FOR. Keep the removed commit alive on
  # another ref -- a split stacked PR -- then rewind this branch. cat-file still
  # says the object exists; it is no longer an ancestor.
  git branch keepalive "$TWO"
  git reset -q --hard "$ONE"
  arm "force-push, removed commit ALIVE on another ref" "$TWO" "$BASE..HEAD" 1
  # and the naive test really would have chosen an empty range here
  if git cat-file -e "$TWO^{commit}" 2>/dev/null; then
    n=$(git rev-list --count "$TWO..HEAD" 2>/dev/null || echo 0)
    if [ "$n" -ne 0 ]; then
      echo "SELF-TEST FAIL: the fixture does not reproduce the empty range" >&2
      fails=$((fails + 1))
    fi
  else
    echo "SELF-TEST FAIL: fixture's removed commit should still exist" >&2
    fails=$((fails + 1))
  fi

  # ⛔ AND THE TWO FORCE-PUSH SHAPES MUST BE TOLD APART IN THE MESSAGE -- the
  # only remaining job of cat-file. Undriven, it would be a decoy in its turn.
  msg_alive=$(pick "$TWO" 2>&1 >/dev/null)
  case "$msg_alive" in
    *"not an ancestor"*) : ;;
    *) echo "SELF-TEST FAIL: a surviving-but-rewound BEFORE must say 'not an ancestor'" >&2
       fails=$((fails + 1)) ;;
  esac
  msg_dead=$(pick "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 2>&1 >/dev/null)
  case "$msg_dead" in
    *"not in this checkout"*) : ;;
    *) echo "SELF-TEST FAIL: an unreachable BEFORE must say 'not in this checkout'" >&2
       fails=$((fails + 1)) ;;
  esac
  if [ "$msg_alive" = "$msg_dead" ]; then
    echo "SELF-TEST FAIL: the two force-push shapes produce the same message" >&2
    fails=$((fails + 1))
  fi

  # merge-base degeneracy: origin/main ahead of nothing, HEAD == merge-base
  r2="$tmp/r2"; git init -q -b main "$r2"; cd "$r2" || return 1
  git config user.email s@t; git config user.name selftest; git config commit.gpgsign false
  echo a > f; git add -A; git commit -qm c1
  echo b > f; git add -A; git commit -qm c2
  git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)"
  arm "merge-base IS HEAD -> tip-only, not empty"   ""      "HEAD~1..HEAD" 1

  # nothing usable at all: one commit, no origin/main
  r3="$tmp/r3"; git init -q -b main "$r3"; cd "$r3" || return 1
  git config user.email s@t; git config user.name selftest; git config commit.gpgsign false
  echo a > f; git add -A; git commit -qm only
  arm "no BEFORE, no origin/main, no HEAD~1 -> FAIL" "" "<FAIL>" 0

  cd "$here" || return 1
  rm -rf "$tmp"
  if [ "$fails" -ne 0 ]; then
    echo "pick_scan_range SELF-TEST: $fails failure(s)" >&2
    return 1
  fi
  echo "pick_scan_range SELF-TEST: OK (10 arms; the ancestry arm keeps the removed"
  echo "  commit alive on another ref, which is the case cat-file cannot see;"
  echo "  every arm asserts its range names at least one commit)"
  return 0
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi
pick "${BEFORE:-}"
