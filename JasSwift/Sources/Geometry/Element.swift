import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Measure the rendered width of `s` for the given font using AppKit when
/// available, falling back to the deterministic stub used by tests on
/// host platforms without a real font.
func renderedTextWidth(_ s: String, family: String, weight: String, style: String, size: Double) -> Double {
    if s.isEmpty { return 0 }
    #if canImport(AppKit)
    var traits: NSFontDescriptor.SymbolicTraits = []
    if weight == "bold" { traits.insert(.bold) }
    if style == "italic" { traits.insert(.italic) }
    let baseFont = NSFont(name: family, size: CGFloat(size)) ?? NSFont.systemFont(ofSize: CGFloat(size))
    let font: NSFont
    if !traits.isEmpty {
        let desc = baseFont.fontDescriptor.withSymbolicTraits(traits)
        font = NSFont(descriptor: desc, size: CGFloat(size)) ?? baseFont
    } else {
        font = baseFont
    }
    return Double(NSAttributedString(string: s, attributes: [.font: font]).size().width)
    #else
    return Double(s.count) * size * approxCharWidthFactor
    #endif
}

/// Line segments per Bezier curve when flattening paths.
public let elementFlattenSteps = 20

/// Average character width as a fraction of font size.
public let approxCharWidthFactor = 0.6

// MARK: - SVG presentation attributes

/// Color with support for RGB, HSB, and CMYK color spaces.
///
/// Components are normalized to [0, 1] except HSB hue which is [0, 360).
/// Each variant carries its own alpha in [0, 1].
public enum Color: Equatable, Hashable {
    /// Red, green, blue, alpha -- all in [0, 1].
    case rgb(r: Double, g: Double, b: Double, a: Double)
    /// Hue [0, 360), saturation [0, 1], brightness [0, 1], alpha [0, 1].
    case hsb(h: Double, s: Double, b: Double, a: Double)
    /// Cyan, magenta, yellow, key (black), alpha -- all in [0, 1].
    case cmyk(c: Double, m: Double, y: Double, k: Double, a: Double)

    /// Backward-compatible initializer that creates an RGB color.
    public init(r: Double, g: Double, b: Double, a: Double = 1.0) {
        self = .rgb(r: r, g: g, b: b, a: a)
    }

    public static let black = Color.rgb(r: 0, g: 0, b: 0, a: 1)
    public static let white = Color.rgb(r: 1, g: 1, b: 1, a: 1)

    /// Alpha component, regardless of color space.
    public var alpha: Double {
        switch self {
        case .rgb(_, _, _, let a),
             .hsb(_, _, _, let a),
             .cmyk(_, _, _, _, let a):
            return a
        }
    }

    /// Return a copy of this color with the alpha component replaced.
    public func withAlpha(_ a: Double) -> Color {
        switch self {
        case .rgb(let r, let g, let b, _): return .rgb(r: r, g: g, b: b, a: a)
        case .hsb(let h, let s, let b, _): return .hsb(h: h, s: s, b: b, a: a)
        case .cmyk(let c, let m, let y, let k, _): return .cmyk(c: c, m: m, y: y, k: k, a: a)
        }
    }

    /// Convert to (r, g, b, a) with all components in [0, 1].
    public func toRgba() -> (Double, Double, Double, Double) {
        switch self {
        case .rgb(let r, let g, let b, let a):
            return (r, g, b, a)
        case .hsb(let h, let s, let bri, let a):
            let (r, g, b) = hsbToRgbComponents(h: h, s: s, v: bri)
            return (r, g, b, a)
        case .cmyk(let c, let m, let y, let k, let a):
            let r = (1.0 - c) * (1.0 - k)
            let g = (1.0 - m) * (1.0 - k)
            let b = (1.0 - y) * (1.0 - k)
            return (r, g, b, a)
        }
    }

    /// Convert to (h, s, b, a) with h in [0, 360), s/b in [0, 1].
    public func toHsba() -> (Double, Double, Double, Double) {
        switch self {
        case .hsb(let h, let s, let b, let a):
            return (h, s, b, a)
        default:
            let (r, g, b, a) = toRgba()
            let (h, s, br) = rgbToHsbComponents(r: r, g: g, b: b)
            return (h, s, br, a)
        }
    }

    /// Convert to (c, m, y, k, a) with all components in [0, 1].
    public func toCmyka() -> (Double, Double, Double, Double, Double) {
        switch self {
        case .cmyk(let c, let m, let y, let k, let a):
            return (c, m, y, k, a)
        default:
            let (r, g, b, a) = toRgba()
            let maxC = max(r, max(g, b))
            let k = 1.0 - maxC
            if k >= 1.0 {
                return (0.0, 0.0, 0.0, 1.0, a)
            }
            let c = (1.0 - r - k) / (1.0 - k)
            let m = (1.0 - g - k) / (1.0 - k)
            let y = (1.0 - b - k) / (1.0 - k)
            return (c, m, y, k, a)
        }
    }

    /// Return the color as a 6-character lowercase hex string (no `#` prefix).
    /// The color is first converted to RGB; alpha is ignored.
    public func toHex() -> String {
        let (r, g, b, _) = toRgba()
        let ri = max(0, min(255, Int(round(r * 255))))
        let gi = max(0, min(255, Int(round(g * 255))))
        let bi = max(0, min(255, Int(round(b * 255))))
        return String(format: "%02x%02x%02x", ri, gi, bi)
    }

    /// Parse a 6-character hex string into an RGB color. An optional leading
    /// `#` is stripped. Returns `nil` if the string is not valid hex.
    public static func fromHex(_ s: String) -> Color? {
        var hex = s
        if hex.hasPrefix("#") { hex = String(hex.dropFirst()) }
        guard hex.count == 6 else { return nil }
        guard let val = UInt32(hex, radix: 16) else { return nil }
        let r = Double((val >> 16) & 0xFF) / 255.0
        let g = Double((val >> 8) & 0xFF) / 255.0
        let b = Double(val & 0xFF) / 255.0
        return Color(r: r, g: g, b: b)
    }
}

// MARK: - Color-space conversion helpers

func hsbToRgbComponents(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
    if s == 0 { return (v, v, v) }
    let h = ((h.truncatingRemainder(dividingBy: 360.0)) + 360.0)
        .truncatingRemainder(dividingBy: 360.0)
    let hi = Int(floor(h / 60.0)) % 6
    let f = h / 60.0 - Double(hi)
    let p = v * (1.0 - s)
    let q = v * (1.0 - s * f)
    let t = v * (1.0 - s * (1.0 - f))
    switch hi {
    case 0: return (v, t, p)
    case 1: return (q, v, p)
    case 2: return (p, v, t)
    case 3: return (p, q, v)
    case 4: return (t, p, v)
    default: return (v, p, q)
    }
}

func rgbToHsbComponents(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
    let maxC = max(r, max(g, b))
    let minC = min(r, min(g, b))
    let delta = maxC - minC

    let brightness = maxC
    let saturation = maxC == 0 ? 0.0 : delta / maxC

    var hue: Double
    if delta == 0 {
        hue = 0
    } else if maxC == r {
        hue = 60.0 * (((g - b) / delta).truncatingRemainder(dividingBy: 6.0))
    } else if maxC == g {
        hue = 60.0 * ((b - r) / delta + 2.0)
    } else {
        hue = 60.0 * ((r - g) / delta + 4.0)
    }
    hue = ((hue.truncatingRemainder(dividingBy: 360.0)) + 360.0)
        .truncatingRemainder(dividingBy: 360.0)

    return (hue, saturation, brightness)
}

/// SVG stroke-linecap.
/// Per-element visibility mode.
///
/// Conforms to `Comparable` so that `min(a, b)` picks the more
/// restrictive of two modes — the rule used to combine an element's
/// own visibility with the cap inherited from its parent Group or
/// Layer. The raw values establish the ordering
/// `invisible < outline < preview`.
///
/// - `preview`: the element is fully drawn.
/// - `outline`: drawn as a thin black outline (stroke 0, no fill).
///   Hit detection ignores fill and stroke width. Text is the
///   exception and still renders as `preview`.
/// - `invisible`: not drawn and not hittable.
///
/// This state is runtime-only and is not persisted to SVG.
public enum Visibility: Int, Equatable, Hashable, Comparable {
    case invisible = 0
    case outline = 1
    case preview = 2

    public static func < (lhs: Visibility, rhs: Visibility) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

/// Blend mode for compositing an element against its parent layer.
/// Values mirror the Opacity panel's mode dropdown. Default is `.normal`.
/// The `String` raw value is snake_case for cross-language JSON equivalence
/// (matches `opacity.yaml` mode ids and Rust's serde snake_case rename).
public enum BlendMode: String, Equatable, Hashable, CaseIterable {
    case normal
    case darken
    case multiply
    case colorBurn     = "color_burn"
    case lighten
    case screen
    case colorDodge    = "color_dodge"
    case overlay
    case softLight     = "soft_light"
    case hardLight     = "hard_light"
    case difference
    case exclusion
    case hue
    case saturation
    case color
    case luminosity
}

/// An opacity mask attached to an element. See OPACITY.md § Document model.
/// Storage-only in Phase 3a — renderer wiring and MAKE_MASK_BUTTON /
/// CLIP_CHECKBOX / INVERT_MASK_CHECKBOX / LINK_INDICATOR land in Phase 3b.
///
/// The mask ``subtree`` is held as a single-element array to satisfy
/// Swift's value-type recursion constraint (structs cannot directly
/// contain themselves). Callers should treat it as a single ``Element``:
/// append exactly one element and read via ``subtreeElement``. Wrap
/// multi-element masks in a ``Group`` or ``Layer``.
public struct Mask: Equatable {
    /// Singleton-array holding the mask's single root element.
    public let subtree: [Element]
    public let clip: Bool
    public let invert: Bool
    /// When true, the element renders as if no mask were attached.
    public let disabled: Bool
    /// When true, mask transforms follow the element's transform. When
    /// false, the mask uses ``unlinkTransform`` as its fixed baseline.
    public let linked: Bool
    /// Captured at unlink time; used as the mask's effective transform
    /// while ``linked`` is false. Cleared on relink.
    public let unlinkTransform: Transform?

    public init(
        subtreeElement: Element,
        clip: Bool = true,
        invert: Bool = false,
        disabled: Bool = false,
        linked: Bool = true,
        unlinkTransform: Transform? = nil
    ) {
        self.subtree = [subtreeElement]
        self.clip = clip
        self.invert = invert
        self.disabled = disabled
        self.linked = linked
        self.unlinkTransform = unlinkTransform
    }

    /// The mask's single root element. Traps if the subtree invariant is violated.
    public var subtreeElement: Element {
        precondition(subtree.count == 1, "Mask.subtree must hold exactly one element")
        return subtree[0]
    }
}

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

/// Stroke alignment relative to the path.
public enum StrokeAlign: Equatable, Hashable {
    case center
    case inside
    case outside
}

/// Arrowhead shape identifier.
public enum Arrowhead: String, CaseIterable, Equatable, Hashable {
    case none
    case simpleArrow = "simple_arrow"
    case openArrow = "open_arrow"
    case closedArrow = "closed_arrow"
    case stealthArrow = "stealth_arrow"
    case barbedArrow = "barbed_arrow"
    case halfArrowUpper = "half_arrow_upper"
    case halfArrowLower = "half_arrow_lower"
    case circle
    case openCircle = "open_circle"
    case square
    case openSquare = "open_square"
    case diamond
    case openDiamond = "open_diamond"
    case slash

    public init(fromString s: String) {
        self = Arrowhead(rawValue: s) ?? .none
    }

