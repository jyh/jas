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
        // REFERENCE_GRAPH.md Phase 2a: live element SVG codec. A reference
        // round-trips as <use href="#id">; a compound as
        // <g data-jas-live="compound_shape" data-jas-operation="...">.
        // live_compound_id additionally carries the compound's own id.
        "live_reference", "live_compound", "live_compound_id",
        // Symbols P1: <defs> master + <use> instance round-trips through SVG
        // (SYMBOLS.md §5 / Fork S3) — defs masters import to symbols, not
        // layers, and re-export identically.
        "symbols_basic",
        // Symbols P4: the instance transform rides data-jas-instance-transform
        // on the <use> and round-trips through SVG distinct from the render
        // CTM (the <use transform> attr). (SYMBOLS.md §4 / Fork F2.)
        "reference_instance_transform",
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
/// Unique-id invariant on import (REFERENCE_GRAPH.md §2.5): two rects share
/// id="dup"; after dedupe the first keeps it and the second has no id.
@Test func svgParseDupIdImport() { assertSvgParse("dup_id_import") }
/// REFERENCE_GRAPH.md Phase 2a: a <use href="#id"> imports as a live
/// reference (F-svg-use); the href minus '#' becomes the target.
@Test func svgParseLiveReference() { assertSvgParse("live_reference") }
/// REFERENCE_GRAPH.md Phase 2a: a <g data-jas-live="compound_shape"
/// data-jas-operation="..."> imports as a CompoundShape, not a Group.
@Test func svgParseLiveCompound() { assertSvgParse("live_compound") }
/// REFERENCE_GRAPH.md §4: the compound's own id="..." attribute imports
/// into CompoundShape.id (name stays excluded for live elements).
@Test func svgParseLiveCompoundId() { assertSvgParse("live_compound_id") }
/// Symbols P1 (SYMBOLS.md §10): the <defs> master (id="m1") imports into
/// doc.symbols (NOT layers); the <use href="#m1" id="i1"> imports as a live
/// reference in the layer. The canonical JSON shows the `symbols` array + the
/// instance. All apps parse it to the identical canonical JSON.
@Test func svgParseSymbolsBasic() { assertSvgParse("symbols_basic") }
/// Symbols P4 (SYMBOLS.md §4 / Fork F2): a <use> carrying
/// data-jas-instance-transform="matrix(2,0,0,2,0,0)" imports as a reference
/// whose instance `transform` field (emitted as `instance_transform`) is
/// scale(2,2), while the render CTM (the `transform` key) stays null — the
/// two transforms are independent.
@Test func svgParseReferenceInstanceTransform() { assertSvgParse("reference_instance_transform") }

/// Pins the motivating equivalence bug (REFERENCE_GRAPH.md §4): import the
/// id-less live_compound.svg, stamp an id onto the compound via
/// Controller.assignId, and assert it lands. Before CompoundShape carried
/// an id, `Element.withId` was a no-op for `.live`, so a compound could
/// never become a reference target.
@Test func assignIdOnCompound() {
    let svg = readFixture("svg/live_compound.svg")
    let model = Model(document: svgToDocument(svg))
    let controller = Controller(model: model)
    // The compound is the sole child of the sole layer: path [0, 0].
    let path: ElementPath = [0, 0]
    #expect(model.document.getElement(path).id == nil)
    controller.assignId(path, id: "cmp1")
    #expect(model.document.getElement(path).id == "cmp1")
}

// MARK: - Dependency index cross-language pin (REFERENCE_GRAPH.md §3)

