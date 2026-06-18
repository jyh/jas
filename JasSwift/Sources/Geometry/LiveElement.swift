import Foundation

// LiveElement framework: shared infrastructure for non-destructive
// element kinds that store source inputs and evaluate them on demand.
//
// CompoundShape is the first conformer (non-destructive boolean over
// an operand tree). Future Live Effects (drop shadow, blend, ...) add
// a case to `LiveVariant`; the top-level `Element` enum only ever
// grows one `.live(LiveVariant)` case.
//
// See `transcripts/BOOLEAN.md` § Live element framework.

// MARK: - Precision constant

/// Default geometric tolerance in points. Matches the `Precision`
/// default in the Boolean Options dialog (BOOLEAN.md). Equals 0.01 mm.
public let DEFAULT_PRECISION: Double = 0.0283

// MARK: - Reference resolution seam (REFERENCE_GRAPH.md §2.1)

/// A by-id reference to another element's stable id. Stable across
/// insert/delete (unlike a tree path); resolved through an
/// `ElementResolver`, never stored as a strong reference. `Comparable` is
/// load-bearing: deterministic recompute order derives from sorted ids,
/// never dictionary iteration order. Mirrors Rust `ElementRef`.
public struct ElementRef: Hashable, Comparable {
    public let id: String
    public init(_ id: String) { self.id = id }
    public static func < (lhs: ElementRef, rhs: ElementRef) -> Bool {
        lhs.id < rhs.id
    }
}

/// Resolves a stable element id to the element it currently names. Lets the
/// geometry layer evaluate by-id references without depending on
/// Model/Document. Phase 1 backs this with a rebuild-on-demand resolver; the
/// persistent-incremental index is Phase 4 (REFERENCE_GRAPH.md §2.4).
public protocol ElementResolver {
    func resolve(_ id: ElementRef) -> Element?
}

/// A resolver that resolves nothing. Used on the resolver-unaware call paths
/// (and wherever no live references are present) so existing geometry
/// behavior is unchanged: a reference resolved through it is treated as
/// dangling. Mirrors Rust `NullResolver`.
public struct NullResolver: ElementResolver {
    public init() {}
    public func resolve(_ id: ElementRef) -> Element? { nil }
}

/// The cycle-guard set threaded through evaluation. Carried as an explicit
/// parameter (never instance state) so all five apps break reference cycles
/// identically (REFERENCE_GRAPH.md §3). Mirrors Rust `VisitSet`.
public typealias VisitSet = Set<ElementRef>

// MARK: - BooleanOptions

/// Document-scoped boolean op settings. Mirrors Rust BooleanOptions
/// per BOOLEAN.md §Boolean Options dialog.
public struct BooleanOptions: Equatable {
    /// Geometric tolerance (points) used for curve flattening and
    /// collinear-point collapse.
    public let precision: Double
    /// If true, collapse collinear / near-duplicate points in output
    /// rings within [precision] of the line through their neighbors.
    public let removeRedundantPoints: Bool
    /// If true, DIVIDE drops fragments with no fill and no stroke.
    public let divideRemoveUnpainted: Bool

    public init(precision: Double = DEFAULT_PRECISION,
                removeRedundantPoints: Bool = true,
                divideRemoveUnpainted: Bool = false) {
        self.precision = precision
        self.removeRedundantPoints = removeRedundantPoints
        self.divideRemoveUnpainted = divideRemoveUnpainted
    }
}

/// Single-pass removal of points whose perpendicular distance to the
/// line between their two neighbors is below [tolerance]. Returns the
/// original ring when collapse would leave fewer than 3 points.
/// Matches the Rust collapse_collinear_points reference.
public func collapseCollinearPoints(
    _ ring: [(Double, Double)], tolerance: Double
) -> [(Double, Double)] {
    let n = ring.count
    guard n >= 3 else { return ring }
    var keep = [Bool](repeating: true, count: n)
    for i in 0..<n {
        let prev = ring[(i - 1 + n) % n]
        let cur = ring[i]
        let nxt = ring[(i + 1) % n]
        let dx = nxt.0 - prev.0
        let dy = nxt.1 - prev.1
        let segLen = (dx * dx + dy * dy).squareRoot()
        if segLen == 0.0 {
            keep[i] = false
            continue
        }
        let num = abs(dy * cur.0 - dx * cur.1 + nxt.0 * prev.1 - nxt.1 * prev.0)
        if num / segLen < tolerance {
            keep[i] = false
        }
    }
    let result = zip(ring, keep).compactMap { $1 ? $0 : nil }
    return result.count < 3 ? ring : result
}

// MARK: - CompoundShape

/// Which boolean operation a compound shape evaluates to. Only the
/// four Shape Mode operations can be compound.
public enum CompoundOperation: String, Equatable {
    case union
    case subtractFront = "subtract_front"
    case intersection
    case exclude
}

/// A live, non-destructive boolean element: stores the operation and
/// its operand tree; evaluates to a polygon set on demand.
/// See `transcripts/BOOLEAN.md` § Compound shape data model.
public struct CompoundShape: Equatable {
    public var operation: CompoundOperation
    public var operands: [Element]
    /// This compound's own stable id (the lazy assign-on-create slot).
    /// Mirrors Rust `CompoundShape.common.id` and Python's
    /// `CompoundShape.id`: `nil` until stamped by `Controller.assignId`.
    /// A compound is a first-class element that can be a reference target
    /// (REFERENCE_GRAPH.md §4); like `.reference`, `.live` has no flat
    /// `Element.id` slot, so the compound carries its identity here inline.
    /// No name field is intended for live elements.
    public var id: String?
    public var fill: Fill?
    public var stroke: Stroke?
    public var opacity: Double
    public var transform: Transform?
    public var locked: Bool
    public var visibility: Visibility
    public var blendMode: BlendMode
    public var mask: Mask?

