# Phase 3 — Category C doc-mutation primitives

**Status**: Phase 3 complete (2026-04). Kept as the design record;
supersedes the Phase 3 sketch in `PLAN.md`. See commits tagged
"Phase 3" in `git log` for the implementation across
`workspace_interpreter/` (reference) and the four native ports.

Precedes the reference implementation in `workspace_interpreter/`
(Step P3.1) and the per-language ports (Steps P3.2–P3.4).

---

## 1. Why this exists

Phase 1 removed 6 hardcoded action arms by making `set:` schema-driven
and generalizing `swap:` / `pop:`. That handled every action whose
effect was a top-level state write.

Phase 3 targets 11 **document-mutating** actions whose YAML today is
`log:` placeholder (see AUDIT.md Part A, items 2–18). Examples:
`toggle_all_layers_visibility`, `delete_layer_selection`,
`new_group`, `flatten_artwork`. These can't be expressed with `set:`
alone — they traverse the document tree, snapshot for undo, insert /
delete / reparent elements, and iterate over selections.

The choice is whether each of the 11 becomes a new hardcoded primitive
per language (`flatten_artwork_primitive:`, `new_group_primitive:`…)
or whether the language gains a small, composable vocabulary that
*these 11 and everything else* can express in YAML. Phase 1's verdict
on `set:` was the latter; Phase 3 extends the same thinking to doc
mutation.

---

## 2. Worked example — `toggle_all_layers_visibility`

The simplest of the 11 and the design's test case. If the YAML below is
readable, the design is right; if not, iterate before building.

```yaml
toggle_all_layers_visibility:
  description: >
    Toggle all top-level layers between visible and invisible. If any
    layer is currently visible, all layers are set to invisible ("Hide
    All Layers"). Otherwise all layers are set to preview mode ("Show
    All Layers"). Takes one undo snapshot for the whole operation.
  category: layers
  tier: 3
  enabled_when: "state.tab_count > 0"
  effects:
    - let:
        target: >
          if any(active_document.top_level_layers,
                 fun l -> l.visibility != 'invisible')
            then 'invisible'
            else 'preview'
    - snapshot
    - foreach:
        source: active_document.top_level_layer_paths
        as: path
      do:
        - doc.set:
            path: path
            fields:
              common.visibility: target
```

Reading this aloud: "Bind `target` to 'invisible' if any top-level
layer is visible, else 'preview'. Snapshot. For each top-level layer
path, write `common.visibility = target` on that element."

Eleven lines plus the description. One `let:` binding, one call to a
higher-order function, one `snapshot`, one `foreach` over a list of
paths, one `doc.set` per iteration. No new keyword is specific to
"toggle visibility"; every primitive has a use elsewhere.

---

## 3. Locked design decisions

Recorded as the answers to the four tollgate questions raised during
design. Not revisitable without rewriting the rest of this doc.

### D1. Binding effect name: `let:`

Chosen over `as:` and `compute: … as: name`. Rationale: `let:` reads
like the functional-language equivalent it is, and the YAML shape
mirrors `set:` (map of name → expression). `as:` remains reserved for
the return value of effects that mutate *and* return a meaningful
value (`pop:`, `doc.delete_at:`, `doc.clone_at:`); a pure binding is
not that.

### D2. `doc.set` field paths are dotted strings

```yaml
- doc.set:
    path: path
    fields:
      common.visibility: invisible
      common.locked: false
```

Chosen over nested maps (`common: { visibility: invisible, locked: false }`)
and flat keys with implicit namespacing. Dotted is explicit at the
write site and matches how `SCHEMA.md` already describes element
fields. Implementation splits the dot, descends into the element, and
schema-validates the leaf.

### D3. Lambdas: `fun x -> body`, higher-order functions over lists

Lambdas use the syntax already chosen for the expression language:
`fun x -> expr` (single-arg) or `fun (x, y) -> expr` (multi-arg). All
four evaluators already parse and evaluate this — the gap is only the
absence of HOFs that *take* lambdas.

Phase 3 adds four built-in HOFs: `any`, `all`, `map`, `filter`. Each
takes `(list, predicate_or_transform)`. They cover the ten other
Category C migrations without needing further expression-language
surface in Phase 3.

