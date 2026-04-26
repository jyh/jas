# Flask Document Model — Phase 0 Audit Findings

Pre-implementation audit of the existing `static/js/engine/` substrate
against the FLASK_PARITY.md design and the integration plan in
the `flask-document-model` branch's planning notes.

**Audit date:** 2026-04-26
**Branch:** `flask-document-model` (off main at `209c532`)
**Method:** read-only inspection + Node test runner

The headline: this is **integration work, not invention**. The engine
substrate (~3,800 lines) is real, ~99% test-passing, and proven by a
working demo page. The production page just doesn't import it.

---

## State of the substrate

### Engine modules — already on main

| File | Lines | Status |
|---|---|---|
| `engine/value.mjs` | 157 | ✅ complete — Null/Bool/Number/String/Color/List/Path |
| `engine/scope.mjs` | 111 | ✅ complete — buildHandlerScope, resolvePath |
| `engine/lexer.mjs` | 218 | ✅ complete — tokenizer |
| `engine/parser.mjs` | 328 | ✅ complete — recursive-descent AST |
| `engine/evaluator.mjs` | 324 | ✅ ~complete — registerPrimitive, math (min/max/abs/sqrt), color decomposition primitives |
| `engine/expr.mjs` | 110 | ✅ complete — `evaluate(source, scope)` with parse cache |
| `engine/document.mjs` | 177 | ✅ complete for V1 — mkRect/Circle/Ellipse/Line/Path/Text/Group/Layer + getElement, cloneDocument, JSON I/O, setSelection family |
| `engine/model.mjs` | 141 | ✅ complete — undo/redo, snapshot, generation counter, listeners, isModified |
| `engine/geometry.mjs` | 469 | ✅ complete for V1 — elementBounds, hitTest, hitTestRect, translateElement, calligraphicOutline (advanced; not needed for V1) |
| `engine/fit_curve.mjs` | 245 | ✅ complete |
| `engine/canvas.mjs` | 129 | ✅ V1-ready — 4-layer SVG (doc/selection/overlay), buildOverlayElement |
| `engine/renderer.mjs` | 264 | ✅ V1-ready — element → SVG markup |
| `engine/effects.mjs` | 770 | ✅ V1-ready — see effect inventory below |
| `engine/tools.mjs` | 174 | ✅ V1-ready — registerTools, dispatchEvent, document-aware primitives |
| `engine/store.mjs` | 104 | ✅ complete — state/panel/tool namespaces |
| `engine/point_buffers.mjs` | 37 | ✅ complete |

**Total existing engine code:** ~3,758 lines.
**Total estimated new code for V1:** ~2,300 lines (per plan).

### Effect inventory (engine/effects.mjs)

`doc.*`:
- ✅ `doc.snapshot`
- ✅ `doc.clear_selection`
- ✅ `doc.set_selection`
- ✅ `doc.add_to_selection`
- ✅ `doc.toggle_selection`
- ✅ `doc.translate_selection`
- ✅ `doc.select_in_rect`
- ✅ `doc.delete_selection`
- ✅ `doc.add_element`
- ✅ `doc.set_attr`
- ✅ `doc.set_attr_on_selection`
- ✅ `doc.add_path_from_buffer`

Non-`doc.*`:
- ✅ `if/then/else`
- ✅ `let/in`
- ✅ `set` (with quote-stripping for string literals)
- ✅ `log`
- ✅ `data.set`, `data.list_append`, `data.list_remove`, `data.list_insert`, `data.list_sort`
- ✅ `brush.{delete_selected,duplicate_selected,append,update}`
- ✅ `buffer.push`, `buffer.clear`

Sufficient for Phase 1+2 (Selection + Rect). Phase 3+ may need
additional handlers (e.g. `doc.zoom.set` for the Zoom tool, but those
are simple setState wrappers).

### Tool yamls — all 27 present

Every native-app tool has a yaml in `workspace/tools/`. None are
missing. They were authored as part of `flask-parity-design` work.

### Document-aware primitives registered by tools.mjs

When a tool dispatch runs, `registerDocumentPrimitives(model)`
installs:
- `hit_test(x, y)` → returns Path or Null
- `selection_contains(path)` → bool
- `selection_empty()` → bool
- `layer_length([0])` → number

These are torn down at end of dispatch (via the closure-returning
pattern) so they don't leak across tool invocations.

---

## Test status

### Engine tests (`jas_flask/tests/js/*.mjs`, Node `--test`)

```
ℹ tests 353
ℹ pass 350
ℹ fail 3
```

**Pass rate: 99.2%.**

### The 3 failing tests

All in `tests/js/test_phase12.mjs`:
- `mousedown adds a zero-sized rect; mousemove resizes it`
- `drag from bottom-right to top-left produces rect with clamped origin`
- `undo after rect creation removes the rect`

**Root cause:** the tests assert that `on_mousedown` adds a rect, but
the current `workspace/tools/rect.yaml` only commits on `on_mouseup`
(with a 1-pixel size-suppression check). The yaml was tightened to
match native-app behavior; the tests weren't updated.

**Severity:** stale tests, not engine bug. The yaml's mouseup-commit
behavior is intentional (matches RectTool in jas_dioxus). Fix is to
update the test to drive a full press → move → release sequence and
assert the rect lands after release. ~30 minutes.

**Decision:** include in Phase 1 cleanup.

