import Foundation

/// Convert a Document to SVG format.
///
/// Internal coordinates are in points (pt). SVG coordinates are in pixels (px).
/// The conversion factor is 96/72 (CSS px per pt at 96 DPI).

private let ptToPx = 96.0 / 72.0

private func px(_ v: Double) -> Double { v * ptToPx }

private func fmt(_ v: Double) -> String {
    let s = String(format: "%.4f", v)
    // Strip trailing zeros and dot
    var end = s.endIndex
    while end > s.startIndex && s[s.index(before: end)] == "0" {
        end = s.index(before: end)
    }
    if end > s.startIndex && s[s.index(before: end)] == "." {
        end = s.index(before: end)
    }
    return String(s[s.startIndex..<end])
}

private func colorStr(_ c: Color) -> String {
    let (cr, cg, cb, ca) = c.toRgba()
    let r = Int(round(cr * 255))
    let g = Int(round(cg * 255))
    let b = Int(round(cb * 255))
    if ca < 1.0 { return "rgba(\(r),\(g),\(b),\(fmt(ca)))" }
    return "rgb(\(r),\(g),\(b))"
}

private func escapeXml(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
}

private func fillAttrs(_ fill: Fill?) -> String {
    guard let fill = fill else { return " fill=\"none\"" }
    var s = " fill=\"\(colorStr(fill.color))\""
    if fill.opacity < 1.0 { s += " fill-opacity=\"\(fmt(fill.opacity))\"" }
    return s
}

private func strokeAttrs(_ stroke: Stroke?) -> String {
    guard let stroke = stroke else { return " stroke=\"none\"" }
    var s = " stroke=\"\(colorStr(stroke.color))\""
    s += " stroke-width=\"\(fmt(px(stroke.width)))\""
    switch stroke.linecap {
    case .butt: break
    case .round: s += " stroke-linecap=\"round\""
    case .square: s += " stroke-linecap=\"square\""
    }
    switch stroke.linejoin {
    case .miter: break
    case .round: s += " stroke-linejoin=\"round\""
    case .bevel: s += " stroke-linejoin=\"bevel\""
    }
    if stroke.opacity < 1.0 { s += " stroke-opacity=\"\(fmt(stroke.opacity))\"" }
    return s
}

private func transformAttr(_ t: Transform?) -> String {
    guard let t = t else { return "" }
    return " transform=\"matrix(\(fmt(t.a)),\(fmt(t.b)),\(fmt(t.c)),\(fmt(t.d)),\(fmt(px(t.e))),\(fmt(px(t.f))))\""
}

private func opacityAttr(_ o: Double) -> String {
    o >= 1.0 ? "" : " opacity=\"\(fmt(o))\""
}

private func pathData(_ commands: [PathCommand]) -> String {
    commands.map { cmd in
        switch cmd {
        case .moveTo(let x, let y):
            return "M\(fmt(px(x))),\(fmt(px(y)))"
        case .lineTo(let x, let y):
            return "L\(fmt(px(x))),\(fmt(px(y)))"
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            return "C\(fmt(px(x1))),\(fmt(px(y1))) \(fmt(px(x2))),\(fmt(px(y2))) \(fmt(px(x))),\(fmt(px(y)))"
        case .smoothCurveTo(let x2, let y2, let x, let y):
            return "S\(fmt(px(x2))),\(fmt(px(y2))) \(fmt(px(x))),\(fmt(px(y)))"
        case .quadTo(let x1, let y1, let x, let y):
            return "Q\(fmt(px(x1))),\(fmt(px(y1))) \(fmt(px(x))),\(fmt(px(y)))"
        case .smoothQuadTo(let x, let y):
            return "T\(fmt(px(x))),\(fmt(px(y)))"
        case .arcTo(let rx, let ry, let rot, let large, let sweep, let x, let y):
            return "A\(fmt(px(rx))),\(fmt(px(ry))) \(fmt(rot)) \(large ? 1 : 0),\(sweep ? 1 : 0) \(fmt(px(x))),\(fmt(px(y)))"
        case .closePath:
            return "Z"
        }
    }.joined(separator: " ")
}

/// Build the attribute-string fragment for the 11 Character-panel
/// attributes, emitting each attribute only when non-empty (per
/// CHARACTER.md's identity-omission rule).
private func textExtraAttrs(textTransform: String, fontVariant: String,
                            baselineShift: String, lineHeight: String,
                            letterSpacing: String, xmlLang: String,
                            aaMode: String, rotate: String,
                            horizontalScale: String, verticalScale: String,
                            kerning: String) -> String {
    var s = ""
    if !textTransform.isEmpty { s += " text-transform=\"\(textTransform)\"" }
    if !fontVariant.isEmpty { s += " font-variant=\"\(fontVariant)\"" }
    if !baselineShift.isEmpty { s += " baseline-shift=\"\(baselineShift)\"" }
    if !lineHeight.isEmpty { s += " line-height=\"\(lineHeight)\"" }
    if !letterSpacing.isEmpty { s += " letter-spacing=\"\(letterSpacing)\"" }
    if !xmlLang.isEmpty { s += " xml:lang=\"\(escapeXml(xmlLang))\"" }
    if !aaMode.isEmpty { s += " urn:jas:1:aa-mode=\"\(escapeXml(aaMode))\"" }
    if !rotate.isEmpty { s += " rotate=\"\(rotate)\"" }
    if !horizontalScale.isEmpty { s += " horizontal-scale=\"\(horizontalScale)\"" }
    if !verticalScale.isEmpty { s += " vertical-scale=\"\(verticalScale)\"" }
    if !kerning.isEmpty { s += " urn:jas:1:kerning-mode=\"\(escapeXml(kerning))\"" }
    return s
}

