/// CLI tool for cross-language algorithm testing.
///
/// Usage:
///   algorithm_roundtrip <algorithm> <fixture.json>
///
/// Reads the fixture file, runs each test vector through the specified
/// algorithm, and outputs a JSON array of results to stdout.

use jas_dioxus::geometry::measure::{Measure, parse_unit};
use jas_dioxus::geometry::test_json::{parse_element, parse_transform};
use jas_dioxus::document::document::Document;
use jas_dioxus::document::evaluated_bounds::element_evaluated_bbox;
use jas_dioxus::geometry::element::{CommonProps, LayerElem};
use jas_dioxus::algorithms::boolean::{
    boolean_exclude_ruled, boolean_intersect_ruled, boolean_subtract_ruled,
    boolean_union_ruled, PolyFillRule, PolygonSet, RuledPolygonSet,
};
use jas_dioxus::algorithms::boolean_normalize::normalize;
use jas_dioxus::algorithms::corpus_text_measure::fixed_char_width_measure;
use jas_dioxus::algorithms::fit_curve::fit_curve;
use jas_dioxus::algorithms::hit_test;
use jas_dioxus::algorithms::path_text_layout::layout_path_text;
use jas_dioxus::algorithms::planar::{FaceId, PlanarGraph};
use jas_dioxus::algorithms::shape_recognize::{recognize, RecognizeConfig, RecognizedShape};
use jas_dioxus::algorithms::text_layout;
use jas_dioxus::geometry::element::{PathCommand, Element, flatten_path_commands};
use jas_dioxus::interpreter::length;

use serde_json::{json, Value};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("Usage: {} <algorithm> <fixture.json>", args[0]);
        std::process::exit(1);
    }

    let algo = &args[1];
    let path = &args[2];

    let json_str = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("Failed to read {}: {}", path, e);
        std::process::exit(1);
    });

    let fixture: Value = serde_json::from_str(&json_str).unwrap_or_else(|e| {
        eprintln!("Failed to parse JSON: {}", e);
        std::process::exit(1);
    });

    // Support both formats: flat array (legacy hit_test.json) and envelope
    let vectors = if fixture.is_array() {
        fixture.as_array().unwrap().clone()
    } else {
        fixture["vectors"]
            .as_array()
            .unwrap_or_else(|| {
                eprintln!("Expected 'vectors' array in fixture");
                std::process::exit(1);
            })
            .clone()
    };

    // Filter out skipped vectors
    let vectors: Vec<Value> = vectors
        .into_iter()
        .filter(|v| !v.get("_skip").and_then(|s| s.as_bool()).unwrap_or(false))
        .collect();

    let results: Vec<Value> = match algo.as_str() {
        "measure" => run_measure(&vectors),
        "element_bounds" => run_element_bounds(&vectors),
        "element_evaluated_bounds" => run_element_evaluated_bounds(&vectors),
        "flatten" => run_flatten(&vectors),
        "arrow_trim" => run_arrow_trim(&vectors),
        "length" => run_length(&vectors),
        "color_convert" => run_color_convert(&vectors),
        "number_commit" => run_number_commit(&vectors),
        "hit_test" => run_hit_test(&vectors),
        "path_project" => run_path_project(&vectors),
        "boolean" => run_boolean(&vectors),
        "boolean_normalize" => run_boolean_normalize(&vectors),
        "polygon_metrics" => run_polygon_metrics(&vectors),
        "fit_curve" => run_fit_curve(&vectors),
        "shape_recognize" => run_shape_recognize(&vectors),
        "planar" => run_planar(&vectors),
        "text_layout" => run_text_layout(&vectors),
        "text_layout_paragraph" => run_text_layout_paragraph(&vectors),
        "path_text_layout" => run_path_text_layout(&vectors),
        "align" => run_align(&vectors),
        _ => {
            eprintln!("Unknown algorithm: {}", algo);
            std::process::exit(1);
        }
    };

    print!(
        "{}",
        serde_json::to_string(&results).expect("Failed to serialize results")
    );
}

// ---------------------------------------------------------------
// path_project (closest-point projection onto a segment / cubic)
// ---------------------------------------------------------------
//
// The distance is reported DIVIDED BY the vector's `scale`, because the
// family's reason to exist is coordinates above ~1e154 — the magnitudes at
// which the naive `(dx*dx + dy*dy).sqrt()` saturates to +inf while `hypot`
// does not. An absolute tolerance is meaningless against a raw 1e200
// distance (one ulp there is ~1.6e184), so every vector declares the scale
// its distance is measured in and the comparison happens on the ratio.
// `scale` is 1.0 for the ordinary-magnitude vectors.

