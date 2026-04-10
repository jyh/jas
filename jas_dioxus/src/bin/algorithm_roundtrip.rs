/// CLI tool for cross-language algorithm testing.
///
/// Usage:
///   algorithm_roundtrip <algorithm> <fixture.json>
///
/// Reads the fixture file, runs each test vector through the specified
/// algorithm, and outputs a JSON array of results to stdout.

use jas_dioxus::algorithms::boolean::{
    boolean_exclude, boolean_intersect, boolean_subtract, boolean_union, PolygonSet, Ring,
};
use jas_dioxus::algorithms::boolean_normalize::normalize;
use jas_dioxus::algorithms::fit_curve::fit_curve;
use jas_dioxus::algorithms::hit_test;
use jas_dioxus::algorithms::path_text_layout::layout_path_text;
use jas_dioxus::algorithms::planar::{FaceId, PlanarGraph};
use jas_dioxus::algorithms::shape_recognize::{recognize, RecognizeConfig, RecognizedShape};
use jas_dioxus::algorithms::text_layout;
use jas_dioxus::geometry::element::PathCommand;

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
        "hit_test" => run_hit_test(&vectors),
        "boolean" => run_boolean(&vectors),
        "boolean_normalize" => run_boolean_normalize(&vectors),
        "fit_curve" => run_fit_curve(&vectors),
        "shape_recognize" => run_shape_recognize(&vectors),
        "planar" => run_planar(&vectors),
        "text_layout" => run_text_layout(&vectors),
        "path_text_layout" => run_path_text_layout(&vectors),
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
            let a = parse_polygon_set(&tc["a"]);
            let b = parse_polygon_set(&tc["b"]);

            let result = match func {
                "union" => boolean_union(&a, &b),
                "intersect" => boolean_intersect(&a, &b),
                "subtract" => boolean_subtract(&a, &b),
                "exclude" => boolean_exclude(&a, &b),
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

            json!({
                "name": name,
                "result": {
                    "area": polygon_set_area(&result),
                    "ring_count": result.len(),
                    "sample_points": sample_points
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
            let result = normalize(&input);

            json!({
                "name": name,
                "result": {
                    "area": polygon_set_area(&result),
                    "ring_count": result.len(),
                    "all_rings_simple": all_rings_simple(&result)
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

            let measure = |s: &str| s.chars().count() as f64 * char_width;
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

            let measure = |s: &str| s.chars().count() as f64 * char_width;
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
// Geometry helpers (duplicated from test modules since they're
// not part of the public API)
// ---------------------------------------------------------------

fn ring_signed_area(ring: &Ring) -> f64 {
    if ring.len() < 3 {
        return 0.0;
    }
    let mut sum = 0.0;
    let n = ring.len();
    for i in 0..n {
        let (x1, y1) = ring[i];
        let (x2, y2) = ring[(i + 1) % n];
        sum += x1 * y2 - x2 * y1;
    }
    sum * 0.5
}

fn point_in_ring(ring: &Ring, pt: (f64, f64)) -> bool {
    let (px, py) = pt;
    let n = ring.len();
    if n < 3 {
        return false;
    }
    let mut inside = false;
    let mut j = n - 1;
    for i in 0..n {
        let (xi, yi) = ring[i];
        let (xj, yj) = ring[j];
        let intersects =
            ((yi > py) != (yj > py)) && (px < (xj - xi) * (py - yi) / (yj - yi) + xi);
        if intersects {
            inside = !inside;
        }
        j = i;
    }
    inside
}

fn point_in_polygon_set(ps: &PolygonSet, pt: (f64, f64)) -> bool {
    let mut count = 0;
    for ring in ps {
        if point_in_ring(ring, pt) {
            count += 1;
        }
    }
    count % 2 == 1
}

fn polygon_set_area(ps: &PolygonSet) -> f64 {
    let mut total = 0.0;
    for (i, ring) in ps.iter().enumerate() {
        let a = ring_signed_area(ring).abs();
        let mut depth = 0;
        if let Some(&pt) = ring.first() {
            for (j, other) in ps.iter().enumerate() {
                if i == j {
                    continue;
                }
                if point_in_ring(other, pt) {
                    depth += 1;
                }
            }
        }
        if depth % 2 == 0 {
            total += a;
        } else {
            total -= a;
        }
    }
    total
}

/// Check that no pair of non-adjacent edges in a ring intersect.
fn is_ring_simple(ring: &Ring) -> bool {
    let n = ring.len();
    if n < 3 {
        return true;
    }
    for i in 0..n {
        let (ax1, ay1) = ring[i];
        let (ax2, ay2) = ring[(i + 1) % n];
        for j in (i + 2)..n {
            if i == 0 && j == n - 1 {
                continue; // skip adjacent pair wrapping around
            }
            let (bx1, by1) = ring[j];
            let (bx2, by2) = ring[(j + 1) % n];
            if proper_crossing(ax1, ay1, ax2, ay2, bx1, by1, bx2, by2) {
                return false;
            }
        }
    }
    true
}

fn proper_crossing(
    ax1: f64,
    ay1: f64,
    ax2: f64,
    ay2: f64,
    bx1: f64,
    by1: f64,
    bx2: f64,
    by2: f64,
) -> bool {
    let d1 = cross(bx2 - bx1, by2 - by1, ax1 - bx1, ay1 - by1);
    let d2 = cross(bx2 - bx1, by2 - by1, ax2 - bx1, ay2 - by1);
    let d3 = cross(ax2 - ax1, ay2 - ay1, bx1 - ax1, by1 - ay1);
    let d4 = cross(ax2 - ax1, ay2 - ay1, bx2 - ax1, by2 - ay1);
    if d1 * d2 < 0.0 && d3 * d4 < 0.0 {
        return true;
    }
    false
}

fn cross(ux: f64, uy: f64, vx: f64, vy: f64) -> f64 {
    ux * vy - uy * vx
}

fn all_rings_simple(ps: &PolygonSet) -> bool {
    ps.iter().all(|ring| is_ring_simple(ring))
}
