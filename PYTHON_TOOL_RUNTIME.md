# Python YAML Tool Runtime — port plan

Propagates the Rust/Swift/OCaml tool-runtime migration to `jas`
(the Python/Qt app). Last stop in the Rust → Swift → OCaml →
Python propagation order. YAML specs in `workspace/tools/*.yaml`
port unchanged; only the Python runtime needs reimplementing.

## Starting state

**jas already has:**
- Interpreter (`workspace_interpreter/`): state_store.py,
  effects.py, expr_eval.py, expr_types.py, color_util.py,
  validator.py — mature and directly analogous to the other apps.
- Geometry (`jas/geometry/`): element, measure, tspan, svg,
  binary, normalize. No path_ops or regular_shapes yet.
- Tools (`jas/tools/`): 19 *_tool.py files including Type +
  TypeOnPath (both permanent-native per NATIVE_BOUNDARY.md §6).

**Python is missing** vs the post-migration end-state:
- `YamlTool` class driving `canvas_tool` from YAML handlers
- `doc.*` effects bridged to Controller
- Doc-aware evaluator primitives (`hit_test`, `hit_test_deep`,
  `selection_contains`, `selection_empty`,
  `anchor_buffer_length`, `anchor_buffer_close_hit`,
  `buffer_length`)
- Point-buffer + anchor-buffer modules
- Geometry kernels: `path_ops.py`, `regular_shapes.py`
- Overlay render types: rect / line / polygon / star /
  buffer_polygon / buffer_polyline / pen_overlay /
  partial_selection_overlay
- Scope-routed `set:` targets (`$tool.<id>.<key>`,
  `$state.<key>`, `$panel.<key>` dispatch)
- Math primitives in expr_eval not already present

## Goal

Replicate Rust/Swift/OCaml end-state:
- 14 tools YAML-driven: Selection, InteriorSelection, Line, Rect,
  RoundedRect, Polygon, Star, Pen, AnchorPoint, DeleteAnchorPoint,
  AddAnchorPoint, Pencil, PartialSelection, PathEraser, Smooth,
  Lasso.
- 2 tools permanent-native: Type, TypeOnPath
  (NATIVE_BOUNDARY.md §6).
- `python.tool_files` baseline: 2 (currently 19).

## Phase breakdown

Mirrors the Swift/OCaml plans. Each phase lands as its own commit.

### Phase 1 — Scope-routed set + tool-scoped state
- Add a `_tools` dict to StateStore.
- Route `tool.<id>.<key>` / `state.<key>` / `panel.<key>` / bare
  in effects.py's set handler.
- Expose `tool` key in `eval_context`.

### Phase 2 — doc.* effect handlers
doc.snapshot, clear_selection, set_selection, add_to_selection,
toggle_selection, translate_selection, copy_selection,
select_in_rect, partial_select_in_rect,
select_polygon_from_buffer.

### Phase 3 — Doc-aware primitives + buffer modules
doc_primitives.py (hit_test, hit_test_deep, selection_contains,
selection_empty). point_buffers.py + anchor_buffers.py. Register
primitives in expr_eval.py (math too).

### Phase 4 — Geometry kernels + path-editing effects
path_ops.py + regular_shapes.py. doc.add_element + doc.path.* suite.

### Phase 5 — YamlTool class + overlay rendering
jas/tools/yaml_tool.py conforming to the existing tool protocol.
Overlay dispatch with render-type registry.

### Phase 6 — Selection tool validation
Swap SelectionTool for YamlTool("selection") in the tool registry.
Port Selection tests.

### Phase 7+ — Per-tool migration
One commit per tool (or pairs). Complexity order matches Swift:
Rect → RoundedRect → Line → Polygon → Star → InteriorSelection →
Lasso → Pencil → Pen → AnchorPoint → DeleteAnchorPoint →
AddAnchorPoint → PartialSelection → PathEraser → Smooth.

### Phase 8 — Cleanup
Delete DrawingToolBase (any other scaffolding). Bump
`python.tool_files` baseline. Update memory.

## Out of scope
- Flask stays generic per CLAUDE.md — no migration needed there.
- Type / TypeOnPath stay native per NATIVE_BOUNDARY.md §6.

## Related documents
- RUST_TOOL_RUNTIME.md, SWIFT_TOOL_RUNTIME.md, OCAML_TOOL_RUNTIME.md
- NATIVE_BOUNDARY.md §6
- scripts/genericity_check.py — `python.tool_files` lint
- workspace/tools/*.yaml — the 16 specs