    public init(
        operation: CompoundOperation,
        operands: [Element],
        id: String? = nil,
        fill: Fill? = nil,
        stroke: Stroke? = nil,
        opacity: Double = 1.0,
        transform: Transform? = nil,
        locked: Bool = false,
        visibility: Visibility = .preview,
        blendMode: BlendMode = .normal,
        mask: Mask? = nil
    ) {
        self.operation = operation
        self.operands = operands
        self.id = id
        self.fill = fill
        self.stroke = stroke
        self.opacity = opacity
        self.transform = transform
        self.locked = locked
        self.visibility = visibility
        self.blendMode = blendMode
        self.mask = mask
    }

    /// Evaluate the compound shape: flatten operands to polygon sets,
    /// apply the boolean operation, return the result.
    ///
    /// Convenience wrapper that resolves no references (a compound's
    /// operands are owned, not referenced); see ``evaluateWith`` for the
    /// resolver-aware form used when an operand subtree may contain by-id
    /// references.
    public func evaluate(precision: Double) -> BoolPolygonSet {
        var visiting = VisitSet()
        return evaluateWith(precision: precision, resolver: NullResolver(), visiting: &visiting)
    }

    /// Resolver-aware evaluation: flattens each operand (threading the
    /// resolver + cycle-guard set so a referenced operand resolves through
    /// `resolver`), then applies the boolean operation. Mirrors Rust
    /// `CompoundShape::evaluate_with`.
    public func evaluateWith(
        precision: Double, resolver: ElementResolver, visiting: inout VisitSet
    ) -> BoolPolygonSet {
        let operandSets = operands.map {
            elementToPolygonSetWith($0, precision: precision, resolver: resolver, visiting: &visiting)
        }
        return applyOperation(operation, operandSets)
    }

    /// Bounding box of the evaluated geometry.
    public var bounds: BBox {
        boundsOfPolygonSet(evaluate(precision: DEFAULT_PRECISION))
    }

    /// Replace the compound shape with Polygon elements derived
    /// from its evaluated geometry. Each polygon carries the
    /// compound shape's own fill / stroke / common props; rings
    /// with fewer than 3 points are dropped. See BOOLEAN.md §
    /// Expand and Release semantics.
    public func expand(precision: Double) -> [Element] {
        let ps = evaluate(precision: precision)
        return ps.compactMap { ring -> Element? in
            guard ring.count >= 3 else { return nil }
            return .polygon(Polygon(
                points: ring,
                fill: fill,
                stroke: stroke,
                opacity: opacity,
                transform: transform,
                locked: locked,
                visibility: visibility
            ))
        }
    }

    /// Inverse of Make. Returns the operand list verbatim; each
    /// keeps its own paint, compound-shape paint is discarded.
    public func release() -> [Element] { operands }
}

// MARK: - ReferenceElem — by-id reference (REFERENCE_GRAPH.md §1.1)

/// A live element that evaluates to another element's geometry, resolved by
/// stable id at evaluate time — the "instance of" primitive (mirrored eyes,
/// connector-follows-block). Its target is named by id, not embedded, so it
/// is a `dependencies()` edge rather than a `children()`/operands input.
/// Mirrors Rust `ReferenceElem`.
public struct ReferenceElem: Equatable {
    /// Stable id of the referenced element.
    public var target: ElementRef
    /// This reference's own stable id (the lazy assign-on-create slot).
    /// Mirrors Rust `ReferenceElem.common.id`: `nil` until the reference is
    /// created with an explicit id by `Controller.createReference`. Unlike
    /// the other element kinds, `.live` has no flat `Element.id` slot, so a
    /// reference carries its identity here inline (matching how it carries
    /// the rest of its common props).
    public var id: String?
    /// The render CTM (Rust's `common.transform`): a whole-element move /
    /// rotate / scale that rides the render layer only. Set by moveSelection /
    /// translated; serialized as the `transform` key. Distinct from
    /// `instanceTransform`.
    public var transform: Transform?
    /// The instance `transform` field (Symbols P4, SYMBOLS.md §4 / Fork F2):
    /// an affine applied to the RESOLVED geometry at eval time, so an instance
    /// can be mirrored/scaled relative to its shared master. Distinct from the
    /// render CTM (`transform`); the render composition is
    /// `transform` (CTM) ∘ `instanceTransform` (eval) ∘ target. Serialized as
    /// the separate `instance_transform` key. `nil` ⇒ geometry unchanged.
    public var instanceTransform: Transform?
    /// Own paint; `nil` inherits the resolved target's paint (Fork F3).
    public var fill: Fill?
    public var stroke: Stroke?
    // Common props carried inline, mirroring CompoundShape's layout.
    public var opacity: Double
    public var locked: Bool
    public var visibility: Visibility
    public var blendMode: BlendMode
    public var mask: Mask?

    public init(
        target: ElementRef,
        id: String? = nil,
        transform: Transform? = nil,
        instanceTransform: Transform? = nil,
        fill: Fill? = nil,
        stroke: Stroke? = nil,
        opacity: Double = 1.0,
        locked: Bool = false,
        visibility: Visibility = .preview,
        blendMode: BlendMode = .normal,
        mask: Mask? = nil
    ) {
        self.target = target
        self.id = id
        self.transform = transform
        self.instanceTransform = instanceTransform
        self.fill = fill
        self.stroke = stroke
        self.opacity = opacity
        self.locked = locked
        self.visibility = visibility
        self.blendMode = blendMode
        self.mask = mask
    }

    /// Stable-id inputs reached by reference rather than containment. A
    /// reference's only dependency is its target. Mirrors Rust
    /// `dependencies()`.
    public var dependencies: [ElementRef] { [target] }

