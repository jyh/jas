import Testing
import Foundation
@testable import JasLib

// THE ARTBOARD TOOL ON THE POINTER SEES AND WRITES THE ARTBOARDS PANEL'S
// SELECTION (ARTBOARD_TOOL.md §Mousedown disambiguation order,
// §Click-to-activate), as Rust's
// the_artboard_tool_on_the_pointer_route_sees_and_writes_the_panel_selection.
// The tool runs on its own store, so the host hands it the panel's facts
// (`setDocumentFacts`: selection and anchor) and the click's selection lands
// in the model's store, where the Artboards panel reads it. Until 2026-10-16
// the probe read only the tool's store, so a panel-selected artboard showed
// the tool no handles (a press on its corner MOVED it), and the click wrote
// into a store no panel reads.

private func artboardTool() throws -> YamlTool {
    let ws = try #require(WorkspaceData.load())
    let tools = try #require(ws.data["tools"] as? [String: Any])
    let spec = try #require(tools["artboard"] as? [String: Any])
    return try #require(YamlTool.fromWorkspaceTool(spec))
}

// Three Letter artboards side by side: ab0000 at x 0, ab0001 at 700, ab0002
// at 1400. Zoom 1, no pan, so a pointer point is a document point.
private func model() -> Model {
    let abs = (0..<3).map { i in
        Artboard(id: "ab000\(i)", name: "Artboard \(i + 1)", x: Double(i) * 700, y: 0,
                 width: 612, height: 792, fill: .transparent,
                 showCenterMark: false, showCrossHairs: false,
                 showVideoSafeAreas: false, videoRulerPixelAspectRatio: 1.0)
    }
    let m = Model(document: Document(layers: [Layer(name: "L", children: [])],
                                     selectedLayer: 0, selection: [], artboards: abs))
    m.zoomLevel = 1
    m.viewOffsetX = 0
    m.viewOffsetY = 0
    return m
}

private func ctx(_ m: Model) -> ToolContext {
    ToolContext(model: m, controller: Controller(model: m),
                hitTestSelection: { _ in false }, hitTestHandle: { _ in nil },
                hitTestText: { _ in nil }, hitTestPathCurve: { _, _ in nil },
                requestUpdate: {}, drawElementOverlay: { _, _, _ in })
}

private func gesture(_ tool: YamlTool, _ m: Model, from: (Double, Double), to: (Double, Double),
                     shift: Bool = false) {
    let c = ctx(m)
    tool.onPress(c, x: from.0, y: from.1, shift: shift, alt: false)
    if from != to {
        tool.onMove(c, x: to.0, y: to.1, shift: shift, alt: false, dragging: true)
    }
    tool.onRelease(c, x: to.0, y: to.1, shift: shift, alt: false)
}

private func bounds(_ m: Model, _ i: Int) -> [Double] {
    let ab = m.document.artboards[i]
    return [ab.x, ab.y, ab.width, ab.height]
}

@Test func aPressOnTheHandleOfThePanelSelectedArtboardResizesIt() throws {
    let tool = try artboardTool()
    let m = model()
    tool.setDocumentFacts(["artboards_panel_selection_ids": ["ab0001"]])
    gesture(tool, m, from: (1312, 792), to: (1362, 842))
    #expect(bounds(m, 1) == [700, 0, 662, 842], "the SE handle resizes; the NW corner stays")
    #expect(bounds(m, 0) == [0, 0, 612, 792], "the control: ab0000 is untouched")
}

@Test func aClickInsideAnArtboardSelectsItInThePanel() throws {
    let tool = try artboardTool()
    let m = model()
    tool.setDocumentFacts(["artboards_panel_selection_ids": [String]()])
    #expect(artboardsPanelSelectionIds(m).isEmpty, "the control: nothing is selected")
    gesture(tool, m, from: (1000, 400), to: (1000, 400))
    #expect(artboardsPanelSelectionIds(m) == ["ab0001"], "the click reaches the panel")
    #expect(bounds(m, 1) == [700, 0, 612, 792], "a click moves nothing")
}

@Test func aShiftClickRangesFromThePanelsAnchor() throws {
    let tool = try artboardTool()
    let m = model()
    tool.setDocumentFacts(["artboards_panel_selection_ids": ["ab0000"],
                           "artboards_panel_anchor": "ab0000"])
    gesture(tool, m, from: (1700, 400), to: (1700, 400), shift: true)
    #expect(artboardsPanelSelectionIds(m) == ["ab0000", "ab0001", "ab0002"],
            "the range runs from the anchor to the clicked artboard")
}

@Test func theHostsArtboardFactsCarryTheSelectionAndTheAnchor() throws {
    let m = model()
    m.stateStore.initPanel(artboardsPanelScope, defaults: [
        "artboards_panel_selection": ["ab0002"], "panel_selection_anchor": "ab0002"])
    let facts = artboardToolFacts(m)
    #expect((facts["artboards_panel_selection_ids"] as? [String]) == ["ab0002"])
    #expect((facts["artboards_panel_anchor"] as? String) == "ab0002")
}
