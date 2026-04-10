/// CLI tool for cross-language algorithm testing.
///
/// Usage:
///   AlgorithmRoundtrip <algorithm> <fixture.json>

import Foundation
import JasLib

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("Usage: \(args[0]) <algorithm> <fixture.json>\n", stderr)
    exit(1)
}

let algo = args[1]
let path = args[2]

guard let data = FileManager.default.contents(atPath: path),
      let jsonStr = String(data: data, encoding: .utf8) else {
    fputs("Failed to read: \(path)\n", stderr)
    exit(1)
}

guard let fixture = try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) else {
    fputs("Failed to parse JSON\n", stderr)
    exit(1)
}

// Support both formats: flat array (legacy hit_test.json) and envelope
let vectors: [[String: Any]]
if let arr = fixture as? [[String: Any]] {
    vectors = arr
} else if let obj = fixture as? [String: Any],
          let arr = obj["vectors"] as? [[String: Any]] {
    vectors = arr
} else {
    fputs("Expected 'vectors' array in fixture\n", stderr)
    exit(1)
}

// Filter out skipped vectors
let activeVectors = vectors.filter { !($0["_skip"] as? Bool ?? false) }

let results: [[String: Any]]
switch algo {
case "hit_test":          results = runHitTest(activeVectors)
case "boolean":           results = runBoolean(activeVectors)
case "boolean_normalize": results = runBooleanNormalize(activeVectors)
case "fit_curve":         results = runFitCurve(activeVectors)
case "shape_recognize":   results = runShapeRecognize(activeVectors)
case "planar":            results = runPlanar(activeVectors)
case "text_layout":       results = runTextLayout(activeVectors)
case "path_text_layout":  results = runPathTextLayout(activeVectors)
default:
    fputs("Unknown algorithm: \(algo)\n", stderr)
    exit(1)
}

let jsonData = try! JSONSerialization.data(withJSONObject: results,
                                            options: [.sortedKeys])
print(String(data: jsonData, encoding: .utf8)!, terminator: "")

// MARK: - Hit Test

func runHitTest(_ vectors: [[String: Any]]) -> [[String: Any]] {
    vectors.map { tc in
        let name = tc["name"] as! String
        let fn = tc["function"] as! String
        let a = tc["args"] as! [Double]
        let result: Bool
        switch fn {
        case "point_in_rect":
            result = pointInRect(a[0], a[1], a[2], a[3], a[4], a[5])
        case "segments_intersect":
            result = segmentsIntersect(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7])
        case "segment_intersects_rect":
            result = segmentIntersectsRect(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7])
        case "rects_intersect":
            result = rectsIntersect(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7])
        case "circle_intersects_rect":
            let filled = tc["filled"] as? Bool ?? true
            result = circleIntersectsRect(a[0], a[1], a[2], a[3], a[4], a[5], a[6], filled: filled)
        case "ellipse_intersects_rect":
            let filled = tc["filled"] as? Bool ?? true
            result = ellipseIntersectsRect(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], filled: filled)
        case "point_in_polygon":
            let poly = parsePolygon(tc["polygon"]!)
            result = pointInPolygon(a[0], a[1], poly)
        default:
            fputs("Unknown hit_test function: \(fn)\n", stderr)
            exit(1)
        }
        return ["name": name, "result": result] as [String: Any]
    }
}

// MARK: - Boolean

func runBoolean(_ vectors: [[String: Any]]) -> [[String: Any]] {
    vectors.map { tc in
        let name = tc["name"] as! String
        let fn = tc["function"] as! String
        let a = parsePolygonSet(tc["a"]!)
        let b = parsePolygonSet(tc["b"]!)
        let res: BoolPolygonSet
        switch fn {
        case "union":     res = booleanUnion(a, b)
        case "intersect": res = booleanIntersect(a, b)
        case "subtract":  res = booleanSubtract(a, b)
        case "exclude":   res = booleanExclude(a, b)
        default:
            fputs("Unknown boolean function: \(fn)\n", stderr)
            exit(1)
        }
        let expected = tc["expected"] as! [String: Any]
        let samplePts = (expected["sample_points"] as? [[String: Any]]) ?? []
        let samples: [[String: Any]] = samplePts.map { sp in
            let pt = parsePoint(sp["point"]!)
            let inside = pointInPolygonSetHelper(res, pt)
            return ["point": [pt.0, pt.1], "inside": inside] as [String: Any]
        }
        return ["name": name, "result": [
            "area": polygonSetAreaHelper(res),
            "ring_count": res.count,
            "sample_points": samples
        ] as [String: Any]] as [String: Any]
    }
}

