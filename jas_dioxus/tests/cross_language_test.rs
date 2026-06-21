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

// --- Generated concept-instance JSON roundtrip (cross-language golden) ---
//
// expected/generated_polygon.json is a Document with one Generated LiveVariant.
// Every app that supports the `generated` kind parses it, re-emits, and must
// reproduce it byte-identically (CONCEPTS.md 3b). Authored from the Rust emit;
// Swift/OCaml/Python pin the same golden.
#[test]
fn json_roundtrip_generated_polygon() {
    let golden = read_fixture("expected/generated_polygon.json");
    let doc = test_json_to_document(&golden);
    assert_eq!(document_to_test_json(&doc), golden,
        "generated_polygon JSON roundtrip mismatch");
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
            fill_gradient: None,
            stroke_gradient: None,
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

// --- Expression-language conformance (shared corpus) ---
//
// Loads the compiled corpus from test_fixtures/expressions/conformance.json
// (generated from workspace/tests/expressions.yaml — the same corpus the Python
// conformance test reads) and asserts this app's evaluator produces the expected
// result type and value for every case. Pins cross-language expression
// equivalence, including the closure lexical-scoping contract.

#[test]
fn expression_conformance() {
    use jas_dioxus::interpreter::expr;
    use jas_dioxus::interpreter::expr_types::Value;

    let raw = read_fixture("expressions/conformance.json");
    let cases: serde_json::Value =
        serde_json::from_str(&raw).expect("conformance.json parses as JSON");
    let cases = cases.as_array().expect("corpus is a JSON array");

    let mut failures = Vec::new();
    for case in cases {
        let src = case["expr"].as_str().expect("expr is a string");
        // Build the eval context from the optional state/data namespaces.
        let mut ctx = serde_json::Map::new();
        if let Some(s) = case.get("state") {
            ctx.insert("state".to_string(), s.clone());
        }
        if let Some(d) = case.get("data") {
            ctx.insert("data".to_string(), d.clone());
        }
        let ctx = serde_json::Value::Object(ctx);

        let result = expr::eval(src, &ctx);
        let ty = case["type"].as_str().expect("type is a string");
        let expected = &case["expected"];

        let ok = match ty {
            "null" => matches!(&result, Value::Null),
            "bool" => matches!(&result, Value::Bool(b) if *b == expected.as_bool().unwrap()),
            "number" => match &result {
                Value::Number(n) => (n - expected.as_f64().unwrap()).abs() < 1e-9,
                _ => false,
            },
            "string" => matches!(&result, Value::Str(s) if s == expected.as_str().unwrap()),
            "color" => matches!(&result, Value::Color(c) if c == expected.as_str().unwrap()),
            "list" => matches!(&result, Value::List(_)),
            other => panic!("unknown expected type {other:?} for expr {src:?}"),
        };
        if !ok {
            failures.push(format!(
                "  {src:?} -> expected {ty} {expected}, got {result:?}"
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "expression conformance failures ({} of {}):\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n"),
    );
}

// --- Concept-generator conformance (shared corpus) ---
//
// Loads test_fixtures/concepts/conformance.json (compiled from
// workspace/concepts/*.yaml + workspace/tests/concepts.yaml). For each case,
// evaluates the concept's generator expression with its parameters bound under
// `param` and asserts the resulting list of [x,y] points matches the expected
// geometry (component-wise, 1e-9). A concept generator is just an expression, so
// this reuses the evaluator — pinning concept geometry across all apps. See
// CONCEPTS.md.

#[test]
fn concept_conformance() {
    use jas_dioxus::interpreter::expr;
    use jas_dioxus::interpreter::expr_types::Value;

    let raw = read_fixture("concepts/conformance.json");
    let cases: serde_json::Value =
        serde_json::from_str(&raw).expect("conformance.json parses as JSON");
    let cases = cases.as_array().expect("corpus is a JSON array");

    let mut failures = Vec::new();
    for case in cases {
        let concept = case["concept"].as_str().unwrap_or("?");
        let generator = case["generator"].as_str().expect("generator is a string");
        // Bind the parameters under the `param` namespace.
        let mut ctx = serde_json::Map::new();
        ctx.insert("param".to_string(), case["params"].clone());
        let ctx = serde_json::Value::Object(ctx);

        let result = expr::eval(generator, &ctx);
        let pts = match &result {
            Value::List(items) => items,
            other => {
                failures.push(format!("{concept}: generator returned non-list {other:?}"));
                continue;
            }
        };
        let expected = case["expected"].as_array().expect("expected is an array");
        if pts.len() != expected.len() {
            failures.push(format!(
                "{concept}: point count — expected {}, got {}",
                expected.len(),
                pts.len()
            ));
            continue;
        }
        for (i, (p, e)) in pts.iter().zip(expected.iter()).enumerate() {
            let pa = p.as_array().filter(|a| a.len() == 2);
            let (px, py) = match pa {
                Some(a) => (a[0].as_f64().unwrap_or(f64::NAN), a[1].as_f64().unwrap_or(f64::NAN)),
                None => {
                    failures.push(format!("{concept} point {i}: not a 2-element list: {p}"));
                    continue;
                }
            };
            let ea = e.as_array().unwrap();
            let (ex, ey) = (ea[0].as_f64().unwrap(), ea[1].as_f64().unwrap());
            if (px - ex).abs() >= 1e-9 || (py - ey).abs() >= 1e-9 {
                failures.push(format!(
                    "{concept} point {i}: expected ({ex}, {ey}), got ({px}, {py})"
                ));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "concept conformance failures:\n{}",
        failures.join("\n"),
    );
}

// --- Concept-operation conformance (shared corpus) ---
//
// Loads test_fixtures/concept_operations/conformance.json (compiled from
// workspace/concepts/*.yaml + workspace/tests/concept_operations.yaml). For each
// case, evaluates the operation's `set:` expressions with the case's params bound
// under `param` and asserts the resolved value of each changed param matches the
// expected change (1e-9). An operation's effect is just expression evaluation, so
// this reuses the evaluator — pinning concept-operation RESOLUTION across all
// apps (CONCEPTS.md §9). The production handler bakes exactly these resolved
// `changes` into the op (value-in-op), so the gate also pins what gets journaled.

#[test]
fn operations_conformance() {
    use jas_dioxus::interpreter::expr;
    use jas_dioxus::interpreter::expr_types::Value;

    let raw = read_fixture("concept_operations/conformance.json");
    let cases: serde_json::Value =
        serde_json::from_str(&raw).expect("conformance.json parses as JSON");
    let cases = cases.as_array().expect("corpus is a JSON array");

    let mut failures = Vec::new();
    for case in cases {
        let concept = case["concept"].as_str().unwrap_or("?");
        let op = case["op"].as_str().unwrap_or("?");
        // Bind the current params under the `param` namespace (the generator's
        // namespace), exactly as the production handler does at resolve time.
        let mut ctx = serde_json::Map::new();
        ctx.insert("param".to_string(), case["params"].clone());
        let ctx = serde_json::Value::Object(ctx);

        let set = case["set"].as_object().expect("set is an object");
        let expected = case["expected"].as_object().expect("expected is an object");
        for (name, expr_src) in set {
            let src = expr_src.as_str().expect("set expr is a string");
            let result = expr::eval(src, &ctx);
            let got = match &result {
                Value::Number(n) => *n,
                other => {
                    failures.push(format!(
                        "{concept}/{op} param {name}: non-numeric result {other:?}"
                    ));
                    continue;
                }
            };
            let want = expected
                .get(name)
                .and_then(|v| v.as_f64())
                .unwrap_or_else(|| panic!("{concept}/{op}: expected has no {name}"));
            if (got - want).abs() >= 1e-9 {
                failures.push(format!(
                    "{concept}/{op} param {name}: expected {want}, got {got}"
                ));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "concept-operation conformance failures:\n{}",
        failures.join("\n"),
    );
}

// --- Concept-fitter conformance (shared corpus) ---
//
// Loads test_fixtures/concept_fitters/conformance.json (compiled from
// workspace/concepts/*.yaml + workspace/tests/concept_fitters.yaml). For each
// case, evaluates the concept's `fitter` expression with the case's points bound
// under `shape.points` and asserts the result matches `expected` — `null` for no
// match, else the flat `[params..., cx, cy, rotation]` list (1e-9). A fitter is
// the dual of the generator and just an expression, so this reuses the evaluator
// — pinning concept DETECTION across all apps (CONCEPTS.md §10). The production
// promote handler runs exactly this and bakes the recovered values into the op.

#[test]
fn fitters_conformance() {
    use jas_dioxus::interpreter::expr;
    use jas_dioxus::interpreter::expr_types::Value;

    let raw = read_fixture("concept_fitters/conformance.json");
    let cases: serde_json::Value =
        serde_json::from_str(&raw).expect("conformance.json parses as JSON");
    let cases = cases.as_array().expect("corpus is a JSON array");

    let mut failures = Vec::new();
    for case in cases {
        let concept = case["concept"].as_str().unwrap_or("?");
        let fitter = case["fitter"].as_str().expect("fitter is a string");
        // Bind the input vertices under `shape.points`, exactly as the production
        // promote handler does at detect time.
        let mut shape = serde_json::Map::new();
        shape.insert("points".to_string(), case["points"].clone());
        let mut ctx = serde_json::Map::new();
        ctx.insert("shape".to_string(), serde_json::Value::Object(shape));
        let ctx = serde_json::Value::Object(ctx);

        let result = expr::eval(fitter, &ctx);
        let expected = &case["expected"];

        if expected.is_null() {
            if !matches!(result, Value::Null) {
                failures.push(format!("{concept}: expected no match (null), got {result:?}"));
            }
            continue;
        }
        let exp = expected.as_array().expect("expected is an array");
        let got = match &result {
            Value::List(items) => items,
            other => {
                failures.push(format!("{concept}: expected {exp:?}, got non-list {other:?}"));
                continue;
            }
        };
        if got.len() != exp.len() {
            failures.push(format!(
                "{concept}: result arity {} != expected {}",
                got.len(),
                exp.len()
            ));
            continue;
        }
        for (i, (g, e)) in got.iter().zip(exp.iter()).enumerate() {
            let gv = match g.as_f64() {
                Some(n) => n,
                None => {
                    failures.push(format!("{concept} output[{i}]: non-numeric {g:?}"));
                    continue;
                }
            };
            let ev = e.as_f64().unwrap();
            if (gv - ev).abs() >= 1e-9 {
                failures.push(format!("{concept} output[{i}]: expected {ev}, got {gv}"));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "concept-fitter conformance failures:\n{}",
        failures.join("\n"),
    );
}

// --- Concept-constraint conformance (shared corpus) ---
//
// Loads test_fixtures/concept_constraints/conformance.json (compiled from
// workspace/concepts/*.yaml + workspace/tests/concept_constraints.yaml). For each
// case, evaluates each constraint's `check` expression with the case's params
// bound under `param` and collects the constraints whose result is NOT truthy
// (`Value::to_bool`, the same truthiness `if` uses) — the violations, in declared
// order — then asserts they match `expected`. A constraint is just a boolean
// expression, so this reuses the evaluator — pinning concept CHECKING across all
// apps (CONCEPTS.md §11). Checking is advisory + read-only (no op-log verb).

#[test]
fn constraints_conformance() {
    use jas_dioxus::interpreter::expr;

    let raw = read_fixture("concept_constraints/conformance.json");
    let cases: serde_json::Value =
        serde_json::from_str(&raw).expect("conformance.json parses as JSON");
    let cases = cases.as_array().expect("corpus is a JSON array");

    let mut failures = Vec::new();
    for case in cases {
        let concept = case["concept"].as_str().unwrap_or("?");
        let mut ctx = serde_json::Map::new();
        ctx.insert("param".to_string(), case["params"].clone());
        let ctx = serde_json::Value::Object(ctx);

        let constraints = case["constraints"].as_array().expect("constraints array");
        let violated: Vec<String> = constraints
            .iter()
            .filter(|c| {
                let check = c["check"].as_str().expect("check is a string");
                !expr::eval(check, &ctx).to_bool()
            })
            .map(|c| c["id"].as_str().unwrap_or("?").to_string())
            .collect();
        let expected: Vec<String> = case["expected"]
            .as_array()
            .expect("expected array")
            .iter()
            .map(|v| v.as_str().unwrap_or("?").to_string())
            .collect();
        if violated != expected {
            failures.push(format!(
                "{concept}: expected violations {expected:?}, got {violated:?}"
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "concept-constraint conformance failures:\n{}",
        failures.join("\n"),
    );
}
