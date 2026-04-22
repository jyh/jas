# Gradient Panel — Implementation Plan

Scope: implement the Gradient panel specified in `GRADIENT.md` across
all five apps (`jas_flask`, `jas_dioxus`, `JasSwift`, `jas_ocaml`,
`jas`), on branch `gradient-panel`.

The on-canvas Gradient tool (`GRADIENT_TOOL.md`) is an independent
follow-up track — not blocking on this plan. Linear and radial are
in-scope; freeform, smooth method, dither, and along/across stroke
sub-modes are flagged `pending_renderer` in the spec and are
out-of-scope for v1.

The phases below each produce something observable so progress is
reviewable and regressions surface early.

## Phases

### Phase 0 — YAML interpreter primitives

Two new widget primitives are required before the panel YAML can be
rendered. Self-contained within the interpreter; no selection or
rendering work.

**Scope**

- `gradient_tile` widget — renders a small gradient preview from a
  gradient value, sized per `DOCUMENT_LIBRARY_SIZE_DROPDOWN`.
  Single-click event.
- `gradient_slider` widget — 1-D stops editor per `GRADIENT.md`
  §Color stops. Renders the bar, stop markers, midpoint markers,
  selected-state accent. Gestures: click-to-select, click-to-add,
  drag stop, drag midpoint, drag-off-bar delete, double-click.
  Keyboard: Left/Right, Shift+Left/Right, Home/End, Delete.
- Disclosure / popover primitives — if required for any inline
  control (verify during YAML drafting; add only if missing).

**Apps:** all 5 (`jas_flask` first, then Rust, Swift, OCaml, Python).

**Deliverable:** a minimal `test-gradient-primitives.yaml` exercises
both widgets with dummy data; all gestures and keyboard actions fire
the right events.

### Phase 1 — Document model: types only

Define the gradient data types as standalone, JSON-roundtrippable
structs. **Integration with `Fill` / `Stroke` is deferred** to a
later phase (1b) when there is a real consumer (Phase 5 panel
writes), because adding a `gradient: Option<Gradient>` field to Fill
requires removing `Copy` and rippling clones through ~50 callsites
per app — a refactor that is unjustified until the panel needs it.

**Scope**

- Add the gradient-object shape (`type`, `angle`, `aspect_ratio`,
  `method`, `dither`, `stroke_sub_mode`, `stops[]`, `nodes[]`) per
  `GRADIENT.md` §Document model. New types: `Gradient`,
  `GradientStop`, `GradientNode`, `GradientType`, `GradientMethod`,
  `StrokeSubMode`.
- Per-app JSON round-trip tests: every variant of every field
  survives serialise → deserialise unchanged.
- Wire-format conformance: `type` / `method` / `stroke_sub_mode`
  serialise as the lowercase strings GRADIENT.md uses.
- `midpoint_to_next` defaults to 50 when absent on parse.

**Apps:** 4 native (Rust, Swift, OCaml, Python). `jas_flask` is not
applicable here — it has no document-model layer of its own; the
gradient values flow through state as JSON dicts.

**Deliverable:** the gradient data types exist in each app and pass
JSON round-trip tests; nothing else changes.

### Phase 1b — Per-element gradient fields

Adds `fill_gradient` and `stroke_gradient` directly to each Element
variant rather than nesting inside Fill/Stroke. Approach (c) from
the architectural fork: keeps Fill/Stroke `Copy`, avoids the
~50-site cascade of approach (a), and avoids the new gradient-ID
identity concept of approach (b).

**Status:** Done across all four native apps.

- **Rust** (`jas_dioxus`): `Option<Box<Gradient>>` on each variant
  struct; `serde(default, skip_serializing_if = is_none)` so JSON
  fixtures continue to parse without the new fields.
- **Swift** (`JasSwift`): `Gradient?` on each variant struct with
  defaulted-init params, so existing call sites continue to work
  unchanged.
- **OCaml** (`jas_ocaml`): `gradient option` on each inline-record
  variant in both element.ml and element.mli; construction sites
  patched via a Python walker that distinguishes constructors from
  patterns by inspecting whether the body ends with a wildcard.
- **Python** (`jas`): `Gradient | None = None` on each Element
  dataclass.

SVG-level integration (parsing `url(#id)` references and emitting
`<defs>` blocks) is Phase 6/7 work; Phase 1b lands the storage
shape so Phase 4 reads + Phase 5 writes can target real fields.

### Phase 2 — Static panel UI

**Scope**