/// Read the shared input document fixture, build the dependency index,
/// serialize it, and assert byte-equality with the shared index fixture. All
/// five apps run this same pair of fixtures; passing means Swift agrees on the
/// canonical index shape (deps/rdeps/dangling/cycles, operands-opaque).
@Test func dependencyIndexCrossLanguage() {
    // Parse the shared input document.
    let input = readFixture("expected/dependency_index_input.json")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let doc = testJsonToDocument(input)

    // Sanity: the parsed input must re-serialize to itself (the fixture is
    // canonical), so the index is computed over the same doc all apps see.
    #expect(documentToTestJson(doc) == input,
        "dependency_index_input.json is not canonical: parse->serialize changed it")

    // Build + serialize the index, compare with the expected fixture.
    let actual = dependencyIndexToTestJson(DependencyIndex.build(doc))
    let expected = readFixture("expected/dependency_index.json")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if actual != expected {
        print("=== EXPECTED (dependency_index) ===")
        print(expected)
        print("=== ACTUAL (dependency_index) ===")
        print(actual)
    }
    #expect(actual == expected,
        "dependency_index cross-language test failed: canonical JSON mismatch")
}

/// Cross-language pin for the chain/diamond graph (REFERENCE_GRAPH.md §8
/// Phase 4a): read the shared input document, build the index, serialize it,
/// and assert byte-equality with the shared chain fixture. Exercises
/// multi-level topological ordering that the primary fixture cannot.
@Test func dependencyIndexChainCrossLanguage() {
    let input = readFixture("expected/dependency_index_chain_input.json")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let doc = testJsonToDocument(input)

    // Sanity: the parsed input must re-serialize to itself (it is canonical).
    #expect(documentToTestJson(doc) == input,
        "dependency_index_chain_input.json is not canonical: parse->serialize changed it")

    let actual = dependencyIndexToTestJson(DependencyIndex.build(doc))
    let expected = readFixture("expected/dependency_index_chain.json")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if actual != expected {
        print("=== EXPECTED (dependency_index_chain) ===")
        print(expected)
        print("=== ACTUAL (dependency_index_chain) ===")
        print(actual)
    }
    #expect(actual == expected,
        "dependency_index_chain cross-language test failed: canonical JSON mismatch")
}

// MARK: - orphaned_references cross-language pin (REFERENCE_GRAPH.md)

/// Parse the shared input document, read the shared orphaned-references
/// fixture, and for each case assert that
/// `DependencyIndex.orphanedReferences(doc, delete_paths)` equals the expected
/// ids. All apps run this same pair of fixtures. The case array ORDER is part
/// of the contract — it is the file's order, identical across all apps.
@Test func orphanedReferencesCrossLanguage() throws {
    let input = readFixture("expected/dependency_index_input.json")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let doc = testJsonToDocument(input)

    let casesJson = readFixture("expected/orphaned_references.json")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let data = casesJson.data(using: .utf8)!
    let cases = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

    for (i, tc) in cases.enumerated() {
        let deletePaths: [ElementPath] = (tc["delete_paths"] as! [[Any]]).map { path in
            path.map { ($0 as! NSNumber).intValue }
        }
        let expected = (tc["orphaned"] as! [Any]).map { $0 as! String }

        let actual = DependencyIndex.orphanedReferences(doc, deletePaths)
        #expect(actual == expected,
            "orphaned_references cross-language case \(i) (\(deletePaths)) mismatch: expected \(expected), got \(actual)")
    }
}

// MARK: - JSON round-trip (parse → serialize)

private func assertJsonRoundtrip(_ name: String) {
    let expected = readFixture("expected/\(name).json").trimmingCharacters(in: .whitespacesAndNewlines)
    let doc = testJsonToDocument(expected)
    let actual = documentToTestJson(doc)

    if actual != expected {
        print("=== EXPECTED (\(name)) ===")
        print(expected)
        print("=== ACTUAL (\(name)) ===")
        print(actual)
    }
    #expect(actual == expected, "JSON round-trip '\(name)' failed: canonical JSON mismatch")
}

