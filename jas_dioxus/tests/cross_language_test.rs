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
