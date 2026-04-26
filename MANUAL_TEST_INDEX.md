# Manual Test Suite — Index

Index of every `transcripts/*_TESTS.md` in the repo. Pair with
`MANUAL_TESTING.md` (procedure / methodology) and the individual
`*_TESTS.md` files (the test bodies).

**Total: 36 test files** covering 27 tools + 13 of 14 panels +
2 native text tools. Every `workspace/panels/*.yaml` and
`workspace/tools/*.yaml` is covered. (Some files cover multiple
yaml — e.g. `SELECTION_TOOL_TESTS.md` covers
selection + partial_selection + interior_selection.)

The ordering below groups tests into **tiers by dependency +
priority**. A tier-N test typically assumes every tier &lt;N component
already works. Run tier 0 first as a smoke gate before any deeper
audit; subsequent tiers can be exercised on demand or in order.

---

## How to read a row

| Column   | Meaning                                                      |
|----------|--------------------------------------------------------------|
| File     | The `_TESTS.md` file in `transcripts/`.                      |
| Covers   | The yaml(s) it tests — only filled in when one file covers more than one yaml. |
| Notes    | Known-broken summary, blockers, deferral status. Truncated; see file's "Known broken" block for detail. |

---

## Tier 0 — Foundation smoke

Tools / panels that have to work before anything else can be
tested. The whole canvas is dead if these are. Run this tier
first on every full audit.

| File | Covers | Notes |
|------|--------|-------|
| [HAND_TOOL_TESTS.md](transcripts/HAND_TOOL_TESTS.md) | hand tool | Pan + double-click "Fit Active Artboard" gesture. Without Hand, you cannot navigate the canvas. |
| [ZOOM_TOOL_TESTS.md](transcripts/ZOOM_TOOL_TESTS.md) | zoom tool | Click-zoom + Alt-zoom-out + scrubby zoom + Z shortcut. Without Zoom, you cannot inspect detail. |
| [SELECTION_TOOL_TESTS.md](transcripts/SELECTION_TOOL_TESTS.md) | selection / partial_selection / interior_selection | Selection gates almost everything else (panels read selection state; transform tools operate on it). Three tools share the file. |
| [LAYERS_TESTS.md](transcripts/LAYERS_TESTS.md) | layers panel | Document-tree visibility / lock / hide / reorder. Almost every other component reads visibility / locked. |

---

## Tier 1 — Primitive shape creation

Tools that create the basic objects every later test uses as a
fixture. Without these, you can't construct test inputs.

| File | Covers | Notes |
|------|--------|-------|
| [RECT_TOOL_TESTS.md](transcripts/RECT_TOOL_TESTS.md) | rect / rounded_rect | Rectangle is the workhorse fixture for almost every panel test. |
| [ELLIPSE_TOOL_TESTS.md](transcripts/ELLIPSE_TOOL_TESTS.md) | ellipse | |
| [LINE_TOOL_TESTS.md](transcripts/LINE_TOOL_TESTS.md) | line | |
| [POLYGON_TOOL_TESTS.md](transcripts/POLYGON_TOOL_TESTS.md) | polygon | |
| [STAR_TOOL_TESTS.md](transcripts/STAR_TOOL_TESTS.md) | star | |
| [PEN_TOOL_TESTS.md](transcripts/PEN_TOOL_TESTS.md) | pen | Path creation; required for path-eraser, smooth, brushes, boolean fixtures. |
| [PENCIL_TOOL_TESTS.md](transcripts/PENCIL_TOOL_TESTS.md) | pencil | Free-hand path creation. |
| [ANCHOR_POINT_TOOLS_TESTS.md](transcripts/ANCHOR_POINT_TOOLS_TESTS.md) | add_anchor_point / delete_anchor_point / anchor_point | Path editing trio. Three tools share the file. |
| [TYPE_TOOL_TESTS.md](transcripts/TYPE_TOOL_TESTS.md) | Type / Type on Path (both native, no yaml) | Text creation; required for Character / Paragraph panel tests. Permanent-native per `NATIVE_BOUNDARY.md` §6. |

---

## Tier 2 — Foundational style panels

The two panels every shape and path interacts with. Color and
Stroke gate every later panel that writes to fill/stroke state.

| File | Covers | Notes |
|------|--------|-------|
| [COLOR_TESTS.md](transcripts/COLOR_TESTS.md) | color panel | Drives `state.fill_color` / `state.stroke_color`; consumed by Eyedropper, Magic Wand, Gradient, Swatches, Brushes. |
| [STROKE_TESTS.md](transcripts/STROKE_TESTS.md) | stroke panel | All `state.stroke_*` keys. Consumed by Brushes, Paintbrush, Eyedropper, Magic Wand. |
| [SWATCHES_TESTS.md](transcripts/SWATCHES_TESTS.md) | swatches panel | Stored color library; depends on Color for application. |

---

## Tier 3 — Workspace structure & navigation

Document containers and "where does the work happen" surface.
Doesn't gate later tests strictly, but breaks loudly if wrong.

