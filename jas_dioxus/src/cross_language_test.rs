//! Cross-language equivalence tests.
//!
//! These tests read shared fixtures from `test_fixtures/` at the
//! repository root.  All four language implementations run the same
//! fixtures, so passing here means the Rust implementation agrees with
//! the canonical expected values.

#[cfg(test)]
mod tests {
    use crate::algorithms::hit_test;
    use crate::document::model::Model;
    use crate::geometry::binary::{document_to_binary, binary_to_document};
    use crate::geometry::svg::{document_to_svg, svg_to_document};
    use crate::geometry::test_json::{document_to_test_json, test_json_to_document};

    /// Path to the shared test fixtures directory, relative to the Rust
    /// crate root (`jas_dioxus/`).
    const FIXTURES: &str = "../test_fixtures";

    /// Read a fixture file and return its contents.
    fn read_fixture(path: &str) -> String {
        let full = format!("{}/{}", FIXTURES, path);
        std::fs::read_to_string(&full)
            .unwrap_or_else(|e| panic!("Failed to read fixture {}: {}", full, e))
    }

    /// Run a single SVG parse-equivalence test:
    /// 1. Read the SVG file.
    /// 2. Parse it into a Document.
    /// 3. Serialize to canonical test JSON.
    /// 4. Compare against the expected JSON file.
    fn assert_svg_parse(name: &str) {
        let svg = read_fixture(&format!("svg/{}.svg", name));
        let expected = read_fixture(&format!("expected/{}.json", name));
        let expected = expected.trim();

        let doc = svg_to_document(&svg);
        let actual = document_to_test_json(&doc);

        if actual != expected {
            // Show a useful diff on failure.
            eprintln!("=== EXPECTED ({}) ===", name);
            eprintln!("{}", expected);
            eprintln!("=== ACTUAL ({}) ===", name);
            eprintln!("{}", actual);
            panic!(
                "Cross-language test '{}' failed: canonical JSON mismatch",
                name
            );
        }
    }

    // ---------------------------------------------------------------
    // SVG round-trip idempotence: parse → serialize → parse
    // should produce the same canonical JSON.
    // ---------------------------------------------------------------

    fn assert_svg_roundtrip(name: &str) {
        let svg = read_fixture(&format!("svg/{}.svg", name));
        let doc1 = svg_to_document(&svg);
        let json1 = document_to_test_json(&doc1);

        let svg2 = document_to_svg(&doc1);
        let doc2 = svg_to_document(&svg2);
        let json2 = document_to_test_json(&doc2);

        if json1 != json2 {
            eprintln!("=== FIRST PARSE ({}) ===", name);
            eprintln!("{}", json1);
            eprintln!("=== AFTER ROUND-TRIP ({}) ===", name);
            eprintln!("{}", json2);
            panic!("SVG round-trip '{}' failed: canonical JSON changed after serialize→parse", name);
        }
    }

    // ---------------------------------------------------------------
    // Canonical JSON round-trip: parse JSON → Document → JSON
    // ---------------------------------------------------------------

    #[test]
    fn json_roundtrip_all_expected() {
        let names = [
            "line_basic", "rect_basic", "rect_with_stroke",
            "circle_basic", "ellipse_basic",
            "polyline_basic", "polygon_basic", "path_all_commands",
            "text_basic", "text_path_basic",
            "group_nested", "transform_translate", "transform_rotate",
            "multi_layer", "complex_document",
            // Stable identity: elements carrying an `id` must survive the
            // test_json parse->serialize round-trip identically in all apps.
            "element_ids",
            // Live elements: reference + compound round-trip through test_json
            // (REFERENCE_GRAPH.md Phase 1a). Compound now carries `operation`.
            "live_reference_roundtrip", "live_compound_roundtrip",
            // A compound shape carrying its own stable id.
            "live_compound_id",
            // Symbols P1: the `symbols` array (a master) + the instance in
            // layers round-trips through test_json (SYMBOLS.md §10).
            "symbols_basic",
            // Symbols P4: a reference whose instance `transform` field is set
            // (the `instance_transform` key) round-trips through test_json
            // distinct from common.transform (SYMBOLS.md §4 / Fork F2).
            "reference_instance_transform",
        ];
        for name in &names {
            let json1 = read_fixture(&format!("expected/{}.json", name));
            let json1 = json1.trim();
            let doc = test_json_to_document(json1);
            let json2 = document_to_test_json(&doc);
            assert_eq!(json1, json2,
                "JSON round-trip '{}' failed: parse→serialize changed the canonical JSON", name);
        }
    }

    // ---------------------------------------------------------------
    // Binary round-trip: JSON → Document → binary → Document → JSON
    // ---------------------------------------------------------------

    #[test]
    fn binary_roundtrip_all_expected() {
        let names = [
            "line_basic", "rect_basic", "rect_with_stroke",
            "circle_basic", "ellipse_basic",
            "polyline_basic", "polygon_basic", "path_all_commands",
            "text_basic", "text_path_basic",
            "text_with_tspans", "text_path_with_tspans",
            "group_nested", "transform_translate", "transform_rotate",
            "multi_layer", "complex_document",
            // Stable identity (binary v2): id+name round-trip generically.
            "element_ids",
            // Live elements round-trip through binary (Phase 2b): reference +
            // compound (TAG_LIVE, kind-discriminated).
            "live_reference_roundtrip", "live_compound_roundtrip",
            // A compound shape carrying its own stable id.
            "live_compound_id",
            // Symbols P1: the master store rides the trailing element array in
            // the binary document (SYMBOLS.md §5); JSON-compare round-trip.
            "symbols_basic",
            // Symbols P4: the instance transform packs at TAG_LIVE slot 9 and
            // round-trips through binary distinct from common.transform
            // (SYMBOLS.md §4 / Fork F2).
            "reference_instance_transform",
        ];
        for name in &names {
            let json1 = read_fixture(&format!("expected/{}.json", name));
            let json1 = json1.trim();
            let doc = test_json_to_document(json1);
            let binary = document_to_binary(&doc, true);
            let doc2 = binary_to_document(&binary)
                .unwrap_or_else(|e| panic!("binary decode failed for '{}': {}", name, e));
            let json2 = document_to_test_json(&doc2);
            assert_eq!(json1, json2,
                "Binary round-trip '{}' failed: canonical JSON changed", name);
        }
    }

    /// Verify Rust can read the binary fixtures generated by Python.
    #[test]
    fn binary_read_python_fixtures() {
        let names = [
            "line_basic", "rect_basic", "rect_with_stroke",
            "circle_basic", "ellipse_basic",
            "polyline_basic", "polygon_basic", "path_all_commands",
            "text_basic", "text_path_basic",
            "group_nested", "transform_translate", "transform_rotate",
            "multi_layer", "complex_document",
            // Stable identity (binary v2): id+name round-trip generically.
            "element_ids",
            // Live elements (Phase 2b): decode the Python-generated TAG_LIVE
            // bytes for reference + compound (cross-app byte pin).
            "live_reference_roundtrip", "live_compound_roundtrip",
            // A compound shape carrying its own stable id.
            "live_compound_id",
            // Symbols: a master in doc.symbols + an instance referencing it.
            "symbols_basic",
            // A reference carrying a non-identity instance transform (scale 2x).
            "reference_instance_transform",
        ];
        for name in &names {
            let bin_path = format!("{}/expected/{}.bin", FIXTURES, name);
            let bin_data = std::fs::read(&bin_path)
                .unwrap_or_else(|e| panic!("Failed to read {}: {}", bin_path, e));
            let doc = binary_to_document(&bin_data)
                .unwrap_or_else(|e| panic!("binary decode failed for '{}': {}", name, e));
            let actual = document_to_test_json(&doc);
            let expected = read_fixture(&format!("expected/{}.json", name));
            let expected = expected.trim();
            assert_eq!(actual, expected,
                "Python binary fixture '{}' did not produce expected JSON", name);
        }
    }

    /// Bootstrap helper: regenerate expected JSON for parse-equivalence
    /// fixtures after the canonical JSON schema changes (e.g., the tspan
    /// migration). Reads each SVG, emits canonical JSON, and writes it
    /// back to expected/{name}.json. Run with:
    ///   cargo test regenerate_parse_expected -- --nocapture --ignored
    #[test]
    #[ignore]
    fn regenerate_parse_expected() {
        let names = [
            "line_basic", "rect_basic", "rect_with_stroke",
            "circle_basic", "ellipse_basic",
            "polyline_basic", "polygon_basic", "path_all_commands",
            "text_basic", "text_path_basic",
            "group_nested", "transform_translate", "transform_rotate",
            "multi_layer", "complex_document",
            "text_with_tspans", "text_xml_space_preserve", "text_path_with_tspans",
            // Import normalization: duplicate ids collapse to first-pre-order-wins.
            "dup_id_import",
            // A compound shape carrying its own stable id (round-trips through
            // all three codecs; id is the only common field SVG preserves for
            // live elements — name is intentionally excluded).
            "live_compound_id",
            // Symbols P1 (SYMBOLS.md §10): a <defs> master (m1) + an instance
            // (<use> -> i1) parses to the canonical `symbols` array + the
            // layer's reference. Rust is the canonical generator.
            "symbols_basic",
            // Symbols P4 (SYMBOLS.md §4 / Fork F2): a <use> carrying
            // data-jas-instance-transform parses to a reference whose instance
            // `transform` field (emitted as `instance_transform`) is set,
            // distinct from common.transform.
            "reference_instance_transform",
        ];
        for name in &names {
            let svg = read_fixture(&format!("svg/{}.svg", name));
            let doc = svg_to_document(&svg);
            let actual = document_to_test_json(&doc);
            let path = format!("{}/expected/{}.json", FIXTURES, name);
            std::fs::write(&path, &actual)
                .unwrap_or_else(|e| panic!("Failed to write {}: {}", path, e));
            eprintln!("Regenerated: expected/{}.json", name);
        }
    }

    #[test]
    fn svg_roundtrip_all_fixtures() {
        let names = [
            "line_basic", "rect_basic", "rect_with_stroke",
            "circle_basic", "ellipse_basic",
            "polyline_basic", "polygon_basic", "path_all_commands",
            "text_basic", "text_path_basic",
            "group_nested", "transform_translate", "transform_rotate",
            "multi_layer", "complex_document",
            "text_with_tspans", "text_xml_space_preserve", "text_path_with_tspans",
            // Live elements round-trip through SVG (Phase 2a): reference as
            // <use href>, compound as <g data-jas-live ...data-jas-operation>.
            "live_reference", "live_compound",
            // A compound shape carrying its own stable id (SVG preserves the
            // compound's id attribute through the round-trip).
            "live_compound_id",
            // Symbols P1: <defs> master + <use> instance round-trips through
            // SVG (SYMBOLS.md §5 / Fork S3) — defs masters import to symbols,
            // not layers, and re-export identically.
            "symbols_basic",
            // Symbols P4: the instance transform rides
            // data-jas-instance-transform on the <use> and round-trips through
            // SVG distinct from common.transform.
            "reference_instance_transform",
        ];
        for name in &names {
            assert_svg_roundtrip(name);
        }
    }

    #[test]
    fn svg_parse_reference_instance_transform() {
        // <use href="#r1" id="i1" data-jas-instance-transform="matrix(2,0,0,2,0,0)">
        // imports as a reference whose instance `transform` field is scale(2,2)
        // (emitted as `instance_transform`), while common.transform stays null
        // (SYMBOLS.md §4 / Fork F2 — the two transforms are independent).
        assert_svg_parse("reference_instance_transform");
    }

