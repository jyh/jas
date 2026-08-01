# CHECKER_RESIDUAL — a guard that models its subject inherits the model's floor

> **THE STOPPING RULE, RATIFIED BY JYH AT COUNCIL, 2026-08-01.**
>
> **Fix an instance when it is cheap and concrete. Declare the CLASS once. Do
> not hold a working instrument for the next member of a series that has no
> last element.**
>
> It was written against **seven** arrivals of one shape across Phases 1 and 2,
> and the eighth arrived during the sitting that wrote it down. The rule is not
> "stop looking". It is: **when you find the next one, fix it if it is cheap,
> declare it if it is not, and land the phase either way.** The class below is
> the standing declaration, so the next author inherits *the decision* rather
> than *the fatigue*.

This document exists because the same defect shape arrived **four times in one
phase**, each fix correct and each one abstraction short of the last:

| iteration | the guard checked | what it missed |
|---|---|---|
| original | the flag appears **as text** in the workflow | a YAML comment satisfied it |
| D1 | the flag appears in a **`run:` body** in the parse tree | steps that never execute |
| R5 / R8 | the step **executes** — the obligation is iterated, not the evidence | lanes with no job at all |
| A6 | the step executes **under a shell that aborts on failure** | the shell is configured three levels away |

**A guard that MODELS its subject inherits every assumption the model makes,
and those assumptions are invisible precisely because they are the model's
floor.** A fifth iteration is not the countermeasure. A *declared,
machine-checked* assumption is, and that is what this file is.

The recommendation on the record was: **land after A6, declare the residual,
do not chase a fifth.** This is the declaration.

---

## The assumption, stated plainly

`scripts/check_geometry_checkers.py` (R8/A6) proves that CI adjudicates every
declared checker lane. It does so **by reading `.github/workflows/test.yml` and
modelling GitHub Actions semantics from it.**

It therefore knows exactly four things about how a step runs, all of them
derived from the file: whether the job or step is behind an `if:`, whether
either carries `continue-on-error`, whether the `needs:` chain is satisfiable,
and — since A6 — **which shell the `run:` body executes under**, resolved in
GitHub's precedence (step `shell:` → job `defaults.run.shell` → workflow
`defaults.run.shell` → the platform default, `pwsh` on windows and `bash`
elsewhere), refusing any shell outside `SHELL_ABORTS_ON_FAILURE` rather than
assuming bash.

**It cannot see runner behaviour that is not in the file.** That is the
residual, and it is not closable by writing a fifth rule of the same kind —
closing it means executing the workflow, which is a different instrument.

## What would falsify it

Any of these makes the model's floor move, and none of them is a bug in the
gate — each is a premise that has changed and wants re-reading:

1. **GitHub changes a runner's default shell**, or changes the `pwsh` /`bash`
   wrapper. `PLATFORM_DEFAULT_SHELL` and `SHELL_ABORTS_ON_FAILURE` are this
   repository's *belief* about a vendor's behaviour, written down as data.
   Nothing in this tree can re-measure them; a human must.
2. **A checker invocation stops living in a `run:` body** — moved into a
   composite action, a reusable workflow, or a script the workflow calls. The
   gate reads `run:` lines. This one at least **fails closed**: the lane would
   report *NO JOB ADJUDICATES IT* rather than passing quietly.
3. **The gate stops resolving the shell at all** — the A6 clause deleted or
   "simplified" back to assuming bash. That is exactly the tidy this phase
   exists to have caught, one level up.
4. **A shell outside the modelled set is adopted.** The gate refuses it, which
   is the correct posture, but the refusal is a *red*, and someone will want to
   extend the allow list — which takes a measurement, not a guess.
5. **Runner configuration outside the workflow file**: a self-hosted runner
   whose label resolves to a family with a different default, an `ACTIONS_*`
   setting, an org-level default. Invisible here by construction.

## The machine-checked half

Three of the five above are claims about text in this repository, so they are
declared for `scripts/check_deferral_expiry.py`, which reds when a stated
precondition lapses. Items 1 and 5 are claims about a vendor and about runner
configuration; **no gate in this tree can check them, and pretending otherwise
would be the fifth iteration.** They are written above so a human re-reads them.

- The gate still resolves the effective shell rather than assuming one:
  <!-- expires-when: {"port": "gate", "file": "scripts/check_geometry_checkers.py", "contains": "SHELL_ABORTS_ON_FAILURE"} -->