/// Emit a single Tspan as an SVG `<tspan ...>content</tspan>` element.
/// Only overridden attributes are emitted (inherited values are
/// absent). Matches the Rust `tspan_svg` — the 5 attributes that
/// round-trip via SVG natively: font-family, font-size, font-weight,
/// font-style, text-decoration.
private func tspanSvg(_ t: Tspan) -> String {
    var attrs = ""
    if let v = t.fontFamily {
        attrs += " font-family=\"\(escapeXml(v))\""
    }
    if let v = t.fontSize {
        attrs += " font-size=\"\(fmt(px(v)))\""
    }
    if let v = t.fontWeight {
        attrs += " font-weight=\"\(escapeXml(v))\""
    }
    if let v = t.fontStyle {
        attrs += " font-style=\"\(escapeXml(v))\""
    }
    if let members = t.textDecoration, !members.isEmpty {
        attrs += " text-decoration=\"\(escapeXml(members.joined(separator: " ")))\""
    }
    return "<tspan\(attrs)>\(escapeXml(t.content))</tspan>"
}

public func elementSvg(_ elem: Element, indent: String) -> String {
    switch elem {
    case .line(let v):
        return "\(indent)<line x1=\"\(fmt(px(v.x1)))\" y1=\"\(fmt(px(v.y1)))\"" +
            " x2=\"\(fmt(px(v.x2)))\" y2=\"\(fmt(px(v.y2)))\"" +
            "\(strokeAttrs(v.stroke))\(opacityAttr(v.opacity))\(transformAttr(v.transform))/>"

    case .rect(let v):
        var rxy = ""
        if v.rx > 0 { rxy += " rx=\"\(fmt(px(v.rx)))\"" }
        if v.ry > 0 { rxy += " ry=\"\(fmt(px(v.ry)))\"" }
        return "\(indent)<rect x=\"\(fmt(px(v.x)))\" y=\"\(fmt(px(v.y)))\"" +
            " width=\"\(fmt(px(v.width)))\" height=\"\(fmt(px(v.height)))\"" +
            "\(rxy)\(fillAttrs(v.fill))\(strokeAttrs(v.stroke))" +
            "\(opacityAttr(v.opacity))\(transformAttr(v.transform))/>"

    case .circle(let v):
        return "\(indent)<circle cx=\"\(fmt(px(v.cx)))\" cy=\"\(fmt(px(v.cy)))\"" +
            " r=\"\(fmt(px(v.r)))\"" +
            "\(fillAttrs(v.fill))\(strokeAttrs(v.stroke))" +
            "\(opacityAttr(v.opacity))\(transformAttr(v.transform))/>"

    case .ellipse(let v):
        return "\(indent)<ellipse cx=\"\(fmt(px(v.cx)))\" cy=\"\(fmt(px(v.cy)))\"" +
            " rx=\"\(fmt(px(v.rx)))\" ry=\"\(fmt(px(v.ry)))\"" +
            "\(fillAttrs(v.fill))\(strokeAttrs(v.stroke))" +
            "\(opacityAttr(v.opacity))\(transformAttr(v.transform))/>"

    case .polyline(let v):
        let ps = v.points.map { "\(fmt(px($0.0))),\(fmt(px($0.1)))" }.joined(separator: " ")
        return "\(indent)<polyline points=\"\(ps)\"" +
            "\(fillAttrs(v.fill))\(strokeAttrs(v.stroke))" +
            "\(opacityAttr(v.opacity))\(transformAttr(v.transform))/>"

    case .polygon(let v):
        let ps = v.points.map { "\(fmt(px($0.0))),\(fmt(px($0.1)))" }.joined(separator: " ")
        return "\(indent)<polygon points=\"\(ps)\"" +
            "\(fillAttrs(v.fill))\(strokeAttrs(v.stroke))" +
            "\(opacityAttr(v.opacity))\(transformAttr(v.transform))/>"

    case .path(let v):
        return "\(indent)<path d=\"\(pathData(v.d))\"" +
            "\(fillAttrs(v.fill))\(strokeAttrs(v.stroke))" +
            "\(opacityAttr(v.opacity))\(transformAttr(v.transform))/>"

    case .text(let v):
        let areaAttrs = v.isAreaText
            ? " style=\"inline-size: \(fmt(px(v.width)))px; white-space: pre-wrap;\""
            : ""
        let fwAttr = v.fontWeight != "normal" ? " font-weight=\"\(v.fontWeight)\"" : ""
        let fsAttr = v.fontStyle != "normal" ? " font-style=\"\(v.fontStyle)\"" : ""
        let tdAttr = (v.textDecoration != "none" && !v.textDecoration.isEmpty)
            ? " text-decoration=\"\(v.textDecoration)\"" : ""
        let extraAttrs = textExtraAttrs(
            textTransform: v.textTransform, fontVariant: v.fontVariant,
            baselineShift: v.baselineShift, lineHeight: v.lineHeight,
            letterSpacing: v.letterSpacing, xmlLang: v.xmlLang,
            aaMode: v.aaMode, rotate: v.rotate,
            horizontalScale: v.horizontalScale, verticalScale: v.verticalScale,
            kerning: v.kerning)
        // SVG `y` is the baseline of the first line; internally `v.y`
        // is the *top* of the layout box, so add the ascent (0.8 *
        // fontSize, the same value `text_layout` uses).
        let svgY = v.y + v.fontSize * 0.8
        // Pre-Tspan-compatible emission: a single no-override tspan
        // round-trips as a flat <text>contents</text>, no <tspan>
        // wrapper. Multi-tspan or any override carries
        // xml:space="preserve" and emits <tspan> children so
        // whitespace round-trips byte-stably (TSPAN.md SVG serialization).
        let isFlat = v.tspans.count == 1 && v.tspans[0].hasNoOverrides
        let body: String
        let spaceAttr: String
        if isFlat {
            body = escapeXml(v.content)
            spaceAttr = ""
        } else {
            body = v.tspans.map(tspanSvg).joined()
            spaceAttr = " xml:space=\"preserve\""
        }
        return "\(indent)<text x=\"\(fmt(px(v.x)))\" y=\"\(fmt(px(svgY)))\"" +
            " font-family=\"\(escapeXml(v.fontFamily))\" font-size=\"\(fmt(px(v.fontSize)))\"" +
            "\(fwAttr)\(fsAttr)\(tdAttr)\(extraAttrs)" +
            "\(areaAttrs)" +
            "\(fillAttrs(v.fill))\(strokeAttrs(v.stroke))" +
            "\(opacityAttr(v.opacity))\(transformAttr(v.transform))\(spaceAttr)>" +
            "\(body)</text>"

    case .textPath(let v):
        let d = pathData(v.d)
        let fwAttr = v.fontWeight != "normal" ? " font-weight=\"\(v.fontWeight)\"" : ""
        let fsAttr = v.fontStyle != "normal" ? " font-style=\"\(v.fontStyle)\"" : ""
        let tdAttr = (v.textDecoration != "none" && !v.textDecoration.isEmpty)
            ? " text-decoration=\"\(v.textDecoration)\"" : ""
        let extraAttrs = textExtraAttrs(
            textTransform: v.textTransform, fontVariant: v.fontVariant,
            baselineShift: v.baselineShift, lineHeight: v.lineHeight,
            letterSpacing: v.letterSpacing, xmlLang: v.xmlLang,
            aaMode: v.aaMode, rotate: v.rotate,
            horizontalScale: v.horizontalScale, verticalScale: v.verticalScale,
            kerning: v.kerning)
        let isFlat = v.tspans.count == 1 && v.tspans[0].hasNoOverrides
        let tpBody: String
        let tpSpaceAttr: String
        if isFlat {
            tpBody = escapeXml(v.content)
            tpSpaceAttr = ""
        } else {
            tpBody = v.tspans.map(tspanSvg).joined()
            tpSpaceAttr = " xml:space=\"preserve\""
        }
        return "\(indent)<text\(fillAttrs(v.fill))\(strokeAttrs(v.stroke))" +
            " font-family=\"\(escapeXml(v.fontFamily))\" font-size=\"\(fmt(px(v.fontSize)))\"" +
            "\(fwAttr)\(fsAttr)\(tdAttr)\(extraAttrs)" +
            "\(opacityAttr(v.opacity))\(transformAttr(v.transform))>" +
            "<textPath path=\"\(d)\"" +
            (v.startOffset > 0 ? " startOffset=\"\(fmt(v.startOffset * 100))%\"" : "") +
            "\(tpSpaceAttr)>\(tpBody)</textPath></text>"

    case .group(let v):
        var lines = ["\(indent)<g\(opacityAttr(v.opacity))\(transformAttr(v.transform))>"]
        for child in v.children {
            lines.append(elementSvg(child, indent: indent + "  "))
        }
        lines.append("\(indent)</g>")
        return lines.joined(separator: "\n")

    case .layer(let v):
        let label = v.name.isEmpty ? "" : " inkscape:label=\"\(escapeXml(v.name))\""
        var lines = ["\(indent)<g\(label)\(opacityAttr(v.opacity))\(transformAttr(v.transform))>"]
        for child in v.children {
            lines.append(elementSvg(child, indent: indent + "  "))
        }
        lines.append("\(indent)</g>")
        return lines.joined(separator: "\n")
    }
}

