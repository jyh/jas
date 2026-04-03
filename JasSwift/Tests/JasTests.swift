import Testing
@testable import JasLib

@Test func contentViewInitializes() {
    let view = ContentView()
    _ = view.body
}

@Test func canvasViewInitializes() {
    let canvas = CanvasView()
    let nsView = canvas.makeNSView(context: .init())
    #expect(nsView.wantsLayer == true)
}