@Test func jsonRoundtripAllExpected() {
    let names = [
        "line_basic", "rect_basic", "rect_with_stroke",
        "circle_basic", "ellipse_basic",
        "polyline_basic", "polygon_basic", "path_all_commands",
        "text_basic", "text_path_basic",
        "group_nested", "transform_translate", "transform_rotate",
        "multi_layer", "complex_document",
        "element_ids",
        // REFERENCE_GRAPH.md Phase 1a: live element codec (compound now
        // emits `operation`; reference emits kind+target). live_compound_id
        // additionally carries the compound's own id (REFERENCE_GRAPH.md §4).
        "live_reference_roundtrip", "live_compound_roundtrip",
        "live_compound_id",
        // Symbols P1: the `symbols` array (a master) + the instance in layers
        // round-trips through test_json (SYMBOLS.md §10).
        "symbols_basic",
        // Symbols P4: a reference whose instance `transform` field is set (the
        // `instance_transform` key) round-trips through test_json distinct from
        // the render CTM (the `transform` key). (SYMBOLS.md §4 / Fork F2.)
        "reference_instance_transform",
    ]
    for name in names { assertJsonRoundtrip(name) }
}

// MARK: - Binary round-trip

private func readFixtureData(_ path: String) -> Data {
    let full = (fixturesPath() as NSString).appendingPathComponent(path)
    let standardized = (full as NSString).standardizingPath
    guard let data = FileManager.default.contents(atPath: standardized) else {
        fatalError("Failed to read fixture: \(standardized)")
    }
    return data
}

@Test func binaryRoundtripAllExpected() {
    let names = [
        "line_basic", "rect_basic", "rect_with_stroke",
        "circle_basic", "ellipse_basic",
        "polyline_basic", "polygon_basic", "path_all_commands",
        "text_basic", "text_path_basic",
        "group_nested", "transform_translate", "transform_rotate",
        "multi_layer", "complex_document", "element_ids",
        // Live elements round-trip through binary (REFERENCE_GRAPH.md Phase 2b).
        // live_compound_id additionally carries the compound's own id (§4).
        "live_reference_roundtrip", "live_compound_roundtrip",
        "live_compound_id",
        // Symbols P1: the master store rides the trailing element array in the
        // binary document (SYMBOLS.md §5); JSON-compare round-trip.
        "symbols_basic",
        // Symbols P4: the instance transform packs at TAG_LIVE slot 9 and
        // round-trips through binary distinct from the render CTM (slot 4).
        // (SYMBOLS.md §4 / Fork F2.)
        "reference_instance_transform",
    ]
    for name in names {
        let expected = readFixture("expected/\(name).json").trimmingCharacters(in: .whitespacesAndNewlines)
        let doc = testJsonToDocument(expected)
        let binary = documentToBinary(doc)
        let doc2 = try! binaryToDocument(binary)
        let actual = documentToTestJson(doc2)
        #expect(actual == expected, "Binary round-trip '\(name)' failed")
    }
}

@Test func binaryReadPythonFixtures() {
    let names = [
        "line_basic", "rect_basic", "rect_with_stroke",
        "circle_basic", "ellipse_basic",
        "polyline_basic", "polygon_basic", "path_all_commands",
        "text_basic", "text_path_basic",
        "group_nested", "transform_translate", "transform_rotate",
        "multi_layer", "complex_document", "element_ids",
        // Cross-app byte pin: decode Python-generated live-element bytes
        // (REFERENCE_GRAPH.md Phase 2b) to the exact expected JSON.
        // live_compound_id.bin (108 bytes, Python-generated) pins the
        // compound's own id through the binary common block (§4).
        "live_reference_roundtrip", "live_compound_roundtrip",
        "live_compound_id",
        // Symbols P1: decode the Python-generated symbols_basic.bin (master
        // store + instance) to the exact expected JSON (SYMBOLS.md §5).
        "symbols_basic",
        // Symbols P4: a reference with a non-identity instance transform.
        "reference_instance_transform",
    ]
    for name in names {
        let binData = readFixtureData("expected/\(name).bin")
        let doc = try! binaryToDocument(binData)
        let actual = documentToTestJson(doc)
        let expected = readFixture("expected/\(name).json").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(actual == expected, "Python binary fixture '\(name)' did not produce expected JSON")
    }
}

