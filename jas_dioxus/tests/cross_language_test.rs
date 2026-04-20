//! Cross-language equivalence tests.
//!
//! Reads shared SVG fixtures from test_fixtures/ at the repository root,
//! parses them, serializes to canonical test JSON, and compares against
//! the expected JSON files.

use jas_dioxus::geometry::svg::{document_to_svg, svg_to_document};
use jas_dioxus::geometry::test_json::{document_to_test_json, test_json_to_document};

use std::path::PathBuf;

fn fixtures_dir() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../test_fixtures");
    p
}

fn read_fixture(path: &str) -> String {
    let full = fixtures_dir().join(path);
    std::fs::read_to_string(&full)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", full.display(), e))
        .trim()
        .to_string()
}

fn assert_svg_parse(name: &str) {
    let svg = read_fixture(&format!("svg/{name}.svg"));
    let expected = read_fixture(&format!("expected/{name}.json"));
    let doc = svg_to_document(&svg);
    let actual = document_to_test_json(&doc);
    assert_eq!(actual, expected, "SVG parse mismatch for {name}");
}

fn assert_svg_roundtrip(name: &str) {
    let svg = read_fixture(&format!("svg/{name}.svg"));
    let doc = svg_to_document(&svg);
    let json1 = document_to_test_json(&doc);
    let svg2 = document_to_svg(&doc);
    let doc2 = svg_to_document(&svg2);
    let json2 = document_to_test_json(&doc2);
    assert_eq!(json1, json2, "SVG roundtrip mismatch for {name}");
}

// --- Parse equivalence tests ---

#[test] fn parse_line_basic() { assert_svg_parse("line_basic"); }
#[test] fn parse_rect_basic() { assert_svg_parse("rect_basic"); }
#[test] fn parse_rect_with_stroke() { assert_svg_parse("rect_with_stroke"); }
#[test] fn parse_circle_basic() { assert_svg_parse("circle_basic"); }
#[test] fn parse_ellipse_basic() { assert_svg_parse("ellipse_basic"); }
#[test] fn parse_polyline_basic() { assert_svg_parse("polyline_basic"); }
#[test] fn parse_polygon_basic() { assert_svg_parse("polygon_basic"); }
#[test] fn parse_path_all_commands() { assert_svg_parse("path_all_commands"); }
#[test] fn parse_text_basic() { assert_svg_parse("text_basic"); }
#[test] fn parse_text_path_basic() { assert_svg_parse("text_path_basic"); }
#[test] fn parse_group_nested() { assert_svg_parse("group_nested"); }
#[test] fn parse_transform_translate() { assert_svg_parse("transform_translate"); }
#[test] fn parse_transform_rotate() { assert_svg_parse("transform_rotate"); }
#[test] fn parse_multi_layer() { assert_svg_parse("multi_layer"); }
#[test] fn parse_complex_document() { assert_svg_parse("complex_document"); }

// --- SVG roundtrip tests ---

#[test] fn roundtrip_line_basic() { assert_svg_roundtrip("line_basic"); }
#[test] fn roundtrip_rect_basic() { assert_svg_roundtrip("rect_basic"); }
#[test] fn roundtrip_circle_basic() { assert_svg_roundtrip("circle_basic"); }
#[test] fn roundtrip_ellipse_basic() { assert_svg_roundtrip("ellipse_basic"); }
#[test] fn roundtrip_polyline_basic() { assert_svg_roundtrip("polyline_basic"); }
#[test] fn roundtrip_polygon_basic() { assert_svg_roundtrip("polygon_basic"); }
#[test] fn roundtrip_path_all_commands() { assert_svg_roundtrip("path_all_commands"); }
#[test] fn roundtrip_group_nested() { assert_svg_roundtrip("group_nested"); }
#[test] fn roundtrip_transform_translate() { assert_svg_roundtrip("transform_translate"); }
#[test] fn roundtrip_transform_rotate() { assert_svg_roundtrip("transform_rotate"); }
#[test] fn roundtrip_multi_layer() { assert_svg_roundtrip("multi_layer"); }
#[test] fn roundtrip_complex_document() { assert_svg_roundtrip("complex_document"); }

// --- JSON roundtrip test ---

#[test]
fn json_roundtrip_all_fixtures() {
    let svg_dir = fixtures_dir().join("svg");
    for entry in std::fs::read_dir(&svg_dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().map_or(false, |e| e == "svg") {
            let name = path.file_stem().unwrap().to_str().unwrap();
            let svg = std::fs::read_to_string(&path).unwrap();
            let doc = svg_to_document(&svg);
            let json1 = document_to_test_json(&doc);
            let doc2 = test_json_to_document(&json1);
            let json2 = document_to_test_json(&doc2);
            assert_eq!(json1, json2, "JSON roundtrip mismatch for {name}");
        }
    }
}

// --- Align panel parity fixture ---
//
// Runs each vector in test_fixtures/algorithms/align.json through
// the Rust algorithms module and compares the translation output
// to the expected field. Swift / OCaml / Python ports will consume
// the same fixture via their own algorithm_roundtrip binaries.

