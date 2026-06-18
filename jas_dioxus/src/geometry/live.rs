//! LiveElement framework: shared infrastructure for non-destructive
//! element kinds that store source inputs and evaluate them on demand.
//!
//! CompoundShape is the first conformer (non-destructive boolean over
//! an operand tree). Future Live Effects (drop shadow, blend, ...) add
//! a variant to `LiveVariant` and implement `LiveElement`; the top-
//! level `Element` enum only ever grows one `Live(LiveVariant)` arm.
//!
//! See `transcripts/BOOLEAN.md` § Live element framework.

// Module-wide allow: LiveElement framework infrastructure. Most of
// the trait surface is reserved for future Live Effects (drop shadow,
// blend, etc.) per project_live_element_framework; CompoundShape is
// the only current conformer and wires only a subset.
#![allow(dead_code)]

use std::rc::Rc;

use crate::algorithms::boolean::{
    self, PolygonSet,
};

use super::element::{translate_element, Bounds, CommonProps, Element, Fill, Stroke};
// RECORDED_ELEMENTS.md: the recipe is a normalized op-segment from the journal.
use crate::document::op_log::PrimitiveOp;

/// Default geometric tolerance in points. Matches the `Precision`
/// default in the Boolean Options dialog (BOOLEAN.md § Boolean
/// Options dialog). Equals 0.01 mm.
pub(crate) const DEFAULT_PRECISION: f64 = 0.0283;

// ---------------------------------------------------------------------------
// Reference resolution seam (REFERENCE_GRAPH.md §2.1)
// ---------------------------------------------------------------------------

/// A by-id reference to another element's `common.id`. Stable across
/// insert/delete (unlike a tree path); resolved through an `ElementResolver`,
/// never stored as an `Rc`. `Ord` is load-bearing: deterministic recompute
/// order derives from sorted ids, never hashmap iteration order.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord,
         serde::Serialize, serde::Deserialize)]
#[serde(transparent)]
pub struct ElementRef(pub String);

/// Resolves a stable element id to the element it currently names. Lets the
/// geometry layer evaluate by-id references without depending on
/// Model/Document. Phase 1 backs this with a rebuild-on-demand resolver; the
/// persistent-incremental index is Phase 4 (REFERENCE_GRAPH.md §2.4).
pub trait ElementResolver {
    fn resolve(&self, id: &ElementRef) -> Option<Rc<Element>>;
}

/// A resolver that resolves nothing. Used on the resolver-unaware call paths
/// (and wherever no live references are present) so existing geometry behavior
/// is unchanged: a reference resolved through it is treated as dangling.
pub struct NullResolver;

impl ElementResolver for NullResolver {
    fn resolve(&self, _id: &ElementRef) -> Option<Rc<Element>> {
        None
    }
}

/// The cycle-guard set threaded through evaluation. Carried as an explicit
/// parameter (never instance/thread state) so all five apps break reference
/// cycles identically (REFERENCE_GRAPH.md §3).
pub(crate) type VisitSet = std::collections::BTreeSet<ElementRef>;

// ---------------------------------------------------------------------------
// Reference-geometry recompute cache (REFERENCE_GRAPH.md Phase 4c, first
// increment). RUST-ONLY perf cache — NO behavior change. Equivalence with the
// other four apps is pinned on resolve()/eval RESULTS, which this never alters
// (gated by a debug-assert on every hit). See also the P4b index==rebuild gate
// in `model.rs`.
// ---------------------------------------------------------------------------
//
// What is cached: the RESOLVED TARGET's UNTRANSFORMED geometry —
// `element_to_polygon_set_with(resolved_target, precision, ..)`. This is shared
// across every reference that points at the same target, so the key is the
// TARGET (its id + the precision it was tessellated at), never the reference.
// The per-reference instance `transform` is applied AFTER the cached geometry,
// in `ReferenceElem::evaluate_with`, so it is not part of the cached value.
//
// Why pure-geometry-only (the crux): a target T that is a Group containing a
// Reference to X has geometry that changes when X is edited even though T's
// `Rc::as_ptr` is unchanged (T points to X by id, not by embedding). A
// `(target_id, Rc::as_ptr)` cache on T would therefore be STALE. By caching
// ONLY targets whose owned subtree contains NO Reference (`subtree_has_reference`
// is false), the geometry is a pure function of the target's `Rc` value, so
// `Rc::as_ptr` is a complete invalidation signal and that hazard is
// structurally excluded. Ref-containing targets fall through to today's exact
// uncached eval (recorded as `HasRefs` so a repeat lookup skips the purity walk
// but never serves cached geometry).
//
// Precision in the key: render makes two passes that may use different
// precision (the fill pass uses the Boolean-panel precision; the
// selection-trace pass uses `DEFAULT_PRECISION`). A coarse vs. fine
// tessellation are DIFFERENT geometry, so precision is part of the key
// (bit-encoded via `f64::to_bits`) — a coarse entry never serves a fine
// request and vice versa.
//
// Lifetime + invalidation: the cache is a thread-local that PERSISTS across
// paints, so repaints between edits (pan / zoom / hover, plus render's two
// passes) reuse it. It is generation-epoched off `model.generation`, which is
// bumped on every mutation / undo / redo: `set_recompute_cache_generation` (the
// paint entry, called from `render()`) clears all entries whenever the
// generation changes. Coarse but trivially correct — any edit drops the whole
// cache — while keeping the win across no-edit repaints. (A future refinement
// is a Model-companion cache paired with the snapshot and carried through
// undo/redo in O(1), mirroring the P4b id-index pairing; this first increment
// keeps the simpler thread-local-persistent form, relying on the per-hit gate
// for correctness.)

/// One cache slot keyed by `(target_id, precision_bits)`. `Pure` holds the
/// target's untransformed geometry, valid while `ptr` still matches the
/// resolved target's `Rc::as_ptr` (a pure-geometry target's geometry is a pure
/// function of its `Rc`). `HasRefs` records that the target's subtree contains a
/// nested reference, so its geometry is NOT cacheable; the entry exists only to
/// short-circuit the purity walk on a repeat lookup — it never serves geometry.
enum CacheEntry {
    Pure { ptr: usize, geom: PolygonSet },
    HasRefs { ptr: usize },
}

/// The thread-local recompute cache, epoched by `generation`. Entries are
/// cleared whenever `generation` changes (any edit / undo / redo).
struct RecomputeCache {
    generation: u64,
    entries: std::collections::HashMap<(String, u64), CacheEntry>,
}

thread_local! {
    static RECOMPUTE_CACHE: std::cell::RefCell<RecomputeCache> =
        std::cell::RefCell::new(RecomputeCache {
            generation: 0,
            entries: std::collections::HashMap::new(),
        });
}

/// Generation-epoch the recompute cache: if `generation` differs from the
/// cache's current epoch, CLEAR every entry and adopt the new epoch. Called at
/// the paint entry (`render()`) with `model.generation()`. Because the
/// generation is bumped on every mutation / undo / redo, this drops the cache on
/// any edit while preserving it across no-edit repaints.
pub fn set_recompute_cache_generation(generation: u64) {
    RECOMPUTE_CACHE.with(|c| {
        let mut cache = c.borrow_mut();
        if cache.generation != generation {
            cache.entries.clear();
            cache.generation = generation;
        }
    });
}

/// Observable cache state for a `(target_id, precision)` slot, for tests only:
/// `Pure` (geometry cached), `HasRefs` (recorded uncacheable), or absent (no
/// entry). Lets the focused Phase-4c tests assert WHAT was cached, beyond just
/// the eval result.
#[cfg(test)]
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum CacheState { Pure, HasRefs }

/// Test-only: report the cache state for `(target_id, precision)`.
#[cfg(test)]
pub(crate) fn recompute_cache_state_for_test(target_id: &str, precision: f64) -> Option<CacheState> {
    RECOMPUTE_CACHE.with(|c| {
        c.borrow().entries.get(&(target_id.to_string(), precision.to_bits())).map(|e| match e {
            CacheEntry::Pure { .. } => CacheState::Pure,
            CacheEntry::HasRefs { .. } => CacheState::HasRefs,
        })
    })
}

/// Test-only: drop all entries and reset the epoch to 0, so each focused test
/// starts from an empty cache regardless of prior tests on the same thread.
#[cfg(test)]
pub(crate) fn clear_recompute_cache_for_test() {
    RECOMPUTE_CACHE.with(|c| {
        let mut cache = c.borrow_mut();
        cache.entries.clear();
        cache.generation = 0;
    });
}

/// True iff `elem`'s OWNED subtree contains a `Reference` anywhere — the purity
/// test that decides whether a target's geometry may be cached. A cheap walk:
/// recurse Group / Layer children and CompoundShape operands (every
/// containment edge `element_to_polygon_set_with` itself descends), and report
/// a hit on any `Element::Live(LiveVariant::Reference(..))`. A reference reached
/// by-id is NOT part of the owned subtree (it is a `dependencies()` edge), so it
/// is the very thing this detects at its own node, not something it follows.
fn subtree_has_reference(elem: &Rc<Element>) -> bool {
    match elem.as_ref() {
        Element::Live(LiveVariant::Reference(_)) => true,
        Element::Live(LiveVariant::CompoundShape(cs)) => {
            cs.operands.iter().any(subtree_has_reference)
        }
        Element::Group(g) => g.children.iter().any(subtree_has_reference),
        Element::Layer(l) => l.children.iter().any(subtree_has_reference),
        // Leaf geometry kinds own no element subtree.
        _ => false,
    }
}