    #[test]
    fn svg_parse_symbols_basic() {
        // The <defs> master (id="m1") imports into doc.symbols (NOT layers);
        // the <use href="#m1" id="i1"> imports as a live reference in the
        // layer. The canonical JSON shows the `symbols` array + the instance.
        // All apps parse it to the identical canonical JSON (SYMBOLS.md §10).
        assert_svg_parse("symbols_basic");
    }

    #[test]
    fn svg_parse_text_with_tspans() {
        assert_svg_parse("text_with_tspans");
    }

    #[test]
    fn svg_parse_text_xml_space_preserve() {
        assert_svg_parse("text_xml_space_preserve");
    }

    #[test]
    fn svg_parse_text_path_with_tspans() {
        assert_svg_parse("text_path_with_tspans");
    }

    #[test]
    fn svg_parse_line_basic() {
        assert_svg_parse("line_basic");
    }

    #[test]
    fn svg_parse_rect_basic() {
        assert_svg_parse("rect_basic");
    }

    #[test]
    fn svg_parse_rect_with_stroke() {
        assert_svg_parse("rect_with_stroke");
    }

    #[test]
    fn svg_parse_circle_basic() {
        assert_svg_parse("circle_basic");
    }

    #[test]
    fn svg_parse_ellipse_basic() {
        assert_svg_parse("ellipse_basic");
    }

    #[test]
    fn svg_parse_polyline_basic() {
        assert_svg_parse("polyline_basic");
    }

    #[test]
    fn svg_parse_polygon_basic() {
        assert_svg_parse("polygon_basic");
    }

    #[test]
    fn svg_parse_path_all_commands() {
        assert_svg_parse("path_all_commands");
    }

    #[test]
    fn svg_parse_text_basic() {
        assert_svg_parse("text_basic");
    }

    #[test]
    fn svg_parse_text_path_basic() {
        assert_svg_parse("text_path_basic");
    }

    #[test]
    fn svg_parse_group_nested() {
        assert_svg_parse("group_nested");
    }

    #[test]
    fn svg_parse_transform_translate() {
        assert_svg_parse("transform_translate");
    }

    #[test]
    fn svg_parse_transform_rotate() {
        assert_svg_parse("transform_rotate");
    }

    #[test]
    fn svg_parse_multi_layer() {
        assert_svg_parse("multi_layer");
    }

    #[test]
    fn svg_parse_complex_document() {
        assert_svg_parse("complex_document");
    }

    #[test]
    fn svg_parse_dup_id_import() {
        // Import normalizes duplicate ids to the unique-id invariant:
        // first pre-order occurrence keeps the id, later ones are cleared
        // (REFERENCE_GRAPH.md §2.5). All apps normalize identically.
        assert_svg_parse("dup_id_import");
    }

    #[test]
    fn svg_parse_live_reference() {
        // <use href="#id"> imports as a live reference (Phase 2a / F-svg-use);
        // all apps parse it to the identical canonical JSON.
        assert_svg_parse("live_reference");
    }

    #[test]
    fn svg_parse_live_compound_id() {
        // A compound shape with id="c1" imports as a CompoundShape whose
        // common.id is set — the compound is now a valid reference target.
        assert_svg_parse("live_compound_id");
    }

    #[test]
    fn svg_parse_live_compound() {
        // <g data-jas-live="compound_shape" data-jas-operation=...> imports as
        // a CompoundShape (not a demoted Group) with its operation preserved.
        assert_svg_parse("live_compound");
    }

    // ---------------------------------------------------------------
    // Algorithm test vectors
    // ---------------------------------------------------------------

    #[test]
    fn algorithm_hit_test_vectors() {
        let json_str = read_fixture("algorithms/hit_test.json");
        let tests: serde_json::Value = serde_json::from_str(&json_str)
            .expect("Failed to parse hit_test.json");

        for tc in tests.as_array().unwrap() {
            let name = tc["name"].as_str().unwrap();
            let func = tc["function"].as_str().unwrap();
            let args: Vec<f64> = tc["args"].as_array().unwrap()
                .iter().map(|v| v.as_f64().unwrap()).collect();
            let expected = tc["expected"].as_bool().unwrap();

            let filled = tc["filled"].as_bool().unwrap_or(false);
            let polygon: Vec<(f64, f64)> = tc["polygon"].as_array()
                .map(|pts| pts.iter().map(|p| {
                    let a = p.as_array().unwrap();
                    (a[0].as_f64().unwrap(), a[1].as_f64().unwrap())
                }).collect())
                .unwrap_or_default();

            let actual = match func {
                "point_in_rect" =>
                    hit_test::point_in_rect(args[0], args[1], args[2], args[3], args[4], args[5]),
                "segments_intersect" =>
                    hit_test::segments_intersect(args[0], args[1], args[2], args[3],
                                                 args[4], args[5], args[6], args[7]),
                "segment_intersects_rect" =>
                    hit_test::segment_intersects_rect(args[0], args[1], args[2], args[3],
                                                      args[4], args[5], args[6], args[7]),
                "rects_intersect" =>
                    hit_test::rects_intersect(args[0], args[1], args[2], args[3],
                                              args[4], args[5], args[6], args[7]),
                "circle_intersects_rect" =>
                    hit_test::circle_intersects_rect(args[0], args[1], args[2],
                                                     args[3], args[4], args[5], args[6], filled),
                "ellipse_intersects_rect" =>
                    hit_test::ellipse_intersects_rect(args[0], args[1], args[2], args[3],
                                                      args[4], args[5], args[6], args[7], filled),
                "point_in_polygon" =>
                    hit_test::point_in_polygon(args[0], args[1], &polygon),
                _ => panic!("Unknown function: {}", func),
            };

            assert_eq!(actual, expected,
                "Hit test '{}' failed: expected {}, got {}", name, expected, actual);
        }
    }

    // ---------------------------------------------------------------
    // Operation equivalence tests
    // ---------------------------------------------------------------

    /// Thin harness shim over the production dispatcher (OP_LOG.md §9,
    /// Increment 3b-B): both the `#[cfg(test)]` cross-language harness and the
    /// production effect path go through the SAME `op_apply` module and the SAME
    /// `record_op` site, so this lift is behavior-preserving (the operations
    /// fixtures stay byte-green) and `targets` is recorded identically on both
    /// paths. Promoting the dispatcher out of `#[cfg(test)]` also hardened its
    /// param parsing so production input can't panic.
    fn apply_op(model: &mut Model, op: &serde_json::Value) {
        crate::document::op_apply::op_apply(model, op);
    }

    /// Run a fixture and return the resulting Model (with its journal). Two
    /// fixture shapes (OP_LOG.md §5):
    ///   - `txns: [{name?, ops:[...]}, ...]` + optional `history: ["undo"|"redo"]`
    ///     — the journal-native form: each transaction commits explicitly, then
    ///     history navigation positions the cursor. `snapshot`/`undo`/`redo` are
    ///     NOT ops here (history navigation, not the op vocabulary).
    ///   - legacy `ops: [...]` — one implicit outer transaction (so non-undoable
    ///     ops like `select_rect`, whose selection IS serialized state per §7,
    ///     are captured); an embedded `snapshot` op opens its own boundaries.
    fn run_operation_model(tc: &serde_json::Value) -> Model {
        let setup_svg = read_fixture(&format!("svg/{}", tc["setup_svg"].as_str().unwrap()));
        let doc = svg_to_document(&setup_svg);
        let mut model = Model::new(doc, None);

        if let Some(txns) = tc.get("txns").and_then(|v| v.as_array()) {
            for txn in txns {
                model.begin_txn();
                if let Some(name) = txn.get("name").and_then(|v| v.as_str()) {
                    model.name_txn(name);
                }
                for op in txn["ops"].as_array().unwrap() {
                    apply_op(&mut model, op);
                }
                model.commit_txn();
                // OP_LOG.md Increment 3a: a `label` on a transaction marks a
                // version point — label_version stamps it onto the committed
                // transaction so it serializes into the journal artifact.
                if let Some(label) = txn.get("label").and_then(|v| v.as_str()) {
                    model.label_version(label);
                }
            }
            if let Some(history) = tc.get("history").and_then(|v| v.as_array()) {
                for h in history {
                    match h.as_str() {
                        Some("undo") => model.undo(),
                        Some("redo") => model.redo(),
                        other => panic!("unknown history directive: {other:?}"),
                    }
                }
            }
        } else {
            model.begin_txn();
            for op in tc["ops"].as_array().unwrap() {
                apply_op(&mut model, op);
            }
            model.commit_txn();
        }
        model
    }

    fn run_operation_test(tc: &serde_json::Value) -> String {
        document_to_test_json(run_operation_model(tc).document())
    }

    /// `checkpoint_equivalence` gate (OP_LOG.md §6): replay the applied prefix
    /// of the journal from `setup_svg` and return its canonical JSON. Must be
    /// byte-identical to the snapshot-path document.
    fn replay_journal(
        setup_svg_name: &str,
        journal: &[crate::document::op_log::Transaction],
        head: usize,
    ) -> String {
        let setup_svg = read_fixture(&format!("svg/{}", setup_svg_name));
        let doc = svg_to_document(&setup_svg);
        let mut model = Model::new(doc, None);
        for txn in &journal[0..head] {
            for op in &txn.ops {
                apply_op(&mut model, &op.params);
            }
        }
        document_to_test_json(model.document())
    }

    fn assert_operation_test(tc: &serde_json::Value) {
        let name = tc["name"].as_str().unwrap();
        let expected_file = tc["expected_json"].as_str().unwrap();
        let expected = read_fixture(&format!("operations/{}", expected_file));
        let expected = expected.trim();
        let model = run_operation_model(tc);
        let actual = document_to_test_json(model.document());

        if actual != expected {
            eprintln!("=== EXPECTED ({}) ===", name);
            eprintln!("{}", expected);
            eprintln!("=== ACTUAL ({}) ===", name);
            eprintln!("{}", actual);
            panic!("Operation test '{}' failed: canonical JSON mismatch", name);
        }

        // checkpoint_equivalence gate (OP_LOG.md §6): the journal must replay to
        // the same document as the snapshot path. Applies to the journal-native
        // `txns` form (the cursor is correct after history navigation) and to
        // legacy `ops` fixtures — except any that still embed the flat
        // snapshot/undo/redo history ops, whose open-then-undone transactions
        // the reshape exists to fix (none remain after the undo-law reshape, but
        // the guard stays).
        let gate_applies = if tc.get("txns").is_some() {
            true
        } else {
            !tc["ops"].as_array().unwrap().iter().any(|o| {
                matches!(o["op"].as_str(), Some("snapshot") | Some("undo") | Some("redo"))
            })
        };
        if gate_applies {
            let setup = tc["setup_svg"].as_str().unwrap();
            let replayed = replay_journal(setup, model.journal(), model.journal_head());
            if replayed != actual {
                eprintln!("=== checkpoint_equivalence GATE FAILED ({}) ===", name);
                eprintln!("--- snapshot path ---\n{}", actual);
                eprintln!("--- journal replay ---\n{}", replayed);
                panic!(
                    "checkpoint_equivalence gate failed for '{}': \
                     journal replay != snapshot path",
                    name
                );
            }
        }
    }

