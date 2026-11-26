import Testing
import Foundation
@testable import JasLib

// Row 275, the Mac slice (b): an input script's `app_state` is seeded into the
// live app by the test-only `--test-fifo` `seed <json>` verb, through the SAME
// parse-and-apply the level-1 forms runner uses (ScriptPanelSeeds), so the two
// cannot disagree about which forms are ruled (docs/TESTING.md section 6:
// `app_state.panels.<content id>.<declared key>`, an index array in a list is
// a PATH). Anything else is refused by name, never dropped.

@Test func fifoSeedWritesADeclaredPanelKeyIntoTheStore() throws {
    let model = Model()
    let receipt = try FifoSeed.run(
        #"{"panels":{"artboards_panel_content":{"artboards_panel_selection":["zs8ap4x3"]}}}"#, model: model)
    #expect(receipt == "1 key(s): artboards_panel_content.artboards_panel_selection")
    #expect(model.stateStore.getPanel("artboards_panel_content", "artboards_panel_selection") as? [String]
            == ["zs8ap4x3"])
}

@Test func fifoSeedRefusesAnUndeclaredKeyByName() {
    let model = Model()
    #expect(throws: FifoReadError.self) {
        try FifoSeed.run(#"{"panels":{"artboards_panel_content":{"zork":1}}}"#, model: model)
    }
    #expect((try? FifoSeed.run(#"{"panels":{"artboards_panel_content":{"zork":1}}}"#, model: model)) == nil)
    let why = ScriptPanelSeeds.parse(["panels": ["artboards_panel_content": ["zork": 1]]])
    if case .failure(let r) = why { #expect(r.description.contains("UndeclaredPanelKey artboards_panel_content.zork")) }
    else { Issue.record("an undeclared key parsed") }
}

@Test func fifoSeedRefusesAFormThatIsNotPanels() {
    let why = ScriptPanelSeeds.parse(["tools": ["x": 1]])
    if case .failure(let r) = why { #expect(r.description.contains("app_state.tools is not a ruled form")) }
    else { Issue.record("a non-panels app_state parsed") }
    #expect(throws: FifoReadError.self) { try FifoSeed.run("not json", model: Model()) }
}

@Test func fifoSeedMarksAnIndexArrayInAListAsAPath() {
    guard case .success(let seeds) = ScriptPanelSeeds.parse(
        ["panels": ["layers_panel_content": ["isolation_stack": [[0, 1]]]]]) else {
        Issue.record("a declared path list did not parse"); return
    }
    #expect(seeds.count == 1)
    let model = Model()
    ScriptPanelSeeds.apply(seeds, model: model)
    // A key the app holds on the Model is seeded there (modelHeldPanelState).
    #expect(model.layersIsolationStack == [[0, 1]])
}