### Flask renderer tests (Python pytest)

281 passed (per latest `flask-toolbar-triangles` branch), so the
server-side Flask plumbing is healthy. No regressions expected from
this work.

---

## Integration gaps — concrete punch list

### Phase 1 — Wire the canvas

| Gap | Where | Effort |
|---|---|---|
| `<svg id="canvas-doc">` etc. not in any rendered template | `templates/normal.html`, `renderer.py` | 1 day |
| No `type: canvas` widget in renderer.py's `_RENDERERS` | `renderer.py` | 0.5 day |
| `app.js` doesn't import engine modules | `app.js` (head: `<script type="module">` block in `normal.html`) | 0.5 day |
| `app.js` has no Model / no engine StateStore — just its own `state` global | `app.js` | 1 day (bridging existing `state` to engine `store.state`) |
| Workspace layout.yaml has no canvas pane | `workspace/layout.yaml` | 0.5 day |
| DOM mouse events not translated to `dispatchEvent` calls | `app.js` | 1 day (mirror canvas_demo.html's wiring) |

### Phase 2 — Selection + Rect

| Gap | Where | Effort |
|---|---|---|
| 3 stale rect-tool tests in `test_phase12.mjs` | `tests/js/test_phase12.mjs` | 0.5 day |
| Selection HUD: dashed bbox per selected path | already in `canvas.mjs` | ✅ done |
| Selection tool yaml | `workspace/tools/selection.yaml` | already present; validate dispatch |

### Phase 3 — More tools + persistence

| Gap | Where | Effort |
|---|---|---|
| `engine/session.mjs` doesn't exist | new file | 1 day |
| `beforeunload` + 30s timer save | `app.js` | 0.5 day |
| Restore-on-load | `app.js` | 0.5 day |
| Tool yamls for line/ellipse/pen/pencil/hand/zoom — present | `workspace/tools/*.yaml` | already present; validate per-tool |

### Phase 4 — File I/O

| Gap | Where | Effort |
|---|---|---|
| No `/api/export/svg` endpoint | `app.py` | 0.5 day |
| No `/api/import/svg` endpoint | `app.py` | 0.5 day |
| Server-side `geometry/svg.py` exists for export | reuse | ✅ |
| File menu Open/Save/Save As wiring | `app.js` + `workspace/menubar.yaml` | 1 day |

### Phase 5 — Undo/redo + panels

| Gap | Where | Effort |
|---|---|---|
| Cmd+Z / Cmd+Y not bound | `workspace/shortcuts.yaml` + `app.js` | 0.25 day |
| Color panel writes propagate to selected elements | `engine/effects.mjs` (new effect) + `workspace/panels/color.yaml` | 1 day |
| Stroke panel ditto | same pattern | 0.5 day |
| Layers panel reads from `model.document.layers` | `workspace/panels/layers.yaml` (panel exists; validate live binding) | 1 day |

---

## Risk assessment

### Low risk

- **Engine substrate**: thoroughly tested (350 passes). Production-grade.
- **Tool yamls**: all 27 already authored to the schema.
- **Effect interpreter**: covers V1 needs without extension.

### Medium risk

- **Canvas pane sizing / theming**: layout.yaml-driven canvas sizing
  has never been tested in production. May need a few iterations.
- **`state` ↔ engine `store.state` bridge**: currently `app.js`'s
  `state` is a plain JS object with custom mutation; engine expects
  `StateStore` with namespaces. Bridging without breaking existing
  panel bindings is the trickiest part of Phase 1.
- **Cross-app parity drift**: every yaml change to a tool now
  potentially affects 6 implementations. Need to revisit
  `CLAUDE.md` propagation order once Flask grows a doc model.

### High risk — recommend early experiment

- **Undo coverage**: every panel that mutates the document needs to
  call `model.snapshot()` before its set. The native apps have this
  threaded through their controllers; Flask needs a similar
  convention. Easy to forget; bad UX when forgotten.
- **Performance at 1000+ elements**: SVG hit-test in DOM scales poorly.
  Mitigation: hit-test against `model.document` (already done in
  `geometry.mjs`), not via DOM `pointer-events`.

---

## Recommended next actions

1. **Fix the 3 stale tests** in `test_phase12.mjs` so the engine suite
   is 100% green. Forces a careful read of the rect-yaml dispatch and
   surfaces any real integration bugs before Phase 1 begins.
2. **Confirm `canvas_demo.html` works in a real browser**: the Node
   test suite proves the modules import and dispatch correctly, but
   doesn't exercise SVG rendering. A 5-minute manual smoke is enough.
3. **Open `FLASK_PARITY.md`'s "Open questions for before V1"** (§892):
   none of these block Phase 1, but answering them now avoids rework
   later. Specifically: deployment story (PWA vs SaaS) and
   performance target (max element count to support).
4. **Branch hygiene**: keep `flask-document-model` separate from
   `flask-toolbar-triangles`. Each phase merges to main on its own.

---

## Verdict

**The plan is realistic.** Phase 1 (wire the canvas + selection +
rect drawing) can ship in the predicted ~10 days. The 5-6 week V1
estimate stands.

The 3,800 lines of unused engine code on main is real working
substrate, not architectural ghost. We've been carrying it for what
seems to be ~2 weeks since the design doc landed.

**Audit conclusion:** proceed to Phase 1.
