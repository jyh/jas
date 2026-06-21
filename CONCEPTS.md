# Concept Packs — domains as declarative data

**Status:** increments 1–2 + 3a + 3b built — the generator engine + format + cross-language gate
(`regular_polygon`, `spiral`, `star`, `gear`, the §6.3 flagship), the `floor`/`mod` parity
primitives, the concept **registry**, the **`LiveVariant::Generated` document arm** (model + eval
+ codecs + tests) in all four apps (golden-pinned, byte-identical through test_json and binary),
and **Concepts-panel Slices 1 AND 2 functional end-to-end in all four native apps**: open Concepts →
select a concept → Place → a default-param `Generated` instance is placed and renders; then **select
it and edit its parameters in the panel and the geometry re-generates live** (the §6.4 parametric
heart). Slice 2 = the dual-mode panel (registry list when nothing is selected; the selected
instance's editable params otherwise) driven by `active_document.selected_concept` + the native
`set_concept_param` effect (find the single selected `Generated`, write `params[name]=value`, one
undo), in Rust/Swift/OCaml/Python, each with a controller + view test mirroring the same fixtures.
Flask exposes the registry list and both panel foreaches but has no interactive editor (its legacy
server renderer can't interpolate loop-var text). Remaining: operations, the fitter, constraints
(§7); an `op_apply` replay arm for `place_concept_instance`/`set_concept_param` (parity, no fixture
exercises it yet). · **Implements:** `VISION.md`
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
   The render-resolver wiring is done in all four apps (each production resolver reads the cached
   `Workspace` concept registry, so a `Generated` instance draws its geometry on the canvas). The
   creation action is a **Concepts panel** modeled on the Symbols panel: a registry-driven list +
   a Place Instance action that appends a default-param `Generated` element. **Slice 1 is complete
   end-to-end in all four native apps** — `workspace/panels/concepts.yaml`, the `concepts_panel_select`
   (generic) + `place_concept_instance` (native, id value-in-op, one undo) actions, the Window-menu
   entry, `data.concepts` exposed per app, and the native place effect + render wiring — open
   Concepts → select → Place → it renders. (Flask exposes the list but has no interactive editor.)
   **Slice 2 is also complete end-to-end in all four native apps** — the dual-mode panel
   (`bind.visible` on `active_document.selected_concept`: registry list when null, the selected
   instance's editable params otherwise), the `active_document.selected_concept` view field
   (`{concept_id, name, params:[{name,value,min,max}]}` — registry schema merged with instance
   values; null unless exactly one `Generated` is selected), and the native `set_concept_param`
   effect (find the single selected `Generated`, write `params[name]=value`, one undo via the
   self-bracketing controller). The param field's committed value is injected as `event.value` by a
   `behavior: [{event: change, action: set_concept_param}]` block — wired in each app's
   `number_input` commit path (Rust's widget framework already dispatched `change`; Swift/OCaml/Python
   needed the commit-time dispatch added). Each app carries a controller test
   (`set_concept_param` updates the param in place) and a view test (`selected_concept` present for a
   single selected `Generated`). Closing Python's Slice-1 gap, the `place_concept_instance` panel
   action — which had only a controller method, never a native panel-dispatch arm — is now
   intercepted natively too (`concepts_apply.py` + a `_dispatch_concepts_action` arm).
   **The `op_apply` replay arm is done in all four native apps** — both verbs now route their
   native handler through `op_apply` inside the one-undo bracket (so the LIVE action JOURNALS a
   real `PrimitiveOp`, value-in-op: concept id + resolved default params + minted id for place;
   path + name + committed value for set), with matching replay arms next to `place_instance`.
   Each app carries a focused checkpoint_equivalence test (place a hexagon + tune sides 6→8 →
   the journal replays byte-identically to the live snapshot, twice). Document state is unchanged
   (same controller calls); only the journal gains the replayable entry. (SVG `data-jas-params`
   is not byte-compared by any fixture; its serialization stays per-app-native.)
4. **Operations — ✅ done (all 4 native apps).** A concept's named edit verbs
   (`add_tooth`/`remove_tooth` on gear, `add_side`/`remove_side` on polygon),
   declared in the pack as `set:` expression transforms of the instance's
   `params` and journaled as the single op-log verb `apply_concept_operation`
   (effect RESOLVED value-in-op at production time; replay merges, never
   re-evaluates). Pinned by the operations conformance corpus + a checkpoint_
   equivalence replay test per app; the Concepts panel renders a button per
   operation. **Detailed design + the conformance gate: §9.**
5. **The fitter (`promote`) — ✅ done (all 4 native apps).** Raw selection →
   parameters/roles via a regular-polygon detector. A fitter is an **expression**
   (the dual of the generator) over a `shape` namespace, needing one new builtin
   `atan2`; `promote_to_concept` replaces a raw Polygon/Polyline with a `Generated`
   carrying the recovered params + a `translate·rotate` placement transform.
   Pinned by the fitter conformance corpus + a generator/fitter round-trip + a
   checkpoint_equivalence replay per app. The gate also caught three latent bugs
   (a Rust dispatch gate, a Swift NSNumber/Bool eval bug, an OCaml list-dot-access
   eval bug). The fuzzy/AI tier stays later (`VISION.md` §7 frontier). **Detailed
   design + the conformance gate: §10.**
6. **Constraints — ✅ done (all 4 native apps).** A concept's invariants as boolean
   `check` expressions over `param` (`min_teeth`/`outer_exceeds_root` on gear,
   `min_sides`/`positive_radius` on polygon), surfaced **advisorily** — the panel
   shows the violated constraints' messages, never blocking the edit. A read-only
   checker (no op-log verb, no controller): `selected_concept.violations` collects
   the constraints whose `check` is not truthy. Pinned by the constraint
   conformance corpus + a view test per app. Bidirectional constraint solving (IK)
   stays the separate, harder layer (`VISION.md` §6.2). **Detailed design + the
   conformance gate: §11.**

**All six increments are complete — a concept's four parts (generator, operations,
fitter, constraints) all ship as declarative data across the 4 native apps, each
cross-language-pinned.**

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

---

## 9. Operations (increment 4) — design

The second of a concept's four parts (`VISION.md` §5.3, §1 here): its **edit
verbs**. The generator answers "params → geometry"; an operation answers "this
named edit → new params". A gear's `add_tooth` is the canonical example: a
single, meaningful verb the artist invokes, distinct from hand-typing a number
into the `teeth` field. Operations are **data, not native code** — the recurring
discipline — so a new domain ships its verbs in its pack with zero app changes.

### 9.1 The locked decisions

| # | Fork | Decision |
|---|------|----------|
| 1 | What is an operation's effect? | **A `set:` map of `param-name → expression`**, each expression evaluated in the existing language with the instance's CURRENT params bound under `param` (exactly the generator's namespace). The result is the new value for that param; unnamed params are unchanged. No new evaluator, no JS — operations ride the same corpus-pinned engine as generators. |
| 2 | Arguments? | **None in v1.** An operation is a self-contained named transform (`add_tooth`, `remove_tooth`, `add_side`). A *parameterized* operation ("set tooth count to N") is just `set_concept_param` and already exists; argument-carrying operations (with a prompt/dialog) are a later generalization. |
| 3 | Where do operations live? | In the concept pack: a new top-level **`operations:`** list in `workspace/concepts/<id>.yaml`, bundled into `workspace.json` by the existing loader (the registry already carries the whole concept, so `concept(id).operations` needs no loader change). |
| 4 | Op-log representation (the determinism fork) | **One verb, `apply_concept_operation`, with the effect RESOLVED at production time.** The native handler reads the instance's current params, evaluates the operation's `set:` expressions, and bakes the resulting `changes` map into the op **value-in-op** (`{path, op_id, changes}`). Replay merges `changes` — it never re-evaluates an expression nor consults the registry, so it is byte-identical and survives a later edit to the operation's definition (the OP_LOG §7 rule, exactly as `set_concept_param` bakes its committed value). `op_id` rides along as journal metadata (semantic readability for the op-log spine); `changes` is authoritative. |
| 5 | How it is pinned | A dedicated **operations conformance corpus** — `workspace/tests/concept_operations.yaml` → `test_fixtures/concept_operations/conformance.json` — self-checked in all five apps, mirroring the concept corpus. A case is `(concept, op, params) → expected changes`; each app evaluates the operation's `set:` expressions over `params` and compares the resolved `changes` within 1e-9. Operation resolution IS expression evaluation, so this is again a thin specialization of the expression gate. |

### 9.2 The format

```yaml
# appended to workspace/concepts/gear.yaml
operations:
  - id: add_tooth
    label: "Add Tooth"
    description: >
      Add one tooth to the gear: increases `teeth` by one. The geometry
      re-derives from the generator at the new tooth count.
    set:
      teeth: "param.teeth + 1"
  - id: remove_tooth
    label: "Remove Tooth"
    description: >
      Remove one tooth, clamped to the 3-tooth minimum a gear needs to be a
      gear: sets `teeth` to max(teeth - 1, 3).
    set:
      teeth: "max(param.teeth - 1, 3)"
```

Each operation is `{id, label, description, set}`. `set` is a map (param name →
expression over `param`); only the named params change. `description` follows the
workspace convention (comprehensive, human-readable). Operations are optional — a
concept with no `operations:` key simply offers none.

### 9.3 The flow (per app)

1. **Declare** — operations in the pack; the registry exposes
   `concept(id).operations`.
2. **Expose** — `active_document.selected_concept` gains an `operations`
   list (`[{id, label, description}]`) alongside `params`, so the panel can
   render a button per operation (params mode, beneath the param fields).
3. **Invoke** — a button dispatches `apply_concept_operation { op_id }`.
4. **Resolve (production-time, value-in-op)** — the native handler finds the
   single selected `Generated`, looks up the operation in the registry by
   `op_id`, evaluates each `set:` expression with `param` = the instance's
   current params, and builds `{op: apply_concept_operation, path, op_id,
   changes}`.
5. **Journal + apply** — routed through `op_apply` inside the one-undo bracket
   (the §7.3 pattern). The replay arm calls
   `Controller.apply_concept_operation(path, changes)`, which merges `changes`
   into the `Generated`'s params (a multi-param generalization of
   `set_concept_param`); the geometry re-derives at the next render.

### 9.4 Tests first (the project rule)

Authored before any controller/op_apply code:
- the **operations corpus** (§9.1 decision 5) — the cross-language equivalence gate;
- a **controller test** — `apply_concept_operation` merges a `changes` map into a
  `Generated`'s params in place;
- an **op_apply replay test** — `apply_concept_operation` journals one op and
  replays byte-identically (checkpoint_equivalence), reusing the §7.3 harness;
- a **view test** — `selected_concept.operations` lists the registry's operations
  for a single selected `Generated`.

### 9.5 Deferrals

Operation **arguments** (parameterized verbs with a prompt), operations that read
**more than `param`** (e.g. the current geometry or sibling elements), and
multi-instance / batch operations are out of scope for v1 — each a clean later
generalization, none a rewrite.

---

## 10. The fitter — `promote` (increment 5) — design

The third of a concept's four parts (`VISION.md` §5.3): its **fitter**, the dual
of the generator. The generator answers "params → geometry"; the fitter answers
"**geometry → params**" — *"this drawing IS a hexagon; recover its sides and
radius."* `promote` runs the fitter over a selected raw shape and, on a match,
replaces it with a live `Generated` instance carrying the recovered parameters —
the `release`/`expand` inverse (`VISION.md` §5.3), and the deterministic floor of
the §7 frontier (the fuzzy/AI tier is layered on top later, never underneath).

### 10.1 The pivotal decision — a fitter is an EXPRESSION

A generator is an expression (format decision 1); **by symmetry a fitter is too.**
A capability audit of the expression engine confirmed it can express a
regular-polygon detector — list indexing (`p[0]`), `.length`, `fold` with a list
accumulator, `map`/`range`, `all`/`any`, `hypot`, `min`/`max`, `let`, lambdas,
booleans, `if/then/else`, and `null` — with **exactly one missing primitive:
`atan2(y, x)`** (to recover the placement angle). So the fitter rides the same
corpus-pinned engine as the generator, `atan2` (degrees, mirroring `sin`/`cos`) is
added to the math family as a small, in-pattern extension (corpus-pinned), and
**concepts stay data, not native code.**

### 10.2 The locked decisions

| # | Fork | Decision |
|---|------|----------|
| 1 | What is a fitter? | **An expression** over a new **`shape`** namespace (`shape.points` = the selected shape's vertices as `[[x,y],…]`), evaluated by the same engine. It returns **`null` (no match)** or a flat **result list** (decision 3). |
| 2 | The one language gap | Add **`atan2(y, x)` in degrees** to the expression language (all 5 evaluators + the expression corpus). Nothing else is missing. |
| 3 | The fitter's output contract | **`null` \| `[<param0>, <param1>, …, cx, cy, rotation]`** — the first *K* values are the concept's *K* declared params **in `params:` order**, followed by the fixed placement triple `cx, cy, rotation` (degrees). No per-concept output map is needed: *K* is read from the concept's `params:`. |
| 4 | How `promote` places it | The recovered params build the `Generated`; the placement triple builds **`common.transform = translate(cx,cy) · rotate(rotation)`** (applied generically at render — verified). The generator stays origin-centered/first-vertex-on-+x; the transform overlays it on the drawing. A regular polygon's CW/CCW winding yields the same vertex SET, so a convex match is visually exact either way. |
| 5 | Op-log representation | One verb **`promote_to_concept`**, fully value-in-op: the native handler runs the fitter(s) at production time and bakes `{path, concept_id, params, transform}` into the op. Replay rebuilds the `Generated` and replaces the element — it never re-runs a fitter nor consults the registry (the OP_LOG §7 rule). |
| 6 | Which concept? | `promote` tries **every registered concept's fitter** over the selection and takes the **first match** (registry order). With one fitter (`regular_polygon`) in v1 this is unambiguous; multi-fitter scoring/disambiguation is later work. |
| 7 | How it is pinned | A **fitter conformance corpus** — `workspace/tests/concept_fitters.yaml` → `test_fixtures/concept_fitters/conformance.json` — self-checked in all five apps: a case is `(concept, points) → expected (null | result list)`, compared within 1e-9. Plus a **round-trip** property test: promoting a generator's own output recovers params+placement that re-render to the same geometry. |

### 10.3 The format

```yaml
# appended to workspace/concepts/regular_polygon.yaml — the dual of `generator`
fitter: |
  let pts = shape.points in
  let n = pts.length in
  if n < 3 then null else
  let cx = fold(pts, 0, fun (acc, p) -> acc + p[0]) / n in
  let cy = fold(pts, 0, fun (acc, p) -> acc + p[1]) / n in
  let dists = map(pts, fun p -> hypot(p[0] - cx, p[1] - cy)) in
  let r0 = dists[0] in
  let rtol = 0.000001 * r0 + 0.0000001 in
  let radii_equal = all(dists, fun d -> abs(d - r0) < rtol) in
  let edges = map(range(0, n),
    fun i -> hypot(pts[mod(i + 1, n)][0] - pts[i][0],
                   pts[mod(i + 1, n)][1] - pts[i][1])) in
  let e0 = edges[0] in
  let etol = 0.000001 * e0 + 0.0000001 in
  let edges_equal = all(edges, fun e -> abs(e - e0) < etol) in
  if radii_equal and edges_equal and r0 > 0 then
    [n, r0, cx, cy, atan2(pts[0][1] - cy, pts[0][0] - cx)]
  else null
```

A regular polygon ⇔ all vertices equidistant from the centroid (equal radii) AND
all edges equal — both expressible with the available list ops. The result is
`[sides, radius, cx, cy, rotation]`. `fitter:` is optional — a concept with none
can't be promoted to.

### 10.4 The flow (per app)

1. **Declare** — `fitter:` in the pack; the registry already carries it.
2. **Extract** — `promote` reads the selected element's vertices (a `Polygon`/
   `Polyline` in v1) into `shape.points`.
3. **Detect (production-time, value-in-op)** — evaluate each registered concept's
   `fitter` over `shape`; the first non-`null` result wins. Split it into params
   (first *K*, by `params:` order) and the placement triple; build the transform.
4. **Journal + apply** — build `{op: promote_to_concept, path, concept_id, params,
   transform}` and route through `op_apply` in the one-undo bracket. The replay
   arm calls `Controller.promote_to_concept(path, concept_id, params, transform)`,
   which replaces the element with a `Generated { concept_id, params, common:
   { transform } }`.
5. **Invoke** — an `Object`-menu item "Promote to Concept", enabled for a single
   eligible element.

### 10.5 Tests first (the project rule)

Authored before the promote code:
- **`atan2` expression-corpus cases** — the language extension, gated in all 5 apps;
- the **fitter conformance corpus** (§10.2 decision 7) — the detector, cross-language;
- a **round-trip property test** — generate `regular_polygon{sides,radius}`, feed the
  points back through the fitter, assert it recovers `[sides, radius, 0, 0, 0]`
  (canonical placement) within tolerance;
- a **controller test** — `promote_to_concept` replaces the element with the
  expected `Generated` (params + transform);
- an **op_apply replay test** — `promote_to_concept` journals one op and replays
  byte-identically (checkpoint_equivalence).

### 10.6 Deferrals

`Path` inputs (curve sampling), **non-canonical detectors** beyond regular polygon
(star/gear fitters, ellipse, line), **multi-fitter scoring** (when several concepts
match), tolerance configurability, and the **fuzzy/AI tier** (`VISION.md` §7) are
all later — the deterministic regular-polygon detector is the floor everything else
builds on.

---

## 11. Constraints (increment 6) — design

The fourth and final part of a concept (`VISION.md` §5.3): its **constraints** —
the invariants its parameters must satisfy. A gear with `teeth < 3` or
`outer <= root` is not a gear. Constraints are *declared data* (the recurring
discipline) and **advisory** (`VISION.md`'s deterministic-core + artist-primacy):
the checker SURFACES violations; it never blocks the artist's edit. This closes
the §6.3 "downside" (concepts had no invariants). Bidirectional solving — move a
handle, back-solve the params (IK) — is the separate, harder layer (`VISION.md`
§6.2), explicitly out of scope.

### 11.1 The locked decisions

| # | Fork | Decision |
|---|------|----------|
| 1 | What is a constraint? | **A boolean expression over `param`** (the same engine), plus a human-readable `message`. `param.teeth >= 3`. No JS — the §6.3 downside closed with the corpus-pinned language. |
| 2 | Advisory or blocking? | **Advisory.** The checker returns the violated constraints; the panel surfaces them under the params. An edit is NEVER rejected (artist-primacy). Auto-clamping already lives in *operations* (`remove_tooth` clamps to 3); op-time enforcement is a later option, not v1. |
| 3 | Where do constraints live? | A new `constraints:` list in the concept pack — `{id, message, check}`. Bundled into `workspace.json` by the existing loader (the registry already carries the whole concept, so no loader change). |
| 4 | The checker | A pure function `check(concept, params) → [{id, message}]`: evaluate each `check` over `param` and collect the constraints whose result is **not truthy** (reusing each interpreter's existing `if`-truthiness, so the verdict agrees cross-language). **READ-ONLY** — no op-log verb, no mutation, no controller change. This makes §7.6 the lightest of the four parts. |
| 5 | How it is pinned | A constraint conformance corpus — `workspace/tests/concept_constraints.yaml` → `test_fixtures/concept_constraints/conformance.json` — self-checked in all five apps: a case is `(concept, params) → expected violated ids`. Checking is boolean expression evaluation, so this is again a thin specialization of the expression gate. |

### 11.2 The format

```yaml
# appended to workspace/concepts/gear.yaml
constraints:
  - id: min_teeth
    message: "A gear needs at least 3 teeth."
    check: "param.teeth >= 3"
  - id: outer_exceeds_root
    message: "The tooth-tip radius must exceed the root radius."
    check: "param.outer > param.root"
  - id: positive_root
    message: "The root radius must be positive."
    check: "param.root > 0"
```

Each constraint is `{id, message, check}`. `check` truthy ⇒ satisfied; not truthy
⇒ violated (the `message` explains why, the workspace-convention English).
`constraints:` is optional — a concept with none simply has no invariants.

### 11.3 The flow (per app)

1. **Declare** — constraints in the pack; the registry exposes them.
2. **Check** — the checker evaluates each `check` over the instance's current
   params and collects the violations `[{id, message}]`.
3. **Surface** — `active_document.selected_concept` gains a `violations` list, so
   the Concepts panel shows a warning block under the params when it is non-empty.
No op-log verb — checking is read-only and recomputed from params on each render.

### 11.4 Tests first (the project rule)

- the **constraint corpus** (§11.1 decision 5) — the cross-language equivalence gate;
- a **checker unit test** — valid params ⇒ no violations; an out-of-range param ⇒
  exactly the right constraint id;
- a **view test** — `selected_concept.violations` lists the violated constraints
  (id + message) for a single selected `Generated`.

### 11.5 Deferrals

**Enforcement** (blocking or auto-clamping an edit), **cross-instance / geometric**
constraints beyond `param` (e.g. "no self-intersection", relations between
elements), **severity levels** (error vs warning), and **bidirectional solving /
IK** (`VISION.md` §6.2) are all later — v1 is a declarative invariant + an advisory
checker, nothing more.