    public var name: String { rawValue }
}

/// Arrow alignment mode.
public enum ArrowAlign: Equatable, Hashable {
    case tipAtEnd
    case centerAtEnd
}

/// Gradient type. See transcripts/GRADIENT.md §Gradient types.
public enum GradientType: String, Codable, Equatable, Hashable {
    case linear
    case radial
    case freeform
}

/// Gradient interpolation / topology method. classic / smooth apply to
/// linear/radial; points / lines apply to freeform.
public enum GradientMethod: String, Codable, Equatable, Hashable {
    case classic
    case smooth
    case points
    case lines
}

/// Stroke sub-mode — how a gradient on a stroke maps onto the path.
public enum StrokeSubMode: String, Codable, Equatable, Hashable {
    case within
    case along
    case across
}

/// A single color stop inside a linear/radial gradient.
///
/// `color` is stored as a hex string ("#rrggbb") for wire-format
/// compatibility with the other apps. Codable handles this directly
/// since String is Codable.
public struct GradientStop: Codable, Equatable, Hashable {
    public let color: String
    /// Opacity 0–100 (percentage).
    public let opacity: Double
    /// Location 0–100 (percentage along the gradient strip).
    public let location: Double
    /// Midpoint between this stop and the next, stored as a
    /// percentage-between value (0–100, where 50 = halfway).
    /// Defaults to 50 when absent on parse.
    public let midpointToNext: Double

    public init(color: String, opacity: Double = 100, location: Double, midpointToNext: Double = 50) {
        self.color = color
        self.opacity = opacity
        self.location = location
        self.midpointToNext = midpointToNext
    }

    enum CodingKeys: String, CodingKey {
        case color
        case opacity
        case location
        case midpointToNext = "midpoint_to_next"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try c.decode(String.self, forKey: .color)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 100
        location = try c.decode(Double.self, forKey: .location)
        midpointToNext = try c.decodeIfPresent(Double.self, forKey: .midpointToNext) ?? 50
    }
}

/// A single node of a freeform gradient.
public struct GradientNode: Codable, Equatable, Hashable {
    public let x: Double
    public let y: Double
    public let color: String
    public let opacity: Double
    public let spread: Double

    public init(x: Double, y: Double, color: String, opacity: Double = 100, spread: Double = 25) {
        self.x = x; self.y = y; self.color = color
        self.opacity = opacity; self.spread = spread
    }
}

/// A gradient value usable as a fill or stroke. See GRADIENT.md §Document model.
public struct Gradient: Codable, Equatable, Hashable {
    public let type: GradientType
    public let angle: Double
    public let aspectRatio: Double
    public let method: GradientMethod
    public let dither: Bool
    public let strokeSubMode: StrokeSubMode
    public let stops: [GradientStop]
    public let nodes: [GradientNode]

    public init(type: GradientType = .linear, angle: Double = 0, aspectRatio: Double = 100,
                method: GradientMethod = .classic, dither: Bool = false,
                strokeSubMode: StrokeSubMode = .within,
                stops: [GradientStop] = [], nodes: [GradientNode] = []) {
        self.type = type; self.angle = angle; self.aspectRatio = aspectRatio
        self.method = method; self.dither = dither; self.strokeSubMode = strokeSubMode
        self.stops = stops; self.nodes = nodes
    }

    enum CodingKeys: String, CodingKey {
        case type
        case angle
        case aspectRatio = "aspect_ratio"
        case method
        case dither
        case strokeSubMode = "stroke_sub_mode"
        case stops
        case nodes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(GradientType.self, forKey: .type) ?? .linear
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        aspectRatio = try c.decodeIfPresent(Double.self, forKey: .aspectRatio) ?? 100
        method = try c.decodeIfPresent(GradientMethod.self, forKey: .method) ?? .classic
        dither = try c.decodeIfPresent(Bool.self, forKey: .dither) ?? false
        strokeSubMode = try c.decodeIfPresent(StrokeSubMode.self, forKey: .strokeSubMode) ?? .within
        stops = try c.decodeIfPresent([GradientStop].self, forKey: .stops) ?? []
        nodes = try c.decodeIfPresent([GradientNode].self, forKey: .nodes) ?? []
    }
}

/// SVG fill presentation attribute.
public struct Fill: Equatable, Hashable {
    public let color: Color
    public let opacity: Double
    public init(color: Color, opacity: Double = 1.0) { self.color = color; self.opacity = opacity }
}

/// SVG stroke presentation attributes.
public struct Stroke: Equatable, Hashable {
    public let color: Color
    public let width: Double
    public let linecap: LineCap
    public let linejoin: LineJoin
    public let miterLimit: Double
    public let align: StrokeAlign
    public let dashPattern: [Double]
    /// When true, per-segment dash and gap lengths flex so a dash is
    /// centered on every anchor and a full dash sits at each open path
    /// end. When false (default), the dash pattern lays out by exact
    /// length along the path. See DASH_ALIGN.md.
    public let dashAlignAnchors: Bool
    public let startArrow: Arrowhead
    public let endArrow: Arrowhead
    public let startArrowScale: Double
    public let endArrowScale: Double
    public let arrowAlign: ArrowAlign
    public let opacity: Double

    public init(color: Color, width: Double = 1.0, linecap: LineCap = .butt, linejoin: LineJoin = .miter,
                miterLimit: Double = 10.0, align: StrokeAlign = .center,
                dashPattern: [Double] = [], dashAlignAnchors: Bool = false,
                startArrow: Arrowhead = .none, endArrow: Arrowhead = .none,
                startArrowScale: Double = 100.0, endArrowScale: Double = 100.0,
                arrowAlign: ArrowAlign = .tipAtEnd, opacity: Double = 1.0) {
        self.color = color
        self.width = width
        self.linecap = linecap
        self.linejoin = linejoin
        self.miterLimit = miterLimit
        self.align = align
        self.dashPattern = dashPattern
        self.dashAlignAnchors = dashAlignAnchors
        self.startArrow = startArrow
        self.endArrow = endArrow
        self.startArrowScale = startArrowScale
        self.endArrowScale = endArrowScale
        self.arrowAlign = arrowAlign
        self.opacity = opacity
    }
}

/// A width control point for variable-width stroke profiles.
public struct StrokeWidthPoint: Equatable, Hashable {
    public let t: Double
    public let widthLeft: Double
    public let widthRight: Double

    public init(t: Double, widthLeft: Double, widthRight: Double) {
        self.t = t; self.widthLeft = widthLeft; self.widthRight = widthRight
    }
}

/// Convert a named profile preset to width control points.
public func profileToWidthPoints(profile: String, width: Double, flipped: Bool) -> [StrokeWidthPoint] {
    let hw = width / 2.0
    let pts: [StrokeWidthPoint]
    switch profile {
    case "taper_both":
        pts = [StrokeWidthPoint(t: 0, widthLeft: 0, widthRight: 0),
               StrokeWidthPoint(t: 0.5, widthLeft: hw, widthRight: hw),
               StrokeWidthPoint(t: 1, widthLeft: 0, widthRight: 0)]
    case "taper_start":
        pts = [StrokeWidthPoint(t: 0, widthLeft: 0, widthRight: 0),
               StrokeWidthPoint(t: 1, widthLeft: hw, widthRight: hw)]
    case "taper_end":
        pts = [StrokeWidthPoint(t: 0, widthLeft: hw, widthRight: hw),
               StrokeWidthPoint(t: 1, widthLeft: 0, widthRight: 0)]
    case "bulge":
        pts = [StrokeWidthPoint(t: 0, widthLeft: hw, widthRight: hw),
               StrokeWidthPoint(t: 0.5, widthLeft: hw * 1.5, widthRight: hw * 1.5),
               StrokeWidthPoint(t: 1, widthLeft: hw, widthRight: hw)]
    case "pinch":
        pts = [StrokeWidthPoint(t: 0, widthLeft: hw, widthRight: hw),
               StrokeWidthPoint(t: 0.5, widthLeft: hw * 0.5, widthRight: hw * 0.5),
               StrokeWidthPoint(t: 1, widthLeft: hw, widthRight: hw)]
    default:
        return []  // "uniform" or unknown
    }
    if flipped {
        return pts.reversed().map { StrokeWidthPoint(t: 1.0 - $0.t, widthLeft: $0.widthLeft, widthRight: $0.widthRight) }
    }
    return pts
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

    /// Identity transform — the no-op 2D affine.
    public static let identity = Transform()

    /// Return a new transform equal to `translate(dx, dy) * self`:
    /// a world-space translation of (dx, dy) pre-pended to this
    /// transform, preserving any existing rotation / scale. Used
    /// by the Align panel per ALIGN.md SVG attribute mapping.
    public func translated(_ dx: Double, _ dy: Double) -> Transform {
        Transform(a: a, b: b, c: c, d: d, e: e + dx, f: f + dy)
    }

    /// Apply this transform to a point.
    public func applyPoint(_ x: Double, _ y: Double) -> (Double, Double) {
        (a * x + c * y + e, b * x + d * y + f)
    }

    /// Return the inverse transform, or nil if the matrix is singular.
    public func inverse() -> Transform? {
        let det = a * d - b * c
        if abs(det) < 1e-12 { return nil }
        let invDet = 1.0 / det
        return Transform(
            a: d * invDet, b: -b * invDet,
            c: -c * invDet, d: a * invDet,
            e: (c * f - d * e) * invDet,
            f: (b * e - a * f) * invDet
        )
    }

    /// Shear matrix with horizontal shear factor `kx` (x ← x + kx·y)
    /// and vertical shear factor `ky` (y ← y + ky·x).
    public static func shear(_ kx: Double, _ ky: Double) -> Transform {
        Transform(a: 1, b: ky, c: kx, d: 1)
    }

    /// Return `self * other` — the matrix that applies `other` first,
    /// then `self`. Equivalent to (self ∘ other)(p) for any point p.
    public func multiply(_ other: Transform) -> Transform {
        Transform(
            a: a * other.a + c * other.b,
            b: b * other.a + d * other.b,
            c: a * other.c + c * other.d,
            d: b * other.c + d * other.d,
            e: a * other.e + c * other.f + e,
            f: b * other.e + d * other.f + f
        )
    }

    /// Conjugate this transform around `(rx, ry)` —
    /// `T(rx, ry) * self * T(-rx, -ry)`. The result, when applied to
    /// any point, behaves as if `self` were applied with `(rx, ry)`
    /// as the origin.
    public func aroundPoint(_ rx: Double, _ ry: Double) -> Transform {
        let pre = Transform.translate(-rx, -ry)
        let post = Transform.translate(rx, ry)
        return post.multiply(self).multiply(pre)
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

    /// All significant points (endpoints + control points) for bounds calculation.
    public var allPoints: [(Double, Double)] {
        switch self {
        case .moveTo(let x, let y), .lineTo(let x, let y), .smoothQuadTo(let x, let y):
            return [(x, y)]
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            return [(x1, y1), (x2, y2), (x, y)]
        case .smoothCurveTo(let x2, let y2, let x, let y):
            return [(x2, y2), (x, y)]
        case .quadTo(let x1, let y1, let x, let y):
            return [(x1, y1), (x, y)]
        case .arcTo(_, _, _, _, _, let x, let y):
            return [(x, y)]
        case .closePath:
            return []
        }
    }
}

// MARK: - SVG Elements

/// Bounding box as (x, y, width, height).
public typealias BBox = (x: Double, y: Double, width: Double, height: Double)

/// Expand bounding box (x, y, w, h) by half-stroke-width on each side.
private func inflateBounds(_ bbox: BBox, _ stroke: Stroke?) -> BBox {
    guard let stroke = stroke else { return bbox }
    let half = stroke.width / 2.0
    return (bbox.x - half, bbox.y - half, bbox.width + 2 * half, bbox.height + 2 * half)
}

/// Bounding box of a point list, no stroke inflation.
private func pointsBounds(_ points: [(Double, Double)]) -> BBox {
    guard !points.isEmpty else { return (0, 0, 0, 0) }
    let xs = points.map(\.0), ys = points.map(\.1)
    let minX = xs.min()!, minY = ys.min()!
    return (minX, minY, xs.max()! - minX, ys.max()! - minY)
}

/// Union the geometric bounds of a children list. Returns
/// `(0, 0, 0, 0)` for empty groups. Used by the recursive
/// `Element.geometricBounds` implementation.
private func childrenGeometricBounds(_ children: [Element]) -> BBox {
    guard !children.isEmpty else { return (0, 0, 0, 0) }
    let all = children.map(\.geometricBounds)
    let minX = all.map(\.x).min()!, minY = all.map(\.y).min()!
    let maxX = all.map { $0.x + $0.width }.max()!
    let maxY = all.map { $0.y + $0.height }.max()!
    return (minX, minY, maxX - minX, maxY - minY)
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
    /// A non-destructive element whose geometry is evaluated on
    /// demand from its source inputs. See `LiveVariant`.
    case live(LiveVariant)

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
        case .live(let v): return v.bounds
        }
    }

