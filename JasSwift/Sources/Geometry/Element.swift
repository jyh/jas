import Foundation

/// Line segments per Bezier curve when flattening paths.
public let elementFlattenSteps = 20

// MARK: - SVG presentation attributes

/// RGBA color with components in [0, 1].
public struct Color: Equatable, Hashable {
    public let r: Double
    public let g: Double
    public let b: Double
    public let a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1.0) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

/// SVG stroke-linecap.
public enum LineCap: Equatable, Hashable {
    case butt
    case round
    case square
}

/// SVG stroke-linejoin.
public enum LineJoin: Equatable, Hashable {
    case miter
    case round
    case bevel
}

/// SVG fill presentation attribute.
public struct Fill: Equatable, Hashable {
    public let color: Color
    public init(color: Color) { self.color = color }
}

/// SVG stroke presentation attributes.
public struct Stroke: Equatable, Hashable {
    public let color: Color
    public let width: Double
    public let linecap: LineCap
    public let linejoin: LineJoin

    public init(color: Color, width: Double = 1.0, linecap: LineCap = .butt, linejoin: LineJoin = .miter) {
        self.color = color
        self.width = width
        self.linecap = linecap
        self.linejoin = linejoin
    }
}

/// SVG transform as a 2D affine matrix [a b c d e f].
public struct Transform: Equatable, Hashable {
    public let a: Double, b: Double, c: Double, d: Double, e: Double, f: Double

    public init(a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, e: Double = 0, f: Double = 0) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }

    public static func translate(_ tx: Double, _ ty: Double) -> Transform {
        Transform(e: tx, f: ty)
    }

    public static func scale(_ sx: Double, _ sy: Double? = nil) -> Transform {
        Transform(a: sx, d: sy ?? sx)
    }

    public static func rotate(_ angleDeg: Double) -> Transform {
        let rad = angleDeg * .pi / 180
        return Transform(a: cos(rad), b: sin(rad), c: -sin(rad), d: cos(rad))
    }
}

// MARK: - SVG path commands

/// SVG path commands (the 'd' attribute).
public enum PathCommand: Equatable {
    /// M x y
    case moveTo(Double, Double)
    /// L x y
    case lineTo(Double, Double)
    /// C x1 y1 x2 y2 x y
    case curveTo(x1: Double, y1: Double, x2: Double, y2: Double, x: Double, y: Double)
    /// S x2 y2 x y
    case smoothCurveTo(x2: Double, y2: Double, x: Double, y: Double)
    /// Q x1 y1 x y
    case quadTo(x1: Double, y1: Double, x: Double, y: Double)
    /// T x y
    case smoothQuadTo(Double, Double)
    /// A rx ry rotation largeArc sweep x y
    case arcTo(rx: Double, ry: Double, rotation: Double, largeArc: Bool, sweep: Bool, x: Double, y: Double)
    /// Z
    case closePath

    /// The endpoint of this command, if any.
    public var endpoint: (Double, Double)? {
        switch self {
        case .moveTo(let x, let y), .lineTo(let x, let y), .smoothQuadTo(let x, let y):
            return (x, y)
        case .curveTo(_, _, _, _, let x, let y), .smoothCurveTo(_, _, let x, let y):
            return (x, y)
        case .quadTo(_, _, let x, let y):
            return (x, y)
        case .arcTo(_, _, _, _, _, let x, let y):
            return (x, y)
        case .closePath:
            return nil
        }
    }
}

// MARK: - SVG Elements

/// Bounding box as (x, y, width, height).
public typealias BBox = (x: Double, y: Double, width: Double, height: Double)

/// Expand a bounding box by half the stroke width on all sides.
private func inflateBounds(_ bbox: BBox, _ stroke: Stroke?) -> BBox {
    guard let stroke = stroke else { return bbox }
    let half = stroke.width / 2.0
    return (bbox.x - half, bbox.y - half, bbox.width + stroke.width, bbox.height + stroke.width)
}

