# CLOUD REFEREE REPLAY REPORT

A referee's account of what a clean, isolated machine could and could not do with this
repository, replayed from nothing. No source file was modified. Nothing was fixed. This is a
report, not a repair.

## TL;DR VERDICT

- **This was a genuinely isolated Linux session — NOT Darwin / macOS.** `uname` reports Linux
  x86_64. The prior incident (a macOS run masquerading as cloud) did **not** recur here.
- The referee is **replayable from nothing** on Linux: Rust was pre-installed, Python deps
  installed from PyPI with one required workaround (see below), and all four referee steps ran to
  green exit.
- **The headline cross-language gate did NOT run.** With `--lang rust` there is exactly one lane,
  so the Rust-vs-Swift comparison performed **0 comparisons**. What ran instead is the oracle
  check: Rust reproduced **410** pinned goldens. Those are two different numbers and this report
  keeps them apart. **The corpus did not "pass" in the cross-language sense — it passed as an
  oracle only.**
- Swift is absent on Linux (expected). The Rust-vs-Swift lane is structurally unavailable here.

---

## STEP 1 — WHERE AM I

```
uname -a:  Linux vm 6.18.5 #1 SMP PREEMPT_DYNAMIC @0 x86_64 x86_64 x86_64 GNU/Linux
HEAD SHA:  ff3e62aa3f68a529e24e3451133e1cbd18b8edb3
branch:    claude/jas-smoke-test-i9hqul
```

**Is this Darwin/macOS? NO.** `uname` is `Linux ... x86_64`. This is an isolated Linux session,
which is what the pattern requires.

### Toolchains found vs installed

| Tool     | Status at start        | Version                                    |
|----------|------------------------|--------------------------------------------|
| rustc    | **found** (pre-installed) | `rustc 1.94.1 (e408947bf 2026-03-25)`   |
| cargo    | **found** (pre-installed) | `cargo 1.94.1 (29ea6fb6a 2026-03-24)`   |
| python3  | **found**              | `Python 3.11.15`                           |
| swift    | **ABSENT**             | `swift: command not found` (expected on Linux) |

Rust did not need installing — no `rustup`/toolchain download was performed, so no download could
have failed on that path.

---

## STEP 2 — INSTALL WHAT IS MISSING

Only Python dependencies needed installing (`pip install -r requirements.txt`).

### FINDING: plain `pip install -r requirements.txt` FAILS on this image

First attempt, verbatim error (exit 1):

```
ERROR: Cannot uninstall blinker 1.7.0, RECORD file not found. Hint: The package was installed by debian.
```

`flask` requires `blinker>=1.9.0`, but the base image ships a Debian-managed `blinker 1.7.0` with
no `RECORD` file, so pip cannot uninstall it to upgrade. The install aborted **at the blinker
step, before reaching pytest** — so after the first attempt, pytest / absl / reportlab / flask /
PySide6 were NOT installed, only the packages earlier in the install order (yaml, msgpack, numpy).

**Workaround that succeeded** (exit 0): `pip install -r requirements.txt --ignore-installed
blinker`. All packages then installed, including PySide6 (Qt). This is a real hidden dependency on
a non-default pip flag — a naive replay following the prompt literally (`pip install -r
requirements.txt`) would stop with pytest missing.

### FIREWALL HOSTS

**No download failed. No firewall host blocked anything.** Every PyPI wheel downloaded
successfully (numpy, PySide6 ~175 MB addon wheel included). Outbound HTTPS to PyPI worked.

### PySide6 (Qt)

`requirements.txt` includes PySide6, which only the FROZEN app needs. It **installed and imports
cleanly** here (`PySide6 6.11.1`) — it did not fail, so no continue-on-failure was needed. The
gating packages `pyyaml (6.0.3)`, `pytest (9.1.1)`, `msgpack (1.2.1)` all import.

Import verification after install:

```
yaml OK 6.0.3   pytest OK 9.1.1   msgpack OK 1.2.1   numpy OK 2.4.6
absl OK 2.5.0   reportlab OK 5.0.0   flask OK   PySide6 OK 6.11.1
```