    /// Bootstrap helper: generate expected JSON for operation tests.
    /// Run with: cargo test generate_operation_expected -- --nocapture --ignored
    #[test]
    #[ignore]
    fn generate_operation_expected() {
        for fixture in &["operations/select_and_move.json", "operations/undo_redo_laws.json",
                         "operations/controller_ops.json",
                         "operations/tspan_ops.json",
                         "operations/symbols_ops.json",
                         "operations/print_config_setters.json",
                         "operations/artboard_set_field_batch.json",
                         "operations/artboard_reorder.json",
                         "operations/artboard_delete.json",
                         "operations/artboard_create.json",
                         "operations/artboard_duplicate.json",
                         "operations/structural_delete_at.json",
                         "operations/structural_delete_selection.json",
                         "operations/structural_insert_after.json",
                         "operations/structural_insert_at.json",
                         "operations/wrap_in_group.json",
                         "operations/wrap_in_layer.json",
                         "operations/unpack_group_at.json"] {
            let json_str = read_fixture(fixture);
            let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();

            for tc in tests.as_array().unwrap() {
                let name = tc["name"].as_str().unwrap();
                let expected_file = tc["expected_json"].as_str().unwrap();
                let actual = run_operation_test(tc);
                let path = format!("{}/operations/{}", FIXTURES, expected_file);
                std::fs::write(&path, &actual)
                    .unwrap_or_else(|e| panic!("Failed to write {}: {}", path, e));
                eprintln!("Generated: {} -> {}", name, expected_file);
            }
        }
    }

    /// Bootstrap: generate the live-element round-trip fixtures
    /// (live_compound_roundtrip / live_reference_roundtrip). Run with:
    ///   cargo test generate_live_fixtures -- --ignored --nocapture
    #[test]
    #[ignore]
    fn generate_live_fixtures() {
        use crate::geometry::element::{Element, RectElem, CommonProps, Color, Fill};
        use crate::document::document::Document;
        use crate::geometry::live::{
            CompoundShape, CompoundOperation, ReferenceElem, ElementRef, LiveVariant,
        };
        use std::rc::Rc;
        let mk_rect = |x: f64| Rc::new(Element::Rect(RectElem {
            x, y: 0.0, width: 36.0, height: 36.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(), fill_gradient: None, stroke_gradient: None,
        }));
        // Compound: subtract-front over two rects (exercises `operation`).
        let compound = Element::Live(LiveVariant::CompoundShape(CompoundShape {
            operation: CompoundOperation::SubtractFront,
            operands: vec![mk_rect(0.0), mk_rect(20.0)],
            fill: None, stroke: None, common: CommonProps::default(),
        }));
        let mut doc_c = Document::default();
        // Document::default() seeds a random layer id and a random-id default
        // artboard; clear both so the fixture is deterministic and
        // regeneration-stable (matching the SVG-derived fixtures' shape).
        doc_c.layers[0].common_mut().id = None;
        doc_c.artboards.clear();
        doc_c.layers[0].children_mut().unwrap().push(Rc::new(compound));
        std::fs::write(
            format!("{}/expected/live_compound_roundtrip.json", FIXTURES),
            document_to_test_json(&doc_c),
        ).unwrap();
        // Reference: a rect with id "r1" plus a reference targeting it.
        let mut rect = RectElem {
            x: 0.0, y: 0.0, width: 36.0, height: 36.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(), fill_gradient: None, stroke_gradient: None,
        };
        rect.common.id = Some("r1".into());
        let reference = Element::Live(LiveVariant::Reference(
            ReferenceElem::new(ElementRef("r1".into()), CommonProps::default())));
        let mut doc_r = Document::default();
        doc_r.layers[0].common_mut().id = None;
        doc_r.artboards.clear();
        {
            let kids = doc_r.layers[0].children_mut().unwrap();
            kids.push(Rc::new(Element::Rect(rect)));
            kids.push(Rc::new(reference));
        }
        std::fs::write(
            format!("{}/expected/live_reference_roundtrip.json", FIXTURES),
            document_to_test_json(&doc_r),
        ).unwrap();
        // Phase 2a SVG fixtures: the SVG form (compound -> <g data-jas-live
        // ...data-jas-operation>, reference -> <use href>) plus the json it
        // parses back to (for the svg_parse cross-language pin). Generated from
        // the writer so they round-trip stably.
        let svg_c = document_to_svg(&doc_c);
        std::fs::write(format!("{}/svg/live_compound.svg", FIXTURES), &svg_c).unwrap();
        std::fs::write(
            format!("{}/expected/live_compound.json", FIXTURES),
            document_to_test_json(&svg_to_document(&svg_c)),
        ).unwrap();
        let svg_r = document_to_svg(&doc_r);
        std::fs::write(format!("{}/svg/live_reference.svg", FIXTURES), &svg_r).unwrap();
        std::fs::write(
            format!("{}/expected/live_reference.json", FIXTURES),
            document_to_test_json(&svg_to_document(&svg_r)),
        ).unwrap();
        eprintln!("Generated live_*_roundtrip.json + svg/live_*.svg + expected/live_*.json");
    }

    /// Build the shared DEPENDENCY INDEX test document programmatically
    /// (REFERENCE_GRAPH.md §3). One layer containing, in z-order:
    ///   - a plain rect A with id "a" (a targetable reference target);
    ///   - two references r1, r2 both targeting "a";
    ///   - a dangling reference r3 targeting "ghost" (absent);
    ///   - a 2-cycle: c1 -> c2 and c2 -> c1;
    ///   - a CompoundShape (subtract_front, two rect operands) whose FIRST
    ///     operand carries id "op1", and a reference r4 targeting "op1".
    /// r4 must come out DANGLING because op1 is operand-nested/opaque (the walk
    /// does not recurse into operands) — this pins the operands-opaque decision.
    ///
    /// Construct it here (not as a parsed string) so the document is
    /// unambiguous; the two generated fixtures then let the sibling apps parse
    /// the SAME doc and compare the SAME canonical index.
    fn dependency_index_test_document() -> crate::document::document::Document {
        use crate::geometry::element::{Element, RectElem, CommonProps, Color, Fill};
        use crate::document::document::Document;
        use crate::geometry::live::{
            CompoundShape, CompoundOperation, ReferenceElem, ElementRef, LiveVariant,
        };
        use std::rc::Rc;

        let rect = |id: Option<&str>, x: f64| {
            Rc::new(Element::Rect(RectElem {
                x, y: 0.0, width: 36.0, height: 36.0, rx: 0.0, ry: 0.0,
                fill: Some(Fill::new(Color::BLACK)), stroke: None,
                common: CommonProps { id: id.map(String::from), ..Default::default() },
                fill_gradient: None, stroke_gradient: None,
            }))
        };
        let reference = |id: &str, target: &str| {
            Rc::new(Element::Live(LiveVariant::Reference(ReferenceElem::new(
                ElementRef(target.to_string()),
                CommonProps { id: Some(id.to_string()), ..Default::default() },
            ))))
        };
        // Compound whose first operand carries id "op1" (operand-nested ->
        // opaque to the by-id graph); the compound itself carries id "cs".
        let compound = Rc::new(Element::Live(LiveVariant::CompoundShape(CompoundShape {
            operation: CompoundOperation::SubtractFront,
            operands: vec![rect(Some("op1"), 0.0), rect(None, 20.0)],
            fill: None, stroke: None,
            common: CommonProps { id: Some("cs".into()), ..Default::default() },
        })));

        let mut doc = Document::default();
        // Clear the random layer id + default artboard so the input fixture is
        // deterministic and regeneration-stable (matching the live fixtures).
        doc.layers[0].common_mut().id = None;
        doc.artboards.clear();
        {
            let kids = doc.layers[0].children_mut().unwrap();
            kids.push(rect(Some("a"), 0.0));
            kids.push(reference("r1", "a"));
            kids.push(reference("r2", "a"));
            kids.push(reference("r3", "ghost"));
            kids.push(reference("c1", "c2"));
            kids.push(reference("c2", "c1"));
            kids.push(compound);
            kids.push(reference("r4", "op1"));
        }
        doc
    }

    /// Bootstrap: generate the shared dependency-index fixtures. Run with:
    ///   cargo test generate_dependency_index_fixtures -- --ignored --nocapture
    /// Emits two fixtures (Rust is the source of truth for the canonical shape):
    ///   - expected/dependency_index_input.json — the input Document in
    ///     canonical test_json, so the sibling apps parse the identical doc;
    ///   - expected/dependency_index.json — the canonical serialized index.
    #[test]
    #[ignore]
    fn generate_dependency_index_fixtures() {
        use crate::document::dependency_index::{
            dependency_index, dependency_index_to_test_json,
        };
        let doc = dependency_index_test_document();
        std::fs::write(
            format!("{}/expected/dependency_index_input.json", FIXTURES),
            document_to_test_json(&doc),
        ).unwrap();
        let idx = dependency_index(&doc);
        std::fs::write(
            format!("{}/expected/dependency_index.json", FIXTURES),
            dependency_index_to_test_json(&idx),
        ).unwrap();
        eprintln!("Generated expected/dependency_index_input.json + dependency_index.json");
    }

    /// Cross-language pin (REFERENCE_GRAPH.md §3): read the shared input
    /// document fixture, build the dependency index, serialize it, and assert
    /// byte-equality with the shared index fixture. All five apps run this same
    /// pair of fixtures; passing means Rust agrees on the canonical index shape.
    #[test]
    fn dependency_index_cross_language() {
        use crate::document::dependency_index::{
            dependency_index, dependency_index_to_test_json,
        };
        // Parse the shared input document.
        let input = read_fixture("expected/dependency_index_input.json");
        let input = input.trim();
        let doc = test_json_to_document(input);

        // Sanity: the parsed input must re-serialize to itself (the fixture is
        // canonical), so the index is computed over the same doc all apps see.
        assert_eq!(
            document_to_test_json(&doc),
            input,
            "dependency_index_input.json is not canonical: parse->serialize changed it"
        );

        // Build + serialize the index, compare with the expected fixture.
        let actual = dependency_index_to_test_json(&dependency_index(&doc));
        let expected = read_fixture("expected/dependency_index.json");
        let expected = expected.trim();
        if actual != expected {
            eprintln!("=== EXPECTED (dependency_index) ===");
            eprintln!("{}", expected);
            eprintln!("=== ACTUAL (dependency_index) ===");
            eprintln!("{}", actual);
            panic!("dependency_index cross-language test failed: canonical JSON mismatch");
        }
    }

    /// A richer, fully-acyclic chain/diamond document for the topo-order pin
    /// (REFERENCE_GRAPH.md §8 Phase 4a). The primary `dependency_index` fixture
    /// is mostly cycle + dangling, so it exercises little of the topological
    /// ordering; this one is a multi-level DAG:
    ///   - a rect `b` (no deps);
    ///   - a chain `s1 -> b`, then `s2 -> s1` (s2 depends on s1 depends on b);
    ///   - two refs `t1 -> b`, `t2 -> b` (b has multiple referrers);
    ///   - `d1 -> s1` (a diamond: s1 is referenced by both s2 and d1).
    /// No cycles, no dangling. The expected `topo_order` is the deterministic
    /// level-by-level Kahn output: b, s1, t1, t2, d1, s2 (level 0 {b} frees
    /// {s1,t1,t2}; emitting s1 at level 1 frees {d1,s2} for level 2 —
    /// dependencies-first; verified in the chain unit test). Constructed here so
    /// the document is unambiguous.
    fn dependency_index_chain_document() -> crate::document::document::Document {
        use crate::geometry::element::{Element, RectElem, CommonProps, Color, Fill};
        use crate::document::document::Document;
        use crate::geometry::live::{ReferenceElem, ElementRef, LiveVariant};
        use std::rc::Rc;

        let rect = |id: Option<&str>, x: f64| {
            Rc::new(Element::Rect(RectElem {
                x, y: 0.0, width: 36.0, height: 36.0, rx: 0.0, ry: 0.0,
                fill: Some(Fill::new(Color::BLACK)), stroke: None,
                common: CommonProps { id: id.map(String::from), ..Default::default() },
                fill_gradient: None, stroke_gradient: None,
            }))
        };
        let reference = |id: &str, target: &str| {
            Rc::new(Element::Live(LiveVariant::Reference(ReferenceElem::new(
                ElementRef(target.to_string()),
                CommonProps { id: Some(id.to_string()), ..Default::default() },
            ))))
        };

        let mut doc = Document::default();
        // Clear the random layer id + default artboard for a deterministic,
        // regeneration-stable input fixture (matching the primary fixture).
        doc.layers[0].common_mut().id = None;
        doc.artboards.clear();
        {
            let kids = doc.layers[0].children_mut().unwrap();
            kids.push(rect(Some("b"), 0.0));
            kids.push(reference("s1", "b"));
            kids.push(reference("s2", "s1"));
            kids.push(reference("t1", "b"));
            kids.push(reference("t2", "b"));
            kids.push(reference("d1", "s1"));
        }
        doc
    }

