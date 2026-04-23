# Rust YAML Tool Runtime — port plan

Audit item #2 from the genericity review: *port Flask's tool YAML
pattern to one native app to validate it works cross-language.*
Flask proves the pattern in `jas_flask/static/js/engine/`; this doc
plans the Rust port in `jas_dioxus/`.

## Goal

One Rust tool (Selection) runs entirely from its `workspace/tools/selection.yaml`
spec, via the same event → scope → effects → mutation pipeline
Flask uses. The native `selection_tool.rs` is deleted. The remaining
14 native tools stay unchanged until this pattern is validated.

Success criteria:

- All existing Selection tool tests pass against the YAML-driven implementation
- `scripts/genericity_check.py` baseline decreases: `rust.tool_files: 18 → 17`
- No observable behavior change in `dx serve` (marquee, drag, alt-copy, shift-extend, keyboard nudge)

## Starting state

**Rust already has** (`jas_dioxus/src/interpreter/`, ~13k lines):
- `expr_lexer.rs`, `expr_parser.rs`, `expr_eval.rs`, `expr_types.rs`, `expr.rs` — expression layer with AST caching
- `scope.rs` — immutable lexical scope chain
- `state_store.rs` — reactive state, panel-scoped + global
- `effects.rs` — `set`, `toggle`, `show_dialog`, `call_action`, `navigate`, `emit`
- `schema.rs` — state field type/nullability checks

**Rust is missing**, relative to Flask JS engine:
- `doc.*` effect handlers (bridge effects → `Controller`)
- YAML-driven tool that implements `CanvasTool` by reading handlers from YAML
- Document-aware evaluator primitives (`hit_test`, `selection_contains`)
- `$event` scope construction from `on_press` / `on_move` / `on_release`
- `$tool.<id>.*` read/write routed to per-tool state

## Phase breakdown

Each phase ends in a committable, test-green state. Phases land as
separate commits; the branch merges as a unit when Phase 5 is done.

### Phase 1 — `doc.*` effect handlers

**Scope**: extend `interpreter/effects.rs` with `doc.*` dispatch that
maps to `Controller` methods. No tool integration yet.

