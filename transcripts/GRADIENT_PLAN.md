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

### Phase 1 — Document model

Extend `element.fill` / `element.stroke` to a discriminated union.

**Scope**

- Add the gradient-object shape (`type`, `angle`, `aspect_ratio`,
  `method`, `dither`, `stroke_sub_mode`, `stops[]`, `nodes[]`) per
  `GRADIENT.md` §Document model.
- Parsers accept either a color string or a gradient object in
  `fill` / `stroke` slots.
- Serializers emit the correct form per the identity-value rule from
  §SVG attribute mapping. `jas:*` extension attributes emitted for
  midpoint / method / dither when non-default.
- Round-trip test per app: every gradient field survives save → load
  unchanged.

**Apps:** 4 native (Rust, Swift, OCaml, Python). `jas_flask` gets
state-shape support only — it has no SVG serializer.

**Deliverable:** SVGs with gradients round-trip across all four
native apps; `jas:*` custom attributes preserve midpoints and other
non-SVG-native fields.

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

**Scope**

- Populate panel control values from the selection's gradient on the
  active attribute (per `state.fill_on_top`).
- Mixed-state rendering per §Multi-selection:
  - Type buttons: none checked when mixed.
  - Angle / aspect / method / opacity / location: blank `—`.
  - Dither: tri-state.
  - Gradient slider: first element's stops shown.
- Disabled-when evaluation per §Enablement.
- Fill-type coupling preview state — when active attribute is
  solid/none, show the seed gradient in the slider with the "not
  applied" indicator.

**Apps:** 4 native + `jas_flask` (flask reads panel selection state
through the existing `state.*` surface).

**Deliverable:** selecting elements with various gradients /
solids / nones / mixed populates the panel correctly.

### Phase 5 — Panel → selection writes (no new rendering)

**Scope**

- Type buttons commit → `gradient.type`.
- Angle / aspect / method / dither commit → corresponding fields.
- Stroke sub-mode buttons commit → `gradient.stroke_sub_mode`.
- Gradient slider operations commit → `gradient.stops[]` changes.
- Stop opacity / location combos commit → selected stop's fields.
- Tile click → copy gradient value onto active attribute.
- Fill-type promotion on first edit — per §Fill-type coupling.
- Fill-type demotion via the fill/stroke widget's Color button uses
  `gradient.stops[0].color`.
- `ADD_TO_SWATCHES_BUTTON` → append to Document Library with
  auto-name.
- `TRASH_BUTTON` → delete selected stop (min-2 floor).
- Panel menu actions: Reverse, Distribute Stops, Reset Midpoints.
- `EYEDROPPER_BUTTON` → color pick into selected stop.
- Double-click stop → opens `workspace/dialogs/color_picker.yaml`
  seeded with the stop's color.

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
