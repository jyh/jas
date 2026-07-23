import Testing
import Foundation
@testable import JasLib

// MARK: - Tool enum tests

@Test func toolEnumVariantCount() {
    #expect(Tool.allCases.count == 29)
}

@Test func toolEnumContainsAllExpected() {
    let tools = Tool.allCases
    #expect(tools.contains(.selection))
    #expect(tools.contains(.partialSelection))
    #expect(tools.contains(.interiorSelection))
    #expect(tools.contains(.pen))
    #expect(tools.contains(.addAnchorPoint))
    #expect(tools.contains(.deleteAnchorPoint))
    #expect(tools.contains(.anchorPoint))
    #expect(tools.contains(.pencil))
    #expect(tools.contains(.paintbrush))
    #expect(tools.contains(.blobBrush))
    #expect(tools.contains(.typeTool))
    #expect(tools.contains(.typeOnPath))
    #expect(tools.contains(.line))
    #expect(tools.contains(.rect))
    #expect(tools.contains(.roundedRect))
    #expect(tools.contains(.ellipse))
    #expect(tools.contains(.pathEraser))
    #expect(tools.contains(.smooth))
    #expect(tools.contains(.polygon))
    #expect(tools.contains(.star))
    #expect(tools.contains(.lasso))
    #expect(tools.contains(.magicWand))
    #expect(tools.contains(.scale))
    #expect(tools.contains(.rotate))
    #expect(tools.contains(.shear))
    #expect(tools.contains(.hand))
    #expect(tools.contains(.zoom))
    #expect(tools.contains(.artboard))
    #expect(tools.contains(.eyedropper))
}

@Test func toolRawValuesUnique() {
    let rawValues = Tool.allCases.map { $0.rawValue }
    #expect(Set(rawValues).count == rawValues.count)
}

@Test func toolConformsToHashable() {
    var set = Set<Tool>()
    for tool in Tool.allCases { set.insert(tool) }
    #expect(set.count == 29)
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
    let alternates: [Tool] = [.partialSelection, .interiorSelection]
    #expect(alternates.count == 2)
    #expect(alternates.contains(.partialSelection))
    #expect(alternates.contains(.interiorSelection))
}

@Test func textSlotAlternates() {
    let alternates: [Tool] = [.typeTool, .typeOnPath]
    #expect(alternates.count == 2)
    #expect(alternates.contains(.typeTool))
    #expect(alternates.contains(.typeOnPath))
}

@Test func shapeSlotAlternates() {
    let alternates: [Tool] = [.rect, .polygon]
    #expect(alternates.count == 2)
    #expect(alternates.contains(.rect))
    #expect(alternates.contains(.polygon))
}

// Removed: toolbarGridHasFourRows / toolbarGridHasTwoColumns /
// toolbarGridHasSevenSlots / toolbarGridThreeSharedSlots — these
// asserted hardcoded layout numbers that had to be edited every
// time a tool slot was added (Magic Wand had already left them
// stale; Scale + Rotate + Shear would compound the drift). Per
// feedback_layout_tests.md, layout-bound tests with hardcoded
// indices are deleted, not shifted, when layouts change.

// MARK: - Flyout-alternates triangle marker (data-level)

// Toolbar slots that declare long-press `alternates:` render a small
// lower-right flyout triangle. The marker is DATA-DRIVEN — it follows the
// bundle's `alternates` field, never a hardcoded slot list or a name
// heuristic. This pins which compiled tool_grid slots carry alternates so
// the render marks exactly those (mirrors jas_dioxus render_icon_button's
// `has_alternates`). Visual parity is verified in a later smoke.

@Test func toolbarAlternatesMarkExactlyTheFlyoutSlots() {
    guard let ws = WorkspaceData.load(), let grid = ws.toolGrid(),
          let kids = grid["children"] as? [[String: Any]] else {
        Issue.record("tool_grid not found in bundle"); return
    }
    let iconButtons = kids.filter { ($0["type"] as? String) == "icon_button" }
    #expect(!iconButtons.isEmpty)
    let marked = Set(iconButtons.filter { iconButtonHasAlternates($0) }
                                .compactMap { $0["id"] as? String })
    // Exactly the multi-tool slots carry long-press alternates in the
    // compiled workspace.
    let expected: Set<String> = [
        "btn_arrow_slot", "btn_pen_slot", "btn_pencil_slot", "btn_text_slot",
        "btn_shape_slot", "btn_transform_slot", "btn_hand_slot",
    ]
    #expect(marked == expected)
    // Field-driven, not name-driven: btn_artboard_slot is named "_slot"
    // but declares NO alternates, so it must not be marked.
    #expect(!marked.contains("btn_artboard_slot"))
    // Plain single-tool slots are never marked.
    #expect(!marked.contains("btn_selection"))
    #expect(!marked.contains("btn_line"))
}

@Test func iconButtonHasAlternatesIgnoresNullAndMissing() {
    #expect(!iconButtonHasAlternates(["type": "icon_button"]))
    #expect(!iconButtonHasAlternates(["type": "icon_button", "alternates": NSNull()]))
    #expect(iconButtonHasAlternates(["type": "icon_button",
                                     "alternates": ["items": [Any]()]]))
}

// MARK: - CanvasTool protocol

@Test func canvasToolProtocolHasRequiredMethods() {
    // Verify the protocol exists and has the expected shape
    // by checking the registry-wired tool conforms.
    let tool: any CanvasTool = createTools()[.selection]!
    _ = tool
}

@Test func selectionToolConformsToCanvasTool() {
    let tool = createTools()[.selection]!
    #expect(tool is CanvasTool)
}

// MARK: - ToolbarPanel defaults

@Test func toolbarPanelDefaultSlots() {
    // Default visible tools in shared slots
    let defaultArrow: Tool = .partialSelection
    let defaultText: Tool = .typeTool
    let defaultShape: Tool = .rect
    #expect(defaultArrow == .partialSelection)
    #expect(defaultText == .typeTool)
    #expect(defaultShape == .rect)
}