- The per-platform default is still written down as data, so the belief about
  the vendor is a line someone can re-measure rather than an assumption in
  prose:
  <!-- expires-when: {"port": "gate", "file": "scripts/check_geometry_checkers.py", "contains": "PLATFORM_DEFAULT_SHELL"} -->
- The Windows job — the lane whose default is `pwsh` and whose failures would
  otherwise stop failing — still declares a modelled shell:
  <!-- expires-when: {"port": "ci", "file": ".github/workflows/test.yml", "contains": "shell: bash"} -->
- No step in the workflow runs a local composite action, so every command CI
  executes is still a `run:` line this gate can read:
  <!-- expires-when: {"port": "ci", "file": ".github/workflows/test.yml", "lacks": "uses: ./"} -->

**The limit of the last two, stated:** a substring claim over one file is
weaker than the property it stands for. `contains: "shell: bash"` would still
hold if the block moved somewhere it did not cover the checker steps, and
`lacks: "uses: ./"` does not see a marketplace action that runs the checkers.
The A6 clause in the gate is what actually adjudicates those cases; these rows
exist so that **deleting the mechanism is a red**, not so that they replace it.

## Where the prose lives

`docs/CHECKERS.md` §8 ("What the bus still cannot see — stated, not hidden")
carries the same limitation in the document a checker author reads. The module
docstring of `scripts/check_geometry_checkers.py` carries it under **A6** and
under **WHAT THIS GATE DOES NOT COVER**.

## Falsifier 6 — `set +e` earlier in the same `run:` body (found at the landing attack)

`status_discarded` reasons about PER-LINE constructs — `||`, a swallowing `&&`, a pipe, a
leading `if`/`while`/`until`/`!`, a trailing `&`. It never notices **errexit being turned
off earlier in the same block**. Prepend `set +e` to a multi-line bash checker step and the
gate stays GREEN while a failing checker no longer fails the step.

Measured at the landing attack, 2026-08-01. Judged NOT a reason to hold, and the reasoning
is worth keeping: `set +e` prepended to a checker step is not the shape of an ordinary tidy
— nobody disables errexit while "cleaning up CI". It is closer to the deliberate deletion
this document already declines to defend against. **But it was UNDECLARED, and undeclared is
the thing this file exists to prevent**, so it is declared here rather than left as a known
gap somebody rediscovers as a defect.

**It is also the FIFTH instance of the shape** — the gate models the shell's semantics
per line, and a line can change the shell's mode for every line after it. Recorded to make
the pattern's persistence visible, not to justify a sixth iteration: closing this properly
means EXECUTING the workflow, which is a different instrument.

---

# THE CLASS — instances 6, 7 and 8, which are 1–5 with "CI" replaced by "THE SAMPLE"

Phase 2 built a **sampled** instrument (`spec/geometry/region.py` +
`spec/geometry/probes.py`), and the shape arrived three more times in it. Read the
sentence at the top of this file with one word swapped and every row below is
already covered:

> **A guard that MODELS its subject inherits every assumption the model makes,
> and those assumptions are invisible precisely because they are the model's
> floor.**

For instances 1–5 the modelled subject was **CI**. For 6–8 it is **the sample**. It
is one class, and it does not need a second name.

| # | the guard | what it MODELLED | the assumption that was the floor | found |
|---|---|---|---|---|
| **6** | `min_accepted_per_vector`, F1 | the sample's *adequacy*, via a box built from the geometry under test | that a sampling box drawn around the output **contains** the output's defects — when the box is a FUNCTION of the output, so a runaway coordinate MOVES the box | a 1pt ring 100pt away left `accepted` at 88 of 88 against a floor of 64 while probes inside the region fell 31 → **0**; 0 of 17 vectors noticed, 10 seeds, three distances |
| **7** | `min_inside_probes_per_vector`, `min_accepted_per_vector`, `min_checks_per_lane` | the sample as **one pool** | that two lanes drawn for opposite reasons — one seedless and reproducible, one fresh every run — are **interchangeable**, so a floor DERIVED from the anchor lane may be PAID by the generative one | blind the lattice (all 64 probes still accepted, none informative) and the union floors still pass **11–15 of `boolean`'s 17** non-empty vectors, median 13, over 40 seeds — and 0–4 of `boolean_normalize`'s 16. **The reverse is worse: `prng_probes: 0`, the discovery lane deleted outright, was 19 of 19 GREEN in BOTH families** |
| **8** | the failure message's lane label, and then the per-lane accumulators | the probe list's **layout** — `"lattice" if idx < lattice_side ** 2 else "prng"` | that the anchor lane is first, emits exactly `side*side` points, and has nothing inserted between it and the generative lane | found while fixing 7. Harmless in a MESSAGE, load-bearing the instant a FLOOR turns on it: a mis-labelled probe charges one lane's shortfall to the other, which is instance 7 rebuilt inside its own repair |