| File | Covers | Notes |
|------|--------|-------|
| [ARTBOARDS_TESTS.md](transcripts/ARTBOARDS_TESTS.md) | artboards panel | Artboard list / rename / activate. |
| [ARTBOARD_TOOL_TESTS.md](transcripts/ARTBOARD_TOOL_TESTS.md) | artboard tool | Creates / resizes artboards on the canvas. |
| [PROPERTIES_TESTS.md](transcripts/PROPERTIES_TESTS.md) | properties panel | **Placeholder panel today** — only Session A (lifecycle + summary render) is `[wired]`. Field tests are `[placeholder]` slots. |

---

## Tier 4 — Selection-aware tools

Tools that act on existing primitives — they need Tier 1
(primitives) and Tier 0 (selection / layers) to test
meaningfully.

| File | Covers | Notes |
|------|--------|-------|
| [LASSO_TOOL_TESTS.md](transcripts/LASSO_TOOL_TESTS.md) | lasso | Free-form selection. |
| [MAGIC_WAND_TOOL_TESTS.md](transcripts/MAGIC_WAND_TOOL_TESTS.md) | magic_wand tool **and** magic_wand panel | One file covers tool + its panel. OCaml dblclick→panel deferred (see Known broken). |
| [SCALE_TOOL_TESTS.md](transcripts/SCALE_TOOL_TESTS.md) | scale | Transform tool family — share `state.transform_reference_point`. |
| [ROTATE_TOOL_TESTS.md](transcripts/ROTATE_TOOL_TESTS.md) | rotate | Same family. |
| [SHEAR_TOOL_TESTS.md](transcripts/SHEAR_TOOL_TESTS.md) | shear | Same family. |
| [ALIGN_TESTS.md](transcripts/ALIGN_TESTS.md) | align panel | Reads selection bounds + artboard rect. Depends on Tier 3 artboards for the "Align to artboard" reference. |

---

## Tier 5 — Path-editing tools

Tools that mutate existing paths. Need Tier 1 paths (Pen / Pencil)
to set up fixtures.

| File | Covers | Notes |
|------|--------|-------|
| [PATH_ERASER_TOOL_TESTS.md](transcripts/PATH_ERASER_TOOL_TESTS.md) | path_eraser | Erase along a stroke; splits / opens paths. |
| [SMOOTH_TOOL_TESTS.md](transcripts/SMOOTH_TOOL_TESTS.md) | smooth | Refit a flat-polyline range with Bezier curves. |

---

## Tier 6 — Specialty paint, brush, boolean, sample

Highest-dependency tier — these tools and panels read state from
many other components and exercise broad slices of the system.

| File | Covers | Notes |
|------|--------|-------|
| [BRUSHES_TESTS.md](transcripts/BRUSHES_TESTS.md) | brushes panel | Depends on Stroke + paths. Calligraphic-only in Phase 1. |
| [PAINTBRUSH_TOOL_TESTS.md](transcripts/PAINTBRUSH_TOOL_TESTS.md) | paintbrush | Depends on Brushes panel + Stroke + paths. |
| [BLOB_BRUSH_TOOL_TESTS.md](transcripts/BLOB_BRUSH_TOOL_TESTS.md) | blob_brush | Depends on Paintbrush + Boolean (merge / erase via boolean primitives). |
| [BOOLEAN_TESTS.md](transcripts/BOOLEAN_TESTS.md) | boolean panel | Depends on Path geometry + planar primitives. Several known-broken / deferred items (OUTLINE, Trap). |
| [EYEDROPPER_TOOL_TESTS.md](transcripts/EYEDROPPER_TOOL_TESTS.md) | eyedropper | Reads / writes Fill / Stroke / Opacity / Character / Paragraph state surfaces. Character / Paragraph tests are `[placeholder]` until text-internals follow-up. OCaml toolbar icon deferred. |

---

## Tier 7 — Specialty panels (text formatting, opacity, gradient)

Panels that operate on attributes already produced by other tools.

| File | Covers | Notes |
|------|--------|-------|
| [CHARACTER_TESTS.md](transcripts/CHARACTER_TESTS.md) | character panel | Needs Type-tool created text. |
| [PARAGRAPH_TESTS.md](transcripts/PARAGRAPH_TESTS.md) | paragraph panel | Needs Type + Character. |
| [OPACITY_TESTS.md](transcripts/OPACITY_TESTS.md) | opacity panel | Element opacity + blend mode + opacity masks. |
| [GRADIENT_TESTS.md](transcripts/GRADIENT_TESTS.md) | gradient panel | Depends on Color (stops). |

---

## Cross-app parity

Every `_TESTS.md` ends with a per-platform parity section
(typically Session H or K — names vary). Run parity passes per
platform, not per test, to amortize app launch + fixture setup.

The platform set is consistently **Rust / Swift / OCaml / Python /
Flask**, but Flask is omitted from non-generic tools and OCaml
sometimes has icon / dblclick deferrals (see each file's Known
broken).

---

## Recommended audit cadence

