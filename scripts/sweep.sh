#!/usr/bin/env bash
# SWEEP — run every gate in scripts/, by GLOBBING THE FILESYSTEM.
#
# It globs rather than naming, so a gate added tomorrow is swept tomorrow
# without anyone remembering to add it here.
#
# WHY THIS FILE EXISTS. The mac seat's habit was `for f in scripts/check_*.py`,
# typed fresh each time. That sweep answered "are the PYTHON gates green?" while
# its author believed he was asking "are the gates green?" — and the tree also
# carries EIGHT `check_*.sh`. `check_intent_map.sh` was RED on origin/main from
# EMPTYARTBOARDS until INTENTMAP paid it, across a fortnight of the mac seat
# reporting "N gates, all green" every single day. Found by the windows seat,
# 2026-08-05, on the first run of a sweep that globbed instead of listing.
#
# It is the INDEXBLIND defect one directory over: a subject list that silently
# answers a narrower question than the one being asked. Both sweeps were right
# about the question they actually asked, which is what makes the shape so hard
# to see from inside it.
#
# Usage:  ./scripts/sweep.sh            run every gate
#         ./scripts/sweep.sh --self-test  prove it can go red
set -u
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--self-test" ]; then
    # PROVE THE FAILURE FIRST (ratified 2026-08-05): a sweep that cannot be
    # shown to notice a red gate is not evidence that the gates are green.
    tmp="$(mktemp "scripts/check_zz_selftest_XXXX.sh")"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp"
    chmod +x "$tmp"
    if out="$("$0" 2>&1)"; then
        rm -f "$tmp"
        echo "sweep --self-test: FAIL — a deliberately red gate was not noticed"
        exit 1
    fi
    rm -f "$tmp"
    case "$out" in
        *"$(basename "$tmp")"*) ;;
        *) echo "sweep --self-test: FAIL — went red but did not name the culprit"
           echo "$out"; exit 1 ;;
    esac
    echo "sweep --self-test: OK (a planted red gate is caught AND named)"
    exit 0
fi

# INTERPRETER SELECTION, BY EXECUTION. The first draft of this file said
# `python3` and inherited whatever PATH gave it. Run from an interactive shell
# with the repo venv active that is `.venv/bin/python3`; run as a script it is
# `/opt/homebrew/bin/python3`, which has no PyYAML — so every gate importing
# yaml died on import and this sweep called it RED. Four false reds on its
# second run, against a tree whose gates were all green.
#
# That is the windows seat's Store-stub finding wearing the other face: there,
# an interpreter that ANSWERS and cannot run; here, an interpreter that runs and
# is the wrong one. Both are selection by the wrong question. So: ask by
# EXECUTION, and ask the question that matters — can this interpreter import
# what the gates import?
pick_python() {
    for c in "./.venv/bin/python3" "python3" "python"; do
        if "$c" -c "import yaml, json, re" >/dev/null 2>&1; then
            printf '%s' "$c"
            return 0
        fi
    done
    return 1
}

if ! PY="$(pick_python)"; then
    # FAIL CLOSED. A sweep that cannot run the gates must never report on them;
    # "no interpreter" is not "no problems".
    echo "sweep: FAIL — no python3 that can import the gates' own dependencies"
    echo "       (tried ./.venv/bin/python3, python3, python)"
    exit 1
fi

fail=0
total=0
for f in scripts/check_*.py scripts/check_*.sh; do
    [ -e "$f" ] || continue
    total=$((total + 1))
    case "$f" in
        *.py) runner=("$PY" "$f") ;;
        *)    runner=(bash "$f") ;;
    esac
    if ! "${runner[@]}" >/dev/null 2>&1; then
        fail=$((fail + 1))
        echo "RED  $f"
    fi
done

# ANTI-VACUITY: a sweep that found no gates must not report success. The empty
# scan is the failure this house makes fatal everywhere else.
if [ "$total" -eq 0 ]; then
    echo "sweep: FAIL — found ZERO gates; the glob has drifted"
    exit 1
fi

if [ "$fail" -eq 0 ]; then
    echo "sweep: OK ($total gates, all green)"
else
    echo "sweep: FAIL ($fail of $total gates red)"
fi
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
