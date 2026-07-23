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
            // Tspan-bearing text fixtures (TSPAN.md): styled runs + xml:space
            // content round-trip through test_json. Mirrors the Swift
            // jsonRoundtripAllExpected registration.
            "text_with_tspans", "text_path_with_tspans", "text_xml_space_preserve",
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
            // Tspan-bearing text fixtures (TSPAN.md): styled runs + xml:space
            // content round-trip through the binary codec (self-roundtrip
            // only; no Python-generated .bin exists for these). Mirrors the
            // Swift binaryRoundtripAllExpected registration.
            "text_with_tspans", "text_path_with_tspans", "text_xml_space_preserve",
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

    /// Shared op-dispatch envelope spanning the two harness op vocabularies
    /// (OP_LOG.md §2 Fork 5 / §12, "Layout-op unification"). It pins, at the
    /// TRAIT level, the contract that document ops and layout ops share — the
    /// `parse -> apply -> serialize` envelope — so a THIRD op vocabulary cannot
    /// entrench as yet another bespoke driver: a new world conforms to `OpWorld`
    /// and reuses the unified runner below.
    ///
    /// Deliberately generic-over-`State` (NOT a `dyn` object): the two state
    /// types — `Model` and `WorkspaceLayout` — are genuinely different and MUST
    /// NOT merge. The trait spans ONLY the per-op envelope; the journal /
    /// transaction brackets / undo / `checkpoint_equivalence` gate stay
    /// DOCUMENT-ONLY on `Model` (in `run_operation_model` / `assert_operation_test`)
    /// and are intentionally NOT on the trait — removing `OpWorld` would leave
    /// document journaling/undo/gate byte-for-byte unchanged and would not
    /// require layout to invent ids/journal/undo.
    ///
    /// Markers are zero-sized and never instantiated; the methods are
    /// associated functions keyed off the marker type parameter `W`.
    trait OpWorld {
        /// The mutable state one op is applied to (`Model` or `WorkspaceLayout`).
        type State;
        /// Apply one primitive op to the state. Returns the op's resolved
        /// `targets` (Fork 4 merge metadata). The unified runner does not
        /// consume the return — the document world's targets already live in
        /// the journal (read there by the gate), and the layout world has no
        /// `common.id` targets — so both impls honestly return `Vec::new()`;
        /// the return is part of the trait shape for a future third vocabulary.
        fn apply(state: &mut Self::State, op: &serde_json::Value) -> Vec<String>;
        /// Serialize the state to canonical, byte-comparable test JSON.
        fn to_test_json(state: &Self::State) -> String;
        /// The op verbs this world dispatches (documentation / introspection;
        /// lets the trait-level test assert each world's vocabulary is wired).
        fn verbs() -> &'static [&'static str];
    }

    /// Document op vocabulary (OP_LOG.md §4). `State = Model`; `apply` delegates
    /// to the production `op_apply` dispatcher unchanged (so the journal,
    /// `record_op` site, and `targets` are byte-identical to the runtime path),
    /// then returns `Vec::new()` — the targets already live on the just-recorded
    /// op in the journal, where the `checkpoint_equivalence` gate reads them, so
    /// surfacing them again here would be redundant and is deliberately avoided
    /// to keep `op_apply`'s signature/behavior untouched.
    struct DocumentOps;
    impl OpWorld for DocumentOps {
        type State = Model;
        fn apply(model: &mut Model, op: &serde_json::Value) -> Vec<String> {
            let result = crate::document::op_apply::op_apply(model, op);
            assert_op_result(op, result);
            Vec::new()
        }
        fn to_test_json(model: &Model) -> String {
            document_to_test_json(model.document())
        }
        fn verbs() -> &'static [&'static str] {
            // Indicative document verbs (the operations/*.json corpus is the
            // exhaustive contract); enough to assert the world is wired.
            &["snapshot", "undo", "redo", "set_attr", "delete_at", "insert_at"]
        }
    }

    /// The ONE generic op-test runner (OP_LOG.md §2 Fork 5 / §12): apply each op
    /// in `ops` to `state` via `W::apply`, then serialize via `W::to_test_json`.
    /// This is the single dispatch+serialize core both the document and the
    /// layout fixture paths share — the near-identical shape the two drivers
    /// (`run_operation_test` and `run_workspace_operation_test`) previously
    /// duplicated. Document-only concerns — the begin/commit transaction
    /// brackets and the `checkpoint_equivalence` gate — stay in the document
    /// driver (`run_operation_model` / `assert_operation_test`) AROUND this core,
    /// not on the trait; the layout driver calls it directly.
    fn run_ops_test<W: OpWorld>(state: &mut W::State, ops: &[serde_json::Value]) -> String {
        for op in ops {
            let _targets = W::apply(state, op);
        }
        W::to_test_json(state)
    }

    /// The S3 error-channel contract, asserted on every fixture op the harness
    /// dispatches: an op carrying `expected_error` (the bare class name, e.g.
    /// `"MissingTarget"`) must Err with exactly that class; an op without it
    /// must be Ok. Detail payloads (param names / ids) are diagnostics only —
    /// the cross-language assertion is the class name string.
    fn assert_op_result(
        op: &serde_json::Value,
        result: Result<(), crate::document::op_apply::OpError>,
    ) {
        let verb = op["op"].as_str().unwrap_or("<no-verb>");
        match op.get("expected_error").and_then(|v| v.as_str()) {
            Some(expected) => match result {
                Err(e) => assert_eq!(
                    e.class_name(),
                    expected,
                    "op '{verb}': expected error class {expected}, got {e}"
                ),
                Ok(()) => panic!("op '{verb}': expected error class {expected}, got Ok"),
            },
            None => {
                if let Err(e) = result {
                    panic!("op '{verb}' unexpectedly errored: {e}");
                }
            }
        }
    }

    /// Thin harness shim over the production dispatcher (OP_LOG.md §9,
    /// Increment 3b-B): both the `#[cfg(test)]` cross-language harness and the
    /// production effect path go through the SAME `op_apply` module and the SAME
    /// `record_op` site, so this lift is behavior-preserving (the operations
    /// fixtures stay byte-green) and `targets` is recorded identically on both
    /// paths. Promoting the dispatcher out of `#[cfg(test)]` also hardened its
    /// param parsing so production input can't panic. The envelope additionally
    /// asserts the S3 error-channel contract per op (`assert_op_result`).
    fn apply_op(model: &mut Model, op: &serde_json::Value) {
        // Route through the shared `OpWorld` envelope so the document dispatch
        // path and the unified runner are the SAME code (DocumentOps::apply
        // delegates to `op_apply` unchanged). targets live in the journal.
        let _ = <DocumentOps as OpWorld>::apply(model, op);
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
            // Flat-`ops` form: one implicit outer transaction. The per-op
            // dispatch + serialize goes through the unified `run_ops_test`
            // runner (shared with the layout world); the begin/commit brackets
            // are the DOCUMENT-ONLY concern that wraps it. The returned JSON is
            // discarded here — `assert_operation_test` re-serializes the model
            // it owns, after which the gate replays the journal — but routing
            // the apply loop through `run_ops_test` puts the shared runner on
            // the live document path on every build configuration.
            model.begin_txn();
            let _ = run_ops_test::<DocumentOps>(&mut model, tc["ops"].as_array().unwrap());
            model.commit_txn();
        }
        model
    }

    fn run_operation_test(tc: &serde_json::Value) -> String {
        <DocumentOps as OpWorld>::to_test_json(&run_operation_model(tc))
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
                // S3 strengthening: journals only ever contain succeeded ops,
                // so every replayed op must be Ok (an Err here means an op that
                // was rejected at apply time somehow reached record_op — a
                // broken Err⇔skipped-before-record_op invariant).
                crate::document::op_apply::op_apply(&mut model, &op.params)
                    .unwrap_or_else(|e| {
                        panic!(
                            "journal replay: op '{}' errored ({e}) — journals \
                             only contain succeeded ops",
                            op.op
                        )
                    });
            }
        }
        <DocumentOps as OpWorld>::to_test_json(&model)
    }

    fn assert_operation_test(tc: &serde_json::Value) {
        let name = tc["name"].as_str().unwrap();
        let expected_file = tc["expected_json"].as_str().unwrap();
        let expected = read_fixture(&format!("operations/{}", expected_file));
        let expected = expected.trim();
        let model = run_operation_model(tc);
        let actual = <DocumentOps as OpWorld>::to_test_json(&model);

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
                         "operations/unpack_group_at.json",
                         "operations/set_attr_on_selection.json",
                         "operations/transform_scale.json",
                         "operations/transform_rotate.json",
                         "operations/transform_shear.json",
                         "operations/transform_copy.json",
                         "operations/id_primary_move.json",
                         "operations/id_primary_copy.json"] {
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

    // ===============================================================
    // GESTURE equivalence corpus (mirrors the OPERATION corpus above,
    // but drives the CanvasTool seam — raw pointer events through a
    // YamlTool — instead of op_apply). A gesture fixture replays a
    // sequence of pointer events against a tool built from the
    // workspace spec and serializes the resulting document.
    //
    // Identity-view convention: the model is loaded with the default
    // (identity) view, so the event x/y ARE document coordinates
    // (pointer_event_payload computes doc_x == x when zoom == 1 and
    // view_offset == 0). shift/alt default to false; `dragging`
    // defaults to false on move events.
    //
    // Self-bracketing: each tool that mutates the document does its
    // own `doc.snapshot` (see e.g. rect.yaml's on_mouseup), so the
    // gesture runner does NOT wrap events in begin_txn/commit_txn —
    // unlike the operation runner, which owns the transaction bracket.
    // ===============================================================

    /// The list of gesture fixture files under `test_fixtures/gestures/`.
    /// Inc-1 seeded the rectangle-draw gesture; inc-2 adds the remaining
    /// press-drag-release draw tools (line / ellipse / rounded_rect /
    /// polygon / star).
    const GESTURE_FIXTURES: &[&str] = &[
        "draw_rect.json",
        "draw_line.json",
        "draw_ellipse.json",
        "draw_rounded_rect.json",
        "draw_polygon.json",
        "draw_star.json",
        // First SELECTION-family gesture (TESTING_STRATEGY.md §5 rec 4):
        // a click-select. Unlike the draw tools, the selection tool's
        // on_mousedown HIT-TESTS — it resolves the top-most element whose
        // bounds contain the press point (doc-space, headless, deterministic
        // via doc_primitives::hit_test) and sets the selection from it. The
        // press point (36,36) is dead-center of the first rect in
        // two_rects.svg (doc-bounds 0..72 in both axes after the 0.75 px->pt
        // import scale), unambiguously inside its bounds and 36 units clear of
        // the second rect (which starts at doc-x 72). No geometry changes; only
        // the selection becomes [{kind:"all", path:[0,0]}].
        "select_click.json",
        // Marquee-select (TESTING_STRATEGY.md §5 rec 4): the other half of
        // the selection tool. When on_mousedown hit-tests to NULL (press on
        // empty space, here doc(-10,-10), outside both rects) the tool enters
        // MARQUEE mode, recording doc_marquee_start/end; on_mousemove updates
        // the end; on_mouseup commits via doc.select_in_rect with the
        // min/max-normalized marquee bounds. The marquee here drags to
        // doc(200,100), fully enclosing BOTH rects (doc-bounds 0..144 x
        // 0..72) — so the contain-vs-intersect semantics of select_in_rect
        // don't matter, and the result is unambiguously both elements:
        // [{kind:"all", path:[0,0]}, {kind:"all", path:[0,1]}].
        "select_marquee.json",
        // Blob Brush paint with an app-level fill precondition (the
        // hollow-blob regression gate). The case sets `app_state`:
        // {fill_color:#ff0000, blob_brush_size:10}, which the runner
        // routes through the production CanvasTool::sync_global_state
        // bridge before the gesture — exactly as the canvas does. The
        // committed Path MUST carry fill=red; before the bridge existed
        // the blob committed fill=null (hollow). Pins the white/null fill
        // contract cross-language. See BLOB_BRUSH_TOOL.md.
        "blob_paint_fill.json",
        // Paintbrush paint with app-level options (the paintbrush_*
        // disconnect gate). app_state sets paintbrush_fidelity:3 (=>
        // fit_error 5.0, a SMOOTHED fit) + paintbrush_fill_new_strokes:true
        // + fill_color, routed through sync_global_state. The committed
        // Path must be filled blue AND smoothed; before the paintbrush_*
        // keys were bridged the live tool used fit_error=0 (no smoothing)
        // and dropped the fill. See PAINTBRUSH_TOOL.md.
        "paintbrush_paint_fill.json",
        "recorded_rect.json",
        "recorded_rect_panzoom.json",
    ];

    /// Run a gesture fixture and return the resulting Model. Resolves
    /// the fixture's `setup_svg` file reference, then delegates to the
    /// SHARED corpus replay path (`recorder::replay::run_gesture_case`)
    /// — the same code the recorder's record-stop fidelity check and
    /// the `corpus_replay` bin run, so corpus replay and recording
    /// verification can never drift apart.
    fn run_gesture_model(tc: &serde_json::Value) -> Model {
        let setup_svg = read_fixture(&format!("svg/{}", tc["setup_svg"].as_str().unwrap()));
        crate::recorder::replay::run_gesture_case(tc, &setup_svg)
    }

    fn run_gesture_test(tc: &serde_json::Value) -> String {
        document_to_test_json(run_gesture_model(tc).document())
    }

    /// Mirror of `assert_operation_test`: replay the gesture and compare
    /// the canonical document JSON against the pinned golden, dumping
    /// EXPECTED/ACTUAL on mismatch.
    fn assert_gesture_test(tc: &serde_json::Value) {
        let name = tc["name"].as_str().unwrap();
        let expected_file = tc["expected_json"].as_str().unwrap();
        let expected = read_fixture(&format!("gestures/{}", expected_file));
        let expected = expected.trim();
        let actual = run_gesture_test(tc);

        if actual != expected {
            eprintln!("=== EXPECTED ({}) ===", name);
            eprintln!("{}", expected);
            eprintln!("=== ACTUAL ({}) ===", name);
            eprintln!("{}", actual);
            panic!("Gesture test '{}' failed: canonical JSON mismatch", name);
        }
    }

    #[test]
    fn gesture_corpus() {
        for fixture in GESTURE_FIXTURES {
            let json_str = read_fixture(&format!("gestures/{}", fixture));
            let tests: serde_json::Value = serde_json::from_str(&json_str)
                .unwrap_or_else(|e| panic!("gesture fixture {} is not valid JSON: {}", fixture, e));
            for tc in tests.as_array().unwrap() {
                assert_gesture_test(tc);
            }
        }
    }

    /// Bootstrap helper: generate expected JSON for gesture tests.
    /// Run with: cargo test generate_gesture_expected -- --ignored --nocapture
    #[test]
    #[ignore]
    fn generate_gesture_expected() {
        for fixture in GESTURE_FIXTURES {
            let json_str = read_fixture(&format!("gestures/{}", fixture));
            let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();
            for tc in tests.as_array().unwrap() {
                let name = tc["name"].as_str().unwrap();
                let expected_file = tc["expected_json"].as_str().unwrap();
                let actual = run_gesture_test(tc);
                let path = format!("{}/gestures/{}", FIXTURES, expected_file);
                std::fs::write(&path, &actual)
                    .unwrap_or_else(|e| panic!("Failed to write {}: {}", path, e));
                eprintln!("Generated: {} -> {}", name, expected_file);
            }
        }
    }

    // ===============================================================
    // ALT-COPY drag gesture: ONE undo step (regression for the
    // "Ctrl+Z reverts the copy to the option-press position but does
    // not remove it" bug). The Selection tool's alt-drag-copy lays a
    // `copy_selection` op mid-gesture; the per-frame drag coalescer
    // (`try_coalesce_drag_frame`) refuses to bridge across a copy, so
    // the post-copy moves land as a SEPARATE undo step. The whole
    // select->drag->alt->move->release gesture must be exactly ONE
    // undo step: one Ctrl+Z restores the pre-gesture document
    // (original in place, copy gone). Drives the production CanvasTool
    // seam via `run_gesture_model`, then asserts undo on the Model.
    // ---------------------------------------------------------------

    /// Dump the journal (head + per-txn name/verbs) for diagnosis.
    fn dump_journal(label: &str, model: &Model) {
        eprintln!("--- {label}: journal_head={} len={} can_undo={}",
            model.journal_head(), model.journal().len(), model.can_undo());
        for (i, t) in model.journal().iter().enumerate() {
            let ops: Vec<String> = t.ops.iter()
                .map(|o| format!("{}{:?}{}", o.op, o.targets,
                    o.params.get("dx").and_then(|v| v.as_f64())
                        .map(|dx| format!("@dx={dx}")).unwrap_or_default()))
                .collect();
            eprintln!("    [{i}] name={:?} ops={:?}", t.name, ops);
        }
    }

    /// PATH B — Alt pressed MID-drag (the user's exact gesture): drag
    /// the original, then hold Option, then keep dragging the copy,
    /// then release. Must collapse to ONE undo step.
    /// Oracle for the alt-copy undo tests: the document the gesture must undo
    /// back to — rect[0,0] selected, both originals in place, NO copy. Captured
    /// by driving ONLY the selecting press (which selects but commits nothing),
    /// so it includes the post-select selection that the first-move snapshot
    /// captured. (NOT the fresh import, whose selection is empty.)
    fn before_drag_oracle() -> String {
        document_to_test_json(run_gesture_model(&serde_json::json!({
            "setup_svg": "two_rects.svg",
            "tool": "selection",
            "events": [ { "kind": "press", "x": 36, "y": 36 } ]
        })).document())
    }

    #[test]
    fn gesture_alt_mid_drag_copy_is_one_undo_step() {
        // two_rects.svg: rect[0] spans doc 0..72; press (36,36) hits its center.
        let before_drag = before_drag_oracle();

        let tc = serde_json::json!({
            "setup_svg": "two_rects.svg",
            "tool": "selection",
            "events": [
                { "kind": "press",   "x": 36, "y": 36 },
                { "kind": "move",    "x": 50, "y": 36, "dragging": true },
                { "kind": "move",    "x": 60, "y": 36, "dragging": true },
                { "kind": "move",    "x": 60, "y": 36, "dragging": true, "alt": true },
                { "kind": "move",    "x": 80, "y": 36, "dragging": true, "alt": true },
                { "kind": "release", "x": 80, "y": 36, "alt": true }
            ]
        });

        let mut model = run_gesture_model(&tc);
        dump_journal("PATH B after gesture", &model);

        let after = document_to_test_json(model.document());
        assert_ne!(after, before_drag, "the alt-drag must have produced a copy");
        assert!(model.can_undo(), "the gesture committed an undoable transaction");
        assert_eq!(model.journal_head(), 1,
            "select->drag->alt->move->release must be exactly ONE undo step");
        assert_eq!(model.journal().last().and_then(|t| t.ops.last()).map(|o| o.op.as_str()),
            Some("copy_selection"), "the single undo step is the copy");

        model.undo();
        dump_journal("PATH B after 1 undo", &model);
        assert_eq!(document_to_test_json(model.document()), before_drag,
            "one undo must restore the original and remove the copy");
        assert!(!model.can_undo(),
            "after one undo the journal cursor is back at the origin (lock-step)");
        assert_eq!(model.journal_head(), 0, "cursor back at origin");
    }

    /// PATH A — Alt held AT press (drag-to-duplicate from the start).
    #[test]
    fn gesture_alt_at_press_copy_is_one_undo_step() {
        let before_drag = before_drag_oracle();

        let tc = serde_json::json!({
            "setup_svg": "two_rects.svg",
            "tool": "selection",
            "events": [
                { "kind": "press",   "x": 36, "y": 36, "alt": true },
                { "kind": "move",    "x": 50, "y": 36, "dragging": true, "alt": true },
                { "kind": "move",    "x": 60, "y": 36, "dragging": true, "alt": true },
                { "kind": "move",    "x": 80, "y": 36, "dragging": true, "alt": true },
                { "kind": "release", "x": 80, "y": 36, "alt": true }
            ]
        });

        let mut model = run_gesture_model(&tc);
        dump_journal("PATH A after gesture", &model);

        let after = document_to_test_json(model.document());
        assert_ne!(after, before_drag, "the alt-drag must have produced a copy");
        assert!(model.can_undo(), "the gesture committed an undoable transaction");
        assert_eq!(model.journal_head(), 1,
            "alt-at-press drag-to-duplicate must be exactly ONE undo step");
        assert_eq!(model.journal().last().and_then(|t| t.ops.last()).map(|o| o.op.as_str()),
            Some("copy_selection"), "the single undo step is the copy");

        model.undo();
        dump_journal("PATH A after 1 undo", &model);
        assert_eq!(document_to_test_json(model.document()), before_drag,
            "one undo must restore the original and remove the copy");
        assert!(!model.can_undo(), "lock-step: cursor back at origin");
    }

    // ===============================================================
    // ACTION corpus (TESTING_STRATEGY.md §5 rec 2)
    // ---------------------------------------------------------------
    // Sibling to the GESTURE corpus above and the OPERATIONS corpus.
    // Where the gesture corpus drives the canvas-tool seam (press /
    // move / release) and the operation corpus drives op_apply, this
    // corpus drives the ACTION seam: the panel/menu/dialog `action`
    // verbs the UI dispatches, which RESOLVE to ops/effects.
    //
    // Production seam: `dispatch_action(action, params, &mut AppState)`
    // (interpreter/renderer.rs) — the GENERIC action dispatcher the
    // live UI calls for every menu item, panel button, and dialog
    // confirm. It merges the action spec's param defaults, builds the
    // AppState eval context, and runs the action's `effects` through
    // `run_yaml_effects_named` (which threads the action verb as the
    // transaction name). We drive THAT path, not a test-only shortcut,
    // so passing here proves the real production route.
    //
    // Fixture format (test_fixtures/actions/<name>.json) — a JSON
    // array of cases, each:
    //   {
    //     "name":        "<case id>",
    //     "setup_svg":   "<file under test_fixtures/svg/>",
    //     "actions":     [ {"action": "<action_id>",
    //                       "params": { <resolved params> }}, ... ],
    //     "expected_json": "<file under test_fixtures/actions/>"
    //   }
    // Each entry in `actions` is dispatched in order through the
    // production `dispatch_action`. The final document is serialized
    // with `document_to_test_json` and compared to the pinned golden
    // — identical to the gesture corpus's assertion shape.
    //
    // SELECTION SETUP: an action that operates on the selection (e.g.
    // a transform confirm) needs the element selected first. Express
    // that as a LEADING action in the `actions` list — a `select_*`
    // verb the UI itself dispatches — so the whole setup stays on the
    // production dispatch path and inside the journaled-state model
    // (selection is serialized Document state, OP_LOG.md §7). The
    // first seeded case (`toggle_all_layers_visibility`) needs no
    // selection: it folds over ALL top-level layers, so its `actions`
    // list is a single verb with empty params.
    //
    // TRANSACTION BRACKETING: actions self-bracket. A document-
    // mutating action opens its undo transaction via the `snapshot`
    // effect and `run_yaml_effects_named` commits it once at the end
    // (naming it with the action verb). So — exactly like the gesture
    // runner, and UNLIKE the operation runner which owns the bracket —
    // the action runner does NOT wrap dispatch in begin_txn/commit_txn.
    // ===============================================================

    /// The list of action fixture files under `test_fixtures/actions/`.
    /// Inc-1 (foundation) seeds the simplest faithful document-affecting
    /// action: the layers-panel "toggle all layers visibility" verb,
    /// which the existing `toggle_all_layers_visibility_*` unit tests in
    /// renderer.rs already exercise through this same `dispatch_action`
    /// path (the "eye-demo" template §5 calls out).
    const ACTION_FIXTURES: &[&str] = &[
        "toggle_all_layers_visibility.json",
        "toggle_all_layers_lock.json",
        "toggle_all_layers_outline.json",
        // S4 second-branch coverage: each toggle_all_layers_* verb branches on
        // the CURRENT uniform state (any-visible->invisible vs all-invisible->
        // preview, etc.). SVG does not serialize visibility/lock, so the
        // second branch is reached by dispatching the SAME verb twice — the
        // first call establishes the uniform state on the production path, the
        // second exercises the branch the single-toggle fixtures above cannot.
        // (These branches were reference-only pins in workspace/tests/phase3/
        // until these fixtures; the single-toggle fixtures keep the
        // global-no-op trap covered since a no-op dispatcher reds them.)
        "toggle_all_layers_visibility_all_invisible.json",
        "toggle_all_layers_lock_all_locked.json",
        "toggle_all_layers_outline_all_outline.json",
        "new_layer.json",
        "make_compound_shape.json",
        "align.json",
        "boolean.json",
        "new_artboard.json",
        "new_symbol.json",
        "place_instance.json",
        "place_concept_instance.json",
        // Object / Edit menu model-pure verbs (select_all, group, ungroup,
        // ungroup_all, lock, hide_selection, make_instance). These are
        // bespoke-native: their actions.yaml entries are `log` stubs (the
        // real behavior lives in menu_bar.rs's dispatch), so the generic
        // dispatch_action would no-op them. The corpus runner intercepts each
        // verb and routes it to the SAME headless Controller mutation the menu
        // invokes (see run_action_model). Mirrors the Python
        // _MENU_NATIVE_HANDLERS intercept.
        "menu_object_ops.json",
    ];

    /// Run an action fixture and return the resulting `AppState`.
    /// Resolves the fixture's `setup_svg` file reference, then delegates
    /// to the SHARED corpus replay path
    /// (`recorder::replay::run_action_case`) — the same code the
    /// recorder's record-stop fidelity check and the `corpus_replay` bin
    /// run (real `dispatch_action` dispatch, deterministic id source,
    /// selection seeding, menu-native intercepts), so corpus replay and
    /// recording verification can never drift apart.
    fn run_action_model(tc: &serde_json::Value) -> crate::workspace::app_state::AppState {
        let setup_svg = read_fixture(&format!("svg/{}", tc["setup_svg"].as_str().unwrap()));
        crate::recorder::replay::run_action_case(tc, &setup_svg)
    }

    /// Serialize the document the action sequence produced (mirrors
    /// `run_gesture_test`).
    fn run_action_test(tc: &serde_json::Value) -> String {
        let st = run_action_model(tc);
        document_to_test_json(st.tabs[st.active_tab].model.document())
    }

    /// Mirror of `assert_gesture_test`: replay the action sequence and
    /// compare the canonical document JSON against the pinned golden,
    /// dumping EXPECTED/ACTUAL on mismatch.
    fn assert_action_test(tc: &serde_json::Value) {
        let name = tc["name"].as_str().unwrap();
        let expected_file = tc["expected_json"].as_str().unwrap();
        let expected = read_fixture(&format!("actions/{}", expected_file));
        let expected = expected.trim();
        let actual = run_action_test(tc);

        if actual != expected {
            eprintln!("=== EXPECTED ({}) ===", name);
            eprintln!("{}", expected);
            eprintln!("=== ACTUAL ({}) ===", name);
            eprintln!("{}", actual);
            panic!("Action test '{}' failed: canonical JSON mismatch", name);
        }
    }

    #[test]
    fn action_corpus() {
        for fixture in ACTION_FIXTURES {
            let json_str = read_fixture(&format!("actions/{}", fixture));
            let tests: serde_json::Value = serde_json::from_str(&json_str)
                .unwrap_or_else(|e| panic!("action fixture {} is not valid JSON: {}", fixture, e));
            for tc in tests.as_array().unwrap() {
                assert_action_test(tc);
            }
        }
    }

    /// Bootstrap helper: generate expected JSON for action tests.
    /// Run with: cargo test generate_action_expected -- --ignored --nocapture
    #[test]
    #[ignore]
    fn generate_action_expected() {
        for fixture in ACTION_FIXTURES {
            let json_str = read_fixture(&format!("actions/{}", fixture));
            let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();
            for tc in tests.as_array().unwrap() {
                let name = tc["name"].as_str().unwrap();
                let expected_file = tc["expected_json"].as_str().unwrap();
                let actual = run_action_test(tc);
                let path = format!("{}/actions/{}", FIXTURES, expected_file);
                std::fs::write(&path, &actual)
                    .unwrap_or_else(|e| panic!("Failed to write {}: {}", path, e));
                eprintln!("Generated: {} -> {}", name, expected_file);
            }
        }
    }

    // ===============================================================
    // KEY-RESOLUTION corpus (TESTING_STRATEGY.md §5 rec 3)
    // ---------------------------------------------------------------
    // Sibling to the GESTURE and ACTION corpora. Where those drive the
    // canvas-tool seam and the dispatch_action seam, this corpus pins
    // the PURE key→action RESOLUTION step: `resolve_key(chord)` maps a
    // normalized, framework-neutral key chord {key, ctrl, shift, alt,
    // meta} to the bundle `shortcuts` table's {action, params} (or
    // null). The framework event → chord BINDING stays on the manual
    // floor (§5); only resolution is byte-gated here.
    //
    // Unlike the gesture/action corpora the output is NOT a document —
    // it is the resolved command itself, so there is no setup_svg and
    // no dispatch. Each fixture group lists `cases` (a name + chord);
    // the runner resolves every chord against the once-loaded bundle
    // `shortcuts` array and emits a CANONICAL JSON array of
    // {name, result} (sorted object keys, compact) compared to the
    // Rust-generated golden. The canonical serializer (`canon_value`)
    // sorts object keys so the byte comparison is order-independent and
    // identical across the four apps.
    // ===============================================================

    /// Key-resolution fixture files under `test_fixtures/keys/`.
    const KEY_FIXTURES: &[&str] = &["key_resolution.json"];

    /// Resolve every chord in a fixture group against the once-loaded
    /// bundle `shortcuts` table and return the canonical result array.
    /// Delegates to the SHARED corpus replay path
    /// (`recorder::replay::run_key_group_json` — the canonical
    /// serializer `canon_value` and the resolution loop live there),
    /// the same code the recorder ingest generator runs.
    fn run_key_test(group: &serde_json::Value) -> String {
        crate::recorder::replay::run_key_group_json(group)
    }

    /// Replay a key fixture group and compare the canonical result array
    /// against the pinned golden, dumping EXPECTED/ACTUAL on mismatch.
    fn assert_key_test(group: &serde_json::Value) {
        let name = group["name"].as_str().unwrap();
        let expected_file = group["expected_json"].as_str().unwrap();
        let expected = read_fixture(&format!("keys/{}", expected_file));
        let expected = expected.trim();
        let actual = run_key_test(group);
        if actual != expected {
            eprintln!("=== EXPECTED ({}) ===", name);
            eprintln!("{}", expected);
            eprintln!("=== ACTUAL ({}) ===", name);
            eprintln!("{}", actual);
            panic!("Key test '{}' failed: canonical JSON mismatch", name);
        }
    }

    #[test]
    fn key_corpus() {
        for fixture in KEY_FIXTURES {
            let json_str = read_fixture(&format!("keys/{}", fixture));
            let groups: serde_json::Value = serde_json::from_str(&json_str)
                .unwrap_or_else(|e| panic!("key fixture {} is not valid JSON: {}", fixture, e));
            for group in groups.as_array().unwrap() {
                assert_key_test(group);
            }
        }
    }

    /// Bootstrap helper: generate expected JSON for key tests.
    /// Run with: cargo test generate_key_expected -- --ignored --nocapture
    #[test]
    #[ignore]
    fn generate_key_expected() {
        for fixture in KEY_FIXTURES {
            let json_str = read_fixture(&format!("keys/{}", fixture));
            let groups: serde_json::Value = serde_json::from_str(&json_str).unwrap();
            for group in groups.as_array().unwrap() {
                let name = group["name"].as_str().unwrap();
                let expected_file = group["expected_json"].as_str().unwrap();
                let actual = run_key_test(group);
                let path = format!("{}/keys/{}", FIXTURES, expected_file);
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

    /// `OpWorld` trait-level pin for the DOCUMENT world (OP_LOG.md §2 Fork 5 /
    /// §12). Proves `DocumentOps` is genuinely wired through the trait — apply a
    /// known op via `<DocumentOps as OpWorld>::apply` through the unified
    /// `run_ops_test` runner and confirm it produces the SAME canonical JSON as
    /// the direct `op_apply` + `document_to_test_json` path. Behavior-preserving
    /// by construction (the trait delegates to `op_apply`); this is the
    /// trait-level proof that the envelope is identical.
    #[test]
    fn op_world_document_envelope() {
        let setup = read_fixture("svg/two_rects.svg");
        let op = serde_json::json!({"op": "select_rect", "x": -5.0, "y": -5.0,
                                    "width": 55.0, "height": 55.0, "extend": false});

        // Path A: direct op_apply + serialize.
        let doc_a = svg_to_document(&setup);
        let mut model_a = Model::new(doc_a, None);
        model_a.begin_txn();
        crate::document::op_apply::op_apply(&mut model_a, &op)
            .expect("known-good select_rect op must apply Ok");
        model_a.commit_txn();
        let direct = document_to_test_json(model_a.document());

        // Path B: through the unified OpWorld runner.
        let doc_b = svg_to_document(&setup);
        let mut model_b = Model::new(doc_b, None);
        model_b.begin_txn();
        let via_trait = run_ops_test::<DocumentOps>(&mut model_b, std::slice::from_ref(&op));
        model_b.commit_txn();

        assert_eq!(direct, via_trait,
            "OpWorld document envelope diverged from direct op_apply path");
        assert!(!DocumentOps::verbs().is_empty(),
            "DocumentOps::verbs() must advertise the document vocabulary");
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
                crate::document::op_apply::op_apply(&mut replay, &op.params)
                    .expect("journal replay: journals only contain succeeded ops");
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
                    crate::document::op_apply::op_apply(&mut replay, &op.params)
                    .expect("journal replay: journals only contain succeeded ops");
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

    // ---------------------------------------------------------------
    // Per-frame drag coalescing (OP_LOG.md §9 follow-up). A live drag commits
    // ONE transaction PER FRAME (selection.yaml fires doc.snapshot only on the
    // first mousemove; each on_mousemove is its own run_effects batch that
    // begin_txns + commits), so a drag of N frames lands as N consecutive
    // single-op move transactions in the journal — and N undo steps.
    // `Model::commit_txn` coalesces ADJACENT same-gesture move transactions
    // (move_selection / move_by_ids) into ONE summed-delta translate, collapsing
    // the N undo steps into one. The txns-form below commits each frame
    // SEPARATELY, so the SECOND commit triggers coalescing into the first.
    // ---------------------------------------------------------------

    /// The dx/dy of a journal transaction's LAST op (the move being summed).
    fn last_op_delta(txn: &crate::document::op_log::Transaction) -> (f64, f64) {
        let op = txn.ops.last().expect("txn has at least one op");
        (
            op.params.get("dx").and_then(|v| v.as_f64()).unwrap_or(0.0),
            op.params.get("dy").and_then(|v| v.as_f64()).unwrap_or(0.0),
        )
    }

    /// Drive a coalescing fixture (txns-form, each frame committed separately)
    /// and assert the post-coalesce journal shape + undo-step lock-step:
    ///  - the journal collapsed to `expect_journal_txns` transactions;
    ///  - the tip txn's op list is `expect_journal_ops` long (when declared);
    ///  - the tip txn's last move op carries the SUMMED delta (when declared);
    ///  - the undo stack and journal cursor are in lock-step
    ///    (`journal_head == expect_undo_steps`), and undoing exactly that many
    ///    times drains both back to the origin (`can_undo()` false,
    ///    `journal_head == 0`) — i.e. ONE undo reverts a whole coalesced drag.
    fn assert_drag_coalesce(tc: &serde_json::Value) {
        let name = tc["name"].as_str().unwrap();
        let mut model = run_operation_model(tc);

        let expect_txns = tc["expect_journal_txns"].as_u64().unwrap() as usize;
        assert_eq!(
            model.journal().len(), expect_txns,
            "[{name}] journal txn count: expected {expect_txns}, got {}",
            model.journal().len());

        if let Some(ops) = tc.get("expect_journal_ops").and_then(|v| v.as_u64()) {
            let tip = model.journal().last().expect("a tip txn");
            assert_eq!(
                tip.ops.len(), ops as usize,
                "[{name}] tip txn op count: expected {ops}, got {}", tip.ops.len());
        }
        if let Some(dx) = tc.get("expect_last_move_dx").and_then(|v| v.as_f64()) {
            let dy = tc.get("expect_last_move_dy").and_then(|v| v.as_f64()).unwrap_or(0.0);
            let (gdx, gdy) = last_op_delta(model.journal().last().unwrap());
            assert_eq!((gdx, gdy), (dx, dy),
                "[{name}] summed delta: expected ({dx},{dy}), got ({gdx},{gdy})");
        }

        // Undo-step lock-step: journal cursor == undo depth == declared steps.
        let steps = tc["expect_undo_steps"].as_u64().unwrap() as usize;
        assert_eq!(model.journal_head(), steps,
            "[{name}] journal_head (== undo steps): expected {steps}, got {}",
            model.journal_head());
        for i in 0..steps {
            assert!(model.can_undo(), "[{name}] expected to undo step {i}");
            model.undo();
        }
        assert!(!model.can_undo(),
            "[{name}] after {steps} undos the undo stack must be empty (lock-step)");
        assert_eq!(model.journal_head(), 0,
            "[{name}] after {steps} undos the journal cursor must be at the origin");
    }

    /// (a)/(c)-twin coalescing pins + (c)-via-name/copy break pins, driven from
    /// the shared `drag_coalesce.json` fixture (txns-form, cross-language).
    #[test]
    fn drag_coalesce() {
        let json_str = read_fixture("operations/drag_coalesce.json");
        let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();
        for tc in tests.as_array().unwrap() {
            assert_drag_coalesce(tc);
        }
    }

    /// (b) NET-ZERO whole-drag: a same-name same-target run that sums to (0,0)
    /// AND round-trips the document leaves NO journal entry and NO undo step.
    ///
    /// The selection is pre-established OUT OF BAND (non-undoable
    /// `Controller::select_rect`, journaling nothing) so the two move frames are
    /// the ONLY journaled transactions — and after the net-zero drop the journal
    /// is genuinely EMPTY and the document is byte-identical to pre-drag.
    #[test]
    fn drag_coalesce_net_zero() {
        use crate::document::controller::Controller;
        let setup = read_fixture("svg/eye.svg");
        let mut model = Model::new(svg_to_document(&setup), None);

        // Pre-select the eye out of band (no journal entry, no undo step).
        Controller::select_rect(&mut model, -5.0, -5.0, 55.0, 55.0, false);
        let pre_drag = document_to_test_json(model.document());
        assert!(model.journal().is_empty(),
            "out-of-band select must not journal");
        assert!(!model.can_undo(), "out-of-band select must not push an undo step");

        // Frame 1: move dx:5 (commits one txn into the empty journal).
        model.begin_txn();
        model.name_txn("selection on_mousemove");
        apply_op(&mut model, &serde_json::json!({"op": "move_selection", "dx": 5, "dy": 0}));
        model.commit_txn();
        assert_eq!(model.journal().len(), 1, "frame 1 journals one txn");
        assert!(model.can_undo(), "frame 1 pushes one undo step");

        // Frame 2: move dx:-5 (same name, same target) -> net (0,0) round-trip.
        model.begin_txn();
        model.name_txn("selection on_mousemove");
        apply_op(&mut model, &serde_json::json!({"op": "move_selection", "dx": -5, "dy": 0}));
        model.commit_txn();

        assert!(model.journal().is_empty(),
            "net-zero whole-drag must leave NO journal entry, got {} txns",
            model.journal().len());
        assert_eq!(model.journal_head(), 0, "net-zero whole-drag leaves cursor at origin");
        assert!(!model.can_undo(),
            "net-zero whole-drag must leave NO undo step (no-op rule across the run)");
        assert_eq!(document_to_test_json(model.document()), pre_drag,
            "net-zero whole-drag must restore the pre-drag document byte-for-byte");
    }

    /// (c) TARGET break (predicate c proper): two ADJACENT single-op move frames
    /// whose target sets differ do NOT coalesce. The selection is changed OUT OF
    /// BAND between the frames (so each frame is a single-op move txn, isolating
    /// the target-mismatch predicate from the op-count predicate), proving the
    /// run breaks and stays TWO distinct undo steps.
    #[test]
    fn drag_coalesce_target_break() {
        use crate::document::controller::Controller;
        use crate::document::document::ElementSelection;
        let setup = read_fixture("svg/two_ided_rects.svg");
        let mut model = Model::new(svg_to_document(&setup), None);

        // Select element "a" (path [0,0]) out of band.
        Controller::set_selection(&mut model, vec![ElementSelection::all(vec![0, 0])]);

        // Frame 1: move "a".
        model.begin_txn();
        model.name_txn("selection on_mousemove");
        apply_op(&mut model, &serde_json::json!({"op": "move_selection", "dx": 5, "dy": 0}));
        model.commit_txn();
        assert_eq!(model.journal().len(), 1);
        assert_eq!(model.journal()[0].ops[0].targets, vec!["a".to_string()],
            "frame 1 targets element a");

        // Change selection to "b" (path [0,1]) out of band — a DIFFERENT target.
        Controller::set_selection(&mut model, vec![ElementSelection::all(vec![0, 1])]);

        // Frame 2: a single-op move on "b". Same name, same verb, but the
        // target set differs ([a] vs [b]) -> predicate (c) fails -> NO coalesce.
        model.begin_txn();
        model.name_txn("selection on_mousemove");
        apply_op(&mut model, &serde_json::json!({"op": "move_selection", "dx": 7, "dy": 0}));
        model.commit_txn();

        assert_eq!(model.journal().len(), 2,
            "different target must NOT coalesce -> two distinct txns");
        assert_eq!(model.journal()[1].ops[0].targets, vec!["b".to_string()],
            "frame 2 targets element b");
        assert_eq!(model.journal_head(), 2, "two distinct undo steps (lock-step)");
        // Both moves are single-op, single-target additive translates of the
        // SAME verb/name — only the TARGET differs — so this isolates predicate
        // (c) from the op-count and verb predicates.
        let (dx0, _) = last_op_delta(&model.journal()[0]);
        let (dx1, _) = last_op_delta(&model.journal()[1]);
        assert_eq!((dx0, dx1), (5.0, 7.0),
            "deltas stay separate (5 and 7), not summed");
    }

    /// (guard) TIP guard (predicate `journal_head == op_journal.len()`): a
    /// coalescable move frame committed AFTER an undo — when the journal cursor
    /// sits BEHIND the tip (`journal_head < len`) — must NOT merge into the
    /// about-to-be-truncated redo tail. It must take the normal truncate/append
    /// path: the redo tail is discarded and the new frame lands as its OWN txn
    /// with its OWN delta (never summed into the stale tail).
    ///
    /// This is the ONLY test that drives `commit_txn` with `journal_head < len`
    /// for a coalescable move, so it is the sole signal for the TIP guard:
    /// without it, regressing the guard (e.g. `if false && ...`) is invisible to
    /// the suite because the merge target is unconditionally `op_journal.last()`
    /// — a regressed guard would silently fuse this frame's delta into a redo-tail
    /// txn that is about to be truncated, corrupting history.
    #[test]
    fn drag_coalesce_post_undo_no_merge() {
        use crate::document::controller::Controller;
        use crate::document::document::ElementSelection;
        let setup = read_fixture("svg/two_ided_rects.svg");
        let mut model = Model::new(svg_to_document(&setup), None);

        // Select element "a" (path [0,0]) out of band (no journal entry).
        Controller::set_selection(&mut model, vec![ElementSelection::all(vec![0, 0])]);

        // Frame 1: a coalescable move (dx:5). Commits one txn at the tip.
        model.begin_txn();
        model.name_txn("selection on_mousemove");
        apply_op(&mut model, &serde_json::json!({"op": "move_selection", "dx": 5, "dy": 0}));
        model.commit_txn();
        assert_eq!(model.journal().len(), 1, "frame 1 journals one txn");
        assert_eq!(model.journal_head(), 1, "cursor at the tip after frame 1");

        // Undo frame 1: cursor moves BEHIND the tip (journal_head 0 < len 1) and
        // a redo entry is staged. This is the guard's scenario.
        model.undo();
        assert_eq!(model.journal_head(), 0, "undo moved the cursor behind the tip");
        assert_eq!(model.journal().len(), 1, "the undone txn is still the redo tail");
        assert!(model.can_redo(), "frame 1 is available to redo");

        // Frame 2: a SAME name / SAME target / SAME verb coalescable move (dx:11)
        // — every predicate (a)-(e) holds EXCEPT the TIP guard, which fails
        // (journal_head 0 != len 1). So it must NOT coalesce: the normal path
        // truncates the redo tail and appends frame 2 as its own txn.
        model.begin_txn();
        model.name_txn("selection on_mousemove");
        apply_op(&mut model, &serde_json::json!({"op": "move_selection", "dx": 11, "dy": 0}));
        model.commit_txn();

        // Normal truncate/append ran: redo tail discarded, frame 2 appended fresh.
        assert_eq!(model.journal().len(), 1,
            "post-undo frame must truncate+append (one txn), NOT merge into the redo tail");
        assert_eq!(model.journal_head(), 1, "cursor advanced to the new tip (lock-step)");
        assert!(!model.can_redo(), "a new edit discards the redo tail");
        // The decisive guard signal: the surviving txn carries frame 2's delta
        // ALONE (11), never frame 1's (5) summed in (16). A regressed guard would
        // have merged into the stale tail and produced 16.
        let (dx, _) = last_op_delta(&model.journal()[0]);
        assert_eq!(dx, 11.0,
            "surviving txn carries frame 2's delta alone (11), not summed with the \
             discarded tail (would be 16) — proves the TIP guard blocked the merge");
        // And undoing the single surviving step drains the journal in lock-step.
        model.undo();
        assert_eq!(model.journal_head(), 0, "one undo drains the single post-undo step");
        assert!(!model.can_undo(), "no further undo steps");
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

    /// OP_LOG.md §5 Fork 4 / 3c-1 — the id-primary op-addressing flip. The fixture
    /// carries TWO cases on the SAME `eye.svg` pointing at the SAME golden:
    ///   - `selrel_move_eye`  : `[select_rect, move_selection]` (selection-relative)
    ///   - `id_primary_move_eye`: `[select_by_ids, move_by_ids]` (id-primary)
    /// Both must produce a BYTE-IDENTICAL document AND selection (the golden is
    /// shared), which proves the id-primary verbs replay to the same document+
    /// selection as the selection-relative pair — the byte-gate reconciliation.
    /// The unchanged `checkpoint_equivalence` gate (run per case by
    /// `assert_operation_test`) additionally proves each journals a replay-safe
    /// segment. The id-primary verb reads its operand ids from its OWN params, so
    /// snapshot and replay apply identical operands (the §7 determinism rule).
    #[test]
    fn operation_id_primary_move() {
        run_operation_fixture("operations/id_primary_move.json");
    }

    /// OP_LOG.md §5 Fork 4 / 3c-1 — the id-primary copy verb. Same shared-golden
    /// shape as `operation_id_primary_move`: `[select_rect, copy_selection]` and
    /// `[select_by_ids, copy_by_ids]` produce a byte-identical document (the copy
    /// is born id-less on BOTH paths) AND selection.
    #[test]
    fn operation_id_primary_copy() {
        run_operation_fixture("operations/id_primary_copy.json");
    }

    /// 3c-1 determinism check (OP_LOG.md §7): an id-primary op reads its operand
    /// ids from its OWN params, NEVER from `doc.selection`, so it applies the SAME
    /// operands regardless of the ambient selection. Drive `move_by_ids{["eye"]}`
    /// with a DELIBERATELY WRONG ambient selection (the whole layer pre-selected)
    /// and confirm the result still equals the shared golden — i.e. the op ignored
    /// the ambient selection and moved exactly the operand named in its params.
    #[test]
    fn id_primary_move_reads_operand_from_params_not_selection() {
        use crate::document::document::ElementSelection;
        use crate::document::controller::Controller;
        let setup_svg = read_fixture("svg/eye.svg");
        let mut model = Model::new(svg_to_document(&setup_svg), None);
        // Poison the ambient selection with an unrelated path — an op that
        // inferred its operand from doc.selection would act on the wrong thing.
        Controller::set_selection(&mut model, vec![ElementSelection::all(vec![0])]);
        model.begin_txn();
        apply_op(&mut model, &serde_json::json!(
            { "op": "select_by_ids", "ids": ["eye"] }));
        apply_op(&mut model, &serde_json::json!(
            { "op": "move_by_ids", "ids": ["eye"], "dx": 50, "dy": 0 }));
        model.commit_txn();
        let actual = document_to_test_json(model.document());
        let expected = read_fixture("operations/id_primary_move_eye.json");
        assert_eq!(actual, expected.trim(),
            "id-primary move read its operand from params, not the ambient selection");

        // Snapshot==replay even though the snapshot ran with a poisoned ambient
        // selection: the journaled ops carry their own operands, so a fresh replay
        // (no ambient selection) reproduces the document byte-identically.
        let replayed = replay_journal("eye.svg", model.journal(), model.journal_head());
        assert_eq!(replayed, actual,
            "id-primary op applies identical operands on snapshot and replay");
    }

    /// 3c-1 EYE-DEMO RE-DERIVATION PIN (the load-bearing payoff): run a FAITHFUL
    /// id-primary journal segment `[select_by_ids, copy_by_ids]` through the SHARED
    /// dispatcher (so it is a real, byte-gated, replayable journal segment),
    /// normalize the committed segment to a `RecordedElem` via the now-pass-through
    /// `capture_recipe`, edit the SOURCE input, re-derive, and confirm the output
    /// TRACKS the edited source. The recipe survives source edits with NO selection
    /// dependency — the operand ids came from the op params (`from:["eye"]`), never
    /// from a select op's resolved selection. Reuses the existing eye-demo golden
    /// (`eye_demo_rederived.json`): `copy_by_ids{dx:50}` captures to `copy{dx:50}`,
    /// whose re-derivation against the edited source (eye→x=100px) is byte-identical
    /// to the selection-relative demo's copy(0)+translate(50) net offset.
    #[test]
    fn id_primary_capture_recipe_rederives_on_source_edit() {
        use crate::geometry::live::{
            capture_recipe, ElementRef, ElementResolver, RecordedElem, DEFAULT_PRECISION,
        };
        use crate::geometry::element::CommonProps;
        use std::rc::Rc;

        // A faithful id-primary demonstration: select the eye, copy it +50.
        // This is a REAL journal segment op_apply replays byte-identically (it is
        // the id_primary_copy fixture's id-primary case).
        let setup_svg = read_fixture("svg/eye.svg");
        let mut model = Model::new(svg_to_document(&setup_svg), None);
        model.begin_txn();
        model.name_txn("id-primary demo");
        apply_op(&mut model, &serde_json::json!(
            { "op": "select_by_ids", "ids": ["eye"] }));
        apply_op(&mut model, &serde_json::json!(
            { "op": "copy_by_ids", "from": ["eye"], "dx": 50, "dy": 0 }));
        model.commit_txn();

        // capture_recipe is a PASS-THROUGH over the id-primary segment: it reads
        // the operand id from the op's `from` PARAM (no selection dependency —
        // select_by_ids' targets are NOT consulted).
        let segment = model.journal().last().expect("a committed transaction").ops.clone();
        // Guard: the captured segment is purely id-primary (proves the brittle
        // selection-relative bridge is NOT on this path).
        for op in &segment {
            assert!(matches!(op.op.as_str(), "select_by_ids" | "copy_by_ids"),
                "segment is id-primary, got {}", op.op);
        }
        let (recipe, inputs) = capture_recipe(&segment);
        assert_eq!(inputs, vec!["eye".to_string()]);
        assert_eq!(recipe.len(), 1);
        assert_eq!(recipe[0].op, "copy");
        assert_eq!(recipe[0].params["from"], serde_json::json!(["eye"]));

        // Wrap + re-derive against the EDITED source (eye moved to x=100 px).
        let mut common = CommonProps::default();
        common.id = Some("rec".into());
        let recorded = RecordedElem::new(
            recipe, inputs.into_iter().map(ElementRef).collect(), common);
        let edited_svg = setup_svg.replace(r#"x="0" y="0""#, r#"x="100" y="0""#);
        let edited_el = svg_to_document(&edited_svg)
            .get_element(&vec![0, 0]).expect("edited source").clone();
        struct OneResolver { id: String, el: Rc<crate::geometry::element::Element> }
        impl ElementResolver for OneResolver {
            fn resolve(&self, id: &ElementRef)
                -> Option<Rc<crate::geometry::element::Element>> {
                if id.0 == self.id { Some(self.el.clone()) } else { None }
            }
        }
        let resolver = OneResolver { id: "eye".into(), el: Rc::new(edited_el) };
        let mut visiting = std::collections::BTreeSet::new();
        let ps = recorded.evaluate_with(DEFAULT_PRECISION, &resolver, &mut visiting);
        let actual = polygon_set_to_test_json(&ps);
        // The re-derived output tracks the edited source — the SAME golden the
        // selection-relative eye demo pins (the net offset is identical).
        let expected = read_fixture("production_capture/eye_demo_rederived.json");
        assert_eq!(actual, expected.trim(),
            "the id-primary recipe re-derived against the edited source, no \
             selection dependency");
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

    /// CONCEPTS.md §7 — the concept-pack ops journal + replay byte-identically.
    /// `place_concept_instance` appends a value-in-op `Generated` element (concept
    /// id + resolved default params + minted id); `set_concept_param` tunes one
    /// param of the `Generated` at `path`. Every operand is value-in-op, so the
    /// journal replays to the SAME document the live edit produced (the
    /// checkpoint_equivalence gate, OP_LOG.md §6) — even though the registry the
    /// defaults came from is never consulted on replay.
    #[test]
    fn operation_concept_ops_replay_is_deterministic() {
        let setup = "rect_basic.svg";
        let setup_svg = read_fixture(&format!("svg/{}", setup));
        let mut model = Model::new(svg_to_document(&setup_svg), None);

        // Place a hexagon instance with a literal id + resolved default params.
        model.begin_txn();
        model.name_txn("place_concept_instance");
        apply_op(
            &mut model,
            &serde_json::json!({
                "op": "place_concept_instance",
                "concept_id": "regular_polygon",
                "params": { "sides": 6.0, "radius": 50.0 },
                "elem_id": "concept-1",
            }),
        );
        model.commit_txn();

        // Tune one param (sides 6 -> 8). The Generated sits at [0,1], after the
        // rect that rect_basic.svg seeds the single layer with.
        model.begin_txn();
        model.name_txn("set_concept_param");
        apply_op(
            &mut model,
            &serde_json::json!({
                "op": "set_concept_param",
                "path": [0, 1],
                "name": "sides",
                "value": 8.0,
            }),
        );
        model.commit_txn();

        let live = <DocumentOps as OpWorld>::to_test_json(&model);
        assert!(
            live.contains("\"concept\":\"regular_polygon\""),
            "the placed Generated instance is in the document: {live}"
        );
        assert!(
            live.contains("\"concept-1\""),
            "the value-in-op id survives into the document: {live}"
        );
        assert!(
            live.contains("\"sides\":8"),
            "set_concept_param tuned sides to 8: {live}"
        );

        // checkpoint_equivalence: the journal replays to the SAME document, twice.
        let head = model.journal_head();
        let replay1 = replay_journal(setup, model.journal(), head);
        let replay2 = replay_journal(setup, model.journal(), head);
        assert_eq!(
            replay1, replay2,
            "concept-op replay is non-deterministic"
        );
        assert_eq!(
            replay1, live,
            "concept-op journal replay != snapshot path (value-in-op operands must \
             reproduce the Generated instance + tuned param byte-identically)"
        );
    }

    /// CONCEPTS.md §9 — `apply_concept_operation` journals + replays byte-
    /// identically. The op carries the production-RESOLVED `changes` map
    /// value-in-op (here `{sides: 7}`, the add_side result), so replay merges it
    /// without re-evaluating the operation's expression — the checkpoint_
    /// equivalence gate for the operations verb.
    #[test]
    fn operation_apply_concept_operation_replay_is_deterministic() {
        let setup = "rect_basic.svg";
        let setup_svg = read_fixture(&format!("svg/{}", setup));
        let mut model = Model::new(svg_to_document(&setup_svg), None);

        model.begin_txn();
        model.name_txn("place_concept_instance");
        apply_op(
            &mut model,
            &serde_json::json!({
                "op": "place_concept_instance",
                "concept_id": "regular_polygon",
                "params": { "sides": 6.0, "radius": 50.0 },
                "elem_id": "concept-1",
            }),
        );
        model.commit_txn();

        // add_side, resolved at production time to { sides: 7 }, journaled with
        // its op_id as metadata and the changes as the authoritative operand.
        model.begin_txn();
        model.name_txn("apply_concept_operation");
        apply_op(
            &mut model,
            &serde_json::json!({
                "op": "apply_concept_operation",
                "path": [0, 1],
                "op_id": "add_side",
                "changes": { "sides": 7.0 },
            }),
        );
        model.commit_txn();

        let live = <DocumentOps as OpWorld>::to_test_json(&model);
        assert!(
            live.contains("\"sides\":7"),
            "the operation merged sides=7: {live}"
        );

        let head = model.journal_head();
        let replay1 = replay_journal(setup, model.journal(), head);
        let replay2 = replay_journal(setup, model.journal(), head);
        assert_eq!(replay1, replay2, "apply_concept_operation replay is non-deterministic");
        assert_eq!(
            replay1, live,
            "apply_concept_operation journal replay != snapshot path"
        );
    }

    /// CONCEPTS.md §10 — `promote_to_concept` journals + replays byte-identically.
    /// Every operand is value-in-op (the detection ran at production time): the
    /// concept id, the recovered params, and the placement transform are baked
    /// into the op, so replay rebuilds the SAME `Generated` element that replaced
    /// the raw polygon — the checkpoint_equivalence gate for the promote verb.
    #[test]
    fn operation_promote_to_concept_replay_is_deterministic() {
        let setup = "polygon_basic.svg";
        let setup_svg = read_fixture(&format!("svg/{}", setup));
        let mut model = Model::new(svg_to_document(&setup_svg), None);

        model.begin_txn();
        model.name_txn("promote_to_concept");
        apply_op(
            &mut model,
            &serde_json::json!({
                "op": "promote_to_concept",
                "path": [0, 0],
                "concept_id": "regular_polygon",
                "params": { "sides": 3.0, "radius": 50.0 },
                "transform": [1.0, 0.0, 0.0, 1.0, 48.0, 32.0],
            }),
        );
        model.commit_txn();

        let live = <DocumentOps as OpWorld>::to_test_json(&model);
        assert!(
            live.contains("\"concept\":\"regular_polygon\"")
                && live.contains("\"kind\":\"generated\""),
            "the raw polygon was promoted to a Generated instance: {live}"
        );

        let head = model.journal_head();
        let replay1 = replay_journal(setup, model.journal(), head);
        let replay2 = replay_journal(setup, model.journal(), head);
        assert_eq!(replay1, replay2, "promote_to_concept replay is non-deterministic");
        assert_eq!(
            replay1, live,
            "promote_to_concept journal replay != snapshot path (value-in-op concept \
             id + params + transform must rebuild the Generated byte-identically)"
        );
    }

    /// CONCEPTS.md §10 — the generator and fitter are inverses (the round-trip
    /// property). Generate a `regular_polygon`'s vertices, feed them back through
    /// the SAME concept's fitter, and assert it recovers `[sides, radius, 0, 0, 0]`
    /// (canonical placement: origin-centred, first vertex on +x ⇒ rotation 0).
    /// Both expressions are read from the compiled registry, so this pins that a
    /// concept's two halves agree.
    #[test]
    fn generator_fitter_round_trip() {
        use crate::interpreter::expr;
        use crate::interpreter::expr_types::Value;
        use crate::interpreter::workspace::Workspace;

        let ws = Workspace::load().expect("workspace loads");
        let concept = ws.concept("regular_polygon").expect("regular_polygon registered");
        let generator = concept["generator"].as_str().unwrap();
        let fitter = concept["fitter"].as_str().unwrap();

        for (sides, radius) in [(6.0, 50.0), (4.0, 10.0), (5.0, 25.0)] {
            // Generate the canonical points.
            let gctx = serde_json::json!({ "param": { "sides": sides, "radius": radius } });
            let pts = match expr::eval(generator, &gctx) {
                Value::List(items) => serde_json::Value::Array(items),
                other => panic!("generator returned non-list: {other:?}"),
            };
            // Fit them back.
            let fctx = serde_json::json!({ "shape": { "points": pts } });
            let recovered = match expr::eval(fitter, &fctx) {
                Value::List(items) => items,
                other => panic!("fitter returned non-list for sides={sides}: {other:?}"),
            };
            let nums: Vec<f64> = recovered.iter().map(|v| v.as_f64().unwrap()).collect();
            let expected = [sides, radius, 0.0, 0.0, 0.0];
            assert_eq!(nums.len(), expected.len(), "fitter arity for sides={sides}");
            for (i, (g, e)) in nums.iter().zip(expected.iter()).enumerate() {
                assert!(
                    (g - e).abs() < 1e-9,
                    "round-trip sides={sides} radius={radius} output[{i}]: \
                     expected {e}, got {g}"
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

    /// OP_LOG.md §9 Phase P6 — `set_attr_on_selection` (a Model-runner verb,
    /// effects.rs): applies one brush attribute (`stroke_brush` /
    /// `stroke_brush_overrides`) to every selected element through the SHARED
    /// `apply_set_attr_on_selection` helper. The op carries the RESOLVED `attr`
    /// + `value` LITERAL (replay has no eval context; an empty `value` string
    /// encodes the clear case). Covers: set a brush slug, set overrides on top,
    /// clear (empty value ⇒ None), and the hardened skips (unknown attr / missing
    /// value). Byte-gated by `checkpoint_equivalence` (`assert_operation_test`).
    ///
    /// NOTE: `document_to_test_json` does NOT serialize `stroke_brush` /
    /// `stroke_brush_overrides`, so the canonical-document byte-gate is BLIND to
    /// these fields (the gate still proves the rest of the doc + selection
    /// replay identically). The dedicated `operation_set_attr_pins_stroke_brush`
    /// test below reads the PathElem fields DIRECTLY so the actual brush mutation
    /// is pinned on both the live and replay paths.
    #[test]
    fn operation_set_attr_on_selection() {
        run_operation_fixture("operations/set_attr_on_selection.json");
    }

    /// OP_LOG.md §9 Phase P6 — pin the ACTUAL stroke_brush mutation (the
    /// canonical-document gate is blind to it). Reads the PathElem fields after
    /// both the live run AND a journal replay, asserting they agree and carry the
    /// resolved literal. Also pins the clear case (empty value ⇒ None on both
    /// live + replay).
    #[test]
    fn operation_set_attr_pins_stroke_brush() {
        use crate::geometry::element::Element;
        // Helper: the brush slug + overrides on the single path at [0,0].
        fn brush_of(model: &Model) -> (Option<String>, Option<String>) {
            match model.document().get_element(&vec![0, 0]) {
                Some(Element::Path(p)) =>
                    (p.stroke_brush.clone(), p.stroke_brush_overrides.clone()),
                _ => panic!("expected a Path at [0,0]"),
            }
        }
        let json_str = read_fixture("operations/set_attr_on_selection.json");
        let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();
        let find = |name: &str| -> serde_json::Value {
            tests.as_array().unwrap().iter()
                .find(|t| t["name"].as_str() == Some(name))
                .unwrap_or_else(|| panic!("case {name} not found")).clone()
        };

        // (1) set a brush slug.
        let tc = find("set_attr_on_selection_stroke_brush");
        let model = run_operation_model(&tc);
        let live = brush_of(&model);
        assert_eq!(live, (Some("charcoal".to_string()), None),
            "the brush slug is applied to the selected path");
        // The same fields survive a journal replay (the op carried the literal).
        let replay = replay_model(&tc, &model);
        assert_eq!(brush_of(&replay), live,
            "journal replay re-applies the same brush slug (checkpoint_equivalence \
             over a field the canonical JSON omits)");

        // (2) set overrides on top of the slug.
        let tc = find("set_attr_on_selection_overrides");
        let model = run_operation_model(&tc);
        let live = brush_of(&model);
        assert_eq!(live,
            (Some("charcoal".to_string()), Some("{\"angle\":42}".to_string())),
            "overrides ride on top of the slug");
        let replay = replay_model(&tc, &model);
        assert_eq!(brush_of(&replay), live, "replay re-applies slug + overrides");

        // (3) clear (empty value ⇒ None) — an effective change (the brush was set).
        let tc = find("set_attr_on_selection_clear");
        let model = run_operation_model(&tc);
        let live = brush_of(&model);
        assert_eq!(live, (None, None),
            "an empty value clears the brush (None)");
        let replay = replay_model(&tc, &model);
        assert_eq!(brush_of(&replay), live, "replay re-applies the clear");
    }

    /// Build the journal-replay Model for a fixture's whole journal (re-derives
    /// from `setup_svg`, applies every committed op via `op_apply`). Distinct
    /// from `replay_journal` (which returns canonical JSON) — this returns the
    /// Model so a test can read fields the canonical JSON omits.
    fn replay_model(tc: &serde_json::Value, live: &Model) -> Model {
        let setup_svg = read_fixture(&format!("svg/{}",
            tc["setup_svg"].as_str().unwrap()));
        let doc = svg_to_document(&setup_svg);
        let mut model = Model::new(doc, None);
        for txn in &live.journal()[0..live.journal_head()] {
            for op in &txn.ops {
                crate::document::op_apply::op_apply(&mut model, &op.params)
                    .expect("journal replay: journals only contain succeeded ops");
            }
        }
        model
    }

    /// OP_LOG.md §9 Phase P6 — Fork-4 targets: `set_attr_on_selection` records
    /// the PRE-mutation selection ids (resolved BEFORE the mutation, matching
    /// copy/move). The byte-gate ignores targets, so this is the only place it is
    /// pinned. The setup selects the single path with id "path-1".
    #[test]
    fn operation_set_attr_records_selection_targets() {
        let json_str = read_fixture("operations/set_attr_on_selection.json");
        let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();
        let tc = tests.as_array().unwrap().iter()
            .find(|t| t["name"].as_str() == Some("set_attr_on_selection_stroke_brush"))
            .unwrap();
        let model = run_operation_model(tc);
        // The outer harness transaction holds both the select_rect (selection,
        // serialized state) and the set_attr op; the LAST op is the brush set.
        let last_txn = model.journal().last().expect("a committed transaction");
        let attr_op = last_txn.ops.iter()
            .find(|o| o.op == "set_attr_on_selection")
            .expect("the set_attr_on_selection op is journaled");
        assert_eq!(attr_op.targets, vec!["path-1".to_string()],
            "targets carry the pre-mutation selection ids");
        assert_eq!(attr_op.params["attr"], "stroke_brush");
        assert_eq!(attr_op.params["value"], "charcoal",
            "the op carries the RESOLVED value literal");
    }

    /// OP_LOG.md §9 Phase P6 — hardened skips journal NO `set_attr_on_selection`
    /// op (unknown attr / missing value). The select_rect still records (it
    /// changes selection), so the transaction is non-empty; the set_attr op
    /// simply never reaches `record_op`.
    #[test]
    fn operation_set_attr_skips_journal_nothing() {
        for name in &[
            "set_attr_on_selection_unknown_attr_skips",
            "set_attr_on_selection_missing_value_skips",
        ] {
            let json_str = read_fixture("operations/set_attr_on_selection.json");
            let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();
            let tc = tests.as_array().unwrap().iter()
                .find(|t| t["name"].as_str() == Some(*name))
                .unwrap_or_else(|| panic!("case {name} not found"));
            let model = run_operation_model(tc);
            let has_attr_op = model.journal().iter()
                .flat_map(|t| t.ops.iter())
                .any(|o| o.op == "set_attr_on_selection");
            assert!(!has_attr_op,
                "{name}: a hardened-skip case journals NO set_attr_on_selection op");
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
    // OP_LOG.md §9 Phase P7 — the transform trio (scale / rotate / shear)
    // ---------------------------------------------------------------

    /// Phase P7 — the transform trio journals the CONFIRM apply through
    /// `op_apply` as one transform op carrying the RESOLVED matrix params (the
    /// factors/angle/axis, the resolved reference point rx/ry, and the scale
    /// flags). The op_apply replay arms call the SAME shared helpers
    /// (`apply_scale`/`apply_rotate`/`apply_shear`) as the production confirm
    /// path, so the matrix compose is byte-identical and the
    /// checkpoint_equivalence gate (`assert_operation_test`) proves each journaled
    /// op replays byte-identically to the snapshot-path document. Identity
    /// transforms (sx=sy=1 / angle=0) journal NOTHING (the no-op short-circuit).
    #[test]
    fn operation_transform_scale() {
        run_operation_fixture("operations/transform_scale.json");
    }

    #[test]
    fn operation_transform_rotate() {
        run_operation_fixture("operations/transform_rotate.json");
    }

    #[test]
    fn operation_transform_shear() {
        run_operation_fixture("operations/transform_shear.json");
    }

    /// Phase P7 — the copy=true variant journals TWO ops in one transaction:
    /// `copy_selection` (duplicate, born id-less) THEN the transform op (applied
    /// to the duplicate). The byte-gate proves the original stays untouched and
    /// the copy carries the composed matrix.
    #[test]
    fn operation_transform_copy() {
        run_operation_fixture("operations/transform_copy.json");
    }

    /// Phase P7 — replay determinism: the SAME journal replays to the SAME
    /// document TWICE. The matrix compose is a pure deterministic function of the
    /// recorded op (resolved literals only — no state, no entropy, no drag
    /// coordinates). Covers all three verbs + the copy variant.
    #[test]
    fn operation_transform_replay_is_deterministic() {
        for fixture in &[
            "operations/transform_scale.json",
            "operations/transform_rotate.json",
            "operations/transform_shear.json",
            "operations/transform_copy.json",
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
                    "replay of '{}' is non-deterministic (the transform matrix must \
                     compose byte-identically from the resolved-literal op)",
                    tc["name"].as_str().unwrap()
                );
            }
        }
    }

    /// Read the production action-bundle (`workspace/workspace.json`) and return
    /// the named action's `effects` array. The native apps load this bundle (not
    /// the YAML), so driving these effects exercises the REAL confirm/preview
    /// paths exactly as production does.
    fn bundle_action_effects(action: &str) -> Vec<serde_json::Value> {
        let bundle = std::fs::read_to_string("../workspace/workspace.json")
            .expect("read workspace.json bundle");
        let v: serde_json::Value = serde_json::from_str(&bundle).expect("parse bundle");
        v["actions"][action]["effects"]
            .as_array()
            .unwrap_or_else(|| panic!("action {action} has no effects array"))
            .clone()
    }

    /// Build a Model from `rect_with_id.svg` with the single rect (id "rect-1")
    /// selected — the common setup for the production-route transform tests.
    ///
    /// The selection is established through a JOURNALED `select_rect` op in its own
    /// committed transaction (not an out-of-band Controller call), so
    /// checkpoint_equivalence can replay it: selection is serialized Document state
    /// (OP_LOG.md §7), and `copy_selection` reads it on replay. This mirrors a real
    /// session, where a prior journaled select established the selection before the
    /// transform dialog opened.
    fn transform_production_model() -> Model {
        let svg = read_fixture("svg/rect_with_id.svg");
        let mut model = Model::new(svg_to_document(&svg), None);
        model.begin_txn();
        crate::document::op_apply::op_apply(&mut model, &serde_json::json!({
            "op": "select_rect", "x": 0, "y": 0, "width": 96, "height": 96,
            "extend": false,
        }))
        .expect("known-good select_rect op must apply Ok");
        model.commit_txn();
        model
    }

    /// Drive an action's effects through the REAL `run_effects` with the given
    /// resolved `param.*` context, stamping `action` as the txn name (matching
    /// production's `name_txn`).
    fn run_transform_action(model: &mut Model, action: &str, params: serde_json::Value) {
        use crate::interpreter::effects::run_effects;
        use crate::interpreter::state_store::StateStore;
        let effects = bundle_action_effects(action);
        let ctx = serde_json::json!({ "param": params });
        let mut store = StateStore::new();
        run_effects(&effects, &ctx, &mut store, Some(model), None, None, Some(action));
    }

    /// Phase P7 — the PRODUCTION confirm path. Drives the REAL
    /// `scale_options_confirm` / `rotate_options_confirm` / `shear_options_confirm`
    /// actions from the bundle and asserts:
    ///  (a) exactly ONE transform op is journaled (copy=false);
    ///  (b) the op carries the RESOLVED params — rx/ry literals (resolved from the
    ///      selection-bounds center, NOT transient state), the factors/angle, and
    ///      (scale) the flags;
    ///  (c) the live document is transformed;
    ///  (d) checkpoint_equivalence holds (the journaled op replays to the same doc).
    #[test]
    fn production_transform_confirm_journals_one_op_with_resolved_params() {
        // (scale) uniform 200%, copy=false. The 96×96 (px) rect parses to 72×72
        // in internal pt units (SVG px→pt ×0.75), so the selection-bounds center
        // is (36, 36) ⇒ rx/ry resolve to 36 — the REAL geometric center, NOT any
        // transient state. (That the resolved literal is 36, not 48, is itself the
        // proof the reference point is resolved from the live selection geometry.)
        {
            let mut model = transform_production_model();
            run_transform_action(&mut model, "scale_options_confirm", serde_json::json!({
                "uniform": true, "uniform_pct": 200.0,
                "horizontal_pct": 100.0, "vertical_pct": 100.0,
                "scale_strokes": true, "scale_corners": false,
                "preview": false, "copy": false,
            }));
            let txn = model.journal().last().expect("a committed transaction");
            let ops: Vec<&str> = txn.ops.iter().map(|o| o.op.as_str()).collect();
            assert_eq!(ops, vec!["scale_transform"],
                "confirm journals exactly one scale_transform op (copy=false)");
            let p = &txn.ops[0].params;
            assert_eq!(p["sx"], 2.0, "resolved sx literal");
            assert_eq!(p["sy"], 2.0, "resolved sy literal");
            assert_eq!(p["rx"], 36.0, "rx resolved to the selection-bounds center literal");
            assert_eq!(p["ry"], 36.0, "ry resolved to the selection-bounds center literal");
            assert_eq!(p["scale_strokes"], true, "resolved scale_strokes flag literal");
            assert_eq!(p["scale_corners"], false, "resolved scale_corners flag literal");
            assert_eq!(txn.ops[0].targets, vec!["rect-1".to_string()],
                "targets carry the pre-mutation selection id");
            // (c) the live document is transformed.
            assert!(transformed_at(&model, &[0, 0]),
                "the selected rect carries a transform after confirm");
            // (d) checkpoint_equivalence.
            assert_confirm_replay_equivalent(&model);
        }
        // (rotate) 30° around the bounds center.
        {
            let mut model = transform_production_model();
            run_transform_action(&mut model, "rotate_options_confirm", serde_json::json!({
                "angle": 30.0, "preview": false, "copy": false,
            }));
            let txn = model.journal().last().expect("a committed transaction");
            let ops: Vec<&str> = txn.ops.iter().map(|o| o.op.as_str()).collect();
            assert_eq!(ops, vec!["rotate_transform"], "one rotate_transform op");
            let p = &txn.ops[0].params;
            assert_eq!(p["angle"], 30.0, "resolved angle literal");
            assert_eq!(p["rx"], 36.0, "rx resolved literal");
            assert_eq!(p["ry"], 36.0, "ry resolved literal");
            assert_eq!(txn.ops[0].targets, vec!["rect-1".to_string()]);
            assert!(transformed_at(&model, &[0, 0]));
            assert_confirm_replay_equivalent(&model);
        }
        // (shear) 20° horizontal around the bounds center.
        {
            let mut model = transform_production_model();
            run_transform_action(&mut model, "shear_options_confirm", serde_json::json!({
                "angle": 20.0, "axis": "horizontal", "axis_angle": 0.0,
                "preview": false, "copy": false,
            }));
            let txn = model.journal().last().expect("a committed transaction");
            let ops: Vec<&str> = txn.ops.iter().map(|o| o.op.as_str()).collect();
            assert_eq!(ops, vec!["shear_transform"], "one shear_transform op");
            let p = &txn.ops[0].params;
            assert_eq!(p["angle"], 20.0, "resolved angle literal");
            assert_eq!(p["axis"], "horizontal", "resolved axis literal");
            assert_eq!(p["axis_angle"], 0.0, "resolved axis_angle literal");
            assert_eq!(p["rx"], 36.0, "rx resolved literal");
            assert_eq!(p["ry"], 36.0, "ry resolved literal");
            assert_eq!(txn.ops[0].targets, vec!["rect-1".to_string()]);
            assert!(transformed_at(&model, &[0, 0]));
            assert_confirm_replay_equivalent(&model);
        }
    }

    /// Phase P7 — the PREVIEW path STAYS OUT-OF-BAND (OP_LOG.md §8). Drives the
    /// REAL preview actions (`scale_options_preview` etc., which the dialog's
    /// on_change hook fires) and asserts NO transform op is journaled — the
    /// preview re-applies through the unbracketed preview-snapshot channel and the
    /// journal stays empty. The live document IS still mutated (the preview is
    /// visible) — only the JOURNAL is untouched.
    #[test]
    fn production_transform_preview_does_not_journal() {
        // Drive the preview through a dialog scope carrying non-identity values
        // (so the preview re-apply is a REAL mutation, not a trivial identity
        // no-op that journals nothing for the wrong reason). The preview exprs
        // read `dialog.*`; we seed them into the store and run the bundle's
        // preview effects directly.
        use crate::interpreter::effects::run_effects;
        use crate::interpreter::state_store::StateStore;
        use std::collections::HashMap;
        let cases: &[(&str, &str, &[(&str, serde_json::Value)])] = &[
            ("scale_options_preview", "scale_options", &[
                ("uniform", serde_json::json!(true)),
                ("uniform_pct", serde_json::json!(200.0)),
            ]),
            ("rotate_options_preview", "rotate_options", &[
                ("angle", serde_json::json!(30.0)),
            ]),
            ("shear_options_preview", "shear_options", &[
                ("angle", serde_json::json!(20.0)),
                ("axis", serde_json::json!("horizontal")),
                ("axis_angle", serde_json::json!(0.0)),
            ]),
        ];
        for (action, dialog_id, dialog_state) in cases {
            let mut model = transform_production_model();
            // The dialog open captures a preview snapshot; the preview action's
            // doc.preview.restore then has a base to restore.
            model.capture_preview_snapshot();
            let mut store = StateStore::new();
            // Open the dialog scope so the preview exprs (`dialog.*`) resolve to
            // the non-identity values the user has typed in.
            let mut defaults: HashMap<String, serde_json::Value> = HashMap::new();
            for (key, value) in dialog_state.iter() {
                defaults.insert(key.to_string(), value.clone());
            }
            store.init_dialog(dialog_id, defaults, None);
            let effects = bundle_action_effects(action);
            run_effects(&effects, &serde_json::json!({}), &mut store,
                Some(&mut model), None, None, Some(action));
            // The live document IS mutated (the preview is visible) ...
            assert!(transformed_at(&model, &[0, 0]),
                "{action}: the preview re-apply does mutate the live document");
            // ... but NO transform op is journaled — the preview is out-of-band.
            let has_transform_op = model.journal().iter()
                .flat_map(|t| t.ops.iter())
                .any(|o| matches!(o.op.as_str(),
                    "scale_transform" | "rotate_transform" | "shear_transform"));
            assert!(!has_transform_op,
                "{action}: the PREVIEW path must journal NO transform op \
                 (out-of-band preview channel, OP_LOG.md §8); journal={:?}",
                model.journal());
        }
    }

    /// Phase P7 — the copy=true composition. Drives the REAL confirm with
    /// copy=true and asserts the transaction journals exactly
    /// [copy_selection, <transform>] (TWO ops), the original is untouched, and the
    /// copy carries the matrix. checkpoint_equivalence holds.
    #[test]
    fn production_transform_copy_journals_two_ops() {
        let mut model = transform_production_model();
        run_transform_action(&mut model, "scale_options_confirm", serde_json::json!({
            "uniform": true, "uniform_pct": 200.0,
            "horizontal_pct": 100.0, "vertical_pct": 100.0,
            "scale_strokes": true, "scale_corners": false,
            "preview": false, "copy": true,
        }));
        let txn = model.journal().last().expect("a committed transaction");
        let ops: Vec<&str> = txn.ops.iter().map(|o| o.op.as_str()).collect();
        assert_eq!(ops, vec!["copy_selection", "scale_transform"],
            "copy=true journals [copy_selection, scale_transform] in ONE transaction");
        // copy_selection records the PRE-mutation source id; the transform op
        // records the duplicate's targets (born id-less ⇒ empty).
        assert_eq!(txn.ops[0].targets, vec!["rect-1".to_string()],
            "copy_selection.targets = pre-mutation source id");
        // The original rect (now at [0,0]) is untouched; the copy (at [0,1])
        // carries the transform.
        assert!(!transformed_at(&model, &[0, 0]),
            "the original is untouched by a copy-transform");
        assert!(transformed_at(&model, &[0, 1]),
            "the duplicate carries the composed matrix");
        assert_confirm_replay_equivalent(&model);
    }

    /// True iff the element at `path` carries a (non-None) common transform.
    fn transformed_at(model: &Model, path: &[usize]) -> bool {
        model.document().get_element(&path.to_vec())
            .map(|e| e.common().transform.is_some())
            .unwrap_or(false)
    }

    /// checkpoint_equivalence (OP_LOG.md §6) for a production-confirm model:
    /// replaying the whole journal from the same setup must serialize
    /// byte-identically to the live document.
    fn assert_confirm_replay_equivalent(model: &Model) {
        let live = document_to_test_json(model.document());
        let replayed = replay_journal(
            "rect_with_id.svg", model.journal(), model.journal_head());
        assert_eq!(replayed, live,
            "checkpoint_equivalence: production confirm journal replay != live document");
    }

    /// Phase P7 — the LIVE-DRAG path. Drives the REAL scale tool handlers from the
    /// bundle (`on_mousedown` → `on_mousemove` → `on_mouseup`) with a faked event
    /// context, asserting:
    ///  - `on_mousemove` mutates NO document content and journals NOTHING (the
    ///    live preview is the bbox_ghost overlay, not a doc mutation — out-of-band);
    ///  - `on_mouseup` (the drag-release commit) journals exactly ONE
    ///    `scale_transform` op (joining the doc.snapshot transaction);
    ///  - checkpoint_equivalence holds for the dragged result.
    #[test]
    fn production_transform_drag_release_journals_one_op() {
        use crate::interpreter::effects::run_effects;
        use crate::interpreter::state_store::StateStore;
        let bundle = std::fs::read_to_string("../workspace/workspace.json")
            .expect("read bundle");
        let v: serde_json::Value = serde_json::from_str(&bundle).unwrap();
        let handler = |name: &str| -> Vec<serde_json::Value> {
            v["tools"]["scale"]["handlers"][name].as_array().unwrap().clone()
        };

        let mut model = transform_production_model();
        let mut store = StateStore::new();
        let journal_len_before = model.journal().len();

        // on_mousedown at (0,0): doc.snapshot + record press, mode='scaling'.
        // doc_x/doc_y mirror what pointer_event_payload supplies in the app
        // (here == x/y at the identity view); the move-guard + apply read
        // event.doc_x/doc_y (scale.yaml operates in document space).
        let down_ctx = serde_json::json!({
            "event": { "x": 0.0, "y": 0.0, "doc_x": 0.0, "doc_y": 0.0, "modifiers": { "alt": false, "shift": false } }
        });
        run_effects(&handler("on_mousedown"), &down_ctx, &mut store,
            Some(&mut model), None, None, Some("scale_tool.on_mousedown"));

        // on_mousemove to (96, 96): updates cursor + moved=true. NO doc mutation,
        // NO journal entry (the preview is the overlay, out-of-band).
        let journal_len_after_down = model.journal().len();
        let move_ctx = serde_json::json!({
            "event": { "x": 96.0, "y": 96.0, "doc_x": 96.0, "doc_y": 96.0, "modifiers": { "alt": false, "shift": false } }
        });
        run_effects(&handler("on_mousemove"), &move_ctx, &mut store,
            Some(&mut model), None, None, Some("scale_tool.on_mousemove"));
        assert!(!transformed_at(&model, &[0, 0]),
            "on_mousemove must NOT mutate the document (the preview is the overlay)");
        assert_eq!(model.journal().len(), journal_len_after_down,
            "on_mousemove journals NOTHING (out-of-band preview, OP_LOG.md §8)");

        // on_mouseup at (96, 96): the drag-release CONFIRM. Journals one
        // scale_transform op (joining the doc.snapshot transaction).
        let up_ctx = move_ctx.clone();
        run_effects(&handler("on_mouseup"), &up_ctx, &mut store,
            Some(&mut model), None, None, Some("scale_tool.on_mouseup"));
        assert!(transformed_at(&model, &[0, 0]),
            "the drag-release commit transforms the selected rect");
        assert!(model.journal().len() > journal_len_before,
            "the drag release committed a transaction");
        let txn = model.journal().last().expect("the drag-release transaction");
        let ops: Vec<&str> = txn.ops.iter().map(|o| o.op.as_str()).collect();
        assert_eq!(ops, vec!["scale_transform"],
            "the drag release journals exactly one scale_transform op");
        assert_eq!(txn.ops[0].targets, vec!["rect-1".to_string()],
            "the drag-release op carries the pre-mutation selection id");
        assert_confirm_replay_equivalent(&model);
    }

    // ---------------------------------------------------------------
    // Workspace layout equivalence tests
    // (requires "web" feature for workspace module)
    // ---------------------------------------------------------------

    #[cfg(feature = "web")]
    use crate::workspace::test_json::{
        workspace_to_test_json, test_json_to_workspace,
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
    use crate::workspace::workspace::{PaneId, PaneKind};

    /// Harness shim over the RUNTIME layout-op dispatcher (OP_LOG.md §12, Fork
    /// 5, Increment 3d-2). The per-verb mutation bodies — once duplicated here —
    /// now live in `crate::workspace::layout_apply::layout_apply`, which is the
    /// SAME dispatcher the production layout-mutation sites route through. The
    /// `workspace_operations/*.json` corpus replays through this shim, so harness
    /// and production exercise ONE dispatcher (the layout analogue of how the
    /// document corpus replays through `op_apply`). Kept as a thin wrapper so the
    /// existing `LayoutOps::apply` / `op_world_layout_envelope` call sites read
    /// unchanged.
    #[cfg(feature = "web")]
    fn apply_workspace_op(layout: &mut WorkspaceLayout, op: &serde_json::Value) {
        crate::workspace::layout_apply::layout_apply(layout, op);
    }

    /// Layout op vocabulary (Fork 5; OP_LOG §12 "Layout-op unification").
    /// `State = WorkspaceLayout`; `apply` delegates to the harness-only,
    /// web-gated `apply_workspace_op` body unchanged and returns `Vec::new()`
    /// (layout ops carry no `common.id` targets); `to_test_json` delegates to
    /// `workspace_to_test_json`. This world is HARNESS-ONLY — `apply_workspace_op`
    /// is NOT promoted to runtime, there is NO layout journal / undo / gate; the
    /// layout fixture path keeps only its weaker serialize-and-compare
    /// round-trip. Conforming to `OpWorld` lets the layout fixture driver reuse
    /// the same `run_ops_test` runner the document world uses, so a third op
    /// vocabulary cannot entrench as a third bespoke driver.
    #[cfg(feature = "web")]
    struct LayoutOps;
    #[cfg(feature = "web")]
    impl OpWorld for LayoutOps {
        type State = WorkspaceLayout;
        fn apply(layout: &mut WorkspaceLayout, op: &serde_json::Value) -> Vec<String> {
            apply_workspace_op(layout, op);
            Vec::new()
        }
        fn to_test_json(layout: &WorkspaceLayout) -> String {
            workspace_to_test_json(layout)
        }
        fn verbs() -> &'static [&'static str] {
            &[
                "toggle_group_collapsed", "set_active_panel", "close_panel",
                "show_panel", "reorder_panel", "move_panel_to_group",
                "detach_group", "redock", "set_pane_position", "tile_panes",
                "toggle_canvas_maximized", "resize_pane", "hide_pane",
                "show_pane", "bring_pane_to_front",
            ]
        }
    }

    #[cfg(feature = "web")]
    fn run_workspace_operation_test(tc: &serde_json::Value) -> String {
        let setup_name = tc["setup"].as_str().unwrap();
        let setup_json = read_fixture(&format!("expected/{}", setup_name));
        let mut layout = test_json_to_workspace(setup_json.trim());
        // Same unified runner the document world uses (Fork 5).
        run_ops_test::<LayoutOps>(&mut layout, tc["ops"].as_array().unwrap())
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

    /// `OpWorld` trait-level pin for the LAYOUT world (OP_LOG.md §2 Fork 5 /
    /// §12). Proves `LayoutOps` is genuinely wired through the trait — applying a
    /// known layout op via the unified `run_ops_test::<LayoutOps>` runner
    /// produces the SAME canonical JSON as the direct `apply_workspace_op` +
    /// `workspace_to_test_json` path. Together with `op_world_document_envelope`,
    /// this shows the SAME runner spans both vocabularies (the Fork-5 point) with
    /// NO layout journal / undo / gate.
    #[cfg(feature = "web")]
    #[test]
    fn op_world_layout_envelope() {
        let mut layout = WorkspaceLayout::default_layout();
        layout.ensure_pane_layout(1200.0, 800.0);
        let op = serde_json::json!({"op": "tile_panes"});

        // Path A: direct apply_workspace_op + serialize.
        let mut layout_a = layout.clone();
        apply_workspace_op(&mut layout_a, &op);
        let direct = workspace_to_test_json(&layout_a);

        // Path B: through the unified OpWorld runner.
        let mut layout_b = layout.clone();
        let via_trait = run_ops_test::<LayoutOps>(&mut layout_b, std::slice::from_ref(&op));

        assert_eq!(direct, via_trait,
            "OpWorld layout envelope diverged from direct apply_workspace_op path");
        assert!(!LayoutOps::verbs().is_empty(),
            "LayoutOps::verbs() must advertise the layout vocabulary");
    }

    // ---------------------------------------------------------------
    // 3d-2 production-route tests (OP_LOG.md §12, Fork 5, Option B)
    //
    // These pin that the PRODUCTION layout-mutation sites route through the
    // SAME runtime `layout_apply` dispatcher the harness corpus replays through,
    // and that the dispatcher never panics on malformed input. `layout_apply`
    // itself is module-level non-gated, but the WHOLE `workspace` / `panels`
    // module tree is `#[cfg(feature = "web")]` at the crate root in this app, so
    // these tests — which touch `AppState` and the panel dispatcher — are
    // web-gated to match (and the `--no-default-features --lib` build, where the
    // layout subsystem is absent, still compiles).
    // ---------------------------------------------------------------

    /// Production-route pin: drive a real production layout path — the Layers
    /// panel hamburger-menu `close_panel` command (`layers_panel::dispatch`),
    /// the same handler the live UI invokes — against a real `AppState`, and
    /// assert (1) it produces the SAME `WorkspaceLayout` (`workspace_to_test_json`)
    /// as feeding the equivalent op straight to the runtime `layout_apply`
    /// dispatcher, proving the production site routes through the one dispatcher;
    /// and (2) the dirty signal still fired — `needs_save()` flips true, which is
    /// the `bump()` the `act` wrapper reads to persist. ZERO behavior change vs
    /// the pre-3d-2 direct `workspace_layout.close_panel(addr)` call.
    #[cfg(feature = "web")]
    #[test]
    fn layout_production_route_close_panel() {
        use crate::workspace::app_state::AppState;
        use crate::workspace::workspace::{WorkspaceLayout, PanelAddr, GroupAddr, DockId};
        use crate::workspace::test_json::workspace_to_test_json;

        // A real AppState with a known, fixture-shaped default layout.
        let mut st = AppState::new();
        st.workspace_layout = WorkspaceLayout::default_layout();
        // Zero the dirty signal so a post-dispatch `needs_save()` proves the
        // production handler's `bump()` (inside `close_panel`) fired.
        st.workspace_layout.mark_saved();
        assert!(!st.workspace_layout.needs_save(),
            "precondition: layout must start clean");

        // The Layers panel address in the default layout (matches the
        // `panel_close_layers` corpus case: dock 0, group 2, panel 0).
        let addr = PanelAddr {
            group: GroupAddr { dock_id: DockId(0), group_idx: 2 },
            panel_idx: 0,
        };

        // Oracle: the same op fed straight to the runtime dispatcher.
        let mut oracle = WorkspaceLayout::default_layout();
        crate::workspace::layout_apply::layout_apply(
            &mut oracle,
            &crate::workspace::layout_apply::op_close_panel(addr),
        );
        let expected = workspace_to_test_json(&oracle);

        // Production path: the panel hamburger-menu dispatcher.
        crate::panels::layers_panel::dispatch("close_panel", addr, &mut st);

        let actual = workspace_to_test_json(&st.workspace_layout);
        assert_eq!(actual, expected,
            "production close_panel path diverged from the runtime layout_apply dispatcher");
        assert!(st.workspace_layout.needs_save(),
            "production close_panel must still bump the dirty signal (needs_save)");
    }

    /// No-panic pin: the runtime `layout_apply` dispatcher MUST tolerate
    /// malformed / garbage ops without panicking — production input is never
    /// trusted (the document `op_apply` discipline). Missing `op`, unknown verb,
    /// wrong-typed params, and missing required `kind` must all SKIP. A
    /// well-formed op on the same layout must still mutate (sanity), confirming
    /// the harness ISN'T masking a no-op dispatcher.
    #[cfg(feature = "web")]
    #[test]
    fn layout_apply_no_panic_on_malformed() {
        use crate::workspace::workspace::WorkspaceLayout;
        use crate::workspace::layout_apply::layout_apply;
        use crate::workspace::test_json::workspace_to_test_json;

        let mut layout = WorkspaceLayout::default_layout();
        layout.ensure_pane_layout(1200.0, 800.0);
        let baseline = workspace_to_test_json(&layout);

        // None of these must panic; each is a no-op (skip).
        let malformed = [
            serde_json::json!({}),                                  // no "op"
            serde_json::json!({"op": 42}),                          // "op" not a string
            serde_json::json!({"op": "totally_unknown_verb"}),     // unknown verb
            serde_json::json!({"op": "show_panel"}),               // missing required "kind"
            serde_json::json!({"op": "show_panel", "kind": 7}),    // "kind" wrong type
            serde_json::json!({"op": "hide_pane"}),                // missing required "kind"
            serde_json::json!({"op": "close_panel"}),              // missing dock/group/panel
            serde_json::json!({"op": "set_pane_position", "pane_id": "x"}), // garbage param
            serde_json::json!({"op": "toggle_group_collapsed", "dock_id": -1}), // bad number
            serde_json::json!({"op": "redock", "dock_id": "nope"}),
        ];
        for op in &malformed {
            layout_apply(&mut layout, op); // must not panic
        }

        // Skipped ops with valid-but-unknown targets leave the layout unchanged
        // for the cases that resolve to defaults but hit no element. (close_panel
        // with defaulted 0/0/0 may mutate group 0; show_panel with missing kind
        // skips entirely.) We only assert no panic above; here we additionally
        // confirm a WELL-FORMED op still works on a fresh layout (the dispatcher
        // is live, not inert).
        let mut fresh = WorkspaceLayout::default_layout();
        let before = workspace_to_test_json(&fresh);
        layout_apply(&mut fresh, &serde_json::json!(
            {"op": "toggle_group_collapsed", "dock_id": 0, "group_idx": 0}));
        let after = workspace_to_test_json(&fresh);
        assert_ne!(before, after,
            "a well-formed op must still mutate — dispatcher is live");
        // `baseline` is captured to document the malformed loop ran against a
        // real, paned layout; reference it so the binding is not dead.
        assert!(!baseline.is_empty());
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
    // Panel widget-layout (Path B) algorithm test vectors
    // ---------------------------------------------------------------

    #[test]
    fn algorithm_panel_layout_vectors() {
        use crate::interpreter::panel_layout::layout_panel;

        let json_str = read_fixture("algorithms/panel_layout.json");
        let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();

        let bundle_str =
            std::fs::read_to_string(format!("{}/../workspace/workspace.json", FIXTURES)).unwrap();
        let bundle: serde_json::Value = serde_json::from_str(&bundle_str).unwrap();
        let panels = &bundle["panels"];

        for tc in tests.as_array().unwrap() {
            let name = tc["name"].as_str().unwrap();
            let func = tc["function"].as_str().unwrap();
            assert_eq!(func, "layout_panel", "Unknown function: {}", func);
            let panel_id = tc["args"]["panel"].as_str().unwrap();
            let avail_w = tc["args"]["avail_w"].as_i64().unwrap();
            let avail_h = tc["args"]["avail_h"].as_i64().unwrap_or(0);
            // ctx is a JSON object data scope (foreach sources + text bindings);
            // serde_json::Value IS what the expr evaluator consumes, so the
            // fixture ctx passes straight through. Default to empty (literals).
            let empty = serde_json::json!({});
            let ctx = tc["args"].get("ctx").unwrap_or(&empty);
            let expected = &tc["expected"];

            let actual = layout_panel(&panels[panel_id], avail_w, avail_h, ctx);
            assert_eq!(&actual, expected, "Panel layout '{}' mismatch", name);
        }
    }

    // ---------------------------------------------------------------
    // Panel widget-TREE (structural snapshot) algorithm test vectors
    // ---------------------------------------------------------------

    #[test]
    fn algorithm_widget_tree_vectors() {
        use crate::interpreter::widget_tree::widget_tree;

        let json_str = read_fixture("algorithms/panel_widget_tree.json");
        let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();

        let bundle_str =
            std::fs::read_to_string(format!("{}/../workspace/workspace.json", FIXTURES)).unwrap();
        let bundle: serde_json::Value = serde_json::from_str(&bundle_str).unwrap();
        let panels = &bundle["panels"];

        for tc in tests.as_array().unwrap() {
            let name = tc["name"].as_str().unwrap();
            let func = tc["function"].as_str().unwrap();
            assert_eq!(func, "widget_tree", "Unknown function: {}", func);
            let panel_id = tc["args"]["panel"].as_str().unwrap();
            // ctx is a JSON object data scope (foreach sources only); it passes
            // straight to the expr evaluator. Default to empty (literals-only).
            let empty = serde_json::json!({});
            let ctx = tc["args"].get("ctx").unwrap_or(&empty);
            let expected = &tc["expected"];

            let actual = widget_tree(&panels[panel_id], ctx);
            assert_eq!(&actual, expected, "Panel widget tree '{}' mismatch", name);
        }
    }

    // ---------------------------------------------------------------
    // Menu enabled/checked (chrome seam) algorithm test vectors
    // ---------------------------------------------------------------

    #[test]
    fn algorithm_menu_state_vectors() {
        use crate::interpreter::menu_state::menu_state;

        let json_str = read_fixture("algorithms/menu_state.json");
        let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();

        let bundle_str =
            std::fs::read_to_string(format!("{}/../workspace/workspace.json", FIXTURES)).unwrap();
        let bundle: serde_json::Value = serde_json::from_str(&bundle_str).unwrap();
        let menubar = &bundle["menubar"];

        for tc in tests.as_array().unwrap() {
            let name = tc["name"].as_str().unwrap();
            let func = tc["function"].as_str().unwrap();
            assert_eq!(func, "menu_state", "Unknown function: {}", func);
            // ctx is a JSON object data scope (state / active_document / workspace
            // / panels / panes namespaces); it passes straight to the expr
            // evaluator as the per-item enabled_when/checked_when context.
            let ctx = &tc["args"]["ctx"];
            let expected = &tc["expected"];

            let actual = menu_state(menubar, ctx);
            assert_eq!(&actual, expected, "Menu state '{}' mismatch", name);
        }
    }

    // ---------------------------------------------------------------
    // Toolbar and menu structure tests
    // ---------------------------------------------------------------

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
