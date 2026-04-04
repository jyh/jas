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

private func colorStr(_ c: JasColor) -> String {
    let r = Int(round(c.r * 255))
    let g = Int(round(c.g * 255))
    let b = Int(round(c.b * 255))
    if c.a < 1.0 { return "rgba(\(r),\(g),\(b),\(fmt(c.a)))" }
    return "rgb(\(r),\(g),\(b))"
}

private func escapeXml(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
}

private func fillAttrs(_ fill: JasFill?) -> String {
    guard let fill = fill else { return " fill=\"none\"" }
    return " fill=\"\(colorStr(fill.color))\""
}

private func strokeAttrs(_ stroke: JasStroke?) -> String {
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
    return s
}

private func transformAttr(_ t: JasTransform?) -> String {
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

private func elementSvg(_ elem: Element, indent: String) -> String {
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
        return "\(indent)<text x=\"\(fmt(px(v.x)))\" y=\"\(fmt(px(v.y)))\"" +
            " font-family=\"\(escapeXml(v.fontFamily))\" font-size=\"\(fmt(px(v.fontSize)))\"" +
            "\(fillAttrs(v.fill))\(strokeAttrs(v.stroke))" +
            "\(opacityAttr(v.opacity))\(transformAttr(v.transform))>" +
            "\(escapeXml(v.content))</text>"

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

public func documentToSvg(_ doc: JasDocument) -> String {
    let b = doc.bounds
    let vb = "\(fmt(px(b.x))) \(fmt(px(b.y))) \(fmt(px(b.width))) \(fmt(px(b.height)))"
    var lines = [
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(vb)\" width=\"\(fmt(px(b.width)))\" height=\"\(fmt(px(b.height)))\">",
    ]
    for layer in doc.layers {
        lines.append(elementSvg(.layer(layer), indent: "  "))
    }
    lines.append("</svg>")
    return lines.joined(separator: "\n")
}
