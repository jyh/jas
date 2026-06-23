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
        // CONCEPTS.md 3b: a Generated concept-instance (concept id + params)
        // round-trips through test_json byte-identically to the Rust-authored
        // golden — the cross-language pin for the generated kind.
        "generated_polygon",
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
        model.setDocumentUnbracketed(newDoc)
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

/// Apply one fixture op to `model` via `controller`. A thin shim over the
/// production dispatcher (OP_LOG.md §9, Increment 3b-B): both the cross-language
/// harness and the production effect path go through the SAME `opApply` module
/// and the SAME `recordOp` site, so this lift is behavior-preserving (the
/// operations fixtures stay byte-green) and `targets` is recorded identically on
/// both paths. Promoting the dispatcher out of the test target also hardened its
/// param parsing so production input can't crash. The `op` dictionary is the raw
/// fixture payload — `PrimitiveOp.params` carries the same dictionary, so a
/// recorded op replays by feeding `op.params` straight back here. Mirrors Rust's
/// `apply_op` shim over `op_apply`.
///
/// Because `opApply` now records the op into the open transaction itself (the
/// single `recordOp` site), the harness loops below no longer call `recordOp`
/// separately. The legacy `snapshot` op (history navigation) maps to `opApply`'s
/// commit-then-begin, matching Rust.
private func applyFixtureOp(_ model: Model, _ controller: Controller, _ op: [String: Any]) {
    opApply(model, controller, op)
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
        // into the journal). `applyFixtureOp` now routes through the production
        // `opApply`, which records each op into the open transaction at its
        // single `recordOp` site (with `targets` populated for the three
        // replay-safe verbs) — so the loops no longer record separately.
        if let txns = tc["txns"] as? [[String: Any]] {
            for txn in txns {
                model.beginTxn()
                if let txnName = txn["name"] as? String {
                    model.nameTxn(txnName)
                }
                for op in (txn["ops"] as! [[String: Any]]) {
                    applyFixtureOp(model, controller, op)
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

// MARK: - OP_LOG.md §9 verb33 unification fixtures (P1–P7)
//
// The shared test_fixtures/operations/* fixtures the Rust P1–P7 phases added are
// the ORACLE: each replays through the Swift `opApply` and byte-matches its
// golden (documentToTestJson), exactly as the pre-existing operations fixtures
// do, plus the checkpoint_equivalence replay gate. Mirrors the Rust
// cross_language_test.rs registrations.

// P1 — print-config setters (8 verbs). The single source fixture
// print_config_setters.json carries 5 sub-cases (document_setup,
// preferences_root, output_and_inks, graphics_cm_marks_advanced,
// type_mismatch_skips); the per-case print_config_*.json files are their
// expected-document goldens, not separate source fixtures.
@Test func operationPrintConfigSetters() throws { try runOperationFixture("print_config_setters.json") }

// P2 — artboard reorder / field setters (5 verbs).
@Test func operationArtboardSetFieldBatch() throws { try runOperationFixture("artboard_set_field_batch.json") }
@Test func operationArtboardReorder() throws { try runOperationFixture("artboard_reorder.json") }
@Test func operationArtboardDelete() throws { try runOperationFixture("artboard_delete.json") }

// P3 — artboard create / duplicate (value-in-op ids).
@Test func operationArtboardCreate() throws { try runOperationFixture("artboard_create.json") }
@Test func operationArtboardDuplicate() throws { try runOperationFixture("artboard_duplicate.json") }

// P4 — structural delete / insert (value-in-op element JSON).
@Test func operationStructuralDeleteAt() throws { try runOperationFixture("structural_delete_at.json") }
@Test func operationStructuralDeleteSelection() throws { try runOperationFixture("structural_delete_selection.json") }
@Test func operationStructuralInsertAfter() throws { try runOperationFixture("structural_insert_after.json") }
@Test func operationStructuralInsertAt() throws { try runOperationFixture("structural_insert_at.json") }

// P5 — group / layer wrapping (multi-step → one op).
@Test func operationWrapInGroup() throws { try runOperationFixture("wrap_in_group.json") }
@Test func operationWrapInLayer() throws { try runOperationFixture("wrap_in_layer.json") }
@Test func operationUnpackGroupAt() throws { try runOperationFixture("unpack_group_at.json") }

// P6 — set_attr_on_selection (brush attrs).
@Test func operationSetAttrOnSelection() throws { try runOperationFixture("set_attr_on_selection.json") }

// P7 — transforms (scale / rotate / shear / copy).
@Test func operationTransformScale() throws { try runOperationFixture("transform_scale.json") }
@Test func operationTransformRotate() throws { try runOperationFixture("transform_rotate.json") }
@Test func operationTransformShear() throws { try runOperationFixture("transform_shear.json") }
@Test func operationTransformCopy() throws { try runOperationFixture("transform_copy.json") }

// MARK: - OP_LOG 3c-1: id-primary op-addressing flip (move / copy / select)

/// OP_LOG.md §5 Fork 4 / 3c-1 — the id-primary op-addressing flip. The fixture
/// carries TWO cases on the SAME `eye.svg` pointing at the SAME golden:
///   - `selrel_move_eye`   : `[select_rect, move_selection]` (selection-relative)
///   - `id_primary_move_eye`: `[select_by_ids, move_by_ids]` (id-primary)
/// Both must produce a BYTE-IDENTICAL document AND selection (the golden is
/// shared), which proves the id-primary verbs replay to the same document+
/// selection as the selection-relative pair — the byte-gate reconciliation. The
/// unchanged `checkpoint_equivalence` gate (run per case by `runOperationFixture`)
/// additionally proves each journals a replay-safe segment. The id-primary verb
/// reads its operand ids from its OWN params, so snapshot and replay apply
/// identical operands (the §7 determinism rule). Mirrors Rust
/// `operation_id_primary_move`.
@Test func operationIdPrimaryMove() throws { try runOperationFixture("id_primary_move.json") }

/// OP_LOG.md §5 Fork 4 / 3c-1 — the id-primary copy verb. Same shared-golden
/// shape as `operationIdPrimaryMove`: `[select_rect, copy_selection]` and
/// `[select_by_ids, copy_by_ids]` produce a byte-identical document (the copy is
/// born id-less on BOTH paths) AND selection. Mirrors Rust
/// `operation_id_primary_copy`.
@Test func operationIdPrimaryCopy() throws { try runOperationFixture("id_primary_copy.json") }

/// 3c-1 determinism check (OP_LOG.md §7): an id-primary op reads its operand ids
/// from its OWN params, NEVER from `doc.selection`, so it applies the SAME
/// operands regardless of the ambient selection. Drive `move_by_ids{["eye"]}`
/// with a DELIBERATELY WRONG ambient selection (the whole layer pre-selected)
/// and confirm the result still equals the shared golden — i.e. the op ignored
/// the ambient selection and moved exactly the operand named in its params.
/// Mirrors Rust `id_primary_move_reads_operand_from_params_not_selection`.
@Test func idPrimaryMoveReadsOperandFromParamsNotSelection() {
    let svg = readFixture("svg/eye.svg")
    let model = Model(document: svgToDocument(svg))
    let controller = Controller(model: model)
    // Poison the ambient selection with an unrelated path — an op that inferred
    // its operand from doc.selection would act on the wrong thing.
    controller.setSelection([ElementSelection.all([0])])
    model.beginTxn()
    opApply(model, controller, ["op": "select_by_ids", "ids": ["eye"]])
    opApply(model, controller, ["op": "move_by_ids", "ids": ["eye"], "dx": 50, "dy": 0])
    model.commitTxn()
    let actual = documentToTestJson(model.document)
    let expected = readFixture("operations/id_primary_move_eye.json")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(actual == expected,
        "id-primary move read its operand from params, not the ambient selection")

    // Snapshot==replay even though the snapshot ran with a poisoned ambient
    // selection: the journaled ops carry their own operands, so a fresh replay
    // (no ambient selection) reproduces the document byte-identically.
    let replayed = replayJournal(svg, model.journal, model.journalHeadValue)
    #expect(replayed == actual,
        "id-primary op applies identical operands on snapshot and replay")
}

/// 3c-1 EYE-DEMO RE-DERIVATION PIN (the load-bearing payoff): run a FAITHFUL
/// id-primary journal segment `[select_by_ids, copy_by_ids]` through the SHARED
/// dispatcher (so it is a real, byte-gated, replayable journal segment),
/// normalize the committed segment to a `RecordedElem` via the now-pass-through
/// `captureRecipe`, edit the SOURCE input, re-derive, and confirm the output
/// TRACKS the edited source. The recipe survives source edits with NO selection
/// dependency — the operand ids came from the op params (`from:["eye"]`), never
/// from a select op's resolved selection. Reuses the existing eye-demo golden
/// (`eye_demo_rederived.json`): `copy_by_ids{dx:50}` captures to `copy{dx:50}`,
/// whose re-derivation against the edited source (eye→x=100px) is byte-identical
/// to the selection-relative demo's copy(0)+translate(50) net offset. Mirrors
/// Rust `id_primary_capture_recipe_rederives_on_source_edit`.
@Test func idPrimaryCaptureRecipeRederivesOnSourceEdit() {
    // A faithful id-primary demonstration: select the eye, copy it +50. This is
    // a REAL journal segment opApply replays byte-identically (it is the
    // id_primary_copy fixture's id-primary case).
    let svg = readFixture("svg/eye.svg")
    let model = Model(document: svgToDocument(svg))
    let controller = Controller(model: model)
    model.beginTxn()
    model.nameTxn("id-primary demo")
    opApply(model, controller, ["op": "select_by_ids", "ids": ["eye"]])
    opApply(model, controller, ["op": "copy_by_ids", "from": ["eye"], "dx": 50, "dy": 0])
    model.commitTxn()

    // captureRecipe is a PASS-THROUGH over the id-primary segment: it reads the
    // operand id from the op's `from` PARAM (no selection dependency —
    // select_by_ids' targets are NOT consulted).
    let segment = model.journal.last!.ops
    // Guard: the captured segment is purely id-primary (proves the brittle
    // selection-relative bridge is NOT on this path).
    for op in segment {
        #expect(op.op == "select_by_ids" || op.op == "copy_by_ids",
            "segment is id-primary, got \(op.op)")
    }
    let (recipe, inputs) = captureRecipe(segment)
    #expect(inputs == ["eye"])
    #expect(recipe.count == 1)
    #expect(recipe[0].op == "copy")
    #expect(recordedStrIds(recipe[0].params, "from") == ["eye"])

    // Wrap + re-derive against the EDITED source (eye moved to x=100 px).
    let recorded = RecordedElem(ops: recipe, inputs: inputs.map { ElementRef($0) }, id: "rec")
    let editedSvg = svg.replacingOccurrences(of: "x=\"0\" y=\"0\"", with: "x=\"100\" y=\"0\"")
    let editedEl = svgToDocument(editedSvg).getElement([0, 0])
    struct OneResolver: ElementResolver {
        let id: String
        let el: Element
        func resolve(_ ref: ElementRef) -> Element? { ref.id == id ? el : nil }
    }
    let resolver = OneResolver(id: "eye", el: editedEl)
    var visiting: VisitSet = []
    let ps = recorded.evaluateWith(precision: DEFAULT_PRECISION, resolver: resolver, visiting: &visiting)
    let actual = polygonSetToTestJson(ps)
    // The re-derived output tracks the edited source — the SAME golden the
    // selection-relative eye demo pins (the net offset is identical).
    let expected = readFixture("production_capture/eye_demo_rederived.json")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(actual == expected,
        "the id-primary recipe re-derived against the edited source, no selection dependency")
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

// MARK: - Per-frame drag coalescing (OP_LOG.md §9 follow-up)
//
// A live drag commits ONE transaction PER FRAME (selection.yaml fires
// doc.snapshot only on the first mousemove; each on_mousemove is its own
// runEffects batch that beginTxns + commits), so a drag of N frames lands as N
// consecutive single-op move transactions in the journal — and N undo steps.
// `Model.commitTxn` coalesces ADJACENT same-gesture move transactions
// (move_selection / move_by_ids) into ONE summed-delta translate, collapsing the
// N undo steps into one. The txns-form below commits each frame SEPARATELY, so
// the SECOND commit triggers coalescing into the first. Mirrors the Rust
// cross_language_test.rs registrations.

/// The dx/dy of a journal transaction's LAST op (the move being summed).
private func lastOpDelta(_ txn: Transaction) -> (Double, Double) {
    let op = txn.ops.last!
    return (
        (op.params["dx"] as? NSNumber)?.doubleValue ?? 0.0,
        (op.params["dy"] as? NSNumber)?.doubleValue ?? 0.0
    )
}

/// Drive a coalescing fixture (txns-form, each frame committed separately) and
/// assert the post-coalesce journal shape + undo-step lock-step:
///  - the journal collapsed to `expect_journal_txns` transactions;
///  - the tip txn's op list is `expect_journal_ops` long (when declared);
///  - the tip txn's last move op carries the SUMMED delta (when declared);
///  - the undo stack and journal cursor are in lock-step
///    (`journalHead == expect_undo_steps`), and undoing exactly that many times
///    drains both back to the origin (`canUndo` false, `journalHead == 0`) — i.e.
///    ONE undo reverts a whole coalesced drag. Mirrors Rust `assert_drag_coalesce`.
private func assertDragCoalesce(_ tc: [String: Any]) {
    let name = tc["name"] as! String
    let svg = readFixture("svg/\(tc["setup_svg"] as! String)")
    let model = Model(document: svgToDocument(svg))
    let controller = Controller(model: model)
    for txn in (tc["txns"] as! [[String: Any]]) {
        model.beginTxn()
        if let n = txn["name"] as? String { model.nameTxn(n) }
        for op in (txn["ops"] as! [[String: Any]]) {
            applyFixtureOp(model, controller, op)
        }
        model.commitTxn()
    }

    let expectTxns = (tc["expect_journal_txns"] as! NSNumber).intValue
    #expect(model.journal.count == expectTxns,
        "[\(name)] journal txn count: expected \(expectTxns), got \(model.journal.count)")

    if let ops = (tc["expect_journal_ops"] as? NSNumber)?.intValue {
        let tip = model.journal.last!
        #expect(tip.ops.count == ops,
            "[\(name)] tip txn op count: expected \(ops), got \(tip.ops.count)")
    }
    if let dx = (tc["expect_last_move_dx"] as? NSNumber)?.doubleValue {
        let dy = (tc["expect_last_move_dy"] as? NSNumber)?.doubleValue ?? 0.0
        let (gdx, gdy) = lastOpDelta(model.journal.last!)
        #expect(gdx == dx && gdy == dy,
            "[\(name)] summed delta: expected (\(dx),\(dy)), got (\(gdx),\(gdy))")
    }

    // Undo-step lock-step: journal cursor == undo depth == declared steps.
    let steps = (tc["expect_undo_steps"] as! NSNumber).intValue
    #expect(model.journalHeadValue == steps,
        "[\(name)] journalHead (== undo steps): expected \(steps), got \(model.journalHeadValue)")
    for i in 0..<steps {
        #expect(model.canUndo, "[\(name)] expected to undo step \(i)")
        model.undo()
    }
    #expect(!model.canUndo,
        "[\(name)] after \(steps) undos the undo stack must be empty (lock-step)")
    #expect(model.journalHeadValue == 0,
        "[\(name)] after \(steps) undos the journal cursor must be at the origin")
}

