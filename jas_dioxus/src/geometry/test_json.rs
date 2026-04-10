//! Canonical Test JSON serialization for cross-language equivalence testing.
//!
//! See `CROSS_LANGUAGE_TESTING.md` at the repository root for the full
//! specification.  Every semantic document value has exactly one JSON
//! string representation, so byte-for-byte comparison of the output is a
//! valid equivalence check.

use crate::document::document::{Document, ElementSelection, SelectionKind};
use crate::geometry::element::*;

// ---------------------------------------------------------------------------
// Float formatting: round to 4 decimal places
// ---------------------------------------------------------------------------

fn fmt(v: f64) -> String {
    let rounded = (v * 10000.0).round() / 10000.0;
    // Ensure there is always a decimal point.
    if rounded == rounded.trunc() {
        format!("{:.1}", rounded)
    } else {
        // Format with enough decimals, strip trailing zeros but keep at
        // least one digit after the decimal point.
        let s = format!("{:.4}", rounded);
        let s = s.trim_end_matches('0');
        s.to_string()
    }
}

// ---------------------------------------------------------------------------
// JSON building helpers
// ---------------------------------------------------------------------------

/// A tiny JSON builder that always emits keys in sorted order.
struct JsonObj {
    entries: Vec<(String, String)>,
}

impl JsonObj {
    fn new() -> Self {
        Self { entries: Vec::new() }
    }

    fn str_val(&mut self, key: &str, v: &str) {
        self.entries.push((
            key.to_string(),
            format!("\"{}\"", v.replace('\\', "\\\\").replace('"', "\\\"")),
        ));
    }

    fn num(&mut self, key: &str, v: f64) {
        self.entries.push((key.to_string(), fmt(v)));
    }

    fn bool_val(&mut self, key: &str, v: bool) {
        self.entries
            .push((key.to_string(), if v { "true" } else { "false" }.to_string()));
    }

    fn null(&mut self, key: &str) {
        self.entries.push((key.to_string(), "null".to_string()));
    }

    fn int(&mut self, key: &str, v: usize) {
        self.entries.push((key.to_string(), v.to_string()));
    }

    fn raw(&mut self, key: &str, json: String) {
        self.entries.push((key.to_string(), json));
    }

    fn build(mut self) -> String {
        self.entries.sort_by(|a, b| a.0.cmp(&b.0));
        let pairs: Vec<String> = self
            .entries
            .iter()
            .map(|(k, v)| format!("\"{}\":{}", k, v))
            .collect();
        format!("{{{}}}", pairs.join(","))
    }
}

fn json_array(items: &[String]) -> String {
    format!("[{}]", items.join(","))
}

// ---------------------------------------------------------------------------
// Type serializers
// ---------------------------------------------------------------------------

fn color_json(c: &Color) -> String {
    let mut o = JsonObj::new();
    o.num("a", c.a);
    o.num("b", c.b);
    o.num("g", c.g);
    o.num("r", c.r);
    o.build()
}

fn fill_json(fill: &Option<Fill>) -> String {
    match fill {
        None => "null".to_string(),
        Some(f) => {
            let mut o = JsonObj::new();
            o.raw("color", color_json(&f.color));
            o.build()
        }
    }
}

fn stroke_json(stroke: &Option<Stroke>) -> String {
    match stroke {
        None => "null".to_string(),
        Some(s) => {
            let mut o = JsonObj::new();
            o.raw("color", color_json(&s.color));
            o.str_val("linecap", linecap_str(s.linecap));
            o.str_val("linejoin", linejoin_str(s.linejoin));
            o.num("width", s.width);
            o.build()
        }
    }
}

fn linecap_str(lc: LineCap) -> &'static str {
    match lc {
        LineCap::Butt => "butt",
        LineCap::Round => "round",
        LineCap::Square => "square",
    }
}

fn linejoin_str(lj: LineJoin) -> &'static str {
    match lj {
        LineJoin::Miter => "miter",
        LineJoin::Round => "round",
        LineJoin::Bevel => "bevel",
    }
}

