import Foundation

// Art brush: one vector artwork stretched along the full stroke path.
// Port of jas_dioxus/src/algorithms/art_along_path.rs (BRUSHES.md §Brush
// types > Art). The artwork is a set of closed polygons in artwork
// coordinates (x ∈ [0, width], y ∈ [0, height]); it is warped onto the
// stroke path so the artwork's x-axis maps to arc-length (0 → start,
// width → end) and its y-axis maps to the perpendicular offset, centred on
// the path and scaled to the ribbon height = (scale/100)·strokeWeight.
// flipAlong reverses the arc-length mapping; flipAcross mirrors the offset.
//
// Phase 1: polygon artwork only, first subpath only, proportional scale.

public struct ArtBrush: Equatable {
    public let artworkWidth: Double
    public let artworkHeight: Double
    public let artwork: [[[Double]]]  // polygons of [x, y] pairs
    public let scale: Double          // percent
    public let flipAcross: Bool
    public let flipAlong: Bool
    public let strokeWeight: Double   // pt

    public init(artworkWidth: Double, artworkHeight: Double, artwork: [[[Double]]],
                scale: Double, flipAcross: Bool, flipAlong: Bool, strokeWeight: Double) {
        self.artworkWidth = artworkWidth
        self.artworkHeight = artworkHeight
        self.artwork = artwork
        self.scale = scale
        self.flipAcross = flipAcross
        self.flipAlong = flipAlong
        self.strokeWeight = strokeWeight
    }
}

/// Warp `brush.artwork` along the stroke `commands`. Returns one warped
/// polygon (array of [x, y]) per artwork polygon; empty for degenerate input.
public func artAlongPath(_ commands: [PathCommand], _ brush: ArtBrush) -> [[[Double]]] {
    guard brush.artworkWidth > 0, brush.artworkHeight > 0 else { return [] }
    let pts = flattenArtPath(commands)
    if pts.count < 2 { return [] }
    var cum = [Double](repeating: 0, count: pts.count)
    for i in 1..<pts.count {
        let dx = pts[i].0 - pts[i - 1].0
        let dy = pts[i].1 - pts[i - 1].1
        cum[i] = cum[i - 1] + (dx * dx + dy * dy).squareRoot()
    }
    let total = cum[pts.count - 1]
    if total <= 0 { return [] }
    let hOut = (brush.scale / 100.0) * brush.strokeWeight

    var out: [[[Double]]] = []
    for poly in brush.artwork {
        var warped: [[Double]] = []
        warped.reserveCapacity(poly.count)
        for pair in poly {
            let ax = pair[0], ay = pair[1]
            var t = min(max(ax / brush.artworkWidth, 0.0), 1.0)
            if brush.flipAlong { t = 1.0 - t }
            let (px, py, tan) = pointAtArcLength(pts, cum, total, t * total)
            var off = (ay - brush.artworkHeight / 2.0) / brush.artworkHeight * hOut
            if brush.flipAcross { off = -off }
            let nx = -sin(tan), ny = cos(tan)
            warped.append([px + nx * off, py + ny * off])
        }
        out.append(warped)
    }
    return out
}

/// Point, and tangent (radians), at arc-length `s` along the polyline.
func pointAtArcLength(_ pts: [(Double, Double)], _ cum: [Double],
                             _ total: Double, _ sIn: Double) -> (Double, Double, Double) {
    let s = min(max(sIn, 0.0), total)
    var lo = 1, hi = pts.count - 1
    while lo < hi {
        let mid = (lo + hi) / 2
        if cum[mid] < s { lo = mid + 1 } else { hi = mid }
    }
    let i = lo
    let seg = cum[i] - cum[i - 1]
    let f = seg > 0 ? (s - cum[i - 1]) / seg : 0.0
    let (x0, y0) = pts[i - 1]
    let (x1, y1) = pts[i]
    let x = x0 + (x1 - x0) * f
    let y = y0 + (y1 - y0) * f
    let tan = atan2(y1 - y0, x1 - x0)
    return (x, y, tan)
}

/// Flatten the first subpath of `commands` into a polyline.
func flattenArtPath(_ commands: [PathCommand]) -> [(Double, Double)] {
    var out: [(Double, Double)] = []
    var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0
    var started = false
    func push(_ x: Double, _ y: Double) {
        if let last = out.last, last.0 == x, last.1 == y { return }
        out.append((x, y))
    }
    for cmd in commands {
        switch cmd {
        case .moveTo(let x, let y):
            if started { return out }
            cx = x; cy = y; sx = x; sy = y
            push(x, y)
        case .lineTo(let x, let y):
            push(x, y); cx = x; cy = y; started = true
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            let n = 16
            for k in 1...n {
                let t = Double(k) / Double(n), u = 1.0 - t
                let bx = u*u*u*cx + 3*u*u*t*x1 + 3*u*t*t*x2 + t*t*t*x
                let by = u*u*u*cy + 3*u*u*t*y1 + 3*u*t*t*y2 + t*t*t*y
                push(bx, by)
            }
            cx = x; cy = y; started = true
        case .quadTo(let x1, let y1, let x, let y):
            let n = 12
            for k in 1...n {
                let t = Double(k) / Double(n), u = 1.0 - t
                let bx = u*u*cx + 2*u*t*x1 + t*t*x
                let by = u*u*cy + 2*u*t*y1 + t*t*y
                push(bx, by)
            }
            cx = x; cy = y; started = true
        case .closePath:
            if cx != sx || cy != sy { push(sx, sy) }
            return out
        default:
            return out
        }
    }
    return out
}