- Generate `workspace/panels/gradient.yaml` from `GRADIENT.md`.
- All controls render at the positions specified in §Layout.
- Panel menu (`PANEL_MENU`) renders with items in the right groups;
  handlers unwired.
- No selection wiring yet.

**Apps:** all 5.

**Deliverable:** Gradient tab shows up; all controls visible; menu
opens with correct structure.

### Phase 3 — Seed libraries + loader

**Scope**

- Author 2–3 seed library JSON files in `workspace/gradients/`
  (`neutrals.json`, `spectrums.json`, `simple_radial.json`).
- Library loader reads all `workspace/gradients/*.json` at startup
  into shared state (analogous to the existing swatches loader).
- `DOCUMENT_LIBRARY_DROPDOWN` populates from the loaded set.
- Tile strip renders `GRADIENT_TILE` per gradient in the active
  library.
- Document Library (per-document) initialised empty.

**Apps:** all 5.

**Deliverable:** changing the library dropdown updates the tile
strip; all three seed libraries render correctly.

### Phase 4 — Selection → panel reads

**Status:** Done across all four native apps.

- **Rust:** `AppState::sync_gradient_panel_from_selection` +
  `GradientPanelState` struct + `Element::fill_gradient()` /
  `stroke_gradient()` accessors.
- **Swift:** `syncGradientPanelFromSelection` in Effects.swift +
  `Element.fillGradient` / `strokeGradient` computed properties.
- **OCaml:** `Effects.sync_gradient_panel_from_selection` +
  `fill_gradient_opt` / `stroke_gradient_opt` pattern accessors,
  exposed via effects.mli.
- **Python:** `panels/gradient_panel_state.py` module.

Each implementation handles four branches per GRADIENT.md
§Multi-selection and §Fill-type coupling: empty selection (no-op),
uniform with gradient (populate panel), mixed (clear preview only),
uniform without gradient (seed preview from current solid color).

The actual sync invocation sites (after selection-changing actions)
are not yet wired — that follows in Phase 5 alongside the writeback
pipeline. Phase 4 lands the read function and 14 unit tests across
the four apps verifying the populated branches.

`jas_flask` does not need this phase — panel state binds directly to
`state.*` keys via the shared yaml interpreter and reads happen
through expression evaluation.

### Phase 5 — Panel → selection writes (no new rendering)

**Status:** Foundation done across all four native apps; UI-event
wiring still pending.

**Foundation (done):** apply / demote primitives that the UI events
will call.

- **Element layer** (`with_fill_gradient`, `with_stroke_gradient`)
  — pure helpers that return a copy of the element with the
  gradient field replaced.
- **Controller layer**
  (`set_selection_fill_gradient`, `set_selection_stroke_gradient`) —
  iterate the selection and write each element's gradient field.
- **AppState/Effects layer**
  (`apply_gradient_panel_to_selection`, `demote_gradient_panel_selection`) —
  build a Gradient from the panel state, write via the controller,
  clear `gradient_preview_state`. Demote clears the gradient and
  leaves the underlying solid Fill / Stroke as the demote-target
  color (per GRADIENT.md §Fill-type coupling).

8 new tests across the four apps verify the apply and demote paths.

**Phase 5 follow-up (wired):** yaml controls + subscription across
all 4 native apps for the basic parameter panel:

- `workspace/panels/gradient.yaml` fires `set: {gradient_X: ...}`
  effects on click / change for LINEAR_BUTTON, RADIAL_BUTTON,
  ANGLE_COMBO, ASPECT_RATIO_COMBO, METHOD_DROPDOWN, DITHER_CHECKBOX.
- Subscription wiring that listens to `gradient_*` state writes
  and calls `apply_gradient_panel_to_selection`:
  - **OCaml:** `Effects.subscribe_gradient_panel` uses
    `State_store.subscribe_global`.
  - **Rust:** `apply_set_effects` in `interpreter/renderer.rs`
    tracks whether any `gradient_*` key was in the set batch and
    calls `apply_gradient_panel_to_selection` after. Schema
    entries added for all six keys.
  - **Swift:** `runOne` set handler fires the
    `apply_gradient_panel` platform hook when any render key appears
    in the batch. Host registers the hook pointing at
    `applyGradientPanelToSelection`.
  - **Python:** `subscribe_gradient_panel` uses
    `StateStore.subscribe`.

**Still pending (the non-trivial remainder):**

- Gradient slider stop / midpoint edits commit: requires
  `panel.stops <-> store.gradient_stops` synchronisation (the list
  of stops is not yet a set of store keys).
