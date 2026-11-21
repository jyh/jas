import Testing
import AppKit
@testable import JasLib

// Row 192 A1 + B1 (OPACITY.md §Page-level items): two document-level booleans,
// page_isolated_blending and page_knockout_group, on DocumentSetup. The Swift
// twin of the Rust arms in document_setup.rs, test_json.rs, svg.rs and paint.rs.

private func withFlags(_ base: DocumentSetup = DocumentSetup(bleedTop: 9),
                       iso: Bool, ko: Bool) -> DocumentSetup {
    _withDocSetup(base, pageIsolatedBlending: iso, pageKnockoutGroup: ko)
}

@Test func thePageFlagsDefaultFalse() {
    #expect(!DocumentSetup.default.pageIsolatedBlending)
    #expect(!DocumentSetup.default.pageKnockoutGroup)
}

@Test func thePageFlagsAreWrittenToTestJsonOnlyWhenTrueAndReadBack() {
    let plain = documentToTestJson(Document(documentSetup: DocumentSetup(bleedTop: 9)))
    #expect(!plain.contains("page_isolated_blending") && !plain.contains("page_knockout_group"), "\(plain)")
    let back = testJsonToDocument(plain).documentSetup
    #expect(!back.pageIsolatedBlending && !back.pageKnockoutGroup)
    for (iso, ko) in [(true, false), (false, true), (true, true)] {
        let ds = withFlags(iso: iso, ko: ko)
        let json = documentToTestJson(Document(documentSetup: ds))
        #expect(json.contains("\"page_isolated_blending\":true") == iso, "\(json)")
        #expect(json.contains("\"page_knockout_group\":true") == ko, "\(json)")
        #expect(testJsonToDocument(json).documentSetup == ds, "iso=\(iso) ko=\(ko)")
    }
}

@Test func thePageFlagsRoundTripThroughSvgAndAreAbsentByDefault() {
    let plain = documentToSvg(Document(documentSetup: DocumentSetup(bleedTop: 9)))
    #expect(plain.contains("<jas:document-setup"), "\(plain)")
    #expect(!plain.contains("page-isolated-blending") && !plain.contains("page-knockout-group"), "\(plain)")
    for (iso, ko) in [(true, false), (false, true), (true, true)] {
        let ds = withFlags(iso: iso, ko: ko)
        let svg = documentToSvg(Document(documentSetup: ds))
        #expect(svg.contains("page-isolated-blending=\"true\"") == iso, "\(svg)")
        #expect(svg.contains("page-knockout-group=\"true\"") == ko, "\(svg)")
        #expect(svgToDocument(svg).documentSetup == ds, "iso=\(iso) ko=\(ko)")
    }
}

/// One edit, inside a transaction as production runs it.
private func setField(_ model: Model, _ field: String, _ val: Value) -> Bool {
    var ok = false
    model.withTxn {
        ok = applyPrintConfigField(model, verb: "set_document_setup_field", field: field, val: val, index: 0)
    }
    return ok
}

@Test func theOpSetsEachPageFlagAndAnotherFieldsEditKeepsThem() {
    let model = Model(document: Document.newEmptyDocument())
    #expect(setField(model, "page_isolated_blending", .bool(true)))
    #expect(setField(model, "page_knockout_group", .bool(true)))
    #expect(model.document.documentSetup.pageIsolatedBlending)
    #expect(model.document.documentSetup.pageKnockoutGroup)
    // The setup is REBUILT field by field on every edit: a copier that does
    // not name the page flags resets them when the bleed changes.
    #expect(setField(model, "bleed_top", .number(4)))
    #expect(model.document.documentSetup.bleedTop == 4)
    #expect(model.document.documentSetup.pageIsolatedBlending, "kept across another field's edit")
    #expect(model.document.documentSetup.pageKnockoutGroup, "kept across another field's edit")
    // A value of the wrong type is refused and changes nothing.
    #expect(!setField(model, "page_isolated_blending", .number(0)))
    #expect(model.document.documentSetup.pageIsolatedBlending)
}

/// B1 in pixels on the Mac canvas: a Multiply layer over a yellow artboard
/// blends with it when the page is not isolated (measured 11-21: (0,142,10)),
/// and shows its own colour when it is (Multiply over a transparent backdrop
/// is the source, which then lands Normal).
private func canvasCentre(isolated: Bool, knockout: Bool = false) -> (Int, Int, Int) {
    let doc = Document(
        layers: [Layer(name: "L", children: [
            .rect(Rect(x: 50, y: 50, width: 100, height: 100,
                       fill: Fill(color: Color(r: 0, g: 0.5, b: 1)), blendMode: .multiply))])],
        artboards: [Artboard(id: "a", x: 0, y: 0, width: 200, height: 200, fill: .color("#ffff00"))],
        documentSetup: _withDocSetup(.default, pageIsolatedBlending: isolated, pageKnockoutGroup: knockout))
    let view = CanvasNSView()
    view.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    let model = Model(document: doc)
    model.viewportW = 200; model.viewportH = 200
    model.zoomLevel = 1.0; model.viewOffsetX = 0; model.viewOffsetY = 0
    view.document = doc
    view.controller = Controller(model: model)
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    let c = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
    return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}

@Test func aPageThatIsNotIsolatedBlendsItsLayersWithTheArtboard() {
    for ko in [false, true] {
        let (r, g, b) = canvasCentre(isolated: false, knockout: ko)
        #expect(b < 40 && g > 90 && r < 40, "multiplied against the artboard (a ONE-layer knockout page is the same picture: its one child composites against B0 = the artboard; knockout \(ko)): \((r, g, b))")
    }
}

@Test func anIsolatedPageCompositesItsLayersOntoTheArtboardOnce() {
    let (r, g, b) = canvasCentre(isolated: true)
    #expect(b > 215 && r < 40, "the layer's own colour: \((r, g, b))")
}