---

## STEP 3 — THE REFEREE (each step timed, cold)

| # | Command | Exit | Wall-clock | Result headline |
|---|---------|------|-----------|-----------------|
| 1 | `cd jas_dioxus && cargo test --lib` | **0** | **84 s** (cold compile + run) | 2633 passed; 0 failed; 16 ignored |
| 2 | `python3 -m pytest workspace_interpreter/ -q` | **0** | **10 s** | 1248 passed |
| 3 | `python3 scripts/cross_language_algorithms.py --lang rust` | **0** | **20 s** | 410 passed, 0 failed, 0 errors (20 algorithms × **0 comparisons**) |
| 4 | `python3 scripts/check_corpus_manifest.py` | **0** | **1 s** | gate OK (25 families, 421 files, 9 declared coverage gaps) |

### Step 1 — `cargo test --lib` (output tail)

```
test result: ok. 2633 passed; 0 failed; 16 ignored; 0 measured; 0 filtered out; finished in 1.79s
=== EXIT: 0 ===
```

16 tests `ignored` — these are declared `#[ignore]`, not silent skips; they are surfaced in the
count, so this is not a vacuous pass.

### Step 2 — `pytest workspace_interpreter/` (output tail)

```
1248 passed in 10.38s
=== EXIT: 0 ===
```

### Step 3 — the corpus runner (output, verbatim, complete)

```
Cross-language algorithms: 410 passed, 0 failed, 0 errors (20 algorithms × 0 comparisons)
```

That single line was the **entire** output — no FAIL, no SKIP, no KNOWN-GAP, no ERROR lines.

### Step 4 — `check_corpus_manifest.py` (output tail)

```
corpus-completeness gate: OK (25 families, 421 files, 0 known-gap warning(s), 9 declared coverage gap(s) printed above)
=== EXIT: 0 ===
```

The 9 "COVERAGE GAP" blocks it prints are **declared, documented gaps** in fixture coverage (e.g.
`flatten-no-arcs`, `fit-curve-first-pass-only`, `codec-optional-fields-unset`,
`identity-view-only`), not failures. The gate is designed to print them loudly and still exit 0.
This is the opposite of a vacuous pass — it names what it does NOT cover.

---

## ⚠ THE MOST IMPORTANT NUMBER — COMPARISON COUNT vs ORACLE COUNT

The corpus runner's designed headline gate is **Rust vs Swift**. There is no Swift on Linux, so
only one lane exists.

- **CROSS-LANGUAGE COMPARISON COUNT: 0.** With one lane, `compare_langs` is empty; the
  app-vs-app comparison loop (`for lang in compare_langs`) never executed. The summary line says
  so literally: `20 algorithms × 0 comparisons`. **No cross-language agreement was checked.**
- **ORACLE COUNT: 410.** All 410 "passed" come solely from the oracle blocks — the Rust binary
  (`cargo run --bin algorithm_roundtrip`) was actually invoked per algorithm and its output
  compared key-by-key against the pinned goldens (`expected` / `translations`) in the fixtures.

**Do NOT read "410 passed" as "the corpus passed."** It means: *Rust still reproduces 410 pinned
golden values on a machine that has never seen this repo.* It does **not** mean any two languages
were shown to agree. The single most valuable thing the headline gate exists to do — cross-check
independent implementations — **did not happen in this run**, and cannot on Linux without Swift.

### Why the oracle count is non-vacuous

`run_rust` raises `RuntimeError` on any non-zero exit of the Rust binary, so a missing or broken
binary would surface as an `errors` count, not a silent pass. The 20 s wall-clock reflects 20
genuine binary invocations. 0 errors + 0 failed + 410 passed therefore reflects real execution.

### Lanes: which ran, which did not