/// An SVG document element. All elements are immutable value types.
public enum Element: Equatable {
    /// SVG \<line\>
    case line(Line)
    /// SVG \<rect\>
    case rect(Rect)
    /// SVG \<circle\>
    case circle(Circle)
    /// SVG \<ellipse\>
    case ellipse(Ellipse)
    /// SVG \<polyline\>
    case polyline(Polyline)
    /// SVG \<polygon\>
    case polygon(Polygon)
    /// SVG \<path\>
    case path(Path)
    /// SVG \<text\>
    case text(Text)
    /// SVG \<text\>\<textPath\>
    case textPath(TextPath)
    /// SVG \<g\>
    case group(Group)
    /// Named layer
    case layer(Layer)

    public var bounds: BBox {
        switch self {
        case .line(let v): return v.bounds
        case .rect(let v): return v.bounds
        case .circle(let v): return v.bounds
        case .ellipse(let v): return v.bounds
        case .polyline(let v): return v.bounds
        case .polygon(let v): return v.bounds
        case .path(let v): return v.bounds
        case .text(let v): return v.bounds
        case .textPath(let v): return v.bounds
        case .group(let v): return v.bounds
        case .layer(let v): return v.bounds
        }
    }

    public var controlPointCount: Int {
        switch self {
        case .line: return 2
        case .rect, .circle, .ellipse: return 4
        case .polygon(let v): return v.points.count
        case .path(let v): return pathAnchorPoints(v.d).count
        case .textPath(let v): return pathAnchorPoints(v.d).count
        default: return 4
        }
    }

    public var controlPointPositions: [(Double, Double)] {
        switch self {
        case .line(let v):
            return [(v.x1, v.y1), (v.x2, v.y2)]
        case .rect(let v):
            return [(v.x, v.y), (v.x + v.width, v.y),
                    (v.x + v.width, v.y + v.height), (v.x, v.y + v.height)]
        case .circle(let v):
            return [(v.cx, v.cy - v.r), (v.cx + v.r, v.cy),
                    (v.cx, v.cy + v.r), (v.cx - v.r, v.cy)]
        case .ellipse(let v):
            return [(v.cx, v.cy - v.ry), (v.cx + v.rx, v.cy),
                    (v.cx, v.cy + v.ry), (v.cx - v.rx, v.cy)]
        case .polygon(let v):
            return v.points
        case .path(let v):
            return pathAnchorPoints(v.d)
        case .textPath(let v):
            return pathAnchorPoints(v.d)
        default:
            let b = self.bounds
            return [(b.x, b.y), (b.x + b.width, b.y),
                    (b.x + b.width, b.y + b.height), (b.x, b.y + b.height)]
        }
    }

