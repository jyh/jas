# Phase 0 Audit: hardcoded actions + schema gaps

Produced as a standalone research pass (no code changes) to feed the
YAML-interpreter refactor planned in `PLAN.md`. Two parts:

- **Part A**: action divergence — where the 18 hardcoded native action
  arms disagree with their YAML `effects:` block, or with each other.
- **Part B**: schema gap — where YAML expressions reference namespaces
  or properties not declared in `workspace/runtime_contexts.yaml`.

Scope: all YAML files under `workspace/` (27 files). Rust source in
`jas_dioxus/src/interpreter/renderer.rs`; cross-language references
found via grep across `jas/` (Python), `jas_ocaml/lib/` (OCaml), and
`JasSwift/Sources/` (Swift).

---

## Part A — Action divergence audit

### Key findings (short)

1. **One real semantic divergence**: `swap_fill_stroke`. YAML uses
   `- swap: [fill_color, stroke_color]`, but the `swap:` effect
   implementation in `renderer.rs` lines 660–669 operates on
   `stroke_panel` fields, not on global fill/stroke state. The
   hardcoded Rust arm `st.swap_fill_stroke()` does the right thing,
   masking a broken YAML primitive. **Python and OCaml both implement
   global-state swap and agree with Rust.** The YAML effect would
   silently do the wrong thing if the Rust arm were removed.

2. **One cross-language behavioral divergence** (NATIVE-DIVERGES):
   `new_layer`. Rust inserts the new layer above the topmost
   panel-selected layer (`min(panel_sel) + 1`). OCaml appends the new
   layer at the top of the layer stack. The YAML description matches
   Rust's behavior ("inserted above the topmost panel-selected layer").
   OCaml's implementation is a drift bug that should be fixed before
   migration.

3. **15 of 18 actions have `log:` placeholder YAML** — most of Category
   C. These don't diverge from YAML so much as bypass it entirely. Real
   logic lives only in native code. Nothing to reconcile here; they
   just need to be migrated during Phases 1–3.

4. **Two actions with real YAML that does NOT actually work today.**
   Follow-up check of `apply_set_effects` (renderer.rs:739–755)
   revealed the `set:` primitive handles only `fill_on_top` and
   `stroke_*` fields; every other key is silently dropped. That makes
   `set_active_color_none` (uses `set: { fill_color: null }`),
   `set_active_color` (uses `set: { fill_color: "param.color" }`),
   `reset_fill_stroke` (uses `set:` for `fill_color`, `stroke_color`,
   `stroke_width`, etc.), and `select_tool` (uses
   `set: { active_tool: "param.tool" }`) all **non-functional via YAML**.
   The Rust hardcoded arms are the only path that actually works; they
   are NOT redundant. See Bug A3 below.

5. **Swift coverage is thin.** Swift has no hardcoded dispatch for any
   of the 18 actions in `Sources/Interpreter/`; it appears to rely on
   YAML-driven effects already. For actions currently mostly as
   placeholders, this means Swift just doesn't do them. Needs
   confirmation — may be a latent feature gap rather than a divergence.

6. **Python is mostly stubbed for Category C**. Tier-3 layer operations
   have `pass` placeholders in menu handlers. Same story as Swift: a
   feature gap, not a divergence. Python's Category A/B implementations
   exist and agree with Rust.

### Per-action summary table

