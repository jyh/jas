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
    switch c {
    case .rgb(let r, let g, let b, let a):
        o.num("a", a)
        o.num("b", b)
        o.num("g", g)
        o.num("r", r)
        o.str("space", "rgb")
    case .hsb(let h, let s, let b, let a):
        o.num("a", a)
        o.num("b", b)
        o.num("h", h)
        o.num("s", s)
        o.str("space", "hsb")
    case .cmyk(let c, let m, let y, let k, let a):
        o.num("a", a)
        o.num("c", c)
        o.num("k", k)
        o.num("m", m)
        o.str("space", "cmyk")
        o.num("y", y)
    }
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

// MARK: - JSON → Document parser (inverse of documentToTestJson)

private func parseF(_ v: Any?) -> Double {
    if let n = v as? NSNumber { return n.doubleValue }
    return 0.0
}

private func parseColor(_ v: Any?) -> Color {
    guard let d = v as? [String: Any] else { return Color(r: 0, g: 0, b: 0, a: 1) }
    let space = d["space"] as? String ?? "rgb"
    switch space {
    case "hsb":
        return .hsb(h: parseF(d["h"]), s: parseF(d["s"]), b: parseF(d["b"]), a: parseF(d["a"]))
    case "cmyk":
        return .cmyk(c: parseF(d["c"]), m: parseF(d["m"]), y: parseF(d["y"]), k: parseF(d["k"]), a: parseF(d["a"]))
    default:
        return Color(r: parseF(d["r"]), g: parseF(d["g"]), b: parseF(d["b"]), a: parseF(d["a"]))
    }
}

private func parseFill(_ v: Any?) -> Fill? {
    guard let d = v as? [String: Any] else { return nil }
    return Fill(color: parseColor(d["color"]))
}

private func parseStroke(_ v: Any?) -> Stroke? {
    guard let d = v as? [String: Any] else { return nil }
    let lc: LineCap
    switch d["linecap"] as? String ?? "butt" {
    case "round": lc = .round
    case "square": lc = .square
    default: lc = .butt
    }
    let lj: LineJoin
    switch d["linejoin"] as? String ?? "miter" {
    case "round": lj = .round
    case "bevel": lj = .bevel
    default: lj = .miter
    }
    return Stroke(color: parseColor(d["color"]), width: parseF(d["width"]), linecap: lc, linejoin: lj)
}

private func parseTransform(_ v: Any?) -> Transform? {
    guard let d = v as? [String: Any] else { return nil }
    return Transform(a: parseF(d["a"]), b: parseF(d["b"]), c: parseF(d["c"]),
                     d: parseF(d["d"]), e: parseF(d["e"]), f: parseF(d["f"]))
}

private func parseVisibility(_ v: Any?) -> Visibility {
    switch v as? String ?? "preview" {
    case "invisible": return .invisible
    case "outline": return .outline
    default: return .preview
    }
}

private func parseCommon(_ d: [String: Any]) -> (Double, Transform?, Bool, Visibility) {
    (parseF(d["opacity"]),
     parseTransform(d["transform"]),
     d["locked"] as? Bool ?? false,
     parseVisibility(d["visibility"]))
}

private func parsePathCommands(_ v: Any?) -> [PathCommand] {
    guard let arr = v as? [[String: Any]] else { return [] }
    return arr.map { c in
        switch c["cmd"] as? String ?? "" {
        case "M": return .moveTo(parseF(c["x"]), parseF(c["y"]))
        case "L": return .lineTo(parseF(c["x"]), parseF(c["y"]))
        case "C": return .curveTo(x1: parseF(c["x1"]), y1: parseF(c["y1"]),
                                  x2: parseF(c["x2"]), y2: parseF(c["y2"]),
                                  x: parseF(c["x"]), y: parseF(c["y"]))
        case "S": return .smoothCurveTo(x2: parseF(c["x2"]), y2: parseF(c["y2"]),
                                        x: parseF(c["x"]), y: parseF(c["y"]))
        case "Q": return .quadTo(x1: parseF(c["x1"]), y1: parseF(c["y1"]),
                                 x: parseF(c["x"]), y: parseF(c["y"]))
        case "T": return .smoothQuadTo(parseF(c["x"]), parseF(c["y"]))
        case "A": return .arcTo(rx: parseF(c["rx"]), ry: parseF(c["ry"]),
                                rotation: parseF(c["x_rotation"]),
                                largeArc: c["large_arc"] as? Bool ?? false,
                                sweep: c["sweep"] as? Bool ?? false,
                                x: parseF(c["x"]), y: parseF(c["y"]))
        default: return .closePath
        }
    }
}

private func parsePoints(_ v: Any?) -> [(Double, Double)] {
    guard let arr = v as? [[Any]] else { return [] }
    return arr.map { p in
        (parseF(p[0]), parseF(p[1]))
    }
}

