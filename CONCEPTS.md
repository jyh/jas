# Concept Packs — domains as declarative data

**Status:** increments 1–2 + 3a built, **3b: the `LiveVariant::Generated` document arm is ported
to all four apps** — the generator engine + format + cross-language gate (`regular_polygon`,
`spiral`, `star`, `gear`, the §6.3 flagship), the `floor`/`mod` parity primitives, the concept
**registry** (concepts bundled into `workspace.json`, loadable in every app), and the Generated
arm (model + eval + codecs + tests) in **Rust, Swift, OCaml, and Python** — pinned by a shared
cross-language round-trip golden (`expected/generated_polygon.json`, byte-identical across all
four through both test_json and binary). Remaining on 3b: sibling render-resolver wiring (Rust
done; Swift/OCaml/Python pending); a creation action. The fitter, operations, and constraints
follow (§7). · **Implements:** `VISION.md`
§6.3 ("domains as declarative packs") and closes its named "decisive gap" — the
expression language can now *generate* geometry, so a parametric concept is data.
· **Builds on:** the geometry-generator functions (`sin`/`cos`/`tan`/`pow`/
`range`/`fold`) pinned by the expression conformance corpus (`SCHEMA.md`
Expression Language; `VISION.md` §10 item 3).

A naming note (as everywhere): this is a **vector illustration application**; we
never name a commercial product.

---

## 1. What a concept is

A **concept** (gear, polygon, eye, connector, hatch, …) is *data, not native
code* — the §6.3 vision. Per `VISION.md` §5.3 it has four parts:

1. a **generator** — parameters → geometry (this increment);
2. a **fitter** — raw selection → parameters/roles (the "promote" dual of
   `release`/`expand`; deferred);
3. **operations** — its edit verbs (deferred);
4. **constraints** — its invariants (deferred).

The discipline is the recurring one (`VISION.md` §5): a concept instance is a
**source description evaluated against a context**, never a baked snapshot. The
generator is that source; the parameters are the context; the geometry is the
evaluation.

---

## 2. The locked decisions

| # | Fork | Decision |
|---|------|----------|
| 1 | What is a generator? | **An expression**, in the existing language, evaluated with the concept's parameters bound under the `param` namespace (already a runtime-context namespace). No new evaluator — concepts ride the engine extended for `VISION.md` §6.3. |
| 2 | Generator output shape | **A list of `[x, y]` points.** Maps directly onto `PolygonElem.points` (`Vec<(f64,f64)>`) — the `regular_polygon_points` precedent already returns exactly this, so no new geometry machinery and instant cross-language serialization (`points_json` → `[[x,y],…]`). A per-concept `closed` flag selects polygon (closed) vs polyline (open). Richer outputs (subpaths, curves, multi-element) are a later generalization. |
| 3 | Where concepts live | `workspace/concepts/*.yaml`, one file per concept — the same authored-data discipline as `workspace/tools/*.yaml` and `workspace/panels/*.yaml`. |
| 4 | How the engine is pinned | A shared conformance corpus (`workspace/tests/concepts.yaml`) compiled to `test_fixtures/concepts/conformance.json` and self-checked in all five apps — exactly the expression-corpus pattern. Concept evaluation == "bind params, evaluate the generator expression, read the points", so the gate reuses the expression evaluator each app already has. **No app-evaluator code changes in increment 1.** |
| 5 | Document integration timing | **Engine first, wire later.** Increment 1 pins the generator semantics with zero document/UI coupling (`VISION.md` §4: "don't chase features; pin the interpreter"). A concept *instance* becomes a `LiveVariant::Generated { concept_id, params }` arm in a later increment (§6). |

---

## 3. The concept-pack format (v1)

`workspace/concepts/<id>.yaml`:

