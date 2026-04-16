# Plan: Move hardcoded actions into the YAML effects language

## Goal

Eliminate the ~81 `- log: "..."` placeholder effects in `workspace/actions.yaml`
by extending the YAML effects language so actions can be expressed as data
instead of being hand-implemented in each of 4 native languages.

Today, each such action is implemented 4× (Rust, Swift, OCaml, Python) plus
sometimes Flask. Every new complex action is a parity-drift point. Moving
them to YAML reduces `N actions × 4 languages` of code to `N YAML blocks +
one shared primitives implementation per language`.

## Scope audited

18 hardcoded arms in `jas_dioxus/src/interpreter/renderer.rs::dispatch_action`
(lines 258–617), classified:

- **Category A** — one-line method calls, trivial: `set_active_color_none`,
  `swap_fill_stroke`, `reset_fill_stroke`, `exit_isolation_mode`
- **Category B** — typed arg parsing: `set_active_color`, `select_tool`
- **Category C** — document mutations + undo snapshot: `new_layer`,
  `delete_layer_selection`, `duplicate_layer_selection`, `new_group`,
  `toggle_all_layers_visibility`, `toggle_all_layers_outline`,
  `toggle_all_layers_lock`, `flatten_artwork`, `collect_in_new_layer`,
  `layer_options_confirm`, `enter_isolation_mode`
- **Category D** — expression reads: `open_layer_options`

The 81 `log:` YAML placeholders across `workspace/actions.yaml` are an
upper bound: there are likely 60+ other actions in the same situation
across all 4 languages that will benefit from the same primitives.

## Constraints

1. **Branch**: do this on `yaml-interpreter-2` (currently empty off main).
   `layers-panel` must merge to main first — don't mix this refactor into
   a feature branch.
2. **Propagation order**: shared-first.
   1. `workspace_interpreter/` (Python — the spec)
   2. Rust `jas_dioxus/src/interpreter/`
   3. Swift `JasSwift/Sources/Interpreter/`
   4. OCaml `jas_ocaml/lib/interpreter/`
   5. Python-app `jas/` (reuses `workspace_interpreter/` if possible)
   6. Flask (only if its rendering path needs the primitive)
3. **Tests first** per project convention — every new primitive has tests
   in each language before code.
4. **No auto-commit** — ask before committing.
5. **Schema must describe every free variable.** `workspace/runtime_contexts.yaml`
   declares the allowed top-level namespaces (`active_document`, `workspace`)
   with their properties, types, and defaults. Every phase must update
   this file in lockstep with engine changes:
   - Phase 0 produces an audit of *existing* schema gaps: any namespace
     used in YAML expressions but not declared in `runtime_contexts.yaml`
     is a schema hole to fix.
   - Phases 1–3 may add state fields; each gets a schema entry.
   - Phase 4 adds path-navigation semantics; `runtime_contexts.yaml`
     must document `active_document.at(path)` and the returned element
     shape (or link to `SCHEMA.md` for the element schema).
   - Also audit `state`, `panel`, `theme`, `param`, `dialog`, `data`
     namespaces — the evaluator treats them generically, but the schema
     should still enumerate their fields. Undocumented variables are
     a correctness hazard across 4 language implementations.

## Phases

### Phase 0 — Bug audit (standalone, no code)

**Goal**: two parallel audits, both feeding into `AUDIT.md`.

**Part A — Action behavior divergence**: find all cases where a Rust arm
disagrees with its YAML `effects:` block. The `swap_fill_stroke` finding
(YAML targets `stroke_panel` fields but Rust arm swaps global fill/stroke)
suggests there are more. Per action:
- Rust arm behavior (summary)
- YAML `effects:` block (verbatim)
- Agreement / disagreement / YAML is placeholder (`log:`)
- Recommendation (fix YAML, delete Rust arm, both, or neither)

Cross-check: grep Swift/OCaml/Python for same action names to see if
their behavior matches Rust (they almost certainly do — same project
pattern — but worth verifying).

**Part B — Schema gap audit**: compare the set of free variables *used*
in YAML expressions against the set *declared* in `runtime_contexts.yaml`.
- Grep `enabled_when`, `when:`, param expressions, `foreach source:`,
  and any other expression sites across all YAML files.
- Extract every root identifier (first dotted segment).
- Compare against the union of: implicit namespaces (`state`, `panel`,
  `theme`, `param`, `dialog`, `data`, foreach-bound names) and declared
  runtime contexts.