    public func moveControlPoints(_ indices: Set<Int>, dx: Double, dy: Double) -> Element {
        switch self {
        case .line(let v):
            return .line(Line(
                x1: v.x1 + (indices.contains(0) ? dx : 0),
                y1: v.y1 + (indices.contains(0) ? dy : 0),
                x2: v.x2 + (indices.contains(1) ? dx : 0),
                y2: v.y2 + (indices.contains(1) ? dy : 0),
                stroke: v.stroke, opacity: v.opacity, transform: v.transform))
        case .rect(let v):
            if indices.count >= 4 {
                return .rect(Rect(x: v.x + dx, y: v.y + dy, width: v.width, height: v.height,
                                     rx: v.rx, ry: v.ry, fill: v.fill, stroke: v.stroke,
                                     opacity: v.opacity, transform: v.transform))
            }
            var pts = [(v.x, v.y), (v.x + v.width, v.y),
                       (v.x + v.width, v.y + v.height), (v.x, v.y + v.height)]
            for i in 0..<4 where indices.contains(i) {
                pts[i] = (pts[i].0 + dx, pts[i].1 + dy)
            }
            return .polygon(Polygon(points: pts,
                                       fill: v.fill, stroke: v.stroke,
                                       opacity: v.opacity, transform: v.transform))
        case .circle(let v):
            if indices.count >= 4 {
                return .circle(Circle(cx: v.cx + dx, cy: v.cy + dy, r: v.r,
                                         fill: v.fill, stroke: v.stroke,
                                         opacity: v.opacity, transform: v.transform))
            }
            var cps = [(v.cx, v.cy - v.r), (v.cx + v.r, v.cy),
                       (v.cx, v.cy + v.r), (v.cx - v.r, v.cy)]
            for i in 0..<4 where indices.contains(i) {
                cps[i] = (cps[i].0 + dx, cps[i].1 + dy)
            }
            let ncx = (cps[1].0 + cps[3].0) / 2
            let ncy = (cps[0].1 + cps[2].1) / 2
            let nr = max(abs(cps[1].0 - ncx), abs(cps[0].1 - ncy))
            return .circle(Circle(cx: ncx, cy: ncy, r: nr,
                                     fill: v.fill, stroke: v.stroke,
                                     opacity: v.opacity, transform: v.transform))
        case .ellipse(let v):
            if indices.count >= 4 {
                return .ellipse(Ellipse(cx: v.cx + dx, cy: v.cy + dy, rx: v.rx, ry: v.ry,
                                           fill: v.fill, stroke: v.stroke,
                                           opacity: v.opacity, transform: v.transform))
            }
            var cps = [(v.cx, v.cy - v.ry), (v.cx + v.rx, v.cy),
                       (v.cx, v.cy + v.ry), (v.cx - v.rx, v.cy)]
            for i in 0..<4 where indices.contains(i) {
                cps[i] = (cps[i].0 + dx, cps[i].1 + dy)
            }
            let ncx = (cps[1].0 + cps[3].0) / 2
            let ncy = (cps[0].1 + cps[2].1) / 2
            return .ellipse(Ellipse(cx: ncx, cy: ncy,
                                       rx: abs(cps[1].0 - ncx), ry: abs(cps[0].1 - ncy),
                                       fill: v.fill, stroke: v.stroke,
                                       opacity: v.opacity, transform: v.transform))
        case .polygon(let v):
            let newPoints = v.points.enumerated().map { (i, pt) in
                indices.contains(i) ? (pt.0 + dx, pt.1 + dy) : pt
            }
            return .polygon(Polygon(points: newPoints,
                                       fill: v.fill, stroke: v.stroke,
                                       opacity: v.opacity, transform: v.transform))
        case .path(let v):
            var cmds = v.d
            var anchorIdx = 0
            for ci in 0..<cmds.count {
                switch cmds[ci] {
                case .closePath:
                    continue
                default:
                    break
                }
                if indices.contains(anchorIdx) {
                    switch cmds[ci] {
                    case .moveTo(let x, let y):
                        cmds[ci] = .moveTo(x + dx, y + dy)
                        if ci + 1 < cmds.count,
                           case .curveTo(let x1, let y1, let x2, let y2, let ex, let ey) = cmds[ci + 1] {
                            cmds[ci + 1] = .curveTo(x1: x1 + dx, y1: y1 + dy, x2: x2, y2: y2, x: ex, y: ey)
                        }
                    case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
                        cmds[ci] = .curveTo(x1: x1, y1: y1, x2: x2 + dx, y2: y2 + dy, x: x + dx, y: y + dy)
                        if ci + 1 < cmds.count,
                           case .curveTo(let nx1, let ny1, let nx2, let ny2, let nx, let ny) = cmds[ci + 1] {
                            cmds[ci + 1] = .curveTo(x1: nx1 + dx, y1: ny1 + dy, x2: nx2, y2: ny2, x: nx, y: ny)
                        }
                    case .lineTo(let x, let y):
                        cmds[ci] = .lineTo(x + dx, y + dy)
                    default:
                        break
                    }
                }
                anchorIdx += 1
            }
            return .path(Path(d: cmds, fill: v.fill, stroke: v.stroke,
                                 opacity: v.opacity, transform: v.transform))
        case .textPath(let v):
            var cmds = v.d
            var anchorIdx = 0
            for ci in 0..<cmds.count {
                switch cmds[ci] {
                case .closePath:
                    continue
                default:
                    break
                }
                if indices.contains(anchorIdx) {
                    switch cmds[ci] {
                    case .moveTo(let x, let y):
                        cmds[ci] = .moveTo(x + dx, y + dy)
                        if ci + 1 < cmds.count,
                           case .curveTo(let x1, let y1, let x2, let y2, let ex, let ey) = cmds[ci + 1] {
                            cmds[ci + 1] = .curveTo(x1: x1 + dx, y1: y1 + dy, x2: x2, y2: y2, x: ex, y: ey)
                        }
                    case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
                        cmds[ci] = .curveTo(x1: x1, y1: y1, x2: x2 + dx, y2: y2 + dy, x: x + dx, y: y + dy)
                        if ci + 1 < cmds.count,
                           case .curveTo(let nx1, let ny1, let nx2, let ny2, let nx, let ny) = cmds[ci + 1] {
                            cmds[ci + 1] = .curveTo(x1: nx1 + dx, y1: ny1 + dy, x2: nx2, y2: ny2, x: nx, y: ny)
                        }
                    case .lineTo(let x, let y):
                        cmds[ci] = .lineTo(x + dx, y + dy)
                    default:
                        break
                    }
                }
                anchorIdx += 1
            }
            return .textPath(TextPath(d: cmds, content: v.content,
                                          startOffset: v.startOffset,
                                          fontFamily: v.fontFamily, fontSize: v.fontSize,
                                          fill: v.fill, stroke: v.stroke,
                                          opacity: v.opacity, transform: v.transform))
        default:
            return self
        }
    }
}

