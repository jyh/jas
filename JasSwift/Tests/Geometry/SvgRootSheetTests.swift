import Testing
@testable import JasLib

// The sheet a drawing states on its root. A file that declares no pages of
// its own (no Inkscape `namedview`) still states its paper: the root
// `width`/`height`, over the `viewBox` when there is one. That is the page
// a PDF export should print on. Twin of Rust's `svg.rs`
// `root_artboard_tests`, on the same synthetic drawing; `documentForOpen`
// is this port's `open_svg_document`.

private func rootSheetSrc(_ rootAttrs: String, _ extra: String) -> String {
    #"<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.0.dtd" "#
        + rootAttrs + ">" + extra + ##"<rect x="1" y="1" width="2" height="2" fill="#000000"/></svg>"##
}

private func rootSheetOpen(_ rootAttrs: String, _ extra: String) -> Document {
    documentForOpen(rootSheetSrc(rootAttrs, extra))
}

private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

/// The one artboard's rect, or nil (recording an issue) when there is not
/// exactly one.
private func one(_ d: Document) -> (Double, Double, Double, Double)? {
    #expect(d.artboards.count == 1, "exactly one artboard: \(d.artboards)")
    guard d.artboards.count == 1 else { return nil }
    let a = d.artboards[0]
    return (a.x, a.y, a.width, a.height)
}

@Test func svgASizedViewBoxBecomesTheSheet() {
    // 2 in x 1 in over a viewBox whose origin is not zero: the sheet is
    // the viewBox window, at paper size (k = 7.2 pt per unit).
    guard let (x, y, w, h) = one(rootSheetOpen(#"width="2in" height="1in" viewBox="-5 -2 20 10""#, "")) else { return }
    #expect(close(w, 144) && close(h, 72), "sheet \(w) x \(h) pt")
    #expect(close(x, -5 * 7.2) && close(y, -2 * 7.2), "sheet origin (\(x), \(y))")
}

@Test func svgASizedRootWithoutAViewBoxBecomesTheSheet() {
    guard let r = one(rootSheetOpen(#"width="5in" height="3in""#, "")) else { return }
    #expect(r == (0, 0, 360, 216), "sheet \(r)")
}

@Test func svgDeclaredPagesWinOverTheRoot() {
    let pages = #"<sodipodi:namedview><inkscape:page x="0" y="0" width="40" height="40" id="p1" inkscape:label="Page"/></sodipodi:namedview>"#
    let d = rootSheetOpen(#"width="2in" height="1in" viewBox="0 0 20 10""#, pages)
    guard let (_, _, w, h) = one(d) else { return }
    #expect(close(w, 40 * 7.2) && close(h, 40 * 7.2), "the declared page, not the root: \(w) x \(h)")
    #expect(d.artboards[0].name == "Page")
}

@Test func svgAnUnsizedRootOpensOnTheDefaultSheet() {
    // No stated size: the at-least-one invariant supplies its default.
    guard let r = one(rootSheetOpen("", "")) else { return }
    let def = Artboard.defaultWithId("")
    #expect(r == (def.x, def.y, def.width, def.height))
}

@Test func svgTheCodecItselfInventsNoSheet() {
    // The shared corpus pins this: reading a file is not opening it.
    let d = svgToDocument(rootSheetSrc(#"width="2in" height="1in" viewBox="-5 -2 20 10""#, ""))
    #expect(d.artboards.isEmpty, "codec read: \(d.artboards)")
}

@Test func svgTheRootSheetRoundTripsThroughTheWriter() {
    let d = rootSheetOpen(#"width="2in" height="1in" viewBox="-5 -2 20 10""#, "")
    let again = svgToDocument(documentToSvg(d))
    guard let a = one(again), let b = one(d) else { return }
    #expect(a == b, "\(a) vs \(b)")
}