- List: (a) namespaces used but not declared anywhere; (b) properties
  used on declared namespaces but missing from the property list;
  (c) declared properties never referenced in any expression (dead
  schema entries).

**Exit criterion**: `AUDIT.md` committed with both parts. User reviews
and agrees on which fixes happen in Phase 1 vs. which defer.

### Phase 1 — Category A primitives (4 actions, low risk)

**New YAML effect primitives needed**:
- `pop: <list_state_key>` — e.g. `pop: layers_isolation_stack`
- Generalize `set:` so it can target any top-level state or panel state
  field (currently scoped narrowly)
- `reset: [<keys>]` — or rely on generalized `set:` with default values
- Fix `swap:` bug from Phase 0 (targets wrong state)

**Per language, per primitive**: test → implement → verify.

**Migration**: move the 4 Category A actions from hardcoded arms to YAML
`effects:` blocks. Delete the hardcoded arms.

**Exit criterion**: 4 hardcoded arms removed × 4 languages = 16 deletions.
All tests pass. Manual smoke test of each action in each running app.

### Phase 2 — Category B typed values (2 actions, low-medium risk)

**Extension**: `set:` with typed coercion. The engine knows the target
field's type (`Color`, `ToolKind`) and parses string values accordingly.
Relies on state-schema metadata — needs design work.

**Per language**: add type coercion table in `set:` implementation.

**Migration**: `set_active_color` and `select_tool` → YAML.

**Exit criterion**: 2 arms removed × 4 languages = 8 deletions.

### Phase 3 — Category C doc-mutation primitives (10 actions, high risk)

**Design tollgate BEFORE coding**: write target YAML for
`toggle_all_layers_visibility` (simplest of the 10). Review the shape —
if the YAML is unreadable, the design is wrong; iterate before building.

**New YAML effect primitives (tentative)**:
- `snapshot` — take an undo snapshot on the active document
- `doc.delete_at: <path_expr>`
- `doc.insert_at: { path, element }`
- `doc.insert_after: { path, element }`
- `doc.clone_at: <path_expr>` → returns element (needs effect-returns-value)
- `doc.create_layer: { name, children?, common? }` factory
- `doc.wrap_in_group: { paths }`
- `doc.unpack_group_at: <path_expr>`
- `foreach` at effect time (reuses the existing render-time keyword — see
  "foreach keyword reuse" below). Applies a list of effects per item in a
  source list.
- `if: { condition, then, else }` — already exists; verify parity
- Selection access in expressions: `panel.layers_selection`
- Helper: `doc.unique_layer_name` — might be pure expression or primitive

**Migration order within Phase 3** (simplest first):
1. `toggle_all_layers_visibility` (iteration + simple mutation)
2. `toggle_all_layers_outline`
3. `toggle_all_layers_lock`
4. `delete_layer_selection`
5. `duplicate_layer_selection`
6. `new_layer`
7. `new_group`
8. `collect_in_new_layer`
9. `flatten_artwork`
10. `layer_options_confirm`
11. `enter_isolation_mode`

Each migration: YAML written → tests → all 4 languages → verify identical
behavior via cross-language tests.

**Exit criterion**: 11 arms removed × 4 languages = 44 deletions. Cross-
language tests validate identical document state after each action.

### Phase 4 — Category D expression language (1 action)

**Extension**: expression-language support for element-by-path reads.
E.g. `doc.at(param.layer_id).name`, `doc.at(path).locked`.

Verify how far `enabled_when` expressions already go — they reference
`active_document.layers_panel_selection_has_group` etc., which implies
partial support exists.

**Migration**: `open_layer_options` → YAML.

**Exit criterion**: 1 arm removed × 4 languages = 4 deletions.

## Total impact if fully executed

- 18 hardcoded arms × 4 languages = **72 parallel implementations removed**
- Replaced by ~12–15 shared effect primitives + ~18 YAML blocks
- Every *future* complex action becomes a YAML change, not a 4-language change
- Unlocks the same migration for 60+ other `log:` placeholder actions across
  `workspace/actions.yaml`

## Open questions

All resolved. Ready for Phase 0.

### Resolved: expression-language path navigation

