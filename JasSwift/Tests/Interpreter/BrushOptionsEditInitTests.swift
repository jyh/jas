import Foundation
import Testing
@testable import JasLib

// Brush Options in library_edit loads the brush it edits (2026-10-15), as the
// reference's test_brush_options_edit_init.py and Rust's
// brush_options_library_edit_loads_the_brush_in_the_engine. Its inits find the
// brush by `filter(...brushes, fun b -> b.slug == ...)[0]` and read `data`
// from the STORE's context, which did not carry it until then in any port.
private func openBrushOptions(_ params: [String: Any]) throws -> StateStore {
    let ws = try #require(WorkspaceData.load())
    let actions = ws.actions()
    let action = try #require(actions["open_brush_options"] as? [String: Any])
    let effects = try #require(action["effects"] as? [Any])
    // This file is JasSwift/Tests/Interpreter/<file>; the repo root is three up.
    let root = (((#filePath as NSString).deletingLastPathComponent as NSString)
        .deletingLastPathComponent as NSString).deletingLastPathComponent
    let path = ((root as NSString)
        .appendingPathComponent("../workspace/brushes/default_brushes/library.json") as NSString)
        .standardizingPath
    let bytes = try #require(FileManager.default.contents(atPath: path))
    let lib = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    let store = StateStore()
    store.setData(["brush_libraries": ["default_brushes": lib]])
    runEffects(effects, ctx: ["param": params], store: store, actions: actions, dialogs: ws.dialogs())
    return store
}

private func dialogValues(_ store: StateStore) -> String {
    let keys = ["brush_name", "brush_type", "angle", "roundness", "size"]
    return keys.map { "\(store.getDialog($0) ?? "nil")" }.joined(separator: "|")
}

@Test func brushOptionsLibraryEditLoadsTheBrushItEdits() throws {
    let store = try openBrushOptions(["mode": "library_edit", "library": "default_brushes",
                                      "brush_slug": "round_7pt"])
    #expect(dialogValues(store) == "7 pt. Round|calligraphic|0|100|7")
}

@Test func brushOptionsCreateKeepsTheDeclaredDefaults() throws {
    let store = try openBrushOptions(["mode": "create"])
    #expect(dialogValues(store) == "|calligraphic|0|100|5")
}

@Test func theStoreContextCarriesData() {
    let store = StateStore()
    store.setData(["brush_libraries": ["x": ["brushes": [Any]()]]])
    let data = store.evalContext()["data"] as? [String: Any]
    #expect(data?["brush_libraries"] != nil, "the store's data is in its context")
}
