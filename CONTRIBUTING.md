# Contributing to Jas

Thank you for your interest in Jas! This project is under active
development as a research artifact (see the paper linked in the README),
and its development process is unusual — features land in the two active
ports (Rust `jas_dioxus/`, Swift `JasSwift/`) against a shared executable
spec, gated by cross-language differential tests. The OCaml port and the
Python Qt app are frozen at the `five-port-parity` tag and do not accept
feature PRs (`POLICY.md` §1). Please read this before opening a pull
request.

## Before you contribute

**Please open an issue first** for anything beyond a trivial fix. The
parity discipline means most changes must land in both active
implementations with matching tests, and the maintainer coordinates that
process. Unsolicited PRs may sit unmerged for a while — an issue
conversation first saves everyone time.

## After you clone — one step, and nothing can run it for you

```sh
git config core.hooksPath .githooks
```

The repository's hooks are tracked in `.githooks/`, but the setting that
activates them is *local* config and cannot be committed. A clone that
skips this step has **no hooks and no warning**, which is exactly how the
commit-msg scrub was silently lost by re-cloning before the hooks were
tracked. Verify your clone with:

```sh
sh scripts/check_githooks_liveness.sh --clone
```

CI asserts the hooks' shape on every push; only you can assert that your
clone actually ran the step. See `.githooks/README.md` — in particular
the two platform rules there, which are not style: hook entry points must
be committed `100755`, and a hook must never name `python3` and stop
there (on Windows it is a Store alias stub that resolves on `PATH` and
then refuses to run, which makes `git commit` fail outright).

## Contribution terms

By submitting a contribution (pull request, patch, or otherwise), you
certify and agree to the following:

1. **Developer Certificate of Origin.** You certify the
   [Developer Certificate of Origin 1.1](https://developercertificate.org/):
   you have the right to submit the contribution under this project's
   license. Sign off each commit (`git commit -s`).

2. **Contributor license grant.** You grant the project maintainer
   (Jason Hickey) a perpetual, worldwide, non-exclusive, irrevocable,
   royalty-free license to use, reproduce, modify, distribute, and
   sublicense your contribution, **including the right to license it
   under terms other than the project's current license**. You retain
   copyright in your contribution.

Contributions that do not include DCO sign-off, or where these terms are
disclaimed, cannot be merged. For substantial contributions the
maintainer may additionally request a signed contributor license
agreement.

## Code expectations

- Match the port's existing style and module structure (see `ARCH.md`).
- Behavior changes must come with tests, and cross-port behavior changes
  must keep the differential harness green across the active ports (Rust,
  Swift) and the `workspace_interpreter/` reference suite.
- The shared YAML spec (`SCHEMA.md`, `workspace/`) is the source of
  truth for behavior; spec changes are coordinated through issues.

Thank you — and enjoy the code. The transcripts in `transcripts/` tell
the story of how it was built.
