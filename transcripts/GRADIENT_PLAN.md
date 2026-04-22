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

**Pending (follow-up wiring):**

- Bind individual panel-control events to call `apply`:
  - Type buttons commit → `gradient.type`.
  - Angle / aspect / method / dither commit → corresponding fields.
  - Stroke sub-mode buttons commit.
  - Gradient slider stop / midpoint edits commit (panel.stops list
    binding to store keys).
  - Stop opacity / location combos commit → selected stop's fields.
  - Tile click → copy gradient value onto active attribute.
- Hook fill/stroke widget Color button to call `demote`.
- `ADD_TO_SWATCHES_BUTTON` → append to Document Library with
  auto-name.
- `TRASH_BUTTON` → delete selected stop (min-2 floor).
- Panel menu actions: Reverse, Distribute Stops, Reset Midpoints.
- `EYEDROPPER_BUTTON` → color pick into selected stop.
- Double-click stop → opens `workspace/dialogs/color_picker.yaml`
  seeded with the stop's color.

The foundation pass leaves stops as panel-local working state with
no store binding. The follow-up adds explicit
`panel.stops <-> store.gradient_stops` synchronisation.

**Apps:** 4 native + `jas_flask`.

**Deliverable:** every control commits correctly; fill-type
transitions work both directions; menu actions produce the expected
`stops[]` transformations.

### Phase 6 — Linear gradient rendering (classic, within-element)

First visual rendering phase. SVG `<linearGradient>` is natively
supported in every backend.

**Scope**

- Emit `<linearGradient>` in `<defs>` with synthesized ids on export.
- Compute `x1` / `y1` / `x2` / `y2` from `angle` and `aspect_ratio`.
- `<stop>` children per gradient stops.
- Midpoints ≠ 50%: synthesize intermediate stops per §SVG attribute
  mapping.
- Canvas renders the gradient via native SVG / equivalent backend
  paint.

**Apps:** 4 native.

**Deliverable:** panel edits show up live on the canvas for linear
gradients; SVG export produces valid standard-compliant output.

### Phase 7 — Radial gradient rendering (classic)

**Scope**

- `<radialGradient>` emit with `cx` / `cy` / `r`.
- `gradientTransform` for `angle` (rotation) and `aspect_ratio ≠ 100%`
  (elliptical).
- Same stop and midpoint handling as Phase 6.

**Apps:** 4 native.

**Deliverable:** radial gradients render on all four native apps,
including elliptical and rotated variants.

### Phase 8 — Stroke gradient (within-stroke sub-mode)

**Scope**

- `state.fill_on_top == stroke` → panel edits the stroke gradient.
- SVG emit: `stroke="url(#gN)"` — native for `within_stroke`.
- Stroke sub-mode row enablement per §Enablement.

**Apps:** 4 native.

**Deliverable:** a stroke with a gradient renders correctly in all
four apps.

### Phase 9 — Library management

**Scope**

- **Open Gradient Library** submenu — dynamic listing of
  `workspace/gradients/*.json` files. Selecting switches the active
  library.
- **Save Gradient Library** dialog — prompts for name; writes the
  document's gradient library to `workspace/gradients/<name>.json`.
- Document Library persists with document save / load.
- Tile thumbnail sizes (small/medium/large) render at correct sizes.

**Apps:** 4 native + `jas_flask` (flask has file I/O for yaml; JSON
loading is analogous).

**Deliverable:** new libraries can be saved and re-opened; Document
Library survives document reload; thumbnail sizes work.

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
