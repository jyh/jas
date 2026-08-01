# CHECKER_RESIDUAL — the geometry-checker bus models CI, and a model has a floor

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