/// v1 used a different positional layout (no generic name/id slots), so a
/// v2 reader must reject it rather than silently mis-parse. Mirrors
/// Python's `test_legacy_v1_rejected`: take a valid v2 blob, stamp its
/// version field back to 1, and assert the decode throws.
@Test func binaryLegacyV1Rejected() {
    var bytes = [UInt8](readFixtureData("expected/rect_basic.bin"))
    // Header layout: [magic 4B][version u16 LE][flags u16 LE]; version is bytes 4..5.
    bytes[4] = 1
    bytes[5] = 0
    #expect(throws: (any Error).self) {
        _ = try binaryToDocument(Data(bytes))
    }
}

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

/// Apply one fixture op to `model` via `controller`, exactly as the legacy
/// harness did. Hoisted to module scope (out of `runOperationFixture`) so BOTH
/// the snapshot path and the journal-replay gate (`replayJournal`) drive the
/// identical dispatcher. The `op` dictionary is the raw fixture payload —
/// `PrimitiveOp.params` carries the same dictionary, so a recorded op replays
/// by feeding `op.params` straight back here.
private func applyFixtureOp(_ model: Model, _ controller: Controller, _ op: [String: Any]) {
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
    case "assign_id":
        let path = (op["path"] as! [Any]).map { ($0 as! NSNumber).intValue }
        controller.assignId(path, id: op["id"] as! String)
    case "create_reference":
        let targetPath = (op["target_path"] as! [Any]).map { ($0 as! NSNumber).intValue }
        controller.createReference(
            targetPath,
            targetId: op["target_id"] as! String,
            refId: op["ref_id"] as! String)
    // Symbols P2 operations (SYMBOLS.md §7). Value-in-op: the ids and
    // paths are read literally from the fixture payload, exactly like
    // the create_reference case.
    case "make_symbol":
        let path = (op["path"] as! [Any]).map { ($0 as! NSNumber).intValue }
        controller.makeSymbol(
            path,
            masterId: op["master_id"] as! String,
            refId: op["ref_id"] as! String)
    case "place_instance":
        controller.placeInstance(
            masterId: op["master_id"] as! String,
            refId: op["ref_id"] as! String)
    case "detach":
        let path = (op["path"] as! [Any]).map { ($0 as! NSNumber).intValue }
        controller.detach(path)
    case "redefine":
        let path = (op["path"] as! [Any]).map { ($0 as! NSNumber).intValue }
        controller.redefine(
            masterId: op["master_id"] as! String,
            path,
            refId: op["ref_id"] as! String)
    case "delete_symbol":
        controller.deleteSymbol(
            masterId: op["master_id"] as! String)
    // Symbols P4 (SYMBOLS.md §4 / Fork F2). Value-in-op: the instance
    // transform is carried in the payload as {a,b,c,d,e,f} (the same
    // matrix shape parsed elsewhere) and applied verbatim.
    case "set_instance_transform":
        let path = (op["path"] as! [Any]).map { ($0 as! NSNumber).intValue }
        let t = op["transform"] as! [String: Any]
        let transform = Transform(
            a: (t["a"] as! NSNumber).doubleValue,
            b: (t["b"] as! NSNumber).doubleValue,
            c: (t["c"] as! NSNumber).doubleValue,
            d: (t["d"] as! NSNumber).doubleValue,
            e: (t["e"] as! NSNumber).doubleValue,
            f: (t["f"] as! NSNumber).doubleValue)
        controller.setInstanceTransform(path, transform: transform)
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
    case "boolean_union":
        controller.applyDestructiveBoolean("union")
    case "simplify":
        controller.simplifySelection(precision: (op["precision"] as? Double) ?? 0.5)
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

/// checkpoint_equivalence gate (OP_LOG.md §6): replay the committed-and-applied
/// prefix of the journal (`journal[0..<head]`) from the SAME setup SVG into a
/// fresh model and return its canonical JSON. The caller asserts this equals
/// the snapshot-path document, so the typed journal is proven to replay to the
/// same document the production undo/redo path produced. Mirrors Python's
/// `_replay_journal` / the Rust gate.
private func replayJournal(_ svg: String, _ journal: [Transaction], _ head: Int) -> String {
    let doc = svgToDocument(svg)
    let model = Model(document: doc)
    let controller = Controller(model: model)
    for txn in journal[0..<head] {
        for op in txn.ops {
            applyFixtureOp(model, controller, op.params)
        }
    }
    return documentToTestJson(model.document)
}

private func runOperationFixture(_ fixture: String) throws {
    let json = readFixture("operations/\(fixture)")
    let data = json.data(using: .utf8)!
    let tests = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

    for tc in tests {
        let name = tc["name"] as! String
        let setupSvg = tc["setup_svg"] as! String
        let expectedFile = tc["expected_json"] as! String

        let svg = readFixture("svg/\(setupSvg)")
        let expected = readFixture("operations/\(expectedFile)").trimmingCharacters(in: .whitespacesAndNewlines)

        let doc = svgToDocument(svg)
        let model = Model(document: doc)
        let controller = Controller(model: model)

        // Two fixture shapes (OP_LOG.md §5): the journal-native `txns` form
        // (each transaction commits explicitly via beginTxn/commitTxn, then a
        // `history` directive of undo/redo positions the cursor; snapshot/undo/
        // redo are NOT ops here) and the legacy flat `ops` form (one implicit
        // outer transaction, so non-undoable ops like select_rect are captured
        // into the journal). Each applied op is recorded into the open
        // transaction via recordOp(PrimitiveOp(op:, params: op)) so commitTxn
        // finalizes a transaction whose ops replay to the same document.
        if let txns = tc["txns"] as? [[String: Any]] {
            for txn in txns {
                model.beginTxn()
                if let txnName = txn["name"] as? String {
                    model.nameTxn(txnName)
                }
                for op in (txn["ops"] as! [[String: Any]]) {
                    applyFixtureOp(model, controller, op)
                    model.recordOp(PrimitiveOp(op: op["op"] as! String, params: op))
                }
                model.commitTxn()
                // OP_LOG.md Increment 3a: a `label` on a transaction marks a
                // version point — labelVersion stamps it onto the committed
                // transaction so it serializes into the journal artifact.
                if let label = txn["label"] as? String {
                    model.labelVersion(label)
                }
            }
            for h in (tc["history"] as? [String] ?? []) {
                switch h {
                case "undo": model.undo()
                case "redo": model.redo()
                default: Issue.record("Unknown history directive: \(h)")
                }
            }
        } else {
            model.beginTxn()
            for op in (tc["ops"] as! [[String: Any]]) {
                applyFixtureOp(model, controller, op)
                model.recordOp(PrimitiveOp(op: op["op"] as! String, params: op))
            }
            model.commitTxn()
        }

        let actual = documentToTestJson(model.document)
        #expect(actual == expected, "Operation test '\(name)' failed")

        // checkpoint_equivalence gate (OP_LOG.md §6): the journal must replay to
        // the same document as the snapshot path. Runs on EVERY operations
        // fixture.
        let replayed = replayJournal(svg, model.journal, model.journalHeadValue)
        #expect(replayed == actual,
            "checkpoint_equivalence gate failed for '\(name)': journal replay != snapshot path")
    }
}