/// Extract anchor points from path commands.
private func pathAnchorPoints(_ d: [PathCommand]) -> [(Double, Double)] {
    var pts: [(Double, Double)] = []
    for cmd in d {
        switch cmd {
        case .moveTo(let x, let y), .lineTo(let x, let y), .smoothQuadTo(let x, let y):
            pts.append((x, y))
        case .curveTo(_, _, _, _, let x, let y), .smoothCurveTo(_, _, let x, let y):
            pts.append((x, y))
        case .quadTo(_, _, let x, let y):
            pts.append((x, y))
        case .arcTo(_, _, _, _, _, let x, let y):
            pts.append((x, y))
        case .closePath:
            break
        }
    }
    return pts
}

/// Return (incoming_handle, outgoing_handle) for a path anchor.
/// Returns nil for a handle that doesn't exist or coincides with its anchor.
public func pathHandlePositions(_ d: [PathCommand], anchorIdx: Int)
    -> ((Double, Double)?, (Double, Double)?) {
    // Map anchor indices to command indices (skip closePath)
    var cmdIndices: [Int] = []
    for (ci, cmd) in d.enumerated() {
        if case .closePath = cmd { continue }
        cmdIndices.append(ci)
    }
    guard anchorIdx >= 0, anchorIdx < cmdIndices.count else { return (nil, nil) }
    let ci = cmdIndices[anchorIdx]
    let cmd = d[ci]
    // Anchor position
    let ax: Double, ay: Double
    switch cmd {
    case .moveTo(let x, let y), .lineTo(let x, let y):
        ax = x; ay = y
    case .curveTo(_, _, _, _, let x, let y):
        ax = x; ay = y
    default:
        return (nil, nil)
    }
    // Incoming handle: (x2, y2) of this CurveTo
    var hIn: (Double, Double)? = nil
    if case .curveTo(_, _, let x2, let y2, _, _) = cmd {
        if abs(x2 - ax) > 0.01 || abs(y2 - ay) > 0.01 {
            hIn = (x2, y2)
        }
    }
    // Outgoing handle: (x1, y1) of next CurveTo
    var hOut: (Double, Double)? = nil
    if ci + 1 < d.count, case .curveTo(let x1, let y1, _, _, _, _) = d[ci + 1] {
        if abs(x1 - ax) > 0.01 || abs(y1 - ay) > 0.01 {
            hOut = (x1, y1)
        }
    }
    return (hIn, hOut)
}