**6, 7 and 8 are all FIXED, and none of them was held for the next one.**

- **6** — two remedies of different kinds, per `docs/CHECKERS.md` §4b lesson 4: an
  EXACT clause (`region.containment_defect`, no probe, no seed, no box) and an
  INFORMATION floor (`min_inside_probes_per_vector`, counting probes the law
  answered *inside the subject* rather than probes it merely accepted).
- **7** — every sampled floor is now keyed by probe lane; each lane meets its own
  floor or the vector reds, and the red names the lane. The generative lane's
  exemption from the information floor is **declared, with the measurement**
  (`checker.no_information_floor`), not omitted.
- **8** — the lane travels **with the probe**, from the generator that drew it
  (`pr.lattice` / `pr.scatter` yield `(lane, point)`), so the attribution is READ
  and never inferred from an index.

## What is NOT claimed, and this is the declaration

**The instrument is still a model of its subject, and there will be a ninth.** Two
of the model's own floors, stated so the next author does not rediscover them as
defects:

1. **The refusal test reads the OUTPUT's edges.** A probe is refused when it comes
   within `tolerance_points` of any edge of A, of B, *or of the result* — so a
   wrong result can, in principle, refuse the probes that would have caught it.
   The per-lane repair narrows this a long way (the anchor floor is now 64 of 64,
   so **any** output-induced refusal on the deterministic lane reds) and does not
   close it: the generative lane's floor has slack by construction, because a
   seeded floor without slack is flaky.
2. **The floors are derived from THIS corpus.** `min_inside_probes_per_vector` is
   the corpus minimum over the anchor lane; edit a vector's geometry and the
   number is stale. It fails in the safe direction — a smaller region reds — and
   the correct response is to RE-DERIVE it, never to lower it.

Closing either properly means a different instrument (exhaustive or symbolic
membership, not sampling), exactly as closing instances 1–5 means *executing* the
workflow. **Per the stopping rule, that is not this phase's job and it is not the
next rule of this kind.**

## The machine-checked half — the sampled instrument's rows

Each row states a premise about text in this repository, so
`scripts/check_deferral_expiry.py` reds when the mechanism is deleted. As with the
CI rows above, these exist so that **removing the mechanism is a red** — they do
not replace the mechanism.

- The probe's lane travels WITH the probe rather than being recovered from its
  index (instance 8):
  <!-- expires-when: {"port": "spec", "file": "spec/geometry/probes.py", "contains": "PROBE_LANES"} -->
- The modelled attribution has not come back into the checker:
  <!-- expires-when: {"port": "gate", "file": "scripts/cross_language_algorithms.py", "lacks": "if idx < cfg"} -->
- The sampled floors are still keyed BY LANE, and still total over the lanes in
  both directions (instance 7):
  <!-- expires-when: {"port": "gate", "file": "scripts/cross_language_algorithms.py", "contains": "PER_PROBE_LANE_FLOORS"} -->
- The INFORMATION floor still exists as a distinct thing from the population
  floor (instance 6's second remedy):
  <!-- expires-when: {"port": "gate", "file": "scripts/cross_language_algorithms.py", "contains": "min_inside_probes_per_vector"} -->
- The EXACT clause that catches a leak without a probe still exists (instance 6's
  first remedy, and the one a widened sample can never replace):
  <!-- expires-when: {"port": "spec", "file": "spec/geometry/region.py", "contains": "def containment_defect"} -->
- A lane excused from the information floor is excused BY NAME, WITH A REASON, in
  the fixture — never by an omitted key:
  <!-- expires-when: {"port": "corpus", "file": "test_fixtures/algorithms/boolean.json", "contains": "no_information_floor"} -->

**The limit of these rows, stated:** a substring claim over one file is weaker than
the property it stands for, exactly as it is for the CI rows. `contains:
"PER_PROBE_LANE_FLOORS"` would still hold if the block were emptied to `{}`; what
actually adjudicates that is `_per_lane_floor_errors`, which is total over
`pr.PROBE_LANES` in both directions and is proven red in
`check_geometry_checkers.py --self-test` case (e6).
