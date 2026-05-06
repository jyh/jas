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

// MARK: - MarksAndBleed (PRINT.md §Phase 2)

@Test func marksAndBleedDefaultsMatchSpec() {
    let m = MarksAndBleed.default
    #expect(m.allPrinterMarks == false)
    #expect(m.trimMarks == false)
    #expect(m.registrationMarks == false)
    #expect(m.colorBars == false)
    #expect(m.pageInformation == false)
    #expect(m.printerMarkType == .roman)
    #expect(m.trimMarkWeight == 0.25)
    #expect(m.markOffset == 6.0)
    #expect(m.useDocumentBleed == true)
    #expect(m.bleedTop == 0)
    #expect(m.bleedRight == 0)
    #expect(m.bleedBottom == 0)
    #expect(m.bleedLeft == 0)
}

@Test func printerMarkTypeRawValuesAreSnakeCase() {
    #expect(PrinterMarkType.roman.rawValue == "roman")
    #expect(PrinterMarkType.japanese.rawValue == "japanese")
}

@Test func colorManagementDefaultsMatchSpec() {
    let c = ColorManagement.default
    #expect(c.documentProfile == "sRGB IEC61966-2.1")
    #expect(c.colorHandling == .letAppDetermine)
    #expect(c.printerProfile == "")
    #expect(c.renderingIntent == .relativeColorimetric)
    #expect(c.preserveRgbNumbers == false)
}

@Test func colorManagementEnumRawValuesAreSnakeCase() {
    #expect(ColorHandling.letAppDetermine.rawValue == "let_app_determine")
    #expect(ColorHandling.letPrinterDetermine.rawValue == "let_printer_determine")
    #expect(ColorHandling.postscriptColorManagement.rawValue == "postscript_color_management")
    #expect(RenderingIntent.perceptual.rawValue == "perceptual")
    #expect(RenderingIntent.relativeColorimetric.rawValue == "relative_colorimetric")
    #expect(RenderingIntent.saturation.rawValue == "saturation")
    #expect(RenderingIntent.absoluteColorimetric.rawValue == "absolute_colorimetric")
}

@Test func colorManagementRoundTripsThroughPrintPreferences() {
    let c = ColorManagement(
        documentProfile: "Adobe RGB (1998)",
        colorHandling: .postscriptColorManagement,
        printerProfile: "U.S. Web Coated (SWOP) v2",
        renderingIntent: .saturation,
        preserveRgbNumbers: true
    )
    let p = PrintPreferences(colorManagement: c)
    let doc = Document(printPreferences: p)
    let json = documentToTestJson(doc)
    #expect(json.contains("\"color_management\""))
    #expect(json.contains("\"color_handling\":\"postscript_color_management\""))
    let doc2 = testJsonToDocument(json)
    #expect(doc2.printPreferences.colorManagement == c)
}

@Test func graphicsDefaultsMatchSpec() {
    let g = Graphics.default
    #expect(g.flatness == 1.0)
    #expect(g.fontDownload == .subset)
    #expect(g.postscriptLevel == .level3)
    #expect(g.dataFormat == .binary)
    #expect(g.compatibleGradientPrinting == false)
    #expect(g.rasterEffectsResolution == 300.0)
}

@Test func graphicsEnumRawValuesAreSnakeCase() {
    #expect(FontDownload.none.rawValue == "none")
    #expect(FontDownload.subset.rawValue == "subset")
    #expect(FontDownload.complete.rawValue == "complete")
    #expect(PostScriptLevel.level2.rawValue == "level_2")
    #expect(PostScriptLevel.level3.rawValue == "level_3")
    #expect(DataFormat.ascii.rawValue == "ascii")
    #expect(DataFormat.binary.rawValue == "binary")
}

@Test func graphicsRoundTripsThroughPrintPreferences() {
    let g = Graphics(
        flatness: 0.4,
        fontDownload: .complete,
        postscriptLevel: .level2,
        dataFormat: .ascii,
        compatibleGradientPrinting: true,
        rasterEffectsResolution: 600.0
    )
    let p = PrintPreferences(graphics: g)
    let doc = Document(printPreferences: p)
    let json = documentToTestJson(doc)
    #expect(json.contains("\"graphics\""))
    #expect(json.contains("\"flatness\":0.4"))
    let doc2 = testJsonToDocument(json)
    #expect(doc2.printPreferences.graphics == g)
}

@Test func outputDefaultsMatchSpec() {
    let o = Output.default
    #expect(o.mode == .composite)
    #expect(o.emulsion == .upRight)
    #expect(o.imagePolarity == .positive)
    #expect(o.printerResolution == "75 lpi / 600 dpi")
    #expect(o.convertSpotToProcess == false)
    #expect(o.overprintBlack == false)
    #expect(o.inks.count == 4)
    #expect(o.inks[0].name == "Process Cyan" && o.inks[0].angle == 105.0)
    #expect(o.inks[1].name == "Process Magenta" && o.inks[1].angle == 75.0)
    #expect(o.inks[2].name == "Process Yellow" && o.inks[2].angle == 90.0)
    #expect(o.inks[3].name == "Process Black" && o.inks[3].angle == 45.0)
    for ink in o.inks {
        #expect(ink.print)
        #expect(ink.frequency == 75.0)
        #expect(ink.dotShape == .round)
    }
}

@Test func outputEnumRawValuesAreSnakeCase() {
    #expect(OutputMode.composite.rawValue == "composite")
    #expect(OutputMode.separations.rawValue == "separations")
    #expect(Emulsion.upRight.rawValue == "up_right")
    #expect(Emulsion.downRight.rawValue == "down_right")
    #expect(ImagePolarity.positive.rawValue == "positive")
    #expect(ImagePolarity.negative.rawValue == "negative")
    #expect(DotShape.round.rawValue == "round")
    #expect(DotShape.euclidean.rawValue == "euclidean")
}

@Test func outputRoundTripsThroughPrintPreferences() {
    let o = Output(
        mode: .separations,
        emulsion: .downRight,
        imagePolarity: .negative,
        printerResolution: "150 lpi / 1200 dpi",
        convertSpotToProcess: true,
        overprintBlack: true,
        inks: [
            InkOverride(name: "Process Cyan", print: false, frequency: 100, angle: 105, dotShape: .ellipse),
            InkOverride(name: "PANTONE 185 C", print: true, frequency: 85, angle: 45, dotShape: .square),
        ]
    )
    let p = PrintPreferences(output: o)
    let doc = Document(printPreferences: p)
    let json = documentToTestJson(doc)
    #expect(json.contains("\"output\""))
    #expect(json.contains("\"inks\""))
    #expect(json.contains("\"PANTONE 185 C\""))
    let doc2 = testJsonToDocument(json)
    #expect(doc2.printPreferences.output == o)
}

@Test func marksAndBleedRoundTripsThroughPrintPreferences() {
    let m = MarksAndBleed(
        allPrinterMarks: true,
        trimMarks: true,
        registrationMarks: true,
        colorBars: true,
        pageInformation: true,
        printerMarkType: .japanese,
        trimMarkWeight: 0.5,
        markOffset: 12,
        useDocumentBleed: false,
        bleedTop: 4, bleedRight: 5,
        bleedBottom: 6, bleedLeft: 7
    )
    let p = PrintPreferences(marksAndBleed: m)
    let doc = Document(printPreferences: p)
    let json = documentToTestJson(doc)
    #expect(json.contains("\"marks_and_bleed\""))
    let doc2 = testJsonToDocument(json)
    #expect(doc2.printPreferences.marksAndBleed == m)
}
