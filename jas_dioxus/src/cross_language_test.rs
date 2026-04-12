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
    use crate::document::model::Model;
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

    #[test]
    fn svg_roundtrip_all_fixtures() {
        let names = [
            "line_basic", "rect_basic", "rect_with_stroke",
            "circle_basic", "ellipse_basic",
            "polyline_basic", "polygon_basic", "path_all_commands",
            "text_basic", "text_path_basic",
            "group_nested", "transform_translate", "transform_rotate",
            "multi_layer", "complex_document",
        ];
        for name in &names {
            assert_svg_roundtrip(name);
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
                         "operations/controller_ops.json"] {
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

    // ---------------------------------------------------------------
    // Workspace layout equivalence tests
    // ---------------------------------------------------------------

    use crate::workspace::test_json::{
        workspace_to_test_json, test_json_to_workspace,
        toolbar_structure_json, menu_structure_json,
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

    use crate::workspace::workspace::{
        DockId, GroupAddr, PanelAddr, PanelKind, PaneId, PaneKind,
    };

    fn parse_panel_kind(s: &str) -> PanelKind {
        match s {
            "color" => PanelKind::Color,
            "stroke" => PanelKind::Stroke,
            "properties" => PanelKind::Properties,
            _ => PanelKind::Layers,
        }
    }

    fn parse_pane_kind(s: &str) -> PaneKind {
        match s {
            "toolbar" => PaneKind::Toolbar,
            "dock" => PaneKind::Dock,
            _ => PaneKind::Canvas,
        }
    }

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

    fn run_workspace_operation_test(tc: &serde_json::Value) -> String {
        let setup_name = tc["setup"].as_str().unwrap();
        let setup_json = read_fixture(&format!("expected/{}", setup_name));
        let mut layout = test_json_to_workspace(setup_json.trim());

        for op in tc["ops"].as_array().unwrap() {
            apply_workspace_op(&mut layout, op);
        }

        workspace_to_test_json(&layout)
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
    // Toolbar and menu structure tests
    // ---------------------------------------------------------------

    #[test]
    fn toolbar_structure() {
        let json = toolbar_structure_json();
        assert_workspace_fixture("toolbar_structure", &json);
    }

    #[test]
    fn menu_structure() {
        let json = menu_structure_json();
        assert_workspace_fixture("menu_structure", &json);
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
}
