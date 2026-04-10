import Foundation

/// Canonical Test JSON serialization for cross-language equivalence testing.
///
/// See `CROSS_LANGUAGE_TESTING.md` at the repository root for the full
/// specification.  Every semantic document value has exactly one JSON
/// string representation, so byte-for-byte comparison of the output is a
/// valid equivalence check.

// MARK: - Float formatting

/// Round to 4 decimal places, always include decimal point.
private func fmt(_ v: Double) -> String {
    let rounded = (v * 10000.0).rounded() / 10000.0
    if rounded == rounded.rounded(.towardZero) && rounded.truncatingRemainder(dividingBy: 1) == 0 {
        return String(format: "%.1f", rounded)
    }
    var s = String(format: "%.4f", rounded)
    // Strip trailing zeros but keep at least one digit after decimal.
    while s.hasSuffix("0") && !s.hasSuffix(".0") {
        s.removeLast()
    }
    return s
}

// MARK: - JSON builder with sorted keys

private class JsonObj {
    private var entries: [(String, String)] = []

    func str(_ key: String, _ v: String) {
        let escaped = v.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        entries.append((key, "\"\(escaped)\""))
    }

    func num(_ key: String, _ v: Double) {
        entries.append((key, fmt(v)))
    }

    func int(_ key: String, _ v: Int) {
        entries.append((key, "\(v)"))
    }

    func bool(_ key: String, _ v: Bool) {
        entries.append((key, v ? "true" : "false"))
    }

    func null(_ key: String) {
        entries.append((key, "null"))
    }

    func raw(_ key: String, _ json: String) {
        entries.append((key, json))
    }

    func build() -> String {
        entries.sort { $0.0 < $1.0 }
        let pairs = entries.map { "\"\($0.0)\":\($0.1)" }
        return "{\(pairs.joined(separator: ","))}"
    }
}

private func jsonArray(_ items: [String]) -> String {
    "[\(items.joined(separator: ","))]"
}

// MARK: - Type serializers

private func colorJson(_ c: Color) -> String {
    let o = JsonObj()
    o.num("a", c.a)
    o.num("b", c.b)
    o.num("g", c.g)
    o.num("r", c.r)
    return o.build()
}

private func fillJson(_ fill: Fill?) -> String {
    guard let f = fill else { return "null" }
    let o = JsonObj()
    o.raw("color", colorJson(f.color))
    return o.build()
}

private func strokeJson(_ stroke: Stroke?) -> String {
    guard let s = stroke else { return "null" }
    let o = JsonObj()
    o.raw("color", colorJson(s.color))
    o.str("linecap", linecapStr(s.linecap))
    o.str("linejoin", linejoinStr(s.linejoin))
    o.num("width", s.width)
    return o.build()
}

private func linecapStr(_ lc: LineCap) -> String {
    switch lc {
    case .butt: "butt"
    case .round: "round"
    case .square: "square"
    }
}

private func linejoinStr(_ lj: LineJoin) -> String {
    switch lj {
    case .miter: "miter"
    case .round: "round"
    case .bevel: "bevel"
    }
}

private func transformJson(_ t: Transform?) -> String {
    guard let t = t else { return "null" }
    let o = JsonObj()
    o.num("a", t.a)
    o.num("b", t.b)
    o.num("c", t.c)
    o.num("d", t.d)
    o.num("e", t.e)
    o.num("f", t.f)
    return o.build()
}

private func visibilityStr(_ v: Visibility) -> String {
    switch v {
    case .invisible: "invisible"
    case .outline: "outline"
    case .preview: "preview"
    }
}

private func commonFields(_ o: JsonObj, _ opacity: Double, _ transform: Transform?,
                           _ locked: Bool, _ visibility: Visibility) {
    o.bool("locked", locked)
    o.num("opacity", opacity)
    o.raw("transform", transformJson(transform))
    o.str("visibility", visibilityStr(visibility))
}

private func pathCommandJson(_ cmd: PathCommand) -> String {
    let o = JsonObj()
    switch cmd {
    case .moveTo(let x, let y):
        o.str("cmd", "M")
        o.num("x", x)
        o.num("y", y)
    case .lineTo(let x, let y):
        o.str("cmd", "L")
        o.num("x", x)
        o.num("y", y)
    case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
        o.str("cmd", "C")
        o.num("x", x)
        o.num("x1", x1)
        o.num("x2", x2)
        o.num("y", y)
        o.num("y1", y1)
        o.num("y2", y2)
    case .smoothCurveTo(let x2, let y2, let x, let y):
        o.str("cmd", "S")
        o.num("x", x)
        o.num("x2", x2)
        o.num("y", y)
        o.num("y2", y2)
    case .quadTo(let x1, let y1, let x, let y):
        o.str("cmd", "Q")
        o.num("x", x)
        o.num("x1", x1)
        o.num("y", y)
        o.num("y1", y1)
    case .smoothQuadTo(let x, let y):
        o.str("cmd", "T")
        o.num("x", x)
        o.num("y", y)
    case .arcTo(let rx, let ry, let rotation, let largeArc, let sweep, let x, let y):
        o.str("cmd", "A")
        o.bool("large_arc", largeArc)
        o.num("rx", rx)
        o.num("ry", ry)
        o.bool("sweep", sweep)
        o.num("x", x)
        o.num("x_rotation", rotation)
        o.num("y", y)
    case .closePath:
        o.str("cmd", "Z")
    }
    return o.build()
}