/// Rotate the opposite handle to be collinear, preserving its distance from the anchor.
private func reflectHandleKeepDistance(ax: Double, ay: Double,
                                       nhx: Double, nhy: Double,
                                       oppHx: Double, oppHy: Double) -> (Double, Double) {
    let dnx = nhx - ax, dny = nhy - ay
    let distNew = hypot(dnx, dny)
    let distOpp = hypot(oppHx - ax, oppHy - ay)
    guard distNew >= 1e-6 else { return (oppHx, oppHy) }
    let scale = -distOpp / distNew
    return (ax + dnx * scale, ay + dny * scale)
}

/// Move a specific handle ('in' or 'out') of a path anchor by (dx, dy).
public func movePathHandle(_ d: [PathCommand], anchorIdx: Int, handleType: String,
                           dx: Double, dy: Double) -> [PathCommand] {
    var cmdIndices: [Int] = []
    for (ci, cmd) in d.enumerated() {
        if case .closePath = cmd { continue }
        cmdIndices.append(ci)
    }
    guard anchorIdx >= 0, anchorIdx < cmdIndices.count else { return d }
    let ci = cmdIndices[anchorIdx]
    let cmd = d[ci]
    // Get anchor position
    let ax: Double, ay: Double
    switch cmd {
    case .moveTo(let x, let y), .lineTo(let x, let y):
        ax = x; ay = y
    case .curveTo(_, _, _, _, let x, let y):
        ax = x; ay = y
    default:
        return d
    }
    var cmds = d
    if handleType == "in" {
        if case .curveTo(let x1, let y1, let x2, let y2, let x, let y) = cmds[ci] {
            let nhx = x2 + dx, nhy = y2 + dy
            cmds[ci] = .curveTo(x1: x1, y1: y1, x2: nhx, y2: nhy, x: x, y: y)
            // Rotate opposite (out) handle to stay collinear, keep its distance
            if ci + 1 < cmds.count,
               case .curveTo(let ox1, let oy1, let nx2, let ny2, let nx, let ny) = cmds[ci + 1] {
                let (rx, ry) = reflectHandleKeepDistance(ax: ax, ay: ay, nhx: nhx, nhy: nhy, oppHx: ox1, oppHy: oy1)
                cmds[ci + 1] = .curveTo(x1: rx, y1: ry, x2: nx2, y2: ny2, x: nx, y: ny)
            }
        }
    } else if handleType == "out" {
        if ci + 1 < cmds.count,
           case .curveTo(let x1, let y1, let x2, let y2, let x, let y) = cmds[ci + 1] {
            let nhx = x1 + dx, nhy = y1 + dy
            cmds[ci + 1] = .curveTo(x1: nhx, y1: nhy, x2: x2, y2: y2, x: x, y: y)
            // Rotate opposite (in) handle to stay collinear, keep its distance
            if case .curveTo(let cx1, let cy1, let cx2, let cy2, let cx, let cy) = cmds[ci] {
                let (rx, ry) = reflectHandleKeepDistance(ax: ax, ay: ay, nhx: nhx, nhy: nhy, oppHx: cx2, oppHy: cy2)
                cmds[ci] = .curveTo(x1: cx1, y1: cy1, x2: rx, y2: ry, x: cx, y: cy)
            }
        }
    }
    return cmds
}

/// SVG \<line\> element.
public struct Line: Equatable {
    public let x1: Double, y1: Double, x2: Double, y2: Double
    public let stroke: Stroke?
    public let opacity: Double
    public let transform: Transform?

    public init(x1: Double, y1: Double, x2: Double, y2: Double,
                stroke: Stroke? = nil, opacity: Double = 1.0, transform: Transform? = nil) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
        self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox {
        let minX = min(x1, x2), minY = min(y1, y2)
        return inflateBounds((minX, minY, abs(x2 - x1), abs(y2 - y1)), stroke)
    }
}

/// SVG \<rect\> element.
public struct Rect: Equatable {
    public let x: Double, y: Double, width: Double, height: Double
    public let rx: Double, ry: Double
    public let fill: Fill?
    public let stroke: Stroke?
    public let opacity: Double
    public let transform: Transform?

