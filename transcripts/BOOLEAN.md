# Boolean Operations

The Boolean Operations Panel performs boolean operations on the geometry of the current selection. Operand handling, paint inheritance, element-type rules, and precision are specified in the subsections below. The core set-theoretic algorithm is already implemented in each app's `algorithms/boolean` module (for example, `jas_ocaml/lib/algorithms/boolean.ml` and `jas_dioxus/src/algorithms/boolean.rs`); this document specifies the panel, dialogs, and glue that connect it to document geometry.

## Terminology

The common commercial-product vocabulary for this class of panel is "Pathfinder" — used as the panel name, dialog title prefix, and menu-item label. That vocabulary belongs to a specific commercial product and is not used in this project. The canonical labels are:

- **Panel tab label**: "Boolean"
- **Panel hamburger menu items**: "Repeat Boolean Operation", "Boolean Options…", "Make Compound Shape", "Release Compound Shape", "Expand Compound Shape"
- **Options dialog title**: "Boolean Options"
- **Trap dialog title** (when we implement Trap): "Boolean Trap"
- **Action category in `actions.yaml`**: `boolean`
- **Action name prefix**: `boolean_` (e.g. `boolean_union`)
- **State field prefix**: `boolean_` (e.g. `state.boolean_precision`)

Never use "Pathfinder" anywhere — in UI labels, code identifiers, or documentation. We prefer the term "Boolean Operations".

The panel exposes nine operations:

- UNION merges all elements into a single element, taking the union of their fills.
- SUBTRACT_FRONT subtracts the fill of the frontmost element from all other elements in the selection
- INTERSECTION takes the intersection of fills
- EXCLUDE subtracts the intersection of all elements from all elements in the selection
- DIVIDE cuts the elements apart so that none of them overlap
- TRIM removes the parts of elements that are hidden behind other elements
- MERGE performs a TRIM, and afterwards merges all elements that are touching and have exactly the same fill color
- CROP uses the frontmost element as a mask and crops all other elements in the selection, removing anything outside the mask
- SUBTRACT_BACK is like SUBTRACT_FRONT but it subtracts the backmost element from all other elements

OUTLINE (which extracts fill boundaries as strokes) is intentionally deferred. It requires the planar-graph / DCEL primitive planned for the Shape Builder tool; we will add it once that primitive lands, rather than implement edge extraction twice. The initial release ships with 5 icons rather than 6.

**Trap** is likewise deferred until we have a physical printing model. Trap is a prepress feature whose every parameter (ink thickness, tint reduction, process-vs-spot handling, trap direction) presupposes spot colors, separations, and a press-output pipeline — none of which this application currently has. The panel menu will not include a "Trap…" item in the initial release.

## Operand and paint rules

Each operation specifies which operands are consumed (removed from the document) and which paint — fill, stroke, opacity, blend mode — the result carries. "Frontmost" means topmost in z-order; "backmost" means the reverse.

- **UNION**, **INTERSECTION**, **EXCLUDE** (destructive click): all operands are consumed. The result is a single path, painted with the frontmost operand's fill, stroke, opacity, and blend mode.
- **SUBTRACT_FRONT**: the frontmost operand is consumed (it was the cutter). Each remaining element has the frontmost subtracted from it and keeps its own paint.
- **SUBTRACT_BACK**: the backmost operand is consumed. Each remaining element has the backmost subtracted from it and keeps its own paint.
- **CROP**: the frontmost operand is consumed (it was the mask). Each remaining element is clipped to the mask's interior and keeps its own paint.
- **DIVIDE**: every operand is consumed. The output is a set of non-overlapping fragments. Each fragment inherits the paint of the frontmost original element that covered its area.
- **TRIM**: every operand is kept. Back-element geometry is chipped away wherever a front element covers it. Each survivor keeps its own paint.
- **MERGE**: performs TRIM, then unions any two touching survivors whose fills are equal under the merge predicate below. The unioned path carries the frontmost contributor's full paint (fill, stroke, opacity, blend mode).

**MERGE predicate.** Two paths have "matching fill" when both fills are solid colors whose canonicalized hex (RGB with normalized alpha channel) is exactly equal. Named-swatch references resolve to their current color before comparison. Gradients, patterns, and "none" fills never match — including against themselves. Only the fill property is inspected: stroke, stroke width, stroke paint, opacity, and blend mode do not affect the merge predicate, and near-matches (e.g. `#ff0000` vs `#ff0001`) are treated as distinct. A future enhancement could add a fill-tolerance field to Boolean Options, but the initial implementation is strict.

