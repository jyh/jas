import Testing
import Foundation
@testable import JasLib

/// G11 (STATUS-jas row 73), the design's §0 UNMEASURED premise, measured
/// first: does `enter_isolation_mode` / `exit_isolation_mode`, DISPATCHED
/// FROM A TOOL'S `on_dblclick`, reach the document's isolation stack
/// (`Model.layersIsolationStack`)? The action writes `panel.isolation_stack`,
/// and a tool dispatch has no panel scope of its own. MEASURED 2026-11-07:
/// NO (enter left `[]`, exit left `[[0, 0]]`, while the `zoom_in` control from
/// the same handler landed). These are now the arms of the fix: the shared
/// routes in `layersStackEffects`, merged into the tool's effect table.

private func isolationModel() -> Model {
    let inner = Element.group(Group(children: [.rect(Rect(x: 0, y: 0, width: 10, height: 10))]))
    return Model(document: Document(
        layers: [Layer(children: [inner])],
        selectedLayer: 0, selection: []
    ))
}

private func probeTool(_ effects: [[String: Any]]) -> YamlTool? {
    YamlTool.fromWorkspaceTool([
        "id": "g11_probe",
        "handlers": ["on_dblclick": effects],
    ])
}

private func ctxFor(_ model: Model) -> ToolContext {
    ToolContext(
        model: model, controller: Controller(model: model),
        hitTestSelection: { _ in false }, hitTestHandle: { _ in nil },
        hitTestText: { _ in nil }, hitTestPathCurve: { _, _ in nil },
        requestUpdate: {}, drawElementOverlay: { _, _, _ in })
}

@Test func g11ProbeAToolDispatchedEnterReachesTheModelStack() throws {
    let model = isolationModel()
    let tool = try #require(probeTool([
        ["dispatch": ["action": "enter_isolation_mode", "params": ["container_id": "'0.0'"]]],
    ]))
    tool.onDoubleClick(ctxFor(model), x: 5, y: 5)
    #expect(model.layersIsolationStack == [[0, 0]], "PROBE: the stack after a tool-dispatched enter is \(model.layersIsolationStack)")
}

@Test func g11ProbeAToolDispatchedExitReachesTheModelStack() throws {
    let model = isolationModel()
    model.layersIsolationStack = [[0, 0]]
    let tool = try #require(probeTool([
        ["dispatch": ["action": "exit_isolation_mode"]],
    ]))
    tool.onDoubleClick(ctxFor(model), x: 5, y: 5)
    #expect(model.layersIsolationStack == [], "PROBE: the stack after a tool-dispatched exit is \(model.layersIsolationStack)")
}

/// The CONTROL: the same handler path runs, and a DOCUMENT action dispatched
/// from it does land. Without this, the two probes above cannot tell "the
/// stack is not bridged" from "on_dblclick never ran".
@Test func g11ProbeControlAToolDispatchedDocumentActionLands() throws {
    let model = isolationModel()
    let tool = try #require(probeTool([
        ["dispatch": ["action": "zoom_in", "params": ["anchor_x": "event.x", "anchor_y": "event.y"]]],
    ]))
    let before = model.zoomLevel
    tool.onDoubleClick(ctxFor(model), x: 5, y: 5)
    #expect(model.zoomLevel > before, "CONTROL: zoom_in from a tool (zoom.yaml's own form) left zoom \(before) -> \(model.zoomLevel)")
}

/// The shared `pop` REPLACES the store's generic pop for every target, so a
/// target it does not route must still pop (`genericPop`), never be dropped.
@Test func layersStackPopFallsThroughForAnotherTarget() throws {
    let model = isolationModel()
    model.layersIsolationStack = [[0, 0]]
    let store = StateStore()
    store.set("g11_list", [1, 2, 3])
    let pop = try #require(layersStackEffects(model: model)["pop"])
    _ = pop("g11_list", [:], store)
    #expect((store.get("g11_list") as? [Int]) == [1, 2], "the other target was not popped")
    #expect(model.layersIsolationStack == [[0, 0]], "a non-isolation pop touched the isolation stack")
}
