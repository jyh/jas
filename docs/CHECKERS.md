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
                            linear_gradient.py — what a gradient PAINTS here
                            region.py          — what a REGION IS (membership
                                                 under either fill rule; ring
                                                 simplicity; laminarity; and
                                                 containment, the one clause
                                                 here that is EXACT and needs
                                                 no probe at all)
                            probes.py          — WHERE TO ASK (the anchor
                                                 lattice and the seeded stream;
                                                 every probe carries the LANE
                                                 that drew it, because a
                                                 per-lane floor cannot be
                                                 charged from an index — §4c)
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

## 4b. THE REGION TIER (Phase 2) — and the four things it measured

`spec/geometry/region.py` answers one question — **is this point in the region
these rings denote under this fill rule** — and two families rule with it:
`boolean` (`boolean_result_is_the_sampled_combination`) and `boolean_normalize`
(`normalize_preserves_the_declared_region`). Both are Seam 1, so the Windows
seat adjudicates them in full.

**What it buys.** `compare_exact_boolean` demands ELEMENTWISE RING EQUALITY at
4dp. The region is unique; **the encoding is not** — ring order, start vertex,
winding, one-ring-versus-two at a pinch and retained collinear vertices are all
free. `boolean.json`'s `intersect_edge_shared_ring_pair_evenodd` is the worked
example: both ports emit the single rectangle `[8,12]x[2,8]` as **two** abutting
rings. A region law is blind to that and refuses a wrong region instead.

**Four measurements, all reproducible, none assumed:**

| mutant | region law | ring equality | pinned-golden oracle |
|---|---|---|---|
| clean tree | green | green | green |
| Swift tie-break **inverted** | **RED** (1) | RED (1) | green |
| **BOTH ports** inverted (a shared bug) | **RED (2, one per lane)** | **GREEN** | RED (1, on `area`) |
| Swift **pre-STABLETIE spelling** | green | green | green |

Read the third row: a bug present in both ports leaves the port-vs-port
comparison **completely green**, and the region law reds in both lanes. Read the
fourth: the literal census-row-35 code is **invisible to every instrument**,
because it is not observable at HEAD — Swift's shipping sort happens to be
stable, exactly as STABLETIE measured. A checker cannot catch a defect that
produces no wrong answer; what it catches is the wrong answer that defect is one
stdlib release away from producing.

### 4b.1 THE COMPLEMENTARITY MEASUREMENT — measured BOTH ways, and the ruling

**`compare_exact_boolean` KEEPS ITS GATE STATUS (RULED, R-A, 2026-08-01).** The
question the ruling settled was whether the region law makes the older,
encoding-exact comparison redundant. It does not, and the answer is a
measurement rather than an opinion: **each instrument is blind to defects the
other refuses, so neither subsumes the other.**

The table above measures one direction. This is the other, over `boolean`'s 19
rulable vectors, each mutant applied to the **Rust** output and then (a) compared
against the untouched **Swift** output by ring equality and (b) ruled by the
region law on its own:

