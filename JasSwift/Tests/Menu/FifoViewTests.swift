import Testing
import Foundation
@testable import JasLib

// The test-only `--test-fifo` `view` and `open` commands (TESTING.md §6, level 2
// on the Mac). A level-2 harness posts real pointer events at screen points, so it
// must know where a document point is on screen. `view 1 0 0` puts the view at
// zoom 1 with no pan, so a document unit is one canvas point, as in the Windows
// shell, which has no pan and no zoom. The canvas reports the view it has in its
// accessibility value, so the harness reads the mapping back instead of trusting
// that the command took.

private func viewModel() -> Model {
    let m = Model(document: Document.newEmptyDocument())
    m.zoomLevel = 0.75
    m.viewOffsetX = 120
    m.viewOffsetY = -40
    return m
}

@Test func fifoViewParsesZoomAndOffsets() {
    let v = FifoView.parse("1 0 0")
    #expect(v?.zoom == 1 && v?.offsetX == 0 && v?.offsetY == 0)
    let w = FifoView.parse("  2.5   -10  7.25 ")
    #expect(w?.zoom == 2.5 && w?.offsetX == -10 && w?.offsetY == 7.25)
}

@Test func fifoViewRefusesAMalformedView() {
    // Wrong arity, a non-number, and a zoom that is not a positive finite
    // number are refused, so a typo cannot silently leave the old view.
    for bad in ["", "1", "1 0", "1 0 0 0", "one 0 0", "1 x 0", "0 0 0", "-1 0 0", "inf 0 0", "nan 0 0", "1 nan 0"] {
        #expect(FifoView.parse(bad) == nil, "accepted \(bad.debugDescription)")
    }
}

@Test func fifoViewAppliesAllThreeFields() {
    let m = viewModel()
    FifoView(zoom: 1, offsetX: 0, offsetY: 0).apply(to: m)
    #expect(m.zoomLevel == 1 && m.viewOffsetX == 0 && m.viewOffsetY == 0)
    // Each field is written by its own value: a view that differs in one
    // field only moves that field.
    FifoView(zoom: 1, offsetX: 0, offsetY: 30).apply(to: m)
    #expect(m.zoomLevel == 1 && m.viewOffsetX == 0 && m.viewOffsetY == 30)
    FifoView(zoom: 2, offsetX: 5, offsetY: 30).apply(to: m)
    #expect(m.zoomLevel == 2 && m.viewOffsetX == 5 && m.viewOffsetY == 30)
}

@Test func theCanvasReportsItsViewInOneParsableLine() {
    // The harness parses this line back; it is the same three numbers in the
    // same order as the command, so `parse(report)` is the round trip.
    let m = viewModel()
    let report = FifoView.report(m)
    #expect(report == "view 0.75 120.0 -40.0")
    let back = FifoView.parse(String(report.dropFirst("view ".count)))
    #expect(back?.zoom == 0.75 && back?.offsetX == 120 && back?.offsetY == -40)
}

@Test func fifoOpenReadsTheFileAsFileOpenDoes() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fifo-open-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><rect x="1" y="2" width="30" height="20"/></svg>"#
    let path = dir.appendingPathComponent("one_rect.svg").path
    try svg.write(toFile: path, atomically: true, encoding: .utf8)
    let model = try FifoOpen.model(path: path)
    // The same document File > Open builds, and the same filename. The open
    // mints its synthesised artboard's id afresh each time, so the artboard is
    // compared without its id (it is the artboard the Windows oracle sets aside).
    let want = documentForOpen(svg)
    #expect(documentToTestJson(model.document.replacing(artboards: []))
            == documentToTestJson(want.replacing(artboards: [])))
    #expect(model.document.artboards.count == 1 && want.artboards.count == 1)
    let (a, b) = (model.document.artboards[0], want.artboards[0])
    #expect(a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height && a.name == b.name)
    #expect(model.filename == path)
}

@Test func fifoOpenRefusesAMissingFile() {
    #expect(throws: (any Error).self) {
        _ = try FifoOpen.model(path: "/nonexistent/fifo-open/none.svg")
    }
}

@Test func fifoReadWritesTheCanonicalBytesExactly() throws {
    // The read-back a level-2 run compares, BYTE for byte as Windows does. The
    // `jas://document` resource re-encodes this JSON through JSONSerialization,
    // which keeps the values and not the bytes, so the harness reads this file.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fifo-read-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let m = Model(document: documentForOpen(
        #"<svg xmlns="http://www.w3.org/2000/svg"><rect x="1" y="2" width="30" height="20" stroke-width="2.000025"/></svg>"#))
    let path = dir.appendingPathComponent("read.json").path
    try FifoRead.write(m, to: path)
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(bytes == Data(documentToTestJson(m.document).utf8))
    // A second read replaces the first; it never appends.
    try FifoRead.write(m, to: path)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
}

@Test func aTestFifoLaunchNeverTouchesTheSession() {
    // A level-2 harness launches and quits the app once per script. The app
    // saves its open tabs on quit and restores them on launch, so a harness
    // run used to overwrite the developer's session and then replay one
    // script's edits into the next. Under `--test-fifo` neither happens.
    #expect(TestHarness.isolatesSession(["Jas", "--title", "T", "--test-fifo", "/tmp/f"]))
    #expect(!TestHarness.isolatesSession(["Jas", "--title", "T"]))
    #expect(!TestHarness.isolatesSession(["Jas", "--mcp-socket", "/tmp/s"]))
}
