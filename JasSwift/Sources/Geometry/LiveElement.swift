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
    ///
    /// Phase 1 stub: returns an empty polygon set. Phase 2 wires the
    /// actual boolean pipeline (port of Rust `CompoundShape::evaluate`).
    public func evaluate(precision: Double) -> BoolPolygonSet {
        return []
    }

    /// Bounding box of the evaluated output (stroke-inclusive).
    /// Phase 1 stub: empty. Phase 2 returns bounds of evaluated geometry.
    public var bounds: BBox { (0, 0, 0, 0) }
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