/// (a)/(c)-twin coalescing pins + (c)-via-name/copy break pins, driven from the
/// shared `drag_coalesce.json` fixture (txns-form, cross-language). Mirrors Rust
/// `drag_coalesce`.
@Test func dragCoalesce() throws {
    let json = readFixture("operations/drag_coalesce.json")
    let tests = try JSONSerialization.jsonObject(
        with: json.data(using: .utf8)!) as! [[String: Any]]
    for tc in tests {
        assertDragCoalesce(tc)
    }
}

/// (b) NET-ZERO whole-drag: a same-name same-target run that sums to (0,0) AND
/// round-trips the document leaves NO journal entry and NO undo step.
///
/// The selection is pre-established OUT OF BAND (non-undoable
/// `Controller.selectRect`, journaling nothing) so the two move frames are the
/// ONLY journaled transactions — and after the net-zero drop the journal is
/// genuinely EMPTY and the document is byte-identical to pre-drag. Mirrors Rust
/// `drag_coalesce_net_zero`.
@Test func dragCoalesceNetZero() {
    let setup = readFixture("svg/eye.svg")
    let model = Model(document: svgToDocument(setup))
    let controller = Controller(model: model)

    // Pre-select the eye out of band (no journal entry, no undo step).
    controller.selectRect(x: -5.0, y: -5.0, width: 55.0, height: 55.0, extend: false)
    let preDrag = documentToTestJson(model.document)
    #expect(model.journal.isEmpty, "out-of-band select must not journal")
    #expect(!model.canUndo, "out-of-band select must not push an undo step")

    // Frame 1: move dx:5 (commits one txn into the empty journal).
    model.beginTxn()
    model.nameTxn("selection on_mousemove")
    applyFixtureOp(model, controller, ["op": "move_selection", "dx": 5, "dy": 0])
    model.commitTxn()
    #expect(model.journal.count == 1, "frame 1 journals one txn")
    #expect(model.canUndo, "frame 1 pushes one undo step")

    // Frame 2: move dx:-5 (same name, same target) -> net (0,0) round-trip.
    model.beginTxn()
    model.nameTxn("selection on_mousemove")
    applyFixtureOp(model, controller, ["op": "move_selection", "dx": -5, "dy": 0])
    model.commitTxn()

    #expect(model.journal.isEmpty,
        "net-zero whole-drag must leave NO journal entry, got \(model.journal.count) txns")
    #expect(model.journalHeadValue == 0, "net-zero whole-drag leaves cursor at origin")
    #expect(!model.canUndo,
        "net-zero whole-drag must leave NO undo step (no-op rule across the run)")
    #expect(documentToTestJson(model.document) == preDrag,
        "net-zero whole-drag must restore the pre-drag document byte-for-byte")
}