fn transform_json(t: &Option<Transform>) -> String {
    match t {
        None => "null".to_string(),
        Some(t) => {
            let mut o = JsonObj::new();
            o.num("a", t.a);
            o.num("b", t.b);
            o.num("c", t.c);
            o.num("d", t.d);
            o.num("e", t.e);
            o.num("f", t.f);
            o.build()
        }
    }
}

fn visibility_str(v: Visibility) -> &'static str {
    match v {
        Visibility::Invisible => "invisible",
        Visibility::Outline => "outline",
        Visibility::Preview => "preview",
    }
}

fn common_fields(o: &mut JsonObj, c: &CommonProps) {
    o.bool_val("locked", c.locked);
    o.num("opacity", c.opacity);
    o.raw("transform", transform_json(&c.transform));
    o.str_val("visibility", visibility_str(c.visibility));
}

fn path_command_json(cmd: &PathCommand) -> String {
    let mut o = JsonObj::new();
    match cmd {
        PathCommand::MoveTo { x, y } => {
            o.str_val("cmd", "M");
            o.num("x", *x);
            o.num("y", *y);
        }
        PathCommand::LineTo { x, y } => {
            o.str_val("cmd", "L");
            o.num("x", *x);
            o.num("y", *y);
        }
        PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
            o.str_val("cmd", "C");
            o.num("x", *x);
            o.num("x1", *x1);
            o.num("x2", *x2);
            o.num("y", *y);
            o.num("y1", *y1);
            o.num("y2", *y2);
        }
        PathCommand::SmoothCurveTo { x2, y2, x, y } => {
            o.str_val("cmd", "S");
            o.num("x", *x);
            o.num("x2", *x2);
            o.num("y", *y);
            o.num("y2", *y2);
        }
        PathCommand::QuadTo { x1, y1, x, y } => {
            o.str_val("cmd", "Q");
            o.num("x", *x);
            o.num("x1", *x1);
            o.num("y", *y);
            o.num("y1", *y1);
        }
        PathCommand::SmoothQuadTo { x, y } => {
            o.str_val("cmd", "T");
            o.num("x", *x);
            o.num("y", *y);
        }
        PathCommand::ArcTo { rx, ry, x_rotation, large_arc, sweep, x, y } => {
            o.str_val("cmd", "A");
            o.bool_val("large_arc", *large_arc);
            o.num("rx", *rx);
            o.num("ry", *ry);
            o.bool_val("sweep", *sweep);
            o.num("x", *x);
            o.num("x_rotation", *x_rotation);
            o.num("y", *y);
        }
        PathCommand::ClosePath => {
            o.str_val("cmd", "Z");
        }
    }
    o.build()
}

fn points_json(points: &[(f64, f64)]) -> String {
    let items: Vec<String> = points
        .iter()
        .map(|(x, y)| format!("[{},{}]", fmt(*x), fmt(*y)))
        .collect();
    json_array(&items)
}

// ---------------------------------------------------------------------------
// Element serializer
// ---------------------------------------------------------------------------

