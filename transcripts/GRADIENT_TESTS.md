# Gradient Panel — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/panels/gradient.yaml`, plus `workspace/gradients/*.json`
(seed libraries). Design doc: `transcripts/GRADIENT.md`. Plan:
`transcripts/GRADIENT_PLAN.md`. On-canvas tool design (deferred):
`transcripts/GRADIENT_TOOL.md`.

Primary platform for manual runs: **Flask (jas_flask)** — yaml
interpretation landed first, native apps mirror. Phase 6–8
rendering verified via hand-constructed gradients in
`fill_gradient` / `stroke_gradient` fields because the panel UI
wiring for slider stops is still pending.

---

## Known broken / pending

_Last reviewed: 2026-04-22_

- GRD-101 — Gradient slider stop drag, drag-off-to-delete,
  click-to-add are not wired to the action pipeline. JS gestures
  in flask dispatch custom events (Phase 0b); store-binding for
  `panel.stops` is not yet done. Since 2026-04-22.
  GRADIENT_PLAN.md §Phase 5 follow-up.
- GRD-102 — Stop opacity / location combos are not wired; bind
  expressions `panel.stops[panel.selected_stop_index].opacity`
  have no set-effect route back. Same deferral as GRD-101.
- GRD-103 — ADD_TO_SWATCHES_BUTTON, TRASH_BUTTON, EYEDROPPER_BUTTON
  have no click handlers. `status: pending` in all four apps.
- GRD-104 — Panel-menu actions Reverse Gradient, Distribute Stops
  Evenly, Reset Midpoints are registered but `enabled_when: false`
  — no handler lands the transformation on `panel.stops` yet.
- GRD-105 — Save Gradient Library menu item is `enabled_when:
  false`. Needs a Save dialog and file-writing pipeline per app.
- GRD-106 — Fill / stroke widget Color button does not demote a
  selected gradient back to solid. `demote_gradient_panel_selection`
  exists but nothing calls it.
- GRD-107 — Double-click on a stop marker should open
  `workspace/dialogs/color_picker.yaml`. Dispatch fires the
  `gradient-slider-stop-dblclick` custom event in flask but no
  handler is registered.
- GRD-108 — Freeform gradient type is `status: pending_renderer`
  across all apps. Button is disabled.
- GRD-109 — Smooth interpolation method is `status: pending_renderer`
  — renders as classic in every app. GRADIENT.md §Method.
- GRD-110 — Dither checkbox is `status: pending_renderer` in all
  four apps.
- GRD-111 — Stroke sub-modes along_stroke / across_stroke are
  `status: pending_renderer`. within_stroke works.
- GRD-112 — Midpoint positions ≠ 50 % are not yet interpolated as
  an extra intermediate stop. Non-50 midpoints currently render
  as if the midpoint is at 50 % (GRADIENT.md §SVG attribute
  mapping round-trip loss).
- GRD-113 — Gradient SVG export (`<defs>` + `url(#gN)`) is not
  wired. Saving a document with a gradient produces SVG that
  omits the gradient. Import likewise ignores `url(#)` refs.
- GRD-114 — Text / TextPath / CompoundShape elements do not carry
  `fill_gradient` / `stroke_gradient` fields. Gradient fills on
  text and compound shapes are not supported.
- GRD-115 — Variable-width Path stroke retains the pre-Phase-8
  solid-only path; gradient strokes on paths with
  `width_points` set are not routed through the stroked-outline
  gradient technique.
- GRD-116 — List-view items in DOCUMENT_LIBRARY_SIZE_DROPDOWN
  (Small List View, Large List View) are declared but the
  row-render path is not implemented. Thumbnail views work.

---

## Automation coverage

_Last synced: 2026-04-22_

**Flask — `jas_flask/tests/test_renderer.py`** (18 tests in
`TestRenderGradientTile`, `TestRenderGradientSlider`,
`TestGradientPrimitivesFixture`)
- gradient_tile HTML emission at all three thumbnail sizes, with
  linear + radial backgrounds.
- gradient_slider bar + stop markers + midpoint markers,
  selection accent classes, data-bind attribute round-trip,
  tabindex, empty-stops fallback.
- Phase 0 fixture `workspace/tests/gradient_primitives.yaml` loads
  and renders 9 tiles (3 sizes × 3 gradients) + 1 slider.

**Rust — `jas_dioxus/src/geometry/element.rs`** (7 tests)
- Gradient / GradientStop / GradientNode JSON round-trip for
  linear, radial-with-midpoints-method-dither, freeform, wire
  format strings, stop-default-midpoint, RectElem with fill
  gradient serde round-trip, RectElem without gradient omits
  fields.

