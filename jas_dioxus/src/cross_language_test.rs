//! Cross-language equivalence tests.
//!
//! These tests read shared SVG fixtures from `test_fixtures/` at the
//! repository root, parse them, serialize to canonical test JSON, and
//! compare against the expected JSON files.  All four language
//! implementations run the same fixtures, so passing here means the Rust
//! implementation agrees with the canonical expected values.

#[cfg(test)]
mod tests {
    use crate::geometry::svg::svg_to_document;
    use crate::geometry::test_json::document_to_test_json;

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
}