| mutant | ring equality | region law |
|---|---|---|
| clean tree | green | green |
| a defect BOTH ports share (tie-break inverted in each) | **GREEN — blind** | **RED**, once per lane |
| one result vertex nudged **0.01pt** (100× the wire's 4dp step) | **RED, 17/19** | **green, 0/19 — blind** |
| a **0.2pt** square hole added to the result | **RED, 17/19** | green on 16/19 |
| **400 hairline rings** (0.0002pt squares) appended | **RED, 17/19** | green on 16/19 |

*(17 and not 19 because two vectors' correct results are empty, so there is no
ring to corrupt. The 0.2pt hole and the 400 hairlines each red **3** vectors, and
not one of the three reds is “there is a hole” or “there are hairlines”: two are
`containment_defect` firing because the injected geometry happened to land
outside an operand box on a disjoint union, and one is a probe that landed inside
the hole by luck. The region law is not detecting these defects; it is
occasionally tripping over them.)*

One measurement worth keeping separately, because it is a consequence of the
per-lane repair in §4c and not of the region law as designed: **400 hairline
*slivers* spanning the sampling box** — 800 extra edges through the probe field
— red **12 of 19**, almost all through `min_accepted_per_vector.anchor`. That is
the law refusing to answer rather than the law seeing a wrong region, and it is
the correct posture, but it should not be read as region coverage.

**So: ring equality is an ADMISSION BARRIER and an ENCODING gate; the region law
is a MEANING gate.** Ring equality would red a third port, a Skia/Vello rewrite,
or a `snap_grid` change that moved a coordinate by an ulp — and it catches, at
4dp, every re-encoding above that leaves the region intact. The region law is
blind to all of those by construction, and is the only instrument that reds on a
bug both ports share.

**THE RULING, and it is a scope call that belongs to JYH and not to a checker
author: revisit the gate status of `compare_exact_boolean` only when a THIRD PORT
ACTUALLY APPLIES FOR ADMISSION.** Not when one is discussed, and not because the
barrier is inconvenient. Until then both instruments run and neither is demoted.

**Four things the phase learned that cost real time, written down so the next
author does not re-buy them:**

1. **The obvious tie geometry does not reach the tie.** Two rings of one operand
   sharing a FULL edge, or meeting at a single vertex, are fused or separated by
   CANONICALISATION before the sweep runs; inverting the tie-break changed *not
   one byte* on five such vectors. What reaches it is a **PARTIAL edge share
   ending at a shared vertex** (`subtract_across_a_partial_edge_share_tie`).
   STABLETIE's own test said so in one line and it was read too late.
2. **"Non-zero membership equals even-odd membership" is FALSE of correct
   output**, so do not write that property. Both ports emit
   `subtract_inner_creates_hole` with its hole wound the SAME way as its outer
   ring — winding 2 inside the hole — and `BOOLEAN.md` clause 4 declares results
   even-odd *precisely so the sweep's winding need not be consistent*. The
   property that says what was meant, and is winding-blind, is **laminarity**:
   over the probe set, no two result rings may be partially overlapping.
3. **Derive `min_checks_per_lane`, never observe it.** With a generative lane the
   accepted-probe count moves run to run. The floor is
   `min_accepted_per_vector x min_rulable_vectors`, which is a true lower bound
   and cannot go flaky.
4. **THE SUBJECT OF MEASUREMENT SETS THE MEASUREMENT'S RESOLUTION** — the
   finding that held this phase back a day, and the one most likely to recur in
   the next sampled law. **A sampling box built from the geometry under test is
   a function of the OUTPUT, so an output that runs away carries the instrument
   with it.** Append a 1pt spurious ring 100pt from `union_overlapping_squares`
   — a far coordinate from a near-parallel intersection is a *named* failure
   mode of sweep-line booleans — and `accepted` stays **88 of 88 against a floor
   of 64**, a perfect sample by every count the fixture declared, while the
   probes landing **inside the region under test fall from 31 to ZERO**. Green,
   fully sampled, nothing asked. **0 of 17 vectors caught it, across 10 seeds,
   for specks of 0.1pt and 1.0pt at 100pt, 1000pt and 10000pt.**

   It also falsified a sentence written in three places — `boolean.json`'s
   `_lanes_why`, `_region_probe_points`'s docstring, and `probes.py`'s
   `sampling_box` — in the form *"the box spans A, B and the result, so a
   result that leaks outside the operand hull is probed where it leaked."*
   **It does not, and all three now say so, in place, next to the claim they
   replaced.** A design claim that is false in the file is worse than no claim:
   the next author reads it as a guarantee and stops looking. Widening a sample
   never catches a subject that moves the sample.

   Two remedies, and note that they are **different in kind**:

   - **Prefer an EXACT clause whenever the property admits one.**
     `bbox(result) ⊆ bbox(A) ∪ bbox(B)` holds for all four boolean operations
     because each returns a subset of `A ∪ B`; it is O(vertices), needs no
     probe, no seed and no box, and its only tolerance is the serialisation
     epsilon already derived. It reds all 19 vectors at every speck size and
     distance measured. An exact clause cannot be blinded by its subject
     **because it is not measured at places the subject chose.**
   - **A sampled clause must floor INFORMATION, not REFUSALS.**
     `min_accepted_per_vector` counts probes the law was *willing to answer*;
     `min_inside_probes_per_vector` counts probes that landed in the region
     being adjudicated, read from the spec side. A fully blind lane reports
     `88 of 88` for the first and `0` for the second. With the exact clause
     bypassed, the same speck run passes the old floor (1672 samples against
     1216) and reds **17 of 19 vectors** on the new one.

   And its exemption is **declared, never silent**: some regions are empty by
   construction (an intersection of disjoint operands, a canonicalisation of a
   zero-area input), so those vectors are named in `checker.empty_regions` with
   a reason. Policed three ways — a declaration the sample contradicts is
   refused, an undeclared vector that went quiet is refused, and a name the law
   never reaches is refused. **Sampling witnesses a region's presence exactly
   and can never prove its absence**, which is why emptiness is a sentence a
   human wrote and the machine's whole job is to refuse a false one.

## 4c. A FLOOR BELONGS TO ONE LANE — and the lane travels with the probe

> **IF A LAW SAMPLES IN MORE THAN ONE LANE, EVERY FLOOR IT DECLARES IS KEYED BY
> LANE, AND EACH LANE MEETS ITS OWN. A number compared against the union of two
> lanes is paid by whichever lane happens to have it.**

This is a rule, not advice, and it is here because Phase 2 shipped the opposite
by accident. `_rule_region` accumulated `accepted` and `inside` over
`lattice(64) + scatter(24)` **concatenated**, so both per-vector floors — and
`min_checks_per_lane` downstream — were compared against the union total. The
fixture's own justification for `min_inside_probes_per_vector` read *"DERIVED
FROM THE ANCHOR LANE, so the generative lane's 24 draws can only add to it and
the floor cannot go flaky"*, which is a true sentence about the floor's
**stability** and a false one about what the floor then **measured**: draws that
can only add can also be **the only thing there**.

**Measured, 40 seeds.** Displace every anchor probe 10000pt — all 64 are still
*accepted* (they stand clear of every edge by miles) and *none* is informative —
and the union floors still pass **11 to 15 of `boolean`'s 17 non-empty vectors,
median 13**, and 0 to 4 of `boolean_normalize`'s 16. Thirteen vectors reporting a
healthy sample while the seedless lane a bisect depends on asked nothing at all.
Under per-lane floors it is **zero, in both families, at every seed measured.**

**And the other direction, which is worse.** Set `prng_probes: 0` — delete the
discovery lane outright — and the old checker was **19 of 19 GREEN in both
families**: the anchor lane's 64 probes met a floor of 64 and its inside count met
a floor derived from itself, so nothing anywhere noticed that the generative lane
had stopped existing. Under per-lane floors it reds **all 19, in both**, naming
the lane: *the 'generative' probe lane produced NO PROBE AT ALL for this vector,
so every floor charged to it is met by an accumulator that was never touched.*
Note the shape of that assertion — it checks that each declared lane **was seen**,
not that its counter is non-zero, because a lane that drew nothing and a lane that
drew and was refused report the same number. Same sentence as R5's, one instrument
down.

Three consequences, and the second is the one that costs thought:

1. **THE LANE COMES FROM THE PRODUCER.** `pr.lattice` and `pr.scatter` yield
   `(lane, point)`. Recovering it downstream as `"lattice" if idx < side**2 else
   "prng"` is not reading the lane, it is modelling the concatenation's layout —
   tolerable in a failure *message*, and load-bearing the instant a *floor* turns
   on it, because a mis-labelled probe charges one lane's shortfall to the other.
   That is the defect above, rebuilt inside its own repair.
2. **THE TWO LANES CANNOT CARRY THE SAME KIND OF FLOOR, AND SAYING SO IS THE
   POINT.** The anchor lane is seedless, so it carries per-vector floors on both
   quantities at their exact corpus minima (`accepted` = 64, the lattice's full
   width; `inside` = 3 for `boolean`, 13 for `boolean_normalize`). The generative
   lane **cannot carry a per-vector information floor at all**: 24 uniform draws
   over a box a region fills 3/64 of put **zero** probes inside in about a third
   of runs, and six of `boolean`'s vectors reach 0 at least once over 300 seeds.
   Any floor of 1 there would be flaky, **and a flaky floor gets lowered until it
   is vacuous.** So that lane carries a POPULATION floor only — and the
   exemption is **declared by name with the measurement**, in
   `checker.no_information_floor`, policed both ways, never an omitted key.
3. **A SEEDED LANE'S FLOOR IS DERIVED WITH A TAIL BOUND, NOT OBSERVED.** The
   generative population floor is 18 of 24, and the arithmetic is in the fixture:
   the refusal band is `2 x tolerance_points` = 0.002pt around every edge, so the
   per-probe refusal probability is bounded by
   `(total edge length x 0.002) / (sampling-box area)` — worst vector 0.001867 —
   giving `P(7+ refusals in 24 draws) <= 2.7e-14` per vector and `5.0e-13` across
   a run. Measured worst over 300 seeds: **one** refusal. The house rule *“declare
   the floor equal to the authored count”* is right for a deterministic
   population and wrong for a seeded one; a seeded floor is set where its tail is
   unarguable, and it says so.

The fixture-wide half is the same rule one level up: `min_checks_per_probe_lane`
is asserted per lane by the runner **and** by `--reconcile` (the report carries
`samples_by_probe_lane`), because `min_checks_per_lane` is their SUM and a sum is
paid by whichever half has it. Both numbers are derived — `per-vector floor x
min_rulable_vectors`, and the scalar is their total — and `_checker_config`
refuses a file where they disagree.

**This is instance 7 and instance 8 of the shape declared in
`transcripts/CHECKER_RESIDUAL.md`** (instances 1–5 were the CI-wiring gate; 6 was
F1 above). Same sentence with *CI* replaced by *the sample*: **a guard that
models its subject inherits every assumption the model makes.** The stopping rule
ratified with it — *fix an instance when it is cheap, declare the CLASS once, do
not hold a working instrument for the next member of a series with no last
element* — is why this section ends here rather than in a ninth rule.

## 4d. PHASE 3, THE PLUMBING PASS — what a family costs when nobody is arguing

Phase 3 added no checker. It added **WIRE**: nine algorithm families that had
no verb, no fixture and no manifest row, taking `ALGORITHMS` from **24 to 33**.
Every one is registered with a `checker_gap` that names **the law that is
available and unwritten**, never "no law exists" — which is the honest state
and the one §6.4 asks for.

**The estimate was 5.1 days and it was too high, for a reason worth keeping.**
Once the first verb existed the shape repeated: parse a fixture record, call
one public function, emit JSON. Seven of the nine were **near-identical** —
`transform_apply`, `paragraph_markers`, `hyphenator`, `simplify`,
`art_along_path`, `pattern_along_path`, `bristle_stroke` — and three of those
shared one helper apiece. Two were **bespoke**: `arrangement`, because the
returned point's **bit-exact identity** with an input endpoint is a contract a
tolerance cannot see and had to be reported as its own field; and
`dash_renderer`, because the answer is a list of sub-paths and the interesting
vectors are the ones where a dash straddles an anchor. **The cost is not in the
verb. It is in the hand-derived expectations** — and it is paid per *clause of
the spec*, not per family.

**Three things the pass measured that are worth more than the plumbing:**

1. **A hand-mirrored primitive can be right.** `arrangement` — the shared
   segment splitter under boolean, planar and normalize, whose whole assurance
   was 11 Rust tests and 11 Swift tests transcribed by hand — agreed on **24
   hand-derived vectors and 6000 fuzz pairs, exactly, including three branches
   no test in either port reached.** A negative result, and it is the one this
   phase most needed, because "never compared" was the reason to look.
2. **The divergence was in the arithmetic nobody thought of as an algorithm.**
   Rust's `f64::to_radians()` is `deg * (PI/180)`; Swift wrote
   `deg * .pi / 180`, which groups the other way. They differ by an ulp on
   **184 of 721 integer degrees**, and since MATRIXPRECISION writes `a/b/c/d`
   at full precision that reaches **the saved SVG bytes**. Two sites fixed
   (354 bit-mismatches → 0, 2957 Swift tests still green); the other 17 Swift
   sites are a declared gap. **No existing family could have seen it: every
   tolerance in the registry is 1e-4 or wider and the difference is 1e-16.**
3. **The S-4 class arrived a third time, and only the relational pass could
   see it.** Registering `dash_renderer` immediately reddened three vectors:
   its undashed fast path counted a leading `ClosePath` as drawable, so
   `Z M 5 5` returned one sub-path where `M 5 5` returned none — **in both
   ports identically**, exactly as `art_flatten` and `calligraphic_outline`
   had before it. Fixed in both. The lesson is not the bug, it is that
   **registering a family is what runs the relational passes over it**; an
   unregistered family is invisible to every instrument in this document, not
   merely to its own.

### 4d.1 THE TENTH FAMILY — `offset_path`, and what "unplumbable" was hiding

Phase 3 left **one** family declared rather than done: `offset_path`, the
Width Tool's variable-width stroke. Its reason was different in kind from the
other eight and worth stating, because it is the reason this programme exists.
It was not missing a fixture. **It had no values at all** — 299 lines of
`web_sys::CanvasRenderingContext2d` calls in Rust (gated behind `web` for that
one import, so a native build could not link it) and CGContext calls in Swift.
The rails and the caps were side effects on a raster surface. There was
nothing for a verb to serialise, therefore no comparison, therefore the two
ports' agreement about every tapered stroke the app draws rested on the two
files having been **typed to look alike**.

Splitting the GEOMETRY from the RASTERISATION is the whole fix, and it took
one sitting: `variable_width_outline_*` returns two rails and two caps as
numbers, `flatten_outline` turns that into the polygon the renderer fills, and
the three drawing functions keep the feature gate while the module loses it.
`ALGORITHMS` is 33 → **34**.

**Three things it measured, and the second is the one to carry forward:**

1. **A flagged divergence was ABSENT, and the flag was the wrong worry.** The
   ports handed the same numbers to `arc_with_anticlockwise(.., true)` and
   `addArc(.., clockwise: true)` across a CGContext y-flip. Measured — a real
   `CGMutablePath`, points read back with `applyWithBlock` — `clockwise: true`
   IS the decreasing-angle sweep, the same one WHATWG gives canvas for those
   arguments. (The canvas half stays a **spec reading**: there is no browser
   in `swift test`, and the file says so where it reports.)
2. **The defect was one level below the flag, in both ports identically.** The
   cap's base angle was `atan2(n_y, -n_x)` — the two arguments of the tangent
   the wrong way round, which is `pi/2 - theta`: the direction **REFLECTED**,
   not the direction. A reflection agrees on one axis and diverges by
   `2*theta` everywhere else, so every round cap was welded on at the wrong
   angle except at 135 and 315 degrees, where the two errors cancel. On a 10pt
   eastward stroke the arc began **7.07pt from the rail it was joined to** and
   the renderer bridged it with a chord. The square cap was always right,
   which is how a fumble looks next to a misunderstanding. **The proof is the
   shape of the failure, not the failure:** the three round-cap vectors were
   RED against hand-derived SVG geometry while **all eight port-vs-port
   comparisons were GREEN** — §4b's third row, live, in a family whose first
   day this was.
3. **The safest answer to "do these two platform flags agree" is to stop
   asking.** Both ports now flatten the cap through the same arithmetic
   (`CAP_ARC_STEPS`, carried on the wire as `default_arc_steps` so it cannot
   drift) and neither hands a sweep flag to a rasteriser. The measurement in
   (1) is knowledge worth keeping; the product no longer depends on it. Note
   what that cost, stated rather than buried: a cap is a 32-segment polyline
   now, not a platform arc, and the chord error is `r*(1-cos(pi/64))`.

**And what the family deliberately does NOT pin, because a golden that guesses
is worse than a gap.** SVG 11.4 defines `round` for a stroke with ONE width;
when the two rails sit at different distances from the spine, no semicircle
joins both, and the code takes the mean so the arc touches neither. Every
asymmetric-width vector here therefore carries a butt cap, and the question is
banked for JYH rather than answered by transcribing whichever mean the code
happens to take.

## 5. The generative lane (Seam 1 arm built in Phase 2 — read before extending it)

**What Phase 2 built, and what it deliberately did not.** The region families
sample from TWO lanes: an **anchor** lane (an 8x8 jittered lattice whose jitter
is a hash of the family and vector name and *nothing else* — seedless, so a red
is the same red on every machine and in every run, which is what a bisect
needs), and a **generative** lane (24 SplitMix64 draws per vector, freshly
seeded from `time.time_ns()`, the seed printed at the head of the checker pass
and carried in the checker report as `generative_seed`, replayable with
`JAS_PROPERTY_SEED=0x...`). Per-vector streams are derived
`splitmix64(run_seed XOR fnv1a("law|vector"))`, so replaying one family cannot
perturb another's draws — item 1 below, done. There is **no `JAS_..._CASES`
knob**: the counts live in the fixture and nothing can shrink them from an
environment variable, which is strictly safer than item 4 below and is why item
4 is still open for the Seam-2 lane only. There is **no stream pin**, and there
does not need to be one at Seam 1: the stream has ONE implementation, so there
is no second copy for it to drift from.

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

**If your law SAMPLES, it declares more, and none of them is optional.**

```jsonc
"min_accepted_per_vector":     { "anchor": 64, "generative": 18 },
"min_inside_probes_per_vector": { "anchor": 3 },
"no_information_floor": {
  "generative": "<the MEASUREMENT that makes a floor here flaky, by name>"
},
"min_checks_per_probe_lane":   { "anchor": 1216, "generative": 342 },
"empty_regions":  { "<vector>": "<why this region is empty BY CONSTRUCTION>" }
```

- `min_inside_probes_per_vector` — how many probes must land in the region being
  adjudicated. A floor on *accepted* probes counts the instrument's caution and
  reads `88 of 88` on a lane that asked nothing; see §4b lesson 4.
- **Every one of these is KEYED BY PROBE LANE and total over
  `pr.PROBE_LANES` in both directions** — see §4c. A lane with no floor is
  refused; a floor for a lane nothing draws is refused; a lane both floored and
  excused is refused; an excuse with no reason is refused.
- `min_checks_per_probe_lane` is **derived** (`per-vector floor x
  min_rulable_vectors`) and `min_checks_per_lane` must equal its sum. The file is
  refused if the two disagree.
- `empty_regions` is the by-name declaration for subjects that are empty by
  construction.

Keys a particular law needs beyond the generic block are declared in
`CHECKER_LAW_REQUIRED_KEYS`, so a fixture that omits one gets a **sentence
naming the missing floor** rather than a `KeyError` from the runner. A
**map-valued** `min_*` key whose name no rule reads is refused outright: the
scalar check skips dicts, so an unrecognised map is asserted by nothing while
reading as a floor.

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

**A mutant may be derived from the OUTPUT, not only from the input.** The
signature is `mutate(vec, out)` and the teeth are measured **inside the lane
loop, per lane**, against that lane's real output; `discriminating` in the
report is the WEAKEST lane's count, so one toothless lane cannot hide behind the
other's teeth. The reason is not convenience: `gradient_remap`'s bug is a bug of
ARITHMETIC and has an expression in the input alone, but `boolean`'s registered
bug — the pinch regression, *a multi-ring region emitted as one self-touching
ring* — is a bug of **ENCODING**, and an encoding bug has no expression that
does not mention the encoding it corrupts. It is also the mutant that proves why
a region law needs a STRUCTURAL half: on several vectors the concatenated ring
**samples correctly**, and only `every result ring is simple` refuses it.

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
- **THE SAME SHAPE ARRIVED THREE MORE TIMES INSIDE THE SAMPLED INSTRUMENT, and
  they are instances 6, 7 and 8 of ONE class, not three findings.** The
  modelled subject is *the sample* rather than *CI*, and the sentence is
  unchanged: a sampling box built from the output moves with the output (F1,
  §4b lesson 4); floors pooled over two lanes are paid by whichever lane has
  them (§4c); a lane recovered from a probe's index models the list's layout
  (§4c). **All three are fixed**, and the class — with what is still
  unclosed, what would falsify it, and the ratified STOPPING RULE that says to
  declare it once rather than write a ninth rule — is in
  `transcripts/CHECKER_RESIDUAL.md`. Two of the sampled instrument's own floors
  remain declared rather than closed, and are named there: the refusal test
  reads the OUTPUT's edges, and the information floors are derived from THIS
  corpus.
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
- **THE TWO F1 REMEDIES HAVE BOUNDARIES, AND THEY ARE DIFFERENT BOUNDARIES.**
  The **containment clause is exact but not general**: it is sound for these
  two shapes — a boolean of two operands, a canonicalisation of one — because
  each returns a subset of its inputs' union. A future family gets no free
  ride from it; it gets the *question* ("does this law's property admit an
  exact clause?"), which is the transferable part. The **information floor is
  general but blunt**: one scalar per fixture is bounded by the weakest
  vector, so `boolean`'s floor is **3**, set by
  `intersect_edge_shared_ring_pair_evenodd`, while the median vector carries
  17 and the strongest 27. It reds on a *collapse* and would not red on a
  vector quietly halving. A per-vector floor map would be tight and would also
  be a maintenance wall; if one is ever wanted, the number to key it on is the
  ANCHOR lane's count, which is the only seed-independent one.
- **THE REGION LAW IS GREEN ON THE CORPUS AND RED ON RANDOM INPUT, AND THAT GAP
  IS NOT YET ADJUDICATED.** A one-off fuzz (not wired to CI; 900 operand pairs
  built only from axis-aligned rectangles, right triangles and corner-cut
  pentagons on a 6x6 integer grid) had the law reject **153** of them on the
  clean tree — 46 by the membership clause, 92 by ring simplicity, 23 by
  laminarity. Two of those were minimised by hand into confirmed shared wrong
  answers (see the findings in the Phase-2 report; both ports agree, both are
  wrong, and independent Monte-Carlo integration over `spec/geometry/region.py`
  adjudicates them). The rest are **unclassified**: some are certainly the same
  class, and some may be the law over-claiming that a boolean RESULT'S rings are
  always simple, which `BOOLEAN.md` states of `canonicalize`'s output but nowhere
  states of the sweep's. **Do not widen the corpus with fuzz output until that is
  ruled**, and do not read the 153 as 153 defects.
- **`polygon_metrics` is now the SECOND membership sampler, not the only one.**
  `spec/geometry/region.py` answers the same question harness-side, importing
  nothing. It could replace both production copies
  (`jas_dioxus/src/algorithms/polygon_metrics.rs`,
  `JasSwift/Sources/Algorithms/PolygonMetrics.swift`) as the *harness's* oracle
  tomorrow — the migration is Phase 3, split out deliberately. What blocks it is
  not the instrument: (a) the ports' copies are called from inside
  `algorithm_roundtrip` to compute the `sample_points` and `area` that the
  goldens are expressed in, so retiring them means moving that computation
  harness-side and re-deriving every `area` golden through the new arithmetic;
  (b) `point_in_ring` is used by `hit_test`'s production path, not only by the
  harness, so one of the two copies is shipping code and cannot be deleted at
  all — only stopped from being the thing that grades itself; and (c) the
  `polygon_metrics` family's whole present value is that it pins the two
  hand-mirrored copies against each other, and nothing yet pins either against
  `spec/`. The cheap first step is a law on `polygon_metrics` itself
  (`spec/geometry/region.py` reproduces each pinned answer), which needs no port
  edit and closes (c).
- **The manifest is a wall.** It already prints 35 coverage gaps every run;
  `checker_gap` adds a second dimension. The bidirectional staleness check is
  the only thing keeping it honest. That is a maintenance cost, and it is stated
  here rather than discovered later.