    /// Resolver-aware evaluation: resolve the target and return its
    /// geometry. A cycle (target already being visited) or a dangling
    /// reference (unresolved) yields an empty set — never a trap
    /// (REFERENCE_GRAPH.md §3). Mirrors Rust `ReferenceElem::evaluate_with`.
    public func evaluateWith(
        precision: Double, resolver: ElementResolver, visiting: inout VisitSet
    ) -> BoolPolygonSet {
        if visiting.contains(target) {
            return []  // cycle: break at the re-entry edge
        }
        guard let resolved = resolver.resolve(target) else {
            return []  // dangling: target not found
        }
        visiting.insert(target)
        // Phase 4c: obtain the resolved target's UNTRANSFORMED geometry through
        // the recompute cache (shared across all references to this target;
        // cached only for pure-geometry targets). The per-reference instance
        // transform is applied AFTER, below.
        let ps = cachedTargetGeometry(
            targetId: target.id, target: resolved, precision: precision,
            resolver: resolver, visiting: &visiting)
        visiting.remove(target)
        // Symbols P4 (SYMBOLS.md §4 / Fork F2): the instance `transform` field
        // (distinct from the render CTM, which renders as `transform`) is
        // applied to the resolved geometry here, so an instance can be
        // mirrored/scaled relative to its master. This single seam covers every
        // consumer of the resolved set — both render sites, polygon-set, and
        // compound-operand use. nil ⇒ return the geometry unchanged (no
        // transform, no double-apply).
        guard let t = instanceTransform else { return ps }
        return ps.map { ring in
            ring.map { (x, y) in t.applyPoint(x, y) }
        }
    }
}

// MARK: - RecordedElem — history-based (recorded) LiveKind (RECORDED_ELEMENTS.md)

/// A recorded (history-based) live element (RECORDED_ELEMENTS.md): a normalized,
/// input-addressed op-segment captured from the journal, replayed against the
/// *current* inputs to produce derived geometry. Edit a source input and the
/// derivative re-derives live. Output ids are derived deterministically from
/// (this element's own id + a position-in-trace counter), never minted, so
/// replay keeps stable output identity (OP_LOG.md §7 / RECORDED_ELEMENTS.md §5).
/// Mirrors Rust `RecordedElem`.
///
/// The recipe draws from a replay-safe subset of the op vocabulary (input-
/// addressed, side-effect-free). 3b-A.1 supports `copy` (clone inputs at an
/// offset, producing the output) and `translate` (move named working elements);
/// further verbs (reflect/transform) extend the same replay.
///
/// Common props are carried inline (id/opacity/transform/locked/visibility/...),
/// matching ``ReferenceElem``'s layout, since `.live` has no flat `Element.id`
/// slot.
public struct RecordedElem: Equatable {
    /// The normalized, input-addressed recipe ops, replayed verbatim in order.
    public var ops: [PrimitiveOp]
    /// Source element ids the recipe rebinds against (by stable id).
    public var inputs: [ElementRef]
    /// Own paint; `nil` inherits nothing (a recorded element derives its own
    /// geometry, so paint is its own — like a compound, not a reference).
    public var fill: Fill?
    public var stroke: Stroke?
    // Common props carried inline, mirroring ReferenceElem's layout.
    public var id: String?
    public var transform: Transform?
    public var opacity: Double
    public var locked: Bool
    public var visibility: Visibility
    public var blendMode: BlendMode
    public var mask: Mask?

    public init(
        ops: [PrimitiveOp],
        inputs: [ElementRef],
        fill: Fill? = nil,
        stroke: Stroke? = nil,
        id: String? = nil,
        transform: Transform? = nil,
        opacity: Double = 1.0,
        locked: Bool = false,
        visibility: Visibility = .preview,
        blendMode: BlendMode = .normal,
        mask: Mask? = nil
    ) {
        self.ops = ops
        self.inputs = inputs
        self.fill = fill
        self.stroke = stroke
        self.id = id
        self.transform = transform
        self.opacity = opacity
        self.locked = locked
        self.visibility = visibility
        self.blendMode = blendMode
        self.mask = mask
    }

    /// Stable-id inputs reached by reference rather than containment, in
    /// deterministic order — the recipe's input ids (by-id edges), like a
    /// reference's target. Mirrors Rust `dependencies()`.
    public var dependencies: [ElementRef] { inputs }

    /// Manual `Equatable`: `PrimitiveOp.params` is `[String: Any]` (not
    /// `Equatable`), so the recipe ops are compared by their canonical JSON
    /// (the same deterministic serialization the test_json codec emits), and
    /// every other field structurally. Lets `RecordedElem` / `LiveVariant` /
    /// `Element` stay `Equatable` like the other live kinds.
    public static func == (lhs: RecordedElem, rhs: RecordedElem) -> Bool {
        lhs.inputs == rhs.inputs
            && lhs.fill == rhs.fill
            && lhs.stroke == rhs.stroke
            && lhs.id == rhs.id
            && lhs.transform == rhs.transform
            && lhs.opacity == rhs.opacity
            && lhs.locked == rhs.locked
            && lhs.visibility == rhs.visibility
            && lhs.blendMode == rhs.blendMode
            && lhs.mask == rhs.mask
            && recordedOpsCanonical(lhs.ops) == recordedOpsCanonical(rhs.ops)
    }

    /// Replay the recipe against the resolved inputs and return the derived
    /// output geometry. A dangling input or a cycle (an input already being
    /// visited) yields an empty set — never a trap (REFERENCE_GRAPH.md §3).
    /// Replay is a pure, deterministic function of the inputs (OP_LOG.md §7).
    /// Mirrors Rust `RecordedElem::evaluate_with`.
    public func evaluateWith(
        precision: Double, resolver: ElementResolver, visiting: inout VisitSet
    ) -> BoolPolygonSet {
        // Resolve inputs into a working set keyed by stable id. A cycle breaks
        // to empty at the re-entry edge; a dangling input yields empty.
        var working: [String: Element] = [:]
        for input in inputs {
            if visiting.contains(input) {
                return []
            }
            guard let el = resolver.resolve(input) else {
                return []  // dangling: input not found
            }
            working[input.id] = el
        }
        // Replay. Derived (produced) elements are keyed by a capture-stable
        // production-index handle `$n`, so the recipe is independent of this
        // element's own id (the recipe is portable across re-id). Geometry
        // replay here needs only the internal handle.
        var outputIds: [String] = []
        var counter = 0
        for op in ops {
            switch op.op {
            case "copy":
                let dx = recordedNum(op.params, "dx")
                let dy = recordedNum(op.params, "dy")
                for src in recordedStrIds(op.params, "from") {
                    if let el = working[src] {
                        let derivedId = "$\(counter)"
                        counter += 1
                        let copy = el.translated(dx: dx, dy: dy)
                        working[derivedId] = copy
                        outputIds.append(derivedId)
                    }
                }
            case "translate":
                let dx = recordedNum(op.params, "dx")
                let dy = recordedNum(op.params, "dy")
                for elemId in recordedStrIds(op.params, "ids") {
                    if let el = working[elemId] {
                        working[elemId] = el.translated(dx: dx, dy: dy)
                    }
                }
            default:
                break  // outside the replay-safe subset: skip
            }
        }
        // Output = the derived elements' geometry, in derivation order.
        var out: BoolPolygonSet = []
        for elemId in outputIds {
            if let el = working[elemId] {
                out.append(contentsOf: elementToPolygonSet(el, precision: precision))
            }
        }
        return out
    }
}