For Alt/Option+click compound shapes, the same paint rule applies at creation time: the compound shape inherits the frontmost operand's paint. After creation the compound shape can be restyled like any other element.

## Compound shapes (live, non-destructive)

The four Shape Mode operations (UNION, SUBTRACT_FRONT, INTERSECTION, EXCLUDE) have two activation modes:

- **Click**: destructively applies the boolean. The selected elements are replaced by a single result path.
- **Alt/Option+click**: creates a **compound shape** — a new element type that stores the operation and its operand paths as a live tree. The compound shape re-evaluates whenever any operand is edited. Compound shapes participate in selection, rendering, hit-testing, and serialization like any other element; their operand tree persists across save/reopen.

Only the four Shape Mode operations produce compound shapes. DIVIDE / TRIM / MERGE / CROP / SUBTRACT_BACK are always destructive and have no compound-shape variant.

The **Expand** button (right half of the Shape Modes row) and the **Expand Compound Shape** menu item both flatten the currently-selected compound shape(s) into static path(s), discarding the operand tree. This is a one-way operation. Enabled only when the selection contains at least one compound shape.

The **Make Compound Shape** menu item is equivalent to Alt+clicking UNION: it creates a compound shape from the selection using UNION as the initial operation. The operation can be changed afterward by selecting the compound shape and clicking a different Shape Mode button.

The **Release Compound Shape** menu item is the inverse of Make: it removes the compound-shape container and restores its operand paths as independent elements, each keeping its original fill / stroke / opacity. Enabled only when the selection contains at least one compound shape.

## Compound shape data model

Compound shapes are a new element kind. This section specifies their storage, selection, rendering, hit-testing, and serialization, and how they integrate with the existing element system. The design targets parity across all five apps.

### Element structure

A CompoundShape stores:

- `operation`: one of `union`, `subtract_front`, `intersection`, `exclude` — the four Shape Mode operations. The destructive-only operations never produce compound shapes.
- `operands`: an ordered list of child elements, recursive (operands can themselves be compound shapes, groups, paths, text, etc.). List order mirrors canvas z-order: index 0 is backmost, last index is frontmost.
- Standard paint and placement properties (`fill`, `stroke`, `opacity`, `blend_mode`, `transform`). At creation these inherit from the frontmost operand per the Operand and paint rules; afterward they are independently editable.
- `cached_geometry`: a polygon set produced by evaluating `operation` over `operands`. Derived, not serialized. Invalidated on any operand geometry or z-order change.

### Selection and isolation

Compound shapes reuse the group-isolation model. A single click selects the compound shape as a unit — outer bounding-box handles, unit transform, paint edits affect the compound shape's own paint. Double-click (or the existing "enter group" action) isolates into the compound shape for operand-level editing. Operand edits invalidate `cached_geometry`; the next render or bounds query recomputes it.

### Rendering

Normal mode: render the compound shape as one filled and stroked element using `cached_geometry` and its own paint. Isolation mode: additionally draw the operands underneath, dimmed, as an editing aid.

### Hit-testing

Outside isolation: one hit test against `cached_geometry`. Inside isolation: per-operand hit testing, frontmost first.

### Serialization

Save the operand tree verbatim, together with `type: compound_shape` and `operation`. Never serialize `cached_geometry`; recompute on load. This keeps documents resilient to Precision changes — opening the same file with different Precision re-evaluates every compound shape.

### Undo / redo

Operand edits land in the undo stack at operand granularity, not compound-shape-snapshot granularity. Re-evaluating `cached_geometry` after an undo or redo step is cheap (polygon ops on already-flattened inputs) and happens lazily on next render.

### Transforms

Outer transform: apply to the compound shape's own `transform`; no geometry recomputation, same as group transforms. Inner transform (on an operand): apply to the operand and invalidate `cached_geometry`.

### Bounds

Computed from `cached_geometry` transformed by the compound shape's own `transform`. Same pattern as every other element.

### Layers panel

Compound shapes appear as expandable containers, visually distinguished from groups by a different icon. Expanding reveals the operand list; dragging operands within the list changes their z-order and re-evaluates.

