import CoreGraphics

/// Viewport / dirty-rect culling predicate for canvas document rendering
/// (SH-4). Pure and CoreGraphics-only so it is unit-testable without a live
/// context. The invariant is one-directional: a false "keep" only wastes a
/// draw (AppKit clips to the dirty rect anyway), whereas a false "skip" would
/// drop visible content — so the predicate is deliberately conservative and
/// errs toward drawing. Culling is therefore VISUALLY INVARIANT.
enum CanvasCull {
    /// Axis-aligned bounding box of a local bbox's four corners after mapping
    /// through affine `m`. Handles rotation / shear correctly (the AABB grows
    /// to contain the rotated rectangle), so a transformed element is tested by
    /// its true POST-transform extent.
    static func mappedAABB(_ b: BBox, _ m: CGAffineTransform) -> CGRect {
        let corners = [
            CGPoint(x: b.x,           y: b.y),
            CGPoint(x: b.x + b.width, y: b.y),
            CGPoint(x: b.x,           y: b.y + b.height),
            CGPoint(x: b.x + b.width, y: b.y + b.height),
        ].map { $0.applying(m) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = xs.min()!, minY = ys.min()!
        return CGRect(x: minX, y: minY, width: xs.max()! - minX, height: ys.max()! - minY)
    }

    /// Whether an element with local bounds `b`, placed into document space by
    /// `localToDoc`, might paint inside `dirtyDoc` (also document space) once a
    /// conservative `margin` (doc units) is allowed for stroke bleed, arrowheads,
    /// miters, and antialiasing. Returns true on any overlap — draw when in doubt.
    static func mayDraw(bounds b: BBox, localToDoc: CGAffineTransform,
                        dirtyDoc: CGRect, margin: CGFloat) -> Bool {
        let box = mappedAABB(b, localToDoc).insetBy(dx: -margin, dy: -margin)
        return box.intersects(dirtyDoc)
    }
}
