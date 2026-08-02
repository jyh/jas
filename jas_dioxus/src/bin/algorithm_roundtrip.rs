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
        "art_flatten" => run_art_flatten(&vectors),
        "calligraphic_outline" => run_calligraphic_outline(&vectors),
        "offset_path" => run_offset_path(&vectors),
        "paste_translate" => run_paste_translate(&vectors),
        "arrow_trim" => run_arrow_trim(&vectors),
        "gradient_remap" => run_gradient_remap(&vectors),
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
        "arrangement" => run_arrangement(&vectors),
        "transform_apply" => run_transform_apply(&vectors),
        "paragraph_markers" => run_paragraph_markers(&vectors),
        "hyphenator" => run_hyphenator(&vectors),
        "simplify" => run_simplify(&vectors),
        "dash_renderer" => run_dash_renderer(&vectors),
        "art_along_path" => run_art_along_path(&vectors),
        "pattern_along_path" => run_pattern_along_path(&vectors),
        "bristle_stroke" => run_bristle_stroke(&vectors),
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
// art_flatten (the FIRST-SUBPATH flattener behind art-along-path,
// pattern-along-path and the bristle brush)
// ---------------------------------------------------------------
//
// A separate verb from `flatten` on purpose: `art_along_path::flatten` is not
// a wrapper over `flatten_path_commands`. It walks the first subpath only,
// dedupes coincident vertices, and samples curves at its own step counts. It
// had no corpus family at all, which is how a leading-ClosePath bail-out
// survived in BOTH ports at once (S-4).

fn run_art_flatten(vectors: &[Value]) -> Vec<Value> {
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let elem = parse_element(&tc["element"]);
            let d = match &elem {
                Element::Path(e) => e.d.clone(),
                _ => Vec::new(),
            };
            let pts = jas_dioxus::algorithms::art_along_path::flatten(&d);
            let result: Vec<Value> = pts.iter().map(|(x, y)| json!([x, y])).collect();
            json!({"name": name, "result": result})
        })
        .collect()
}

// ---------------------------------------------------------------
// calligraphic_outline (the Calligraphic brush's variable-width outline)
// ---------------------------------------------------------------
//
// Driven for the same reason as `art_flatten`: its private stroke sampler is a
// FOURTH first-subpath walker, with its own step counts and its own
// accumulator, and it carried the same leading-ClosePath bail-out in both
// ports. Gated at the public function rather than at the sampler so the family
// asserts what the artist sees (the ribbon), not an internal.

fn run_calligraphic_outline(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::algorithms::calligraphic_outline::{
        calligraphic_outline, CalligraphicBrush,
    };
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let elem = parse_element(&tc["element"]);
            let d = match &elem {
                Element::Path(e) => e.d.clone(),
                _ => Vec::new(),
            };
            let b = &tc["brush"];
            let brush = CalligraphicBrush {
                angle: b["angle"].as_f64().unwrap_or(0.0),
                roundness: b["roundness"].as_f64().unwrap_or(100.0),
                size: b["size"].as_f64().unwrap_or(1.0),
            };
            let pts = calligraphic_outline(&d, &brush);
            let result: Vec<Value> = pts.iter().map(|(x, y)| json!([x, y])).collect();
            json!({"name": name, "result": result})
        })
        .collect()
}

// ---------------------------------------------------------------
// offset_path (the WIDTH TOOL's variable-width stroke outline)
// ---------------------------------------------------------------
//
// The last unreachable family of the Phase-3 plumbing pass, and it was
// unreachable for a reason worth naming: `algorithms/offset_path` produced no
// values at all. It was 299 lines of `web_sys::CanvasRenderingContext2d`
// calls, gated behind `web` for that one import, so the rails and the caps
// existed only as side effects on a canvas. Nothing could serialise them,
// nothing could compare them, and the two ports' agreement about a variable-
// width stroke rested on the two files having been typed to look alike.
//
// The verb reports THREE things:
//   * `polygon` -- the closed outline the renderer fills, flattened at the
//     vector's own `arc_steps`. Faithful: it carries the duplicate vertex a
//     `move_to` leaves behind and any chord between a rail and the point a
//     cap arc actually begins at, because both are edges of the filled shape.
//   * `start_cap` / `end_cap` -- the caps PARAMETRICALLY, so a cap defect is
//     legible as an angle rather than only as a moved point, and so the sweep
//     direction is a compared VALUE instead of a platform flag nobody outside
//     the drawing code ever saw.
//   * `default_arc_steps` -- the production constant. It is not otherwise on
//     the wire (the vectors choose small step counts to stay hand-readable),
//     and a constant the two ports could set differently is exactly the kind
//     of agreement that should not rest on a comment.
//
// SCOPE, stated where it reports: this gates the OUTLINE. It does not gate
// the fill (colour, alpha, winding rule) and it does not gate the platform
// call that consumes the polygon.