public func documentToSvg(_ doc: Document) -> String {
    let b = doc.bounds
    let vb = "\(fmt(px(b.x))) \(fmt(px(b.y))) \(fmt(px(b.width))) \(fmt(px(b.height)))"
    var lines = [
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:inkscape=\"http://www.inkscape.org/namespaces/inkscape\" viewBox=\"\(vb)\" width=\"\(fmt(px(b.width)))\" height=\"\(fmt(px(b.height)))\">",
    ]
    for layer in doc.layers {
        lines.append(elementSvg(.layer(layer), indent: "  "))
    }
    lines.append("</svg>")
    return lines.joined(separator: "\n")
}

// MARK: - SVG Import

private let pxToPt = 72.0 / 96.0

private func toPt(_ v: Double) -> Double { v * pxToPt }

private let namedColors: [String: (Int, Int, Int)] = [
    "black": (0, 0, 0), "white": (255, 255, 255), "red": (255, 0, 0),
    "green": (0, 128, 0), "blue": (0, 0, 255), "yellow": (255, 255, 0),
    "cyan": (0, 255, 255), "magenta": (255, 0, 255), "gray": (128, 128, 128),
    "grey": (128, 128, 128), "silver": (192, 192, 192), "maroon": (128, 0, 0),
    "olive": (128, 128, 0), "lime": (0, 255, 0), "aqua": (0, 255, 255),
    "teal": (0, 128, 128), "navy": (0, 0, 128), "fuchsia": (255, 0, 255),
    "purple": (128, 0, 128), "orange": (255, 165, 0), "pink": (255, 192, 203),
    "brown": (165, 42, 42), "coral": (255, 127, 80), "crimson": (220, 20, 60),
    "gold": (255, 215, 0), "indigo": (75, 0, 130), "ivory": (255, 255, 240),
    "khaki": (240, 230, 140), "lavender": (230, 230, 250), "plum": (221, 160, 221),
    "salmon": (250, 128, 114), "sienna": (160, 82, 45), "tan": (210, 180, 140),
    "tomato": (255, 99, 71), "turquoise": (64, 224, 208), "violet": (238, 130, 238),
    "wheat": (245, 222, 179), "steelblue": (70, 130, 180), "skyblue": (135, 206, 235),
    "slategray": (112, 128, 144), "slategrey": (112, 128, 144),
    "darkgray": (169, 169, 169), "darkgrey": (169, 169, 169),
    "lightgray": (211, 211, 211), "lightgrey": (211, 211, 211),
    "darkblue": (0, 0, 139), "darkgreen": (0, 100, 0), "darkred": (139, 0, 0),
]