    /// Geometric bounding box — bbox of the path / shape geometry
    /// alone, ignoring stroke width and any fill bleed. Used by
    /// Align operations when "Use Preview Bounds" is off (the
    /// default) per ALIGN.md §Bounding box selection.
    public var geometricBounds: BBox {
        switch self {
        case .line(let v):
            let minX = min(v.x1, v.x2), minY = min(v.y1, v.y2)
            return (minX, minY, abs(v.x2 - v.x1), abs(v.y2 - v.y1))
        case .rect(let v): return (v.x, v.y, v.width, v.height)
        case .circle(let v): return (v.cx - v.r, v.cy - v.r, v.r * 2, v.r * 2)
        case .ellipse(let v): return (v.cx - v.rx, v.cy - v.ry, v.rx * 2, v.ry * 2)
        case .polyline(let v): return pointsBounds(v.points)
        case .polygon(let v): return pointsBounds(v.points)
        case .path(let v): return pathBounds(v.d)
        case .text, .textPath:
            // Text has no stroke inflation today; preview and
            // geometric bounds are equivalent.
            return self.bounds
        case .group(let v): return childrenGeometricBounds(v.children)
        case .layer(let v): return childrenGeometricBounds(v.children)
        case .live(let v): return v.bounds
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

    public func moveControlPoints(_ kind: SelectionKind, dx: Double, dy: Double) -> Element {
        // `.partial([])` — "element selected, no CPs highlighted" —
        // is a no-op: return unchanged. Without this guard, the
        // Rect/Circle/Ellipse branches would fall through to their
        // polygon-conversion path (since `isAll` is false for an
        // empty set) and silently change the primitive type without
        // any visible movement.
        if case .partial(let cps) = kind, cps.isEmpty {
            return self
        }
        switch self {
        case .line(let v):
            return .line(Line(
                x1: v.x1 + (kind.contains(0) ? dx : 0),
                y1: v.y1 + (kind.contains(0) ? dy : 0),
                x2: v.x2 + (kind.contains(1) ? dx : 0),
                y2: v.y2 + (kind.contains(1) ? dy : 0),
                stroke: v.stroke, opacity: v.opacity, transform: v.transform,
                locked: v.locked))
        case .rect(let v):
            if kind.isAll(total: 4) {
                return .rect(Rect(x: v.x + dx, y: v.y + dy, width: v.width, height: v.height,
                                     rx: v.rx, ry: v.ry, fill: v.fill, stroke: v.stroke,
                                     opacity: v.opacity, transform: v.transform,
                                     locked: v.locked))
            }
            var pts = [(v.x, v.y), (v.x + v.width, v.y),
                       (v.x + v.width, v.y + v.height), (v.x, v.y + v.height)]
            for i in 0..<4 where kind.contains(i) {
                pts[i] = (pts[i].0 + dx, pts[i].1 + dy)
            }
            return .polygon(Polygon(points: pts,
                                       fill: v.fill, stroke: v.stroke,
                                       opacity: v.opacity, transform: v.transform,
                                       locked: v.locked))
        case .circle(let v):
            if kind.isAll(total: 4) {
                return .circle(Circle(cx: v.cx + dx, cy: v.cy + dy, r: v.r,
                                         fill: v.fill, stroke: v.stroke,
                                         opacity: v.opacity, transform: v.transform,
                                         locked: v.locked))
            }
            var cps = [(v.cx, v.cy - v.r), (v.cx + v.r, v.cy),
                       (v.cx, v.cy + v.r), (v.cx - v.r, v.cy)]
            for i in 0..<4 where kind.contains(i) {
                cps[i] = (cps[i].0 + dx, cps[i].1 + dy)
            }
            let ncx = (cps[1].0 + cps[3].0) / 2
            let ncy = (cps[0].1 + cps[2].1) / 2
            let nr = max(abs(cps[1].0 - ncx), abs(cps[0].1 - ncy))
            return .circle(Circle(cx: ncx, cy: ncy, r: nr,
                                     fill: v.fill, stroke: v.stroke,
                                     opacity: v.opacity, transform: v.transform,
                                     locked: v.locked))
        case .ellipse(let v):
            if kind.isAll(total: 4) {
                return .ellipse(Ellipse(cx: v.cx + dx, cy: v.cy + dy, rx: v.rx, ry: v.ry,
                                           fill: v.fill, stroke: v.stroke,
                                           opacity: v.opacity, transform: v.transform,
                                           locked: v.locked))
            }
            var cps = [(v.cx, v.cy - v.ry), (v.cx + v.rx, v.cy),
                       (v.cx, v.cy + v.ry), (v.cx - v.rx, v.cy)]
            for i in 0..<4 where kind.contains(i) {
                cps[i] = (cps[i].0 + dx, cps[i].1 + dy)
            }
            let ncx = (cps[1].0 + cps[3].0) / 2
            let ncy = (cps[0].1 + cps[2].1) / 2
            return .ellipse(Ellipse(cx: ncx, cy: ncy,
                                       rx: abs(cps[1].0 - ncx), ry: abs(cps[0].1 - ncy),
                                       fill: v.fill, stroke: v.stroke,
                                       opacity: v.opacity, transform: v.transform,
                                       locked: v.locked))
        case .polygon(let v):
            let newPoints = v.points.enumerated().map { (i, pt) in
                kind.contains(i) ? (pt.0 + dx, pt.1 + dy) : pt
            }
            return .polygon(Polygon(points: newPoints,
                                       fill: v.fill, stroke: v.stroke,
                                       opacity: v.opacity, transform: v.transform,
                                       locked: v.locked))
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
                if kind.contains(anchorIdx) {
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
                                 widthPoints: v.widthPoints,
                                 opacity: v.opacity, transform: v.transform,
                                 locked: v.locked))
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
                if kind.contains(anchorIdx) {
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
                                          opacity: v.opacity, transform: v.transform,
                                          locked: v.locked))
        default:
            return self
        }
    }

    /// The element's fill, if it has one. Line, Group, and Layer return nil.
    public var fill: Fill? {
        switch self {
        case .line: return nil
        case .rect(let v): return v.fill
        case .circle(let v): return v.fill
        case .ellipse(let v): return v.fill
        case .polyline(let v): return v.fill
        case .polygon(let v): return v.fill
        case .path(let v): return v.fill
        case .text(let v): return v.fill
        case .textPath(let v): return v.fill
        case .group: return nil
        case .layer: return nil
        case .live(let v): return v.fill
        }
    }

    /// The element's stroke, if it has one. Group and Layer return nil.
    public var stroke: Stroke? {
        switch self {
        case .line(let v): return v.stroke
        case .rect(let v): return v.stroke
        case .circle(let v): return v.stroke
        case .ellipse(let v): return v.stroke
        case .polyline(let v): return v.stroke
        case .polygon(let v): return v.stroke
        case .path(let v): return v.stroke
        case .text(let v): return v.stroke
        case .textPath(let v): return v.stroke
        case .group: return nil
        case .layer: return nil
        case .live(let v): return v.stroke
        }
    }

    /// Optional gradient applied to the element's fill, if any.
    /// Phase 1b: lives directly on each Element variant rather than nested
    /// inside Fill. See GRADIENT.md §Document model.
    public var fillGradient: Gradient? {
        switch self {
        case .rect(let v): return v.fillGradient
        case .circle(let v): return v.fillGradient
        case .ellipse(let v): return v.fillGradient
        case .polyline(let v): return v.fillGradient
        case .polygon(let v): return v.fillGradient
        case .path(let v): return v.fillGradient
        default: return nil
        }
    }

    /// Optional gradient applied to the element's stroke, if any.
    public var strokeGradient: Gradient? {
        switch self {
        case .line(let v): return v.strokeGradient
        case .rect(let v): return v.strokeGradient
        case .circle(let v): return v.strokeGradient
        case .ellipse(let v): return v.strokeGradient
        case .polyline(let v): return v.strokeGradient
        case .polygon(let v): return v.strokeGradient
        case .path(let v): return v.strokeGradient
        default: return nil
        }
    }

    public var isLocked: Bool {
        switch self {
        case .line(let v): return v.locked
        case .rect(let v): return v.locked
        case .circle(let v): return v.locked
        case .ellipse(let v): return v.locked
        case .polyline(let v): return v.locked
        case .polygon(let v): return v.locked
        case .path(let v): return v.locked
        case .text(let v): return v.locked
        case .textPath(let v): return v.locked
        case .group(let v): return v.locked
        case .layer(let v): return v.locked
        case .live(let v): return v.locked
        }
    }

    public func withLocked(_ locked: Bool) -> Element {
        switch self {
        case .line(let v):
            return .line(Line(x1: v.x1, y1: v.y1, x2: v.x2, y2: v.y2,
                              stroke: v.stroke, widthPoints: v.widthPoints,
                              opacity: v.opacity, transform: v.transform,
                              locked: locked, visibility: v.visibility))
        case .rect(let v):
            return .rect(Rect(x: v.x, y: v.y, width: v.width, height: v.height,
                              rx: v.rx, ry: v.ry, fill: v.fill, stroke: v.stroke,
                              opacity: v.opacity, transform: v.transform, locked: locked,
                              visibility: v.visibility))
        case .circle(let v):
            return .circle(Circle(cx: v.cx, cy: v.cy, r: v.r,
                                  fill: v.fill, stroke: v.stroke,
                                  opacity: v.opacity, transform: v.transform, locked: locked,
                                  visibility: v.visibility))
        case .ellipse(let v):
            return .ellipse(Ellipse(cx: v.cx, cy: v.cy, rx: v.rx, ry: v.ry,
                                    fill: v.fill, stroke: v.stroke,
                                    opacity: v.opacity, transform: v.transform, locked: locked,
                                    visibility: v.visibility))
        case .polyline(let v):
            return .polyline(Polyline(points: v.points, fill: v.fill, stroke: v.stroke,
                                     opacity: v.opacity, transform: v.transform, locked: locked,
                                     visibility: v.visibility))
        case .polygon(let v):
            return .polygon(Polygon(points: v.points, fill: v.fill, stroke: v.stroke,
                                    opacity: v.opacity, transform: v.transform, locked: locked,
                                    visibility: v.visibility))
        case .path(let v):
            return .path(Path(d: v.d, fill: v.fill, stroke: v.stroke,
                              widthPoints: v.widthPoints,
                              opacity: v.opacity, transform: v.transform, locked: locked,
                              visibility: v.visibility))
        case .text(let v):
            return .text(Text(x: v.x, y: v.y, content: v.content,
                              fontFamily: v.fontFamily, fontSize: v.fontSize,
                              fontWeight: v.fontWeight, fontStyle: v.fontStyle,
                              textDecoration: v.textDecoration,
                              width: v.width, height: v.height,
                              fill: v.fill, stroke: v.stroke,
                              opacity: v.opacity, transform: v.transform, locked: locked,
                              visibility: v.visibility))
        case .textPath(let v):
            return .textPath(TextPath(d: v.d, content: v.content,
                                      startOffset: v.startOffset,
                                      fontFamily: v.fontFamily, fontSize: v.fontSize,
                                      fontWeight: v.fontWeight, fontStyle: v.fontStyle,
                                      textDecoration: v.textDecoration,
                                      fill: v.fill, stroke: v.stroke,
                                      opacity: v.opacity, transform: v.transform, locked: locked,
                                      visibility: v.visibility))
        case .group(let v):
            return .group(Group(children: v.children, opacity: v.opacity,
                                transform: v.transform, locked: locked,
                                visibility: v.visibility))
        case .layer(let v):
            return .layer(Layer(name: v.name, children: v.children, opacity: v.opacity,
                                transform: v.transform, locked: locked,
                                visibility: v.visibility))
        case .live(let v):
            return .live(v.withLocked(locked))
        }
    }

    /// Visibility of this element (does not include any cap inherited
    /// from a parent Group/Layer; use ``Document.effectiveVisibility``
    /// for that).
    public var visibility: Visibility {
        switch self {
        case .line(let v): return v.visibility
        case .rect(let v): return v.visibility
        case .circle(let v): return v.visibility
        case .ellipse(let v): return v.visibility
        case .polyline(let v): return v.visibility
        case .polygon(let v): return v.visibility
        case .path(let v): return v.visibility
        case .text(let v): return v.visibility
        case .textPath(let v): return v.visibility
        case .group(let v): return v.visibility
        case .layer(let v): return v.visibility
        case .live(let v): return v.visibility
        }
    }

