import Foundation
import Testing
@testable import JasLib

// `swatch.save_library: { library, name }` (design 2026-10-28 §3.4): the
// brush law over the swatch libraries, which on the Mac are app-global
// (`model.swatchLibraries`). Row for row with test_swatch_save_library.py.

private func saveSwatches(_ name: Any, library: Any = "web_colors") -> Model {
    let model = Model()
    model.swatchLibraries.libs = [
        "web_colors": ["name": "Web Colors", "swatches": [["name": "Red", "color": "#ff0000"]]],
        "my_swatches": ["name": "My Swatches", "swatches": [[String: Any]]()],
    ]
    let store = model.stateStore
    store.initPanel("swatches", defaults: [
        "selected_library": library, "selected_swatches": [0],
        "open_libraries": [["id": "web_colors", "collapsed": true]],
    ])
    store.setActivePanel("swatches")
    let handler = buildYamlToolEffects(model: model)["swatch.save_library"]
    #expect(handler != nil, "swatch.save_library is not in the tool table")
    _ = handler?(["library": "param.lib", "name": "param.name"],
                 ["param": ["lib": library, "name": name]], store)
    return model
}

private func json(_ v: Any?) -> String {
    guard let v, let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return "nil" }
    return String(data: d, encoding: .utf8) ?? "nil"
}

@Test func swatchSaveLibrarySavesANewLibraryOpenedSelectedAndQueued() {
    let m = saveSwatches("Sunset Palette")
    #expect(json(m.swatchLibraries.libs["sunset_palette"])
            == json(["name": "Sunset Palette", "swatches": [["name": "Red", "color": "#ff0000"]]]))
    #expect((m.swatchLibraries.libs["web_colors"] as? [String: Any])?["name"] as? String == "Web Colors")
    #expect(json(m.stateStore.getPanel("swatches_panel_content", "open_libraries"))
            == json([["id": "web_colors", "collapsed": true], ["id": "sunset_palette", "collapsed": false]]))
    #expect(m.stateStore.getPanel("swatches_panel_content", "selected_library") as? String == "sunset_palette")
    #expect(json(m.stateStore.pendingWrites) == json([["kind": "swatch_library", "slug": "sunset_palette",
        "manifest": ["name": "Sunset Palette", "swatches": [["name": "Red", "color": "#ff0000"]]]]]))
}

@Test func swatchSaveLibraryInPlaceSuffixAndNoOps() {
    let m = saveSwatches("Web  Colors!")
    #expect((m.swatchLibraries.libs["web_colors"] as? [String: Any])?["name"] as? String == "Web  Colors!")
    #expect(m.swatchLibraries.libs.count == 2, "in place")
    #expect(m.stateStore.getPanel("swatches_panel_content", "selected_library") as? String == "web_colors")
    #expect(saveSwatches("My Swatches").swatchLibraries.libs["my_swatches_2"] != nil, "the first free suffix")
    for (name, lib) in [("", "web_colors"), ("X", "nowhere"), ("X", "")] {
        let m = saveSwatches(name, library: lib)
        #expect(m.stateStore.pendingWrites.isEmpty, "\(name) \(lib)")
        #expect(m.swatchLibraries.libs.count == 2, "\(name) \(lib)")
    }
}