### Expand and Release semantics

- **Expand**: replace the compound shape with a single Bézier path refit from `cached_geometry` using Precision. The expanded path carries the compound shape's own paint. Operand tree discarded.
- **Release**: replace the compound shape with its operands, inserted into the parent at the compound shape's position and in their original operand-list z-order. Each operand keeps its own paint. The compound shape's paint is discarded.

### Implementation sequence

Per project convention: flask first, then jas_dioxus, JasSwift, jas_ocaml, jas. Within each app:

1. Add the `compound_shape` element type to the schema and element enum.
2. Implement evaluation over the operand tree using the existing boolean algorithm.
3. Render and hit-test (non-isolated path first).
4. Serialization round-trip, with a cross-app parity test.
5. Selection, transform, and bounds integration.
6. Isolation mode: enter/exit, operand-level selection and editing, dimmed operand display.
7. Layers panel: icon, expansion, drag-reorder.
8. Undo/redo at operand granularity.
9. Expand and Release implementations.
10. Alt/Option+click on the four Shape Mode buttons; Make Compound Shape menu item wiring.

Scope estimate: 2–3 weeks per app, 8–12 weeks across all five. The first four phases constitute the minimum viable compound shape (read, evaluate, render, save); the remaining phases ship incrementally.

## Geometry and precision

The core algorithm in `algorithms/boolean` operates on polygon sets (rings of points). Document elements are mapped to polygon sets on the way in, and the resulting polygon set is refit back to Bézier paths on the way out. A single tolerance — `Precision` from the Boolean Options dialog — governs every tolerance-sensitive step:

- **Flattening.** Bézier curves are sampled into polyline rings such that the maximum perpendicular distance between the true curve and its approximation does not exceed Precision.
- **Refit.** The output polygon set is passed through `algorithms/fit_curve` so the resulting element is a Bézier path that matches what the artist drew. The same Precision bounds the fit error.
- **Redundant-point removal.** When "Remove Redundant Points" is checked in the Boolean Options dialog, collinear points in the output are collapsed within Precision.

Element-type handling for operands:

- **Paths** (including ellipses, rectangles, and other parametric shapes): feed their geometry straight in. Open paths are implicitly closed with a straight segment.
- **Text**: flatten to glyph outlines first, then treat as a path.
- **Groups**: recursively flatten the group's contents into a single polygon set, treated as one operand.
- **Compound paths**: feed their rings in directly.
- **Compound shapes**: evaluate the live tree to a polygon set and use that as the operand. Destructive operations on compound shapes discard their trees.
- **Rasters, images, symbols, and other non-geometric elements**: skipped silently; a status-bar message reports how many elements were skipped.

## Boolean Options dialog

A modal dialog, reached from the panel menu's "Boolean Options…" item. It edits three document-level preferences that every boolean operation consults.

Fields:

- **Precision** (number input, default `0.0283 pt`): the single tolerance used for Bézier flattening, Bézier refit, and redundant-point collapse. Range 0.001–100 pt.
- **Remove Redundant Points** (checkbox, default unchecked): when on, collinear points in the output whose deviation is within Precision are collapsed after each operation.
- **Divide and Outline Will Remove Unpainted Artwork** (checkbox, default unchecked): when on, DIVIDE fragments with no fill and no stroke are discarded rather than kept as invisible paths. (OUTLINE is deferred; only DIVIDE consults this flag for now.)

Buttons:

- **Defaults**: resets all three fields to their factory values in the dialog (does not commit).
- **Cancel**: dismisses the dialog without applying.
- **OK**: writes the three fields to document state and dismisses.

Backing state in `workspace/state.yaml`:

- `state.boolean_precision` (number, default `0.0283`)
- `state.boolean_remove_redundant_points` (bool, default `false`)
- `state.boolean_divide_remove_unpainted` (bool, default `false`)

These values are persisted with the document, read by every operation implementation, and written only by the dialog's OK action.

```yaml
panel:
- .row: "Shape Modes:"
- .row:
  - .col-2: UNION
  - .col-2: SUBTRACT_FRONT
  - .col-2: INTERSECTION
  - .col-2: EXCLUDE
  - .col-4: EXPAND
- .row:
  - .col-2: DIVIDE
  - .col-2: TRIM
  - .col-2: MERGE
  - .col-2: CROP
  - .col-2: SUBTRACT_BACK
  - .col-2: ""   # reserved slot for OUTLINE (deferred)
```

