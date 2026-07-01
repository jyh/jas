import Foundation

// Bristle brush: N semi-transparent bristle lines spread across the brush
// width, each following the path at a fixed perpendicular offset. Port of
// jas_dioxus/src/algorithms/bristle_stroke.rs (BRUSHES.md §Brush types >
// Bristle). The caller strokes each polyline in the stroke colour with
// alpha() / lineWidth(). Phase 1: straight offset bristles, first subpath.

public struct BristleBrush: Equatable {
    public let size: Double
    public let density: Double
    public let thickness: Double
    public let opacity: Double
    public let strokeWeight: Double

    public init(size: Double, density: Double, thickness: Double,
                opacity: Double, strokeWeight: Double) {
        self.size = size
        self.density = density
        self.thickness = thickness
        self.opacity = opacity
        self.strokeWeight = strokeWeight
    }

    /// Bristle count (2...12), from density.
    public func count() -> Int { min(max(Int((density / 12.5).rounded()), 2), 12) }
    /// Per-bristle line width (min 0.5), from thickness and spacing.
    public func lineWidth() -> Double {
        let bw = size * strokeWeight
        return max((thickness / 100.0) * (bw / Double(count())), 0.5)
    }
    /// Per-bristle stroke alpha (0...1), from opacity.
    public func alpha() -> Double { min(max(opacity / 100.0, 0.0), 1.0) }
}

/// Bristle polylines: one per bristle, each the path offset perpendicular by
/// that bristle's centre offset. Empty for degenerate input.
public func bristleStroke(_ commands: [PathCommand], _ brush: BristleBrush) -> [[[Double]]] {
    let pts = flattenArtPath(commands)
    if pts.count < 2 { return [] }
    let bw = brush.size * brush.strokeWeight
    if bw <= 0 { return [] }
    let n = brush.count()
    let m = pts.count
    var normals: [(Double, Double)] = []
    normals.reserveCapacity(m)
    for i in 0..<m {
        let tx: Double, ty: Double
        if i + 1 < m { tx = pts[i + 1].0 - pts[i].0; ty = pts[i + 1].1 - pts[i].1 }
        else { tx = pts[i].0 - pts[i - 1].0; ty = pts[i].1 - pts[i - 1].1 }
        let len = (tx * tx + ty * ty).squareRoot()
        normals.append(len > 0 ? (-ty / len, tx / len) : (0.0, 1.0))
    }
    var out: [[[Double]]] = []
    for b in 0..<n {
        let oc = (Double(b) / (Double(n) - 1.0) - 0.5) * bw
        var line: [[Double]] = []
        line.reserveCapacity(m)
        for i in 0..<m {
            let (nx, ny) = normals[i]
            line.append([pts[i].0 + nx * oc, pts[i].1 + ny * oc])
        }
        out.append(line)
    }
    return out
}