#[test]
fn align_fixture_matches_expected() {
    use jas_dioxus::algorithms::align as aa;
    use jas_dioxus::geometry::element::{
        Bounds, Color, CommonProps, Element, Fill, RectElem,
    };

    let raw = read_fixture("algorithms/align.json");
    let fixture: serde_json::Value = serde_json::from_str(&raw)
        .expect("align.json parses as JSON");
    let vectors = fixture["vectors"].as_array().expect("vectors array");

    fn make_rect(b: Bounds) -> Element {
        Element::Rect(RectElem {
            x: b.0, y: b.1, width: b.2, height: b.3, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
        })
    }
    fn to_bounds(arr: &serde_json::Value) -> Bounds {
        let a = arr.as_array().unwrap();
        (
            a[0].as_f64().unwrap(), a[1].as_f64().unwrap(),
            a[2].as_f64().unwrap(), a[3].as_f64().unwrap(),
        )
    }

    for v in vectors {
        let name = v["name"].as_str().unwrap_or("<unnamed>");
        let op = v["op"].as_str().unwrap_or("");
        let rects: Vec<Element> = v["rects"].as_array().unwrap()
            .iter().map(|r| make_rect(to_bounds(r))).collect();
        let pairs: Vec<(Vec<usize>, &Element)> = rects.iter().enumerate()
            .map(|(i, e)| (vec![i], e)).collect();

        let bounds_fn: aa::BoundsFn = if v["use_preview_bounds"].as_bool().unwrap_or(false) {
            aa::preview_bounds
        } else {
            aa::geometric_bounds
        };
        let reference = {
            let r = &v["reference"];
            match r["kind"].as_str().unwrap_or("selection") {
                "selection" => {
                    let refs: Vec<&Element> = rects.iter().collect();
                    aa::AlignReference::Selection(aa::union_bounds(&refs, bounds_fn))
                }
                "artboard" => aa::AlignReference::Artboard(to_bounds(&r["bbox"])),
                "key_object" => {
                    let idx = r["index"].as_u64().unwrap() as usize;
                    aa::AlignReference::KeyObject {
                        bbox: bounds_fn(&rects[idx]),
                        path: vec![idx],
                    }
                }
                other => panic!("unknown reference kind: {other}"),
            }
        };
        let explicit_gap = v["explicit_gap"].as_f64();

        let actual = match op {
            "align_left" => aa::align_left(&pairs, &reference, bounds_fn),
            "align_horizontal_center" => aa::align_horizontal_center(&pairs, &reference, bounds_fn),
            "align_right" => aa::align_right(&pairs, &reference, bounds_fn),
            "align_top" => aa::align_top(&pairs, &reference, bounds_fn),
            "align_vertical_center" => aa::align_vertical_center(&pairs, &reference, bounds_fn),
            "align_bottom" => aa::align_bottom(&pairs, &reference, bounds_fn),
            "distribute_left" => aa::distribute_left(&pairs, &reference, bounds_fn),
            "distribute_horizontal_center" => aa::distribute_horizontal_center(&pairs, &reference, bounds_fn),
            "distribute_right" => aa::distribute_right(&pairs, &reference, bounds_fn),
            "distribute_top" => aa::distribute_top(&pairs, &reference, bounds_fn),
            "distribute_vertical_center" => aa::distribute_vertical_center(&pairs, &reference, bounds_fn),
            "distribute_bottom" => aa::distribute_bottom(&pairs, &reference, bounds_fn),
            "distribute_vertical_spacing" => aa::distribute_vertical_spacing(&pairs, &reference, explicit_gap, bounds_fn),
            "distribute_horizontal_spacing" => aa::distribute_horizontal_spacing(&pairs, &reference, explicit_gap, bounds_fn),
            other => panic!("unknown op: {other}"),
        };

        let expected_arr = v["translations"].as_array().unwrap();
        assert_eq!(
            actual.len(),
            expected_arr.len(),
            "vector {name}: translation count mismatch — got {:?}",
            actual,
        );
        for (act, exp) in actual.iter().zip(expected_arr.iter()) {
            let exp_path: Vec<usize> = exp["path"].as_array().unwrap()
                .iter().map(|v| v.as_u64().unwrap() as usize).collect();
            assert_eq!(act.path, exp_path, "vector {name}: path mismatch");
            assert!(
                (act.dx - exp["dx"].as_f64().unwrap()).abs() < 1e-4,
                "vector {name}: dx mismatch on path {:?}: got {} want {}",
                act.path, act.dx, exp["dx"].as_f64().unwrap(),
            );
            assert!(
                (act.dy - exp["dy"].as_f64().unwrap()).abs() < 1e-4,
                "vector {name}: dy mismatch on path {:?}: got {} want {}",
                act.path, act.dy, exp["dy"].as_f64().unwrap(),
            );
        }
    }
}