// MARK: - Boolean Normalize

func runBooleanNormalize(_ vectors: [[String: Any]]) -> [[String: Any]] {
    vectors.map { tc in
        let name = tc["name"] as! String
        let input = parsePolygonSet(tc["input"]!)
        let res = normalize(input)
        return ["name": name, "result": [
            "area": polygonSetAreaHelper(res),
            "ring_count": res.count,
            "all_rings_simple": allRingsSimple(res)
        ] as [String: Any]] as [String: Any]
    }
}

// MARK: - Fit Curve

func runFitCurve(_ vectors: [[String: Any]]) -> [[String: Any]] {
    vectors.map { tc in
        let name = tc["name"] as! String
        let points = parsePoints(tc["points"]!)
        let error = tc["error"] as! Double
        let segs = fitCurve(points: points, error: error)
        let segJson: [[Double]] = segs.map {
            [$0.p1x, $0.p1y, $0.c1x, $0.c1y, $0.c2x, $0.c2y, $0.p2x, $0.p2y]
        }
        return ["name": name, "result": [
            "segment_count": segs.count,
            "segments": segJson
        ] as [String: Any]] as [String: Any]
    }
}

// MARK: - Shape Recognize

func runShapeRecognize(_ vectors: [[String: Any]]) -> [[String: Any]] {
    vectors.map { tc in
        let name = tc["name"] as! String
        let points = parsePoints(tc["points"]!)
        var cfg = RecognizeConfig()
        if let cfgDict = tc["config"] as? [String: Any],
           let tol = cfgDict["tolerance"] as? Double {
            cfg.tolerance = tol
        }
        let shape = recognize(points, cfg)
        let resultVal: Any = shape.map { shapeToDict($0) } ?? NSNull()
        return ["name": name, "result": resultVal] as [String: Any]
    }
}

func shapeToDict(_ shape: RecognizedShape) -> [String: Any] {
    switch shape {
    case .line(let a, let b):
        return ["kind": "line", "params": ["ax": a.0, "ay": a.1, "bx": b.0, "by": b.1]]
    case .triangle(let pts):
        return ["kind": "triangle", "params": [
            "pts": [[pts.0.0, pts.0.1], [pts.1.0, pts.1.1], [pts.2.0, pts.2.1]]
        ]]
    case .rectangle(let x, let y, let w, let h):
        let kind = abs(w - h) < 1e-9 ? "square" : "rectangle"
        return ["kind": kind, "params": ["x": x, "y": y, "w": w, "h": h]]
    case .roundRect(let x, let y, let w, let h, let r):
        return ["kind": "round_rect", "params": ["x": x, "y": y, "w": w, "h": h, "r": r]]
    case .circle(let cx, let cy, let r):
        return ["kind": "circle", "params": ["cx": cx, "cy": cy, "r": r]]
    case .ellipse(let cx, let cy, let rx, let ry):
        return ["kind": "ellipse", "params": ["cx": cx, "cy": cy, "rx": rx, "ry": ry]]
    case .arrow(let tail, let tip, let hl, let hw, let sw):
        return ["kind": "arrow", "params": [
            "tail_x": tail.0, "tail_y": tail.1,
            "tip_x": tip.0, "tip_y": tip.1,
            "head_len": hl, "head_half_width": hw, "shaft_half_width": sw
        ]]
    case .lemniscate(let center, let a, let horizontal):
        return ["kind": "lemniscate", "params": [
            "cx": center.0, "cy": center.1, "a": a, "horizontal": horizontal
        ]]
    case .scribble(let points):
        let pts: [[Double]] = points.map { [$0.0, $0.1] }
        return ["kind": "scribble", "params": ["points": pts]]
    }
}

