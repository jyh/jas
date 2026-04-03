import Foundation

// MARK: - SVG presentation attributes

/// RGBA color with components in [0, 1].
public struct JasColor: Equatable, Hashable {
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
public struct JasFill: Equatable, Hashable {
    public let color: JasColor
    public init(color: JasColor) { self.color = color }
}

/// SVG stroke presentation attributes.
public struct JasStroke: Equatable, Hashable {
    public let color: JasColor
    public let width: Double
    public let linecap: LineCap
    public let linejoin: LineJoin

    public init(color: JasColor, width: Double = 1.0, linecap: LineCap = .butt, linejoin: LineJoin = .miter) {
        self.color = color
        self.width = width
        self.linecap = linecap
        self.linejoin = linejoin
    }
}

/// SVG transform as a 2D affine matrix [a b c d e f].
public struct JasTransform: Equatable, Hashable {
    public let a: Double, b: Double, c: Double, d: Double, e: Double, f: Double

    public init(a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, e: Double = 0, f: Double = 0) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }

    public static func translate(_ tx: Double, _ ty: Double) -> JasTransform {
        JasTransform(e: tx, f: ty)
    }

    public static func scale(_ sx: Double, _ sy: Double? = nil) -> JasTransform {
        JasTransform(a: sx, d: sy ?? sx)
    }

    public static func rotate(_ angleDeg: Double) -> JasTransform {
        let rad = angleDeg * .pi / 180
        return JasTransform(a: cos(rad), b: sin(rad), c: -sin(rad), d: cos(rad))
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

/// An SVG document element. All elements are immutable value types.
public enum Element: Equatable {
    /// SVG \<line\>
    case line(JasLine)
    /// SVG \<rect\>
    case rect(JasRect)
    /// SVG \<circle\>
    case circle(JasCircle)
    /// SVG \<ellipse\>
    case ellipse(JasEllipse)
    /// SVG \<polyline\>
    case polyline(JasPolyline)
    /// SVG \<polygon\>
    case polygon(JasPolygon)
    /// SVG \<path\>
    case path(JasPath)
    /// SVG \<text\>
    case text(JasText)
    /// SVG \<g\>
    case group(JasGroup)
    /// Named layer
    case layer(JasLayer)

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
        case .group(let v): return v.bounds
        case .layer(let v): return v.bounds
        }
    }
}

/// SVG \<line\> element.
public struct JasLine: Equatable {
    public let x1: Double, y1: Double, x2: Double, y2: Double
    public let stroke: JasStroke?
    public let opacity: Double
    public let transform: JasTransform?

    public init(x1: Double, y1: Double, x2: Double, y2: Double,
                stroke: JasStroke? = nil, opacity: Double = 1.0, transform: JasTransform? = nil) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
        self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox {
        let minX = min(x1, x2), minY = min(y1, y2)
        return (minX, minY, abs(x2 - x1), abs(y2 - y1))
    }
}

/// SVG \<rect\> element.
public struct JasRect: Equatable {
    public let x: Double, y: Double, width: Double, height: Double
    public let rx: Double, ry: Double
    public let fill: JasFill?
    public let stroke: JasStroke?
    public let opacity: Double
    public let transform: JasTransform?

    public init(x: Double, y: Double, width: Double, height: Double,
                rx: Double = 0, ry: Double = 0,
                fill: JasFill? = nil, stroke: JasStroke? = nil,
                opacity: Double = 1.0, transform: JasTransform? = nil) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.rx = rx; self.ry = ry
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox { (x, y, width, height) }
}

/// SVG \<circle\> element.
public struct JasCircle: Equatable {
    public let cx: Double, cy: Double, r: Double
    public let fill: JasFill?
    public let stroke: JasStroke?
    public let opacity: Double
    public let transform: JasTransform?

    public init(cx: Double, cy: Double, r: Double,
                fill: JasFill? = nil, stroke: JasStroke? = nil,
                opacity: Double = 1.0, transform: JasTransform? = nil) {
        self.cx = cx; self.cy = cy; self.r = r
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox { (cx - r, cy - r, r * 2, r * 2) }
}

/// SVG \<ellipse\> element.
public struct JasEllipse: Equatable {
    public let cx: Double, cy: Double, rx: Double, ry: Double
    public let fill: JasFill?
    public let stroke: JasStroke?
    public let opacity: Double
    public let transform: JasTransform?

