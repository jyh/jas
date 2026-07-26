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
- **Standard paint and placement properties** (`fill`, `stroke`, `opacity`, `blend_mode`, `transform`) live on the LiveElement wrapper. At creation these inherit from the frontmost child per the Operand and paint rules; afterward they are independently editable.
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

### Does a path EDIT preserve the declared rule? OPEN — needs a ruling

**Status: BANKED 2026-07-26, unfixed on purpose.** This is a behaviour question, not a defect with an obvious repair, and answering it one way changes five Rust call sites. It is written up here rather than fixed because the fourth round of this feature is the wrong place to decide semantics. Everything below was verified in the tree at this commit; each count states how it was taken.

**The divergence.** The two ports disagree about what a path *edit* does to the path's `fill_rule`, and they disagree in the direction that undoes the very corruption this feature was built to stop.

- **Swift preserves it.** All eight of `YamlToolEffects.swift`'s path-`d` rewrites go through one helper, `pathWithCommands` (`:1594`), which forwards `pe.fillRule`.
- **Rust discards it.** Every one of the five Rust path-edit rebuilds writes `fill_rule: FillRule::NonZero` as a literal.

On identical input — a two-ring even-odd path — `delete_anchor_near` therefore returns **even-odd in Swift and non-zero in Rust**. So deleting one anchor from an even-odd boolean result **floods its holes in Rust and keeps them in Swift**: the same artwork corruption the fill-rule work existed to prevent, now asymmetric and pointing the other way.

**The sites, counted mechanically.** Swift: `grep -o pathWithCommands JasSwift/Sources/Tools/YamlToolEffects.swift | wc -l` reports 9 occurrences; one is the declaration at `:1594`, so 8 are calls, in six functions — `pathDeleteAnchorNear` (`:1618`), `pathInsertAnchorOnSegmentNear` (`:1663`), `pathEraseAtRect` (`:1737`), `pathCommitAnchorEdit` (`:1911`, `:1918`, `:1927`), `paintbrushEditCommit` (`:2143`), `pathSmoothAtCursor` (`:2191`). Rust: `grep -c 'fill_rule' jas_dioxus/src/interpreter/effects.rs` reports 12 literal `FillRule::NonZero` writes; classified by reading each one, 4 are `#[cfg(test)]` fixtures (`:7269`, `:7546`, `:7601`, `:9759`), 2 are fresh `add_element` constructions from a point buffer with no source path (`:1083`, `:1217`), 1 is the blob-brush merge (`:4954`, which deletes N elements and inserts one new unified path with a fresh `CommonProps` — a construction, not a `d` rewrite, and the only borderline case), and the remaining **5 are rewrites of an existing `PathElem`**: `path_erase_at_rect` (`:4436`), `path_paintbrush_edit_commit` (`:4681`), `path_smooth_at_cursor` (`:5469`), `path_insert_anchor_on_segment_near` (`:5587`), `path_delete_anchor_near` (`:5620`). 4 + 2 + 1 + 5 = 12.

**Neither side is pinned.** Verified by probe, both reverted afterwards:

- Rewriting Swift's `pathWithCommands` to `fillRule: .nonzero` and running `swift test`: **2428 tests, all pass.** Swift's preservation is behaviour no test asserts.
- Rewriting Rust's `:5620` to `fill_rule: pe.fill_rule` and running `cargo test --lib`: **2552 pass, 0 fail.** Rust's discarding is equally unpinned.

**The ruling needed: should a path EDIT preserve the declared fill rule?** Preserving is the defensible reading — the artist did not ask to change the rule by dragging an anchor, and the rule is a property of the path, not of the last operation applied to it. But it *is* a behaviour choice, and it is not free: ruling "preserve" means changing five Rust sites, and each is a place where someone might argue the edit produces a genuinely new path.

**One thing worth recording about how this was missed.** An earlier round of this feature removed the default from Swift's `Path.init` so that the compiler, not a reviewer, would enumerate the rebuild sites. That trick was **one-sided in effect only, not in principle**: Rust's struct literals already require every field, so Rust's compiler enumerated these five sites too — and at each one a human answered the question by typing `NonZero`. A compiler can force the question to be asked. It cannot notice that the answer was wrong.