    /// Blend mode of this element. Default `.normal` for every element kind;
    /// applied via `CGContext.setBlendMode` at render time.
    public var blendMode: BlendMode {
        switch self {
        case .line(let v): return v.blendMode
        case .rect(let v): return v.blendMode
        case .circle(let v): return v.blendMode
        case .ellipse(let v): return v.blendMode
        case .polyline(let v): return v.blendMode
        case .polygon(let v): return v.blendMode
        case .path(let v): return v.blendMode
        case .text(let v): return v.blendMode
        case .textPath(let v): return v.blendMode
        case .group(let v): return v.blendMode
        case .layer(let v): return v.blendMode
        case .live(let v): return v.blendMode
        }
    }

    /// Optional opacity mask attached to this element. Phase 3a storage-only.
    public var mask: Mask? {
        switch self {
        case .line(let v): return v.mask
        case .rect(let v): return v.mask
        case .circle(let v): return v.mask
        case .ellipse(let v): return v.mask
        case .polyline(let v): return v.mask
        case .polygon(let v): return v.mask
        case .path(let v): return v.mask
        case .text(let v): return v.mask
        case .textPath(let v): return v.mask
        case .group(let v): return v.mask
        case .layer(let v): return v.mask
        case .live(let v): return v.mask
        }
    }

    /// The element's transform, if any.
    public var transform: Transform? {
        switch self {
        case .line(let v): return v.transform
        case .rect(let v): return v.transform
        case .circle(let v): return v.transform
        case .ellipse(let v): return v.transform
        case .polyline(let v): return v.transform
        case .polygon(let v): return v.transform
        case .path(let v): return v.transform
        case .text(let v): return v.transform
        case .textPath(let v): return v.transform
        case .group(let v): return v.transform
        case .layer(let v): return v.transform
        case .live(let v): return v.transform
        }
    }

    /// Return a copy of this element with its `visibility` replaced.
    public func withVisibility(_ visibility: Visibility) -> Element {
        switch self {
        case .line(let v):
            return .line(Line(x1: v.x1, y1: v.y1, x2: v.x2, y2: v.y2,
                              stroke: v.stroke, widthPoints: v.widthPoints,
                              opacity: v.opacity, transform: v.transform,
                              locked: v.locked, visibility: visibility))
        case .rect(let v):
            return .rect(Rect(x: v.x, y: v.y, width: v.width, height: v.height,
                              rx: v.rx, ry: v.ry, fill: v.fill, stroke: v.stroke,
                              opacity: v.opacity, transform: v.transform, locked: v.locked,
                              visibility: visibility))
        case .circle(let v):
            return .circle(Circle(cx: v.cx, cy: v.cy, r: v.r,
                                  fill: v.fill, stroke: v.stroke,
                                  opacity: v.opacity, transform: v.transform, locked: v.locked,
                                  visibility: visibility))
        case .ellipse(let v):
            return .ellipse(Ellipse(cx: v.cx, cy: v.cy, rx: v.rx, ry: v.ry,
                                    fill: v.fill, stroke: v.stroke,
                                    opacity: v.opacity, transform: v.transform, locked: v.locked,
                                    visibility: visibility))
        case .polyline(let v):
            return .polyline(Polyline(points: v.points, fill: v.fill, stroke: v.stroke,
                                     opacity: v.opacity, transform: v.transform, locked: v.locked,
                                     visibility: visibility))
        case .polygon(let v):
            return .polygon(Polygon(points: v.points, fill: v.fill, stroke: v.stroke,
                                    opacity: v.opacity, transform: v.transform, locked: v.locked,
                                    visibility: visibility))
        case .path(let v):
            return .path(Path(d: v.d, fill: v.fill, stroke: v.stroke,
                              widthPoints: v.widthPoints,
                              opacity: v.opacity, transform: v.transform, locked: v.locked,
                              visibility: visibility))
        case .text(let v):
            return .text(Text(x: v.x, y: v.y, content: v.content,
                              fontFamily: v.fontFamily, fontSize: v.fontSize,
                              fontWeight: v.fontWeight, fontStyle: v.fontStyle,
                              textDecoration: v.textDecoration,
                              width: v.width, height: v.height,
                              fill: v.fill, stroke: v.stroke,
                              opacity: v.opacity, transform: v.transform, locked: v.locked,
                              visibility: visibility))
        case .textPath(let v):
            return .textPath(TextPath(d: v.d, content: v.content,
                                      startOffset: v.startOffset,
                                      fontFamily: v.fontFamily, fontSize: v.fontSize,
                                      fontWeight: v.fontWeight, fontStyle: v.fontStyle,
                                      textDecoration: v.textDecoration,
                                      fill: v.fill, stroke: v.stroke,
                                      opacity: v.opacity, transform: v.transform, locked: v.locked,
                                      visibility: visibility))
        case .group(let v):
            return .group(Group(children: v.children, opacity: v.opacity,
                                transform: v.transform, locked: v.locked,
                                visibility: visibility))
        case .layer(let v):
            return .layer(Layer(name: v.name, children: v.children, opacity: v.opacity,
                                transform: v.transform, locked: v.locked,
                                visibility: visibility))
        case .live(let v):
            return .live(v.withVisibility(visibility))
        }
    }

    /// Return a copy of this element with `(dx, dy)` pre-pended to
    /// its transforms world-space translation. See
    /// `Transform.translated` for the math. Used by the Align panel
    /// to move elements without disturbing existing rotation / scale.
    public func withTransformTranslated(dx: Double, dy: Double) -> Element {
        let t = (transform ?? .identity).translated(dx, dy)
        return withTransformSet(t)
    }

    /// Return a copy of this element with `matrix` pre-multiplied
    /// onto its existing transform. Used by the transform-tool
    /// family (Scale / Rotate / Shear) to compose a per-frame
    /// matrix on top of any existing transform without disturbing
    /// the element's geometry. See SCALE_TOOL.md §Apply behavior.
    public func withTransformPremultiplied(_ matrix: Transform) -> Element {
        let t = matrix.multiply(transform ?? .identity)
        return withTransformSet(t)
    }

    /// Internal: replace the element's transform with `t`,
    /// preserving every other field. Shared by
    /// `withTransformTranslated` and `withTransformPremultiplied`.
    private func withTransformSet(_ t: Transform) -> Element {
        switch self {
        case .line(let v):
            return .line(Line(x1: v.x1, y1: v.y1, x2: v.x2, y2: v.y2,
                              stroke: v.stroke, widthPoints: v.widthPoints,
                              opacity: v.opacity, transform: t,
                              locked: v.locked, visibility: v.visibility))
        case .rect(let v):
            return .rect(Rect(x: v.x, y: v.y, width: v.width, height: v.height,
                              rx: v.rx, ry: v.ry, fill: v.fill, stroke: v.stroke,
                              opacity: v.opacity, transform: t, locked: v.locked,
                              visibility: v.visibility))
        case .circle(let v):
            return .circle(Circle(cx: v.cx, cy: v.cy, r: v.r,
                                  fill: v.fill, stroke: v.stroke,
                                  opacity: v.opacity, transform: t, locked: v.locked,
                                  visibility: v.visibility))
        case .ellipse(let v):
            return .ellipse(Ellipse(cx: v.cx, cy: v.cy, rx: v.rx, ry: v.ry,
                                    fill: v.fill, stroke: v.stroke,
                                    opacity: v.opacity, transform: t, locked: v.locked,
                                    visibility: v.visibility))
        case .polyline(let v):
            return .polyline(Polyline(points: v.points, fill: v.fill, stroke: v.stroke,
                                     opacity: v.opacity, transform: t, locked: v.locked,
                                     visibility: v.visibility))
        case .polygon(let v):
            return .polygon(Polygon(points: v.points, fill: v.fill, stroke: v.stroke,
                                    opacity: v.opacity, transform: t, locked: v.locked,
                                    visibility: v.visibility))
        case .path(let v):
            return .path(Path(d: v.d, fill: v.fill, stroke: v.stroke,
                              widthPoints: v.widthPoints,
                              opacity: v.opacity, transform: t, locked: v.locked,
                              visibility: v.visibility))
        case .text(let v):
            return .text(Text(x: v.x, y: v.y, content: v.content,
                              fontFamily: v.fontFamily, fontSize: v.fontSize,
                              fontWeight: v.fontWeight, fontStyle: v.fontStyle,
                              textDecoration: v.textDecoration,
                              width: v.width, height: v.height,
                              fill: v.fill, stroke: v.stroke,
                              opacity: v.opacity, transform: t, locked: v.locked,
                              visibility: v.visibility))
        case .textPath(let v):
            return .textPath(TextPath(d: v.d, content: v.content,
                                      startOffset: v.startOffset,
                                      fontFamily: v.fontFamily, fontSize: v.fontSize,
                                      fontWeight: v.fontWeight, fontStyle: v.fontStyle,
                                      textDecoration: v.textDecoration,
                                      fill: v.fill, stroke: v.stroke,
                                      opacity: v.opacity, transform: t, locked: v.locked,
                                      visibility: v.visibility))
        case .group(let v):
            return .group(Group(children: v.children, opacity: v.opacity,
                                transform: t, locked: v.locked,
                                visibility: v.visibility))
        case .layer(let v):
            return .layer(Layer(name: v.name, children: v.children, opacity: v.opacity,
                                transform: t, locked: v.locked,
                                visibility: v.visibility))
        case .live(let v):
            return .live(v.withTransform(t))
        }
    }
}

// MARK: - Fill / Stroke replacement helpers

/// Return a copy of `element` with the fill replaced. Line has no fill
/// (returned unchanged). Group and Layer have no fill (returned unchanged).
/// Return a copy of the element with its `fillGradient` replaced.
/// Elements that do not support a fill gradient are returned unchanged.
public func withFillGradient(_ element: Element, fillGradient: Gradient?) -> Element {
    switch element {
    case .rect(let v):
        return .rect(Rect(x: v.x, y: v.y, width: v.width, height: v.height,
                          rx: v.rx, ry: v.ry, fill: v.fill, stroke: v.stroke,
                          opacity: v.opacity, transform: v.transform, locked: v.locked,
                          visibility: v.visibility, blendMode: v.blendMode, mask: v.mask,
                          fillGradient: fillGradient, strokeGradient: v.strokeGradient))
    case .circle(let v):
        return .circle(Circle(cx: v.cx, cy: v.cy, r: v.r,
                              fill: v.fill, stroke: v.stroke,
                              opacity: v.opacity, transform: v.transform, locked: v.locked,
                              visibility: v.visibility, blendMode: v.blendMode, mask: v.mask,
                              fillGradient: fillGradient, strokeGradient: v.strokeGradient))
    case .ellipse(let v):
        return .ellipse(Ellipse(cx: v.cx, cy: v.cy, rx: v.rx, ry: v.ry,
                                fill: v.fill, stroke: v.stroke,
                                opacity: v.opacity, transform: v.transform, locked: v.locked,
                                visibility: v.visibility, blendMode: v.blendMode, mask: v.mask,
                                fillGradient: fillGradient, strokeGradient: v.strokeGradient))
    case .polyline(let v):
        return .polyline(Polyline(points: v.points, fill: v.fill, stroke: v.stroke,
                                  opacity: v.opacity, transform: v.transform, locked: v.locked,
                                  visibility: v.visibility, blendMode: v.blendMode, mask: v.mask,
                                  fillGradient: fillGradient, strokeGradient: v.strokeGradient))
    case .polygon(let v):
        return .polygon(Polygon(points: v.points, fill: v.fill, stroke: v.stroke,
                                opacity: v.opacity, transform: v.transform, locked: v.locked,
                                visibility: v.visibility, blendMode: v.blendMode, mask: v.mask,
                                fillGradient: fillGradient, strokeGradient: v.strokeGradient))
    case .path(let v):
        return .path(Path(d: v.d, fill: v.fill, stroke: v.stroke,
                          widthPoints: v.widthPoints,
                          opacity: v.opacity, transform: v.transform, locked: v.locked,
                          visibility: v.visibility, blendMode: v.blendMode, mask: v.mask,
                          fillGradient: fillGradient, strokeGradient: v.strokeGradient))
    default:
        return element
    }
}