fn run_path_project(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::geometry::path_ops::{closest_on_cubic, closest_on_line};
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let func = tc["function"].as_str().unwrap_or("");
            let a: Vec<f64> = tc["args"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_f64().unwrap())
                .collect();
            let scale = tc["scale"].as_f64().unwrap_or(1.0);
            let (dist, t) = match func {
                "closest_on_line" => closest_on_line(a[0], a[1], a[2], a[3], a[4], a[5]),
                "closest_on_cubic" => closest_on_cubic(
                    a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9],
                ),
                _ => {
                    eprintln!("Unknown path_project function: {}", func);
                    std::process::exit(1);
                }
            };
            json!({"name": name,
                   "result": {"distance_over_scale": dist / scale, "t": t}})
        })
        .collect()
}

// ---------------------------------------------------------------
// number_commit (the number_input widget's commit rule)
// ---------------------------------------------------------------

fn run_number_commit(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::interpreter::widget_commit::number_input_commit;
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let text = tc["text"].as_str().unwrap_or("");
            let min = tc.get("min").and_then(|v| v.as_f64());
            let max = tc.get("max").and_then(|v| v.as_f64());
            json!({"name": name, "result": number_input_commit(text, min, max)})
        })
        .collect()
}

// ---------------------------------------------------------------
// measure (unit conversion)
// ---------------------------------------------------------------

fn run_measure(vectors: &[Value]) -> Vec<Value> {
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let unit_str = tc["unit"].as_str().unwrap();
            let value = tc["value"].as_f64().unwrap();
            let font_size = tc.get("font_size").and_then(|v| v.as_f64()).unwrap_or(16.0);
            let unit = parse_unit(unit_str).unwrap_or_else(|| {
                eprintln!("Unknown unit: {}", unit_str);
                std::process::exit(1);
            });
            let m = Measure::new(value, unit);
            json!({"name": name, "result": m.to_px(font_size)})
        })
        .collect()
}

// ---------------------------------------------------------------
// element_bounds
// ---------------------------------------------------------------

fn run_element_bounds(vectors: &[Value]) -> Vec<Value> {
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let elem_json = &tc["element"];
            let elem = parse_element(elem_json);
            let (x, y, w, h) = elem.bounds();
            json!({"name": name, "result": [x, y, w, h]})
        })
        .collect()
}

// ---------------------------------------------------------------
// element_evaluated_bounds (transform-aware bbox, DOCUMENT space)
// ---------------------------------------------------------------

/// Each vector is one element placed as the single child of one layer, so the
/// gated path is `[0, 0]`: the element's own `transform` is folded first, then
/// the layer's `layer_transform` as the sole ancestor. Building the document
/// here (rather than shipping a whole document per vector) keeps the fixture
/// readable; the geometry under test is entirely inside the port function.
fn run_element_evaluated_bounds(vectors: &[Value]) -> Vec<Value> {
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let elem = parse_element(&tc["element"]);
            let layer_transform = parse_transform(&tc["layer_transform"]);
            let mut doc = Document::default();
            doc.layers = vec![Element::Layer(LayerElem {
                children: vec![std::rc::Rc::new(elem)],
                common: CommonProps {
                    transform: layer_transform,
                    ..Default::default()
                },
                isolated_blending: false,
                knockout_group: false,
            })];
            let result = match element_evaluated_bbox(&doc, &[0, 0]) {
                Some((x, y, w, h)) => json!([x, y, w, h]),
                None => Value::Null,
            };
            json!({"name": name, "result": result})
        })
        .collect()
}

// ---------------------------------------------------------------
// flatten (path commands -> polyline; exercises multi-subpath close)
// ---------------------------------------------------------------

fn run_flatten(vectors: &[Value]) -> Vec<Value> {
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let elem = parse_element(&tc["element"]);
            let d = match &elem {
                Element::Path(e) => e.d.clone(),
                _ => Vec::new(),
            };
            let pts = flatten_path_commands(&d);
            let result: Vec<Value> = pts.iter().map(|(x, y)| json!([x, y])).collect();
            json!({"name": name, "result": result})
        })
        .collect()
}

// ---------------------------------------------------------------
// arrow_trim (arc-length trim of an arrowheaded stroke path)
// ---------------------------------------------------------------

