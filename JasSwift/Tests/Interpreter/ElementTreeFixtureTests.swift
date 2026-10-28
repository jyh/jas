import Testing
import Foundation
@testable import JasLib

/// STATUS-jas item 38 step 1: `active_document.element_tree` against the
/// shared fixture the reference and Rust read (`test_fixtures/layers/element_tree.json`).
@Suite struct ElementTreeFixtureTests {

    private static func cases() -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("test_fixtures").appendingPathComponent("layers/element_tree.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cases = json["cases"] as? [[String: Any]] else { return [] }
        return cases
    }

    private static func visibleCases() -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("test_fixtures").appendingPathComponent("layers/element_tree.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cases = json["visible_cases"] as? [[String: Any]] else { return [] }
        return cases
    }

    @Test func elementTreeRowsMatchTheSharedFixture() throws {
        let cases = Self.cases()
        #expect(cases.count >= 2, "the fixture is not vacuous")
        var compared = 0
        for c in cases {
            let docData = try JSONSerialization.data(withJSONObject: c["document"] as Any, options: [.sortedKeys])
            let doc = testJsonToDocument(String(data: docData, encoding: .utf8)!)
            let got = elementTree(doc)
            let want = c["expected"] as? [[String: Any]] ?? []
            #expect(got.count == want.count, "\(c["name"] ?? "")")
            for (g, w) in zip(got, want) {
                #expect(NSDictionary(dictionary: g).isEqual(to: w), "\(c["name"] ?? ""): \(g) vs \(w)")
                compared += 1
            }
        }
        #expect(compared >= 5)
    }

    /// `lp_tree`'s row template keys its binds by PATH (item 38 step 3). flask
    /// §602 measured every row showing its rename box when they compared
    /// `node.id` (null on every row) with a null `panel.renaming_element`.
    /// Twin of Rust `the_layers_row_template_reads_paths`.
    @Test func theLayersRowTemplateReadsPaths() throws {
        func find(_ v: Any, _ id: String) -> [String: Any]? {
            if let d = v as? [String: Any] {
                if d["id"] as? String == id { return d }
                for c in d.values { if let hit = find(c, id) { return hit } }
            } else if let a = v as? [Any] {
                for c in a { if let hit = find(c, id) { return hit } }
            }
            return nil
        }
        let panels = WorkspaceData.load()?.data["panels"] as? [String: Any] ?? [:]
        let tree = try #require(find(panels["layers_panel_content"] as Any, "lp_tree"))
        let rows = Self.cases().first?["expected"] as? [[String: Any]] ?? []
        #expect(rows.count == 5, "the control: case 0's rows")
        let children = (tree["do"] as? [String: Any])?["children"] as? [[String: Any]] ?? []
        func visible(_ ctx: [String: Any], _ id: String) -> [Bool] {
            let src = (tree["foreach"] as? [String: Any])?["source"] as? String ?? ""
            guard case .list(let expanded) = evaluate(src, context: ctx) else { return [] }
            let expr = ((children.first { $0["id"] as? String == id }?["bind"]) as? [String: Any])?["visible"] as? String ?? ""
            return expanded.map { r in
                var c = ctx; c["node"] = r.value
                return evaluate(expr, context: c).toBool()
            }
        }
        func ctx(_ renaming: Any, _ collapsed: [[Int]]) -> [String: Any] {
            ["active_document": ["element_tree": rows],
             "panel": ["layers_panel_selection": [] as [Any], "isolation_stack": [] as [Any],
                       "collapsed_paths": collapsed, "renaming_element": renaming]]
        }
        let idle = ctx(NSNull(), [])
        #expect(visible(idle, "lp_name") == Array(repeating: true, count: rows.count), "every name shows")
        #expect(visible(idle, "lp_name_edit") == Array(repeating: false, count: rows.count), "no rename box")
        let renaming = ctx(rows[2]["path"] as Any, [])
        #expect(visible(renaming, "lp_name_edit").filter { $0 }.count == 1)
        #expect(visible(ctx(NSNull(), [[0, 1]]), "lp_name").count == rows.count - 1, "the collapsed group hides its child")
    }