```yaml
id: regular_polygon
name: Regular Polygon
# Comprehensive, human-readable English (the workspace convention).
description: >
  A regular N-sided polygon centered on the origin, with the first vertex on
  the +x axis. `sides` vertices are placed at equal angular steps of 360/sides
  degrees on a circle of radius `radius`.
params:
  - { name: sides,  type: number, default: 6 }
  - { name: radius, type: number, default: 50 }
closed: true            # the point list forms a closed polygon (vs an open polyline)
generator: |
  map(range(0, param.sides), fun i ->
    let a = 360 * i / param.sides in
    [param.radius * cos(a), param.radius * sin(a)])
```

- **`params`** — each `{name, type, default}`. `type` is `number` in v1 (the
  field exists so non-numeric params are addable later). Defaults make a concept
  instantiable with no arguments.
- **`generator`** — an expression that reads `param.<name>` and evaluates to a
  list of `[x, y]` points. Uses only the shared, corpus-pinned language; trig is
  in **degrees** (`SCHEMA.md`).
- **`closed`** — `true` ⇒ the points close into a polygon; `false` ⇒ an open
  polyline (e.g. a spiral).

Concepts shipped: **`regular_polygon`** (closed) and **`spiral`** (open) in
increment 1; **`star`** and **`gear`** (closed; the §6.3 flagship) in increment 2,
once the `floor`/`mod` parity primitives landed.

---

## 4. The conformance gate

`workspace/tests/concepts.yaml` — cases reference a concept by id, override
params, and pin the expected geometry:

```yaml
tests:
  - concept: regular_polygon
    params: { sides: 4, radius: 10 }
    expected: [[10, 0], [0, 10], [-10, 0], [0, -10]]
```

`scripts/compile_concept_corpus.py` resolves each case against its concept file
(inlining the generator expression and merging param defaults with overrides)
into a self-contained `test_fixtures/concepts/conformance.json`:

```json
{ "concept": "regular_polygon", "generator": "<expr>",
  "params": { "sides": 4, "radius": 10 }, "closed": true,
  "expected": [[10,0],[0,10],[-10,0],[0,-10]] }
```

`scripts/check_concept_corpus.sh` is the freshness gate (mirrors
`check_workspace_json.sh`). Each app's `cross_language_test` loads the JSON,
binds `params` under `param`, evaluates the inlined generator with its own
expression evaluator, reads the resulting points, and compares to `expected`
component-wise within **1e-9** (the same tolerance the expression corpus uses;
trig results are not exact). Point **count** is part of the contract.

Because a generator is an expression, this gate is a thin specialization of the
expression conformance gate — it inherits the same cross-language guarantee.

---

## 5. Determinism & equivalence

Evaluation is a pure function of (concept generator + parameter values), so it is
deterministic and replayable (`VISION.md` §8). The only cross-language subtlety
is floating-point trig, handled by the 1e-9 tolerance — already validated by the
expression corpus. Recompute order is intrinsic to the generator's `range`/`map`,
not hashmap order, so the §8 determinism trap does not apply.

---

## 6. Keep-ready — the deferred integration (designed, not built)

A concept *instance* in a document is a parametric live element. It fits the
existing `LiveElement` framework as a fourth `LiveVariant` arm, alongside
`CompoundShape` / `Reference` / `Recorded` (`live.rs`):

```
LiveVariant::Generated { concept_id: String, params: <json map>, common }
```

- **Evaluation** plugs into the single `evaluate_with(precision, resolver,
  visiting)` seam: resolve the concept by id, bind `params`, evaluate the
  generator, turn the points into the output geometry. (`Generated` has no by-id
  inputs, so the `resolver` is unused — simpler than `Recorded`.)
- **Serialization** mirrors `Recorded`: `type: "live"`, `kind: "generated"`,
  with `concept_id` + a canonical-JSON `params` map on the wire (binary slots
  8/9; test_json keys; SVG emits the evaluated geometry like `CompoundShape`).
