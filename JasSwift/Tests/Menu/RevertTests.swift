import Testing
@testable import JasLib

// Revert's model-pure half, driven the way Rust's `revert_tests`
// (`jas_dioxus/src/workspace/clipboard.rs`) drives `apply_revert`. The menu's
// `revert()` keeps the confirmation alert and the file read; everything after
// "the artist said Revert" lives in `MenuActions.applyRevert`, so it has an arm.

/// A baseline with IDENTIFIABLE content: an empty `<svg/>` parses to the same
/// one-empty-layer shape the dirtying edit produces, and could not tell the
/// two states apart.
private let saved = #"<svg xmlns="http://www.w3.org/2000/svg"><rect x="1" y="2" width="3" height="4"/></svg>"#

/// A file that states its paper on its root and declares no pages: Open puts
/// it on a 5 x 7 in sheet, the bare codec read leaves it with no artboard.
private let sheet = #"<svg xmlns="http://www.w3.org/2000/svg" width="5in" height="7in" viewBox="0 0 360 504"><rect x="1" y="2" width="3" height="4"/></svg>"#

/// A model that has a saved version on disk (a non-`Untitled-` filename) and
/// has been edited since.
private func dirtyModel(filename: String = "/tmp/hull.svg") -> Model {
    let model = Model(document: documentForOpen(saved), filename: filename)
    model.markSaved()
    model.editDocument(Document(layers: [Layer(name: "L0", children: [])]))
    return model
}

/// Artboards without their ids: the artboard invariant mints a fresh random id
/// on every read of a page-less file, so two reads of one file differ only there.
private func sheets(_ doc: Document) -> [[Double]] {
    doc.artboards.map { [$0.x, $0.y, $0.width, $0.height] }
}

/// The artwork, compared in canonical SVG with the artboards set aside.
private func artwork(_ doc: Document) -> String {
    documentToSvg(doc.replacing(artboards: []))
}

@Test func revertIsOfferedOnlyWithChangesAndASavedVersion() {
    let clean = Model(document: documentForOpen(saved), filename: "/tmp/hull.svg")
    clean.markSaved()
    #expect(!MenuActions.canRevert(clean), "an unmodified document has nothing to revert")

    let untitled = dirtyModel(filename: "Untitled-3")
    #expect(!MenuActions.canRevert(untitled), "a never-saved document has no baseline")

    #expect(MenuActions.canRevert(dirtyModel()))
}

@Test func revertRestoresTheBaselineAsOneUndoableStep() {
    let model = dirtyModel()
    let edited = artwork(model.document)
    #expect(edited != artwork(documentForOpen(saved)), "control: the edit must change the artwork")

    #expect(MenuActions.applyRevert(model, svg: saved))

    #expect(!model.isModified, "a completed revert leaves the document clean")
    #expect(artwork(model.document) == artwork(documentForOpen(saved)),
            "the edit is gone and the saved rect is back")
    model.undo()
    #expect(artwork(model.document) == edited,
            "ONE undo takes the revert back, to the edited document -- Rust's one transaction")
}

@Test func revertLandsOnTheSheetOpenGives() {
    let opened = documentForOpen(sheet)
    #expect(sheets(opened) != sheets(svgToDocument(sheet)),
            "control: Open and the codec must differ on this file")

    let model = dirtyModel()
    #expect(MenuActions.applyRevert(model, svg: sheet))
    #expect(sheets(model.document) == sheets(opened), "Revert must land on the sheet Open gives")
}

@Test func aRefusedRevertChangesNothing() {
    let model = dirtyModel(filename: "Untitled-3")
    let before = artwork(model.document)
    #expect(!MenuActions.applyRevert(model, svg: saved))
    #expect(model.isModified, "a refused revert leaves the changes intact")
    #expect(artwork(model.document) == before)
}