## Panel metadata

The yaml panel entry wraps the layout above with the following metadata, matching the pattern established by `workspace/panels/align.yaml`:

- **id**: `boolean_panel_content`
- **type**: `panel`
- **summary**: `"Boolean"`
- **description**: a condensed form of this document's top-level prose — what the panel does, the destructive-vs-compound distinction, the operand and paint rules summary, and the enable/disable behavior.

### Panel-level transient state

Only one field:

- **last_operation**: enum over the nine operations (`union`, `intersection`, `subtract_front`, `exclude`, `divide`, `trim`, `merge`, `crop`, `subtract_back`), default `null`. Populated on each operation-button click. Feeds "Repeat Boolean Operation"; see Repeat state below.

The three Boolean Options fields (`precision`, `remove_redundant_points`, `divide_remove_unpainted`) live in document state, not panel state, and are edited only through the Boolean Options dialog.

### init

- `last_operation: "state.last_boolean_op"`

### Menu

Hamburger-menu items, in order:

- **Repeat Boolean Operation** — re-applies `state.last_boolean_op` against the current selection. Enabled when `panel.last_operation != null` and the current selection satisfies that operation's enable rule.
- **Boolean Options…** — opens the modal described under Boolean Options dialog.
- separator
- **Make Compound Shape** — equivalent to Alt+click on UNION. Enabled when `selection_count >= 2`.
- **Release Compound Shape** — enabled when the selection contains at least one compound shape.
- **Expand Compound Shape** — same enable rule as Release.
- separator
- **Reset Panel** — sets `panel.last_operation` to `null`. Does not touch document state; for that, open Boolean Options and click Defaults.
- separator
- **Close Boolean** — dismisses the panel.

The Reset Panel and Close Boolean items are added for parity with the Align panel's menu.

### Default placement

The Boolean panel's default-workspace placement is the same panel group that contains Transform and Align, appearing to the right of Align in the tab order. The three panels all operate on the current selection's geometry and belong together semantically.

Users can redock the Boolean panel freely; this placement applies only to the initial workspace and to the "Reset Workspace" action. Placement is configured in `workspace/default_layouts.yaml` per the existing panel-group conventions.

Additionally, the Window menu gains a **Boolean** toggle item (alongside the existing panel toggles) so the panel can be shown or hidden independently of its dock state.

## Panel actions

All actions are defined in `workspace/actions.yaml` under `category: boolean`. Each action's `effects` list begins with `snapshot` (for undo) unless noted otherwise. Native apps dispatch on the single-key effect following `snapshot`.

### Destructive operation actions (9)

One per op. Each writes `state.last_boolean_op` so Repeat can replay it.

- `boolean_union`
- `boolean_intersection`
- `boolean_subtract_front`
- `boolean_exclude`
- `boolean_divide`
- `boolean_trim`
- `boolean_merge`
- `boolean_crop`
- `boolean_subtract_back`

### Compound-shape-creating actions (4)

Fire when the user Alt/Option+clicks one of the four Shape Mode buttons. Separate action per op so the native apps can keep a "one action, one effect" pattern.

- `boolean_union_compound`
- `boolean_intersection_compound`
- `boolean_subtract_front_compound`
- `boolean_exclude_compound`

### Compound-shape menu actions (3)

- `make_compound_shape` — equivalent to `boolean_union_compound` fired from the menu.
- `release_compound_shape`
- `expand_compound_shape`

### Infrastructure actions (5)

- `repeat_boolean_operation` — reads `state.last_boolean_op` and dispatches the matching action above.
- `open_boolean_options` — opens the Boolean Options modal dialog.
- `boolean_options_confirm` — writes the three dialog fields to document state; fired by the dialog's OK button.
- `reset_boolean_options_defaults` — resets the three fields to factory values inside the dialog only; does not commit.
- `reset_boolean_panel` — sets `panel.last_operation = null`.

`close_panel` is reused from the existing Align / common-panel infrastructure; not added here.

Total new actions: 21.

## Enable / disable rules

Every button and menu item binds a `disabled` expression evaluated against the current selection and panel state.

### Operation buttons (all nine)

- `bind: disabled: 'active_document.selection_count < 2'`

