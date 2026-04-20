/// Align and distribute operations — Swift port of
/// `jas_dioxus/src/algorithms/align.rs`. See
/// `transcripts/ALIGN.md` for the spec.
///
/// This module owns the geometry of the 14 Align panel buttons.
/// Each operation reads a list of (path, Element) pairs plus an
/// `AlignReference` (selection bbox, artboard rectangle, or
/// designated key object) and returns an array of `AlignTranslation`
/// values for the caller to apply.
///
/// Callers are responsible for taking a document snapshot, pre-
/// pending each element's transform with the returned (dx, dy),
/// and committing the transaction.

import Foundation

/// Fixed reference a single Align / Distribute / Distribute
/// Spacing operation consults.
public enum AlignReference: Equatable {
    case selection(BBox)
    case artboard(BBox)
    case keyObject(bbox: BBox, path: ElementPath)

    public var bbox: BBox {
        switch self {
        case .selection(let b): return b
        case .artboard(let b): return b
        case .keyObject(let b, _): return b
        }
    }

    public var keyPath: ElementPath? {
        if case .keyObject(_, let p) = self { return p }
        return nil
    }

    public static func == (lhs: AlignReference, rhs: AlignReference) -> Bool {
        switch (lhs, rhs) {
        case (.selection(let a), .selection(let b)):
            return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height
        case (.artboard(let a), .artboard(let b)):
            return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height
        case (.keyObject(let ab, let ap), .keyObject(let bb, let bp)):
            return ab.x == bb.x && ab.y == bb.y && ab.width == bb.width && ab.height == bb.height
                && ap == bp
        default:
            return false
        }
    }
}

/// Per-element translation emitted by an Align operation.
public struct AlignTranslation {
    public let path: ElementPath
    public let dx: Double
    public let dy: Double

    public init(path: ElementPath, dx: Double, dy: Double) {
        self.path = path
        self.dx = dx
        self.dy = dy
    }
}

extension AlignTranslation: Equatable {
    public static func == (lhs: AlignTranslation, rhs: AlignTranslation) -> Bool {
        lhs.path == rhs.path && lhs.dx == rhs.dx && lhs.dy == rhs.dy
    }
}

/// Bounds-lookup function. Pass `alignPreviewBounds` when Use
/// Preview Bounds is checked in the panel menu; otherwise pass
/// `alignGeometricBounds`. See ALIGN.md §Bounding box selection.
public typealias AlignBoundsFn = (Element) -> BBox

public func alignPreviewBounds(_ e: Element) -> BBox { e.bounds }
public func alignGeometricBounds(_ e: Element) -> BBox { e.geometricBounds }

/// Union the bounding boxes of an element list using the given
/// bounds function. Returns `(0, 0, 0, 0)` when the list is empty.
public func alignUnionBounds(_ elements: [Element], _ boundsFn: AlignBoundsFn) -> BBox {
    guard !elements.isEmpty else { return (0, 0, 0, 0) }
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity
    for e in elements {
        let b = boundsFn(e)
        minX = min(minX, b.x); minY = min(minY, b.y)
        maxX = max(maxX, b.x + b.width); maxY = max(maxY, b.y + b.height)
    }
    return (minX, minY, maxX - minX, maxY - minY)
}

/// Axis of an operation — horizontal ops move in x; vertical in y.
public enum AlignAxis {
    case horizontal, vertical
}

/// Which edge or midpoint along the axis the operation anchors to.
public enum AlignAxisAnchor {
    case min, center, max
}

/// Extract (min, max, center) along the given axis from a bbox.
public func alignAxisExtent(_ bbox: BBox, _ axis: AlignAxis) -> (Double, Double, Double) {
    switch axis {
    case .horizontal: return (bbox.x, bbox.x + bbox.width, bbox.x + bbox.width / 2.0)
    case .vertical: return (bbox.y, bbox.y + bbox.height, bbox.y + bbox.height / 2.0)
    }
}

