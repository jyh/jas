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
        let areaAttrs = v.isAreaText
            ? " style=\"inline-size: \(fmt(px(v.width)))px; white-space: pre-wrap;\""
            : ""
        return "\(indent)<text x=\"\(fmt(px(v.x)))\" y=\"\(fmt(px(v.y)))\"" +
            " font-family=\"\(escapeXml(v.fontFamily))\" font-size=\"\(fmt(px(v.fontSize)))\"" +
            "\(areaAttrs)" +
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

private func parseColor(_ s: String) -> JasColor? {
    let s = s.trimmingCharacters(in: .whitespaces)
    if s == "none" { return nil }
    if s.hasPrefix("rgba(") {
        let inner = s.dropFirst(5).dropLast(1)
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 4,
              let r = Int(parts[0]), let g = Int(parts[1]),
              let b = Int(parts[2]), let a = Double(parts[3]) else { return nil }
        return JasColor(r: Double(r) / 255.0, g: Double(g) / 255.0, b: Double(b) / 255.0, a: a)
    }
    if s.hasPrefix("rgb(") {
        let inner = s.dropFirst(4).dropLast(1)
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3,
              let r = Int(parts[0]), let g = Int(parts[1]), let b = Int(parts[2]) else { return nil }
        return JasColor(r: Double(r) / 255.0, g: Double(g) / 255.0, b: Double(b) / 255.0)
    }
    return nil
}

private func parseFill(_ node: XMLElement) -> JasFill? {
    guard let val = node.attribute(forName: "fill")?.stringValue, val != "none" else { return nil }
    guard let c = parseColor(val) else { return nil }
    return JasFill(color: c)
}

private func parseStroke(_ node: XMLElement) -> JasStroke? {
    guard let val = node.attribute(forName: "stroke")?.stringValue, val != "none" else { return nil }
    guard let c = parseColor(val) else { return nil }
    let width = toPt(Double(node.attribute(forName: "stroke-width")?.stringValue ?? "1") ?? 1.0)
    let lcStr = node.attribute(forName: "stroke-linecap")?.stringValue ?? "butt"
    let ljStr = node.attribute(forName: "stroke-linejoin")?.stringValue ?? "miter"
    let lc: LineCap = lcStr == "round" ? .round : lcStr == "square" ? .square : .butt
    let lj: LineJoin = ljStr == "round" ? .round : ljStr == "bevel" ? .bevel : .miter
    return JasStroke(color: c, width: width, linecap: lc, linejoin: lj)
}

