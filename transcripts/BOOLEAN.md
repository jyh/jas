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

## Live element framework

CompoundShape is the first instance of a broader pattern we call **LiveElement**: an element kind that stores source inputs, evaluates them on demand via a per-feature function, and caches the result. Future live features (Live Effects like drop shadow, Blends, similar) will implement the same contract, so that adding a new live feature does not require editing the top-level element enum in every app.

### Contract

```
struct Source {
    children: Vec<Element>,        // element-valued inputs; embedded in the document tree
    params: Map<String, Value>,    // scalar-valued inputs (number, color, enum, string)
}

trait LiveElement {
    kind() -> LiveKind              // discriminator: CompoundShape, DropShadow, Blend, ...
    source() -> &Source
    source_mut() -> &mut Source
    invalidate()                    // marks per-feature internal cache dirty on source change
    render(canvas)                  // per-feature rendering; uses its own cache
    hit_test(point) -> HitResult
    bounds() -> Rect
    expand() -> Vec<Element>        // one-way flatten to static element(s)
    release() -> Vec<Element>       // inverse of Make: children returned to parent
    isolation_enter() / exit()      // optional; default no-op for features without canvas source editing
}
```

Design choices:

- **No shared cached-output type.** Each feature caches internally. A compound shape caches a polygon set; a future drop shadow would cache a rasterized buffer — unifying these under one type would either force a least-common-denominator or a tagged union that leaks per-feature knowledge. The trait only exposes `invalidate()` and `render()`.
- **`source.children` is a flat Vec.** Per-feature conventions dictate indexing (compound shape: operands in z-order; blend: `[a, b, spine?]`; drop shadow: `[source]`). No named slots. Children are embedded in the document tree and participate in per-element undo.
- **`source.params` values are a tagged union** of number / color / enum / string. Snapshot-undoable as a unit (distinct from children edits).
- **Optional isolation.** Features whose source is edited via a panel or dialog (drop shadow's scalar params) rather than on the canvas return a no-op from `isolation_enter()`.

### Dry-run against future candidates

The contract was pressure-tested against three hypothetical future live features before committing:

- **Drop Shadow** (a Live Effect): fits. Source = `[source_element]`, params = `{offset_x, offset_y, blur, color, opacity}`. Caches a rasterized buffer at render time. Hit-test delegates to source (shadow passes through). Forced the "no shared CachedOutput" decision.
- **Blend** (interpolate between two elements across N steps): fits. Source = `[a, b]` or `[a, b, spine]`, params = `{steps, easing}`. Caches N interpolated path elements. Renders each path in z-order.
- **Symbol** (reusable instance of a shared master): **does not fit.** Symbol instances reference a master in an external library, not embedded in the instance. Force-fitting would duplicate the master per instance or require external references that break `Source` embedding. Symbols belong in a separate linked/referenced-element abstraction, implemented whenever they are added to the app.

### Serialization (LiveElement)

A LiveElement serializes as:

```
{
  "type": "live",
  "kind": "compound_shape",        // or "drop_shadow", "blend", ...
  "kind_schema_version": 1,
  "children": [ ... embedded element objects ... ],
  "params": { ... feature-specific scalars ... },
  // plus standard paint and transform properties on the LiveElement itself
}
```

The `kind_schema_version` lets each feature's params schema evolve independently across releases.

## Compound shape data model

CompoundShape is the first LiveElement conformer (see Live element framework above). This section specifies its kind-specific storage, evaluation, rendering, hit-testing, and lifecycle. Cross-cutting concerns — selection plumbing, transform propagation, bounds computation, isolation entry/exit infrastructure, serialization skeleton, and render/hit-test dispatch — are inherited from the LiveElement infrastructure.

### Element structure

As a LiveElement conformer, a CompoundShape populates Source as follows:

- **`source.children`**: the operand list, in z-order (index 0 = backmost, last index = frontmost). Recursive — operands can be paths, groups, text, or nested LiveElements (including other compound shapes).
- **`source.params`**: `{ operation: "union" | "subtract_front" | "intersection" | "exclude" }`. Only the four Shape Mode operations can be compound; the destructive-only Path operations never produce compound shapes.
- **Standard paint and placement properties** (`fill`, `stroke`, `opacity`, `blend_mode`, `transform`) live on the LiveElement wrapper; afterward they are independently editable. At creation the four PAINT properties inherit from the frontmost child per the Operand and paint rules. `transform` does NOT: MAKE is a WRAP, and a wrapper is 0->1 — it never wears a member's `common` (`transcripts/EDIT_SEMANTICS_FREEZE.md` §3.4/§3.6, ratified 2026-07-27). Rust carries only a *unanimous* transform, and that is bug containment rather than law: the evaluator below flattens operands through a transform-blind walk, so an operand's own transform is ignored and only the wrapper's is applied at render. When that walk becomes transform-aware the carry is deleted and the children keep their own. Rust landed this 2026-07-27; JasSwift's `makeCompoundShape(operation:)` still hard-codes `opacity: 1.0` and `locked: false`, elects the frontmost's `transform` and `visibility` outright, and passes no `name`, `mask`, `blendMode` or `id` at all — so it diverges the other way and needs the matching commit.
- **Internal cache**: a polygon set produced by evaluating `source.params.operation` over `source.children`, refit to a Bézier path via `algorithms/fit_curve` for rendering. Derived, not serialized. Invalidated on any child geometry or z-order change, or on an `operation` param edit.

### Selection and isolation

Compound shapes reuse the group-isolation model. A single click selects the compound shape as a unit — outer bounding-box handles, unit transform, paint edits affect the compound shape's own paint. Double-click (or the existing "enter group" action) isolates into the compound shape for operand-level editing. Operand edits invalidate `cached_geometry`; the next render or bounds query recomputes it.

### Rendering

Normal mode: render the compound shape as one filled and stroked element using `cached_geometry` and its own paint. Isolation mode: additionally draw the operands underneath, dimmed, as an editing aid.

### Hit-testing

Outside isolation: one hit test against `cached_geometry`. Inside isolation: per-operand hit testing, frontmost first.

### Serialization

Serialized via the LiveElement schema above with `kind: "compound_shape"`, `kind_schema_version: 1`, `children` = operands, and `params.operation` = one of the four Shape Mode operations. Never serialize the internal polygon-set cache; recompute on load. This keeps documents resilient to Precision changes — opening the same file with a different Precision re-evaluates every compound shape.

### Undo / redo

- **Children edits** (geometry, z-order, paint of an operand) land in the undo stack at per-element granularity via the existing per-element undo system, not as a compound-shape snapshot.
- **Params edits** (switching the operation) snapshot as a single unit.
- Re-evaluating the cache after an undo or redo step is cheap (polygon ops on already-flattened inputs) and happens lazily on next render.

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

Compound shapes are canvas-dependent. Flask gets only the panel-UI / menu / dialog yaml wiring (no element type or renderer, since flask has no canvas subsystem). The recommended starting app for the compound-shape implementation itself is **jas_dioxus** (Rust), as the most canonical native target; JasSwift, jas_ocaml, and jas port from it.

Within each native app, 10 phases:

1. Define the LiveElement trait and `Source` type. Add a single `live` element variant to the element enum. Implement the shared infrastructure: render dispatch, hit-test dispatch, serialization skeleton, isolation-mode plumbing, expand/release plumbing, bounds/transform propagation.
2. Register CompoundShape as the first LiveKind. Implement its evaluate (existing boolean algorithm over operands), compound-shape-specific render (filled + stroked Bézier refit from cached polygon_set), and hit-test (point-in-polygon against cached geometry).
3. Serialization round-trip for the `{"type": "live", "kind": "compound_shape", ...}` schema; cross-app parity test.
4. Selection, transform, and bounds integration (largely inherited from LiveElement infrastructure).
5. Isolation mode: enter/exit, operand-level selection and editing, dimmed operand display.
6. Layers panel: icon, expansion, drag-reorder of children.
7. Undo/redo: children edits via existing per-element undo; param edits (operation switch) snapshot as a unit.
8. Expand and Release implementations.
9. Alt/Option+click wiring on the four Shape Mode buttons; Make Compound Shape menu item wiring.
10. BOOLEAN_TESTS.md coverage: every compound-shape scenario passes.

Scope estimate: ~2–3 weeks per native app, ~8–12 weeks across the four native apps. Phases 1–3 constitute the minimum viable compound shape (read, evaluate, render, save); remaining phases ship incrementally.

**Flask scope** (separate, ~1 week): yaml wiring for the Make / Release / Expand Compound Shape menu items, the Boolean Options dialog, Alt+click modifier detection on the four Shape Mode buttons (dispatches to the destructive action as a no-op until compound shapes exist), and panel-state plumbing for `last_operation`. None of this requires compound shapes to exist in flask's document model.

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

### Fill rule: the polygon set carries it

**Status: RULED 2026-07-26 (JYH). This is settled specification.** A polygon set does not have a fill rule of its own — it **carries the one its source declared**. The algorithm layer must never assume one.

**The ruling.** Neither fill rule is universally "more natural" for an artist, because they are natural for *different operations*. Even-odd matches the naive model of a **deliberate hole**: a shape inside a shape is a donut, with no thinking about direction. Non-zero matches what artists expect from **drawing**: a self-crossing scribble, or a five-pointed star drawn in one stroke, fills solid — where under even-odd the star gets a hollow pentagon, the classic surprise. Artists want both behaviours at once, which is exactly why SVG and PDF put `fill-rule` **on the path** rather than in the renderer.

**The decisive argument is correctness, not taste.** jas imports and exports SVG, and `PathElem` *already* carries `fill_rule`. A rule fixed in the algorithm layer therefore makes the boundary **lie**: a document declaring `fill-rule="nonzero"` would be silently reinterpreted by a boolean operation, and the artist would get a hole they never drew. The schema change is algorithm-layer only — the document side already said the right thing.

**What the law says, in four clauses.**

1. **Operands carry a rule.** The algorithm-layer operand type is `RuledPolygonSet` (Rust) / `BoolRuledPolygonSet` (Swift): rings plus the `PolyFillRule` / `BoolFillRule` that reads them. `boolean_normalize::normalize` takes the rule as a mandatory argument and there is no rule-less entry point, so the assumption cannot creep back in. A bare `PolygonSet` still exists — it is just geometry, not a region — and the standing convention is that one crossing a function boundary inside the algorithm layer means *even-odd, already canonical*.
2. **The rule reads the whole set at once**, exactly as SVG and PDF define it, not ring by ring. Under non-zero, nested same-orientation rings are a **solid** and overlapping ones are their **union**; under even-odd they are a **hole** and their **symmetric difference**. (Even-odd parity happens to be additive across rings, so the implementation may still resolve it per ring — that is an optimisation, not a different semantics.)
3. **Canonicalization spends the rule.** `canonicalize` / `boolCanonicalize` returns simple rings denoting the same region *read under even-odd*, whatever rule came in. Downstream — the sweep, the renderer, the corpus — needs no rule. This is the single place a declared rule is interpreted.
4. **Generated results declare EVEN-ODD.** A boolean result is machine-made, and even-odd is the safer declaration for it because it does not depend on the sweep emitting consistent winding: a hole stays a hole even if a future connection step hands it back wound the "wrong" way. This is now explicit rather than incidental — `boolean::RESULT_FILL_RULE` / `boolResultFillRule` names it, and both ports' destructive-boolean emitters stamp that constant.

**What this unblocked.** Inter-ring winding cancellation — the degenerate class the previous wave deliberately left unimplemented pending this ruling — is now implemented in both ports. It stopped being a question the moment the rule was carried: under a declared non-zero rule, cancelling is simply *doing what the artist's path says*, not us choosing a semantics on their behalf. The pinning tests come in **pairs** — one input, both rules, two answers — in `algorithms::boolean_normalize` (Rust) and `BooleanNormalizeDegenerateTests` (Swift), each with its expectation derived from first principles rather than read back from the implementation, because these are shared limitations that a differential referee is blind to. The corpus (`test_fixtures/algorithms/boolean_normalize.json`, `boolean.json`) gates only that the two ports agree; the vectors declare their rule with an optional `fill_rule` / `a_fill_rule` / `b_fill_rule` field, absent meaning even-odd.

**Superseded reading, for the record.** Before the ruling the tree contradicted itself: `algorithms/boolean` declared even-odd with orientation outside the contract, while `algorithms/boolean_normalize` documented its input as non-zero winding. The interim resolution was a hybrid — non-zero *within* a ring, even-odd *between* rings — chosen because a naive set-wide non-zero reading deletes the inner ring of every donut drawn the natural way (two co-oriented rings, winding 2 in the middle) and turned seven unit tests red. That hybrid is now gone: the same donut is a hole when the document says `evenodd` and a solid when it says `nonzero`, and both are pinned.

### Multi-ring results: FIXED 2026-07-26

**Status: closed.** The divergence and the user-facing bug below are fixed in both ports, the pinch-split has landed, and the `exclude_overlapping_squares` `ring_count` holdout is retired — that oracle key is live. This subsection is kept as the record of what was wrong and why the fix had the shape it did; the past tense marks what no longer holds.

**What is true now.** Both ports emit a **single even-odd `Path`** for a multi-ring boolean result and keep the single-ring case a `Polygon`. Swift's `Path` carries `fillRule`, imports and exports it in SVG, propagates it through every copy helper, and the canvas fills with `CGPathFillRule.evenOdd` when the path declares it — so the hole survives in the model *and* on screen. The rule stamped is `boolResultFillRule` / `RESULT_FILL_RULE`, clause 4 of the carried-rule law. The action goldens now carry `fill_rule` whenever it is not the `nonzero` default, so a golden can no longer be blind to a port filling a hole.

The pinch-split is `boolean.rs`'s `split_pinched_rings` / `Boolean.swift`'s `splitPinchedRings`, a post-pass on `connect_edges` output: it cuts any ring that visits a vertex twice at the repeat, which is region-preserving by construction (no vertex invented or moved, and the two loops' signed areas sum to the original's). `exclude` of the two corner-overlapping squares now yields the derived-correct 75 + 75 over two simple rings, and `boolean_exclude_overlapping_rects_expected.json` was regenerated **once**, after both ports agreed byte for byte.

**The original diagnosis, for the record.**

A boolean result is often multi-ring: EXCLUDE of two overlapping rectangles is one outer ring plus an inner ring cutting out the overlap, and SUBTRACT of an inner shape is a donut. The two active ports materialise that differently:

- **Rust** (`Controller::apply_destructive_boolean`) emits a single `PathElem` carrying every ring as a subpath, with `fill_rule: FillRule::EvenOdd`, so the renderer honours the boolean semantics.
- **Swift** (`applyDestructiveBoolean`) emits **N independent `Polygon` elements**, one per ring. Each fills its own area on its own, and Swift's `Path` element has no `fillRule` field at all — the concept does not exist anywhere in the Swift sources.

The consequence was not cosmetic: **any boolean result with a hole had its hole filled in Swift.** The inner ring became an ordinary filled polygon painted over the region it was supposed to remove. Rust drew the donut; Swift drew the disc.

That also blocked a separate, already-derived correctness fix. The `exclude_overlapping_squares` corpus vector pins `ring_count: 2` — the derived-correct answer, two L-shapes touching only at two isolated points — while both ports emitted one self-touching twelve-vertex ring, because `connect_edges` cannot tell which of two touching regions it is on at a pinch vertex. Landing the split first would have changed a one-ring result into a two-ring result, which each port then materialised by a *different* rule — so it would have broken the `boolean_exclude_overlapping_rects` action golden differently in Rust and in Swift. Hence the ordering below, which is the order the fix was actually landed in:

1. Add `fill_rule` to Swift's `Path` element, mirroring Rust's `FillRule` (`nonzero` default, `evenodd`), additive so existing documents stay valid — **done**, including SVG import/export and propagation through every copy helper.
2. Change `applyDestructiveBoolean` to emit **one even-odd `Path`** for multi-ring results, matching Rust ring for ring and keeping the single-ring case a `Polygon` as both ports already do — **done**, and the canvas honours the rule, without which the model would be right and the screen still wrong.
3. Land the pinch-split in both ports together — **done** (`split_pinched_rings` / `splitPinchedRings`).
4. Regenerate `test_fixtures/actions/boolean_exclude_overlapping_rects_expected.json` **once**, after both ports agree — **done**; the two ports' canonical JSON was byte-identical before the golden was touched.
5. Delete the `_known_gap` / `_known_gap_keys` holdout on `exclude_overlapping_squares` in `test_fixtures/algorithms/boolean.json`, putting its `ring_count` back under the golden oracle — **done**; the cross-language algorithm gate reports no known-gap line and one more passing key.

### Does a path EDIT preserve the declared rule? RULED 2026-07-26 — yes, and more than the rule

**Status: RULED and FIXED (phase 1).** JYH's ruling went wider than the question asked, and it is stated as a **law, not an enumeration**:

> "The ship is the same ship even when planks are removed, replaced, the anchor is heaved — that's what an artist will expect."

**A PATH EDIT PRESERVES EVERYTHING EXCEPT `d`.** Deliberately not a field list: the ruling's own first draft listed 14 fields, and the verify lens proved the omission bites — `transform` was missing, and dropping `transform` RELOCATES the artwork. Phrasing it as "everything except the geometry" is what stops it rotting as fields are added. **Erase does not remove identity** — it is still the same object.

**What landed.** The five Rust sites are now `PathElem { d: new_cmds, ..pe.clone() }`, which satisfies the law by construction and cannot drop the next field added; it is also less code than the field lists it replaced. Swift has no struct-update syntax, so `pathWithCommands` forwards all 18 properties by hand, pinned by a `Mirror`-driven battery (`Tests/Tools/PathEditTheseusTests.swift`) that compares every reflected property except `d` — so a property added to `Path` later is checked without editing the test. Both ports' erase now branches on the surviving-fragment count.

**What phase 2 owed, for the SEVERING erase only — BOTH NOW LANDED.** Fresh deterministic cross-port ids per fragment (landed with the cardinality round), and a linear-gradient stop remap (landed 2026-07-27, S-2; see `PATH_ERASER_TOOL.md` and the `gradient_remap` corpus family). The paragraph below is the original statement of the debt, kept for the record. The severing arm did **not** propagate `id`: nothing on that path can mint one (`Controller::assign_id` / `Controller.assignId` never mint — the initiator carries the id in the operation payload — and `dedupe_element_ids` / `dedupeElementIds` only CLEAR duplicates, and only in document readers), so copying it would leave N live elements sharing an id and break the unique-id invariant of `REFERENCE_GRAPH.md` §2.5. The gradient half: a gradient carries no position — linear is angle + stops resolved against the element's OWN bbox centre and half-diagonal — so each fragment re-fits the whole ramp instead of showing its slice; the fix is an affine remap of stop locations with clipping and interpolated endpoint colours. Radial cannot be preserved without a model change, and JYH has accepted the recentre.

The record of the divergence as it stood before the ruling is kept below, because the *how it was missed* paragraph is the transferable part.

**The divergence, as it stood.** The two ports disagreed about what a path *edit* does to the path's `fill_rule`, and they disagreed in the direction that undoes the very corruption this feature was built to stop.

- **Swift preserved it.** All eight of `YamlToolEffects.swift`'s path-`d` rewrites go through one helper, `pathWithCommands`, which forwarded `pe.fillRule`.
- **Rust discarded it.** Every one of the five Rust path-edit rebuilds wrote `fill_rule: FillRule::NonZero` as a literal.

On identical input — a two-ring even-odd path — `delete_anchor_near` therefore returned **even-odd in Swift and non-zero in Rust**. So deleting one anchor from an even-odd boolean result **flooded its holes in Rust and kept them in Swift**: the same artwork corruption the fill-rule work existed to prevent, asymmetric and pointing the other way.

**The sites.** Swift: 8 calls to `pathWithCommands`, in six functions — `pathDeleteAnchorNear`, `pathInsertAnchorOnSegmentNear`, `pathEraseAtRect`, `pathCommitAnchorEdit` (three arms), `paintbrushEditCommit`, `pathSmoothAtCursor`. All 8 now pass an explicit `identity:` argument, which has **no default**, so the compiler enumerates them if the one-element / split distinction ever changes. Rust: the 5 path-edit rebuilds are `path_erase_at_rect`, `path_paintbrush_edit_commit`, `path_smooth_at_cursor`, `path_insert_anchor_on_segment_near`, `path_delete_anchor_near`. (Line numbers are omitted on purpose — they moved twice while this section was being written. `grep -n 'pathWithCommands(' JasSwift/Sources/Tools/YamlToolEffects.swift` reports 9 lines: 1 declaration + 8 calls. After the fix, `grep -c 'FillRule::NonZero' jas_dioxus/src/interpreter/effects.rs` reports 7 remaining literals: 4 `#[cfg(test)]` fixtures, 2 fresh `add_element` constructions from a point buffer with no source path, and the blob-brush merge. **That last classification was WRONG and the verify lens refuted it by DRIVING, not reading.** With exactly ONE matching source path, `doc.blob_brush.commit_painting` is the one-element case — one existing `PathElem` in, one out with a rewritten `d` — and it drops 7 fields including `transform`, so it RELOCATES the artwork by the source's translation. Swift's `blobBrushCommitPainting` resets identically, so this is a SHARED gap, not a parity break. **Aggravated by this very fix:** erase now preserves `tool_origin`, where `CommonProps::default()` used to clear it — so erased fragments are now merge candidates they previously were not, widening the reach of the blob-merge gap. **BANKED as an open Theseus site**: its N==1 arm is unambiguous under the law; its N>1 arm is a genuine design question (which of several merged sources is the ship?) and needs a ruling.)

**Neither side was pinned; both are now.** The pre-fix probes, for the record: rewriting Swift's `pathWithCommands` to `fillRule: .nonzero` and running `swift test` gave **2428 tests, all pass**; rewriting Rust's `path_delete_anchor_near` to `fill_rule: pe.fill_rule` and running `cargo test --lib` gave **2552 pass, 0 fail**. Both behaviours were unasserted. The Ship of Theseus batteries (7 Rust tests in `effects.rs`'s `mod tests`, 8 Swift tests in `PathEditTheseusTests.swift`) close that: each was observed failing before the fix, and each has a mutation proof.

**The question, as it was posed: should a path EDIT preserve the declared fill rule?** Preserving is the defensible reading — the artist did not ask to change the rule by dragging an anchor, and the rule is a property of the path, not of the last operation applied to it. JYH ruled that way and then widened it past the fill rule to every non-`d` field.

**One thing worth recording about how this was missed.** An earlier round of this feature removed the default from Swift's `Path.init` so that the compiler, not a reviewer, would enumerate the rebuild sites. That trick was **one-sided in effect only, not in principle**: Rust's struct literals already require every field, so Rust's compiler enumerated these five sites too — and at each one a human answered the question by typing `NonZero`. A compiler can force the question to be asked. It cannot notice that the answer was wrong.

### The same helper dropped a whole family of fields — FIXED with the ruling above

**Status: FIXED 2026-07-26** in `pathWithCommands` and in Rust's `path_erase_at_rect`. Two RELATED arms of the same shape are still open, named below.

`pathWithCommands` forwarded 12 of `Path`'s 18 stored properties. The 6 it dropped were **`widthPoints`, `strokeBrush`, `strokeBrushOverrides`, `toolOrigin`, `name`, `id`** — so on **every** anchor edit, insert, erase, smooth or paintbrush commit, a variable-width or brushed path lost its stroke profile *and* its identity. It now forwards all 18 (with `id` withheld in the severing-erase arm only, per the phase-2 deferral above). (Count method: `Path` has 18 stored properties by `grep -c 'public let'` over the struct body in `Element.swift`; 18 − 12 = 6, and all 6 were named individually by the Mirror battery's observed pre-fix failures.)

**And Rust was not uniformly the generous port.** `path_erase_at_rect` rebuilt with `common: CommonProps::default()`, discarding all 9 of `CommonProps`' fields — `opacity`, `mode`, `transform`, `locked`, `visibility`, `mask`, `tool_origin`, `name`, `id` — where Swift's `pathEraseAtRect` forwarded `opacity`, `transform`, `locked`, `visibility`, `blendMode` and `mask`. So Swift lost the stroke profile and identity on an edit while Rust lost the appearance and identity on an erase. Both directions were fixed; neither port was picked as the winner. Rust also dropped `fill_gradient` / `stroke_gradient` at the smooth, paintbrush-edit and erase sites; the struct-update conversion closes those too.

**Still OPEN — two related arms in `Element.swift`, not in the path-edit family.** Disclosed here so the class stays visibly open on live paths: `withMask` drops 7 in its `.path` arm (the 6 above minus `widthPoints`, plus `fillGradient` and `strokeGradient`), and `withWidthPoints` drops 9 (those 7 plus `blendMode` and `mask`). Both re-verified in the tree at this commit by reading the two `.path` arms. The identical shape in `Controller.movePathHandle` **was** fixed, in "FILLRULE: a handle drag stops rewriting the rest of the path", and its pin (`Tests/Document/MovePathHandleFieldsTests.swift`) is a `Mirror`-driven walk that would work verbatim for these two — as would the one in `Tests/Tools/PathEditTheseusTests.swift`.

### Swift's `Polygon` has no `toolOrigin` field at all — and SVG import reaches it

**Status: BANKED 2026-07-26.** Recorded first as "a model-shape asymmetry, likely unreachable"; that was wrong, and the correction is the interesting part.

Rust's `PolygonElem` carries `common: CommonProps`, which includes `tool_origin`; Swift's `Polygon` (`Element.swift:2926`) has no such property, so a `tool_origin` on a Polygon is lossy in Swift at **every** boundary — SVG, binary codec, every copy helper — not at one site.

The tempting dismissal is that nothing writes it: the only in-app writer of `tool_origin` is the blob brush (four sites, all writing the literal `"blob_brush"`), and it stamps Paths. **But SVG import writes it too, and it writes it generically.** Rust's `parse_element` (`svg.rs:1569`) computes `let common = parse_common(node)` **once, before matching on the tag**, and `parse_common` (`:1283`) reads `jas:tool-origin` unconditionally — so the `"polygon"` arm (`:1628`) hands that `common` straight into `PolygonElem`. Swift's `parseElement` reads `jas:tool-origin` only inside its `"path"` arm (`Svg.swift:1349`); its `"polygon"` arm (`:1340`) has nowhere to put it.

So: **open an SVG containing `<polygon jas:tool-origin="…">` in both ports and Rust preserves the tag while Swift silently drops it.** That is a live prime-directive divergence on import, reachable by a hand-authored or third-party file, not a latent model asymmetry. It is banked rather than fixed only because this round's charter is closed; it is the smallest of the three stones and the fix is additive (a `toolOrigin` on Swift's `Polygon`, plus the import arm and the copy helpers).

