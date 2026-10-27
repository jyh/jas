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
}