/// (c) TARGET break (predicate c proper): two ADJACENT single-op move frames
/// whose target sets differ do NOT coalesce. The selection is changed OUT OF
/// BAND between the frames (so each frame is a single-op move txn, isolating the
/// target-mismatch predicate from the op-count predicate), proving the run
/// breaks and stays TWO distinct undo steps. Mirrors Rust
/// `drag_coalesce_target_break`.
@Test func dragCoalesceTargetBreak() {
    let setup = readFixture("svg/two_ided_rects.svg")
    let model = Model(document: svgToDocument(setup))
    let controller = Controller(model: model)

    // Select element "a" (path [0,0]) out of band.
    controller.setSelection([ElementSelection.all([0, 0])])

    // Frame 1: move "a".
    model.beginTxn()
    model.nameTxn("selection on_mousemove")
    applyFixtureOp(model, controller, ["op": "move_selection", "dx": 5, "dy": 0])
    model.commitTxn()
    #expect(model.journal.count == 1)
    #expect(model.journal[0].ops[0].targets == ["a"], "frame 1 targets element a")

    // Change selection to "b" (path [0,1]) out of band — a DIFFERENT target.
    controller.setSelection([ElementSelection.all([0, 1])])

    // Frame 2: a single-op move on "b". Same name, same verb, but the target set
    // differs ([a] vs [b]) -> predicate (c) fails -> NO coalesce.
    model.beginTxn()
    model.nameTxn("selection on_mousemove")
    applyFixtureOp(model, controller, ["op": "move_selection", "dx": 7, "dy": 0])
    model.commitTxn()

    #expect(model.journal.count == 2,
        "different target must NOT coalesce -> two distinct txns")
    #expect(model.journal[1].ops[0].targets == ["b"], "frame 2 targets element b")
    #expect(model.journalHeadValue == 2, "two distinct undo steps (lock-step)")
    // Both moves are single-op, single-target additive translates of the SAME
    // verb/name — only the TARGET differs — so this isolates predicate (c) from
    // the op-count and verb predicates.
    let (dx0, _) = lastOpDelta(model.journal[0])
    let (dx1, _) = lastOpDelta(model.journal[1])
    #expect(dx0 == 5.0 && dx1 == 7.0,
        "deltas stay separate (5 and 7), not summed")
}

/// (guard) TIP guard (predicate `journalHead == opJournal.count`): a coalescable
/// move frame committed AFTER an undo — when the journal cursor sits BEHIND the
/// tip (`journalHead < count`) — must NOT merge into the about-to-be-truncated
/// redo tail. It must take the normal truncate/append path: the redo tail is
/// discarded and the new frame lands as its OWN txn with its OWN delta (never
/// summed into the stale tail).
///
/// This is the ONLY test that drives `commitTxn` with `journalHead < count` for a
/// coalescable move, so it is the sole signal for the TIP guard: without it,
/// regressing the guard is invisible to the suite because the merge target is
/// unconditionally `opJournal.last` — a regressed guard would silently fuse this
/// frame's delta into a redo-tail txn that is about to be truncated, corrupting
/// history. Mirrors Rust `drag_coalesce_post_undo_no_merge`.
@Test func dragCoalescePostUndoNoMerge() {
    let setup = readFixture("svg/two_ided_rects.svg")
    let model = Model(document: svgToDocument(setup))
    let controller = Controller(model: model)

    // Select element "a" (path [0,0]) out of band (no journal entry).
    controller.setSelection([ElementSelection.all([0, 0])])

    // Frame 1: a coalescable move (dx:5). Commits one txn at the tip.
    model.beginTxn()
    model.nameTxn("selection on_mousemove")
    applyFixtureOp(model, controller, ["op": "move_selection", "dx": 5, "dy": 0])
    model.commitTxn()
    #expect(model.journal.count == 1, "frame 1 journals one txn")
    #expect(model.journalHeadValue == 1, "cursor at the tip after frame 1")

    // Undo frame 1: cursor moves BEHIND the tip (journalHead 0 < count 1) and a
    // redo entry is staged. This is the guard's scenario.
    model.undo()
    #expect(model.journalHeadValue == 0, "undo moved the cursor behind the tip")
    #expect(model.journal.count == 1, "the undone txn is still the redo tail")
    #expect(model.canRedo, "frame 1 is available to redo")

    // Frame 2: a SAME name / SAME target / SAME verb coalescable move (dx:11) —
    // every predicate (a)-(e) holds EXCEPT the TIP guard, which fails
    // (journalHead 0 != count 1). So it must NOT coalesce: the normal path
    // truncates the redo tail and appends frame 2 as its own txn.
    model.beginTxn()
    model.nameTxn("selection on_mousemove")
    applyFixtureOp(model, controller, ["op": "move_selection", "dx": 11, "dy": 0])
    model.commitTxn()

    // Normal truncate/append ran: redo tail discarded, frame 2 appended fresh.
    #expect(model.journal.count == 1,
        "post-undo frame must truncate+append (one txn), NOT merge into the redo tail")
    #expect(model.journalHeadValue == 1, "cursor advanced to the new tip (lock-step)")
    #expect(!model.canRedo, "a new edit discards the redo tail")
    // The decisive guard signal: the surviving txn carries frame 2's delta ALONE
    // (11), never frame 1's (5) summed in (16). A regressed guard would have
    // merged into the stale tail and produced 16.
    let (dx, _) = lastOpDelta(model.journal[0])
    #expect(dx == 11.0,
        "surviving txn carries frame 2's delta alone (11), not summed with the discarded tail (would be 16) — proves the TIP guard blocked the merge")
    // And undoing the single surviving step drains the journal in lock-step.
    model.undo()
    #expect(model.journalHeadValue == 0, "one undo drains the single post-undo step")
    #expect(!model.canUndo, "no further undo steps")
}

// MARK: - Production op-capture (OP_LOG.md §9, Increment 3b-B)

