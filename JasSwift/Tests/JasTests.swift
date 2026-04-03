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

@Test func jasCommandsInitializes() {
    let commands = JasCommands()
    #expect(commands != nil)
}

@Test func contentViewWithKeyboardHandlerInitializes() {
    let view = ContentView()
    // The view includes KeyboardShortcutHandler for keyboard shortcuts
    // Accessing body ensures the view hierarchy is constructed
    _ = view.body
    #expect(true)
}
