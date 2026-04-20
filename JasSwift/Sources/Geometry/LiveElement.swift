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
    public var fill: Fill?
    public var stroke: Stroke?
    public var opacity: Double
    public var transform: Transform?
    public var locked: Bool
    public var visibility: Visibility

    public init(
        operation: CompoundOperation,
        operands: [Element],
        fill: Fill? = nil,
        stroke: Stroke? = nil,
        opacity: Double = 1.0,
        transform: Transform? = nil,
        locked: Bool = false,
        visibility: Visibility = .preview
    ) {
        self.operation = operation
        self.operands = operands
        self.fill = fill
        self.stroke = stroke
        self.opacity = opacity
        self.transform = transform
        self.locked = locked
        self.visibility = visibility
    }

    /// Evaluate the compound shape: flatten operands to polygon sets,
    /// apply the boolean operation, return the result.
    public func evaluate(precision: Double) -> BoolPolygonSet {
        let operandSets = operands.map { elementToPolygonSet($0, precision: precision) }
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

// MARK: - Geometry helpers

/// Flatten a document element into a polygon set suitable for the
/// boolean algorithm. See BOOLEAN.md § Geometry and precision.
public func elementToPolygonSet(_ elem: Element, precision: Double) -> BoolPolygonSet {
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
        return g.children.flatMap { elementToPolygonSet($0, precision: precision) }
    case .layer(let l):
        return l.children.flatMap { elementToPolygonSet($0, precision: precision) }
    case .live(let v):
        switch v {
        case .compoundShape(let cs): return cs.evaluate(precision: precision)
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
private func flattenPathToRings(_ d: [PathCommand]) -> BoolPolygonSet {
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

    public var kind: String {
        switch self {
        case .compoundShape: return "compound_shape"
        }
    }

    public var kindSchemaVersion: Int {
        switch self {
        case .compoundShape: return 1
        }
    }

    public var fill: Fill? {
        switch self {
        case .compoundShape(let cs): return cs.fill
        }
    }

    public var stroke: Stroke? {
        switch self {
        case .compoundShape(let cs): return cs.stroke
        }
    }

    public var opacity: Double {
        switch self {
        case .compoundShape(let cs): return cs.opacity
        }
    }

    public var transform: Transform? {
        switch self {
        case .compoundShape(let cs): return cs.transform
        }
    }

    public var locked: Bool {
        switch self {
        case .compoundShape(let cs): return cs.locked
        }
    }

    public var visibility: Visibility {
        switch self {
        case .compoundShape(let cs): return cs.visibility
        }
    }

    public var operands: [Element] {
        switch self {
        case .compoundShape(let cs): return cs.operands
        }
    }

    public var bounds: BBox {
        switch self {
        case .compoundShape(let cs): return cs.bounds
        }
    }

    // MARK: - Mutators returning a new value

    public func withLocked(_ locked: Bool) -> LiveVariant {
        switch self {
        case .compoundShape(let cs):
            var updated = cs
            updated.locked = locked
            return .compoundShape(updated)
        }
    }

    public func withVisibility(_ visibility: Visibility) -> LiveVariant {
        switch self {
        case .compoundShape(let cs):
            var updated = cs
            updated.visibility = visibility
            return .compoundShape(updated)
        }
    }

    public func withTransform(_ transform: Transform?) -> LiveVariant {
        switch self {
        case .compoundShape(let cs):
            var updated = cs
            updated.transform = transform
            return .compoundShape(updated)
        }
    }

    public func withFill(_ fill: Fill?) -> LiveVariant {
        switch self {
        case .compoundShape(let cs):
            var updated = cs
            updated.fill = fill
            return .compoundShape(updated)
        }
    }

    public func withStroke(_ stroke: Stroke?) -> LiveVariant {
        switch self {
        case .compoundShape(let cs):
            var updated = cs
            updated.stroke = stroke
            return .compoundShape(updated)
        }
    }
}