// MARK: - Planar

func runPlanar(_ vectors: [[String: Any]]) -> [[String: Any]] {
    vectors.map { tc in
        let name = tc["name"] as! String
        let polylines = (tc["polylines"] as! [Any]).map { parsePoints($0) }
        let graph = PlanarGraph.build(polylines)
        let fc = graph.faceCount
        var areas: [Double] = (0..<fc).map { graph.faceNetArea(FaceId($0)) }
        areas.sort()
        let expected = tc["expected"] as! [String: Any]
        let samplePts = (expected["sample_points"] as? [[String: Any]]) ?? []
        let samples: [[String: Any]] = samplePts.map { sp in
            let pt = parsePoint(sp["point"]!)
            let hit = graph.hitTest(pt)
            return ["point": [pt.0, pt.1], "inside_any_face": hit != nil] as [String: Any]
        }
        return ["name": name, "result": [
            "face_count": fc,
            "face_areas_sorted": areas,
            "sample_points": samples
        ] as [String: Any]] as [String: Any]
    }
}

// MARK: - Text Layout

func runTextLayout(_ vectors: [[String: Any]]) -> [[String: Any]] {
    vectors.map { tc in
        let name = tc["name"] as! String
        let content = tc["content"] as! String
        let maxWidth = tc["max_width"] as! Double
        let fontSize = tc["font_size"] as! Double
        let charWidth = tc["char_width"] as! Double
        let measure: (String) -> Double = { s in Double(s.count) * charWidth }
        let layout = layoutText(content, maxWidth: maxWidth, fontSize: fontSize,
                                measure: measure)
        let glyphs: [[String: Any]] = layout.glyphs.map { g in
            ["idx": g.idx, "line": g.line, "x": g.x, "right": g.right] as [String: Any]
        }
        return ["name": name, "result": [
            "line_count": layout.lines.count,
            "char_count": layout.charCount,
            "glyphs": glyphs
        ] as [String: Any]] as [String: Any]
    }
}

// MARK: - Path Text Layout

func runPathTextLayout(_ vectors: [[String: Any]]) -> [[String: Any]] {
    vectors.map { tc in
        let name = tc["name"] as! String
        let pathCmds = parsePathCommands(tc["path"]!)
        let content = tc["content"] as! String
        let startOffset = tc["start_offset"] as! Double
        let fontSize = tc["font_size"] as! Double
        let charWidth = tc["char_width"] as! Double
        let measure: (String) -> Double = { s in Double(s.count) * charWidth }
        let layout = layoutPathText(pathCmds, content: content,
                                    startOffset: startOffset, fontSize: fontSize,
                                    measure: measure)
        let glyphs: [[String: Any]] = layout.glyphs.map { g in
            ["idx": g.idx, "cx": g.cx, "cy": g.cy, "angle": g.angle,
             "overflow": g.overflow] as [String: Any]
        }
        return ["name": name, "result": [
            "total_length": layout.totalLength,
            "char_count": layout.charCount,
            "glyphs": glyphs
        ] as [String: Any]] as [String: Any]
    }
}

// MARK: - JSON Parsing Helpers

func parsePoint(_ v: Any) -> (Double, Double) {
    let arr = v as! [Double]
    return (arr[0], arr[1])
}

func parsePoints(_ v: Any) -> [(Double, Double)] {
    (v as! [[Double]]).map { ($0[0], $0[1]) }
}

func parsePolygon(_ v: Any) -> [(Double, Double)] {
    parsePoints(v)
}

func parsePolygonSet(_ v: Any) -> BoolPolygonSet {
    (v as! [Any]).map { parsePoints($0) }
}