    /// Bootstrap: generate the shared chain/diamond dependency-index fixtures.
    /// Run with:
    ///   cargo test generate_dependency_index_chain_fixtures -- --ignored --nocapture
    /// Emits two fixtures (Rust is the source of truth for the canonical shape):
    ///   - expected/dependency_index_chain_input.json — the input Document;
    ///   - expected/dependency_index_chain.json — the canonical serialized index
    ///     (incl. topo_order in topological sequence).
    #[test]
    #[ignore]
    fn generate_dependency_index_chain_fixtures() {
        use crate::document::dependency_index::{
            dependency_index, dependency_index_to_test_json,
        };
        let doc = dependency_index_chain_document();
        std::fs::write(
            format!("{}/expected/dependency_index_chain_input.json", FIXTURES),
            document_to_test_json(&doc),
        ).unwrap();
        let idx = dependency_index(&doc);
        std::fs::write(
            format!("{}/expected/dependency_index_chain.json", FIXTURES),
            dependency_index_to_test_json(&idx),
        ).unwrap();
        eprintln!(
            "Generated expected/dependency_index_chain_input.json + dependency_index_chain.json"
        );
    }

    /// Cross-language pin for the chain/diamond graph (REFERENCE_GRAPH.md §8
    /// Phase 4a): read the shared input document, build the index, serialize it,
    /// and assert byte-equality with the shared chain fixture. Exercises
    /// multi-level topological ordering that the primary fixture cannot.
    #[test]
    fn dependency_index_chain_cross_language() {
        use crate::document::dependency_index::{
            dependency_index, dependency_index_to_test_json,
        };
        let input = read_fixture("expected/dependency_index_chain_input.json");
        let input = input.trim();
        let doc = test_json_to_document(input);

        // Sanity: the parsed input must re-serialize to itself (it is canonical).
        assert_eq!(
            document_to_test_json(&doc),
            input,
            "dependency_index_chain_input.json is not canonical: parse->serialize changed it"
        );

        let actual = dependency_index_to_test_json(&dependency_index(&doc));
        let expected = read_fixture("expected/dependency_index_chain.json");
        let expected = expected.trim();
        if actual != expected {
            eprintln!("=== EXPECTED (dependency_index_chain) ===");
            eprintln!("{}", expected);
            eprintln!("=== ACTUAL (dependency_index_chain) ===");
            eprintln!("{}", actual);
            panic!("dependency_index_chain cross-language test failed: canonical JSON mismatch");
        }
    }

    // ---------------------------------------------------------------
    // orphaned_references predicate (reference-aware delete core)
    // ---------------------------------------------------------------

    /// The shared orphaned-references fixture cases, computed by the Rust
    /// implementation over `dependency_index_input.json` and hand-verified
    /// (REFERENCE_GRAPH.md, locked semantics). The case array ORDER is part of
    /// the contract — it is the file's order, identical across all apps.
    ///
    /// Layer 0 z-order: a=[0,0], r1->a=[0,1], r2->a=[0,2], r3->ghost=[0,3],
    /// c1->c2=[0,4], c2->c1=[0,5], cs=[0,6] (operand id op1), r4->op1=[0,7].
    fn orphaned_references_cases() -> Vec<(Vec<Vec<usize>>, Vec<String>)> {
        vec![
            // delete `a` -> both refs to it are orphaned.
            (vec![vec![0, 0]], vec!["r1".to_string(), "r2".to_string()]),
            // delete `a` + r1 -> only r2 orphaned (r1 is itself deleted).
            (vec![vec![0, 0], vec![0, 1]], vec!["r2".to_string()]),
            // delete r1 (an instance) -> nothing orphaned (instances have no rdeps).
            (vec![vec![0, 1]], vec![]),
            // delete c1 -> c2 (which references c1) is orphaned.
            (vec![vec![0, 4]], vec!["c2".to_string()]),
            // delete the compound `cs` -> nothing orphaned (op1 is operand-opaque,
            // so r4 was already dangling, not orphaned-by-this-delete; cs has no rdeps).
            (vec![vec![0, 6]], vec![]),
        ]
    }

    /// Bootstrap: generate the shared orphaned-references fixture. Run with:
    ///   cargo test generate_orphaned_references_fixture -- --ignored --nocapture
    /// Emits `expected/orphaned_references.json` — a canonical JSON array of
    /// `{"delete_paths":[..],"orphaned":[sorted ids]}` cases, computed by the
    /// Rust implementation (the source of truth for the canonical shape).
    #[test]
    #[ignore]
    fn generate_orphaned_references_fixture() {
        use crate::document::dependency_index::{
            orphaned_references, orphaned_references_cases_to_test_json,
        };
        let doc = dependency_index_test_document();
        // Compute each case's `orphaned` from the implementation (not the
        // hand-written expectation) so the fixture is the function's own output.
        let cases: Vec<(Vec<Vec<usize>>, Vec<String>)> = orphaned_references_cases()
            .into_iter()
            .map(|(paths, _)| {
                let orphaned = orphaned_references(&doc, &paths);
                (paths, orphaned)
            })
            .collect();
        std::fs::write(
            format!("{}/expected/orphaned_references.json", FIXTURES),
            orphaned_references_cases_to_test_json(&cases),
        )
        .unwrap();
        eprintln!("Generated expected/orphaned_references.json");
    }

    /// Cross-language pin (REFERENCE_GRAPH.md): parse the shared input document,
    /// read the shared orphaned-references fixture, and for each case assert that
    /// `orphaned_references(doc, &delete_paths)` equals the expected ids. All
    /// apps run this same pair of fixtures.
    #[test]
    fn orphaned_references_cross_language() {
        use crate::document::dependency_index::orphaned_references;

        let input = read_fixture("expected/dependency_index_input.json");
        let doc = test_json_to_document(input.trim());

        let cases_json = read_fixture("expected/orphaned_references.json");
        let cases: serde_json::Value = serde_json::from_str(cases_json.trim())
            .expect("orphaned_references.json is valid JSON");
        let cases = cases.as_array().expect("orphaned_references.json is an array");

        for (i, case) in cases.iter().enumerate() {
            let delete_paths: Vec<Vec<usize>> = case["delete_paths"]
                .as_array()
                .expect("delete_paths is an array")
                .iter()
                .map(|p| {
                    p.as_array()
                        .expect("a path is an array")
                        .iter()
                        .map(|n| n.as_u64().expect("path index is a number") as usize)
                        .collect()
                })
                .collect();
            let expected: Vec<String> = case["orphaned"]
                .as_array()
                .expect("orphaned is an array")
                .iter()
                .map(|s| s.as_str().expect("an orphaned id is a string").to_string())
                .collect();

            let actual = orphaned_references(&doc, &delete_paths);
            assert_eq!(
                actual, expected,
                "orphaned_references cross-language case {} ({:?}) mismatch: expected {:?}, got {:?}",
                i, delete_paths, expected, actual
            );
        }
    }

    fn run_operation_fixture(fixture: &str) {
        let json_str = read_fixture(fixture);
        let tests: serde_json::Value = serde_json::from_str(&json_str)
            .unwrap_or_else(|e| panic!("Failed to parse {}: {}", fixture, e));
        for tc in tests.as_array().unwrap() {
            assert_operation_test(tc);
        }
    }

    /// Canonical JSON of the Transaction journal (OP_LOG.md §10 item 4): pins
    /// the reserved causal/merge metadata (txn_id/name/actor/parent/lamport/
    /// label) + each op's verb and targets across apps. Fixed key order (sorted)
    /// + deterministic `txn-N` ids make it byte-shareable. ops carry the verb +
    /// targets only (not the flat params, which the operations fixtures already
    /// pin via the document gate).
    fn journal_to_test_json(journal: &[crate::document::op_log::Transaction]) -> String {
        fn opt(s: &Option<String>) -> String {
            match s {
                Some(v) => format!("\"{v}\""),
                None => "null".to_string(),
            }
        }
        let txns: Vec<String> = journal
            .iter()
            .map(|t| {
                let ops: Vec<String> = t
                    .ops
                    .iter()
                    .map(|o| {
                        let targets: Vec<String> =
                            o.targets.iter().map(|x| format!("\"{x}\"")).collect();
                        format!("{{\"op\":\"{}\",\"targets\":[{}]}}", o.op, targets.join(","))
                    })
                    .collect();
                format!(
                    "{{\"actor\":\"{}\",\"label\":{},\"lamport\":{},\"name\":{},\
                     \"ops\":[{}],\"parent\":{},\"txn_id\":\"{}\"}}",
                    t.actor,
                    opt(&t.label),
                    t.lamport,
                    opt(&t.name),
                    ops.join(","),
                    opt(&t.parent),
                    t.txn_id,
                )
            })
            .collect();
        format!("[{}]", txns.join(","))
    }

    fn assert_journal_metadata(tc: &serde_json::Value) {
        let model = run_operation_model(tc);
        let actual = journal_to_test_json(model.journal());
        let expected_file = tc["expected_journal_json"].as_str().unwrap();
        let expected = read_fixture(&format!("operations/{expected_file}"));
        let expected = expected.trim();
        if actual != expected {
            eprintln!("=== EXPECTED journal ===\n{expected}");
            eprintln!("=== ACTUAL journal ===\n{actual}");
            panic!("txn_metadata journal JSON mismatch");
        }
    }

    /// OP_LOG.md §10 item 4: the journal's causal/merge metadata serializes
    /// byte-identically across apps (deterministic txn-N counter + parent edge).
    #[test]
    fn journal_txn_metadata() {
        for fixture in ["operations/txn_metadata.json", "operations/txn_labels.json"] {
            let json_str = read_fixture(fixture);
            let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();
            for tc in tests.as_array().unwrap() {
                assert_journal_metadata(tc);
            }
        }
    }

    // ---------------------------------------------------------------
    // Production op-capture cross-language fixture (OP_LOG.md §9,
    // Increment 3b-B). The 3b-B production logic already ships in Rust
    // (effects.rs `run_doc_effect` routing the three replay-safe verbs +
    // `run_effects` action-name stamping; controller::selection_to_ids; the
    // lazy `begin_txn`-excluding-`select_rect` drag-frame-hole fix in
    // op_apply). This section EXTRACTS the two #[cfg(test)] effects.rs proofs
    // into a SHARED, byte-pinnable fixture + goldens + harness so the
    // Swift/OCaml/Python ports have a golden to match byte-for-byte. The
    // harness drives the REAL `interpreter::effects::run_effects` (NOT the
    // hand-bracketed `apply_op` operations path) — that is the whole point:
    // it exercises the YAML→harness param translation (marquee corner coords
    // x1/y1/x2/y2/additive → x/y/width/height/extend), batch ownership /
    // single-transaction commit, action naming, and the lazy-begin hole fix.
    // ---------------------------------------------------------------