/// Read a numeric recipe-param value (`dx` / `dy`) from a `[String: Any]`
/// op-params dict, defaulting to 0. Mirrors the Rust `num` closure in
/// `evaluate_with` / `capture_recipe`.
func recordedNum(_ params: [String: Any], _ key: String) -> Double {
    if let n = params[key] as? NSNumber { return n.doubleValue }
    if let d = params[key] as? Double { return d }
    if let i = params[key] as? Int { return Double(i) }
    return 0.0
}

/// Read a string-id array recipe-param (`from` / `ids`) from a `[String: Any]`
/// op-params dict. Mirrors the Rust `str_ids` closure in `evaluate_with`.
func recordedStrIds(_ params: [String: Any], _ key: String) -> [String] {
    guard let arr = params[key] as? [Any] else { return [] }
    return arr.compactMap { $0 as? String }
}

/// Canonical-JSON float formatting for recorded recipes: 4-decimal rounding,
/// always a decimal point, trailing zeros stripped. Mirrors the `fmt` used by
/// the test_json codec so a recorded element's recipe `params` serialize
/// byte-identically (RECORDED_ELEMENTS.md §8 / OP_LOG.md §5 canonicalization).
private func recordedFmt(_ v: Double) -> String {
    let rounded = (v * 10000.0).rounded() / 10000.0
    if rounded == rounded.rounded(.towardZero) && rounded.truncatingRemainder(dividingBy: 1) == 0 {
        return String(format: "%.1f", rounded)
    }
    var s = String(format: "%.4f", rounded)
    while s.hasSuffix("0") && !s.hasSuffix(".0") {
        s.removeLast()
    }
    return s
}

/// Canonical JSON of an arbitrary recipe-param value (sorted object keys, fixed
/// floats, quoted strings), so a recorded element's recipe `params` serialize
/// byte-identically across the four native apps. Mirrors Rust `canonical_value`
/// in `test_json.rs`. `[String: Any]` params come from the harness / fixtures;
/// the value subset is null / bool / number / string / array / object.
func canonicalRecordedValue(_ v: Any) -> String {
    switch v {
    case is NSNull:
        return "null"
    case let b as Bool where (v as? NSNumber)?.isBool == true:
        return b ? "true" : "false"
    case let n as NSNumber:
        // NSNumber backs Bool, Int, and Double from JSONSerialization /
        // dictionary literals; route booleans first (above), the rest as floats.
        if n.isBool { return n.boolValue ? "true" : "false" }
        return recordedFmt(n.doubleValue)
    case let d as Double:
        return recordedFmt(d)
    case let i as Int:
        return recordedFmt(Double(i))
    case let s as String:
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    case let arr as [Any]:
        return "[\(arr.map(canonicalRecordedValue).joined(separator: ","))]"
    case let obj as [String: Any]:
        let keys = obj.keys.sorted()
        let entries = keys.map { k -> String in
            let escaped = k.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\":\(canonicalRecordedValue(obj[k]!))"
        }
        return "{\(entries.joined(separator: ","))}"
    default:
        return "null"
    }
}

/// Canonical JSON of a single recipe op: `{op, params, targets}` with sorted
/// params keys. Mirrors the Rust op emitter in `element_json`.
func canonicalRecordedOp(_ op: PrimitiveOp) -> String {
    let targets = op.targets.map { "\"\($0)\"" }.joined(separator: ",")
    let opEscaped = op.op.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
    return "{\"op\":\"\(opEscaped)\",\"params\":\(canonicalRecordedValue(op.params))," +
        "\"targets\":[\(targets)]}"
}

/// Canonical JSON array of a recipe op list (used by serialization + the
/// `RecordedElem` `==`).
func recordedOpsCanonical(_ ops: [PrimitiveOp]) -> String {
    "[\(ops.map(canonicalRecordedOp).joined(separator: ","))]"
}

/// True iff this `NSNumber` actually backs a `Bool` (so `1` is not mistaken for
/// `true`). `JSONSerialization` boxes JSON booleans as the tagged
/// `__NSCFBoolean`, whose `objCType` is `c`; numeric values use other tags.
extension NSNumber {
    var isBool: Bool {
        CFGetTypeID(self) == CFBooleanGetTypeID()
    }
}