fn cmd_to_json(cmd: &PathCommand) -> Value {
    match *cmd {
        PathCommand::MoveTo { x, y } => json!({"cmd": "M", "x": x, "y": y}),
        PathCommand::LineTo { x, y } => json!({"cmd": "L", "x": x, "y": y}),
        PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
            json!({"cmd": "C", "x1": x1, "y1": y1, "x2": x2, "y2": y2, "x": x, "y": y})
        }
        PathCommand::QuadTo { x1, y1, x, y } => {
            json!({"cmd": "Q", "x1": x1, "y1": y1, "x": x, "y": y})
        }
        PathCommand::ClosePath => json!({"cmd": "Z"}),
        _ => json!({"cmd": "?"}),
    }
}

fn run_arrow_trim(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::algorithms::arrow_trim::{head_angles, trim_path};
    const EPS: f64 = 1e-9;
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let elem = parse_element(&tc["element"]);
            let d = match &elem {
                Element::Path(e) => e.d.clone(),
                _ => Vec::new(),
            };
            let start_sb = tc["start_setback"].as_f64().unwrap_or(0.0);
            let end_sb = tc["end_setback"].as_f64().unwrap_or(0.0);
            // Orientation vectors pin the trim-chord head angles (ARROWFIX2
            // item 1); a head reports its angle only when armed (setback > 0).
            if tc["orient"].as_bool().unwrap_or(false) {
                let (start_angle, end_angle) = head_angles(&d, start_sb, end_sb);
                let start = if start_sb > EPS { json!(start_angle) } else { Value::Null };
                let end = if end_sb > EPS { json!(end_angle) } else { Value::Null };
                return json!({"name": name, "result": {"start": start, "end": end}});
            }
            let trimmed = trim_path(&d, start_sb, end_sb);
            let result: Vec<Value> = trimmed.iter().map(cmd_to_json).collect();
            json!({"name": name, "result": result})
        })
        .collect()
}

// ---------------------------------------------------------------
// length (unit-aware parse "12 px" -> pt, and format pt -> "16 px")
// ---------------------------------------------------------------

fn run_length(vectors: &[Value]) -> Vec<Value> {
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let result: Value = if tc["function"].as_str() == Some("parse") {
                let input = tc["input"].as_str().unwrap_or("");
                let du = tc["default_unit"].as_str().unwrap_or("");
                match length::parse(input, du) {
                    Some(v) => json!(v),
                    None => Value::Null,
                }
            } else {
                let pt = tc.get("pt").and_then(|v| v.as_f64());
                let unit = tc["unit"].as_str().unwrap_or("");
                let precision = tc["precision"].as_u64().unwrap_or(2) as usize;
                json!(length::format(pt, unit, precision))
            };
            json!({"name": name, "result": result})
        })
        .collect()
}

// ---------------------------------------------------------------
// color_convert (the Color panel's four conversion primitives)
// ---------------------------------------------------------------

fn run_color_convert(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::interpreter::color_util as cu;
    let ints = |v: &Value| -> Vec<i64> {
        v.as_array().unwrap().iter().map(|x| x.as_i64().unwrap()).collect()
    };
    let floats = |v: &Value| -> Vec<f64> {
        v.as_array().unwrap().iter().map(|x| x.as_f64().unwrap()).collect()
    };
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let result: Value = match tc["function"].as_str().unwrap_or("") {
                "rgb_to_hsb" => {
                    let a = ints(&tc["rgb"]);
                    let (h, s, b) = cu::rgb_to_hsb(a[0] as u8, a[1] as u8, a[2] as u8);
                    json!([h, s, b])
                }
                "hsb_to_rgb" => {
                    let a = floats(&tc["hsb"]);
                    let (r, g, b) = cu::hsb_to_rgb(a[0], a[1], a[2]);
                    json!([r as i64, g as i64, b as i64])
                }
                "rgb_to_cmyk" => {
                    let a = ints(&tc["rgb"]);
                    let (c, m, y, k) = cu::rgb_to_cmyk(a[0] as u8, a[1] as u8, a[2] as u8);
                    json!([c, m, y, k])
                }
                "panel_channels" => {
                    let a = floats(&tc["float_rgb"]);
                    let ch = cu::panel_channels(a[0], a[1], a[2]);
                    json!({
                        "r": ch.r, "g": ch.g, "bl": ch.bl,
                        "h": ch.h, "s": ch.s, "b": ch.b,
                        "c": ch.c, "m": ch.m, "y": ch.y, "k": ch.k,
                        "hex": ch.hex,
                    })
                }
                other => {
                    eprintln!("Unknown color_convert function: {}", other);
                    std::process::exit(1);
                }
            };
            json!({"name": name, "result": result})
        })
        .collect()
}

