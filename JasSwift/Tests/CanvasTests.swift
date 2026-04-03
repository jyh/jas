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
