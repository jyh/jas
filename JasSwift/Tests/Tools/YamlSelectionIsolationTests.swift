import Testing
import Foundation
@testable import JasLib

/// G11 (STATUS-jas row 73), driven through the SHIPPED selection tool
/// (`workspace/tools/selection.yaml`) on the shared hit-test fixture's
/// document: layer L = [group G [R1 at x 0, R2 at x 20], R3 at x 40, ...].
/// Double-click a group enters isolation; inside it a click selects the
/// group's child; a click outside the root selects nothing; double-click on
/// empty canvas exits one level; double-click a leaf does nothing new.

private func fixtureModel() throws -> Model {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("test_fixtures/layers/hit_test_root.json"))
    let fx = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let docData = try JSONSerialization.data(withJSONObject: fx["document"] as Any, options: [.sortedKeys])
    return Model(document: testJsonToDocument(String(data: docData, encoding: .utf8)!))
}

private func selection() throws -> YamlTool {
    let ws = try #require(WorkspaceData.load())
    let spec = try #require((ws.data["tools"] as? [String: Any])?["selection"] as? [String: Any])
    return try #require(YamlTool.fromWorkspaceTool(spec))
}

private func ctx(_ model: Model) -> ToolContext {
    ToolContext(
        model: model, controller: Controller(model: model),
        hitTestSelection: { _ in false }, hitTestHandle: { _ in nil },
        hitTestText: { _ in nil }, hitTestPathCurve: { _, _ in nil },
        requestUpdate: {}, drawElementOverlay: { _, _, _ in })
}

private func click(_ t: YamlTool, _ c: ToolContext, _ x: Double, _ y: Double) {
    t.onPress(c, x: x, y: y, shift: false, alt: false)
    t.onRelease(c, x: x, y: y, shift: false, alt: false)
}

private func doubleClick(_ t: YamlTool, _ c: ToolContext, _ x: Double, _ y: Double) {
    click(t, c, x, y); click(t, c, x, y)
    t.onDoubleClick(c, x: x, y: y)
}

private func selected(_ m: Model) -> [[Int]] {
    m.document.selection.map(\.path).sorted { $0.lexicographicallyPrecedes($1) }
}

@Test func g11DoubleClickAGroupEntersAndEmptyCanvasExits() throws {
    let model = try fixtureModel()
    let tool = try selection()
    let c = ctx(model)
    doubleClick(tool, c, 5, 5)
    #expect(model.layersIsolationStack == [[0, 0]], "double-click on G enters it")
    click(tool, c, 25, 5)
    #expect(selected(model) == [[0, 0, 1]], "inside isolation a click selects the group's child, not the group")
    click(tool, c, 45, 5)
    #expect(!selected(model).contains([0, 0]) && !selected(model).contains { $0.count > 2 },
            "a click outside the isolated group selects nothing inside it")
    // The miss starts a zero-size marquee; G11 step 4 scoped `doc.select_in_rect`
    // to the isolation root, so its release selects nothing. (Until then this
    // was a `withKnownIssue`: the release selected R3 [0, 1] outside G.)
    #expect(selected(model) == [], "a click outside the isolated group selects nothing")
    let band = ctx(model)
    tool.onPress(band, x: -1, y: -1, shift: false, alt: false)
    tool.onMove(band, x: 31, y: 11, shift: false, alt: false, dragging: true)
    tool.onRelease(band, x: 31, y: 11, shift: false, alt: false)
    #expect(selected(model) == [[0, 0, 0], [0, 0, 1]],
            "a marquee over G's members while G is isolated selects the members, never G")
    doubleClick(tool, c, 15, 50)
    #expect(model.layersIsolationStack == [], "double-click on empty canvas exits one level")
    click(tool, c, 25, 5)
    #expect(selected(model) == [[0, 0]], "after exit a click selects the group again")
}

@Test func g11DoubleClickANestedGroupStacksAndALeafDoesNothing() throws {
    let model = try fixtureModel()
    let tool = try selection()
    let c = ctx(model)
    doubleClick(tool, c, 45, 5)
    #expect(model.layersIsolationStack == [], "double-click on a leaf (R3) enters nothing")
    doubleClick(tool, c, 105, 5)
    #expect(model.layersIsolationStack == [[0, 2]], "double-click on the transformed group Moved enters it")
    doubleClick(tool, c, 105, 5)
    #expect(model.layersIsolationStack == [[0, 2], [0, 2, 0]], "a nested group stacks one more level")
    doubleClick(tool, c, 150, 50)
    #expect(model.layersIsolationStack == [[0, 2]], "empty canvas exits ONE level")
}

/// G11 step 4's FRAME arms (seat design 2026-11-08 §4 arms 4/5), which only
/// the ports carry: `Moved` [0, 2] is translated by (100, 0), so `Inner` answers
/// for R4 where R4 is DRAWN, and a walk dropping the root's frame would answer
/// where its raw geometry sits instead. Twin of Rust
/// `g11_marquee_composes_the_root_frame_both_directions`.
@Test func g11MarqueeComposesTheRootFrameBothDirections() throws {
    let model = try fixtureModel()
    let controller = Controller(model: model)
    controller.selectRect(x: 102, y: 2, width: 1, height: 1, root: [0, 2])
    #expect(selected(model) == [[0, 2, 0]], "Inner answers for R4 where it is drawn")
    controller.selectRect(x: 2, y: 2, width: 1, height: 1, root: [0, 2])
    #expect(selected(model) == [], "R4's untransformed geometry is not where it is drawn")
    controller.selectRect(x: 45, y: 5, width: 0, height: 0, root: [0, 0])
    #expect(selected(model) == [], "a band outside the root selects nothing")
    controller.selectRect(x: 2, y: 2, width: 1, height: 1, root: [0, 1])
    #expect(selected(model) == [], "a leaf root selects nothing, never the layer walk")
}