### D4. `path` is an opaque value type

Paths are a distinct `ValueType` in the expression language, alongside
`Number`, `Str`, `Bool`, `Color`, `List`, `Closure`. Internal
representation: list of non-negative integers.

**Computed properties** (property-access syntax, zero-arg, pure):

| Property | Returns | Meaning |
|---|---|---|
| `p.depth` | number | Number of path segments. `[]` has depth 0. |
| `p.parent` | path or null | Drops last index. `[]`.parent is null. |
| `p.id` | string | Dotted form: `[0, 2]` → `"0.2"`, `[]` → `""`. |
| `p.indices` | list of number | Escape hatch to list ops. |

**Free functions**:

| Function | Returns | Meaning |
|---|---|---|
| `path(i, j, ...)` | path | Constructor from integer args. `path()` is root. |
| `path_child(p, i)` | path | Appends index `i`. |
| `path_from_id(s)` | path | Parses `"0.2"` back to a path. Returns null on malformed. |

**Equality**: `p1 == p2` compares index-wise. `path(0, 2) == path(0, 2)`
is true; `path(0, 2) == [0, 2]` is false (different types, even though
same internal data).

Rationale for computed-property / free-function split: the existing
expression parser already supports `a.b.c` property chains but not
`a.b(x)` method calls. Property accessors with no args map naturally;
operations with args stay as prefix function calls.

---

## 4. Scope and closure semantics

Lexical scoping. Binding sites are determined by the text of the
program; runtime order is irrelevant.

### 4.1 Scope boundaries

Every `effects:` list *and* every inner `do:`, `then:`, `else:` list
is a **scope**. When evaluation enters a list, it pushes a new scope
onto the environment chain. When it exits, that scope is popped.

### 4.2 Binding rules

Within a scope, the following introduce bindings:

1. **`- let: { name: expr, ... }`** — evaluates each `expr` against the
   current environment and extends the scope with `name → value`. The
   new binding is visible from the next effect in the list onward.
   A second `let:` on the same name does **not** mutate the first; it
   opens a **nested shadowing scope** that extends to the end of the
   containing list. When that list ends, the outer binding is recovered.
2. **`- foreach: { source: expr, as: name } do: [...]`** — evaluates
   `source` once in the surrounding scope; for each item, pushes a
   **fresh scope** containing `name → item`, evaluates `do:`, pops.
   Bindings made inside one iteration are **not** visible in the next.
3. **`fun x -> body`** (inside an expression) — creates a closure value
   that captures the current environment **by value** at definition
   time. When the closure is later applied, argument binding happens
   on top of the captured environment — not the caller's environment.

### 4.3 Name resolution

A free identifier `$x` in an expression is resolved by searching the
environment chain outward from the innermost scope until a binding is
found. If no binding exists, the identifier falls through to the
runtime-context namespaces (`state`, `panel`, `active_document`,
`theme`, etc.) — exactly as today.

### 4.4 Closure-capture test case

This test must pass in all four languages:

```yaml
effects:
  - let: { x: 1 }
  - let: { f: "fun _ -> x" }     # f captures x from first let's scope
  - let: { x: 2 }                 # new scope shadowing first let
  - assert: "x == 2"              # direct lookup sees shadowed x
  - assert: "f(null) == 1"        # closure sees captured x, not shadowed x
```

If closure semantics are broken, `f(null)` returns 2 (the shadow
leaked into the capture). Phase 3 CI must include this fixture.

### 4.5 `foreach` iteration-capture test case

```yaml
effects:
  - let: { captures: [] }         # conceptual; pseudo-syntax
  - foreach:
      source: [1, 2, 3]
      as: x
    do:
      - list_push: { target: captures, value: "fun _ -> x" }
  # After the loop, captures[0](null) == 1, captures[1](null) == 2,
  # captures[2](null) == 3 — each closure captured its iteration's x.
```

A broken implementation (sharing a mutable cell for `x` across
iterations, JS-style) returns 3 for all three calls.

### 4.6 Implementation model

Each scope is a **persistent map** from names to values, linked by
parent pointer to the enclosing scope — a frame chain. Pushing a scope
is O(1); lookups walk the chain. Closures store a reference to the
frame chain at definition time, so lookups from inside a closure use
the captured chain, not the caller's.

