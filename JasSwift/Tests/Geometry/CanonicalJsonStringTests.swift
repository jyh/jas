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

    // MARK: - Per-call-site pins for `jsonEscapeString`
    //
    // `canonicalJsonStringCorpus` above drives the escaper through three entry
    // points: the function itself, `JsonObj.str` (via a tspan's content), and
    // `canonicalRecordedValue`'s String arm. The escaper has EIGHT call sites
    // across TestJson.swift and LiveElement.swift, and each of the other six
    // was reverted individually to its pre-2026-07-27 form with the whole
    // 2649-test suite green — routed by 2358fda4, gated by nothing. One test
    // per site follows, each named for its site.
    //
    // Every test uses ONE probe whose canonical spelling separates both
    // pre-lift Swift forms at once, and the Rust `{:?}` form too so the two
    // ports can share the probe:
    //   probe            a " b \ c U+0008 d
    //   canonical        "a\"b\\c\bd"     (json.dumps, ensure_ascii=False)
    //   naive "\"\(s)\"" "a"b\c<BS>d"     — invalid JSON, three ways wrong
    //   two-replacement  "a\"b\\c<BS>d"   — raw control char, still invalid
    // The probe deliberately contains no whitespace: both text-decoration
    // writers tokenize on it.
    private static let escapeProbe = "a\"b\\c\u{08}d"
    /// The probe's canonical spelling, produced by
    /// `json.dumps('a"b\\c\bd', ensure_ascii=False)` — the rule's adjudicator —
    /// and NOT by running this port's escaper.
    private static let escapeProbeJson = #""a\"b\\c\bd""#

    /// Assert the emitted element JSON is JSON at all, which is the property
    /// the escaper exists for.
    private static func expectParses(_ json: String, _ label: String) {
        let ok = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil
        #expect(ok, "\(label): emitted invalid JSON: \(json)")
    }

    /// SITE: `textDecorationJson` — the element-wide `text_decoration` list.
    ///
    /// The tspan's list is left absent so it emits `null`, which keeps this
    /// test blind to `tspanJson`'s list writer and pins this site alone.
    @Test func elementTextDecorationMembersAreJsonEscaped() {
        let elem = parseElement([
            "type": "text",
            "x": 0.0, "y": 0.0, "font_size": 12.0,
            "text_decoration": [Self.escapeProbe],
            "tspans": [["id": 1, "content": "t"]],
        ] as [String: Any])
        let json = elementJson(elem)
        #expect(json.contains("\"text_decoration\":[\(Self.escapeProbeJson)]"),
                "element text_decoration member not escaped in: \(json)")
        #expect(json.contains("\"text_decoration\":null"),
                "tspan list not null in: \(json)")
        Self.expectParses(json, "element text_decoration")
    }

    /// SITE: `tspanJson`'s `text_decoration` member list.
    ///
    /// The element-wide list is held at `"none"` so it emits `[]`, which keeps
    /// this test blind to `textDecorationJson` and pins this site alone.
    @Test func tspanTextDecorationMembersAreJsonEscaped() {
        let elem = parseElement([
            "type": "text",
            "x": 0.0, "y": 0.0, "font_size": 12.0,
            "text_decoration": "none",
            "tspans": [["id": 1, "content": "t",
                        "text_decoration": [Self.escapeProbe]]],
        ] as [String: Any])
        let json = elementJson(elem)
        #expect(json.contains("\"text_decoration\":[\(Self.escapeProbeJson)]"),
                "tspan text_decoration member not escaped in: \(json)")
        #expect(json.contains("\"text_decoration\":[]"),
                "element list not empty in: \(json)")
        Self.expectParses(json, "tspan text_decoration")
    }

    /// SITE: `elementJson`'s recorded arm, the `inputs` id list.
    @Test func recordedInputIdsAreJsonEscaped() {
        let elem = Element.live(.recorded(RecordedElem(
            ops: [], inputs: [ElementRef(Self.escapeProbe)])))
        let json = elementJson(elem)
        #expect(json.contains("\"inputs\":[\(Self.escapeProbeJson)]"),
                "recorded input id not escaped in: \(json)")
        Self.expectParses(json, "recorded inputs")
    }

    /// SITE: `canonicalRecordedValue`'s object-KEY arm — a recipe param's own
    /// key, the one key these files emit that is data rather than a literal.
    /// The corpus test pins the String VALUE arm six lines above it; reverting
    /// the key arm alone left the suite green.
    @Test func recipeParamObjectKeysAreJsonEscaped() {
        // Directly, with a `true` value so no float formatting is involved.
        #expect(canonicalRecordedValue([Self.escapeProbe: true] as [String: Any])
                    == "{\(Self.escapeProbeJson):true}")
        // And through the shipping serializer: a recorded op's params, with the
        // op name and targets held ordinary so only the key arm can matter.
        let elem = Element.live(.recorded(RecordedElem(
            ops: [PrimitiveOp(op: "translate",
                              params: [Self.escapeProbe: true],
                              targets: [])],
            inputs: [])))
        let json = elementJson(elem)
        #expect(json.contains("\"params\":{\(Self.escapeProbeJson):true}"),
                "recipe param key not escaped in: \(json)")
        Self.expectParses(json, "recipe param key")
    }

    /// SITE: `canonicalRecordedOp`'s `targets` list.
    @Test func recordedOpTargetsAreJsonEscaped() {
        let elem = Element.live(.recorded(RecordedElem(
            ops: [PrimitiveOp(op: "translate", params: [:],
                              targets: [Self.escapeProbe])],
            inputs: [])))
        let json = elementJson(elem)
        #expect(json.contains("\"targets\":[\(Self.escapeProbeJson)]"),
                "recorded op target not escaped in: \(json)")
        Self.expectParses(json, "recorded op targets")
    }

    /// SITE: `canonicalRecordedOp`'s op NAME.
    @Test func recordedOpNameIsJsonEscaped() {
        let elem = Element.live(.recorded(RecordedElem(
            ops: [PrimitiveOp(op: Self.escapeProbe, params: [:], targets: [])],
            inputs: [])))
        let json = elementJson(elem)
        #expect(json.contains("\"op\":\(Self.escapeProbeJson)"),
                "recorded op name not escaped in: \(json)")
        Self.expectParses(json, "recorded op name")
    }
}
