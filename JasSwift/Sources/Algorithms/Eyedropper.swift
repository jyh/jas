// Eyedropper extract / apply helpers.
//
// Two pure functions plus an `Appearance` data container:
//
//   - extractEyedropperAppearance(element) -> Appearance
//     Snapshot a source element's relevant attrs into a serializable
//     blob suitable for state.eyedropper_cache.
//
//   - applyEyedropperAppearance(target, appearance, config) -> Element
//     Return a copy of `target` with attrs from `appearance` written
//     onto it, gated by the master / sub toggles in `config`.
//
// See transcripts/EYEDROPPER_TOOL.md for the full spec.
// Cross-language parity is mechanical — the Rust / OCaml / Python
// ports of this module follow the same shape.
//
// Phase 1 limitations:
//
//   - Character and Paragraph extraction / apply is stubbed.
//   - Stroke profile copies widthPoints on Line / Path only.
//   - Gradient / pattern fills are not sampled in Phase 1 — only
//     solid fills round-trip. A non-solid source fill is treated as
//     "no fill data sampled" (cached as nil).
//
// Cache serialization: Fill / Stroke / BlendMode in the Swift
// Element model don't conform to Codable. The Appearance type uses
// a hand-written toDict / init?(dict:) pair to round-trip through
// JSON in a shape compatible with Rust's serde-derived form (and
// the OCaml / Python ports).

import Foundation

// MARK: - Element extension (opacity accessor)
//
// Element.swift provides isLocked, blendMode, visibility — but no
// opacity accessor. Add one for use by extract/apply.