    public init(x: Double, y: Double, width: Double, height: Double,
                rx: Double = 0, ry: Double = 0,
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.rx = rx; self.ry = ry
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox { inflateBounds((x, y, width, height), stroke) }
}

/// SVG \<circle\> element.
public struct Circle: Equatable {
    public let cx: Double, cy: Double, r: Double
    public let fill: Fill?
    public let stroke: Stroke?
    public let opacity: Double
    public let transform: Transform?

    public init(cx: Double, cy: Double, r: Double,
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil) {
        self.cx = cx; self.cy = cy; self.r = r
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox { inflateBounds((cx - r, cy - r, r * 2, r * 2), stroke) }
}

/// SVG \<ellipse\> element.
public struct Ellipse: Equatable {
    public let cx: Double, cy: Double, rx: Double, ry: Double
    public let fill: Fill?
    public let stroke: Stroke?
    public let opacity: Double
    public let transform: Transform?

    public init(cx: Double, cy: Double, rx: Double, ry: Double,
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil) {
        self.cx = cx; self.cy = cy; self.rx = rx; self.ry = ry
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox { inflateBounds((cx - rx, cy - ry, rx * 2, ry * 2), stroke) }
}

/// SVG \<polyline\> element.
public struct Polyline: Equatable {
    public let points: [(Double, Double)]
    public let fill: Fill?
    public let stroke: Stroke?
    public let opacity: Double
    public let transform: Transform?

    public init(points: [(Double, Double)],
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil) {
        self.points = points
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox {
        guard !points.isEmpty else { return (0, 0, 0, 0) }
        let xs = points.map(\.0), ys = points.map(\.1)
        let minX = xs.min()!, minY = ys.min()!
        return inflateBounds((minX, minY, xs.max()! - minX, ys.max()! - minY), stroke)
    }

    public static func == (lhs: Polyline, rhs: Polyline) -> Bool {
        lhs.points.count == rhs.points.count
            && zip(lhs.points, rhs.points).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            && lhs.fill == rhs.fill && lhs.stroke == rhs.stroke
            && lhs.opacity == rhs.opacity && lhs.transform == rhs.transform
    }
}

/// SVG \<polygon\> element.
public struct Polygon: Equatable {
    public let points: [(Double, Double)]
    public let fill: Fill?
    public let stroke: Stroke?
    public let opacity: Double
    public let transform: Transform?

    public init(points: [(Double, Double)],
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil) {
        self.points = points
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox {
        guard !points.isEmpty else { return (0, 0, 0, 0) }
        let xs = points.map(\.0), ys = points.map(\.1)
        let minX = xs.min()!, minY = ys.min()!
        return inflateBounds((minX, minY, xs.max()! - minX, ys.max()! - minY), stroke)
    }

    public static func == (lhs: Polygon, rhs: Polygon) -> Bool {
        lhs.points.count == rhs.points.count
            && zip(lhs.points, rhs.points).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            && lhs.fill == rhs.fill && lhs.stroke == rhs.stroke
            && lhs.opacity == rhs.opacity && lhs.transform == rhs.transform
    }
}

/// SVG \<path\> element.
/// Approximate bounds from path command endpoints.
func pathBounds(_ d: [PathCommand]) -> BBox {
    let endpoints = d.compactMap(\.endpoint)
    guard !endpoints.isEmpty else { return (0, 0, 0, 0) }
    let xs = endpoints.map(\.0), ys = endpoints.map(\.1)
    let minX = xs.min()!, minY = ys.min()!
    return (minX, minY, xs.max()! - minX, ys.max()! - minY)
}

public struct Path: Equatable {
    public let d: [PathCommand]
    public let fill: Fill?
    public let stroke: Stroke?
    public let opacity: Double
    public let transform: Transform?

    public init(d: [PathCommand],
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil) {
        self.d = d
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox {
        return inflateBounds(pathBounds(d), stroke)
    }
}

/// SVG \<text\> element.
public struct Text: Equatable {
    public let x: Double, y: Double
    public let content: String
    public let fontFamily: String
    public let fontSize: Double
    public let fontWeight: String
    public let fontStyle: String
    public let textDecoration: String
    public let width: Double
    public let height: Double
    public let fill: Fill?
    public let stroke: Stroke?
    public let opacity: Double
    public let transform: Transform?

