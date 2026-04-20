//! Canonical Test JSON serialization for cross-language equivalence testing.
//!
//! See `CROSS_LANGUAGE_TESTING.md` at the repository root for the full
//! specification.  Every semantic document value has exactly one JSON
//! string representation, so byte-for-byte comparison of the output is a
//! valid equivalence check.

use crate::document::document::{Document, ElementPath, ElementSelection, Selection, SelectionKind, SortedCps};
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

    fn opt_str(&mut self, key: &str, v: &Option<String>) {
        match v {
            Some(s) => self.str_val(key, s),
            None => self.null(key),
        }
    }

    /// Emit an empty string as null, otherwise as a JSON string.
    /// Matches the canonical-JSON rule that default/omitted attributes
    /// render as null.
    fn empty_as_null(&mut self, key: &str, v: &str) {
        if v.is_empty() {
            self.null(key);
        } else {
            self.str_val(key, v);
        }
    }

    fn opt_num(&mut self, key: &str, v: Option<f64>) {
        match v {
            Some(n) => self.num(key, n),
            None => self.null(key),
        }
    }

    fn opt_bool(&mut self, key: &str, v: Option<bool>) {
        match v {
            Some(b) => self.bool_val(key, b),
            None => self.null(key),
        }
    }

    fn opt_str_vec(&mut self, key: &str, v: &Option<Vec<String>>) {
        match v {
            Some(vec) => {
                let mut sorted = vec.clone();
                sorted.sort();
                let quoted: Vec<String> = sorted
                    .iter()
                    .map(|s| format!("\"{}\"", s))
                    .collect();
                self.raw(key, format!("[{}]", quoted.join(",")));
            }
            None => self.null(key),
        }
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
    match c {
        Color::Rgb { r, g, b, a } => {
            o.num("a", *a);
            o.num("b", *b);
            o.num("g", *g);
            o.num("r", *r);
            o.str_val("space", "rgb");
        }
        Color::Hsb { h, s, b, a } => {
            o.num("a", *a);
            o.num("b", *b);
            o.num("h", *h);
            o.num("s", *s);
            o.str_val("space", "hsb");
        }
        Color::Cmyk { c, m, y, k, a } => {
            o.num("a", *a);
            o.num("c", *c);
            o.num("k", *k);
            o.num("m", *m);
            o.str_val("space", "cmyk");
            o.num("y", *y);
        }
    }
    o.build()
}