| Trigger | Scope |
|---------|-------|
| Every release candidate | Tier 0 smoke (4 files, ~15 min). |
| When changing a foundational system (selection, layout, theming, document model) | Tiers 0 + impacted file's tier. |
| When changing a single component | That component's `_TESTS.md` only — sessions A (smoke) + the specific feature area. |
| Quarterly full audit | All tiers in order. ~6 hours including parity passes. |
| When yaml changes | Diff yaml IDs against test IDs in the matching `_TESTS.md`; per `MANUAL_TESTING.md` § Maintenance rituals. |
| Stale-sweep | Files whose `_Last reviewed:_` or `_Last synced:_` date is &gt;60 days old. |

---

## Quick reference (alphabetical)

| File | Tier |
|------|------|
| [ALIGN_TESTS.md](transcripts/ALIGN_TESTS.md) | 4 |
| [ANCHOR_POINT_TOOLS_TESTS.md](transcripts/ANCHOR_POINT_TOOLS_TESTS.md) | 1 |
| [ARTBOARDS_TESTS.md](transcripts/ARTBOARDS_TESTS.md) | 3 |
| [ARTBOARD_TOOL_TESTS.md](transcripts/ARTBOARD_TOOL_TESTS.md) | 3 |
| [BLOB_BRUSH_TOOL_TESTS.md](transcripts/BLOB_BRUSH_TOOL_TESTS.md) | 6 |
| [BOOLEAN_TESTS.md](transcripts/BOOLEAN_TESTS.md) | 6 |
| [BRUSHES_TESTS.md](transcripts/BRUSHES_TESTS.md) | 6 |
| [CHARACTER_TESTS.md](transcripts/CHARACTER_TESTS.md) | 7 |
| [COLOR_TESTS.md](transcripts/COLOR_TESTS.md) | 2 |
| [ELLIPSE_TOOL_TESTS.md](transcripts/ELLIPSE_TOOL_TESTS.md) | 1 |
| [EYEDROPPER_TOOL_TESTS.md](transcripts/EYEDROPPER_TOOL_TESTS.md) | 6 |
| [GRADIENT_TESTS.md](transcripts/GRADIENT_TESTS.md) | 7 |
| [HAND_TOOL_TESTS.md](transcripts/HAND_TOOL_TESTS.md) | 0 |
| [LASSO_TOOL_TESTS.md](transcripts/LASSO_TOOL_TESTS.md) | 4 |
| [LAYERS_TESTS.md](transcripts/LAYERS_TESTS.md) | 0 |
| [LINE_TOOL_TESTS.md](transcripts/LINE_TOOL_TESTS.md) | 1 |
| [MAGIC_WAND_TOOL_TESTS.md](transcripts/MAGIC_WAND_TOOL_TESTS.md) | 4 |
| [OPACITY_TESTS.md](transcripts/OPACITY_TESTS.md) | 7 |
| [PAINTBRUSH_TOOL_TESTS.md](transcripts/PAINTBRUSH_TOOL_TESTS.md) | 6 |
| [PARAGRAPH_TESTS.md](transcripts/PARAGRAPH_TESTS.md) | 7 |
| [PATH_ERASER_TOOL_TESTS.md](transcripts/PATH_ERASER_TOOL_TESTS.md) | 5 |
| [PENCIL_TOOL_TESTS.md](transcripts/PENCIL_TOOL_TESTS.md) | 1 |
| [PEN_TOOL_TESTS.md](transcripts/PEN_TOOL_TESTS.md) | 1 |
| [POLYGON_TOOL_TESTS.md](transcripts/POLYGON_TOOL_TESTS.md) | 1 |
| [PROPERTIES_TESTS.md](transcripts/PROPERTIES_TESTS.md) | 3 |
| [RECT_TOOL_TESTS.md](transcripts/RECT_TOOL_TESTS.md) | 1 |
| [ROTATE_TOOL_TESTS.md](transcripts/ROTATE_TOOL_TESTS.md) | 4 |
| [SCALE_TOOL_TESTS.md](transcripts/SCALE_TOOL_TESTS.md) | 4 |
| [SELECTION_TOOL_TESTS.md](transcripts/SELECTION_TOOL_TESTS.md) | 0 |
| [SHEAR_TOOL_TESTS.md](transcripts/SHEAR_TOOL_TESTS.md) | 4 |
| [SMOOTH_TOOL_TESTS.md](transcripts/SMOOTH_TOOL_TESTS.md) | 5 |
| [STAR_TOOL_TESTS.md](transcripts/STAR_TOOL_TESTS.md) | 1 |
| [STROKE_TESTS.md](transcripts/STROKE_TESTS.md) | 2 |
| [SWATCHES_TESTS.md](transcripts/SWATCHES_TESTS.md) | 2 |
| [TYPE_TOOL_TESTS.md](transcripts/TYPE_TOOL_TESTS.md) | 1 |
| [ZOOM_TOOL_TESTS.md](transcripts/ZOOM_TOOL_TESTS.md) | 0 |

---

## Maintenance

When a new `_TESTS.md` lands, add a row to the appropriate tier
table _and_ to the alphabetical quick-reference. When a tier
shifts (e.g. Properties moves from Tier 3 placeholder to a real
panel), move the row.