Python and Swift currently use a flat dict copied on extension
(`dict(ctx)` / `ctx.merging(...)`). That's semantically equivalent to
the frame-chain model for correctness (each copy is a persistent
snapshot). Rust and OCaml use an env structure separate from the ctx
JSON. Phase 3 does not require changing these internal shapes — only
adding the `let:` **effect-level** hook and ensuring `foreach`
iterations get fresh frames.

---

## 5. New YAML effect primitives (4)

Signatures using the return-value notation from PLAN.md §309. `unit`
means the effect returns nothing; `as:` on a unit effect is a warning.

### 5.1 `let: { name: expr, ... }` → unit

Evaluates each expression against the current environment; the results
extend the current scope for subsequent effects. Multiple bindings in
one `let:` block evaluate left-to-right (YAML map order) — earlier
names are visible to later expressions *in the same block*.

```yaml
- let:
    target: "if active_document.any_top_level_layer_visible then 'hidden' else 'visible'"
    layer_count: "active_document.top_level_layer_paths.length"
```

Named bindings are visible until the end of the containing list. A
rebinding of the same name in the same `effects:` list shadows
(see §4.2).

### 5.2 `snapshot` → unit

Pushes an undo checkpoint on the active document. No args. Does
nothing if there is no active tab (e.g. `state.tab_count == 0`).

```yaml
- snapshot
```

Implementation per-language: calls the existing `model.snapshot()` /
`tab.model.snapshot()` / `m#snapshot` method on the active tab's model.

### 5.3 `foreach: { source, as } do: [effect_list]` → unit

Evaluates `source` once; for each item in the resulting list, pushes a
fresh scope with `as:` bound to the item, runs `do:` effects, pops.

```yaml
- foreach:
    source: active_document.top_level_layer_paths
    as: path
  do:
    - doc.set:
        path: path
        fields:
          common.visibility: target
```

Same keyword as the render-time `foreach` already in use (layers.yaml
breadcrumbs, etc.). The render-time and effect-time forms share the
same scoping discipline but not the same implementation entry point.
Documented as "the `foreach` keyword has two call sites".

Implicit `_index` is bound alongside `as:`, as in render-time `foreach`.

### 5.4 `doc.set: { path, fields: { "dotted.field": expr, ... } }` → unit

Schema-driven element write on `active_document.at(path)`. `path` is a
path value; `fields` is a map from dotted field paths (relative to the
element root) to expressions. Each field's leaf type is looked up in
the element schema (`SCHEMA.md`) and the expression result is coerced
as in Phase 1's `set:`. On coercion failure, the write is skipped and
a diagnostic is emitted; other fields in the same `doc.set` still
apply (batch-semantics consistent with Phase 1).

```yaml
- doc.set:
    path: path
    fields:
      common.visibility: target
      common.locked: false
      name: "'Renamed Layer'"
```

Implementation per-language:

1. Resolve `path` against the active document, producing a mutable
   handle to one element. If the path is invalid, emit a diagnostic
   and skip.
2. For each `(dotted_field, expr_result)` pair:
   - Descend the dotted path to the leaf, walking through nested
     `common`, `stroke`, etc. (The allowed descent paths come from
     the element schema.)
   - Type-check / coerce the expression result against the leaf's
     declared type.
   - Write. Each leaf assignment goes through the document's normal
     mutation API so undo / change-notification stays consistent.

### 5.5 Primitives deferred past Phase 3

Phase 3 deliberately does **not** introduce:

- `doc.delete_at`, `doc.insert_at`, `doc.insert_after` — needed by
  `delete_layer_selection`, `new_layer`, `duplicate_layer_selection`,
  `new_group`, `collect_in_new_layer`, `flatten_artwork`. These
  primitives are **additions** to Phase 3's vocabulary, specified in
  §8 as sub-tollgates before each dependent action migrates.
- `doc.clone_at` returning an element value — needed for
  `duplicate_layer_selection`. Requires effect-returns-value machinery.
- `doc.wrap_in_group`, `doc.unpack_group_at` — composite operations;
  can be expressed as compositions of insert/delete/snapshot once the
  atomic primitives exist.