/// Normalize a captured journal op-segment into a recorded recipe
/// (RECORDED_ELEMENTS.md §1/§4): rewrite selection-relative ops into the
/// input-addressed form by tracking the working selection as recipe refs.
/// Mirrors Rust `capture_recipe`.
///
/// - A select op (`select_rect`/`select`) establishes the working selection from
///   its resolved `targets` (the ids it selected); it is NOT emitted — selection
///   becomes input-addressing.
/// - `copy_selection` emits `copy{from, dx, dy}` (source = the working selection)
///   and rebinds the selection to the produced `$n` handles.
/// - `move_selection` emits `translate{ids, dx, dy}` on the working selection.
/// - Ops outside the replay-safe subset are dropped from the recipe.
///
/// The recipe's non-`$` refs are the **inputs** — the elements it rebinds by
/// stable id (the deterministic "everything that traces to a read input rebinds;
/// produced elements are `$n` handles" MVP rule; no AI fitter). Returns
/// `(recipe, inputIds)`; the caller wraps them in a ``RecordedElem``.
public func captureRecipe(_ segment: [PrimitiveOp]) -> (recipe: [PrimitiveOp], inputs: [String]) {
    var working: [String] = []
    var recipe: [PrimitiveOp] = []
    var counter = 0
    for op in segment {
        switch op.op {
        case "select_rect", "select":
            working = op.targets
        case "copy_selection":
            let dx = recordedNum(op.params, "dx")
            let dy = recordedNum(op.params, "dy")
            recipe.append(PrimitiveOp(
                op: "copy",
                params: ["from": working, "dx": dx, "dy": dy],
                targets: []))
            var produced: [String] = []
            for _ in working {
                produced.append("$\(counter)")
                counter += 1
            }
            working = produced
        case "move_selection":
            let dx = recordedNum(op.params, "dx")
            let dy = recordedNum(op.params, "dy")
            recipe.append(PrimitiveOp(
                op: "translate",
                params: ["ids": working, "dx": dx, "dy": dy],
                targets: []))
        default:
            break
        }
    }
    // Inputs = the distinct non-`$` refs the recipe rebinds, in first-seen order.
    var inputs: [String] = []
    for op in recipe {
        for key in ["from", "ids"] {
            for r in recordedStrIds(op.params, key) {
                if !r.hasPrefix("$") && !inputs.contains(r) {
                    inputs.append(r)
                }
            }
        }
    }
    return (recipe, inputs)
}

// MARK: - Reference-geometry recompute cache (REFERENCE_GRAPH.md §2.4 Phase 4c)
//
// PER-APP PERF CACHE. §2.3 lets the cache strategy differ per app; equivalence
// is pinned on resolve() RESULTS, which this never alters (gated by `assert` on
// every pure hit). Mirrors the Rust Phase-4c cache in `live.rs`, adapted to
// this app's Option-B index strategy.
//
// What is cached: the RESOLVED TARGET's UNTRANSFORMED geometry —
// `elementToPolygonSetWith(target, ...)`. Shared across every reference that
// names the same target, so the key is the TARGET (its id + the precision it
// was tessellated at), never the reference. The per-reference instance
// transform is applied AFTER the cached geometry, in `evaluateWith`.
//
// Why pure-geometry only (the crux): a target whose subtree contains a
// reference has geometry that depends on the nested target AND on the ambient
// cycle-guard (`visiting`) state, so it is never safe to share. Caching ONLY
// targets whose subtree contains NO reference (`subtreeHasReference` is false)
// makes the geometry a pure function of the target's own content at this
// generation. Ref-containing targets fall through to exact uncached eval
// (recorded `.hasRefs` so a repeat lookup skips the purity walk but never
// serves cached geometry).
//
// Divergence from Rust (allowed by §2.3): Rust additionally keys on the
// target's `Rc::as_ptr` (it pairs with the Rust-only incremental Rc-diff
// index). This app rebuilds the index at the mutation chokepoint (Option B),
// so within a generation the document is immutable and id -> geometry is fixed;
// the generation epoch alone is the complete signal, and there is no
// pointer-identity check (Element is a value type — there is none to check).
// The per-hit `assert(cached == fresh)` proves it.
//
// Lifetime + invalidation: a module-global cache that PERSISTS across paints,
// so no-edit repaints (pan / zoom / hover, plus the fill + selection-trace
// passes) reuse it. It is generation-epoched off `Model.generation`, bumped on
// every mutation / undo / redo; `setRecomputeCacheGeneration` (the paint entry)
// clears all entries whenever the generation changes. Precision is part of the
// key (the two render passes may use different precision; coarse vs fine are
// different geometry).

/// Observable cache state for a `(targetId, precision)` slot, for tests:
/// `.pure` (geometry cached), `.hasRefs` (recorded uncacheable), or `nil`
/// (no entry).
enum RecomputeCacheState: Equatable { case pure, hasRefs }

/// One cache slot. `.pure` holds the target's untransformed geometry, valid for
/// the current epoch. `.hasRefs` records that the target's subtree contains a
/// nested reference, so its geometry is NOT cacheable; it only short-circuits
/// the purity walk on a repeat lookup — it never serves geometry.
private enum RecomputeCacheEntry {
    case pure(BoolPolygonSet)
    case hasRefs
}

private struct RecomputeKey: Hashable {
    let id: String
    let precisionBits: UInt64
}

// THREAD-LOCAL storage, mirroring Rust's `thread_local! RECOMPUTE_CACHE`. The
// production render path is single-threaded (the cache persists across paints
// on the render thread); per-thread storage additionally isolates the parallel
// test runner so concurrent tests neither data-race the dictionary nor share
// cache entries. The box is created lazily per thread and reused thereafter.
private final class RecomputeCacheBox {
    var generation: UInt64 = 0
    var entries: [RecomputeKey: RecomputeCacheEntry] = [:]
}

private let recomputeCacheThreadKey = "JasLib.RecomputeCache"

private func recomputeCacheBox() -> RecomputeCacheBox {
    let dict = Thread.current.threadDictionary
    if let box = dict[recomputeCacheThreadKey] as? RecomputeCacheBox { return box }
    let box = RecomputeCacheBox()
    dict[recomputeCacheThreadKey] = box
    return box
}

/// Generation-epoch the recompute cache: if `generation` differs from the
/// current epoch, clear every entry and adopt the new epoch. Called at the
/// paint entry with `Model.generation` (bumped on every mutation / undo /
/// redo), so this drops the cache on any edit while preserving it across
/// no-edit repaints.
func setRecomputeCacheGeneration(_ generation: UInt64) {
    let box = recomputeCacheBox()
    if box.generation != generation {
        box.entries.removeAll(keepingCapacity: true)
        box.generation = generation
    }
}