    public init(x: Double, y: Double, content: String,
                fontFamily: String = "sans-serif", fontSize: Double = 16.0,
                fontWeight: String = "normal", fontStyle: String = "normal",
                textDecoration: String = "none",
                width: Double = 0, height: Double = 0,
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil) {
        self.x = x; self.y = y; self.content = content
        self.fontFamily = fontFamily; self.fontSize = fontSize
        self.fontWeight = fontWeight; self.fontStyle = fontStyle; self.textDecoration = textDecoration
        self.width = width; self.height = height
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var isAreaText: Bool { width > 0 && height > 0 }

    public var bounds: BBox {
        if isAreaText {
            return (x, y, width, height)
        }
        let approxWidth = Double(content.count) * fontSize * 0.6
        return (x, y - fontSize, approxWidth, fontSize)
    }
}

/// SVG \<text\>\<textPath\> — text rendered along a path.
public struct TextPath: Equatable {
    public let d: [PathCommand]
    public let content: String
    public let startOffset: Double
    public let fontFamily: String
    public let fontSize: Double
    public let fontWeight: String
    public let fontStyle: String
    public let textDecoration: String
    public let fill: Fill?
    public let stroke: Stroke?
    public let opacity: Double
    public let transform: Transform?

    public init(d: [PathCommand], content: String = "Lorem Ipsum",
                startOffset: Double = 0.0,
                fontFamily: String = "sans-serif", fontSize: Double = 16.0,
                fontWeight: String = "normal", fontStyle: String = "normal",
                textDecoration: String = "none",
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil) {
        self.d = d; self.content = content; self.startOffset = startOffset
        self.fontFamily = fontFamily; self.fontSize = fontSize
        self.fontWeight = fontWeight; self.fontStyle = fontStyle; self.textDecoration = textDecoration
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox {
        return inflateBounds(pathBounds(d), stroke)
    }
}

/// SVG \<g\> element.
public struct Group: Equatable {
    public let children: [Element]
    public let opacity: Double
    public let transform: Transform?

    public init(children: [Element], opacity: Double = 1.0, transform: Transform? = nil) {
        self.children = children
        self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox {
        guard !children.isEmpty else { return (0, 0, 0, 0) }
        let all = children.map(\.bounds)
        let minX = all.map(\.x).min()!, minY = all.map(\.y).min()!
        let maxX = all.map { $0.x + $0.width }.max()!
        let maxY = all.map { $0.y + $0.height }.max()!
        return (minX, minY, maxX - minX, maxY - minY)
    }
}

/// A named group (layer) of elements.
public struct Layer: Equatable {
    public let name: String
    public let children: [Element]
    public let opacity: Double
    public let transform: Transform?