The structure is: Phase 3 ships the worked example
(`toggle_all_layers_visibility`) and the other two pure-visibility-toggle
actions (`_outline`, `_lock`) first, using only the primitives in §5.1–§5.4.
Then each subsequent migration in §8 introduces its own primitives under
a sub-tollgate design review.

---

## 6. New expression-language features

### 6.1 Higher-order functions on lists

Four new built-in function names: `any`, `all`, `map`, `filter`. All
take `(list, callable)`. The callable may be a lambda (`fun l ->
l.visibility != 'invisible'`) or a named closure in scope.

| Function | Signature | Returns |
|---|---|---|
| `any(xs, pred)` | pred: `a -> bool` | `bool` — true iff `pred(x)` is truthy for at least one `x` |
| `all(xs, pred)` | pred: `a -> bool` | `bool` — true iff `pred(x)` is truthy for every `x` |
| `map(xs, f)` | f: `a -> b` | `list<b>` — applies `f` to each element |
| `filter(xs, pred)` | pred: `a -> bool` | `list<a>` — keeps elements where `pred(x)` is truthy |

Behavior on the empty list: `any([])` → false; `all([])` → true;
`map([]) / filter([])` → `[]`.

All four evaluators already have the `__apply__` machinery to invoke
a closure by value. The HOFs are a small wrapper over that machinery
plus a list iteration.

### 6.2 Path value type

Introduces a new `ValueType::Path` variant alongside the existing ones
(see §3 D4 for the surface API). Port delta per language:

- **Python**: add `PATH` to `ValueType` enum; `Value.path(indices:
  tuple[int, ...])` constructor. Update `_eval_dot_access` to
  special-case path-typed receivers. Register `path`, `path_child`,
  `path_from_id` as builtins in `_eval_func`. Update `Value.__eq__`.
- **Rust**: add `Value::Path(Vec<usize>)`. Extend `eval_dot_access`
  match. Add path functions to the `match name` arms in
  `eval_func_call`. Update `PartialEq` derive or impl.
- **Swift**: add `.path([Int])` to `Value` enum. Extend property
  accessor switch. Add to the function dispatch switch.
- **OCaml**: add `Path of int list` to the `value` type. Extend
  `eval_dot_access` match. Add to `eval_func` match.

Paths equate structurally. Paths do **not** implicitly coerce to
lists; `p.indices` is the explicit coercion.

### 6.3 Sequence of closure captures inside `foreach`

Implementation note, not surface feature: each iteration of `foreach`
must produce a fresh frame. Today's per-iteration `ctx` extension in
Python (`dict(ctx)`, extended with `as:` binding, passed to the body)
is correct by construction — each `dict(ctx)` call is a snapshot,
and closures made inside the body capture that snapshot. The other
three languages must match this semantics.

Test fixture in §4.5 is the contract.

---

## 7. Schema additions

### 7.1 `runtime_contexts.yaml`: `type: path`

Add `path` as a declared type. Example on `active_document`:

```yaml
active_document:
  properties:
    top_level_layer_paths:
      type: list
      item_type: path
      description: "Paths of all top-level elements of kind Layer"
    top_level_layers:
      type: list
      item_type: object
      description: "Top-level Layer elements as {path, name, visibility, common, ...}"
```

The schema-driven `set:` validator (from Phase 1) must also recognize
`path` as a valid item type.

### 7.2 `active_document` property additions

Two new properties read by Phase 3's first three migrations:

| Name | Type | Used by |
|---|---|---|
| `top_level_layers` | `list<object>` | HOF predicates needing layer fields (e.g. `l.visibility`) |
| `top_level_layer_paths` | `list<path>` | `foreach` loops that only need the path, not the payload |

Both are computed from the active tab's `document.layers` filtered to
`Element::Layer` kind.

`top_level_layer_paths` is arguably redundant — one could write
`map(top_level_layers, fun l -> l.path)` — but Phase 3 keeps it as a
convenience for the hot loop in §2. If profiling finds the materialized
object list expensive when only paths are needed, the path-only version
is cheap.

### 7.3 Retrospective rollup properties