    /// flask §603: the render plan sent the expanded `lp_tree` as a leaf of
    /// type `tree_view` as well as its rows. An expanded tree is layout-only.
    /// Twin of Rust `the_expanded_tree_is_not_also_drawn_as_a_leaf`.
    @Test func theExpandedTreeIsNotAlsoDrawnAsALeaf() throws {
        let panels = WorkspaceData.load()?.data["panels"] as? [String: Any] ?? [:]
        let panel = try #require(panels["layers_panel_content"] as? [String: Any])
        let rows = Self.cases().first?["expected"] as? [[String: Any]] ?? []
        let ctx: [String: Any] = [
            "active_document": ["element_tree": rows],
            "panel": ["layers_panel_selection": [] as [Any], "isolation_stack": [] as [Any],
                      "collapsed_paths": [] as [Any], "renaming_element": NSNull()]]
        let plan = PanelLayout.renderPlan(panel, availW: 228, availH: 600, ctx: ctx)
        let kinds = plan.leaves.compactMap { $0.node["type"] as? String }
        #expect(!kinds.contains("tree_view"), "\(kinds)")
        #expect(kinds.filter { $0 == "icon_button" }.count >= 2 * rows.count, "the control: the rows' leaves")
    }

    /// The same cases through the expression language: `layers.yaml`
    /// `lp_tree`'s foreach source calls `tree_visible_rows`, and the panel
    /// selection arrives as path markers (STATUS-jas item 38).
    @Test func treeVisibleRowsThroughTheEvaluator() throws {
        let cases = Self.visibleCases()
        #expect(cases.count >= 4, "the fixture is not vacuous")
        var compared = 0
        for c in cases {
            let docData = try JSONSerialization.data(withJSONObject: c["document"] as Any, options: [.sortedKeys])
            let doc = testJsonToDocument(String(data: docData, encoding: .utf8)!)
            let b = c["binds"] as? [String: Any] ?? [:]
            let psel = (b["panel_selection"] as? [[Int]] ?? []).map { ["__path__": $0] }
            let ctx: [String: Any] = [
                "active_document": ["element_tree": elementTree(doc)],
                "panel": ["layers_panel_selection": psel],
                "collapsed": b["collapsed"] ?? [], "renaming": b["renaming"] ?? NSNull(),
            ]
            let got = evaluate("tree_visible_rows(active_document.element_tree, collapsed, "
                + "panel.layers_panel_selection, renaming)", context: ctx)
            guard case .list(let items) = got else {
                Issue.record("\(c["name"] ?? ""): not a list: \(got)"); continue
            }
            let want = c["expected"] as? [[String: Any]] ?? []
            #expect(items.count == want.count, "\(c["name"] ?? "")")
            for (g, w) in zip(items, want) {
                #expect(NSDictionary(dictionary: g.value as? [String: Any] ?? [:]).isEqual(to: w),
                        "\(c["name"] ?? ""): \(g.value) vs \(w)")
                compared += 1
            }
        }
        #expect(compared >= 12)
    }

    /// Step 1b: the rows to draw, resolved from `element_tree` and the
    /// widget's binds (the fixture's `visible_cases`, flask §591).
    @Test func treeVisibleRowsMatchTheSharedFixture() throws {
        let cases = Self.visibleCases()
        #expect(cases.count >= 4, "the fixture is not vacuous")
        var compared = 0
        for c in cases {
            let docData = try JSONSerialization.data(withJSONObject: c["document"] as Any, options: [.sortedKeys])
            let doc = testJsonToDocument(String(data: docData, encoding: .utf8)!)
            let b = c["binds"] as? [String: Any] ?? [:]
            let got = treeVisibleRows(elementTree(doc),
                collapsed: b["collapsed"] as? [[Int]] ?? [],
                panelSelection: b["panel_selection"] as? [[Int]] ?? [],
                renaming: b["renaming"] as? [Int])
            let want = c["expected"] as? [[String: Any]] ?? []
            #expect(got.count == want.count, "\(c["name"] ?? "")")
            for (g, w) in zip(got, want) {
                #expect(NSDictionary(dictionary: g).isEqual(to: w), "\(c["name"] ?? ""): \(g) vs \(w)")
                compared += 1
            }
        }
        #expect(compared >= 12)
    }
}