// ---------------------------------------------------------------
// hit_test
// ---------------------------------------------------------------

fn run_hit_test(vectors: &[Value]) -> Vec<Value> {
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap();
            let func = tc["function"].as_str().unwrap();
            let args: Vec<f64> = tc["args"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_f64().unwrap())
                .collect();

            let result: bool = match func {
                "point_in_rect" => {
                    hit_test::point_in_rect(args[0], args[1], args[2], args[3], args[4], args[5])
                }
                "segments_intersect" => hit_test::segments_intersect(
                    args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7],
                ),
                "segment_intersects_rect" => hit_test::segment_intersects_rect(
                    args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7],
                ),
                "rects_intersect" => hit_test::rects_intersect(
                    args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7],
                ),
                "circle_intersects_rect" => {
                    let filled = tc["filled"].as_bool().unwrap_or(true);
                    hit_test::circle_intersects_rect(
                        args[0], args[1], args[2], args[3], args[4], args[5], args[6], filled,
                    )
                }
                "ellipse_intersects_rect" => {
                    let filled = tc["filled"].as_bool().unwrap_or(true);
                    hit_test::ellipse_intersects_rect(
                        args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7],
                        filled,
                    )
                }
                "point_in_polygon" => {
                    let poly = parse_polygon(&tc["polygon"]);
                    hit_test::point_in_polygon(args[0], args[1], &poly)
                }
                // Element-level marquee / lasso. `element` is a test-JSON
                // element (parse_element handles every type, including
                // live compound shapes); `args` is the marquee rect
                // x, y, w, h; `polygon` is the lasso outline.
                "element_intersects_rect" => {
                    let elem = parse_element(&tc["element"]);
                    hit_test::element_intersects_rect(
                        &elem, args[0], args[1], args[2], args[3],
                    )
                }
                "element_intersects_polygon" => {
                    let elem = parse_element(&tc["element"]);
                    let poly = parse_polygon(&tc["polygon"]);
                    hit_test::element_intersects_polygon(&elem, &poly)
                }
                _ => {
                    eprintln!("Unknown hit_test function: {}", func);
                    std::process::exit(1);
                }
            };
            json!({"name": name, "result": result})
        })
        .collect()
}

// ---------------------------------------------------------------
// boolean
// ---------------------------------------------------------------

fn run_boolean(vectors: &[Value]) -> Vec<Value> {
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap();
            let func = tc["function"].as_str().unwrap();
            // Each operand DECLARES its fill rule (the carried-rule
            // law, transcripts/BOOLEAN.md). Absent, it is even-odd:
            // the standing convention for a bare ring list, and what
            // `boolean_union` and friends read.
            let a = RuledPolygonSet::new(
                parse_polygon_set(&tc["a"]),
                parse_fill_rule(&tc["a_fill_rule"]),
            );
            let b = RuledPolygonSet::new(
                parse_polygon_set(&tc["b"]),
                parse_fill_rule(&tc["b_fill_rule"]),
            );

            let result = match func {
                "union" => boolean_union_ruled(&a, &b),
                "intersect" => boolean_intersect_ruled(&a, &b),
                "subtract" => boolean_subtract_ruled(&a, &b),
                "exclude" => boolean_exclude_ruled(&a, &b),
                _ => {
                    eprintln!("Unknown boolean function: {}", func);
                    std::process::exit(1);
                }
            };

            let sample_points: Vec<Value> = tc["expected"]["sample_points"]
                .as_array()
                .map(|arr| {
                    arr.iter()
                        .map(|sp| {
                            let pt = parse_point(&sp["point"]);
                            let inside = point_in_polygon_set(&result, pt);
                            json!({"point": [pt.0, pt.1], "inside": inside})
                        })
                        .collect()
                })
                .unwrap_or_default();

            let rings: Vec<Value> = result
                .iter()
                .map(|ring| {
                    Value::Array(ring.iter().map(|&(x, y)| json!([x, y])).collect())
                })
                .collect();

            json!({
                "name": name,
                "result": {
                    "area": polygon_set_area(&result),
                    "ring_count": result.len(),
                    "sample_points": sample_points,
                    "rings": rings
                }
            })
        })
        .collect()
}

// ---------------------------------------------------------------
// boolean_normalize
// ---------------------------------------------------------------