    /// Production-capture JOURNAL serializer VARIANT (OP_LOG.md §10 item 4).
    ///
    /// Distinct from `journal_to_test_json` (the txn_metadata serializer), which
    /// deliberately OMITS op params and pins txn_id/lamport/parent/actor. The
    /// production golden MUST instead pin the PARAM-TRANSLATION result (the
    /// marquee corners x1=-5,y1=-5,x2=50,y2=50 normalize to
    /// x=-5,y=-5,width=55,height=55,extend=false), so this variant emits, per
    /// transaction: `name`, and per op `{op, params, targets}` with `params`
    /// sorted-key + fixed-float canonicalized exactly like `document_to_test_json`
    /// (via `test_json::canonical_json_value`).
    ///
    /// `txn_id` is EXCLUDED — it is a live-entropy seam, non-deterministic
    /// per-app (live runs draw entropy), so it can never be byte-shared. The
    /// redundant `"op"` key inside the recorded `params` (op_apply records the
    /// full op value, verb included) is STRIPPED — the verb already lives in the
    /// op-level `op` field, and the golden's `params` shape is the pure payload
    /// the ports replay. `actor`/`parent`/`lamport` are OMITTED: this serializer
    /// pins only what the production-capture goldens are about (the translated
    /// ops + the action name); the causal metadata already has its own
    /// byte-stable golden (`txn_metadata_golden.json`) which this work leaves
    /// untouched.
    fn production_journal_to_test_json(
        journal: &[crate::document::op_log::Transaction],
    ) -> String {
        fn opt(s: &Option<String>) -> String {
            match s {
                Some(v) => format!("{v:?}"),
                None => "null".to_string(),
            }
        }
        let txns: Vec<String> = journal
            .iter()
            .map(|t| {
                let ops: Vec<String> = t
                    .ops
                    .iter()
                    .map(|o| {
                        // Strip the redundant top-level "op" key from params:
                        // op_apply records the FULL op value (verb included), but
                        // the verb already lives in the op-level `op` field, so
                        // the golden's `params` is the pure payload.
                        let mut params = o.params.clone();
                        if let serde_json::Value::Object(map) = &mut params {
                            map.remove("op");
                        }
                        let targets: Vec<String> =
                            o.targets.iter().map(|x| format!("{x:?}")).collect();
                        format!(
                            "{{\"op\":{:?},\"params\":{},\"targets\":[{}]}}",
                            o.op,
                            crate::geometry::test_json::canonical_json_value(&params),
                            targets.join(","),
                        )
                    })
                    .collect();
                format!(
                    "{{\"name\":{},\"ops\":[{}]}}",
                    opt(&t.name),
                    ops.join(","),
                )
            })
            .collect();
        format!("[{}]", txns.join(","))
    }

    /// Canonical JSON of an evaluated `PolygonSet` (a list of rings, each a list
    /// of (x,y) points), using the SAME fixed-float canonicalization as
    /// `document_to_test_json` so the re-derived geometry golden is byte-shareable
    /// across apps. Pins the re-derived OUTPUT of the production-captured recipe
    /// against the EDITED source (the liveness payoff), not the recipe shape.
    fn polygon_set_to_test_json(ps: &[Vec<(f64, f64)>]) -> String {
        let rings: Vec<String> = ps
            .iter()
            .map(|ring| {
                let pts: Vec<String> = ring
                    .iter()
                    .map(|&(x, y)| {
                        format!(
                            "[{},{}]",
                            crate::geometry::test_json::canonical_json_value(
                                &serde_json::json!(x)),
                            crate::geometry::test_json::canonical_json_value(
                                &serde_json::json!(y)),
                        )
                    })
                    .collect();
                format!("[{}]", pts.join(","))
            })
            .collect();
        format!("[{}]", rings.join(","))
    }

    /// Build the fresh Model a production-capture fixture's `setup_svg` defines.
    fn production_model(fixture: &serde_json::Value) -> Model {
        let setup_svg =
            read_fixture(fixture["setup_svg"].as_str().expect("setup_svg"));
        Model::new(svg_to_document(&setup_svg), None)
    }

    /// Run every `run_effects` batch a production-capture fixture defines through
    /// the REAL production interpreter, stamping the fixture's `action_name`.
    ///
    /// Supports both fixture shapes:
    ///   - `effect_batch: [...]` — ONE run_effects call (the eye_demo
    ///     select→copy→move demonstration, committing one named transaction).
    ///   - `frames: [[...], [...]]` — MULTIPLE separate run_effects calls (the
    ///     drag-frame-hole closure: frame 1 = snapshot+select+translate,
    ///     frame 2 = a BARE translate with NO snapshot). Each frame is a
    ///     distinct batch, so each commits its own named transaction — the one
    ///     scenario the test-path operations corpus structurally cannot reach.
    fn run_production_batches(fixture: &serde_json::Value, model: &mut Model) {
        use crate::interpreter::effects::run_effects;
        use crate::interpreter::state_store::StateStore;
        let action_name = fixture["action_name"].as_str();
        let parse_batch = |v: &serde_json::Value| -> Vec<serde_json::Value> {
            v.as_array().expect("a batch is an array of effects").clone()
        };
        let mut store = StateStore::new();
        if let Some(batch) = fixture.get("effect_batch") {
            let effects = parse_batch(batch);
            run_effects(
                &effects, &serde_json::json!({}), &mut store,
                Some(model), None, None, action_name);
        } else if let Some(frames) = fixture.get("frames").and_then(|v| v.as_array()) {
            for frame in frames {
                let effects = parse_batch(frame);
                run_effects(
                    &effects, &serde_json::json!({}), &mut store,
                    Some(model), None, None, action_name);
            }
        } else {
            panic!("production-capture fixture has neither effect_batch nor frames");
        }
    }

    /// Re-derive the recorded element's output against the EDITED source and
    /// return its canonical PolygonSet JSON.
    ///
    /// Lifts the LAST committed transaction's op segment (the production journal
    /// segment), runs `capture_recipe` to normalize it into an input-addressed
    /// recipe, wraps it in a `RecordedElem`, then `evaluate_with` it over a
    /// resolver that returns the EDITED source (the fixture's
    /// `recorded.edit_source` applies `set:{x:..}` to the source SVG).
    ///
    /// NOTE — the SVG px→pt unit conversion (96/72 = ×0.75) bakes into the
    /// re-derived bbox: editing the source `eye` to x=100 (px) maps to x=75 (pt)
    /// with w=10px→7.5pt; copy(dx=0)+translate(+50) → the derived bbox spans
    /// x in [125, 132.5] (pt). The derivative FOLLOWED the edit (capture-time
    /// source was x=0 → would have been [50,57.5]) — that is the whole point of
    /// liveness, and it is what this golden pins.
    fn rederive_recorded_output(
        fixture: &serde_json::Value,
        journal: &[crate::document::op_log::Transaction],
    ) -> String {
        use crate::geometry::live::{
            capture_recipe, ElementRef, ElementResolver, RecordedElem, DEFAULT_PRECISION,
        };
        use crate::geometry::element::CommonProps;
        use std::rc::Rc;

        let segment = journal.last().expect("a committed transaction").ops.clone();
        let (recipe, inputs) = capture_recipe(&segment);

        let mut common = CommonProps::default();
        common.id = Some("rec".into());
        let recorded = RecordedElem::new(
            recipe,
            inputs.iter().cloned().map(ElementRef).collect(),
            common,
        );

        // Apply the fixture's edit to the source SVG, parse, and resolve the
        // edited element by id.
        let rec = &fixture["recorded"];
        let edit = &rec["edit_source"];
        let edit_id = edit["id"].as_str().expect("edit_source.id");
        let setup_svg =
            read_fixture(fixture["setup_svg"].as_str().expect("setup_svg"));
        // The eye_demo edit sets x=100; mirror the effects.rs proof's textual
        // edit (replace x="0" y="0" → x="100" y="0") so the parse is identical.
        let new_x = edit["set"]["x"].as_f64().expect("edit_source.set.x");
        let edited_svg = setup_svg.replace(
            r#"x="0" y="0""#, &format!(r#"x="{}" y="0""#, new_x as i64));
        let edited_doc = svg_to_document(&edited_svg);
        // The edited source is layers[0].children[0].
        let edited_el = edited_doc
            .get_element(&vec![0, 0])
            .expect("edited source element")
            .clone();

        struct OneResolver {
            id: String,
            el: Rc<crate::geometry::element::Element>,
        }
        impl ElementResolver for OneResolver {
            fn resolve(
                &self, id: &ElementRef,
            ) -> Option<Rc<crate::geometry::element::Element>> {
                if id.0 == self.id { Some(self.el.clone()) } else { None }
            }
        }
        let resolver = OneResolver { id: edit_id.to_string(), el: Rc::new(edited_el) };
        let mut visiting = std::collections::BTreeSet::new();
        let ps = recorded.evaluate_with(DEFAULT_PRECISION, &resolver, &mut visiting);
        polygon_set_to_test_json(&ps)
    }

    /// Reusable production-capture harness (OP_LOG.md §9, Increment 3b-B). Loads
    /// the fixture, drives the REAL `run_effects` over `setup_svg`, then asserts:
    ///  (a) `production_journal_to_test_json` == `expected_journal_json`
    ///      (pins the translated ops + the action name);
    ///  (b) the `checkpoint_equivalence` replay (OP_LOG.md §6): replaying the
    ///      journal ops via `op_apply` from `setup_svg` is byte-identical BOTH to
    ///      `expected_document_json` AND to the live snapshot-path document;
    ///  (c) the recorded re-derivation (when the fixture declares `recorded`)
    ///      == `expected_output_json`;
    ///  (d) a SCOPED completeness assert (OP_LOG.md §9): EVERY committed
    ///      production transaction's `ops` is non-empty (the production path here
    ///      MUST emit ops — NOT a global commit_txn invariant; the other ~30
    ///      verbs legitimately still emit empty ops).
    fn run_production_batch_fixture(fixture_path: &str) {
        let json_str = read_fixture(fixture_path);
        let fx: serde_json::Value =
            serde_json::from_str(&json_str).expect("parse production-capture fixture");
        let name = fx["name"].as_str().unwrap_or(fixture_path);

        // Drive the REAL production interpreter.
        let mut model = production_model(&fx);
        run_production_batches(&fx, &mut model);

        // (a) journal serialization == golden.
        let actual_journal = production_journal_to_test_json(model.journal());
        let expected_journal =
            read_fixture(fx["expected_journal_json"].as_str().expect("expected_journal_json"));
        let expected_journal = expected_journal.trim();
        if actual_journal != expected_journal {
            eprintln!("=== EXPECTED journal ({name}) ===\n{expected_journal}");
            eprintln!("=== ACTUAL journal ({name}) ===\n{actual_journal}");
            panic!("production-capture journal JSON mismatch for '{name}'");
        }

        // Snapshot-path document (the live result of run_effects).
        let snapshot_doc = document_to_test_json(model.document());

        // (b) checkpoint_equivalence: replay the WHOLE journal via op_apply from
        // a fresh setup, byte-compare to BOTH the expected_document golden AND
        // the live snapshot-path document.
        let mut replay = production_model(&fx);
        for txn in model.journal() {
            for op in &txn.ops {
                crate::document::op_apply::op_apply(&mut replay, &op.params);
            }
        }
        let replay_doc = document_to_test_json(replay.document());
        let expected_doc =
            read_fixture(fx["expected_document_json"].as_str().expect("expected_document_json"));
        let expected_doc = expected_doc.trim();
        if replay_doc != snapshot_doc {
            eprintln!("=== checkpoint_equivalence GATE FAILED ({name}) ===");
            eprintln!("--- snapshot path ---\n{snapshot_doc}");
            eprintln!("--- journal replay ---\n{replay_doc}");
            panic!("checkpoint_equivalence: journal replay != snapshot path for '{name}'");
        }
        if replay_doc != expected_doc {
            eprintln!("=== EXPECTED doc ({name}) ===\n{expected_doc}");
            eprintln!("=== ACTUAL doc ({name}) ===\n{replay_doc}");
            panic!("production-capture document JSON mismatch for '{name}'");
        }

        // (c) recorded re-derivation against the edited source == golden.
        if fx.get("recorded").is_some() {
            let actual_out = rederive_recorded_output(&fx, model.journal());
            let expected_out = read_fixture(
                fx["recorded"]["expected_output_json"].as_str().expect("expected_output_json"));
            let expected_out = expected_out.trim();
            if actual_out != expected_out {
                eprintln!("=== EXPECTED rederived ({name}) ===\n{expected_out}");
                eprintln!("=== ACTUAL rederived ({name}) ===\n{actual_out}");
                panic!("production-capture re-derivation mismatch for '{name}'");
            }
        }

        // (d) scoped completeness assert: every committed production transaction
        // emits ops (the production path here is NOT named-but-op-less).
        assert!(!model.journal().is_empty(),
            "production batch committed at least one transaction ({name})");
        for (i, txn) in model.journal().iter().enumerate() {
            assert!(!txn.ops.is_empty(),
                "production txn {i} emits ops (3b-B completeness, {name})");
        }
    }

    /// Bootstrap: generate the production-capture goldens from the real
    /// production path. Run with:
    ///   cargo test generate_production_capture_goldens -- --ignored --nocapture
    /// Rust is the source of truth for the canonical shape; the sibling apps
    /// match these goldens byte-for-byte.
    #[test]
    #[ignore]
    fn generate_production_capture_goldens() {
        for fixture_path in [
            "production_capture/eye_demo.json",
            "production_capture/eye_demo_bare_frame.json",
        ] {
            let json_str = read_fixture(fixture_path);
            let fx: serde_json::Value = serde_json::from_str(&json_str).unwrap();
            let mut model = production_model(&fx);
            run_production_batches(&fx, &mut model);

            let journal = production_journal_to_test_json(model.journal());
            let jpath = format!(
                "{}/{}", FIXTURES, fx["expected_journal_json"].as_str().unwrap());
            std::fs::write(&jpath, &journal).unwrap();
            eprintln!("Generated {jpath}\n{journal}");

            // Document golden = the journal-replay document (== snapshot path,
            // gated below).
            let mut replay = production_model(&fx);
            for txn in model.journal() {
                for op in &txn.ops {
                    crate::document::op_apply::op_apply(&mut replay, &op.params);
                }
            }
            let doc = document_to_test_json(replay.document());
            let dpath = format!(
                "{}/{}", FIXTURES, fx["expected_document_json"].as_str().unwrap());
            std::fs::write(&dpath, &doc).unwrap();
            eprintln!("Generated {dpath}\n{doc}");

            if fx.get("recorded").is_some() {
                let out = rederive_recorded_output(&fx, model.journal());
                let opath = format!(
                    "{}/{}", FIXTURES,
                    fx["recorded"]["expected_output_json"].as_str().unwrap());
                std::fs::write(&opath, &out).unwrap();
                eprintln!("Generated {opath}\n{out}");
            }
        }
    }

    /// Production op-capture eye demo (OP_LOG.md §9): marquee-select → copy →
    /// move, driven through the REAL run_effects, pins the translated journal,
    /// the checkpoint-equivalent document, and the live re-derivation.
    #[test]
    fn production_capture_eye_demo() {
        run_production_batch_fixture("production_capture/eye_demo.json");
    }

    /// Production op-capture drag-frame-hole closure (OP_LOG.md §9): two SEPARATE
    /// run_effects batches — frame 1 (snapshot+select+translate) and a BARE
    /// frame 2 (translate, NO snapshot) — both commit NAMED transactions that
    /// journal their move_selection op. The one scenario the test-path
    /// operations corpus structurally cannot reach.
    #[test]
    fn production_capture_eye_demo_bare_frame() {
        run_production_batch_fixture("production_capture/eye_demo_bare_frame.json");
    }

    /// The canonical recorded-live-element document (RECORDED_ELEMENTS.md): a
    /// recorded element whose recipe copies its input "eye" and translates the
    /// copy +50x. Built identically in every app's harness, so its
    /// document_to_test_json serialization (the recipe + inputs) is the
    /// cross-language pin.
    fn recorded_canonical_document() -> crate::document::document::Document {
        use crate::document::op_log::PrimitiveOp;
        use crate::geometry::element::{CommonProps, Element, LayerElem};
        use crate::geometry::live::{ElementRef, LiveVariant, RecordedElem};
        use std::rc::Rc;
        let recipe = vec![
            PrimitiveOp { op: "copy".into(),
                params: serde_json::json!({"from": ["eye"], "dx": 0.0, "dy": 0.0}),
                targets: vec![] },
            PrimitiveOp { op: "translate".into(),
                params: serde_json::json!({"ids": ["$0"], "dx": 50.0, "dy": 0.0}),
                targets: vec![] },
        ];
        let mut common = CommonProps::default();
        common.id = Some("rec".into());
        let rec = RecordedElem::new(recipe, vec![ElementRef("eye".into())], common);
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(Element::Live(LiveVariant::Recorded(rec)))],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        crate::document::document::Document {
            layers: vec![layer], artboards: vec![], ..Default::default()
        }
    }