**Rust — `jas_dioxus/src/interpreter/renderer.rs`** (5 tests)
- sync_gradient_panel_from_selection: uniform gradient populates
  panel, solid fill seeds preview, no selection keeps defaults.
- apply_gradient_panel_to_selection writes fill_gradient to the
  element and clears preview_state.
- demote_gradient_panel_selection clears fill_gradient while
  preserving the solid Fill.

**Swift — `JasSwift/Tests/Geometry/ElementTests.swift`** (5 tests)
- Gradient JSON round-trip linear / radial / freeform, wire
  format strings, stop default midpoint.
- Rect fillGradient and Circle strokeGradient field round-trip.

**Swift — `JasSwift/Tests/Interpreter/GradientPanelSyncTests.swift`**
(5 tests)
- Uniform with gradient, solid seeds preview, empty selection
  leaves store alone, apply writes fillGradient, demote clears it.

**OCaml — `jas_ocaml/test/geometry/element_test.ml`** (5 tests)
- Gradient round-trip linear / radial / freeform, wire format
  strings, stop default midpoint.

**OCaml — `jas_ocaml/test/interpreter/effects_test.ml`** (5 tests)
in `Gradient Phase 4` section
- Uniform with gradient, solid seeds preview, empty selection
  leaves store alone, apply writes fill_gradient, demote clears it.

**Python — `jas/geometry/element_test.py`** (8 tests)
- Gradient JSON round-trip linear / radial-with-midpoints-method-
  dither / freeform, wire format, stop default midpoint.
- Rect fill_gradient, Circle stroke_gradient field round-trip,
  Line has only stroke_gradient (no fill_gradient) verified via
  dataclass fields introspection.

**Python — `jas/panels/gradient_panel_state_test.py`** (9 tests)
- sync (no-op, empty, uniform with gradient, solid seeds preview,
  mixed clears preview only).
- apply / demote round-trip.
- is_gradient_render_key predicate, subscribe triggers apply on
  gradient_* write.

**workspace_interpreter — `tests/test_loader.py`** (1 test)
- Three seed libraries (neutrals, spectrums, simple_radial) load
  with the expected fields (name, description, gradients array,
  and each gradient carries name / type / stops with
  color / opacity / location).

The manual suite below covers what auto-tests don't: actual widget
rendering on canvas, gradient fill / stroke visual correctness,
library tile click applying a preset, multi-selection blank states,
and the fill-type coupling preview indicator.

---

## Setup

1. Launch the app and open a new document.
2. Add a rectangle (approximately 200 × 150 pt) near the canvas
   center. The remaining tests assume at least one rectangle is
   selectable.
3. Activate the Gradient tab in the panel group that contains
   Stroke / Properties.

---

## Basic panel rendering

### GRD-M01: Gradient tab shows up

**Steps:**
1. Click the Gradient tab in the panel group.

**Expected:** Panel body renders with Presets row, tile strip,
horizontal rule, fill/stroke widget, Type / Stroke / ∠ / ↕ /
Method / Dither rows, gradient slider row, and selected-stop
properties row. All controls visible.

**Auto-covered:** Flask yaml-rendering tests; native rendering
not yet in an automated harness.

### GRD-M02: Default panel state

**Steps:**
1. Open a fresh document with no selection.

**Expected:** Type shows Linear checked; Stroke sub-mode shows
Within checked; Angle ≈ 0°; Aspect ratio ≈ 100 %; Method Classic;
Dither unchecked. Tile strip shows gradients from the Neutrals
library (active_library_id default).

---

## Tile click applies gradient

### GRD-M03: Preset tile applies to selected rectangle

**Steps:**
1. Select the rectangle.
2. Click the first tile in the Spectrums library ("Rainbow").

**Expected:** The rectangle's fill now renders as a horizontal
rainbow gradient. The panel's Type, Angle, Method etc. reflect
the Rainbow gradient's fields (linear, 0°, classic).

**Tests:** LINEAR tile → linear gradient renders. RADIAL tile
→ radial gradient renders.

### GRD-M04: Tile click when no selection

**Steps:**
1. Click on empty canvas to clear selection.
2. Click any library tile.

**Expected:** No visual change (nothing is selected). Panel state
updates to reflect the tile's gradient (defaults mode).

---

## Type / angle / aspect / method / dither

### GRD-M05: Type radio group