| Lane | Ran? | Why |
|------|------|-----|
| Rust (reference) | **YES** | pre-installed toolchain; binary built & executed 20× |
| Swift | **NO** | `swift` absent on Linux (expected) — the Rust-vs-Swift comparison is structurally impossible here |
| OCaml | NO | not in `--lang rust`; frozen canary, `dune` not installed |
| Python | NO | not in `--lang rust` (it is the live reference interpreter, exercised separately by Step 2's pytest) |

---

## STEP 4 — THE CLEAN-MACHINE QUESTIONS

**1. Does everything build and run from nothing, or is there a hidden maintainer-machine
dependency?**
Mostly yes, with **one hidden dependency worth naming**: the literal command in the prompt,
`pip install -r requirements.txt`, **fails** on this image because of the Debian-managed
`blinker 1.7.0` that flask's `blinker>=1.9.0` cannot upgrade past without `--ignore-installed
blinker`. No absolute paths, no cached artifacts, and no macOS assumptions were hit; Rust happened
to be pre-installed. If Rust were NOT pre-installed, a rustup download would be required and was
not exercised here.

**2. Do the pinned goldens reproduce on hardware that has never seen this repo?**
**Yes — 410 of them, via Rust, exactly.** 0 oracle failures. This is the one place fixture
corruption or maintainer-local-only goldens would show, and it did not: the goldens reproduce on
this clean Linux box. Caveat: this proves it for **Rust only**. The goldens were not
cross-checked against Swift or the Python reference in this run.

**3. Did anything pass VACUOUSLY?**
No vacuous pass detected. Counts are high and consistent (2633 / 1248 / 410) and each runner
fails loudly on missing pieces: `run_rust` raises on binary failure; the manifest gate treats a
missing fixture as a hard ERROR and prints its 9 coverage gaps by name; `cargo`'s 16 `ignored`
are declared, not silent. **The closest thing to "vacuous" is structural, not a bug:** the corpus
gate's *headline cross-language comparison* silently degrades to 0 comparisons when only one lane
is present — the summary line does disclose `× 0 comparisons`, but a reader skimming "410 passed"
could easily mistake it for a cross-language pass. That is the reporting hazard this report exists
to prevent.

**4. Cold wall-clock time per step.**
pip install (successful workaround) 16 s · cargo test --lib **84 s** · pytest 10 s · corpus
runner 20 s · manifest check 1 s. (The first, failed pip attempt cost an additional ~15 s.)

---

## TREE CLEANLINESS

`git status --short` is **empty** after all runs — no tracked file was modified. Build artifacts
were produced (`jas_dioxus/target/`, `jas_dioxus/Cargo.lock`, several `__pycache__/`) but all are
`.gitignore`d, so they did not dirty the tracked tree. Only `CLOUD_REFEREE_REPORT.md` is
committed.

---

## CLOSING VERDICT

**Is this repo replayable from nothing?** On Linux, **yes for the reference-and-oracle half**:
Rust + Python build and run, all three non-corpus suites are green, and the pinned goldens
reproduce exactly on hardware that has never seen the repo. **But the referee's headline gate —
independent-implementation cross-checking — cannot run here at all**, because it needs Swift and
Swift is Linux-absent. What a Linux replay can honestly certify is *"Rust still reproduces the
goldens"*, not *"the implementations agree."*

**What would make the referee stronger here:**
1. **Make the single-lane degradation impossible to misread.** When `compare_langs` is empty, the
   runner should say so as a warning, not fold the oracle count into a bare "410 passed." A run
   that performs zero cross-language comparisons should not be able to look like a cross-language
   pass at a glance.
2. **Add a second Linux-runnable lane.** OCaml (`dune`) or the Python reference could serve as the
   cross-check partner on Linux, so `--lang rust,ocaml` or `--lang rust,python` yields a non-zero
   comparison count without needing macOS/Swift. Today, Linux can only ever oracle-check.
3. **Fix the `requirements.txt` install path** so a literal replay works: pin/relax `blinker`, or
   document `--ignore-installed blinker` in the setup steps. As written, the prompt's own Step-2
   command fails and would leave pytest uninstalled.
4. **A rustup-cold replay** (Rust not pre-installed) was not exercised; testing it would close the
   last "assumed present" gap in the toolchain story.