private func parseColor(_ s: String) -> Color? {
    let s = s.trimmingCharacters(in: .whitespaces)
    if s == "none" { return nil }
    // Named SVG colors
    if let (r, g, b) = namedColors[s.lowercased()] {
        return Color(r: Double(r) / 255.0, g: Double(g) / 255.0, b: Double(b) / 255.0)
    }
    // Hex colors: #RGB, #RGBA, #RRGGBB, #RRGGBBAA
    if s.hasPrefix("#") {
        let hex = String(s.dropFirst())
        if hex.count == 3 {
            let chars = Array(hex)
            guard let r = UInt8(String(repeating: chars[0], count: 2), radix: 16),
                  let g = UInt8(String(repeating: chars[1], count: 2), radix: 16),
                  let b = UInt8(String(repeating: chars[2], count: 2), radix: 16) else { return nil }
            return Color(r: Double(r) / 255.0, g: Double(g) / 255.0, b: Double(b) / 255.0)
        }
        if hex.count == 4 {
            let chars = Array(hex)
            guard let r = UInt8(String(repeating: chars[0], count: 2), radix: 16),
                  let g = UInt8(String(repeating: chars[1], count: 2), radix: 16),
                  let b = UInt8(String(repeating: chars[2], count: 2), radix: 16),
                  let a = UInt8(String(repeating: chars[3], count: 2), radix: 16) else { return nil }
            return Color(r: Double(r) / 255.0, g: Double(g) / 255.0, b: Double(b) / 255.0, a: Double(a) / 255.0)
        }
        if hex.count == 6 {
            guard let val = UInt32(hex, radix: 16) else { return nil }
            return Color(r: Double((val >> 16) & 0xFF) / 255.0,
                         g: Double((val >> 8) & 0xFF) / 255.0,
                         b: Double(val & 0xFF) / 255.0)
        }
        if hex.count == 8 {
            guard let val = UInt64(hex, radix: 16) else { return nil }
            return Color(r: Double((val >> 24) & 0xFF) / 255.0,
                         g: Double((val >> 16) & 0xFF) / 255.0,
                         b: Double((val >> 8) & 0xFF) / 255.0,
                         a: Double(val & 0xFF) / 255.0)
        }
        return nil
    }
    // rgba()/rgb() functional notation
    if s.hasPrefix("rgba(") {
        let inner = s.dropFirst(5).dropLast(1)
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 4,
              let r = Int(parts[0]), let g = Int(parts[1]),
              let b = Int(parts[2]), let a = Double(parts[3]) else { return nil }
        return Color(r: Double(r) / 255.0, g: Double(g) / 255.0, b: Double(b) / 255.0, a: a)
    }
    if s.hasPrefix("rgb(") {
        let inner = s.dropFirst(4).dropLast(1)
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3,
              let r = Int(parts[0]), let g = Int(parts[1]), let b = Int(parts[2]) else { return nil }
        return Color(r: Double(r) / 255.0, g: Double(g) / 255.0, b: Double(b) / 255.0)
    }
    print("Warning: unrecognized SVG color value: \(s)")
    return nil
}