fn run_offset_path(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::algorithms::offset_path::{
        flatten_outline, variable_width_outline_line,
        variable_width_outline_path, StrokeCap, CAP_ARC_STEPS,
    };
    use jas_dioxus::geometry::element::{LineCap, StrokeWidthPoint};

    fn cap_json(c: &StrokeCap) -> Value {
        match *c {
            StrokeCap::Butt => json!({"kind": "butt"}),
            StrokeCap::Round { cx, cy, r, a0, a1, decreasing } => json!({
                "kind": "round", "cx": cx, "cy": cy, "r": r,
                "a0": a0, "a1": a1, "decreasing": decreasing,
            }),
            StrokeCap::Square { ext, ux, uy } => json!({
                "kind": "square", "ext": ext, "ux": ux, "uy": uy,
            }),
        }
    }

    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let width_points: Vec<StrokeWidthPoint> = tc["width_points"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .map(|p| StrokeWidthPoint {
                            t: p["t"].as_f64().unwrap_or(0.0),
                            width_left: p["width_left"].as_f64().unwrap_or(0.0),
                            width_right: p["width_right"].as_f64().unwrap_or(0.0),
                        })
                        .collect()
                })
                .unwrap_or_default();
            let linecap = match tc["linecap"].as_str().unwrap_or("butt") {
                "round" => LineCap::Round,
                "square" => LineCap::Square,
                _ => LineCap::Butt,
            };
            let arc_steps = tc["arc_steps"].as_u64().unwrap_or(CAP_ARC_STEPS as u64)
                as usize;

            let elem = parse_element(&tc["element"]);
            let outline = match &elem {
                Element::Line(e) => variable_width_outline_line(
                    e.x1, e.y1, e.x2, e.y2, &width_points, linecap,
                ),
                Element::Path(e) => {
                    variable_width_outline_path(&e.d, &width_points, linecap)
                }
                _ => variable_width_outline_path(&[], &width_points, linecap),
            };
            let poly: Vec<Value> = flatten_outline(&outline, arc_steps)
                .iter()
                .map(|(x, y)| json!([x, y]))
                .collect();
            json!({"name": name, "result": {
                "polygon": poly,
                "start_cap": cap_json(&outline.start_cap),
                "end_cap": cap_json(&outline.end_cap),
                "default_arc_steps": CAP_ARC_STEPS,
            }})
        })
        .collect()
}

// ---------------------------------------------------------------
// paste_translate (the offset a PASTE applies to each pasted element)
// ---------------------------------------------------------------
//
// `workspace/actions.yaml` §paste: "offset 24 points down and to the right
// from the original position", against `paste_in_place`'s explicit "no offset".
// Both ports implement that by translating each pasted element, and until this
// family NOTHING watched it: `op_apply` has no paste verb in either port and no
// corpus vector pastes anything.
//
// This verb deliberately calls the function each port's PASTE PATH calls, not
// the tidiest one available: Rust's `translate_element` (invoked at both paste
// sites in workspace/clipboard.rs) and Swift's `EditClipboard.translateElement`
// (invoked by `pasteClipboard`). Pointing it at Swift's `Element.translated`
// instead would be a decoy — that function was already correct while the paste
// path was not.
//
// SCOPE, stated: this gates the per-element transform a paste applies. The rest
// of the paste FLOW is still ungated and still divergent (Rust appends to the
// selected layer; Swift merges by layer name) — see the manifest's
// `paste-offset-compound-divergence` row.

