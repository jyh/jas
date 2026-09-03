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
| `pre-push` | **100755** | entry point: refuses a push whose delta carries a session trailer/URL or a path into the private record — the CI gates run *after* the objects are public |
| `prove_pre_push.sh` | **100755** | the 8-arm prover for `pre-push`: three clean pushes, three leak shapes refused, a delete allowed, and a mutation control |

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

## ⛔ ONE TRAP THE STEP INTRODUCES — `core.hooksPath` IS GLOBAL, `.githooks/` IS NOT

`core.hooksPath` lives in `.git/config`, which is **repo-global**. `.githooks/` is a
**tracked directory**, which is **branch-local**. Point the first at the second and then
check out any branch that predates this port — a branch off an older `main`, a bisect, a
`git worktree` on an old tag — and the directory simply **is not there**.

**Git does not warn. No hook runs. The commit-msg scrub does not run.** The state looks
exactly like a repository with no hooks configured, which is the same silence this whole
directory exists to end.

Found by walking into it: this port's own author branched off `main` to build an
unrelated gate, and the session trailer would have entered that commit unscrubbed. It was
caught before the commit, by checking rather than by noticing.

**While working on a branch without `.githooks/`:**

```sh
git config --unset core.hooksPath     # restores .git/hooks/, if you still have it
```

and set it again when you return. `scripts/check_githooks_liveness.sh --clone` reports
the state either way. ⇒ **The step is per-clone AND per-branch-shape.** It is not a thing
you do once and forget, until every live branch carries `.githooks/`.
