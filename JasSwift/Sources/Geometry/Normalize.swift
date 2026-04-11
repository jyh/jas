/// SVG opacity normalizer.
///
/// Extracts color alpha into fill/stroke opacity (multiplicative),
/// then sets color alpha to 1.0.  This ensures that element
/// transparency is expressed through opacity attributes rather than
/// color alpha channels.

public func normalizeDocument(_ doc: Document) -> Document {
    Document(layers: doc.layers.map { normalizeLayer($0) })
}

private func normalizeFill(_ fill: Fill) -> Fill {
    Fill(color: fill.color.withAlpha(1.0), opacity: fill.opacity * fill.color.alpha)
}

private func normalizeStroke(_ stroke: Stroke) -> Stroke {
    Stroke(color: stroke.color.withAlpha(1.0), width: stroke.width,
           linecap: stroke.linecap, linejoin: stroke.linejoin,
           opacity: stroke.opacity * stroke.color.alpha)
}

private func normalizeElement(_ elem: Element) -> Element {
    switch elem {
    case .line(let e):
        return .line(Line(x1: e.x1, y1: e.y1, x2: e.x2, y2: e.y2,
                          stroke: e.stroke.map(normalizeStroke),
                          opacity: e.opacity, transform: e.transform,
                          locked: e.locked, visibility: e.visibility))
    case .rect(let e):
        return .rect(Rect(x: e.x, y: e.y, width: e.width, height: e.height,
                           rx: e.rx, ry: e.ry,
                           fill: e.fill.map(normalizeFill), stroke: e.stroke.map(normalizeStroke),
                           opacity: e.opacity, transform: e.transform,
                           locked: e.locked, visibility: e.visibility))
    case .circle(let e):
        return .circle(Circle(cx: e.cx, cy: e.cy, r: e.r,
                              fill: e.fill.map(normalizeFill), stroke: e.stroke.map(normalizeStroke),
                              opacity: e.opacity, transform: e.transform,
                              locked: e.locked, visibility: e.visibility))
    case .ellipse(let e):
        return .ellipse(Ellipse(cx: e.cx, cy: e.cy, rx: e.rx, ry: e.ry,
                                fill: e.fill.map(normalizeFill), stroke: e.stroke.map(normalizeStroke),
                                opacity: e.opacity, transform: e.transform,
                                locked: e.locked, visibility: e.visibility))
    case .polyline(let e):
        return .polyline(Polyline(points: e.points,
                                  fill: e.fill.map(normalizeFill), stroke: e.stroke.map(normalizeStroke),
                                  opacity: e.opacity, transform: e.transform,
                                  locked: e.locked, visibility: e.visibility))
    case .polygon(let e):
        return .polygon(Polygon(points: e.points,
                                fill: e.fill.map(normalizeFill), stroke: e.stroke.map(normalizeStroke),
                                opacity: e.opacity, transform: e.transform,
                                locked: e.locked, visibility: e.visibility))
    case .path(let e):
        return .path(Path(d: e.d,
                          fill: e.fill.map(normalizeFill), stroke: e.stroke.map(normalizeStroke),
                          opacity: e.opacity, transform: e.transform,
                          locked: e.locked, visibility: e.visibility))
    case .text(let e):
        return .text(Text(x: e.x, y: e.y, content: e.content,
                          fontFamily: e.fontFamily, fontSize: e.fontSize,
                          fontWeight: e.fontWeight, fontStyle: e.fontStyle,
                          textDecoration: e.textDecoration,
                          width: e.width, height: e.height,
                          fill: e.fill.map(normalizeFill), stroke: e.stroke.map(normalizeStroke),
                          opacity: e.opacity, transform: e.transform,
                          locked: e.locked, visibility: e.visibility))
    case .textPath(let e):
        return .textPath(TextPath(d: e.d, content: e.content, startOffset: e.startOffset,
                                  fontFamily: e.fontFamily, fontSize: e.fontSize,
                                  fontWeight: e.fontWeight, fontStyle: e.fontStyle,
                                  textDecoration: e.textDecoration,
                                  fill: e.fill.map(normalizeFill), stroke: e.stroke.map(normalizeStroke),
                                  opacity: e.opacity, transform: e.transform,
                                  locked: e.locked, visibility: e.visibility))
    case .group(let g):
        return .group(Group(children: g.children.map(normalizeElement),
                            opacity: g.opacity, transform: g.transform,
                            locked: g.locked, visibility: g.visibility))
    case .layer(let l):
        return .layer(Layer(name: l.name, children: l.children.map(normalizeElement),
                            opacity: l.opacity, transform: l.transform,
                            locked: l.locked, visibility: l.visibility))
    }
}

private func normalizeLayer(_ layer: Layer) -> Layer {
    Layer(name: layer.name, children: layer.children.map(normalizeElement),
          opacity: layer.opacity, transform: layer.transform,
          locked: layer.locked, visibility: layer.visibility)
}
