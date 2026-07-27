import Foundation
import Testing
@testable import JasLib

/// Risk R9's CALL SITES, as opposed to its shared helpers.
///
/// `R9SaturatingCastTests` holds `saturatingInt`, `intIfIntegral`,
/// `hyphenationFieldInt` and friends to their Rust mirrors. Nothing held the
/// production sites to CALLING them: each of the five sites pinned here could
/// be reverted to its trapping pre-R9 expression with the whole Swift suite
/// still green. Each test below drives the site through the shipping entry
/// point, so a revert is a failure and not a silent regression.
struct R9CallSitePinTests {

    // MARK: - Test-JSON tspan id (TestJson.swift parseTspan)

    /// The shared `id`-domain corpus at
    /// `test_fixtures/algorithms/tspan_id_from_json.json`, driven through the
    /// real element decoder. jas_dioxus runs the same file in
    /// `geometry::test_json::tests::tspan_id_domain_corpus`.
    @Test func tspanIdDomainCorpusMatchesAcrossPorts() {
        let thisFile = #filePath
        let testsDir = (thisFile as NSString).deletingLastPathComponent
        let jasTests = (testsDir as NSString).deletingLastPathComponent
        let jasSwift = (jasTests as NSString).deletingLastPathComponent
        let root = (jasSwift as NSString).appendingPathComponent("../test_fixtures")
        let path = ((root as NSString)
            .appendingPathComponent("algorithms/tspan_id_from_json.json")
            as NSString).standardizingPath
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vectors = file["vectors"] as? [[String: Any]]
        else { fatalError("Failed to read fixture: \(path)") }
        #expect(!vectors.isEmpty)
        for v in vectors {
            let name = v["name"] as? String ?? "?"
            guard case .text(let t) = parseElement(v["input"]) else {
                fatalError("vector \(name): expected a text element")
            }
            let expected = UInt32(truncatingIfNeeded: (v["expected"] as? NSNumber)?.int64Value ?? -1)
            #expect(t.tspans[0].id == expected, "vector \(name)")
            if let last = (v["expected_last"] as? NSNumber)?.uint32Value {
                #expect(t.tspans[t.tspans.count - 1].id == last,
                        "vector \(name) (last tspan)")
            }
        }
    }
}