fn run_boolean_normalize(vectors: &[Value]) -> Vec<Value> {
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap();
            let input = parse_polygon_set(&tc["input"]);
            let result = normalize(&input, parse_fill_rule(&tc["fill_rule"]));

            let rings: Vec<Value> = result
                .iter()
                .map(|ring| {
                    Value::Array(ring.iter().map(|&(x, y)| json!([x, y])).collect())
                })
                .collect();

            json!({
                "name": name,
                "result": {
                    "area": polygon_set_area(&result),
                    "ring_count": result.len(),
                    "all_rings_simple": all_rings_simple(&result),
                    "rings": rings
                }
            })
        })
        .collect()
}

// ---------------------------------------------------------------
// polygon_metrics
// ---------------------------------------------------------------
//
// Gates the harness's OWN instruments. No boolean operation runs here:
// the fixture's ring sets go straight into
// `jas_dioxus::algorithms::polygon_metrics`, so a red vector accuses a
// measuring instrument and nothing else. Fixture shape:
//   { name, rings: [[[x,y]...]...], sample_points: [[x,y]...] }

fn run_polygon_metrics(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::algorithms::polygon_metrics::{is_ring_simple, ring_signed_area};
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap();
            let rings = parse_polygon_set(&tc["rings"]);
            let sample_points: Vec<Value> = tc["sample_points"]
                .as_array()
                .map(|pts| {
                    pts.iter()
                        .map(|p| {
                            let pt = parse_point(p);
                            json!({
                                "point": [pt.0, pt.1],
                                "inside": point_in_polygon_set(&rings, pt)
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            json!({
                "name": name,
                "result": {
                    "ring_count": rings.len(),
                    "ring_signed_areas": rings.iter().map(ring_signed_area)
                        .collect::<Vec<f64>>(),
                    "ring_simple": rings.iter().map(is_ring_simple)
                        .collect::<Vec<bool>>(),
                    "all_rings_simple": all_rings_simple(&rings),
                    "area": polygon_set_area(&rings),
                    "sample_points": sample_points,
                }
            })
        })
        .collect()
}

// ---------------------------------------------------------------
// fit_curve
// ---------------------------------------------------------------

fn run_fit_curve(vectors: &[Value]) -> Vec<Value> {
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap();
            let points = parse_points(&tc["points"]);
            let error = tc["error"].as_f64().unwrap();
            let segments = fit_curve(&points, error);

            let seg_json: Vec<Value> = segments
                .iter()
                .map(|&(p1x, p1y, c1x, c1y, c2x, c2y, p2x, p2y)| {
                    json!([p1x, p1y, c1x, c1y, c2x, c2y, p2x, p2y])
                })
                .collect();

            json!({
                "name": name,
                "result": {
                    "segment_count": segments.len(),
                    "segments": seg_json
                }
            })
        })
        .collect()
}

// ---------------------------------------------------------------
// shape_recognize
// ---------------------------------------------------------------

fn run_shape_recognize(vectors: &[Value]) -> Vec<Value> {
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap();
            let points = parse_points(&tc["points"]);
            let cfg = if tc.get("config").is_some() {
                let mut cfg = RecognizeConfig::default();
                if let Some(t) = tc["config"]["tolerance"].as_f64() {
                    cfg.tolerance = t;
                }
                cfg
            } else {
                RecognizeConfig::default()
            };

            let result = recognize(&points, &cfg);

            json!({
                "name": name,
                "result": match result {
                    None => Value::Null,
                    Some(shape) => shape_to_json(&shape),
                }
            })
        })
        .collect()
}

