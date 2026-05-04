import Testing
@testable import JasLib

// MARK: - DocumentSetup

@Test func documentSetupDefaults() {
    let s = DocumentSetup.default
    #expect(s.bleedTop == 0)
    #expect(s.bleedRight == 0)
    #expect(s.bleedBottom == 0)
    #expect(s.bleedLeft == 0)
    #expect(s.bleedUniform == true)
    #expect(s.showImagesOutline == false)
    #expect(s.highlightSubstitutedGlyphs == false)
}

@Test func bleedRectNoneWhenAllZero() {
    let ab = Artboard(id: "ab", name: "A1", x: 10, y: 20, width: 100, height: 200)
    let s = DocumentSetup.default
    #expect(s.bleedRect(forArtboard: ab) == nil)
}

@Test func bleedRectUniformExtendsAllSides() {
    let ab = Artboard(id: "ab", name: "A1", x: 10, y: 20, width: 100, height: 200)
    let s = DocumentSetup(bleedTop: 5, bleedRight: 5, bleedBottom: 5, bleedLeft: 5)
    let r = s.bleedRect(forArtboard: ab)!
    #expect(r.0 == 5 && r.1 == 15 && r.2 == 110 && r.3 == 210)
}

@Test func bleedRectPartialOnlyOffsetsSidesWithBleed() {
    let ab = Artboard(id: "ab", name: "A1", x: 10, y: 20, width: 100, height: 200)
    let s = DocumentSetup(bleedLeft: 7)
    let r = s.bleedRect(forArtboard: ab)!
    #expect(r.0 == 3 && r.1 == 20 && r.2 == 107 && r.3 == 200)
}

// MARK: - PrintPreferences

@Test func printPreferencesDefaultsMatchSpec() {
    let p = PrintPreferences.default
    #expect(p.presetName == "[Default]")
    #expect(p.printerName == nil)
    #expect(p.copies == 1)
    #expect(p.collate == false)
    #expect(p.reverseOrder == false)
    #expect(p.artboardRangeMode == .all)
    #expect(p.artboardRange == "")
    #expect(p.ignoreArtboards == false)
    #expect(p.skipBlankArtboards == false)
    #expect(p.mediaSize == .definedByDriver)
    #expect(p.mediaWidth == 612)
    #expect(p.mediaHeight == 792)
    #expect(p.orientation == .portrait)
    #expect(p.autoRotate == true)
    #expect(p.transverse == false)
    #expect(p.printLayers == .visiblePrintable)
    #expect(p.placementX == 0)
    #expect(p.placementY == 0)
    #expect(p.scalingMode == .doNotScale)
    #expect(p.customScale == 100.0)
    #expect(p.tileOverlapH == 0)
    #expect(p.tileOverlapV == 0)
    #expect(p.tileRange == "")
}

@Test func defaultPresetHoldsDefaults() {
    let p = PrintPreset.defaultPreset
    #expect(p.name == "[Default]")
    #expect(p.preferences == .default)
}

@Test func enumStringFormsAreSnakeCase() {
    #expect(ArtboardRangeMode.all.rawValue == "all")
    #expect(ArtboardRangeMode.range.rawValue == "range")
    #expect(MediaSize.definedByDriver.rawValue == "defined_by_driver")
    #expect(MediaSize.tabloid.rawValue == "tabloid")
    #expect(Orientation.portrait.rawValue == "portrait")
    #expect(PrintLayers.visiblePrintable.rawValue == "visible_printable")
    #expect(ScalingMode.doNotScale.rawValue == "do_not_scale")
    #expect(ScalingMode.fitToPage.rawValue == "fit_to_page")
}

// MARK: - Test JSON omission + round-trip

@Test func documentSetupOnlyEmittedWhenNonDefault() {
    let doc = Document()
    let json = documentToTestJson(doc)
    #expect(!json.contains("\"document_setup\""))

    let doc2 = Document(documentSetup: DocumentSetup(bleedTop: 9))
    let json2 = documentToTestJson(doc2)
    #expect(json2.contains("\"document_setup\""))
    #expect(json2.contains("\"bleed_top\":9.0"))
}

@Test func documentSetupRoundTrip() {
    let s = DocumentSetup(
        bleedTop: 9, bleedRight: 9, bleedBottom: 9, bleedLeft: 9,
        bleedUniform: false,
        showImagesOutline: true,
        highlightSubstitutedGlyphs: true
    )
    let doc = Document(documentSetup: s)
    let json = documentToTestJson(doc)
    let doc2 = testJsonToDocument(json)
    #expect(doc2.documentSetup == s)
}

@Test func printPreferencesOnlyEmittedWhenNonDefault() {
    let doc = Document()
    let json = documentToTestJson(doc)
    #expect(!json.contains("\"print_preferences\""))

    let doc2 = Document(printPreferences: PrintPreferences(copies: 5))
    let json2 = documentToTestJson(doc2)
    #expect(json2.contains("\"print_preferences\""))
    #expect(json2.contains("\"copies\":5"))
}

@Test func printPreferencesRoundTrip() {
    let p = PrintPreferences(
        presetName: "[Default]",
        printerName: "My Laser",
        copies: 7,
        collate: true,
        reverseOrder: true,
        artboardRangeMode: .range,
        artboardRange: "1-3, 5",
        ignoreArtboards: true,
        skipBlankArtboards: true,
        mediaSize: .a4,
        mediaWidth: 595.28,
        mediaHeight: 841.89,
        orientation: .landscape,
        autoRotate: false,
        transverse: true,
        printLayers: .all,
        placementX: 12,
        placementY: 24,
        scalingMode: .custom,
        customScale: 75.5,
        tileOverlapH: 6,
        tileOverlapV: 6,
        tileRange: "1-2"
    )
    let doc = Document(printPreferences: p)
    let json = documentToTestJson(doc)
    let doc2 = testJsonToDocument(json)
    #expect(doc2.printPreferences == p)
}