/// Canonical JSON of the Transaction journal in the production-capture shape
/// (name + ops{op, params, targets}, NO txn_id). Distinct from
/// `journalToTestJson`: this pins the PARAM-TRANSLATION result (the marquee
/// corners x1=-5,y1=-5,x2=50,y2=50 normalize to x=-5,y=-5,width=55,height=55,
/// extend=false), so it emits each op's full `{op, params, targets}` with
/// `params` sorted-key + fixed-float canonicalized exactly like
/// `documentToTestJson` (via `canonicalRecordedValue`).
///
/// `txn_id` is EXCLUDED — it is a live-entropy seam, non-deterministic per-app,
/// so it can never be byte-shared. The redundant `"op"` key inside the recorded
/// `params` (opApply records the full op dict, verb included) is STRIPPED — the
/// verb already lives in the op-level `op` field. `actor`/`parent`/`lamport` are
/// OMITTED: this serializer pins only what the production-capture goldens are
/// about (the translated ops + the action name). Mirrors Rust
/// `production_journal_to_test_json`.
private func productionJournalToTestJson(_ journal: [Transaction]) -> String {
    func opt(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
    let txns = journal.map { (t: Transaction) -> String in
        let ops = t.ops.map { (o: PrimitiveOp) -> String in
            // Strip the redundant top-level "op" key from params.
            var params = o.params
            params.removeValue(forKey: "op")
            let targets = o.targets.map { "\"\($0)\"" }.joined(separator: ",")
            return "{\"op\":\"\(o.op)\",\"params\":\(canonicalRecordedValue(params))," +
                "\"targets\":[\(targets)]}"
        }.joined(separator: ",")
        return "{\"name\":\(opt(t.name)),\"ops\":[\(ops)]}"
    }.joined(separator: ",")
    return "[\(txns)]"
}

/// Canonical JSON of an evaluated polygon set (a list of rings, each a list of
/// (x,y) points), using the SAME fixed-float canonicalization as
/// `documentToTestJson` so the re-derived geometry golden is byte-shareable.
/// Mirrors Rust `polygon_set_to_test_json`.
private func polygonSetToTestJson(_ ps: BoolPolygonSet) -> String {
    let rings = ps.map { (ring: BoolRing) -> String in
        let pts = ring.map { (pt: (Double, Double)) -> String in
            "[\(canonicalRecordedValue(pt.0)),\(canonicalRecordedValue(pt.1))]"
        }.joined(separator: ",")
        return "[\(pts)]"
    }.joined(separator: ",")
    return "[\(rings)]"
}

/// Build the fresh Model a production-capture fixture's `setup_svg` defines.
private func productionModel(_ fixture: [String: Any]) -> Model {
    let svgPath = fixture["setup_svg"] as! String
    let svg = readFixture(svgPath)
    return Model(document: svgToDocument(svg))
}

/// Run every `runEffects` batch a production-capture fixture defines through the
/// REAL production interpreter, stamping the fixture's `action_name`.
///
/// Supports both fixture shapes:
///   - `effect_batch: [...]` — ONE runEffects call (the eye_demo
///     select→copy→move demonstration, committing one named transaction).
///   - `frames: [[...], [...]]` — MULTIPLE separate runEffects calls (the
///     drag-frame-hole closure: frame 1 = snapshot+select+translate, frame 2 =
///     a BARE translate with NO snapshot). Each frame is a distinct batch, so
///     each commits its own named transaction — the one scenario the test-path
///     operations corpus structurally cannot reach.
/// Mirrors Rust `run_production_batches`.
private func runProductionBatches(_ fixture: [String: Any], _ model: Model) {
    let actionName = fixture["action_name"] as? String
    let store = StateStore()
    let platformEffects = buildYamlToolEffects(model: model)
    func runBatch(_ effects: [Any]) {
        runEffects(effects, ctx: [:], store: store,
                   platformEffects: platformEffects,
                   model: model, actionName: actionName)
    }
    if let batch = fixture["effect_batch"] as? [Any] {
        runBatch(batch)
    } else if let frames = fixture["frames"] as? [[Any]] {
        for frame in frames { runBatch(frame) }
    } else {
        Issue.record("production-capture fixture has neither effect_batch nor frames")
    }
}

/// Re-derive the recorded element's output against the EDITED source and return
/// its canonical polygon-set JSON.
///
/// Lifts the LAST committed transaction's op segment (the production journal
/// segment), runs `captureRecipe` to normalize it into an input-addressed
/// recipe, wraps it in a `RecordedElem`, then `evaluateWith` it over a resolver
/// that returns the EDITED source (the fixture's `recorded.edit_source` applies
/// a textual SVG edit). The SVG px→pt unit conversion (96/72 = ×0.75) bakes into
/// the re-derived bbox: editing the source `eye` to x=100 (px) maps to x=75 (pt)
/// with w=10px→7.5pt; copy(dx=0)+translate(+50) → the derived bbox spans x in
/// [125, 132.5] (pt). Mirrors Rust `rederive_recorded_output`.
private func rederiveRecordedOutput(_ fixture: [String: Any], _ journal: [Transaction]) -> String {
    let segment = journal.last!.ops
    let (recipe, inputs) = captureRecipe(segment)
    let recorded = RecordedElem(
        ops: recipe, inputs: inputs.map { ElementRef($0) }, id: "rec")

    // Apply the fixture's edit to the source SVG, parse, and resolve the edited
    // element by id. Mirror the effects.rs proof's textual edit (replace
    // `x="0" y="0"` → `x="100" y="0"`) so the parse is identical to Rust.
    let rec = fixture["recorded"] as! [String: Any]
    let edit = rec["edit_source"] as! [String: Any]
    let editId = edit["id"] as! String
    let newX = ((edit["set"] as! [String: Any])["x"] as! NSNumber).intValue
    let svg = readFixture(fixture["setup_svg"] as! String)
    let editedSvg = svg.replacingOccurrences(
        of: "x=\"0\" y=\"0\"", with: "x=\"\(newX)\" y=\"0\"")
    let editedDoc = svgToDocument(editedSvg)
    // The edited source is layers[0].children[0].
    let editedEl = editedDoc.getElement([0, 0])

    struct OneResolver: ElementResolver {
        let id: String
        let el: Element
        func resolve(_ ref: ElementRef) -> Element? {
            ref.id == id ? el : nil
        }
    }
    let resolver = OneResolver(id: editId, el: editedEl)
    var visiting: VisitSet = []
    let ps = recorded.evaluateWith(
        precision: DEFAULT_PRECISION, resolver: resolver, visiting: &visiting)
    return polygonSetToTestJson(ps)
}

/// Reusable production-capture harness (OP_LOG.md §9, Increment 3b-B). Loads the
/// fixture, drives the REAL `runEffects` over `setup_svg`, then asserts:
///  (a) `productionJournalToTestJson` == `expected_journal_json` (pins the
///      translated ops + the action name);
///  (b) the `checkpoint_equivalence` replay (OP_LOG.md §6): replaying the journal
///      ops via `opApply` from `setup_svg` is byte-identical BOTH to
///      `expected_document_json` AND to the live snapshot-path document;
///  (c) the recorded re-derivation (when the fixture declares `recorded`) ==
///      `expected_output_json`;
///  (d) a SCOPED completeness assert (OP_LOG.md §9): EVERY committed production
///      transaction's `ops` is non-empty (the production path here MUST emit ops
///      — NOT a global commit_txn invariant). Mirrors Rust
///      `run_production_batch_fixture`.
private func runProductionBatchFixture(_ fixturePath: String) {
    let json = readFixture(fixturePath)
    let fx = try! JSONSerialization.jsonObject(
        with: json.data(using: .utf8)!) as! [String: Any]
    let name = (fx["name"] as? String) ?? fixturePath

    // Drive the REAL production interpreter.
    let model = productionModel(fx)
    runProductionBatches(fx, model)

    // (a) journal serialization == golden.
    let actualJournal = productionJournalToTestJson(model.journal)
    let expectedJournal = readFixture(fx["expected_journal_json"] as! String)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if actualJournal != expectedJournal {
        print("=== EXPECTED journal (\(name)) ===\n\(expectedJournal)")
        print("=== ACTUAL journal (\(name)) ===\n\(actualJournal)")
    }
    #expect(actualJournal == expectedJournal,
        "production-capture journal JSON mismatch for '\(name)'")

    // Snapshot-path document (the live result of runEffects).
    let snapshotDoc = documentToTestJson(model.document)

    // (b) checkpoint_equivalence: replay the WHOLE journal via opApply from a
    // fresh setup, byte-compare to BOTH the expected_document golden AND the
    // live snapshot-path document.
    let replay = productionModel(fx)
    let replayController = Controller(model: replay)
    for txn in model.journal {
        for op in txn.ops {
            opApply(replay, replayController, op.params)
        }
    }
    let replayDoc = documentToTestJson(replay.document)
    let expectedDoc = readFixture(fx["expected_document_json"] as! String)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if replayDoc != snapshotDoc {
        print("=== checkpoint_equivalence GATE FAILED (\(name)) ===")
        print("--- snapshot path ---\n\(snapshotDoc)")
        print("--- journal replay ---\n\(replayDoc)")
    }
    #expect(replayDoc == snapshotDoc,
        "checkpoint_equivalence: journal replay != snapshot path for '\(name)'")
    if replayDoc != expectedDoc {
        print("=== EXPECTED doc (\(name)) ===\n\(expectedDoc)")
        print("=== ACTUAL doc (\(name)) ===\n\(replayDoc)")
    }
    #expect(replayDoc == expectedDoc,
        "production-capture document JSON mismatch for '\(name)'")

    // (c) recorded re-derivation against the edited source == golden.
    if let rec = fx["recorded"] as? [String: Any] {
        let actualOut = rederiveRecordedOutput(fx, model.journal)
        let expectedOut = readFixture(rec["expected_output_json"] as! String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if actualOut != expectedOut {
            print("=== EXPECTED rederived (\(name)) ===\n\(expectedOut)")
            print("=== ACTUAL rederived (\(name)) ===\n\(actualOut)")
        }
        #expect(actualOut == expectedOut,
            "production-capture re-derivation mismatch for '\(name)'")
    }

    // (d) scoped completeness assert: every committed production transaction
    // emits ops (the production path here is NOT named-but-op-less).
    #expect(!model.journal.isEmpty,
        "production batch committed at least one transaction (\(name))")
    for (i, txn) in model.journal.enumerated() {
        #expect(!txn.ops.isEmpty,
            "production txn \(i) emits ops (3b-B completeness, \(name))")
    }
}

/// Production op-capture eye demo (OP_LOG.md §9): marquee-select → copy → move,
/// driven through the REAL runEffects, pins the translated journal, the
/// checkpoint-equivalent document, and the live re-derivation. Mirrors Rust
/// `production_capture_eye_demo`.
@Test func productionCaptureEyeDemo() {
    runProductionBatchFixture("production_capture/eye_demo.json")
}

/// Production op-capture drag-frame-hole closure (OP_LOG.md §9): two SEPARATE
/// runEffects batches — frame 1 (snapshot+select+translate) and a BARE frame 2
/// (translate, NO snapshot) — both commit NAMED transactions that journal their
/// move_selection op. The one scenario the test-path operations corpus
/// structurally cannot reach. Mirrors Rust
/// `production_capture_eye_demo_bare_frame`.
@Test func productionCaptureEyeDemoBareFrame() {
    runProductionBatchFixture("production_capture/eye_demo_bare_frame.json")
}

// MARK: - OP_LOG.md §9 Phase P7 — transform CONFIRM production route

/// Build a model with the rect_with_id selection established (the production
/// transform tests' shared setup). Mirrors Rust `transform_production_model`.
private func transformProductionModel() -> Model {
    let svg = readFixture("svg/rect_with_id.svg")
    let model = Model(document: svgToDocument(svg))
    let controller = Controller(model: model)
    model.beginTxn()
    opApply(model, controller, [
        "op": "select_rect", "x": 0.0, "y": 0.0, "width": 96.0, "height": 96.0,
        "extend": false,
    ])
    model.commitTxn()
    return model
}

/// Drive an action's effects through the REAL runEffects with the given resolved
/// `param.*` context, stamping `action` as the txn name. Mirrors Rust
/// `run_transform_action`.
private func runTransformAction(_ model: Model, _ action: String, _ params: [String: Any]) {
    guard let bundle = WorkspaceData.load(),
          let actionDef = bundle.actions()[action] as? [String: Any],
          let effects = actionDef["effects"] as? [Any] else {
        Issue.record("could not load action '\(action)' effects from bundle")
        return
    }
    let store = StateStore()
    let platformEffects = buildYamlToolEffects(model: model)
    runEffects(effects, ctx: ["param": params], store: store,
               actions: bundle.actions(),
               platformEffects: platformEffects,
               model: model, actionName: action)
}

/// True iff the element at `path` carries a non-nil transform.
private func transformedAt(_ model: Model, _ path: ElementPath) -> Bool {
    guard let el = model.document.tryGetElement(path) else { return false }
    return el.transform != nil
}

