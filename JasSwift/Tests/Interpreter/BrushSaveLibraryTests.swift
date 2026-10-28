import Foundation
import Testing
@testable import JasLib

// `brush.save_library: { library, name }`, Save Brush Library's confirm (the
// 2026-10-28 jas brush-library design, B.2). Row for row with the reference's
// test_brush_save_library.py.

private let libsFixture: [String: Any] = [
    "default_brushes": ["name": "Default Brushes", "brushes": [["slug": "basic", "name": "Basic"]]],
    "my_brushes": ["name": "My Brushes", "brushes": [[String: Any]]()],
    "my_brushes_2": ["name": "My Brushes 2", "brushes": [[String: Any]]()],
]

private func save(_ name: Any, library: Any = "default_brushes",
                  libs: [String: Any] = libsFixture) -> StateStore {
    let model = Model()
    let store = model.stateStore
    store.setData(["brush_libraries": libs])
    store.initPanel("brushes", defaults: [
        "selected_library": library, "selected_brushes": ["basic"],
        "open_libraries": [["id": "default_brushes", "collapsed": true]],
    ])
    store.setActivePanel("brushes")
    let handler = buildYamlToolEffects(model: model)["brush.save_library"]
    #expect(handler != nil, "brush.save_library is not in the tool table")
    _ = handler?(["library": "param.lib", "name": "param.name"],
                 ["param": ["lib": library, "name": name]], store)
    return store
}

private func json(_ v: Any?) -> String {
    guard let v, let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return "nil" }
    return String(data: d, encoding: .utf8) ?? "nil"
}

private func libs(_ s: StateStore) -> [String: Any] { (s.getDataPath("brush_libraries") as? [String: Any]) ?? [:] }

private let slugRows: [(String, String)] = [
    ("Calligraphy Set", "calligraphy_set"),
    ("  Ink -- & Wash!  ", "ink_wash"),
    ("\u{dc}ber 7", "ber_7"),
    ("--- !!! ---", "library"),
    ("\u{212a}elvin", "elvin"),  // ASCII-only lower-casing: the Kelvin sign is not "k"
]

@Test func saveLibrarySlugIsDerivedFromTheName() {
    for (name, slug) in slugRows {
        let s = save(name)
        #expect((libs(s)[slug] as? [String: Any])?["name"] as? String == name, "\(name) -> \(slug)")
    }
    #expect(Set(slugRows.map(\.1)).count == slugRows.count, "slug rows pairwise distinct")
}

@Test func saveLibraryNewIsADeepCopyWithTheNewName() {
    let s = save("Calligraphy Set")
    #expect(json(libs(s)["calligraphy_set"]) == #"{"brushes":[{"name":"Basic","slug":"basic"}],"name":"Calligraphy Set"}"#)
    #expect((libs(s)["default_brushes"] as? [String: Any])?["name"] as? String == "Default Brushes")
}

@Test func saveLibraryNewOpensExpandedAndBecomesTheSelection() {
    let s = save("Calligraphy Set")
    #expect(json(s.getPanel("brushes", "open_libraries"))
            == #"[{"collapsed":true,"id":"default_brushes"},{"collapsed":false,"id":"calligraphy_set"}]"#)
    #expect(s.getPanel("brushes", "selected_library") as? String == "calligraphy_set")
    #expect(s.getPanel("brushes", "selected_brushes") as? [String] == ["basic"])
}

@Test func saveLibraryOwnSlugSavesInPlace() {
    let s = save("Default Brushes!")
    #expect(Set(libs(s).keys) == Set(libsFixture.keys))
    #expect((libs(s)["default_brushes"] as? [String: Any])?["name"] as? String == "Default Brushes!")
    #expect(json(s.getPanel("brushes", "open_libraries")) == #"[{"collapsed":true,"id":"default_brushes"}]"#)
    #expect(s.getPanel("brushes", "selected_library") as? String == "default_brushes")
}

@Test func saveLibraryAnotherSlugTakesTheFirstFreeSuffix() {
    #expect(libs(save("My Brushes"))["my_brushes_3"] != nil)
    var two = libsFixture; two.removeValue(forKey: "my_brushes_2")
    #expect(libs(save("My Brushes", libs: two))["my_brushes_2"] != nil)
}

@Test func saveLibraryQueuesOneWriteForTheHost() {
    let s = save("Calligraphy Set")
    #expect(json(s.pendingWrites)
            == #"[{"kind":"brush_library","manifest":{"brushes":[{"name":"Basic","slug":"basic"}],"name":"Calligraphy Set"},"slug":"calligraphy_set"}]"#)
    #expect(save("Default Brushes").pendingWrites.compactMap { $0["slug"] as? String } == ["default_brushes"])
}

@Test func saveLibraryEmptyNameOrMissingSourceIsANoOp() {
    for (name, lib) in [("", "default_brushes"), ("X", "nowhere")] as [(Any, Any)] {
        let s = save(name, library: lib)
        #expect(json(libs(s)) == json(libsFixture), "\(name) \(lib)")
        #expect(s.pendingWrites.isEmpty)
        #expect(json(s.getPanel("brushes", "open_libraries")) == #"[{"collapsed":true,"id":"default_brushes"}]"#)
    }
    let s = save(NSNull(), library: NSNull())
    #expect(s.pendingWrites.isEmpty)
    #expect(StateStore().pendingWrites.isEmpty)
}