/// Return a copy of the element with its `strokeGradient` replaced.
/// Elements that do not support a stroke gradient are returned unchanged.
public func withStrokeGradient(_ element: Element, strokeGradient: Gradient?) -> Element {
    switch element {
    case .line(let v):
        return .line(Line(x1: v.x1, y1: v.y1, x2: v.x2, y2: v.y2,
                          stroke: v.stroke, widthPoints: v.widthPoints,
                          opacity: v.opacity, transform: v.transform, locked: v.locked,
                          visibility: v.visibility, blendMode: v.blendMode, mask: v.mask,
                          strokeGradient: strokeGradient))
    case .rect(let v):
        return .rect(Rect(x: v.x, y: v.y, width: v.width, height: v.height,
                          rx: v.rx, ry: v.ry, fill: v.fill, stroke: v.stroke,
                          opacity: v.opacity, transform: v.transform, locked: v.locked,
                          visibility: v.visibility, blendMode: v.blendMode, mask: v.mask,
                          fillGradient: v.fillGradient, strokeGradient: strokeGradient))
    case .circle(let v):
        return .circle(Circle(cx: v.cx, cy: v.cy, r: v.r,
                              fill: v.fill, stroke: v.stroke,
                              opacity: v.opacity, transform: v.transform, locked: v.locked,
                              visibility: v.visibility, blendMode: v.blendMode, mask: v.mask,
                              fillGradient: v.fillGradient, strokeGradient: strokeGradient))
    case .ellipse(let v):
        return .ellipse(Ellipse(cx: v.cx, cy: v.cy, rx: v.rx, ry: v.ry,
                                fill: v.fill, stroke: v.stroke,
                                opacity: v.opacity, transform: v.transform, locked: v.locked,
                                visibility: v.visibility, blendMode: v.blendMode, mask: v.mask,
                                fillGradient: v.fillGradient, strokeGradient: strokeGradient))
    case .polyline(let v):
        return .polyline(Polyline(points: v.points, fill: v.fill, stroke: v.stroke,
                                  opacity: v.opacity, transform: v.transform, locked: v.locked,
                                  visibility: v.visibility, blendMode: v.blendMode, mask: v.mask,
                                  fillGradient: v.fillGradient, strokeGradient: strokeGradient))
    case .polygon(let v):
        return .polygon(Polygon(points: v.points, fill: v.fill, stroke: v.stroke,
                                opacity: v.opacity, transform: v.transform, locked: v.locked,
                                visibility: v.visibility, blendMode: v.blendMode, mask: v.mask,
                                fillGradient: v.fillGradient, strokeGradient: strokeGradient))
    case .path(let v):
        return .path(Path(d: v.d, fill: v.fill, stroke: v.stroke,
                          widthPoints: v.widthPoints,
                          opacity: v.opacity, transform: v.transform, locked: v.locked,
                          visibility: v.visibility, blendMode: v.blendMode, mask: v.mask,
                          fillGradient: v.fillGradient, strokeGradient: strokeGradient))
    default:
        return element
    }
}

public func withFill(_ element: Element, fill: Fill?) -> Element {
    switch element {
    case .line:
        return element
    case .rect(let v):
        return .rect(Rect(x: v.x, y: v.y, width: v.width, height: v.height,
                          rx: v.rx, ry: v.ry, fill: fill, stroke: v.stroke,
                          opacity: v.opacity, transform: v.transform, locked: v.locked,
                          visibility: v.visibility))
    case .circle(let v):
        return .circle(Circle(cx: v.cx, cy: v.cy, r: v.r,
                              fill: fill, stroke: v.stroke,
                              opacity: v.opacity, transform: v.transform, locked: v.locked,
                              visibility: v.visibility))
    case .ellipse(let v):
        return .ellipse(Ellipse(cx: v.cx, cy: v.cy, rx: v.rx, ry: v.ry,
                                fill: fill, stroke: v.stroke,
                                opacity: v.opacity, transform: v.transform, locked: v.locked,
                                visibility: v.visibility))
    case .polyline(let v):
        return .polyline(Polyline(points: v.points, fill: fill, stroke: v.stroke,
                                  opacity: v.opacity, transform: v.transform, locked: v.locked,
                                  visibility: v.visibility))
    case .polygon(let v):
        return .polygon(Polygon(points: v.points, fill: fill, stroke: v.stroke,
                                opacity: v.opacity, transform: v.transform, locked: v.locked,
                                visibility: v.visibility))
    case .path(let v):
        return .path(Path(d: v.d, fill: fill, stroke: v.stroke,
                          widthPoints: v.widthPoints,
                          opacity: v.opacity, transform: v.transform, locked: v.locked,
                          visibility: v.visibility))
    case .text(let v):
        return .text(Text(x: v.x, y: v.y, content: v.content,
                          fontFamily: v.fontFamily, fontSize: v.fontSize,
                          fontWeight: v.fontWeight, fontStyle: v.fontStyle,
                          textDecoration: v.textDecoration,
                          width: v.width, height: v.height,
                          fill: fill, stroke: v.stroke,
                          opacity: v.opacity, transform: v.transform, locked: v.locked,
                          visibility: v.visibility))
    case .textPath(let v):
        return .textPath(TextPath(d: v.d, content: v.content,
                                  startOffset: v.startOffset,
                                  fontFamily: v.fontFamily, fontSize: v.fontSize,
                                  fontWeight: v.fontWeight, fontStyle: v.fontStyle,
                                  textDecoration: v.textDecoration,
                                  fill: fill, stroke: v.stroke,
                                  opacity: v.opacity, transform: v.transform, locked: v.locked,
                                  visibility: v.visibility))
    case .group, .layer:
        return element
    case .live(let v):
        return .live(v.withFill(fill))
    }
}

/// Return a copy of `element` with the stroke replaced. Group and Layer
/// have no stroke (returned unchanged).
public func withStroke(_ element: Element, stroke: Stroke?) -> Element {
    switch element {
    case .line(let v):
        return .line(Line(x1: v.x1, y1: v.y1, x2: v.x2, y2: v.y2,
                          stroke: stroke, widthPoints: v.widthPoints,
                          opacity: v.opacity, transform: v.transform,
                          locked: v.locked, visibility: v.visibility))
    case .rect(let v):
        return .rect(Rect(x: v.x, y: v.y, width: v.width, height: v.height,
                          rx: v.rx, ry: v.ry, fill: v.fill, stroke: stroke,
                          opacity: v.opacity, transform: v.transform, locked: v.locked,
                          visibility: v.visibility))
    case .circle(let v):
        return .circle(Circle(cx: v.cx, cy: v.cy, r: v.r,
                              fill: v.fill, stroke: stroke,
                              opacity: v.opacity, transform: v.transform, locked: v.locked,
                              visibility: v.visibility))
    case .ellipse(let v):
        return .ellipse(Ellipse(cx: v.cx, cy: v.cy, rx: v.rx, ry: v.ry,
                                fill: v.fill, stroke: stroke,
                                opacity: v.opacity, transform: v.transform, locked: v.locked,
                                visibility: v.visibility))
    case .polyline(let v):
        return .polyline(Polyline(points: v.points, fill: v.fill, stroke: stroke,
                                  opacity: v.opacity, transform: v.transform, locked: v.locked,
                                  visibility: v.visibility))
    case .polygon(let v):
        return .polygon(Polygon(points: v.points, fill: v.fill, stroke: stroke,
                                opacity: v.opacity, transform: v.transform, locked: v.locked,
                                visibility: v.visibility))
    case .path(let v):
        return .path(Path(d: v.d, fill: v.fill, stroke: stroke,
                          widthPoints: v.widthPoints,
                          opacity: v.opacity, transform: v.transform, locked: v.locked,
                          visibility: v.visibility))
    case .text(let v):
        return .text(Text(x: v.x, y: v.y, content: v.content,
                          fontFamily: v.fontFamily, fontSize: v.fontSize,
                          fontWeight: v.fontWeight, fontStyle: v.fontStyle,
                          textDecoration: v.textDecoration,
                          width: v.width, height: v.height,
                          fill: v.fill, stroke: stroke,
                          opacity: v.opacity, transform: v.transform, locked: v.locked,
                          visibility: v.visibility))
    case .textPath(let v):
        return .textPath(TextPath(d: v.d, content: v.content,
                                  startOffset: v.startOffset,
                                  fontFamily: v.fontFamily, fontSize: v.fontSize,
                                  fontWeight: v.fontWeight, fontStyle: v.fontStyle,
                                  textDecoration: v.textDecoration,
                                  fill: v.fill, stroke: stroke,
                                  opacity: v.opacity, transform: v.transform, locked: v.locked,
                                  visibility: v.visibility))
    case .group, .layer:
        return element
    case .live(let v):
        return .live(v.withStroke(stroke))
    }
}

/// Return a copy of the element with strokeBrush replaced.
/// Path-only; other elements are returned unchanged. See
/// BRUSHES.md §Stroke styling interaction.
public func withStrokeBrush(_ element: Element, strokeBrush: String?) -> Element {
    switch element {
    case .path(let v):
        return .path(Path(d: v.d, fill: v.fill, stroke: v.stroke,
                          widthPoints: v.widthPoints,
                          opacity: v.opacity, transform: v.transform,
                          locked: v.locked, visibility: v.visibility,
                          blendMode: v.blendMode, mask: v.mask,
                          fillGradient: v.fillGradient,
                          strokeGradient: v.strokeGradient,
                          strokeBrush: strokeBrush,
                          strokeBrushOverrides: v.strokeBrushOverrides))
    default:
        return element
    }
}

/// Return a copy of the element with strokeBrushOverrides replaced.
/// Path-only.
public func withStrokeBrushOverrides(_ element: Element, overrides: String?) -> Element {
    switch element {
    case .path(let v):
        return .path(Path(d: v.d, fill: v.fill, stroke: v.stroke,
                          widthPoints: v.widthPoints,
                          opacity: v.opacity, transform: v.transform,
                          locked: v.locked, visibility: v.visibility,
                          blendMode: v.blendMode, mask: v.mask,
                          fillGradient: v.fillGradient,
                          strokeGradient: v.strokeGradient,
                          strokeBrush: v.strokeBrush,
                          strokeBrushOverrides: overrides))
    default:
        return element
    }
}

// MARK: - Selection-level mask helpers (OPACITY.md § States)

/// Return the ``Mask`` on the first selected element, if any.
/// Drives the "first-element-wins" toggles in the Opacity panel
/// (disable, unlink, and the MAKE_MASK_BUTTON label flip per
/// OPACITY.md § States).
public func firstMask(_ document: Document) -> Mask? {
    guard let first = document.selection.first else { return nil }
    return document.getElement(first.path).mask
}

/// True when **every** selected element has an opacity mask attached.
/// Mixed selections (some masked, some not) count as "no mask" per
/// OPACITY.md § States.
public func selectionHasMask(_ document: Document) -> Bool {
    if document.selection.isEmpty { return false }
    return document.selection.allSatisfy { document.getElement($0.path).mask != nil }
}

