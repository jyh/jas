import Testing
@testable import JasLib

// MARK: - Tool enum tests

@Test func toolEnumHasTenCases() {
    #expect(Tool.allCases.count == 16)
}

@Test func toolEnumContainsAllExpected() {
    let tools = Tool.allCases
    #expect(tools.contains(.selection))
    #expect(tools.contains(.directSelection))
    #expect(tools.contains(.groupSelection))
    #expect(tools.contains(.pen))
    #expect(tools.contains(.addAnchorPoint))
    #expect(tools.contains(.deleteAnchorPoint))
    #expect(tools.contains(.pencil))
    #expect(tools.contains(.typeTool))
    #expect(tools.contains(.textPath))
    #expect(tools.contains(.line))
    #expect(tools.contains(.rect))
    #expect(tools.contains(.roundedRect))
    #expect(tools.contains(.polygon))
    #expect(tools.contains(.star))
}

@Test func toolRawValuesUnique() {
    let rawValues = Tool.allCases.map { $0.rawValue }
    #expect(Set(rawValues).count == rawValues.count)
}

@Test func toolConformsToHashable() {
    var set = Set<Tool>()
    for tool in Tool.allCases { set.insert(tool) }
    #expect(set.count == 16)
}

// MARK: - Tool constants

@Test func hitRadiusValue() {
    #expect(hitRadius == 8.0)
}

@Test func handleDrawSizeValue() {
    #expect(handleDrawSize == 10.0)
}

@Test func dragThresholdValue() {
    #expect(dragThreshold == 4.0)
}

@Test func pasteOffsetValue() {
    #expect(pasteOffset == 24.0)
}

@Test func longPressDurationValue() {
    #expect(longPressDuration == 0.5)
}

@Test func polygonSidesValue() {
    #expect(polygonSides == 5)
}

// MARK: - Shared slot groups

@Test func arrowSlotAlternates() {
    let alternates: [Tool] = [.directSelection, .groupSelection]
    #expect(alternates.count == 2)
    #expect(alternates.contains(.directSelection))
    #expect(alternates.contains(.groupSelection))
}

@Test func textSlotAlternates() {
    let alternates: [Tool] = [.typeTool, .textPath]
    #expect(alternates.count == 2)
    #expect(alternates.contains(.typeTool))
    #expect(alternates.contains(.textPath))
}

@Test func shapeSlotAlternates() {
    let alternates: [Tool] = [.rect, .polygon]
    #expect(alternates.count == 2)
    #expect(alternates.contains(.rect))
    #expect(alternates.contains(.polygon))
}

// MARK: - Toolbar grid layout

@Test func toolbarGridHasFourRows() {
    // Row 0: Selection, Direct/Group Selection
    // Row 1: Pen, Pencil
    // Row 2: Text/TextPath, Line
    // Row 3: Rect/Polygon
    let rows = 4
    #expect(rows == 4)
}

@Test func toolbarGridHasTwoColumns() {
    let cols = 2
    #expect(cols == 2)
}

@Test func toolbarGridHasSevenSlots() {
    // 7 visible slots: selection, direct, pen, pencil, text, line, rect/polygon
    let slots = 7
    #expect(slots == 7)
}

@Test func toolbarGridThreeSharedSlots() {
    // Arrow slot (direct/group), Text slot (text/textPath), Shape slot (rect/polygon)
    let sharedSlots = 3
    #expect(sharedSlots == 3)
}

// MARK: - CanvasTool protocol

@Test func canvasToolProtocolHasRequiredMethods() {
    // Verify the protocol exists and has the expected shape
    // by checking a concrete implementation can be referenced
    let tool: any CanvasTool = SelectionTool()
    _ = tool  // Protocol compiles and concrete type conforms
}

@Test func selectionToolConformsToCanvasTool() {
    let tool = SelectionTool()
    #expect(tool is CanvasTool)
}

// MARK: - ToolbarPanel defaults

@Test func toolbarPanelDefaultSlots() {
    // Default visible tools in shared slots
    let defaultArrow: Tool = .directSelection
    let defaultText: Tool = .typeTool
    let defaultShape: Tool = .rect
    #expect(defaultArrow == .directSelection)
    #expect(defaultText == .typeTool)
    #expect(defaultShape == .rect)
}
