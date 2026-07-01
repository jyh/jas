import Foundation

// Pattern brush: side artwork tile repeated along the stroke path.
// Port of jas_dioxus/src/algorithms/pattern_along_path.rs (BRUSHES.md
// §Brush types > Pattern). Reuses flattenArtPath + pointAtArcLength.
// Phase 1: SIDE tile only (corner tiles deferred), polygon artwork.

public struct PatternBrush: Equatable {
    public let tileWidth: Double
    public let tileHeight: Double
    public let side: [[[Double]]]   // side-tile polygons of [x, y] pairs
    public let scale: Double        // percent
    public let spacing: Double      // percent of tile width
    public let flipAcross: Bool
    public let flipAlong: Bool
    public let strokeWeight: Double // pt

    public init(tileWidth: Double, tileHeight: Double, side: [[[Double]]],
                scale: Double, spacing: Double, flipAcross: Bool, flipAlong: Bool,
                strokeWeight: Double) {
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.side = side
        self.scale = scale
        self.spacing = spacing
        self.flipAcross = flipAcross
        self.flipAlong = flipAlong
        self.strokeWeight = strokeWeight
    }
}

/// Tile `brush.side` along the stroke `commands`. Returns one warped polygon
/// per (tile placement × side polygon); empty for degenerate input.
public func patternAlongPath(_ commands: [PathCommand], _ brush: PatternBrush) -> [[[Double]]] {
    guard brush.tileWidth > 0, brush.tileHeight > 0 else { return [] }
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
    let ribbon = (brush.scale / 100.0) * brush.strokeWeight
    let tileW = ribbon * (brush.tileWidth / brush.tileHeight)
    if tileW <= 0 { return [] }
    let gap = tileW * (brush.spacing / 100.0)
    let step = tileW + gap
    if step <= 0 { return [] }
    let n = max(Int((total / step).rounded(.down)), 1)

    var out: [[[Double]]] = []
    for i in 0..<n {
        let start = Double(i) * step
        for poly in brush.side {
            var warped: [[Double]] = []
            for pair in poly {
                let ax = pair[0], ay = pair[1]
                var u = min(max(ax / brush.tileWidth, 0.0), 1.0)
                if brush.flipAlong { u = 1.0 - u }
                let s = start + u * tileW
                let (px, py, tan) = pointAtArcLength(pts, cum, total, s)
                var off = (ay - brush.tileHeight / 2.0) / brush.tileHeight * ribbon
                if brush.flipAcross { off = -off }
                let nx = -sin(tan), ny = cos(tan)
                warped.append([px + nx * off, py + ny * off])
            }
            out.append(warped)
        }
    }
    return out
}
