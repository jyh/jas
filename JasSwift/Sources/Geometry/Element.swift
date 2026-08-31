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
        // quantise8, not `max(0, min(255, Int(round(x * 255))))`: that outer
        // clamp was correct and agreed with Rust for every FINITE component,
        // but the INNER cast was a precondition failure on NaN / ±infinity
        // where Rust's `as u8` saturates. Risk R9.
        let ri = quantise8(r), gi = quantise8(g), bi = quantise8(b)
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
    // A non-finite hue is sanitised to 0 in BOTH ports before the sector
    // index is taken. `Int(floor(h / 60.0))` here is a precondition failure on
    // NaN, where Rust's `as u32` yields 0 and then carries NaN into two of the
    // three components — neither is a colour, so the ports agree on 0 instead.
    // Infinity reaches the same place: the wrap below is NaN for it. Risk R9,
    // transcripts/CORPUS_CENSUS.md §7. Rust twin: geometry/element.rs
    // hsb_to_rgb_components.
    let h = h.isFinite
        ? ((h.truncatingRemainder(dividingBy: 360.0)) + 360.0)
            .truncatingRemainder(dividingBy: 360.0)
        : 0.0
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

    /// Advance one step in the Layers eye cycle: preview -> outline ->
    /// invisible -> preview. Pure; used by the tree-row eye button.
    /// Cross-app equivalent of OCaml `Element.cycle_visibility`, Python
    /// `_cycle_visibility`, Rust `cycle_element_visibility`.
    public var cycled: Visibility {
        switch self {
        case .preview: return .outline
        case .outline: return .invisible
        case .invisible: return .preview
        }
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

    /// A copy of this stroke with its `width` replaced, preserving every
    /// other field. Used by the element-stroke counter-scale to rewrite
    /// `stroke.width` at the source so EVERY reader (the pen line width AND
    /// the arrowhead setback) sees the divided width.
    public func withWidth(_ width: Double) -> Stroke {
        Stroke(color: color, width: width, linecap: linecap, linejoin: linejoin,
               miterLimit: miterLimit, align: align,
               dashPattern: dashPattern, dashAlignAnchors: dashAlignAnchors,
               startArrow: startArrow, endArrow: endArrow,
               startArrowScale: startArrowScale, endArrowScale: endArrowScale,
               arrowAlign: arrowAlign, opacity: opacity)
    }

    /// A copy of this stroke with its `linecap` replaced, preserving every
    /// other field. Used to butt the arc-length-trimmed cut of an arrowheaded
    /// stroke so round/projecting caps can't poke into the head base.
    public func withLinecap(_ linecap: LineCap) -> Stroke {
        Stroke(color: color, width: width, linecap: linecap, linejoin: linejoin,
               miterLimit: miterLimit, align: align,
               dashPattern: dashPattern, dashAlignAnchors: dashAlignAnchors,
               startArrow: startArrow, endArrow: endArrow,
               startArrowScale: startArrowScale, endArrowScale: endArrowScale,
               arrowAlign: arrowAlign, opacity: opacity)
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
        // `angleDeg * (pi/180)`, NOT `angleDeg * pi / 180`. The two group
        // differently and disagree by an ulp on 184 of the 721 integer
        // degrees in [-360, 360] -- MEASURED through the transform_apply
        // corpus family, not argued. Rust spells this `f64::to_radians()`,
        // which is `self * (PI / 180.0)`, and since MATRIXPRECISION writes
        // a/b/c/d at full shortest-round-trip precision the difference is
        // no longer invisible: it reaches the `matrix(...)` bytes in the
        // saved SVG. Keep the parenthesis -- and it is no longer this site's
        // job to remember why: scripts/check_degree_radian_grouping.py refuses
        // the other spelling everywhere in both active ports.
        let rad = angleDeg * (Double.pi / 180)
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

/// Axis-aligned box of `b`'s four corners mapped through `t` — the one
/// meaning of "a bbox through a transform", shared with the Python
/// reference's `_aabb_through` and Rust's `geometry::element::aabb_through`.
///
/// ⚖️ This carries A6 §3.3's ruled contract (2026-08-31): the reveal mask
/// law's bbox is the axis-aligned bounds OF the transformed mask subtree —
/// `bounds(mask_xf · subtree)`, never the transform of its bounds as a
/// region, which a rotation makes inexpressible in an axis-aligned box.
/// Exact for every axis-preserving transform and for any subtree whose
/// geometry reaches its bbox corners; otherwise the box of the transformed
/// BOUNDS, the same over-approximation the evaluated-bbox family makes.
public func aabbThrough(_ b: BBox, _ t: Transform) -> BBox {
    let x0 = b.x, y0 = b.y, x1 = b.x + b.width, y1 = b.y + b.height
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity
    for (px, py) in [(x0, y0), (x1, y0), (x1, y1), (x0, y1)] {
        let (x, y) = t.applyPoint(px, py)
        minX = min(minX, x); minY = min(minY, y)
        maxX = max(maxX, x); maxY = max(maxY, y)
    }
    return (minX, minY, maxX - minX, maxY - minY)
}

/// Expand bounding box (x, y, w, h) by the ink the stroke actually puts
/// OUTSIDE the path, which depends on `stroke.align`.
///
/// RULED 2026-08-21: Center inflates by w/2 on each side, Inside not at all,
/// Outside by the full w. Twin: Rust's `inflate_bounds`.
///
/// This used to inflate by w/2 unconditionally — exactly right for Center and
/// wrong for the other two by w/2 per side, an error that SCALES with the
/// stroke (20pt on a 40pt stroke). Both ports were wrong in the same way, so
/// the cross-language equivalence law was blind to it by construction: a shared
/// defect agrees with itself.
///
/// NO CLOSEDNESS BRANCH — see the twin's note. `actions.yaml`'s "Inside and
/// outside behave as center on open paths" is implemented by no renderer, and
/// bounds follow the ink rather than the stale sentence.
private func inflateBounds(_ bbox: BBox, _ stroke: Stroke?) -> BBox {
    guard let stroke = stroke else { return bbox }
    let outward: Double
    switch stroke.align {
    case .center: outward = stroke.width / 2.0
    case .inside: outward = 0
    case .outside: outward = stroke.width
    }
    return (bbox.x - outward, bbox.y - outward,
            bbox.width + 2 * outward, bbox.height + 2 * outward)
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
/// Geometric bounds that RESOLVE the three live kinds whose geometry lives
/// behind an id (`reference` / `recorded` / `generated`), returning `nil` for an
/// element that occupies no canvas at all.
///
/// `Element.geometricBounds` and `Element.bounds` are deliberately left
/// resolver-less and both keep answering the zero box for those kinds — the same
/// two-form split as `HitTest`'s plain and `...With` verbs, for the same reason:
/// with no document behind it, there is no fact about where a target id is.
///
/// ## Why `nil`, and why it is the whole point
///
/// A dangling instance draws nothing, so it must contribute NOTHING to a union
/// — not a zero-sized box at the origin. `childrenGeometricBounds` unions its
/// children unconditionally, so a group holding one instance reported a box
/// STRETCHED BACK TO (0,0): measured (0,0,110,110) for a group whose true extent
/// was (5,7,105,103). The empty box was not merely absent; it was a phantom
/// point at the origin that the union swallowed.
///
/// Degenerate boxes from every OTHER kind still contribute exactly as before.
/// Mirrors Rust `resolved_geometric_bounds` (geometry/element.rs).
public func resolvedGeometricBounds(_ elem: Element, _ resolver: ElementResolver) -> BBox? {
    resolvedBoundsWith(elem, resolver) { $0.geometricBounds }
}

/// ``resolvedGeometricBounds(_:_:)`` with the leaf measurement chosen by the
/// caller: `\.geometricBounds` for the stroke-exclusive box, `\.bounds` for the
/// stroke-inflated (preview) one.
///
/// The parameter exists because Align reads both, under its Use Preview Bounds
/// flag. Hard-coding the geometric leaf would have silently dropped stroke
/// inflation from every leaf inside a GROUP the moment align started resolving
/// — fixing an instance's box by breaking every stroked sibling's.
///
/// **A resolver-backed kind answers with its resolved rings under EITHER leaf
/// choice**, because evaluated rings carry no stroke. So an instance's own
/// stroke inflation is still missing in preview mode; it would need the
/// resolved TARGET's stroke, which is different work. A bounded, stated
/// shortfall, and strictly better than the zero box it replaces — which was
/// wrong in both modes.
public func resolvedBoundsWith(_ elem: Element,
                               _ resolver: ElementResolver,
                               _ leaf: (Element) -> BBox) -> BBox? {
    if let rings = resolvedRings(elem, resolver) {
        return ringsBBox(rings)
    }
    switch elem {
    case .group(let g): return resolvedChildrenBounds(g.children, resolver, leaf)
    case .layer(let l): return resolvedChildrenBounds(l.children, resolver, leaf)
    default: return leaf(elem)
    }
}

/// Union of the children's resolved geometric bounds, skipping the ones that
/// occupy nothing. `nil` when no child occupies anything.
private func resolvedChildrenBounds(_ children: [Element],
                                    _ resolver: ElementResolver,
                                    _ leaf: (Element) -> BBox) -> BBox? {
    var acc: (Double, Double, Double, Double)? = nil
    for c in children {
        guard let b = resolvedBoundsWith(c, resolver, leaf) else { continue }
        if let (ax, ay, bx, by) = acc {
            acc = (min(ax, b.x), min(ay, b.y),
                   max(bx, b.x + b.width), max(by, b.y + b.height))
        } else {
            acc = (b.x, b.y, b.x + b.width, b.y + b.height)
        }
    }
    guard let (ax, ay, bx, by) = acc else { return nil }
    return (x: ax, y: ay, width: bx - ax, height: by - ay)
}

private func childrenGeometricBounds(_ children: [Element]) -> BBox {
    guard !children.isEmpty else { return (0, 0, 0, 0) }
    let all = children.map(\.geometricBounds)
    let minX = all.map(\.x).min()!, minY = all.map(\.y).min()!
    let maxX = all.map { $0.x + $0.width }.max()!
    let maxY = all.map { $0.y + $0.height }.max()!
    return (minX, minY, maxX - minX, maxY - minY)
}

/// Translate the selected anchors of a command list by (dx, dy).
///
/// Anchor `i` is the i'th non-`closePath` command. Moving an anchor drags the
/// handles that belong to it: a `moveTo` also carries the FOLLOWING curve's
/// outgoing handle, and a `curveTo` carries its own incoming handle plus the
/// next curve's outgoing one. Mirrors Rust `move_path_command_points`
/// (`jas_dioxus/src/geometry/element.rs`).
///
/// Factored out of `moveControlPoints`: the `.path` and `.textPath` arms held
/// two byte-identical copies of this walk, which is the shape that lets two
/// arms of one switch drift apart.
fileprivate func movePathCommandPoints(_ d: [PathCommand], _ kind: SelectionKind,
                                       dx: Double, dy: Double) -> [PathCommand] {
    var cmds = d
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
    return cmds
}

/// An SVG document element. All elements are immutable value types.
public enum Element: Equatable {
    /// SVG \<line\>
    case line(Line)
    /// SVG \<rect\>
    case rect(Rect)
    /// SVG \<circle\>
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
        case .rect, .ellipse: return 4
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

    /// ``controlPointPositions`` for an element that may measure something
    /// ELSEWHERE in the document — a symbol instance and its recorded /
    /// generated siblings.
    ///
    /// The kinds that carry their own coordinates answer identically; the
    /// resolver-backed ones fall to the bbox-corner branch, and THAT is where
    /// the two differ. `bounds` has no resolver, so it answers a zero box at
    /// the ORIGIN for them and the four "corners" collapse onto (0,0): a
    /// selected instance drew its box correctly (the box resolves) with its
    /// four resize handles stacked in the corner of the document. Spelled as a
    /// second NAME rather than a defaulted argument so no caller can get the
    /// narrow answer by omission. Twin of Rust's `control_points_with`.
    public func controlPointPositions(resolvedBy resolver: ElementResolver)
        -> [(Double, Double)] {
        guard case .live = self else { return controlPointPositions }
        // Resolved to nothing (dangling / cyclic): no handles at all is the
        // honest answer — the origin would be a claim about where it is.
        guard let b = resolvedBoundsWith(self, resolver, { $0.bounds }) else { return [] }
        return [(b.x, b.y), (b.x + b.width, b.y),
                (b.x + b.width, b.y + b.height), (b.x, b.y + b.height)]
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
        // PRESERVATION (EDIT_SEMANTICS_FREEZE.md §3.1): a control-point drag
        // speaks to POSITION only, so every same-kind arm below is
        // clone-then-mutate — the Swift counterpart of Rust
        // `move_control_points`' `..e.clone()` / `let mut new = e.clone()`.
        // Field omission is not expressible in that form, which is the point:
        // this switch previously restated each field by hand and the `.path`
        // and `.textPath` arms stopped short of ten and twenty fields
        // respectively while five conforming siblings sat around them.
        // A move must keep the element's stable identity (OP_LOG.md §9 /
        // Fork 4: a journaled `move_selection` resolves `targets` from the
        // moved element's `common.id`) — dropping the id here silently broke
        // the second drag frame's targets and the document's id.
        //
        // The ONE arm that is not clone-then-mutate is Rect's partial-corner
        // case, which changes the element's REPRESENTATION to Polygon (T1's
        // representation term). It forwards every field with a counterpart on
        // Polygon, and its two source-only fields — `rx`/`ry` — have none; see
        // the note there.
        case .line(var v):
            if kind.contains(0) { v.x1 += dx; v.y1 += dy }
            if kind.contains(1) { v.x2 += dx; v.y2 += dy }
            return .line(v)
        case .rect(let v):
            if kind.isAll(total: 4) {
                var n = v
                n.x += dx; n.y += dy
                return .rect(n)
            }
            // Rect -> Polygon. `rx`/`ry` have no counterpart on Polygon and
            // are DISCARDED here: a rounded rect's corners come out square.
            // Rust flattens the rounding into the emitted points instead
            // (`rounded_rect_corner_runs`, ratified answer (3) of
            // EDIT_SEMANTICS_FREEZE.md §8), so the two ports diverge on a
            // ROUNDED rect's corner drag. Closing that needs the corner-run
            // flattener AND the control-point remap that follows it
            // (`remap_cp_selection_after_move`, which the drag pipeline must
            // call between samples) — it is not a change to this arm alone.
            var pts = [(v.x, v.y), (v.x + v.width, v.y),
                       (v.x + v.width, v.y + v.height), (v.x, v.y + v.height)]
            for i in 0..<4 where kind.contains(i) {
                pts[i] = (pts[i].0 + dx, pts[i].1 + dy)
            }
            return .polygon(Polygon(points: pts,
                                       fill: v.fill, stroke: v.stroke,
                                       opacity: v.opacity, transform: v.transform,
                                       locked: v.locked,
                                       visibility: v.visibility, blendMode: v.blendMode,
                                       mask: v.mask, fillGradient: v.fillGradient,
                                       strokeGradient: v.strokeGradient,
                                       name: v.name, id: v.id))
        case .ellipse(let v):
            if kind.isAll(total: 4) {
                var n = v
                n.cx += dx; n.cy += dy
                return .ellipse(n)
            }
            var cps = [(v.cx, v.cy - v.ry), (v.cx + v.rx, v.cy),
                       (v.cx, v.cy + v.ry), (v.cx - v.rx, v.cy)]
            for i in 0..<4 where kind.contains(i) {
                cps[i] = (cps[i].0 + dx, cps[i].1 + dy)
            }
            let ncx = (cps[1].0 + cps[3].0) / 2
            let ncy = (cps[0].1 + cps[2].1) / 2
            var ne = v
            ne.cx = ncx
            ne.cy = ncy
            ne.rx = abs(cps[1].0 - ncx)
            ne.ry = abs(cps[0].1 - ncy)
            return .ellipse(ne)
        case .polygon(var v):
            v.points = v.points.enumerated().map { (i, pt) in
                kind.contains(i) ? (pt.0 + dx, pt.1 + dy) : pt
            }
            return .polygon(v)
        // A polyline's control points are its points, exactly as a polygon's
        // are — the kinds differ only in whether the run closes. This arm was
        // ABSENT in both ports: a polyline fell to `default` and did not move,
        // whole or by control point. Found by the Rust twin of
        // `moveAllEqualsTranslateForEveryKind`, not by a report.
        case .polyline(var v):
            v.points = v.points.enumerated().map { (i, pt) in
                kind.contains(i) ? (pt.0 + dx, pt.1 + dy) : pt
            }
            return .polyline(v)
        case .path(var v):
            v.d = movePathCommandPoints(v.d, kind, dx: dx, dy: dy)
            return .path(v)
        case .textPath(var v):
            v.d = movePathCommandPoints(v.d, kind, dx: dx, dy: dy)
            return .textPath(v)
        case .text:
            // Text resize/move via corner handles. When the whole
            // element is selected (kind=.all, e.g. clicking the
            // body and dragging) translate by (dx, dy). When a
            // single corner is selected, scale the text
            // proportionally about the opposite corner — diagonal
            // distance ratio drives both font-size and origin so
            // the fixed corner stays put.
            if kind.isAll(total: 4) {
                return self.translated(dx: dx, dy: dy)
            }
            guard case .text(let v) = self else { return self }
            let cornerIdx = (0..<4).first(where: { kind.contains($0) })
            guard let ci = cornerIdx else { return self }
            let b = self.bounds
            let corners: [(Double, Double)] = [
                (b.x, b.y), (b.x + b.width, b.y),
                (b.x + b.width, b.y + b.height), (b.x, b.y + b.height)
            ]
            let opp = corners[(ci + 2) % 4]
            let cur = corners[ci]
            let new = (cur.0 + dx, cur.1 + dy)
            let oldDiag = sqrt((cur.0 - opp.0) * (cur.0 - opp.0)
                              + (cur.1 - opp.1) * (cur.1 - opp.1))
            guard oldDiag > 0 else { return self }
            let newDiag = sqrt((new.0 - opp.0) * (new.0 - opp.0)
                              + (new.1 - opp.1) * (new.1 - opp.1))
            let scale = max(0.1, min(50.0, newDiag / oldDiag))
            var nt = v
            nt.x = opp.0 + (v.x - opp.0) * scale
            nt.y = opp.1 + (v.y - opp.1) * scale
            nt.fontSize = v.fontSize * scale
            nt.width = v.width * scale
            nt.height = v.height * scale
            return .text(nt)
        case .live(.reference(let r)) where kind.isAll(total: 0):
            // A reference has no geometry of its own, so a whole-element
            // move (kind=.all) rides on its transform — the only thing
            // to move. The render seam already applies this transform to
            // a reference, so the move is visible without any render
            // change. (A partial / control-point move is meaningless for
            // a reference, so it falls through to the no-op default like
            // Group/Layer/CompoundShape.) Mirrors the Reference arm in
            // Rust `move_control_points`. Note: Swift's ReferenceElem
            // carries a single `transform` field (serialized as
            // `transform`, applied at the render seam), which plays the
            // role of Rust's `common.transform` here.
            var updated = r
            updated.transform = (r.transform ?? .identity).translated(dx, dy)
            return .live(.reference(updated))
        // CONTAINERS AND THE REMAINING LIVE KINDS. A container has no control
        // points of its own, so selecting it selects the whole subtree and
        // moving it moves its members. `translated(dx:dy:)` already does that
        // for every one of these kinds (it is the Align and paste path), so
        // delegate rather than re-derive.
        //
        // Without this, a Group fell to `default: return self` and a group
        // selected as ONE entry DID NOT MOVE — which in JasSwift was every
        // click-and-drag of a group, because the Selection tool sets a
        // one-entry selection (`selection.yaml` `doc.set_selection`) and
        // hit_test returns the GROUP's path for a click inside its child.
        // Rust hid the identical missing arm behind `doc.set_selection`'s
        // container expansion, which LAYER_STRUCTURE.md §20 rules should be
        // removed — so this had to be repaired before that lands.
        // Measured 2026-07-29; twin invariant:
        // `move_all_equals_translate_for_every_kind`.
        case .group, .layer, .live:
            // The predicate is the element's OWN control-point count, not zero.
            // DOCUMENT.md's table grants a Group FOUR bbox-corner control
            // points, so "fully selected" has two valid spellings — `.all`, and
            // `.partial([0,1,2,3])`, which is what a full selection expands to.
            // Guarding on `isAll(total: 0)` accepted only the first, so the
            // second fell through and THE GROUP DID NOT MOVE: the very defect
            // this arm was added to fix, still armed one layer down.
            //
            // A PARTIAL container selection (one corner) is a resize gesture,
            // not a move, and group resize does not exist — it correctly falls
            // through. Twin: `a_container_moves_however_its_full_selection_is_spelled`.
            guard kind.isAll(total: controlPointCount) else { return self }
            return translated(dx: dx, dy: dy)
        default:
            return self
        }
    }

    /// The element's fill, if it has one. Line, Group, and Layer return nil.
    public var fill: Fill? {
        switch self {
        case .line: return nil
        case .rect(let v): return v.fill
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
        case .line(var v): v.locked = locked; return .line(v)
        case .rect(var v): v.locked = locked; return .rect(v)
        case .ellipse(var v): v.locked = locked; return .ellipse(v)
        case .polyline(var v): v.locked = locked; return .polyline(v)
        case .polygon(var v): v.locked = locked; return .polygon(v)
        case .path(var v): v.locked = locked; return .path(v)
        case .text(var v): v.locked = locked; return .text(v)
        case .textPath(var v): v.locked = locked; return .textPath(v)
        case .group(var v): v.locked = locked; return .group(v)
        case .layer(var v): v.locked = locked; return .layer(v)
        case .live(let v): return .live(v.withLocked(locked))
        }
    }

    /// Visibility of this element (does not include any cap inherited
    /// from a parent Group/Layer; use ``Document.effectiveVisibility``
    /// for that).
    public var visibility: Visibility {
        switch self {
        case .line(let v): return v.visibility
        case .rect(let v): return v.visibility
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

    /// The element's opacity (0.0–1.0).
    public var opacity: Double {
        switch self {
        case .line(let v): return v.opacity
        case .rect(let v): return v.opacity
        case .ellipse(let v): return v.opacity
        case .polyline(let v): return v.opacity
        case .polygon(let v): return v.opacity
        case .path(let v): return v.opacity
        case .text(let v): return v.opacity
        case .textPath(let v): return v.opacity
        case .group(let v): return v.opacity
        case .layer(let v): return v.opacity
        case .live(let v): return v.opacity
        }
    }

    /// Optional opacity mask attached to this element. Phase 3a storage-only.
    public var mask: Mask? {
        switch self {
        case .line(let v): return v.mask
        case .rect(let v): return v.mask
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

    /// The element's stable, opaque id, if any. None until assigned.
    /// Mirrors `CommonProps.id` in the reference implementation: the id
    /// names *which* element this is (surviving reorder and edit), where
    /// the tree-path names *where* it sits. Live elements have no flat
    /// id slot yet, so they report nil.
    public var id: String? {
        switch self {
        case .line(let v): return v.id
        case .rect(let v): return v.id
        case .ellipse(let v): return v.id
        case .polyline(let v): return v.id
        case .polygon(let v): return v.id
        case .path(let v): return v.id
        case .text(let v): return v.id
        case .textPath(let v): return v.id
        case .group(let v): return v.id
        case .layer(let v): return v.id
        // Live elements carry their stable id inline on each conformer
        // (CompoundShape.id / ReferenceElem.id), not a flat slot.
        case .live(let v): return v.id
        }
    }

    /// The element's user-visible name (`common.name`), or nil when unnamed.
    /// Used by the Symbols panel to label a master row, with a positional
    /// "Symbol N" fallback computed by the view-builder when this is nil.
    /// Mirrors how Rust reads `common().name` — for EVERY kind, live ones
    /// included: each live conformer carries its name inline, exactly as it
    /// carries its id (see ``LiveVariant/name``). This arm used to return a
    /// hard `nil`, which is why the Layers panel could not label a compound
    /// shape the artist had named.
    public var name: String? {
        switch self {
        case .line(let v): return v.name
        case .rect(let v): return v.name
        case .ellipse(let v): return v.name
        case .polyline(let v): return v.name
        case .polygon(let v): return v.name
        case .path(let v): return v.name
        case .text(let v): return v.name
        case .textPath(let v): return v.name
        case .group(let v): return v.name
        case .layer(let v): return v.name
        // Live elements carry their name inline on each conformer, like
        // their id (see LiveElement.swift).
        case .live(let v): return v.name
        }
    }

    /// Return a copy of this element with its `name` replaced (pass `nil` to
    /// clear). The twin of ``withId(_:)``; `.live` stamps its name inline on
    /// the conformer, so a rename reaches a compound / reference / recorded /
    /// generated element like any other. Mirrors the reference
    /// implementation's `common_mut().name = ...`.
    public func withName(_ name: String?) -> Element {
        // AN EMPTY NAME IS NOT A NAME, for every kind. jas_dioxus's rename
        // commit is `if val.is_empty() { None } else { Some(val) }` and writes
        // `common.name` for any element type (LYR-091), so an unnamed element
        // is one whose name is absent -- which is what drives the `<Type>`
        // fallback label in the Layers tree.
        //
        // This normalized for NOBODY until 2026-07-30, and its `.layer` arm
        // assigned `v.name` directly rather than routing through
        // `Layer.withName`, bypassing the one `normalizedName` the codebase
        // already had. Harmless only because rename was gated to Layers and the
        // layer path called `Layer.withName` itself; opening rename to every
        // kind (council O4) would have made clearing a name store
        // `Optional("")` here and `None` there -- two ports disagreeing about
        // whether an element is NAMED, which the tree label, the bracket
        // fallback and the type filter all read.
        let n = Layer.normalizedName(name)
        switch self {
        case .line(var v): v.name = n; return .line(v)
        case .rect(var v): v.name = n; return .rect(v)
        case .ellipse(var v): v.name = n; return .ellipse(v)
        case .polyline(var v): v.name = n; return .polyline(v)
        case .polygon(var v): v.name = n; return .polygon(v)
        case .path(var v): v.name = n; return .path(v)
        case .text(var v): v.name = n; return .text(v)
        case .textPath(var v): v.name = n; return .textPath(v)
        case .group(var v): v.name = n; return .group(v)
        // Through Layer.withName, so the layer path cannot drift from the
        // normalization it owns.
        case .layer(let v): return .layer(v.withName(n))
        case .live(let v): return .live(v.withName(n))
        }
    }

    /// Return a copy of this element with its stable `id` cleared (set to
    /// nil) on the element itself AND recursively on every descendant.
    ///
    /// A DUPLICATED element must not inherit the source's identity — two
    /// elements cannot share an id (REFERENCE_GRAPH.md §2.5), and a duplicate
    /// that did would be worse than a loud break: a reference to the shared id
    /// silently REBINDS to whichever element the index walk reaches first
    /// (transcripts/EDIT_SEMANTICS_FREEZE.md §3.7). So a copy is born id-less
    /// (lazy) and mints a fresh id only if/when it later becomes a reference
    /// target; `id: nil` is the documented default T3 allows in place of a
    /// mint. Mirrors the reference implementation's `clear_ids`. See the
    /// stable-identity initiative (VISION.md §6.2).
    ///
    /// The walk mirrors ``Document/elementIds``: it descends `children` AND a
    /// compound shape's owned `operands`, which are not `children` at all —
    /// exactly why that walk carries a separate arm for them. It used to stop
    /// at a live element's own inline id, so copying a compound shape cleared
    /// the compound's id and left EVERY OPERAND id duplicated, one level below
    /// the id this helper exists to clear.
    ///
    /// Callers: ``Controller/copySelection(dx:dy:)`` and
    /// ``Controller/detach(_:)``. NOT the clipboard paste path
    /// (`EditClipboard.translateElement` is a field-preserving copy, id
    /// included) — this comment used to claim "every duplication path
    /// (copy/paste/duplicate)", which was never true of paste.
    public func clearingIds() -> Element {
        switch self {
        case .line(let v): return .line(v.withId(nil))
        case .rect(let v): return .rect(v.withId(nil))
        case .ellipse(let v): return .ellipse(v.withId(nil))
        case .polyline(let v): return .polyline(v.withId(nil))
        case .polygon(let v): return .polygon(v.withId(nil))
        case .path(let v): return .path(v.withId(nil))
        case .text(let v): return .text(v.withId(nil))
        case .textPath(let v): return .textPath(v.withId(nil))
        case .group(let v):
            return .group(v.withId(nil).withChildren(v.children.map { $0.clearingIds() }))
        case .layer(let v):
            return .layer(v.withId(nil).withChildren(v.children.map { $0.clearingIds() }))
        case .live(let v):
            // Live elements carry their id inline on each conformer; clear it
            // like any other element. A compound shape ALSO owns its
            // `operands`, which are not `children`, so they must be walked
            // here or they keep the source's ids. The inner switch is
            // exhaustive so a future payload that gains owned children forces
            // this decision to be made again rather than silently going
            // unwalked — the same discipline ``Document/elementIds`` uses.
            let cleared = v.withId(nil)
            switch cleared {
            case .compoundShape(var cs):
                cs.operands = cs.operands.map { $0.clearingIds() }
                return .live(.compoundShape(cs))
            case .reference, .recorded, .generated:
                return .live(cleared)
            }
        }
    }

    /// Return a copy of this element with its stable `id` replaced by
    /// `id` (pass `nil` to clear). Only the element itself is touched —
    /// children of a group/layer keep their own ids, unlike
    /// ``clearingIds()`` which recurses. Mirrors the reference's
    /// `common_mut().id = ...` single-element stamp used by
    /// `Controller.assignId`. `.live` carries its id inline on each
    /// conformer (see ``id``), so it stamps like any other element.
    public func withId(_ id: String?) -> Element {
        switch self {
        case .line(let v): return .line(v.withId(id))
        case .rect(let v): return .rect(v.withId(id))
        case .ellipse(let v): return .ellipse(v.withId(id))
        case .polyline(let v): return .polyline(v.withId(id))
        case .polygon(let v): return .polygon(v.withId(id))
        case .path(let v): return .path(v.withId(id))
        case .text(let v): return .text(v.withId(id))
        case .textPath(let v): return .textPath(v.withId(id))
        case .group(let v): return .group(v.withId(id))
        case .layer(let v): return .layer(v.withId(id))
        // Live elements carry their id inline on each conformer; stamp it
        // so `Controller.assignId` works over a compound / reference.
        case .live(let v): return .live(v.withId(id))
        }
    }

    /// Return a copy of this element with its `visibility` replaced.
    public func withVisibility(_ visibility: Visibility) -> Element {
        switch self {
        case .line(var v): v.visibility = visibility; return .line(v)
        case .rect(var v): v.visibility = visibility; return .rect(v)
        case .ellipse(var v): v.visibility = visibility; return .ellipse(v)
        case .polyline(var v): v.visibility = visibility; return .polyline(v)
        case .polygon(var v): v.visibility = visibility; return .polygon(v)
        case .path(var v): v.visibility = visibility; return .path(v)
        case .text(var v): v.visibility = visibility; return .text(v)
        case .textPath(var v): v.visibility = visibility; return .textPath(v)
        case .group(var v): v.visibility = visibility; return .group(v)
        case .layer(var v): v.visibility = visibility; return .layer(v)
        case .live(let v): return .live(v.withVisibility(visibility))
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

    /// Translate every coordinate in a path-command list by (dx, dy).
    /// ArcTo's `rx`/`ry`/rotation/flags pass through — only the
    /// endpoint moves. Used internally by `Element.translated`.
    fileprivate func translatePathCommands(
        _ d: [PathCommand], dx: Double, dy: Double
    ) -> [PathCommand] {
        d.map { cmd in
            switch cmd {
            case .moveTo(let x, let y): return .moveTo(x + dx, y + dy)
            case .lineTo(let x, let y): return .lineTo(x + dx, y + dy)
            case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
                return .curveTo(x1: x1 + dx, y1: y1 + dy,
                                x2: x2 + dx, y2: y2 + dy,
                                x: x + dx, y: y + dy)
            case .smoothCurveTo(let x2, let y2, let x, let y):
                return .smoothCurveTo(x2: x2 + dx, y2: y2 + dy,
                                       x: x + dx, y: y + dy)
            case .quadTo(let x1, let y1, let x, let y):
                return .quadTo(x1: x1 + dx, y1: y1 + dy,
                                x: x + dx, y: y + dy)
            case .smoothQuadTo(let x, let y): return .smoothQuadTo(x + dx, y + dy)
            case .arcTo(let rx, let ry, let rot, let la, let sw, let x, let y):
                return .arcTo(rx: rx, ry: ry, rotation: rot,
                              largeArc: la, sweep: sw,
                              x: x + dx, y: y + dy)
            case .closePath: return .closePath
            }
        }
    }

    /// Return a copy of this element translated by (dx, dy) — baked
    /// into the element's raw coordinates rather than its transform.
    /// Required wherever a translation needs to keep `bounds` /
    /// hit-test in lockstep with the visual position; the Align panel
    /// is the canonical caller. Stuffing the offset into the
    /// transform field instead is what makes a second click on
    /// align_left double the offset (per ALIGN.md §Translation
    /// semantics, mirrored from `translate_element` in
    /// `jas_dioxus/src/geometry/element.rs`).
    /// Apply a per-element rewrite to every PAINTABLE element a selection entry
    /// reaches: the element itself when it is a leaf, or every leaf beneath it
    /// when it is a container, at any depth.
    ///
    /// RULED 2026-07-29 (JYH at council: *"yes, recurse into members"*).
    /// Selecting a group and clicking a swatch is the commonest operation in the
    /// application and it did NOTHING — `withFill` and its siblings return a
    /// container unchanged, which is right for the data model (a group carries
    /// no fill of its own) and wrong for the artist's intent. Rust hid it behind
    /// `doc.set_selection`'s container expansion; JasSwift, which does not
    /// expand, was simply broken.
    ///
    /// **The recursion lives HERE and not inside `withFill`/`withStroke`.**
    /// Those are also called at render time (stroke scaling) and on
    /// symbol-instance overrides, where recursing would be wrong or wasteful.
    /// Only "apply this to the selection" wants the walk.
    ///
    /// Containers are rebuilt through `withChildren`, never by re-listing their
    /// fields — that is the Swift copy-site omission class, and re-listing here
    /// would silently drop a container's `id`, `mask` and blending flags on
    /// every swatch click. Twin: Rust `map_paintable`.
    ///
    /// NOTE: this does NOT skip locked descendants. Lock enforcement is §15's
    /// job and is not built yet; no other selection operation respects it
    /// either, and a lone exception here would be an inconsistency rather than
    /// a protection.
    /// Visit every PAINTABLE element a selection entry reaches: the element
    /// itself when it is a leaf, or every leaf beneath it when it is a
    /// container. The READ twin of `mapPaintable`.
    ///
    /// The panels summarise a selection through `selectionFillSummary` /
    /// `selectionStrokeSummary`, which SKIPPED containers — so a selected group
    /// summarised to `.noSelection`, "nothing is selected", while Rust's twin
    /// said `Uniform(None)`, "this has no stroke". Both wrong, and wrong in
    /// different directions. An empty container visits nothing and so
    /// contributes no value.
    public func forEachPaintable(_ f: (Element) -> Void) {
        switch self {
        case .group(let g): g.children.forEach { $0.forEachPaintable(f) }
        case .layer(let l): l.children.forEach { $0.forEachPaintable(f) }
        default: f(self)
        }
    }

    public func mapPaintable(_ f: (Element) -> Element) -> Element {
        switch self {
        case .group(let g):
            return .group(g.withChildren(g.children.map { $0.mapPaintable(f) }))
        case .layer(let l):
            return .layer(l.withChildren(l.children.map { $0.mapPaintable(f) }))
        default:
            return f(self)
        }
    }

    public func translated(dx: Double, dy: Double) -> Element {
        // PRESERVATION (EDIT_SEMANTICS_FREEZE.md §3.1): a translation speaks
        // to POSITION only, so every arm is clone-then-mutate — the Swift
        // counterpart of Rust `translate_element`'s `..e.clone()`. These arms
        // were open-coded rebuilds and three of them stopped short: `.path`
        // dropped `strokeBrush` / `strokeBrushOverrides` / `toolOrigin`, so
        // an Align-panel nudge stripped a brushed stroke; `.text` and
        // `.textPath` each dropped all ELEVEN character-panel fields
        // (letterSpacing, lineHeight, kerning, …), so nudging styled type
        // reset its typography.
        switch self {
        case .line(var v):
            v.x1 += dx; v.y1 += dy
            v.x2 += dx; v.y2 += dy
            return .line(v)
        case .rect(var v):
            v.x += dx; v.y += dy
            return .rect(v)
        case .ellipse(var v):
            v.cx += dx; v.cy += dy
            return .ellipse(v)
        case .polyline(var v):
            v.points = v.points.map { ($0.0 + dx, $0.1 + dy) }
            return .polyline(v)
        case .polygon(var v):
            v.points = v.points.map { ($0.0 + dx, $0.1 + dy) }
            return .polygon(v)
        case .path(var v):
            v.d = translatePathCommands(v.d, dx: dx, dy: dy)
            return .path(v)
        case .text(var v):
            v.x += dx; v.y += dy
            return .text(v)
        case .textPath(var v):
            v.d = translatePathCommands(v.d, dx: dx, dy: dy)
            return .textPath(v)
        case .group(var v):
            v.children = v.children.map { $0.translated(dx: dx, dy: dy) }
            return .group(v)
        case .layer(var v):
            v.children = v.children.map { $0.translated(dx: dx, dy: dy) }
            return .layer(v)
        case .live(.reference(let r)):
            // A reference has no geometry of its own to translate; its
            // move rides on its transform (the live render seam applies
            // it). Mirrors the Reference arm in `moveControlPoints` and
            // Rust `translate_element`. (Used by paste / copy / group
            // paths.) Swift's ReferenceElem carries a single `transform`
            // field that plays the role of Rust's `common.transform`.
            var updated = r
            updated.transform = (r.transform ?? .identity).translated(dx, dy)
            return .live(.reference(updated))
        case .live(.compoundShape(let cs)):
            // A compound shape bakes a translation by recursing into its
            // operands (raw-coord bake), NOT by setting its transform — so the
            // saved document keeps no residual transform and the re-evaluated
            // boolean result moves with its operands. Mirrors Rust / Python /
            // OCaml `translate_element`. (Align DOES reach this branch when a
            // compound shape is in the selection — the earlier "unreachable"
            // note was wrong and diverged from the other three apps.)
            var updated = cs
            updated.operands = cs.operands.map { $0.translated(dx: dx, dy: dy) }
            return .live(.compoundShape(updated))
        case .live:
            // Recorded / Generated live elements have no raw coordinates to
            // bake into, so their move rides on the transform (like the
            // Reference arm above). Mirrors Rust's Recorded / Generated arms.
            return self.withTransformTranslated(dx: dx, dy: dy)
        }
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

    /// Internal: replace the element's transform with `t`, preserving EVERY
    /// other field (name, id, blendMode, mask, gradients, brush bindings,
    /// per-element extras). Shared by `withTransformTranslated` and
    /// `withTransformPremultiplied`. Preserving the full common block is required
    /// for cross-language equivalence (OP_LOG.md §9 Phase P7): a transform must
    /// not silently drop the element's `id`/`name`/blend/mask — earlier this
    /// helper rebuilt each variant with only geometry+stroke+opacity, dropping
    /// the rest, which diverged from Rust's `transform.unwrap_or_default()`
    /// compose that mutates the common block in place.
    ///
    /// It is now clone-then-mutate, so "preserving EVERY other field" is a
    /// property of the FORM rather than of a list a reader has to check. The
    /// full-field rebuild it replaced was enumerated as complete — but it was
    /// the same shape as five arms that were not, and no battery watched it.
    /// `TransformAndStrokeTheseusTests.swift` watches it now.
    private func withTransformSet(_ t: Transform) -> Element {
        switch self {
        case .line(var v): v.transform = t; return .line(v)
        case .rect(var v): v.transform = t; return .rect(v)
        case .ellipse(var v): v.transform = t; return .ellipse(v)
        case .polyline(var v): v.transform = t; return .polyline(v)
        case .polygon(var v): v.transform = t; return .polygon(v)
        case .path(var v): v.transform = t; return .path(v)
        case .text(var v): v.transform = t; return .text(v)
        case .textPath(var v): v.transform = t; return .textPath(v)
        case .group(var v): v.transform = t; return .group(v)
        case .layer(var v): v.transform = t; return .layer(v)
        case .live(let v):
            return .live(v.withTransform(t))
        }
    }

    /// Return a copy with any of `transform` / `opacity` / `blendMode`
    /// replaced (nil = keep), preserving every other field. Used by the
    /// Properties panel edit apply (decision-5 Part B.2). Generalizes
    /// `withTransformSet` to the two other common-block scalars.
    func withCommon(transform: Transform? = nil, opacity: Double? = nil,
                    blendMode: BlendMode? = nil) -> Element {
        // Clone-then-mutate at every arm (EDIT_SEMANTICS_FREEZE.md §3.1): the
        // three writes are stated once per kind and the other thirty-odd
        // fields are carried by the copy rather than by a hand-kept list.
        switch self {
        case .line(var v):
            v.opacity = opacity ?? v.opacity
            v.transform = transform ?? v.transform
            v.blendMode = blendMode ?? v.blendMode
            return .line(v)
        case .rect(var v):
            v.opacity = opacity ?? v.opacity
            v.transform = transform ?? v.transform
            v.blendMode = blendMode ?? v.blendMode
            return .rect(v)
        case .ellipse(var v):
            v.opacity = opacity ?? v.opacity
            v.transform = transform ?? v.transform
            v.blendMode = blendMode ?? v.blendMode
            return .ellipse(v)
        case .polyline(var v):
            v.opacity = opacity ?? v.opacity
            v.transform = transform ?? v.transform
            v.blendMode = blendMode ?? v.blendMode
            return .polyline(v)
        case .polygon(var v):
            v.opacity = opacity ?? v.opacity
            v.transform = transform ?? v.transform
            v.blendMode = blendMode ?? v.blendMode
            return .polygon(v)
        case .path(var v):
            v.opacity = opacity ?? v.opacity
            v.transform = transform ?? v.transform
            v.blendMode = blendMode ?? v.blendMode
            return .path(v)
        case .text(var v):
            v.opacity = opacity ?? v.opacity
            v.transform = transform ?? v.transform
            v.blendMode = blendMode ?? v.blendMode
            return .text(v)
        case .textPath(var v):
            v.opacity = opacity ?? v.opacity
            v.transform = transform ?? v.transform
            v.blendMode = blendMode ?? v.blendMode
            return .textPath(v)
        case .group(var v):
            v.opacity = opacity ?? v.opacity
            v.transform = transform ?? v.transform
            v.blendMode = blendMode ?? v.blendMode
            return .group(v)
        case .layer(var v):
            v.opacity = opacity ?? v.opacity
            v.transform = transform ?? v.transform
            v.blendMode = blendMode ?? v.blendMode
            return .layer(v)
        case .live(var v):
            // All three are settable on a Live element — every conformer
            // STORES `opacity` and `blendMode`, and jas_dioxus writes them
            // through `common_mut()` at the Properties-panel apply. This arm
            // used to discard both (`_ = (opacity, blendMode)`, "no
            // LiveElement setter"), which made an Opacity or Blend Mode edit
            // over a selected compound shape a SILENT NO-OP in this port
            // alone. `nil` still means keep, exactly as on the other arms.
            if let o = opacity { v = v.withOpacity(o) }
            if let b = blendMode { v = v.withBlendMode(b) }
            if let t = transform { v = v.withTransform(t) }
            return .live(v)
        }
    }
}

// MARK: - Fill / Stroke replacement helpers

/// Return a copy of `element` with the fill replaced. Line has no fill
/// (returned unchanged). Group and Layer have no fill (returned unchanged).
/// Return a copy of the element with its `fillGradient` replaced.
/// Elements that do not support a fill gradient (Line, Text, TextPath,
/// Group, Layer, Live) are returned unchanged.
///
/// EDIT_SEMANTICS_FREEZE.md §3.1: this is a 1→1 edit that speaks to
/// `fillGradient` and nothing else, so every other field survives — `name`,
/// `id`, `toolOrigin`, `strokeBrush`, `strokeBrushOverrides` included. The
/// clone-then-mutate form is what makes that true structurally rather than by
/// hand-audit; the open-coded rebuild it replaced passed no `name:`/`id:` at
/// ANY arm and additionally dropped the Path's brush and tool-origin fields,
/// so setting a gradient from the Gradient panel destroyed the identity that
/// references, symbols and the ledger are keyed on. Rust's twin
/// (`RectElem { fill_gradient: gradient, ..e.clone() }`) always conformed.
public func withFillGradient(_ element: Element, fillGradient: Gradient?) -> Element {
    switch element {
    case .rect(var v): v.fillGradient = fillGradient; return .rect(v)
    case .ellipse(var v): v.fillGradient = fillGradient; return .ellipse(v)
    case .polyline(var v): v.fillGradient = fillGradient; return .polyline(v)
    case .polygon(var v): v.fillGradient = fillGradient; return .polygon(v)
    case .path(var v): v.fillGradient = fillGradient; return .path(v)
    default:
        return element
    }
}

/// Return a copy of the element with its `strokeGradient` replaced.
/// Elements that do not support a stroke gradient (Text, TextPath, Group,
/// Layer, Live) are returned unchanged.
///
/// Same clause, same class, same repair as ``withFillGradient(_:strokeGradient:)``
/// — see its note. Rust's twin is `..e.clone()` at every arm.
public func withStrokeGradient(_ element: Element, strokeGradient: Gradient?) -> Element {
    switch element {
    case .line(var v): v.strokeGradient = strokeGradient; return .line(v)
    case .rect(var v): v.strokeGradient = strokeGradient; return .rect(v)
    case .ellipse(var v): v.strokeGradient = strokeGradient; return .ellipse(v)
    case .polyline(var v): v.strokeGradient = strokeGradient; return .polyline(v)
    case .polygon(var v): v.strokeGradient = strokeGradient; return .polygon(v)
    case .path(var v): v.strokeGradient = strokeGradient; return .path(v)
    default:
        return element
    }
}

/// EDIT_SEMANTICS_FREEZE.md §3.1 + T1's SHADOWING-FAMILY closure. This edit
/// speaks to the fill family — `fill` AND the `fillGradient` that shadows it on
/// the render chain — and to nothing else: `name`, `id`, `mask`, `blendMode`,
/// `strokeGradient`, `strokeBrush`, `strokeBrushOverrides`, `toolOrigin` and a
/// text element's tspan RUN STRUCTURE all survive.
///
/// The open-coded rebuild this replaced stopped at `visibility:` and dropped
/// every one of them, so a Colour-panel fill on a named, cited, masked,
/// brush-stroked path destroyed its identity, and on a Text it collapsed every
/// run into one (it routed through the `content:` convenience initializer).
///
/// NAMED CROSS-PORT DELTA: Rust's `with_fill` is
/// `RectElem { fill, ..e.clone() }`, which CARRIES `fill_gradient` — so there a
/// colour pick leaves the gradient shadowing the new colour, and here it
/// clears it. This port's answer is unchanged by this repair (it always
/// cleared) and is the one T1's closure states; which port is right is the
/// §3.6 gradients-as-paint AMENDMENT, a ruling that must land in both ports at
/// once. Not guessed here.
public func withFill(_ element: Element, fill: Fill?) -> Element {
    switch element {
    case .line:
        return element
    case .rect(var v): v.fill = fill; v.fillGradient = nil; return .rect(v)
    case .ellipse(var v): v.fill = fill; v.fillGradient = nil; return .ellipse(v)
    case .polyline(var v): v.fill = fill; v.fillGradient = nil; return .polyline(v)
    case .polygon(var v): v.fill = fill; v.fillGradient = nil; return .polygon(v)
    case .path(var v): v.fill = fill; v.fillGradient = nil; return .path(v)
    // Text and TextPath carry no gradient in this port, so the fill family is
    // `fill` alone there.
    case .text(var v): v.fill = fill; return .text(v)
    case .textPath(var v): v.fill = fill; return .textPath(v)
    case .group, .layer:
        return element
    case .live(let v):
        return .live(v.withFill(fill))
    }
}

/// Return a copy of `element` with the stroke replaced. Group and Layer
/// have no stroke (returned unchanged).
public func withStroke(_ element: Element, stroke: Stroke?) -> Element {
    // Clone-then-mutate at every arm (EDIT_SEMANTICS_FREEZE.md §3.1): this
    // speaks to `stroke` and nothing else, and the copy carries the rest.
    switch element {
    case .line(var v): v.stroke = stroke; return .line(v)
    case .rect(var v): v.stroke = stroke; return .rect(v)
    case .ellipse(var v): v.stroke = stroke; return .ellipse(v)
    case .polyline(var v): v.stroke = stroke; return .polyline(v)
    case .polygon(var v): v.stroke = stroke; return .polygon(v)
    case .path(var v): v.stroke = stroke; return .path(v)
    case .text(var v): v.stroke = stroke; return .text(v)
    case .textPath(var v): v.stroke = stroke; return .textPath(v)
    case .group, .layer:
        return element
    case .live(let v):
        return .live(v.withStroke(stroke))
    }
}

/// Promote a Line (or open Polyline) to a geometry-identical Path so it can
/// carry Path-only attributes such as `strokeBrush`. Mirrors the Rect→Polygon
/// corner-drag promotion (the "upgrade naturally" convention ratified by JYH
/// 2026-07-25): identity is preserved (the caller replaces the element in
/// place at its tree path), the common props (name, id, opacity, transform,
/// visibility, lock, mask, blend mode) carry WHOLE, and stroke + width profile
/// carry whole too. A Line has no fill, so the Path fill is nil; a Polyline's
/// fill and gradients carry across. Non-promotable elements (including a
/// degenerate Polyline with fewer than two points) return unchanged. See
/// BRUSHES.md §Stroke styling interaction.
public func promoteToPathForBrush(_ element: Element) -> Element {
    switch element {
    case .line(let v):
        return .path(Path(d: [.moveTo(v.x1, v.y1), .lineTo(v.x2, v.y2)],
                          fill: nil, stroke: v.stroke, widthPoints: v.widthPoints,
                          opacity: v.opacity, transform: v.transform,
                          locked: v.locked, visibility: v.visibility,
                          blendMode: v.blendMode, mask: v.mask,
                          fillGradient: nil, strokeGradient: v.strokeGradient,
                          strokeBrush: nil, strokeBrushOverrides: nil,
                          toolOrigin: nil, name: v.name, id: v.id,
                          // A Line is one open subpath and carries no rule.
                          fillRule: .nonzero))
    case .polyline(let v) where v.points.count >= 2:
        var d: [PathCommand] = [.moveTo(v.points[0].0, v.points[0].1)]
        for p in v.points[1...] { d.append(.lineTo(p.0, p.1)) }
        return .path(Path(d: d, fill: v.fill, stroke: v.stroke, widthPoints: [],
                          opacity: v.opacity, transform: v.transform,
                          locked: v.locked, visibility: v.visibility,
                          blendMode: v.blendMode, mask: v.mask,
                          fillGradient: v.fillGradient, strokeGradient: v.strokeGradient,
                          strokeBrush: nil, strokeBrushOverrides: nil,
                          toolOrigin: nil, name: v.name, id: v.id,
                          // A Polyline is one subpath and carries no rule.
                          fillRule: .nonzero))
    default:
        return element
    }
}

/// Return a copy of the element with strokeBrush replaced.
/// A Path carries the brush directly. Applying a brush (a non-nil slug) to a
/// Line or open Polyline PROMOTES it to a geometry-identical Path that then
/// carries the brush — the "upgrade naturally" convention (JYH 2026-07-25);
/// see `promoteToPathForBrush`. Clearing (nil) is not a brush application, so
/// it never promotes. Other elements are returned unchanged. See BRUSHES.md
/// §Stroke styling interaction.
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
                          strokeBrushOverrides: v.strokeBrushOverrides,
                          toolOrigin: v.toolOrigin, name: v.name, id: v.id, fillRule: v.fillRule))
    case .line, .polyline:
        guard strokeBrush != nil,
              case .path(let p) = promoteToPathForBrush(element) else { return element }
        return .path(Path(d: p.d, fill: p.fill, stroke: p.stroke,
                          widthPoints: p.widthPoints,
                          opacity: p.opacity, transform: p.transform,
                          locked: p.locked, visibility: p.visibility,
                          blendMode: p.blendMode, mask: p.mask,
                          fillGradient: p.fillGradient,
                          strokeGradient: p.strokeGradient,
                          strokeBrush: strokeBrush,
                          strokeBrushOverrides: p.strokeBrushOverrides,
                          toolOrigin: p.toolOrigin, name: p.name, id: p.id, fillRule: p.fillRule))
    default:
        return element
    }
}

/// Return a copy of the element with strokeBrushOverrides replaced.
/// A Path carries it directly; a Line / open Polyline is promoted to a Path
/// first when the value is non-nil (mirrors `withStrokeBrush`). Clearing (nil)
/// never promotes.
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
                          strokeBrushOverrides: overrides,
                          toolOrigin: v.toolOrigin, name: v.name, id: v.id, fillRule: v.fillRule))
    case .line, .polyline:
        guard overrides != nil,
              case .path(let p) = promoteToPathForBrush(element) else { return element }
        return .path(Path(d: p.d, fill: p.fill, stroke: p.stroke,
                          widthPoints: p.widthPoints,
                          opacity: p.opacity, transform: p.transform,
                          locked: p.locked, visibility: p.visibility,
                          blendMode: p.blendMode, mask: p.mask,
                          fillGradient: p.fillGradient,
                          strokeGradient: p.strokeGradient,
                          strokeBrush: p.strokeBrush,
                          strokeBrushOverrides: overrides,
                          toolOrigin: p.toolOrigin, name: p.name, id: p.id, fillRule: p.fillRule))
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
    case .line(var v): v.mask = mask; return .line(v)
    case .rect(var v): v.mask = mask; return .rect(v)
    case .ellipse(var v): v.mask = mask; return .ellipse(v)
    case .polyline(var v): v.mask = mask; return .polyline(v)
    case .polygon(var v): v.mask = mask; return .polygon(v)
    case .path(var v): v.mask = mask; return .path(v)
    case .text(var v): v.mask = mask; return .text(v)
    case .textPath(var v): v.mask = mask; return .textPath(v)
    case .group(var v): v.mask = mask; return .group(v)
    case .layer(var v): v.mask = mask; return .layer(v)
    case .live(let v): return .live(v.withMask(mask))
    }
}

/// Return a copy of `element` with the Opacity panel's two page-level
/// blending flags replaced. Only Group and Layer carry them; every other kind
/// is returned unchanged, exactly as `withWidthPoints` leaves the ten kinds
/// that have no width profile alone.
///
/// CLONE-THEN-MUTATE, deliberately (`var v = element; v.field = ...`). The
/// alternative — rebuilding `Group(children:…)` / `Layer(name:…)` with the two
/// flags added to the argument list — is the Swift copy-site omission class
/// that has been found five times in this repository: it creates a site whose
/// correctness is a list somebody has to keep current. Here every field except
/// the two named is preserved structurally.
public func withContainerBlendFlags(_ element: Element,
                                    isolatedBlending: Bool,
                                    knockoutGroup: Bool) -> Element {
    switch element {
    case .group(var v):
        v.isolatedBlending = isolatedBlending
        v.knockoutGroup = knockoutGroup
        return .group(v)
    case .layer(var v):
        v.isolatedBlending = isolatedBlending
        v.knockoutGroup = knockoutGroup
        return .layer(v)
    default:
        return element
    }
}

/// The Opacity panel's two page-level blending flags, or `(false, false)` for
/// a kind that cannot carry them. The read half of
/// ``withContainerBlendFlags(_:isolatedBlending:knockoutGroup:)``; both codecs
/// that write the flags go through it so neither has to re-derive which kinds
/// have them.
public func containerBlendFlags(_ element: Element) -> (isolatedBlending: Bool, knockoutGroup: Bool) {
    switch element {
    case .group(let v): return (v.isolatedBlending, v.knockoutGroup)
    case .layer(let v): return (v.isolatedBlending, v.knockoutGroup)
    default: return (false, false)
    }
}

/// Return a copy of `element` with width points replaced.
/// Only Line and Path support width points; others returned unchanged.
public func withWidthPoints(_ element: Element, widthPoints: [StrokeWidthPoint]) -> Element {
    switch element {
    case .line(var v): v.widthPoints = widthPoints; return .line(v)
    case .path(var v): v.widthPoints = widthPoints; return .path(v)
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
    public internal(set) var x1: Double, y1: Double, x2: Double, y2: Double
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public internal(set) var name: String?
    /// Stable, opaque element identity. Additive: None means the element
    /// has no id yet, so every existing document remains valid. Where the
    /// tree-path encodes *where* an element sits, the id names *which*
    /// element it is, surviving reorder and edit. Round-trips through
    /// test_json (emitted only when set, so id-less elements stay
    /// byte-identical) and, in a later increment, the SVG `id` attribute.
    public internal(set) var id: String?
    public internal(set) var stroke: Stroke?
    public internal(set) var widthPoints: [StrokeWidthPoint]
    public internal(set) var opacity: Double
    public internal(set) var transform: Transform?
    public internal(set) var locked: Bool
    public internal(set) var visibility: Visibility
    public internal(set) var blendMode: BlendMode
    public internal(set) var mask: Mask?
    /// Optional gradient applied to the stroke (in lieu of `stroke.color`).
    /// Phase 1b adds gradient paint per-element. See GRADIENT.md
    /// §Document model.
    public internal(set) var strokeGradient: Gradient?

    public init(x1: Double, y1: Double, x2: Double, y2: Double,
                stroke: Stroke? = nil, widthPoints: [StrokeWidthPoint] = [],
                opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                mask: Mask? = nil,
                strokeGradient: Gradient? = nil,
                name: String? = nil,
                id: String? = nil) {
        self.name = name
        self.id = id
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
    public internal(set) var x: Double, y: Double, width: Double, height: Double
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public internal(set) var name: String?
    /// Stable, opaque element identity. Additive: None = no id yet, so
    /// every existing document remains valid. See `Line.id`.
    public internal(set) var id: String?
    public internal(set) var rx: Double, ry: Double
    public internal(set) var fill: Fill?
    public internal(set) var stroke: Stroke?
    public internal(set) var opacity: Double
    public internal(set) var transform: Transform?
    public internal(set) var locked: Bool
    public internal(set) var visibility: Visibility
    public internal(set) var blendMode: BlendMode
    public internal(set) var mask: Mask?
    public internal(set) var fillGradient: Gradient?
    public internal(set) var strokeGradient: Gradient?

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
                name: String? = nil,
                id: String? = nil) {
        self.name = name
        self.id = id
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
/// SVG \<ellipse\> element.
public struct Ellipse: Equatable {
    public internal(set) var cx: Double, cy: Double, rx: Double, ry: Double
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public internal(set) var name: String?
    /// Stable, opaque element identity. Additive: None = no id yet, so
    /// every existing document remains valid. See `Line.id`.
    public internal(set) var id: String?
    public internal(set) var fill: Fill?
    public internal(set) var stroke: Stroke?
    public internal(set) var opacity: Double
    public internal(set) var transform: Transform?
    public internal(set) var locked: Bool
    public internal(set) var visibility: Visibility
    public internal(set) var blendMode: BlendMode
    public internal(set) var mask: Mask?
    public internal(set) var fillGradient: Gradient?
    public internal(set) var strokeGradient: Gradient?

    public init(cx: Double, cy: Double, rx: Double, ry: Double,
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                mask: Mask? = nil,
                fillGradient: Gradient? = nil,
                strokeGradient: Gradient? = nil,
                name: String? = nil,
                id: String? = nil) {
        self.name = name
        self.id = id
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
    public internal(set) var points: [(Double, Double)]
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public internal(set) var name: String?
    /// Stable, opaque element identity. Additive: None = no id yet, so
    /// every existing document remains valid. See `Line.id`.
    public internal(set) var id: String?
    public internal(set) var fill: Fill?
    public internal(set) var stroke: Stroke?
    public internal(set) var opacity: Double
    public internal(set) var transform: Transform?
    public internal(set) var locked: Bool
    public internal(set) var visibility: Visibility
    public internal(set) var blendMode: BlendMode
    public internal(set) var mask: Mask?
    public internal(set) var fillGradient: Gradient?
    public internal(set) var strokeGradient: Gradient?

    public init(points: [(Double, Double)],
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                mask: Mask? = nil,
                fillGradient: Gradient? = nil,
                strokeGradient: Gradient? = nil,
                name: String? = nil,
                id: String? = nil) {
        self.name = name
        self.id = id
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
    public internal(set) var points: [(Double, Double)]
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public internal(set) var name: String?
    /// Stable, opaque element identity. Additive: None = no id yet, so
    /// every existing document remains valid. See `Line.id`.
    public internal(set) var id: String?
    public internal(set) var fill: Fill?
    public internal(set) var stroke: Stroke?
    public internal(set) var opacity: Double
    public internal(set) var transform: Transform?
    public internal(set) var locked: Bool
    public internal(set) var visibility: Visibility
    public internal(set) var blendMode: BlendMode
    public internal(set) var mask: Mask?
    public internal(set) var fillGradient: Gradient?
    public internal(set) var strokeGradient: Gradient?

    public init(points: [(Double, Double)],
                fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                mask: Mask? = nil,
                fillGradient: Gradient? = nil,
                strokeGradient: Gradient? = nil,
                name: String? = nil,
                id: String? = nil) {
        self.name = name
        self.id = id
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

/// Candidate (x, y) extrema for an SVG arc: the two endpoints plus any
/// cardinal-tangent points of the underlying ellipse that fall within the
/// arc's actual sweep range. Fixes the "ArcTo bbox skips the peak" gap.
/// Degenerate arcs (zero radius) collapse to the endpoint pair. SVG 1.1
/// §F.6 endpoint-to-center parameterization. Mirrors the Rust reference
/// (jas_dioxus geometry/element.rs arcExtremaPoints) so path bounds are
/// byte-equivalent across apps, gated by the element_bounds corpus.
private func arcExtremaPoints(
    _ x0: Double, _ y0: Double,
    _ rx: Double, _ ry: Double, _ xRotationDeg: Double,
    _ largeArc: Bool, _ sweep: Bool,
    _ x: Double, _ y: Double
) -> [(Double, Double)] {
    if abs(rx) < 1e-12 || abs(ry) < 1e-12 {
        return [(x0, y0), (x, y)]
    }
    let twoPi = 2.0 * Double.pi
    let phi = xRotationDeg * (Double.pi / 180)
    let cosPhi = cos(phi), sinPhi = sin(phi)

    let dx = (x0 - x) / 2.0, dy = (y0 - y) / 2.0
    let x1p = cosPhi * dx + sinPhi * dy
    let y1p = -sinPhi * dx + cosPhi * dy
    var rxEff = abs(rx), ryEff = abs(ry)
    let lambda = (x1p * x1p) / (rxEff * rxEff) + (y1p * y1p) / (ryEff * ryEff)
    if lambda > 1.0 {
        let s = lambda.squareRoot()
        rxEff *= s
        ryEff *= s
    }
    let sign = (largeArc == sweep) ? -1.0 : 1.0
    let num = Swift.max(
        rxEff * rxEff * ryEff * ryEff
        - rxEff * rxEff * y1p * y1p
        - ryEff * ryEff * x1p * x1p,
        0.0)
    let den = rxEff * rxEff * y1p * y1p + ryEff * ryEff * x1p * x1p
    let factor = den < 1e-12 ? 0.0 : sign * (num / den).squareRoot()
    let cxp = factor * (rxEff * y1p) / ryEff
    let cyp = -factor * (ryEff * x1p) / rxEff
    let cxArc = cosPhi * cxp - sinPhi * cyp + (x0 + x) / 2.0
    let cyArc = sinPhi * cxp + cosPhi * cyp + (y0 + y) / 2.0

    let theta1 = atan2((y1p - cyp) / ryEff, (x1p - cxp) / rxEff)
    let theta2 = atan2((-y1p - cyp) / ryEff, (-x1p - cxp) / rxEff)
    var delta = theta2 - theta1
    if !sweep && delta > 0.0 { delta -= twoPi }
    else if sweep && delta < 0.0 { delta += twoPi }

    let tx = atan2(-ryEff * sinPhi, rxEff * cosPhi)
    let ty = atan2(ryEff * cosPhi, rxEff * sinPhi)
    let candidates = [tx, tx + Double.pi, ty, ty + Double.pi]

    func inSweep(_ t: Double) -> Bool {
        var dt = t - theta1
        if delta >= 0.0 {
            while dt < 0.0 { dt += twoPi }
            while dt > twoPi { dt -= twoPi }
            return dt <= delta + 1e-9
        } else {
            while dt > 0.0 { dt -= twoPi }
            while dt < -twoPi { dt += twoPi }
            return dt >= delta - 1e-9
        }
    }

    var points: [(Double, Double)] = [(x0, y0), (x, y)]
    for t in candidates where inSweep(t) {
        let px = cxArc + rxEff * cosPhi * cos(t) - ryEff * sinPhi * sin(t)
        let py = cyArc + rxEff * sinPhi * cos(t) + ryEff * cosPhi * sin(t)
        points.append((px, py))
    }
    return points
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
        case .arcTo(let rx, let ry, let rot, let la, let sw, let x, let y):
            for (px, py) in arcExtremaPoints(cx, cy, rx, ry, rot, la, sw, x, y) {
                xs.append(px); ys.append(py)
            }
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

/// SVG-style fill rule. Determines how a multi-subpath shape is filled.
/// Defaults to `.nonzero` (the SVG default).
///
/// This is the DOCUMENT-SIDE half of the carried-rule law
/// (transcripts/BOOLEAN.md, "Fill rule: the polygon set carries it"):
/// what the artist or the imported file declared. The algorithm-side
/// half is `BoolFillRule`, and the initializers below are the only
/// bridge between them — a boolean operand must carry this value
/// across, never assume one. Boolean RESULTS are stamped with
/// `boolResultFillRule`, which is even-odd, so that a generated
/// multi-ring compound shape shows its holes instead of filling them.
///
/// Additive: absent from a document means `.nonzero`, so every
/// existing file stays valid. Twin of Rust's
/// `geometry::element::FillRule`.
public enum FillRule: String, Equatable {
    case nonzero
    case evenodd
}

extension FillRule {
    /// The document rule an algorithm-layer rule denotes.
    public init(_ r: BoolFillRule) {
        switch r {
        case .nonzero: self = .nonzero
        case .evenodd: self = .evenodd
        }
    }
}

extension BoolFillRule {
    /// The algorithm-layer rule a document rule denotes. Call this at
    /// the boundary where an element becomes a boolean operand.
    public init(_ r: FillRule) {
        switch r {
        case .nonzero: self = .nonzero
        case .evenodd: self = .evenodd
        }
    }
}

public struct Path: Equatable {
    public internal(set) var d: [PathCommand]
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public internal(set) var name: String?
    /// Stable, opaque element identity. Additive: None = no id yet, so
    /// every existing document remains valid. See `Line.id`.
    public internal(set) var id: String?
    public internal(set) var fill: Fill?
    public internal(set) var stroke: Stroke?
    public internal(set) var widthPoints: [StrokeWidthPoint]
    public internal(set) var opacity: Double
    public internal(set) var transform: Transform?
    public internal(set) var locked: Bool
    public internal(set) var visibility: Visibility
    public internal(set) var blendMode: BlendMode
    public internal(set) var mask: Mask?
    public internal(set) var fillGradient: Gradient?
    public internal(set) var strokeGradient: Gradient?
    /// Active-brush reference as "<library_slug>/<brush_slug>", or
    /// nil for a plain native-stroke path. Consumed by the canvas
    /// renderer's brush dispatch (Phase 3.4). See BRUSHES.md
    /// §Stroke styling interaction.
    public internal(set) var strokeBrush: String?
    /// Per-instance brush-parameter overrides as compact JSON
    /// layered over the master brush at render time. See BRUSHES.md
    /// §Panel state.
    public internal(set) var strokeBrushOverrides: String?
    /// Optional `jas:tool-origin` tag identifying the tool that
    /// produced this element. Blob Brush sets `"blob_brush"` on its
    /// commits so subsequent sweeps can merge / erase into the same
    /// element. Preserved by mutations; optional on export.
    /// See BLOB_BRUSH_TOOL.md §Fill and stroke.
    public internal(set) var toolOrigin: String?
    /// Which fill rule reads this path's subpaths. See `FillRule` and
    /// transcripts/BOOLEAN.md.
    ///
    /// The initializer parameter has NO DEFAULT, deliberately. Swift has
    /// no equivalent of Rust's `PathElem { d, ..p.clone() }`, so every
    /// Swift edit of a Path is an open-coded rebuild that restates each
    /// field by hand; a defaulted `fillRule` let such a rebuild compile
    /// while silently reinterpreting the artwork (refilling the holes of
    /// an even-odd boolean result). Requiring the argument makes the
    /// compiler, not a reviewer, enumerate the sites. A rebuild site passes
    /// the source's rule; a fresh-construction site states the rule its
    /// geometry means — `.nonzero` at every such site today except
    /// `Controller.applyDestructiveBoolean`, which stamps
    /// `boolResultFillRule`.
    public internal(set) var fillRule: FillRule

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
                name: String? = nil,
                id: String? = nil,
                fillRule: FillRule) {
        self.name = name
        self.id = id
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
        self.fillRule = fillRule
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
    public internal(set) var x: Double, y: Double
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public internal(set) var name: String?
    /// Stable, opaque element identity. Additive: None = no id yet, so
    /// every existing document remains valid. See `Line.id`.
    public internal(set) var id: String?
    public internal(set) var tspans: [Tspan]
    public internal(set) var fontFamily: String
    public internal(set) var fontSize: Double
    public internal(set) var fontWeight: String
    public internal(set) var fontStyle: String
    public internal(set) var textDecoration: String
    public internal(set) var textTransform: String
    public internal(set) var fontVariant: String
    public internal(set) var baselineShift: String
    public internal(set) var lineHeight: String
    public internal(set) var letterSpacing: String
    public internal(set) var xmlLang: String
    public internal(set) var aaMode: String
    public internal(set) var rotate: String
    public internal(set) var horizontalScale: String
    public internal(set) var verticalScale: String
    public internal(set) var kerning: String
    public internal(set) var width: Double
    public internal(set) var height: Double
    public internal(set) var fill: Fill?
    public internal(set) var stroke: Stroke?
    public internal(set) var opacity: Double
    public internal(set) var transform: Transform?
    public internal(set) var locked: Bool
    public internal(set) var visibility: Visibility
    public internal(set) var blendMode: BlendMode
    public internal(set) var mask: Mask?

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
                name: String? = nil,
                id: String? = nil) {
        self.name = name
        self.id = id
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
                name: String? = nil,
                id: String? = nil) {
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
                  // blendMode and mask were accepted and then NOT forwarded,
                  // so `Text(x:y:content:blendMode:mask:)` silently discarded
                  // both -- the Swift copy-site omission class again. Found by
                  // the binary codec's per-tag common extension gate
                  // (BinaryCommonExtensionTests), which drives a blend-moded,
                  // masked Text through this initializer on the read path.
                  blendMode: blendMode, mask: mask,
                  name: name, id: id)
    }

    /// Derived content: concatenation of every tspan's content.
    public var content: String { concatTspanContent(tspans) }

    public var isAreaText: Bool { width > 0 && height > 0 }

    /// Returns `true` when every tspan can be rendered by the
    /// flat / paragraph-aware fast path:
    ///
    /// - Empty paragraph wrappers (`jasRole == "paragraph"`) are
    ///   metadata only — `buildSegmentsFromText` reads them; their
    ///   character-level fields are ignored at render time, so an
    ///   empty wrapper never forces the segmented path.
    /// - Body tspans (no `jasRole`) must carry no character-level
    ///   overrides; otherwise the per-tspan font / decoration /
    ///   transform must go through the per-tspan attributed path.
    ///
    /// Without this, the moment the Paragraph panel inserts an empty
    /// wrapper before existing flat content, the renderer would flip
    /// to the segmented (single-line) path and the paragraph would
    /// collapse visually.
    public var renderIsFlat: Bool {
        tspans.allSatisfy { t in
            if t.jasRole == "paragraph" {
                return t.content.isEmpty
            }
            return t.hasNoOverrides
        }
    }

    /// Return a copy of this Text with the content replaced by one run. Used
    /// by `TextEditSession.applyToDocument`; expressed through ``withTspans``
    /// so there is exactly one preservation site for both.
    public func with(content: String) -> Text {
        withTspans([Tspan(id: 0, content: content)])
    }

    /// Return a copy with the tspans list replaced, preserving every other
    /// field. Used by `TextEditSession.applyToDocument` after reconciling
    /// content so per-range overrides survive.
    ///
    /// EDIT_SEMANTICS_FREEZE.md §3.1: this was an open-coded rebuild that
    /// stopped at `locked:`, so committing a text edit destroyed the element's
    /// `visibility`, `blendMode`, `mask`, `name` and `id` — while its own doc
    /// comment claimed it preserved everything. Rust's twin is `t.clone()` +
    /// `new_t.tspans = ...` (tools/text_edit.rs) and always conformed. The
    /// clone-then-mutate form is what makes the claim true structurally.
    public func withTspans(_ tspans: [Tspan]) -> Text {
        var v = self; v.tspans = tspans; return v
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
    public internal(set) var d: [PathCommand]
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public internal(set) var name: String?
    /// Stable, opaque element identity. Additive: None = no id yet, so
    /// every existing document remains valid. See `Line.id`.
    public internal(set) var id: String?
    public internal(set) var tspans: [Tspan]
    public internal(set) var startOffset: Double
    public internal(set) var fontFamily: String
    public internal(set) var fontSize: Double
    public internal(set) var fontWeight: String
    public internal(set) var fontStyle: String
    public internal(set) var textDecoration: String
    public internal(set) var textTransform: String
    public internal(set) var fontVariant: String
    public internal(set) var baselineShift: String
    public internal(set) var lineHeight: String
    public internal(set) var letterSpacing: String
    public internal(set) var xmlLang: String
    public internal(set) var aaMode: String
    public internal(set) var rotate: String
    public internal(set) var horizontalScale: String
    public internal(set) var verticalScale: String
    public internal(set) var kerning: String
    public internal(set) var fill: Fill?
    public internal(set) var stroke: Stroke?
    public internal(set) var opacity: Double
    public internal(set) var transform: Transform?

    public internal(set) var locked: Bool
    public internal(set) var visibility: Visibility
    public internal(set) var blendMode: BlendMode
    public internal(set) var mask: Mask?

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
                name: String? = nil,
                id: String? = nil) {
        self.name = name
        self.id = id
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
                mask: Mask? = nil,
                name: String? = nil,
                id: String? = nil) {
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
                  locked: locked, visibility: visibility,
                  // As Text's content initializer: accepted and not forwarded.
                  blendMode: blendMode, mask: mask,
                  name: name, id: id)
    }

    public var content: String { concatTspanContent(tspans) }

    public var bounds: BBox {
        return inflateBounds(pathBounds(d), stroke)
    }

    /// Return a copy of this TextPath with the content replaced by one run.
    /// Expressed through ``withTspans`` so there is one preservation site.
    public func with(content: String) -> TextPath {
        withTspans([Tspan(id: 0, content: content)])
    }

    /// Return a copy with the tspans list replaced, preserving every other
    /// field. Same clause and same repair as ``Text/withTspans(_:)`` — see its
    /// note; the rebuild this replaced dropped `visibility`, `blendMode`,
    /// `mask`, `name` and `id`.
    public func withTspans(_ tspans: [Tspan]) -> TextPath {
        var v = self; v.tspans = tspans; return v
    }
}

/// SVG \<g\> element.
public struct Group: Equatable {
    public internal(set) var children: [Element]
    /// User-visible name. None means unnamed → tree row shows <Type> fallback.
    public internal(set) var name: String?
    /// Stable, opaque element identity. Additive: None = no id yet, so
    /// every existing document remains valid. See `Line.id`.
    public internal(set) var id: String?
    public internal(set) var opacity: Double
    public internal(set) var transform: Transform?
    public internal(set) var locked: Bool
    public internal(set) var visibility: Visibility
    public internal(set) var blendMode: BlendMode
    public internal(set) var mask: Mask?
    /// Opacity panel "Page Isolated Blending" flag. Storage-only in
    /// Phase 2; renderer support is deferred. Default false.
    public internal(set) var isolatedBlending: Bool
    /// Opacity panel "Page Knockout Group" flag. Storage-only in
    /// Phase 2; renderer support is deferred. Default false.
    public internal(set) var knockoutGroup: Bool

    public init(children: [Element], opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                isolatedBlending: Bool = false,
                knockoutGroup: Bool = false,
                mask: Mask? = nil,
                name: String? = nil,
                id: String? = nil) {
        self.name = name
        self.id = id
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

/// A named group (layer) of elements. Mirrors the same field shape as
/// ``Group``: the user-visible name is `String?` and unnamed layers
/// fall back to a "Layer N" display label in the layers panel.
public struct Layer: Equatable {
    public internal(set) var name: String?
    /// Stable, opaque element identity. Additive: None = no id yet, so
    /// every existing document remains valid. See `Line.id`.
    public internal(set) var id: String?
    public internal(set) var children: [Element]
    public internal(set) var opacity: Double
    public internal(set) var transform: Transform?
    public internal(set) var locked: Bool
    public internal(set) var visibility: Visibility
    public internal(set) var blendMode: BlendMode
    public internal(set) var mask: Mask?
    /// See ``Group/isolatedBlending``. Present on layers so the
    /// document root (a Layer) can carry the flag today.
    public internal(set) var isolatedBlending: Bool
    /// See ``Group/knockoutGroup``.
    public internal(set) var knockoutGroup: Bool

    /// Convenience accessor that returns the empty string when the
    /// layer is unnamed. Most callers should use `name ?? ""` directly,
    /// but this keeps `assert(layer.displayName == "X")` style call
    /// sites readable when nil-vs-"" doesn't matter.
    public var displayName: String { name ?? "" }

    public init(name: String? = nil, children: [Element], opacity: Double = 1.0, transform: Transform? = nil,
                locked: Bool = false,
                visibility: Visibility = .preview,
                blendMode: BlendMode = .normal,
                isolatedBlending: Bool = false,
                knockoutGroup: Bool = false,
                mask: Mask? = nil,
                id: String? = nil) {
        self.name = Layer.normalizedName(name)
        self.id = id
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

// MARK: - Stable-identity helpers

// Per-struct `withId(_:)` is clone-then-mutate (`var v = self; v.id = id`),
// so it replaces only `id` and preservation of every other field is
// structural rather than a list anyone has to maintain. (The comment here
// used to describe a full memberwise-initializer rebuild; that stopped being
// the implementation and the description was left behind.) Used by
// `Element.clearingIds()` so a duplicated element is born id-less without
// dropping any other attribute. See the stable-identity initiative.

extension Line {
    public func withId(_ id: String?) -> Line {
        var v = self; v.id = id; return v
    }
}

extension Rect {
    public func withId(_ id: String?) -> Rect {
        var v = self; v.id = id; return v
    }
}

extension Ellipse {
    public func withId(_ id: String?) -> Ellipse {
        var v = self; v.id = id; return v
    }
}

extension Polyline {
    public func withId(_ id: String?) -> Polyline {
        var v = self; v.id = id; return v
    }
}

extension Polygon {
    public func withId(_ id: String?) -> Polygon {
        var v = self; v.id = id; return v
    }
}

extension Path {
    public func withId(_ id: String?) -> Path {
        var v = self; v.id = id; return v
    }
}

extension Text {
    public func withId(_ id: String?) -> Text {
        var v = self; v.id = id; return v
    }
}

extension TextPath {
    public func withId(_ id: String?) -> TextPath {
        var v = self; v.id = id; return v
    }
}

extension Group {
    public func withId(_ id: String?) -> Group {
        var v = self; v.id = id; return v
    }

    public func withChildren(_ children: [Element]) -> Group {
        var v = self; v.children = children; return v
    }
}

extension Layer {
    /// The empty layer name means UNNAMED, everywhere. Owned here so the
    /// memberwise init and ``withName(_:)`` cannot drift apart.
    static func normalizedName(_ name: String?) -> String? {
        (name?.isEmpty == true) ? nil : name
    }

    public func withId(_ id: String?) -> Layer {
        var v = self; v.id = id; return v
    }

    public func withChildren(_ children: [Element]) -> Layer {
        var v = self; v.children = children; return v
    }

    /// Clone-then-mutate single-field writes, so a caller that wants to change
    /// a layer's name / lock / visibility never has to spell out an argument
    /// list against an 11-field struct. Every such rebuild that existed before
    /// these was silently dropping `id`, `blendMode`, `mask` and both opacity
    /// flags (the Swift copy-site omission class); see `CopySiteOmissionTests`
    /// and `scripts/check_swift_copy_sites.py`.
    public func withName(_ name: String?) -> Layer {
        var v = self; v.name = Layer.normalizedName(name); return v
    }

    public func withLocked(_ locked: Bool) -> Layer {
        var v = self; v.locked = locked; return v
    }

    public func withVisibility(_ visibility: Visibility) -> Layer {
        var v = self; v.visibility = visibility; return v
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
            // A close before any point has been established is a NO-OP
            // (S-4, ruled by JYH at the fleet council 2026-07-27: the
            // artist never means a close-before-anything). Without this
            // guard the arm appends the still-uninitialised `firstPt`,
            // putting a phantom vertex at the document origin. Matches
            // Rust's `flatten_path_commands`. `firstPt` tracks the CURRENT
            // subpath start, so a close after a point still returns to the
            // MoveTo -- the guard is on emptiness, nothing else.
            if !pts.isEmpty { pts.append(firstPt) }
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