private func parseTransform(_ node: XMLElement) -> JasTransform? {
    guard let val = node.attribute(forName: "transform")?.stringValue else { return nil }
    if val.hasPrefix("matrix(") {
        let inner = val.dropFirst(7).dropLast(1)
        let parts = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 6 else { return nil }
        return JasTransform(a: parts[0], b: parts[1], c: parts[2],
                            d: parts[3], e: toPt(parts[4]), f: toPt(parts[5]))
    }
    if val.hasPrefix("translate(") {
        let inner = val.dropFirst(10).dropLast(1)
        let parts = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty else { return nil }
        let ty = parts.count > 1 ? parts[1] : 0.0
        return JasTransform.translate(toPt(parts[0]), toPt(ty))
    }
    if val.hasPrefix("rotate(") {
        let inner = val.dropFirst(7).dropLast(1)
        guard let deg = Double(inner.trimmingCharacters(in: .whitespaces)) else { return nil }
        return JasTransform.rotate(deg)
    }
    if val.hasPrefix("scale(") {
        let inner = val.dropFirst(6).dropLast(1)
        let parts = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty else { return nil }
        let sy = parts.count > 1 ? parts[1] : parts[0]
        return JasTransform.scale(parts[0], sy)
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

    while pos < len {
        skipWs()
        guard pos < len else { break }
        let c = chars[pos]
        switch c {
        case "M": pos += 1; commands.append(.moveTo(toPt(readNum()), toPt(readNum())))
        case "L": pos += 1; commands.append(.lineTo(toPt(readNum()), toPt(readNum())))
        case "C":
            pos += 1
            let x1 = toPt(readNum()), y1 = toPt(readNum())
            let x2 = toPt(readNum()), y2 = toPt(readNum())
            let x = toPt(readNum()), y = toPt(readNum())
            commands.append(.curveTo(x1: x1, y1: y1, x2: x2, y2: y2, x: x, y: y))
        case "S":
            pos += 1
            let x2 = toPt(readNum()), y2 = toPt(readNum())
            let x = toPt(readNum()), y = toPt(readNum())
            commands.append(.smoothCurveTo(x2: x2, y2: y2, x: x, y: y))
        case "Q":
            pos += 1
            let x1 = toPt(readNum()), y1 = toPt(readNum())
            let x = toPt(readNum()), y = toPt(readNum())
            commands.append(.quadTo(x1: x1, y1: y1, x: x, y: y))
        case "T": pos += 1; commands.append(.smoothQuadTo(toPt(readNum()), toPt(readNum())))
        case "A":
            pos += 1
            let rx = toPt(readNum()), ry = toPt(readNum())
            let rot = readNum()
            let large = readNum() != 0
            let sweep = readNum() != 0
            let x = toPt(readNum()), y = toPt(readNum())
            commands.append(.arcTo(rx: rx, ry: ry, rotation: rot, largeArc: large, sweep: sweep, x: x, y: y))
        case "Z", "z": pos += 1; commands.append(.closePath)
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
        return .line(JasLine(
            x1: toPt(attrF(elem, "x1")), y1: toPt(attrF(elem, "y1")),
            x2: toPt(attrF(elem, "x2")), y2: toPt(attrF(elem, "y2")),
            stroke: stroke, opacity: opacity, transform: transform))

    case "rect":
        return .rect(JasRect(
            x: toPt(attrF(elem, "x")), y: toPt(attrF(elem, "y")),
            width: toPt(attrF(elem, "width")), height: toPt(attrF(elem, "height")),
            rx: toPt(attrF(elem, "rx")), ry: toPt(attrF(elem, "ry")),
            fill: fill, stroke: stroke, opacity: opacity, transform: transform))

    case "circle":
        return .circle(JasCircle(
            cx: toPt(attrF(elem, "cx")), cy: toPt(attrF(elem, "cy")),
            r: toPt(attrF(elem, "r")),
            fill: fill, stroke: stroke, opacity: opacity, transform: transform))

    case "ellipse":
        return .ellipse(JasEllipse(
            cx: toPt(attrF(elem, "cx")), cy: toPt(attrF(elem, "cy")),
            rx: toPt(attrF(elem, "rx")), ry: toPt(attrF(elem, "ry")),
            fill: fill, stroke: stroke, opacity: opacity, transform: transform))

    case "polyline":
        let pts = parsePoints(elem.attribute(forName: "points")?.stringValue ?? "")
        return .polyline(JasPolyline(points: pts, fill: fill, stroke: stroke,
                                      opacity: opacity, transform: transform))

    case "polygon":
        let pts = parsePoints(elem.attribute(forName: "points")?.stringValue ?? "")
        return .polygon(JasPolygon(points: pts, fill: fill, stroke: stroke,
                                    opacity: opacity, transform: transform))

    case "path":
        let d = parsePathD(elem.attribute(forName: "d")?.stringValue ?? "")
        return .path(JasPath(d: d, fill: fill, stroke: stroke,
                              opacity: opacity, transform: transform))

    case "text":
        let content = elem.stringValue ?? ""
        let ff = elem.attribute(forName: "font-family")?.stringValue ?? "sans-serif"
        let fs = toPt(attrF(elem, "font-size", 16.0))
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
            let lines = max(1, Int(Double(content.count) * fs * 0.6 / tw) + 1)
            th = Double(lines) * fs * 1.2
        }
        return .text(JasText(
            x: toPt(attrF(elem, "x")), y: toPt(attrF(elem, "y")),
            content: content, fontFamily: ff, fontSize: fs,
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
            return .layer(JasLayer(name: name, children: children,
                                    opacity: opacity, transform: transform))
        }
        return .group(JasGroup(children: children,
                                opacity: opacity, transform: transform))

    default:
        return nil
    }
}

public func svgToDocument(_ svg: String) -> JasDocument {
    guard let data = svg.data(using: .utf8),
          let xmlDoc = try? XMLDocument(data: data, options: []) else {
        return JasDocument(layers: [JasLayer(children: [])])
    }
    guard let root = xmlDoc.rootElement() else {
        return JasDocument(layers: [JasLayer(children: [])])
    }

    var layers: [JasLayer] = []
    if let childNodes = root.children {
        for child in childNodes {
            guard let elem = parseElement(child) else { continue }
            switch elem {
            case .layer(let l):
                layers.append(l)
            case .group(let g):
                layers.append(JasLayer(name: "", children: g.children,
                                        opacity: g.opacity, transform: g.transform))
            default:
                if layers.isEmpty || !layers.last!.name.isEmpty {
                    layers.append(JasLayer(name: "", children: [elem]))
                } else {
                    let last = layers.removeLast()
                    layers.append(JasLayer(name: "", children: last.children + [elem],
                                            opacity: last.opacity, transform: last.transform))
                }
            }
        }
    }
    if layers.isEmpty { layers = [JasLayer(children: [])] }
    return JasDocument(layers: layers)
}