fn run_paste_translate(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::document::document::Document;
    use jas_dioxus::geometry::element::{translate_element, CommonProps, LayerElem};
    use jas_dioxus::geometry::test_json::document_to_test_json;
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let elem = parse_element(&tc["element"]);
            let dx = tc["dx"].as_f64().unwrap_or(0.0);
            let dy = tc["dy"].as_f64().unwrap_or(0.0);
            let moved = translate_element(&elem, dx, dy);
            // Serialized through the SHARED document writer so the comparison
            // sees every field, not only the coordinates: the Swift paste
            // helper's group/layer arms also dropped name, id, visibility,
            // blend mode and mask, which a coordinate-only result would miss.
            let doc = Document {
                layers: vec![jas_dioxus::geometry::element::Element::Layer(LayerElem {
                    children: vec![std::rc::Rc::new(moved)],
                    common: CommonProps { name: Some("L0".into()), ..Default::default() },
                    isolated_blending: false,
                    knockout_group: false,
                })],
                // Explicitly EMPTY: `Document::default()` seeds a Letter
                // artboard whose id is random, which would make the golden
                // non-deterministic and port-divergent for reasons that have
                // nothing to do with paste. Swift's `Document(layers:)`
                // defaults artboards to empty already.
                artboards: Vec::new(),
                ..Document::default()
            };
            // The writer's CANONICAL STRING, not a re-parsed object: round-
            // tripping it through a JSON library normalises `1.0` to `1` in one
            // port and not the other, which would have been a harness
            // divergence wearing the costume of a port divergence. This is the
            // same comparison the operations corpus makes.
            json!({"name": name, "result": document_to_test_json(&doc)})
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

// ---------------------------------------------------------------
// gradient_remap (linear-gradient stop remap onto a split fragment)
// ---------------------------------------------------------------

fn stop_from_json(v: &Value) -> jas_dioxus::geometry::element::GradientStop {
    use jas_dioxus::geometry::element::{Color, GradientStop};
    GradientStop {
        color: Color::from_hex(v["hex"].as_str().unwrap_or("000000"))
            .unwrap_or(Color::rgb(0.0, 0.0, 0.0)),
        opacity: v["opacity"].as_f64().unwrap_or(100.0),
        location: v["location"].as_f64().unwrap_or(0.0),
        midpoint_to_next: v["midpoint"].as_f64().unwrap_or(50.0),
    }
}

fn bbox_from_json(v: &Value) -> (f64, f64, f64, f64) {
    let a = v.as_array().cloned().unwrap_or_default();
    let g = |i: usize| a.get(i).and_then(|x| x.as_f64()).unwrap_or(0.0);
    (g(0), g(1), g(2), g(3))
}

fn run_gradient_remap(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::algorithms::gradient_remap::remap_linear_stops;
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let stops: Vec<_> = tc["stops"]
                .as_array()
                .map(|a| a.iter().map(stop_from_json).collect())
                .unwrap_or_default();
            let out = remap_linear_stops(
                &stops,
                tc["angle"].as_f64().unwrap_or(0.0),
                bbox_from_json(&tc["parent"]),
                bbox_from_json(&tc["fragment"]),
            );
            let result: Vec<Value> = out
                .iter()
                .map(|s| {
                    // Reported as 8-bit hex, not f64 channels: a Swift
                    // GradientStop stores its colour AS a hex string, so hex is
                    // the widest value the two stop models share. See the
                    // fixture's _doc.
                    json!({
                        "hex": s.color.to_hex(),
                        "opacity": s.opacity,
                        "location": s.location,
                        "midpoint": s.midpoint_to_next,
                    })
                })
                .collect();
            json!({"name": name, "result": result})
        })
        .collect()
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

        // No document behind these vectors -- the runner materialises plain
        // rects -- so the resolver-less measurements are exactly right here.
        let bounds_fn: aa::BoundsFn = if v["use_preview_bounds"].as_bool().unwrap_or(false) {
            &aa::preview_bounds
        } else {
            &aa::geometric_bounds
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

// ---------------------------------------------------------------
// arrangement (the shared segment-splitting primitive)
// ---------------------------------------------------------------
//
// `split_points` and `add_or_find_vertex` are the first stage of BOTH the
// planar-graph extractor and the boolean ring normalizer, and until this
// verb existed neither had any cross-language witness: their whole
// assurance was 11 Rust tests and 11 Swift tests mirrored by hand.
//
// The `endpoint` field is load-bearing and is NOT a tolerance quantity.
// The module contracts that a returned point is TAKEN FROM an existing
// endpoint whenever a parameter sits at one, bit-exactly, because that is
// what lets the caller's dedup fuse a T-junction into a single vertex. A
// tolerance comparison cannot tell (5.0, 0.0) from (4.999999999999999,
// 0.0), so each point reports which input endpoint it is BIT-IDENTICAL to
// — first match in the order a1, a2, b1, b2 — and that string is compared
// exactly.

fn arrangement_endpoint_name(
    p: (f64, f64),
    a1: (f64, f64),
    a2: (f64, f64),
    b1: (f64, f64),
    b2: (f64, f64),
) -> Value {
    for (name, q) in [("a1", a1), ("a2", a2), ("b1", b1), ("b2", b2)] {
        if p.0 == q.0 && p.1 == q.1 {
            return Value::String(name.to_string());
        }
    }
    Value::Null
}

fn arrangement_point(v: &Value) -> (f64, f64) {
    let a = v.as_array().expect("arrangement: point must be [x, y]");
    (
        a[0].as_f64().expect("arrangement: x must be a number"),
        a[1].as_f64().expect("arrangement: y must be a number"),
    )
}

fn run_arrangement(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::algorithms::arrangement::{add_or_find_vertex, split_points};
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let func = tc["function"].as_str().unwrap_or("");
            let result = match func {
                "split_points" => {
                    let a = tc["a"].as_array().expect("arrangement: `a` missing");
                    let b = tc["b"].as_array().expect("arrangement: `b` missing");
                    let (a1, a2) = (arrangement_point(&a[0]), arrangement_point(&a[1]));
                    let (b1, b2) = (arrangement_point(&b[0]), arrangement_point(&b[1]));
                    let pts: Vec<Value> = split_points(a1, a2, b1, b2)
                        .into_iter()
                        .map(|(p, s, t)| {
                            json!({
                                "p": [p.0, p.1],
                                "s": s,
                                "t": t,
                                "endpoint": arrangement_endpoint_name(p, a1, a2, b1, b2),
                            })
                        })
                        .collect();
                    json!({ "points": pts })
                }
                "add_or_find_vertex" => {
                    let mut verts: Vec<(f64, f64)> = tc["vertices"]
                        .as_array()
                        .expect("arrangement: `vertices` missing")
                        .iter()
                        .map(arrangement_point)
                        .collect();
                    let indices: Vec<Value> = tc["points"]
                        .as_array()
                        .expect("arrangement: `points` missing")
                        .iter()
                        .map(|p| json!(add_or_find_vertex(&mut verts, arrangement_point(p))))
                        .collect();
                    let out: Vec<Value> = verts.iter().map(|v| json!([v.0, v.1])).collect();
                    json!({ "indices": indices, "vertices": out })
                }
                _ => {
                    eprintln!("Unknown arrangement function: {}", func);
                    std::process::exit(1);
                }
            };
            json!({ "name": name, "result": result })
        })
        .collect()
}

