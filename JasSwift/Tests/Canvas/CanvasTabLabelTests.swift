import Testing
@testable import JasLib

// Row 115: the canvas tab shows the document's modified mark, from the spec
// (layout.yaml `canvas_tab_bar`), so the Mac's native tab bar and the plan a
// shell draws read one rule. Twin of `canvas_tab_label_*` in
// jas_dioxus/src/interpreter/workspace.rs.

@Test func canvasTabLabelIsTheBareNameWhenClean() {
    #expect(canvasTabLabel(name: "a.svg", isModified: false) == "a.svg")
}

@Test func canvasTabLabelMarksAModifiedDocument() {
    #expect(canvasTabLabel(name: "a.svg", isModified: true) == "a.svg *")
}

@Test func canvasTabLabelComesFromTheSpec() {
    let template = WorkspaceData.load()?.canvasTabLabelTemplate()
    #expect(template != nil, "the compiled layout carries the tab label")
    #expect(template?.contains("doc.is_modified") == true, "the spec names the mark: \(template ?? "nil")")
}