- Stop opacity / location combos commit.
- Tile click → copy gradient value onto active attribute.
- Hook fill/stroke widget Color button to call `demote`.
- `ADD_TO_SWATCHES_BUTTON` → append to Document Library.
- `TRASH_BUTTON` → delete selected stop (min-2 floor).
- Panel menu actions: Reverse, Distribute Stops, Reset Midpoints.
- `EYEDROPPER_BUTTON` → color pick into selected stop.
- Double-click stop → opens `workspace/dialogs/color_picker.yaml`.
- Stroke sub-mode buttons commit (for stroke_gradient, which
  depends on Phase 8 stroke rendering).

**Apps:** 4 native + `jas_flask`.

**Deliverable:** every control commits correctly; fill-type
transitions work both directions; menu actions produce the expected
`stops[]` transformations.

### Phases 6 + 7 — Linear and radial gradient rendering

**Status:** Done across all four native apps. Phase 6 and Phase 7
landed together since each backend's gradient API naturally
supports both linear and radial via the same pattern.

- **Rust** (`jas_dioxus`): `apply_fill` in `src/canvas/render.rs`
  takes `Option<&Gradient>` + bbox; `make_canvas_gradient` builds
  a `web_sys::CanvasGradient` (linear or radial). Required enabling
  the `CanvasGradient` web-sys feature.
- **Swift** (`JasSwift`): `fillStrokeOrOutline` overload takes
  `fillGradient` + bbox; `fillCurrentPathWithGradient` saves state,
  clips to the current path, then `drawLinearGradient` /
  `drawRadialGradient`, restores. Re-adds path for stroke.
- **OCaml** (`jas_ocaml`): `fill_and_stroke_with_gradient` builds a
  `Cairo.Pattern.create_linear` / `_radial`, applies stops via
  `add_color_stop_rgba`, then `Cairo.fill_preserve` so the path
  stays for stroking.
- **Python** (`jas`): `_apply_fill` takes `fill_gradient` + bbox;
  `_make_qgradient` builds a `QLinearGradient` or `QRadialGradient`.

Shape variants covered per app: Rect, Circle, Ellipse, Polyline,
Polygon, Path (Path through `elem.bounds`). Text / TextPath /
CompoundShape and variable-width Path stroke still use solid-only
paths.

**Deferred Phase 6/7 details:**
- Midpoint synthesis (GRADIENT.md §SVG mapping) — currently stops
  render at their raw locations; non-50% midpoints become plain
  stops at the midpoint position. Proper midpoint-to-stop
  synthesis is a follow-up.
- SVG export / import round-trip — the renderer produces gradients
  on screen, but the save-to-SVG / load-from-SVG round-trip with
  `<defs>` + `url(#gN)` remains Phase 9 territory.

### Phase 8 — Stroke gradient (within-stroke sub-mode)

**Status:** Done across all four native apps.

- **Rust:** `apply_stroke_with_gradient` uses
  `set_stroke_style_canvas_gradient`.