/// True iff `elem`'s OWNED subtree contains a reference anywhere — the purity
/// test deciding whether a target's geometry may be cached. Recurses group /
/// layer children and compound-shape operands (every containment edge
/// `elementToPolygonSetWith` itself descends). A reference reached by-id is NOT
/// part of the owned subtree, so this detects a reference at its own node, it
/// never follows one. Mirrors Rust `subtree_has_reference`.
func subtreeHasReference(_ elem: Element) -> Bool {
    switch elem {
    case .live(.reference):
        return true
    case .live(.compoundShape(let cs)):
        return cs.operands.contains(where: subtreeHasReference)
    case .group(let g):
        return g.children.contains(where: subtreeHasReference)
    case .layer(let l):
        return l.children.contains(where: subtreeHasReference)
    default:
        return false
    }
}

/// Exact polygon-set equality (a `BoolRing` is `[(Double, Double)]`; tuples are
/// not `Equatable`, so compare element-wise). Used only by the gate, where
/// cached and fresh are computed by the same function on the same input, so the
/// comparison is bit-exact.
func boolPolygonSetsEqual(_ a: BoolPolygonSet, _ b: BoolPolygonSet) -> Bool {
    guard a.count == b.count else { return false }
    for (ra, rb) in zip(a, b) {
        guard ra.count == rb.count else { return false }
        for (pa, pb) in zip(ra, rb) {
            if pa.0 != pb.0 || pa.1 != pb.1 { return false }
        }
    }
    return true
}

/// Obtain the resolved target's UNTRANSFORMED geometry via the recompute cache.
/// Caches only pure-geometry targets (no nested reference); ref-containing
/// targets are evaluated fresh every time (recorded `.hasRefs`). The
/// per-reference instance transform is applied by the caller AFTER this returns.
///
/// Correctness gate: on every `.pure` hit, `assert(cached == fresh)` (mirroring
/// the Phase-4b `idIndex == rebuildIdIndex` assert). The fresh eval is inside
/// the `assert` autoclosure, so it runs only in debug (the whole test suite
/// runs in debug); zero release-build cost.
func cachedTargetGeometry(
    targetId: String, target: Element, precision: Double,
    resolver: ElementResolver, visiting: inout VisitSet
) -> BoolPolygonSet {
    let box = recomputeCacheBox()
    let key = RecomputeKey(id: targetId, precisionBits: precision.bitPattern)
    switch box.entries[key] {
    case .pure(let geom):
        assert({
            var freshVisit = VisitSet()
            let fresh = elementToPolygonSetWith(
                target, precision: precision, resolver: resolver, visiting: &freshVisit)
            return boolPolygonSetsEqual(geom, fresh)
        }(), "reference geometry recompute cache diverged from fresh eval")
        return geom
    case .hasRefs:
        // Target contains a nested reference: never serve cached geometry.
        return elementToPolygonSetWith(
            target, precision: precision, resolver: resolver, visiting: &visiting)
    case nil:
        // Cache miss: evaluate fresh, then record by purity.
        let fresh = elementToPolygonSetWith(
            target, precision: precision, resolver: resolver, visiting: &visiting)
        box.entries[key] = subtreeHasReference(target) ? .hasRefs : .pure(fresh)
        return fresh
    }
}

/// Test/introspection: the cache state for `(targetId, precision)`, or `nil`
/// if no entry exists.
func recomputeCacheStateForTest(_ targetId: String, _ precision: Double) -> RecomputeCacheState? {
    switch recomputeCacheBox().entries[RecomputeKey(id: targetId, precisionBits: precision.bitPattern)] {
    case .pure: return .pure
    case .hasRefs: return .hasRefs
    case nil: return nil
    }
}

/// Test-only: drop all recompute-cache entries and reset the epoch to 0, so
/// each focused test starts from an empty cache.
func clearRecomputeCacheForTest() {
    let box = recomputeCacheBox()
    box.entries.removeAll()
    box.generation = 0
}

// MARK: - Geometry helpers

/// Flatten a document element into a polygon set suitable for the
/// boolean algorithm. See BOOLEAN.md § Geometry and precision.
///
/// Convenience wrapper that resolves no references; see
/// ``elementToPolygonSetWith`` for the resolver-aware form. Existing call
/// sites that pass no resolver are behavior-identical.
public func elementToPolygonSet(_ elem: Element, precision: Double) -> BoolPolygonSet {
    var visiting = VisitSet()
    return elementToPolygonSetWith(elem, precision: precision, resolver: NullResolver(), visiting: &visiting)
}

/// Resolver-aware flattening. Identical to ``elementToPolygonSet`` except
/// that by-id references resolve through `resolver`, with `visiting`
/// breaking cycles. Mirrors Rust `element_to_polygon_set_with`.
public func elementToPolygonSetWith(
    _ elem: Element, precision: Double, resolver: ElementResolver, visiting: inout VisitSet
) -> BoolPolygonSet {
    switch elem {
    case .rect(let r):
        return [[
            (r.x, r.y),
            (r.x + r.width, r.y),
            (r.x + r.width, r.y + r.height),
            (r.x, r.y + r.height),
        ]]
    case .polygon(let p):
        return p.points.isEmpty ? [] : [p.points]
    case .polyline(let p):
        // Implicitly closed for even-odd fill.
        return p.points.isEmpty ? [] : [p.points]
    case .circle(let c):
        return [circleToRing(cx: c.cx, cy: c.cy, r: c.r, precision: precision)]
    case .ellipse(let e):
        return [ellipseToRing(cx: e.cx, cy: e.cy, rx: e.rx, ry: e.ry, precision: precision)]
    case .group(let g):
        return g.children.flatMap {
            elementToPolygonSetWith($0, precision: precision, resolver: resolver, visiting: &visiting)
        }
    case .layer(let l):
        return l.children.flatMap {
            elementToPolygonSetWith($0, precision: precision, resolver: resolver, visiting: &visiting)
        }
    case .live(let v):
        switch v {
        case .compoundShape(let cs):
            return cs.evaluateWith(precision: precision, resolver: resolver, visiting: &visiting)
        case .reference(let r):
            return r.evaluateWith(precision: precision, resolver: resolver, visiting: &visiting)
        case .recorded(let rec):
            return rec.evaluateWith(precision: precision, resolver: resolver, visiting: &visiting)
        }
    case .path(let p):
        return flattenPathToRings(p.d)
    case .textPath(let tp):
        return flattenPathToRings(tp.d)
    case .line, .text:
        // Line has zero area; Text glyph flattening is deferred.
        return []
    }
}