/// Parse an SVG `<tspan>` child node into a Tspan. Only attributes
/// present on the node become `Some` overrides; absent attributes
/// remain `nil` (tspan inherits from the parent element). Mirrors
/// the Rust `parse_tspan`.
private func parseTspan(_ node: XMLElement, id: UInt32) -> Tspan {
    let content = node.stringValue ?? ""
    let fontFamily = node.attribute(forName: "font-family")?.stringValue
    let fontSize = (node.attribute(forName: "font-size")?.stringValue)
        .flatMap(Double.init).map(toPt)
    let fontWeight = node.attribute(forName: "font-weight")?.stringValue
    let fontStyle = node.attribute(forName: "font-style")?.stringValue
    let decoration = (node.attribute(forName: "text-decoration")?.stringValue).map { raw -> [String] in
        raw.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0 != "none" && !$0.isEmpty }
            .sorted()
    }
    return Tspan(
        id: id, content: content,
        fontFamily: fontFamily, fontSize: fontSize,
        fontStyle: fontStyle, fontWeight: fontWeight,
        textDecoration: decoration)
}

/// Collect `<tspan>` children from an XMLElement and return them as
/// a list of parsed Tspans, in document order. Returns an empty list
/// when no `<tspan>` children are present (caller falls back to the
/// flat-content single-tspan default).
private func collectTspanChildren(_ elem: XMLElement) -> [Tspan] {
    guard let children = elem.children else { return [] }
    var result: [Tspan] = []
    var nextId: UInt32 = 0
    for child in children {
        if let xml = child as? XMLElement, xml.localName == "tspan" {
            result.append(parseTspan(xml, id: nextId))
            nextId += 1
        }
    }
    return result
}

private func parseFill(_ node: XMLElement) -> Fill? {
    guard let val = node.attribute(forName: "fill")?.stringValue, val != "none" else { return nil }
    guard let c = parseColor(val) else { return nil }
    let opacity = Double(node.attribute(forName: "fill-opacity")?.stringValue ?? "1") ?? 1.0
    return Fill(color: c, opacity: opacity)
}

private func parseStroke(_ node: XMLElement) -> Stroke? {
    guard let val = node.attribute(forName: "stroke")?.stringValue, val != "none" else { return nil }
    guard let c = parseColor(val) else { return nil }
    let width = toPt(Double(node.attribute(forName: "stroke-width")?.stringValue ?? "1") ?? 1.0)
    let lcStr = node.attribute(forName: "stroke-linecap")?.stringValue ?? "butt"
    let ljStr = node.attribute(forName: "stroke-linejoin")?.stringValue ?? "miter"
    let lc: LineCap = lcStr == "round" ? .round : lcStr == "square" ? .square : .butt
    let lj: LineJoin = ljStr == "round" ? .round : ljStr == "bevel" ? .bevel : .miter
    let opacity = Double(node.attribute(forName: "stroke-opacity")?.stringValue ?? "1") ?? 1.0
    return Stroke(color: c, width: width, linecap: lc, linejoin: lj, opacity: opacity)
}

private func parseTransform(_ node: XMLElement) -> Transform? {
    guard let val = node.attribute(forName: "transform")?.stringValue else { return nil }
    if val.hasPrefix("matrix(") {
        let inner = val.dropFirst(7).dropLast(1)
        let parts = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 6 else { return nil }
        return Transform(a: parts[0], b: parts[1], c: parts[2],
                            d: parts[3], e: toPt(parts[4]), f: toPt(parts[5]))
    }
    if val.hasPrefix("translate(") {
        let inner = val.dropFirst(10).dropLast(1)
        let parts = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty else { return nil }
        let ty = parts.count > 1 ? parts[1] : 0.0
        return Transform.translate(toPt(parts[0]), toPt(ty))
    }
    if val.hasPrefix("rotate(") {
        let inner = val.dropFirst(7).dropLast(1)
        guard let deg = Double(inner.trimmingCharacters(in: .whitespaces)) else { return nil }
        return Transform.rotate(deg)
    }
    if val.hasPrefix("scale(") {
        let inner = val.dropFirst(6).dropLast(1)
        let parts = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty else { return nil }
        let sy = parts.count > 1 ? parts[1] : parts[0]
        return Transform.scale(parts[0], sy)
    }
    return nil
}

private func parseOpacity(_ node: XMLElement) -> Double {
    Double(node.attribute(forName: "opacity")?.stringValue ?? "1") ?? 1.0
}

private func parsePoints(_ s: String) -> [(Double, Double)] {
    s.trimmingCharacters(in: .whitespaces).split(separator: " ").compactMap { pair in
        let parts = pair.split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return (toPt(x), toPt(y))
    }
}

