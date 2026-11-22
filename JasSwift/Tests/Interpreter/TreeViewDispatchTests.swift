import Testing
@testable import JasLib

// Row 117 (Mac): the Layers tree_view renders as the native tree
// (TreeViewContent), never as the generic foreach expansion. `lp_tree` gained
// `foreach` + `do` on 10-27 (567b4031) for the PLAN a native shell expands,
// and the element view's foreach branch runs before its type dispatch, so from
// that day the live Mac panel drew the template: the row context menu (#958),
// the right-click that selects its row (#959) and the Delete orphan gate
// (#961) never ran. Measured live 11-22: 8 renders of `lp_tree` through the
// foreach branch, 0 calls of the native row view. The web's twin was fixed on
// 11-12 (#923, `expands_as_foreach`); this is the same predicate.

private func find(_ n: Any?, _ id: String) -> [String: Any]? {
    if let d = n as? [String: Any] {
        if d["id"] as? String == id { return d }
        for k in ["children", "content", "do"] {
            if let f = find(d[k], id) { return f }
        }
    } else if let a = n as? [Any] {
        for x in a { if let f = find(x, id) { return f } }
    }
    return nil
}

@Test func aTreeViewWithAForeachIsTheNativeTreeOnTheMac() throws {
    let panel = try #require(WorkspaceData.load()?.panel("layers_panel_content"))
    let tree = try #require(find(panel, "lp_tree"), "the shipped Layers panel has no lp_tree")
    // The precondition this test exists for: read from the shipped workspace,
    // so a re-typed widget or a dropped foreach reds here instead of passing.
    #expect(tree["type"] as? String == "tree_view")
    #expect(tree["foreach"] != nil && tree["do"] != nil, "lp_tree no longer carries foreach + do")
    #expect(!YamlElementView.expandsAsForeach(tree), "lp_tree would render as the generic template")
}

@Test func anyOtherNodeWithAForeachStillExpands() {
    // The control: the predicate is not simply false.
    let row: [String: Any] = ["type": "container", "foreach": ["source": "x", "as": "i"], "do": ["type": "text"]]
    #expect(YamlElementView.expandsAsForeach(row))
    let untyped: [String: Any] = ["foreach": ["source": "x"], "do": [:] as [String: Any]]
    #expect(YamlElementView.expandsAsForeach(untyped))
    #expect(!YamlElementView.expandsAsForeach(["type": "container", "foreach": ["source": "x"]]))
}