| # | Action | Verdict | Notes | Fix priority |
|---|---|---|---|---|
| 1 | `set_active_color` | ENGINE-GAP | YAML `set: { fill_color: ... }` dropped by engine (Bug A3) | Phase 1/2 |
| 2 | `set_active_color_none` | ENGINE-GAP | YAML `set: { fill_color: null }` dropped by engine (Bug A3) | Phase 1 |
| 3 | `swap_fill_stroke` | **DIVERGES** | YAML `swap:` targets wrong state (Bug A1) | **High — bug fix in Phase 1** |
| 4 | `reset_fill_stroke` | ENGINE-GAP | 3 of 24 `set:` fields dropped (`fill_color`, `stroke_color`, `stroke_width`) | Phase 1 |
| 5 | `select_tool` | ENGINE-GAP | YAML `set: { active_tool: ... }` dropped by engine (Bug A3) | Phase 1/2 |
| 6 | `enter_isolation_mode` | PLACEHOLDER | YAML is `log:` only | Phase 3 |
| 7 | `exit_isolation_mode` | PLACEHOLDER | YAML is `log:` only | Phase 1 (simple pop) |
| 8 | `layer_options_confirm` | PLACEHOLDER | YAML is `log:` only | Phase 3 |
| 9 | `open_layer_options` | PARTIAL | YAML opens dialog but doesn't populate params from layer | Phase 4 |
| 10 | `new_layer` | **NATIVE-DIVERGES** | Rust/OCaml disagree on insertion position | **Medium — fix OCaml before Phase 3** |
| 11 | `delete_layer_selection` | PLACEHOLDER | `log:` only | Phase 3 |
| 12 | `duplicate_layer_selection` | PLACEHOLDER | `log:` only | Phase 3 |
| 13 | `new_group` | PLACEHOLDER | `log:` only | Phase 3 |
| 14 | `toggle_all_layers_visibility` | PLACEHOLDER | `log:` only | Phase 3 (first target) |
| 15 | `toggle_all_layers_outline` | PLACEHOLDER | `log:` only | Phase 3 |
| 16 | `toggle_all_layers_lock` | PLACEHOLDER | `log:` only | Phase 3 |
| 17 | `flatten_artwork` | PLACEHOLDER | `log:` only | Phase 3 |
| 18 | `collect_in_new_layer` | PLACEHOLDER | `log:` only | Phase 3 |

### Bugs found during the audit

Three concrete bugs. A1 and A3 are Phase 1 engine work; A2 is a parity
fix that must land before Phase 3:

**Bug A1 — `swap:` effect primitive is broken.** In
`jas_dioxus/src/interpreter/renderer.rs` lines 660–669, the `swap:`
effect handler reads from and writes to `st.stroke_panel` fields
via `get_stroke_state_field` / `set_stroke_state_field`. For the
`swap_fill_stroke` action (and any other top-level field swap), this
operates on the wrong state. Fix: either generalize `swap:` to target
top-level state fields (matching how the Rust `st.swap_fill_stroke()`
method works), or rename the current primitive to
`swap_stroke_panel_state:` and add a new `swap:` that targets global
state. Apply the fix in all 4 native language implementations. Verify
Python/OCaml have the correct primitive implementation before
deleting their hardcoded `swap_fill_stroke` arms.

**Bug A2 — `new_layer` insertion position diverges between Rust and
OCaml.** Rust (`renderer.rs:403–408`) computes
`insert_pos = min(panel_sel where path.len() == 1) + 1` falling back
to `layers.len()`. OCaml (`panel_menu.ml:96–108`) always appends to
the end. The YAML description matches Rust. Fix OCaml to match Rust
before Phase 3 migration — otherwise the YAML-migrated action will
produce different results depending on which app runs it.

**Bug A3 — `set:` primitive covers only 2 field classes.**
`apply_set_effects` in `renderer.rs:739–755` only handles `fill_on_top`
and any key prefixed with `stroke_`. Every other key hits the `_ => {}`
branch and is silently dropped. This is the root cause of four of the
ENGINE-GAP verdicts above: YAML that looks correct for `set_active_color`,
`set_active_color_none`, `reset_fill_stroke`, and `select_tool` is
actually a no-op because the engine doesn't support the keys they use.

Implications:
- `apply_set_effects` must be rewritten in Phase 1 to handle every
  addressable state field (`fill_color`, `stroke_color`, `stroke_width`,
  `active_tool`, `fill_on_top`, and whatever else state fields exist —
  see `workspace/state.yaml` for the full list).
- No typed coercion exists today (no hex→`Color`, no string→`ToolKind`).
  Category B work is a prerequisite for Color/ToolKind-typed fields to
  be usable via `set:`, not an optional follow-up.
- **Cross-language check needed**: the same narrow scope likely exists
  in the Python / OCaml / Swift equivalents of `apply_set_effects`, but
  may differ in detail. If one language already supports more than Rust,
  that's latent drift. Scope includes auditing those implementations
  during Phase 1 startup.
- None of the four ENGINE-GAP actions' Rust arms are "redundant" — they
  are the only thing that actually works today. They can only be
  deleted after Bug A3 is fixed AND Category B typed coercion is in.

### Open questions flagged during the audit