// ---------------------------------------------------------------
// transform_apply (the Scale / Rotate / Shear matrix builders)
// ---------------------------------------------------------------
//
// Every transform dialog and every transform tool routes through these
// four functions, and none of them had a cross-language witness. The
// matrix is reported as its six components in FULL precision — the
// MATRIXPRECISION ruling is that multipliers keep full precision and only
// positions round to four — plus the transformed image of two probe
// points, so a matrix that is right in its components and wrong in its
// pivot cannot pass.

fn transform_json(t: &jas_dioxus::geometry::element::Transform) -> Value {
    // Two probe points, applied through the matrix: the pivot arithmetic
    // (translate(-r) * base * translate(r)) lives entirely in `e` and `f`,
    // and a reader comparing only a..d would not see it move.
    let apply = |x: f64, y: f64| (t.a * x + t.c * y + t.e, t.b * x + t.d * y + t.f);
    let p1 = apply(0.0, 0.0);
    let p2 = apply(100.0, 40.0);
    json!({
        "m": [t.a, t.b, t.c, t.d, t.e, t.f],
        "origin_image": [p1.0, p1.1],
        "probe_image": [p2.0, p2.1],
    })
}

fn run_transform_apply(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::algorithms::transform_apply as ta;
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let func = tc["function"].as_str().unwrap_or("");
            let n = |k: &str, d: f64| tc.get(k).and_then(|v| v.as_f64()).unwrap_or(d);
            let result = match func {
                "scale_matrix" => transform_json(&ta::scale_matrix(
                    n("sx", 1.0), n("sy", 1.0), n("rx", 0.0), n("ry", 0.0),
                )),
                "rotate_matrix" => transform_json(&ta::rotate_matrix(
                    n("theta_deg", 0.0), n("rx", 0.0), n("ry", 0.0),
                )),
                "shear_matrix" => transform_json(&ta::shear_matrix(
                    n("angle_deg", 0.0),
                    tc.get("axis").and_then(|v| v.as_str()).unwrap_or("horizontal"),
                    n("axis_angle_deg", 0.0),
                    n("rx", 0.0),
                    n("ry", 0.0),
                )),
                "stroke_width_factor" => {
                    json!({ "factor": ta::stroke_width_factor(n("sx", 1.0), n("sy", 1.0)) })
                }
                _ => {
                    eprintln!("Unknown transform_apply function: {}", func);
                    std::process::exit(1);
                }
            };
            json!({ "name": name, "result": result })
        })
        .collect()
}

