# Swift YAML Tool Runtime — port plan

Propagates the Rust tool-runtime migration (see
`RUST_TOOL_RUNTIME.md` + `project_rust_yaml_tool_runtime.md`) to
`JasSwift`. Per CLAUDE.md propagation order (Rust → Swift → OCaml →
Python), Swift is next after Rust. The YAML specs under
`workspace/tools/*.yaml` are language-independent; they port
unchanged. Only the runtime needs reimplementing in Swift.

## Starting state

**JasSwift already has** (≈4500 total native tool lines, much more
compact than Rust's pre-migration ≈18k):

- Interpreter layer (`JasSwift/Sources/Interpreter/`):
    Effects.swift (2075 lines), ExprEval.swift (1362 lines),
    StateStore.swift (250 lines), Scope.swift, ExprTypes.swift,
    Schema.swift, WorkspaceLoader.swift — substantial and
    directly analogous to the Rust version.
- Geometry layer (`JasSwift/Sources/Geometry/`): Element, Measure,
    Tspan, Svg, Binary, Normalize. No path_ops or regular_shapes yet.
- Tool layer (`JasSwift/Sources/Tools/`): 18 tool files, many
    compact thanks to shared base classes (`DrawingToolBase`,
    `SelectionToolBase`).

**Swift is missing**, relative to the post-migration Rust runtime:

- `YamlTool` class implementing `CanvasTool` by reading YAML handlers
- `doc.*` effects bridged to `Controller`
- Document-aware evaluator primitives (`hit_test`, `hit_test_deep`,
  `selection_contains`, `selection_empty`,
  `anchor_buffer_length`, `anchor_buffer_close_hit`,
  `buffer_length`)
- Thread-local point-buffer + anchor-buffer modules
- Geometry kernels: `path_ops.swift` and `regular_shapes.swift`
- Overlay render types: `rect` (with rx/ry), `line`, `polygon`,
  `star`, `buffer_polygon`, `buffer_polyline`, `pen_overlay`,
  `partial_selection_overlay`
- Scope-routed `set:` targets (`$tool.<id>.<key>`,
  `$state.<key>`, `$panel.<key>` dispatch)
- Math primitives not already in ExprEval: `hypot`, `sqrt` etc.

## Goal

Replicate the Rust end-state in Swift:
- `16` tools running from YAML (Selection, Rect, RoundedRect, Line,
  Polygon, Star, InteriorSelection, Lasso, Pencil, Pen,
  AddAnchorPoint, DeleteAnchorPoint, AnchorPoint, PathEraser,
  Smooth, PartialSelection)
- `2` tools remaining native by policy (Type, TypeOnPath) per
  NATIVE_BOUNDARY.md §6
- `swift.tool_files` genericity baseline drops from its current
  value down to 2
- Zero behavior change in the AppKit app

## Phase breakdown

Mirrors the Rust plan phases (RUST_TOOL_RUNTIME.md §Phase breakdown)
with Swift-specific adjustments. Each phase lands as its own commit
or small group of commits.

### Phase 1 — Scope-routed set + tool-scoped state

Audit the Swift `StateStore.swift` and effects `set:` handler:
- Add a `tool` section analogous to `panels`.
- Route `tool.<id>.<key>` / `state.<key>` / `panel.<key>` / bare
  targets through `set_by_scoped_target`-equivalent.
- Update `evalContext()` to include `tool:` at the top of scope.

Tests: small StateStore and Effects unit tests mirroring the
Rust set_routes_* cases.

### Phase 2 — doc.* effect handlers

Add to `Interpreter/Effects.swift`:
```
doc.snapshot
doc.clear_selection / set_selection / add_to_selection
    / toggle_selection / translate_selection / copy_selection
    / select_in_rect / partial_select_in_rect
    / select_polygon_from_buffer
doc.add_element  (type: rect/rounded_rect/line/polygon/star,
                  fill/stroke → model defaults on omission)
doc.add_path_from_buffer
doc.add_path_from_anchor_buffer
doc.path.delete_anchor_near
doc.path.insert_anchor_on_segment_near
doc.path.probe_anchor_hit / commit_anchor_edit
doc.path.erase_at_rect / smooth_at_cursor
doc.path.probe_partial_hit / commit_partial_marquee
doc.move_path_handle
buffer.push / clear
anchor.push / set_last_out / pop / clear
```

Each effect maps to a `Controller` method or native kernel call.

### Phase 3 — Doc-aware primitives + buffer modules

Create `Interpreter/DocPrimitives.swift` with `hit_test`,
`hit_test_deep`, `selection_contains`, `selection_empty`. Use a
`@MainActor` (or single-threaded-equivalent) module-level
`Optional<Document>` rather than the Rust thread-local —
AppKit runs on main thread so no guard needed.

Create `Interpreter/PointBuffers.swift` and
`Interpreter/AnchorBuffers.swift` with the named-buffer APIs.

Register the primitives in `ExprEval.swift::evalFunc` alongside
existing math / list / color primitives.

### Phase 4 — Geometry kernels

`Geometry/PathOps.swift` with:
```
deleteAnchorFromPath, lerp, evalCubic, closestOnLine,
closestOnCubic, splitCubic, closestSegmentAndT,
insertPointInPath + InsertAnchorResult,
cmdEndpoint, cmdStartPoint(s), flattenWithCmdMap,
liangBarskyTMin/Max, lineSegmentIntersectsRect,
flatIndexToCmdAndT, splitCubicCmdAt, splitQuadCmdAt,
entryCmd, exitCmd, EraserHit, findEraserHit,
splitPathAtEraser
```

`Geometry/RegularShapes.swift` with `regularPolygonPoints` and
`starPoints`.

### Phase 5 — YamlTool class + CanvasTool impl

`Tools/YamlTool.swift`:
- Holds a `ToolSpec` (parsed from workspace.json's `tools.<id>`)
  and a private `StateStore` seeded with state defaults.
- Implements the Swift `CanvasTool` protocol: onPress → builds
  `$event` scope → registers document → runs effects → tears down.
- Handles onDblclick and onKeyEvent dispatch → `on_dblclick` /
  `on_keydown` YAML handlers.
- Overlay dispatch with render-type registry (rect / line / polygon
  / star / buffer_polygon / buffer_polyline / pen_overlay /
  partial_selection_overlay).

### Phase 6 — Selection tool validation

Swap `SelectionTool` for `YamlTool("selection")` in
`ActiveDocumentView` (or wherever tools are wired). Port Selection's
existing behavioral tests to run against the YamlTool variant.
Validate in-app by running `JasSwift` and exercising marquee, click,
shift-click, drag, Alt+drag, Escape.

Only after parity is confirmed does this phase end. This is the
"prove the pattern works cross-language again" gate.

### Phase 7+ — Per-tool migration

One commit per tool (or pairs where they share infra — as Rust did
for Polygon+Star and PathEraser+Smooth). In complexity order:
Rect → RoundedRect → Line → Polygon → Star → InteriorSelection →
Lasso → Pencil → Pen → AnchorPoint → DeleteAnchorPoint →
AddAnchorPoint → PartialSelection → PathEraser → Smooth.

Each commit:
1. Wire `YamlTool("<id>")` in the tool registry
2. Delete the native `<Name>Tool.swift`
3. Port behavioral tests
4. Run `scripts/genericity_check.py --update-baseline`
5. Verify in `JasSwift` app

### Phase 8 — Cutover cleanup

Delete base classes (`DrawingToolBase`, `SelectionToolBase`)
that have no remaining conformers. Document the final state in
the Rust tool runtime memory note, noting Swift propagation is
done.

## Out of scope for this branch

- OCaml + Python propagation — separate branches after Swift lands
- Porting TextEditSession-backed Type / TypeOnPath — permanent
  native per NATIVE_BOUNDARY.md §6
- Refactoring Swift's existing tool-dispatch plumbing beyond what
  the migration requires

## Risks + open questions

**R1: Swift already has a compact tool layer.** The absolute
line-count win is smaller than Rust (8500→?). The main benefits
are cross-language consistency and the "add a feature in one
place" payoff. Worth flagging if the payoff debate reopens.

**R2: Overlay rendering APIs differ from web_sys.** Swift uses
`CGContext` / `NSBezierPath`; the render-type dispatch has to
translate the same YAML spec to those APIs. Straightforward
but each render type needs a Swift counterpart.

**R3: Keyboard routing.** Swift's keyboard handling uses
`NSEvent` with different modifier flags and key codes. The Rust
fix for `on_key` vs `on_key_event` dispatch (rust-yaml-pen-tool
post-merge commit 483e9c5) will need a Swift analogue — check
the protocol's equivalent methods early in Phase 5.

**R4: TextEditSession.** Swift's `TextEditSession.swift` (351
lines) is a distinct implementation from Rust's; the text tools
keeping it as native is already baked into NATIVE_BOUNDARY.md §6,
so Phase 7+ skips them.

**R5: Multi-session commitment.** This is a big branch. Ideally
it stays green between sessions — each phase is a committable
checkpoint. If a phase goes multi-session, its sub-commits still
keep the main branch working (YamlTool coexists with native tools
until the per-tool delete-and-swap).

## Related documents

- `RUST_TOOL_RUNTIME.md` — the plan this one mirrors
- `NATIVE_BOUNDARY.md` §6 — Type/TypeOnPath permanent-native decision
- `POLICY.md` §2 — genericity policy
- `scripts/genericity_check.py` — CI lint tracking `swift.tool_files`
- `workspace/tools/*.yaml` — the 16 tool specs, ready to be driven by
  the Swift runtime when it lands