private func parsePathD(_ d: String) -> [PathCommand] {
    var commands: [PathCommand] = []
    let chars = Array(d)
    let len = chars.count
    var pos = 0
    var curX = 0.0, curY = 0.0
    var startX = 0.0, startY = 0.0

    func skipWs() {
        while pos < len && (chars[pos] == " " || chars[pos] == "," || chars[pos] == "\n" || chars[pos] == "\r" || chars[pos] == "\t") {
            pos += 1
        }
    }

    func readNum() -> Double {
        skipWs()
        let start = pos
        if pos < len && (chars[pos] == "-" || chars[pos] == "+") { pos += 1 }
        while pos < len && (chars[pos] >= "0" && chars[pos] <= "9" || chars[pos] == ".") { pos += 1 }
        if pos < len && (chars[pos] == "e" || chars[pos] == "E") {
            pos += 1
            if pos < len && (chars[pos] == "-" || chars[pos] == "+") { pos += 1 }
            while pos < len && chars[pos] >= "0" && chars[pos] <= "9" { pos += 1 }
        }
        return Double(String(chars[start..<pos])) ?? 0
    }

    func update(_ x: Double, _ y: Double) { curX = x; curY = y }

    while pos < len {
        skipWs()
        guard pos < len else { break }
        let c = chars[pos]
        switch c {
        case "M":
            pos += 1; let x = readNum(), y = readNum()
            commands.append(.moveTo(toPt(x), toPt(y)))
            update(x, y); startX = x; startY = y
        case "m":
            pos += 1; let x = curX + readNum(), y = curY + readNum()
            commands.append(.moveTo(toPt(x), toPt(y)))
            update(x, y); startX = x; startY = y
        case "L":
            pos += 1; let x = readNum(), y = readNum()
            commands.append(.lineTo(toPt(x), toPt(y)))
            update(x, y)
        case "l":
            pos += 1; let x = curX + readNum(), y = curY + readNum()
            commands.append(.lineTo(toPt(x), toPt(y)))
            update(x, y)
        case "H":
            pos += 1; let x = readNum()
            commands.append(.lineTo(toPt(x), toPt(curY)))
            curX = x
        case "h":
            pos += 1; let x = curX + readNum()
            commands.append(.lineTo(toPt(x), toPt(curY)))
            curX = x
        case "V":
            pos += 1; let y = readNum()
            commands.append(.lineTo(toPt(curX), toPt(y)))
            curY = y
        case "v":
            pos += 1; let y = curY + readNum()
            commands.append(.lineTo(toPt(curX), toPt(y)))
            curY = y
        case "C":
            pos += 1
            let x1 = readNum(), y1 = readNum()
            let x2 = readNum(), y2 = readNum()
            let x = readNum(), y = readNum()
            commands.append(.curveTo(x1: toPt(x1), y1: toPt(y1), x2: toPt(x2), y2: toPt(y2), x: toPt(x), y: toPt(y)))
            update(x, y)
        case "c":
            pos += 1
            let x1 = curX + readNum(), y1 = curY + readNum()
            let x2 = curX + readNum(), y2 = curY + readNum()
            let x = curX + readNum(), y = curY + readNum()
            commands.append(.curveTo(x1: toPt(x1), y1: toPt(y1), x2: toPt(x2), y2: toPt(y2), x: toPt(x), y: toPt(y)))
            update(x, y)
        case "S":
            pos += 1
            let x2 = readNum(), y2 = readNum()
            let x = readNum(), y = readNum()
            commands.append(.smoothCurveTo(x2: toPt(x2), y2: toPt(y2), x: toPt(x), y: toPt(y)))
            update(x, y)
        case "s":
            pos += 1
            let x2 = curX + readNum(), y2 = curY + readNum()
            let x = curX + readNum(), y = curY + readNum()
            commands.append(.smoothCurveTo(x2: toPt(x2), y2: toPt(y2), x: toPt(x), y: toPt(y)))
            update(x, y)
        case "Q":
            pos += 1
            let x1 = readNum(), y1 = readNum()
            let x = readNum(), y = readNum()
            commands.append(.quadTo(x1: toPt(x1), y1: toPt(y1), x: toPt(x), y: toPt(y)))
            update(x, y)
        case "q":
            pos += 1
            let x1 = curX + readNum(), y1 = curY + readNum()
            let x = curX + readNum(), y = curY + readNum()
            commands.append(.quadTo(x1: toPt(x1), y1: toPt(y1), x: toPt(x), y: toPt(y)))
            update(x, y)
        case "T":
            pos += 1; let x = readNum(), y = readNum()
            commands.append(.smoothQuadTo(toPt(x), toPt(y)))
            update(x, y)
        case "t":
            pos += 1; let x = curX + readNum(), y = curY + readNum()
            commands.append(.smoothQuadTo(toPt(x), toPt(y)))
            update(x, y)
        case "A":
            pos += 1
            let rx = readNum(), ry = readNum()
            let rot = readNum()
            let large = readNum() != 0
            let sweep = readNum() != 0
            let x = readNum(), y = readNum()
            commands.append(.arcTo(rx: toPt(rx), ry: toPt(ry), rotation: rot, largeArc: large, sweep: sweep, x: toPt(x), y: toPt(y)))
            update(x, y)
        case "a":
            pos += 1
            let rx = readNum(), ry = readNum()
            let rot = readNum()
            let large = readNum() != 0
            let sweep = readNum() != 0
            let x = curX + readNum(), y = curY + readNum()
            commands.append(.arcTo(rx: toPt(rx), ry: toPt(ry), rotation: rot, largeArc: large, sweep: sweep, x: toPt(x), y: toPt(y)))
            update(x, y)
        case "Z", "z":
            pos += 1; commands.append(.closePath)
            curX = startX; curY = startY
        default: pos += 1
        }
    }
    return commands
}