/// checkpoint_equivalence for a production-confirm model: replaying the whole
/// journal from the same setup must serialize byte-identically to the live doc.
private func assertConfirmReplayEquivalent(_ model: Model) {
    let live = documentToTestJson(model.document)
    let replayed = replayJournal(readFixture("svg/rect_with_id.svg"),
                                 model.journal, model.journalHeadValue)
    #expect(replayed == live,
        "checkpoint_equivalence: production confirm journal replay != live document")
}

/// Phase P7 — the PRODUCTION confirm path. Drives the REAL
/// scale/rotate/shear_options_confirm actions from the bundle (journal:true) and
/// asserts exactly ONE transform op is journaled carrying the RESOLVED params
/// (rx/ry = the 72×72-pt selection-bounds center = 36, the factors/angle/flags),
/// the live doc is transformed, and checkpoint_equivalence holds. Mirrors Rust
/// `production_transform_confirm_journals_one_op_with_resolved_params`.
@Test func productionTransformConfirmJournalsOneOp() {
    // (scale) uniform 200%, copy=false. 96×96 px → 72×72 pt ⇒ center (36, 36).
    do {
        let model = transformProductionModel()
        runTransformAction(model, "scale_options_confirm", [
            "uniform": true, "uniform_pct": 200.0,
            "horizontal_pct": 100.0, "vertical_pct": 100.0,
            "scale_strokes": true, "scale_corners": false,
            "preview": false, "copy": false,
        ])
        let txn = model.journal.last!
        #expect(txn.ops.map { $0.op } == ["scale_transform"],
            "confirm journals exactly one scale_transform op (copy=false)")
        let p = txn.ops[0].params
        #expect((p["sx"] as? NSNumber)?.doubleValue == 2.0)
        #expect((p["sy"] as? NSNumber)?.doubleValue == 2.0)
        #expect((p["rx"] as? NSNumber)?.doubleValue == 36.0, "rx = selection-bounds center")
        #expect((p["ry"] as? NSNumber)?.doubleValue == 36.0, "ry = selection-bounds center")
        #expect((p["scale_strokes"] as? NSNumber)?.boolValue == true)
        #expect((p["scale_corners"] as? NSNumber)?.boolValue == false)
        #expect(txn.ops[0].targets == ["rect-1"], "targets = pre-mutation selection id")
        #expect(transformedAt(model, [0, 0]), "the rect carries a transform after confirm")
        assertConfirmReplayEquivalent(model)
    }
    // (rotate) 30° around the bounds center.
    do {
        let model = transformProductionModel()
        runTransformAction(model, "rotate_options_confirm",
            ["angle": 30.0, "preview": false, "copy": false])
        let txn = model.journal.last!
        #expect(txn.ops.map { $0.op } == ["rotate_transform"], "one rotate_transform op")
        let p = txn.ops[0].params
        #expect((p["angle"] as? NSNumber)?.doubleValue == 30.0)
        #expect((p["rx"] as? NSNumber)?.doubleValue == 36.0)
        #expect((p["ry"] as? NSNumber)?.doubleValue == 36.0)
        #expect(txn.ops[0].targets == ["rect-1"])
        #expect(transformedAt(model, [0, 0]))
        assertConfirmReplayEquivalent(model)
    }
    // (shear) 20° horizontal around the bounds center.
    do {
        let model = transformProductionModel()
        runTransformAction(model, "shear_options_confirm",
            ["angle": 20.0, "axis": "horizontal", "axis_angle": 0.0,
             "preview": false, "copy": false])
        let txn = model.journal.last!
        #expect(txn.ops.map { $0.op } == ["shear_transform"], "one shear_transform op")
        let p = txn.ops[0].params
        #expect((p["angle"] as? NSNumber)?.doubleValue == 20.0)
        #expect(p["axis"] as? String == "horizontal")
        #expect((p["axis_angle"] as? NSNumber)?.doubleValue == 0.0)
        #expect((p["rx"] as? NSNumber)?.doubleValue == 36.0)
        #expect((p["ry"] as? NSNumber)?.doubleValue == 36.0)
        #expect(txn.ops[0].targets == ["rect-1"])
        #expect(transformedAt(model, [0, 0]))
        assertConfirmReplayEquivalent(model)
    }
}

/// Phase P7 — the copy=true composition. Drives the REAL confirm with copy=true
/// and asserts the transaction journals [copy_selection, scale_transform] (TWO
/// ops), the original is untouched, the copy carries the matrix, and
/// checkpoint_equivalence holds. Mirrors Rust
/// `production_transform_copy_journals_two_ops`.
@Test func productionTransformCopyJournalsTwoOps() {
    let model = transformProductionModel()
    runTransformAction(model, "scale_options_confirm", [
        "uniform": true, "uniform_pct": 200.0,
        "horizontal_pct": 100.0, "vertical_pct": 100.0,
        "scale_strokes": true, "scale_corners": false,
        "preview": false, "copy": true,
    ])
    let txn = model.journal.last!
    #expect(txn.ops.map { $0.op } == ["copy_selection", "scale_transform"],
        "copy=true journals [copy_selection, scale_transform] in ONE transaction")
    #expect(txn.ops[0].targets == ["rect-1"], "copy_selection.targets = pre-mutation source id")
    #expect(!transformedAt(model, [0, 0]), "the original is untouched by a copy-transform")
    #expect(transformedAt(model, [0, 1]), "the duplicate carries the composed matrix")
    assertConfirmReplayEquivalent(model)
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

@Test func testStateDefaults() {
    let json = stateDefaultsJson()
    assertWorkspaceFixture("state_defaults", json)
}

@Test func testShortcutStructure() {
    let json = shortcutStructureJson()
    assertWorkspaceFixture("shortcut_structure", json)
}

// MARK: - Workspace operation equivalence tests

/// Harness shim over the RUNTIME layout-op dispatcher (OP_LOG.md §12, Fork 5,
/// Increment 3d-2). The per-verb mutation bodies — once duplicated here — now
/// live in `layoutApply` (Sources/Workspace/LayoutApply.swift), which is the
/// SAME dispatcher the production layout-mutation sites route through. The
/// `workspace_operations/*.json` corpus replays through this shim, so harness
/// and production exercise ONE dispatcher (the layout analogue of how the
/// document corpus replays through op-apply). Kept as a thin wrapper so the
/// existing `runWorkspaceOperationFixture` call site reads unchanged.
private func applyWorkspaceOp(_ layout: inout WorkspaceLayout, _ op: [String: Any]) {
    layoutApply(&layout, op)
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

// MARK: - 3d-2 production-route tests (OP_LOG.md §12, Fork 5, Option B)
//
// These pin that the PRODUCTION layout-mutation sites route through the SAME
// runtime `layoutApply` dispatcher the harness corpus replays through, and
// that the dispatcher never crashes on malformed input.

/// Production-route pin: drive a real production layout path — the Layers panel
/// hamburger-menu `close_panel` command (`LayersPanel.dispatch`), the same
/// handler the live UI invokes — against a real `WorkspaceLayout`, and assert
/// (1) it produces the SAME layout (`workspaceToTestJson`) as feeding the
/// equivalent op straight to the runtime `layoutApply` dispatcher, proving the
/// production site routes through the one dispatcher; and (2) the dirty signal
/// still fired — `needsSave()` flips true, which is the `bump()` the save path
/// reads to persist. ZERO behavior change vs the pre-3d-2 direct
/// `layout.closePanel(addr)` call.
@Test func testLayoutProductionRouteClosePanel() {
    // A real default layout, marked clean so a post-dispatch `needsSave()`
    // proves the production handler's `bump()` (inside `closePanel`) fired.
    var layout = WorkspaceLayout.defaultLayout()
    layout.markSaved()
    #expect(!layout.needsSave(), "precondition: layout must start clean")

    // The Layers panel address in the default layout (dock 0, group 4, panel 1).
    func findLayers(_ l: WorkspaceLayout) -> PanelAddr? {
        for (_, dock) in l.anchored {
            for (gi, group) in dock.groups.enumerated() {
                if let pi = group.panels.firstIndex(of: .layers) {
                    return PanelAddr(group: GroupAddr(dockId: dock.id, groupIdx: gi), panelIdx: pi)
                }
            }
        }
        return nil
    }
    guard let addr = findLayers(layout) else {
        Issue.record("Layers panel must exist in the default layout")
        return
    }

    // Oracle: the same op fed straight to the runtime dispatcher.
    var oracle = WorkspaceLayout.defaultLayout()
    layoutApply(&oracle, opClosePanel(addr))
    let expected = workspaceToTestJson(oracle)

    // Production path: the Layers panel hamburger-menu dispatcher.
    LayersPanel.dispatch("close_panel", addr: addr, layout: &layout)

    let actual = workspaceToTestJson(layout)
    #expect(actual == expected,
        "production close_panel path diverged from the runtime layoutApply dispatcher")
    #expect(layout.needsSave(),
        "production close_panel must still bump the dirty signal (needsSave)")
}