/// Obtain the resolved target's UNTRANSFORMED geometry, via the recompute
/// cache. Caches only pure-geometry targets (no nested reference); ref-containing
/// targets are evaluated fresh every time (recorded as `HasRefs`). The
/// per-reference instance transform is applied by the caller AFTER this returns.
///
/// Correctness gate: on every `Pure` hit, `debug_assert!(cached == fresh)`
/// (mirroring the P4b index==rebuild gate). Combined with the per-paint
/// generation epoch and the `Rc::as_ptr` check, this is the proof the cache
/// never diverges from a fresh eval.
fn cached_target_geometry(
    target_id: &str,
    target: &Rc<Element>,
    precision: f64,
    resolver: &dyn ElementResolver,
    visiting: &mut VisitSet,
) -> PolygonSet {
    let tptr = Rc::as_ptr(target) as usize;
    let key = (target_id.to_string(), precision.to_bits());

    // Fast path: a live entry whose ptr still matches.
    enum Hit { Reuse(PolygonSet), FreshUncached, Miss }
    let hit = RECOMPUTE_CACHE.with(|c| {
        let cache = c.borrow();
        match cache.entries.get(&key) {
            Some(CacheEntry::Pure { ptr, geom }) if *ptr == tptr => Hit::Reuse(geom.clone()),
            Some(CacheEntry::HasRefs { ptr }) if *ptr == tptr => Hit::FreshUncached,
            _ => Hit::Miss,
        }
    });

    match hit {
        Hit::Reuse(geom) => {
            // GATE: the cached geometry must equal a fresh eval. Mirrors the
            // P4b model.rs index==rebuild debug-assert.
            debug_assert!(
                {
                    let mut fresh_visit = VisitSet::new();
                    let fresh = element_to_polygon_set_with(
                        target, precision, resolver, &mut fresh_visit);
                    geom == fresh
                },
                "reference geometry recompute cache diverged from fresh eval",
            );
            geom
        }
        Hit::FreshUncached => {
            // Target contains nested references — never cache its geometry.
            element_to_polygon_set_with(target, precision, resolver, visiting)
        }
        Hit::Miss => {
            // Cache miss or stale ptr: evaluate fresh, then record by purity.
            let fresh = element_to_polygon_set_with(target, precision, resolver, visiting);
            let entry = if subtree_has_reference(target) {
                CacheEntry::HasRefs { ptr: tptr }
            } else {
                CacheEntry::Pure { ptr: tptr, geom: fresh.clone() }
            };
            RECOMPUTE_CACHE.with(|c| { c.borrow_mut().entries.insert(key, entry); });
            fresh
        }
    }
}

// ---------------------------------------------------------------------------
// Trait
// ---------------------------------------------------------------------------

/// Shared behavior of every LiveKind's inner struct. Implemented by
/// each concrete kind (e.g. `CompoundShape`) and also by `LiveVariant`
/// via delegation, so consumers holding a `LiveVariant` can invoke
/// these methods without an inner match.
pub trait LiveElement {
    /// Stable tag used in serialized form and in UI code to identify
    /// the live kind (e.g. `"compound_shape"`).
    fn kind(&self) -> &'static str;

    /// Version of the params schema for this kind. Incremented when a
    /// kind's serialized shape changes in a backwards-incompatible way.
    fn kind_schema_version(&self) -> u32;

    fn common(&self) -> &CommonProps;
    fn common_mut(&mut self) -> &mut CommonProps;
    fn fill(&self) -> Option<&Fill>;
    fn stroke(&self) -> Option<&Stroke>;

    /// Element-valued inputs. Per-feature conventions dictate the
    /// index ordering (compound shape: operands in z-order; blend:
    /// `[a, b, spine?]`; drop shadow: `[source]`).
    fn children(&self) -> &[Rc<Element>];
    /// Mutable access to element-valued inputs, or `None` for kinds with no
    /// owned children (e.g. a reference, whose input is a `dependencies()`
    /// edge, not an operand).
    fn children_mut(&mut self) -> Option<&mut Vec<Rc<Element>>>;

    /// Stable-id inputs reached by reference rather than containment, in
    /// deterministic order. Default empty: containment kinds (e.g.
    /// CompoundShape) own their inputs and expose them via `children()`. The
    /// reference-graph index reads this; it is the only by-id edge source.
    fn dependencies(&self) -> Vec<ElementRef> {
        Vec::new()
    }

    /// Stroke-inclusive bounding box of the evaluated output.
    fn bounds(&self) -> Bounds;

    /// Mark the kind's internal cache dirty. Default: no-op. Kinds
    /// that introduce a cache override this.
    fn invalidate(&mut self) {}

    /// Flatten to one-or-more static elements. The evaluated geometry
    /// becomes concrete Path / Polygon elements that no longer depend
    /// on the source tree. See BOOLEAN.md § Expand and Release
    /// semantics. `precision` governs any Bézier refit.
    fn expand(&self, precision: f64) -> Vec<Rc<Element>>;

    /// Restore the source elements as independent children. Each
    /// returned element retains its original paint; the LiveElement
    /// wrapper's own paint is discarded.
    fn release(&self) -> Vec<Rc<Element>>;
}

// ---------------------------------------------------------------------------
// CompoundShape — first LiveKind
// ---------------------------------------------------------------------------

/// Which boolean operation a compound shape evaluates to. Only the
/// four Shape Mode operations can be compound; the destructive-only
/// path operations never produce compound shapes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CompoundOperation {
    Union,
    SubtractFront,
    Intersection,
    Exclude,
}

/// A live, non-destructive boolean element: stores the operation and
/// its operand tree; evaluates to a polygon set on demand.
///
/// See `transcripts/BOOLEAN.md` § Compound shape data model.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct CompoundShape {
    pub operation: CompoundOperation,
    pub operands: Vec<Rc<Element>>,
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
}

impl CompoundShape {
    /// Evaluate the compound shape: flatten every operand into a
    /// polygon set, then apply the boolean operation across them.
    ///
    /// Pure function — no cache today. A cache lives in a future
    /// phase once render performance demands it.
    ///
    /// Convenience wrapper that resolves no references (a compound's operands
    /// are owned, not referenced); see `evaluate_with` for the resolver-aware
    /// form used when an operand subtree may contain by-id references.
    pub fn evaluate(&self, precision: f64) -> PolygonSet {
        let mut visiting = VisitSet::new();
        self.evaluate_with(precision, &NullResolver, &mut visiting)
    }

    /// Resolver-aware evaluation: flattens each operand (threading the
    /// resolver + cycle-guard set so a referenced operand resolves through
    /// `resolver`), then applies the boolean operation.
    pub fn evaluate_with(
        &self,
        precision: f64,
        resolver: &dyn ElementResolver,
        visiting: &mut VisitSet,
    ) -> PolygonSet {
        let operands: Vec<PolygonSet> = self.operands.iter()
            .map(|e| element_to_polygon_set_with(e, precision, resolver, visiting))
            .collect();
        apply_operation(self.operation, &operands)
    }
}

impl LiveElement for CompoundShape {
    fn kind(&self) -> &'static str { "compound_shape" }
    fn kind_schema_version(&self) -> u32 { 1 }
    fn common(&self) -> &CommonProps { &self.common }
    fn common_mut(&mut self) -> &mut CommonProps { &mut self.common }
    fn fill(&self) -> Option<&Fill> { self.fill.as_ref() }
    fn stroke(&self) -> Option<&Stroke> { self.stroke.as_ref() }
    fn children(&self) -> &[Rc<Element>] { &self.operands }
    fn children_mut(&mut self) -> Option<&mut Vec<Rc<Element>>> { Some(&mut self.operands) }

    fn bounds(&self) -> Bounds {
        bounds_of_polygon_set(&self.evaluate(DEFAULT_PRECISION))
    }

    /// Expand a compound shape to one `Polygon` element per ring of
    /// the evaluated geometry. Each produced element inherits the
    /// compound shape's own fill / stroke / common; the operand tree
    /// is dropped. Phase 2's polygon output is already a set of
    /// closed rings, so no Bézier refit is performed; refitting via
    /// `algorithms::fit_curve` lands in a later pass.
    fn expand(&self, precision: f64) -> Vec<Rc<Element>> {
        let ps = self.evaluate(precision);
        ps.into_iter()
            .filter(|ring| ring.len() >= 3)
            .map(|ring| {
                Rc::new(Element::Polygon(super::element::PolygonElem {
                    points: ring,
                    fill: self.fill.clone(),
                    stroke: self.stroke.clone(),
                    common: self.common.clone(),
                                    fill_gradient: None,
                    stroke_gradient: None,
                }))
            })
            .collect()
    }

    fn release(&self) -> Vec<Rc<Element>> {
        self.operands.clone()
    }
}

// ---------------------------------------------------------------------------
// ReferenceElem — by-id reference to another element (REFERENCE_GRAPH.md §1.1)
// ---------------------------------------------------------------------------

/// A live element that evaluates to another element's geometry, resolved by
/// stable id at evaluate time — the "instance of" primitive (mirrored eyes,
/// connector-follows-block). Its target is named by id, not embedded, so it
/// is a `dependencies()` edge rather than a `children()` operand.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ReferenceElem {
    /// Stable id of the referenced element.
    pub target: ElementRef,
    /// Optional instance transform applied to the resolved geometry. Declared
    /// now (Fork F2) but always `None` until Phase 3 wires it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transform: Option<crate::geometry::element::Transform>,
    /// Own paint; `None` inherits the resolved target's paint (Fork F3).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill: Option<Fill>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
}

impl ReferenceElem {
    /// Construct a reference to `target` with no overrides.
    pub fn new(target: ElementRef, common: CommonProps) -> Self {
        Self {
            target,
            transform: None,
            fill: None,
            stroke: None,
            common,
        }
    }