Phase 1 Part B observed `active_document.layers_panel_selection_*`
rollup properties. Phase 3 prefers HOFs + computed lists over
more rollups. Existing rollups stay for backward compat with
`enabled_when:` expressions; new rollups are not added.

---

## 8. Migration order within Phase 3

Eleven actions, migrated in order of primitive requirements. Each
group ships with its required sub-tollgate (new primitives listed
before the actions that need them).

### Group A — Visibility / lock toggles (uses §5 primitives only)

1. `toggle_all_layers_visibility`
2. `toggle_all_layers_outline`
3. `toggle_all_layers_lock`

Shape: `let: target`, `snapshot`, `foreach` over paths, `doc.set` of
`common.*` field. Exit criterion: all three migrate with the YAML shape
in §2, pass cross-language tests, and the three arms in each of Rust /
OCaml / Python are deleted. Swift gains working versions.

### Sub-tollgate 1 — Delete / duplicate primitives

Introduce:

- `doc.delete_at: path` → deleted element (effect-returns-value)
- `doc.clone_at: path` → cloned element (same mechanism)
- `doc.insert_at: { parent_path, index, element }` → unit
- `doc.insert_after: { path, element }` → unit

Plus: effect-level `as:` return-binding wired to the same env chain
used by `let:`.

### Group B — Delete / duplicate

4. `delete_layer_selection`
5. `duplicate_layer_selection`

### Sub-tollgate 2 — Factory primitive *(absorbed into implementation)*

Introduce:

- `doc.create_layer: { name, children?, common? }` → element

Shipped without a separate design doc. `doc.create_layer` takes a
`name` (required, string) and returns a new Layer element whose
`common` defaults to the schema's defaults (`visibility: preview`,
`locked: false`, `opacity: 1.0`). The element flows through
effect-level `as:` binding and is installed via a follow-up
`doc.insert_at`. `children` and `common` overrides aren't wired yet;
they're only needed by Phase 5+ compositional actions.

### Group C — Creation

6. `new_layer`
7. `new_group`
8. `collect_in_new_layer`

### Sub-tollgate 3 — Structural *(absorbed into implementation)*

Introduce:

- `doc.wrap_in_group: { paths }` → unit
- `doc.unpack_group_at: path` → unit
- `doc.wrap_in_layer: { paths, name }` → unit (added during Group C)

Shipped without a separate design doc. `doc.wrap_in_group` and
`doc.wrap_in_layer` take a `paths` expression (list of Path values)
and remove the elements at those paths, wrapping them in a new
Group/Layer. `wrap_in_layer` also takes a `name` expression;
`wrap_in_group` leaves the Group unnamed. `doc.unpack_group_at`
replaces a Group with its children in place.

Swift's typed `Document.layers: [Layer]` constrains
`doc.wrap_in_group` to top-level containers only; Rust/OCaml/Python
support nested wrapping via their Element-tree APIs.

### Group D — Structural

9. `flatten_artwork`

### Sub-tollgate 4 — Dialog return-value *(resolved: reused param namespace)*

Originally planned:

- Mechanism for `layer_options_confirm` to read its dialog's `prop:`
  values inside an expression.

