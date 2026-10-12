import Testing
import Foundation
@testable import JasLib

// The hit test hits painted geometry (transcripts/SELECTION_TOOL.md § Hit
// test: painted geometry). The rows are the shared corpus
// test_fixtures/algorithms/painted_hit.json, whose expectations the
// reference writes by hand (workspace_interpreter/tests/test_hit_law.py).

private func paintedHitCorpus() -> [[String: Any]] {
    let thisFile = #filePath
    let jasSwiftDir = (((thisFile as NSString).deletingLastPathComponent as NSString)
        .deletingLastPathComponent as NSString).deletingLastPathComponent
    let path = ((jasSwiftDir as NSString)
        .appendingPathComponent("../test_fixtures/algorithms/painted_hit.json") as NSString)
        .standardizingPath
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cases = obj["cases"] as? [[String: Any]] else {
        Issue.record("cannot read \(path)")
        return []
    }
    return cases
}

@Test func theSharedPaintedHitCorpus() throws {
    let cases = paintedHitCorpus()
    // Anti-vacuity: the corpus is the reference's 49 rows (a floor).
    #expect(cases.count >= 49, "corpus has \(cases.count) rows")
    var failures: [String] = []
    for c in cases {
        let docData = try JSONSerialization.data(withJSONObject: c["document"]!)
        let doc = testJsonToDocument(String(data: docData, encoding: .utf8)!)
        let x = (c["x"] as! NSNumber).doubleValue
        let y = (c["y"] as! NSNumber).doubleValue
        let deep = (c["deep"] as! NSNumber).boolValue
        let got: Value
        do {
            let handle = registerDocument(doc)
            got = deep ? docHitTestDeep(x, y) : docHitTest(x, y)
            _ = handle
        }
        let expect: Value
        if let p = c["expect"] as? [NSNumber] {
            expect = .path(p.map { $0.intValue })
        } else {
            expect = .null
        }
        if got != expect {
            failures.append("\(c["name"] ?? "?"): got \(got), law says \(expect)")
        }
    }
    #expect(failures.isEmpty, "\(failures.count) of \(cases.count) rows:\n\(failures.joined(separator: "\n"))")
}

/// A compound's own fill, which the corpus cannot carry (test_json omits a
/// compound's paint in every port). Mirrors the reference's
/// `test_a_compound_shape_hits_its_evaluated_area`.
@Test func aCompoundShapeHitsItsEvaluatedArea() {
    let ink = Fill(color: .black)
    let a = Element.rect(Rect(x: 0, y: 0, width: 40, height: 40, fill: ink))
    let b = Element.rect(Rect(x: 10, y: 10, width: 20, height: 20, fill: ink))
    let cs = Element.live(.compoundShape(CompoundShape(
        operation: .subtractFront, operands: [a, b], name: nil, fill: ink)))
    #expect(hitLawPaintedHit(cs, 5, 5, .preview))
    #expect(!hitLawPaintedHit(cs, 20, 20, .preview), "the hole")
}