- ~~Does `apply_set_effects` coerce string values to typed fields?~~
  **Answered: no.** `apply_set_effects` in `renderer.rs:739–755` handles
  only `fill_on_top` and `stroke_*` keys; everything else is silently
  dropped. Added as Bug A3 above. Typed coercion does not exist at all.

- For `open_layer_options`, the Rust arm builds dialog params from
  layer properties. Once Phase 4 lands path navigation, the YAML would
  become:
  ```yaml
  effects:
    - open_dialog:
        id: layer_options
        params:
          mode: "param.mode"
          layer_id: "param.layer_id"
          name: "active_document.at(param.layer_id).name"
          lock: "active_document.at(param.layer_id).common.locked"
          # ... etc
  ```
  Confirm this shape during Phase 4 implementation.

---

## Part B — Schema gap audit

### Inventory of root identifiers in YAML expressions

Scanned all 27 YAML files. Found ~450 expression sites. Root identifiers
fall into three tiers:

**Implicit namespaces** (always or contextually available; used but not
formally declared in `runtime_contexts.yaml`):

| Root | Purpose | Distinct props used | Schema-documented? |
|---|---|---|---|
| `state` | Global app state (from `StateStore._state`) | 47 | **No — not in runtime_contexts.yaml** |
| `panel` | Active panel state | 25 | **No** |
| `theme` | Theme colors / sizes | ~10 paths (`theme.colors.*`, `theme.sizes.*`) | **No** |
| `param` | Action / dialog parameters | 25 | **No** (expected — these are per-action) |
| `dialog` | Open dialog state | 15 | **No** (expected — per-dialog) |
| `data` | External data (swatch_libraries) | 2 | **No** |
| `event` | UI event context | 10 (`event.alt`, `event.key`, `event.client_x`, etc.) | **No — new find; I didn't know this existed** |
| `node` | Tree-row rendering context (layers panel) | 12 (`node.id`, `node.locked`, `node.ancestor_layer_color`, etc.) | **No — new find** |
| `prop` | Template instantiation (tab templates) | 1 (`prop.index`) | **No — new find** |
| `_index` | Auto-bound in `foreach` (position in source) | — | **No — implicit language feature** |

**Declared namespaces** (in `runtime_contexts.yaml`):

| Root | Declared props | Used in expressions |
|---|---|---|
| `active_document` | `is_modified`, `has_filename`, `filename`, `any_modified`, `has_selection`, `selection_count`, `can_undo`, `can_redo`, `zoom_level` | 8 of 9 declared properties are used; plus **5 undeclared** (see below) |
| `workspace` | `has_saved_layout`, `active_layout_name` | 1 of 2 used |

**Lexical (foreach-bound)**: `lib`, `swatch`, `level` — each scoped to a
specific `foreach` body. Not global. Not schema issues.

### Schema gaps

#### Undeclared properties on `active_document` (5)

Used in YAML expressions but missing from `runtime_contexts.yaml`:

| Property | Type (inferred) | Where used | Count |
|---|---|---|---|
| `active_document.layers_panel_selection_count` | number | `actions.yaml:1045,1057,1070,1083,1214,1338`; `panels/layers.yaml:344,365,382,665` | 10 |
| `active_document.layers_panel_selection_is_container` | bool | `actions.yaml:1214`; `panels/layers.yaml:365` | 2 |
| `active_document.layers_panel_selection_has_group` | bool | `actions.yaml:1095`; `panels/layers.yaml:377,662` | 3 |
| `active_document.element_tree` | object (tree) | `panels/layers.yaml:507` (foreach source) | 1 |
| `active_document.element_selection` | array\<string\> | `panels/layers.yaml:509` | 1 |

**Semantic concern noted during audit**: three of these five
(`layers_panel_selection_count`, `_is_container`, `_has_group`) are
arguably panel state, not document state. They likely ended up on
`active_document` because that was the only namespace with
computed-property machinery. `PLAN.md` already flags this as an
accretion-cleanup opportunity for after Phase 4 lands path navigation.

#### Undocumented implicit namespaces (4)

`event`, `node`, `prop`, `_index` are used in YAML expressions but not
declared anywhere. The expression evaluator accepts them because it's
generic, but the 4 native-language implementations must all agree on
what these names bind to and what properties exist. **This is latent
parity-drift surface.**

Recommendation: add these to `runtime_contexts.yaml` (or a sibling
schema file) with:
- `event`: UI event context, bound in action dispatch handlers.
  Properties: `alt`, `key`, `target_id`, `target_class`, `client_x`,
  `client_y`, `offset_x`, `offset_y`, `edge`, `resize_cursor`.
