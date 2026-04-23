# OCaml YAML Tool Runtime — port plan

Propagates the Rust/Swift tool-runtime migration (see
`RUST_TOOL_RUNTIME.md` / `SWIFT_TOOL_RUNTIME.md` and the memory
notes `project_rust_yaml_tool_runtime.md` /
`project_swift_yaml_tool_runtime.md`) to `jas_ocaml`. Per CLAUDE.md
propagation order (Rust → Swift → OCaml → Python), OCaml is next
after Swift. The YAML specs under `workspace/tools/*.yaml` are
language-independent; they port unchanged. Only the runtime needs
reimplementing in OCaml.

## Starting state

**jas_ocaml already has** (≈11.8k lines total across tools + runtime):

- Interpreter layer (`jas_ocaml/lib/interpreter/`):
    state_store.ml / expr_eval.ml / effects.ml / schema.ml /
    workspace_loader.ml — direct analogues of the Rust/Swift
    versions.
- Geometry layer (`jas_ocaml/lib/geometry/`): Element, Measure,
    Tspan, Svg, Binary, Normalize, Live. No path_ops or regular_shapes.
- Tool layer (`jas_ocaml/lib/tools/`): 19 tool files (see
    scripts/genericity_check.py baseline).

**OCaml is missing**, relative to the post-migration Rust/Swift runtime:

- `yaml_tool.ml` class implementing the `canvas_tool` class type
  by reading YAML handlers
- `doc.*` effects bridged to `Controller`
- Document-aware evaluator primitives (`hit_test`, `hit_test_deep`,
  `selection_contains`, `selection_empty`,
  `anchor_buffer_length`, `anchor_buffer_close_hit`,
  `buffer_length`)
- Thread-local-equivalent (ref-cell) point-buffer + anchor-buffer modules
- Geometry kernels: `path_ops.ml` and `regular_shapes.ml`
- Overlay render types: `rect` (with rx/ry), `line`, `polygon`,
  `star`, `buffer_polygon`, `buffer_polyline`, `pen_overlay`,
  `partial_selection_overlay`
- Scope-routed `set:` targets (`$tool.<id>.<key>`,
  `$state.<key>`, `$panel.<key>` dispatch)

## Goal

Replicate the Rust/Swift end-state in OCaml:
- 14 tools running from YAML (Selection, Rect, RoundedRect, Line,
  Polygon, Star, InteriorSelection, Lasso, Pencil, Pen,
  AddAnchorPoint, DeleteAnchorPoint, AnchorPoint, PathEraser,
  Smooth, PartialSelection — same list as Swift)
- 2 tools remaining native by policy (Type, TypeOnPath) per
  NATIVE_BOUNDARY.md §6
- `ocaml.tool_files` genericity baseline drops from its current
  value down to 2
- Zero behavior change in the GTK app

## Phase breakdown

Mirrors the Swift plan phases. Each phase lands as its own commit.

### Phase 1 — Scope-routed set + tool-scoped state
Audit `state_store.ml` and the effects `set:` handler:
- Add a `tools` section analogous to `panels`.
- Route `tool.<id>.<key>` / `state.<key>` / `panel.<key>` / bare
  targets.
- Update `eval_context` to include `tool:` in scope.

### Phase 2 — doc.* effect handlers
Add to effects.ml: snapshot, clear_selection, set_selection,
add_to_selection, toggle_selection, translate_selection,
copy_selection, select_in_rect, partial_select_in_rect.

### Phase 3 — Doc-aware primitives + buffer modules
Create doc_primitives.ml, point_buffers.ml, anchor_buffers.ml.
Register primitives in expr_eval.ml.

### Phase 4 — Geometry kernels + path-editing effects
path_ops.ml + regular_shapes.ml; doc.add_element + doc.path.* suite.

### Phase 5 — YamlTool class + overlay rendering
`yaml_tool.ml` implementing `canvas_tool`. Overlay dispatch with
render-type registry (rect / line / polygon / star /
buffer_polygon / buffer_polyline / pen_overlay /
partial_selection_overlay).

### Phase 6 — Selection tool validation
Swap `Selection_tool.selection_tool` for
`Yaml_tool.yaml_tool ~id:"selection"` in tool_factory. Port
Selection tests against the YAML variant.

### Phase 7+ — Per-tool migration
One commit per tool (or pairs):
Rect → RoundedRect → Line → Polygon → Star → InteriorSelection →
Lasso → Pencil → Pen → AnchorPoint → DeleteAnchorPoint →
AddAnchorPoint → PartialSelection → PathEraser → Smooth.

### Phase 8 — Cutover cleanup
Delete any remaining scaffolding (drawing_tool base, etc.), bump
genericity baseline, update memory.

## Out of scope for this branch
- Python propagation — separate branch after OCaml lands.
- Text tools (Type / TypeOnPath) permanent native per NATIVE_BOUNDARY.md §6.

## Related documents
- `SWIFT_TOOL_RUNTIME.md` — the plan this one mirrors
- `RUST_TOOL_RUNTIME.md` — the original plan
- `NATIVE_BOUNDARY.md` §6 — Type/TypeOnPath permanent-native decision
- `scripts/genericity_check.py` — CI lint tracking `ocaml.tool_files`
- `workspace/tools/*.yaml` — the 16 tool specs, ready to be driven by
  the OCaml runtime when it lands