    /// Resolver-aware evaluation: resolve the target and return its geometry.
    /// A cycle (target already being visited) or a dangling reference
    /// (unresolved) yields an empty set — never a panic (REFERENCE_GRAPH.md §3).
    pub fn evaluate_with(
        &self,
        precision: f64,
        resolver: &dyn ElementResolver,
        visiting: &mut VisitSet,
    ) -> PolygonSet {
        if visiting.contains(&self.target) {
            return PolygonSet::new(); // cycle: break at the re-entry edge
        }
        match resolver.resolve(&self.target) {
            Some(target) => {
                visiting.insert(self.target.clone());
                // Phase 4c: obtain the resolved target's UNTRANSFORMED geometry
                // through the recompute cache (shared across all references to
                // this target; cached only for pure-geometry targets). The
                // per-reference instance transform is applied AFTER, below.
                let ps = cached_target_geometry(
                    &self.target.0, &target, precision, resolver, visiting);
                visiting.remove(&self.target);
                // Symbols P4 (SYMBOLS.md §4 / Fork F2): the instance `transform`
                // field (distinct from common.transform, which renders as the
                // CTM) is applied to the resolved geometry here, so an instance
                // can be mirrored/scaled relative to its master. This single
                // seam covers every consumer of the resolved set — both render
                // sites, polygon-set, and compound-operand use. None ⇒ return
                // the geometry unchanged (no transform, no double-apply).
                match self.transform {
                    Some(t) => ps.into_iter()
                        .map(|ring| ring.into_iter()
                            .map(|(x, y)| t.apply_point(x, y))
                            .collect())
                        .collect(),
                    None => ps,
                }
            }
            None => PolygonSet::new(), // dangling: target not found
        }
    }
}

impl LiveElement for ReferenceElem {
    fn kind(&self) -> &'static str { "reference" }
    fn kind_schema_version(&self) -> u32 { 1 }
    fn common(&self) -> &CommonProps { &self.common }
    fn common_mut(&mut self) -> &mut CommonProps { &mut self.common }
    fn fill(&self) -> Option<&Fill> { self.fill.as_ref() }
    fn stroke(&self) -> Option<&Stroke> { self.stroke.as_ref() }
    fn children(&self) -> &[Rc<Element>] { &[] }
    fn children_mut(&mut self) -> Option<&mut Vec<Rc<Element>>> { None }
    fn dependencies(&self) -> Vec<ElementRef> { vec![self.target.clone()] }

    /// Resolver-free bounds are degenerate for a reference (its geometry lives
    /// elsewhere); the resolver-aware bounds lands with the render wiring (1b).
    fn bounds(&self) -> Bounds { (0.0, 0.0, 0.0, 0.0) }

    /// A reference owns no source to expand or release; both are no-ops until
    /// the resolver-aware expand path lands.
    fn expand(&self, _precision: f64) -> Vec<Rc<Element>> { Vec::new() }
    fn release(&self) -> Vec<Rc<Element>> { Vec::new() }
}

// ---------------------------------------------------------------------------
// RecordedElem — history-based (recorded) LiveKind (RECORDED_ELEMENTS.md)
// ---------------------------------------------------------------------------

/// A recorded (history-based) live element (RECORDED_ELEMENTS.md): a normalized,
/// input-addressed op-segment captured from the journal, replayed against the
/// *current* inputs to produce derived geometry. Edit a source input and the
/// derivative re-derives live. Output ids are derived deterministically from
/// (this element's own id + a position-in-trace counter), never minted, so
/// replay keeps stable output identity (OP_LOG.md §7 / RECORDED_ELEMENTS.md §5).
///
/// The recipe draws from a replay-safe subset of the op vocabulary (input-
/// addressed, side-effect-free). 3b-A.1 supports `copy` (clone inputs at an
/// offset, producing the output) and `translate` (move named working elements);
/// further verbs (reflect/transform) extend the same replay.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct RecordedElem {
    /// The normalized, input-addressed recipe ops, replayed verbatim in order.
    pub ops: Vec<PrimitiveOp>,
    /// Source element ids the recipe rebinds against (by stable `common.id`).
    pub inputs: Vec<ElementRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill: Option<Fill>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
}

impl RecordedElem {
    pub fn new(ops: Vec<PrimitiveOp>, inputs: Vec<ElementRef>, common: CommonProps) -> Self {
        Self { ops, inputs, fill: None, stroke: None, common }
    }

    /// Replay the recipe against the resolved inputs and return the derived
    /// output geometry. A dangling input or a cycle (an input already being
    /// visited) yields an empty set — never a panic (REFERENCE_GRAPH.md §3).
    /// Replay is a pure, deterministic function of the inputs (OP_LOG.md §7).
    pub fn evaluate_with(
        &self,
        precision: f64,
        resolver: &dyn ElementResolver,
        visiting: &mut VisitSet,
    ) -> PolygonSet {
        // Resolve inputs into a working set keyed by stable id. A cycle breaks
        // to empty at the re-entry edge; a dangling input yields empty.
        let mut working: std::collections::HashMap<String, Element> =
            std::collections::HashMap::new();
        for input in &self.inputs {
            if visiting.contains(input) {
                return PolygonSet::new();
            }
            match resolver.resolve(input) {
                Some(el) => {
                    working.insert(input.0.clone(), (*el).clone());
                }
                None => return PolygonSet::new(),
            }
        }
        // Replay. Output ids are derived deterministically: `<own_id>/<n>`.
        let own_id = self.common.id.clone().unwrap_or_default();
        let mut output_ids: Vec<String> = Vec::new();
        let mut counter: usize = 0;
        let str_ids = |v: Option<&serde_json::Value>| -> Vec<String> {
            v.and_then(|x| x.as_array())
                .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
                .unwrap_or_default()
        };
        let num = |p: &serde_json::Value, k: &str| p.get(k).and_then(|v| v.as_f64()).unwrap_or(0.0);
        for op in &self.ops {
            match op.op.as_str() {
                "copy" => {
                    let (dx, dy) = (num(&op.params, "dx"), num(&op.params, "dy"));
                    for src in str_ids(op.params.get("from")) {
                        if let Some(el) = working.get(&src) {
                            let derived_id = format!("{own_id}/{counter}");
                            counter += 1;
                            let copy = translate_element(el, dx, dy);
                            working.insert(derived_id.clone(), copy);
                            output_ids.push(derived_id);
                        }
                    }
                }
                "translate" => {
                    let (dx, dy) = (num(&op.params, "dx"), num(&op.params, "dy"));
                    for id in str_ids(op.params.get("ids")) {
                        if let Some(el) = working.get(&id) {
                            let moved = translate_element(el, dx, dy);
                            working.insert(id, moved);
                        }
                    }
                }
                _ => {} // outside the replay-safe subset: skip
            }
        }
        // Output = the derived elements' geometry, in derivation order.
        let mut out = PolygonSet::new();
        for id in &output_ids {
            if let Some(el) = working.get(id) {
                out.extend(element_to_polygon_set(el, precision));
            }
        }
        out
    }
}

// ---------------------------------------------------------------------------
// LiveVariant — closed-world enum over the known LiveKinds
// ---------------------------------------------------------------------------

/// Closed-world enum over all known LiveKinds. Adding a new kind adds
/// one variant here and one match arm in each trait method; the top-
/// level `Element` enum only ever has one `Live(LiveVariant)` variant.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum LiveVariant {
    CompoundShape(CompoundShape),
    Reference(ReferenceElem),
}

impl LiveElement for LiveVariant {
    fn kind(&self) -> &'static str {
        match self {
            LiveVariant::CompoundShape(cs) => cs.kind(),
            LiveVariant::Reference(r) => r.kind(),
        }
    }
    fn kind_schema_version(&self) -> u32 {
        match self {
            LiveVariant::CompoundShape(cs) => cs.kind_schema_version(),
            LiveVariant::Reference(r) => r.kind_schema_version(),
        }
    }
    fn common(&self) -> &CommonProps {
        match self {
            LiveVariant::CompoundShape(cs) => cs.common(),
            LiveVariant::Reference(r) => r.common(),
        }
    }
    fn common_mut(&mut self) -> &mut CommonProps {
        match self {
            LiveVariant::CompoundShape(cs) => cs.common_mut(),
            LiveVariant::Reference(r) => r.common_mut(),
        }
    }
    fn fill(&self) -> Option<&Fill> {
        match self {
            LiveVariant::CompoundShape(cs) => cs.fill(),
            LiveVariant::Reference(r) => r.fill(),
        }
    }
    fn stroke(&self) -> Option<&Stroke> {
        match self {
            LiveVariant::CompoundShape(cs) => cs.stroke(),
            LiveVariant::Reference(r) => r.stroke(),
        }
    }
    fn children(&self) -> &[Rc<Element>] {
        match self {
            LiveVariant::CompoundShape(cs) => cs.children(),
            LiveVariant::Reference(r) => r.children(),
        }
    }
    fn children_mut(&mut self) -> Option<&mut Vec<Rc<Element>>> {
        match self {
            LiveVariant::CompoundShape(cs) => cs.children_mut(),
            LiveVariant::Reference(r) => r.children_mut(),
        }
    }
    fn dependencies(&self) -> Vec<ElementRef> {
        match self {
            LiveVariant::CompoundShape(cs) => cs.dependencies(),
            LiveVariant::Reference(r) => r.dependencies(),
        }
    }
    fn bounds(&self) -> Bounds {
        match self {
            LiveVariant::CompoundShape(cs) => cs.bounds(),
            LiveVariant::Reference(r) => r.bounds(),
        }
    }
    fn invalidate(&mut self) {
        match self {
            LiveVariant::CompoundShape(cs) => cs.invalidate(),
            LiveVariant::Reference(r) => r.invalidate(),
        }
    }
    fn expand(&self, precision: f64) -> Vec<Rc<Element>> {
        match self {
            LiveVariant::CompoundShape(cs) => cs.expand(precision),
            LiveVariant::Reference(r) => r.expand(precision),
        }
    }
    fn release(&self) -> Vec<Rc<Element>> {
        match self {
            LiveVariant::CompoundShape(cs) => cs.release(),
            LiveVariant::Reference(r) => r.release(),
        }
    }
}

