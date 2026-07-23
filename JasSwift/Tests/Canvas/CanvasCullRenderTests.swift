import Testing
import AppKit
@testable import JasLib

// SH-4 integration: render the real canvas draw() path to an offscreen bitmap
// and assert the culling that runs there is VISUALLY INVARIANT — adding a
// far-off-screen element changes nothing in the visible image — and that an
// in-view element is NOT wrongly culled (the coordinate wiring is correct).

private func renderModel(_ doc: Document, w: Int, h: Int) -> NSBitmapImageRep? {
    let view = CanvasNSView()
    view.frame = NSRect(x: 0, y: 0, width: w, height: h)
    let model = Model(document: doc)
    // Pin the view transform so doc coords == view points (no first-paint
    // re-center: viewport must not read as the 888x900 construction default).
    model.viewportW = Double(w)
    model.viewportH = Double(h)
    model.zoomLevel = 1.0
    model.viewOffsetX = 0.0
    model.viewOffsetY = 0.0
    view.document = doc
    view.controller = Controller(model: model)
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double,
                  fill: Fill) -> Element {
    .rect(Rect(x: x, y: y, width: w, height: h, fill: fill))
}

@Test func cullRenderIsVisuallyInvariantToOffscreenElement() {
    let red = Fill(color: Color(r: 0.86, g: 0.08, b: 0.08))
    let inView = rect(60, 60, 40, 40, fill: red)
    // Baseline: just the in-view rect.
    let docA = Document(layers: [Layer(children: [inView])], selectedLayer: 0, selection: [])
    // Plus a far off-screen rect that the viewport cull must drop.
    let offscreen = rect(50_000, 50_000, 40, 40, fill: red)
    let docB = Document(layers: [Layer(children: [inView, offscreen])],
                        selectedLayer: 0, selection: [])
    guard let a = renderModel(docA, w: 240, h: 200),
          let b = renderModel(docB, w: 240, h: 200) else {
        Issue.record("offscreen render unavailable in this environment")
        return
    }
    // The visible image is byte-identical whether or not the off-screen element
    // is present — culling it (or drawing it) cannot change visible pixels.
    #expect(a.tiffRepresentation == b.tiffRepresentation)
}

@Test func cullRenderKeepsInViewElement() {
    let red = Fill(color: Color(r: 0.86, g: 0.08, b: 0.08))
    let withRect = Document(layers: [Layer(children: [rect(60, 60, 40, 40, fill: red)])],
                            selectedLayer: 0, selection: [])
    let empty = Document(layers: [Layer(children: [])], selectedLayer: 0, selection: [])
    guard let withR = renderModel(withRect, w: 240, h: 200),
          let without = renderModel(empty, w: 240, h: 200) else {
        Issue.record("offscreen render unavailable in this environment")
        return
    }
    // A visible element must actually paint: the two images differ. (If culling
    // wrongly dropped the in-view rect, or the doc→screen mapping were off, the
    // images would match.)
    #expect(withR.tiffRepresentation != without.tiffRepresentation)
}