### The same helper drops a whole family of fields — larger than the fill-rule half

**Status: BANKED 2026-07-26.** Its own stone; the fill-rule question above is one field out of this set.

`pathWithCommands` forwards 12 of `Path`'s 18 stored properties. The 6 it drops are **`widthPoints`, `strokeBrush`, `strokeBrushOverrides`, `toolOrigin`, `name`, `id`** — so on **every** anchor edit, insert, erase, smooth or paintbrush commit, a variable-width or brushed path loses its stroke profile *and* its identity. Rust's twins forward all six. (Counts: `Path` has 18 stored properties by `grep -c 'public let'` over the struct body in `Element.swift`; 18 − 12 = 6.)

Two related arms of the same shape, disclosed here so the class stays visibly open on live paths: `withMask` (`Element.swift:2371`) drops 7 in its `.path` arm (the 6 above minus `widthPoints`, plus `fillGradient` and `strokeGradient`), and `withWidthPoints` (`:2424`) drops 9 (those 7 plus `blendMode` and `mask`). The identical shape in `Controller.movePathHandle` **was** fixed, in "FILLRULE: a handle drag stops rewriting the rest of the path", and its pin (`Tests/Document/MovePathHandleFieldsTests.swift`) is a `Mirror`-driven walk that would work verbatim for these three.

**And Rust is not uniformly the generous port.** `path_erase_at_rect` (`effects.rs:4436`) rebuilds with `common: CommonProps::default()`, discarding all 9 of `CommonProps`' fields — `opacity`, `mode`, `transform`, `locked`, `visibility`, `mask`, `tool_origin`, `name`, `id` — where Swift's `pathEraseAtRect` forwards `opacity`, `transform`, `locked`, `visibility`, `blendMode` and `mask`. So Swift loses the stroke profile and identity on an edit while Rust loses the appearance and identity on an erase. Whoever takes this stone should fix both directions, not pick a winner.

### Swift's `Polygon` has no `toolOrigin` field at all

**Status: BANKED 2026-07-26.** A model-shape asymmetry rather than a behaviour bug, and likely unreachable today.

Rust's `PolygonElem` carries `common: CommonProps`, which includes `tool_origin`; Swift's `Polygon` (`Element.swift:2927`) has no such property, so a `tool_origin` on a Polygon is lossy in Swift at **every** boundary — SVG, binary codec, every copy helper — not at one site. It is probably unreachable in practice: the only writer of `tool_origin` is the blob brush, which stamps it onto Paths. That "probably" is exactly what a ruling should replace, because a boolean result whose single ring materialises as a `Polygon` is one plausible future writer.

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
| **Does a path EDIT preserve the declared rule?** | **OPEN — needs a ruling** | [Does a path EDIT preserve the declared rule? OPEN — needs a ruling](#does-a-path-edit-preserve-the-declared-rule-open--needs-a-ruling) — Swift preserves, Rust writes `NonZero` at all five rebuild sites, so an anchor edit floods an even-odd hole in Rust and not in Swift. Unpinned in both ports (probe-verified). Ruling "preserve" costs five Rust sites. |
| **The field family at the same helper** | **BANKED — its own stone** | [The same helper drops a whole family of fields](#the-same-helper-drops-a-whole-family-of-fields--larger-than-the-fill-rule-half) — `pathWithCommands` drops 6 of 18 fields across 8 call sites; `withMask` / `withWidthPoints` drop 7 and 9. Rust's `path_erase_at_rect` drops all 9 `CommonProps` fields in the other direction. |
| **Swift `Polygon` has no `toolOrigin`** | **BANKED — likely unreachable today** | [Swift's `Polygon` has no `toolOrigin` field at all](#swifts-polygon-has-no-toolorigin-field-at-all) — model-shape asymmetry against Rust's `PolygonElem.common`; lossy at every boundary, but only the blob brush writes `tool_origin` and it writes onto Paths. |
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
