# CHECKERS — how to write one, and where it lives

> **The checker is the law. The corpus is its witnesses. The generative lane is
> its growing confidence.**
> (Ruled at council, 2026-08-01.)

A **checker** is a small executable predicate — the kind a human actually reads
— that takes **any** input/output pair and rules it legal or not. It is not a
golden. It has no pinned answer, so it can adjudicate a case nobody wrote down,
and a bug shared by both ports does not make it green.

This document is the bus. It should be enough, on its own, to write checker #2
without asking anyone — including from Windows. If it is not, that is a defect
in this file.

---

## 0. The one rule that voids a checker

> **A CHECKER EARNS ITS RUNG ONLY IF IT COULD HAVE BEEN WRITTEN WITHOUT READING
> THE IMPLEMENTATION.**

If you had to open the file under test to transcribe the formula, it is a golden
with extra steps and it scores **zero** — it cannot fail the bug it was copied
from. A classification audit found **nine** proposed checkers that merely
restated the implementation. Write the law from the spec (`transcripts/*.md`,
the fixture's own `_doc`, `WORKSPACE.md`), reconcile it against the
hand-derived witnesses, and only then open the source — to break it.

Corollary, and it is the acceptance test for the whole exercise: **prove the
checker red.** Mutate the implementation, watch it fail, restore. A checker
never seen red is not yet an instrument.

---

## 1. Which seam? — decide this first, it is where all the money is

| | **SEAM 1** (out-of-process) | **SEAM 2** (in-process) |
|---|---|---|
| the wire | `algorithm_roundtrip <algo> <fixture.json>` → `[{name, result}]` | `run_gesture_case` / the Swift twin — no CLI |
| implementations | **1** (Python, harness-side) | **2**, hand-mirrored (Rust + Swift) |
| measured cost | ~216 lines once, amortised over every family | ~1,100 lines **per family, per port** |
| exemplar | `check_leading_close_invariance` (20 families at once) | `shift_constrain_square` (1 family, 2 tools) |
| Windows sees | **all of it** | the Rust arm only — `swift test` is macOS-only |

Ratio ≈ **6.7×**, and Seam 1 amortises while Seam 2 does not.

**Rules that follow, and they are rules, not advice:**

- **Classify the family in writing before you start.** One row: Seam 1 or Seam 2.
- **Seam-1 families before Seam-2 families.** Seam 1 is what makes the bus
  reusable; Seam 2 is what makes it expensive.
- **At most ONE Seam-2 checker per phase.** `shift_constrain` holds that slot.
- If a family is Seam 2 only because it lacks a roundtrip arm, **pull the
  plumbing forward** — one arm per port — rather than paying the mirror tax
  once and then again for every future checker on that seam. (Liang-Barsky is
  the named instance: Seam 2 today, Seam 1 after one arm per port.)
- Anything the **jas/windows** seat must be able to referee belongs at Seam 1.

**Do not let Seam 1's cheapness pull a family there that genuinely lives at the
tool seam.** A harness-side checker cannot see a defect above the wire: the
boolean family's rings are emitted, a tool's committed element after a gesture
is not. Chasing the cheap seam with the wrong family is how a checker becomes a
golden with extra steps.

---

## 2. Where the parts live

```
spec/geometry/            the analytic TCB: what a thing MEANS, as importable
                          Python. Standard library ONLY — enforced, not
                          conventional (check_geometry_checkers.py scans it).
scripts/cross_language_algorithms.py
                          the Seam-1 checkers themselves, beside the registry.
                          Already wired on BOTH platform families
                          (windows-latest --lang rust; macos-latest
                          --lang rust,swift --require-comparisons).
test_fixtures/algorithms/<algo>.json
                          the witnesses (`vectors[].expected`) AND the
                          `checker` block that declares every floor.
scripts/check_geometry_checkers.py
                          totality: R1–R5 plus the TCB import scan.
scripts/corpus_manifest.json
                          one `checker` (or `checker: null` + `checker_gap`)
                          per family.
```

**Why the TCB is not in `workspace_interpreter/`.** That is the *live
reference* — an implementation of the spec's meaning. A checker inside the
reference cannot adjudicate the reference; law and defendant collapse. The
checker must be outside every implementation, the reference included.

**Naming is load-bearing.** `scripts/check_lane_coverage.py` globs
`scripts/check_*.py` and explicitly excludes non-Python gates. A gate named
anything else is invisible to it and its both-platforms claim is fiction. Never
invent `scripts/run_geometry_checkers.py`.

---

## 3. The rules the bus enforces (R1–R8)

| | rule | what it stops |
|---|---|---|
| **R1** | Every family NAMES a checker or carries `checker: null` **with a reason**. Policed **both ways**: a gap row whose hole has closed is stale and fails. | A family going unwatched by being *forgotten* rather than *excused*. One-directional policing is how `swift:dropdown` asserted a missing feature for months after it shipped. |
| **R2** | Every floor is **declared in the fixture**, and the runner asserts the count it **actually ran** — not the count declared. | A hardcoded floor in a runner drifts (`discriminating >= 2` lives in the Rust runner today, hand-mirrored in Swift). And the count-what-you-ran assertion is what catches a seeding pass that seeded zero. |
| **R3** | Teeth: a **mutant with a named prior bug**, or — where none exists — a red self-test case. | A mutant an author invents is a self-graded exam; they invent one their checker catches, and `min_discriminating` reads healthy forever. |
| **R4** | A registered family that ruled **nothing** is a failure, not a silent zero. | `lane_report` exits 3 only when the *whole run* is empty; one family going empty is below its resolution. |
| **R5** | The runner writes down the rulings it **performed**, per lane; the gate reads them back and asserts non-zero, **that every REQUESTED lane is among them**, lane agreement, and every declared floor. | R1–R4 are total over the registry and the fixtures, **not over the runners** — and the runner is where the vacuity lives. The requested-lane clause is load-bearing: a lane that rules zero is **absent** from the account, not present with a zero, so every rule phrased over the lanes *present* steps around it. Demanding two lanes only at seam 2 left **seam 1 — the preferred seam, and the one every checker rides — unguarded**; one `SKIP_LANG_ALGO` line emptied the Swift arm and reconcile printed `OK ... across lanes rust, swift`. |
| **R6** | The report must be **evidence**: a run id, a digest of the fixtures ruled over and of the `spec/` tier ruled with, all recomputed by the reader; and it must be **gitignored and untracked**. | `--reconcile` reads a *file*, and a file is not a run. A committed report sits in every checkout and reconciles green on a run where the writing step was deleted. The `spec/` half is the interlock: change the denotation and an account computed under the old one stops vouching for the new one. |
| **R7** | The witness set declares what it must **separate**, not only how big it is (`min_witnesses` against `CHECKER_WITNESS_PROBES`, total both ways). | Counting vectors and samples measures **population**; a corpus can meet every count and be **collinear**. `gradient_remap` shipped 9 vectors and 585 green comparisons in which all 18 bounding boxes were degenerate, so `half_diag = hypot(w,h)/2` — the clause `spec/` singles out as *not half the width* — was exercised by nothing, and mutating it to `max(w,h)/2` left the whole board green. |
| **R8** | The lanes that must be adjudicated are **declared as data** in `scripts/checker_lane_registry.json`, a lane being a `(platform, language)` pair with a reason; the gate **iterates that registry**, not the jobs it discovers, and proves per lane that a job on that platform runs the checker for that language, pairs writer and reader at one path, and is not neutered by job- or step-level `if:`, by `continue-on-error`, by an unsatisfiable `needs:` chain, or by a shell short-circuit. Both directions: an **undeclared** lane CI adjudicates reds too, as does a `permitted_if` whose condition has gone. | **Presence is a proxy for execution.** R5–R7 rule over a report; this rules over the workflow. `check_ci_wiring` iterated `set(writers) \| set(readers)`, so **a job carrying neither flag was invisible**: deleting seven lines from the Windows job — the seat that most needs the guarantee, since `swift test` is macOS-only and Windows already sees only the Rust arm — left the gate, its `--self-test` and `check_lane_coverage.py` **all green**. And `executed_run_commands`, whose docstring claims *every command CI actually executes*, read only `step["run"]`: never `continue-on-error`, never `if:`, never `needs:`, never the shell. A rule phrased over what it **finds** cannot notice an absence, so the obligation is written down and iterated. **A6, the fourth iteration of the same shape:** every one of those exit-status rules stood on *"GitHub runs a `run:` body as `bash -e {0}`"*, which on `windows-latest` is **false by default** — the shell is `pwsh` and its wrapper appends `exit $LASTEXITCODE`. What made the model true was one `defaults: run: shell: bash` block **no gate read**. The shell is now resolved in GitHub's precedence and an unmodelled one is **refused, not assumed**. The residual — that this gate models CI *from the file* — is **declared** in `transcripts/CHECKER_RESIDUAL.md` rather than chased with a fifth rule (§8). |

**A floor of zero is not a floor, and a floor of one is barely one.** Declare
the floor **equal to the authored count**: adding vectors leaves it green,
deleting them reds. A family is not emptied by deleting its file — it is
emptied by rewriting the file's contents.

---

## 4. Two rules about numbers, written before anyone needs them

**THE ULP RULE.** `spec/` is a *third* floating-point dialect. It will not agree
bit-for-bit with Rust or Swift on a borderline value. The analytic tier may host
**only** laws whose verdict is robust to ulp-scale disagreement — a sampled
comparison with a tolerance **derived from a real quantisation step**, never
`==`. A bit-exact law (the circle invariant is `==` with no tolerance band,
deliberately) **must stay at Seam 2 and be mirrored.** Move one harness-side and
it will go quietly wrong, in the direction of green.

**THE HEX-BIT-PATTERN RULE.** `algorithm_roundtrip.rs` parses fixtures with
`serde_json`, which this tree has **measured** to mis-parse 21,397 of 199,903
shortest-round-trip `f64` literals by exactly 1 ulp — **10.7%** — while Rust's
own `str::parse`, Swift's `Double(String)`, `JSONSerialization` and Python all
read them correctly. This is dormant while fixtures hold small integers. The
moment a generative lane writes random doubles onto the algorithm wire, **the
Python oracle and the Rust implementation are computing on different inputs one
time in ten**, and it will present as a geometry bug. So: **any GENERATED double
on the algorithm wire is a hex bit-pattern string**, or the port echoes its
parsed input and the oracle rules against the echo. (Hex *strings*, not
integers: a negative double's bit pattern exceeds 2^63.)

---

## 5. The generative lane (not yet built for Seam 1 — read before you build it)

Four things the existing `shift_constrain` lane gets right and any new lane must
keep: a **fresh nanosecond seed** every run; the seed **printed at the head and
on failure**, with `JAS_PROPERTY_SEED` for exact replay; a **SplitMix64
finalizer** on the seed (adjacent raw LCG states differ only by the multiplier,
so seeds 1 and 2 would otherwise draw near-identically); and the **stream pin**,
where both ports build the stream at a fixed seed and compare the first draws
exactly — so "replay this seed in the other port" is a guarantee, not a hope.

Four things to add before there is a second generative family:

1. **One run seed, per-family derived streams.**
   `splitmix64(run_seed XOR fnv1a(family_name))` — otherwise one
   `JAS_PROPERTY_SEED` reseeds every family at once and replaying family B
   perturbs A, C and D.
2. **Pin the `PropertyStream` ONCE** (LCG + finalizer + lerp +
   signed_magnitude), and let each family pin only its own **draw order** — or
   the LCG gets re-pinned once per family.
3. **THE QUARANTINE RULE.** A generative red currently lives only in an expiring
   CI log. A generative failure is **first demoted to a named witness in the
   corpus**, carrying a `why` with the arithmetic, and **only then fixed**.
   Otherwise the regression teeth for that bug are in a log nobody keeps.
4. **`JAS_PROPERTY_CASES` with a hard floor** that can never drop the sample
   below what `min_discriminating` needs. Measure the existing lane's wall clock
   before multiplying 384 cases by four families across `cargo test` **and**
   `swift test`; a "fast" local run must not be able to go silently vacuous.

---

## 6. Copyable template — a Seam-1 checker, start to finish

Worked example in the tree: **`gradient_remap`**, whose law is
`gradient_remap_repaints_the_fragment`.

### 6.1 Write the denotation into `spec/`

Only if the law needs one. It answers *what does this MEAN* — never *what does
the algorithm DO*. Standard library only.

```python
# spec/geometry/<thing>.py
def axis_unit(angle_deg): ...      # what the spec says the geometry is
def ramp(bbox, u): ...
```

### 6.2 Write the law beside the registry

In `scripts/cross_language_algorithms.py`. It returns `None`/a count when legal,
or a **string saying why not, with the arithmetic in it**.

```python
def <family>_<law_name>(vec, out, cfg):
    """THE LAW. <one sentence a human can check against the spec>.

    Written from <the spec source>; <implementation>.rs was not opened.
    """
    for place in <the sample set>:
        want = <what the spec says should be here>
        got  = <what the output puts here>
        if <off by more than cfg["tolerance..."]>:
            return f"at {place}: spec says {want}, output says {got}"
    return <how many samples were checked>
```

Then register three things:

```python
GEOMETRY_CHECKERS["<algo>"] = "<law_name>"          # R1 forward
CHECKER_PROBES["<law_name>"] = lambda v: ...        # R1 reverse: the SHAPE it
                                                    # consumes, so a stale gap
                                                    # row can be found
CHECKER_FUNCS["<law_name>"] = (rule, rulable, mutant)
```

`rulable(vec)` returns **why a vector cannot be ruled**, or `None`. Every
unrulable vector must be **declared by name in the fixture** — a vector the law
silently skips is a vector nothing watches — and the declaration is policed both
ways.

### 6.3 Declare every floor in the fixture

```jsonc
"checker": {
  "name": "<law_name>",
  "seam": 1,
  "law": "<the one sentence>",
  "samples_per_vector": 65,
  "tolerance_bytes": 0.500001,
  "_tolerance_why": "DERIVED from a real quantisation step, with the arithmetic",
  "min_rulable_vectors": 8,          // equal to the authored count
  "min_checks_per_lane": 500,
  "min_witnesses": {                 // R7: what the set must SEPARATE
    "<probe name>": 4                //   one entry per CHECKER_WITNESS_PROBES
  },                                 //   probe; total in both directions
  "_min_witnesses_why": "<the clause each probe keeps exercised>",
  "unrulable": { "<vector name>": "<why no law can rule it>" },
  "mutant": {
    "name": "<name>",
    "provenance": "<THE NAMED PRIOR BUG this transcribes>",
    "min_discriminating": 7,
    "_min_discriminating_why": "MEASURED: <n> of <m>, margins <lo>..<hi>"
  }
}
```

### 6.4 Register the family in `scripts/corpus_manifest.json`

`"checker": "<name or a pointer to the per-algorithm registry>"`, or
`"checker": null` **plus** `"checker_gap": "<reason>"`. `"PHASE 2"` means *a law
IS available at this seam and is unwritten* — a different and more honest claim
than *no law exists*. A reason that restates the implementation is not a reason.

### 6.5 Wire it, and prove it red

```bash
python3 scripts/check_geometry_checkers.py --self-test
python3 scripts/check_geometry_checkers.py
python3 scripts/cross_language_algorithms.py --lang rust,swift --algo <algo> \
        --checker-report /tmp/r.json
python3 scripts/check_geometry_checkers.py --reconcile /tmp/r.json
```

Then **break the implementation and watch the checker fail**, and record the
mutation and the result. Restore. Break the **denotation** too — mutate the
clause in `spec/` your law leans on hardest and watch the same red; that is the
step that would have caught `half_diag` before it shipped, and it is now R7's
job to keep catching it.

**The CI wiring is asserted over EXECUTED steps, never over the file's text.**
`check_ci_wiring` parses the workflow and reads only `run:` bodies, dropping
YAML comments and shell comments, and it requires the two flags to **pair
inside one job** on the **same report path**. The rule it replaced was
`if flag not in workflow_text` — a bare substring scan — under which deleting
every invocation left the gate green, because one occurrence survived: **the
YAML comment warning that without those steps the lane goes vacuous.** The
prose about the check was read as the check. When you wire a new checker,
assume any comment you write is invisible to the gate, because it is.

**And the wiring rule is phrased over the OBLIGATION, not over the workflow
(R8).** Parsing `run:` bodies is closer to execution but is still not
execution: `check_ci_wiring` iterated the jobs it *found*, so a job carrying
neither flag was invisible, and it read nothing about `continue-on-error`,
`if:`, `needs:`, or the shell. So **the lanes that must be adjudicated are
declared in `scripts/checker_lane_registry.json`** — one row per
`(platform, language)` pair, each with a reason — and the gate iterates that
file. Adding or dropping a lane is an edit *there*, plus `MIN_DECLARED_LANES`
in the same commit; it is never an emergent consequence of a CI edit. Two
consequences when you wire a lane:

- **State `--lang` explicitly** on the `--checker-report` writer. The gate
  refuses to mirror another file's argparse default, because a mirrored value
  drifts (R2's lesson, one file over).
- **Put the invocation on its own line.** `bash -e` does *not* abort for a
  non-final element of an `&&` chain — `bash -e -c 'false && echo hi; echo
  after'` prints `after` and exits **0** — so a checker call chained onto
  something else can fail in total silence. `|| true` and a pipe do the same
  thing more obviously.
- **Run it under a shell the gate models** (`bash` or `sh`). The gate resolves
  the effective shell — step `shell:`, job `defaults.run.shell`, workflow
  `defaults.run.shell`, then the platform default — and **refuses** anything
  else rather than assuming bash. This matters most on `windows-latest`, whose
  default is `pwsh`: its wrapper appends `exit $LASTEXITCODE` instead of
  aborting, so a failing `python A` above a passing `python B` reports **only
  B**. The Windows job's `defaults: run: shell: bash` block is load-bearing;
  see §8.

---

## 7. The mutant, and when you may not have one

The mutant is **the bug, written down** — not a second copy of the
implementation. It is fed to the same predicate on every run and the predicate
must reject it, so the lane measures its **teeth** and not only its
**population**.

It needs a **named prior bug**. `gradient_remap`'s mutant is the pre-S-2
shipping behaviour (a fragment inheriting its parent's stops verbatim), named in
the fixture's own `_doc`. `shift_constrain`'s is DYADICSIDE.

**No prior bug? Then you may not invent one.** Take the **red self-test rung**
instead: synthetic cases (a)–(d) that must go red, plus case **(e), the live
tree must be clean** — the house style across 23 `scripts/` gates. `R3` refuses
to register a family with neither.

**Mutants rot silently.** A stale mutant keeps a floor green forever while
measuring arithmetic nobody ships. There is no freshness gate today; it is
needed **before the second mutant, not before the first**. The cheaper fix, when
it applies, is to *derive* the mutant from the declarative source it mirrors
rather than hand-transcribing it.

---

## 8. What the bus still cannot see — stated, not hidden

- **`test_fixtures/properties` (the Seam-2 property family) is not yet readable
  by this registry.** Its floors are hardcoded in the two runners
  (`discriminating >= 2`, hand-mirrored) rather than declared in the fixture,
  and it has no `vectors` key, so it cannot join `VECTOR_FLOOR_FAMILIES` as-is.
  It is registered as a `checker_gap` naming itself as the first migration.
  Until then: **11 witnesses can be rewritten to 2 and every gate stays green.**
- **Feature flags.** Every Seam-2 checker site in
  `jas_dioxus/src/cross_language_test.rs` is `#[cfg(feature = "web")]`, and
  `check_native_core_tests.py`'s own docstring names cfg-wrapping as the
  green-turning fix it cannot see. Seam-1 checkers are immune by construction —
  they are Python and no port flag can compile them away — which is a further
  reason to prefer Seam 1. A new Seam-2 checker must either be feature-free or
  be named in a companion assertion.
- **Windows seed entropy is unmeasured.** The generative lane assumes a
  nanosecond seed nobody chose; Windows clock granularity is coarser, and
  SplitMix64 spreads a seed rather than creating entropy that was never there.
  One measurement, one line in the fixture `_doc`, before anyone leans on it.
- **R1's reverse direction is mechanised at algorithm granularity only.** For
  the heterogeneous corpus families there is no generic "does this now have
  geometry" probe, and inventing one would be guessing.
- **R8 does not interpret the shell, and it is not a GitHub Actions runner.**
  It names the decay forms that have a name — `||`, a swallowing `&&`, a pipe,
  a leading `if`/`while`/`until`/`!`, `&` — and cannot see a status discarded
  by a trap, a subshell, `set +e` three lines up, or a variable. It reads
  `runs-on` literally and **refuses** a matrix expression rather than guessing
  which platform it resolves to. A gate that claimed to model bash would be a
  fourth shell with a nicer name.
- **THE GATE MODELS GITHUB ACTIONS FROM THE WORKFLOW FILE, AND CANNOT SEE
  RUNNER BEHAVIOUR IT DOES NOT MODEL. This is the declared residual of Phase 1
  and it is not a bug to be fixed by a fifth rule.** The shape arrived four
  times: the flag as **text** (a YAML comment satisfied it) → the flag in a
  **`run:` body** (steps that never execute) → the step **executes** (lanes
  with no job at all) → the step executes **under a shell that aborts on
  failure** (the shell is configured three levels away). Each fix was correct
  and each was one abstraction short. **A guard that models its subject
  inherits every assumption the model makes, and those assumptions are
  invisible precisely because they are the model's floor.**

  A6 closed the fourth: the shell is now **resolved** in GitHub's precedence —
  step `shell:`, job `defaults.run.shell`, workflow `defaults.run.shell`, then
  the platform default (**`pwsh` on windows, `bash` elsewhere**) — and a shell
  outside `SHELL_ABORTS_ON_FAILURE` is **refused, never assumed to be bash**.
  What made the old model true was one `defaults: run: shell: bash` block eight
  lines below `runs-on` in the Windows job that **no gate in this repository
  read**; deleting it as an ordinary tidy would have turned that lane's
  failures into passes. Two consequences for anyone wiring a lane: **put the
  checker invocation on its own line under a modelled shell**, and know that on
  `windows-latest` without that block a `python A` / `python B` pair reports
  only **B**.

  What remains outside the model, stated rather than hidden: **the vendor's
  behaviour** (GitHub changing a runner's default shell or a wrapper —
  `PLATFORM_DEFAULT_SHELL` and `SHELL_ABORTS_ON_FAILURE` are this repository's
  *belief* about it, written as data because nothing here can re-measure them);
  **anything not in the file** (a self-hosted runner label resolving to a
  family with a different default, an org- or runner-level setting); and
  **commands that stop being `run:` lines** (a composite or reusable workflow),
  which at least fails closed as *NO JOB ADJUDICATES IT*. Closing that residual
  means *executing* the workflow, which is a different instrument, not another
  rule of this kind. **The countermeasure chosen instead is a DECLARED,
  MACHINE-CHECKED assumption:** `transcripts/CHECKER_RESIDUAL.md` names the
  premise, states what would falsify it, and carries `expires-when` markers
  that `scripts/check_deferral_expiry.py` reds on when the premise moves.
- **R8 cannot stop someone who means it.** Deleting a lane row and lowering
  `MIN_DECLARED_LANES` in one commit is a legal edit — by design, because
  dropping a lane has to be *possible*. What the registry buys is that the edit
  is **visible, local, and has to carry a sentence**, instead of being an
  emergent consequence of seven deleted lines in a CI job.
- **CAN THE FLOORS SEE COLLINEARITY? Partly — and the general answer is not a
  floor.** Counting cannot: `min_rulable_vectors` and `min_checks_per_lane`
  measure population, and `gradient_remap` was 9 vectors / 585 green
  comparisons in which every bounding box was degenerate. A tenth degenerate
  vector would have raised both numbers and exercised nothing new. R7's
  `min_witnesses` **can** see it, but only for a clause someone has already
  noticed: each probe is hand-written from a known separation, so R7 is a
  **regression floor, not a discovery instrument** — it keeps a noticed clause
  exercised and cannot say which clause to notice next.
  **The total instrument is mutation, and the machinery already exists.**
  “This corpus exercises this clause” is exactly “some mutation of this clause
  is rejected by this corpus”, which is what R3's `mutant` /
  `min_discriminating` pair already measures. The gap is *what* gets mutated:
  the one registered mutant, `identity_remap`, mutates the **implementation's
  behaviour**, while `half_diag` lives in the **analytic tier**, which no
  mutant touches. Extend the mutant set to `spec/` — one mutant per clause of
  the denotation, each with a declared floor — and a collinear corpus reports
  itself as *“the half_diag mutant is rejected on 0 vectors, floor 4”*: a red
  with a name, at authoring time, instead of an audit finding. It is cheap,
  because the ports' outputs are already in hand from the main pass and only
  the Python law is re-run. **Its own boundary, stated: a clause nobody wrote a
  mutant for is still unwatched.** Making *that* total is a coverage question
  about `spec/` (every branch and every constant named by some mutant), and it
  is not answered here.
- **The manifest is a wall.** It already prints 35 coverage gaps every run;
  `checker_gap` adds a second dimension. The bidirectional staleness check is
  the only thing keeping it honest. That is a maintenance cost, and it is stated
  here rather than discovered later.