fn shape_to_json(shape: &RecognizedShape) -> Value {
    match shape {
        RecognizedShape::Line { a, b } => json!({
            "kind": "line",
            "params": {"ax": a.0, "ay": a.1, "bx": b.0, "by": b.1}
        }),
        RecognizedShape::Triangle { pts } => json!({
            "kind": "triangle",
            "params": {"pts": [[pts[0].0, pts[0].1], [pts[1].0, pts[1].1], [pts[2].0, pts[2].1]]}
        }),
        RecognizedShape::Rectangle { x, y, w, h } => {
            let kind = if (w - h).abs() < 1e-9 { "square" } else { "rectangle" };
            json!({
                "kind": kind,
                "params": {"x": x, "y": y, "w": w, "h": h}
            })
        }
        RecognizedShape::RoundRect { x, y, w, h, r } => json!({
            "kind": "round_rect",
            "params": {"x": x, "y": y, "w": w, "h": h, "r": r}
        }),
        RecognizedShape::Circle { cx, cy, r } => json!({
            "kind": "circle",
            "params": {"cx": cx, "cy": cy, "r": r}
        }),
        RecognizedShape::Ellipse { cx, cy, rx, ry } => json!({
            "kind": "ellipse",
            "params": {"cx": cx, "cy": cy, "rx": rx, "ry": ry}
        }),
        RecognizedShape::Arrow {
            tail,
            tip,
            head_len,
            head_half_width,
            shaft_half_width,
        } => json!({
            "kind": "arrow",
            "params": {
                "tail_x": tail.0, "tail_y": tail.1,
                "tip_x": tip.0, "tip_y": tip.1,
                "head_len": head_len,
                "head_half_width": head_half_width,
                "shaft_half_width": shaft_half_width
            }
        }),
        RecognizedShape::Lemniscate {
            center,
            a,
            horizontal,
        } => json!({
            "kind": "lemniscate",
            "params": {"cx": center.0, "cy": center.1, "a": a, "horizontal": horizontal}
        }),
        RecognizedShape::Scribble { points } => {
            let pts: Vec<Value> = points.iter().map(|p| json!([p.0, p.1])).collect();
            json!({
                "kind": "scribble",
                "params": {"points": pts}
            })
        }
    }
}

// ---------------------------------------------------------------
// planar
// ---------------------------------------------------------------

fn run_planar(vectors: &[Value]) -> Vec<Value> {
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap();
            let polylines: Vec<Vec<(f64, f64)>> = tc["polylines"]
                .as_array()
                .unwrap()
                .iter()
                .map(|pl| parse_points(pl))
                .collect();

            let graph = PlanarGraph::build(&polylines);
            let fc = graph.face_count();

            let mut areas: Vec<f64> = (0..fc)
                .map(|i| graph.face_net_area(FaceId(i)))
                .collect();
            areas.sort_by(|a, b| a.partial_cmp(b).unwrap());

            let sample_points: Vec<Value> = tc["expected"]["sample_points"]
                .as_array()
                .map(|arr| {
                    arr.iter()
                        .map(|sp| {
                            let pt = parse_point(&sp["point"]);
                            let hit = graph.hit_test(pt);
                            json!({"point": [pt.0, pt.1], "inside_any_face": hit.is_some()})
                        })
                        .collect()
                })
                .unwrap_or_default();

            json!({
                "name": name,
                "result": {
                    "face_count": fc,
                    "face_areas_sorted": areas,
                    "sample_points": sample_points
                }
            })
        })
        .collect()
}

// ---------------------------------------------------------------
// text_layout
// ---------------------------------------------------------------

fn run_text_layout(vectors: &[Value]) -> Vec<Value> {
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap();
            let content = tc["content"].as_str().unwrap();
            let max_width = tc["max_width"].as_f64().unwrap();
            let font_size = tc["font_size"].as_f64().unwrap();
            let char_width = tc["char_width"].as_f64().unwrap();

            let measure = fixed_char_width_measure(char_width);
            let layout = text_layout::layout(content, max_width, font_size, &measure);

            let glyphs: Vec<Value> = layout
                .glyphs
                .iter()
                .map(|g| {
                    json!({
                        "idx": g.idx,
                        "line": g.line,
                        "x": g.x,
                        "right": g.right
                    })
                })
                .collect();

            json!({
                "name": name,
                "result": {
                    "line_count": layout.lines.len(),
                    "char_count": layout.char_count,
                    "glyphs": glyphs
                }
            })
        })
        .collect()
}

// ---------------------------------------------------------------
// text_layout_paragraph (Phase 11 parity)
// ---------------------------------------------------------------

