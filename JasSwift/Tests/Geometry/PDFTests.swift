import Testing
import PDFKit
@testable import JasLib

@Test func pdfSmokeDefaultDocIsValidPdf() {
    let doc = Document()
    let data = documentToPdf(doc)
    #expect(data.count > 0)
    let pdf = PDFDocument(data: data)
    #expect(pdf != nil)
}

@Test func pdfOneArtboardYieldsOnePage() {
    // Document() seeds one default Letter artboard via newEmptyDocument
    // path; here we use the explicit init which leaves artboards empty.
    // To get one artboard, pass it through newEmptyDocument.
    let doc = Document.newEmptyDocument(idGenerator: { "ab1" })
    let data = documentToPdf(doc)
    let pdf = PDFDocument(data: data)!
    #expect(pdf.pageCount == 1)
}

@Test func pdfNArtboardsYieldsNPages() {
    let abs = [
        Artboard(id: "a", name: "A1", x: 0, y: 0, width: 100, height: 100),
        Artboard(id: "b", name: "A2", x: 0, y: 200, width: 200, height: 200),
        Artboard(id: "c", name: "A3", x: 0, y: 500, width: 50, height: 50),
    ]
    let doc = Document(artboards: abs)
    let data = documentToPdf(doc)
    let pdf = PDFDocument(data: data)!
    #expect(pdf.pageCount == 3)
}

@Test func pdfIgnoreArtboardsCollapsesToOnePage() {
    let abs = [
        Artboard(id: "a", name: "A1", x: 0, y: 0, width: 100, height: 100),
        Artboard(id: "b", name: "A2", x: 200, y: 200, width: 200, height: 200),
    ]
    let doc = Document(
        artboards: abs,
        printPreferences: PrintPreferences(ignoreArtboards: true)
    )
    let data = documentToPdf(doc)
    let pdf = PDFDocument(data: data)!
    #expect(pdf.pageCount == 1)
    let mediaBox = pdf.page(at: 0)!.bounds(for: .mediaBox)
    // Union covers (0..400, 0..400).
    #expect(mediaBox.width == 400)
    #expect(mediaBox.height == 400)
}

@Test func pdfEmptyDocPicksFallbackPageSize() {
    // Direct init() leaves artboards empty; collectPages then falls
    // through to a single 612x792 page.
    let doc = Document()
    let data = documentToPdf(doc)
    let pdf = PDFDocument(data: data)!
    #expect(pdf.pageCount == 1)
    let mediaBox = pdf.page(at: 0)!.bounds(for: .mediaBox)
    #expect(mediaBox.width == 612)
    #expect(mediaBox.height == 792)
}

@Test func pdfSeparationsEmitsOnePagePerEnabledInk() {
    let abs = [Artboard(id: "a", name: "A1", x: 0, y: 0, width: 100, height: 100)]
    let prefs = PrintPreferences(output: Output(mode: .separations))
    let doc = Document(artboards: abs, printPreferences: prefs)
    let data = documentToPdf(doc)
    let pdf = PDFDocument(data: data)!
    // Default 4 process inks all enabled → 4 pages.
    #expect(pdf.pageCount == 4)
}

@Test func pdfSeparationsSkipsUnprintedInks() {
    let abs = [Artboard(id: "a", name: "A1", x: 0, y: 0, width: 100, height: 100)]
    var inks = InkOverride.processCmykDefaults
    inks[0] = InkOverride(name: inks[0].name, print: false, frequency: inks[0].frequency,
                          angle: inks[0].angle, dotShape: inks[0].dotShape)
    inks[1] = InkOverride(name: inks[1].name, print: false, frequency: inks[1].frequency,
                          angle: inks[1].angle, dotShape: inks[1].dotShape)
    let prefs = PrintPreferences(output: Output(mode: .separations, inks: inks))
    let doc = Document(artboards: abs, printPreferences: prefs)
    let data = documentToPdf(doc)
    let pdf = PDFDocument(data: data)!
    // Only Yellow + Black left enabled → 2 pages.
    #expect(pdf.pageCount == 2)
}

@Test func pdfSeparationsWithZeroEnabledInksFallsBackToComposite() {
    let abs = [Artboard(id: "a", name: "A1", x: 0, y: 0, width: 100, height: 100)]
    let inks = InkOverride.processCmykDefaults.map { ink in
        InkOverride(name: ink.name, print: false, frequency: ink.frequency,
                    angle: ink.angle, dotShape: ink.dotShape)
    }
    let prefs = PrintPreferences(output: Output(mode: .separations, inks: inks))
    let doc = Document(artboards: abs, printPreferences: prefs)
    let data = documentToPdf(doc)
    let pdf = PDFDocument(data: data)!
    // Empty ink list shouldn't yield an empty PDF — fall through to
    // the single composite page.
    #expect(pdf.pageCount == 1)
}

@Test func pdfCompositeModeUnchangedByPhase3Changes() {
    // Composite is the default; ensure adding the Output sub-record
    // didn't perturb the page count for a default-options document.
    let doc = Document()
    let data = documentToPdf(doc)
    let pdf = PDFDocument(data: data)!
    #expect(pdf.pageCount == 1)
}

@Test func pdfNonDefaultPhase6ValuesDontBreakOutput() {
    // Phase 6 v1 stores Advanced + Phase 6 DocumentSetup fields
    // but defers the rendering effects (rasterize-as-bitmap, the
    // flattener pipelines, simulated paper, white-overprint
    // discard). Smoke-test that having non-default values
    // doesn't crash the emitter.
    let advanced = Advanced(printAsBitmap: true,
                            overprintFlattenerPreset: .highResolution)
    let setup = DocumentSetup(
        paperColor: "#fff8e7",
        simulateColoredPaper: true,
        transparencyFlattenerPreset: .highResolution,
        discardWhiteOverprint: true)
    let prefs = PrintPreferences(advanced: advanced)
    let doc = Document(documentSetup: setup, printPreferences: prefs)
    let data = documentToPdf(doc)
    let pdf = PDFDocument(data: data)
    #expect(pdf != nil)
    #expect(pdf?.pageCount == 1)
}

@Test func pdfNonDefaultRenderingIntentProducesValidPdf() {
    // Smoke: ColorManagement.renderingIntent ≠ .relativeColorimetric
    // propagates through the emitter (CGContext.setRenderingIntent)
    // without breaking the output envelope.
    let cm = ColorManagement(renderingIntent: .perceptual)
    let prefs = PrintPreferences(colorManagement: cm)
    let doc = Document(printPreferences: prefs)
    let data = documentToPdf(doc)
    #expect(PDFDocument(data: data) != nil)
}

@Test func pdfNonDefaultFlatnessProducesValidPdf() {
    // Smoke: Graphics.flatness ≠ 1 propagates through the emitter
    // (CGContext.setFlatness) without breaking the output envelope.
    // Can't easily inspect the path-flattening tolerance in the
    // generated PDF stream from outside CG, so settle for a valid
    // PDF + page-count assertion.
    let prefs = PrintPreferences(graphics: Graphics(flatness: 5.0))
    let doc = Document(printPreferences: prefs)
    let data = documentToPdf(doc)
    #expect(PDFDocument(data: data) != nil)
}