Resolved without new machinery: the dialog's OK button forwards
dialog state (`dialog.name`, `dialog.lock`, `dialog.show`,
`dialog.preview`) as dispatch `params:`. `layer_options_confirm` then
reads them as `param.name` / `param.lock` / etc. — the same namespace
every action already uses for dispatch arguments. A latent bug in the
`open_dialog` effect handler (outer-action `param` overlaying the
dialog's own `_dialog_params` during init evaluation) was fixed by
dropping `param` from the init eval-ctx extras.

### Group E — Dialog commit

10. `layer_options_confirm`

### Group F — Isolation

11. `enter_isolation_mode`

Already half-done: Phase 1 Step 6 added `pop: panel.isolation_stack`
for `exit_isolation_mode`. Enter is a conditional `list_push: panel.
isolation_stack` — primitive may already exist. Worth verifying before
designing a sub-tollgate.

---

## 9. Port delta per language

Phase 1 finding: Let / Lambda / Closure are already present in all
four expression evaluators (see agent survey, 2026-04-16). Phase 3's
non-trivial port work is:

| Area | Python | Rust | Swift | OCaml |
|---|---|---|---|---|
| `let:` effect wired to env | new | new | new | new |
| Effect-time `foreach` | new | new | present (render only) | new |
| `snapshot` primitive | new | new | new | new |
| `doc.set` primitive | new | new | new | new |
| HOFs: `any` / `all` / `map` / `filter` | new | new | new | new |
| `path` value type | new variant | new variant | new variant | new variant |
| `active_document` rollups (§7.2) | new | new | new | new |

"New" here means ~20–50 lines per item per language. The largest
single item is `doc.set` — it needs the per-element schema descent
logic, which is per-language mirror of the Phase 1 `apply_set_effects`.

No refactor of the existing `set:` path / `apply_set_schemadriven`
infrastructure is required. Phase 3's `doc.set` shares the coercion
layer (§5.4) but uses a separate resolution path (element-at-path vs.
global state field).

---

## 10. Tests

### 10.1 Cross-language fixtures

`workspace/tests/phase3/` (new): YAML fixtures of the form

```yaml
name: "toggle_all_layers_visibility_all_visible"
initial_doc:
  layers:
    - { kind: Layer, name: "A", visibility: visible }
    - { kind: Layer, name: "B", visibility: visible }
action: toggle_all_layers_visibility
params: {}
expected_doc:
  layers:
    - { kind: Layer, name: "A", visibility: invisible }
    - { kind: Layer, name: "B", visibility: invisible }
```

Each of the 4 languages loads these fixtures via its existing test
harness (`workspace_interpreter/tests/`, `jas_dioxus/tests/`,
`JasSwift/Tests/`, `jas_ocaml/test/`) and verifies that running the
action produces `expected_doc`.

### 10.2 Semantics fixtures

Originally planned as `workspace/tests/phase3_semantics/`. In practice,
the semantics contracts (closure capture §4.4, iteration capture §4.5,
HOF round-tripping §6.3) shipped as in-language test suites rather
than a cross-language YAML-fixture harness:

- Python reference: `workspace_interpreter/tests/test_phase3_semantics.py`
- Rust: `jas_dioxus/src/interpreter/expr_eval.rs` and `renderer.rs`
  unit tests.
- Swift: `JasSwift/Tests/Interpreter/ExprEvalPhase3Tests.swift`.
- OCaml: `jas_ocaml/test/interpreter/expr_eval_test.ml`.

Each language's suite covers the same semantic contracts with test
bodies translated into native test tooling. A YAML fixture harness
would give better drift-resistance, but was skipped because each
language's expression evaluator already has native fixture harness
support and the in-language translations were less friction than
adding a new YAML-driven harness to 4 test runners.

### 10.3 Schema tests

`runtime_contexts.yaml` gains `type: path`; extend the existing schema
validator tests to check paths can round-trip through `set:` and
`doc.set`, that `list<path>` is valid as an `item_type`, and that
coercion rejects non-path values for `path`-typed fields.

---

## 11. Exit criterion — STATUS: COMPLETE

Phase 3 exit criteria:

1. ✅ All 11 Category C actions have their YAML `log:` placeholder
   replaced with real `effects:` blocks built from the primitives in
   §5 / sub-tollgates.
2. ✅ Hardcoded arms deleted where they existed (Rust
   `dispatch_action`, OCaml/Python `panel_menu` dispatches).
3. ✅ `workspace/tests/phase3/` fixtures pass in all 4 languages.
4. ✅ Semantics contracts pass in all 4 languages via in-language
   test suites (see §10.2 — the planned YAML fixture harness was
   replaced by per-language tests).
5. ✅ Closure-capture §4.4 and iteration-capture §4.5 contracts
   pass in every evaluator.
6. ✅ `AUDIT.md` reflects Phase 3/4 completion (see "Phase 3 / Phase
   4 completion status" section).

Phase 4 (`open_layer_options` + `element_at`) is complete. The
`active_document.at(path)` navigation primitive shipped as the free
function `element_at(path)` — the expression parser already supports
zero-arg property chains (`p.depth`, `p.parent`) but not one-arg
methods (`obj.at(x)`), so a free function stays consistent with the
existing conventions (`path_from_id`, `path_child`).