// ---------------------------------------------------------------
// paragraph_markers (the list-marker half of text_layout_paragraph)
// ---------------------------------------------------------------
//
// The `text_layout_paragraph` verb drives `text_layout::layout_with_
// paragraphs`; it does NOT reach the module of the same name. Those five
// functions are called only from the RENDERER (canvas/render.rs,
// CanvasSubwindow.swift) and from app_state, so every ordered list an
// artist draws goes through arithmetic no corpus family watched.

fn run_paragraph_markers(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::algorithms::text_layout::ParagraphSegment;
    use jas_dioxus::algorithms::text_layout_paragraph as tlp;
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let func = tc["function"].as_str().unwrap_or("");
            let result = match func {
                "marker_text" => json!({ "text": tlp::marker_text(
                    tc["list_style"].as_str().unwrap_or(""),
                    tc["counter"].as_u64().unwrap_or(0) as usize) }),
                "to_alpha" => json!({ "text": tlp::to_alpha(
                    tc["n"].as_u64().unwrap_or(0) as usize,
                    tc["upper"].as_bool().unwrap_or(false)) }),
                "to_roman" => json!({ "text": tlp::to_roman(
                    tc["n"].as_u64().unwrap_or(0) as usize,
                    tc["upper"].as_bool().unwrap_or(false)) }),
                "compute_counters" => {
                    // Only `list_style` is consulted, so the fixture carries
                    // a bare style list rather than whole segments.
                    let segs: Vec<ParagraphSegment> = tc["styles"]
                        .as_array()
                        .expect("paragraph_markers: `styles` missing")
                        .iter()
                        .map(|v| ParagraphSegment {
                            list_style: v.as_str().map(String::from),
                            ..ParagraphSegment::default()
                        })
                        .collect();
                    json!({ "counters": tlp::compute_counters(&segs) })
                }
                _ => {
                    eprintln!("Unknown paragraph_markers function: {}", func);
                    std::process::exit(1);
                }
            };
            json!({ "name": name, "result": result })
        })
        .collect()
}

// ---------------------------------------------------------------
// hyphenator (Liang-style pattern hyphenation)
// ---------------------------------------------------------------
//
// Both public functions. `split_pattern` is the parser the whole table
// is read through, so a divergence there mis-hyphenates every word
// silently rather than loudly.

