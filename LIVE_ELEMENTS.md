# Live Elements — the unifying model

**Status:** design proposed (2026-06-17) · **Scope:** the single abstraction under
which all non-destructive, parametric elements live · **Relationship to other docs:**
this generalizes the keystone in `VISION.md` §6.2 (stable identity + live graph) and
§6.3 (concepts as declarative packs); it sits on the reference graph built in
`REFERENCE_GRAPH.md` and the master/instance machinery in `SYMBOLS.md`; and it
depends on the operation-log spine (`VISION.md` §10 item 2), the
expression-language conformance corpus (§10 item 3), and the geometry-generator
extension that corpus gates (§6.3).

A naming note (as everywhere): this is a **vector illustration application**; we never
name a commercial product.

---

## 1. The one concept

> **A Live element is `inputs + parameters + a generator → re-evaluated output`,
> under one uniform evaluation contract. What differs between kinds is only *where
> the generator comes from*.**

This is the deepest reading of the recurring discipline in `VISION.md` §5: *the
document is always a source description evaluated against a context, never a baked
snapshot.* A Live element is exactly such a source description. The boolean compound
shape proved the pattern for one case; this model generalizes that single proven
pattern to every concept — including, crucially, concepts an artist authors by
demonstration with zero code.

The payoff of having **one** contract: a handful of pinned interpreter mechanisms,
with infinite *content* (concepts, recordings) layered on top as data — which is
simultaneously what an equivalent-five-apps architecture needs and what an
intent-assisting AI needs (`VISION.md` §4, "one road, not a fork").

---

## 2. The evaluation contract (uniform across all kinds)

Every Live element, regardless of kind, obeys the same contract. Today this is the
`LiveElement` trait (`jas_dioxus/src/geometry/live.rs` — `kind()`,
`kind_schema_version()`, `common()`, `fill()`, `stroke()`, `children()`,
`dependencies()`, `bounds()`, `expand()`, `release()` — mirrored in all four native
apps); the model below is its generalization.

What is genuinely **uniform** is the evaluation *signature* and *result type*, graph
membership, the op-log edit surface, and `expand`/`release`. What is **per-provenance**
— and must be pinned separately by fixtures — is *purity*, *id-minting*, and
*partial-failure* semantics: native and declared generators are pure functions;
a recorded generator replays an op-trace and so mints ids and carries intrinsic order.
The one failure rule that **is** uniform: any generator that cannot complete (a cycle,
a dangling input, a failed op in a trace) yields an **empty** result atomically — never
a panic, never partial geometry (`REFERENCE_GRAPH.md` §3). `kind_schema_version()` is
the seam the future named-parameter schema (§6) hangs off.

- **Inputs** — element-valued sources, in two channels that already exist:
  - **owned** inputs (containment), exposed via `children()`; and
  - **by-id references** (`dependencies()`), naming elements elsewhere by stable
    `common.id`. The by-id channel is what makes liveness cross-tree and many-to-many
    (`REFERENCE_GRAPH.md`); the containment channel is the compound-shape style.