fn element_json(elem: &Element) -> String {
    let mut o = JsonObj::new();
    match elem {
        Element::Line(e) => {
            o.str_val("type", "line");
            common_fields(&mut o, &e.common);
            o.raw("stroke", stroke_json(&e.stroke));
            o.num("x1", e.x1);
            o.num("x2", e.x2);
            o.num("y1", e.y1);
            o.num("y2", e.y2);
        }
        Element::Rect(e) => {
            o.str_val("type", "rect");
            common_fields(&mut o, &e.common);
            o.raw("fill", fill_json(&e.fill));
            o.num("height", e.height);
            o.num("rx", e.rx);
            o.num("ry", e.ry);
            o.raw("stroke", stroke_json(&e.stroke));
            o.num("width", e.width);
            o.num("x", e.x);
            o.num("y", e.y);
        }
        Element::Circle(e) => {
            o.str_val("type", "circle");
            common_fields(&mut o, &e.common);
            o.num("cx", e.cx);
            o.num("cy", e.cy);
            o.raw("fill", fill_json(&e.fill));
            o.num("r", e.r);
            o.raw("stroke", stroke_json(&e.stroke));
        }
        Element::Ellipse(e) => {
            o.str_val("type", "ellipse");
            common_fields(&mut o, &e.common);
            o.num("cx", e.cx);
            o.num("cy", e.cy);
            o.raw("fill", fill_json(&e.fill));
            o.num("rx", e.rx);
            o.num("ry", e.ry);
            o.raw("stroke", stroke_json(&e.stroke));
        }
        Element::Polyline(e) => {
            o.str_val("type", "polyline");
            common_fields(&mut o, &e.common);
            o.raw("fill", fill_json(&e.fill));
            o.raw("points", points_json(&e.points));
            o.raw("stroke", stroke_json(&e.stroke));
        }
        Element::Polygon(e) => {
            o.str_val("type", "polygon");
            common_fields(&mut o, &e.common);
            o.raw("fill", fill_json(&e.fill));
            o.raw("points", points_json(&e.points));
            o.raw("stroke", stroke_json(&e.stroke));
        }
        Element::Path(e) => {
            o.str_val("type", "path");
            common_fields(&mut o, &e.common);
            let cmds: Vec<String> = e.d.iter().map(path_command_json).collect();
            o.raw("d", json_array(&cmds));
            o.raw("fill", fill_json(&e.fill));
            o.raw("stroke", stroke_json(&e.stroke));
        }
        Element::Text(e) => {
            o.str_val("type", "text");
            common_fields(&mut o, &e.common);
            o.str_val("content", &e.content);
            o.raw("fill", fill_json(&e.fill));
            o.str_val("font_family", &e.font_family);
            o.num("font_size", e.font_size);
            o.str_val("font_style", &e.font_style);
            o.str_val("font_weight", &e.font_weight);
            o.num("height", e.height);
            o.raw("stroke", stroke_json(&e.stroke));
            o.str_val("text_decoration", &e.text_decoration);
            o.num("width", e.width);
            o.num("x", e.x);
            o.num("y", e.y);
        }
        Element::TextPath(e) => {
            o.str_val("type", "text_path");
            common_fields(&mut o, &e.common);
            o.str_val("content", &e.content);
            let cmds: Vec<String> = e.d.iter().map(path_command_json).collect();
            o.raw("d", json_array(&cmds));
            o.raw("fill", fill_json(&e.fill));
            o.str_val("font_family", &e.font_family);
            o.num("font_size", e.font_size);
            o.str_val("font_style", &e.font_style);
            o.str_val("font_weight", &e.font_weight);
            o.num("start_offset", e.start_offset);
            o.raw("stroke", stroke_json(&e.stroke));
            o.str_val("text_decoration", &e.text_decoration);
        }
        Element::Group(e) => {
            o.str_val("type", "group");
            common_fields(&mut o, &e.common);
            let children: Vec<String> = e.children.iter().map(|c| element_json(c)).collect();
            o.raw("children", json_array(&children));
        }
        Element::Layer(e) => {
            o.str_val("type", "layer");
            common_fields(&mut o, &e.common);
            let children: Vec<String> = e.children.iter().map(|c| element_json(c)).collect();
            o.raw("children", json_array(&children));
            o.str_val("name", &e.name);
        }
    }
    o.build()
}

// ---------------------------------------------------------------------------
// Selection serializer
// ---------------------------------------------------------------------------

fn selection_json(sel: &[ElementSelection]) -> String {
    let mut entries: Vec<(Vec<usize>, String)> = sel
        .iter()
        .map(|es| {
            let mut o = JsonObj::new();
            match &es.kind {
                SelectionKind::All => {
                    o.str_val("kind", "all");
                }
                SelectionKind::Partial(cps) => {
                    let indices: Vec<String> = cps.iter().map(|i| i.to_string()).collect();
                    o.raw("kind", format!("{{\"partial\":[{}]}}", indices.join(",")));
                }
            }
            let path: Vec<String> = es.path.iter().map(|i| i.to_string()).collect();
            o.raw("path", format!("[{}]", path.join(",")));
            (es.path.clone(), o.build())
        })
        .collect();
    // Sort by path lexicographically.
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    let items: Vec<String> = entries.into_iter().map(|(_, json)| json).collect();
    json_array(&items)
}

// ---------------------------------------------------------------------------
// Document serializer (public API)
// ---------------------------------------------------------------------------

