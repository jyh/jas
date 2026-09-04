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
            // CONCEPTS.md 3b: a Generated concept-instance (concept id +
            // params). JasSwift's jsonRoundtripAllExpected called this "the
            // cross-language pin for the generated kind" while Rust's list
            // did not carry it at all — a ONE-SIDED pin wearing a
            // cross-language label. Registered here so the claim is true.
            "generated_polygon",
            // ANY ELEMENT CARRIES A NAME, live kinds included (the name maps
            // to SVG inkscape:label). live_named names the compound AND the
            // reference AND both operands; live_named_recipe names the
            // recorded and the generated kinds, which have no SVG read path
            // and so can only be reached through the JSON/binary lanes.
            "live_named", "live_named_recipe",
            // LOCKSVG: the two lock goldens pin the canonical-JSON lane too,
            // so a `locked` regression in test_json cannot hide behind the SVG
            // lane being the one under repair.
            "locked_layer_and_element", "locked_all_kinds",
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
            // A live element's `name` rides the generic common block at
            // TAG_LIVE slot 5 like every other element's. Both fixtures name
            // their live elements, so a codec that packed nil there reds.
            "live_named", "live_named_recipe",
            // LOCKSVG: `common.locked` rides pack_common slot 1 and always
            // did; these two goldens make that a MEASUREMENT rather than an
            // assumption, on a document where the flag is actually true.
            "locked_layer_and_element", "locked_all_kinds",
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

    /// The resolution of the SVG writer, in decimal places: `svg.rs::fmt`
    /// quantizes lengths with `(v * 10000.0).round() / 10000.0`.
    const SVG_WRITER_DP: i32 = 4;

    /// Compare two canonical-JSON documents AT THE SVG WRITER'S RESOLUTION,
    /// because the two sides reach this point through different formats and one
    /// of them has crossed a boundary JYH ruled is lossy on purpose.
    ///
    /// # Why this is not a silent tolerance
    ///
    /// `binary_read_python_fixtures` asserts *decoding the Python-written binary
    /// yields the same document as parsing the source SVG*. Binary stores
    /// lossless `f64`; SVG stores px at 4dp. A 1pt stroke goes out as `4/3 =
    /// 1.3333` and comes back as `1.3333 × 0.75 = 0.999975` — a 2.5e-5 gap that
    /// is not a defect but the px grid, and R2 ruled FOR 4dp on lengths
    /// precisely because they SETTLE there: `0.999975` is a fixpoint, not a
    /// drift, and `a_reopened_matrix_is_bit_identical_on_every_later_save_and_
    /// reopen` pins the same property for the matrix.
    ///
    /// Until 2026-08-02 the oracle also printed 4dp, so both sides rendered
    /// `1.0` and the assertion held — **by construction, not by correctness.**
    /// R3 took the oracle to 6dp so it could stop sharing its subject's
    /// quantizer, and this equivalence became false the moment it could be seen.
    ///
    /// It SHOULD be false. Asserting agreement below 1e-4 across a boundary the
    /// ruling calls not exactly invertible is asserting something already ruled
    /// untrue. So the comparison moves to the writer's resolution — and says so
    /// here, and names the boundary in its failure message, rather than
    /// loosening quietly and leaving the next reader to find a bare epsilon and
    /// wonder what it was hiding.
    ///
    /// Everything that is not a number is still compared EXACTLY.
    fn assert_docs_equal_at_writer_resolution(actual: &str, expected: &str, name: &str) {
        fn quantize(v: &mut serde_json::Value) {
            match v {
                serde_json::Value::Number(n) => {
                    if let Some(f) = n.as_f64() {
                        let s = 10f64.powi(SVG_WRITER_DP);
                        let q = (f * s).round() / s;
                        if let Some(num) = serde_json::Number::from_f64(q) {
                            *v = serde_json::Value::Number(num);
                        }
                    }
                }
                serde_json::Value::Array(a) => a.iter_mut().for_each(quantize),
                serde_json::Value::Object(o) => o.iter_mut().for_each(|(_, x)| quantize(x)),
                _ => {}
            }
        }

        // Identical bytes is the common case and needs no parsing.
        if actual == expected {
            return;
        }

        let mut a: serde_json::Value = serde_json::from_str(actual)
            .unwrap_or_else(|e| panic!("'{}': actual is not JSON: {}", name, e));
        let mut e: serde_json::Value = serde_json::from_str(expected)
            .unwrap_or_else(|e| panic!("'{}': expected is not JSON: {}", name, e));
        quantize(&mut a);
        quantize(&mut e);

        assert_eq!(
            a, e,
            "Python binary fixture '{}' disagrees with the SVG-parsed golden AT \
             THE SVG WRITER'S RESOLUTION ({} dp). A difference this large is a \
             real divergence, not the pt<->px grid: the lossy-boundary allowance \
             covers only differences below 1e-{}.\n  binary-decoded: {}\n  \
             svg-parsed    : {}",
            name, SVG_WRITER_DP, SVG_WRITER_DP, actual, expected
        );
    }

    /// Verify Rust can read the binary fixtures generated by Python.
    ///
    /// Compared at the SVG writer's resolution — see
    /// [`assert_docs_equal_at_writer_resolution`] for the ruling this rests on.
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
            assert_docs_equal_at_writer_resolution(&actual, expected, name);
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
            // The same normalization reaching INSIDE a live compound's operands.
            "dup_id_compound_operand",
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
            // LOCKSVG: `common.locked` across the SVG boundary.
            "locked_layer_and_element", "locked_all_kinds",
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
            // A NAMED compound and a NAMED <use> reference survive the SVG
            // boundary: the name maps to inkscape:label, which the reader
            // already lifted into common.name generically while the live
            // writer arms routed through a name-less attribute tail.
            "live_named",
            // LOCKSVG: the WRITE side. `assert_svg_parse` above pins the
            // reader; only a round trip can catch a writer arm that drops
            // `jas:locked`, because the reader would then read a file that
            // never carried it and agree with itself.
            "locked_layer_and_element", "locked_all_kinds",
        ];
        for name in &names {
            assert_svg_roundtrip(name);
        }
    }

    /// The SVG READ side of the live-element name, pinned against the shared
    /// golden rather than only against itself: `<g data-jas-live=...
    /// inkscape:label="hull">` and `<use ... inkscape:label="eye"/>` import
    /// with those names, and so do the two named operands.
    #[test]
    fn svg_parse_live_named() {
        assert_svg_parse("live_named");
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

    // ---------------------------------------------------------------
    // LOCKSVG — `common.locked` survives the SVG boundary.
    //
    // Until 2026-07-28 it did not, in EITHER active port: this port's
    // `parse_common` hard-coded `locked: false` and had no writer at all;
    // JasSwift's Svg.swift contained zero occurrences of `locked`,
    // case-insensitive. Lock a layer, save, reopen — the protection was gone.
    // Every fixture in the shared corpus is SVG-seeded, so the corpus was
    // STRUCTURALLY BLIND to lock as a precondition and could gate nothing
    // about it (jas_dioxus/src/document/op_apply.rs said so in a doc comment).
    //
    // The spelling is ` jas:locked="true"` in the `urn:jas:1` namespace, the
    // same namespace and the same written-only-when-non-default shape as the
    // sibling CommonProps field `jas:tool-origin`.
    // ---------------------------------------------------------------

    #[test]
    fn svg_parse_locked_layer_and_element() {
        // The SEMANTIC vector, and the one the inherited-lock ruling
        // (transcripts/LAYER_STRUCTURE.md §13) needs to exist before it can be
        // gated at all: a LOCKED LAYER whose children carry no lock flag of
        // their own (inheritance, NOT materialization — the children stay
        // `locked: false` in the golden), plus a LOCKED ELEMENT sitting inside
        // an UNLOCKED layer.
        assert_svg_parse("locked_layer_and_element");
    }

    #[test]
    fn svg_parse_locked_all_kinds() {
        // The WRITER-ARM CENSUS. One locked instance of every element kind
        // that has an SVG read path — line, rect, circle, ellipse, polyline,
        // polygon, path, text, text-on-path, group, layer, <use> reference,
        // compound shape — plus a <defs> symbol master and a top-level bare
        // <g> that the importer PROMOTES to a Layer (that promotion rebuilds
        // the container field by field in JasSwift, which is exactly where the
        // Swift copy-site omission class strikes). A writer arm that forgets
        // the attribute cannot hide behind a sibling arm that remembers it.
        //
        // NOT covered, stated rather than implied: the `recorded` and
        // `generated` live kinds, which NEITHER port can read back from SVG at
        // all (they import as plain Groups), so no round-trip fixture can
        // watch their writer arms.
        assert_svg_parse("locked_all_kinds");
    }

    #[test]
    fn svg_parse_dup_id_import() {
        // Import normalizes duplicate ids to the unique-id invariant:
        // first pre-order occurrence keeps the id, later ones are cleared
        // (REFERENCE_GRAPH.md §2.5). All apps normalize identically.
        assert_svg_parse("dup_id_import");
    }

    #[test]
    fn svg_parse_dup_id_compound_operand() {
        // The same §2.5 normalization, reaching INSIDE a live compound's
        // operands — the operands are real elements carrying their own
        // common.id, so they are part of the one document-wide id space.
        // The vector pins both directions of that: the operand whose id
        // repeats an earlier layer child is CLEARED, and the operand id that
        // is first-seen ENTERS the seen set, so a later layer child repeating
        // it is cleared in turn.
        assert_svg_parse("dup_id_compound_operand");
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
                // Element-level marquee / lasso: `element` is a test-JSON
                // element, `args` the marquee rect x/y/w/h, `polygon` the
                // lasso outline.
                "element_intersects_rect" => {
                    let elem = crate::geometry::test_json::parse_element(&tc["element"]);
                    hit_test::element_intersects_rect(&elem, args[0], args[1], args[2], args[3])
                }
                "element_intersects_polygon" => {
                    let elem = crate::geometry::test_json::parse_element(&tc["element"]);
                    hit_test::element_intersects_polygon(&elem, &polygon)
                }
                _ => panic!("Unknown function: {}", func),
            };

            assert_eq!(actual, expected,
                "Hit test '{}' failed: expected {}, got {}", name, expected, actual);
        }
    }

    /// The `number_input` COMMIT corpus: typed text → the value written to
    /// state, or nothing at all. Acceptance goldens are derived from the live
    /// reference's numeric-string coercion (see the fixture's `_doc`); the
    /// clamp goldens are the widget's declared-bounds rule. Mirrored by Swift's
    /// `algorithmNumberCommitVectors`, and run port-against-port by
    /// `scripts/cross_language_algorithms.py --algo number_commit`.
    #[test]
    fn algorithm_number_commit_vectors() {
        use crate::interpreter::widget_commit::number_input_commit;
        let json_str = read_fixture("algorithms/number_commit.json");
        let doc: serde_json::Value =
            serde_json::from_str(&json_str).expect("Failed to parse number_commit.json");
        let vectors = doc["vectors"].as_array().expect("number_commit.json has no vectors");
        assert!(!vectors.is_empty(), "number_commit.json is empty");

        for tc in vectors {
            let name = tc["name"].as_str().unwrap();
            let text = tc["text"].as_str().unwrap();
            let min = tc.get("min").and_then(|v| v.as_f64());
            let max = tc.get("max").and_then(|v| v.as_f64());
            let expected = tc["expected"].as_f64();
            assert_eq!(
                number_input_commit(text, min, max),
                expected,
                "number_commit '{}': text {:?} with min {:?} max {:?}",
                name, text, min, max,
            );
        }
    }

    /// The colour-conversion corpus: the four primitives every port's Color
    /// panel is built out of, goldens derived from the spec formulas rather than
    /// captured from a port.
    ///
    /// The `panel_channels` family is the one that matters most. It pins the
    /// ORDER the panel's channel derivation applies the conversions in —
    /// quantise the float colour to three 8-bit values FIRST, then convert
    /// those — which is the contract Swift's overlay broke by asking the float
    /// colour for its own h/s/b instead (COLORTIERS, 2026-07-26). Mirrored by
    /// Swift's `algorithmColorConvertVectors`, and run port-against-port by
    /// `scripts/cross_language_algorithms.py --algo color_convert`.
    #[test]
    fn algorithm_color_convert_vectors() {
        use crate::interpreter::color_util as cu;
        let json_str = read_fixture("algorithms/color_convert.json");
        let doc: serde_json::Value = serde_json::from_str(&json_str)
            .expect("Failed to parse color_convert.json");
        let vectors = doc["vectors"].as_array().expect("color_convert.json has no vectors");
        assert!(!vectors.is_empty(), "color_convert.json is empty");

        let ints = |v: &serde_json::Value| -> Vec<i64> {
            v.as_array().unwrap().iter().map(|x| x.as_i64().unwrap()).collect()
        };
        let floats = |v: &serde_json::Value| -> Vec<f64> {
            v.as_array().unwrap().iter().map(|x| x.as_f64().unwrap()).collect()
        };

        for tc in vectors {
            let name = tc["name"].as_str().unwrap();
            match tc["function"].as_str().unwrap() {
                "rgb_to_hsb" => {
                    let a = ints(&tc["rgb"]);
                    let (h, s, b) = cu::rgb_to_hsb(a[0] as u8, a[1] as u8, a[2] as u8);
                    assert_eq!(vec![h as i64, s as i64, b as i64], ints(&tc["expected"]),
                        "color_convert '{}': rgb_to_hsb", name);
                }
                "hsb_to_rgb" => {
                    let a = floats(&tc["hsb"]);
                    let (r, g, b) = cu::hsb_to_rgb(a[0], a[1], a[2]);
                    assert_eq!(vec![r as i64, g as i64, b as i64], ints(&tc["expected"]),
                        "color_convert '{}': hsb_to_rgb", name);
                }
                "rgb_to_cmyk" => {
                    let a = ints(&tc["rgb"]);
                    let (c, m, y, k) = cu::rgb_to_cmyk(a[0] as u8, a[1] as u8, a[2] as u8);
                    assert_eq!(vec![c as i64, m as i64, y as i64, k as i64],
                        ints(&tc["expected"]), "color_convert '{}': rgb_to_cmyk", name);
                }
                "panel_channels" => {
                    let a = floats(&tc["float_rgb"]);
                    let got = cu::panel_channels(a[0], a[1], a[2]);
                    let want = tc["expected"].as_object().unwrap();
                    let pairs: [(&str, i64); 10] = [
                        ("r", got.r as i64), ("g", got.g as i64), ("bl", got.bl as i64),
                        ("h", got.h as i64), ("s", got.s as i64), ("b", got.b as i64),
                        ("c", got.c as i64), ("m", got.m as i64), ("y", got.y as i64),
                        ("k", got.k as i64),
                    ];
                    for (key, value) in pairs {
                        assert_eq!(value, want[key].as_i64().unwrap(),
                            "color_convert '{}': panel_channels.{}", name, key);
                    }
                    assert_eq!(got.hex, want["hex"].as_str().unwrap(),
                        "color_convert '{}': panel_channels.hex", name);
                }
                other => panic!("Unknown color_convert function: {}", other),
            }
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
        run_operation_model_from(setup_document(tc), tc)
    }

    /// The setup document a vector names, through whichever of the two doors
    /// it declares.
    ///
    /// `setup_svg` is the corpus-wide default. `setup_test_json` exists
    /// because the SVG codec has NO counterpart for a mask, a blend mode or a
    /// stroke alignment and no port writes a jas: extension for the gradients,
    /// the stroke brush or the width profile (the `svg` column of
    /// test_fixtures/expected/codec_field_survival.json) — so a corpus whose
    /// only door is SVG can never place those on a BYSTANDER, which is exactly
    /// the class EDIT_SEMANTICS_FREEZE.md T4 exists to watch. The canonical
    /// test JSON carries all twelve, so it is the door that can express the
    /// setup the law needs.
    fn setup_document(tc: &serde_json::Value) -> crate::document::document::Document {
        if let Some(name) = tc.get("setup_test_json").and_then(|v| v.as_str()) {
            test_json_to_document(&read_fixture(&format!("expected/{name}")))
        } else {
            svg_to_document(&read_fixture(&format!(
                "svg/{}", tc["setup_svg"].as_str().unwrap())))
        }
    }

    fn run_operation_model_from(
        doc: crate::document::document::Document,
        tc: &serde_json::Value,
    ) -> Model {
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

    /// Every `operations/` fixture that drives a golden, DERIVED from disk.
    ///
    /// This used to be a hand-typed list inline in `generate_operation_expected`,
    /// and on 2026-08-01 it carried **33 names against a corpus of 36**. The three
    /// it had silently stopped covering — `boolean_ops.json`,
    /// `paste_clipboard_text.json`, `paste_stacking.json` — were reachable by NO
    /// generator at all, so their goldens could not be regenerated by any means.
    /// Two of the three surfaced only because the R3 precision change reddened
    /// them and a complete regeneration left them red.
    ///
    /// The sibling corpora do not have this hazard because they share ONE list
    /// between the corpus test and its generator (`GESTURE_FIXTURES` is read at
    /// both sites, likewise `ACTION_FIXTURES`), so the two cannot drift from each
    /// other. The operations corpus has no such list: its cases are 36 separately
    /// named `#[test]` functions calling `run_operation_fixture` directly, which
    /// is right for granular failure reporting and left the generator enumerating
    /// the same corpus a second time, by hand. Two independent enumerations of one
    /// set is the drift.
    ///
    /// Deriving from disk removes the class rather than re-syncing the instance:
    /// a fixture added tomorrow is covered without anyone remembering. Verified at
    /// the time of the change that the derived set is EXACTLY the set the tests
    /// consume — 36 each, zero symmetric difference.
    fn operation_fixtures() -> Vec<String> {
        let dir = format!("{}/operations", FIXTURES);
        let entries = std::fs::read_dir(&dir)
            .unwrap_or_else(|e| panic!("cannot read {}: {}", dir, e));

        let mut out = Vec::new();
        for entry in entries {
            let name = entry.expect("unreadable dir entry").file_name()
                .to_string_lossy().into_owned();
            if !name.ends_with(".json") || name.ends_with("_expected.json") {
                continue;
            }
            // A fixture drives a golden iff its cases name one.
            if read_fixture(&format!("operations/{}", name)).contains("\"expected_json\"") {
                out.push(format!("operations/{}", name));
            }
        }
        out.sort();

        // FAIL CLOSED. A derived list that silently derives to EMPTY is worse
        // than the hand-typed one it replaced: every generator run would write
        // nothing, report success, and leave every golden stale. The scan
        // breaking must red, not pass.
        assert!(
            !out.is_empty(),
            "derived ZERO operation fixtures from {} -- the scan is broken, or the \
             corpus moved. Regenerating in this state would silently write nothing \
             while reporting success.",
            dir
        );
        out
    }

    /// Bootstrap helper: generate expected JSON for operation tests.
    /// Run with: cargo test generate_operation_expected -- --nocapture --ignored
    ///
    /// Covers whatever `operation_fixtures()` finds on disk — see the note there
    /// for why this is derived rather than listed.
    #[test]
    #[ignore]
    fn generate_operation_expected() {
        let fixtures = operation_fixtures();
        // State the scope where the work is reported: a reader must be able to
        // tell from the output alone how much of the corpus this run covered.
        eprintln!(
            "generate_operation_expected: {} fixture(s) derived from {}/operations",
            fixtures.len(),
            FIXTURES
        );
        for fixture in &fixtures {
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

    /// The corpus and its generator must enumerate the SAME set.
    ///
    /// Not ignored, so it runs in CI. The hand-typed list this replaced drifted
    /// to 33 against a corpus of 36 and nothing noticed for as long as it took an
    /// unrelated precision change to red two of the three orphans. This pins the
    /// property that made the drift possible: every fixture the corpus consumes
    /// must be one the generator can regenerate.
    #[test]
    fn every_operation_fixture_the_corpus_consumes_is_regenerable() {
        let derived: std::collections::BTreeSet<String> =
            operation_fixtures().into_iter().collect();

        // The corpus side, read from the test source rather than a second list —
        // a third enumeration would reintroduce exactly the drift being fixed.
        let src = include_str!("cross_language_test.rs");
        let mut consumed = std::collections::BTreeSet::new();
        const CALL: &str = "run_operation_fixture(\"";
        for (idx, _) in src.match_indices(CALL) {
            let arg = &src[idx + CALL.len()..];
            if let Some(end) = arg.find('"') {
                consumed.insert(arg[..end].to_string());
            }
        }

        assert!(
            !consumed.is_empty(),
            "scanned ZERO run_operation_fixture call sites -- the scan is broken \
             and this assertion would pass vacuously"
        );

        let unregenerable: Vec<_> = consumed.difference(&derived).collect();
        assert!(
            unregenerable.is_empty(),
            "{} fixture(s) are consumed by the corpus but reachable by no \
             generator, so their goldens cannot be regenerated by any means: {:?}",
            unregenerable.len(),
            unregenerable
        );
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
        // VIEWSEED: the same Rect drag at a NON-identity view (zoom 2, offset
        // (-100, -50)). Every other gesture vector runs at the identity view,
        // where the screen→doc conversion in pointer_event_payload is
        // algebraically the identity and a tool that skipped it would still
        // pass. See CORPUS_CENSUS.md §5.7.
        "draw_rect_zoomed.json",
        "draw_line.json",
        "draw_ellipse.json",
        "draw_ellipse_shift.json",
        "draw_rect_shift.json",
        // SHIFTZOOM: the same two Shift drags at zoom 1.5, where the
        // doc-space anchor is NOT dyadic. The pair above runs at zoom 1,
        // where every anchor is an exact integer and a commit that
        // RECOVERS the constrained side by re-subtracting the anchor
        // happens to be exact — which is why SHIFTCONSTRAIN shipped a
        // Shift that only drew a true circle/square at 100% zoom. Both
        // cases carry `expected_exact`, since the 4-dp canonical golden
        // cannot see the one-ulp gap between rx and ry.
        "draw_ellipse_shift_zoomed.json",
        "draw_rect_shift_zoomed.json",
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
        // D4 (SCOPE-effective-locked.md §3): the same click-select, but on a
        // document whose LAYERS overlap. Every other selection-family vector
        // is single-layer, where a forward and a reversed layer walk are the
        // same walk — so the corpus could not see that this port's layer loop
        // in doc_primitives::hit_test/hit_test_deep was NOT reversed while
        // Swift's and the live Python reference's both were. Topmost-first is
        // what hit-testing means, so the press at doc(36,36) — inside both the
        // Background rect and the Foreground circle — must resolve [1, 0].
        "select_click_multi_layer.json",
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
        "recorded_blob_dot.json",
        "recorded_blob_merge.json",
        "recorded_blob_separate.json",
        // TRANSFORM-BLIND MERGE gate (S-3). The setup's only element is a
        // blob-brush path whose LOCAL `d` is the square 0..72 (doc units) and
        // whose `common.transform` is translate(300,300) — so it RENDERS at
        // doc 300..372. The sweep runs at doc y=50 from x=50 to x=150, i.e.
        // the painted region is x 45..155 / y 45..55, which does not come
        // within 145 units of where that blob is drawn. The correct document
        // therefore has TWO children: the existing blob untouched, plus a new
        // blob at the painted location.
        //
        // What the transform-blind code produced: the match test ran
        // `path_to_polygon_set(&pe.d)` on the RAW `d` (0..72), which DOES
        // overlap the sweep, so the two merged into ONE child whose `d` was
        // the doc-space union pushed back through no matrix at all — one
        // child, and the new ink drawn offset by the matrix's (300, 300) from
        // where the artist put it. See transcripts/BLOB_BRUSH_TOOL.md
        // §Transform.
        "blob_transform_no_merge.json",
        // The POSITIVE half of the pair above. The setup is the same square
        // 0..72 with the transform removed, so it sits exactly under the sweep
        // and the merge is CORRECT: one child, the union, at doc x 0..155.
        //
        // Also a gate on `jas:tool-origin` surviving an SVG IMPORT.
        // `tool_origin` is not a key of the canonical test JSON, so no
        // serialization gate observes it directly; only a merge depends on it.
        // Counted mechanically: `grep -rl "jas:tool-origin" test_fixtures/svg`
        // returns three files, all added with these fixtures, and the two that
        // MERGE (this one and blob_transform_merge) are the ones whose goldens
        // change if the tag is dropped — blob_transform_no_merge yields two
        // children either way. This is the fixture that caught it.
        //
        // It is also the identity-transform guard on the transform work: a
        // matrix-aware merge must leave a transform-less element's result
        // byte-identical to what it was before.
        "blob_import_merge.json",
        // The n == 1 arm WITH a matrix — the only gate whose merged `d` is
        // written THROUGH a matrix, so the only one the inverse write-back can
        // be seen through (mutation-proved: dropping the inverse fails
        // gesture_corpus on this vector and nothing else). Same setup as
        // blob_transform_no_merge (local square 0..72, translate(300,300), so
        // drawn at doc 300..372); this sweep runs at doc y=336 from x=320 to
        // x=420, which DOES cross it. One child results, keeping the source's
        // id and its matrix, and `d` must come back in the source's LOCAL
        // space: the square unioned with the sweep mapped through the inverse,
        // spanning local x 0..125, y 0..72.
        //
        // Without the inverse the union is written in document coordinates and
        // the whole element is then drawn through translate(300,300) on top of
        // that — offset by (300, 300) from where it belongs — while every
        // field-list test (`assert_only_d_changed`) still passes: they graft
        // the source's `d` onto the output and never look at it.
        "blob_transform_merge.json",
    ];

    #[cfg(feature = "web")]
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

    #[cfg(feature = "web")]
    fn run_gesture_test(tc: &serde_json::Value) -> String {
        document_to_test_json(run_gesture_model(tc).document())
    }

    #[cfg(feature = "web")]
    /// Full-precision value of one named geometry field, for the
    /// `expected_exact` assertion below. Deliberately a short, explicit
    /// table rather than a reflective lookup: a fixture naming a field
    /// this list does not carry is a fixture bug, and saying so loudly
    /// beats silently asserting nothing.
    fn gesture_exact_field(el: &crate::geometry::element::Element, field: &str) -> f64 {
        use crate::geometry::element::Element;
        match (el, field) {
            (Element::Ellipse(e), "cx") => e.cx,
            (Element::Ellipse(e), "cy") => e.cy,
            (Element::Ellipse(e), "rx") => e.rx,
            (Element::Ellipse(e), "ry") => e.ry,
            (Element::Rect(r), "x") => r.x,
            (Element::Rect(r), "y") => r.y,
            (Element::Rect(r), "width") => r.width,
            (Element::Rect(r), "height") => r.height,
            _ => panic!("expected_exact: field {field:?} is not readable on {el:?}"),
        }
    }

    #[cfg(feature = "web")]
    /// OPTIONAL second assertion: `expected_exact`.
    ///
    /// The canonical document JSON rounds every float to 4 decimal
    /// places, which is right for a cross-language golden but blind to a
    /// one-ulp defect. Shift-constrained drawing is exactly that kind of
    /// contract — a circle is a circle only if rx and ry are the SAME
    /// double, and at a non-dyadic zoom a commit that re-derives the
    /// radius from a coordinate misses by ~1e-14, which the golden
    /// cannot show. This block names an element by path and pins chosen
    /// fields at FULL precision.
    ///
    /// The comparison is EXACT (`==` on f64), on the same reasoning as
    /// `assert_action_view`: both ports run the same IEEE-754 double
    /// operations on the same inputs and the fixture literals are
    /// shortest-round-trip forms, so any difference is a real
    /// divergence, not a formatting artifact. Cases without the block
    /// are unaffected. Mirrors Swift `assertGestureExact`.
    fn assert_gesture_exact(tc: &serde_json::Value, doc: &crate::document::document::Document) {
        let Some(exact) = tc.get("expected_exact") else { return };
        let name = tc["name"].as_str().unwrap();
        let path: Vec<usize> = exact["path"]
            .as_array()
            .expect("expected_exact.path must be an array")
            .iter()
            .map(|v| v.as_u64().expect("expected_exact.path entries must be integers") as usize)
            .collect();
        let el = doc
            .get_element(&path)
            .unwrap_or_else(|| panic!("expected_exact: '{name}' has no element at path {path:?}"));
        let fields = exact["fields"]
            .as_object()
            .expect("expected_exact.fields must be an object");
        for (field, want) in fields {
            let want = want.as_f64().expect("expected_exact field values must be numbers");
            let got = gesture_exact_field(el, field);
            assert!(
                got == want,
                "Gesture test '{name}': element {path:?} field {field} is {got:?}, \
                 expected EXACTLY {want:?} (delta {:e})",
                got - want
            );
        }
    }

    #[cfg(feature = "web")]
    /// Mirror of `assert_operation_test`: replay the gesture and compare
    /// the canonical document JSON against the pinned golden, dumping
    /// EXPECTED/ACTUAL on mismatch. Then apply the case's optional
    /// full-precision `expected_exact` pins.
    fn assert_gesture_test(tc: &serde_json::Value) {
        let name = tc["name"].as_str().unwrap();
        let expected_file = tc["expected_json"].as_str().unwrap();
        let expected = read_fixture(&format!("gestures/{}", expected_file));
        let expected = expected.trim();
        let model = run_gesture_model(tc);
        let actual = document_to_test_json(model.document());

        if actual != expected {
            eprintln!("=== EXPECTED ({}) ===", name);
            eprintln!("{}", expected);
            eprintln!("=== ACTUAL ({}) ===", name);
            eprintln!("{}", actual);
            panic!("Gesture test '{}' failed: canonical JSON mismatch", name);
        }

        assert_gesture_exact(tc, model.document());
    }

    #[cfg(feature = "web")]
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

    #[cfg(feature = "web")]
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
    // THE CIRCLE INVARIANT — a Shift-constrained draw is SQUARE
    // BIT-EXACTLY, at any zoom and any pan.
    //
    //     ellipse.rx == ellipse.ry        rect.width == rect.height
    //
    // Built as a CHECKER with a GENERATIVE lane rather than as more
    // gesture vectors, because vectors are the wrong instrument here.
    // DYADICSIDE fixed the cause (the constrained side is CARRIED in
    // `doc_w`/`doc_h`, never RECOVERED by re-subtracting the anchor)
    // but pinned it with two hand-picked drags, and the round trip
    // `(anchor + side) - anchor` only loses an ulp when the sum crosses
    // a binade — so most candidate vectors are exact BY LUCK and the
    // original defect needed a SEARCHED-FOR vector to show itself.
    //
    // Three lanes, in the ruled order — the checker is the law, the
    // corpus is its witnesses, the generative lane is its growing
    // confidence:
    //
    //   `check_shift_constrain`      the predicate (the law)
    //   `shift_constrain_witnesses`  the named corpus, deterministic
    //   `shift_constrain_generative` fresh vectors, fresh seed each run
    //
    // All three read test_fixtures/properties/shift_constrain_square.json,
    // whose `_doc` carries the full rationale. Mirrored in Swift as
    // `checkShiftConstrain` / `shiftConstrainWitnesses` /
    // `shiftConstrainGenerative` (JasSwift/Tests/CrossLanguageTests.swift).
    // ---------------------------------------------------------------

    /// One Shift-constrained draw, in the terms the checker takes: the
    /// view it happens on and the two viewport points that bracket it.
    #[cfg(feature = "web")]
    #[derive(Clone, Copy, Debug)]
    struct ShiftDraw {
        zoom: f64,
        offset_x: f64,
        offset_y: f64,
        press_x: f64,
        press_y: f64,
        release_x: f64,
        release_y: f64,
    }

    #[cfg(feature = "web")]
    impl ShiftDraw {
        /// The gesture case this draw denotes: press, one dragging move
        /// with Shift held, release at the same point with Shift held.
        /// Shaped for `run_gesture_model`, so the checker drives the
        /// PRODUCTION CanvasTool seam through the same shared replay
        /// path the gesture corpus uses — not a private re-derivation
        /// of what the tool would have done.
        fn gesture_case(&self, tool: &str, setup_svg: &str, viewport: (f64, f64)) -> serde_json::Value {
            serde_json::json!({
                "name": format!("shift_constrain/{tool}"),
                "setup_svg": setup_svg,
                "tool": tool,
                "view": {
                    "zoom_level": self.zoom,
                    "view_offset_x": self.offset_x,
                    "view_offset_y": self.offset_y,
                    "viewport_w": viewport.0,
                    "viewport_h": viewport.1,
                },
                "events": [
                    { "kind": "press", "x": self.press_x, "y": self.press_y },
                    { "kind": "move", "x": self.release_x, "y": self.release_y,
                      "dragging": true, "shift": true },
                    { "kind": "release", "x": self.release_x, "y": self.release_y,
                      "shift": true },
                ],
            })
        }
    }

    /// THE CHECKER. Replay `draw` with `tool` and rule the committed
    /// element legal: it must EXIST at `path`, and its two named fields
    /// must be the SAME double.
    ///
    /// Returns `None` when legal, `Some(complaint)` when not — a
    /// predicate rather than an assertion, so the generative lane can
    /// collect several failures and report the shape of them instead of
    /// aborting on the first.
    ///
    /// The equality is `==`, with no tolerance band, deliberately. A
    /// circle is a circle only if the radii are the same double: the
    /// model types the shape by comparing them and the 4-decimal-place
    /// canonical golden cannot see a 1e-14 gap, so an "almost equal"
    /// pair is exactly the defect this exists to catch.
    ///
    /// Mirrors Swift `checkShiftConstrain`.
    #[cfg(feature = "web")]
    fn check_shift_constrain(
        draw: &ShiftDraw,
        tool: &str,
        fields: (&str, &str),
        setup_svg: &str,
        path: &Vec<usize>,
        viewport: (f64, f64),
    ) -> Option<String> {
        let case = draw.gesture_case(tool, setup_svg, viewport);
        let model = run_gesture_model(&case);
        let Some(el) = model.document().get_element(path) else {
            return Some(format!(
                "{tool}: nothing was committed at path {path:?} — the 1-pixel \
                 commit guard suppressed the draw, so this case asserts nothing"
            ));
        };
        // `gesture_exact_field` panics on a field it does not carry —
        // the same explicit table the `expected_exact` channel reads,
        // so a fixture naming an unreadable field fails loudly.
        let a = gesture_exact_field(el, fields.0);
        let b = gesture_exact_field(el, fields.1);
        if a == b {
            return None;
        }
        Some(format!(
            "{tool}: {} = {a:?} but {} = {b:?} (delta {:e}) — a Shift-constrained \
             draw must be square BIT-EXACTLY; view zoom={:?} offset=({:?}, {:?}), \
             press=({:?}, {:?}), release=({:?}, {:?})",
            fields.0, fields.1, b - a,
            draw.zoom, draw.offset_x, draw.offset_y,
            draw.press_x, draw.press_y, draw.release_x, draw.release_y
        ))
    }

    /// THE MUTANT — the PRE-DYADICSIDE spelling, kept so the checker's
    /// teeth can be measured rather than assumed.
    ///
    /// This is NOT a second copy of the implementation; it is the BUG,
    /// written down. Before DYADICSIDE the commit recovered the half-side
    /// as `abs(doc_end - doc_start) / 2`, re-subtracting the anchor that
    /// had just been added to it, and that round trip is not exact away
    /// from a dyadic zoom. Returns the pair (x half-side, y half-side)
    /// the old spelling would have committed; they differ exactly on the
    /// vectors that spelling gets wrong.
    ///
    /// Used two ways: every witness asserts that the mutant's verdict
    /// matches its recorded `discriminating` flag, and the generative
    /// lane refuses a run in which too few of its fresh vectors could
    /// have caught the bug. A checker that cannot fail the bug it was
    /// written for is worth zero, so that is measured continuously.
    ///
    /// IF THE TOOLS' CONSTRAINT ARITHMETIC EVER CHANGES SHAPE, this must
    /// be re-derived or deleted outright — a stale mutant measures
    /// nothing while looking like it measures something. Spelled to
    /// match the YAML step for step, including `0.0 - side` for the
    /// negative branch (the expression language's `0 - max(...)`).
    /// Mirrors Swift `dyadicsideMutant`.
    #[cfg(feature = "web")]
    fn dyadicside_mutant(draw: &ShiftDraw) -> (f64, f64) {
        // doc = (screen - view_offset) / zoom — YamlTool::pointer_event_payload.
        let doc_start_x = (draw.press_x - draw.offset_x) / draw.zoom;
        let doc_start_y = (draw.press_y - draw.offset_y) / draw.zoom;
        let doc_x = (draw.release_x - draw.offset_x) / draw.zoom;
        let doc_y = (draw.release_y - draw.offset_y) / draw.zoom;
        let side = (doc_x - doc_start_x).abs().max((doc_y - doc_start_y).abs());
        let doc_end_x = doc_start_x + if doc_x >= doc_start_x { side } else { 0.0 - side };
        let doc_end_y = doc_start_y + if doc_y >= doc_start_y { side } else { 0.0 - side };
        (
            (doc_end_x - doc_start_x).abs() / 2.0,
            (doc_end_y - doc_start_y).abs() / 2.0,
        )
    }

    /// Would the pre-DYADICSIDE spelling get this vector WRONG?
    #[cfg(feature = "web")]
    fn mutant_is_discriminating(draw: &ShiftDraw) -> bool {
        let (a, b) = dyadicside_mutant(draw);
        a != b
    }

    /// The shared property fixture, parsed once per test.
    #[cfg(feature = "web")]
    fn shift_constrain_fixture() -> serde_json::Value {
        let raw = read_fixture("properties/shift_constrain_square.json");
        serde_json::from_str(&raw)
            .expect("properties/shift_constrain_square.json is not valid JSON")
    }

    /// `(tool id, (field a, field b))` pairs the fixture declares.
    #[cfg(feature = "web")]
    fn shift_constrain_tools(fx: &serde_json::Value) -> Vec<(String, (String, String))> {
        fx["tools"]
            .as_array()
            .expect("property fixture must declare `tools`")
            .iter()
            .map(|t| {
                let fields = t["fields"].as_array().expect("tool entry needs `fields`");
                assert_eq!(fields.len(), 2, "a tool's `fields` names exactly the pair that must be equal");
                (
                    t["tool"].as_str().unwrap().to_string(),
                    (
                        fields[0].as_str().unwrap().to_string(),
                        fields[1].as_str().unwrap().to_string(),
                    ),
                )
            })
            .collect()
    }

    /// The fixture's setup / path / viewport, shared by both lanes.
    #[cfg(feature = "web")]
    fn shift_constrain_env(fx: &serde_json::Value) -> (String, Vec<usize>, (f64, f64)) {
        let setup = fx["setup_svg"].as_str().unwrap().to_string();
        let path: Vec<usize> = fx["element_path"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_u64().unwrap() as usize)
            .collect();
        let viewport = (
            fx["viewport_w"].as_f64().unwrap(),
            fx["viewport_h"].as_f64().unwrap(),
        );
        (setup, path, viewport)
    }

    /// LANE 2 — THE WITNESSES. Every named vector, against every tool,
    /// deterministically, every run.
    ///
    /// Also asserts each witness's recorded `discriminating` flag
    /// against the mutant, so the corpus proves its own teeth: nine of
    /// the eleven vectors here would have caught the DYADICSIDE bug, and
    /// this test says so out loud every run rather than trusting a
    /// comment written the day they were searched for.
    #[cfg(feature = "web")]
    #[test]
    fn shift_constrain_witnesses() {
        let fx = shift_constrain_fixture();
        let (setup, path, viewport) = shift_constrain_env(&fx);
        let tools = shift_constrain_tools(&fx);
        let witnesses = fx["witnesses"].as_array().expect("fixture needs `witnesses`");
        assert!(!witnesses.is_empty(), "the witness corpus must not be empty");

        let mut discriminating = 0usize;
        let mut failures: Vec<String> = Vec::new();

        for w in witnesses {
            let name = w["name"].as_str().unwrap();
            let press = w["press"].as_array().unwrap();
            let release = w["release"].as_array().unwrap();
            let draw = ShiftDraw {
                zoom: w["zoom"].as_f64().unwrap(),
                offset_x: w["view_offset_x"].as_f64().unwrap(),
                offset_y: w["view_offset_y"].as_f64().unwrap(),
                press_x: press[0].as_f64().unwrap(),
                press_y: press[1].as_f64().unwrap(),
                release_x: release[0].as_f64().unwrap(),
                release_y: release[1].as_f64().unwrap(),
            };

            // The witness's claim about its own power, checked.
            let claimed = w["discriminating"].as_bool().unwrap_or_else(|| {
                panic!("witness '{name}' must record `discriminating`")
            });
            let actual = mutant_is_discriminating(&draw);
            assert_eq!(
                actual, claimed,
                "witness '{name}' records discriminating={claimed}, but the \
                 pre-DYADICSIDE mutant says {actual} (mutant halves {:?}). Either \
                 the flag is stale or the mutant no longer models the old spelling.",
                dyadicside_mutant(&draw)
            );
            if actual {
                discriminating += 1;
            }

            for (tool, (fa, fb)) in &tools {
                if let Some(why) =
                    check_shift_constrain(&draw, tool, (fa, fb), &setup, &path, viewport)
                {
                    failures.push(format!("witness '{name}': {why}"));
                }
            }
        }

        assert!(
            discriminating >= 2,
            "the witness corpus has lost its teeth: only {discriminating} of {} \
             vectors would catch the pre-DYADICSIDE spelling",
            witnesses.len()
        );
        assert!(
            failures.is_empty(),
            "the circle invariant failed on {} witness/tool pair(s):\n  {}",
            failures.len(),
            failures.join("\n  ")
        );
    }

    // ---------------------------------------------------------------
    // The seeded input stream. Spelled identically in Swift
    // (`PropertyStream` / `propertySeed` / `shiftDrawSample`) so a seed
    // that goes red in one port replays vector-for-vector in the other
    // — pinned by `stream_pin` in the fixture.
    // ---------------------------------------------------------------

    /// The house LCG (Numerical Recipes constants, as in `boolean.rs`
    /// and `shape_recognize.rs`), on a SplitMix64-finalized seed.
    ///
    /// The finalizer matters: raw LCG states for adjacent seeds differ
    /// by only the multiplier, so `JAS_PROPERTY_SEED=1` and `=2` would
    /// otherwise produce near-identical first draws — a trap for anyone
    /// replaying by hand.
    #[cfg(feature = "web")]
    struct PropertyStream {
        state: u64,
    }

    #[cfg(feature = "web")]
    impl PropertyStream {
        fn new(seed: u64) -> Self {
            let mut z = seed;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
            PropertyStream { state: z ^ (z >> 31) }
        }

        /// Next draw, uniform in [0, 1).
        fn u(&mut self) -> f64 {
            self.state = self.state.wrapping_mul(1664525).wrapping_add(1013904223);
            (self.state >> 11) as f64 / (1u64 << 53) as f64
        }
    }

    #[cfg(feature = "web")]
    fn lerp(lo: f64, hi: f64, u: f64) -> f64 {
        lo + (hi - lo) * u
    }

    /// A signed magnitude in [lo, hi] from ONE draw: the low half of the
    /// unit interval is the negative branch, the high half the positive
    /// one, each rescaled back to [0, 1). Both rescalings are exact in
    /// binary (Sterbenz on `u - 0.5`, and a multiply by 2), so the two
    /// ports cannot disagree about them.
    #[cfg(feature = "web")]
    fn signed_magnitude(u: f64, lo: f64, hi: f64) -> f64 {
        if u < 0.5 {
            -(lo + (hi - lo) * (u * 2.0))
        } else {
            lo + (hi - lo) * ((u - 0.5) * 2.0)
        }
    }

    /// Draw ONE Shift-constrained draw from the stream. Nine values, in
    /// the order the fixture's `_generative_doc` records; both ports
    /// must consume them in that order or the streams diverge.
    ///
    /// The drag is an OFFSET from the press, not an independent second
    /// point, so `drag_min` guarantees the 1-pixel commit guard is
    /// cleared and no rejection sampling is needed — every draw is a
    /// real case. Mirrors Swift `shiftDrawSample`.
    #[cfg(feature = "web")]
    fn shift_draw_sample(st: &mut PropertyStream, cfg: &serde_json::Value) -> ShiftDraw {
        let n = |k: &str| cfg[k].as_f64().unwrap_or_else(|| panic!("generative.{k} must be a number"));
        let zoom = lerp(n("zoom_min"), n("zoom_max"), st.u());
        let offset_x = lerp(n("offset_min"), n("offset_max"), st.u());
        let offset_y = lerp(n("offset_min"), n("offset_max"), st.u());
        let mut press_x = lerp(n("press_min"), n("press_max"), st.u());
        let mut press_y = lerp(n("press_min"), n("press_max"), st.u());
        let mut dx = signed_magnitude(st.u(), n("drag_min"), n("drag_max"));
        let mut dy = signed_magnitude(st.u(), n("drag_min"), n("drag_max"));

        // Axis lock: a pure horizontal or vertical Shift drag takes the
        // other branch (the zero axis has no sign to follow, so it takes
        // the positive one). A continuous generator produces an exact
        // zero with probability zero, so it has to be asked for. At most
        // one axis is zeroed — both would fail the commit guard.
        let axis = st.u();
        let p = n("axis_zero_p");
        if axis < p {
            dy = 0.0;
        } else if axis < 2.0 * p {
            dx = 0.0;
        }

        let mut release_x = press_x + dx;
        let mut release_y = press_y + dy;

        // Quantize lock: real pointer events are usually integral, and
        // integral screen coordinates are a measurably different
        // population (at zoom 0.1, 1/3 and 1.0 they are exact under the
        // old spelling where continuous ones are not). Rounding shaves
        // at most 1 px off the drag, and drag_min is 3, so the commit
        // guard still holds.
        if st.u() < n("quantize_p") {
            press_x = press_x.round();
            press_y = press_y.round();
            release_x = release_x.round();
            release_y = release_y.round();
        }

        ShiftDraw { zoom, offset_x, offset_y, press_x, press_y, release_x, release_y }
    }

    /// The seed for this run: `JAS_PROPERTY_SEED` if the environment
    /// names one, otherwise the nanosecond clock. FRESH EVERY RUN is
    /// the point — the lane exists to see vectors nobody chose.
    /// Mirrors Swift `propertySeed`.
    #[cfg(feature = "web")]
    fn property_seed() -> u64 {
        if let Ok(s) = std::env::var("JAS_PROPERTY_SEED") {
            return s
                .trim()
                .parse::<u64>()
                .unwrap_or_else(|e| panic!("JAS_PROPERTY_SEED={s:?} is not a u64: {e}"));
        }
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0x5EED_1234_ABCD_0001)
    }

    /// LANE 3 — THE GENERATIVE LANE. The same checker, on vectors nobody
    /// chose, from a fresh seed every run.
    ///
    /// Three things are asserted, and the second and third are what keep
    /// the lane from rotting into a no-op:
    ///
    ///   * every generated vector satisfies the circle invariant;
    ///   * every generated vector actually COMMITTED an element (the
    ///     count is checked against `cases`), so the guard can never
    ///     quietly swallow the population;
    ///   * at least `min_discriminating` of them are vectors the
    ///     pre-DYADICSIDE spelling would get WRONG, measured live by the
    ///     mutant — the lane's teeth, checked rather than assumed.
    ///
    /// A failure prints the seed. `JAS_PROPERTY_SEED=<that seed>`
    /// replays the run exactly, here or in Swift.
    #[cfg(feature = "web")]
    #[test]
    fn shift_constrain_generative() {
        let fx = shift_constrain_fixture();
        let (setup, path, viewport) = shift_constrain_env(&fx);
        let tools = shift_constrain_tools(&fx);
        let cfg = &fx["generative"];
        let cases = cfg["cases"].as_u64().expect("generative.cases") as usize;
        let min_discriminating =
            cfg["min_discriminating"].as_u64().expect("generative.min_discriminating") as usize;

        // The cross-language pin: both ports must draw the SAME vectors
        // from the same seed, or a seed reported by one is meaningless
        // in the other.
        assert_stream_pin(&fx);

        let seed = property_seed();
        eprintln!(
            "shift_constrain_generative: seed {seed} ({cases} cases x {} tools) — \
             replay with JAS_PROPERTY_SEED={seed}",
            tools.len()
        );

        let mut st = PropertyStream::new(seed);
        let mut discriminating = 0usize;
        let mut committed = 0usize;
        let mut failures: Vec<String> = Vec::new();

        for i in 0..cases {
            let draw = shift_draw_sample(&mut st, cfg);
            if mutant_is_discriminating(&draw) {
                discriminating += 1;
            }
            for (tool, (fa, fb)) in &tools {
                match check_shift_constrain(&draw, tool, (fa, fb), &setup, &path, viewport) {
                    None => committed += 1,
                    Some(why) => {
                        // Cap the report: the first handful shows the
                        // shape, and the seed reproduces the rest.
                        if failures.len() < 8 {
                            failures.push(format!("case {i}: {why}"));
                        }
                    }
                }
            }
        }

        assert!(
            failures.is_empty(),
            "seed {seed}: the circle invariant failed on generated vectors \
             (showing up to 8):\n  {}\nReplay with JAS_PROPERTY_SEED={seed}",
            failures.join("\n  ")
        );
        // Reached only when nothing failed, so every check committed.
        assert_eq!(
            committed,
            cases * tools.len(),
            "seed {seed}: only {committed} of {} generated draws committed an \
             element — the generator has drifted below the 1-pixel commit guard \
             and is asserting nothing",
            cases * tools.len()
        );
        assert!(
            discriminating >= min_discriminating,
            "seed {seed}: only {discriminating} of {cases} generated vectors would \
             catch the pre-DYADICSIDE spelling (floor {min_discriminating}). The \
             generator has been narrowed or broken; a lane that cannot fail the bug \
             it was written for is worth zero."
        );
        // Report the teeth on the SUCCESS path too. A floor that is only
        // read when it trips hides a slow slide toward it; this number
        // is the one to watch if the generator is ever retuned.
        eprintln!(
            "shift_constrain_generative: {discriminating}/{cases} generated vectors \
             discriminate the pre-DYADICSIDE spelling (floor {min_discriminating})"
        );
    }

    /// One pinned double, read as an IEEE-754 bit pattern in hex.
    ///
    /// NOT `as_f64()` on a decimal literal, and the reason is measured:
    /// serde_json 1.0.149 with default features (what this crate builds
    /// today) mis-parses 21397 of 199903 SHORTEST-ROUND-TRIP f64
    /// literals by exactly 1 ulp — 10.7%. Rust's own `str::parse`,
    /// Swift's `Double(String)` and Swift's JSONSerialization all read
    /// the same literals correctly, so the error is one-sided and
    /// invisible from the Swift arm. A decimal pin here would therefore
    /// not be a shared value at all, and a bit-exactness gate built on
    /// one would report phantom reds and phantom greens with equal
    /// confidence. See the fixture's `_stream_pin_doc`.
    #[cfg(feature = "web")]
    fn pinned_f64(v: &serde_json::Value) -> f64 {
        let s = v
            .as_str()
            .unwrap_or_else(|| panic!("stream_pin values are hex bit-pattern strings, got {v}"));
        let hex = s.strip_prefix("0x").unwrap_or(s);
        f64::from_bits(
            u64::from_str_radix(hex, 16)
                .unwrap_or_else(|e| panic!("stream_pin value {s:?} is not hex: {e}")),
        )
    }

    /// Both ports draw the same vectors from the same seed. Compares the
    /// first few cases of a FIXED seed against bit-pattern pins,
    /// `==` on doubles. Mirrors Swift `assertStreamPin`.
    #[cfg(feature = "web")]
    fn assert_stream_pin(fx: &serde_json::Value) {
        let pin = &fx["stream_pin"];
        let seed = pin["seed"].as_u64().expect("stream_pin.seed");
        let cfg = &fx["generative"];
        let mut st = PropertyStream::new(seed);
        for (i, want) in pin["cases"].as_array().unwrap().iter().enumerate() {
            let got = shift_draw_sample(&mut st, cfg);
            let press = want["press"].as_array().unwrap();
            let release = want["release"].as_array().unwrap();
            let expect: [(&str, f64, f64); 7] = [
                ("zoom", got.zoom, pinned_f64(&want["zoom"])),
                ("view_offset_x", got.offset_x, pinned_f64(&want["view_offset_x"])),
                ("view_offset_y", got.offset_y, pinned_f64(&want["view_offset_y"])),
                ("press_x", got.press_x, pinned_f64(&press[0])),
                ("press_y", got.press_y, pinned_f64(&press[1])),
                ("release_x", got.release_x, pinned_f64(&release[0])),
                ("release_y", got.release_y, pinned_f64(&release[1])),
            ];
            for (field, g, w) in expect {
                assert!(
                    g == w,
                    "stream_pin seed {seed} case {i}: {field} is {g:?} (bits {:#018x}), \
                     expected EXACTLY {w:?} (bits {:#018x}). The two ports are no longer \
                     fuzzing the same space, so every seed exchanged between them is \
                     meaningless.",
                    g.to_bits(),
                    w.to_bits()
                );
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

    #[cfg(feature = "web")]
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

    #[cfg(feature = "web")]
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

    #[cfg(feature = "web")]
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
        // CPTRIAGE: the fill_stroke None verbs. The FIRST cases to carry an
        // `expected_panel_state` block — the document golden alone cannot see
        // the defect these were written for (a None that the panel-render
        // state reader never republished, so the Color panel's guards kept
        // reading the old colour). See `assert_action_panel_state`.
        "fill_stroke_none.json",
        // COLORTIERS: the action-dispatch `state` scope is SELECTION-AWARE.
        // `set_fill_type_solid` on a stroke-only SELECTION must read that
        // selection's None and paint it; Rust's `build_appstate_ctx` used to
        // read the app default alone, so the click was a silent no-op there
        // and painted in Swift. The second case pins the Mixed outcome (the
        // declared default stands — absent is not null).
        "fill_stroke_action_scope.json",
        // VIEWSEED: the FIRST fixtures anywhere in test_fixtures/ that set
        // zoom_level / view_offset. Every other case runs at the identity
        // view, where screen↔doc conversion is algebraically the identity and
        // so cannot fail (CORPUS_CENSUS.md §5.7). These cases seed a
        // non-identity view via `view` and assert the resulting view triple
        // via `expected_view` — a fact NO document golden can see, because
        // view state is not document content.
        "view_state.json",
        // LAYERSTRUCT R1 (transcripts/LAYER_STRUCTURE.md §3): group always
        // flattens. Before R1 a selection whose members did not share one
        // parent was a silent no-op in BOTH ports, and NO fixture anywhere
        // grouped across parents — so the defect and then the ruling arrived
        // unwatched. These cases cross two layers, two sibling groups, a
        // layer and a nested group, and pin the frontmost z-slot placement
        // that `actions.yaml` §group always specified but neither port
        // implemented. The contiguous same-parent case stays pinned by
        // `menu_group_two_rects` in menu_object_ops.json, which R1 must leave
        // byte-identical.
        "group_flatten.json",
        // LOCKINHERIT (transcripts/LAYER_STRUCTURE.md §13): Select All and
        // inherited lock. `actions.yaml` §select_all always said "locked
        // objects are excluded" without saying WHOSE flag, and the two ports
        // answered differently — Rust's hand-rolled loop never checked the
        // LAYER's, so Select All swept up a locked layer's whole contents while
        // Swift skipped it. Deliberately groupless in the open layer: Select
        // All's group-expansion difference (SCOPE-effective-locked.md D2 / Q2)
        // is UNRULED and would red here for a reason that is not about lock.
        "lock_inheritance_actions.json",
    ];

    #[cfg(feature = "web")]
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

    #[cfg(feature = "web")]
    /// Serialize the document the action sequence produced (mirrors
    /// `run_gesture_test`).
    fn run_action_test(tc: &serde_json::Value) -> String {
        let st = run_action_model(tc);
        document_to_test_json(st.tabs[st.active_tab].model.document())
    }

    #[cfg(feature = "web")]
    /// OPTIONAL second assertion: `expected_panel_state`.
    ///
    /// The document is not the only thing an action moves. A `fill_stroke`
    /// verb writes an APP-LEVEL fact, and every panel that reads it back
    /// does so through the port's panel-render state reader — Rust's
    /// `build_live_state_map`, Swift's `buildLiveStateMap`. Those readers
    /// are native per-port code that no document golden touches, and they
    /// drifted: `set_fill_none` cleared the fill in both ports while the
    /// Rust reader kept publishing the workspace default `#ffffff`
    /// (CPTRIAGE), so `color.yaml`'s fifteen slider `disabled` guards, the
    /// hex field, the colour bar and Invert / Complement all read a colour
    /// that was no longer there and NOTHING a user could see moved.
    ///
    /// So a case may pin the state scope the panels actually render
    /// against. The block is a SUBSET assertion — name only the keys under
    /// test — and `null` is a real expectation, not "absent": publishing
    /// Null is the whole point, because the map starts from the workspace
    /// defaults and an omitted key leaves the default standing.
    ///
    /// Cases without the block are unaffected. Mirrors Swift's
    /// `assertActionPanelState`.
    fn assert_action_panel_state(
        tc: &serde_json::Value, st: &crate::workspace::app_state::AppState,
    ) {
        let Some(expected) = tc.get("expected_panel_state").and_then(|v| v.as_object())
        else { return };
        let name = tc["name"].as_str().unwrap();
        let live = crate::workspace::dock_panel::build_live_state_map(st);
        for (key, want) in expected {
            // ABSENT is not NULL, and the docstring above says so: the reader
            // must PUBLISH the key. Asserting presence separately is what lets
            // a `null` expectation catch the regression it was written for — a
            // port that stops seeding / overlaying and omits the key instead.
            // Coalescing the two would read that omission as a published null.
            assert!(
                live.contains_key(key),
                "Action test '{}': the panel-render state map has no key {:?} \
                 at all. The corpus pins its VALUE, so the key must be \
                 published — an absent key leaves whatever the caller had \
                 (here the workspace default) standing.",
                name, key,
            );
            let got = &live[key];
            assert_eq!(
                got, want,
                "Action test '{}': panel-render state.{} is {} but the corpus \
                 pins {}. The panels read this map, so a wrong value here is a \
                 control that renders against a fact the action already changed.",
                name, key, got, want,
            );
        }
    }

    #[cfg(feature = "web")]
    /// OPTIONAL third assertion: `expected_view`.
    ///
    /// View state — `zoom_level`, `view_offset_x`, `view_offset_y` — is
    /// NOT document content, so `document_to_test_json` cannot see it and
    /// no golden in this corpus constrained it before VIEWSEED. Combined
    /// with the case's `view` seed this is the whole point of the
    /// view-state family: run the action off the identity view and pin
    /// the triple the view effects produce.
    ///
    /// The comparison is EXACT (`==` on f64). Both ports evaluate the same
    /// IEEE-754 double operations on the same inputs, and the fixture
    /// literals are shortest-round-trip forms, so any difference is a real
    /// divergence and not a formatting artifact. Cases without the block
    /// are unaffected. Mirrors Swift's `assertActionView`.
    fn assert_action_view(
        tc: &serde_json::Value, st: &crate::workspace::app_state::AppState,
    ) {
        let Some(expected) = tc.get("expected_view").and_then(|v| v.as_object())
        else { return };
        let name = tc["name"].as_str().unwrap();
        // Read the triple straight off the Model the run produced: view
        // state is NOT document content, so the golden cannot carry it.
        let model = &st.tabs[st.active_tab].model;
        let (zoom, offx, offy) =
            (model.zoom_level, model.view_offset_x, model.view_offset_y);
        for (key, want) in expected {
            let want = want.as_f64().unwrap_or_else(|| {
                panic!("Action test '{}': expected_view.{} is not a number", name, key)
            });
            let got = match key.as_str() {
                "zoom_level" => zoom,
                "view_offset_x" => offx,
                "view_offset_y" => offy,
                other => panic!(
                    "Action test '{}': expected_view names {:?}, which is not part \
                     of the view triple (zoom_level / view_offset_x / view_offset_y)",
                    name, other,
                ),
            };
            assert_eq!(
                got, want,
                "Action test '{}': view state {} is {} but the corpus pins {}. \
                 The view transform decides which region of the document the \
                 user is looking at and how every screen coordinate converts, \
                 so a wrong value here is a canvas that shows the wrong thing.",
                name, key, got, want,
            );
        }
    }

    #[cfg(feature = "web")]
    /// Mirror of `assert_gesture_test`: replay the action sequence and
    /// compare the canonical document JSON against the pinned golden,
    /// dumping EXPECTED/ACTUAL on mismatch. Then apply the case's optional
    /// `expected_panel_state` and `expected_view` blocks.
    fn assert_action_test(tc: &serde_json::Value) {
        let name = tc["name"].as_str().unwrap();
        let expected_file = tc["expected_json"].as_str().unwrap();
        let expected = read_fixture(&format!("actions/{}", expected_file));
        let expected = expected.trim();
        let st = run_action_model(tc);
        let actual = document_to_test_json(st.tabs[st.active_tab].model.document());

        if actual != expected {
            eprintln!("=== EXPECTED ({}) ===", name);
            eprintln!("{}", expected);
            eprintln!("=== ACTUAL ({}) ===", name);
            eprintln!("{}", actual);
            panic!("Action test '{}' failed: canonical JSON mismatch", name);
        }
        assert_action_panel_state(tc, &st);
        assert_action_view(tc, &st);
    }

    #[cfg(feature = "web")]
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

    #[cfg(feature = "web")]
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

    // ===============================================================
    // PRESERVATION corpus — the DOCUMENT-LEVEL INVARIANT GATE
    // (transcripts/EDIT_SEMANTICS_FREEZE.md §4.1, the primary tier).
    //
    // The freeze's own finding is that a per-copy-API battery is
    // structurally blind to the gravest violation class: inline
    // container rebuilds are not copy APIs, so no battery would ever be
    // written for them. This gate does not look at any copy site. It
    // serializes the WHOLE document before and after an edit and asserts
    // six invariants over the canonical (cross-language) test JSON —
    // "one predicate both ports can fail identically" (§4.2). The Swift
    // twin in JasSwift/Tests/CrossLanguageTests.swift evaluates exactly
    // the same six names over exactly the same vectors.
    //
    // A vector may PIN a known violation for this port. A pinned
    // invariant is asserted to FAIL: fixing the site turns this gate red
    // until the pin is removed, so a pin can never rot into a silent
    // suppression. `scripts/check_preservation_corpus.py` gates the data
    // shape (V1-V5 anti-vacuity).
    // ===============================================================

    /// One evaluated invariant: `None` = held, `Some(why)` = violated.
    type InvResult = (&'static str, Option<String>);

    /// Recursively collect every id-bearing element of a canonical
    /// document JSON: the ids in document order, and each id's own
    /// attribute object with `children` stripped (a container that
    /// legitimately gained or lost a child still has ITS OWN fields
    /// compared — that is the T4 bystander predicate).
    fn preservation_walk(
        node: &serde_json::Value,
        ids: &mut Vec<String>,
        attrs: &mut std::collections::HashMap<String, serde_json::Value>,
    ) {
        match node {
            serde_json::Value::Array(items) => {
                for it in items {
                    preservation_walk(it, ids, attrs);
                }
            }
            serde_json::Value::Object(obj) => {
                if obj.contains_key("type")
                    && let Some(id) = obj.get("id").and_then(|v| v.as_str())
                {
                    ids.push(id.to_string());
                    let mut stripped = obj.clone();
                    stripped.remove("children");
                    attrs.insert(id.to_string(), serde_json::Value::Object(stripped));
                }
                for key in ["layers", "children", "symbols"] {
                    if let Some(v) = obj.get(key) {
                        preservation_walk(v, ids, attrs);
                    }
                }
            }
            _ => {}
        }
    }

    struct PreservationSnapshot {
        ids: Vec<String>,
        attrs: std::collections::HashMap<String, serde_json::Value>,
    }

    fn preservation_snapshot(doc_json: &str) -> PreservationSnapshot {
        let v: serde_json::Value = serde_json::from_str(doc_json)
            .expect("canonical document JSON parses");
        let mut ids = Vec::new();
        let mut attrs = std::collections::HashMap::new();
        preservation_walk(&v, &mut ids, &mut attrs);
        PreservationSnapshot { ids, attrs }
    }

    fn str_list(tc: &serde_json::Value, key: &str) -> Vec<String> {
        tc[key]
            .as_array()
            .unwrap_or_else(|| panic!("preservation vector needs a '{key}' array"))
            .iter()
            .map(|v| v.as_str().expect("a string").to_string())
            .collect()
    }

    /// Evaluate the six document-level invariants for one vector.
    fn preservation_invariants_for(
        tc: &serde_json::Value,
        before: &PreservationSnapshot,
        after: &PreservationSnapshot,
    ) -> Vec<InvResult> {
        use std::collections::BTreeSet;
        let subject: BTreeSet<String> = str_list(tc, "subject_ids").into_iter().collect();
        let consumed: BTreeSet<String> = str_list(tc, "consumed_ids").into_iter().collect();
        let speaks_to: BTreeSet<String> = str_list(tc, "speaks_to").into_iter().collect();
        let want_fresh = tc["expected_fresh_ids"].as_u64().expect("expected_fresh_ids") as usize;

        let before_set: BTreeSet<&String> = before.ids.iter().collect();
        let after_set: BTreeSet<&String> = after.ids.iter().collect();

        let mut out: Vec<InvResult> = Vec::new();

        // id_uniqueness — the REFERENCE_GRAPH.md §2.5 uniqueness invariant,
        // document-wide, after the edit.
        let mut dups: Vec<&String> = Vec::new();
        for id in &after.ids {
            if after.ids.iter().filter(|o| *o == id).count() > 1 && !dups.contains(&id) {
                dups.push(id);
            }
        }
        out.push((
            "id_uniqueness",
            if dups.is_empty() {
                None
            } else {
                Some(format!("id(s) appear more than once after the edit: {dups:?}"))
            },
        ));

        // id_survival — every identity the edit did not consume is still there.
        let lost: Vec<&&String> = before_set
            .iter()
            .filter(|id| !consumed.contains(**id) && !after_set.contains(**id))
            .collect();
        out.push((
            "id_survival",
            if lost.is_empty() {
                None
            } else {
                Some(format!("id(s) present before and NOT consumed vanished: {lost:?}"))
            },
        ));

        // consumed_ids_die — over-preservation is a violation too (§3.3).
        let survived: Vec<&String> = consumed.iter().filter(|id| after_set.contains(id)).collect();
        out.push((
            "consumed_ids_die",
            if survived.is_empty() {
                None
            } else {
                Some(format!(
                    "id(s) the edit consumed rode out on the result: {survived:?}"
                ))
            },
        ));

        // fresh_ids — how many identities the edit minted.
        let fresh: Vec<&&String> = after_set.iter().filter(|id| !before_set.contains(**id)).collect();
        out.push((
            "fresh_ids",
            if fresh.len() == want_fresh {
                None
            } else {
                Some(format!(
                    "expected {want_fresh} freshly minted id(s), got {} ({fresh:?})",
                    fresh.len()
                ))
            },
        ));

        // bystanders_unchanged — T4, including the containers the edit
        // rebuilt to reach its target. Compared only for bystanders that
        // still carry their id after the edit; a bystander whose id was
        // destroyed is id_survival's failure, not this one's.
        let mut byst_fail: Vec<String> = Vec::new();
        for id in &before_set {
            if subject.contains(*id) || consumed.contains(*id) {
                continue;
            }
            let (Some(b), Some(a)) = (before.attrs.get(*id), after.attrs.get(*id)) else {
                continue;
            };
            if b != a {
                byst_fail.push(format!("{id}: {b} -> {a}"));
            }
        }
        out.push((
            "bystanders_unchanged",
            if byst_fail.is_empty() {
                None
            } else {
                Some(format!("bystander attributes changed: {byst_fail:?}"))
            },
        ));

        // subject_fields_only — clause 1: only the spoken-to keys may differ.
        let mut subj_fail: Vec<String> = Vec::new();
        for id in &subject {
            let (Some(b), Some(a)) = (before.attrs.get(id), after.attrs.get(id)) else {
                continue;
            };
            let bo = b.as_object().unwrap();
            let ao = a.as_object().unwrap();
            let keys: BTreeSet<&String> = bo.keys().chain(ao.keys()).collect();
            for k in keys {
                if speaks_to.contains(k) {
                    continue;
                }
                if bo.get(k) != ao.get(k) {
                    subj_fail.push(format!("{id}.{k}: {:?} -> {:?}", bo.get(k), ao.get(k)));
                }
            }
        }
        out.push((
            "subject_fields_only",
            if subj_fail.is_empty() {
                None
            } else {
                Some(format!(
                    "subject changed keys outside speaks_to {speaks_to:?}: {subj_fail:?}"
                ))
            },
        ));

        out
    }

    /// Anti-vacuity, asserted at RUNTIME (the data-shape half lives in
    /// `scripts/check_preservation_corpus.py`): the edit must have changed
    /// the document, every named id must have existed before it, and there
    /// must be at least one bystander to watch.
    fn assert_preservation_not_vacuous(
        name: &str,
        tc: &serde_json::Value,
        before_json: &str,
        after_json: &str,
        before: &PreservationSnapshot,
        after: &PreservationSnapshot,
    ) {
        assert_ne!(
            before_json, after_json,
            "preservation vector '{name}' left the document byte-identical — \
             every invariant over it would be vacuously true"
        );
        for key in ["subject_ids", "consumed_ids"] {
            for id in str_list(tc, key) {
                assert!(
                    before.ids.contains(&id),
                    "preservation vector '{name}' names {key} id '{id}', which is \
                     absent from the loaded setup document"
                );
            }
        }
        let named: Vec<String> = str_list(tc, "subject_ids")
            .into_iter()
            .chain(str_list(tc, "consumed_ids"))
            .collect();
        let bystanders = before.ids.iter().filter(|i| !named.contains(i)).count();
        assert!(
            bystanders > 0,
            "preservation vector '{name}' has no bystander — T4 is unwatchable here"
        );

        // `bystander_fields_present` (optional) is the DOCUMENT-LEVEL form of
        // §3.1's anti-vacuity guard: "every battery asserts its fixture
        // differs from the default in every non-subject field, because a rich
        // fixture that silently decays to defaults passes on nothing".
        // `bystanders_unchanged` compares before against after, so a setup
        // that lost its mask on the way IN would compare two identical
        // mask-less snapshots and pass. Naming a field here asserts the
        // BEFORE snapshot really carries it.
        //
        // A dotted name `a.b` means: top-level key `a` is present and its
        // canonical JSON value contains the key `b` — the shape that reaches
        // the four stroke fields, which live inside the `stroke` value rather
        // than beside it. The two ports implement the identical rule.
        if let Some(map) = tc.get("bystander_fields_present").and_then(|v| v.as_object()) {
            let named: Vec<String> = str_list(tc, "subject_ids")
                .into_iter()
                .chain(str_list(tc, "consumed_ids"))
                .collect();
            for (id, keys) in map {
                assert!(
                    !named.contains(id),
                    "preservation vector '{name}' lists '{id}' under \
                     bystander_fields_present, but the vector NAMES it — a \
                     subject is not a bystander"
                );
                let attrs = before.attrs.get(id).unwrap_or_else(|| panic!(
                    "preservation vector '{name}' names bystander '{id}', which \
                     is absent from the loaded setup document"));
                let obj = attrs.as_object().expect("an element attribute object");
                for key in keys.as_array().expect("an array of field names") {
                    let key = key.as_str().expect("field names are strings");
                    match key.split_once('.') {
                        None => assert!(
                            obj.contains_key(key),
                            "preservation vector '{name}': bystander '{id}' was \
                             declared to carry '{key}', but the loaded setup does \
                             not — the fixture decayed to defaults and every \
                             invariant over that field is vacuous"),
                        Some((outer, inner)) => {
                            let v = obj.get(outer).unwrap_or_else(|| panic!(
                                "preservation vector '{name}': bystander '{id}' \
                                 has no '{outer}' at all, so '{key}' cannot be \
                                 carried"));
                            assert!(
                                crate::geometry::test_json::canonical_json_value(v)
                                    .contains(&format!("\"{inner}\":")),
                                "preservation vector '{name}': bystander '{id}' \
                                 was declared to carry '{key}', but its '{outer}' \
                                 is {v} — the fixture decayed to defaults");
                        }
                    }
                }
            }
        }

        // `must_change` (optional) turns `speaks_to` from a PERMISSION into a
        // CLAIM. `subject_fields_only` only forbids differences OUTSIDE
        // `speaks_to`, so listing a key there makes the gate blind to it: an
        // implementation that stopped writing the key entirely would still be
        // green. Naming it here asserts the edit really does rewrite it, which
        // is what lets a corpus vector separate a behaviour rather than merely
        // tolerate it — e.g. the blob 1-match vector, whose `fill_rule` claim
        // is the ring term (T1's third closure) made visible to the corpus.
        if let Some(keys) = tc.get("must_change").and_then(|v| v.as_array()) {
            for id in str_list(tc, "subject_ids") {
                let (Some(b), Some(a)) = (before.attrs.get(&id), after.attrs.get(&id))
                else {
                    panic!(
                        "preservation vector '{name}' declares must_change but \
                         subject '{id}' is missing from one of the snapshots"
                    );
                };
                for key in keys {
                    let key = key.as_str().expect("must_change entries are strings");
                    assert_ne!(
                        b.get(key), a.get(key),
                        "preservation vector '{name}' claims the edit rewrites \
                         {id}.{key}, but it is unchanged — the claim is stale, \
                         or the behaviour it watches has regressed"
                    );
                }
            }
        }
    }

    /// THE DOCUMENT-LEVEL INVARIANT GATE. Runs every
    /// `test_fixtures/preservation/*.json` vector through the production op
    /// dispatcher and asserts the six invariants over the whole document.
    /// Read the corpus file and return its vectors, refusing any shape that
    /// would let an EMPTIED corpus pass.
    ///
    /// Measured on 2026-07-28: with the file rewritten to `[]` this test
    /// printed `ok` in 0.00s, and so did its Swift twin and both script
    /// gates — the loop below has nothing to iterate and every assertion
    /// inside it is skipped rather than failed. The floor is declared by the
    /// corpus itself (`min_vectors`) so it lives in ONE place instead of as a
    /// magic number in four, and the bare-array form is REFUSED rather than
    /// tolerated, because a tolerant reader would accept `[]` again.
    fn preservation_vectors(json_str: &str) -> Vec<serde_json::Value> {
        let root: serde_json::Value = serde_json::from_str(json_str)
            .expect("preservation_invariants.json parses");
        let obj = root.as_object().expect(
            "the preservation corpus's top level must be an OBJECT carrying \
             'min_vectors' and 'vectors' — a bare array cannot declare its own \
             floor, which is how emptying it to `[]` turned all four gates green",
        );
        let min = obj
            .get("min_vectors")
            .and_then(|v| v.as_u64())
            .expect("the preservation corpus must declare 'min_vectors'")
            as usize;
        assert!(min >= 1, "min_vectors must be at least 1 — a floor of zero is not a floor");
        let vectors = obj
            .get("vectors")
            .and_then(|v| v.as_array())
            .expect("the preservation corpus must carry a 'vectors' array")
            .clone();
        assert!(
            vectors.len() >= min,
            "preservation corpus declares min_vectors={min} but carries {} — \
             vectors were removed without lowering the floor the corpus states \
             about itself",
            vectors.len()
        );
        vectors
    }

    #[cfg(feature = "web")]
    #[test]
    fn preservation_invariants() {
        let json_str = read_fixture("preservation/preservation_invariants.json");
        let tests = preservation_vectors(&json_str);
        let mut failures: Vec<String> = Vec::new();

        for tc in &tests {
            let name = tc["name"].as_str().expect("a name");

            // BEFORE: the setup document, loaded and serialized with no ops.
            let before_model = Model::new(setup_document(tc), None);
            let before_json = <DocumentOps as OpWorld>::to_test_json(&before_model);

            // AFTER. A vector drives its edit through ONE of two production
            // paths, chosen by its own shape: `events` replays pointer input
            // through the real tool (the gesture corpus's runner), `txns`
            // dispatches ops. The gesture arm is not a convenience — the blob
            // brush's commit arms are a YAML effect with NO `op_apply` verb, so
            // an op-only gate is structurally blind to them, which is the same
            // shape of blindness §4.1 records for per-copy-API batteries.
            let after_model = if tc.get("events").is_some() {
                run_gesture_model(tc)
            } else {
                run_operation_model(tc)
            };
            let after_json = <DocumentOps as OpWorld>::to_test_json(&after_model);

            let before = preservation_snapshot(&before_json);
            let after = preservation_snapshot(&after_json);
            assert_preservation_not_vacuous(
                name, tc, &before_json, &after_json, &before, &after);

            let pinned: Vec<(String, String)> = tc["expected_violations"]["rust"]
                .as_array()
                .expect("expected_violations.rust is an array")
                .iter()
                .map(|r| {
                    (
                        r["invariant"].as_str().expect("invariant").to_string(),
                        r["row"].as_str().expect("row").to_string(),
                    )
                })
                .collect();

            failures.extend(preservation_pin_report(
                name, &pinned, preservation_invariants_for(tc, &before, &after)));
        }

        assert!(
            failures.is_empty(),
            "preservation invariant gate: {} failure(s):\n  {}",
            failures.len(),
            failures.join("\n  ")
        );
    }

    /// Fold one vector's evaluated invariants against its PINS.
    ///
    /// Extracted so `preservation_pin_inversion` can drive it directly. The
    /// inversion arm below — a pinned violation that now HOLDS is a FAILURE —
    /// is the mechanism that stops a pin from rotting into a silent
    /// suppression, and it is exercised ZERO times by the shipped corpus,
    /// where every vector declares `expected_violations: []`. A mechanism no
    /// data exercises is one refactor away from being deleted by accident.
    fn preservation_pin_report(
        name: &str,
        pinned: &[(String, String)],
        results: Vec<InvResult>,
    ) -> Vec<String> {
        let mut failures = Vec::new();
        for (inv, result) in results {
            let pin = pinned.iter().find(|(p, _)| p == inv);
            match (pin, &result) {
                // Unpinned invariant that failed — the law is broken here.
                (None, Some(why)) => failures.push(format!("[{name}] {inv} VIOLATED: {why}")),
                // Pinned violation that no longer reproduces — the pin is
                // stale and must be deleted (this is what stops a pin from
                // rotting into a suppression).
                (Some((_, row)), None) => failures.push(format!(
                    "[{name}] {inv} is PINNED as a known violation ({row}) but now \
                     HOLDS — remove the pin from the vector"
                )),
                _ => {}
            }
        }
        failures
    }

    /// THE PIN INVERSION, as a truth table. Twin of Swift
    /// `preservationPinInversion`; the two assert the same four cells with the
    /// same strings, so the ports cannot drift on what a pin MEANS.
    #[test]
    fn preservation_pin_inversion() {
        let pin = vec![(
            "bystanders_unchanged".to_string(),
            "some/site.rs:1 — the row this pin cites".to_string(),
        )];
        let violated: Vec<InvResult> =
            vec![("bystanders_unchanged", Some("grp.mask: {...} -> <absent>".into()))];
        let holds: Vec<InvResult> = vec![("bystanders_unchanged", None)];

        // 1. UNPINNED + violated → reported as a violation.
        let out = preservation_pin_report("v", &[], violated.clone());
        assert_eq!(out.len(), 1, "unpinned violation must be reported: {out:?}");
        assert!(out[0].contains("bystanders_unchanged VIOLATED"), "{out:?}");

        // 2. PINNED + violated → silent; the pin is doing its job.
        assert!(
            preservation_pin_report("v", &pin, violated).is_empty(),
            "a pinned violation that still reproduces must be silent"
        );

        // 3. PINNED + holds → THE INVERSION. Repairing the site reds the gate
        //    until the pin is deleted.
        let out = preservation_pin_report("v", &pin, holds.clone());
        assert_eq!(out.len(), 1, "a repaired pinned site must red the gate: {out:?}");
        assert!(
            out[0].contains("is PINNED as a known violation")
                && out[0].contains("but now HOLDS")
                && out[0].contains("some/site.rs:1"),
            "the inversion must name the pin's own row: {out:?}"
        );

        // 4. UNPINNED + holds → silent, the ordinary green case.
        assert!(preservation_pin_report("v", &[], holds).is_empty());

        // 5. A pin on a DIFFERENT invariant does not suppress this one — the
        //    match is per-invariant, not per-vector.
        let other = vec![("id_survival".to_string(), "elsewhere".to_string())];
        let out = preservation_pin_report(
            "v", &other,
            vec![("bystanders_unchanged", Some("boom".into()))]);
        assert_eq!(out.len(), 1, "a pin must not suppress a sibling invariant: {out:?}");
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

    /// `state.boolean_remove_redundant_points` defaults to FALSE
    /// (`workspace/state.yaml`), so the collinear-collapse pass does NOT
    /// run on a default boolean. The setup is two rects overlapping in x
    /// with the same y-extent, so the union's top and bottom edges each
    /// carry two vertices the sweep inserted at the operands' vertical
    /// edges — vertices the collapse pass would delete. The golden pins
    /// them present, which is what makes this fixture DISCRIMINATE the
    /// default instead of being blind to it (Swift defaulted the flag to
    /// true, so the pass ran in exactly one port). The same golden pins
    /// BOOLEAN.md's paint rule for UNION: the result carries the
    /// frontmost operand's fill and opacity (blue, 0.5), not the
    /// backmost's (red, 0.8) and not a reset 1.0.
    #[test]
    fn operation_boolean_collapse_default() {
        run_operation_fixture("operations/boolean_collapse_default.json");
    }

    /// PASTE AND LAYER STRUCTURE (LAYER_STRUCTURE.md R2/R3, ratified
    /// 2026-07-28). The family that did not exist: §5 records that `op_apply`
    /// had no `paste` verb in either port, so NO fixture could reach ANY paste
    /// behaviour and both rulings would have landed unwatched.
    ///
    /// It pins R2 and R3 over the SAME input rather than describing the
    /// difference: `paste_one_name_match_still_flattens_into_active` and
    /// `paste_preserving_one_name_match_appends_and_creates` paste one fragment
    /// (one layer name matching the document, one not) under each command. The
    /// first must land BOTH children in the active layer — that is R2 deleting
    /// Swift's name-matching from the default path — and the second must append
    /// into the matching layer and CREATE the missing one.
    ///
    /// The paste `svg` is VALUE-IN-OP, so the checkpoint_equivalence gate
    /// replays every case from the op's own params.
    #[test]
    fn operation_paste_layers() {
        run_operation_fixture("operations/paste_layers.json");
    }

    /// SELECT ALL SELECTS TOP-LEVEL OBJECTS (transcripts/LAYER_STRUCTURE.md §16,
    /// D2, RULED 2026-07-28) — and SELECTION ORDER IS PART OF THE DOCUMENT (§10,
    /// D6, ruled the same day).
    ///
    /// Neither could be watched before this family. `op_apply` had no
    /// `select_all` verb in either port, so nothing shared reached Select All;
    /// and the canonical-JSON selection serializer sorted by path in BOTH ports,
    /// so no golden anywhere could see the ORDER a selection was built in. The
    /// sort is gone and these goldens pin emission order, which is why the
    /// `copy_of_a_two_element_selection_emits_a_deterministic_order` case can
    /// require a NON-document order ([0,3] then [0,1]) and mean it.
    ///
    /// `a_marquee_and_select_all_agree_on_the_same_top_level_objects` shares
    /// `select_all_top_level_expected.json` with the Select All case, which is
    /// §16.4 (RULED 2026-07-29) made structural: the two operations must land on
    /// the SAME selection for this document, so if either drifts the shared
    /// golden reds.
    ///
    /// This comment previously said the marquee's group branch "is right for the
    /// marquee, which is the caller it was written for, and wrong only for
    /// Select All". That was the pre-§16.4 reading and it is no longer true. The
    /// branch pushed the group AND every unlocked member, and `copy_selection`
    /// reads that shape as a copy of the group PLUS a copy of each member into
    /// the source group — marquee-then-duplicate left the SOURCE holding four
    /// children instead of two.
    #[test]
    fn operation_select_all_top_level() {
        run_operation_fixture("operations/select_all_top_level.json");
    }

    /// PASTE AND A LOCKED TARGET — transcripts/LAYER_STRUCTURE.md §15 (RULED by
    /// JYH 2026-07-28): **refuse when the ARTIST chose the target, divert when
    /// the FRAGMENT chose it.** Plain Paste targets the ACTIVE layer, so a
    /// locked one refuses; preserving Paste targets a layer the fragment named,
    /// so a locked one diverts to `"Sky" → "Sky 2"`. Hidden is NOT locked and is
    /// appended into normally.
    ///
    /// It is the family `paste_layers.json` said it could not be: that file's
    /// own `_doc` records "WHAT THIS FAMILY CANNOT REACH: appending into a
    /// LOCKED or HIDDEN matching layer … no `setup_svg` can produce a locked
    /// layer". `jas:locked` (§13.1) retired that sentence.
    ///
    /// EVERY GOLDEN HERE IS IMPLEMENTATION-INDEPENDENT, which is what let the
    /// family go red in both ports at once. A refusal points at its own family's
    /// SETUP golden by file identity; a divert points at a CONTROL case that
    /// pastes a fragment layer literally named `"Sky 2"`, which this ruling does
    /// not touch — so the divert is pinned as an EQUATION rather than as a
    /// snapshot of the code that implements it.
    #[test]
    fn operation_paste_locked_layers() {
        run_operation_fixture("operations/paste_locked_layers.json");
    }

    /// WHAT THE CLIPBOARD HOLDS DECIDES WHAT PASTE DOES — D4/D5, ratified
    /// 2026-07-28 (Swift is canon; Rust drops its internal-clipboard fallback).
    ///
    /// `paste_layers.json` carries the fragment MARKUP in `svg`, which
    /// presupposes the SVG branch was already chosen. This family carries the
    /// RAW CLIPBOARD PAYLOAD in `text` — before any branch is chosen — so it is
    /// the only thing that can watch the DISPATCH: text becomes a Text element,
    /// an empty or unreadable clipboard is a no-op, and an SVG payload still
    /// reaches the shared paste body.
    ///
    /// It is NOT a parallel path.
    /// `paste_clipboard_svg_payload_through_text_equals_the_svg_param` points at
    /// `paste_layers.json`'s OWN golden file, so a second copy of the paste body
    /// behind the `text` param could not stay agreeing with it.
    #[test]
    fn operation_paste_clipboard_text() {
        run_operation_fixture("operations/paste_clipboard_text.json");
    }

    /// REPEATED PASTES STACK WITH CUMULATIVE OFFSETS — `workspace/actions.yaml`
    /// §paste, a sentence the spec has carried since it was written and which
    /// NEITHER active port implemented: the second paste landed exactly on the
    /// first. Both ports were wrong together, so the written requirement
    /// governs (JYH, 2026-07-28: "follow the spec").
    ///
    /// The family pins the three run positions (36 / 60 / 84 in document space)
    /// and the four decisions the sentence leaves open — reset keyed to the
    /// PAYLOAD, `paste_in_place` outside the run, preserving-layers sharing the
    /// one run, and a paste that lands nothing not advancing it. Two of its
    /// vectors point at ANOTHER vector's golden by file identity rather than
    /// carrying a second copy.
    ///
    /// `paste_clipboard_text_payload_stacks_too` is the one that matters most:
    /// `text` is the raw clipboard payload, which is what production reads in
    /// both ports, so a run implemented on the corpus-only `svg` param alone
    /// would still leave the artist pasting on one spot.
    ///
    /// UNDO is NOT reachable from here (the runner applies `history` after every
    /// transaction) and is pinned by `op_apply::paste_stacking_tests` and its
    /// Swift twin instead.
    #[test]
    fn operation_paste_stacking() {
        run_operation_fixture("operations/paste_stacking.json");
    }

    /// LOCK IS INHERITED, NOT MATERIALIZED — transcripts/LAYER_STRUCTURE.md §13
    /// (RULED by JYH 2026-07-28). A locked layer locks everything inside it, at
    /// every depth, and those elements cannot be individually unlocked.
    ///
    /// Drives the two selection seams the ruling names: `select_element` (the
    /// path-addressed click, where the element's OWN `locked` was read one line
    /// above an INHERITED `effective_visibility`) and `select_rect` (the
    /// marquee). Both op verbs route through the production `Controller`
    /// mutators.
    ///
    /// This family could not have existed before `jas:locked` landed the same
    /// day (§13.1): every case is seeded from a `setup_svg`, and until then the
    /// SVG codec dropped `common.locked` in both ports, so NO shared fixture
    /// anywhere could start from a locked document.
    #[test]
    fn operation_lock_inheritance() {
        run_operation_fixture("operations/lock_inheritance.json");
    }

    /// MATERIALIZATION IS REPEALED — transcripts/LAYER_STRUCTURE.md §13.
    ///
    /// The shipped spec (`workspace/panels/layers.yaml`, `workspace/actions.yaml`
    /// §toggle_element_lock) said locking a container WRITES `locked = true`
    /// onto each direct child and restores saved states on unlock, while the
    /// Rust comments in `controller.rs` / `doc_primitives.rs` asserted the
    /// opposite. Nothing could see the contradiction because the lock button's
    /// document work lived only behind a Dioxus click handler — no op verb, no
    /// action, no gesture reached it.
    ///
    /// The `toggle_element_lock` verb this family added routes through the SAME
    /// pure `Document::toggling_element_lock` the panel calls, so it gates the panel's
    /// behaviour rather than duplicating it.
    #[test]
    fn operation_lock_toggle_no_materialization() {
        run_operation_fixture("operations/lock_toggle_no_materialization.json");
    }

    /// `Object > Lock` STOPPED MATERIALIZING — transcripts/LAYER_STRUCTURE.md
    /// §13. The sibling of the family above, and the half of the repeal that
    /// was left behind: §13 repaired the Layers-panel path
    /// (`Document::toggling_element_lock`) and `lock_selection` kept a SECOND,
    /// recursive implementation that stamped `locked = true` onto every
    /// descendant of a Group.
    ///
    /// Worse than a leftover once §13.1 landed `jas:locked`: the stamped flags
    /// survive save and reload, and under inheritance nothing in the UI can
    /// clear one of them — the artist opens the parent and the children stay
    /// locked.
    ///
    /// Two of the goldens are the PANEL family's own, by file identity, so the
    /// gate states the two paths are one behaviour rather than describing the
    /// answer twice.
    #[test]
    fn operation_lock_selection_no_materialization() {
        run_operation_fixture("operations/lock_selection_no_materialization.json");
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

    /// EDIT_SEMANTICS_FREEZE.md T4 (the BYSTANDER CLAUSE) as a cross-port byte
    /// gate: *an edit preserves, unchanged, every element it does not name —
    /// including the containers it rebuilds to reach its target.* The three
    /// structural mutators (replace / delete / insert-after) each reach a
    /// grandchild through a Layer and a Group that both carry an `id`, a `name`
    /// and — for the replace vector — a non-default `visibility`. Everything the
    /// shared test-JSON encoding can see about those two containers must survive
    /// the edit byte-identically. Rust conformed on the day this landed; the
    /// fixture exists because the Swift twin did not (its private `withChildren`
    /// rebuilt Layer/Group from four fields), and a per-port unit test cannot
    /// discharge the ratification condition on its own.
    #[test]
    fn operation_bystander_containers() {
        run_operation_fixture("operations/bystander_containers.json");
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

        // (4) LINEPROMOTE — a Line receiving a brush is PROMOTED to a Path that
        // carries the resolved slug. The canonical JSON already gates the type
        // flip + geometry; here we pin the brush field itself (which that JSON
        // omits) on both the live + replay paths.
        let tc = find("set_attr_on_selection_line_promotes_to_path");
        let model = run_operation_model(&tc);
        match model.document().get_element(&vec![0, 0]) {
            Some(Element::Path(p)) => {
                assert_eq!(p.stroke_brush, Some("charcoal".to_string()),
                    "the promoted Path carries the brush slug");
                assert_eq!(p.d, vec![
                    crate::geometry::element::PathCommand::MoveTo { x: 0.0, y: 0.0 },
                    crate::geometry::element::PathCommand::LineTo { x: 36.0, y: 18.0 },
                ], "the promoted geometry is MoveTo(x1,y1)+LineTo(x2,y2)");
                assert_eq!(p.common.id.as_deref(), Some("line-1"),
                    "identity (id) survives the promotion");
            }
            other => panic!("a brushed Line must become a Path, got {other:?}"),
        }
        let replay = replay_model(&tc, &model);
        assert!(matches!(replay.document().get_element(&vec![0, 0]), Some(Element::Path(_))),
            "journal replay reproduces the Line→Path promotion");
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

    use crate::workspace::test_json::{
        workspace_to_test_json, test_json_to_workspace,
        state_defaults_json, shortcut_structure_json,
    };
    use crate::workspace::workspace::WorkspaceLayout;

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

    #[test]
    fn workspace_default_layout() {
        let layout = WorkspaceLayout::default_layout();
        let json = workspace_to_test_json(&layout);
        assert_workspace_fixture("workspace_default", &json);
    }

    #[test]
    fn workspace_default_with_panes() {
        let mut layout = WorkspaceLayout::default_layout();
        layout.ensure_pane_layout(1200.0, 800.0);
        let json = workspace_to_test_json(&layout);
        assert_workspace_fixture("workspace_default_with_panes", &json);
    }

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
    struct LayoutOps;
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

    fn run_workspace_operation_test(tc: &serde_json::Value) -> String {
        let setup_name = tc["setup"].as_str().unwrap();
        let setup_json = read_fixture(&format!("expected/{}", setup_name));
        let mut layout = test_json_to_workspace(setup_json.trim());
        // Same unified runner the document world uses (Fork 5).
        run_ops_test::<LayoutOps>(&mut layout, tc["ops"].as_array().unwrap())
    }

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

    fn run_workspace_operation_fixture(fixture: &str) {
        let json_str = read_fixture(fixture);
        let tests: serde_json::Value = serde_json::from_str(&json_str)
            .unwrap_or_else(|e| panic!("Failed to parse {}: {}", fixture, e));
        for tc in tests.as_array().unwrap() {
            assert_workspace_operation_test(tc);
        }
    }

    /// Bootstrap: generate expected JSON for workspace operation tests.
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

    #[test]
    fn workspace_panel_ops() {
        run_workspace_operation_fixture("workspace_operations/panel_ops.json");
    }

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

    use crate::workspace::pane::{Pane, PaneConfig, EdgeSide};

    fn parse_edge_side(s: &str) -> EdgeSide {
        match s {
            "right" => EdgeSide::Right,
            "top" => EdgeSide::Top,
            "bottom" => EdgeSide::Bottom,
            _ => EdgeSide::Left,
        }
    }

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
    // Panel bind-VALUE (resolved snapshot) algorithm test vectors
    // ---------------------------------------------------------------

    #[test]
    fn algorithm_bind_values_vectors() {
        use crate::interpreter::bind_values::bind_values;

        let json_str = read_fixture("algorithms/panel_bind_values.json");
        let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();

        let bundle_str =
            std::fs::read_to_string(format!("{}/../workspace/workspace.json", FIXTURES)).unwrap();
        let bundle: serde_json::Value = serde_json::from_str(&bundle_str).unwrap();
        let panels = &bundle["panels"];

        for tc in tests.as_array().unwrap() {
            let name = tc["name"].as_str().unwrap();
            let func = tc["function"].as_str().unwrap();
            assert_eq!(func, "bind_values", "Unknown function: {}", func);
            let panel_id = tc["args"]["panel"].as_str().unwrap();
            // ctx is a JSON object data scope (state / panel / data namespaces);
            // it passes straight to the expr evaluator, as in the two sibling
            // panel passes. Default to empty (everything resolves to null).
            let empty = serde_json::json!({});
            let ctx = tc["args"].get("ctx").unwrap_or(&empty);
            let expected = &tc["expected"];

            let actual = bind_values(&panels[panel_id], ctx);
            assert_eq!(&actual, expected, "Panel bind values '{}' mismatch", name);
        }
    }

    /// The census 5.8 claim, in this port: two data scopes differing only in
    /// `panel.hex` — "664040" vs "664141", the colour divergence's byte pattern
    /// — are INDISTINGUISHABLE to `widget_tree` (key names only) and to
    /// `layout_panel` (scalar count times a constant), and differ in exactly one
    /// `bind_values` row. That difference is the reason this family exists, so
    /// it is asserted here rather than only in the shared corpus.
    #[test]
    fn bind_values_separates_equal_length_hex_where_the_older_gates_cannot() {
        use crate::interpreter::bind_values::bind_values;
        use crate::interpreter::panel_layout::layout_panel;
        use crate::interpreter::widget_tree::widget_tree;

        let bundle_str =
            std::fs::read_to_string(format!("{}/../workspace/workspace.json", FIXTURES)).unwrap();
        let bundle: serde_json::Value = serde_json::from_str(&bundle_str).unwrap();
        let panel = &bundle["panels"]["color_panel_content"];

        let ctx_of = |hex: &str| {
            serde_json::json!({
                "state": {"fill_color": "#664040", "fill_on_top": true},
                "panel": {"mode": "hsb", "hex": hex},
            })
        };
        let (a, b) = (ctx_of("664040"), ctx_of("664141"));

        assert_eq!(widget_tree(panel, &a), widget_tree(panel, &b),
            "widget_tree is expected to be blind to bind VALUES");
        assert_eq!(layout_panel(panel, 228, 600, &a), layout_panel(panel, 228, 600, &b),
            "layout_panel is expected to be blind to equal-length text");

        let rows_a = bind_values(panel, &a);
        let rows_b = bind_values(panel, &b);
        let ra = rows_a.as_array().unwrap();
        let rb = rows_b.as_array().unwrap();
        assert_eq!(ra.len(), rb.len());
        let diff: Vec<_> = ra.iter().zip(rb.iter()).filter(|(x, y)| x != y).collect();
        assert_eq!(diff.len(), 1, "expected exactly one differing row, got {:?}", diff);
        let (x, y) = diff[0];
        assert_eq!(x["id"], "cp_hex");
        assert_eq!(x["key"], "bind.value");
        assert_eq!(x["value"], "664040");
        assert_eq!(y["value"], "664141");
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

    /// The PANEL-menu arm of the same chrome seam.
    ///
    /// `menu_state.json` pins the MENUBAR; nothing pinned a panel hamburger
    /// menu's dynamic state, and the gap was not academic. Until this landed
    /// this port answered every panel-menu `checked_when` with a hard-coded
    /// `false` (fourteen per-panel `is_checked` hooks, one of them a
    /// `return false` whose comment claimed the generic evaluator resolved
    /// them) while JasSwift answered five of the Brushes panel's with a
    /// hand-coded native rule — the same predicate, two answers.
    ///
    /// The subject is the SAME `menu_state` walk, applied to a panel's `menu:`
    /// array wrapped as one menu, so paths read `[0, i]`.
    #[test]
    fn algorithm_panel_menu_state_vectors() {
        use crate::interpreter::menu_state::menu_state;

        let json_str = read_fixture("algorithms/panel_menu_state.json");
        let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();

        let bundle_str =
            std::fs::read_to_string(format!("{}/../workspace/workspace.json", FIXTURES)).unwrap();
        let bundle: serde_json::Value = serde_json::from_str(&bundle_str).unwrap();

        let cases = tests.as_array().unwrap();
        assert!(cases.len() >= 6, "corpus shrank: {} cases", cases.len());
        let mut checked_rows = 0usize;
        for tc in cases {
            let name = tc["name"].as_str().unwrap();
            let func = tc["function"].as_str().unwrap();
            assert_eq!(func, "panel_menu_state", "Unknown function: {}", func);
            let pid = tc["args"]["panel"].as_str().unwrap();
            let menu = bundle["panels"][pid]["menu"].clone();
            assert!(menu.is_array(), "panel {} has no menu in the bundle", pid);
            let menubar = serde_json::json!([{ "items": menu }]);
            let ctx = &tc["args"]["ctx"];

            let actual = menu_state(&menubar, ctx);
            assert_eq!(&actual, &tc["expected"], "Panel menu state '{}' mismatch", name);
            checked_rows += tc["expected"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|r| r["checked"].is_boolean())
                .count();
        }
        // Anti-vacuity: a runner over rows that carry no predicate passes
        // without evaluating anything.
        assert!(checked_rows >= 29, "only {checked_rows} checked rows evaluated");
    }

    /// The panel-state WRITE arm of the same chrome seam.
    ///
    /// `panel_menu_state.json` seeds a panel scope directly and pins how the
    /// check marks are DERIVED from it. It says nothing about how the scope
    /// comes to hold the user's choices, and that is where the two active ports
    /// diverged next: this port stored no Brushes panel state at all, so every
    /// Brushes check mark evaluated the declared default forever while
    /// JasSwift's shared panel store moved with the user.
    ///
    /// The subject is the round trip — declared defaults, the generic
    /// `set_panel_state` effect, the scope read back, the panel's own menu
    /// evaluated against it — driven through THIS port's storage
    /// (`apply_set_panel_state_with_ctx` writing, `panel_menu_ctx` reading). A
    /// port that stores nothing returns the defaults and reds on the first case.
    #[cfg(feature = "web")]
    #[test]
    fn algorithm_panel_state_write_vectors() {
        use crate::interpreter::menu_state::menu_state;
        use crate::workspace::app_state::AppState;

        let json_str = read_fixture("algorithms/panel_state_writes.json");
        let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();

        let bundle_str =
            std::fs::read_to_string(format!("{}/../workspace/workspace.json", FIXTURES)).unwrap();
        let bundle: serde_json::Value = serde_json::from_str(&bundle_str).unwrap();

        let cases = tests.as_array().unwrap();
        assert!(cases.len() >= 8, "corpus shrank: {} cases", cases.len());
        let mut checked_rows = 0usize;
        let mut panels_seen: std::collections::HashSet<&str> = std::collections::HashSet::new();
        for tc in cases {
            let name = tc["name"].as_str().unwrap();
            let func = tc["function"].as_str().unwrap();
            assert_eq!(func, "panel_state_writes", "Unknown function: {}", func);
            let pid = tc["args"]["panel"].as_str().unwrap();
            panels_seen.insert(pid);
            let writes = tc["args"]["writes"].as_array().unwrap();
            assert!(!writes.is_empty(), "case '{}' performs no write", name);

            // This port's storage, driven exactly as an action's effect drives
            // it: a fresh AppState seeded only by the bundle's declared
            // defaults, then one generic set_panel_state per write.
            let mut st = AppState::new();
            for w in writes {
                let mut sps = serde_json::Map::new();
                sps.insert("panel".to_string(), serde_json::Value::String(pid.to_string()));
                sps.insert("key".to_string(), w["key"].clone());
                sps.insert("value".to_string(), w["value"].clone());
                crate::interpreter::renderer::apply_set_panel_state_with_ctx(&sps, &mut st, None);
            }
            // The scope this port would evaluate the panel's menu against.
            let scope = crate::panels::panel_menu::panel_menu_ctx(pid, &st)["panel"].clone();
            assert_eq!(
                &scope, &tc["expected"]["panel_state"],
                "Panel scope after the writes of '{}' mismatch", name
            );

            let menu = bundle["panels"][pid]["menu"].clone();
            assert!(menu.is_array(), "panel {} has no menu in the bundle", pid);
            let menubar = serde_json::json!([{ "items": menu }]);
            let ctx = serde_json::json!({
                "panel": scope,
                "preferences": tc["args"]["preferences"],
            });
            let actual = menu_state(&menubar, &ctx);
            assert_eq!(&actual, &tc["expected"]["menu"], "Panel menu after '{}' mismatch", name);
            checked_rows += tc["expected"]["menu"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|r| r["checked"].is_boolean())
                .count();
        }
        // Anti-vacuity: rows with no predicate pass without evaluating anything,
        // and a corpus naming one panel is satisfied by a Brushes-shaped hook.
        assert!(checked_rows >= 70, "only {checked_rows} checked rows evaluated");
        assert!(panels_seen.len() >= 2, "only one panel covered");
    }

    /// The derivation `layout -> panels.<id>` that `menu_state` takes as
    /// GIVEN. menu_state.json feeds the panels map in as input, so nothing
    /// watched how that map is computed from a dock layout — the seam where
    /// a panel can be a group MEMBER while being off screen (a background
    /// tab, a collapsed group/dock, a hidden dock pane). These vectors pin
    /// the predicate itself: on screen iff it is its group's active tab and
    /// every container above it is expanded and shown.
    #[test]
    fn algorithm_panel_on_screen_vectors() {
        use crate::workspace::layout_apply::panel_kind_str;
        use crate::workspace::workspace::{PanelKind, WorkspaceLayout};
        #[allow(unused_imports)]
        use crate::workspace::test_json;

        let json_str = read_fixture("algorithms/panel_on_screen.json");
        let tests: serde_json::Value = serde_json::from_str(&json_str).unwrap();

        const ALL16: &[PanelKind] = &[
            PanelKind::Layers,
            PanelKind::Color,
            PanelKind::Swatches,
            PanelKind::Brushes,
            PanelKind::Gradient,
            PanelKind::Stroke,
            PanelKind::Properties,
            PanelKind::Character,
            PanelKind::Paragraph,
            PanelKind::Artboards,
            PanelKind::Align,
            PanelKind::Boolean,
            PanelKind::Opacity,
            PanelKind::MagicWand,
            PanelKind::Symbols,
            PanelKind::Concepts,
        ];

        let cases = tests.as_array().unwrap();
        assert!(!cases.is_empty(), "panel_on_screen corpus is empty");
        for tc in cases {
            let name = tc["name"].as_str().unwrap();
            let func = tc["function"].as_str().unwrap();
            assert_eq!(func, "panel_on_screen", "Unknown function: {}", func);
            let layout: WorkspaceLayout = crate::workspace::test_json::test_json_to_workspace(
                &tc["args"]["layout"].to_string(),
            );
            let expected = tc["expected"].as_object().unwrap();
            assert_eq!(expected.len(), ALL16.len(), "'{}' must name every kind", name);
            for &kind in ALL16 {
                let id = panel_kind_str(kind);
                let want = expected[id].as_bool().unwrap();
                assert_eq!(
                    layout.panel_on_screen(kind),
                    want,
                    "'{}': panel_on_screen({}) should be {}",
                    name,
                    id,
                    want
                );
            }
        }
    }

    /// FLOATSPELL: the one spelling of a full-precision f64. Expected values
    /// come from the RULE (computed in Python), not from either port, so this
    /// binds Rust as tightly as it binds Swift.
    #[test]
    fn algorithm_float_format_vectors() {
        let json_str = read_fixture("algorithms/float_format.json");
        let doc: serde_json::Value = serde_json::from_str(&json_str).unwrap();
        let cases = doc["cases"].as_array().unwrap();
        assert!(!cases.is_empty(), "float_format corpus is empty");
        let mut exponent_cases = 0;
        for c in cases {
            let v = c["value"].as_f64().unwrap();
            let want = c["expected"].as_str().unwrap();
            let got = crate::geometry::svg::fmt_full(v);
            assert_eq!(got, want, "fmt_full({v:?})");
            // Round-trip: the whole point of "shortest that round-trips".
            assert_eq!(
                got.parse::<f64>().unwrap().to_bits(),
                v.to_bits(),
                "fmt_full({v:?}) = {got} does not read back as the same f64"
            );
            if format!("{v:?}").contains('e') {
                exponent_cases += 1;
            }
            assert!(
                !got.contains('e') && !got.contains('E'),
                "fixed notation only, got {got}"
            );
        }
        // ANTI-VACUITY: the corpus must actually contain the cases where the
        // two ports diverge, or it proves nothing about the hazard it exists
        // for.
        assert!(
            exponent_cases >= 6,
            "corpus must carry exponent-boundary values; found {exponent_cases}"
        );
    }

    // ---------------------------------------------------------------
    // Toolbar and menu structure tests
    // ---------------------------------------------------------------

    // ---------------------------------------------------------------
    // STROKEWIDTH: the field-scoped Stroke-panel apply law
    // ---------------------------------------------------------------
    //
    // Runs test_fixtures/stroke_apply/panel_edit.json — the shared corpus
    // that pins this law across the three LIVE implementations (the
    // workspace_interpreter reference, this port, and Swift). The
    // reference states the field -> attribute-group table
    // (workspace_interpreter/stroke_law.py); `StrokeEditGroup` mirrors it.
    // A vector's `expected` is a DELTA over its effective base: the keys
    // it names are what the edit changed, and every key it omits must come
    // back unchanged.

    /// A fixture colour: 6-char hex, or the `{space, components, a}` object
    /// form. The object form exists because a stroke colour is NOT hex —
    /// hex flattens the space, drops the alpha and quantises to 8 bits, and
    /// a panel edit must hand the colour back bit-for-bit.
    fn color_from_attrs(spec: &serde_json::Value)
        -> crate::geometry::element::Color
    {
        use crate::geometry::element::Color;
        if let Some(hex) = spec.as_str() {
            return Color::from_hex(hex).expect("fixture colour must parse");
        }
        let f = |k: &str| spec.get(k).and_then(|v| v.as_f64())
            .unwrap_or_else(|| panic!("fixture colour missing '{}'", k));
        let a = spec.get("a").and_then(|v| v.as_f64()).unwrap_or(1.0);
        match spec.get("space").and_then(|v| v.as_str()) {
            Some("cmyk") => Color::Cmyk {
                c: f("c"), m: f("m"), y: f("y"), k: f("k"), a },
            Some("hsb") => Color::Hsb { h: f("h"), s: f("s"), b: f("b"), a },
            Some("rgb") => Color::Rgb { r: f("r"), g: f("g"), b: f("b"), a },
            other => panic!("unknown fixture colour space {:?}", other),
        }
    }

    /// The Stroke a fixture attribute map describes, taking anything it
    /// omits from `base`.
    fn stroke_from_attrs(base: &crate::geometry::element::Stroke,
                         attrs: &serde_json::Value)
        -> crate::geometry::element::Stroke
    {
        use crate::geometry::element::{
            Arrowhead, ArrowAlign, LineCap, LineJoin, StrokeAlign,
        };
        let mut s = *base;
        if let Some(v) = attrs.get("color") {
            if !v.is_null() { s.color = color_from_attrs(v); }
        }
        if let Some(v) = attrs.get("width").and_then(|v| v.as_f64()) { s.width = v; }
        if let Some(v) = attrs.get("linecap").and_then(|v| v.as_str()) {
            s.linecap = match v {
                "round" => LineCap::Round,
                "square" => LineCap::Square,
                _ => LineCap::Butt,
            };
        }
        if let Some(v) = attrs.get("linejoin").and_then(|v| v.as_str()) {
            s.linejoin = match v {
                "round" => LineJoin::Round,
                "bevel" => LineJoin::Bevel,
                _ => LineJoin::Miter,
            };
        }
        if let Some(v) = attrs.get("miter_limit").and_then(|v| v.as_f64()) {
            s.miter_limit = v;
        }
        if let Some(v) = attrs.get("align").and_then(|v| v.as_str()) {
            s.align = match v {
                "inside" => StrokeAlign::Inside,
                "outside" => StrokeAlign::Outside,
                _ => StrokeAlign::Center,
            };
        }
        if let Some(v) = attrs.get("dash").and_then(|v| v.as_array()) {
            s.dash_pattern = [0.0; 6];
            s.dash_len = v.len() as u8;
            for (i, d) in v.iter().enumerate() {
                s.dash_pattern[i] = d.as_f64().unwrap();
            }
        }
        if let Some(v) = attrs.get("dash_align_anchors").and_then(|v| v.as_bool()) {
            s.dash_align_anchors = v;
        }
        if let Some(v) = attrs.get("start_arrow").and_then(|v| v.as_str()) {
            s.start_arrow = Arrowhead::from_str(v);
        }
        if let Some(v) = attrs.get("end_arrow").and_then(|v| v.as_str()) {
            s.end_arrow = Arrowhead::from_str(v);
        }
        if let Some(v) = attrs.get("start_arrow_scale").and_then(|v| v.as_f64()) {
            s.start_arrow_scale = v;
        }
        if let Some(v) = attrs.get("end_arrow_scale").and_then(|v| v.as_f64()) {
            s.end_arrow_scale = v;
        }
        if let Some(v) = attrs.get("arrow_align").and_then(|v| v.as_str()) {
            s.arrow_align = if v == "center_at_end" {
                ArrowAlign::CenterAtEnd
            } else {
                ArrowAlign::TipAtEnd
            };
        }
        if let Some(v) = attrs.get("opacity").and_then(|v| v.as_f64()) {
            s.opacity = v;
        }
        s
    }

    #[cfg(feature = "web")]
    /// The StrokePanelState a fixture panel map describes (its defaults
    /// block plus the vector's overrides).
    fn stroke_panel_from_attrs(attrs: &serde_json::Value)
        -> crate::workspace::app_state::StrokePanelState
    {
        let mut sp = crate::workspace::app_state::StrokePanelState::default();
        let s = |k: &str| attrs.get(k).and_then(|v| v.as_str()).map(|v| v.to_string());
        let f = |k: &str| attrs.get(k).and_then(|v| v.as_f64());
        let b = |k: &str| attrs.get(k).and_then(|v| v.as_bool());
        if let Some(v) = s("cap") { sp.cap = v; }
        if let Some(v) = s("join") { sp.join = v; }
        if let Some(v) = f("miter_limit") { sp.miter_limit = v; }
        if let Some(v) = s("align_stroke") { sp.align = v; }
        if let Some(v) = b("dashed") { sp.dashed = v; }
        if let Some(v) = f("dash_1") { sp.dash_1 = v; }
        if let Some(v) = f("gap_1") { sp.gap_1 = v; }
        sp.dash_2 = f("dash_2");
        sp.gap_2 = f("gap_2");
        sp.dash_3 = f("dash_3");
        sp.gap_3 = f("gap_3");
        if let Some(v) = b("dash_align_anchors") { sp.dash_align_anchors = v; }
        if let Some(v) = s("start_arrowhead") { sp.start_arrowhead = v; }
        if let Some(v) = s("end_arrowhead") { sp.end_arrowhead = v; }
        if let Some(v) = f("start_arrowhead_scale") { sp.start_arrowhead_scale = v; }
        if let Some(v) = f("end_arrowhead_scale") { sp.end_arrowhead_scale = v; }
        if let Some(v) = s("arrow_align") { sp.arrow_align = v; }
        if let Some(v) = s("profile") { sp.profile = v; }
        if let Some(v) = b("profile_flipped") { sp.profile_flipped = v; }
        if let Some(v) = f("weight") { sp.weight = v; }
        sp
    }

    /// Merge a JSON object over another, shallow (the vector's overrides
    /// over the corpus defaults / its base).
    fn merged(base: &serde_json::Value, over: &serde_json::Value) -> serde_json::Value {
        let mut out = base.as_object().cloned().unwrap_or_default();
        if let Some(o) = over.as_object() {
            for (k, v) in o { out.insert(k.clone(), v.clone()); }
        }
        serde_json::Value::Object(out)
    }

    #[cfg(feature = "web")]
    #[test]
    fn stroke_apply_panel_edit_corpus() {
        use crate::geometry::element::{Color, Stroke};
        use crate::workspace::app_state::{
            recolor_stroke, stroke_with_group, StrokeEditGroup,
        };
        let raw = read_fixture("stroke_apply/panel_edit.json");
        let corpus: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let plain = Stroke::new(Color::from_hex("#000000").unwrap(), 1.0);
        let mut ran = 0usize;
        for vec in corpus["vectors"].as_array().unwrap() {
            let name = vec["name"].as_str().unwrap();
            // `base`: a literal attribute map, the NAME of a shared map, or
            // null (an element with no stroke, which takes `fallback`).
            let base_attrs = match &vec["base"] {
                serde_json::Value::String(n) => corpus[n.as_str()].clone(),
                serde_json::Value::Null => vec["fallback"].clone(),
                other => other.clone(),
            };
            let has_base = !vec["base"].is_null();
            let base = if base_attrs.is_null() {
                None
            } else {
                Some(stroke_from_attrs(&plain, &base_attrs))
            };
            let op = vec["op"].as_str().unwrap();
            if op == "color_pick" {
                let color = Color::from_hex(vec["color"].as_str().unwrap()).unwrap();
                let got = recolor_stroke(if has_base { base } else { None },
                                         color);
                let want = stroke_from_attrs(
                    &base.unwrap_or(plain),
                    &merged(&base_attrs, &vec["expected"]),
                );
                assert_eq!(got, want, "stroke_apply color_pick '{}'", name);
                ran += 1;
                continue;
            }
            assert_eq!(op, "panel_edit", "unknown op in vector '{}'", name);
            let edited = vec["edited"].as_str().unwrap();
            // The key goes to production UNTOUCHED: normalizing the flat
            // GLOBAL form (`stroke_cap`, `stroke_width`) is `from_field`'s
            // job, and the `*_global_key` vectors exist to pin exactly
            // that. This arm used to strip the prefix itself, which made
            // those three vectors pass vacuously here.
            let group = StrokeEditGroup::from_field(edited);
            if vec["expected"].is_null() {
                assert!(group.is_none(),
                        "stroke_apply '{}': '{}' must own no group", name, edited);
                ran += 1;
                continue;
            }
            let group = group.unwrap_or_else(
                || panic!("stroke_apply '{}': '{}' must own a group", name, edited));
            // A vector's `scope` (panel / global) collapses in this port:
            // the flat global `stroke_cap` and the panel field `cap` are ONE
            // slot on `StrokePanelState` — `renderer::set_app_state_field`
            // writes the same field a widget write-back does for every key
            // this corpus uses, weight included (`stroke_width` ->
            // `stroke_panel.weight`, pinned by
            // `global_stroke_width_write_lands_on_the_panel_weight`).
            // (Known exception OUTSIDE the corpus: it has no
            // `stroke_dash_align_anchors` arm — banked in STROKE.md's
            // follow-ups with the global-apply question.) Swift
            // and the reference keep two dicts, so there the marker selects
            // which one gets seeded.
            let panel = stroke_panel_from_attrs(
                &merged(&corpus["panel_defaults"], &vec["panel"]));
            let committed = vec["committed_width"].as_f64().unwrap();
            let got = stroke_with_group(base.unwrap(), &panel, group, committed);
            let want = stroke_from_attrs(
                &base.unwrap(), &merged(&base_attrs, &vec["expected"]));
            assert_eq!(got, want, "stroke_apply panel_edit '{}'", name);
            ran += 1;
        }
        assert!(ran >= 25, "stroke_apply corpus ran only {} vectors", ran);
    }

    // ── CHARPANEL: the field-scoped Character-panel apply law ──────
    //
    // Runs test_fixtures/character_apply/panel_edit.json — the shared corpus
    // that pins this law across the three LIVE implementations (the
    // workspace_interpreter reference, this port, and Swift JasSwift). The
    // reference states the field -> attribute-group table
    // (workspace_interpreter/character_law.py); `CharacterEditGroup` mirrors
    // it.
    //
    // A vector's `expected` is a DELTA over its base: the keys it names are
    // what the edit changed, and every key it omits must come back
    // unchanged. That is the whole point of the law, so the corpus states it
    // directly rather than re-listing whole attribute sets.

    #[cfg(feature = "web")]
    /// A fixture attribute map as `CharacterAttrs`. Every key is present in
    /// the merged map (the corpus's `element_defaults` names all sixteen),
    /// so no port's element-constructor defaults leak into the corpus.
    fn character_attrs_from_json(
        attrs: &serde_json::Value,
    ) -> crate::workspace::app_state::CharacterAttrs {
        let s = |k: &str| attrs[k].as_str().unwrap_or("").to_string();
        crate::workspace::app_state::CharacterAttrs {
            font_family: s("font_family"),
            font_size: attrs["font_size"].as_f64().unwrap_or(12.0),
            font_weight: s("font_weight"),
            font_style: s("font_style"),
            text_decoration: s("text_decoration"),
            text_transform: s("text_transform"),
            font_variant: s("font_variant"),
            baseline_shift: s("baseline_shift"),
            line_height: s("line_height"),
            letter_spacing: s("letter_spacing"),
            xml_lang: s("xml_lang"),
            aa_mode: s("aa_mode"),
            rotate: s("rotate"),
            horizontal_scale: s("horizontal_scale"),
            vertical_scale: s("vertical_scale"),
            kerning: s("kerning"),
        }
    }

    #[cfg(feature = "web")]
    /// A fixture panel map as `CharacterPanelState`. Unlike the Stroke
    /// corpus there is no panel-vs-global scope question: every Character
    /// control binds `panel.<field>` only.
    fn character_panel_from_json(
        panel: &serde_json::Value,
    ) -> crate::workspace::app_state::CharacterPanelState {
        let mut cp = crate::workspace::app_state::CharacterPanelState::default();
        let s = |k: &str| panel[k].as_str().map(|v| v.to_string());
        if let Some(v) = s("font_family") { cp.font_family = v; }
        if let Some(v) = s("style_name") { cp.style_name = v; }
        if let Some(v) = panel["font_size"].as_f64() { cp.font_size = v; }
        if let Some(v) = panel["leading"].as_f64() { cp.leading = v; }
        if let Some(v) = s("kerning") { cp.kerning = v; }
        if let Some(v) = panel["tracking"].as_f64() { cp.tracking = v; }
        if let Some(v) = panel["vertical_scale"].as_f64() { cp.vertical_scale = v; }
        if let Some(v) = panel["horizontal_scale"].as_f64() { cp.horizontal_scale = v; }
        if let Some(v) = panel["baseline_shift"].as_f64() { cp.baseline_shift = v; }
        if let Some(v) = panel["character_rotation"].as_f64() { cp.character_rotation = v; }
        if let Some(v) = panel["all_caps"].as_bool() { cp.all_caps = v; }
        if let Some(v) = panel["small_caps"].as_bool() { cp.small_caps = v; }
        if let Some(v) = panel["superscript"].as_bool() { cp.superscript = v; }
        if let Some(v) = panel["subscript"].as_bool() { cp.subscript = v; }
        if let Some(v) = panel["underline"].as_bool() { cp.underline = v; }
        if let Some(v) = panel["strikethrough"].as_bool() { cp.strikethrough = v; }
        if let Some(v) = s("language") { cp.language = v; }
        if let Some(v) = s("anti_aliasing") { cp.anti_aliasing = v; }
        cp
    }

    #[cfg(feature = "web")]
    #[test]
    fn character_apply_panel_edit_corpus() {
        use crate::workspace::app_state::{character_with_group, CharacterEditGroup};
        let raw = read_fixture("character_apply/panel_edit.json");
        let corpus: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let mut ran = 0usize;
        for vec in corpus["vectors"].as_array().unwrap() {
            let name = vec["name"].as_str().unwrap();
            assert_eq!(vec["op"].as_str().unwrap(), "panel_edit",
                       "character_apply '{}': unknown op", name);
            // `base` is a literal attribute delta or the NAME of a shared
            // one; either way it is a delta over `element_defaults`.
            let base_delta = match &vec["base"] {
                serde_json::Value::String(n) => corpus[n.as_str()].clone(),
                other => other.clone(),
            };
            let base_attrs = merged(&corpus["element_defaults"], &base_delta);
            let base = character_attrs_from_json(&base_attrs);
            let edited = vec["edited"].as_str().unwrap();
            let group = CharacterEditGroup::from_field(edited);
            if vec["expected"].is_null() {
                assert!(group.is_none(),
                        "character_apply '{}': '{}' must own no group",
                        name, edited);
                ran += 1;
                continue;
            }
            let group = group.unwrap_or_else(|| panic!(
                "character_apply '{}': '{}' must own a group", name, edited));
            let cp = character_panel_from_json(
                &merged(&corpus["panel_defaults"], &vec["panel"]));
            let got = character_with_group(base, &cp, group);
            let want = character_attrs_from_json(
                &merged(&base_attrs, &vec["expected"]));
            assert_eq!(got, want, "character_apply panel_edit '{}'", name);
            ran += 1;
        }
        assert!(ran >= 40, "character_apply corpus ran only {} vectors", ran);
    }

    // ── the panel defaults are the WORKSPACE's, machine-checked ─────
    //
    // The other two arms already gate this: the reference compares
    // CHARACTER_PANEL_FIELDS against workspace.json
    // (test_character_apply.py, TestTheFallbacksAreTheWorkspaceDefaults) and
    // Swift compares characterPanelDefaults the same way
    // (CharacterApplyCorpusTests, fallbacksMatchTheWorkspace). This port had
    // no equivalent check on `CharacterPanelState::default()` — and it had
    // already drifted: the struct's kerning default was `String::new()` where
    // the workspace declares "Auto". That was harmless in the APPLY only
    // because `kerning_attr` maps "" and "Auto" to the same empty attribute,
    // i.e. precisely the silent drift the other arms' gates exist to catch —
    // and it was visible in the DISPLAY, where a no-selection panel showed a
    // blank Kerning combo against the other ports' "Auto".
    //
    // `leading` is the one field where this arm's expectation is the INVERSE
    // of the other two. There the fallback table omits it deliberately —
    // absence is the sentinel for "no committed leading, take the element's
    // Auto value". This port's `leading` is a plain `f64` that cannot be
    // absent, so it must carry the declared 14.4 like any other field, and
    // the Auto value gets materialised instead (see
    // `character_panel_post_write` / the nullable-clear path).

    #[cfg(feature = "web")]
    /// `CharacterPanelState::default()` as a field-name -> value map, so the
    /// struct can be compared against the bundle key by key.
    ///
    /// Spelled out field by field on purpose: a field added to the struct
    /// without a line here fails the key-set assertion below, which is half
    /// of what the gate is for.
    fn character_panel_default_map()
        -> std::collections::BTreeMap<&'static str, serde_json::Value>
    {
        use serde_json::json;
        let d = crate::workspace::app_state::CharacterPanelState::default();
        let mut m = std::collections::BTreeMap::new();
        m.insert("font_family", json!(d.font_family));
        m.insert("style_name", json!(d.style_name));
        m.insert("font_size", json!(d.font_size));
        m.insert("leading", json!(d.leading));
        m.insert("kerning", json!(d.kerning));
        m.insert("tracking", json!(d.tracking));
        m.insert("vertical_scale", json!(d.vertical_scale));
        m.insert("horizontal_scale", json!(d.horizontal_scale));
        m.insert("baseline_shift", json!(d.baseline_shift));
        m.insert("character_rotation", json!(d.character_rotation));
        m.insert("all_caps", json!(d.all_caps));
        m.insert("small_caps", json!(d.small_caps));
        m.insert("superscript", json!(d.superscript));
        m.insert("subscript", json!(d.subscript));
        m.insert("underline", json!(d.underline));
        m.insert("strikethrough", json!(d.strikethrough));
        m.insert("language", json!(d.language));
        m.insert("anti_aliasing", json!(d.anti_aliasing));
        m.insert("snap_to_glyph_visible", json!(d.snap_to_glyph_visible));
        m.insert("snap_baseline", json!(d.snap_baseline));
        m.insert("snap_x_height", json!(d.snap_x_height));
        m.insert("snap_glyph_bounds", json!(d.snap_glyph_bounds));
        m.insert("snap_proximity_guides", json!(d.snap_proximity_guides));
        m.insert("snap_angular_guides", json!(d.snap_angular_guides));
        m.insert("snap_anchor_point", json!(d.snap_anchor_point));
        m
    }

    /// Two declared defaults are the same value even when the bundle boxed an
    /// integral default as an integer (`12`) where the struct holds `12.0`.
    /// Mirrors Swift's `sameWorkspaceValue`.
    fn same_workspace_value(a: &serde_json::Value, b: &serde_json::Value) -> bool {
        match (a.as_f64(), b.as_f64()) {
            (Some(x), Some(y)) if !a.is_boolean() && !b.is_boolean() => x == y,
            _ => a == b,
        }
    }

    #[cfg(feature = "web")]
    #[test]
    fn character_panel_defaults_match_the_workspace() {
        let bundle = std::fs::read_to_string("../workspace/workspace.json")
            .expect("read workspace.json bundle");
        let ws: serde_json::Value = serde_json::from_str(&bundle)
            .expect("workspace.json must parse");
        let state = ws["panels"]["character_panel_content"]["state"]
            .as_object()
            .expect("character_panel_content must declare panel state");
        let declared: std::collections::BTreeMap<String, serde_json::Value> =
            state.iter().map(|(k, v)| {
                let d = if v.is_object() {
                    v.get("default").cloned().unwrap_or(serde_json::Value::Null)
                } else {
                    v.clone()
                };
                (k.clone(), d)
            }).collect();
        let ours = character_panel_default_map();

        // Both directions: a workspace field the struct forgot, and a struct
        // field the workspace never declared, are both drift.
        let ours_keys: std::collections::BTreeSet<&str> =
            ours.keys().copied().collect();
        let ws_keys: std::collections::BTreeSet<&str> =
            declared.keys().map(String::as_str).collect();
        assert_eq!(ours_keys, ws_keys,
                   "CharacterPanelState fields and the workspace-declared \
                    character panel state must be the same set");

        for (field, want) in &declared {
            let got = &ours[field.as_str()];
            assert!(same_workspace_value(got, want),
                    "{}: CharacterPanelState::default() has {} but the \
                     workspace declares {}", field, got, want);
        }
    }

    // ---------------------------------------------------------------
    // CODEC FIELD SURVIVAL
    //
    // Every other codec gate in this file compares `document_to_test_json`
    // STRINGS. That catches a dropped field perfectly -- but only for fields
    // the canonical test-JSON itself emits, and the set of fields the BINARY
    // codec drops is a strict SUBSET of the set the test-JSON drops. So no
    // fixture, however saturated, can red-light a binary-codec drop through
    // the string oracle: it would be normalized back to default on the way in
    // and pass, green and vacuous.
    //
    // NOTE 2026-07-28: the SUBSET claim above was true when written and is NOT
    // true now -- the preservation wave extended canonical test-JSON to carry
    // all twelve formerly-dropped fields, so test_json drops NOTHING and binary
    // drops only fill_gradient / stroke_gradient. The oracle got STRONGER. This
    // gate stays: it is BYTE-level where the oracle is string-level.
    //
    // This gate compares at the MODEL level instead (PartialEq on PathElem),
    // which is what lets it see the fields the oracle cannot express. The
    // saturated Path below is mirrored in JasSwift/Tests/CrossLanguageTests
    // .swift (`saturatedPath`) and stated once in prose in the fixture's
    // `saturated_path` block. See transcripts/EDIT_SEMANTICS_FREEZE.md: a
    // round trip speaks to NOTHING, so it must preserve EVERYTHING.
    // ---------------------------------------------------------------

    fn survival_gradient() -> Box<crate::geometry::element::Gradient> {
        use crate::geometry::element::*;
        Box::new(Gradient {
            gtype: GradientType::Radial,
            angle: 45.0,
            aspect_ratio: 200.0,
            method: GradientMethod::Smooth,
            dither: true,
            stroke_sub_mode: StrokeSubMode::Along,
            stops: vec![
                GradientStop { color: Color::Rgb { r: 1.0, g: 0.0, b: 0.0, a: 1.0 },
                               opacity: 100.0, location: 0.0, midpoint_to_next: 25.0 },
                GradientStop { color: Color::Rgb { r: 0.0, g: 0.0, b: 1.0, a: 1.0 },
                               opacity: 50.0, location: 100.0, midpoint_to_next: 50.0 },
            ],
            nodes: vec![],
        })
    }

    /// The attribute-SATURATED Path: every optional field on the kind set to a
    /// non-default value. Mirrored by `saturatedPath()` in JasSwift.
    fn survival_saturated_path() -> crate::geometry::element::PathElem {
        use crate::geometry::element::*;
        PathElem {
            d: vec![PathCommand::MoveTo { x: 0.0, y: 0.0 },
                    PathCommand::LineTo { x: 10.0, y: 10.0 },
                    PathCommand::ClosePath],
            fill: Some(Fill { color: Color::Hsb { h: 120.0, s: 0.5, b: 0.6, a: 0.8 }, opacity: 0.6 }),
            stroke: Some(Stroke {
                color: Color::Cmyk { c: 0.1, m: 0.2, y: 0.3, k: 0.4, a: 0.9 },
                width: 4.5,
                linecap: LineCap::Round,
                linejoin: LineJoin::Bevel,
                miter_limit: 7.5,
                align: StrokeAlign::Inside,
                // Chosen so the SVG round trip is EXACT: the writer emits
                // lengths in px at 4 decimal places, so a pt value whose px
                // form is not exact at 4dp (4pt -> 5.3333px -> 3.999975pt)
                // comes back off by ~1e-5 and the cell would read DROPPED for
                // a PRECISION reason rather than an omission. 3/1.5/6/0.75 pt
                // are 4/2/8/1 px exactly. Mirrored in JasSwift.
                dash_pattern: [3.0, 1.5, 6.0, 0.75, 0.0, 0.0],
                dash_len: 4,
                dash_align_anchors: true,
                start_arrow: Arrowhead::ClosedArrow,
                end_arrow: Arrowhead::Circle,
                start_arrow_scale: 150.0,
                end_arrow_scale: 75.0,
                arrow_align: ArrowAlign::CenterAtEnd,
                opacity: 0.75,
            }),
            width_points: vec![
                StrokeWidthPoint { t: 0.0, width_left: 1.0, width_right: 2.0 },
                StrokeWidthPoint { t: 1.0, width_left: 3.0, width_right: 4.0 },
            ],
            common: CommonProps {
                opacity: 0.5,
                mode: BlendMode::Multiply,
                transform: Some(Transform { a: 2.0, b: 0.0, c: 0.0, d: 3.0, e: 5.0, f: 7.0 }),
                locked: true,
                visibility: Visibility::Outline,
                mask: Some(Box::new(Mask {
                    subtree: Box::new(Element::Rect(RectElem {
                        x: 1.0, y: 2.0, width: 3.0, height: 4.0, rx: 0.0, ry: 0.0,
                        fill: Some(Fill::new(Color::Rgb { r: 1.0, g: 1.0, b: 1.0, a: 1.0 })),
                        stroke: None,
                        common: CommonProps::default(),
                        fill_gradient: None,
                        stroke_gradient: None,
                    })),
                    clip: true,
                    invert: true,
                    disabled: false,
                    linked: false,
                    unlink_transform: Some(Transform { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 9.0, f: 9.0 }),
                })),
                tool_origin: Some("blob_brush".to_string()),
                name: Some("name_path".to_string()),
                id: Some("id_path".to_string()),
            },
            fill_gradient: Some(survival_gradient()),
            stroke_gradient: Some(survival_gradient()),
            fill_rule: FillRule::EvenOdd,
            stroke_brush: Some("basic/calligraphic_5".to_string()),
            stroke_brush_overrides: Some("{\"angle\":30}".to_string()),
        }
    }

    /// The attribute-SATURATED Group: the container half of this gate.
    /// `isolated_blending` and `knockout_group` live on Group and Layer ONLY,
    /// so a saturated Path cannot reach them and the fixture's `fields` list
    /// held no container field at all until 2026-07-28. Mirrored by
    /// `saturatedGroup()` in JasSwift.
    ///
    /// It carries a child on purpose: an EMPTY container is a shape a codec
    /// can legitimately drop, which would confuse a structural loss with a
    /// field loss.
    fn survival_saturated_group() -> crate::geometry::element::GroupElem {
        use crate::geometry::element::*;
        let mut gc = CommonProps::default();
        gc.name = Some("name_group".to_string());
        gc.id = Some("id_group".to_string());
        GroupElem {
            children: vec![std::rc::Rc::new(Element::Rect(RectElem {
                x: 30.0, y: 40.0, width: 5.0, height: 6.0, rx: 0.0, ry: 0.0,
                fill: Some(Fill::new(Color::Rgb { r: 1.0, g: 1.0, b: 1.0, a: 1.0 })),
                stroke: None,
                common: CommonProps::default(),
                fill_gradient: None,
                stroke_gradient: None,
            }))],
            common: gc,
            isolated_blending: true,
            knockout_group: true,
        }
    }

    fn survival_doc() -> crate::document::document::Document {
        use crate::geometry::element::*;
        let mut d = crate::document::document::Document::default();
        let mut lc = CommonProps::default();
        lc.name = Some("Layer 1".to_string());
        // The enclosing Layer is saturated too: Group and Layer are watched
        // SEPARATELY because every codec in both ports has a distinct
        // construction site per kind, so one can be repaired and the other
        // missed.
        d.layers = vec![Element::Layer(LayerElem {
            children: vec![
                std::rc::Rc::new(Element::Path(survival_saturated_path())),
                std::rc::Rc::new(Element::Group(survival_saturated_group())),
            ],
            common: lc,
            isolated_blending: true,
            knockout_group: true,
        })];
        d
    }

    fn survival_first_path(
        d: &crate::document::document::Document,
    ) -> Option<crate::geometry::element::PathElem> {
        use crate::geometry::element::Element;
        let kids = match d.layers.first()? { Element::Layer(e) => &e.children, _ => return None };
        match kids.first()?.as_ref() { Element::Path(p) => Some(p.clone()), _ => None }
    }

    fn survival_first_layer(
        d: &crate::document::document::Document,
    ) -> Option<crate::geometry::element::LayerElem> {
        use crate::geometry::element::Element;
        match d.layers.first()? { Element::Layer(e) => Some(e.clone()), _ => None }
    }

    fn survival_first_group(
        d: &crate::document::document::Document,
    ) -> Option<crate::geometry::element::GroupElem> {
        use crate::geometry::element::Element;
        let kids = match d.layers.first()? { Element::Layer(e) => &e.children, _ => return None };
        kids.iter().find_map(|c| match c.as_ref() {
            Element::Group(g) => Some(g.clone()),
            _ => None,
        })
    }

    /// PRESERVED / DROPPED for each watched field of `after` against `before`.
    ///
    /// Takes the whole DOCUMENT on each side rather than the Path alone,
    /// because four of the watched fields are container fields that no leaf
    /// can carry.
    fn survival_row(
        before_doc: &crate::document::document::Document,
        after_doc: &crate::document::document::Document,
    ) -> Vec<(&'static str, &'static str)> {
        let before = survival_first_path(before_doc)
            .expect("the saturated doc has a Path");
        let before = &before;
        let a = match survival_first_path(after_doc) {
            Some(a) => a,
            None => panic!("codec_field_survival: the saturated Path did not survive the \
                            round trip AT ALL -- every field row below is meaningless"),
        };
        let a = &a;
        // The two containers. A missing one is a STRUCTURAL loss, not a field
        // loss, so it panics rather than reporting DROPPED four times and
        // inviting the reader to fix the wrong thing.
        let bl = survival_first_layer(before_doc).expect("the saturated doc has a Layer");
        let al = survival_first_layer(after_doc).unwrap_or_else(|| panic!(
            "codec_field_survival: the saturated Layer did not survive the round trip \
             AT ALL -- the layer.* rows below would be meaningless"));
        let bg = survival_first_group(before_doc).expect("the saturated doc has a Group");
        let ag = survival_first_group(after_doc).unwrap_or_else(|| panic!(
            "codec_field_survival: the saturated Group did not survive the round trip \
             AT ALL -- the group.* rows below would be meaningless"));
        let s = |ok: bool| if ok { "PRESERVED" } else { "DROPPED" };
        vec![
            ("common.locked", s(a.common.locked == before.common.locked)),
            ("common.mask", s(a.common.mask == before.common.mask)),
            ("common.mode", s(a.common.mode == before.common.mode)),
            ("common.tool_origin", s(a.common.tool_origin == before.common.tool_origin)),
            ("fill_gradient", s(a.fill_gradient == before.fill_gradient)),
            ("fill_rule", s(a.fill_rule == before.fill_rule)),
            ("group.isolated_blending", s(ag.isolated_blending == bg.isolated_blending)),
            ("group.knockout_group", s(ag.knockout_group == bg.knockout_group)),
            ("layer.isolated_blending", s(al.isolated_blending == bl.isolated_blending)),
            ("layer.knockout_group", s(al.knockout_group == bl.knockout_group)),
            ("stroke.align", s(a.stroke.map(|x| x.align) == before.stroke.map(|x| x.align))),
            ("stroke.dash_align_anchors",
             s(a.stroke.map(|x| x.dash_align_anchors) == before.stroke.map(|x| x.dash_align_anchors))),
            // The ACTIVE slice, not the fixed six-slot array: the two ports
            // store the pattern differently (Rust [f64; 6] + dash_len, Swift a
            // Vec), and `dash_array()` / `dashPattern` is the shape they share.
            ("stroke.dash_pattern",
             s(a.stroke.map(|x| x.dash_array().to_vec()) == before.stroke.map(|x| x.dash_array().to_vec()))),
            ("stroke.miter_limit",
             s(a.stroke.map(|x| x.miter_limit) == before.stroke.map(|x| x.miter_limit))),
            ("stroke_brush", s(a.stroke_brush == before.stroke_brush)),
            ("stroke_brush_overrides", s(a.stroke_brush_overrides == before.stroke_brush_overrides)),
            ("stroke_gradient", s(a.stroke_gradient == before.stroke_gradient)),
            ("width_points", s(a.width_points == before.width_points)),
        ]
    }

    #[test]
    fn codec_field_survival() {
        let raw = read_fixture("expected/codec_field_survival.json");
        let fx: serde_json::Value = serde_json::from_str(&raw)
            .expect("codec_field_survival.json is not valid JSON");
        let fields: Vec<String> = fx["fields"].as_array().unwrap().iter()
            .map(|v| v.as_str().unwrap().to_string()).collect();
        assert!(!fields.is_empty(), "codec_field_survival: the field list is empty");

        let doc = survival_doc();

        let via_json = test_json_to_document(&document_to_test_json(&doc));
        let via_bin = binary_to_document(&document_to_binary(&doc, false))
            .expect("binary round trip of the saturated doc");
        let via_svg = svg_to_document(&document_to_svg(&doc));

        for (codec, rt) in [("test_json", &via_json), ("binary", &via_bin), ("svg", &via_svg)] {
            let got = survival_row(&doc, rt);
            assert_eq!(got.len(), fields.len(),
                "codec_field_survival: the gate watches {} fields, the fixture declares {}",
                got.len(), fields.len());
            for (field, actual) in got {
                assert!(fields.iter().any(|f| f == field),
                    "codec_field_survival: field '{}' is watched by the gate but absent \
                     from the fixture's `fields` list", field);
                // A `port_overrides` entry means the two ports measurably
                // disagree on this cell today; this port is asserted to produce
                // the OTHER value, so closing the divergence reds this gate
                // until the entry is deleted.
                let override_val = fx["port_overrides"]["entries"].as_array().unwrap().iter()
                    .find(|e| e["codec"] == codec && e["field"] == field && e["port"] == "rust")
                    .and_then(|e| e["value"].as_str());
                let expected = override_val.unwrap_or_else(|| {
                    fx["survival"][codec][field].as_str().unwrap_or_else(|| panic!(
                        "codec_field_survival: fixture declares no cell for {}/{}", codec, field))
                });
                assert_eq!(expected, actual,
                    "codec_field_survival: {}/{} -- fixture says {}, rust measured {}{}",
                    codec, field, expected, actual,
                    if override_val.is_some() {
                        " (a port_overrides entry pins this cell; if the divergence closed, \
                          delete the entry)"
                    } else { "" });
            }
        }
    }

    // ---------------------------------------------------------------
    // BINARY WIRE -- the byte-level gate
    //
    // RULED 2026-07-27 together with the codec's per-tag trailing extension:
    // every OTHER codec gate compares canonical test-JSON strings, and the
    // fields the binary codec drops are a strict SUBSET of the fields that
    // string oracle also drops. So a one-port slot mismatch in `pack_element`
    // would land SILENTLY -- extending a format whose divergences we cannot
    // see is not acceptable. Coverage gap
    // `codec-string-oracle-cannot-see-a-dropped-field` is the record.
    //
    // This gate compares BYTES against ONE shared golden
    // (test_fixtures/expected/binary_wire.json), which is what makes it a
    // cross-port statement: a port that drifts cannot fix itself by editing
    // its own literal, because there is no per-port literal to edit. The
    // fixture also declares the per-tag ARITY the trailing append is defined
    // against, asserted here through `packed_element_slot_count`.
    //
    // Twin: `binaryWire` in JasSwift/Tests/CrossLanguageTests.swift.
    // ---------------------------------------------------------------

    /// One element per wire tag, in the fixture's `tag_arity` key order.
    /// Mirrored by `wireTagElements()` in JasSwift. The CONTENT is
    /// deliberately minimal: arity is a property of the tag, not of the
    /// values, so a shape with fewer numbers makes the pinned bytes readable.
    fn wire_tag_elements() -> Vec<crate::geometry::element::Element> {
        use crate::geometry::element::*;
        use crate::geometry::live::*;
        let c = CommonProps::default;
        vec![
            Element::Layer(LayerElem { children: vec![], isolated_blending: false,
                                       knockout_group: false, common: c() }),
            Element::Group(GroupElem { children: vec![], isolated_blending: false,
                                       knockout_group: false, common: c() }),
            Element::Line(LineElem { x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0, stroke: None,
                                     width_points: vec![], common: c(),
                                     stroke_gradient: None }),
            Element::Rect(RectElem { x: 0.0, y: 0.0, width: 1.0, height: 2.0, rx: 0.0, ry: 0.0,
                                     fill: None, stroke: None, common: c(),
                                     fill_gradient: None, stroke_gradient: None }),
            Element::Ellipse(EllipseElem { cx: 0.0, cy: 0.0, rx: 1.0, ry: 1.0, fill: None, stroke: None,
                                         common: c(), fill_gradient: None,
                                         stroke_gradient: None }),
            Element::Ellipse(EllipseElem { cx: 0.0, cy: 0.0, rx: 1.0, ry: 2.0, fill: None,
                                           stroke: None, common: c(), fill_gradient: None,
                                           stroke_gradient: None }),
            Element::Polyline(PolylineElem { points: vec![(0.0, 0.0), (1.0, 1.0)], fill: None,
                                             stroke: None, common: c(), fill_gradient: None,
                                             stroke_gradient: None }),
            Element::Polygon(PolygonElem { points: vec![(0.0, 0.0), (1.0, 1.0), (2.0, 0.0)],
                                           fill: None, stroke: None, common: c(),
                                           fill_gradient: None, stroke_gradient: None }),
            Element::Path(PathElem { d: vec![PathCommand::MoveTo { x: 0.0, y: 0.0 },
                                             PathCommand::LineTo { x: 1.0, y: 1.0 }],
                                     fill: None, stroke: None, width_points: vec![],
                                     common: c(), fill_gradient: None, stroke_gradient: None,
                                     fill_rule: FillRule::NonZero, stroke_brush: None,
                                     stroke_brush_overrides: None }),
            Element::Text(TextElem::from_string(1.0, 2.0, "hi", "Arial", 12.0, "normal",
                                                "normal", "none", 10.0, 12.0, None, None, c())),
            Element::TextPath(TextPathElem::from_string(
                vec![PathCommand::MoveTo { x: 0.0, y: 0.0 },
                     PathCommand::LineTo { x: 1.0, y: 1.0 }],
                "hi", 0.0, "Arial", 12.0, "normal", "normal", "none", None, None, c())),
            Element::Live(LiveVariant::Reference(
                ReferenceElem::new(ElementRef("m1".to_string()), c()))),
        ]
    }

    /// Every LIVE kind, which all share `tag_arity["live"]`.
    fn wire_live_elements() -> Vec<crate::geometry::element::Element> {
        use crate::geometry::element::*;
        use crate::geometry::live::*;
        let c = CommonProps::default;
        vec![
            Element::Live(LiveVariant::CompoundShape(CompoundShape {
                operation: CompoundOperation::Union, operands: vec![],
                fill: None, stroke: None, common: c() })),
            Element::Live(LiveVariant::Reference(
                ReferenceElem::new(ElementRef("m1".to_string()), c()))),
            Element::Live(LiveVariant::Recorded(RecordedElem::new(vec![], vec![], c()))),
            Element::Live(LiveVariant::Generated(GeneratedElem::new(
                "spiral".to_string(), serde_json::Value::Object(Default::default()), c()))),
        ]
    }

    /// The document a named wire case packs. Mirrored by `wireCaseDocument`
    /// in JasSwift -- the two constructions ARE the thing being compared, so
    /// they must stay identical shape for identical shape.
    fn wire_case_document(name: &str) -> crate::document::document::Document {
        use crate::document::document::Document;
        use crate::geometry::element::*;
        let layer = |kids: Vec<Element>| Element::Layer(LayerElem {
            children: kids.into_iter().map(std::rc::Rc::new).collect(),
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let doc = |kids: Vec<Element>| Document {
            layers: vec![layer(kids)], selected_layer: 0, ..Document::default()
        };
        match name {
            // Every non-text, non-live tag at its default, so the arity of
            // each is visible in the bytes.
            "shapes_default" => doc(wire_tag_elements().into_iter()
                .filter(|e| !matches!(e, Element::Text(_) | Element::TextPath(_)
                                        | Element::Live(_) | Element::Layer(_)))
                .collect()),
            // Text and TextPath, split out because the tspan payload is where
            // the two ports are KNOWN to diverge (see the fixture's
            // `port_hex`).
            "text_default" => doc(wire_tag_elements().into_iter()
                .filter(|e| matches!(e, Element::Text(_) | Element::TextPath(_)))
                .collect()),
            "live_default" => doc(wire_live_elements()),
            // The extension's whole reason for existing, at non-default
            // values: a masked, blend-moded, tool-tagged, brushed Path.
            "saturated_extension" => doc(vec![Element::Path(survival_saturated_path())]),
            other => panic!("binary_wire: unknown case '{other}'"),
        }
    }

    fn wire_hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    /// Regeneration helper after an INTENTIONAL codec change. Run with:
    ///   cargo test print_binary_wire_hex -- --ignored --nocapture
    #[test]
    #[ignore]
    fn print_binary_wire_hex() {
        for e in wire_tag_elements() {
            println!("ARITY {} = {}", crate::geometry::binary::element_tag_label(&e),
                     crate::geometry::binary::packed_element_slot_count(&e));
        }
        for name in ["shapes_default", "text_default", "live_default",
                     "saturated_extension"] {
            println!("CASE {} = {}", name,
                     wire_hex(&document_to_binary(&wire_case_document(name), false)));
        }
    }

    #[test]
    fn binary_wire() {
        let raw = read_fixture("expected/binary_wire.json");
        let fx: serde_json::Value = serde_json::from_str(&raw)
            .expect("binary_wire.json is not valid JSON");

        // (1) ARITY. Every tag's packed slot count is declared as data and
        // asserted here, so a slot added to one port and not the other cannot
        // hide behind a compensating change elsewhere in the array.
        let arity = fx["tag_arity"].as_object().expect("tag_arity object");
        let mut seen: Vec<String> = Vec::new();
        for elem in wire_tag_elements().iter().chain(wire_live_elements().iter()) {
            let label = crate::geometry::binary::element_tag_label(elem);
            let want = arity.get(label)
                .unwrap_or_else(|| panic!("binary_wire: tag_arity declares no '{label}'"))
                .as_u64().expect("tag_arity value is an integer") as usize;
            let got = crate::geometry::binary::packed_element_slot_count(elem);
            assert_eq!(got, want,
                "binary_wire: TAG '{label}' packs {got} slots, the fixture declares {want}");
            if !seen.iter().any(|s| s == label) { seen.push(label.to_string()); }
        }
        assert_eq!(seen.len(), arity.len(),
            "binary_wire: the gate reaches {} tags, the fixture declares {} -- every tag \
             must be watched", seen.len(), arity.len());

        // (2) BYTES. One shared golden per case, uncompressed so the pinned
        // string is the msgpack itself rather than a deflate stream.
        for case in fx["cases"].as_array().expect("cases array") {
            let name = case["name"].as_str().expect("case name");
            let expected = case["port_hex"].get("rust").and_then(|v| v.as_str())
                .unwrap_or_else(|| case["hex"].as_str().expect("case hex"));
            let got = wire_hex(&document_to_binary(&wire_case_document(name), false));
            assert_eq!(got, expected,
                "binary_wire: case '{name}' bytes changed. If the codec changed on \
                 PURPOSE, regenerate with `cargo test print_binary_wire_hex -- --ignored \
                 --nocapture` and update the SHARED fixture, which will red the other \
                 port until it agrees.");
            // The bytes must also decode -- a pinned string that no longer
            // parses would be a green gate over a broken codec.
            let doc = binary_to_document(&crate::geometry::binary::unhex_for_tests(expected))
                .unwrap_or_else(|e| panic!("binary_wire: case '{name}' does not decode: {e}"));
            assert!(!doc.layers.is_empty(), "binary_wire: case '{name}' decoded to no layers");
        }
    }

    /// A `jas:`-prefixed attribute obliges the root `<svg>` to declare the
    /// namespace: a strict XML parser rejects an undeclared prefix, and it
    /// rejects the WHOLE DOCUMENT, not the attribute. `jas:tool-origin` is the
    /// case the saturated `codec_field_survival` fixture cannot see, because a
    /// saturated path also carries arrowheads and the arrowheads pull the
    /// namespace in by themselves.
    ///
    /// The element here is what Blob Brush actually commits: a tool-origin tag
    /// and no arrowheads. Mirrors `svgToolOriginSurvivesWithoutArrowheads` in
    /// JasSwift/Tests/CrossLanguageTests.swift.
    #[test]
    fn svg_tool_origin_survives_without_arrowheads() {
        use crate::geometry::element::*;
        let mut common = CommonProps::default();
        common.tool_origin = Some("blob_brush".to_string());
        let path = Element::Path(PathElem {
            d: vec![PathCommand::MoveTo { x: 0.0, y: 0.0 },
                    PathCommand::LineTo { x: 10.0, y: 10.0 }],
            fill: None,
            stroke: Some(Stroke::new(Color::Rgb { r: 0.0, g: 0.0, b: 0.0, a: 1.0 }, 2.0)),
            width_points: vec![],
            common,
            fill_gradient: None,
            stroke_gradient: None,
            fill_rule: FillRule::NonZero,
            stroke_brush: None,
            stroke_brush_overrides: None,
        });
        let mut lc = CommonProps::default();
        lc.name = Some("L".to_string());
        let mut doc = crate::document::document::Document::default();
        doc.layers = vec![Element::Layer(LayerElem {
            children: vec![std::rc::Rc::new(path)],
            common: lc,
            isolated_blending: false,
            knockout_group: false,
        })];

        let svg = document_to_svg(&doc);
        assert!(svg.contains("jas:tool-origin=\"blob_brush\""),
                "the writer must emit jas:tool-origin; got:\n{}", svg);
        assert!(svg.contains("xmlns:jas="),
                "a jas:-prefixed attribute obliges the root <svg> to declare \
                 xmlns:jas; got:\n{}", svg);

        let back = svg_to_document(&svg);
        let kids = match back.layers.first() {
            Some(Element::Layer(l)) => l.children.len(),
            _ => 0,
        };
        assert_eq!(kids, 1,
            "the round-tripped document lost its content entirely -- an \
             undeclared namespace prefix makes a strict parser reject the \
             whole file");
        match back.layers.first() {
            Some(Element::Layer(l)) => match l.children.first().map(|c| c.as_ref()) {
                Some(Element::Path(p)) => assert_eq!(
                    p.common.tool_origin.as_deref(), Some("blob_brush"),
                    "tool origin did not survive the SVG round trip"),
                other => panic!("expected a Path, got {:?}", other),
            },
            other => panic!("expected a Layer, got {:?}", other),
        }
    }

    #[test]
    fn state_defaults() {
        let json = state_defaults_json();
        assert_workspace_fixture("state_defaults", &json);
    }

    #[test]
    fn shortcut_structure() {
        let json = shortcut_structure_json();
        assert_workspace_fixture("shortcut_structure", &json);
    }

    #[cfg(feature = "web")]
    /// CONTAINER-SEEDED EQUIVALENCE: an operation on a group must equal the
    /// same operation on its sole member.
    ///
    /// Council O3.1. Candidate 3 of `QUEUE-finding-defects-better.md`, scored
    /// by Starbuck at arbitration as reaching 5 of the 8 known defects
    /// outright — the highest of the four candidates, and the ONLY one that
    /// reaches premises nobody wrote down, because it needs no one to have
    /// anticipated anything.
    ///
    /// THE LAW. Every one of those eight defects fired on the same input: A
    /// SELECTED CONTAINER. Each was a function that answered correctly for a
    /// leaf and wrongly — or silently not at all — for a group wrapping that
    /// same leaf. So: take a corpus case, wrap its selected element in a
    /// single-child group, run the identical action against the identical
    /// selection path (wrapping IN PLACE leaves the path unchanged, and the
    /// group is now what is selected), and require the two results to agree
    /// once the wrapper is removed.
    ///
    /// NO GOLDEN IS INVOLVED, which is what makes this cheap and what makes it
    /// reach defects nobody predicted. It compares the app against ITSELF under
    /// a transformation that must not matter. A shared defect — both ports
    /// wrong identically, which was six of the original eight — is invisible to
    /// every differential gate we own and visible here.
    #[test]
    fn an_operation_on_a_group_equals_the_same_operation_on_its_member() {
        use crate::geometry::element::{CommonProps, Element, GroupElem};

        // Actions whose MEANING changes with a container, so the relation does
        // not hold and saying so is not a cop-out. Each needs a reason.
        const EXEMPT: &[(&str, &str)] = &[
            ("group", "wrapping the target is the operation's own subject"),
            ("ungroup", "likewise, in reverse"),
            ("ungroup_all", "likewise"),
            ("promote_to_concept", "container identity is the payload"),
            ("make_instance", "same"),
            ("new_symbol", "same"),
            ("place_instance", "same"),
        ];

        /// Wrap the element at `path` in a single-child group, marked so it can
        /// be found again after the operation has run.
        fn wrap_at(doc: &mut crate::document::document::Document, path: &[usize]) -> bool {
            if path.len() != 2 { return false; }        // top-level child only
            let Some(layer) = doc.layers.get_mut(path[0]) else { return false };
            let Some(kids) = layer.children_mut() else { return false };
            let Some(slot) = kids.get_mut(path[1]) else { return false };
            let inner = (**slot).clone();
            if inner.is_group_or_layer() { return false; }   // leaves only
            *slot = std::rc::Rc::new(Element::Group(GroupElem {
                children: vec![std::rc::Rc::new(inner)],
                common: CommonProps { name: Some("__seed_wrapper__".into()),
                                      ..CommonProps::default() },
                isolated_blending: false,
                knockout_group: false,
            }));
            true
        }

        /// Remove the wrappers again, so the two documents are comparable.
        fn unwrap_seeds(el: &Element) -> Element {
            let mut out = el.clone();
            if let Some(kids) = out.children_mut() {
                let mut next: Vec<std::rc::Rc<Element>> = Vec::with_capacity(kids.len());
                for k in kids.iter() {
                    let cleaned = unwrap_seeds(k);
                    let is_seed = matches!(&cleaned, Element::Group(g)
                        if g.common.name.as_deref() == Some("__seed_wrapper__"));
                    if is_seed {
                        if let Element::Group(g) = &cleaned {
                            for gc in &g.children { next.push(gc.clone()); }
                        }
                    } else {
                        next.push(std::rc::Rc::new(cleaned));
                    }
                }
                *kids = next;
            }
            out
        }

        // KNOWN DISAGREEMENTS. Landing these as a pinned list rather than as a
        // lowered floor is deliberate: the valuable direction is that a NEW
        // disagreement reds, and that works from the first run. Each row was
        // filed as a QUESTION, not an accepted answer -- declaring them
        // "artifacts" on reasoning alone would be the confident-and-wrong row
        // this project keeps catching itself writing.
        //
        // TRIAGED 2026-07-30 (Flask, seat `TRIAGE-container-seeded-seven.md`),
        // by reproducing each one and READING THE BYTES rather than arguing.
        // The theory that all seven were artifacts DID NOT SURVIVE: three are,
        // four were a real defect and are now fixed.
        //
        //   menu_lock / menu_hide: the flag lands on the WRAPPER and this
        //   comparison strips it -- measured, `"locked":true` vs `false` and
        //   `"invisible"` vs `"preview"`. Both CASCADE (`effective_locked` /
        //   `effective_visibility`), so the artist-visible result is identical.
        //   CONFIRMED artifact.
        //
        //   make_compound_shape: the group version carries one extra nesting
        //   level, because the wrapper survived as a compound-shape OPERAND --
        //   which BOOLEAN.md §operands explicitly permits -- and `unwrap_seeds`
        //   does not recurse into a LiveElement's operands. The relation is
        //   comparing two structures that are correctly different. CONFIRMED
        //   artifact.
        //
        //   THE FOUR BOOLEAN ROWS ARE GONE, and their absence is the gate:
        //   union / subtract_front / intersection / exclude on a container
        //   produced UNPAINTED, UNSTROKED artwork wearing the container's name
        //   (`"fill":null, "name":"__seed_wrapper__"`). Not a semantic question
        //   -- BOOLEAN.md settles both halves, §operands making a group a
        //   legitimate operand and §paint taking "the frontmost operand's fill,
        //   stroke, opacity and blend mode" -- but an implementation that could
        //   not apply the settled rule to a container, because `fill()` and
        //   `stroke()` both end `_ => None`. Fixed at every one of the six
        //   container-reading paint sites plus the `common` reads beside them;
        //   see `operand_leaves` / `source_common` /
        //   `geometry::element::resolved_fill` and the unit twins in
        //   controller.rs (`a_boolean_over_a_grouped_operand_paints_like_the_bare_leaf`).
        //
        // Removing a row here still requires either a fix or a recorded ruling.
        const KNOWN: &[&str] = &[
            "make_compound_shape.json::make_compound_shape_two_rects",
            "menu_object_ops.json::menu_lock_two_rects",
            "menu_object_ops.json::menu_hide_two_rects",
        ];

        let mut checked = 0usize;
        let mut disagreements: Vec<String> = Vec::new();
        let mut seen_known: Vec<String> = Vec::new();

        for fname in ACTION_FIXTURES {
            let raw = read_fixture(&format!("actions/{fname}"));
            let cases: serde_json::Value = match serde_json::from_str(&raw) {
                Ok(v) => v, Err(_) => continue,
            };
            let Some(arr) = cases.as_array() else { continue };
            for tc in arr {
                let Some(setup) = tc["setup_svg"].as_str() else { continue };
                let sel = match tc["selection"].as_array() { Some(s) => s, None => continue };
                if sel.is_empty() { continue; }
                // EVERY selected leaf gets wrapped, not just a lone one. The
                // first cut required a single target and seeded ZERO cases --
                // the corpus is overwhelmingly two- and three-target
                // selections, and the anti-vacuity floor is the only reason
                // that was noticed rather than reported as a clean run.
                //
                // Wrapping IN PLACE is what makes multi-target safe: each
                // wrapper takes the slot its element occupied, so no index
                // moves and every selection path stays valid and now names a
                // group.
                let paths: Vec<Vec<usize>> = sel.iter()
                    .filter_map(|p| p.as_array())
                    .map(|p| p.iter().filter_map(|n| n.as_u64()).map(|n| n as usize).collect())
                    .collect();
                let acts = tc["actions"].as_array().cloned().unwrap_or_default();
                if acts.iter().any(|a| {
                    let n = a["action"].as_str().unwrap_or("");
                    EXEMPT.iter().any(|(e, _)| *e == n)
                }) { continue; }

                let svg = read_fixture(&format!("svg/{setup}"));
                let mut wrapped_doc = svg_to_document(&svg);
                let mut any = false;
                for path in &paths {
                    if wrap_at(&mut wrapped_doc, path) { any = true; }
                }
                if !any { continue; }
                let wrapped_svg = document_to_svg(&wrapped_doc);

                let plain = crate::recorder::replay::run_action_case(tc, &svg);
                let seeded = crate::recorder::replay::run_action_case(tc, &wrapped_svg);

                let mut plain_doc = plain.tabs[plain.active_tab].model.document().clone();
                let mut seeded_doc = seeded.tabs[seeded.active_tab].model.document().clone();
                plain_doc.layers = plain_doc.layers.iter().map(unwrap_seeds).collect();
                seeded_doc.layers = seeded_doc.layers.iter().map(unwrap_seeds).collect();

                checked += 1;
                let a = document_to_test_json(&plain_doc);
                let b = document_to_test_json(&seeded_doc);
                if a != b {
                    let name = tc["name"].as_str().unwrap_or("<unnamed>");
                    let key = format!("{fname}::{name}");
                    if KNOWN.contains(&key.as_str()) {
                        seen_known.push(key);
                    } else {
                        disagreements.push(key);
                    }
                }
            }
        }

        // Anti-vacuity: a walk that seeded nothing proves nothing, and would
        // read exactly like a clean tree.
        assert!(checked >= 20,
                "only {checked} case(s) were container-seeded -- below the floor. \
                 A transform that silently applies to nothing reports no \
                 disagreements, which is indistinguishable from agreement.");

        // A KNOWN row that stopped disagreeing is a row that must go -- the
        // same expiry discipline the exemption ledgers carry, so a fix cannot
        // leave a stale question behind.
        let vanished: Vec<&str> = KNOWN.iter()
            .filter(|k| !seen_known.iter().any(|s| s == *k))
            .copied()
            .collect();
        assert!(vanished.is_empty(),
                "{} known disagreement(s) no longer disagree -- delete the rows: {:?}",
                vanished.len(), vanished);

        assert!(disagreements.is_empty(),
                "{} NEW container-seeded disagreement(s) out of {checked} \
                 seeded ({} known) -- an operation answered differently for a \
                 group than for its sole member, which is the shape all eight \
                 of the 2026-07-29 defects wore:\n  {}",
                disagreements.len(), seen_known.len(), disagreements.join("\n  "));
    }

    /// THE TYPE TOKEN IS DERIVED FROM THE ELEMENT, NOT FROM ITS TAG.
    ///
    /// `test_fixtures/view_state/element_type_tokens.json` is the single
    /// definition; the twin reader is `elementTypeTokensMatchTheSharedCorpus`
    /// in JasSwift/Tests/CrossLanguageTests.swift.
    ///
    /// It exists because the model used to carry a `circle` kind AND an
    /// `ellipse` kind, and the token was whichever tag the SVG had. That is
    /// provenance: `apply_scale` composes a matrix onto `common.transform` and
    /// never touches the radii, so a `circle` stayed typed `circle` while being
    /// drawn as an egg. JYH ruled 2026-07-30 that one round kind survives and
    /// `circle` becomes a DERIVED token.
    ///
    /// The decisive row is `[0, 1]`: an `<ellipse rx=20 ry=20>` and a
    /// `<circle r=20>` are the same shape, so they must answer the same token.
    /// Under the old tag-based rule they did not.
    #[test]
    fn element_type_tokens_match_the_shared_corpus() {
        use crate::algorithms::layers_filter::type_value;

        let raw = read_fixture("view_state/element_type_tokens.json");
        let spec: serde_json::Value = serde_json::from_str(&raw)
            .expect("element_type_tokens.json is not valid JSON");
        let setup = spec["setup_svg"].as_str().expect("no `setup_svg`");
        let doc = svg_to_document(&read_fixture(&format!("svg/{setup}")));

        let rows = spec["rows"].as_array().expect("no `rows`");
        let min = spec["min_rows"].as_u64().expect("no `min_rows`") as usize;
        // Anti-vacuity declared BY THE DATA, so the floor cannot drift out of
        // step with the corpus it guards.
        assert_eq!(rows.len(), min,
                   "walked {} row(s) against a declared floor of {}", rows.len(), min);

        for row in rows {
            let path: Vec<usize> = row["path"].as_array().unwrap()
                .iter().map(|n| n.as_u64().unwrap() as usize).collect();
            let want = row["token"].as_str().unwrap();
            let why = row["why"].as_str().unwrap_or("");
            let elem = doc.get_element(&path)
                .unwrap_or_else(|| panic!("no element at {path:?}"));
            assert_eq!(type_value(elem), want,
                       "type token at {path:?} should be {want:?} -- {why}");
        }
    }

    /// `<circle>` SURVIVES A ROUND TRIP even though the model no longer has a
    /// circle kind: the writer re-derives the tag from the radii AS THEY WILL
    /// BE PRINTED.
    ///
    /// The mirror is pinned too, and it is a REWRITE we accept rather than a
    /// property we achieved: an `<ellipse rx=20 ry=20>` comes back out as
    /// `<circle>`. Someone who authored that ellipse deliberately will see it
    /// change. That is the price of one kind, recorded here so it is a decision
    /// and not a surprise.
    ///
    /// THE SECOND HALF, added after the render-path audit, is the SUB-PRECISION
    /// case: the tag used to be decided by an exact `rx == ry` while the
    /// coordinates were printed at four decimals, so radii differing below the
    /// printed precision were written as `<ellipse rx="20" ry="20">` -- a file
    /// that reopens EXACTLY round. The tag flipped to `<circle>` on the very
    /// next save and the derived type token flipped with it. The twin is
    /// `roundEllipsesSerializeAsCircleAndSquashedOnesDoNot` in
    /// JasSwift/Tests/CrossLanguageTests.swift, over the same two fixtures.
    #[test]
    fn round_ellipses_serialize_as_circle_and_squashed_ones_do_not() {
        use crate::algorithms::layers_filter::type_value;

        let doc = svg_to_document(&read_fixture("svg/circle_ellipse_mix.svg"));
        let out = document_to_svg(&doc);
        assert_eq!(out.matches("<circle").count(), 2,
                   "both round shapes should emit <circle>; got:\n{out}");
        assert_eq!(out.matches("<ellipse").count(), 1,
                   "only the rx != ry shape should emit <ellipse>; got:\n{out}");
        // And the re-read is stable -- a second trip must not oscillate.
        assert_eq!(document_to_svg(&svg_to_document(&out)), out,
                   "svg -> doc -> svg is not idempotent");

        // THE TAG DESCRIBES WHAT WAS PRINTED. Hand-derived expectations for
        // `svg/ellipse_radii_below_print_precision.svg` (pt = px * 0.75, and
        // the writer prints px at four decimals):
        //   [0, 0] rx=20.00001px ry=20.00002px. The radii differ, but both
        //          print "20.0000" -> "20". Written as an <ellipse> the file
        //          would say rx == ry and reopen round, so the tag must be
        //          <circle> from the start.
        //   [0, 1] rx=20px ry=20.0002px. That difference IS printed, so this
        //          one stays an <ellipse> on every trip -- the guard against
        //          a fix that rounds harder than the writer does.
        let sub = svg_to_document(
            &read_fixture("svg/ellipse_radii_below_print_precision.svg"));
        let out1 = document_to_svg(&sub);
        assert_eq!(out1.matches("<circle").count(), 1,
                   "radii differing below the printed precision must be \
                    written as <circle>; got:\n{out1}");
        assert_eq!(out1.matches("<ellipse").count(), 1,
                   "radii differing above the printed precision must stay \
                    <ellipse>; got:\n{out1}");

        // svg -> doc -> svg -> doc: what was written reads back as what was
        // written, and the type token agrees with the tag.
        let sub1 = svg_to_document(&out1);
        assert_eq!(type_value(sub1.get_element(&vec![0, 0]).unwrap()), "circle",
                   "the <circle> we wrote must read back as a round ellipse");
        assert_eq!(type_value(sub1.get_element(&vec![0, 1]).unwrap()), "ellipse",
                   "the <ellipse> we wrote must read back squashed");

        // ... and the next save does not move, in tag or in token.
        let out2 = document_to_svg(&sub1);
        assert_eq!(out2, out1,
                   "the tag is not stable across save-and-reopen:\n{out1}\n{out2}");
        let sub2 = svg_to_document(&out2);
        assert_eq!(type_value(sub2.get_element(&vec![0, 0]).unwrap()), "circle",
                   "type token flipped on the second trip");
        assert_eq!(type_value(sub2.get_element(&vec![0, 1]).unwrap()), "ellipse",
                   "type token flipped on the second trip");
    }

    /// THE LAYERS TYPE FILTER, driven from the shared corpus.
    ///
    /// `test_fixtures/view_state/layers_type_filter.json` is the single
    /// definition of this algorithm; the twin reader is
    /// `layersTypeFilterMatchesTheSharedCorpus` in
    /// JasSwift/Tests/CrossLanguageTests.swift.
    ///
    /// It exists because this filter had NO test on either side for months while
    /// the two ports disagreed: jas_dioxus derived each row's type by parsing its
    /// display label, so a NAMED element escaped the filter entirely. Per-port
    /// unit tests now pin each half, but two hand-written suites agree today and
    /// drift later — the corpus is what makes them answer to one source.
    ///
    /// The rows carry TYPES, not labels. A vector spelled as display names would
    /// re-enact the defect inside the corpus meant to prevent it.
    #[test]
    fn layers_type_filter_matches_the_shared_corpus() {
        use crate::algorithms::layers_filter::type_filter_keep;
        use std::collections::HashSet;

        let raw = read_fixture("view_state/layers_type_filter.json");
        let doc: serde_json::Value = serde_json::from_str(&raw)
            .expect("layers_type_filter.json is not valid JSON");

        let vectors = doc["vectors"].as_array().expect("no `vectors` array");
        let min = doc["min_vectors"].as_u64().expect("no `min_vectors`") as usize;
        // Anti-vacuity, EXACT rather than slack: a reader that walked zero
        // vectors asserts nothing and is indistinguishable from a clean run.
        // The floor is declared BY THE DATA, which is the shape
        // check_preservation_corpus.py established -- a floor the fixture states
        // about itself cannot drift out of step with it.
        assert_eq!(
            vectors.len(), min,
            "walked {} vector(s) against a declared floor of {}",
            vectors.len(), min
        );

        for v in vectors {
            let name = v["name"].as_str().unwrap_or("<unnamed>");
            let rows: Vec<(Vec<usize>, String)> = v["rows"].as_array()
                .unwrap_or_else(|| panic!("{name}: no `rows`"))
                .iter()
                .map(|r| (
                    r["path"].as_array().expect("row has no `path`").iter()
                        .map(|n| n.as_u64().expect("path entry not a number") as usize)
                        .collect(),
                    r["type"].as_str().expect("row has no `type`").to_string(),
                ))
                .collect();
            let hidden: HashSet<String> = v["hidden"].as_array()
                .unwrap_or_else(|| panic!("{name}: no `hidden`"))
                .iter()
                .map(|t| t.as_str().expect("hidden entry not a string").to_string())
                .collect();
            let mut want: Vec<Vec<usize>> = v["expected_keep"].as_array()
                .unwrap_or_else(|| panic!("{name}: no `expected_keep`"))
                .iter()
                .map(|p| p.as_array().expect("expected path not an array").iter()
                    .map(|n| n.as_u64().expect("path entry not a number") as usize)
                    .collect())
                .collect();
            want.sort();

            let keep = type_filter_keep(
                rows.iter().map(|(p, t)| (p.as_slice(), t.as_str())),
                &hidden,
            );
            let mut got: Vec<Vec<usize>> = keep.iter().cloned().collect();
            got.sort();

            assert_eq!(got, want, "vector `{name}`");

            // SCAFFOLDING vs CONTENT. A surviving row whose own type is hidden
            // is here only to reach a descendant -- carried, never matched, and
            // rendered dimmed (JYH, council 2026-07-30). Derived in the fixture
            // as `keep \ visible`, recomputed here, so the two cannot drift.
            let mut want_anc: Vec<Vec<usize>> = v["expected_ancestor_only"].as_array()
                .unwrap_or_else(|| panic!("{name}: no `expected_ancestor_only`"))
                .iter()
                .map(|p| p.as_array().expect("path not an array").iter()
                    .map(|n| n.as_u64().expect("path entry not a number") as usize)
                    .collect())
                .collect();
            want_anc.sort();
            let mut got_anc: Vec<Vec<usize>> = keep.iter()
                .filter(|k| rows.iter().any(|(p, t)| p == *k && hidden.contains(t.as_str())))
                .cloned()
                .collect();
            got_anc.sort();
            assert_eq!(got_anc, want_anc, "vector `{name}`: ancestor-only set");
        }
    }

    /// THE FILTER MENU — which declared item becomes which KIND of row, and what
    /// each kind does when clicked.
    ///
    /// Driven from the `menu` block of
    /// `test_fixtures/view_state/layers_type_filter.json`; the twin reader is
    /// `layersFilterMenuMatchesTheSharedCorpus` in
    /// JasSwift/Tests/CrossLanguageTests.swift.
    ///
    /// THE DEFECT IT CLOSES (shipped 2026-07-30, this port only).
    /// `render_layers_filter_dropdown` collected every item carrying a `label`
    /// and a `value` and never read its declared `type`, so the `All` row — an
    /// ACTION — rendered as a thirteenth checkbox. Clicking it checked the token
    /// `__all__`, which no element answers, so under CHECKED semantics the
    /// hidden set became the whole vocabulary and the tree went blank. JasSwift
    /// dispatched on the declared type from the day both were written, so the
    /// pair written together disagreed within hours: precisely what a shared
    /// vector is for.
    #[test]
    fn layers_filter_menu_matches_the_shared_corpus() {
        use crate::algorithms::layers_filter::{
            checked_after_action, hidden_from_checked, menu_rows, type_filter_keep,
            MenuRowKind,
        };
        use std::collections::HashSet;

        let raw = read_fixture("view_state/layers_type_filter.json");
        let doc: serde_json::Value = serde_json::from_str(&raw)
            .expect("layers_type_filter.json is not valid JSON");
        let menu = &doc["menu"];

        let items = menu["items"].as_array().expect("no `menu.items`");
        // Anti-vacuity declared BY THE DATA, exact rather than slack.
        assert_eq!(
            items.len(),
            menu["min_items"].as_u64().expect("no `min_items`") as usize,
            "walked {} menu item(s) against the declared floor",
            items.len()
        );

        let rows = menu_rows(items);

        // (1) THE PARTITION. An action-typed item is NOT a type toggle, and an
        //     item that declares no type it recognises is neither.
        let got_toggles: Vec<&str> = rows.iter()
            .filter(|r| r.kind == MenuRowKind::Toggle)
            .map(|r| r.value.as_str())
            .collect();
        let want_toggles: Vec<&str> = menu["expected_toggle_values"].as_array()
            .expect("no `expected_toggle_values`")
            .iter().map(|v| v.as_str().expect("toggle value not a string"))
            .collect();
        assert_eq!(got_toggles, want_toggles,
                   "the toggle rows are not the declared toggle rows -- an \
                    action row rendered as a checkbox is the 2026-07-30 defect");

        let got_actions: Vec<(&str, &str, &str)> = rows.iter()
            .filter_map(|r| match &r.kind {
                MenuRowKind::Action(a) => Some((r.label.as_str(), r.value.as_str(), a.as_str())),
                MenuRowKind::Toggle => None,
            })
            .collect();
        let want_actions: Vec<(&str, &str, &str)> = menu["expected_action_rows"].as_array()
            .expect("no `expected_action_rows`")
            .iter()
            .map(|v| (
                v["label"].as_str().expect("action row has no `label`"),
                v["value"].as_str().expect("action row has no `value`"),
                v["action"].as_str().expect("action row has no `action`"),
            ))
            .collect();
        assert_eq!(got_actions, want_actions,
                   "the action rows are not the declared action rows");

        let tree: Vec<(Vec<usize>, String)> = menu["tree"].as_array()
            .expect("no `menu.tree`")
            .iter()
            .map(|r| (
                r["path"].as_array().expect("tree row has no `path`").iter()
                    .map(|n| n.as_u64().expect("path entry not a number") as usize)
                    .collect(),
                r["type"].as_str().expect("tree row has no `type`").to_string(),
            ))
            .collect();
        let keep_of = |hidden: &HashSet<String>| {
            let mut got: Vec<Vec<usize>> = type_filter_keep(
                tree.iter().map(|(p, t)| (p.as_slice(), t.as_str())),
                hidden,
            ).into_iter().collect();
            got.sort();
            got
        };
        let paths_of = |key: &str, v: &serde_json::Value| -> Vec<Vec<usize>> {
            let mut out: Vec<Vec<usize>> = v[key].as_array()
                .unwrap_or_else(|| panic!("no `{key}`"))
                .iter()
                .map(|p| p.as_array().expect("path not an array").iter()
                    .map(|n| n.as_u64().expect("path entry not a number") as usize)
                    .collect())
                .collect();
            out.sort();
            out
        };

        // (2) INVOKING THE ACTION yields the everything-visible state.
        let vectors = menu["action_vectors"].as_array().expect("no `action_vectors`");
        assert_eq!(
            vectors.len(),
            menu["min_action_vectors"].as_u64().expect("no `min_action_vectors`") as usize,
            "walked {} action vector(s) against the declared floor",
            vectors.len()
        );
        for v in vectors {
            let name = v["name"].as_str().unwrap_or("<unnamed>");
            let action = v["action"].as_str().expect("vector has no `action`");
            let before: HashSet<String> = v["checked_before"].as_array()
                .unwrap_or_else(|| panic!("{name}: no `checked_before`"))
                .iter().map(|t| t.as_str().expect("not a string").to_string())
                .collect();

            let got = checked_after_action(action, &before);
            let effective = if v["expected_checked_after"].is_null() {
                assert!(got.is_none(),
                        "vector `{name}`: an action this port does not know must \
                         be REFUSED, not answered with a guess -- got {got:?}");
                before.clone()
            } else {
                let want: HashSet<String> = v["expected_checked_after"].as_array()
                    .expect("`expected_checked_after` is neither null nor an array")
                    .iter().map(|t| t.as_str().expect("not a string").to_string())
                    .collect();
                assert_eq!(got.as_ref(), Some(&want), "vector `{name}`: checked set after");
                want
            };

            let hidden = hidden_from_checked(&effective);
            let mut got_hidden: Vec<String> = hidden.iter().cloned().collect();
            got_hidden.sort();
            let mut want_hidden: Vec<String> = v["expected_hidden_after"].as_array()
                .unwrap_or_else(|| panic!("{name}: no `expected_hidden_after`"))
                .iter().map(|t| t.as_str().expect("not a string").to_string())
                .collect();
            want_hidden.sort();
            assert_eq!(got_hidden, want_hidden, "vector `{name}`: hidden set after");

            assert_eq!(keep_of(&hidden), paths_of("expected_keep_after", v),
                       "vector `{name}`: the tree after the click");
        }

        // (3) THE REGRESSION ITSELF, as the blank tree it produced.
        let d = &menu["defect_if_the_action_row_were_a_toggle"];
        let checked: HashSet<String> = d["checked"].as_array()
            .expect("no `defect...checked`")
            .iter().map(|t| t.as_str().expect("not a string").to_string())
            .collect();
        let hidden = hidden_from_checked(&checked);
        assert_eq!(
            hidden.len(),
            d["expected_hidden_count"].as_u64().expect("no `expected_hidden_count`") as usize,
            "checking a token no element answers must hide the WHOLE vocabulary"
        );
        assert_eq!(keep_of(&hidden), paths_of("expected_keep", d),
                   "the defect's blank tree is not what the fixture records");
    }
}
