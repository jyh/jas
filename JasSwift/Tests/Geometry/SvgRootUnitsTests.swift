import Testing
@testable import JasLib

// Root-size units (SVG 1.1 §7.2 / §7.7): the outermost `<svg>`'s
// `width`/`height` with a unit, over a `viewBox`, fix what one USER UNIT
// is on paper. A drawing authored in inches at 1:24 says so this way, and
// the import must land each length at that real size. Twin of Rust's
// `svg.rs` `root_units_tests`, on the same synthetic drawing.

private func rootUnitsAll(_ doc: Document) -> [Element] {
    var out: [Element] = []
    func walk(_ e: Element) {
        out.append(e)
        switch e {
        case .group(let g): g.children.forEach(walk)
        case .layer(let l): l.children.forEach(walk)
        default: break
        }
    }
    doc.layers.forEach { walk(.layer($0)) }
    return out
}

private func rootUnitsRect(_ doc: Document) -> Rect? {
    rootUnitsAll(doc).lazy.compactMap { if case .rect(let r) = $0 { return r } else { return nil } }.first
}

private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

/// One fixture body, wrapped in whichever root is under test.
private func drawing(_ rootAttrs: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" \(rootAttrs)>
    <g><g transform="translate(1,0)"><rect x="10" y="2" width="5" height="3" fill="#cccccc" stroke="#000000" stroke-width="0.5" stroke-dasharray="1 2"/></g></g>
    <line x1="0" y1="0" x2="4" y2="0" stroke="#000000"/>
    <circle cx="3" cy="3" r="1" fill="#ff0000"/>
    <text x="4" y="6" font-size="2" fill="#000000">A</text>
    </svg>
    """
}

/// Every length kind the importer converts, checked against `k`, the
/// fixture's own pt-per-user-unit, derived from its root attributes.
private func expectScaled(_ doc: Document, _ k: Double) {
    guard let r = rootUnitsRect(doc) else { Issue.record("no rect"); return }
    #expect(close(r.x, 10 * k) && close(r.y, 2 * k), "rect origin (\(r.x), \(r.y)) at k=\(k)")
    #expect(close(r.width, 5 * k) && close(r.height, 3 * k), "rect size (\(r.width), \(r.height)) at k=\(k)")
    guard let s = r.stroke else { Issue.record("no stroke"); return }
    #expect(close(s.width, 0.5 * k), "stroke width \(s.width) at k=\(k)")
    #expect(s.dashPattern.count == 2)
    if s.dashPattern.count == 2 {
        #expect(close(s.dashPattern[0], 1 * k) && close(s.dashPattern[1], 2 * k), "dash \(s.dashPattern)")
    }
    let es = rootUnitsAll(doc)
    let t = es.lazy.compactMap { e -> Transform? in
        if case .group(let g) = e { return g.transform } else { return nil }
    }.first
    #expect(t != nil, "group transform")
    if let t { #expect(close(t.e, 1 * k) && close(t.f, 0), "translate (\(t.e), \(t.f)) at k=\(k)") }
    let l = es.lazy.compactMap { if case .line(let l) = $0 { return l } else { return nil } }.first
    #expect(l.map { close($0.x2, 4 * k) } == true, "line x2 \(String(describing: l?.x2))")
    let c = es.lazy.compactMap { if case .ellipse(let c) = $0 { return c } else { return nil } }.first
    #expect(c.map { close($0.cx, 3 * k) && close($0.rx, 1 * k) } == true, "circle \(String(describing: c))")
    let tx = es.lazy.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.first
    #expect(tx.map { close($0.x, 4 * k) && close($0.fontSize, 2 * k) } == true,
            "text x \(String(describing: tx?.x)) size \(String(describing: tx?.fontSize))")
}

@Test func svgInchRootOverAViewBoxSetsTheUserUnit() {
    // 20 user units across 2 in: one unit is 0.1 in = 7.2 pt.
    let doc = svgToDocument(drawing(#"width="2in" height="1in" viewBox="0 0 20 10""#))
    expectScaled(doc, 2 * 72 / 20)
}

@Test func svgMillimetreRootSetsTheUserUnit() {
    let doc = svgToDocument(drawing(#"width="100mm" height="50mm" viewBox="0 0 100 50""#))
    expectScaled(doc, 72 / 25.4)
}

@Test func svgEveryAbsoluteRootUnitIsRead() {
    // Each root is exactly 1 in wide over 10 units: k = 7.2 pt always.
    for w in ["1in", "2.54cm", "25.4mm", "72pt", "6pc", "96px", "96"] {
        let doc = svgToDocument(drawing("width=\"\(w)\" height=\"\(w)\" viewBox=\"0 0 10 10\""))
        let x = rootUnitsRect(doc)?.x ?? .nan
        #expect(close(x, 10 * 7.2), "width=\(w): rect x \(x)")
    }
}

@Test func svgAMismatchedRootAspectTakesTheSmallerScale() {
    // Default preserveAspectRatio is `xMidYMid meet`: the viewBox fits
    // INSIDE the viewport, so the smaller of the two axis scales wins.
    let doc = svgToDocument(drawing(#"width="2in" height="2in" viewBox="0 0 20 10""#))
    expectScaled(doc, 2 * 72 / 20)
}

@Test func svgAUnitlessRootMatchingItsViewBoxIsUnchanged() {
    // What jas's own writer emits: width/height equal the viewBox size,
    // with a non-zero viewBox origin. Unit is px, and coordinates keep
    // their origin (the viewBox is a window, not a shift).
    let doc = svgToDocument(drawing(#"width="420" height="267" viewBox="-54 50.6 420 267""#))
    expectScaled(doc, 0.75)
}

@Test func svgNoViewBoxMeansPxUserUnitsWhateverTheRootWidth() {
    let doc = svgToDocument(drawing(#"width="5in" height="3in""#))
    expectScaled(doc, 0.75)
}

@Test func svgAScaledImportRoundTripsThroughTheWriter() {
    let doc = svgToDocument(drawing(#"width="2in" height="1in" viewBox="0 0 20 10""#))
    let again = svgToDocument(documentToSvg(doc))
    expectScaled(again, 2 * 72 / 20)
}

@Test func svgTheRootUnitDoesNotLeakIntoTheNextImport() {
    // The scale is scoped to one import: a plain file read after an
    // inch-rooted one is back at px.
    _ = svgToDocument(drawing(#"width="2in" height="1in" viewBox="0 0 20 10""#))
    expectScaled(svgToDocument(drawing(#"width="5in" height="3in""#)), 0.75)
}