// ---------------------------------------------------------------------------
// Evaluation helpers — Element → PolygonSet, boolean dispatch, bounds
// ---------------------------------------------------------------------------

/// Flatten a document element into a polygon set suitable for the
/// boolean algorithm. Per BOOLEAN.md § Geometry and precision:
///
/// - Rect / Polygon / Polyline / Circle / Ellipse → direct conversion.
///   Polyline is implicitly closed.
/// - Group / Layer → recursively concatenate children's rings.
/// - Live → recursively evaluate.
/// - Path / Text / TextPath / Line → empty for now. Path flattening
///   (Bézier → polyline) lands in a follow-up phase; Text glyph
///   flattening is deferred; Line has zero area.
pub(crate) fn element_to_polygon_set(elem: &Element, precision: f64) -> PolygonSet {
    let mut visiting = VisitSet::new();
    element_to_polygon_set_with(elem, precision, &NullResolver, &mut visiting)
}

/// Resolver-aware flattening. Identical to [`element_to_polygon_set`] except
/// that by-id references (added in a follow-up) resolve through `resolver`,
/// with `visiting` breaking cycles. The 2-arg wrapper above passes a
/// [`NullResolver`], so existing call sites are behavior-identical.
pub(crate) fn element_to_polygon_set_with(
    elem: &Element,
    precision: f64,
    resolver: &dyn ElementResolver,
    visiting: &mut VisitSet,
) -> PolygonSet {
    match elem {
        Element::Rect(r) => vec![vec![
            (r.x, r.y),
            (r.x + r.width, r.y),
            (r.x + r.width, r.y + r.height),
            (r.x, r.y + r.height),
        ]],
        Element::Polygon(p) => {
            if p.points.is_empty() { PolygonSet::new() } else { vec![p.points.clone()] }
        }
        Element::Polyline(p) => {
            if p.points.is_empty() { PolygonSet::new() } else { vec![p.points.clone()] }
        }
        Element::Circle(c) => vec![circle_to_ring(c.cx, c.cy, c.r, precision)],
        Element::Ellipse(e) => vec![ellipse_to_ring(e.cx, e.cy, e.rx, e.ry, precision)],
        Element::Group(g) => {
            let mut out = PolygonSet::new();
            for child in &g.children {
                out.extend(element_to_polygon_set_with(child, precision, resolver, visiting));
            }
            out
        }
        Element::Layer(l) => {
            let mut out = PolygonSet::new();
            for child in &l.children {
                out.extend(element_to_polygon_set_with(child, precision, resolver, visiting));
            }
            out
        }
        Element::Live(v) => match v {
            LiveVariant::CompoundShape(cs) => cs.evaluate_with(precision, resolver, visiting),
            LiveVariant::Reference(r) => r.evaluate_with(precision, resolver, visiting),
        },
        Element::Path(p) => super::element::flatten_path_to_rings(&p.d),
        Element::TextPath(tp) => {
            // Treat text-on-path's underlying path as a ring; the
            // glyph layout itself is not a polygon-set concept.
            super::element::flatten_path_to_rings(&tp.d)
        }
        // Line has zero area; Text glyph flattening is deferred until
        // we have a font-outline pipeline.
        Element::Line(_) | Element::Text(_) => PolygonSet::new(),
    }
}

/// Sample a circle at enough points that the max perpendicular
/// distance between the polyline and the true arc is ≤ `precision`.
///
/// Error per segment on a circle of radius r is ≈ r·(1 − cos(π/n)),
/// which for large n is ≈ r·(π/n)²/2. Solving for n:
///
/// ```text
/// n ≥ π · √(r / (2 · precision))
/// ```
fn circle_to_ring(cx: f64, cy: f64, r: f64, precision: f64) -> Vec<(f64, f64)> {
    let n = segments_for_arc(r, precision);
    (0..n)
        .map(|i| {
            let theta = (i as f64) / (n as f64) * std::f64::consts::TAU;
            (cx + r * theta.cos(), cy + r * theta.sin())
        })
        .collect()
}

/// Same formula as `circle_to_ring`, using the larger radius to pick
/// the segment count conservatively.
fn ellipse_to_ring(cx: f64, cy: f64, rx: f64, ry: f64, precision: f64) -> Vec<(f64, f64)> {
    let n = segments_for_arc(rx.max(ry), precision);
    (0..n)
        .map(|i| {
            let theta = (i as f64) / (n as f64) * std::f64::consts::TAU;
            (cx + rx * theta.cos(), cy + ry * theta.sin())
        })
        .collect()
}

fn segments_for_arc(radius: f64, precision: f64) -> usize {
    if radius <= 0.0 || precision <= 0.0 {
        return 32;
    }
    let approx = std::f64::consts::PI * (radius / (2.0 * precision)).sqrt();
    approx.ceil().max(8.0) as usize
}

/// Dispatch a boolean operation across an arbitrary number of operands.
/// Binary ops are folded left-to-right; SubtractFront consumes the
/// last operand as the cutter and unions the remaining survivors
/// after each one has the cutter removed, matching the semantics in
/// BOOLEAN.md § Operand and paint rules.
pub(crate) fn apply_operation(op: CompoundOperation, operands: &[PolygonSet]) -> PolygonSet {
    if operands.is_empty() {
        return PolygonSet::new();
    }
    match op {
        CompoundOperation::Union => {
            operands[1..]
                .iter()
                .fold(operands[0].clone(), |acc, b| boolean::boolean_union(&acc, b))
        }
        CompoundOperation::Intersection => {
            operands[1..]
                .iter()
                .fold(operands[0].clone(), |acc, b| boolean::boolean_intersect(&acc, b))
        }
        CompoundOperation::SubtractFront => {
            if operands.len() < 2 {
                return operands[0].clone();
            }
            let (survivors, cutter_slice) = operands.split_at(operands.len() - 1);
            let cutter = &cutter_slice[0];
            survivors
                .iter()
                .map(|s| boolean::boolean_subtract(s, cutter))
                .fold(PolygonSet::new(), |acc, s| boolean::boolean_union(&acc, &s))
        }
        CompoundOperation::Exclude => {
            operands[1..]
                .iter()
                .fold(operands[0].clone(), |acc, b| boolean::boolean_exclude(&acc, b))
        }
    }
}