fn run_text_layout_paragraph(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::algorithms::text_layout::{
        layout_with_paragraphs, ParagraphSegment, TextAlign,
    };
    fn parse_align(v: Option<&Value>) -> TextAlign {
        match v.and_then(|x| x.as_str()) {
            Some("center") => TextAlign::Center,
            Some("right") => TextAlign::Right,
            Some("justify") => TextAlign::Justify,
            _ => TextAlign::Left,
        }
    }
    fn f(v: Option<&Value>, default: f64) -> f64 {
        v.and_then(|x| x.as_f64()).unwrap_or(default)
    }
    fn b(v: Option<&Value>) -> bool {
        v.and_then(|x| x.as_bool()).unwrap_or(false)
    }
    fn u(v: Option<&Value>, default: usize) -> usize {
        v.and_then(|x| x.as_u64()).map(|n| n as usize).unwrap_or(default)
    }
    fn parse_seg(j: &Value) -> ParagraphSegment {
        let d = ParagraphSegment::default();
        ParagraphSegment {
            char_start: u(j.get("char_start"), 0),
            char_end: u(j.get("char_end"), 0),
            left_indent: f(j.get("left_indent"), d.left_indent),
            right_indent: f(j.get("right_indent"), d.right_indent),
            first_line_indent: f(j.get("first_line_indent"), d.first_line_indent),
            space_before: f(j.get("space_before"), d.space_before),
            space_after: f(j.get("space_after"), d.space_after),
            text_align: parse_align(j.get("text_align")),
            list_style: j.get("list_style").and_then(|x| x.as_str()).map(String::from),
            marker_gap: f(j.get("marker_gap"), d.marker_gap),
            hanging_punctuation: b(j.get("hanging_punctuation")),
            word_spacing_min: f(j.get("word_spacing_min"), d.word_spacing_min),
            word_spacing_desired: f(j.get("word_spacing_desired"), d.word_spacing_desired),
            word_spacing_max: f(j.get("word_spacing_max"), d.word_spacing_max),
            last_line_align: parse_align(j.get("last_line_align")),
            hyphenate: b(j.get("hyphenate")),
            hyphenate_min_word: u(j.get("hyphenate_min_word"), d.hyphenate_min_word),
            hyphenate_min_before: u(j.get("hyphenate_min_before"), d.hyphenate_min_before),
            hyphenate_min_after: u(j.get("hyphenate_min_after"), d.hyphenate_min_after),
            hyphenate_bias: u(j.get("hyphenate_bias"), d.hyphenate_bias as usize) as u8,
            hyphenate_capitalized: b(j.get("hyphenate_capitalized")),
        }
    }

    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap();
            let content = tc["content"].as_str().unwrap();
            let max_width = tc["max_width"].as_f64().unwrap();
            let font_size = tc["font_size"].as_f64().unwrap();
            let char_width = tc["char_width"].as_f64().unwrap();
            let segs: Vec<ParagraphSegment> = tc["paragraphs"].as_array()
                .map(|a| a.iter().map(parse_seg).collect())
                .unwrap_or_default();

            let measure = fixed_char_width_measure(char_width);
            let layout = layout_with_paragraphs(content, max_width, font_size, &segs, &measure);

            let glyphs: Vec<Value> = layout.glyphs.iter().map(|g| {
                json!({
                    "idx": g.idx,
                    "line": g.line,
                    "x": g.x,
                    "right": g.right
                })
            }).collect();

            json!({
                "name": name,
                "result": {
                    "line_count": layout.lines.len(),
                    "char_count": layout.char_count,
                    "glyphs": glyphs
                }
            })
        })
        .collect()
}

// ---------------------------------------------------------------
// path_text_layout
// ---------------------------------------------------------------

fn run_path_text_layout(vectors: &[Value]) -> Vec<Value> {
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap();
            let path_cmds = parse_path_commands(&tc["path"]);
            let content = tc["content"].as_str().unwrap();
            let start_offset = tc["start_offset"].as_f64().unwrap();
            let font_size = tc["font_size"].as_f64().unwrap();
            let char_width = tc["char_width"].as_f64().unwrap();

            let measure = fixed_char_width_measure(char_width);
            let layout =
                layout_path_text(&path_cmds, content, start_offset, font_size, &measure);

            let glyphs: Vec<Value> = layout
                .glyphs
                .iter()
                .map(|g| {
                    json!({
                        "idx": g.idx,
                        "cx": g.cx,
                        "cy": g.cy,
                        "angle": g.angle,
                        "overflow": g.overflow
                    })
                })
                .collect();

            json!({
                "name": name,
                "result": {
                    "total_length": layout.total_length,
                    "char_count": layout.char_count,
                    "glyphs": glyphs
                }
            })
        })
        .collect()
}

// ---------------------------------------------------------------
// JSON parsing helpers
// ---------------------------------------------------------------

fn parse_point(v: &Value) -> (f64, f64) {
    let arr = v.as_array().unwrap();
    (arr[0].as_f64().unwrap(), arr[1].as_f64().unwrap())
}

fn parse_points(v: &Value) -> Vec<(f64, f64)> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|p| parse_point(p))
        .collect()
}

fn parse_polygon(v: &Value) -> Vec<(f64, f64)> {
    parse_points(v)
}

