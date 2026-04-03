import Foundation

// MARK: - Basic value types

/// A 2D point.
public struct JasPoint: Equatable, Hashable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

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

/// Stroke alignment relative to the path.
public enum StrokeAlignment: Equatable, Hashable {
    case center
    case inside
    case outside
}

/// Fill style for a closed path.
public struct JasFill: Equatable, Hashable {
    public let color: JasColor

    public init(color: JasColor) {
        self.color = color
    }
}

/// Stroke style for a path.
public struct JasStroke: Equatable, Hashable {
    public let color: JasColor
    public let width: Double
    public let alignment: StrokeAlignment

    public init(color: JasColor, width: Double = 1.0, alignment: StrokeAlignment = .center) {
        self.color = color
        self.width = width
        self.alignment = alignment
    }
}

// MARK: - Path components

/// An anchor point on a path, with optional control handles for curves.
public struct AnchorPoint: Equatable, Hashable {
    public let position: JasPoint
    public let handleIn: JasPoint?
    public let handleOut: JasPoint?

    public init(position: JasPoint, handleIn: JasPoint? = nil, handleOut: JasPoint? = nil) {
        self.position = position
        self.handleIn = handleIn
        self.handleOut = handleOut
    }
}

// MARK: - Elements

/// A document element. All elements are immutable value types.
public enum Element: Equatable {
    /// A vector path defined by anchor points.
    case path(JasPath)
    /// A rectangle defined by origin and size.
    case rect(JasRect)
    /// An ellipse defined by center and radii.
    case ellipse(JasEllipse)
    /// A group of elements treated as a single unit.
    case group(JasGroup)

    /// Return the bounding box as (topLeft, bottomRight).
    public var bounds: (JasPoint, JasPoint) {
        switch self {
        case .path(let p): return p.bounds
        case .rect(let r): return r.bounds
        case .ellipse(let e): return e.bounds
        case .group(let g): return g.bounds
        }
    }
}

/// A vector path defined by anchor points.
public struct JasPath: Equatable {
    public let anchors: [AnchorPoint]
    public let closed: Bool
    public let fill: JasFill?
    public let stroke: JasStroke?

    public init(anchors: [AnchorPoint], closed: Bool = false, fill: JasFill? = nil, stroke: JasStroke? = nil) {
        self.anchors = anchors
        self.closed = closed
        self.fill = fill
        self.stroke = stroke
    }

    public var bounds: (JasPoint, JasPoint) {
        guard !anchors.isEmpty else { return (JasPoint(x: 0, y: 0), JasPoint(x: 0, y: 0)) }
        let xs = anchors.map(\.position.x)
        let ys = anchors.map(\.position.y)
        return (JasPoint(x: xs.min()!, y: ys.min()!), JasPoint(x: xs.max()!, y: ys.max()!))
    }
}

/// A rectangle defined by origin and size.
public struct JasRect: Equatable {
    public let origin: JasPoint
    public let width: Double
    public let height: Double
    public let fill: JasFill?
    public let stroke: JasStroke?

    public init(origin: JasPoint, width: Double, height: Double, fill: JasFill? = nil, stroke: JasStroke? = nil) {
        self.origin = origin
        self.width = width
        self.height = height
        self.fill = fill
        self.stroke = stroke
    }

    public var bounds: (JasPoint, JasPoint) {
        (origin, JasPoint(x: origin.x + width, y: origin.y + height))
    }
}

/// An ellipse defined by center and radii.
public struct JasEllipse: Equatable {
    public let center: JasPoint
    public let rx: Double
    public let ry: Double
    public let fill: JasFill?
    public let stroke: JasStroke?

    public init(center: JasPoint, rx: Double, ry: Double, fill: JasFill? = nil, stroke: JasStroke? = nil) {
        self.center = center
        self.rx = rx
        self.ry = ry
        self.fill = fill
        self.stroke = stroke
    }

    public var bounds: (JasPoint, JasPoint) {
        (JasPoint(x: center.x - rx, y: center.y - ry),
         JasPoint(x: center.x + rx, y: center.y + ry))
    }
}

/// A group of elements treated as a single unit.
public struct JasGroup: Equatable {
    public let children: [Element]

    public init(children: [Element]) {
        self.children = children
    }

    public var bounds: (JasPoint, JasPoint) {
        guard !children.isEmpty else { return (JasPoint(x: 0, y: 0), JasPoint(x: 0, y: 0)) }
        let allBounds = children.map(\.bounds)
        let minX = allBounds.map(\.0.x).min()!
        let minY = allBounds.map(\.0.y).min()!
        let maxX = allBounds.map(\.1.x).max()!
        let maxY = allBounds.map(\.1.y).max()!
        return (JasPoint(x: minX, y: minY), JasPoint(x: maxX, y: maxY))
    }
}
