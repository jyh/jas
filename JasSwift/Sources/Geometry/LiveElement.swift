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
        let ps = elementToPolygonSetWith(
            resolved, precision: precision, resolver: resolver, visiting: &visiting)
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

    public var kind: String {
        switch self {
        case .compoundShape: return "compound_shape"
        case .reference: return "reference"
        }
    }

    public var kindSchemaVersion: Int {
        switch self {
        case .compoundShape: return 1
        case .reference: return 1
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
        }
    }

    public var fill: Fill? {
        switch self {
        case .compoundShape(let cs): return cs.fill
        case .reference(let r): return r.fill
        }
    }

    public var stroke: Stroke? {
        switch self {
        case .compoundShape(let cs): return cs.stroke
        case .reference(let r): return r.stroke
        }
    }

    public var opacity: Double {
        switch self {
        case .compoundShape(let cs): return cs.opacity
        case .reference(let r): return r.opacity
        }
    }

    public var transform: Transform? {
        switch self {
        case .compoundShape(let cs): return cs.transform
        case .reference(let r): return r.transform
        }
    }

    public var locked: Bool {
        switch self {
        case .compoundShape(let cs): return cs.locked
        case .reference(let r): return r.locked
        }
    }

    public var visibility: Visibility {
        switch self {
        case .compoundShape(let cs): return cs.visibility
        case .reference(let r): return r.visibility
        }
    }

    public var blendMode: BlendMode {
        switch self {
        case .compoundShape(let cs): return cs.blendMode
        case .reference(let r): return r.blendMode
        }
    }

    public var mask: Mask? {
        switch self {
        case .compoundShape(let cs): return cs.mask
        case .reference(let r): return r.mask
        }
    }

    public var operands: [Element] {
        switch self {
        case .compoundShape(let cs): return cs.operands
        // A reference owns no children; its target is a dependency edge.
        case .reference: return []
        }
    }

    /// Stable-id inputs reached by reference rather than containment, in
    /// deterministic order. Default empty for containment kinds (compound
    /// shape owns its operands); the reference reports its target. Mirrors
    /// Rust `LiveElement::dependencies`.
    public var dependencies: [ElementRef] {
        switch self {
        case .compoundShape: return []
        case .reference(let r): return r.dependencies
        }
    }

    public var bounds: BBox {
        switch self {
        case .compoundShape(let cs): return cs.bounds
        // Resolver-free bounds are degenerate for a reference (its geometry
        // lives elsewhere); resolver-aware bounds land with render wiring (1b).
        case .reference: return (0, 0, 0, 0)
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
        }
    }

    /// Return a copy with the live element's own stable `id` replaced
    /// (pass `nil` to clear). Both conformers stamp their inline id,
    /// so `Controller.assignId` / `clearingIds` work over a compound or
    /// reference exactly as over any other id-bearing element — matching
    /// the reference implementations' generic `common_mut().id = ...`.
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
        }
    }
}
