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

// MARK: - SVG round-trip idempotence

private func assertSvgRoundtrip(_ name: String) {
    let svg = readFixture("svg/\(name).svg")
    let doc1 = svgToDocument(svg)
    let json1 = documentToTestJson(doc1)

    let svg2 = documentToSvg(doc1)
    let doc2 = svgToDocument(svg2)
    let json2 = documentToTestJson(doc2)

    if json1 != json2 {
        print("=== FIRST PARSE (\(name)) ===")
        print(json1)
        print("=== AFTER ROUND-TRIP (\(name)) ===")
        print(json2)
    }
    #expect(json1 == json2, "SVG round-trip '\(name)' failed")
}

@Test func svgRoundtripAllFixtures() {
    let names = [
        "line_basic", "rect_basic", "rect_with_stroke",
        "circle_basic", "ellipse_basic",
        "polyline_basic", "polygon_basic", "path_all_commands",
        "text_basic", "text_path_basic",
        "group_nested", "transform_translate", "transform_rotate",
        "multi_layer", "complex_document",
    ]
    for name in names { assertSvgRoundtrip(name) }
}

// MARK: - SVG parse equivalence

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

// MARK: - Operation equivalence tests

private struct OpTestCase: Decodable {
    let name: String
    let setup_svg: String
    let ops: [[String: AnyDecodable]]
    let expected_json: String
}

/// Minimal wrapper for heterogeneous JSON values.
private struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else { value = NSNull() }
    }
}

private func applyOp(_ model: Model, _ controller: Controller, _ op: [String: AnyDecodable]) {
    let name = op["op"]!.value as! String
    switch name {
    case "select_rect":
        controller.selectRect(
            x: op["x"]!.value as! Double,
            y: op["y"]!.value as! Double,
            width: op["width"]!.value as! Double,
            height: op["height"]!.value as! Double,
            extend: op["extend"]?.value as? Bool ?? false)
    case "move_selection":
        controller.moveSelection(
            dx: op["dx"]!.value as! Double,
            dy: op["dy"]!.value as! Double)
    case "delete_selection":
        let newDoc = model.document.deleteSelection()
        model.document = newDoc
    case "snapshot":
        model.snapshot()
    case "undo":
        model.undo()
    case "redo":
        model.redo()
    default:
        Issue.record("Unknown op: \(name)")
    }
}

private func runOperationFixture(_ fixture: String) throws {
    let json = readFixture("operations/\(fixture)")
    let data = json.data(using: .utf8)!
    let tests = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

    for tc in tests {
        let name = tc["name"] as! String
        let setupSvg = tc["setup_svg"] as! String
        let expectedFile = tc["expected_json"] as! String
        let ops = tc["ops"] as! [[String: Any]]

        let svg = readFixture("svg/\(setupSvg)")
        let expected = readFixture("operations/\(expectedFile)").trimmingCharacters(in: .whitespacesAndNewlines)

        let doc = svgToDocument(svg)
        let model = Model(document: doc)
        let controller = Controller(model: model)

        for op in ops {
            let opName = op["op"] as! String
            switch opName {
            case "select_rect":
                controller.selectRect(
                    x: op["x"] as! Double,
                    y: op["y"] as! Double,
                    width: op["width"] as! Double,
                    height: op["height"] as! Double,
                    extend: op["extend"] as? Bool ?? false)
            case "move_selection":
                controller.moveSelection(
                    dx: op["dx"] as! Double,
                    dy: op["dy"] as! Double)
            case "copy_selection":
                controller.copySelection(
                    dx: op["dx"] as! Double,
                    dy: op["dy"] as! Double)
            case "delete_selection":
                model.document = model.document.deleteSelection()
            case "lock_selection":
                controller.lockSelection()
            case "unlock_all":
                controller.unlockAll()
            case "hide_selection":
                controller.hideSelection()
            case "show_all":
                controller.showAll()
            case "snapshot":
                model.snapshot()
            case "undo":
                model.undo()
            case "redo":
                model.redo()
            default:
                Issue.record("Unknown op: \(opName)")
            }
        }

        let actual = documentToTestJson(model.document)
        #expect(actual == expected, "Operation test '\(name)' failed")
    }
}

@Test func operationSelectAndMove() throws {
    try runOperationFixture("select_and_move.json")
}

@Test func operationUndoRedoLaws() throws {
    try runOperationFixture("undo_redo_laws.json")
}

@Test func operationControllerOps() throws {
    try runOperationFixture("controller_ops.json")
}

@Test func algorithmHitTestVectors() throws {
    let json = readFixture("algorithms/hit_test.json")
    let data = json.data(using: .utf8)!
    let tests = try JSONDecoder().decode([HitTestCase].self, from: data)

    // Use JSONSerialization for richer type handling (polygon arrays).
    let rawData = json.data(using: .utf8)!
    let rawTests = try JSONSerialization.jsonObject(with: rawData) as! [[String: Any]]

    for tc in rawTests {
        let name = tc["name"] as! String
        let function = tc["function"] as! String
        let args = tc["args"] as! [Double]
        let expected = tc["expected"] as! Bool
        let filled = tc["filled"] as? Bool ?? false

        let actual: Bool
        switch function {
        case "point_in_rect":
            actual = pointInRect(args[0], args[1], args[2], args[3], args[4], args[5])
        case "segments_intersect":
            actual = segmentsIntersect(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7])
        case "segment_intersects_rect":
            actual = segmentIntersectsRect(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7])
        case "rects_intersect":
            actual = rectsIntersect(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7])
        case "circle_intersects_rect":
            actual = circleIntersectsRect(args[0], args[1], args[2], args[3], args[4], args[5], args[6], filled: filled)
        case "ellipse_intersects_rect":
            actual = ellipseIntersectsRect(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], filled: filled)
        case "point_in_polygon":
            let polyRaw = tc["polygon"] as! [[Double]]
            let poly = polyRaw.map { ($0[0], $0[1]) }
            actual = pointInPolygon(args[0], args[1], poly)
        default:
            Issue.record("Unknown function: \(function)")
            continue
        }
        #expect(actual == expected, "Hit test '\(name)' failed: expected \(expected), got \(actual)")
    }
}