private func attrF(_ node: XMLElement, _ name: String, _ def: Double = 0) -> Double {
    Double(node.attribute(forName: name)?.stringValue ?? "") ?? def
}

private func parseElement(_ node: XMLNode) -> Element? {
    guard let elem = node as? XMLElement, let tag = elem.localName else { return nil }

    let fill = parseFill(elem)
    let stroke = parseStroke(elem)
    let opacity = parseOpacity(elem)
    let transform = parseTransform(elem)

    switch tag {
    case "line":
        return .line(Line(
            x1: toPt(attrF(elem, "x1")), y1: toPt(attrF(elem, "y1")),
            x2: toPt(attrF(elem, "x2")), y2: toPt(attrF(elem, "y2")),
            stroke: stroke, opacity: opacity, transform: transform))

    case "rect":
        return .rect(Rect(
            x: toPt(attrF(elem, "x")), y: toPt(attrF(elem, "y")),
            width: toPt(attrF(elem, "width")), height: toPt(attrF(elem, "height")),
            rx: toPt(attrF(elem, "rx")), ry: toPt(attrF(elem, "ry")),
            fill: fill, stroke: stroke, opacity: opacity, transform: transform))

    case "circle":
        return .circle(Circle(
            cx: toPt(attrF(elem, "cx")), cy: toPt(attrF(elem, "cy")),
            r: toPt(attrF(elem, "r")),
            fill: fill, stroke: stroke, opacity: opacity, transform: transform))

    case "ellipse":
        return .ellipse(Ellipse(
            cx: toPt(attrF(elem, "cx")), cy: toPt(attrF(elem, "cy")),
            rx: toPt(attrF(elem, "rx")), ry: toPt(attrF(elem, "ry")),
            fill: fill, stroke: stroke, opacity: opacity, transform: transform))

    case "polyline":
        let pts = parsePoints(elem.attribute(forName: "points")?.stringValue ?? "")
        return .polyline(Polyline(points: pts, fill: fill, stroke: stroke,
                                      opacity: opacity, transform: transform))

    case "polygon":
        let pts = parsePoints(elem.attribute(forName: "points")?.stringValue ?? "")
        return .polygon(Polygon(points: pts, fill: fill, stroke: stroke,
                                    opacity: opacity, transform: transform))

    case "path":
        let d = parsePathD(elem.attribute(forName: "d")?.stringValue ?? "")
        return .path(Path(d: d, fill: fill, stroke: stroke,
                              opacity: opacity, transform: transform))

    case "text":
        let ff = elem.attribute(forName: "font-family")?.stringValue ?? "sans-serif"
        let fs = toPt(attrF(elem, "font-size", 16.0))
        let fw = elem.attribute(forName: "font-weight")?.stringValue ?? "normal"
        let fst = elem.attribute(forName: "font-style")?.stringValue ?? "normal"
        let td = elem.attribute(forName: "text-decoration")?.stringValue ?? "none"
        let tt = elem.attribute(forName: "text-transform")?.stringValue ?? ""
        let fv = elem.attribute(forName: "font-variant")?.stringValue ?? ""
        let bs = elem.attribute(forName: "baseline-shift")?.stringValue ?? ""
        let lh = elem.attribute(forName: "line-height")?.stringValue ?? ""
        let ls = elem.attribute(forName: "letter-spacing")?.stringValue ?? ""
        let lang = elem.attribute(forName: "xml:lang")?.stringValue
                ?? elem.attribute(forName: "lang")?.stringValue ?? ""
        let aa = elem.attribute(forName: "urn:jas:1:aa-mode")?.stringValue ?? ""
        let rotate = elem.attribute(forName: "rotate")?.stringValue ?? ""
        let hScale = elem.attribute(forName: "horizontal-scale")?.stringValue ?? ""
        let vScale = elem.attribute(forName: "vertical-scale")?.stringValue ?? ""
        let kern = elem.attribute(forName: "urn:jas:1:kerning-mode")?.stringValue ?? ""
        // Check for <textPath> child
        if let children = elem.children {
            for child in children {
                guard let tpElem = child as? XMLElement, tpElem.localName == "textPath" else { continue }
                let dStr = tpElem.attribute(forName: "path")?.stringValue
                        ?? tpElem.attribute(forName: "d")?.stringValue ?? ""
                let d = parsePathD(dStr)
                var startOffset = 0.0
                let offsetStr = tpElem.attribute(forName: "startOffset")?.stringValue ?? "0"
                if offsetStr.hasSuffix("%") {
                    startOffset = (Double(String(offsetStr.dropLast())) ?? 0) / 100.0
                } else {
                    startOffset = Double(offsetStr) ?? 0
                }
                // Prefer <tspan> children inside the <textPath>; fall
                // back to flat string content when none are present.
                let tpTspanChildren = collectTspanChildren(tpElem)
                if !tpTspanChildren.isEmpty {
                    return .textPath(TextPath(
                        d: d, tspans: tpTspanChildren, startOffset: startOffset,
                        fontFamily: ff, fontSize: fs,
                        fontWeight: fw, fontStyle: fst, textDecoration: td,
                        textTransform: tt, fontVariant: fv,
                        baselineShift: bs, lineHeight: lh, letterSpacing: ls,
                        xmlLang: lang, aaMode: aa, rotate: rotate,
                        horizontalScale: hScale, verticalScale: vScale, kerning: kern,
                        fill: fill, stroke: stroke, opacity: opacity, transform: transform))
                }
                let tpContent = tpElem.stringValue ?? ""
                return .textPath(TextPath(
                    d: d, content: tpContent, startOffset: startOffset,
                    fontFamily: ff, fontSize: fs,
                    fontWeight: fw, fontStyle: fst, textDecoration: td,
                    textTransform: tt, fontVariant: fv,
                    baselineShift: bs, lineHeight: lh, letterSpacing: ls,
                    xmlLang: lang, aaMode: aa, rotate: rotate,
                    horizontalScale: hScale, verticalScale: vScale, kerning: kern,
                    fill: fill, stroke: stroke, opacity: opacity, transform: transform))
            }
        }
        let tspanChildren = collectTspanChildren(elem)
        let content = tspanChildren.isEmpty
            ? (elem.stringValue ?? "")
            : tspanChildren.map(\.content).joined()
        var tw = 0.0
        if let style = elem.attribute(forName: "style")?.stringValue {
            if let range = style.range(of: #"inline-size:\s*([\d.]+)px"#, options: .regularExpression) {
                let match = style[range]
                if let numRange = match.range(of: #"[\d.]+"#, options: .regularExpression) {
                    tw = toPt(Double(match[numRange]) ?? 0)
                }
            }
        }
        var th = 0.0
        if tw > 0 {
            let lines = max(1, Int(Double(content.count) * fs * approxCharWidthFactor / tw) + 1)
            th = Double(lines) * fs * 1.2
        }
        // SVG `y` is the baseline of the first line; convert to the
        // layout-box top by subtracting the ascent (0.8 * fs).
        let svgY = toPt(attrF(elem, "y"))
        if !tspanChildren.isEmpty {
            return .text(Text(
                x: toPt(attrF(elem, "x")), y: svgY - fs * 0.8,
                tspans: tspanChildren,
                fontFamily: ff, fontSize: fs,
                fontWeight: fw, fontStyle: fst, textDecoration: td,
                textTransform: tt, fontVariant: fv,
                baselineShift: bs, lineHeight: lh, letterSpacing: ls,
                xmlLang: lang, aaMode: aa, rotate: rotate,
                horizontalScale: hScale, verticalScale: vScale, kerning: kern,
                width: tw, height: th,
                fill: fill, stroke: stroke, opacity: opacity, transform: transform))
        }
        return .text(Text(
            x: toPt(attrF(elem, "x")), y: svgY - fs * 0.8,
            content: content, fontFamily: ff, fontSize: fs,
            fontWeight: fw, fontStyle: fst, textDecoration: td,
            textTransform: tt, fontVariant: fv,
            baselineShift: bs, lineHeight: lh, letterSpacing: ls,
            xmlLang: lang, aaMode: aa, rotate: rotate,
            horizontalScale: hScale, verticalScale: vScale, kerning: kern,
            width: tw, height: th,
            fill: fill, stroke: stroke, opacity: opacity, transform: transform))

    case "g":
        var children: [Element] = []
        if let childNodes = elem.children {
            for child in childNodes {
                if let parsed = parseElement(child) {
                    children.append(parsed)
                }
            }
        }
        let label = elem.attribute(forName: "label")?.stringValue
                  ?? elem.attribute(forName: "inkscape:label")?.stringValue
        if let name = label {
            return .layer(Layer(name: name, children: children,
                                    opacity: opacity, transform: transform))
        }
        return .group(Group(children: children,
                                opacity: opacity, transform: transform))

    default:
        return nil
    }
}