    /// Cross-language pin (RECORDED_ELEMENTS.md §8): a recorded element's recipe
    /// + inputs serialize byte-identically across the four native apps.
    #[test]
    fn recorded_cross_language() {
        let actual = document_to_test_json(&recorded_canonical_document());
        let expected = read_fixture("operations/recorded_eye.json");
        let expected = expected.trim();
        if actual != expected {
            eprintln!("=== EXPECTED ===\n{expected}\n=== ACTUAL ===\n{actual}");
            panic!("recorded cross-language serialization mismatch");
        }
    }

    #[test]
    fn operation_select_and_move() {
        run_operation_fixture("operations/select_and_move.json");
    }

    #[test]
    fn operation_undo_redo_laws() {
        run_operation_fixture("operations/undo_redo_laws.json");
    }

    #[test]
    fn operation_controller_ops() {
        run_operation_fixture("operations/controller_ops.json");
    }

    #[test]
    fn operation_tspan_ops() {
        run_operation_fixture("operations/tspan_ops.json");
    }

    /// Symbols P2 operation fixtures (SYMBOLS.md §7): make_symbol, place_instance,
    /// detach, redefine. Each setup parses through the P1 SVG <defs> codec, runs
    /// the op, and pins the canonical JSON all four apps must reproduce.
    #[test]
    fn operation_symbols_ops() {
        run_operation_fixture("operations/symbols_ops.json");
    }

    /// Boolean grouping (OP_LOG.md §10 item 3): boolean_union + post-op simplify
    /// are one transaction with two child ops; the gate pins that the journal
    /// replays to the snapshot-path document.
    #[test]
    fn operation_boolean_ops() {
        run_operation_fixture("operations/boolean_ops.json");
    }

    /// Print-config field setters (OP_LOG.md §9 Phase P1): the eight doc.*
    /// print-config verbs journal real ops through `op_apply`. The fixtures span
    /// all four target structs (document_setup, print_preferences root,
    /// output.inks[index], graphics/color_management/marks/output/advanced) plus
    /// a type-mismatch skip case. The checkpoint_equivalence gate (run by
    /// `assert_operation_test`) proves each journaled op replays byte-identically
    /// to the snapshot-path document — i.e. the arm both mutates and replays.
    #[test]
    fn operation_print_config_setters() {
        run_operation_fixture("operations/print_config_setters.json");
    }

    /// Artboard doc.* setters (OP_LOG.md §9 Phase P2): the five no-id-minting
    /// artboard verbs journal real ops through `op_apply`. `set_artboard_field`
    /// targets one artboard by id and applies one field per op — the batch
    /// fixture proves the ten field-call action (artboard_options_confirm) lands
    /// as TEN distinct ops inside ONE transaction (one-op-per-field-call
    /// granularity) plus the two document-global `set_artboard_options_field`
    /// ops. A type-mismatch / missing-id case proves the skip records nothing.
    /// The checkpoint_equivalence gate (run by `assert_operation_test`) proves
    /// each journaled op replays byte-identically to the snapshot-path document.
    #[test]
    fn operation_artboard_set_field_batch() {
        run_operation_fixture("operations/artboard_set_field_batch.json");
    }

    /// Artboard reorder (OP_LOG.md §9 Phase P2): `move_artboards_up` /
    /// `move_artboards_down` swap each selected artboard with its unselected
    /// neighbor. Includes a no-op-at-the-boundary case (a top artboard moved up
    /// journals nothing). targets carry the moved ids.
    #[test]
    fn operation_artboard_reorder() {
        run_operation_fixture("operations/artboard_reorder.json");
    }

    /// Artboard delete (OP_LOG.md §9 Phase P2): `delete_artboard_by_id` retains
    /// the artboards whose id differs from the target; a missing-id delete
    /// journals nothing (no effective change). targets carry the deleted id.
    #[test]
    fn operation_artboard_delete() {
        run_operation_fixture("operations/artboard_delete.json");
    }

    /// Artboard create (OP_LOG.md §9 Phase P3): `create_artboard` is the FIRST
    /// id-minting verb to journal through `op_apply`. Under the VALUE-IN-OP id
    /// strategy the op carries the minted `id` as a LITERAL (the harness fixtures
    /// supply FIXED ids — `abZZ`/`abYY`/`abXX`) and a RESOLVED `fields` object;
    /// the op_apply arm reads them VERBATIM and NEVER mints / NEVER taps entropy /
    /// NEVER runs the collision-retry. The checkpoint_equivalence gate (run by
    /// `assert_operation_test`) proves the journaled op replays byte-identically
    /// to the snapshot-path document — INCLUDING the new artboard with its literal
    /// id. A type-mismatch field is skipped (the artboard keeps the default for
    /// that field) while the create itself still lands.
    #[test]
    fn operation_artboard_create() {
        run_operation_fixture("operations/artboard_create.json");
    }

    /// Artboard duplicate (OP_LOG.md §9 Phase P3): `duplicate_artboard` clones a
    /// source artboard (by `id`) and writes the minted `new_id` + the RESOLVED
    /// `name` + `offset_x`/`offset_y` as LITERALS. The op_apply arm reads them
    /// VERBATIM and NEVER mints (no entropy / no collision-retry on replay) and
    /// NEVER re-derives the name. A missing source id is a no-op that journals
    /// nothing. The checkpoint_equivalence gate proves byte-identical replay.
    #[test]
    fn operation_artboard_duplicate() {
        run_operation_fixture("operations/artboard_duplicate.json");
    }

    /// Structural tree-mutation verbs (OP_LOG.md §9 Phase P4): `delete_at`
    /// removes the element at a path (a missing path is a no-op that journals
    /// nothing); `insert_after` / `insert_at` carry the WHOLE element to insert as
    /// LITERAL serde JSON in the op (VALUE-IN-OP, §7) and insert it VERBATIM —
    /// the carried id (`dup-1` / `ins-1` / `lyr-1`) survives byte-identically on
    /// replay; `delete_selection` operates on the serialized selection. A
    /// malformed/absent element or path SKIPS (records nothing) without panicking.
    /// The checkpoint_equivalence gate (run by `assert_operation_test`) proves each
    /// journaled op replays byte-identically to the snapshot-path document —
    /// INCLUDING the inserted element with its literal id — which is the heart of
    /// the element value-in-op strategy.
    #[test]
    fn operation_structural_delete_at() {
        run_operation_fixture("operations/structural_delete_at.json");
    }