fn run_hyphenator(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::algorithms::hyphenator::{hyphenate, split_pattern};
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let func = tc["function"].as_str().unwrap_or("");
            let result = match func {
                "split_pattern" => {
                    let (letters, digits) = split_pattern(tc["pattern"].as_str().unwrap_or(""));
                    json!({ "letters": letters, "digits": digits })
                }
                "hyphenate" => {
                    let pats: Vec<String> = tc["patterns"]
                        .as_array()
                        .expect("hyphenator: `patterns` missing")
                        .iter()
                        .map(|v| v.as_str().unwrap_or("").to_string())
                        .collect();
                    let refs: Vec<&str> = pats.iter().map(|s| s.as_str()).collect();
                    let breaks = hyphenate(
                        tc["word"].as_str().unwrap_or(""),
                        &refs,
                        tc["min_before"].as_u64().unwrap_or(0) as usize,
                        tc["min_after"].as_u64().unwrap_or(0) as usize,
                    );
                    // The break MASK is the primitive answer; the hyphenated
                    // spelling is the same answer a human can read, and a
                    // reader who can only check one should check that one.
                    let word: Vec<char> = tc["word"].as_str().unwrap_or("").chars().collect();
                    let mut spelled = String::new();
                    for (i, c) in word.iter().enumerate() {
                        if i > 0 && *breaks.get(i).unwrap_or(&false) {
                            spelled.push('-');
                        }
                        spelled.push(*c);
                    }
                    json!({ "breaks": breaks, "spelled": spelled })
                }
                _ => {
                    eprintln!("Unknown hyphenator function: {}", func);
                    std::process::exit(1);
                }
            };
            json!({ "name": name, "result": result })
        })
        .collect()
}

// ---------------------------------------------------------------
// simplify (polyline -> Bezier, the Object > Simplify command and the
// tail of every boolean result)
// ---------------------------------------------------------------

fn run_simplify(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::algorithms::simplify::{simplify_polyline, simplify_polyline_with_angle};
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let pts: Vec<(f64, f64)> = tc["points"]
                .as_array()
                .expect("simplify: `points` missing")
                .iter()
                .map(arrangement_point)
                .collect();
            let precision = tc["precision"].as_f64().unwrap_or(1.0);
            let closed = tc["closed"].as_bool().unwrap_or(false);
            let out = match tc.get("corner_angle").and_then(|v| v.as_f64()) {
                Some(a) => simplify_polyline_with_angle(&pts, precision, closed, a),
                None => simplify_polyline(&pts, precision, closed),
            };
            let cmds: Vec<Value> = out.iter().map(cmd_to_json).collect();
            json!({ "name": name, "result": cmds })
        })
        .collect()
}

// ---------------------------------------------------------------
// dash_renderer (every dashed stroke the app draws)
// ---------------------------------------------------------------
//
// The output is a LIST OF SUB-PATHS, one per dash, in arc-length order,
// so the family pins the dash BOUNDARIES and not merely the total ink.

fn run_dash_renderer(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::algorithms::dash_renderer::expand_dashed_stroke;
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let elem = parse_element(&tc["element"]);
            let d = match &elem {
                Element::Path(e) => e.d.clone(),
                _ => Vec::new(),
            };
            let dash: Vec<f64> = tc["dash_array"]
                .as_array()
                .expect("dash_renderer: `dash_array` missing")
                .iter()
                .map(|v| v.as_f64().unwrap_or(0.0))
                .collect();
            let align = tc["align_anchors"].as_bool().unwrap_or(false);
            let subpaths: Vec<Value> = expand_dashed_stroke(&d, &dash, align)
                .iter()
                .map(|sp| Value::Array(sp.iter().map(cmd_to_json).collect()))
                .collect();
            json!({ "name": name, "result": { "subpaths": subpaths } })
        })
        .collect()
}