/// Return a copy of `element` with its opacity mask replaced. Passing
/// `nil` removes the mask; passing `Some(mask)` sets / replaces it.
/// All other fields (including `blendMode`, `isolatedBlending`,
/// `knockoutGroup`, fills, strokes, and children) are preserved.
public func withMask(_ element: Element, mask: Mask?) -> Element {
    switch element {
    case .line(let v):
        return .line(Line(x1: v.x1, y1: v.y1, x2: v.x2, y2: v.y2,
                          stroke: v.stroke, widthPoints: v.widthPoints,
                          opacity: v.opacity, transform: v.transform,
                          locked: v.locked, visibility: v.visibility,
                          blendMode: v.blendMode, mask: mask))
    case .rect(let v):
        return .rect(Rect(x: v.x, y: v.y, width: v.width, height: v.height,
                          rx: v.rx, ry: v.ry, fill: v.fill, stroke: v.stroke,
                          opacity: v.opacity, transform: v.transform, locked: v.locked,
                          visibility: v.visibility, blendMode: v.blendMode, mask: mask))
    case .circle(let v):
        return .circle(Circle(cx: v.cx, cy: v.cy, r: v.r,
                              fill: v.fill, stroke: v.stroke,
                              opacity: v.opacity, transform: v.transform, locked: v.locked,
                              visibility: v.visibility, blendMode: v.blendMode, mask: mask))
    case .ellipse(let v):
        return .ellipse(Ellipse(cx: v.cx, cy: v.cy, rx: v.rx, ry: v.ry,
                                fill: v.fill, stroke: v.stroke,
                                opacity: v.opacity, transform: v.transform, locked: v.locked,
                                visibility: v.visibility, blendMode: v.blendMode, mask: mask))
    case .polyline(let v):
        return .polyline(Polyline(points: v.points, fill: v.fill, stroke: v.stroke,
                                  opacity: v.opacity, transform: v.transform, locked: v.locked,
                                  visibility: v.visibility, blendMode: v.blendMode, mask: mask))
    case .polygon(let v):
        return .polygon(Polygon(points: v.points, fill: v.fill, stroke: v.stroke,
                                opacity: v.opacity, transform: v.transform, locked: v.locked,
                                visibility: v.visibility, blendMode: v.blendMode, mask: mask))
    case .path(let v):
        return .path(Path(d: v.d, fill: v.fill, stroke: v.stroke,
                          widthPoints: v.widthPoints,
                          opacity: v.opacity, transform: v.transform, locked: v.locked,
                          visibility: v.visibility, blendMode: v.blendMode, mask: mask))
    case .text(let v):
        return .text(Text(x: v.x, y: v.y, content: v.content,
                          fontFamily: v.fontFamily, fontSize: v.fontSize,
                          fontWeight: v.fontWeight, fontStyle: v.fontStyle,
                          textDecoration: v.textDecoration,
                          width: v.width, height: v.height,
                          fill: v.fill, stroke: v.stroke,
                          opacity: v.opacity, transform: v.transform, locked: v.locked,
                          visibility: v.visibility, blendMode: v.blendMode, mask: mask))
    case .textPath(let v):
        return .textPath(TextPath(d: v.d, content: v.content,
                                  startOffset: v.startOffset,
                                  fontFamily: v.fontFamily, fontSize: v.fontSize,
                                  fontWeight: v.fontWeight, fontStyle: v.fontStyle,
                                  textDecoration: v.textDecoration,
                                  fill: v.fill, stroke: v.stroke,
                                  opacity: v.opacity, transform: v.transform, locked: v.locked,
                                  visibility: v.visibility, blendMode: v.blendMode, mask: mask))
    case .group(let v):
        return .group(Group(children: v.children,
                            opacity: v.opacity, transform: v.transform,
                            locked: v.locked, visibility: v.visibility,
                            blendMode: v.blendMode,
                            isolatedBlending: v.isolatedBlending,
                            knockoutGroup: v.knockoutGroup,
                            mask: mask))
    case .layer(let v):
        return .layer(Layer(name: v.name, children: v.children,
                            opacity: v.opacity, transform: v.transform,
                            locked: v.locked, visibility: v.visibility,
                            blendMode: v.blendMode,
                            isolatedBlending: v.isolatedBlending,
                            knockoutGroup: v.knockoutGroup,
                            mask: mask))
    case .live(let v):
        return .live(v.withMask(mask))
    }
}

