import Foundation
import Testing
@testable import JasLib

// The Mac host half of Save Brush Library (the 2026-10-28 jas brush-library
// design, B.3): `brush.save_library` queues `{kind, slug, manifest}` on the
// store, a sink the APP installs writes `<root>/brushes/<slug>/library.json`,
// and at launch the user's libraries shadow the bundle's by slug. Every arm
// uses its own temporary root: `swift test` never passes `--test-fifo`, so
// nothing here may touch the developer's Application Support.

private func tmpRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("jas-brushlib-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func json(_ v: Any?) -> String {
    guard let v, let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return "nil" }
    return String(data: d, encoding: .utf8) ?? "nil"
}

@Test func brushLibraryStoreWritesTheManifestUnderItsSlug() throws {
    let root = tmpRoot()
    let store = BrushLibraryStore(root: root)
    try store.write(slug: "calligraphy_set", manifest: ["name": "Calligraphy Set", "brushes": [[String: Any]]()])
    let file = root.appendingPathComponent("brushes/calligraphy_set/library.json")
    let back = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
    #expect(json(back) == #"{"brushes":[],"name":"Calligraphy Set"}"#)
}

@Test func brushLibraryStoreRefusesASlugOutsideItsAlphabet() {
    let root = tmpRoot()
    for bad in ["", "../x", "a/b", "A", "a.b"] {
        #expect(throws: (any Error).self, "\(bad)") {
            try BrushLibraryStore(root: root).write(slug: bad, manifest: ["name": "x"])
        }
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("x").path))
}

@Test func brushLibraryStoreLoadsWhatItWrote() throws {
    let store = BrushLibraryStore(root: tmpRoot())
    try store.write(slug: "b_lib", manifest: ["name": "B"])
    try store.write(slug: "a_lib", manifest: ["name": "A"])
    #expect(json(store.load()) == #"{"a_lib":{"name":"A"},"b_lib":{"name":"B"}}"#)
}

@Test func brushLibraryStoreLoadSkipsWhatIsNotALibrary() throws {
    let root = tmpRoot()
    let fm = FileManager.default
    let b = root.appendingPathComponent("brushes")
    try fm.createDirectory(at: b.appendingPathComponent("no_manifest"), withIntermediateDirectories: true)
    try fm.createDirectory(at: b.appendingPathComponent("bad_json"), withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: b.appendingPathComponent("bad_json/library.json"))
    try fm.createDirectory(at: b.appendingPathComponent("a_list"), withIntermediateDirectories: true)
    try Data("[1]".utf8).write(to: b.appendingPathComponent("a_list/library.json"))
    try Data("{}".utf8).write(to: b.appendingPathComponent("stray.json"))
    try BrushLibraryStore(root: root).write(slug: "good", manifest: ["name": "G"])
    #expect(json(BrushLibraryStore(root: root).load()) == #"{"good":{"name":"G"}}"#)
}

@Test func brushLibraryStoreLoadOfAMissingRootIsEmpty() {
    #expect(BrushLibraryStore(root: tmpRoot().appendingPathComponent("absent")).load().isEmpty)
}

@Test func userLibrariesShadowTheBundleBySlug() {
    let bundle: [String: Any] = ["default_brushes": ["name": "Default"], "other": ["name": "Other"]]
    let user: [String: Any] = ["default_brushes": ["name": "Mine"], "new_lib": ["name": "New"]]
    #expect(json(BrushLibraryStore.merged(bundle: bundle, user: user))
            == #"{"default_brushes":{"name":"Mine"},"new_lib":{"name":"New"},"other":{"name":"Other"}}"#)
}

@Test func aSinkDrainsEachWriteAndKeepsAFailedOne() {
    let s = StateStore()
    var seen: [String] = []
    s.pendingWriteSink = { w in
        let slug = w["slug"] as? String ?? ""
        seen.append(slug)
        return slug != "fails"
    }
    s.appendPendingWrite(["kind": "brush_library", "slug": "ok", "manifest": [:]])
    s.appendPendingWrite(["kind": "brush_library", "slug": "fails", "manifest": [:]])
    #expect(seen == ["ok", "fails"])
    #expect(s.pendingWrites.compactMap { $0["slug"] as? String } == ["fails"], "a failed write stays queued")
}

@Test func withoutASinkWritesStayQueued() {
    let s = StateStore()
    s.appendPendingWrite(["kind": "brush_library", "slug": "ok", "manifest": [:]])
    #expect(s.pendingWrites.count == 1)
}

@Test func aSavedLibraryReachesTheDiskThroughTheSink() throws {
    // End to end through the effect: the installed sink is the store's.
    let root = tmpRoot()
    let model = Model()
    let store = model.stateStore
    store.pendingWriteSink = BrushLibraryStore(root: root).sink
    store.setData(["brush_libraries": ["default_brushes": ["name": "Default Brushes", "brushes": [[String: Any]]()]]])
    store.initPanel("brushes", defaults: ["selected_library": "default_brushes", "open_libraries": [[String: Any]]()])
    _ = buildYamlToolEffects(model: model)["brush.save_library"]?(
        ["library": "\"default_brushes\"", "name": "\"Ink Set\""], [:], store)
    #expect(store.pendingWrites.isEmpty)
    #expect(json(BrushLibraryStore(root: root).load()) == #"{"ink_set":{"brushes":[],"name":"Ink Set"}}"#)
}

@Test func noLiveStoreIsInstalledUnderTest() {
    // The app sets `live` in `JasApp.init`; a test process must never have one,
    // or every `Model()` in the suite would read and write the developer's
    // Application Support.
    #expect(BrushLibraryStore.live == nil)
    #expect(Model().stateStore.pendingWriteSink == nil)
}
