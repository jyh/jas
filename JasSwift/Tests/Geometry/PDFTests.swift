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