// ---------------------------------------------------------------
// The three PATH BRUSHES: art warp, pattern tiling, bristles
// ---------------------------------------------------------------
//
// One shape, three families. Each takes a stroke path plus a brush and
// returns a list of polygons (or, for the bristle brush, polylines) in
// document coordinates. `art_flatten` already gates the FIRST-SUBPATH
// WALKER all three sit on; nothing gated the warp, the tiling or the
// bristle spread above it, so an S-4 fix at the walker could be undone
// by a divergence one level up and no family would say so.

fn polys_json(polys: &[Vec<(f64, f64)>]) -> Value {
    Value::Array(
        polys
            .iter()
            .map(|p| Value::Array(p.iter().map(|q| json!([q.0, q.1])).collect()))
            .collect(),
    )
}

fn brush_polys(v: Option<&Value>) -> Vec<Vec<(f64, f64)>> {
    v.and_then(|x| x.as_array())
        .map(|a| {
            a.iter()
                .map(|p| {
                    p.as_array()
                        .expect("brush polygon must be a point list")
                        .iter()
                        .map(arrangement_point)
                        .collect()
                })
                .collect()
        })
        .unwrap_or_default()
}

fn brush_path(tc: &Value) -> Vec<PathCommand> {
    match parse_element(&tc["element"]) {
        Element::Path(e) => e.d,
        _ => Vec::new(),
    }
}

fn run_art_along_path(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::algorithms::art_along_path::{art_along_path, ArtBrush};
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let b = &tc["brush"];
            let n = |k: &str, d: f64| b.get(k).and_then(|v| v.as_f64()).unwrap_or(d);
            let f = |k: &str| b.get(k).and_then(|v| v.as_bool()).unwrap_or(false);
            let brush = ArtBrush {
                artwork_width: n("artwork_width", 0.0),
                artwork_height: n("artwork_height", 0.0),
                artwork: brush_polys(b.get("artwork")),
                scale: n("scale", 100.0),
                flip_across: f("flip_across"),
                flip_along: f("flip_along"),
                stroke_weight: n("stroke_weight", 1.0),
            };
            json!({"name": name,
                   "result": polys_json(&art_along_path(&brush_path(tc), &brush))})
        })
        .collect()
}

fn run_pattern_along_path(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::algorithms::pattern_along_path::{pattern_along_path, PatternBrush};
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let b = &tc["brush"];
            let n = |k: &str, d: f64| b.get(k).and_then(|v| v.as_f64()).unwrap_or(d);
            let f = |k: &str| b.get(k).and_then(|v| v.as_bool()).unwrap_or(false);
            let brush = PatternBrush {
                tile_width: n("tile_width", 0.0),
                tile_height: n("tile_height", 0.0),
                side: brush_polys(b.get("side")),
                scale: n("scale", 100.0),
                spacing: n("spacing", 0.0),
                flip_across: f("flip_across"),
                flip_along: f("flip_along"),
                stroke_weight: n("stroke_weight", 1.0),
            };
            json!({"name": name,
                   "result": polys_json(&pattern_along_path(&brush_path(tc), &brush))})
        })
        .collect()
}

fn run_bristle_stroke(vectors: &[Value]) -> Vec<Value> {
    use jas_dioxus::algorithms::bristle_stroke::{bristle_stroke, BristleBrush};
    vectors
        .iter()
        .map(|tc| {
            let name = tc["name"].as_str().unwrap_or("");
            let b = &tc["brush"];
            let n = |k: &str, d: f64| b.get(k).and_then(|v| v.as_f64()).unwrap_or(d);
            let brush = BristleBrush {
                size: n("size", 1.0),
                density: n("density", 50.0),
                thickness: n("thickness", 50.0),
                opacity: n("opacity", 100.0),
                stroke_weight: n("stroke_weight", 1.0),
            };
            // The three DERIVED scalars are reported alongside the polylines
            // because the caller strokes with them: a port that agreed on
            // every bristle centreline and disagreed on the alpha would
            // paint a visibly different stroke and compare green.
            json!({"name": name, "result": {
                "count": brush.count(),
                "line_width": brush.line_width(),
                "alpha": brush.alpha(),
                "bristles": polys_json(&bristle_stroke(&brush_path(tc), &brush)),
            }})
        })
        .collect()
}