**Steps:**
1. Select a rectangle with a fill gradient applied.
2. Click RADIAL_BUTTON.

**Expected:** Rectangle renders with radial gradient. LINEAR and
FREEFORM show unchecked. FREEFORM button is disabled
(pending_renderer).

### GRD-M06: Angle combo

**Steps:**
1. With a rectangle and linear gradient selected.
2. Enter 90 in ANGLE_COMBO or pick it from the preset list.

**Expected:** Linear gradient rotates to vertical. Visual change
on canvas.

### GRD-M07: Aspect ratio combo (radial)

**Steps:**
1. Apply a radial gradient to a rectangle.
2. Set ASPECT_RATIO_COMBO to 50 %.

**Expected:** Radial gradient shrinks to half its previous radius.

### GRD-M08: Method dropdown

**Steps:**
1. Pick Smooth from METHOD_DROPDOWN.

**Expected:** Renders as classic (GRD-109 — smooth is
pending_renderer). State key updates.

### GRD-M09: Dither checkbox

**Steps:**
1. Toggle DITHER_CHECKBOX on.

**Expected:** No visual change (GRD-110 — dither is
pending_renderer). State key updates.

---

## Stroke gradient

### GRD-M10: Stroke gradient within-stroke

**Steps:**
1. Apply a stroke-only gradient (via the fill/stroke widget to
   switch to stroke edit mode — per GRD-106 this path isn't fully
   wired; use a hand-constructed gradient for now).
2. Increase stroke width to 10 pt.

**Expected:** Stroke renders with a gradient along its width.

**Auto-covered:** Phase 8 rendering tests (unit-level build
checks only; visual correctness needs this manual test).

---

## Multi-selection

### GRD-M11: Uniform selection

**Steps:**
1. Select two rectangles with the same gradient.

**Expected:** Panel shows that gradient (Type / Angle / etc.
match). Preview state off.

### GRD-M12: Mixed selection

**Steps:**
1. Select a rectangle with a linear gradient and a circle with a
   radial gradient.

**Expected:** Panel keeps its existing values (blank / `—`
rendering of mixed fields is aspirational per §Multi-selection;
current implementation leaves the fields at their last uniform
value and sets `preview_state = false`).

### GRD-M13: Solid + gradient selection

**Steps:**
1. Select a rectangle with a gradient fill and another with a
   solid-color fill.

**Expected:** Mixed selection per above. Editing the panel
applies the resulting gradient to all selected elements,
promoting the solid one via fill-type coupling.

---

## Library browsing

### GRD-M14: Library dropdown switch

**Steps:**
1. Click DOCUMENT_LIBRARY_DROPDOWN.
2. Select Spectrums.

**Expected:** Tile strip repopulates with Spectrums gradients.
Dropdown label updates.

### GRD-M15: Thumbnail size

**Steps:**
1. Click DOCUMENT_LIBRARY_SIZE_DROPDOWN.
2. Pick Small Thumbnail View.

**Expected:** Tile strip tiles shrink to 16 px. Medium (32 px)
and Large (64 px) likewise. List views are declared but
non-functional (GRD-116).

### GRD-M16: Open Gradient Library menu

**Steps:**
1. Open panel hamburger menu.
2. Hover Open Gradient Library.

**Expected:** Submenu lists all discovered libraries (currently
Neutrals, Spectrums, Simple Radial). Clicking one switches
`active_library_id` and the tile strip updates.

---

## Cross-app parity

### GRD-M17: Same gradient renders identically

**Setup:** Create a document with one rectangle. Apply the
Rainbow gradient from the Spectrums library.

**Steps:** Export the document SVG. Open in all four native apps.

**Expected:** Each app renders the rectangle with a visible
horizontal rainbow gradient. Positional accuracy within
reasonable tolerance. Stop colors match.

**Known gap:** GRD-113 — SVG export does not yet emit the
gradient, so this test currently requires constructing the
gradient programmatically in each app. A proper parity suite
lands with Phase 9 / Phase 10.

---

## Deferred additions (not in scope for this suite)

Items covered by `status: pending_renderer` or `GRD-NNN` known-
broken entries above; not worth manual testing until their
implementation lands:

- Freeform gradient visual rendering.
- Smooth interpolation (OKLab perceptual) visual output.
- Dither noise visibility.
- Along-stroke / across-stroke sub-mode rendering.
- Midpoint-to-stop synthesis for non-50% midpoints.
- SVG export / import round-trip.
- Text / TextPath / CompoundShape gradient fills.