/// Return a copy of `element` with width points replaced.
/// Only Line and Path support width points; others returned unchanged.
public func withWidthPoints(_ element: Element, widthPoints: [StrokeWidthPoint]) -> Element {
    switch element {
    case .line(let v):
        return .line(Line(x1: v.x1, y1: v.y1, x2: v.x2, y2: v.y2,
                          stroke: v.stroke, widthPoints: widthPoints,
                          opacity: v.opacity, transform: v.transform,
                          locked: v.locked, visibility: v.visibility))
    case .path(let v):
        return .path(Path(d: v.d, fill: v.fill, stroke: v.stroke,
                          widthPoints: widthPoints,
                          opacity: v.opacity, transform: v.transform, locked: v.locked,
                          visibility: v.visibility))
    default:
        return element
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

/// Move a single handle without reflecting the opposite handle (cusp behavior).
public func movePathHandleIndependent(_ d: [PathCommand], anchorIdx: Int, handleType: String,
                                      dx: Double, dy: Double) -> [PathCommand] {
    var cmdIndices: [Int] = []
    for (ci, cmd) in d.enumerated() {
        if case .closePath = cmd { continue }
        cmdIndices.append(ci)
    }
    guard anchorIdx >= 0, anchorIdx < cmdIndices.count else { return d }
    let ci = cmdIndices[anchorIdx]
    var cmds = d
    if handleType == "in" {
        if case .curveTo(let x1, let y1, let x2, let y2, let x, let y) = cmds[ci] {
            cmds[ci] = .curveTo(x1: x1, y1: y1, x2: x2 + dx, y2: y2 + dy, x: x, y: y)
        }
    } else if handleType == "out" {
        if ci + 1 < cmds.count,
           case .curveTo(let x1, let y1, let x2, let y2, let x, let y) = cmds[ci + 1] {
            cmds[ci + 1] = .curveTo(x1: x1 + dx, y1: y1 + dy, x2: x2, y2: y2, x: x, y: y)
        }
    }
    return cmds
}

/// True if a path anchor has at least one non-degenerate handle (i.e. is "smooth").
public func isSmoothPoint(_ d: [PathCommand], anchorIdx: Int) -> Bool {
    let (hIn, hOut) = pathHandlePositions(d, anchorIdx: anchorIdx)
    return hIn != nil || hOut != nil
}

/// Convert a corner point to a smooth point with handles pulled toward (hx, hy).
/// The outgoing handle is placed at (hx, hy) and the incoming handle is reflected
/// through the anchor.
public func convertCornerToSmooth(_ d: [PathCommand], anchorIdx: Int,
                                  hx: Double, hy: Double) -> [PathCommand] {
    var cmdIndices: [Int] = []
    for (ci, cmd) in d.enumerated() {
        if case .closePath = cmd { continue }
        cmdIndices.append(ci)
    }
    guard anchorIdx >= 0, anchorIdx < cmdIndices.count else { return d }
    let ci = cmdIndices[anchorIdx]
    let cmd = d[ci]
    let ax: Double, ay: Double
    switch cmd {
    case .moveTo(let x, let y), .lineTo(let x, let y):
        ax = x; ay = y
    case .curveTo(_, _, _, _, let x, let y):
        ax = x; ay = y
    default:
        return d
    }
    // Reflected handle: mirror (hx, hy) through the anchor.
    let rhx = 2.0 * ax - hx
    let rhy = 2.0 * ay - hy
    var cmds = d
    // Set incoming handle (x2, y2) on this command to the reflected position.
    switch cmds[ci] {
    case .lineTo(let x, let y):
        // Use previous anchor as x1,y1 if there is one.
        var px = x, py = y
        if ci > 0 {
            switch d[ci - 1] {
            case .moveTo(let mx, let my), .lineTo(let mx, let my): px = mx; py = my
            case .curveTo(_, _, _, _, let cxe, let cye): px = cxe; py = cye
            default: break
            }
        }
        cmds[ci] = .curveTo(x1: px, y1: py, x2: rhx, y2: rhy, x: x, y: y)
    case .curveTo(let x1, let y1, _, _, let x, let y):
        cmds[ci] = .curveTo(x1: x1, y1: y1, x2: rhx, y2: rhy, x: x, y: y)
    case .moveTo:
        // No incoming handle on a MoveTo; only outgoing handle is set below.
        break
    default:
        break
    }
    // Set outgoing handle (x1, y1) on the next command to (hx, hy).
    if ci + 1 < cmds.count {
        switch cmds[ci + 1] {
        case .lineTo(let x, let y):
            cmds[ci + 1] = .curveTo(x1: hx, y1: hy, x2: x, y2: y, x: x, y: y)
        case .curveTo(_, _, let x2, let y2, let x, let y):
            cmds[ci + 1] = .curveTo(x1: hx, y1: hy, x2: x2, y2: y2, x: x, y: y)
        default:
            break
        }
    }
    return cmds
}

/// Convert a smooth point to a corner point by collapsing both handles to the anchor.
public func convertSmoothToCorner(_ d: [PathCommand], anchorIdx: Int) -> [PathCommand] {
    var cmdIndices: [Int] = []
    for (ci, cmd) in d.enumerated() {
        if case .closePath = cmd { continue }
        cmdIndices.append(ci)
    }
    guard anchorIdx >= 0, anchorIdx < cmdIndices.count else { return d }
    let ci = cmdIndices[anchorIdx]
    let cmd = d[ci]
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
    // Collapse incoming handle (x2, y2) on this command to the anchor.
    if case .curveTo(let x1, let y1, _, _, let x, let y) = cmds[ci] {
        cmds[ci] = .curveTo(x1: x1, y1: y1, x2: ax, y2: ay, x: x, y: y)
    }
    // Collapse outgoing handle (x1, y1) on the next command to the anchor.
    if ci + 1 < cmds.count,
       case .curveTo(_, _, let x2, let y2, let x, let y) = cmds[ci + 1] {
        cmds[ci + 1] = .curveTo(x1: ax, y1: ay, x2: x2, y2: y2, x: x, y: y)
    }
    return cmds
}

/// SVG \<line\> element.
public struct Line: Equatable {
    public let x1: Double, y1: Double, x2: Double, y2: Double
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public let name: String?
    public let stroke: Stroke?
    public let widthPoints: [StrokeWidthPoint]
    public let opacity: Double
    public let transform: Transform?
    public let locked: Bool
    public let visibility: Visibility
    public let blendMode: BlendMode
    public let mask: Mask?
    /// Optional gradient applied to the stroke (in lieu of `stroke.color`).
    /// Phase 1b adds gradient paint per-element. See GRADIENT.md
    /// §Document model.
    public let strokeGradient: Gradient?

    public init(x1: Double, y1: Double, x2: Double, y2: Double,
                stroke: Stroke? = nil, widthPoints: [StrokeWidthPoint] = [],
                opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                mask: Mask? = nil,
                strokeGradient: Gradient? = nil,
                name: String? = nil) {
        self.name = name
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
        self.stroke = stroke; self.widthPoints = widthPoints
        self.opacity = opacity; self.transform = transform
        self.locked = locked
        self.visibility = visibility
        self.blendMode = blendMode
        self.mask = mask
        self.strokeGradient = strokeGradient
    }

    public var bounds: BBox {
        let minX = min(x1, x2), minY = min(y1, y2)
        return inflateBounds((minX, minY, abs(x2 - x1), abs(y2 - y1)), stroke)
    }
}

/// SVG \<rect\> element.
public struct Rect: Equatable {
    public let x: Double, y: Double, width: Double, height: Double
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public let name: String?
    public let rx: Double, ry: Double
    public let fill: Fill?
    public let stroke: Stroke?
    public let opacity: Double
    public let transform: Transform?
    public let locked: Bool
    public let visibility: Visibility
    public let blendMode: BlendMode
    public let mask: Mask?
    public let fillGradient: Gradient?
    public let strokeGradient: Gradient?

    public init(x: Double, y: Double, width: Double, height: Double,
                rx: Double = 0, ry: Double = 0,
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                mask: Mask? = nil,
                fillGradient: Gradient? = nil,
                strokeGradient: Gradient? = nil,
                name: String? = nil) {
        self.name = name
        self.x = x; self.y = y; self.width = width; self.height = height
        self.rx = rx; self.ry = ry
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
        self.locked = locked
        self.visibility = visibility
        self.blendMode = blendMode
        self.mask = mask
        self.fillGradient = fillGradient
        self.strokeGradient = strokeGradient
    }

    public var bounds: BBox { inflateBounds((x, y, width, height), stroke) }
}

/// SVG \<circle\> element.
public struct Circle: Equatable {
    public let cx: Double, cy: Double, r: Double
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public let name: String?
    public let fill: Fill?
    public let stroke: Stroke?
    public let opacity: Double
    public let transform: Transform?
    public let locked: Bool
    public let visibility: Visibility
    public let blendMode: BlendMode
    public let mask: Mask?
    public let fillGradient: Gradient?
    public let strokeGradient: Gradient?

    public init(cx: Double, cy: Double, r: Double,
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                mask: Mask? = nil,
                fillGradient: Gradient? = nil,
                strokeGradient: Gradient? = nil,
                name: String? = nil) {
        self.name = name
        self.cx = cx; self.cy = cy; self.r = r
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
        self.locked = locked
        self.visibility = visibility
        self.blendMode = blendMode
        self.mask = mask
        self.fillGradient = fillGradient
        self.strokeGradient = strokeGradient
    }

    public var bounds: BBox { inflateBounds((cx - r, cy - r, r * 2, r * 2), stroke) }
}

/// SVG \<ellipse\> element.
public struct Ellipse: Equatable {
    public let cx: Double, cy: Double, rx: Double, ry: Double
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public let name: String?
    public let fill: Fill?
    public let stroke: Stroke?
    public let opacity: Double
    public let transform: Transform?
    public let locked: Bool
    public let visibility: Visibility
    public let blendMode: BlendMode
    public let mask: Mask?
    public let fillGradient: Gradient?
    public let strokeGradient: Gradient?

    public init(cx: Double, cy: Double, rx: Double, ry: Double,
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                mask: Mask? = nil,
                fillGradient: Gradient? = nil,
                strokeGradient: Gradient? = nil,
                name: String? = nil) {
        self.name = name
        self.cx = cx; self.cy = cy; self.rx = rx; self.ry = ry
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
        self.locked = locked
        self.visibility = visibility
        self.blendMode = blendMode
        self.mask = mask
        self.fillGradient = fillGradient
        self.strokeGradient = strokeGradient
    }

    public var bounds: BBox { inflateBounds((cx - rx, cy - ry, rx * 2, ry * 2), stroke) }
}

/// SVG \<polyline\> element.
public struct Polyline: Equatable {
    public let points: [(Double, Double)]
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public let name: String?
    public let fill: Fill?
    public let stroke: Stroke?
    public let opacity: Double
    public let transform: Transform?
    public let locked: Bool
    public let visibility: Visibility
    public let blendMode: BlendMode
    public let mask: Mask?
    public let fillGradient: Gradient?
    public let strokeGradient: Gradient?

    public init(points: [(Double, Double)],
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                mask: Mask? = nil,
                fillGradient: Gradient? = nil,
                strokeGradient: Gradient? = nil,
                name: String? = nil) {
        self.name = name
        self.points = points
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
        self.locked = locked
        self.visibility = visibility
        self.blendMode = blendMode
        self.mask = mask
        self.fillGradient = fillGradient
        self.strokeGradient = strokeGradient
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
            && lhs.locked == rhs.locked
    }
}

/// SVG \<polygon\> element.
public struct Polygon: Equatable {
    public let points: [(Double, Double)]
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public let name: String?
    public let fill: Fill?
    public let stroke: Stroke?
    public let opacity: Double
    public let transform: Transform?
    public let locked: Bool
    public let visibility: Visibility
    public let blendMode: BlendMode
    public let mask: Mask?
    public let fillGradient: Gradient?
    public let strokeGradient: Gradient?

    public init(points: [(Double, Double)],
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                mask: Mask? = nil,
                fillGradient: Gradient? = nil,
                strokeGradient: Gradient? = nil,
                name: String? = nil) {
        self.name = name
        self.points = points
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
        self.locked = locked
        self.visibility = visibility
        self.blendMode = blendMode
        self.mask = mask
        self.fillGradient = fillGradient
        self.strokeGradient = strokeGradient
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
            && lhs.locked == rhs.locked
    }
}

/// Return t-values in (0,1) where a cubic Bezier is at an extremum.
private func cubicExtrema(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> [Double] {
    let a = -3*p0 + 9*p1 - 9*p2 + 3*p3
    let b = 6*p0 - 12*p1 + 6*p2
    let c = -3*p0 + 3*p1
    if Swift.abs(a) < 1e-12 {
        if Swift.abs(b) > 1e-12 {
            let t = -c / b
            return (t > 0 && t < 1) ? [t] : []
        }
        return []
    }
    let disc = b*b - 4*a*c
    guard disc >= 0 else { return [] }
    let sq = disc.squareRoot()
    return [(-b + sq) / (2*a), (-b - sq) / (2*a)].filter { $0 > 0 && $0 < 1 }
}

private func quadraticExtremum(_ p0: Double, _ p1: Double, _ p2: Double) -> [Double] {
    let denom = p0 - 2*p1 + p2
    guard Swift.abs(denom) >= 1e-12 else { return [] }
    let t = (p0 - p1) / denom
    return (t > 0 && t < 1) ? [t] : []
}

private func cubicEval(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ t: Double) -> Double {
    let u = 1 - t
    return u*u*u*p0 + 3*u*u*t*p1 + 3*u*t*t*p2 + t*t*t*p3
}

private func quadraticEval(_ p0: Double, _ p1: Double, _ p2: Double, _ t: Double) -> Double {
    let u = 1 - t
    return u*u*p0 + 2*u*t*p1 + t*t*p2
}

/// SVG \<path\> element.
/// Compute tight bounds by finding Bezier extrema.
func pathBounds(_ d: [PathCommand]) -> BBox {
    var xs: [Double] = [], ys: [Double] = []
    var cx = 0.0, cy = 0.0
    var sx = 0.0, sy = 0.0
    var prevX2 = 0.0, prevY2 = 0.0
    var prevIsCurve = false
    for cmd in d {
        switch cmd {
        case .moveTo(let x, let y):
            xs.append(x); ys.append(y)
            cx = x; cy = y; sx = x; sy = y
        case .lineTo(let x, let y):
            xs.append(x); ys.append(y)
            cx = x; cy = y
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            xs.append(contentsOf: [cx, x]); ys.append(contentsOf: [cy, y])
            for t in cubicExtrema(cx, x1, x2, x) { xs.append(cubicEval(cx, x1, x2, x, t)) }
            for t in cubicExtrema(cy, y1, y2, y) { ys.append(cubicEval(cy, y1, y2, y, t)) }
            prevX2 = x2; prevY2 = y2; cx = x; cy = y
            prevIsCurve = true; continue
        case .smoothCurveTo(let x2, let y2, let x, let y):
            let (rx1, ry1) = prevIsCurve ? (2*cx - prevX2, 2*cy - prevY2) : (cx, cy)
            xs.append(contentsOf: [cx, x]); ys.append(contentsOf: [cy, y])
            for t in cubicExtrema(cx, rx1, x2, x) { xs.append(cubicEval(cx, rx1, x2, x, t)) }
            for t in cubicExtrema(cy, ry1, y2, y) { ys.append(cubicEval(cy, ry1, y2, y, t)) }
            prevX2 = x2; prevY2 = y2; cx = x; cy = y
            prevIsCurve = true; continue
        case .quadTo(let x1, let y1, let x, let y):
            xs.append(contentsOf: [cx, x]); ys.append(contentsOf: [cy, y])
            for t in quadraticExtremum(cx, x1, x) { xs.append(quadraticEval(cx, x1, x, t)) }
            for t in quadraticExtremum(cy, y1, y) { ys.append(quadraticEval(cy, y1, y, t)) }
            cx = x; cy = y
        case .smoothQuadTo(let x, let y):
            xs.append(x); ys.append(y)
            cx = x; cy = y
        case .arcTo(_, _, _, _, _, let x, let y):
            xs.append(x); ys.append(y)
            cx = x; cy = y
        case .closePath:
            cx = sx; cy = sy
        }
        prevIsCurve = false
    }
    guard !xs.isEmpty else { return (0, 0, 0, 0) }
    let minX = xs.min()!, minY = ys.min()!
    return (minX, minY, xs.max()! - minX, ys.max()! - minY)
}

public struct Path: Equatable {
    public let d: [PathCommand]
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public let name: String?
    public let fill: Fill?
    public let stroke: Stroke?
    public let widthPoints: [StrokeWidthPoint]
    public let opacity: Double
    public let transform: Transform?
    public let locked: Bool
    public let visibility: Visibility
    public let blendMode: BlendMode
    public let mask: Mask?
    public let fillGradient: Gradient?
    public let strokeGradient: Gradient?
    /// Active-brush reference as "<library_slug>/<brush_slug>", or
    /// nil for a plain native-stroke path. Consumed by the canvas
    /// renderer's brush dispatch (Phase 3.4). See BRUSHES.md
    /// §Stroke styling interaction.
    public let strokeBrush: String?
    /// Per-instance brush-parameter overrides as compact JSON
    /// layered over the master brush at render time. See BRUSHES.md
    /// §Panel state.
    public let strokeBrushOverrides: String?
    /// Optional `jas:tool-origin` tag identifying the tool that
    /// produced this element. Blob Brush sets `"blob_brush"` on its
    /// commits so subsequent sweeps can merge / erase into the same
    /// element. Preserved by mutations; optional on export.
    /// See BLOB_BRUSH_TOOL.md §Fill and stroke.
    public let toolOrigin: String?

    public init(d: [PathCommand],
                fill: Fill? = nil, stroke: Stroke? = nil,
                widthPoints: [StrokeWidthPoint] = [],
                opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                mask: Mask? = nil,
                fillGradient: Gradient? = nil,
                strokeGradient: Gradient? = nil,
                strokeBrush: String? = nil,
                strokeBrushOverrides: String? = nil,
                toolOrigin: String? = nil,
                name: String? = nil) {
        self.name = name
        self.d = d
        self.fill = fill; self.stroke = stroke; self.widthPoints = widthPoints
        self.opacity = opacity; self.transform = transform
        self.locked = locked
        self.visibility = visibility
        self.blendMode = blendMode
        self.mask = mask
        self.fillGradient = fillGradient
        self.strokeGradient = strokeGradient
        self.strokeBrush = strokeBrush
        self.strokeBrushOverrides = strokeBrushOverrides
        self.toolOrigin = toolOrigin
    }

    public var bounds: BBox {
        return inflateBounds(pathBounds(d), stroke)
    }
}

/// SVG \<text\> element.
///
/// Text is stored as an ordered, non-empty list of `tspans`
/// (per-character-range formatting substructures). The flat
/// `content: String` surface is preserved as a derived computed
/// property so existing callers continue to work; every constructor
/// that takes a `content: String` wraps it in a single default
/// tspan with id 0.
///
/// New character-panel fields (text_transform, font_variant,
/// baseline_shift, line_height, letter_spacing, xml_lang, aa_mode,
/// rotate, horizontal_scale, vertical_scale, kerning) mirror the
/// Rust TextElem shape. Empty string means "omit / inherit default"
/// per CHARACTER.md's identity-omission rule.
public struct Text: Equatable {
    public let x: Double, y: Double
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public let name: String?
    public let tspans: [Tspan]
    public let fontFamily: String
    public let fontSize: Double
    public let fontWeight: String
    public let fontStyle: String
    public let textDecoration: String
    public let textTransform: String
    public let fontVariant: String
    public let baselineShift: String
    public let lineHeight: String
    public let letterSpacing: String
    public let xmlLang: String
    public let aaMode: String
    public let rotate: String
    public let horizontalScale: String
    public let verticalScale: String
    public let kerning: String
    public let width: Double
    public let height: Double
    public let fill: Fill?
    public let stroke: Stroke?
    public let opacity: Double
    public let transform: Transform?
    public let locked: Bool
    public let visibility: Visibility
    public let blendMode: BlendMode
    public let mask: Mask?

    /// Primary tspans-based initializer. Used by canonical JSON /
    /// SVG parsers that have already split the text into tspans.
    public init(x: Double, y: Double, tspans: [Tspan],
                fontFamily: String = "sans-serif", fontSize: Double = 16.0,
                fontWeight: String = "normal", fontStyle: String = "normal",
                textDecoration: String = "none",
                textTransform: String = "", fontVariant: String = "",
                baselineShift: String = "", lineHeight: String = "",
                letterSpacing: String = "", xmlLang: String = "",
                aaMode: String = "", rotate: String = "",
                horizontalScale: String = "", verticalScale: String = "",
                kerning: String = "",
                width: Double = 0, height: Double = 0,
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                mask: Mask? = nil,
                name: String? = nil) {
        self.name = name
        self.x = x; self.y = y; self.tspans = tspans
        self.fontFamily = fontFamily; self.fontSize = fontSize
        self.fontWeight = fontWeight; self.fontStyle = fontStyle; self.textDecoration = textDecoration
        self.textTransform = textTransform; self.fontVariant = fontVariant
        self.baselineShift = baselineShift; self.lineHeight = lineHeight
        self.letterSpacing = letterSpacing; self.xmlLang = xmlLang
        self.aaMode = aaMode; self.rotate = rotate
        self.horizontalScale = horizontalScale; self.verticalScale = verticalScale
        self.kerning = kerning
        self.width = width; self.height = height
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
        self.locked = locked
        self.visibility = visibility
        self.blendMode = blendMode
        self.mask = mask
    }

    /// Backward-compatible convenience initializer that wraps a flat
    /// string in a single default tspan (id 0, no overrides).
    public init(x: Double, y: Double, content: String,
                fontFamily: String = "sans-serif", fontSize: Double = 16.0,
                fontWeight: String = "normal", fontStyle: String = "normal",
                textDecoration: String = "none",
                textTransform: String = "", fontVariant: String = "",
                baselineShift: String = "", lineHeight: String = "",
                letterSpacing: String = "", xmlLang: String = "",
                aaMode: String = "", rotate: String = "",
                horizontalScale: String = "", verticalScale: String = "",
                kerning: String = "",
                width: Double = 0, height: Double = 0,
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                mask: Mask? = nil,
                name: String? = nil) {
        let t = Tspan(id: 0, content: content)
        self.init(x: x, y: y, tspans: [t],
                  fontFamily: fontFamily, fontSize: fontSize,
                  fontWeight: fontWeight, fontStyle: fontStyle,
                  textDecoration: textDecoration,
                  textTransform: textTransform, fontVariant: fontVariant,
                  baselineShift: baselineShift, lineHeight: lineHeight,
                  letterSpacing: letterSpacing, xmlLang: xmlLang,
                  aaMode: aaMode, rotate: rotate,
                  horizontalScale: horizontalScale, verticalScale: verticalScale,
                  kerning: kerning,
                  width: width, height: height,
                  fill: fill, stroke: stroke,
                  opacity: opacity, transform: transform,
                  locked: locked, visibility: visibility,
                  name: name)
    }

    /// Derived content: concatenation of every tspan's content.
    public var content: String { concatTspanContent(tspans) }

    public var isAreaText: Bool { width > 0 && height > 0 }

    /// Return a copy of this Text with the given fields replaced. Used by
    /// `TextEditSession.applyToDocument` so the field list lives in one
    /// place.
    public func with(content: String) -> Text {
        Text(x: x, y: y, content: content,
             fontFamily: fontFamily, fontSize: fontSize,
             fontWeight: fontWeight, fontStyle: fontStyle,
             textDecoration: textDecoration,
             textTransform: textTransform, fontVariant: fontVariant,
             baselineShift: baselineShift, lineHeight: lineHeight,
             letterSpacing: letterSpacing, xmlLang: xmlLang,
             aaMode: aaMode, rotate: rotate,
             horizontalScale: horizontalScale, verticalScale: verticalScale,
             kerning: kerning,
             width: width, height: height,
             fill: fill, stroke: stroke,
             opacity: opacity, transform: transform, locked: locked)
    }

    /// Return a copy with the tspans list replaced. Preserves every
    /// other field. Used by `TextEditSession.applyToDocument` after
    /// reconciling content so per-range overrides survive.
    public func withTspans(_ tspans: [Tspan]) -> Text {
        Text(x: x, y: y, tspans: tspans,
             fontFamily: fontFamily, fontSize: fontSize,
             fontWeight: fontWeight, fontStyle: fontStyle,
             textDecoration: textDecoration,
             textTransform: textTransform, fontVariant: fontVariant,
             baselineShift: baselineShift, lineHeight: lineHeight,
             letterSpacing: letterSpacing, xmlLang: xmlLang,
             aaMode: aaMode, rotate: rotate,
             horizontalScale: horizontalScale, verticalScale: verticalScale,
             kerning: kerning,
             width: width, height: height,
             fill: fill, stroke: stroke,
             opacity: opacity, transform: transform, locked: locked)
    }

    public var bounds: BBox {
        if isAreaText {
            return (x, y, width, height)
        }
        // Point text: `y` is the *top* of the layout box (the baseline is
        // `y + 0.8*fontSize`, matching `text_layout`'s ascent). Width is
        // the widest "\n"-separated line measured with the real font;
        // height is fontSize × line count.
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var maxW: Double = 0
        for l in lines {
            let w = renderedTextWidth(String(l), family: fontFamily,
                                      weight: fontWeight, style: fontStyle, size: fontSize)
            if w > maxW { maxW = w }
        }
        let height = Double(max(lines.count, 1)) * fontSize
        return (x, y, maxW, height)
    }
}

/// SVG \<text\>\<textPath\> — text rendered along a path.
///
/// Same tspan migration as `Text`: stored as `tspans`, `content` is
/// computed, the `content:` initializer wraps in a default tspan.
/// The 11 new character-panel fields mirror `Text`'s.
public struct TextPath: Equatable {
    public let d: [PathCommand]
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public let name: String?
    public let tspans: [Tspan]
    public let startOffset: Double
    public let fontFamily: String
    public let fontSize: Double
    public let fontWeight: String
    public let fontStyle: String
    public let textDecoration: String
    public let textTransform: String
    public let fontVariant: String
    public let baselineShift: String
    public let lineHeight: String
    public let letterSpacing: String
    public let xmlLang: String
    public let aaMode: String
    public let rotate: String
    public let horizontalScale: String
    public let verticalScale: String
    public let kerning: String
    public let fill: Fill?
    public let stroke: Stroke?
    public let opacity: Double
    public let transform: Transform?

    public let locked: Bool
    public let visibility: Visibility
    public let blendMode: BlendMode
    public let mask: Mask?

    public init(d: [PathCommand], tspans: [Tspan],
                startOffset: Double = 0.0,
                fontFamily: String = "sans-serif", fontSize: Double = 16.0,
                fontWeight: String = "normal", fontStyle: String = "normal",
                textDecoration: String = "none",
                textTransform: String = "", fontVariant: String = "",
                baselineShift: String = "", lineHeight: String = "",
                letterSpacing: String = "", xmlLang: String = "",
                aaMode: String = "", rotate: String = "",
                horizontalScale: String = "", verticalScale: String = "",
                kerning: String = "",
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                mask: Mask? = nil,
                name: String? = nil) {
        self.name = name
        self.d = d; self.tspans = tspans; self.startOffset = startOffset
        self.fontFamily = fontFamily; self.fontSize = fontSize
        self.fontWeight = fontWeight; self.fontStyle = fontStyle; self.textDecoration = textDecoration
        self.textTransform = textTransform; self.fontVariant = fontVariant
        self.baselineShift = baselineShift; self.lineHeight = lineHeight
        self.letterSpacing = letterSpacing; self.xmlLang = xmlLang
        self.aaMode = aaMode; self.rotate = rotate
        self.horizontalScale = horizontalScale; self.verticalScale = verticalScale
        self.kerning = kerning
        self.fill = fill; self.stroke = stroke; self.opacity = opacity; self.transform = transform
        self.locked = locked
        self.visibility = visibility
        self.blendMode = blendMode
        self.mask = mask
    }

    /// Backward-compatible initializer: wraps a flat content string in
    /// a single default tspan.
    public init(d: [PathCommand], content: String = "Lorem Ipsum",
                startOffset: Double = 0.0,
                fontFamily: String = "sans-serif", fontSize: Double = 16.0,
                fontWeight: String = "normal", fontStyle: String = "normal",
                textDecoration: String = "none",
                textTransform: String = "", fontVariant: String = "",
                baselineShift: String = "", lineHeight: String = "",
                letterSpacing: String = "", xmlLang: String = "",
                aaMode: String = "", rotate: String = "",
                horizontalScale: String = "", verticalScale: String = "",
                kerning: String = "",
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                mask: Mask? = nil) {
        let t = Tspan(id: 0, content: content)
        self.init(d: d, tspans: [t], startOffset: startOffset,
                  fontFamily: fontFamily, fontSize: fontSize,
                  fontWeight: fontWeight, fontStyle: fontStyle,
                  textDecoration: textDecoration,
                  textTransform: textTransform, fontVariant: fontVariant,
                  baselineShift: baselineShift, lineHeight: lineHeight,
                  letterSpacing: letterSpacing, xmlLang: xmlLang,
                  aaMode: aaMode, rotate: rotate,
                  horizontalScale: horizontalScale, verticalScale: verticalScale,
                  kerning: kerning,
                  fill: fill, stroke: stroke,
                  opacity: opacity, transform: transform,
                  locked: locked, visibility: visibility)
    }

    public var content: String { concatTspanContent(tspans) }

    public var bounds: BBox {
        return inflateBounds(pathBounds(d), stroke)
    }

    /// Return a copy of this TextPath with `content` replaced.
    public func with(content: String) -> TextPath {
        TextPath(d: d, content: content, startOffset: startOffset,
                 fontFamily: fontFamily, fontSize: fontSize,
                 fontWeight: fontWeight, fontStyle: fontStyle,
                 textDecoration: textDecoration,
                 textTransform: textTransform, fontVariant: fontVariant,
                 baselineShift: baselineShift, lineHeight: lineHeight,
                 letterSpacing: letterSpacing, xmlLang: xmlLang,
                 aaMode: aaMode, rotate: rotate,
                 horizontalScale: horizontalScale, verticalScale: verticalScale,
                 kerning: kerning,
                 fill: fill, stroke: stroke,
                 opacity: opacity, transform: transform, locked: locked)
    }

    /// Return a copy with the tspans list replaced.
    public func withTspans(_ tspans: [Tspan]) -> TextPath {
        TextPath(d: d, tspans: tspans, startOffset: startOffset,
                 fontFamily: fontFamily, fontSize: fontSize,
                 fontWeight: fontWeight, fontStyle: fontStyle,
                 textDecoration: textDecoration,
                 textTransform: textTransform, fontVariant: fontVariant,
                 baselineShift: baselineShift, lineHeight: lineHeight,
                 letterSpacing: letterSpacing, xmlLang: xmlLang,
                 aaMode: aaMode, rotate: rotate,
                 horizontalScale: horizontalScale, verticalScale: verticalScale,
                 kerning: kerning,
                 fill: fill, stroke: stroke,
                 opacity: opacity, transform: transform, locked: locked)
    }
}

/// SVG \<g\> element.
public struct Group: Equatable {
    public let children: [Element]
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public let name: String?
    public let opacity: Double
    public let transform: Transform?
    public let locked: Bool
    public let visibility: Visibility
    public let blendMode: BlendMode
    public let mask: Mask?
    /// Opacity panel "Page Isolated Blending" flag. Storage-only in
    /// Phase 2; renderer support is deferred. Default false.
    public let isolatedBlending: Bool
    /// Opacity panel "Page Knockout Group" flag. Storage-only in
    /// Phase 2; renderer support is deferred. Default false.
    public let knockoutGroup: Bool

    public init(children: [Element], opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                isolatedBlending: Bool = false,
                knockoutGroup: Bool = false,
                mask: Mask? = nil,
                name: String? = nil) {
        self.name = name
        self.children = children
        self.opacity = opacity; self.transform = transform
        self.locked = locked
        self.visibility = visibility
        self.blendMode = blendMode
        self.isolatedBlending = isolatedBlending
        self.knockoutGroup = knockoutGroup
        self.mask = mask
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
    public let locked: Bool
    public let visibility: Visibility
    public let blendMode: BlendMode
    public let mask: Mask?
    /// See ``Group/isolatedBlending``. Present on layers so the
    /// document root (a Layer) can carry the flag today.
    public let isolatedBlending: Bool
    /// See ``Group/knockoutGroup``.
    public let knockoutGroup: Bool

    public init(name: String = "Layer", children: [Element], opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                isolatedBlending: Bool = false,
                knockoutGroup: Bool = false,
                mask: Mask? = nil) {
        self.name = name
        self.children = children
        self.opacity = opacity; self.transform = transform
        self.locked = locked
        self.visibility = visibility
        self.blendMode = blendMode
        self.isolatedBlending = isolatedBlending
        self.knockoutGroup = knockoutGroup
        self.mask = mask
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