fn fill_json(fill: &Option<Fill>) -> String {
    match fill {
        None => "null".to_string(),
        Some(f) => {
            let mut o = JsonObj::new();
            o.raw("color", color_json(&f.color));
            o.num("opacity", f.opacity);
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
            o.num("opacity", s.opacity);
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

fn tspan_json(t: &crate::geometry::tspan::Tspan) -> String {
    let mut o = JsonObj::new();
    o.opt_num("baseline_shift", t.baseline_shift);
    o.str_val("content", &t.content);
    o.opt_num("dx", t.dx);
    o.opt_str("font_family", &t.font_family);
    o.opt_num("font_size", t.font_size);
    o.opt_str("font_style", &t.font_style);
    o.opt_str("font_variant", &t.font_variant);
    o.opt_str("font_weight", &t.font_weight);
    o.int("id", t.id as usize);
    o.opt_str("jas_aa_mode", &t.jas_aa_mode);
    o.opt_bool("jas_fractional_widths", t.jas_fractional_widths);
    o.opt_str("jas_kerning_mode", &t.jas_kerning_mode);
    o.opt_bool("jas_no_break", t.jas_no_break);
    o.opt_num("letter_spacing", t.letter_spacing);
    o.opt_num("line_height", t.line_height);
    o.opt_num("rotate", t.rotate);
    o.opt_str("style_name", &t.style_name);
    o.opt_str_vec("text_decoration", &t.text_decoration);
    o.opt_str("text_rendering", &t.text_rendering);
    o.opt_str("text_transform", &t.text_transform);
    o.raw("transform", transform_json(&t.transform));
    o.opt_str("xml_lang", &t.xml_lang);
    o.build()
}

/// Convert the legacy `text_decoration: String` field into the canonical
/// sorted-array-of-members form.
///
/// `"none"` / `""` → `[]`
/// `"underline"` → `["underline"]`
/// `"line-through"` → `["line-through"]`
/// `"underline line-through"` → `["line-through","underline"]` (alphabetical)
fn text_decoration_json(td: &str) -> String {
    let mut parts: Vec<&str> = td
        .split_whitespace()
        .filter(|s| !s.is_empty() && *s != "none")
        .collect();
    parts.sort();
    let quoted: Vec<String> = parts.iter().map(|s| format!("\"{}\"", s)).collect();
    format!("[{}]", quoted.join(","))
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
            // Extended element-wide attribute slots. Still-null slots
            // are placeholders until TextElem grows per-element
            // override fields (see TSPAN.md Attribute Home).
            o.empty_as_null("baseline_shift", &e.baseline_shift);
            o.null("dx");
            o.raw("fill", fill_json(&e.fill));
            o.str_val("font_family", &e.font_family);
            o.num("font_size", e.font_size);
            o.str_val("font_style", &e.font_style);
            o.empty_as_null("font_variant", &e.font_variant);
            o.str_val("font_weight", &e.font_weight);
            o.num("height", e.height);
            o.empty_as_null("horizontal_scale", &e.horizontal_scale);
            o.empty_as_null("jas_aa_mode", &e.aa_mode);
            o.null("jas_fractional_widths");
            o.empty_as_null("jas_kerning_mode", &e.kerning);
            o.null("jas_no_break");
            o.empty_as_null("letter_spacing", &e.letter_spacing);
            o.empty_as_null("line_height", &e.line_height);
            o.empty_as_null("rotate", &e.rotate);
            o.raw("stroke", stroke_json(&e.stroke));
            o.null("style_name");
            o.raw("text_decoration", text_decoration_json(&e.text_decoration));
            o.null("text_rendering");
            o.empty_as_null("text_transform", &e.text_transform);
            // Per-tspan list (always non-empty).
            let tspans: Vec<String> = e.tspans.iter().map(tspan_json).collect();
            o.raw("tspans", json_array(&tspans));
            o.empty_as_null("vertical_scale", &e.vertical_scale);
            o.num("width", e.width);
            o.num("x", e.x);
            o.empty_as_null("xml_lang", &e.xml_lang);
            o.num("y", e.y);
        }
        Element::TextPath(e) => {
            o.str_val("type", "text_path");
            common_fields(&mut o, &e.common);
            o.empty_as_null("baseline_shift", &e.baseline_shift);
            let cmds: Vec<String> = e.d.iter().map(path_command_json).collect();
            o.raw("d", json_array(&cmds));
            o.null("dx");
            o.raw("fill", fill_json(&e.fill));
            o.str_val("font_family", &e.font_family);
            o.num("font_size", e.font_size);
            o.str_val("font_style", &e.font_style);
            o.empty_as_null("font_variant", &e.font_variant);
            o.str_val("font_weight", &e.font_weight);
            o.empty_as_null("horizontal_scale", &e.horizontal_scale);
            o.empty_as_null("jas_aa_mode", &e.aa_mode);
            o.null("jas_fractional_widths");
            o.empty_as_null("jas_kerning_mode", &e.kerning);
            o.null("jas_no_break");
            o.empty_as_null("letter_spacing", &e.letter_spacing);
            o.empty_as_null("line_height", &e.line_height);
            o.empty_as_null("rotate", &e.rotate);
            o.num("start_offset", e.start_offset);
            o.raw("stroke", stroke_json(&e.stroke));
            o.null("style_name");
            o.raw("text_decoration", text_decoration_json(&e.text_decoration));
            o.null("text_rendering");
            o.empty_as_null("text_transform", &e.text_transform);
            let tspans: Vec<String> = e.tspans.iter().map(tspan_json).collect();
            o.raw("tspans", json_array(&tspans));
            o.empty_as_null("vertical_scale", &e.vertical_scale);
            o.empty_as_null("xml_lang", &e.xml_lang);
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
        Element::Live(v) => match v {
            crate::geometry::live::LiveVariant::CompoundShape(cs) => {
                o.str_val("type", "live");
                o.str_val("kind", "compound_shape");
                common_fields(&mut o, &cs.common);
                let children: Vec<String> = cs.operands.iter().map(|c| element_json(c)).collect();
                o.raw("children", json_array(&children));
            }
        },
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
// JSON → Document parser (inverse of document_to_test_json)
// ---------------------------------------------------------------------------

fn parse_f(v: &serde_json::Value) -> f64 {
    v.as_f64().unwrap_or(0.0)
}

fn parse_str_opt(v: &serde_json::Value) -> Option<String> {
    v.as_str().map(String::from)
}

fn parse_transform_opt(v: &serde_json::Value) -> Option<Transform> {
    if v.is_null() {
        return None;
    }
    Some(Transform {
        a: parse_f(&v["a"]),
        b: parse_f(&v["b"]),
        c: parse_f(&v["c"]),
        d: parse_f(&v["d"]),
        e: parse_f(&v["e"]),
        f: parse_f(&v["f"]),
    })
}

fn parse_tspan(v: &serde_json::Value) -> crate::geometry::tspan::Tspan {
    crate::geometry::tspan::Tspan {
        id: v["id"].as_u64().unwrap_or(0) as u32,
        content: v["content"].as_str().unwrap_or("").to_string(),
        baseline_shift: v["baseline_shift"].as_f64(),
        dx: v["dx"].as_f64(),
        font_family: parse_str_opt(&v["font_family"]),
        font_size: v["font_size"].as_f64(),
        font_style: parse_str_opt(&v["font_style"]),
        font_variant: parse_str_opt(&v["font_variant"]),
        font_weight: parse_str_opt(&v["font_weight"]),
        jas_aa_mode: parse_str_opt(&v["jas_aa_mode"]),
        jas_fractional_widths: v["jas_fractional_widths"].as_bool(),
        jas_kerning_mode: parse_str_opt(&v["jas_kerning_mode"]),
        jas_no_break: v["jas_no_break"].as_bool(),
        letter_spacing: v["letter_spacing"].as_f64(),
        line_height: v["line_height"].as_f64(),
        rotate: v["rotate"].as_f64(),
        style_name: parse_str_opt(&v["style_name"]),
        text_decoration: v["text_decoration"].as_array().map(|arr| {
            arr.iter()
                .filter_map(|s| s.as_str().map(String::from))
                .collect()
        }),
        text_rendering: parse_str_opt(&v["text_rendering"]),
        text_transform: parse_str_opt(&v["text_transform"]),
        transform: parse_transform_opt(&v["transform"]),
        xml_lang: parse_str_opt(&v["xml_lang"]),
        jas_role: parse_str_opt(&v["jas_role"]),
        jas_left_indent: v["jas_left_indent"].as_f64(),
        jas_right_indent: v["jas_right_indent"].as_f64(),
        jas_hyphenate: v["jas_hyphenate"].as_bool(),
        jas_hanging_punctuation: v["jas_hanging_punctuation"].as_bool(),
        jas_list_style: parse_str_opt(&v["jas_list_style"]),
        text_align: parse_str_opt(&v["text_align"]),
        text_align_last: parse_str_opt(&v["text_align_last"]),
        text_indent: v["text_indent"].as_f64(),
        jas_space_before: v["jas_space_before"].as_f64(),
        jas_space_after: v["jas_space_after"].as_f64(),
        jas_word_spacing_min: v["jas_word_spacing_min"].as_f64(),
        jas_word_spacing_desired: v["jas_word_spacing_desired"].as_f64(),
        jas_word_spacing_max: v["jas_word_spacing_max"].as_f64(),
        jas_letter_spacing_min: v["jas_letter_spacing_min"].as_f64(),
        jas_letter_spacing_desired: v["jas_letter_spacing_desired"].as_f64(),
        jas_letter_spacing_max: v["jas_letter_spacing_max"].as_f64(),
        jas_glyph_scaling_min: v["jas_glyph_scaling_min"].as_f64(),
        jas_glyph_scaling_desired: v["jas_glyph_scaling_desired"].as_f64(),
        jas_glyph_scaling_max: v["jas_glyph_scaling_max"].as_f64(),
        jas_auto_leading: v["jas_auto_leading"].as_f64(),
        jas_single_word_justify: parse_str_opt(&v["jas_single_word_justify"]),
        jas_hyphenate_min_word: v["jas_hyphenate_min_word"].as_f64(),
        jas_hyphenate_min_before: v["jas_hyphenate_min_before"].as_f64(),
        jas_hyphenate_min_after: v["jas_hyphenate_min_after"].as_f64(),
        jas_hyphenate_limit: v["jas_hyphenate_limit"].as_f64(),
        jas_hyphenate_zone: v["jas_hyphenate_zone"].as_f64(),
        jas_hyphenate_bias: v["jas_hyphenate_bias"].as_f64(),
        jas_hyphenate_capitalized: v["jas_hyphenate_capitalized"].as_bool(),
    }
}

/// Parse the tspan list from a Text / TextPath JSON value. Accepts two
/// shapes for backward compatibility during the migration:
/// - New: `"tspans": [...]` array of tspan objects.
/// - Legacy: `"content": "..."` string (→ single default tspan).
fn parse_tspans_or_legacy(v: &serde_json::Value) -> Vec<crate::geometry::tspan::Tspan> {
    if let Some(arr) = v.get("tspans").and_then(|t| t.as_array()) {
        return arr.iter().map(parse_tspan).collect();
    }
    let content = v["content"].as_str().unwrap_or("").to_string();
    vec![crate::geometry::tspan::Tspan {
        content,
        ..crate::geometry::tspan::Tspan::default_tspan()
    }]
}

/// Accepts the new `text_decoration` canonical form (sorted array) or
/// the legacy string form; returns the space-separated string shape
/// used by the current `TextElem.text_decoration: String` field.
fn parse_text_decoration_field(v: &serde_json::Value) -> String {
    if let Some(arr) = v.as_array() {
        if arr.is_empty() {
            return "none".to_string();
        }
        let parts: Vec<&str> = arr.iter().filter_map(|x| x.as_str()).collect();
        return parts.join(" ");
    }
    v.as_str().unwrap_or("none").to_string()
}

fn parse_color(v: &serde_json::Value) -> Color {
    match v["space"].as_str().unwrap_or("rgb") {
        "hsb" => Color::Hsb {
            h: parse_f(&v["h"]),
            s: parse_f(&v["s"]),
            b: parse_f(&v["b"]),
            a: parse_f(&v["a"]),
        },
        "cmyk" => Color::Cmyk {
            c: parse_f(&v["c"]),
            m: parse_f(&v["m"]),
            y: parse_f(&v["y"]),
            k: parse_f(&v["k"]),
            a: parse_f(&v["a"]),
        },
        _ => Color::Rgb {
            r: parse_f(&v["r"]),
            g: parse_f(&v["g"]),
            b: parse_f(&v["b"]),
            a: parse_f(&v["a"]),
        },
    }
}

fn parse_fill(v: &serde_json::Value) -> Option<Fill> {
    if v.is_null() { return None; }
    Some(Fill {
        color: parse_color(&v["color"]),
        opacity: v["opacity"].as_f64().unwrap_or(1.0),
    })
}

fn parse_stroke(v: &serde_json::Value) -> Option<Stroke> {
    if v.is_null() { return None; }
    let lc = match v["linecap"].as_str().unwrap_or("butt") {
        "round" => LineCap::Round,
        "square" => LineCap::Square,
        _ => LineCap::Butt,
    };
    let lj = match v["linejoin"].as_str().unwrap_or("miter") {
        "round" => LineJoin::Round,
        "bevel" => LineJoin::Bevel,
        _ => LineJoin::Miter,
    };
    Some(Stroke { color: parse_color(&v["color"]), width: parse_f(&v["width"]), linecap: lc, linejoin: lj, miter_limit: 10.0, align: StrokeAlign::Center, dash_pattern: [0.0; 6], dash_len: 0, start_arrow: Arrowhead::None, end_arrow: Arrowhead::None, start_arrow_scale: 100.0, end_arrow_scale: 100.0, arrow_align: ArrowAlign::TipAtEnd, opacity: v["opacity"].as_f64().unwrap_or(1.0) })
}

fn parse_transform(v: &serde_json::Value) -> Option<Transform> {
    if v.is_null() { return None; }
    Some(Transform {
        a: parse_f(&v["a"]), b: parse_f(&v["b"]), c: parse_f(&v["c"]),
        d: parse_f(&v["d"]), e: parse_f(&v["e"]), f: parse_f(&v["f"]),
    })
}

fn parse_visibility(v: &serde_json::Value) -> Visibility {
    match v.as_str().unwrap_or("preview") {
        "invisible" => Visibility::Invisible,
        "outline" => Visibility::Outline,
        _ => Visibility::Preview,
    }
}

fn parse_common(v: &serde_json::Value) -> CommonProps {
    CommonProps {
        opacity: parse_f(&v["opacity"]),
        transform: parse_transform(&v["transform"]),
        locked: v["locked"].as_bool().unwrap_or(false),
        visibility: parse_visibility(&v["visibility"]),
    }
}

fn parse_path_commands(v: &serde_json::Value) -> Vec<PathCommand> {
    v.as_array().unwrap_or(&vec![]).iter().map(|c| {
        match c["cmd"].as_str().unwrap_or("") {
            "M" => PathCommand::MoveTo { x: parse_f(&c["x"]), y: parse_f(&c["y"]) },
            "L" => PathCommand::LineTo { x: parse_f(&c["x"]), y: parse_f(&c["y"]) },
            "C" => PathCommand::CurveTo {
                x1: parse_f(&c["x1"]), y1: parse_f(&c["y1"]),
                x2: parse_f(&c["x2"]), y2: parse_f(&c["y2"]),
                x: parse_f(&c["x"]), y: parse_f(&c["y"]),
            },
            "S" => PathCommand::SmoothCurveTo {
                x2: parse_f(&c["x2"]), y2: parse_f(&c["y2"]),
                x: parse_f(&c["x"]), y: parse_f(&c["y"]),
            },
            "Q" => PathCommand::QuadTo {
                x1: parse_f(&c["x1"]), y1: parse_f(&c["y1"]),
                x: parse_f(&c["x"]), y: parse_f(&c["y"]),
            },
            "T" => PathCommand::SmoothQuadTo { x: parse_f(&c["x"]), y: parse_f(&c["y"]) },
            "A" => PathCommand::ArcTo {
                rx: parse_f(&c["rx"]), ry: parse_f(&c["ry"]),
                x_rotation: parse_f(&c["x_rotation"]),
                large_arc: c["large_arc"].as_bool().unwrap_or(false),
                sweep: c["sweep"].as_bool().unwrap_or(false),
                x: parse_f(&c["x"]), y: parse_f(&c["y"]),
            },
            _ => PathCommand::ClosePath,
        }
    }).collect()
}

fn parse_points(v: &serde_json::Value) -> Vec<(f64, f64)> {
    v.as_array().unwrap_or(&vec![]).iter().map(|p| {
        let a = p.as_array().unwrap();
        (a[0].as_f64().unwrap(), a[1].as_f64().unwrap())
    }).collect()
}

pub fn parse_element(v: &serde_json::Value) -> Element {
    let typ = v["type"].as_str().unwrap_or("");
    let common = parse_common(v);
    match typ {
        "line" => Element::Line(LineElem {
            x1: parse_f(&v["x1"]), y1: parse_f(&v["y1"]),
            x2: parse_f(&v["x2"]), y2: parse_f(&v["y2"]),
            stroke: parse_stroke(&v["stroke"]),
            width_points: vec![],
            common,
        }),
        "rect" => Element::Rect(RectElem {
            x: parse_f(&v["x"]), y: parse_f(&v["y"]),
            width: parse_f(&v["width"]), height: parse_f(&v["height"]),
            rx: parse_f(&v["rx"]), ry: parse_f(&v["ry"]),
            fill: parse_fill(&v["fill"]), stroke: parse_stroke(&v["stroke"]),
            common,
        }),
        "circle" => Element::Circle(CircleElem {
            cx: parse_f(&v["cx"]), cy: parse_f(&v["cy"]), r: parse_f(&v["r"]),
            fill: parse_fill(&v["fill"]), stroke: parse_stroke(&v["stroke"]),
            common,
        }),
        "ellipse" => Element::Ellipse(EllipseElem {
            cx: parse_f(&v["cx"]), cy: parse_f(&v["cy"]),
            rx: parse_f(&v["rx"]), ry: parse_f(&v["ry"]),
            fill: parse_fill(&v["fill"]), stroke: parse_stroke(&v["stroke"]),
            common,
        }),
        "polyline" => Element::Polyline(PolylineElem {
            points: parse_points(&v["points"]),
            fill: parse_fill(&v["fill"]), stroke: parse_stroke(&v["stroke"]),
            common,
        }),
        "polygon" => Element::Polygon(PolygonElem {
            points: parse_points(&v["points"]),
            fill: parse_fill(&v["fill"]), stroke: parse_stroke(&v["stroke"]),
            common,
        }),
        "path" => Element::Path(PathElem {
            d: parse_path_commands(&v["d"]),
            fill: parse_fill(&v["fill"]), stroke: parse_stroke(&v["stroke"]),
            width_points: vec![],
            common,
        }),
        "text" => Element::Text(TextElem {
            x: parse_f(&v["x"]),
            y: parse_f(&v["y"]),
            tspans: parse_tspans_or_legacy(v),
            font_family: v["font_family"]
                .as_str()
                .unwrap_or("sans-serif")
                .to_string(),
            font_size: parse_f(&v["font_size"]),
            font_weight: v["font_weight"].as_str().unwrap_or("normal").to_string(),
            font_style: v["font_style"].as_str().unwrap_or("normal").to_string(),
            text_decoration: parse_text_decoration_field(&v["text_decoration"]),
            text_transform: v["text_transform"].as_str().unwrap_or("").to_string(),
            font_variant: v["font_variant"].as_str().unwrap_or("").to_string(),
            baseline_shift: v["baseline_shift"].as_str().unwrap_or("").to_string(),
            line_height: v["line_height"].as_str().unwrap_or("").to_string(),
            letter_spacing: v["letter_spacing"].as_str().unwrap_or("").to_string(),
            xml_lang: v["xml_lang"].as_str().unwrap_or("").to_string(),
            aa_mode: v["jas_aa_mode"].as_str().unwrap_or("").to_string(),
            rotate: v["rotate"].as_str().unwrap_or("").to_string(),
            horizontal_scale: v["horizontal_scale"].as_str().unwrap_or("").to_string(),
            vertical_scale: v["vertical_scale"].as_str().unwrap_or("").to_string(),
            kerning: v["jas_kerning_mode"].as_str().unwrap_or("").to_string(),
            width: parse_f(&v["width"]),
            height: parse_f(&v["height"]),
            fill: parse_fill(&v["fill"]),
            stroke: parse_stroke(&v["stroke"]),
            common,
        }),
        "text_path" => Element::TextPath(TextPathElem {
            d: parse_path_commands(&v["d"]),
            tspans: parse_tspans_or_legacy(v),
            start_offset: parse_f(&v["start_offset"]),
            font_family: v["font_family"]
                .as_str()
                .unwrap_or("sans-serif")
                .to_string(),
            font_size: parse_f(&v["font_size"]),
            font_weight: v["font_weight"].as_str().unwrap_or("normal").to_string(),
            font_style: v["font_style"].as_str().unwrap_or("normal").to_string(),
            text_decoration: parse_text_decoration_field(&v["text_decoration"]),
            text_transform: v["text_transform"].as_str().unwrap_or("").to_string(),
            font_variant: v["font_variant"].as_str().unwrap_or("").to_string(),
            baseline_shift: v["baseline_shift"].as_str().unwrap_or("").to_string(),
            line_height: v["line_height"].as_str().unwrap_or("").to_string(),
            letter_spacing: v["letter_spacing"].as_str().unwrap_or("").to_string(),
            xml_lang: v["xml_lang"].as_str().unwrap_or("").to_string(),
            aa_mode: v["jas_aa_mode"].as_str().unwrap_or("").to_string(),
            rotate: v["rotate"].as_str().unwrap_or("").to_string(),
            horizontal_scale: v["horizontal_scale"].as_str().unwrap_or("").to_string(),
            vertical_scale: v["vertical_scale"].as_str().unwrap_or("").to_string(),
            kerning: v["jas_kerning_mode"].as_str().unwrap_or("").to_string(),
            fill: parse_fill(&v["fill"]),
            stroke: parse_stroke(&v["stroke"]),
            common,
        }),
        "group" => {
            let children = v["children"].as_array().unwrap_or(&vec![])
                .iter().map(|c| std::rc::Rc::new(parse_element(c))).collect();
            Element::Group(GroupElem { children, common })
        },
        "layer" => {
            let children = v["children"].as_array().unwrap_or(&vec![])
                .iter().map(|c| std::rc::Rc::new(parse_element(c))).collect();
            let name = v["name"].as_str().unwrap_or("Layer").to_string();
            Element::Layer(LayerElem { name, children, common })
        },
        _ => panic!("Unknown element type: {}", typ),
    }
}

fn parse_selection(v: &serde_json::Value) -> Selection {
    v.as_array().unwrap_or(&vec![]).iter().map(|es| {
        let path: ElementPath = es["path"].as_array().unwrap()
            .iter().map(|i| i.as_u64().unwrap() as usize).collect();
        let kind = if let Some(s) = es["kind"].as_str() {
            if s == "all" { SelectionKind::All }
            else { SelectionKind::All }
        } else if let Some(obj) = es["kind"].as_object() {
            if let Some(partial) = obj.get("partial") {
                let cps: Vec<usize> = partial.as_array().unwrap()
                    .iter().map(|i| i.as_u64().unwrap() as usize).collect();
                SelectionKind::Partial(SortedCps::from_iter(cps))
            } else { SelectionKind::All }
        } else { SelectionKind::All };
        ElementSelection { path, kind }
    }).collect()
}

/// Parse canonical test JSON into a Document.
///
/// This is the inverse of [`document_to_test_json`].
pub fn test_json_to_document(json: &str) -> Document {
    let v: serde_json::Value = serde_json::from_str(json)
        .expect("Failed to parse test JSON");
    let layers: Vec<Element> = v["layers"].as_array().unwrap()
        .iter().map(|l| parse_element(l)).collect();
    let selected_layer = v["selected_layer"].as_u64().unwrap_or(0) as usize;
    let selection = parse_selection(&v["selection"]);
    Document { layers, selected_layer, selection }
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
            width_points: Vec::new(),
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
        assert!(json.contains("\"fill\":{\"color\":{\"a\":1.0,\"b\":0.0,\"g\":0.0,\"r\":1.0,\"space\":\"rgb\"},\"opacity\":1.0}"));
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
