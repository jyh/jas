import Foundation

// MARK: - Path text layout
//
// Walks the arc length of a flattened path and places one glyph per
// character at the center of its arc-length interval. Mirrors
// `path_text_layout.rs` / `.ml` / `.py`.

public struct PathGlyph {
    public let idx: Int
    public let offset: Double
    public let width: Double
    public let cx: Double
    public let cy: Double
    public let angle: Double
    public let overflow: Bool
}

public struct PathTextLayout {
    public let glyphs: [PathGlyph]
    public let totalLength: Double
    public let fontSize: Double
    public let charCount: Int
}

private func arcLengths(_ pts: [(Double, Double)]) -> [Double] {
    if pts.isEmpty { return [0.0] }
    var out: [Double] = [0.0]
    var prev = pts[0]
    for i in 1..<pts.count {
        let (x, y) = pts[i]
        let dx = x - prev.0, dy = y - prev.1
        out.append(out.last! + (dx * dx + dy * dy).squareRoot())
        prev = pts[i]
    }
    return out
}

private func sampleAtArc(_ pts: [(Double, Double)], _ lens: [Double], _ arcIn: Double)
    -> (Double, Double, Double) {
    let n = pts.count
    if n < 2 {
        let (x, y) = n == 1 ? pts[0] : (0.0, 0.0)
        return (x, y, 0.0)
    }
    let arc = max(0.0, arcIn)
    for i in 1..<n {
        if lens[i] >= arc {
            let seg = lens[i] - lens[i - 1]
            let t = seg > 0 ? (arc - lens[i - 1]) / seg : 0.0
            let (ax, ay) = pts[i - 1]
            let (bx, by) = pts[i]
            return (ax + t * (bx - ax), ay + t * (by - ay), atan2(by - ay, bx - ax))
        }
    }
    let last = n - 1
    let (ax, ay) = pts[last - 1]
    let (bx, by) = pts[last]
    return (bx, by, atan2(by - ay, bx - ax))
}

/// Layout `content` along the curve described by `d`, starting at the
/// fractional `startOffset` (0…1) along the path's arc length.
public func layoutPathText(_ d: [PathCommand],
                           content: String,
                           startOffset: Double,
                           fontSize: Double,
                           measure: (String) -> Double) -> PathTextLayout {
    let pts = flattenPathCommands(d)
    let lens = arcLengths(pts)
    let total = lens.last ?? 0.0
    let chars = Array(content)
    let n = chars.count
    if total <= 0 || pts.isEmpty {
        return PathTextLayout(glyphs: [], totalLength: total, fontSize: fontSize, charCount: n)
    }
    let startArc = max(0.0, min(1.0, startOffset)) * total
    var curArc = startArc
    var glyphs: [PathGlyph] = []
    for i in 0..<n {
        let cw = measure(String(chars[i]))
        let centerArc = curArc + cw / 2
        let overflow = centerArc > total
        let (cx, cy, angle) = sampleAtArc(pts, lens, min(centerArc, total))
        glyphs.append(PathGlyph(idx: i, offset: curArc, width: cw,
                                cx: cx, cy: cy, angle: angle, overflow: overflow))
        curArc += cw
    }
    return PathTextLayout(glyphs: glyphs, totalLength: total, fontSize: fontSize, charCount: n)
}

public extension PathTextLayout {
    /// Caret position (x, y, tangent angle) for `cursor`. nil if empty.
    func cursorPos(_ cursor: Int) -> (Double, Double, Double)? {
        let n = glyphs.count
        if n == 0 { return nil }
        if cursor == 0 {
            let g = glyphs[0]
            let dx = -cos(g.angle) * g.width / 2
            let dy = -sin(g.angle) * g.width / 2
            return (g.cx + dx, g.cy + dy, g.angle)
        }
        if cursor >= n {
            let g = glyphs[n - 1]
            let dx = cos(g.angle) * g.width / 2
            let dy = sin(g.angle) * g.width / 2
            return (g.cx + dx, g.cy + dy, g.angle)
        }
        let g = glyphs[cursor]
        let dx = -cos(g.angle) * g.width / 2
        let dy = -sin(g.angle) * g.width / 2
        return (g.cx + dx, g.cy + dy, g.angle)
    }

    func hitTest(_ x: Double, _ y: Double) -> Int {
        let n = glyphs.count
        if n == 0 { return 0 }
        var bestIdx = 0
        var bestDist = Double.infinity
        for i in 0..<n {
            let g = glyphs[i]
            let half = g.width / 2
            let bx = g.cx - cos(g.angle) * half
            let by = g.cy - sin(g.angle) * half
            let ax = g.cx + cos(g.angle) * half
            let ay = g.cy + sin(g.angle) * half
            let db = ((x - bx) * (x - bx) + (y - by) * (y - by)).squareRoot()
            let da = ((x - ax) * (x - ax) + (y - ay) * (y - ay)).squareRoot()
            if db < bestDist { bestDist = db; bestIdx = i }
            if da < bestDist { bestDist = da; bestIdx = i + 1 }
        }
        return bestIdx
    }
}