/// Read a corpus vector's declared fill rule. Absent means EVEN-ODD —
/// the algorithm layer's default for a bare ring list, matching
/// `PolyFillRule::default()`. See transcripts/BOOLEAN.md
/// "Fill rule: the polygon set carries it".
fn parse_fill_rule(v: &Value) -> PolyFillRule {
    match v.as_str() {
        Some("nonzero") => PolyFillRule::NonZero,
        Some("evenodd") | None => PolyFillRule::EvenOdd,
        Some(other) => {
            eprintln!("Unknown fill_rule: {}", other);
            std::process::exit(1);
        }
    }
}

fn parse_polygon_set(v: &Value) -> PolygonSet {
    v.as_array()
        .unwrap()
        .iter()
        .map(|ring| parse_points(ring))
        .collect()
}

fn parse_path_commands(v: &Value) -> Vec<PathCommand> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|c| {
            let cmd = c["cmd"].as_str().unwrap();
            match cmd {
                "M" => PathCommand::MoveTo {
                    x: c["x"].as_f64().unwrap(),
                    y: c["y"].as_f64().unwrap(),
                },
                "L" => PathCommand::LineTo {
                    x: c["x"].as_f64().unwrap(),
                    y: c["y"].as_f64().unwrap(),
                },
                "C" => PathCommand::CurveTo {
                    x1: c["x1"].as_f64().unwrap(),
                    y1: c["y1"].as_f64().unwrap(),
                    x2: c["x2"].as_f64().unwrap(),
                    y2: c["y2"].as_f64().unwrap(),
                    x: c["x"].as_f64().unwrap(),
                    y: c["y"].as_f64().unwrap(),
                },
                "Q" => PathCommand::QuadTo {
                    x1: c["x1"].as_f64().unwrap(),
                    y1: c["y1"].as_f64().unwrap(),
                    x: c["x"].as_f64().unwrap(),
                    y: c["y"].as_f64().unwrap(),
                },
                "Z" => PathCommand::ClosePath,
                _ => {
                    eprintln!("Unknown path command: {}", cmd);
                    std::process::exit(1);
                }
            }
        })
        .collect()
}

// ---------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------
//
// The region metrics every boolean golden is expressed in live in
// jas_dioxus::algorithms::polygon_metrics — one copy, gated by the
// `polygon_metrics` corpus family. They used to be hand-pasted here.

use jas_dioxus::algorithms::polygon_metrics::{
    all_rings_simple, point_in_polygon_set, polygon_set_area,
};

// ── align ────────────────────────────────────────────────────
//
// Fixture shape (test_fixtures/algorithms/align.json):
//   { op, rects: [[x,y,w,h]...], reference, use_preview_bounds,
//     explicit_gap, translations }
//
// The runner materialises each rect as a real Rect element, builds
// the AlignReference from the reference descriptor, calls the
// named operation, and emits a sorted list of translations for
// comparison.

fn run_align(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::algorithms::align as aa;
    use jas_dioxus::geometry::element::{
        Bounds, Color, CommonProps, Element, Fill, RectElem,
    };

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

    fn to_bounds(arr: &Value) -> Bounds {
        let a = arr.as_array().unwrap();
        (
            a[0].as_f64().unwrap(),
            a[1].as_f64().unwrap(),
            a[2].as_f64().unwrap(),
            a[3].as_f64().unwrap(),
        )
    }

    vectors.iter().map(|v| {
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
            let kind = r["kind"].as_str().unwrap_or("selection");
            match kind {
                "selection" => {
                    let refs: Vec<&Element> = rects.iter().collect();
                    aa::AlignReference::Selection(aa::union_bounds(&refs, bounds_fn))
                }
                "artboard" => {
                    aa::AlignReference::Artboard(to_bounds(&r["bbox"]))
                }
                "key_object" => {
                    let idx = r["index"].as_u64().unwrap() as usize;
                    aa::AlignReference::KeyObject {
                        bbox: bounds_fn(&rects[idx]),
                        path: vec![idx],
                    }
                }
                _ => aa::AlignReference::Selection((0.0, 0.0, 0.0, 0.0)),
            }
        };

        let explicit_gap = v["explicit_gap"].as_f64();

        let out = match op {
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
            _ => Vec::new(),
        };

        let translations: Vec<Value> = out.iter()
            .map(|t| json!({ "path": t.path, "dx": t.dx, "dy": t.dy }))
            .collect();
        json!({ "translations": translations })
    }).collect()
}