/// The canonical recorded-live-element document (RECORDED_ELEMENTS.md): a
/// recorded element whose recipe copies its input "eye" and translates the copy
/// +50x. Built identically in every app's harness, so its documentToTestJson
/// serialization (the recipe + inputs) is the cross-language pin. Mirrors Rust
/// `recorded_canonical_document`.
private func recordedCanonicalDocument() -> Document {
    let recipe = [
        PrimitiveOp(op: "copy", params: ["from": ["eye"], "dx": 0.0, "dy": 0.0], targets: []),
        PrimitiveOp(op: "translate", params: ["ids": ["$0"], "dx": 50.0, "dy": 0.0], targets: []),
    ]
    let rec = RecordedElem(ops: recipe, inputs: [ElementRef("eye")], id: "rec")
    let layer = Layer(children: [.live(.recorded(rec))])
    return Document(layers: [layer], selectedLayer: 0, selection: [], artboards: [])
}

/// Cross-language pin (RECORDED_ELEMENTS.md §8): a recorded element's recipe +
/// inputs serialize byte-identically across the four native apps. Mirrors Rust
/// `recorded_cross_language`.
@Test func recordedCrossLanguage() {
    let actual = documentToTestJson(recordedCanonicalDocument())
    let expected = readFixture("operations/recorded_eye.json")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if actual != expected {
        print("=== EXPECTED (recorded_eye) ===")
        print(expected)
        print("=== ACTUAL (recorded_eye) ===")
        print(actual)
    }
    #expect(actual == expected, "recorded cross-language serialization mismatch")
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

/// Symbols P2 operation fixtures (SYMBOLS.md §7): make_symbol, place_instance,
/// detach, redefine. Each setup parses through the P1 SVG <defs> codec, runs
/// the op, and pins the canonical JSON all apps must reproduce.
@Test func operationSymbolsOps() throws {
    try runOperationFixture("symbols_ops.json")
}

/// Boolean grouping (OP_LOG.md §10 item 3): boolean_union + post-op simplify are
/// one transaction; the gate pins the journal replays to the snapshot-path doc.
@Test func operationBooleanOps() throws {
    try runOperationFixture("boolean_ops.json")
}

/// Canonical JSON of the Transaction journal (OP_LOG.md §10 item 4): pins the
/// reserved causal/merge metadata + each op's verb and targets across apps.
/// Fixed key order + deterministic txn-N ids make it byte-shareable. Mirrors
/// journal_to_test_json in the other apps' harnesses.
private func journalToTestJson(_ journal: [Transaction]) -> String {
    func opt(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
    let txns = journal.map { (t: Transaction) -> String in
        let ops = t.ops.map { (o: PrimitiveOp) -> String in
            let targets = o.targets.map { "\"\($0)\"" }.joined(separator: ",")
            return "{\"op\":\"\(o.op)\",\"targets\":[\(targets)]}"
        }.joined(separator: ",")
        return "{\"actor\":\"\(t.actor)\",\"label\":\(opt(t.label)),"
            + "\"lamport\":\(t.lamport),\"name\":\(opt(t.name)),"
            + "\"ops\":[\(ops)],\"parent\":\(opt(t.parent)),\"txn_id\":\"\(t.txnId)\"}"
    }.joined(separator: ",")
    return "[\(txns)]"
}

/// OP_LOG.md §10 item 4: the journal's causal/merge metadata serializes
/// byte-identically across apps (deterministic txn-N counter + parent edge).
/// Runs BOTH the base txn_metadata fixture and the txn_labels fixture
/// (OP_LOG.md Increment 3a: a transaction `label` stamps a version onto the
/// committed txn so the label serializes into the journal artifact).
@Test func journalTxnMetadata() throws {
    for fixture in ["operations/txn_metadata.json", "operations/txn_labels.json"] {
        let json = readFixture(fixture)
        let tests = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [[String: Any]]
        for tc in tests {
            let svg = readFixture("svg/\(tc["setup_svg"] as! String)")
            let model = Model(document: svgToDocument(svg))
            let controller = Controller(model: model)
            for txn in (tc["txns"] as! [[String: Any]]) {
                model.beginTxn()
                if let n = txn["name"] as? String { model.nameTxn(n) }
                for op in (txn["ops"] as! [[String: Any]]) {
                    applyFixtureOp(model, controller, op)
                    model.recordOp(PrimitiveOp(op: op["op"] as! String, params: op))
                }
                model.commitTxn()
                // Increment 3a: stamp the label onto the committed transaction.
                if let label = txn["label"] as? String {
                    model.labelVersion(label)
                }
            }
            let actual = journalToTestJson(model.journal)
            let expected = readFixture("operations/\(tc["expected_journal_json"] as! String)")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(actual == expected, "journal JSON mismatch for \(fixture)")
        }
    }
}

// MARK: - Workspace layout equivalence tests

private func assertWorkspaceFixture(_ name: String, _ json: String) {
    let expected = readFixture("expected/\(name).json").trimmingCharacters(in: .whitespacesAndNewlines)
    if json != expected {
        print("=== EXPECTED (\(name)) ===")
        print(expected)
        print("=== ACTUAL (\(name)) ===")
        print(json)
    }
    #expect(json == expected, "Workspace test '\(name)' failed: canonical JSON mismatch")
}

@Test func testWorkspaceDefaultLayout() {
    let layout = WorkspaceLayout.defaultLayout()
    let json = workspaceToTestJson(layout)
    assertWorkspaceFixture("workspace_default", json)
}

@Test func testWorkspaceDefaultWithPanes() {
    var layout = WorkspaceLayout.defaultLayout()
    layout.ensurePaneLayout(viewportW: 1200, viewportH: 800)
    let json = workspaceToTestJson(layout)
    assertWorkspaceFixture("workspace_default_with_panes", json)
}

@Test func testWorkspaceJsonRoundtrip() {
    for name in ["workspace_default", "workspace_default_with_panes"] {
        let fixture = readFixture("expected/\(name).json").trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = testJsonToWorkspace(fixture)
        let reserialized = workspaceToTestJson(parsed)
        #expect(fixture == reserialized, "Workspace JSON roundtrip failed for '\(name)'")
    }
}

@Test func testToolbarStructure() {
    let json = toolbarStructureJson()
    assertWorkspaceFixture("toolbar_structure", json)
}

@Test func testMenuStructure() {
    let json = menuStructureJson()
    assertWorkspaceFixture("menu_structure", json)
}

@Test func testStateDefaults() {
    let json = stateDefaultsJson()
    assertWorkspaceFixture("state_defaults", json)
}

@Test func testShortcutStructure() {
    let json = shortcutStructureJson()
    assertWorkspaceFixture("shortcut_structure", json)
}

// MARK: - Workspace operation equivalence tests

private func applyWorkspaceOp(_ layout: inout WorkspaceLayout, _ op: [String: Any]) {
    let name = op["op"] as! String
    switch name {
    // Panel/dock operations
    case "toggle_group_collapsed":
        layout.toggleGroupCollapsed(GroupAddr(
            dockId: DockId(op["dock_id"] as! Int),
            groupIdx: op["group_idx"] as! Int
        ))
    case "set_active_panel":
        layout.setActivePanel(PanelAddr(
            group: GroupAddr(
                dockId: DockId(op["dock_id"] as! Int),
                groupIdx: op["group_idx"] as! Int
            ),
            panelIdx: op["panel_idx"] as! Int
        ))
    case "close_panel":
        layout.closePanel(PanelAddr(
            group: GroupAddr(
                dockId: DockId(op["dock_id"] as! Int),
                groupIdx: op["group_idx"] as! Int
            ),
            panelIdx: op["panel_idx"] as! Int
        ))
    case "show_panel":
        let kind = parsePanelKindOp(op["kind"] as! String)
        layout.showPanel(kind)
    case "reorder_panel":
        layout.reorderPanel(
            GroupAddr(
                dockId: DockId(op["dock_id"] as! Int),
                groupIdx: op["group_idx"] as! Int
            ),
            from: op["from"] as! Int,
            to: op["to"] as! Int
        )
    case "move_panel_to_group":
        layout.movePanelToGroup(
            PanelAddr(
                group: GroupAddr(
                    dockId: DockId(op["from_dock_id"] as! Int),
                    groupIdx: op["from_group_idx"] as! Int
                ),
                panelIdx: op["from_panel_idx"] as! Int
            ),
            to: GroupAddr(
                dockId: DockId(op["to_dock_id"] as! Int),
                groupIdx: op["to_group_idx"] as! Int
            )
        )
    case "detach_group":
        layout.detachGroup(
            GroupAddr(
                dockId: DockId(op["dock_id"] as! Int),
                groupIdx: op["group_idx"] as! Int
            ),
            x: op["x"] as! Double,
            y: op["y"] as! Double
        )
    case "redock":
        layout.redock(DockId(op["dock_id"] as! Int))
    // Pane operations
    case "set_pane_position":
        layout.panesMut { pl in
            pl.setPanePosition(
                PaneId(op["pane_id"] as! Int),
                x: op["x"] as! Double,
                y: op["y"] as! Double
            )
        }
    case "tile_panes":
        layout.panesMut { pl in
            pl.tilePanes(collapsedOverride: nil)
        }
    case "toggle_canvas_maximized":
        layout.panesMut { pl in
            pl.toggleCanvasMaximized()
        }
    case "resize_pane":
        layout.panesMut { pl in
            pl.resizePane(
                PaneId(op["pane_id"] as! Int),
                width: op["width"] as! Double,
                height: op["height"] as! Double
            )
        }
    case "hide_pane":
        let kind = parsePaneKindOp(op["kind"] as! String)
        layout.panesMut { pl in
            pl.hidePane(kind)
        }
    case "show_pane":
        let kind = parsePaneKindOp(op["kind"] as! String)
        layout.panesMut { pl in
            pl.showPane(kind)
        }
    case "bring_pane_to_front":
        layout.panesMut { pl in
            pl.bringPaneToFront(PaneId(op["pane_id"] as! Int))
        }
    default:
        Issue.record("Unknown workspace op: \(name)")
    }
}

private func parsePanelKindOp(_ s: String) -> PanelKind {
    switch s {
    case "color": return .color
    case "stroke": return .stroke
    case "properties": return .properties
    default: return .layers
    }
}

private func parsePaneKindOp(_ s: String) -> PaneKind {
    switch s {
    case "toolbar": return .toolbar
    case "dock": return .dock
    default: return .canvas
    }
}

private func runWorkspaceOperationFixture(_ fixture: String) throws {
    let json = readFixture("workspace_operations/\(fixture)")
    let data = json.data(using: .utf8)!
    let tests = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

    for tc in tests {
        let name = tc["name"] as! String
        let setupName = tc["setup"] as! String
        let expectedFile = tc["expected_json"] as! String
        let ops = tc["ops"] as! [[String: Any]]

        let setupJson = readFixture("expected/\(setupName)").trimmingCharacters(in: .whitespacesAndNewlines)
        var layout = testJsonToWorkspace(setupJson)

        for op in ops {
            applyWorkspaceOp(&layout, op)
        }

        let actual = workspaceToTestJson(layout)
        let expected = readFixture("workspace_operations/\(expectedFile)").trimmingCharacters(in: .whitespacesAndNewlines)

        if actual != expected {
            print("=== EXPECTED (\(name)) ===")
            print(expected)
            print("=== ACTUAL (\(name)) ===")
            print(actual)
        }
        #expect(actual == expected, "Workspace operation test '\(name)' failed")
    }
}

@Test func testWorkspacePanelOps() throws {
    try runWorkspaceOperationFixture("panel_ops.json")
}

@Test func testWorkspacePaneOps() throws {
    try runWorkspaceOperationFixture("pane_ops.json")
}

// MARK: - Pane geometry algorithm test vectors

private func parseEdgeSideOp(_ s: String) -> EdgeSide {
    switch s {
    case "right": return .right
    case "top": return .top
    case "bottom": return .bottom
    default: return .left
    }
}

@Test func testAlgorithmPaneGeometry() throws {
    let json = readFixture("algorithms/pane_geometry.json")
    let data = json.data(using: .utf8)!
    let tests = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

    for tc in tests {
        let name = tc["name"] as! String
        let function = tc["function"] as! String
        let args = tc["args"] as! [String: Any]
        let expected = tc["expected"] as! Double

        let actual: Double
        switch function {
        case "pane_edge_coord":
            let pane = Pane(
                id: PaneId(0),
                kind: .canvas,
                config: .forKind(.canvas),
                x: args["x"] as! Double,
                y: args["y"] as! Double,
                width: args["width"] as! Double,
                height: args["height"] as! Double
            )
            let edge = parseEdgeSideOp(args["edge"] as! String)
            actual = PaneLayout.paneEdgeCoord(pane, edge)
        default:
            Issue.record("Unknown function: \(function)")
            continue
        }
        #expect(abs(actual - expected) < 0.0001,
            "Pane geometry '\(name)' failed: expected \(expected), got \(actual)")
    }
}

// MARK: - Hit test algorithm vectors

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