public extension Element {
    var opacityValue: Double {
        switch self {
        case .line(let v): return v.opacity
        case .rect(let v): return v.opacity
        case .circle(let v): return v.opacity
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
}

// MARK: - Data

/// Snapshot of a source element's attrs. Round-trips through JSON
/// via state.eyedropper_cache. Fields are optional so the cache can
/// encode "not sampled" distinctly from "sampled as default".
public struct EyedropperAppearance: Equatable {
    public var fill: Fill?
    public var stroke: Stroke?
    public var opacity: Double?
    public var blendMode: BlendMode?
    public var strokeBrush: String?
    public var widthPoints: [StrokeWidthPoint]

    public init(fill: Fill? = nil, stroke: Stroke? = nil,
                opacity: Double? = nil, blendMode: BlendMode? = nil,
                strokeBrush: String? = nil,
                widthPoints: [StrokeWidthPoint] = []) {
        self.fill = fill
        self.stroke = stroke
        self.opacity = opacity
        self.blendMode = blendMode
        self.strokeBrush = strokeBrush
        self.widthPoints = widthPoints
    }
}

/// Toggle configuration mirroring the 25 state.eyedropper_* boolean
/// keys. Master toggles gate entire groups; sub-toggles gate
/// individual attrs within a group. Both must be true for an
/// attribute to be applied.
public struct EyedropperConfig: Equatable {
    public var fill: Bool = true

    public var stroke: Bool = true
    public var strokeColor: Bool = true
    public var strokeWeight: Bool = true
    public var strokeCapJoin: Bool = true
    public var strokeAlign: Bool = true
    public var strokeDash: Bool = true
    public var strokeArrowheads: Bool = true
    public var strokeProfile: Bool = true
    public var strokeBrush: Bool = true

    public var opacity: Bool = true
    public var opacityAlpha: Bool = true
    public var opacityBlend: Bool = true

    public var character: Bool = true
    public var characterFont: Bool = true
    public var characterSize: Bool = true
    public var characterLeading: Bool = true
    public var characterKerning: Bool = true
    public var characterTracking: Bool = true
    public var characterColor: Bool = true

    public var paragraph: Bool = true
    public var paragraphAlign: Bool = true
    public var paragraphIndent: Bool = true
    public var paragraphSpace: Bool = true
    public var paragraphHyphenate: Bool = true

    public init() {}
}

// MARK: - Eligibility

/// Source-side eligibility per EYEDROPPER_TOOL.md §Eligibility.
/// Locked is OK (we read, don't write); Hidden is not (no hit-test).
/// Group / Layer are never sources — the caller is responsible for
/// descending to the innermost element under the cursor.
public func isSourceEligible(_ element: Element) -> Bool {
    if element.visibility == .invisible { return false }
    switch element {
    case .group, .layer: return false
    default: return true
    }
}

/// Target-side eligibility per EYEDROPPER_TOOL.md §Eligibility.
/// Locked is not OK (writes need permission); Hidden is OK (writes
/// persist). Group / Layer are never targets — the caller recurses
/// into them and applies to leaves.
public func isTargetEligible(_ element: Element) -> Bool {
    if element.isLocked { return false }
    switch element {
    case .group, .layer: return false
    default: return true
    }
}

// MARK: - Extract

/// Snapshot the source element's attrs into an Appearance.
/// Caller is responsible for source-eligibility; this function does
/// not filter.
public func extractEyedropperAppearance(_ element: Element) -> EyedropperAppearance {
    return EyedropperAppearance(
        fill: element.fill,
        stroke: element.stroke,
        opacity: element.opacityValue,
        blendMode: element.blendMode,
        strokeBrush: extractStrokeBrush(element),
        widthPoints: extractWidthPoints(element)
    )
}

private func extractStrokeBrush(_ element: Element) -> String? {
    if case .path(let p) = element { return p.strokeBrush }
    return nil
}

private func extractWidthPoints(_ element: Element) -> [StrokeWidthPoint] {
    switch element {
    case .line(let v): return v.widthPoints
    case .path(let v): return v.widthPoints
    default: return []
    }
}

// MARK: - Apply

/// Return a copy of `target` with the attrs from `appearance`
/// applied per `config`. Master OFF skips the entire group;
/// master ON + sub OFF skips that sub-attribute. Caller is
/// responsible for target-eligibility (locked / container check);
/// this function applies to whatever it's given.
public func applyEyedropperAppearance(
    _ target: Element,
    appearance: EyedropperAppearance,
    config: EyedropperConfig
) -> Element {
    var result = target

    // Fill
    if config.fill {
        result = withFill(result, fill: appearance.fill)
    }

    // Stroke (master + sub-toggles)
    if config.stroke {
        result = applyStrokeWithSubs(result, src: appearance.stroke, config: config)
        if config.strokeBrush {
            result = withStrokeBrush(result, strokeBrush: appearance.strokeBrush)
        }
        if config.strokeProfile {
            result = withWidthPoints(result, widthPoints: appearance.widthPoints)
        }
    }

    // Opacity (master + 2 sub-toggles)
    if config.opacity {
        if config.opacityAlpha, let op = appearance.opacity {
            result = withOpacity(result, opacity: op)
        }
        if config.opacityBlend, let blend = appearance.blendMode {
            result = withBlendMode(result, blendMode: blend)
        }
    }

    // Character / Paragraph: Phase 1 stub (no-op).
    return result
}

/// Helper for the Stroke group's per-sub-toggle apply. Mirrors the
/// Rust apply_stroke_with_subs.
private func applyStrokeWithSubs(
    _ target: Element,
    src: Stroke?,
    config: EyedropperConfig
) -> Element {
    guard let src = src else {
        return withStroke(target, stroke: nil)
    }

    let anyStrokeSub = config.strokeColor || config.strokeWeight
        || config.strokeCapJoin || config.strokeAlign
        || config.strokeDash || config.strokeArrowheads
    if !anyStrokeSub {
        return target
    }

    let existing = target.stroke ?? Stroke(color: src.color, width: src.width)

    let newStroke = Stroke(
        color: config.strokeColor ? src.color : existing.color,
        width: config.strokeWeight ? src.width : existing.width,
        linecap: config.strokeCapJoin ? src.linecap : existing.linecap,
        linejoin: config.strokeCapJoin ? src.linejoin : existing.linejoin,
        miterLimit: config.strokeCapJoin ? src.miterLimit : existing.miterLimit,
        align: config.strokeAlign ? src.align : existing.align,
        dashPattern: config.strokeDash ? src.dashPattern : existing.dashPattern,
        startArrow: config.strokeArrowheads ? src.startArrow : existing.startArrow,
        endArrow: config.strokeArrowheads ? src.endArrow : existing.endArrow,
        startArrowScale: config.strokeArrowheads ? src.startArrowScale : existing.startArrowScale,
        endArrowScale: config.strokeArrowheads ? src.endArrowScale : existing.endArrowScale,
        arrowAlign: config.strokeArrowheads ? src.arrowAlign : existing.arrowAlign,
        opacity: config.strokeColor ? src.opacity : existing.opacity
    )
    return withStroke(target, stroke: newStroke)
}

// MARK: - Element opacity / blendMode helpers

private func withOpacity(_ element: Element, opacity: Double) -> Element {
    return rebuildWithOpacityAndBlend(element, opacity: opacity, blendMode: nil)
}

private func withBlendMode(_ element: Element, blendMode: BlendMode) -> Element {
    return rebuildWithOpacityAndBlend(element, opacity: nil, blendMode: blendMode)
}

private func rebuildWithOpacityAndBlend(
    _ element: Element,
    opacity newOpacity: Double?,
    blendMode newBlendMode: BlendMode?
) -> Element {
    switch element {
    case .line(let v):
        return .line(Line(
            x1: v.x1, y1: v.y1, x2: v.x2, y2: v.y2,
            stroke: v.stroke, widthPoints: v.widthPoints,
            opacity: newOpacity ?? v.opacity, transform: v.transform,
            locked: v.locked, visibility: v.visibility,
            blendMode: newBlendMode ?? v.blendMode, mask: v.mask,
            strokeGradient: v.strokeGradient
        ))
    case .rect(let v):
        return .rect(Rect(
            x: v.x, y: v.y, width: v.width, height: v.height,
            rx: v.rx, ry: v.ry, fill: v.fill, stroke: v.stroke,
            opacity: newOpacity ?? v.opacity, transform: v.transform,
            locked: v.locked, visibility: v.visibility,
            blendMode: newBlendMode ?? v.blendMode, mask: v.mask,
            fillGradient: v.fillGradient, strokeGradient: v.strokeGradient
        ))
    case .circle(let v):
        return .circle(Circle(
            cx: v.cx, cy: v.cy, r: v.r,
            fill: v.fill, stroke: v.stroke,
            opacity: newOpacity ?? v.opacity, transform: v.transform,
            locked: v.locked, visibility: v.visibility,
            blendMode: newBlendMode ?? v.blendMode, mask: v.mask,
            fillGradient: v.fillGradient, strokeGradient: v.strokeGradient
        ))
    case .ellipse(let v):
        return .ellipse(Ellipse(
            cx: v.cx, cy: v.cy, rx: v.rx, ry: v.ry,
            fill: v.fill, stroke: v.stroke,
            opacity: newOpacity ?? v.opacity, transform: v.transform,
            locked: v.locked, visibility: v.visibility,
            blendMode: newBlendMode ?? v.blendMode, mask: v.mask,
            fillGradient: v.fillGradient, strokeGradient: v.strokeGradient
        ))
    case .polyline(let v):
        return .polyline(Polyline(
            points: v.points, fill: v.fill, stroke: v.stroke,
            opacity: newOpacity ?? v.opacity, transform: v.transform,
            locked: v.locked, visibility: v.visibility,
            blendMode: newBlendMode ?? v.blendMode, mask: v.mask,
            fillGradient: v.fillGradient, strokeGradient: v.strokeGradient
        ))
    case .polygon(let v):
        return .polygon(Polygon(
            points: v.points, fill: v.fill, stroke: v.stroke,
            opacity: newOpacity ?? v.opacity, transform: v.transform,
            locked: v.locked, visibility: v.visibility,
            blendMode: newBlendMode ?? v.blendMode, mask: v.mask,
            fillGradient: v.fillGradient, strokeGradient: v.strokeGradient
        ))
    case .path(let v):
        return .path(Path(
            d: v.d, fill: v.fill, stroke: v.stroke,
            widthPoints: v.widthPoints,
            opacity: newOpacity ?? v.opacity, transform: v.transform,
            locked: v.locked, visibility: v.visibility,
            blendMode: newBlendMode ?? v.blendMode, mask: v.mask,
            fillGradient: v.fillGradient, strokeGradient: v.strokeGradient,
            strokeBrush: v.strokeBrush,
            strokeBrushOverrides: v.strokeBrushOverrides
        ))
    case .text, .textPath, .group, .layer, .live:
        // Phase 1: text / paragraph rebuilds + container / live
        // pass-through deferred. apply_to_target_recursive descends
        // into containers, and live elements have their own attr
        // handling.
        return element
    }
}

// MARK: - JSON dict serialization
//
// Cache state is held by StateStore as Any; we round-trip Appearance
// through a [String: Any] dictionary that matches the Rust serde
// JSON shape so cached values are portable across apps.

public extension EyedropperAppearance {
    /// Serialize to a JSON-compatible dictionary. Empty fields are
    /// omitted (matching Rust's #[serde(skip_serializing_if =
    /// "Option::is_none")]).
    func toDict() -> [String: Any] {
        var out: [String: Any] = [:]
        if let f = fill { out["fill"] = fillToDict(f) }
        if let s = stroke { out["stroke"] = strokeToDict(s) }
        if let op = opacity { out["opacity"] = op }
        if let bm = blendMode { out["blend_mode"] = bm.rawValue }
        if let sb = strokeBrush { out["stroke_brush"] = sb }
        if !widthPoints.isEmpty {
            out["width_points"] = widthPoints.map { wp -> [String: Any] in
                ["t": wp.t, "width_left": wp.widthLeft, "width_right": wp.widthRight]
            }
        }
        return out
    }

    /// Parse from a JSON-compatible dictionary; returns nil if the
    /// shape is unrecognizable. Missing fields are decoded as nil.
    init?(dict: [String: Any]) {
        let f = (dict["fill"] as? [String: Any]).flatMap(fillFromDict)
        let s = (dict["stroke"] as? [String: Any]).flatMap(strokeFromDict)
        let op = dict["opacity"] as? Double
        let bm = (dict["blend_mode"] as? String).flatMap { BlendMode(rawValue: $0) }
        let sb = dict["stroke_brush"] as? String
        let wp: [StrokeWidthPoint] = ((dict["width_points"] as? [[String: Any]]) ?? []).compactMap {
            guard let t = $0["t"] as? Double,
                  let l = $0["width_left"] as? Double,
                  let r = $0["width_right"] as? Double
            else { return nil }
            return StrokeWidthPoint(t: t, widthLeft: l, widthRight: r)
        }
        self.init(fill: f, stroke: s, opacity: op, blendMode: bm,
                  strokeBrush: sb, widthPoints: wp)
    }
}

private func fillToDict(_ f: Fill) -> [String: Any] {
    return [
        "color": colorToString(f.color),
        "opacity": f.opacity,
    ]
}

private func fillFromDict(_ d: [String: Any]) -> Fill? {
    guard let colorAny = d["color"], let opacity = d["opacity"] as? Double else {
        return nil
    }
    guard let color = colorFromAny(colorAny) else { return nil }
    return Fill(color: color, opacity: opacity)
}

private func strokeToDict(_ s: Stroke) -> [String: Any] {
    return [
        "color":             colorToString(s.color),
        "width":             s.width,
        "linecap":           lineCapToString(s.linecap),
        "linejoin":          lineJoinToString(s.linejoin),
        "miter_limit":       s.miterLimit,
        "align":             strokeAlignToString(s.align),
        "dash_pattern":      s.dashPattern,
        "start_arrow":       arrowheadToString(s.startArrow),
        "end_arrow":         arrowheadToString(s.endArrow),
        "start_arrow_scale": s.startArrowScale,
        "end_arrow_scale":   s.endArrowScale,
        "arrow_align":       arrowAlignToString(s.arrowAlign),
        "opacity":           s.opacity,
    ]
}

private func strokeFromDict(_ d: [String: Any]) -> Stroke? {
    guard let colorAny = d["color"], let color = colorFromAny(colorAny) else { return nil }
    let width = (d["width"] as? Double) ?? 1.0
    let cap = lineCapFromString(d["linecap"] as? String ?? "butt")
    let join = lineJoinFromString(d["linejoin"] as? String ?? "miter")
    let miter = (d["miter_limit"] as? Double) ?? 10.0
    let align = strokeAlignFromString(d["align"] as? String ?? "center")
    let dashPattern = (d["dash_pattern"] as? [Double]) ?? []
    let startArrow = arrowheadFromString(d["start_arrow"] as? String ?? "none")
    let endArrow = arrowheadFromString(d["end_arrow"] as? String ?? "none")
    let startScale = (d["start_arrow_scale"] as? Double) ?? 100.0
    let endScale = (d["end_arrow_scale"] as? Double) ?? 100.0
    let arrowAlign = arrowAlignFromString(d["arrow_align"] as? String ?? "tip_at_end")
    let opacity = (d["opacity"] as? Double) ?? 1.0
    return Stroke(
        color: color, width: width, linecap: cap, linejoin: join,
        miterLimit: miter, align: align, dashPattern: dashPattern,
        startArrow: startArrow, endArrow: endArrow,
        startArrowScale: startScale, endArrowScale: endScale,
        arrowAlign: arrowAlign, opacity: opacity
    )
}

// Color round-trip uses the SVG hex form when possible, falling back
// to a string representation accepted by Color's existing parser.

private func colorToString(_ c: Color) -> String {
    return c.toHex()
}

private func colorFromAny(_ v: Any) -> Color? {
    if let s = v as? String { return Color.fromHex(s) }
    if let arr = v as? [Double], arr.count >= 3 {
        let a = arr.count >= 4 ? arr[3] : 1.0
        return .rgb(r: arr[0], g: arr[1], b: arr[2], a: a)
    }
    if let dict = v as? [String: Any],
       let r = dict["r"] as? Double,
       let g = dict["g"] as? Double,
       let b = dict["b"] as? Double {
        return .rgb(r: r, g: g, b: b, a: (dict["a"] as? Double) ?? 1.0)
    }
    return nil
}

private func lineCapToString(_ v: LineCap) -> String {
    switch v {
    case .butt: return "butt"
    case .round: return "round"
    case .square: return "square"
    }
}
private func lineCapFromString(_ s: String) -> LineCap {
    switch s {
    case "round": return .round
    case "square": return .square
    default: return .butt
    }
}

private func lineJoinToString(_ v: LineJoin) -> String {
    switch v {
    case .miter: return "miter"
    case .round: return "round"
    case .bevel: return "bevel"
    }
}
private func lineJoinFromString(_ s: String) -> LineJoin {
    switch s {
    case "round": return .round
    case "bevel": return .bevel
    default: return .miter
    }
}

private func strokeAlignToString(_ v: StrokeAlign) -> String {
    switch v {
    case .center: return "center"
    case .inside: return "inside"
    case .outside: return "outside"
    }
}
private func strokeAlignFromString(_ s: String) -> StrokeAlign {
    switch s {
    case "inside": return .inside
    case "outside": return .outside
    default: return .center
    }
}

private func arrowheadToString(_ v: Arrowhead) -> String {
    return v.rawValue
}
private func arrowheadFromString(_ s: String) -> Arrowhead {
    return Arrowhead(fromString: s)
}

private func arrowAlignToString(_ v: ArrowAlign) -> String {
    switch v {
    case .tipAtEnd: return "tip_at_end"
    case .centerAtEnd: return "center_at_end"
    }
}
private func arrowAlignFromString(_ s: String) -> ArrowAlign {
    switch s {
    case "center_at_end": return .centerAtEnd
    default: return .tipAtEnd
    }
}
