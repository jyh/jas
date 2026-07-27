# CLOUD_SMOKE_REPORT — first crossing

**Verdict up front, because it changes how to read everything below: this run did NOT execute on
a clean Linux machine.** It executed on the maintainer's own macOS workstation (`jaoquin.local`),
inside a git worktree of the maintainer's existing local clone, sharing the maintainer's home
directory, shell PATH, `~/.cargo`, and a pre-existing Python virtualenv. Every toolchain, every
dependency, and every cache was already present before this session began. See "THE HONEST
HEADLINE" below before trusting any pass count in this report as evidence of portability.

## 1. Where this ran

- HEAD SHA: `ff3e62aa3f68a529e24e3451133e1cbd18b8edb3`
  ("Merge arc2-prototypes: the cardinality law, and the corpus that can see")
- Branch: `worktree-agent-a840737c23898c92c` (a git-worktree checkout under
  `jas/.claude/worktrees/agent-a840737c23898c92c`, sharing the parent repo's object store)
- `origin/main` on GitHub is **identical to this HEAD** (`git ls-remote --heads origin` returned
  `ff3e62aa3f68a529e24e3451133e1cbd18b8edb3 refs/heads/main`) — the arc2-prototypes merge this
  session was meant to smoke-test is already on `main` upstream.
- `uname -a`: `Darwin jaoquin.local 25.5.0 Darwin Kernel Version 25.5.0: Tue Jun 9 22:28:34 PDT
  2026; root:xnu-12377.121.10~1/RELEASE_ARM64_T6050 arm64` — **this is macOS (Darwin/arm64), not
  Linux.**
- `sw_vers`: macOS 26.5.2, build 25F84.
- Disk: 926Gi volume, 158Gi free.

### Toolchains found ALREADY present (nothing in this list was installed by this session)
- `rustc 1.94.1 (e408947bf 2026-03-25)`, `cargo 1.94.1 (29ea6fb6a 2026-03-24)` at
  `/Users/jyh/.cargo/bin` (rustup-managed, maintainer's own toolchain).
- `python3 --version` → `Python 3.11.15`, resolved via a **pre-existing virtualenv** at
  `/Users/jyh/projects/claude/jas/.venv` (created 2026-05-20, per file mtimes) — not a venv
  local to this worktree; `PATH` simply puts it first.
- `swift --version` → **Apple Swift 6.3.3 is present** (Xcode toolchain). The mission prompt
  explicitly predicted "expect swift to be absent; that is expected, not a failure" — that
  prediction was written for a Linux box. On this actual (macOS) machine Swift is installed, but
  the mission's Step 3/4 command list still does not invoke the Swift test suite, so the Swift
  lane still did not run in this report (see §4).
- `~/.cargo/registry` last touched 2026-05-20 (cache dir, index, src) — over two months old,
  confirming dependency resolution used a warm local cache, not a fresh fetch.
- Also present on `PATH`, unrelated to this mission but further evidence of a long-lived personal
  dev machine, not a scratch container: `.elan` (Lean), `opam 5.4.1` (OCaml), `anaconda3`,
  `google-cloud-sdk`.

## 2. Step 2 — "install what is missing"

```
$ time pip3 install -r requirements.txt
Requirement already satisfied: numpy ... PySide6 ... pytest ... absl-py ... pyyaml ...
msgpack ... flask ... reportlab ... (all already satisfied, including PySide6/Qt)
real 0m0.245s
```
Exit status 0. **Zero packages were installed** — every entry in `requirements.txt`, including
PySide6 (Qt, needed only by the frozen Python app), was already satisfied in the pre-existing
venv. This step therefore tested nothing about installability; it only confirmed the venv's prior
state. No firewall host was ever contacted, so none is available to report — see §4 for why this
makes the "record the missing firewall host" ask of the mission moot in this environment.

## 3. Step 3 — the referee suites, timed

### `cargo test --lib` (jas_dioxus, the Rust port's suite)
```
$ cd jas_dioxus && time cargo test --lib
test result: ok. 2633 passed; 0 failed; 16 ignored; 0 measured; 0 filtered out; finished in 0.24s
real 0m28.002s   user 1m16.957s   sys 0m11.994s
```
Exit status 0. `jas_dioxus/target/` did not exist before this run (created fresh, timestamped
today) — so this specific build compiled from scratch, but it drew every crate from the
two-month-old warm `~/.cargo/registry` cache rather than downloading over the network. 28s
wall-clock for a from-scratch compile + 2633 tests is plausible only because dependency
resolution and download were skipped entirely.

### `pytest workspace_interpreter/` (the live reference interpreter)
```
$ time python3 -m pytest workspace_interpreter/ -q
1248 passed in 3.69s
real 0m3.845s
```
Exit status 0 (pytest quiet mode, all dots, no skips visible in the summary line).

### `cross_language_algorithms.py --lang rust` (the corpus runner — READ THIS CAREFULLY)
```
$ time python3 scripts/cross_language_algorithms.py --lang rust
Cross-language algorithms: 410 passed, 0 failed, 0 errors (20 algorithms × 0 comparisons)
real 0m13.430s
```
Exit status 0.

**THE COMPARISON COUNT: this run performed 0 (zero) cross-language comparisons and 410 oracle
checks across 20 algorithm families.** The `--lang rust` invocation is a single-lane run; with
only one language present there is no second implementation to diff against, so the gate's actual
comparison logic never fires. What ran instead is an oracle check: does the Rust port still
reproduce the pinned goldens in `test_fixtures/`? That is a real and useful check — it is exactly
what would catch fixture corruption or a golden that only reproduces on one machine (see §4.2) —
but it is **not** the corpus's headline claim (Rust vs. Swift agreement), and this report does
**not** claim the corpus "passed" in that sense. The scale differs from the number quoted in the
mission prompt (44 passed / 1 algorithm × 0 comparisons) only because that example was apparently
for one filtered family (`--algo <name>`); this run used no `--algo` filter and so covered all 20
algorithm families in the manifest, giving 410 passed / 20 algorithms × 0 comparisons. The
zero-comparisons finding is identical in kind — it is what "only one language present" always
produces, at any family count.

### `check_corpus_manifest.py`
```
$ time python3 scripts/check_corpus_manifest.py
[... 9 declared COVERAGE GAP blocks printed, each with evidence/blocks/unblock, e.g.
 text-index-unit, element-bounds-untransformed, flatten-wrong-flattener, flatten-no-arcs,
 fit-curve-first-pass-only, codec-optional-fields-unset, codec-no-control-chars,
 identity-view-only, panel-text-width-scalar-count-only ...]
corpus-completeness gate: OK (25 families, 421 files, 0 known-gap warning(s),
9 declared coverage gap(s) printed above)
real 0m0.432s
```
Exit status 0. This is a real gate that passed; the 9 "coverage gap" blocks are declared/known
limitations the manifest tracks and prints on every run (not new failures introduced by this
session) — this is the corpus's own self-reporting mechanism working as designed, not a defect
this run discovered.

### `check_preservation_corpus.py` — **DOES NOT EXIST AT THIS COMMIT**
```
$ ls scripts/check_preservation_corpus.py
ls: scripts/check_preservation_corpus.py: No such file or directory
```
This command from the mission's Step 3 script list **could not be run** — the file is absent from
`scripts/` at HEAD (`ff3e62aa`). I did not fabricate a result for it. Git archaeology: the file
does exist in this repository's object store, introduced by commits `a893301b` / `ec59eba0`
("PRESERVE: the preservation corpus family + its anti-vacuity validator") and extended by
`1a52d47c` ("PRESERVE: gesture-driven vectors reach the blob arms"), but **none of those commits
are ancestors of this HEAD** — `git merge-base --is-ancestor 1a52d47c HEAD` returns false. They
live only on a sibling branch (`worktree-wf_6acf2c78-530-3`, itself dated the same day, minutes
before this session started) that has not been merged into `arc2-prototypes` / `main`. This is not
a broken install or a missing dependency; it is unmerged work on another branch that the mission
prompt's author apparently expected to already be integrated. I am reporting the absence rather
than substituting a different script or skipping the line silently.

## 4. Step 4 — the clean-machine questions

**1. Does everything build and run from nothing?**
**No, and this run cannot answer that question at all** — it never tested it. Every toolchain
(rustc/cargo via rustup, the Python venv with every `requirements.txt` package pre-satisfied,
Swift/Xcode) was already installed on this machine before the session started, and every cache
that would normally require network access (`~/.cargo/registry`, the venv's site-packages) was
already warm, dated weeks to months before this run. `git ls-remote origin` succeeded in 0.35s
with no authentication friction, confirming this machine has ordinary, unrestricted internet
access and existing GitHub credentials — the opposite of a sandboxed clean-room. The only things
observed "from nothing" in this session were: the `jas_dioxus/target/` build directory (compiled
fresh, but from warm crate caches) and this worktree's checkout itself. **This session is not
evidence the repo is replayable on a machine that has never seen it; it is evidence the repo
still works on the maintainer's own long-lived development machine.** A genuine clean-machine
test would need a fresh container/VM with no `~/.cargo`, no pre-built venv, and no prior
`git clone` of this repo, and ideally would be Linux as the mission intended (this host is
Darwin/arm64).

**2. Do the pinned goldens reproduce on hardware that has never seen this repo?**
**Cannot be determined from this run.** The 410 oracle passes in `cross_language_algorithms.py
--lang rust` and the 1248 passes in `pytest workspace_interpreter/` show the goldens reproduce on
*this* machine — which is the machine the goldens were almost certainly authored and pinned on
(same user, same repo checkout lineage, same warm caches). That is close to the weakest possible
evidence for golden portability: it cannot rule out a golden that silently encodes something
machine-specific (float formatting, path separators, locale, endianness assumptions). No inference
about cross-machine reproduction should be drawn from this report.

**3. Did anything pass vacuously?**
- The `pip3 install` step "passed" (exit 0) while doing zero installation work — worth flagging
  even though it's not a test suite, because it means Step 2 validated nothing about
  installability.
- `cross_language_algorithms.py --lang rust`: not vacuous in the sense of a no-op, but its 410
  "passed" count is real work (oracle replay) doing a *different and narrower* job than the
  headline cross-language gate it stands in for — see §3, flagged there in detail per the
  mission's explicit warning.
- `check_corpus_manifest.py`'s "9 declared coverage gap(s)" are not a vacuous pass either — they
  are printed diagnostics about known-uncovered surface, distinct from the gate's own pass/fail
  (which is 0/0 known-gap warnings, exit 0). Worth noting so the two concepts (declared gaps vs.
  gate failures) aren't conflated in this report.
- No suite in this run reported a suspiciously low count relative to its own history that I could
  detect (no baseline from a genuinely clean run was available to compare against, per Q1/Q2).
- Swift's suite did not run at all — not vacuously skipped by a script, just never invoked, per
  the mission's own command list (see below).

**4. Timing (all cold in the sense of "first run in this worktree," warm in the sense of caches)**
| step | wall time | exit |
|---|---|---|
| `pip3 install -r requirements.txt` | 0.245s | 0 |
| `cargo test --lib` (jas_dioxus) | 28.002s | 0 |
| `pytest workspace_interpreter/ -q` | 3.845s | 0 |
| `cross_language_algorithms.py --lang rust` | 13.430s | 0 |
| `check_corpus_manifest.py` | 0.432s | 0 |
| `check_preservation_corpus.py` | N/A — file absent at HEAD | N/A |
| `git ls-remote --heads origin` (network probe) | 0.346s | 0 |

## Which lanes ran, which did not

- **Rust (`jas_dioxus`)**: ran — `cargo test --lib`, full pass.
- **Python reference (`workspace_interpreter/`)**: ran — full pass.
- **Cross-language corpus, Rust lane**: ran, oracle-only (0 comparisons, see §3).
- **Swift (`JasSwift`)**: did **not** run. Swift itself is present on this machine (unlike the
  Linux box the mission assumed), but the mission's Step 3 command list never invokes a Swift
  test target, so this report has no data on it either way. This is worth flagging back to
  whoever dispatched this mission: on an actual Linux box Swift's absence forces this; on this
  (macOS) box it was simply never asked for.
- **OCaml (`jas_ocaml`) / Python Qt app (`jas`)**: frozen ports, not in the mission's command
  list, not run.
- **Flask (`jas_flask`)**: non-gating reference renderer, not in the mission's command list, not
  run.

## Firewall / network findings

None. No install step attempted a network fetch (all dependencies pre-satisfied), and the one
explicit network probe this report ran (`git ls-remote --heads origin`) succeeded immediately.
There is nothing to record here, and that absence is itself part of the honest headline: this
was never a network-restricted environment.

## Working tree hygiene

`git status --short` and `git diff --stat` were both empty after every step above. The only
filesystem change from any command in this session was the creation of `jas_dioxus/target/`
(gitignored via `jas_dioxus/.gitignore` → `/target/`), which is not tracked and was not committed.

## VERDICT

This run is a valid, useful **regression smoke test on the maintainer's own machine**: the Rust
suite (2633 tests), the Python reference interpreter (1248 tests), the corpus-manifest
completeness gate, and an oracle replay of 410 pinned algorithm vectors all pass cleanly at
`ff3e62aa` (= current `origin/main`), and the working tree stayed clean throughout. That is real
signal that nothing in the arc2-prototypes merge broke these gates *as measured here*.

It is **not** evidence that the repo is replayable "from nothing" on Linux, or on any machine that
hasn't already built this project. Every toolchain and cache pre-existed; the host is macOS, not
Linux; no network access was ever tested under restriction; and the mission's designated
`check_preservation_corpus.py` gate could not run because the file lives only on an unmerged
sibling branch. To make this referee actually strong at answering "does this replay from zero,"
the dispatch would need to run inside a genuinely fresh Linux container/VM with no pre-seeded
`~/.cargo`, no pre-built Python venv, and no prior clone of this repository — and the
`check_preservation_corpus.py` gate would need to actually be merged to the branch being tested
before a mission prompt assumes its presence.