/// The anchor position of a bbox along a given axis.
public func alignAnchorPosition(
    _ bbox: BBox, _ axis: AlignAxis, _ anchor: AlignAxisAnchor
) -> Double {
    let (lo, hi, mid) = alignAxisExtent(bbox, axis)
    switch anchor {
    case .min: return lo
    case .center: return mid
    case .max: return hi
    }
}

/// Generic alignment driver used by the six public Align
/// operations. For each selected element whose bbox anchor differs
/// from the reference bbox anchor along the given axis, emit a
/// translation that moves it onto the target.
///
/// Elements whose path matches `reference.keyPath` are skipped —
/// the key object never moves, per ALIGN.md §Align To target.
/// Zero-delta translations are omitted per the identity-value
/// rule in ALIGN.md §SVG attribute mapping.
public func alignAlongAxis(
    _ elements: [(ElementPath, Element)],
    _ reference: AlignReference,
    _ axis: AlignAxis,
    _ anchor: AlignAxisAnchor,
    _ boundsFn: AlignBoundsFn
) -> [AlignTranslation] {
    let target = alignAnchorPosition(reference.bbox, axis, anchor)
    let keyPath = reference.keyPath
    var out: [AlignTranslation] = []
    for (path, elem) in elements {
        if path == keyPath { continue }
        let pos = alignAnchorPosition(boundsFn(elem), axis, anchor)
        let delta = target - pos
        if delta == 0 { continue }
        let (dx, dy): (Double, Double) = switch axis {
        case .horizontal: (delta, 0)
        case .vertical: (0, delta)
        }
        out.append(AlignTranslation(path: path, dx: dx, dy: dy))
    }
    return out
}

/// ALIGN_LEFT_BUTTON. Move every non-key element so its left edge
/// coincides with the reference's left edge.
public func alignLeft(
    _ elements: [(ElementPath, Element)],
    _ reference: AlignReference,
    _ boundsFn: AlignBoundsFn
) -> [AlignTranslation] {
    alignAlongAxis(elements, reference, .horizontal, .min, boundsFn)
}

/// ALIGN_HORIZONTAL_CENTER_BUTTON. Move every non-key element so
/// its horizontal center coincides with the reference's.
public func alignHorizontalCenter(
    _ elements: [(ElementPath, Element)],
    _ reference: AlignReference,
    _ boundsFn: AlignBoundsFn
) -> [AlignTranslation] {
    alignAlongAxis(elements, reference, .horizontal, .center, boundsFn)
}

/// ALIGN_RIGHT_BUTTON. Move every non-key element so its right
/// edge coincides with the reference's right edge.
public func alignRight(
    _ elements: [(ElementPath, Element)],
    _ reference: AlignReference,
    _ boundsFn: AlignBoundsFn
) -> [AlignTranslation] {
    alignAlongAxis(elements, reference, .horizontal, .max, boundsFn)
}

/// ALIGN_TOP_BUTTON. Move every non-key element so its top edge
/// coincides with the reference's top edge.
public func alignTop(
    _ elements: [(ElementPath, Element)],
    _ reference: AlignReference,
    _ boundsFn: AlignBoundsFn
) -> [AlignTranslation] {
    alignAlongAxis(elements, reference, .vertical, .min, boundsFn)
}

/// ALIGN_VERTICAL_CENTER_BUTTON. Move every non-key element so
/// its vertical center coincides with the reference's.
public func alignVerticalCenter(
    _ elements: [(ElementPath, Element)],
    _ reference: AlignReference,
    _ boundsFn: AlignBoundsFn
) -> [AlignTranslation] {
    alignAlongAxis(elements, reference, .vertical, .center, boundsFn)
}

/// ALIGN_BOTTOM_BUTTON. Move every non-key element so its bottom
/// edge coincides with the reference's bottom edge.
public func alignBottom(
    _ elements: [(ElementPath, Element)],
    _ reference: AlignReference,
    _ boundsFn: AlignBoundsFn
) -> [AlignTranslation] {
    alignAlongAxis(elements, reference, .vertical, .max, boundsFn)
}