The nine operation buttons use the raw selection count, not an eligible-element count. Non-geometric elements (rasters, symbols, images) in the selection do not block the op; they are skipped silently by the implementation, and a status-bar message reports how many were skipped. If fewer than two eligible operands remain after skipping, the op is a no-op with a status message.

### Expand button (on the panel)

- `bind: disabled: 'not active_document.selection_has_compound_shape'`

Requires a new document predicate `selection_has_compound_shape` that returns true when at least one selected element is a compound shape. This predicate is also consumed by the three compound-shape menu items.

### Compound-shape menu items

- **Make Compound Shape**: `disabled: 'active_document.selection_count < 2'`.
- **Release Compound Shape**: `disabled: 'not active_document.selection_has_compound_shape'`.
- **Expand Compound Shape**: same as Release.

### Repeat Boolean Operation menu item

- `disabled: 'panel.last_operation == null or active_document.selection_count < 2'`

The full "selection satisfies the remembered op's own enable rule" is simplified here because every op currently shares the `selection_count >= 2` gate. Revisit if future ops adopt different gates.

### Reset Panel / Close Boolean / Boolean Options…

Always enabled.

## Repeat state

The "Repeat Boolean Operation" menu item replays the most recent op on the current selection. Its backing store:

- **`state.last_boolean_op`** (document state, `workspace/state.yaml`): string enum with 13 allowed values and a default of `null`.

The 13 values are the nine destructive ops —

`union`, `intersection`, `subtract_front`, `exclude`, `divide`, `trim`, `merge`, `crop`, `subtract_back`

— plus the four compound-creating variants:

`union_compound`, `intersection_compound`, `subtract_front_compound`, `exclude_compound`

### Write points

Every one of the 13 corresponding actions writes this field as its last effect, dual-written to `panel.last_operation` per the Align convention. The three compound-shape menu infrastructure actions — `release_compound_shape`, `expand_compound_shape`, `make_compound_shape` — do **not** write the field. Make is structurally equivalent to `boolean_union_compound`, so Repeat can replay Make via that path; Release and Expand are one-shot cleanup actions whose accidental replay on a different selection would be annoying, so they are deliberately non-repeatable.

### Dispatch

`repeat_boolean_operation` reads `state.last_boolean_op`, looks up the matching action, and dispatches it. The dispatched action runs its own `snapshot` effect, so undo granularity stays identical to a direct click.

### Persistence

Document state means Repeat survives panel close/reopen and document save/load. A document reopened tomorrow still remembers its last boolean op.

## Testing

A companion manual-test file `transcripts/BOOLEAN_TESTS.md` is the authoritative fixture set for this panel, matching the per-component test convention established by `transcripts/ALIGN_TESTS.md`. Each of the nine destructive operations, the four compound-creating variants, Make / Release / Expand Compound Shape, and Repeat Boolean Operation gets a numbered scenario with the standard **Setup / Action / Expected** structure. Coverage categories:

- **Canonical case per op**: simplest input that exercises the operation (e.g. two overlapping circles → UNION → one merged shape).
- **Geometric edge cases**: operands sharing an edge without overlapping, completely nested operands, disjoint operands, one operand entirely inside another, zero-area intersections.
- **Paint inheritance**: verify the frontmost operand's paint survives on UNION / INTERSECTION / EXCLUDE; verify survivor paints on SUBTRACT / CROP / DIVIDE / TRIM / MERGE; verify the MERGE predicate (hex equality, gradient/pattern never match).
- **Element-type coverage**: mixed selections containing paths, text, ellipses, groups, compound paths, and compound shapes; verify rasters / symbols are skipped with a status message.
- **Precision behavior**: a tight-overlap pair that should resolve cleanly at default Precision but may not at 10× Precision; the Remove-Redundant-Points checkbox observably changes vertex count on a chosen fixture.
- **Compound shape lifecycle**: Make; edit an operand, verify the compound shape re-evaluates; Release; Expand; save/reload round-trip with cached geometry discarded and recomputed.
- **Repeat**: apply one op, select a different selection, invoke Repeat, verify the same op fires; verify Repeat survives panel close/reopen and document save/load.

`BOOLEAN_TESTS.md` itself is written during implementation of the first app (flask, per project convention); subsequent apps' implementations are verified against the same test list, and a port is not considered complete until every scenario passes. This is a hard gate for declaring any app's Boolean panel implementation complete.