/// Tight bounding box of a polygon set. Returns `(0, 0, 0, 0)` for
/// empty input.
fn bounds_of_polygon_set(ps: &PolygonSet) -> Bounds {
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    for ring in ps {
        for &(x, y) in ring {
            if x < min_x { min_x = x; }
            if y < min_y { min_y = y; }
            if x > max_x { max_x = x; }
            if y > max_y { max_y = y; }
        }
    }
    if !min_x.is_finite() {
        return (0.0, 0.0, 0.0, 0.0);
    }
    (min_x, min_y, max_x - min_x, max_y - min_y)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::RectElem;

    fn empty_compound(op: CompoundOperation) -> CompoundShape {
        CompoundShape {
            operation: op,
            operands: vec![],
            fill: None,
            stroke: None,
            common: CommonProps::default(),
        }
    }

    fn rc_rect(x: f64, y: f64, w: f64, h: f64) -> Rc<Element> {
        Rc::new(Element::Rect(RectElem {
            x, y, width: w, height: h, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        }))
    }

    fn bbox_of_ring(ring: &[(f64, f64)]) -> (f64, f64, f64, f64) {
        let min_x = ring.iter().map(|(x, _)| *x).fold(f64::INFINITY, f64::min);
        let max_x = ring.iter().map(|(x, _)| *x).fold(f64::NEG_INFINITY, f64::max);
        let min_y = ring.iter().map(|(_, y)| *y).fold(f64::INFINITY, f64::min);
        let max_y = ring.iter().map(|(_, y)| *y).fold(f64::NEG_INFINITY, f64::max);
        (min_x, min_y, max_x, max_y)
    }

    #[test]
    fn compound_shape_kind_and_version() {
        let cs = empty_compound(CompoundOperation::Union);
        assert_eq!(cs.kind(), "compound_shape");
        assert_eq!(cs.kind_schema_version(), 1);
    }

    #[test]
    fn live_variant_delegates_to_inner() {
        let lv = LiveVariant::CompoundShape(empty_compound(CompoundOperation::Intersection));
        assert_eq!(lv.kind(), "compound_shape");
        assert_eq!(lv.children().len(), 0);
        // Empty compound → empty bounds.
        assert_eq!(lv.bounds(), (0.0, 0.0, 0.0, 0.0));
    }

    #[test]
    fn serde_roundtrip_via_element() {
        let cs = empty_compound(CompoundOperation::SubtractFront);
        let element = Element::Live(LiveVariant::CompoundShape(cs));
        let json = serde_json::to_string(&element).expect("serialize");
        let back: Element = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(element, back);
    }

    #[test]
    fn live_variant_is_kind_tagged() {
        let lv = LiveVariant::CompoundShape(empty_compound(CompoundOperation::Union));
        let json = serde_json::to_string(&lv).expect("serialize");
        assert!(json.contains("\"kind\":\"compound_shape\""),
                "expected kind tag in {json}");
        assert!(json.contains("\"operation\":\"union\""),
                "expected snake_case operation in {json}");
    }

    #[test]
    fn evaluate_union_of_two_overlapping_rects() {
        // r1 = [0..10]×[0..10], r2 = [5..15]×[0..10]. Union spans
        // x∈[0,15], y∈[0,10], as a single ring.
        let cs = CompoundShape {
            operation: CompoundOperation::Union,
            operands: vec![rc_rect(0.0, 0.0, 10.0, 10.0), rc_rect(5.0, 0.0, 10.0, 10.0)],
            fill: None, stroke: None, common: CommonProps::default(),
        };
        let polygons = cs.evaluate(DEFAULT_PRECISION);
        assert_eq!(polygons.len(), 1, "union of overlapping rects = 1 ring");
        let (min_x, min_y, max_x, max_y) = bbox_of_ring(&polygons[0]);
        assert!((min_x - 0.0).abs() < 1e-6, "min_x = {min_x}");
        assert!((max_x - 15.0).abs() < 1e-6, "max_x = {max_x}");
        assert!((min_y - 0.0).abs() < 1e-6, "min_y = {min_y}");
        assert!((max_y - 10.0).abs() < 1e-6, "max_y = {max_y}");
    }

    #[test]
    fn evaluate_intersection_of_two_overlapping_rects() {
        let cs = CompoundShape {
            operation: CompoundOperation::Intersection,
            operands: vec![rc_rect(0.0, 0.0, 10.0, 10.0), rc_rect(5.0, 0.0, 10.0, 10.0)],
            fill: None, stroke: None, common: CommonProps::default(),
        };
        let polygons = cs.evaluate(DEFAULT_PRECISION);
        assert_eq!(polygons.len(), 1);
        let (min_x, min_y, max_x, max_y) = bbox_of_ring(&polygons[0]);
        assert!((min_x - 5.0).abs() < 1e-6, "min_x = {min_x}");
        assert!((max_x - 10.0).abs() < 1e-6, "max_x = {max_x}");
        assert!((min_y - 0.0).abs() < 1e-6, "min_y = {min_y}");
        assert!((max_y - 10.0).abs() < 1e-6, "max_y = {max_y}");
    }

    #[test]
    fn evaluate_subtract_front_removes_frontmost_operand() {
        // Front (last) = cutter at [5..15]×[0..10]. Survivor at
        // [0..10]×[0..10]. Subtraction leaves x∈[0,5], y∈[0,10].
        let cs = CompoundShape {
            operation: CompoundOperation::SubtractFront,
            operands: vec![rc_rect(0.0, 0.0, 10.0, 10.0), rc_rect(5.0, 0.0, 10.0, 10.0)],
            fill: None, stroke: None, common: CommonProps::default(),
        };
        let polygons = cs.evaluate(DEFAULT_PRECISION);
        assert_eq!(polygons.len(), 1);
        let (min_x, _, max_x, _) = bbox_of_ring(&polygons[0]);
        assert!((min_x - 0.0).abs() < 1e-6);
        assert!((max_x - 5.0).abs() < 1e-6, "max_x = {max_x}");
    }

    #[test]
    fn evaluate_exclude_is_symmetric_difference() {
        // XOR of two overlapping rects → two disjoint rings.
        let cs = CompoundShape {
            operation: CompoundOperation::Exclude,
            operands: vec![rc_rect(0.0, 0.0, 10.0, 10.0), rc_rect(5.0, 0.0, 10.0, 10.0)],
            fill: None, stroke: None, common: CommonProps::default(),
        };
        let polygons = cs.evaluate(DEFAULT_PRECISION);
        // Two non-overlapping strips.
        assert_eq!(polygons.len(), 2, "xor of partially overlapping rects = 2 rings");
    }

    #[test]
    fn bounds_reflects_evaluated_geometry() {
        let cs = CompoundShape {
            operation: CompoundOperation::Union,
            operands: vec![rc_rect(0.0, 0.0, 10.0, 10.0), rc_rect(5.0, 0.0, 10.0, 10.0)],
            fill: None, stroke: None, common: CommonProps::default(),
        };
        let (bx, by, bw, bh) = cs.bounds();
        assert!((bx - 0.0).abs() < 1e-6);
        assert!((by - 0.0).abs() < 1e-6);
        assert!((bw - 15.0).abs() < 1e-6);
        assert!((bh - 10.0).abs() < 1e-6);
    }

    #[test]
    fn empty_compound_has_empty_bounds() {
        let cs = empty_compound(CompoundOperation::Union);
        assert_eq!(cs.bounds(), (0.0, 0.0, 0.0, 0.0));
    }

    #[test]
    fn element_to_polygon_set_rect() {
        let rect = Element::Rect(RectElem {
            x: 1.0, y: 2.0, width: 3.0, height: 4.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        });
        let ps = element_to_polygon_set(&rect, DEFAULT_PRECISION);
        assert_eq!(ps.len(), 1);
        assert_eq!(ps[0], vec![(1.0, 2.0), (4.0, 2.0), (4.0, 6.0), (1.0, 6.0)]);
    }

    #[test]
    fn expand_produces_one_polygon_per_ring() {
        use crate::geometry::element::{Color, Fill};
        let red = Fill::new(Color::Rgb { r: 1.0, g: 0.0, b: 0.0, a: 1.0 });
        let cs = CompoundShape {
            operation: CompoundOperation::Exclude,
            operands: vec![rc_rect(0.0, 0.0, 10.0, 10.0), rc_rect(5.0, 0.0, 10.0, 10.0)],
            fill: Some(red),
            stroke: None,
            common: CommonProps::default(),
        };
        let expanded = cs.expand(DEFAULT_PRECISION);
        // XOR of two overlapping rects → two non-overlapping rings.
        assert_eq!(expanded.len(), 2);
        // Each produced element is a Polygon carrying the compound
        // shape's own fill.
        for rc in &expanded {
            match rc.as_ref() {
                Element::Polygon(p) => {
                    assert_eq!(p.fill, Some(red));
                }
                other => panic!("expected Polygon, got {other:?}"),
            }
        }
    }

    #[test]
    fn release_returns_operands_verbatim() {
        let r1 = rc_rect(0.0, 0.0, 10.0, 10.0);
        let r2 = rc_rect(5.0, 0.0, 10.0, 10.0);
        let cs = CompoundShape {
            operation: CompoundOperation::Union,
            operands: vec![r1.clone(), r2.clone()],
            fill: None, stroke: None, common: CommonProps::default(),
        };
        let released = cs.release();
        assert_eq!(released.len(), 2);
        // Same Rc instances — no deep clone.
        assert!(Rc::ptr_eq(&released[0], &r1));
        assert!(Rc::ptr_eq(&released[1], &r2));
    }

    #[test]
    fn element_live_bounds_come_from_evaluation() {
        // Wrap a CompoundShape in an Element and verify the top-level
        // Element::bounds() accessor delegates into LiveElement::bounds.
        let cs = CompoundShape {
            operation: CompoundOperation::Union,
            operands: vec![rc_rect(0.0, 0.0, 10.0, 10.0), rc_rect(5.0, 0.0, 10.0, 10.0)],
            fill: None, stroke: None, common: CommonProps::default(),
        };
        let elem = Element::Live(LiveVariant::CompoundShape(cs));
        let (bx, by, bw, bh) = elem.bounds();
        assert!((bx - 0.0).abs() < 1e-6);
        assert!((by - 0.0).abs() < 1e-6);
        assert!((bw - 15.0).abs() < 1e-6);
        assert!((bh - 10.0).abs() < 1e-6);
    }

    #[test]
    fn path_flattens_into_polygon_set_for_boolean() {
        use crate::geometry::element::{PathCommand, PathElem};
        // Path equivalent of a 10x10 square at origin, closed.
        let sq = Rc::new(Element::Path(PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::LineTo { x: 10.0, y: 0.0 },
                PathCommand::LineTo { x: 10.0, y: 10.0 },
                PathCommand::LineTo { x: 0.0, y: 10.0 },
                PathCommand::ClosePath,
            ],
            fill: None, stroke: None, width_points: vec![],
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
            stroke_brush: None,
            stroke_brush_overrides: None,
            fill_rule: crate::geometry::element::FillRule::NonZero,
        }));
        let ps = element_to_polygon_set(&sq, DEFAULT_PRECISION);
        assert_eq!(ps.len(), 1, "closed square path → 1 ring");
        let (min_x, min_y, max_x, max_y) = bbox_of_ring(&ps[0]);
        assert!((min_x - 0.0).abs() < 1e-6);
        assert!((min_y - 0.0).abs() < 1e-6);
        assert!((max_x - 10.0).abs() < 1e-6);
        assert!((max_y - 10.0).abs() < 1e-6);
    }

    #[test]
    fn compound_shape_with_path_operand_evaluates() {
        use crate::geometry::element::{PathCommand, PathElem};
        let sq = |ox: f64| Rc::new(Element::Path(PathElem {
            d: vec![
                PathCommand::MoveTo { x: ox, y: 0.0 },
                PathCommand::LineTo { x: ox + 10.0, y: 0.0 },
                PathCommand::LineTo { x: ox + 10.0, y: 10.0 },
                PathCommand::LineTo { x: ox, y: 10.0 },
                PathCommand::ClosePath,
            ],
            fill: None, stroke: None, width_points: vec![],
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
            stroke_brush: None,
            stroke_brush_overrides: None,
            fill_rule: crate::geometry::element::FillRule::NonZero,
        }));
        let cs = CompoundShape {
            operation: CompoundOperation::Union,
            operands: vec![sq(0.0), sq(5.0)],
            fill: None, stroke: None, common: CommonProps::default(),
        };
        let ps = cs.evaluate(DEFAULT_PRECISION);
        // Union of two overlapping path-rects → 1 ring spanning
        // x ∈ [0, 15], y ∈ [0, 10].
        assert_eq!(ps.len(), 1);
        let (min_x, min_y, max_x, max_y) = bbox_of_ring(&ps[0]);
        assert!((min_x - 0.0).abs() < 1e-6);
        assert!((min_y - 0.0).abs() < 1e-6);
        assert!((max_x - 15.0).abs() < 1e-6);
        assert!((max_y - 10.0).abs() < 1e-6);
    }

    #[test]
    fn multi_subpath_path_yields_multi_ring_polygon_set() {
        use crate::geometry::element::{PathCommand, PathElem};
        // Two disjoint squares in one path.
        let p = Rc::new(Element::Path(PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::LineTo { x: 10.0, y: 0.0 },
                PathCommand::LineTo { x: 10.0, y: 10.0 },
                PathCommand::LineTo { x: 0.0, y: 10.0 },
                PathCommand::ClosePath,
                PathCommand::MoveTo { x: 20.0, y: 0.0 },
                PathCommand::LineTo { x: 30.0, y: 0.0 },
                PathCommand::LineTo { x: 30.0, y: 10.0 },
                PathCommand::LineTo { x: 20.0, y: 10.0 },
                PathCommand::ClosePath,
            ],
            fill: None, stroke: None, width_points: vec![],
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
            stroke_brush: None,
            stroke_brush_overrides: None,
            fill_rule: crate::geometry::element::FillRule::NonZero,
        }));
        let ps = element_to_polygon_set(&p, DEFAULT_PRECISION);
        assert_eq!(ps.len(), 2, "two disjoint subpaths → 2 rings");
    }

    #[test]
    fn element_to_polygon_set_recurses_into_live() {
        let inner = Rc::new(Element::Live(LiveVariant::CompoundShape(CompoundShape {
            operation: CompoundOperation::Union,
            operands: vec![rc_rect(0.0, 0.0, 10.0, 10.0), rc_rect(5.0, 0.0, 10.0, 10.0)],
            fill: None, stroke: None, common: CommonProps::default(),
        })));
        let ps = element_to_polygon_set(&inner, DEFAULT_PRECISION);
        assert_eq!(ps.len(), 1, "nested compound shape evaluates to one ring");
        let (min_x, _, max_x, _) = bbox_of_ring(&ps[0]);
        assert!((min_x - 0.0).abs() < 1e-6);
        assert!((max_x - 15.0).abs() < 1e-6);
    }

    // --- ReferenceElem (REFERENCE_GRAPH.md Phase 1a) -------------------------

    /// A test resolver backed by an id→element map.
    struct MapResolver(std::collections::HashMap<String, Rc<Element>>);
    impl ElementResolver for MapResolver {
        fn resolve(&self, id: &ElementRef) -> Option<Rc<Element>> {
            self.0.get(&id.0).cloned()
        }
    }

    #[test]
    fn reference_evaluates_to_target_geometry() {
        let mut map = std::collections::HashMap::new();
        map.insert("r1".to_string(), rc_rect(0.0, 0.0, 10.0, 10.0));
        let resolver = MapResolver(map);
        let reference = ReferenceElem::new(ElementRef("r1".into()), CommonProps::default());
        let mut visiting = VisitSet::new();
        let ps = reference.evaluate_with(DEFAULT_PRECISION, &resolver, &mut visiting);
        assert_eq!(ps.len(), 1, "reference resolves to the target rect's ring");
        let (min_x, _, max_x, _) = bbox_of_ring(&ps[0]);
        assert!((min_x - 0.0).abs() < 1e-6);
        assert!((max_x - 10.0).abs() < 1e-6);
        // The cycle-guard set is left clean after a successful resolve.
        assert!(visiting.is_empty());
    }

    #[test]
    fn dangling_reference_evaluates_empty() {
        let reference = ReferenceElem::new(ElementRef("missing".into()), CommonProps::default());
        let mut visiting = VisitSet::new();
        let ps = reference.evaluate_with(DEFAULT_PRECISION, &NullResolver, &mut visiting);
        assert!(ps.is_empty(), "dangling reference evaluates to empty, never panics");
    }

    // --- RecordedElem (RECORDED_ELEMENTS.md — history-based provenance) ------

    fn recorded_op(op: &str, params: serde_json::Value) -> PrimitiveOp {
        PrimitiveOp { op: op.to_string(), params, targets: Vec::new() }
    }

    #[test]
    fn recorded_replays_copy_translate_and_re_derives_when_input_changes() {
        // Recipe: copy the input "eye", then translate that derived copy +50x.
        // The derived copy is the recorded element's output; editing the source
        // eye must re-derive it live.
        let recipe = vec![
            recorded_op("copy", serde_json::json!({"from": ["eye"], "dx": 0.0, "dy": 0.0})),
            recorded_op("translate", serde_json::json!({"ids": ["rec/0"], "dx": 50.0, "dy": 0.0})),
        ];
        let mut common = CommonProps::default();
        common.id = Some("rec".into());
        let recorded = RecordedElem::new(recipe, vec![ElementRef("eye".into())], common);

        // Source eye at (0,0,10,10) → derived copy translated +50 → bbox [50,60].
        let mut map = std::collections::HashMap::new();
        map.insert("eye".to_string(), rc_rect(0.0, 0.0, 10.0, 10.0));
        let mut visiting = VisitSet::new();
        let ps = recorded.evaluate_with(DEFAULT_PRECISION, &MapResolver(map), &mut visiting);
        assert_eq!(ps.len(), 1, "one derived output element");
        let (min_x, _, max_x, _) = bbox_of_ring(&ps[0]);
        assert!((min_x - 50.0).abs() < 1e-6 && (max_x - 60.0).abs() < 1e-6);

        // Edit the source eye (move to x=100) → the derived copy follows.
        let mut map2 = std::collections::HashMap::new();
        map2.insert("eye".to_string(), rc_rect(100.0, 0.0, 10.0, 10.0));
        let mut visiting2 = VisitSet::new();
        let ps2 = recorded.evaluate_with(DEFAULT_PRECISION, &MapResolver(map2), &mut visiting2);
        let (min_x2, _, max_x2, _) = bbox_of_ring(&ps2[0]);
        assert!((min_x2 - 150.0).abs() < 1e-6 && (max_x2 - 160.0).abs() < 1e-6,
            "derived copy re-derived against the edited source");
    }

    #[test]
    fn recorded_dangling_input_evaluates_empty() {
        let recipe = vec![recorded_op("copy", serde_json::json!({"from": ["x"], "dx": 0.0, "dy": 0.0}))];
        let recorded = RecordedElem::new(recipe, vec![ElementRef("x".into())], CommonProps::default());
        let mut visiting = VisitSet::new();
        let ps = recorded.evaluate_with(DEFAULT_PRECISION, &NullResolver, &mut visiting);
        assert!(ps.is_empty(), "dangling input evaluates empty, never panics");
    }

    #[test]
    fn reference_cycle_breaks_to_empty() {
        // Resolver where id "a" resolves to a reference back to "a" — a
        // self-cycle. The threaded visited-set must break it.
        struct CycleResolver;
        impl ElementResolver for CycleResolver {
            fn resolve(&self, id: &ElementRef) -> Option<Rc<Element>> {
                if id.0 == "a" {
                    Some(Rc::new(Element::Live(LiveVariant::Reference(
                        ReferenceElem::new(ElementRef("a".into()), CommonProps::default()),
                    ))))
                } else {
                    None
                }
            }
        }
        let reference = ReferenceElem::new(ElementRef("a".into()), CommonProps::default());
        let mut visiting = VisitSet::new();
        let ps = reference.evaluate_with(DEFAULT_PRECISION, &CycleResolver, &mut visiting);
        assert!(ps.is_empty(), "reference cycle breaks to empty, no infinite recursion");
        assert!(visiting.is_empty(), "cycle-guard set is restored after evaluation");
    }

    #[test]
    fn reference_reports_its_target_as_dependency() {
        let reference = ReferenceElem::new(ElementRef("t".into()), CommonProps::default());
        assert_eq!(reference.dependencies(), vec![ElementRef("t".into())]);
        assert!(reference.children().is_empty());
    }

    // --- Symbols P4: the instance `transform` field (SYMBOLS.md §4 / Fork F2) -

    #[test]
    fn reference_instance_transform_scales_target_geometry() {
        // A reference whose instance `transform` is scale(2,2), targeting a
        // 10x10 rect at the origin, evaluates to the rect geometry scaled 2x
        // (a 20x20 ring). The instance transform is applied to every point of
        // the resolved PolygonSet (composition: instance.transform ∘ geometry).
        use crate::geometry::element::Transform;
        let mut map = std::collections::HashMap::new();
        map.insert("r1".to_string(), rc_rect(0.0, 0.0, 10.0, 10.0));
        let resolver = MapResolver(map);
        let mut reference = ReferenceElem::new(ElementRef("r1".into()), CommonProps::default());
        reference.transform = Some(Transform::scale(2.0, 2.0));
        let mut visiting = VisitSet::new();
        let scaled = reference.evaluate_with(DEFAULT_PRECISION, &resolver, &mut visiting);

        // Unscaled reference for comparison.
        let plain = ReferenceElem::new(ElementRef("r1".into()), CommonProps::default());
        let mut visiting2 = VisitSet::new();
        let mut map2 = std::collections::HashMap::new();
        map2.insert("r1".to_string(), rc_rect(0.0, 0.0, 10.0, 10.0));
        let resolver2 = MapResolver(map2);
        let unscaled = plain.evaluate_with(DEFAULT_PRECISION, &resolver2, &mut visiting2);

        assert_eq!(scaled.len(), unscaled.len(), "same ring count, just scaled");
        let (sminx, sminy, smaxx, smaxy) = bbox_of_ring(&scaled[0]);
        let (uminx, uminy, umaxx, umaxy) = bbox_of_ring(&unscaled[0]);
        assert!((sminx - uminx * 2.0).abs() < 1e-6);
        assert!((sminy - uminy * 2.0).abs() < 1e-6);
        assert!((smaxx - umaxx * 2.0).abs() < 1e-6);
        assert!((smaxy - umaxy * 2.0).abs() < 1e-6);
        // Concretely: the 10x10 rect at origin scales to a 20x20 box.
        assert!((sminx - 0.0).abs() < 1e-6 && (sminy - 0.0).abs() < 1e-6);
        assert!((smaxx - 20.0).abs() < 1e-6 && (smaxy - 20.0).abs() < 1e-6);
        assert!(visiting.is_empty());
    }

    #[test]
    fn reference_none_instance_transform_leaves_eval_unchanged() {
        // The default instance transform is None; eval is byte-identical to the
        // resolved target geometry (no transform applied, no double-apply).
        let mut map = std::collections::HashMap::new();
        map.insert("r1".to_string(), rc_rect(0.0, 0.0, 10.0, 10.0));
        let resolver = MapResolver(map);
        let reference = ReferenceElem::new(ElementRef("r1".into()), CommonProps::default());
        assert!(reference.transform.is_none(), "instance transform defaults to None");
        let mut visiting = VisitSet::new();
        let via_ref = reference.evaluate_with(DEFAULT_PRECISION, &resolver, &mut visiting);
        // Equal to evaluating the target rect directly.
        let direct = element_to_polygon_set(
            &Element::Rect(crate::geometry::element::RectElem {
                x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
                fill: None, stroke: None, common: CommonProps::default(),
                fill_gradient: None, stroke_gradient: None,
            }),
            DEFAULT_PRECISION);
        assert_eq!(via_ref, direct,
            "None instance transform leaves the resolved geometry unchanged");
    }

    // --- Symbols P1: an instance resolves a master from doc.symbols ----------

    #[test]
    fn instance_resolves_to_master_geometry_from_symbols() {
        // SYMBOLS.md §10 RESOLVE gate: the symbols_basic doc — ONE master rect
        // (id "m1") in doc.symbols and ONE instance (a ReferenceElem id "i1"
        // targeting "m1") in a layer. A resolver that indexes doc.symbols (as
        // canvas::render::register_ref_index does) makes the instance evaluate
        // to the master's geometry — non-empty and equal to the rect's polygon
        // set. This is the whole point of the off-canvas store: masters are
        // resolvable but never in `layers`.
        use crate::document::document::Document;
        use crate::geometry::element::RectElem;

        let master_rect = RectElem {
            x: 9.0, y: 18.0, width: 27.0, height: 36.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps { id: Some("m1".into()), ..Default::default() },
            fill_gradient: None, stroke_gradient: None,
        };
        let mut doc = Document::default();
        doc.symbols = vec![Element::Rect(master_rect.clone())];
        // The instance lives in a layer, off the master.
        doc.layers[0].children_mut().unwrap().push(Rc::new(Element::Live(
            LiveVariant::Reference(ReferenceElem::new(
                ElementRef("m1".into()),
                CommonProps { id: Some("i1".into()), ..Default::default() },
            )),
        )));

        // Build an id->element index over doc.symbols (the symbols half of
        // register_ref_index): a master's OWN id is the target.
        let mut map = std::collections::HashMap::new();
        for m in &doc.symbols {
            if let Some(id) = &m.common().id {
                map.insert(id.clone(), Rc::new(m.clone()));
            }
        }
        let resolver = MapResolver(map);

        // Pull the instance out of the layer and evaluate it.
        let instance = doc.layers[0].children().unwrap().last().unwrap().clone();
        let mut visiting = VisitSet::new();
        let resolved = element_to_polygon_set_with(
            &instance, DEFAULT_PRECISION, &resolver, &mut visiting);

        // Non-empty, and equal to evaluating the master rect directly.
        assert!(!resolved.is_empty(), "instance must resolve to the master geometry");
        let master_ps = element_to_polygon_set(
            &Element::Rect(master_rect), DEFAULT_PRECISION);
        assert_eq!(resolved, master_ps,
            "resolved instance geometry must equal the master rect's polygon set");
        assert!(visiting.is_empty(), "cycle-guard set restored after resolve");
    }

    // --- Phase 4c: reference-geometry recompute cache ------------------------
    //
    // RUST-ONLY perf cache. No behavior change: every assertion below pins
    // eval RESULTS against a fresh `element_to_polygon_set_with`, while
    // additionally checking the cache STATE (Pure / HasRefs / absent) so the
    // caching itself is observable. The debug-assert gate inside the lookup
    // (`cached == fresh`) also fires on every Pure hit in these tests.

    /// A resolver whose backing map can be mutated between evaluations so a
    /// test can simulate an edit to the target (new `Rc`, hence new ptr).
    struct CellResolver(std::cell::RefCell<std::collections::HashMap<String, Rc<Element>>>);
    impl ElementResolver for CellResolver {
        fn resolve(&self, id: &ElementRef) -> Option<Rc<Element>> {
            self.0.borrow().get(&id.0).cloned()
        }
    }
    impl CellResolver {
        fn new() -> Self {
            Self(std::cell::RefCell::new(std::collections::HashMap::new()))
        }
        fn set(&self, id: &str, elem: Rc<Element>) {
            self.0.borrow_mut().insert(id.to_string(), elem);
        }
    }

    /// Evaluate the target the cache would obtain, threading a fresh visit set
    /// so the comparison oracle is independent of cache state.
    fn fresh_target_geom(target: &Rc<Element>, precision: f64, resolver: &dyn ElementResolver)
        -> PolygonSet
    {
        let mut v = VisitSet::new();
        element_to_polygon_set_with(target, precision, resolver, &mut v)
    }

    #[test]
    fn subtree_has_reference_detects_nested_reference() {
        // A bare rect has no reference.
        let rect = rc_rect(0.0, 0.0, 10.0, 10.0);
        assert!(!subtree_has_reference(&rect));

        // A group of rects has no reference.
        let group = Rc::new(Element::Group(crate::geometry::element::GroupElem {
            children: vec![rc_rect(0.0, 0.0, 5.0, 5.0), rc_rect(5.0, 0.0, 5.0, 5.0)],
            common: CommonProps::default(),
            ..Default::default()
        }));
        assert!(!subtree_has_reference(&group));

        // A group containing a reference DOES have one (the stale hazard).
        let group_with_ref = Rc::new(Element::Group(crate::geometry::element::GroupElem {
            children: vec![
                rc_rect(0.0, 0.0, 5.0, 5.0),
                Rc::new(Element::Live(LiveVariant::Reference(ReferenceElem::new(
                    ElementRef("x".into()), CommonProps::default())))),
            ],
            common: CommonProps::default(),
            ..Default::default()
        }));
        assert!(subtree_has_reference(&group_with_ref));

        // A compound shape whose operand is a reference also has one.
        let compound_with_ref = Rc::new(Element::Live(LiveVariant::CompoundShape(CompoundShape {
            operation: CompoundOperation::Union,
            operands: vec![
                rc_rect(0.0, 0.0, 5.0, 5.0),
                Rc::new(Element::Live(LiveVariant::Reference(ReferenceElem::new(
                    ElementRef("x".into()), CommonProps::default())))),
            ],
            fill: None, stroke: None, common: CommonProps::default(),
        })));
        assert!(subtree_has_reference(&compound_with_ref));
    }

    #[test]
    fn pure_target_reference_is_cached_and_second_eval_hits() {
        // (a) A pure-geometry target (a plain rect) referenced by an instance:
        // first eval populates a Pure entry; a second eval at the same
        // generation + same target ptr reuses the cached geometry (gate
        // confirms cached == fresh) and the RESULT equals a fresh eval.
        clear_recompute_cache_for_test();
        set_recompute_cache_generation(7);

        let resolver = CellResolver::new();
        resolver.set("r1", rc_rect(0.0, 0.0, 10.0, 10.0));
        let reference = ReferenceElem::new(ElementRef("r1".into()), CommonProps::default());

        // Before any eval: no entry.
        assert!(recompute_cache_state_for_test("r1", DEFAULT_PRECISION).is_none());

        let mut v1 = VisitSet::new();
        let first = reference.evaluate_with(DEFAULT_PRECISION, &resolver, &mut v1);

        // After first eval: a Pure entry exists.
        assert_eq!(recompute_cache_state_for_test("r1", DEFAULT_PRECISION),
                   Some(CacheState::Pure));

        // Result equals a fresh eval of the resolved target.
        let target = resolver.resolve(&ElementRef("r1".into())).unwrap();
        assert_eq!(first, fresh_target_geom(&target, DEFAULT_PRECISION, &resolver));

        // Second eval hits the cache (gate fires: cached == fresh) and the
        // result is identical.
        let mut v2 = VisitSet::new();
        let second = reference.evaluate_with(DEFAULT_PRECISION, &resolver, &mut v2);
        assert_eq!(first, second, "second eval reuses cached geometry, same result");
        assert_eq!(recompute_cache_state_for_test("r1", DEFAULT_PRECISION),
                   Some(CacheState::Pure));
    }

    #[test]
    fn editing_target_new_generation_re_evaluates_no_stale() {
        // (b) Editing the target bumps the model generation; the epoch clears
        // the cache so the next eval recomputes against the NEW target. No
        // stale geometry survives.
        clear_recompute_cache_for_test();
        set_recompute_cache_generation(1);

        let resolver = CellResolver::new();
        resolver.set("r1", rc_rect(0.0, 0.0, 10.0, 10.0));
        let reference = ReferenceElem::new(ElementRef("r1".into()), CommonProps::default());

        let mut v1 = VisitSet::new();
        let before = reference.evaluate_with(DEFAULT_PRECISION, &resolver, &mut v1);
        let (_, _, bmaxx, _) = bbox_of_ring(&before[0]);
        assert!((bmaxx - 10.0).abs() < 1e-6);
        assert_eq!(recompute_cache_state_for_test("r1", DEFAULT_PRECISION),
                   Some(CacheState::Pure));

        // Edit: replace the target with a larger rect (a fresh Rc → new ptr)
        // AND advance the generation, as a real edit would.
        resolver.set("r1", rc_rect(0.0, 0.0, 40.0, 40.0));
        set_recompute_cache_generation(2);
        // The epoch bump cleared the cache.
        assert!(recompute_cache_state_for_test("r1", DEFAULT_PRECISION).is_none());

        let mut v2 = VisitSet::new();
        let after = reference.evaluate_with(DEFAULT_PRECISION, &resolver, &mut v2);
        let (_, _, amaxx, _) = bbox_of_ring(&after[0]);
        assert!((amaxx - 40.0).abs() < 1e-6, "re-evaluated against the EDITED target");
        // And it equals a fresh eval of the new target (no stale).
        let target = resolver.resolve(&ElementRef("r1".into())).unwrap();
        assert_eq!(after, fresh_target_geom(&target, DEFAULT_PRECISION, &resolver));
    }

    #[test]
    fn ref_containing_target_is_not_cached_and_tracks_nested_edits() {
        // (c) A target that CONTAINS a nested reference must NOT be cached as
        // Pure (its geometry depends on the nested target, which can change
        // with the same outer Rc ptr). It records HasRefs and re-resolves
        // fresh each time. We then change the NESTED target's geometry WITHOUT
        // bumping the generation; because the outer target is uncached, the
        // change is reflected — the stale-nested-ref hazard does NOT occur.
        clear_recompute_cache_for_test();
        set_recompute_cache_generation(5);

        let resolver = CellResolver::new();
        // Nested leaf target "x" — a 10x10 rect.
        resolver.set("x", rc_rect(0.0, 0.0, 10.0, 10.0));
        // Outer target "g" — a GROUP containing a reference to "x". Its Rc
        // never changes below, but its geometry depends on "x".
        let group_referencing_x = Rc::new(Element::Group(crate::geometry::element::GroupElem {
            children: vec![Rc::new(Element::Live(LiveVariant::Reference(
                ReferenceElem::new(ElementRef("x".into()), CommonProps::default()))))],
            common: CommonProps::default(),
            ..Default::default()
        }));
        resolver.set("g", group_referencing_x);

        // An instance pointing at the ref-containing target "g".
        let outer_ref = ReferenceElem::new(ElementRef("g".into()), CommonProps::default());

        let mut v1 = VisitSet::new();
        let first = outer_ref.evaluate_with(DEFAULT_PRECISION, &resolver, &mut v1);
        // The outer target was recorded as HasRefs (NOT cached as Pure).
        assert_eq!(recompute_cache_state_for_test("g", DEFAULT_PRECISION),
                   Some(CacheState::HasRefs));
        let (_, _, fmaxx, _) = bbox_of_ring(&first[0]);
        assert!((fmaxx - 10.0).abs() < 1e-6);

        // Mutate the NESTED target "x" WITHOUT bumping the generation. (This
        // is the stale hazard a (target_id, Rc::as_ptr) Pure cache on "g"
        // would suffer: "g"'s ptr is unchanged.)
        resolver.set("x", rc_rect(0.0, 0.0, 30.0, 30.0));

        let mut v2 = VisitSet::new();
        let second = outer_ref.evaluate_with(DEFAULT_PRECISION, &resolver, &mut v2);
        let (_, _, smaxx, _) = bbox_of_ring(&second[0]);
        assert!((smaxx - 30.0).abs() < 1e-6,
            "ref-containing target re-resolves: nested edit is reflected, not stale");
        // Still HasRefs, never promoted to Pure.
        assert_eq!(recompute_cache_state_for_test("g", DEFAULT_PRECISION),
                   Some(CacheState::HasRefs));
        // Equals a fresh eval of the (unchanged-ptr) outer target.
        let target = resolver.resolve(&ElementRef("g".into())).unwrap();
        assert_eq!(second, fresh_target_geom(&target, DEFAULT_PRECISION, &resolver));
    }

    #[test]
    fn instance_transform_composes_on_top_of_cached_pure_geometry() {
        // (d) The per-reference instance transform is applied AFTER the
        // (shared, cached) target geometry. A plain instance caches the
        // untransformed target; a scaled instance of the SAME target reuses
        // that cached geometry and applies its own transform on top.
        clear_recompute_cache_for_test();
        set_recompute_cache_generation(9);

        let resolver = CellResolver::new();
        resolver.set("r1", rc_rect(0.0, 0.0, 10.0, 10.0));

        // Plain instance populates the Pure cache with UNTRANSFORMED geometry.
        let plain = ReferenceElem::new(ElementRef("r1".into()), CommonProps::default());
        let mut v1 = VisitSet::new();
        let plain_ps = plain.evaluate_with(DEFAULT_PRECISION, &resolver, &mut v1);
        assert_eq!(recompute_cache_state_for_test("r1", DEFAULT_PRECISION),
                   Some(CacheState::Pure));
        let (_, _, pmaxx, pmaxy) = bbox_of_ring(&plain_ps[0]);
        assert!((pmaxx - 10.0).abs() < 1e-6 && (pmaxy - 10.0).abs() < 1e-6);

        // Scaled instance of the SAME target: hits the cached (untransformed)
        // geometry, then applies scale(2,2) on top.
        let mut scaled = ReferenceElem::new(ElementRef("r1".into()), CommonProps::default());
        scaled.transform = Some(crate::geometry::element::Transform::scale(2.0, 2.0));
        let mut v2 = VisitSet::new();
        let scaled_ps = scaled.evaluate_with(DEFAULT_PRECISION, &resolver, &mut v2);
        let (sminx, sminy, smaxx, smaxy) = bbox_of_ring(&scaled_ps[0]);
        assert!((sminx - 0.0).abs() < 1e-6 && (sminy - 0.0).abs() < 1e-6);
        assert!((smaxx - 20.0).abs() < 1e-6 && (smaxy - 20.0).abs() < 1e-6,
            "instance transform composes on top of the cached target geometry");

        // The cache still holds the UNTRANSFORMED geometry (Pure), shared.
        assert_eq!(recompute_cache_state_for_test("r1", DEFAULT_PRECISION),
                   Some(CacheState::Pure));
        // And the scaled result equals applying the transform to a fresh eval.
        let target = resolver.resolve(&ElementRef("r1".into())).unwrap();
        let fresh = fresh_target_geom(&target, DEFAULT_PRECISION, &resolver);
        let t = crate::geometry::element::Transform::scale(2.0, 2.0);
        let fresh_scaled: PolygonSet = fresh.into_iter()
            .map(|ring| ring.into_iter().map(|(x, y)| t.apply_point(x, y)).collect())
            .collect();
        assert_eq!(scaled_ps, fresh_scaled);
    }

    #[test]
    fn cache_keys_on_precision_so_two_render_passes_dont_collide() {
        // The two render passes use different precision (fill precision vs
        // DEFAULT_PRECISION). The cache key includes precision, so a circle
        // target tessellated at one precision never serves a request at
        // another precision (which would be a wrong-detail result).
        clear_recompute_cache_for_test();
        set_recompute_cache_generation(3);

        let resolver = CellResolver::new();
        resolver.set("c1", Rc::new(Element::Circle(crate::geometry::element::CircleElem {
            cx: 0.0, cy: 0.0, r: 100.0,
            fill: None, stroke: None, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        })));
        let reference = ReferenceElem::new(ElementRef("c1".into()), CommonProps::default());

        let coarse = 1.0;
        let fine = 0.01;

        let mut v1 = VisitSet::new();
        let ps_coarse = reference.evaluate_with(coarse, &resolver, &mut v1);
        let mut v2 = VisitSet::new();
        let ps_fine = reference.evaluate_with(fine, &resolver, &mut v2);

        // Distinct precisions tessellate to distinct ring lengths — they must
        // not have served each other from one cache slot.
        assert_ne!(ps_coarse[0].len(), ps_fine[0].len(),
            "different precision must produce different tessellation");
        // Both keys are live in the cache simultaneously.
        assert_eq!(recompute_cache_state_for_test("c1", coarse), Some(CacheState::Pure));
        assert_eq!(recompute_cache_state_for_test("c1", fine), Some(CacheState::Pure));

        // Each equals its own fresh eval.
        let target = resolver.resolve(&ElementRef("c1".into())).unwrap();
        assert_eq!(ps_coarse, fresh_target_geom(&target, coarse, &resolver));
        assert_eq!(ps_fine, fresh_target_geom(&target, fine, &resolver));
    }
}