/// Dispatch a boolean operation across an arbitrary number of operands.
public func applyOperation(
    _ op: CompoundOperation, _ operandSets: [BoolPolygonSet]
) -> BoolPolygonSet {
    guard !operandSets.isEmpty else { return [] }
    switch op {
    case .union:
        return operandSets.dropFirst().reduce(operandSets[0]) { acc, b in
            booleanUnion(acc, b)
        }
    case .intersection:
        return operandSets.dropFirst().reduce(operandSets[0]) { acc, b in
            booleanIntersect(acc, b)
        }
    case .subtractFront:
        if operandSets.count < 2 { return operandSets[0] }
        let cutter = operandSets.last!
        let survivors = operandSets.dropLast()
        return survivors.reduce([]) { acc, s in
            booleanUnion(acc, booleanSubtract(s, cutter))
        }
    case .exclude:
        return operandSets.dropFirst().reduce(operandSets[0]) { acc, b in
            booleanExclude(acc, b)
        }
    }
}

/// Tight bounding box of a polygon set. Returns (0, 0, 0, 0) for empty.
public func boundsOfPolygonSet(_ ps: BoolPolygonSet) -> BBox {
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity
    for ring in ps {
        for (x, y) in ring {
            if x < minX { minX = x }
            if y < minY { minY = y }
            if x > maxX { maxX = x }
            if y > maxY { maxY = y }
        }
    }
    guard minX.isFinite else { return (0, 0, 0, 0) }
    return (minX, minY, maxX - minX, maxY - minY)
}

// MARK: - Internal ring samplers

private func segmentsForArc(radius: Double, precision: Double) -> Int {
    guard radius > 0, precision > 0 else { return 32 }
    let n = Double.pi * (radius / (2.0 * precision)).squareRoot()
    return max(8, Int(n.rounded(.up)))
}

private func circleToRing(cx: Double, cy: Double, r: Double, precision: Double) -> BoolRing {
    let n = segmentsForArc(radius: r, precision: precision)
    return (0..<n).map { i in
        let theta = 2.0 * Double.pi * Double(i) / Double(n)
        return (cx + r * cos(theta), cy + r * sin(theta))
    }
}

private func ellipseToRing(cx: Double, cy: Double, rx: Double, ry: Double, precision: Double) -> BoolRing {
    let n = segmentsForArc(radius: max(rx, ry), precision: precision)
    return (0..<n).map { i in
        let theta = 2.0 * Double.pi * Double(i) / Double(n)
        return (cx + rx * cos(theta), cy + ry * sin(theta))
    }
}

/// Ring-aware path flattening. MoveTo starts a new ring; ClosePath
/// finalizes. Open subpaths finalize at next MoveTo or end. Rings
/// with fewer than 3 points are dropped. Bezier / quad segments use
/// 20 steps; Smooth / Arc approximate as line-to-endpoint.
public func flattenPathToRings(_ d: [PathCommand]) -> BoolPolygonSet {
    let steps = 20
    var rings: BoolPolygonSet = []
    var cur: BoolRing = []
    var cx: Double = 0, cy: Double = 0

    func flush() {
        if cur.count >= 3 { rings.append(cur) }
        cur = []
    }

    for cmd in d {
        switch cmd {
        case .moveTo(let x, let y):
            flush()
            cur.append((x, y))
            cx = x; cy = y
        case .lineTo(let x, let y):
            cur.append((x, y))
            cx = x; cy = y
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let mt = 1 - t
                let px = mt*mt*mt*cx + 3*mt*mt*t*x1 + 3*mt*t*t*x2 + t*t*t*x
                let py = mt*mt*mt*cy + 3*mt*mt*t*y1 + 3*mt*t*t*y2 + t*t*t*y
                cur.append((px, py))
            }
            cx = x; cy = y
        case .quadTo(let x1, let y1, let x, let y):
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let mt = 1 - t
                let px = mt*mt*cx + 2*mt*t*x1 + t*t*x
                let py = mt*mt*cy + 2*mt*t*y1 + t*t*y
                cur.append((px, py))
            }
            cx = x; cy = y
        case .closePath:
            flush()
        case .smoothCurveTo(_, _, let x, let y),
             .smoothQuadTo(let x, let y),
             .arcTo(_, _, _, _, _, let x, let y):
            cur.append((x, y))
            cx = x; cy = y
        }
    }
    flush()
    return rings
}

// MARK: - LiveVariant

/// Closed-world enum over all known LiveKinds. Adding a new kind adds
/// one case here; the top-level `Element` enum only ever has one
/// `.live(LiveVariant)` case.
public enum LiveVariant: Equatable {
    case compoundShape(CompoundShape)
    case reference(ReferenceElem)
    case recorded(RecordedElem)

    public var kind: String {
        switch self {
        case .compoundShape: return "compound_shape"
        case .reference: return "reference"
        case .recorded: return "recorded"
        }
    }

    public var kindSchemaVersion: Int {
        switch self {
        case .compoundShape: return 1
        case .reference: return 1
        case .recorded: return 1
        }
    }

    /// This live element's own stable id. Both conformers carry their
    /// identity inline (CompoundShape.id / ReferenceElem.id) since `.live`
    /// has no flat `Element.id` slot. Mirrors how the reference's
    /// `common.id` flows through the generic id machinery in Rust/Python.
    public var id: String? {
        switch self {
        case .compoundShape(let cs): return cs.id
        case .reference(let r): return r.id
        case .recorded(let rec): return rec.id
        }
    }