- **Touch points** per app: the `LiveVariant` enum + the `LiveElement` trait
  methods + the eval dispatch + the three codecs, propagated Rust → Swift →
  OCaml → Python.

This needs a per-app **concept registry** (load the concepts from the compiled
`workspace.json`). **Increment 3a — ✅ done:** the loader now bundles
`workspace/concepts/*.yaml` into `workspace.json` under a `concepts` key, and every
app exposes a `concept(id)` accessor (Python `loader.concept`, Rust/OCaml/Swift
`Workspace*.concept`), each with a load test that resolves a concept and evaluates
its generator to geometry. The `Generated` element arm (3b) builds on this.

---

## 7. The increment plan

1. **Generator engine + format + cross-language gate (this increment).**
   `regular_polygon` + `spiral`; no document coupling.
2. **Parity primitives + gear/star — ✅ done.** `floor(x)` and `mod(a, b)` (the
   floored `a - b*floor(a/b)`, defined identically in every interpreter rather than
   the host `%`, whose sign convention differs) were added to the math family and
   corpus-pinned; `star` and `gear` are authored and gated across all five apps.
   This completed the `VISION.md` §6.3 flagship example as data.
3. **Concept registry + the `LiveVariant::Generated` arm (§6).** (a) ✅ **done** —
   the registry: concepts compiled into `workspace.json` + a per-app `concept(id)`
   accessor, each with a load-and-evaluate test (increment 3a). (b) the `Generated`
   element arm so a concept instance lives in a document, renders, round-trips, with
   editable parameters (the live "tune the same parameters without redoing anything"
   of §6.4). **Rust lead ✅:** the `GeneratedElem` model, the 13 `LiveElement` dispatch
   methods, `evaluate_with` (concept resolved via a registry-extended `ElementResolver`
   → generator → points → geometry), the test_json/binary/SVG codecs, and round-trip +
   eval tests. **All four apps ✅** — Swift (inline-common `RecordedElem` layout), Python
   (`LiveElement` dataclass + class-based resolver), and OCaml (a `concept_resolver` closure
   `string -> (params -> points) option`, since `lib/geometry` can't import the evaluator — the
   caller builds it, geometry stays decoupled). All pinned by the shared golden
   `expected/generated_polygon.json` (byte-identical through test_json and binary).
   **Remaining:** wire the production render-resolver to the registry (**Rust ✅** —
   `RenderResolver.resolve_concept` reads the cached `Workspace` registry, so a `Generated`
   instance evaluates its concept's geometry on the canvas render path; Swift/OCaml/Python
   pending); and a
   creation action/UI. (SVG `data-jas-params` is not byte-compared by any fixture; its
   serialization stays per-app-native.)
4. **Operations.** A concept's edit verbs (e.g. "set tooth count"), as
   `actions.yaml`/op-log operations on the instance's `params`.
5. **The fitter (`promote`).** Raw selection → parameters/roles — the deterministic
   tier first (geometric heuristics: a regular polygon detector), the fuzzy/AI
   tier later (`VISION.md` §7 frontier).
6. **Constraints.** A representation for a concept's invariants (deterministic, no
   JS — `VISION.md` §6.3 downside), and a checker. Bidirectional constraint
   solving (IK) stays the separate, harder layer (`VISION.md` §6.2).

---

## 8. Risks

- **Generator output is points-only in v1** — curves (a gear with rounded teeth)
  and multi-element concepts need a richer output shape; designed as a later
  generalization of decision 2, not a rewrite.
- **Float equivalence** — trig across libms; mitigated by the 1e-9 tolerance the
  expression corpus already proves out. Keep concept expected-values clean.
- **The corpus inlines generators** — until increment 3's registry, the concept
  files are exercised only by the compile step, not loaded by any app. State this
  so no one assumes runtime concept loading exists yet.
- **No constraint representation yet** — the §6.3 downside is real and unbuilt;
  v1 concepts are pure generators with no invariants.
