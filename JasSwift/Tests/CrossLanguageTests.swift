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

@Test func operationSelectAndMove() throws {
    let json = readFixture("operations/select_and_move.json")
    let data = json.data(using: .utf8)!

    // Parse manually since the ops are heterogeneous.
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
                Issue.record("Unknown op: \(opName)")
            }
        }

        let actual = documentToTestJson(model.document)
        if actual != expected {
            print("=== EXPECTED (\(name)) ===")
            print(expected)
            print("=== ACTUAL (\(name)) ===")
            print(actual)
        }
        #expect(actual == expected, "Operation test '\(name)' failed")
    }
}

@Test func operationUndoRedoLaws() throws {
    let json = readFixture("operations/undo_redo_laws.json")
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
            case "delete_selection":
                model.document = model.document.deleteSelection()
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