/// Serialize a Document to canonical test JSON.
///
/// The output is a compact JSON string with sorted keys and normalized
/// floats, suitable for byte-for-byte cross-language comparison.
pub fn document_to_test_json(doc: &Document) -> String {
    let layers: Vec<String> = doc.layers.iter().map(|l| element_json(l)).collect();
    let mut o = JsonObj::new();
    o.raw("layers", json_array(&layers));
    o.int("selected_layer", doc.selected_layer);
    o.raw("selection", selection_json(&doc.selection));
    o.build()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::rc::Rc;

    #[test]
    fn empty_document() {
        let doc = Document::default();
        let json = document_to_test_json(&doc);
        assert!(json.contains("\"type\":\"layer\""));
        assert!(json.contains("\"selected_layer\":0"));
        assert!(json.contains("\"selection\":[]"));
    }

    #[test]
    fn line_element() {
        let line = Element::Line(LineElem {
            x1: 0.0,
            y1: 0.0,
            x2: 72.0,
            y2: 36.0,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            common: CommonProps::default(),
        });
        let json = element_json(&line);
        assert!(json.contains("\"type\":\"line\""));
        assert!(json.contains("\"x2\":72.0"));
        assert!(json.contains("\"y2\":36.0"));
        // No fill key for lines.
        assert!(!json.contains("\"fill\""));
    }

    #[test]
    fn rect_element() {
        let rect = Element::Rect(RectElem {
            x: 0.0,
            y: 0.0,
            width: 100.0,
            height: 50.0,
            rx: 0.0,
            ry: 0.0,
            fill: Some(Fill::new(Color::new(1.0, 0.0, 0.0, 1.0))),
            stroke: None,
            common: CommonProps::default(),
        });
        let json = element_json(&rect);
        assert!(json.contains("\"type\":\"rect\""));
        assert!(json.contains("\"fill\":{\"color\":{\"a\":1.0,\"b\":0.0,\"g\":0.0,\"r\":1.0}}"));
        assert!(json.contains("\"stroke\":null"));
    }

    #[test]
    fn float_formatting() {
        assert_eq!(fmt(1.0), "1.0");
        assert_eq!(fmt(0.0), "0.0");
        assert_eq!(fmt(3.14159), "3.1416");
        assert_eq!(fmt(0.5), "0.5");
        assert_eq!(fmt(72.0), "72.0");
        assert_eq!(fmt(0.12345), "0.1235");
    }

    #[test]
    fn keys_sorted() {
        let rect = Element::Rect(RectElem {
            x: 10.0,
            y: 20.0,
            width: 30.0,
            height: 40.0,
            rx: 5.0,
            ry: 5.0,
            fill: None,
            stroke: None,
            common: CommonProps::default(),
        });
        let json = element_json(&rect);
        // Keys must be in alphabetical order.
        let fill_pos = json.find("\"fill\"").unwrap();
        let height_pos = json.find("\"height\"").unwrap();
        let type_pos = json.find("\"type\"").unwrap();
        assert!(fill_pos < height_pos);
        assert!(height_pos < type_pos);
    }

    #[test]
    fn selection_sorted_by_path() {
        let sel = vec![
            ElementSelection::all(vec![1, 0]),
            ElementSelection::all(vec![0, 1]),
            ElementSelection::partial(vec![0, 0], [2, 0, 4]),
        ];
        let json = selection_json(&sel);
        // [0,0] should come first, then [0,1], then [1,0].
        let pos_00 = json.find("[0,0]").unwrap();
        let pos_01 = json.find("[0,1]").unwrap();
        let pos_10 = json.find("[1,0]").unwrap();
        assert!(pos_00 < pos_01);
        assert!(pos_01 < pos_10);
    }

    #[test]
    fn group_no_fill_stroke() {
        let group = Element::Group(GroupElem {
            children: Vec::new(),
            common: CommonProps::default(),
        });
        let json = element_json(&group);
        assert!(!json.contains("\"fill\""));
        assert!(!json.contains("\"stroke\""));
        assert!(json.contains("\"children\":[]"));
    }

    #[test]
    fn transform_json_output() {
        let t = Some(Transform::translate(10.0, 20.0));
        let json = transform_json(&t);
        assert!(json.contains("\"e\":10.0"));
        assert!(json.contains("\"f\":20.0"));
    }
}