/// No-panic pin: the runtime `layoutApply` dispatcher MUST tolerate malformed /
/// garbage ops without crashing — production input is never trusted. Missing
/// `op`, unknown verb, wrong-typed params, and missing required `kind` must all
/// SKIP. A well-formed op on a fresh layout must still mutate (sanity),
/// confirming the dispatcher ISN'T inert.
@Test func testLayoutApplyNoPanicOnMalformed() {
    var layout = WorkspaceLayout.defaultLayout()
    layout.ensurePaneLayout(viewportW: 1200, viewportH: 800)

    // None of these must crash; each is a no-op (skip).
    let malformed: [[String: Any]] = [
        [:],                                                       // no "op"
        ["op": 42],                                                // "op" not a string
        ["op": "totally_unknown_verb"],                           // unknown verb
        ["op": "show_panel"],                                     // missing required "kind"
        ["op": "show_panel", "kind": 7],                         // "kind" wrong type
        ["op": "hide_pane"],                                      // missing required "kind"
        ["op": "close_panel"],                                    // missing dock/group/panel
        ["op": "set_pane_position", "pane_id": "x"],             // garbage param
        ["op": "toggle_group_collapsed", "dock_id": -1],        // bad number
        ["op": "redock", "dock_id": "nope"],                    // garbage param
    ]
    for op in malformed {
        layoutApply(&layout, op) // must not crash
    }

    // A WELL-FORMED op must still mutate a fresh layout (dispatcher is live).
    var fresh = WorkspaceLayout.defaultLayout()
    let before = workspaceToTestJson(fresh)
    layoutApply(&fresh, ["op": "toggle_group_collapsed", "dock_id": 0, "group_idx": 0])
    let after = workspaceToTestJson(fresh)
    #expect(before != after, "a well-formed op must still mutate — dispatcher is live")
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

// MARK: - Expression-language conformance (shared corpus)

/// Loads the compiled corpus from test_fixtures/expressions/conformance.json
/// (generated from workspace/tests/expressions.yaml — the same corpus the
/// Python conformance test reads) and asserts this app's evaluator produces the
/// expected result type and value for every case. Pins cross-language
/// expression equivalence, including the closure lexical-scoping contract.
@Test func expressionConformance() throws {
    let raw = readFixture("expressions/conformance.json")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let data = raw.data(using: .utf8)!
    let cases = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

    var failures: [String] = []
    for tc in cases {
        let expr = tc["expr"] as! String
        // Build the eval context from the optional state/data namespaces.
        var ctx: [String: Any] = [:]
        if let s = tc["state"] { ctx["state"] = s }
        if let d = tc["data"] { ctx["data"] = d }

        let result = evaluate(expr, context: ctx)
        let ty = tc["type"] as! String
        let expected = tc["expected"]

        let ok: Bool
        switch ty {
        case "null":
            if case .null = result { ok = true } else { ok = false }
        case "bool":
            if case .bool(let b) = result { ok = b == (expected as! Bool) } else { ok = false }
        case "number":
            if case .number(let n) = result {
                ok = abs(n - (expected as! NSNumber).doubleValue) < 1e-9
            } else { ok = false }
        case "string":
            if case .string(let s) = result { ok = s == (expected as! String) } else { ok = false }
        case "color":
            if case .color(let c) = result { ok = c == (expected as! String) } else { ok = false }
        case "list":
            if case .list = result { ok = true } else { ok = false }
        default:
            Issue.record("Unknown expected type \(ty) for expr \(expr)")
            continue
        }
        if !ok {
            failures.append("  \(expr) -> expected \(ty) \(expected ?? "null"), got \(result)")
        }
    }
    #expect(failures.isEmpty,
        "expression conformance failures (\(failures.count) of \(cases.count)):\n\(failures.joined(separator: "\n"))")
}

// MARK: - Concept-generator conformance (shared corpus)

/// Loads test_fixtures/concepts/conformance.json (compiled from
/// workspace/concepts/*.yaml + workspace/tests/concepts.yaml). Evaluates each
/// concept's generator expression with its parameters bound under `param` and
/// asserts the resulting [x,y] points match the expected geometry (1e-9). A
/// generator is just an expression, so this reuses the evaluator. See CONCEPTS.md.
@Test func conceptConformance() throws {
    func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    let raw = readFixture("concepts/conformance.json")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let data = raw.data(using: .utf8)!
    let cases = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

    var failures: [String] = []
    for tc in cases {
        let concept = tc["concept"] as? String ?? "?"
        let generator = tc["generator"] as! String
        let params = tc["params"] as! [String: Any]

        let result = evaluate(generator, context: ["param": params])
        guard case .list(let items) = result else {
            failures.append("\(concept): generator returned non-list")
            continue
        }
        let expected = tc["expected"] as! [[Any]]
        if items.count != expected.count {
            failures.append("\(concept): point count — expected \(expected.count), got \(items.count)")
            continue
        }
        for (i, pair) in zip(items, expected).enumerated() {
            let (item, exp) = pair
            guard let coords = item.value as? [Any], coords.count == 2,
                  let px = num(coords[0]), let py = num(coords[1]) else {
                failures.append("\(concept) point \(i): not a 2-element numeric list")
                continue
            }
            guard let ex = num(exp[0]), let ey = num(exp[1]) else {
                failures.append("\(concept) point \(i): malformed expected")
                continue
            }
            if abs(px - ex) >= 1e-9 || abs(py - ey) >= 1e-9 {
                failures.append("\(concept) point \(i): expected (\(ex), \(ey)), got (\(px), \(py))")
            }
        }
    }
    #expect(failures.isEmpty,
        "concept conformance failures:\n\(failures.joined(separator: "\n"))")
}

// MARK: - Concept-fitter conformance (shared corpus)

/// Loads test_fixtures/concept_fitters/conformance.json (compiled from
/// workspace/concepts/*.yaml + workspace/tests/concept_fitters.yaml). For each
/// case, evaluates the concept's `fitter` expression with the case's points
/// bound under `shape.points` and asserts the result matches `expected` — `null`
/// for no match, else the flat `[params..., cx, cy, rotation]` list (1e-9). A
/// fitter is the dual of the generator and just an expression, so this reuses
/// the evaluator — pinning concept DETECTION across all apps (CONCEPTS.md §10).
/// The production promote handler runs exactly this and bakes the recovered
/// values into the op. Mirrors Rust `fitters_conformance`.
@Test func fittersConformance() throws {
    func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    let raw = readFixture("concept_fitters/conformance.json")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let data = raw.data(using: .utf8)!
    let cases = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

    var failures: [String] = []
    for tc in cases {
        let concept = tc["concept"] as? String ?? "?"
        let fitter = tc["fitter"] as! String
        // Bind the input vertices under `shape.points`, exactly as the production
        // promote handler does at detect time.
        let ctx: [String: Any] = ["shape": ["points": tc["points"] as! [Any]]]
        let result = evaluate(fitter, context: ctx)

        // A `null` expected ⇒ no match: the fitter must evaluate to `.null`. JSON
        // null decodes to NSNull, so distinguish it from the list form.
        let expected = tc["expected"]
        if expected == nil || expected is NSNull {
            if case .null = result {} else {
                failures.append("\(concept): expected no match (null), got \(result)")
            }
            continue
        }
        guard case .list(let items) = result else {
            failures.append("\(concept): expected a list, got non-list \(result)")
            continue
        }
        let exp = expected as! [Any]
        if items.count != exp.count {
            failures.append("\(concept): result arity \(items.count) != expected \(exp.count)")
            continue
        }
        for (i, pair) in zip(items, exp).enumerated() {
            let (item, e) = pair
            guard let got = num(item.value) else {
                failures.append("\(concept) output[\(i)]: non-numeric \(item.value)")
                continue
            }
            guard let want = num(e) else {
                failures.append("\(concept) output[\(i)]: malformed expected \(e)")
                continue
            }
            if abs(got - want) >= 1e-9 {
                failures.append("\(concept) output[\(i)]: expected \(want), got \(got)")
            }
        }
    }
    #expect(failures.isEmpty,
        "concept-fitter conformance failures:\n\(failures.joined(separator: "\n"))")
}

/// CONCEPTS.md §10 — the generator and fitter are inverses (the round-trip
/// property). Generate a `regular_polygon`'s vertices, feed them back through the
/// SAME concept's fitter, and assert it recovers `[sides, radius, 0, 0, 0]`
/// (canonical placement: origin-centred, first vertex on +x ⇒ rotation 0). Both
/// expressions are read from the compiled registry, so this pins that a concept's
/// two halves agree. Mirrors Rust `generator_fitter_round_trip`.
@Test func generatorFitterRoundTrip() throws {
    func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    let ws = WorkspaceData.load()
    let concept = ws?.concept("regular_polygon")
    let generator = concept?["generator"] as! String
    let fitter = concept?["fitter"] as! String

    for (sides, radius) in [(6.0, 50.0), (4.0, 10.0), (5.0, 25.0)] {
        // Generate the canonical points.
        let gres = evaluate(generator, context: ["param": ["sides": sides, "radius": radius]])
        guard case .list(let gitems) = gres else {
            Issue.record("generator returned non-list for sides=\(sides)"); continue
        }
        let pts: [[Double]] = gitems.compactMap { item in
            guard let coords = item.value as? [Any], coords.count == 2,
                  let x = num(coords[0]), let y = num(coords[1]) else { return nil }
            return [x, y]
        }
        // Fit them back.
        let fres = evaluate(fitter, context: ["shape": ["points": pts]])
        guard case .list(let fitems) = fres else {
            Issue.record("fitter returned non-list for sides=\(sides)"); continue
        }
        let nums = fitems.map { num($0.value) ?? Double.nan }
        let expected = [sides, radius, 0.0, 0.0, 0.0]
        #expect(nums.count == expected.count, "fitter arity for sides=\(sides)")
        if nums.count == expected.count {
            for (i, (g, e)) in zip(nums, expected).enumerated() {
                #expect(abs(g - e) < 1e-9,
                        "round-trip sides=\(sides) radius=\(radius) output[\(i)]: expected \(e), got \(g)")
            }
        }
    }
}