    public init(cx: Double, cy: Double, rx: Double, ry: Double,
                fill: JasFill? = nil, stroke: JasStroke? = nil,
                opacity: Double = 1.0, transform: JasTransform? = nil) {
        self.cx = cx; self.cy = cy; self.rx = rx; self.ry = ry
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox { (cx - rx, cy - ry, rx * 2, ry * 2) }
}

/// SVG \<polyline\> element.
public struct JasPolyline: Equatable {
    public let points: [(Double, Double)]
    public let fill: JasFill?
    public let stroke: JasStroke?
    public let opacity: Double
    public let transform: JasTransform?

    public init(points: [(Double, Double)],
                fill: JasFill? = nil, stroke: JasStroke? = nil,
                opacity: Double = 1.0, transform: JasTransform? = nil) {
        self.points = points
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox {
        guard !points.isEmpty else { return (0, 0, 0, 0) }
        let xs = points.map(\.0), ys = points.map(\.1)
        let minX = xs.min()!, minY = ys.min()!
        return (minX, minY, xs.max()! - minX, ys.max()! - minY)
    }

    public static func == (lhs: JasPolyline, rhs: JasPolyline) -> Bool {
        lhs.points.count == rhs.points.count
            && zip(lhs.points, rhs.points).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            && lhs.fill == rhs.fill && lhs.stroke == rhs.stroke
            && lhs.opacity == rhs.opacity && lhs.transform == rhs.transform
    }
}

/// SVG \<polygon\> element.
public struct JasPolygon: Equatable {
    public let points: [(Double, Double)]
    public let fill: JasFill?
    public let stroke: JasStroke?
    public let opacity: Double
    public let transform: JasTransform?

    public init(points: [(Double, Double)],
                fill: JasFill? = nil, stroke: JasStroke? = nil,
                opacity: Double = 1.0, transform: JasTransform? = nil) {
        self.points = points
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox {
        guard !points.isEmpty else { return (0, 0, 0, 0) }
        let xs = points.map(\.0), ys = points.map(\.1)
        let minX = xs.min()!, minY = ys.min()!
        return (minX, minY, xs.max()! - minX, ys.max()! - minY)
    }

    public static func == (lhs: JasPolygon, rhs: JasPolygon) -> Bool {
        lhs.points.count == rhs.points.count
            && zip(lhs.points, rhs.points).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            && lhs.fill == rhs.fill && lhs.stroke == rhs.stroke
            && lhs.opacity == rhs.opacity && lhs.transform == rhs.transform
    }
}

/// SVG \<path\> element.
public struct JasPath: Equatable {
    public let d: [PathCommand]
    public let fill: JasFill?
    public let stroke: JasStroke?
    public let opacity: Double
    public let transform: JasTransform?

    public init(d: [PathCommand],
                fill: JasFill? = nil, stroke: JasStroke? = nil,
                opacity: Double = 1.0, transform: JasTransform? = nil) {
        self.d = d
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox {
        let endpoints = d.compactMap(\.endpoint)
        guard !endpoints.isEmpty else { return (0, 0, 0, 0) }
        let xs = endpoints.map(\.0), ys = endpoints.map(\.1)
        let minX = xs.min()!, minY = ys.min()!
        return (minX, minY, xs.max()! - minX, ys.max()! - minY)
    }
}

/// SVG \<text\> element.
public struct JasText: Equatable {
    public let x: Double, y: Double
    public let content: String
    public let fontFamily: String
    public let fontSize: Double
    public let fill: JasFill?
    public let stroke: JasStroke?
    public let opacity: Double
    public let transform: JasTransform?

    public init(x: Double, y: Double, content: String,
                fontFamily: String = "sans-serif", fontSize: Double = 16.0,
                fill: JasFill? = nil, stroke: JasStroke? = nil,
                opacity: Double = 1.0, transform: JasTransform? = nil) {
        self.x = x; self.y = y; self.content = content
        self.fontFamily = fontFamily; self.fontSize = fontSize
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
    }

    public var bounds: BBox {
        let approxWidth = Double(content.count) * fontSize * 0.6
        return (x, y - fontSize, approxWidth, fontSize)
    }
}

/// SVG \<g\> element.
public struct JasGroup: Equatable {
    public let children: [Element]
    public let opacity: Double
    public let transform: JasTransform?

    public init(children: [Element], opacity: Double = 1.0, transform: JasTransform? = nil) {
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
public struct JasLayer: Equatable {
    public let name: String
    public let children: [Element]
    public let opacity: Double
    public let transform: JasTransform?

    public init(name: String = "Layer", children: [Element], opacity: Double = 1.0, transform: JasTransform? = nil) {
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
