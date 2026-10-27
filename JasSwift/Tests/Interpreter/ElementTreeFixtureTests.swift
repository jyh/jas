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
