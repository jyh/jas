import Testing
@testable import JasLib

// Row 302 (ruling 1054's twin): the Mac's NATIVE canvas tab strip carries the
// ids the engine's plan carries, `canvas_tab_<i>` and `canvas_tab_close_<i>`,
// resolved from the spec's own `canvas_tab_bar` templates. Twin of
// `canvas_tab_ids_*` and `canvas_strip_ids_*` in
// jas_dioxus/src/interpreter/workspace.rs.

private func flat(_ v: [(tab: String, close: String)]) -> [String] {
    v.map { "\($0.tab)|\($0.close)" }
}

@Test func canvasTabIdsComeFromTheSpecOnePairPerDocument() {
    let ids = canvasTabIds(docs: [(name: "a.svg", isModified: false), (name: "b.svg", isModified: true)])
    #expect(flat(ids) == ["canvas_tab_0|canvas_tab_close_0", "canvas_tab_1|canvas_tab_close_1"])
    #expect(canvasTabIds(docs: []).isEmpty, "no document, no tab")
}

@Test func canvasStripIdsFollowThePlansThreeRules() {
    func bar(_ tab: String, _ close: String) -> [String: Any] {
        [
            "id": "canvas_tab_bar",
            "foreach": ["source": "workspace.open_documents", "as": "doc"],
            "do": [
                "id": tab, "type": "row",
                "children": [
                    ["type": "text", "content": "{{doc.name}}"],
                    ["id": close, "type": "icon_button", "icon": "close"],
                ] as [[String: Any]],
            ] as [String: Any],
        ]
    }
    let docs: [(name: String, isModified: Bool)] = [("a", false), ("a", false), ("b", false)]
    #expect(flat(canvasStripIds(bar: bar("t_{{doc.index}}", "c_{{state.x}}"), docs: docs))
            == ["t_0|", "t_1|", "t_2|"], "condition 1: a state read is withheld")
    #expect(flat(canvasStripIds(bar: bar("t_{{doc.name}}", "c_{{doc.index}}"), docs: docs))
            == ["|c_0", "|c_1", "t_b|c_2"], "condition 3: 'a' twice is withheld from both rows")
    #expect(flat(canvasStripIds(bar: bar("tab", "c_{{doc._index}}"), docs: docs))
            == ["tab|c_0", "tab|c_1", "tab|c_2"], "a static id is carried as is, even repeated")
    #expect(flat(canvasStripIds(bar: bar("c_1", "c_{{doc.index}}"), docs: docs))
            == ["|c_0", "|", "|c_2"], "condition 3: a static id equal to a resolved one is withheld from both")
}