    public var fill: Fill? {
        switch self {
        case .compoundShape(let cs): return cs.fill
        case .reference(let r): return r.fill
        case .recorded(let rec): return rec.fill
        }
    }

    public var stroke: Stroke? {
        switch self {
        case .compoundShape(let cs): return cs.stroke
        case .reference(let r): return r.stroke
        case .recorded(let rec): return rec.stroke
        }
    }

    public var opacity: Double {
        switch self {
        case .compoundShape(let cs): return cs.opacity
        case .reference(let r): return r.opacity
        case .recorded(let rec): return rec.opacity
        }
    }

    public var transform: Transform? {
        switch self {
        case .compoundShape(let cs): return cs.transform
        case .reference(let r): return r.transform
        case .recorded(let rec): return rec.transform
        }
    }

    public var locked: Bool {
        switch self {
        case .compoundShape(let cs): return cs.locked
        case .reference(let r): return r.locked
        case .recorded(let rec): return rec.locked
        }
    }

    public var visibility: Visibility {
        switch self {
        case .compoundShape(let cs): return cs.visibility
        case .reference(let r): return r.visibility
        case .recorded(let rec): return rec.visibility
        }
    }

    public var blendMode: BlendMode {
        switch self {
        case .compoundShape(let cs): return cs.blendMode
        case .reference(let r): return r.blendMode
        case .recorded(let rec): return rec.blendMode
        }
    }

    public var mask: Mask? {
        switch self {
        case .compoundShape(let cs): return cs.mask
        case .reference(let r): return r.mask
        case .recorded(let rec): return rec.mask
        }
    }

    public var operands: [Element] {
        switch self {
        case .compoundShape(let cs): return cs.operands
        // A reference owns no children; its target is a dependency edge.
        case .reference: return []
        // A recorded element owns no children; its inputs are by-id edges.
        case .recorded: return []
        }
    }

    /// Stable-id inputs reached by reference rather than containment, in
    /// deterministic order. Default empty for containment kinds (compound
    /// shape owns its operands); the reference reports its target, the
    /// recorded element its recipe inputs. Mirrors Rust
    /// `LiveElement::dependencies`.
    public var dependencies: [ElementRef] {
        switch self {
        case .compoundShape: return []
        case .reference(let r): return r.dependencies
        case .recorded(let rec): return rec.dependencies
        }
    }

    public var bounds: BBox {
        switch self {
        case .compoundShape(let cs): return cs.bounds
        // Resolver-free bounds are degenerate for a reference (its geometry
        // lives elsewhere); resolver-aware bounds land with render wiring (1b).
        case .reference: return (0, 0, 0, 0)
        // Likewise degenerate for a recorded element — its geometry is
        // replayed from inputs (mirrors ReferenceElem; Rust stubs the same).
        case .recorded: return (0, 0, 0, 0)
        }
    }

    // MARK: - Mutators returning a new value

    public func withLocked(_ locked: Bool) -> LiveVariant {
        switch self {
        case .compoundShape(let cs):
            var updated = cs
            updated.locked = locked
            return .compoundShape(updated)
        case .reference(let r):
            var updated = r
            updated.locked = locked
            return .reference(updated)
        case .recorded(let rec):
            var updated = rec
            updated.locked = locked
            return .recorded(updated)
        }
    }

    public func withVisibility(_ visibility: Visibility) -> LiveVariant {
        switch self {
        case .compoundShape(let cs):
            var updated = cs
            updated.visibility = visibility
            return .compoundShape(updated)
        case .reference(let r):
            var updated = r
            updated.visibility = visibility
            return .reference(updated)
        case .recorded(let rec):
            var updated = rec
            updated.visibility = visibility
            return .recorded(updated)
        }
    }

    public func withTransform(_ transform: Transform?) -> LiveVariant {
        switch self {
        case .compoundShape(let cs):
            var updated = cs
            updated.transform = transform
            return .compoundShape(updated)
        case .reference(let r):
            var updated = r
            updated.transform = transform
            return .reference(updated)
        case .recorded(let rec):
            var updated = rec
            updated.transform = transform
            return .recorded(updated)
        }
    }

    public func withFill(_ fill: Fill?) -> LiveVariant {
        switch self {
        case .compoundShape(let cs):
            var updated = cs
            updated.fill = fill
            return .compoundShape(updated)
        case .reference(let r):
            var updated = r
            updated.fill = fill
            return .reference(updated)
        case .recorded(let rec):
            var updated = rec
            updated.fill = fill
            return .recorded(updated)
        }
    }

    public func withStroke(_ stroke: Stroke?) -> LiveVariant {
        switch self {
        case .compoundShape(let cs):
            var updated = cs
            updated.stroke = stroke
            return .compoundShape(updated)
        case .reference(let r):
            var updated = r
            updated.stroke = stroke
            return .reference(updated)
        case .recorded(let rec):
            var updated = rec
            updated.stroke = stroke
            return .recorded(updated)
        }
    }

    public func withMask(_ mask: Mask?) -> LiveVariant {
        switch self {
        case .compoundShape(let cs):
            var updated = cs
            updated.mask = mask
            return .compoundShape(updated)
        case .reference(let r):
            var updated = r
            updated.mask = mask
            return .reference(updated)
        case .recorded(let rec):
            var updated = rec
            updated.mask = mask
            return .recorded(updated)
        }
    }

    /// Return a copy with the live element's own stable `id` replaced
    /// (pass `nil` to clear). Every conformer stamps its inline id,
    /// so `Controller.assignId` / `clearingIds` work over a compound,
    /// reference, or recorded element exactly as over any other id-bearing
    /// element — matching the reference implementations' generic
    /// `common_mut().id = ...`.
    public func withId(_ id: String?) -> LiveVariant {
        switch self {
        case .compoundShape(let cs):
            var updated = cs
            updated.id = id
            return .compoundShape(updated)
        case .reference(let r):
            var updated = r
            updated.id = id
            return .reference(updated)
        case .recorded(let rec):
            var updated = rec
            updated.id = id
            return .recorded(updated)
        }
    }
}
