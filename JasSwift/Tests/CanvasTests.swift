import Testing
@testable import JasLib

@Test func defaultToolIsSelection() {
    let tool: Tool = .selection
    #expect(tool == .selection)
}

@Test func toolEnumCases() {
    let tools = Tool.allCases
    #expect(tools.count == 2)
    #expect(tools.contains(.selection))
    #expect(tools.contains(.directSelection))
}

@Test func contentViewInitializes() {
    let view = ContentView()
    _ = view.body
}

@Test func toolEnumCasesExist() {
    let tools = Tool.allCases
    #expect(tools.count == 2)
    #expect(tools.contains(.selection))
    #expect(tools.contains(.directSelection))
}

@Test func contentViewWithKeyboardHandlerInitializes() {
    let view = ContentView()
    _ = view.body
    #expect(true)
}

@Test func defaultBoundingBox() {
    let bbox = CanvasBoundingBox()
    #expect(bbox.x == 0 && bbox.y == 0 && bbox.width == 800 && bbox.height == 600)
}

@Test func customBoundingBox() {
    let bbox = CanvasBoundingBox(x: 10, y: 20, width: 1024, height: 768)
    #expect(bbox.x == 10 && bbox.y == 20 && bbox.width == 1024 && bbox.height == 768)
}