Decision: extend the existing `active_document` namespace with a path-
navigation operator so expressions can read element properties by path.
No new `doc` namespace (would fragment the namespace surface), no per-
property helper functions like `get_layer_name` (don't scale).

Tentative shape (final syntax decided during Phase 4 implementation):

```
active_document.at($path).name
active_document.at($path).common.locked
active_document.at($path).children.length
```

Semantics:
- `active_document.at(path)` returns the element at `path`, or `null`
  if the path is invalid / out of range.
- `.` navigation on `null` propagates null (no crashes on missing data).
- Path is a list of integers (same internal representation as
  `layers_panel_selection` entries and the layer_id params).

Used in:
- `enabled_when` conditions (already use expressions; gains new capability)
- Action `effects:` blocks (via param resolution — already evaluates
  expressions in `open_dialog.params`)
- Future `if:` conditions inside effects
- Any other expression context in the YAML engine

Unblocks `open_layer_options` (category D) as pure YAML — dialog params
become expressions over `active_document.at($param.layer_id)`. Also
simplifies properties like `active_document.layers_panel_selection_has_group`,
which currently exist as bespoke rollup properties because expressions
had no way to query the document structure directly.

Accretion-cleanup opportunity: properties like
`active_document.layers_panel_selection_has_group` and
`active_document.layers_panel_selection_is_container` are really panel
state, not document state. They likely ended up on `active_document`
because that was the only namespace with computed-property machinery.
Once path navigation lands, some of these can be retired in favor of
expressions like `panel.layers_selection.length > 0 and foreach(...)`.
Defer this cleanup to a separate pass — not blocking.

### Resolved: explicit `snapshot` effect

Decision: snapshots are taken by an explicit `- snapshot` effect in the
action's `effects:` list, not implicitly by the engine.

```yaml
delete_layer_selection:
  effects:
    - snapshot
    - foreach:
        source: "panel.layers_selection"
        as: path
        do:
          - doc.delete_at: "$path"
```

Rationale:
- The engine cannot know statically whether an action will mutate the
  document, because mutations can be conditional. Implicit snapshots
  would either over-snapshot (any action containing a mutation) or
  require runtime introspection.
- One explicit `snapshot` at the top of an action produces a single
  undo step even if the action performs many mutations — which is the
  behavior the hardcoded arms implement today.
- Actions that don't mutate (category A, B, D) simply don't include
  `snapshot` in their effects. Zero wasted undo entries.
- Makes action semantics self-documenting in YAML: if you see
  `- snapshot`, the action is undoable.

Cost: YAML author must remember to add `snapshot` when migrating a
document-mutating action. Mitigation: validator tool that warns when an
action contains any `doc.*` effect but no `snapshot`.

### Resolved: effects can return values

Decision: effects may return a value, and a subsequent effect can
reference that value via a bound name. Syntax mirrors `foreach`'s
`as:` binding.

```yaml
effects:
  - doc.clone_at:
      path: "$source_path"
      as: cloned
  - doc.insert_after:
      path: "$source_path"
      element: "$cloned"
```

Implications:
- Every effect optionally accepts an `as: <name>` field. Named value is
  visible to subsequent effects in the same `effects:` list (standard
  lexical scoping — also visible inside later `if`/`foreach` bodies).
- Each effect primitive documents what it returns (the mutated element,
  the new path, the previous value, or `null` for pure state-setters).
- Unspecified `as:` means the return value is discarded.
- Binding name collision with `foreach` iterator variable is an error —
  YAML author must pick distinct names.

This avoids the need for compound primitives like `duplicate_at` — they
can be expressed as a two-line YAML chain.

### Resolved: foreach keyword reuse

Decision: extend the existing `foreach` keyword to effect-time iteration,
rather than introduce a new keyword. Rationale: same source-expression
binding (`source` / `as`), same mental model ("repeat for each item").

Known asymmetry to document: render-time `foreach` has `do:` as a sibling
key on the element node, because elements are maps with one primary
structural key. Effect-time `foreach` must nest `do:` inside, because
effects are list items with one top-level key (matching the shape of the
existing `if:` effect, which nests `then:`/`else:`).

Render-time (existing):
```yaml
foreach:
  source: "panel.isolation_stack"
  as: level
do:
  type: container
```

Effect-time (new):
```yaml
effects:
  - foreach:
      source: "doc.layers"
      as: layer
      do:
        - set: { ... }
```

Optional future cleanup: teach `render_repeat` to also accept `do:` nested
inside `foreach:` for shape consistency. Not blocking.

## Progress tracking

- [x] Phase 0: Bug audit — `AUDIT.md` produced
- [ ] Phase 1: Category A primitives — 4 actions (+ 2 bug fixes, + schema gaps)
- [ ] Phase 2: Category B typed values — 2 actions
- [ ] Phase 3: Category C doc mutations — 11 actions
- [ ] Phase 4: Category D expression reads — 1 action