- `node`: Tree-row context, bound per-row during layers-panel rendering.
  Properties: `id`, `name`, `type`, `type_label`, `is_container`,
  `locked`, `visibility`, `element_selected`, `panel_selected`,
  `ancestor_layer_color`, `depth`, `search_ancestor_only`.
- `prop`: Template instantiation context. Property: `index`.
- `_index`: Implicit index variable added by `foreach`. Document as a
  language feature, not a namespace.

#### Dead declarations (2)

Declared in `runtime_contexts.yaml` but not used in any expression:

- `active_document.zoom_level` — declared (number), never read in
  expressions. Verify whether this is (a) set via imperative API only,
  (b) intended for future use, or (c) truly dead. If (c), remove.
- `workspace.active_layout_name` — same situation.

Low priority — these aren't blocking anything, just schema noise.

#### Namespaces used but not declared (core schema gap)

The biggest finding: **`state`, `panel`, `theme`, `param`, `dialog`,
`data` are core namespaces used in hundreds of expressions but have no
schema documentation.** `runtime_contexts.yaml` only declares
`active_document` and `workspace`. Everything else is implicit.

This matches constraint #5 in `PLAN.md` ("schema must describe every
free variable") and is the highest-impact schema work.

Recommendation: extend `runtime_contexts.yaml` (or add a companion
`workspace/namespaces.yaml`) to declare all implicit namespaces with
their properties, types, and defaults. Source of truth for each:

- `state`: read from `workspace/state.yaml` (which already enumerates
  global state fields — this should feed into the schema).
- `panel`: enumerated across `workspace/panels/*.yaml` per panel —
  needs consolidation.
- `theme`: `workspace/theme.yaml`.
- `param`, `dialog`: per-action / per-dialog; not global. These might
  not belong in `runtime_contexts.yaml` but should be declared at the
  action / dialog level (where they already have `params:` blocks).

### Schema work to do during Phase 1

Not blocking — can be done in parallel with Category A implementation.

1. Add the 5 undeclared `active_document` properties to
   `runtime_contexts.yaml`.
2. Add `event`, `node`, `prop` as declared namespaces (new entries or
   new file).
3. Document `_index` as a foreach language feature in interpreter docs.
4. Decide on the fate of `zoom_level` / `active_layout_name` — remove
   or mark "imperative-only".
5. **Bigger**: declare `state`, `panel`, `theme` in the schema — feed
   from existing YAML that already defines their shape.

---

## What happens next

Phase 0 is complete. The audit expanded Phase 1's scope; the biggest
shift is that `set:` engine support (Bug A3) is the core Phase 1 work,
not a small prep task as originally planned.

Recommended Phase 1 ordering:

1. **Audit the Python/OCaml/Swift equivalents of `apply_set_effects`**
   to find parallel A3-style gaps and any cross-language divergence.
   This feeds the scope of step 3.
2. **Fix Bug A1**: decide the scope of the `swap:` fix (generalize to
   global state vs. rename + add a new global-state variant).
   Implement in `workspace_interpreter/` spec first, then per language.
3. **Fix Bug A3**: rewrite `apply_set_effects` across all 4 languages
   so every top-level state field in `workspace/state.yaml` is
   addressable via `set:`. Add null and string-passthrough support.
   Typed coercion (Color, ToolKind) is deferred to Category B unless
   needed during step 4.
4. **Build other Category A primitives**: `pop:`, `reset:` (if not
   subsumed by generalized `set:`).
5. **Migrate actions to YAML**: `exit_isolation_mode`, `swap_fill_stroke`
   first (simplest). `set_active_color_none`, `reset_fill_stroke`,
   `set_active_color`, `select_tool` only after Category B lands the
   typed coercion these depend on (so they'll actually work via YAML).
6. **Fix Bug A2**: OCaml `new_layer` insertion position — must land
   before Phase 3. Can happen in parallel with the above.
7. **Schema gap fixes** (Part B findings): add the 5 missing
   `active_document` properties; declare `event`, `node`, `prop`;
   declare core namespaces `state`/`panel`/`theme` (biggest, deferable).
8. **Investigate Swift/Python feature gaps** for tier-3 layer operations
   — determines whether Phase 3 migration also adds new behavior.
