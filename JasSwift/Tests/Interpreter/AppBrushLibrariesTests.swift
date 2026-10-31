import Testing
@testable import JasLib

// The brush libraries are APP-GLOBAL (STATUS-jas row 59), as jas_dioxus holds
// them on `AppState.brush_libraries`, shared across every tab. Since #649 the
// Mac kept them in each canvas's `stateStore`, so a brush edited in one tab
// was not seen in another. The workspace now installs ONE store-independent
// tier (`AppBrushLibraries`) into every adopted canvas, as it does for the
// swatch libraries and the app defaults.

private func blankModel() -> Model { Model(document: Document.newEmptyDocument()) }

@Test func aBrushLibraryEditInOneCanvasIsReadInAnother() {
    let workspace = WorkspaceState()
    let a = blankModel(), b = blankModel()
    workspace.addCanvas(a)
    workspace.addCanvas(b)
    a.stateStore.setDataPath("brush_libraries.zz_row59", ["name": "Mine", "brushes": []])
    #expect(b.stateStore.getDataPath("brush_libraries.zz_row59.name") as? String == "Mine",
            "the second tab reads the first tab's edit")
    // The expression context too: a dialog init or a panel bind reads data.*.
    let data = b.stateStore.evalContext()["data"] as? [String: Any]
    let libs = data?["brush_libraries"] as? [String: Any]
    #expect((libs?["zz_row59"] as? [String: Any])?["name"] as? String == "Mine")
    // And the other way round.
    b.stateStore.setDataPath("brush_libraries.zz_row59.name", "Renamed")
    #expect(a.stateStore.getDataPath("brush_libraries.zz_row59.name") as? String == "Renamed")
}

@Test func aCanvasOpenedAfterTheEditReadsIt() {
    let workspace = WorkspaceState()
    let a = blankModel()
    workspace.addCanvas(a)
    a.stateStore.setDataPath("brush_libraries.zz_row59", ["name": "Mine", "brushes": []])
    let later = blankModel()
    workspace.addCanvas(later)
    #expect(later.stateStore.getDataPath("brush_libraries.zz_row59.name") as? String == "Mine",
            "a tab opened later adopts the tier, not its own fresh seed")
}

@Test func theSharedTierKeepsTheShippedLibraries() {
    let workspace = WorkspaceState()
    let a = blankModel()
    let seeded = (a.stateStore.getDataPath("brush_libraries") as? [String: Any]).map { Set($0.keys) }
    workspace.addCanvas(a)
    let adopted = (a.stateStore.getDataPath("brush_libraries") as? [String: Any]).map { Set($0.keys) }
    #expect(seeded != nil && !(seeded?.isEmpty ?? true), "CONTROL: the bundle ships brush libraries")
    #expect(adopted == seeded, "adoption keeps the shipped libraries")
}

@Test func twoCanvasesNoWorkspaceAdoptedKeepTheirOwn() {
    // The control: without the workspace, two bare models do not share, so
    // the arms above cannot pass through a process-wide static.
    let a = blankModel(), b = blankModel()
    a.stateStore.setDataPath("brush_libraries.zz_row59", ["name": "Mine", "brushes": []])
    #expect(b.stateStore.getDataPath("brush_libraries.zz_row59") == nil)
}

@Test func otherDataKeysStayPerStore() {
    // Only `brush_libraries` is app-global; the rest of `data` stays the
    // store's own.
    let workspace = WorkspaceState()
    let a = blankModel(), b = blankModel()
    workspace.addCanvas(a)
    workspace.addCanvas(b)
    a.stateStore.setDataPath("zz_row59_other", "a")
    #expect(b.stateStore.getDataPath("zz_row59_other") == nil)
}