- **Parameters** — the values that tune generation. *Today there is no generic
  parameter bag* — params are kind-specific struct fields (the boolean op enum; a
  reference's instance transform + paint overrides). The generic, named, schema'd
  parameter set is the new thing this model introduces (and what the gear needs).
- **Generator** — the function `(inputs, parameters, context) → output`. Its
  *representation* differs by kind (§4); its *signature* does not. **`context`** is the
  ambient evaluation input not owned by the element: tessellation precision/tolerance
  today, and a global animation cursor `t` when `VISION.md` §6.8 lands (time is the
  intended future context input; edit-time and playback-time stay separate and frame
  state never bakes into the document — the timeline machinery is scoped to §6.8).
- **Output** — the evaluated geometry/elements, re-derived on demand and **never
  baked into the document**. The Live element **node** carries its own stable
  `common.id` so *its* downstream references stay live; the evaluated output is
  addressed through that node, not as N independently-referenceable elements
  (sub-element identity is the frontier, §4). (Output may be multi-element — see L6.
  The separate, identity-*dropping* `expand` verb is the only path that materializes
  output as document elements, and today `CompoundShape::expand` copies one `common`,
  id and all, into every output ring, so multi-ring expand must mint fresh per-element
  ids — a real follow-up, `live.rs` `expand`.)
- **Graph membership** — a Live element is a node in the dependency graph
  (`deps`/`rdeps`/`dangling`/`cycles`/`topo_order`, `REFERENCE_GRAPH.md` §2.6).
  Recompute is **intended** to follow `topo_order` once an incremental scheduler is
  wired; **today** eval recurses with an `Rc::as_ptr`-keyed cache (the P4c recompute
  cache is keyed on `(target_id, precision)`, not a topo walk) and `topo_order` is
  computed/serialized but has **no production consumer yet** (`REFERENCE_GRAPH.md`
  §2.6). Cycles and dangling inputs break to an empty result at eval, never a panic.
- **Edit surface** — inputs and parameters are mutated **only** through the operation
  log (`VISION.md` §10 item 2). "Change a parameter" is just a transaction; so is
  "rebind an input." There is no privileged mutation path — which is also what makes
  the AI a peer producer of the same operations (§6.1/§6.10). This is the **target**
  contract: the op-log is not built and Rust still has two effect runners, so
  single-path mutation depends on the §11d "consolidate to one mutation path" work.
- **Un-live verbs** — `expand` (bake the current output to static geometry, dropping
  liveness) and `release` (restore the source inputs as independent elements). They
  exist on the trait but are **fully implemented only for CompoundShape today**:
  Reference's `expand`/`release` are no-op stubs until the resolver-aware expand path
  lands (`live.rs`), and OCaml exposes them as `compound_shape`-specific free
  functions rather than variant-dispatched methods. Each new provenance must define
  them — in particular, what `release` means for a **recorded** element (whose source
  is an op-trace, not owned operands) is undefined and needs specifying.
- **Constraints (optional)** — the fourth leg of the `VISION.md` §6.3 quadruple
  (fitter + generator + operations + **constraints**). A declared concept may carry
  invariants its parameters must preserve. The **v1 position**: what ships is forward,
  one-way DAG recompute; a declared invariant is a *generator-side check* that, when
  violated, breaks-to-empty or flags a conflict (it never silently produces wrong
  geometry). Bidirectional constraint **solving** (IK, mutual constraints) is a
  separate, harder layer and is scoped **out** (`VISION.md` §6.2, §7) — the one-way
  DAG covers most cases.
- **Equivalence rule** — cross-language equivalence is pinned on the **output**
  (the resolved geometry / element tree), never on the generator's internal
  representation or any per-app cache. This **generalizes** the `REFERENCE_GRAPH.md`
  §2.3 cache-equivalence rule (and `VISION.md` §3's same-results-not-same-pixels law)
  from `resolve()` results to every generator's output, which is what lets the
  generator representation differ per app where useful while staying observably
  identical.

---

## 3. Generator provenance — the only axis that varies

The kinds of Live element differ in exactly one way: **where the generator comes
from.** Four provenances:

| Provenance | Generator is… | Authored by | Parameters | Deterministic at runtime? |
|---|---|---|---|---|
| **Native** | hand-coded function, in all four native apps (Flask has no geometry/live core) | the core team | fixed struct fields | yes |
| **Recorded** | a captured op-segment, replayed | demonstration ("watch what I do") | the trace's free variables | yes — *if* replay outputs are id-stable and the op subset is side-effect-free (§4) |
| **Declared** | a parametric recipe in the expression language | a concept pack (team / community / AI) | a declared, named param list | yes |
| **Inferred** | *not a runtime kind* — see §5 | the AI **fitter** | inferred | the fitter is offline; its **output** is one of the three above |

The two Live kinds that exist today are both **native**:

- **CompoundShape** — generator = the boolean algorithm; inputs = owned operands;
  parameter = the operation enum (union/intersect/subtract/exclude). `release`/
  `expand` are its un-live verbs.
- **Reference** — generator = "resolve the target, compose the instance transform";
  input = one by-id target; parameters = instance transform + paint overrides. A
  Symbol instance *is* a Reference (`SYMBOLS.md`).

**Recorded** and **Declared** are the two new provenances this model adds. They are
how breadth arrives without new native code.

---

## 4. The recorded (history-based) provenance

This is the novel, artist-direct provenance, so it gets its own section.

**Idea.** Given an *ancestor* state and the *current* state, the slice of the
operation log between them is a recipe. Promote that op-segment into a Live element
whose generator is "replay these operations against the current inputs." A
demonstration becomes a live relationship.

> Example: the artist says "watch what I do," selects an eye in a portrait, copies it,
> reflects the copy, and moves it into place. We capture `copy(eye) → reflect → move`
> as a recorded generator with the original eye as its input. Edit the original eye
> and the reflected copy re-derives live.

This is **history-based parametric modeling** — the proven paradigm behind
feature-history CAD — applied to 2D illustration. That precedent both validates the
idea and warns us where it gets hard (below).

**Why the op-log spine is the prerequisite.** A recorded generator is only sound if
replay is a pure, deterministic function of its inputs:

- Ops must reference inputs by **stable `common.id`**, not by value or by
  tree-path-at-capture — so "copy element X" means "copy whatever X *is now*."
  (Stable identity, `VISION.md` §10 item 1, is shipped; this is what unlocks it.)
- Replay must be deterministic, with one subtlety the rng seam does **not** give for
  free: `REFERENCE_GRAPH.md` §4 mints ids non-deterministically (pinned per-app, not
  by a shared fixture), so a recipe that *minted fresh* output ids on every replay
  could not keep stable output identity, and downstream liveness would break. So a
  recorded generator's **output ids must be derived deterministically** from
  (the Live element's own id + a position-in-trace counter), not minted from the rng
  seam. "Sorted-id ordering" (the `VISION.md` §8 trap) governs only *set-valued
  recompute* order; the trace's own op order is intrinsic and replayed verbatim. No
  hidden tool/selection state: selection-relative ops (`select_rect` then
  `move_selection`) are normalized to a closed, input-addressed form
  (`move([those ids])`) at capture.
- The recorded generator draws from a **replay-safe subset** of the same op
  vocabulary — input-addressed, side-effect-free, and with **no op that mutates
  another Live element's generator** (that is what prevents generator-level cycles the
  dependency-graph cycle-break does not catch; such an op is rejected at capture). So
  it is one vocabulary used at two levels — the edit surface for all Live elements,
  and a restricted generator language for the recorded kind — not the *full* vocabulary
  in both (this resolves what was fork L5).
- One recorder, three consumers: the normalized op-segment behind a recorded generator
  is the **same artifact** captured for `VISION.md` §9-regime-2 replay fixtures and
  labeled for §6.9 versioning. The determinism + id-addressing requirements here are
  therefore shared infrastructure, not recorded-generator-specific.

**The hard part: trace → function.** A recording is concrete ("reflect about
x=412.7", "move by (37, −12)"). A reusable generator must know which arguments are
**inputs** (track the original), which are **bound constants**, and which are
**derived** (recompute relative to the input). The trace alone cannot tell you;
only intent can.

- **Deterministic MVP (buildable, `VISION.md` §7 buildable tier):** the artist marks
  the input(s) (or we infer "the first element the segment reads"); everything that
  traces to that input is rebound by id; everything else stays a literal constant.
  Predictable default — reflected *geometry* updates live, the *placement* stays put.
  This ships the eye example with no AI.
- **Fitter upgrade (frontier, §7):** detecting which constants *want* to be relative,
  or extracting named parameters from a trace, is the AI-assisted "fitter" (§5).

**The boundary to respect: the topological-naming problem.** In feature-history
modeling the worst bug class is a recipe that references a *sub-element* ("this edge,"
"anchor point 3") which an upstream edit silently rebinds or invalidates. Stable ids
solve this at the **element** level (we have them); they do **not** yet exist for
sub-element entities (anchor points, path segments). So **element-granularity
recorded recipes (the eye — a whole element) are safe now; control-point-granularity
recipes are the frontier** and define the natural v1 boundary.

---

## 5. Authoring vs. runtime — and why the AI never breaks equivalence

The four provenances split across two layers:

```
AUTHORING (how a Live element is born)        RUNTIME (in the 4 native apps; Flask has no geometry core)
  fitter:                                       Live element = inputs + params + generator → output
    deterministic  (compound make,                generator ∈ { native | recorded | declared }
       trace capture, curve-fit, repeat        ─►  one eval signature · one dependency graph
       detection)                                  one op-log edit surface · expand / release
    AI / fuzzy     ("this is a gear";              equivalence pinned on OUTPUT
       infer relative params)
```

The **fitter** (`VISION.md` §6.3) is "raw selection → parameters/roles" — the dual of
`release`/`expand`. It is what *produces* a Live element. It may be deterministic
(the existing compound-shape "make"; trace capture; curve fitting) or AI/fuzzy.

The key invariant: **"AI-inferred" is not a runtime generator kind.** The AI never
*is* a generator at evaluation time (that would be non-deterministic and unpinnable,
and would violate artist primacy). The AI runs the *fitter* offline and produces a
**deterministic Live element of one of the three runtime provenances** — e.g. "this
trace is really a gear with `tooth_count=12`" (→ a Declared element) or "these
constants should be relative" (→ a parameterized Recorded element). The fitted result
then runs deterministically like any other and is pinned like any other. You pin the
*committed result*, not the model (`VISION.md` §6.1). This keeps the deterministic
core, equivalence, and artist primacy (§6.10) intact by construction.

The **freezing invariant** that makes this airtight: the fitter runs **once, at
authoring**, and bakes *literal* parameter values + a *frozen* recipe/concept id into
the Live element. A parameter may never be a deferred model call resolved at eval time,
and the generator never consults the AI during recompute. "Re-fit on upstream edit"
(re-run the gear fitter when the input changes shape) is desirable, but it is a
**re-authoring transaction** — a new committed op the artist accepts — not eval-time
inference. So the runtime stays a pure, pinnable function even for AI-authored elements.

---

## 6. The data-model rule: closed mechanisms, open content

Openness lives in **data and recordings, not in new enum arms.**

- Keep a **small, closed set of generator *mechanisms*** — the native variants we
  have, plus `recorded` and `declared` — where `declared` is parameterized by a
  concept-pack id. So **N concepts = 1 enum arm + N data packs**, not N arms in five
  languages. A recorded generator is likewise *data* (a normalized op-segment), not a
  new arm.
- This is "breadth becomes content, not releases" (`VISION.md` §6.3) and the
  pin-the-interpreter discipline (`VISION.md` §4): a few interpreter mechanisms pinned
  by shared conformance fixtures, with infinite content authored on top by the team,
  the community, or the AI.

(Terminology: a `LiveVariant` **arm** is a concrete representation in the enum; a
**provenance** is where a generator comes from. The two `recorded`/`declared` arms
this model adds carry *all* recorded recipes and *all* declared concepts respectively
— so "1 arm + N data packs" and "adds two arms" are consistent.)

**Unify the signature; sum-type the representation.** The provenances genuinely differ
(recorded = an imperative trace with the abstraction/topological-naming problem;
declared = a pure expression; native = opaque code). Do not force them into one
representation. `LiveVariant` is already a closed enum of arms; this model adds two
arms — one of which (`declared`) is open via data — without making the abstraction a
god-object.

**Multiple simultaneous interpretations / "lenses"** (`VISION.md` §2.4/§6.4) fall out
of this model with no new machinery: overlapping interpretations are simply **N Live
elements that share the same by-id inputs**; their mutual coherence is the dependency
graph (edit a shared input, every interpretation re-derives); and "editing through one
lens at a time" is editing one Live element's parameters while the others recompute.
The *lens UX* — choosing which interpretation is in focus, surfacing conflicts — is
out of scope here and tracked in `VISION.md` §6.4; the *substrate* it needs is exactly
this model.

---

## 7. Dependencies & sequencing

This model is a destination; it lands in dependency order on foundations, some
shipped and some not:

1. **Stable identity** — ✅ shipped (`common.id`, all four native apps; Flask has no
   element model). Prerequisite for both recorded recipes (rebind by id) and any
   cross-tree liveness.
2. **The live dependency graph** — ✅ shipped (`REFERENCE_GRAPH.md`:
   deps/rdeps/dangling/cycles/topo_order, incremental + cached recompute). The
   evaluation/graph substrate every kind rides.
3. **The operation-log spine** — ⬜ not started (`VISION.md` §10 item 2). The
   prerequisite for the **recorded** provenance (it is the generator language) and
   for param/input edits as transactions. This model **imposes a constraint** on the
   as-yet-undesigned op-log: when it is designed, op operands **must** be id-addressed
   (not tree-path-keyed), because a path-keyed recipe breaks the instant an input is
   edited. Flag this as a requirement LIVE adds, not an existing guarantee.
4. **The expression language + conformance corpus, then geometry generators** —
   🟡 partial / ⬜ (`VISION.md` §10 item 3, §6.3). The prerequisite for the
   **declared** provenance: the language already has arithmetic, `sqrt`/`hypot`/
   `min`/`max`/`abs`, and `map`/`filter`/`any`/`all` over existing lists, but it
   cannot **synthesize** a sequence (no `range`), has no `fold`/`reduce`, and no trig
   (`sin`/`cos`) — so a gear cannot be data yet. Pin the language cross-app (it gates
   Python only today) before extending it.
5. **Sub-element identity** — ⬜ not started. The prerequisite for
   control-point-granularity recorded recipes (the topological-naming frontier, §4).

---

## 8. What is shipped vs. vision (be honest)

- **Shipped:** the uniform contract exists as the `LiveElement` trait with two
  **native** kinds (CompoundShape, Reference), the dependency graph, incremental +
  cached recompute, `expand`/`release` (CompoundShape only), and stable identity —
  pinned across the four native apps via shared `live_compound` / `live_reference` /
  `dependency_index` fixtures (Flask has no geometry/live core).
- **Not built:** a generic named-parameter bag; the **recorded** provenance (needs
  the op-log spine); the **declared** provenance and concept-pack runtime (needs the
  expression-language extension); the **fitter** beyond the existing deterministic
  compound "make"; the AI authoring path; sub-element identity.

This model does not claim any of the unbuilt pieces exist; it states the single
abstraction they all conform to so they are additive, not a rewrite.

---

## 9. Open forks

| # | Fork | Options | Lean |
|---|---|---|---|
| L1 | Generic parameter representation | (a) a typed per-kind struct; (b) a generic named-value map with a declared schema | (b) for declared/recorded (open content); (a) stays for native |
| L2 | Where a recorded op-segment is stored | (a) inline on the Live element; (b) in a shared recipe store keyed by id (reused across instances) | (b) if recipes are reused like Symbol masters; (a) for one-offs — decide with the Symbols store as precedent |
| L3 | Recorded-recipe input marking | (a) artist explicitly marks inputs; (b) infer "first element read"; (c) AI fitter | (b) default + (a) override for the MVP; (c) is the upgrade |
| L4 | Constant vs. relative default for recorded params | (a) all constants (placement stays put); (b) infer relative | (a) predictable MVP; (b) via the fitter |
| L5 | Recorded generator: full op vocabulary or a subset? | (a) full vocabulary; (b) a pure, replay-safe subset | **Resolved in §4 → (b):** only deterministic, input-addressed, side-effect-free ops (no op that mutates another Live element's generator) are recipe-eligible; rejected at capture otherwise. Kept here for the record. |
| L6 | Output cardinality | (a) a Live element produces one geometry; (b) it may produce N output elements (e.g. a forest generator) | (b) eventually — but then `expand` must mint fresh per-output ids (§2 Output), and sub-element/per-output identity is the frontier (§4). Start with single-output kinds. |
| L7 | Declared-pack constraint representation | (a) invariants as expression-language predicates checked at eval; (b) a richer constraint DSL | (a) to start (rides the same language as the generator); defer (b). Depends on the unstarted expression-language extension (§7 item 4). |

---

## 10. Risks

- **Trace abstraction is the crux, not the mechanism.** Record-and-replay's
  *mechanism* is straightforward; its *correctness* depends entirely on an op-log that
  does not yet exist and must be built with id-addressed, side-effect-free, atomic,
  deterministic-output-id semantics from the start (`VISION.md` §10 item 2, not
  started — undo is currently whole-document snapshots). And deciding what is
  parametric is the hard, partly-AI part. Mitigate by shipping the deterministic MVP
  (marked inputs, constant defaults) first and treating richer abstraction as frontier.
- **Topological naming.** Sub-element references in recipes will rebind wrongly under
  upstream edits until sub-element identity exists. Mitigate by bounding v1 to
  element-granularity recipes and saying so loudly.
- **Op-log correctness is load-bearing three times.** A non-deterministic or
  path-keyed op-log makes recorded **generators**, replay **fixtures** (`VISION.md` §9
  regime 2), and **versions** (§6.9) all silently wrong — they share one artifact. The
  op-log forks (id-addressing, determinism seam, deterministic output ids, atomic
  transactions) must be settled *with all three uses in mind*.
- **God-object risk.** Over-unifying the representation would make the abstraction
  brittle. Mitigate with "unify the *signature*, sum-type the representation" (§6) —
  purity/id-minting/partial-failure are pinned per provenance, not assumed uniform.
- **Equivalence drift.** Per-app generator/cache differences are allowed only because
  equivalence is pinned on the *output*. Every new kind must ship with shared
  output-level conformance fixtures before it is trusted (the §2.3 rule), or it
  re-creates the "dead-but-green" failure mode `VISION.md` §4 warns about.