Effects to implement (matching Flask's `effects.mjs`):

| Effect | Maps to |
|---|---|
| `doc.snapshot` | `Controller::snapshot()` |
| `doc.clear_selection` | `Controller::clear_selection()` |
| `doc.set_selection` | `Controller::set_selection(paths)` |
| `doc.add_to_selection` | `Controller::add_to_selection(path)` |
| `doc.toggle_selection` | toggle path in/out of selection |
| `doc.translate_selection` | `Controller::move_selection(dx, dy)` |
| `doc.copy_selection` | `Controller::copy_selection(dx, dy)` |
| `doc.select_in_rect` | hit-test rect → `set_selection` or `add_to_selection` |
| `doc.delete_selection` | `Controller::delete_selection()` |

**Tests first** — `interpreter/effects_doc_test.rs`:
- Each effect in isolation: given a `Model` + YAML effect, expected `Document` + `Selection` state
- Fixtures mirror `jas_flask/tests/js/test_doc_effects.mjs` where possible

**Risk**: `Controller` methods take `&mut Model` but effects currently take `&mut StateStore`. Need a combined `EffectCtx { model: &mut Model, store: &mut StateStore, scope: &Scope }` passed through runEffects.

### Phase 2 — Document-aware evaluator primitives

**Scope**: register `hit_test`, `selection_contains`, `element_bounds`
as evaluator functions, using Flask's per-dispatch registration
pattern (setup before dispatch, teardown after).

**Tests first** — `interpreter/expr_eval_doc_test.rs`:
- `hit_test(rect, x, y)` returns the path of the topmost hit
- `selection_contains(selection, path)` returns bool
- Primitives unavailable outside dispatch (teardown works)

**Risk**: Value needs to hold a `Document` reference or the Document
has to be serialized to JSON for each dispatch. Flask sidesteps by
passing plain JS objects. Proposed: add a `Value::Document(Rc<Document>)`
variant with `.get(path)` access; primitives read through it.

Alternative: keep Document native and have primitives close over
`&Model` captured by the registration. This is closer to Flask's
pattern and avoids reshaping Value.

### Phase 3 — `YamlTool` struct + `CanvasTool` impl

**Scope**: a single struct that implements `CanvasTool` by reading
handler lists from a YAML tool spec at construction.

```rust
pub struct YamlTool {
    spec: ToolSpec,              // parsed workspace/tools/<id>.yaml
    tool_state: HashMap<...>,    // holds $tool.<id>.* values
}

impl CanvasTool for YamlTool {
    fn on_press(&mut self, model: &mut Model, x, y, shift, alt) {
        let scope = build_event_scope("mousedown", x, y, shift, alt, &self.tool_state);
        run_effects(&self.spec.handlers.on_mousedown, &scope, model, &mut self.tool_state);
    }
    // ... on_move, on_release, draw_overlay
}
```

**Tests first** — `tools/yaml_tool_test.rs`:
- Given a mock YAML spec with a single effect (`set $tool.foo.x = $event.x`), dispatching `on_press(10, 20, ...)` leaves `tool_state.foo.x == 10`
- `doc.*` effects inside handlers mutate Model correctly

**Risk**: `draw_overlay` needs a renderer that takes YAML overlay specs and produces canvas draw calls. Flask returns SVG strings; Rust uses `web_sys::CanvasRenderingContext2d`. Need a small YAML-overlay-to-canvas translator (simpler than the full `renderer.rs`).

### Phase 4 — Validate against Selection tool

**Scope**: register a `YamlTool` instance for Selection alongside
the existing `SelectionTool`. Route Selection dispatch to the YAML
version behind a runtime flag (`ToolKind::SelectionYaml` or a
module-level const).

**Tests** — copy every existing `selection_tool_test.rs` case and
run it against `YamlTool::from_spec(&workspace.tools["selection"])`.

This is the validation gate. If Selection tests pass against YAML,
the pattern works. If not, diagnose divergences before Phase 5.

### Phase 5 — Cutover + cleanup

**Scope**:
- Delete `src/tools/selection_tool.rs`
- Delete `ToolKind::SelectionYaml` flag; Selection uses `YamlTool` unconditionally
- Remove native-selection branches from `tool_factory.rs`
- Run `python scripts/genericity_check.py --update-baseline` → baseline drops `rust.tool_files` 18 → 17
- Commit the updated baseline in the same PR

## Out of scope for this branch

- Porting the other 14 tools. Each is its own PR after the Selection
  pattern is validated. ~4-6 hours per tool if the runtime works.
- Porting to Swift / OCaml / Python. Those are subsequent branches
  per CLAUDE.md propagation order (Rust → Swift → OCaml → Python).
- Overlay renderer for arbitrary SVG elements. The Selection tool's
  overlay is a single dashed rectangle; the translator only needs to
  handle that plus a few SVG primitives for the other drawing tools.
- YAML schema evolution. Assume `workspace/tools/*.yaml` shape is
  frozen at its current form (from `flask-parity-design`).

## Risks + open questions

**R1: Evaluator function registration ergonomics.** Flask registers
`hit_test` with a closure over the current Document for each
dispatch, then tears down after. Rust's evaluator supports built-in
functions via `expr_eval.rs`; per-dispatch dynamic registration is
not currently a supported pattern. Phase 2 needs to add one, probably
via a `thread_local!` primitive registry.

**R2: Value::Document or closure-captured Model?** Flask holds plain
JSON objects, so passing the document through scope is trivial. Rust
has strongly-typed `Document`. Two options:
- (a) Add `Value::DocumentRef(Rc<Document>)` and grow primitives to
  deconstruct it
- (b) Have primitives close over `&Model` captured at registration
  time and only expose simple shapes through Value

Leaning (b): less Value surface change, matches Flask's closure-over-Model
closer, but means primitives can't be pure — they read mutably-captured
state. Acceptable for now since they're scoped to a single dispatch.

**R3: Overlay rendering.** Selection's overlay is small (one rect),
but generalizing to "any tool's overlay from YAML" means implementing
a subset of SVG. Proposed: Phase 3 only handles `{ type: rect, … }`
and `{ type: circle, … }` overlays; extend in later tool-port branches
as needed.

**R4: Undo/redo integration.** Flask's `doc.snapshot` pushes to
the Model's undo stack. Rust's `Controller::snapshot()` does the same.
The YAML spec already calls `doc.snapshot` at the start of mutation-
producing handlers; the Rust port just needs to dispatch it. Should
be mechanical.

**R5: Web feature flag.** Core interpreter is feature-independent,
but `CanvasTool::draw_overlay` takes `web_sys::CanvasRenderingContext2d`,
which is `web`-only. `YamlTool` inherits this — fine for now. A
cleaner separation (render-layer abstraction) is deferred.

## Propagation plan (post-branch)

Once Rust Selection validates:

1. **Port remaining 14 Rust tools** — incremental, one tool per PR.
   Baseline reduction per PR: `rust.tool_files -= 1`.
2. **Propagate to Swift** — Swift has the same `CanvasTool` / `Controller`
   structure. Most of this plan applies with language translation.
3. **Propagate to OCaml** — OCaml has the interpreter; Phase 1-3
   port there, then Selection cutover.
4. **Propagate to Python** — last per CLAUDE.md order.

## Related documents

- `POLICY.md` §2 — genericity policy this work advances
- `NATIVE_BOUNDARY.md` — the 5 legitimately-native categories (tool code is not among them)
- `FLASK_PARITY.md` — the cross-language architectural context
- `scripts/genericity_check.py` — the CI lint that tracks the `rust.tool_files` baseline
- `jas_flask/static/js/engine/` — reference implementation being ported
- `workspace/tools/selection.yaml` — the input spec for the validation target