private func parseElement(_ v: Any?) -> Element {
    guard let d = v as? [String: Any] else { fatalError("Expected JSON object for element") }
    let typ = d["type"] as? String ?? ""
    let (opacity, transform, locked, visibility) = parseCommon(d)

    switch typ {
    case "line":
        return .line(Line(x1: parseF(d["x1"]), y1: parseF(d["y1"]),
                          x2: parseF(d["x2"]), y2: parseF(d["y2"]),
                          stroke: parseStroke(d["stroke"]),
                          opacity: opacity, transform: transform, locked: locked,
                          visibility: visibility))
    case "rect":
        return .rect(Rect(x: parseF(d["x"]), y: parseF(d["y"]),
                          width: parseF(d["width"]), height: parseF(d["height"]),
                          rx: parseF(d["rx"]), ry: parseF(d["ry"]),
                          fill: parseFill(d["fill"]), stroke: parseStroke(d["stroke"]),
                          opacity: opacity, transform: transform, locked: locked,
                          visibility: visibility))
    case "circle":
        return .circle(Circle(cx: parseF(d["cx"]), cy: parseF(d["cy"]), r: parseF(d["r"]),
                              fill: parseFill(d["fill"]), stroke: parseStroke(d["stroke"]),
                              opacity: opacity, transform: transform, locked: locked,
                              visibility: visibility))
    case "ellipse":
        return .ellipse(Ellipse(cx: parseF(d["cx"]), cy: parseF(d["cy"]),
                                rx: parseF(d["rx"]), ry: parseF(d["ry"]),
                                fill: parseFill(d["fill"]), stroke: parseStroke(d["stroke"]),
                                opacity: opacity, transform: transform, locked: locked,
                                visibility: visibility))
    case "polyline":
        return .polyline(Polyline(points: parsePoints(d["points"]),
                                  fill: parseFill(d["fill"]), stroke: parseStroke(d["stroke"]),
                                  opacity: opacity, transform: transform, locked: locked,
                                  visibility: visibility))
    case "polygon":
        return .polygon(Polygon(points: parsePoints(d["points"]),
                                fill: parseFill(d["fill"]), stroke: parseStroke(d["stroke"]),
                                opacity: opacity, transform: transform, locked: locked,
                                visibility: visibility))
    case "path":
        return .path(Path(d: parsePathCommands(d["d"]),
                          fill: parseFill(d["fill"]), stroke: parseStroke(d["stroke"]),
                          opacity: opacity, transform: transform, locked: locked,
                          visibility: visibility))
    case "text":
        return .text(Text(x: parseF(d["x"]), y: parseF(d["y"]),
                          content: d["content"] as? String ?? "",
                          fontFamily: d["font_family"] as? String ?? "sans-serif",
                          fontSize: parseF(d["font_size"]),
                          fontWeight: d["font_weight"] as? String ?? "normal",
                          fontStyle: d["font_style"] as? String ?? "normal",
                          textDecoration: d["text_decoration"] as? String ?? "none",
                          width: parseF(d["width"]), height: parseF(d["height"]),
                          fill: parseFill(d["fill"]), stroke: parseStroke(d["stroke"]),
                          opacity: opacity, transform: transform, locked: locked,
                          visibility: visibility))
    case "text_path":
        return .textPath(TextPath(d: parsePathCommands(d["d"]),
                                  content: d["content"] as? String ?? "",
                                  startOffset: parseF(d["start_offset"]),
                                  fontFamily: d["font_family"] as? String ?? "sans-serif",
                                  fontSize: parseF(d["font_size"]),
                                  fontWeight: d["font_weight"] as? String ?? "normal",
                                  fontStyle: d["font_style"] as? String ?? "normal",
                                  textDecoration: d["text_decoration"] as? String ?? "none",
                                  fill: parseFill(d["fill"]), stroke: parseStroke(d["stroke"]),
                                  opacity: opacity, transform: transform, locked: locked,
                                  visibility: visibility))
    case "group":
        let children = (d["children"] as? [Any] ?? []).map { parseElement($0) }
        return .group(Group(children: children, opacity: opacity, transform: transform,
                            locked: locked, visibility: visibility))
    case "layer":
        let children = (d["children"] as? [Any] ?? []).map { parseElement($0) }
        let name = d["name"] as? String ?? "Layer"
        return .layer(Layer(name: name, children: children, opacity: opacity, transform: transform,
                            locked: locked, visibility: visibility))
    default:
        fatalError("Unknown element type: \(typ)")
    }
}

private func parseSelection(_ v: Any?) -> Selection {
    guard let arr = v as? [[String: Any]] else { return [] }
    var sel: Selection = []
    for es in arr {
        let path = (es["path"] as? [Any] ?? []).map { ($0 as! NSNumber).intValue }
        let kind: SelectionKind
        if let s = es["kind"] as? String {
            kind = s == "all" ? .all : .all
        } else if let obj = es["kind"] as? [String: Any],
                  let partial = obj["partial"] as? [Any] {
            let cps = partial.map { ($0 as! NSNumber).intValue }
            kind = .partial(SortedCps(cps))
        } else {
            kind = .all
        }
        sel.insert(ElementSelection(path: path, kind: kind))
    }
    return sel
}

/// Parse canonical test JSON into a Document.
///
/// This is the inverse of ``documentToTestJson(_:)``.
public func testJsonToDocument(_ json: String) -> Document {
    let data = json.data(using: .utf8)!
    let v = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    let layerValues = v["layers"] as? [Any] ?? []
    let layers: [Layer] = layerValues.map { lv in
        let elem = parseElement(lv)
        guard case .layer(let l) = elem else { fatalError("Expected layer element") }
        return l
    }
    let selectedLayer = (v["selected_layer"] as? NSNumber)?.intValue ?? 0
    let selection = parseSelection(v["selection"])
    return Document(layers: layers, selectedLayer: selectedLayer, selection: selection)
}
