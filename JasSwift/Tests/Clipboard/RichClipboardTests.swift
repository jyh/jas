import AppKit
import Testing
@testable import JasLib

// Uses a fresh private pasteboard per test to avoid clobbering the
// user's real clipboard during `swift test`.

private func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name(rawValue: "jas.tests.\(UUID().uuidString)"))
}

@Test func richClipboardWritePopulatesThreeTypes() {
    let pb = makePasteboard()
    let tspans = [
        Tspan(id: 0, content: "foo"),
        Tspan(id: 1, content: "bar", fontWeight: "bold"),
    ]
    richClipboardWrite(flat: "foobar", tspans: tspans, pasteboard: pb)
    #expect(pb.string(forType: .string) == "foobar")
    let json = pb.string(forType: jasTspansPasteboardType)
    #expect(json != nil)
    #expect(json!.contains("\"content\":\"foo\""))
    #expect(json!.contains("\"font_weight\":\"bold\""))
    let svg = pb.string(forType: svgXmlPasteboardType)
    #expect(svg != nil)
    #expect(svg!.contains("<tspan>foo</tspan>"))
    #expect(svg!.contains(#"<tspan font-weight="bold">bar</tspan>"#))
}

@Test func richClipboardReadPrefersJsonOverSvg() {
    let pb = makePasteboard()
    let tspans = [Tspan(id: 0, content: "X", fontWeight: "bold")]
    richClipboardWrite(flat: "X", tspans: tspans, pasteboard: pb)
    let back = richClipboardReadTspans(pasteboard: pb)
    #expect(back != nil)
    #expect(back!.count == 1)
    #expect(back![0].content == "X")
    #expect(back![0].fontWeight == "bold")
}

@Test func richClipboardReadReturnsNilWhenFormatsMissing() {
    let pb = makePasteboard()
    pb.clearContents()
    pb.declareTypes([.string], owner: nil)
    pb.setString("plain text", forType: .string)
    #expect(richClipboardReadTspans(pasteboard: pb) == nil)
}

@Test func richClipboardSvgFallbackWhenJsonAbsent() {
    // Simulate an SVG-aware app that only writes the SVG format.
    let pb = makePasteboard()
    pb.clearContents()
    pb.declareTypes([.string, svgXmlPasteboardType], owner: nil)
    pb.setString("X", forType: .string)
    pb.setString(#"<text xmlns="http://www.w3.org/2000/svg"><tspan font-weight="bold">X</tspan></text>"#,
                  forType: svgXmlPasteboardType)
    let back = richClipboardReadTspans(pasteboard: pb)
    #expect(back != nil)
    #expect(back!.count == 1)
    #expect(back![0].content == "X")
    #expect(back![0].fontWeight == "bold")
}