public func svgToDocument(_ svg: String) -> Document {
    guard let data = svg.data(using: .utf8) else {
        print("Warning: SVG string is not valid UTF-8")
        return Document(layers: [Layer(children: [])])
    }
    guard let xmlDoc = try? XMLDocument(data: data, options: []) else {
        print("Warning: Failed to parse SVG XML")
        return Document(layers: [Layer(children: [])])
    }
    guard let root = xmlDoc.rootElement() else {
        return Document(layers: [Layer(children: [])])
    }

    var layers: [Layer] = []
    if let childNodes = root.children {
        for child in childNodes {
            guard let elem = parseElement(child) else { continue }
            switch elem {
            case .layer(let l):
                layers.append(l)
            case .group(let g):
                layers.append(Layer(name: "", children: g.children,
                                        opacity: g.opacity, transform: g.transform))
            default:
                if layers.isEmpty || !layers.last!.name.isEmpty {
                    layers.append(Layer(name: "", children: [elem]))
                } else {
                    let last = layers.removeLast()
                    layers.append(Layer(name: "", children: last.children + [elem],
                                            opacity: last.opacity, transform: last.transform))
                }
            }
        }
    }
    if layers.isEmpty { layers = [Layer(children: [])] }
    return normalizeDocument(Document(layers: layers))
}