// MARK: - Concept-operation conformance (shared corpus)

/// Loads test_fixtures/concept_operations/conformance.json (compiled from
/// workspace/concepts/*.yaml + workspace/tests/concept_operations.yaml). For each
/// case, evaluates the operation's `set:` expressions with the case's params
/// bound under `param` and asserts the resolved value of each changed param
/// matches the expected change (1e-9). An operation's effect is just expression
/// evaluation, so this reuses the evaluator — pinning concept-operation
/// RESOLUTION across all apps (CONCEPTS.md §9). The production handler bakes
/// exactly these resolved `changes` into the op (value-in-op), so the gate also
/// pins what gets journaled. Mirrors Rust `operations_conformance`.
@Test func operationsConformance() throws {
    let raw = readFixture("concept_operations/conformance.json")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let data = raw.data(using: .utf8)!
    let cases = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

    func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    var failures: [String] = []
    for tc in cases {
        let concept = tc["concept"] as? String ?? "?"
        let op = tc["op"] as? String ?? "?"
        // Bind the current params under the `param` namespace (the generator's
        // namespace), exactly as the production handler does at resolve time.
        let params = tc["params"] as! [String: Any]
        let ctx: [String: Any] = ["param": params]

        let set = tc["set"] as! [String: Any]
        let expected = tc["expected"] as! [String: Any]
        for (name, exprAny) in set {
            let src = exprAny as! String
            let result = evaluate(src, context: ctx)
            guard case .number(let got) = result else {
                failures.append("\(concept)/\(op) param \(name): non-numeric result \(result)")
                continue
            }
            guard let want = num(expected[name]) else {
                failures.append("\(concept)/\(op): expected has no \(name)")
                continue
            }
            if abs(got - want) >= 1e-9 {
                failures.append("\(concept)/\(op) param \(name): expected \(want), got \(got)")
            }
        }
    }
    #expect(failures.isEmpty,
        "concept-operation conformance failures:\n\(failures.joined(separator: "\n"))")
}

// MARK: - Concept-constraint conformance (shared corpus)

/// Loads test_fixtures/concept_constraints/conformance.json (compiled from
/// workspace/concepts/*.yaml + workspace/tests/concept_constraints.yaml). For each
/// case, evaluates each constraint's `check` expression with the case's params
/// bound under `param` and collects the constraints whose result is NOT truthy
/// (`Value.toBool`, the same truthiness `if` uses) — the violations, in declared
/// order — then asserts they match `expected`. A constraint is just a boolean
/// expression, so this reuses the evaluator — pinning concept CHECKING across all
/// apps (CONCEPTS.md §11). Checking is advisory + read-only (no op-log verb).
/// Mirrors Rust `constraints_conformance`.
@Test func constraintsConformance() throws {
    let raw = readFixture("concept_constraints/conformance.json")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let data = raw.data(using: .utf8)!
    let cases = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

    var failures: [String] = []
    for tc in cases {
        let concept = tc["concept"] as? String ?? "?"
        // Bind the current params under the `param` namespace, exactly as the
        // checker does at view-build time.
        let params = tc["params"] as! [String: Any]
        let ctx: [String: Any] = ["param": params]

        let constraints = tc["constraints"] as! [[String: Any]]
        let violated: [String] = constraints.compactMap { c in
            let check = c["check"] as! String
            return evaluate(check, context: ctx).toBool() ? nil : (c["id"] as? String ?? "?")
        }
        let expected: [String] = (tc["expected"] as! [Any]).map { $0 as? String ?? "?" }
        if violated != expected {
            failures.append("\(concept): expected violations \(expected), got \(violated)")
        }
    }
    #expect(failures.isEmpty,
        "concept-constraint conformance failures:\n\(failures.joined(separator: "\n"))")
}

// MARK: - Concept registry (increment 3a)

/// The concept packs are bundled into workspace.json and loadable via
/// WorkspaceData. Registry -> evaluator round-trip confirms the bundled
/// generator yields geometry. See CONCEPTS.md §6/§7.
@Test func conceptRegistry() throws {
    guard let ws = WorkspaceData.load() else {
        Issue.record("workspace failed to load")
        return
    }
    let gear = ws.concept("gear")
    #expect(gear != nil)
    #expect((gear?["closed"] as? Bool) == true)
    #expect(((gear?["generator"] as? String) ?? "").contains("mod("))
    #expect(ws.concept("no_such_concept") == nil)

    guard let poly = ws.concept("regular_polygon"),
          let generator = poly["generator"] as? String else {
        Issue.record("regular_polygon not registered")
        return
    }
    let result = evaluate(generator, context: ["param": ["sides": 4, "radius": 10]])
    guard case .list(let items) = result else {
        Issue.record("generator did not return a list")
        return
    }
    #expect(items.count == 4)
}

// MARK: - Generated live element (concept instance, CONCEPTS.md 3b)

@Test func generatedLiveVariantRoundTripsAndSerializes() throws {
    let ge = GeneratedElem(
        conceptId: "regular_polygon",
        params: ["sides": 6, "radius": 50],
        id: "poly1")
    let layer = Layer(name: "Layer", children: [.live(.generated(ge))])
    let doc = Document(layers: [layer], artboards: [])

    let json = documentToTestJson(doc)
    #expect(json.contains("\"kind\":\"generated\""))
    #expect(json.contains("\"concept\":\"regular_polygon\""))
    #expect(json.contains("\"params\""))

    // test_json round-trip (parse → emit byte-identical).
    let back = testJsonToDocument(json)
    #expect(documentToTestJson(back) == json)

    // binary round-trip.
    let bytes = documentToBinary(doc, compress: false)
    let backBin = try binaryToDocument(bytes)
    #expect(documentToTestJson(backBin) == json)
}

@Test func generatedEvaluatesViaConceptResolver() {
    struct OneConcept: ElementResolver {
        func resolve(_ id: ElementRef) -> Element? { nil }
        func resolveConcept(_ conceptId: String) -> ConceptDef? {
            conceptId == "regular_polygon"
                ? ConceptDef(generator: "map(range(0, param.sides), fun i -> "
                    + "let a = 360 * i / param.sides in "
                    + "[param.radius * cos(a), param.radius * sin(a)])", closed: true)
                : nil
        }
    }
    let ge = GeneratedElem(conceptId: "regular_polygon", params: ["sides": 4, "radius": 10])
    var visiting = VisitSet()
    let ps = ge.evaluateWith(precision: 1.0, resolver: OneConcept(), visiting: &visiting)
    #expect(ps.count == 1)
    #expect(ps.first?.count == 4)
    if let p0 = ps.first?.first {
        #expect(abs(p0.0 - 10.0) < 1e-9 && abs(p0.1) < 1e-9)
    }
    var v2 = VisitSet()
    #expect(ge.evaluateWith(precision: 1.0, resolver: NullResolver(), visiting: &v2).isEmpty)
}

// MARK: - Concept render wiring (CONCEPTS.md 3b)

/// The production render resolver resolves concept packs from the bundled
/// workspace registry, so a placed Generated instance evaluates its concept's
/// geometry on the canvas render path. Mirrors the Rust render-wiring test.
@Test func renderResolverResolvesConcepts() {
    let resolver = RebuildResolver(document: Document())
    let def = resolver.resolveConcept("regular_polygon")
    #expect(def != nil)
    #expect((def?.generator.contains("cos(")) == true)
    #expect(resolver.resolveConcept("no_such_concept") == nil)

    let ge = GeneratedElem(conceptId: "regular_polygon",
                           params: ["sides": 4, "radius": 10])
    var visiting = VisitSet()
    let ps = ge.evaluateWith(precision: 1.0, resolver: resolver, visiting: &visiting)
    #expect(ps.count == 1)
    #expect(ps.first?.count == 4)
}

// MARK: - Gesture equivalence corpus (CROSS_LANGUAGE_TESTING.md §3a)
//
// Mirrors the OPERATION corpus above, but drives the CanvasTool seam — raw
// pointer events through a YamlTool — instead of opApply. A gesture fixture
// replays a sequence of pointer events against a tool built from the workspace
// spec and serializes the resulting document, asserting BYTE-EQUAL to the
// Rust-authored golden.
//
// Identity-view convention: the Model is loaded with the default (identity)
// view (zoomLevel == 1.0, viewOffsetX/Y == 0.0), so the event x/y ARE document
// coordinates (pointerPayload computes doc_x == x in that case). shift/alt
// default to false; `dragging` defaults to false on move events.
//
// Self-bracketing: each tool that mutates the document does its own
// doc.snapshot (e.g. rect.yaml's on_mouseup), so the gesture runner does NOT
// wrap events in beginTxn/commitTxn — unlike the operation runner, which owns
// the transaction bracket. Mirrors Rust's run_gesture_model / assert_gesture_test.

/// The list of gesture fixture files under `test_fixtures/gestures/`.
/// Inc-1 was just the rectangle-draw gesture; inc-2 adds the five additional
/// draw tools (line, ellipse, rounded_rect, polygon, star), each replaying the
/// same press(10,20)->drag(110,70)->release(110,70) gesture as draw_rect.
private let gestureFixtures = [
    "draw_rect.json",
    "draw_line.json",
    "draw_ellipse.json",
    "draw_rounded_rect.json",
    "draw_polygon.json",
    "draw_star.json",
    // Selection-family (§5 rec 4): click-select drives the selection tool's
    // doc-space hit_test (which element is under the point) — the cross-app
    // hit-test parity gate. Click center of rect0 -> path [0,0].
    "select_click.json",
]

