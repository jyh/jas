import Testing
import Foundation
@testable import JasLib

/// Path to the shared test fixtures directory, relative to this source file.
private func fixturesPath() -> String {
    let thisFile = #filePath
    let testsDir = (thisFile as NSString).deletingLastPathComponent
    let jasSwiftDir = (testsDir as NSString).deletingLastPathComponent
    return (jasSwiftDir as NSString).appendingPathComponent("../test_fixtures")
}

/// Read a fixture file and return its contents.
private func readFixture(_ path: String) -> String {
    let full = (fixturesPath() as NSString).appendingPathComponent(path)
    let standardized = (full as NSString).standardizingPath
    guard let data = FileManager.default.contents(atPath: standardized),
          let str = String(data: data, encoding: .utf8) else {
        fatalError("Failed to read fixture: \(standardized)")
    }
    return str
}

/// Run a single SVG parse-equivalence test:
/// 1. Read the SVG file.
/// 2. Parse it into a Document.
/// 3. Serialize to canonical test JSON.
/// 4. Compare against the expected JSON file.
private func assertSvgParse(_ name: String) {
    let svg = readFixture("svg/\(name).svg")
    let expected = readFixture("expected/\(name).json").trimmingCharacters(in: .whitespacesAndNewlines)

    let doc = svgToDocument(svg)
    let actual = documentToTestJson(doc)

    if actual != expected {
        print("=== EXPECTED (\(name)) ===")
        print(expected)
        print("=== ACTUAL (\(name)) ===")
        print(actual)
    }
    #expect(actual == expected, "Cross-language test '\(name)' failed: canonical JSON mismatch")
}

@Test func svgParseLineBasic() { assertSvgParse("line_basic") }
@Test func svgParseRectBasic() { assertSvgParse("rect_basic") }
@Test func svgParseRectWithStroke() { assertSvgParse("rect_with_stroke") }
@Test func svgParseCircleBasic() { assertSvgParse("circle_basic") }
@Test func svgParseEllipseBasic() { assertSvgParse("ellipse_basic") }
@Test func svgParsePolylineBasic() { assertSvgParse("polyline_basic") }
@Test func svgParsePolygonBasic() { assertSvgParse("polygon_basic") }
@Test func svgParsePathAllCommands() { assertSvgParse("path_all_commands") }
@Test func svgParseTextBasic() { assertSvgParse("text_basic") }
@Test func svgParseTextPathBasic() { assertSvgParse("text_path_basic") }
@Test func svgParseGroupNested() { assertSvgParse("group_nested") }
@Test func svgParseTransformTranslate() { assertSvgParse("transform_translate") }
@Test func svgParseTransformRotate() { assertSvgParse("transform_rotate") }
@Test func svgParseMultiLayer() { assertSvgParse("multi_layer") }
@Test func svgParseComplexDocument() { assertSvgParse("complex_document") }

// MARK: - Algorithm test vectors

private struct HitTestCase: Decodable {
    let name: String
    let function: String
    let args: [Double]
    let expected: Bool
}

@Test func algorithmHitTestVectors() throws {
    let json = readFixture("algorithms/hit_test.json")
    let data = json.data(using: .utf8)!
    let tests = try JSONDecoder().decode([HitTestCase].self, from: data)

    for tc in tests {
        let a = tc.args
        let actual: Bool
        switch tc.function {
        case "point_in_rect":
            actual = pointInRect(a[0], a[1], a[2], a[3], a[4], a[5])
        case "segments_intersect":
            actual = segmentsIntersect(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7])
        case "segment_intersects_rect":
            actual = segmentIntersectsRect(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7])
        case "rects_intersect":
            actual = rectsIntersect(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7])
        default:
            Issue.record("Unknown function: \(tc.function)")
            continue
        }
        #expect(actual == tc.expected, "Hit test '\(tc.name)' failed: expected \(tc.expected), got \(actual)")
    }
}
