//! Cross-language equivalence tests.
//!
//! These tests read shared fixtures from `test_fixtures/` at the
//! repository root.  All four language implementations run the same
//! fixtures, so passing here means the Rust implementation agrees with
//! the canonical expected values.

#[cfg(test)]
mod tests {
    use crate::algorithms::hit_test;
    use crate::document::controller::Controller;
    use crate::document::document::ElementPath;
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

    fn apply_op(model: &mut Model, op: &serde_json::Value) {
        let name = op["op"].as_str().unwrap();
        match name {
            "select_rect" => {
                Controller::select_rect(
                    model,
                    op["x"].as_f64().unwrap(),
                    op["y"].as_f64().unwrap(),
                    op["width"].as_f64().unwrap(),
                    op["height"].as_f64().unwrap(),
                    op["extend"].as_bool().unwrap_or(false),
                );
            }
            "move_selection" => {
                Controller::move_selection(
                    model,
                    op["dx"].as_f64().unwrap(),
                    op["dy"].as_f64().unwrap(),
                );
            }
            "copy_selection" => {
                Controller::copy_selection(
                    model,
                    op["dx"].as_f64().unwrap(),
                    op["dy"].as_f64().unwrap(),
                );
            }
            "assign_id" => {
                let path: ElementPath = op["path"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|i| i.as_u64().unwrap() as usize)
                    .collect();
                Controller::assign_id(model, &path, op["id"].as_str().unwrap());
            }
            "create_reference" => {
                let target_path: ElementPath = op["target_path"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|i| i.as_u64().unwrap() as usize)
                    .collect();
                Controller::create_reference(
                    model,
                    &target_path,
                    op["target_id"].as_str().unwrap(),
                    op["ref_id"].as_str().unwrap(),
                );
            }
            // Symbols P2 operations (SYMBOLS.md §7). Value-in-op: the ids and
            // paths are read literally from the fixture payload, exactly like
            // the create_reference arm.
            "make_symbol" => {
                let path: ElementPath = op["path"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|i| i.as_u64().unwrap() as usize)
                    .collect();
                Controller::make_symbol(
                    model,
                    &path,
                    op["master_id"].as_str().unwrap(),
                    op["ref_id"].as_str().unwrap(),
                );
            }
            "place_instance" => {
                Controller::place_instance(
                    model,
                    op["master_id"].as_str().unwrap(),
                    op["ref_id"].as_str().unwrap(),
                );
            }
            "detach" => {
                let path: ElementPath = op["path"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|i| i.as_u64().unwrap() as usize)
                    .collect();
                Controller::detach(model, &path);
            }
            "redefine" => {
                let path: ElementPath = op["path"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|i| i.as_u64().unwrap() as usize)
                    .collect();
                Controller::redefine(
                    model,
                    op["master_id"].as_str().unwrap(),
                    &path,
                    op["ref_id"].as_str().unwrap(),
                );
            }
            "delete_symbol" => {
                Controller::delete_symbol(
                    model,
                    op["master_id"].as_str().unwrap(),
                );
            }
            // Symbols P4 (SYMBOLS.md §4 / Fork F2). Value-in-op: the instance
            // transform is carried in the payload as {a,b,c,d,e,f} (the same
            // matrix shape parsed elsewhere) and applied verbatim.
            "set_instance_transform" => {
                let path: ElementPath = op["path"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|i| i.as_u64().unwrap() as usize)
                    .collect();
                let t = &op["transform"];
                let transform = crate::geometry::element::Transform {
                    a: t["a"].as_f64().unwrap(),
                    b: t["b"].as_f64().unwrap(),
                    c: t["c"].as_f64().unwrap(),
                    d: t["d"].as_f64().unwrap(),
                    e: t["e"].as_f64().unwrap(),
                    f: t["f"].as_f64().unwrap(),
                };
                Controller::set_instance_transform(model, &path, transform);
            }
            "delete_selection" => {
                let new_doc = model.document().delete_selection();
                model.set_document(new_doc);
            }
            "lock_selection" => {
                Controller::lock_selection(model);
            }
            "unlock_all" => {
                Controller::unlock_all(model);
            }
            "hide_selection" => {
                Controller::hide_selection(model);
            }
            "show_all" => {
                Controller::show_all(model);
            }
            "set_character_attribute" => {
                let path: ElementPath = op["path"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|i| i.as_u64().unwrap() as usize)
                    .collect();
                Controller::set_character_attribute(
                    model,
                    &path,
                    op["char_start"].as_u64().unwrap() as usize,
                    op["char_end"].as_u64().unwrap() as usize,
                    op["attribute"].as_str().unwrap(),
                    op["value"].as_str().unwrap(),
                );
            }
            "snapshot" => {
                model.snapshot();
            }
            "undo" => {
                model.undo();
            }
            "redo" => {
                model.redo();
            }
            _ => panic!("Unknown op: {}", name),
        }
    }

    fn run_operation_test(tc: &serde_json::Value) -> String {
        let setup_svg = read_fixture(&format!("svg/{}", tc["setup_svg"].as_str().unwrap()));
        let doc = svg_to_document(&setup_svg);
        let mut model = Model::new(doc, None);

        for op in tc["ops"].as_array().unwrap() {
            apply_op(&mut model, op);
        }

        document_to_test_json(model.document())
    }

    fn assert_operation_test(tc: &serde_json::Value) {
        let name = tc["name"].as_str().unwrap();
        let expected_file = tc["expected_json"].as_str().unwrap();
        let expected = read_fixture(&format!("operations/{}", expected_file));
        let expected = expected.trim();
        let actual = run_operation_test(tc);

        if actual != expected {
            eprintln!("=== EXPECTED ({}) ===", name);
            eprintln!("{}", expected);
            eprintln!("=== ACTUAL ({}) ===", name);
            eprintln!("{}", actual);
            panic!("Operation test '{}' failed: canonical JSON mismatch", name);
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
                         "operations/symbols_ops.json"] {
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