private func pointsJson(_ points: [(Double, Double)]) -> String {
    let items = points.map { "[\(fmt($0.0)),\(fmt($0.1))]" }
    return jsonArray(items)
}

// MARK: - Element serializer

private func elementJson(_ elem: Element) -> String {
    let o = JsonObj()
    switch elem {
    case .line(let e):
        o.str("type", "line")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility)
        o.raw("stroke", strokeJson(e.stroke))
        o.num("x1", e.x1)
        o.num("x2", e.x2)
        o.num("y1", e.y1)
        o.num("y2", e.y2)
    case .rect(let e):
        o.str("type", "rect")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility)
        o.raw("fill", fillJson(e.fill))
        o.num("height", e.height)
        o.num("rx", e.rx)
        o.num("ry", e.ry)
        o.raw("stroke", strokeJson(e.stroke))
        o.num("width", e.width)
        o.num("x", e.x)
        o.num("y", e.y)
    case .circle(let e):
        o.str("type", "circle")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility)
        o.num("cx", e.cx)
        o.num("cy", e.cy)
        o.raw("fill", fillJson(e.fill))
        o.num("r", e.r)
        o.raw("stroke", strokeJson(e.stroke))
    case .ellipse(let e):
        o.str("type", "ellipse")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility)
        o.num("cx", e.cx)
        o.num("cy", e.cy)
        o.raw("fill", fillJson(e.fill))
        o.num("rx", e.rx)
        o.num("ry", e.ry)
        o.raw("stroke", strokeJson(e.stroke))
    case .polyline(let e):
        o.str("type", "polyline")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility)
        o.raw("fill", fillJson(e.fill))
        o.raw("points", pointsJson(e.points))
        o.raw("stroke", strokeJson(e.stroke))
    case .polygon(let e):
        o.str("type", "polygon")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility)
        o.raw("fill", fillJson(e.fill))
        o.raw("points", pointsJson(e.points))
        o.raw("stroke", strokeJson(e.stroke))
    case .path(let e):
        o.str("type", "path")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility)
        let cmds = e.d.map { pathCommandJson($0) }
        o.raw("d", jsonArray(cmds))
        o.raw("fill", fillJson(e.fill))
        o.raw("stroke", strokeJson(e.stroke))
    case .text(let e):
        o.str("type", "text")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility)
        o.str("content", e.content)
        o.raw("fill", fillJson(e.fill))
        o.str("font_family", e.fontFamily)
        o.num("font_size", e.fontSize)
        o.str("font_style", e.fontStyle)
        o.str("font_weight", e.fontWeight)
        o.num("height", e.height)
        o.raw("stroke", strokeJson(e.stroke))
        o.str("text_decoration", e.textDecoration)
        o.num("width", e.width)
        o.num("x", e.x)
        o.num("y", e.y)
    case .textPath(let e):
        o.str("type", "text_path")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility)
        o.str("content", e.content)
        let cmds = e.d.map { pathCommandJson($0) }
        o.raw("d", jsonArray(cmds))
        o.raw("fill", fillJson(e.fill))
        o.str("font_family", e.fontFamily)
        o.num("font_size", e.fontSize)
        o.str("font_style", e.fontStyle)
        o.str("font_weight", e.fontWeight)
        o.num("start_offset", e.startOffset)
        o.raw("stroke", strokeJson(e.stroke))
        o.str("text_decoration", e.textDecoration)
    case .group(let e):
        o.str("type", "group")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility)
        let children = e.children.map { elementJson($0) }
        o.raw("children", jsonArray(children))
    case .layer(let e):
        o.str("type", "layer")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility)
        let children = e.children.map { elementJson($0) }
        o.raw("children", jsonArray(children))
        o.str("name", e.name)
    }
    return o.build()
}

// MARK: - Selection serializer

private func selectionJson(_ sel: [ElementSelection]) -> String {
    var entries: [(path: [Int], json: String)] = sel.map { es in
        let o = JsonObj()
        switch es.kind {
        case .all:
            o.str("kind", "all")
        case .partial(let cps):
            let indices = cps.toArray().map { "\($0)" }
            o.raw("kind", "{\"partial\":[\(indices.joined(separator: ","))]}")
        }
        let path = es.path.map { "\($0)" }
        o.raw("path", "[\(path.joined(separator: ","))]")
        return (es.path, o.build())
    }
    // Sort by path lexicographically.
    entries.sort { a, b in
        for (ai, bi) in zip(a.path, b.path) {
            if ai != bi { return ai < bi }
        }
        return a.path.count < b.path.count
    }
    let items = entries.map { $0.json }
    return jsonArray(items)
}

// MARK: - Document serializer (public API)

/// Serialize a Document to canonical test JSON.
///
/// The output is a compact JSON string with sorted keys and normalized
/// floats, suitable for byte-for-byte cross-language comparison.
public func documentToTestJson(_ doc: Document) -> String {
    let layers = doc.layers.map { elementJson(.layer($0)) }
    let o = JsonObj()
    o.raw("layers", jsonArray(layers))
    o.int("selected_layer", doc.selectedLayer)
    o.raw("selection", selectionJson(Array(doc.selection)))
    return o.build()
}