func parsePathCommands(_ v: Any) -> [PathCommand] {
    (v as! [[String: Any]]).map { c in
        let cmd = c["cmd"] as! String
        switch cmd {
        case "M": return .moveTo(c["x"] as! Double, c["y"] as! Double)
        case "L": return .lineTo(c["x"] as! Double, c["y"] as! Double)
        case "C": return .curveTo(x1: c["x1"] as! Double, y1: c["y1"] as! Double,
                                   x2: c["x2"] as! Double, y2: c["y2"] as! Double,
                                   x: c["x"] as! Double, y: c["y"] as! Double)
        case "Q": return .quadTo(x1: c["x1"] as! Double, y1: c["y1"] as! Double,
                                  x: c["x"] as! Double, y: c["y"] as! Double)
        case "Z": return .closePath
        default:
            fputs("Unknown path command: \(cmd)\n", stderr)
            exit(1)
        }
    }
}

// MARK: - Geometry Helpers

func ringSignedArea(_ ring: BoolRing) -> Double {
    guard ring.count >= 3 else { return 0 }
    var sum = 0.0
    let n = ring.count
    for i in 0..<n {
        let (x1, y1) = ring[i]
        let (x2, y2) = ring[(i + 1) % n]
        sum += x1 * y2 - x2 * y1
    }
    return sum * 0.5
}

func pointInRingHelper(_ ring: BoolRing, _ pt: (Double, Double)) -> Bool {
    let (px, py) = pt
    let n = ring.count
    guard n >= 3 else { return false }
    var inside = false
    var j = n - 1
    for i in 0..<n {
        let (xi, yi) = ring[i]
        let (xj, yj) = ring[j]
        if ((yi > py) != (yj > py)) && (px < (xj - xi) * (py - yi) / (yj - yi) + xi) {
            inside = !inside
        }
        j = i
    }
    return inside
}

func pointInPolygonSetHelper(_ ps: BoolPolygonSet, _ pt: (Double, Double)) -> Bool {
    var count = 0
    for ring in ps {
        if pointInRingHelper(ring, pt) { count += 1 }
    }
    return count % 2 == 1
}

func polygonSetAreaHelper(_ ps: BoolPolygonSet) -> Double {
    var total = 0.0
    for (i, ring) in ps.enumerated() {
        let a = abs(ringSignedArea(ring))
        var depth = 0
        if let pt = ring.first {
            for (j, other) in ps.enumerated() {
                if i == j { continue }
                if pointInRingHelper(other, pt) { depth += 1 }
            }
        }
        total += depth % 2 == 0 ? a : -a
    }
    return total
}

func allRingsSimple(_ ps: BoolPolygonSet) -> Bool {
    ps.allSatisfy { isRingSimple($0) }
}

func isRingSimple(_ ring: BoolRing) -> Bool {
    let n = ring.count
    guard n >= 3 else { return true }
    for i in 0..<n {
        let (ax1, ay1) = ring[i]
        let (ax2, ay2) = ring[(i + 1) % n]
        for j in (i + 2)..<n {
            if i == 0 && j == n - 1 { continue }
            let (bx1, by1) = ring[j]
            let (bx2, by2) = ring[(j + 1) % n]
            if properCrossing(ax1, ay1, ax2, ay2, bx1, by1, bx2, by2) { return false }
        }
    }
    return true
}

func properCrossing(_ ax1: Double, _ ay1: Double, _ ax2: Double, _ ay2: Double,
                    _ bx1: Double, _ by1: Double, _ bx2: Double, _ by2: Double) -> Bool {
    let d1 = crossProduct(bx2 - bx1, by2 - by1, ax1 - bx1, ay1 - by1)
    let d2 = crossProduct(bx2 - bx1, by2 - by1, ax2 - bx1, ay2 - by1)
    let d3 = crossProduct(ax2 - ax1, ay2 - ay1, bx1 - ax1, by1 - ay1)
    let d4 = crossProduct(ax2 - ax1, ay2 - ay1, bx2 - ax1, by2 - ay1)
    return d1 * d2 < 0 && d3 * d4 < 0
}

func crossProduct(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
    ux * vy - uy * vx
}