    #[test]
    fn operation_structural_delete_selection() {
        run_operation_fixture("operations/structural_delete_selection.json");
    }

    #[test]
    fn operation_structural_insert_after() {
        run_operation_fixture("operations/structural_insert_after.json");
    }

    #[test]
    fn operation_structural_insert_at() {
        run_operation_fixture("operations/structural_insert_at.json");
    }

    /// OP_LOG.md §9 Phase P4 — Fork-4 targets: an inserting verb whose carried
    /// element has a `common.id` records that id in `targets`. The byte-gate
    /// ignores targets, so this is the only place it is pinned.
    #[test]
    fn operation_structural_insert_records_id_targets() {
        // insert_after carries id "dup-1"; insert_at carries "ins-1" (nested) and
        // "lyr-1" (top-level layer).
        let cases: &[(&str, &str, &str)] = &[
            ("operations/structural_insert_after.json", "structural_insert_after_child", "dup-1"),
            ("operations/structural_insert_at.json", "structural_insert_at_nested", "ins-1"),
            ("operations/structural_insert_at.json", "structural_insert_at_top_level_layer", "lyr-1"),
        ];
        for (fixture, name, expected_id) in cases {
            let json_str = read_fixture(fixture);
            let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();
            let tc = tests.as_array().unwrap().iter()
                .find(|t| t["name"].as_str() == Some(name))
                .unwrap_or_else(|| panic!("fixture case {name} not found"));
            let model = run_operation_model(tc);
            let last = model.journal().last().expect("a committed transaction");
            assert_eq!(last.ops.len(), 1, "{name}: one insert op journaled");
            assert_eq!(last.ops[0].targets, vec![expected_id.to_string()],
                "{name}: targets carry the inserted element's literal id (value-in-op)");
        }
    }

    /// OP_LOG.md §9 Phase P4 — element value-in-op replay determinism: the SAME
    /// journal (carrying the WHOLE element JSON) replays to the SAME document
    /// TWICE, and the inserted element keeps its literal id (no re-mint, no
    /// entropy). Covers the two inserting verbs.
    #[test]
    fn operation_structural_insert_replay_is_deterministic() {
        for fixture in &[
            "operations/structural_insert_after.json",
            "operations/structural_insert_at.json",
        ] {
            let json_str = read_fixture(fixture);
            let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();
            for tc in tests.as_array().unwrap() {
                let model = run_operation_model(tc);
                let setup = tc["setup_svg"].as_str().unwrap();
                let head = model.journal_head();
                let replay1 = replay_journal(setup, model.journal(), head);
                let replay2 = replay_journal(setup, model.journal(), head);
                assert_eq!(
                    replay1, replay2,
                    "replay of '{}' is non-deterministic (value-in-op element must \
                     insert byte-identically with its literal id)",
                    tc["name"].as_str().unwrap()
                );
            }
        }
    }

    /// Group/layer wrapping verbs (OP_LOG.md §9 Phase P5): the highest-structural-
    /// complexity verbs. Each is a MULTI-STEP mutation that must replay as ONE
    /// deterministic op:
    ///   - `wrap_in_group` collects the elements at `paths` in document order,
    ///     reverse-deletes them, then inserts a new Group (carrying them as
    ///     children) at the TOPMOST source index under the shared parent. The op
    ///     carries the RESOLVED plain index arrays (`[[..],..]`) and, value-in-op,
    ///     an optional literal container `id`.
    ///   - `wrap_in_layer` is parallel but appends a new top-level Layer carrying
    ///     the RESOLVED name LITERAL (never the `next_layer_name` expr — replay
    ///     must not re-derive a possibly-colliding name) and an optional literal id.
    ///   - `unpack_group_at` extracts a Group's children, deletes the group, and
    ///     re-inserts the children at the vacated position with ascending indices
    ///     (children keep their ids — no minting).
    /// The checkpoint_equivalence gate (run by `assert_operation_test`) proves the
    /// multi-step reconstructs the EXACT tree — child order, deletion order, and
    /// insertion index all deterministic from the op — byte-identically on the
    /// replay path. Malformed paths / missing groups SKIP (records nothing) without
    /// panicking; an empty `paths` is a no-op that journals nothing.
    #[test]
    fn operation_wrap_in_group() {
        run_operation_fixture("operations/wrap_in_group.json");
    }

    #[test]
    fn operation_wrap_in_layer() {
        run_operation_fixture("operations/wrap_in_layer.json");
    }

    #[test]
    fn operation_unpack_group_at() {
        run_operation_fixture("operations/unpack_group_at.json");
    }

    /// OP_LOG.md §9 Phase P5 — Fork-4 targets: `wrap_in_group` / `wrap_in_layer`
    /// record the wrapped element ids PLUS the container id when the op assigns one
    /// (value-in-op). `unpack_group_at` records the unpacked children's ids. The
    /// byte-gate ignores targets, so this is the only place it is pinned.
    #[test]
    fn operation_wrap_unpack_records_id_targets() {
        // wrap_in_group with id "grp-1": wrapped rects are id-less (two_rects.svg),
        // so targets is just the assigned group id.
        let cases: &[(&str, &str, &str, Vec<&str>)] = &[
            ("operations/wrap_in_group.json", "wrap_in_group_with_id", "wrap_in_group",
                vec!["grp-1"]),
            ("operations/wrap_in_layer.json", "wrap_in_layer_with_id", "wrap_in_layer",
                vec!["lyr-9"]),
        ];
        for (fixture, name, expected_verb, expected_targets) in cases {
            let json_str = read_fixture(fixture);
            let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();
            let tc = tests.as_array().unwrap().iter()
                .find(|t| t["name"].as_str() == Some(name))
                .unwrap_or_else(|| panic!("fixture case {name} not found"));
            let model = run_operation_model(tc);
            let last = model.journal().last().expect("a committed transaction");
            assert_eq!(last.ops.len(), 1, "{name}: one wrap op journaled");
            assert_eq!(last.ops[0].op, *expected_verb, "{name}: the journaled verb");
            let expected: Vec<String> = expected_targets.iter().map(|s| s.to_string()).collect();
            assert_eq!(last.ops[0].targets, expected,
                "{name}: targets carry wrapped ids + the assigned container id");
        }
    }

    /// OP_LOG.md §9 Phase P5 — malformed/no-op cases journal NOTHING (the op never
    /// reaches record_op when nothing changed). Proves the hardened param parse +
    /// effective-change guard: a malformed `paths`, an empty `paths`, a non-Group
    /// target, and a missing path each leave the journal empty.
    #[test]
    fn operation_wrap_unpack_noop_journals_nothing() {
        let cases: &[(&str, &str)] = &[
            ("operations/wrap_in_group.json", "wrap_in_group_malformed_paths_skips"),
            ("operations/wrap_in_group.json", "wrap_in_group_empty_paths_noop"),
            ("operations/wrap_in_layer.json", "wrap_in_layer_malformed_paths_skips"),
            ("operations/wrap_in_layer.json", "wrap_in_layer_empty_paths_noop"),
            ("operations/unpack_group_at.json", "unpack_group_at_non_group_noop"),
            ("operations/unpack_group_at.json", "unpack_group_at_missing_path_noop"),
            ("operations/unpack_group_at.json", "unpack_group_at_malformed_path_skips"),
        ];
        for (fixture, name) in cases {
            let json_str = read_fixture(fixture);
            let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();
            let tc = tests.as_array().unwrap().iter()
                .find(|t| t["name"].as_str() == Some(name))
                .unwrap_or_else(|| panic!("fixture case {name} not found"));
            let model = run_operation_model(tc);
            // A no-op/malformed wrap mutates nothing, so the bracketing transaction
            // is empty — and an empty transaction is dropped on commit (the
            // commit_txn no-op rule, OP_LOG.md §9). The journal is therefore empty.
            assert!(model.journal().is_empty(),
                "{name}: a no-op/malformed wrap must journal NOTHING (got {:?})",
                model.journal());
        }
    }

    /// OP_LOG.md §9 Phase P5 — multi-step replay determinism: the SAME journal
    /// replays to the SAME document TWICE. The multi-step reconstruction (sort
    /// paths, reverse-delete, build container, insert at topmost index) is a pure
    /// deterministic function of the recorded op — child order, deletion order, and
    /// insertion index are all fixed by the op, with no entropy and no re-derived
    /// name. Covers all three wrapping verbs.
    #[test]
    fn operation_wrap_unpack_replay_is_deterministic() {
        for fixture in &[
            "operations/wrap_in_group.json",
            "operations/wrap_in_layer.json",
            "operations/unpack_group_at.json",
        ] {
            let json_str = read_fixture(fixture);
            let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();
            for tc in tests.as_array().unwrap() {
                let model = run_operation_model(tc);
                let setup = tc["setup_svg"].as_str().unwrap();
                let head = model.journal_head();
                let replay1 = replay_journal(setup, model.journal(), head);
                let replay2 = replay_journal(setup, model.journal(), head);
                assert_eq!(
                    replay1, replay2,
                    "replay of '{}' is non-deterministic (the multi-step wrap must \
                     reconstruct the tree byte-identically from the op)",
                    tc["name"].as_str().unwrap()
                );
            }
        }
    }

    /// OP_LOG.md §9 Phase P3 — replay determinism: the SAME journal (with its
    /// literal minted ids) replays to the SAME document TWICE. This is the heart
    /// of the value-in-op id strategy: even though the original mint was entropic,
    /// replay is a pure deterministic function of the recorded journal (no
    /// entropy / no collision-retry on the op_apply path). Covers BOTH id-minting
    /// verbs.
    #[test]
    fn operation_artboard_create_duplicate_replay_is_deterministic() {
        for fixture in &[
            "operations/artboard_create.json",
            "operations/artboard_duplicate.json",
        ] {
            let json_str = read_fixture(fixture);
            let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();
            for tc in tests.as_array().unwrap() {
                let model = run_operation_model(tc);
                let setup = tc["setup_svg"].as_str().unwrap();
                let head = model.journal_head();
                let replay1 = replay_journal(setup, model.journal(), head);
                let replay2 = replay_journal(setup, model.journal(), head);
                assert_eq!(
                    replay1, replay2,
                    "replay of '{}' is non-deterministic (op_apply must never \
                     mint/tap entropy on the id-minting verbs)",
                    tc["name"].as_str().unwrap()
                );
            }
        }
    }

    // ---------------------------------------------------------------
    // Workspace layout equivalence tests
    // (requires "web" feature for workspace module)
    // ---------------------------------------------------------------

    #[cfg(feature = "web")]
    use crate::workspace::test_json::{
        workspace_to_test_json, test_json_to_workspace,
        toolbar_structure_json, menu_structure_json,
        state_defaults_json, shortcut_structure_json,
    };
    #[cfg(feature = "web")]
    use crate::workspace::workspace::WorkspaceLayout;

    #[cfg(feature = "web")]
    fn assert_workspace_fixture(name: &str, json: &str) {
        let expected = read_fixture(&format!("expected/{}.json", name));
        let expected = expected.trim();
        if json != expected {
            eprintln!("=== EXPECTED ({}) ===", name);
            eprintln!("{}", expected);
            eprintln!("=== ACTUAL ({}) ===", name);
            eprintln!("{}", json);
            panic!("Workspace test '{}' failed: canonical JSON mismatch", name);
        }
    }

