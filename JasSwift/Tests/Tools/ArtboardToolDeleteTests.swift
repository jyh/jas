import Testing
import Foundation
@testable import JasLib

// THE ARTBOARD TOOL'S DELETE (ARTBOARD_TOOL.md §Delete behavior), as Rust's
// the_artboard_tools_delete_deletes_the_panel_selected_artboards: with
// artboards selected in the Artboards panel, Delete deletes THEM; with none,
// it falls through to `delete_selection` (the elements). The tool claims the
// key (`claims_keys`) and the host hands it the panel selection
// (`setDocumentFacts`). Until 2026-10-15 every port ran the global delete
// first, and the branch's `len(...)` was no function in any port.

private func artboardTool() throws -> YamlTool {
    let ws = try #require(WorkspaceData.load())
    let tools = try #require(ws.data["tools"] as? [String: Any])
    let spec = try #require(tools["artboard"] as? [String: Any])
    return try #require(YamlTool.fromWorkspaceTool(spec))
}

private func model() -> Model {
    let rect = Element.rect(Rect(x: 10, y: 10, width: 20, height: 20))
    let abs = (0..<3).map { i in
        Artboard(id: "ab000\(i)", name: "Artboard \(i + 1)", x: Double(i) * 700, y: 0,
                 width: 612, height: 792, fill: .transparent,
                 showCenterMark: false, showCrossHairs: false,
                 showVideoSafeAreas: false, videoRulerPixelAspectRatio: 1.0)
    }
    return Model(document: Document(layers: [Layer(name: "L", children: [rect])],
                                    selectedLayer: 0, selection: [ElementSelection.all([0, 0])],
                                    artboards: abs))
}

private func ctx(_ m: Model) -> ToolContext {
    ToolContext(model: m, controller: Controller(model: m),
                hitTestSelection: { _ in false }, hitTestHandle: { _ in nil },
                hitTestText: { _ in nil }, hitTestPathCurve: { _, _ in nil },
                requestUpdate: {}, drawElementOverlay: { _, _, _ in })
}

@Test func theArtboardToolClaimsDeleteAndBackspace() throws {
    let tool = try artboardTool()
    #expect(tool.claimsKey("Delete") && tool.claimsKey("Backspace"))
    #expect(!tool.claimsKey("Escape"), "the control: a key it does not claim")
}

@Test func theArtboardToolsDeleteDeletesThePanelSelectedArtboards() throws {
    let tool = try artboardTool()
    let m = model()
    tool.setDocumentFacts(["artboards_panel_selection_ids": ["ab0001"]])
    #expect(tool.onKeyEvent(ctx(m), "Delete", KeyMods(shift: false, ctrl: false, alt: false, cmd: false)))
    #expect(m.document.artboards.map(\.id) == ["ab0000", "ab0002"], "the panel-selected artboard is deleted")
    #expect(m.document.selection.count == 1, "the elements stay")
}

@Test func theArtboardToolsDeleteFallsThroughToDeleteSelection() throws {
    let tool = try artboardTool()
    let m = model()
    tool.setDocumentFacts(["artboards_panel_selection_ids": [String]()])
    #expect(tool.onKeyEvent(ctx(m), "Delete", KeyMods(shift: false, ctrl: false, alt: false, cmd: false)))
    #expect(m.document.artboards.count == 3, "no artboard is deleted")
    #expect(m.document.layers[0].children.isEmpty, "nothing panel-selected: the element is deleted")
}
