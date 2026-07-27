import Foundation
import Testing
@testable import JasLib

/// The canonical Test-JSON string-escaping rule, driven from the shared
/// corpus at `test_fixtures/algorithms/canonical_json_string.json`.
/// jas_dioxus runs the same file in
/// `geometry::test_json::tests::canonical_json_string_corpus`.
///
/// Before 2026-07-27 this port had two string writers at two different
/// escaping levels and the byte oracle behind the codec gates could not
/// express a control character at all:
///
///   - `JsonObj.str` applied exactly two replacements (backslash, quote), so
///     a tspan content of "a<LF>b" serialised to a raw LF inside a JSON
///     string, which JSONSerialization rejects. A loud ceiling.
///   - `canonicalRecordedValue` (recipe params, recorded ops, generated
///     concept params) did the same two replacements and therefore emitted
///     control characters, combining marks, ZWJ and NBSP RAW -- where
///     jas_dioxus's mirror `canonical_value` used Rust's `{:?}` and emitted
///     `\u{301}`, `\u{200d}`, `\0`, `\u{1}`. That was a byte divergence on a
///     path no fixture reached, and neither spelling was JSON for the
///     control characters.
struct CanonicalJsonStringTests {

    private static func fixturePath(_ rel: String) -> String {
        let thisFile = #filePath
        let geometryDir = (thisFile as NSString).deletingLastPathComponent
        let testsDir = (geometryDir as NSString).deletingLastPathComponent
        let jasSwift = (testsDir as NSString).deletingLastPathComponent
        let root = (jasSwift as NSString).appendingPathComponent("../test_fixtures")
        return ((root as NSString).appendingPathComponent(rel) as NSString)
            .standardizingPath
    }

    /// Three independent claims per vector, because the three paths used to
    /// disagree with each other, plus the `reparses` claim that the emitted
    /// bytes are JSON that decodes back to the input.
    @Test func canonicalJsonStringCorpus() {
        let path = Self.fixturePath("algorithms/canonical_json_string.json")
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vectors = file["vectors"] as? [[String: Any]]
        else { fatalError("Failed to read fixture: \(path)") }
        #expect(!vectors.isEmpty)

        for v in vectors {
            let name = v["name"] as? String ?? "?"
            guard let input = v["input"] as? String,
                  let canonical = v["canonical"] as? String
            else { fatalError("vector \(name): input/canonical must be strings") }

            #expect(jsonEscapeString(input) == canonical,
                    "vector \(name): jsonEscapeString")

            // `JsonObj` is file-private to TestJson.swift, so its `str` arm is
            // reached the way production reaches it: a tspan's content, which
            // that writer emits unconditionally. (jas_dioxus's mirror calls
            // `JsonObj::str_val` directly -- same function, same claim.)
            let elem = parseElement([
                "type": "text",
                "x": 0.0, "y": 0.0, "font_size": 12.0,
                "tspans": [["id": 1, "content": input]],
            ] as [String: Any])
            #expect(elementJson(elem).contains("\"content\":\(canonical),"),
                    "vector \(name): JsonObj.str via tspan content")

            #expect(canonicalRecordedValue(input) == canonical,
                    "vector \(name): canonicalRecordedValue")

            if v["reparses"] as? Bool == true {
                let wrapped = "{\"k\":\(canonical)}".data(using: .utf8)!
                guard let back = try? JSONSerialization.jsonObject(with: wrapped)
                        as? [String: Any],
                      let s = back["k"] as? String
                else {
                    Issue.record("vector \(name): emitted invalid JSON")
                    continue
                }
                #expect(s == input, "vector \(name): reparse did not recover the input")
            }
        }
    }

    /// The vector the ceiling blocked: a text element whose content carries a
    /// newline survives `documentToTestJson` -> `testJsonToDocument` ->
    /// `documentToTestJson` unchanged. Before the lift the FIRST of those
    /// calls produced a raw LF inside a JSON string and the second trapped in
    /// `JSONSerialization`.
    ///
    /// Mirrored in jas_dioxus by
    /// `multi_line_text_round_trips_through_test_json`.
    @Test func multiLineTextRoundTripsThroughTestJson() {
        let content = "line one\nline two\ttabbed"
        // Built through the shipping parser so the test states no field
        // defaults of its own.
        let elem = parseElement([
            "type": "text",
            "x": 10.0, "y": 20.0, "font_size": 12.0,
            "name": "a\u{7f}name",
            "tspans": [["id": 1, "content": content]],
        ] as [String: Any])
        let layer = Layer(children: [elem])
        let doc = Document(layers: [layer], selectedLayer: 0)

        let json = documentToTestJson(doc)
        #expect(json.contains("\"content\":\"line one\\nline two\\ttabbed\""),
                "escaped content missing from: \(json)")

        let back = testJsonToDocument(json)
        guard case .text(let t) = back.layers[0].children[0] else {
            fatalError("expected a text element")
        }
        #expect(t.tspans[0].content == content, "content did not survive")
        #expect(t.name == "a\u{7f}name")
        // The canonical form is a fixed point, which every golden relies on.
        #expect(documentToTestJson(back) == json)
    }
}