    #[cfg(feature = "web")]
    #[test]
    fn workspace_default_layout() {
        let layout = WorkspaceLayout::default_layout();
        let json = workspace_to_test_json(&layout);
        assert_workspace_fixture("workspace_default", &json);
    }

    #[cfg(feature = "web")]
    #[test]
    fn workspace_default_with_panes() {
        let mut layout = WorkspaceLayout::default_layout();
        layout.ensure_pane_layout(1200.0, 800.0);
        let json = workspace_to_test_json(&layout);
        assert_workspace_fixture("workspace_default_with_panes", &json);
    }

    #[cfg(feature = "web")]
    #[test]
    fn workspace_json_roundtrip() {
        for name in &["workspace_default", "workspace_default_with_panes"] {
            let fixture = read_fixture(&format!("expected/{}.json", name));
            let fixture = fixture.trim();
            let parsed = test_json_to_workspace(fixture);
            let reserialized = workspace_to_test_json(&parsed);
            assert_eq!(fixture, reserialized,
                "Workspace JSON roundtrip failed for '{}'", name);
        }
    }

    // ---------------------------------------------------------------
    // Workspace operation equivalence tests
    // ---------------------------------------------------------------

    #[cfg(feature = "web")]
    use crate::workspace::workspace::{
        DockId, GroupAddr, PanelAddr, PanelKind, PaneId, PaneKind,
    };

    #[cfg(feature = "web")]
    fn parse_panel_kind(s: &str) -> PanelKind {
        match s {
            "color" => PanelKind::Color,
            "swatches" => PanelKind::Swatches,
            "stroke" => PanelKind::Stroke,
            "properties" => PanelKind::Properties,
            _ => PanelKind::Layers,
        }
    }

    #[cfg(feature = "web")]
    fn parse_pane_kind(s: &str) -> PaneKind {
        match s {
            "toolbar" => PaneKind::Toolbar,
            "dock" => PaneKind::Dock,
            _ => PaneKind::Canvas,
        }
    }

    #[cfg(feature = "web")]
    fn apply_workspace_op(layout: &mut WorkspaceLayout, op: &serde_json::Value) {
        let name = op["op"].as_str().unwrap();
        match name {
            // Panel/dock operations
            "toggle_group_collapsed" => {
                layout.toggle_group_collapsed(GroupAddr {
                    dock_id: DockId(op["dock_id"].as_u64().unwrap() as usize),
                    group_idx: op["group_idx"].as_u64().unwrap() as usize,
                });
            }
            "set_active_panel" => {
                layout.set_active_panel(PanelAddr {
                    group: GroupAddr {
                        dock_id: DockId(op["dock_id"].as_u64().unwrap() as usize),
                        group_idx: op["group_idx"].as_u64().unwrap() as usize,
                    },
                    panel_idx: op["panel_idx"].as_u64().unwrap() as usize,
                });
            }
            "close_panel" => {
                layout.close_panel(PanelAddr {
                    group: GroupAddr {
                        dock_id: DockId(op["dock_id"].as_u64().unwrap() as usize),
                        group_idx: op["group_idx"].as_u64().unwrap() as usize,
                    },
                    panel_idx: op["panel_idx"].as_u64().unwrap() as usize,
                });
            }
            "show_panel" => {
                let kind = parse_panel_kind(op["kind"].as_str().unwrap());
                layout.show_panel(kind);
            }
            "reorder_panel" => {
                layout.reorder_panel(
                    GroupAddr {
                        dock_id: DockId(op["dock_id"].as_u64().unwrap() as usize),
                        group_idx: op["group_idx"].as_u64().unwrap() as usize,
                    },
                    op["from"].as_u64().unwrap() as usize,
                    op["to"].as_u64().unwrap() as usize,
                );
            }
            "move_panel_to_group" => {
                layout.move_panel_to_group(
                    PanelAddr {
                        group: GroupAddr {
                            dock_id: DockId(op["from_dock_id"].as_u64().unwrap() as usize),
                            group_idx: op["from_group_idx"].as_u64().unwrap() as usize,
                        },
                        panel_idx: op["from_panel_idx"].as_u64().unwrap() as usize,
                    },
                    GroupAddr {
                        dock_id: DockId(op["to_dock_id"].as_u64().unwrap() as usize),
                        group_idx: op["to_group_idx"].as_u64().unwrap() as usize,
                    },
                );
            }
            "detach_group" => {
                layout.detach_group(
                    GroupAddr {
                        dock_id: DockId(op["dock_id"].as_u64().unwrap() as usize),
                        group_idx: op["group_idx"].as_u64().unwrap() as usize,
                    },
                    op["x"].as_f64().unwrap(),
                    op["y"].as_f64().unwrap(),
                );
            }
            "redock" => {
                layout.redock(DockId(op["dock_id"].as_u64().unwrap() as usize));
            }
            // Pane operations
            "set_pane_position" => {
                let pl = layout.pane_layout.as_mut().unwrap();
                pl.set_pane_position(
                    PaneId(op["pane_id"].as_u64().unwrap() as usize),
                    op["x"].as_f64().unwrap(),
                    op["y"].as_f64().unwrap(),
                );
            }
            "tile_panes" => {
                let pl = layout.pane_layout.as_mut().unwrap();
                pl.tile_panes(None);
            }
            "toggle_canvas_maximized" => {
                let pl = layout.pane_layout.as_mut().unwrap();
                pl.toggle_canvas_maximized();
            }
            "resize_pane" => {
                let pl = layout.pane_layout.as_mut().unwrap();
                pl.resize_pane(
                    PaneId(op["pane_id"].as_u64().unwrap() as usize),
                    op["width"].as_f64().unwrap(),
                    op["height"].as_f64().unwrap(),
                );
            }
            "hide_pane" => {
                let pl = layout.pane_layout.as_mut().unwrap();
                let kind = parse_pane_kind(op["kind"].as_str().unwrap());
                pl.hide_pane(kind);
            }
            "show_pane" => {
                let pl = layout.pane_layout.as_mut().unwrap();
                let kind = parse_pane_kind(op["kind"].as_str().unwrap());
                pl.show_pane(kind);
            }
            "bring_pane_to_front" => {
                let pl = layout.pane_layout.as_mut().unwrap();
                pl.bring_pane_to_front(PaneId(op["pane_id"].as_u64().unwrap() as usize));
            }
            _ => panic!("Unknown workspace op: {}", name),
        }
    }

    #[cfg(feature = "web")]
    fn run_workspace_operation_test(tc: &serde_json::Value) -> String {
        let setup_name = tc["setup"].as_str().unwrap();
        let setup_json = read_fixture(&format!("expected/{}", setup_name));
        let mut layout = test_json_to_workspace(setup_json.trim());

        for op in tc["ops"].as_array().unwrap() {
            apply_workspace_op(&mut layout, op);
        }

        workspace_to_test_json(&layout)
    }

    #[cfg(feature = "web")]
    fn assert_workspace_operation_test(tc: &serde_json::Value) {
        let name = tc["name"].as_str().unwrap();
        let expected_file = tc["expected_json"].as_str().unwrap();
        let expected = read_fixture(&format!("workspace_operations/{}", expected_file));
        let expected = expected.trim();
        let actual = run_workspace_operation_test(tc);

        if actual != expected {
            eprintln!("=== EXPECTED ({}) ===", name);
            eprintln!("{}", expected);
            eprintln!("=== ACTUAL ({}) ===", name);
            eprintln!("{}", actual);
            panic!("Workspace operation test '{}' failed: canonical JSON mismatch", name);
        }
    }

    #[cfg(feature = "web")]
    fn run_workspace_operation_fixture(fixture: &str) {
        let json_str = read_fixture(fixture);
        let tests: serde_json::Value = serde_json::from_str(&json_str)
            .unwrap_or_else(|e| panic!("Failed to parse {}: {}", fixture, e));
        for tc in tests.as_array().unwrap() {
            assert_workspace_operation_test(tc);
        }
    }

    /// Bootstrap: generate expected JSON for workspace operation tests.
    #[cfg(feature = "web")]
    #[test]
    #[ignore]
    fn generate_workspace_operation_expected() {
        for fixture in &["workspace_operations/panel_ops.json",
                         "workspace_operations/pane_ops.json"] {
            let json_str = read_fixture(fixture);
            let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();

            for tc in tests.as_array().unwrap() {
                let name = tc["name"].as_str().unwrap();
                let expected_file = tc["expected_json"].as_str().unwrap();
                let actual = run_workspace_operation_test(tc);
                let path = format!("{}/workspace_operations/{}", FIXTURES, expected_file);
                std::fs::write(&path, &actual)
                    .unwrap_or_else(|e| panic!("Failed to write {}: {}", path, e));
                eprintln!("Generated: {} -> {}", name, expected_file);
            }
        }
    }

    #[cfg(feature = "web")]
    #[test]
    fn workspace_panel_ops() {
        run_workspace_operation_fixture("workspace_operations/panel_ops.json");
    }

    #[cfg(feature = "web")]
    #[test]
    fn workspace_pane_ops() {
        run_workspace_operation_fixture("workspace_operations/pane_ops.json");
    }

    // ---------------------------------------------------------------
    // Pane geometry algorithm test vectors
    // ---------------------------------------------------------------

    #[cfg(feature = "web")]
    use crate::workspace::pane::{Pane, PaneConfig, EdgeSide};

    #[cfg(feature = "web")]
    fn parse_edge_side(s: &str) -> EdgeSide {
        match s {
            "right" => EdgeSide::Right,
            "top" => EdgeSide::Top,
            "bottom" => EdgeSide::Bottom,
            _ => EdgeSide::Left,
        }
    }

    #[cfg(feature = "web")]
    #[test]
    fn algorithm_pane_geometry_vectors() {
        use crate::workspace::pane::PaneLayout;

        let json_str = read_fixture("algorithms/pane_geometry.json");
        let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();

        for tc in tests.as_array().unwrap() {
            let name = tc["name"].as_str().unwrap();
            let func = tc["function"].as_str().unwrap();
            let args = &tc["args"];
            let expected = tc["expected"].as_f64().unwrap();

            let actual = match func {
                "pane_edge_coord" => {
                    let pane = Pane {
                        id: PaneId(0),
                        kind: PaneKind::Canvas,
                        config: PaneConfig::default(),
                        x: args["x"].as_f64().unwrap(),
                        y: args["y"].as_f64().unwrap(),
                        width: args["width"].as_f64().unwrap(),
                        height: args["height"].as_f64().unwrap(),
                    };
                    let edge = parse_edge_side(args["edge"].as_str().unwrap());
                    PaneLayout::pane_edge_coord(&pane, edge)
                }
                _ => panic!("Unknown function: {}", func),
            };

            assert!((actual - expected).abs() < 0.0001,
                "Pane geometry '{}' failed: expected {}, got {}", name, expected, actual);
        }
    }

    // ---------------------------------------------------------------
    // Toolbar and menu structure tests
    // ---------------------------------------------------------------

    #[cfg(feature = "web")]
    #[test]
    fn toolbar_structure() {
        let json = toolbar_structure_json();
        assert_workspace_fixture("toolbar_structure", &json);
    }

    #[cfg(feature = "web")]
    #[test]
    fn menu_structure() {
        let json = menu_structure_json();
        assert_workspace_fixture("menu_structure", &json);
    }

    #[cfg(feature = "web")]
    #[test]
    fn state_defaults() {
        let json = state_defaults_json();
        assert_workspace_fixture("state_defaults", &json);
    }

    #[cfg(feature = "web")]
    #[test]
    fn shortcut_structure() {
        let json = shortcut_structure_json();
        assert_workspace_fixture("shortcut_structure", &json);
    }
}