/// Build a minimal ToolContext for replaying gestures: a YamlTool reads only
/// `ctx.model` and `ctx.requestUpdate` on the pointer path, so the hit-test
/// closures and overlay hook are inert stubs. Mirrors the makeCtx helper used
/// across the tool tests.
private func gestureToolContext(_ model: Model) -> ToolContext {
    ToolContext(
        model: model,
        controller: Controller(model: model),
        hitTestSelection: { _ in false },
        hitTestHandle: { _ in nil },
        hitTestText: { _ in nil },
        hitTestPathCurve: { _, _ in nil },
        requestUpdate: {},
        drawElementOverlay: { _, _, _ in }
    )
}

/// Run a gesture fixture and return the resulting Model. Loads the setup SVG
/// into a Model under the default identity view, builds the tool from the
/// workspace spec (the same `loadYamlTool` path the running app uses), activates
/// it, then dispatches each event through the CanvasTool seam (onPress / onMove /
/// onRelease). Mirrors Rust `run_gesture_model`.
private func runGestureModel(_ tc: [String: Any]) -> Model {
    let setupSvg = readFixture("svg/\(tc["setup_svg"] as! String)")
    let model = Model(document: svgToDocument(setupSvg))

    let toolId = tc["tool"] as! String
    guard let ws = WorkspaceData.load() else {
        fatalError("workspace.json failed to load")
    }
    guard let tool = loadYamlTool(toolId, in: ws) else {
        fatalError("workspace declares no tool '\(toolId)' (or it failed to parse)")
    }

    let ctx = gestureToolContext(model)
    tool.activate(ctx)

    for ev in tc["events"] as! [[String: Any]] {
        let x = (ev["x"] as! NSNumber).doubleValue
        let y = (ev["y"] as! NSNumber).doubleValue
        // shift/alt default false; dragging defaults false on move.
        let shift = (ev["shift"] as? Bool) ?? false
        let alt = (ev["alt"] as? Bool) ?? false
        switch ev["kind"] as! String {
        case "press":
            tool.onPress(ctx, x: x, y: y, shift: shift, alt: alt)
        case "move":
            let dragging = (ev["dragging"] as? Bool) ?? false
            tool.onMove(ctx, x: x, y: y, shift: shift, dragging: dragging)
        case "release":
            tool.onRelease(ctx, x: x, y: y, shift: shift, alt: alt)
        default:
            Issue.record("unknown gesture event kind: \(ev["kind"] ?? "nil")")
        }
    }
    return model
}

/// Mirror of `assertOperationTest`: replay the gesture and compare the canonical
/// document JSON against the pinned golden, dumping EXPECTED/ACTUAL on mismatch.
/// Mirrors Rust `assert_gesture_test`.
private func assertGestureTest(_ tc: [String: Any]) {
    let name = tc["name"] as! String
    let expectedFile = tc["expected_json"] as! String
    let expected = readFixture("gestures/\(expectedFile)")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let actual = documentToTestJson(runGestureModel(tc).document)

    if actual != expected {
        print("=== EXPECTED (\(name)) ===")
        print(expected)
        print("=== ACTUAL (\(name)) ===")
        print(actual)
    }
    #expect(actual == expected, "Gesture test '\(name)' failed: canonical JSON mismatch")
}

/// Inc-1 of the shared gesture-fixture corpus: replay each fixture's pointer
/// events through this app's CanvasTool seam and assert the resulting document
/// serializes byte-identically to the Rust-authored golden.
@Test func gestureCorpus() throws {
    for fixture in gestureFixtures {
        let json = readFixture("gestures/\(fixture)")
        let data = json.data(using: .utf8)!
        let tests = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        for tc in tests {
            assertGestureTest(tc)
        }
    }
}

// MARK: - Action equivalence corpus (CROSS_LANGUAGE_TESTING.md §3b)
//
// Sibling to the GESTURE corpus above and the OPERATION corpus. Where the
// gesture corpus drives the CanvasTool seam (press / move / release) and the
// operation corpus drives opApply, this corpus drives the ACTION seam: the
// panel/menu/dialog `action` verbs the UI dispatches, which RESOLVE to
// ops/effects.
//
// Production seam: `LayersPanel.dispatchYamlAction(action, model:, params:)`
// (Sources/Panels/LayersPanel.swift) — the generic action dispatcher the live
// UI menu invokes for the layers-panel verbs (it is what
// `LayersPanel.dispatch("toggle_all_layers_visibility", …)` routes to). It
// loads the action's `effects` from the bundle, builds the `active_document`
// eval context (the `top_level_layers` / `top_level_layer_paths` rollups the
// effects read), and runs the effects through the SHARED `runEffects` pipeline,
// threading the action verb as the transaction name (OP_LOG.md §9). We drive
// THAT path, not a test-only shortcut, so passing here proves the real
// production route — the Swift analogue of Rust's generic `dispatch_action`.
//
// Fixture format (test_fixtures/actions/<name>.json) — a JSON array of cases,
// each:
//   {
//     "name":        "<case id>",
//     "setup_svg":   "<file under test_fixtures/svg/>",
//     "actions":     [ {"action": "<action_id>", "params": { <literals> }}, … ],
//     "expected_json": "<file under test_fixtures/actions/>"
//   }
// Each entry in `actions` is dispatched in order through the production
// dispatcher with its resolved params. The final document is serialized with
// `documentToTestJson` and compared to the pinned golden — identical to the
// gesture corpus's assertion shape.
//
// SELECTION SETUP: an action that operates on the selection expresses it as a
// LEADING `select_*` action in the same `actions` list — a verb the UI itself
// dispatches — so setup stays on the production dispatch path and inside the
// journaled-state model (selection is serialized Document state, OP_LOG.md §7).
// The first seeded case (`toggle_all_layers_visibility`) needs NO selection: it
// folds over ALL top-level layers, so its `actions` list is one verb with empty
// params.
//
// TRANSACTION BRACKETING: actions self-bracket. A document-mutating action
// opens its undo transaction via the `snapshot` effect and the `runEffects`
// owner commits it once at the end (naming it with the action verb). So —
// exactly like the gesture runner, and UNLIKE the operation runner which owns
// the bracket — the action runner does NOT wrap dispatch in beginTxn/commitTxn.
// Mirrors Rust's run_action_model / assert_action_test.

/// The list of action fixture files under `test_fixtures/actions/`.
/// Inc-2 mirrors the Rust ACTION_FIXTURES foundation: the layers-panel
/// "toggle all layers visibility" verb (the simplest faithful document-
/// affecting action), driven through this app's production action dispatcher.
private let actionFixtures = [
    "toggle_all_layers_visibility.json",
]

/// Build a Model whose document is parsed from `setupSvg`. Mirrors Rust
/// `action_state_from_svg` (loads the tree from a shared SVG fixture instead of
/// constructing layers inline) and the gesture runner's identity-view setup.
private func actionModelFromSvg(_ setupSvg: String) -> Model {
    let svg = readFixture("svg/\(setupSvg)")
    return Model(document: svgToDocument(svg))
}

/// Run an action fixture and return the resulting Model. Loads the setup SVG,
/// then dispatches each `actions[i]` through the REAL
/// `LayersPanel.dispatchYamlAction` (the same generic dispatcher the UI menu
/// invokes), passing the case's resolved params. Mirrors Rust `run_action_model`
/// — state is reachable on the returned Model for cases that need it.
private func runActionModel(_ tc: [String: Any]) -> Model {
    let setupSvg = tc["setup_svg"] as! String
    let model = actionModelFromSvg(setupSvg)

    for step in tc["actions"] as! [[String: Any]] {
        let action = step["action"] as! String
        // Params are an object of resolved literals (mirrors the production-route
        // transform tests). Default to empty.
        let params = (step["params"] as? [String: Any]) ?? [:]
        LayersPanel.dispatchYamlAction(action, model: model, params: params)
    }
    return model
}

/// Mirror of `assertGestureTest`: replay the action sequence and compare the
/// canonical document JSON against the pinned golden, dumping EXPECTED/ACTUAL on
/// mismatch. Mirrors Rust `assert_action_test`.
private func assertActionTest(_ tc: [String: Any]) {
    let name = tc["name"] as! String
    let expectedFile = tc["expected_json"] as! String
    let expected = readFixture("actions/\(expectedFile)")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let actual = documentToTestJson(runActionModel(tc).document)

    if actual != expected {
        print("=== EXPECTED (\(name)) ===")
        print(expected)
        print("=== ACTUAL (\(name)) ===")
        print(actual)
    }
    #expect(actual == expected, "Action test '\(name)' failed: canonical JSON mismatch")
}

/// Inc-2 of the shared action-fixture corpus: replay each fixture's action
/// sequence through this app's production action-dispatch seam and assert the
/// resulting document serializes byte-identically to the Rust-authored golden.
@Test func actionCorpus() throws {
    for fixture in actionFixtures {
        let json = readFixture("actions/\(fixture)")
        let data = json.data(using: .utf8)!
        let tests = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        for tc in tests {
            assertActionTest(tc)
        }
    }
}