- **OCaml:** `fill_stroke_gradient_full` sets the gradient as Cairo
  source after `apply_stroke` (Cairo's unified source semantics).
- **Python:** `_apply_stroke` builds `QPen(QBrush(QGradient))` —
  Qt supports a gradient brush on the pen natively.
- **Swift:** `fillStrokedPathWithGradient` uses
  `replacePathWithStrokedPath` to convert the stroked outline into
  a fillable path, then fills it with the gradient (CGContext
  gradient APIs are fill-oriented).

All four handle the four paint combinations: fill-gradient + stroke-
gradient, fill-gradient + solid-stroke, solid-fill + stroke-gradient,
solid + solid. `state.fill_on_top` flips which attribute the panel
edits; the renderer reads both fields regardless.

Along-stroke / across-stroke sub-modes remain `pending_renderer`
per GRADIENT.md §Stroke sub-modes — they require path-arc-length /
perpendicular-distance parameterization that isn't natively
supported by Canvas2D / CGContext / Cairo / QPainter gradient APIs.

### Phase 9 — Library management

**Status:** Foundation partially landed.

- **Open Gradient Library** submenu — declared as `dynamic: true`
  in `gradient.yaml`, matching the Swatches panel convention. Menu
  renderer walks `data.gradient_libraries` (populated by the loader
  from Phase 3) and emits submenu entries per discovered library.
  Selecting one switches `panel.active_library_id`.
- **Tile click applies** — each `GRADIENT_TILE` in the strip fires
  six `set` effects on click, threading the tile's gradient value
  through the subscription chain to the selected elements'
  `fill_gradient` field.
- Thumbnail sizes (small/medium/large): working.
- List views (small list / large list): declared in the size
  dropdown, `status: pending_renderer` until the row-render path
  lands.

**Pending for Phase 9 completion:**

- **Save Gradient Library** dialog — prompts for name and writes
  the Document Library to `workspace/gradients/<name>.json`.
  Requires a save-dialog primitive and per-app file-writing
  pipeline.
- **Document Library persistence** — per-document, travels with
  document save / load. Document Library state is currently
  panel-local; a serialisation round-trip is needed.

### Phase 10 — Cross-app parity + manual tests

**Status:** Manual test suite drafted; parity sweep pending.

- **`transcripts/GRADIENT_TESTS.md`** — 17 manual test cases
  covering panel rendering, tile click, type / angle / aspect /
  method / dither controls, stroke gradient, multi-selection,
  library browsing, and cross-app parity. 16 known-broken items
  track the remaining gaps. Covers automation across flask
  (18 tests), Rust (12), Swift (10), OCaml (10), Python (17),
  workspace_interpreter (1).

**Pending:** actual cross-app parity run — build the document in
each of the four native apps, confirm identical output, fix any
divergences.

### Phase 10 — Cross-app parity + polish + manual tests

**Scope**

- Author `transcripts/GRADIENT_TESTS.md` per
  `MANUAL_TESTING.md` convention (linear/radial/stroke /
  multi-selection / fill-type coupling / keyboard / library
  management).
- Test corpus: representative gradients covering every in-scope
  field, exported from one app and re-imported in every other.
- Parity assertions: the four native apps produce pixel-identical
  renders for the corpus (within tolerance).
- Fix any divergences surfaced.
- Remove the seed-library placeholder and confirm the full content
  catalog (Foliage, Skintones, …) is scheduled as a separate track.

**Apps:** all 5.

**Deliverable:** Gradient panel feature-complete and consistent
across apps for v1 scope.

## Out of scope (deferred)

Tracked in `GRADIENT.md` §Deferred additions. Each gets its own plan
when scheduled:

- Freeform gradient (type + rendering + canvas node editing).
- `method = smooth` with perceptual (OKLab) interpolation.
- `dither` renderer pass in all four apps.
- Stroke along / across rendering.
- On-canvas Gradient tool (per `GRADIENT_TOOL.md`).
- List-view tile rendering.
- Full bundled library catalog (~20 libraries, content authoring).
- Unified gradient + color libraries.

## Conventions

**Commits:** one per phase. The spec rewrite (`GRADIENT.md`) and the
tool stub (`GRADIENT_TOOL.md`) already landed on this branch.

**Per-app sequencing within each phase:** flask → Rust → Swift →
OCaml → Python (`CLAUDE.md`). Phases that skip flask skip it
entirely.

**Testing:** write tests before code (`CLAUDE.md`). Unit / integration
tests per phase; manual-testing pass in Phase 10 via
`transcripts/GRADIENT_TESTS.md`. Serialization round-trip assertions
in Phase 1; SVG-validity assertions in Phases 6–8; parity assertions
in Phase 10.

**Branch:** `gradient-panel`. Do not merge to `main` until Phase 10
passes across all apps.

## Spec amendments expected during implementation

`GRADIENT.md` may need tightening as the work surfaces gaps.
Anticipated amendments:

- Exact widget-schema YAML for `gradient_tile` and `gradient_slider`
  once chosen in Phase 0.
- Disclosure / popover primitive details if any are added in Phase 0.
- Visual indicator for "not applied" preview state — the spec calls
  for "e.g. a dimmed border or a 'Not applied' subtitle" but does
  not fix the design; Phase 4 picks one.
- Tile-size pixel dimensions for the three thumbnail views — spec
  references the size menu but does not fix the pixel sizes.
- Any unexpected gaps surfaced while generating the panel YAML in
  Phase 2.

Amendments happen on this branch and ride in with the phase that
surfaces them.

## Spec → YAML translation conventions

`GRADIENT.md` uses the compact bootstrap-style layout notation. The
flask YAML interpreter does not understand this notation directly;
`workspace/panels/gradient.yaml` generated in Phase 2 uses the verbose
`type:` form. Translations follow the existing table in
`PARAGRAPH_PLAN.md` §Spec → YAML translation conventions (row / col /
hr / enabled-when). No new translations are expected for this panel.
