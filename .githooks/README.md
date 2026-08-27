# `.githooks/` — the hooks, tracked, plus the one step a repo cannot take for you

## THE FRESH-CLONE STEP

```sh
git config core.hooksPath .githooks
```

Run it once per clone. **Nothing in this repository can run it for you**, and that
is the whole reason this file exists.

## WHY IT CANNOT BE TRACKED, AND WHY THAT MATTERS MORE THAN IT SOUNDS

`core.hooksPath` is *local* configuration. It lives in `.git/config`, which is not
part of any commit, so a fresh clone starts with **no hooks and no warning**.

That is the failure this directory was created to end. Before it, the commit-msg
scrub lived in `.git/hooks/` — untracked by construction — so **a re-clone silently
lost it**, and the loss looked exactly like everything working. A hook that does
nothing and a hook that worked are indistinguishable from the outside; only the
history, later, tells them apart.

Tracking the hooks fixes the *content* problem. The *activation* problem stays
local by git's design, so it is covered two other ways:

* **`scripts/check_githooks_liveness.sh`** asserts the SHAPE in CI on every push —
  entry points present and `100755`, no bare `python3`, and a vacuity guard so a
  run that inspects nothing cannot report success.
* **`scripts/check_githooks_liveness.sh --clone`** asserts that *this* clone
  actually ran the step. CI cannot run that arm meaningfully — its own clone never
  has the setting — so it is yours to run after cloning.

## WHAT IS HERE

| file | mode | what it is |
|---|---|---|
| `commit-msg` | **100755** | entry point: strips the session trailer before it can enter history |
| `commit_msg_scrub.py` | **100644** | the module `commit-msg` invokes. Deliberately **not** executable — see below |
| `prove_commit_msg_scrub.sh` | **100755** | the 10-phase prover: red proven before green |

## TWO PLATFORM RULES THAT ARE NOT STYLE

Both were measured on a Windows seat (git 2.55.0.windows.3, 2026-08-26), and both
fail **silently** in the direction that is hardest to notice.

**1. Entry points must be committed `100755`.** Windows runs a hook whatever its
mode says, and `core.filemode` is `false` there, so a `chmod +x` never reaches the
index. A hook added from Windows is committed `100644`, works on the box that wrote
it, and is inert on macOS/Linux, where git requires the executable bit. Add hooks
with `git update-index --chmod=+x`, and let the gate check it.

**2. Never name `python3` and stop there.** On Windows `python3` is a Microsoft
Store app-execution-alias **stub**: it is on `PATH`, it answers `command -v`, and it
fails when run (`python3 --version` exits 49 with no version; `python` reports
3.12.10). A hook that shells out to it does not merely fail to fire — **`git commit`
exits 1 with `HEAD` unmoved**, locking that seat out of committing entirely.

Choose the interpreter **by execution**, as `commit-msg` does:

```sh
PY=
for c in python3 python py; do
  if "$c" -c "" >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -z "$PY" ] && { echo "REFUSED: no working python interpreter." >&2; exit 1; }
```

Note the third arm that gives you for free: when nothing runs, it **refuses loudly**
rather than failing open.

This is also why `commit_msg_scrub.py` is `100644`. It carries a
`#!/usr/bin/env python3` line for editors, and is only ever invoked as `"$PY"
commit_msg_scrub.py`. Keeping the executable bit off means nobody can run it
directly and meet that shebang on a machine where `python3` is the stub — and the
liveness gate fails any executable file whose shebang names `python3`.