    public init(name: String = "Layer", children: [Element], opacity: Double = 1.0, transform: Transform? = nil) {
        self.name = name
        self.children = children
        self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox {
        guard !children.isEmpty else { return (0, 0, 0, 0) }
        let all = children.map(\.bounds)
        let minX = all.map(\.x).min()!, minY = all.map(\.y).min()!
        let maxX = all.map { $0.x + $0.width }.max()!
        let maxY = all.map { $0.y + $0.height }.max()!
        return (minX, minY, maxX - minX, maxY - minY)
    }
}

// MARK: - Path geometry utilities

/// Flatten path commands into a polyline by evaluating Bezier curves.
public func flattenPathCommands(_ d: [PathCommand]) -> [(Double, Double)] {
    var pts: [(Double, Double)] = []
    var cx = 0.0, cy = 0.0
    let steps = elementFlattenSteps
    var firstPt = (0.0, 0.0)
    for cmd in d {
        switch cmd {
        case .moveTo(let x, let y):
            pts.append((x, y))
            cx = x; cy = y; firstPt = (x, y)
        case .lineTo(let x, let y):
            pts.append((x, y))
            cx = x; cy = y
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let mt = 1.0 - t
                let px = mt*mt*mt*cx + 3*mt*mt*t*x1 + 3*mt*t*t*x2 + t*t*t*x
                let py = mt*mt*mt*cy + 3*mt*mt*t*y1 + 3*mt*t*t*y2 + t*t*t*y
                pts.append((px, py))
            }
            cx = x; cy = y
        case .quadTo(let x1, let y1, let x, let y):
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let mt = 1.0 - t
                let px = mt*mt*cx + 2*mt*t*x1 + t*t*x
                let py = mt*mt*cy + 2*mt*t*y1 + t*t*y
                pts.append((px, py))
            }
            cx = x; cy = y
        case .closePath:
            pts.append(firstPt)
        default:
            if let ep = cmd.endpoint {
                pts.append(ep)
                cx = ep.0; cy = ep.1
            }
        }
    }
    return pts
}

/// Compute cumulative arc lengths for a polyline.
private func arcLengths(_ pts: [(Double, Double)]) -> [Double] {
    var lengths = [0.0]
    for i in 1..<pts.count {
        let dx = pts[i].0 - pts[i-1].0
        let dy = pts[i].1 - pts[i-1].1
        lengths.append(lengths.last! + (dx*dx + dy*dy).squareRoot())
    }
    return lengths
}

/// Return the (x, y) point at fraction t (0..1) along the path.
public func pathPointAtOffset(_ d: [PathCommand], t: Double) -> (Double, Double) {
    let pts = flattenPathCommands(d)
    guard pts.count >= 2 else { return pts.first ?? (0, 0) }
    let lengths = arcLengths(pts)
    let total = lengths.last!
    guard total > 0 else { return pts[0] }
    let target = max(0, min(1, t)) * total
    for i in 1..<lengths.count {
        if lengths[i] >= target {
            let segLen = lengths[i] - lengths[i-1]
            if segLen == 0 { return pts[i] }
            let frac = (target - lengths[i-1]) / segLen
            return (pts[i-1].0 + frac * (pts[i].0 - pts[i-1].0),
                    pts[i-1].1 + frac * (pts[i].1 - pts[i-1].1))
        }
    }
    return pts.last!
}

/// Return the offset (0..1) of the closest point on the path to (px, py).
public func pathClosestOffset(_ d: [PathCommand], px: Double, py: Double) -> Double {
    let pts = flattenPathCommands(d)
    guard pts.count >= 2 else { return 0 }
    let lengths = arcLengths(pts)
    let total = lengths.last!
    guard total > 0 else { return 0 }
    var bestDist = Double.infinity
    var bestOffset = 0.0
    for i in 1..<pts.count {
        let (ax, ay) = pts[i-1]
        let (bx, by) = pts[i]
        let dx = bx - ax, dy = by - ay
        let segLenSq = dx*dx + dy*dy
        guard segLenSq > 0 else { continue }
        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / segLenSq))
        let qx = ax + t * dx, qy = ay + t * dy
        let dist = ((px - qx) * (px - qx) + (py - qy) * (py - qy)).squareRoot()
        if dist < bestDist {
            bestDist = dist
            bestOffset = (lengths[i-1] + t * (lengths[i] - lengths[i-1])) / total
        }
    }
    return bestOffset
}

/// Return the minimum distance from point (px, py) to the path curve.
public func pathDistanceToPoint(_ d: [PathCommand], px: Double, py: Double) -> Double {
    let pts = flattenPathCommands(d)
    guard pts.count >= 2 else {
        if let p = pts.first {
            return ((px - p.0) * (px - p.0) + (py - p.1) * (py - p.1)).squareRoot()
        }
        return .infinity
    }
    var bestDist = Double.infinity
    for i in 1..<pts.count {
        let (ax, ay) = pts[i-1]
        let (bx, by) = pts[i]
        let dx = bx - ax, dy = by - ay
        let segLenSq = dx*dx + dy*dy
        guard segLenSq > 0 else { continue }
        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / segLenSq))
        let qx = ax + t * dx, qy = ay + t * dy
        let dist = ((px - qx) * (px - qx) + (py - qy) * (py - qy)).squareRoot()
        if dist < bestDist { bestDist = dist }
    }
    return bestDist
}
