import Testing
import Foundation
@testable import JasLib

/// G11 (STATUS-jas row 73): `hit_test(x, y, root)` against the shared fixture
/// the reference and Rust read (`test_fixtures/layers/hit_test_root.json`).
@Suite struct HitTestRootFixtureTests {
    private static func fixture() -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("test_fixtures").appendingPathComponent("layers/hit_test_root.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    @Test func hitTestWithARootMatchesTheSharedFixture() throws {
        let fx = Self.fixture()
        let cases = fx["cases"] as? [[String: Any]] ?? []
        #expect(cases.count >= 10, "the fixture is not vacuous")
        let docData = try JSONSerialization.data(withJSONObject: fx["document"] as Any, options: [.sortedKeys])
        let doc = testJsonToDocument(String(data: docData, encoding: .utf8)!)
        let reg = registerDocument(doc)
        var compared = 0
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let root = c["root"] as? [Int]
            let arg = root.map { "path(" + $0.map(String.init).joined(separator: ", ") + ")" } ?? "null"
            let got = evaluate("hit_test(\(c["x"]!), \(c["y"]!), \(arg))", context: [:])
            if let want = c["expected"] as? [Int] {
                #expect(got == .path(want), "\(name): \(got)")
            } else {
                #expect(got == .null, "\(name): \(got)")
            }
            compared += 1
        }
        #expect(compared == cases.count)
        _ = reg
    }

    @Test func isGroupMatchesTheSharedFixture() throws {
        let fx = Self.fixture()
        let cases = fx["is_group_cases"] as? [[String: Any]] ?? []
        #expect(cases.count >= 5, "the fixture is not vacuous")
        let docData = try JSONSerialization.data(withJSONObject: fx["document"] as Any, options: [.sortedKeys])
        let reg = registerDocument(testJsonToDocument(String(data: docData, encoding: .utf8)!))
        for c in cases {
            let p = (c["path"] as? [Int] ?? []).map(String.init).joined(separator: ", ")
            #expect(evaluate("is_group(path(\(p)))", context: [:]) == .bool(c["expected"] as! Bool), "\(c["name"]!)")
        }
        _ = reg
    }
}