### The collapse default: Swift contradicted `state.yaml`, and the corpus could not see it — FIXED 2026-07-26

`workspace/state.yaml` declares `boolean_remove_redundant_points` default `false` (restated under "Boolean Options dialog" below). Rust's `BooleanOptions::default()` said `false`; Swift's `BooleanOptions.init` defaulted it to `true`. Three routes reach the collapse pass, and all three took that initializer default: `OpApply`'s `boolean_union` arm and `Controller.applyDestructiveBoolean`'s default argument name no options at all, and the panel route (`Effects.swift`'s `booleanOptionsFromStore`) falls back to the same initializer default for any key the store has no value for — which is every `state.boolean_*` key until the Boolean Options dialog is confirmed, since Swift's `StateStore` starts empty and its schema does not carry declared defaults. Rust's panel route reads `BooleanPanelState::default()`, whose `remove_redundant_points` is `false` from the start. So the pass ran in Swift and not in Rust. The spec is the ruling; Swift's initializer now says `false`.

The corpus reported green throughout, and the reason is worth keeping: the existing `boolean_ops.json` setup overlaps its two rects corner-to-corner, and that union ring has no collinear vertex — so the collapse pass was a no-op *in that fixture* and the flag's value was unobservable. `test_fixtures/operations/boolean_collapse_default.json` overlaps them in x with the same y-extent instead, which makes the sweep insert a vertex on the top and bottom edges at each operand's vertical edge; the golden pins 8 points where the collapse pass would leave 4. Flipping either port's default now fails it.

### The boolean rebuild and the non-paint properties — paint FIXED, the rest BANKED 2026-07-26

Same omission class as the Ship of Theseus sites above, at the boolean's output rebuild. Rust rebuilds with `common.clone()` from the paint source; Swift restates the fields by hand.

**Fixed, because §Operand and paint rules decides it:** that section names four properties as the paint the result carries — "fill, stroke, opacity, blend mode". Swift passed fill and stroke, wrote `opacity: 1.0` as a literal, and left `blendMode` at its default, so a half-transparent multiply operand came out of UNION opaque and normal. Both Swift arms (single-ring Polygon, multi-ring Path) now pass all four. Rust already did — and nothing asserted it, so both ports gained the same three cases (UNION and EXCLUDE carry the frontmost operand's opacity/blend; a SUBTRACT_FRONT survivor keeps its own). `opacity` is additionally pinned cross-language by the fixture above; blend mode is not in the operations corpus JSON, which is why that pair is per-port.

**Banked, then RULED — and half-landed. Read the two halves separately.**

The banked question was: `locked` (Swift writes `false`, Rust clones the source's) and `name` / `id` / `toolOrigin` / `mask` (Swift drops, Rust clones — and in Swift's single-ring arm `toolOrigin` has nowhere to go at all, per the `Polygon` section above). The paint rule does not reach these, and the cardinality law cuts both ways within one panel: UNION / INTERSECTION / EXCLUDE are N->1 and DIVIDE is 1->N, where identity dies, while a SUBTRACT_FRONT / SUBTRACT_BACK / CROP survivor and a TRIM operand are 1->1, where it lives — and MERGE is per-group, exactly the blob brush's two arms. Rust's uniform `common.clone()` therefore carried a *frontmost* operand's `id` through a UNION, which is the direction "the largest — or the lowest-z — source keeps the id" was explicitly rejected in.

`transcripts/EDIT_SEMANTICS_FREEZE.md` (RATIFIED by JYH 2026-07-27) answers it without a decision per op, because cardinality plus "speaks to" classify them — see its §3.6 table. Landed **in Rust only** on 2026-07-27 (`Controller::apply_destructive_boolean`, UNION / INTERSECTION / EXCLUDE arm): the product now carries the frontmost's four paint properties, a fresh minted `id` where an operand carried one, ASSERTING-SOURCES unanimity for `name`, and plain unanimity for `transform` / `locked` / `visibility` / `mask` / `toolOrigin`.

Landed **in Rust only**, in two waves on 2026-07-27, all in `Controller::apply_destructive_boolean_minting`:

- **UNION / INTERSECTION / EXCLUDE** (wave 1). N->1.
- **DIVIDE** (wave 2). The arm handed EVERY output region the designated operand's whole `common`, id included, so an operand covering two regions left two live elements wearing one id. The arrow is now counted per designated operand off the partition: an operand that yielded one region is 1->1 and keeps its identity (`path_erase_at_rect`'s own branch, and a NAMED DELTA from §3.6's flat "fresh mint" for the degenerate case); an operand the partition split mints a fresh id per fragment and copies appearance, `transform` and `name` to each.
- **MERGE** (wave 2). The rejected rule was written down here rather than disguised: `common_winner = trim_j.3.clone()` plus the comment "j is frontmost; its stroke/common wins". Now branched per merged group — a one-contributor group is 1->1 and preserves everything; a multi-contributor group is N->1 through the SAME `merged_common` helper the UNION arm uses, with only PAINT riding from the frontmost contributor.
- **TRIM** (wave 2, unchanged behaviour, newly pinned). Every operand is 1->1 and clones its own `common`.

Twenty-four batteries in `controller.rs`'s `preservation_law_tests` cover these, each with the §3.1 anti-vacuity guard and a geometry pairing.

**STILL OPEN, and now a live one-sided divergence:** JasSwift's `applyDestructiveBoolean` is unchanged — it drops `id` / `name` / `toolOrigin` / `mask` and writes `locked: false` on every arm, including the 1->1 SUBTRACT / CROP / TRIM survivors where §3.1 requires full preservation. Bringing Swift to the §3.6 table is the matching commit. No cross-language golden can see any of this: every boolean vector in the corpus runs on operands with no `id` and no other legislated attribute (recorded as coverage gap `identity-law-boolean-operands-id-less` in `scripts/corpus_manifest.json`). (`fillGradient` / `strokeGradient` are still dropped by both ports at this rebuild — the §3.6 amendment that adds them under T1's shadowing closure is not landed in either.) **Also still open in BOTH ports, and inside the same function: the LOSSY DEMOTION** (§3.5's "Boolean flatten, single-ring arm" row). The flatten step emits `Polygon` for a single-ring result and writes `width_points` empty / `stroke_brush` None / `stroke_brush_overrides` None on the multi-ring `Path`, so a 1->1 SUBTRACT / CROP / TRIM / unsplit-DIVIDE survivor that was a variable-width or brushed Path loses its stroke profile. **Driven 2026-07-27 in Rust:** a `subtract_front` survivor carrying one width point and `strokeBrush` "b1" comes out a `Polygon` — identity intact, profile gone. Per T1's representation term the survivor arms must emit the survivor's own kind, or Path as the superset; that changes the emitted element KIND and so must land in both ports at once.

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

## Open rulings and follow-ups

The index of what this document leaves unsettled. Each entry says where the detail lives; the detail is not duplicated here.

| Item | Status | Detail |
| --- | --- | --- |
| **Which fill rule reads a polygon set** | **RULED 2026-07-26** | [Fill rule: the polygon set carries it](#fill-rule-the-polygon-set-carries-it) — the set carries its source's declared rule; results declare even-odd. Inter-ring winding cancellation implemented in both ports as a consequence. |
| **Multi-ring results differ between the ports** | **FIXED 2026-07-26** | [Multi-ring results: FIXED 2026-07-26](#multi-ring-results-fixed-2026-07-26) — both ports emit one even-odd Path, Swift's canvas honours it, the pinch-split landed and the `ring_count` oracle holdout is retired. |
| **Does a path EDIT preserve the declared rule?** | **RULED 2026-07-26 — phase 1 FIXED** | [Does a path EDIT preserve the declared rule? RULED 2026-07-26](#does-a-path-edit-preserve-the-declared-rule-ruled-2026-07-26--yes-and-more-than-the-rule) — the Ship of Theseus law: a path edit preserves EVERYTHING except `d`, stated as a law rather than a field list. Rust's five sites are now `..pe.clone()`; Swift's one helper forwards all 18 properties. Phase 2's two debts on the SEVERING erase are both paid: fresh per-fragment ids, and the linear-gradient stop remap (2026-07-27). Radial still re-centres, as ruled. |
| **The field family at the same helper** | **FIXED 2026-07-26; two related arms still open** | [The same helper dropped a whole family of fields](#the-same-helper-dropped-a-whole-family-of-fields--fixed-with-the-ruling-above) — `pathWithCommands` (6 of 18, across 8 call sites) and Rust's `path_erase_at_rect` (all 9 `CommonProps` fields, the other direction) are fixed. `withMask` / `withWidthPoints` in `Element.swift` still drop 7 and 9 in their `.path` arms. |
| **The collapse default** | **FIXED 2026-07-26** | [The collapse default: Swift contradicted `state.yaml`](#the-collapse-default-swift-contradicted-stateyaml-and-the-corpus-could-not-see-it--fixed-2026-07-26) — Swift defaulted `remove_redundant_points` to true against the spec's false, and the corpus setup could not observe the difference. Fixed, and a fixture that discriminates it added. |
| **The boolean rebuild's non-paint properties** | **paint FIXED 2026-07-26; identity RULED + landed in Rust 2026-07-27; SWIFT OPEN** | [The boolean rebuild and the non-paint properties](#the-boolean-rebuild-and-the-non-paint-properties--paint-fixed-the-rest-banked-2026-07-26) — opacity and blend mode now carry in both ports per §Operand and paint rules. The per-op ruling the row asked for is `EDIT_SEMANTICS_FREEZE.md` §3.6, ratified 2026-07-27, and Rust's UNION / INTERSECTION / EXCLUDE, DIVIDE, TRIM and MERGE arms now implement it. JasSwift's `applyDestructiveBoolean` still drops `id` / `name` / `toolOrigin` / `mask` and writes `locked: false` on every arm — a live one-sided divergence, invisible to every cross-language gate (coverage gaps `identity-law-boolean-operands-id-less` and `preservation-op-vocabulary-only`). The lossy Polygon demotion of a 1->1 survivor is open in both ports. |
| **Swift `Polygon` has no `toolOrigin`** | **BANKED — reachable, smallest of the three** | [Swift's `Polygon` has no `toolOrigin` field at all — and SVG import reaches it](#swifts-polygon-has-no-toolorigin-field-at-all--and-svg-import-reaches-it) — Rust's `parse_common` reads `jas:tool-origin` before the tag match, so its `<polygon>` arm keeps the tag and Swift's drops it. Live import divergence; additive fix. |
| **OUTLINE operation** | Deferred, unblock trigger named | [Terminology](#terminology) — waits on the planar-graph / DCEL primitive for the Shape Builder tool. |
| **Trap operation** | Deferred, unblock trigger named | [Terminology](#terminology) — waits on a physical printing model (spot colors, separations, press output). |

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
